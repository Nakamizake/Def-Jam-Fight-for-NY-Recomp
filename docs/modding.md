# Modding

A mod is a folder in `userdata/Load/Mods/<mod name>/` (in an installed game,
`<install folder>\userdata\Load\Mods\<mod name>\`). It can hold replacement textures, replacement
game files, or both. Nothing in the game's own files is ever changed: switch a mod off and the
game is exactly as it came off the disc.

Mods are switched on and off in the game: **Esc > MODS**. Each mod is listed by its folder name.
A mod packed as `.zip`, `.rar` or `.7z` can be dropped into `Load/Mods/` as it is; it is unpacked
the next time the MODS tab opens (with `tar`, which Windows 10 and 11 include; 7-Zip or unrar on the PATH also work).

```
userdata/Load/Mods/
  BetterCrowd/
    files/                        game files: the same paths as on the disc
      venue.xml
      assets/icrowd.viv
    textures/                     any folder name; .png/.dds anywhere in the mod
      tex1_128x128_0123456789abcdef_5.png
```

## Textures

Replacement textures are Dolphin custom textures: `.png` or `.dds` files named after the texture
they replace (`tex1_<width>x<height>_<hash>_<format>.png`), anywhere inside the mod folder. They
switch on and off at once, with no restart.

To find a texture's name, let the game dump the textures it uses. Dumping slows the game and is
never left on between sessions, so it is switched on for one session from the environment: in
PowerShell, in the game folder, run

```powershell
$env:RINGOUT_DUMP_TEXTURES = '1'; .\DefJam.exe
```

(from a clone, `scripts\run.ps1` instead of `.\DefJam.exe`), then play to where the texture
appears. The dumps land in `userdata/Dump/Textures/GNWE69/`; copy the one you want into your mod
and edit it (a larger image of the same aspect ratio is fine).

The button icons are drawn by the port itself (see *Button icons* in the player guide, `docs/playing.md` in the repository), above the HD
texture pack and below the mods: a mod that replaces one of them wins.

A loose HD texture pack also works in `userdata/Load/Textures/GNWE69/` (the *HD texture pack*
row in MODS). Where a mod and the pack replace the same texture, the mod wins; between two mods,
the one whose name sorts first wins.

### PS2 texture pack

The PlayStation 2 release of the game has the same textures as the GameCube one, but most of
them at twice the width and height: every character texture and about half of each venue's.
`tools-src/textures/ps2_textures.py` builds a texture mod from them, out of your own copy of the
PS2 disc (an `.iso`, or a folder with its files). It pairs each GameCube texture with its PS2
counterpart and writes the larger one under the GameCube texture's name. It leaves a texture out
when the PS2 one is not larger, and also when the two pictures do not match once the larger one
is scaled down (a few textures were redrawn between the releases). Neither disc is changed.

```powershell
python -I tools-src\textures\ps2_textures.py --gc-files extracted\GNWE69\files `
    --ps2 D:\Games\DefJamPS2.iso --out userdata\Load\Mods\PS2Textures
```

An installed game does all of this in one click: *Build PS2 HD textures* in the game folder
(or the Start menu) asks for the PS2 disc image, builds the mod and switches it on. By hand, the
tool is in `modding\`, so from the game folder:

```powershell
toolchain\python\bin\python.exe -I modding\ps2_textures.py --gc-files game\files `
    --ps2 D:\Games\DefJamPS2.iso --out userdata\Load\Mods\PS2Textures
```

It takes a minute or two and writes about 5,800 textures: around 160 MB, or 250 MB with the
installed game's Python, which lacks zlib and leaves the PNGs uncompressed. Then switch on
**PS2Textures** in Esc > MODS. Like any texture mod it is drawn only on your PC, so it never
matters to netplay. The textures are loaded the first time the game uses each one, not all at
boot, which keeps the game's memory use about the same with the pack on.

## Game files

A `files` folder in a mod mirrors the disc's file tree, the one extracted to
`extracted/GNWE69/files/` (in an installed game, `game\files\`). Each file in it replaces the
disc file at the same path, and a file the disc does not have is added. Sizes are free: the disc
is rebuilt around them at boot.

- Game files are read when the game boots, so switching such a mod in MODS shows
  `ON - RESTART` / `OFF - RESTART` until the game is restarted.
- Between two mods that replace the same file, the one whose name sorts first wins.
- `files` may also sit one folder down (`<mod>/<any folder>/files/`), as archives often wrap
  everything in a folder.

What is where on the disc:

| Path | What |
| --- | --- |
| `fighter.xml`, `venue.xml`, `gamedata.xml`, `gconfig.xml` | fighters; venues (with their crowd and ambient sounds); game data; global settings |
| `assets/entity.xml` | venue objects, including where the instanced crowd stands |
| `assets/*.viv` | venues (`v2bg`), characters (`v2cp_*`), crowd (`icrowd`, `cincrowd`), props, shops |
| `fonts/*.viv`, `screens/screens.viv` | fonts; the menus and HUD (EA's Flash-based UI) |
| `audio/*.viv`, `movies/` | music, sound effects, speech; videos |

Some XML files start with a `<?x...x?>` line; leave it in place.

### .viv archives

Most game data sits in `.viv` archives: EA BIG archives whose entries are mostly
RefPack-compressed. `tools-src/modding/viv.py` lists, extracts and rebuilds them (Python 3, no
extra packages; an installed game has the tool in `modding\` and a Python in
`toolchain\python\bin\python.exe`):

```powershell
python -I tools-src\modding\viv.py list    extracted\GNWE69\files\assets\icrowd.viv
python -I tools-src\modding\viv.py extract extracted\GNWE69\files\assets\icrowd.viv work\icrowd
# edit, add or replace files under work\icrowd
python -I tools-src\modding\viv.py pack    work\icrowd userdata\Load\Mods\MyMod\files\assets\icrowd.viv
```

`extract` writes every entry decompressed, plus `_viv.json` (the archive's layout and a hash of
each file). `pack` keeps the original bytes of every unchanged file, compresses changed ones
again the way they were stored, and appends files that were not in the archive. Always write the
result into a mod, never over the game's own archive.

## Netplay

Textures are only drawn on your PC, so they never matter to netplay. Game files do: they change
what the game computes, and two players with different files would drift apart. The netplay
check covers the enabled game-file mods, so players can only join each other with the same ones
switched on; otherwise the lobby says the copies differ.

## Sharing a mod

Share the mod folder (or a `.zip` of it). A rebuilt `.viv` also contains the unchanged files of
the original archive, which come from the game disc.
