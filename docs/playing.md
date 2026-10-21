# Player guide

## Installing

The installer, `DefJamFFNY-Setup-<version>.exe`, is per-user and needs no administrator rights.

- It needs a **plain `.iso`** of the GameCube USA release (`GNWE69`). Convert `.rvz`, `.gcz`,
  `.wia`, `.ciso` or `.nkit.iso` images with Dolphin first: right-click the game >
  *Convert File...* > Format **ISO**, no compression.
- Pick any install folder. Everything the game writes (saves, settings, shader cache, logs)
  stays inside it.
- The disc page is filled in automatically when the `.iso` sits next to the installer or in a
  folder next to it, or from `/ISO="path"` on the command line.
- Right after installing, a console window builds the game from your disc (about 5–8 minutes,
  using every CPU core) and closes by itself.
- The first start prepares the graphics shaders for about a minute; later starts are quick.
- Shortcuts: the game folder always has *Rebuild game files*, *Optimize for this PC* and
  *Build PS2 HD textures*. Two optional tasks add Start menu entries (the game, those three
  tools as *Def Jam - ...*, the game folder and the uninstaller) and a desktop shortcut;
  untick them when updating and the old ones are removed.

### Optimize for this PC

Optional (also offered, unticked, at the end of the install). It rebuilds the game with a
profile-guided optimisation trained on your PC: a measuring build first, then the game opens and
plays back-to-back 2v2 fights on its own (your input is ignored, a banner says what is going on,
and a throwaway memory card is used, so your saves are never touched), then the final build.
It takes about 15–20 minutes and makes the game roughly 25% faster:

| Scene, unthrottled | installer build | after *Optimize* |
| --- | --- | --- |
| 2v2 fight | 78 fps | 97 fps |
| 2v2 fight with a Blazin' move | 78.5 fps | 97.5 fps |
| 1v1 fight | 108 fps | 129 fps |

### Updating

Run the installer of the new version and pick the same folder. The disc is not needed again
(leave the disc field empty); saves, settings and the optimisation are kept. When the game's
code did not change, the build step finishes in seconds.

### PS2 HD textures

Optional (also offered, unticked, at the end of the install). The PlayStation 2 release has
most of the game's textures at twice the resolution. *Build PS2 HD textures* asks for your own
disc image of Def Jam: Fight for NY for PlayStation 2 (`.iso`), copies those textures into a mod
named **PS2Textures** in about a minute and switches it on; Esc > MODS switches it off again.
It needs about 250 MB, only reads the disc image, and writes its log to
`logs\ps2-textures.log`. How it works: *PS2 texture pack* in the [modding guide](modding.md).

### Uninstalling

Settings > Apps, or the uninstaller in the Start menu (or `unins000.exe` in the game folder). It removes the game and the built files,
and asks whether to keep your saves and settings.

## Settings menu

Esc pauses the game and opens the settings menu (arrows to move, Left/Right to change, Esc to
close; a gamepad works too). Changes are saved as you make them, and the line under the list
explains the selected setting.

- **Video:** internal resolution, aspect ratio, V-Sync, anti-aliasing, anisotropic and texture
  filtering, post-processing filters (CRT, scanlines, FXAA, ...), renderer, shader compilation
  mode and fullscreen.
- **Audio:** volume, mute, treble boost, output (Cubeb or WASAPI), latency and buffer size, gap
  filling and pitch preservation. The GameCube mixes at 32 kHz, so the game never has anything
  above 16 kHz; *Treble Boost* brightens it to taste.
- **System:** emulation speed, CPU overclock, fast disc loading, netplay, reset, quit.
- **Controls, Cheats, Mods, States, Replays, Shots:** rebinding, cheat codes, mods, save
  states, input recordings and screenshots.

A few settings (renderer, audio output, compile shaders at boot) apply at the next launch; the
menu says so.

## Controls

