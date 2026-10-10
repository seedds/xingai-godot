class_name BattleAI
extends RefCounted
## The AI of the 6.6 engine (docs/ai.md §2.2, §4): the action order of a phase (0x44da7a) and the turn of one AI
## unit, AIAct 0x43ad3b — Prepare, the movement floods with the cell callback CellScore 0x43a55e, the physical and
## strategy target scoring, the movement modes (GoTarget / Active / passive / hold / retreat), the walk and the
## action (physical attack 0x43aaf7, 必杀, 军师技, strategy cast).
##
## The decision state is the original's "choice" (dest 0x4b2c20, retreat 0x4b2c24, target 0x4b2c28, best strategy
## target 0x4b2c2c, best physical target 0x4b2c30, forbidden cell 0x4b2c38, best strategy 0x4b2c40, chosen strategy
## 0x4b2c44, best score 0x4b2c4c) and the AI layers of buffer 0x48b0e0 (A +0: the opposite unit attackable from a
## cell, B +0x640: the cell scores); the flood grid and the walk path are the map buffer's (battle/movement.gd).
## UnitStat's 众志成城 scan (0x43cb00) writes the evaluated unit into 0x4b2c28 but saves and restores it around
## (0x43cc92), so the choice is not disturbed.
##
## The strategy evaluation rolls the dice as the original does (hit roll, spread, 末日审判, critical); the parts of the
## formulas that do not depend on the candidate cell or the draws are cached for one decision (`_sc`).

const NONE := 0xff
const NO_CELL := Vector2i(0xff, 0xff)

var st: BattleStage
var u: BUnit                 # the acting unit
var code := 0                # its AI code for this decision
var W := 0
var H := 0
var layer_a := PackedByteArray()
var layer_b := PackedByteArray()

# choice
var dest := NO_CELL
var retreat := false
var choice_target := NONE
var best_strat_target := NONE
var best_phys := NONE
var forbidden := NO_CELL
var best_strat := NONE
var choice_strategy := NONE
var best := 0
var strat_list: Array[int] = []

var _sc: Dictionary = {}     # per-decision cache
var _probe := false          # 危险区域 probe (byte 0x500ace): CellScore answers whether _probe_pid can be hit
var _probe_pid := -1
var _goal_ok := true         # GoalBonus: the unit's terrain effect at its cell ≠ 0xff
var _terrain_e := 0          # TerrainScore's terrain-effect part (the unit's own cell)


func _init(s: BattleStage) -> void:
	st = s


# ------------------------------------------------------------------ action order (0x44da7a)
## The friend phase orders slots 0..58 (slot 59 is never written — quirk), the enemy phase 60..249. Passes: 0 必杀
## users (都督's 军师技 family → 0x75, ordered last), 1 on a healing tile, 2 wounded, 3 casters (EV 4063 = 2: the
## family priorities of table 0x44dccc, then straight to pass 8), 4 (EV 4063 ≠ 0) attack or defence growth ≥ 4,
## 5 ranged, 6 family row 1 = 0, 7 everybody, 8 the 0x75 holders.
func compute_order(player_side: bool) -> void:
	var lo := 0 if player_side else 60
	var hi := 59 if player_side else 250
	for i in range(lo, hi):
		st.units[i].order = 0xff
	var ev63 := Rules.evb(4063)
	var n := 0
	var p := 0
	while p <= 8:
		if p == 4 and ev63 == 0:
			p += 1
			continue
		var custom := false
		for i in range(lo, hi):
			var x := st.units[i]
			if x.state != 2:
				continue
			if p == 3 and ev63 == 2:
				var m := _custom_order(i, hi, n)
				if m != n:
					n = m
					custom = true
					break
			if p == 8:
				if x.order == 0x75:
					x.order = n
					n += 1
			elif _order_pass(x, p) and x.order == 0xff:
				x.order = n
				n += 1
		p = 8 if custom else p + 1


func _order_pass(x: BUnit, p: int) -> bool:
	var f := x.family()
	match p:
		0:
			if Rules.can_use_skill(x) == 0:
				return false
			if Rules.fam_attr(8, f) == 9:
				x.order = 0x75
				return false
			return true
		1: return Rules.regen_pct(x.pos) != 0
		2: return Rules.wounded(x)
		3: return _caster_type(x) != 0 and f != 9
		4: return Person.class_growth(x.cls(), 0) >= 4 or Person.class_growth(x.cls(), 1) >= 4
		5: return Rules.is_ranged(x)
		6: return f <= 39 and Rules.fam_attr(1, f) == 0
	return true


## CustomOrder 0x44dc5b (EV 4063 = 2): priorities 0..5 of table 0x44dccc[family]; family 40 reads a byte that never
## matches, so such units get no order and never act (quirk).
func _custom_order(start: int, end: int, n: int) -> int:
	for t in 6:
		for j in range(start, end):
			var x := st.units[j]
			if x.state == 2 and x.order == 0xff and Mem.r8(0x44dccc + x.family()) == t:
				x.order = n
				n += 1
	return n


## CasterType 0x4190e8: family row 5 (2 武将 → 0, 1 文官 → 1, 0 全能 → 2); families ≥ 40 give 40.
func _caster_type(x: BUnit) -> int:
	var f := x.family()
	if f >= 40:
		return f
	var v := Rules.fam_attr(5, f)
	return v if v == 1 else v ^ 2


