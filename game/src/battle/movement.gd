class_name Movement
extends RefCounted
## The movement search of the 6.6 engine (docs/battle.md §6.4, docs/ai.md §4.3 / §4.7): the level-ordered flood
## 0x438484 over the map buffer's cost grid (+0x12c0), the zone-of-control / stop-cell test 0x437d59, the AI's
## activity area 0x4077f6 and the greedy path walk 0x437e23 (path directions at +0x1900). The first cost written to
## a cell stays (no relaxation), so the scan order — levels ascending, rows, neighbours up/right/down/left —
## decides the result, as in the original.

const GRID_OFF := 0x12c0
const PATH_OFF := 0x1900
const PROBE_OFF := 0x9c50       # probe mode (0x500ace): the original uses MapBuf+0; the port a free scratch area
const PROBE := 0x500ace

## Last flood result kinds
const NONE := 0xff


static func w() -> int:
	return Mem.r8(Mem.MAP_WH)


static func h() -> int:
	return Mem.r8(Mem.MAP_WH + 1)


static func grid_base() -> int:
	return Mem.MAP_BUF + (PROBE_OFF if Mem.r8(PROBE) != 0 else GRID_OFF)


static func idx(c: Vector2i) -> int:
	return c.x + c.y * w()


## Cost of the last flood at cell c (0xff = not reached; off the map 0xff).
static func grid_at(c: Vector2i) -> int:
	if not Rules.in_map(c):
		return 0xff
	return Mem.r8(grid_base() + idx(c))


static func set_grid(c: Vector2i, v: int) -> void:
	if Rules.in_map(c):
		Mem.w8(grid_base() + idx(c), v)


## Move limit rectangle 0x4362e6 ([0x501bf0] = {x, y, w, h}; 0 = none).
static func in_move_rect(c: Vector2i) -> bool:
	var r := Mem.r32(Rules.MOVE_RECT)
	if r == 0:
		return true
	var x0 := r & 0xff
	var y0 := (r >> 8) & 0xff
	var rw := (r >> 16) & 0xff
	var rh := (r >> 24) & 0xff
	return x0 <= c.x and y0 <= c.y and c.x < ((x0 + rw) & 0xff) and c.y < ((y0 + rh) & 0xff)


## "Home side" 0x42e2ed (EV 4019 = 1, 深入敌后 超级卡位): slots < 20 → 0, < 60 → 1, else the kind (5 → 2 and
## 6 → 3 unless the control counter 0x501ad8 is set; 3 / 6-as-3 → +1 with EV 4053), through table 0x40672d.
static func home_side(u: BUnit) -> int:
	var k := 0
	if u.slot >= 20:
		if u.slot < 60:
			k = 1
		else:
			k = u.kind
			if k != 2:
				if k == 5:
					if Mem.r8(0x501ad8 + u.slot) == 0:
						k = 2
				else:
					if k == 3 or (k == 6 and Mem.r8(0x501ad8 + u.slot) == 0):
						if k == 6:
							k = 3
						if Mem.r8(Mem.EV + 4 * 4053) != 0:
							k += 1
	return Mem.r8(0x40672d + k)


## Hostile 0x42e2b7: sides differ, by side() or (use_side false) by the EV 4019 side function.
static func hostile(a: BUnit, b: BUnit, use_side: bool) -> bool:
	if use_side or Mem.r32(Mem.EV + 4 * 4019) == 0:
		return a.side() != b.side()
	return home_side(a) != home_side(b)


## AiAreaOK 0x4077f6 → 0x414f05: AI codes 7 and even codes move freely, as does a unit outside its activity box
## (corners +9/+0xa and +0x20/+0x21, inclusive, unsigned bytes) or one whose corner 2 is 0xffff; a unit inside it
## stays inside.
static func ai_area_ok(u: BUnit, c: Vector2i) -> bool:
	var code := u.ai
	if code == 7 or (code & 1) == 0 or Mem.r16(u.addr + 0x20) == 0xffff:
		return true
	var x1 := Mem.r8(u.addr + 9)
	var y1 := Mem.r8(u.addr + 0xa)
	var x2 := Mem.r8(u.addr + 0x20)
	var y2 := Mem.r8(u.addr + 0x21)
	var p := u.pos
	if x1 <= p.x and p.x <= x2 and y1 <= p.y and p.y <= y2:
		if c.x < x1 or x2 < c.x or c.y < y1 or y2 < c.y:
			return false
	return true


