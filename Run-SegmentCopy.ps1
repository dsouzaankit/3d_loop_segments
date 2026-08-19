#Requires -Version 5.1
<#
.SYNOPSIS
  Remux input into two rotating segment MKVs (`3d_op_%02d.mkv`) using **stream copy** (`-c copy`) and **realtime read** (`-re`). PotPlayer RememberFiles `-ss` seek is preserved. Encode/decode tuning parameters (**TargetMbps**, **EncoderPreset**, **OutputLongEdgeCapPx**, **SkipSourceDecodeFrames**, **InputReadrate**) are **deprecated and ignored** (kept for Explorer command-line compatibility).
  Optional DLNA idle stop: -DlnaIdleStopMinutes or -DlnaIdleStopSeconds (> 0) enables monitoring (use **0** to disable). Default: **Wi-Fi only** outbound Mbps — cumulative bytes sampled every **30s**; ffmpeg stops **as soon as** **all five** consecutive **60s** averages in the last **5 minutes** are **strictly < `-DlnaIdleUploadMbpsThreshold`** (default **5** Mbps). Until **~305s** of samples exist, `w0`–`w4` stay **`n/a`** (condition not evaluated). **`-DlnaIdleStopMinutes` / `-DlnaIdleStopSeconds`** do not add delay in Wi-Fi mode (legacy `-DlnaIdleLegacyLastAccess` still uses idle duration). Deprecated: -DlnaIdleLegacyLastAccess uses NTFS LastAccessTime on segment files (see README).
  Matches sibling PotPlayer RememberFiles defaults: `-ss`, `F:\f1_media\3d_fullsbs_trans` output
  (Skybox DLNA path; when F: is missing, files live under %AppData%\3d_loop_segments and F: is subst'd for the run),
  two rotating segment files (`3d_op_%02d.mkv`).

.NOTES
  README.md: mapped-network input can bottleneck reads; DLNA idle (default Wi-Fi Mbps heuristic) is experimental.
  Console: Space pauses/resumes the segment remux (3d_op_*.mkv) via NtSuspend/NtResume; Enter stops ffmpeg and exits (130).
  DLNA Wi-Fi idle and run timeout (3600s) keep ticking while Space-paused; idle kill (~305s sample history + five low Mbps windows) is independent of ffmpeg suspend.
  DLNA root: F:\f1_media\3d_fullsbs_trans is always AppData-backed with subst F: for the run. On quit: Obfuscate-DlnaSegmentRootMedia (rename segments to sha256.tmp + .dlna_obf_map.json), then Remove-DlnaSegmentRootSubst; startup restores via Ensure-DlnaSegmentRoot.

.PARAMETER LiteralPath
  Input file (Explorer passes %L expanded).

.PARAMETER TargetMbps
  **Deprecated (ignored).** Retained for context-menu compatibility; this path uses stream copy, not CBR video encode.

.PARAMETER OutputDirectory
  Default: F:\f1_media\3d_fullsbs_trans (Skybox DLNA share path; same default as the sibling project's ffmpeg segment launcher).
  Recreated via %AppData%\3d_loop_segments + subst F: (physical F: is not used).

.PARAMETER SsMsOverride
  Seek ms when >= 0; default -1 uses RememberFiles registry for this path.

.PARAMETER ContextMenu
  Set by Install-ContextMenu.Production.ps1 / Install-ContextMenu.DlnaTest.ps1 (informational).

.PARAMETER NoPause
  Skip final 5s wait.

.PARAMETER NoClampSeek
  Do not skip the remux run when resume seek is past ffprobe duration tail.

.PARAMETER DryRun
  Print ffmpeg command only.

.PARAMETER DlnaIdleStopMinutes
  If **> 0** (and DlnaIdleStopSeconds is 0), enables DLNA idle monitoring (exit **125** when idle fires). Ignored if DlnaIdleStopSeconds > 0. **Default: 5** (use **0** to disable). **Wi-Fi Mbps mode:** minutes value does **not** delay the stop; ffmpeg exits **immediately** on the first poll where all five minute windows are **strictly <** `-DlnaIdleUploadMbpsThreshold`. **Legacy LastAccess mode:** this is the idle duration before stop.
  Default (no -DlnaIdleLegacyLastAccess): Wi-Fi outbound heuristic (see -DlnaIdleUploadMbpsThreshold). Legacy mode polls LastAccessTime every 30s.
  Experimental; see README.md. Logs under segmentcopy_logs/dlna_wifi_upload_<PID>.log (default) or dlna_lastaccess_<PID>.log (legacy).

.PARAMETER DlnaIdleStopSeconds
  If **> 0**, enables monitoring and takes precedence over DlnaIdleStopMinutes. **Wi-Fi Mbps mode:** seconds value does **not** delay the stop (immediate when all five windows are strictly < threshold). **Legacy LastAccess:** idle duration in seconds.
  Exit 125 when stopped for idle. Default Wi-Fi mode samples cumulative bytes every 30s. Legacy LastAccess mode requires fsutil last-access when that switch is set.

.PARAMETER DlnaIdleUploadMbpsThreshold
  Used with default DLNA idle (Wi-Fi only): when **all five** consecutive **60-second** windows in the last **5 minutes** have average outbound Mbps **strictly less than** this value on a poll, ffmpeg stops **immediately** (exit **125**). Default **5** when idle stop is enabled and this is omitted or 0 (unless -DlnaIdleLegacyLastAccess). Other Wi-Fi traffic counts.

.PARAMETER DlnaIdleLegacyLastAccess
  Deprecated: use NTFS LastAccessTime on segment files instead of the Wi-Fi Mbps heuristic. Requires fsutil last-access updates; unreliable (see README).

.PARAMETER InputReadrate
  **Deprecated (ignored).** This script always uses **-re** before `-i` for realtime read pacing (no `-readrate`).

.PARAMETER SkipSourceDecodeFrames
  **Deprecated (ignored).** Stream copy does not use `-skip_frame`.

.PARAMETER EncoderPreset
  **Deprecated (ignored).** No QSV (or any) video encoder in the stream-copy path.

.PARAMETER OutputLongEdgeCapPx
  **Deprecated (ignored).** Rescaling requires re-encode; not compatible with `-c copy`.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $LiteralPath,
    [int] $TargetMbps = 100,
    [string] $OutputDirectory = 'F:\f1_media\3d_fullsbs_trans',
    [int] $SsMsOverride = -1,
    [string] $Ffmpeg = 'ffmpeg',
    [string] $LogFile = '',
    [switch] $NoLogFile,
    [switch] $DryRun,
    [switch] $NoPause,
    [switch] $ContextMenu,
    [switch] $NoClampSeek,
    [int] $DlnaIdleStopMinutes = 5,
    [int] $DlnaIdleStopSeconds = 0,
    [switch] $DlnaIdleLegacyLastAccess,
    [double] $DlnaIdleUploadMbpsThreshold = 5,
    [double] $InputReadrate = 0,
    [ValidateSet('Prompt', 'None', 'Bidir', 'Noref', '0', '1', '2')]
    [string] $SkipSourceDecodeFrames = 'Prompt',
    [ValidateSet('veryslow', 'slower', 'slow', 'medium', 'fast', 'faster', 'veryfast')]
    [string] $EncoderPreset = 'veryfast',
    [int] $OutputLongEdgeCapPx = 0
)

$ErrorActionPreference = 'Stop'

if ($TargetMbps -lt 0 -or $TargetMbps -gt 300) {
    throw "TargetMbps must be 0-300 (got $TargetMbps)."
}
if ($DlnaIdleStopMinutes -lt 0) {
    throw "DlnaIdleStopMinutes must be >= 0 (got $DlnaIdleStopMinutes)."
}
if ($DlnaIdleStopSeconds -lt 0) {
    throw "DlnaIdleStopSeconds must be >= 0 (got $DlnaIdleStopSeconds)."
}
if ($DlnaIdleUploadMbpsThreshold -lt 0) {
    throw "DlnaIdleUploadMbpsThreshold must be >= 0 (got $DlnaIdleUploadMbpsThreshold)."
}
if (($DlnaIdleStopMinutes -gt 0 -or $DlnaIdleStopSeconds -gt 0) -and -not $DlnaIdleLegacyLastAccess -and $DlnaIdleUploadMbpsThreshold -le 0) {
    $DlnaIdleUploadMbpsThreshold = 5
}
if ($InputReadrate -lt 0) {
    throw "InputReadrate must be >= 0 (got $InputReadrate)."
}
if ($OutputLongEdgeCapPx -lt 0) {
    throw "OutputLongEdgeCapPx must be >= 0 (got $OutputLongEdgeCapPx)."
}

$thisScriptPath = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    [System.IO.Path]::GetFullPath($PSCommandPath)
} else {
    [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
}

# Same two-file `3d_op_%02d.mkv` wrap as the sibling project's ffmpeg segment launcher
$HardcodedOutputFilePattern = '3d_op_%02d.mkv'
$InstanceMutexName = 'Local\FfmpegSegmentCopy3dOpSegmentJobLock'
$RunLogMaxBytes = 2L * 1024L * 1024L
# Mutex wait + ffmpeg wall clock (1 hour)
$RunTimeoutSeconds = 3600
$script:ExitCodeTimeout = 124
$script:ExitCodeDlnaIdle = 125
$script:ExitCodeUserCancel = 130
$script:ConsoleHeartbeatSeconds = 30

$leafFfmpegControlScript = Join-Path ([System.IO.Path]::GetDirectoryName($thisScriptPath)) 'Invoke-LeafFfmpegControl.ps1'
if (Test-Path -LiteralPath $leafFfmpegControlScript -PathType Leaf) {
    . $leafFfmpegControlScript
}
# Min span (seconds) of byte samples required to compute five 60s Mbps windows (last 5 minutes).
$DlnaWifiFiveWindowHistorySeconds = 305.0

function Normalize-MatchPath {
    param([string] $P)
    if ([string]::IsNullOrWhiteSpace($P)) { return '' }
    try {
        return [System.IO.Path]::GetFullPath($P).ToLowerInvariant()
    } catch {
        return $P.Trim().ToLowerInvariant()
    }
}

function ConvertFrom-RememberLine {
    param([object] $Data)
    if ($null -eq $Data) { return $null }
    [string] $s = $null
    if ($Data -is [byte[]]) {
        $b = [byte[]]$Data
        if ($b.Length -eq 0) { return $null }
        try {
            $s = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0)
        } catch {
            $s = [Text.Encoding]::UTF8.GetString($b)
        }
    } else {
        $s = [string]$Data
    }
    $s = $s.Trim()
    if ($s -notmatch '^(\d+)=(.*)$') { return $null }
    return @{
        Ms   = [int64]$Matches[1]
        Path = $Matches[2].Trim().Trim('"')
    }
}

