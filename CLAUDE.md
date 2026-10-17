# CLAUDE.md

Static-recompilation port of Def Jam: Fight for NY (GameCube `GNWE69`) on RingOut's fork of
DolRecomp + ModernGekko (chosen for speed).

## Rules

- Never commit or distribute anything derived from the disc (`disc/`, `extracted/`, generated C, modules).
  Check `git status` before any commit.
- All code, comments, commits and docs in English. Talk to the user in Brazilian Portuguese.
- Safety first (personal PC): no admin, no injection, no unverified binaries; build from source.
  Ask before installing anything outside the repo, and log it in `docs/external-footprint.md`.
- Do not commit unless asked.
- Keep paths free of spaces (it breaks DolRecomp's Windows tests).

## Toolchain (Windows)

- Runtime and recompiler: MSVC from Visual Studio 2022 Community, through the VS developer
  environment (`VC\Auxiliary\Build\vcvars64.bat`) and VS's bundled Ninja
  (`scripts/build-tools.ps1` -> `build/runtime`).
- Game module: portable Clang in `tools/llvm-mingw` (RingOut's generated code needs it;
  `scripts/build-module.ps1`, recompiler flags in `config/recomp/<id>.flags`).

## Layout

- `lib/RingOut` — submodule: RingOut's DolRecomp + ModernGekko, and the module CMake project in
  `dist/RingOut-1.0-dist/module-src`. Do not edit in place; changes live in `patches/RingOut/`
  and `build-tools.ps1` applies them.
- `lib/DolRecomp`, `lib/ModernGekko`, `patches/ModernGekko`, `patches/RecompCore` — the old
  upstream stack, kept for reference until the RingOut stack is validated.
- `extracted/GNWE69/` — extracted disc (`sys/main.dol`, `files/`).
- `scripts/run.ps1` runs the game; `scripts/bench.ps1` benchmarks it unattended through the
  automation directory (`--automation-dir`, `--load-state`).
