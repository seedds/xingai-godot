#!/bin/bash
# Convert the AVI cutscenes (Cinepak 320x240, PCM audio) to Ogg Theora/Vorbis for Godot: video/<name>.ogv.
# The engine names Logo.Avi, Open.Avi, End.Avi, Press.Avi and Mov%03u.Avi (strings in Ekd5.exe); the game ships
# Logo, Open and END (end2.avi is not referenced). usage: conv_video.sh [GAME_DIR]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF=$(brew --prefix ffmpeg-full)/bin/ffmpeg
SRC=${1:-$ROOT/orig}
DST=$ROOT/game/assets/video
mkdir -p "$DST"
for f in "$SRC"/*.[aA][vV][iI]; do
  b=$(basename "$f" | sed 's/\.[aA][vV][iI]$//' | tr 'A-Z' 'a-z')
  case "$b" in logo|open|end|press|mov[0-9][0-9][0-9]) ;; *) continue ;; esac
  [ -f "$DST/$b.ogv" ] && continue
  $FF -hide_banner -loglevel error -y -i "$f" -c:v libtheora -q:v 8 -c:a libvorbis -q:a 4 "$DST/$b.ogv" && echo "ok $b"
done
