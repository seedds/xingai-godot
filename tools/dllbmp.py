"""Extract RT_BITMAP resources from PE files as BMP/PNG."""
import pefile, struct, sys, os, io
from PIL import Image
def bitmaps(path):
    p = pefile.PE(path)
    out = []
    for t in p.DIRECTORY_ENTRY_RESOURCE.entries:
        if t.id != 2: continue
        for e in t.directory.entries:
            for l in e.directory.entries:
                ds = l.data.struct
                raw = p.get_data(ds.OffsetToData, ds.Size)
                name = e.id if e.id is not None else str(e.name)
                out.append((name, raw))
    return out
def to_image(raw):
    hdrsize = struct.unpack('<I', raw[:4])[0]
    bpp = struct.unpack('<H', raw[14:16])[0]
    clr = struct.unpack('<I', raw[32:36])[0] if hdrsize >= 40 else 0
    if bpp <= 8:
        ncol = clr or (1 << bpp)
        off = 14 + hdrsize + ncol * 4
    else:
        comp = struct.unpack('<I', raw[16:20])[0]
        off = 14 + hdrsize + (12 if comp == 3 else 0)
    fh = b'BM' + struct.pack('<IHHI', 14 + len(raw), 0, 0, off)
    return Image.open(io.BytesIO(fh + raw))
if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for name, raw in bitmaps(src):
        try:
            im = to_image(raw); im.load()
            im.save(os.path.join(dst, '%s.png' % name))
            print(name, im.size, im.mode)
        except Exception as ex:
            print(name, 'ERR', ex)
