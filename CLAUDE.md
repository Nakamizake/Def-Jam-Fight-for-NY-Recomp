# CLAUDE.md

Static-recompilation port of Def Jam: Fight for NY (GameCube `GNWE69`) on RingOut's fork of
DolRecomp + ModernGekko (chosen for speed). Human-facing docs: README.md, CONTRIBUTING.md and
docs/.

## Rules

- Never commit or distribute anything derived from the disc (`disc/`, `extracted/`, generated C,
  modules, profiles, savestates). Check `git status` before any commit.
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
  `dist/RingOut-1.0-dist/module-src`. Edit it in place, build with
  `scripts/build-tools.ps1 -NoPatch`, then save the edits with
  `scripts/save-ringout-patch.ps1 00NN-name` (patches live in `patches/RingOut/`).
- `extracted/GNWE69/` — extracted disc (`sys/main.dol`, `files/`).
- `scripts/run.ps1` runs the game; `scripts/bench.ps1` benchmarks it unattended through the
  automation directory (`--automation-dir`, `--load-state`).
