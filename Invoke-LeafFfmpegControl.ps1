#Requires -Version 5.1
# Leaf DLNA export ffmpeg (3d_op_*.mkv): NtSuspend/NtResume + Space toggle for wait loops.
$script:LeafFfmpegNtApiInitialized = $false
$script:LeafFfmpegExportSuspended = $false
$script:LeafFfmpegSuspendedPids = [System.Collections.Generic.List[int]]::new()
# Segment mux passes the ffmpeg pattern (3d_op_%02d.mkv), not literal slot filenames.
$script:LeafFfmpegOutputLeaves = @('3d_op_00.mkv', '3d_op_01.mkv', '3d_op_%02d.mkv')
# Preferred Skybox DLNA share path (dummy subst, AppData store; same mount as 3d_playlist_local).
# Prefer M:; if M: is a real volume or someone else's subst, pick a free D-Z letter
# and warn to remap the folder in the Skybox PC client.
$script:DlnaSegmentRootShareParent = 'm1_media'
$script:DlnaSegmentRootShareParentLegacyNames = @('f1_media', 'k1_media')
$script:DlnaSegmentRootShareRelative = 'm1_media\3d_fullsbs_trans'
$script:DlnaSegmentRootDriveLetter = 'M'
$script:DlnaSegmentRootPreferred = ('{0}:\{1}' -f $script:DlnaSegmentRootDriveLetter, $script:DlnaSegmentRootShareRelative)
$script:DlnaSegmentRootDefault = $script:DlnaSegmentRootPreferred
$script:DlnaSegmentRootAppDataLeaf = '3d_loop_segments'
$script:DlnaSegmentRootSubstLeaf = 'm1_media_dlna_subst'
$script:DlnaSegmentRootSubstLeafLegacyNames = @('k1_media_dlna_subst', 'f1_media_dlna_subst', 'f1_media_F_subst')
$script:DlnaSegmentRootEnsured = $false
$script:DlnaSegmentRootEnsureMode = ''
$script:DlnaSegmentRootOwnedSubst = $false
$script:DlnaSegmentRootSharedSubst = $false
$script:DlnaWorkflowQuitCleanupDone = $false
# Quit hides media from DLNA by renaming; startup restores via scrambled map.
# Own map file (do not share .dlna_obf_map.json — playlist uses a different key and
# deletes that file when decrypt fails, which blocked restore and forced fresh 3d_op_*).
$script:DlnaObfuscationMapLeafShared = '.dlna_obf_map.json'
$script:DlnaObfuscationMapLeaf = '.dlna_obf_map.3d_loop_segments.json'
$script:DlnaObfuscationMapMagic = 'DLNAOBF1:'
$script:DlnaObfuscationMapKeyMaterial = '3d_loop_segments.dlna_obf_map.v1'
$script:DlnaObfuscationSharedMapParsed = $false
$script:DlnaObfuscationTmpSuffix = '.tmp'
$script:DlnaObfuscationPrefix = '_dlna_obf_'
$script:DlnaObfuscationSuffix = '.dlna_obf'
$script:DlnaMediaExtensions = @(
    '.mkv', '.mp4', '.m4v', '.mov', '.webm', '.ts', '.m2ts', '.mts',
    '.avi', '.wmv', '.mpg', '.mpeg', '.m2v', '.flv', '.3gp', '.ogv', '.ogg',
    '.avs', '.avsi'
)

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
        throw 'APPDATA is not set; cannot resolve dummy DLNA subst mount.'
    }
    $canonical = [System.IO.Path]::GetFullPath((Join-Path $appData $script:DlnaSegmentRootSubstLeaf))
    foreach ($legacyLeaf in @($script:DlnaSegmentRootSubstLeafLegacyNames)) {
        $legacy = [System.IO.Path]::GetFullPath((Join-Path $appData $legacyLeaf))
        if ((Test-Path -LiteralPath $legacy -PathType Container) -and
            -not (Test-Path -LiteralPath $canonical -PathType Container)) {
            try {
                Move-Item -LiteralPath $legacy -Destination $canonical -Force -ErrorAction Stop
            } catch {
                return $legacy
            }
        }
    }
    return $canonical
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

function Get-SubstDriveMappings {
    $map = @{}
    $lines = @()
    try {
        $lines = @(& subst.exe 2>$null)
    } catch {
        return $map
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # subst lines look like: M:\: => C:\Users\...\m1_media_dlna_subst
        if ($line -match '^\s*([A-Za-z]:)\\:\s*=>\s*(.+?)\s*$') {
            $mapped = $Matches[1].ToUpperInvariant()
            $target = [System.IO.Path]::GetFullPath($Matches[2].Trim().Trim('"'))
            $map[$mapped.Substring(0, 1)] = $target
        }
    }
    return $map
}

function Get-SubstDriveTarget {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $want = $Letter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $map = Get-SubstDriveMappings
    if ($map.ContainsKey($want)) {
        return $map[$want]
    }
    return $null
}

function Set-DlnaSegmentRootActiveLetter {
    param([Parameter(Mandatory = $true)][string] $Letter)
    $ch = $Letter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $script:DlnaSegmentRootDriveLetter = $ch
    $script:DlnaSegmentRootPreferred = ('{0}:\{1}' -f $ch, $script:DlnaSegmentRootShareRelative)
}

function Get-DlnaFreeDriveLetters {
    $occupied = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.Name.Length -ge 1) {
            [void]$occupied.Add($d.Name.Substring(0, 1))
        }
    }
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        $n = [string]$_.Name
        if ($n.Length -eq 1) { [void]$occupied.Add($n) }
    }
    foreach ($letter in (Get-SubstDriveMappings).Keys) {
        [void]$occupied.Add($letter)
    }
    $free = [System.Collections.Generic.List[string]]::new()
    foreach ($code in 68..90) {
        $ch = [string][char]$code
        if (-not $occupied.Contains($ch) -and -not [System.IO.Directory]::Exists("${ch}:\")) {
            $free.Add($ch)
        }
    }
    return @($free)
}