# ------------------------------------------------------------------ player-phase displays (§5.6)
## 危险区域 0x421cd6(E) without the display conditions (option byte 0x501a70, E.colour ≥ 2, a range overlay up, the
## current unit `cur` of code 7 — the caller's): E's movement flood in probe mode (byte 0x500ace, the scratch grid)
## stops at the first cell from which E's attack shape or its first listed strategy with a cast range reaches cur.
func threat(e: BUnit, cur: BUnit) -> bool:
	u = e
	code = e.ai
	W = Rules.map_w()
	H = Rules.map_h()
	forbidden = NO_CELL
	_sc.clear()
	_probe = true
	_probe_pid = cur.pid
	Mem.w8(Movement.PROBE, Mem.r8(Movement.PROBE) + 1)
	Effects.begin_cache()
	var r := _flood(e.pos, e.move_points(), 4, NO_CELL, 1)
	Effects.end_cache()
	Mem.w8(Movement.PROBE, Mem.r8(Movement.PROBE) - 1)
	_probe = false
	return r == 1


## AI仇恨 0x412f37(E) without the display conditions (cursor +0x64 == 1, or +0x68 == 1 with side(cur) == 1 — the
## caller's): 0 without a current unit or on its side; else the cache 0x5003a0[E] or max(1, PhysScore(E → cur,
## cell (0, 0)), BestStrategy(E, at cur's cell, given cur) unless E is under 禁咒), cached.
func ai_value(e: BUnit, cur: BUnit) -> int:
	if cur == null or e.side() == cur.side():
		return 0
	var v := Mem.r8(0x5003a0 + e.slot)
	if v != 0:
		return v
	u = e
	code = e.ai
	W = Rules.map_w()
	H = Rules.map_h()
	_sc.clear()
	Effects.begin_cache()
	v = _phys_score(cur, Vector2i.ZERO)
	if not e.sealed():
		_build_strat_list()
		# the given word is the slot with 0xff in its second byte: never 0 or 1, so no hit roll but the spread
		v = maxi(_best_strategy(cur.pos, 0xff00 | cur.slot), v)
	Effects.end_cache()
	v = maxi(v, 1) & 0xff
	Mem.w8(0x5003a0 + e.slot, v)
	return v


## 0x422386: the AI仇恨 cache is cleared when a move selection or an attack / cast ends.
func clear_ai_values() -> void:
	Mem.fill(0x5003a0, 250, 0)


# ------------------------------------------------------------------ AIAct (0x43ad3b)
## One unit's AI turn. Port-only: autoplay (WG_AUTO / WG_DEMO) runs player units (code 7) through here as code 1.
func act(unit: BUnit) -> void:
	var auto := unit.ai == 7 and (Game.autoplay or Game.demo)
	if auto:
		unit.ai = 1
	await _act(unit)
	if auto:
		unit.ai = 7


func _act(unit: BUnit) -> void:
	u = unit
	W = Rules.map_w()
	H = Rules.map_h()
	if W == 0 or H == 0:
		return                                  # port: no field loaded (a missing map), nothing to evaluate
	var mv := 100 if (u.flags & 0x80) else u.move_points() & 0xff
	forbidden = NO_CELL
	Mem.w32(0x4b2c1c, 0)
	st.set_current(u)
	Mem.w8(BattleStage.LAST_ACTION, 0xff)
	if u.target != NONE and (u.target >= st.units.size() or st.units[u.target].state != 2):
		u.target = NONE
		u.ai = 1
	if u.state != 2 or (u.flags & 2) or u.confused():
		Mem.w8(Rules.WALKED, 0)
		return
	code = u.ai
	_sc.clear()
	Effects.begin_cache()
	_prepare()
	if retreat and (u.flags & 0x80) == 0 and u.slot != 60:
		_retreat_move(mv)
	else:
		match code:
			0, 4:
				_go_target(mv)
			1:
				if _active(mv) == 0xff and u.pos == dest:
					_hold()
			2:
				_hold()
			3:
				if _flood(u.pos, 0xff, 8, NO_CELL, 1) != 0xff:
					_passive(mv)
				else:
					_hold()
	Effects.end_cache()
	await _move_along_path()
	_arrival()
	# [G] a unit that died on the way (先制攻击) does not act; the original's flow has no test here
	if (u.flags & 2) == 0 and (u.flags & 0x80) == 0 and u.ai != 4 and u.hp > 0:
		if not await st.strategy.family_special(u):
			if choice_strategy == NONE:
				await _physical_attack()
			else:
				var s := choice_strategy
				var cell := st.units[choice_target].pos if choice_target != NONE else u.pos
				if await st.strategy.cast(s, u, cell):
					u.flags = u.flags | 6
				Mem.w8(BattleStage.LAST_ACTION, 2)
				if s == 0x39:
					Mem.w32(Rules.B + 0x504, 1)
	if (u.flags & 0x80) == 0 and (u.flags & 4):
		u.flags = u.flags | 2
	Mem.w8(Rules.WALKED, 0)


## Hold: the own cell only (mode-4 flood with 0 move points); dest = the own cell.
func _hold() -> void:
	_flood(u.pos, 0, 4, NO_CELL, 1)
	dest = u.pos


