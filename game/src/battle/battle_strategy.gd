class_name BattleStrategy
extends RefCounted
## Strategies (策略), 军师技 and turn-start auras (docs/battle.md §2–3, docs/skills.md §3.4, §5.2, §5.7). The
## context object of the original lives at 0x497af8 in Mem, as there (Rules reads +1 / +3 / +0xc / +0xd from it):
##   +0 s, +1 caster slot, +2 preset target (0xff = picked), +3 critical, +0xc current target, +0xd target list
##   (0xff end), +0x108 i32 value per target (damage > 0, heal < 0), +0x400 result code, +0x401 code per target,
##   +0x4fb range code, +0x4fc area code, +0x4fd/+0x4fe animation cell, +0x502 EXP, +0x506 weapon EXP,
##   +0x50a armour EXP per target, +0x54c caster earns EXP, +0x550 performed, +0x554 big animation.
## The context is shared: a strategy cast inside another one (策略先手, 策略反击 during 连击 / 号令) overwrites it, and
## the outer handler reads it back as the original does. Values are never cleared between casts (0x4251e1 only
## refills the list), so handlers that leave a value unset see the previous one (八阵图 / 玄武, as in the original).

const C := Rules.STRAT_CTX
const TOTAL := 0x500c42        # dword: 策略连击 saved EXP words, then the damage total (0x42bbba)
const REPEAT := 0x500c46       # 策略连击 guard
const FREE_CAST := 0x500fcc    # no MP cost
const SKIP_ANIM := 0x501a75    # option: no strategy animation
const NO_INTRO := 0x500e9b     # 1: no cast intro (超度)
const FS_INDEX := 0x500c41     # 军师技 index
const OBJ_COUNT := 0x501ae1    # 纵火 / 修筑 objects on the map
const OBJ_LIST := 0x501ae2     # 10 × {x, y, timer}
const JINGJIN := 0x501b00      # 精进 timer per slot
const FANJIAN := 0x501ad8      # 反間計 timer per slot
const BOSS := 0x492f90 + 0x3d06
const TICK := 0.05             # one 50 ms tick of 0x42c632 / 0x423971

## 0x415531: buff codes, four downs then four ups and move up (0x40bb87)
const BUFF_CODES := [0x1b, 0x1d, 0x17, 0x19, 0x1f, 0x35, 0x37, 0x31, 0x33, 0x30]
## 0x4785c6: 八阵图 / 玄武 result codes by roll (0x4785c7 = from index 1)
const ROLL_CODES := [0x40, 0x49, 0x4a, 0x4b, 0x4c, 0x48, 0x57, 0x50]
## 0x4785ce: Meff of each ROLL_CODES group (category 12, 0x4216c0)
const ROLL_MEFF := [8, 23, 25, 26, 27, 33, 17, 10]
## 0x420e7f: status masks of 0x420e36 codes 0x1f/0x21/0x23/0x25 (混乱 中毒 麻痹 禁咒)
const STATUS_MASKS := [0x08, 0x10, 0x02, 0x04]
## 0x42faa7 / 0x42faad: the two Meff of each buff aura
const AURA_MEFF_A := [0x0d, 0x0e, 0x0d, 0x0f, 0x10, 0x1e]
const AURA_MEFF_B := [0x22, 0x23, 0x22, 0x24, 0x25, 0x2e]

var st: BattleStage
## The attack item's value when an item is used as a strategy (byte 0x500ad7 = 1; 0x41dd72), set by the item code.
var item_value := 0
## The AI's chosen target slot (0x4b2c28): the AI target picker of 连击's attacks prefers it. cast() sets it from the
## target cell for casters that are not player-controlled.
var ai_target := 0xff
var _cell := Vector2i(-1, -1)  # the cell chosen by the player / AI for cast() (stands for 0x45533d's answer)


func _init(s: BattleStage) -> void:
	st = s


# ------------------------------------------------------------------ public entry points
## Dispatcher 0x425627 for a strategy picked through the menu or by the AI (preset 0xff): `target` is the chosen
## cell (the caster's own for self / whole-map strategies). Returns true when performed; the caster has then acted
## (0x41c0e8: flags |= 6) and the last action is 2.
func cast(s: int, caster: BUnit, target: Vector2i) -> bool:
	var old := _cell
	_cell = target
	if caster.ai != 7:
		ai_target = Rules.slot_at(target)
	var ok: bool = await _dispatch(s, caster, 0xff)
	_cell = old
	if ok:
		Mem.w8(BattleStage.LAST_ACTION, 2)
		caster.flags = caster.flags | 6
	st.refresh_units()
	return ok


## 0x4179b4: cast s at a unit (策略先手 / 策略反击 / 策略追击): only if not sealed and the MP suffices (0x417af6); the
## target is preset, so no target choice and no 策略先手 of the target.
func cast_at(caster: BUnit, target: BUnit, s: int) -> bool:
	if not Rules.can_cast(caster, s):
		return false
	var old := _cell
	_cell = target.pos
	var ok: bool = await _dispatch(s, caster, target.slot)
	_cell = old
	return ok


## How the dispatcher picks the target of s (0x4233f8 / 0x45533d): 0 none (self, whole map), 2 an enemy, 3 an ally,
## 4 a cell (纵火 / 修筑).
func pick_mode(s: int) -> int:
	match Rules.mg(Rules.MG_ID, s):
		1, 22, 23, 24, 25, 28, 29, 31, 34, 35, 36, 40:
			return 0
		27:
			return 4
		13, 14, 15, 16, 17, 18, 19, 20, 21, 33, 37, 38, 39:
			return 3
	return 2


## Cell choice for pick mode 4 (纵火 / 修筑): 2 = accepted, 1 = refused. [G: any cell of the map without a unit]
func cell_check(_s: int, c: Vector2i) -> int:
	if not Rules.in_map(c) or Rules.slot_at(c) != 0xff:
		return 1
	return 2


## The units strategy s cast by `caster` with centre `center` would reach (0x44402b / 0x435ce9 / 0x444064 and the
## special handlers' lists), for the target choice and the AI. An empty centre counts only with 洪荒之力 (0x406e2b).
func targets_for(s: int, caster: BUnit, center: Vector2i) -> Array[BUnit]:
	var out: Array[BUnit] = []
	var id := Rules.mg(Rules.MG_ID, s)
	var slots: Array[int] = []
	match id:
		1:
			for u in st.units:
				if u.state == 2 and u.side() != caster.side():
					slots.append(u.slot)
		28:
			for i in range(60, 250):
				if st.units[i].state == 2:
					slots.append(i)
		29:
			for u in st.units:
				if u.state == 2 and u.side() == caster.side():
					slots.append(u.slot)
		22, 31, 34, 35, 36:
			return out
		23, 24, 25, 40:
			out.append(caster)
			return out
		_:
			var t := Rules.unit_at(center)
			var area := Rules.strat_area(caster, s)
			if id in [26, 27, 37, 38]:
				area = 0
			var sm := _side_mode(id)
			if t != null:
				slots.append(t.slot)
				slots.append_array(_area_slots(caster, t.pos, area, sm, t.slot))
			elif area != 0 and caster.eff(68, 0x6e, 1, 1) != 0:
				slots.append_array(_area_slots(caster, center, area, sm, 0xff))
	for sl in slots:
		var u := st.units[sl]
		if _terrain_keep(caster, u, s):
			out.append(u)
	return out


## Op 0x6b in a battle (0x414071): effect `eff` at cell c when the cell is on screen — < 100 Meff `eff`,
## ≥ 100 the resource animation Mcall(eff % 100) (0x416a14) followed by 4 ticks.
func play_cell_effect(eff: int, c: Vector2i) -> void:
	if not _on_screen(c):
		return
	if eff < 100:
		await _meff(eff, [c], false)
	else:
		await _mcall(eff, _cell_point(c))


## Op 0x72 sub 1 / 2 / 3 animation 0x406d64: Meff `s` on every cell inside the view (at most 250), the hit frame
## drawing `numbers` (one per cell; empty = none) in the style of code `num_kind` (0x40 damage, 0x50 heal) with the
## hurt / cheer frame of a unit standing there. Returns false (nothing played) when no cell was on screen.
func script_anim(s: int, cells: Array[Vector2i], numbers: Array, num_kind: int) -> bool:
	var pts := []
	var shown: Array[int] = []
	for i in cells.size():
		if _on_screen(cells[i]) and pts.size() < 250:
			pts.append(_cell_point(cells[i]))
			shown.append(i)
	if pts.is_empty():
		return false
	var on_hit := func() -> void:
		if numbers.is_empty():
			return
		for i in shown:
			var u := st.unit_at(cells[i])
			_pose(u, UnitSprite.Pose.CHEER if num_kind == 0x50 else UnitSprite.Pose.HURT)
			if i < numbers.size() and int(numbers[i]) != 0:
				_number(cells[i], absi(int(numbers[i])), num_kind == 0x50 or int(numbers[i]) < 0, false, false)
	await EffectPlayer.play("xben", s, _layer(), pts, on_hit)
	if not numbers.is_empty():
		await _ticks(10)
		for i in shown:
			_pose(st.unit_at(cells[i]), UnitSprite.Pose.STAND)
		st.refresh_units()
	return true


# ------------------------------------------------------------------ context access
func _u(slot: int) -> BUnit:
	return st.units[slot] if slot >= 0 and slot < st.units.size() else null


func _cs() -> int:
	return Mem.r8(C)


func _caster() -> BUnit:
	return _u(Mem.r8(C + 1))


func _t(k: int) -> int:
	return Mem.r8(C + 0xd + k)


func _set_t(k: int, v: int) -> void:
	Mem.w8(C + 0xd + k, v)


func _val(k: int) -> int:
	return Mem.r32s(C + 0x108 + 4 * k)


func _set_val(k: int, v: int) -> void:
	Mem.w32(C + 0x108 + 4 * k, v & 0xffffffff)


func _code(k: int) -> int:
	return Mem.r8(C + 0x401 + k)


func _set_code(k: int, v: int) -> void:
	Mem.w8(C + 0x401 + k, v)


func _ctx_code() -> int:
	return Mem.r8(C + 0x400)


func _performed() -> void:
	Mem.w32(C + 0x550, 1)