function Write-DlnaSkyboxDriveConflictWarning {
    param(
        [Parameter(Mandatory = $true)][string] $PreferredLetter,
        [Parameter(Mandatory = $true)][string] $ActualLetter
    )
    $preferred = $PreferredLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $actual = $ActualLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $actualPath = ('{0}:\{1}' -f $actual, $script:DlnaSegmentRootShareRelative)
    Write-Warning ("Drive {0}: is in use. Dummy DLNA is {1} for this run." -f $preferred, $actualPath)
    Write-Warning ("If Skybox is running, the workflow will try to update Add folders to {0}. Otherwise add that path yourself." -f $actualPath)
}

$loopSegmentsSkybox = Join-Path $PSScriptRoot 'Get-LoopSegmentsSkybox.ps1'
if (-not (Test-Path -LiteralPath $loopSegmentsSkybox -PathType Leaf)) {
    throw ("Get-LoopSegmentsSkybox.ps1 not found: {0}" -f $loopSegmentsSkybox)
}
. $loopSegmentsSkybox

function Resolve-DlnaSegmentRootDriveLetter {
    param([Parameter(Mandatory = $true)][string] $SubstMount)
    $preferred = $script:DlnaSegmentRootDriveLetter.TrimEnd(':').ToUpperInvariant().Substring(0, 1)
    $mappings = Get-SubstDriveMappings
    $ourLetter = $null
    foreach ($letter in $mappings.Keys) {
        if ($mappings[$letter].Equals($SubstMount, [StringComparison]::OrdinalIgnoreCase)) {
            $ourLetter = $letter
            break
        }
    }
    $preferredTaken = $mappings.ContainsKey($preferred) -or (Test-DlnaSegmentRootDrivePresent -Letter $preferred)
    if (-not [string]::IsNullOrWhiteSpace($ourLetter)) {
        if ($ourLetter -eq $preferred) {
            return $preferred
        }
        if (-not $preferredTaken) {
            try { & subst.exe "${ourLetter}:" /d 2>&1 | Out-Null } catch { }
            Write-Host ("DLNA root: moved dummy subst {0}: -> preferred {1}:." -f $ourLetter, $preferred)
            return $preferred
        }
        Write-DlnaSkyboxDriveConflictWarning -PreferredLetter $preferred -ActualLetter $ourLetter
        return $ourLetter
    }
    if (-not $preferredTaken) {
        return $preferred
    }
    $free = @(Get-DlnaFreeDriveLetters)
    if ($free.Count -eq 0) {
        throw ("Drive {0}: is in use and no free D-Z letter is left for dummy DLNA subst -> {1}." -f `
            $preferred, $SubstMount)
    }
    $picked = [string]($free | Get-Random)
    Write-DlnaSkyboxDriveConflictWarning -PreferredLetter $preferred -ActualLetter $picked
    return $picked
}

function Join-DlnaNetPath {
    param(
        [Parameter(Mandatory = $true)][string] $Base,
        [Parameter(Mandatory = $true)][string] $Child
    )
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Base, $Child))
}

function Register-DlnaSubstPsDrive {
    param(
        [string] $Letter = $script:DlnaSegmentRootDriveLetter,
        [string] $MountPath = ''
    )
    $name = $Letter.TrimEnd(':')
    $mount = if (-not [string]::IsNullOrWhiteSpace($MountPath)) {
        [System.IO.Path]::GetFullPath($MountPath)
    } else {
        $fromSubst = Get-SubstDriveTarget -Letter $name
        if (-not [string]::IsNullOrWhiteSpace($fromSubst)) { $fromSubst } else { Get-DlnaSegmentRootSubstMount }
    }
    $existing = Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($null -ne $existing) { return $true }
    try {
        New-PSDrive -Name $name -PSProvider FileSystem -Root $mount -Scope Global -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Warning ("Could not register PowerShell drive {0}: ({1}). Using Win32 paths only." -f $name, $_.Exception.Message)
        return $false
    }
}

function Unregister-DlnaSubstPsDrive {
    param([string] $Letter = $script:DlnaSegmentRootDriveLetter)
    $name = $Letter.TrimEnd(':')
    if ($null -eq (Get-PSDrive -Name $name -PSProvider FileSystem -ErrorAction SilentlyContinue)) { return }
    try { Remove-PSDrive -Name $name -Force -ErrorAction SilentlyContinue } catch { }
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
            return $linkFull
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

function Remove-DlnaSegmentRootLegacyShareParents {
    <#
      After dummy letter moved F: / K: -> M:, subst mount was renamed to m1_media_dlna_subst
      but leftover f1_media\ / k1_media\ (+ old 3d_fullsbs_trans junction) can remain inside it.
      Media stay in %AppData%\3d_loop_segments (or the existing junction target); this only drops unused dummy parents.
    #>
    param([Parameter(Mandatory = $true)][string] $SubstMount)
    $mount = [System.IO.Path]::GetFullPath($SubstMount)
    foreach ($legacyParent in @($script:DlnaSegmentRootShareParentLegacyNames)) {
        if ([string]::Equals($legacyParent, $script:DlnaSegmentRootShareParent, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $legacyDir = Join-Path $mount $legacyParent
        if (-not (Test-Path -LiteralPath $legacyDir)) { continue }
        $legacyJunction = Join-Path $legacyDir '3d_fullsbs_trans'
        if (Test-Path -LiteralPath $legacyJunction) {
            try {
                $item = Get-Item -LiteralPath $legacyJunction -Force
                $isReparse = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
                if ($isReparse) {
                    cmd.exe /c rmdir "$legacyJunction" | Out-Null
                }
            } catch { }
        }
        try {
            $left = @(Get-ChildItem -LiteralPath $legacyDir -Force -ErrorAction SilentlyContinue)
            if ($left.Count -eq 0) {
                Remove-Item -LiteralPath $legacyDir -Force -ErrorAction Stop
                Write-Host ("DLNA root: removed leftover dummy parent {0}" -f $legacyDir)
            } else {
                Write-Warning ("DLNA root: leftover dummy parent still has files, left in place: {0}" -f $legacyDir)
            }
        } catch {
            Write-Warning ("DLNA root: could not remove leftover dummy parent {0}: {1}" -f $legacyDir, $_.Exception.Message)
        }
    }
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
    try {
        [void](Restore-DlnaObfuscatedMedia -Root $root)
    } catch {
        Write-Warning ("DLNA root restore obfuscated media failed: {0}" -f $_.Exception.Message)
    }
    return $root
}

function Ensure-DlnaSegmentRootDirectory {
    param([Parameter(Mandatory = $true)][string] $Root)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetFullPath($Root))
}

function Test-DlnaSubstTargetIsShareable {
    param([string] $SubstTarget)
    if ([string]::IsNullOrWhiteSpace($SubstTarget)) { return $false }
    $appData = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appData)) { $appData = $env:APPDATA }
    if ([string]::IsNullOrWhiteSpace($appData)) { return $false }
    $appFull = [System.IO.Path]::GetFullPath($appData).TrimEnd('\')
    $tgt = [System.IO.Path]::GetFullPath($SubstTarget)
    return $tgt.StartsWith($appFull, [StringComparison]::OrdinalIgnoreCase)
}

function Ensure-DlnaSegmentRoot {
    <#
    .SYNOPSIS
      Skybox path {letter}:\m1_media\3d_fullsbs_trans via dummy subst (prefer M:, same mount as 3d_playlist_local).
      Reuses an existing AppData subst instead of failing. Does not write onto a real M: volume.
      Starts the Skybox PC client if idle and maps 3d_fullsbs_trans. Log/manual cleanup passes -SkipSkyboxClient.
    #>
    param(
        [switch] $Force,
        [switch] $SkipSkyboxClient
    )
    if ($script:DlnaSegmentRootEnsured -and -not $Force.IsPresent) {
        return $script:DlnaSegmentRootDefault
    }

    $appDataRoot = Get-DlnaSegmentRootAppDataFallback
    $substMount = Get-DlnaSegmentRootSubstMount
    $wasOwned = $script:DlnaSegmentRootOwnedSubst
    $letter = Resolve-DlnaSegmentRootDriveLetter -SubstMount $substMount
    Set-DlnaSegmentRootActiveLetter -Letter $letter
    $preferred = $script:DlnaSegmentRootPreferred
    $script:DlnaSegmentRootOwnedSubst = $false
    $script:DlnaSegmentRootSharedSubst = $false

    [void][System.IO.Directory]::CreateDirectory($appDataRoot)

    $existingSubst = Get-SubstDriveTarget -Letter $letter
    $mountForShare = $substMount
    if (-not [string]::IsNullOrWhiteSpace($existingSubst)) {
        if ($existingSubst.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
            if ($wasOwned) {
                $script:DlnaSegmentRootOwnedSubst = $true
            } else {
                $script:DlnaSegmentRootSharedSubst = $true
            }
        } elseif (Test-DlnaSubstTargetIsShareable -SubstTarget $existingSubst) {
            $script:DlnaSegmentRootSharedSubst = $true
            $mountForShare = $existingSubst
        } else {
            throw ("Drive {0}: is subst'd to {1} (not under %AppData%); cannot share it for DLNA." -f `
                $letter, $existingSubst)
        }
        Write-Host ("DLNA root: reusing subst {0}: -> {1} (mode={2}); Skybox path {3}." -f `
            $letter, $existingSubst, $(if ($script:DlnaSegmentRootSharedSubst) { 'shared-subst' } else { 'appdata-subst' }), $preferred)
    } elseif (Test-DlnaSegmentRootDrivePresent -Letter $letter) {
        throw ("Drive {0}: is a real volume (not our dummy subst). Unmount it so Explorer can keep dummy {0}: -> {1}." -f `
            $letter, $substMount)
    } else {
        $substOut = & subst.exe "${letter}:" "$substMount" 2>&1
        if (-not (Test-DlnaSegmentRootDrivePresent -Letter $letter)) {
            throw ("Failed to subst dummy {0}: -> {1}: {2}" -f $letter, $substMount, $substOut)
        }
        $script:DlnaSegmentRootOwnedSubst = $true
        Write-Host ("DLNA root: dummy {0}: subst -> {1} (store %AppData%\{2}; Skybox path {3})." -f `
            $letter, $substMount, $script:DlnaSegmentRootAppDataLeaf, $preferred)
    }

    [void][System.IO.Directory]::CreateDirectory((Join-Path $mountForShare $script:DlnaSegmentRootShareParent))
    $junc = Join-Path $mountForShare $script:DlnaSegmentRootShareRelative
    if (-not (Test-Path -LiteralPath $junc)) {
        [void](Ensure-DirectoryJunction -LinkPath $junc -TargetPath $appDataRoot)
    }
    Remove-DlnaSegmentRootLegacyShareParents -SubstMount $mountForShare
    $appDataForLegacy = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace($appDataForLegacy)) { $appDataForLegacy = $env:APPDATA }
    if (-not [string]::IsNullOrWhiteSpace($appDataForLegacy)) {
        $liveSubstTargets = @((Get-SubstDriveMappings).Values)
        foreach ($legacyLeaf in @($script:DlnaSegmentRootSubstLeafLegacyNames)) {
            $legacyMount = [System.IO.Path]::GetFullPath((Join-Path $appDataForLegacy $legacyLeaf))
            if (-not (Test-Path -LiteralPath $legacyMount -PathType Container)) { continue }
            if ($legacyMount.Equals($mountForShare, [StringComparison]::OrdinalIgnoreCase) -or
                $legacyMount.Equals($substMount, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            Remove-DlnaSegmentRootLegacyShareParents -SubstMount $legacyMount
            $inUse = $false
            foreach ($tgt in $liveSubstTargets) {
                if ($legacyMount.Equals([string]$tgt, [StringComparison]::OrdinalIgnoreCase)) { $inUse = $true; break }
            }
            if ($inUse) { continue }
            try {
                $left = @(Get-ChildItem -LiteralPath $legacyMount -Force -ErrorAction SilentlyContinue)
                if ($left.Count -eq 0) {
                    Remove-Item -LiteralPath $legacyMount -Force -ErrorAction Stop
                    Write-Host ("DLNA root: removed leftover dummy subst folder {0}" -f $legacyMount)
                }
            } catch { }
        }
    }
    [void](Register-DlnaSubstPsDrive -Letter $letter -MountPath $mountForShare)

    if (-not [System.IO.Directory]::Exists($preferred)) {
        throw ("Dummy subst is mapped but preferred Skybox path is missing: {0}" -f $preferred)
    }

    if (-not $SkipSkyboxClient.IsPresent) {
        try {
            [void](Start-SkyboxPcClientIfNeeded)
        } catch {
            Write-Warning ("Skybox PC client start failed: {0}" -f $_.Exception.Message)
        }
        try {
            Sync-SkyboxDlnaShareMapping -ExpectedRoot $preferred
        } catch {
            Write-Warning ("Skybox PC client folder-mapping check failed: {0}" -f $_.Exception.Message)
        }
    }

    $mode = if ($script:DlnaSegmentRootSharedSubst) { 'shared-subst' } else { 'appdata-subst' }
    return (Complete-DlnaSegmentRootEnsure -Root $preferred -Mode $mode)
}

function Get-DlnaSegmentRoot {
    return (Ensure-DlnaSegmentRoot)
}

function Test-DlnaPlaceholderSharePath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return [bool]($Path.Trim() -match '^[A-Za-z]:\\(?:m1_media|k1_media|f1_media)\\3d_fullsbs_trans(?:\\|$)')
}

function Convert-DlnaPlaceholderSharePath {
    <#
    .SYNOPSIS
      Retarget F:\ / K:\ / M:\ (or any letter) ...\m1_media\3d_fullsbs_trans\... (also legacy k1_media / f1_media)
      to the ensured dummy letter. Custom paths are left alone.
    #>
    param([string] $Path)
    if (-not (Test-DlnaPlaceholderSharePath -Path $Path)) {
        return $Path
    }
    $ensured = Ensure-DlnaSegmentRoot
    if ($Path -match '(?i)[A-Za-z]:\\(?:m1_media|k1_media|f1_media)\\3d_fullsbs_trans(?:\\(.*))?$') {
        $rest = $Matches[1]
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return $ensured
        }
        return [System.IO.Path]::GetFullPath((Join-Path $ensured $rest))
    }
    return $ensured
}

function Remove-DlnaSegmentRootSubst {
    <#
    .SYNOPSIS
      If the session dummy letter is our AppData subst and this run created it, remove the
      3d_fullsbs_trans junction and subst {letter}: /d. Shared playlist subst is left mapped.
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
    Unregister-DlnaSubstPsDrive -Letter $letter
    if ([string]::IsNullOrWhiteSpace($substTarget)) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: no {0}: subst mapping (nothing to remove)." -f $letter)
        }
        $script:DlnaSegmentRootEnsured = $false
        $script:DlnaSegmentRootEnsureMode = ''
        $script:DlnaSegmentRootOwnedSubst = $false
        $script:DlnaSegmentRootSharedSubst = $false
        return @{ Removed = $false; Reason = 'no-subst' }
    }
    if (-not $script:DlnaSegmentRootOwnedSubst) {
        if (-not $Quiet.IsPresent) {
            Write-Host ("DLNA root subst cleanup: leaving {0}: -> {1} (shared/existing subst; this run did not create it)." -f `
                $letter, $substTarget)
        }
        $script:DlnaSegmentRootEnsured = $false
        $script:DlnaSegmentRootEnsureMode = ''
        $script:DlnaSegmentRootSharedSubst = $false
        return @{ Removed = $false; Reason = 'shared-subst'; Target = $substTarget }
    }

    $junction = [System.IO.Path]::GetFullPath((Join-Path $substMount $script:DlnaSegmentRootShareRelative))
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
    $script:DlnaSegmentRootOwnedSubst = $false
    $script:DlnaSegmentRootSharedSubst = $false
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

