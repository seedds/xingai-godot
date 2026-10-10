"""AI upscaling of the converted graphics (PyTorch + spandrel, runs on the Apple GPU via MPS).

Library part: load a super-resolution model (.pth/.safetensors, any architecture spandrel knows) and
upscale RGB or RGBA images. Large images are processed in overlapping tiles. Transparent pixels get the
colour of their nearest opaque neighbour before upscaling so sprite edges do not pick up dark halos, and
the alpha channel is upscaled by the same model (as a grey image).

    tools/venv/bin/python -I tools/upscale.py MODEL in.png out.png
"""
import sys

import numpy as np
import torch
from PIL import Image
from spandrel import ImageModelDescriptor, ModelLoader

DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def load_model(path: str, half: bool = False) -> ImageModelDescriptor:
    """Load a model file. `a.pth|b.pth@w` interpolates two models of the same architecture
    (w·a + (1−w)·b, "network interpolation", e.g. Real-ESRGAN's general model with its weak-denoise twin)."""
    if "|" in path:
        pair, w = path.rsplit("@", 1)
        a, b = pair.split("|")
        ma, mb = load_model(a), load_model(b)
        w = float(w)
        sb = mb.model.state_dict()
        ma.model.load_state_dict({k: w * v + (1 - w) * sb[k] for k, v in ma.model.state_dict().items()})
        return ma
    m = ModelLoader(device=DEVICE).load_from_file(path)
    assert isinstance(m, ImageModelDescriptor), path
    m.eval()
    if half and m.supports_half:
        m.model.half()
    return m


@torch.inference_mode()
def _run(model: ImageModelDescriptor, rgb: np.ndarray) -> np.ndarray:
    """rgb: HxWx3 float32 0..1 → (H*s)x(W*s)x3."""
    dtype = next(model.model.parameters()).dtype
    t = torch.from_numpy(np.ascontiguousarray(rgb.transpose(2, 0, 1)))[None].to(DEVICE, dtype)
    out = model(t)
    return out[0].clamp(0, 1).float().cpu().numpy().transpose(1, 2, 0)


def upscale_rgb(model: ImageModelDescriptor, rgb: np.ndarray, tile: int = 384, pad: int = 24,
                wrap: bool = False) -> np.ndarray:
    """Upscale an HxWx3 float32 image, in tiles of `tile` px with `pad` px of context on each side.
    `wrap`: the image is a repeating pattern, so its borders see the opposite side (stays seamless)."""
    s = model.scale
    h, w, _ = rgb.shape
    if h <= tile + 2 * pad and w <= tile + 2 * pad:
        return _run(model, _pad(rgb, pad, wrap))[pad * s:(pad + h) * s, pad * s:(pad + w) * s]
    src = _pad(rgb, pad, wrap)
    out = np.zeros((h * s, w * s, 3), np.float32)
    for y in range(0, h, tile):
        for x in range(0, w, tile):
            th, tw = min(tile, h - y), min(tile, w - x)
            part = _run(model, src[y:y + th + 2 * pad, x:x + tw + 2 * pad])
            out[y * s:(y + th) * s, x * s:(x + tw) * s] = part[pad * s:(pad + th) * s, pad * s:(pad + tw) * s]
    return out


def _pad(a: np.ndarray, pad: int, wrap: bool) -> np.ndarray:
    mode = "wrap" if wrap else "reflect" if min(a.shape[:2]) > pad else "edge"
    return np.pad(a, ((pad, pad), (pad, pad), (0, 0)), mode=mode)


def bleed(rgb: np.ndarray, alpha: np.ndarray, rounds: int = 16) -> np.ndarray:
    """Give fully transparent pixels the average colour of their opaque neighbours (repeated dilation)."""
    rgb = rgb.copy()
    known = alpha > 0
    if known.all() or not known.any():
        return rgb
    for _ in range(rounds):
        if known.all():
            break
        acc = np.zeros_like(rgb)
        cnt = np.zeros(known.shape, np.float32)
        # neighbours through a 1-pixel border of unknown pixels (np.roll would wrap colours round the edges)
        kp = np.pad(known, 1)
        rp = np.pad(rgb, ((1, 1), (1, 1), (0, 0)))
        h, w = known.shape
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
            k = kp[1 + dy:1 + dy + h, 1 + dx:1 + dx + w]
            acc += rp[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] * k[..., None]
            cnt += k
        new = (~known) & (cnt > 0)
        rgb[new] = acc[new] / cnt[new][:, None]
        known = known | new
    return rgb


def upscale_image(model: ImageModelDescriptor, img: Image.Image, wrap: bool = False,
                  alpha_model: ImageModelDescriptor | None = None) -> Image.Image:
    """Upscale a PIL image (RGB, RGBA or L; other modes are converted to RGB). `alpha_model` upscales the
    alpha channel (default: `model`; a small fast model is enough for masks)."""
    if img.mode == "L":
        return upscale_image(model, img.convert("RGB"), wrap).convert("L")
    if img.mode == "RGBA":
        a = np.asarray(img, np.float32) / 255.0
        alpha = a[..., 3]
        if alpha.min() >= 1.0:
            return upscale_image(model, img.convert("RGB"), wrap)
        rgb = upscale_rgb(model, bleed(a[..., :3], alpha), wrap=wrap)
        up_a = upscale_rgb(alpha_model or model, np.repeat(alpha[..., None], 3, 2), wrap=wrap).mean(2)
        if not ((alpha > 0) & (alpha < 1)).any():
            # colour-keyed sprite: keep edges crisp but anti-aliased (steepen the model's soft ramp)
            up_a = np.clip((up_a - 0.5) * 2.0 + 0.5, 0, 1)
        out = np.dstack([rgb, up_a])
        return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")
    rgb = np.asarray(img.convert("RGB"), np.float32) / 255.0
    return Image.fromarray((upscale_rgb(model, rgb, wrap=wrap) * 255 + 0.5).astype(np.uint8), "RGB")


if __name__ == "__main__":
    model = load_model(sys.argv[1])
    upscale_image(model, Image.open(sys.argv[2])).save(sys.argv[3])