function Get-RememberEntries {
    $list = New-Object System.Collections.Generic.List[object]
    $rememberFilesRegistryPath = 'SOFTWARE\DAUM\PotPlayerMini64\RememberFiles'
    $reg = $null
    try {
        $reg = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($rememberFilesRegistryPath)
        if (-not $reg) { return $list }

        foreach ($name in $reg.GetValueNames()) {
            if ($name -eq 'MRUList') { continue }
            $val = $reg.GetValue($name)
            $parsed = ConvertFrom-RememberLine $val
            if ($parsed) { [void]$list.Add($parsed) }
        }

        foreach ($skName in $reg.GetSubKeyNames()) {
            $sk = $reg.OpenSubKey($skName)
            if ($sk) {
                try {
                    $val = $sk.GetValue('', $null)
                    $parsed = ConvertFrom-RememberLine $val
                    if ($parsed) { [void]$list.Add($parsed) }
                } finally {
                    $sk.Dispose()
                }
            }
        }
    } finally {
        if ($reg) { $reg.Dispose() }
    }
    return $list
}

function Get-SeekMsForRememberedPath {
    param([string] $TargetPath)
    $want = Normalize-MatchPath $TargetPath
    $bestMs = 0L
    $bestLen = -1
    foreach ($e in Get-RememberEntries) {
        if ((Normalize-MatchPath $e.Path) -eq $want) {
            $len = $e.Path.Length
            if ($len -gt $bestLen) {
                $bestLen = $len
                $bestMs = $e.Ms
            }
        }
    }
    return [Math]::Max(0L, $bestMs)
}

function Get-DigitFromConsoleKeyInfo {
    [OutputType([Nullable[int]])]
    param([System.ConsoleKeyInfo] $KeyInfo)
    $c = $KeyInfo.KeyChar
    if ($c -ge [char]'0' -and $c -le [char]'9') {
        return [int]$c - [int][char]'0'
    }
    $k = $KeyInfo.Key
    if ($k -ge [ConsoleKey]::D0 -and $k -le [ConsoleKey]::D9) {
        return [int]$k - [int][ConsoleKey]::D0
    }
    if ($k -ge [ConsoleKey]::NumPad0 -and $k -le [ConsoleKey]::NumPad9) {
        return [int]$k - [int][ConsoleKey]::NumPad0
    }
    return $null
}

