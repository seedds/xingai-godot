extends Node
## AI checks against hand-traced cases of docs/ai.md §2.2 / §4: the action order passes, Prepare's layer A, GoalBonus,
## PhysScore values, the flood order and CellScore's tie rules, the attack-direction choice, the strategy list and
## choice, scripted moves, Arrival, a whole turn; and the decision time. Prints "t_ai: PASS".

var ok := true
var st: BattleStage
var ai: BattleAI


func _check(cond: bool, what: String) -> void:
	if not cond:
		ok = false
		print("t_ai: FAIL ", what)
	else:
		print("t_ai: ok   ", what)


func _ev(n: int, v: int) -> void:
	Mem.w32(Mem.EV + 4 * n, v)


func _map(w: int, h: int, t: int) -> void:
	Mem.w8(Mem.MAP_WH, w)
	Mem.w8(Mem.MAP_WH + 1, h)
	Mem.fill(Mem.MAP_BUF + 0x640, w * h, t)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)


func _clear() -> void:
	for u in st.units:
		if u.state == 2:
			u.state = 0
		Mem.fill(u.addr, Mem.UNIT_SIZE, 0)
		Mem.w32(u.addr, 0xffff)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)


func _person(pid: int, cls: int, lv: int, stats: Array) -> Person:
	var p := Game.person(pid)
	p.cls = cls
	p.level = lv
	for i in 5:
		p.set_stat_word(i, stats[i])
	p.weapon = -1
	p.armor = -1
	p.accessory = -1
	p.sp = 0
	return p


func _unit(slot: int, pid: int, kind: int, c: Vector2i, code := -1) -> BUnit:
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
	u.target = 0xff
	Mem.w16(u.addr + 0x20, 0xffff)
	u.ai = code if code >= 0 else (7 if kind == 0 else 1)
	return u


## The decision of AIAct without the walk and the action (Prepare, then the code's movement mode).
func _decide(u: BUnit) -> void:
	ai.u = u
	ai.W = Rules.map_w()
	ai.H = Rules.map_h()
	ai.forbidden = BattleAI.NO_CELL
	ai.code = u.ai
	ai._sc.clear()
	st.set_current(u)
	Effects.begin_cache()
	ai._prepare()
	var mv := u.move_points()
	match u.ai:
		0, 4: ai._go_target(mv)
		1:
			if ai._active(mv) == 0xff and u.pos == ai.dest:
				ai._hold()
		2: ai._hold()
	Effects.end_cache()


func run() -> void:
	Game.new_game_state()
	st = BattleStage.new()
	for s in Mem.UNIT_SLOTS:
		st.units.append(BUnit.at(s))
	st.actions = BattleActions.new(st)
	st.strategy = BattleStrategy.new(st)
	ai = BattleAI.new(st)
	st.ai = ai
	Effects.battle = st
	_map(20, 20, 0)
	Mem.w8(Rules.B + 0x10, 2)
	Mem.w8(0x500c47, 0)
	_ev(4061, 100)
	_ev(4063, 0)
	_ev(4065, 0)
	_ev(4066, 0)

	_order_cases()
	_phys_cases()
	_strategy_cases()
	_move_cases()
	_display_cases()
	await _turn_case()
	_perf_case()

	Effects.battle = null
	st.free()
	print("t_ai: PASS" if ok else "t_ai: FAILED")


