#!/bin/bash
# Build the iPhone app from game/ (Godot iOS export → Xcode project → xcodebuild) and optionally install it.
#
#   tools/build_ios.sh                  signed app (development) in build/ios_sym/Release-iphoneos/XinGai.app
#   tools/build_ios.sh --device [UDID]  ... then install and launch it on a connected iPhone (default: the first
#                                       reachable one with Developer Mode on); Xcode registers the device if needed
#   tools/build_ios.sh --unsigned       unsigned build/XinGai-iOS.ipa for sideloading (what the release workflow ships)
#   tools/build_ios.sh --sim [DEVICE]   native arm64 build for the Xcode Simulator, installed and started there
#                                       (DEVICE: simulator name or UDID, default "iPhone 18 Pro"); needs the arm64
#                                       simulator engine library from tools/build_ios_sim_lib.sh
#
# Needs Xcode, Godot 4.7.2 (GODOT=path overrides `godot`) with its iOS export template (ios.zip, see
# docs/BUILDING.md) and the HD pack in game/assets_hd (the iOS preset leaves the original pictures out).
# Signing is automatic with the team in the iOS preset (TEAM=… overrides). IOS_ENV='{"WG_…":"…"}' passes
# environment variables to the launched app (debug switches, see docs/DEVELOPMENT.md), on a device or simulator.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
godot="${GODOT:-godot}"
mode="signed"
udid=""
case "${1:-}" in
  --device) mode="device"; udid="${2:-}" ;;
  --unsigned) mode="unsigned" ;;
  --sim) mode="sim"; sim="${2:-iPhone 18 Pro}" ;;
  "") ;;
  *) sed -n '2,17p' "$0"; exit 2 ;;
esac

preset_value() {   # option of the iOS preset in export_presets.cfg
  awk -v key="$1" '/^\[preset\.[0-9]+\]$/ { ios = 0 } /^name="iOS"/ { ios = 1 } /^\[preset\.[0-9]+\.options\]/ { opts = ios }
    opts && index($0, key "=") == 1 { sub(/^[^=]*="?/, ""); sub(/"$/, ""); print; exit }' "$root/game/export_presets.cfg"
}
bundle_id="$(preset_value application/bundle_identifier)"
team="${TEAM:-$(preset_value application/app_store_team_id)}"

if [ ! -d "$root/game/assets_hd/gfx" ]; then
  echo "game/assets_hd is missing: the iOS build ships the HD pack only (see docs/HD_GRAPHICS.md)" >&2
  exit 1
fi
ver="$("$godot" --version | cut -d. -f1-3)"
tpl="$HOME/Library/Application Support/Godot/export_templates/${ver}.stable/ios.zip"
if [ ! -f "$tpl" ]; then
  echo "no iOS export template at $tpl (see docs/BUILDING.md)" >&2
  exit 1
fi

simlib="$root/build/ios_sim_lib/libgodot.a"
if [ "$mode" = "sim" ] && { [ ! -f "$simlib" ] || [ "$(cat "$root/build/ios_sim_lib/version.txt" 2>/dev/null)" != "$ver" ]; }; then
  echo "no arm64 simulator engine library for Godot $ver: run tools/build_ios_sim_lib.sh first" >&2
  exit 1
fi

if [ "$mode" = "device" ] && [ -z "$udid" ]; then
  json="$(mktemp)"
  xcrun devicectl list devices --json-output "$json" > /dev/null
  udid="$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    hw, cp, dp = d.get("hardwareProperties", {}), d.get("connectionProperties", {}), d.get("deviceProperties", {})
    if (hw.get("reality") == "physical" and hw.get("deviceType") == "iPhone" and cp.get("pairingState") == "paired"
            and cp.get("tunnelState") != "unavailable" and dp.get("developerModeStatus") == "enabled"):
        print(hw["udid"]); break' "$json")"
  rm -f "$json"
  if [ -z "$udid" ]; then
    echo "no reachable iPhone: connect and unlock it (Developer Mode on), or pass its UDID" >&2
    xcrun devicectl list devices >&2
    exit 1
  fi
fi