## Init 0x4251e1(s, caster): not performed, the target list refilled with 0xff, current target 0xff, EXP zero, the
## range (0x401dff, 远距攻击) and area (0x41a10c, 辅助穿透) codes; +2 and +3 are cleared by the slot's dword write.
func _init_ctx(s: int, u: BUnit) -> void:
	Mem.w32(C + 0x550, 0)
	Mem.w8(C, s)
	Mem.w32(C + 1, u.slot)
	Mem.w32(C + 4, maxi(u.pid, 0))
	Mem.w32(C + 8, u.slot)
	Mem.w8(C + 0xc, 0xff)
	Mem.w32(C + 0x54c, 1 if (u.kind == 0 or u.ai == 7) else 0)
	if u.pid >= 0:
		Mem.w8(C + 0x4fb, Rules.strat_range(u, s))
		Mem.w8(C + 0x4fc, Rules.strat_area(u, s))
	else:
		Mem.w8(C + 0x4fb, int(Rules.strat(s).get("range", 0xff)))
		Mem.w8(C + 0x4fc, int(Rules.strat(s).get("area", 0)))
	Mem.w32(C + 0x502, 0)
	Mem.w32(C + 0x506, 0)
	Mem.fill(C + 0xd, 0xfb, 0xff)


# ------------------------------------------------------------------ dispatcher 0x425627
func _dispatch(s: int, caster: BUnit, preset: int) -> bool:
	_init_ctx(s, caster)
	var why := Rules.situation(s, caster)
	if why != "":
		if caster.ai == 7 and why != "-":
			await _msg(why)
		return false
	var e := Rules.s_effect(s)
	var mc := Rules.mg(Rules.MG_MCALL, s)
	Mem.w32(C + 0x554, 1 if (e != 43 and mc >= 100 and mc != 0xff) else 0)
	Mem.w8(C + 2, preset)
	var id := Rules.mg(Rules.MG_ID, s) if s < 0x90 else 0xff
	match id:
		0, 41, 42, 43, 44, 45:
			Mem.w8(C + 0x400, 0x40)
			await _generic(false, 0, 2)
		1:
			Mem.w8(C + 0x400, 0x40)
			await _sandstorm()
		2:
			Mem.w8(C + 0x400, 0x42)
			await _buff_cast(false)
		3:
			Mem.w8(C + 0x400, 0x41)
			await _generic(false, 0, 2)
		4, 5, 6, 7, 30, 32:
			Mem.w8(C + 0x400, {4: 0x46, 5: 0x47, 6: 0x44, 7: 0x45, 30: 0x48, 32: 0x43}[id])
			await _buff_cast(false)
		8, 9, 10, 11:
			Mem.w8(C + 0x400, {8: 0x4a, 9: 0x49, 10: 0x4b, 11: 0x4c}[id])
			await _generic(true, 0, 2)
		12:
			Mem.w8(C + 0x400, 0xff)
			await _bazhen()
		13, 14:
			Mem.w8(C + 0x400, 0x50 if id == 13 else 0x51)
			await _recover()
		15:
			Mem.w8(C + 0x400, 0x5a)
			await _generic(true, 1, 3)
		16, 17, 18, 19, 20, 33, 39:
			Mem.w8(C + 0x400, {16: 0x56, 17: 0x54, 18: 0x55, 19: 0x52, 20: 0x53, 33: 0x58, 39: 0x5b}[id])
			await _buff_cast(true)
		21:
			Mem.w8(C + 0x400, 0x59)
			await _return_act()
		22:
			Mem.w8(C + 0x400, 0x70)
			await _weather()
		23, 25, 40:
			Mem.w8(C + 0x400, {23: 0x52, 25: 0x57, 40: 0x5b}[id])
			await _self_buff()
		24:
			Mem.w8(C + 0x400, 0x51)
			await _meditate()
		26:
			Mem.w8(C + 0x400, 0x40)
			await _orbs(5 if e == 25 else 0)
		27:
			await _place_object()
		28:
			Mem.w8(C + 0x400, 0xff)
			await _xuanwu(60, 1)
		29:
			Mem.w8(C + 0x400, 0x5a)
			await _baihu()
		31, 35:
			await _move_again(id == 35)
		34:
			await _combo()
		36:
			await _summon()
		37:
			await _swap()
		38:
			await _command()
		_:
			Mem.w8(C + 0x400, 0)
	await _finish()
	return Mem.r32(C + 0x550) != 0


## sideMode of the area expansion per handler (0 other camp, 1 own camp).
func _side_mode(id: int) -> int:
	return 1 if id in [13, 14, 15, 16, 17, 18, 19, 20, 21, 33, 39] else 0


# ------------------------------------------------------------------ target choice 0x4233f8 / 0x42220f / 0x417b77
## 0x4233f8: pick (mode 2 enemy, 3 ally), then 0x417b77. Returns the target slot or 0xff (cancelled).
func _pick_target(mode: int) -> int:
	var t := _pick(mode)
	if t == 0xff:
		return 0xff
	Mem.w8(C + 0xc, t)
	if not await _check_target(t):
		return 0xff
	return Mem.r8(C + 0xc)


## 0x42220f: in the 练武场 (EV 4087) the fixed pair 0 / 60; else the preset, else the chosen target.
func _pick(mode: int) -> int:
	if Rules.evb(4087) != 0:
		if Mem.r8(C + 1) == 60:
			return 0 if mode == 2 else 60
		return 60 if mode == 2 else 0
	var pre := Mem.r8(C + 2)
	if pre != 0xff:
		return pre
	return _ui_pick(mode)


## Stands for the target picker 0x45533d: the unit on the chosen cell; an empty cell only through 0x406e2b.
func _ui_pick(mode: int) -> int:
	if not Rules.in_map(_cell):
		return 0xff
	var sl := Rules.slot_at(_cell)
	if sl != 0xff:
		return sl
	return _empty_cell(mode)


## 0x406e2b for strategies (modes 2 / 3, no attack item): with 洪荒之力 (0x45d37e) the area around the empty cell
## becomes the target list (0x435ce9 + 0x444064); 0xfe if it holds a unit.
func _empty_cell(mode: int) -> int:
	if (mode != 2 and mode != 3) or Mem.r8(Rules.STRAT_ITEM) == 1:
		return 0xff
	var caster := _caster()
	if caster.eff(68, 0x6e, 1, 1) == 0:
		return 0xff
	var lst := _area_slots(caster, _cell, Mem.r8(C + 0x4fc), 1 if mode == 3 else 0, 0xff)
	for i in lst.size():
		_set_t(i, lst[i])
	_set_t(lst.size(), 0xff)
	_filter()
	return 0xfe if _t(0) != 0xff else 0xff


## 0x417b77: target validity (0x42044d; its message when the caster earns EXP), then for a chosen (not preset) unit
## the target's 策略先手 (0x4179e3); after it the context is re-initialised keeping the result code and the target.
func _check_target(t: int) -> bool:
	var tt := t
	if t == 0xfe:
		tt = _t(0)
		Mem.w8(C + 0xc, tt)
	var s := _cs()
	var caster := _caster()
	var why := Rules.target_valid(s, caster, _u(tt))
	if why != "":
		if Mem.r32(C + 0x54c) != 0 and why != "-":
			await _msg(why)
		return false
	if Rules.evb(4087) != 1 and t != 0xfe and Mem.r8(C + 2) == 0xff:
		var code := Mem.r8(C + 0x400)
		var cur := Mem.r8(C + 0xc)
		if not await _preempt(caster, s):
			return false
		_init_ctx(s, caster)
		Mem.w8(C + 0x400, code)
		Mem.w8(C + 0xc, cur)
	return true


## 0x4179e3: against an enemy-targeted strategy the target (alive, not 混乱) with 策略先手 v casts v − 1 at the
## caster first when the caster stands in its range (0x41cecc); if that was cast, the caster goes on only alive, not
## 混乱 and still able to cast s (0x420420), else it has acted.
func _preempt(caster: BUnit, s: int) -> bool:
	if Rules.s_side(s) != 0:
		return true
	var t := _u(Mem.r8(C + 0xc))
	if t == null or _dead_or_confused(t) != 0:
		return true
	var v := t.eff(0x5e, 0x78, 1, 0)
	if v == 0:
		return true
	var s2 := (v - 1) & 0xff
	if not caster.pos in Rules.range_cells(Rules.strat_range(t, s2), t.pos):
		return true
	if not await cast_at(t, caster, s2):
		return true
	if _dead_or_confused(caster) == 0 and Rules.can_cast(caster, s):
		return true
	caster.flags = caster.flags | 6
	return false


## 0x426b33: 2 dead, the 混乱 counter if confused, else 0.
func _dead_or_confused(u: BUnit) -> int:
	if u.hp == 0:
		return 2
	return u.status_count(BUnit.ST_CONFUSION)


# ------------------------------------------------------------------ area 0x44402b / 0x435ce9 / 0x444064
## 0x44402b: once per cast (empty list), the centre target first, then the area units of `side_mode`, filtered.
func _expand(side_mode: int) -> void:
	if _t(0) != 0xff:
		return
	var t0 := Mem.r8(C + 0xc)
	_set_t(0, t0)
	var lst := _area_slots(_caster(), _u(t0).pos, Mem.r8(C + 0x4fc), side_mode, t0)
	for i in mini(lst.size(), 0xf9):
		_set_t(1 + i, lst[i])
	_filter()


## 0x435ce9 / 0x435c10: units on the area cells around `center` (no HP test), not the first target again; sideMode
## 0 other camp (every camp while byte 0x500c44 == 1), 1 same camp, 2 any.
func _area_slots(caster: BUnit, center: Vector2i, area: int, side_mode: int, first: int) -> Array[int]:
	var out: Array[int] = []
	var sd := caster.side()
	for p in Rules.area_cells(area, center, caster.pos):
		var sl := Rules.slot_at(p)
		if sl == 0xff or sl == first:
			continue
		var o := st.units[sl]
		var ok := false
		match side_mode:
			0: ok = Mem.r8(Rules.ITEM_MODE) == 1 or o.side() != sd
			1: ok = o.side() == sd
			2: ok = true
		if ok:
			out.append(sl)
	return out


## 0x41d90e / 0x420a5a: the unit counts when the strategy ignores the terrain or the element suits its terrain.
func _terrain_keep(caster: BUnit, u: BUnit, s: int) -> bool:
	if Rules.ignores_terrain(caster, s):
		return true
	var e := Rules.s_effect(s)
	return e >= 4 or Rules.elemental_ok(e, u)


## 0x444064: drop the targets of the context list failing _terrain_keep; returns how many were dropped.
func _filter() -> int:
	var caster := _caster()
	var s := _cs()
	var r := 0
	var w := 0
	while r < 0xfb and _t(r) != 0xff:
		var sl := _t(r)
		if _terrain_keep(caster, _u(sl), s):
			_set_t(w, sl)
			w += 1
		r += 1
	for i in range(w, r):
		_set_t(i, 0xff)
	return r - w


