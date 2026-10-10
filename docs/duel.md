# 单挑 / 练武场 / 舌战 — 新改曹操傳 6.6 (Ekd5.exe) reimplementation spec

Evidence: `orig/Ekd5.exe`, read with `tools/disx.py` and a full Ghidra dump. The engine is hand-written assembly:
* objects come in `ecx` and are kept in `[ebp-4]`;
* values come back in `ecx` or `edx`;
* small arguments go in `al`;
* callees read the **caller's locals** (e.g. 0x40a5c5 `[ebp+0x1c]` is 0x437645's `[ebp-4]`).

So every rule below was read in the disassembly. **[C]** = confirmed in the disassembly. **[G]** = guess.
Unmarked rules are [C].

The 6.6 engine has **four** duel-like systems. Only the first three can be reached with this mod's scripts and
data:

| system | where | how it is started | used by this mod |
|---|---|---|---|
| A. **Scripted duel** (wg2025-style, no randomness) | duel screen, object `DUEL` = 0x4b3c80 | op 0x68 with EV 4087 = 0, then ops 0x60–0x66 / 0x62 / 0x5f | 261 S + 24 R scripts |
| B. **练武场 dialog fight, 普通模式** (mode 1): a mini battle using the normal battle engine | modal dialog 330 "练武场" | op 0x68 with EV 4087 = 1; item 171 強制單挑令; menu 功能→练武场→普通模式 | 28 script uses + item + menu |
| C. **练武场 dialog fight, 单挑模式** (mode 2): a 4-command duel (攻击/突击/防御/回避) | the same dialog | menu 功能→练武场→单挑模式 only | menu |
| D. **"S-form" duel / 舌战** on the duel screen (EV 4083 = 2 command duel, = 1 debate) | duel screen + child windows | an item of type 0x31 whose base value is 1 or 2, or op 0x12 `choice` with int16 arg 0x3ff after a duel setup | **never**: no script writes EV 4083, no script uses choice 0x3ff, and the only type-0x31 consumable (171) has value 0. Document it, implement it last |

## 0. Conventions

* **EV n** = script integer variable n (u32 at 0x502000 + 4n, memory.md §8). The duel variables are:

  | EV | address | initial | meaning (as the code uses it) | set by |
  |---|---|---|---|---|
  | 4082 | 0x505fc8 | 0 | S-form only: the loser is shown as "killed" (op 0x62 grey-out and an extra animation). No gameplay effect | nobody (reset to 0 by 0x415c86) |
  | 4083 | 0x505fcc | 0 | S-form mode: 0 off, 1 舌战, 2 command duel | the item duel 0x425ef7 (= item value) |
  | 4084 | 0x505fd0 | 0 | **result**: 0 = A (the player-side fighter) lost, 1 = A won, 2 = draw | 0x41cf04, 0x453247 (flee), 0x439e0b (S-form) |
  | 4085 | 0x505fd4 | 5 | HP of the enemy in the command duel (mode 2 and S-form 2) | reset to 5 after every dialog / S-form |
  | 4086 | 0x505fd8 | 0 | 4 bytes r0..r3: enemy duel abilities (§3.5) | reset to 0 after every dialog / S-form |
  | 4087 | 0x505fdc | 0 | 练武场 mode: 0 none, 1 普通, 2 单挑. Also the global "in training" flag that ~60 battle routines test (§3.4) | scripts (`4087 = 1`, 28×), menu, item |

  The variable documentation (`變量計算+意義.txt`) says 4084 is "0 平手 1 胜利 2 失败". **That is wrong.** The
  code and every script use 0 = 失败, 1 = 勝利, 2 = 平手.

* `rand(n)` 0x47fb13 = `n < 2 ? 0 : lcg() % n`. lcg 0x47fae7: `s = s*0x41c64e6d + 0x3039` (seed u32 0x48ecd4),
  returns `(s >> 16) & 0x7fff`. `chance(p)` 0x47fb32 = `rand(100) < p` (unsigned).
* Units are 0x30-byte records at 0x4a7b20 (memory.md §4). +0x10 = HP and +0x14 = MP are reused as duel HP and
  SP. **U0** = slot 0 (0x4a7b20), **U60** = slot 60 (0x4a8660).
* **P1023** = person record 0x3ff (`[0x4cea08]`, memory.md §1). It is a scratch record. Its fields +0x11..+0x1a
  hold the persistent command-duel progress; a save keeps +0x11..+0x36 of every person. Its fields +0x38..+0x3d
  hold the current enemy's duel data (not saved). **P1022** = person 0x3fe, the generic training opponent.
* **DC** = duel context block at 0x500ae0 (0x90 bytes, not saved). Its +0x30.. part is **DB** = 0x500b10
  (舌战 state, §5.3).
* Side numbering on the duel screen (as in wg2025): side 1 = player side (right), side 0 = the other.
  `DUEL+4` / `DUEL+0x30` = side 0 / side 1 fighter record (+0 person ptr, +4 unit ptr, +8 person id).

---------------------------------------------------------------------------------------------------
## 1. System A — scripted duel (ops 0x68, 0x60–0x66, 0x62, 0x5f)

The visible behaviour is the wg2025 duel (`rea/docs/duel.md`). All op semantics, action numbers (0..15), exchange
kinds (0..4), specials (0..2), bubble layout and text timing (holds 5/12/20 for speed 0/1/2) are the same. The
EXP rule of op 0x62 and the box geometry are also the same. Port `duel_layer.gd` as is, with the 6.6 changes below.
The 6.6 code was rewritten (compacted). The entry points of the action routines are unchanged (action table
0x4484e7 = wg2025 addresses except act 1 → 0x444d08).

### 1.1 Op handlers (table 0x410a38, op−2) [C]

