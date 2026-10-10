#!/bin/bash
# Build the Android app (an .apk signed with the release key) from game/ and optionally install it.
#
#   tools/build_android.sh              build/XinGai.apk
#   tools/build_android.sh --install    ... then install and start it on the connected phone or running emulator
#                                       (with several, ANDROID_SERIAL=… picks one; see `adb devices`)
#
# Needs Godot 4.7.2 (GODOT=path overrides `godot`) with its Android export template (android_release.apk, see
# docs/BUILDING.md), a JDK 17+ and the Android SDK (build-tools and platform-tools) set in Godot's editor settings
# (Export → Android). The HD pack (game/assets_hd) is optional.
# Signing: the release key, so the build installs over the published ones and keeps their saves. By default
# ~/.android/wagang-release.keystore (alias wagang) with its password in the login keychain (item
# wagang-android-keystore); GODOT_ANDROID_KEYSTORE_RELEASE_PATH / _USER / _PASSWORD override it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
godot="${GODOT:-godot}"
install=0
case "${1:-}" in
  --install) install=1 ;;
  "") ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac

ver="$("$godot" --version | cut -d. -f1-3)"
data="$HOME/Library/Application Support/Godot"
[ "$(uname)" = Darwin ] || data="${XDG_DATA_HOME:-$HOME/.local/share}/godot"
tpl="$data/export_templates/${ver}.stable/android_release.apk"
if [ ! -f "$tpl" ]; then
  echo "no Android export template at $tpl (see docs/BUILDING.md)" >&2
  exit 1
fi

if [ -z "${GODOT_ANDROID_KEYSTORE_RELEASE_PATH:-}" ]; then
  export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$HOME/.android/wagang-release.keystore"
  export GODOT_ANDROID_KEYSTORE_RELEASE_USER="wagang"
  GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$(security find-generic-password -s wagang-android-keystore -w 2> /dev/null)" \
    || { echo "no password for the release key in the keychain (item wagang-android-keystore)" >&2; exit 1; }
  export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD
fi
if [ ! -f "$GODOT_ANDROID_KEYSTORE_RELEASE_PATH" ]; then
  echo "no release key at $GODOT_ANDROID_KEYSTORE_RELEASE_PATH (see docs/BUILDING.md)" >&2
  exit 1
fi

echo "== exporting build/XinGai.apk"
mkdir -p "$root/build"
rm -f "$root/build/XinGai.apk"
(cd "$root/game" && "$godot" --headless --path . --export-release "Android" ../build/XinGai.apk) \
  > "$root/build/android_export.log" 2>&1 || { tail -30 "$root/build/android_export.log"; exit 1; }
test -s "$root/build/XinGai.apk" || { tail -30 "$root/build/android_export.log"; exit 1; }
ls -la "$root/build/XinGai.apk"

if [ "$install" = 1 ]; then
  package="$(awk '/^\[preset\.[0-9]+\]$/ { a = 0 } /^name="Android"/ { a = 1 } a && /^package\/unique_name=/ {
    sub(/^[^"]*"/, ""); sub(/"$/, ""); print; exit }' "$root/game/export_presets.cfg")"
  echo "== installing $package"
  adb install -r "$root/build/XinGai.apk"
  adb shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 > /dev/null
  echo "the game's output: adb logcat -s godot"
fi
