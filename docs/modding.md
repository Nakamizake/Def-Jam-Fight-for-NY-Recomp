# Modding

A mod is a folder in `userdata/Load/Mods/<mod name>/` (in an installed game,
`<install folder>\userdata\Load\Mods\<mod name>\`). It can hold replacement textures, replacement
game files and memory patches, in any mix. Nothing in the game's own files is ever changed: switch a mod off and the
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

### PS2 extras

The PlayStation 2 release of the game has a few things the GameCube one lacks. The tools in
`tools-src/ps2/` build each of them as a mod, out of your own copy of the PS2 disc (an `.iso`,
or a folder with its files); neither disc is changed. `ps2_extras.py` builds the ones you pick,
each into a mod folder of its own:

| Switch | Mod | What | Tool |
| --- | --- | --- | --- |
| `--textures` | PS2Textures | most textures at twice the resolution | `ps2_textures.py` |
| `--music` | PS2Music | the soundtrack at the PS2's sample rate, and its 12 extra songs | `ps2_music.py` |

```powershell
python -I tools-src\ps2\ps2_extras.py --gc-files extracted\GNWE69\files `
    --ps2 D:\Games\DefJamPS2.iso --mods userdata\Load\Mods --textures --music
```

An installed game does all of this in one click: *Add PS2 extras* in the game folder (or the
Start menu) asks which extras to build and for the PS2 disc image, builds them and switches them
on. By hand, the tools are in `modding\`, so from the game folder:

```powershell
toolchain\python\bin\python.exe -I modding\ps2_extras.py --gc-files game\files `
    --ps2 D:\Games\DefJamPS2.iso --mods userdata\Load\Mods --textures --music
```

Each tool also runs on its own (`ps2_textures.py` / `ps2_music.py` with `--out <mod folder>`
in place of `--mods` and the switches).

**Textures.** The PS2 disc has the same textures, but most of them at twice the width and
height: every character texture and about half of each venue's. `ps2_textures.py` pairs each
GameCube texture with its PS2 counterpart and writes the larger one under the GameCube texture's
name. It leaves a texture out when the PS2 one is not larger, and also when the two pictures do
not match once the larger one is scaled down (a few textures were redrawn between the releases).
The names match any palette (the game builds some palettes as it runs), so a replacement shows
wherever the same texels are drawn: single-colour textures are left out too (every solid square
of a size shares them; two white venue squares turned whole menus white), as are texels the
GameCube disc draws with more than one palette.
It takes a minute or two and writes about 5,800 textures: around 160 MB, or 250 MB with the
installed game's Python, which lacks zlib and leaves the PNGs uncompressed. Like any texture mod
it is drawn only on your PC, so it never matters to netplay. The textures are loaded the first
time the game uses each one, not all at boot, which keeps the game's memory use about the same.

**Music.** Both releases store the soundtrack as EA-XA ADPCM, the PS2 one at 36,000 Hz against
the GameCube's 22,050. `ps2_music.py` rebuilds the five music archives (`audio/music0-4.viv`)
with the PS2 recording of each of the 20 songs (`main.mus`) and its interactive-music script
(`tune.mpf`), converted to the GameCube's byte order (`ea_audio.py`, `mpf.py`); the audio
frames themselves are the same bytes on both consoles. The songs keep the GameCube's
loading-screen and overlay sound banks (the same sounds, and the game holds them in buffers
sized for the GameCube's own).

It also adds the 12 songs the GameCube release left out (`arewecuttin`, `getintoit`,
`getitnow`, `hitem`, `mamasaid`, `minitrack2`, `nuffrespect`, `nwa`, `poppalarge`, `pump`,
`ricache`, `seizetheday`), whose loading-screen and overlay banks are resampled to the
GameCube's rate (24,000 to 16,000 Hz) and encoded again, as the game keeps those banks in
buffers sized for the GameCube's own. The song database (`djv2.sod`, the same on both discs)
still describes them; the GameCube executable skips them by name, from two copies of one list
(at `80297D54` for the Beatbox's list, at `802990EC` for checks elsewhere in the game), and a
`patches.txt` (see *Memory patches* below) empties both. Emptying only the first left the front
end's music set-up (`8002BC18`, `8002C6BC`) reading a null pointer for each of them. A 13th PS2
song, `holler`, has no Beatbox entry in the database on either console, so it is left out.

The same `patches.txt` fits an Options save from before the mod to the longer list
(`playlist_fix.py`). The game keeps the Beatbox playlist as an array of song ids, sorted (a song
is found by binary search, `8028E62C`), and a flags byte for each: display position and state
(locked, checked, unchecked). The save holds both arrays but not their length, so a 20-song save
comes back with 12 empty entries while the game counts 32, and the Beatbox repeats songs and
loses the new ones. The patch hooks the playlist's `GetState` (`8028DFE4`): when ids are missing
it lays the arrays out again in id order, each song keeping its flags, and unlocks the missing
ones at the next display positions, so they join the end of the player's list, checked. Its
code sits in the two emptied lists.

It takes under a minute and writes about 670 MB. It is a game-file mod, so for netplay both
players need it switched on (or both off).

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
| `audio/*.viv`, `movies/` | music (`music0-4.viv`: per song a stream, a script and two sound banks), sound effects, speech; videos |

Some XML files start with a `<?x...x?>` line; leave it in place.

### Memory patches

A `patches.txt` in a mod (next to `files`, or one folder down like it) changes bytes of the
game's memory after the executable is loaded, for what no disc file holds: a table or a
string inside the executable itself. One patch per line, in hex, `#` starting a comment:

```
# <address> <new bytes> <bytes expected there>
8029E384 0000021800000216000002190000021A0000021400000215 000002180000021800000218000002180000021800000218  # voice banks
```

A patch applies only if the bytes at the address are the expected ones, so it never lands in
the wrong place in another version of the game; addresses must be in main memory
(`80000000`-`817FFFFF`), and the new and expected bytes the same length. The log
(`logs\runtime.log` in an installed game) says how many patches each mod applied, and why a
line was rejected. Like game files, patches apply from the next start and count for netplay.

Patching code needs care. The game runs as native code recompiled ahead of time; a 4 KB block
of it whose bytes no longer match falls back to Dolphin's JIT, but only where the game enters it
through the dispatcher: through a function pointer such as a C++ virtual call, not a direct
call (`bl`) from other recompiled code, which runs the original. Hook a function the game only
reaches through a pointer (as `playlist_fix.py` does), and check the log for the
`SMC: chunk ... hash mismatch` line that shows the block left the native code.

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

## Port fixes

Some of what the GameCube release left out is still on its disc, only switched off. The port
switches it back on with its own fixes: game files (and, when needed, memory patches) laid out
like a mod in the game's `fixes` folder (`extracted/GNWE69/fixes/`; in an installed game,
`game\fixes\`). The runtime applies them on every boot, below every mod: a mod that replaces
the same file wins over the fix. They are not listed in MODS, and they count for netplay like
any game file.

Being made from the game's files, the fixes cannot ship with the port either: the game build
makes them (`build-game.ps1` on every install and update; `scripts/run.ps1` when they are
missing or older than the tools), with `tools-src/modding/port_fixes.py`:

```powershell
python -I tools-src\modding\port_fixes.py --game extracted\GNWE69
```

**What the menus switch off on the GameCube.** The menus are Flash screens whose compiled
ActionScript (the `.apt` script of each screen's bundle in `screens/screens.viv`) is shared by
every console the game shipped on, and branches on `_root.g_console` where they differ. On the
GameCube, a few of those branches leave out things that are still on its disc:

- **Voice page.** The story mode's Sketch Artist ends with one more page after *Positive ID?*:
  what your fighter sounds like, out of six voices (Rough, Street, Clean Cut, Cocky, Smooth,
  Gruff), each with a preview on X. The GameCube skips it and always gives the first voice, and
  its executable gives all six voices the first one's speech in fights; a memory patch
  (`patches.txt` in the fixes) puts back the PlayStation 2's table, one set of speech per voice.
  The voice is chosen when the fighter is created, so it shows in a new story.
- **Venue map.** *Choose Venue* draws the city from `battle/map.swf`, about four times as
  detailed as the `map_ngc.swf` the GameCube loads instead.
- **Trailer.** *Extras* gets a third poster that plays the game's trailer
  (`movies/attract.mad`), from the posters the PlayStation 2 release uses.
- **Spotlight.** Most menus lay a soft light over the screen that darkens its edges; the
  GameCube hides it.

`gc_cuts.py` makes those tests of `_root.g_console == "gc"` compare with a string the console
name never equals (one byte each), rebuilds the archive and writes the voice patch. Every other
console test in the scripts was checked too: the rest fit the layout to the TV, show the
GameCube's own button prompts, copyright line and memory card messages, or only concern the
other consoles.
`gc_cuts.py --out <mod folder>` also builds the fix as an ordinary mod.

## Netplay

Textures are only drawn on your PC, so they never matter to netplay. Game files do: they change
what the game computes, and two players with different files would drift apart. The netplay
check covers the enabled game-file mods, so players can only join each other with the same ones
switched on; otherwise the lobby says the copies differ.

## Sharing a mod

Share the mod folder (or a `.zip` of it). A rebuilt `.viv` also contains the unchanged files of
the original archive, which come from the game disc.