# ------------------------------------------------------------------ handlers
## 0x4231c2(isStatus, sideMode, pickMode): damage (0, 0, 2), status (1, 0, 2), cure (1, 1, 3). 策略连击 (0x4390a9)
## runs the pass and its results once more on the same targets.
func _generic(is_status: bool, side_mode: int, pick_mode: int) -> void:
	if await _pick_target(pick_mode) == 0xff:
		return
	_expand(side_mode)
	var total := 0
	while true:
		total += await _pass(is_status)
		await _apply()
		if Mem.r8(REPEAT) != 0:
			break
		if not _repeat_check():
			break
	Mem.w32(C + 0x502, Mem.r32(C + 0x502) + Mem.r16(TOTAL))
	Mem.w32(C + 0x506, Mem.r32(C + 0x506) + Mem.r16(TOTAL + 2))
	Mem.w32(TOTAL, total & 0xffffffff)


## 0x4390a9 策略连击: Q(caster, 58, 0x3b, 1, 1) → guard +1, the EXP words saved in 0x500c42 / 0x500c44.
func _repeat_check() -> bool:
	var caster := _caster()
	if caster.eff(0x3a, 0x3b, 1, 1) == 0:
		return false
	Mem.w8(REPEAT, Mem.r8(REPEAT) + 1)
	Mem.w16(TOTAL, Mem.r32(C + 0x502) & 0xffff)
	Mem.w16(TOTAL + 2, Mem.r32(C + 0x506) & 0xffff)
	return true


## 0x423594: per target, status strategies roll the hit (code = the result code on a hit, none in the 练武场) and
## pass it as the damage flag for player-camp casters; damage (0x43c01d); damage strategies get the code when the
## damage is non-zero. EXP per target (0x44de9e). Returns the damage total.
func _pass(is_status: bool) -> int:
	var total := 0
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		var ts := _t(k)
		Mem.w8(C + 0xc, ts)
		var caster := _caster()
		var t := _u(ts)
		var flag := 0
		if is_status:
			var hit := Rules.strat_hit_test(caster, t, _cs())
			_set_code(k, _ctx_code() if hit and Rules.evb(4087) == 0 else 0)
			flag = 1 if hit and caster.side() == 1 else 0
		var d := _damage(caster, t, _cs(), flag)
		total += d
		_set_val(k, d)
		if not is_status:
			_set_code(k, _ctx_code() if d != 0 else 0)
		_exp_target(k)
		k += 1
	return total


## 0x43c01d through Rules; an attack item used as a strategy deals its value (capped at HP, or MP for 吸收MP).
func _damage(c: BUnit, t: BUnit, s: int, flag: int) -> int:
	if Mem.r8(Rules.STRAT_ITEM) == 1:
		return mini(item_value, t.mp if Rules.s_effect(s) == 6 else t.hp)
	return Rules.strat_damage(c, t, s, flag)


## 0x423230(isBuff): debuffs, 反間計, 诱敌, 衰气 (enemies, mode 2) and buffs, 精进, blank 112 (allies, mode 3): code on
## a hit, no damage.
func _buff_cast(is_buff: bool) -> void:
	if await _pick_target(3 if is_buff else 2) == 0xff:
		return
	_expand(1 if is_buff else 0)
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var hit := Rules.strat_hit_test(_caster(), _u(_t(k)), _cs())
		_set_code(k, _ctx_code() if hit else 0)
		_exp_target(k)
		k += 1
	await _apply()


## 0x4232bf: HP / MP recovery, no hit roll; value = −heal (0x43c5df).
func _recover() -> void:
	if await _pick_target(3) == 0xff:
		return
	_expand(1)
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		_set_val(k, -Rules.heal_amount(_u(_t(k)), _cs(), _caster(), false))
		_set_code(k, _ctx_code())
		_exp_target(k)
		k += 1
	await _apply()


## 0x42427b 砂暴: every on-map unit of the other camp, then the terrain filter. With no candidate at all only the
## intro plays and nothing is performed (the EXP computed then is dropped); a list emptied by the filter still counts.
func _sandstorm() -> void:
	var caster := _caster()
	var sd := caster.side()
	var n := 0
	for u in st.units:
		if u.state == 2 and u.side() != sd:
			_set_t(n, u.slot)
			n += 1
	_filter()
	if n == 0:
		_set_val(0, 0)
		Mem.w8(C + 0x401 + 0xfa, 0)
		Mem.w8(C + 0xc, Mem.r8(C + 1))
		_set_t(0, Mem.r8(C + 1))
		var x := _strat_exp(0)
		if Mem.r32(C + 0x502) < x:
			Mem.w32(C + 0x502, x)
		await _intro()
		return
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var d := _damage(_caster(), _u(_t(k)), _cs(), 0)
		_set_val(k, d)
		_set_code(k, 0x40 if d != 0 else 0)
		_exp_target(k)
		k += 1
	await _apply()


## 0x4243c6 八阵图: own target choice (0x45533d, no 策略先手), area 3 of enemies; per unit rand(8): 0 damage as 八阵图,
## 1 damage as 毒烟 (46) with code 中毒, 2..6 混乱 / 麻痹 / 禁咒 / all down / all up without a roll, 7 full heal.
func _bazhen() -> void:
	var t := _ui_pick(2)
	if t == 0xff and Mem.r8(C + 2) != 0xff:
		t = Mem.r8(C + 2)      # [G] a preset cast: 0x45533d would ask the UI / the AI target
	if t == 0xff:
		return
	if t == 0xfe:
		t = _t(0)
	Mem.w8(C + 0xc, t)
	var why := Rules.target_valid(_cs(), _caster(), _u(t))
	if why != "":
		if Mem.r32(C + 0x54c) != 0 and why != "-":
			await _msg(why)
		return
	_expand(0)
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var r := Rules.rand(8)
		var code: int
		if r < 2:
			_set_val(k, _damage(_caster(), _u(_t(k)), 0x36 if r == 0 else 0x2e, 0))
			code = 0x40 if r == 0 else 0x49
		elif r == 7:
			_set_val(k, -Rules.heal_amount(_u(_t(k)), _cs(), _caster(), false))
			code = 0x50
		else:
			code = ROLL_CODES[r]
		_set_code(k, code)
		_exp_target(k)
		k += 1
	await _apply()


## 0x4244e5(n): 灵珠 (n 0) hit the chosen enemy `area` times (the next candidate when it dies); 青龙出海 (n 5) five
## hits each on a random enemy in cast range, the dead dropped. Each hit is a full damage + result pass.
func _orbs(n: int) -> void:
	var t := await _pick_target(2)
	if t == 0xff:
		return
	var s := _cs()
	_set_t(0, Mem.r8(C + 1))
	var caster := _caster()
	Mem.w32(C + 0x554, 0)
	var cands: Array[int] = []
	for o in Rules.collect(caster, caster.pos, [Mem.r8(C + 0x4fb), 0xff, 0xff, 0xff], 0):
		cands.append(o.slot)
	if cands.is_empty():
		return
	var cnt := cands.size()
	if n == 0:
		var kept: Array[int] = []
		for sl in cands:
			if _terrain_keep(caster, _u(sl), s):
				kept.append(sl)
		cands = kept
		cnt = kept.size()
	else:
		await _intro()
	var mc := Rules.mg(Rules.MG_MCALL, s)
	if mc > 99:
		await _mcall(mc, _cell_point(caster.pos))
	var hits := n
	if n == 0:
		var i := cands.find(t)
		if i > 0:
			cands[i] = cands[0]
			cands[0] = t
		hits = int(Rules.strat(s).get("area", 0))
	var done := 0
	while cnt > 0:
		if hits <= done:
			return
		var idx := Rules.rand(cnt) if n != 0 else 0
		var ts := cands[idx] if idx < cands.size() else 0xff
		_set_t(0, ts)
		Mem.w8(C + 0xc, ts)
		var u := _u(ts)
		if u == null or u.hp == 0:
			cnt -= 1
			cands[idx] = cands[cnt]
			cands[cnt] = 0xff
			continue
		done += 1
		var d := _damage(_caster(), u, _cs(), 0)
		_set_val(0, d)
		_set_code(0, 0x40 if d != 0 else 0)
		_exp_target(0)
		await _apply()


## 0x42481a(start, mode) 玄武现世 (60, 1) / 超度 (0, 1): every on-map unit from slot `start` passing the terrain
## filter; mode 1: the caster's camp loses its ailments and gets the five ups, the others one of 混乱 中毒 麻痹 禁咒
## and all down by rand(5) (mode 0: rand(7), 6 = full heal). No hit roll; applied by its own loop after the animation.
func _xuanwu(start: int, mode: int) -> void:
	var caster := _caster()
	var s := _cs()
	var n := 0
	for i in range(start, 250):
		var u := st.units[i]
		if u.state == 2 and _terrain_keep(caster, u, s):
			_set_t(n, i)
			n += 1
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var t := _u(_t(k))
		var r: int
		if mode == 0:
			r = Rules.rand(6 if k > 0xbd else 7)
		elif _caster().side() != t.side():
			r = Rules.rand(5)
		else:
			t.status = 0
			r = 5
		if r == 6:
			_set_val(k, -Rules.heal_amount(t, _cs(), _caster(), false))
			_set_code(k, 0x50)
		else:
			_set_code(k, ROLL_CODES[r + 1])
		_exp_target(k)
		k += 1
	await _animate()
	_sort_targets()
	k = 0
	while k < 0xfb and _t(k) != 0xff:
		var t := _u(_t(k))
		var code := _code(k)
		var i := (code - 0x48) & 0xff
		if i == 0xf:
			i = 5
		if i == 0:
			_buffs(t, 0, 4)
		elif i == 5:
			_buffs(t, 5, 5)
		elif i < 5:
			t.inflict(STATUS_MASKS[i - 1])
		else:
			t.hp = t.hp - _val(k)
		if code != 0:
			_se(0x7c)
			await _ticks(2)
			await _look(t.pos)
			st.refresh_units()
		k += 1
	_performed()


## 0x4246d0 白虎临凡: every on-map unit of the caster's camp passing the filter: heal (spirit formula) and a hit roll;
## a target's code is the previous target's (the first one's the result code); with a code HP += heal, ailments cured.
func _baihu() -> void:
	var caster := _caster()
	var s := _cs()
	var n := 0
	for u in st.units:
		if u.state == 2 and u.side() == caster.side() and _terrain_keep(caster, u, s):
			_set_t(n, u.slot)
			n += 1
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var t := _u(_t(k))
		_set_val(k, -Rules.heal_amount(t, _cs(), _caster(), false))
		var hit := Rules.strat_hit_test(_caster(), t, _cs())
		_set_code(k, Mem.r8(C + 0x400 + k) if hit else 0)
		_exp_target(k)
		k += 1
	await _animate()
	k = 0
	while k < 0xfb and _t(k) != 0xff:
		if _code(k) != 0:
			var t := _u(_t(k))
			t.hp = t.hp - _val(k)
			t.cure(BUnit.ST_ALL)
		k += 1
	_performed()


## 0x423aa1 回归: allies of the area, hit roll → code 0x59 (may act again).
func _return_act() -> void:
	if await _pick_target(3) == 0xff:
		return
	_expand(1)
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var hit := Rules.strat_hit_test(_caster(), _u(_t(k)), _cs())
		_set_code(k, 0x59 if hit else 0)
		_exp_target(k)
		k += 1
	await _apply()