# ------------------------------------------------------------------ Prepare (0x43a2ac)
## Layer A: for every opposite unit the cells from which this unit's attack shape reaches it (0x0b "cannot attack"
## read as 0 = the 4 neighbours; later slots overwrite earlier ones), then the 4 neighbours of opposite 左天羅右地網
## holders; layer B cleared; a wounded unit (codes other than 2 / 4) gets +50 on every healing tile and the retreat
## flag; the choice is reset.
func _prepare() -> void:
	var n := W * H
	layer_a.resize(n)
	layer_a.fill(0xff)
	layer_b.resize(n)
	var codes: Array = Rules.attack_codes(u)
	if codes[0] == 0x0b:
		codes = [0, codes[1], codes[2], codes[3]]
	var sd := u.side()
	for x: BUnit in st.units:
		if x.state == 2 and x.side() != sd:
			_stamp(x, codes)
	for x: BUnit in st.units:
		if x.state == 2 and x.side() != sd and x.eff(0x60, 0x7a, 1, 1) != 0:
			_stamp(x, [0, 0xff, 0xff, 0xff])
	layer_b.fill(0)
	retreat = false
	if Rules.wounded(u) and code != 2 and code != 4:
		for y in H:
			for x in W:
				if Rules.regen_pct(Vector2i(x, y)) != 0:
					var i := x + y * W
					layer_b[i] = (layer_b[i] + 50) & 0xff
		retreat = true
	best = 0
	choice_target = NONE
	dest = NO_CELL
	choice_strategy = NONE
	var e := Rules.tile_effect(u, false) & 0xff
	_goal_ok = e != 0xff
	_terrain_e = ((e + 0x9c) & 0xff) >> 3 if e > 100 else 0


## 0x436511(x, x.pos, codes, flags 0): every cell of the shape around x gets layer A = x's slot.
func _stamp(x: BUnit, codes: Array) -> void:
	for c in Rules.codes_cells(codes, x.pos):
		layer_a[c.x + c.y * W] = x.slot


# ------------------------------------------------------------------ floods
## Flood 0x438484 with this AI's callbacks; mode 4 first resets the choice and builds the strategy list (0x438560).
func _flood(start: Vector2i, mp: int, mode: int, target: Vector2i, zoc: int) -> int:
	if (mode & 4) and start != target:
		best = 0
		choice_target = NONE
		dest = NO_CELL
		choice_strategy = NONE
		_build_strat_list()
	return Movement.flood(u, start, mp, mode, target, zoc, _layer_a_at, _cell_score)


func _layer_a_at(c: Vector2i) -> int:
	return layer_a[c.x + c.y * W]


## BuildStratList 0x442a26(U, 2) → 0x465ac1: the strategies the unit knows (学会策略 masks, or for group 0 the class
## level / person list) whose record MP cost its MP covers, ascending; no imitation.
func _build_strat_list() -> void:
	if _sc.has("list"):
		return
	strat_list = []
	var masks := Rules.learn_masks(u)
	var p := u.person
	for s in 0x90:
		if Rules._knows(p, s, false, masks) and u.mp >= int(Rules.strat(s).get("mp", 0)):
			strat_list.append(s)
	_sc["list"] = true


# ------------------------------------------------------------------ CellScore (0x43a55e)
## Score of a reached cell (layer B accumulates over the floods of one decision); the best cell so far becomes the
## choice — ties: the later cell for codes 0 / 4, else the earlier one.
func _cell_score(c: Vector2i) -> int:
	var i := c.x + c.y * W
	if c != u.pos and Rules.slot_at(c) != 0xff:
		return 0xff
	if _probe:
		# probe mode: BestPhysical's answer, else the 禁咒 counter (a 1-turn seal reads as 1 — quirk), else
		# BestStrategy's; a code-4 or scripted unit is not evaluated [G: the original returns a stale register]
		if (u.flags & 0x80) or code == 4:
			return 0
		var a := _best_physical(c)
		if a != 0:
			return a
		var n := u.status_count(BUnit.ST_SEAL)
		return n if n != 0 else _best_strategy(c)
	var atk := 0
	var stv := 0
	if (u.flags & 0x80) == 0:
		if code != 4:
			if layer_a[i] != 0xff or c == u.pos:
				atk = _best_physical(c)
			if not u.sealed():
				stv = _best_strategy(c)
			layer_b[i] = mini(255, layer_b[i] + maxi(atk, stv))
		layer_b[i] += mini(_terrain_score(c), 255 - layer_b[i])
		if c == u.pos and atk == 0:
			layer_b[i] += mini(1, 255 - layer_b[i])
	if forbidden != NO_CELL and c == forbidden:
		layer_b[i] = 0
	var v := layer_b[i]
	if v < best:
		return 0xff
	if v == best and code != 0 and code != 4:
		return 0xff
	if atk < stv:
		choice_strategy = best_strat
		choice_target = best_strat_target if best_strat != 0x48 else best_phys
	else:
		choice_strategy = NONE
		choice_target = best_phys
	best = v
	dest = c
	return 0xff


## TerrainScore 0x452e18: a healing tile +8 below 20 % HP (byte 0x500af0 ≠ 2), else +1; plus (e − 100) / 8 for the
## terrain effect e > 100 of the unit's own cell (no candidate cell is set here).
func _terrain_score(c: Vector2i) -> int:
	var s := 0
	var t := Rules.terrain_at(c)
	if t >= 18 and t <= 22:
		s = 8 if Mem.r8(0x500af0) != 2 and u.hp < Rules.pct(20, u.max_hp()) else 1
	return (s + _terrain_e) & 0xff


# ------------------------------------------------------------------ physical scoring
## BestPhysical 0x438914(c): the opposite units in the attack shape around c (candidate cell 0x48e8c2 = c meanwhile);
## the approach walk (cells walked: 冲锋攻击); the highest PhysScore, ties: the later unit.
func _best_physical(c: Vector2i) -> int:
	Mem.w16(Rules.VTILE, c.x | (c.y << 8))
	best_phys = NONE
	var bv := 0
	var list := Rules.collect(u, c, Rules.attack_codes(u), 0x80)
	if not list.is_empty() and _probe:
		Mem.w16(Rules.VTILE, 0xffff)
		return 1 if _listed(list) else 0      # 0x421d6c
	if not list.is_empty():
		Movement.step_toward(u, u.pos, c, 0xff, 0)
		for t in list:
			var v := _phys_score(t, c)
			if v >= bv:
				bv = v
				best_phys = t.slot
	Mem.w16(Rules.VTILE, 0xffff)
	return bv


