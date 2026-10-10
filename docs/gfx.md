# 新改曹操傳 6.6 graphics / asset formats (gfx track)

Status: complete first pass — every graphic file the exe loads is identified and converted (8501 files, ~400 MB
under `game/assets/gfx/`); open questions in §10.

Exe = `orig/Ekd5.exe` (the community "6.6 engine": CCZ Ekd5.exe largely rewritten in place, extra code and
tables in `.text3` 0x4ce000+). Addresses are VAs unless marked "file". The engine works in **24-bit** buffers:
every picture entry is decoded to BGR24 and blitted with a colour key, so there are no palettes any more
(compare rea/docs/gfx.md for wg2025, whose concepts — sheet layouts, frame meanings, KoeiAnim — carry over,
but whose addresses and file names do not).

## 1. Global facts

### 1.1 Containers and the entry decoder
* **Ls12** archives (Koei LS11 family; `tools/ls12.py`, lazy reader `tools/e5.py` `Archive`). Reader object:
  open 0x41fb35(obj, name) (= 0x418f5c open + 256-byte dictionary at file offset 0x10); `.e5` files under `E5\`
  are opened through 0x4165b8 (eax = name, ecx = object; path built by 0x42ba60 `"E5\%s"`), the root-level ones
  (UNIT_*.E5, PMAPOBJ.E5, HEXZMAP.E5) directly. Read entry 0x41fc89(obj, i, dst): the entry table starts at 0x110
  (12 bytes per entry, big-endian `csize, usize, offset`); **entry count = (offset of entry 0 − 0x114) / 12 and an
  index ≥ count reads entry 0**; csize == usize → stored, else LS11 decompression (0x41fbfe). Almost every 6.6
  archive stores its entries uncompressed (only 47 Pmap.e5 entries are compressed).
* **Picture loader** 0x4789d6(i, dst, mode, copy_size, archive) = read entry + decode 0x40e770(buf, size, mode,
  0x4be840) (+ copy `copy_size` bytes to dst). The decoder recognises
  - `BM` → BMP (24-bit payload copied; bottom-up rows flipped by 0x473c61, a negative height is taken as top-down);
  - `89 50 4E 47` → PNG (`PngRead` import, 32-bit PNGs get their alpha handled by 0x426511);
  - `FF D8 FF` → JPEG (`Jpg.dll` `JpgInit/JpgRead`, 0x420db9);
  - anything else → **raw 8-bit** pixels, each byte looked up in the exe palette at VA 0x4cb1c0 (file 0x9D3C0,
    256 RGBQUADs; `e5.exe_palette`), row-major top-down, no size information (the caller knows it).
  Then 0x4033dc(h, w, buf, mode) applies the **colour key** when mode ≠ 0: every pixel whose R, G and B each
  differ from (247,0,255) by **less than `mode`** (0x420691; mode 0x60 uses 10) is replaced by exactly (247,0,255)
  — or by black when mode = 0x60 (faces in status windows); mode 0x0b also keys near-black. Raw 8-bit entries with
  mode 10 skip this step (palette indices 0..9 and 246..255 already hold the exact key colour).
  Modes seen: 0 = opaque pictures (backgrounds, title, maps, range diagrams), 10 = sprites/faces/icons (tolerance
  < 10), 0x0c = animation pictures (Meff/DT/Mcall, tolerance < 12), 0x60 = faces drawn opaque.
* Converter rule (`tools/gfx66_common.py`): sprites → RGBA PNG with the key (same tolerance) as alpha 0;
  opaque JPEG entries are **copied byte for byte as `.jpg`** (trimmed after the EOI marker), opaque BMPs → PNG.
  **The Godot side must load `.jpg` files** (`Image.load_jpg_from_buffer`); every index.json gives the file name
  with its extension.

### 1.2 Palette
* There are no per-picture palettes any more (wg2025's Fei/Niuqun/DeDe are gone). The only palette is the
  exe's 256-colour table (0x4cb1c0) used for raw 8-bit entries (unit sprites 309/666..715, ~375 Pmapobj entries,
  some effects). Its entries 10..173 equal the shared sprite range of the CCZ/wg2025 palettes; 0..9 and 246..255
  are the key colour. `gfx/palettes/` is not produced.

### 1.3 Battle maps (Hexzmap.e5, MAP/mNNN.jpg)
* Map id = word 0x510cfe, set by the scene script op 0x413d13 with kind 3: `a4` (0xffff → 99) + 100 × byte
  [0x505f4c] (which is then cleared).
* `Hexzmap.e5` (root dir, 126 entries; loader 0x44c1c2(0) reads entry = word 0x510cfe): `byte0 = W*3, byte1 = H*3`,
  then W×H terrain bytes, cells 48×48, row-major; W,H stored at 0x4b422c/0x4b422d and the grid copied into the map
  buffer (0x40167e). Terrain ids used: 0..25, 27..29.
* Map picture = `MAP\M%03u.Jpg` (name builder 0x463d4f, zero-padded by 0x41800d), loaded by 0x420bae(word
  0x510cfe) from battle setup 0x44d386. JPEG, W*48 × H*48 (all 125 match their grid). m000/m001 are `.JPG`;
  **m109 is missing** (Hexzmap entry 109 has no picture).
* No minimap file: the battle overview map 0x41e7fe draws each cell as the 12×12 terrain tile U_select[14]
  (12 px per cell; `gfx/terrain/mini/NN.png`, §8.2) plus deployment-slot digits; no picture is produced here.
* Output: `gfx/maps/mNNN.jpg` + `maps/index.json` `{format, source, map_id, maps:[{id, width, height, cell:48,
  terrain:[[row]...], image:"mNNN.jpg"|null, pixel_size, source}], extra_pictures_without_grid}`.
  Difference from rea: `image` is a `.jpg`; no `palette`, `minimap`, `minimap_cell` keys.

## 2. Converter
`tools/venv/bin/python -I tools/conv_gfx.py [--only cat1,cat2] [--out DIR] [--list]` (default out
`game/assets/gfx/`, reads `orig/`). Categories and modules: units (`gfx66_units`), rpg_sprites + backgrounds
(`gfx66_story`), maps (`gfx66_maps`), portraits (`gfx66_portraits`), screens (`gfx66_screens`), effects
(`gfx66_effects`), icons + terrain + ui (`gfx66_ui`); shared helpers `gfx66_common`, `e5`, `ls12`. Writes
`gfx/summary.json`. Then run `tools/mark_keep.py` (marks `.png/.jpg/.json` importer=keep).

### 2.1 What the Godot code has to change (index/layout differences from rea)
* JPEG files: `maps/mNNN.jpg`, most `backgrounds/NNN.jpg`, most `screens/NN.jpg`, `effects/map_patches/NNN.jpg`,
  `effects/qusi/03.jpg`, some `ui/u_select/NN.jpg` — `Assets.image()` must decode JPEG; use the `file` names from
  the indexes (backgrounds: `images[entry].file`; screens: `screens[entry].file`).
* units: `Person.graphic_id()` / `sprite_entry()` → rule of §3 (S table 0x501000, `g < 0x50`, `g + 0xa0`).
* portraits: face entry = `v + 7` (v ≠ 0) for everybody, no story overrides; no `small` set (use `large`), new `fb`.
* story: scene op kinds/offsets of §5.1 (`image + 256·bank (+40 for kind 2)`); actor sprite = R table (§5.2).
* screens: title = 00 + emblems 01..03 (no alternative titles), game over = 07, duel backdrop = Logo entry.
* effects: strategy → Mcall then Meff (§7.4, arrays `meff`/`mcall`), record `dx/dy/cue/opacity`, new `dt`, `tr`;
  map patches are plain JPEGs (no `idx/` + palette).
* icons/terrain/ui: §8 (commands = duel/debate buttons by resource id, terrain pictures 0..29 + 12×12 `mini`).
* No `palettes/` directory and no minimaps.

## 3. Battle unit sprites (Unit_mov.e5 / Unit_atk.e5 / Unit_spc.e5)
| file | entry | frames |
|---|---|---|
| `Unit_mov.e5` | 48×528 = 11 × 48×48 | 0-1 walk down, 2-3 walk up, 4-5 walk left, 6 stand down, 7 stand up, 8 stand left, 9-10 weak (low HP) |
| `Unit_atk.e5` | 64×768 = 12 × 64×64 | 0-3 attack down, 4-7 attack up, 8-11 attack left |
| `Unit_spc.e5` | 48×240 = 5 × 48×48 | 0 defend down, 1 defend up, 2 defend left, 3 hurt, 4 cheer |
* 717 entries each, same index in the three files. 666 are 24-bit BMPs; **entry 309 and 666..715 are raw 8-bit**
  (25344/49152/11520 bytes, 50 of them with 2 trailing bytes) in the exe palette. All loaded with mode 10 (keyed).
* Loaders: mov 0x43fe2c (UNIT_MOV.E5, 0x12900 bytes), atk 0x403b96, spc 0x403d7f. Right-facing frames are
  mirrored from the left ones (0x40d38c): atk direction 0 → frames 4-7, 1 → mirror of 8-11, 2 → 0-3, 3 → 8-11
  (0x403b96, direction byte via 0x44270c); spc likewise (0x403d7f); mov walk/stand right in 0x43fd34.
  Direction codes 0 up, 1 right, 2 down, 3 left (as CCZ).
* **Entry index** 0x43fc48(unit): `g = graphic_id(person)`; `entry = g*3 + min(unit byte +5, 2)` if `g < 0x50`
  else `entry = g + 0xa0`.
* **graphic_id** 0x40685c → 0x4068a1(pid): pid = word person+0 & 0xfff (0x482715); class = person byte +0x2b
  (0x406610); `tier = class % 3`; `v = u16 S_table[pid]` at **0x501000** (1024 entries; initial values in the exe
  image, file offset 0xD2800 = System.ini `FileHead`; part of the 0x30000-byte state block 0x501000.. that a save
  restores (0x4188f2); script-settable).
  - `v == 0` (or pid ≥ 0x400) → `g = class` (no class→graphic table any more: 80 class graphics);
  - `1 ≤ v ≤ 0x20` → `g = 0x50 + 3*(v−1) + tier` (32 "three-tier" graphics, System.ini `Three=32`);
  - `v ≥ 0x21` → `g = v + 0x8f`.
  Entry ranges: 0..239 = 80 classes × 3 colours; 240..335 = three-tier graphics; 336..716 = single graphics
  (v 33..413). The initial S table has 373 non-zero entries (max 360).
* Output: `gfx/units/{mov,atk,spc}/NNN.png` (vertical strips, RGBA) + `units/index.json` (rea schema:
  `sheets.{mov,atk,spc}: {dir, file_pattern, count, frame_w, frame_h, frames, layout, frame_names}`,
  `mirroring`, `direction_codes`, `anchor`, `entry_index`). Differences: `entry_index` has no `class_to_graphic`;
  it has `graphic_id` (rule text), `entry_ranges`, `s_table_initial.nonzero` and `person_override` (= the same
  initial S table as `{pid: v}`), but **`v` means something else than wg2025's person.wa byte** — Person.graphic_id()
  must be rewritten with the rule above.

## 4. Portraits (E5/Face.e5, E5/Fb.e5)
| set | source | size | used by |
|---|---|---|---|
| large | Face.e5 entry f (700) | 120×120 (34 entries 596..629 taller: 120×127..196) | dialog window 0x42d3f5 / 0x42de7d, unit info 0x46d742, 0x431c19 (mode 10, keyed); status/person windows 0x45c697, 0x469ecb, 0x44cbaa (mode 0x60: key → black, drawn opaque) |
| fb | Fb.e5 entry f (700; 108 differ from Face.e5: 106 × 192×272, 1 × 192×282, 1 × 120×120) | 192×272 | three-portrait dialog window 0x42d8bf → 0x42d0a9: 600×356 window, portrait i at x = 6 + 198·i, persons not speaking dimmed by 0x40690c |
* Archive objects: Fb 0x4ac430, Face 0x4ac538 (opened by 0x42be51 together with Mmap 0x4ac640).
* **Face entry** 0x40765c(person): `v = u16 face_table[pid]` at 0x50f000 (the person face field, word +4 of the
  runtime person record, kept in sync by 0x423e30); **entry = v + 7 if v ≠ 0, else 0**. No per-person story
  overrides as in wg2025 (pid 1/4/8/35); Game.resolved_face() must drop them. The protagonist uses the same rule.
* The engine blits 120×120 from the decoded picture, i.e. the top 120 rows of the taller entries.
* Fb entries identical to Face.e5 are 120×120 pictures the 192×272 blit would overrun; they are not exported
  (`fb_faces` lists the 108 that exist).
* Output: `gfx/portraits/large/NNN.png`, `gfx/portraits/fb/NNN.png` (RGBA, key → alpha 0), `portraits/index.json`:
  `{large: "large/%03d.png", fb: "fb/%03d.png", small: null, sizes, large_odd_sizes, fb_sizes, large_faces,
  fb_faces, faces: {"f": [file]}, faces_detail: {"f": {large, fb}}, face_index_rule, sources, transparency}`.
  Differences: no `small` (80×80) or `classic` (64×80) sets exist in 6.6 — code asking for small faces must use
  `large` (scaled); new `fb` set.

## 5. Story / RPG scenes
### 5.1 Scene backgrounds (E5/Mmap.e5) and scene grids (E5/Pmap.e5)
* Mmap.e5: 852 × 640×400 (599 BMP24 → PNG, 253 JPEG → .jpg; entry 92 is blank black). Archive object 0x4ac640.
* Loader 0x40bbaf: scene struct 0x4ac63c = `{byte kind, byte image}`;
  **entry = image + 256 × dword[0x505eec] + (40 if kind == 2 else 0)**, decoded with mode 0 (opaque) and blitted
  640×400 at (0,40). Cache dword 0x48bae0[kind]. dword 0x505eec is a picture **bank** that is only read here (set
  through script memory writes). For kind 2 the decoded picture is then re-ordered into 8×8 tiles
  (0x473d4a(buf, 0x3250, tmp, 8): 80×50 tiles) for the scene compositor — **the storage itself is always plain
  rows** (verified on all 852 entries), unlike wg2025's Giji.WA.
* Scene script op 0x413d13 (5 args a0..a4, a0 = kind): kind 0: image = a1 (0xffff → 0); kind 1: image = 114 if
  a2 == 0, else a1, or (a1 == 0xffff) a3 + 40 (a3 == 0xffff → 114); kind 2: image = a3 (0xffff → 0); kind 3 =
  battle map (image 0xff, see §1.3). 0x428346(kind, image) stores the image as a **byte**. (Script agent: map
  this onto the op's arguments; story_stage.op_change_scene's wg2025 offsets {0:0, 1:114, 2:40} are wrong now.)
* Pmap.e5: 812 × 20016 bytes, **entry = image + 256 × dword[0x505eec] (no kind offset)**, loader 0x425dcd → buffer
  0x401669 (word 0 overwritten with the image id). Header 8 LE words `[id, X=100, Y=100, Z=1, 200, 100, 1, ?]`;
  then a u16 grid [Z][Y][X] at offset 0x10 (0x4268ba: `0x10 + 2*((X*Y)*z + X*y + x)`, dims read by 0x426a71).
  Cell low byte = object sprite id (0xff = none; 0x427426 creates a scene-object actor with Pmapobj character =
  low byte — no shipped entry has one), high byte 0xff / 0xf0 (walk / occlusion flags, as wg2025 Buha.wa).
* Output: `gfx/backgrounds/NNN.(png|jpg)`, `gfx/backgrounds/buha/NNN.png` (200×100 greyscale = the raw grid
  bytes, low/high byte per cell, same picture as rea's Buha export), `backgrounds/index.json`:
  `{source, scene_lookup:{loader, rule, cache, script_op, bank}, images:[{entry, file, format, size, blank}],
  buha:{source, format, masks:[{entry, file, header_words, extra_word_14}]}}`.
  Differences: `file` may be `.jpg` (load by `images[entry].file`, not `"%03d.png"`); no `palette`, `storage`,
  `scene_kind`, `scene_image` (an entry can be reached by several kinds).

### 5.2 RPG actor sprites (Pmapobj.e5)
* Pmapobj.e5 (root dir): 922 entries = **461 characters**, character c = entries 2c (front view, facing down-left)
  and 2c+1 (back view, facing up-right), each 48×1280 = 20 frames of 48×64. Storage mixed: 546 BMP24, 279 raw
  8-bit (61440 B) + 88 raw with 2 trailing bytes, 1 JPEG (entry 710), and **8 BMPs whose 54-byte header is wiped
  (548–553, 914, 915)**: the decoder would take them for raw 8-bit (garbage); the converter decodes their payload
  as the intended bottom-up BMP, but the bottom part of those files (frames ~13..19) is corrupt in the original too.
  These are characters 274–276 and 457 (only R_table[1000] = 457 refers to one of them).
* Cache loader 0x426c6a(c, slot): entries 2c+1 and 2c (mode 10, 0x2d000 bytes each) → slot
  `[2c+1 | mirror(2c) | 2c | mirror(2c+1)]` (0x40d38c(48, 1280) row mirror) — same order as CCZ/wg2025, so
  **direction code d: 0 = up-right (back), 1 = down-right (mirrored front), 2 = down-left (front), 3 = up-left
  (mirrored back)**. Slots ≥ 18 live in a second buffer (+0xbb800). Frame address inside the slot
  (`(d*20 + frame) * 0x2400`) not re-verified in the 6.6 code.
* **Character of an actor** = `u16 R_table[pid]` at **0x50f800** (0x409038; initial values exe file 0xE1000 =
  System.ini `RFileHead`; set by script op 0x411f2d; saved with the 0x501000 block). Actor creation for a person
  0x428c8e → 0x426d61(pid, c) → cache lookup 0x426a4a / loader 0x426c6a.
* Frames: 0 stand, 1/2 walk, 3..19 action poses (as wg2025, character specific).
* Output: `gfx/rpg_sprites/NNN.png` = 960×256 sheet (row = direction code, column = frame) for c = 0..460,
  `rpg_sprites/index.json` (rea schema: `source, count, file_pattern, frame_w, frame_h, frames_per_direction,
  layout, directions, frames`; plus `transparency`, `sprite_id_rule` with `r_table_initial.values` (1024),
  `notes` {entry: problem}, `storage_kinds`). rea's `anchor`/`coordinates`/`loader` keys are not exported.
* Actor screen transform: the forward transform was not re-traced, but the 6.6 mouse → scene-cell inverse 0x478d56
  (`a = mx>>3, b = my>>2; X = (a+b−1 + 2·camY − W/2 + camX)>>1; Y = (b−a−3 + 2·camY + W/2 − camX)>>1`, camX/camY =
  words 0x49ceb4/0x49ceb6, W = Pmap header word at offset 8 = 200) is exactly the inverse of rea's §5.2 transform
  (`sx = 8(X−Y) + 4W − 8 − 8camX`, `sy = 4(X+Y) − 8Z − 8camY + 8`), so that transform still applies.

## 6. Full-screen pictures (E5/Logo.e5)
| entry | size | role |
|---|---|---|
| 0 | 640×400 JPEG | title screen, drawn at (0,40) by the title loop 0x42bd6c |
| 1-3 | 64×64 BMP | title emblems (red/yellow/blue bird) at (188/288/388, 340) when byte 0/1/2 of `SV\SV.E5S` is non-zero (0x41a280(i) reads byte i of that file) |
| 4 | 640×400 | battle title card 0x424105 (battle setup 0x44d0dc/0x44d379; battle name drawn over it) and backdrop of the ending sequence 0x4317ab |
| 5 | 604×364 | stone relief (duel backdrop size) |
| 6 | 640×400 | KOEI logo: program exit (0x42b5e1 → 0x412eec) and end of the ending sequence |
| 7 | 640×400 | GAME OVER (0x42c09e, main loop 0x42bf8a when a battle is lost) |
| 8-11 | 48×48 BMP | window background pattern tiles: 0x40abdc(n) n < 4 → entry n+8 (mode 10) into buffer 0x4015da; n is kept in byte 3 of `SV\SV.E5S` (0x41a280(3) / 0x41a1c6(3)); they are copied over the Mark.e5 花色 tile, and with the default n = 0 the built-in Mark tile stays (§8.3) |
| 12 | 640×480 | publisher splash (第3波); no loader found |
| 13-39 (and 5) | 604×364 JPEG | **duel backdrops**: duel op 0x4103ee (args: 2 persons, backdrop) → 0x4499a3 → 0x4486f4 draws Logo[backdrop] at (+8,+8) inside the 624×384 duel frame |
* Output: `gfx/screens/NN.jpg` (JPEG entries) / `NN.png` (BMP entries, keyed), `screens/index.json`
  `{source, title, game_over: 7, duel_backdrops, window_tiles, screens:[{entry, file, format, size, keyed, role}]}`.
  Differences from rea: files are mostly `.jpg`; no palettes; the title is always entry 0 (+ emblems), wg2025's
  alternative titles 13..15 do not exist (main.gd's `12 + v` choice is wrong now), game over = 07, the duel
  backdrop index is the Logo entry itself.

## 7. Effects and animations (converter `tools/gfx66_effects.py`, category `effects`)

Output root `gfx/effects/`, one `index.json` (schema in §7.6). Files written by the ui converter into
`effects/kao/` and `effects/qusi/` are described in `ui/index.json` (`effects/items32/` is not produced, §8.3).

### 7.1 KoeiAnim format (Meff.e5 / DT.e5 entries, Mcall00-22.e5 files)
* Header 20 bytes: `u8 n_rec, u8 n_img, u8 n_alpha, u8 has_pal, u32 delay_ms, u32 W, u32 H, u32 id`; then `n_rec`
  20-byte records; then the pictures. Three picture storages (the 6.6 engine decodes all of them to 24-bit with
  the entry decoder 0x40e770, mode 0x0c):
  - **raw 8-bit** (19 Mcall files, all of Meff, DT 7..59): `n_img` WxH index planes then `n_alpha` WxH planes,
    expanded through the exe palette (VA 0x4cb1c0) — the alpha planes too;
  - **BMP24** (Mcall00, DT 0..6): one bottom-up BMP of W x H*(n_img+n_alpha), frames stacked top to bottom
    (Meff loader 0x4318e5 moves the BMP header behind the pixels and gives it a negative bfOffBits so 0x40e770
    decodes it in place);
  - **PNG** (Mcall12/13/15): one 32-bit PNG of W x H*(n_img+n_alpha); PngRead (Jpg.dll import) returns RGB plus
    an alpha plane, which 0x426511 rescales to percent (a*100/255).
* Record: `+0 u8 image, +1 u8 layer (always 0xff), +2 u8 p2, +3 u8 p3, +4 u32 mode, +8 i32 dx, +12 i32 dy,
  +16 u8 cue` (+17..19 garbage). dx/dy are new compared with rea's description (they are non-zero in 6.6 files).
* `id`: low byte = sound effect, played as `0x46d0b7(id + 100)` (Mcall 0x403035 via 0x41c4ef, Meff 0x42bf1a).
  Byte 18 (third byte of id) = per-pixel-alpha flag (below).
* Timing: delay is divided by 50 (Mcall 0x40273f, Meff 0x40bd5d) and waited in ticks of timeGetTime()/50
  (0x42c632 / 0x47eb97): one record per `delay_ms` (all shipped delays are multiples of 50).
* Position: frame top-left = `(x - W/2 + dx, y - H/2 + dy)`, (x, y) = target point. Meff: target cell centre
  (0x40196f: cell pos (0x4169f4) + 24, stored minus W/2,H/2 by 0x401a7c, record offset added in 0x40208b), one copy
  per target. Mcall: 0x402b83 with the point from 0x421496 = target cell centre, or the map-view centre
  (`w/2, h/2 + 0x38`) for strategy categories 0x1c/0x1d.
* **Blending (24-bit, rewritten in 6.6 — rea's 8-bit palette-LUT modes no longer apply):** key pixels
  (|c - (247,0,255)| < 12 per channel after decoding, incl. palette entries 0-9, 124, 246-255) are never drawn.
  Others: `out = (bg*(100-L) + img*L) / 100` per channel (0x40690c → 0x415a64, integer division), with
  `L = p3*6 + 4` (Mcall 0x4055fa, Meff 0x402396/0x40e905). Exceptions:
  - Mcall record with `mode == 0 and p2 == 0` → plain keyed copy (0x402b83);
  - **per-pixel alpha**: when the 16-bit word at header +18 is 0x2001 (byte 18 == 1 and the decoder flagged a
    32-bit PNG), L = the PNG alpha of that pixel instead (Mcall 0x4055fa tests obj+0x2e, Meff 0x40e905 tests obj+2 =
    the n_alpha byte + flag). True for Mcall13 and Mcall15. Mcall12 has a PNG but byte 18 = 0: the engine ignores
    its alpha (converted that way: keyed RGB, uniform L — its transparent area is drawn as white).
  - The 8-bit alpha maps and the `mode`/`p2` alpha-index fields are loaded but not used by either 6.6 player.
  The converter precomputes `opacity` per record (= L/100, or 1.0 for the two exceptions).
* Record `cue`: Meff `cue == 1` = hit frame (0x401e5d → 0x421ab6 draws the targets' hurt/defend frame from
  Unit_spc and the damage numbers); sound on frame 0 unless `cue == 2`, and on every frame with `cue == 3`
  (Mcall 0x41c4ef, Meff 0x403206).

### 7.2 Meff.e5 → `effects/xben/`, DT.e5 → `effects/dt/`
* Meff.e5: Ls12, 60 KoeiAnim (57 entries byte-identical to wg2025 Xben.wa at the same index; 31 changed, 58/59 new).
  Loader 0x40bcd2(obj 0x4917b0, n) → 0x4318e5 → 0x401000 (record/frame pointers), play 0x401e5d.
  Entries 52..56 = 216x50 weather banners: 0x449f91 plays `0x34 + weather` at (108, 25) when the weather changes.
  Fixed use: entry 45 (0x423b94, 0x42b7e5).
* DT.e5: Ls12, 60 KoeiAnim: 7..59 byte-identical to Meff.e5, 0..6 new single pictures with an embedded BMP24
  (0: 336x48 rocks strip, 1: 96x144 building, 2: 3 dashed 48x48 marker frames, 3: 48x48 cage, 4-6: 48x48 ice).
  No direct reference to the name 0x48bbfa "DT.E5": **0x40da9a patches the Meff loader's code** (byte 0x40bd21 =
  0xfa → name pointer 0x48bbfa; byte 0x40bd34 = 0xb7 → `movzx ecx, word`), calls 0x40bcd2 with `n - 1`, then
  restores the bytes. Used for 40 animated object slots (0x46cea4 → slot records; word +0x12 = DT number, 1-based;
  0 removes) set by script handler 0x4295fb (arg 0 = slot 0..39, args 1/2 = position, ×48 in battle (0x40b922),
  negative = copy from a unit) and reloaded by 0x4051ee.
* Output `xben/NN/img_KK.png`, `dt/NN/img_KK.png` (RGBA, key → alpha 0) + `alpha_KK.png` (L, raw maps, unused).

### 7.3 Mcall00-22.e5 → `effects/mcall/`
* Raw KoeiAnim files (not Ls12). 0x40eae0(v, '2') formats `E5\MCALL%02u.E5` (the digit of the format at 0x48b88d
  is patched) and opens it in player object 0x492788 (0x402a24 → stream thread 0x41295c: header 0x40273f,
  pictures 0x4027c9/0x4025a7); play 0x403035, frame 0x402b83. 0x40eab4 calls it with '3' (`MCALL%03u.E5`, number =
  the unit's person word, 25% chance via 0x47fb32(0x19), for a flag at +3 of the action) — no 3-digit files ship.
* Sizes: 240x240 (00-03, 11), 300x300 (04-09, 12-22), 320x240 (10). The shipped strategy table uses 00-08 and 11.

### 7.4 Strategy → animation (0x421496; tables from System.ini MgMeff/MgMcall)
* `mcall[s]` = byte VA 0x4d19f0 + s (file 0xA31F0), `meff[s]` = VA 0x4d1960 + s (file 0xA3160), 144 strategies;
  category `MgID[s]` = VA 0x4d1570 + s.
* `c = mcall[s]`: 255 → no animation at all. 100 ≤ c < 255 → Mcall(c % 100) first (flag +0x554 set in 0x425627
  unless the action result is 0x2b), then for category 12 only 0x4216c0 plays 8 Meff entries
  `[8, 23, 25, 26, 27, 33, 17, 10]` on the targets whose effect byte (+0x401) is `[0x40, 0x49, 0x4a, 0x4b, 0x4c,
  0x48, 0x57, 0x50]` respectively. Then for any c ≠ 255: `e = meff[s]`, e ≠ 255 → Meff[e] on every target cell.
  c < 100 means "no Mcall" (System.ini).
* Exported as `strategy_effect_table.meff/.mcall/.category/.category12_multi`.

### 7.5 Diagrams, weather, map patches
| file | content | loader / index rule | output |
|---|---|---|---|
| Hitarea.e5 (33 × 64x64 PNG RGB) | reach diagrams (targetable cells) | 0x46fc61(index, buf, slot, name) mode 0 (no key). Unit info 0x477b7f: index = class record byte +1 (attack range type), slot 5. Strategy info 0x46fa82: index = strategy record byte +0x0c (0xff → 16; index ≥ count reads entry 0 per 0x41fc89), or 11 when record byte +0x0f == 0x28 | `ranges/attack/NN.png` |
| Effarea.e5 (10 × 64x64 PNG, alpha 225-255 ignored) | effect-area diagrams | same loader. Unit info: index = 0x407835(person) (attack area type), slot 6. Strategy info: record byte +0x0d & 0x0f (0xff → 16 → entry 0); 0 when byte +0x0f == 0x28 or (dialog flag == 0 and category 0x1a) | `ranges/strategy/NN.png` (opaque RGB) |
| Tr.e5 (11 × 64x64 PNG; 0..9 = Effarea 0..9) | RPG-scene picture objects | script handler 0x425bf2: arg0 < 8 → actor slot 0x6a + arg0 (0x426aa8), actor word +0x3a = Tr entry; 0x42789d loads it (mode 10, keyed), one frame W x H. (Slots ≥ 0x72 load U_SELECT.E5 the same way with 10 frames of H/10, 0x42a049.) | `tr/NN.png` |
| Weather.e5 (5 × 216x200 raw 8-bit; = wg2025 Xthree.wa) | weather panel, 4 frames of 216x50 | 0x449ef0, mode 10: entry = weather = byte table VA 0x48e100[climate*6 + level] (0x41553b); 0 clear, 1 cloudy, 2 rain, 3 heavy rain, 4 snow | `weather/N.png` |
| Gate.e5 (192 × 144x144 JPEG) | 3x3-cell terrain-change patches | 0x4376ea loads (mode 10) and cuts into 48x48 cells (0x473d4a, 0x40d344 = /48); 0x437779 copies the cells around the centre cell into the map's cell buffer (0x40162c + cell*0x1b00), skipping cells outside the map; 0x42a8ed darkens for night/fog. Patch code v (change record +4, table VA 0x4b3d21, 250 × 5 bytes): **apply = entry 2v−8** (0x4563ff; reload 0x456e7c), **restore = entry 2v−7** (0x4567dd); v < 4 or > 200 = small marks, not Gate. Entries 16/17 (left column) and 46/47/68/69 (top row) have colour-key cells: map-edge patches whose keyed cells fall outside the map. | `map_patches/NNN.jpg` (bytes as stored) |

### 7.6 `effects/index.json`
`{anim_format, see_also, strategy_effect_table: {source, rule, meff[144], mcall[144], category[144],
category12_multi: {unit_effect_codes[8], meff[8], rule}}, xben|dt|mcall: {source, dir, notes, anims: {"NN": {size:
[W,H], delay_ms, id, sound, images, alphas, own_palette, storage: raw8|bmp24|png, alpha_source: key|png, source,
records: [{image, layer, p2, p3, mode, dx, dy, cue, opacity}]}}}, ranges_attack|ranges_strategy|tr: {source,
size, files, role}, weather: {source, files, layout, rule, role}, map_patches: {source, role, rule, key_cells,
patches: [{entry, file, size, patch_code, state: changed|original, key_cells?}]}}`.

Differences from rea's file: `strategy_effect_table.values` is replaced by the two arrays `meff`/`mcall` (rule
above); records gain `dx, dy, cue, opacity`; anims gain `sound, storage, alpha_source`; new `dt`, `tr`;
`map_patches` entries are JPEG files with no palette/`idx` images (`palette_guess` gone); `items32` moved to the
ui converter.

## 8. Icons, terrain pictures and UI pieces (`tools/gfx66_ui.py`: categories icons, terrain, ui)

### 8.1 Icons (Item.e5, Mtem.e5, Cmdicon.dll, U_select.e5[30])
* **ImageList builder 0x40aa0b(name, count, masked, size, fixed)** (hand-written asm, read from the
  disassembly; Ghidra loses the stack args). `size < 0x10` → icon edge `(size+1)*16` (0 = 16, 1 = 32), else
  `size` px. `fixed == -1` → icon i = archive entry **`2*i + size`**, decoded with mode 10 by 0x4789d6 (colour
  key (247,0,255), tolerance < 10 per channel, 0x4033dc); `fixed != -1` → one entry cut into a vertical strip of
  `count` icons. `masked` adds ILC_MASK (mask from the key, 0x40a13b). An entry index past the archive end reads
  entry 0 (0x41fc89).
* Lists built at 0x40b5ac:
  | list | call | args | content |
  |---|---|---|---|
  | 0x492e0c | 0x40b5c4 | MTEM, 256, unmasked, 16 | strategy small icons (drawn opaque) |
  | 0x492e10 | 0x40b5e9 | MTEM, 256, masked, 32 | strategy large icons |
  | 0x492e18 | 0x40b60e | ITEM, 256, masked, 16 | item small icons |
  | 0x492e14 | 0x40b633 | ITEM, 256, masked, 32 | item large icons (also the game's 32x32 item pictures) |
  | 0x492e1c | 0x40b655 | U_SELECT, 9, masked, 16, fixed 30 | 9 list icons (0x44d6e6 draws 7/8 = unchecked/checked box) |
  | 0x4b68d0 | 0x46c644 | U_SELECT, 30, unmasked, 48, fixed 31 | terrain pictures (terrain list dialog 0x46c520) |
* Item.e5: 512 BMP24 = 256 items × (16x16, 32x32), key (247,0,255) (some (255,0,255), keyed by the tolerance).
  Mtem.e5: 176 BMP24 = **88 strategies** × (16, 32); ids 88..255 fall back to entry 0.
* **Cmdicon.dll** (resource-only DLL, LoadLibraryA at 0x475311, handle 0x500abc): 29 8-bit RT_BITMAPs —
  21..24 = 单挑 buttons 攻击/突击/防御/回避 (70x24), 31..52 = 舌战 card/command buttons (故事/道理/时节 小中大,
  镇静, 愤怒, 诡辩, 大喝, 无视, 故事, 道理, 时节, 话术, 熟虑, "== =="), 61..63 = 66x41 big 故事/道理/时节.
  0x42b1a0: `BM_SETIMAGE` with id `21 + n` (duel, [0x505fcc] != 1) or debate `31 + value` / 0x32 / 0x34;
  0x452d6a: `STM_SETIMAGE` on dialog item 0x56b with 61..63 or 45..48. Opaque (button bitmaps).
  (wg2025's CmdIcon.dll held five 16x16 command icons — a different thing.)
* Output: `icons/{items,strategies}/{small,large}/NNN.png` (RGBA; items keyed both sizes, strategies small
  opaque / large keyed), `icons/commands/NNN.png` (NNN = resource id, opaque RGB), `icons/list16/NN.png`.
  `icons/index.json`: `{rule, sets:{items|strategies:{source, count, entries, small_keyed, large_keyed,
  icons:[{id, small, large}]}, commands:{source, rule, count, icons:[{id, resource_id, file, size, role}]},
  list16:{source, rule, count, icons:[{id, file}]}}}`. Differences from rea: commands are 29 duel/debate
  buttons keyed by resource id (rea: 5 icons, id = rid−100); new set list16; items count 256 (rea 105),
  strategies 88 (rea 31).

### 8.2 Terrain pictures (U_select.e5[31], [14])
* U_select[31] = PNG 48x1440 = 30 frames of 48x48; ImageList 0x4b68d0 (above); **picture = terrain id**
  (order matches the CCZ terrain list: 0 平原 … 13 大河 … 26 火; 27..29 mod additions). Replaces Mapatr.dll.
* U_select[14] = JPEG 12x360 = 30 frames of 12x12 (opaque, mode 0): **battle overview map** 0x41e7fe draws
  every Hexzmap cell as the 12x12 tile of its terrain (loaded by 0x41e929 into block 0x48b100 at +0x642,
  tiles at +0x4380 + t*0x1b0), then deployment slots `i` (table 0x507680: x, y, colour; ≤ 20) as 12x12 digits
  `i+1` from U_select[12] (colour 0) / [13] (colour 1). This is the 6.6 replacement of wg2025's Xixi.wa minimap
  (12 px per cell instead of 6).
* Output `terrain/NN.png` (48x48 RGB), `terrain/mini/NN.png` (12x12), `terrain/index.json`:
  `{source, rule, note, tiles:[{terrain, file, size, source, name_guess}], mini:{source, rule, cell:12,
  tiles:[{terrain, file}]}}` (rea: `tiles[].resource_id` → `source`; `mini` is new).

### 8.3 UI pieces
#### Ekd5.exe RT_BITMAP
106 (288x28) / 302 (288x24) toolbar strips of 12 24px buttons (palette[0] black, opaque), 341..344 48x48
shop buttons 卖出/买进/装备/出兵, 350/351 16x16 red/blue bird marks (palette[0] = (247,0,255) → keyed).
→ `ui/exe/<id>.png`.

#### Mark.e5 + Mark.DEC (the 6.6 counterpart of wg2025 Kao.wa)
* Mark.e5 is **not** Ls12: 0x52f20 bytes of raw 24-bit BGR pieces, rows top-down, each row padded to 4 bytes.
  Mark.DEC (192 B) = 12 records of 16 bytes `u32 offset, u16 w, u16 h, u16 bytes/pixel (3), 6-byte GBK name`
  — an editor directory; **the exe never reads Mark.DEC**.
* Loader 0x42b734 reads the whole file into buffer block 0x48b110 (getter 0x4015c5; 0x4015da(off) = base+off);
  Weather.e5 is loaded behind it at +0x52f20 (0x449ef0). Code addresses pieces by hard-coded offsets:
  | # | name | size | role | offsets used |
  |---|---|---|---|---|
  | 0 | 条状物 | 2x84 | colour bars | |
  | 1 | 花色 | 48x48 | window background pattern tile (dove) | 0x2a0 |
  | 2 | 小遮罩 | 48x192 | 4 masks (water, tall grass, grass, snow) over the lower part of 48x48 unit frames (unit draw 0x451347 → 0x4302fc) | 0x6ea0 |
  | 3 | 大遮罩 | 64x256 | same for 64x64 attack frames | 0x119a0 |
  | 4–6 | 小船/小兰船/大兰船 | 48x288, 48x288, 64x384 | 6-frame boats drawn under a unit on terrain 13 (大河) (0x451347 → 0x403479, mirrored right) | computed |
  | 7 | 标志 | 48x192 | 4 frames: sand window tile, red/grey/white cell frames | 0x3ada0, 0x3c8a0, 0x3e3a0, 0x3fea0 |
  | 8 | 标志动 | 48x384 | 8 frames: animated corner marks / coloured cell highlights | |
  | 9 | 气泡 | 24x48 | 2 speech-bubble frames | 0x4f1a0, 0x4f860 |
  | 10 | 经验 | 16x96 | icons: 0 sword, 1 armour (status 0x4503cf); 2..5 fire/water/?/earth (unit info 0x45576d, greyed when the flag is clear) | 0x4ff20, 0x50220, 0x50520+n*0x300 |
  | 11 | 单挑框 | 16x160 | duel frame: ◀ 16x16, ▶ 16x16, left cap 16x64, right cap 16x64 (= Kao.wa 0x198c0..0x1a2c0, identical shapes) | 0x51120, 0x51420, 0x51720, 0x52320 |
* **Window background** (0x473202(x, y, w, h, flag, …)): the rect is tiled with 48x48 pieces — Mark 0x2a0 (花色)
  if `flag`, else Mark 0x3ada0 (标志 frame 0, sand) — then the border is drawn with frame glyphs.
* **Pattern option** (0x40abdc(n, save)): `n < 4` → Logo.e5[8+n] (48x48, mode 10) is copied over Mark 0x2a0;
  `n ≥ 4` → filled with RGB(212,208,200) (0x44cb85(0xd4d0c8, 0x900, buf)). n = byte 3 of `SV\SV.E5S`
  (0x41a280(3); a fresh file has 0 there, 0x42225a); set from the options dialog (0x41ba11 / 0x41bd4e / 0x44f939,
  0x41a1c6(3)). Startup 0x40251c only reloads when n differs from the current value at 0x492e20 (bss, 0), so
  with the default n = 0 the built-in Mark 花色 stays — it is the same dove picture as Logo[8] (small colour
  differences). Patterns: 0 dove, 1 grey camouflage, 2 lattice, 3 diamond knot, ≥4 plain grey.
* Output `ui/mark/NN.png` (RGBA, key transparent).

#### U_select.e5 (32 entries; = CCZ U_select.e5, wg2025 Qusi.wa)
| entry | content | user |
|---|---|---|
| 0–2 | 50x50 slot frames for the 选择武将 grid, **stored as 100x25 JPEG** = the 7500 bytes of a 50x50 picture (the dialog blits 50x50 from the decoded bytes) | 0x45eade |
| 3, 4 | 选择武将 (RT_DIALOG 236) backgrounds 512x296 (item 0x43f) / 512x128 (item 0x441), mode 0 | 0x45eade |
| 5–8 | 288x144 landscapes, entry `5 + [0x500ae8]`; 0x41d947 copies 48x48 pieces | 0x40a52e |
| 9, 10 | 344x84 parchment message boxes (mirror pair); dialog 0x42d3f5 picks UI buffer +0 / +0x152a0 | 0x43e86d |
| 11 | title sub-menu buttons 176x44 × 9 (0–3 items, 4–7 highlighted, 8 blank); item i at y = 0x58 + 64 i (0x404c33) | 0x42bc94 |
| 12, 13 | 12x12 digits 1..20 (deployment slot numbers, colour 0 / 1) | 0x41e929 |
| 14 | 12x12 terrain tiles (overview map) | 0x41e929 |
| 15–19, 22–24 | UI buffer pieces: 48x10 bar frame, 48x48 watchtower/trap, 24x24 icons, 16x16 marks, 48x48 fire / burning boat frames, 600x84 white text box (big-portrait talk 0x42d0a9), 48x48 path arrows (10), 12x12 stat arrows (12) | 0x43e86d |
| 20 | 48x48 fire / burning boat frames (map objects; frame sets 0x40dd39) | 0x40dde5 |
| 21 | 12x12 digits 0..9 | ? |
| 25–29 | 16x16 sword icons | ? |
| 30 | 9 icons 16x16 → icons/list16 | 0x40b655 |
| 31 | 30 terrain pictures → terrain/ | 0x46c644 |
* UI buffer (block 0x48b0d0, getter 0x401521 / 0x401536(off)): 0x43e86d loads entries 10, 9, 12, 15, 16, 17,
  18, 19, 22, 23, 24 back to back (table 0x43e916, sizes 0x43e8e6): +0, +0x152a0, +0x2a540, +0x2adb0, +0x2b350,
  +0x2e950, +0x30450, +0x30d50, +0x3e550, +0x633f0, +0x741f0.
* Script op 0x425b66 places U_SELECT entries as scene objects in actor slots 0x72..0x7f (picture = entry
  byte actor+0x3a, loader 0x42789d), TR.E5 likewise in slots 0x6a..0x71 (0x425bf2); reloaded after a load at
  0x42a049.
* Output `ui/u_select/NN.png|jpg`: entries decoded with mode 10 → keyed PNG; mode-0 JPEGs copied as .jpg.

`ui/index.json`: `{items:[{source, resource_id, file, size, keyed_index0, role}], mark:{source, loader, key,
pieces:[{index, name, offset, size, frame_size, frames, file, role, exe_offsets}]}, u_select:{source, decode,
ui_buffer, entries:[{entry, file, size, stored, keyed, decode_mode, role, loader}]}, compat:{note, files:[{file,
from}]}}` (rea: `items` only, plus mark/xres DLL groups).

#### Compatibility copies (for the existing Godot code)
* `effects/kao/198c0_16x16.png`, `199c0_16x16.png`, `19ac0_16x64.png`, `19ec0_16x64.png` ← Mark[11] slices;
  `effects/kao/1abc0_48x48.png` ← Mark[1] (花色, default window pattern).
* `effects/qusi/03.jpg` ← U_select[3] (same entry number as wg2025 Qusi.wa[3]; the 选择武将 background).
  Note: the generic 6.6 window background is the tiled 48x48 pattern (0x473202), not this picture.
* `effects/items32/` is not produced: item pictures are the Item.e5 32x32 list = `icons/items/large/`.


## 9. File → role summary
| file | role | format |
|---|---|---|
| Unit_mov/atk/spc.e5 | battle unit sprites | Ls12, 717 each, BMP24 / raw 8-bit |
| Pmapobj.e5 | RPG actor sprites | Ls12, 922 = 461 × (front, back), 48×1280 |
| Hexzmap.e5 | battle terrain grids | Ls12, 126, `[W*3, H*3, W*H]` |
| MAP/mNNN.jpg | battle map pictures | JPEG, 125 (m109 missing) |
| E5/Mmap.e5 | story CGs + RPG scene backgrounds | Ls12, 852 × 640×400 BMP24/JPEG |
| E5/Pmap.e5 | RPG scene grids | Ls12, 812 × (16 + 100×100 u16) |
| E5/Face.e5 | 120×120 portraits | Ls12, 700 BMP24 |
| E5/Fb.e5 | 192×272 portraits (3-portrait dialog) | Ls12, 700 BMP24 (592 = Face.e5) |
| E5/Logo.e5 | title, emblems, game over, window tiles, duel backdrops | Ls12, 40 JPEG/BMP24 |
| E5/Item.e5 / E5/Mtem.e5 | item (256) / strategy (88) icons 16×16 + 32×32 | Ls12, BMP24, entry 2i+size |
| Cmdicon.dll | duel / debate button bitmaps (ids 21..63) | PE resources, 8-bit DIB |
| E5/U_select.e5 | UI pieces, terrain pictures (31), overview-map tiles (14), list icons (30) | Ls12, 32 JPEG/PNG/BMP24 |
| E5/Mark.e5 (+ Mark.DEC) | UI/battle piece atlas (= wg2025 Kao.wa) | raw BGR24 rows, 12 pieces; Mark.DEC = editor directory |
| Ekd5.exe RT_BITMAP | toolbar strips, shop buttons, bird marks | PE resources |
| E5/Mcall00-22.e5 | full-screen strategy animations | raw KoeiAnim (8-bit / BMP24 / PNG pictures) |
| E5/Meff.e5 | effect animations (= wg2025 Xben.wa + 3) | Ls12 of KoeiAnim, 60 |
| E5/DT.e5 | animated map/scene objects (0..6 new, 7..59 = Meff) | Ls12 of KoeiAnim, 60 |
| E5/Hitarea.e5 / E5/Effarea.e5 | reach / effect-area diagrams | Ls12, 33 / 10 × 64×64 PNG |
| E5/Tr.e5 | RPG-scene picture objects | Ls12, 11 × 64×64 PNG |
| E5/Weather.e5 | weather panel backdrops (= wg2025 Xthree.wa) | Ls12, 5 × 216×200 raw 8-bit |
| E5/Gate.e5 | 3×3-cell terrain-change patches (= CCZ Nima) | Ls12, 192 × 144×144 JPEG |
| E5/Imsg.e5, Star.e5, Data.e5, SETTING.E5 | data (other tracks) | — |

## 10. Open questions
* Unit side ↔ colour (entry g*3 + side): which army gets which value is decided by the battle code.
* 64×64 attack-frame anchor (−8,−8) and the RPG frame address inside a cache slot: CCZ/wg2025 conventions, not
  re-verified in the 6.6 blitters (the actor transform is confirmed through its inverse, §5.2).
* What sets the `SV\SV.E5S` emblem bytes (game clears?) and dword 0x505eec (picture bank): data/script side.
* Logo[12] has no loader; Pmapobj characters 274–276/457 are partly corrupt in the original.
* U_select[5..8] (288x144 landscapes): which screen; selector [0x500ae8] has no direct xref (set via a
  computed address / script memory op).
* U_select[21] (digits 0–9) and [25..29] (16x16 swords): users not found by string xref (loaded by index
  through other archive handles?).
* Mark[8] 标志动 and Mark[0] colour bars: users not located (computed offsets).
* Element names of Mark[10] frames 2..5 (flag meaning in 0x45576d / 0x419587).
* Terrain names 25, 27..29 (data track).
* Mcall obj+0x4c (makes layer < 40 records take the blended path) is only ever cleared (0x402537) — assumed 0.
* DT object drawing/looping code and the exact meaning of handler 0x4295fb's args 3..8 not traced (script track).
* Effarea/Hitarea indices for strategies are read from the strategy record (byte +0x0c/+0x0d) — field names for the
  data track; "record byte +0x0f == 0x28" condition not identified.
* 0x40eab4's per-person `MCALL%03u.E5` cut-ins: trigger conditions only partly read (no files ship).
