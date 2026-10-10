"""Battle maps: Hexzmap.e5 (terrain grids) + MAP/mNNN.jpg (map pictures) -> gfx/maps/mNNN.jpg + maps/index.json.

The pictures are JPEGs (W*48 x H*48) copied unchanged. No minimaps (the 6.6 game has no minimap file and the
Godot code does not use one). See docs/gfx.md §1.3.
"""
import os as _os
import os, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import gfx66_common as g


def map_files():
    """{map id: path} of orig/MAP/m%03d.jpg (case-insensitive: m000/m001 are .JPG)."""
    res = {}
    d = g.ORIG + 'MAP/'
    for f in os.listdir(d):
        low = f.lower()
        if low.startswith('m') and low.endswith('.jpg') and low[1:-4].isdigit():
            res[int(low[1:-4])] = d + f
    return res


def convert(out):
    H = g.arc('Hexzmap.e5')
    d = g.ensure(out + 'maps')
    files = map_files()
    maps = []
    for i in range(len(H)):
        b = H[i]
        W, Hh = b[0] // 3, b[1] // 3
        terrain = list(b[2:2 + W * Hh])
        ent = {'id': i, 'width': W, 'height': Hh, 'cell': 48,
               'terrain': [terrain[r * W:(r + 1) * W] for r in range(Hh)]}
        if i in files:
            raw = open(files[i], 'rb').read()
            name = 'm%03d.jpg' % i
            g.save_jpg(raw, d + '/' + name)
            im = g.open_image(raw)
            ent.update({'image': name, 'pixel_size': list(im.size), 'source': 'MAP/' + os.path.basename(files[i])})
            if im.size != (W * 48, Hh * 48):
                ent['note'] = 'picture size differs from the terrain grid (%dx%d cells)' % (W, Hh)
        else:
            ent.update({'image': None, 'note': 'no MAP/m%03d.jpg in the game (Hexzmap entry without picture)' % i})
        maps.append(ent)
    extra = sorted(k for k in files if k >= len(H))
    g.write_index(out, 'maps', {
        'format': 'terrain[row][col] = terrain type id per 48x48 cell (Hexzmap.e5 entry: byte W*3, byte H*3, W*H '
                  'bytes row-major); image = JPEG of W*48 x H*48 pixels (opaque, no palette)',
        'source': 'Hexzmap.e5 (Ls12, %d entries; loader 0x44c1c2: entry = word 0x510cfe, stores W,H at 0x4b422c) '
                  '+ MAP/mNNN.jpg (name built by 0x463d4f "MAP\\\\M%%s.Jpg" with the 3-digit map id, loaded by '
                  '0x420bae(word 0x510cfe) from battle setup 0x44d386)' % len(H),
        'map_id': 'word 0x510cfe, set by the scene op 0x413d13 kind 3: a4 (0xffff -> 99) + 100*byte[0x505f4c]',
        'maps': maps,
        'extra_pictures_without_grid': extra})
    return {'maps': len(maps), 'pictures': sum(1 for m in maps if m.get('image'))}


CATEGORIES = {'maps': convert}
