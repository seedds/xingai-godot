"""Palette helpers for wagan/CCZ graphics.

Palette entries in Fei/Niuqun/DeDe (and other 768-byte palettes) are stored as (B, R, G) triplets:
the setter at wagan.wa 0x47e867 writes byte0->blue, byte1->red, byte2->green.  The loader 0x41e050
shifts every byte right by 4 and the setter shifts left by [0x4ba228]=4, so the game really shows
`v & 0xF0` per channel (4 bits/channel).  Only entries 10..245 are written (0x41e1f3 calls
0x47e867(10, 236, pal+30)); 0..9 and 246..255 are the Windows static colours.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from ls12 import read_archive

WIN_STATIC = {0: (0, 0, 0), 1: (128, 0, 0), 2: (0, 128, 0), 3: (128, 128, 0), 4: (0, 0, 128), 5: (128, 0, 128),
              6: (0, 128, 128), 7: (192, 192, 192), 8: (192, 220, 192), 9: (166, 202, 240),
              246: (255, 251, 240), 247: (160, 160, 164), 248: (128, 128, 128), 249: (255, 0, 0),
              250: (0, 255, 0), 251: (255, 255, 0), 252: (0, 0, 255), 253: (255, 0, 255), 254: (0, 255, 255),
              255: (255, 255, 255)}

def decode_palette(raw, quantize=False):
    """raw stored palette (<=768 bytes, BRG order) -> list of 256 (r,g,b)."""
    raw = bytes(raw) + bytes(768 - len(raw))
    four_bit = max(raw) <= 15   # e.g. MCALL00's embedded palette stores 0..15 per channel
    out = []
    for i in range(256):
        if i in WIN_STATIC:
            out.append(WIN_STATIC[i]); continue
        b, r, g = raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]
        if four_bit:
            r, g, b = r * 17, g * 17, b * 17
        if quantize:
            r, g, b = r & 0xF0, g & 0xF0, b & 0xF0
        out.append((r, g, b))
    return out

def flat(pal):
    return bytes(c for rgb in pal for c in rgb)

_cache = {}
def load(name, idx, quantize=False, root=_REPO + '/wg2025/'):
    if name not in _cache:
        _cache[name] = read_archive(root + name)
    return decode_palette(_cache[name][idx], quantize)
