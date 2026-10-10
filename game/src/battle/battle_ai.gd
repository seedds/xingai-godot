class_name BattleAI
extends RefCounted
## Unit AI (docs/rules.md §10.3–10.5, AIAct 0x43ad1c). AI codes (unit +0xe):
## 0 go for target person/point, 1 active, 2 hold, 3 passive, 4 follow/flee (never attacks), 7 player-controlled.

const HEAL_TERRAIN := [18, 19, 20, 21, 22]
const MAGIC_FAMILIES := [8, 9, 10, 18]

var st: BattleStage
var u: BUnit
var layer_a: Dictionary = {}     # cell -> attackable opposite unit
var layer_b: Dictionary = {}     # cell -> score
var best := 0
var dest := Vector2i(-1, -1)
var choice_strategy := -1
var choice_target: BUnit
var forbidden := Vector2i(-1, -1)
var retreat := false
var usable_strats: Array[int] = []
var grid: Dictionary = {}        # cell -> cost from the start of the last flood (0x4aeb38 + 0x12c0)

## Neighbour order of the original's floods and walks (0x4359f5, table 0x48df68): up, right, down, left.
const FDIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]


func _init(s: BattleStage) -> void:
	st = s


# ------------------------------------------------------------------ phase driver (§10.4)
func _compute_order(a: int, b: int) -> void:
	for i in range(a, b):
		st.units[i].order = 0xff
	var n := 0
	var passes := [
		func(x: BUnit) -> bool: return st.view.terrain_at(x.pos) in HEAL_TERRAIN,
		func(x: BUnit) -> bool: return _wounded(x),
		func(x: BUnit) -> bool: return x.family() in [8, 10, 18],
		func(x: BUnit) -> bool: return x.family() in Rules.RANGED_FAMILIES,
		func(x: BUnit) -> bool: return x.family() in [0, 3, 5, 7, 11, 12, 13, 15, 16, 17, 20, 24],
		func(_x: BUnit) -> bool: return true,
	]
	for p in passes:
		for i in range(a, b):
			var x := st.units[i]
			if x.state == BUnit.STATE_ON_MAP and x.order == 0xff and p.call(x):
				x.order = n
				n += 1


func run_phase(a: int, b: int) -> void:
	_compute_order(a, b)
	var skipped := {}      # units whose AIAct returned at once (乱/迷): no flags set, not picked again
	var guard := 0
	while guard < 200 and not st._battle_finished():
		guard += 1
		var pick: BUnit = null
		for i in range(a, b):
			var x := st.units[i]
			if skipped.has(i) or not x.active() or x.mode == 7:
				continue
			if x.flags & (BUnit.F_MOVED | BUnit.F_ACTED):
				continue
			if pick == null or x.order < pick.order:
				pick = x
		if pick == null:
			break
		if await act(pick):
			pick.flags |= BUnit.F_MOVED | BUnit.F_ACTED
		else:
			skipped[pick.slot] = true
		st.refresh_units()
		await st.checkpoint()


static func _wounded(x: BUnit) -> bool:
	if x.cls() == 0x31:
		return false
	if x.pid < 0x400:
		return x.hp * 5 <= x.max_hp() * 2
	return x.hp * 5 <= x.max_hp()


# ------------------------------------------------------------------ one unit
## AIAct (0x43ad1c). Returns false when the unit loses its turn: confused (乱) or lost (迷) units, and units
## that have already acted, return at once (10.5.4).
func act(unit: BUnit) -> bool:
	u = unit
	if not u.active():
		return false
	var mv := 100 if (u.flags & BUnit.F_PASS) else u.move_points()
	forbidden = Vector2i(-1, -1)
	var tslot := Mem.r8(u.addr + 8)
	if tslot != 0xff and (tslot >= 115 or st.units[tslot].state != BUnit.STATE_ON_MAP):
		Mem.w8(u.addr + 8, 0xff)
		u.mode = 1
	if (u.flags & BUnit.F_ACTED) or (u.status & (BUnit.ST_CONFUSION | BUnit.ST_LOST)):
		return false
	_prepare()
	grid = {}
	if retreat and not (u.flags & BUnit.F_PASS) and u.slot != 35:
		# fall back toward the own leader: unit 0 for the player side, unit 35 (if on the map) for the enemy
		var goal := Vector2i(-1, -1)
		if u.is_player_side():
			goal = st.units[0].pos
		elif st.units[35].state == BUnit.STATE_ON_MAP:
			goal = st.units[35].pos
		if st.view.in_bounds(goal):
			_goal_bonus(goal, 10)
			if _flood2(goal, u.pos, true) or _flood2(goal, u.pos, false):
				_step_toward(goal, mv, true)
				_flood4(u.pos, mv)
			else:
				_active(mv)
		else:
			_active(mv)
	else:
		match u.mode:
			0, 4:
				_go_target(mv)
			1:
				_active(mv)
			2:
				_flood4(u.pos, 0)
				dest = u.pos
			3:
				if _flood8(u.pos, mv) != null:
					_flood4(u.pos, mv)
				else:
					dest = u.pos
			7:
				_active(mv)      # player units under autoplay (WG_AUTO)
	# MoveAlongPath (0x43a956): walk to dest on the last flood's grid
	BUnit.move_origin = u.pos
	if dest.x >= 0 and dest != u.pos and grid.has(dest):
		await st.view.ensure_visible(u.pos)
		await st.actions.move_unit(u, _path_from(dest))
	_arrival()
	# act
	if not (u.flags & BUnit.F_PASS) and u.mode != 4 and u.active():
		if choice_strategy >= 0 and choice_target != null and choice_target.active():
			await st.actions.cast(u, choice_strategy, choice_target.pos)
		else:
			await _physical_attack()
	return true


