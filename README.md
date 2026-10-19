# DefJamFFNY-Port

An experimental native PC port of **Def Jam: Fight for NY** (GameCube, disc ID `GNWE69`),
built by **static recompilation**: the game's PowerPC executable is translated ahead of
time into C, compiled for x86-64 and run on a Dolphin-derived runtime that provides
graphics, audio, input and the rest of the console hardware.

> **No game data and no game code are included or distributed.** You supply a disc image
> you own; everything derived from it (extracted files, recompiled code, the compiled game
> module) is generated on your machine and is git-ignored.

Personal / study project, Windows only for now.

## Status

The game boots and plays: menus, the story mode and 1v1 and 2v2 fights run at full speed
(60 fps) on the development PC, including the heaviest 2v2 special moves. Still
experimental: expect rough edges, and report freezes with the diagnostics described below.

## How it works

| Stage | Tool | Output |
| --- | --- | --- |
| Extract the disc | `dolrecomp extract` | `extracted/GNWE69/` (`sys/main.dol` + game files) |
| Recompile `main.dol` | dolrecomp (C backend) | generated C sources |
| Build the game module | Clang (llvm-mingw) | `gGNWE69_recomp.dll` |
| Run | ModernGekko runtime (`moderngekko-run.exe`) | the game in a window |

