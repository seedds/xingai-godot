class_name PersonAttrs
extends RefCounted
## Person attributes of ops 0x36 武将状态测试 (0x4112fa) and 0x38 武将能力设定 (0x412007), docs/eex.md §11.5:
## getter 0x422e9d, set 0x407027, add 0x406eca. Attribute ids: 0–4 stat words +0x11 (攻防精爆士), 5 HP base (dword
## +0x1b), 6 MP base +0x1f, 7 / 8 the battle unit's current HP / MP, 9 Lv +0x2c, 10–14 raw abilities +0x21.. (武统智敏运),
## 15 special (test: "has item v equipped"; set: face; add: u8 0x501a84[unit index]).
## The battle selectors of op 0x36 (persons ≥ 0x400) and the unit HP/MP routine 0x45aa37 are BattleStage's (it
## overrides op_test_attr / op_set_attr); this is the story side and the shared record part.


## Getter 0x422e9d: 0..4 words, 5 dword, 6 word, 9 level, 7 / 8 / 15 → 0, 10.. → byte +0x17 + attr.
static func get_attr(pid: int, attr: int) -> int:
	var b := Mem.person_addr(pid)
	attr &= 0xff
	if attr < 5:
		return Mem.r16(b + 0x11 + 2 * attr)
	match attr:
		5: return Mem.r32(b + 0x1b)
		6: return Mem.r16(b + 0x1f)
		9: return Mem.r8(b + 0x2c)
	if attr < 10 or attr == 15:
		return 0
	return Mem.r8(b + 0x17 + attr)


## Current HP / MP of the person's unit (0x477adc → unit +0x10 / +0x14), or -1 without a unit on the field.
static func unit_hp_mp(pid: int, attr: int) -> int:
	var slot := Game.unit_slot_of_person(pid)
	if slot < 0:
		return -1
	var u := Mem.unit_addr(slot)
	return Mem.r32(u + 0x10) if attr == 7 else Mem.r16(u + 0x14)


## Op 0x36 outside the battle selectors: person 0xffff → false; attr 7 / 8 without a unit → false; attr 15 = one of the
## three equipment slots holds item v (cmp ignored; a hit sets EV[4068] = person, 0x4114d4); else getter vs v with
## 0x421e00 (unsigned; 0 ≥, 1 <, other ==).
static func test(_host: ScriptHost, pid: int, attr: int, v: int, cmp: int) -> bool:
	if pid == 0xffff or pid > 0x400:
		return false
	var a := attr & 0xff
	var val := 0
	if a == 7 or a == 8:
		val = unit_hp_mp(pid, a)
		if val < 0:
			return false
	elif a == 15:
		var b := Mem.person_addr(pid)
		for k in 3:
			if Mem.r8(b + 0x2e + 3 * k) == v:
				Mem.set_ev(4068, pid)
				return true
		return false
	else:
		val = get_attr(pid, a)
	return Game.compare(val, v & 0xffffffff, cmp & 0xff)


## Op 0x38: rejected for person 0xffff, > 0x400, attr > 15; attrs < 7 run the 功勋 hook 0x408b52(v, op, attr);
## op 0 set (0x407027), 1 add (0x406eca), 2 set(get − v, saturating 0x47fa9e), other ops do nothing.
static func set_attr(host: ScriptHost, pid: int, attr: int, op: int, v: int) -> void:
	if pid == 0xffff or pid > 0x400 or attr & 0xff > 15:
		return
	var a := attr & 0xff
	var o := op & 0xff
	if o > 2:
		return
	if a < 7:
		merit_hook(pid, a, v, o)
	match o:
		0:
			set_value(host, pid, a, v)
		1:
			add_value(host, pid, a, v)
		2:
			var cur := get_attr(pid, a)
			if a == 7 or a == 8:
				cur = maxi(unit_hp_mp(pid, a), 0)
			set_value(host, pid, a, cur - v if (v & 0xffffffff) < cur else 0)
	host.on_field_written(-1, pid)


## SetStat 0x407027.
static func set_value(host: ScriptHost, pid: int, a: int, v: int) -> void:
	var b := Mem.person_addr(pid)
	v &= 0xffffffff
	if a < 5:
		Mem.w16(b + 0x11 + 2 * a, 9999 if (v & 0xffff) > 0x270e else v)
	elif a == 5:
		Mem.w32(b + 0x1b, 0xffff if v > 0xfffe else v)
	elif a == 6:
		Mem.w16(b + 0x1f, 9999 if (v & 0xffff) > 0x270e else v)
	elif a == 7 or a == 8:
		# battle HP / MP through 0x45aa37 with byte EV[4044] = 2 (set): clamped to the maximum, never kills
		host.unit_hp_mp_op(pid, a, v, 2)
	elif a == 15:
		Mem.w16(b + 4, v & 0xffff)
		Mem.w16(Mem.FACE_TABLE + 2 * pid, v & 0xffff)
	elif a > 9:
		Mem.w8(b + 0x17 + a, mini(v, 100))


## AddStat 0x406eca (mode 0): 0..4 / 5 / 6 capped at 9999; 7 / 8 the battle routine with EV[4044] = 1 (add); 9 nothing;
## 15 → u8 0x501a84[unit index] = v; 10..14 capped at 100.
static func add_value(host: ScriptHost, pid: int, a: int, v: int) -> void:
	var b := Mem.person_addr(pid)
	if a < 5:
		Mem.w16(b + 0x11 + 2 * a, mini(Mem.r16(b + 0x11 + 2 * a) + v, 9999))
	elif a == 5:
		Mem.w32(b + 0x1b, mini(Mem.r32(b + 0x1b) + v, 9999))
	elif a == 6:
		Mem.w16(b + 0x1f, mini(Mem.r16(b + 0x1f) + v, 9999))
	elif a == 7 or a == 8:
		host.unit_hp_mp_op(pid, a, v, 1)
	elif a == 15:
		var s := Game.unit_slot_of_person(pid)
		if s >= 0:
			Mem.w8(0x501a84 + s, v)
	elif a > 9:
		Mem.w8(b + 0x17 + a, mini(Mem.r8(b + 0x17 + a) + v, 100))


## 功勋 hook 0x408b52(value, mode, stat) for persons < 102 not marked 0xff: mode 0 sets the bonus to value − base
## (DataTransfer.merit_set); mode 1 adds value to it (members; others get value); mode 2 subtracts min(value, the
## current attribute) (members; others get −that).
static func merit_hook(pid: int, stat: int, v: int, mode: int) -> void:
	if pid > 0x65 or Mem.r8(Mem.person_addr(pid) + 0x2a) == 0xff:
		return
	if mode == 0:
		DataTransfer.merit_set(pid, stat, v & 0xffff)
		return
	var a := 0x508400 + 14 * pid + 2 * stat
	var member := Mem.r8(Mem.person_addr(pid) + 0x2a) == 0
	if mode == 1:
		Mem.w16(a, (Mem.r16s(a) + v) & 0xffff if member else v & 0xffff)
	else:
		var d := mini(v, get_attr(pid, stat))
		Mem.w16(a, (Mem.r16s(a) - d) & 0xffff if member else (-d) & 0xffff)
