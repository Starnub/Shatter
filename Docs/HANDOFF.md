# Shatter: hand-off (read this first, then act)

## 0. Budget rules (most important)
The user has about **$17 of usage left** and wants **at least a playable demo**. Every token counts:
- **No subagents, no web research, no codebase exploration.** Everything needed is in this file. Open a file only to edit it; `grep -n` for the exact spot first.
- Don't read `Docs/PLAN.md` (long-term vision). The demo scope in section 6 overrides it.
- **One remote command per step**: `Tools\build.ps1` and `Tools\shot.ps1` (section 3). View small JPG previews (480-960 px), never 4K PNGs.
- Don't poll repeatedly. If you must wait, use one `start_process` running a PowerShell wait loop (≤ 55 s).
- Don't download DXC into the cloud container. The PC build compiles shaders in about 10 s and reports errors.
- Batch edits: write a whole feature, then build once. Fix all reported errors in one pass.
- Keep chat replies short. Commit and push after each working step (the cloud container is ephemeral).

## 1. Setup
- **Repo** `starnub/shatter`, branch `claude/admiring-goodall-lagxs1` (continues `claude/vigilant-noether-3kj2qi`; the PC clone is checked out on it). The cloud session edits in `/home/user/Shatter`, commits and pushes. The PC pulls and builds.
- **PC**: Windows 11, RTX 5090 32 GB, 9800X3D, LG C2 42" (HDR, 4K 120 Hz). Clone at `C:\dev\Shatter`, build dir `build\`, exe `bin\Rtxpt.exe`.
- **Remote access**: Desktop Commander MCP, tools `mcp__Remote_Desktop_Commander__*` (load with ToolSearch: `select:mcp__Remote_Desktop_Commander__start_process,mcp__Remote_Desktop_Commander__read_file,mcp__Remote_Desktop_Commander__read_process_output,mcp__Remote_Desktop_Commander__list_directory`). Device "Starnub". Use `shell: "powershell.exe"`.
  - If calls time out or the device is offline: ask the user to run `npx.cmd @wonderwhy-er/desktop-commander@latest remote` in PowerShell and keep that window open.
  - `read_process_output` often returns immediately. Check results with `read_file` / `list_directory` instead.
  - Commands that kill processes by command line must exclude themselves (`$_.ProcessId -ne $PID`), or they kill their own shell.
- The session's permission mode is Auto. A session can't grant itself permissions, so some calls may prompt the user.

## 2. State (commit `363758c` and later)
- **Engine**: NVIDIA RTXPT 1.8.1 path tracer merged at the repo root (D3D12; DLSS 4.5 SR/RR/FG/Dynamic MFG via Streamline 2.14.1; Agility SDK 1.619, SM 6.9). Engine edits are marked `// SHATTER:`.
- **M0 (done)**: HDR10 output with the GT7 tone mapper (`Game/Hdr/`, `Game/Shaders/HdrOutput.hlsl`); automation (`Game/Automation/`: `--bench`, `--screenshot`, named camera presets in `Game/camera_presets.json`).
- **M1 (done, measured)**: point clouds in `Game/Points/` (C++) and `Game/Shaders/Points/` (HLSL).
  - Generation: a CPU density grid (`CloudDensity.cpp`, FastNoiseLite noise-warped Gaussian with a spherical falloff) becomes Morton cell offsets. `PointGenerate.hlsl` then writes 4096-point batches at 4 bytes per point (11/11/10 bits inside each batch AABB), scattered with a quadratic B-spline kernel. There's a 1-bit "collected" mask per point (`Cloud::collected`, zeroed, not used yet).
  - Per frame: `PointCull.hlsl` (frustum test + LOD cap, indirect args) → `PointRaster.hlsl` (additive; int64 fixed point with stochastic rounding into a display-res `uint64` buffer; depth test against the render-res depth) → `PointComposite.hlsl` (adds into `ProcessedOutputColor` before bloom and tonemap).
  - Hook: `Rtxpt/Sample.cpp`, right after the `DLSS_SR_RR` profiler block (grep `SHATTER: diamond-dust`). Clouds are generated on the first frame: a row of 4 clouds 3 m in front of the camera, 1B points total.
  - Settings: `shatter::PointSettings` (`PointCloudSystem.h`), stored in `m_ui.Points`, with a UI panel "Shatter: points" in `Rtxpt/SampleUI.cpp`.
  - Shading is a placeholder: tint × random brightness ÷ d².
  - Perf at 4K on the 5090: raster about 72 G points/s (1B points per frame takes 14.4 ms), cull 0.03 ms, composite 0.13 ms, PathTrace about 3.8 ms. 4B points fit in VRAM (15.4 GB).