func _prepare() -> void:
	layer_a.clear()
	layer_b.clear()
	best = 0
	dest = Vector2i(-1, -1)
	choice_strategy = -1
	choice_target = null
	retreat = false
	var code := st.actions.attack_range_code(u)
	for t in st.units:
		if t.active() and t.is_enemy_of(u):
			for c in Shapes.range_cells(code, t.pos, st.view.map_w, st.view.map_h):
				layer_a[c] = t
	if _wounded(u) and not (u.mode in [2, 4]):
		retreat = true
		for y in st.view.map_h:
			for x in st.view.map_w:
				var c := Vector2i(x, y)
				if st.view.terrain_at(c) in HEAL_TERRAIN:
					layer_b[c] = int(layer_b.get(c, 0)) + 50
	usable_strats.clear()
	if not (u.status & BUnit.ST_SEAL):
		for s in st.actions.known_strategies(u):
			# Usable (0x4390ef) also asks 0x41fec9, which does not depend on the target
			if st.actions.strategy_mp(s) <= u.mp and st.actions.cast_refusal(u, s) == "":
				usable_strats.append(s)


# ------------------------------------------------------------------ flood (0x438308)
## The original's flood from `start` over U's move costs: cost levels in increasing order, each level's cells
## row by row, each opening its 4 neighbours in FDIRS order. A neighbour is taken if it is unvisited, passable,
## within `mp` and not held by an opposite unit (unless !zoc and U may pass); with `zoc`, cells in an enemy zone
## of control (other than the start) do not open their neighbours. `on_cell` sees each newly reached cell in that
## order and stops the flood by returning true. Fills `grid`. Returns false if the start's terrain is impassable.
func _flood(start: Vector2i, mp: int, zoc: bool, on_cell: Callable) -> bool:
	grid = {start: 0}
	if Rules.move_cost(u, st.view.terrain_at(start)) >= 255:
		return false
	var can_pass := (u.flags & BUnit.F_PASS) != 0
	var buckets := {0: [start]}
	var level := 0
	while level < mp:
		var cells: Array = buckets.get(level, [])
		buckets.erase(level)
		cells.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
		for c: Vector2i in cells:
			if c != start and zoc and st.actions.in_zoc(u, c):
				continue
			for d in FDIRS:
				var n := c + d
				if not st.view.in_bounds(n) or grid.has(n):
					continue
				var cost := Rules.move_cost(u, st.view.terrain_at(n))
				if cost >= 255 or level + cost > mp:
					continue
				var o := st.unit_at(n)
				if o != null and o.is_enemy_of(u) and (zoc or not can_pass):
					continue
				grid[n] = level + cost
				if not buckets.has(level + cost):
					buckets[level + cost] = []
				buckets[level + cost].append(n)
				if on_cell.call(n):
					return true
		if buckets.is_empty():
			break
		level = buckets.keys().min()
	return true


## Flood mode 8: the opposite unit attackable from the first reached cell that has one (layer_a), or null.
## The start cell itself is not looked at.
func _flood8(start: Vector2i, mp: int) -> BUnit:
	var hit: Array = [null]
	_flood(start, mp, true, func(n: Vector2i) -> bool:
		if layer_a.has(n):
			hit[0] = layer_a[n]
			return true
		return false)
	return hit[0]