echo "== exporting the Xcode project"
rm -rf "$root/build/ios"
mkdir -p "$root/build/ios"
(cd "$root/game" && "$godot" --headless --path . --export-release "iOS" ../build/ios/XinGai.ipa) > "$root/build/ios_export.log" 2>&1 \
  || { tail -30 "$root/build/ios_export.log"; exit 1; }
test -s "$root/build/ios/XinGai.pck" && test -d "$root/build/ios/XinGai.xcodeproj"

echo "== building ($mode)"
sym="$root/build/ios_sym"
common=(-project "$root/build/ios/XinGai.xcodeproj" -scheme XinGai -configuration Release
  -derivedDataPath "$root/build/ios_dd" SYMROOT="$sym")
if [ "$mode" = "sim" ]; then
  # the template's simulator slice is x86-64 only: add the arm64 library, and build arm64 only
  slice="$(ls -d "$root"/build/ios/XinGai.xcframework/*simulator)"
  lipo -create "$slice/libgodot.a" "$simlib" -output "$slice/libgodot.fat.a"
  mv "$slice/libgodot.fat.a" "$slice/libgodot.a"
  xcodebuild "${common[@]}" -sdk iphonesimulator -destination "generic/platform=iOS Simulator" ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$root/build/ios_build.log" 2>&1 \
    || { grep -E "error:" "$root/build/ios_build.log" | head -20; exit 1; }
elif [ "$mode" = "unsigned" ]; then
  common+=(-sdk iphoneos)
  xcodebuild "${common[@]}" -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO build > "$root/build/ios_build.log" 2>&1 \
    || { grep -E "error:" "$root/build/ios_build.log" | head -20; exit 1; }
else
  common+=(-sdk iphoneos)
  dest="generic/platform=iOS"
  [ -n "$udid" ] && dest="id=$udid"
  xcodebuild "${common[@]}" -destination "$dest" -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" build > "$root/build/ios_build.log" 2>&1 \
    || { grep -E "error:" "$root/build/ios_build.log" | head -20; exit 1; }
fi
app="$sym/Release-iphoneos/XinGai.app"
[ "$mode" = "sim" ] && app="$sym/Release-iphonesimulator/XinGai.app"
test -f "$app/XinGai.pck"

if [ "$mode" = "sim" ]; then
  echo "== installing on the simulator \"$sim\""
  xcrun simctl boot "$sim" 2> /dev/null || true      # (fails when it is already booted)
  # the simulator window: Simulator.app, or DeviceHub.app from Xcode 27 on
  for ui in "$(xcode-select -p)/Applications/Simulator.app" "$(xcode-select -p)/../Applications/DeviceHub.app"; do
    if [ -d "$ui" ]; then open "$ui"; break; fi
  done
  xcrun simctl bootstatus "$sim" -b > /dev/null
  xcrun simctl install "$sim" "$app"
  # simctl passes SIMCTL_CHILD_X to the app as X
  if [ -n "${IOS_ENV:-}" ]; then
    while IFS= read -r kv; do export "SIMCTL_CHILD_$kv"; done < <(python3 -I -c '
import json, sys
for k, v in json.loads(sys.argv[1]).items():
    print(f"{k}={v}")' "$IOS_ENV")
  fi
  # the game's output goes to build/ios_sim.log
  xcrun simctl launch --terminate-running-process --stdout="$root/build/ios_sim.log" --stderr="$root/build/ios_sim.log" \
    "$sim" "$bundle_id"
elif [ "$mode" = "unsigned" ]; then
  stage="$(mktemp -d)"
  mkdir "$stage/Payload"
  cp -R "$app" "$stage/Payload/"
  rm -f "$root/build/XinGai-iOS.ipa"
  (cd "$stage" && zip -q -r -y "$root/build/XinGai-iOS.ipa" Payload)
  rm -rf "$stage"
  echo "== $root/build/XinGai-iOS.ipa"
elif [ "$mode" = "device" ]; then
  echo "== installing on $udid"
  xcrun devicectl device install app --device "$udid" "$app"
  launch=(xcrun devicectl device process launch --device "$udid" --terminate-existing)
  [ -n "${IOS_ENV:-}" ] && launch+=(--environment-variables "$IOS_ENV")
  "${launch[@]}" "$bundle_id"
else
  echo "== $app"
fi
