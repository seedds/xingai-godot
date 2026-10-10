"""Convert every wagan (CCZ-engine) graphics asset to PNG + JSON indexes.

usage: tools/venv/bin/python -I tools/conv_gfx.py [--quantize] [--only maps,icons,...] [--out DIR]

Categories produced here: maps, palettes, terrain, icons, ui.
Categories produced by sub-modules (if present): units (gfx_units), portraits (gfx_portraits),
rpg_sprites/backgrounds/screens (gfx_story), effects (gfx_effects).
See docs/gfx.md for formats and the JSON schemas.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import argparse, importlib, json, os, sys, time
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import gfxcommon as g
import gfxpal
import dllbmp

N_MAPS = 58  # HM00..HM57 (Yun.wa has a 59th entry without a bitmap)


# ----------------------------------------------------------------------------- palettes
def conv_palettes(out, quantize=False):
    res = {'format': 'each palette = 256 "#rrggbb" strings (already converted from the stored B,R,G order; '
                     'indices 0-9/246-255 = Windows static colours)',
           'quantized_to_4bit': quantize, 'files': {}}
    for name, key in (('Fei.WA', 'fei'), ('Niuqun.wa', 'niuqun'), ('DeDe.WA', 'dede')):
        pals = []
        for raw in g.archive(name):
            pals.append(['#%02x%02x%02x' % c for c in gfxpal.decode_palette(raw, quantize)])
        p = os.path.join(g.ensure(out + 'palettes'), key + '.json')
        json.dump(pals, open(p, 'w'))
        res['files'][key] = {'file': key + '.json', 'source': name, 'count': len(pals)}
    res['files']['fei']['role'] = 'battle map palettes: fei[N] for HMnn.wa / Xixi[N]'
    res['files']['niuqun']['role'] = 'story background palettes: niuqun[N] for Giji.WA[N]'
    res['files']['dede']['role'] = 'misc palettes (0,2: 246-colour game palettes; 1: 6x6x6 cube; 3: grey ramp)'
    res['shared_range'] = [10, 173]
    res['background_range'] = [174, 245]
    g.write_index('palettes', res)
    return {'palettes': sum(v['count'] for v in res['files'].values())}


# ----------------------------------------------------------------------------- maps
def map_dims(yun_entry):
    return yun_entry[0] // 3, yun_entry[1] // 3


def conv_maps(out, quantize=False):
    Y = g.archive('Yun.wa')
    X = g.archive('Xixi.wa')
    d = g.ensure(out + 'maps')
    g.ensure(d + '/minimap')
    maps = []
    for i in range(len(Y)):
        W, H = map_dims(Y[i])
        terrain = list(Y[i][2:2 + W * H])
        ent = {'id': i, 'width': W, 'height': H, 'cell': 48,
               'terrain': [terrain[r * W:(r + 1) * W] for r in range(H)]}
        hm = g.GAME + 'HM%02d.wa' % i
        if os.path.exists(hm):
            pal = gfxpal.load('Fei.WA', i, quantize)
            raw = open(hm, 'rb').read()
            need = W * H * 48 * 48
            raw = raw[:need] + bytes(max(0, need - len(raw)))
            im = g.indexed_to_rgba(g.untile(raw, W, H, 48, 48), W * 48, H * 48, pal, key=None).convert('RGB')
            g.save_png(im, '%s/HM%02d.png' % (d, i))
            ent.update({'image': 'HM%02d.png' % i, 'pixel_size': [W * 48, H * 48], 'palette': 'fei[%d]' % i,
                        'source': 'HM%02d.wa' % i})
            if i < len(X):
                mraw = X[i] + bytes(max(0, W * H * 36 - len(X[i])))
                mim = g.indexed_to_rgba(mraw, W * 6, H * 6, pal, key=None).convert('RGB')
                g.save_png(mim, '%s/minimap/HM%02d.png' % (d, i))
                ent['minimap'] = 'minimap/HM%02d.png' % i
                ent['minimap_cell'] = 6
        else:
            ent['image'] = None
            ent['note'] = 'Yun.wa entry without HM bitmap (unused / placeholder)'
        maps.append(ent)
    g.write_index('maps', {
        'format': 'terrain[row][col] = terrain type id (0..28) per 48x48 cell; see terrain/index.json',
        'source': 'Yun.wa (=CCZ Hexzmap.e5) + HMnn.wa (cell-tiled 8bpp) + Xixi.wa (minimap) + Fei.WA palettes',
        'maps': maps})
    return {'maps': sum(1 for m in maps if m.get('image'))}


# ----------------------------------------------------------------------------- DLL bitmaps
def dll_images(name):
    out = {}
    for rid, raw in dllbmp.bitmaps(g.GAME + name):
        im = dllbmp.to_image(raw)
        im.load()
        out[rid] = im
    return out


def keyed(im, key_index=0):
    """8-bit DIB -> RGBA with palette index `key_index` transparent (ImageList mask rule 0x40a58a)."""
    if im.mode != 'P':
        return im.convert('RGBA')
    a = np.array(im)
    rgba = np.array(im.convert('RGBA'))
    if key_index is not None:
        rgba[a == key_index, 3] = 0
    return Image.fromarray(rgba, 'RGBA')


TERRAIN_NAMES_GUESS = ['平原', '草原', '树林', '荒地', '山地', '岩山', '山崖', '雪原', '桥梁', '浅滩', '沼泽', '池塘',
                       '小河', '大河', '栅栏', '城墙', '城内', '城门', '城池', '关隘', '鹿砦', '村庄', '兵营', '民居',
                       '宝物库', '?', '火', '?']


def conv_terrain(out, quantize=False):
    ims = dll_images('Mapatr.dll')
    d = g.ensure(out + 'terrain')
    tiles = []
    for rid in sorted(ims):
        t = rid - 100
        g.save_png(ims[rid].convert('RGB'), '%s/%02d.png' % (d, t))
        tiles.append({'terrain': t, 'file': '%02d.png' % t, 'size': list(ims[rid].size), 'resource_id': rid,
                      'name_guess': TERRAIN_NAMES_GUESS[t] if t < len(TERRAIN_NAMES_GUESS) else None})
    g.write_index('terrain', {'source': 'Mapatr.dll RT_BITMAP 100+terrain (loaded into an ImageList at 0x46c675)',
                              'note': 'terrain-info picture shown for a cell; names are CCZ defaults, the data '
                                      'agent has the authoritative names in data.wa',
                              'tiles': tiles})
    return {'terrain': len(tiles)}


def conv_icons(out, quantize=False):
    d = g.ensure(out + 'icons')
    idx = {'rule': 'bitmap id = 100 + 2*i + size (size 0 = 16x16, 1 = 32x32); ImageList builder 0x40b19e; '
                   'palette index 0 is the transparency key (mask built by 0x40a58a)', 'sets': {}}
    for dll, key, count in (('Itemicon.dll', 'items', 105), ('Mgcicon.dll', 'strategies', 31)):
        ims = dll_images(dll)
        ents = []
        for i in range(count):
            e = {'id': i}
            for size, sz in ((0, 'small'), (1, 'large')):
                rid = 100 + 2 * i + size
                if rid in ims:
                    f = '%s/%s/%03d.png' % (key, sz, i)
                    g.save_png(keyed(ims[rid]), d + '/' + f)
                    e[sz] = f
            ents.append(e)
        idx['sets'][key] = {'source': dll, 'count': count, 'icons': ents}
    ims = dll_images('Cmdicon.dll')
    ents = []
    for rid in sorted(ims):
        f = 'commands/%03d.png' % (rid - 100)
        g.save_png(keyed(ims[rid]), d + '/' + f)
        ents.append({'id': rid - 100, 'file': f, 'size': list(ims[rid].size)})
    idx['sets']['commands'] = {'source': 'Cmdicon.dll (16x16, ids 100..104)', 'count': len(ents), 'icons': ents}
    g.write_index('icons', idx)
    return {'icons': sum(s['count'] for s in idx['sets'].values())}


def conv_ui(out, quantize=False):
    d = g.ensure(out + 'ui')
    items = []
    groups = (('wagan.wa', 'exe', 'main exe RT_BITMAP: 106/302 = 12-button toolbar strips (24px), '
                                  '341-344 = 48x48 pictures, 350/351 = 16x16'),
              ('mark.wa', 'mark', 'resource DLL loaded by mod code (LoadImage wrapper 0x4d4144): ids 2/3 = 8x80 '
                                  'message-window side pieces, 5 = 24x24 speech mark'),
              ('XRes.dll', 'xres', 'launcher (wg.exe) skin: window buttons, title bar, 400x120 dialog'))
    for dll, key, desc in groups:
        ims = dll_images(dll)
        for rid in sorted(ims, key=lambda r: (str(type(r)), r)):
            im = ims[rid]
            f = '%s/%s.png' % (key, rid)
            # Koei originals use palette index 0 = (247,0,255) as colour key
            pal0 = tuple(im.getpalette()[:3]) if im.mode == 'P' else None
            out_im = keyed(im) if pal0 == (247, 0, 255) else im.convert('RGBA')
            g.save_png(out_im, d + '/' + f)
            items.append({'source': dll, 'resource_id': rid, 'file': f, 'size': list(im.size),
                          'keyed_index0': pal0 == (247, 0, 255)})
        items.append({'group': key, 'description': desc})
    g.write_index('ui', {'items': items})
    return {'ui': sum(1 for x in items if 'file' in x)}


LOCAL = {'palettes': conv_palettes, 'maps': conv_maps, 'terrain': conv_terrain, 'icons': conv_icons,
         'ui': conv_ui}
MODULES = {'units': 'gfx_units', 'portraits': 'gfx_portraits', 'story': 'gfx_story', 'effects': 'gfx_effects'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--quantize', action='store_true', help='reproduce the game\'s 4-bit/channel palette')
    ap.add_argument('--only', default='', help='comma list of: ' + ','.join(list(LOCAL) + list(MODULES)))
    ap.add_argument('--out', default=g.OUT)
    a = ap.parse_args()
    out = a.out if a.out.endswith('/') else a.out + '/'
    only = set(filter(None, a.only.split(',')))
    summary = {}
    for k, fn in LOCAL.items():
        if only and k not in only:
            continue
        t = time.time()
        summary.update(fn(out, a.quantize))
        print('%-10s done in %.1fs' % (k, time.time() - t), flush=True)
    for k, mod in MODULES.items():
        if only and k not in only:
            continue
        try:
            m = importlib.import_module(mod)
        except ImportError as ex:
            print('%-10s skipped (%s)' % (k, ex))
            continue
        t = time.time()
        r = m.convert(out, a.quantize)
        summary[k] = r
        print('%-10s done in %.1fs' % (k, time.time() - t), flush=True)
    json.dump(summary, open(out + 'summary.json', 'w'), ensure_ascii=False, indent=1, default=str)
    print(json.dumps(summary, ensure_ascii=False, default=str)[:2000])


if __name__ == '__main__':
    main()
