# Shatter

First-person incremental game about collecting billions of points ("diamond dust"), built on NVIDIA RTXPT (D3D12). **Read `Docs/HANDOFF.md` first and follow its budget rules**: the user has very little usage left and the goal is a playable demo. `Docs/PLAN.md` is the long-term vision; read it only for design questions.

## Ground rules
- Build for one machine only: RTX 5090 / 9800X3D / Win 11 / LG C2 42" HDR at 4K120. No fallbacks, no compatibility paths, no other vendors.
- Budget-critical: no subagents, no web research, no exploratory reads. Batch work; one build and one screenshot per step (HANDOFF section 3).
- Reuse before writing: existing libraries and assets first (see PLAN §13). Write code only for what is novel.
- Phase 1 is point collecting only. Don't build progression systems until the user asks.

## Layout
- Repo root: NVIDIA RTXPT, merged in with its history (remote `rtxpt`, see PLAN §3). Keep engine edits minimal and mark them `// SHATTER:`.
- `Game/`: all Shatter code and shaders.
- `Tools/`: bench/screenshot scripts.

## Verifying work
Don't claim a visual or performance result without evidence. Use the game's own hooks (HANDOFF section 3: Tools/build.ps1, Tools/shot.ps1):
- `--bench <s> --camera <preset>` gives per-pass GPU ms and VRAM as JSON. Compare before and after every perf change.
- `--screenshot <path> --frame N` writes EXR + tonemapped PNG. Read the PNG to check visuals. The user judges HDR on the actual display.
