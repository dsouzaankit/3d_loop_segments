#Requires -Version 5.1
<#
.SYNOPSIS
  Loop-segments Skybox start/stop plus Add-folders mapping (3d_fullsbs_trans + Skybox_vr_pc AirScreen share).

.DESCRIPTION
  Dot-source from Invoke-LeafFfmpegControl.ps1.
  Process start / hide-to-tray / quit and the AirScreen share (p_cld_media by default)
  come from the Skybox_vr_pc git submodule (SkyboxVrPc.UnmapPath.ps1), then
  P:\all_scripts\Skybox_vr_pc. This file keeps the workflow-started marker and
  maps/unmaps 3d_fullsbs_trans. Override the Skybox_vr_pc root with SKYBOX_VR_PC_ROOT.
#>

$script:LoopSegmentsSkyboxDlnaFolderName = '3d_fullsbs_trans'
$script:LoopSegmentsSkyboxVrPcImported = $false

function Get-LoopSegmentsSkyboxVrPcRoot {
    $envRoot = [string]$env:SKYBOX_VR_PC_ROOT
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        [void]$candidates.Add($envRoot.Trim())
    }
    $walk = $PSScriptRoot
    for ($i = 0; $i -lt 6 -and $walk; $i++) {
        [void]$candidates.Add((Join-Path $walk 'Skybox_vr_pc'))
        $walk = Split-Path -Parent $walk
    }
    [void]$candidates.Add('P:\all_scripts\Skybox_vr_pc')
    foreach ($root in $candidates) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($root)
        } catch {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $full 'SkyboxVrPc.UnmapPath.ps1') -PathType Leaf) {
            return $full
        }
    }
    return $null
}

function Import-LoopSegmentsSkyboxVrPc {
    [bool]$script:LoopSegmentsSkyboxVrPcImported
}

$script:LoopSegmentsSkyboxVrPcRootResolved = Get-LoopSegmentsSkyboxVrPcRoot
if ($script:LoopSegmentsSkyboxVrPcRootResolved) {
    . (Join-Path $script:LoopSegmentsSkyboxVrPcRootResolved 'SkyboxVrPc.UnmapPath.ps1')
    $script:LoopSegmentsSkyboxVrPcImported = $true
} else {
    Write-Warning '[skybox] Skybox_vr_pc not found (expected ./Skybox_vr_pc submodule, P:\all_scripts\Skybox_vr_pc, or SKYBOX_VR_PC_ROOT).'
}

function Get-SkyboxPcClientStartedMarkerPath {
    Join-Path $env:LOCALAPPDATA '3d_loop_segments\skybox-started-by-workflow.marker'
}

function Set-SkyboxPcClientStartedMarker {
    $p = Get-SkyboxPcClientStartedMarkerPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    Set-Content -LiteralPath $p -Value (Get-Date -Format o) -Encoding ascii
}