## Flood mode 2: is `goal` reached from `start` (ignoring the move limit)?
func _flood2(start: Vector2i, goal: Vector2i, zoc: bool) -> bool:
	if start == goal:
		return false
	var found: Array = [false]
	_flood(start, 255, zoc, func(n: Vector2i) -> bool:
		if n == goal:
			found[0] = true
			return true
		return false)
	return found[0]


## Flood mode 4: reset the choice and score the start (unless U may pass) and every reached cell (CellScore).
func _flood4(start: Vector2i, mp: int) -> void:
	best = 0
	dest = Vector2i(-1, -1)
	choice_strategy = -1
	choice_target = null
	if not (u.flags & BUnit.F_PASS):
		_cell_score(start)
	_flood(start, mp, true, func(n: Vector2i) -> bool:
		_cell_score(n)
		return false)


func _cell_score(c: Vector2i) -> void:
	var occ := st.unit_at(c, u)
	if occ != null:
		return
	var atk := 0
	var stv := 0
	var phys_t: BUnit = null
	var strat := -1
	var strat_t: BUnit = null
	var v := int(layer_b.get(c, 0))
	if u.mode != 4:
		if layer_a.has(c) or c == u.pos:
			var r := _best_physical(c)
			atk = r[0]
			phys_t = r[1]
		if not (u.status & BUnit.ST_SEAL):
			var r2 := _best_strategy(c)
			stv = r2[0]
			strat = r2[1]
			strat_t = r2[2]
		v += maxi(atk, stv)
	v = mini(255, v + _terrain_score(c))
	if c == u.pos and atk == 0:
		v = mini(255, v + 1)
	if c == forbidden:
		v = 0
	layer_b[c] = v
	if v > best:
		best = v
		dest = c
		if stv > atk:
			choice_strategy = strat
			choice_target = strat_t
		else:
			choice_strategy = -1
			choice_target = phys_t


func _terrain_score(c: Vector2i) -> int:
	var t := st.view.terrain_at(c)
	if t in HEAL_TERRAIN:
		return 8
	var e := Rules.terrain_effect(u, st.view.terrain_at(u.pos))
	return maxi(e - 10, 0)


func _best_physical(c: Vector2i) -> Array:
	var bestv := 0
	var bt: BUnit = null
	for cell in st.actions.attack_cells(u, c):
		var t := st.unit_at(cell)
		if t == null or t == u or not t.active() or not t.is_enemy_of(u):
			continue
		var s := _phys_score(t, c)
		if s > bestv:
			bestv = s
			bt = t
	return [bestv, bt]


func _phys_score(t: BUnit, c: Vector2i) -> int:
	var s := 0
	var d := Rules.calc_damage(u, t, st.view.terrain_at(u.pos), st.view.terrain_at(t.pos), false, 0)
	var mh := maxi(t.max_hp(), 1)
	if d >= t.hp:
		s = 80
	elif d * 10 / mh >= 1:
		s = 16
	elif t.hp * 100 / mh <= 40:
		s = 16
	elif u.mode == 1:
		s = 10
	else:
		s = 2
	if t.status & BUnit.ST_CONFUSION:
		s += 8
	if s > 0 and t.pid < 0x400:
		s += 8 if (t.pid == st.boss_pid or t.slot == 35) else 4
	if s < 75 and u.family() in MAGIC_FAMILIES:
		return 0
	if s > 1 and st.actions.can_attack(t, u, t.pos) and Shapes.range_cells(st.actions.attack_range_code(t), t.pos, st.view.map_w, st.view.map_h).has(c):
		s -= 1
	return s


func _best_strategy(c: Vector2i) -> Array:
	var bestv := 0
	var bs := -1
	var bt: BUnit = null
	for s in usable_strats:
		var sd := Game.strategy(s)
		var side_opp := s <= 38 or s >= 64
		var cast := Shapes.range_cells(int(sd.get("range", 0)), c, st.view.map_w, st.view.map_h, not side_opp)
		for cell in cast:
			var t := st.unit_at(cell)
			if t == null or not t.active():
				continue
			if t == u and side_opp:
				continue
			if side_opp != t.is_enemy_of(u) and t != u:
				continue
			if not side_opp and t.is_enemy_of(u):
				continue
			if not st.actions.usable_on(u, s, t):
				continue
			var v := mini(_strat_score(t, s, c), 255)
			if v <= 0:
				continue
			if int(sd.get("area", 0)) != 0:
				v = _area_adjust(s, cell, v, side_opp)
			if v > bestv:
				bestv = v
				bs = s
				bt = t
	return [bestv, bs, bt]