## Trap 0x428b7a (counting form, trigger 0): for a player-controlled mover (m = 4) entering an empty cell, the
## hostile units whose 先制攻击 (Q(0x52, 0x51, 0, 0) > their +0x22 count) range covers it. Mines (0x4749b5,
## modern-war maps) are not implemented [open item].
static func trap_count(u: BUnit, c: Vector2i) -> int:
	if u.flags & 0x80 or u.ai != 7:
		return 0
	if Rules.slot_at(c) != 0xff:
		return 0
	var n := 0
	for x: BUnit in Effects.battle.units:
		if x.state != 2 or x.side() == u.side() or x.hp == 0:
			continue
		var v := x.eff(0x52, 0x51, 0, 0)
		if v != 0 and x.byte(0x22) < (v & 0xff) and Rules.in_attack_range(x, x.pos, c):
			n += 1
			return n
	return n


## InEnemyZOC / StopCell 0x437d59: a 先制攻击 trap stops; 穿越移动 or 突击移动 ignore zones; otherwise a hostile unit
## on an orthogonal neighbour makes the cell a stop cell (enterable, not left).
static func in_enemy_zoc(u: BUnit, c: Vector2i, use_side: bool) -> bool:
	if trap_count(u, c) != 0:
		return true
	if Rules.passes(u) or u.eff(0x37, 0x29, 1, 1) != 0:
		return false
	for d in Rules.DIR4:
		var o := Rules.unit_at(c + d)
		if o != null and hostile(u, o, use_side):
			return true
	return false


## Flood 0x438484(U, start, mp, mode, target, zoc). Modes: 0 plain; 8 → returns layer_a(cell) of the first
## reached empty cell whose layerA unit is on the map; 2 → 1 when `target` is reached; 4 → 1 when cell_score(cell)
## == 1 (probe mode only). zoc: 0 no zones (hostile units block), 1 zones, 2 no zones and nobody blocks, 3 like 1
## without the activity area. Returns 0xff when nothing stopped the flood. The mode-4 choice reset and strategy
## list (0x438560..) are the caller's (they come before any cell is scored).
static func flood(u: BUnit, start: Vector2i, mp: int, mode: int, target: Vector2i, zoc: int,
		layer_a: Callable = Callable(), cell_score: Callable = Callable()) -> int:
	var scripted := (u.flags & 0x80) != 0
	var zoc_on := (zoc & 1) != 0
	if start == target:
		return NONE
	var W := w()
	var H := h()
	var g := grid_base()
	if Mem.r8(PROBE) == 0:
		Mem.w8(Mem.MAP_BUF + PATH_OFF, 0xff)
	Mem.fill(g, W * H, 0xff)
	Mem.w8(g + start.x + start.y * W, 0)
	if (mode & 4) and not scripted and cell_score.is_valid():
		if cell_score.call(start) == 1:
			return 1
	Effects.begin_cache()
	var r := _flood(u, start, mp, mode, target, zoc, layer_a, cell_score, W, H, g, scripted, zoc_on)
	Effects.end_cache()
	return r


