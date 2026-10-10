extends Node
## BattleStrategy / EffectPlayer checks (docs/battle.md §2–3, docs/skills.md §3.4 / §5.2): hit rates by MgHit code,
## strategy damage and heals (replayed from the same RNG seed), result codes (buffs, status counters), MP cost with
## 节约MP, every non-blank strategy cast once on a small field, the nine 军师技 and the auras. Headless, autoplay.
##   tools/gtest.sh t_strat66
## Prints "t_strat66: PASS" at the end.

var ui: GameUI
var st: BattleStage
var stage = null
var ok := true

const CASTER := Vector2i(5, 5)
const ALLY := Vector2i(5, 6)
const FOE := Vector2i(6, 5)
const FOE2 := Vector2i(7, 5)
const EMPTY := Vector2i(4, 5)
## the non-blank strategies (docs/battle.md §2.1)
const STRATS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26,
	27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54,
	55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 83, 84, 85, 86, 89,
	94, 95, 96, 97, 100, 136, 137, 138, 140, 141, 142, 143]


func _check(cond: bool, what: String) -> void:
	if not cond:
		ok = false
		print("t_strat66: FAIL ", what)
	else:
		print("t_strat66: ok   ", what)


func _ev(n: int, v: int) -> void:
	Mem.w32(Mem.EV + 4 * n, v)


func _person(pid: int, cls: int, lv: int, stats: Array) -> void:
	var p := Game.person(pid)
	p.cls = cls
	p.level = lv
	for i in 5:
		p.set_stat_word(i, stats[i])
	p.weapon = -1
	p.armor = -1
	p.accessory = -1


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


## A fresh field: caster (slot 0), an ally below it (slot 1), two enemies to its right (slots 60, 61), clear
## weather, no terrain objects.
func _field() -> Array:
	for u in st.units:
		Mem.fill(u.addr, Mem.UNIT_SIZE, 0)
		Mem.w32(u.addr, 0xffff)
		Mem.w8(u.addr + 4, u.slot)
		Mem.w16(u.addr + 6, 0xffff)
	Mem.fill(Mem.MAP_BUF + 0x640, 20 * 20, 28)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)
	Mem.fill(Rules.ACC, 1000, 0)
	Mem.w8(Rules.B + 0x11, 0)
	Mem.w8(Rules.B + 4, 0)
	Mem.w8(0x501ae1, 0)
	Mem.fill(0x501ae2, 0x1e, 0xff)
	Mem.fill(0x501ad8 + 60, 190, 0)     # 反間計 timers (slots ≥ 60; lower slots overlap 0x501ae1..)
	Mem.fill(0x501b00, 20, 0)           # 精进 timers
	Mem.fill(0x4b3d21, 0x4e2, 0xff)
	Mem.fill(BattleStage.DEPLOY, 250 * 16, 0xff)
	st.terrain_changes.clear()
	for c in st.view.marks.keys():
		st.view.marks.erase(c)
	var c := _unit(0, 400, 0, CASTER)
	var a := _unit(1, 401, 0, ALLY)
	var f := _unit(60, 402, 2, FOE)
	var g := _unit(61, 403, 2, FOE2)
	c.mp = 999
	Mem.w32(c.addr + 0x14, 999)
	st.refresh_units()
	return [c, a, f, g]


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
	_ev(4018, 0)
	_ev(4017, 0)
	_ev(4087, 0)
	_ev(4062, 0)
	_person(400, 24, 20, [80, 60, 120, 70, 90])
	_person(401, 0, 15, [90, 80, 60, 60, 70])
	_person(402, 6, 18, [85, 70, 70, 60, 60])
	_person(403, 6, 18, [85, 70, 70, 60, 60])
	Game.gold = 5000
	_check(Mem.r8(0x4736e8 + 1) == 0x46 and Rules.mg(Rules.MG_ID, 54) == 12, "exe tables mapped (summon flags 0x46, 八阵图 MgID 12)")
	await _hit_rates()
	await _damage_and_heal()
	await _codes()
	await _mp_cost()
	await _every_strategy()
	await _specials()
	await _family_specials()
	await _auras()
	await _anim_player()
	print("t_strat66: ", "PASS" if ok else "FAIL")