function Get-QuickSeekOverrideMs {
    [OutputType([Nullable[int64]])]
    param()
    Write-Host 'Quick seek override: press 0/1/2/3/4 within 5s for 0/10/15/30/45 min (or wait for registry resume).'
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                $d = Get-DigitFromConsoleKeyInfo $key
                if ($null -eq $d) { continue }
                switch ($d) {
                    0 { return 0L }
                    1 { return 10L * 60L * 1000L }
                    2 { return 15L * 60L * 1000L }
                    3 { return 30L * 60L * 1000L }
                    4 { return 45L * 60L * 1000L }
                    default { }
                }
            }
        } catch {
            return $null
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Get-FfprobeExePath {
    param([string] $FfmpegExe)
    $dir = [System.IO.Path]::GetDirectoryName($FfmpegExe)
    $candidate = Join-Path $dir 'ffprobe.exe'
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-FormatDurationSeconds {
    param([string] $MediaPath, [string] $FfprobeExe)
    $raw = & $FfprobeExe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- $MediaPath 2>$null
    $s = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
    if ($s -eq '' -or $s -eq 'N/A') { return $null }
    $n = 0.0
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $null
    }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -le 0) { return $null }
    return $n
}

function Get-RemainingTimeoutMs {
    param([datetime] $TimeoutAtUtc)
    $remaining = [int64][Math]::Floor(($TimeoutAtUtc - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -lt 0) { return 0 }
    if ($remaining -gt [int64][int]::MaxValue) { return [int]::MaxValue }
    return [int]$remaining
}

function Test-FsutilLastAccessTimeUpdatesEnabled {
    try {
        $lines = @(cmd /c "fsutil behavior query disablelastaccess" 2>$null)
        $txt = ($lines | Out-String)
        if ($txt -match 'DisableLastAccess\s*=\s*(\d+)') {
            $v = [int]$Matches[1]
            if ($v -eq 1 -or $v -eq 3) { return $false }
            return $true
        }
    } catch { }
    return $true
}

function Get-SegmentPairLastAccessState {
    param([string] $Directory)
    $last0 = $null
    $last1 = $null
    $names = @('3d_op_00.mkv', '3d_op_01.mkv')
    for ($i = 0; $i -lt $names.Length; $i++) {
        $p = Join-Path $Directory $names[$i]
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $la = (Get-Item -LiteralPath $p -Force).LastAccessTimeUtc
            if ($i -eq 0) { $last0 = $la } else { $last1 = $la }
        } catch { }
    }
    if ($null -eq $last0 -and $null -eq $last1) { return $null }
    $maxUtc = [DateTime]::MinValue
    foreach ($t in @($last0, $last1)) {
        if ($null -ne $t -and $t -gt $maxUtc) { $maxUtc = $t }
    }
    if ($maxUtc -eq [DateTime]::MinValue) { return $null }
    return [pscustomobject]@{ MaxUtc = $maxUtc; Last0Utc = $last0; Last1Utc = $last1 }
}

function Write-DlnaLastAccessLogLine {
    param([string] $LiteralPath, [string] $Line)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return }
    try {
        $dir = [System.IO.Path]::GetDirectoryName($LiteralPath)
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void][System.IO.Directory]::CreateDirectory($dir)
        }
        Add-Content -LiteralPath $LiteralPath -Value $Line -Encoding utf8
    } catch { }
}

function Get-DlnaLogLocalTimestamp {
    return (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
}

function Get-WifiUpAdapterNames {
    [OutputType([string[]])]
    param()
    try {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                $_.Status -eq 'Up' -and (
                    $_.MediaType -eq '802.11' -or
                    ($_.PhysicalMediaType -match '802\.11|Wireless|Wi-?Fi|WLAN')
                )
            })
        if ($adapters.Count -eq 0) { return @() }
        return @($adapters | ForEach-Object { $_.Name } | Sort-Object -Unique)
    } catch {
        return @()
    }
}

function Get-WifiOutboundBytesSent {
    [OutputType([UInt64])]
    param([string[]] $AdapterNames)
    if ($null -eq $AdapterNames -or $AdapterNames.Count -eq 0) { return [UInt64]0 }
    $sum = [UInt64]0
    foreach ($n in $AdapterNames) {
        try {
            $s = Get-NetAdapterStatistics -Name $n -ErrorAction Stop
            $sent = $null
            foreach ($prop in @('SentBytes', 'OutboundBytes')) {
                $p = $s.PSObject.Properties[$prop]
                if ($null -ne $p -and $null -ne $p.Value) {
                    try {
                        $sent = [UInt64]$p.Value
                        break
                    } catch { }
                }
            }
            if ($null -ne $sent) { $sum += $sent }
        } catch { }
    }
    return $sum
}

function Get-DlnaInterpolatedBytesAt {
    [OutputType([Nullable[double]])]
    param(
        [System.Collections.Generic.List[object]] $Samples,
        [datetime] $Ta
    )
    if ($null -eq $Samples -or $Samples.Count -eq 0) { return $null }
    if ($Ta -le $Samples[0].T) { return [double]$Samples[0].B }
    $last = $Samples[$Samples.Count - 1]
    if ($Ta -ge $last.T) { return [double]$last.B }
    for ($i = 0; $i -lt $Samples.Count - 1; $i++) {
        $a = $Samples[$i]
        $b = $Samples[$i + 1]
        if ($Ta -ge $a.T -and $Ta -lt $b.T) {
            $span = ($b.T - $a.T).TotalSeconds
            if ($span -le 0) { return [double]$a.B }
            $frac = ($Ta - $a.T).TotalSeconds / $span
            return [double]$a.B + $frac * ([double]$b.B - [double]$a.B)
        }
    }
    return [double]$last.B
}

function Get-DlnaFiveWindowMinuteMbps {
    [OutputType([double[]])]
    param(
        [System.Collections.Generic.List[object]] $Samples,
        [datetime] $NowUtc
    )
    if ($null -eq $Samples -or $Samples.Count -lt 2) { return $null }
    if (($NowUtc - $Samples[0].T).TotalSeconds -lt $DlnaWifiFiveWindowHistorySeconds) { return $null }
    $out = [double[]]::new(5)
    for ($w = 0; $w -lt 5; $w++) {
        $ws = $NowUtc.AddSeconds(-300 + $w * 60)
        $we = $ws.AddSeconds(60)
        $bs = Get-DlnaInterpolatedBytesAt -Samples $Samples -Ta $ws
        $be = Get-DlnaInterpolatedBytesAt -Samples $Samples -Ta $we
        if ($null -eq $bs -or $null -eq $be) { return $null }
        $delta = $be - $bs
        if ($delta -lt 0) { return $null }
        $out[$w] = ($delta * 8.0) / 60.0 / 1.0e6
    }
    return ,$out
}