function Invoke-DlnaWorkflowQuitCleanup {
    <#
    .SYNOPSIS
      Idempotent workflow quit: unmap Skybox 3d_fullsbs_trans, quit Skybox only if this run started it,
      obfuscate media, then remove dummy subst if this run created it.
    #>
    param(
        [switch] $KeepLogs,
        [switch] $Quiet,
        [switch] $DryRun
    )
    if ($script:DlnaWorkflowQuitCleanupDone -and -not $DryRun.IsPresent) {
        return @{ Done = $true; Skipped = $true }
    }
    if (-not $DryRun.IsPresent) {
        $script:DlnaWorkflowQuitCleanupDone = $true
    }

    $obf = $null
    $subst = $null
    if (-not $DryRun.IsPresent) {
        try {
            Sync-SkyboxDlnaShareMapping -ExpectedRoot $script:DlnaSegmentRootPreferred -Removed
        } catch {
            Write-Warning ("Skybox PC client mapping cleanup on quit failed: {0}" -f $_.Exception.Message)
        }
        try {
            Stop-SkyboxPcClient -OnlyIfWorkflowStarted
        } catch {
            Write-Warning ("Skybox PC client quit failed: {0}" -f $_.Exception.Message)
        }
    }
    try {
        if (Get-Command Obfuscate-DlnaSegmentRootMedia -ErrorAction SilentlyContinue) {
            $obf = Obfuscate-DlnaSegmentRootMedia -KeepLogs:$KeepLogs.IsPresent -Quiet:$Quiet.IsPresent -DryRun:$DryRun.IsPresent
        }
    } catch {
        Write-Warning ("DLNA root media obfuscate on quit failed: {0}" -f $_.Exception.Message)
    }
    try {
        if (Get-Command Remove-DlnaSegmentRootSubst -ErrorAction SilentlyContinue) {
            $subst = Remove-DlnaSegmentRootSubst -Quiet:$Quiet.IsPresent -DryRun:$DryRun.IsPresent
        }
    } catch {
        Write-Warning ("DLNA root dummy subst cleanup on quit failed: {0}" -f $_.Exception.Message)
    }
    return @{ Done = $true; Skipped = $false; Obfuscate = $obf; Subst = $subst }
}