## 0x41e3b3 冥想 (self): HP cost min(HP − 1, 50) as the second value, MP gain (HP − 1)/2 or 25 (≤ the missing MP);
## animation, EXP (0x416f0f), results — not through 0x4251bd.
func _meditate() -> void:
	var caster := _caster()
	Mem.w8(C + 0xc, caster.slot)
	_set_t(0, caster.slot)
	var why := Rules.target_valid(_cs(), caster, caster)
	if why != "":
		if Mem.r32(C + 0x54c) != 0 and why != "-":
			await _msg(why)
		return
	_set_code(0, _ctx_code())
	var hp := caster.hp
	if hp < 0x33:
		_set_val(1, hp - 1)
		_set_val(0, -((hp - 1) / 2))
	else:
		_set_val(1, 0x32)
		_set_val(0, -0x19)
	var lim := (caster.mp & 0xffff) - caster.max_mp()
	if _val(0) < lim:
		_set_val(0, lim)
	await _animate()
	_self_exp()
	await _results()


## 0x424374 气合 / 霸气 / blank 113 (self, no hit roll).
func _self_buff() -> void:
	var caster := _caster()
	Mem.w8(C + 0xc, caster.slot)
	_set_t(0, caster.slot)
	var why := Rules.target_valid(_cs(), caster, caster)
	if why != "":
		if Mem.r32(C + 0x54c) != 0 and why != "-":
			await _msg(why)
		return
	_set_code(0, _ctx_code())
	await _apply()
	_self_exp()


## 0x423b0b weather: wanted = 0x40dbab[MgHurt] (豪雨 2, 晴明 0, 昙天 1) → phase index 0x44a1f5; a different index
## changes the weather (0x449f91, SE 0x86, 30 ticks), else Meff 45 ("no effect"). Always performed, EXP 20.
func _weather() -> void:
	var s := _cs()
	_set_code(0, 0)
	var b := Rules.mg(Rules.MG_HURT, s)
	var v := _weather_index(Mem.r8(0x40dbab + b))
	_set_val(0, v)
	_set_code(0, (b - 0x40) & 0xff)
	await _animate()
	if _code(0) != 0 and v != Mem.r8(Rules.B + 4):
		_se(0x86)
		await _ticks(0x1e)
		st.set_weather(v)
	else:
		await _meff(45, [_caster().pos], false)
	_self_exp()


## 0x44a1f5(w): w ≤ 1 → the first phase index 0..5 of the climate row holding w (6 if none); rain → the last index
## holding 2 / 3 / 4 (0 if none).
func _weather_index(w: int) -> int:
	var row := 0x48e100 + Mem.r8(Rules.B + 0x11) * 6
	if (w & 0xff) < 2 or (w & 0x80) != 0:
		for i in 6:
			if Mem.r8(row + i) == (w & 0xff):
				return i
		return 6
	var i := 6
	while i != 0:
		var c := Mem.r8(row + i - 1)
		i -= 1
		if c == 2 or c == 3 or c == 4:
			return i
	return 0


## 0x40eb7e 疾行 / 瞬移: SE 0x27, the caster's movement again (瞬移: anywhere, byte 0x500ad3 = 1 meanwhile);
## performed when it moved or stayed by choice (0x40ea8e).
func _move_again(teleport: bool) -> void:
	var caster := _caster()
	_se(0x27)
	if teleport:
		Mem.w8(Rules.FORCED_MOVE, 1)
	var ok := await _move_select(caster, [0x0b, 0xff, 0xff, 0xff], 0xff if teleport else 0)
	Mem.w8(Rules.FORCED_MOVE, 0)
	if ok:
		_done_self()


## MoveSelect 0x43d4fc for strategies (mode 1): the player phase's move selection; an AI-controlled unit only shows
## its range there and does not move (and in Game.autoplay nobody can click).
func _move_select(u: BUnit, codes: Array, mp: int) -> bool:
	if st.input == null or u.ai != 7 or Game.autoplay or not st.input.has_method("move_select"):
		return false
	return await st.input.move_select(u, codes, mp, 1)


## 0x449c0d 连击: the strategy name, then rand(3) + 2 attack steps (0x439413) while a target is found and the caster
## is alive and not confused (a dead caster is removed, 0x4065d9). Performed after at least one attack.
func _combo() -> void:
	await _name_box()
	var n := Rules.rand(3) + 2
	var caster := _caster()
	var saved := ai_target
	var count := 0
	var i := 0
	while i < n:
		var r: int = await _attack_step(caster)
		ai_target = saved
		if r == -1:
			break
		count += 1
		var dc := _dead_or_confused(caster)
		if dc != 0:
			if dc == 2:
				await st.post_action()
			break
		i += 1
	if count != 0:
		_performed()
		_set_t(0, Mem.r8(C + 1))
		Mem.w8(C + 0xc, Mem.r8(C + 1))


## 0x439413: one attack of `u` — a player-controlled unit chooses in its attack range (0x45533d mode 1), others take
## the AI target if in range, else the last unit found (0x436511); then the attack command and the post-action
## clean-up (0x4065d9). −1 when there was no target.
func _attack_step(u: BUnit) -> int:
	var codes := Rules.attack_codes(u)
	var t := 0xff
	if u.ai == 7 and not Game.autoplay and st.input != null and st.input.has_method("pick_target"):
		t = await st.input.pick_target(u, codes, 1)
		if t == 0xfe:
			t = 0xff
			# [G] an area weapon on an empty cell: the first hostile unit of the area (as the player's 攻击)
			for p in Rules.area_cells(Rules.phys_area(u), st.input.picked_cell, u.pos):
				var o := st.unit_at(p)
				if o != null and o.hp > 0 and o.side() != u.side():
					t = o.slot
					break
	else:
		for o in Rules.collect(u, u.pos, codes, 0):
			t = o.slot
			if o.slot == ai_target:
				break
	if t == 0xff:
		return -1
	await st.actions.attack_command(u, st.units[t], true)
	await st.post_action()
	return 0


## 0x426551 召唤: the first 20 deployment persons become the sortie list; a unit of person 0x300 | MgHurt (level
## = sortie level + 0x501bf4, AI mode 1, flags by the caster's camp) is generated in the first free deployment entry
## of the camp's range (an entry of that person whose unit is off the map is reused unless EV 4080) and enters next
## to the caster; at most range × count of them in a row. Nothing placed → "不能再添加了！".
func _summon() -> void:
	var caster := _caster()
	var s := _cs()
	var kind := caster.kind if caster.kind != 0 else 1
	for i in 20:
		Mem.w16(BattleStage.SORTIE + 2 * i, Mem.r16(st._entry(i)))
	var lo := 20
	var hi := 60
	if kind != 1:
		lo = 60
		hi = 250
	var lvl := maxi(st._sortie_level() + Mem.r8s(0x501bf4), 1)
	var pid := 0x300 | Rules.mg(Rules.MG_HURT, s)
	var count := int(Rules.strat(s).get("area", 0))
	var rng := int(Rules.strat(s).get("range", 0))
	var ai := Rules.s_side(s) * 6 + 1 if kind == 1 else 1
	var made := 0
	var run := 1
	var any := false
	while made < count:
		var j := lo
		var e := -1
		var stop := false
		while true:
			if j >= hi:
				stop = true
				break
			e = st._entry(j)
			var p := Mem.r16(e)
			if p == pid:
				if Rules.evb(4080) == 0 and st.units[j].state != 2:
					break
				if rng * count <= run:
					stop = true
					break
				run += 1
			else:
				run = 1
				if p == 0xffff:
					Mem.w16(e, pid)
					break
			j += 1
		if stop:
			break
		Mem.w32(e, pid)
		Mem.w8(e + 2, 2)
		Mem.w8(e + 3, lvl & 0xff)
		Mem.w8(e + 4, (lvl >> 8) & 0xff)
		Mem.w8(e + 5, 0)
		Mem.w32(e + 0xc, ai)
		Mem.w32(e + 8, Mem.r8(0x4736e8 + kind))
		if not any:
			await _name_box()
			any = true
		await _summon_unit(e, j, pid, caster)
		made += 1
	if any:
		_done_self()
	else:
		await _msg("不能再添加了！")


## 0x424a87: the person's Data.e5 equipment codes (0x4264c6 unless EV 4029), Generate (0x42ad35), SetAI
## (0x459d95), then the unit enters at the caster's cell (0x4092c0, facing down) and faces the caster.
func _summon_unit(e: int, slot: int, pid: int, caster: BUnit) -> void:
	if Rules.evb(4029) == 0:
		var recs: Array = Assets.json("data/persons.json")
		var rec: Dictionary = recs[pid] if pid < recs.size() else {}
		Mem.w8(e + 9, 0xff if rec.get("weapon") == null else int(rec["weapon"]))
		Mem.w8(e + 0xa, 0xff if rec.get("armor") == null else int(rec["armor"]))
		Mem.w8(e + 0xb, 0xff if rec.get("accessory") == null else int(rec["accessory"]))
		Mem.w16(e + 6, 0xfefe)
	var u := st.units[slot]
	st._generate(u, Mem.r8(e + 8), e, pid, Vector2i(Mem.r8(e + 4), Mem.r8(e + 5)))
	st.set_ai(u, Mem.r8(e + 0xc), Mem.r16(e + 0xe), Mem.r8(e + 0xe), Mem.r8(e + 0xf))
	st.refresh_units()
	await st.revive(u, caster.pos.x, caster.pos.y, 2)
	st.actions.face(u, caster.pos)
	st.refresh_units()


## 0x42d387 移形换影: an ally (mode 3) and the caster exchange cells.
func _swap() -> void:
	var caster := _caster()
	if await _pick_target(3) == 0xff:
		return
	var t := _u(Mem.r8(C + 0xc))
	_set_t(0, t.slot)
	await _intro()
	var a := caster.pos
	var b := t.pos
	caster.pos = b
	t.pos = a
	st.refresh_units()
	_performed()
	_exp_target(0)
	_se(8)


## 0x428081 号令: a player-controlled ally that has not acted moves (0x43d4fc) and attacks (0x439413) at once; the
## context's first 16 bytes are restored afterwards (the target list then reads empty).
func _command() -> void:
	var saved := []
	for i in 16:
		saved.append(Mem.r8(C + i))
	saved[12] = 0xff
	saved[13] = 0xff
	saved[14] = 0xff
	saved[15] = 0xff
	var ts := await _pick_target(3)
	if ts == 0xff:
		return
	saved[12] = ts
	var t := _u(ts)
	if t.ai != 7:
		await _msg("只能对我军使用")
		return
	if (t.flags & 2) >= 2:
		await _msg("已经行动完毕。")
		return
	_set_t(0, Mem.r8(C + 0xc))
	await _intro()
	await _move_select(t, [], 0)
	_se(8)
	t.flags = t.flags & ~4
	await _attack_step(t)
	for i in 16:
		Mem.w8(C + i, saved[i])
	Mem.w8(C + 0x54c, 1)
	Mem.w8(C + 0x550, 1)
	_exp_target(0)