| op | handler → routine | args (tags) | notes |
|---|---|---|---|
| 0x68 duel_setup | 0x4103ee | personA (int16), personB (int16), backdrop (tag 0x4f) | Skipped (returns 0) unless A < 0x400, B < 0x400 and A ≠ B. **EV 4087 = 0 → 0x4499a3(DUEL, A, B, backdrop)** (system A). EV 4087 ≠ 0 → 0x41e6a4(A, B, backdrop) (system B/C, §3) |
| 0x60 duel_say | 0x417447 → 0x448bae | side (tag 0x26, ≠0 → 1), text, act | appear + speech |
| 0x61 duel_end (= fight start) | 0x4174c0 → 0x448cb3 | — | wait 20, "胜负" banner (0x431b99), wait 20, redraw, wait 10 |
| 0x62 duel_62 | 0x4111f4 → 0x448e55 | winner side | grey loser, EXP (same formula as wg2025 §6) |
| 0x63 duel_say2 | 0x4175c2 → 0x4431af | side, text, mode | unchanged address |
| 0x64 duel_action | 0x417636 → 0x448497 | side, act | table 0x4484e7, acts 0..16 (16 = 12 panting) |
| 0x65 duel_action2 | 0x41768c → 0x448389 | side, kind, arg | kinds 0..4 as wg2025. Kinds 5..8 are new and used only by the S-form engine (§5.1) |
| 0x66 duel_action3 | 0x4176e6 → 0x44867a | side, kind, arg | specials 0..2 |
| 0x5f duel_start (= close) | 0x41583f → 0x4498e5, then 0x411991 | — | close |

eex.py names tag 0x26 "person". For these ops it is a side flag (`cmp [ebp+8],0; setne`).

### 1.2 Setup (0x4499a3 + activation 0x4495f4 + drawing 0x4486f4)
* **Side assignment** is unchanged [C]:
  * `member(p)` = person +0x2a ≠ 0xff (0x42ac58). If A is a member: side0 = B, side1 = A.
  * Else if B is a member: side0 = A, side1 = B.
  * Else, if the side (0x406710) of A's unit is 1 (player side): side0 = B, side1 = A. Otherwise side0 = A,
    side1 = B.

  Then side0 dir = 1, side1 dir = 3, and the MOV caches are mirrored (0x43fd34).
* **Activation 0x4495f4** (new: also works outside battle):
  * In battle the fighters are the persons' units (0x477adc). If either person has no unit, the duel stays
    inactive (`DUEL+0 = 0`) and all ops do nothing.
  * **Outside battle** (R scenes) slots **60 and 11** are borrowed: side0 → unit 60 with colour 2, side1 →
    unit 11. Each gets the person id and its slot, and its sprite is reloaded (0x43fe2c).
  * The box is `L = viewW/2 − 312`, `T = viewH/2 − 0x88` in battle and `viewH/2 − 0xac` outside battle
    (0x420660(0x496f38) is also called outside battle).
  * Fighter x: side0 `L+168`, side1 `L+360` — or, when EV 4083 ≠ 0 (S-form), `L+72` and `L+456`.
  * Y = T+144. Portraits are at (24,24) and (536,280), bubbles at (120,32) and (184,288). `+0x84` (EXP) = 0.
* **Drawing 0x4486f4**, compared with wg2025 §3.1:
  1. Frame 624×384 and the first bevel set as in wg2025.
  2. Save the BGM to +0x64, then **BGM 10**, then wait 10.
  3. Side-0 portrait and big name, wait 20, "单挑" banner, wait 20, side-1 name and portrait.
  4. **Wait 43** ticks (wg2025: 75).
  5. Backdrop = **Logo.e5 entry `backdrop`** (604×364 JPEG; gfx.md §screens), drawn at (L+8, T+8). The backdrop
     is inset by 8 px, so the first bevel stays visible. There is **no second bevel pass**.
  6. Draw the portraits and small names, then capture the background and the fighter strip.

  Scripts use backdrops 15..37.
* Graphics are 24-bit (frames of 0x1b00 bytes = 48×48×3, key colour 0xF700FF). wg2025's palette-index colour
  values become RGB, but the frame numbers and SEs are the same (e.g. act 0 = MOV frame 8 + SE 8, act 13 = fill
  with the key colour).

### 1.3 Other differences [C]
* **op 0x60 appear**: 10 steps (not 16).
  * Step k = 10..1 draws MOV8 blended toward white by k·10 % (0x40690c(…, k*10, 0xffffff, 1, 0)) and waits 1.
  * Then wait 5. The loop never draws k = 0, so with act 0 the fighter stays 10 % whitened until the next
    redraw (original quirk).
  * Then act (if ≠ 0), then say2(side, text, mode 1).
* **op 0x5f close**:
  * Restore the mirror flags. Set `DUEL+0 = 0`, skippable wait 30, redraw the map. Clear `[0x500ef9]` (the
    portrait overlay flag; wg2025 used 0x4cf608). Restore the BGM.
  * In battle, when the side-1 unit is player-controlled (0x43ff54): EXP popup (0x450986) and
    `SetExp(person, exp + DUEL+0x84)` (0x4088cd).
  * Out of battle it calls `SetExp(side1 person, exp + DUEL+0x84)` without a popup. +0x84 is 0 unless op 0x62
    gave EXP.
* Script usage (all files): exchange kinds 0:418 1:914 2:213 3:181 4:189; specials 0:800 1:560 2:49; acts 0..15
  (14/15: 5 each); op 0x62 winner 1:70 0:24.

---------------------------------------------------------------------------------------------------
## 2. Entry points into the 练武场 dialog [C]

```
0x41e6a4 TrainStart(A, B, arg):                 # op 0x68 when EV4087 != 0, and the item duel
    byte[0x500d8f] += 1                         # "started by script/item" flag
    0x41de7e(&screenmode 0x4ac63c, 1)           # P1023+0x1a = screen mode; screen mode = 3 (battle)
    TrainDlgOpen(DC, A=P(A), B=P(B), arg, x=0)

0x418f05 TrainDlgOpen (ecx=DC, eax=A ptr, edx=x, stack B ptr, arg):
    DC+0 = A ptr (player side fighter, U0)      DC+4 = B ptr (opponent, U60)
    DC+8 = arg (byte; +9..+0xc = x: byte +9 = opponent level for menu fights)
    DC+0xa = 1 (round counter)                  DC+0x1c = P1023 ptr
    DC+0x10 = EV4087 (mode)                     DC+0x11 = [0x500d8f] (1 = script/item, 0 = menu)
    DialogBoxParamA(dialog 330, owner main window, proc 0x4207b2)    # modal
```
* **op 0x68** with EV 4087 = 1: all 28 scripts use `int_var_op 4087 = 1; duel_setup A B 1`, then test EV 4084
  (0 失败 / 1 勝利 / 2 平手). Script fights are always 普通模式 (mode 1). The arg (1) is stored but not used by
  mode 1.
