# Development

Debug options, the automated test harness, and the reverse-engineering workflow. For the code structure see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Running from source

```sh
./run_game.sh                               # windowed; downloads the HD pack once, re-imports when a script changed
godot --headless --path game ...            # headless, for tests (after one `--import`)
godot -e --path game                        # open in the Godot editor
```

Godot prints to the terminal. Harmless noise you can ignore:
* `WARNING: Case mismatch opening requested file … app_userdata …` comes from the user-data folder name on a
  case-insensitive file system.
* `ObjectDB instances were leaked at exit`.

## Debug environment variables

All options are environment variables read at start-up, for example
`WG_START=21 WG_PARTY=0,8,13 ./run_game.sh`. They also work with the exported app's binary.

**Starting point**

| Variable | Effect |
|---|---|
| `WG_START=n` | Skip the title and start a new game at scenario *n* (even = story `R_(n/2)`, odd = battle `S_(n/2)`). At a battle, the party becomes the sortie list. |
| `WG_PARTY=0,8,13` | With `WG_START`: add these person ids to the party |
| `WG_SETFLAGS=755,…` | With `WG_START`: preset story flags that an earlier branch would have set |
| `WG_LOADSLOT=n` | Skip the title and load save slot *n* |
| `WG_STOP=n` | Quit when scenario *n* is reached |
| `WG_NOVIDEO=1` | Skip cutscene videos |
| `WG_HD=0` | Show the original art instead of the HD graphics pack (for comparisons) |

**Automatic play**

| Variable | Effect |
|---|---|
| `WG_AUTO=1` | Autoplay: the AI plays your phase, dialogue and waits are instant, menus pick automatically, story scenes click characters |
| `WG_DEMO=1` | Like autoplay but at normal speed (watchable) |
| `WG_RANDOM=1` | Autoplay picks random choices and clicks (otherwise deterministic) |
| `WG_GOD=1` | Player side invulnerable and strong. With autoplay: enemies are cleared after turn 12, and a battle still running at turn 60 jumps to its aftermath |
| `WG_SORTIE_P=n` | Chance (%) that autoplay presses 出征 when available (default 12) |

**Tracing**

| Variable | Effect |
|---|---|
| `WG_TRACE_SEC=1` | Print every script section that runs, with battle turn and phase |
| `WG_TRACE_TEXT=1` | Print dialogue, choices, popups and autoplay clicks |
| `WG_TRACE_OPS=1` | Print every executed instruction (very verbose) |
| `WG_TRACE_BATTLE=1` | Print battle details (deployment, joins, area tests) |
| `WG_MEMWATCH=4b2c50-4b2c74` | Report writes to an address range (hex) in the emulated memory |

**Test harness and bots**

| Variable | Effect |
|---|---|
| `WG_AUTOSAVE=1`, `WG_AUTOSLOT=n` | Flow-test harness (below): autosave to slot *n* (default 19; 0–9 are the player's saves) after each scenario, retry from it after a game over |
| `WG_INPUTBOT=dir` | Drive the player phase with synthetic mouse and keyboard events and save screenshots to *dir*. `WG_BOTTURNS=n` limits the turns |
| `WG_BOTMODE=load`, `WG_BOTSLOT=n` | Input-bot variant: load slot *n* from the battle menu |
| `WG_BOTMODE=duel` | Input-bot variant: stage a 单挑 between the first player unit and the first enemy, with screenshots |
| `WG_BOTMODE=victory` | Input-bot variant: open the system menu, pick 胜利条件 and screenshot the window |
| `WG_BOTMODE=touchcancel` | Input-bot variant for the touch shell: checks that taps on empty spots cancel and that 菜单 opens the system menu; prints `TOUCHCANCEL: PASS` and writes `touchcancel.txt` to the bot folder |
| `WG_FXTEST=3,5` | Input-bot variant: cast these strategy ids from the first player unit at the first enemy and screenshot their animations. With `WG_AUTO=1` instead of the bot (no screenshots) it prints each target's HP, status and buffs before and after, e.g. `WG_START=1 WG_AUTO=1 WG_GOD=1 WG_FXTEST=38,66` |
| `WG_SAVETEST=1` | Save at battle turn 2 and quit; run again with `WG_LOADSLOT=18` to check the restore |
| `WG_ACCEPT_SPAM=1` | Press Enter every 0.6 s |
| `WG_SHOTS=dir` | Save a screenshot to *dir* every `WG_SHOT_EVERY` seconds (default 3) |
| `WG_SHELLSHOT=dir` | Touch shell only: the same for the whole screen, side buttons included (`user://…` works on a phone) |
| `WG_SHELLSIZE=WxH` | Touch shell on a desktop: open the window at this size, e.g. `1734x800` (iPhone shape) or `1334x750` (16:9) |

The player's autosave (`user://autosave.json`, the title screen's 继续游戏) is neither read nor written while
`WG_AUTO`, `WG_DEMO`, `WG_START`, `WG_AUTOSAVE` or `WG_INPUTBOT` is set, so tests and bots leave it alone. Other runs,
`WG_LOADSLOT` among them, keep it up to date like normal play.