# ------------------------------------------------------------------ action order (§2.2)
func _order_cases() -> void:
	_clear()
	_person(510, 3, 10, [80, 80, 80, 80, 80])     # 轻步兵 (family 1: row 1 = 1, row 5 = 2 武将)
	_person(511, 3, 10, [80, 80, 80, 80, 80])
	_person(512, 6, 10, [80, 80, 80, 80, 80])     # 弓兵 (family 2, ranged)
	_person(513, 9, 10, [80, 80, 80, 80, 80])     # 轻骑兵 (family 3, row 1 = 0)
	_person(514, 3, 10, [80, 80, 80, 80, 80])
	_person(515, 24, 10, [80, 80, 80, 80, 80])    # 策士 (family 8, row 5 = 1 文官)
	_person(516, 27, 10, [80, 80, 80, 80, 80])    # 医师 (family 9: never a pass-3 caster; growth 攻 2 防 2)
	_person(517, 3, 10, [80, 80, 80, 80, 80])
	_person(518, 48, 10, [80, 80, 80, 80, 80])    # 都统 (family 16, 军师技 row 8 = 9)
	var w := _unit(60, 510, 2, Vector2i(1, 1))
	w.hp = w.max_hp() * 2 / 5                      # wounded: HP ≤ MaxHP·2/5
	_unit(61, 511, 2, Vector2i(3, 1))
	Mem.w8(Mem.MAP_BUF + 0x640 + 3 + 1 * 20, 21)   # 村庄 under 61
	_unit(62, 512, 2, Vector2i(5, 1))
	_unit(63, 513, 2, Vector2i(7, 1))
	_unit(64, 514, 2, Vector2i(9, 1))
	_unit(65, 515, 2, Vector2i(11, 1))
	_unit(66, 516, 2, Vector2i(13, 1))
	_unit(67, 517, 2, Vector2i(15, 1))
	Game.person(517).sp = 100                      # SP ≥ EV 4061 → CanSpecial 1
	_unit(68, 518, 2, Vector2i(17, 1))
	Game.person(518).sp = 255                      # ≥ the cost of 军师技 0x58 (255) → CanSpecial 2, family row 8 = 9
	var hidden := _unit(69, 510, 2, Vector2i(1, 3))
	hidden.state = 1
	st.units[59].order = 0x33
	ai.compute_order(false)
	var got := []
	for i in range(60, 70):
		got.append(st.units[i].order)
	# pass 0: 67 → 0 (68 → 0x75); 1: 61 → 1; 2: 60 → 2; 3: 65 → 3; 4 skipped (EV 4063 = 0); 5: 62 → 4;
	# 6: 63 → 5; 7: 64 → 6, 66 → 7; 8: 68 → 8; the hidden unit keeps 0xff
	_check(got == [2, 1, 4, 5, 6, 3, 7, 0, 8, 0xff], "action order, EV 4063 = 0 (got %s)" % [got])
	_ev(4063, 1)
	ai.compute_order(false)
	got = []
	for i in range(60, 70):
		got.append(st.units[i].order)
	# pass 4 (growth 攻 or 防 ≥ 4): 62 → 4, 63 → 5, 64 → 6 in slot order; 医师 (2 / 2) waits for pass 7 → 7
	_check(got == [2, 1, 4, 5, 6, 3, 7, 0, 8, 0xff], "action order, EV 4063 = 1 (got %s)" % [got])
	_ev(4063, 2)
	ai.compute_order(false)
	got = []
	for i in range(60, 70):
		got.append(st.units[i].order)
	# pass 3 at the first unit: table 0x44dccc priority 0 = families 1 and 3 in slot order (63 → 3, 64 → 4),
	# 1 family 8 (65 → 5), 2 family 2 (62 → 6), 4 family 9 (66 → 7); then pass 8: 68 → 8
	_check(got == [2, 1, 6, 3, 4, 5, 7, 0, 8, 0xff], "action order, EV 4063 = 2 custom (got %s)" % [got])
	_ev(4063, 0)
	ai.compute_order(true)
	_check(st.units[59].order == 0x33, "friend phase never writes slot 59")
	Mem.w8(Mem.MAP_BUF + 0x640 + 3 + 1 * 20, 0)


# ------------------------------------------------------------------ Prepare, GoalBonus, PhysScore, CellScore ties
## Enemy 轻步兵 (slot 60, 攻 100, lv 10, move 4) at (5, 5); player 轻步兵 (slot 0, 防 80, HP 78) at (8, 5).
## Attack shape code 1 = the 8 neighbours. Damage preview: 10 + 25 + (100 − 80)/5 = 39 → 39·100/78 = 50;
## PhysScore = 50 + 4 (not the boss) − 1 (in the player's counter range) = 53.
func _setup_duel(code: int) -> Array:
	_clear()
	_person(500, 3, 10, [100, 50, 50, 50, 50])
	_person(501, 3, 10, [50, 80, 50, 50, 50])
	var a := _unit(60, 500, 2, Vector2i(5, 5), code)
	var d := _unit(0, 501, 0, Vector2i(8, 5))
	d.hp = 78
	d.dir = 0
	return [a, d]