* **Menu 功能 → 练武场** (menu id 112; WndProc 0x474c97 case 0x70 → 0x474e0e). The entry is enabled only
  **outside battle** (0x4759bc grays submenu position 4 when 0x40b922 = in battle).
  * Choice box (0x42de7d(text, 0x3fe, 4); 0x3fe probably names the speaker [G]): "普通模式\n单挑模式\n自动提升\n取消".
  * For choice 1/2, EV 4087 is set to it. Then 0x423842(choice) runs (§3.6).
  * Afterwards EV 4087 = 0, screen mode byte `[0x4ac63c] = 2`, and 0x40dff9 runs.
* **Item 強制單挑令** (§4) calls TrainStart with mode 1.

`[0x500d8f]` is cleared by the dialog's WM_DESTROY handler 0x42a214, and EV 4087 is cleared there too when it was
set. That handler always sets EV 4086 = 0, EV 4085 = 5, `[0x500cb0] = 0`, `[0x49476c] = −1`, `[0x494728] = 1`.

---------------------------------------------------------------------------------------------------
## 3. Systems B/C — the 练武场 dialog (dialog 330, proc 0x4207b2)

### 3.1 Dialog setup (WM_INITDIALOG) [C]
1. **Back up U0 and U60** (0x40762f: 0x30 bytes each → 0x500b10 / 0x500b40). Restored at WM_DESTROY by
   0x41d27a.
2. **Fake map** 0x40ada3 (all restored at the end):
   * Save unit-grid row cells 0..3 (map buffer +0xc80) to DC+0xc and set them to `ff ff 3c 00` (U60 at x=2,
     U0 at x=3).
   * Save the terrain cells (2,0),(3,0) (+0x642) to DC+0x1a and set them to 0xff.
   * Save the map size word `0x4b422c` to DC+0x12 and set it to 0x0104 (4×1).
   * Set `[0x500cb0] = 1`.
   * Save the view (0x4b4250 +4/+8) to P1023+0x1b/+0x1f and set it to 0. Set view +0x40 = 0x38 and +0x54 = 0xffff.
   * Set `[0x500c44] = 2` and increment `[0x500e9a]`.
3. When mode ≠ 2 and DC+0x11 ≠ 1 (menu fights): reload Data.e5 into the buffer 0x48b100 (0x4266af).
4. DC+0x14 = hwnd. Then 0x42b6b7 (fighter setup, §3.2):
   * U0 sprite position byte +0x21/+0x22 = (240, 56).
   * In mode ≠ 2 the button texts become 0x508 "策略" and 0x509 "道具".
   * Focus goes to 0x507. Draw the picture (0x40d5a4). Fill both info panels (0x42c5ac) and the round text.
5. Idle animation timer: SetTimer id 0x6e, 300 ms, proc 0x43a51a (fighters alternate idle frames). 0x452de9
   switches it on and off.
6. Disable buttons 0x508..0x50b (0x43bfa3). Only "开始" is active.
7. Layout 0x452fba (pixel sizes after creation; the dialog is centred on the main window by 0x423c6e):
   * **mode 2**: client 381×250. The template positions stay: picture 0x4c3 moved to (2,2) 294×150. Buttons
     (DLU) 开始/攻击 0x507 (199,19), 突击 0x50a (200,46), 防御 0x508 (199,75), 回避 0x509 (199,105), 逃跑 0x50b
     (199,134), each 49×14. "回合数" (199,3) with the value 0x433 "n/10" (226,2). Two small panels: enemy group
     0x55a at (1,103), player group 0x557 at (101,103). Each shows name, HP, SP.
   * **mode 1**: client 381×341.
     * The hidden controls 0x551..0x56a are shown: Lv, Exp, and the 攻击/防御/精神/爆发/士气 rows.
     * The groups are moved and enlarged to 144×160: player 0x557 at (151,154), enemy 0x55a at (1,154).
     * The labels 0x553/0x554 "SP" are renamed "MP".
     * Buttons are moved to x=300, y=127/181/235/289, size 72×22: 攻击 0x507, 策略 0x508, 道具 0x509,
       逃跑 0x50b. 突击 0x50a is hidden.
   * Picture box 0x4c3 = (2,2) 294×150 in both modes.
   * The window title is "练武场". When DC+0x11 ≠ 0 (script/item) it is "单挑".
   * Panel fill 0x42c5ac(hwnd, unit, k): group 0x557+3k caption = name (0x407775), next id = class name. U0 →
     k=0 (player panel), U60 → k=1.

### 3.2 Fighter setup 0x436dd1(mode, ctx) → 0x436f52 / 0x436fef [C]
```
InitFighter(unit, person, mode):                      # 0x436f52
    unit.person = id(person)
    if mode != 2: unit.HP = MaxHP(person) (0x407263); unit.MP = MaxMP(person) (0x40728f); unit buffs[0..5] = 3
    else:
        D = P1023
        if unit is U0:
            if byte[0x510cf8] == 0:                    # first command duel ever (flag in the save block)
                byte[0x510cf8] = 1
                D+0x11..+0x14 = 50, 50, 85, 15          # q0..q3
                D+0x15 = 5 (player duel HP)  D+0x16 = 5  D+0x17 = 1 (duel level)  D+0x18 = 0  D+0x19 = 0
            unit.HP = D+0x15
        else:  D+0x38..+0x3b = EV4086 bytes r0..r3;  D+0x3c = EV4085;  D+0x3d = 5;  unit.HP = EV4085 (byte)
        unit.MP (= SP) = 1

SetupEnemy(ctx, mode):                                # 0x436fef
    if ctx+0x11 == 0:                                 # menu fight: build a random opponent in person 1022
        if mode != 2: 0x45362b(P1022, level = ctx+9)  # below
        else: r = rand(26); P1022.class = (r < 13) ? 3*r : r + 26
    U60.+0x21/+0x22 = (0, 56)
    InitFighter(U60, ctx+4 person, mode)
    U0:  +4 = 00 00 03 00 (slot 0, colour 0, x 3, y 0); +0xc = state 2, flags 0, AI code 7, facing 3
    U60: +4 = 3c 02 02 00 (slot 60, colour 2 enemy, x 2, y 0); +0xc = state 2, flags 0, AI code 2 (hold), facing 1; +8 = 0xff
    if mode != 1: U0.x = 4; U60.x = 1

0x45362b(P, L)  — random training opponent:
    reset P from Data.e5 (0x41b617(buf, id, 1))
    r = rand(26); c = (r < 13) ? 3*r : r + 26
    if c < 38: c += (L >= 40) ? 2 : (L >= 20) ? 1 : 0        # promotion tier
    P.level = 0; P.class = c; LevelUp(P, L levels) (0x4073f3(L, 0))
    auto-equip weapon and armour: 0x407fd4(0,1), 0x407fd4(1,1)
```
The player-side fighter is A (script/item) or the person chosen in the menu. Script fights use B's current data
as is. Both fighters start at full HP/MP (mode 1).

