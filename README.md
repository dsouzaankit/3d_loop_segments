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

**Output** uses the Skybox DLNA path **`F:\f1_media\3d_fullsbs_trans`**, always backed by **`%AppData%\3d_loop_segments`**. Each run maps **`subst F:`** → `%AppData%\3d_loop_segments_F_subst` with a junction so ffmpeg and Skybox still see the `F:\...` path. A **physical F: drive must not be mounted** (the script errors if `F:` exists without being our subst). On exit, **`subst F: /d`** and the junction are removed; AppData files remain.

**Downstream streaming** (e.g. DLNA to a client over a link slower than your media bitrate) is a **separate** bottleneck from “reading the source over SMB.”

---

## DLNA output root (`F:` / `%AppData%`)

Skybox/DLNA still uses **`F:\f1_media\3d_fullsbs_trans`**. `Run-SegmentCopy.ps1` always calls **`Ensure-DlnaSegmentRoot`** after the instance mutex:

| F: at start | What happens |
|-------------|--------------|
| Absent | `subst F:` → AppData subst mount; junction → `%AppData%\3d_loop_segments`. |
| Our subst from a prior run | Refresh junction; reuse mapping. |
| Physical drive or foreign `subst` | **Error** — free `F:` before running. |

On exit, **`Remove-DlnaSegmentRootSubst`** removes our junction and `subst F: /d`. AppData data stays. Subst mount name **`3d_loop_segments_F_subst`** avoids clashing with `3d_playlist_local`.

### Media obfuscation (quit / startup)

Same pattern as `3d_playlist_local`:

- **Startup** (`Ensure-DlnaSegmentRoot`): restores any `<sha256>.tmp` segment files using scrambled **`.dlna_obf_map.json`** in the DLNA root (`3d_op_00.mkv` / `3d_op_01.mkv` names come back).
- **Quit** (`Invoke-DlnaWorkflowQuitCleanup` in `Run-SegmentCopy.ps1` `finally`): stops leaf ffmpeg, renames media to `<sha256(relativePath)>.tmp`, writes/updates the map, removes `subst F:`. Media is **hidden from DLNA**, not deleted.
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
