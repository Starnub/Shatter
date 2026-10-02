# Shatter: Phase 1 Plan, "Diamond Dust"

Phase 1 is only about collecting points, and it should feel great before any progression exists. Progression (0D points → 1D lines → 2D planes → 3D polyhedra → 4D polychora) gets designed after this is polished.

## 1. Vision

You walk a crystal valley stuck at golden hour. Clouds of **diamond dust** hang between quartz spires and drift over salt pans: billions of tiny crystal facets, each one flashing a pure spectral color when the sun, the facet and your eye line up. Standing inside a cloud and looking toward the sun, you see the 22° halo, sun dogs and sun pillars. Nothing paints them on; they come out of billions of individually shaded points, the same way they form in real diamond dust. You walk and glide up to a cloud, aim the nozzle, and the points spiral into it along swirling vortex paths and pile up as a glittering swarm inside a glass canister.

## 2. Target machine (no fallbacks, no compatibility paths)

| Part | Value | Consequence |
|---|---|---|
| GPU | RTX 5090, 32 GB, Blackwell | DXR 1.2, SER, OMM, SM 6.9, LSS/sphere primitives, cluster AS, DLSS 4.5 (RR, Dynamic MFG) |
| CPU / RAM | 9800X3D / 64 GB DDR5-6000 | CPU barely matters: everything is GPU-driven |
| Display | LG C2 42" WOLED, 4K 120 Hz, VRR, HDMI 2.1 | ~650-700 nits on a 10% window, only ~110-150 nits full-field (ABL). HGIG mode. Burn-in risk from static HUD. |
| OS / driver | Win 11 26200, driver 610.88 | Above RTXPT's minimum (595.71) |
| iGPU | Radeon (on the 9800X3D) | **The monitor must be plugged into the 5090.** The app must pick the NVIDIA adapter explicitly (`EnumAdapterByGpuPreference(HIGH_PERFORMANCE)`) |

**Frame budget.** Render a base frame at ~60 fps, then DLSS 4.5 frame generation fills to 120 Hz, with Reflex on. Internal path-tracing resolution comes from DLSS SR (Performance/Balanced to start). Points render at **native 4K** after upscaling. Targets (to be measured, not promises):

| Pass | Target |
|---|---|
| Path tracing at internal res + DLSS RR/SR | 6-8 ms |
| Point system at native 4K (cull + raster + composite) | 4-6 ms, about 1-2 billion points per frame |
| Vacuum sim, volumes, tonemap, misc | 1-2 ms |

## 3. Foundation: fork NVIDIA RTXPT instead of writing an engine

