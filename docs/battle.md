# 新改曹操傳 6.6 — battle rules (Ekd5.exe)

Specification of the battle rules of the 6.6 engine, for porting into `game/src/battle/` and `game/src/core/rules.gd`
(which still hold wg2025's rules — the 6.6 engine changed almost every formula, so do not reuse wg2025 numbers).
All addresses are VAs in `orig/Ekd5.exe` (image base 0x400000). Confidence: **[C]** confirmed in the disassembly
(`tools/disx.py`, recursive disassembly; Ghidra only as a cross-check — the hand-written asm passes values in
`ecx`/`edx` and through the caller's stack slots, so its C is often wrong), **[D]** from data or the mod's own notes
only, **[G]** inferred. A section heading tagged [C] means every statement under it is [C] unless tagged otherwise.

Related documents: record layouts and the memory map in [memory.md](memory.md) and [rules.md](rules.md) (data
track); the effect catalogue (what each 特效 / item effect id means, the effect query 0x4101d9 itself) in
[skills.md](skills.md); AI decisions, the command loop and duels in [ai.md](ai.md) / [duel.md](duel.md); scripts in
[eex.md](eex.md).

Integer arithmetic: all divisions truncate toward zero on unsigned 32-bit values unless stated; `x·p/100` means
`(x·p)/100` computed in 32 bits (overflow is not a concern for the values involved). "byte arithmetic" means the
original works on 8-bit registers and wraps at 256.

## Contents

1. [Physical attack](#1-physical-attack) — exchange flow, battle stats, hit, damage, critical, second strike,
   damage post-processing, applying a strike, counters / preemption / follow-ups, range and area shapes,
   knock-back, 武将技 / 军师技 and SP, 围攻, order of random draws
2. [Strategies](#2-strategies) — data, learning, casting, targeting, hit, damage, healing, special handlers, EXP
3. [Status effects and buffs](#3-status-effects-and-buffs)
4. [Items in battle](#4-items-in-battle)
5. [EXP and level-up](#5-exp-and-level-up)
6. [Movement, terrain and weather](#6-movement-terrain-and-weather)
7. [Turn housekeeping](#7-turn-housekeeping)
8. [Configuration EVs and patched constants](#8-configuration-evs-and-patched-constants)
9. [Open questions](#9-open-questions)

## Quick reference — the core formulas

| What | Formula | Where |
|---|---|---|
| Physical damage | `Level(A) + 25 ± \|VA − VD\|/5` (min 1), then matchup %, effect terms, ×3/4 for counters and second strikes, rand(7) spread −2..+4 | 0x43bc5a §1.5 |
| Strategy damage | `Level(C) + 25 ± \|精C − 精T\|/5`, × MgHurt %, × family resistance %, element/terrain/weather +25 %, effect terms, spread | 0x43c01d §2.7 |
| Hit curve (both) | `a ≥ 2d → 100; a ≥ d → 90 + (a−d)·10/d; a ≥ d/2 → 60 + (a−d/2)·30/(d/2); else 30 + (a−d/3)·30/(d/3)` | 0x43b53a §1.4 |
| Hit roll | rate ≥ 100 hits; else roll, one retry at rate−10 when rate ≥ 85 | 0x43b4b6 §1.4 |
| Crit / double curve | `a ≥ 3d → 100; a > 2d → 20 + (a−2d)·80/d; a ≥ d → 2 + (a−d)·18/d; else 1` (士气 / 爆发) | 0x405d0a §1.6 |
| Crit bonus | physical `+dmg·(rate+100)/2 %` (`+50 %` for 必杀); strategy `+dmg·(rate+100)/4 %` | §1.6, §2.7 |
| Buff level effect | level ≥ 4 → ×12/10, ≤ 2 → ×8/10 (code byte 0x22) | 0x42211e §1.3 |
| Status durations | 麻痹 1, 禁咒 2, 混乱 1, 中毒 3 turns; recovery roll `luck/2` % at count 1 | 0x4240ce, 0x42402c §3 |
| Physical EXP | `2·clamp(Lt−La, −1, 47) + 6`, kill `+64/(max(La−Lt,0)+2)` (leader +48) | 0x4037a3 §5.2 |
| Level-up growth | stat += `(class grade + ability grade) >> 1` per level, no randomness | 0x4073f3 §5.4 |
| Regeneration | HP `MaxHP·t/100` (+effect %), MP `t` flat; t = 城池 25, 关隘/鹿砦/兵营 20, 村庄 15 | 0x43cddd §7.4 |
| SP gain when hit | `dmg/4` (player/ally) or `dmg/2` (enemy), min 1, cap 255 | 0x410fc3 §1.13 |

## 1. Physical attack

### 1.0 Conventions (used throughout this document)

* `EffQ(u, sp, it, a3, a4)` = the effect query **0x4101d9** (`ecx` = unit `u`, four stack arguments in call order).
  `sp` = personal 特效 id (names: 0x4cc600 + sp·16), `it` = item-effect id (names: 0x4cb7a0 + (it − 0x1a)·16).
  It returns the effect value (0 = absent). Semantics of `a3`/`a4` and the catalogue of effects are in
  docs/skills.md; below every query gives its arguments and the 特效 name.
* `side(u)` = 0x406710: table 0x40672d[`u+5`] → 1 player/ally, 0 enemy, 2 third party (`u+5 == 3` and EV 4053).
  `isPlayer(u)` = 0x43ff54: `u+5 == 0`. Unit slots: 0..19 player, 20..59 ally, 60..249 enemy.
* Unit fields: `+0` person id, `+4` slot, `+5` army code, `+6/+7` x/y, `+0xe` AI code (7 = player-controlled),
  `+0xf` facing 0..3, `+0x10` HP, `+0x14` MP, `+0x18..+0x1d` buff levels (atk, def, spi, 爆发, 士气, move;
  3 = neutral), `+0x1e` status byte (2-bit counters: 麻痹 bits 0-1, 禁咒 2-3, 混乱 4-5, 中毒 6-7). Status test
  **0x423fe8(mask)**: mask 2 → 麻痹 counter, 4 → 禁咒, 8 → 混乱, 0x10 → 中毒 (returns the counter, 0 = none).
* `Pct(p, v)` = 0x425ad9 = `v·p/100` (unsigned 32-bit). `SatSub(a, b)` = 0x47fa9e = `a > b ? a − b : 0`.
  `MinAdd(a, b, cap)` = 0x47fa89 = `min(a + b, cap)` (signed compare).
* `UnitFamily(u)` = 0x43b4a7 → 0x40bf0c: class ≤ 59 → class/3, 60..79 → class − 40, else 40.
* Family attribute rows 0x4d20c0 + 40·k (u8[40]): **k3 0x4d2138 "ranged" flag** (families 2 弓兵, 4 弓骑兵, 5 炮车,
  19 女弓兵, 28 井栏), **k7 0x4d21d8 "may not join 围攻"** (1 for every family), **k8 0x4d2200 军师技 index**.
* Rolls: `Roll(p, mode)` = 0x4287a8 (accumulator-aware; called `roll_acc` in §2) and `Chance2(p, m)` = 0x43786b
  (plain / deck roll; called `roll` in §2, `Chance` in §7), both in §1.4. §2 writes the effect query as
  `effq(u; sid, eid, a3, a4)` and §6–7 as `EffQ(sid, eid, a3, a4)` — same function and argument order.
* RNG: `rand(n)` 0x47fb13 = MSVC LCG (`seed = seed·0x41c64e6d + 0x3039; r = (seed >> 16) & 0x7fff`; `n < 2 → 0`,
  else `r % n`); `chance(p)` 0x47fb32 = `rand(100) < p`. Seed starts at 1 (0x48ecd4).

### 1.1 The combat object (0x4927f0, one global) [C]

| Off | Meaning |
|---|---|
| +0x00 / +0x01 | attacker slot / current target slot |
| +0x04 / +0x08 / +0x0c | attacker person id / person ptr / unit ptr (0x406289) |
| +0x10.. | target slots, 0xff-terminated (primary target first, then the area targets) |
| +0x84 + 4i | HP damage for target i |
| +0x254 + 4i | MP damage for target i |
| +0x424 / +0x425 | area code / target position (0x406289) |
| +0x428 | person EXP of this attack = max over targets and strikes (§5) |
| +0x42c | weapon EXP (sum) |
| +0x430 + 4i | armour EXP of target i |
| +0x600 | `isPlayer(attacker)` (EXP flag) |
| +0x604 | critical flag of the last strike |
| +0x608 | strike counter (0 = first strike) |

Globals: **[0x500e9a]** attack mode: 0 normal, 1 围攻 in progress, 2 武将技 (必杀) — the word at 0x500e9a is
written `(skill << 8) | 2`, so **[0x500e9b] = skill number k** while mode 2 [C: 0x4225f1, 0x423373].
**[0x492e04]** counter depth. **[0x500c48]** tiles walked this action (set by the path walker 0x437e23, cleared
at the end of the command) [C]. **[0x48e8bd]** HP damage dealt to the primary target in this exchange.

### 1.2 Exchange flow [C]

Player 攻击 command 0x43dada → **0x43db23(unit, ?, target, checkPre=1)**; AI 0x43aaf7 does the same inline.
```
Attack(A, T):                                     # 0x43db23 (player), 0x43ac93.. (AI)
    face A toward T                               # 0x435829 (A turns; T keeps its facing)
    pre = checkPre ? Preempt(T, A) : 0            # 0x410f1c; the 必杀 path passes checkPre = 0
    if pre == 0xff: goto after                    # T's 策略先手 killed/confused A
    if pre: Exchange(T, A)                        # T strikes first; A's blow becomes T's "counter" below
    else:   Exchange(A, T)
after:
    r = FollowUp(A, T)                            # 0x42c144: 奋战, else 引导 if T died (§1.10)
    SupportAttacks(T, A)                          # 0x4223a9: 同仇敌忾 then 戮力同心 (§1.10)
```
```
Exchange(X, Y):                                   # 0x4064f1, ecx = 0x4927f0
    setup combat object: targets = [Y] + AreaTargets(X, Y)   # 0x406252 → 0x406289, §1.11
    obj.strikes = 0
    loop while obj.strikes < 2:
        Strike()                                  # 0x4527fe = Compute 0x405de1 + Apply 0x452907
        StrategyPursuit(Y)                        # 0x417983, §1.10
        if not Again(): break                     # 0x4060d2, §1.7
        obj.strikes += 1
        if X confused (0x423fe8(8)): break
    PostExchange()                                # 0x406b3c: reflect, 吸血, 吸收金钱, EXP (§1.9)
    0x42ab32(0)
    if mode == 0: Counter()                       # 0x406453 (not in 围攻 / 必杀 mode), §1.10
```
`Strike` = **0x405de1** (compute damage for every target, critical for target 0, §1.5–1.8) then **0x452907**
(转移伤害 0x418205 unless the attacker has 斩杀攻击, the attack animation 0x4526e7, then Apply 0x405966 §1.9).

### 1.3 Battle stats [C]

All four combat rolls use **StatPair 0x40d2ab(A, kA, D, kD, noTerrain)** (stdcall, returns EDX = A's value,
EAX = D's value). Stat index k: 0 攻击, 1 防御, 2 精神, 3 爆发, 4 士气.
```
StatPair(A, kA, D, kD, noTerrain):
    VA = UnitStat(A, kA, effOther = EffQ(D, 0x6a 偷梁换柱, 0x6a, 1, 0))       # 0x421278
    VA = Auras(A, kA, VA)                                                     # 0x423ced
    VA = Weaken(by D, kA, VA)                                                 # 0x416a38, ecx = D
    VD = UnitStat(D, kD, effOther = EffQ(A, 0x54 批亢捣虚, 0x70, 1, 0))       # 0x43c3ba
    VD = Auras(D, kD, VD)
    VD = Weaken(by A, kD, VD)
    if not noTerrain:
        VA = VA · TerrainPct(A, 0x1e).pct / 100     # 0x40c7c8, unsigned; A's own tile (the AI's planned tile 0x48e8c2 when EV4065 ≠ 0, §6.3)
        VD = VD · TerrainPct(D, 0x20).pct / 100     # D's real tile
    return VA, VD
```
Users: damage (k 0 vs 1), hit (3 vs 3), critical (4 vs 4), double attack (3 vs 3); all with terrain.

**UnitStat 0x414ccb(k, effOther)** (ecx = unit):
```
own = EffQ(u, 0x39 唯我独尊, 0x61, 1, 1)                                     # 0x43c3cc
if effOther and not own:                     # opponent's 偷梁换柱 / 批亢捣虚
    v = effOther >= 6 ? min(Buffed(u, 0..4)) : Buffed(u, effOther − 1)       # starts at 0xffff
elif own and not effOther:  v = max(Buffed(u, 0..4))
else:                       v = Buffed(u, k)
v = HpMpAssist(u, v, k)        # 0x428430
v = Alone(u, v)                # 0x478eab 一夫当关
v = Outnumbered(u, v)          # 0x4363b0 万夫莫敌
v = Morale(u, v)               # 0x4200a2 (众志成城, 鬼神之勇, difficulty EVs)
```
* **Buffed(u, s)** = getter table 0x440151[s] (0x43f5ff, 0x43f62b, 0x43f657, 0x43f683, 0x43f6af):
  `min(BuffApply(PersonStat(s), 0x22, u[0x18+s], u), 9999)`.
  `PersonStat(s)` (0x40715a + 0x35·s) = `min(BaseStat(s) + EquipBonus(s) + StatFloor(s), 9999)` — person-level
  stat, see docs/rules.md and §5 (BaseStat 0x43c4d3 includes the kill-count and 破百 bonuses).
* **BuffApply 0x42211e(v, code, level, u)**: `up = (code >> 4) & 15` and `down = code & 15` (tenths; the shipped
  byte is 0x22 at 0x43f617/0x43f643/0x43f66f/0x43f69b/0x43f6c7, i.e. up 2, down 2). For the unit and each of its 8
  neighbours (0x4359f5 order: up, right, down, left, up-right, down-right, down-left, up-left) of the **same side**,
  `w = EffQ(n, 0x74 状态强化, 0x4c, 1, 0)`; if `w`: `up += w/10`, `down −= min(w%10, down)`. Then
  `level >= 4 → v·(10+up)/10`, `level <= 2 → v·(10−down)/10`, `3 → v` (unsigned). The magnitude does not depend on
  4/5/6 or 0/1/2 (the level only counts down, §3).
* **HpMpAssist 0x428430**: for i = 0..4, stop at the first i that applies anything:
  `m = EffQ(u, 0x9d+i HP辅助, 0x7d, 3, 0)`; if `m >> k & 1`: `v += HP/5` (current HP, 0x40bad4 signed);
  `m = EffQ(u, 0xa2+i MP辅助, 0x7e, 3, 0)`; if `m >> k & 1`: `v += MP` (current MP word +0x14).
* **Alone 0x478eab**: `p = EffQ(u, 0x47 一夫当关, 0x69, 0, 0)`; if p: `n` = number of units of `u`'s own side
  (kind 4 if side(u)==1 else kind 5) in the 3×3 box around u (0x41bc4a → 0x428df1 / 0x44cb12); if `n == 0`, or
  `n == 1` and that unit is `u`: full p, else `p >>= 1`; `v += v·p/100`.
* **Outnumbered 0x4363b0**: `p = EffQ(u, 0x55 万夫莫敌, 0x71, 1, 0)`; `n` = units of the opposing side in the 3×3
  box; `v += v·(p·(n+1))/100`.
* **Morale 0x4200a2** = `v = 0x43cb00(v)`, then `u+5 >= 2 → v·EV4033/100`, `u+5 == 1 → v·EV4034/100` (only if the
  EV ≠ 0; player units `u+5 == 0` never scaled). Defaults EV4033 = EV4034 = 0 (off).
  **0x43cb00**: sum over every on-map unit `w ≠ u` (state 2, person id < 0x400) with
  `p = EffQ(w, 0x3c 众志成城, 0x1c, 1, 0)` with u in one of the 8 cells around w (0x420b08): `n` = number of w's own-side units in the 8 cells
  around w (0x4024aa); same side →
  `S += p·n`, else `S −= p·n` (imul at 0x43cb8f = "stacking" mode). `S > 0 → v += v·S/100`;
  `S < 0 → v −= min(v·|S|/100, v − 1)`. Then **鬼神之勇 0x45b67c**: `p = EffQ(u, 0x51, 0x6d, 0, 0)`;
  `b = min(p, ((MaxHP − HP)·100/MaxHP) >> 1)`; `v += v·b/100`. Result `max(v, 1)`.
* **Auras 0x423ced(u, k, v)**: for j = 0 (能力替换) then j = 1 (能力辅助), for i = 0..4:
  `r = EffQ(u, (j ? 0x85 : 0x80)+i, j ? 0x7b : 0x7c, 2, 0)` (0x412be6 via table 0x412c70); `src = r >> 5`,
  `mask = r & 31` (format of 能力替換.txt). If `mask >> k & 1`: `w = UnitStat(u, src, 0)`;
  能力替换: `v = (k == 4 or w >= v) ? w : v`; 能力辅助: unless the same `r` was already applied in this pass,
  `v += w·20/100`.
* **Weaken 0x416a38(k, v)** (ecx = the opponent): for i = 0..5, `m = EffQ(opp, 0x8a+i 忽视能力, 0x7a, 3, 0)`;
  at the first i with `m >> k & 1`: `v −= v·20/100`, stop.

### 1.4 Hit [C]

**HitTest 0x43b4b6(A, D, kind = 1 physical, param)**:
```
rate = PhysHitRate(A, D)                      # 0x43b623 (strategies: StratHitRate 0x43b730, roll mode 0x13)
if (byte)rate >= 100: hit
if EV4018 > 1:                                # config, default 0
    if rate >= EV4018: hit
    if rate < EV4017: miss                    # EV4017 default 0
for try in 0, 1:
    h = Roll(rate, mode = 1)                  # 0x4287a8
    if EV4018 == 1 or h or rate < 85: break
    rate −= 10                                # one retry at rate−10 when rate ≥ 85
return h                                      # (code returns rate·2 / h·2; only "nonzero" matters)
```
**PhysHitRate 0x43b623**:
```
if mode == 2 (必杀): return 100
if famflag3[UnitFamily(A)] and EffQ(D, 0x2f 防御远距攻击, 0x4e, 1, 1): return 0     # 0x47ef3d → 0x41cddc
if D paralysed (0x423fe8(2)): return 100
(VA, VD) = StatPair(A, 3, D, 3, 0)                       # 爆发 vs 爆发, terrain applied
rate = HitCurve(VA, VD)                                  # 0x43b53a
if EffQ(A, 0x1e 攻击绝对命中, 0x24, 1, 1): return 100
v = EffQ(A, 0x1f 辅助攻击命中, 0x7e, 1, 0);  if v: rate = min(rate + v, 100)
v = EffQ(D, 0x20 辅助攻击防御, 0x29, 1, 0);  if v: rate = SatSub(rate, v)
return Direction(A, D, rate)                              # 0x408eee
```
**HitCurve 0x43b53a(a, d)** (unsigned):
```
a >= 2d       → 100
a >= d        → 90 + (a − d)·10 / d
a >= d/2      → 60 + (a − d/2)·30 / (d/2)
else          → 30 + SatSub(a, d/3)·30 / (d/3)
# d = 1, a = 0 (3rd line, d/2 = 0) and d = 2, a = 0 (4th line, d/3 = 0) divide by zero: the original faults (§9)
```
**Direction 0x408eee(A, D, rate)**: `extra = DirBonus(A, D, rate, retExtra=1)` (0x408db1, §1.5);
`rate = min(rate + extra, 100)`; `rate = SatSub(rate, EffQ(D, 0x21 辅助全防御, 0x22, 1, 0))`; `max(rate, 1)`.

**Roll 0x4287a8(p, mode)** — `mode` low nibble = accumulator slot, bit 0 = "count misses", high nibble 1 = the
strategy table. Physical hit 1, critical 2, double attack 0, strategy hit 0x13.
```
if EV4087 == 0:                                  # 0x505fdc (duel item mode) skips the accumulator
    unit = (mode >> 4) == 1 ? byte[0x497af8 + (mode&1 ? 0xc : 1)] : byte[0x4927f0 + (mode & 1)]
    acc  = &byte[0x4930c8 + unit·4 + (mode & 15)]          # 4 accumulators per unit slot
    if mode & 1: t = acc + 100 − p;  ok = t < 100;  if !ok: t −= 100      # byte arithmetic
    else:        t = acc + p;        ok = t >= 100; if ok:  t −= 100
    if not (mode == 0 and byte[0x492df8] >= 1): acc = t
    if EV4018 == 1: return ok                     # 集气 (deterministic) mode
return Chance2(p, 0)                              # 0x43786b
```
Accumulators are set to EV4017 at battle start (0x4121e2, memset 0x4930c8 × 1000) and for a unit on (re)entry
(0x4277a9). **Chance2 0x43786b(p, m)**: if `m == 2` or EV4077 ≥ 2 (default 2): `chance(p)`. Otherwise the
"pseudo-random" deck: `v = byte[0x508998 + EV4077·52 + cur]`, `cur = cur < 51 ? cur+1 : 0` (cursor byte
0x501bf6 + EV4077); `p = min(p, 100)`; `m == 1 → v >= 100 − p`, `m == 0 → p >= v`. The two 52-byte decks are
refilled at the start of every player phase (0x44ed7f → 0x423490: 104 × `rand(100) + 1`); EV4077 is set to 0 for
the player phase and 1 for the enemy phase unless it is 2 (§7.1).

### 1.5 Damage — CalcDamage 0x43bc5a(A = ecx, D, preview, mode) [C]

`mode`: 0 first strike, 1 counter (`[0x492e04] > 0`), 2 second strike (`obj.strikes > 0`) (0x405e47).
`preview` = 1 for AI/forecast calls (no hit roll, no randomness, no 末日审判).
```
if D[4] == 0xff: return 0
# 斩杀攻击 0x43637b
p = EffQ(A, 0x6e 斩杀攻击, 0x7d, 1, 0)
if p and D.HP <= MaxHP(D)·p/100:  dmg = D.HP;  goto final            # no hit roll, no cap
if (v = Forced(0x15)) (斬首):  dmg = MaxHP(D)·v/100;  goto cap          # 0x436334, §1.13 (shipped v = 100)
v = EffQ(A, 0x16 破甲攻击, 0x1f, 1, 0)
if v: dmg = (byte[0x4cb6bf] == 1) ? v : MaxHP(D)·v/100;  goto cap    # shipped byte = 1 → fixed v; never misses
(VA, VD) = StatPair(A, 0, D, 1, 0)
if not preview and not HitTest(A, D, 1, 0xff): return 0                # miss
dmg = Level(A) + 25                                                     # 0x43bd36 (patched "base 25")
dmg = VA >= VD ? dmg + (VA − VD)/5 : max(SatSub(dmg, (VD − VA)/5), 1)   # /5 at 0x43bd48 / 0x43bd5c
v = EffQ(A, 0x75 疾风攻击, 0x4c, 1, 0)
if v: d = UnitMove(D) − v;  if (int8)d < 0: dmg += dmg·(−d·5)/100        # 0x43f74f = D's effective move
m = Matchup(A, D);  if m != 100: dmg = max(dmg·m/100, 1)                # 0x426737
if famflag3[UnitFamily(A)]:                                             # ranged attacker
    v = EffQ(D, 0x22 减轻远距损伤, 0x45, 1, 0);  if v: dmg = max(dmg − dmg·v/100, 1)    # 0x42a9f7
dmg = Breakthrough(0, D, A, dmg)                                        # 0x411072, §1.12
v = EffQ(A, 0x19 冲锋攻击, 0x5f, 1, 0)
if v and [0x500c48]: dmg += dmg·(v·[0x500c48])/100                      # +v% per tile walked
v = EffQ(D, 0x23 减轻物理损伤, 0x3d, 1, 0);  if v: dmg = max(dmg − dmg·v/100, 1)
if mode == 0: dmg += dmg·(EffQ(A, 0x2c 仇恨攻击, 0x4a, 1, 0)·hits[A.slot])/100   # 0x478f08
else:         if not EffQ(A, 0x48 强化反击, 0x6a, 1, 1): dmg = max(dmg·3 >> 2, 1)    # counters AND 2nd strikes
dmg = Modifiers(A, D, dmg, preview)                                      # 0x412c78
if not preview: dmg = Doom(A, dmg, person(D))                           # 0x42423d 末日审判
cap:   c = EffQ(D, 0x56 限制伤害, 0x72, 1, 0);  if c and c < dmg: dmg = c   # 0x43c3f0
final: if preview and mode==2(必杀): dmg += dmg·50/100                    # 0x406b0e
       return min(dmg, D.HP)       # (ecx returns the value before this cap; used by MP防御)
```
* `Level(A)` = person level byte +0x2c (0x412674). `hits[slot]` = byte 0x508a00[slot]: +1 (≤ 255) for every strike
  aimed at the unit, **misses included** (0x406080, reached for every target); cleared for the opposing side's
  slots at each turn start (0x420952, §7.2). **The counter read is the
  attacker's own** (`[ebp+8]` of 0x478f08 = A): 仇恨攻击 grows with the hits A has taken.
* **Matchup 0x426737(D, A)** = `max(byte[0x4d1a80 + fam(A)·40 + fam(D)] + EffQ(A, 0x76 绝对克制, 0x4e, 1, 0)
  − EffQ(D, 0x76, 0x4e, 1, 0), 0)`. **Row = attacker family, column = defender family** (stdcall: the first
  argument is the last push; the table gives 步兵→弓兵 150, 弓兵→骑兵 130, 骑兵→步兵 110, 步兵→骑兵 60 — the CCZ
  triangle). Note: docs/rules.md §1.4 currently states the transposed reading; this one is correct.
  Table 40×40 at 0x4d1a80 (file 0xA3280 = System.ini UserXK).
* **Modifiers 0x412c78(A, D, dmg, preview)**:
  ```
  dmg = DirBonus(A, D, dmg, 0)                 # 0x408db1, below
  if preview: return dmg
  dmg = Fog(A, D, dmg)                         # 0x41d716
  r = rand(7)
  dmg = r > 2 ? dmg + r − 2 : max(SatSub(dmg, r), 1)     # −0,−1,−2,+1..+4 ("push 7" at 0x412ca0; 0 = no spread)
  ```
* **DirBonus 0x408db1(A, D, x, retExtra)** — also used on the hit rate:
  ```
  extra = 0
  if EV4066 != 0:                              # 0x505f88 攻击方向伤害加成, default 0
      (ax, ay) = A's tile, or the AI virtual tile word 0x48e8c2 when A is AI-controlled and it is set
      f = D.facing (+0xf)
      if f even:  c = ay == D.y ? 1 : (D.y > ay ? (f == 2 ? 2 : 0) : (f == 0 ? 2 : 0))
      else:       c = ax == D.x ? 1 : (D.x > ax ? (f == 1 ? 2 : 0) : (f == 3 ? 2 : 0))
      e = x·(c·5)/100;  x += e;  extra += e    # front 0, flank +5 %, rear +10 %
  if side(D) != 1 and mode == 1 (围攻): e = x·5/100; x += e; extra += e
  return retExtra ? extra : x
  ```
  Facing: 0 = up (−y), 1 = right, 2 = down, 3 = left (a D facing up is hit "from behind" by an attacker with a
  larger y). The defender does not turn before the blow (0x435829 turns only the attacker; the animation
  0x4526e7 restores the defender's facing).
* **Fog 0x41d716(D, dmg)** (ecx = A): if EV4087 == 0 and byte[0x501bd2] ≥ 2 and `grp(A) != grp(D)`
  (grp = 0x4088b4: slot < 60 or `+5 == 5` → 1, else 2): `mask = grp(D) == 2 ? 0x0d : 0x0e`; if
  `byte[0x4934b0 + D.x + D.y·W] & mask == 0` → `dmg = dmg·80/100`. (0x4934b0 is a per-cell visibility map,
  0x501bd2 the battle's visibility mode [G: fog of war].)
* **Doom 0x42423d (末日审判)**: if `EffQ(A, 0x6f 末日审判, 0x48, 3, 0) & 1`:
  `dmg += MaxHP(D)·(deck0[c]/20 + 10)/100` with its own deck cursor 0x501bf5 (0x455e25, deck 0) — 10..15 % of the
  defender's max HP (patch bytes 0x424262 = 20, 0x42426a = 10).

### 1.6 Critical hit [C]

Computed in 0x405de1 **for target index 0 only, when that target's HP > 0** (before damage; a missed strike can
"crit" for 0 and still sets the flag):
```
if mode == 2 (必杀): rate = 100
else:
    rate = CritRate()                                   # 0x40c7d8
    if rate <= 100:
        if not Roll(rate, 2): skip
        rate += 100
    if EffQ(D, 0x30 防御致命攻击, 0x41, 1, 1) and not EffQ(A, 0x70 忽视暴防, 0x34, 1, 1):   # 0x42aa2a
        dmg[0] = 0;  obj.crit = 1;  skip bonus
dmg[0] += dmg[0]·(rate >> 1)/100                        # 必杀 +50 %; rolled crit +50 % + rate/2 %
obj.crit = 1
```
**CritRate 0x40c7d8** = `Curve(VD, VA)` with `(VA, VD) = StatPair(A, 4, D, 4, 0)` (士气 vs 士气), plus 100 if
`EffQ(A, 0x33 致命一击, 0x31, 3, 0) & 1` (0x44f9a9). **Curve 0x405d0a(d, a)** (unsigned):
```
a >= 3d → 100;   a > 2d → 20 + (a − 2d)·80/d;   a >= d → 2 + (a − d)·18/d;   else 1
```
After the animation, a crit shows the person's critical line with `chance(25)` (0x452791) — an RNG draw.

### 1.7 Second strike (double attack) [C]

**Again 0x4060d2** (sets obj+1 = primary target, clears obj.crit):
```
if EffQ(A, 0x35 双枪攻击, 0x42, 1, 0) and obj.strikes < 1: return 1      # guaranteed, no roll
if [0x492e04] > 0: return 0                                             # never during counters
if obj.strikes > 1: return 0
return Roll(DoubleRate(), 0)
```
**DoubleRate 0x405cb9** = 100 if `EffQ(A, 0x34 主动连击, 0x42, 1, 1)`, else `Curve(VD, VA)` with
`(VA, VD) = StatPair(A, 3, D, 3, 0)` (爆发). The loop in 1.2 allows at most 2 strikes but calls Again() after
the second strike too (one more roll is consumed). The second strike computes damage with mode 2 (×3/4 unless
强化反击) and the target's `EffQ(T, 0x31 防御二次攻击, 0x41, 1, 1)` zeroes it (0x405f30). Knock-back of the
**primary** target is followed by 0x4111a5 only when the attack has area targets: if the primary target is still in
the attacker's range the area list is rebuilt around its new cell (0x4364c7), otherwise obj.strikes = 1, which
cancels the second strike (Again() still rolls). A single-target attack keeps striking the pushed unit.

### 1.8 Per-target damage post-processing (0x405de1, after CalcDamage and the crit) [C]

For each target i with `dmg = obj.dmg[i] > 0` (T = target unit, `raw` = CalcDamage's uncapped value):
```
mp = T.MP
if any EffQ(T, 0xa2+j MP辅助, 0x7e, 3, 0), j = 0..4 (0x414d70 → 50):
    loss = mp > MaxMP(T)·50/100 ? 1 : 0;   obj.mpdmg[i] = loss;   mp −= loss
if EffQ(T, 0x32 MP防御, 0x44, 1, 1) and mp > 0:                         # MP shield (0x4210ac)
    x = dmg <= mp ? (dmg < T.HP ? dmg : min(raw, mp)) : mp
    if EffQ(T, 0x32, 0x44, 1, 1): x = min(x, T.HP)                        # 僵尸大法 patch 0x41ab00
    obj.mpdmg[i] += x;  obj.dmg[i] = 0
elif GoldShield(i):                                                      # 0x42128a 金钱防御
    pass
else: obj.dmg[i] = min(dmg, T.HP)
```
**GoldShield 0x42128a**: if `EffQ(T, 0x6b 金钱防御, 0x5b, 1, 1)` and `dmg > 1`: if T is player-controlled
(`T+0xe == 7`): cost `(dmg − 1)·10` gold; if gold (GS 0x4b077c) ≥ cost, pay and set `dmg = 1`, else no effect.
Other units: `dmg = 1` for free.

Then per target: `obj.exp = max(obj.exp, AttackExp(i))` (0x4037a3), `obj.wexp += WeaponExp(i)` (0x403870),
`obj.aexp[i] = ArmourExp(i)` (0x403a8a) — formulas in §5. `hits[T.slot] += 1` (≤ 255). 0x42a96d (功勋 §5).

**转移伤害 0x418205** (before Apply, skipped when A has 斩杀攻击): for each original target T with
`v = EffQ(T, 0x57 转移伤害, 0x73, 1, 0)`: R = the unit with the lowest current HP among T's enemies inside T's
attack range (0x4091f4(T, 2, 0x50, 0, 0); first minimum in list order; never the attacker A); if R exists and
`obj.dmg[i] >= v`: `m = obj.dmg[i]·v/100`; `obj.dmg[i] −= m`; `m = min(m, R.HP)`; if R is already a target j:
`obj.dmg[j] = min(obj.dmg[j] + m, R.HP)`, else R is appended with damage m.

### 1.9 Applying a strike — 0x405966, then 0x406b3c after the exchange [C]

For each target T (index i), with `dmg`, `mpdmg`, mode byte `[0x500c44]` (0 for attacks; 1 during a mine
detonation 0x42d2d3, 2 during a thrown attack item 0x404b46, §4.4):
```
if [0x500c44] < 1:
  if dmg == 0 and mpdmg == 0:                                    # miss
    (EV 4093 modern-war maps: miss effect 0x42b7da)
    猛击/盾反 0x422026(A, T):                                     # these trigger on a MISS
        v = EffQ(A, 0x72 猛击, 0x4a, 1, 0):  if v: Smash(T, from A, mask 8, min(v,100))
        if T alive: w = EffQ(T, 0x73 盾反, 0x4a, 1, 0): if w: Smash(A, from T, mask 2, min(w,100))
  else:                                                          # hit
    V = T;  if k == 0 and EffQ(T, 0x12 反弹异常攻击, 0x2a, 1, 1): V = A        # 0x4220b0 (not for 武将技)
    Debuffs(k, V)        # 0x40399f: for s = 0..5: if Forced(8+s) or EffQ(A, 6+s 破坏攻击..破坏移动, tbl1[s], 1, 1):
                         #   Buff(V, s, down)   (0x409821(s,0); tbl1 = 0x437e19 = 34 24 54 2d 2c 5f)
    RandomBreak(k, V)    # 0x472d6e: n = Forced(14 折磨) or else EffQ(A, 0xc 随机破坏能力, 0x5e, 1, 0)
                         #   n = min(n, 6); pick n distinct s by rand(6) (redraw duplicates); Buff(V, s, down)
    Statuses(k, V)       # 0x4039f6: for s = 0..3 (麻痹, 禁咒, 混乱, 中毒): if Forced(15+s) → apply;
                         #   else v = EffQ(A, 0xd+s 麻痹攻击..中毒攻击, tbl2[s], 1, s==2 ? 0 : 1)
                         #   (tbl2 = 0x437e1f = 2d 26 2b 2c); if v and Chance2(v, 0): apply
                         #   apply = SetStatus(V, 2 << s)  (0x4240d6, §3)
    if Forced(19 鬼门) or EffQ(A, 0x11 随机异常状态, 0x1d, 1, 1):        # 0x42119b(V, A's person)
        L = A's weapon level (person +0x2f)
        for (mul, add, mask) in (5,15,4) (4,8,0x10) (3,3,2) (2,0,8):  if chance(L·mul + add): SetStatus(V, mask)
SP gain of T = SpGain(T, dmg)                                    # 0x410fc3, §1.13
display; if i == 0: [0x48e8bd] += dmg
T.HP −= dmg (0x43f6db);  T.MP −= mpdmg (0x43f715)
armour EXP of T applied (0x4082dd(1, aexp))
if dmg > 0 and T alive:
    AutoUse(T)                                                   # 0x416442 自动使用 (§4)
    if [0x500c44] < 1 and Breakthrough(1, T, A) and i == 0: knocked = 1   # 0x411072 (every target may be pushed)
if knocked and i != 0 and i is the last target: 0x4111a5(A)       # §1.7
clear unit flag bit 0x20 (0x406690)
```
**Smash 0x422076 → 0x4220d3(victim, source, mask, p)**: if the victim has 反弹异常攻击 the status goes to the
source instead (mask cleared for the victim); then, if the victim's HP > 0: `d = HP·p/100`, SetStatus(victim, mask),
`HP −= d` (no roll). So when a blow misses, 猛击 still confuses the target (mask 8) and takes `v` % of its current
HP, and the target's 盾反 paralyses the attacker and takes `w` % of the attacker's current HP. The call order inside
the hit branch is Debuffs 0x40399f, RandomBreak 0x472d6e, Statuses 0x4039f6, then 0x42119b (0x405a24..0x405a6b).

**PostExchange 0x406b3c** (once per Exchange; the first block is skipped when `[0x500c44] == 2`):
```
(r, hpAfter) = Reflect()                       # 0x440e06: r = Σ_i dmg[i]·EffQ(T_i, 0x13 反弹伤害, 0x42, 1, 0)/100
                                               #   dmg[] = the LAST strike's values (0x405de1 clears them per strike)
                                               #   if A.HP <= r: r = A.HP − 1  (never lethal)
if (p = Forced(0x14 嗜血)) or (p = EffQ(A, 0x14 吸血攻击, 0x65, 1, 0)):   # shipped 嗜血 value 100
    heal = [0x48e8bd]·min(p,100)/100;  newHP = min(heal + hpAfter, MaxHP(A))   # 0x48e8bd: primary target, all strikes
else newHP = hpAfter
if EffQ(A, 0x15 吸收金钱, 0x5b, 1, 1):          # gold ± primary-target damage
    target+5 >= 2 → gold = min(gold + [0x48e8bd], 999999); else gold = SatSub(gold, [0x48e8bd])
if HP changed: A.HP = newHP
# --- always:
SetExp(A, A.exp + obj.exp)                     # 0x4088cd (level-ups, §5)
weapon EXP: 0x4082dd(0, obj.wexp)
[0x48e8bd] = 0;  [0x500c48] = 0
```

### 1.10 Counter-attack, preemption and follow-ups [C]

**Counter 0x406453** (after Exchange in normal mode; T = primary target, X = the striker):
```
d = [0x492e04]
if d > 1 or (d == 1 and not EffQ(T, 0x25 反击后反击, 0x30, 1, 1)): d = 0; return
if T dead or confused (0x426b33): d = 0; return
if EffQ(X, 0x26 无反击攻击, 0x34, 1, 1): d = 0; return
range = (v = EffQ(T, 0x5f 策略反击, 0x79, 1, 0)) and CanCast(T, v−1) ? StrategyRange(v−1) (0x401dff)
                                                                     : AttackRange(T) (0x43f8c0)
if X's tile not in range (0x412b30): d = 0; return
d += 1;  [0x501bfa] = d
if v and CastAt(T, X, v−1) (0x4179b4 → dispatcher 0x425627): d = 0     # strategy counter
else Exchange(T, X)                       # damage mode 1 → ×3/4 unless 强化反击; 2nd strike only via 双枪攻击
```
So a counter happens whether the blow hit or missed, only from the primary target of an area attack, and the
original attacker may counter back only with 反击后反击 (depth 2 stops). Attack mode 1 (围攻) and 2 (必杀) skip the
counter. `CanCast 0x417af6(u, s)`: not 禁咒 and `MP >= MPCost(u, s)` (0x417b27).

**Preempt 0x410f1c(T, A)** (before the exchange, normal attacks only):
```
if T confused: return 0
v = EffQ(T, 0x5e 策略先手, 0x78, 1, 0)
if v and A within StrategyRange(T, v−1) and CastAt(T, A, v−1) and A dead-or-confused: return 0xff
if EffQ(T, 0x1a 先手攻击, 0x29, 1, 1) and A within AttackRange(T): turn T to A; return 1
return 0
```
With `1` the exchange is `Exchange(T, A)`: T strikes normally, then A's blow comes as T's counter (mode 1: ×3/4,
a second strike only through 双枪攻击), and T counters again only with 反击后反击.

**StrategyPursuit 0x417983** (after every strike): `v = EffQ(X, 0x5d 策略追击, 0x77, 1, 0)`; if v: try
`CastAt(X, target, v−1)`; **if the strategy is not cast, X makes one more physical strike** (0x4527fe; the strike
counter is not advanced).

**先制攻击 0x428a53** (move interrupt): when a unit steps onto a cell (mode 4), every on-map hostile unit H alive
with `v = EffQ(H, 0x52 先制攻击, 0x51, 0, 0) > H[+0x22]` whose attack range covers the cell (0x428b1f) attacks the
mover: `H[+0x22] += 1`, `Attack(H, mover)` (0x43db23, checkPre 1). If the mover dies the move stops (returns −1).

**FollowUp 0x42c144(A, T)**: `Fervent(A, T)` (0x4363f1); if it did nothing and T is dead → `Lead(A)` (0x4212f1).
* **奋战 0x4363f1**: requires A alive and not confused, and `Forced(0x17 血戰)` or `EffQ(A, 0x17 奋战攻击, 0x36, 1, 0)`.
  List = enemies in A's attack range ordered by 0x419a67 (first those a preview CalcDamage would kill, then the
  rest, each group in range-scan order). For each unit ≠ T: `Exchange(A, u)`; stop after 2 (patch byte 0x436479;
  unlimited for 血戰) or when A is dead/confused.
* **引导 0x4212f1**: if `EffQ(A, 0x18 引导攻击, 0x36, 1, 1)`: same list; `Exchange(A, u)` for each, stop after 2
  (patch byte 0x421340) or as soon as one survives.
* **大杀四方** (0x4290c8, on every kill in AttackExp): if `v = EffQ(A, 0x40 大杀四方, 0x54, 1, 0)` and
  `A[+0x24] < v` (byte compare; bit 7 is cleared again when it is consumed): `A[+0x24] |= 0x80` (act again after
  the action, 0x41b508: bit cleared, `+0x24 += 1`, acted flags cleared — skills.md §5.6). The kill also adds 1 to
  the person's kill count (0x426ba0) when the attacker is a player unit.

**SupportAttacks 0x4223a9(T, A)** (end of a player/AI attack command, 0x43db23 / 0x43aaf7 / 0x41d693): two passes
of 0x438ebd(kind, victim, other) — kind 0: victim T, other A; kind 1: victim A, other T. Nothing if the victim is
dead or EV4087 ≠ 0. Joiners = every unit U ≠ other, state 2, on other's side (0x42e2b7 with 0x42e2ed, i.e. ignoring
EV4019), not dead/confused, with `v = EffQ(U, kind ? 0x71 戮力同心 : 0x3b 同仇敌忾, kind ? 0x58 : 0x1f, 1, 0)`,
`U[+0x23] < v`, and the victim inside U's attack range (0x4091f4(U, 2, 0x50, 2, 0)); slot order. Then 0x41058d:
attack mode word = 0; for each joiner: face, `U[+0x23] += 1`, Preempt(victim, U), `Exchange(U, victim)` (or the
preempted order; a normal exchange with counters), stop as soon as the victim is dead. So 同仇敌忾 = allies of the
attacker pile on the defender, 戮力同心 = allies of the defender strike back at the attacker. (`U+0x23` counts these
support attacks; where it is reset was not traced [G: per turn].)

### 1.11 Attack range and area [C]

**AttackRange 0x43f8c0(u)** returns 4 shape codes (bytes, 0xff = none); the range is their union:
```
c0 = 0xff;  if mode == 2 and u is the acting unit ([0x500ac0]) and k: c0 = skill[k].+0xc
c1 = item value of 远距攻击 (it 0x32) if the person has it (0x43c794(0x32, 0, 5)), else 0xff
c2 = 0x14 if the person has item effect 0x2c;  c3 = 0x0c if item effect 0x54
c0 = Upgrade(u, c0 == 0xff ? class.byte1 : c0)          # 0x417a38: class byte 1 (0x44f9a0)
     # Upgrade 0x41ce8c: if EffQ(u, 0x5b 远距攻击-攻击, 0x76, 3, 0) & 1: c0 = byte[0x41ceab + c0]
if u has 禁咒 (0x423fe8(4)): return (0x0b, ff, ff, ff)                   # no physical attack
if AdjacentPin(u) == 0 (0x42bb57: an orthogonally adjacent enemy has EffQ(0x60 左天羅右地網, 0x7a, 1, 1)):
    return c0 == 0x0b ? (0x0b, ff, ff, ff) : (0, 0, 0, 0)                  # melee cross only
return (c0, c1, c2, c3)
```
Upgrade map 0x41ceab (code → code): 0→1 1→6 2→3 3→4 4→18 5→19 6→12 7→8 8→18 9→31 10→10 11→0 12→13 13→33 14→15
15→22 16→17 17→18 18→37 19→12 20→12 21→22 22→34 23→1 24→32 25→29 26→3 27→28 28→29 29→35 30→31 31→3 32→36.

**Shapes** (0x436511 → table 0x4d1400; code 10 = whole map 0x4366f0, 11 = none, codes > 11 use entry code−2;
only byte 0 may be code 0). Each entry lists (a, b) offsets in one quadrant; 0x436611 mirrors them:
`a, b != 0 → (±a, ±b)`; one of them 0 → `r = max(a, b)`, cells `(±r, 0), (0, ±r)`. The unit's own cell is
never included; cells off the map are dropped (0x437aff).

| code | name (editor) | quadrant offsets |
|---|---|---|
| 0 | 十字 | (1,0) |
| 1 | 九宫 | (1,0) (1,1) |
| 2 | 弓兵 | (2,0) (1,1) |
| 3 | 弩兵 | (2,0) (3,0) (1,1) (2,1) (1,2) |
| 4 | 连弩兵 | (2,0) (3,0) (4,0) (1,1) (2,1) (3,1) (1,2) (2,2) (1,3) |
| 5 | 爆炎 | (1,0) (2,0) |
| 6 | 无羽箭 | (1,0) (1,1) (2,0) |
| 7 | 轻炮车 | (4,0) (3,1) (2,2) (1,3) |
| 8 | 霹雳车 | (4,0) (5,0) (3,1) (4,1) (2,2) (3,2) (1,3) (2,3) (1,4) |
| 9 | 弓骑 | (2,0) |
| 10 | 全屏 | every cell |
| 11 | 无攻击 | — |
| 12 | 大无羽箭 | (1,0) (1,1) (2,0) (1,2) (2,1) (3,0) |
| 13 | 大大无羽箭 | (1,0) (2,0) (3,0) (4,0) (1,1) (2,1) (3,1) (1,2) (2,2) (1,3) |
| 14 | 特殊 | (3,0) (3,1) (1,3) |
| 15 | 大方块 | (3,0) (3,1) (3,2) (1,3) (2,3) |
| 16 | 刺客1 | (3,0) (2,1) (1,2) |
| 17 | 刺客2 | (3,0) (4,0) (2,1) (3,1) (1,2) (2,2) (1,3) |
| 18 | 刺客3 | (3,0) (4,0) (5,0) (2,1) (3,1) (4,1) (1,2) (2,2) (3,2) (1,3) (2,3) (1,4) |
| 19 | 大爆炎 | (1,0) (2,0) (3,0) |
| 20 | 方块1 | (1,0) (1,1) (2,0) (1,2) (2,1) |
| 21 | 方块2 | (4,0) (4,1) (4,2) (3,3) (1,4) (2,4) |
| 22 | 方块3 | (3,0) (4,0) (3,1) (4,1) (3,2) (4,2) (1,3) (2,3) (3,3) (1,4) (2,4) |
| 23 | 交叉1 | (1,1) |
| 24 | 交叉2 | (1,1) (2,2) |
| 25 | 蜻蜓 | (2,0) (2,1) (1,2) |
| 26 | 云霞 | (2,0) (1,1) (2,1) (1,2) |
| 27 | 藤弓 | (2,2) |
| 28 | 弩 | (2,0) (2,2) |
| 29 | 斩月 | (2,0) (2,1) (1,2) (2,2) |
| 30 | 四方竹弓 | (3,0) |
| 31 | 南蛮弩 | (2,0) (3,0) |
| 32 | 12格 | (1,0) (1,1) (2,2) |
| 33 | — | (1..5,0) (1..4,1) (1..3,2) (1,3) (2,3) (1,4) |
| 34 | — | (3..5,0) (3..5,1) (3..5,2) (1..4,3) (1..3,4) (1,5) (2,5) |
| 35 | — | (2,0) (3,0) (2,1) (3,1) (1,2) (2,2) (1,3) |
| 36 | — | (1,0) (2,0) (1,1) (2,1) (1,2) (2,2) |
| 37 | — | (3..5,0) (2..5,1) (1..4,2) (1..3,3) (1,4) (2,4) (1,5) |

Units collected by a range scan (list 0x4ac748) are taken in shape-list order, each entry giving 4 cells in the
order `(+a,−b) (−a,−b) (−a,+b) (+a,+b)` or `(+r,0) (−r,0) (0,−r) (0,+r)`; filter (0x437aff): HP > 0 and side
mode 0 = hostile only, 1 = same side only, 2 = all.

**Area of a physical attack** (targets besides the primary one): area code = (mode 2 and `skill[k].+0xd`) or the
person's 穿透攻击 item value (it 0x33, 0x45d3e8) or class table 0x407881[class] (重炮车/霹雳车 1, 標槍兵 family 4,
驯獸师 4, 猛獸 1, 特種兵 7, 蛮骑兵 1, 陷阵营 4, 木人 2, else 0), then upgraded by 0x45d316 when EV4087 == 0 and
`EffQ(u, 0xa7 辅助穿透-攻击, 0x57, 3, 0) & 1` (0x42518f) via table 0x45d343 (0→1 1→2 2→3 3→8 4→7 5→5 6→6 7→5 8→6
9→2 10→10). Targets (0x435ce9, hostile units only, full damage each — no fall-off):

| area | targets |
|---|---|
| 0 | primary only |
| 1 | + 4 orthogonal neighbours of the target |
| 2 | + 8 neighbours |
| 3 | + diamond radius 2 around the target (shape list 0x4d225e) |
| 4 | + 1 cell behind the target (direction sign(T − A), 0x42230e) |
| 5 | + 5 cells behind |
| 6 | + diamond radius 3 (0x4d2288) |
| 7 | + 2 cells behind |
| 8 | + (1,0) (1,1) (2,0) (1,2) (2,1) mirrored (0x4d22fa) |
| 9 | + the 2 cells beside the target perpendicular to the attack (0x4254fa) |
| 10 | + 8 neighbours **of the attacker** |

### 1.12 Knock-back — 突破攻击 (Breakthrough 0x411072(flag, T, A), ecx = dmg) [C]

Applies when `Forced(0x16 驱逐)` (0 in the shipped data) or `EffQ(A, 0x61 突破攻击, 0x35, 1, 1)`; otherwise
`p = EffQ(A, 0x62 加强攻击, 0x35, 0, 0)` gives `dmg += dmg·p/100` (flag 0 only).
```
cell = T + (sign(T.x − A.x), sign(T.y − A.y))        # 0x42230e (A's tile or the AI virtual tile)
canPush = mode != 1 (围攻) and T not dead/confused and cell on map and empty and passable for T (0x45936d < 0xfe)
flag 0 (damage):  canPush ? dmg : dmg + dmg·30/100     # "突破攻击的威力" byte 0x4110c1 = 30
flag 1 (after the hit, T alive): if canPush: move T to cell (animation 0x4594ea, [0x500ad3] = 1), return 1
```

### 1.13 武将技 / 军师技 (必杀) and SP [C]

**SP** = byte 0x501c00[person id] (0..255, saved with the 0x501000 block).
* **Gain when damaged** 0x410fc3(dmg) for the struck unit: nothing if EV4087 ≠ 0 or EV4059 == 1;
  `g = dmg · (EffQ(T, 0x24 集气加倍, 0x41, 1, 0) ? 2 : 1)`; `g = T+5 >= 2 ? g/2 : g/4`; `g = max(g, 1)` if dmg > 0;
  AddSP(T, g, 0). **AddSP 0x423930(n, force)**: unless `force`, persons with id > EV4030 (default 200) get nothing;
  `SP = min(SP + n, 255)`.
* Per-turn gain (每回合恢复SP, SP光环) §7; reset to 0 when a unit re-enters unless EV 4095 (0x4277e6).
* **Spend** 0x423910: `SP −= min(SP, skill[k].+0xe)`.

**Skill records** (Data.e5 e5 tail → 0x4a7510 + k·16): name, `+0xc` range code, `+0xd` area code, `+0xe` SP cost,
`+0xf` value. Shipped: 0 重击 (cost 100), 1–27 cost 255; 80–89 军师技 cost 255.

**CanUseSkill 0x4225fb(u)**:
```
if EV4059 != 0: return 0                                   # 禁止必杀
a = byte[0x4d2200 + UnitFamily(u)]                         # 军师技 index of the family, 0 = none
if a: need = skill[a + 0x4f].+0xe
elif u+0xe == 7: return nonzero                            # player-controlled 武将技 user: no SP / seal check here
                                                           #   (value (ecx & ~0xff) + 1; the skill menu checks costs)
else: need = EV4061                                        # default 100
if 禁咒 (0x423fe8(4)): return 0
return SP >= need ? (a ? 2 : 1) : 0
```
**Which 武将技 a person knows** 0x418744(k, person): record k of the table at `[0x500c37]` (= 0x512000, 16 bytes,
saved; filled by script op 0x72 sub 6, skills.md §3.2): `+0xf == family(person)` or one of 5 `(u16 person id,
u8 min level)` entries with that person and `level >= min level`. The AI picks the first k in
1..0x4f known with `SP >= cost` (0x4225a2).

**Using a 武将技** (player menu 5 → 0x423358, AI 0x465fab): mode word = `(k << 8) | 2`; target in AttackRange
(with `skill.+0xc`); message (0x417a96, which for k = 1..6 raises the user's buff s = k−1 (0x409821(s, up)) and for
k = 7 calls 0x429b67(0x57)); `Attack(A, T)` with checkPre 0; FollowUp; SpendSP; mode = 0. Inside the exchange
mode 2 means: hit 100 %, crit always (+50 %), no counter, area/range from the skill, and per-k hooks through
**Forced(K) 0x436334([0x500e9b], K)** = `k == K ? skill[K].+0xf : 0` — a hook fires only when that value ≠ 0:
k 8–13 debuff s = k−8, 14 `min(v,6)` random debuffs, 15–18 status 麻痹/禁咒/混乱/中毒, 19 鬼门 random statuses,
20 嗜血 (heal v %), 21 斬首 (damage = MaxHP·v/100), 22 驱逐 (knock-back), 23 血戰 (奋战 without limit). **With the
shipped Data.e5 only 20 嗜血 (100), 21 斬首 (100) and 23 血戰 (7) have a non-zero value**; 8–19 and 22 behave like
重击 plus the generic 必杀 bonuses (skills.md §3.5).

**军师技** (families with k8 ≠ 0: 0x467c9e, tried first by menu 5): `a = byte[0x4d2200 + fam]` (1..9),
handler table 0x467d1d[a−1]: 1 重生 0x451195, 2 歷精圖治 0x4510ba, 3 八陣圖 0x451129, 4 巫蠱 0x42ac0a, 5 鼓舞
0x41dbcd, 6 賣慘 0x422c4a, 7 濟世 0x43bf2a, 8 超度 0x436d8b, 9 再戰 0x410339; then SpendSP(a + 0x4f). The
handlers apply area effects through 0x422caf (range code 12 for the player side, 10 = whole map for the enemy
side, kind/amount packed in the argument); their effects are tabulated in skills.md §3.4 (文官必杀, ids 80–89; id 89
？？ picks a random handler with `rand(8)`).

### 1.14 围攻 (surround attack) [C]

Menu 6 → 0x41d693; AI 0x43aaf7 when the attacker is in one of the 8 cells around the target and its range code
is not 2/3/4. Participants 0x405bf2: units in the 8 neighbour cells of the target (order up, right, down, left,
diagonals) passing 0x416e53: same side as the attacker (0x404fcb), **family k7 byte == 0**, AI units only if their
SP < EV4061, unit flag +0xd bit 1 clear, not confused, and their range shape class (0x40ae26) fits the cell
(orthogonal/diagonal). **Every family has k7 = 1 in the shipped table, so nobody qualifies and the command always
answers 不能围攻该部队.** If it ran (0x417c67): mode 1; the attacker, then each participant, attack the target
(`0x417bf2`, which also checks 先手攻击); no counters until the end, then one counter against the main attacker;
damage +5 % vs non-player-side targets (DirBonus), no knock-back (+30 % instead), EXP ×2 (0x403d5a, §5).

### 1.15 Order of random draws in one exchange [C]

Every `Roll`/`Chance2` below draws `rand(100)` from the LCG in the default mode (EV4077 = 2) and nothing in the
deck / 集气 modes; 末日审判 always uses its own deck cursor (no LCG draw). Per strike:
1. Compute 0x405de1, for each target in list order: HitTest (1 or 2 rolls; none for 斩杀 / 斩首 / 破甲 and in
   preview), then `rand(7)` if it hit; after target 0, the critical Roll (not for 必杀 or rate > 100).
2. Animation 0x4526e7: if the crit flag is set and byte 0x501a76 == 0: `chance(25)`, and on success the line
   picker 0x40c099 (generic lines draw `rand(3)`, memory.md §3).
3. Apply 0x405966, for each target: on a hit `rand(6)` draws of 随机破坏能力 / 折磨, then the status `Chance2`
   rolls (only for effects present), then 鬼门 / 随机异常状态 `chance` ×4; on a miss nothing.
4. StrategyPursuit: the follow-up strategy's own draws (§2), or another full strike.
5. Again(): one Roll unless 双枪攻击 decides it or a counter is running.
Then the counter exchange (same order), then FollowUp exchanges.

## 2. Strategies

All VAs are `orig/Ekd5.exe`. Confidence: **[C]** confirmed in disassembly, **[D]** mod docs / data only,
**[G]** guess. Helper notation used below (all [C]):

| notation | function | meaning |
|---|---|---|
| `pct(p, v)` | 0x425ad9 | `v * p / 100`, unsigned 32-bit, truncating |
| `satsub(a, b)` | 0x47fa9e | `a - b if b < a else 0` |
| `addcap(a, b, cap)` | 0x47fa89 | `min(a + b, cap)` (signed compare) |
| `rand(n)` | 0x47fb13 | LCG `s = s*0x41c64e6d + 0x3039` (seed 0x48ecd4), `r = (s >> 16) & 0x7fff`, returns `r % n` (`n < 2` → 0) |
| `chance(p)` | 0x47fb32 | `rand(100) < p` |
| `roll(p, mode)` | 0x43786b | `chance(p)` when EV4077 ≥ 2 (default 2) or mode == 2; else the pseudo-random deck (§2.6.3) |
| `effq(u; a, b, c, d)` | 0x4101d9 | effect query on unit `u` with the call's four arguments in order (catalogue: docs/skills.md) |
| `effq2(u; a, b, c, d)` | 0x42518f | second effect-query entry (bitmask-style results) |
| `stat_pair(A, i, B, j, noTerrain)` | 0x40d2ab | returns (A's battle stat i, B's battle stat j), each = buffed stat (0x414ccb) → 0x423ced → 0x416a38 opponent modifiers → `× terrain% / 100` unless `noTerrain`. §1.3. Stat index: 0 攻击 1 防御 2 精神 3 爆发 4 士气 |
| `terrain_pct(u)` | 0x43f7b8(0x1e) → EDX | class-family terrain effect at the unit's tile (§6.3) |

Unit fields used here (0x30-byte record at 0x4a7b20 + 0x30·idx, getter 0x4061f9): +0 person id (u16), +4 unit
index, +5 side byte (0 我军, 1 友军, 2 敌军, 3 援军; +3 while converted), +6/+7 x/y, +0xc state (2 = on the field),
+0xd action flags (bits 1|2 = has acted), +0xe control (7 = player-controlled), +0xf facing, +0x10 HP (u32),
+0x14 MP (u16), +0x18..+0x1d buff levels, +0x1e status byte. `side(u)` = 0x406710: table 0x40672d[u+5] =
{0→1, 1→1, 2→0, 3→0 (2 if EV4053 援军和敌军对攻), 4→2, 5→1, 6→1}; equal `side()` = same camp.

> Anchor corrections: `0x425ad0` is a generic "byte +0xe" getter — MP cost when ECX is a strategy record, the
> control byte when ECX is a unit. `0x4224a8` belongs to the consumable-item path (0x4224d4), not strategies.

### 2.1 Data

**Strategy record** — Data.e5 entry 5, 144 × 97 bytes, parsed by 0x40d737 (loop 0x41b830) into 144 × 0x61 at
0x4a3e77 (getter 0x484002: `0x4a3e77 + id*0x61`). The 1552 bytes after the 144 records are copied to 0x4a7510. [C]

| mem off | file off | meaning |
|---|---|---|
| +0x00 | 0x00 | name (10 bytes GBK, +0x0a = 0) |
| +0x0b | 0x0c | target side: 0 enemy, 1 ally, 2 none (weather) — getter 0x425ac7 |
| +0x0c | 0x0d | cast range code (§2.5.1) — getter 0x418c90 |
| +0x0d | 0x0e | area code (§2.5.2) — getter 0x484e27 |
| +0x0e | 0x0f | MP cost (getter 0x425ad0); MP-recovery strategies also use it as the amount restored |
| +0x0f | 0x0b | effect type (getter 0x44270c); names 0x48bfe8, 9-byte records: 0 攻击(火) 1 攻击(水) 2 攻击(地) 3 攻击(风) 4 攻击 5 吸收HP 6 吸收MP 7 能力下降 8 防御下降 9 敏捷下降 10 士气下降 11 能力上升 12 防御上升 13 敏捷上升 14 士气上升 15 混乱 16 中毒 17 麻痹 18 禁咒 19 恢复HP 20 恢复MP 21 恢复状态 22 再次行动 23 气候变化 24 谜 25 四神 26 全部上升 27 移动上升 28 全部下降 29 连续移动 30 生命交换 31 经验加倍 32 连续攻击 33 控制敌军 34 以火阻敌 35 建造鹿砦 36 诱敌深入 37 瞬间移动 38 攻击(雷) 39 苌弘碧血 40 召唤大法 41 交换位置 42 兵力投送 43 附加技能 |
| +0x10 | 0x10 | animation group |
| +0x11.. | 0x11.. | 80 bytes: learn level per class (getter 0x4845b2: `rec[0x11 + class]`, 0 = never) |

**Extension tables** (System.ini keys; 10 × u8[0x90] from 0x4d14e0, indexed by strategy id) [C addresses, D names]:

| VA | key | used by | semantics (verified) |
|---|---|---|---|
| 0x4d14e0 | MgMF | 0x41a10c, 0x41dc78 | bit0: may be imitated/learned through 模仿 (0x41dc78 with `onlyImitable`); bit1: auxiliary "penetration" may widen the area (§2.5.3) |
| 0x4d1570 | MgID | dispatcher 0x425627, 0x43c5df, 0x4226b7 | handler index (§2.4) |
| 0x4d1600 / 0x4d1690 | MgAIYN1 / MgAIYN2 | AI 0x439879 / 0x439881, arena menu 0x46647d | 13 = AI (resp. arena) never uses it — see docs/ai.md |
| 0x4d1720 | MgHit | 0x43b730 | hit code (§2.6) — not a cap in 6.6: ≥5 multiplies |
| 0x4d17b0 | Mg8 | 0x41dc78 | learn-category bitmask (§2.2) |
| 0x4d1840 | MgHurt | 0x43c01d, 0x43c5df, 0x423b0b, 0x426551 | damage coefficient %, 255 = kill (target's current HP); re-used as heal formula selector, weather id, summon id |
| 0x4d18d0 | MgHurtYN | 0x415efa | `< 4` → the strategy computes damage (0 四系, 1 毒麻, 2 八图/撞心, 3 青龙/朱雀); ≥4 none |
| 0x4d1960 | MgMeff | 0x421496 | small animation |
| 0x4d19f0 | MgMcall | 0x425627, 0x421496 | big animation if 100..254 (sets ctx+0x554) |

Family attribute rows used by strategies (0x4d20c0 + 40·k, index = class family 0..39; family = 0x40bf0c:
class ≤ 59 → class/3, 60..79 → class−40, else 40): **attr5 0x4d2188** (attack type: 1 策略系, 2 物理系, 0 both),
**attr6 0x4d21b0** (strategy damage taken %): 步兵 80, 骑兵 80, 西凉骑兵 130, 蠻族兵/驯獸师/特種兵 120, 飛行者 80,
閹兵 50, 井栏 150, 阴阳师 50, 蛮骑兵 130, 陷阵营 150, 木人 150, 土偶 150, all others 100. [C]

**All non-blank strategies** (side/range/area/MP/effect from Data.e5; tables from the exe) [C data dump]:

| id | name | effect | MgID | side | range | area | MP | MgHit | MgHurt | HurtYN | MF | Mg8 | AI1/AI2 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 灼热 | 0 攻击(火) | 0 | 0 | 13 | 0 | 6 | 2 | 70 | 0 | 3 | 1 | 5/5 |
| 1 | 烈火 | 0 攻击(火) | 0 | 0 | 12 | 0 | 10 | 90 | 90 | 0 | 3 | 1 | 5/5 |
| 2 | 火阵 | 0 攻击(火) | 0 | 0 | 13 | 1 | 12 | 90 | 50 | 0 | 3 | 1 | 5/5 |
| 3 | 火龙 | 0 攻击(火) | 0 | 0 | 12 | 2 | 20 | 80 | 70 | 0 | 3 | 1 | 5/13 |
| 4 | 爆焰 | 0 攻击(火) | 0 | 0 | 5 | 5 | 24 | 60 | 90 | 0 | 3 | 65 | 5/5 |
| 5 | 火灵珠 | 0 攻击(火) | 26 | 0 | 12 | 4 | 10 | 70 | 50 | 0 | 3 | 1 | 5/13 |
| 6 | 浊流 | 1 攻击(水) | 0 | 0 | 13 | 0 | 6 | 2 | 70 | 0 | 3 | 1 | 5/5 |
| 7 | 激流 | 1 攻击(水) | 0 | 0 | 12 | 0 | 10 | 90 | 90 | 0 | 3 | 1 | 5/5 |
| 8 | 水阵 | 1 攻击(水) | 0 | 0 | 13 | 1 | 12 | 90 | 50 | 0 | 3 | 1 | 5/5 |
| 9 | 水龙 | 1 攻击(水) | 0 | 0 | 12 | 2 | 20 | 80 | 70 | 0 | 3 | 1 | 5/13 |
| 10 | 海啸 | 1 攻击(水) | 0 | 0 | 11 | 0 | 80 | 3 | 255 | 0 | 0 | 0 | 13/13 |
| 11 | 水灵珠 | 1 攻击(水) | 26 | 0 | 12 | 4 | 10 | 70 | 50 | 0 | 3 | 1 | 5/13 |
| 12 | 旋风 | 3 攻击(风) | 0 | 0 | 13 | 0 | 6 | 2 | 50 | 0 | 3 | 1 | 5/5 |
| 13 | 龙卷 | 3 攻击(风) | 0 | 0 | 13 | 0 | 10 | 90 | 70 | 0 | 3 | 1 | 5/5 |
| 14 | 风阵 | 3 攻击(风) | 0 | 0 | 13 | 2 | 12 | 2 | 40 | 0 | 3 | 1 | 5/5 |
| 15 | 风龙 | 3 攻击(风) | 0 | 0 | 12 | 3 | 20 | 90 | 50 | 0 | 3 | 1 | 5/13 |
| 16 | 砂暴 | 3 攻击(风) | 1 | 0 | 11 | 0 | 100 | 90 | 10 | 0 | 0 | 128 | 13/13 |
| 17 | 风灵珠 | 3 攻击(风) | 26 | 0 | 12 | 4 | 6 | 70 | 40 | 0 | 3 | 1 | 5/13 |
| 18 | 落石 | 2 攻击(地) | 0 | 0 | 13 | 0 | 6 | 2 | 70 | 0 | 3 | 1 | 5/5 |
| 19 | 山岚 | 2 攻击(地) | 0 | 0 | 12 | 0 | 10 | 90 | 90 | 0 | 3 | 1 | 5/5 |
| 20 | 地阵 | 2 攻击(地) | 0 | 0 | 13 | 1 | 12 | 2 | 70 | 0 | 3 | 1 | 5/5 |
| 21 | 地龙 | 2 攻击(地) | 0 | 0 | 12 | 2 | 20 | 80 | 90 | 0 | 3 | 1 | 5/13 |
| 22 | 巨岩 | 2 攻击(地) | 0 | 0 | 12 | 0 | 20 | 2 | 120 | 0 | 3 | 65 | 5/5 |
| 23 | 土灵珠 | 2 攻击(地) | 26 | 0 | 12 | 4 | 10 | 70 | 60 | 0 | 3 | 1 | 5/13 |
| 24 | 落雷 | 38 攻击(雷) | 0 | 0 | 13 | 0 | 12 | 2 | 80 | 0 | 3 | 64 | 5/5 |
| 25 | 狂雷 | 38 攻击(雷) | 0 | 0 | 12 | 0 | 20 | 90 | 100 | 0 | 3 | 64 | 5/5 |
| 26 | 雷阵 | 38 攻击(雷) | 0 | 0 | 13 | 1 | 40 | 90 | 100 | 0 | 3 | 64 | 5/5 |
| 27 | 霹靂 | 38 攻击(雷) | 0 | 0 | 12 | 2 | 80 | 80 | 120 | 0 | 3 | 64 | 5/13 |
| 28 | 帝天狂雷 | 38 攻击(雷) | 0 | 0 | 13 | 0 | 40 | 2 | 150 | 0 | 3 | 64 | 5/5 |
| 29 | 雷灵珠 | 38 攻击(雷) | 26 | 0 | 12 | 4 | 10 | 70 | 70 | 0 | 3 | 64 | 5/13 |
| 30 | 吸血 | 5 吸收HP | 0 | 0 | 12 | 0 | 6 | 80 | 70 | 0 | 3 | 68 | 5/5 |
| 31 | 暈眩 | 4 攻击 | 0 | 0 | 11 | 0 | 150 | 2 | 255 | 0 | 0 | 64 | 13/13 |
| 32 | 換血 | 30 生命交换 | 0 | 0 | 12 | 0 | 12 | 60 | 100 | 4 | 1 | 64 | 5/5 |
| 33 | 连击 | 32 连续攻击 | 34 | 0 | 11 | 0 | 10 | 100 | 100 | 0 | 3 | 64 | 2/13 |
| 34 | 谍报 | 6 吸收MP | 3 | 0 | 12 | 0 | 4 | 90 | 50 | 4 | 3 | 232 | 3/3 |
| 35 | 压迫 | 7 能力下降 | 6 | 0 | 13 | 0 | 8 | 80 | 28 | 4 | 3 | 2 | 14/14 |
| 36 | 大喝 | 7 能力下降 | 6 | 0 | 12 | 1 | 16 | 60 | 28 | 4 | 3 | 2 | 14/14 |
| 37 | 咒骂 | 8 防御下降 | 7 | 0 | 13 | 0 | 8 | 80 | 28 | 4 | 3 | 2 | 14/14 |
| 38 | 威吓 | 8 防御下降 | 7 | 0 | 12 | 1 | 16 | 60 | 28 | 4 | 3 | 2 | 14/14 |
| 39 | 钝兵 | 9 敏捷下降 | 4 | 0 | 13 | 1 | 6 | 90 | 28 | 4 | 3 | 2 | 13/13 |
| 40 | 钝队 | 9 敏捷下降 | 4 | 0 | 12 | 2 | 12 | 80 | 28 | 4 | 3 | 2 | 13/13 |
| 41 | 虚脱 | 10 士气下降 | 5 | 0 | 13 | 1 | 6 | 90 | 28 | 4 | 3 | 2 | 13/13 |
| 42 | 厌战 | 10 士气下降 | 5 | 0 | 12 | 2 | 12 | 80 | 28 | 4 | 3 | 2 | 13/13 |
| 43 | 衰气 | 28 全部下降 | 30 | 0 | 6 | 0 | 30 | 60 | 28 | 4 | 3 | 2 | 13/13 |
| 44 | 谎报 | 15 混乱 | 8 | 0 | 13 | 0 | 10 | 60 | 28 | 4 | 3 | 4 | 4/13 |
| 45 | 谎言 | 15 混乱 | 8 | 0 | 12 | 1 | 20 | 40 | 28 | 4 | 3 | 4 | 4/13 |
| 46 | 毒烟 | 16 中毒 | 9 | 0 | 13 | 0 | 8 | 90 | 70 | 1 | 3 | 4 | 5/5 |
| 47 | 毒雾 | 16 中毒 | 9 | 0 | 12 | 3 | 18 | 80 | 40 | 1 | 3 | 4 | 5/13 |
| 48 | 定身 | 17 麻痹 | 10 | 0 | 13 | 0 | 8 | 80 | 50 | 1 | 3 | 4 | 5/13 |
| 49 | 定军 | 17 麻痹 | 10 | 0 | 12 | 3 | 18 | 60 | 20 | 1 | 3 | 4 | 5/13 |
| 50 | 禁咒 | 18 禁咒 | 11 | 0 | 13 | 0 | 8 | 60 | 28 | 4 | 3 | 4 | 6/13 |
| 51 | 封咒 | 18 禁咒 | 11 | 0 | 12 | 1 | 24 | 40 | 28 | 4 | 3 | 4 | 6/13 |
| 52 | 诱敌 | 36 诱敌深入 | 32 | 0 | 18 | 0 | 15 | 80 | 28 | 4 | 1 | 0 | 13/13 |
| 53 | 反間計 | 33 控制敌军 | 2 | 0 | 13 | 0 | 200 | 80 | 28 | 4 | 0 | 0 | 13/13 |
| 54 | 八阵图 | 24 谜 | 12 | 0 | 13 | 3 | 20 | 100 | 120 | 2 | 3 | 68 | 13/13 |
| 55 | 小補給 | 19 恢复HP | 13 | 1 | 13 | 0 | 6 | 100 | 0 | 4 | 3 | 8 | 7/7 |
| 56 | 大補給 | 19 恢复HP | 13 | 1 | 12 | 0 | 10 | 100 | 28 | 4 | 3 | 8 | 7/7 |
| 57 | 援队 | 19 恢复HP | 13 | 1 | 13 | 1 | 12 | 100 | 0 | 4 | 3 | 8 | 7/13 |
| 58 | 援军 | 19 恢复HP | 13 | 1 | 12 | 2 | 20 | 100 | 28 | 4 | 3 | 8 | 7/13 |
| 59 | 输送 | 19 恢复HP | 13 | 1 | 10 | 0 | 20 | 100 | 28 | 4 | 3 | 8 | 7/7 |
| 60 | 建言 | 20 恢复MP | 14 | 1 | 12 | 0 | 24 | 100 | 28 | 4 | 3 | 8 | 10/13 |
| 61 | 献策 | 20 恢复MP | 14 | 1 | 6 | 0 | 48 | 100 | 28 | 4 | 3 | 8 | 10/13 |
| 62 | 撞心 | 39 苌弘碧血 | 15 | 1 | 13 | 0 | 30 | 100 | 60 | 2 | 3 | 64 | 13/13 |
| 63 | 觉醒 | 21 恢复状态 | 15 | 1 | 13 | 0 | 8 | 1 | 28 | 4 | 3 | 8 | 11/13 |
| 64 | 大觉醒 | 21 恢复状态 | 15 | 1 | 12 | 2 | 18 | 1 | 28 | 4 | 3 | 8 | 11/13 |
| 65 | 奋起 | 11 能力上升 | 19 | 1 | 13 | 0 | 6 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 66 | 鼓舞 | 11 能力上升 | 19 | 1 | 12 | 1 | 15 | 100 | 28 | 4 | 3 | 16 | 13/15 |
| 67 | 坚固 | 12 防御上升 | 20 | 1 | 13 | 0 | 6 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 68 | 强阵 | 12 防御上升 | 20 | 1 | 12 | 1 | 15 | 100 | 28 | 4 | 3 | 16 | 13/15 |
| 69 | 练兵 | 13 敏捷上升 | 17 | 1 | 13 | 1 | 6 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 70 | 练队 | 13 敏捷上升 | 17 | 1 | 12 | 2 | 15 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 71 | 欢声 | 14 士气上升 | 18 | 1 | 13 | 1 | 6 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 72 | 昂扬 | 14 士气上升 | 18 | 1 | 12 | 2 | 15 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 73 | 强行 | 27 移动上升 | 16 | 1 | 12 | 0 | 8 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 74 | 疾行 | 29 连续移动 | 31 | 1 | 11 | 0 | 10 | 2 | 28 | 4 | 3 | 16 | 13/13 |
| 75 | 瞬移 | 37 瞬间移动 | 35 | 1 | 10 | 0 | 25 | 100 | 28 | 4 | 3 | 0 | 13/13 |
| 76 | 移形换影 | 41 交换位置 | 37 | 1 | 12 | 0 | 12 | 100 | 28 | 4 | 1 | 0 | 13/13 |
| 77 | 号令 | 42 兵力投送 | 38 | 1 | 13 | 0 | 15 | 100 | 28 | 4 | 1 | 0 | 13/13 |
| 83 | 精进 | 31 经验加倍 | 33 | 1 | 13 | 0 | 8 | 100 | 28 | 4 | 3 | 16 | 13/13 |
| 84 | 气合 | 11 能力上升 | 23 | 1 | 11 | 0 | 3 | 2 | 28 | 4 | 3 | 16 | 13/13 |
| 85 | 霸气 | 26 全部上升 | 25 | 1 | 11 | 0 | 10 | 2 | 28 | 4 | 3 | 16 | 13/13 |
| 86 | 冥想 | 20 恢复MP | 24 | 1 | 11 | 0 | 0 | 2 | 28 | 4 | 3 | 72 | 13/13 |
| 89 | 回归 | 22 再次行动 | 21 | 1 | 6 | 0 | 45 | 100 | 28 | 4 | 0 | 0 | 12/13 |
| 94 | 纵火 | 34 以火阻敌 | 27 | 1 | 6 | 0 | 20 | 100 | 28 | 4 | 1 | 64 | 13/13 |
| 95 | 修筑 | 35 建造鹿砦 | 27 | 1 | 6 | 0 | 10 | 100 | 28 | 4 | 1 | 64 | 13/13 |
| 96 | 召喚孔融 | 40 召唤大法 | 36 | 0 | 1 | 1 | 10 | 100 | 89 | 4 | 0 | 0 | 13/13 |
| 97 | 召喚毒蠍 | 40 召唤大法 | 36 | 0 | 1 | 1 | 10 | 100 | 92 | 4 | 0 | 0 | 13/13 |
| 100 | 哼哈之術 | 15 混乱 | 8 | 0 | 6 | 0 | 0 | 70 | 40 | 1 | 0 | 0 | 13/13 |
| 136 | 豪雨 | 23 气候变化 | 22 | 2 | 11 | 0 | 18 | 2 | 0 | 4 | 3 | 32 | 13/13 |
| 137 | 晴明 | 23 气候变化 | 22 | 2 | 11 | 0 | 18 | 2 | 1 | 4 | 3 | 32 | 13/13 |
| 138 | 昙天 | 23 气候变化 | 22 | 2 | 11 | 0 | 18 | 2 | 2 | 4 | 3 | 32 | 13/13 |
| 140 | 青龙出海 | 25 四神 | 26 | 0 | 12 | 0 | 40 | 2 | 70 | 3 | 3 | 128 | 13/13 |
| 141 | 朱雀翔天 | 25 四神 | 0 | 0 | 13 | 2 | 40 | 2 | 100 | 3 | 3 | 128 | 13/13 |
| 142 | 玄武现世 | 25 四神 | 28 | 0 | 11 | 0 | 40 | 2 | 28 | 4 | 3 | 128 | 13/13 |
| 143 | 白虎临凡 | 25 四神 | 29 | 1 | 11 | 0 | 40 | 100 | 28 | 4 | 3 | 128 | 13/13 |

Blank records 78–82, 87, 88, 90–93, 98, 99, 101–135, 139 are named 空白xxxx, have MgID 144 (outside the jump
table) or copies of real handlers, and are learned by no class; 112/113 use MgID 39/40 (script hook, §2.9.14).
Do not offer blanks.

### 2.2 Who knows a strategy — 0x41dc78 [C]

```
knows(unit, s, onlyImitable):
  P = person(unit)
  for k in 0..7:
      m = effq2(P; 0x49 + k, 0x6c, 3, 0)               # 0x43e1a8(k): learn-category mask granted by effects/items
      if (m != 0 and (m & Mg8[s]) != 0)
         or (k == 0 and (learned_by_level(P, s)        # 0x41832b
                         or learned_by_person_table(P, s))):   # 0x40de69
          if not onlyImitable or (MgMF[s] & 1): return True
  return False
learned_by_level(P, s):  L = strat[s].learn[P.class]  (rec+0x11+class);  L != 0 and P.level >= L     [C]
learned_by_person_table(P, s):  runtime table at 0x507800 (empty in the exe; filled when loading):
    sections "0xff, strategy id, {level u8, person id u16}*" — true if an entry for (s, P) has level <= P.level [C format, G source]
```
Mg8 bit meanings follow the data: 1 四系 elementals, 2 debuffs, 4 status, 8 recovery, 16 buffs/movement,
32 weather, 64 雷/special, 128 四神/砂暴 (谍报 = 232 = 128|64|32|8). [D]

### 2.3 Can the strategy be cast now

**Menu filter 0x417af6(unit, s)** [C]: `sealed(unit)` (status mask 4) → no; else `unit.MP >= mp_cost(unit, s)`.

```
mp_cost(unit, s):                                    # 0x417b27
  c = strat[s].mp                                    # rec+0x0e
  q = effq(unit; 0x2e, 0x39, 1, 0)                   # 0x44df49
  if q: c = c * (100 - q) / 100                      # 0x41edc1, truncating
  return c
```

**Situation check 0x46fcf8(s, caster, showMsg)** (also the gate at the top of the dispatcher; 1 = usable) [C]:
weather `w` = 0x41553b(0x4b3d08) = `table 0x48e100[state+0x11][state+4]` (0 晴, 1 阴, ≥2 恶劣天气).
* effect 0 (fire) and 纵火: unusable if `w >= 2` ("在恶劣天气时无法使用"), unless `effq(P; 0x2a, 0x3a, 1, 1)`
  (0x41ff0f) or (EV4087 ≠ 0 and byte 0x500af1 == 0).
* effect 20 with MgID 24 (冥想): needs caster HP ≥ 3 ("ＨＰ不足").
* effect 25 (四神), 0x41ff6e: usable outright if `effq2(P; 0x50, 0x6c, 3, 0) > 0x7f` (learn mask 7 bit 7);
  otherwise the person must have an equipped item with effect 0x3a (0x4079da), then usable if 0x41ff0f, else by
  weather: 青龙出海 (MgID 26) needs `w >= 2`, 朱雀翔天 (MgID 0) needs `w == 0`, 玄武现世 (MgID 28) needs `w == 1`,
  白虎 no condition.
* effects 34/35 (纵火/修筑): unusable when 10 objects exist (byte 0x501ae1 ≥ 10, "不能再添加了！"); 修筑 also needs
  gold (0x4b077c via 0x40e1d0) ≥ 1000.
* everything else: usable.

### 2.4 Cast flow and dispatcher 0x425627(s, caster, preTarget) [C]

Context object (ECX; one shared instance at 0x497af8 for the player cast path): +0 s, +1 caster idx, +2 preset
target (0xff = choose), +3 critical flag, +4 caster person*, +8 caster unit*, +0xc current target, +0xd target
list (0xff-terminated), +0x108 i32[] value per target (damage >0, heal <0), +0x400 result code, +0x401 per-target
code (0 = miss), +0x4fb range code, +0x4fc area code, +0x502 EXP, +0x506 equipment EXP, +0x50a per-target
equipment-EXP flag, +0x54c "caster earns EXP" = `caster.side_byte == 0 or caster.control == 7`, +0x550 performed,
+0x554 big animation.

1. 0x4251e1 init: range code = 0x401dff (rec+0x0c, through 0x41ce8c(2, ·) — range modifier, [G] effect hook);
   area code = 0x41a10c (§2.5.3).
2. 0x46fcf8 check (message only for player-controlled casters); fail → return.
3. Big animation flag = `effect != 43 and 99 < MgMcall[s] < 255`.
4. Dispatch on `MgID[s]` via jump table 0x4259c3 (ctx+0x400 = result code written first):

| MgID | strategies | code | handler |
|---|---|---|---|
| 0 | elementals, 雷, 吸血, 暈眩, 換血, 朱雀 | 0x40 | 0x423198 → 0x4231c2(0,0,2) damage |
| 3 | 谍报 | 0x41 | 0x423198 damage (MP) |
| 1 | 砂暴 | 0x40 | 0x42427b |
| 2 | 反間計 | 0x42 | 0x423230(0) |
| 32 | 诱敌 | 0x43 | 0x423230(0) |
| 6/7/4/5 | 压迫·大喝 / 咒骂·威吓 / 钝兵·钝队 / 虚脱·厌战 | 0x44/0x45/0x46/0x47 | 0x423230(0) debuff |
| 30 | 衰气 | 0x48 | 0x423230(0) |
| 9/8/10/11 | 毒 / 混乱(+哼哈) / 麻痹 / 禁咒 | 0x49/0x4a/0x4b/0x4c | 0x4231a8(0) → 0x4231c2(1,0,2) |
| 15 | 撞心, 觉醒, 大觉醒 | 0x5a | 0x4231a8(1) → 0x4231c2(1,1,3) |
| 19/20/17/18/16 | 奋起·鼓舞 / 坚固·强阵 / 练兵·练队 / 欢声·昂扬 / 强行 | 0x52/0x53/0x54/0x55/0x56 | 0x423230(1) buff |
| 33 | 精进 | 0x58 | 0x423230(1) |
| 13 / 14 | HP / MP recovery | 0x50 / 0x51 | 0x4232bf |
| 12 | 八阵图 | 0xff | 0x4243c6 |
| 21 | 回归 | 0x59 | 0x423aa1 |
| 22 | 豪雨·晴明·昙天 | 0x70 | 0x423b0b |
| 23 / 25 | 气合 / 霸气 | 0x52 / 0x57 | 0x424374 (self) |
| 24 | 冥想 | 0x51 | 0x41e3b3 |
| 26 | 灵珠×5, 青龙出海 | 0x40 | 0x4244e5(5 if effect 25 else 0) |
| 28 / 29 | 玄武 / 白虎 | 0xff / 0x5a | 0x42481a(start=60, mode=1) / 0x4246d0 |
| 34 | 连击 | — | 0x449c0d |
| 27 | 纵火, 修筑 | — | 0x414e29 |
| 31 / 35 | 疾行 / 瞬移 | — | 0x40eb7e(0) / 0x40eb7e(1) |
| 36 / 37 / 38 | 召唤 / 移形换影 / 号令 | — | 0x426551 / 0x42d387 / 0x428081 |
| 39 / 40 | blank 112 / 113 | 0x5b | 0x423230(1) / 0x424374 |

5. 0x422f2e finalize (§2.10), return ctx+0x550.

**Generic multi-target body 0x4231c2(isStatus, sideMode, pickMode)** [C]:
```
t = pick_target(pickMode)                 # 0x4233f8 → 0x42220f: preset ctx+2, else UI/AI pick 0x45533d(range code)
if t == 0xff: return                      # cancelled: nothing spent
expand_area(sideMode)                     # 0x44402b (§2.5)
total = per_target_pass(isStatus)         # 0x423594
apply_results()                           # 0x4251bd = animation 0x421496 + result applier 0x42269c, sets ctx+0x550
if byte[0x500c46] == 0 and effq(caster; 0x3a, 0x3b, 1, 1):   # 0x4390a9 "连续策略": cast once more
    byte[0x500c46] += 1; remember totals in 0x500c42; repeat per_target_pass + apply_results (same targets)
ctx.exp += word[0x500c42]; ctx.equip_exp += word[0x500c44]; dword[0x500c42] = total
```
```
per_target_pass(isStatus):                # 0x423594
  for each target T in ctx list:
      if isStatus:
          hit = hit_test(caster, T, s)                         # §2.6
          ctx.code[T] = hit and EV4087 == 0 ? ctx.code : 0
          flag = side(caster) == 1 ? hit : 0                   # enemy casters: damage rolls its own hit again
      else: flag = 0
      d = strat_damage(caster, T, s, flag)                     # 0x43c01d (0 for non-damaging strategies)
      ctx.value[T] = d
      if not isStatus: ctx.code[T] = d ? ctx.code : 0
      ctx.exp = max(ctx.exp, strat_exp(T)); ctx.equip_exp = max(..)   # 0x44de9e (§2.11)
```
Buff/debuff 0x423230(isBuff): pick (mode 2 + isBuff), expand area (sideMode = isBuff), per target
`code = hit_test(...) ? ctx.code : 0`, no damage. Recovery 0x4232bf: pick (mode 3), expand (sideMode 1),
`value = -heal(T)` (0x43c5df, §2.8), code always set (no hit test). [C]

### 2.5 Targeting

#### 2.5.1 Cast range — 0x436511 [C]
Range code `c` (rec+0x0c; the function accepts 4 packed codes, strategies use one): `c == 10` → every tile of the
map (0x4366f0); `c == 11` → no tiles (self only); otherwise list = ptr table 0x4d1400[c > 11 ? c − 2 : c], u16
entries `(a, b)` terminated by 0xffff. Each entry adds, relative to the caster: if `a ≠ 0` and `b ≠ 0` the four
tiles (±a, ±b); otherwise the four orthogonal tiles at distance `max(a, b)`. When the pick mode targets allies
(modes 3/4) the caster's own tile is added too. Codes used by strategies:

| code | entries | tiles |
|---|---|---|
| 1 | (1,0)(1,1) | 8 neighbours |
| 5 | (1,0)(2,0) | orthogonal cross, distance 1–2 |
| 6 | (1,0)(1,1)(2,0) | Manhattan ≤ 2 |
| 10 | — | whole map |
| 11 | — | self only |
| 12 | (1,0)(1,1)(2,0)(1,2)(2,1)(3,0) | Manhattan ≤ 3 |
| 13 | (1,0)(2,0)(3,0)(4,0)(1,1)(2,1)(3,1)(1,2)(2,2)(1,3) | Manhattan ≤ 4 |
| 18 | (3,0)(4,0)(5,0)(2,1)(3,1)(4,1)(1,2)(2,2)(3,2)(1,3)(2,3)(1,4) | Manhattan 3–5 ring |

(Full table 0x4d1400 has codes 0–37; the physical-attack section reuses it for attack ranges.)

#### 2.5.2 Effect area — 0x435ce9 [C]
Area code `a` (ctx+0x4fc): the centre (chosen target) is always first; `a == 0` → single target. Otherwise
`k = 0x406235[a]`: `k == 0x61` → line: `n` tiles stepping from the target away from the caster in the
caster→target direction (0x42230e), `n = 1` for a=4, `5` for a=5, `2` for a=7; `k == 0x60` (a=9) → the two tiles
from 0x4254fa (flanking, [G]); else entry list ptr 0x4d13a0[k] expanded around the target (or around the caster
when `a == 10`) with the same (a,b) rule:

| area | list | shape |
|---|---|---|
| 1 | (1,0) | cross, 5 tiles |
| 2, 10 | (1,0)(1,1) | 3×3 |
| 3 | (1,0)(1,1)(2,0) | Manhattan ≤ 2, 13 tiles |
| 6 | (1,0)(1,1)(2,0)(1,2)(2,1)(3,0) | Manhattan ≤ 3, 25 tiles |
| 8 | (1,0)(1,1)(2,0)(1,2)(2,1) | 21 tiles |
| 4 / 5 / 7 | line | 1 / 5 / 2 tiles behind the target |

Units collected from the tiles (0x435c10) are filtered by `sideMode`: 0 → other camp only (all units if byte
0x500c44 == 1, which is set during a mine detonation 0x42d2d3); 1 → same camp; 2 → any. Then 0x444064 drops units for which
`elemental_ok` fails (below). Strategy area damage has **no distance falloff** (the per-cell % list this scan writes, 0x500e7d + k = max(50,
100 − 10·ring), is read only by thrown-item / mine damage, §4.4; physical attacks ignore it too). [C]

#### 2.5.3 Penetration (MgMF bit 1) — 0x41a10c / 0x45d316 [C]
If `MgMF[s] & 2` and `effq2(caster; 0xa8, 0x57, 3, 0) & 2` (and EV4087 == 0), area = table 0x45d343[area]:
0→1, 1→2, 2→3, 3→8, 4→7, 5→5, 6→6, 7→5, 8→6, 9→2, 10→10.

#### 2.5.4 Target validity — 0x42044d(s, caster, target, showMsg) [C]
```
aiCaster = caster.control != 7
if ignores_terrain(caster, s): return OK          # 0x41d90e: effect >= 25 → OK;  effect 4..24 → not OK here (continue);
                                                   # effect 0..3 → effq(P; 0x2b, 0x38, 1, 1) (EV4087 == 0)
e = effect(s)
if e <= 3:  return elemental_ok(e, target) ? OK : NO ("不能在这里使用")
if 15 <= e <= 18 and aiCaster and status_of(target, e) != 0: NO      # AI does not re-apply
if e == 22:  target == caster → NO ("不能对我方部队使用");
             aiCaster: NO unless target has acted (flags 4 or 2) and target.side_byte != 0
if aiCaster:                                       # waste checks, AI only (jump table 0x42060c)
    e == 5 (吸收HP): NO if caster HP == MaxHP;   e == 6: NO if caster MP == MaxMP
    e == 19: NO if target HP == MaxHP;          e == 20: NO if target MP == MaxMP
    e == 21: NO if target status byte == 0
return OK
elemental_ok(e, unit) = table_0x420acc[terrain(unit)] & (1 << {fire 0, water 1, earth 3, wind 2}[e])   # 0x420a5a
```
Terrain/element table 0x420acc (bit0 火 bit1 水 bit2 风 bit3 地; = the 6.6 patch "改策略搭配的地形") [C]:
平原 草原 栅栏 5 (火风) · 树林 城墙 城内 城门 城池 关隘 鹿砦 村庄 兵营 民居 宝物库 火 1 (火) · 荒地 山地 岩山 山崖 12 (风地) ·
雪原 浅滩 沼泽 池塘 小河 大河 水池 船 6 (水风) · 桥梁 7 (火水风) · 祭坛 15 (all) · 地下 8 (地). Terrains 30–33
(地雷 战壕 掩体 工事) read past the table into code bytes: 0x55, 0x8b, 0xec, 0x8b (port literally). 雷 (38) and
non-elemental strategies have no terrain restriction.

### 2.6 Hit chance

#### 2.6.1 Strategy hit rate — 0x43b730(0, target T, s), ECX = caster C [C]
```
if effect(s) == 33 (反間計) and T.person_id(u32 at T+0) < 210: return 0           # immunity (doc: patch 0x43B7C1)
if target_valid(s, C, T, 0) fails: return 0                                      # 0x42044d
if paralysed(T) and s not in {10 海啸, 31 暈眩, 53 反間計}: return 100
if effq(C; 0x1b, 0x1b, 1, 1): return 100
if effq(T; 0x63, 0x4f, 1, 1) and strat[s].side == 0: return 0                   # strategy immunity
(cA, tA) = stat_pair(C, 2, T, 2, 0); (cB, tB) = stat_pair(C, 4, T, 4, 0)        # 精神 + 士气, WITH terrain
r = base_rate(cA + cB, tA + tB)                                                  # 0x43b53a
r = satsub(r, effq(T; 0x1d, 0x29, 1, 0))
r = min(r + dir_bonus(C, T, r), 100); r = max(1, satsub(r, effq(T; 0x21, 0x22, 1, 0)))   # 0x408eee
if s < 150:
    h = MgHit[s]
    h >= 5:  r = (h == 100) ? 100 : r * h / 100
    h 0:     r = r * 90 / 100            (大觉醒)
    h 1:     r = 100                     (觉醒)
    h 2:     unchanged
    h 3, 4:  if T.index == 0: r = 0
             elif T.person_id == boss (u16 at 0x492f90+0x3d06): low byte of r = low byte of boss id  (quirk, port literally)
             else r = r * (h == 3 ? 34 : 50) / 100
if effect(s) == 5 and family(C) == 12 (女兵): r = r * 3 / 2
r = addcap(r, effq(C; 0x1c, 0x26, 1, 0), 100)
if effq(C; 0x27, 0x20, 1, 0): r = addcap(r, 10, 100)
return min(r & 0xff, 100)

base_rate(A, D):                                     # 0x43b53a, unsigned
  if A >= 2*D: 100
  elif A >= D: 90 + (A - D) * 10 / D
  elif A >= D/2: 60 + (A - D/2) * 30 / (D/2)
  else: 30 + satsub(A, D/3) * 30 / (D/3)
dir_bonus (0x408db1 mode 1): delta = v*5k/100 with k = 0 front / 1 side / 2 back of T's facing when EV4066
  (攻击方向伤害加成) ≠ 0, plus v*5/100 when side(T) != 1 and byte 0x500e9a == 1 (§1.5).
```
Heal/MP recovery (MgID 13/14), weather, 气合/霸气/冥想 and the special handlers below skip the hit test unless
stated. Buffs and cures go through it but their MgHit is 100 or code 1 (sure hit).

#### 2.6.2 Hit roll — 0x43b4b6(T, kind=2, s) [C]
```
r = rate (above)
if r >= 100: hit
if EV4018 (u32 0x505ec8) > 1:  if r >= EV4018: hit;  if r < EV4017 (0x505ec4): miss
for attempt in 0..1:
    ok = roll_acc(r, 0x13)                           # 0x4287a8
    if EV4018 == 1 or ok or r < 85: break
    r -= 10                                          # second chance at r-10 when r >= 85
return ok
```
`roll_acc(p, mode)` (0x4287a8): unless EV4087 ≠ 0, updates a per-slot accumulator `acc = byte 0x4930c8[slot]`,
`slot = 4·idx + (mode % 16)` with idx = byte 0x497af8+0xc (current strategy target) for mode 0x13, byte
0x497af8+1 (caster) for mode 0x12 (strategy critical), byte 0x4927f0+1 (the current physical target) for mode 1
(physical hit; §1.4).
Odd `mode % 16`: `s = acc + 100 − p; hitAcc = s < 100; acc = hitAcc ? s : s − 100`; even (0x12):
`s = acc + p; hitAcc = s >= 100; acc = hitAcc ? s − 100 : s`. If EV4018 == 1 (普罗 类型3 集气模式) the result is
`hitAcc`; otherwise (and always when EV4087 ≠ 0) `roll(p, 0)`. Defaults: EV4017 = EV4018 = 0
(scripts R_072/R_107 may set 4017=50, 4018=1).

#### 2.6.3 Pseudo-random modes [C]
`roll(p, mode)` 0x43786b: if EV4077 (0x505fb4, default 2) < 2 and mode ≠ 2: `v = deck(0x501bf6, row = EV4077)`,
`p = min(p,100)`, hit = (mode == 1) ? `v >= 100 − p` : `p >= v`. `deck(ctr, row)` 0x455e25 (ECX = counter byte,
EAX = row): `table 0x508998[row*52 + *ctr]`, then `*ctr = *ctr < 51 ? *ctr + 1 : 0` (table refilled at every player-phase start by 0x423490: 104 × `rand(100)+1`, §7.1).

### 2.7 Damage — strat_damage 0x43c01d(T, P_T, s, flag), ECX = caster C [C]
```
if byte[0x500ad7] == 1: d = item_value (attack item used as a strategy: 0x41dd72) → goto cap
e = effect(s); coef = MgHurt[s]
if MgHurtYN[s] >= 4 and e not in {30 生命交换, 6 吸收MP}: return 0
if flag == 0 and not hit_test(C, T, s): return 0
if not target_valid(s, C.idx, T.idx, 0): return 0
if e == 30: return T.HP - C.HP                     # signed; NOT capped (換血, see §2.10)
if coef == 255: return T.HP                        # 海啸 / 暈眩: kills
(c, t) = stat_pair(C, 2, T, 2, 1)                  # 精神, no terrain
base = level(C) + 25
d = c >= t ? base + (c - t) / 5 : satsub(base, (t - c) / 5)     # divisor 5 = patches 0x43C126/0x43C139
d = d * coef / 100
f = family(T); if f <= 39: d = d * attr6[f] / 100                # 0x4d21b0
bonus = 0
if e == 0:  if terrain(T) in {2 树林, 23 民居}: bonus = 25        # (a +20 branch for family 0x40 is dead code)
if e in {1, 3, 38}: if weather >= 2: bonus = 25 else skip
if e == 2:  if family(C) == 7 (贼兵): bonus = 25 else skip
d += d * bonus / 100
if e == 5 and family(C) == 12 (女兵): d *= 2
q = (e >= 4) ? effq(C; 0x27, 0x20, 1, 0) : effq(C; 0x28, 0x38, 1, 0);  d += d * q / 100
q = effq(T; 0x29, 0x43, 1, 0);  d = satsub(d, d * q / 100)
d = common_mod(C, T, d, flag)                      # 0x412c78 below
if flag != 1: d = crit_and_doom(C, T, d)           # 0x40ca68 below
cap: d = min(d, e == 6 ? T.MP : T.HP)
```
`flag`: 0 for damage strategies; for status strategies = the earlier hit result if `side(C) == 1`, else 0
(0x423594). With flag 1 the variance, 0x41d716 and crit/doom steps are skipped (6.6 fix "毒和定身策略无法触发
末日审判/致命一击" keys on this flag).

**common_mod 0x412c78(C, T, d, flag)** (shared with physical damage) [C]:
```
d = 0x408db1(C, T, d, 0)          # direction / 围攻 bonus (§1.5)
if flag != 1:
    d = 0x41d716(T, d)            # ×80/100 under a map-zone condition (byte 0x501bd2 >= 2, table 0x4934b0) [G meaning]
    r = rand(7)
    d = r > 2 ? d + (r - 2) : max(1, satsub(d, r))     # −0..−2 or +1..+4  (6.1 doc "push 7" float)
```
**crit_and_doom 0x40ca68** [C]:
```
if effq(C; 0x6f, 0x48, 3, 0) & 2:                                   # 末日审判 (0x42423d, mode 2 = strategy)
    d += maxHP(T) * (10 + deck(0x501bf5, row 0) / 20) / 100          # patch bytes 0x424262 (20) / 0x42426A (10)
if T.idx == ctx.first_target:                                        # only the centre target can crit
    v = (effq(C; 0x33, 0x31, 3, 0) & 2 ? 100 : 0) + crit_curve(t4, c4)   # (c4, t4) = stat_pair(C, 4, T, 4, 0) 士气
    if v <= 100:  if not roll_acc(v, 0x12): return d;  v += 100
    d += d * (v / 4) / 100;  ctx+3 = 1        # (+25 % + v/4 %); 25 % chance of a cosmetic quote (0x40eab4)
crit_curve(D, A):                     # 0x405d0a
    A >= 3D: 100;  A > 2D: 20 + (A − 2D)*80/D;  A >= D: 2 + (A − D)*18/D;  else 1
```

### 2.8 Recovery amounts — heal 0x43c5df(s, caster idx, preview), ECX = target T [C]
```
id = MgID[s]
if id in {12 八阵图, 28 玄武}: h = maxHP(T) − T.HP
elif id == 14 (建言/献策): h = strat[s].mp (rec+0x0e: 24 / 48)
elif id in {13, 29 白虎}:
    v = stat(C, 2 精神) * terrain_pct(C) / 100      # caster's buffed spirit (0x414ccb(2,0))
    h = MgHurt[s] == 0 ? v / 10 + 40 : v / 2 + 70   # 小補給/援队 (coef 0) vs 大補給/援军/输送/白虎
    if not preview and rand(200) < stat(T, 4 士气): h += rand(11)
else: return 0 (no poison halving)
if poisoned(T): h >>= 1                            # 0x423fa1
cap: h = min(h, id == 14 ? maxMP(T) − T.MP : maxHP(T) − T.HP)
```

### 2.9 Status, buff and special results

The result applier 0x42269c maps each target's code (`code − 0x3f` → table 0x422bc2 → jump 0x422aa0) [C]:

| code | effect on target |
|---|---|
| 0 (miss) | "miss" message if value == 0 |
| 0x40, 0x41, 0x50, 0x51 | none besides the HP/MP change |
| 0x44/0x45/0x46/0x47 | `buff_change(0x1b / 0x1d / 0x17 / 0x19)` = 攻击 / 防御 / 爆发 / 士气 down |
| 0x52/0x53/0x54/0x55 | `buff_change(0x35 / 0x37 / 0x31 / 0x33)` = 攻击 / 防御 / 爆发 / 士气 up |
| 0x56 | `buff_change(0x30)` = move up |
| 0x48 / 0x57 | the four downs / the four ups (0x40bb87 with codes 0x415531[0..3] / [5..8]) |
| 0x49 / 0x4a / 0x4b / 0x4c | inflict 中毒 / 混乱 / 麻痹 / 禁咒 (0x420e36(0x21/0x1f/0x23/0x25)) unless `value >= T.HP` |
| 0x5a | cure all statuses (0x420e36(0x2e) → clear mask 0x1e) |
| 0x58 | 精进: `byte 0x501b00[T.idx] = 3` if T.idx < 20 (0x420bd3 code 0x39) |
| 0x42 | 反間計: §2.9.13 |
| 0x43 | 诱敌: move T next to the caster (0x4594ea(0x404 + T.idx, C.x, C.y, 4)) |
| 0x59 | 回归: clear T action flags bits 1\|2 (0x406690(6)) — T may act again |
| 0x5b | script hook 0x42fd09 (blank 112/113) |

Then for every target with `value ≠ 0` (MgID ≠ 32): MgID 3/14 → MP −= value; MgID 24 (冥想) → HP −= value2
(ctx+0x10c), MP −= value; else HP −= value, where a negative value is first clamped so HP ≤ maxHP and a positive one
to ≤ HP. If HP damage > 0: SP gain 0x410fc3 (§3.7 note) and, if the target survives, damage-reaction 0x416442. [C]

**buff_change(code, T)** 0x420cb4 [C]: `k = (code − 0x17) >> 1; up = k > 4; if up: k −= 8`; stat =
table 0x465a16[k] (k 0→3 爆发, 1→4 士气, 2→0 攻击, 3→1 防御, 4→5 移动). For 攻击 codes, `t = attr5[family(T)]`
(0x4190e8): t == 2 → 攻击 only, t == 1 → 精神 (stat 2) only, else both 攻击 and 精神. Level setter 0x43f98e:
```
lv = T.buff[stat] (signed byte)
up:   lv >= 3 → 6;  lv < 3 → 3
down: lv > 3 → 3;   lv <= 3 → 0
```
So one cast moves a level straight to the extreme (6 / 0) or cancels the opposite state. [C]

Special handlers (all [C] from disassembly/decompile unless marked):

1. **砂暴** 0x42427b: targets every on-field unit of the other camp (whole map, no range/area), dropped by the
   elemental filter (wind); each: `d = strat_damage(..., flag 0)` (own hit roll), code 0x40 if `d`. If nobody,
   EXP for "no target" is still computed.
2. **八阵图** 0x4243c6: pick target (range 13), area 3 (enemies); per unit `r = rand(8)`: 0 → damage as 八阵图
   (MgHurt 120), code 0x40; 1 → damage as strategy 46 毒烟 (MgHurt 70, own hit roll) with code 0x49 (poison applied
   even if the damage roll missed, unless killed); 2..6 → codes 0x4a 混乱, 0x4b 麻痹, 0x4c 禁咒, 0x48 all down,
   0x57 all up (table 0x4785c6) without hit test; 7 → full heal (code 0x50).
3. **灵珠 ×5 / 青龙出海** 0x4244e5(n): candidates = enemies in cast range (sideMode 0) after the elemental filter.
   灵珠 (n=0): the chosen target is hit `area code` (= 4) times; if it dies, the remaining hits go to the next
   candidate. 青龙 (n=5): 5 hits, each on `candidates[rand(count)]`, dead units removed. Each hit = full
   `strat_damage` (own hit roll), result applied per hit.
4. **朱雀翔天**: ordinary MgID 0 damage strategy (range 13, area 2).
5. **玄武现世** 0x42481a(start = 60, mode = 1): scans unit indices **60..249 only** (player indices 0..59 are never
   touched — port literally); for each on-field unit passing the elemental filter: same camp as the caster →
   status byte cleared, code 0x57 (all up); other camp → code table 0x4785c7[rand(5)] = 0x49, 0x4a, 0x4b, 0x4c,
   0x48 applied by its own loop where 0x49 → **混乱**, 0x4a → **中毒**, 0x4b → 麻痹, 0x4c → 禁咒 (mapping differs
   from 0x42269c), 0x48 → all down. No hit test.
6. **白虎临凡** 0x4246d0: every on-field unit of the caster's camp passing the filter: `h = heal(T)` (spirit
   formula), hit test (MgHit 100 → sure), on hit HP += h and cure all statuses.
7. **回归** 0x423aa1: pick (ally mode), area, per target hit test → code 0x59.
8. **冥想** 0x41e3b3 (self): `hpCost = HP < 51 ? HP − 1 : 50`, `mpGain = HP < 51 ? (HP − 1) / 2 : 25`, MP gain
   clamped to `maxMP − MP`.
9. **气合 / 霸气** 0x424374 (self, no hit test): 气合 → 攻击 up (and/or 精神 by attr5); 霸气 → all four up.
10. **Weather** 0x423b0b: wanted = table 0x40dbab[MgHurt] (豪雨 → 2, 晴明 → 0, 昙天 → 1); new phase index =
    0x44a1f5(wanted): for wanted ≤ 1 the first index i in 0..5 of the current weather row (0x48e100 + 6·state[0x11])
    with that value (6 if none); for rain the last index whose value is 2/3/4, minus 1 [C code, G intent]. If it
    differs from the current phase (state+4) the weather changes (0x449f91), else "no effect". Always succeeds
    otherwise; EXP 20 (§2.11).
11. **连击** 0x449c0d: `n = rand(3) + 2` physical attack actions (0x439413) in a row, stopping when no target or the
    attacker is dead/confused (0x426b33).
12. **疾行 / 瞬移** 0x40eb7e: re-opens movement (0x43d4fc(caster, 0xb, 0/0xff, 1)); 瞬移 moves anywhere
    (flag 0xff) [C call, G semantics]. **移形换影** 0x42d387: swap caster and the chosen ally (0x428ffc).
    **号令** 0x428081: target ally must be player-controlled and not yet moved (`flags & 2 == 0`): it moves
    (0x43d4fc) and attacks (0x439413) immediately, then is marked acted (flag 4).
    **纵火 / 修筑** 0x414e29: pick a tile (range 6, mode 4), place object (0x4560f3, terrain 0x14, 修筑 also spends
    1000 gold), registered in the 10-slot list at 0x501ae2 {pos u16, timer = 2}, counter byte 0x501ae1 += 1.
    **召唤** 0x426551: spawns MgHurt-coded units (`0x300 | MgHurt`) near the caster, count from the area code
    [G details — needs its own pass if the port uses summons].
13. **反間計 (6th new strategy)**: hit as above (persons < 210 immune, ×0.8); on hit 0x420bd3(0x3b): timer
    `byte 0x501ad8[T.idx] = 2` and 0x4073bc(T, 2): EV4078 (0x505fb8) 0 → `T.side_byte += 3` and `T.control = 7`
    (controllable ally); 1 → side += 3 only (uncontrollable ally); 2 → control = 7 only (stops acting). Revert at
    turn start (§3.5): `side −= 3`, `control = 1`. The doc's "3 turns at 0x420C0C" is `mov dl, 2` at 0x420c10 in 6.6.
14. **撞心 / 換血 / 谍报 / 吸血**: 撞心 (MgID 15, HurtYN 2) cures the ally **and** deals spirit damage to it
    (MgHurt 60) — literal; 換血 (MgID 0, effect 30): value = `T.HP − C.HP` (negative heals T, clamped to maxHP);
    the caster gains the positive total (§2.10); 谍报: MP damage ≤ T.MP, caster regains it; 吸血: HP damage, caster
    heals it. Blank 112/113 (MgID 39/40) call script hook 0x402ac7 with (MgMcall, MgHurt, MgHurtYN).

### 2.10 Caster bookkeeping — 0x422f2e (after any performed strategy) [C]
```
if not ctx.performed or C.state != 2: skip
cost = byte[0x500fcc] ? 0 : mp_cost(C, s);  rem = satsub(C.MP, cost);  if rem == 0: cost = C.MP
(total, refl) = 0x42bbba: total = Σ positive values (or dword 0x500c42 if non-zero, 连续策略);
               refl = Σ value_i * effq(T_i; 0x42, 0x55, 1, 0) / 100
hpGain = 0; mpDelta = −cost
if e in {5, 30}: hpGain = min(total, maxHP(C) − C.HP)
if e == 6: g = min(total, maxMP(C) − rem); rem += g; mpDelta = g − cost
q = effq(C; 0x43, 0x56, 1, 0); if q: hpGain = min(hpGain + total*q/100, maxHP(C) − C.HP)
if refl: hpGain −= refl; if hpGain < 0: hpGain = −min(−hpGain, C.HP − 1)     # reflection never kills
if mpDelta < 0: sp_gain(C, −mpDelta * 2)                                      # 0x410fc3
C.HP += hpGain; C.MP = rem
person EXP += ctx.exp (0x4088cd);  equipment EXP slot 0 += ctx.equip_exp (0x4082dd)
```

### 2.11 Strategy EXP — 0x420efb (per target; ctx keeps the maximum, not the sum) [C]
```
if strat[s].side == 2: x = 20
else:
    d = level(C) − level(T)
    killed = side == 0 and MgHurtYN[s] < 4 and value_T >= T.HP
    if not killed:
        if not ctx.earnsExp: return 0
        x = d < 0 ? min(−d*4 + 10, 100) : max(satsub(10, d/2), 5)
    else:
        (kill bookkeeping 0x4290c8 / 0x42a9c4); if not ctx.earnsExp: return 0
        x = d < 0 ? min(−d*8 + 32, 200) : max(satsub(32, d*4), 10)
        if T.person_id == boss (u16 0x492f90+0x3d06): x *= 2
return scale(x, person)        # 0x42104f
scale(x, isPerson): x = x * (100 + equip_bonus(stat 8 EXP)) / 100   (0x407faa)
    equipment EXP always, person EXP only if EV4079 ≠ 0: ×2 if 精进 timer (0x501b00[idx], side_byte 0) ≠ 0,
    ×2 again if byte 0x500e9a == 1                                    # 0x403d5a
```
Equipment EXP 0x421363: only if `earnsExp` and the weapon slot item qualifies (0x41de1d(0x19) or kind 2/10):
`3`, minus 1 when `level(C) > level(T)` (non-side-2 strategies), scaled the same way.

## 3. Status effects and buffs

### 3.1 Status byte — unit+0x1e [C]
Four 2-bit counters (matches 6.5異常狀態計算.txt): bits 0–1 麻痹 (field 0), 2–3 禁咒 (1), 4–5 混乱 (2),
6–7 中毒 (3). Field value 0 = clear, 1..3 = remaining-turn counter. Masks used by the engine: `2 << field`
(2 麻痹, 4 禁咒, 8 混乱, 0x10 中毒; 0x1e = all).

| function | VA | semantics |
|---|---|---|
| `status(u, mask)` | 0x423fe8 | returns the 2-bit value of the first field selected by mask (0 if none) |
| `inflict(u, mask)` | 0x4240d6 | `byte |= init[field]` for each selected field, `init` = 0x4240ce {0x01, 0x08, 0x10, 0xc0} |
| `clear(u, mask)` | 0x423fb9 | clears selected fields (keep-mask table 0x4240d2) |
| status / buff event | 0x45aa37(pid, kind, v, show, idx) | kind 0..5 → `buff[kind] = v`; 6 → `v & 0x80 ? clear(v) : inflict(v)`; 7/8 → HP/MP op (script command 0x4d) |

Durations on infliction (bytes 0x4240ce = 6.6 patch "異常狀態回合數 01 08 10 C0"): **麻痹 1, 禁咒 2, 混乱 1,
中毒 3**. Inflicting ORs into the field (an existing value may combine, e.g. 2|1 = 3); the AI never re-applies a
present status (§2.5.4) — note the AI check uses mask `2 << table[e]` which for 中毒 is 32 and never matches.

### 3.2 What each status does [C]
* **麻痹**: move points 0 (0x43f74f); physical attacks on it always hit (0x43b623); strategies on it always hit
  except 海啸/暈眩/反間計 (0x43b730). No other reader of mask 2 in action/menu code → it may still act in place.
* **禁咒**: cannot use strategies (0x417af6); attack range replaced by code 0x0b (no tiles) → cannot attack or
  counter (0x43f8c0). It also blocks 武将技/军师技: 0x4225fb tests it through the flags 0x423fe8 leaves (`je` after the call is
  taken only on the "not found" path, which ends with `xor eax,eax`), §1.13.
* **混乱**: not selectable/controllable by the player and does not count as "still to act" (0x44e706, 0x44e0d9);
  never counter-attacks or preempts (0x406453 / 0x410f1c); ends 连击 chains (0x426b33); provides no adjacent support (0x416e53).
  Its own behaviour is AI-driven — see docs/ai.md.
* **中毒**: at its side's turn start loses `max(1, maxHP*20/100)`, but never below 1 HP (0x44e024:
  `dmg = HP <= dmg ? HP − 1 : dmg`); all healing it receives (strategies 0x43c5df, regeneration 0x43cddd) is
  halved (0x423fa1, `>> 1`).
* Status-immunity effect `effq(u; 0x12, 0x2a, 1, 1)` (0x472c53): after every action (0x42bc14, called from the
  player loop and script commands) all statuses are cured and every buff level < 3 is reset to 3.

### 3.3 Turn-start processing — 0x44ee30(side) [C]
Side 0 = unit indices 0..59, side 1 = 60..249. For each unit of the range, in index order:
1. `status_recovery(u)` 0x4263b0 (only `u.state == 2` with status ≠ 0): if an adjacent same-camp unit has the
   curer effect (0x43d16a scans the 8 neighbours for 0x42f87c, with animation) → cure all; else
   `tick(u, p1(u))` 0x42402c.
2. `buff_decay(u)` 0x43c940.
Then 0x420952 clears 0x508a00[] for the other range, then **poison damage** for the range (0x44dfc7 → 0x44e024),
then **regeneration** 0x43cddd for the range (physical/turn section).

```
tick(u, p):                                          # 0x42402c, fields 0..3
  for each field f with value v != 0:
      if p >= 100: cure f
      elif v >= 2: v -= 1
      else (v == 1):  EV4023 (0x505edc): 0 → cure if roll(p, 0); 1 → v' = deck(0x501bf5, row 1), cure if p >= v' and v' ≠ 0; 2 → always cure
  cure = event 0x45aa37(pid, 6, (2 << f) | 0x80, 1, idx)
```
So poison lasts 2 guaranteed turn starts then rolls; paralysis/confusion roll from the first turn start;
seal decrements once then rolls.

### 3.4 Recovery chances — 0x43c72c(u, mode) [C]
```
m = raw 士气 ability byte (person+0x25, via 0x4070e1(4))
p1 = effq(u; 2, 0x1c, 1, 1) ? 100 : m / 2                    # mode 1: status & debuff recovery
p0 = m > 100 ? 10 : 60 − m / 2                               # mode 0: buff wear-off (0x47fad0(60, m/2))
```

### 3.5 Buff levels — unit+0x18..+0x1d [C]
`+0x18 攻击, +0x19 防御, +0x1a 精神, +0x1b 爆发, +0x1c 士气, +0x1d 移动`; 3 = normal, 0..2 debuffed, 4..6
buffed (6.5 doc: "超過6會出錯"). Stat effect of a level: §1.3 BuffApply (patch bytes 0x43F617.. = 0x22 per stat: +20 % / −20 %).
Movement (0x43f74f): level ≥ 4 → `min(move + 2, 255)`; level < 3 → `move − 2` if move > 2 else 0.
```
buff_decay(u):                                               # 0x43c940, turn start of the unit's side
  for k in 0..5:
      lv = u.buff[k]
      lv == 3: —
      lv >= 5: lv − 1
      lv == 4: if roll(p0, 1): lv = 3
      lv <= 2: if p1 == 100: lv = 3
               elif lv < 2: lv + 1
               elif roll(p1, 0): lv = 3
  精进 timer t = 0x501b00[idx] (only if side_byte == 0):  t == 1 → if roll(p0, 1): t = 0 (message 0x2f);  t >= 2 → t − 1
  if idx >= 60: 反間計 timer t = 0x501ad8[idx]:  t == 1 → (roll(100,0) always) revert (message 0x2c, 0x4073bc(u,0));  t >= 2 → t − 1
```
(The 6.1 tutorial's "BUFF 固定三回合" patch NOPs the rolls; 6.6 keeps them.) A cast buff therefore holds at
6 → 5 → 4 for two turn starts, then wears off with chance p0 per turn; a debuff 0 → 1 → 2 then recovers with p1.
精进 doubles EXP (§2.11) while its timer is non-zero. A converted enemy (反間計, timer 2) reverts at the second
enemy-phase start after the cast.

### 3.6 Cures [C]
* Strategies: 觉醒/大觉醒/撞心 (code 0x5a), 白虎 (all allies), 玄武 (caster's camp in indices 60+), 八阵图 never cures.
* Items (usability 0x41c50c, item type byte +0x11): 0x1c needs 混乱, 0x1d 中毒, 0x1e 麻痹, 0x1f 禁咒, 0x20 any status
  (effect application: items section).
* Adjacent curer effect (0x43d16a) at turn start; status-immunity effect after each action (§3.2).
* Script/event: 0x45aa37 kind 6 with bit 7.

### 3.7 Related notes
* SP gain 0x410fc3(h) (skipped if EV4087 ≠ 0 or EV4059 禁止必杀 == 1) [C]: `if effq(u; 0x24, 0x41, 1, 0): h *= 2`;
  `sp = side_byte(u) < 2 ? h / 4 : h / 2` (我/友 vs 敌/援); `if h > 0 and sp == 0: sp = 1`; add via 0x423930. A target
  taking h HP strategy damage calls it with h; the caster calls it with `2 × MP spent`. SP rules: §1.13.
* EV summary for this section: 4017/4018 (hit thresholds & 集气 mode), 4023 (status recovery mode), 4053 (援军 camp),
  4059 (no 必杀/SP), 4066 (direction bonus), 4077 (pseudo-random, default 2 = off), 4078 (反間計 mode), 4079 (精进
  person EXP), 4087 (arena: fixed targets 0x3c, no terrain/SP/crit side effects).

## 4. Items in battle

Confidence: **[C]** read in the disassembly (formula/flow confirmed), **[D]** mod docs / data only, **[G]** inferred.
Conventions as elsewhere in this doc: `P` = person record (0x48 bytes, `PersonPtr(id)` 0x4061e4), `U` = battle
unit (0x30 bytes at 0x4a7b20, `UnitPtr` 0x4061f9), `I` = item record (25 bytes at `0x49f820 + 0x19*id`, getter
0x4837c2; ids 0..103 from Data.e5, 104..255 from Star.e5). Integer division truncates. `Pct(p, v) = v*p/100`
(0x425ad9, unsigned). `MinAdd(a, b, cap) = min(a+b, cap)` (0x47fa89, signed compare). `ByteAddCap(a, b, cap) =
min((a&255)+(b&255), cap&255)` (0x47fab5).

### 4.1 Item record fields used by battle code [C]
| in-memory | meaning (as used) | readers |
|---|---|---|
| `I+0x11` | type. `<0x14` weapon, `<0x1a` armour, else effect id (accessory / consumable) | 0x43ad20 |
| `I+0x14` | weapons/armour: treasure special effect id (0xff none); others: category 2 accessory / 3 consumable | 0x43ad29, category 0x40b444 |
| `I+0x13` | thrown items: attack-range code | 0x4103bb (0x412685) |
| `I+0x15` | base value `val` (level-1 value; consumable amount low byte) | 0x41dd72 (`eax`) |
| `I+0x16` | treasure special value `sv`; consumables: **high byte** of the amount | 0x41dd72 (`ecx = word +0x15`), 0x44661a |
| `I+0x17` | equipment growth per level; attack items: splash-area code; 附加技能: duration | 0x41dd72 (`edx`), 0x4202bb |
| `I+0x18` | use flags: bit 1 (`&2`) = not consumed on use ("無限使用", value 3 in data) | 0x4083f0 → `use+0x1e` |

* Category (0x40b444): type<0x14 → 0 weapon, type<0x1a → 1 armour, else `I+0x14` (2 accessory, 3 consumable).
  Treasure (0x40b4e1) = category ≤ 1 and type odd.
* Equipment kind → stat ("stat_of_type", 0x4067ce; table 0x40684f for type<0x1a): types 0..13 (剑枪弓棍炮车锤斧) → 0
  attack; 14..17 (扇, 宝剑) → 2 spirit; 18,19 (神器) → 10 = attack **and** spirit; 20..25 (铠甲劲装袍服) → 1 defence;
  accessory types 0x20..0x28 → 0 atk,1 def,2 spi,3 agi(爆发),4 morale,5 HP,6 MP,8 EXP%,7 move (table 0x4067c5);
  0x5c → 9; 0xfe → 10; else 0xff. Same map for a treasure's special id (0x40678e, on `I+0x14`).
* Person equipment slots (0x4065f0 / 0x4032df / 0x409680): slot k = 0 weapon, 1 armour, 2 accessory:
  id `P+0x2e+3k`, level `P+0x2f+3k`, exp `P+0x30+3k` (accessory has only the id byte `P+0x34`; `P+0x35` is the
  kill-count word, see 5.7).

### 4.2 Equipment values [C]
```
EquipValue(I, L)                       # 0x40b3d7; L = item level (1-based)
    v = I.val
    if category(I) <= 1:               # weapon / armour
        repeat (L-1) & 0xff times: v += I.growth      # byte loop counter: L must never be 0 (0 -> 255 steps)
    return v                           # no cap

SpecialValue(I, L)                     # 0x4200f5; treasure special value at level L
    v = I.sv; e = I.special            # e = I+0x14
    if e == 0x1f:   v = v*(L+1); goto ten           # 同仇破甲: scales at every level
    if L < 7:       return v
    if e == 0x72:   v = v*3/4; goto ten             # floor
    if e == 0x33:   return 7 if v == 4 else v       # 穿透攻击
    if e == 0x32:   return v*2
    if e in (0x36, 0x42, 0x46): return v + 1
    if byte[0x4cb6ba + (e-0x1a)] < 7: v = v*3/2     # floor; "7级质变" (6.1 tutorial CMP DL,7 -> 6.6 0x42010d)
ten:
    if L >= 10:                                     # "10级宝物" (6.6 0x420155)
        t = byte[0x4cb5ca + (e-0x1a)]               # table patched by the 6.6 log "修改10級寶物特效值"
        if t != 0xfe: return t
    return v
```
Equipment stat bonus `EquipBonus(s)` (0x407c29, ECX = person) — the bonus added to stat `s` (0..4 stats, 5 HP max,
6 MP max, 7 move, 8 EXP%):
```
sum = 0
for slot in (weapon, armour):
    id = P[0x2e+3*slot]; if id == 0xff: continue
    L = P[0x2f+3*slot]; I = item(id)
    t = stat_of_type(I.type)
    if t == s or (t == 10 and s in (0, 2)):          # 0x405670
        sum += EquipValue(I, L)                      # FLAT
    if treasure(I) and stat_of_type(I.special) == s: # 0x40678e
        sum += ScalePct(s, SpecialValue(I, L))       # 0x452825
acc = P[0x34]
if acc != 0xff and stat_of_type(item(acc).type) == s:
    sum += ScalePct(s, item(acc).val)
return sum

ScalePct(s, v)                                       # 0x452825; table 0x4cb6c0[s] == 2 for all s 0..6
    if s >= 7 or byte[0x4cb6c0+s] != 2: return v     # move (7) and EXP% (8): flat
    base = s<=4 ? word P[0x11+2s] : s==5 ? dword P[0x1b] : word P[0x1f]
    #   (with 特效 61 神魔附体 active, base = 0x407d48 "growth*level + raw" instead — see SKILLS)
    return Pct(v, base)                              # = base*v/100  -> treasure specials / accessories are PERCENT
```
So weapon/armour main values are flat additions, while treasure specials and accessories that raise a stat give
`v %` of the person's raw stat word (HP/MP: of the base HP `P+0x1b` / base MP `P+0x1f`). [C]

### 4.3 Using a consumable in battle [C]
Dispatcher `UseItem(item, user_unit, arg, consume)` 0x44f2ac (use object at 0x497750, built by 0x4083a7:
`+0` item id, `+2` user unit idx, `+3` target idx, `+4` user unit, `+8` target unit, `+0xc` user person,
`+0x10` target person, `+0x14` item ptr, `+0x18` = 1 (target range code), `+0x1c` used flag, `+0x1d` type,
`+0x1e` = `I+0x18` flags). Handler = `table[0x44f330][byte 0x44f380[type-0x1a]]`. Target choice: 0x41d122 →
UI 0x45533d(user, range code `+0x18` = 1, mode 4, item) (range-1 pick [G]); auto-use passes `arg = 0` = the user
itself. Validity 0x41c50c(item, target, check): the handlers call it with check = 0, where only 增加经验 (level < 100)
and 兵种上升 (5.5) can refuse; with check = 1 (menu/preview) the status cures also require the target to have that
status and 恢复状态 any status. After the handler: if used and `consume != 0` and
`(I+0x18 & 2) == 0` → inventory count `byte[0x493af0 + id − 0xa0]` −= 1 (0x420299; consumables are ids ≥ 160).
No handler gives person EXP or equipment EXP. [C]

| type (name) | handler | effect [C unless noted] |
|---|---|---|
| 0x1a 恢复HP | 0x41c61d | `heal = Amount(HP)`; `U.HP = min(U.HP + heal, MaxHP)` (0x43f6db) |
| 0x1b 恢复MP | 0x41c6c0 | `heal = Amount(MP) & 0xffff`; `U.MP = min(U.MP + heal, MaxMP)` (0x43f715) |
| 0x1c..0x20 治疗混乱/中毒/麻痹/禁咒, 恢复状态 | 0x41cd61 | clear status mask 8 / 0x10 / 2 / 4 / 0x1e on the target (0x423fb9; bit meaning in §3). Menu check: target has that status (0x423fe8) / status byte `U+0x1e` ≠ 0 |
| 0x21..0x25 武力…运气上升 (fruits) | 0x41d14a | see 5.6 |
| 0x26 增加经验 | 0x41cce6 | `SetExp(P.exp + I.val, show=1)` (5.2), then full HP/MP (0x41a0df). Usable only if level < 100 |
| 0x27 兵种上升 | 0x41d468 | class promotion (5.5) |
| 0x28 恢复SP | 0x4223db | `SP[pid] = min(SP + Amount(SP), 255)` (0x423930 with force=1; SP table `0x501c00[pid]`) |
| 0x29 获得功勋 | 0x4224d4 | 功勋 word[0] (attack) `+= val16` (5.8); only person id < 102 in the army |
| 0x2a HP上升 / 0x2b MP上升 | 0x4224d4 | base HP `P+0x1b` (word store) / base MP word `P+0x1f` `= min(base + val16, 0xffff)`; also bonus table `word[0x508400 + 14*pid + 2*(5|6)] += val16` (so EV4094 recalculation keeps it). Only person id < 102 in the army, else "不能在这里使用。" |
| 0x31 单挑 | 0x425e4c | forced duel (duel track); `I.val == 0` → byte 0x505fdc = 1, else EV4083 = val |
| 0x32 学会策略 | 0x432cce | adds strategy `val−1` to the per-person strategy table 0x507800 (learn level 1) |
| 0x33 使用策略 | 0x432cce | casts strategy `val−1` with MP cost forced 0 (flag 0x500fcc) |
| 0x34 附加技能 | 0x432a77 | temporary effect via 0x402ac7(pid, id = `I.val`, value = `I.sv`, turns = `I.growth`, table 0x512dc0) (SKILLS) |
| 0x3e 起出地雷, 0x3f 遥控地雷, 0x40 杀伤HP (mine), 0x41 杀伤HP (thrown), 0x42 发现地雷 | 0x41268e | 4.4 |
| 0x2c..0x30, 0x35..0x39 | 0x4805c9 | no-op (returns 1) |
| 0x3a..0x3d (任务物品 合成材料 工具物品 装备升级) | — | dispatch index 22..25 points past the handler table: not usable in battle [G: menu must filter them] |

```
Amount(kind)                                   # 0x43c44a(item); val16 = I[+0x15] | I[+0x16]<<8
    missing = kind==HP ? MaxHP - U.HP : kind==MP ? MaxMP - U.MP : 255 - SP[pid]
    if I[+0x15] == 0xff: return missing        # "完全恢复" (仙桃 val 255)
    return min(missing, val16)
```
(The preview window 0x44049e shows the same numbers; HP/MP上升 preview 0x423dea uses `min(Max + val16, 0xffff) − Max`,
fruits preview 0 when EV4074 = 1.)

**自动使用 (auto-use)** [C] — after a unit takes physical (0x405b25) or strategy (0x422a33) damage and survives
(damage > 0, HP > 0): `id = EffQ(108 自动使用, 0x46, 1, 0)` (0x422edf; the 6.6 fix "-422ee6 6A 01" set a3 = 1).
For a player-side unit the item is used only if `U.HP + I.val ≤ MaxHP`. Then (0x416442):
* EV4035 (0x505f0c) ≠ 0 → use without consuming;
* EV4035 = 0: player side → only if the inventory holds it (`byte[0x493af0+id−0xa0] ≠ 0`), consumed;
  AI side → used, nothing consumed.
The item is applied by `UseItem(id, unit, arg=0 (self), consume)`.

### 4.4 Attack items and mines (EV 4089–4093 only gate the shop) [C]
* **Thrown (type 0x41)**: byte 0x500ad7 = 1; range code `I+0x13`, splash-area code `I+0x17` (0x404b46 → 0x406289).
  Damage (0x4361b1): centre cell `val16`, other cells `max(1, val16 * byte[0x500e7c + k] / 100)` (0x407398, `k` =
  cell index; the per-cell % table is filled by the area scan 0x435c10: `max(50, 100 − 10·ring)`, §1.11); each capped at the target's HP. No hit roll
  (preview hit = 100). Strategy-damage function 0x43c01d returns `min(val16, HP)` for this mode.
* **Mines (type 0x40)** placed by 0x40d8dc; detonation 0x42d2d3: same damage rule, the unit standing on the mine
  cell (if any) is the full-damage centre, otherwise every unit uses `byte[0x500e7c + k + 1]`. Remote (0x3f)
  0x40d956; dig up (0x3e) 0x41d03e/0x414a7e returns it to the inventory; detect (0x42) 0x412797.
* EXP: each enemy (side ≥ 2) whose HP is **below** the raw damage adds 24 to the action EXP (0x436201; an exact
  kill, damage == HP, adds nothing). Thrown item: final EXP = max(that, max over targets of PhysEXP) (0x41f91a, 5.2).
  Mine: **every** deployed living player unit (slots 0..19, side 0, state 2, HP low byte ≠ 0) gets
  `SetExp(exp + A.exp)` (0x405157) [G: A.exp is not re-initialised on this path].

### 4.5 Equipment EXP and levels [C]
`EquipExpAdd(slot, add)` 0x4082dd (ECX = person; slot 0 weapon / 1 armour only):
```
id = P[0x2e+3*slot]; if id == 0xff: return
need, maxL = treasure(id) ? (200, 9) : (100, 5)
L = P[0x2f+3*slot];  e = P[0x30+3*slot] + add          # 32-bit sum
while e >= need and L < maxL:                           # signed byte compare
    L += 1; P[0x2f+3*slot] = L; LevelUpMessage(pid, slot)    # 0x4083f9 "武器/护具等级上升！"
    e -= need
P[0x30+3*slot] = 0xff if L >= maxL else (e & 0xff)
```
* Levels: normal 1..5, treasure 1..9 by EXP; 9 → 10 only with 升級寶物符 (item 255, type 0x3d 装备升级, outside
  battle) [D desc]; `max level` helper 0x4201c1 = 10 treasure / 5 normal.
* Gates: `EquipExpEnabled()` 0x403262 = (byte 0x505fdc == 0) or (byte 0x4ce24b == 1) or (byte 0x500af1 == 1).
  Only player-side (U+5 == 0) attackers/casters gain weapon EXP; only player-side targets gain armour EXP.
* All equipment EXP passes `ExpMod(v, person=0)` (0x42104f): `v = v*(100 + (EquipBonus(8) & 0xff))/100`; then
  ×2 if the unit has 精进 (byte `0x501b00[unit]` ≠ 0, player side only, 0x42545f) and ×2 more if byte 0x500e9a == 1
  (围攻 in progress) (0x403d5a).

| source | amount per target (before ExpMod) | where |
|---|---|---|
| weapon, physical strike (summed over targets and strikes, applied once per attack) | weapon must exist and (stat_of_type ∈ {0, 10} or `I+0x14 == 0x18`): `3` if HP or MP damage dealt (`2` if attacker level > target level), `+1` if this attack has crit flag `A+0x604`; `1` if no damage | 0x403870 → `A+0x42c` → 0x406b3c |
| armour, being struck (per strike, player-side target) | `4` if HP or MP damage taken (`3` if attacker level < target level), `1` if none | 0x403a8a → `A+0x430+4k` → 0x405966 |
| weapon, strategy cast | weapon stat_of_type ∈ {2, 10} or `I+0x14 == 0x19`: `3`, `2` if the strategy targets a side (record +0x0b ≠ 2) and caster level > first target's level | 0x421363 → `S+0x506` → 0x422f2e / 0x41a0ac |
| armour, strategy received (player-side target) | `4` if an enemy-targeting strategy (record +0x0b == 0) hurt it (`S+0x108+4k` ≠ 0), `3` if target level > caster level; else 0 | 0x421409 |
| per turn | `EffQ(4 每回合武器exp, 0x73)` / `EffQ(5 每回合护具exp, 0x73)` × (100+EquipBonus(8))/100 | 0x43cddd |

**EV 4039 equipment auto-upgrade** (0x40c990, run when a person is deployed, after unit init 0x44274c) [C]:
`avg = ArmyAvgLevel()` (0x40c231: mean level of persons 0..126 with `P+0x2a ≠ 0xff`, floor, min 1). For weapon and
armour: treasure target `min(avg/6 + 1, 9)`; normal: `tier = avg/20`, target `avg ≥ 60 ? 5 : (avg%20)/4 + 1`
(0x407da3); a normal item whose id is above `byte[0x482427 + type/2] + tier` is left alone, one below it gets target 5.
If target > current level: level = target, exp = (target < maxL and target ≠ 9) ? 0 : 0xff. (Also with EV4039 the
equipment price becomes 8000 (0x453a98).)

## 5. EXP and level-up

### 5.1 Person fields [C]
`P+0x11+2s` stat word s (0 攻击 1 防御 2 精神 3 爆发 4 士气), `P+0x1b` base HP (dword; word-read by MaxHP),
`P+0x1f` base MP (word), `P+0x21+s` raw ability byte, `P+0x2a` army flag (0xff = not in the player's army),
`P+0x2b` class, `P+0x2c` level, `P+0x2d` EXP (0xff = capped), `P+0x2e..0x34` equipment (4.1), `P+0x35` word kill
count, `P+0x27` sorties (+1 per deployment of an army member, 0x44274c) and `P+0x28` victories (+1, 0x44ebe8),
both capped at 255, `P+0x02` 功勋 training bit mask (set by the 功勋 UI [G]).

### 5.2 EXP per action [C]
Action object `A` (0x4927f0 for attacks; init 0x406289): `A+0xc` attacker unit, `A+8` attacker person,
`A+0x10..` target unit list (0xff end), `A+0x84+4k` HP damage, `A+0x254+4k` MP damage, `A+0x428` EXP,
`A+0x42c` weapon EXP, `A+0x430+4k` armour EXP, `A+0x600 = (attacker U+5 == 0)` (only player-side units gain EXP;
friendly AI side 1 and enemies get none), `A+0x604` crit flag, `A+0x608` strike counter.
```
PhysEXP(k)                                   # 0x4037a3, per target k per strike
    lvA = attacker level, lvT = target level, hp = target U.HP (before this strike)
    exp = 0
    if A.dmg[k] >= hp:                       # kill
        if hp > 0: KillHook()                # 0x4290c8: kill count +1 (5.7), 大杀四方 flag
        if not A.player: return 0
        Gain功勋(attacker, all five, 1)       # 0x42a9c4(1)
        if dword U_target[0] == word[0x492f90+0x3d06]: exp += 48       # the battle's designated leader [G meaning]
        else: d = max(lvA - lvT, 0); exp += 64 / (d + 2)               # 32, 21, 16, 12, 10, ...
    if not A.player: return exp              # (0)
    d2 = clamp(lvT - lvA, -1, 47)            # signed byte compare; levels assumed < 128 apart
    exp += 2*d2 + 6                          # 4 .. 100; given even on a miss
    return ExpMod(exp, person=1)             # 0x42104f
ExpMod(v, isPerson)                          # 0x42104f, ECX = gaining person
    v = v * (100 + (EquipBonus(8) & 0xff)) / 100           # 0x407faa (辅助获得Exp)
    if not isPerson or EV4079 (0x505fbc) != 0:
        if 精进(unit): v *= 2                 # 0x501b00[unit] != 0, player side
        if byte 0x500e9a == 1: v *= 2         # 围攻 (surround attack)
    return v
```
* Per attack (all strikes of a double attack included, A is initialised once in 0x4064f1): `A.exp = max(A.exp,
  PhysEXP(k))` over every target and strike (0x40603d); the weapon EXP is the **sum**. After the attack
  (0x406b3c): `SetExp(P.exp + A.exp, show=1)`, `EquipExpAdd(0, A.weaponExp)`. A counter-attack is its own action.
* Strategies: EXP computed by 0x420efb (§2) into `S+0x502`, weapon EXP `S+0x506`; applied the same way
  (0x422f2e / 0x41a0ac: `SetExp(exp + S+0x502)`, `EquipExpAdd(0, S+0x506)`).
* Per turn (0x43cddd, player side): `EffQ(3 每回合获得exp, 0x1d)` × (100+EquipBonus(8))/100 → `SetExp`.
* Items: only 经验果 (4.3), thrown items / mines (4.4). Duels: duel track (0x4498e5).

### 5.3 SetExp and level cap [C]
```
SetExp(total, show)                          # 0x4088cd, ECX = person
    if P.level >= 100: return                # no EXP at level >= 100
    while total >= 100:
        LevelUpAndPromote(1, show)           # 0x408d52
        total -= 100
    P.exp = 0xff if P.level >= 100 else total & 0xff
LevelUpAndPromote(n, show)                   # 0x408d52
    LevelUp(n, show)
    # automatic promotion at level 20/40 exists but is dead code: guarded by `class (signed byte) <= -2`,
    # never true for class ids < 0x80
```
Levels above 100 come only from scripts / LevelUp callers (LevelUp clamps `n = min(n, 255 − level)`).

### 5.4 LevelUp(n, show) — 0x4073f3 [C]
```
n = min(n, 255 - P.level);  P.level += n
for i in 0..6:                               # 5 stats, 5 = HP, 6 = MP
    g = Growth(i)                            # 0x4250b6
    if EV4094 (0x505ff8) != 0 and i <= 4:
        Recalc(i, show=0)                    # 0x43a409, once
    else:
        repeat n times: AddStat(i, g)        # 0x406eca mode 0
    (delta for the level-up window = new value − old)
if P.level >= 100: P.exp = 0xff
if show:                                     # always shows the window; EV4062 is NOT read here
    level-up window (0x44cfc8), sound 0xb
    for strat in 0..143: if class learn level (strategy +0x11+class) == level, or the person's own entry in
        table 0x507800 (0x40de69) has learn level == level: "学会了策略「%s」！"
    if EV4059 != 1: for k in 0..26: newly learnt 必杀 → "领悟必杀技「%s」！" (0x41bce6; §1 必杀)
```
LevelUp does not touch the unit's current HP/MP.
```
Growth(i)                                    # 0x4250b6 (ECX = class id)
    c = class[2+i] + Adj(i)                  # class record 0x23 bytes at 0x4a2a27 (0x41b782/0x40dbae)
    if i > 4: return c                       # HP: class[7] (4..10), MP: class[8] (1..3) per level
    a = Grade(i) + Adj(i)                    # 0x4072f2
    return max(c + a, 0) >> 1                # class grades are 1..10 (data: 2/4/6/8/10)
Grade(i)                                     # 0x4072f2, raw = P[0x21+i]; "能力分檔" patch 0x407301..0x407321
    raw >= 99 (unsigned) -> 10;  >= 90 -> 8;  >= 70 -> 6;  >= 50 -> 4;  else 2
Adj(i)                                       # 0x436e3d: per-person growth tweak, table 0x507ec0
    # sections "ff <stat>" then 3-byte entries [s8 delta][u16 person id]; delta < 0 is stored off by one
    # (value+1 is used). Default table is empty for every stat -> Adj = 0. Note Adj is applied to both terms.
AddStat(i, v, mode)                          # 0x406eca (ECX = person)
    i <= 4:  P.stat[i] = MinAdd(mode==1 ? 0 : P.stat[i], v, 9999)
    i == 5:  P.hpBase  = MinAdd(P.hpBase, v, 9999)     (dword; mode ignored)
    i == 6:  P.mpBase  = MinAdd(P.mpBase, v, 9999)     (word)
    i 10..14: raw[i-10] = MinAdd(raw, v, 100)
    i == 15: byte[0x501a84 + unit] = v (if the person is on the field)
    i 7, 8:  0x45aa37(pid, i, v, 1, 0) with byte 0x505f30 (EV4044) = 1 (current HP/MP op); i == 9: nothing
```
No randomness anywhere in level-up (6.6 has no growth jitter). There is no "min 1" floor: a computed growth of 0
adds 0. Stats cap 9999; base HP/MP cap 9999 on level-up (but HP上升/MP上升 items store up to 0xffff).

**EV 4094 recalculation** (player option "升級時能力會重新計算"; default 0 = "壓級練果") [C]:
```
Recalc(s, show)                              # 0x43a409
    v = GrowthSum(s) + raw[s] + Bonus(s)
    if P+0x2a != 0 or v > P.stat[s]: P.stat[s] = v (mode 1, cap 9999)   # never lowers an army member's stat
    if show and in battle and EV4022 (0x505ed8) == 0: buff level U[0x18+s] = (≥3 ? 6 : 3)  (0x414361)
GrowthSum(s)                                 # 0x408a60 (+0x4115d7); G_c(s) = Growth(s) with class c
    cls = P.class; L = P.level; tier = cls <= 59 ? cls % 3 : 0
    c = cls; sum = 0
    if tier == 2 and L >= 30: c -= 1; sum += G_c(s)*15; L -= 15
    if tier >= 1 and L >= 15: c -= 1; sum += G_c(s)*15; L -= 15
    return sum + G_cls(s)*L
    # tier 2, L >= 30: 15*G(cls-1) + 15*G(cls-2) + (L-30)*G(cls); tier 2/1 with 15 <= L: 15*G(cls-1) + (L-15)*G(cls)
Bonus(s)                                     # 0x41055d: person id < 102 and P+0x2a == 0:
    return s16 word[0x508400 + 14*pid + 2*s]     # stat boosts recorded by scripts / HP上升 items; else 0
```
(Fruits call `Recalc` too when EV4094 ≠ 0.)

### 5.5 Class promotion [C]
Engine promotion only through item type 0x27 兵种上升 (印绶) or callers of 0x41d468; script command 52 changes class
separately (EV4081 decides recalculation [D]).
```
CanPromote(P)                                # 0x41d3dc
    cls > 59                 -> "这是不能提升兵种的部队。"
    cls % 3 == 2             -> "不能再提升兵种了。"
    P.level < (cls%3 + 1)*15 -> "下一个兵种需要等级%u以上。"          # 15 for tier 0->1, 30 for 1->2
Promote(P)                                   # 0x41d468
    P.class += 1
    for i in (5, 6): AddStat(i, PromoBonus(i))
    unit HP/MP = MaxHP/MaxMP (0x41a0df); message "%s的兵种提升为%s！"
PromoBonus(i)                                # 0x413fac(i, P, 1)
    if P+0x2a == 0xff or new class > 59 or tier == 0: 0
    else 2 * (class[2+i] + Adj(i)) of the NEW class
```

### 5.6 Fruits and stat caps [C]
Fruit (type 0x21+s, 0x41d14a): `v = I.val` (2 in data); `P.stat[s] = MinAdd(P.stat[s], EV4074 ? 0 : v, 9999)`;
`raw[s] = raw[s] >= 110 ? raw[s] : ByteAddCap(raw[s], v, 110)` (0x423e93/0x404df7; both caps are the patched
0x6E at 0x423e9d / 0x423ea1 — fruits never lower a raw ability above the cap); if EV4094: `Recalc(s)`.
Caps: stat word 9999; raw ability 110 (fruits, 功勋 conversion 0x42ac98); base HP/MP 9999 (level-up) / 0xffff
(items); MaxHP ≤ 0xffff, MaxMP ≤ 9999, move ≤ 127.

### 5.7 Kill count and derived-stat bonuses [C]
* Kill count `word P+0x35` += 1 when a player-side unit's physical/thrown strike kills (0x426ba0; not while byte
  0x505fdc ≠ 0). Also `EffQ(64 大杀四方, 0x54)`: if `U+0x24 < value` → `U+0x24 |= 0x80` (re-action, §1).
* `KillBonus(k, v)` 0x405b86 (EV4046 0x505f38 ≠ 0, player option "殺敵數加成"): `k == 0x7f`: `v + (kills ≥ 100)`;
  else `v + Pct(kills/k, v)`. Used with k = 30 for the five stats (BaseStat), 15 for HP/MP max, 0x7f for move.
* `BaseStat(s)` 0x43c4d3: `b = KillBonus(30, P.stat[s]); if EV4073 (0x505fa4) and raw[s] > 100: b += Pct(raw[s]−100, b);
  return min(b, 9999)` (破百加成). Person stat = `min(BaseStat(s) + EquipBonus(s) + adj, 9999)` (0x40715a..0x40722e;
  adj ≠ 0 only with 神魔附体). `MaxHP = MinAdd(KillBonus(15, word P+0x1b), EquipBonus(5), 0xffff)` (0x407263);
  `MaxMP = MinAdd(KillBonus(15, P+0x1f), EquipBonus(6), 9999)` (0x40728f);
  `Move = MinAdd(EquipBonus(7), KillBonus(0x7f, class.move), 127)` (0x4072bb).
* Difficulty multiplier (0x4200a2, end of the battle-stat chain 0x414ccb): side ≥ 2 → `Pct(EV4033, stat)`, side 1 →
  `Pct(EV4034, stat)`, side 0 (player) unchanged; 0 = off. (Belongs to §1; noted here because the 许子将 options set it.)

### 5.8 功勋 (merit) system [C]
Player options (R_072): 功勋模式 sets EV4047 = 1 (shared pool), EV4055 = 0, EV4073 = 1, EV4074 = 1, EV4075 = 1.
* Storage: 5 words per person at `0x508000 + 10*pid` (one per stat), only for person id < 102 with `P+0x2a ≠ 0xff`
  (0x42acd2; enemy growth passes force = 1). Shared pool = EV4048 (0x505f40).
* `Gain(n, P, s)` 0x42ab8e (skipped if `raw[s] == 0xff`):
  `m = (byte 0x500e9a == 1 ? (byte 0x505fdc == 0 ? 2n : (EV4055 != 0 ? none : n)) : n) + EffQ(69 获得功勋, 0x3a)`;
  `+ n` more if the unit has 精进; `word += m` (16-bit, wraps).
* Earning events: attacker +1 attack per target per strike (0x422dde); +1 爆发 per follow-up strike
  (`A+0x608 ≥ 1`) and +1 士气 while the crit flag is set (0x40dc5c, per strike); target +1 防御 per strike and +1 爆发
  when it took no HP/MP damage (0x42a96d); player kill +1 to all five (0x42a9c4); strategy caster +1 精神 (0x411892);
  victory (0x44ebe8, result byte == 2): every unit 0..34 in state 2 whose person is in the army gets
  `4 * (maxTurn − turn)` (byte subtraction, 0x44efdf) in all five; 获得功勋 item (4.3).
* Conversion `Convert(P, s)` 0x423f4b (only EV4074 ≠ 0 and bit s of `P+0x02` set):
  `cost(raw) = raw < 80 ? 50 : (raw − 79)*10 + 55` (0x42ac8f; raw ≥ 110 → never);
  if `功勋[s] ≥ cost`: `功勋[s] −= cost; raw[s] += 1; Recalc(s, show=1)` — one point per trigger (repeats only while
  byte 0x501a74 ≠ 0). Triggers: after each attack for the attacker s ∈ {0,3,4} (0x42ab32(0)), after damage for
  each target s ∈ {1,3} (0x42ab32(1)), after a strategy s ∈ {2} (+4) (0x41d238). With EV4022 = 0 a conversion in
  battle also sets the stat's buff level to 6 (or back to 3 if debuffed).
* Victory with EV4047 (0x408fa0): for persons 0..101, each stat whose `P+0x02` bit is clear moves its 功勋 to the
  pool; spending the pool is UI (0x456cb4/0x456da6) [G].
* Enemy growth EV4075 (0x46206c(pid, 50, mode)): counter `byte 0x5083fc` += 1 per victory (0x40badd, cap 255).
  `pool = counter*50`; for each stat s: `while cost(raw[s]) ≤ pool and raw[s] < 110: pool −= cost; raw[s] += 1;
  P.stat[s] += 1` (pool restarts at counter*50 for every stat). Applied when a unit is placed by 0x42ad35 (mode 1,
  scripted deployment [G]; mode ≠ 2 first reloads the person record via 0x41b617 [G]) and when a person's army flag
  changes (0x4095b9, mode 2, counter temporarily reduced by the value recorded at his last change [G]); for mode ≠ 1
  the leftover pool is added to his 功勋 store (0x42acd2 force).

### 5.9 Levels of AI units and the bench [C]
* Deploy level (scripts, 0x41240b → 0x4123c8): `ref = max(1, mean of the 4 highest levels among deployed players
  (0x4184dd) + s8 byte 0x501bf4)`; script level `L ≤ 100` → `ByteAddCap(ref, L, 100 + N)`; `L > 100` →
  `max(ref − (L−100), 1)` (byte math). `N = 10` for enemies (operand at 0x407fc7) and friends (0x419b69) — the
  "高N級" patch.
* Bench auto-level (option "板凳自動升級", script ext command, 0x406cfa): repeat until stable: every army person
  0..126 below `ArmyAvgLevel()` gets `LevelUp(avg − level, show=0)`.
* EV4095 = 0: a revived unit's SP is reset to 0 (0x4277e6).

## 6. Movement, terrain and weather

Conventions for this section: `EffQ(I, item, a3, a4)` = the effect query 0x4101d9 with its four stack arguments in
call order (`I` = personal 特效 id, name table 0x4cc600 = I-table; `item` = the matching item-effect code); it returns
the effect value (0 = absent). The catalogue of effects is in docs/skills.md; names below are the I-table names.
`side(u)` = 0x406710: `T[u+5]` with `T = 0x40672d = [1,1,0,0,2,1,1]`, index +1 when `u+5 == 3` and EV 4053 ≠ 0
(so player/ally = 1, enemy = 0, enemy reinforcements = 2 when EV 4053 「援军和敌军对攻」 is on) [C].
Unit slots: 0..19 player, 20..59 ally, 60..249 enemy (0x45b771, 0x42e2ed) [C].

### 6.1 Move points

**Person move 0x4072bb** (ecx = person) [C]:
```
pmove = min(EquipBonus(7) + class[person+0x2b].move + kb, 127)      # 0x47fa89 (signed min), class.move = class rec +0 (0x41b782/0x41edef)
kb    = (EV4046 != 0 and person.kills(u16 +0x35) >= 100) ? 1 : 0     # 0x405b86(0x7f, move); EV 4046 = 0x505f38 杀敌数加成
```
**Unit move 0x43f74f** (ecx = unit) — this is the value the range search and CalcDamage use [C]:
```
m = pmove(person(unit))
if unit.status paralysis count (unit+0x1e bits 0-1) != 0: return 0         # 0x423fe8(2)
lv = unit+0x1d                                                              # move buff level, 3 = normal
if lv >= 4: m = min(m + 2, 255)        # 0x47fab5
elif lv != 3: m = max(m - 2, 0)        # 0x47fad0 (lv 0..2)
return m
```
Other callers substitute: the AI move 0x43ad3b uses `m = 100` when unit flag `+0xd & 0x80` is set [C].

**Note for §1 (CalcDamage 0x43bd8e)** [C]: `0x413260` = `EffQ(0x75 疾风攻击, 0x4c, 1, 0)` on the attacker (value v);
`0x43f74f` is the defender's unit move above. If `v != 0` and `(int8)(move_def − v) < 0`:
`dmg += dmg * ((v − move_def) * 5) / 100` (0x425ad9) — 疾风攻击: +5 % per move point the target is below v.

### 6.2 Terrain types and the family table

Terrain ids (names 0x48bdb0[34]): 0 平原 1 草原 2 树林 3 荒地 4 山地 5 岩山 6 山崖 7 雪原 8 桥梁 9 浅滩 10 沼泽
11 池塘 12 小河 13 大河 14 栅栏 15 城墙 16 城内 17 城门 18 城池 19 关隘 20 鹿砦 21 村庄 22 兵营 23 民居 24 宝物库
25 水池 26 火 27 船 28 祭坛 29 地下 (30 地雷 31 战壕 32 掩体 33 工事 have names but no column in the family table).

Family record (Data.e5 e4, 40 × 60 bytes, memory 0x4a3517 + fam·0x3c, getter 0x41b7d2) [C]:
bytes 0..29 = terrain effect **percent** per terrain (0x41f62a); bytes 30..59 = move cost per terrain (0x4060c4),
0xff = impassable. Family of a unit = 0x43b4a7 (class ≤ 59 → class/3, 60..79 → class − 40, else 40). Examples
from the shipped Data.e5: 步兵 costs `1 1 1 1 2 ff ff 1 1 2 2 ff ff 1 ff ff 1 ff 1 1 1 1 1 2 1 ff…`, 飛行者 (family
25) cost 1 everywhere except 26 火 / 28 / 29 = ff and effect 100 everywhere.

**Map terrain lookup 0x435991(pos)** [C]: `x >= W([0x4b422c]) or y >= H([0x4b422d])` → 0xff; else 0x412557:
`t = map[0x640 + x + y·W]`; if a unit stands on the cell (`map[0xc80 + idx] != 0xff`) and that unit has
`v = EffQ(0xab 万里龙城, 0x2a, 0, 0)` with `v & 4` → the cell reads as **19 关隘**.

### 6.3 Terrain cost and terrain effect: TerrainPct 0x43f7b8(t) (ecx = unit) [C]

Returns **AL = move cost** and **EDX = terrain effect percent** for the unit's family. Argument `t < 30` = that
terrain; `t = 0x1e` = the unit's own tile (AI "virtual position" 0x48e8c2 used instead when it is set and EV 4065
AI地形利用 ≠ 0 and the unit is not player-controlled — 0x407bf6), `t = 0x20` = always the real tile.
```
fam = UnitFamily(unit)
if EV4087 (0x505fdc) != 0: return AL=0xff, EDX=100          # terrain ignored, nobody can move (练武场 duel modes) [D for meaning]
if fam >= 40:              return AL=0xff, EDX=0
eff  = family[fam].effect[t]                                  # percent
cost = family[fam].cost[t]                                     # 0x412b5f, includes the pin rule below
if cost != 0xff:
    # 龙巡四海 / 虎啸山林 (0x435bb1): a = EffQ(0xa9,0x2a,0,0), b = EffQ(0xaa,0x2a,0,0)
    # C[t] = 0x435bf2[t] = 2 for t 2..6 (树林 荒地 山地 岩山 山崖), 1 for t 7..13 (雪原 … 大河), else 0
    if (a & C[t]) or (b & C[t]): eff = max(eff, 120)            # tested a first, then b
    if a != 0 or b != 0: cost = 1                               # any terrain, also overrides the pin cost 0x80
if EffQ(0x3e 辅助地形状态, 0x2a, 1, 1): eff = max(eff, 110)     # 0x478e39
if EffQ(0x3f 恶路移动, 0x2a, 1, 1) and cost != 0xff: cost = 1   # 0x478e4b
if [0x500ad3] != 1 and EffQ(0x36 穿越移动, 0x5d, 1, 1):         # 0x403a6f ([0x500ad3]=1 only during knock-back / forced moves)
    if cost >= 0x80: cost = 1       # impassable (0xff) and pinned (0x80) become 1
    elif cost > 1:   cost -= 1
return AL=cost, EDX=eff
```
**Pin (左天羅右地網) 0x412b5f(t, unit)** [C]: unless `unit+0xd & 0x80`, if any of the 4 orthogonal neighbours of the
unit's *current* position holds a unit with `side() != side(unit)` and `EffQ(0x60 左天羅右地網, 0x7a, 1, 1) != 0`,
then `cost = max(cost, 0x80)` for every terrain. Because cost ≥ 0x80 exceeds any move, a pinned unit cannot move
(unless one of the cost-lowering effects above applies).

**Terrain effect on combat** [C]: StatPair 0x40d2ab (physical, last arg 0) multiplies attack by
`TerrainPct(0x1e).EDX / 100` of the attacker and defence by `TerrainPct(0x20).EDX / 100` of the defender
(0x40c7c8: `v * pct / 100`, unsigned). Details in §1.

### 6.4 Movement range search 0x438484 [C]

`MoveSearch(start=&unit+6, move, flags, tx, ty, mode)` (ecx = unit; stdcall, 6 args). Distances go to the map
scratch layer `map + 0x12c0` (W·H bytes, filled with 0xff). Player move display (0x43d4fc) calls it with
`move = UnitMove, flags = 0, target = (ff,ff), mode = 1`; the AI uses other flags (early exits, below).
Neighbour order (0x4359f5, table 0x435a3e): **0 up (0,−1), 1 right (+1,0), 2 down (0,+1), 3 left (−1,0)**.

```
zoc   = mode & 1                      # mode 1 = normal move with stop cells
free  = (unit+0xd & 0x80) != 0        # 0x425af0(0x80)
if pos(start) == (tx,ty): return 0xff
dist[*] = 0xff; dist[start] = 0
if TerrainPct(terrain(start)).cost == 0xff: return 0xff          # unit stands on impassable ground: no move
L = 0
loop:
    if no progress in the previous pass: return 0xff
    if L >= move: return 0xff
    for y in 0..H-1: for x in 0..W-1:                              # row-major scan
        if dist[x,y] != L: continue
        if zoc and (x,y) != start and StopCell(unit, (x,y)): continue   # 0x437d59 — may be entered, not left
        for dir in 0..3:
            n = (x,y) + delta[dir]; skip if off the map
            skip if [0x501bf0] != 0 and n outside its rectangle {x0,y0,w,h}   # 0x4362e6, script-set move limit
            skip if dist[n] != 0xff                                 # FIRST ASSIGNMENT WINS (no relaxation)
            c = TerrainPct(terrain(n)).cost; skip if c == 0xff
            skip if L + c > move                                    # signed compare
            if move != 0xff and flags != 0 and mode != 3 and not AiAreaOk(unit, n): skip   # 0x4077f6 (AI leash)
            o = unit at n (map + 0xc80)
            if o != 0xff and mode != 2 and not 穿越移动(unit):        # 0x403a6f, see 6.3
                if Hostile(unit, o):                                 # 0x42e2b7, below
                    if zoc or not free: skip                         # enemies block
            dist[n] = L + c
            # early exits used by the AI: flags&8 → return slot of a state-2 unit recorded at n in grid 0x40154a
            # (when n is empty); flags&2 → return 1 if n == (tx,ty); flags&4 → return 1 if 0x405da7(n) == 1
    L = smallest dist value > L present on the map (cells that are StopCells and were assigned earlier in the
        same pass are not candidates, which never changes the result)
```
Because a cell keeps the first distance written to it, the result depends on the scan order (levels ascending,
row-major, neighbours up/right/down/left); with terrain costs 1–3 this is **not** a true shortest path. The port
must reproduce the loop exactly. Reachable cells = `dist != 0xff`; friendly units may be passed through.
A destination is valid (0x43fc7f) when the cell is empty or holds a unit in state 1 (hidden), and its cost for
the unit is not 0xff.

**Hostile(a, b) 0x42e2b7** [C]: `G(a) != G(b)` where G = table 0x42e2e5[EV 4019]: EV 4019 = 0 (default) → side()
0x406710; EV 4019 = 1 (「深入敌后 超级卡位」) → 0x42e2ed: slots < 20 → T[0], 20..59 → T[1], else by u+5 (5/6 count
as player side while the enemy-control counter 0x501ad8[slot] ≠ 0), T = 0x40672d.

**StopCell(unit, cell) 0x437d59** — entering is allowed, expanding is not [C]:
```
m = (unit+0xd & 0x80 == 0 and unit+0xe == 7) ? 4 : 0               # player-controlled
if Trap(cell, trigger=0, m) != 0: return true                       # 0x428b7a
if 穿越移动(unit) (0x403a6f) or EffQ(0x37 突击移动, 0x29, 1, 1) (0x472c65): return false
return any orthogonal neighbour of cell holds a unit o with Hostile(unit, o)        # zone of control
```
Trap 0x428b7a / 0x428a53 / 0x4749b5 [C structure, G meaning]: for player-controlled units entering an *empty*
cell, count enemy units (side() differs, state 2, HP > 0) with `v = EffQ(0x52 先制攻击, 0x51, 0, 0) > 0`,
`o+0x22 < v` and the cell inside o's attack area (0x428b1f) — 先制攻击 interception (when actually moving,
`trigger=1` makes them attack (0x43db23), increments o+0x22 and stops the mover). If the count is 0, mines are
checked: table 0x510000 + 2·(x + y·(W−1)) (sic), family 25 飛行者 never triggers; mine owner/visibility checks
0x4103bb / 0x422663 (modern-war maps, EV 4093).

### 6.5 Weather [C]

State in the battle object 0x4b3d08: `+0x11` climate (0..4), `+4` level (0..5), both set by the battle-settings
script op. Shown weather (0x41553b) = `0x48e100[climate·6 + level]`, ids **0 晴 1 阴 2 雨 3 暴雨 4 雪**:
```
climate 0: 0 0 0 1 2 3    climate 1: 0 0 0 0 1 2    climate 2: 0 1 2 2 3 3
climate 3: 0 0 1 1 4 4    climate 4: 0 1 4 4 4 4
```
Update **0x449f91(w)**: `if w < 6: level = w` (weather strategies) else random walk:
```
r = rand(8); c = level + 1
if c > r: c -= 1  elif c < r: c += 1
level = 5 if c == 0 else 0 if c == 7 else c - 1
```
(P(level−1) = (level+1)/8 with wrap 0→5, P(same) = 1/8, P(level+1) = (6−level)/8 with wrap 5→0.) Called with
w = 0xff at the top of every round except the first and except the round resumed from a save (0x44ef7b). If the
shown weather changed, the weather banner is animated. "Bad weather" checks elsewhere test `weather > 1`
(雨 暴雨 雪) — strategy restrictions and the +25 % fire/wind strategy terms are in §2.

### 6.6 Terrain regeneration (values used by §7.4) [C]

`RegenPct(pos)` 0x428a25 → 0x41e467: terrain 18 城池 → 25, 19 关隘 → 20, 20 鹿砦 → 20, 21 村庄 → 15,
22 兵营 → 20, everything else 0 (after the 万里龙城 override of 6.2). The same number is used as % of max HP and as
**flat** MP points.

## 7. Turn housekeeping

### 7.1 Round and phase structure [C]

Battle object `B = 0x4b3d08`: `+1` result (0 = running), `+2` round counter (0-based; shown as +1), `+3` round
limit, `+0x10` phase (0 player, 1 ally, 2 enemy), `+0x504` "re-sort action order" flag.

Round loop **0x44eee5(resumed)**:
```
loop:
    if B+1 != 0: break
    if B+2 >= B+3:                                       # out of rounds
        message; the unit of person 0 among slots 0..59 (else slot 0 if on the map) is removed (0x441744(0,0))
        B+1 = 3; break
    if not resumed and B+2 != 0: WeatherUpdate(0xff)     # 0x449f91
    PlayerPhase(resumed)                                 # 0x44ed7f, then ally + enemy phases (0x44e825)
    resumed = 0
    if B+1 == 5: (save-and-quit path) ; else B+2 += 1
end: 0x44ebe8((B+3 − B+2) · 4)                           # end-of-battle 功勋 bonus = remaining rounds × 4 (§5)
```
**Player phase 0x44ed7f**: banner; `B+0x10 = 0`; event check 0x44c601; unless resumed: `if EV4077 != 2: EV4077 = 0`;
**TurnStart(0)** (slots 0..59, i.e. player *and* ally units); refill the two 52-entry pseudo-random decks
0x508998 (0x423490: 104 × `rand(100)+1`); then the player command loop.
**AI phases 0x44e825**: ally phase (`B+0x10 = 1`, slots 0..59) then enemy phase (banner, `B+0x10 = 2`,
`if EV4077 != 2: EV4077 = 1`, **TurnStart(1)** for slots 60..249). Each AI phase computes the action order
(7.5), then runs two passes (`[0x500c47]` = 0, 1) over order index 0..249, letting each state-2 unit with that order
act if `unit+0xe != 7` (not player-controlled) and its flags `+0xd & 4`, `& 2` are clear. Player units whose AI
code is not 7 therefore act in the ally phase. The ally phase has no turn-start processing of its own.

### 7.2 TurnStart(phase) 0x44ee30 — order of processing [C]

Range = slots 0..59 for phase 0, 60..249 for phase 1.
1. `0x42fc0c` timed strategy-effect list 0x512dc0 (4-byte entries `{u8 kind, u8 turns, u16 person}`, written by
   strategy code 0x42fd09 / 0x42fd47 — §2): for entries with `1 ≤ turns ≤ 99` whose person's unit (0x43e4d6)
   has `side() & 1 != phase` (i.e. the owner's side is starting its phase): `turns == 1` → roll
   `Chance(a, 1)` with that unit's buff-fade chance a (7.3); on success message 0x2f and `turns = 0`; `turns > 1`
   or no unit on the map → `turns -= 1`.
2. For each unit in range: **StatusTick** 0x4263b0, then **BuffTick** 0x43c940 (7.3).
3. `0x420952`: clear the per-unit "times attacked this phase" counter `0x508a00[slot]` for the *other* side's
   slots (incremented once per strike aimed at the unit, misses included, 0x40608a, saturating at 255; read by 仇恨攻击
   for the attacker's own slot, §1.5).
4. **Poison** 0x44dfc7 for each unit in range (7.4).
5. **Regen** 0x43cddd for each unit in range (7.4).

### 7.3 Status and buff ticks [C]

Status byte `unit+0x1e`: 2-bit turn counters, 麻痹 bits 0-1, 禁咒 2-3, 混乱 4-5, 中毒 6-7; status mask for
0x423fe8: 2 麻痹, 4 禁咒, 8 混乱, 0x10 中毒. Buff levels `unit+0x18..+0x1d` (攻 防 精 爆 士 移): 0..2 debuff,
3 normal, 4..6 buff (auto-buffs set 6).

Recovery chances (0x43c72c, luck = raw ability 4, person+0x25):
```
a (buff fade)       = luck > 100 ? 10 : 60 − luck/2            (k = 0)
b (status/debuff)   = EffQ(2 每回合恢复状态, 0x1c, 1, 1) ? 100 : luck >> 1     (k = 1)
```
`Chance(p, mode)` 0x43786b: if `mode == 2` or EV 4077 ≥ 2 → `rand(100) < p`; else pseudo-random:
`r = deck draw` (0x455e25, stream `k = EV4077`: index byte 0x501bf6+k, value `0x508998[k·0x34 + idx]` (1..100),
idx cycles 0..0x33), `p = min(p,100)`; mode 1 → `r >= 100 − p`; mode 0 → `p >= r`.

**StatusTick 0x4263b0** (state 2 and status ≠ 0 only):
```
if any of the 8 surrounding cells (dirs 0..7: N E S W NE SE SW NW) holds a state-2 unit of the same side() with
   EffQ(0x64 健康光环, 0x7b, 1, 1):  cure all four statuses (0x45aa37(…, 6, 0x9e, …))          # 0x43d16a
else for i in 0..3 (麻痹, 禁咒, 混乱, 中毒):                                                  # 0x42402c(unit, b)
    cnt = (status >> 2i) & 3; if cnt == 0: continue
    if b >= 100: cure i
    elif cnt > 1: cnt -= 1
    else:   # cnt == 1, EV 4023 负面状态恢复模式
        EV4023 == 0: cure if Chance(b, 0)
        EV4023 == 1: r = deck draw (index 0x501bf6, values 0x508998+0x34); cure if b >= r and r != 0
        else:        cure
```
So a status set to 3 lasts at least 2 turn starts, then each turn start it ends with chance b.

**BuffTick 0x43c940** (state 2 only), for each of the 6 levels:
```
lv == 3: nothing
lv >= 5: lv -= 1                                   # 6 → 5 → 4 unconditionally
lv == 4: if Chance(a, 1): lv = 3                   # 0x45aa37(person, i, 3, 1, slot)
lv <= 2: if b == 100: lv = 3
         elif lv < 2: lv += 1                       # 0 → 1 → 2 unconditionally
         elif Chance(b, 0): lv = 3
```
Then two counters: **精进** (player-side units, `u+5 == 0`): `c = 0x501b00[slot]`; `c > 1 → c −= 1`;
`c == 1 → if Chance(a,1): c = 0` (message 0x2f). **Enemy control** (slots ≥ 60): `c = 0x501ad8[slot]`;
`c > 1 → c −= 1`; `c == 1 →` always ends (Chance(100,0)): message 0x2c, 0x4073bc restores the unit. (Both set by
strategies, §2.)

### 7.4 Poison, regeneration, per-turn effects [C]

**Poison 0x44dfc7 → 0x44e024(unit, 20, show)**, for each state-2 unit in range with a 中毒 count ≠ 0:
`d = max(MaxHP·20/100, 1); if HP <= d: d = HP − 1; HP −= d` — poison never kills.

**Regen 0x43cddd(unit)** (state 2 only):
```
AutoAuras(unit)        # 0x42f8d9: Buff光环 EffQ(0x97+i, 0x7f, 3, 0) i=0..5 (bit masks, ORed),
                       # HP光环 EffQ(0x65,0x52,0,0), MP光环 EffQ(0x66,0x53,0,0), SP光环 EffQ(0x67,0,0,0),
                       # 诅咒光环 EffQ(0x68,0,0,0): area effects cast at turn start (semantics: §2 / skills.md)
AutoBuffs(unit)        # 0x43d038: for i in 0..6: v = EffQ(0x90+i 自动提升, 0x66, 3, 0);
                       #   v == 0x3f → if any level ≤ 3: set all 6 levels to 6 (message 0x26), stop;
                       #   else for each bit j (0..5) of v with level j ≤ 3: level j = 6 (0x414361)
maxhp = MaxHP(person); t = RegenPct(unit pos)
hp = maxhp·t/100 + maxhp·EffQ(0 每回合恢复HP, 0x25, 0, 0)/100           # each term truncated
mp = t + EffQ(1 每回合恢复MP, 0x1b, 0, 0) + EffQ(0x32 MP防御, 0x44, 0, 0)  # flat points
if poisoned: hp >>= 1; mp >>= 1                                          # 0x423fa1
sp = EffQ(0x69 每回合恢复SP, 0, 0, 0); if sp: sp = SpAdd(unit, sp, 1)    # 0x423930: SP[person] (0x501c00) =
                                                                         #   min(SP+sp, 255), returns the gain
if unit+5 == 0 (player side):                                            # per-turn EXP, 0x43cedd
    g_k = EffQ(3+k, [0x1d,0x73,0x73][k], 0, 0) · (100 + EquipBonus(8)) / 100     # k: 0 person, 1 weapon, 2 armour
if any gain > 0: show the numbers (0x450986)
HP = hp > 0 ? min(HP + hp, maxhp) : HP;  MP = mp > 0 ? min(MP + mp, MaxMP) : MP
person exp: 0x4088cd(exp + g_0, 1)  (level-up handling §5); weapon exp 0x4082dd(0, g_1); armour exp 0x4082dd(1, g_2)
```
(SpAdd with flag 0 — used elsewhere — gives nothing to persons > EV 4030, default 200.)

### 7.5 Action order of AI units 0x44da7a(side) — rules part [C]

`side ≠ 0` → slots 0..58 (sic: slot 59 is never ordered), `side = 0` → slots 60..249. All orders (`unit+0xb`)
are reset to 0xff, then passes k = 0..8 give consecutive numbers (0, 1, 2, …) to on-map units still unordered, in
slot order:

| k | units taken | notes |
|---|---|---|
| 0 | can release 必杀 (0x4225fb: SP ≥ need, not 禁咒) | family attr row 8 (0x4d2200) == 9 (都督) → order 0x75 instead (全体回归必杀 last) |
| 1 | standing on a regen tile (RegenPct ≠ 0) | |
| 2 | dying: HP ≤ MaxHP·2/5 (person < 0x400) or HP ≤ MaxHP/5 (generic ≥ 0x400, except class 0x31) | 0x439cfe |
| 3 | EV 4063 = 2: custom priority 0x44dccc[family] 0..5 (all remaining, by priority), then jump to k = 8; otherwise: family row 5 (0x4d2188) ≠ 2 (casters/commanders), except family 9 医师 | |
| 4 | EV 4063 ≠ 0: class attack growth ≥ 4 or defence growth ≥ 4 ("S" grade) | skipped when EV 4063 = 0 |
| 5 | family row 3 (0x4d2138) ≠ 0 (ranged) | |
| 6 | family row 1 (0x4d20e8) == 0 | |
| 7 | everyone left | |
| 8 | units holding 0x75 | |

### 7.6 Defeat, retreat, revival [C unless tagged]

* After each action 0x40502b removes every state-2 unit with HP 0: **0x441744(0, 0)** → retreat animation
  (person 0 / protagonist gets a camera move and a different animation), `unit+0xc = 3`, status byte = 0,
  units that targeted it get AI target 0xff / mode 1, and for persons in the player's army (`person+0x2a != 0xff`)
  `person+0x29 += 1` (retreat counter, ≤ 0xff). The engine never kills a person permanently; 撤退 / 阵亡 lines and
  consequences are scripted [G], except duels (EV 4082, docs/duel.md).
* Battle results: B+1 = 3 on running out of rounds; victory/defeat conditions are checked by 0x44c601 (scripts).
* (Re)appearance by script op 0x4092c0 → 0x4277a9: `SP[person] = 0` unless EV 4095 ≠ 0 (复活保留SP); a unit with
  HP 0 also gets its pseudo-hit state `0x4930c8[slot]` reset to EV 4017 in all four bytes; enemy slots clear
  `0x501b14[slot−60]`.
* Summoned units (召唤术, §2): EV 4080 = 0 lets a summon whose earlier copy is no longer on the map be summoned
  again; 1 forbids it (0x426616).

## 8. Configuration EVs and patched constants

### 8.1 Config EVs read by battle code [C reads; defaults = the exe's values at 0x505ec0..0x505ffc]

EV n lives at `0x502000 + 4n` (u32; several readers look at the low byte only). Scenario scripts may change them.

| EV | Address | Default | Effect in battle | § |
|---|---|---|---|---|
| 4017 | 0x505ec4 | 0 | hit roll: rate < EV4017 always misses when EV4018 > 1; initial value of the 集气 accumulators | 1.4 |
| 4018 | 0x505ec8 | 0 | 0/1 = no thresholds; 1 = deterministic 集气 accumulator rolls; ≥ 2 = rate ≥ EV4018 always hits | 1.4, 2.6 |
| 4019 | 0x505ecc | 0 | hostility function for ZOC / blocking (深入敌后 超级卡位) | 6.4 |
| 4022 | 0x505ed8 | 0 | 0 = an in-battle stat recalculation / 功勋 conversion also sets the buff level | 5.4, 5.8 |
| 4023 | 0x505edc | 0 | status recovery at count 1: 0 roll, 1 deck, 2 always | 3.3 |
| 4030 | 0x505ef8 | 200 | persons with id > this gain no SP (except forced gains) | 1.13 |
| 4033 / 4034 | 0x505f04 / 0x505f08 | 0 / 0 | battle-stat multiplier % for enemy/援 (`u+5 ≥ 2`) / ally (`u+5 == 1`) units; 0 = off | 1.3 |
| 4035 | 0x505f0c | 0 | 自动使用: 0 consumes the item, 1 free | 4.3 |
| 4039 | 0x505f1c | 0 | equipment auto-upgrade on deployment | 4.5 |
| 4046 | 0x505f38 | 0 | kill-count bonuses (stats +1 %/30 kills, HP/MP +1 %/15, move +1 at 100) | 5.7 |
| 4053 | 0x505f54 | 0 | 援军 (`u+5 == 3`) is a third side | 1.0 |
| 4059 | 0x505f6c | 0 | ≠ 0: no 武将技/军师技; == 1: also no SP gain and no "领悟必杀技" at level-up | 1.13 |
| 4061 | 0x505f74 | 100 | SP an AI unit of a non-strategist family needs before it considers a 武将技 | 1.13 |
| 4062 | 0x505f78 | 1024 | imitation threshold inside the effect query (skills.md) | — |
| 4063 | 0x505f7c | 0 | AI action order scheme | 7.5 |
| 4065 | 0x505f84 | 0 | AI terrain use: terrain % of the AI's planned tile | 6.3 |
| 4066 | 0x505f88 | 0 | attack-direction bonus (flank +5 %, rear +10 %) on physical/strategy damage and hit | 1.5 |
| 4073 | 0x505fa4 | 0 | 破百: raw ability > 100 adds `(raw−100)` % | 5.7 |
| 4074 / 4075 | 0x505fa8 / 0x505fac | 0 / 0 | 功勋 system for the player / AI growth | 5.8 |
| 4077 | 0x505fb4 | 2 | < 2: rolls use the pseudo-random decks (set to 0/1 per phase) | 1.4, 7.1 |
| 4078 | 0x505fb8 | 0 | 反間計 result mode | 2.9 |
| 4079 | 0x505fbc | 0 | 精进 also doubles person EXP | 5.2 |
| 4080 | 0x505fc0 | 0 | summon may be re-summoned | 7.6 |
| 4082 | 0x505fc8 | 0 | duel loser dies (docs/duel.md) | 7.6 |
| 4087 | 0x505fdc | 0 | set by the 单挑 item (§4.3): skips accumulators, terrain (every TerrainPct = 0xff/100), SP gain, fog | 1.4, 6.3 |
| 4093 | 0x505ff4 | 0 | modern-war presentation (mines, miss effects) | 1.9, 4.4 |
| 4094 | 0x505ff8 | 0 | stat recalculation at level-up | 5.4 |
| 4095 | 0x505ffc | 0 | revived/re-appearing units keep SP | 7.6 |

### 8.2 Constants the mod's patch logs edit (all verified at these addresses) [C]

| Address | Value | Meaning |
|---|---|---|
| 0x43bd36 | 0x19 | physical damage base `level + 25` |
| 0x43bd48 / 0x43bd5c | 5 | physical `(VA−VD)/5` divisors |
| 0x43c126 / 0x43c139 | 5 | strategy `(精−精)/5` divisors |
| 0x412ca0 | `push 7` | damage spread `rand(7)` (0 disables it) |
| 0x4110c1 | 0x1e | 突破攻击 +30 % when the target cannot be pushed |
| 0x43f617, 0x43f643, 0x43f66f, 0x43f69b, 0x43f6c7 | 0x22 | buff code per stat: high nibble = +tenths for levels ≥ 4, low nibble = −tenths for ≤ 2 |
| 0x4240ce | 01 08 10 C0 | status durations written on infliction (麻痹 1, 禁咒 2, 混乱 1, 中毒 3) |
| 0x424262 / 0x42426a | 0x14 / 0x0a | 末日审判: `deck/20 + 10` % of max HP |
| 0x436479 | 2 | 奋战 extra exchanges |
| 0x421340 | 2 | 引导 extra exchanges |
| 0x4d1a80 | 40×40 | class matchup table (row = attacker family) |
| 0x423e9d / 0x423ea1 / 0x42ac99 | 0x6e | raw ability caps 110 (display / fruits / 功勋) |
| 0x407301/09/11/19, 0x407305/0d/15/1d/21 | 63 5a 46 32, 0a 08 06 04 02 | ability grade thresholds 99/90/70/50 → grades 10/8/6/4, else 2 |
| 0x407fc7 / 0x419b69 | 0x0a | N in the scripted enemy/ally deploy level `min(ref + L, 100 + N)` (§5.9) |
| 0x4cb6bf | 1 | 破甲攻击 deals its value as fixed damage (≠ 1: % of max HP) |

## 9. Open questions

Physical attack / SP (§1):
1. 文官必杀 handlers (0x451195 … 0x410339): dispatch, cost and area are verified here; their effects are summarised in
   skills.md §3.4, partly [G] there.
2. Shipped skill values make 折磨 / 破X / 捕縛… / 鬼门 / 驱逐 no-ops beyond the generic 必杀 bonuses (§1.13) —
   literal reading of 0x436334; confirm in play if possible.
3. **防御致命攻击** (0x42aa2a) sets a critical strike's damage to 0 (literal reading of the code).
4. **MP辅助** targets lose exactly 1 MP per strike when MP > 50 % (0x405f86) — looks like a 6.6 quirk; port literally.
5. **Fog** 0x41d716: meaning of byte 0x501bd2 and the per-cell map 0x4934b0 (×0.8 damage) not traced to their writers.
6. **围攻** is disabled by data (family row k7 = 1 everywhere); the code path (§1.14) is documented but untested.
7. HitCurve 0x43b53a divides by `d/2` or `d/3`: `a = 0` with `d ∈ {1, 2}` faults in the original (an attacker value
   of 0 needs e.g. a terrain % of 0, family 40). The port should guard (treat as the next branch) and log.
8. 0x4111a5 (after a knock-back with area targets) — re-targeting of the second strike read at summary level only.
9. Reset point of the support-attack counter `unit+0x23` (同仇敌忾 / 戮力同心) and of 先制攻击's `unit+0x22`.
10. The mode byte 0x500e9a is also incremented by the duel setup 0x40ada3; interplay with duels: docs/duel.md.

Strategies / status (§2–3):
11. Weather strategies: the rain search in 0x44a1f5 ("minus 1", not-found value 6).
12. 召唤 (0x426551) unit creation details; 纵火/修筑 objects (0x4560f3) and their timers.
13. The AI's "already has this status" check builds mask 32 for 中毒 (never matches) — port literally.
14. 玄武现世 only touches unit slots 60..249 — clear in code, intent unknown.

Items / growth (§4–5):
15. Who sets the battle leader id `word[0x492f90+0x3d06]` (48-EXP kill, ×2 strategy kill EXP, MgHit 3/4 quirk).
16. Whether the action EXP is reset before a mine's party-wide EXP (0x405157).
17. Armour EXP from strategies uses only the first target for the 精进 test (per-target caller not checked).
18. Item types 0x3a–0x3d dispatch past the handler table — the menu must filter them.
19. Equipment level 0 would loop 255 times in EquipValue; confirm every path sets level ≥ 1.
20. Meaning of the person byte +0x02 功勋 mask and how the shared pool (EV4048) is spent.

Movement / turns (§6–7):
21. Unit flag `+0xd` bit 7 (exempt from pins, passes hostile units when ZOC is off, AI move 100).
22. The action-order routine 0x44da7a never orders slot 59 (looks like an original bug — port literally).
23. Aura effects (Buff/HP/MP/SP/诅咒光环 0x42f8d9, tables 0x42faa7 / 0x42faad) and the timed effect list 0x512dc0
    writers.
24. Mine owner / visibility checks (0x4103bb, 0x422663) and the two AI passes per phase (`[0x500c47]`).
25. Round limit, climate and starting weather come from the battle-settings script op (meaning taken from wg2025's
    notes, not re-verified in 6.6).