# ------------------------------------------------------------------ hit rate by MgHit code (0x43b730)
func _hit_rates() -> void:
	var f := _field()
	var c: BUnit = f[0]
	var t: BUnit = f[2]
	var a: BUnit = f[1]
	var p1 := Rules.stat_pair(c, 2, t, 2, false)
	var p2 := Rules.stat_pair(c, 4, t, 4, false)
	var base := Rules.hit_curve(p1[0] + p2[0], p1[1] + p2[1])
	_check(Rules.strat_hit_rate(c, t, 0) == mini(base, 100), "灼热 MgHit 2: the curve %d" % base)
	_check(Rules.strat_hit_rate(c, t, 1) == base * 90 / 100, "烈火 MgHit 90: %d · 90 %%" % base)
	_check(Rules.strat_hit_rate(c, t, 10) == base * 34 / 100, "海啸 MgHit 3: · 34 %% (not slot 0, not the leader)")
	Mem.w32(t.addr, 100)
	_check(Rules.strat_hit_rate(c, t, 53) == 0, "反間計 on a person < 210: 0")
	Mem.w32(t.addr, 402)
	_check(Rules.strat_hit_rate(c, a, 63) == 100, "觉醒 MgHit 1: 100")
	t.inflict(BUnit.ST_PARALYSIS)
	_check(Rules.strat_hit_rate(c, t, 1) == 100 and Rules.strat_hit_rate(c, t, 10) == base * 34 / 100, "麻痹: 100 except 海啸 / 暈眩 / 反間計")


# ------------------------------------------------------------------ damage and heal through the cast, replayed
func _damage_and_heal() -> void:
	var f := _field()
	var c: BUnit = f[0]
	var t: BUnit = f[2]
	t.inflict(BUnit.ST_PARALYSIS)
	# deterministic part: flag 1 = no variance / critical
	var p := Rules.stat_pair(c, 2, t, 2, true)
	var b := c.level() + 25
	var d0: int = b + (p[0] - p[1]) / 5 if p[0] >= p[1] else Rules.sat_sub(b, (p[1] - p[0]) / 5)
	d0 = d0 * 70 / 100
	d0 = d0 * Rules.fam_attr(6, t.family()) / 100
	_check(Rules.strat_damage(c, t, 46, 1) == mini(d0, t.hp), "毒烟 flag 1: (Lv + 25 + Δ精神/5)·70 %%·family %% = %d" % d0)
	# 灼热 cast vs the same draws replayed
	Rules.srand(1234)
	Mem.w8(Rules.STRAT_CTX + 1, 0)
	Mem.w8(Rules.STRAT_CTX + 0xc, 60)
	Mem.w8(Rules.STRAT_CTX + 0xd, 60)
	var want := Rules.strat_damage(c, t, 0, 0)
	var hp0 := t.hp
	var mp0 := c.mp
	Rules.srand(1234)
	Mem.fill(Rules.ACC, 1000, 0)
	var done: bool = await st.strategy.cast(0, c, FOE)
	_check(done and hp0 - t.hp == want, "灼热 cast: HP −%d (replayed %d)" % [hp0 - t.hp, want])
	_check(mp0 - c.mp == Rules.mp_cost(c, 0), "灼热 cast: MP −%d" % Rules.mp_cost(c, 0))
	_check((c.flags & 6) == 6 and Mem.r8(BattleStage.LAST_ACTION) == 2, "caster acted, last action 2")
	# 小補給 / 大補給 heal replayed
	f = _field()
	c = f[0]
	var a: BUnit = f[1]
	a.hp = 10
	Rules.srand(99)
	var h := Rules.heal_amount(a, 55, c, false)
	var v := Rules.unit_stat(c, 2, 0) * Rules.tile_effect(c, false) / 100
	_check(h >= v / 10 + 40 and h <= v / 10 + 50, "小補給: 精神·地形 / 10 + 40 (+ rand(11)) = %d" % h)
	a.hp = 10
	Rules.srand(99)
	await st.strategy.cast(55, c, ALLY)
	_check(a.hp == 10 + h, "小補給 cast heals %d" % (a.hp - 10))
	a.hp = 10
	a.inflict(BUnit.ST_POISON)
	_check(Rules.heal_amount(a, 56, c, true) == (v / 2 + 70) >> 1, "大補給 on a poisoned unit: (精神 / 2 + 70) / 2")


