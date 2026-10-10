"""Story / RPG scene graphics.

  rpg_sprites  Pmapobj.e5 (922 = 461 characters x front/back, 48x1280 = 20 frames of 48x64)
               -> gfx/rpg_sprites/NNN.png (960x256 sheet, row = direction code) + index.json
  backgrounds  Mmap.e5 (852 x 640x400, BMP24 or JPEG) -> gfx/backgrounds/NNN.(png|jpg)
               Pmap.e5 (812 scene grids)              -> gfx/backgrounds/buha/NNN.png + index.json
See docs/gfx.md §5.
"""
import os as _os
import struct, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import gfx66_common as g

R_TABLE_VA, R_TABLE_FILE = 0x50f800, 0xE1000      # u16 x 1024 per-person story sprite (System.ini RFileHead)
FW, FH, NF = 48, 64, 20


def r_table():
    with open(g.EXE, 'rb') as f:
        f.seek(R_TABLE_FILE)
        return list(struct.unpack('<1024H', f.read(2048)))


def pmapobj_entry(b):
    """One 48x1280 strip as RGBA. Returns (image, note)."""
    k = g.kind(b)
    if k == 'raw' and len(b) >= 54 + FW * FH * NF * 3 and not any(b[:20]):
        # BMP whose 54-byte header is wiped (zeros, entry 552 has a few stray bytes): the decoder 0x40e770 takes
        # it for raw 8-bit pixels (garbage on screen); the payload is a normal bottom-up 24-bit BMP, decoded here.
        a = np.frombuffer(b[54:54 + FW * FH * NF * 3], np.uint8).reshape(FH * NF, FW, 3)[::-1, :, ::-1]
        return g.keyed(Image.fromarray(a.copy(), 'RGB')), 'zeroed BMP header (engine shows garbage)'
    return g.decode(b, FW, FH * NF, key=True), None


def conv_rpg(out):
    A = g.arc('Pmapobj.e5')
    d = g.ensure(out + 'rpg_sprites')
    n = len(A) // 2
    notes = {}
    kinds = {}
    for c in range(n):
        front, nf = pmapobj_entry(A[2 * c])
        back, nb = pmapobj_entry(A[2 * c + 1])
        for e, note in ((2 * c, nf), (2 * c + 1, nb)):
            if note:
                notes[str(e)] = note
        for e in (2 * c, 2 * c + 1):
            kinds.setdefault(g.kind(A[e]), []).append(e)
        sheet = Image.new('RGBA', (FW * NF, FH * 4), (0, 0, 0, 0))
        rows = [back, front.transpose(Image.FLIP_LEFT_RIGHT), front, back.transpose(Image.FLIP_LEFT_RIGHT)]
        for dcode, strip in enumerate(rows):
            for f in range(NF):
                sheet.paste(strip.crop((0, f * FH, FW, (f + 1) * FH)), (f * FW, dcode * FH))
        g.save_png(sheet, '%s/%03d.png' % (d, c))
    rt = r_table()
    idx = {
        'source': 'Pmapobj.e5 (Ls12, 922 entries): character c uses entries 2c (front view, facing down-left) and '
                  '2c+1 (back view, facing up-right); each 48x1280 = 20 frames of 48x64. Mixed storage: 24-bit BMP, '
                  'raw 8-bit in the exe palette (61440 B, some +2), one JPEG (entry 710), 8 BMPs with a zeroed header',
        'count': n,
        'file_pattern': '%03d.png',
        'frame_w': FW, 'frame_h': FH, 'frames_per_direction': NF,
        'layout': 'sheet 960x256: row = direction code d (0..3), column = frame 0..19',
        'directions': {
            '0': 'up-right / NE: entry 2c+1', '1': 'down-right / SE: mirror of entry 2c',
            '2': 'down-left / SW: entry 2c', '3': 'up-left / NW: mirror of entry 2c+1',
            'evidence': 'cache loader 0x426c6a(c, slot) reads entries 2c+1 and 2c (mode 10, 0x2d000 bytes each) and '
                        'mirrors them with 0x40d38c(48, 1280): slot = [2c+1 | mirror(2c) | 2c | mirror(2c+1)], '
                        'the same order as CCZ; frame address inside the slot not re-verified for the 6.6 engine'},
        'frames': {'0': 'stand', '1': 'walk A', '2': 'walk B', '3..19': 'action poses (character specific)'},
        'transparency': 'colour key (247,0,255) within <10 per channel -> alpha 0',
        'sprite_id_rule': {
            'actors': 'actor of person pid: c = u16 R_table[pid] (0x409038: [0x50f800 + 2*pid]); actor creation '
                      '0x428c8e -> 0x426d61(pid, c) -> cache 0x426a4a / loader 0x426c6a',
            'scene_objects': '0x427426: Pmap grid cells whose low byte != 0xff create an actor with c = low byte '
                             '(no shipped Pmap entry has any)',
            'r_table_set': 'script op 0x411f2d writes R_table[arg] (with the save state block 0x501000..0x531000)',
            'r_table_initial': {'va': '0x50f800', 'file_offset': '0xE1000', 'values': rt},
        },
        'notes': notes,
        'storage_kinds': {k: len(v) for k, v in kinds.items()},
    }
    g.write_index(out, 'rpg_sprites', idx)
    return {'characters': n, 'zeroed_header_entries': len(notes)}


