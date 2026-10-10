#!/bin/bash
# Run the game from source with Godot 4.7 (brew install --cask godot).
# First run: download the HD graphics pack (game/assets_hd; without it the original art is used). Godot's import
# cache (game/.godot) is (re)built when it is missing or older than a script, since without it the scripts' class
# names are not registered.
cd "$(dirname "$0")" || exit 1
if [ ! -d game/assets_hd/gfx ]; then
  tools/get_hd_pack.sh || echo "Could not download the HD graphics pack; using the original art."
fi
cd game || exit 1
cache=.godot/global_script_class_cache.cfg
if [ ! -f "$cache" ] || [ -n "$(find src -name '*.gd' -newer "$cache" | head -1)" ]; then
  echo "Importing the project (takes a minute the first time)…"
  godot --headless --path . --import || exit 1
  touch "$cache"
fi
exec godot --path . "$@"