### 3.3 Round flow — WM_COMMAND 0x45321a(hwnd, ctx+0x11, wParam, lParam, ctx, mode) [C]
```
id = wParam;  if id < 0x507: return
disable buttons 0x507..0x50b
k = id - 0x505
k == 6 (逃跑 0x50b):  EV4084 = 0;  EndDialog;  return
k == 2 (0x507):
    if ctx+0xb == 0:                     # the first press is "开始"
        ctx+0xb = 1;  SetDlgItemText(0x507, "攻击");  idle timer off
        Walk(enemy→ mode==2 ? 48 : 96, player→ mode==2 ? 192 : 144)        # 0x41da18, 8 px per frame
        goto ENABLE
    if mode != 2: idle off;  PhysicalAttack(U0 → U60)  (AtkSlots 0x4927f0 .0x4064f1(0, 0x3c))
    else:         DuelCmd(hwnd, ctx, 1)                                      # §3.5
k == 3 (0x508): mode != 2: s = SelectStrategy(U0) (0x4664df); if s == 0xff goto ENABLE
                            idle off; U0.CastStrategy(s) (0x41c0e8); if !(U0.flags & 2) goto ENABLE
                mode == 2: DuelCmd(…, 3)
k == 4 (0x509): mode != 2: it = SelectItem(U0) (0x41e13d); if it == 0xff goto ENABLE
                            idle off; U0.UseItem(it) (0x420271); if !(U0.flags & 2) goto ENABLE
                mode == 2: DuelCmd(…, 4)
k == 5 (0x50a): DuelCmd(…, 2)
ENEMY:
    refresh panels (0x420168);  U60.status (+0x1e) = 0          # the enemy's ailments are wiped every round
    if U60.HP > 0 and mode != 2:
        [0x4bd1c4] = 0; 0x43a51a; 0x452f06;  U0.flags = 0
        AIAct(U60) (0x43ad3b, see ai.md; in training the AI uses the strategy table MgAIYN2 0x4d1690);  U60.flags = 0
    if !RoundEnd(hwnd, mode, ctx, ctx+0x11, U0, U60): return      # dialog ended
    if mode == 2: Walk(48, 192)                                    # back to the start marks
ENABLE:
    idle timer on
    mode == 1: enable 攻击; 策略 if U0 can use a strategy (0x43e023); 道具 if U0 has a usable item (0x408e96)
    else:      enable 攻击/防御/回避; 突击 iff U0.SP >= 3                (0x4162f0)
    if ctx+0x11 == 0: enable 逃跑                                        # menu fights only
```

**RoundEnd 0x41cf04** (returns 0 = dialog closed, 1 = go on):
```
if U0.HP == 0:  EV4084 = 0;  if ctx+0x11 != 1: MsgBox("战败");  EndDialog;  return 0
if U60.HP == 0: EV4084 = 1;  goto NEXT
if ctx+0xa < 10: ctx+0xa += 1;  set 0x433 = "%d/%d" (ctx+0xa, 10);  if mode != 1: both SP += 1 (cap 5);  return 1
EV4084 = 2;  if ctx+0x11 == 1: EndDialog; return 0
MsgBox("平手")
NEXT:
    DuelLevelUp(mode, ctx)                          # 0x4107c3, mode 2 only (§3.5)
    if ctx+0x11 == 1: EndDialog; return 0           # script/item fights end here
    # menu: offer the next opponent
    avg = PartyAverageLevel()                       # 0x40c231
    if mode == 2: x = 0
    elif level(A) < avg: x = ctx+9 = avg
    else: MsgBox("你已经没有对手了。"); EndDialog; return 0
    [0x500cb0] = 0
    if !PayTraining(x): EndDialog; return 0         # 0x4237f9
    [0x500cb0] = 1
    if mode != 2: reload Data.e5
    re-setup both fighters (0x436dd1: full HP/MP, new random opponent); 0x40ad60(U60)
    ctx+0xa = 1; redraw; if mode != 2: Walk(96, 144)
    return 1
```
* Rounds: the counter starts at 1, so at most 10 exchanges. The 10th survived exchange is a draw. The player is
  checked first, so mutual KO = loss.
* **PayTraining(x)** 0x4237f9:
  * x == 0 (mode 2): `v = 0x40d8a9()`, which is 1 if `[0x510cf8] == 0`. If P1023+0x19 ≥ 5 it shows
    "目前无需练武了" and returns 0. Otherwise v = P1023+0x17 (duel level). cost = v·2·10.
  * x ≠ 0 (mode 1): cost = level(A)·10.
  * Then 0x423820: if cost > gold `[0x4b077c]` → "资金不足", return 0. Otherwise "支付%d金？" yes/no (0x43bfd2):
    yes → SE 0xa, gold −= cost, `[0x4ac63c] = 3`.
* **PartyAverageLevel** 0x40c231 = Σ level / count over persons 0..126 with person+0x2a ≠ 0xff (integer
  division). The result is 1 if there are no persons or the average is ≤ 1.
* **WM_DESTROY** (0x4207b2 msg 2):
  * Timer off, 0x41d27a: restore U0/U60, the map cells, size and view. Clear DC +0..+0x1f, `[0x500c44]`,
    `[0x500e9a]`. Restore the screen mode from P1023+0x1a.
  * Delete the two GDI objects of 0x491878 (0x455e1d / 0x455e44). Then 0x42a214 (§2).

