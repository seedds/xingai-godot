# HD graphics

The original art is 640×480 with a 256-colour palette. On a modern display the game is scaled 3–5×, so the
pixels and the colour dithering show. The **HD graphics pack** replaces the textures the game draws with 4×
AI-upscaled versions and changes nothing else: the same images, at the same logical size, at the same places.
Released builds contain only the HD art; there is no switch.

![Original vs HD pack: a story background and battle units, same frame](images/hd-compare.jpg)

| | Original | HD |
|---|---|---|
| Story background (1:1 crop) | dithered 256-colour pixels | clean lines and gradients |
| Texture filtering | nearest-neighbour (sharp pixels) | bilinear (smooth); mipmapped in small windows |
| Files | `game/assets/gfx/**.png` | `game/assets_hd/gfx/**.webp` |

## Where it lives

* The pack (3,500 files, about 740 MB) is too big for the git repository. It is published as `assets_hd.zip` in
  the release tagged [hd-pack](https://github.com/seedds/wagang-godot/releases/tag/hd-pack).
* **Release builds** (`.github/workflows/release.yml`) download it (also checked against GitHub's SHA-256), and
  leave the original pictures out
  (`exclude_filter`), so a build ships only the HD art. The workflow then plays the first scenarios from the
  exported data to make sure no picture is missing.
* **From source:** `run_game.sh` downloads it into `game/assets_hd/` on first run (`tools/get_hd_pack.sh`, which
  checks the download against the SHA-256 GitHub publishes for the asset). Without it the game falls back to the
  original PNGs in `game/assets/`. `WG_HD=0` shows the original art for comparisons.
* **Local exports** include `game/assets_hd/` when it exists (`include_filter` in `game/export_presets.cfg`).

## How the game uses it

`Assets.tex(rel)` (`game/src/core/assets.gd`) looks for `res://assets_hd/<rel without .png>.webp` when HD is
active. It loads that 4× image and calls `ImageTexture.set_size_override()` with the original PNG's size (read
from its header). Every `get_size()`, region rectangle and draw call therefore keeps working in the original's
pixel units, and no drawing code changes. Images without an HD version fall back to the original.

* **Filtering:** with HD active, the root viewport's default canvas texture filter becomes bilinear (the
  original pixel art keeps nearest-neighbour). In a window smaller than 2.5× the original size the 4× art is
  shrunk enough to shimmer, so the filter then uses the textures' mipmaps (generated when an HD texture is
  loaded). The duel screen sets its own filter.
* **Size limit:** some GPUs accept textures of at most 8192 px. The one bigger image (battle map 13, 8448×6144)
  is scaled down to fit when it is loaded; the size override keeps its drawn size.
* **Memory:** a 4× texture takes 16× the memory (plus a third for mipmaps), so HD textures are cached with a
  budget (1 GB, LRU). Older ones stay alive only while a node still uses them.
* **Terrain patches** (bridges, gates and fires that change during a battle) are coloured at run time from an
  index image and the map's palette. The tool finds every (map, patch) pair a battle script can paste (79 of
  them), renders each with that map's palette and upscales it like the maps, as
  `effects/map_patches/mapMM/NNN.webp`. Any other combination gets a 4× Lanczos resize.

## Building the pack

```sh
tools/venv/bin/pip install torch spandrel          # PyTorch with Apple GPU (MPS) support, model loader
# download the models below into tools/upscale_models/
tools/venv/bin/python -I tools/upscale_assets.py    # ~1 hour on an M4 Pro; skips files that already exist
```

After rebuilding, publish the new pack so the release builds use it:

```sh
rm -f build/assets_hd.zip            # zip adds to an existing archive
(cd game/assets_hd && zip -0 -qr ../../build/assets_hd.zip . -x '*.tmp' -x '*.DS_Store')
gh release upload hd-pack build/assets_hd.zip --clobber
```

`--clobber` deletes the old file before the new one is uploaded, so release builds that start during the upload
fail; upload when no push is building.

Options: `--only SUBSTR` limits the run to paths containing *SUBSTR* (e.g. `--only maps/`), `--force` redoes
existing files, `--list` prints what would be done. `tools/upscale.py MODEL in.png out.png` upscales a single
image, for trying models.

How the tool works (`tools/upscale.py`):

* Models run through [spandrel](https://github.com/chaiNNer-org/spandrel), which loads ESRGAN, Real-ESRGAN,
  SwinIR, DAT, HAT and most other super-resolution architectures, on the Apple GPU in half precision.
* Large images are processed in 384 px tiles with 24 px of overlapping context.
* **Transparency:** fully transparent pixels first take the colour of their nearest opaque neighbours, so edges
  don't pick up dark fringes. The alpha channel is upscaled separately by a small fast model and steepened for
  colour-keyed sprites, so edges stay crisp but anti-aliased.
* **Sprite sheets** are split into frames with a 12 px transparent gutter, so neighbouring frames cannot bleed
  into each other.
* **Repeating patterns** (the window texture, the duel background tile) see wrap-around context, so they stay
  seamless.
* Output is WebP: lossy colour at quality 92, which is invisible at 4×, with lossless alpha.

## Model choice

Every candidate was run on the same samples of each kind of art and compared side by side. These included
Upscayl's models (Real-ESRGAN, Remacri, UltraSharp) and anime, pixel-art and general models.

| Art | Model | Why |
|---|---|---|
| portraits, CG pictures (`screens/`), story backgrounds | **RealESRGAN_x4plus_anime_6B** | Removes the palette dithering and gives clean lines and smooth gradients. The others keep the dither speckles as texture. |
| battle maps | **4x-AnimeSharp** | Keeps the grass, earth and rock texture. The anime model smears terrain into flat blobs. |
| unit and town sprites, effects, window and duel UI | **4x-PixelPerfectV4** | Crisp sprite outlines without invented detail. The anime model adds odd highlights at 48 px. |
| alpha masks | **realesr-animevideov3** | Small and fast; masks need no detail. |

Also tested and not used: RealESRGAN_x4plus, 4x-UltraSharp and 4x_foolhardy_Remacri (they amplify the
dithering), 4xHFA2k (soft), 4xHFA2k_ludvae_realplksr_dysample (alpha problems), realesr-general-x4v3 at three
denoise strengths (soft), and 4x-NMKD-Siax (amplifies dithering).

| Model file (`tools/upscale_models/`) | Source | Licence |
|---|---|---|
| `RealESRGAN_x4plus_anime_6B.pth` | [Real-ESRGAN v0.2.2.4](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.2.4) | BSD-3-Clause |
| `realesr-animevideov3.pth` | [Real-ESRGAN v0.2.5.0](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0) | BSD-3-Clause |
| `4x-AnimeSharp.pth` | [Kim2091/AnimeSharp](https://huggingface.co/Kim2091/AnimeSharp) ([OpenModelDB](https://openmodeldb.info/models/4x-AnimeSharp)) | CC BY-NC-SA 4.0 |
| `4x-PixelPerfectV4.pth` | [OpenModelDB: 4x-PixelPerfectV4](https://openmodeldb.info/models/4x-PixelPerfectV4) | WTFPL |

To try another model, add it to `tools/upscale_models/`, change the model in `RULES` in
`tools/upscale_assets.py` for the folders concerned, and re-run with `--force --only <folder>`.
