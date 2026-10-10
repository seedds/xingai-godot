"""Story / RPG-scene graphics and full-screen pictures.

  yueyue.wa (Ls12 at +0x500) -> <out>/rpg_sprites/NNN.png   (480 characters, 4 directions x 20 frames 48x64)
  Giji.WA + Niuqun.wa        -> <out>/backgrounds/NNN.png   (337 640x400 scene pictures)
  Buha.wa                    -> <out>/backgrounds/buha/NNN.png (200x100 scene masks, raw values)
  GHAI.WA (+DeDe palettes)   -> <out>/screens/NN.png        (title, logos, game over, battle backdrops ...)
See docs/gfx.md sections 5/6.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
import gfxcommon as g
import gfxpal

FW, FH, NF = 48, 64, 20


# ----------------------------------------------------------------------------- RPG actors
def conv_rpg(out, quantize):
    pal = g.sprite_palette(quantize)
    Y = g.archive('yueyue.wa')
    d = g.ensure(out + 'rpg_sprites')
    n = len(Y) // 2
    for i in range(n):
        front = g.indexed_to_rgba(Y[2 * i], FW, FH * NF, pal, 0)      # entry 2i   : facing down-left (SW)
        back = g.indexed_to_rgba(Y[2 * i + 1], FW, FH * NF, pal, 0)   # entry 2i+1 : facing up-left (NW)
        quarters = [back, front.transpose(Image.FLIP_LEFT_RIGHT), front, back.transpose(Image.FLIP_LEFT_RIGHT)]
        sheet = Image.new('RGBA', (FW * NF, FH * 4), (0, 0, 0, 0))
        for row, q in enumerate(quarters):
            for f in range(NF):
                fr = q.crop((0, f * FH, FW, (f + 1) * FH))
                sheet.paste(fr, (f * FW, row * FH))
        g.save_png(sheet, '%s/%03d.png' % (d, i))
    g.write_index('rpg_sprites', {
        'source': 'yueyue.wa (Ls12 archive hidden at file offset 0x500); character id c uses entries 2c '
                  '(front view) and 2c+1 (back view), each 48x1280 = 20 frames of 48x64, index 0 transparent',
        'count': n, 'file_pattern': '%03d.png', 'frame_w': FW, 'frame_h': FH, 'frames_per_direction': NF,
        'layout': 'sheet 960x256: row = direction code d (0..3), column = frame 0..19',
        'directions': {'0': 'up-right / NE (-Y): entry 2c+1',
                       '1': 'down-right / SE (+X): mirror of entry 2c',
                       '2': 'down-left / SW (+Y): entry 2c',
                       '3': 'up-left / NW (-X): mirror of entry 2c+1',
                       'evidence': 'loader 0x426c6a builds a 0x3c000 slot [2c+1 | mirror(2c) | 2c | mirror(2c+1)]; '
                                   'frame ptr 0x42b010 = slot + (dir*20 + frame)*0xC00 (dir = actor+0x2e, '
                                   'frame = actor+0x2a); walk steps set dir to the step code (0x42a4f5), whose '
                                   'deltas are dx@0x48b8c0 = (0,1,0,-1), dy@0x48b8b0 = (-1,0,1,0)'},
        'frames': {'0': 'stand', '1': 'walk A', '2': 'walk B',
                   '3..19': 'action poses (common: 3 kneel, 4/5 raise arm, 6 hand to head/sweat, 8 bow, '
                            '12 lying/fallen; later frames are character specific)'},
        'anchor': 'actor screen point (sx, sy) is the bottom-left of the 48x64 frame: blit at (sx, sy-64) '
                  '(0x42a2c4)',
        'coordinates': {
            'actor fields': 'X = word +4, Y = word +6, Z = word +8 (0x42aa20/0x42add0/0x42adf0)',
            'transform 0x4272c5': 'sx = 8*(X - Y) + 4*W - 8 - 8*camX ; sy = 4*(X + Y) - 8*Z - 8*camY + 8',
            'W': 'word at Buha entry offset 8 (= 200 in every entry)',
            'cam': 'camX/camY = words 0x49ceb4/0x49ceb6 (scroll, in 8px units)',
            'screen': 'the 640x400 scene view is drawn at y = 40 (0x427b2b adds 0x28 to sy)',
            'units': 'isometric half-cells: +1 X -> (+8,+4) px, +1 Y -> (-8,+4) px, +1 Z -> -8 px'},
        'loader': 'actor create 0x426db2(person?, sprite_id) -> cache slot 0x426c6a(sprite_id, slot); '
                  'sprite id comes straight from the S-script command'})
    return n


# ----------------------------------------------------------------------------- backgrounds
ROWS = set(range(40)) | {114}     # stored row-major; every other Giji entry is stored as 8x8 tiles


def conv_backgrounds(out, quantize):
    G = g.archive('Giji.WA')
    d = g.ensure(out + 'backgrounds')
    ents = []
    for i, e in enumerate(G):
        raw = e[:256000]
        storage = 'rows' if i in ROWS else 'tiles8'
        if storage == 'tiles8':
            raw = g.untile(raw, 80, 50, 8, 8)
        im = g.indexed_to_rgba(raw, 640, 400, gfxpal.load('Niuqun.wa', i, quantize), key=None).convert('RGB')
        g.save_png(im, '%s/%03d.png' % (d, i))
        kind = 0 if i < 40 else 2 if i < 114 else 1
        ents.append({'entry': i, 'file': '%03d.png' % i, 'palette': 'niuqun[%d]' % i, 'storage': storage,
                     'scene_kind': kind, 'scene_image': i - {0: 0, 2: 40, 1: 114}[kind],
                     'blank': len(set(raw)) <= 1})
    # Buha: per-scene 200x100 byte masks
    B = g.archive('Buha.wa')
    bd = g.ensure(d + '/buha')
    bents = []
    for i, e in enumerate(B):
        hdr = [int.from_bytes(e[k:k + 2], 'little') for k in range(0, 14, 2)]
        mask = e[16:16 + 20000]
        Image.frombytes('L', (200, 100), mask).save('%s/%03d.png' % (bd, i))
        bents.append({'entry': i, 'file': 'buha/%03d.png' % i, 'header_words': hdr,
                      'extra_bytes_14_15': e[14:16].hex()})
    g.write_index('backgrounds', {
        'source': 'Giji.WA (337 x 640x400 8bpp) with palette Niuqun.wa[same index]; loader 0x40bc37',
        'scene_lookup': 'scene struct 0x4ac63c: byte kind, word image (set by the S-script scene op). '
                        'Giji entry = image + {kind 0: 0, kind 2: 40, kind 1: 114}; palette Niuqun[entry] '
                        '(0x40bd98); drawn at (0, 40) 640x400 (0x40bdbc)',
        'storage': 'entries 0..39 and 114 are plain rows; all others are 8x8 tiles in row-major tile order '
                   '(80x50 tiles) - converted to plain images here',
        'images': ents,
        'buha': {'source': 'Buha.wa entry = scene image id (word 0x4ac63d, loader 0x428857, buffer 0x4aeb38)',
                 'format': '14-byte header (7 LE words: [id, 100, 100, 1, 200, 100, 1]) + 2 bytes + 200x100 '
                           'bytes; values 0xFF / 0xF0 (scene walk/occlusion mask - semantics unverified); '
                           'word@8 (=200) is the W used by the actor screen transform',
                 'masks': bents}})
    return len(ents)


# ----------------------------------------------------------------------------- GHAI screens
GHAI_DIMS = {256002: (640, 400), 256000: (640, 400), 239616: (624, 384), 239618: (624, 384),
             307200: (640, 480), 2304: (48, 48), 4096: (64, 64)}
GHAI_INFO = {
    0: ('title screen (default)', 0), 13: ('title screen variant', 0), 14: ('title screen variant', 0),
    15: ('title screen variant', 0),
    6: ('Koei Tecmo / 轩辕 credits logo (0x42b6fa: DeDe[1])', 1),
    7: ('GAME OVER screen (0x42c12f: DeDe[2])', 2),
    12: ('轩辕学院 splash, heavily dithered (0x42bc8f: DeDe[3])', 3),
    1: ('64x64 emblem (red bird)', 0), 2: ('64x64 emblem (yellow bird)', 0), 3: ('64x64 emblem (blue bird)', 0),
    4: ('grey battle illustration 640x400', 0), 5: ('grey stone-relief backdrop 624x384', 0),
    8: ('48x48 tile', 0), 9: ('48x48 tile', 0), 10: ('48x48 tile', 0), 11: ('48x48 tile', 0),
    16: ('624x384 backdrop: army camp', 0), 17: ('624x384 backdrop: field', 0), 18: ('624x384 backdrop: night', 0),
    19: ('624x384 backdrop: market', 0), 20: ('624x384 backdrop: fog', 0), 21: ('624x384 backdrop: plain', 0)}


def conv_screens(out, quantize):
    G = g.archive('GHAI.WA')
    d = g.ensure(out + 'screens')
    ents = []
    for i, e in enumerate(G):
        w, h = GHAI_DIMS[len(e)]
        role, pal_i = GHAI_INFO.get(i, ('?', 0))
        im = g.indexed_to_rgba(e, w, h, gfxpal.load('DeDe.WA', pal_i, quantize), key=None).convert('RGB')
        g.save_png(im, '%s/%02d.png' % (d, i))
        ents.append({'entry': i, 'file': '%02d.png' % i, 'size': [w, h], 'palette': 'dede[%d]' % pal_i,
                     'role': role})
    g.write_index('screens', {
        'source': 'GHAI.WA (Ls12); palettes from DeDe.WA (0x41e050(i, 2)); entries using only indices <174 '
                  'render identically with any game palette',
        'notes': 'title loader 0x42bd90 picks entry 0 or 13..15 (0x41a284(0)+0xc, save-progress dependent); '
                 'entry 6 via 0x42b6f6, 12 via 0x42bc8f, 7 via 0x42c12f',
        'screens': ents})
    return len(ents)


def convert(out_root=g.OUT, quantize=False):
    return {'rpg_sprites': conv_rpg(out_root, quantize),
            'backgrounds': conv_backgrounds(out_root, quantize),
            'screens': conv_screens(out_root, quantize)}


if __name__ == '__main__':
    print(convert())
