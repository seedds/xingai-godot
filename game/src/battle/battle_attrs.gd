class_name BattleAttrs
extends RefCounted
## Op 0x36 武将状态测试 inside a battle (0x4112fa, eex.md §11.5): persons ≥ 0x400 are selectors (0x4113f5); other
## persons and op 0x38 use the shared PersonAttrs (getter 0x422e9d).


## 0x4112fa: person 0xffff → false; selectors ≥ 0x400 → 0x4113f5; else PersonAttrs.test.
static func test(st: BattleStage, pid: int, attr: int, v: int, cmp: int) -> bool:
	if pid == 0xffff:
		return false
	if pid >= 0x400:
		for u in st.units:
			if u.state == 2 and _test_unit(u, attr, v, cmp) and _sel_ok(st, u, pid):
				return true
		return false
	return PersonAttrs.test(st, pid, attr, v, cmp)


## 0x4113f5 per unit on the map: 7 HP (dword +0x10), 8 MP (word +0x14), 15 an equipped item v (a hit sets EV[4068] =
## the person, 0x4114d4), else the person's attribute; compared by 0x421e00.
static func _test_unit(u: BUnit, attr: int, v: int, cmp: int) -> bool:
	var val := 0
	match attr:
		7: val = u.hp
		8: val = u.mp & 0xffff
		15:
			var b := Mem.person_addr(u.pid)
			for k in 3:
				if Mem.r8(b + 0x2e + 3 * k) == v:
					Mem.set_ev(4068, u.pid)
					return true
			return false
		_: val = PersonAttrs.get_attr(u.pid, attr)
	return Game.compare(val, v & 0xffffffff, cmp)


## 0x41147a: 0x400 any unit, 0x401 player side (0x406710 = 1), 0x402 the other sides, others: the acting person's
## first unit (0x456079([0x4b5df0])) when it is on the player side with kind 0 (0x413172).
static func _sel_ok(st: BattleStage, u: BUnit, sel: int) -> bool:
	match sel - 0x400:
		0: return true
		1: return u.side() == 1
		2: return u.side() != 1
	if u.side() != 1 or u.kind != 0:
		return false
	var cur := st.current_unit_person()
	for o in st.units:
		if o.pid == cur and o.state != 0:
			return o == u
	return false
