extends Node
## Timing of the stat pipeline (CalcDamage preview, strategy damage preview, the flood) on a populated plain.

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


func run() -> void:
	Game.new_game_state()
	var st := FakeStage.new()
	for s in Mem.UNIT_SLOTS:
		st.units.append(BUnit.at(s))
	Effects.battle = st
	Mem.w8(Mem.MAP_WH, 30)
	Mem.w8(Mem.MAP_WH + 1, 30)
	Mem.fill(Mem.MAP_BUF + 0x640, 900, 0)
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)
	var n := 0
	for i in 40:
		var slot := i if i < 20 else 60 + i
		var u: BUnit = st.units[slot]
		Mem.w32(u.addr, 200 + i)
		Mem.w8(u.addr + 4, slot)
		u.kind = 0 if i < 20 else 2
		u.state = 2
		u.pos = Vector2i(2 + (i % 10) * 2, 2 + (i / 10) * 3)
		for b in 6:
			u.set_buff(b, 3)
		u.hp = u.max_hp()
		n += 1
	var a: BUnit = st.units[0]
	var d: BUnit = st.units[80]
	var t0 := Time.get_ticks_usec()
	for k in 200:
		Rules.calc_damage(a, d, true, 0)
	var t1 := Time.get_ticks_usec()
	print("t_perf: calc_damage preview %.1f us" % [(t1 - t0) / 200.0])
	Effects.begin_cache()
	t0 = Time.get_ticks_usec()
	for k in 200:
		Rules.calc_damage(a, d, true, 0)
	t1 = Time.get_ticks_usec()
	Effects.end_cache()
	print("t_perf: calc_damage preview, cached queries %.1f us" % [(t1 - t0) / 200.0])
	t0 = Time.get_ticks_usec()
	for k in 200:
		Rules.strat_damage(a, d, 0, 0, true)
	t1 = Time.get_ticks_usec()
	print("t_perf: strat_damage preview %.1f us" % [(t1 - t0) / 200.0])
	t0 = Time.get_ticks_usec()
	for k in 20:
		Movement.move_range(a, 6)
	t1 = Time.get_ticks_usec()
	print("t_perf: flood mv 6 %.1f us" % [(t1 - t0) / 20.0])
	t0 = Time.get_ticks_usec()
	for k in 5:
		Movement.flood(a, a.pos, 0xff, 0, Vector2i(0xff, 0xff), 1)
	t1 = Time.get_ticks_usec()
	print("t_perf: flood mv 255 %.1f us" % [(t1 - t0) / 5.0])
	t0 = Time.get_ticks_usec()
	for k in 1000:
		Effects.query_sources(200, k % 200, 0x40, 1, 0)
	t1 = Time.get_ticks_usec()
	print("t_perf: query_sources %.1f us" % [(t1 - t0) / 1000.0])
	t0 = Time.get_ticks_usec()
	for k in 1000:
		Effects.query(a, k % 200, 0x40, 1, 0)
	t1 = Time.get_ticks_usec()
	print("t_perf: query %.1f us" % [(t1 - t0) / 1000.0])
	t0 = Time.get_ticks_usec()
	for k in 1000:
		Effects.added_value(200, k % 200)
	t1 = Time.get_ticks_usec()
	print("t_perf: added_value %.1f us" % [(t1 - t0) / 1000.0])
	t0 = Time.get_ticks_usec()
	for k in 1000:
		Effects.has_item_effect(200, 0x40)
	t1 = Time.get_ticks_usec()
	print("t_perf: has_item_effect %.1f us" % [(t1 - t0) / 1000.0])
	t0 = Time.get_ticks_usec()
	for k in 1000:
		Effects.set_value(200, k % 200)
		Effects.exclusive_value(200, k % 200)
	t1 = Time.get_ticks_usec()
	print("t_perf: excl+set %.1f us" % [(t1 - t0) / 1000.0])
	Effects.battle = null
