#!/bin/bash
# Build game/assets/data/skills.json (spec: docs/skills.md): the 特效 and item-effect catalogue read from Ekd5.exe,
# the (sid, eid, mode, a4) query pairs found in the code (tools/skills66/sites.json, extra_queries.json: results
# of the call-site analysis) and the 必杀 records. Needs tools/conv_data.py's output first.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
D=tools/skills66
T=$(mktemp -d)
cp $D/sites.json $D/extra_queries.json "$T/"
tools/venv/bin/python -I $D/base_data.py "$T" &&
tools/venv/bin/python -I $D/bisha_json.py "$T/bisha.json" &&
tools/venv/bin/python -I $D/gen_json.py "$T" game/assets/data/skills.json
rc=$?
rm -r "$T"
exit $rc
