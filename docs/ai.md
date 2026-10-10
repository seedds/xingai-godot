# 新改曹操傳 6.6 — battle flow and AI

Specification of the battle turn loop, the AI and the player-phase engine rules of `orig/Ekd5.exe` (the 6.6
engine, image base 0x400000), for the Godot port (`game/src/battle/battle_ai.gd`, `battle_stage.gd`). Duels,
debates (舌战) and the training ground (练武场) are in [duel.md](duel.md). Memory layouts: [memory.md](memory.md);
data tables (strategy, family attribute rows k0..k8 at 0x4d20c0 + 40k, MgAIYN tables): [rules.md](rules.md);
formulas (damage, hit rate, move cost, range / area shapes, status and buff rules): [battle.md](battle.md);
effects / 特效 (`Eff(a, b)` below): [skills.md](skills.md); script ops: [eex.md](eex.md).

Confidence tags: **[C]** read in the disassembly (Ghidra only as a cross-check), **[G]** interpretation / naming,
**[?]** open. The 6.6 engine is hand-written assembly over CCZ: objects in `ecx`, results often in `ecx`/`edx`,
callees reading the caller's pushes. wg2025 (rea) addresses do not carry over; §6 lists the behavioural
differences from wg2025's port (rea/docs/rules.md §9–§10).

**Notation.** `U[i]` = battle unit slot i (0x30 bytes at 0x4a7b20 + 0x30·i, getter 0x4061f9 returns the pointer in
ECX); slots 0–19 player (我军), 20–59 friends (友军), 60–249 enemies (敌军 / 援军); slot 60 = the first enemy
("leader"). `P[p]` = person record ([0x4cea00] + 0x48·p). `ctx` = battle object 0x4b3d08. `R` = script reader
0x492f90. `EV n` = script int variable n at 0x502000 + 4n (config EVs 4016..4095 listed in
`修改器與修改記錄/變量計算+意義.txt`). `side(U)` = 0x406710 (§2.1). `MaxHP` = 0x407263(person),
`MaxMP` = 0x40728f(person). `rand(n)` = 0x47fb13(n) = (n < 2) ? 0 : R mod n (RNG 0x47fae7, battle.md).
Integer arithmetic is unsigned 32-bit unless stated; "byte" = 8-bit with wrap-around. Option bytes of the 6.6
options menu (list of 16-byte strings at 0x4beec0: `5-显示生命条` … `p-极速移动`) live at 0x501a60 + k, k = the
option's base-36 key (e.g. `i-显示AI方针` = 0x501a72).

`Eff(a, b)` / `Effect(U, a, b, …)` / `query(a, b, …)` all denote the effect query 0x4101d9(a, b, c, d) on a unit: `a`
= 特效 id (16-byte names at 0x4cc600 + 16a), `b` = item-effect id (names at 0x4cb7a0 + 16(b − 0x1a)); the
semantics are in skills.md.

Contents: §1 battle flow · §2 sides, armies, action order · §3 AI modes and fields · §4 the AI turn ·
§5 player phase and AI displays · §6 differences from wg2025 · §7 open questions.

## 1. Battle flow
### 1.1 Battle object fields used by the flow [C]

| ctx off | meaning | written by |
|---|---|---|
| +0x00 | u8 copied to GS+5 at battle start (save-list label) | 0x44d2f8 |
| +0x01 | **result**: 0 running, 2 victory, 3 defeat, 5 abandoned (a save was loaded), 6 / 7 transient UI requests (end phase / next unit, consumed by the player loop) | SetResult 0x40be38 |
| +0x02 | round counter, 0-based (shown turn = +2 + 1) | 0 at start, +1 after each round (0x44efaa) |
| +0x03 | turn limit (from R+0x3d0e = op 0x45 a2; op 0x5d changes it) | 0x44d362, 0x41709c |
| +0x04 | weather level 0..5 (R+0x3e92 at start) | 0x449f91 |
| +0x10 | phase: 0 player, 1 friend (ally AI), 2 enemy | round / phase loops |
| +0x11 | climate row 0..4 (R+0x3e91) | battle start |
| +0x500 | "next unit / menu pending" flag (player loop) | 0x44e482 |
| +0x504 | dword: re-order request for the running AI phase | 0x43b328 (AI cast strategy 0x39), cleared 0x44e830 / 0x44eae9 |
| +0x520 | 1 while the player-phase input loop runs, else 0 | 0x44edfd |

### 1.2 Battle entry, battle loop and end [C]

```
BattleEntry 0x44f058(ctx):
    resume = [0x497738]                         # a battle save is being loaded
    resume ? Restore 0x44d0af : BattleStart 0x44d2ca            # §1.7
    ...UI init (0x410d1f, 0x44a971)
    if result == 0 and !resume:
        while R+8 != 0: 0x4180c1(R)             # run the S file's opening (deployment / pre-battle talk)
    ...draw (0x449ef0, 0x44a36f), turn display 0x410549, ...
    return BattleLoop(resume)                   # the scene loop 0x42c228 seeds the RNG word 0x48ecd4 =
                                                # GetTickCount() mod 0x7fffffff just before calling this

BattleLoop 0x44eee5(resume):
  loop:
    if ctx.result != 0: break
    if ctx.turn >= ctx.limit:                   # time out
        MessageBox 0x42f699(2, "因为战斗时间过长，撤退。" @0x48e220)
        for i in 0..59: if U[i].person == 0: RemoveUnit(U[i], 0, 0) (0x441744); found; break
        if !found and U[0].state == 2: RemoveUnit(U[0], 0, 0)
        ctx.result = 3; break
    byte 0x4b4238 = 0                           # "next unit" cycle index
    if !resume and ctx.turn != 0: Weather(0xff) (0x449f91)       # every round except the first / a resumed one
    Round(resume) (0x44ed7f); resume = 0
    if ctx.result == 5: teardown (0x4364bd, 0x41ba73, …) and return 5   # no end processing
    ctx.turn += 1                               # also after the round that set a result
  BattleEnd 0x44ebe8((ctx.limit - ctx.turn) * 4)                       # byte arithmetic: (u8)(limit - turn) * 4
  return ctx.result
```
* With limit L the rounds with `turn` 0..L−1 are played (shown 第1..第L回合; the banner says 最终回合 when shown
  turn ≥ L); the check before round L ends the battle as a defeat.
* BattleEnd(bonus) 0x44ebe8: teardown; **only if result == 2**: keeps running the script (0x4180c1) until it returns
  2 or 4 (the victory event section), then for slots **0..34** (0x23 — a CCZ leftover) on the map whose person is
  in the army (0x42ac58): 功勋 +bonus for each of the 5 abilities (0x42a9c4, persons < 0x66 only) and
  P+0x28 = min(P+0x28 + 1, 255) (battles won). Then 0x408fa0 (功勋 pooling), cleanup, 0x4180c1.
* Result handling by the scene loop 0x42c228 [C]: 1 → result reset to 0 and the battle is run again (no setter of
  1 found [?]); 3 → scene flag 0x20 (defeat / game over); 4 → 0x40 (no setter found [?]); 5 → 0x08 (load);
  anything else (2) → the script continues (0x417e95).

**Who sets the result** [C]: op 0x49 战斗结束 (0x417ad7) → 2; op 0x0e 战斗失败 (0x415890) → 3 (both only in
battle mode, via 0x4144ab); time out → 3; Load menu during a battle (0x419866) → 5; battle menu ids 0x6d / 0x6e
(0x4102f8 / 0x416fbc) → 6 / 7. **Victory and defeat are script-driven**: the engine never ends a battle by itself
except by the turn limit. The S script's event sections test the standard conditions with op 0x42 / 0x43 (§1.8)
and then execute 0x49 / 0x0e.

### 1.3 One round 0x44ed7f(resume) [C]

```
Round(resume):
  0x410549                                  # turn/limit display
  TurnBanner 0x44ac28(turn+1, 0, resume, 0)  # "我军阶段" + "第%2u回合" / "最终回合"; see below
  if !resume:
      ctx.phase = 0; Poll(); if turn == 0: Poll()       # the first round polls twice
      if result: goto friend_enemy              # (returns at once)
      if byte EV4077 (0x505fb4, 伪随机) != 2: EV4077 = 0    # current side for the pseudo-random mode
      SideUpkeep(0) (0x44ee30)                 # player side, slots 0..59 (§1.5)
      0x423490(0x508998): 104 bytes = rand(100)+1 each     # 104 RNG calls every player phase [C]
      0x40ec9d: tick the 10 timed map objects at 0x501ae2 (3 B {x, y, timer}; timer 0 → 0x456670(x,y,0,0)
                removes it, count byte 0x501ae1 −1; timer 0xff = free)
  ctx+0x520 = 1; 0x449de6(1) (UI on); PlayerLoop(resume) (0x44e0d9, §1.6); ctx+0x520 = 0; 0x449de6(0)
friend_enemy:
  if result == 0: AIPhases() (0x44e825, §1.4)
```
TurnBanner 0x44ac28(turn, kind, resume, colour_phase): draws "我军阶段" (kind 0) / "敌军阶段" (kind 1) (strings
0x48e154 / 0x48e160) and for kind 0 the turn line. If `resume == 0` (always for the enemy phase):
```
for i in 0..249: U[i].flags &= ~6 (0x406690);  dword U[i]+0x22 = 0 (clears +0x22..+0x25, incl. the
                 extra-action byte +0x24 and the attack counter +0x23);  byte 0x508b00[i] = 0
byte 0x501bf9 = 0xff;  KindSwap(colour_phase) (0x416f38, §2.1)
```
So action flags of **all** 250 units are cleared at the start of the player phase and again at the start of the
enemy phase; the friend phase clears nothing.

### 1.4 Friend and enemy phases 0x44e825 [C]

```
AIPhases():
  ctx+0x504 = 0
  for ph in (0 = friend, 1 = enemy):
    if result != 0: return
    if ph == 1:
        TurnBanner(turn+1, 1, 0, 2); ctx.phase = 2; Poll(); if result: return
        if EV4077 != 2: EV4077 = 1
        SideUpkeep(1)                           # enemy side, slots 60..249
    else:
        ctx.phase = 1; Poll(); if result: return
    lo, hi = (0, 60) if ph == 0 else (60, 250)
    ActionOrder(ph == 0) (0x44da7a, §2.2)
    for pass in (0, 1):                         # byte 0x500c47 = pass (2 after the loop)
      k = 0
      while result == 0 and k < 250:
        i = first slot in [lo, hi) with U.state == 2 and U.order == k and U.ai != 7
            and !(U.flags & 4) and !(U.flags & 2)
        if i exists:
          if !(byte 0x4b4230 & 4):              # debug flag, never set by the exe (only cleared, 0x401843) [?]
              0x42b81b(0)                        # cursor/UI refresh
              CurrentUnit(U) (0x406240: U+0x24 &= 0x7f; [0x4b5df0] = person; [0x500ac0] = U)
              if CanSpecial(U) (0x4225fb) == 1: PickPersonalSpecial(U) (0x4225a2)   # §1.9
              AIAct(U) with AL = 4 (0x43ad3b; AL is the walk speed handed to MoveAlongPath)
              word 0x500e9a = 0; SendMessage(main, WM_LBUTTONUP)
              if U.flags & 2: UnitActed(i) (0x45b609)      # event slot 3 + Poll (§1.10)
          PostAction() (0x42bc14)                          # §1.10
          if ExtraAction(i) (0x41b508): k -= 1             # same order slot again → the unit acts again
          else:
              if FreeAction(i) (0x412d52): k -= 1
              while byte 0x500e9c != 0:                    # 围攻 partners queued by the last attack
                  n = --0x500e9c; FreeAction(byte 0x500e9d[n])
          if result == 0 and U.flags & 2: 0x43fcc9 (camera to U); Poll()
        if ctx+0x504: ActionOrder(ph == 0); ctx+0x504 = 0; k = 0 (via 0xff + 1); continue
        k += 1
```
* **Who acts where**: friend phase = slots 0..59 whose AI code ≠ 7 (allies, and player units only if a script gave
  them an AI code — party members refuse SetAI, §1.7); enemy phase = slots 60..249 with code ≠ 7 (敌军 and 援军, and
  controlled enemies of EV 4078 = 1). Code 7 units never act in an AI phase.
