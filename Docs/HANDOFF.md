# Shatter: hand-off for the cloud session

Read `CLAUDE.md` and `Docs/PLAN.md` first. This file is the current state and how to work across the Linux cloud container and the user's Windows PC.

## State (branch `claude/vigilant-noether-3kj2qi`)
- **M0 is done except the user's HDR check, which they confirmed looks good.** RTXPT v.1.8.1 is merged in; Donut is vendored (edits marked `// SHATTER:`).
- Streamline 2.14.1, Agility SDK 1.619, DXC 1.9.2602.17. High-performance adapter forced. HDR10 swapchain + GT7 tone mapper (`Game/Shaders/HdrOutput.hlsl`, pass in `Game/Hdr/`). Dynamic MFG in the frame-gen dropdown.
- Automation (`Game/Automation/`): `--bench`, `--camera`, `--screenshot`, `--frame`, `--fg` (see `Rtxpt/SampleCommon/CommandLine.cpp`). Bench JSON and screenshots go to `Tools/out/` (gitignored).
- Baseline (kitchen, 3840x2141 window, DLSS-RR, internal 2227x1242): 125 fps with FG off; 4x FG measured multiplier 4.0 at ~100 base fps. PathTrace 4.06 ms, DLSS 2.56 ms, FinalOutput 0.08 ms. Process VRAM 5.8 GB.

## What the cloud container cannot do
It is Linux. It cannot build (MSVC, D3D12, Streamline are Windows-only), run the app, take screenshots, or measure anything. So:
- Write code, HLSL and docs there; keep changes small and reviewable; commit and push to the branch.
- **Never claim a build, visual or performance result.** Anything that needs the PC goes back to the user, who runs it (or asks the local Windows session) and reports the output.

## Windows checks (the user or the local session runs these)
```
cmake -S . -B build
cmake --build build --config Release --parallel
bin\Rtxpt.exe --scene kitchen.scene.json --width 3840 --height 2160 --camera default --bench 15
bin\Rtxpt.exe --scene kitchen.scene.json --camera default --screenshot Tools\out\shot.png --frame 64
```
Compare bench JSON before and after every perf change (CLAUDE.md).

## Known issues
- Windows reports a 7600-nit peak for the C2; `HdrSettings::EffectivePeakNits()` falls back to 700 outside 250..1500. The in-game override exists.
- The ImGui menu draws straight into the PQ signal (not remapped for HDR). User says it is fine for now.
- Presented fps with frame generation is an estimate (base fps x Streamline multiplier), not measured on the display. Dynamic MFG generates nothing when base fps already exceeds the 120 Hz target.
- DLSS DLLs are file version 310.9.1; not confirmed to be the 4.5 model.

## M1: point system v0 (written in the cloud, not yet built or run)
Code: `Game/Points/` (C++), `Game/Shaders/Points/` (HLSL, compiled by `Game/shaders.cfg`), hook in `Rtxpt/Sample.cpp` right after `DLSS_SR_RR` (marked SHATTER), UI panel "Shatter: points", CLI flags in `Rtxpt/SampleCommon/CommandLine.cpp`.
- **Generation** (`CloudDensity.cpp` + `PointGenerate.hlsl`): the CPU evaluates a noise-warped Gaussian density on a Morton-ordered grid (FastNoiseLite, MIT, vendored in `Game/ThirdParty`) and turns it into per-cell point offsets. The GPU then generates each 4096-point batch from those offsets. No billion-point sort is needed, batches are spatially coherent, and storage order is permuted inside a batch, so any prefix is a uniform subsample. Points are 4 bytes (11/11/10 bits in the batch AABB, dithered on decode). Clouds are capped at 512M points each (2 GB buffers); default 1B points in 4 clouds placed in a row in front of the camera on the first frame.
- **Per frame**: per-cloud batch cull (8-corner frustum test, screen-footprint LOD capped at N points per pixel with energy compensation) → indirect raster (one workgroup per batch, additive) → one composite into `ProcessedOutputColor` before bloom/tonemap. GPU passes `Points_Cull`, `Points_Raster`, `Points_Composite` show up in bench JSON; `points.*` holds counts, VRAM and generation times.
- **Accumulation modes**: int64 `InterlockedAdd` with 21/21/22-bit fixed point and stochastic rounding (default), or NVAPI `NvInterlockedAddFp16x4` into RGBA16F. Optional wave pre-aggregation (`WaveMatch` + `WaveMultiPrefixSum`) for batches that are small on screen.
- **Built and measured on the 5090** (commit c8af66b, kitchen, default camera, 3840x2141 window, DLSS-RR, FG off, `Tools/bench_points.ps1`):

