# Building

The repository holds the code, the converters and the documentation, not the game. The converted game data
(`game/assets/`) is **gitignored for now**: it is generated from an original copy of 新改曹操傳 6.6 by the tools in
`tools/` (see [Re-generating the game data](#re-generating-the-game-data)). Once `game/assets/` exists, running and
exporting only need Godot. This page covers **exporting the apps**, the **converter pipeline** and the state of the
**GitHub Actions** workflow.

## Exporting the apps

Requirements: [Godot 4.7](https://godotengine.org) (4.7.2; `brew install --cask godot`) with its export templates
(Godot → Editor → Manage Export Templates → Download; the full download has macOS, Windows, iOS and Android), and
the converted data in `game/assets/`. Build Godot's import cache once before the first export:

```sh
godot --headless --path game --import
```

All presets are in `game/export_presets.cfg`. They pack `assets/*` (and `assets_hd/*`, which does not exist for
this game, see [HD_GRAPHICS.md](HD_GRAPHICS.md)) and the scripts, so **every build ships the original pictures**.
Export paths are relative to `game/`, so `../build/…` ends up in `build/` at the repository root.

### macOS

```sh
godot --headless --path game --export-release "macOS" ../build/XinGai.app
```

* A **universal** app (Intel macOS 10.13+, Apple Silicon 11+), ad-hoc code-signed, bundle id
  `local.xgccz.xingai`, about 860 MB. The executable and the data pack are named after the project
  (`application/config/name`): `XinGai.app/Contents/MacOS/新改曹操傳` and `Contents/Resources/新改曹操傳.pck`. The
  icon is `game/export/ios_icon.png`, cut from the title picture.
* For distribution outside your own machines, sign with a Developer ID and notarize (`codesign/*` and
  `notarization/*` in the preset). An ad-hoc signed app copied to another Mac is blocked by Gatekeeper the first
  time (see [PLAYING.md](PLAYING.md#troubleshooting)).

### Windows

```sh
godot --headless --path game --export-release "Windows" ../build/windows/XinGai.exe
```

The preset (x86-64, `XinGai.exe` plus `XinGai.pck`, no code signing) is inherited from the wg2025 port and has not
been tested with this game. The `.pck` is the same on every platform, so it can be checked on a Mac with
`godot --headless --main-pack build/windows/XinGai.pck` and the smoke-test variables below.

### iPhone

Requirements: a Mac with Xcode, and Godot's iOS export template (`ios.zip` in
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`; it is in the full template download, or
extract `templates/ios.zip` from `Godot_v4.7.2-stable_export_templates.tpz`).

```sh
tools/build_ios.sh --device                # build, install and start it on the connected iPhone
tools/build_ios.sh                         # signed app only: build/ios_sym/Release-iphoneos/XinGai.app
tools/build_ios.sh --unsigned              # unsigned build/XinGai-iOS.ipa, for sideloading (AltStore, Sideloadly)
tools/build_ios_sim_lib.sh                 # once per Godot version: the arm64 engine library for the simulator
tools/build_ios.sh --sim                   # native arm64 build, installed and started in the Xcode Simulator
```

* The script exports the **iOS** preset as an Xcode project (`build/ios/`) and builds it with `xcodebuild`. Logs:
  `build/ios_export.log`, `build/ios_build.log`.
* The preset: bundle id `com.seedds.xingai`, team `9LK4YZ82JR` (`application/app_store_team_id`; `TEAM=…`
  overrides it), iPhone only, iOS 15+, arm64, landscape. The app is `XinGai.app` (executable `XinGai`), shown on
  the home screen as 新改曹操傳. Change the bundle id and the team for your own Apple account.
* **Signing** is automatic (`-allowProvisioningUpdates`) with an *Apple Development* certificate; Xcode must be
  signed in to the team's account. Building for a device registers it with the team if needed.
* **Device:** `--device` picks the first paired, reachable iPhone with Developer Mode on (or pass its UDID; list
  them with `xcrun devicectl list devices`). It must be unlocked. `IOS_ENV='{"WG_START":"1"}'` passes debug
  variables ([DEVELOPMENT.md](DEVELOPMENT.md)) to the app.
* **Simulator:** the official template's simulator library is x86-64 only, so `tools/build_ios_sim_lib.sh`
  compiles the same Godot version's library for the arm64 simulator into `build/ios_sim_lib/libgodot.a` (about
  20 minutes once; the Godot source stays in `build/godot-src`, and `scons` is installed into `tools/venv`).
  `--sim` merges it into the exported project and builds with `ARCHS=arm64`. The library depends only on the Godot
  version, so `build/ios_sim_lib` may be a symlink to another checkout's copy (e.g. the wg2025 port's).
  The default simulator is *iPhone 18 Pro* (`--sim "iPhone 17e"` picks another, by name or UDID); the game's output
  goes to `build/ios_sim.log`. The simulator runs Godot's Compatibility (OpenGL) renderer, a phone uses Metal.
* The app is about 750 MB. File sharing is on, so the saves show up in the Files app. The launch screen is
  `game/export/ios_launch.png`. On iOS and Android the project starts `res://src/touch/touch_shell.tscn` instead of
  `main.tscn` (`run/main_scene.mobile`), and text uses the bundled Noto Serif SC subset (`assets/fonts`), since iOS
  has no Song typeface.

### Android

Requirements: Godot's Android export template (`android_release.apk` in
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`, or extract `templates/android_release.apk`
from the `.tpz`), a JDK 17 and the Android SDK with platform-tools and build-tools (Android Studio installs them),
entered in Godot's editor settings (*Editor Settings → Export → Android*: Java SDK Path, Android SDK Path), and the
release key (below).

```sh
tools/build_android.sh                     # build/XinGai.apk, signed with the release key
tools/build_android.sh --install           # ... then install and start it on the connected phone or emulator (adb)
```

* The **Android** preset fills Godot's prebuilt APK template (no Gradle build): package `com.seedds.xingai`,
  64-bit ARM only, Android 7.0+ (API 24, Godot's default), landscape, immersive full screen. The APK is about
  700 MB. Export log: `build/android_export.log`; the game's output: `adb logcat -s godot`.
* **Renderer:** `command_line/extra_args` starts the Compatibility renderer (OpenGL ES 3) instead of Godot's
  Vulkan-based Mobile renderer; it runs on more phones (and in the emulator, where the Vulkan renderer stalls).
* **Launcher icon:** `game/export/ios_icon.png`, and for adaptive icons `android_icon_fg.png` over
  `android_icon_bg.png`.
* Text is decoded with the game's own GBK table (`assets/data/gbk.bin`, `core/gbk.gd`): Android has no iconv, so
  Godot's multibyte conversion does not work there.
* The back button or gesture does what 返回 / 菜单 do; it does not quit the app. Saves stay in the app's private
  storage: kept when a newer build is installed over it, deleted when the app is uninstalled.
* **Signing:** every build must be signed with the same key, or Android refuses to install it over the previous
  one (players would have to uninstall first, which deletes their saves). `tools/build_android.sh` uses the release
  key of the wg2025 port: `~/.android/wagang-release.keystore` (alias `wagang`, certificate `CN=WaGang`, SHA-256
  `a07c41ea…e667`) with its password in the login keychain (item `wagang-android-keystore`). The two games have
  different package names, so sharing the key is harmless. `GODOT_ANDROID_KEYSTORE_RELEASE_PATH` / `_USER` /
  `_PASSWORD` select another key. Keep a backup of the keystore and its password: without them no new build can
  update an installed one.

### Smoke tests

Any build can play the first scenarios without a window (the macOS binary shown; for the `.pck` use
`godot --headless --main-pack …`):

```sh
app="build/XinGai.app/Contents/MacOS/新改曹操傳"
WG_START=0 WG_AUTO=1 WG_GOD=1 WG_STOP=3 WG_NOVIDEO=1 "$app" --headless   # story: R_000, R_001, R_150, R_107
WG_START=1 WG_AUTO=1 WG_GOD=1 WG_STOP=2 WG_NOVIDEO=1 "$app" --headless   # the first battle: S_000, then R_001
```

Each prints a `== scenario n: FILE` line per file and exits with code 0 (a new game goes R_000 → R_001 → R_150 →
R_107). Look for `SCRIPT ERROR`, `missing image`, `missing json` or `Failed to load` in the output. The same
variables work with `./run_game.sh --headless` from source. Longer automated play-throughs are described in
[DEVELOPMENT.md](DEVELOPMENT.md).

## Re-generating the game data

Everything under `game/assets/` is produced from the original game by the converters in `tools/`. The output is
gitignored until the converters are considered stable.

### Prerequisites

* **The original game at `orig/`** in the repository root: the 新改曹操傳 6.6 修正版 directory, as a symlink
  (`ln -s "/path/to/新改曹操傳6.6修正版" orig`) or a copy. It is copyrighted and never committed (`/orig` is in
  `.gitignore`). The converters read `Ekd5.exe` (parsed, never executed), `Data.e5`, `Star.e5`, `Imsg.e5`,
  `System.ini`, `Hexzmap.e5`, `Pmapobj.e5`, the `Unit_*.e5` sprites, `Mark.DEC`, `Cmdicon.dll` (resources read as
  data), `E5/` (pictures, portraits, effects), `MAP/` (battle maps), `RS/` (the `R_###.eex` / `S_###.eex`
  scripts), `SoundTrk/`, `WAV/` and the `.avi` videos. Treat the directory as untrusted input: never run anything
  from it.
* **Python 3** with a virtual environment in `tools/venv`:
  ```sh
  python3 -m venv tools/venv
  tools/venv/bin/pip install pillow numpy capstone pefile fonttools
  ```
* **ffmpeg** on the PATH (sound effects) and Homebrew's **ffmpeg-full**, which has libtheora (videos):
  `brew install ffmpeg ffmpeg-full`.
* **Noto Serif SC** (SIL OFL 1.1) for the mobile font: `NotoSerifSC-Regular.otf` from
  [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk) (`Serif/SubsetOTF/SC/`), with its `LICENSE` (the OFL
  text).

The converters find the repository from their own location (`tools/..`) and read `orig/` there; most also take
the game directory or the output directory as an argument (see each script's header).

### Steps

Run from the repository root, in this order. Each step writes into `game/assets/`.

| # | Command | Produces |
|---|---|---|
| 1 | `tools/venv/bin/python -I tools/dump_image.py` | `data/exe_image.bin`: `Ekd5.exe`'s sections as one flat image at 0x400000, the game's emulated memory |
| 2 | `tools/venv/bin/python -I tools/conv_data.py` | `data/*.json`: persons, items, classes, class families, strategies, shops, terrain, names, texts (`Imsg.e5`), sprite tables |
| 3 | `tools/conv_skills.sh` | `data/skills.json`: the 特效 / item-effect catalogue and the 必杀 records (reads step 2's JSON) |
| 4 | `tools/venv/bin/python -I tools/eex.py` | `scripts/R_###.json`, `S_###.json` (249 files) and `opcodes.json`; text listings in `extract/eex_txt/` |
| 5 | `tools/venv/bin/python -I tools/conv_gfx.py` | `gfx/`: units, rpg_sprites, backgrounds, maps, portraits, screens, effects, icons, terrain, ui, each with an `index.json` (8,501 files) |
| 6 | `tools/venv/bin/python -I tools/conv_audio.py` | `audio/bgm/NN.mp3` (the 198 music tracks, copied) and `audio/se/*.wav` (143 sound effects as 16-bit PCM) |
| 7 | `tools/conv_video.sh` | `video/logo.ogv`, `open.ogv`, `end.ogv` (Theora / Vorbis) |
| 8 | `tools/venv/bin/python -I tools/gbk_table.py` | `data/gbk.bin`: the GBK table the game decodes text with |
| 9 | `tools/venv/bin/python -I tools/subset_font.py PATH/NotoSerifSC-Regular.otf` | `fonts/NotoSerifSC-game.otf`: the font cut to the characters of the scripts, data and sources (needs steps 2–5) |
| 10 | `cp PATH/LICENSE game/assets/fonts/OFL.txt` | the font's licence, shipped with it |
| 11 | `tools/venv/bin/python -I tools/mark_keep.py` | a `*.import` file with `importer="keep"` next to every asset |
| 12 | `godot --headless --path game --import` | Godot's import cache |

Notes:

* **Step 4** checks every file while converting and prints a summary (`files: 249 ok, 0 errors; …`).
  `--stats` adds the opcode frequency table; `--out DIR` / `--txt DIR` write elsewhere. Format: [eex.md](eex.md).
* **Step 5** takes about 20 seconds on an Apple Silicon Mac. `--only units,portraits` limits it to some categories
  (`--list` prints them). The formats are documented in [gfx.md](gfx.md).
* **Step 7** converts only the videos the engine names (`Logo`, `Open`, `End`; `end2.avi` is unused) and skips
  outputs that exist: delete `game/assets/video/*.ogv` to redo them.
* **Step 9** reports characters the font lacks; they are drawn by the system-font fallback. Re-run it when the
  scripts or the UI texts change.
* **Step 11 is required.** Godot only ships the raw PNG/JPEG/JSON/MP3/WAV/OGV/BIN files, which the game loads at run
  time through `Assets`, if they are marked `importer="keep"` (steps 8 and 9 write their own `.import` files).

After converting, start the game once (`./run_game.sh`) and run the smoke tests above.

## Automatic releases (GitHub Actions)

`.github/workflows/release.yml` comes from the wg2025 port, where it builds macOS, Windows, iPhone and Android on
every push to `main` and publishes them as a GitHub release *Build N* (version `1.0.N`, stamped by
`.github/scripts/stamp_version.sh`). It has been adapted to this game (`XinGai` file names, original pictures, no HD
pack), but **it is not set up for this repository**: the repository has no GitHub remote, and the runners would
need the converted data, which is gitignored (`game/assets/` would have to be committed first). For the Android
job the repository secrets `ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD` would have to hold the release
key above; the workflow checks the APK's certificate against `ANDROID_CERT_SHA256` (that key's `a07c41ea…e667`).
