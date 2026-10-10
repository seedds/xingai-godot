"""Build the HD graphics pack: 4x AI-upscaled copies of the textures the game draws.

    tools/venv/bin/python -I tools/upscale_assets.py [--force] [--only SUBSTR] [--list]

Reads game/assets/gfx/**.png and writes game/assets_hd/gfx/**.webp (same relative path, .webp instead of
.png), plus an importer="keep" .import file for each, so Godot ships them raw like game/assets. The game
uses an HD file instead of the original when it exists (see Assets.tex), at the original's logical size.

Each kind of art gets the model that suited it best in side-by-side tests (docs/HD_GRAPHICS.md):
painted art (portraits, CG pictures, story backgrounds) → Real-ESRGAN x4plus anime (clean lines, removes
the 256-colour dithering); battle maps → 4x-AnimeSharp (keeps the terrain texture); sprites, effects and UI
→ 4x-PixelPerfectV4 (crisp sprite edges). Sprite sheets are split into frames with transparent gutters so
neighbouring frames cannot bleed into each other; repeating patterns are upscaled with wrap-around context.
Existing outputs are skipped unless --force.
"""
import glob
import os
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upscale  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, "game/assets/gfx")
DST = os.path.join(REPO, "game/assets_hd/gfx")
MODELS = os.path.join(REPO, "tools/upscale_models")
KEEP = '[remap]\n\nimporter="keep"\n'

ANIME = "RealESRGAN_x4plus_anime_6B.pth"
TEXTURE = "4x-AnimeSharp.pth"
SPRITE = "4x-PixelPerfectV4.pth"
ALPHA = "realesr-animevideov3.pth"   # small fast model for transparency masks

# (glob relative to gfx/, model, frame size for sprite sheets or None, repeating pattern)
RULES = [
    ("portraits/large/*.png", ANIME, None, False),
    ("portraits/small/*.png", ANIME, None, False),
    ("screens/*.png", ANIME, None, False),
    ("backgrounds/[0-9]*.png", ANIME, None, False),
    ("maps/*.png", TEXTURE, None, False),
    ("units/mov/*.png", SPRITE, (48, 48), False),
    ("units/atk/*.png", SPRITE, (64, 64), False),
    ("units/spc/*.png", SPRITE, (48, 48), False),
    ("rpg_sprites/*.png", SPRITE, (48, 64), False),
    ("effects/xben/*/img_*.png", SPRITE, None, False),
    ("effects/mcall/*/img_*.png", SPRITE, None, False),
    ("effects/kao/1abc0_48x48.png", SPRITE, None, True),
    ("effects/kao/19ac0_16x64.png", SPRITE, None, False),
    ("effects/kao/19ec0_16x64.png", SPRITE, None, False),
    ("effects/kao/198c0_16x16.png", SPRITE, None, False),
    ("effects/kao/199c0_16x16.png", SPRITE, None, False),
    ("effects/qusi/03.png", SPRITE, None, True),
]

GUTTER = 12  # transparent px between frames: more than the models' reach at 1x
SCRIPTS = os.path.join(REPO, "game/assets/scripts")


def patch_combos() -> list:
    """(map id, Nima entry) of every terrain patch a battle script can paste (op 0x58 with patch >= 4 and
    alt == 0 → entry 2·patch−8; the map comes from op 0x27 change_scene mode 3, arg 4)."""
    import json
    combos = set()
    for f in sorted(glob.glob(os.path.join(SCRIPTS, "S_*.json"))):
        maps, patches = set(), set()
        for sc in json.load(open(f))["scenes"]:
            for se in sc["sections"]:
                for ins in se["body"]:
                    a = ins["args"]
                    if ins["op"] == 0x27 and a and a[0] == 3 and isinstance(a[4], int):
                        maps.add(0 if a[4] == 0xffff else a[4])
                    if ins["op"] == 0x58 and isinstance(a[0], int) and a[0] >= 4 and a[1] == 0:
                        patches.add(2 * a[0] - 8)
        combos |= {(m, e) for m in maps for e in patches}
    return sorted(combos)