func _phys_cases() -> void:
	var ad := _setup_duel(1)
	var a: BUnit = ad[0]
	var d: BUnit = ad[1]
	_check(d.max_hp() >= 78 and Rules.matchup(a, d) == 100, "setup: HP 78 possible, matchup 100")
	ai.u = a
	ai.W = 20
	ai.H = 20
	ai.code = 1
	ai._sc.clear()
	st.set_current(a)
	ai._prepare()
	var marked := []
	for y in 20:
		for x in 20:
			if ai.layer_a[x + y * 20] != 0xff:
				marked.append(Vector2i(x, y))
	_check(marked.size() == 8 and ai.layer_a[7 + 5 * 20] == 0 and ai.layer_a[9 + 6 * 20] == 0,
			"Prepare: layer A = slot 0 on its 8 neighbours")
	_check(ai._best_physical(Vector2i(7, 5)) == 53 and ai.best_phys == 0, "PhysScore 50 + 4 − 1 = 53")
	_check(Mem.r16(Rules.VTILE) == 0xffff, "candidate cell reset")
	_check(ai._best_physical(Vector2i(4, 4)) == 0 and ai.best_phys == 0xff, "no target from (4, 4)")
	a.target = 0
	_check(ai._best_physical(Vector2i(7, 4)) == 53 + 98, "攻击武将 target +98")
	a.target = 0xff
	d.inflict(BUnit.ST_PARALYSIS)
	_check(ai._best_physical(Vector2i(7, 4)) == 61, "麻痹 target +8")
	d.cure(BUnit.ST_ALL)
	# GoalBonus(goal, 20): ring 1 = 10, ring 2 = 9, ring 3 nothing; the goal itself is occupied
	ai._goal_bonus(d.pos, 20)
	var lb := ai.layer_b
	_check(lb[8 + 5 * 20] == 0 and lb[7 + 5 * 20] == 10 and lb[8 + 4 * 20] == 10 and lb[9 + 4 * 20] == 9
			and lb[6 + 5 * 20] == 9 and lb[8 + 2 * 20] == 0 and lb[5 + 5 * 20] == 0, "GoalBonus 20: 10 / 9 / 0")

	# code 1, no target: the attack cells score 53 each; ties keep the first one the flood reaches: (7, 5)
	ad = _setup_duel(1)
	_decide(ad[0])
	_check(ai.dest == Vector2i(7, 5) and ai.best == 53 and ai.choice_strategy == 0xff and ai.choice_target == 0,
			"code 1: first attack cell (7, 5), score 53 (got %s %d)" % [ai.dest, ai.best])
	# code 0 with target 0: +20 GoalBonus (ring 1 = 10) and +98 → 161 on (7, 5), (8, 4), (8, 6); the later wins
	ad = _setup_duel(0)
	(ad[0] as BUnit).target = 0
	_decide(ad[0])
	_check(ai.dest == Vector2i(8, 6) and ai.best == 161, "code 0: the last 161 cell (8, 6) (got %s %d)" % [ai.dest, ai.best])
	# EV 4066 (direction): the player faces up; from below +10 % (42 → 53 + 4 − 1 = 56), from the side +5 % (40 → 54);
	# (7, 6) and (8, 6) score 56, (7, 6) is reached first
	_ev(4066, 1)
	ad = _setup_duel(1)
	_decide(ad[0])
	_check(ai.dest == Vector2i(7, 6) and ai.best == 56, "EV 4066: rear cell (7, 6) 56 (got %s %d)" % [ai.dest, ai.best])
	_ev(4066, 0)
	# out of reach: the enemy approaches (Active: StepToward on the flood from the player's attack cell, then the
	# normal evaluation); far away the best cell is the walked one with the GoalBonus-free score 0 → still moves
	ad = _setup_duel(1)
	(ad[1] as BUnit).pos = Vector2i(16, 5)
	_decide(ad[0])
	_check(ai.dest.x > 5 and ai.dest.x <= 9 and ai.choice_target == 0xff, "approach toward a far target (got %s)" % [ai.dest])
	# hold (code 2) evaluates the own cell only: 1 (own cell, no attack)
	ad = _setup_duel(2)
	_decide(ad[0])
	_check(ai.dest == Vector2i(5, 5) and ai.best == 1, "hold: own cell, score 1")


