#Requires -Version 5.1
<#
.SYNOPSIS
  Remove HKCU context menu entries for this folder's segment remux launchers (current verbs and legacy verbs from older installers).

.NOTES
  No admin required. Restart Explorer if a stale item remains.
  By default only prints removed keys and a summary; use -Verbose to list each skipped path.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$verbs = @(
    'shell\SegmentCopyRemuxProd',
    'shell\SegmentCopyRemuxDlnaTest',
    'shell\TranscodeSegmentCopyProd',
    'shell\TranscodeSegmentCopyDlnaTest',
    'shell\TranscodeAv1QsvProd',
    'shell\TranscodeAv1QsvDlnaTest',
    'shell\TranscodeAv1Qsv'
)

$extensions = @(
    '.mp4', '.mkv', '.mov', '.m4v', '.avi', '.wmv', '.webm', '.ts', '.m2ts', '.mpeg', '.mpg', '.avs'
)

$removed = 0
$skipped = 0

foreach ($ext in $extensions) {
    foreach ($base in @(
        "HKCU:\Software\Classes\$ext",
        "HKCU:\Software\Classes\SystemFileAssociations\$ext"
    )) {
        foreach ($verb in $verbs) {
            $shellKey = Join-Path $base $verb
            if (Test-Path -LiteralPath $shellKey) {
                Remove-Item -LiteralPath $shellKey -Recurse -Force
                $removed++
                Write-Host "Removed: $shellKey"
            } else {
                $skipped++
                Write-Verbose "Not present (skipped): $shellKey"
            }
        }
    }
}

Write-Host ''
Write-Host "Done. Removed $removed key(s); $skipped path(s) were not present."
Write-Host 'Restart Explorer if a stale entry remains:'
Write-Host '  Stop-Process -Name explorer -Force; Start-Process explorer'