function Stop-LeafFfmpegExport {
    $pids = @(Get-LeafFfmpegProcessIds)
    $stopped = 0
    foreach ($procId in $pids) {
        try {
            & taskkill.exe /PID $procId /T /F 2>$null | Out-Null
            $stopped++
        } catch { }
    }
    $script:LeafFfmpegExportSuspended = $false
    if ($null -ne $script:LeafFfmpegSuspendedPids) {
        $script:LeafFfmpegSuspendedPids.Clear()
    }
    return $stopped
}

function Test-DlnaMediaFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    $ext = [System.IO.Path]::GetExtension($FileName)
    if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
    return $script:DlnaMediaExtensions -contains $ext.ToLowerInvariant()
}

function Get-DlnaPathRelativeToRoot {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $FullPath
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $full = [System.IO.Path]::GetFullPath($FullPath)
    if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($rootFull.Length).TrimStart('\', '/')
    }
    return [System.IO.Path]::GetFileName($FullPath)
}

function Test-DlnaObfuscationMapLeafName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    return (
        $FileName.Equals($script:DlnaObfuscationMapLeaf, [StringComparison]::OrdinalIgnoreCase) -or
        $FileName.Equals($script:DlnaObfuscationMapLeafShared, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-DlnaObfuscationMapPath {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $Shared
    )
    $leaf = if ($Shared.IsPresent) { $script:DlnaObfuscationMapLeafShared } else { $script:DlnaObfuscationMapLeaf }
    return (Join-DlnaNetPath -Base $Root -Child $leaf)
}

function Get-DlnaObfuscationMapKeyBytes {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:DlnaObfuscationMapKeyMaterial))
    } finally {
        $sha.Dispose()
    }
}

