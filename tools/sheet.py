"""Make a contact sheet of images: sheet.py out.png scale cols file1 file2 ..."""
import sys
from PIL import Image, ImageDraw
out, scale, cols = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
ims = []
for f in sys.argv[4:]:
    im = Image.open(f).convert('RGBA')
    if scale != 1: im = im.resize((max(1,int(im.width*scale)), max(1,int(im.height*scale))), Image.NEAREST)
    ims.append((f.split('/')[-1], im))
cw = max(i.width for _, i in ims) + 4; ch = max(i.height for _, i in ims) + 14
rows = (len(ims) + cols - 1) // cols
S = Image.new('RGBA', (cw * cols, ch * rows), (40, 40, 60, 255))
d = ImageDraw.Draw(S)
for k, (n, im) in enumerate(ims):
    x = (k % cols) * cw; y = (k // cols) * ch
    S.paste(im, (x + 2, y + 12), im)
    d.text((x + 2, y), n[:14], fill=(255, 255, 0, 255))
S.save(out)
print(S.size)