## 0x414e29 纵火 / 修筑: a cell (mode 4, byte 0x500ad7 = 2 meanwhile); the strategy name, a terrain change at the cell
## (0x4560f3: 纵火 type 0 → terrain 0x1a, 修筑 type 0xcc, terrain 0x14, 1000 gold), registered with timer 2 in the
## 10-slot list 0x501ae2; SE 0x13 / 9.
func _place_object() -> void:
	Mem.w8(Rules.STRAT_ITEM, 2)
	var c := _cell
	if Rules.in_map(c) and cell_check(_cs(), c) == 2:
		var caster := _caster()
		st.actions.face(caster, c)
		await _name_box()
		await st.actions.unit_pose(caster, 6)
		var e := Rules.s_effect(_cs())
		var typ := 0
		if e != 34:
			Game.gold = Game.gold - 1000
			typ = (e + 0xa9) & 0xff
		_place_terrain(c, 0x14, typ)
		Mem.w8(OBJ_COUNT, Mem.r8(OBJ_COUNT) + 1)
		for i in 10:
			var a := OBJ_LIST + 3 * i
			if Mem.r16(a) == 0xffff:
				Mem.w16(a, c.x | (c.y << 8))
				Mem.w8(a + 2, 2)
				break
		_done_self()
		_se(0x13 if e == 34 else 9)
	Mem.w8(Rules.STRAT_ITEM, 0)


## 0x4560f3 for one cell (camera, no sound): types 0 / 1..2 become terrain 0x1a / 0x1b unless EV 4036; the change
## is recorded (0x4b3d21) and drawn as a mark.
func _place_terrain(c: Vector2i, terr: int, typ: int) -> void:
	if Rules.evb(4036) == 0:
		if typ == 0:
			terr = 0x1a
		elif typ < 3:
			terr = 0x1b
	var old := Rules.raw_terrain(c)
	if st.view:
		st.view.set_terrain(c, terr)
		st.view.add_mark(typ, c)
	else:
		Mem.w8(Mem.MAP_BUF + 0x640 + c.x + c.y * Rules.map_w(), terr)
	st.terrain_changes.append({"x": c.x, "y": c.y, "new": terr, "old": old, "patch": typ, "silent": true, "node": null})
	st._record_terrain(c, terr, old, typ)
	st.refresh_units()


## A 纵火 / 修筑 object whose timer ran out (0x40ec9d): the cell's terrain is restored.
func remove_map_object(c: Vector2i) -> void:
	st._revert_terrain(c, -1)
	st.refresh_units()


# ------------------------------------------------------------------ results 0x4251bd / 0x42269c
## 0x4251bd: animation, results, performed.
func _apply() -> void:
	await _animate()
	await _results()
	_performed()


## 0x42269c: targets sorted (0x42554f); per target the code's effect and its result Meff, then the value: MP for
## 谍报 / MP recovery, HP and MP for 冥想, else HP (a heal capped at max HP, damage at HP); HP damage gives SP
## (0x410fc3) and, if the target survives, 自动使用 (0x416442). Armour EXP, 功勋 (+1 精神, +1 士气 after a miss).
func _results() -> void:
	var id := Rules.mg(Rules.MG_ID, _cs())
	_sort_targets()
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		var ts := _t(k)
		Mem.w8(C + 0xc, ts)
		var t := _u(ts)
		var caster := _caster()
		var code := _code(k)
		var fx := 0xff
		if code < 0x90:
			fx = await _result_code(code, t, k, caster)
		if fx != 0xff:
			await _meff(fx, [t.pos], false)
			st.refresh_units()
		var v := _val(k)
		if v != 0 and id != 32:
			var hpd := 0
			var mpd := 0
			if id == 3 or id == 14:
				mpd = v
			elif id == 24:
				hpd = _val(k + 1)
				mpd = v
			else:
				hpd = v
				var hp := t.hp
				if t.max_hp() < ((hp - hpd) & 0xffffffff):
					hpd = hp - t.max_hp()
				if hpd > hp:
					hpd = hp
			var spg := 0
			if hpd > 0:
				spg = Rules.sp_gain(t, hpd)
			# 0x4229e8: the result window (kind = SP gained, armour EXP of this target; long for a strategy without
			# area, ctx +0x4fc = 0) before the values change
			await st.result_panel(t, spg, hpd, mpd, 0, 0, Mem.r8(C + 0x50a + k) if k < 0x42 else 0,
					Mem.r8(C + 0x4fc) == 0)
			t.hp = t.hp - hpd
			t.mp = (t.mp & 0xffff) - mpd
			if hpd > 0 and t.hp != 0:
				await _auto_use(t, caster)
		elif fx != 0xff:
			await _ticks(8)
		var ae := Mem.r8(C + 0x50a + (k if k < 0x42 else 0))
		if ae != 0:
			await st.actions.equip_exp(t, 1, ae)
		_merit(t, 4 if fx == 0x2d else 2)
		await st.merit_after_strategy(t, true)       # 0x41d238(1)
		st.refresh_units()
		k += 1


## The per-target code (jump table 0x422aa0 via 0x422bc2). Returns the result Meff or 0xff.
func _result_code(code: int, t: BUnit, k: int, caster: BUnit) -> int:
	match code:
		0:
			return 0x2d if _val(k) == 0 else 0xff
		0x42:
			_buff_change(0x3b, t)
			return 0x2a
		0x43:
			await st.scripted_move(t, caster.pos, 4)
			return 0x30
		0x44, 0x45, 0x46, 0x47:
			_buff_change(BUFF_CODES[code - 0x44], t)
			return 0x27 + code - 0x44
		0x48:
			_buffs(t, 0, 4)
			return 0x2b
		0x49, 0x4a, 0x4b, 0x4c:
			if _val(k) >= t.hp:
				return 0xff
			var i := code - 0x49
			i = i ^ 1 if i < 2 else i
			t.inflict(STATUS_MASKS[i])
			return [0x31, 0x30, 0x32, 0x33][code - 0x49]
		0x52, 0x53, 0x54, 0x55:
			_buff_change(BUFF_CODES[5 + code - 0x52], t)
			return 0x22 + code - 0x52
		0x56:
			_buff_change(0x30, t)
			return 0x2e
		0x57:
			_buffs(t, 5, 4)
			return 0x26
		0x58:
			_buff_change(0x39, t)
			return 0x2e
		0x59:
			t.flags = t.flags & ~6
			return 0x2c
		0x5a:
			t.cure(BUnit.ST_ALL)
			return 0x2c
		0x5b:
			var s := _cs()
			Effects.added_set(t.pid, Rules.mg(Rules.MG_MCALL, s), Rules.mg(Rules.MG_HURT, s), Rules.mg(Rules.MG_HURTYN, s), false)
			return 0x26
	return 0xff


## 0x40bb87: n buff codes of 0x415531 from `start` (0: the four downs, 5: the four ups (+ move up with n 5)).
func _buffs(t: BUnit, start: int, n: int) -> void:
	for i in n:
		_buff_change(BUFF_CODES[start + i], t)


## buff_change 0x420cb4(code, T): the timers of 0x420bd3 (0x39 精进 3 turns for slots < 20; 0x3b 反間計 2 turns and
## the conversion 0x4073bc), then codes 0x17..0x38 move one stat to the extreme (0x43f98e): 0x17 / 0x19 / 0x1b /
## 0x1d / 0x1f down 爆发 士气 攻击 防御 移动, +0x1a up; 攻击 codes reach 攻击 and / or 精神 by the attack type.
func _buff_change(code: int, t: BUnit) -> void:
	if code == 0x39 or code == 0x3a:
		if t.slot < 0x14:
			Mem.w8(JINGJIN + t.slot, 3)
	elif code == 0x3b or code == 0x3c:
		_convert(t)
	var d := code - 0x17
	if d < 0 or d >= 0x22:
		return
	var k := d >> 1
	var up := k > 4
	if up:
		k -= 8
	if k < 0 or k > 8:
		return
	var stats: Array = [3]
	match k:
		0, 5: stats = [3]
		1, 6: stats = [4]
		2, 7: stats = Rules.attack_buff_stats(t)
		3, 8: stats = [1]
		4: stats = [5]
	for stat in stats:
		t.set_buff(stat, Rules.buff_step(t.buff(stat), up))


## 0x4073bc(T, 2) 反間計: timer 2; EV 4078: 0 → camp +3 and player-controlled, 1 → camp +3, else controlled only.
func _convert(t: BUnit) -> void:
	Mem.w8(FANJIAN + t.slot, 2)
	match Rules.evb(4078):
		0:
			t.kind = (t.kind + 3) & 0xff
			t.ai = 7
		1:
			t.kind = (t.kind + 3) & 0xff
		_:
			t.ai = 7


## 0x42554f: targets after the first ordered by row, then column (codes, armour EXP and values move along).
func _sort_targets() -> void:
	var n := 2
	while n < 0xfb and _t(n) != 0xff:
		var l := n
		while l > 1:
			var a := _u(_t(l - 1)).pos
			var b := _u(_t(l)).pos
			if a.y < b.y or (a.y == b.y and a.x <= b.x):
				break
			_swap8(C + 0xc + l, C + 0xd + l)
			_swap8(C + 0x400 + l, C + 0x401 + l)
			if l < 0x42:
				_swap8(C + 0x509 + l, C + 0x50a + l)
			if l < 0xbe:
				var x := Mem.r32(C + 0x104 + 4 * l)
				Mem.w32(C + 0x104 + 4 * l, Mem.r32(C + 0x108 + 4 * l))
				Mem.w32(C + 0x108 + 4 * l, x)
			l -= 1
		n += 1


func _swap8(a: int, b: int) -> void:
	var x := Mem.r8(a)
	Mem.w8(a, Mem.r8(b))
	Mem.w8(b, x)


## 自动使用 0x416442 after strategy HP damage on a surviving target (the combat track's item code).
func _auto_use(t: BUnit, caster: BUnit) -> void:
	if st.actions.has_method("auto_use"):
		await st.actions.call("auto_use", t, caster)


## 功勋 0x42aa0b(s, 1) for persons < 0x66 (0x42acd2).
func _merit(u: BUnit, s: int) -> void:
	if u.pid >= 0 and u.pid < 0x66:
		st._merit_gain(u, s, 1)