### 3.4 普通模式 (mode 1) — battle engine inside the dialog
The player's 攻击/策略/道具 are the normal battle routines aimed at U60 (rules in battle.md / skills.md). U60
then takes a normal AI turn as a unit with AI code 2 (hold). EXP and level-ups are applied to the persons as in
battle; the person records are **not** restored afterwards, the units are. Training mode (EV 4087 ≠ 0) changes
these battle routines [C]:

| where | effect in training |
|---|---|
| 0x43f7b8 terrain effect of a unit | always 100 % |
| 0x426ba0 | kill count (person +0x35) not increased |
| 0x42ab8e | 功勋 gain only if EV 4055 = 0 |
| 0x410fc3 | no 必杀 SP gain from damage |
| 0x403262 (gates weapon/armour EXP 0x403870 / 0x403a8a and strategy equipment EXP 0x421363 / 0x42140d) | equipment EXP only when not training, or DC+0x11 = 1 (script/item fight), or byte 0x4ce24b = 1 (it is 0). **Menu fights give no equipment EXP** |
| 0x450033 HP/EXP map popup | skipped |
| 0x418c7c "is person 0's unit" (game-over test) | false |
| 0x439870 AI strategy-use table | MgAIYN2 0x4d1690 instead of MgAIYN1 0x4d1600 |
| 0x4087f0 / 0x40b3a6 | message boxes are owned by the training dialog (DC+0x14) |
| 0x41d122 (map target cursor 0x45533d) | not shown; it returns 0 at once. How the strategy dispatcher 0x425627 (called by 0x41c0e8 with target −1) then picks U60 or U0 was not traced [G] |
| 0x477adc (person → unit) | checks slot 0, then slots 60..249 only (slots 1..59 are skipped) |
| others: 0x403269, 0x40372a, 0x40447b, 0x404f60, 0x4084f9, 0x40aca8, 0x417b9d, 0x418e40, 0x419bb6, 0x41c4b5, 0x41c7e2, 0x41d651, 0x41d71b, 0x41d927, 0x420a43, 0x4214ad, 0x421a2f, 0x422216, 0x42243d, 0x4235ed, 0x423be3, 0x42532a, 0x4287bc, 0x42a680, 0x438ed8, 0x43ab27, 0x43b2e9, 0x43e5f3, 0x43ec05, 0x45219d, 0x45233f, 0x45242d, 0x45275f, 0x4527b7, 0x453ac9, 0x455044, 0x457b01, 0x45d31e, 0x45e857, 0x45e900, 0x466464, 0x46709b, 0x467ca3, 0x46d860, 0x46fd27 | mostly drawing into the dialog picture instead of the map, and skipped map effects. Not individually analysed [G] |

### 3.5 单挑模式 (mode 2) — the command duel
**Data** (P1023, persistent):

| field | init | cap | use |
|---|---|---|---|
| q0 +0x11 | 50 | 60 | player's 攻击 vs a defending enemy: success % = max(q0 − r0, 0) |
| q1 +0x12 | 50 | 60 | not used by any resolution (raised by level-ups only) |
| q2 +0x13 | 85 | 95 | evading an enemy 突击: the enemy succeeds with (100 + r2 − q2) % (8-bit arithmetic) |
| q3 +0x14 | 15 | 25 | not used by any resolution |
| HP +0x15 | 5 | 7 | player duel HP |
| +0x17 | 1 | 43 | duel level |
| +0x18 | 0 | — | wins toward the next level (0..4) |
| +0x19 | 0 | — | menu wins/draws; ≥ 5 → "目前无需练武了" and no more paid matches |

Enemy: HP = EV 4085 (5). Abilities r0..r3 = EV 4086 bytes (all 0). With the defaults the player's attack beats
a defence 50 % of the time and an enemy 突击 beats the player's 回避 15 % of the time.

**Commands**: 1 攻击 (button 0x507), 2 突击 (0x50a, costs 3 SP, needs SP ≥ 3), 3 防御 (0x508), 4 回避 (0x509).
**SP** starts at 1:
* +1 for both after every completed round (cap 5);
* +damage taken (cap 5; 0x44de51);
* 突击 subtracts 3 when chosen.

**DuelCmd 0x437645(hwnd, ctx, pc)**:
```
idle timer off
repeat:                                   # enemy command
    r = rand(4)
    if r == 1 and U60.SP < 3: retry       # 突击 needs SP
    if r == 3 and U0.SP < 3:  retry       # 回避 only when the player could 突击
    if r >= 2: if byte[0x4a7b40] > 2: retry else byte[0x4a7b40] += 1   # ≤ 3 passive picks in a row
    else: byte[0x4a7b40] = 0
e = r + 1                                 # 1 攻击 2 突击 3 防御 4 回避
Walk to the meeting marks: (e<3) ? (pc<3 ? (96,144) : (144,192)) : (pc<3 ? (48,96) : (48,192))   # (enemy x, player x)
Resolve(pc, e)                            # 0x40a5c5
```
`[0x4a7b40]` is U0+0x20, which the dialog does not initialise (it holds whatever the saved unit 0 had). If it is
> 2 at the start, the enemy cannot defend or evade until it has attacked once (original quirk).

**Resolve 0x40a5c5** (P = U0, E = U60; "X hits Y n" = Y.HP −= min(n, HP), then Y.SP += n (cap 5)):
```
if pc == 2: P.SP -= 3          if e == 2: E.SP -= 3
switch e:
  4 (enemy 回避):  nothing happens (both stand, SE 6)                                    # 0x423c27
  1 (enemy 攻击):  pc == 1: clash, P and E each lose 1 HP (0x4536c7)
                   else (突击/防御/回避): P hits E 2                                      # 0x43e1c3
  3 (enemy 防御):  pc == 1: if chance(max(q0 - r0, 0)): P says "哼！防的住吗？", P hits E 1
                             else: P whiffs, P says "失手了！", E hits P 1
                   else: P hits E 1
  2 (enemy 突击):  pc == 4: if chance((100 + r2 - q2) & 0xff): E says "早就知道你要躲。", E hits P 1
                             else: E whiffs, E says "失手了！", P hits E 2
                   else: E hits P 1
```
Then RoundEnd (§3.3). The S-form version (§5.2) is the same table except "E hits P **2**" when the evade fails.
The code makes "Enemy 攻击 vs 防御/回避 → the player hits for 2" and "enemy 防御 vs player 防御/回避 → the player
hits for 1". These look odd but are what it does.

