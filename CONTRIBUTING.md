# Contributing

Issues and pull requests are welcome. A few ground rules keep the project safe to host and easy
to work on.

## Never commit game data

Nothing derived from the disc may be committed or attached anywhere: disc images, extracted
files (`extracted/`), recompiled C, game modules, PGO profiles, twin-chunk lists, savestates,
texture dumps or rebuilt `.viv` archives. They are git-ignored; check `git status` before every
commit. Hand-written metadata about the game (addresses in `config/recomp/`, texture names in
`config/ButtonIcons/targets.ini`, settings) is fine.

## Style

- Code, comments, commit messages and docs in English.
- Match the surrounding code: its naming, comment density and idioms.
- PowerShell for scripts, Python 3 (standard library only) for tools; run Python tools with
  `python -I`.
- Keep paths free of spaces.
- No administrator rights, no injection into other processes, no prebuilt binaries: everything
  is built from source. Anything a change installs or writes outside the repository goes into
  [docs/external-footprint.md](docs/external-footprint.md).

## Changing the runtime

`lib/RingOut` is a submodule pinned to a RingOut release and is never committed to; this port's
changes to it are the numbered patches in `patches/RingOut/`. Edit `lib/RingOut` in place, build
with `scripts\build-tools.ps1 -NoPatch`, then save the edits as the next patch with
`scripts\save-ringout-patch.ps1 00NN-short-name`. See [docs/building.md](docs/building.md#changing-the-runtime).

## Testing a change

- Play it: `scripts\run.ps1`.
- Measure it: `scripts\bench.ps1` runs the game unattended on a copy of your `userdata/`, from
  power-on or from a savestate of your own, and reports fps and frame-time percentiles.
- A change to the recompiler, its flags or the region list needs `scripts\build-module.ps1`;
  retrain PGO afterwards when you use it.

## Reporting a bug

Say what you did, what happened and which version you run. For a freeze or a crash, attach the
report from `userdata/Diagnostics/` (see [docs/playing.md](docs/playing.md#if-the-game-freezes-or-crashes)).