| run | points total | rendered/frame | raster ms | throughput | frame ms |
|---|---|---|---|---|---|
| raw (no LOD), int64 | 250M | 133M | 1.94 | 69 G/s | 9.7 |
| raw, int64 | 500M | 264M | 3.75 | 70 G/s | 11.4 |
| raw, int64 | 1B | 525M | 7.23 | 73 G/s | 14.9 |
| raw, int64 | 2B | 1.04B | 14.4 | 72 G/s | 22.2 |
| raw, int64, no wave aggregation | 1B | 525M | 7.24 | 72 G/s | 14.9 |
| raw, NVAPI fp16x4 | 1B | 525M | 13.7 | 38 G/s | 21.8 |
| LOD 16 ppp, int64 | 4B (15.4 GB) | 1.04B | 14.4 | 72 G/s | 22.3 |

  Cull 0.02-0.06 ms, composite 0.13 ms, PathTrace ~3.8 ms. Generation: 36 ms GPU + 0.65 s CPU for 4B points.
  - **int64 fixed point wins** (1.9x faster than fp16x4) and stays the default.
  - Wave aggregation makes no difference in this view (batches are rarely small on screen this close); revisit with distant clouds.
  - The LOD cap barely bites up close: the AABB screen rectangle overestimates a batch's footprint. Tighten in M2.
  - Throughput scales linearly, so at ~72 G/s the 4-6 ms point budget (PLAN 2) means about 300-430M rasterized points per frame at 4K. LOD has to keep it there.
- **Bugs found on hardware and fixed**: missing UAV barrier between cull and finalize (NVRHI skips automatic barriers when the binding set doesn't change), which drew a random subset of batches each frame (visible flashing); `std::exit` teardown crashing at the end of automation runs (now `TerminateProcess` after results are written); RTXPT pausing rendering when unfocused, which stalled automation runs; vertical and horizontal bands in the clouds. The bands came from scattering each density cell's points uniformly over a 2-cell box, which sums to a staircase density. Generation now uses a quadratic B-spline kernel, and per-point hashes no longer share streams (brightness was correlated with the y dither).
- Known: `--debug` shows two NVRHI validation errors from existing graphics passes (framebuffer format mismatch in `setGraphicsState`, `drawIndirect` without indirect params). Not from the point system; still to track down.
- Known M1 limits: placeholder shading (M2 does glints); points have no motion vectors yet, so frame generation will ghost them; the depth test uses the render-resolution jittered depth (edge shimmer possible); Hi-Z occlusion deferred to M3; generation is synchronous on the first frame.

### Windows checks for M1 (run from the repo root)
```
cmake -S . -B build                                   # re-run: new source files are globbed
cmake --build build --config Release --parallel
bin\Rtxpt.exe --scene kitchen.scene.json --camera default --debug --bench 5 --pointsM 100
     # D3D12 debug layer + NVRHI validation: any errors/warnings mentioning Point* in the log?
bin\Rtxpt.exe --scene kitchen.scene.json --width 3840 --height 2160 --camera default --fg 0 --screenshot Tools\out\points.png --frame 64
powershell -ExecutionPolicy Bypass -File Tools\bench_points.ps1     # full sweep (about 2 min); -Quick for 3 runs
```
Then check visually: clouds in front of the default camera, hidden correctly behind kitchen geometry, no grid or lattice patterns, and int64 vs fp16x4 look the same.

## Next: M2 (PLAN section 11)
Diamond-dust shading (crystal habits, spectral glints, bilinear glint splats), point motion vectors + depth for frame generation, Rec.2020 working space for the point layer.
