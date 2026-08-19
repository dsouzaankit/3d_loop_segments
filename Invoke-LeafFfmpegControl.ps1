#Requires -Version 5.1
# Leaf DLNA export ffmpeg (3d_op_*.mkv): NtSuspend/NtResume + Space toggle for wait loops.
$script:LeafFfmpegNtApiInitialized = $false
$script:LeafFfmpegExportSuspended = $false
$script:LeafFfmpegSuspendedPids = [System.Collections.Generic.List[int]]::new()
# Segment mux passes the ffmpeg pattern (3d_op_%02d.mkv), not literal slot filenames.
$script:LeafFfmpegOutputLeaves = @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
# Preferred Skybox DLNA share path. Files live under %AppData%; F: is always our subst for the run.
$script:DlnaSegmentRootPreferred = 'F:\f1_media\3d_fullsbs_trans'
$script:DlnaSegmentRootDefault = $script:DlnaSegmentRootPreferred
$script:DlnaSegmentRootDriveLetter = 'F'
$script:DlnaSegmentRootAppDataLeaf = '3d_loop_segments'
$script:DlnaSegmentRootSubstLeaf = '3d_loop_segments_F_subst'
$script:DlnaSegmentRootEnsured = $false
$script:DlnaSegmentRootEnsureMode = ''

function Get-DlnaSegmentRootAppDataFallback {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'APPDATA is not set; cannot resolve 3d_loop_segments DLNA fallback.'
    }
    return [System.IO.Path]::GetFullPath((Join-Path $appData $script:DlnaSegmentRootAppDataLeaf))
}

function Get-DlnaSegmentRootSubstMount {
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($appData)) {
        throw 'APPDATA is not set; cannot resolve F: subst mount.'
    }
    return [System.IO.Path]::GetFullPath((Join-Path $appData $script:DlnaSegmentRootSubstLeaf))
}

function Test-DlnaSegmentRootDrivePresent {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $root = ('{0}:\' -f $Letter.TrimEnd(':'))
    try {
        return [System.IO.Directory]::Exists($root)
    } catch {
        return $false
    }
}

function Get-SubstDriveTarget {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $want = ($Letter.TrimEnd(':') + ':').ToUpperInvariant()
    $lines = @()
    try {
        $lines = @(& subst.exe 2>$null)
    } catch {
        return $null
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # subst lines look like: F:\: => C:\Users\...\3d_loop_segments_F_subst
        if ($line -match '^\s*([A-Za-z]:)\\:\s*=>\s*(.+?)\s*$') {
            $mapped = $Matches[1].ToUpperInvariant()
            if ($mapped -eq $want) {
                return [System.IO.Path]::GetFullPath($Matches[2].Trim().Trim('"'))
            }
        }
    }
    return $null
}

function Ensure-DirectoryJunction {
    param(
        [Parameter(Mandatory = $true)][string] $LinkPath,
        [Parameter(Mandatory = $true)][string] $TargetPath
    )
    $linkFull = [System.IO.Path]::GetFullPath($LinkPath)
    $targetFull = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($targetFull)
    }
    if (Test-Path -LiteralPath $linkFull) {
        $item = Get-Item -LiteralPath $linkFull -Force
        $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        if ($isReparse) {
            $existingTarget = $null
            try {
                if ($null -ne $item.Target -and $item.Target.Count -gt 0) {
                    $existingTarget = [System.IO.Path]::GetFullPath([string]$item.Target[0])
                }
            } catch { }
            if ([string]::IsNullOrWhiteSpace($existingTarget) -or
                -not $existingTarget.Equals($targetFull, [StringComparison]::OrdinalIgnoreCase)) {
                cmd.exe /c rmdir "$linkFull" | Out-Null
            } else {
                return $linkFull
            }
        } else {
            return $linkFull
        }
    }
    $parent = [System.IO.Path]::GetDirectoryName($linkFull)
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $mklink = cmd.exe /c mklink /J "$linkFull" "$targetFull" 2>&1
    if (-not (Test-Path -LiteralPath $linkFull)) {
        throw ("Failed to create junction {0} -> {1}: {2}" -f $linkFull, $targetFull, $mklink)
    }
    return $linkFull
}