# ------------------------------------------------------------------ result codes
func _codes() -> void:
	var f := _field()
	var c: BUnit = f[0]
	var t: BUnit = f[2]
	var bs := st.strategy
	t.set_buff(1, 3)
	bs._buff_change(0x1d, t)
	_check(t.buff(1) == 0, "防御 down from 3 → 0")
	bs._buff_change(0x37, t)
	_check(t.buff(1) == 3, "防御 up from 0 → 3")
	bs._buff_change(0x37, t)
	_check(t.buff(1) == 6, "防御 up from 3 → 6")
	bs._buff_change(0x30, t)
	_check(t.buff(5) == 6, "move up → 6")
	bs._buff_change(0x35, t)
	var st_a := Rules.attack_buff_stats(t)
	_check(t.buff(st_a[0]) == 6, "攻击 up reaches stat %s by the attack type" % [st_a])
	# status counters through casts on a paralysed target (sure hits)
	t.status = 0
	t.inflict(BUnit.ST_PARALYSIS)
	var hp0 := t.hp
	var d := Rules.strat_damage(c, t, 46, 1)
	await st.strategy.cast(46, c, FOE)
	_check((t.status & 0xc0) == 0xc0 and hp0 - t.hp == d, "毒烟: 中毒 counter 3, HP −%d" % d)
	await st.strategy.cast(50, c, FOE)
	_check((t.status & 0x0c) == 0x08, "禁咒: counter 2")
	await st.strategy.cast(44, c, FOE)
	_check((t.status & 0x30) == 0x10, "谎报: 混乱 counter 1")
	await st.strategy.cast(35, c, FOE)
	_check(t.buff(st_a[0]) == 3, "压迫 on a raised 攻击: 6 → 3")
	await st.strategy.cast(35, c, FOE)
	_check(t.buff(st_a[0]) == 0, "压迫 again: 3 → 0")
	var a: BUnit = f[1]
	a.status = 0x10 | 0xc0
	await st.strategy.cast(63, c, ALLY)
	_check(a.status == 0, "觉醒 cures")
	await st.strategy.cast(65, c, ALLY)
	_check(a.buff(Rules.attack_buff_stats(a)[0]) == 6, "奋起: 攻击 up")
	a.flags = 6
	await st.strategy.cast(89, c, ALLY)
	_check((a.flags & 6) == 0, "回归: the ally may act again")


# ------------------------------------------------------------------ MP cost with 节约MP (sid 46)
func _mp_cost() -> void:
	var f := _field()
	var c: BUnit = f[0]
	_check(Rules.mp_cost(c, 3) == 20, "火龙 MP 20")
	Effects.added_set(c.pid, 0x2e, 50, 100, true)
	_check(Rules.mp_cost(c, 3) == 10, "节约MP 50: MP 10")
	var t: BUnit = f[2]
	t.inflict(BUnit.ST_PARALYSIS)
	var mp0 := c.mp
	await st.strategy.cast(3, c, FOE)
	_check(mp0 - c.mp == 10, "火龙 cast with 节约MP spends 10")
	Effects.added_set(c.pid, 0x2e, 0, 0, true)


