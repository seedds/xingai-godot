# Architecture

How the Godot reimplementation is put together. The reverse-engineering facts it relies on (file formats, script
opcodes, formulas, AI) are specified in the documents listed in [README.md](README.md). This page is about the code
in `game/src/`.

## Design in one paragraph

The mod's 249 scripts do not only call high-level opcodes: they also read and write raw engine memory, poking
person records, battle units, flags and variables by address. So the reimplementation keeps the game state in an
**emulated byte image of the original engine's memory**, laid out exactly like the original. A script interpreter
runs the original (converted) scripts against it. Godot nodes render that state and handle input. Formulas and AI
are ported from the decompiled executable.

```
             ┌──────────── main.gd ────────────┐
             │ title · scenario loop · saves   │
             └──────┬──────────────────┬───────┘
        even n: R_###.json     odd n: S_###.json
                    ▼                  ▼
            StoryStage            BattleStage ── BattleActions · BattleStrategy · BattleAI · BattleInput
                    └──── extends ScriptHost ──┘         BattleView · BattleHUD · DuelLayer
                                                         Rules · Effects · Movement (formulas, 特效 query, flood)
                               │ op_<name>()
                            EexVM  (scenes → sections → bodies)
                               │
   Autoloads:  Mem (emulated memory) · Game (state, data tables) · Assets · Audio
                               │
                         GameUI (dialog, menus, popups, fades, video)
```

On iOS and Android the main scene is `touch/touch_shell.tscn` instead. It runs `main.tscn` inside a 640×480 `SubViewport` with
touch buttons beside it (see "Touch controls" in [DEVELOPMENT.md](DEVELOPMENT.md)). Code reaches the Main node
through `Game.main`, never `/root/Main`.

## Autoloads

| Singleton | File | Role |
|---|---|---|
| `Assets` | `core/assets.gd` | Loads converted data at run time: textures from PNG bytes, JSON, MP3/WAV, OGV video, fonts (system Chinese fonts with fallbacks; on mobile a bundled Noto Serif SC subset, `tools/subset_font.py`). Everything under `res://assets` is imported with `importer="keep"`, so files are read raw. With an HD pack in `res://assets_hd` (none exists for this game yet), `tex()` would substitute its 4× `.webp` at the original's logical size (see [HD_GRAPHICS.md](HD_GRAPHICS.md)). |
| `Audio` | `core/audio.gd` | BGM player (the original CD tracks as `audio/bgm/NN.mp3`) and a small pool of sound-effect players. |
| `Mem` | `core/mem.gd` | The emulated memory (below). |
| `Game` | `core/game.gd` | Static data tables (persons, classes, items, strategies, terrain …), the party and bag, scenario number, gold, and save/load. |

## Emulated memory (`core/mem.gd`)

`Mem.r8/r16/r32` and `w8/w16/w32` address one flat 32-bit space:

* **0x400000 …** – `assets/data/exe_image.bin`, the executable's sections mapped as the loader would, including
  all initialised data tables. Writes go into a copy.
* **0x01000000 …** – heap for the 1024 person records (0x48 bytes) followed by the 128 shops (0x28 bytes), one
  block as the original allocates them; the pointers to them live at 0x4cea00 / 0x4cea04 like in the original.
* **0x02000000 …** – the battle map buffer (0x640-byte header, the terrain at +0x640, the unit grid at +0xc80). It
  is reached through the buffer object at 0x48b140 like the original's, so scripts that read terrain through it
  see the real map, and terrain changes made during a battle are part of a save.
* Anything else lands in sparse 4 KB pages created on first write.

Important locations:

