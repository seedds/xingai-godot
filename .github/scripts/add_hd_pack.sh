#!/bin/bash
# Release builds ship the HD art only. The pack (the contents of game/assets_hd, built locally with
# tools/upscale_assets.py) is the asset assets_hd.zip of the release tagged hd-pack. This puts it into
# game/assets_hd and leaves the original pictures out of every export preset. Needs GH_TOKEN; Linux or macOS.
set -euo pipefail
tmp="$(mktemp -d)"
gh release download hd-pack -p "assets_hd.zip" -D "$tmp"
# GitHub's SHA-256 of the asset catches a truncated or replaced-while-downloading pack
want=$(gh release view hd-pack --json assets --jq '.assets[] | select(.name=="assets_hd.zip") | .digest')
echo "${want#sha256:}  $tmp/assets_hd.zip" | shasum -a 256 -c -
unzip -q "$tmp/assets_hd.zip" -d game/assets_hd
rm -r "$tmp"
n=$(find game/assets_hd -name '*.webp' | wc -l)
echo "HD pack: $n images"
test "$n" -ge 3400
# every texture the game draws has an HD version (palettes, index files and the terrain-patch index images stay);
# the iOS preset already has this list (tools/build_ios.sh builds HD-only too)
exclude="assets/gfx/backgrounds/*.png,assets/gfx/maps/*.png,assets/gfx/units/*.png,assets/gfx/rpg_sprites/*.png"
exclude="$exclude,assets/gfx/portraits/*.png,assets/gfx/screens/*.png,assets/gfx/effects/xben/*.png"
exclude="$exclude,assets/gfx/effects/mcall/*.png,assets/gfx/effects/kao/*.png,assets/gfx/effects/qusi/*.png"
exclude="$exclude,assets/gfx/effects/items32/*.png,assets/gfx/effects/ranges/*.png,assets/gfx/effects/weather/*.png"
exclude="$exclude,assets/gfx/icons/*.png,assets/gfx/terrain/*.png,assets/gfx/ui/*.png"
EXCLUDE="$exclude" perl -pi -e 's#^exclude_filter=""#exclude_filter="$ENV{EXCLUDE}"#' game/export_presets.cfg
presets=$(grep -c '^\[preset\.[0-9]*\]$' game/export_presets.cfg)
test "$(grep -cF "exclude_filter=\"$exclude" game/export_presets.cfg)" -eq "$presets"   # all presets
