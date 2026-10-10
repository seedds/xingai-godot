"""Battle unit sprites: Unit_mov.e5 / Unit_atk.e5 / Unit_spc.e5 -> gfx/units/{mov,atk,spc}/NNN.png + index.json.

717 entries per archive, same entry index in all three. 666 entries are 24-bit BMPs, entry 309 and 666..715 are
raw 8-bit pixels in the exe palette (some with 2 trailing bytes). Frames are stacked vertically (CCZ order).
Colour key (247,0,255) with the engine's tolerance (loaders pass mode 10 to 0x4789d6 -> 0x4033dc).
See docs/gfx.md §3.
"""
import os as _os
import struct, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import gfx66_common as g

SHEETS = {
    'mov': ('Unit_mov.e5', 48, 48, 11, ['walk_down_0', 'walk_down_1', 'walk_up_0', 'walk_up_1', 'walk_left_0',
                                         'walk_left_1', 'stand_down', 'stand_up', 'stand_left', 'weak_0', 'weak_1']),
    'atk': ('Unit_atk.e5', 64, 64, 12, ['attack_down_0', 'attack_down_1', 'attack_down_2', 'attack_down_3',
                                         'attack_up_0', 'attack_up_1', 'attack_up_2', 'attack_up_3',
                                         'attack_left_0', 'attack_left_1', 'attack_left_2', 'attack_left_3']),
    'spc': ('Unit_spc.e5', 48, 48, 5, ['defend_down', 'defend_up', 'defend_left', 'hurt', 'cheer']),
}

S_TABLE_VA, S_TABLE_FILE = 0x501000, 0xD2800     # u16 x 1024 per-person battle-graphic override (System.ini FileHead)


def s_table():
    with open(g.EXE, 'rb') as f:
        f.seek(S_TABLE_FILE)
        return list(struct.unpack('<1024H', f.read(2048)))


def convert(out):
    d = g.ensure(out + 'units')
    sheets = {}
    raw_entries = {}
    for key, (src, fw, fh, n, names) in SHEETS.items():
        A = g.arc(src)
        raws = []
        for i in range(len(A)):
            b = A[i]
            if g.kind(b) == 'raw':
                raws.append(i)
            im = g.decode(b, fw, fh * n, key=True)
            assert im.size == (fw, fh * n), (src, i, im.size)
            g.save_png(im, '%s/%s/%03d.png' % (d, key, i))
        raw_entries[key] = raws
        sheets[key] = {'dir': key + '/', 'file_pattern': key + '/%03d.png', 'count': len(A), 'source': src,
                       'frame_w': fw, 'frame_h': fh, 'frames': n,
                       'layout': 'vertical strip, frame i at y = i*frame_h', 'frame_names': names}
    st = s_table()
    idx = {
        'source': 'Unit_mov.e5 / Unit_atk.e5 / Unit_spc.e5 (Ls12, 717 entries each, same entry index in all three); '
                  '666 x 24-bit BMP, the others raw 8-bit in the exe palette (VA 0x4cb1c0)',
        'raw_8bit_entries': raw_entries['mov'],
        'transparency': 'colour key (247,0,255), every channel within <10 (0x4033dc/0x420691, mode 10) -> alpha 0',
        'sheets': sheets,
        'mirroring': {
            'rule': 'right-facing frames are not stored: the engine mirrors the left-facing frames (0x40d38c)',
            'mov': 'walk_right = mirror(walk_left_0/1), stand_right = mirror(stand_left) (0x43fd34)',
            'atk': 'attack_right = mirror(attack_left_0..3) (0x403b96 case 1: 0x40d38c(64, 256, frames 8..11))',
            'spc': 'defend_right = mirror(defend_left) (0x403d7f case 1)'},
        'direction_codes': {'note': 'unit direction byte (0x44270c); attack loader 0x403b96: 0 -> frames 4-7, '
                                    '1 -> mirrored 8-11, 2 -> 0-3, 3 -> 8-11; defend loader 0x403d7f likewise',
                            '0': 'up', '1': 'right (mirrored left)', '2': 'down', '3': 'left'},
        'anchor': {'mov': [0, 0], 'spc': [0, 0], 'atk': [-8, -8],
                   'note': '48x48 frames cover the cell; 64x64 attack frames centred on the cell (CCZ convention, '
                           'blitter not re-checked for the 6.6 engine)'},
        'entry_index': {
            'function': 'Ekd5.exe 0x43fc48(unit)',
            'rule': 'g = graphic_id(person); if g < 0x50: entry = g*3 + min(unit byte +5, 2) else entry = g + 0xa0',
            'unit.side': 'unit byte +5 selects the colour variant of the 80 class graphics: entry g*3+0/1/2 '
                         '(which army gets which value: battle code)',
            'graphic_id': [
                'Ekd5.exe 0x40685c(person) -> 0x4068a1(pid): pid = word person+0 & 0xfff (0x482715); '
                'class = person byte +0x2b (0x406610); tier = class % 3',
                'v = u16 S_table[pid] (VA 0x501000, 1024 entries; saved with the game state; script-settable)',
                'v == 0 (or pid >= 0x400) -> g = class',
                '1 <= v <= 0x20 -> g = 0x50 + 3*(v-1) + tier   (32 three-tier graphics, System.ini Three=32)',
                'v >= 0x21 -> g = v + 0x8f'],
            'entry_ranges': '0..239: 80 classes x 3 colours; 240..335: 32 three-tier graphics x 3 tiers '
                            '(v 1..32); 336..716: single graphics (v 33..413)',
            's_table_initial': {'va': '0x501000', 'file_offset': '0xD2800',
                                'note': 'initial values from the exe image (new game); a save restores the '
                                        '0x30000-byte block at 0x501000 (0x4188f2)',
                                'nonzero': {str(i): v for i, v in enumerate(st) if v}},
            'person_override': {str(i): v for i, v in enumerate(st) if v},
        },
    }
    g.write_index(out, 'units', idx)
    return {k: v['count'] for k, v in sheets.items()}


CATEGORIES = {'units': convert}