function Test-DlnaFiveMinuteWindowsAllStrictlyAboveThreshold {
    param([double[]] $WindowsMbps, [double] $ThresholdMbps)
    if ($null -eq $WindowsMbps -or $WindowsMbps.Length -ne 5) { return $false }
    foreach ($m in $WindowsMbps) {
        if ($m -le $ThresholdMbps) { return $false }
    }
    return $true
}

function Test-DlnaFiveMinuteWindowsAllStrictlyBelowThreshold {
    param([double[]] $WindowsMbps, [double] $ThresholdMbps)
    if ($null -eq $WindowsMbps -or $WindowsMbps.Length -ne 5) { return $false }
    foreach ($m in $WindowsMbps) {
        if ($m -ge $ThresholdMbps) { return $false }
    }
    return $true
}

function Stop-ProcessTreeByPid {
    param([int] $PidToKill)
    if ($PidToKill -le 0) { return }
    try {
        & taskkill.exe /PID $PidToKill /T /F 2>$null | Out-Null
    } catch {
        try { Stop-Process -Id $PidToKill -Force -ErrorAction Stop } catch { }
    }
}

function Clear-PendingConsoleKeys {
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {
        # Non-interactive host: ignore.
    }
}

function New-FfmpegProcessLogPaths {
    param(
        [string] $ScriptPath,
        [string] $InputPath,
        [string] $EncoderLogStem = 'segmentcopy'
    )
    $scriptDir = [System.IO.Path]::GetDirectoryName($ScriptPath)
    $logsRoot = Join-Path $scriptDir 'segmentcopy_logs'
    [void][System.IO.Directory]::CreateDirectory($logsRoot)
    $ffmpegRoot = Join-Path $logsRoot 'ffmpeg_process'
    [void][System.IO.Directory]::CreateDirectory($ffmpegRoot)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeStem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    if ([string]::IsNullOrWhiteSpace($safeStem)) { $safeStem = 'input' }
    $safeStem = [regex]::Replace($safeStem, '[^\w\.\-]+', '_')
    if ($safeStem.Length -gt 80) { $safeStem = $safeStem.Substring(0, 80) }
    $base = "${stamp}_${PID}_${safeStem}_${EncoderLogStem}"
    return @{
        StdOut = Join-Path $ffmpegRoot ($base + '.stdout.log')
        StdErr = Join-Path $ffmpegRoot ($base + '.stderr.log')
    }
}

function Get-RobustProcessExitCode {
    param([System.Diagnostics.Process] $Process)
    if ($null -eq $Process) { return $null }
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $Process.Refresh()
            $raw = $Process.ExitCode
            if ($null -ne $raw) { return [int]$raw }
        } catch { }
        Start-Sleep -Milliseconds 150
    }
    return $null
}

function Test-FfmpegAppearsSuccessfulFromStderr {
    param([string] $StdErrPath)
    if ([string]::IsNullOrWhiteSpace($StdErrPath)) { return $false }
    if (-not (Test-Path -LiteralPath $StdErrPath -PathType Leaf)) { return $false }
    try {
        $tail = Get-Content -LiteralPath $StdErrPath -Tail 120 -ErrorAction Stop
        if (-not $tail) { return $false }
        $joined = ($tail -join "`n")
        if ($joined -match '(?im)^\s*frame=.*\bLsize=' -or $joined -match '(?im)^\s*\[out#0/.+\]\s+video:') {
            if ($joined -notmatch '(?im)\berror\b|\bfailed\b|\binvalid\b|\bcannot\b') {
                return $true
            }
        }
    } catch { }
    return $false
}

function Write-SegmentCopyFailureAppendLog {
    param([string] $ScriptDir, [string] $InputPath, [int] $Code, [string] $FfmpegCommandLine)
    try {
        if ([string]::IsNullOrWhiteSpace($ScriptDir)) { return }
        $logsRoot = Join-Path $ScriptDir 'segmentcopy_logs'
        [void][System.IO.Directory]::CreateDirectory($logsRoot)
        $path = Join-Path $logsRoot 'segmentcopy_failures.log'
        $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $sep = ('=' * 72)
        $lines = @($sep, "$when | exit=$Code", "input: $InputPath")
        if (-not [string]::IsNullOrWhiteSpace($FfmpegCommandLine)) { $lines += "ffmpeg: $FfmpegCommandLine" }
        $lines += $sep
        Add-Content -LiteralPath $path -Value ($lines -join [Environment]::NewLine) -Encoding utf8
        Write-Host "Failure summary appended to: $path"
    } catch {
        Write-Warning "Could not write segmentcopy_failures.log: $_"
    }
}

$exitCode = 0
$instanceMutex = $null
$ownsMutex = $false
$transcriptActive = $false
$failureLogCommandLine = $null
$lockOwnerPath = $null
$fullInput = $null
$runTimeoutAtUtc = [DateTime]::UtcNow.AddSeconds($RunTimeoutSeconds)
Write-Host "Run timeout: ${RunTimeoutSeconds}s"

