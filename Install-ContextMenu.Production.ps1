#Requires -Version 5.1
<#
.SYNOPSIS
  HKCU context menu (production): Remux to rotating MKV segments with stream copy + -re; passes -TargetMbps 100 (ignored; compatibility), -DlnaIdleStopMinutes 5 (Wi-Fi upload idle heuristic). No bitrate/scale prompts.

.NOTES
  Verb: shell\SegmentCopyRemuxProd. Pair with Install-ContextMenu.DlnaTest.ps1 for the seconds-based idle tester.
  Remove all variants: Uninstall-ContextMenu.ps1
#>
$ErrorActionPreference = 'Stop'

$installDir = $PSScriptRoot
$launcher = Join-Path $installDir 'Run-SegmentCopy.ps1'
if (-not (Test-Path -LiteralPath $launcher)) {
    Write-Error "Launcher not found: $launcher"
    exit 1
}

$verbSubKey = 'shell\SegmentCopyRemuxProd'
$cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -LiteralPath `"%L`" -ContextMenu -TargetMbps 100 -DlnaIdleStopMinutes 5"

$extensions = @(
    '.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.webm', '.ts', '.m2ts', '.mpeg', '.mpg', '.avs'
)

foreach ($ext in $extensions) {
    foreach ($base in @(
        "HKCU:\Software\Classes\$ext",
        "HKCU:\Software\Classes\SystemFileAssociations\$ext"
    )) {
        $shellKey = Join-Path $base $verbSubKey
        $commandKey = Join-Path $shellKey 'command'

        New-Item -Path $shellKey -Force | Out-Null
        New-Item -Path $commandKey -Force | Out-Null

        Set-ItemProperty -LiteralPath $shellKey -Name '(default)' -Value 'Remux segments (copy+re, DLNA idle 5m)'
        Set-ItemProperty -LiteralPath $shellKey -Name 'Position' -Type String -Value 'Top'
        Set-ItemProperty -LiteralPath $commandKey -Name '(default)' -Value $cmd

        Write-Host "Installed: $shellKey"
    }
}

Write-Host ''
Write-Host "Command: $cmd"
Write-Host ''
Write-Host 'If the item is missing, restart Explorer:'
Write-Host '  Stop-Process -Name explorer -Force; Start-Process explorer'
