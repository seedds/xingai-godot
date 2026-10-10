# Documentation

## Guides

| Document | For | Contents |
|---|---|---|
| [PLAYING.md](PLAYING.md) | players | starting the game, controls, story scenes, battles, duels, saving, troubleshooting |
| [BUILDING.md](BUILDING.md) | builders | exporting the macOS app; re-generating `game/assets` from the original game |
| [ARCHITECTURE.md](ARCHITECTURE.md) | developers | how the code works: emulated memory, script VM, stages, UI, source map |
| [DEVELOPMENT.md](DEVELOPMENT.md) | developers | debug options, automated play-through tests, reverse-engineering workflow |
| [HD_GRAPHICS.md](HD_GRAPHICS.md) | builders | the 4× AI-upscaled graphics pack: how the game uses it, building and publishing it, which model is used for what |

## Reverse-engineering specifications

These record what was learned from the original executable (`wagan.wa`) and data files, with the addresses each
fact comes from. They are the reference the code is written against.

| Document | Contents |
|---|---|
| [NOTES.md](NOTES.md) | Overview: game directory layout, executable sections and the mod's `.text2` code, the file-name table, the Ls12 archive format, resource DLLs |
| [gfx.md](gfx.md) | Every graphics format: battle unit sprites, portraits, story-scene backgrounds and sprites, full-screen pictures, UI atlases (Kao, Qusi), effect animations, palettes; the file → role map |
| [eex.md](eex.md) | The EEX scenario-script language: files and chapter progression, container format, variables, the interpreter's execution model, the full opcode table, the memory map scripts poke |
| [rules.md](rules.md) | Data tables (persons, classes, items, strategies, terrain), growth, battle units, damage/hit/critical/double-attack formulas, strategies, ranges and areas, movement, experience and equipment levels, turn structure, status effects, battle script ops and the enemy AI |
| [engine_notes.md](engine_notes.md) | Opcodes whose parser names are misleading, other op semantics (audio, video, sortie, duel, join, special functions), the endgame structure and ending conditions, story-scene projection, sound ids |
| [duel.md](duel.md) | The 单挑 duel screen: ops, data layout, screen layout, every action/blow/special animation with timings and sounds, result and EXP, image filters |

Addresses are virtual addresses in `wagan.wa` (image base 0x400000). Tags used in the specs: **[C]** read from
code, **[I]** inferred, **[G]** guessed or approximated.

`images/` holds the screenshots used by the guides.