| Address | Contents |
|---|---|
| 0x4b0770 (`GS`) | game-state block: settings bytes (+0..+3), scenario counter (u16 +6), gold (+0xc), the bag (+0x13); [memory.md](memory.md) §6 |
| 0x492fc8 (`FLAGS`) | story flags as bits (flag i = bit 7 − i % 8 of byte i / 8) |
| 0x502000 (`EV`) | the mod's 4096 integer variables |
| 0x506000 (`PT`) | the mod's pointer table |
| 0x501000 … 0x531000 | the 6.6 engine's data block, saved raw: battle sprites per person (0x501000), display options (0x501a65), 必杀 SP (0x501c00), EV, PT, story sprites (0x50f800) …; [memory.md](memory.md) §8 |
| 0x4a7b20 (`UNITS`) | 250 battle-unit records × 0x30 bytes (slots 0–19 player, 20–59 allies, 60–249 enemies) |
| 0x4b3d08 | the battle object (result, round, turn limit, weather, phase, climate) |
| 0x497af8 | the strategy context (caster, targets, values, result codes) |
| 0x48b350 | sortie list (u16 person ids, 0xffff-terminated) |
| 0x4b0783 | the bag (item slots) |
| 0x4b3c80 | duel object |
| 0x4927f0 | the combat context (attacker / defender of the latest attack, the scripts' 攻防 tests) |

`Person` (`core/person.gd`) and `BUnit` (`battle/bunit.gd`) are **views**: thin objects whose properties read and
write the record in `Mem`. Every change a script makes by address is therefore visible to the engine, and the
other way round.

Saves (`Game.save_game`) store the memory ranges that hold game state (`Mem.SAVE_RANGES`), the person heap and
the extra pages as base64, plus the party, the inventory, the script variables, the scenario and the running
stage's own state. Saves are JSON with a version number, written through a temporary file; a small `.info.json`
beside each holds what the slot list shows.

## Script interpreter (`core/eex_vm.gd`)

The converter (`tools/eex.py`) turns each `RS/R_###.eex` / `RS/S_###.eex` into JSON: **scenes**, each with
**sections**. A section has a **condition list** and a flat **body** of instructions. `IF` carries its jump target
(`end`) and its condition (`cond`); `goto` carries a resolved target (scene, section, index).

The execution model follows the original:

* `poll()` evaluates every section of the current scene; the **last** one whose conditions all hold runs.
* A scene with a single section is linear: when its body ends, the next scene starts. Multi-section scenes are
  event loops left through `next_scene` / `goto_scenario`.
* Nesting is tracked at run time. `IF` pushes a level, `END` pops one, `ELSE` tests the last result at its level.
  A `goto` inside a block pops one level and continues at the target, possibly in another section.
* Each instruction is dispatched to `host.op_<name>(ins)`. Handlers may `await` (dialogue, animations, delays).
  Test ops return a bool. Handlers that return nothing count as true when used as an `IF` condition, as in the
  original. `vm.next_op` tells a handler which instruction follows (a run of story `actor_move`s walks in
  parallel and only the last one waits).
* Scenario scripts are parsed when a file starts and not kept in the JSON cache (a whole play-through's worth would
  take gigabytes).

`docs/eex.md` lists all opcodes; `docs/engine_notes.md` notes the ops whose parser names are misleading (for
example op 0x23 "play_music" actually plays a sound effect).

## Script host and stages

`ScriptHost` (`core/script_host.gd`) holds the opcode handlers shared by story and battle scripts: flags and
variables, `int_var_op` / `data_transfer` (raw memory access), dialogue and captions, choices, audio and video,
party and items, resources, class changes, and the special functions. `arg()` resolves `{"var": n}` operands
through EV variables.

### Story scenes (`story/story_stage.gd`)

* A 640×400 view at y = 40 of the 640×480 screen: background from `gfx/backgrounds` plus isometric actors
  (`RpgActor`, 48×64 frames). The foot point of half-cell (x, y, z) is `(8(x−y)+312, 4(x+y)−8z−152)`.
* After a poll finds nothing to run, the stage waits for a click on an actor. The click sets a flag in `GS` and polls
  again, so sections testing `test_clicked(pid)` fire.
* The toolbar is the original's (0x419959): 卖出 / 买进 / 装备 / 出征, shown in sortie mode. The original's menu bar is
  one system menu, opened by a right click, Esc or the **菜单** button. **出征** builds the sortie list
  (`build_sortie`, port of 0x418597) and sets the pending flag that the scene's own `test_pending` section
  consumes.

### Battles (`battle/battle_stage.gd`)

* **Scene 0:** deployment ops create the battlefield (map from `gfx/maps`, terrain, units), then the opening events
  run.
* **Scene 1:** the turn loop (`battle_loop`, 0x44eee5) runs player, ally and enemy phases (side upkeep:
  ailments, buffs, poison, regeneration). At each phase start and after each unit's action `checkpoint()` runs the
  event poll 0x44c601 (victory and defeat checks, reinforcements, scripted dialogue); a section run that changed
  nothing ends the poll early (`Mem` write journal), with the same result as the original's repeated runs.
* **Scene 2:** the aftermath.

| Class | Responsibility |
|---|---|
| `BattleView` | map rendering, highlight overlays, battle tint / fog, cursor, camera and scrolling |
| `BattleInput` | player phase (0x44e0d9): select → move range → move → command menu; system menu |
| `BattleActions` | attacks, counters, criticals, 必杀, items, EXP, level-ups, walking, unit poses |
| `BattleStrategy` | the strategy engine (dispatcher 0x425627, every MgID handler, 军师技, auras, `script_anim`) |
| `BattleAI` | action order 0x44da7a and AIAct 0x43ad3b (docs/ai.md) |
| `BattleHUD` | hovered-unit panel, turn and weather, phase banners |
| `ResultPanel` / `RewardScreen` | the unit result window 0x450986 / the op 0x59 reward screen 0x44b5a8 |
| `DtPicture` | the op 0x72 sub 12 map objects (DT.e5) |
| `Mines` | modern-war mines: the record layer 0x510000, steps, explosions, item handler 10 |
| `BattleOverview` | 战场缩小图, the 1/8-scale map window 0x4603c1 (units, view frame, frame dragging) |
| `Rules` (`core/rules.gd`) | battle formulas: stat pipeline, damage, hit / critical rates, RNG and decks (docs/battle.md) |
| `Effects` (`core/effects.gd`) | the 特效 query 0x4101d9 (personal, 附加技能, class, item, 专属 / 套装, 模仿 / 屏蔽; docs/skills.md) |
| `Movement` | the flood 0x438484, zones of control, step-toward and paths |
| `EffectPlayer` | KoeiAnim animations (Meff, Mcall, DT) |
| `DuelLayer` | the 单挑 screen, implemented from `docs/duel.md` |
| `SortieScreen` | 出场选择, choosing who goes into battle |

## UI (`ui/`)

`GameUI` sits above the stages and owns the dialogue box (typewriter text, portraits), choice menus, popups,
banners, captions, chapter titles, fades and the video layer. The 6.6 script windows (`Win66`, `Text66`) are drawn
as the original's blitters draw them, and its Win32 dialogs (武将情报, 装备, 买进 / 卖出, 选择武将, 环境设定 …) are rebuilt
from their dialog templates on `Dlg66`. `PartyMenu` opens the out-of-battle dialogs; `UIStyle` styles the port's own
panels and buttons.

* "Click to continue" waits compare `Game.clicks`, a counter of presses kept by `Game._input`, instead of polling
  whether a button is held: a short trackpad tap is never missed, and the click that closed one box does not also
  close the next one.
* Choice menus scroll when they have more rows than fit on the screen (arrow keys, wheel, Page Up/Down) and cut
  over-long rows short. The dialogue box grows for long texts, and captions wrap.
* Chapter titles are drawn above the fade layer, since scripts show them on a black screen.

## Main flow (`main.gd`)

1. Boot: play the logo video, then the title screen (`TitleMenu`, the four picture buttons of `U_select.e5`). The
   title picture shows an emblem for each ending reached (recorded in `user://sv.e5s`, the original's
   `SV\SV.E5S`).
2. `_run_flow()`: for scenario *n* load `R_(n/2)` if *n* is even, else `S_(n/2)`; run it; then *n* + 1, unless a
   script jumped with `goto_scenario`.
3. Game over, endings, title and loading all go through `_stop_flow()`, which abandons the running stage and
   stops a looping sound effect. The
   scenario loop is tagged with a generation counter, so an orphaned loop can never continue.

Also in `main.gd`: window handling (the initial size is the largest of 3×–1× that fits the screen; after the user
resizes the window it snaps back to 4:3 so the picture fills it; full screen), the Space/Ctrl fast-forward
(`Engine.time_scale = 4`), the version label on the title screen (`application/config/version`, set by the release
workflow) and the `WG_SHOTS` debug screenshots.

## Source map

| Path | Contents |
|---|---|
| `main.gd` | boot, title, scenario loop, game over/ending, save/load menus, window |
| `core/` | `assets`, `audio`, `mem`, `game`, `person`, `eex_vm`, `script_host`, `ext_command`, `text_expand`, `rules`, `effects`, `data_transfer`, `special_funcs`, `person_attrs`, `sound_map`, `gbk` |
| `story/` | `story_stage`, `rpg_actor` |
| `battle/` | `battle_stage`, `battle_view`, `battle_input`, `battle_actions`, `battle_strategy`, `battle_ai`, `battle_hud`, `battle_attrs`, `bunit`, `movement`, `unit_sprite`, `effect_player`, `result_panel`, `reward_screen`, `dt_picture`, `duel_layer`, `training`, `sortie_screen`, `battle_overview`, `mines`; `grid` / `shapes` are wg2025 helpers still used by the input bot |
| `ui/` | `game_ui`, `dialog_box`, `choice_menu`, `title_menu`, `status_panel`, `party_menu`, `shop_menu`, `ui_style`, `video_layer`; the 6.6 windows and dialogs `win66`, `windows66`, `text66`, `choice_win66`, `history_win66`, `dlg66`, `sys_dialog66`, `person_panel66`, `unit_list66`, `item_list66`, `item_info66`, `item_text66`, `equip_dlg66`, `sortie66`, `kankyou66` |
| `touch/` | `touch_shell`: the main scene on iOS and Android |
| `debug/` | `test_runner`, `input_bot`, small test scripts such as `t_hd` (HD texture mechanism) and `t_resize` (window snapping); see [DEVELOPMENT.md](DEVELOPMENT.md) |