function Protect-DlnaObfuscationMapText {
    param([Parameter(Mandatory = $true)][string] $PlainText)
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $key = Get-DlnaObfuscationMapKeyBytes
    $out = New-Object byte[] $plainBytes.Length
    for ($i = 0; $i -lt $plainBytes.Length; $i++) {
        $out[$i] = $plainBytes[$i] -bxor $key[$i % $key.Length]
    }
    return ($script:DlnaObfuscationMapMagic + [Convert]::ToBase64String($out))
}

function Unprotect-DlnaObfuscationMapText {
    param([Parameter(Mandatory = $true)][string] $ProtectedText)
    $raw = $ProtectedText.Trim()
    if (-not $raw.StartsWith($script:DlnaObfuscationMapMagic, [StringComparison]::Ordinal)) {
        return $null
    }
    $b64 = $raw.Substring($script:DlnaObfuscationMapMagic.Length)
    try {
        $bytes = [Convert]::FromBase64String($b64)
    } catch {
        return $null
    }
    $key = Get-DlnaObfuscationMapKeyBytes
    $out = New-Object byte[] $bytes.Length
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $out[$i] = $bytes[$i] -bxor $key[$i % $key.Length]
    }
    return [System.Text.Encoding]::UTF8.GetString($out)
}

function ConvertFrom-DlnaObfuscationMapJson {
    param([Parameter(Mandatory = $true)][string] $JsonText)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $map }
    $doc = $JsonText | ConvertFrom-Json
    if ($null -eq $doc) { return $map }
    foreach ($p in $doc.PSObject.Properties) {
        if ([string]::IsNullOrWhiteSpace($p.Name) -or $null -eq $p.Value) { continue }
        $map[[string]$p.Name] = [string]$p.Value
    }
    return $map
}

function Read-DlnaObfuscationMapFromFile {
    param([Parameter(Mandatory = $true)][string] $Path)
    $result = @{ Map = @{}; Parsed = $false; Exists = $false }
    if (-not [System.IO.File]::Exists($Path)) { return $result }
    $result.Exists = $true
    try {
        $raw = [System.IO.File]::ReadAllText($Path)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $result.Parsed = $true
            return $result
        }
        $json = Unprotect-DlnaObfuscationMapText -ProtectedText $raw
        if ([string]::IsNullOrWhiteSpace($json)) {
            if ($raw.TrimStart().StartsWith('{')) { $json = $raw } else { return $result }
        }
        $jsonTrim = $json.TrimStart()
        if (-not ($jsonTrim.StartsWith('{') -or $jsonTrim.StartsWith('['))) { return $result }
        $map = ConvertFrom-DlnaObfuscationMapJson -JsonText $json
        $result.Map = $map
        $result.Parsed = $true
    } catch { }
    return $result
}

function Read-DlnaObfuscationMap {
    param([Parameter(Mandatory = $true)][string] $Root)
    $script:DlnaObfuscationSharedMapParsed = $false
    $map = @{}
    $own = Read-DlnaObfuscationMapFromFile -Path (Get-DlnaObfuscationMapPath -Root $Root)
    $shared = Read-DlnaObfuscationMapFromFile -Path (Get-DlnaObfuscationMapPath -Root $Root -Shared)
    if ($own.Parsed) {
        foreach ($k in @($own.Map.Keys)) { $map[$k] = $own.Map[$k] }
    }
    if ($shared.Parsed) {
        $script:DlnaObfuscationSharedMapParsed = $true
        foreach ($k in @($shared.Map.Keys)) {
            if (-not $map.ContainsKey($k)) { $map[$k] = $shared.Map[$k] }
        }
    }
    return $map
}

