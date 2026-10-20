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
                    Dolphin settings, the controller layouts and the button icon art
scripts/            build, run, benchmark, training and packaging scripts (PowerShell)
installer/          Windows installer: Inno Setup script, launcher (DefJam.exe) and the
                    script that builds the game on the player's machine
tools-src/          profiling and diagnostics helpers, the .viv modding tool (Python) and the
                    button glyph generator
docs/               notes, the modding guide and the external-footprint log
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

## Installer

`scripts/package.ps1` builds a per-user Windows installer, `build/package/DefJamFFNY-Setup-<version>.exe`
(about 75 MB). It holds the runtime, the recompiler and a trimmed Clang toolchain, and no
game data: right after installing, the installer builds the game on the player's PC from
their own disc image (`installer/build-game.ps1`, about 5 minutes on 8 cores).

- No administrator rights. The player picks the install folder; everything the game writes
  (saves, settings, shader cache, logs) stays in it.
- The disc page is filled in automatically when the `.iso` sits next to the installer or in
  a folder next to it, or from `/ISO="path"` on the command line.
- Start menu: the game, *Def Jam - Rebuild game files* (`DefJam.exe --rebuild`), *Def Jam -
  Optimize for this PC* (`DefJam.exe --optimize`), the game folder and the uninstaller; the
  install folder also gets an *Optimize for this PC* shortcut. Uninstalling removes the built
  game and asks whether to keep the saves.
- The module is first built without a PGO profile or twin chunks (profiles are game-derived,
  so none can ship): about 79 fps unthrottled in a 2v2 fight, well above 60 on the
  development PC.