def patch_image(map_id: int, entry: int) -> Image.Image:
    """A Nima patch coloured with a map's palette, as BattleView.add_patch builds it."""
    import json
    pals = json.load(open(os.path.join(SRC, "palettes/fei.json")))
    pal = pals[map_id] if isinstance(pals, list) else pals[str(map_id)]
    lut = [tuple(int(h.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)) for h in pal]
    idx = np.asarray(Image.open(os.path.join(SRC, "effects/map_patches/idx/%03d.png" % entry)).convert("L"))
    rgb = np.array([lut[k] if k < len(lut) else (0, 0, 0) for k in range(256)], np.uint8)[idx]
    return Image.fromarray(rgb, "RGB")


def jobs(only: str):
    for pattern, model, frame, wrap in RULES:
        for p in sorted(glob.glob(os.path.join(SRC, pattern))):
            rel = os.path.relpath(p, SRC)
            if only and only not in rel:
                continue
            yield rel, model, frame, wrap
    # terrain patches have no PNG of their own: rendered per map palette (see patch_image)
    for m, e in patch_combos():
        rel = "effects/map_patches/map%02d/%03d.png" % (m, e)
        if not only or only in rel:
            yield rel, TEXTURE, None, False


def upscale_sheet(model, img: Image.Image, fw: int, fh: int, alpha_model=None) -> Image.Image:
    """Upscale a grid of fw x fh frames, each surrounded by a transparent gutter."""
    img = img.convert("RGBA")
    cols, rows = img.width // fw, img.height // fh
    g = GUTTER
    spread = Image.new("RGBA", (cols * (fw + g) + g, rows * (fh + g) + g), (0, 0, 0, 0))
    for r in range(rows):
        for c in range(cols):
            spread.paste(img.crop((c * fw, r * fh, (c + 1) * fw, (r + 1) * fh)), (g + c * (fw + g), g + r * (fh + g)))
    up = upscale.upscale_image(model, spread, alpha_model=alpha_model)
    s = model.scale
    out = Image.new("RGBA", (img.width * s, img.height * s), (0, 0, 0, 0))
    for r in range(rows):
        for c in range(cols):
            x, y = (g + c * (fw + g)) * s, (g + r * (fh + g)) * s
            out.paste(up.crop((x, y, x + fw * s, y + fh * s)), (c * fw * s, r * fh * s))
    return out


def save(img: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    # lossy colour at a high quality (invisible at 4x), lossless alpha
    img.save(tmp, "WEBP", quality=92, method=4, alpha_quality=100)
    os.replace(tmp, path)
    with open(path + ".import", "w") as f:
        f.write(KEEP)


def main() -> None:
    force = "--force" in sys.argv
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    todo = [j for j in jobs(only) if force or not os.path.exists(os.path.join(DST, j[0][:-4] + ".webp"))]
    if "--list" in sys.argv:
        for j in todo:
            print(j[0], j[1])
        return
    print(f"{len(todo)} images to upscale", flush=True)
    loaded: dict = {}
    alpha_model = upscale.load_model(os.path.join(MODELS, ALPHA), half=True)
    t0 = time.time()
    for i, (rel, mname, frame, wrap) in enumerate(todo):
        if mname not in loaded:
            loaded.clear()   # one model on the GPU at a time (jobs are grouped by model)
            loaded[mname] = upscale.load_model(os.path.join(MODELS, mname), half=True)
        model = loaded[mname]
        if rel.startswith("effects/map_patches/map"):
            img = patch_image(int(rel.split("/")[2][3:]), int(rel[-7:-4]))
        else:
            img = Image.open(os.path.join(SRC, rel))
            img.load()
        if frame and img.width % frame[0] == 0 and img.height % frame[1] == 0:
            out = upscale_sheet(model, img, *frame, alpha_model=alpha_model)
        else:
            out = upscale.upscale_image(model, img, wrap, alpha_model)
        save(out, os.path.join(DST, rel[:-4] + ".webp"))
        if i % 25 == 0 or i == len(todo) - 1:
            el = time.time() - t0
            print(f"[{i + 1}/{len(todo)}] {rel} {el:.0f}s elapsed, ~{el / (i + 1) * (len(todo) - i - 1):.0f}s left",
                  flush=True)


if __name__ == "__main__":
    main()