function Write-DlnaObfuscationMap {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)]$Map,
        [switch] $DryRun
    )
    $path = Get-DlnaObfuscationMapPath -Root $Root
    $sharedPath = Get-DlnaObfuscationMapPath -Root $Root -Shared
    if ($DryRun.IsPresent) { return }
    if ($null -eq $Map -or $Map.Count -eq 0) {
        if ([System.IO.File]::Exists($path)) {
            try { [System.IO.File]::Delete($path) } catch { }
        }
        return
    }
    $ordered = [ordered]@{}
    foreach ($key in @($Map.Keys | Sort-Object)) {
        $ordered[$key] = $Map[$key]
    }
    $json = $ordered | ConvertTo-Json -Compress
    $scrambled = Protect-DlnaObfuscationMapText -PlainText $json
    $dir = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($dir)) {
        [void][System.IO.Directory]::CreateDirectory($dir)
    }
    [System.IO.File]::WriteAllText($path, $scrambled)
    if ($script:DlnaObfuscationSharedMapParsed -and [System.IO.File]::Exists($sharedPath)) {
        try { [System.IO.File]::Delete($sharedPath) } catch { }
        $script:DlnaObfuscationSharedMapParsed = $false
    }
}

function Get-DlnaContentHashLeaf {
    param([Parameter(Mandatory = $true)][string] $RelativeClearPath)
    $norm = (($RelativeClearPath -replace '/', '\').Trim().ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm))
    } finally {
        $sha.Dispose()
    }
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return ($hex + $script:DlnaObfuscationTmpSuffix)
}

function Test-DlnaHashTmpFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    return [bool]($FileName -match '^[0-9a-fA-F]{16,64}(_v)?\.tmp$')
}

function Test-DlnaLegacyObfuscatedFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    if (-not $FileName.StartsWith($script:DlnaObfuscationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ($FileName.EndsWith($script:DlnaObfuscationSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return (Test-DlnaMediaFileName -FileName $FileName)
}

function Test-DlnaObfuscatedFileName {
    param([Parameter(Mandatory = $true)][string] $FileName)
    if (Test-DlnaHashTmpFileName -FileName $FileName) { return $true }
    return (Test-DlnaLegacyObfuscatedFileName -FileName $FileName)
}

function Get-DlnaLegacyUnobfuscatedLeafName {
    param([Parameter(Mandatory = $true)][string] $LeafName)
    if (-not $LeafName.StartsWith($script:DlnaObfuscationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $LeafName
    }
    $mid = $LeafName.Substring($script:DlnaObfuscationPrefix.Length)
    if ($mid.EndsWith($script:DlnaObfuscationSuffix, [StringComparison]::OrdinalIgnoreCase)) {
        return $mid.Substring(0, $mid.Length - $script:DlnaObfuscationSuffix.Length)
    }
    return $mid
}

function Test-DlnaLogPath {
    param([Parameter(Mandatory = $true)][string] $FullPath)
    if ($FullPath -match '(?i)[\\/]logs[\\/]') { return $true }
    return ([System.IO.Path]::GetExtension($FullPath) -eq '.log')
}

function Clear-DlnaPathBestEffort {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $DryRun
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }
    if ($DryRun.IsPresent) { return 'dry-run' }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return 'deleted'
    } catch {
        try {
            $fs = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Truncate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::Read
            )
            $fs.Close()
            $fs.Dispose()
            return 'truncated'
        } catch {
            return 'failed'
        }
    }
}

function Rename-DlnaPathBestEffort {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $DestinationLeaf,
        [switch] $DryRun
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
        return 'missing'
    }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $dest = [System.IO.Path]::Combine($dir, $DestinationLeaf)
    if ($Path.Equals($dest, [StringComparison]::OrdinalIgnoreCase)) {
        return 'unchanged'
    }
    if ($DryRun.IsPresent) { return 'dry-run' }
    try {
        if ([System.IO.File]::Exists($dest)) {
            [System.IO.File]::Delete($dest)
        }
        [System.IO.File]::Move($Path, $dest)
        return 'renamed'
    } catch {
        return 'failed'
    }
}

function Test-DlnaRelativePathIsSharedPlaylistSegmentDir {
    param([string] $RelativePath)
    if (-not $script:DlnaSegmentRootSharedSubst) { return $false }
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    $rel = (($RelativePath -replace '/', '\').TrimStart('\'))
    $first = ($rel -split '\\', 2)[0]
    return @('flat', 'fisheye', 'hybrid') -contains $first.ToLowerInvariant()
}

function Get-DlnaObfuscationCandidateFiles {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [switch] $ObfuscatedNamesOnly
    )
    $out = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if (-not [System.IO.Directory]::Exists($Root)) { return @() }
    $paths = @()
    try {
        $paths = [System.IO.Directory]::EnumerateFiles($Root, '*', [System.IO.SearchOption]::AllDirectories)
    } catch {
        return @()
    }
    foreach ($fp in $paths) {
        $name = [System.IO.Path]::GetFileName($fp)
        if (Test-DlnaObfuscationMapLeafName -FileName $name) { continue }
        if ($ObfuscatedNamesOnly.IsPresent -and -not (Test-DlnaObfuscatedFileName -FileName $name)) { continue }
        $rel = Get-DlnaPathRelativeToRoot -Root $Root -FullPath $fp
        if (Test-DlnaRelativePathIsSharedPlaylistSegmentDir -RelativePath $rel) { continue }
        $out.Add((New-Object System.IO.FileInfo($fp)))
    }
    return @($out.ToArray())
}

function Resolve-DlnaHashTmpClearRelative {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][System.IO.FileInfo] $HashFile,
        [Parameter(Mandatory = $true)]$Map
    )
    $relObf = Get-DlnaPathRelativeToRoot -Root $Root -FullPath $HashFile.FullName
    if ($Map.ContainsKey($relObf)) {
        $mapped = [string]$Map[$relObf]
        if (-not [string]::IsNullOrWhiteSpace($mapped)) { return $mapped }
    }
    foreach ($k in @($Map.Keys)) {
        if ([System.IO.Path]::GetFileName([string]$k).Equals($HashFile.Name, [StringComparison]::OrdinalIgnoreCase)) {
            $mapped = [string]$Map[$k]
            if (-not [string]::IsNullOrWhiteSpace($mapped)) { return $mapped }
        }
    }
    $dir = $HashFile.DirectoryName
    $want = $HashFile.Name
    $tryRels = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($sib in [System.IO.Directory]::EnumerateFiles($dir)) {
            $leaf = [System.IO.Path]::GetFileName($sib)
            if (Test-DlnaHashTmpFileName -FileName $leaf) { continue }
            if (Test-DlnaObfuscationMapLeafName -FileName $leaf) { continue }
            if (-not (Test-DlnaMediaFileName -FileName $leaf)) { continue }
            $tryRels.Add((Get-DlnaPathRelativeToRoot -Root $Root -FullPath $sib))
        }
    } catch { }
    foreach ($leaf in @('3d_op_00.mkv', '3d_op_01.mkv')) {
        $tryRels.Add((Get-DlnaPathRelativeToRoot -Root $Root -FullPath ([System.IO.Path]::Combine($dir, $leaf))))
    }
    $seen = @{}
    foreach ($clearRel in $tryRels) {
        if ([string]::IsNullOrWhiteSpace($clearRel)) { continue }
        $key = $clearRel.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ((Get-DlnaContentHashLeaf -RelativeClearPath $clearRel).Equals($want, [StringComparison]::OrdinalIgnoreCase)) {
            return $clearRel
        }
    }
    return $null
}

