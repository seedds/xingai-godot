class_name BattleAttrs
extends RefCounted
## Ops 0x36 武将状态测试 / 0x38 武将能力设定 inside a battle (getter 0x422e9d, setter 0x407027 / 0x406eca; eex.md §11.5).
## Attributes: 0–4 stat words (攻防精爆士), 5 base HP (dword +0x1b), 6 base MP, 7 / 8 the unit's HP / MP, 9 level,
## 10–14 raw abilities, 15 special (test: an item equipped; set: face; add: the per-unit byte 0x501a84).

static func get_attr(st: BattleStage, pid: int, attr: int) -> int:
	var p := Game.person(pid)
	if p == null:
		return -1
	match attr:
		0, 1, 2, 3, 4: return p.get_stat_word(attr)
		5: return Mem.r32(p.base + 0x1b)
		6: return p.mp_base
		7, 8:
			var u := st.unit_of_person(pid)
			if u == null:
				return -1
			return u.hp if attr == 7 else u.mp
		9: return p.level
		10, 11, 12, 13, 14: return p.get_raw(attr - 10)
	return 0


## 0x36: person 0xffff → false; selectors ≥ 0x400 (0x4113f5): any unit on the map that matches (0x400 any, 0x401
## side 1, 0x402 not side 1, 0x403 the current unit) and passes [G: the attribute is compared per unit]; attr 7/8
## without a unit → false; attr 15 = the person has item v equipped (cmp ignored; a hit sets EV 4068 = person).
static func test(st: BattleStage, pid: int, attr: int, v: int, cmp: int) -> bool:
	if pid == 0xffff:
		return false
	if pid >= 0x400:
		for u in st.units:
			if u.state != 2 or u.pid < 0:
				continue
			var ok := false
			match pid:
				0x400: ok = true
				0x401: ok = u.side() == 1
				0x402: ok = u.side() != 1
				0x403: ok = u == st.current_unit
			if ok and _test_one(st, u.pid, attr, v, cmp):
				return true
		return false
	return _test_one(st, pid, attr, v, cmp)


static func _test_one(st: BattleStage, pid: int, attr: int, v: int, cmp: int) -> bool:
	if attr == 15:
		var p := Game.person(pid)
		if p == null:
			return false
		for k in 3:
			if Mem.r8(p.base + 0x2e + 3 * k) == (v & 0xff):
				Mem.w32(Mem.EV + 4 * 4068, pid)
				return true
		return false
	var cur := get_attr(st, pid, attr)
	if cur < 0:
		return false
	return Game.compare(cur, v, cmp)


## 0x38: op 0 set, 1 add, 2 subtract (saturating, then set); battle selectors 0x400..0x402 = the current unit.
## Changes of attrs ≤ 6 go into the 功勋 bonus table 0x508400 (0x408b52) [G: as the difference].
static func set_attr(st: BattleStage, pid: int, attr: int, op: int, v: int) -> void:
	if pid >= 0x400 and pid <= 0x402:
		if st.current_unit == null:
			return
		pid = st.current_unit.pid
	if pid == 0xffff or pid >= 0x400 or attr > 15:
		return
	var p := Game.person(pid)
	if p == null:
		return
	if op == 2 and attr != 9 and attr != 15:
		var cur := get_attr(st, pid, attr)
		if cur < 0:
			return
		v = Rules.sat_sub(cur, v)
		op = 0
	var before := get_attr(st, pid, attr) if attr <= 6 else 0
	match attr:
		0, 1, 2, 3, 4:
			p.set_stat_word(attr, mini(v, 9999) if op == 0 else mini(p.get_stat_word(attr) + v, 9999))
		5:
			Mem.w32(p.base + 0x1b, mini(v, 0xffff) if op == 0 else mini(Mem.r32(p.base + 0x1b) + v, 9999))
		6:
			p.mp_base = mini(v, 9999) if op == 0 else mini(p.mp_base + v, 9999)
		7, 8:
			var u := st.unit_of_person(pid)
			if u == null or u.state != 2:
				return
			Mem.w32(Mem.EV + 4 * 4044, 2 if op == 0 else 1)
			if attr == 7:
				u.hp = mini(st.hp_op(u.hp, v), u.max_hp())
			else:
				u.mp = mini(st.hp_op(u.mp, v), u.max_mp())
			Mem.w32(Mem.EV + 4 * 4044, 0)
		10, 11, 12, 13, 14:
			p.set_raw(attr - 10, mini(v, 100) if op == 0 else mini(p.get_raw(attr - 10) + v, 100))
		15:
			if op == 0:
				p.face = v
			else:
				var u2 := st.unit_of_person(pid)
				if u2 != null:
					Mem.w8(0x501a84 + u2.slot, v)
	if attr <= 6 and pid < 102 and Game.is_member(pid):
		var a := 0x508400 + 14 * pid + 2 * attr
		Mem.w16(a, Mem.r16(a) + get_attr(st, pid, attr) - before)
	st.refresh_units()
