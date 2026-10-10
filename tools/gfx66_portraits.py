"""Portraits: E5/Face.e5 (700, mostly 120x120) -> gfx/portraits/large/NNN.png,
E5/Fb.e5 (700; 108 differ from Face.e5, mostly 192x272) -> gfx/portraits/fb/NNN.png, + portraits/index.json.
Both are 24-bit BMPs with the colour key (247,0,255). See docs/gfx.md §4.
"""
import os as _os
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import gfx66_common as g


def convert(out):
    F = g.arc('E5/Face.e5')
    B = g.arc('E5/Fb.e5')
    d = g.ensure(out + 'portraits')
    sizes_large = {}
    faces, detail = {}, {}
    fb_faces = []
    for i in range(len(F)):
        b = F[i]
        im = g.decode(b, key=True)
        g.save_png(im, '%s/large/%03d.png' % (d, i))
        if im.size != (120, 120):
            sizes_large[str(i)] = list(im.size)
        faces[str(i)] = ['large/%03d.png' % i]
        detail[str(i)] = {'large': 'large/%03d.png' % i}
    sizes_fb = {}
    for i in range(len(B)):
        b = B[i]
        if i < len(F) and b == F[i]:
            continue
        im = g.decode(b, key=True)
        g.save_png(im, '%s/fb/%03d.png' % (d, i))
        fb_faces.append(i)
        sizes_fb[str(i)] = list(im.size)
        detail.setdefault(str(i), {})['fb'] = 'fb/%03d.png' % i
    idx = {
        'large': 'large/%03d.png',
        'fb': 'fb/%03d.png',
        'small': None,
        'sizes': {'large': [120, 120], 'fb': [192, 272]},
        'large_odd_sizes': sizes_large,
        'fb_sizes': sizes_fb,
        'large_faces': list(range(len(F))),
        'fb_faces': fb_faces,
        'faces': faces,
        'faces_detail': detail,
        'face_index_rule': 'entry = 0x40765c(person): pid = word person+0 & 0xfff; v = u16 face_table[pid] '
                           '(VA 0x50f000, = the person face field word +4, copied by 0x423e30); entry = v + 7 if '
                           'v != 0 else 0. The same entry indexes Face.e5 and Fb.e5.',
        'sources': {
            'large': 'E5/Face.e5 (archive object 0x4ac538, opened by 0x42be51): 120x120 face in the dialog window '
                     '(0x42d3f5, 0x42de7d, 0x46d742, 0x431c19 ... mode 10 = key transparent) and in the status / '
                     'person windows (0x45c697, 0x469ecb, 0x44cbaa: mode 0x60 = key pixels turned black, drawn '
                     'opaque). Entries 596..627 include taller pictures (large_odd_sizes).',
            'fb': 'E5/Fb.e5 (object 0x4ac430): 192x272 portraits of the three-portrait dialog window 0x42d8bf -> '
                  '0x42d0a9 (600x356 window; portrait i at x = 6 + 198*i; persons not speaking are dimmed by '
                  '0x40690c). Entries identical to Face.e5 (120x120) are not exported: fb_faces lists the '
                  'entries that have their own picture.'},
        'transparency': 'colour key (247,0,255) within <10 per channel -> alpha 0',
    }
    g.write_index(out, 'portraits', idx)
    return {'large': len(F), 'fb': len(fb_faces)}


CATEGORIES = {'portraits': convert}
