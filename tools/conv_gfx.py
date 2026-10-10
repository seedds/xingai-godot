"""Convert every graphic of 新改曹操傳 6.6 (6.6 engine, Ekd5.exe) to PNG/JPEG + JSON indexes.

usage: tools/venv/bin/python -I tools/conv_gfx.py [--only cat1,cat2,...] [--out DIR] [--list]

Reads the original game under orig/ (read only) and writes game/assets/gfx/<category>/ with an index.json
per category. The work is done by the tools/gfx66_*.py modules; each exposes CATEGORIES = {name: fn(out)},
fn returning a small summary dict. See docs/gfx.md for the formats, the exe code and the JSON schemas.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import argparse, importlib, json, os, sys, time
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import gfx66_common as g

# conversion order = the order categories run in when no --only is given
MODULES = ['gfx66_units', 'gfx66_story', 'gfx66_maps', 'gfx66_portraits', 'gfx66_screens', 'gfx66_effects',
           'gfx66_ui']


def categories():
    cats = {}
    for name in MODULES:
        try:
            m = importlib.import_module(name)
        except ImportError as ex:
            print('module %s not available (%s)' % (name, ex))
            continue
        for k, fn in m.CATEGORIES.items():
            cats[k] = fn
    return cats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only', default='', help='comma list of categories (see --list)')
    ap.add_argument('--out', default=g.OUT)
    ap.add_argument('--list', action='store_true')
    a = ap.parse_args()
    out = a.out if a.out.endswith('/') else a.out + '/'
    cats = categories()
    if a.list:
        print(' '.join(cats))
        return
    only = [c for c in a.only.split(',') if c]
    bad = [c for c in only if c not in cats]
    if bad:
        sys.exit('unknown categories: %s (have: %s)' % (', '.join(bad), ', '.join(cats)))
    sp = out + 'summary.json'
    try:
        summary = json.load(open(sp))
    except (OSError, ValueError):
        summary = {}
    for k, fn in cats.items():
        if only and k not in only:
            continue
        t = time.time()
        summary[k] = fn(out)
        print('%-12s done in %5.1fs  %s' % (k, time.time() - t, json.dumps(summary[k], ensure_ascii=False)[:200]),
              flush=True)
    g.ensure(out)
    json.dump(summary, open(sp, 'w'), ensure_ascii=False, indent=1, default=str)


if __name__ == '__main__':
    main()