Any SDL gamepad works, and the keyboard plays alongside it. Each console release of the game is
a layout (Esc > CONTROLS > Layout): PlayStation, Xbox or GameCube. On *Auto* (the default) the
layout follows the pad: a DualSense plays like the PlayStation 2 release, an Xbox pad like the
Xbox release, a GameCube or Switch pad like the GameCube release. The face buttons sit in the
same place on all three; the shoulders differ:

| Action | PlayStation | Xbox | GameCube | Keyboard |
| --- | --- | --- | --- | --- |
| Move | left stick | left stick | control stick | W A S D |
| Punch | Triangle | Y | Y | I |
| Kick (and Back in menus) | Square | X | B | J |
| Grapple / throw / pick up (and Select) | Cross | A | A | K |
| Run | Circle | B | X | L |
| Block | R1 | right trigger | R | E |
| Strong attack modifier | L1 | left trigger | L | Q |
| Target (multi-fighter) | R2 / L2 | either bumper | Z | Tab |
| Taunt / Blazin' | right stick | right stick | C-stick | arrow keys |
| Pause | Start | Start | Start | Enter |

Rebinding a button in the menu switches the layout to *Custom*, which *Auto* then leaves alone.
The layouts are Dolphin pad profiles (`config/Controllers/Layouts/` in the repository); a profile
of your own in `userdata/Config/Profiles/GCPad/` shows up in the list too.

### Button icons

The game's button prompts (in menus, dialogs and the tutorials) are redrawn for the controls
actually in use: each one shows what performs that action on player 1's device, in that
device's style (PlayStation symbols, Xbox letters, Switch, GameCube), turns into keyboard keys as
soon as a bound key is pressed, and back at the next pad input. A rebind shows up in the icons
right away.

Esc > CONTROLS > Button icons picks the style: *Auto* (the above), GameCube, PlayStation, Xbox,
Switch or Keyboard to always draw that one, or *Off* for the game's own icons. A style change
shows at once; *Off* (or back on) takes effect at the next start.

The icons are drawn by the port from `config/ButtonIcons/`: `targets.ini` lists the game
textures that show a button and where the glyph goes (redrawn from measurements; nothing from
the disc is used), and `glyphs/<style>/<input>.png` is the art, generated by
`tools-src/button-icons/make-button-glyphs.ps1`.

## Netplay

Two to four PCs play one session over Dolphin's netplay (delay-based: every peer runs the same
inputs on the same frame). Set **System > Netplay** and pick *Start Netplay*; the game restarts
into a lobby, and the host clicks *Start game* once everyone is in.

- **HOST ONLINE / JOIN ONLINE:** over the internet with nothing to set up. The host's lobby
  shows an 8-character *host code* with a Copy button; the others choose JOIN ONLINE and press
  Space on *Host Code* to paste it (or enter it digit by digit on a pad). The PCs find each
  other through [Dolphin's traversal server](https://github.com/dolphin-emu/dolphin/tree/master/Source/Core/Common/TraversalServer.cpp)
  (`stun.dolphin-emu.org`), run by the Dolphin team for Dolphin's own netplay: it only
  introduces the peers; the match itself goes directly between the PCs. Thanks to the Dolphin
  project for running it.
- **HOST / JOIN:** a local network or a VPN. The joiner enters the host's address, or uses
  *Scan for Hosts* to find it on the same network.

Every player needs the same disc (USA), the same version of the port and the same game-file
mods. Windows Firewall asks once whether `moderngekko-run.exe` may use the network: allowing it
(private networks are enough at home) is what lets others reach a host.

Command line: `--netplay-host-online`, `--netplay-join-code <code>`, `--netplay-host`,
`--netplay-join <address>`, with `--netplay-port`, `--nickname`, `--buffer` (input delay in
frames) and `--headless` for scripted sessions (`moderngekko-run.exe --help`).

## If the game freezes or crashes

The game writes a report to `userdata/Diagnostics/` when it stops producing frames for 4
seconds (`stall-*.txt`), when it crashes (`crash-*.txt`), or when you press Ctrl+Shift+D in the
game window (`manual-*.txt`). Attach the report when you open an issue.
