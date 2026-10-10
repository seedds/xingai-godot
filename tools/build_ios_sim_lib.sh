#!/bin/bash
# Build Godot's iOS Simulator engine library for Apple Silicon, for tools/build_ios.sh --sim.
#
# The official iOS export template's simulator library is x86-64 only, and current simulators run native arm64
# apps only. This compiles the same Godot version (as `godot --version` reports) for the arm64 simulator into
# build/ios_sim_lib/libgodot.a. About 20 minutes on an M4 Pro; the source and objects (~3 GB) stay in
# build/godot-src for a faster rebuild. The simulator build has only the OpenGL (Compatibility) renderer;
# Godot falls back to it automatically, while a phone uses Metal.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
godot="${GODOT:-godot}"
ver="$("$godot" --version | cut -d. -f1-3)"
src="$root/build/godot-src"
if [ ! -d "$src" ]; then
  git clone --depth 1 --branch "${ver}-stable" https://github.com/godotengine/godot.git "$src"
fi
scons="$root/tools/venv/bin/scons"
[ -x "$scons" ] || "$root/tools/venv/bin/pip" install scons
(cd "$src" && "$scons" platform=ios target=template_release arch=arm64 simulator=yes generate_bundle=no \
  -j"$(sysctl -n hw.ncpu)")
mkdir -p "$root/build/ios_sim_lib"
cp "$src/bin/libgodot.ios.template_release.arm64.simulator.a" "$root/build/ios_sim_lib/libgodot.a"
echo "$ver" > "$root/build/ios_sim_lib/version.txt"
echo "== $root/build/ios_sim_lib/libgodot.a (Godot $ver, arm64 simulator)"
