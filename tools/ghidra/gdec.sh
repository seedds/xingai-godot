#!/bin/bash
# Decompile Ekd5.exe (the 6.6 engine) functions with Ghidra headless. usage: gdec.sh OUTFILE ADDR [ADDR...]
# First run imports + auto-analyses the exe into a project (slow, once).
export JAVA_HOME=${JAVA_HOME_21:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
GH=${GHIDRA_INSTALL_DIR:-/opt/homebrew/Cellar/ghidra/12.1.4/libexec}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJ=${GDEC_PROJ:-$ROOT/extract/ghidra_proj}   # a copy per parallel user (Ghidra locks the project)
EXE=$ROOT/orig/Ekd5.exe
SP=$ROOT/tools/ghidra
mkdir -p "$PROJ"
OUT=$1; shift
if [ ! -d "$PROJ/ekd5.rep" ]; then
  "$GH/support/analyzeHeadless" "$PROJ" ekd5 -import "$EXE" -processor x86:LE:32:default -cspec windows \
     -scriptPath "$SP" -postScript Decompile.java "$OUT" "$@" > "$PROJ/import.log" 2>&1
else
  "$GH/support/analyzeHeadless" "$PROJ" ekd5 -process Ekd5.exe -noanalysis -readOnly \
     -scriptPath "$SP" -postScript Decompile.java "$OUT" "$@" > "$PROJ/last.log" 2>&1
fi
tail -3 "$PROJ"/*.log | grep -i -E "error|exception" | head -5
