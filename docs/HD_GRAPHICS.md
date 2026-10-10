# HD graphics

**There is no HD graphics pack for this game yet.** Every build, desktop and mobile, ships and draws the original
pictures (`game/assets/gfx/`, 8,501 PNG and JPEG files converted by `tools/conv_gfx.py`), scaled with
nearest-neighbour filtering.

The port inherited the HD mechanism of the wg2025 port, where a pack of 4× AI-upscaled textures replaces the art
the game draws. The code is still in place and switches itself on as soon as a pack exists in `game/assets_hd/`;
the tools that built and distributed wg2025's pack are wg2025-specific (see below).

## How the game would use a pack

`Assets.tex(rel)` (`game/src/core/assets.gd`) looks for `res://assets_hd/<rel without extension>.webp` when
`game/assets_hd/gfx/` exists (and `WG_HD` is not `0`). It loads that image and gives the texture the original's
size (`ImageTexture.set_size_override()`), so every size, region rectangle and draw call stays in the original's
pixel units and no drawing code changes. Pictures without an HD version fall back to the original.

* **Size:** the original's size is read from its PNG header. Pictures this game stores as JPEG (the battle maps,
  most story backgrounds and full-screen pictures, the map patches) have no PNG, so the size is taken as the
  WebP's size ÷ 4: their HD versions must be exactly 4×.
* **Filtering:** with HD active the viewport's default texture filter becomes bilinear, with mipmaps when the game
  is shown at less than 2.5× (the shrunk 4× art would shimmer). The duel screen sets its own filter.
* **Limits:** images over 8192 px are scaled down to fit (some GPUs accept no more); on phones images over 4096 px
  are halved. HD textures are cached up to a budget (1 GB, 384 MB on phones, least recently used first).
* `Assets.hd_only(rel)` serves generated art that has no original picture.
* **Exports:** every preset's `include_filter` has `assets_hd/*`, so a pack in `game/assets_hd/` would be packed
  automatically, next to the originals unless `exclude_filter` leaves those out.
* **Test:** `t_hd` checks the mechanism (it needs a window, see [DEVELOPMENT.md](DEVELOPMENT.md)).

## What a pack for this game would need

* **The upscaler's rules.** `tools/upscale_assets.py` (with `tools/upscale.py`, PyTorch and spandrel) is
  wg2025's and matches wg2025's asset tree, not this one:
  * its globs expect PNG (`maps/*.png`, `backgrounds/[0-9]*.png`, `screens/*.png`), while the 6.6 maps
    (`maps/mNNN.jpg`), most story backgrounds (`backgrounds/NNN.jpg`) and most screens are JPEG
    (`backgrounds/buha/` holds walk grids, not pictures); it expects `portraits/small/`, while this game has
    `portraits/large/` and `portraits/fb/`;
  * its terrain-patch pass renders palette-index images with `palettes/fei.json` (`effects/map_patches/idx/`); the
    6.6 engine draws in 24-bit colour, has no palettes, and its map patches are ready-made pictures
    (`effects/map_patches/NNN.jpg`);
  * several folders of this tree (`effects/dt`, `effects/tr`, `icons/`, `terrain/`, `ui/`) match no rule.
* **The model choice.** wg2025 picked an anime model for painted art, 4x-AnimeSharp for maps and 4x-PixelPerfectV4
  for sprites, mainly to remove 256-colour dithering. This game's art is 24-bit, so the comparison would have to be
  redone.
* **Distribution.** A pack is too big for the git repository (wg2025's had about 3,500 files, 740 MB). wg2025
  published it as a release asset, downloaded by `tools/get_hd_pack.sh` (from `run_game.sh`) and by a release
  workflow step (`.github/scripts/add_hd_pack.sh`, which also excluded the original pictures from the exports).
  Those two scripts pointed at wg2025's pack and have been removed from this repository; a pack for this game would
  need its own release, download script and workflow step.