* No restart after an action: k simply continues (differs from wg2025 §9.1's wording). The scan restarts at order 0
  only on a ctx+0x504 request; that is set **only** when an AI unit casts strategy id 0x39 (0x43b31b) — id 57 is
  援队 in 6.6's strategy table (a CCZ leftover: 战备 in wg2025) [C; meaning G]. Units that appear during a phase
  (op 0x4c) got order 0xff at phase start and do not act in that phase [C].
* **The two passes** [C]: the pass number is read only by Active 0x43a7c9 (AI code 1, also the fallback of
  GoTarget / retreat): when an attack position is reachable now (Flood mode 8 ≠ 0xff) and the evaluated best cell
  equals the unit's own cell, then `pass == 0 and code < 4` → return (stay); `pass == 1 or code ≥ 4` → ignore the
  stay and advance toward the nearest attackable opposite unit (the "no attack position" branch). Flags are not
  cleared between the passes and the scan skips flags 2/4 in both, so pass 1 is a second chance for exactly the
  units that did nothing in pass 0: a move sets 4 (MoveAlongPath 0x43aa1b, only if dest ≠ pos) and then 2 at the
  end of AIAct (0x43b34b), an attack sets 2|4 (0x43acfe / 0x43ad08), a cast sets 2|4 (0x41c0e8, called right after
  the cast at 0x43b30f); a unit that neither moved, attacked nor cast keeps its flags clear. Effect: in pass 0 everybody that can do
  something does it, idle units wait; in pass 1 idle active units advance after the others have moved. Units that
  stay idle in both passes (hold / passive) simply run AIAct twice.

### 1.5 Side upkeep 0x44ee30(s) — start of the player phase (s = 0, slots 0..59) and of the enemy phase (s = 1, slots 60..249) [C]

```
lo, hi = (0, 60) if s == 0 else (60, 250)
0x42fc0c(eax = s)          # timed map objects / traps list 0x512dc0 (4 B records {?, timer, u16 owner});
                           # timers of objects whose owner is not of side s count down [G, see battle.md]
for i in lo..hi-1:
    StatusRecovery 0x4263b0(U[i])     # on map and any status: cure roll (rate 0x43c72c(U,1)) or clear-all effect
    BuffDecay 0x43c940(U[i])          # 6 buff bytes toward 3; also the per-unit timers 0x501b00[i] (kind-0 units)
                                      # and, for slots ≥ 60, the control counter 0x501ad8[i] (§2.1)
clear byte 0x508a00[j] for the OTHER side's slots (0x420952: s == 0 → j = 60..249, s == 1 → j = 0..59)
Poison 0x44dfc7(s)                    # units of the side on the map with 中毒 (status mask 0x10, 0x423fe8):
                                      #   0x44e024(U, 0x14, 1) then 0x4158dc(U)
for i in lo..hi-1: Regen 0x43cddd(U[i])
```
Formulas of the four routines: docs/battle.md. Status byte +0x1e = four 2-bit turn counters
(麻痹 0-1, 禁咒 2-3, 混乱 4-5, 中毒 6-7); `StatusTest(U, mask)` 0x423fe8 with mask 2 / 4 / 8 / 0x10.
Friends (slots 20..59) get their upkeep at the **player** phase start, not at the friend phase.

### 1.6 Player phase loop 0x44e0d9(resume) [C, UI details G]

Summary (details, clicks and prompts: §5.1): the loop runs while some slot 0..59 has code 7, state 2 and no
flag 0x80; after every completed command it runs PostAction, 再次移动, the extra actions and a Poll, and
offers the end prompt when no code-7 unit of any slot is left without flag 2 (confused units do not count).

* Commandable (0x43d4fc start) [C]: `Side(U) == 1` (§2.1) and `!(U.flags & 0x80)` and `U.ai == 7`; other units can
  only be inspected (move range shown). (Debug bit 0x4b4230 & 4 lifts the side test.) NextUnit (0x44e706) cycles
  only through slots 0..59 with kind 0 (0x43ff54), code 7, state 2, flags 2 and 4 clear and not 混乱.
* Quirk [C]: the "anyone left?" count runs over all 250 slots, so a code-7 unit that cannot be commanded
  (EV 4078 = 2 controlled enemy, §2.1) keeps the phase from ending automatically.
* The per-unit command menu (攻击/策略/道具/待机/必杀/围攻…) is §5.3.

### 1.7 Battle start 0x44d2ca and unit creation 0x43bb15 [C]

```
BattleStart(ctx):
  GS+5 = ctx[0]; byte 0x4b4234 = 0
  ctx: +5 = 0, +1 +2 = 0 (result, turn), +8 dword = 0, +0xc dword = 0, +0x10 = 0, +0x4fc = 0, +0x500 = 0
  ctx+0x11 = climate (byte 0x496e21 = R+0x3e91); ctx+4 = weather level (byte 0x496e22 = R+0x3e92)
  byte 0x501ae1 = 0; bytes 0x501ae2..0x501aff = 0xff        # timed objects free
  ctx+3 = turn limit (byte R+0x3d0e)
  … map load, terrain-change records ctx+0x19 (250 × 5 B) = 0xff, unit grid = 0xff …
  CreateUnits 0x43bb15
  for i in 0..249:
      U.flags &= ~0x80;  U.status = 0 (0x423fb9(0x1e))
      if U.state != 0: load the unit sprite (0x43fe2c)
      if i < 60 and kind(U) (0x413172: +5 if ≤ 6 else 0) == 0: U.ai = 7         # player units
  0x44d227 (camera, UI)
```
CreateUnits 0x43bb15: reloads Data.e5 persons (0x41b533), then walks the 250 deployment entries
E(j) = 0x494fd4 + 16·j (0x418dd0; filled by ops 0x44/0x46/0x47/0x48/0x4b — docs/eex.md) with three counters
`player = 0, friend = 20, enemy = 60`:
```
for j in 0..249 with E.person (u16 +0) != 0xffff:
   f = byte E+8
   f & 3 == 0  → UnitInit 0x40c990(U[player++], person, f, E.x (+4), E.y (+5))        # no SetAI
   f & 1 == 0, f & 2 (ally):
        army member (0x42ac58: P+0x2a != 0xff) → UnitInit 0x40c990(U[friend], …); idx = friend++
        else → idx = friend++; Generate 0x42ad35(f, E, person, E+4)    # reload base data 0x46206c, UnitInit
                                                                        # 0x44274c, promote 0x442890(E+2,E+3),
                                                                        # equip 0x44299b ×3 (E+9/+6, E+0xa/+7,
                                                                        # E+0xb), HP/MP full
        SetAI(person, E+0xc mode, u16 E+0xe, E+0xe x, E+0xf y, idx)  (0x459d95)
   f & 1 (enemy / 援军): idx = enemy++; Generate; SetAI(…)
```
UnitInit (0x44274c, docs/memory.md §4) sets person, state 1, kind (0x425d9a: f&3 = 3 → 3, 1 → 2, 2 → 1, 0 → 0),
facing, HP/MP, buffs 3, status 0, then places the unit (0x442b03; hidden flag f & 4 → stays state 1 off-map until
op 0x4c reveals it). It does **not** touch +8..+0xb, +0xd, +0xe: target unit / point, order, flags and AI code keep
whatever the slot held before unless SetAI or the loop above writes them.

SetAI 0x459d95(person, mode, tperson, tx, ty, idx) [C]:
```
U = idx != 0 ? U[idx] (fails if its person is 0xffff) : UnitOf(person) (0x41b882 / 0x456079)
fail (return −1) if no unit, or mode ∉ 0..7 (signed byte), or P[U.person]+0x2a != 0xff (army member)
U.flags &= ~0x80; U.target = 0xff; U.ai = table 0x48e379[mode]       # 0x442669 (ignores values > 7)
mode 3 / 5: U.target = slot of UnitOf(tperson) (0x42632c; nothing if the person has no unit)
mode 4 / 6: if tx < map W and ty < map H: U.point = (tx, ty), U.target = 0xff (0x427fb0 → 0x44268c)
```
| mode (editor name, CczString.ini) | 0 被动出击 | 1 主动出击 | 2 坚守原地 | 3 攻击武将 | 4 到指定点 | 5 跟随武将 | 6 逃到指定点 | 7 (no name) |
|---|---|---|---|---|---|---|---|---|
| AI code (0x48e379) | 3 | 1 | 2 | 0 | 0 | 4 | 4 | **7** = player controlled |

UnitOf(person) 0x41b882: `person ≥ 0x404` → slot person − 0x404; else if EV 4031 ≠ 0 and person < 250 → slot
person; else the first slot whose person matches and whose state ≠ 0 (0x456079).
Consequences [C]: an ally that is an army member keeps the slot's stale AI code / target (SetAI refused; as in
wg2025); a script can hand any non-member unit to the player with op 0x4e and mode 7.

#### 1.7a AI fields that are never reset (initial values) [C]

The unit array 0x4a7b20 is zero BSS (beyond .text2's raw data), saved and restored with battle saves (+0x04..+0x0f,
+0x18..+0x2f). There is **no per-battle reset** of the AI fields (wg2025 had one, 0x442613): UnitInit 0x44274c,
re-entry (op 0x55 → UnitInit), BattleStart and RemoveUnit leave them alone. Complete writer lists (byte-pattern
search over .code/.text1/.text3 plus call sites):

| field | initial (fresh process) | written by |
|---|---|---|
| +0x08 target slot | 0 | SetAI (0xff, then mode 3/5 slot 0x42632c→0x443140); AIAct start (0xff + code 1 if the target is not on the map, 0x43adbb); point setter 0x44268c (0xff); RemoveUnit (0xff + code 1 for codes 0/4 targeting the removed unit); army-change copy 0x4081a6 (dword +8 = 0xff ⇒ +8 = 0xff, +9 = +0xa = **+0xb = 0**); scripted move restores it (0x459612); 练武场 setup 0x437078 (U[60]) |
| +0x09/+0x0a point x, y = **AI-area corner 1** | 0, 0 | SetAI modes 4/6 via 0x427fb0→0x44268c (only if inside the map); 0x4081a6 (0, 0); op 0x72 cmds 11 / 17 (below); scripted move save/restore |
| +0x0b order | 0 | ActionOrder only (§2.2); 0x4081a6 (0) |
| +0x0e AI code | 0 | SetAI, battle start (7 for kind-0 slots < 60), AIAct (1), arrival (3, 0x43fd29), RemoveUnit (1), 0x4081a6 (7 for the player army, else 1), 0x4073bc (7 / 1), scripted move (0, then restore) |
| word +0x20 = **AI-area corner 2** (x = +0x20, y = +0x21) | 0x0000 | only op 0x72 信息传送 cmd 11 "限定AI行动范围(逐个)" (0x44ce20: list of persons / slots) and cmd 17 "限制区域AI行动范围(范围)" (0x42c846: every unit inside a rectangle): for each unit whose code ≠ 7: word +9 = (x1, y1), word +0x20 = (x2, y2). Copied along by 0x4081a6. (+0x21 of slots 0 and 60 is also used as a duel / 练武场 work field: 0x425d3f, 0x42b6b7, 0x436fef.) |

AiAreaOK 0x4077f6(U, cell) (called from 0x437f69 / 0x43877a): `true` if code == 7 or code is even (0 / 2 / 4),
or word +0x20 == 0xffff; otherwise AreaTest 0x414f05(c1 = word +9, c2 = word +0x20, cell): if U's **current**
cell is outside the inclusive box [c1.x..c2.x] × [c1.y..c2.y] → `true` (no restriction); else `cell` must lie in
the box. Box tests are unsigned byte compares, so with the fresh value c2 = (0,0) the box is empty unless
c1 = (0,0) — i.e. "no area" in practice, but a unit standing on (0,0) with point (0,0) is confined to (0,0).
Nothing writes 0xffff into +0x20 except a script (op 0x72 with x2 = y2 = 0xff). SetAI does **not** reset the area,
but a mode-4/6 SetAI moves corner 1 (the shared target point), so a stale corner 2 from an earlier battle or an
earlier order can combine with a new target point.

### 1.8 Victory / defeat tests (ops 0x42 / 0x43) [C]

op 0x42 战斗胜利测试 (0x411bd0) runs **0x428f36** and returns event slot 5 == 1; op 0x43 战斗失败测试
(0x411ba5) runs **0x44ca6d** and returns event slot 6 == 1.
```
VictoryTest 0x428f36:                 # sets event slot 5 = 1 (0x44f840) when true
  if ctx.result != 0: return 1
  for i in 60..250 (inclusive: slot 250 is read past the array — quirk):
      if U[i].state ∈ {3,4} and R+0x3d04 bit0 and U[i].person == u16 R+0x3d06: slot5 = 1; return 1   # boss
  if CountUnits(5) == 0: slot5 = 1; return 1          # no 敌军/援军 (kind 2/3) on the map
  return 0
DefeatTest 0x44ca6d:                  # sets event slot 6 = 1 (0x44f880)
  if ctx.result != 0: return 1
  for i in 0..60 (inclusive: also slot 60, the first enemy — quirk):
      if U[i].state ∈ {3,4} and R+0x3d08 bit0 and U[i].person == u16 R+0x3d0a: defeat     # protected leader
  if U[0].person != 0: if CountUnits(0) == 0: defeat              # no kind-0 unit on the map
  else: if no slot 0..20 (inclusive, quirk) has state 1 or 2: defeat
  return 0
```
CountUnits 0x428df1(code, rect, x1, y1, x2, y2): counts slots with state 2 matching `code` (0x44cb12) on the whole
map or (rect == 1) in the rectangle; returns the count (AL) and the first match (DL). Matching 0x44cb12: k = kind
(0x413172), but kind 2 in slots < 20 counts as 0 and in slots 20..59 as 1; code ≤ 3 → k == code; 4 → k ≤ 1;
5 → k ∈ {2,3}; 6 → any. Kinds 5/6 (controlled enemies, §2.1) match only code 6, so **a battle whose remaining
enemies are all controlled passes the "all enemies gone" test** [C].

### 1.9 Specials before AIAct [C]

```
CanSpecial 0x4225fb(U):                     # 0 = no, 1 = personal 武将技, 2 = family 军师技
  if EV4059 (0x505f6c 禁止必杀) != 0: return 0
  t = attr8[family(U)] (0x4d2200)
  if t != 0: k = 1; need = byte (0x4a7510 + (0x4f + t)·16)+0x0e        # cost of skill 79+t (军师技 80..88)
  else:      if U.ai == 7: return (ECX & ~0xff) + 1   (non-zero garbage; AL = 1)
             k = 0; need = byte EV4061 (0x505f74 必杀所需SP)
  if StatusTest(U, 4) (禁咒): return 0
  if SP[person] (byte 0x501c00 + person) < need: return 0
  return k + 1
PickPersonalSpecial 0x4225a2(U):            # only when CanSpecial == 1 (AL compared)
  for s in 1..0x4f: if 0x418744(person, s) == 1 (person knows 武将技 s) and SP[person] ≥ byte(0x4a7510+16·s)+0x0e:
      word 0x500e9a = (s << 8) | 2; return
  word 0x500e9a = 2
```
AIAct reads word 0x500e9a (§4.12); the phase loop clears it after AIAct.

### 1.10 After an action [C]

```
UnitActed 0x45b609(i):     # only if ctx.result (byte +1) == 0 and U[i].state == 2
    event slot 3 = {u32 person, u32 x, u32 y} (0x40ffb2(R, 3, …, 12)); Poll()
PostAction 0x42bc14:
    for every unit on the map with HP == 0: RemoveUnit(U, 0, 0) (0x40502b)
    for every unit on the map with HP ≠ 0 and Effect(U, 0x12 反弹异常攻击, 0x2a, 1, 1) (0x472c53):
        if status: cure (0x42402c(U, 100)); every buff < 3 → 3 (0x45aa37(person, b, 3, 1, slot))
ExtraAction 0x41b508(i):   # granted by 0x4290c8 after a kill (callers 0x4037a3 attack / 0x420efb strategy):
                           # n = Effect(U, 0x40 大杀四方, 0x54, 1, 0); if n and (U+0x24) < n: U+0x24 |= 0x80
    if U+0x24 & 0x80: U+0x24 &= 0x7f; if U.state == 2: U+0x24 += 1; Reenable(U); return 1
    return 0
FreeAction 0x412d52(i):    # once per phase per unit (byte 0x508b00[i], reset by TurnBanner)
    if U.person != 0xffff and U.HP != 0 and 0x508b00[i] == 0 and Effect(U, 0x38 二次行动, 0x5a, 1, 1) (0x421175):
        Reenable(U); 0x508b00[i] = 0xff; return 1
    return 0
Reenable 0x412d9d(U): U.flags &= ~6; animation 0x43e6aa(slot, 6, 0x88)
```
The 围攻 queue (count byte 0x500e9c, slots 0x500e9d[]) is filled by the attack code (0x405bf2 collects up to 8
partners around the target, 0x44eb2d filters them; 0x417d4b) and drained after the action: each partner gets
FreeAction (phase loop) or ExtraAction-then-FreeAction (player loop). A re-enabled partner acts again in an AI phase
only if its order is still ahead of k [C].
In the player phase 0x43d4fc marks 0x508b00[i] = 1 (blocked) when the commanded unit lacks effect 0x38.

RemoveUnit 0x441744(U, silent, anim) [C] (only state 2): silent → vanish (0x454f10); else the retreat line
(0x40c00f) if U+0x1f ≠ 0 and kind 0, camera + animation 2 if anim or person == 0, else SE 0x10 + animation 0;
off the map (0x42a297); army members P+0x29 += 1 (≤ 255) unless silent; state 3, status 0; **every unit whose
target slot is this unit and whose AI code is 0 or 4 gets target 0xff and code 1** (as wg2025).

### 1.11 When the script's event sections are polled [C]

