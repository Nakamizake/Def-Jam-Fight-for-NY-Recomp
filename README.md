# DefJamFFNY-Port

An experimental native PC port of **Def Jam: Fight for NY** (GameCube, disc ID `GNWE69`),
built by **static recompilation**: the game's PowerPC executable is translated ahead of
time into C, compiled for x86-64 and run on a Dolphin-derived runtime that provides
graphics, audio, input and the rest of the console hardware.

> **No game data and no game code are included or distributed.** You supply a disc image
> you own; everything derived from it (extracted files, recompiled code, the compiled game
> module) is generated on your machine and is git-ignored.

Personal / study project. Early stage — it does not boot yet.

## How it works

| Stage | Tool | Output |
| --- | --- | --- |
| Extract the disc | [DolRecomp](https://github.com/ExpansionPak/DolRecomp) `extract` | `extracted/<game>/sys/main.dol` + game files |
| Recompile `main.dol` | DolRecomp (C backend) | generated C sources |
| Build the game module | `moderngekko-port build` | native module |
| Run | [ModernGekko](https://github.com/ExpansionPak/ModernGekko) runtime | the game in a window |

The layout follows [ModernGekko-Template](https://github.com/ExpansionPak/ModernGekko-Template).
[RingOut](https://github.com/jackpoison-prog/RingOut) (a SoulCalibur II port on the same stack)
is the main reference for game-specific work.

## Repository layout

```
lib/DolRecomp/      submodule: static recompiler
lib/ModernGekko/    submodule: runtime (pulls a Dolphin-derived core, ~900 MB)
scripts/            build and run scripts (PowerShell)
docs/               notes, decisions and the external-footprint log
disc/               your disc image (git-ignored)
extracted/          extracted disc contents (git-ignored)
build/              all build output, including the game module (git-ignored)
```

## Requirements (Windows)

- Visual Studio 2022 with the "Desktop development with C++" workload
  (provides MSVC, CMake and Ninja)
- Git
- A Def Jam: Fight for NY (USA) GameCube disc image you own, as `.iso`.
  `.rvz` images can be converted with Dolphin's `DolphinTool convert -f iso`.

## Getting started

```powershell
git clone --recurse-submodules <this repo>
```

Build and run instructions will land in `scripts/` once the pipeline is wired up.

## Freezes and crashes

The runtime writes a report to `userdata/Diagnostics/` when the game stops producing
frames for 4 seconds (`stall-*.txt`), when it crashes (`crash-*.txt`), or when you press
Ctrl+Shift+D in the game window (`manual-*.txt`). A report holds the guest registers and
call stack, every guest thread and what it waits on, the GPU FIFO state, and the native
stack of every thread as `module+offset`. To turn those into function names, run the game
with the profiling build (`scripts\run.ps1 -Profiling`, which has PDBs) and then:

```powershell
python -I tools-src\profiling\resolve_report.py userdata\Diagnostics\stall-<time>.txt
```

## Licence

Project code: GPL-3.0-or-later (to match DolRecomp and ModernGekko). See each submodule
for its own licence.
