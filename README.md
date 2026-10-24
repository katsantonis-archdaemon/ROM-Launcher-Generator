# ROM Launcher Generator

A Windows GUI tool that scans a folder of ROMs organized by console and generates a `.bat` launcher for every game — so you can add your whole emulation library to Steam, Playnite, or any other launcher as individual entries, without creating each shortcut by hand.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Windows-0078D6?logo=windows&logoColor=white)

## Why

Emulator frontends and custom launchers (Steam's "Add a Non-Steam Game," Hydra Launcher, etc.) generally want one `.bat`/`.exe` per game. Doing that by hand for a library of any real size means writing the same three-line batch file over and over, swapping in a path each time. This tool automates that: point it at your `Roms` folder and your chosen emulators, and it builds the whole set in one pass — then helps keep it tidy as you add more ROMs later.

## Features

- **Per-console scanning** — detects consoles by subfolder name (`nes`, `snes`, `ps1`, `ps2`, `gamecube`, `switch`, etc. — 19 supported out of the box, matched case-insensitively), warns on but still processes unrecognized folder names
- **One `.bat` launcher per game**, mirrored into a separate output folder by console, so your ROM folders are never modified directly (aside from the PS1 organizing step below)
- **Remembers emulator paths** between runs in a small local config file — set each console's emulator once
- **Skips existing launchers** — re-running after adding new ROMs only creates what's missing, never overwrites
- **Cleans up launcher names** — strips region/language/version tags like `(USA)`, `(En,Fr,Es)`, `[!]`, `(Rev 1)` from filenames
- **Multi-disc grouping** — `.cue`/`.bin`, `.gdi`, and similarly paired files collapse into a single launcher per game instead of one per file; `(Disc 1)` / `(Disc 2)` naming is recognized too
- **PS1 `.m3u` playlist organizing** — for the `ps1` folder specifically, any game with multiple disc files gets its files moved into a `multi/` subfolder and a matching `.m3u` playlist written next to it, so emulators that support disc-swapping (e.g. Duckstation, PCSX2) can use it directly. Already-organized games are left alone on re-scan.
- **Optional SteamGridDB artwork fetching** — pulls grid, hero, logo, and icon art per game automatically, with a review screen to manually swap any auto-picked image for one of several alternatives
- **Preview / verification pass** — checks that every launcher generated this session actually points at files that still exist, and that every `.m3u` this session created is valid, flagging anything broken with a reason
- Dark, themed UI with a live debug console alongside it for troubleshooting

## Setup

Download the latest release, extract it and run the `.bat` file, not the `.ps1` directly — it unblocks the script (so Windows doesn't flag it as an untrusted download) and launches it with the right execution policy for that one run, without changing any system-wide PowerShell settings. A console window stays open alongside the GUI showing live debug output, which is useful if something doesn't behave as expected.

## Usage

1. **Roms folder** — point this at the folder containing your console subfolders (e.g. `E:\Roms`, with `E:\Roms\ps1`, `E:\Roms\snes`, etc. inside it).
2. **Output folder** — where the generated `.bat` launchers should go. This is kept separate from your ROMs; the generated folder structure mirrors your console subfolders.
3. **Scan for consoles** — detects every console subfolder containing ROMs and lists them, with an emulator path field for each (auto-filled from previous runs where remembered).
4. Set any missing emulator paths, using the Browse button to pick each `.exe`.
5. *(Optional)* Check **Fetch artwork** and paste a SteamGridDB API key to pull cover art automatically.
6. **Generate launchers.**
7. *(Optional)* Use **Preview** to verify everything generated this run is actually valid, and **Review artwork** to swap any auto-picked image you don't like.

## Expected folder layout

```
Roms/
├── ps1/
│   ├── Final Fantasy VII (USA) (Disc 1).chd
│   ├── Final Fantasy VII (USA) (Disc 2).chd
│   └── Crash Bandicoot (USA).chd
├── snes/
│   └── Super Mario World (USA).sfc
└── gamecube/
    └── ...

Rom Launchers/            <- your chosen output folder
├── ps1/
│   ├── Final Fantasy VII.bat
│   └── Crash Bandicoot.bat
├── snes/
│   └── Super Mario World.bat
└── gamecube/
    └── ...
```

After a PS1 folder with multi-disc games is scanned, it's reorganized in place like this:

```
Roms/ps1/
├── Final Fantasy VII.m3u      <- generated playlist
├── Crash Bandicoot (USA).chd  <- single-disc games are left where they are
└── multi/
    ├── Final Fantasy VII (USA) (Disc 1).chd
    └── Final Fantasy VII (USA) (Disc 2).chd
```

## Supported consoles

`nes` `snes` `mastersystem` `genesis` `gb` `gbc` `gba` `n64` `ps1` `dreamcast` `ps2` `gamecube` `xbox` `wii` `ds` `psp` `3ds` `psvita` `switch`

Folder names are matched case-insensitively. Any other folder name is still scanned and processed — you'll just get a warning that it's not in this list, in case it's a typo.

## Notes & limitations

- Windows/PowerShell + WPF only; there's no cross-platform version YET.
- The PS1 `.m3u` organizer **moves files** (not copies) into a `multi/` subfolder. It skips any game that already has a matching `.m3u`, so re-scanning an already-organized library is safe, but it's worth trying on a small folder first if you're cautious.
- SteamGridDB artwork matching is by cleaned-up game title; obscure titles or ROM hacks may not find a match.
- This was built and reviewed carefully, but only tested by hand on a real Windows machine as it was built — not covered by automated tests. If you hit a bug, please open an issue with what you were doing and, if possible, the debug console's output.
