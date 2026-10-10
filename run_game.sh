#!/bin/bash
# Run the game from source with Godot 4.7 (brew install --cask godot). Arguments go to Godot (e.g. --headless).
# Needs the converted game data in game/assets (README.md; docs/BUILDING.md, "Re-generating the game data"). Godot's
# import cache (game/.godot) is (re)built when it is missing or older than a script, since without it the scripts'
# class names are not registered.
cd "$(dirname "$0")" || exit 1
if [ ! -f game/assets/data/exe_image.bin ] || [ ! -d game/assets/scripts ]; then
  echo "No converted game data in game/assets. Put the original game at orig/ and convert it" >&2
  echo "(README.md; docs/BUILDING.md, \"Re-generating the game data\")." >&2
  exit 1
fi
cd game || exit 1
cache=.godot/global_script_class_cache.cfg
if [ ! -f "$cache" ] || [ -n "$(find src -name '*.gd' -newer "$cache" | head -1)" ]; then
  echo "Importing the project (takes a minute the first time)…"
  godot --headless --path . --import || exit 1
  touch "$cache"
fi
exec godot --path . "$@"