static func _flood(u: BUnit, start: Vector2i, mp: int, mode: int, target: Vector2i, zoc: int, layer_a: Callable,
		cell_score: Callable, W: int, H: int, g: int, scripted: bool, zoc_on: bool) -> int:
	if Rules.move_cost(u, Rules.terrain_at(start)) == 0xff:
		return NONE
	var N := W * H
	# per-flood tables (nothing on the map changes during a flood): grid mirror, terrain cost, units, stop cells
	var grid := PackedByteArray()
	grid.resize(N)
	grid.fill(0xff)
	grid[start.x + start.y * W] = 0
	var cost := PackedInt32Array()
	cost.resize(N)
	var costs := {}
	var occ := PackedByteArray()
	occ.resize(N)
	var tb := Mem.MAP_BUF + 0x640
	var ob := Mem.MAP_BUF + 0xc80
	for i in N:
		var t := Mem.r8(tb + i)
		var os := Mem.r8(ob + i)
		occ[i] = os
		if os != 0xff:
			t = Rules.terrain_at(Vector2i(i % W, i / W))
		if not costs.has(t):
			costs[t] = Rules.move_cost(u, t)
		cost[i] = costs[t]
	var stop := zoc_table(u, false, occ, W, H)
	var passing := Rules.passes(u)
	var units: Array = Effects.battle.units
	var cur := 0
	var changed := true
	var nxt := 0xff
	var first := true
	while true:
		if not first:
			cur = nxt
		first = false
		if not changed or cur >= mp:
			return NONE
		changed = false
		nxt = 0xff
		var above := 0xff
		for y in H:
			for x in W:
				var i := x + y * W
				var c := grid[i]
				if c > cur and c != 0xff and above > c:
					above = c
				if c != cur:
					continue
				var here := Vector2i(x, y)
				if here != start and zoc_on and stop[i] != 0:
					continue
				for d in 4:
					var n: Vector2i = here + Rules.DIR4[d]
					if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
						continue
					if not in_move_rect(n):
						continue
					var ni := n.x + n.y * W
					if grid[ni] != 0xff:
						continue
					var mc: int = cost[ni]
					if mc == 0xff or c + mc > mp:
						continue
					if mp != 0xff and mode != 0 and zoc != 3 and not ai_area_ok(u, n):
						continue
					var os := occ[ni]
					if os != 0xff and zoc != 2 and not passing:
						if hostile(u, units[os], false) and (zoc_on or not scripted):
							continue
					var nc := (c + mc) & 0xff
					grid[ni] = nc
					Mem.w8(g + ni, nc)
					changed = true
					if nxt > c + mc:
						if zoc_on and not scripted:
							if stop[ni] == 0:
								nxt = nc
								if nxt > above:
									nxt = above
						else:
							nxt = nc
					if (mode & 8) and layer_a.is_valid() and os == 0xff:
						var a: int = layer_a.call(n)
						if a != 0xff and units[a].state == 2:
							return a
					if (mode & 2) and n == target:
						return 1
					if (mode & 4) and cell_score.is_valid() and cell_score.call(n) == 1:
						return 1
			# end of a row
			if not changed:
				if above != 0xff:
					nxt = above
					changed = true
			elif nxt > above:
				nxt = above
	return NONE


## Stop-cell table of in_enemy_zoc for every cell (one pass per flood; the result per cell is the same as calling
## in_enemy_zoc on it).
static func zoc_table(u: BUnit, use_side: bool, occ: PackedByteArray, W: int, H: int) -> PackedByteArray:
	var N := W * H
	var stop := PackedByteArray()
	stop.resize(N)
	var units: Array = Effects.battle.units
	# 先制攻击 interceptors (player-controlled movers only)
	var traps: Array = []
	if (u.flags & 0x80) == 0 and u.ai == 7:
		for x: BUnit in units:
			if x.state != 2 or x.side() == u.side() or x.hp == 0:
				continue
			var v := x.eff(0x52, 0x51, 0, 0)
			if v != 0 and x.byte(0x22) < (v & 0xff):
				traps.append(Rules.attack_cells(x, x.pos))
	var ignore := Rules.passes(u) or u.eff(0x37, 0x29, 1, 1) != 0
	for cells: Array in traps:
		for c: Vector2i in cells:
			var ti := c.x + c.y * W
			if occ[ti] == 0xff:
				stop[ti] = 1
	if ignore:
		return stop
	# a hostile unit marks its 4 neighbours
	for i in N:
		var os := occ[i]
		if os == 0xff or not hostile(u, units[os], use_side):
			continue
		var x := i % W
		var y := i / W
		if y > 0: stop[i - W] = 1
		if x < W - 1: stop[i + 1] = 1
		if y < H - 1: stop[i + W] = 1
		if x > 0: stop[i - 1] = 1
	return stop


## The cells a flood reached (grid ≠ 0xff).
static func reached() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var g := grid_base()
	for y in h():
		for x in w():
			if Mem.r8(g + x + y * w()) != 0xff:
				out.append(Vector2i(x, y))
	return out


## Destination check 0x43fc7f: no unit on the cell other than a hidden (state 1) one, and the unit can stand there.
static func dest_valid(u: BUnit, c: Vector2i) -> bool:
	var o := Rules.unit_at(c)
	if o != null and o.state != 1:
		return false
	return Rules.move_cost(u, Rules.terrain_at(c)) != 0xff


