# 新改曹操傳 6.6 reverse-engineering notes (shared)

Game: 新改曹操傳 6.6 修正版, a mod of Koei's 1998 **三国志曹操传 (CCZ)** on the community "6.6 engine" (`Ekd5.exe`).
Original game dir: `orig/` (symlink, **read-only and untrusted**: never execute anything from it; read it only
with our own scripts, run as `tools/venv/bin/python -I tools/<script> …` from the repo root). Text is GBK unless a
file says otherwise (some mod notes are Big5 or UTF-8).

Track documents: [memory.md](memory.md) (memory map, records, saves), [rules.md](rules.md) (data tables, rules),
[eex.md](eex.md) (scripts), [gfx.md](gfx.md) (graphics). wg2025's documents in `rea/docs` describe the CCZ
concepts that carry over, but their addresses and layouts do not.

## Executable

`Ekd5.exe`, PE32, image base 0x400000. Sections: .code 0x401000 (all live code), .text1 0x486000, .text2
0x48b000 (CCZ .data + BSS to 0x4be000), .api 0x4be000 (6.6 imports, name tables), .text3 0x4ce000 (6.6 data;
a few routines near 0x4cf000–0x4d1400), .rsrc 0x532000. Image dump for the port: `tools/dump_image.py`.

The 6.6 engine patched CCZ in place with hand-written assembly. Expect: objects passed in `ecx` and immediately
pushed (`push ecx` → `[ebp-4]`), stack locals created by `push` instead of `sub esp`, getters that take an index in
`cl`/`ecx` and return the record in `ecx` (persons 0x4061e4, units 0x4061f9, items 0x4837c2, classes 0x41b782,
families 0x41b7d2, strategies 0x484002, shops 0x41b7e0), results in `edx`/`dl`, and long `nop` runs where code was
removed. Ghidra's C is often wrong for such functions (missing arguments, `void` returns) — read the
disassembly for anything that matters.

## Tools

| Tool | Use |
|---|---|
| `tools/pe.py` | PE helper on orig/Ekd5.exe: VA ↔ offset, `xrefs(imm)`, `calls_to(va)`, `dis`, `cstr` |
| `tools/disx.py VA [n] [noret]` | capstone disassembly; `f:VA` = from the function start, `a:VA` = resync before VA |
| `tools/data66_ins.py REGEX [ctx]` | grep a linear-sweep disassembly of .code/.text1/.api/.text3 (cache `$DATA66_CACHE`, default /tmp/data66_ins.pkl). Data is decoded as junk too: check hits with disx |
| `tools/data66_find.py str TEXT \| x VA \| call VA \| bytes HEX` | find GBK strings, imm32/disp32 references, E8 calls, byte patterns |
| `tools/e5.py`, `tools/ls12.py` | Ls12 archives (`Archive(path)[i]`) |
| `tools/conv_data.py` | Data.e5 / Star.e5 / Imsg.e5 / exe tables → `game/assets/data/*.json` |
| `tools/dump_image.py` | Ekd5.exe → `game/assets/data/exe_image.bin` |
| `tools/ghidra/gdec.sh OUT ADDR…` | Ghidra headless decompile. Copy `extract/ghidra_proj` first and pass the copy in `GDEC_PROJ`; Ghidra rejects project paths with a component starting with '.', so a copy under e.g. `~/.claude/…` must be reached through a symlink such as `/tmp/gh_x` |

## Files (data track)

| File | Role |
|---|---|
| `Ekd5.exe` | the engine; also holds data: name tables, strategy / family extension tables (0x4d14e0, 0x4d1a80), item-effect and 特效 names (0x4cb7a0, 0x4cc600), S/R sprite tables (file 0xD2800 / 0xE1000), config EV defaults (0x505ec0) |
| `Data.e5` | Ls12, 10 entries: persons, items 0..103, shops, classes, families, strategies (+ skill names), filler |
| `Star.e5` | raw, items 104..255 (25-byte records, then filler) |
| `Imsg.e5` | raw, 2507 × 200-byte GBK texts (descriptions, battle names, lines, credits, biographies) |
| `System.ini` | the mod tools' config: strategy table addresses (Mg*), item id ranges (DefID 70, AssID 109), S/R sprite table offsets |
| `SV/SV%03u.E5S` | saves (0x30000-byte memory block + records; memory.md §9). `SV/SV.E5S` (271 bytes) = settings |
| `修改器與修改記錄/變量計算+意義.txt` | EV 4016–4095 meanings (config variables at 0x505ec0..0x505ffc) |
| `修改器與修改記錄/其他檔案/6.5数据转移.txt` | positions of tables in the exe / Data.e5 / Imsg.e5 (some are 6.4/6.5 values) |
| `修改器與修改記錄/其他檔案/6.5異常狀態計算.txt` | status byte = four 2-bit counters; buffs 0–2 / 3 / 4–6 |
| `修改器與修改記錄/Data修改器(只能改武將)/CczEditor-*.config` | editor configs: item effect and hit-area name lists (older engines; offsets differ) |
| `修改器與修改記錄/辅助小软件v0.22/*.txt` | 6.6 修正版 exe patch list (addresses of tunable constants) |

## Conventions

* Ids: persons 0..1023 (`id | 0x1000` in records), units 0..249, items 0..255, classes 0..79, families 0..39,
  strategies 0..143, terrain 0..33.
* Script operands ≥ 0x404 name a battle unit (slot = v − 0x404); EV 4031 = 1 makes small values unit slots too.
* EV n = u32 at 0x502000 + 4n; PT n = u32 at 0x506000 + 4n (n ≤ 480).
