"""Icons, terrain pictures and UI pieces of the 6.6 engine (categories icons, terrain, ui for conv_gfx.py).

Sources (orig/, read only): E5/Item.e5, E5/Mtem.e5, Cmdicon.dll (resources parsed with pefile, never loaded),
E5/U_select.e5, E5/Mark.e5 + Mark.DEC, Ekd5.exe RT_BITMAP. See docs/gfx.md (icons / terrain / UI sections).
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import io, os, struct, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
import pefile
from PIL import Image
import gfx66_common as g

# ----------------------------------------------------------------------------- PE bitmaps


def pe_bitmaps(path):
    """{resource id: raw DIB bytes} of the RT_BITMAP resources of a PE file (parsed from bytes, never loaded)."""
    pe = pefile.PE(data=open(path, 'rb').read())
    out = {}
    for t in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if t.id != 2:
            continue
        for e in t.directory.entries:
            for leaf in e.directory.entries:
                ds = leaf.data.struct
                out[e.id if e.id is not None else str(e.name)] = pe.get_data(ds.OffsetToData, ds.Size)
    return out


def dib_image(raw):
    """PIL image of a packed DIB (BITMAPINFOHEADER + colour table + pixels)."""
    hs = struct.unpack('<I', raw[:4])[0]
    bpp = struct.unpack('<H', raw[14:16])[0]
    clr = struct.unpack('<I', raw[32:36])[0] if hs >= 40 else 0
    off = 14 + hs + ((clr or (1 << bpp)) * 4 if bpp <= 8 else 0)
    im = Image.open(io.BytesIO(b'BM' + struct.pack('<IHHI', 14 + len(raw), 0, 0, off) + raw))
    im.load()
    return im


def key_index0(im):
    """8-bit DIB -> RGBA with palette index 0 transparent."""
    a = np.array(im)
    rgba = np.array(im.convert('RGBA'))
    rgba[a == 0] = (0, 0, 0, 0)
    return Image.fromarray(rgba, 'RGBA')


def pal0(im):
    return tuple(im.getpalette()[:3]) if im.mode == 'P' else None


# ----------------------------------------------------------------------------- icons

CMD_ROLES = {21: '单挑 攻击', 22: '单挑 突击', 23: '单挑 防御', 24: '单挑 回避',
             31: '舌战 故事(小)', 32: '舌战 故事(中)', 33: '舌战 故事(大)', 34: '舌战 道理(小)', 35: '舌战 道理(中)',
             36: '舌战 道理(大)', 37: '舌战 时节(小)', 38: '舌战 时节(中)', 39: '舌战 时节(大)', 40: '舌战 镇静',
             41: '舌战 愤怒', 42: '舌战 诡辩', 43: '舌战 大喝', 44: '舌战 无视', 45: '舌战 故事', 46: '舌战 道理',
             47: '舌战 时节', 48: '舌战 话术', 49: '舌战 熟虑', 50: '舌战 熟虑', 51: '舌战 == ==', 52: '舌战 == ==',
             61: '舌战 big 故事', 62: '舌战 big 道理', 63: '舌战 big 时节'}


def conv_icons(out):
    d = g.ensure(out + 'icons')
    idx = {'rule': 'ImageList builder 0x40aa0b(name, count, masked, size, fixed): icon i = archive entry '
                   '2*i + size (size 0 = 16x16, 1 = 32x32); lists built at 0x40b5ac: Mtem small (0x492e0c, '
                   'unmasked), Mtem large (0x492e10, masked), Item small (0x492e18, masked), Item large (0x492e14, '
                   'masked), 256 icons each. Entries are decoded with mode 10 (colour key (247,0,255), tolerance '
                   '<10 per channel -> 0x4033dc); masked lists make the key transparent. An entry index past the '
                   'end of the archive reads entry 0 (0x41fc89).',
           'sets': {}}
    total = 0
    for rel, key, count, masks in (('E5/Item.e5', 'items', 256, (True, True)),
                                   ('E5/Mtem.e5', 'strategies', 88, (False, True))):
        A = g.arc(rel)
        ents = []
        for i in range(count):
            e = {'id': i}
            for size, sz in ((0, 'small'), (1, 'large')):
                n = 2 * i + size
                if n >= len(A):
                    continue
                f = '%s/%s/%03d.png' % (key, sz, i)
                g.save_png(g.decode(A[n], key=masks[size]), d + '/' + f)
                e[sz] = f
                total += 1
            ents.append(e)
        idx['sets'][key] = {'source': rel, 'count': count, 'entries': len(A),
                            'small_keyed': masks[0], 'large_keyed': masks[1], 'icons': ents}
    idx['sets']['strategies']['note'] = ('Mtem.e5 has 176 entries = 88 strategies; the game builds 256-icon '
                                         'lists, ids >= 88 fall back to entry 0. The small list is unmasked '
                                         '(drawn opaque), so small strategy icons are exported opaque.')
    # Cmdicon.dll: duel (单挑) and debate (舌战) command button bitmaps
    bms = pe_bitmaps(g.ORIG + 'Cmdicon.dll')
    ents = []
    for rid in sorted(bms):
        im = dib_image(bms[rid])
        f = 'commands/%03d.png' % rid
        g.save_png(im.convert('RGB'), d + '/' + f)
        ents.append({'id': rid, 'resource_id': rid, 'file': f, 'size': list(im.size), 'role': CMD_ROLES.get(rid)})
    idx['sets']['commands'] = {
        'source': 'Cmdicon.dll RT_BITMAP (8-bit DIB), LoadLibraryA at 0x475311 (handle 0x500abc)',
        'rule': 'button bitmaps set with BM_SETIMAGE (0x42b1a0: duel buttons id = 21 + n; debate: id = 31 + '
                'card value / 50 / 52) and STM_SETIMAGE on dialog item 0x56b (0x452d6a: 61..63 or 45..48); '
                'drawn opaque, file name = resource id',
        'count': len(ents), 'icons': ents}
    # U_select.e5[30]: 9 16x16 icons, ImageList 0x492e1c
    A = g.arc('E5/U_select.e5')
    strip = g.decode(A[30], key=True)
    ents = []
    for i in range(strip.height // 16):
        f = 'list16/%02d.png' % i
        g.save_png(strip.crop((0, 16 * i, 16, 16 * i + 16)), d + '/' + f)
        ents.append({'id': i, 'file': f})
    idx['sets']['list16'] = {
        'source': 'U_select.e5[30] (16x144 BMP) cut into 9 16x16 icons',
        'rule': 'ImageList 0x492e1c built at 0x40b655 = 0x40aa0b(U_SELECT, 9, masked, 16, fixed entry 30); '
                'drawn in item/equipment list views (0x44d6e6 draws index 7/8 = unchecked/checked box)',
        'count': len(ents), 'icons': ents}
    g.write_index(out, 'icons', idx)
    return {'icons': total, 'commands': len(bms), 'list16': len(ents)}


# ----------------------------------------------------------------------------- terrain

TERRAIN_NAMES_GUESS = ['平原', '草原', '树林', '荒地', '山地', '岩山', '山崖', '雪原', '桥梁', '浅滩', '沼泽', '池塘',
                       '小河', '大河', '栅栏', '城墙', '城内', '城门', '城池', '关隘', '鹿砦', '村庄', '兵营', '民居',
                       '宝物库', None, '火', None, None, None]


def conv_terrain(out):
    d = g.ensure(out + 'terrain')
    A = g.arc('E5/U_select.e5')
    big = g.decode(A[31], key=False)          # 48x1440 PNG, 30 frames
    tiles = []
    for t in range(big.height // 48):
        f = '%02d.png' % t
        g.save_png(big.crop((0, 48 * t, 48, 48 * t + 48)), d + '/' + f)
        tiles.append({'terrain': t, 'file': f, 'size': [48, 48], 'source': 'U_select.e5[31] frame %d' % t,
                      'name_guess': TERRAIN_NAMES_GUESS[t]})
    mini = g.decode(A[14], key=False)         # 12x360 JPEG, 30 frames (opaque, mode 0)
    minis = []
    for t in range(mini.height // 12):
        f = 'mini/%02d.png' % t
        g.save_png(mini.crop((0, 12 * t, 12, 12 * t + 12)), d + '/' + f)
        minis.append({'terrain': t, 'file': f})
    g.write_index(out, 'terrain', {
        'source': 'U_select.e5[31] (PNG 48x1440 = 30 frames of 48x48, frame = terrain id)',
        'rule': 'ImageList 0x4b68d0 = 0x40aa0b(U_SELECT, 30, unmasked, 48, fixed entry 31) built in the terrain '
                'list dialog 0x46c520 (call 0x46c644); picture index = terrain id',
        'note': 'names are CCZ defaults (guess); the data track has the authoritative terrain names',
        'tiles': tiles,
        'mini': {'source': 'U_select.e5[14] (JPEG 12x360 = 30 frames of 12x12)',
                 'rule': 'battle overview map 0x41e7fe: every cell of the Hexzmap grid is drawn as a 12x12 tile '
                         '(entry 14 frame = terrain id, loaded by 0x41e929 at buffer 0x40159c+0x642+0x4380); '
                         'deployment slots are numbered with U_select[12] (colour 0) / [13] (colour 1) 12x12 digits '
                         '1..20 (see ui/index.json)',
                 'cell': 12, 'tiles': minis}})
    return {'terrain': len(tiles), 'mini': len(minis)}


# ----------------------------------------------------------------------------- ui

# U_select.e5 entry roles (users in Ekd5.exe)
U_SELECT = {
    0: ('50x50 slot frame (stored as 100x25 JPEG = the 7500 bytes of a 50x50 picture), state 0', 0x45eade, 10, (50, 50)),
    1: ('50x50 slot frame, state 1', 0x45eade, 10, (50, 50)),
    2: ('50x50 slot frame, state 2', 0x45eade, 10, (50, 50)),
    3: ('选择武将 dialog (RT_DIALOG 236) upper background 512x296 (dialog item 0x43f)', 0x45eade, 0, None),
    4: ('选择武将 dialog lower background 512x128 (dialog item 0x441)', 0x45eade, 0, None),
    5: ('288x144 landscape picture: entry 5 + [0x500ae8] (0..3); 0x41d947 copies 48x48 pieces of it', 0x40a52e, 0, None),
    6: ('288x144 landscape picture (variant 1)', 0x40a52e, 0, None),
    7: ('288x144 landscape picture (variant 2)', 0x40a52e, 0, None),
    8: ('288x144 landscape picture (variant 3)', 0x40a52e, 0, None),
    9: ('344x84 parchment message box (UI buffer 0x401521 + 0x152a0; dialog 0x42d3f5 picks +0 / +0x152a0)', 0x43e86d, 10, None),
    10: ('344x84 parchment message box, mirrored (UI buffer + 0)', 0x43e86d, 10, None),
    11: ('title sub-menu buttons: 9 frames 176x44 (0-3 items, 4-7 highlighted, 8 blank); 0x404c33 draws item i '
         'from +i*0x5ac0 at y = 0x58 + 64*i', 0x42bc94, 10, None),
    12: ('12x12 digits 1..20 (deployment slot numbers, colour 0); overview map 0x41e7fe', 0x41e929, 10, None),
    13: ('12x12 digits 1..20 (colour 1)', 0x41e929, 10, None),
    14: ('12x12 terrain tiles for the battle overview map (30 frames = terrain id) -> terrain/mini/', 0x41e929, 0, None),
    15: ('48x10 bar frame (UI buffer +0x2adb0)', 0x43e86d, 10, None),
    16: ('2 frames 48x48 (watchtower, trap) (UI buffer +0x2b350)', 0x43e86d, 10, None),
    17: ('4 icons 24x24 (heart, feather, sword, scroll) (UI buffer +0x2e950)', 0x43e86d, 10, None),
    18: ('3 marks 16x16 (?, red X, blue X) (UI buffer +0x30450)', 0x43e86d, 10, None),
    19: ('8 frames 48x48: fire (0-3), boat, burning boats (UI buffer +0x30d50; frame sets 0x40dd39)', 0x43e86d, 10, None),
    20: ('8 frames 48x48: small fire / burning boats (map objects, 0x40dd39)', 0x40dde5, 10, None),
    21: ('12x12 digits 0..9', None, 10, None),
    22: ('600x84 white rounded text box (UI buffer +0x3e550; big-portrait talk 0x42d0a9)', 0x43e86d, 10, None),
    23: ('10 frames 48x48: green movement-path arrows and lines (UI buffer +0x633f0)', 0x43e86d, 10, None),
    24: ('12 arrows 12x12 (stat up/down) (UI buffer +0x741f0)', 0x43e86d, 10, None),
    25: ('16x16 sword icon', None, 10, None),
    26: ('16x16 sword icon', None, 10, None),
    27: ('16x16 sword icon', None, 10, None),
    28: ('16x16 sword icon', None, 10, None),
    29: ('16x16 sword icon', None, 10, None),
    30: ('9 icons 16x16 -> icons/list16/ (ImageList 0x492e1c)', 0x40b655, 10, None),
    31: ('30 terrain pictures 48x48 -> terrain/ (ImageList 0x4b68d0)', 0x46c644, 10, None),
}

EXE_ROLES = {106: 'toolbar strip, 12 buttons of 24x24 (288x28)', 302: 'toolbar strip, 12 buttons of 24x24 (288x24)',
             341: '48x48 shop button 卖出', 342: '48x48 shop button 买进', 343: '48x48 shop button 装备',
             344: '48x48 shop button 出兵', 350: '16x16 red bird mark', 351: '16x16 blue bird mark'}

# Mark.e5 pieces: frame height and the atlas offsets the exe code uses (0x4015da(offset) = Mark buffer + offset)
MARK_INFO = {
    0: (84, '2x84 colour bars', []),
    1: (48, 'window background pattern tile (dove); overwritten by Logo.e5[8+n] for pattern option n < 4, '
            'by grey (212,208,200) for n >= 4 (0x40abdc); tiled by the window filler 0x473202', [0x2a0]),
    2: (48, '4 frames 48x48 (water, tall grass, grass, snow): masks laid over the lower part of 48x48 unit '
            'frames on some terrains (unit draw 0x451347 -> 0x4302fc; 0x6ea0 = frame 3)', [0x6ea0]),
    3: (64, '4 frames 64x64: the same masks for 64x64 attack frames (0x119a0 = frame 3)', [0x119a0]),
    4: (48, '6 frames 48x48: boat drawn under a unit standing on terrain 13 (big river) (0x451347 -> 0x403479, '
            'mirrored for the right-facing direction)', []),
    5: (48, '6 frames 48x48: the same boat on blue water', []),
    6: (64, '6 frames 64x64: boat on blue water for 64x64 attack frames', []),
    7: (48, '4 frames 48x48: sand window tile (0x473202 default), red / grey / white cell frames',
        [0x3ada0, 0x3c8a0, 0x3e3a0, 0x3fea0]),
    8: (48, '8 frames 48x48: animated corner marks / coloured cell highlights', []),
    9: (24, '2 frames 24x24: speech bubble', [0x4f1a0, 0x4f860]),
    10: (16, '6 icons 16x16: 0 sword / 1 armour (unit status window 0x4503cf), 2..5 fire, water, ?, earth '
             '(unit info 0x45576d: offset 0x50520 + n*0x300, greyed when the flag bit is clear)',
         [0x4ff20, 0x50220, 0x50520]),
    11: (160, 'duel frame (one strip): 2 triangles 16x16 (left, right) + 2 bar caps 16x64 (left, right); = wg2025 Kao.wa '
             '0x198c0..0x1a2c0', [0x51120, 0x51420, 0x51720, 0x52320]),
}


def mark_records():
    d = open(g.ORIG + 'Mark.DEC', 'rb').read()
    recs = []
    for i in range(len(d) // 16):
        off, w, h, bpp = struct.unpack('<IHHH', d[16 * i:16 * i + 10])
        name = d[16 * i + 10:16 * i + 16].split(b'\0')[0].decode('gbk', 'replace')
        recs.append((off, w, h, bpp, name))
    return recs


def mark_piece(m, off, w, h):
    """Raw 24-bit BGR, top-down rows padded to 4 bytes -> RGB PIL image."""
    stride = (w * 3 + 3) & ~3
    a = np.frombuffer(m[off:off + stride * h], np.uint8).reshape(h, stride)[:, :w * 3].reshape(h, w, 3)[:, :, ::-1]
    return Image.fromarray(a.copy(), 'RGB')


def conv_ui(out):
    d = g.ensure(out + 'ui')
    items = []
    # exe bitmaps
    for rid, raw in sorted(pe_bitmaps(g.EXE).items()):
        im = dib_image(raw)
        k = pal0(im) == g.KEY
        f = 'exe/%s.png' % rid
        g.save_png(key_index0(im) if k else im.convert('RGBA'), d + '/' + f)
        items.append({'source': 'Ekd5.exe', 'resource_id': rid, 'file': f, 'size': list(im.size),
                      'keyed_index0': k, 'role': EXE_ROLES.get(rid)})
    # Mark.e5 atlas
    m = open(g.ORIG + 'E5/Mark.e5', 'rb').read()
    marks = []
    for i, (off, w, h, bpp, name) in enumerate(mark_records()):
        im = g.keyed(mark_piece(m, off, w, h))
        f = 'mark/%02d.png' % i
        g.save_png(im, d + '/' + f)
        fh, role, refs = MARK_INFO.get(i, (h, None, []))
        marks.append({'index': i, 'name': name, 'offset': off, 'size': [w, h], 'frame_size': [w, fh],
                      'frames': h // fh, 'file': f, 'role': role,
                      'exe_offsets': ['0x%x' % r for r in refs]})
    # U_select.e5
    A = g.arc('E5/U_select.e5')
    usel = []
    for i in range(len(A)):
        b = A[i]
        role, user, mode, reshape = U_SELECT[i]
        base = d + '/u_select/%02d' % i
        if reshape:                                  # 7500 bytes of a 50x50 picture stored as 100x25
            a = np.array(g.decode(b, key=False).convert('RGB'))
            im = g.keyed(Image.fromarray(a.reshape(-1, 3)[:reshape[0] * reshape[1]].reshape(
                reshape[1], reshape[0], 3)))
            g.save_png(im, base + '.png')
            f = os.path.basename(base) + '.png'
        else:
            f = g.save_entry(b, base, key=(mode != 0))
        im = Image.open(base + os.path.splitext(f)[1])
        usel.append({'entry': i, 'file': 'u_select/' + f, 'size': list(im.size), 'stored': g.kind(b),
                     'keyed': mode != 0, 'decode_mode': mode, 'role': role,
                     'loader': '0x%x' % user if user else None})
    # wg2025-compatible copies used by the Godot code (game/src/battle/duel_layer.gd, ui/ui_style.gd)
    kd = g.ensure(out + 'effects/kao')
    duel = g.keyed(mark_piece(m, *mark_records()[11][:3]))
    compat = []
    for name, box in (('198c0_16x16', (0, 0, 16, 16)), ('199c0_16x16', (0, 16, 16, 32)),
                      ('19ac0_16x64', (0, 32, 16, 96)), ('19ec0_16x64', (0, 96, 16, 160))):
        g.save_png(duel.crop(box), '%s/%s.png' % (kd, name))
        compat.append({'file': 'effects/kao/%s.png' % name, 'from': 'ui/mark/11.png rows %d..%d' % (box[1], box[3] - 1)})
    off, w, h = mark_records()[1][:3]
    g.save_png(mark_piece(m, off, w, h).convert('RGBA'), kd + '/1abc0_48x48.png')
    compat.append({'file': 'effects/kao/1abc0_48x48.png', 'from': 'ui/mark/01.png (花色 pattern tile, default)'})
    g.save_entry(A[3], g.ensure(out + 'effects/qusi') + '/03')
    compat.append({'file': 'effects/qusi/03.jpg', 'from': 'ui/u_select/03.jpg (same entry number as wg2025 '
                   'Qusi.wa[3]: the 选择武将 dialog background)'})
    g.write_index(out, 'ui', {
        'items': items,
        'mark': {'source': 'E5/Mark.e5 (0x52f20 bytes, raw 24-bit BGR, rows top-down padded to 4 bytes) + Mark.DEC '
                           '(16-byte records: u32 offset, u16 w, u16 h, u16 bytes/pixel, 6-byte GBK name)',
                 'loader': '0x42b734 reads the whole file into buffer block 0x48b110 (getter 0x4015c5 / 0x4015da(off)); '
                           'the exe addresses pieces by hard-coded offsets (exe_offsets), Mark.DEC is only the '
                           'editor directory; Weather.e5 follows in the same block at +0x52f20',
                 'key': '(247,0,255) -> transparent', 'pieces': marks},
        'u_select': {'source': 'E5/U_select.e5 (Ls12, 32 entries: JPEG/PNG/BMP24) = CCZ U_select.e5 (wg2025 Qusi.wa)',
                     'decode': 'decode_mode = mode passed to the entry decoder 0x40e770 (10: colour key kept -> '
                               'exported transparent; 0: opaque, JPEG copied as .jpg)',
                     'ui_buffer': '0x43e86d loads entries 10,9,12,15,16,17,18,19,22,23,24 back to back into block '
                                  '0x48b0d0 (getter 0x401521/0x401536(off)); offsets in the roles',
                     'entries': usel},
        'compat': {'note': 'copies under wg2025 names for the existing Godot code; effects/items32 is not produced '
                           '(the game draws item pictures from the Item.e5 ImageList = icons/items/large/)',
                   'files': compat}})
    return {'exe': len(items), 'mark': len(marks), 'u_select': len(usel), 'compat': len(compat)}


CATEGORIES = {'icons': conv_icons, 'terrain': conv_terrain, 'ui': conv_ui}