# ------------------------------------------------------------------ caster bookkeeping 0x422f2e
## After a cast: MP cost (none with byte 0x500fcc; the whole MP if it does not suffice), 吸收HP / 生命交换 heal the
## caster by the damage total, 吸收MP refills MP; 策略吸血 and 策略反伤 (never lethal); SP for the MP spent; EXP and
## weapon EXP; 功勋 +1 精神. Clears the 策略连击 state.
func _finish() -> void:
	var caster := _caster()
	if Mem.r32(C + 0x550) == 0 or caster == null or caster.state != 2:
		Mem.w32(TOTAL, 0)
		Mem.w8(REPEAT, 0)
		return
	var s := _cs()
	var hp := caster.hp
	var cost := 0 if Mem.r8(FREE_CAST) != 0 else Rules.mp_cost(caster, s)
	var mp := caster.mp & 0xffff
	var rem := Rules.sat_sub(mp, cost)
	if rem == 0:
		cost = mp
	var tr := _totals()
	var total: int = tr[0]
	var e := Rules.s_effect(s)
	var gain := 0
	var mpd := -cost
	var miss := caster.max_hp() - hp
	if e == 5 or e == 30:
		gain = _min_u(total, miss)
	elif e == 6:
		var g := _min_u(total, caster.max_mp() - rem)
		rem += g
		mpd = g - cost
	var q := caster.eff(0x43, 0x56, 1, 0)
	if q != 0:
		gain = _min_u(Rules.pct(q, total & 0xffffffff) + gain, miss)
	var refl: int = tr[1]
	if refl != 0:
		gain -= refl
		if gain < 0:
			var g := -gain
			if hp <= g:
				g = hp - 1
			gain = -g
	if mpd < 0:
		Rules.sp_gain(caster, -mpd * 2)
	# 0x423088: the caster's result window (EXP bar rising by the strategy EXP, weapon EXP) before HP / MP change
	await st.result_panel(caster, 0x100, -gain, -mpd, Mem.r32(C + 0x502), Mem.r32(C + 0x506), 0, true)
	caster.hp = hp + gain
	caster.mp = rem
	var x := Mem.r32(C + 0x502)
	if x > 0:
		await st.actions.set_exp(caster, x)
	var w := Mem.r32(C + 0x506)
	if w > 0:
		await st.actions.equip_exp(caster, 0, w)
	_merit(caster, 2)
	await st.merit_after_strategy(caster, false)     # 0x411892 → 0x41d238(0)
	Mem.w32(TOTAL, 0)
	Mem.w8(REPEAT, 0)
	st.refresh_units()


## 0x42356e-style minimum of two values compared as unsigned 32-bit (a negative total — 換血 on a target with less
## HP — reads huge, so the cap wins).
func _min_u(a: int, b: int) -> int:
	return a if (a & 0xffffffff) < (b & 0xffffffff) else b


## 0x42bbba: [damage total = dword 0x500c42 if set, else the sum of positive values; reflection = Σ value ·
## 策略反伤(target) %].
func _totals() -> Array:
	var sum := 0
	var refl := 0
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		var v := _val(k)
		if v > 0:
			sum += v
			var q := _u(_t(k)).eff(0x42, 0x55, 1, 0)
			if q != 0:
				refl += Rules.pct(v, q)
		k += 1
	var t := Mem.r32s(TOTAL)
	return [t if t != 0 else sum, refl]


# ------------------------------------------------------------------ EXP 0x44de9e / 0x420efb / 0x421363 / 0x421409
## 0x44de9e: the context keeps the largest strategy EXP and weapon EXP; the armour EXP per target.
func _exp_target(k: int) -> void:
	var x := _strat_exp(k)
	if Mem.r32(C + 0x502) < x:
		Mem.w32(C + 0x502, x)
	var w := _weapon_exp()
	if Mem.r32(C + 0x506) < w:
		Mem.w32(C + 0x506, w)
	if k < 0x42:
		Mem.w8(C + 0x50a + k, _armour_exp(k) & 0xff)


## 0x416f0f: EXP of a self / special strategy (target 0), performed.
func _self_exp() -> void:
	Mem.w32(C + 0x502, _strat_exp(0))
	Mem.w32(C + 0x506, _weapon_exp())
	_performed()


## 0x40ea8e: the caster as the target, then 0x416f0f.
func _done_self() -> void:
	_set_t(0, Mem.r8(C + 1))
	Mem.w8(C + 0xc, Mem.r8(C + 1))
	_self_exp()


## 0x420efb: weather strategies 20; otherwise by the level difference to the current target, the kill formula when
## an enemy-targeted damaging strategy's value (unsigned) reaches its HP (with the kill hook: 大杀四方, kill count,
## 功勋), ×2 on the battle's leader; 0 when the caster earns none.
func _strat_exp(k: int) -> int:
	var earns := Mem.r32(C + 0x54c) != 0
	var s := _cs()
	var side := Rules.s_side(s)
	var caster := _caster()
	var x := 0
	if side == 2:
		x = 20
	else:
		var t := _u(Mem.r8(C + 0xc))
		if t == null or t.pid < 0:
			return 0
		var lc := caster.level()
		var lt := t.level()
		var hp := t.hp
		if side == 1 or Rules.mg(Rules.MG_HURTYN, s) >= 4 or (_val(k) & 0xffffffff) < hp:
			if not earns:
				return 0
			var d := lc - lt
			x = mini(-d * 4 + 10, 100) if d < 0 else maxi(Rules.sat_sub(10, d >> 1), 5)
		else:
			if hp != 0:
				_kill_hook(caster, earns)
			if not earns:
				return 0
			if caster.pid >= 0 and caster.pid < 0x66:
				for i in 5:
					st._merit_gain(caster, i, 1)
			var d := lc - lt
			x = mini(-d * 8 + 32, 200) if d < 0 else maxi(Rules.sat_sub(32, d * 4), 10)
			if Mem.r32(t.addr) == Mem.r16(BOSS):
				x *= 2
	return _exp_scale(caster, x, true)


## 0x4290c8: 大杀四方 (Q(0x40, 0x54, 1, 0) above the counter +0x24 → act again after the action) and the person's
## kill count +1 (0x426ba0, not in the 练武场) when the caster earns EXP.
func _kill_hook(u: BUnit, earns: bool) -> void:
	var v := u.eff(0x40, 0x54, 1, 0) & 0xff
	if v != 0 and u.byte(0x24) < v:
		u.set_byte(0x24, u.byte(0x24) | 0x80)
	if earns and Rules.evb(4087) == 0:
		var a := u.person.base + 0x35
		Mem.w16(a, Mem.r16(a) + 1)


## 0x421363: weapon EXP 3 (2 against a lower-level target) when the caster earns EXP and its weapon is a 策略 weapon
## (treasure special 0x19, or a spirit / attack-and-spirit type), scaled.
func _weapon_exp() -> int:
	if Mem.r32(C + 0x54c) == 0 or not _arena_ok():
		return 0
	var caster := _caster()
	var p := caster.person
	var w := Mem.r8(p.base + 0x2e)
	var ok := false
	var it := Game.item(w)
	if w != 0xff:
		var sp: Variant = it.get("special")
		ok = sp != null and int(sp) == 0x19
	if not ok:
		var st_t := Person.stat_of_type(int(it.get("type", 0xff)))
		ok = st_t == 2 or st_t == 10
	if not ok:
		return 0
	var c := 3
	if Rules.s_side(_cs()) != 2:
		var t := _u(Mem.r8(C + 0xc))
		if t != null and t.pid >= 0 and t.level() < caster.level():
			c = 2
	return _exp_scale(caster, c, false)


## 0x421409: armour EXP of a player-army target hit by an enemy-targeted strategy with a value: 4, 3 when the
## target's level is above the caster's.
func _armour_exp(k: int) -> int:
	if not _arena_ok():
		return 0
	var t := _u(Mem.r8(C + 0xc))
	if t == null or t.kind != 0:
		return 0
	var c := 0
	if Rules.s_side(_cs()) == 0 and _val(k) != 0:
		c = 3 if t.level() > _caster().level() else 4
	return _exp_scale(t, c, false)


## 0x403262: EXP outside the 练武场, or with byte 0x4ce24b / 0x500af1 set.
func _arena_ok() -> bool:
	return Rules.evb(4087) == 0 or Mem.r8(0x4ce24b) == 1 or Mem.r8(0x500af1) == 1


## ExpMod 0x42104f: × (100 + 辅助获得Exp) / 100; equipment EXP always, person EXP only with EV 4079: ×2 with 精进
## (player army), ×2 in 围攻.
func _exp_scale(u: BUnit, x: int, is_person: bool) -> int:
	var v := x * (100 + (u.person.equip_bonus(8) & 0xff)) / 100
	if not is_person or Rules.evb(4079) != 0:
		if u.kind == 0 and Mem.r8(JINGJIN + u.slot) != 0:
			v *= 2
		if Rules.attack_mode() == 1:
			v *= 2
	return v


