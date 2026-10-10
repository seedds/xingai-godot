"""Effects category of the 6.6-engine graphics converter (run through tools/conv_gfx.py --only effects).

Sources (orig/E5/): Meff.e5 + DT.e5 (Ls12 archives of KoeiAnim animations), Mcall00-22.e5 (one KoeiAnim each),
Hitarea.e5 / Effarea.e5 / Tr.e5 (64x64 PNG diagrams), Weather.e5 (216x200 raw 8-bit panels), Gate.e5 (144x144
JPEG map patches); Ekd5.exe strategy tables MgMeff (VA 0x4d1960) / MgMcall (VA 0x4d19f0) / MgID (VA 0x4d1570).

Output under <out>/effects/ (see docs/gfx.md "Effects and animations"):
  xben/NN/img_KK.png (+alpha_KK.png)   Meff.e5 entry NN
  dt/NN/img_KK.png (+alpha_KK.png)     DT.e5 entry NN (battle-map / scene animated objects)
  mcall/NN/img_KK.png (+alpha_KK.png)  Mcall%02d.e5
  ranges/attack/NN.png                 Hitarea.e5 (reach diagrams)
  ranges/strategy/NN.png               Effarea.e5 (effect-area diagrams)
  tr/NN.png                            Tr.e5 (RPG-scene picture objects)
  weather/N.png                        Weather.e5
  map_patches/NNN.jpg                  Gate.e5 (JPEG bytes as stored)
  index.json
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import io, os, struct, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import gfx66_common as g
from e5 import kind, open_image

ANIM_KEY_TOL = 12          # the animation loaders pass mode 0x0c to the decoder 0x40e770 -> 0x4033dc tolerance 12
EXE_MEFF = 0xA3160         # MgMeff  file offset (VA 0x4d1960), 144 bytes
EXE_MCALL = 0xA31F0        # MgMcall file offset (VA 0x4d19f0), 144 bytes
EXE_MGID = 0xA2D70         # MgID    file offset (VA 0x4d1570), 144 bytes (strategy category)
CAT12_UNIT_CODES = 0x4785c6  # VA: 8 unit effect codes ...
CAT12_MEFF = 0x4785ce        # VA: ... and the Meff entry played for each (0x4216c0)


# ----------------------------------------------------------------------------- KoeiAnim
def parse_anim(b):
    """KoeiAnim bytes -> dict(header fields, records, frames (list of HxWx3 uint8), alphas, png_alpha)."""
    nr, ni, na, hp, delay, W, H, idw = struct.unpack('<4B4I', b[:20])
    recs = []
    for i in range(nr):
        img, layer, p2, p3, mode, dx, dy, cue = struct.unpack('<4BIiiI', b[20 + 20 * i:40 + 20 * i])
        recs.append({'image': img, 'layer': None if layer == 0xff else layer, 'p2': p2, 'p3': p3,
                     'mode': mode, 'dx': dx, 'dy': dy, 'cue': cue & 0xff})
    data = b[20 + 20 * nr:]
    k = kind(data)
    frames, alphas, png_alpha = [], [], None
    if k in ('bmp', 'png'):
        im = open_image(data)
        a = np.array(im.convert('RGBA'))
        rgb = a[..., :3]
        if k == 'png' and im.mode in ('RGBA', 'LA', 'P'):
            png_alpha = a[..., 3]
        n = ni + na
        for f in range(n):
            blk = rgb[f * H:(f + 1) * H]
            if blk.shape[0] < H:
                blk = np.vstack([blk, np.zeros((H - blk.shape[0], W, 3), np.uint8)])
            (frames if f < ni else alphas).append(blk)
        storage = 'bmp24' if k == 'bmp' else 'png'
    else:
        pal = np.array(g.palette(), np.uint8)
        fs = W * H
        for f in range(ni):
            idx = np.frombuffer(data[f * fs:(f + 1) * fs].ljust(fs, b'\0'), np.uint8).reshape(H, W)
            frames.append(pal[idx])
        for f in range(na):
            o = (ni + f) * fs
            alphas.append(np.frombuffer(data[o:o + fs].ljust(fs, b'\0'), np.uint8).reshape(H, W))
        storage = 'raw8'
    return {'n_rec': nr, 'n_img': ni, 'n_alpha': na, 'has_pal': hp, 'delay': delay, 'W': W, 'H': H,
            'id': idw, 'records': recs, 'frames': frames, 'alphas': alphas, 'png_alpha': png_alpha,
            'storage': storage}


def write_anim(a, d, is_mcall):
    """Write img_KK.png (+alpha_KK.png) for one parsed animation; returns its index entry."""
    W, H = a['W'], a['H']
    # per-pixel alpha path: word at header +0x12 == 0x2001, i.e. byte 18 == 1 and the data is a 32-bit PNG
    # (Mcall: 0x4055fa tests obj+0x2e; Meff: 0x40e905 tests obj+2 = n_alpha byte + PNG flag)
    if is_mcall:
        flag_byte = (a['id'] >> 16) & 0xff
    else:
        flag_byte = a['n_alpha']
    per_pixel = flag_byte == 1 and a['storage'] == 'png' and a['png_alpha'] is not None
    os.makedirs(d, exist_ok=True)
    for k, fr in enumerate(a['frames']):
        rgba = np.zeros((H, W, 4), np.uint8)
        rgba[..., :3] = fr
        if per_pixel:
            rgba[..., 3] = a['png_alpha'][k * H:(k + 1) * H]
        else:
            rgba[..., 3] = 255
        hit = g.key_hits(fr, tol=ANIM_KEY_TOL)
        rgba[hit] = 0
        g.save_png(Image.fromarray(rgba, 'RGBA'), '%s/img_%02d.png' % (d, k))
    for k, al in enumerate(a['alphas']):
        if al.ndim == 3:
            al = al[..., 0]
        g.save_png(Image.fromarray(np.ascontiguousarray(al), 'L'), '%s/alpha_%02d.png' % (d, k))
    recs = []
    for r in a['records']:
        r = dict(r)
        if per_pixel:
            op = 1.0
        elif is_mcall and r['mode'] == 0 and r['p2'] == 0:
            op = 1.0                                   # 0x402b83: plain keyed copy
        else:
            op = min((r['p3'] * 6 + 4) / 100.0, 1.0)  # 0x40690c level = p3*6+4 (percent)
        r['opacity'] = round(op, 2)
        recs.append(r)
    return {'size': [W, H], 'delay_ms': a['delay'] // 50 * 50, 'id': a['id'] & 0xffff,
            'sound': a['id'] & 0xff, 'images': len(a['frames']), 'alphas': len(a['alphas']),
            'own_palette': bool(a['has_pal']), 'storage': a['storage'],
            'alpha_source': 'png' if per_pixel else 'key', 'records': recs}


def anim_archive(arc_rel, outdir, label):
    A = g.arc(arc_rel)
    anims = {}
    for i in range(len(A)):
        a = parse_anim(A[i])
        e = write_anim(a, '%s/%02d' % (outdir, i), False)
        e['source'] = '%s[%d]' % (label, i)
        anims['%02d' % i] = e
    return anims


# ----------------------------------------------------------------------------- simple pictures
def png_dir(arc_rel, outdir, keyed):
    A = g.arc(arc_rel)
    files = []
    for i in range(len(A)):
        im = g.open_image(A[i])
        out = g.keyed(im) if keyed else im.convert('RGB')
        f = '%02d.png' % i
        g.save_png(out, '%s/%s' % (outdir, f))
        files.append(f)
    return files


def conv_weather(outdir):
    A = g.arc('E5/Weather.e5')
    files = []
    for i in range(len(A)):
        im = g.raw8(A[i], 216, 200, key=True)
        f = '%d.png' % i
        g.save_png(im, '%s/%s' % (outdir, f))
        files.append('weather/' + f)
    return files


def conv_gate(outdir):
    A = g.arc('E5/Gate.e5')
    patches = []
    for i in range(len(A)):
        b = A[i]
        assert kind(b) == 'jpg', i
        f = '%03d.jpg' % i
        g.save_jpg(b, '%s/%s' % (outdir, f))
        a = np.array(g.open_image(b).convert('RGB'))
        hit = g.key_hits(a)
        e = {'entry': i, 'file': 'map_patches/' + f, 'size': [a.shape[1], a.shape[0]],
             'patch_code': i // 2 + 4, 'state': 'changed' if i % 2 == 0 else 'original'}
        if hit.any():
            cells = [[int(hit[r * 48:(r + 1) * 48, c * 48:(c + 1) * 48].mean() > 0.5) for c in range(3)]
                     for r in range(3)]
            e['key_cells'] = cells
        patches.append(e)
    return patches


# ----------------------------------------------------------------------------- strategy tables
def strategy_tables():
    with open(g.EXE, 'rb') as f:
        d = f.read()
    meff = list(d[EXE_MEFF:EXE_MEFF + 144])
    mcall = list(d[EXE_MCALL:EXE_MCALL + 144])
    cat = list(d[EXE_MGID:EXE_MGID + 144])
    # VA -> file offset for the .code section (VA 0x401000 = file 0x400)
    codes = list(d[CAT12_UNIT_CODES - 0x401000 + 0x400:][:8])
    effs = list(d[CAT12_MEFF - 0x401000 + 0x400:][:8])
    return meff, mcall, cat, codes, effs


# ----------------------------------------------------------------------------- main
def convert(out):
    root = g.ensure(out + 'effects')
    idx = {
        'anim_format': {
            'format': 'KoeiAnim: header u8 n_rec, u8 n_img, u8 n_alpha, u8 has_pal, u32 delay_ms, u32 W, u32 H, '
                      'u32 id; n_rec x 20-byte records; then the pictures: raw 8-bit (n_img then n_alpha WxH '
                      'planes, exe palette), or one BMP24 / PNG of W x H*(n_img+n_alpha) (frames stacked)',
            'record': {'image': 'frame index (img_KK)', 'layer': 'byte 1 (always 0xff = null here)',
                       'p2': 'byte 2 (Mcall: p2 != 0 forces the blended path)',
                       'p3': 'byte 3: blend level L = p3*6+4 percent (0x4055fa / 0x402396 -> 0x40690c)',
                       'mode': 'u32 +4 (Mcall: mode != 0 forces the blended path)',
                       'dx': 'i32 +8: x offset added to the frame position', 'dy': 'i32 +12: y offset',
                       'cue': 'byte +16: 1 = Meff hit frame (0x401e5d -> 0x421ab6 shows the targets hurt/'
                              'defend pose + numbers); sound: plays on frame 0 unless cue == 2, and on every '
                              'frame with cue == 3 (0x41c4ef / 0x403206)',
                       'opacity': 'precomputed: what the 6.6 player draws: '
                                  'bg*(1-o) + img*o for every non-key pixel'},
            'playback': 'one record per tick; delay_ms is rounded down to the 50 ms timer tick (0x40273f/0x40bd5d '
                        'divide by 50, 0x42c632 waits ticks of timeGetTime()/50). Frame top-left = '
                        '(x - W/2 + dx, y - H/2 + dy) where (x, y) = target cell centre (cell pos + 24) '
                        '(Meff 0x40196f/0x401a7c + 0x40208b, Mcall 0x421496 + 0x402b83)',
            'blend': '24-bit: key pixels (|c-(247,0,255)| < 12 per channel, alpha 0 in img_KK.png) are skipped; '
                     'others: out = (bg*(100-L) + img*L) / 100 per channel, L = p3*6+4 (0x40690c, 0x415a64). '
                     'Mcall records with mode == 0 and p2 == 0 are plain keyed copies (0x402b83). '
                     'alpha_source "png": per-pixel alpha from the PNG instead of L (header byte 18 == 1 and a '
                     '32-bit PNG: Mcall 0x4055fa, Meff 0x40e905). The 8-bit alpha maps (alpha_KK.png) are decoded '
                     'but not used by the 6.6 player.',
            'sound': 'sound = low byte of the header id; the player calls 0x46d0b7(sound + 100)',
        },
        'see_also': 'ui/index.json describes effects/items32, kao, qusi',
    }

    meff, mcall, cat, codes, effs = strategy_tables()
    idx['strategy_effect_table'] = {
        'source': 'Ekd5.exe MgMeff (VA 0x4d1960, file 0xA3160) and MgMcall (VA 0x4d19f0, file 0xA31F0), '
                  '144 strategies (System.ini MgMeff/MgMcall); category = MgID (VA 0x4d1570)',
        'rule': '0x421496: c = mcall[s]; if c == 255: nothing. If 100 <= c < 255: play Mcall(c % 100) '
                '(0x40eb54 -> 0x4060a9 -> 0x40eae0 "E5\\MCALL%02u.E5") centred on the target cell centre (on '
                'the map view centre for categories 0x1c/0x1d), then (category 12 only) 0x4216c0 plays '
                'category12_multi. Then (any c != 255) e = meff[s]; if e != 255: play Meff[e] on every target '
                'cell (0x40bcd2 + 0x40196f + 0x401e5d)',
        'meff': meff, 'mcall': mcall, 'category': cat,
        'category12_multi': {'source': '0x4216c0 (tables VA 0x4785c6 / 0x4785ce)',
                             'unit_effect_codes': codes, 'meff': effs,
                             'rule': 'for each pair: Meff[meff[i]] on the targets whose effect byte (+0x401) '
                                     '== unit_effect_codes[i]'},
    }

    # Meff -> xben, DT -> dt
    idx['xben'] = {'source': 'Meff.e5 (Ls12, 60 KoeiAnim; 57 identical to wg2025 Xben.wa, 31 changed, 58/59 new), loader 0x40bcd2 -> 0x4318e5',
                   'dir': 'xben/NN/',
                   'notes': 'entries 52..56 = 216x50 weather banners (0x449f91 plays 0x34 + weather at (108,25)); '
                            'entry 45 fixed use at 0x423b94/0x42b7e5',
                   'anims': anim_archive('E5/Meff.e5', root + '/xben', 'Meff.e5')}
    idx['dt'] = {'source': 'DT.e5 (Ls12, 60 KoeiAnim): loaded through the Meff loader with the file name patched '
                           'to DT.E5 (0x40da9a writes 0xfa/0xb7 into 0x40bd21/0x40bd34: name 0x48bbfa, 16-bit '
                           'index) for the 40 animated object slots of script handler 0x4295fb (slot = arg 0, '
                           'object word +0x12 = DT entry + 1; 0 removes it)',
                 'dir': 'dt/NN/',
                 'notes': 'entries 7..59 are byte-identical to Meff.e5; 0..6 are new single pictures with an '
                          'embedded BMP24',
                 'anims': anim_archive('E5/DT.e5', root + '/dt', 'DT.e5')}

    # Mcall
    m = {}
    for n in range(23):
        p = g.ORIG + 'E5/Mcall%02d.e5' % n
        if not os.path.exists(p):
            continue
        with open(p, 'rb') as f:
            a = parse_anim(f.read())
        e = write_anim(a, '%s/mcall/%02d' % (root, n), True)
        e['source'] = 'Mcall%02d.e5' % n
        m['%02d' % n] = e
    idx['mcall'] = {'source': 'E5/Mcall00..22.e5 (raw KoeiAnim files), opened by 0x40eae0 '
                              '(sprintf "E5\\MCALL%02u.E5", v % 100) -> 0x402a24 (player object 0x492788, '
                              'stream thread 0x41295c: header 0x40273f, pictures 0x4027c9/0x4025a7); play 0x403035, '
                              'frame draw 0x402b83',
                    'dir': 'mcall/NN/', 'anims': m,
                    'notes': 'referenced by the shipped MgMcall table: 00-08 and 11. Mcall12 has a PNG but '
                             'header byte 18 == 0, so the engine ignores its alpha (keyed RGB at level L, as '
                             'converted). 0x40eab4 can also open "E5\\MCALL%03u.E5" (3 digits, number = the '
                             'unit\'s person word); no such files ship.'}

    # diagrams
    idx['ranges_attack'] = {
        'source': 'Hitarea.e5 (33 x 64x64 PNG, opaque)', 'size': [64, 64],
        'files': ['ranges/attack/' + f for f in png_dir('E5/Hitarea.e5', root + '/ranges/attack', False)],
        'role': 'reach diagrams (which cells can be targeted), loader 0x46fc61 (mode 0, no key). Unit info '
                '0x477b7f: index = class record byte +1 (attack range type), window slot 5. Strategy info '
                '0x46fa82: index = strategy record byte +0x0c (0xff -> 16; an index >= the entry count reads '
                'entry 0, 0x41fc89), or 11 when record byte +0x0f == 0x28'}
    idx['ranges_strategy'] = {
        'source': 'Effarea.e5 (10 x 64x64 PNG; alpha 225..255 ignored by the engine -> saved opaque)',
        'size': [64, 64],
        'files': ['ranges/strategy/' + f for f in png_dir('E5/Effarea.e5', root + '/ranges/strategy', False)],
        'role': 'effect-area diagrams (cells hit around the target), loader 0x46fc61. Unit info: index = '
                '0x407835(person) (attack area type), slot 6. Strategy info: index = strategy byte +0x0d & 0x0f '
                '(0xff -> 16 -> entry 0); 0 when record byte +0x0f == 0x28, or when the dialog flag (+0x50 -> '
                '+0x74) is 0 and MgID[s] == 0x1a'}
    trf = png_dir('E5/Tr.e5', root + '/tr', True)
    idx['tr'] = {'source': 'Tr.e5 (11 x 64x64 PNG; 0..9 identical to Effarea.e5)', 'size': [64, 64],
                 'files': ['tr/' + f for f in trf],
                 'role': 'RPG-scene picture objects: script handler 0x425bf2 puts Tr entry (actor word +0x3a) into '
                         'actor slot 0x6a + arg0 (arg0 < 8); 0x42789d loads it (mode 10 = keyed, one frame of '
                         'W x H). Slots >= 0x72 load U_SELECT.E5 the same way with 10 frames of H/10 '
                         '(0x42a049)'}
    idx['weather'] = {'source': 'Weather.e5 (5 x 216x200 raw 8-bit, exe palette; = rea Xthree.wa), loader '
                                '0x449ef0 (mode 10)',
                      'files': conv_weather(g.ensure(root + '/weather')),
                      'layout': '216x200 = 4 animation frames of 216x50 stacked vertically',
                      'rule': 'entry = weather = table VA 0x48e100[climate*6 + level] (0x41553b); on a change '
                              '0x449f91 plays Meff[0x34 + weather] at (108, 25) then reloads the panel',
                      'role': 'battle weather panel: 0 clear, 1 cloudy, 2 rain, 3 heavy rain, 4 snow'}
    idx['map_patches'] = {
        'source': 'Gate.e5: 192 JPEG 144x144 (3x3 cells), copied byte for byte',
        'role': 'battle-map terrain-change patches. 0x4376ea loads the entry (mode 10) and cuts it into 48x48 '
                'cells (0x473d4a); 0x437779 copies each cell into the map picture centred on the target cell, '
                'skipping cells outside the map (and darkens it for night/fog via 0x42a8ed). No palette any more.',
        'rule': 'patch code v (4..200, stored in the change record +4, table VA 0x4b3d21, 250 x 5 bytes): '
                'apply = entry 2*v - 8 (0x4563ff, reload 0x456e7c), restore = entry 2*v - 7 (0x4567dd). '
                'v < 4 or v > 200 are small marks, not Gate pictures',
        'key_cells': 'entries listing key_cells contain colour-key (247,0,255) cells (1 = keyed 48x48 cell); '
                     'the engine copies them unkeyed, so they must lie outside the map when used',
        'patches': conv_gate(g.ensure(root + '/map_patches'))}

    g.write_index(out, 'effects', idx)
    return {'xben': len(idx['xben']['anims']), 'dt': len(idx['dt']['anims']), 'mcall': len(m),
            'ranges_attack': len(idx['ranges_attack']['files']),
            'ranges_strategy': len(idx['ranges_strategy']['files']), 'tr': len(trf),
            'weather': len(idx['weather']['files']), 'map_patches': len(idx['map_patches']['patches'])}


CATEGORIES = {'effects': convert}
