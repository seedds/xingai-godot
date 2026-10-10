extends Node
## Equipment codes of ops 0x3e / 0x48 (Person.equip_code). Prints "t_equip: PASS".

func _check(ok: bool, what: String) -> bool:
	if not ok:
		print("t_equip: FAIL ", what)
	return ok


func run() -> void:
	var ok := true
	Game.new_game_state()
	var p: Person = Game.person(0)
	# code ≥ 2: weapon code − 2, armour code + 0x24 (R_00: person 0 gets weapon code 25 = item 23)
	p.equip_code(0, 25, 0)
	ok = _check(p.weapon == 23 or not p.can_equip(23), "weapon code 25 → %d" % p.weapon) and ok
	p.equip_code(1, 3, 1)
	ok = _check(p.armor == 39 or not p.can_equip(39), "armour code 3 → %d" % p.armor) and ok
	# code 1 takes the item off
	p.equip_code(0, 1, 0)
	ok = _check(p.weapon == -1 and p.weapon_lvl == 0xff, "take off") and ok
	# code 0: default by class and level (0x407fe7)
	p.level = 20
	p.equip_code(0, 0, 0)
	var it := Game.item(p.weapon)
	ok = _check(p.weapon >= 0 and Person.slot_of(it) == 0 and p.weapon % 3 == 1 and p.weapon_lvl == 1, "default weapon lv20 → %d Lv%d" % [p.weapon, p.weapon_lvl]) and ok
	p.level = 50
	p.equip_code(1, 0, 0)
	ok = _check(p.armor >= 0x26 and p.armor <= 0x2b and (p.armor - 0x26) % 3 == 2 and p.armor_lvl == 3 and p.armor_exp == 0xff, "default armour lv50 → %d Lv%d" % [p.armor, p.armor_lvl]) and ok
	# wrong kind for the slot is ignored; level capped at 3 for normal items
	var before := p.weapon
	p.equip_code(0, 0x26 + 2, 0)
	ok = _check(p.weapon == before, "armour id as weapon ignored") and ok
	p.equip_code(0, 2 + before, 9)
	ok = _check(p.weapon_lvl == 3, "level cap") and ok
	print("t_equip: PASS" if ok else "t_equip: FAILED")
