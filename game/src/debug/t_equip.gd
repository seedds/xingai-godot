extends Node
## Equipment codes as the battle setup decodes them (0x44299b: 0 default 0x407fd4, 1 take off 0x406cbc, else item
## 0x407df1 = code − 2 + {0, 70, 109}, level 0xfe = raw id). Prints "t_equip: PASS".

func _check(ok: bool, what: String) -> bool:
	if not ok:
		print("t_equip: FAIL ", what)
	return ok


func run() -> void:
	var ok := true
	Game.new_game_state()
	var p: Person = Game.person(0)
	# code ≥ 2: weapon id = code − 2 (no class check in 0x407df1), level 0 = automatic for Lv1 → 1
	p.equip_code(0, 25, 0)
	ok = _check(p.weapon == 23 and p.weapon_lvl == 1 and p.weapon_exp == 0, "weapon code 25 → %d Lv%d" % [p.weapon, p.weapon_lvl]) and ok
	# armour: code − 2 + 70
	p.equip_code(1, 3, 1)
	ok = _check(p.armor == 71 and p.armor_lvl == 1, "armour code 3 → %d" % p.armor) and ok
	# accessory: code − 2 + 109, level 0xff
	p.equip_code(2, 2, 0)
	ok = _check(p.accessory == 109, "accessory code 2 → %d" % p.accessory) and ok
	# level 0xfe: the code is the item id
	p.equip_code(0, 5, 0xfe)
	ok = _check(p.weapon == 5, "raw id with level 0xfe → %d" % p.weapon) and ok
	# code 1 takes the item off
	p.equip_code(0, 1, 0)
	ok = _check(p.weapon == -1 and p.weapon_lvl == 0xff, "take off") and ok
	# code 0: default by class and level (0x407fd4): Lv 20 → tier 1, level (20 % 20)/4 + 1 = 1
	p.level = 20
	p.equip_code(0, 0, 0)
	var it := Game.item(p.weapon)
	ok = _check(p.weapon >= 0 and Person.slot_of(it) == 0 and p.weapon_lvl == 1, "default weapon lv20 → %d Lv%d" % [p.weapon, p.weapon_lvl]) and ok
	# Lv 60 → level 5, exp 0xff
	p.level = 60
	p.equip_code(1, 0, 0)
	ok = _check(p.armor >= 0x46 and p.armor_lvl == 5 and p.armor_exp == 0xff, "default armour lv60 → %d Lv%d" % [p.armor, p.armor_lvl]) and ok
	# wrong category for the slot is ignored; level above the maximum → the maximum
	var before := p.weapon
	p.equip_code(0, 0x46 + 2, 0)
	ok = _check(p.weapon == before, "armour id as weapon ignored") and ok
	p.equip_code(0, 2 + 1, 9)
	ok = _check(p.weapon == 1 and p.weapon_lvl == 5 and p.weapon_exp == 0xff, "level capped at 5") and ok
	# codes above 0x95 do nothing
	p.equip_code(0, 0x96, 1)
	ok = _check(p.weapon == 1, "code > 0x95 ignored") and ok
	print("t_equip: PASS" if ok else "t_equip: FAILED")
