# Building

The repository contains the converted game data (`game/assets/`); the HD graphics pack (`game/assets_hd/`) is
downloaded by `run_game.sh` or `tools/get_hd_pack.sh`. To play or develop you only need Godot. This page covers
**exporting the apps** yourself, the **automatic releases**, and **re-generating `game/assets/`** from an original
copy of the game.

## Exporting the apps

Requirements: [Godot 4.7](https://godotengine.org) (`brew install --cask godot`) with the export templates
installed (Godot → Editor → Manage Export Templates → Download; the full download has macOS, Windows, iOS and
Android).

### macOS

```sh
godot --headless --path game --import                                  # build Godot's import cache (first time)
godot --headless --path game --export-release "macOS" ../build/WaGang.app
```

* The output path is relative to `game/`, so `../build/WaGang.app` ends up in `build/` at the repository root.
* The preset (`game/export_presets.cfg`) builds a **universal** binary (Intel macOS 10.13+, Apple Silicon 11+),
  ad-hoc code-signed, bundle id `local.wg2025.wagang`. It packs `assets/*`, `assets_hd/*` (the HD graphics pack,
  if present) and the scripts. A local export keeps the original pictures too: about 1.5 GB with the HD pack,
  860 MB without. (The release builds leave the originals out; see below.)
* Smoke test without a window: `WG_START=0 WG_AUTO=1 WG_STOP=2 WG_NOVIDEO=1 build/WaGang.app/Contents/MacOS/* --headless`.
  It should print `== scenario 0: R_00` … `== scenario 2: R_01`.

For distribution outside your own machines, sign with a Developer ID and notarize. Set `codesign/*` and
`notarization/*` in the preset.

### Windows

```sh
godot --headless --path game --export-release "Windows" ../build/windows/WaGang.exe
```

The preset exports `WaGang.exe` plus `WaGang.pck` (x86-64, no code signing; icon and version resources are not
modified, so no `rcedit` is needed). The `.pck` is the same on every platform, so it can be checked on a Mac:
`godot --headless --main-pack build/windows/WaGang.pck` with the smoke-test variables above.

### iPhone

Requirements: a Mac with Xcode, Godot's iOS export template (`ios.zip` in
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`; it is in the full template download, or
extract `templates/ios.zip` from `Godot_v4.7.2-stable_export_templates.tpz`) and the HD graphics pack in
`game/assets_hd` (the iOS preset ships the HD art only, like the releases).

```sh
godot --headless --path game --import      # first time
tools/build_ios.sh --device                # build, install and start it on the connected iPhone
tools/build_ios.sh                         # build a signed app only (build/ios_sym/Release-iphoneos/WaGang.app)
tools/build_ios.sh --unsigned              # unsigned build/WaGang-iOS.ipa for sideloading (what the releases ship)
tools/build_ios_sim_lib.sh                 # once per Godot version: arm64 engine library for the simulator
tools/build_ios.sh --sim                   # native arm64 build, installed and started in the Xcode Simulator
```

* The script exports the **iOS** preset as an Xcode project (`build/ios/`), then builds it with `xcodebuild`.
  Logs: `build/ios_export.log`, `build/ios_build.log`.
* **Signing** is automatic (`-allowProvisioningUpdates`) with the team in the preset
  (`application/app_store_team_id`; `TEAM=…` overrides it) and an *Apple Development* certificate. Xcode must be
  signed in to that team's Apple account; building for a device registers it with the team if needed. Change
  `application/bundle_identifier` (`com.seedds.wagang`) and the team for your own account.
* **Device:** `--device` picks the first paired, reachable iPhone with Developer Mode on (or pass its UDID; list
  them with `xcrun devicectl list devices`). It must be unlocked. `IOS_ENV='{"WG_START":"1"}'` passes debug
  variables to the app.
* **Simulator:** always a native Apple Silicon (arm64) build. The official template's simulator library is x86-64
  only, so `tools/build_ios_sim_lib.sh` compiles the same Godot version's library for the arm64 simulator
  (about 20 minutes once; the source stays in `build/godot-src`). `--sim` adds it to the exported project and
  builds with `ARCHS=arm64`.
  * The default simulator is *iPhone 18 Pro*; `--sim "iPhone 17e"` picks another, by name or UDID.
  * The game's output goes to `build/ios_sim.log`.
  * The simulator has no Metal driver in Godot, so it runs the Compatibility (OpenGL) renderer; a phone uses Metal.
* The preset targets iPhone (iOS 15+, A12 or newer), landscape only. File sharing is on, so the saves show up in
  the Files app. The icon is `game/export/ios_icon.png`, cut from the title art. On iOS the project runs
  `res://src/touch/touch_shell.tscn` instead of `main.tscn` (`run/main_scene.mobile`).

### Android

Requirements: Godot's Android export template (`android_release.apk` in
`~/Library/Application Support/Godot/export_templates/4.7.2.stable/`; it is in the full template download, or
extract `templates/android_release.apk` from the `.tpz`), a JDK 17 and the Android SDK with platform-tools and
build-tools (Android Studio installs them) entered in Godot's editor settings (*Editor Settings → Export → Android*:
Java SDK Path, Android SDK Path), the HD graphics pack in `game/assets_hd`, and the release key (below).