**DuelLevelUp 0x4107c3(mode, ctx)** — called after a win, and after a draw in menu fights; mode 2 only:
```
D = P1023
if ctx+0x11 == 0: D+0x19 += 1
if D+0x17 >= 43: return
if D+0x18 < 4: D+0x18 += 1; return
D+0x18 = 0; D+0x17 += 1
repeat: i = rand(5)
        until (i==0 and q0<60) or (i==1 and q1<60) or (i==2 and q2!=95) or (i==3 and q3!=25) or (i==4 and HP<7)
D[0x11+i] += 1;  SE 0xb;  MsgBox("单挑等级提升")
```
(10+10+10+10+2 = 42 raises fit exactly into levels 1..43.)

**Opponent in menu fights**: person 1022 with a random class (sprite only). Its HP is EV 4085 and its abilities
are EV 4086.

**Visuals**:
* Fighters are 48×48 frames drawn into the picture at (unit+0x21, 56). U0 starts at x 240, U60 at x 0, and they
  walk in 8-px steps.
* Hit animation 0x4370f3: 5 frames, then damage. A 2-damage hit adds 2×2 flash frames with SE 6.
* Clash 0x4536c7: both sides animate.
* Speech lines are popups next to the speaker (0x416a75 → 0x46d9a4). The dialog uses fixed strings (the first
  line of sets 17/18/19), not the random choice of the S-form.
* Frame offsets inside each unit's 0x1e900-byte cache: base 0x24c00 for U0, 0x24c00 + 0x1e900 for U60
  (0x41cc9d) [C]. The per-frame choice was not mapped [G].

### 3.6 Menu 练武场 — 0x423842(choice) [C]
* **普通模式** (1):
  * L = the list of party members (persons 0..1023, person+0x2a ≠ 0xff) whose level < party average
    (0x4222ab). If L is empty: "目前无需练武了".
  * Pick one from the list dialog 0x45e6b3, then 0x41ecae(avg) with that person:
    * pay level·10;
    * fight P1022 at the average level (TrainDlgOpen with x = avg);
    * after the dialog, rebuild the list and pick again (until cancel / empty).
* **单挑模式** (2):
  * The fighter is the **first party member by id** (0x4184b0).
  * 0x41ecae(0): pay duel-level·20 (refused once P1023+0x19 ≥ 5), then fight P1022 in mode 2.
  * After each win/draw, RoundEnd offers the next paid match.
* **自动提升** (3):
  * L and avg as above. If L is empty: "目前无需练武了".
  * cost = avg·1000 gold, confirmed with "支付%d金？".
  * Then 0x406cfa: repeat { avg = average; every member 0..126 with level < avg gets LevelUp(avg − level) } until
    nobody was raised.
  * MsgBox "全队等级提升".

---------------------------------------------------------------------------------------------------
## 4. Item duel in battle — 強制單挑令 (item 171) [C]

Using a consumable whose type (item +0x11) is 0x31 goes through the item dispatcher 0x44f2ac. It builds the item
context with 0x4083a7:
* +0 item id, +2 user slot, +4 user unit;
* +0x1d type;
* jump table 0x44f330 with index table 0x44f380[type − 0x1a]; type 0x31 → handler 8 = **0x425e4c**.

```
ItemDuel(ctx):
    [0x500ad7] = 1;  t = SelectTarget(mode 2) (0x41d122 → 0x4b4250.0x45533d(user, 1, 2, item));  [0x500ad7] -= 1
    if t == 0xff: return
    ctx+3 = t;  ctx+8 = unit t
    Dialog("敢一决胜负吗？", speaker 0x404 + user slot);  Dialog("有何不敢！", speaker 0x404 + t)   # 0x45965d; face each other (0x421d3d)
    ctx+0x1c += 1;  save 32 bytes of ctx
    v = item base value (item +0x15; 0x41dd72)
    if v == 0: EV4087 = 1; TrainStart(user person, target person, 1)          # system B, mode 1, flag 1
    else:      EV4083 = v; 0x425f56(user, target, 5): classic setup with backdrop 5, both appear with empty
               text, op 0x61, [0x496f48] = 0, S-form start 0x448117, pump messages while EV4083 != 0   # system D
    restore ctx
    EV4084 == 0 → the user's unit loses 100 % of its current HP; == 1 → the target's unit does; == 2 → nothing
        (0x4220d3(slot, slot, 0, 100): HP popup 0x450986, then HP −= HP·100/100; the normal death handling follows)
```
Item 171 has value 0, so in this mod it is always a 普通模式 dialog fight (U0 = user, U60 = target, both at full HP
inside the dialog). The real units are untouched except for the loser's HP afterwards. EV 4087 stays 1 until the
dialog's WM_DESTROY clears it (`[0x500d8f]` ≠ 0).

---------------------------------------------------------------------------------------------------
## 5. System D — S-form duel / 舌战 (engine only; unreachable in this mod) [C unless marked]

### 5.1 Start and end
* **Start** 0x448117 (on an active DUEL from a classic setup):
  * Save side1/side0 unit HP/MP to 0x500b00..0x500b0c.
  * Clear DB+0x55..+0x58 and the player's 熟虑 flag. Set the played cards and the topic to 0xff (0x500b5e dword
    = −1).
  * DC+0 = side1 person, DC+4 = side0 person, round 1, DC+0x10 = EV4083, DC+0x11 = 1, DC+0x1c = P1023.
  * **0x420970(mode)** on both units:
    * mode 1 (舌战): HP = 120, MP (怒气) = 0.
    * mode 2: as InitFighter mode 2 (player HP = P1023+0x15, enemy HP = EV 4085, r = EV 4086, SP = 1). The
      unit-side test is `slot < 0x3c`; the 6.6 bugfix "修正舌戰變量4085的bug" changed it from 0x23.
  * 舌战 only: deal both hands (0x43cc0f; enemy hand first), create the enemy card windows (dialog 331, proc
    0x435093) and the topic window (0x42b572).
  * Create the player's button windows (dialog 297, proc 0x414f77, Cmdicon.dll bitmaps).
    * 单挑: 4 buttons 21..24 = 攻击/突击/防御/回避.
    * 舌战: hand + button 5 熟虑.
  * Status panels: player at (L+0x30, T+0x120), enemy at (L+0x1e0, T+0x20), 128×48. Each has an HP gauge and a
    second gauge "%4u /%4u" (舌战: HP/120 and 怒/80; 单挑: HP/max and SP/5) plus the personality label.
  * The caller pumps messages until EV 4083 = 0.
