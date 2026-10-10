"""Full-screen pictures and other Logo.e5 pictures -> gfx/screens/NN.(jpg|png) + screens/index.json.

Logo.e5 (40 entries) plays the role of wg2025's GHAI.WA: title, title emblems, KOEI exit logo, GAME OVER,
window pattern tiles, publisher splash and the duel backdrops. JPEGs are copied unchanged; the BMP pieces are
keyed RGBA PNGs. See docs/gfx.md §6.
"""
import os as _os
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import gfx66_common as g

ROLES = {
    0: 'title screen 640x400, drawn at (0,40) by the title loop 0x42bd6c (mode 0)',
    1: 'title emblem (red bird) 64x64, drawn at (188,340) when byte 0 of SV\\SV.E5S is non-zero (0x41a280(0); 0x42bd6c, mode 10 keyed)',
    2: 'title emblem (yellow bird) 64x64 at (288,340) when 0x41a280(1)',
    3: 'title emblem (blue bird) 64x64 at (388,340) when 0x41a280(2)',
    4: 'cavalry painting 640x400: battle title card 0x424105 (drawn at (0,40), battle name text over it; called '
       'from battle setup 0x44d0dc/0x44d379) and backdrop of the ending sequence 0x4317ab (character cards '
       '0x431543 / 0x431c19; called from 0x42bed5)',
    5: 'stone relief 604x364 (duel backdrop size; duel op index 5)',
    6: 'KOEI logo 640x400 shown when the program exits (0x42b5e1 -> 0x412eec) and at the end of the ending '
       'sequence 0x4317ab',
    7: 'GAME OVER 640x400 (0x42c09e, from the main loop 0x42bf8a when the battle is lost)',
    8: 'window background pattern tile 48x48 (0x40abdc(n) n < 4 -> entry n + 8, mode 10; n is kept in byte 3 '
       'of SV\\SV.E5S, 0x41a280(3) / 0x41a1c6(3))',
    9: 'window background pattern tile 48x48 (n = 1)',
    10: 'window background pattern tile 48x48 (n = 2)',
    11: 'window background pattern tile 48x48 (n = 3)',
    12: 'publisher splash 640x480 (第3波); no loader found in Ekd5.exe (probably unused)',
}
DUEL = 'duel backdrop 604x364, drawn at (+8,+8) inside the 624x384 duel frame (0x4486f4); index = arg 2 of the ' \
       'duel script op 0x4103ee -> 0x4499a3'


def convert(out):
    A = g.arc('E5/Logo.e5')
    d = g.ensure(out + 'screens')
    screens = []
    for i in range(len(A)):
        b = A[i]
        k = g.kind(b)
        name = g.save_entry(b, '%s/%02d' % (d, i), key=(k != 'jpg'))
        im = g.open_image(b)
        role = ROLES.get(i, DUEL if im.size == (604, 364) else '?')
        if i == 5:
            role = 'stone relief 604x364; ' + DUEL
        screens.append({'entry': i, 'file': name, 'format': 'jpg' if k == 'jpg' else 'png', 'size': list(im.size),
                        'keyed': k != 'jpg', 'role': role})
    g.write_index(out, 'screens', {
        'source': 'E5/Logo.e5 (Ls12, %d entries; loaders call 0x448a0b(entry, buf) / 0x4789d6 with the archive '
                  'opened by 0x4165b8 ("E5\\\\LOGO.E5")); JPEG entries copied unchanged as NN.jpg, BMP entries '
                  'keyed (247,0,255) RGBA NN.png' % len(A),
        'title': 'screens/00 + emblems 01..03 (no alternative title pictures as in wg2025 GHAI 13..15)',
        'game_over': 7,
        'duel_backdrops': [s['entry'] for s in screens if s['size'] == [604, 364]],
        'window_tiles': [8, 9, 10, 11],
        'screens': screens})
    return {'screens': len(screens)}


CATEGORIES = {'screens': convert}