func _strat_score(t: BUnit, s: int, _c: Vector2i) -> int:
	var hpp := t.hp * 100 / maxi(t.max_hp(), 1)
	if s in [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 15, 16, 17, 18, 19, 20, 33, 34, 35, 36]:
		if not Rules.strat_terrain_ok(s, u, st.view.terrain_at(t.pos), st.weather()) and s <= 19:
			return 0
		var d := Rules.strat_damage(u, t, s, true)
		var mh := maxi(t.max_hp(), 1)
		var v := 1
		if d >= t.hp: v = 76
		elif d * 10 / mh >= 3: v = 30
		elif d * 10 / mh >= 1: v = 10
		if s == 20:
			if u.hp < u.max_hp(): v += 5
			if _wounded(u): v += 10
		if s in [33, 34] and hpp >= 40: v += 8
		if s in [35, 36] and Grid.manhattan(t.pos, u.pos) != 1: v += 10
		return v
	match s:
		21, 31, 32:
			var h := Rules.strat_hit(u, t, s, st.view.terrain_at(t.pos), st.weather())
			if h >= 35:
				return 15 + (15 if hpp >= 80 else 0)
			return 0
		22:
			return 20 if (u.mp <= u.max_mp() / 5 and t.mp >= 30) else 0
		37:
			if t.family() in [8, 9, 10, 11, 18, 19, 20] and Rules.strat_hit(u, t, s, st.view.terrain_at(t.pos), st.weather()) >= 60:
				return 15 + (7 if hpp >= 80 else 0)
			return 0
		39, 40, 43:
			return (50 + (5 if s == 40 else (10 if s == 43 else 0))) if _wounded(t) else 0
		41, 42:
			return 50 if _wounded(t) else 0
		44, 45, 62:
			if t.mp <= t.max_mp() / 5 and u.mp >= st.actions.strategy_mp(s):
				if t.family() == 9: return 1
				if t.family() in MAGIC_FAMILIES: return 12
				if t.family() == 0: return 6
			return 0
		46, 47:
			var v2 := 5
			if t.status == BUnit.ST_PARALYSIS and not (t.mode in [2, 3]): v2 += 25
			elif t.status == BUnit.ST_SEAL and t.family() in MAGIC_FAMILIES: v2 += 30
			elif t.status == BUnit.ST_CONFUSION: v2 += 35
			return v2 if t.status != 0 else 0
		57:
			if t.mode in [2, 3] or t.family() == 9: return 0
			if t.family() in [0, 19]: return 15
			if t.family() == 5: return 10 + Rules.rand(4)
			if t.family() == 8: return 10
			return Rules.rand(5)
	return 0


func _area_adjust(s: int, center: Vector2i, v: int, side_opp: bool) -> int:
	var hits: Array[BUnit] = []
	for cell in Shapes.area_cells(int(Game.strategy(s).get("area", 0)), u.pos, center, st.view.map_w, st.view.map_h):
		if cell == center:
			continue
		var t := st.unit_at(cell)
		if t and t.active() and (t.is_enemy_of(u) == side_opp):
			hits.append(t)
	if hits.is_empty():
		return v - 4 if v > 4 else 0
	for t in hits:
		if not st.actions.usable_on(u, s, t):
			continue
		if side_opp:
			v += 3
		elif s >= 39 and s <= 45:
			if t.hp * 100 / maxi(t.max_hp(), 1) < 60:
				v += 5
		elif s in [46, 47]:
			if t.status != 0:
				v += 3
		else:
			v += 3
	return maxi(v, 0)


# ------------------------------------------------------------------ movement helpers (§10.5.2)
## GoalBonus (0x438178): +v on `cell` if it has no score yet and is free (or U's own cell), then v−10 (v > 10) or
## v−1 on its neighbours, down to 9; classes 15 and 16 do not spread it. (The original also requires U's
## terrain effect on its own cell to be ≠ 0xff, which always holds.)
func _goal_bonus(cell: Vector2i, v: int) -> void:
	if v < 9:
		return
	if st.view.in_bounds(cell) and int(layer_b.get(cell, 0)) == 0:
		var occ := st.unit_at(cell)
		if occ == null or cell == u.pos:
			layer_b[cell] = v
	if u.cls() in [15, 16]:
		return
	for d in FDIRS:
		var n := cell + d
		if st.view.in_bounds(n):
			_goal_bonus(n, v - 1 if v < 11 else v - 10)