## The player's move range (0x43d4fc → flood mode 0, zoc 1): cells with a cost, and valid destinations among them.
static func move_range(u: BUnit, mp: int) -> Array[Vector2i]:
	flood(u, u.pos, mp, 0, Vector2i(0xff, 0xff), 1)
	return reached()


## CanDescend 0x43ff64: rem ≠ 0 and a neighbour has a lower grid value and a cost ≤ rem.
static func can_descend(rem: int, c: Vector2i, u: BUnit) -> bool:
	if rem == 0:
		return false
	var gc := grid_at(c)
	for d in Rules.DIR4:
		var n: Vector2i = c + d
		if not Rules.in_map(n):
			continue
		if grid_at(n) < gc and Rules.move_cost(u, Rules.terrain_at(n)) <= rem:
			return true
	return false


## StepToward 0x437e23(U, goal, from, mv, bonus): walk greedily down the last flood's grid from `from` toward `goal`
## (the flood's start): at each cell the neighbour (directions retry..3) with the lowest value below the current
## one whose cost fits the remaining points; cells in a hostile zone are skipped unless they are the goal or the unit
## is on a scripted move; with mv ≠ 0xff the activity area applies. Stuck with bonus 1: GoalBonus(cur, 10) on an
## empty cell the unit cannot descend from; units with codes 0 / 4 retry with fewer directions (blocking the dead
## end), others GoalBonus(cur, 20). Writes [0x500c48] = the step count and returns the path from `goal` to `from`
## as directions (reversed and turned by 2), i.e. the walk from the flood's start to `from`.
static func step_toward(u: BUnit, goal: Vector2i, from: Vector2i, mv: int, bonus: int,
		goal_bonus: Callable = Callable()) -> Array[int]:
	var retry := 4
	var scripted := (u.flags & 0x80) != 0
	var path: Array[int] = []
	var cur := from
	var rem := 0
	var ok := true
	while true:
		path.clear()
		cur = from
		ok = true
		rem = mv & 0xff
		while cur != goal and ok:
			var bd := grid_at(cur)
			var best := 0xff
			var cost := 0
			for d in range(0 if retry == 4 else retry, 4):
				var nb: Vector2i = cur + Rules.DIR4[d]
				if not Rules.in_map(nb):
					continue
				if in_enemy_zoc(u, nb, true) and nb != goal and not scripted:
					continue
				if mv != 0xff and not ai_area_ok(u, nb):
					continue
				var gv := grid_at(nb)
				if gv < bd:
					var mc := Rules.move_cost(u, Rules.terrain_at(nb))
					if mc <= rem:
						bd = gv
						cost = mc
						best = d
			if best == 0xff:
				ok = false
			else:
				cur = cur + Rules.DIR4[best]
				rem = (rem - cost) & 0xff
			path.append(best)
		if ok or bonus != 1:
			break
		if Rules.slot_at(cur) == 0xff and not can_descend(rem, cur, u):
			if goal_bonus.is_valid():
				goal_bonus.call(cur, 10)
			break
		if (u.ai != 0 and u.ai != 4) or retry == 0:
			if goal_bonus.is_valid():
				goal_bonus.call(cur, 20)
			break
		set_grid(cur, 0xff)
		retry -= 1
	Mem.w8(Rules.WALKED, path.size())
	# drop the unmoved last entry of a stuck walk, reverse, turn each direction by 2
	var out: Array[int] = []
	for i in range(path.size() - 1, -1, -1):
		if path[i] == 0xff:
			continue
		out.append((path[i] + 2) & 3)
	var pa := Mem.MAP_BUF + PATH_OFF
	if out.is_empty():
		Mem.w8(pa, 0xff)
	for i in out.size():
		Mem.w8(pa + i, out[i])
	return out


## The walk of a unit to `dest` on the last flood from its cell (0x437e23(U, U.pos, dest, 0xff, 0)): the cells in
## walking order (empty when dest is not reachable that way).
static func path_to(u: BUnit, dest: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if dest == u.pos:
		return cells
	var dirs := step_toward(u, u.pos, dest, 0xff, 0)
	var c := u.pos
	for d in dirs:
		c += Rules.DIR4[d]
		cells.append(c)
	if cells.is_empty() or cells[-1] != dest:
		return [] as Array[Vector2i]
	return cells
