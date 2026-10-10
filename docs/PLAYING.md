# Player guide

How to start the game and play it: the title screen, controls, story scenes, battles, duels, menus and saving.
For converting the game data and exporting the apps see [BUILDING.md](BUILDING.md).

The port follows the original 新改曹操傳 6.6 (its menus, windows and rules are those of the 6.6 engine); this page
describes how they are reached here, and what differs.

## Starting the game

There are no published downloads: the game data comes from your own copy of the original game.

* **From source** (macOS): put the original game at `orig/`, convert it (see the
  [README](../README.md#getting-started) or [BUILDING.md](BUILDING.md#re-generating-the-game-data)), then run
  `./run_game.sh` with [Godot 4.7](https://godotengine.org) installed.
* **macOS app:** export `build/XinGai.app` ([BUILDING.md](BUILDING.md#macos)) and open it.
* **iPhone:** `tools/build_ios.sh --device` builds the app and installs it on a connected iPhone (needs Xcode and
  an Apple developer account); `tools/build_ios.sh --unsigned` makes an `.ipa` for AltStore or Sideloadly.
* **Android:** `tools/build_android.sh --install` builds the APK and installs it over USB (adb); the APK can also be
  copied to the phone and opened there.

On a desktop the window opens at the largest of 3×, 2.5×, 2×, 1.5× or 1× the original 640×480 that fits the
screen. It can be resized freely; when you let go it snaps back to the game's 4:3 shape. **⌘F**, **F11** or
**Alt+Enter** toggles full screen. On iPhone and Android the game runs in landscape: the 4:3 picture fills the
screen height, with touch buttons in the bars on both sides.

The logo video plays first (a click skips it), then the title screen.

## Title screen

The title picture shows up to three emblems, one for each ending you have reached. The four picture buttons on the
right are the original's (`U_select.e5`); the mouse over one highlights it, and the arrow keys with Enter work too.

| Button | Action |
|---|---|
| **刀兵初現** | new game |
| **烽煙再起** | load a game: the list of the 10 save slots. When there is an autosave, a menu first offers **继续游戏** (continue from it) or **读取进度** (the slot list) |
| **沙場點兵** | the original's 环境设定 settings dialog (also in the battle system menu); 确定 keeps the settings for new games |
| **南山放馬** | quit (does nothing on iPhone and Android, where apps are not quit) |

A build stamped with a version (`.github/scripts/stamp_version.sh`, used by the release workflow) shows it
(版本 1.0.N) in the bottom-right corner; ordinary local builds show none.

## Controls

### Mouse and keyboard

| Input | Action |
|---|---|
| Left click / Enter | select, confirm, advance the text |
| Right click / Esc | cancel or go back. Where nothing is open: the system menu (story scene, empty battle cell); on a battle unit: its 武将情报 window |
| Arrow keys | move the battle cursor; move through menus |
| Mouse wheel / Page Up, Page Down | scroll long lists |
| Mouse at a screen edge / middle-button drag | scroll the battle map |
| Hold **Space** | everything runs 4× faster |
| Hold **Ctrl** | 4× faster, and text and waits skip ahead |
| Click / Enter / Esc during a video | skip it |
| **5**–**9**, **A**–**P** (in a battle) | toggle the display options (see [环境设定](#环境设定-settings)) |

### Touch (iPhone and Android)

Taps are left clicks. The side bars hold three buttons:

| Button / gesture | Action |
|---|---|
| **菜单** (top left) | the system menu. Only available at the top level: a story scene waiting for you, or your battle phase with no unit selected |
| **返回** (left) | cancel or go back, like Esc (also advances text and skips a video). Dimmed while 菜单 is available |
| **快进** (right) | fast-forward on/off, like holding Ctrl; lit while on |
| Back button / gesture (Android) | 返回, or 菜单 where 返回 is dimmed. It never quits the game |
| Tap a battle cell | a click, and shows the unit or terrain panel (what hovering does with a mouse) |
| Drag on the battle map | scroll the map (a drag never counts as a tap) |
| Drag up/down on a long list | scroll the list |
| Slide on a menu, lift | the entry under the finger is picked when you lift it, so a near-miss can be corrected first |
| Tap outside a menu or range | cancel: closes the menu (outside the unit's command menu it takes the move back); outside the highlighted cells while picking a target or a destination it stops picking |

## Story scenes

Story files (`R_###`) alternate with battle files (`S_###`). Some story scenes play by themselves; in others the game
waits until you click a character on the screen, and a scene keeps waiting until you click the one that moves the
story on. Dialogue windows show the speaker's portrait and name; text types out (a click shows the rest), and each
page waits for a click unless 会话窗口不自动关闭 is turned off in 环境设定.

**System menu** (right click / Esc while the scene waits; the **菜单** button at the top right, or 菜单 on a phone):

| Entry | |
|---|---|
| **武将一览** | the party list (部队情报一览); a row opens that person's 武将情报 window (装备 / 策略 / 兵种 pages) |
| **持有道具一览** | the items held (outside battle, items are only shown; they are used in battles) |
| **历史情报** | the chronicle of the story so far |
| **保存** / **读取** | save to / load from one of the 10 slots. Some scenes forbid saving ("目前禁止存档") |
| **练武场** | the training ground (below) |
| **回到标题** | back to the title screen |

**Toolbar (sortie mode).** When a battle is ahead the story usually switches to sortie mode, and four icon buttons
appear at the bottom right (from right to left; hover for the name). A scenario can hide some of them.

* **卖出** / **买进** – the shop: sell, or buy from the 武器店 and 道具店 tabs. Equipment is bought for a person who
  can use it and worn at once (the old piece goes to the warehouse, at most 200 pieces); items are bought and sold
  by count. Prices and goods depend on the chapter.
* **装备** – the equipment window: the warehouse list and a person panel. Click a usable item to wear it, click a
  worn piece to put it back; **自动装备**, **卸除装备** and **设为默认装备** act on the whole party.
* **出征** – march out. The sortie window **选择武将** lists the candidates (persons the story requires come first and
  cannot be removed); click to add or remove, right click for 武将情报, the two buttons sort the list. **决定**
  needs at least two thirds of the maximum; the scene then continues into the battle.

Many dialogue choices and battle results set story flags that decide later branches and the ending you reach.

### 练武场 (training ground)

From the story system menu (not in battles). It costs gold.

* **普通模式** – pick a member whose level is below the party's average and pay level × 10 gold for a fight of up to
  10 rounds against a training opponent, with 攻击, 策略 and 道具. Experience and level-ups are kept.
* **单挑模式** – the first party member fights a command duel against the trainer (攻击 / 突击 / 防御 / 回避); its
  progress is kept between visits.
* **自动提升** – pay (average level × 1000) gold to raise every member below the average to it.

Some scenarios also start training fights from the script.

## Battles

A battle starts with the deployment and the opening events. Then the turns run: your phase (我军阶段, with the
turn number, or 最终回合 on the last turn), then the allied and enemy phases. The victory and defeat conditions are
in the system menu (**胜利条件**). A lost battle usually ends in a game over.

**Your phase**

1. Click one of your units. **Blue** cells show where it can move, **red** cells what it can attack from there.
2. Click a blue cell to move there, or the unit's own cell to stay. Clicking elsewhere turns the unit that way.
3. Pick a command (greyed entries are not possible now):

   | Command | |
   |---|---|
   | **攻击** | attack a unit inside the red range |
   | **策略** | cast a strategy (the list shows the MP cost), then pick the target or area |
   | **道具** | use an item from the bag on the unit or a target in range |
   | **交换** | swap the weapon, armour or accessory with a neighbouring member ("装备不匹配" if one of them cannot use the other's) |
   | **围攻** | attack together with the units that can join in against that target ("不能围攻该部队" if none can) |
   | **必杀** | a 武将技 from the person's list (重击 and the skills learned), paid with 气 (SP); a class family with its own 军师技 uses that instead |
   | **待命** | wait |
   | **取消** | take the move back (also right click / Esc) |

4. Skills can grant a second move or another action afterwards. When no unit can act any more the game asks
   whether to end the turn; it can also be ended from the system menu.

**Information.** Hovering over a cell (tapping it on a phone) shows the panel of the unit there: portrait, class and
level, HP / MP / SP, the ailment counters (麻 paralysis, 禁 seal, 乱 confusion, 毒 poison), buff arrows (攻 防 精 爆 士 移)
and the terrain with its effect; on an empty cell, the terrain. Right click a unit for its 武将情报 window. The turn,
the turn limit and the weather have a panel of their own.

**System menu** (right click / Esc on an empty cell; 菜单 on a phone):

| Entry | |
|---|---|
| **结束回合** | end your phase |
| **检索未执行部队** | jump to the next unit that has not acted |
| **武将一览**, **持有道具一览**, **历史情报** | as in story scenes |
| **胜利条件** | the victory and defeat conditions |
| **战场缩小图** | the battle map at 1/8 scale (below) |
| **环境设定** | settings (below) |
| **保存** / **读取** | save / load, also in the middle of a battle |
| **回到标题** | back to the title screen |

**战场缩小图** shows the whole map with the units as coloured squares by side and a frame for the visible part. Drag
the frame to scroll the battle view; the window's caption bar moves it, its close box closes it. It opens by itself
at the start of a battle while 战斗时，自动显示战场缩小图 is on (the default).

### 环境设定 (settings)

The original's settings dialog; **确定** keeps the changes, **取消** drops them. The settings (except 加速 and 花色)
are part of the game state and saved with it.

* **听背景音乐** (music on/off) and **音量** (music volume) act at once.
* **会话窗口不自动关闭**: on, every text page waits for a click; off, pages advance after a time set by
  **讯息显示速度** (快 / 普通 / 慢), which also sets the typing speed.
* **武将移动速度** (快 / 普通 / 慢): how fast units walk.
* **战斗时，自动显示战场缩小图**: open the 战场缩小图 at the start of every battle.
* The list on the right holds the 21 display options, each with its hotkey (keys 5–9, A–P toggle them during a
  battle without opening the dialog):
  * **5** 显示生命条 – HP bars on the units; **6** 显示Buff状态 – buff arrows
  * **E** 显示行动顺序 – the order in which the AI units will act; **F** 显示AI仇恨 – each enemy's interest in the
    selected unit; **G** 显示危险区域 – tints the enemies that could hit the selected unit where it stands;
    **I** 显示AI方针 – the AI unit's orders in its panel; **O** 预览行动路线 – the path to the cell under the cursor
    (in the AI phases, to the AI unit's destination)
  * **D** 保留装备 – how 自动装备 treats the party's equipment; **H** 显示升级提示 – level-ups list the gains;
    **K** 连续使用功勋 – 功勋 converts into as many ability points as it pays for, not one at a time;
    **L** 跳过战斗过程 – no attack and strategy animations; **M** 暴击不语 – no line on a critical
    hit; **P** 极速移动 – units move without walking
  * The others (7–9, A–C, J, N) are stored but have no effect in the port yet. 听音效, 战斗时窗口自动最大化, 加速 and
    花色 are stored only as well.

## Duels (单挑)

When the story calls for one, two officers fight on the duel screen: the introduction with their names, then the
fight with speech bubbles. These duels are scripted and play by themselves; a click finishes a bubble early or moves
on. The winner may gain experience when the duel closes. Command duels where you choose the moves are fought in the
练武场 (单挑模式).

## Saving and loading

* **10 save slots** (存储进度 / 读取进度), from the story or the battle system menu, also in the middle of a battle;
  loading also from the title screen (烽煙再起). A save is written to a temporary file first, so a crash while
  saving leaves the old save intact; a damaged save, or one from a newer version of the port, is refused. The
  original game's save files (`SV\SV###.E5S`) cannot be loaded.
* **Autosave:** the game keeps an autosave of the last point where it waited for you: the start of every scenario
  file, a story scene waiting for a click, or your battle phase with nothing selected. It is written when the app
  goes to the background, loses focus or is closed, and at most once a minute while playing, so on a phone it is
  safe to switch away or close the app at any time. **烽煙再起 → 继续游戏** resumes it. It does not use one of the 10
  slots. After a game over (再玩一次吗？: 是 returns to the title, 否 quits the game on a desktop) it lets you retry
  from the last checkpoint.
* **Endings:** an ending plays the closing video and the credits, records its emblem for the title screen and returns
  to the title (the original quits the program there).
* **Where saves live:** `save_00.json` … `save_09.json` (each with a small `.info.json` for the slot list),
  `autosave.json` and `sv.e5s` (the original's `SV\SV.E5S` record: the endings reached, shown as title emblems, and
  collected items) in the game's user folder:
  * macOS: `~/Library/Application Support/Godot/app_userdata/新改曹操傳/`
  * iPhone: the app's own folder, visible in the **Files** app under **On My iPhone → 新改曹操傳** (or in Finder's
    iPhone *Files* tab), so saves can be copied to and from a computer
  * Android: the app's private storage; it survives updates but is deleted when the app is uninstalled
  * Windows (untested build): `%APPDATA%\Godot\app_userdata\新改曹操傳\`

  The files are the same on every platform. Slots numbered 11 and higher are written by the automated tests.

## Troubleshooting

| Problem | Fix |
|---|---|
| `run_game.sh`: "No converted game data in game/assets" | Put the original game at `orig/` and run the converters ([BUILDING.md](BUILDING.md#re-generating-the-game-data)) |
| macOS: "App can't be opened" / "Apple could not verify…" (an app copied from another Mac) | It is only ad-hoc signed. macOS 15+: **System Settings → Privacy & Security → Open Anyway**; older: right-click → **Open**; or `xattr -dr com.apple.quarantine XinGai.app` |
| iPhone: the sideloaded app stops opening after a week | A free Apple ID signs for 7 days; re-sign it with AltStore / Sideloadly |
| Android: "App not installed" over an older build | The new APK is signed with another key; uninstall first (this deletes the saves) or build with the release key ([BUILDING.md](BUILDING.md#android)) |
| Missing characters (▯) in text | The desktop uses system Chinese fonts: SimSun, Songti SC, STSong, Heiti SC or PingFang SC, with Hiragino Sans GB, Heiti SC, Microsoft YaHei and SimHei as fallbacks (on macOS make sure they are not disabled in Font Book). Phones use the bundled Noto Serif SC; `WG_BUNDLED_FONT=1` uses it on a desktop too |
| 保存 says 目前禁止存档 | The scenario forbids saving at this point; save later |
| A story scene "does nothing" | It is waiting for you: click the character that continues the story, or look for the 出征 button in sortie mode |
| Window too small or too large | Drag its edge or corner (it snaps to 4:3) or toggle full screen (⌘F) |