# ------------------------------------------------------------------ strategies
## Enemy 策士 lv 30 (文官: PhysScore < 75 → 0) at (5, 5) against the player 轻步兵 at (8, 5).
func _strategy_cases() -> void:
	_clear()
	_person(520, 24, 30, [50, 50, 120, 50, 50])
	_person(501, 3, 10, [50, 80, 50, 50, 50])
	var c := _unit(60, 520, 2, Vector2i(5, 5), 1)
	var d := _unit(0, 501, 0, Vector2i(8, 5))
	c.mp = 12
	ai.u = c
	ai.W = 20
	ai.H = 20
	ai._sc.clear()
	ai._build_strat_list()
	# known by class level at lv 30 (strategies.json): 灼热 0, 火阵 2, 浊流 6, 水阵 8, 落石 18, 地阵 20, 小補給 55,
	# 气合 84; record MP ≤ 12 → all of them
	_check(ai.strat_list == [0, 2, 6, 8, 18, 20, 55, 84], "strategy list (got %s)" % [ai.strat_list])
	c.mp = 6
	ai._sc.clear()
	ai._build_strat_list()
	_check(ai.strat_list == [0, 6, 18, 55, 84], "strategy list with MP 6 (got %s)" % [ai.strat_list])
	c.mp = 12
	Rules.srand(7)
	_decide(c)
	var s1 := ai.choice_strategy
	var t1 := ai.choice_target
	var d1 := ai.dest
	var cast_ok := s1 != 0xff and Rules.codes_cells([Rules.strat_range(c, s1), 0xff, 0xff, 0xff], d1).has(d.pos)
	_check(cast_ok and t1 == 0, "文官 chooses a strategy at the player in range (s %d t %d dest %s)" % [s1, t1, d1])
	Rules.srand(7)
	_decide(c)
	_check(ai.choice_strategy == s1 and ai.dest == d1, "same seed, same decision")
	# a wounded ally next to the caster: 小補給 scores 50 (+ nothing) — with the player out of every range
	d.pos = Vector2i(18, 18)
	_person(521, 3, 10, [50, 50, 50, 50, 50])
	var f := _unit(61, 521, 2, Vector2i(5, 6), 1)
	f.hp = f.max_hp() * 2 / 5
	Rules.srand(7)
	_decide(c)
	_check(ai.choice_strategy == 55 and ai.choice_target == 61, "小補給 on the wounded ally (s %d t %d)" % [ai.choice_strategy, ai.choice_target])


# ------------------------------------------------------------------ scripted move, arrival
func _move_cases() -> void:
	_clear()
	_person(500, 3, 10, [100, 50, 50, 50, 50])
	_person(501, 3, 10, [50, 80, 50, 50, 50])
	var a := _unit(60, 500, 2, Vector2i(2, 10), 0)
	_unit(0, 501, 0, Vector2i(18, 2))
	a.flags = 0x80
	a.point = Vector2i(14, 10)
	ai.u = a
	_decide(a)
	_check(ai.dest == Vector2i(14, 10), "scripted move: dest = the goal beyond the move points")