# ------------------------------------------------------------------ every non-blank strategy once
func _every_strategy() -> void:
	var failed := []
	for s in STRATS:
		var f := _field()
		var c: BUnit = f[0]
		var a: BUnit = f[1]
		a.hp = 1
		a.flags = 6 if s == 89 else 0
		for i in [2, 3]:
			var e: BUnit = f[i]
			e.inflict(BUnit.ST_PARALYSIS)
		Effects.added_set(c.pid, 0x50, 0x80, 100, true)      # 学会策略-四神 ≥ 0x80
		var cell := CASTER
		match st.strategy.pick_mode(s):
			2: cell = FOE
			3: cell = ALLY
			4: cell = EMPTY
		var why := Rules.situation(s, c)
		var done: bool = await st.strategy.cast(s, c, cell)
		var want := Rules.mg(Rules.MG_ID, s) not in [31, 35]     # 疾行 / 瞬移 need the player's move
		print("t_strat66:      cast %3d %s → %s %s" % [s, Rules.strat(s).get("name", "?"), done, why])
		if done != want:
			failed.append(s)
	_check(failed.is_empty(), "every non-blank strategy performed (but 疾行 / 瞬移 under autoplay): %s" % [failed])


# ------------------------------------------------------------------ handler specifics
func _specials() -> void:
	var f := _field()
	var c: BUnit = f[0]
	var a: BUnit = f[1]
	var t: BUnit = f[2]
	# weather: 豪雨 picks the rain phase of the climate row
	await st.strategy.cast(136, c, CASTER)
	_check(Rules.weather() >= 2, "豪雨 → weather %d" % Rules.weather())
	await st.strategy.cast(137, c, CASTER)
	_check(Rules.weather() == 0, "晴明 → clear")
	# 移形换影
	await st.strategy.cast(76, c, ALLY)
	_check(c.pos == ALLY and a.pos == CASTER and Rules.slot_at(ALLY) == 0 and Rules.slot_at(CASTER) == 1, "移形换影 swaps")
	# 纵火 / 修筑
	f = _field()
	c = f[0]
	await st.strategy.cast(94, c, EMPTY)
	_check(Rules.raw_terrain(EMPTY) == 0x1a and Mem.r8(0x501ae1) == 1 and Mem.r8(0x501ae4) == 2, "纵火: fire terrain, object timer 2")
	st.strategy.remove_map_object(EMPTY)
	_check(Rules.raw_terrain(EMPTY) == 28, "object removed: terrain back")
	var g0 := Game.gold
	await st.strategy.cast(95, c, EMPTY + Vector2i(0, -1))
	_check(Game.gold == g0 - 1000 and Rules.raw_terrain(EMPTY + Vector2i(0, -1)) == 0x14, "修筑: 鹿砦, 1000 gold")
	# 召唤
	f = _field()
	c = f[0]
	await st.strategy.cast(97, c, CASTER)
	var sm := st.units[20]
	_check(sm.state == 2 and sm.pid == 0x35c and sm.kind == 1 and (absi(sm.pos.x - 5) + absi(sm.pos.y - 5)) <= 2, "召喚毒蠍: person 0x35c as a friend next to the caster at %s" % sm.pos)
	# 反間計 on a person ≥ 210 (EV 4078 = 0)
	f = _field()
	c = f[0]
	t = f[2]
	Mem.w32(t.addr, 0x300)
	var hit := false
	for k in 8:
		Rules.srand(77 + k)
		t.kind = 2
		t.ai = 1
		await st.strategy.cast(53, c, FOE)
		if t.kind == 5:
			hit = true
			break
	_check(hit and t.ai == 7 and Mem.r8(0x501ad8 + 60) == 2, "反間計: enemy controlled, timer 2")
	# 冥想
	f = _field()
	c = f[0]
	c.mp = 0
	var hp0 := c.hp
	await st.strategy.cast(86, c, CASTER)
	_check(c.hp == hp0 - mini(hp0 - 1, 50) and c.mp == mini(25 if hp0 >= 51 else (hp0 - 1) / 2, c.max_mp()), "冥想: HP −%d, MP +%d" % [hp0 - c.hp, c.mp])


