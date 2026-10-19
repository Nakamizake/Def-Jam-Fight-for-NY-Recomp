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

## Hitches

For short hitches (a frame that takes 100 ms instead of 16.7), set `RINGOUT_HITCH_TRACE`
to a threshold in milliseconds before starting the game, or pass `-HitchTraceMs` to
`scripts\bench.ps1`. Every video field or presented frame slower than that gets a
`hitch-*.txt` report in `userdata/Diagnostics/`. The report shows what the CPU and GPU
threads were waiting on around the slow frame (the speed limiter, the GPU draining its
FIFO, a DVD read, a Vulkan fence or present, a pipeline compile, ...) and how long each
thread was actually running. When a frame runs long, the report also holds native stacks
sampled from every thread meanwhile (the stuck one first), written as `module+0xoffset`;
turn them into function names
with `python -I tools-src\profiling\resolve_report.py <report>`. With the variable unset the
trace is off and costs next to nothing.

## Profile-guided build

`scripts\train-pgo.ps1` builds an instrumented game module, plays two fight savestates with
it (`build/states/fight-1v1.sav` and `2v2-special.sav` by default), merges the counts into
`build/pgo/GNWE69.profdata` and rebuilds the module with them. `scripts\build-module.ps1`
then uses that profile on every build (`-NoPgo` turns it off). On the development PC this made
an unthrottled 2v2 fight run about 13% faster, and removed the 30+ ms frames seen in a 2v2
special move at full speed. Retrain after changing `config/recomp/GNWE69.flags`, dolrecomp
or the Clang toolchain: the profile only fits the code it was trained on. The profile is
derived from the game, so it stays in `build/` and is never committed.

## Native regions and twin chunks

Two more of RingOut's recompiler passes are on for this game:

- **Native regions** (`config/recomp/GNWE69.regions`): the hottest guest functions of a 2v2 fight,
  chiefly the skinning code that blends bone matrices and writes them to the GX FIFO, run as
  native C with guest registers in C locals and small leaf calls inlined. Patch
  `0019-region-gather-pipe-stores` keeps their FIFO stores inside the region.
- **Twin chunks** (`build/pgo/GNWE69.hot`, made by `scripts\train-twin.ps1`): every chunk gets a
  fast copy entered only at the entry points a training run used, with the ordinary chunk as the
  fallback for any other entry.

`scripts\build-module.ps1` uses both when their lists exist (`-NoRegions`, `-NoTwin`). Both change
the generated code, so run `scripts\train-pgo.ps1` after changing either list. On the development
PC, unthrottled 2v2: 78.6 fps without either or PGO, 84.4 with both, and 96.6 with both plus a
retrained profile (91.1 with PGO alone).

## Licence

Project code: GPL-3.0-or-later (to match DolRecomp and ModernGekko). See each submodule
for its own licence.