Everything is built on [RingOut](https://github.com/jackpoison-prog/RingOut), a SoulCalibur II
port whose fork of [DolRecomp](https://github.com/ExpansionPak/DolRecomp) and
[ModernGekko](https://github.com/ExpansionPak/ModernGekko) is much faster than upstream.
This repository adds the Def Jam specifics: recompiler settings, game settings, a default
controller layout, fixes to the stack (as patches), and the build, run and benchmark scripts.

## Repository layout

```
lib/RingOut/        submodule: RingOut's DolRecomp + ModernGekko, and the game-module CMake project
patches/RingOut/    local changes to lib/RingOut, applied by build-tools.ps1
config/             recompiler flags and native regions (recomp/), game settings, default
                    Dolphin settings and controller layout
scripts/            build, run, benchmark and training scripts (PowerShell)
tools-src/          profiling and diagnostics helpers (Python)
docs/               notes and the external-footprint log
lib/DolRecomp/, lib/ModernGekko/, patches/ModernGekko/, patches/RecompCore/, scripts/run-legacy.ps1
                    the earlier upstream stack, kept for reference only
disc/, extracted/   your disc image and its extracted files (git-ignored)
build/              all build output, including the game module (git-ignored)
tools/              portable toolchain (git-ignored, see below)
userdata/           config, memory cards, logs and diagnostics of your game (git-ignored)
```

## Requirements

- Windows 10/11, x86-64.
- Visual Studio 2022 with the "Desktop development with C++" workload (MSVC, CMake and
  Ninja; builds the runtime and the recompiler).
- Git and Python 3.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20260616 (UCRT x86_64), unpacked to
  `tools/llvm-mingw/`. The recompiled code needs Clang; MSVC cannot build it. The exact
  archive and its SHA-256 are in [docs/external-footprint.md](docs/external-footprint.md).
- A Def Jam: Fight for NY (USA) GameCube disc image you own, as `.iso`. `.rvz` images can
  be converted with Dolphin's `DolphinTool convert -f iso`.
- About 10 GB of free disk space and 16 GB of RAM (each large generated file takes over
  1 GB to compile; lower `-Jobs` if memory runs short).

Keep the repository in a path without spaces.

## Getting started

```powershell
git clone <this repo> DefJamFFNY-Port
cd DefJamFFNY-Port
git submodule update --init --depth 1 lib/RingOut

# 1. Runtime and recompiler (applies patches/RingOut first; the first build takes a while)
.\scripts\build-tools.ps1

# 2. Extract your disc into extracted/GNWE69
.\build\runtime\dolrecomp-build\dolrecomp.exe extract disc\DefJam.iso extracted\GNWE69

# 3. Recompile the game and build the module (about 20-30 minutes)
.\scripts\build-module.ps1 -Jobs 4

# 4. Play
.\scripts\run.ps1
```

Optional, for the best speed (see [Performance](#performance)). Both scripts play fight
savestates of your own from `build/states/` (names and lengths are parameters):

```powershell
.\scripts\train-twin.ps1
.\scripts\train-pgo.ps1
```

`run.ps1` keeps all runtime data in `userdata/` inside the repository, not in
`%LOCALAPPDATA%`. Esc opens the runtime's menu (graphics, controls). `-Graphics Vulkan`
(or `D3D`, `D3D12`, `OGL`) picks a renderer.

## Controls

Any SDL gamepad works; the default layout is the PlayStation 2 release's:

| Action | PS2 / DualSense | GameCube |
| --- | --- | --- |
| Punch | Triangle | Y |
| Kick | Square | B |
| Grapple / throw / pick up | Cross | A |
| Run | Circle | X |
| Block | R1 | R |
| Strong attack modifier | L1 | L |
| Target (multi-fighter) | R2 / L2 | Z |
| Taunt / Blazin' | right stick | C-stick |

The layout is copied to `userdata/Config/GCPadNew.ini` on the first run; rebind in the
menu, or delete that file to get the default back.

## Performance

`scripts\build-module.ps1` turns on three of RingOut's speed-ups whenever their inputs exist:

- **Profile-guided optimisation**: `scripts\train-pgo.ps1` builds an instrumented module,
  plays two fight savestates (`build/states/fight-1v1.sav` and `2v2-special.sav`) with it
  and rebuilds the module with the counts in `build/pgo/GNWE69.profdata` (`-NoPgo`).
- **Native regions** (`config/recomp/GNWE69.regions`): the hottest guest functions of a 2v2
  fight, chiefly the skinning code that blends bone matrices and writes them to the GX FIFO,
  run as native C with guest registers in C locals and small leaf calls inlined. Patch
  `0019-region-gather-pipe-stores` keeps their FIFO stores inside the region (`-NoRegions`).
- **Twin chunks**: `scripts\train-twin.ps1` records the chunk entry points the game uses into
  `build/pgo/GNWE69.hot`; every chunk then gets a fast copy entered only there, with the
  ordinary chunk as the fallback for any other entry (`-NoTwin`).

The profile and the entry list are derived from the game, so they stay in `build/` and are
never committed. Retrain PGO after changing the flags, the region list, the entry list,
dolrecomp or the Clang toolchain: a profile only fits the code it was trained on.

Unthrottled 2v2 fight on the development PC:

| Build | fps |
| --- | --- |
| none of the three | 78.6 |
| native regions + twin chunks | 84.4 |
| PGO only | 91.1 |
| all three | 96.6 |

## Freezes and crashes

The runtime writes a report to `userdata/Diagnostics/` when the game stops producing
frames for 4 seconds (`stall-*.txt`), when it crashes (`crash-*.txt`), or when you press
Ctrl+Shift+D in the game window (`manual-*.txt`). A report holds the guest registers and
call stack, every guest thread and what it waits on, the GPU FIFO state, and the native
stack of every thread as `module+offset`. To turn those into function names, run the game
with the profiling build (`scripts\build-tools.ps1 -Profiling`, then
`scripts\run.ps1 -Profiling`, which has PDBs) and then:

```powershell
python -I tools-src\profiling\resolve_report.py userdata\Diagnostics\stall-<time>.txt
```

## Hitches

For short hitches (a frame that takes 100 ms instead of 16.7), set `RINGOUT_HITCH_TRACE`
to a threshold in milliseconds before starting the game, or pass `-HitchTraceMs` to
`scripts\bench.ps1`. Every video field or presented frame slower than that gets a
`hitch-*.txt` report in `userdata/Diagnostics/`. The report shows what the CPU and GPU
threads were waiting on around the slow frame (the speed limiter, the GPU draining its
FIFO, a DVD read, a Vulkan fence or present, a pipeline compile, ...) and how long each
thread was actually running. When a frame runs long, the report also holds native stacks
sampled from every thread meanwhile (the stuck one first), written as `module+0xoffset`;
turn them into function names with `python -I tools-src\profiling\resolve_report.py <report>`.
With the variable unset the trace is off and costs next to nothing.

## Development

- **Changing the RingOut stack.** `lib/RingOut` is never committed to. Edit it in place,
  build with `scripts\build-tools.ps1 -NoPatch`, then save the edits as the next patch with
  `scripts\save-ringout-patch.ps1 00NN-short-name`. The recompiler is built from
  `lib/RingOut/DolRecomp/src`, and the module build compiles its mirror in
  `dist/RingOut-1.0-dist/module-src/deps/dolrecomp-src`: change both copies.
- **Benchmarks.** `scripts\bench.ps1` runs the game unattended in a copy of `userdata/`
  (`build/bench-userdata`), so your settings and saves are never touched. It boots or loads
  a savestate (`-LoadState`), presses buttons (`-PressAfterLoad`), and reports fps and
  frame-time percentiles; `-Module` runs another module build, `-Unthrottled` lifts the
  speed limit to measure CPU headroom.
- **Module variants.** `scripts\build-module.ps1 -Variant <name>` builds to a side folder
  without replacing the module `run.ps1` uses; `-ExcludeFlag`, `-ExtraFlag` and
  `-ModuleOption` change the recompiler flags and module options for that build.

## Licence

Project code: GPL-3.0-or-later (to match DolRecomp and ModernGekko). See each submodule
for its own licence.