function Complete-DlnaSegmentRootEnsure {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $Mode
    )
    $root = [System.IO.Path]::GetFullPath($Root)
    [void][System.IO.Directory]::CreateDirectory($root)
    $script:DlnaSegmentRootDefault = $root
    $script:DlnaSegmentRootEnsureMode = $Mode
    $script:DlnaSegmentRootEnsured = $true
    return $root
}

function Ensure-DlnaSegmentRoot {
    <#
    .SYNOPSIS
      Skybox path F:\f1_media\3d_fullsbs_trans is always backed by %AppData%\3d_loop_segments via
      subst F: + directory junction. Does not use a physical F: volume.
    #>
    param([switch] $Force)
    if ($script:DlnaSegmentRootEnsured -and -not $Force.IsPresent) {
        return $script:DlnaSegmentRootDefault
    }

    $preferred = $script:DlnaSegmentRootPreferred
    $appDataRoot = Get-DlnaSegmentRootAppDataFallback
    $substMount = Get-DlnaSegmentRootSubstMount
    $letter = $script:DlnaSegmentRootDriveLetter

    [void][System.IO.Directory]::CreateDirectory($appDataRoot)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $substMount 'f1_media'))
    [void](Ensure-DirectoryJunction -LinkPath (Join-Path $substMount 'f1_media\3d_fullsbs_trans') -TargetPath $appDataRoot)

    $existingSubst = Get-SubstDriveTarget -Letter $letter
    if (-not [string]::IsNullOrWhiteSpace($existingSubst) -and
        -not $existingSubst.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
        throw ("Drive {0}: is already subst'd to {1}; cannot map DLNA mount {2}." -f `
            $letter, $existingSubst, $substMount)
    }

    if ([string]::IsNullOrWhiteSpace($existingSubst)) {
        if (Test-DlnaSegmentRootDrivePresent -Letter $letter) {
            throw ("Drive {0}: is present but is not our AppData subst ({1}). Remove or unmount {0}: so this script can subst it for DLNA output." -f `
                $letter, $substMount)
        }
        $substOut = & subst.exe "${letter}:" "$substMount" 2>&1
        if (-not (Test-DlnaSegmentRootDrivePresent -Letter $letter)) {
            throw ("Failed to subst {0}: -> {1}: {2}" -f $letter, $substMount, $substOut)
        }
        Write-Host ("DLNA root: subst {0}: -> {1}; data under %AppData%\{2}; Skybox path {3}." -f `
            $letter, $substMount, $script:DlnaSegmentRootAppDataLeaf, $preferred)
    }

    if (-not (Test-Path -LiteralPath $preferred -PathType Container)) {
        throw ("DLNA subst/junction setup succeeded but preferred path missing: {0}" -f $preferred)
    }

    return (Complete-DlnaSegmentRootEnsure -Root $preferred -Mode 'appdata-subst')
}

function Get-DlnaSegmentRoot {
    return (Ensure-DlnaSegmentRoot)
}

function Remove-DlnaSegmentRootSubst {
    <#
    .SYNOPSIS
      If F: is our AppData subst, remove the 3d_fullsbs_trans junction and subst F: /d.
      Does not delete %AppData%\3d_loop_segments data.
    #>
    param(
        [switch] $Quiet,
        [switch] $DryRun
    )
    $letter = $script:DlnaSegmentRootDriveLetter
    $substMount = $null
    try {
        $substMount = Get-DlnaSegmentRootSubstMount
    } catch {
        return @{ Removed = $false; Reason = 'no-appdata' }
    }

    $substTarget = Get-SubstDriveTarget -Letter $letter
    if ([string]::IsNullOrWhiteSpace($substTarget)) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: no {0}: subst mapping (nothing to remove)." -f $letter)
        }
        $script:DlnaSegmentRootEnsured = $false
        $script:DlnaSegmentRootEnsureMode = ''
        return @{ Removed = $false; Reason = 'no-subst' }
    }
    if (-not $substTarget.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: {0}: maps to {1} (not our mount); leaving alone." -f `
                $letter, $substTarget)
        }
        return @{ Removed = $false; Reason = 'foreign-subst'; Target = $substTarget }
    }

    $junction = [System.IO.Path]::GetFullPath((Join-Path $substMount 'f1_media\3d_fullsbs_trans'))
    $junctionRemoved = $false
    if (Test-Path -LiteralPath $junction) {
        try {
            $item = Get-Item -LiteralPath $junction -Force
            $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparse) {
                if (-not $DryRun.IsPresent) {
                    cmd.exe /c rmdir "$junction" | Out-Null
                }
                $junctionRemoved = -not (Test-Path -LiteralPath $junction)
                if ($DryRun.IsPresent) { $junctionRemoved = $true }
            }
        } catch { }
    }

    $substRemoved = $false
    if (-not $DryRun.IsPresent) {
        try {
            & subst.exe "${letter}:" /d 2>&1 | Out-Null
        } catch { }
        $still = Get-SubstDriveTarget -Letter $letter
        $substRemoved = [string]::IsNullOrWhiteSpace($still)
    } else {
        $substRemoved = $true
    }

    $script:DlnaSegmentRootEnsured = $false
    $script:DlnaSegmentRootEnsureMode = ''
    $script:DlnaSegmentRootDefault = $script:DlnaSegmentRootPreferred

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would remove' } else { 'removed' }
        Write-Host ("DLNA root subst cleanup: {0} {1}: -> {2} (junction_removed={3}, subst_removed={4})." -f `
            $verb, $letter, $substMount, $junctionRemoved, $substRemoved)
    }

    return @{
        Removed         = ($junctionRemoved -or $substRemoved)
        JunctionRemoved = $junctionRemoved
        SubstRemoved    = $substRemoved
        Mount           = $substMount
    }
}

function Test-FfmpegCommandLineIsLeafDlnaExport {
    param([string] $CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($leaf in $script:LeafFfmpegOutputLeaves) {
        if ($CommandLine -like "*$leaf*") { return $true }
    }
    return $false
}

function Initialize-LeafFfmpegNtSuspendApi {
    if ($script:LeafFfmpegNtApiInitialized) { return }
    if ('LeafFfmpegNtSuspend' -as [type]) {
        $script:LeafFfmpegNtApiInitialized = $true
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LeafFfmpegNtSuspend {
    [DllImport("ntdll.dll")]
    public static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll")]
    public static extern int NtResumeProcess(IntPtr processHandle);
}
'@ -ErrorAction Stop
    $script:LeafFfmpegNtApiInitialized = $true
}

function Convert-TranscodeWorkflowDeadlineUtc {
    param([string] $UtcIso)
    if ([string]::IsNullOrWhiteSpace($UtcIso)) { return $null }
    try {
        return [datetime]::Parse(
            $UtcIso,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    } catch {
        return $null
    }
}

function Test-TranscodeWorkflowDeadlineExpired {
    param([datetime] $DeadlineUtc)
    if ($null -eq $DeadlineUtc -or $DeadlineUtc -le [datetime]::MinValue) { return $false }
    if ($DeadlineUtc -ge [datetime]::MaxValue.AddDays(-1)) { return $false }
    return [DateTime]::UtcNow -ge $DeadlineUtc
}

function Get-LeafFfmpegProcessIds {
    $ids = [System.Collections.Generic.HashSet[int]]::new()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if (Test-FfmpegCommandLineIsLeafDlnaExport -CommandLine $cmd) {
            [void]$ids.Add([int]$proc.ProcessId)
        }
    }
    return @($ids | Sort-Object)
}

function Set-LeafFfmpegProcessSuspended {
    param([int] $ProcessId)
    Initialize-LeafFfmpegNtSuspendApi
    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $status = [LeafFfmpegNtSuspend]::NtSuspendProcess($proc.Handle)
        return ($status -eq 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Set-LeafFfmpegProcessResumed {
    param([int] $ProcessId)
    Initialize-LeafFfmpegNtSuspendApi
    $proc = $null
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $status = [LeafFfmpegNtSuspend]::NtResumeProcess($proc.Handle)
        return ($status -eq 0)
    } catch {
        return $false
    } finally {
        if ($null -ne $proc) { $proc.Dispose() }
    }
}

function Suspend-LeafFfmpegExport {
    $pids = @(Get-LeafFfmpegProcessIds)
    if ($pids.Count -lt 1) {
        Write-Host '[leaf-export] No DLNA export ffmpeg (3d_op_*.mkv) running to pause.'
        return $false
    }
    $script:LeafFfmpegSuspendedPids.Clear()
    $ok = 0
    foreach ($procId in $pids) {
        if (Set-LeafFfmpegProcessSuspended -ProcessId $procId) {
            [void]$script:LeafFfmpegSuspendedPids.Add($procId)
            $ok++
        }
    }
    if ($ok -gt 0) {
        $script:LeafFfmpegExportSuspended = $true
        Write-Host "[leaf-export] Paused $ok DLNA export ffmpeg process(es): $($script:LeafFfmpegSuspendedPids -join ', ')"
        return $true
    }
    Write-Warning '[leaf-export] Could not pause DLNA export ffmpeg (process may have exited).'
    return $false
}

function Resume-LeafFfmpegExport {
    $targets = @($script:LeafFfmpegSuspendedPids)
    if ($targets.Count -lt 1) {
        $targets = @(Get-LeafFfmpegProcessIds)
    }
    if ($targets.Count -lt 1) {
        $script:LeafFfmpegExportSuspended = $false
        $script:LeafFfmpegSuspendedPids.Clear()
        Write-Host '[leaf-export] No DLNA export ffmpeg to resume.'
        return $false
    }
    $ok = 0
    foreach ($procId in $targets) {
        if (Set-LeafFfmpegProcessResumed -ProcessId $procId) { $ok++ }
    }
    $script:LeafFfmpegExportSuspended = $false
    $script:LeafFfmpegSuspendedPids.Clear()
    if ($ok -gt 0) {
        Write-Host "[leaf-export] Resumed $ok DLNA export ffmpeg process(es)."
        return $true
    }
    Write-Warning '[leaf-export] Could not resume DLNA export ffmpeg.'
    return $false
}

function Toggle-LeafFfmpegExportSuspend {
    if ($script:LeafFfmpegExportSuspended) {
        return (Resume-LeafFfmpegExport)
    }
    return (Suspend-LeafFfmpegExport)
}

function Invoke-TranscodeConsoleKeyPoll {
    param(
        [switch] $AllowEnterCancel,
        [ref] $EnterCancel
    )
    if ($AllowEnterCancel -and (Get-Command Invoke-BatchConsoleControlPoll -ErrorAction SilentlyContinue)) {
        $cancelled = $false
        $action = Invoke-BatchConsoleControlPoll -CancelledByEnter ([ref]$cancelled)
        if ($cancelled -and $null -ne $EnterCancel) { $EnterCancel.Value = $true }
        return [bool]$action
    }
    if (-not $AllowEnterCancel -and (Get-Command Test-BatchConsoleEnterKeyPending -ErrorAction SilentlyContinue)) {
        if (Test-BatchConsoleEnterKeyPending) { return $false }
    }
    try {
        if (-not [Console]::KeyAvailable) { return $false }
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Spacebar) {
            [void](Toggle-LeafFfmpegExportSuspend)
            return $true
        }
    } catch {
        # Non-interactive host: no console keys.
    }
    return $false
}
