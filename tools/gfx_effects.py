"""Effects / animations / battle UI pieces.

  MCALL00-08.wa (raw "KoeiAnim" files)     -> <out>/effects/mcall/NN/  (frames + alpha) + index
  Xben.wa (58 KoeiAnim entries, =Meff.e5)  -> <out>/effects/xben/NN/
  Jiqi.wa / Drink.wa  range diagrams       -> <out>/effects/ranges/{attack,strategy}/NN.png
  Xthree.wa weather backdrops              -> <out>/effects/weather/N.png (4 frames 216x50 each)
  Nima.wa 3x3-cell battle map patches      -> <out>/effects/map_patches/NNN.png (+ idx/ index PNGs)
  Yoyo.wa 32x32 item pictures              -> <out>/effects/items32/NNN.png
  Qusi.wa misc UI pieces                   -> <out>/effects/qusi/NN.png
  Kao.wa battle/UI atlas                   -> <out>/effects/kao/<offset>_<w>x<h>.png
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import struct, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import gfxcommon as g
import gfxpal

# strategy id -> effect (wagan.wa table 0x4866c0, 68 entries): <100 Xben entry, >=100 MCALL(v-100), 255 none
STRATEGY_EFFECT = [0, 1, 0, 100, 57, 2, 3, 2, 101, 3, 4, 5, 4, 102, 4, 6, 7, 6, 103, 8, 31, 24, 32, 20, 20, 21, 21,
                   18, 18, 19, 19, 25, 25, 23, 23, 26, 26, 27, 104, 9, 10, 9, 10, 10, 11, 12, 28, 28, 30, 15, 15,
                   16, 16, 13, 13, 14, 14, 29, 255, 255, 255, 13, 31, 17, 106, 105, 107, 108]


def parse_anim(d):
    nr, ni, na, hp = d[:4]
    delay, w, h, ident = struct.unpack('<4I', d[4:20])
    recs = []
    for r in range(nr):
        b = d[20 + r * 20: 40 + r * 20]
        recs.append({'image': b[0], 'layer': None if b[1] == 0xff else b[1], 'p2': b[2], 'p3': b[3],
                     'mode': struct.unpack('<I', b[4:8])[0]})
    base = 20 + nr * 20
    imgs = [d[base + k * w * h: base + (k + 1) * w * h] for k in range(ni)]
    base += ni * w * h
    alphas = [d[base + k * w * h: base + (k + 1) * w * h] for k in range(na)]
    base += na * w * h
    pal = d[base:base + 768] if hp else None
    return {'w': w, 'h': h, 'delay_ms': delay, 'id': ident, 'records': recs, 'images': imgs, 'alphas': alphas,
            'palette': pal}


def export_anim(a, d, pal):
    g.ensure(d)
    if a['palette']:
        pal = gfxpal.decode_palette(a['palette'])
    w, h = a['w'], a['h']
    for k, im in enumerate(a['images']):
        g.save_png(g.indexed_to_rgba(im, w, h, pal, 0), '%s/img_%02d.png' % (d, k))
    for k, al in enumerate(a['alphas']):
        Image.frombytes('L', (w, h), al).save('%s/alpha_%02d.png' % (d, k))
    return {'size': [w, h], 'delay_ms': a['delay_ms'], 'id': a['id'], 'images': len(a['images']),
            'alphas': len(a['alphas']), 'own_palette': a['palette'] is not None, 'records': a['records']}


ANIM_DOC = {
    'format': 'header u8 n_rec,u8 n_img,u8 n_alpha,u8 has_pal,u32 delay_ms,u32 W,u32 H,u32 id; n_rec x 20-byte '
              'records; n_img WxH 8bpp images; n_alpha WxH 8-bit alpha maps; 768-byte palette if has_pal '
              '(4-bit, B,R,G order)',
    'playback': 'one record per tick of delay_ms (0x403014 waits [obj+0x20]); frame centred on the target '
                'point (x-W/2, y-H/2) (0x402cb5)',
    'record': {'image': 'index into img_NN', 'layer': 'extra layer select (<40) or null (0xff)',
               'mode 1': 'alpha-map blend: alpha image = p2, strength = p3 (0..16) (0x430369 -> 0x4300c8)',
               'mode 0': 'weighted blend: background weight p2, image weight p3 (0..16) via the RGB444 LUT '
                         '(0x43030e -> 0x42fd5a); p2 == 0 -> plain copy of non-zero pixels; (16,16) ~ additive'},
    'pixels': 'image index 0 = transparent (background shows through)'}


def conv_anims(out, quantize):
    pal = g.sprite_palette(quantize)
    res = {'mcall': {}, 'xben': {}}
    for n in range(9):
        a = parse_anim(open(g.GAME + 'Mcall%02d.wa' % n, 'rb').read())
        res['mcall']['%02d' % n] = export_anim(a, out + 'effects/mcall/%02d' % n, pal)
    for n, e in enumerate(g.archive('Xben.wa')):
        a = parse_anim(e)
        res['xben']['%02d' % n] = export_anim(a, out + 'effects/xben/%02d' % n, pal)
    return res


def conv_misc(out, quantize):
    pal = gfxpal.load('DeDe.WA', 0, quantize)
    idx = {}
    # range diagrams
    for name, key in (('Jiqi.wa', 'attack'), ('Drink.wa', 'strategy')):
        files = []
        for i, e in enumerate(g.archive(name)):
            f = 'ranges/%s/%02d.png' % (key, i)
            g.save_png(g.indexed_to_rgba(e, 64, 64, pal, None), out + 'effects/' + f)
            files.append(f)
        idx['ranges_' + key] = {'source': name, 'size': [64, 64], 'files': files}
    idx['ranges_attack']['role'] = 'attack-range diagrams (8x8 grid of 8px cells, blue = unit, red = reach); ' \
                                   'loaders 0x46fcb4/0x478164; index = class attack-range type (data.wa)'
    idx['ranges_strategy']['role'] = 'strategy effect-area diagrams (red = target, green = area); loader ' \
                                     '0x46fdda; index = strategy area type (data.wa)'
    # weather
    files = []
    for i, e in enumerate(g.archive('Xthree.wa')):
        f = 'weather/%d.png' % i
        g.save_png(g.indexed_to_rgba(e, 216, 200, pal, None), out + 'effects/' + f)
        files.append(f)
    idx['weather'] = {'source': 'Xthree.wa (loader 0x449f27 -> Kao buffer +0x1c8e0)', 'files': files,
                      'layout': '216x200 = 4 animation frames of 216x50 stacked vertically',
                      'role': 'battle weather panel: 0 clear, 1 cloudy, 2 rain, 3 heavy rain, 4 snow'}
    # map patches
    files = []
    for i, e in enumerate(g.archive('Nima.wa')):
        raw = g.untile(e[:20736], 3, 3, 48, 48)
        g.ensure(out + 'effects/map_patches/idx')
        Image.frombytes('L', (144, 144), raw).save(out + 'effects/map_patches/idx/%03d.png' % i)
        # preview with the best-fitting Fei palette
        a = np.frombuffer(raw, np.uint8).reshape(144, 144)
        best = None
        for m in range(58):
            P = np.array(gfxpal.load('Fei.WA', m), np.int32)[a]
            s = np.abs(np.diff(P, axis=0)).mean() + np.abs(np.diff(P, axis=1)).mean()
            if best is None or s < best[0]:
                best = (s, m)
        f = 'map_patches/%03d.png' % i
        g.save_png(g.indexed_to_rgba(raw, 144, 144, gfxpal.load('Fei.WA', best[1], quantize), None).convert('RGB'),
                   out + 'effects/' + f)
        files.append({'file': f, 'index_png': 'map_patches/idx/%03d.png' % i, 'palette_guess': 'fei[%d]' % best[1]})
    idx['map_patches'] = {'source': 'Nima.wa: 186 entries, 3x3 cells of 48x48 stored cell after cell (like HM)',
                          'role': 'battle-map change overlays (gates, walls, bridges, fire...) drawn when a cell '
                                  'terrain changes (0x456140 writes the terrain grid then redraws); palette = the '
                                  'current map Fei palette, so idx/*.png keep raw palette indices (grey value = '
                                  'index) and the RGB preview uses the best-fitting map palette (heuristic)',
                          'patches': files}
    # Yoyo item pictures
    files = []
    for i, e in enumerate(g.archive('Yoyo.wa')):
        f = 'items32/%03d.png' % i
        g.save_png(g.indexed_to_rgba(e, 32, 32, pal, 0), out + 'effects/' + f)
        files.append(f)
    idx['items32'] = {'source': 'Yoyo.wa (8bpp 32x32, index 0 transparent)', 'files': files,
                      'role': 'item pictures drawn by the game itself (same artwork as ItemIcon.dll large icons)'}
    # Qusi
    Q = g.archive('Qusi.wa')
    qd = {0: (50, 50), 1: (50, 50), 2: (50, 50), 9: (50, 50), 10: (50, 50), 11: (50, 50), 3: (400, 296),
          4: (400, 128), 5: (576, 72), 6: (576, 72), 7: (576, 72), 8: (576, 72)}
    files = []
    for i, e in enumerate(Q):
        if i in qd:
            w, h = qd[i]
            raw = e
        else:   # 2-byte header + data
            raw = e[2:]
            w = 48
            h = len(raw) // 48
        f = 'qusi/%02d.png' % i
        g.save_png(g.indexed_to_rgba(raw, w, h, pal, 0 if w <= 50 else None), out + 'effects/' + f)
        files.append({'file': f, 'size': [w, h], 'header': e[:2].hex() if i not in qd else None})
    idx['qusi'] = {'source': 'Qusi.wa (loaders 0x45ec2b, 0x4db3f0)', 'files': files,
                   'role': '0-2/9-11 small buttons, 3 400x296 and 4 400x128 blue dragon-pattern window '
                           'backgrounds, 5-8 576x72 sea/shore panorama strips, 12-14 48-wide pieces with a '
                           '2-byte header (sizes guessed)'}
    # Kao atlas
    kao = open(g.GAME + 'Kao.wa', 'rb').read()
    regions = [(0x0, 8, 8, 6, 'colour bars / window pieces'), (0x180, 24, 24, 5, '24x24 icons (heart, feather, '
               'scroll, speech bubbles)'), (0xcc0, 48, 48, 43, '48x48 battle cursors, terrain overlays, fire, '
               'tents (some items in this run are not 48x48)'), (0x18dc0, 48, 48, 1, '48x48 tile'),
               (0x196c0, 16, 16, 4, '16x16 marks'), (0x19ac0, 64, 16, 2, '64x16 bars'),
               (0x1a2c0, 16, 16, 9, '16x16 status icons'), (0x1abc0, 48, 48, 1, 'emblem (GHAI 48x48 loaded '
               'here at runtime by 0x40b006)'), (0x1b4c0, 18, 8, 35, '18x8 pieces')]
    files = []
    for off, w, h, n, role in regions:
        for k in range(n):
            o = off + k * w * h
            if o + w * h > len(kao):
                break
            f = 'kao/%05x_%dx%d.png' % (o, w, h)
            g.save_png(g.indexed_to_rgba(kao[o:o + w * h], w, h, pal, 0), out + 'effects/' + f)
            files.append({'file': f, 'offset': o, 'size': [w, h], 'role': role})
    idx['kao'] = {'source': 'Kao.wa: raw 116960-byte UI atlas read whole into buffer 0x4aeb50 (0x42ba29); '
                            'sprites addressed by fixed byte offsets (push off / 0x47fa40) with sizes from the '
                            'blit calls; region table partly inferred', 'pieces': files}
    return idx


def convert(out_root=g.OUT, quantize=False):
    anims = conv_anims(out_root, quantize)
    misc = conv_misc(out_root, quantize)
    g.write_index('effects', {
        'anim_format': ANIM_DOC,
        'strategy_effect_table': {'source': 'wagan.wa 0x4866c0 (strategy id -> effect)',
                                  'rule': 'v < 100: Xben entry v; 100 <= v < 200: MCALL(v-100) (0x4217fe uses '
                                          'v % 100) played full-screen; 255: none. For MCALL strategies 0x4215f0 '
                                          'also remaps the follow-up Xben effect via a jump table (values 1,3,5,7,'
                                          '0x16,0x39,0x0a or none)',
                                  'values': STRATEGY_EFFECT},
        'mcall': {'source': 'MCALL00..08.wa', 'dir': 'mcall/NN/', 'anims': anims['mcall']},
        'xben': {'source': 'Xben.wa (Ls12, 58 entries; = CCZ Meff.e5)', 'dir': 'xben/NN/',
                 'notes': 'entries 52..56 = 216x50 animated weather panels (0x44a121 loads entry 0x34 + weather id; static versions in Xthree.wa)', 'anims': anims['xben']},
        **misc})
    return {'mcall': len(anims['mcall']), 'xben': len(anims['xben'])}


if __name__ == '__main__':
    print(convert())
