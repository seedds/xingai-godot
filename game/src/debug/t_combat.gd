extends Node
## BattleActions checks (docs/battle.md §1, §4, §5) against hand-computed cases. The rolls run in 集气 mode
## (EV 4018 = 1: the per-unit accumulators decide every hit / critical / double roll), so the only LCG draws of a
## plain exchange are the damage spreads rand(7) (and chance(25) after a critical); each case predicts them from the
## seed. Headless, autoplay.
##   tools/gtest.sh t_combat
## Prints "t_combat: PASS" at the end.

var ui: GameUI
var st: BattleStage
var stage = null
var ok := true

const AP := Vector2i(5, 5)
const DP := Vector2i(6, 5)
const APID := 5          # a person < 102 in the army: has a 功勋 store
const DPID := 402


func _check(cond: bool, what: String) -> void:
	if not cond:
		ok = false
		print("t_combat: FAIL ", what)
	else:
		print("t_combat: ok   ", what)


func _ev(n: int, v: int) -> void:
	Mem.w32(Mem.EV + 4 * n, v)


func _person(pid: int, cls: int, lv: int, stats: Array) -> Person:
	var p := Game.person(pid)
	p.cls = cls
	p.level = lv
	p.exp = 0
	for i in 5:
		p.set_stat_word(i, stats[i])
	for k in 3:
		Mem.w8(p.base + 0x2e + 3 * k, 0xff)
	return p


func _unit(slot: int, pid: int, kind: int, c: Vector2i) -> BUnit:
	var u: BUnit = st.units[slot]
	Mem.fill(u.addr, Mem.UNIT_SIZE, 0)
	Mem.w8(u.addr + 4, slot)
	Mem.w32(u.addr, pid)
	u.kind = kind
	u.state = 2
	u.pos = c
	for i in 6:
		u.set_buff(i, 3)
	u.hp = u.max_hp()
	u.mp = u.max_mp()
	u.ai = 7 if kind == 0 else 1
	u.dir = 2
	return u


## A fresh field: the attacker A (slot 0, player army) left of the enemy D (slot 60); accumulators, hit counters,
## SP and 功勋 cleared.
func _field(a_stats: Array, d_stats: Array) -> Array:
	for u in st.units:
		Mem.fill(u.addr, Mem.UNIT_SIZE, 0)
		Mem.w32(u.addr, 0xffff)
		Mem.w8(u.addr + 4, u.slot)
		Mem.w16(u.addr + 6, 0xffff)
	Mem.fill(Mem.MAP_BUF + 0x640, 20 * 20, 0)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)
	Mem.fill(Rules.ACC, 1000, 0)
	Mem.fill(Rules.HITS, 250, 0)
	Mem.fill(0x501b00, 20, 0)
	Mem.fill(0x508000, 0x400, 0)
	Mem.w32(Rules.COUNTER_DEPTH, 0)
	Mem.w8(BattleActions.LAST_ACTION, 0xff)
	Rules.set_attack_mode(0)
	var pa := _person(APID, 0, 20, a_stats)
	pa.army = 0
	_person(DPID, 0, 18, d_stats)
	Mem.w8(Mem.SP + APID, 0)
	Mem.w8(Mem.SP + DPID, 0)
	var a := _unit(0, APID, 0, AP)
	var d := _unit(60, DPID, 2, DP)
	st.refresh_units()
	return [a, d]


## The damage spread of Modifiers 0x412c78: rand(7) > 2 → + r − 2, else − r (at least 1).
func _spread(dmg: int) -> int:
	var r := Rules.rand(7)
	if r > 2:
		return dmg + r - 2
	return maxi(Rules.sat_sub(dmg, r), 1)


func _raw(a: BUnit, d: BUnit, mode: int) -> int:
	return Rules.calc_damage(a, d, true, mode)[1]


func _merit(pid: int, s: int) -> int:
	return Mem.r16(0x508000 + 10 * pid + 2 * s)


