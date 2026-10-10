extends Node
## Foundation checks against hand-computed cases of docs/battle.md / docs/skills.md: the effect query, the stat
## pipeline, damage / hit / critical curves, the flood and growth. Prints "t_rules: PASS".

class FakeStage:
	extends RefCounted
	var units: Array[BUnit] = []

	func unit_at(c: Vector2i, _ex: BUnit = null) -> BUnit:
		return Rules.unit_at(c)

	func unit_of_person(pid: int) -> BUnit:
		for u in units:
			if u.pid == pid:
				return u
		return null


var ok := true


func _check(cond: bool, what: String) -> void:
	if not cond:
		ok = false
		print("t_rules: FAIL ", what)
	else:
		print("t_rules: ok   ", what)


func _map(w: int, h: int, t: int) -> void:
	Mem.w8(Mem.MAP_WH, w)
	Mem.w8(Mem.MAP_WH + 1, h)
	Mem.fill(Mem.MAP_BUF + 0x640, w * h, t)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)


func _unit(st: FakeStage, slot: int, pid: int, kind: int, c: Vector2i) -> BUnit:
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
	return u


func _person(pid: int, cls: int, lv: int, stats: Array) -> Person:
	var p := Game.person(pid)
	p.cls = cls
	p.level = lv
	for i in 5:
		p.set_stat_word(i, stats[i])
	p.weapon = -1
	p.armor = -1
	p.accessory = -1
	return p