if ($DryRun) {
    Write-Host 'DryRun: skipping segment job mutex (no ffmpeg, no segment files).'
} else {
    try {
        $instanceMutex = New-Object System.Threading.Mutex($false, $InstanceMutexName)
        $scriptDirForLock = [System.IO.Path]::GetDirectoryName($thisScriptPath)
        $lockOwnerPath = [System.IO.Path]::Combine($scriptDirForLock, 'segmentcopy_logs', 'segmentcopy_lock_owner.txt')
        $gotImmediate = $false
        try {
            $gotImmediate = $instanceMutex.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }
        if ($ownsMutex) {
            # Abandoned mutex: already own.
        } elseif ($gotImmediate) {
            $ownsMutex = $true
        } else {
            Write-Host 'Another segment remux (same output pattern) is active. Waiting for turn...'
            $remainingMs = Get-RemainingTimeoutMs -TimeoutAtUtc $runTimeoutAtUtc
            if ($remainingMs -le 0) {
                Write-Warning "Timeout waiting for mutex: $InstanceMutexName"
                $exitCode = $script:ExitCodeTimeout
                throw [System.ApplicationException] 'mutex-timeout'
            }
            try {
                $acquired = $instanceMutex.WaitOne($remainingMs, $false)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
            if (-not $acquired) {
                Write-Warning "Timed out waiting for mutex: $InstanceMutexName"
                $exitCode = $script:ExitCodeTimeout
                throw [System.ApplicationException] 'mutex-timeout'
            }
            $ownsMutex = $true
            Write-Host 'Lock acquired. Starting ffmpeg.'
        }
        if ($ownsMutex) {
            try {
                $lockDir = [System.IO.Path]::GetDirectoryName($lockOwnerPath)
                [void][System.IO.Directory]::CreateDirectory($lockDir)
                $lines = @(
                    "mutex=$InstanceMutexName",
                    "pid=$PID",
                    "startUtc=$((Get-Process -Id $PID -ErrorAction SilentlyContinue).StartTime.ToUniversalTime().ToString('o'))",
                    "script=$thisScriptPath",
                    "input=$LiteralPath"
                )
                Set-Content -LiteralPath $lockOwnerPath -Value $lines -Encoding utf8
            } catch { }
        }
    } catch [System.ApplicationException] {
        if ($exitCode -ne $script:ExitCodeTimeout) { $exitCode = 1 }
    }
}

if ($exitCode -eq $script:ExitCodeTimeout) {
    if ($instanceMutex) {
        if ($ownsMutex) {
            try { [void]$instanceMutex.ReleaseMutex() } catch { }
            $ownsMutex = $false
        }
        $instanceMutex.Dispose()
        $instanceMutex = $null
    }
    if (-not $NoPause) {
        Write-Host ''
        Write-Host 'Exiting in 5 seconds...'
        Start-Sleep -Seconds 5
    }
    exit $exitCode
}

try {
    if (Get-Command Ensure-DlnaSegmentRoot -ErrorAction SilentlyContinue) {
        $ensuredRoot = Ensure-DlnaSegmentRoot -Force
        $preferredRoot = $script:DlnaSegmentRootPreferred
        if ([string]::IsNullOrWhiteSpace($preferredRoot)) {
            $preferredRoot = 'F:\f1_media\3d_fullsbs_trans'
        }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or
            ($OutputDirectory.TrimEnd('\') -ieq $preferredRoot.TrimEnd('\'))) {
            $OutputDirectory = $ensuredRoot
        }
        Write-Host ("DLNA output root: {0} (mode={1})" -f $OutputDirectory, $script:DlnaSegmentRootEnsureMode)
    }

    if (-not $NoLogFile) {
        try {
            $scriptDir = [System.IO.Path]::GetDirectoryName($thisScriptPath)
            if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
                $logFull = if ([System.IO.Path]::IsPathRooted($LogFile)) {
                    [System.IO.Path]::GetFullPath($LogFile)
                } else {
                    [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, $LogFile))
                }
            } else {
                $logsRoot = Join-Path $scriptDir 'segmentcopy_logs'
                $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                $logFull = Join-Path $logsRoot "segmentcopy_${stamp}_$PID.log"
            }
            $logDir = [System.IO.Path]::GetDirectoryName($logFull)
            if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
                [void][System.IO.Directory]::CreateDirectory($logDir)
            }
            if ((Test-Path -LiteralPath $logFull) -and ((Get-Item -LiteralPath $logFull).Length -gt $RunLogMaxBytes)) {
                Remove-Item -LiteralPath $logFull -Force -ErrorAction Stop
                Write-Host 'Log file exceeded 2 MB; rotated (fresh file at same path).'
            }
            Start-Transcript -Path $logFull -Append -ErrorAction Stop
            $transcriptActive = $true
            Write-Host "Transcript logging appended to: $logFull"
        } catch {
            Write-Warning "Transcript logging failed; continuing without file log: $_"
        }
    }

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        try {
            $clip = Get-Clipboard -Raw -ErrorAction Stop
            if ($null -ne $clip) { $LiteralPath = ([string]$clip).Trim() }
        } catch { }
    }

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
        Write-Error 'Input path not provided and clipboard is empty.'
        $exitCode = 2
        return
    }

    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) {
        Write-Error "Input not found: $LiteralPath"
        $exitCode = 2
        return
    }

    $fullInput = [System.IO.Path]::GetFullPath($LiteralPath)

    Write-Host 'Segment mux: -re + -c copy (TargetMbps, EncoderPreset, OutputLongEdgeCapPx, SkipSourceDecodeFrames, InputReadrate are deprecated and ignored).'

    if ($SsMsOverride -ge 0) {
        $ssMs = [int64]$SsMsOverride
    } else {
        $ssMs = Get-SeekMsForRememberedPath $fullInput
        $quickSeekOverrideMs = Get-QuickSeekOverrideMs
        if ($null -ne $quickSeekOverrideMs) { $ssMs = [int64]$quickSeekOverrideMs }
    }

    $root = [System.IO.Path]::GetFullPath($OutputDirectory)
    $outPath = [System.IO.Path]::Combine($root, $HardcodedOutputFilePattern)
    $outDir = [System.IO.Path]::GetDirectoryName($outPath)
    if (-not [System.IO.Directory]::Exists($outDir)) {
        [void][System.IO.Directory]::CreateDirectory($outDir)
    }

    $ffmpegExe = $Ffmpeg
    if (-not [System.IO.Path]::IsPathRooted($ffmpegExe)) {
        $cmdFfmpeg = Get-Command $ffmpegExe -ErrorAction SilentlyContinue
        if (-not $cmdFfmpeg) {
            Write-Error "ffmpeg not found: $Ffmpeg"
            $exitCode = 1
            return
        }
        $ffmpegExe = $cmdFfmpeg.Source
    }

    $ffprobeExe = Get-FfprobeExePath $ffmpegExe

    $remuxSkippedSeekPastEnd = $false
    if (-not $NoClampSeek -and $ffprobeExe) {
        $durSec = Get-FormatDurationSeconds -MediaPath $fullInput -FfprobeExe $ffprobeExe
        if ($null -ne $durSec) {
            $tailSec = 0.25
            $maxStartSec = [Math]::Max(0.0, $durSec - $tailSec)
            $reqSec = [double]$ssMs / 1000.0
            if ($reqSec -gt $maxStartSec) {
                Write-Host "Resume seek past usable end (duration $([math]::Round($durSec, 3)) s). Skipping ffmpeg (exit 0)."
                $remuxSkippedSeekPastEnd = $true
            }
        }
    }

    if ($remuxSkippedSeekPastEnd) {
        $exitCode = 0
        return
    }

    $ssSec = [double]$ssMs / 1000.0
    $ssMin = $ssSec / 60.0
    $fmtSec = $ssSec.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture)
    $encoderLogStem = 'segmentcopy'

    $argList = @(
        '-hide_banner', '-y',
        '-ss', $fmtSec,
        '-re',
        '-i', $fullInput,
        '-map', '0:v',
        '-map', '0:a?',
        '-c', 'copy',
        '-f', 'segment',
        '-segment_time', '60',
        '-segment_wrap', '2',
        '-reset_timestamps', '1',
        $outPath
    )

    $all = @($ffmpegExe) + $argList
    $commandLine = ($all | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '

    Write-Host "Stream copy + -re | Resume (-ss): $([math]::Round($ssMin, 4)) min -> $outPath"
    Write-Host "FFmpeg command: $commandLine"

    if ($DryRun) {
        $exitCode = 0
        return
    }

    $failureLogCommandLine = $commandLine
    $ffmpegChildLogs = New-FfmpegProcessLogPaths -ScriptPath $thisScriptPath -InputPath $fullInput -EncoderLogStem $encoderLogStem
    Write-Host "FFmpeg stdout log: $($ffmpegChildLogs.StdOut)"
    Write-Host "FFmpeg stderr log: $($ffmpegChildLogs.StdErr)"

    $dlnaMonitorActive = $false
    $dlnaUseUploadMode = -not $DlnaIdleLegacyLastAccess
    $dlnaPollIntervalMs = 30000
    $dlnaIdleSpan = $null
    [string] $dlnaIdleLabel = ''
    [string[]] $dlnaWifiAdapterNames = @()
    if ($DlnaIdleStopSeconds -gt 0) {
        $dlnaIdleSpan = [TimeSpan]::FromSeconds([double]$DlnaIdleStopSeconds)
        $dlnaPollIntervalMs = 5000
        $dlnaIdleLabel = "$DlnaIdleStopSeconds s"
    } elseif ($DlnaIdleStopMinutes -gt 0) {
        $dlnaIdleSpan = [TimeSpan]::FromMinutes([double]$DlnaIdleStopMinutes)
        $dlnaPollIntervalMs = 30000
        $dlnaIdleLabel = "$DlnaIdleStopMinutes min"
    }
    # Wi-Fi Mbps heuristic: how often to read counters and append dlna_wifi_upload log lines (throttle).
    $dlnaUploadSampleIntervalMs = 30000
    $nextDlnaPollUtc = [DateTime]::UtcNow.AddMilliseconds(-$dlnaPollIntervalMs)
    $nextDlnaUploadSampleUtc = [DateTime]::UtcNow.AddMilliseconds(-$dlnaUploadSampleIntervalMs)
    $dlnaArmed = $false
    $dlnaPeakAccessUtc = [DateTime]::UtcNow
    [string] $dlnaAccessLogPath = ''
    $uploadSamples = New-Object 'System.Collections.Generic.List[psobject]'
    if ($null -ne $dlnaIdleSpan) {
        if ($dlnaUseUploadMode) {
            $dlnaWifiAdapterNames = @(Get-WifiUpAdapterNames)
            if ($dlnaWifiAdapterNames.Count -eq 0) {
                Write-Warning 'DLNA idle: no Wi-Fi adapter in Up state (802.11 / wireless). Upload heuristic skipped for this run.'
            } else {
                $dlnaMonitorActive = $true
                $scriptDirDlna = [System.IO.Path]::GetDirectoryName($thisScriptPath)
                $dlnaLogsRoot = Join-Path $scriptDirDlna 'segmentcopy_logs'
                [void][System.IO.Directory]::CreateDirectory($dlnaLogsRoot)
                $dlnaAccessLogPath = Join-Path $dlnaLogsRoot "dlna_wifi_upload_$PID.log"
                $wifiList = $dlnaWifiAdapterNames -join ','
                $sampleSec = [int]($dlnaUploadSampleIntervalMs / 1000)
                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "# DLNA Wi-Fi upload idle | pid=$PID | root=$root | wifi_adapters=$wifiList | stop_immediate_when_all_windows_under_mbps=$DlnaIdleUploadMbpsThreshold | sample_s=$sampleSec | local_ts`t event`t details"
                Write-Host "DLNA Wi-Fi upload idle poll log: $dlnaAccessLogPath"
                Write-Host @"
DLNA idle monitoring (Wi-Fi outbound): adapters: $wifiList. After both segment files exist, ffmpeg stops **immediately** on the first sample where **all five** consecutive 60s windows in the last 5 minutes average **strictly <** $DlnaIdleUploadMbpsThreshold Mbps on Wi-Fi outbound (bytes sampled every $($dlnaUploadSampleIntervalMs / 1000)s; exit $($script:ExitCodeDlnaIdle)). Monitoring continues while Space-paused. Timestamps in the log file are local machine time.
  Folder: $root
"@
            }
        } else {
            Write-Warning 'DLNA idle: -DlnaIdleLegacyLastAccess (NTFS LastAccessTime) is deprecated and unreliable; prefer default Wi-Fi Mbps heuristic.'
            if (Test-FsutilLastAccessTimeUpdatesEnabled) {
                $dlnaMonitorActive = $true
                $scriptDirDlna = [System.IO.Path]::GetDirectoryName($thisScriptPath)
                $dlnaLogsRoot = Join-Path $scriptDirDlna 'segmentcopy_logs'
                [void][System.IO.Directory]::CreateDirectory($dlnaLogsRoot)
                $dlnaAccessLogPath = Join-Path $dlnaLogsRoot "dlna_lastaccess_$PID.log"
                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "# DLNA LastAccessTime (deprecated) | pid=$PID | root=$root | idle_threshold=$dlnaIdleLabel | poll_s=$($dlnaPollIntervalMs / 1000) | local_ts`t event`t details"
                Write-Host "DLNA LastAccessTime poll log (legacy): $dlnaAccessLogPath"
                Write-Host @"
DLNA idle monitoring (legacy): after both segment files exist, ffmpeg stops if max LastAccessTimeUtc is idle for $dlnaIdleLabel (poll every $($dlnaPollIntervalMs / 1000)s). Log timestamps are local machine time.
  Folder: $root
  Exit code $($script:ExitCodeDlnaIdle) when stopped for idle.
"@
            } else {
                Write-Warning 'fsutil: last-access time updates appear disabled (DisableLastAccess 1 or 3). Legacy DLNA idle monitoring skipped for this run.'
            }
        }
    }

    $ffArgLine = ($argList | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' }
        else { $_ }
    }) -join ' '

    Write-Host 'Console: Space=pause/resume segment remux ffmpeg (3d_op_*.mkv); Enter=stop remux and exit. DLNA Wi-Fi idle + run timeout still tick while paused.'
    Clear-PendingConsoleKeys

    $ffProc = Start-Process -FilePath $ffmpegExe -ArgumentList $ffArgLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $ffmpegChildLogs.StdOut -RedirectStandardError $ffmpegChildLogs.StdErr

    $waitHeartbeatSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ([DateTime]::UtcNow -ge $runTimeoutAtUtc) {
            Write-Warning "Run timeout (${RunTimeoutSeconds}s). Stopping ffmpeg..."
            Stop-ProcessTreeByPid -PidToKill $ffProc.Id
            $exitCode = $script:ExitCodeTimeout
            break
        }
        if ($dlnaMonitorActive) {
            $nowUtc = [DateTime]::UtcNow
            if ($dlnaUseUploadMode) {
                if (($nowUtc - $nextDlnaUploadSampleUtc).TotalMilliseconds -ge $dlnaUploadSampleIntervalMs) {
                    $nextDlnaUploadSampleUtc = $nowUtc
                    $p0 = Join-Path $root '3d_op_00.mkv'
                    $p1 = Join-Path $root '3d_op_01.mkv'
                    if ((Test-Path -LiteralPath $p0 -PathType Leaf) -and (Test-Path -LiteralPath $p1 -PathType Leaf)) {
                        if (-not $dlnaArmed) {
                            $dlnaArmed = $true
                            $uploadSamples.Clear()
                            $b0 = Get-WifiOutboundBytesSent -AdapterNames $dlnaWifiAdapterNames
                            $uploadSamples.Add([pscustomobject]@{ T = $nowUtc; B = $b0 })
                            Write-Host 'DLNA idle monitor armed (both segment files present; Wi-Fi five-window upload Mbps check).'
                            if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                $ts = Get-DlnaLogLocalTimestamp
                                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t armed`t under_mbps=$DlnaIdleUploadMbpsThreshold`t wifi_bytes=$b0"
                            }
                        } else {
                            $bCur = Get-WifiOutboundBytesSent -AdapterNames $dlnaWifiAdapterNames
                            $uploadSamples.Add([pscustomobject]@{ T = $nowUtc; B = $bCur })
                            while ($uploadSamples.Count -gt 0 -and ($nowUtc - $uploadSamples[0].T).TotalSeconds -gt 400) {
                                $uploadSamples.RemoveAt(0)
                            }
                            $lastSm = $uploadSamples[$uploadSamples.Count - 1]
                            $prevSm = $uploadSamples[$uploadSamples.Count - 2]
                            $dStep = [double]$lastSm.B - [double]$prevSm.B
                            if ($dStep -lt 0) {
                                $uploadSamples.Clear()
                                $uploadSamples.Add([pscustomobject]@{ T = $nowUtc; B = $bCur })
                            }
                            $winMb = Get-DlnaFiveWindowMinuteMbps -Samples $uploadSamples -NowUtc $nowUtc
                            $winMbReady = ($null -ne $winMb)
                            $allFiveUnderTh = $false
                            $streamingHigh = $false
                            if ($winMbReady) {
                                $allFiveUnderTh = Test-DlnaFiveMinuteWindowsAllStrictlyBelowThreshold -WindowsMbps $winMb -ThresholdMbps $DlnaIdleUploadMbpsThreshold
                                $streamingHigh = Test-DlnaFiveMinuteWindowsAllStrictlyAboveThreshold -WindowsMbps $winMb -ThresholdMbps $DlnaIdleUploadMbpsThreshold
                            }
                            if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                $ts = Get-DlnaLogLocalTimestamp
                                $wStr = 'w0=n/a,w1=n/a,w2=n/a,w3=n/a,w4=n/a'
                                if ($null -ne $winMb) {
                                    $wStr = ('w0={0},w1={1},w2={2},w3={3},w4={4}' -f @(
                                        [Math]::Round($winMb[0], 3), [Math]::Round($winMb[1], 3), [Math]::Round($winMb[2], 3),
                                        [Math]::Round($winMb[3], 3), [Math]::Round($winMb[4], 3)))
                                }
                                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t poll`t five_win_ready=$winMbReady`t all5_under_th=$allFiveUnderTh`t streaming_high=$streamingHigh`t $wStr`t wifi_bytes=$bCur"
                            }
                            if ($winMbReady -and $allFiveUnderTh) {
                                if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                    $ts = Get-DlnaLogLocalTimestamp
                                    Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t idle_stop`t reason=all_five_60s_windows_under_threshold_immediate`t under_mbps=$DlnaIdleUploadMbpsThreshold`t stopping_ffmpeg=1"
                                }
                                Write-Warning "Wi-Fi DLNA idle: all five consecutive 60s averages < $DlnaIdleUploadMbpsThreshold Mbps (immediate stop). Stopping ffmpeg..."
                                Stop-ProcessTreeByPid -PidToKill $ffProc.Id
                                $exitCode = $script:ExitCodeDlnaIdle
                                break
                            }
                        }
                    }
                }
            } elseif (($nowUtc - $nextDlnaPollUtc).TotalMilliseconds -ge $dlnaPollIntervalMs) {
                $nextDlnaPollUtc = $nowUtc
                $p0 = Join-Path $root '3d_op_00.mkv'
                $p1 = Join-Path $root '3d_op_01.mkv'
                if ((Test-Path -LiteralPath $p0 -PathType Leaf) -and (Test-Path -LiteralPath $p1 -PathType Leaf)) {
                    $accessState = Get-SegmentPairLastAccessState -Directory $root
                    if ($null -ne $accessState) {
                        $maxAccess = $accessState.MaxUtc
                        $iso0 = if ($null -ne $accessState.Last0Utc) { $accessState.Last0Utc.ToString('o') } else { '' }
                        $iso1 = if ($null -ne $accessState.Last1Utc) { $accessState.Last1Utc.ToString('o') } else { '' }
                        $isoMax = $maxAccess.ToString('o')
                        $isoPeak = $dlnaPeakAccessUtc.ToString('o')
                        $idleVsPeakSec = [Math]::Round(($nowUtc - $dlnaPeakAccessUtc).TotalSeconds, 2)
                        if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                            $ts = Get-DlnaLogLocalTimestamp
                            Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t poll`t max=$isoMax`t 00=$iso0`t 01=$iso1`t peak=$isoPeak`t armed=$dlnaArmed`t idle_sec_vs_peak=$idleVsPeakSec"
                        }
                        if (-not $dlnaArmed) {
                            $dlnaArmed = $true
                            $dlnaPeakAccessUtc = $maxAccess
                            Write-Host 'DLNA idle monitor armed (both segment files present; tracking max LastAccessTimeUtc).'
                            if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                $ts = Get-DlnaLogLocalTimestamp
                                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t armed`t peak=$($dlnaPeakAccessUtc.ToString('o'))`t 00=$iso0`t 01=$iso1`t max=$isoMax"
                            }
                        } elseif ($maxAccess -gt $dlnaPeakAccessUtc) {
                            $prevPeak = $dlnaPeakAccessUtc
                            $dlnaPeakAccessUtc = $maxAccess
                            Write-Host "DLNA LastAccessTime: peak advanced (timestamp newer; not necessarily a viewer read). $($prevPeak.ToString('o')) -> $($dlnaPeakAccessUtc.ToString('o')) | 3d_op_00=$iso0 | 3d_op_01=$iso1"
                            if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                $ts = Get-DlnaLogLocalTimestamp
                                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t peak_advance`t prev_peak=$($prevPeak.ToString('o'))`t new_peak=$($dlnaPeakAccessUtc.ToString('o'))`t 00=$iso0`t 01=$iso1`t max=$isoMax"
                            }
                        } elseif (($nowUtc - $dlnaPeakAccessUtc).TotalSeconds -ge $dlnaIdleSpan.TotalSeconds) {
                            if (-not [string]::IsNullOrWhiteSpace($dlnaAccessLogPath)) {
                                $ts = Get-DlnaLogLocalTimestamp
                                Write-DlnaLastAccessLogLine -LiteralPath $dlnaAccessLogPath -Line "$ts`t idle_stop`t threshold=$dlnaIdleLabel`t peak=$isoPeak`t last_max=$isoMax`t stopping_ffmpeg=1"
                            }
                            Write-Warning "No newer LastAccessTime on segment files for at least $dlnaIdleLabel (legacy DLNA heuristic). Stopping ffmpeg..."
                            Stop-ProcessTreeByPid -PidToKill $ffProc.Id
                            $exitCode = $script:ExitCodeDlnaIdle
                            break
                        }
                    }
                }
            }
        }
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Spacebar) {
                    if (Get-Command Toggle-LeafFfmpegExportSuspend -ErrorAction SilentlyContinue) {
                        [void](Toggle-LeafFfmpegExportSuspend)
                    }
                } elseif ($key.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ''
                    Write-Host 'Enter pressed — stopping ffmpeg...'
                    Stop-ProcessTreeByPid -PidToKill $ffProc.Id
                    $exitCode = $script:ExitCodeUserCancel
                    break
                }
            }
        } catch {
            # Non-interactive host: only wait for process exit.
        }
        if ($waitHeartbeatSw.Elapsed.TotalSeconds -ge $script:ConsoleHeartbeatSeconds) {
            $elapsedSec = [int][Math]::Floor($waitHeartbeatSw.Elapsed.TotalSeconds)
            Write-Host "[wait] FFmpeg still running (${elapsedSec}s). stderr: $($ffmpegChildLogs.StdErr) (Space=pause/resume segment remux)"
            $waitHeartbeatSw.Restart()
        }
        $exited = $false
        try {
            $ffProc.Refresh()
            $exited = $ffProc.HasExited
        } catch {
            $exited = $true
        }
        if ($exited) { break }
        Start-Sleep -Milliseconds 200
    }
    try { $ffProc.WaitForExit() } catch { }

    if ($exitCode -ne $script:ExitCodeTimeout -and $exitCode -ne $script:ExitCodeDlnaIdle -and $exitCode -ne $script:ExitCodeUserCancel) {
        $robustEc = Get-RobustProcessExitCode -Process $ffProc
        if ($null -ne $robustEc) {
            $exitCode = $robustEc
        } elseif (Test-FfmpegAppearsSuccessfulFromStderr -StdErrPath $ffmpegChildLogs.StdErr) {
            Write-Warning 'FFmpeg ExitCode unavailable; stderr suggests success. Treating as 0.'
            $exitCode = 0
        } else {
            $exitCode = 1
        }
    }
    Write-Host "FFmpeg exit code: $exitCode"
    if ($exitCode -ne 0 -and (Test-Path -LiteralPath $ffmpegChildLogs.StdErr)) {
        Write-Host 'FFmpeg stderr tail (last 40 lines):'
        try {
            $tail = Get-Content -LiteralPath $ffmpegChildLogs.StdErr -Tail 40 -ErrorAction Stop
            if ($tail) { Write-Host ($tail -join [Environment]::NewLine) }
        } catch { }
    }
} catch {
    Write-Warning ("Segment remux failed: {0}" -f $_.Exception.Message)
    if ($exitCode -eq 0) { $exitCode = 1 }
} finally {
    if ($transcriptActive) {
        try { Stop-Transcript } catch { }
        $transcriptActive = $false
    }
    if ($instanceMutex) {
        if ($ownsMutex) { [void]$instanceMutex.ReleaseMutex() }
        $instanceMutex.Dispose()
    }
    if ($ownsMutex -and $lockOwnerPath) {
        try { Remove-Item -LiteralPath $lockOwnerPath -Force -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $DryRun -and (Get-Command Invoke-DlnaWorkflowQuitCleanup -ErrorAction SilentlyContinue)) {
        $keepDlnaLogs = ($exitCode -ne 0 -and $exitCode -ne $script:ExitCodeTimeout -and `
            $exitCode -ne $script:ExitCodeDlnaIdle -and $exitCode -ne $script:ExitCodeUserCancel)
        try {
            [void](Invoke-DlnaWorkflowQuitCleanup -KeepLogs:$keepDlnaLogs)
        } catch {
            Write-Warning ("DLNA workflow quit cleanup failed: {0}" -f $_.Exception.Message)
        }
    } elseif (Get-Command Remove-DlnaSegmentRootSubst -ErrorAction SilentlyContinue) {
        try {
            [void](Remove-DlnaSegmentRootSubst)
        } catch {
            Write-Warning ("DLNA root F: subst cleanup on quit failed: {0}" -f $_.Exception.Message)
        }
    }
}

if ($exitCode -ne 0 -and $NoLogFile) {
    $sd = [System.IO.Path]::GetDirectoryName($thisScriptPath)
    $inp = if ((Test-Path Variable:fullInput) -and -not [string]::IsNullOrWhiteSpace($fullInput)) { $fullInput } else { $LiteralPath }
    Write-SegmentCopyFailureAppendLog -ScriptDir $sd -InputPath $inp -Code $exitCode -FfmpegCommandLine $failureLogCommandLine
}

if (-not $NoPause) {
    Write-Host ''
    Write-Host 'Exiting in 5 seconds...'
    Start-Sleep -Seconds 5
}
exit $exitCode
