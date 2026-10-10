class_name PersonAttrs
extends RefCounted
## Person attribute ids (0x406d87 / 0x406f54) used by ops 0x36/0x38 outside battles:
## 0-4 stat words, 5 base MaxHP, 6 base MaxMP, 9 level, 10-14 raw abilities, 15 item stack count.

static func get_attr(pid: int, attr: int) -> int:
	if attr == 15:
		return Game.stack_count(pid)
	var p := Game.person(pid)
	if p == null:
		return 0
	match attr:
		0, 1, 2, 3, 4: return p.get_stat_word(attr)
		5: return p.hp_base
		6: return p.mp_base
		9: return p.level
		10, 11, 12, 13, 14: return p.get_raw(attr - 10)
	return 0


static func set_attr(pid: int, attr: int, op: int, v: int) -> void:
	var p := Game.person(pid)
	if p == null:
		return
	var cur := get_attr(pid, attr)
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
		15:
			if Game.is_stack_item(pid):
				Mem.w8(Game.STACKS + pid - Game.STACK_FIRST, clampi(nv, 0, 99))
