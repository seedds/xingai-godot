"""Dump wagan.wa's mapped sections into one flat little-endian image starting at 0x400000
(zero-filled gaps, BSS zeroed), used by the Godot engine's emulated memory (src/core/mem.gd)."""
import os as _os
_REPO = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))   # repository root
import pefile, sys
src = _REPO + '/wg2025/wagan.wa'
dst = _REPO + '/game/assets/data/exe_image.bin'
pe = pefile.PE(src)
base = pe.OPTIONAL_HEADER.ImageBase
end = max(s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData) for s in pe.sections)
img = bytearray(end)
img[0:len(pe.header)] = pe.header
for s in pe.sections:
    raw = s.get_data()[:max(s.Misc_VirtualSize, 0) or len(s.get_data())]
    img[s.VirtualAddress:s.VirtualAddress + len(raw)] = raw
open(dst, 'wb').write(bytes(img))
print(hex(base), hex(base + end), len(img))
