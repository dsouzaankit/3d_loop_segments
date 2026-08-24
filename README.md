# Segment remux (context menu)

PowerShell launcher: `Run-SegmentCopy.ps1` remuxes with **`-c copy`** and **`-re`** into two rotating segment MKVs (`3d_op_%02d.mkv`, 60s segments, wrap 2). While ffmpeg runs: **Space** pauses/resumes the remux (NtSuspend/NtResume, same as `3d_playlist_local`); **Enter** stops ffmpeg and exits with code **130**. **TargetMbps**, **EncoderPreset**, **OutputLongEdgeCapPx**, **SkipSourceDecodeFrames**, and **InputReadrate** are **deprecated and ignored** (kept for Explorer/context-menu compatibility). **Output long-edge cap** and **decoder skip** prompts are removed. **DLNA idle** defaults to the Wi‑Fi outbound five-window heuristic with **`-DlnaIdleStopMinutes 5`** (enables monitoring; ffmpeg stops **immediately** the first time **all five** recent minute windows are **strictly <** the Mbps threshold—minutes/seconds do **not** add a wait in Wi-Fi mode). Pass **`-DlnaIdleStopMinutes 0`** to turn idle stop off. Context menu installers: `Install-ContextMenu.Production.ps1`, `Install-ContextMenu.DlnaTest.ps1`; remove with `Uninstall-ContextMenu.ps1`.

## Source media on a mapped network drive

If **input files** live on a **mapped drive** (SMB share, VPN, NAS, etc.), **read throughput** can be limited by **bandwidth and latency**, not only by local CPU or GPU.

- ffmpeg must **read** the entire source (demux; with **`-c copy`** there is no full video decode/encode in this launcher path). High-bitrate sources can still need **well above** a nominal “100 Mbps” link in **sustained** read throughput, especially with **seek** (`-ss`), random access, or concurrent traffic. **`-re`** paces input read to roughly real time.
- **Symptoms**: low CPU/GPU use, ffmpeg waiting on I/O, stutters, or long wall-clock times while the network is saturated.
- **Mitigations** (most reliable first):
  1. **Copy the source to a local SSD**, run the remux from that path, then copy outputs back if needed.
  2. Use **wired LAN** and a path that can sustain the **source file’s** peak read rate (not just “average internet speed”).
  3. Reduce competing traffic on the same link while ffmpeg is running.