## PhysScore 0x4389bd(t, c).
func _phys_score(t: BUnit, c: Vector2i) -> int:
	var s := 0
	if t.slot < 0xfa:
		if u.target == t.slot:
			s = 98
		if (t.eff(0x53, 0x6f, 3, 0) & 1) != 0:
			s = 101                                   # 众矢之的: the byte is overwritten
		if t.side() != u.side():
			var d: int = Rules.calc_damage(u, t, true, 0)[0]
			if Rules.is_ranged(u) and t.eff(0x2f, 0x4e, 1, 1) != 0:
				return 1
			if not _worth(t):
				return 1
			if t.hp != 0:
				s += maxi(d * 100 / t.hp, 1)
	if t.paralysed():
		s += 8
	if s != 0:
		s += 8 if Mem.r32(t.addr) == Mem.r16(BattleStage.READER + 0x3d06) or t.slot == 60 else 4
	if s < 75 and _caster_type(u) == 1:
		return 0
	var a := Rules.phys_area(u)
	if a != 0xff and a != 0:
		s = _area_adjust(_area_hits(t, 1, a), s, 0, NONE)
	if s > 0 and Rules.attack_mode() != 2 and s > 1:
		# layer C: T's attack shape around T — a counter-attack is possible from c
		if Rules.codes_cells(Rules.attack_codes(t), t.pos).has(c):
			s -= 1
	return s


## 0x401e1d: false (score 1) when the unit's SP is below EV 4061, it lacks 忽视暴防, has 致命一击 bit 0 and the
## target has 防御致命攻击.
func _worth(t: BUnit) -> bool:
	return not (u.person.sp < Rules.evb(4061) and u.eff(0x70, 0x34, 1, 1) == 0
			and (u.eff(0x33, 0x31, 3, 0) & 1) != 0 and t.eff(0x30, 0x41, 1, 1) != 0)