```sh
godot --headless --path game --import      # first time
tools/build_android.sh                     # build/WaGang.apk, signed with the release key
tools/build_android.sh --install           # ... then install and start it on the connected phone or emulator (adb)
```

* The **Android** preset fills Godot's prebuilt APK template (no Gradle build): 64-bit ARM only, Android 7.0+
  (API 24), package `com.seedds.wagang`, landscape, immersive full screen, HD art only like iOS. The APK is about
  1.1 GB. Export log: `build/android_export.log`; the game's output: `adb logcat -s godot`.
* **Renderer:** the preset starts the game with the Compatibility renderer (OpenGL ES 3, through
  `command_line/extra_args`) instead of Godot's Vulkan-based Mobile renderer. It runs on more phones, and it is the
  configuration that was tested (in the Android emulator Godot's Vulkan renderer stalls on a black screen). iOS keeps
  the Mobile renderer (Metal).
* **Launcher icon:** `game/export/ios_icon.png` (legacy icon) and, for Android 8+ adaptive icons, the same picture at
  two-thirds size (`android_icon_fg.png`) over a blurred copy (`android_icon_bg.png`), because launchers show only
  the middle of an adaptive icon.
* The back button or gesture does what 返回 / 菜单 do; it does not quit the app. Saves stay in the app's private
  storage: kept when a newer build is installed over it, deleted when the app is uninstalled.
* **Signing:** every build must be signed with the same key, or Android refuses to install it over the previous one
  (players would have to uninstall first, which deletes their saves). The release key is
  `~/.android/wagang-release.keystore` (alias `wagang`, PKCS12, RSA 4096, valid until 2054) with its password in
  the login keychain (item `wagang-android-keystore`; `security find-generic-password -s wagang-android-keystore -w`
  prints it). `GODOT_ANDROID_KEYSTORE_RELEASE_PATH` / `_USER` / `_PASSWORD` select another key. **Keep a backup of
  the keystore and its password**: without them no new build can update an installed one.
* The release workflow gets the key from the repository secrets `ANDROID_KEYSTORE_BASE64` and
  `ANDROID_KEYSTORE_PASSWORD`, and checks the APK's certificate against `ANDROID_CERT_SHA256` in the workflow
  (`a07c41ea…e667`). To set the secrets again, or for a fork with its own key (made with
  `keytool -genkeypair -keystore … -storetype PKCS12 -alias wagang -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=WaGang"`;
  then put its certificate's SHA-256 from `keytool -list -v` into `ANDROID_CERT_SHA256`):
  ```sh
  base64 -i ~/.android/wagang-release.keystore | gh secret set ANDROID_KEYSTORE_BASE64
  security find-generic-password -s wagang-android-keystore -w | tr -d '\n' | gh secret set ANDROID_KEYSTORE_PASSWORD
  ```

## Automatic releases (GitHub Actions)

`.github/workflows/release.yml` builds and publishes all four platforms on every push to `main` that changes the game
(pushes touching only `docs/`, Markdown files, `tools/` or `.gitignore` are skipped). It can also be started by
hand from the repository's **Actions** tab (*Release builds → Run workflow*); runs from other branches do nothing.

* **Build number:** the workflow's run number *N*, which increases with every run. The release is tagged
  `build-N` and titled *Build N*; the game's version is `1.0.N`. The version is written into
  `application/config/version`, shown in the title screen's corner, into the macOS and iOS bundle versions and
  into the Android version name, with *N* as the Android version code (it must grow for an update to install). The
  repository itself keeps no version, so local builds show none.
* **Steps:** on an Ubuntu runner it installs Godot 4.7.2 and the macOS and Windows export templates (cached
  between runs; the downloads are checked against pinned SHA-256 sums), imports the project, exports
  `WaGang-macOS-build-N.zip` (universal, ad-hoc signed by Godot's built-in signer) and `WaGang-Windows-build-N.zip`,
  then creates the release with both files and install notes. A run takes about 5 minutes. The actions are pinned
  to commit SHAs.
* **iPhone:** a second job (`ios`, on a macOS runner, after the release exists) installs the macOS Godot editor
  and the iOS template, runs `tools/build_ios.sh --unsigned` and uploads `WaGang-iOS-build-N.ipa` to the same
  release.
* **Android:** a third job (`android`, on an Ubuntu runner, after the release exists) installs Godot and the
  Android template (`android_release.apk`), exports the **Android** preset signed with the release key from the
  repository secrets (see [Android](#android)), checks the signing certificate and the package contents, and uploads
  `WaGang-Android-build-N.apk`. The runner's JDK 17 and Android SDK are used. Each release is about 4.4 GB (macOS
  1.09 GB, Windows 1.07 GB, iPhone 1.1 GB, Android 1.13 GB; HD art only). The HD-pack and version-stamp steps the
  jobs share are `.github/scripts/add_hd_pack.sh` and `stamp_version.sh`.
* **Latest, re-runs and clean-up:** a build becomes the repository's *Latest* release only if its commit is still
  the newest on `main`, so re-running an old build does not replace a newer one. Re-running a build that was
  already published replaces its files. After publishing, the workflow deletes all but the newest 5 `build-N`
  releases and their tags (`KEEP_BUILDS`).
* **HD graphics only:** the workflow downloads the HD graphics pack (`assets_hd.zip` from the release tagged
  `hd-pack`) and fails without it. It sets the presets' `exclude_filter` so the original pictures under
  `assets/gfx` stay out of the builds (palettes, index files and the terrain-patch index images stay). It then
  plays the first scenarios headless from the exported `.pck` and fails if the game exits with an error, a
  picture or data file is missing, or a script fails to compile. After rebuilding the pack, re-upload it (see
  [HD_GRAPHICS.md](HD_GRAPHICS.md)).

## Re-generating the game data

Everything under `game/assets/` is produced from the original game by the converters in `tools/`.

### Prerequisites

* The original game directory, placed at `wg2025/` in the repository root. It is not part of the repository. It
  contains `wagan.wa` (the executable), the `*.wa` / `*.e5` data archives, the `R_xx.wagan` / `S_xx.wagan` scripts,
  `SoundTrk/`, the `Se*.wav` sound effects and the `*.wmv` / `*.avi` videos.
* Python 3 with a virtual environment in `tools/venv`:
  ```sh
  python3 -m venv tools/venv
  tools/venv/bin/pip install pillow numpy pefile capstone av
  ```
* `ffmpeg` on the PATH for audio, and Homebrew's `ffmpeg-full` (it has libtheora) for video:
  `brew install ffmpeg ffmpeg-full`.

> **Paths:** the converters and shell helpers find the repository from their own location (`tools/..`) and
> expect the original game at `wg2025/` in the repository root. `tools/ghidra/gdec.sh` takes `GHIDRA_INSTALL_DIR`
> and `JAVA_HOME_21` from the environment (default: the Homebrew locations).

### Steps

Run from the repository root. Each step writes into `game/assets/`.

| # | Command | Produces |
|---|---|---|
| 1 | `tools/venv/bin/python -I tools/dump_image.py` | `data/exe_image.bin`: `wagan.wa`'s mapped sections as one flat image at 0x400000, used as the emulated memory |
| 2 | `cp wg2025/person.wa game/assets/data/person_wa.bin` | the mod's per-person graphics table, loaded at 0x55a000 |
| 3 | `tools/venv/bin/python -I tools/conv_data.py` | `data/*.json`: persons, classes, class families, items, shops, strategies, terrain, shapes, names, texts |
| 4 | `tools/venv/bin/python -I tools/eex.py` | `scripts/R_xx.json`, `scripts/S_xx.json`, `scripts/opcodes.json` (plus text listings in `extract/eex_txt/`) |
| 5 | `tools/venv/bin/python -I tools/conv_gfx.py` | `gfx/`: maps, terrain, unit sprites, portraits, story backgrounds and sprites, effects, icons, UI pieces, palettes, each with an `index.json` |
| 6 | `python3 -I tools/conv_audio.py` | `audio/bgm/NN.mp3` (CD tracks) and `audio/se/*.wav` (16-bit PCM) |
| 7 | `tools/conv_video.sh` | `video/*.ogv` (Theora/Vorbis) |
| 8 | see below | the two speech-bubble caps in `gfx/effects/kao/` |
| 9 | `python3 -I tools/mark_keep.py` | a `*.import` file with `importer="keep"` next to every asset |
| 10 | `godot --headless --path game --import` | Godot's import cache |

Notes:

* **Step 5** takes several minutes. `--only units,portraits` limits it to some groups (`palettes`, `maps`,
  `terrain`, `icons`, `ui`, `units`, `portraits`, `story`, `effects`), and `--quantize` reproduces the game's
  4-bit-per-channel colours. The formats are documented in [gfx.md](gfx.md).
* **Step 7:** the numbered and `END` videos have their first byte zeroed by the game (`0x30 → 0x00`); the script
  restores it before converting. Videos are scaled to at most 1280 px wide.
* **Step 8** is not part of `conv_gfx.py` yet. The duel screen's speech-bubble caps are 16×64 images that the atlas
  export writes as 64×16; reshape them:
  ```sh
  tools/venv/bin/python -I - <<'EOF'
  from PIL import Image
  d = 'game/assets/gfx/effects/kao/'
  for n in ('19ac0', '19ec0'):
      im = Image.open(d + n + '_64x16.png').convert('RGBA')
      out = Image.new('RGBA', (16, 64)); out.putdata(list(im.getdata())); out.save(d + n + '_16x64.png')
  EOF
  ```
* **Step 9 is required.** Godot only ships the raw PNG/JSON/MP3/WAV/OGV files (which the game loads at run time
  with `Assets.*`) if they are marked `importer="keep"`.

Then rebuild the HD graphics pack (`game/assets_hd/`) from the converted graphics and re-publish it:
`tools/venv/bin/python -I tools/upscale_assets.py`. See [HD_GRAPHICS.md](HD_GRAPHICS.md).

After converting, run the game once (`./run_game.sh`) and an automated smoke test (see
[DEVELOPMENT.md](DEVELOPMENT.md)) before exporting.