* **End** 0x439d80(DUEL, w) (w = winner side, 2 = draw):
  * Hide the windows.
  * w = 2: draw lines.
  * Otherwise:
    1. The loser does act 12 and says a line from set 15 (al 0x15); wait 8.
    2. If EV 4082: the loser does act 11 and gets the op-0x62 grey-out (0x448e55(w), which also computes the duel
       EXP) and SE.
    3. The winner does act 5 (cheer) and says a line from set 21 for 单挑 (al 0x1b) or set 14 for 舌战 (al 0x14).
       A draw uses set 23 (al 0x1d).
  * **EV4084 = w** (1 = player won).
  * Then cleanup 0x415c86:
    * restore the HP/MP of both units;
    * EV4082 = EV4083 = EV4086 = 0, EV4085 = 5;
    * classic close (op 0x5f);
    * zero DC.

  The duel itself never changes the real HP; only the item caller applies the loss (§4).
* **Lines** 0x41f66b(al = set, side): `s = al < 9 ? al/3 : al − 6`; text = table 0x4ce260[3s + rand(3)]; shown
  with DuelSay(side, text, 0). Sets:
  * 0–2 the three card categories;
  * 3 镇静, 4 愤怒, 5 诡辩, 6 大喝, 7 无视 (card lines);
  * 8 confused, 9 hurt ("呃！"), 10 ignored, 11 uncertain, 12 enraged, 13 deliberation, 14 debate win,
    15 debate loss, 16 rage burst;
  * 17 "哼！防的住吗？…", 18 "早就知道你要躲。…", 19 "失手了！…", 20 "哼！再来！…", 21 duel win,
    22 "嗬！该我出手了!…", 23 duel draw.

### 5.2 S-form 单挑 (EV 4083 = 2)
Button i → pc = i + 1. If pc = 2 and the player's SP < 3: "ＳＰ不足。".
* The enemy pick is the same as §3.5, using the real units' SP and the same counter byte 0x4a7b40.
* Resolve 0x43837e uses the same table as §3.5, played with duel-screen animations:
  * 0x407705(side, packed) = other side does act c2, exchange(side, kind c1, arg c0), the other side takes c3
    damage (act 12 if it survives a 2);
  * the mutual clash uses exchange kind 5.
* **One difference**: a successful evade-beater ("早就知道你要躲。") does **2** damage (dialog: 1).
* After each exchange:
  * player HP 0 → result 0;
  * enemy HP 0 → DuelLevelUp(2, DC), result 1;
  * round ≥ 10 → result 2;
  * otherwise round += 1, walk back, both SP += 1, MsgBox "回合数 %d/%d".
* A result ends the duel (0x439d80, 0x415c86).

### 5.3 舌战 (EV 4083 = 1)
**State DB = 0x500b10:**

| offset | meaning |
|---|---|
| +0x00..+0x14 | enemy card hwnds |
| +0x18 / +0x20 | centre windows; topic window struct at 0x500b30 |
| +0x28..+0x3c | player button hwnds |
| +0x40 | enemy hand {n, c1..c5} |
| +0x46 | enemy 熟虑 flag (0xff = used) |
| +0x47 | player hand {n, c1..c5} |
| +0x4d | player 熟虑 flag |
| +0x4e | topic 0..2 |
| +0x4f / +0x50 | played card (enemy / player; 0xff none) |
| +0x51 / +0x52 | played index |
| +0x53 / +0x54 | rage counter (0 calm, 1..4 enraged) |
| +0x55 / +0x56 | damage-taken accumulator (byte) |
| +0x57 | winner of the last decisive exchange (0 enemy, 1 player) |
| +0x58 | topic age |

**Cards** 0..13 (Cmdicon bitmap 31 + card):
* 0–8: category `c/3` (0 故事, 1 道理, 2 时节), strength `c%3` (小中大).
* 9 镇静, 10 愤怒, 11 诡辩, 12 大喝, 13 无视.

Hand size n = 5 if the person's raw 智力 (person +0x23) ≥ 90, 4 if ≥ 80, else 3. Deal = n × rand(14) with at
most one card ≥ 9 (0x43cc0f), sorted ascending. A refill after a play (0x43cd17) replaces the played slot:
* draw rand(14); no 9/10 while that side is enraged;
* a card ≥ 9 is allowed only if the other cards hold none (n < 4) or at most one (n ≥ 4) (0x44843c).

**Personality** (byte 0x508c00[person], save block): 0 胆小, 1 冷静, 2 刚胆, 3 莽撞. The initial table has person 0 = 1,
1 = 2, 2 = 3 and everyone else 0. No code writes it.

**Topic** (window shows Cmdicon 61 + topic):
* random 0..2 at the start;
* after every exchange (0x439e18):
  * a winning normal card off-topic → topic = its category (age 0);
  * a winning 诡辩 (11) → new random topic ≠ current with chance(90) (age 0);
  * otherwise (ties included) the topic age +1; when the age is already 4 → new random topic ≠ current (age 0).

