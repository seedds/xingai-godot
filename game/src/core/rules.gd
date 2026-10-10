class_name Rules
extends RefCounted
## Battle formulas of the 6.6 engine (docs/battle.md, docs/skills.md, docs/ai.md). Pure computations on the emulated
## memory: the RNG, rolls, the stat pipeline, terrain, ranges and areas, hit / critical / damage for attacks and
## strategies, heal amounts, strategy usability. The battle executors (BattleActions, BattleStrategy, BattleAI) do
## the side effects. Integer arithmetic mirrors the original (truncating; "pct(p, v)" = v·p/100).

# ------------------------------------------------------------------ globals of the original (emulated memory)
const SEED := 0x48ecd4          # RNG state (starts at 1; reseeded at each battle start)
const B := 0x4b3d08             # battle object: +1 result, +2 round, +3 limit, +4 weather level, +0x10 phase, +0x11 climate
const COMBAT := 0x4927f0        # combat object: +0 attacker slot, +1 current target slot
const STRAT_CTX := 0x497af8     # strategy context: +0 strategy, +1 caster slot, +0xc current target
const ACC := 0x4930c8           # 4 roll accumulators per unit slot (集气 mode)
const DECKS := 0x508998         # two 52-byte pseudo-random decks
const DECK_CUR := 0x501bf6      # deck cursors (row 0 / row 1)
const DOOM_CUR := 0x501bf5      # 末日审判's own cursor on deck 0
const ATTACK_MODE := 0x500e9a   # byte: 0 attack, 1 围攻, 2 必杀; 0x500e9b = the 必杀 id
const WALKED := 0x500c48        # cells walked in this action (冲锋攻击)
const COUNTER_DEPTH := 0x492e04
const VTILE := 0x48e8c2         # AI candidate cell (word x | y << 8; 0xffff = none)
const HITS := 0x508a00          # strikes aimed at each slot since the other side's phase start (仇恨攻击)
const CUR_UNIT := 0x500ac0      # slot of the acting unit (the original keeps a pointer)
const ITEM_MODE := 0x500c44     # 0 attack; 1 mine detonation; 2 thrown item
const FORCED_MOVE := 0x500ad3   # 1 during knock-back / forced moves
const MOVE_RECT := 0x501bf0     # script move limit {x, y, w, h} (0 = none)
const STRAT_ITEM := 0x500ad7    # 1: an attack item is used as a strategy
const VIS := 0x4934b0           # per-cell visibility: bit 0 seen by the player group, bit 1 by the enemy group

const DIR4: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
## 0x4359f5 (table 0x435a3e): up, right, down, left, up-right, down-right, down-left, up-left
const DIR8: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1)]


static func ev(n: int) -> int:
	return Mem.r32(Mem.EV + 4 * n)


static func evb(n: int) -> int:
	return Mem.r8(Mem.EV + 4 * n)


# ------------------------------------------------------------------ RNG (0x47fae7 / 0x47fb13 / 0x47fb32)
static func srand(s: int) -> void:
	Mem.w32(SEED, s & 0xffffffff)


## rand(n) 0x47fb13: MSVC LCG; n < 2 → 0 without a draw.
static func rand(n: int) -> int:
	if n < 2:
		return 0
	var s := (Mem.r32(SEED) * 0x41c64e6d + 0x3039) & 0xffffffff
	Mem.w32(SEED, s)
	return ((s >> 16) & 0x7fff) % n


## chance(p) 0x47fb32: rand(100) < p (unsigned).
static func chance(p: int) -> bool:
	return rand(100) < (p & 0xffffffff)


static func pct(p: int, v: int) -> int:
	return v * p / 100


static func sat_sub(x: int, y: int) -> int:
	return x - y if x > y else 0


## MinAdd 0x47fa89: min(a + b, cap) (signed).
static func min_add(a: int, b: int, cap: int) -> int:
	return mini(a + b, cap)


# ------------------------------------------------------------------ rolls (0x43786b / 0x4287a8 / decks)
## Deck draw 0x455e25: deck `row` at the cursor byte, the cursor cycling 0..51.
static func deck(cur_addr: int, row: int) -> int:
	var c := Mem.r8(cur_addr)
	var v := Mem.r8(DECKS + row * 52 + c)
	Mem.w8(cur_addr, c + 1 if c < 51 else 0)
	return v


## 0x423490 at every player-phase start: 104 × (rand(100) + 1).
static func refill_decks() -> void:
	for i in 104:
		Mem.w8(DECKS + i, rand(100) + 1)


## Chance2 0x43786b: rand when m == 2 or EV 4077 ≥ 2 (default), else the pseudo-random deck of EV 4077:
## m 1 → v ≥ 100 − p, m 0 → p ≥ v.
static func chance2(p: int, m: int) -> bool:
	var row := evb(4077)
	if m == 2 or row >= 2:
		return chance(p)
	var v := deck(DECK_CUR + row, row)
	p = mini(p, 100)
	if m == 1:
		return v >= 100 - p
	return p >= v


## Roll 0x4287a8(p, mode): mode low nibble = accumulator slot (bit 0 = count misses), high nibble 1 = strategy
## context. Physical hit 1, critical 2, double attack 0, strategy hit 0x13, strategy critical 0x12. The per-unit
## accumulators decide alone in 集气 mode (EV 4018 = 1); otherwise Chance2(p, 0).
static func roll_acc(p: int, mode: int) -> bool:
	if Mem.r32(Mem.EV + 4 * 4087) == 0:
		var unit: int
		if (mode >> 4) == 1:
			unit = Mem.r8(STRAT_CTX + (0xc if mode & 1 else 1))
		else:
			unit = Mem.r8(COMBAT + (mode & 1))
		var a := ACC + unit * 4 + (mode & 15)
		var acc := Mem.r8(a)
		var t: int
		var ok: bool
		if mode & 1:
			t = (acc + 100 - p) & 0xff
			ok = t < 100
			if not ok:
				t = (t - 100) & 0xff
		else:
			t = (acc + p) & 0xff
			ok = t >= 100
			if ok:
				t = (t - 100) & 0xff
		if not (mode == 0 and Mem.r8(0x492df8) >= 1):
			Mem.w8(a, t)
		if ev(4018) == 1:
			return ok
	return chance2(p, 0)


## Accumulators reset (0x4121e2 at battle start for all, 0x4277a9 for a re-entering unit): EV 4017 in each.
static func reset_acc(slot := -1) -> void:
	var v := evb(4017)
	if slot < 0:
		Mem.fill(ACC, 1000, v)
	else:
		Mem.fill(ACC + slot * 4, 4, v)


# ------------------------------------------------------------------ curves
## HitCurve 0x43b53a (unsigned). The original divides by zero for a = 0 with d ∈ {1, 2}; that case is taken as
## the branch below it (port guard, docs/battle.md §9.7).
static func hit_curve(a: int, d: int) -> int:
	if a >= 2 * d:
		return 100
	if a >= d:
		return 90 + (a - d) * 10 / d
	var h := d / 2
	if a >= h and h > 0:
		return 60 + (a - h) * 30 / h
	var t := d / 3
	if t == 0:
		return 30
	return 30 + sat_sub(a, t) * 30 / t


## Crit / double curve 0x405d0a(d, a).
static func crit_curve(d: int, a: int) -> int:
	if a >= 3 * d:
		return 100
	if a > 2 * d:
		return 20 + (a - 2 * d) * 80 / d
	if a >= d:
		return 2 + (a - d) * 18 / d
	return 1


# ------------------------------------------------------------------ map and terrain
static func st():
	return Effects.battle


static func map_w() -> int:
	return Mem.r8(Mem.MAP_WH)


static func map_h() -> int:
	return Mem.r8(Mem.MAP_WH + 1)