[RTXPT](https://github.com/NVIDIA-RTX/RTXPT) (v1.8.1, D3D12/Vulkan, built on Donut + NVRHI) already ships nearly everything around the novel parts:

- Path tracer derived from Falcor, with **nested dielectrics with priority + volumes** (crystals with inclusions), SER, OMM, RTXDI (ReSTIR DI/GI)
- DLSS SR / RR / FG / MFG via Streamline, NRD denoisers, ImGui, glTF, ShaderMake
- NVRHI exposes **Linear Swept Spheres and cluster acceleration structures on D3D12** (Blackwell). That's a stretch path for showing vacuumed particles in refractions.

License: NVIDIA RTX SDK license. Fine for a personal project; if Shatter is ever released, it needs attribution ("contains source code provided by NVIDIA") and a notice to NVIDIA before shipping DLSS.

**Repo layout.** RTXPT depends on git submodules, which `git subtree` doesn't carry, so its history is merged straight into this repo: add it as remote `rtxpt`, merge its latest release tag with `--allow-unrelated-histories`, then `git submodule update --init --recursive`. Upstream updates become `git fetch rtxpt` plus a merge of the newer tag. Before the first merge, check for case-insensitive path collisions (Windows), e.g. our docs/ against RTXPT's Docs/ (resolved by renaming ours to Docs/).

```
/          RTXPT root (engine + its submodules); edits kept minimal and marked `// SHATTER:`
/Game/     all Shatter code: points/, world/, player/, vacuum/, audio/, hdr/, shaders/
/Tools/    bench + screenshot scripts used by Claude Code during iteration
/Docs/     this plan (RTXPT's own docs live here too)
```

**Upgrades to the fork at M0:** latest Streamline (2.11.x / DLSS 4.5 with Dynamic MFG), Agility SDK 1.619 (SM 6.9 retail), DXC 1.9.2602+.

**Deliberately not used in Phase 1:** work graphs (indirect dispatch covers every GPU-driven step here), cooperative vectors (deprecated in SM 6.9 in favor of SM 6.10 LinAlg, still in preview), neural texture compression (no texture-heavy content). They come back only if a measured problem calls for them.

## 4. The diamond-dust point system (the core)

### 4.1 Storage: about 4 bytes per point
- Clouds are **generated on the GPU at load** from seeds, so nothing is shipped. Generators: noise-warped Gaussian bodies, curl-noise wisps, strange attractors (Aizawa, Thomas, Halvorsen, Lorenz), 3D IFS "fractal dust" via the chaos game, plus a horizontal-plate "sheet" cloud that lies low over the salt pans. Fractal dusts have non-integer dimension (a Cantor-like dust sits between 0D and 1D), which is a natural hook for Phase 2.
- Points are Morton-sorted with a GPU radix sort (b0nes164/[GPUSorting](https://github.com/b0nes164/GPUSorting) OneSweep for D3D12, license to be checked, or FidelityFX Parallel Sort (MIT)) and then cut into **batches of 4096**. Each batch stores an fp32 AABB. Each point stores **3 × 11/11/10-bit offsets inside its batch AABB = 4 bytes**, which is sub-millimeter precision. Points are shuffled inside each batch so any prefix is a uniform subsample (LOD for free).
- **Nothing else is stored per point.** Crystal habit, orientation, size and material come from `hash(cloudId, pointIndex)`.
- Collected state is a **1-bit mask per point**.
- Budget: 1 B points at M1, then scale toward **4 B (≈16 GB positions + 0.5 GB mask)** while there's VRAM headroom. If more is ever wanted, instanced cloud templates come next (CuRast showed 4 B instanced triangles at 60 fps on a 5090).

### 4.2 Rendering: compute rasterization at native 4K, additive, order-independent
This builds on Schütz, Kerbl & Wimmer's compute point rasterizers (2021, [2022 "2 Billion Points"](https://www.cg.tuwien.ac.at/research/publications/2022/SCHUETZ-2022-PCC/SCHUETZ-2022-PCC-paper.pdf)) and [CuRast (2026)](https://github.com/m-schuetz/CuRast), with one important change. Real diamond dust is sparse and translucent, so points barely occlude each other. Instead of their 64-bit `atomicMin` nearest-point visibility, Shatter **sums radiance** per pixel. That is physically right for glints, has no sorting and no order dependence, and aliases far less than winner-takes-all.

Per frame:
1. **Batch cull** (one thread per batch): frustum, Hi-Z occlusion against scene depth, distance → LOD: all points / a prefix subsample with energy compensation / volume-only. Writes indirect dispatch args.
2. **4K scene depth**: depth-only raster of terrain + crystals at native 4K (mesh shaders, well under 1 ms). Glass surfaces write depth, so points behind a crystal are hidden here and show up *refracted* through the path tracer instead (§4.5).
3. **Raster** (one workgroup per batch, one thread per point): decode → mask test → project → depth test → glint shading (§4.3) → accumulate.
   - Accumulate into a 4K buffer with 64-bit integer `InterlockedAdd` (RGB packed as 21/21/22-bit fixed point, scaled by last frame's exposure). The alternative to benchmark is NVAPI `NvInterlockedAddFp16x4` into RGBA16F.
   - Pre-aggregate inside the wave (`WaveMatch` + `WaveActiveSum`) when many lanes hit the same pixel, which is common for distant dense batches.
   - Dim points splat to one pixel. Bright glints splat **2×2 bilinear** for temporal stability.
   - Points above a brightness threshold also `InterlockedMin` their depth into a point-depth buffer, which feeds motion vectors and depth to frame generation.
4. **Composite** onto the upscaled HDR scene color before tonemapping, with merged depth/MVs, then hand off to DLSS FG.

**Working color space: linear Rec.2020** for the point layer and the final composite. Spectral glints are the most saturated colors physically possible, and clipping them to Rec.709 would waste the C2's ~P3 gamut.

### 4.3 Glint shading: real ice/diamond optics per point
Each point is a tiny crystal with a hashed orientation drawn from a per-cloud distribution:
- **Random 3D** orientation → 22° and 46° halos
- **Horizontal plates** (c-axis vertical with a few degrees of wobble) → sun dogs, sun pillar, circumzenithal arc
- **Horizontal columns** → upper tangent arc and Parry arcs

For each point, the shader evaluates a few analytic ray paths:
- **External reflection** off the face whose normal is closest to the sun-eye half-vector. This gives white glints and the sun pillar.
- **Refraction through a 60° prism face pair** (minimum deviation with ice n≈1.31 is 21.8°, the 22° halo) and through a **90° basal/prism pair** (45.7°, the 46° halo).
- **Dispersion**: n(λ) from a Cauchy fit (ice ≈1.306 red → 1.317 blue; diamond 2.41-2.45 for far stronger "fire"). Along each path the shader solves for the wavelength λ* whose outgoing direction points at the eye. Intensity = Fresnel transmittances × a Gaussian in the angular miss, using the sun's angular radius (0.27°) plus facet imperfection. Color = CIE(λ*) → Rec.2020.
- A cheap early-out rejects the vast majority of points that can't glint this frame. Non-glinting points add a faint scattering term that gives the cloud its body.

Incoming sun light per point comes from a **baked light volume** per cloud (§4.4), so points in a crystal's shadow go dark and points in its dispersed beam glint in that beam's colors. Cloud materials: ice first; diamond and quartz clouds add variety later.

### 4.4 Baked light (the sun and the scene never move)
A fixed sun over a static valley means most of the expensive light transport is a **one-time load cost**:
- **Per-cloud sun light volume** (≈128³, RGB9E5): photons are traced from the sun with inline ray queries through the crystal meshes, spectrally, so they carry dispersion-colored transmission, shadowing and focused caustic beams, plus the cloud's own extinction toward the sun.
- **Ground caustic lightmap**: the terrain is a heightfield, so caustics splat into a 2D texture over the valley. The path tracer adds it at diffuse ground hits and excludes sun-through-glass NEE so nothing is counted twice.
- **Halo phase-function LUT** for each crystal population: Monte Carlo through hexagonal prisms in the style of [HaloRay](https://github.com/naavis/haloray) and [Lumice](https://github.com/saqibkh/Lumice). The volume LOD (§4.5) uses it, so far clouds and near points produce the same halo.

### 4.5 Volume LOD and secondary rays
Each cloud gets a density volume, built at load by splatting its points into a grid. Far batches render as a ray-marched medium with the halo phase LUT instead of as points. The same volumes are added to the path tracer as procedural AABBs in the TLAS, so clouds appear **through refracting crystals and in mirror reflections**. Stretch goal: put the brightest/nearest active particles into a Blackwell sphere/LSS BLAS so individual vacuumed sparkles show up in refractions.

## 5. Vacuum
- **Input**: hold the mouse button and a cone pulls from the nozzle (start at ~6 m range, ~25° half-angle; tunable later as upgrades).
- **Activation** (compute): batches overlapping the cone → per-point test → the point is probabilistically captured with chance ∝ suction × falloff × dt → `InterlockedAnd` clears its mask bit, and the winning thread appends it to an **active particle buffer** (position, velocity, seed, age; budget 5-20 M).
- **Flow**: suction (inverse-square toward the nozzle, cone falloff) + swirl around the nozzle axis + divergence-free **curl noise** turbulence (Bridson 2007) + drag. Particles accelerate, spiral in, and are counted when they reach the nozzle mouth. Fast particles can draw as short velocity-aligned streaks.
- **Wake**: clouds part as you walk through them. Points near a ring buffer of the player's recent positions get an analytic displacement at render time, which costs no storage and no simulation.
- **Canister**: glass cylinder on the device. Collected points keep swirling inside it (a capped representative set) and visibly fill it up. It doubles as the diegetic counter, so Phase 1 needs no HUD numbers.
- Clouds don't respawn in Phase 1 (debug key resets them).

## 6. The crystal valley
- **Bounded valley, ~1.5 km.** Heightfield terrain from FastNoise2 (MIT) noise plus GPU hydraulic erosion. Pale salt/quartz sand, with **shallow wet salt pans as mirrors**. Mirrors double every spire, cloud and glint for little cost. The point layer can render a second time with a reflected view matrix, masked to mirror pixels, for crisp reflected glints.
- **Crystals**: procedural quartz clusters (hexagonal prism + pyramidal termination, taper, phantoms, inclusions) from pebbles to 80 m spires. About 50 variants as BLASes, instanced up to ~100k times. Clear / smoky / amethyst / citrine tints.
- **Spectral dispersion in the path tracer**: hero-wavelength sampling (Wilkie et al. 2014) added to RTXPT's dielectric BSDF. Wavelength choice is stratified across pixels so DLSS RR sees structured noise.
- **Sky**: fixed sun at ~6-10° elevation, baked once into an HDR environment map with the [Prague Sky Model](https://cgg.mff.cuni.cz/) (spectral, accurate at low sun angles). Fallback: Hillaire 2020 (MIT sample code). Analytic sun disk with limb darkening.

## 7. Player
- **Jolt Physics** (MIT) `CharacterVirtual`: walk / sprint / jump. **Glide**: hold jump in the air for reduced gravity and forward lift. Crystals are hexagonal prisms, i.e. convex hulls, which makes collision cheap and exact.
- Raw mouse input (GLFW raw motion, which Donut already uses). ~90° FOV, tunable.

## 8. HDR on the LG C2
- HDR10 swapchain (R10G10B10A2, `DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020`), flip model, tearing allowed for VRR.
- Setup on your side: **HGIG** on, Game Optimizer on, and the Windows HDR Calibration app run once. The game reads the calibrated peak from `DXGI_OUTPUT_DESC1` and has an in-game override; defaults are 700 nits peak and ~200 nits paper white.
- **Tonemapper: Polyphony's GT7 tone mapping** (SIGGRAPH 2025, MIT-licensed C++ reference). It's a color-volume mapper that avoids hue twisting, which is exactly what saturated spectral highlights need. Ported to HLSL.
- The C2's ABL means small intense highlights on a mid-tone scene, which suits this content well. Avoid large bright areas.
- **Burn-in**: no static HUD. Anything on screen is tiny and dim, and fades out after a few seconds idle.
- **Glare**: multi-scale bloom, plus optional small chromatic diffraction starbursts on the top-K brightest glints only. These get tuned by eye at M7 and dropped if they look cheap.

## 9. Audio
**miniaudio** (public domain) for mixing and output, **Steam Audio** (Apache 2.0) for HRTF spatialization. Everything is synthesized, so there are no asset licenses to manage:
- Collection: **granular chimes**. Each grain is a short FM bell whose pitch is mapped from the glint's wavelength onto a pentatonic scale, and grain density follows collection rate, so thousands per second become a shimmering wash.
- Vacuum: filtered noise plus hum, modulated by suction load. Ambience: wind, plus faint resonant tones near spires.

## 10. Iteration workflow (Claude Code running on your PC)
The game needs built-in automation so Claude Code can see and measure what it builds:
- `--bench <seconds> --camera <preset>` → JSON of per-pass GPU timestamps + VRAM usage
- `--screenshot <path> --frame N` → EXR (scene-referred) **and** a tonemapped SDR PNG. Claude Code can read the PNG; HDR judgement stays with your eyes.
- Camera presets saved and loaded by name, so before/after comparisons are reproducible
- PIX / Nsight Graphics for deep dives when the JSON isn't enough

**Install before starting:** Visual Studio 2022 (Desktop C++ workload, Windows 11 SDK), CMake ≥ 4.0.2, Git, Python 3, PIX, Nsight Graphics, Claude Code. Then clone this repo, check out this branch, and start a session with: *"Start M0 from Docs/PLAN.md."*

## 11. Milestones
| # | Milestone | Done when |
|---|---|---|
| M0 | RTXPT merged in, builds and runs; NVIDIA adapter forced; HDR10 + GT7 tonemap; DLSS 4.5 SR/RR/FG/MFG toggles; bench/screenshot hooks | Test scene runs at 4K120 with FG on the C2, and bench JSON is produced |
| M1 | Point system v0: GPU cloud generation, batches, cull, additive 4K raster, depth test, composite | 1 B points measured; throughput curve recorded; int64 vs fp16x4 atomics benchmarked |
| M2 | Diamond-dust shading: crystal habits, spectral glints, bilinear glints, point MVs for FG | Halos and sun dogs emerge on their own; FG artifacts judged by eye |
| M3 | Valley: terrain + erosion, quartz clusters, dispersion in the PT, sky bake, caustic + light-volume bake, salt-pan mirrors | Golden-hour valley screenshots you're happy with |
| M4 | Player + vacuum: Jolt controller + glide, capture/flow/collect, wake, canister | Collecting feels good in your hands |
| M5 | Volume LOD + clouds in secondary rays | Far clouds and clouds seen through crystals match near points |
| M6 | Audio | Collection sounds like glitter |
| M7 | Polish: cloud generator variety, glare, HDR calibration UI, perf pass, scale toward 4 B points | You'd show it to someone |

## 12. Known risks (honest list)
- **DLSS RR and dispersion noise.** RR is trained on ordinary RGB path tracing, so chromatic noise may smear. Mitigation: wavelength stratification, or route dispersive lobes through NRD.
- **Frame generation and sub-pixel glints.** Generated frames may ghost or drop sparkles. Point-layer MVs help. If it still looks wrong, lower the MFG factor or turn FG off and render fewer points. Decide by A/B on the C2.
- **4K atomic throughput on Blackwell** for additive accumulation is unmeasured. M1 benchmarks it before anything depends on it.
- **RTXPT is a sample, not an engine.** Game code lives around it via a thin seam; expect some surgery in `Sample.cpp`.
- **VRAM**: 4 B points plus the path-traced scene may not fit together. Start at 1 B and scale with measurements.
- Every number in this document is a target. None of it has run yet.

## 13. Libraries (existing work reused, per your rule)
RTXPT / Donut / NVRHI / Streamline / NRD (NVIDIA RTX SDK license) · DirectX Agility SDK 1.619 + DXC · NVAPI · Jolt Physics (MIT) · FastNoise2 (MIT) · GPUSorting or FidelityFX Parallel Sort · GT7 tone mapping (MIT) · miniaudio (PD/MIT-0) · Steam Audio (Apache 2.0) · Dear ImGui (MIT, via Donut) · Prague Sky Model / Hillaire 2020 sample (MIT).

## 14. References
- Schütz, Kerbl, Wimmer, *Rendering Point Clouds with Compute Shaders and Vertex Order Optimization*, EGSR 2021
- Schütz, Kerbl, Wimmer, [*Software Rasterization of 2 Billion Points in Real Time*](https://www.cg.tuwien.ac.at/research/publications/2022/SCHUETZ-2022-PCC/SCHUETZ-2022-PCC-paper.pdf), HPG 2022
- Schütz et al., *SimLOD*, 2024; Erler, Schütz et al., *LidarScout*, HPG 2025
- Schütz, Lipp, Kristmann, Wimmer, [*CuRast: CUDA-Based Software Rasterization for Billions of Triangles*](https://github.com/m-schuetz/CuRast), CGF 2026 (RTX 5090: 1 B unique / 4 B instanced triangles at 60 fps)
- Collado et al., *Virtualized Point Cloud Rendering*, IEEE TVCG 2025
- Unterguggenberger, Lipp, Wimmer, Steinberger, Kerbl, Schütz, *Adaptive LOD for Fast Rendering of Parametric Objects on Modern GPUs*, IEEE TVCG 2026. **Relevant to Phase 2**: point-rasterized lines and surfaces.
- *Virtualized 3D Gaussians: cluster-based LOD*, 2025
- Deliot & Belcour, *Real-Time Rendering of Glinty Appearances using Distributed Binomial Laws on Anisotropic Grids*, HPG 2023; *Real-Time Image-Based Lighting of Glints*, 2025
- Wilkie et al., *Hero Wavelength Spectral Sampling*, EGSR 2014
- Bridson, Hourihan, Nordenstam, *Curl-Noise for Procedural Fluid Flow*, SIGGRAPH 2007
- Polyphony Digital, *GT7 Tone Mapping*, SIGGRAPH 2025 shading course (MIT sample)
- HaloRay; Lumice; Hong & Baranoski, *A Study on Atmospheric Halo Visualization*
- NVIDIA RTXPT 1.8.1; DLSS 4.5 SDK / Streamline 2.11 (Apr 2026); Microsoft, *Shader Model 6.9 retail*, Agility SDK 1.619 (Feb 2026)