func run() -> void:
	Game.new_game_state()
	var st := FakeStage.new()
	for s in Mem.UNIT_SLOTS:
		st.units.append(BUnit.at(s))
	Effects.battle = st
	_map(20, 20, 0)

	# ---- curves
	_check(Rules.hit_curve(100, 80) == 92, "hit curve a ≥ d: 90 + 20·10/80 = 92")
	_check(Rules.hit_curve(50, 80) == 67, "hit curve a ≥ d/2: 60 + 10·30/40 = 67")
	_check(Rules.hit_curve(20, 80) == 30, "hit curve low: 30")
	_check(Rules.hit_curve(160, 80) == 100, "hit curve a ≥ 2d: 100")
	_check(Rules.crit_curve(50, 160) == 100, "crit curve a ≥ 3d")
	_check(Rules.crit_curve(50, 120) == 52, "crit curve 2d < a: 20 + 20·80/50 = 52")
	_check(Rules.crit_curve(50, 60) == 5, "crit curve d ≤ a: 2 + 10·18/50 = 5")

	# ---- RNG: MSVC LCG from seed 1
	Rules.srand(1)
	var r0 := Rules.rand(0x8000)
	_check(r0 == 16838, "LCG first value from seed 1 = 16838 (got %d)" % r0)

	# ---- damage: 步兵 (class 3, family 1) lv 10 攻 100 vs 弓兵 (class 6, family 2) 防 80 on 平原
	_person(500, 3, 10, [100, 50, 50, 50, 50])
	_person(501, 6, 10, [50, 80, 50, 50, 50])
	var a := _unit(st, 0, 500, 0, Vector2i(5, 5))
	var d := _unit(st, 60, 501, 2, Vector2i(6, 5))
	var sp := Rules.stat_pair(a, 0, d, 1, false)
	_check(sp[0] == 100 and sp[1] == 80, "stat pair 100 / 80 (got %s)" % [sp])
	var dm: Array = Rules.calc_damage(a, d, true, 0)
	_check(dm[0] == 58, "damage (10 + 25 + 20/5)·150 pct = 58 (got %d)" % dm[0])
	dm = Rules.calc_damage(a, d, true, 1)
	_check(dm[0] == 43, "counter ×3/4 = 43 (got %d)" % dm[0])
	# buff level 6 on 攻击: ×12/10 → VA 120 → 10+25+40/5 = 43 → ×1.5 = 64
	a.set_buff(0, 6)
	dm = Rules.calc_damage(a, d, true, 0)
	_check(dm[0] == 64, "攻击 buff 6 → 64 (got %d)" % dm[0])
	a.set_buff(0, 3)
	# 爆发 50 vs 50 → hit 90 + 0 = 90
	_check(Rules.phys_hit_rate(a, d) == 90, "physical hit rate 爆发 equal → 90 (got %d)" % Rules.phys_hit_rate(a, d))
	# paralysed defender → 100
	d.inflict(BUnit.ST_PARALYSIS)
	_check(d.status == 1 and Rules.phys_hit_rate(a, d) == 100, "麻痹 → 100, counter 1")
	d.inflict(BUnit.ST_POISON)
	_check(d.status == 0xc1 and d.poisoned(), "中毒 counter 3 ORed in")
	d.cure(BUnit.ST_ALL)
	_check(d.status == 0, "cure all")

	# ---- effect query: personal talent row 20 (吸血攻击), person slot 0 value 30
	var row := Mem.r32(Effects.ROWS_PTR) + 20 * 16
	Mem.w16(row, 500)
	Mem.w8(row + 2, 30)
	_check(a.eff(20, 0x65, 1, 0) == 30, "personal 吸血攻击 30")
	# class entry for family 1 tier 0 (class 3) value 40: mode 1 max → 40, mode 0 sum → 70
	Mem.w8(row + 0xc, 3)
	Mem.w8(row + 0xd, 40)
	_check(a.eff(20, 0x65, 1, 0) == 40, "max(personal 30, class 40) = 40")
	_check(a.eff(20, 0x65, 0, 0) == 70, "sum = 70")
	# mode 2: first non-zero = personal 30; the class value 40 does not override
	_check(a.eff(20, 0x65, 2, 0) == 30, "mode 2 first non-zero = 30")
	# class inheritance: class 4 (tier 1 of family 1) also matches a class-3 entry
	Game.person(500).cls = 4
	_check(a.eff(20, 0x65, 1, 0) == 40, "class entry inherited upward")
	Game.person(500).cls = 3
	# 特效屏蔽 (89) on an adjacent enemy blocks everything
	var srow := Mem.r32(Effects.ROWS_PTR) + 89 * 16
	Mem.w16(srow, 501)
	Mem.w8(srow + 2, 1)
	_check(a.eff(20, 0x65, 1, 0) == 0, "adjacent enemy 特效屏蔽 blocks")
	d.pos = Vector2i(8, 5)
	_check(a.eff(20, 0x65, 1, 0) == 40, "not adjacent any more")
	Mem.w16(srow, 0x400)
	# 特效模仿 (88): the unit copies an orthogonal neighbour's value (any side)
	_person(502, 6, 10, [50, 50, 50, 50, 50])
	var c := _unit(st, 1, 502, 0, Vector2i(5, 6))
	var mrow := Mem.r32(Effects.ROWS_PTR) + 88 * 16
	Mem.w16(mrow, 502)
	Mem.w8(mrow + 2, 1)
	_check(c.eff(20, 0x65, 1, 0) == 40, "特效模仿 copies the neighbour's 40 (got %d)" % c.eff(20, 0x65, 1, 0))
	Mem.w16(mrow, 0x400)
	Mem.w16(row, 0x400)
	Mem.w8(row + 0xc, 0xff)
	# 附加技能 stream: insert / update / turns
	Effects.added_set(500, 20, 25, 3, true)
	_check(a.eff(20, 0x65, 1, 0) == 25, "附加技能 25 for 3 turns")
	Effects.added_set(500, 20, 10, 5, false)
	_check(Effects.added_value(500, 20) == 25, "max-merge keeps 25")
	Effects.added_set(501, 20, 7, 1, true)
	_check(Effects.added_value(501, 20) == 7 and Effects.added_value(500, 20) == 25, "second person in the group")
	Effects.added_set(500, 21, 9, 2, true)
	_check(Effects.added_value(500, 21) == 9 and Effects.added_value(501, 20) == 7, "new group appended")

	# ---- item effect values (0x4200f5): 古锭刀 (33) 同仇破甲 sv 15 → sv·(L+1)
	_check(Effects.value_at_level(Game.item(33), 1) == 30, "同仇破甲 Lv1 = 15·2")
	# 黄金铠 (80) eid 0x41 sv 100, kind < 7 → ×1.5 at Lv7
	_check(Effects.value_at_level(Game.item(80), 7) == 150, "×1.5 at level 7")

	# ---- flood: move 4 on open plain = Manhattan diamond (41 cells incl. start)
	for u in st.units:
		if u.state == 2:
			u.state = 0
	var m := _unit(st, 2, 500, 0, Vector2i(10, 10))
	var cells := Movement.move_range(m, 4)
	_check(cells.size() == 41, "flood mv 4 on plain = 41 cells (got %d)" % cells.size())
	# a hostile unit 2 cells east: zone of control stops expansion next to it
	var e2 := _unit(st, 61, 501, 2, Vector2i(12, 10))
	cells = Movement.move_range(m, 4)
	_check(not cells.has(Vector2i(13, 10)) and cells.has(Vector2i(11, 10)) and not cells.has(Vector2i(12, 10)), "ZOC / blocking")
	var path := Movement.path_to(m, Vector2i(10, 7))
	_check(path.size() == 3 and path[-1] == Vector2i(10, 7), "path to (10,7): %s" % [path])
	e2.state = 0

	# ---- fog (tint mode ≥ 2): sight = Manhattan 2 → an enemy 3 cells away is unseen → ×0.8 damage
	Mem.w8(0x501bd2, 30)
	var fa := _unit(st, 3, 500, 0, Vector2i(2, 2))
	var fd := _unit(st, 62, 501, 2, Vector2i(5, 2))
	Rules.vis_update()
	_check(Mem.r8(Rules.VIS + 4 + 2 * 20) & 1 and not (Mem.r8(Rules.VIS + 5 + 2 * 20) & 1), "sight reaches Manhattan 2")
	var dfog: int = Rules.fog(fa, fd, 100)
	fd.pos = Vector2i(4, 2)
	Rules.vis_update()
	var dseen: int = Rules.fog(fa, fd, 100)
	_check(dfog == 80 and dseen == 100, "fog ×80 unseen (%d), seen %d" % [dfog, dseen])
	Mem.w8(0x501bd2, 0)
	fa.state = 0
	fd.state = 0

	# ---- growth: person 0 (群雄, class 0) 攻击: class grade 6 + ability grade(88) 6 → 6 per level
	Game.new_game_state()
	var p0 := Game.person(0)
	var before := p0.get_stat_word(0)
	var g: Array = p0.level_up(1)
	_check(g[0] == 6 and p0.get_stat_word(0) == before + 6 and p0.level == 2, "LevelUp 群雄 攻击 +6 (got %s)" % [g])
	_check(Person.auto_level_at(Game.item(1), 45) == 2, "auto equipment level lv45 → (45%20)/4+1 = 2")

	Effects.battle = null
	print("t_rules: PASS" if ok else "t_rules: FAIL")
