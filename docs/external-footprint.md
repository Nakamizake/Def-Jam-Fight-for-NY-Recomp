# External footprint

Everything this project has added **outside** the repository folder, and how to remove it.
Keep this file up to date whenever something new is installed or written elsewhere.

## Outside the repository

None so far.

Tools already present on the machine and reused (not installed by this project):

- Visual Studio 2022 Community (MSVC, CMake, and its bundled Ninja at
  `Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe`)
- Git, Python 3.14, 7-Zip
- CMake 4.4 (`C:\Program Files\CMake`); `scripts/package.ps1` copies `cmake.exe` and its
  `share\` modules into the installer
- Inno Setup 6 (`%LOCALAPPDATA%\Programs\Inno Setup 6`), used by `scripts/package.ps1`

## What the installer writes (when someone installs the game)

`build/package/DefJamFFNY-Setup-<version>.exe` is per-user and needs no administrator rights.
A real install writes the following, and its uninstaller removes it:

| Where | What |
| --- | --- |
| the chosen folder (default `%LOCALAPPDATA%\Programs\DefJamFFNY`) | the game, the built module, logs, `userdata\` (saves and settings; the uninstaller asks before deleting it) |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\{EE1476CB-E33D-4B0B-B14F-8CE9E9E79008}_is1` | the entry in Settings > Apps |
| Start menu folder *Def Jam Fight for NY* | shortcuts: game, rebuild, game folder, uninstall |
| desktop (optional task) | game shortcut |

Test builds (`package.ps1 -TestInstall`) create neither the registry entry nor shortcuts;
they have only been installed into `build/install-test/` (removed with `build/`).

## Inside the repository but git-ignored

These are local only and are removed by deleting the folder:

| Path | What | Source |
| --- | --- | --- |
| `disc/` | the user's own disc image (`.rvz` and converted `.iso`) | user |
| `extracted/` | files extracted from the disc | generated |
| `build/`, `build-*/` | build output, recompiled code, game module | generated |
| `tools/dolphin/` | Dolphin 2609a x64, portable (`portable.txt`), used only for `DolphinTool convert` | https://dl.dolphin-emu.org/releases/2609a/dolphin-2609a-x64.7z (SHA-256 `bbfd13bf9e6d2a4164a15c392b1f32a9b18150e5136746b388704608fbb60f76`) |
| `tools/llvm-mingw/` | llvm-mingw 20260616 (Clang 22.1.8, UCRT x86_64), portable; builds the game module only (RingOut's generated code needs Clang) | https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/llvm-mingw-20260616-ucrt-x86_64.zip (SHA-256 `b9b68a4d276e16fa25802aaba458e4638f64b3884c290aaccdc2d87083b6ca35`) |
| `tools/downloads/` | the Dolphin and llvm-mingw archives above | same |
| `references/RingOut/` | old read-only clone of RingOut (broken index); superseded by the `lib/RingOut` submodule and safe to delete | https://github.com/jackpoison-prog/RingOut |
| `lib/*/build/` | submodule build output | generated |
