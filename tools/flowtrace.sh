#!/bin/bash
# Like flowtest.sh but with section/text tracing into extract/flow_trace.log. usage: flowtrace.sh [seconds] [stop]
# Continues from the autosave slot WG_AUTOSLOT (default 19; never one of the player's slots 0-9) if it exists, else
# (or with FRESH=1) starts a new game.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/game" || exit 1
LOG=$ROOT/extract/flow_trace.log
SLOT=${WG_AUTOSLOT:-19}
SAVE="$HOME/Library/Application Support/Godot/app_userdata/新改曹操傳/save_$SLOT.json"
if [ -f "$SAVE" ] && [ "$FRESH" = "" ]; then START="WG_LOADSLOT=$SLOT"; else START="WG_START=0"; fi
env $START WG_AUTOSLOT=$SLOT WG_TRACE_SEC=1 WG_TRACE_TEXT=1 WG_AUTOSAVE=1 WG_RANDOM=1 WG_CHOOSE_AVOID=${WG_CHOOSE_AVOID:-夢幻關卡,外傳,思過崖,兵種大對決,歪傳,跳關} WG_GOD=1 WG_AUTO=1 WG_STOP=${2:-999} WG_NOVIDEO=1 \
  perl -e "alarm ${1:-3000}; exec @ARGV" godot --headless --path . 2>&1 | grep --line-buffered -v "Case mismatch\|open_internal\|^$\|^\s*\[[0-9]*\] \|GDScript backtrace" >> "$LOG"
