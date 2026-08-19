#Requires -Version 5.1
<#
.SYNOPSIS
  Delete log files under this folder's segmentcopy_logs (and legacy transcode_logs if present).

.DESCRIPTION
  Removes all children of segmentcopy_logs (transcripts, dlna_*.log, ffmpeg_process, etc.) without
  deleting the segmentcopy_logs directory itself. Same for legacy transcode_logs.

.EXAMPLE
  .\Clear-SegmentCopyLogs.ps1

.EXAMPLE
  .\Clear-SegmentCopyLogs.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'

function Clear-LogTreeContents {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LogRoot
    )
    if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
        Write-Host "Skip (not found): $LogRoot"
        return 0
    }
    $children = @(Get-ChildItem -LiteralPath $LogRoot -Force -ErrorAction Stop)
    if ($children.Count -eq 0) {
        Write-Host "Already empty: $LogRoot"
        return 0
    }
    if (-not $PSCmdlet.ShouldProcess($LogRoot, 'Remove all files and subfolders inside')) {
        return 0
    }
    $removed = 0
    foreach ($item in $children) {
        Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
        $removed++
    }
    Write-Host "Cleaned $removed item(s) under: $LogRoot"
    return $removed
}

$root = $PSScriptRoot
$total = 0
$total += Clear-LogTreeContents -LogRoot (Join-Path $root 'segmentcopy_logs')
$total += Clear-LogTreeContents -LogRoot (Join-Path $root 'transcode_logs')
Write-Host ''
Write-Host "Done. Total top-level entries removed: $total"