- *Optimize for this PC* is optional (also offered, unticked, at the end of the install).
  It trains the PGO profile on the player's PC without savestates (`build-game.ps1
  -Optimize`, about 20 minutes): a measuring build, then the game boots with
  `--unattended` (player input ignored, settings menu off, a banner on screen) and
  `scripts/AutoPlay.psm1` drives it through the menus into back-to-back 2v2 fights on a
  throwaway memory card, then the real build. The counts are zeroed when the first fight
  starts (automation command `profile_reset`), so boot, intro movie and the Flash menus do
  not weigh in: counted from power-on, the same training made one 2v2 scene 9% slower.
  About 14 minutes on the development PC, for 78 → 97 fps in a 2v2 fight (table below).
  The profile is kept in `module\`, so *Rebuild game files* stays optimised while the
  recompiler, its settings and Clang are unchanged.

Needs Inno Setup 6, besides the development requirements below. `-TestInstall` builds a
variant with no shortcuts and no uninstall registry entry, for test installs into
`build/`.

```powershell
.\scripts\build-tools.ps1
.\scripts\package.ps1 -Version 0.1.0
```

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
`%LOCALAPPDATA%`. `-Graphics Vulkan` (or `D3D`, `D3D12`, `OGL`) overrides the renderer for
one run.

## Settings menu

Esc pauses the game and opens the settings menu (arrows to move, Left/Right to change,
Esc to close; a gamepad works too). Changes are saved as you make them, and the line under
the list says what the selected setting does.

- **Video:** internal resolution, aspect ratio, V-Sync, anti-aliasing, anisotropic and
  texture filtering, post-processing filters (CRT, scanlines, FXAA, ...), renderer, shader
  compilation mode and fullscreen.
- **Audio:** volume, mute, treble boost, output (Cubeb or WASAPI), latency and buffer
  size, gap filling and pitch preservation. The GameCube mixes at 32 kHz, so the game
  never has anything above 16 kHz; Treble Boost brightens it to taste.
- **System:** emulation speed, CPU overclock, fast disc loading, netplay, reset, quit.
- **Controls, Cheats, Mods, States, Replays, Shots:** rebinding, cheat codes, mods,
  save states, input recordings and screenshots.

A few settings (renderer, audio output, compile shaders at boot) apply at the next launch;
the menu says so.

## Mods

A mod is a folder in `userdata/Load/Mods/<name>/`, switched on and off in **Esc > MODS**. It can
replace textures (Dolphin custom textures, live) and game files (a `files/` folder that mirrors
the disc, applied at the next boot through Dolphin's Riivolution file patching; the extracted
game is never changed). `tools-src/modding/viv.py` extracts and rebuilds the game's `.viv`
archives (EA BIG, RefPack-compressed). See [docs/modding.md](docs/modding.md).

## Netplay

Two to four PCs play one session over Dolphin's netplay (delay-based, both peers run the
same inputs on the same frame). Set **System > Netplay** and pick *Start Netplay*; the game
restarts into a lobby, and the host clicks *Start game* once everyone is in.

- **HOST ONLINE / JOIN ONLINE** — over the internet with nothing to set up: the host's
  lobby shows a *host code* (8 characters, with a Copy button); the others choose JOIN
  ONLINE and press Space on *Host Code* to paste it (or enter it digit by digit on a pad).
  The PCs find each other through
  [Dolphin's traversal server](https://github.com/dolphin-emu/dolphin/tree/master/Source/Core/Common/TraversalServer.cpp)
  (`stun.dolphin-emu.org`), run by the Dolphin team for Dolphin's own netplay: it only
  introduces the peers so they can connect through their routers; the match itself goes
  directly between the PCs. Thanks to the Dolphin project for running it.
- **HOST / JOIN** — a local network or a VPN: the joiner enters the host's address, or
  uses *Scan for Hosts* to find it on the same network.

Windows Firewall asks once whether `moderngekko-run.exe` may use the network. Allowing it
(private networks are enough at home) is what lets others reach a host; JOIN usually works
either way.

Command line: `--netplay-host-online`, `--netplay-join-code <code>`, `--netplay-host`,
`--netplay-join <address>`, with `--netplay-port`, `--nickname`, `--buffer` (input delay in
frames) and `--headless` for scripted sessions (`moderngekko-run.exe --help`).

## Controls

Any SDL gamepad works. Each console release of the game is a layout (Esc > CONTROLS >
Layout): PlayStation, Xbox or GameCube. On Auto (the default) the layout follows the pad:
a DualSense plays the PlayStation 2 release's layout, an Xbox pad the Xbox release's, a
GameCube or Switch pad the GameCube release's. The face buttons sit in the same place on
all three; the shoulders differ:

| Action | PlayStation | Xbox | GameCube | Keyboard |
| --- | --- | --- | --- | --- |
| Move | left stick | left stick | control stick | W A S D |
| Punch | Triangle | Y | Y | I |
| Kick (and Back in menus) | Square | X | B | J |
| Grapple / throw / pick up (and Select) | Cross | A | A | K |
| Run | Circle | B | X | L |
| Block | R1 | right trigger | R (right trigger) | E |
| Strong attack modifier | L1 | left trigger | L (left trigger) | Q |
| Target (multi-fighter) | R2 / L2 | either bumper | Z (right bumper) | Tab |
| Taunt / Blazin' | right stick | right stick | C-stick | arrow keys |
| Pause | Start | Start | Start | Enter |

The layouts are Dolphin pad profiles in `config/Controllers/Layouts/`, copied to
`userdata/Config/Profiles/GCPad/` each time the game is set up (a profile of your own in
that folder shows up in the list too). Every layout also binds the keyboard, by its full
device name, so it plays alongside any pad. Rebinding a button in the menu switches the
layout to Custom, which Auto then leaves alone. The bindings in use are in
`userdata/Config/GCPadNew.ini`.

### Button icons

The game's button icons (the A, B, X, Y, L, R and stick icons in menus, dialogs and the
tutorial) are redrawn for the controls actually in use: each shows what performs that action
on player 1's device, in that device's style (PlayStation symbols, Xbox letters, Switch,
GameCube), and turns into keyboard keys as soon as a bound key is pressed, and back at the
next pad input. A rebind in the menu shows up in the icons right away.

Esc > CONTROLS > Button icons picks the style: Auto (the above), GameCube, PlayStation, Xbox,
Switch or Keyboard to always draw that one whatever is plugged in, or Off for the game's own
icons. A style change shows at once; Off (or back on) takes effect at the next start. The
choice is `ButtonIcons` under `[RecompMenu]` in `userdata/Config/Dolphin.ini`.

The runtime side is RingOut's `RecompButtonIcons`. What it draws comes from
`config/ButtonIcons/`, copied to `userdata/Load/ButtonIcons/` each time the game is set up:

- `targets.ini` lists the game textures that show a button: which control each one shows
  and where the glyph goes (with the lines and tabs some icons carry, redrawn from
  measurements: nothing from the disc is used);
- `glyphs/<style>/<input>.png` is the art, one 128x128 image per physical input, drawn by
  `tools-src/button-icons/make-button-glyphs.ps1` (`-Preview` writes a sheet of all of them
  to `build/`).

The drawn icons go to `userdata/Cache/ButtonIcons/`.

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

The installer's module has the native regions only; *Optimize for this PC* adds a PGO
profile trained without savestates. Unthrottled, 30 s of each scene, none of them used for
that training:

| Scene | installer build | after *Optimize* |
| --- | --- | --- |
| 2v2 fight (`2v2-fight`) | 78.0 | 97.2 |
| 2v2 fight (`2v2-special`) | 78.5 | 97.5 |
| 1v1 fight (`fight-1v1`) | 107.9 | 128.6 |

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
