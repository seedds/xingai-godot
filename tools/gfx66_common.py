"""Shared helpers for the 6.6-engine graphics converters (tools/conv_gfx.py + tools/gfx66_*.py).

Conventions (see docs/gfx.md):
  * Input: the original game under <repo>/orig/ (read only, never executed).
  * Output root: <repo>/game/assets/gfx/<category>/..., every category writes <category>/index.json.
  * PNG for everything except JPEG entries of opaque pictures, which are copied byte for byte as .jpg.
  * Sprites are RGBA: the engine's colour key (247,0,255) becomes alpha 0. The key test is the engine's:
    every channel differs by less than 10 (0x420691, applied to decoded entries by 0x4033dc when the
    loader passes mode 10/0x60/0x0b), so JPEG noise and the (255,0,255) variants are keyed too.
"""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import json, os, sys
sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
import numpy as np
from PIL import Image
from e5 import Archive, kind, open_image, exe_palette, KEY

ORIG = _REPO + '/orig/'
OUT = _REPO + '/game/assets/gfx/'
EXE = ORIG + 'Ekd5.exe'
KEY_TOL = 10

_arcs = {}


def arc(rel):
    """Lazy Ls12 archive under orig/ (cached)."""
    if rel not in _arcs:
        _arcs[rel] = Archive(ORIG + rel)
    return _arcs[rel]


_pal = None


def palette():
    """The engine's 256-colour palette (exe file offset 0x9D3C0 = VA 0x4cb1c0, used by the raw 8-bit
    path of the entry decoder 0x40e770). Indices 0..9 and 246..255 hold the key colour."""
    global _pal
    if _pal is None:
        _pal = exe_palette(EXE)
    return _pal


def key_hits(a, key=KEY, tol=KEY_TOL):
    """Bool mask of pixels the engine treats as the colour key (|c - key| < tol for R, G and B)."""
    a = a.astype(np.int16)
    return ((np.abs(a[..., 0] - key[0]) < tol) & (np.abs(a[..., 1] - key[1]) < tol)
            & (np.abs(a[..., 2] - key[2]) < tol))


def keyed(im, key=KEY, tol=KEY_TOL):
    """RGBA copy with the key colour (engine tolerance) made fully transparent (RGB zeroed)."""
    a = np.array(im.convert('RGBA'))
    hit = key_hits(a, key, tol)
    a[hit] = (0, 0, 0, 0)
    return Image.fromarray(a, 'RGBA')


def raw8(b, w, h, key=True):
    """RGBA picture of raw 8-bit pixels (row-major, top-down) in the exe palette; key colours transparent."""
    n = w * h
    idx = np.frombuffer(bytes(b[:n]).ljust(n, b'\0'), np.uint8).reshape(h, w)
    lut = np.zeros((256, 4), np.uint8)
    lut[:, :3] = np.array(palette(), np.uint8)
    lut[:, 3] = 255
    if key:
        lut[key_hits(lut[:, :3]), 3] = 0
        lut[lut[:, 3] == 0, :3] = 0
    return Image.fromarray(lut[idx], 'RGBA')


def decode(b, w=None, h=None, key=True):
    """Entry bytes -> PIL image as the engine's decoder 0x40e770 sees it. BMP/JPEG/PNG are decoded
    normally (bottom-up BMPs flipped); anything else is raw 8-bit in the exe palette of size w x h.
    key=True -> RGBA with the colour key transparent; key=False -> RGB (or RGBA if the PNG has alpha)."""
    k = kind(b)
    if k == 'raw':
        assert w and h, 'raw entry needs a size'
        im = raw8(b, w, h, key)
        return im if key else im.convert('RGB')
    im = open_image(b)
    if key:
        return keyed(im)
    if im.mode in ('RGBA', 'LA') or (im.mode == 'P' and 'transparency' in im.info):
        return im.convert('RGBA')
    return im.convert('RGB')


def jpeg_bytes(b):
    """A JPEG entry trimmed to its end-of-image marker (some entries carry padding after FFD9)."""
    e = b.rfind(b'\xff\xd9')
    return bytes(b[:e + 2]) if e > 0 else bytes(b)


def ensure(path):
    os.makedirs(path, exist_ok=True)
    return path


def save_png(im, path):
    ensure(os.path.dirname(path))
    im.save(path, optimize=False, compress_level=6)


def save_jpg(b, path):
    ensure(os.path.dirname(path))
    with open(path, 'wb') as f:
        f.write(jpeg_bytes(b))


def save_entry(b, path_noext, w=None, h=None, key=False):
    """Opaque picture entry: JPEG copied as <path>.jpg, anything else saved as <path>.png.
    Returns the file name written (basename with extension)."""
    if kind(b) == 'jpg' and not key:
        save_jpg(b, path_noext + '.jpg')
        return os.path.basename(path_noext) + '.jpg'
    save_png(decode(b, w, h, key), path_noext + '.png')
    return os.path.basename(path_noext) + '.png'


def img_size(b):
    """(w, h) of a BMP/JPEG/PNG entry without full decoding, None for raw."""
    if kind(b) == 'raw':
        return None
    im = open_image(b)
    return im.size


def write_index(out, category, obj):
    p = os.path.join(ensure(out + category), 'index.json')
    with open(p, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    return p