# ------------------------------------------------------------------ 军师技 0x467c9e
## 文官必杀 0x467c9e: not in the 练武场, the gate (0x4225fb), a family with attr8; index attr8 − 1 (rand(8) past 8);
## context init with strategy 0x3b (输送), the handler of 0x467d1d, last action 5, SP −= its cost (0x423910).
func family_special(u: BUnit) -> bool:
	if Rules.evb(4087) != 0 or Rules.can_use_skill(u) == 0:
		return false
	var a := Rules.fam_attr(8, u.family())
	if a == 0:
		return false
	var idx := a - 1
	if idx >= 9:
		idx = Rules.rand(8)
	_init_ctx(0x3b, u)
	Mem.w8(FS_INDEX, idx)
	var near := 0x0c000000 if u.kind < 2 else 0x0a000000
	match idx:
		0:      # 重生 0x451195: own camp incl. self: heal (输送 formula), ailments cleared
			await _fs_intro(u, idx)
			_fs_collect(u, 0x01010006, near)
			Mem.w8(C + 0x400, 0x50)
			await _fs_apply(0, 10, 1, true)
			await _fs_exp(u, 4 if u.kind < 2 else 2)
		1:      # 歷精圖治 0x4510ba: own camp: the five buffs 6
			await _fs_intro(u, idx)
			_fs_collect(u, 0x01010005, near)
			Mem.w8(C + 0x400, 0x50)
			await _fs_apply(0x26, 0x11, 6, false)
			await _fs_exp(u, 4 if u.kind < 2 else 2)
		2:      # 八陣圖 0x451129: the other camp: the five buffs 0
			await _fs_intro(u, idx)
			_fs_collect(u, 0x00000005, near)
			Mem.w8(C + 0x400, 0x40)
			await _fs_apply(0x27, 0x12, 0, false)
			await _fs_exp(u, 2 if u.kind < 2 else 4)
		3:      # 巫蠱 0x42ac0a
			await _wugu(u)
		4:      # 鼓舞 0x41dbcd: own camp: 攻击 up
			await _fs_intro(u, idx)
			_fs_collect(u, 0x01010005, near)
			Mem.w8(C + 0x400, 0x50)
			await _fs_buff(0x26, 0x11, 0x35, 0x50)
			await _fs_exp(u, 4 if u.kind < 2 else 2)
		5:      # 賣慘 0x422c4a: the other camp: 攻击 down
			await _fs_intro(u, idx)
			_fs_collect(u, 0x00010005, near)
			Mem.w8(C + 0x400, 0x40)
			await _fs_buff(0x27, 0x12, 0x1b, 0x40)
			await _fs_exp(u, 2 if u.kind < 2 else 4)
		6:      # 濟世 0x43bf2a: as 重生, then move up and 50 % MP (0x420200)
			await _fs_intro(u, idx)
			_fs_collect(u, 0x01010006, near)
			Mem.w8(C + 0x400, 0x50)
			await _fs_apply(0, 10, 1, true)
			var k := 0
			while k < 0xfb and _t(k) != 0xff:
				var t := _u(_t(k))
				t.set_buff(5, 6)
				_mp_restore(t, 0x32)
				k += 1
			await _fs_exp(u, 4 if u.kind < 2 else 2)
		7:      # 超度 0x436d8b: 玄武 from slot 0 as strategy 51, no intro
			await _fs_intro(u, idx)
			Mem.w8(NO_INTRO, 1)
			Mem.w8(C, 0x33)
			Mem.w8(C + 0x400, 0xff)
			await _xuanwu(0, 1)
			Mem.w8(NO_INTRO, 0)
			await _fs_exp(u, 2)
		8:      # 再戰 0x410339: own camp without the caster may act again
			await _fs_intro(u, idx)
			_fs_collect(u, 0x01000005, near)
			Mem.w8(C + 0x400, 0x50)
			var k := 0
			while k < 0xfb and _t(k) != 0xff:
				if _t(k) == Mem.r8(C + 1):
					_set_t(k, _t(k + 1))
				else:
					var t := _u(_t(k))
					t.flags = t.flags & ~6
					_set_code(k, 0x50)
				k += 1
			await _fs_anim(0x1d, 0x2c, false)
			await _fs_exp(u, 4 if u.kind < 2 else 2)
	Mem.w8(BattleStage.LAST_ACTION, 5)
	Rules.spend_sp(u.pid, 0x4f + a)
	st.refresh_units()
	return true


## 0x413870: the unit's action 7, SE 0x27, the 军师技 name (record 80 + index).
func _fs_intro(u: BUnit, idx: int) -> void:
	u.dir = 2
	await st.actions.unit_pose(u, 7)
	_se(0x27)
	await _msg(str(Rules.skill(80 + idx).get("name", "")))


## 0x422caf(list, unit, p2, p3): the units of range code p3 >> 24 around the caster (collect flags p2 >> 24; code 10
## with flags 1 drops the first, i.e. the caster), the caster only with p2 byte 2, level ≤ the caster's with p3
## byte 2; ops (p2 byte 0) > 5 fill the values: 6 heal (amount 0: the strategy formula, else HP光环 %), 7 MP光环,
## 8 SP光环, ≥ 9 诅咒光环 damage — the last three applied at once.
func _fs_collect(u: BUnit, p2: int, p3: int) -> void:
	var op := p2 & 0xff
	var amount := (p2 >> 8) & 0xff
	var with_self := ((p2 >> 16) & 0xff) == 1
	var flags := (p2 >> 24) & 0xff
	var code := (p3 >> 24) & 0xff
	var lvl_cap := ((p3 >> 16) & 0xff) == 1
	var found := Rules.collect(u, u.pos, [code, 0xff, 0xff, 0xff], flags)
	var start := 1 if (code == 10 and flags == 1) else 0
	var lv := _caster().level()
	var k := 0
	for i in range(start, found.size()):
		var o: BUnit = found[i]
		if not with_self and o.slot == u.slot:
			continue
		if lvl_cap and lv < o.level():
			continue
		_set_t(k, o.slot)
		if op > 5:
			var v := 0
			if op == 6:
				if amount == 0:
					Mem.w8(C + 0xc, o.slot)
					v = -Rules.heal_amount(o, _cs(), _caster(), false)
				else:
					v = -_hp_aura(o, amount)
			elif op == 7:
				v = -_mp_restore(o, amount)
			elif op == 8:
				v = -Rules.add_sp(o.pid, amount, true)
			else:
				v = _curse(o, amount)
			_set_val(k, v)
			_set_code(k, _ctx_code())
		k += 1


## 0x45126c(ctx, a, b, p): p byte 0 == 1 → HP −= value and (unless byte 1 is 7) ailments cleared; else byte 1 == 0 →
## the five buff levels = byte 0, else buff byte 1 − 1 = byte 0. Codes 0x40 / 0x50; then Meff b, a (0x451204).
func _fs_apply(a: int, b: int, p: int, numbers: bool) -> void:
	var lo := p & 0xff
	var b1 := (p >> 8) & 0xff
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		Mem.w8(C + 0xc, _t(k))
		var t := _u(_t(k))
		if lo == 1:
			t.hp = t.hp - _val(k)
			if b1 != 7:
				t.status = 0
		elif b1 == 0:
			for i in 5:
				t.set_buff(i, lo)
		else:
			t.set_buff(b1 - 1, lo)
		_set_code(k, 0x40 if lo == 0 else 0x50)
		k += 1
	await _fs_anim(b, a, numbers)


## 0x40e89b(ctx, a, b, up, code): buff_change(0x35 / 0x1b) on every target, then Meff b, a.
func _fs_buff(a: int, b: int, buff: int, code: int) -> void:
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		_buff_change(buff, _u(_t(k)))
		_set_code(k, code)
		k += 1
	await _fs_anim(b, a, false)


## 0x451204(a, b): Meff a, then b if non-zero, on the targets with the hit frame.
func _fs_anim(a: int, b: int, numbers: bool) -> void:
	var cells := _target_cells()
	await _meff(a, cells, true, numbers)
	if b != 0:
		await _meff(b, cells, true, numbers)
	_restore_poses()


## 0x409b67(unit, k): EXP over the targets of the matching camp (0x429f77: k 4 player army, else the others), the
## caster has acted (0x4253f6), EXP and weapon EXP to the context's person (0x41a0ac).
func _fs_exp(u: BUnit, k: int) -> void:
	var i := 0
	while i < 0xfb and _t(i) != 0xff:
		var t := _u(_t(i))
		var kd := t.kind
		if (kd < 2) if k == 4 else (kd > 1 and kd < 0x80):
			Mem.w8(C + 0xc, t.slot)
			var x := _strat_exp(i)
			if Mem.r32(C + 0x502) < x:
				Mem.w32(C + 0x502, x)
			var w := _weapon_exp()
			if Mem.r32(C + 0x506) < w:
				Mem.w32(C + 0x506, w)
		i += 1
	u.flags = u.flags | 6
	var p := _caster()
	if p != null and p.pid >= 0:
		var x := Mem.r32(C + 0x502)
		if x > 0:
			await st.actions.set_exp(p, x)
		var w := Mem.r32(C + 0x506)
		if w > 0:
			await st.actions.equip_exp(p, 0, w)


## 巫蠱 0x42ac0a → 0x45ade7(0, 0, H, W, camp, 6, 0x16): the context re-initialised for slot 60; cells x 0..H,
## y 0..W (the map's sides swapped, inclusive) holding a unit of the other camp (CountUnits code 5 / 4 by
## 0x42e2ed) get 麻痹 禁咒 中毒 (status event 6, mask 0x16); Meff 0x31 on them unless EV 4043; then 0x409b67.
func _wugu(u: BUnit) -> void:
	var code := 5 if u.side() == 1 else 4
	await _fs_intro(u, 3)
	_init_ctx(0, st.units[60])
	var W := Rules.map_w()
	var H := Rules.map_h()
	var n := 0
	for y in range(0, W + 1):
		for x in range(0, H + 1):
			var o := Rules.unit_at(Vector2i(x, y))
			if o == null or o.state != 2 or not _camp_code_ok(o, code):
				continue
			_set_t(n, o.slot)
			n += 1
			o.inflict(0x16)
	st.refresh_units()
	if n != 0 and Rules.ev(4043) == 0:
		await _meff(0x31, _target_cells(), false)
	await _fs_exp(u, code)


## 0x45aed1 with the camp code of 0x42e2ed: slots < 20 → 0, < 60 → 1, else the kind (5 / 6 by the 反間計 timer, 3
## and 6 +1 with EV 4053, > 3 → −1); codes < 4 equal, 4 → < 2, 5 → 2 or 3, 6 any.
func _camp_code_ok(o: BUnit, code: int) -> bool:
	var v := 0
	if o.slot >= 20:
		if o.slot < 60:
			v = 1
		else:
			var k := o.kind
			v = k
			if k == 5:
				if Mem.r8(FANJIAN + o.slot) == 0:
					v = 2
			elif k == 3 or (k == 6 and Mem.r8(FANJIAN + o.slot) == 0):
				if k == 6:
					v = 3
				if Rules.evb(4053) != 0:
					v += 1
	if v > 3:
		v -= 1
	if code < 4:
		return v == code
	if code == 4:
		return v < 2
	if code == 5:
		return v == 2 or v == 3
	return code == 6


# ------------------------------------------------------------------ auras 0x42f8d9
## Auras 0x42f8d9 at the unit's side's turn start (in 0x43cddd): Buff光环 (mask = OR of Q(0x97 + i, 0x7f, 3, 0),
## each bit j: the same-camp neighbours' buff j = 6), then HP光环 101, MP光环 102 (> 100 → 0), SP光环 103 and
## 诅咒光环 104 (the other camp), each on the 8 neighbours with its Meff.
func turn_auras(u: BUnit) -> void:
	if u.state != 2:
		return
	var acc := 0
	var nxt := 0
	for c in 10:
		var v: int
		if c <= 5:
			v = u.eff(0x97 + c, 0x7f, 3, 0)
			acc |= v
			if c != 5:
				continue
		else:
			v = u.eff(0x65 + c - 6, [0x52, 0x53, 0, 0][c - 6], 0, 0)
			acc = v
		if acc == 0:
			nxt = 6 if nxt == 0 else nxt + 1
			continue
		while nxt <= c:
			_init_ctx(0x43, u)
			if c < 6:
				if (acc >> nxt) & 1:
					await _aura_buff(u, nxt)
			else:
				var w := acc
				if (acc & 0xff) > 100 and nxt == 7:
					w = 0
				await _aura(u, nxt, w & 0xff)
			nxt += 1
	st.refresh_units()