function Restore-DlnaObfuscatedMedia {
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $Quiet
    )
    $rootFull = $null
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $rootFull = [System.IO.Path]::GetFullPath($Root)
    } elseif ($script:DlnaSegmentRootEnsured -and -not [string]::IsNullOrWhiteSpace($script:DlnaSegmentRootDefault)) {
        $rootFull = $script:DlnaSegmentRootDefault
    } else {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $restored = 0
    $overwritten = 0
    $skipped = 0
    $failed = 0
    if (-not [System.IO.Directory]::Exists($rootFull)) {
        return @{ Root = $rootFull; Restored = 0; Overwritten = 0; Skipped = 0; Failed = 0 }
    }

    $map = Read-DlnaObfuscationMap -Root $rootFull
    $mapDirty = $false
    $files = @(Get-DlnaObfuscationCandidateFiles -Root $rootFull -ObfuscatedNamesOnly)

    foreach ($f in $files) {
        $relObf = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath $f.FullName
        $clearRel = $null
        $clearLeaf = $null
        $destDir = $f.DirectoryName

        if (Test-DlnaHashTmpFileName -FileName $f.Name) {
            $clearRel = Resolve-DlnaHashTmpClearRelative -Root $rootFull -HashFile $f -Map $map
            if ([string]::IsNullOrWhiteSpace($clearRel)) {
                $skipped++
                continue
            }
            $clearLeaf = [System.IO.Path]::GetFileName($clearRel)
            $clearParent = [System.IO.Path]::GetDirectoryName($clearRel)
            if (-not [string]::IsNullOrWhiteSpace($clearParent)) {
                $destDir = Join-DlnaNetPath -Base $rootFull -Child $clearParent
                if (-not $DryRun.IsPresent -and -not [System.IO.Directory]::Exists($destDir)) {
                    [void][System.IO.Directory]::CreateDirectory($destDir)
                }
            }
        } else {
            $clearLeaf = Get-DlnaLegacyUnobfuscatedLeafName -LeafName $f.Name
            $clearRel = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath ([System.IO.Path]::Combine($f.DirectoryName, $clearLeaf))
        }

        if ([string]::IsNullOrWhiteSpace($clearLeaf)) {
            $skipped++
            continue
        }

        $dest = [System.IO.Path]::Combine($destDir, $clearLeaf)
        $destExisted = [System.IO.File]::Exists($dest)

        if ($destDir.Equals($f.DirectoryName, [StringComparison]::OrdinalIgnoreCase)) {
            $action = Rename-DlnaPathBestEffort -Path $f.FullName -DestinationLeaf $clearLeaf -DryRun:$DryRun.IsPresent
        } elseif ($DryRun.IsPresent) {
            $action = 'dry-run'
        } else {
            try {
                if ($destExisted) { [System.IO.File]::Delete($dest) }
                [System.IO.File]::Move($f.FullName, $dest)
                $action = 'renamed'
            } catch {
                $action = 'failed'
            }
        }

        switch ($action) {
            { $_ -in @('renamed', 'dry-run') } {
                $restored++
                if ($destExisted) { $overwritten++ }
                if ($map.ContainsKey($relObf)) {
                    $map.Remove($relObf)
                    $mapDirty = $true
                }
            }
            { $_ -in @('unchanged', 'missing') } { $skipped++ }
            default { $failed++ }
        }
    }

    if ($mapDirty) {
        Write-DlnaObfuscationMap -Root $rootFull -Map $map -DryRun:$DryRun.IsPresent
    }

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would restore' } else { 'restored' }
        Write-Host ("DLNA root {0} obfuscated media: {1} (restored={2}, overwritten={3}, skipped={4}, failed={5})" -f `
            $verb, $rootFull, $restored, $overwritten, $skipped, $failed)
    }

    return @{
        Root        = $rootFull
        Restored    = $restored
        Overwritten = $overwritten
        Skipped     = $skipped
        Failed      = $failed
    }
}

function Obfuscate-DlnaSegmentRootMedia {
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $NoStopLeafExport,
        [switch] $Quiet,
        [switch] $KeepLogs
    )
    $rootFull = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Root)) {
            $rootFull = Ensure-DlnaSegmentRoot -SkipSkyboxClient
        } else {
            $rootFull = [System.IO.Path]::GetFullPath($Root)
        }
    } catch {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $obfuscated = 0
    $deleted = 0
    $truncated = 0
    $failed = 0
    $stopped = 0
    $keptLogs = 0
    $skipped = 0

    if (-not $NoStopLeafExport.IsPresent -and -not $DryRun.IsPresent) {
        try { $stopped = [int](Stop-LeafFfmpegExport) } catch { $stopped = 0 }
    }

    if (-not [System.IO.Directory]::Exists($rootFull)) {
        if (-not $DryRun.IsPresent) {
            try { Ensure-DlnaSegmentRootDirectory -Root $rootFull } catch { }
        }
        return @{
            Root       = $rootFull
            Obfuscated = 0
            Deleted    = 0
            Truncated  = 0
            Failed     = 0
            Stopped    = $stopped
            KeptLogs   = 0
            Skipped    = 0
        }
    }

    $map = Read-DlnaObfuscationMap -Root $rootFull
    $mapDirty = $false
    $files = @(Get-DlnaObfuscationCandidateFiles -Root $rootFull)
    foreach ($f in $files) {
        if (Test-DlnaLogPath -FullPath $f.FullName) {
            if ($KeepLogs.IsPresent) {
                $keptLogs++
                continue
            }
            $action = Clear-DlnaPathBestEffort -Path $f.FullName -DryRun:$DryRun.IsPresent
            switch ($action) {
                'deleted' { $deleted++ }
                'truncated' { $truncated++ }
                'dry-run' { $deleted++ }
                'failed' { $failed++ }
            }
            continue
        }

        if (Test-DlnaHashTmpFileName -FileName $f.Name) {
            $skipped++
            continue
        }

        $clearLeaf = $f.Name
        $isLegacy = Test-DlnaLegacyObfuscatedFileName -FileName $f.Name
        if ($isLegacy) {
            $clearLeaf = Get-DlnaLegacyUnobfuscatedLeafName -LeafName $f.Name
        } elseif (-not (Test-DlnaMediaFileName -FileName $f.Name)) {
            $skipped++
            continue
        }

        $clearFullForHash = if ($isLegacy) {
            [System.IO.Path]::Combine($f.DirectoryName, $clearLeaf)
        } else {
            $f.FullName
        }
        $clearRel = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath $clearFullForHash
        $obfLeaf = Get-DlnaContentHashLeaf -RelativeClearPath $clearRel
        if ($obfLeaf.Equals($f.Name, [StringComparison]::OrdinalIgnoreCase)) {
            $skipped++
            continue
        }

        $action = Rename-DlnaPathBestEffort -Path $f.FullName -DestinationLeaf $obfLeaf -DryRun:$DryRun.IsPresent
        switch ($action) {
            { $_ -in @('renamed', 'dry-run') } {
                $obfuscated++
                $relObf = Get-DlnaPathRelativeToRoot -Root $rootFull -FullPath ([System.IO.Path]::Combine($f.DirectoryName, $obfLeaf))
                $map[$relObf] = $clearRel
                $mapDirty = $true
            }
            { $_ -in @('unchanged', 'missing') } { $skipped++ }
            default { $failed++ }
        }
    }

    if ($mapDirty) {
        Write-DlnaObfuscationMap -Root $rootFull -Map $map -DryRun:$DryRun.IsPresent
    }

    if (-not $DryRun.IsPresent) {
        try { Ensure-DlnaSegmentRootDirectory -Root $rootFull } catch { }
    }

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would obfuscate' } else { 'obfuscated' }
        $logNote = if ($KeepLogs.IsPresent) { ", kept_logs=$keptLogs" } else { ", logs_deleted=$deleted, logs_truncated=$truncated" }
        Write-Host ("DLNA root {0} media: {1} (obfuscated={2}, failed={3}, skipped={4}, stopped_leaf_ffmpeg={5}{6})" -f `
            $verb, $rootFull, $obfuscated, $failed, $skipped, $stopped, $logNote)
    }

    return @{
        Root       = $rootFull
        Obfuscated = $obfuscated
        Deleted    = $deleted
        Truncated  = $truncated
        Failed     = $failed
        Stopped    = $stopped
        KeptLogs   = $keptLogs
        Skipped    = $skipped
    }
}