Example: watch the first battle play itself:
`WG_START=1 WG_DEMO=1 WG_NOVIDEO=1 ./run_game.sh`

## Automated play-through tests ("flow tests")

The scripts in `tools/` run the game headless in autoplay and log to `extract/`:

| Script | Purpose |
|---|---|
| `tools/flowtest.sh [seconds] [stop]` | Long autoplay run with autosave and retry: continues from slot 19 (`WG_AUTOSLOT`) if it exists, else (or with `FRESH=1`) starts a new game → `extract/flow.log` |
| `tools/flowtrace.sh [seconds] [stop]` | The same with section and text tracing → `extract/flow_trace.log` |
| `tools/flowpar.sh START STOP SLOT [seconds] [PARTY]` | Jump-start a scenario range (for running ranges in parallel) → `extract/flow_par_START.log` |
| `tools/flowres.sh SLOT STOP LOG [seconds]` | Resume such a run from its autosave slot |
| `tools/flowwatch.sh LOG…` | Print skips and errors as they appear, and `STALL` when a log is silent for 5 minutes (use with a log watcher) |
| `tools/gtest.sh t_name` | Run `game/src/debug/t_name.gd` under the headless test runner |

The autosave slot numbers are save files in the game's user folder: use **11 or higher**, since slots 0–9 are the
player's own saves. Run several ranges in parallel with bash, for example
`bash -c 'for r in "0 16 11" "16 32 12"; do set -- $r; tools/flowpar.sh $1 $2 $3 1500 & done; wait'`. The tests also
write `niuniu.bin` (the endings record).

Headless unit checks (`tools/gtest.sh NAME`): `t_parse` loads every script (catches parse errors anywhere),
`t_equip` checks the equipment codes of ops 0x3e/0x48, `t_strat` the strategy usability rules (0x420422, 0x41fec9),
`t_touch` the touch controls (map taps and drag-panning, menu taps, slides and drag-scrolling), `t_rpgwalk` story
walking (route order and facing per step, 0x429159), `t_dialog` the message box growing to fit long texts (the
9-line 胜利条件 window), `t_person` prints person stats.

Two checks need a window (they read rendered pixels or resize the window), so run them without `--headless`:

```sh
cd game
TEST=res://src/debug/t_hd.gd godot --path . res://src/debug/test_runner.tscn       # prints t_hd: PASS
TEST=res://src/debug/t_resize.gd godot --path . res://src/debug/test_runner.tscn   # prints t_resize: PASS
```

The harness (`WG_AUTOSAVE`) keeps random play moving:

* A **game over** reloads the last autosave and retries.
* A **battle** lost 3 times jumps to its aftermath on the next try.
* A **story scene** that fails 30 times (usually chained 单挑 mini-games) is skipped.
* A **story scene** with more than 2,500 autoplay clicks (an unsolved puzzle or hub) is ended.
* An **ending** in the last chapters stops the run.

Every skip prints a `== flow-test: …` line. A skip usually means random play can't meet a scripted objective (turn
limits, traps, puzzles, choice-dependent endings), not a bug. Look for `SCRIPT ERROR`, `ERROR` or a `STALL`
instead.

Tips:

* Jump starts lack the story flags and levels of a real play-through. Start at a story scene (even *n*) where
  possible, and use `WG_SETFLAGS` for branch scenes.
* Godot's output is block-buffered when redirected to a file. To see the last line before a hang, run under a
  pseudo-terminal: `script -q /dev/null godot … < /dev/null > log`.
* A hung run at 100 % CPU is a script loop; at ~0 % it is an `await` that never completes. `WG_TRACE_OPS=1` shows
  where.

## Touch controls and the phone builds

On mobile, `project.godot` runs `res://src/touch/touch_shell.tscn` (`run/main_scene.mobile`) instead of
`main.tscn`. `TouchShell`:

* Lays out in window pixels. The window has no content scaling there (`window/stretch/mode.mobile="disabled"`).
* Runs `main.tscn` inside a `SubViewport` with `size_2d_override` 640×480. The game still sees an exact 640×480
  screen, and it is drawn at the display's resolution, so HD art and text stay sharp.
* Puts the 4:3 picture in the middle and the buttons in the side bars, clear of the notch. The original's right
  click does two jobs, and each gets its own button:
  * **菜单** (top left) calls the stage's `open_menu()`. It is only enabled while the stage's `menu_ready()` is
    true: a story scene waiting (`_waiting_click`), or the battle player phase at its top level (`BattleInput.idle`).
  * **返回** sends Esc; every cancel path also takes `ui_cancel`. It is dimmed while 菜单 is enabled.
  * **快进** toggles `Game.fast_toggle`, which `Game.skip_held()` treats like holding Ctrl.
  * Android's back button or gesture (`NOTIFICATION_WM_GO_BACK_REQUEST`) activates 返回, or 菜单 where 返回 is
    dimmed. `application/config/quit_on_go_back` is off, so it never quits the app.

Game-side switches:

* `Game.touch` (set by the shell) makes `BattleView` click a cell on release and pan on drag, and show the tapped
  cell's info panel.
