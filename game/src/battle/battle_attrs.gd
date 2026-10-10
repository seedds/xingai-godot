class_name BattleAttrs
extends RefCounted
## Attribute ids of EEX op 0x36 test_attr / 0x38 set_attr (0x4112e9 / 0x412006, person attr 0x406d87/0x406f54):
## 0-4 battle stat words (攻击 防御 精神 爆发 士气, person +0x11..), 5 base MaxHP (+0x1c), 6 base MaxMP (+0x20),
## 7 battle-unit HP, 9 level, 10-14 raw abilities (武艺 统制 智谋 感知 胆魄), 15 stack count of item `person`.
## Person selectors 0x400..0x402 mean the current (event-triggering / acting) unit.

static func _pid(st: BattleStage, pid: int) -> int:
	if pid >= 0x400 and pid <= 0x402 and st.current_unit:
		return st.current_unit.pid
	return pid


static func get_attr(st: BattleStage, pid: int, attr: int) -> int:
	pid = _pid(st, pid)
	if pid == 0xffff or pid > 0x400:
		return -1
	if attr == 15:
		return Game.stack_count(pid)
	if attr == 7:
		# the person's battle-unit HP (hidden/not-yet-appeared units keep full HP)
		# 0x4112e9: unit index lookup; no unit → the value is the index 0xff (255), not 0
		var u := st.unit_by_pid(pid)
		return u.hp if u else 0xff
	var p := Game.person(pid)
	if p == null:
		return 0
	match attr:
		0, 1, 2, 3, 4: return p.get_stat_word(attr)
		5: return p.hp_base
		6: return p.mp_base
		9: return p.level
		10, 11, 12, 13, 14: return p.get_raw([0, 1, 2, 3, 4][attr - 10])
	return 0


static func set_attr(st: BattleStage, pid: int, attr: int, op: int, v: int) -> void:
	pid = _pid(st, pid)
	if attr == 7:
		var u := st.unit_by_pid(pid)
		if u == null:
			return
		match op:
			0: u.hp = mini(v, u.max_hp())
			1: u.hp = mini(u.hp + v, u.max_hp())
			2: u.hp = maxi(u.hp - v, 0)
		if u.hp <= 0 and u.state == BUnit.STATE_ON_MAP:
			u.extra["dying"] = true
		st.refresh_units()
		if u.hp <= 0 and u.state == BUnit.STATE_ON_MAP:
			await st.actions.unit_defeated(u)
		return
	var p := Game.person(pid)
	if p == null:
		return
	var cur := get_attr(st, pid, attr)
	var nv := cur
	match op:
		0: nv = v
		1: nv = cur + v
		2: nv = maxi(cur - v, 0)
	match attr:
		0, 1, 2, 3, 4: p.set_stat_word(attr, mini(nv, 9999))
		5: p.hp_base = clampi(nv, 1, 9999)
		6: p.mp_base = clampi(nv, 1, 255)
		9:
			if nv > p.level: p.level_up(nv - p.level)
			else: p.level = maxi(nv, 1)
		10, 11, 12, 13, 14: p.set_raw(attr - 10, mini(nv, 120))