Poll = 0x44c601: for k < R+0x24 (section count): 0x4180c1(R) (select + run); stop when R+8 == 0.
1. Battle entry: the opening runs while R+8 ≠ 0 (§1.2), not a Poll.
2. Player-phase start (after the banner and flag reset): Poll; on round 0 twice.
3. Friend-phase start: Poll (ctx.phase = 1).
4. Enemy-phase start (after banner, flag reset, KindSwap): Poll (ctx.phase = 2).
5. After each AI unit that finished its action (flags & 2): UnitActed → Poll, and after PostAction / extra
   actions again (camera to the unit, Poll).
6. After each completed player command: UnitActed → Poll (0x44e3f6), then after PostAction / extra actions Poll.
7. Inside some multi-hit attack effects (0x449c0d → 0x439413 → 0x4065d9: Poll + PostAction per hit) and when a
   script op kills a unit (0x406e0f → 0x46d05a: Poll + PostAction).
Every Poll is skipped / its effects stop as soon as ctx.result ≠ 0 (callers check +1).

### 1.12 Weather 0x449f91(w) [C] (same as wg2025)

`w < 6: level = w` (script / strategy); else random walk: `c = level + 1; r = rand(8); if c > r: c −= 1
elif c ≠ r: c += 1; level = (c == 0) ? 5 : (c == 7) ? 0 : c − 1` (compare on the low byte). Shown weather =
table 0x48e100[climate·6 + level] (0x41553b): rows `0 0 0 1 2 3 | 0 0 0 0 1 2 | 0 1 2 2 3 3 | 0 0 1 1 4 4 |
0 1 4 4 4 4` (0 晴 1 阴 2 雨 3 暴雨 4 雪). If the shown weather changed the weather panel (image 0x34 + weather) is
redrawn. Called with 0xff at every round start except round 0 and a resumed round (one rand(8) per round).

### 1.13 Other script ops that act on the flow [C]

* op 0x5d 回合上限设定 (op, v) (0x41709c), battle only: op 1 → limit = min(limit + v, 255); op 0 → limit = v, but
  at least turn+1; op 2 → limit −= v, but at least turn+1; 0xffff → nothing. Refreshes the turn display.
* op 0x51 战场恢复行动权 (0x416276): every unit on the map: flags &= ~6, all statuses cleared, HP = max HP.
* op 0x54 战场撤退确认 (0x4144d2): PostAction now (units with 0 HP leave).
* op 0x3f test_turn compares turn+1; op 0x40 tests ctx.phase (0/1/2) (docs/eex.md).
* Scripted move (0x4594ea, used by the battle 武将移动 op): saves target / code / flags / point, sets flag 0x80,
  code 0 with the target point and runs AIAct (flag 0x80 → move points 100, no attack), then restores everything
  and sets the facing. Flag 0x80 also bars a unit from being commanded (§1.6) [C].

## 2. Sides, armies and the action order
### 2.1 Sides, armies, colours [C]

| slots | army | kind byte +5 (UnitInit) | acts in |
|---|---|---|---|
| 0..19 | 我军 player | 0 | player phase (code 7) |
| 20..59 | 友军 ally | 1 | friend phase (AI) |
| 60..249 | 敌军 enemy | 2 | enemy phase (AI) |
| 60..249 with the second deploy flag of op 0x47 | 援军 (third army) [name G] | 3 | enemy phase (AI) |

**Side** 0x406710(U) = table 0x40672d[k] with k = kind, except kind 3 with EV 4053 (0x505f54 援军和敌军是否对攻)
≠ 0 → k = 4: `kind 0,1 → 1; 2,3 → 0; (3 + EV4053) → 2; 5,6 → 1`. **Two units are hostile iff their sides
differ** (e.g. PhysScore 0x438a09/0x438a14, strategy target test 0x439127/0x439136). With EV 4053 the 援军 side 2
is hostile to everybody; without it 援军 fight with the enemy.
ZOC / blocking (0x437d59, Flood 0x438484 → 0x4387b0, 0x438ebd) compare sides through 0x42e2b7(a, b, fn = EAX), which
returns `side(a) != side(b)` **in EDX**; if the caller passes fn = 0 the side function is table 0x42e2e5[EV 4019
(0x505ecc, 深入敌后 超级卡位)]: 0 → 0x406710, 1 → 0x42e2ed = "home side": k = 0 for slots < 20, 1 for 20..59,
for ≥ 60 the kind but 5 → 2 and 6 → 3 unless the control counter 0x501ad8[slot] ≠ 0 (then 5/6 stay), 3 → 4 with
EV 4053. (Values ≥ 2 of EV 4019 index past the table.)

Sprite colour (0x43fc48): `entry = graphic·3 + min(kind, 2)` for graphics < 0x50 — colour 0 player, 1 ally, 2 enemy;
援军 (3) and controlled enemies (5, 6) are drawn in the enemy colour.

**KindSwap 0x416f38(p)** — run by TurnBanner, p = 0 at the player-phase start, 2 at the enemy-phase start; for
every unit on the map, with `e = Effect(U, 0x46, 0x68, 0, 1)` (0x478e6f; 特效 0x46 = 深入敌后 by the name table 0x4cc600,
item effect 0x68 = 深入敌后; semantics: skills.md):
```
if e == 0:
    if p == 0:  slot < 20 → kind = 0;  20..59 → kind = 1;  ≥ 60 → Revert
    if p == 2:  slot ≥ 60 → Revert
else:
    if p == 2:  slot < 60 → kind = 2;  ≥ 60 → if kind ≥ 5: kind −= 3
    if p == 0:  slot < 20 → kind = 0;  20..59 → kind = 1;  ≥ 60 → kind += 3
Revert: if byte 0x501ad8[slot] == 0 and kind ≥ 5: kind −= 3
```
So every player-phase start also resets the kind of all player-side slots to 0 / 1.

**Controlled enemies** (EV 4078, the "6th new strategy") [C mechanics, G naming]: the strategy result code
(0x420c0b, case 8 of 0x420bd3) calls 0x4073bc(U, &0x501ad8[slot], 2): counter = 2 and by EV 4078 (0x505fb8):
0 → kind += 3 and ai = 7 (player-commandable ally), 1 → kind += 3 (AI ally that still acts in the enemy phase),
2 → ai = 7 only (stays on the enemy side and simply does not act). Release 0x4073bc(U, ptr, 0): counter 0,
kind −= 3, ai = 1. In BuffDecay (0x43c940) for slots ≥ 60: counter c ≠ 0: c == 1 → (chance 100, 0x43786b) message
0x427cbc(0x2c) and release; else c −= 1 — i.e. counted down at each enemy-phase upkeep, released at the start of
the second enemy phase after the hit. (Note: modes 1 and 2 apply only one of the two changes, but the release
undoes both — faithful quirk.)

### 2.2 Action order 0x44da7a(side_player) [C]

Range: side_player ≠ 0 → slots **0..58** (`[ebp-0x10] = 0x3b`, exclusive — slot 59 is skipped); else 60..249.
**Slot-59 quirk** [C]: +0xb of slot 59 is never written by ActionOrder; the only other writers are the army-change
copy 0x4081a6 (order := 0) and save loading, and the unit array is zero BSS (0x4a7b20 lies past the raw data of
.text2), so in practice U[59].order == 0. The phase scan takes the **first** slot with order == k that has code ≠ 7
and no flags 2/4, so the slot-59 ally competes for k = 0: it acts at k = 0 of pass 0 when the order-0 holder is a
code-7 player unit (the usual case, pass 0 below orders player units first) or has already acted, otherwise at k = 0
of pass 1.
```
for i in range: U.order = 0xff
n = 0
for pass in 0..8:                           # jump table 0x44dc37
  for i in range with U.state == 2:
    pass 0: c = CanSpecial(U) (0x4225fb); if c == 0: skip
            if attr8[family(U)] (0x4d2200) == 9: U.order = 0x75; skip       # 都督 军师技 (全体回归) goes last
            Assign
    pass 1: if terrain(U.pos) ∈ 18..22 (城池 关隘 鹿砦 村庄 兵营; 0x428a25 → heal% 0x41e467 25/20/20/15/20 ≠ 0): Assign
    pass 2: if Wounded(U) (0x439cfe): Assign
            Wounded: HP ≠ 0 and (person < 0x400 ? HP ≤ MaxHP·2/5 : class ≠ 0x31 and family ≠ 0x32 and HP ≤ MaxHP/5)
            (MaxHP = 0x407263; integer division; unsigned compares)
    pass 3: if EV4063 (0x505f7c) == 2:
                m = CustomOrder(i, end, n) (0x44dc5b): for t in 0..5: for j in i..end-1 with state 2, order 0xff
                    and table 0x44dccc[family(U[j])] == t: U[j].order = m++
                if m != n: n = m; pass = 8 (skip 4..7); next pass
            if attr5[family] (0x4d2188) != 2 and family != 9: Assign       # 0x4190e8; family 40 also passes
    pass 4: if EV4063 == 0: skip the whole pass
            c = class record (0x41b782(P.class)); if c[2] ≥ 4 or c[3] ≥ 4: Assign   # 攻击 / 防御 growth grade (0x40dbae)
    pass 5: if attr3[family] (0x4d2138) != 0: Assign        # ranged: 弓兵 弓骑兵 炮车 女弓兵 井栏
    pass 6: if family ≤ 39 and attr1[family] (0x4d20e8) == 0: Assign   # 0x4011e8: 君主 骑兵 弓骑兵 驃騎兵 西凉骑兵 統軍
                                                          # 女騎士 白马骑 特種兵 飛行者 閹兵 仙人 蛮骑兵 陷阵营 魔王 石像鬼
    pass 7: Assign
    pass 8: if U.order == 0x75: U.order = n++
  Assign: if U.order == 0xff: U.order = n++
```
family(U) = 0x43b4a7 = 0x40bf0c(P): class ≤ 59 → class/3, 60..79 → class − 40, else 40 (tables are indexed 0..39;
family 40 reads byte 0x44dcf4 = 0x55 in CustomOrder and never matches → with EV 4063 = 2 such units get no order
and never act — quirk). Table 0x44dccc (EV 4063 = 2 default contents, family 0..39):
`03 00 02 00 02 02 03 03 01 04 01 01 03 00 02 02 01 01 00 01 01 01 00 00 00 00 01 01 01 01 01 01 00 00 00 00 01 01 01 01`.
Pass 3 families (attr5 ≠ 2, not 9): 策士 8, 道士 10, 統軍 15, 都督 16, 咒术士 17, 辎重队 30, 仙人 31.
The mod notes' summary "必杀 > 濒死 > 可恢复地形 > … > 全体回归必杀" has 濒死 and terrain swapped; the code orders
terrain (pass 1) before wounded (pass 2), like wg2025.
CanSpecial returns non-zero for every AI-code-7 unit without a family special (garbage+1, see §1.9), so player
units are ordered in pass 0 — harmless, they never act in AI phases.

## 3. AI modes, AI codes and the per-unit AI fields

### 3.1 Unit fields used by the AI (unit record 0x4a7b20 + 0x30·slot, memory.md §4)

| Off | Meaning for the AI |
|---|---|
| +0x04 | own slot (player 0–19, friends 20–59, enemies 60–249; slot 60 = the enemy leader, "first enemy deployed") |
| +0x05 | kind / colour (side via 0x406710, §2.1) |
| +0x08 | AI target unit slot (0xff = none / the target is a point) |
| +0x09, +0x0a | AI target point x, y; for codes 1 and 3 also the first corner of the **activity area** |
| +0x0b | action order in its phase (§2.2) |
| +0x0c | state (2 = on the map) |
| +0x0d | flags: 0x04 moved, 0x02 action finished (both make the phase loop skip the unit), 0x80 scripted move (set only by the script "move unit" path 0x4594ea, cleared by SetAI) |
| +0x0e | AI code 0..7 (setter 0x442669 ignores values ≥ 8); 7 = commanded by the player |
| +0x20, +0x21 | second corner of the activity area. Written together with +0x09 only by op 0x72 信息传送 cmd 17 (0x42c846: every non-code-7 unit inside a rectangle) and cmd 11 (0x44ce20: a list of persons / slots), see eex.md; initially 0 and never reset (§1.7a) |

### 3.2 SetAI (0x459d95(person, mode, target_person, x, y, slot)) [C]
```
U = slot ≠ 0 ? U[slot] (fails if U.person == 0xffff) : unit of person (0x41b882, else 0x456079)
fail (return −1) if no unit, mode > 7 (signed byte), or the person is an army member (P+0x2a ≠ 0xff, 0x42ac58)
U.flags &= ~0x80 ; U.target = 0xff ; U.code = table_0x48e379[mode]
mode 3, 5: U.target = slot of target_person's unit (0x42632c; nothing if that person has no unit)
mode 4, 6: if x < W and y < H: U.point = (x, y) (0x427fb0; otherwise the old point stays)
```
| mode | code | CCZ editor name [names G] | behaviour (§4) |
|---|---|---|---|
| 0 | 3 | 被动出击 passive | acts when an attack position on some opposite unit is reachable at all |
| 1 | 1 | 主动出击 active | advances on the nearest attackable opposite unit |
| 2 | 2 | 坚守原地 hold | never moves; attacks / casts from its cell |
| 3 | 0 | 攻击武将 attack a person | goes for the target unit (fallback: active) |
| 4 | 0 | 到达地点 go to a point | goes for the target point, fights on the way; becomes passive on arrival |
| 5 | 4 | 跟随武将 follow a person | moves toward the target unit; never attacks or casts |
| 6 | 4 | 逃至地点 flee to a point | moves toward the point; never attacks or casts; passive on arrival |
| 7 | 7 | (6.6) player control | the unit is commanded by the player (no AI) |

Run-time changes of the code: a code-0/4 unit whose target unit is no longer on the map becomes code 1 with
target 0xff at the start of its turn (AIAct); a code-0/4 unit with no target unit standing on its target point
becomes code 3 (Arrival 0x43fcdf); when a unit leaves the map, units targeting it are reset (RemoveUnit, §1.10).

**AI-policy label** (option "i-显示AI方针", byte 0x501a72 ≠ 0; 0x42641e(U) formats into the text buffer 0x492f38,
strings 0x48e5f2..) [C]:

| U.target | U.code | label |
|---|---|---|
| 0xff | 0 | `前往(%2d:%2d)` with U.point |
| 0xff | 4 | `逃往(%2d:%2d)` with U.point |
| 0xff | 1 / 2 / 3 | `出击` / `坚守` / `防御` (string 0x48e5f7 + (code − 1)·5) |
| 0xff | ≥ 7 | `可控` |
| unit | 0 | `锁定` + target's name (0x425fb5) |
| unit | 4 | `跟随` + target's name |

(The table index is `(code >> 2)·7`, so code 7 with a target would read 跟随; codes 5, 6 never occur.)