def conv_backgrounds(out):
    A = g.arc('E5/Mmap.e5')
    d = g.ensure(out + 'backgrounds')
    images = []
    for i in range(len(A)):
        b = A[i]
        k = g.kind(b)
        name = g.save_entry(b, '%s/%03d' % (d, i), key=False)
        im = g.open_image(b)
        a = np.asarray(im.convert('L'))
        images.append({'entry': i, 'file': name, 'format': 'jpg' if k == 'jpg' else 'png',
                       'size': list(im.size), 'blank': bool(a.max() == a.min())})
    P = g.arc('E5/Pmap.e5')
    masks = []
    for i in range(len(P)):
        b = P[i]
        hdr = list(struct.unpack('<8H', b[:16]))
        grid = np.frombuffer(b[16:16 + 20000], np.uint8).reshape(100, 200)
        g.save_png(Image.fromarray(grid.copy(), 'L'), '%s/buha/%03d.png' % (d, i))
        masks.append({'entry': i, 'file': 'buha/%03d.png' % i, 'header_words': hdr[:7],
                      'extra_word_14': hdr[7]})
    idx = {
        'source': 'Mmap.e5 (Ls12, %d entries, 640x400; BMP24 -> NNN.png, JPEG -> NNN.jpg copied unchanged); '
                  'archive object 0x4ac640 opened by 0x42be51' % len(A),
        'scene_lookup': {
            'loader': '0x40bbaf (scene struct 0x4ac63c: byte kind, byte image)',
            'rule': 'entry = image + 256*dword[0x505eec] + (40 if kind == 2 else 0); decoded with mode 0 (no colour '
                    'key); kind 2 then re-orders the picture into 8x8 tiles (0x473d4a(buf, 0x3250, tmp, 8)) for the '
                    'scene compositor - storage itself is always plain rows',
            'cache': 'dword 0x48bae0[kind] = last entry',
            'script_op': '0x413d13 (5 args a0..a4): a0 = kind; kind 0: image = a1 (0xffff -> 0); kind 1: image = '
                         '114 if a2 == 0, else a1, or a3 + 40 when a1 == 0xffff (a3 == 0xffff -> 114); kind 2: image '
                         '= a3 (0xffff -> 0); kind 3 (battle map): image 0xff, battle map = a4 (0xffff -> 99) + '
                         '100*byte[0x505f4c] -> word 0x510cfe; then 0x428346(kind, image) stores the image BYTE',
            'bank': 'dword 0x505eec: picture bank, only read here (set through script memory writes)',
        },
        'images': images,
        'buha': {
            'source': 'Pmap.e5 (Ls12, %d entries of 20016 bytes); entry = image + 256*dword[0x505eec] (no kind '
                      'offset), loader 0x425dcd -> buffer 0x401669' % len(P),
            'format': 'header 16 bytes = 8 LE words [scene id, X=100, Y=100, Z=1, W=200, 100, 1, ?]; then a '
                      'u16 grid [Z][Y][X] (0x4268ba: offset 0x10 + 2*((X*Y)*z + X*y + x)); cell low byte = object '
                      'sprite id (0xff none, 0x427426), high byte 0xff / 0xf0 (walk / occlusion flags, semantics as '
                      'wg2025 Buha). Exported as 200x100 greyscale = the raw bytes (lo, hi per cell), same as rea',
            'masks': masks},
    }
    g.write_index(out, 'backgrounds', idx)
    return {'backgrounds': len(images), 'jpg': sum(1 for x in images if x['format'] == 'jpg'),
            'masks': len(masks)}


CATEGORIES = {'rpg_sprites': conv_rpg, 'backgrounds': conv_backgrounds}
