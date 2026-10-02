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

## Next: M1 (PLAN section 11)
GPU cloud generation (noise-warped Gaussian first), Morton-sorted batches of 4096 at 4 bytes/point, batch cull, additive native-4K compute raster, composite before `HdrOutputPass`, 1 B points measured, int64 vs fp16x4 atomics benchmarked. Put code in `Game/points/`, shaders in `Game/Shaders/` (compiled by `Game/shaders.cfg`).