- **D1 (done, builds)**: game mode in `Rtxpt/Sample.cpp` (grep `SHATTER: game mode`). Tab toggles it; it's on by default and off in bench/screenshot runs. It captures the cursor with raw motion, holds a synthetic left button so `FirstPersonCamera` mouse-looks, hides ImGui, and moves at `m_gameMoveSpeed` (2 m/s; scroll changes it). RMB is left free for the vacuum.
- **Void scene (default)**: `Game/Scenes/shatter-void.scene.json`, copied into `Assets\` by `build.ps1` (Assets is NVIDIA's submodule). The scene's env `radianceScale` is ignored, so `Sample.cpp` zeroes the environment intensity for this scene by name. Fixed exposure EV 3. Clouds start 6 m out. Game-mode rotate speed is .0015. Screenshots: `shot.ps1 -Scene shatter-void.scene.json -NoCamera`. Play: double-click `bin\Rtxpt.exe`.

- **D2/D3/D5 (built, awaiting play test)**: `Game/Shaders/Points/PointVacuum.hlsl` (`main_capture`, `main_particles`), wired in `PointCloudSystem::Render` (capture after cull, particles after raster; int64 mode only). Capture probability adapts on the CPU from the read-back candidate weight so captures hit `vacuumRate` (300/s) within `vacuumRadius` 0.5 m / `vacuumConeDeg` 30. Particle ring of 65536 in `m_particles`; totals in `m_vacuum` (read back with the stats). Input: RMB or F (E is camera up), R respawns. HUD in `SampleUI::buildUI` (`Points.showHud`). Tuning knobs are in `PointSettings`.

- **Motion/cloud**: `AnimatePoint` in `PointRaster.hlsl` is drift only (5 mm coherent current; the user liked it). A visual pull toward the nozzle was tried and removed: it looked bouncy and fake. Clouds are stacked (`stackClouds`): 1B points as 2 buffers sharing one center and density shape, radius 0.6 m, brightness 2.
- **Vacuum v2 (mass suction, built)**: few bright particles always looked like 'popping in' (a single cloud point is invisible). Now captures 3M/s with a soft distance/angle falloff (no cookie-cutter edge); particles spawn at the drifted position with the exact cloud brightness (`PointBrightness`, `DriftPoint` in PointCommon.hlsli) and follow a 1/d^2 sink flow into the jar mouth (`main_jar` draws the jar; full = 1e9). Ring of 8M particles (256 MB), max age 2.5 s. Test without input: `--vacuum` (cloud edge 0.1 m from the camera, vacuum held); bench JSON has `collected` (17.8M in a 4 s run).

## 3. Commands (on the PC, in `C:\dev\Shatter`)
- **Build**: `powershell -ExecutionPolicy Bypass -File Tools\build.ps1` pulls, builds Release, and prints only errors plus `BUILD EXIT n`. Add `-Configure` after adding or removing source files (`Game/` globs its sources).
- **Screenshot**: `powershell -ExecutionPolicy Bypass -File Tools\shot.ps1 -Name x` writes `Tools\out\shot\x.jpg` (960 px). Options:
  - `-Scene bistro-programmer-art.scene.json -NoCamera` for a different scene with its own camera
  - `-Extra "--pointsM 250"` to pass extra app flags
  - `-Crop "x,y,w,h"` to also write a 1:1 crop PNG
  - `-PreviewWidth 480` for a smaller preview
- **Play** (the user): `bin\Rtxpt.exe --scene bistro-programmer-art.scene.json`
- **App flags**:
  - `--noPoints --pointsM N --pointClouds N --pointAtomic 0|1 --pointLod 0|1 --pointAgg 0|1 --pointPpp X --pointGrid N`
  - `--fg N` (0 = frame generation off), `--camera <preset>`, `--bench <s> --benchOut <json>`, `--debug` (D3D12 + NVRHI validation), `--nonInteractive`
- **Logs** go only to OutputDebugString. `Tools\m1_checks.ps1` shows how to capture them with DebugView. Avoid unless something crashes.
- **Scenes** in `Assets\`:
  - `bistro-programmer-art` (outdoor street at night, recommended for the demo)
  - `kitchen` (camera preset `default`)
  - `transparent-machines` (glass)
  - `programmer-art(-proc-sky)`, `living-room`

## 4. Pitfalls already paid for (don't re-learn)
- **NVRHI barriers**: automatic barriers are only placed when the bound binding set changes. Two dispatches that share a binding set need `commandList->setBufferState(buf, nvrhi::ResourceStates::UnorderedAccess); commandList->commitBarriers();` between them. Missing this caused the flashing bug.
- For atomic-only passes, disable UAV barriers with `setEnableUavBarriersForBuffer/Texture(x, false)` and re-enable afterwards (already done for the accumulation and stats buffers).
- **Volatile constant buffers**: call `writeBuffer` before each dispatch that needs different constants (`maxVersions` is 256).
- **Shaders**: add them to `Game/shaders.cfg`. Load with `m_shaderFactory->CreateShader("shatter/Shaders/<path>.hlsl", "<entry>", &defines, desc)`. Permutations use `-D NAME={0,1}`. Start each file with `#pragma pack_matrix(row_major)` and use `mul(float4(p,1), M)`. SM 6.9 (int64 atomics, `WaveMatch`, `[WaveSize(32)]`). D3D12 only.
- **Random numbers**: give every random quantity its own `PcgHash(h ^ CONSTANT)` stream. Reusing one stream for two quantities caused banding.
- **Projection**: reverse-Z with an infinite far plane. The render-res `Depth` texture holds NDC z (0 = sky); linear depth = `zNear / z`. Points use `GetViewProjectionMatrix(false)` (no jitter).
- RTXPT pauses rendering when its window is unfocused. Automation runs override this (`Sample::ShouldRenderUnfocused`). Automation exits with `TerminateProcess` (`std::exit` teardown crashed).
- Known and harmless: `--debug` reports 2 NVRHI validation errors from RTXPT's own graphics passes.

