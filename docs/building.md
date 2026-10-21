# Building from source

## Requirements

- Windows 10/11, x86-64.
- Visual Studio 2022 with the *Desktop development with C++* workload (MSVC, CMake and Ninja;
  builds the runtime and the recompiler).
- Git and Python 3.
- [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20260616 (UCRT x86_64), unpacked to
  `tools/llvm-mingw/`. The recompiled code needs Clang; MSVC cannot build it. The exact archive
  and its SHA-256 are in [external-footprint.md](external-footprint.md).
- A Def Jam: Fight for NY (USA, `GNWE69`) GameCube disc image of your own, as `.iso`. `.rvz`
  images can be converted with Dolphin's `DolphinTool convert -f iso`.
- About 10 GB of free disk space and 16 GB of RAM (each large generated file takes over 1 GB
  to compile; lower `-Jobs` if memory runs short).
- For the installer only: [Inno Setup 6](https://jrsoftware.org/isinfo.php).

Keep the repository in a path without spaces: DolRecomp's Windows build breaks on them.

Everything derived from the disc (`disc/`, `extracted/`, generated C, game modules, PGO
profiles, savestates) is git-ignored and must never be committed or shared.

## Build and run

```powershell
git clone https://github.com/Nakamizake/Def-Jam-Fight-for-NY-Recomp.git DefJamFFNY
cd DefJamFFNY
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

`run.ps1` keeps all runtime data in `userdata/` inside the repository, not in
`%LOCALAPPDATA%`. `-Graphics Vulkan` (or `D3D`, `D3D12`, `OGL`) overrides the renderer for one
run.

## Installer

```powershell
.\scripts\build-tools.ps1
.\scripts\package.ps1 -Version 0.1.0
```

`scripts/package.ps1` builds a per-user Windows installer,
`build/package/DefJamFFNY-Setup-<version>.exe` (about 75 MB). It holds the runtime, the
recompiler and a trimmed Clang toolchain, and no game data: right after installing, it builds
the game on the player's PC from their own disc image (`installer/build-game.ps1`).

- The module is first built without a PGO profile (profiles are derived from the game, so none
  can ship), with the native regions only.
- *Optimize for this PC* (`DefJam.exe --optimize`, `build-game.ps1 -Optimize`) trains the PGO
  profile on the player's PC without savestates: a measuring build, then the game boots with
  `--unattended` (player input ignored, settings menu off, a banner on screen) and
  `scripts/AutoPlay.psm1` drives it through the menus into back-to-back 2v2 fights on a
  throwaway memory card, then the real build. The counts are zeroed when the first fight starts
  (automation command `profile_reset`), so boot, the intro movie and the menus do not weigh in.
  The profile is kept in `module\`, so *Rebuild game files* stays optimised while the
  recompiler, its settings and Clang are unchanged.
- Installing over an existing install is a quick update: when the game's code and everything
  the module is built from are unchanged (`module\GNWE69.module.stamp`), the build step keeps
  the installed module.
- `-TestInstall` builds a variant with no shortcuts and no uninstall registry entry, for test
  installs into `build/`.

## Performance

`scripts\build-module.ps1` turns on three of RingOut's speed-ups whenever their inputs exist:

- **Profile-guided optimisation:** `scripts\train-pgo.ps1` builds an instrumented module, plays
  fight savestates of your own (`build/states/fight-1v1.sav` and `2v2-special.sav`; names and
  lengths are parameters) with it, and rebuilds the module with the counts in
  `build/pgo/GNWE69.profdata` (`-NoPgo` to skip).
- **Native regions** (`config/recomp/GNWE69.regions`): the hottest guest functions of a 2v2
  fight, chiefly the skinning code that blends bone matrices and writes them to the GX FIFO,
  run as native C with guest registers in C locals and small leaf calls inlined. Patch
  `0019-region-gather-pipe-stores` keeps their FIFO stores inside the region (`-NoRegions`).
- **Twin chunks:** `scripts\train-twin.ps1` records the chunk entry points the game uses into
  `build/pgo/GNWE69.hot`; every chunk then gets a fast copy entered only there, with the
  ordinary chunk as the fallback for any other entry (`-NoTwin`).

The profile and the entry list are derived from the game, so they stay in `build/` and are
never committed. Retrain PGO after changing the flags, the region list, the entry list,
DolRecomp or the Clang toolchain: a profile only fits the code it was trained on.

Unthrottled 2v2 fight on the development PC (Ryzen 5 5600G, RX 6750 XT):

| Build | fps |
| --- | --- |
| none of the three | 78.6 |
| native regions + twin chunks | 84.4 |
| PGO only | 91.1 |
| all three | 96.6 |

## Changing the runtime

`lib/RingOut` is a submodule pinned to a RingOut release; this port's changes to it live in
`patches/RingOut/` and are applied by `scripts\build-tools.ps1`.

1. Edit `lib/RingOut` in place and build with `scripts\build-tools.ps1 -NoPatch` (the edits are
   already there).
2. Save the edits as the next patch with `scripts\save-ringout-patch.ps1 00NN-short-name`.

The recompiler is built from `lib/RingOut/DolRecomp/src`, and the module build compiles its
mirror in `dist/RingOut-1.0-dist/module-src/deps/dolrecomp-src`: change both copies.

## Benchmarks and module variants

- `scripts\bench.ps1` runs the game unattended in a copy of `userdata/`
  (`build/bench-userdata`), so your settings and saves are never touched. It boots or loads a
  savestate (`-LoadState`), presses buttons (`-PressAfterLoad`), and reports fps and frame-time
  percentiles; `-Module` runs another module build, `-Unthrottled` lifts the speed limit to
  measure CPU headroom.
- `scripts\build-module.ps1 -Variant <name>` builds to a side folder without replacing the
  module `run.ps1` uses; `-ExcludeFlag`, `-ExtraFlag` and `-ModuleOption` change the recompiler
  flags and module options for that build.
- `--automation-dir <dir>` (used by `bench.ps1` and `AutoPlay.psm1`) makes the runtime execute
  command files dropped into `<dir>/commands/`: pad input, save/load state, screenshots, memory
  reads and writes, a banner, profile reset and stop.

## Diagnostics

### Freezes and crashes

The runtime writes a report to `userdata/Diagnostics/` when the game stops producing frames for
4 seconds (`stall-*.txt`), when it crashes (`crash-*.txt`), or on Ctrl+Shift+D (`manual-*.txt`).
A report holds the guest registers and call stack, every guest thread and what it waits on, the
GPU FIFO state, and the native stack of every thread as `module+offset`. To turn those into
function names, run the profiling build (`scripts\build-tools.ps1 -Profiling`, then
`scripts\run.ps1 -Profiling`, which has PDBs) and then:

```powershell
python -I tools-src\profiling\resolve_report.py userdata\Diagnostics\stall-<time>.txt
```

### Hitches

For short hitches (a frame that takes 100 ms instead of 16.7), set `RINGOUT_HITCH_TRACE` to a
threshold in milliseconds before starting the game, or pass `-HitchTraceMs` to
`scripts\bench.ps1`. Every video field or presented frame slower than that gets a `hitch-*.txt`
report in `userdata/Diagnostics/`, showing what the CPU and GPU threads were waiting on around
the slow frame (the speed limiter, the GPU draining its FIFO, a DVD read, a Vulkan fence or
present, a pipeline compile, ...) and how long each thread actually ran. When a frame runs long,
the report also holds native stacks sampled from every thread meanwhile, resolved the same way
with `resolve_report.py`. With the variable unset the trace is off and costs next to nothing.

### Other helpers

- `tools-src/profiling/sample_profiler.py`: a minimal sampling profiler for the running game
  (no admin rights, nothing injected); `trace_hitches.py` finds hitches in its `--trace` output.
- `tools-src/analysis/diff_dol_memory.py`: compares a guest memory dump against `main.dol`, to
  find code the game rewrites at run time.