**Output** uses the Skybox DLNA path **`M:\m1_media\3d_fullsbs_trans`** (prefer **M:**; a free **D–Z** letter if **M:** is a real volume or someone else’s subst). Dummy subst uses **`%AppData%\m1_media_dlna_subst`** (same as `3d_playlist_local`; leftover **`f1_media_F_subst`** is renamed). If that subst is already active, this script **reuses** it. A **physical** preferred letter (or a subst not under `%AppData%`) is an error or triggers a fallback letter. On exit, **`subst {letter}: /d`** only if **this run** created the mapping. Leftover dummy parent **`f1_media\`** (and **`k1_media\`**) under the subst mount is removed when empty.

**Downstream streaming** (e.g. DLNA to a client over a link slower than your media bitrate) is a **separate** bottleneck from “reading the source over SMB.”

---

## DLNA output root (`M:` / `%AppData%`)

Skybox/DLNA uses **`{letter}:\m1_media\3d_fullsbs_trans`**. `Run-SegmentCopy.ps1` always calls **`Ensure-DlnaSegmentRoot`** after the instance mutex. Default `-OutputDirectory` is **`M:\m1_media\3d_fullsbs_trans`**; **`Convert-DlnaPlaceholderSharePath`** retargets legacy **`F:\` / `K:\` / `M:\`** `f1_media` / `k1_media` / `m1_media` placeholders to the live dummy letter.

The preferred letter is **M:**. If **M:** is taken, a free **D–Z** letter is used and the Skybox PC client **Add folders** mapping is updated (or you are warned to add that path). Playlist already subst’s the same **`m1_media_dlna_subst`** mount, so this script **reuses** that mapping instead of inventing a second dummy tree.

| Dummy letter at start | What happens |
|-----------------------|--------------|
| Absent (unmapped) | This run **creates** `subst {letter}:` → `%AppData%\m1_media_dlna_subst`; junction → `%AppData%\3d_loop_segments` if that path is not already a folder/junction. Starts Skybox PC client if idle and maps **3d_fullsbs_trans**. On quit: unmap that Skybox folder, obfuscate, then **`subst /d`** if this run created the mapping. |
| Existing AppData subst (including playlist’s `m1_media_dlna_subst`, or leftover `f1_media_F_subst`) | **Reuse** that mapping. Write to `{letter}:\m1_media\3d_fullsbs_trans`. Physical files follow the **existing** `3d_fullsbs_trans` junction (typically `%AppData%\3d_playlist_local`), **not** `%AppData%\3d_loop_segments`. Do not steal or `subst /d` on quit. Drop leftover **`f1_media\`** / **`k1_media\`** parents when empty. Obfuscate recursively, including **`fisheye_temp\`**; skip live playlist segment dirs **`flat\` / `fisheye\` / `hybrid\`** only. |
| Physical drive or non-AppData `subst` on the preferred letter | Pick a free **D–Z** letter (or error if none). |

On exit, **`Remove-DlnaSegmentRootSubst`** tears down dummy `{letter}:` **only if this run created the subst**. AppData data stays. After `subst`, the script also registers a PowerShell drive for that letter (provider cache does not pick up subst on its own; without that, `Join-Path` / `Test-Path` throw **Cannot find drive** and context-menu runs fail). Set **`3D_LOOP_SEGMENTS_SKIP_SKYBOX=1`** (or **`3D_PLAYLIST_SKIP_SKYBOX=1`**) to skip launching Skybox (mappings still sync if it is already up). Log/manual cleanup (`Cleanup-DlnaSegmentRoot.ps1`, obfuscate/clear helpers) calls **`Ensure-DlnaSegmentRoot -SkipSkyboxClient`**.

Skybox start/stop and AirScreen mapping come from **`Get-LoopSegmentsSkybox.ps1`**, which **dot-sources** `SkyboxVrPc.UnmapPath.ps1`. This repo does **not** vendor `Skybox_vr_pc` as a git submodule (unlike `3d_playlist_local`). It loads the first existing tree among **`SKYBOX_VR_PC_ROOT`**, **`P:\all_scripts\Skybox_vr_pc`**, and a **`Skybox_vr_pc`** folder found by walking up from this script.

### Media obfuscation (quit / startup)

Same pattern as `3d_playlist_local`:

- **Startup** (`Ensure-DlnaSegmentRoot`): restores any `<sha256>.tmp` files using this script’s scrambled **`.dlna_obf_map.3d_loop_segments.json`** (`3d_op_00.mkv` / `3d_op_01.mkv` and any `.avs` / `.avsi` names come back). If the clear name already exists, the restored file **overwrites** it so ffmpeg can then `-y` replace in place instead of creating a second file. Does not use playlist’s `.dlna_obf_map.json` (different key; playlist deletes that file when decrypt fails).
- **Quit** (`Invoke-DlnaWorkflowQuitCleanup` in `Run-SegmentCopy.ps1` `finally`, plus a **Ctrl+C** `trap`): unmaps Skybox **3d_fullsbs_trans** (and quits Skybox only if this run started it), stops leaf ffmpeg, renames media **and AviSynth scripts** (`.avs` / `.avsi`) to `<sha256(relativePath)>.tmp`, writes **`.dlna_obf_map.3d_loop_segments.json`** — including **`fisheye_temp\`**. **`subst {letter}: /d`** only if **this run created** the dummy drive. If playlist already had the dummy letter subst’d, the mapping stays; live **`flat\` / `fisheye\` / `hybrid\`** segment dirs are not renamed.
- **Manual delete:** `Cleanup-DlnaSegmentRoot.ps1` (calls `Clear-DlnaSegmentRootContents`).
- **Keep logs on error:** non-zero exit codes other than timeout (**124**), DLNA idle (**125**), and user cancel (**130**) pass `-KeepLogs` to the obfuscator (rarely needed here; segment logs live under `segmentcopy_logs\` beside the script).

---

## Decoder frame skip (`-SkipSourceDecodeFrames`; **deprecated in this script**)

The script still accepts **`-SkipSourceDecodeFrames`** for registry compatibility, but the **stream-copy** pipeline does **not** pass **`-skip_frame`**. The table below describes what those values meant on older encode builds; they are **ignored** now.

| Mode | Meaning (historical) |
|------|--------|
| **None** | Full decode path; no `-skip_frame`. |
| **Bidir** | Skip decoding **B-frames** (when an encode path was used). |

Upstream reference: [FFmpeg documentation — search `skip_frame`](https://ffmpeg.org/ffmpeg-all.html).

---

## DLNA idle “sniff” (experimental)

The script can optionally stop ffmpeg when it believes **playback has gone idle** (exit **125**). **Wi‑Fi default:** stop **immediately** when the Mbps heuristic fires. **Legacy LastAccess:** uses `-DlnaIdleStopMinutes` / `-DlnaIdleStopSeconds` as the idle **duration**.

### Default: Wi-Fi outbound Mbps (since this repo revision)

- Counters are read only from **Wi‑Fi adapters** that are **Up** (`Get-NetAdapter`: `MediaType` **802.11** or wireless-like `PhysicalMediaType`). If none are Up, monitoring is skipped with a warning.
- After both `3d_op_00.mkv` and `3d_op_01.mkv` exist, the script samples **cumulative Wi‑Fi outbound bytes** every **30s** and builds five consecutive **60-second** windows covering the last **5 minutes** (relative to “now”). For each window it computes average **Mbps** = `(bytes_end − bytes_start) × 8 / 60 / 1e6` with linear interpolation between samples at the window edges.
- **Idle kill (Wi‑Fi):** on the **first** poll where **all five** per-minute averages are **strictly < `-DlnaIdleUploadMbpsThreshold`** (default **5** Mbps), ffmpeg stops **immediately** (exit **125**). There is **no** extra multi-minute hold; `-DlnaIdleStopMinutes` / `-DlnaIdleStopSeconds` only **enable** monitoring when **> 0** (use **0** to disable).
- Until about **305 seconds** of samples exist after arming, **`w0`–`w4`** stay **`n/a`** (five 1‑minute windows are not computable yet), so the condition is not evaluated.
- **Other traffic on Wi‑Fi** (updates, cloud sync, other devices) affects the same counters—tune the threshold or use **manual stop** if needed.
- Poll log: **`segmentcopy_logs/dlna_wifi_upload_<PID>.log`**. Columns include **`five_win_ready`**, **`all5_under_th`** (all five windows strictly < threshold), and **`streaming_high`** (all windows strictly > threshold). Timestamps are **local machine time** (`Get-Date`, no UTC suffix).

### Deprecated: NTFS `LastAccessTime` (`-DlnaIdleLegacyLastAccess`)

Pass **`-DlnaIdleLegacyLastAccess`** to use the old segment-file **LastAccessTime** heuristic (still unreliable: ffmpeg writes, indexers, media servers, etc.). Requires **fsutil** last-access behavior that updates timestamps on reads. Log: **`segmentcopy_logs/dlna_lastaccess_<PID>.log`** (local timestamps).

**Why LastAccess was dropped as default:** timestamps are often wrong or noisy for “is someone reading over DLNA,” as described in older notes in this section’s git history.

Treat **DLNA idle stop as experimental**. Prefer **manual stop** or a **server-side** signal when possible.

### Console: Space pause vs DLNA idle

- **Space** pauses/resumes the segment remux ffmpeg only (`NtSuspend` / `NtResume` on `3d_op_*.mkv` processes). **Enter** stops ffmpeg and exits **130**.
- **DLNA Wi‑Fi idle monitoring keeps running while paused.** The PowerShell wait loop still samples Wi‑Fi every **30s**; pause does not reset or disable the five-window heuristic.
- After both segment files exist, you need **~305s** of samples before `w0`–`w4` are ready; then if **all five** minute averages stay **strictly <** the Mbps threshold (no DLNA/streaming traffic on Wi‑Fi), ffmpeg is killed with exit **125** even when Space-paused.
- **Run timeout** (default **3600s**, mutex + ffmpeg wall clock) also keeps ticking while paused (exit **124**).

For current parameters, see comment-based help in `Run-SegmentCopy.ps1`.