## One greedy step toward lower `grid` values: the first neighbour (FDIRS order) with the smallest value below
## the current cell's whose move cost fits in `rem`; cells in an enemy zone of control are skipped unless they are
## `goal` or U may pass. Returns [cell, cost], or [] when no step is possible.
func _descend(p: Vector2i, goal: Vector2i, rem: int) -> Array:
	var bestv: int = grid.get(p, 0xff)
	var out: Array = []
	for d in FDIRS:
		var n := p + d
		if not st.view.in_bounds(n):
			continue
		if st.actions.in_zoc(u, n) and n != goal and not (u.flags & BUnit.F_PASS):
			continue
		var g: int = grid.get(n, 0xff)
		if g < bestv:
			var cost := Rules.move_cost(u, st.view.terrain_at(n))
			if cost <= rem:
				bestv = g
				out = [n, cost]
	return out


## StepToward (0x437e2e) on the grid of a flood from `goal`: walk from U's cell within mv; if it stops short and
## `bonus`, GoalBonus there (20 if a unit stands on the end cell, U included, else 10).
func _step_toward(goal: Vector2i, mv: int, bonus: bool) -> void:
	var p := u.pos
	var rem := mv
	while p != goal:
		var step := _descend(p, goal, rem)
		if step.is_empty():
			if bonus:
				_goal_bonus(p, 20 if st.unit_at(p) != null else 10)
			return
		p = step[0]
		rem -= int(step[1])


## The walk to `dest` (0x4d3a2d → 0x437e2e(U, U.pos, dest, 255, 0)): descend the last flood's grid from dest to
## U's cell, then reverse it.
func _path_from(to: Vector2i) -> Array[Vector2i]:
	var back: Array[Vector2i] = []
	var p := to
	var rem := 255
	while p != u.pos:
		back.append(p)
		var step := _descend(p, u.pos, rem)
		if step.is_empty():
			break
		p = step[0]
		rem -= int(step[1])
	back.reverse()
	return back


## Active (0x43a7c9, code 1): evaluate normally if an attack cell is reachable now; else head for the opposite
## unit whose attack cell the flood reaches first (move limit ignored), if a path to it exists.
func _active(mv: int) -> void:
	if _flood8(u.pos, mv) != null:
		_flood4(u.pos, mv)
		return
	var j := _flood8(u.pos, 255)
	if j == null:
		dest = u.pos
		return
	var goal := j.pos
	if _flood2(goal, u.pos, true) or _flood2(goal, u.pos, false):
		_step_toward(goal, mv, true)
		_flood4(u.pos, mv)


## GoTarget (0x43afd4, codes 0 and 4): the target unit's cell (if that unit itself goes for a target, its target
## point is forbidden), else the target point.
func _go_target(mv: int) -> void:
	var tslot := Mem.r8(u.addr + 8)
	var goal: Vector2i
	if tslot != 0xff and tslot < 115:
		var tu := st.units[tslot]
		goal = tu.pos
		if tu.mode in [0, 4]:
			forbidden = Vector2i(Mem.r8(tu.addr + 9), Mem.r8(tu.addr + 10))
	else:
		goal = Vector2i(Mem.r8(u.addr + 9), Mem.r8(u.addr + 10))
	if u.flags & BUnit.F_PASS:
		if not _flood2(u.pos, goal, true):
			_flood2(u.pos, goal, false)
		dest = goal
		return
	var r := _flood8(u.pos, mv)
	if tslot != 0xff and r != null and r.slot == tslot:
		_goal_bonus(goal, 20)
		_flood4(u.pos, mv)
		return
	_goal_bonus(goal, 10)
	if _flood2(goal, u.pos, true):
		_step_toward(goal, mv, true)
		_flood4(u.pos, mv)
	elif not _flood2(goal, u.pos, false):
		_active(mv)
	else:
		_step_toward(goal, mv, true)
		_flood4(u.pos, mv)


func _arrival() -> void:
	if Mem.r8(u.addr + 8) == 0xff and u.mode in [0, 4]:
		var tp := Vector2i(Mem.r8(u.addr + 9), Mem.r8(u.addr + 10))
		if u.pos == tp:
			u.mode = 3


func _physical_attack() -> void:
	if u.mode == 4 or (u.flags & BUnit.F_PASS):
		return
	var t := choice_target
	if t == null or not t.active() or not st.actions.can_attack(u, t):
		t = null
		for c in st.actions.attack_cells(u, u.pos):
			var x := st.unit_at(c)
			if x and x.active() and x.is_enemy_of(u):
				t = x
	if t == null:
		return
	await st.actions.attack(u, t)
	if not t.active() and u.active() and u.has_effect(46):
		for c in st.actions.attack_cells(u, u.pos):
			var x := st.unit_at(c)
			if x and x.active() and x.is_enemy_of(u):
				await st.actions.attack(u, x)
				break
