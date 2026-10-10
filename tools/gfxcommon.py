"""Shared helpers for the wagan graphics converters (used by conv_gfx.py and gfx_*.py modules).

Conventions:
  * Output root: <repo>/game/assets/gfx/<category>/...
  * PNGs are RGBA.  Palette index 0 is the colour key for sprites (alpha 0) unless stated otherwise.
  * Every category writes <category>/index.json (see docs/gfx.md for the schemas).
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import io, json, os, sys, zipfile
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
from ls12 import read_archive
import gfxpal

GAME = _REPO + '/wg2025/'
OUT = _REPO + '/game/assets/gfx/'

_arc = {}
def archive(name):
    """Ls12 archive entries (handles the mod's hidden-offset headers)."""
    if name not in _arc:
        _arc[name] = read_archive(GAME + name)
    return _arc[name]

def face_zip_members():
    """face.wa = ZIP with blocks [0:0xc8] and [0x400:0x4c8] swapped (wg.exe 0x401160 writes
    %TEMP%\\de1.dat then unzips ~gtl.dll / ~kvr.db / ~zl1g.dat).  Returns {name: bytes}."""
    if 'face.wa' not in _arc:
        d = open(GAME + 'face.wa', 'rb').read()
        z = d[0x400:0x4c8] + d[0xc8:0x400] + d[0:0xc8] + d[0x4c8:]
        zf = zipfile.ZipFile(io.BytesIO(z))
        _arc['face.wa'] = {n: zf.read(n) for n in zf.namelist()}
    return _arc['face.wa']

def unit_archive(name):
    """name in ('~gtl.dll' (Unit_atk), '~kvr.db' (Unit_spc), '~zl1g.dat' (Unit_mov))."""
    key = 'unit:' + name
    if key not in _arc:
        _arc[key] = read_archive(face_zip_members()[name])
    return _arc[key]

# shared sprite palette: indices 10..173 are identical in every Fei/Niuqun/DeDe palette
def sprite_palette(quantize=False):
    return gfxpal.load('Fei.WA', 0, quantize)

def indexed_to_rgba(idx, w, h, pal, key=0):
    """idx: bytes/ndarray of w*h palette indices -> RGBA PIL image. key=None -> opaque."""
    a = np.frombuffer(bytes(idx[:w * h]), np.uint8).reshape(h, w)
    lut = np.zeros((256, 4), np.uint8)
    lut[:, :3] = np.array(pal, np.uint8)
    lut[:, 3] = 255
    if key is not None:
        lut[key, 3] = 0
    return Image.fromarray(lut[a], 'RGBA')

def untile(idx, cols, rows, tw, th):
    """cells stored one after another (tw*th bytes each, row-major cell order) -> flat w*h bytes."""
    a = np.frombuffer(bytes(idx[:cols * rows * tw * th]), np.uint8).reshape(rows, cols, th, tw)
    return a.transpose(0, 2, 1, 3).reshape(rows * th, cols * tw).tobytes()

def ensure(path):
    os.makedirs(path, exist_ok=True)
    return path

def save_png(im, path):
    ensure(os.path.dirname(path))
    im.save(path, optimize=False, compress_level=6)

def write_index(category, obj):
    p = os.path.join(ensure(OUT + category), 'index.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    return p