### 3.3 Activity area (6.6) [C]
`AiAreaOK(U, cell)` (0x4077f6 → 0x414f05): true when U.code == 7, or U.code is even, or word U+0x20 == 0xffff, or
U's **current** cell lies outside the rectangle `[min..max]` spanned by (U+0x09, U+0x0a) and (U+0x20, U+0x21)
(inclusive, the corner order as stored: x1 = +0x09, x2 = +0x20, y1 = +0x0a, y2 = +0x21, test `x1 ≤ x ≤ x2`);
otherwise true iff `cell` is inside that rectangle (unsigned byte compares). So an active (1) or passive (3) unit
that stands inside its area never steps out of it; a unit outside its area moves freely. With the default
corner 2 = (0, 0) the box is empty unless corner 1 is (0, 0) too, i.e. "no area" in practice (a unit standing on
(0, 0) with target point (0, 0) is confined to that cell — faithful quirk). Corner 1 is the shared target point, so
a mode-4/6 SetAI moves the box. The flood (§4.3) applies it to every newly taken cell
when `mp ≠ 0xff`, `mode ≠ 0` and `zoc ≠ 3`; StepToward applies it when `mv ≠ 0xff`.

## 4. The AI turn of one unit

Notation: `layerA` = AI layer +0 (0x40154a: buffer object 0x48b0e0 offset 0), `layerB` = AI layer +0x640,
`layerC` = AI layer +0xc80 (counter-attack marks); `grid` = map buffer 0x48b140 +0x12c0 (flood cost grid);
`path` = map buffer +0x1900; cell index = x + y·W (W, H = bytes 0x4b422c / 0x4b422d). `Eff(a, b)` = the effect
query 0x4101d9(a, b, …) (a = 特效 id, names 0x4cc600 + 16a; b = item-effect id, names 0x4cb7a0 + 16(b − 0x1a);
semantics in skills.md). All arithmetic is unsigned 32-bit unless marked; "byte" = 8-bit wrap. `rand(n)` =
0x47fb13(n) = (n < 2) ? 0 : R mod n with R = 0x47fae7 (docs/battle.md, RNG).

Decision globals ("choice"): 0x4b2c20 dest cell (0xff = none), 0x4b2c24 bit 0 retreat, 0x4b2c28 target unit,
0x4b2c2c best-strategy target, 0x4b2c30 best physical target, 0x4b2c38 forbidden cell, 0x4b2c40 best strategy,
0x4b2c44 chosen strategy (0xff = physical attack), 0x4b2c4c best score (byte), 0x4ac748 unit list (0xff-terminated,
write pointer 0x4b2c34), 0x4ac808 usable-strategy list, 0x48e8c2 "candidate attack cell" (word, 0xffff = none).

### 4.0 Unit lists by range shape (0x436511) [C]
Several decisions keep "the first" or "the last" candidate, so the order in which units are collected matters.
`Collect(U, c, codes, flags, append)` (0x436511): `codes` is a packed dword of up to four range codes (byte i,
0xff = none; code 0 only as byte 0; 0x0b = no range; codes > 0x25 ignored). If byte 0 is 0xff → return 0xff.
Unless `append`, the list 0x4ac748 is emptied. For each byte i = 0..3: code 0x0a = the whole map (0x4366f0: y
outer, x inner, then stop); otherwise the offset list `table_0x4d1400[code < 0x0b ? code : code − 2]` of (a, b)
byte pairs (0xffff-terminated; shapes in docs/battle.md), each pair expanded (0x436611) in this order:
`a, b ≠ 0: (x+a, y−b), (x−a, y−b), (x−a, y+b), (x+a, y+b)`; `a or b = 0, m = max(a, b): (x+m, y), (x−m, y), (x, y−m),
(x, y+m)`. Each cell (0x437aff): off-map skipped; unless `flags & 0x80` the cell is stamped (grid and layerA =
the collecting unit's slot — this is how Prepare marks attack cells); with `append` ≠ 0 the cell is only marked
layerC = 1 (no list); otherwise the unit standing there is appended if its HP > 0, it is not yet listed, and its
side matches (`flags & 0x7f` == 2: any; bit 0 set: same side as U; else: other side). Return: 0xff for `append`;
otherwise `choice.target` if it is in the list, else the last unit listed, else 0xff.

### 4.1 AIAct (0x43ad3b) [C]
```
AIAct(U):
  mv = (U.flags & 0x80) ? 100 : MovePoints(U)         # 0x43f74f: class/equipment move (docs/battle.md); 麻痹 → 0;
                                                      #   move buff (+0x1d) ≥ 4 → min(mv+2, 255), < 3 → max(mv−2, 0)
  choice.forbidden = 0xff ; dword 0x4b2c1c = 0 ; SetCurrentUnit(U) (0x406240: U+0x24 &= 0x7f, 0x4b5df0 = person,
  0x500ac0 = U) ; byte 0x501bf9 = 0xff (last action kind)
  if U.target ≠ 0xff and U[U.target].state ≠ 2: U.target = 0xff; U.code = 1
  if U.state ≠ 2 or (U.flags & 2) or U.status(混乱): return      # 0x423fe8(U, 8): bits 4-5 of +0x1e
  Prepare(U)                                                     # 4.2
  if choice.retreat and !(U.flags & 0x80) and U.slot ≠ 60:      # 4.9
      Retreat(U, mv)
  else switch U.code:                                            # jump table 0x43b360
      0, 4: GoTarget(U, mv)                                      # 4.8
      1:    if Active(U, mv) == 0xff and U.pos == choice.dest: Hold(U)
      2:    Hold(U)
      3:    if Flood(U.pos, 0xff, mode 8, zoc 1) ≠ 0xff: PassiveAct(U, mv)   # note: unlimited move points here
            else Hold(U)
      ≥ 5:  nothing (choice stays empty)
  MoveAlongPath(U, walk speed = AL at entry, 4 from the phase loop) ; Arrival(U)          # 4.10
  if !(U.flags & 2) and !(U.flags & 0x80) and U.code ≠ 4 and !FamilySpecial(U):   # 4.12
      if choice.strategy == 0xff: PhysicalAttack(U)              # 4.11
      else:
          if EV4087 == 0: 0x441488(U, 2, choice.target, choice.strategy)   # camera / cursor onto the target
          CastStrategy 0x41c0e8(U, choice.strategy)               # dispatcher 0x497af8.0x425627(s, U.slot, −1);
                                                                 #   on success U.flags |= 6
          byte 0x501bf9 = 2 ; if choice.strategy == 0x39 (援队): dword ctx+0x504 (0x4b420c) = 1   # order recomputed, §1.4
  if !(U.flags & 0x80) and (U.flags & 4): U.flags |= 2
  byte 0x500c48 = 0
Hold(U) = Flood(U.pos, 0, mode 4, zoc 1); choice.dest = U.pos     # evaluate the own cell only
```
`0x441488(U, mode, t, s)` (mode 0 move, 1 attack, 2 strategy) is the AI-action preview: camera to U, then, unless
mode == 0 and option p 极速移动 (byte 0x501a79) is on, the range / target display (§5.6); it also places the
map cursor used by the strategy dispatcher [G].
EV 4087 (0x505fdc) ≠ 0 means the 练武场 duel window (duel.md): the AI then reads MgAIYN2 instead of MgAIYN1, every
move cost is 0xff and every terrain effect 100 % (0x43f7b8), PhysicalAttack takes the 练武场 branch, and the
opponent (slot 60) acts as a code-2 (hold) unit (duel.md §3.4). Other callers of AIAct: the 练武场 dialog
0x45321a (opponent = slot 60) and the scripted move 0x4594ea (sets flag 0x80 and code 0, target point = the
destination, calls AIAct, then restores code / flags / point / target).

### 4.2 Prepare (0x43a2ac) [C]
```
r = AtkRangeCode(U) (0x43f8c0)                  # packed range codes, docs/battle.md; if byte 0 == 0x0b
                                                # ("cannot attack", e.g. 禁咒) it becomes 0 = the 4 neighbours
layerA[*] = 0xff
for j in 0..249: if U[j].state == 2 and side(U[j]) ≠ side(U):          # 0x43a289
    MarkShape(U[j].pos, r, mark = j)        # 0x436511(U[j], …, flags 0, append 0): every cell of shape r around
                                            # U[j] gets layerA = j (and grid = j); later j overwrite earlier ones
for j in 0..249: if U[j].state == 2 and side(U[j]) ≠ side(U) and Eff(0x60 左天羅右地網, 0x7a)(U[j]):
    MarkShape(U[j].pos, code 0 (the 4 neighbours), mark = j)
layerB[*] = 0 ; choice.retreat = 0
if Wounded(U) and U.code ∉ {2, 4}:
    for y, x: if terrain(x, y) ∈ 18..22 (城池 关隘 鹿砦 村庄 兵营, 0x428a25): layerB[x, y] += 50 (byte)
    choice.retreat = 1
choice.best = 0 ; choice.target = choice.dest = choice.strategy = 0xff
```
`Wounded(U)` (0x439cfe): `U.HP == 0 → false`; person < 0x400: `U.HP ≤ MaxHP·2/5`; person ≥ 0x400: false for class
0x31 or family 0x32, else `U.HP ≤ MaxHP/5` (MaxHP = 0x407263, integer division).

### 4.3 Flood (0x438484(U, start, mp, mode, tx, ty, zoc)) [C]
Level-ordered flood over the cost grid; every newly taken cell is offered to the mode callbacks in discovery order,
and that order decides ties in the scoring.
```
side = side(U) ; scripted = U.flags & 0x80 ; zocOn = zoc & 1
if start == (tx, ty): return 0xff
grid = MapBuf+0x12c0 (probe mode, byte 0x500ace ≠ 0: MapBuf+0 instead); normal mode also sets path[0] = 0xff
grid[*] = 0xff ; grid[start] = 0
if mode & 4:
    choice.best = 0; choice.target = choice.dest = choice.strategy = 0xff
    BuildStratList(U)            # 0x442a26(U, 2, 0x4ac808): ids 0..143 ascending of every strategy U knows
                                 # (0x465ac1: class learn level, 学会策略 groups Mg8 0x4d17b0, …) with U.MP ≥ cost
    if !scripted and CellScore(start) == 1: return 1      # only possible in probe mode
if MoveCost(U, terrain(start)) == 0xff: return 0xff         # 0x43f7b8, docs/battle.md
cur = 0 ; changed = 1
while changed and cur < mp:
    changed = 0 ; next = 0xff ; above = 0xff
    for y in 0..H−1: for x in 0..W−1:
        c = grid[x, y]
        if cur < c ≠ 0xff and c < above: above = c
        if c ≠ cur: continue
        if (x, y) ≠ start and zocOn and InEnemyZOC(U, (x, y), sideFn = var4019): continue   # does not expand
        for d in 0..3 (up, right, down, left: 0x435a3e = (0,−1) (1,0) (0,1) (−1,0)):
            n = neighbour; skip if off the map or outside the rectangle at 0x501bf0 (x, y, w, h; 0 = none)
            skip if grid[n] ≠ 0xff
            mc = MoveCost(U, terrain(n)); skip if mc == 0xff or c + mc > mp
            skip if mp ≠ 0xff and mode ≠ 0 and zoc ≠ 3 and !AiAreaOK(U, n)
            o = unit at n (MapBuf+0xc80)
            if o ≠ 0xff and zoc ≠ 2 and !PassEffect(U) and Hostile(U, U[o], sideFn = var4019):
                skip if zocOn or !scripted          # hostile units block (scripted moves pass with zoc 0)
            grid[n] = c + mc ; changed = 1
            if c + mc < next:
                if zocOn and !scripted: if !InEnemyZOC(U, n, var4019): next = min(c + mc, above)
                else: next = c + mc
            if (mode & 8) and no unit stands on n and layerA[n] ≠ 0xff and U[layerA[n]].state == 2:
                return layerA[n]
            if (mode & 2) and n == (tx, ty): return 1
            if (mode & 4) and CellScore(n) == 1: return 1        # only possible in probe mode
        # end of each row:
        if !changed: (if above ≠ 0xff: next = above; changed = 1) else: next = min(next, above)
    cur = next
return 0xff
```
* zoc: 0 = no ZOC, hostile units still block; 1 = ZOC (cells in an enemy ZOC are entered but do not expand);
  2 = no ZOC and no unit blocks at all; 3 = like 1 but ignores the activity area.
* A cell keeps the first cost it is given (not a true shortest path when terrain costs differ, as in CCZ).
* `PassEffect(U)` (0x403a6f) = byte 0x500ad3 == 1 or Eff(0x36 穿越移动, 0x5d).
* `Hostile(U, V, f)` (0x42e2b7) = f(U) ≠ f(V); f = side() (0x406710) when var 4019 (EV 0x505ecc, 深入敌后 超级卡位)
  is 0, else the alternative 0x42e2ed (§2.1).
* `InEnemyZOC(U, cell, useSide)` (0x437d59): `TrapZOC(cell)` (0x428b7a, mines / special cells, docs/battle.md)
  → its value; else false if PassEffect(U) or Eff(0x37 突击移动, 0x29)(U); else true iff a 4-neighbour holds a unit V
  with Hostile(U, V, useSide ? side : var4019 function). The flood's own calls pass useSide = 0, StepToward's 1.
* Probe mode (byte 0x500ace ≠ 0, only 0x421cd6, the player-phase threat check of the UI) makes CellScore return
  early (4.4) and uses the separate grid; the normal AI never sets it.

### 4.4 CellScore (0x405da7 → 0x43a55e(U, c)) [C]
`layerB[c]` accumulates over all mode-4 floods of the same turn (it is only cleared by Prepare).
```
if a unit stands on c and c ≠ U.pos: return
atk = st = 0
if !(U.flags & 0x80):
    if U.code ≠ 4:
        if probe or layerA[c] ≠ 0xff or c == U.pos: atk = BestPhysical(U, c)      # 4.5
        if !U.status(禁咒 bits 2-3): st = BestStrategy(U, c, 0)                     # 4.6
        layerB[c] = min(255, layerB[c] + max(atk, st))
    t = TerrainScore(U, c) ; layerB[c] += min(t, 255 − layerB[c])
    if c == U.pos and atk == 0: layerB[c] += min(1, 255 − layerB[c])
if c == choice.forbidden: layerB[c] = 0
if choice.best > layerB[c]: return
if choice.best == layerB[c] and U.code ∉ {0, 4}: return        # codes 0 and 4: the LATER cell wins ties
if st > atk: choice.strategy = bestStrat (0x4b2c40)
             choice.target = (bestStrat == 0x48) ? bestPhys : bestStratTarget
else:        choice.strategy = 0xff ; choice.target = bestPhys
choice.best = layerB[c] ; choice.dest = c
```
TerrainScore (0x452e18): `s = 0`; if terrain(c) ∈ 18..22: `s += (U.HP < MaxHP·20/100 and byte 0x500af0 ≠ 2) ? 8 : 1`;
`e` = terrain-effect percent of U's family at TerrainPos(U, 0) (MoveCost(U, 0x1e) returns it in dl); if `e > 100`:
`s += (e − 100) >> 3`. TerrainPos(U, k) (0x407bf6) = U.pos for code-7 units, k == 2 or 0x48e8c2 == 0xffff; else
0x48e8c2 if k == 1 or EV 4065 (开启AI地形利用) ≠ 0; else U.pos. Since 0x48e8c2 is 0xffff outside BestPhysical, the
e-part always uses the unit's **current** cell (same for every candidate, as in CCZ).

### 4.5 BestPhysical (0x438914(U, c)) and PhysScore (0x4389bd(U, t, c)) [C]
```
BestPhysical(U, c):
  0x48e8c2 = c ; best = 0 ; bestPhys = 0xff
  list = units in AtkRangeCode(U) around c, opposite side, HP > 0 (0x436511(U, c, r, 0x80, 0))
  if list empty: 0x48e8c2 = 0xffff; return 0
  if probe: return (current unit in list) ? 1 : 0
  StepToward(U, goal U.pos, from c, 0xff, 0)       # the approach path (for direction-dependent damage, EV 4066)
  for t in list (order of collection): v = PhysScore(U, t, c); if v ≥ best: best = v; bestPhys = t   # ties: LAST
  0x48e8c2 = 0xffff ; return best
```
While 0x48e8c2 = c, the damage preview uses c as the attacker's cell for the terrain effect when EV 4065 ≠ 0 (AI
terrain use) and for the attack-direction bonus (EV 4066, 0x408db1), and AtkRangeCode checks 左天羅右地網
neighbours of c.
```
PhysScore(U, t, c):                                # T = U[t]
  s = (U.target == t) ? 98 : 0                     # 攻击武将 target
  if Eff(0x53 众矢之的, 0x6f) bit 0 (T): s = 101   # (the byte is overwritten: 101, not 98+101)
  if side(T) ≠ side(U):
      d = CalcDamage preview (0x43bc5a(U, T, 1, 0)) # docs/battle.md
      if U is a ranged family (k3 table 0x4d2138) and Eff(0x2f 防御远距攻击, 0x4e)(T): return 1
      if SP[U.person] < EV4061 and !Eff(0x70, 0x34)(U) and (Eff(0x33 致命一击, 0x31) bit 0)(U)
         and Eff(0x30 防御致命攻击, 0x41)(T): return 1
      s += max(1, d·100 / T.HP)                     # current HP; ≥ 100 means a kill
  if T.status(麻痹 bits 0-1): s += 8
  if s > 0: s += (T.person == boss (Reader 0x492f90 + 0x3d06) or t == 60) ? 8 : 4
  if s < 75 and CasterType(U) == 1 (文官): return 0
  a = PhysAreaCode(U) (0x407835); if a ∉ {0, 0xff}:
      hits = units hit around T (0x435941(U, t, 1, a, …), T itself not listed)
      s = AreaAdjust(hits, s, kind 0, U, strategy 0xff)
  if s > 0 and byte 0x500e9a ≠ 2:                  # 0x500e9a == 2: the unit attacks with a 必杀 this turn
      layerC[*] = 0 ; mark T's attack shape (AtkRangeCode(T) around T.pos) with 1 in layerC
      if layerC[c] == 1 and s > 1: s −= 1          # counter-attack possible
  return s
```
CasterType (0x4190e8): family k5 table 0x4d2188 (2 武将, 1 文官, 0 全能) mapped to 0 武将, 1 文官, 2 全能.

