#!/bin/bash
# Long autoplay flow test with autosave/retry. usage: flowtest.sh [seconds] [stop_scenario]
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/game" || exit 1
LOG=$ROOT/extract/flow.log
SLOT=${WG_AUTOSLOT:-19}     # not one of the player's save slots 0-9
SAVE="$HOME/Library/Application Support/Godot/app_userdata/新改曹操傳/save_$SLOT.json"
if [ -f "$SAVE" ] && [ "$FRESH" = "" ]; then START="WG_LOADSLOT=$SLOT"; else START="WG_START=0"; fi
env $START WG_AUTOSLOT=$SLOT WG_AUTOSAVE=1 WG_RANDOM=1 WG_CHOOSE_AVOID=${WG_CHOOSE_AVOID:-夢幻關卡,外傳,思過崖,兵種大對決,歪傳,跳關} WG_GOD=1 WG_AUTO=1 WG_STOP=${2:-999} WG_NOVIDEO=1 perl -e "alarm ${1:-3000}; exec @ARGV" godot --headless --path . 2>&1 \
  | grep --line-buffered -E "== |chapter|WARNING|ERROR|SCRIPT" >> "$LOG"