function Clear-DlnaSegmentRootContents {
    param(
        [string] $Root = '',
        [switch] $DryRun,
        [switch] $NoStopLeafExport,
        [switch] $Quiet,
        [switch] $KeepLogs
    )
    $rootFull = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Root)) {
            $rootFull = Ensure-DlnaSegmentRoot -SkipSkyboxClient
        } else {
            $rootFull = [System.IO.Path]::GetFullPath($Root)
        }
    } catch {
        $rootFull = $script:DlnaSegmentRootPreferred
    }

    $deleted = 0
    $truncated = 0
    $failed = 0
    $stopped = 0
    $keptLogs = 0

    if (-not $NoStopLeafExport.IsPresent -and -not $DryRun.IsPresent) {
        try { $stopped = [int](Stop-LeafFfmpegExport) } catch { $stopped = 0 }
    }

    if (-not [System.IO.Directory]::Exists($rootFull)) {
        if (-not $DryRun.IsPresent) {
            try { Ensure-DlnaSegmentRootDirectory -Root $rootFull } catch { }
        }
        return @{
            Root      = $rootFull
            Deleted   = 0
            Truncated = 0
            Failed    = 0
            Stopped   = $stopped
            KeptLogs  = 0
        }
    }

    $files = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if ($KeepLogs.IsPresent -and (Test-DlnaLogPath -FullPath $f.FullName)) {
            $keptLogs++
            continue
        }
        $action = Clear-DlnaPathBestEffort -Path $f.FullName -DryRun:$DryRun.IsPresent
        switch ($action) {
            'deleted' { $deleted++ }
            'truncated' { $truncated++ }
            'dry-run' { $deleted++ }
            'failed' { $failed++ }
        }
    }

    if (-not $DryRun.IsPresent) {
        try { Ensure-DlnaSegmentRootDirectory -Root $rootFull } catch { }
    }

    if (-not $Quiet.IsPresent) {
        $verb = if ($DryRun.IsPresent) { 'would clear' } else { 'cleared' }
        Write-Host ("DLNA root {0} contents: {1} (deleted={2}, truncated={3}, failed={4}, stopped_leaf_ffmpeg={5}, kept_logs={6})" -f `
            $verb, $rootFull, $deleted, $truncated, $failed, $stopped, $keptLogs)
    }

    return @{
        Root      = $rootFull
        Deleted   = $deleted
        Truncated = $truncated
        Failed    = $failed
        Stopped   = $stopped
        KeptLogs  = $keptLogs
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