## 5. Key code locations
| What | Where |
|---|---|
| Point system C++ | `Game/Points/PointCloudSystem.{h,cpp}`, `Game/Points/CloudDensity.{h,cpp}` |
| Shared C++/HLSL structs | `Game/Shaders/Points/PointShared.h` (`PointBatch`, `PointFrameConstants`), helpers in `PointCommon.hlsli` |
| Frame hook, input, camera | `Rtxpt/Sample.cpp`: `Render()` (grep `SHATTER`), `KeyboardUpdate`, `MousePosUpdate`/`MouseButtonUpdate`, `m_camera` (Donut `FirstPersonCamera`) |
| UI | `Rtxpt/SampleUI.cpp` (grep `Shatter: points`); UI data struct `SampleUIData` in `Rtxpt/SampleUI.h` |
| CLI flags | `Rtxpt/SampleCommon/CommandLine.{h,cpp}` (grep `SHATTER`), applied once in `Sample::Render` where `m_automation` is created |

## 6. Demo scope (in order; stop when the budget runs low)
Goal: launch, then fly or walk around the bistro street full of glittering clouds. Hold a button to vacuum points, which stream into you while a counter goes up. Clouds can respawn.

1. **D1 Controls**: RTXPT already has a fly camera (Donut `FirstPersonCamera`). Add a "game mode" toggle (e.g. Tab):
   - Mouse-look without holding a button (`glfwSetInputMode(window, GLFW_CURSOR, GLFW_CURSOR_DISABLED)`; the window is `GetDeviceManager()->GetWindow()`)
   - ImGui UI hidden
   - Walking-pace move speed

   Check the existing bindings in `KeyboardUpdate` first to avoid conflicts. Default to game mode on.
2. **D2 Vacuum**: a new `PointVacuum.hlsl`, one workgroup per batch (reuse each cloud's visible list or all batches).
   - Points within about 4 m and about 20° of the camera's forward axis are captured with some probability per frame.
   - On capture: `InterlockedOr` the collected bit (bind `collected` as a UAV here), append to a particle buffer (position, velocity, seed; cap 2M; atomic counter), and add to a global collected counter (`uint64`, read back like the existing stats ring).
   - A particle pass updates particles toward a nozzle (camera pos + forward × 0.4 − up × 0.15) with some swirl, removes them on arrival, and rasterizes them into the same int64 accumulation buffer before composite.
   - Input: hold the right mouse button (or E).
3. **D3 HUD**: a minimal ImGui overlay showing the collected count, visible in game mode.
4. **D4 Glints (cheap version of M2, big visual payoff)**: in `PointRaster.hlsl`, replace the placeholder shading.
   - Per-point random unit normal (hash), a fixed sun or light direction, and the view direction.
   - `glint = pow(saturate(dot(n, normalize(L + V))), ~1000-3000)` × a strong intensity, with a spectral hue per point (hash or angle based).
   - Keep a dim base scatter so the cloud body stays visible.
5. **D5 Respawn**: the R key sets `m_ui.Points.regenerate = true`.
6. **D6 (optional)**: spread the clouds along the bistro street (per-scene defaults for count, radius and distance).

Out of scope for the demo: the crystal valley, path-traced dispersion, physics, audio, glare, and point motion vectors (play with frame generation off).

**Verify**: build → `shot.ps1` → for anything interactive (input, vacuum), ask the user to play it and report back rather than building automation for it.