**Turn** (player clicks a card, 0x43a07a → 0x44dcf4):
```
card idx 5 = 熟虑: forbidden ("激愤状态下不能使用") if the player is enraged and 刚胆;
    if flag 0x500b5d == 0xff "已进行过熟虑！"; else redeal the player's hand (flag = 0xff).
    NOTE: the click handler 0x414f77 increments 0x500b5d before and zeroes it after every click, so the
    "already" check never fires: 熟虑 is effectively unlimited (original bug).
normal card c: forbidden if (enemy enraged and 冷静) and c >= 9;
               or player enraged and (c in {9,10} or (c >= 11 and player 刚胆))
play: animation, record player card; if the enemy has not played: enemy picks (AI below) and plays
loop:
    w = Compare()                                   # 0x43f504, below
    apply (0x439ee8 → 0x41e614 / tie)
    r = RageCheck(w)                                # 0x44602d; 0xff → debate over (0x415c86)
    PostExchange (0x439e18); Refill both (0x43cd17, played cards := 0xff)
    if DB+0x57 == 0 (the enemy won the last decisive exchange): the enemy leads (picks blind, its card is shown as a
        category icon only) and the loop waits for the player's click; else wait for the click
```
**Compare** (e = enemy card, p = player card, t = topic):
```
if (enemy enraged and 刚胆) xor (player enraged and 刚胆):
    the enraged 刚胆 side wins unless the other plays a card >= 12: then the higher card wins, equal = tie
elif e < 9 and p < 9:
    on_e = (e/3 == t); on_p = (p/3 == t)
    on_e and !on_p → enemy;  !on_e and on_p → player;  else compare strength e%3 vs p%3 (higher wins, equal tie)
elif e < 9:  p in {9,10} → enemy;  p >= 11 → player
elif e in {9,10}: p < 11 → tie;  p >= 11 → player
else (e >= 11): p < 11 → enemy;  higher card wins;  equal → tie
```
**Apply**:
* **Tie**: both 怒 += 10 (cap 80), SE.
* **Win by card cw over loser card lc** (0x41e614):
  1. If cw ≥ 9 and lc ∉ {9,10}, the loser first says its own card's line.
  2. The winner says cw's line. The loser does act 7, says "呃！", waits 5. cw = 11: loser act 12 + confused
     line; cw = 13: loser act 11 + "ignored" line.
  3. **Damage** (0x4206c9):

     ```
     d = 4 · (winner's hand size);  gain = 10
     if winner enraged and 冷静: d += d/2
     elif winner enraged and 莽撞: d = 40            (card modifiers skipped)
     else if cw == 13: d = 0, gain = 20;  if cw == 12: d = 30, gain = 20
     loser.HP -= min(d, HP);  loser.怒 = min(怒 + gain, 80);  acc[loser] += d
     ```

  4. If the loser survived and lc = 9: **calm**, the winner's 怒 −40 (floor 0). If lc = 10: **anger**, the
     loser's own 怒 +40 (cap 80).
* **RageCheck(w)** (w = 2 checks the enemy as loser first, then the player):

  ```
  loser HP == 0 → debate over, winner w (0x439d80)
  if loser.怒 < 80: return
  loser becomes enraged: act 10, SE 0x21, rage line, 怒 = 0, rage counter = 1
  if the winner is calm:
      winner holds a 9: it is used up (replaced by rand(14)), the loser is calmed (rage off); stop
      winner holds a 10: used up; the winner also becomes enraged; winner's burst, then loser's burst
  else: loser's burst
  burst (0x40638d by personality): 胆小 = 3 hits, 莽撞 = 1 hit with charge glow, 冷静/刚胆 = none (rage lasts)
      each hit: fixed lines "你还是闭上嘴…/这下你该听懂了吧？/应该让你也长点见识！", exchange kind 0,
      damage as above with cw = 0 (so 莽撞 = 40); then RageCheck on the victim; then the burster's rage ends
  ```
* **PostExchange**: each enraged side's counter +1. At 4 the rage ends. While an enraged side is 冷静, its 熟虑
  flag is refreshed every exchange. Every 40 damage taken (acc ≥ 40 → acc −= 40) also refreshes 熟虑.

**Enemy card AI** (0x41edf7; it may peek at the player's hand when leading):
```
pE2 = player enraged & 刚胆; eE2 = enemy enraged & 刚胆
eE2 and !pE2 → play the lowest card
pE2 and !eE2 → play the top card if it is 12/13, else fall through to "none"
otherwise: k = (player card known) ? (p<9 ? (on-topic ? 0 : 1) : 2)
                                   : (player holds an on-topic normal card ? 0 : 1)
              # the peek scans 5 slots from the bottom whatever the hand size and stops at the first card >= 9
   k=0: strongest on-topic normal card
   k=1: weakest on-topic card; else strongest off-topic card if its strength >= 1
   k=2: if player enraged & 冷静: weakest on-topic; else top card >= 11 if Worth(top) else weakest on-topic
none: unless (player enraged & 冷静): first card from the bottom with Worth(c) (0x418060)
      if still none and the enemy 熟虑 is unused: 熟虑 (redeal, flag 0xff) and choose again
      else the lowest card
Worth(c) (0x42003a): enemy enraged and c <= 10 → no; 11 → yes; 12 → player HP <= 30 or 怒 <= 60;
      13 → player 怒 <= 20; 9 → enemy HP > 50 and enemy 熟虑 used and player 怒 >= 70;
      other (10 or normal) → enemy HP > 30 and enemy 怒 >= 50
```

---------------------------------------------------------------------------------------------------
## 6. Differences from wg2025 (summary)
* Op 0x68 branches on EV 4087 into the 练武场 dialog; the classic duel also runs outside battle (borrowed units
  60/11).
* Backdrop = Logo.e5 entry (604×364 at +8,+8), intro wait 43, no second bevel, 10-step appear fade, 24-bit
  frames, overlay flag 0x500ef9. Exchange kinds 5–8 and act 16 exist but only the S-form uses them.
* New: 练武场 dialog fights (普通/单挑), persistent duel level in person 1023, 自动提升, the item duel with
  HP-loss for the loser, EV 4084 result protocol, and the S-form duel/舌战 (unused here).

## 7. Open questions
* Exact frame indices and timings of the dialog-fight animations (0x4370f3, 0x4536c7, 0x41da18 walk, idle timer
  0x43a51a) and the S-form exchange kinds 5–8 (0x4461cf with 0x40b516) were not mapped frame by frame.
* About 45 training-mode branches in §3.4 are listed but not individually analysed (mostly drawing/map).
* Exact pixel positions of the S-form card and button windows (0x439fa6 → 0x427fee) were not converted.
* Card names 镇静/愤怒/诡辩/大喝/无视 come from the Cmdicon.dll bitmaps (gfx.md); the semantics above are from code.