# ------------------------------------------------------------------ 军师技
func _family_specials() -> void:
	var cls_of := {1: 27, 2: 78, 3: 51, 4: 30, 5: 24, 6: 69, 7: 0, 8: 71, 9: 48}
	for a8 in range(1, 10):
		var f := _field()
		var c: BUnit = f[0]
		var a: BUnit = f[1]
		var t: BUnit = f[2]
		Game.person(400).cls = cls_of[a8]
		c.hp = c.max_hp()
		Mem.w8(Mem.SP + 400, 255)
		a.hp = 1
		a.status = 0xc0
		a.flags = 6
		_check(Rules.fam_attr(8, c.family()) == a8, "class %d has 军师技 %d" % [cls_of[a8], a8])
		var done: bool = await st.strategy.family_special(c)
		var name := str(Rules.skill(79 + a8).get("name", "?"))
		match a8:
			1: _check(done and a.hp > 1 and a.status == 0, "重生 heals and cures")
			2: _check(done and a.buff(0) == 6 and a.buff(4) == 6, "歷精圖治: buffs 6")
			3: _check(done and t.buff(0) == 0 and t.buff(4) == 0, "八陣圖: enemy buffs 0")
			4: _check(done and (t.status & 0xcd) == 0xc9, "巫蠱: 麻痹 禁咒 中毒 (status %x)" % t.status)
			5: _check(done and a.buff(Rules.attack_buff_stats(a)[0]) == 6, "鼓舞: 攻击 up")
			6: _check(done and t.buff(Rules.attack_buff_stats(t)[0]) == 0, "賣慘: 攻击 down")
			7: _check(done and a.hp > 1 and a.buff(5) == 6, "濟世: heal, move 6")
			8: _check(done and a.status == 0 and a.buff(0) == 6, "超度: own camp cured and raised")
			9: _check(done and (a.flags & 6) == 0, "再戰: the ally may act again")
		_check((c.flags & 6) == 6 and Mem.r8(BattleStage.LAST_ACTION) == 5 and Mem.r8(Mem.SP + 400) < 255, "%s: acted, last action 5, SP spent" % name)
	Game.person(400).cls = 24


# ------------------------------------------------------------------ auras
func _auras() -> void:
	var f := _field()
	var c: BUnit = f[0]
	var a: BUnit = f[1]
	var t: BUnit = f[2]
	a.hp = 1
	Effects.added_set(c.pid, 0x65, 20, 100, true)
	Effects.added_set(c.pid, 0x97, 1, 100, true)
	Effects.added_set(c.pid, 0x68, 10, 100, true)
	var thp := t.hp
	await st.strategy.turn_auras(c)
	_check(a.hp == 1 + a.max_hp() * 20 / 100, "HP光环 20 %%: +%d" % (a.hp - 1))
	_check(a.buff(0) == 6 and c.buff(0) == 3, "攻击光环: the neighbour's 攻击 6, not the owner's")
	_check(thp - t.hp == maxi(t.max_hp() * 10 / 100, 1), "诅咒光环 10 %% on the enemy")
	for sid in [0x65, 0x97, 0x68]:
		Effects.added_set(c.pid, sid, 0, 0, true)


# ------------------------------------------------------------------ the player
func _anim_player() -> void:
	var a := EffectPlayer.anim_of("xben", 1)
	_check(not a.is_empty() and int(a.get("sound", -1)) == 1, "Meff 1 record, sound 1")
	var hits := [0]
	var played := await EffectPlayer.play("xben", 1, null, [Vector2.ZERO], func() -> void: hits[0] += 1)
	_check(played and hits[0] == 1, "autoplay: no frames, the hit callback once")
	_check(not await EffectPlayer.play("mcall", 99, null, []), "missing Mcall: nothing")
	var cells: Array[Vector2i] = [FOE, Vector2i(19, 19) + Vector2i(40, 40)]
	_check(await st.strategy.script_anim(5, cells, [10, 0], 0x40), "script_anim: on screen → true")
	var off: Array[Vector2i] = [Vector2i(-5, -5)]
	_check(not await st.strategy.script_anim(5, off, [], 0x40), "script_anim: nothing on screen → false")
