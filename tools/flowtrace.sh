#!/bin/bash
# Like flowtest.sh but with section/text tracing into extract/flow_trace.log
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/game" || exit 1
LOG=$ROOT/extract/flow_trace.log
env WG_LOADSLOT=9 WG_TRACE_SEC=1 WG_TRACE_TEXT=1 WG_AUTOSAVE=1 WG_RANDOM=1 WG_GOD=1 WG_AUTO=1 WG_STOP=${2:-200} WG_NOVIDEO=1 \
  perl -e "alarm ${1:-3000}; exec @ARGV" godot --headless --path . 2>&1 | grep --line-buffered -v "Case mismatch\|open_internal\|^$\|^\s*\[[0-9]*\] \|GDScript backtrace" >> "$LOG"
