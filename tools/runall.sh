#!/bin/bash
# Run every story file (or a list of scenario numbers) once, headless with autoplay, and collect the warnings and
# errors: tools/runall.sh [OUTDIR] [n ...]   (n = scenario number; default all R files).  Per-file logs in OUTDIR.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=${1:-/tmp/runall}; shift
mkdir -p "$OUT"
cd "$ROOT/game" || exit 1
if [ $# -eq 0 ]; then
  set -- $(ls assets/scripts/R_*.json | sed 's/.*R_0*\([0-9]*\)\.json/\1/' | sed 's/^$/0/' | awk '{print $1*2}')
fi
JOBS=${JOBS:-6}
run() {
  n=$1
  WG_START=$n WG_AUTO=1 WG_NOVIDEO=1 WG_ONEFILE=1 WG_OPSTATS=1 perl -e "alarm ${TMO:-240}; exec @ARGV" \
    godot --headless --path . > "$OUT/$n.log" 2>&1
  echo "rc=$?" >> "$OUT/$n.log"
}
export -f run; export OUT TMO
printf '%s\n' "$@" | xargs -P "$JOBS" -n 1 bash -c 'run "$0"'
grep -h 'EEX unimplemented\|SCRIPT ERROR\|^ERROR\|Parse Error\|Invalid\|rc=1[0-9][0-9]' "$OUT"/*.log | sort | uniq -c | sort -rn | head -80
echo "files: $(ls "$OUT"/*.log | wc -l)  done: $(grep -l '== file done' "$OUT"/*.log | wc -l)"
