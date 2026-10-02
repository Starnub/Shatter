# Shatter

First-person incremental game about collecting billions of points ("diamond dust") in a path-traced crystal valley. **Read `docs/PLAN.md` before doing anything**: it holds the design, architecture, milestones and the reasoning behind them.

## Ground rules
- Build for one machine only: RTX 5090 / 9800X3D / Win 11 / LG C2 42" HDR at 4K120. No fallbacks, no compatibility paths, no other vendors.
- Keep usage minimal without sacrificing quality. Use subagents or extra tool calls only when they directly improve the result.
- Reuse before writing: existing libraries and assets first (see PLAN §13). Write code only for what is novel.
- Phase 1 is point collecting only. Don't build progression systems until the user asks.
- The old 2016 `Shatter.rar` at the repo root is unrelated. Ignore it.

## Layout
- `Engine/`: NVIDIA RTXPT imported via `git subtree`. Keep edits minimal and mark them `// SHATTER:`.
- `Game/`: all Shatter code and shaders.
- `Tools/`: bench/screenshot scripts.

## Verifying work
Don't claim a visual or performance result without evidence. Use the game's own hooks (PLAN §10):
- `--bench <s> --camera <preset>` gives per-pass GPU ms and VRAM as JSON. Compare before and after every perf change.
- `--screenshot <path> --frame N` writes EXR + tonemapped PNG. Read the PNG to check visuals. The user judges HDR on the actual display.
