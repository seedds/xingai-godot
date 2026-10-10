#!/bin/bash
# Convert WMV cutscenes to Ogg Theora/Vorbis for Godot. Numbered/END files have byte 0 zeroed (0x30 -> 0x00).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FF=$(brew --prefix ffmpeg-full)/bin/ffmpeg
SRC=$ROOT/wg2025
DST=$ROOT/game/assets/video
for f in "$SRC"/*.wmv; do
  b=$(basename "$f" .wmv | tr 'A-Z' 'a-z')
  [ -f "$DST/$b.ogv" ] && continue
  (printf '\x30'; tail -c +2 "$f") | $FF -hide_banner -loglevel error -y -i pipe:0 \
     -vf "scale='min(1280,iw)':-2" -c:v libtheora -q:v 6 -c:a libvorbis -q:a 4 "$DST/$b.ogv" && echo "ok $b"
done
