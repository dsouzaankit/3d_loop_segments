#Requires -Version 5.1
<#
.SYNOPSIS
  Manually delete/truncate all files under the DLNA segment root (%AppData%\3d_loop_segments).

.DESCRIPTION
  Workflows obfuscate media on quit instead of deleting. Use this when you want files removed.
  Calls Clear-DlnaSegmentRootContents in Invoke-LeafFfmpegControl.ps1 (stop leaf ffmpeg, delete files).

.PARAMETER Root
  Override DLNA root. Default: Ensure-DlnaSegmentRoot.

.PARAMETER KeepLogs
  Leave *.log and logs\ trees in place.

.PARAMETER DryRun
  Report actions without deleting.

.PARAMETER NoStopLeafExport
  Do not taskkill leaf DLNA export ffmpeg first.
#>
[CmdletBinding()]
param(
    [string] $Root = '',
    [switch] $KeepLogs,
    [switch] $DryRun,
    [switch] $NoStopLeafExport
)

$ErrorActionPreference = 'Stop'
$leafControl = Join-Path $PSScriptRoot 'Invoke-LeafFfmpegControl.ps1'
if (-not (Test-Path -LiteralPath $leafControl -PathType Leaf)) {
    throw "Invoke-LeafFfmpegControl.ps1 not found: $leafControl"
}
. $leafControl

if (-not (Get-Command Clear-DlnaSegmentRootContents -ErrorAction SilentlyContinue)) {
    throw 'Clear-DlnaSegmentRootContents is not available after loading Invoke-LeafFfmpegControl.ps1'
}

Write-Host 'Cleanup-DlnaSegmentRoot: deleting media/logs under DLNA segment root (manual).'
$result = Clear-DlnaSegmentRootContents `
    -Root $Root `
    -KeepLogs:$KeepLogs.IsPresent `
    -DryRun:$DryRun.IsPresent `
    -NoStopLeafExport:$NoStopLeafExport.IsPresent

Write-Host ("Done. Root={0} Deleted={1} Truncated={2} Failed={3} StoppedLeafFfmpeg={4}" -f `
    $result.Root, $result.Deleted, $result.Truncated, $result.Failed, $result.Stopped)

if ($Host.Name -eq 'ConsoleHost' -and -not $DryRun.IsPresent) {
    Write-Host 'Press Enter to close...'
    try { [void][Console]::ReadLine() } catch { Start-Sleep -Seconds 3 }
}