static func in_map(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < map_w() and c.y < map_h()


## Terrain byte of a cell (map buffer +0x640), 0xff off the map.
static func raw_terrain(c: Vector2i) -> int:
	if not in_map(c):
		return 0xff
	return Mem.r8(Mem.MAP_BUF + 0x640 + c.x + c.y * map_w())


## Unit slot on a cell (map buffer +0xc80, 0xff none).
static func slot_at(c: Vector2i) -> int:
	if not in_map(c):
		return 0xff
	return Mem.r8(Mem.MAP_BUF + 0xc80 + c.x + c.y * map_w())


static func unit_at(c: Vector2i) -> BUnit:
	var s := slot_at(c)
	if s == 0xff or st() == null:
		return null
	return st().units[s]


## Terrain of a cell (0x435991 → 0x412557): a cell whose unit has 万里龙城 bit 4 reads as 19 关隘.
static func terrain_at(c: Vector2i) -> int:
	var t := raw_terrain(c)
	if t == 0xff:
		return t
	var u := unit_at(c)
	if u != null and (u.eff(0xab, 0x2a, 0, 0) & 4) != 0:
		return 0x13
	return t


static var _fam_flat := PackedByteArray()


## The family records as the engine holds them (40 × 60 bytes: terrain effect % per terrain 0..29, move cost per
## terrain 0..29, 0xff impassable), so terrains 30..33 read past a record as in the original.
static func fam_byte(fam: int, i: int) -> int:
	if _fam_flat.is_empty():
		_fam_flat.resize(41 * 60)
		_fam_flat.fill(0)
		for f in Game.families_db.size():
			var r: Dictionary = Game.families_db[f]
			var te: Array = r.get("terrain_effect", [])
			var mc: Array = r.get("move_cost", [])
			for k in 30:
				_fam_flat[f * 60 + k] = int(te[k]) if k < te.size() else 0
				_fam_flat[f * 60 + 30 + k] = 0xff if k >= mc.size() or mc[k] == null else int(mc[k])
	var a := fam * 60 + i
	return _fam_flat[a] if a >= 0 and a < _fam_flat.size() else 0


## Family attribute row k (0x4d20c0 + 40·k): 1 order pass 6, 3 ranged, 5 attack type (1 策略系 2 物理系 0 both),
## 6 strategy damage %, 7 no 围攻, 8 军师技 index.
static func fam_attr(k: int, fam: int) -> int:
	return Mem.r8(0x4d20c0 + 40 * k + fam)


## Ranged attacker family (0x4281af, row 3): 弓兵 弓骑兵 炮车 女弓兵 井栏.
static func is_ranged(u: BUnit) -> bool:
	return fam_attr(3, u.family()) != 0


## 左天羅右地網 pin 0x412b5f: unless the unit is on a scripted move, an orthogonal neighbour of its current cell of
## another side with Q(0x60, 0x7a, 1, 1) raises every cost to at least 0x80.
static func pinned(u: BUnit) -> bool:
	if u.flags & 0x80:
		return false
	for d in DIR4:
		var o := unit_at(u.pos + d)
		if o != null and o.side() != u.side() and o.eff(0x60, 0x7a, 1, 1) != 0:
			return true
	return false


## TerrainPct 0x43f7b8(t): [move cost, terrain effect %] of terrain t for the unit's family, with 龙巡四海 /
## 虎啸山林, 辅助地形状态, 恶路移动, 穿越移动 and the pin rule.
static func terrain_pct(u: BUnit, t: int) -> Array:
	var fam := u.family()
	if ev(4087) != 0:
		return [0xff, 100]
	if fam >= 40:
		return [0xff, 0]
	var e := fam_byte(fam, t)
	var cost := fam_byte(fam, 30 + t)
	if pinned(u):
		cost = maxi(cost, 0x80)
	if cost != 0xff:
		var a := u.eff(0xa9, 0x2a, 0, 0)
		var b := u.eff(0xaa, 0x2a, 0, 0)
		var cls_t := Mem.r8(0x435bf2 + t) if t < 30 else 0
		if (a & cls_t) or (b & cls_t):
			e = maxi(e, 120)
		if a != 0 or b != 0:
			cost = 1
	if u.eff(0x3e, 0x2a, 1, 1) != 0:
		e = maxi(e, 110)
	if cost != 0xff and u.eff(0x3f, 0x2a, 1, 1) != 0:
		cost = 1
	if passes(u):
		if cost >= 0x80:
			cost = 1
		elif cost > 1:
			cost -= 1
	return [cost, e]


## 穿越移动 0x403a6f: always during a forced move (byte 0x500ad3 = 1), else Q(0x36, 0x5d, 1, 1).
static func passes(u: BUnit) -> bool:
	return Mem.r8(FORCED_MOVE) == 1 or u.eff(0x36, 0x5d, 1, 1) != 0


static func move_cost(u: BUnit, t: int) -> int:
	if t == 0xff or t < 0:
		return 0xff
	return terrain_pct(u, t)[0]


## TerrainPos 0x407bf6(k): the AI candidate cell instead of the unit's own for an AI unit when one is set and
## k == 1, or k == 0 with EV 4065 (AI地形利用); k == 2 always the real cell.
static func unit_tile(u: BUnit, k: int) -> Vector2i:
	var vt := Mem.r16(VTILE)
	if u.ai == 7 or k == 2 or vt == 0xffff or (k != 1 and ev(4065) == 0):
		return u.pos
	return Vector2i(vt & 0xff, vt >> 8)


## Terrain effect % of the unit's own tile (0x1e, AI candidate with EV 4065) or real tile (0x20).
static func tile_effect(u: BUnit, real: bool) -> int:
	return terrain_pct(u, terrain_at(unit_tile(u, 2 if real else 0)))[1]


## RegenPct 0x428a25 → 0x41e467: 城池 25, 关隘 / 鹿砦 / 兵营 20, 村庄 15 (% of max HP, and flat MP).
static func regen_pct(c: Vector2i) -> int:
	var t := terrain_at(c)
	match t:
		18: return 25
		19, 20, 22: return 20
		21: return 15
	return 0


# ------------------------------------------------------------------ the stat pipeline (§1.3)
## BuffApply 0x42211e: code byte up/down tenths (0x22: ±20 %); the first of the unit and its 8 same-side
## neighbours with 状态强化 changes them (up + v/10, down − min(v%10, down)).
static func buff_apply(v: int, code: int, lvl: int, u: BUnit) -> int:
	var down := code % 16
	var up := (code / 16) % 16
	var sd := u.side()
	for i in 9:
		var n: BUnit = u
		if i > 0:
			n = unit_at(u.pos + DIR8[i - 1])
			if n == null or n.side() != sd:
				continue
		var w := n.eff(0x74, 0x4c, 1, 0)
		if w != 0:
			up += w / 10
			down -= mini(w % 10, down)
			break
	if lvl >= 4:
		return v * (10 + up) / 10
	if lvl <= 2:
		return v * (10 - down) / 10
	return v


## Buffed(u, s) (0x440151[s]): the person stat with the buff level, at most 9999.
static func buffed(u: BUnit, s: int) -> int:
	var code := Mem.r8(0x43f617 + 0x2c * s)
	return mini(buff_apply(u.person.stat(s), code, u.buff(s), u), 9999)


## UnitStat 0x414ccb(k, effOther): 唯我独尊 / the opponent's 偷梁换柱 or 批亢捣虚 choose the stat, then HP辅助 /
## MP辅助, 一夫当关, 万夫莫敌, 众志成城, 鬼神之勇 and the difficulty multipliers.
static func unit_stat(u: BUnit, k: int, eff_other: int) -> int:
	var own := u.eff(0x39, 0x61, 1, 1)
	var v := 0
	if eff_other != 0 and own == 0:
		if eff_other > 5:
			v = 0xffff
			for i in 5:
				v = mini(v, buffed(u, i))
		else:
			k = eff_other - 1
			v = buffed(u, k)
	elif own != 0 and eff_other == 0:
		for i in 5:
			v = maxi(v, buffed(u, i))
	else:
		v = buffed(u, k)
	v = hpmp_assist(u, v, k)
	v = alone(u, v)
	v = outnumbered(u, v)
	return morale(u, v)


## HP辅助 / MP辅助 0x428430: the first row i (0..4) whose masks name stat k adds HP/5 and/or MP.
static func hpmp_assist(u: BUnit, v: int, k: int) -> int:
	for i in 5:
		var n := 0
		var m := u.eff(0x9d + i, 0x7d, 3, 0)
		if m != 0 and (m >> k) & 1:
			v += u.hp / 5
			n += 1
		m = u.eff(0xa2 + i, 0x7e, 3, 0)
		if m != 0 and (m >> k) & 1:
			v += u.mp & 0xffff
			n += 1
		if n:
			break
	return v


## Units of a CountUnits code (0x428df1 / 0x44cb12) on the map, in the rectangle when `rect` (inclusive cells).
## Returns [count, first slot]. Codes: 0..3 kind, 4 kind ≤ 1, 5 kind 2/3, 6 any (kind 2 counts as 0 in slots < 20
## and as 1 in 20..59; kinds > 6 as 0).
static func count_units(code: int, rect := false, x1 := 0, y1 := 0, x2 := 0, y2 := 0) -> Array:
	var n := 0
	var first := 0xff
	if rect:
		for y in range(y1, y2 + 1):
			for x in range(x1, x2 + 1):
				var s := slot_at(Vector2i(x, y))
				if s == 0xff:
					continue
				var o: BUnit = st().units[s]
				if o.state != 2:
					continue
				if n == 0:
					first = s
				if kind_matches(o, code):
					n += 1
	else:
		for o: BUnit in st().units:
			if o.state == 2 and kind_matches(o, code):
				if n == 0:
					first = o.slot
				n += 1
	return [n & 0xff, first]


static func kind_matches(o: BUnit, code: int) -> bool:
	var k := o.kind
	if k > 6:
		k = 0
	if k == 2:
		if o.slot < 20:
			k = 0
		elif o.slot < 60:
			k = 1
	if code < 4:
		return k == code
	if code == 4:
		return k < 2
	if code == 5:
		return k == 2 or k == 3
	return code == 6


## Units of `code` in the 3×3 box around the unit (0x41bc4a; an AI unit in an AI phase counts around its candidate
## cell).
static func box_count(u: BUnit, code: int) -> Array:
	var c := u.pos
	if u.ai != 7 and Mem.r8(B + 0x10) != 0:
		c = unit_tile(u, 1)
	return count_units(code, true, maxi(c.x - 1, 0), maxi(c.y - 1, 0), c.x + 1, c.y + 1)


## 一夫当关 0x478eab: +v % alone in the 3×3 box of its own side, else +v/2 %.
static func alone(u: BUnit, v: int) -> int:
	var p := u.eff(0x47, 0x69, 0, 0)
	if p == 0:
		return v
	var r := box_count(u, 4 if u.side() == 1 else 5)
	if r[0] != 0 and (r[0] != 1 or r[1] != u.slot):
		p >>= 1
	return v + pct(p, v)


## 万夫莫敌 0x4363b0: +(n + 1)·v % with n opposing units in the 3×3 box.
static func outnumbered(u: BUnit, v: int) -> int:
	var p := u.eff(0x55, 0x71, 1, 0)
	if p == 0:
		return v
	var n: int = box_count(u, 5 if u.side() == 1 else 4)[0]
	return v + pct((n + 1) * p, v)


## 0x4200a2: 众志成城 and 鬼神之勇 (0x43cb00), then EV 4033 (kind ≥ 2) / EV 4034 (kind 1) as % when non-zero.
static func morale(u: BUnit, v: int) -> int:
	v = zhongzhi(u, v)
	var m := 0
	if u.kind > 1:
		m = ev(4033)
	elif u.kind == 1:
		m = ev(4034)
	if m != 0:
		v = pct(m, v)
	return v


## 众志成城 0x43cb00: every other on-map unit W (person < 0x400) with Q(0x3c, 0x1c, 1, 0) = p next to the unit
## adds (same side) or removes p · n %, n = W's same-side units around W (+1 for an AI unit next to W only through
## its candidate cell); the loss leaves at least 1. Then 鬼神之勇 0x45b67c, the result at least 1.
static func zhongzhi(u: BUnit, v: int) -> int:
	var sd := u.side()
	var s := 0
	var ai_phase := u.ai != 7 and Mem.r8(B + 0x10) != 0
	for w: BUnit in st().units:
		if w == u or w.state != 2 or Mem.r16(w.addr) >= 0x400:
			continue
		var p := w.eff(0x3c, 0x1c, 1, 0)
		if (p & 0xff) == 0:
			continue
		var adj := false
		var listed := false
		if not ai_phase:
			var flags := sd if w.slot < 60 else sd ^ 1
			adj = _adj8(w.pos, u.pos) and u.hp > 0 and ((flags & 1) == 1) == (u.side() == w.side())
		else:
			adj = _adj8(w.pos, unit_tile(u, 1))
		if not adj:
			continue
		var n := 0
		for d in DIR8:
			var o := unit_at(w.pos + d)
			if o != null and o.hp > 0 and o.side() == w.side():
				n += 1
				if o == u:
					listed = true
		if ai_phase and not listed:
			n += 1
		if sd == w.side():
			s += p * n
		else:
			s -= p * n
	if s > 0:
		v += pct(s, v)
	elif s < 0:
		var r := pct(-s, v)
		if v <= r:
			r = v - 1
		v -= r
	return maxi(guishen(u, v), 1)


static func _adj8(a: Vector2i, b: Vector2i) -> bool:
	return a != b and absi(a.x - b.x) <= 1 and absi(a.y - b.y) <= 1


## 鬼神之勇 0x45b67c: + min(v, lost-HP % / 2) %.
static func guishen(u: BUnit, v: int) -> int:
	var p := u.eff(0x51, 0x6d, 0, 0)
	if p == 0:
		return v
	var mh := u.max_hp()
	if mh <= 0:
		return v
	var b := ((mh - u.hp) * 100 / mh) >> 1
	if b != 0:
		v += pct(mini(b, p), v)
	return v


## 能力替换 / 能力辅助 0x423ced: rows 0x80+i / 0x85+i (mode 2) as source·0x20 + target mask; 替换 takes the source
## stat when larger (士气 always), 辅助 adds 20 % of it once per distinct code.
static func auras(u: BUnit, k: int, v: int) -> int:
	var applied := []
	for j in 2:
		for i in 5:
			var r := u.eff((0x85 if j else 0x80) + i, 0x7b if j else 0x7c, 2, 0)
			if r == 0 or not ((r & 31) >> k) & 1:
				continue
			var w := unit_stat(u, (r >> 5) & 7, 0)
			if j == 0:
				if k == 4 or w >= v:
					v = w
			elif not applied.has(r):
				applied.append(r)
				v += pct(20, w)
	return v


## 忽视能力 0x416a38 (on the opponent): the first row 0x8a+i naming stat k takes 20 % off.
static func weaken(opp: BUnit, k: int, v: int) -> int:
	for i in 6:
		var m := opp.eff(0x8a + i, 0x7a, 3, 0)
		if m != 0 and (m >> k) & 1:
			return v - pct(20, v)
	return v


## StatPair 0x40d2ab: [A's stat kA, D's stat kD] with 偷梁换柱 / 批亢捣虚, auras, the opponent's 忽视能力 and (unless
## no_terrain) the terrain % of A's own tile (AI candidate with EV 4065) and D's real tile.
static func stat_pair(a: BUnit, ka: int, d: BUnit, kd: int, no_terrain: bool) -> Array:
	Effects.begin_cache()
	var r := _stat_pair(a, ka, d, kd, no_terrain)
	Effects.end_cache()
	return r


static func _stat_pair(a: BUnit, ka: int, d: BUnit, kd: int, no_terrain: bool) -> Array:
	var va := unit_stat(a, ka, d.eff(0x6a, 0x6a, 1, 0))
	va = auras(a, ka, va)
	va = weaken(d, ka, va)
	var vd := unit_stat(d, kd, a.eff(0x54, 0x70, 1, 0))
	vd = auras(d, kd, vd)
	vd = weaken(a, kd, vd)
	if not no_terrain:
		va = va * tile_effect(a, false) / 100
		vd = vd * tile_effect(d, true) / 100
	return [va, vd]


# ------------------------------------------------------------------ shapes (0x436511 / 0x435ce9)
## The (a, b) pairs of range code `code` (table 0x4d1400, codes > 11 at code − 2).
static func shape_entries(code: int) -> Array:
	var out := []
	if code == 10 or code == 11 or code >= 0x26 or code < 0:
		return out
	var p := Mem.r32(0x4d1400 + 4 * (code - 2 if code > 10 else code))
	var guard := 0
	while Mem.r16(p) != 0xffff and guard < 64:
		out.append([Mem.r8(p), Mem.r8(p + 1)])
		p += 2
		guard += 1
	return out


## Expand one (a, b) pair (0x436611 / 0x42399b order): a, b ≠ 0 → (+a,−b) (−a,−b) (−a,+b) (+a,+b); one of them 0 →
## m = max: (+m,0) (−m,0) (0,−m) (0,+m). Off-map cells are dropped.
static func expand_entry(c: Vector2i, a: int, b: int, out: Array) -> void:
	var cells: Array
	if a != 0 and b != 0:
		cells = [Vector2i(c.x + a, c.y - b), Vector2i(c.x - a, c.y - b), Vector2i(c.x - a, c.y + b), Vector2i(c.x + a, c.y + b)]
	else:
		var m := maxi(a, b)
		if m == 0:
			return
		cells = [Vector2i(c.x + m, c.y), Vector2i(c.x - m, c.y), Vector2i(c.x, c.y - m), Vector2i(c.x, c.y + m)]
	for p in cells:
		if in_map(p):
			out.append(p)


## Cells of one range code around c in the original's order (code 10 = the whole map, y outer; 11 = none).
static func range_cells(code: int, c: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if code == 10:
		for y in map_h():
			for x in map_w():
				out.append(Vector2i(x, y))
		return out
	for e in shape_entries(code):
		expand_entry(c, e[0], e[1], out)
	return out


## Cells of a packed range (up to 4 codes, 0xff none; code 0 only as the first) around c; with `self_cell` the
## centre first (the same-side collection of 0x436511 includes it).
static func codes_cells(codes: Array, c: Vector2i, self_cell := false) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if codes.is_empty() or codes[0] == 0xff:
		return out
	if self_cell and in_map(c):
		out.append(c)
	for i in 4:
		var code: int = codes[i] if i < codes.size() else 0xff
		if code == 0xff or (code == 0 and i != 0) or code >= 0x26:
			continue
		if code == 10:
			out.append_array(range_cells(10, c))
			break
		out.append_array(range_cells(code, c))
	return out


## Collect 0x436511 → 0x437aff: units on the cells of `codes` around `c` (flags bit 0: same side as u, the centre
## included; flags == 2: any side; otherwise the other side), HP > 0, each once, in collection order.
static func collect(u: BUnit, c: Vector2i, codes: Array, flags: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	var sd := u.side()
	for p in codes_cells(codes, c, (flags & 1) != 0):
		var o := unit_at(p)
		if o == null or out.has(o):
			continue
		if flags != 2:
			if flags & 1:
				if o.side() != sd:
					continue
			elif o.side() == sd:
				continue
		if o.hp == 0:
			continue
		out.append(o)
	return out


## Effect area cells around `t` (0x435ce9), the primary cell not included: k = 0x406235[a]; 0x61 = a line behind the
## target (1 cell for 4, 5 for 5, 2 for 7), 0x60 = the two flank cells (0x4254fa), else list 0x4d13a0[k] around the
## target (around the attacker for area 10).
static func area_cells(a: int, t: Vector2i, src_pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if a == 0 or a >= 0xb:
		return out
	var k := Mem.r8(0x406235 + a)
	if k == 0x60:
		var offs := flank(t, src_pos)
		for o in offs:
			var p: Vector2i = t + o
			if in_map(p):
				out.append(p)
	elif k == 0x61:
		var step := Vector2i(signi(t.x - src_pos.x), signi(t.y - src_pos.y))
		var n := 5 if a == 5 else (1 if a == 4 else 2)
		var p := t
		for i in n:
			p += step
			if in_map(p):
				out.append(p)
	else:
		var center := src_pos if a == 10 else t
		var lp := Mem.r32(0x4d13a0 + 4 * k)
		var guard := 0
		while Mem.r16(lp) != 0xffff and guard < 64:
			expand_entry(center, Mem.r8(lp), Mem.r8(lp + 1), out)
			lp += 2
			guard += 1
	return out


## 0x4254fa: the two cells beside the target across the attack direction.
static func flank(t: Vector2i, a: Vector2i) -> Array:
	if t.x == a.x:
		return [Vector2i(1, 0), Vector2i(-1, 0)]
	if t.y != a.y:
		if t.x < a.x:
			if a.y <= t.y:
				return [Vector2i(1, 1), Vector2i(-1, -1)]
		elif t.y < a.y:
			return [Vector2i(1, 1), Vector2i(-1, -1)]
		return [Vector2i(-1, 1), Vector2i(1, -1)]
	return [Vector2i(0, 1), Vector2i(0, -1)]


# ------------------------------------------------------------------ attack range and area (§1.11)
static func attack_mode() -> int:
	return Mem.r8(ATTACK_MODE)


static func skill_id() -> int:
	return Mem.r8(ATTACK_MODE + 1)


static func set_attack_mode(m: int, k := 0) -> void:
	Mem.w16(ATTACK_MODE, (k << 8) | m)


## Forced(K) 0x436334: the current 必杀's value when it is K.
static func forced(k: int) -> int:
	var cur := skill_id()
	if cur == 0 or cur != k:
		return 0
	return int(skill(k).get("value", 0))


## Range upgrade 0x41ce8c: with 远距攻击 (sid 0x5a + k, eid 0x76, mode 3) & k the code goes through 0x41ceab.
static func upgrade_code(u: BUnit, k: int, code: int) -> int:
	if (u.eff(0x5a + k, 0x76, 3, 0) & k) != 0:
		return Mem.r8(0x41ceab + (code & 0xff))
	return code


## AttackRange 0x43f8c0 → 4 codes: the class (or current 必杀's) range upgraded, the 远距攻击 item value, 0x14 for
## item effect 0x2c, 0x0c for 0x54. 禁咒 → (0x0b); pinned by an adjacent 左天羅右地網 enemy → (0) (melee cross).
static func attack_codes(u: BUnit) -> Array:
	var c := [0xff, 0xff, 0xff, 0xff]
	var c0 := 0xff
	if Mem.r8(CUR_UNIT) == u.slot and attack_mode() == 2 and skill_id() != 0:
		c0 = int(skill(skill_id()).get("range_code", 0xff))
	if c0 == 0xff:
		c0 = int(Game.cls(u.cls()).get("attack_range", 0))
	c[0] = upgrade_code(u, 1, c0)
	if Effects.has_item_effect(u.pid, 0x32):
		var v := Effects.item_value(u.pid, 0x32, 5)
		if v != 0:
			c[1] = v
	if Effects.has_item_effect(u.pid, 0x2c):
		c[2] = 0x14
	if Effects.has_item_effect(u.pid, 0x54):
		c[3] = 0x0c
	if u.sealed():
		return [0x0b, 0xff, 0xff, 0xff]
	if adjacent_pin(u):
		return [0x0b, 0xff, 0xff, 0xff] if c[0] == 0x0b else [0, 0, 0, 0]
	return c


## 0x42bb57: an orthogonal neighbour of the unit's (candidate) cell is a hostile unit with 左天羅右地網.
static func adjacent_pin(u: BUnit) -> bool:
	var c := unit_tile(u, 1)
	for d in DIR4:
		var o := unit_at(c + d)
		if o != null and o.side() != u.side() and o.eff(0x60, 0x7a, 1, 1) != 0:
			return true
	return false


static func attack_cells(u: BUnit, c: Vector2i) -> Array[Vector2i]:
	return codes_cells(attack_codes(u), c)


static func in_attack_range(u: BUnit, from: Vector2i, cell: Vector2i) -> bool:
	return attack_cells(u, from).has(cell)


## Physical area code 0x407835: the 必杀's 穿透 shape, else the 穿透攻击 item value (eid 0x33), else the class table
## 0x407881; widened by 辅助穿透-攻击 (QueryAny(0xa7, 0x57, 3, 0) & 1, not with EV 4087) through 0x45d343.
static func phys_area(u: BUnit) -> int:
	var a := 0
	if attack_mode() == 2:
		a = int(skill(skill_id()).get("pierce_shape", 0))
	if a == 0:
		a = Effects.item_value(u.pid, 0x33, 5) if Effects.has_item_effect(u.pid, 0x33) else 0
		if a == 0:
			a = Mem.r8(0x407881 + u.cls())
	return pierce_upgrade(u, 1, a)


## 0x45d316: 辅助穿透 (sid 0xa6 + k) & k → table 0x45d343[area]; not with EV 4087.
static func pierce_upgrade(u: BUnit, k: int, a: int) -> int:
	if ev(4087) == 0 and (Effects.any(u.pid, 0xa6 + k, 0x57, 3, 0) & k) != 0:
		return Mem.r8(0x45d343 + a)
	return a


## Targets of a physical attack (0x406289 → 0x435ce9): the primary target, then hostile area units.
static func attack_targets(a: BUnit, t: BUnit) -> Array[BUnit]:
	var out: Array[BUnit] = [t]
	var area := phys_area(a)
	for p in area_cells(area, t.pos, unit_tile(a, 2)):
		var o := unit_at(p)
		if o != null and o != t and not out.has(o) and o.hp > 0 and o.side() != a.side():
			out.append(o)
	return out


# ------------------------------------------------------------------ physical hit, critical, double (§1.4–1.7)
## DirBonus 0x408db1: EV 4066 flank +5 % / rear +10 % by the defender's facing; +5 % in 围攻 against a
## non-player-camp defender. Returns the extra (ret_extra) or the new value.
static func dir_bonus(a: BUnit, d: BUnit, x: int, ret_extra: bool) -> int:
	var extra := 0
	if ev(4066) != 0:
		var ap := a.pos
		var vt := Mem.r16(VTILE)
		if a.ai != 7 and vt != 0xffff:
			ap = Vector2i(vt & 0xff, vt >> 8)
		var f := d.dir
		var c := 0
		if f % 2 == 0:
			c = 1 if ap.y == d.pos.y else ((2 if f == 2 else 0) if d.pos.y > ap.y else (2 if f == 0 else 0))
		else:
			c = 1 if ap.x == d.pos.x else ((2 if f == 1 else 0) if d.pos.x > ap.x else (2 if f == 3 else 0))
		var e := x * (c * 5) / 100
		x += e
		extra += e
	if d.side() != 1 and attack_mode() == 1:
		var e2 := x * 5 / 100
		x += e2
		extra += e2
	return extra if ret_extra else x


## 0x408eee: direction extra (≤ 100), minus 辅助全防御 of the target, at least 1.
static func direction(a: BUnit, d: BUnit, rate: int) -> int:
	rate = mini(rate + dir_bonus(a, d, rate, true), 100)
	rate = sat_sub(rate, d.eff(0x21, 0x22, 1, 0))
	return maxi(rate, 1)


## PhysHitRate 0x43b623.
static func phys_hit_rate(a: BUnit, d: BUnit) -> int:
	Effects.begin_cache()
	var r := _phys_hit_rate(a, d)
	Effects.end_cache()
	return r


static func _phys_hit_rate(a: BUnit, d: BUnit) -> int:
	if attack_mode() == 2:
		return 100
	if is_ranged(a) and d.eff(0x2f, 0x4e, 1, 1) != 0:
		return 0
	if d.paralysed():
		return 100
	var p := stat_pair(a, 3, d, 3, false)
	var rate := hit_curve(p[0], p[1])
	if a.eff(0x1e, 0x24, 1, 1) != 0:
		return 100
	var v := a.eff(0x1f, 0x7e, 1, 0)
	if v:
		rate = mini(rate + v, 100)
	v = d.eff(0x20, 0x29, 1, 0)
	if v:
		rate = sat_sub(rate, v)
	return direction(a, d, rate)


## HitTest 0x43b4b6 for a physical strike (the combat object's attacker / target must be set).
static func phys_hit_test(a: BUnit, d: BUnit) -> bool:
	return hit_roll(phys_hit_rate(a, d), 1)


## The roll part of 0x43b4b6: sure at ≥ 100; EV 4018 > 1 thresholds; one retry at rate − 10 when rate ≥ 85.
static func hit_roll(rate: int, mode: int) -> bool:
	if (rate & 0xff) >= 100:
		return true
	var e18 := ev(4018)
	if e18 > 1:
		if rate >= e18:
			return true
		if rate < ev(4017):
			return false
	var h := false
	for t in 2:
		h = roll_acc(rate, mode)
		if e18 == 1 or h or rate < 85:
			break
		rate -= 10
	return h


## CritRate 0x40c7d8: Curve(D's 士气, A's 士气) + 100 with 致命一击 bit 1.
static func crit_rate(a: BUnit, d: BUnit) -> int:
	Effects.begin_cache()
	var r := _crit_rate(a, d)
	Effects.end_cache()
	return r


static func _crit_rate(a: BUnit, d: BUnit) -> int:
	var p := stat_pair(a, 4, d, 4, false)
	var r := crit_curve(p[1], p[0])
	if a.eff(0x33, 0x31, 3, 0) & 1:
		r += 100
	return r


## DoubleRate 0x405cb9: 100 with 主动连击, else Curve(D's 爆发, A's 爆发).
static func double_rate(a: BUnit, d: BUnit) -> int:
	Effects.begin_cache()
	var r := _double_rate(a, d)
	Effects.end_cache()
	return r


static func _double_rate(a: BUnit, d: BUnit) -> int:
	if a.eff(0x34, 0x42, 1, 1) != 0:
		return 100
	var p := stat_pair(a, 3, d, 3, false)
	return crit_curve(p[1], p[0])


## Matchup 0x426737(D, A): table 0x4d1a80[fam(A)·40 + fam(D)] + 绝对克制(A) − 绝对克制(D), at least 0.
static func matchup(a: BUnit, d: BUnit) -> int:
	var fa := a.family()
	var fd := d.family()
	var v := Mem.r8(0x4d1a80 + fa * 40 + fd) + a.eff(0x76, 0x4e, 1, 0) - d.eff(0x76, 0x4e, 1, 0)
	return maxi(v, 0)


## Knock-back cell 0x42230e: one step from the target away from the attacker (its tile or AI candidate); valid if
## not 围攻, the target alive and not confused, the cell on the map, empty and passable for the target.
static func push_cell(t: BUnit, a: BUnit) -> Vector2i:
	var ap := unit_tile(a, 1)
	var c := t.pos + Vector2i(signi(t.pos.x - ap.x), signi(t.pos.y - ap.y))
	if attack_mode() == 1 or t.hp == 0 or t.confused() or not in_map(c) or slot_at(c) != 0xff:
		return Vector2i(-1, -1)
	if move_cost(t, terrain_at(c)) >= 0xfe:
		return Vector2i(-1, -1)
	return c


## Breakthrough 0x411072 damage part (flag 0): 突破 (forced 驱逐 or Q(0x61, 0x35, 1, 1)) adds 30 % when the target
## cannot be pushed; otherwise 加强攻击 Q(0x62, 0x35, 0, 0) adds its %.
static func breakthrough_damage(t: BUnit, a: BUnit, dmg: int) -> int:
	if forced(0x16) != 0 or a.eff(0x61, 0x35, 1, 1) != 0:
		if push_cell(t, a).x < 0:
			dmg += dmg * Mem.r8(0x4110c1) / 100
		return dmg
	var p := a.eff(0x62, 0x35, 0, 0)
	if p:
		dmg += pct(p, dmg)
	return dmg


## Does an attack by `a` knock targets back (0x411072 with flag 1)?
static func pushes(a: BUnit) -> bool:
	return forced(0x16) != 0 or a.eff(0x61, 0x35, 1, 1) != 0


## Fog 0x41d716: ×80 % between groups when the cell is not visible (byte 0x501bd2 ≥ 2).
static func fog(a: BUnit, d: BUnit, dmg: int) -> int:
	if ev(4087) != 0 or Mem.r8(0x501bd2) < 2:
		return dmg
	vis_update()
	var ga := 1 if (a.slot < 60 or a.kind == 5) else 2
	var gd := 1 if (d.slot < 60 or d.kind == 5) else 2
	if ga == gd:
		return dmg
	var mask := 0x0d if gd == 2 else 0x0e
	if (Mem.r8(0x4934b0 + d.pos.x + d.pos.y * map_w()) & mask) == 0:
		return dmg * 80 / 100
	return dmg


static var _vis_gen := -1


## Visibility map 0x4934b0 while the battle tint mode (0x501bd2) is ≥ 2 (fog): every on-map unit reveals its cell
## and its sight shape for its group (0x42a297 → 0x42a6b8 / 0x42a708 / 0x42a5d6; a cell is cleared only when no
## unit of the group still sees it, so the map is the union of the groups' sights — rebuilt here when units moved).
## Bits 2/3 come from other sources and are kept.
static func vis_update() -> void:
	if Mem.r8(0x501bd2) < 2 or st() == null:
		return
	if _vis_gen == BUnit.gen:
		return
	_vis_gen = BUnit.gen
	var W := map_w()
	for i in W * map_h():
		Mem.w8(VIS + i, Mem.r8(VIS + i) & 0xc)
	for u: BUnit in st().units:
		if u.state != 2 or u.pid < 0:
			continue
		var g := 1 if (u.slot < 60 or u.kind == 5) else 2
		var cells: Array[Vector2i] = [u.pos]
		var p := Mem.r32(0x4d1400 + 4 * sight_shape(u))
		var guard := 0
		while Mem.r16(p) != 0xffff and guard < 64:
			expand_entry(u.pos, Mem.r8(p), Mem.r8(p + 1), cells)
			p += 2
			guard += 1
		for c in cells:
			if in_map(c):
				Mem.w8(VIS + c.x + c.y * W, Mem.r8(VIS + c.x + c.y * W) | g)


## Sight 0x42b1f1: 增加视野 (QuerySources(65, 0, 1, 0)) ≥ 12 → shape table entry v − 2, else entry 6 (Manhattan ≤ 2).
static func sight_shape(u: BUnit) -> int:
	var v := Effects.src(u.pid, 65, 0, 1, 0) & 0xff
	return v - 2 if v >= 12 else 6


## Modifiers 0x412c78: direction / 围攻 bonus; unless preview (flag 1 for strategies): fog and the rand(7) spread
## (−0..−2 or +1..+4, at least 1).
static func modifiers(a: BUnit, d: BUnit, dmg: int, preview: bool) -> int:
	dmg = dir_bonus(a, d, dmg, false)
	if preview:
		return dmg
	dmg = fog(a, d, dmg)
	var r := rand(7)
	if r > 2:
		return dmg + r - 2
	return maxi(sat_sub(dmg, r), 1)


## 末日审判 0x42423d(kind 1 physical, 2 strategy): + max HP · (deck0/20 + 10) %, the deck on its own cursor.
static func doom(a: BUnit, dmg: int, d: BUnit, kind: int) -> int:
	if (a.eff(0x6f, 0x48, 3, 0) & kind) == 0:
		return dmg
	var r := deck(DOOM_CUR, 0)
	return dmg + d.max_hp() * (r / Mem.r8(0x424262) + Mem.r8(0x42426a)) / 100


## CalcDamage 0x43bc5a(A, D, preview, mode): mode 0 first strike, 1 counter, 2 second strike. Returns
## [damage (≤ D's HP), raw damage before that cap]; 0 = a miss (the hit roll happens here unless preview).
static func calc_damage(a: BUnit, d: BUnit, preview: bool, mode: int) -> Array:
	Effects.begin_cache()
	var r := _calc_damage(a, d, preview, mode)
	Effects.end_cache()
	return r


static func _calc_damage(a: BUnit, d: BUnit, preview: bool, mode: int) -> Array:
	if Mem.r8(d.addr + 4) == 0xff:
		return [0, 0]
	var dmg := 0
	var final := false
	var p := a.eff(0x6e, 0x7d, 1, 0)
	if p and d.hp <= pct(p, d.max_hp()):
		dmg = d.hp
		final = true
	if not final:
		var v := forced(0x15)
		var capped := false
		if v:
			dmg = pct(v, d.max_hp())
			capped = true
		else:
			v = a.eff(0x16, 0x1f, 1, 0)
			if v:
				dmg = v if Mem.r8(0x4cb6bf) == 1 else pct(v, d.max_hp())
				capped = true
		if not capped:
			var sp := stat_pair(a, 0, d, 1, false)
			if not preview and not phys_hit_test(a, d):
				return [0, 0]
			var va: int = sp[0]
			var vd: int = sp[1]
			dmg = a.level() + Mem.r8(0x43bd36)
			if va >= vd:
				dmg += (va - vd) / Mem.r8(0x43bd48)
			else:
				dmg = maxi(sat_sub(dmg, (vd - va) / Mem.r8(0x43bd5c)), 1)
			v = a.eff(0x75, 0x4c, 1, 0)
			if v:
				var mv := d.move_points() - v
				if ((mv + 256) & 0xff) >= 0x80:
					dmg += dmg * ((v - d.move_points()) * 5) / 100
			var m := matchup(a, d)
			if m != 100:
				dmg = maxi(dmg * m / 100, 1)
			if is_ranged(a):
				v = d.eff(0x22, 0x45, 1, 0)
				if v:
					dmg = maxi(dmg - pct(v, dmg), 1)
			dmg = breakthrough_damage(d, a, dmg)
			v = a.eff(0x19, 0x5f, 1, 0)
			var walked := Mem.r8(WALKED)
			if v and walked:
				dmg += dmg * (v * walked) / 100
			v = d.eff(0x23, 0x3d, 1, 0)
			if v:
				dmg = maxi(dmg - pct(v, dmg), 1)
			if mode == 0:
				dmg += dmg * (a.eff(0x2c, 0x4a, 1, 0) * Mem.r8(HITS + a.slot)) / 100
			elif a.eff(0x48, 0x6a, 1, 1) == 0:
				dmg = maxi(dmg * 3 >> 2, 1)
			dmg = modifiers(a, d, dmg, preview)
			if not preview:
				dmg = doom(a, dmg, d, 1)
		var c := d.eff(0x56, 0x72, 1, 0)
		if c and c < dmg:
			dmg = c
	if preview and attack_mode() == 2:
		dmg += dmg * 50 / 100
	if Game.god:
		if d.side() == 1:
			return [0, 0]
		if a.side() == 1:
			dmg *= 20
	return [mini(dmg, d.hp), dmg]


# ------------------------------------------------------------------ 必杀 and SP (§1.13)
static var _skills: Array = []


## 必杀 record k (0x4a7510 + 16·k): name, range_code (+0xc), pierce_shape (+0xd), sp_cost (+0xe), value (+0xf).
static func skill(k: int) -> Dictionary:
	if _skills.is_empty():
		var d: Variant = Assets.json("data/skills.json")
		if d is Dictionary:
			_skills = d.get("bisha", {}).get("skills", [])
	if k < 0 or k >= _skills.size():
		return {}
	return _skills[k]


## 0x418744: does the person know 武将技 k (learner row k of 0x512000: owner family byte, or one of 5 (person,
## min level) slots)?
static func knows_skill(pid: int, k: int) -> bool:
	if k < 0 or k >= 80:
		return false
	var row := Mem.r32(0x500c37) + 16 * k
	var p := Game.person(pid)
	if p == null:
		return false
	if Mem.r8(row + 0xf) == p.family():
		return true
	for i in 5:
		if Mem.r16(row + 3 * i) == pid and p.level >= Mem.r8(row + 3 * i + 2):
			return true
	return false


## CanUseSkill 0x4225fb: 0 no; 1 武将技 (player-controlled units always — the menu checks costs); 2 军师技 (family
## row 8 ≠ 0). EV 4059 forbids, 禁咒 blocks, the SP must reach the cost (EV 4061 for AI 武将技 users).
static func can_use_skill(u: BUnit) -> int:
	if ev(4059) != 0:
		return 0
	var a := fam_attr(8, u.family())
	var need := 0
	if a != 0:
		need = int(skill(a + 0x4f).get("sp_cost", 255))
	elif u.ai == 7:
		return 1
	else:
		need = evb(4061)
	if u.sealed():
		return 0
	if u.person.sp < need:
		return 0
	return 2 if a != 0 else 1


## The first 武将技 1..0x4f the person knows with SP ≥ cost (0x4225a2), else 0 (重击).
static func pick_skill(u: BUnit) -> int:
	for k in range(1, 0x50):
		if knows_skill(u.pid, k) and u.person.sp >= int(skill(k).get("sp_cost", 255)):
			return k
	return 0


## AddSP 0x423930: unless forced, persons with id > EV 4030 get nothing; SP ≤ 255. Returns the gain.
static func add_sp(pid: int, n: int, force := false) -> int:
	if not force and pid > ev(4030):
		return 0
	var a := Mem.SP + pid
	var old := Mem.r8(a)
	var v := mini(old + n, 255)
	Mem.w8(a, v)
	return v - old


## SP gain when damaged 0x410fc3: ×2 with 集气加倍; kind < 2 a quarter, else half; at least 1 for damage > 0.
## Returns the SP gained (0x423930).
static func sp_gain(u: BUnit, dmg: int) -> int:
	if evb(4087) != 0 or evb(4059) == 1:
		return 0
	var g := dmg * (2 if u.eff(0x24, 0x41, 1, 0) != 0 else 1)
	g = g / 2 if u.kind >= 2 else g / 4
	if dmg > 0 and g == 0:
		g = 1
	return add_sp(u.pid, g)


## SpendSP 0x423910: SP −= min(SP, cost of 必杀 k).
static func spend_sp(pid: int, k: int) -> void:
	var a := Mem.SP + pid
	Mem.w8(a, sat_sub(Mem.r8(a), int(skill(k).get("sp_cost", 255))))


# ------------------------------------------------------------------ strategies (§2)
const MG_MF := 0
const MG_ID := 1
const MG_AI1 := 2
const MG_AI2 := 3
const MG_HIT := 4
const MG8 := 5
const MG_HURT := 6
const MG_HURTYN := 7
const MG_MEFF := 8
const MG_MCALL := 9


static func strat(s: int) -> Dictionary:
	return Game.strategy(s)


## Per-strategy extension table k (0x4d14e0 + 0x90·k).
static func mg(k: int, s: int) -> int:
	return Mem.r8(0x4d14e0 + 0x90 * k + s)


static func s_effect(s: int) -> int:
	return int(strat(s).get("effect", 0xff))


static func s_side(s: int) -> int:
	return int(strat(s).get("target", 0))


## Shown weather 0x41553b: table 0x48e100[climate·6 + level] (0 晴 1 阴 2 雨 3 暴雨 4 雪).
static func weather() -> int:
	return Mem.r8(0x48e100 + Mem.r8(B + 0x11) * 6 + Mem.r8(B + 4))


## MP cost 0x417b27: the record's cost, −节约MP %.
static func mp_cost(u: BUnit, s: int) -> int:
	var c := int(strat(s).get("mp", 0))
	var q := u.eff(0x2e, 0x39, 1, 0)
	if q:
		c = c * ((100 - q) & 0xff) / 100
	return c


## Menu filter 0x417af6: not sealed and enough MP.
static func can_cast(u: BUnit, s: int) -> bool:
	return not u.sealed() and u.mp >= mp_cost(u, s)


## Situation check 0x46fcf8: "" if usable now, else the original's message ("-" = refused without one).
## Effect 0 and 纵火 (34): bad weather refuses unless the weather is ignored (byte EV[4087] with [0x500af1] = 0, or
## 0x41ff0f 策略无视天气); 20 with MgID 24: HP < 3; 25 (四神, 0x41ff6e): mask 7 of 学会策略 ≥ 0x80 passes, else the
## item with effect 0x3a is needed, then the weather of 青龙 / 朱雀 / 玄武 (0x41ff0f only); 34 / 35: at most 10 map
## objects, 修筑 needs 1000 gold (message at 0x500ca7).
static func situation(s: int, u: BUnit) -> String:
	var e := s_effect(s)
	var w := weather()
	var ignore_w := u.eff(0x2a, 0x3a, 1, 1) != 0
	var id := mg(MG_ID, s)
	if e == 34 or e == 35:
		if Mem.r8(0x501ae1) >= 10:
			return "不能再添加了！"
		if e == 35:
			return "" if Game.gold >= 1000 else ScriptHost.read_cstr(0x500ca7, 64)
	if e == 0 or e == 34:
		if (ev(4087) != 0 and Mem.r8(0x500af1) == 0) or ignore_w or w < 2:
			return ""
		return "在恶劣天气时无法使用。"
	if e == 20 and id == 24 and u.hp < 3:
		return "ＨＰ不足。"
	if e == 25:
		if (Effects.any(u.pid, 0x50, 0x6c, 3, 0) & 0xff) >= 0x80:
			return ""
		if not Effects.has_item_effect(u.pid, 0x3a):
			var it := 0
			while it < 0xff and int(Game.item(it).get("type", -1)) != 0x3a:
				it += 1
			return "使用%s需要%s。" % [str(strat(s).get("name", "")), str(Game.item(it).get("name", ""))]
		if ignore_w:
			return ""
		match id:
			26: return "" if w >= 2 else "只能在恶劣天气时使用。"
			0: return "" if w == 0 else "只能在晴天时使用。"
			28: return "" if w == 1 else "只能在阴天时使用。"
	return ""


## Strategy learned by class level (0x41832b).
static func learned_by_level(p: Person, s: int) -> bool:
	var lv: Dictionary = strat(s).get("learn_level_by_class", {})
	var l := int(lv.get(str(p.cls), 0))
	return l != 0 and p.level >= l


## Strategy learned from the per-person list 0x507800 (0x40de69): an entry (level ≤ the person's level).
static func learned_by_table(p: Person, s: int) -> bool:
	var e := Effects.stream_find(Effects.LEARN, s, p.id, 0)
	return e >= 0 and Mem.r8(e) <= p.level


## Knows 0x41dc78(unit, s, onlyImitable): 学会策略 masks (QueryAny(0x49 + k, 0x6c, 3, 0)) against Mg8, or (k = 0)
## class level / person list; imitation only for strategies with MgMF bit 0.
static func knows(u: BUnit, s: int, only_imitable := false) -> bool:
	return _knows(u.person, s, only_imitable, learn_masks(u))


## The 8 学会策略 masks of a unit (QueryAny(0x49 + k, 0x6c, 3, 0), 0x43e1a8).
static func learn_masks(u: BUnit) -> Array:
	var out := []
	Effects.begin_cache()
	for k in 8:
		out.append(Effects.any(u.pid, 0x49 + k, 0x6c, 3, 0))
	Effects.end_cache()
	return out


static func _knows(p: Person, s: int, only_imitable: bool, masks: Array) -> bool:
	for k in 8:
		var m: int = masks[k]
		if (m != 0 and (m & mg(MG8, s)) != 0) or (k == 0 and (learned_by_level(p, s) or learned_by_table(p, s))):
			if not only_imitable or (mg(MG_MF, s) & 1):
				return true
	return false


## Strategies the unit knows, ascending (0x442a26 / the menu list); with `imitate` (策略模仿) the imitable ones of
## the 4 neighbours are added. Blank records (MgID ≥ 144 or no learner) never reach this list since nobody
## knows them.
static func known_strategies(u: BUnit, imitate := true) -> Array[int]:
	var out: Array[int] = []
	var masks := learn_masks(u)
	var p := u.person
	for s in 144:
		if _knows(p, s, false, masks):
			out.append(s)
	if imitate and u.eff(0x2d, 0x3b, 1, 1) != 0:
		for o in Effects.neighbours4(u):
			var om := learn_masks(o)
			for s in 144:
				if not out.has(s) and _knows(o.person, s, true, om):
					out.append(s)
		out.sort()
	return out


## Cast range code 0x401dff: record +0x0c through the 远距攻击-策略 upgrade.
static func strat_range(u: BUnit, s: int) -> int:
	return upgrade_code(u, 2, int(strat(s).get("range", 0xff)))


## Area code 0x41a10c: record +0x0d, widened by 辅助穿透-策略 when MgMF bit 1.
static func strat_area(u: BUnit, s: int) -> int:
	var a := int(strat(s).get("area", 0))
	if mg(MG_MF, s) & 2:
		a = pierce_upgrade(u, 2, a)
	return a


## Terrain / element table 0x420acc (0x419587): bit 0 火 1 水 2 风 3 地 per terrain (terrains 30.. read code bytes);
## effects other than the four elements are not terrain-bound.
static func elemental_ok(e: int, t: BUnit) -> bool:
	if e > 3:
		return true
	var bit := {0: 1, 1: 2, 3: 4, 2: 8}
	var terr := terrain_at(t.pos)
	return (Mem.r8(0x420acc + terr) & int(bit.get(e, 0))) != 0


## 0x41d90e: effect ≥ 25 always; effects 0..3 skip the terrain test with 策略无视地形 (or EV 4087).
static func ignores_terrain(c: BUnit, s: int) -> bool:
	var e := s_effect(s)
	if e >= 25:
		return true
	if e >= 4:
		return false
	return ev(4087) != 0 or c.eff(0x2b, 0x38, 1, 1) != 0


## Target validity 0x42044d(s, caster, target): "" = OK, else the message ("-" = refused without one). The waste
## checks only bind AI casters (AI code ≠ 7).
static func target_valid(s: int, c: BUnit, t: BUnit) -> String:
	var ai_caster := c.ai != 7
	if ignores_terrain(c, s):
		return ""
	var e := s_effect(s)
	if e <= 3:
		return "" if elemental_ok(e, t) else "不能在这里使用。"
	if e >= 15 and e <= 18 and ai_caster:
		var f := {15: 2, 16: 3, 17: 0, 18: 1}
		# the AI's "already has it" mask is 2 << table[e]; for 中毒 that is 32, which never matches (§3.1)
		var mask := 2 << int(f[e]) if e != 16 else 32
		if t.status_count(mask) != 0:
			return "-"
	if e == 22:
		if t == c:
			return "不能对我方部队使用。"
		if ai_caster and not ((t.flags & 6) != 0 and t.kind != 0):
			return "-"
	if ai_caster:
		match e:
			5: if c.hp == c.max_hp(): return "-"
			6: if c.mp == c.max_mp(): return "-"
			19: if t.hp == t.max_hp(): return "-"
			20: if t.mp == t.max_mp(): return "-"
			21: if t.status == 0: return "-"
	return ""


## Strategy hit rate 0x43b730(C, T, s).
static func strat_hit_rate(c: BUnit, t: BUnit, s: int) -> int:
	Effects.begin_cache()
	var r := _strat_hit_rate(c, t, s)
	Effects.end_cache()
	return r


static func _strat_hit_rate(c: BUnit, t: BUnit, s: int) -> int:
	var e := s_effect(s)
	if e == 33 and Mem.r32(t.addr) < 210:
		return 0
	if target_valid(s, c, t) != "":
		return 0
	if t.paralysed() and not s in [10, 31, 53]:
		return 100
	if c.eff(0x1b, 0x1b, 1, 1) != 0:
		return 100
	if t.eff(0x63, 0x4f, 1, 1) != 0 and s_side(s) == 0:
		return 0
	var p1 := stat_pair(c, 2, t, 2, false)
	var p2 := stat_pair(c, 4, t, 4, false)
	var r := hit_curve(p1[0] + p2[0], p1[1] + p2[1])
	r = sat_sub(r, t.eff(0x1d, 0x29, 1, 0))
	r = direction(c, t, r)
	if s < 150:
		var h := mg(MG_HIT, s)
		if h >= 5:
			r = 100 if h == 100 else r * h / 100
		elif h == 0:
			r = r * 90 / 100
		elif h == 1:
			r = 100
		elif h == 3 or h == 4:
			if t.slot == 0:
				r = 0
			elif t.pid == Mem.r16(0x492f90 + 0x3d06):
				r = (r & ~0xff) | (Mem.r16(0x492f90 + 0x3d06) & 0xff)
			else:
				r = r * (34 if h == 3 else 50) / 100
	if e == 5 and c.family() == 12:
		r = r * 3 / 2
	r = min_add(r, c.eff(0x1c, 0x26, 1, 0), 100)
	if c.eff(0x27, 0x20, 1, 0) != 0:
		r = min_add(r, 10, 100)
	return mini(r & 0xff, 100)


## Strategy hit test 0x43b4b6(T, kind 2, s) (the strategy context's caster / target must be set).
static func strat_hit_test(c: BUnit, t: BUnit, s: int) -> bool:
	return hit_roll(strat_hit_rate(c, t, s), 0x13)


## Strategy damage 0x43c01d(C, T, s, flag): flag 1 = a status strategy whose hit already rolled (no variance, no
## critical / 末日审判); preview = no rolls (the AI's evaluation). Returns the value (MP for 吸收MP; 換血 may be
## negative = a heal).
static func strat_damage(c: BUnit, t: BUnit, s: int, flag: int, preview := false) -> int:
	Effects.begin_cache()
	var r := _strat_damage(c, t, s, flag, preview)
	Effects.end_cache()
	return r


static func _strat_damage(c: BUnit, t: BUnit, s: int, flag: int, preview := false) -> int:
	if Mem.r8(STRAT_ITEM) == 1:
		return -1      # attack item used as a strategy: the caller supplies the item value
	var e := s_effect(s)
	var coef := mg(MG_HURT, s)
	if mg(MG_HURTYN, s) >= 4 and e != 30 and e != 6:
		return 0
	if flag == 0 and not preview and not strat_hit_test(c, t, s):
		return 0
	if target_valid(s, c, t) != "":
		return 0
	if e == 30:
		return t.hp - c.hp
	if coef == 255:
		return t.hp
	var p := stat_pair(c, 2, t, 2, true)
	var cv: int = p[0]
	var tv: int = p[1]
	var base := c.level() + 25
	var d: int
	if cv >= tv:
		d = base + (cv - tv) / Mem.r8(0x43c126)
	else:
		d = sat_sub(base, (tv - cv) / Mem.r8(0x43c139))
	d = d * coef / 100
	var f := t.family()
	if f <= 39:
		d = d * fam_attr(6, f) / 100
	var bonus := 0
	if e == 0:
		if terrain_at(t.pos) in [2, 23]:
			bonus = 25
	elif e in [1, 3, 38]:
		if weather() >= 2:
			bonus = 25
	elif e == 2:
		if c.family() == 7:
			bonus = 25
	d += d * bonus / 100
	if e == 5 and c.family() == 12:
		d *= 2
	var q := c.eff(0x27, 0x20, 1, 0) if e >= 4 else c.eff(0x28, 0x38, 1, 0)
	d += d * q / 100
	q = t.eff(0x29, 0x43, 1, 0)
	d = sat_sub(d, d * q / 100)
	d = modifiers(c, t, d, preview or flag == 1)
	if flag != 1 and not preview:
		d = strat_crit_doom(c, t, d)
	if Game.god:
		if t.side() == 1 and c.side() != 1:
			return 0
		if c.side() == 1 and t.side() != 1:
			d *= 20
	return mini(d, t.mp if e == 6 else t.hp)


## crit_and_doom 0x40ca68: 末日审判 (kind 2), then the centre target's critical: rate = (致命一击 bit 2 ? 100 : 0)
## + Curve(T's 士气, C's 士气); a rate ≤ 100 rolls (0x12) and adds 100; + rate/4 %.
static func strat_crit_doom(c: BUnit, t: BUnit, d: int) -> int:
	d = doom(c, d, t, 2)
	if t.slot == Mem.r8(STRAT_CTX + 0xd):
		var p := stat_pair(c, 4, t, 4, false)
		var v := (100 if (c.eff(0x33, 0x31, 3, 0) & 2) else 0) + crit_curve(p[1], p[0])
		if v <= 100:
			if not roll_acc(v, 0x12):
				return d
			v += 100
		d += d * (v / 4) / 100
		Mem.w8(STRAT_CTX + 3, 1)
	return d


## Heal amount 0x43c5df(T, s, C, preview): 八阵图 / 玄武 the missing HP; MP recovery the record's MP; the 補給 and 白虎
## by the caster's spirit (with terrain), + rand(11) when rand(200) < T's 士气; halved under poison; capped.
static func heal_amount(t: BUnit, s: int, c: BUnit, preview: bool) -> int:
	Effects.begin_cache()
	var r := _heal_amount(t, s, c, preview)
	Effects.end_cache()
	return r


static func _heal_amount(t: BUnit, s: int, c: BUnit, preview: bool) -> int:
	var id := mg(MG_ID, s)
	var h := 0
	if id == 12 or id == 28:
		h = t.max_hp() - t.hp
	elif id == 14:
		h = int(strat(s).get("mp", 0))
	elif id == 13 or id == 29:
		var v := unit_stat(c, 2, 0) * tile_effect(c, false) / 100
		h = v / 10 + 40 if mg(MG_HURT, s) == 0 else v / 2 + 70
		if not preview and rand(200) < unit_stat(t, 4, 0):
			h += rand(11)
	else:
		return 0
	if t.poisoned():
		h >>= 1
	if id == 14:
		return mini(h, t.max_mp() - t.mp)
	return mini(h, t.max_hp() - t.hp)


# ------------------------------------------------------------------ misc
## Wounded 0x439cfe: named persons at ≤ 40 % HP, generic ones at ≤ 20 % (never class 0x31 / family 0x32).
static func wounded(u: BUnit) -> bool:
	if u.hp == 0:
		return false
	var mh := u.max_hp()
	if Mem.r16(u.addr) < 0x400:
		return u.hp <= mh * 2 / 5
	if u.cls() == 0x31 or u.family() == 0x32:
		return false
	return u.hp <= mh / 5


## Recovery chances 0x43c72c(u, mode): mode 1 status / debuff (100 with 每回合恢复状态, else 士气 raw / 2), mode 0
## buff wear-off (raw > 100 → 10, else 60 − raw / 2).
static func recovery_chance(u: BUnit, m: int) -> int:
	var raw := u.person.get_raw(4)
	if m == 1:
		return 100 if u.eff(2, 0x1c, 1, 1) != 0 else raw / 2
	return 10 if raw > 100 else sat_sub(60, raw / 2)


## Buff level setter 0x43f98e: up → 6 from ≥ 3, else 3; down → 3 from > 3, else 0.
static func buff_step(b: int, up: bool) -> int:
	b = b - 256 if b >= 128 else b
	if up:
		return 6 if b >= 3 else 3
	return 3 if b > 3 else 0


## The stats a 攻击 buff code reaches (0x420cb4 / 0x4190e8): attack type 2 → 攻击, 1 → 精神, else both.
static func attack_buff_stats(u: BUnit) -> Array:
	match fam_attr(5, u.family()):
		2: return [0]
		1: return [2]
	return [0, 2]
