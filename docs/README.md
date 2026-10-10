# Documentation

## Guides

| Document | For | Contents |
|---|---|---|
| [PLAYING.md](PLAYING.md) | players | starting the game, title screen, controls (mouse, keyboard, touch), story scenes, battles, 环境设定, duels and 练武场, saving, troubleshooting |
| [BUILDING.md](BUILDING.md) | builders | exporting the macOS, iPhone and Android apps; smoke tests; re-generating `game/assets` from the original game; the state of the GitHub Actions workflow |
| [ARCHITECTURE.md](ARCHITECTURE.md) | developers | how the code works: emulated memory, script VM, stages, UI, source map |
| [DEVELOPMENT.md](DEVELOPMENT.md) | developers | debug options, automated play-through tests, touch shell, reverse-engineering workflow |
| [HD_GRAPHICS.md](HD_GRAPHICS.md) | builders | the HD art mechanism inherited from the wg2025 port; no HD pack exists for this game yet |

## Reverse-engineering specifications

These record what was learned from the original engine (`orig/Ekd5.exe`, the community "6.6 engine") and the data
files, with the addresses each fact comes from. They are the reference the code is written against.

| Document | Contents |
|---|---|
| [NOTES.md](NOTES.md) | Overview: the executable's sections and code conventions, the analysis tools, the data files and the mod's own notes, id conventions |
| [memory.md](memory.md) | The memory map the port emulates: sections, record getters, person and battle-unit records, the scripts' field interface, the game-state block, the 0x501000 block, save files |
| [rules.md](rules.md) | Data tables: persons, items, shops, classes, class families, strategies, terrain, texts (`Data.e5`, `Star.e5`, `Imsg.e5`, tables in the exe) |
| [eex.md](eex.md) | The EEX scenario scripts: files and scenario progression, container format, execution model, the opcode reference, 0x72 信息传送, variables and the memory scripts poke, config EVs 4016–4095 |
| [engine_notes.md](engine_notes.md) | Opcodes whose names mislead, interpreter quirks, differences from the wg2025 port, script-side findings |
| [gfx.md](gfx.md) | Every graphics format: unit sprites, portraits, story scenes, full-screen pictures, effects and animations, icons, terrain and UI pieces; the file → role map |
| [battle.md](battle.md) | Battle rules: physical attacks, strategies, status effects and buffs, items in battle, EXP and level-ups, movement, terrain and weather, turn housekeeping |
| [skills.md](skills.md) | The effect system: 特效 and item effects, where a unit's skills come from, 必杀, the effect query, the full catalogue |
| [ai.md](ai.md) | Battle flow, sides and action order, AI modes, the AI turn of one unit, the player phase and its map displays (the 环境设定 display options) |
| [duel.md](duel.md) | 单挑, 练武场 and 舌战: the scripted duel screen, the training-ground dialog (普通模式 / 单挑模式), the item duel, the unused S-form duel |

Addresses are virtual addresses in `Ekd5.exe` (image base 0x400000). Tags used in the specs: **[C]** confirmed in
the code, **[D]** from data or the mod's own notes only, **[S]** from save files, **[G]** guessed or inferred. The
wg2025 port's documents (in the `rea` repository) describe the CCZ concepts that carry over, but their addresses
and layouts do not.
