#!/bin/bash
# Watch flow-test logs (args: log names in extract/): print skips/errors as they happen, and STALL when a log is silent > 300 s.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/extract" || exit 1
FILES=("$@")
[ ${#FILES[@]} -eq 0 ] && FILES=(flow_trace.log flow_par_32.log flow_par_62.log flow_par_80.log)
for f in "${FILES[@]}"; do
  (tail -n0 -F "$f" 2>/dev/null | awk -v n="$f" '/^== flow-test/ {print n": "$0; fflush()} /SCRIPT ERROR|^ERROR|Resumed|Invalid/ && !/Case mismatch/ {print n": "$0; fflush()}') &
done
warned=()
while true; do
  sleep 60
  now=$(date +%s)
  for i in "${!FILES[@]}"; do
    f=${FILES[$i]}
    m=$(stat -f %m "$f" 2>/dev/null || echo "$now")
    if [ $((now - m)) -gt 300 ]; then
      if [ -z "${warned[$i]}" ]; then
        echo "$f: STALL no output for $((now - m))s; last: $(grep -E '^== scenario' "$f" | tail -1)"
        warned[$i]=1
      fi
    else
      warned[$i]=""
    fi
  done
done