## AreaHits 0x435941 → 0x4364c7 → 0x435ce9 around t (t not included, no HP test): kind 1 = the opposite side (any
## side during a mine detonation), 2 / 3 = the acting unit's side.
func _area_hits(t: BUnit, kind: int, a: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	var sd := u.side()
	for p in Rules.area_cells(a, t.pos, u.pos):
		var o := Rules.unit_at(p)
		if o == null:
			continue
		if kind != 1:
			if o.side() != sd:
				continue
		elif Mem.r8(Rules.ITEM_MODE) != 1 and o.side() == sd:
			continue
		out.append(o)
	return out


## AreaAdjust 0x438bf3(hits, v, kind, s): no unit → v − 2 (v > 4) else 2; per unit: kind 0 a kill +10 else +3
## (strategies: usable units only, +3 more for the AI target), 1 below 60 % HP +5, 2 attack buff < 4 +3, 3 / 4
## defence buff < 4 +3, 5 any ailment +3. At least 0.
func _area_adjust(hits: Array[BUnit], v: int, kind: int, s: int) -> int:
	if hits.is_empty():
		return v - 2 if v > 4 else 2
	var b := 0
	for h in hits:
		match kind:
			0:
				var d := 0
				if s == NONE:
					d = Rules.calc_damage(u, h, true, 0)[0]
				else:
					if not _usable(h, s):
						continue
					if h.slot == u.target:
						b += 3
					d = _strat_damage(h, s)
				b += 10 if d >= h.hp else 3
			1:
				if _usable(h, s) and h.hp * 100 / maxi(h.max_hp(), 1) < 60:
					b += 5
			2:
				if _usable(h, s) and h.buff(0) < 4:
					b += 3
			3, 4:
				if _usable(h, s) and h.buff(1) < 4:
					b += 3
			5:
				if _usable(h, s) and h.status != 0:
					b += 3
	return maxi(v + b, 0)


# ------------------------------------------------------------------ strategy scoring
## Per-decision data of strategy s: [BestStrategy's range codes (连击 33: the attack range), area, side 0x423cb3
## (2 read as 1), AI category (MgAIYN1, MgAIYN2 with EV 4087), cast range 0x401dff].
func _meta(s: int) -> Array:
	var m: Variant = _sc.get(s)
	if m == null:
		var rng := Rules.strat_range(u, s)
		var codes: Array = Rules.attack_codes(u) if s == 0x21 else [rng, 0xff, 0xff, 0xff]
		var side := Rules.s_side(s)
		m = [codes, Rules.strat_area(u, s), 1 if side == 2 else side,
				Rules.mg(Rules.MG_AI2 if Rules.ev(4087) != 0 else Rules.MG_AI1, s), rng]
		_sc[s] = m
	return m


## BestStrategy 0x439169(c, given): every listed strategy against the units in its cast range around c (given ≠ 0:
## against unit `given & 0xff` alone, in range or not, and the best strategy / target are not recorded); ties: the
## first strategy / target.
func _best_strategy(c: Vector2i, given := 0) -> int:
	if given == 0:
		best_strat_target = NONE
		best_strat = NONE
	var bv := 0
	var lists := {}
	for s in strat_list:
		var m := _meta(s)
		var codes: Array = m[0]
		var side: int = m[2]
		if side == 2:
			continue
		if codes[0] == 0xff:
			# no cast range: the area units around c (0x4358df) [G: dead with the shipped strategy data]
			var sum := 0
			for h in _self_area_hits(c, s, m):
				sum += _strat_score(h, s, c, given)
				if sum > 0:
					sum += _target_bonus(h)
			if sum > bv:
				bv = sum
				if given == 0:
					best_strat_target = NONE
					best_strat = s
			continue
		var key: int = (int(codes[0]) << 24) | (int(codes[1]) << 16) | (int(codes[2]) << 8) | int(codes[3]) | (side << 32)
		var list: Array[BUnit] = []
		if given != 0:
			list.append(st.units[given & 0xff])
		elif lists.has(key):
			list = lists[key]
		else:
			list = Rules.collect(u, c, codes, side | 0x80)
			lists[key] = list
			if _probe:
				return 1 if _listed(list) else 0      # the first strategy with a cast range answers (quirk)
		for t in list:
			var v := _strat_score(t, s, c, given)
			if v > 0:
				v += _target_bonus(t)
				if v > bv:
					bv = v
					if given == 0:
						best_strat_target = t.slot
						best_strat = s
	return bv


## 0x421d6c: the probed person is in the list.
func _listed(list: Array[BUnit]) -> bool:
	for x in list:
		if x.pid == _probe_pid:
			return true
	return false


func _self_area_hits(c: Vector2i, s: int, m: Array) -> Array[BUnit]:
	var out: Array[BUnit] = []
	var sd := u.side()
	for p in Rules.area_cells(m[1], c, u.pos):
		var o := Rules.unit_at(p)
		if o != null and (o.side() == sd) == (m[2] != 0):
			out.append(o)
	return out


## TargetBonus 0x40c854: an opposite 众矢之的 (bit 1) target 101, the AI target 98.
func _target_bonus(t: BUnit) -> int:
	if t.side() != u.side() and (t.eff(0x53, 0x6f, 3, 0) & 2) != 0:
		return 101
	if u.target == t.slot:
		return 98
	return 0


## Usable 0x4390ef(t, s): the situation check 0x46fcf8, the target check 0x42044d and the record's side byte (0 the
## other side, 1 the same side, else any).
func _usable(t: BUnit, s: int) -> bool:
	var key := 0x10000 + t.slot * 256 + s
	var r: Variant = _sc.get(key)
	if r != null:
		return r
	var ok := Rules.situation(s, u) == "" and Rules.target_valid(s, u, t) == ""
	if ok:
		match Rules.s_side(s):
			0: ok = t.side() != u.side()
			1: ok = t.side() == u.side()
	_sc[key] = ok
	return ok


## StratScore 0x4395dc(t, s, c, given) by the AI category of the strategy (jump table 0x43a140); `given` is passed
## on as the strategy damage flag.
func _strat_score(t: BUnit, s: int, c: Vector2i, given := 0) -> int:
	var m := _meta(s)
	var area: int = m[1]
	var ranged: bool = m[4] != 0xff
	if ranged and not _usable(t, s):
		return 0
	if s >= 0x90:
		return 0
	var hpp := t.hp * 100 / maxi(t.max_hp(), 1)
	var v := 0
	var area_kind := -1
	match m[3]:
		0, 1, 5:
			if not _usable(t, s):
				return 0
			var d := _strat_damage(t, s, given)
			if d >= 0:
				var p := maxi(d * 100 / maxi(t.hp, 1), 1)
				if p == 100:
					v = 100
				else:
					v = p
					if s == 43:                                   # 衰气
						v += _decline_bonus(t)
					elif s == 30:                                 # 吸血
						if u.hp < u.max_hp():
							v += 5
						if Rules.wounded(u):
							v += 10
					elif s == 48 or s == 49:                      # 定身 定军
						if not _adjacent8(u, t):
							v += 27
					elif s >= 31 and s <= 47:
						if hpp >= 40:
							v += 8
			area_kind = 0
		4:
			if not (_usable(t, s) and _hit_rate(t, s) >= 35):
				return 0
			v = 26 + (26 if hpp >= 80 else 0)
			area_kind = 0
		11:
			var mx := 0
			var n := 0
			for i in 4:
				if t.status & (3 << (2 * i)):
					mx = maxi(mx, Mem.r8(0x412793 + i))
					n += 1
			v = (mx + n + 5) & 0xff
			area_kind = 5
		7, 8, 9:
			if not Rules.wounded(t):
				return 0
			match s:
				55: return 50                                     # 小補給
				56: return 55
				59: return 60                                     # 输送
			v = 50
			area_kind = 1
		3:
			if _usable(t, s) and u.mp <= u.max_mp() / 5 and t.mp >= 30:
				return 20
			return 0
		6:
			if Rules.fam_attr(5, t.family()) == 2 or _hit_rate(t, s) >= 60:
				return 25 + (7 if (hpp & 0xff) >= 80 else 0)
			return 0
		10:
			if t.mp <= t.max_mp() / 5 and u.mp >= int(Rules.strat(s).get("mp", 0)) + 6:
				var f := t.family()
				if f == 9:
					return 1
				if _caster_type(t) != 0 or Effects.has_item_effect(t.pid, 0x48):
					return 12
				if f == 0:
					return 6
			return 0
		12:
			if t.ai == 2 or t.ai == 3 or (s == 89 and Rules.learned_by_level(t.person, s)):
				return 0
			var f := t.family()
			match f:
				9: return 0
				0, 19: return 15
				8: return 10
			return 10 + Rules.rand(5 if f == 5 else 4)
		2:
			if ((u.hp * 100 / maxi(u.max_hp(), 1)) & 0xff) > 40 and _caster_type(u) == 0:
				return 100 + (_best_physical(c) if given == 0 else 0)
			return 0
		14:
			var ct := _caster_type(t)
			if (s - 35) >> 1 == 0:
				if ct == 0:
					if t.buff(0) <= 3: return 0
					v = 10
				elif ct == 1:
					if t.buff(2) <= 3: return 0
					v = 10
				else:
					if t.buff(0) <= 3 and t.buff(2) <= 3: return 0
					v = 11
			else:
				if t.buff(1) < 3: return 0
				v = 12
			area_kind = 0
		15:
			var ct := _caster_type(t)
			if (s - 65) >> 1 == 0:
				if ct == 0:
					if t.buff(0) >= 3: return 0
					v = 10
				elif ct == 1:
					if t.buff(2) >= 3: return 0
					v = 10
				else:
					if t.buff(0) >= 3 and t.buff(2) >= 3: return 0
					v = 11
			else:
				if t.buff(1) >= 3: return 0
				v = 11
			area_kind = 0
		_:
			return 0
	if area_kind >= 0 and area != 0:
		# the area units are listed only for strategies with a cast range [G: the other case is dead]
		var hits: Array[BUnit] = _strat_hits(t, s, m) if ranged else ([] as Array[BUnit])
		v = _area_adjust(hits, v, area_kind, s)
	return v


## The area units around t for strategy s (kind = record side + 1), cached for the decision.
func _strat_hits(t: BUnit, s: int, m: Array) -> Array[BUnit]:
	var key := 0x20000 + t.slot * 256 + s
	var r: Variant = _sc.get(key)
	if r == null:
		r = _area_hits(t, Rules.s_side(s) + 1, m[1])
		_sc[key] = r
	return r


## 0x417a61 (衰气): 10, + table 0x481ded[i] for each of 攻 防 精 not lowered, + 1 more when raised (byte).
func _decline_bonus(t: BUnit) -> int:
	var v := 10
	for i in 3:
		var b := t.buff(i)
		if b > 2:
			v = (v + Mem.r8(0x481ded + i)) & 0xff
			if b != 3:
				v += 1
	return v


## 0x45afca(U, T, 1): T on one of the 8 cells around U.
func _adjacent8(a: BUnit, b: BUnit) -> bool:
	var d := b.pos - a.pos
	return a.state == 2 and b.state == 2 and absi(d.x) <= 1 and absi(d.y) <= 1 and d != Vector2i.ZERO


## Strategy hit rate 0x43b730 (no candidate cell during the strategy scoring: cached for the decision).
func _hit_rate(t: BUnit, s: int) -> int:
	var key := 0x30000 + t.slot * 256 + s
	var r: Variant = _sc.get(key)
	if r == null:
		r = Rules.strat_hit_rate(u, t, s)
		_sc[key] = r
	return r


## The AI's strategy damage 0x43c01d(U, t, s, flag) = Rules.strat_damage(u, t, s, flag) with its draws (flag 0: the
## hit roll; flag ≠ 1: the spread, 末日审判, the critical) made every time; the target check, the base value and the
## critical rate are cached.
func _strat_damage(t: BUnit, s: int, flag := 0) -> int:
	if Mem.r8(Rules.STRAT_ITEM) == 1:
		return -1
	var e := Rules.s_effect(s)
	var coef := Rules.mg(Rules.MG_HURT, s)
	if Rules.mg(Rules.MG_HURTYN, s) >= 4 and e != 30 and e != 6:
		return 0
	if flag == 0 and not Rules.hit_roll(_hit_rate(t, s), 0x13):
		return 0
	var key := 0x40000 + t.slot * 256 + s
	var base: Variant = _sc.get(key)
	if base == null:
		if Rules.target_valid(s, u, t) != "":
			base = -1
		elif e == 30:
			base = -2
		elif coef == 255:
			base = -3
		else:
			Effects.begin_cache()
			base = _strat_base(t, s, e, coef)
			Effects.end_cache()
		_sc[key] = base
	if base == -1:
		return 0
	if base == -2:
		return t.hp - u.hp
	if base == -3:
		return t.hp
	var d: int = Rules.modifiers(u, t, base, flag == 1)
	if flag != 1:
		d = _crit_doom(t, d)
	if Game.god:
		if t.side() == 1 and u.side() != 1:
			return 0
		if u.side() == 1 and t.side() != 1:
			d *= 20
	return mini(d, t.mp if e == 6 else t.hp)


## crit_and_doom 0x40ca68 (as Rules.strat_crit_doom, the rate cached).
func _crit_doom(t: BUnit, d: int) -> int:
	d = Rules.doom(u, d, t, 2)
	if t.slot == Mem.r8(Rules.STRAT_CTX + 0xd):
		var ck := 0x50000 + t.slot
		var v: Variant = _sc.get(ck)
		if v == null:
			var p := Rules.stat_pair(u, 4, t, 4, false)
			v = (100 if (u.eff(0x33, 0x31, 3, 0) & 2) else 0) + Rules.crit_curve(p[1], p[0])
			_sc[ck] = v
		var rate: int = v
		var crit := true
		if rate <= 100:
			crit = Rules.roll_acc(rate, 0x12)
			rate += 100
		if crit:
			d += d * (rate / 4) / 100
			Mem.w8(Rules.STRAT_CTX + 3, 1)
	return d


## 0x43c01d up to the spread (as Rules._strat_damage).
func _strat_base(t: BUnit, s: int, e: int, coef: int) -> int:
	var p := Rules.stat_pair(u, 2, t, 2, true)
	var cv: int = p[0]
	var tv: int = p[1]
	var base := u.level() + 25
	var d: int
	if cv >= tv:
		d = base + (cv - tv) / Mem.r8(0x43c126)
	else:
		d = Rules.sat_sub(base, (tv - cv) / Mem.r8(0x43c139))
	d = d * coef / 100
	var f := t.family()
	if f <= 39:
		d = d * Rules.fam_attr(6, f) / 100
	var bonus := 0
	if e == 0:
		if Rules.terrain_at(t.pos) in [2, 23]:
			bonus = 25
	elif e in [1, 3, 38]:
		if Rules.weather() >= 2:
			bonus = 25
	elif e == 2:
		if u.family() == 7:
			bonus = 25
	d += d * bonus / 100
	if e == 5 and u.family() == 12:
		d *= 2
	var q := u.eff(0x27, 0x20, 1, 0) if e >= 4 else u.eff(0x28, 0x38, 1, 0)
	d += d * q / 100
	q = t.eff(0x29, 0x43, 1, 0)
	return Rules.sat_sub(d, d * q / 100)


# ------------------------------------------------------------------ movement modes
## GoalBonus 0x43817b(cell, v): +v on a cell whose layer-B score is still 0 (empty or the unit's own), then v − 10
## (v > 10) or v − 1 on the 4 neighbours, down to 9; classes 15 / 16 do not spread it.
func _goal_bonus(cell: Vector2i, v: int) -> void:
	if v < 9 or not Rules.in_map(cell):
		return
	var i := cell.x + cell.y * W
	if _goal_ok and layer_b[i] == 0 and (cell == u.pos or Rules.slot_at(cell) == 0xff):
		layer_b[i] = v & 0xff
	var c := u.cls()
	if c == 15 or c == 16:
		return
	var nv := v - 10 if v > 10 else v - 1
	for d in Rules.DIR4:
		_goal_bonus(cell + d, nv)


func _step_toward(goal: Vector2i, from: Vector2i, mv: int) -> void:
	Movement.step_toward(u, goal, from, mv, 1, _goal_bonus)


## GoTarget (codes 0 / 4, 0x43af8b): toward the target unit (whose own target point is then forbidden when it goes
## for one) or the target point; attackable from a reachable cell → +20 there and the normal evaluation; else
## approach. Scripted moves (flag 0x80) only set the destination.
func _go_target(mv: int) -> void:
	var goal: Vector2i
	# the scripted move 0x4594ea sets its goal through the point setter 0x44268c, which clears the target: a
	# scripted unit always goes for its point (the port's BattleStage.scripted_move keeps the target)
	if u.target == NONE or (u.flags & 0x80):
		goal = u.point
	else:
		var tu := st.units[u.target]
		goal = tu.pos
		if tu.ai == 0 or tu.ai == 4:
			forbidden = tu.point
	if (u.flags & 0x80) == 0:
		var r := _flood(u.pos, mv, 8, NO_CELL, 1)
		if u.target != NONE and r == u.target:
			_goal_bonus(goal, 20)
			_flood(u.pos, mv, 4, NO_CELL, 1)
		else:
			_goal_bonus(goal, 10)
			if _flood(goal, 0xff, 2, u.pos, 1) == 1 or _flood(goal, 0xff, 2, u.pos, 0) != 0xff:
				_step_toward(goal, u.pos, mv)
				_flood(u.pos, mv, 4, NO_CELL, 1)
			else:
				_active(mv)
	else:
		if _flood(u.pos, 0xff, 2, goal, 1) == 1:
			dest = goal
		elif _flood(u.pos, 0xff, 2, goal, 0) == 0:
			dest = u.pos
			u.point = u.pos
		else:
			dest = goal


## Active 0x43a7c9 (code 1): with an attack cell in reach the normal evaluation (staying put returns the code
## outside pass 1 for codes < 4); otherwise approach the opposite unit whose attack cell an unlimited flood meets
## first (a friend unit with none reachable walks toward unit 0). 0xff after an approach or when nobody can be
## attacked anywhere, 0 when the unit moves or no way was found.
func _active(mv: int) -> int:
	if _flood(u.pos, mv, 8, NO_CELL, 1) != 0xff:
		Mem.w32(0x4b2c1c, 1)
		_flood(u.pos, mv, 4, NO_CELL, 1)
		if dest != u.pos:
			return 0
		if Mem.r8(0x500c47) != 1 and code < 4:
			return code
	var j := _flood(u.pos, 0xff, 8, NO_CELL, 1)
	if j == 0xff:
		dest = u.pos
		return 0xff
	var goal := st.units[j].pos
	if _flood(goal, 0xff, 2, u.pos, 1) == 1 or _flood(goal, 0xff, 2, u.pos, 2) != 0xff \
			or (u.kind == 1 and _flood(st.units[0].pos, 0xff, 2, u.pos, 1) == 1):
		_step_toward(goal, u.pos, mv)
		return _flood(u.pos, mv, 4, NO_CELL, 1)
	return 0


## PassiveAct 0x40debe (code 3): in the enemy phase a unit with an activity area first evaluates ignoring it and keeps
## that when it scores ≥ 100; else the normal evaluation.
func _passive(mv: int) -> void:
	if Mem.r8(Rules.B + 0x10) == 2 and Mem.r16(u.addr + 0x20) != 0xffff:
		_flood(u.pos, mv, 4, NO_CELL, 3)
		if best >= 100:
			return
	_flood(u.pos, mv, 4, NO_CELL, 1)


## Retreat (a wounded unit): toward unit 0 (player camp) or unit 60 when on the map; else Active.
func _retreat_move(mv: int) -> void:
	var goal := NO_CELL
	if u.side() == 1:
		goal = st.units[0].pos
	elif st.units[60].state == 2:
		goal = st.units[60].pos
	if goal == NO_CELL:
		_active(mv)
		return
	_goal_bonus(goal, 10)
	if _flood(goal, 0xff, 2, u.pos, 1) == 1:
		_step_toward(goal, u.pos, mv)
		_flood(u.pos, mv, 4, NO_CELL, 1)
	elif _flood(goal, 0xff, 2, u.pos, 0) == 0xff:
		_active(mv)
	else:
		_step_toward(goal, u.pos, mv)
		_flood(u.pos, mv, 4, NO_CELL, 1)


# ------------------------------------------------------------------ walking and acting
## MoveAlongPath 0x43a959: the walk to dest on the last flood's grid (the descent from dest, reversed).
func _move_along_path() -> void:
	if u.state != 2 or dest.x == 0xff or dest == u.pos:
		Mem.w8(Rules.WALKED, 0)
		return
	var dirs := Movement.step_toward(u, u.pos, dest, 0xff, 0)
	var cells: Array[Vector2i] = []
	var c := u.pos
	for d in dirs:
		c += Rules.DIR4[d]
		cells.append(c)
	# a scripted move toward an unreachable goal ends with a step onto the goal itself (docs/ai.md §7.3; the walker's
	# handling is untraced) [G: the walk stops before a cell the unit cannot take]
	while not cells.is_empty():
		var last: Vector2i = cells[-1]
		var o := Rules.slot_at(last)
		if (o != 0xff and o != u.slot) or Rules.move_cost(u, Rules.terrain_at(last)) == 0xff:
			cells.pop_back()
		else:
			break
	if cells.is_empty():
		Mem.w8(Rules.WALKED, 0)
		return
	if st.view != null:
		await st.view.ensure_visible(u.pos, not Game.autoplay)
	await st.actions.move_unit(u, cells)
	if (u.flags & 0x80) == 0:
		u.flags = u.flags | 4
	st.refresh_units()


## Arrival 0x43fcdf: a code 0 / 4 unit without a target unit standing on its point becomes passive (3).
func _arrival() -> void:
	if u.target == NONE and u.pos == u.point and (u.ai == 0 or u.ai == 4):
		u.ai = 3


## PhysicalAttack 0x43aaf7: the target is choice.target when it is in the attack shape around the unit, else the last
## unit collected; 必杀 when CanSpecial ≠ 0, 围攻 when helpers stand around an adjacent target (never with the shipped
## family data), else the attack command (pre-attack reactions, exchange, follow-up, support attacks).
func _physical_attack() -> void:
	Mem.fill(Mem.MAP_BUF + Movement.GRID_OFF, 0x640, 0xff)
	if Rules.ev(4087) != 0:
		# 练武场 (docs/duel.md §3.4): the fighter in slot 0, no range / weapon / flag tests
		Mem.w8(BattleStage.LAST_ACTION, 1)
		await st.actions.attack_command(u, st.units[0], false)
		u.flags = u.flags | 6
		st.refresh_units()
		return
	var list := Rules.collect(u, u.pos, Rules.attack_codes(u), 0)
	if (u.flags & 0x80) or u.ai == 4:
		return
	if not _weapon_ok(u.person):
		return
	if list.is_empty() or (u.flags & 2):
		return
	var t: BUnit = list[-1]
	for x in list:
		if x.slot == choice_target:
			t = x
			break
	st.actions.face(u, t.pos)
	if Rules.can_use_skill(u) != 0:
		await st.actions.bisha_attack(u, t)
	else:
		var helpers := _siege_helpers(t)
		var c0: int = Rules.attack_codes(u)[0]
		if not helpers.is_empty() and absi(u.pos.x - t.pos.x) <= 1 and absi(u.pos.y - t.pos.y) <= 1 \
				and c0 != 2 and c0 != 3 and c0 != 4 and st.actions.has_method("siege_command"):
			await st.actions.siege_command(u, t, helpers)
		else:
			Mem.w8(BattleStage.LAST_ACTION, 1)
			await st.actions.attack_command(u, t, true)
	u.flags = u.flags | 6
	st.refresh_units()


## 0x407961(person, weapon): an empty slot or an unknown item is fine; a consumable is not; else the class's equip
## flags (Person.can_equip).
func _weapon_ok(p: Person) -> bool:
	var w := p.weapon
	if w < 0:
		return true
	var it := Game.item(w)
	if it.is_empty():
		return true
	return Person.slot_of(it) != 3 and p.can_equip(w)


## SiegeHelpers 0x405bf2 → 0x416e53: same-side units on the 8 cells around the target whose family may join (row 7
## = 0; every shipped family has 1), not AI units holding a 必杀 (SP ≥ EV 4061), not done, not confused, whose attack
## shape class (0x40ae26, table 0x43784a: 0 orthogonal, 1 diagonal, 2 both) fits that cell.
func _siege_helpers(t: BUnit) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for k in 8:
		var h := Rules.unit_at(t.pos + Rules.DIR8[k])
		if h == null or h == u or h.side() != u.side():
			continue
		if Rules.fam_attr(7, h.family()) != 0:
			continue
		if h.ai != 7 and h.person.sp >= Rules.evb(4061):
			continue
		if (h.flags & 2) or h.confused():
			continue
		var cls := 0xff
		for cv: int in Rules.attack_codes(h):
			if cv == 0xff or cv > 32:
				continue
			var v := Mem.r8(0x43784a + cv)
			if v == 0xff:
				continue
			if v == 2:
				cls = 2
				break
			cls &= v
		if cls == 0xff or (cls != 2 and cls != (k >> 2)):
			continue
		out.append(h)
	return out