function Clear-SkyboxPcClientStartedMarker {
    $p = Get-SkyboxPcClientStartedMarkerPath
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

function Test-SkyboxPcClientStartedByWorkflow {
    Test-Path -LiteralPath (Get-SkyboxPcClientStartedMarkerPath)
}

function Invoke-LoopSegmentsSkyboxVrPcMap {
    if (-not (Import-LoopSegmentsSkyboxVrPc)) { return $false }
    if (-not (Get-Command Map-SkyboxVrPcShare -ErrorAction SilentlyContinue)) { return $false }
    try {
        return [bool](Map-SkyboxVrPcShare)
    } catch {
        Write-Warning ("[skybox] Skybox_vr_pc AirScreen share not mapped: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-LoopSegmentsSkyboxVrPcUnmap {
    if (-not (Get-Command Unmap-SkyboxVrPcShare -ErrorAction SilentlyContinue)) {
        if (-not (Import-LoopSegmentsSkyboxVrPc)) { return }
    }
    if (-not (Get-Command Unmap-SkyboxVrPcShare -ErrorAction SilentlyContinue)) { return }
    try {
        [void](Unmap-SkyboxVrPcShare)
    } catch {
        Write-Warning ("[skybox] Skybox_vr_pc AirScreen share unmap failed: {0}" -f $_.Exception.Message)
    }
}

function Sync-SkyboxDlnaShareMapping {
    param(
        [string] $ExpectedRoot = '',
        [switch] $Removed
    )
    $expected = if ([string]::IsNullOrWhiteSpace($ExpectedRoot)) { '' } else { $ExpectedRoot.TrimEnd('\') }
    $name = $script:LoopSegmentsSkyboxDlnaFolderName
    if (-not (Import-LoopSegmentsSkyboxVrPc) -or -not (Get-Command Sync-SkyboxVrPcShareMapping -ErrorAction SilentlyContinue)) {
        if ($Removed.IsPresent) {
            Write-Warning ("Skybox_vr_pc mapping helper missing. Could not remove {0} Add-folders mapping(s)." -f $name)
        } else {
            Write-Warning ("Skybox_vr_pc mapping helper missing. Could not map {0}." -f $expected)
        }
        return
    }
    if ($Removed.IsPresent) {
        [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName $name -Removed)
        return
    }
    [void](Sync-SkyboxVrPcShareMapping -ExpectedRoot $expected -ShareName $name)
}

function Start-SkyboxPcClientIfNeeded {
    <#
      Skybox_vr_pc starts SKYBOX VR if idle, hides to tray, waits for :8018, maps the AirScreen share,
      then this file maps 3d_fullsbs_trans. Quit unmaps both, then quits Skybox only if this workflow started it.
    #>
    if ($env:3D_LOOP_SEGMENTS_SKIP_SKYBOX -eq '1' -or $env:3D_PLAYLIST_SKIP_SKYBOX -eq '1') {
        Write-Host '[skybox] Skipping SKYBOX VR desktop (3D_LOOP_SEGMENTS_SKIP_SKYBOX or 3D_PLAYLIST_SKIP_SKYBOX=1)'
        return $false
    }
    if (-not (Import-LoopSegmentsSkyboxVrPc) -or -not (Get-Command Start-SkyboxVrPcProcess -ErrorAction SilentlyContinue)) {
        Write-Warning '[skybox] Skybox_vr_pc Start-SkyboxVrPcProcess not available.'
        return $false
    }
    $already = $false
    if (Get-Command Test-SkyboxPcClientRunning -ErrorAction SilentlyContinue) {
        $already = [bool](Test-SkyboxPcClientRunning)
    }
    if ($already) {
        try { Clear-SkyboxPcClientStartedMarker } catch { }
    }
    $ok = $false
    try {
        $ok = [bool](Start-SkyboxVrPcProcess)
    } catch {
        Write-Warning ("Skybox PC client start failed: {0}" -f $_.Exception.Message)
        return $false
    }
    if (-not $already) {
        $weStarted = $false
        if (Get-Command Test-SkyboxVrPcStartedByThisSession -ErrorAction SilentlyContinue) {
            $weStarted = [bool](Test-SkyboxVrPcStartedByThisSession)
        } elseif (Get-Command Test-SkyboxPcClientRunning -ErrorAction SilentlyContinue) {
            $weStarted = [bool](Test-SkyboxPcClientRunning)
        }
        if ($weStarted) {
            try { Set-SkyboxPcClientStartedMarker } catch { }
        }
    }
    [void](Invoke-LoopSegmentsSkyboxVrPcMap)
    return $ok
}

function Stop-SkyboxPcClient {
    param([switch] $OnlyIfWorkflowStarted)

    if (Get-Command Stop-SkyboxPcClientMinimizeWatch -ErrorAction SilentlyContinue) {
        try { Stop-SkyboxPcClientMinimizeWatch } catch { }
    }
    Invoke-LoopSegmentsSkyboxVrPcUnmap

    if ($OnlyIfWorkflowStarted -and -not (Test-SkyboxPcClientStartedByWorkflow)) {
        return
    }
    if (Get-Command Stop-SkyboxVrPcProcess -ErrorAction SilentlyContinue) {
        Stop-SkyboxVrPcProcess
    }
    Clear-SkyboxPcClientStartedMarker
}
