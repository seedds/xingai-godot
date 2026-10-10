#!/bin/bash
# Download the HD graphics pack (game/assets_hd, ~720 MB) from the repository's hd-pack release.
# run_game.sh calls this on first run. The pack can also be built locally with tools/upscale_assets.py.
cd "$(dirname "$0")/.." || exit 1
REPO="seedds/wagang-godot"
URL="https://github.com/$REPO/releases/download/hd-pack/assets_hd.zip"
if [ -d game/assets_hd/gfx ]; then
  echo "game/assets_hd already exists"
  exit 0
fi
if [ -e game/assets_hd ]; then
  # left over from an interrupted install: keep it out of the way
  rm -rf game/assets_hd.partial && mv game/assets_hd game/assets_hd.partial || exit 1
  echo "Moved an incomplete game/assets_hd to game/assets_hd.partial"
fi
echo "Downloading the HD graphics pack (~720 MB)…"
mkdir -p build
tmp=$(mktemp -d "$PWD/build/hdpack.XXXXXX") || exit 1    # same volume as game/, so the final mv is a rename
trap 'rm -rf "$tmp"' EXIT
curl -L --fail --progress-bar -o "$tmp/assets_hd.zip" "$URL" || exit 1
# GitHub publishes each release asset's SHA-256; check the download against it when the API answers
want=$(curl -sL --fail "https://api.github.com/repos/$REPO/releases/tags/hd-pack" \
  | python3 -c 'import json,sys
for a in json.load(sys.stdin).get("assets", []):
    if a.get("name") == "assets_hd.zip": print((a.get("digest") or "").replace("sha256:", ""))' 2>/dev/null)
if [ -n "$want" ]; then
  have=$(shasum -a 256 "$tmp/assets_hd.zip" | cut -d' ' -f1)
  if [ "$have" != "$want" ]; then
    echo "The download is damaged (SHA-256 mismatch); please try again." >&2
    exit 1
  fi
fi
mkdir -p "$tmp/out" && unzip -q "$tmp/assets_hd.zip" -d "$tmp/out" || exit 1
mv "$tmp/out" game/assets_hd || exit 1
echo "HD graphics pack installed: $(find game/assets_hd -name '*.webp' | wc -l | tr -d ' ') images"