AreaAdjust (0x438bf3(hits, v, kind, U, s)) [C]:
```
if hits empty: return (v > 4) ? v − 2 : 2
b = 0
for u in hits:
  kind 0: if s == 0xff: d = CalcDamage(U, u, 1, 0)
          else: if !Usable(U, u, s): continue
                if u == U.target: b += 3
                d = StrategyDamage preview (0x43c01d(U, u, person, s, 0))
          b += (d ≥ u.HP) ? 10 : 3
  kind 1: if Usable and u.HP·100/MaxHP(u) < 60: b += 5
  kind 2: if Usable and u.buff[atk] (+0x18) < 4: b += 3
  kind 3, 4: if Usable and u.buff[def] (+0x19) < 4: b += 3
  kind 5: if Usable and u.status ≠ 0: b += 3
return max(v + b, 0)
```

### 4.6 BestStrategy (0x439169(U, c, given)) and StratScore (0x4395dc) [C]
`Usable(U, t, s)` (0x4390ef) = CanCast(s, U) (0x46fcf8: MP, seal, …) and TargetOK(s, U, t) (0x42044d: terrain,
weather, target state…; docs/battle.md) and the side test on strategy byte +0x0b: 0 → t on the other side,
1 → same side, else any.
```
BestStrategy(U, c, given):                         # given = 0 from CellScore
  if given == 0: bestStratTarget = bestStrat = 0xff
  best = 0
  for s in the usable-strategy list (ascending ids):
      r = (s == 0x21) ? AtkRangeCode(U) : StratRange(U, s)     # 0x401dff: strategy +0x0c, 远距攻击-策略 extension
      side = StratSide(s) (0x423cb3: +0x0b, 2 → 1); if side == 2: continue
      if byte r == 0xff:                           # no cast range: area around c
          sum = 0
          for u in SelfAreaHits(U, c, s) (0x4358df): sum += StratScore(U, u, s, c, terrain(c), given)
                                                    if sum > 0: sum += TargetBonus(U, u)
          if sum > best: best = sum; if given == 0: bestStratTarget = 0xff; bestStrat = s
      else:
          list = given ≠ 0 ? [given…] : units in r around c (0x436511(U, c, r, side|0x80, 0))
          if probe: return (current unit in list) ? 1 : 0
          for t in list: v = StratScore(U, t, s, c, terrain(c), given); if v > 0: v += TargetBonus(U, t)
                         if v > best: best = v; if given == 0: bestStratTarget = t; bestStrat = s
  return best                                       # ties: the FIRST strategy / target wins
TargetBonus(U, t) (0x40c854): side(t) ≠ side(U) and Eff(0x53 众矢之的, 0x6f) bit 1 (t) → 101;
                              else t == U.target → 98; else 0
```
StratScore(U, t, s, c, terrain, given) — `T = U[t]`, `hp% = T.HP·100/MaxHP(T)` (0x4078d1), `area` = area code of s
for U (0x41a10c: strategy +0x0d, widened by 辅助穿透 when MgMF bit 1), `hits` = area units around t (0x435941):
```
if StratRange(U, s) ≠ 0xff:
    if area ≠ 0: hits = AreaHits(U, t, kind (+0x0b)+1, area)
    if !Usable(U, t, s): return 0
if s ≥ 144: return 0
cat = (EV4087 ≠ 0 ? MgAIYN2 0x4d1690 : MgAIYN1 0x4d1600)[s] ; v = 0 ; areaKind = none
switch cat (jump table 0x43a140):
 0, 1, 5 (damage):  if !Usable: return 0
       d = StrategyDamage(U, T, s, given) (signed); if d < 0: v = 0, areaKind = 0
       else p = max(1, d·100 / T.HP)
            if p == 100: v = 100
            else: v = p
                  if s == 43 (衰气): v += 0x417a61(T)
                  elif s == 30 (吸血): v += 5 if U.HP < MaxHP(U); v += 10 if Wounded(U)
                  elif s ∈ 48..49 (定身 定军): v += 27 unless 0x45afca(U.person, T.person, 1) (adjacent & able
                                                to attack each other)
                  elif s ∈ 31..47: v += 8 if hp% ≥ 40
            areaKind = 0
 4 (confuse):  if Usable and HitRate(U, T, s) (0x43b730) ≥ 35: v = 26 + (hp% ≥ 80 ? 26 : 0); areaKind = 0
               else return 0
 11 (cure):    m = 0; n = 0
               for i in 0..3: if T.status & (3 << 2i): m = max(m, [25, 30, 35, 25][i]) (byte); n += 1
               v = m + n + 5 ; areaKind = 5
 7, 8, 9 (heal): if !Wounded(T): return 0
               v = 50; s == 55 (小補給): return 50; s == 56: return 55; s == 59 (输送): return 60
               areaKind = 1                                     # 援队 57, 援军 58, others
 3 (MP drain): if Usable and U.MP ≤ MaxMP(U)/5 and T.MP ≥ 30: return 20 ; return 0
 6 (seal):     if family(T) has k5 == 2 (武将) or HitRate ≥ 60: return 25 + (hp% ≥ 80 ? 7 : 0) ; return 0
 10 (MP give): if T.MP ≤ MaxMP(T)/5 and U.MP ≥ cost(s) + 6:
                   family(T) == 9 (医师) → 1; CasterType(T) ≠ 0 or 0x4079da(T.person, 0x48) → 12;
                   family(T) == 0 (君主) → 6; else 0
               return that (no area)
 12 (回归):    return 0 if T.code ∈ {2, 3} or (s == 89 and 0x41832b(T.person, s))
               f = family(T): 9 → 0; 0 → 15; 19 → 15; 8 → 10; else 10 + rand(f == 5 ? 5 : 4)
 2 (连击 s 33): if hp%(U) > 40 and CasterType(U) == 0: v = 100 + (given == 0 ? BestPhysical(U, c) : 0)
               return v (no area)
 14 (debuff, s 35–38): k = (s − 35) >> 1 ; ct = CasterType(T)
               k == 0: ct 0: atk buff > 3 → 10; ct 1: spirit buff (+0x1a) > 3 → 10; ct 2: atk > 3 or spi > 3 → 11
               k == 1: def buff (+0x19) ≥ 3 → 12
               none of these: return 0 ; areaKind = 0
 15 (buff, s 65–68): k = (s − 65) >> 1 ; ct = CasterType(T)
               k == 0: ct 0: atk < 3 → 10; ct 1: spi < 3 → 10; ct 2: atk < 3 or spi < 3 → 11
               k == 1: def < 3 → 11
               none: return 0 ; areaKind = 0
 13: return 0                                                  # "AI does not use"
if area ≠ 0 and areaKind ≠ none: v = AreaAdjust(hits, v, areaKind, U, s)
return v
```
MgAIYN1 values in this mod's data (strategies.json `ai_use_battle`): 5 for the damage, poison and paralysis
strategies, 2 连击, 3 谍报, 4 谎报/谎言, 6 禁咒/封咒, 7 the five 補給 strategies, 10 建言/献策, 11 觉醒/大觉醒,
12 回归 and 空白0082, 14 压迫/大喝/咒骂/威吓, 13 for everything else. The AI value editor of 6.4
(`其他檔案/AI价值编辑器/ai价值统计(6.4).xlsx`) lists these constants at the same addresses; its numbers are 6.4
values, the ones above are read from the 6.6 code.

### 4.7 Movement helpers [C]
GoalBonus (0x43817b(cell, v, slot)), recursive:
```
if v < 9: return
if terrain effect of U[slot] at its current cell (MoveCost(U, 0x1e) dl) ≠ 0xff and layerB[cell] == 0
   and (no unit on cell or cell == U[slot].pos): layerB[cell] += v
if U[slot].class ∉ {15, 16}:
    for d in 0..3: if neighbour n exists: GoalBonus(n, v > 10 ? v − 10 : v − 1, slot)
```
(v = 10: goal 10, neighbours 9; v = 20: goal 20, ring 1 10, ring 2 9 — only on cells whose layerB is still 0.)