# ------------------------------------------------------------------ 危险区域 / AI仇恨 (§5.6)
func _display_cases() -> void:
	var ad := _setup_duel(1)
	var e: BUnit = ad[0]
	var p: BUnit = ad[1]
	_check(ai.threat(e, p) and Mem.r8(Movement.PROBE) == 0, "threat: the enemy reaches an attack cell of the player")
	p.pos = Vector2i(16, 5)
	_check(not ai.threat(e, p), "threat: player out of reach")
	e.status = 1 << 2                              # 禁咒 counter 1: CellScore answers 1 at the own cell (quirk)
	_check(ai.threat(e, p), "threat: a 1-turn 禁咒 reads as dangerous")
	e.status = 2 << 2
	_check(not ai.threat(e, p), "threat: 禁咒 counter 2 does not")
	e.status = 0
	p.pos = Vector2i(8, 5)
	ai.clear_ai_values()
	# PhysScore(E → player, cell (0, 0)): 50 + 4, (0, 0) is not in the player's range; no strategies
	_check(ai.ai_value(e, p) == 54 and Mem.r8(0x5003a0 + 60) == 54, "AI value 54, cached")
	p.pos = Vector2i(16, 5)
	_check(ai.ai_value(e, p) == 54, "AI value from the cache")
	ai.clear_ai_values()
	_check(ai.ai_value(e, e) == 0, "AI value: same side → 0")
	# a 文官 far away: the strategies are scored against the player whatever the range (given), no physical value
	_person(520, 24, 30, [50, 50, 120, 50, 50])
	var c := _unit(61, 520, 2, Vector2i(1, 18), 1)
	c.mp = 12
	ai.best_strat = 0x77
	var v := ai.ai_value(c, p)
	_check(v > 1 and ai.best_strat == 0x77, "AI value of a far 策士 from its strategies (%d), choice untouched" % v)
	ai.clear_ai_values()


func _turn_case() -> void:
	var ad := _setup_duel(1)
	var a: BUnit = ad[0]
	await ai.act(a)
	_check(a.pos == Vector2i(7, 5) and (a.flags & 6) == 6 and Mem.r8(BattleStage.LAST_ACTION) == 1
			and Mem.r8(Rules.WALKED) == 0, "turn: walks to (7, 5) and attacks (flags 6, last action 1)")
	# Arrival: code 0 without target on its point → code 3
	_clear()
	_person(500, 3, 10, [100, 50, 50, 50, 50])
	_person(501, 3, 10, [50, 80, 50, 50, 50])
	var b := _unit(60, 500, 2, Vector2i(2, 10), 0)
	_unit(0, 501, 0, Vector2i(18, 2))
	b.point = Vector2i(4, 10)
	await ai.act(b)
	_check(b.pos == Vector2i(4, 10) and b.ai == 3, "arrival on the point: code 3 (pos %s code %d)" % [b.pos, b.ai])
	# scripted: walks the whole way, no attack, no flag 2
	_clear()
	_person(500, 3, 10, [100, 50, 50, 50, 50])
	var s := _unit(60, 500, 2, Vector2i(2, 12), 0)
	_unit(0, 501, 0, Vector2i(18, 2))
	s.flags = 0x80
	s.point = Vector2i(14, 12)
	await ai.act(s)
	_check(s.pos == Vector2i(14, 12) and (s.flags & 2) == 0, "scripted move walks to the goal (pos %s)" % [s.pos])


# ------------------------------------------------------------------ decision time
## A 策士 with 8 strategies and a 轻骑兵 (move 6) among 12 player units on a 30 × 30 map.
func _perf_case() -> void:
	_map(30, 30, 0)
	_clear()
	_person(520, 24, 30, [50, 50, 120, 50, 50])
	_person(522, 9, 20, [100, 50, 50, 50, 50])
	_person(501, 3, 10, [50, 80, 50, 50, 50])
	var c := _unit(60, 520, 2, Vector2i(10, 10), 1)
	var k := _unit(61, 522, 2, Vector2i(12, 12), 1)
	for i in 12:
		_unit(i, 501, 0, Vector2i(14 + (i % 4) * 2, 8 + (i / 4) * 3))
	var t0 := Time.get_ticks_usec()
	_decide(c)
	var t1 := Time.get_ticks_usec()
	_decide(k)
	var t2 := Time.get_ticks_usec()
	print("t_ai: decision 策士 (8 strategies) %d ms, 轻骑兵 %d ms" % [(t1 - t0) / 1000, (t2 - t1) / 1000])
	_map(20, 20, 0)