func _acc(slot: int, k: int) -> int:
	return Mem.r8(Rules.ACC + slot * 4 + k)


func run() -> void:
	Game.autoplay = true
	Game.main = self
	ui = GameUI.new()
	add_child(ui)
	Game.new_game_state()
	st = BattleStage.new()
	add_child(st)
	stage = st
	await get_tree().process_frame
	st.view.load_map(0)
	st.field_ready = true
	_ev(4066, 0)
	_ev(4077, 2)
	_ev(4018, 1)
	_ev(4017, 0)
	_ev(4087, 0)
	_ev(4079, 0)
	_ev(4074, 0)
	_ev(4030, 1023)
	_ev(4059, 0)
	Mem.w8(0x501bd2, 0)
	var act := st.actions

	# ---- 1. one blow and the counter: hit 90 % (accumulator +10), critical 2 and double 2 never reach 100
	var u := _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	var a: BUnit = u[0]
	var d: BUnit = u[1]
	_check(Rules.phys_hit_rate(a, d) == 90 and Rules.crit_rate(a, d) == 2 and Rules.double_rate(a, d) == 2,
		"rates: hit 90, critical 2, double 2 (equal 爆发 / 士气)")
	var seed := Mem.r32(Rules.SEED)
	var amax := a.hp
	var dmax := d.hp
	var d1 := mini(_spread(_raw(a, d, 0)), dmax)
	var d2 := mini(_spread(_raw(d, a, 1)), amax)
	Rules.srand(seed)
	await act.attack_command(a, d)
	_check(d.hp == dmax - d1, "A's blow: D loses %d (got %d)" % [d1, dmax - d.hp])
	_check(a.hp == amax - d2, "D's counter (mode 1, ×3/4 inside CalcDamage): A loses %d (got %d)" % [d2, amax - a.hp])
	_check(_raw(d, a, 1) == maxi(_raw(d, a, 0) * 3 >> 2, 1), "counter damage = ¾ of a first strike")
	_check(_acc(60, 1) == 10 and _acc(0, 1) == 10, "hit accumulators of both targets: +10 each")
	_check(_acc(0, 2) == 2 and _acc(0, 0) == 2, "A: one critical roll and one double roll (+2 each)")
	_check(_acc(60, 2) == 2 and _acc(60, 0) == 0, "D: a critical roll, no double roll during the counter")
	_check(a.person.exp == 4, "A's EXP: 2·clamp(18 − 20, −1, 47) + 6 = 4 (got %d)" % a.person.exp)
	_check(Mem.r8(Mem.SP + DPID) == maxi(d1 / 2, 1) and Mem.r8(Mem.SP + APID) == maxi(d2 / 4, 1),
		"SP from damage: enemy ½, player ¼")
	_check(Mem.r8(Rules.HITS + 60) == 1 and Mem.r8(Rules.HITS) == 1, "hit counters 0x508a00 + 1 each")
	_check(_merit(APID, 0) == 1 and _merit(APID, 1) == 1 and _merit(APID, 3) == 0,
		"功勋: A +1 攻击 (its strike), +1 防御 (struck by the counter)")
	_check(a.flags & 6 == 6 and Mem.r8(BattleActions.LAST_ACTION) == 1 and Mem.r32(Rules.COUNTER_DEPTH) == 0,
		"A has acted, last action 1, counter depth back to 0")
	_check(act.was_target(a) and Mem.r8(Rules.COMBAT) == 60, "combat object: the counter's attacker D, target A")

	# ---- 2. a second strike: A's 爆发 ≥ 3·D's → hit 100 (no roll), double 100; D's counter hits at 30 %
	u = _field([80, 60, 50, 180, 60], [70, 60, 50, 60, 60])
	a = u[0]
	d = u[1]
	_check(Rules.phys_hit_rate(a, d) == 100 and Rules.double_rate(a, d) == 100 and Rules.phys_hit_rate(d, a) == 30,
		"rates: A hit 100, double 100; D hit 30")
	seed = Mem.r32(Rules.SEED)
	amax = a.hp
	dmax = d.hp
	d1 = mini(_spread(_raw(a, d, 0)), dmax)
	var d1b := mini(_spread(_raw(a, d, 2)), dmax - d1)
	d2 = mini(_spread(_raw(d, a, 1)), amax)
	Rules.srand(seed)
	await act.attack_command(a, d)
	_check(d.hp == dmax - d1 - d1b, "two strikes (the second in mode 2): D loses %d + %d (got %d)" % [d1, d1b,
		dmax - d.hp])
	_check(a.hp == amax - d2, "the counter after both strikes: A loses %d (got %d)" % [d2, amax - a.hp])
	_check(_acc(0, 1) == 70, "D's 30 % hit: A's accumulator 70")
	_check(Mem.r8(Rules.HITS + 60) == 2, "two strikes counted on D")
	_check(_merit(APID, 0) == 2 and _merit(APID, 3) == 1 and _merit(APID, 1) == 1,
		"功勋: +1 攻击 per strike, +1 爆发 for the second, +1 防御 for the counter")
	_check(a.person.exp == 4, "EXP is the maximum over strikes: 4")

	# ---- 3. a kill with a weapon: kill EXP, kill count, weapon EXP, level-up, 功勋 in every stat, no counter
	u = _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	a = u[0]
	d = u[1]
	var pa := a.person
	Mem.w8(pa.base + 0x2e, 0)       # 短剑, level 1
	Mem.w8(pa.base + 0x2f, 1)
	Mem.w8(pa.base + 0x30, 0)
	Mem.w8(pa.base + 0x31, 70)      # 皮铠, level 1
	Mem.w8(pa.base + 0x32, 1)
	Mem.w8(pa.base + 0x33, 0)
	pa.exp = 90
	var kills := pa.kills
	d.hp = 1
	amax = a.hp
	await act.attack_command(a, d)
	_check(d.hp == 0 and a.hp == amax, "D falls, no counter")
	_check(pa.level == 21 and pa.exp == 10, "EXP 90 + 64/(2+2) + 4 = 110 → level 21, EXP 10 (got L%d E%d)" % [
		pa.level, pa.exp])
	_check(pa.kills == kills + 1, "kill count + 1")
	_check(Mem.r8(pa.base + 0x30) == 2, "weapon EXP 3 − 1 (lower-level target) = 2 (got %d)" % Mem.r8(pa.base + 0x30))
	_check(Mem.r8(pa.base + 0x33) == 0, "armour EXP: not struck")
	_check(_merit(APID, 0) == 2 and _merit(APID, 1) == 1 and _merit(APID, 2) == 1 and _merit(APID, 4) == 1,
		"功勋 of a kill: +1 in all five (攻击 +1 more for the strike)")

	# ---- 4. armour EXP of a struck player unit: 4, 3 against a lower-level attacker
	u = _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	a = u[0]
	d = u[1]
	Mem.w8(pa.base + 0x31, 70)
	Mem.w8(pa.base + 0x32, 1)
	Mem.w8(pa.base + 0x33, 0)
	d.ai = 1
	await act.attack_command(d, a)
	_check(Mem.r8(pa.base + 0x33) == 3, "armour EXP 3 (the attacker's level 18 < 20) (got %d)" % Mem.r8(pa.base + 0x33))
	_check(a.person.exp == 4 and d.flags & 6 == 6, "A's counter is an attack: EXP 4; D has acted")

	# ---- 5. the AI's 重击 (必杀 0): hit 100, critical +50 %, no counter, SP spent, last action 5
	u = _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	a = u[0]
	d = u[1]
	Mem.w8(Mem.SP + DPID, 100)
	seed = Mem.r32(Rules.SEED)
	amax = a.hp
	var raw := _raw(d, a, 0)
	var base := mini(_spread(raw), amax)
	var exp_dmg := mini(base + Rules.pct(50, base), amax)
	Rules.srand(seed)
	Mem.w8(Rules.CUR_UNIT, d.slot)
	Rules.set_attack_mode(2, 0)
	await act.bisha_attack(d, a)
	_check(a.hp == amax - exp_dmg, "重击: (spread %d) + 50 %% = %d (got %d)" % [base, exp_dmg, amax - a.hp])
	_check(Mem.r8(Mem.SP + DPID) == 0, "SP 100 − cost 100 = 0")
	_check(Rules.attack_mode() == 0 and Mem.r8(BattleActions.LAST_ACTION) == 5 and d.flags & 6 == 6,
		"mode word cleared, last action 5, D has acted")
	_check(_acc(60, 0) == 2 and _acc(0, 1) == 0, "必杀: a double roll (+2), no hit roll, no counter")

	# ---- 6. consumables
	u = _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	a = u[0]
	amax = a.hp
	Mem.w8(BattleActions.BAG_COUNT + 190, 2)
	Mem.w8(BattleActions.BAG_COUNT + 172, 1)
	a.hp = amax - 100
	_check(BattleActions.battle_items().has(190) and BattleActions.item_handler(190) == 0, "补血豆 listed, handler 0")
	_check(await act.use_item(a, 190, a) and a.hp == amax - 20 and BattleActions.bag_count(190) == 1,
		"补血豆: +80 HP, one used")
	_check(await act.use_item(a, 172, a) and a.hp == amax and BattleActions.bag_count(172) == 1,
		"预制菜: +min(50, missing 20); flags bit 1 → not used up")
	a.hp = 1
	_check(await act.use_item(a, 192, a) and a.hp == amax, "仙桃 (value 0xff): all HP")
	_check(not act.item_usable(195, a, 1), "解毒散 needs 中毒 (menu check)")
	a.inflict(BUnit.ST_POISON)
	_check(act.item_usable(195, a, 1) and await act.use_item(a, 195, a) and not a.poisoned(), "解毒散 cures 中毒")
	var w0 := pa.get_stat_word(0)
	var r0 := pa.get_raw(0)
	_check(await act.use_item(a, 161, a) and pa.get_stat_word(0) == w0 + 2 and pa.get_raw(0) == mini(r0 + 2, 110)
		and a.buff(0) == 6, "武勇果: 攻击 +2, raw +2, buff 3 → 6")
	var lv := pa.level
	pa.exp = 10
	a.hp = 1
	_check(await act.use_item(a, 166, a) and pa.level == lv + 2 and pa.exp == 60 and a.hp == a.max_hp(),
		"经验果: +250 EXP → two levels, EXP 60, HP refilled")
	Mem.w8(Mem.SP + APID, 240)
	_check(await act.use_item(a, 167, a) and Mem.r8(Mem.SP + APID) == 255, "SP item: +min(20, 255 − 240)")
	pa.cls = 0
	pa.level = 15
	_check(act.item_usable(160, a, 1) and await act.use_item(a, 160, a) and pa.cls == 1, "印绶: class 0 → 1 at level 15")
	_check(not act.item_usable(160, a, 1) or pa.level >= 30, "印绶: the next tier needs level 30")

	# ---- 7. movement, 围攻, presentation calls
	u = _field([80, 60, 50, 60, 60], [70, 60, 50, 60, 60])
	a = u[0]
	d = u[1]
	var path: Array[Vector2i] = [Vector2i(5, 6), Vector2i(5, 7)]
	_check(await act.move_unit(a, path) and a.pos == Vector2i(5, 7) and a.dir == 2, "walk two cells down")
	_check(not act.can_siege(a) and not await act.siege_command(a, d), "围攻: no family qualifies (row 7 = 1)")
	for k in 13:
		await act.unit_pose(a, k, 1, 1)
	await act.retreat_animation(d, false, false)
	await act.retreat_animation(d, true, false)
	await act.retreat_animation(d, false, true)
	_check(true, "unit actions 0..12 and the three retreat kinds run")

	print("t_combat: PASS" if ok else "t_combat: FAILED")