StepToward (0x437e23(U, goal, from, mv, bonus)) walks greedily on the grid of the last flood (distance from that
flood's start):
```
retry = 4
restart:
  cur = from ; n = 0 ; ok = 1 ; rem = mv
  while cur ≠ goal and ok:
      best = 0xff ; bd = grid[cur]
      for d in (retry == 4 ? 0 : retry) .. 3:
          nb = neighbour(cur, d); skip if off the map
          skip if InEnemyZOC(U, nb, useSide 1) and nb ≠ goal and !(U.flags & 0x80)
          skip if mv ≠ 0xff and !AiAreaOK(U, nb)
          g = grid[nb]; skip unless g < bd (signed)
          mc = MoveCost(U, terrain(nb)); skip if rem < mc
          bd = g ; best = d ; cost = mc
      if best ≠ 0xff: cur = neighbour(cur, best); rem −= cost; path[n] = best; n += 1
      else: ok = 0; n += 1
  if !ok and bonus == 1:
      if no unit on cur and !CanDescend(cur, U, rem): GoalBonus(cur, 10, U.slot)
      elif U.code ∈ {0, 4} and retry ≠ 0: grid[cur] = 0xff; retry −= 1; goto restart
      else: GoalBonus(cur, 20, U.slot)
  byte 0x500c48 = n ; reverse path[0..n−1] and turn each direction by 2 (mod 4); n == 0 → path[0] = 0xff
```
`CanDescend(cur, U, rem)` (0x43ff64): rem ≠ 0 and some neighbour has a grid value below grid[cur] and a move cost
≤ rem. The retries restrict the directions tried at every step to `retry..3` (3, then 2–3, then 1–3, then 0–3).
When stuck, n counts one step more than was walked; this only matters for the bonus calls (the movement path itself
always reaches its goal, 4.10).

### 4.8 GoTarget (codes 0 and 4; AIAct case at 0x43af8b) [C]
```
if U.target ≠ 0xff: goal = U[U.target].pos
                    if U[U.target].code ∈ {0, 4}: choice.forbidden = that unit's target point
else: goal = U.point
if !(U.flags & 0x80):
    r = Flood(U.pos, mv, mode 8, zoc 1)
    if U.target ≠ 0xff and r == U.target:
        GoalBonus(goal, 20, U.slot); Flood(U.pos, mv, mode 4, zoc 1)
    else:
        GoalBonus(goal, 10, U.slot)
        if Flood(goal, 0xff, mode 2, target U.pos, zoc 1) == 1 or Flood(goal, 0xff, mode 2, U.pos, zoc 0) ≠ 0xff:
            StepToward(U, goal, U.pos, mv, 1); Flood(U.pos, mv, mode 4, zoc 1)
        else: Active(U, mv)
else:                                              # scripted move (flag 0x80, mv = 100)
    if Flood(U.pos, 0xff, mode 2, target goal, zoc 1) == 1: choice.dest = goal
    elif Flood(U.pos, 0xff, mode 2, goal, zoc 0) == 0: (never: mode 2 returns 1 or 0xff) dest = U.pos; U.point = U.pos
    else: choice.dest = goal                       # also when the goal is unreachable
```
Code 4 units get no attack or strategy candidates (CellScore skips them) and never attack (AIAct, PhysicalAttack).
Quirk [C]: the mode-8 flood returns `layerA` of the first empty attack cell it reaches, and layerA holds the
**highest** slot that can be attacked from that cell (Prepare overwrites in slot order). If another opposite unit
with a higher slot can also be attacked from that cell, `r ≠ U.target` and the unit takes the "approach" branch
even though its target is attackable this turn.

### 4.9 Active (0x43a7c9(U, mv)), PassiveAct (0x40debe(U, mv)) and Retreat [C]
```
Active(U, mv):
  if Flood(U.pos, mv, mode 8, zoc 1) ≠ 0xff:          # an attack cell is reachable this turn
      dword 0x4b2c1c = 1 ; Flood(U.pos, mv, mode 4, zoc 1)
      if choice.dest ≠ U.pos: return 0
      if byte 0x500c47 (phase-loop pass) ≠ 1 and U.code < 4: return U.code    # stays / acts from its cell
  j = Flood(U.pos, 0xff, mode 8, zoc 1)              # nearest attack cell anywhere (no move limit)
  if j == 0xff: choice.dest = U.pos; return 0xff
  goal = U[j].pos
  found = Flood(goal, 0xff, mode 2, U.pos, zoc 1) == 1                # tried in this order, stop at the first hit
       or Flood(goal, 0xff, mode 2, U.pos, zoc 2) ≠ 0xff                # zoc 2: no ZOC, units do not block
       or (U.kind == 1 and Flood(U[0].pos, 0xff, mode 2, U.pos, zoc 1) == 1)   # 0x40d917
  if found: StepToward(U, goal, U.pos, mv, 1); return Flood(U.pos, mv, mode 4, zoc 1)   # = 0xff (normal mode)
  return 0             # not found: choice.dest stays 0xff → no move; the attack step uses whatever is in range
```
AIAct's code-1 case re-evaluates the own cell (Hold) when Active returns 0xff and the chosen cell is the own cell
(after an approach whose best cell is "stay", or when no attackable unit exists anywhere).
StepToward descends the grid of the flood that succeeded: for the 0x40d917 case that is the distance to **unit 0's**
cell, so a friend (kind 1) with no reachable enemy walks toward the player's leader. The bonus walk ignores unit
blocking (only ZOC); the real move is taken from the final mode-4 flood.
```
PassiveAct(U, mv):
  if ctx(0x4b3d08)+0x10 == 2 (enemy phase) and word U+0x20 ≠ 0xffff:
      Flood(U.pos, mv, mode 4, zoc 3)                 # ignore the activity area first
      if choice.best ≥ 100: return
  Flood(U.pos, mv, mode 4, zoc 1)
Retreat(U, mv):                                       # choice.retreat set by Prepare
  goal = side(U) == 1 ? U[0].pos : (U[60].state == 2 ? U[60].pos : none)
  if none: Active(U, mv); return
  GoalBonus(goal, 10, U.slot)
  if Flood(goal, 0xff, mode 2, U.pos, zoc 1) == 1: StepToward(U, goal, U.pos, mv, 1); Flood(U.pos, mv, mode 4, zoc 1)
  elif Flood(goal, 0xff, mode 2, U.pos, zoc 0) == 0xff: Active(U, mv)
  else: StepToward(…); Flood(U.pos, mv, mode 4, zoc 1)
```
U[0]'s cell is used whatever U[0]'s state is (a unit that left the map keeps its last x, y; RemoveUnit only clears
the occupancy cell, 0x4193b0 → 0x42dc72) [C]; "none" happens only for the enemy side when slot 60 is not on the map.
A wounded unit therefore scores healing terrain +50 (+8 or +1 TerrainScore), a cell next to its leader +10/+9
(GoalBonus), and still fights or heals where that scores more. Codes 2 and 4 never retreat, slot 60 never retreats.

### 4.10 MoveAlongPath (0x43a959) and Arrival (0x43fcdf) [C]
```
MoveAlongPath(U):
  if U.state == 2 and choice.dest ∉ {0xff, U.pos}:
      p = StepToward(U, goal U.pos, from choice.dest, 0xff, 0)       # on the last mode-4 flood's grid, reversed
      if p[0] ≠ 0xff:
          U.flags & 0x80 ? camera to U (0x4b4250.0x45503f) : 0x441488(U, 0, 0xff, 0xff) (selection display)
          walk the path (0x43d9ed(U, p, &dest, …); traps, animations: docs/battle.md / gfx.md)
          if !(U.flags & 0x80): U.flags |= 4
          0x41bd67(U); 0x44a88a()
  byte 0x500c48 = result
Arrival(U): if U.target ≠ 0xff: (0x43feda: true if the target is 4-adjacent; no state change)
            elif U.pos == U.point and U.code ∈ {0, 4}: U.code = 3
```

### 4.11 PhysicalAttack (0x43aaf7) [C]
```
grid[*] = 0xff
if EV4087 ≠ 0:                                   # 练武场 dialog fight (duel.md §3.4)
    t = 0 (slot 0, the player's fighter): no range / weapon / flag tests; combat slots (U, 0); continue at
    "byte 0x501bf9 = 1" below
t = units in AtkRangeCode(U) around U.pos (0x436511(U, U.pos, r, 0, 0)) → returns choice.target if it is in the
    list, else the LAST unit collected, else 0xff        (also stamps layerA/grid with U.slot, harmless)
return if U.flags & 0x80, U.code == 4, the equipped weapon cannot attack (0x407961), t == 0xff, or U.flags & 2
face t (0x435829) ; 0x441488(U, 1, t, 0xff)
if CanSpecial(U) (0x4225fb) ≠ 0: 必杀 attack 0x465fab(U.slot, t)               # 4.12
else:
    n = SiegeHelpers(U.slot, t, collect 1) (0x405bf2, §5.3; always 0 with this mod's family data)
    if n: filter the partner queue (0x44eb2d on 0x500e9d); byte 0x500c48 = its value at entry
    if n and |U.x − T.x| ≤ 1 and |U.y − T.y| ≤ 1 and byte 0 of AtkRangeCode(U) ∉ {2, 3, 4}:
        围攻 0x417c67(t, U, n)
    else:
        r = PreAttack 0x410f1c(t, U)                     # 先手 … may cancel (0xff) or swap the roles (≠ 0)
        if r ≠ 0xff: combat slots 0x4927f0.0x4064f1 = (U, t), or (t, U) when r ≠ 0
        byte 0x501bf9 = 1
        if Combat 0x4363f1(U, t) == 0 and T.HP == 0:     # the attack itself (docs/battle.md)
            if 0x4212f1(U) ≠ 0: t = its CL               # 引导攻击 follow-up target
    0x4223a9(U, t): post-combat reactions 0x438ebd for U and for U[t] (same-side units' reaction effects, skills.md)
U.flags |= 2 | 4 ; refresh (0x4b4250.0x453ac3)
```

### 4.12 必杀 (special attacks) in the AI [C for the decisions; effects in skills.md]
* Before AIAct the phase loop calls `CanSpecial(U)` (0x4225fb): 0 if EV 4059 (禁止必杀) ≠ 0 or U is sealed (禁咒);
  family 必杀 (family k8 table 0x4d2200 ≠ 0): 2 if the person's SP (0x424808) ≥ cost byte +0x0e of record
  0x41e918(k8 + 0x4f), else 0; otherwise 1 if SP ≥ EV 4061 (code-7 units without a family special: always
  non-zero, a garbage value, §1.9).
  For 1 the loop calls `SelectSpecial` (0x4225a2): the first 必杀 i in 1..79 the person owns (0x418744) whose cost
  ≤ SP → word 0x500e9a = 2 | i << 8 (none: 2). While 0x500e9a holds 2 for the current unit, AtkRangeCode and
  PhysAreaCode use the 必杀 record's range / area, and PhysScore skips the counter-attack penalty. The phase loop
  clears 0x500e9a after the action.
* After moving: `FamilySpecial` (0x467c9e): if EV 4087 == 0, CanSpecial(U) ≠ 0 and k8(family) = k ≠ 0:
  i = (k − 1 < 9) ? k − 1 : rand(8); 0x497af8.0x4251e1(0x3b, U.slot) (cut-in animation 0x3b); byte 0x500c41 = i;
  handler table 0x467d1d[i](U) (9 handlers, the same 军师技 handlers as the player's 必杀 command; they end with
  U.flags |= 6); byte 0x501bf9 = 5; 0x423910: SP −= min(SP, cost of skill 0x4f + k); the unit does not attack.
  Families with k8: 君主 7, 策士 5, 医师 1, 道士 4, 統軍 5, 都督 9, 咒术士 3, 阴阳师 6, 辎重队 7, 仙人 8, 皇帝 2, 百姓 6.
* Otherwise the physical attack is the 必杀 attack whenever CanSpecial(U) ≠ 0: 0x465fab(slot, t) = cut-in 0x417a96,
  combat slots (0x4927f0.0x4064f1(slot, t)), 0x42c144(U, t) = Combat 0x4363f1 + the 引导攻击 follow-up (with the
  必杀 range / area of word 0x500e9a),
  SP −= min(SP, cost of skill byte 0x500e9b) (0x423910), word 0x500e9a = 0, byte 0x501bf9 = 5 — the same path as the
  player's 武将技 (§5.3). If SelectSpecial found no skill (0x500e9a = 2, id 0) the routine still runs with id 0.

### 4.13 Items
The AI never uses items: the item-use routine 0x420271 is called only from the player menu (0x40a985) and the
练武场 dialog. Automatic item effects (自动使用 …) belong to skills.md.

## 5. Player phase — input loop, unit commands and map displays

Scope: everything the 6.6 engine decides while the player commands units (formulas of attacks, strategies,
items and duels are in battle.md / skills.md / duel.md; this section gives *when* each command is offered and
what it calls). Tags: **[C]** read in the disassembly (Ghidra only as a cross-check), **[D]** data / mod notes,
**[G]** guess, **[?]** open. `U` = battle unit (0x30 B at 0x4a7b20 + slot·0x30, memory.md §4); `ctx` = battle
object 0x4b3d08; `cur` = current unit pointer 0x500ac0 (set by 0x406240, which also stores its person in
0x4b5df0 and clears the pending-大杀四方 bit U+0x24 bit 7, §5.5); `EVn` = script variable n (u32 at 0x502000 + 4n;
the config EVs are read as bytes).

Unit helpers used below (all [C]):

| helper | meaning |
|---|---|
| 0x4061f9 (cl = slot → ecx) | unit pointer |
| 0x418c90 | state U+0xc (2 = on map) |
| 0x425ad0 | AI code U+0xe (7 = player-controlled) |
| 0x425af0(U, m) | `(U+0xd & m) == m`; flags 0x02 = action finished, 0x04 = moved, 0x80 = scripted move |
| 0x442718(U, m) / 0x406690(U, m) | set / clear flag bits m (the player-side "acted" mark is m = 6) |
| 0x423fe8(U, m) | status counter test: m 2 → 麻痹 (bits 0-1), 4 → 禁咒 (bits 2-3), 8 → 混乱 (bits 4-5), 0x10 → 中毒 (bits 6-7); returns the counter (0 = not affected) |
| 0x406710(U) | side: table 0x40672d[colour] = {0:1, 1:1, 2:0, 3:0}; colour 3 uses index 4 (= 2, a third party) when EV4053 (援军和敌军是否对攻, byte 0x505f54) ≠ 0. **1 = player side** |
| 0x43ff54(U) | colour U+5 == 0 (the player's own army) |
| 0x43b4a7(U) | family of the unit's class (0x40bf0c) |
| 0x435884(&pos) | unit slot at a cell (0xff none) |
| 0x4101d9(e, k, a, b) | skill/特效 query; `e` indexes the effect-name table 0x4cc600 (16 B names: 45 策略模仿, 56 二次行动, 64 大杀四方, 73..80 学会策略-四系…四神, 90 再次移动); see skills.md |

Slot ranges (0x428ea8, 0x44cb12, 0x44e825): **0..19 player, 20..59 allies, 60..249 enemies**; "player side" in
the phase loops = slots 0..59 [C].

### 5.1 Player input loop 0x44e0d9(ctx, resumed) [C]

Called once per round from the player phase 0x44ed7f with ctx+0x520 = 1 (toolbar state 0x449de6(1)).
`ctx+1` is the battle result byte; inside this loop it is also the *map command* byte written by toolbar /
right-click (6 = end phase, 7 = next unit, 5 = load/quit) and reset to 0 after use.

```
done = 1
for slot in 0..59:                                   # anybody to command?
    if !(U.flags & 0x80) and U.code == 7 and U.state == 2: done = 0; break
camera to the first on-map unit of slots 0..19 (else 20..249)          (0x428ea8(.,1), 0x45503f)
ctx+5 = 0                                            # cursor animation frame (0x406747: +1 mod 8)
if resumed == 0: AutosaveStart()                     # 0x412ab7, option 'A' (§5.6)
while done == 0:
    hover = UnitAt(cursor cell); if none and map object at the cell (0x4362c4: word grid 0x510000 indexed
            ((W-1)·y + x)·2 — quirk W-1; obj[0] ≠ 0 and obj[1] ≠ 2) → hover = 0xfe
    hovering an on-map unit shows its status panel (0x464a32; unit window 0x479795 if open)
    LEFT CLICK (0x42c56b == 1, cell on the map 0x4290a9):
        hover < 0xfa (any unit, any side): acted = UnitCommand(U[hover])                 # §5.2
            0x45b609(hover): if ctx+1 == 0 and the unit is on the map: script event context {person, x, y}
                (0x40ffb2(R, 3, …, 12)) and a script poll 0x44c601 — done after EVERY click on a unit,
                also when the command was cancelled (the condition before it was nopped, 0x44e3df/0x44e3e4)
        hover ≥ 0xfe (empty cell or map object): terrain info popup at the cell (0x45576d: terrain name,
            effect %, recovery, strategy-type icons 0x419587)
    if ctx+1 == 7 (检索未执行部队): ctx+1 = 0; if NextUnit() (0x44e706) found none: ctx+1 = 6; ctx+0x500 = 1
    RIGHT CLICK (0x42c56b == 2): unit at the cell → its unit window (0x479795), else ctx+1 = 6
    if ctx+1 == 6: done = YesNo("结束所有部队的命令吗？") (0x42f699(1, 0x48e120)); ctx+1 = 0
    if ctx+1 == 5: return                                                    # load / quit to title
    if acted:                                                                # §5.5
        AfterPlayerAction(U[hover])
        if ctx+1 != 0: return
        0x44c601()                                                           # script poll
        if ctx+1 != 0: return
        n = #{slot 0..249 : !(flags & 2), not 混乱, state 2, code 7}
        if n == 0: done = YesNo("结束所有部队的命令吗？")                   # auto prompt; "no" keeps the phase
end: 0x412ae5(20) (end-of-phase autosave, §5.6); cursor hidden
```

* No commandable unit at phase start → the phase ends at once, without a prompt [C].
* The end prompt after an action counts code-7 units of **all 250 slots** (allies under player control and
  converted enemies included) but ignores confused ones; units under 麻痹 still count [C].
* NextUnit 0x44e706 ("检索未执行部队"): the list of slots 0..59 with no flag 2, no flag 4, state 2, code 7,
  **colour 0** (0x43ff54) and not 混乱; none → status-line message "没有可以行动的部队。" (0x48e1fa, 0x42f699
  type 0) and the end prompt; else index 0x4b4238 += 1 (wraps to 0; reset to 0 every round by 0x44eee5) and the
  cursor jumps to that unit (0x455298) — it does not select it [C].

### 5.2 Commanding a unit: UnitCommand 0x43dde0(U) and move selection 0x43d4fc [C]

```
UnitCommand(U):
    save facing U+0xf and cell U+6
    if !MoveSelect(U, rangecode 0 → the unit's attack range code 0x43f8c0, mp 0 → MovePoints, mode 0): return 0
    cur = U; build the command menu (§5.3) next to the unit (right of it if its screen x < half the
        screen, else left; vertically centred, clamped) — 0x45bbd2 / 0x45b990
    sel = 0
    while !(U.flags & 2) and sel != 0xff:
        sel = CommandMenu()          # 0x413b7c: dialog 0x117, returns 1..7 or 0xff; 0x501bf9 = sel
        dispatch sel (§5.3)           # a handler that is cancelled leaves flags alone → the menu reopens,
                                     # with the SAME enabled entries (not recomputed)
    if sel == 0xff:                  # 取消 / right click in the menu: undo the move
        U.flags &= ~4; Teleport(U, saved cell) (0x40f171); U.facing = saved; refresh sprite mirror (0x43fd34)
    return (sel != 0xff and U.flags & 2)
```

**MoveSelect 0x43d4fc(U, rangecode, mp, mode)** — also used for 再次移动 (§5.5):

```
if mode != 1: 0x501bf9 = 0xff
cur = U
if 0x508b00[slot] != 0xff: 0x508b00[slot] = (U has 二次行动 ? 0 : 1)        # query 0x421175 = (56, 0x5a, 1, 1)
rangecode = rangecode or 0x43f8c0(U)
why = -1                                     # -1 = may move
if side(U) != 1:                     why = 0   # "这是敌军部队。"
elif U.flags & 0x80 or U.code != 7:  why = 1   # "这是友军部队。"
elif 混乱:                           why = 5   # "正处于混乱状态。"
elif U.flags & 2:                    why = 6   # already acted: facing change only
(debug byte 0x4b4230 bit 2 lifts the side/code tests; 0x4b4230 is zeroed at battle setup 0x4017f6 and
 never set by the game itself → always 0)
mp = mp or MovePoints(U) (0x43f74f; also when mp == -1)
Flood(U, U.pos, mp, mode 0, zoc 1) → reach grid MapBuf+0x12c0 (0xff = unreachable)        (§4.3)
move-range display style: colour 0 or code 7 → cursor+0x64 = 1, else cursor+0x68 = 1
0x4b5ddb = slot; attack-shape overlay of `rangecode` around the unit's CURRENT cell: 0x411bfb(pos, code)
    stores code at 0x4b5dd5 (= cursor+0x1b85, 0xff = none) and marks the shape cells (0x47c608 → 0x45288b)
while why == -1:
    c = click (0x40e02c; right click → 0xff)
    if c == 0xff:                                    why = 2 (cancel)
    elif cell free (0x43fc7f: no on-map unit at c — occupancy layer MapBuf+0xc80 — and terrain passable
         for U, 0x43f7b8 ≠ 0xff) and reach[c] ≠ 0xff: why = 4 (move)
    elif UnitAt(c) == U:                              why = 3 (stay)
    elif UnitAt(c) ≠ 0xff and reach[c] ≠ 0xff:        Message("因为有其他部队，所以不能移动。") (0x48dfa8)
    else:                                             Face(U, c)  — and stay in the loop
messages for why 0/1/5: wait for one more click; a click on the map shows the text (modal), right click
    closes silently (0x40dbbc). why 6: wait for one click, then Face(U, that cell) — also after a right
    click, whose cell is (0xff,0xff) → the unit turns to facing 1 (quirk) [C]
clear displays: cursor+0x64 = 0; cursor+0x68 = 0 and the AI-value cache 0x5003a0 is zeroed (0x422386);
    0x411bfb(pos, 0xff)
why 3: return 1 (menu without moving)
why 4: path = 0x437e23(U, from U.pos to c) on the reach grid; walk it (0x43d9ed); unless interrupted:
       0x41bd67(U), U.flags |= 4; 0x4b5dd5 = 0xff; return 1
       (mp == -1 → 0x4028cc instant placement; rangecode byte 0xff → 0x41f3fb [not traced])
else return 0
```

**Face(U, cell)** 0x412148: `same x: cell.y > U.y → 2 else 0; otherwise cell.x > U.x → 1 else 3` (0 up, 1 right,
2 down, 3 left; diagonal cells use the horizontal direction), applied with 0x4575b8(person, 0xffff, dir):
nothing if already facing that way, else SE 6 (not when 0x500ad7 == 2) and the new facing; a unit that has
finished keeps its grey look. Facing matters for EV4066 (攻击方向伤害加成, battle.md) [C].

### 5.3 The command menu — dialog resource 0x117, buttons 0x507..0x50d → selection id − 0x506 [C]

Top to bottom as laid out in the resource (all 55×14 owner-drawn buttons, images 0x492e1c index id − 0x507):

| row | button | sel | enabled when (computed once per menu, before the loop) | handler |
|---|---|---|---|---|
| 1 | 攻击 0x507 | 1 | `menu+0x34` = **AttackTargets**: 0x43e33c(slot, rangecode 0x43f8c0(U), 0): some opposite-side unit is attackable from the unit's (new) cell (0x436511 fills the list 0x4ac748) | 0x43dada |
| 2 | 策略 0x508 | 2 | `menu+0x38` = **KnowsStrategy** 0x43e023 (below) | 0x42c177(U, 0) |
| 3 | 道具 0x509 | 3 | `menu+0x3c` = **BagHasBattleItem** 0x408e96 (below) | 0x40a985 |
| 4 | 交换 0x50d | 7 | **CanExchange** 0x41bc16 (below) | 0x4151fe |
| 5 | 围攻 0x50c | 6 | **CanSiege** 0x419d74 (below) | 0x41d693 |
| 6 | 必杀 0x50b | 5 | **BishaAvail** 0x4225fb(cur) ≠ 0 (below) | 0x467c9e, else 0x423358 |
| 7 | 待命 0x50a | 4 | always | U.flags \|= 6 (0x442718) |
| 8 | 取消 (id 2) | 0xff | always; a right click on the menu sends it too (0x46e81f) | undo move (§5.2) |

There is no 单挑 entry: a duel is started with the consumable whose effect index is 0x17 "单挑" (item effect
id 0x31, dispatcher 0x44f2ac → table 0x44f380 → handler 0x425e4c; EV4083 picks auto / 舌战 / 单挑) — see
duel.md [C].

**KnowsStrategy 0x43e023(U)** [C]:
```
if U has 策略模仿 (0x4210be = query(45, 0x3b, 1, 1)):
    for k in 0..3: n = UnitAt(4-neighbour k of U); if n ≠ 0xff and KnowsAny(U[n], imitable=1): return 1
return KnowsAny(U, imitable=0)
KnowsAny(V, imit) 0x41dc78:  P = person(V)
    for k in 0..7: b = query(73 + k, 0x6c, 3, 0) on V           # 学会策略-四系 … 四神, a bit mask
        for s in 0..143:
            known = (b ≠ 0 and b & Mg8[s] (0x4d17b0)) or (k == 0 and (ClassLearnLevel(P, s) (0x435a4e) ≠ 0
                    and level(P) ≥ it  — 0x41832b) or PersonLearn(s, P) (0x40de69, table 0x507800)))
            if known and (imit == 0 or MgMF[s] (0x4d14e0) & 1): return 1
    return 0
```
MP, 禁咒 and terrain are **not** checked here: choosing 策略 while sealed shows "正处于禁咒状态。" (0x48e01c,
0x42c177) and returns to the menu; otherwise the strategy list (dialog 0x11a, filter boxes 四系 Deff 妨碍 补给 Buff
气候 绝 四神) is shown until a strategy is cast (0x41c0e8 → 0x425627; success → flags 6) or the list is
cancelled. Which list rows are greyed (MP / terrain / weather) is in skills.md [? not traced here].

**BagHasBattleItem 0x408e96** [C]: the army bag is the u8 count array 0x493af0[0..351] for item ids 0xa0 + i;
enabled iff some i has count ≠ 0 and its effect index `k = 0x40b4bd(item) = effect id − 0x1a` passes 0x46708c:
`k ∉ 0x20..0x23` (任务物品 合成材料 工具物品 装备升级) and, when EV4087 ≠ 0 (练武场 battle, byte 0x505fdc), also
`k ≠ 0x17` (单挑) and `k ∉ 0x24..0x28` (地雷 items). It does not look at the unit. 道具 then loops item list
(dialog 0xf2) → use (0x420271 → 0x44f2ac; success → flags 6) until the list is cancelled.

**CanExchange 0x41bc16** [C] (EV4052 = 可以和友军交换装备, u32 at 0x505f50, values 0 or 4):
```
if EV4052 == 0 and cur.colour ≠ 0: return 0
if 0x501a84[cur.slot] ≠ 0: return 0                  # per-unit "exchange forbidden" byte (AddStat attr 15)
n = CountUnits(side code = EV4052, rectangle (x−1, y−1)..(x+1, y+1) around cur, clamped at 0)   # 0x428df1
return n ≥ 2                                         # itself + one more, diagonals included
```
CountUnits side codes (0x44cb12): 0..3 colour == code (a colour-2 unit in slots < 20 counts as 0, in 20..59 as
1), 4 = colour < 2, 5 = colour 2 or 3, 6 = all. Handler 0x4151fe: choose 交换武器 / 交换护具 / 交换辅助装备
(0x42de7d); own slot empty → "没有此项装备"; partner chosen with the target picker (0x45533d, range code 1,
own side; with EV4052 ≠ 4 the partner must be colour 0, else "这是友军部队。"); partner's 0x501a84 ≠ 0 →
"目前禁止交换" (and stop); each must be able to wear the other's item (0x407961; an empty slot is fine) else
"装备不匹配" and pick again; then the two items (with level and exp) are swapped, "装备交换完成", flags 6.

**CanSiege 0x419d74** [C] — 围攻:
```
targets = AttackTargets(cur)                         # list 0x4ac748
return any t in targets with SiegeHelpers(cur, t, collect=0) ≥ 1
SiegeHelpers(a, t, collect) 0x405bf2: list 0x500e9d = 0xff…; n = 0
    for k in 0..7 (8 neighbours of t, table 0x435a3e: 4 orthogonal then 4 diagonal):
        h = Helper(cell, a, diag = k >> 2) (0x416e53); if h ≠ 0xff: list[n++] = h; if !collect: return 1
    return n
Helper: h = UnitAt(cell); reject if none, h == a, not on a's side (0x404fcb), 0x4d21d8[family(h)] ≠ 0,
        (h.code ≠ 7 and SP[person(h)] ≥ EV4061), h.flags & 2, h 混乱, or the attack shape of h (0x40ae26 over
        its range codes, table 0x43784a: 0 orthogonal, 1 diagonal, 2 both, 0xff none) does not cover that
        neighbour (2 = any; else must equal diag)
```
**Data note [C+D]:** 0x4d21d8 is the family attribute row shown as "参与围攻:" in the class window (0x477c27,
"是" for 0, "否" for 1). In the shipped Ekd5.exe (and every backup exe) it is 1 for all 40 families, so **no
unit can ever help and 围攻 is never enabled** in 新改曹操傳 6.6 — the port must still implement the rule.
(rules.md calls row k7 "0 → SP table used"; the reader 0x416e9c is this family test, the SP test follows it.)
Handler 0x41d693 (for completeness): word 0x500e9a = 1, pick a target in attack range; no helper →
"不能围攻该部队" (0x48b1c8); then 0x417c67: SE 5, message "围攻", the initiator attacks (0x417bf2), then each
helper in list order attacks (each gets flags 6) until the target's HP is 0; if all attacked and it lives,
the target counters the initiator only (0x406453, unless byte 0x500e99 ≠ 0); count of helpers that attacked
→ 0x500e9c (used by §5.5). Initiator flags 6.

**BishaAvail 0x4225fb(U)** [C] — 必杀 (SP u8 0x501c00[person]; skill records 0x4a7510 + 16·i, 武将技 i = 1..79,
军师技 i = 80..96; byte +0xe = SP cost; family table 0x4d2200 = row k8):
```
if EV4059 (禁止必杀, byte 0x505f6c) ≠ 0: return 0
c = 0x4d2200[family(U)]                     # 0 = 武将 family (person skills); 1..9 = a 军师技 family
if c == 0:
    if U.code == 7: return ≠0                # player-controlled: always offered (checks happen in the list)
    need = EV4061 (必杀所需SP, byte 0x505f74); result = 1
else:
    need = skill[79 + c].cost;               result = 2
if 禁咒: return 0
if SP[person(U)] < need: return 0
return result                                # the AI phase uses result == 1 → 0x4225a2 (§4.12)
```
Handler (sel 5):
```
if EV4087 == 0 and BishaAvail(U) and c ≠ 0:             # 军师技, army-wide, no target choice
    idx = c − 1; if idx ≥ 9: idx = rand(8)
    animation 0x4251e1(0x497af8, 0x3b, slot); 0x500c41 = idx; call 0x467d1d[idx](U, c)   # 9 handlers
        (each ends in 0x409b67 → 0x4253f6, which sets U.flags |= 6)
    0x501bf9 = 5; SP[person] −= min(SP, skill[79 + c].cost)                               (0x423910)
else:                                                   # 武将技 list
    loop: s = 0x42c177(U, 1)   — sealed → "正处于禁咒状态。" and back to the menu; list dialog 0x11a in
              skill mode; cancel → back to the menu
          word 0x500e9a = s·256 + 2; t = target picker (attack range of U, mode 1); cancel → list again
    0x417a96; attack 0x43db23(U, t, no pre-attack reactions); U.flags |= 6;
    SP[person] −= min(SP, skill[s].cost); 0x500e9a = 0
```
The per-skill SP test and the list contents (0x418744 person-has-skill) are skills.md [? not traced here].

**攻击 0x43dada** [C]: target picker 0x45533d(slot, rangecode, mode 1) — highlights the range, a click outside it
→ "不在范围之内。", on an own-side unit → "不能攻击我军部队。"; with an area/penetration weapon (U+0x61 =
0x407835 ≠ 0) a click on an empty cell in range is accepted if the area hits a unit (0x406e2b), which becomes the
target; no target at all → "范围内没有敌军部队。". Then 0x43db23(U, t, 1): face t; pre-attack reactions 0x410f1c
(may cancel or swap attacker/defender — battle.md); combat slots 0x4064f1; 0x42c144 = combat 0x4363f1 + the
引导攻击 follow-up (0x4212f1); post-combat reactions 0x4223a9 (→ 0x438ebd); flags 6. Cancel → back to the menu.

### 5.4 Map-level commands [C]

* Right click on an empty cell = 结束回合 (ctx+1 = 6 → yes/no prompt); on a unit = its unit window.
* Toolbar / menu (WM_COMMAND 0x474c97; tooltips table 0x4750b1): 0x65 保存 (only if byte 0x500fff ≠ 0, else a
  message), 0x66 读取, 0x68 结束游戏 (WM_CLOSE), 0x69 武将一览, 0x6a 胜利条件 (text 0x496ca0 or "现在无法显示"),
  0x6b 环境设定 (dialog "KANKYOU", §5.6), 0x6c 战场缩小图, **0x6d 结束回合** → ctx+1 = 6, **0x6e 检索未执行部队**
  → ctx+1 = 7, 0x6f 历史情报, 0x70 练武场 mode chooser (0x474e0e: 普通模式 / 单挑模式 / 自动提升 → EV4087,
  duel.md), 0x9cd5 持有道具一览, 0x9cd6 地形情报一览, 0x9cd7 宝物图鉴. 0x6d / 0x6e act only in battle (0x40b922).
* Keyboard hook 0x413296 (active window = main window, no auto-repeat): '0'..'4' game speed (word 0x500ad8),
  '5'..'9' and 'A'..'P' toggle display option k = key − '5' / key − 0x3c (§5.6), arrows scroll (0x47ba9b),
  'Z' 0x4250e6, Shift 0x42268c, '-'/'+' 0x42cc47 [UI, not traced further].

### 5.5 After a player action: AfterPlayerAction (inside 0x44e0d9) [C]

```
toolbar off
if ctx+1 != 2:
    StatusAura()                       # 0x42bc14: dead units removed (0x40502b); every on-map unit with HP
                                       # and query(18, 0x2a, 1, 1) (0x472c53, "反弹异常攻击") loses all status
                                       # (0x42402c(U,100)) and its debuffs (< 3) are reset to 3 (0x45aa37)
    MoveAgain(U)                       # 0x415d93, below
    StatusAura()
    s = U.slot
    loop:
        if !Rampage(s): ExtraAction(s)                 # 大杀四方 first, else 二次行动
        if 0x500e9c == 0: break
        s = 0x500e9d[--0x500e9c]                       # then every 围攻 helper that attacked
```
* **再次移动** MoveAgain 0x415d93(U): if U is alive and not confused (0x426b33 == 0) and has query(90, 0x5f, 1, 1)
  (0x43c438): flags &= ~6, SE 0x27, MoveSelect(U, rangecode 0x0b = no attack overlay, mp 0 = full move points,
  mode 1) — a plain move, no menu — then flags |= 6 whatever happened.
* **大杀四方** Rampage 0x41b508(slot): flag U+0x24 bit 7 is set by 0x4290c8 when U lands a lethal hit (physical
  0x4037a3 / strategy 0x420efb: damage ≥ the target's HP > 0) and `U+0x24 < v`, v = value of query(64, 0x54, 1,
  0) (0x45d3be; the byte compare includes bit 7, so a second kill in the same action changes nothing). After the
  action: if bit 7: clear it; if U is on the map: U+0x24 += 1 and the unit may act again (0x412d9d: flags &= ~6,
  effect 0x43e6aa(slot, 6, −0x78)); returns 1. So up to v extra actions per phase.
* **二次行动** ExtraAction 0x412d52(slot): person ≠ 0xffff, HP ≠ 0, 0x508b00[slot] == 0 and query(56, 0x5a, 1, 1)
  (0x421175) → 0x412d9d (act again) and 0x508b00[slot] = 0xff: once per phase.
* Phase start (0x44ac28, not when resuming a save): for all 250 slots flags &= ~6, dword U+0x22 = 0 (clears the
  大杀四方 counter and bit), 0x508b00[slot] = 0; 0x501bf9 = 0xff. 0x44ac28 runs at the player phase and at the
  enemy phase (not the ally phase) — §1.3.

### 5.6 What the player sees of the AI: display options (环境设定 "KANKYOU", hotkeys) [C]

Options are bytes 0x501a65 + k (saved in the 0x501000 block; the dialog edits a copy at 0x500fa4, names 16 B at
0x4beec0 + 16k with their hotkey):

| k | key | name | byte | effect (reader) |
|---|---|---|---|---|
| 0 | 5 | 显示生命条 | 0x501a65 | HP bar on unit sprites (0x43eae4) |
| 1 | 6 | 显示Buff状态 | 0x501a66 | buff arrows; slots < 20 with 0x501b00[slot] ≠ 0 tinted 0xff8000 in the player/ally colours |
| 2–4 | 7–9 | 部队状态 / 双击暴击 / 地形状态 | 0x501a67–69 | UI |
| 5 | A | 开启自动存档 | 0x501a6a | autosave (below) |
| 6–8 | B–D | 策略等级 / 攻击方描边 / 保留装备 | 0x501a6b–6d | UI / equipment |
| 9 | E | **显示行动顺序** | 0x501a6e | AI action order numbers (below) |
| 10 | F | **显示AI仇恨** | 0x501a6f | AI value numbers (below) |
| 11 | G | **显示危险区域** | 0x501a70 | threat tint (below) |
| 12 | H | 显示升级提示 | 0x501a71 | |
| 13 | I | **显示AI方针** | 0x501a72 | AI order text (below) |
| 14–18 | J–N | Buff回合 / 连续使用功勋 / 跳过战斗过程 / 暴击不语 / 显示撤退部队 | 0x501a73–77 | |
| 19 | O | **预览行动路线** | 0x501a78 | path preview (below) |
| 20 | P | 极速移动 | 0x501a79 | |

* **危险区域 (threat)** 0x421cd6(E), evaluated while drawing each unit sprite (0x43eae4): only when the option is
  on, E.colour ≥ 2 (enemy colours), an attack-range overlay is up (0x4b5dd5 ≠ 0xff — i.e. while a unit's move
  range or a target picker is shown) and `cur` has code 7. Then byte 0x500ace += 1 (probe mode) and E's own
  movement flood runs (0x438484(E, E.pos, MovePoints(E), mode 4, zoc 1), on the scratch grid MapBuf+0 so the
  player's reach grid survives); in probe mode CellScore stops as soon as BestPhysical / BestStrategy find the
  person of `cur` (0x4b5df0) among the targets from a reachable cell (0x421d6c) → 1. Result 1 → E's sprite is
  tinted 0xff0000 (0x40690c(0x900, img, 0x28, colour, 1)). So the option marks **the enemy units that could hit
  the selected unit, at the cell it stands on now** — not a cell overlay. Flood, CellScore, BestPhysical and
  BestStrategy are §4. Quirks [C]: BestStrategy answers at the first strategy that has a cast range (0 or
  1), later strategies are not tried; a self-area strategy returns its score, which counts only when it is
  exactly 1; if E is under 禁咒 CellScore returns the 禁咒 counter, so a 1-turn seal reads as "dangerous" at
  E's own cell. Other tints in the same drawer: acted (flags 2 and 4, HP > 0) grey (colour 0); in enemy colours
  中毒 → 0xa500 (takes precedence over the threat tint).
* **AI仇恨 (AI value)** 0x412f37(E), drawn as a number at (0x12, 0x28) on E when ≠ 0: needs cur (slot ≠ 0xff) on
  the other side than E and the move-range display of cur (cursor+0x64 == 1, or +0x68 == 1 with side(cur) == 1).
  Value = cache 0x5003a0[E.slot] if ≠ 0, else `max(1, PhysScore(E → cur) (0x4389bd(E; cur.slot, 0)),
  BestStrategy(E, at cur's cell, given target cur) (0x439169, skipped under 禁咒))`, stored in the cache. The
  cache is zeroed when a move selection or an attack/cast (0x441488) ends (0x422386).
* **行动顺序** (0x43e782): in the player phase only while cursor+0x64 ≠ 0, recomputing both sides' order first
  (0x44da7a(0), (1)); in AI phases always; draws U+0xb at (0x12, 0x3a) for every unit with code ≠ 7.
* **AI方针** (option I): the order label 0x42641e (§3.2) is written into the unit panel 0x44049e, i.e. it is
  shown when the panel of a hovered unit is drawn during the cursor wait 0x454269 / target pickers. The caller
  (0x440ba4) passes a default text in eax — "友军" (0x48e06c) for side 1, "敌军" (0x48e074) otherwise — which is
  what that line shows when the option is off [C].
* **预览行动路线** 0x427739: while a move display is up, the path from cur to — player phase: the cell under the
  cursor (0x4b4248); AI phases: the AI's chosen destination (0x4b2c20) — is computed (0x437e23) and drawn.
* **Autosave** (option A): at the start of every player phase that is not a resumed save, slot = turn (ctx+2)
  mod 20 via 0x412ae5 with byte 0x500acf temporarily 0x2c; at the end of the phase slot 20 if byte 0x500df9 ≠ 0.
  0x412ae5 saves only when 0x500fff ≠ 0 (saving allowed) [C; slot naming G].

## 6. Differences from wg2025 (behaviour the port must change)

### 6.1 Battle flow

* Slots 0..19 / 20..59 / 60..249 (wg2025 0..14 / 15..34 / 35..114); deployment entries 16 B (wg2025 64 B).
* Two passes per AI phase (§1.4); no restart of the order scan after an action.
* Extra actions: U+0x24 (kill → effect 0x40), effect 0x38 once per phase, 围攻 partners (§1.10).
* Specials (必杀 / SP) pre-step and pass 0 of the action order; 9 passes with EV 4063 variants; slot-59 quirk.
* SetAI accepts mode 7 (→ code 7); party test is P+0x2a ≠ 0xff (wg2025: == 0).
* Kind values 5/6, KindSwap at phase starts, controlled enemies (EV 4078), third side 2 (EV 4053), ZOC side
  function by EV 4019.
* Victory/defeat test loops have inclusive bounds (slot 250 / 60 / 20 quirks); turn limit forces the person-0 retreat.
* 104 extra rand() calls per player phase (0x423490); RNG reseeded from GetTickCount at each battle start.
* Retreat-line flag is U+0x1f (wg2025 +0x20).

### 6.2 AI
* Slots / leader: enemy leader slot 60 (wg 35); retreat goal U[0] / U[60].
* AIAct skips only 混乱 units (wg: 乱 and 迷); status is four 2-bit counters.
* Flood: same discovery order, plus the activity area, the rectangle 0x501bf0, zoc modes 2 / 3, 穿越移动 /
  突击移动 / trap ZOC, the EV 4019 side function and the probe mode.
* CellScore: ties go to the later cell for codes 0 and 4 (wg: always the first); `strategy == 0x48` special case.
* BestPhysical keeps the LAST best target on ties (wg: first). PhysScore is re-weighted: `max(1, dmg·100/HP)`
  (kill ≥ 100) instead of the 80/16/10/2 buckets; target +98 (wg: none), 众矢之的 = 101, 麻痹 +8 (wg: 乱 +8),
  leader / boss +8 else +4 (same), casters < 75 → 0 (same), immunity gates → 1, area: no extra hit → `v > 4 ?
  v − 2 : 2` (wg: −4, ≥ 0), per hit kill +10 / else +3 (wg 10 / 4 / 0), counter −1 (same) except with 必杀.
* BestStrategy: TargetBonus 101 / 98 (wg: +10 for the target); categories from MgAIYN1/2 instead of a hard-coded
  strategy-id switch; no 255 cap; new category values (§4.6).
* Code 3 (passive) tests attack cells with unlimited move points and may evaluate the whole move range; activity
  area two-step in the enemy phase. Code 1: phase-loop pass 1 makes idle units advance; zoc-2 fallback; friends
  without a reachable enemy follow U[0].
* StepToward retries (codes 0 / 4) with restricted direction sets.
* 必杀: SP / family specials chosen before and after the move (§4.12).
* EV 4065 (AI terrain use) / EV 4066 (attack direction) via the candidate cell 0x48e8c2.
* SetAI mode 7 → code 7 (hand a unit to the player); army members still refuse SetAI.

### 6.3 Player phase

* Player side is slots 0..59 (player 0..19, allies 20..59), not 0..34; the auto-end count scans all 250 slots.
* Menu: 攻击 策略 道具 交换 围攻 必杀 待命 取消 (wg2025 / the port: 攻击 策略 道具 待命). 策略 is offered when the unit
  knows any strategy (or can imitate a neighbour's); 禁咒 is reported when it is chosen. 道具 depends only on
  the army bag. The menu is not rebuilt after a cancelled sub-command.
* Right click: empty cell → end-phase prompt, unit → unit window (the port opens a system menu).
* While choosing a destination, a click outside the range turns the unit to face it and keeps the selection
  (the port switches to another unit or cancels); a reachable occupied cell gives "因为有其他部队，所以不能移动。".
  Clicking a finished unit lets the player re-face it.
* Only 混乱 blocks commanding (6.6 has no 迷); enemy / uncontrolled ally clicks show the range and, on a second
  click, "这是敌军部队。" / "这是友军部队。".
* The attack overlay shown with the move range is the shape around the unit's current cell (the port draws the
  union over all reachable cells).
* New: 再次移动, 二次行动, 大杀四方, 围攻 helpers, 必杀 (武将技/军师技, SP), 交换, NextUnit, and the AI displays.

## 7. Open questions

### 7.1 Battle flow

* Effects 0x12 反弹异常攻击, 0x38 二次行动, 0x40 大杀四方, 0x46 深入敌后 (names from the 特效 table 0x4cc600):
  value semantics — docs/skills.md.
* 0x4b4230 bit 2: no setter found (debug "control everything" mode?).
* Results 1 and 4 handled by the scene loop but never set by the exe.
* 0x42fc0c map-object timers and 0x501b00 player-unit timers: semantics for battle.md.
* Whether anything outside the searched patterns (bulk copies other than 0x4081a6 / save load) writes unit +0xb;
  the §2.2 slot-59 statement assumes not.
### 7.2 Player phase

* Rows of the strategy / 武将技 / item lists that are greyed and why (MP, terrain, weather, per-skill SP) —
  skills.md / items.
* MoveSelect with rangecode 0xff (0x41f3fb) and mp == −1 (0x4028cc) callers not traced.
* 0x501b00[slot] (Buff tint) meaning; hotkeys 'Z', Shift, '-'/'+'.
* Right-click cancel after clicking a finished unit turning it to facing 1 — a real original quirk per the
  code; worth confirming in the running game.

### 7.3 AI
* `Eff(0x60, 0x7a)` (左天羅右地網 by the 特效 name table; item effect 0x7a reads 忽视能力 in 0x4cb7a0): its 4
  neighbours become attack cells in Prepare and AtkRangeCode forces adjacent opposite units to melee range 0 —
  name / item pairing to be confirmed in skills.md.
* CellScore's special case `bestStrat == 0x48` (72 = 昂扬 in this data, never chosen: MgAIYN1 13) looks like a
  leftover id of 连击 (33 = 0x21 here, the strategy BestStrategy treats with the attack range); faithful as is.
* BestStrategy's "no cast range" branch (strategy range code 0xff) is dead with the shipped strategy data (no
  strategy has range 0xff and 0x41ce8c never yields it); documented for completeness.
* Byte 0x500af0 (TerrainScore: == 2 → healing terrain always +1) is +0x10 of the 练武场 dialog context 0x500ae0
  (its mode copy of EV 4087, duel.md); byte 0x500ad3 == 1 (set / cleared around 0x40eb90) disables unit blocking
  and ZOC for everybody.
* 0x441488's role in placing the strategy target for the dispatcher 0x425627 (called with target −1) is inferred.
* A scripted move (flag 0x80) toward an unreachable goal takes `dest = goal`; MoveAlongPath then descends a grid
  in which the goal has no cost (0xff, compared as 255): if a neighbour of the goal was reached, the path runs
  from U to that neighbour and ends with a step onto the goal cell itself; if not, StepToward stops at once and
  returns a one-step path made of a stale byte. What the walker 0x43d9ed does with such a step was not traced;
  verify in the running game before porting this edge case.
* Item use: none by the AI (§4.13); 必杀 effects (0x465fab, the nine 军师技 handlers 0x467d1d) are skills.md.

Duels (单挑), debates (舌战) and the 练武场 small-window battles (EV 4087, MgAIYN2, AIAct on slot 60 from the dialog
0x45321a) are specified in [duel.md](duel.md).