## 0x42dc04: buff j of the same-camp neighbours (not the unit) = 6; Meff 0x42faa7[j], 0x42faad[j].
func _aura_buff(u: BUnit, j: int) -> void:
	_fs_collect(u, 0x01000001, 0x01000000)
	Mem.w8(C + 0x400, 0x50)
	await _fs_apply(AURA_MEFF_B[j], AURA_MEFF_A[j], ((j + 1) << 8) | 6, false)


## 0x42fdcb → 0x42f9da HP (Meff 10), 0x42fa10 MP (Meff 11), 0x42fa41 SP (Meff 0x1d), 0x42fa72 诅咒 (other camp,
## Meff 0x1f) on the 8 neighbours.
func _aura(u: BUnit, k: int, v: int) -> void:
	var p2 := 0x01000000 | (v << 8) | k
	match k:
		6:
			_fs_collect(u, p2, 0x01000000)
			Mem.w8(C + 0x400, 0x50)
			await _fs_apply(0, 10, 0x701, true)
		7:
			Mem.w8(C + 0x400, 0x51)
			_fs_collect(u, p2, 0x01000000)
			await _fs_anim(0xb, 0, true)
		8:
			Mem.w8(C + 0x400, 0x52)
			_fs_collect(u, p2, 0x01000000)
			await _fs_anim(0x1d, 0, true)
		9:
			Mem.w8(C + 0x400, 0x40)
			_fs_collect(u, p2 & 0xffffff, 0x01000000)
			await _fs_anim(0x1f, 0, true)


## 0x422e68: HP光环 heal min(max HP · v %, the missing HP).
func _hp_aura(t: BUnit, v: int) -> int:
	var mh := t.max_hp()
	var inc := Rules.pct(v, mh)
	if mh <= t.hp + inc:
		inc = mh - t.hp
	return inc


## 0x436ce1: MP += max MP · v % (v 0: (caster level + 10) · 10 %), capped; returns the gain.
func _mp_restore(t: BUnit, v: int) -> int:
	var mm := t.max_mp()
	var base := mm
	if v == 0:
		v = 10
		base = _caster().level() + 10
	var inc := Rules.pct(v, base)
	if mm <= t.mp + inc:
		inc = mm - t.mp
	t.mp = t.mp + inc
	return inc


## 0x44e024(T, v, 0): 诅咒 damage max(max HP · v %, 1), never below 1 HP; applied, returned.
func _curse(t: BUnit, v: int) -> int:
	var d := Rules.pct(v, t.max_hp())
	if d == 0:
		d = 1
	if t.hp <= d:
		d = t.hp - 1
	t.hp = t.hp - d
	return d


# ------------------------------------------------------------------ animation 0x421496 / 0x4218a9 / 0x421ab6
## 0x421496: nothing with the 不显示策略动画 option (0x501a75); a critical's 25 % roll (0x40eab4, its 3-digit Mcall
## does not ship); the intro (not for 青龙 / with 0x500e9b); the big animation Mcall (flag +0x554; 玄武 / 白虎 at
## the view centre, else the first target); 八阵图's eight Meff by code (0x4216c0); the strategy Meff on the targets
## (cue 1: the hit frame); 10 ticks with the hit poses.
func _animate() -> void:
	if Mem.r8(SKIP_ANIM) != 0:
		return
	var s := _cs()
	if Rules.evb(4087) == 0 and Mem.r8(C + 3) == 1 and Rules.chance(25):
		pass
	var id := Rules.mg(Rules.MG_ID, s)
	var mc := Rules.mg(Rules.MG_MCALL, s)
	if (id != 26 or Rules.s_effect(s) != 25) and Mem.r8(NO_INTRO) != 1:
		await _intro()
	var first := _u(_t(0))
	var fpos := first.pos if first != null else _caster().pos
	Mem.w8(C + 0x4fd, fpos.x)
	Mem.w8(C + 0x4fe, fpos.y)
	if Mem.r32(C + 0x554) != 0:
		var pt: Vector2
		if id == 28 or id == 29:
			pt = _view_centre()
		else:
			await _look(fpos)
			pt = _cell_point(fpos)
		await _mcall(mc, pt)
		Mem.w32(C + 0x554, 0)
	var me := mc
	if mc > 99 and mc != 0xff and id == 12:
		await _bazhen_multi()
	if mc != 0xff:
		me = Rules.mg(Rules.MG_MEFF, s)
	if me != 0xff:
		await _look(fpos)
		await _meff(me, _target_cells(), true)
	await _ticks(10)
	_restore_poses()


## 0x4216c0: for each of the eight codes, Meff 0x4785ce[i] on the targets holding it (the result code set to it).
func _bazhen_multi() -> void:
	for i in 8:
		Mem.w8(C + 0x400, ROLL_CODES[i])
		var cells: Array = []
		var k := 0
		while k < 0xbe and _t(k) != 0xff:
			if _code(k) == ROLL_CODES[i]:
				cells.append(_u(_t(k)).pos)
			k += 1
		if not cells.is_empty():
			await _meff(ROLL_MEFF[i], cells, true)


## 0x4218a9: the caster faces the first target (玄武 / 白虎: down) and shows its cast frame, SE 8 after 8 ticks, the
## camera on the first target (result codes 0x4x..0x7x), SE 0x27, the strategy name box (not in the 练武场), at least
## 20 ticks in all.
func _intro() -> void:
	var caster := _caster()
	var id := Rules.mg(Rules.MG_ID, _cs())
	var first := _u(_t(0))
	if id == 28 or id == 29:
		caster.dir = 2
	elif first != null:
		st.actions.face(caster, first.pos)
	if caster.node and not Game.autoplay:
		caster.node.attack_frame(caster.dir, 0)
	await _ticks(8)
	_se(8)
	if (Mem.r8(C + 0x400) & 0x70) != 0 and first != null:
		await _look(first.pos)
	if Mem.r8(C + 3) == 1 and caster.node and not Game.autoplay:
		caster.node.flash = 0.6
	var t0 := Time.get_ticks_msec()
	_se(0x27)
	if Rules.evb(4087) == 0:
		await _msg(str(Rules.strat(_cs()).get("name", "")))
	var spent := (Time.get_ticks_msec() - t0) / 50
	if spent < 20:
		await _ticks(20 - spent)
	if caster.node:
		caster.node.flash = 0.0
		caster.node.set_pose(UnitSprite.Pose.STAND, caster.dir)
	st.refresh_units()


## 0x406ead: the strategy name in the message box.
func _name_box() -> void:
	await _msg(str(Rules.strat(_cs()).get("name", "")))


## 0x421ab6: the hit frame — targets whose code is the context's 0x4x code show the hurt frame, 0x5x the cheer
## frame, code 0 the defend frame of their facing; then their value (heal: MP 0x51, SP 0x52 colours; damage: MP
## 0x41, critical (clears +3)).
func _hit_frame(numbers: bool) -> void:
	var cc := _ctx_code()
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		var t := _u(_t(k))
		var code := _code(k)
		var show := true
		if (code & 0x70) == 0x40 and code == cc:
			_pose(t, UnitSprite.Pose.HURT)
		elif (code & 0x70) == 0x50 and code == cc:
			_pose(t, UnitSprite.Pose.CHEER)
		elif code == 0:
			_pose(t, UnitSprite.Pose.DEFEND)
		else:
			show = false
		if show and numbers:
			var v := _val(k)
			if v < 0:
				_number(t.pos, -v, true, code == 0x51, false)
			elif v > 0:
				var crit := false
				if code != 0x41 and Mem.r8(C + 3) != 0:
					crit = true
					Mem.w8(C + 3, 0)
				_number(t.pos, v, false, code == 0x41, crit)
		k += 1


func _restore_poses() -> void:
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		var t := _u(_t(k))
		if t != null and t.node and t.node.pose in [UnitSprite.Pose.HURT, UnitSprite.Pose.CHEER, UnitSprite.Pose.DEFEND]:
			t.node.set_pose(UnitSprite.Pose.STAND, t.dir)
		k += 1
	st.refresh_units()


## Meff `n` on the cells inside the view (0x40bcd2 / 0x40196f / 0x401e5d), with the hit frame or not. False when
## no cell was on screen (then nothing plays).
func _meff(n: int, cells: Array, with_hit: bool, numbers := true) -> bool:
	var pts := []
	for c in cells:
		if _on_screen(c) and pts.size() < 250:
			pts.append(_cell_point(c))
	if pts.is_empty():
		return false
	var cb := _hit_frame.bind(numbers) if with_hit else Callable()
	await EffectPlayer.play("xben", n, _layer(), pts, cb)
	return true


## Mcall(n % 100) at a world point (0x40eb54 / 0x40345b), then 4 ticks.
func _mcall(n: int, pt: Vector2) -> void:
	await EffectPlayer.play("mcall", n % 100, _layer(), [pt])
	await _ticks(4)


func _target_cells() -> Array:
	var out := []
	var k := 0
	while k < 0xfb and _t(k) != 0xff:
		out.append(_u(_t(k)).pos)
		k += 1
	return out


func _layer() -> Node:
	return st.view.fx_layer if st.view else null


func _cell_point(c: Vector2i) -> Vector2:
	return st.view.cell_center(c) if st.view else Vector2(c * 48) + Vector2(24, 24)


func _view_centre() -> Vector2:
	if st.view == null or st.view.camera == null:
		return Vector2.ZERO
	return st.view.camera.position + st.view.view_size() / 2


## 0x40196f's screen test: the cell centre inside the view.
func _on_screen(c: Vector2i) -> bool:
	if st.view == null or st.view.camera == null:
		return true
	var p := st.view.cell_center(c)
	var cam := st.view.camera.position
	var vs := st.view.view_size()
	return p.x >= cam.x and p.x < cam.x + vs.x and p.y >= cam.y and p.y < cam.y + vs.y


## 0x45503f: bring the cell into view.
func _look(c: Vector2i) -> void:
	if st.view == null:
		return
	if Game.autoplay:
		st.view.ensure_visible(c, false)
		return
	await st.view.ensure_visible(c)


func _pose(u: BUnit, p: int) -> void:
	if u != null and u.node and not Game.autoplay:
		u.node.set_pose(p, u.dir)


## Damage / heal numbers of the hit frame. [G colours]
func _number(c: Vector2i, v: int, heal: bool, mp: bool, crit: bool) -> void:
	if st.hud == null:
		return
	var col := Color(1, 1, 1)
	if mp:
		col = Color(0.5, 0.75, 1)
	elif heal:
		col = Color(0.45, 1, 0.45)
	elif crit:
		col = Color(1, 0.9, 0.2)
	st.hud.popup_number(("+%d" if heal else "%d") % v, c, col)


func _msg(text: String) -> void:
	if text == "" or st.ui == null:
		return
	await st.ui.message(2, text)


func _se(n: int) -> void:
	if not Game.autoplay:
		Audio.play_se(SoundMap.se_name(n))


func _ticks(n: int) -> void:
	await st.wait(n * TICK)
