"""Battle unit sprites: face.wa -> ~zl1g.dat (Unit_mov), ~gtl.dll (Unit_atk), ~kvr.db (Unit_spc).

Writes <out>/units/{mov,atk,spc}/NNN.png (vertical frame strips, RGBA, index 0 transparent) and
<out>/units/index.json.  See docs/gfx.md section "Battle unit sprites".
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from PIL import Image
import gfxcommon as g
import gfxpal

ARCHIVES = {
    'mov': ('~zl1g.dat', 48, 48, 11),
    'atk': ('~gtl.dll', 64, 64, 12),
    'spc': ('~kvr.db', 48, 48, 5),
}

FRAMES = {
    'mov': ['walk_down_0', 'walk_down_1', 'walk_up_0', 'walk_up_1', 'walk_left_0', 'walk_left_1',
            'stand_down', 'stand_up', 'stand_left', 'weak_0', 'weak_1'],
    'atk': ['attack_down_0', 'attack_down_1', 'attack_down_2', 'attack_down_3',
            'attack_up_0', 'attack_up_1', 'attack_up_2', 'attack_up_3',
            'attack_left_0', 'attack_left_1', 'attack_left_2', 'attack_left_3'],
    'spc': ['defend_down', 'defend_up', 'defend_left', 'hurt', 'cheer'],
}

# graphic id for persons without an override: class (person +0x2b) -> graphic, from the byte table
# built on the stack at wagan.wa 0x406950 (classes >= 0x35 -> 0x45)
CLASS_TO_GRAPHIC = [34, 35, 36, 0, 1, 2, 6, 7, 8, 3, 4, 5, 9, 10, 11, 18, 19, 20, 12, 13, 14, 15, 16, 17,
                    21, 22, 23, 24, 25, 26, 27, 28, 29, 43, 44, 45, 37, 38, 39, 33, 40, 32, 31, 30, 41, 46,
                    47, 48, 49, 42, 50, 51, 52]


def person_overrides():
    raw = open(g.GAME + 'person.wa', 'rb').read()
    return {i: b for i, b in enumerate(raw) if b}


def convert(out_root=g.OUT, quantize=False):
    pal = g.sprite_palette(quantize)
    out = out_root + 'units/'
    counts = {}
    for key, (arc, fw, fh, n) in ARCHIVES.items():
        ents = g.unit_archive(arc)
        g.ensure(out + key)
        for i, e in enumerate(ents):
            im = g.indexed_to_rgba(e, fw, fh * n, pal, key=0)
            g.save_png(im, '%s%s/%03d.png' % (out, key, i))
        counts[key] = len(ents)
    idx = {
        'source': 'face.wa (swapped-block ZIP) -> ~zl1g.dat=Unit_mov, ~gtl.dll=Unit_atk, ~kvr.db=Unit_spc '
                  '(Ls12 archives, 270 entries each, same entry index in all three)',
        'palette': 'shared sprite range (indices 10..173 identical in every palette); index 0 = transparent',
        'sheets': {k: {'dir': k + '/', 'file_pattern': k + '/%03d.png', 'count': counts[k],
                       'frame_w': ARCHIVES[k][1], 'frame_h': ARCHIVES[k][2], 'frames': len(FRAMES[k]),
                       'layout': 'vertical strip, frame i at y = i*frame_h', 'frame_names': FRAMES[k]}
                   for k in ARCHIVES},
        'mirroring': {
            'rule': 'right-facing frames are NOT stored: the engine mirrors the left-facing frames horizontally '
                    '(row mirror 0x41edf7 via 0x41ee53)',
            'mov': 'walk_right = mirror(walk_left_0/1) (0x43fd89: 48x96), stand_right = mirror(stand_left) '
                   '(0x43fde6: 48x48)',
            'atk': 'attack_right = mirror(attack_left_0..3) (0x403ce1: 64x256)',
            'spc': 'defend_right = mirror(defend_left) (0x403f56)'},
        'direction_codes': {'note': 'unit byte +0x0f (0x43e320); attack loader 0x403b8f jump table 0x403d75',
                            '0': 'up', '1': 'right (mirrored left)', '2': 'down', '3': 'left'},
        'anchor': {'mov': [0, 0], 'spc': [0, 0],
                   'atk': [-8, -8],
                   'note': '48x48 frames cover the cell; 64x64 attack frames are drawn centred on the cell '
                           '(offset -8,-8) - CCZ convention, not re-verified in the blitter'},
        'entry_index': {
            'function': 'wagan.wa 0x43fc48(unit)',
            'rule': 'g = graphic_id(person); if g < 43: entry = g*3 + min(unit.side, 2) else entry = g + 86',
            'unit.side': 'unit byte +5 (0..2) selects colour variant: entry g*3+0 red, +1 green, +2 blue '
                         '(colours as seen; which army is which side value: see data docs)',
            'graphic_id(person)': [
                'person record = [0x4d0048] + pid*0x48 (pid = word +0 & 0xfff); class = byte +0x2b',
                'override v = person_override[pid] (person.wa loaded to 0x55a000 by 0x4d00fc); tier = class % 3',
                'v=0: no override -> CLASS_TO_GRAPHIC[class] if class < 0x35 else 0x45',
                'v=1..5: g = 0x35 + 3*(v-1) + tier   (0x35..0x43)',
                'v=6: g = 0x44 if class < 0x28 else 0x45',
                'v>=7: g = v + 0x3f'],
            'class_to_graphic': CLASS_TO_GRAPHIC,
            'person_override': {str(k): v for k, v in person_overrides().items()},
        },
    }
    g.write_index('units', idx)
    return counts


if __name__ == '__main__':
    print(convert())