* It also makes `ChoiceMenu` pick on release and scroll long lists by dragging. Desktop input is unchanged.
* Tapping an empty spot cancels. Outside a cancellable `ChoiceMenu` (pressed and released there) the menu closes.
  Outside the highlighted cells while picking a target, `BattleInput._cancels` treats the tap as a right click.
* `Game.main` replaces `/root/Main`, which does not exist inside the shell.
* `Game._input` ignores presses on the side bars.
* On mobile, `Assets` halves HD textures over 4096 px and keeps a smaller HD cache.

Try it on the desktop; the mouse acts as a finger, and right click still works:

```sh
cd game
WG_SHELLSIZE=1734x800 godot --path . res://src/touch/touch_shell.tscn
# the input bot through the shell (taps on release, 菜单 for the system menu):
WG_START=1 WG_ACCEPT_SPAM=1 WG_NOVIDEO=1 WG_INPUTBOT=/tmp/bot WG_BOTTURNS=2 WG_SHELLSIZE=1734x800 \
  godot --path . res://src/touch/touch_shell.tscn
# tap-an-empty-spot checks in a real battle; prints TOUCHCANCEL: PASS, also written to /tmp/bot/touchcancel.txt:
WG_START=1 WG_ACCEPT_SPAM=1 WG_NOVIDEO=1 WG_INPUTBOT=/tmp/bot WG_BOTMODE=touchcancel WG_SHELLSIZE=1734x800 \
  godot --path . res://src/touch/touch_shell.tscn
```

Building and installing on a phone: `tools/build_ios.sh --device`; in the Xcode Simulator (native arm64, after
`tools/build_ios_sim_lib.sh` once): `tools/build_ios.sh --sim` (see [BUILDING.md](BUILDING.md)). Android:
`tools/build_android.sh --install` builds the APK and installs it on the connected phone or a running emulator; the
game's output is in `adb logcat -s godot`. Debug variables reach the iOS app through `IOS_ENV`. For example,
`IOS_ENV='{"WG_SHELLSHOT":"user://shots"}' tools/build_ios.sh --device` saves screenshots in the app's Documents
folder. Fetch them from a phone with
`xcrun devicectl device copy from --device UDID --domain-type appDataContainer --domain-identifier com.seedds.wagang --source Documents/shots --destination DIR`;
in the simulator they are under `$(xcrun simctl get_app_container booted com.seedds.wagang data)/Documents`. For
example, this plays one battle turn through the touch path with screenshots:
`IOS_ENV='{"WG_START":"1","WG_NOVIDEO":"1","WG_ACCEPT_SPAM":"1","WG_INPUTBOT":"user://bot","WG_BOTTURNS":"1","WG_SHELLSHOT":"user://shots"}' tools/build_ios.sh --sim`.

## HD graphics and releases

* `tools/get_hd_pack.sh` downloads the HD graphics pack into `game/assets_hd/`. `tools/upscale_assets.py`
  rebuilds it, and `tools/upscale.py` upscales single images for trying models. See [HD_GRAPHICS.md](HD_GRAPHICS.md).
* Every push to `main` that changes the game builds and publishes *Build N* for macOS, Windows, iPhone and Android; see
  "Automatic releases" in [BUILDING.md](BUILDING.md). Check a run with `gh run list --workflow release.yml`.

## Reverse-engineering workflow

The original executable is `wg2025/wagan.wa` (PE32, image base 0x400000). The mod's code lives in an extra
`.text2` section around 0x4d0000 and hooks the original code with `jmp` patches.

* **Ghidra (preferred):** `tools/ghidra/gdec.sh OUT.c 0x41973c 0x448524 …` decompiles functions headlessly. The
  first run imports and analyses the executable into `extract/ghidra_proj` (slow, once). The script uses Ghidra
  and JDK 21 from Homebrew unless `GHIDRA_INSTALL_DIR` / `JAVA_HOME_21` point elsewhere.
* **Quick disassembly:** `tools/venv/bin/python -I tools/disx.py 0x43640e 40` (capstone). `tools/cases.py`
  disassembles jump-table targets, and `tools/findins.py REGEX` searches instructions.
* **Data:** `game/assets/data/exe_image.bin` is the mapped executable, so `offset = address − 0x400000` reads any
  table the game uses. The same image is the game's emulated memory.
* **Scripts:** `tools/eex.py` also writes human-readable listings to `extract/eex_txt/`. The JSON in
  `game/assets/scripts/` is what the game runs.

Conventions:

* Findings go into `docs/` with the addresses they come from: `rules.md` for formulas and AI, `eex.md` for
  opcodes, `engine_notes.md` for op semantics and engine behaviour, `gfx.md` for formats, `duel.md` for the duel
  screen. Code comments cite the same addresses.
* **Adding an opcode:** implement `op_<name>(ins)` in `ScriptHost`, or in `StoryStage` / `BattleStage` if it only
  makes sense there. Read arguments with `arg(ins, i)` (resolves `{"var": n}`) or `sarg()`; test ops return a bool.
  An unimplemented op prints `EEX unimplemented op …` once.
* Script names in `opcodes.json` come from the original parser and can be misleading; trust the decompiled handler
  (see `engine_notes.md`).
