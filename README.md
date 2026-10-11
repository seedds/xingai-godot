# 新改曹操傳 6.6 — Godot port

A reimplementation of **新改曹操傳 6.6 修正版** in **Godot 4.7**, running natively on **macOS**, **iPhone** and
**Android**. The original is a Windows fan mod of Koei's 1998 *三国志曹操传* built on the community "6.6 engine"
(`Ekd5.exe`, the CCZ executable largely rewritten in place).

The engine was reverse-engineered (Ghidra and disassembly): its file formats, the EEX scenario-script language, the
memory layout the scripts poke, the battle formulas, the effect (特效) system, the AI, duels and the 练武场 are
documented in [docs/](docs/README.md), and the port is written against those specifications. The game data — 249
story and battle scripts, maps, unit sprites, portraits, scene pictures, music, sound effects and videos — comes
from the original game, converted but not altered.

The port was forked from the Godot port of another CCZ mod (wg2025, 兴唐传·瓦岗山异闻录) and is a work in progress.

## What you need

* **The original game**: the 新改曹操傳 6.6 修正版 directory (`Ekd5.exe`, `Data.e5`, `Imsg.e5`, `E5/`, `MAP/`,
  `RS/`, `SoundTrk/`, `WAV/`, the `.avi` videos …). It is **not included** and must never be committed.
* [Godot 4.7](https://godotengine.org) (`brew install --cask godot`) on a Mac (macOS 10.13+ on Intel, 11+ on Apple
  Silicon).
* For converting the data once: Python 3, `ffmpeg` and Homebrew's `ffmpeg-full` (`brew install ffmpeg ffmpeg-full`),
  and the Noto Serif SC font (for the phone builds).

## Getting started

The converted game data is in the repository (`game/assets/`), so a clone runs as it is:

```sh
./run_game.sh
```

Ready-made builds for macOS, Windows, iPhone and Android are on the
[Releases](https://github.com/seedds/xingai-godot/releases) page (see [docs/BUILDING.md](docs/BUILDING.md#automatic-releases-github-actions)).

To re-generate `game/assets/` from the original game (after changing a converter):

```sh
# 1. the original game at orig/ (a symlink or a copy; /orig is gitignored)
ln -s "/path/to/新改曹操傳6.6修正版" orig

# 2. convert it into game/assets
python3 -m venv tools/venv
tools/venv/bin/pip install pillow numpy capstone pefile fonttools
tools/venv/bin/python -I tools/dump_image.py
tools/venv/bin/python -I tools/conv_data.py
tools/conv_skills.sh
tools/venv/bin/python -I tools/eex.py
tools/venv/bin/python -I tools/conv_gfx.py
tools/venv/bin/python -I tools/conv_audio.py
tools/conv_video.sh
tools/venv/bin/python -I tools/gbk_table.py
tools/venv/bin/python -I tools/subset_font.py PATH/NotoSerifSC-Regular.otf
cp PATH/LICENSE game/assets/fonts/OFL.txt          # the font's licence (SIL OFL 1.1)
tools/venv/bin/python -I tools/mark_keep.py
```

The converters only read `orig/`; nothing from the original game is executed. Each step is explained in
[docs/BUILDING.md](docs/BUILDING.md#re-generating-the-game-data). `run_game.sh` builds Godot's import cache when it
is missing or outdated (a minute the first time) and passes its arguments to Godot. To use Godot directly, run
`godot --headless --path game --import` once, then `godot --path game`.

How to play — controls, menus, battles, saving — is in **[docs/PLAYING.md](docs/PLAYING.md)**. In short: left click
selects, right click or Esc cancels and opens the menus, holding Space or Ctrl fast-forwards; on phones the side
buttons 菜单 / 返回 / 快进 replace the right click and the keys.

## Building the apps

```sh
godot --headless --path game --import                                    # once
godot --headless --path game --export-release "macOS" ../build/XinGai.app  # universal macOS app
tools/build_ios.sh --device                                              # iPhone (Xcode, Apple developer account)
tools/build_android.sh --install                                         # Android APK (JDK 17, Android SDK)
```

The apps are named 新改曹操傳 (bundle / package id `com.seedds.xingai` on iPhone and Android). Every build ships
the original pictures; there is no HD graphics pack for this game yet. Export templates, signing, the simulator
build, smoke tests and the (not yet active) release workflow are in [docs/BUILDING.md](docs/BUILDING.md).

## Documentation

| Document | Contents |
|---|---|
| [docs/PLAYING.md](docs/PLAYING.md) | player guide: title screen, controls, story scenes, battles, duels, saving, troubleshooting |
| [docs/BUILDING.md](docs/BUILDING.md) | exporting the macOS / iPhone / Android apps; converting the original game data |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the port works: emulated memory, script VM, stages, UI |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | debug options, automated play-through tests, reverse-engineering workflow |
| [docs/HD_GRAPHICS.md](docs/HD_GRAPHICS.md) | the HD art mechanism and what a pack for this game would need |
| [docs/README.md](docs/README.md) | index of the reverse-engineering specifications (memory, data, scripts, graphics, battle, skills, AI, duels) |

## Repository layout

| Path | Contents |
|---|---|
| `game/` | the Godot project: `src/` (GDScript), `assets/` (converted game data, generated by the converters), `export/` (app icons), `export_presets.cfg` |
| `tools/` | converters, analysis helpers, Ghidra headless scripts, build and test scripts |
| `docs/` | guides and reverse-engineering specifications |
| `.github/` | the release workflow (not active yet) and its version-stamp script |
| `run_game.sh` | runs the game from source |

Not in the repository (`.gitignore`): the original game (`orig/`), the converted data (`game/assets/`), build
output (`build/`), scratch output of the tools (`extract/`) and the Python environment (`tools/venv`).

## Legal

This is an unofficial fan project for preservation and study. It is not affiliated with or endorsed by Koei Tecmo
or the authors of the mod. *三国志曹操传* is © Koei Tecmo. **The original game data is not included**: the
repository contains only the reimplementation, the converters and the documentation; the game content (pictures,
music, sound, video, text, scripts) has to come from your own copy of the original game and remains the property
of its respective rights holders. The repository has no licence file yet, so all rights to the code are reserved.
