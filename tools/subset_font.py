#!/usr/bin/env python3
"""Cut a Song (serif) font down to the characters the game shows, for platforms without one (iOS has only PingFang).

    tools/venv/bin/pip install fonttools
    tools/venv/bin/python -I tools/subset_font.py NotoSerifSC-Regular.otf

Input: Noto Serif SC (SIL OFL 1.1), e.g. Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf from github.com/notofonts/noto-cjk.
Output: game/assets/fonts/NotoSerifSC-game.otf (+ .import marked keep). Characters come from the scripts, the data
tables and the GDScript sources, plus ASCII and the common punctuation blocks. Re-run after the text changes;
anything missing still shows through the system-font fallback (Assets.font()).
"""
import json
import pathlib
import sys

from fontTools import subset

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "game/assets/fonts/NotoSerifSC-game.otf"


def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield k
            yield from strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from strings(x)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    used = set()
    for d in ["game/assets/scripts", "game/assets/data", "game/assets/gfx"]:
        for p in (ROOT / d).rglob("*.json"):
            for s in strings(json.loads(p.read_text(encoding="utf-8"))):
                used.update(s)
    for p in (ROOT / "game/src").rglob("*.gd"):
        used.update(p.read_text(encoding="utf-8"))
    used = {c for c in used if c.isprintable() or c == "　"}
    chars = used | set(chr(c) for c in range(0x20, 0x7F))
    for lo, hi in [(0x2010, 0x2027), (0x25A0, 0x25FF), (0x3000, 0x303F), (0xFF01, 0xFF5E)]:
        chars.update(chr(c) for c in range(lo, hi + 1))
    opts = subset.Options()
    opts.name_IDs = ["*"]
    opts.name_languages = ["*"]
    opts.notdef_outline = True
    opts.layout_features = ["*"]
    font = subset.load_font(sys.argv[1], opts)
    sub = subset.Subsetter(opts)
    sub.populate(text="".join(sorted(chars)))
    sub.subset(font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(OUT), opts)
    OUT.with_suffix(".otf.import").write_text('[remap]\n\nimporter="keep"\n')
    have = set(chr(c) for c in font.getBestCmap())
    missing = sorted(c for c in used if c not in have and ord(c) > 0x7F)
    print(f"{len(used)} characters in the game, {len(have)} in {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")
    if missing:
        print(f"{len(missing)} not in the font (shown by the fallback): {''.join(missing[:80])}")


if __name__ == "__main__":
    main()
