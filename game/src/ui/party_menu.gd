class_name PartyMenu
extends RefCounted
## Out-of-battle party management: equipment (装备) and item use (道具).


static func _pick_member(ui: GameUI, title: String) -> int:
	var ids := Game.party_ids()
	if ids.is_empty():
		await ui.popup("没有部队。", 1.0)
		return -1
	var labels := []
	for pid in ids:
		var p := Game.person(pid)
		labels.append("%s　%s Lv%d" % [p.name, p.class_name_str(), p.level])
	var i := await ui.menu.choose(labels, Vector2(-1, -1), true, title, [], 200)
	return -1 if i < 0 else ids[i]


static func can_equip(p: Person, iid: int) -> bool:
	return p.can_equip(iid)


static func _item_label(iid: int, lvl: int) -> String:
	if iid < 0:
		return "—"
	var it := Game.item(iid)
	var s := str(it.get("name", "?"))
	if String(it.get("category", "")) in ["weapon", "armor"] and lvl > 0 and lvl < 0xff:
		s += " Lv%d" % lvl
	return s


static func equip_menu(ui: GameUI) -> void:
	while true:
		var pid := await _pick_member(ui, "装备")
		if pid < 0:
			return
		var p := Game.person(pid)
		while true:
			var slots := ["武器：" + _item_label(p.weapon, p.weapon_lvl), "防具：" + _item_label(p.armor, p.armor_lvl), "辅助：" + _item_label(p.accessory, 0)]
			var si := await ui.menu.choose(slots, Vector2(-1, -1), true, p.name, [], 220)
			if si < 0:
				break
			var cat: String = ["weapon", "armor", "accessory"][si]
			var opts := []
			var labels := ["（卸下）"]
			for e in Game.bag_entries():
				var iid := int(e["id"])
				if int(e.get("slot", -1)) < 0:
					continue
				if String(Game.item(iid).get("category", "")) == cat and can_equip(p, iid):
					opts.append(e)
					labels.append(_item_label(iid, int(e["lvl"])))
			var k := await ui.menu.choose(labels, Vector2(-1, -1), true, "选择" + ["武器", "防具", "辅助"][si], [], 200)
			if k < 0:
				continue
			# take off the current item
			var cur: int = [p.weapon, p.armor, p.accessory][si]
			var cur_lvl: int = [p.weapon_lvl, p.armor_lvl, 0][si]
			var cur_exp: int = [p.weapon_exp, p.armor_exp, 0][si]
			if k == 0 and cur >= 0 and not Game.is_stack_item(cur) and Game.bag_free_slot() < 0:
				await ui.popup("道具已满，无法卸下。", 1.2)
				continue
			if k > 0:
				var e: Dictionary = opts[k - 1]
				Game.remove_bag_slot(int(e["slot"]))
				match si:
					0:
						p.weapon = int(e["id"])
						p.weapon_lvl = maxi(int(e["lvl"]), 1)
						p.weapon_exp = int(e["exp"])
					1:
						p.armor = int(e["id"])
						p.armor_lvl = maxi(int(e["lvl"]), 1)
						p.armor_exp = int(e["exp"])
					2:
						p.accessory = int(e["id"])
			else:
				match si:
					0: p.weapon = -1
					1: p.armor = -1
					2: p.accessory = -1
			if cur >= 0:
				Game.add_item(cur, maxi(cur_lvl, 1), cur_exp & 0xff)    # keeps its level and experience


## Use consumables outside battle (fruits, 仙人果, 印绶, 太保令 …).
static func item_menu(ui: GameUI) -> void:
	while true:
		var entries := []
		var labels := []
		for e in Game.bag_entries():
			var it := Game.item(int(e["id"]))
			if String(it.get("category", "")) != "consumable":
				continue
			entries.append(e)
			labels.append("%s %s" % [it.get("name", "?"), ("×%d" % int(e["count"])) if e.has("count") else ""])
		if entries.is_empty():
			await ui.popup("没有可以使用的道具。", 1.0)
			return
		var i := await ui.menu.choose(labels, Vector2(-1, -1), true, "道具", [], 200)
		if i < 0:
			return
		var entry: Dictionary = entries[i]
		var it := Game.item(int(entry["id"]))
		var t := int(it.get("type", 0))
		if t in [63, 64, 65, 66, 67, 68]:
			await ui.popup("这个道具只能在战场上使用。", 1.0)
			continue
		var pid := await _pick_member(ui, str(it.get("name", "")))
		if pid < 0:
			continue
		var p := Game.person(pid)
		var v := int(it.get("value", 0))
		match t:
			70, 71, 72, 73, 74:
				var si: int = [0, 2, 1, 3, 4][t - 70]
				p.set_stat_word(si, mini(p.get_stat_word(si) + v, 9999))
				p.set_raw(si, mini(p.get_raw(si) + v, 100))
				await ui.popup("%s 的能力上升了！" % p.name, 1.2)
			75:
				p.bonus_counter = 5
				p.level_up(1)
				await ui.popup("%s 的等级上升到 %d！" % [p.name, p.level], 1.2)
			76:
				var tier := p.cls % 3
				if p.cls > 38 or tier >= 2 or p.level < (20 if tier == 0 else 40):
					await ui.popup("还不能晋升。", 1.0)
					continue
				p.cls += 1
				await ui.popup("%s 晋升为 %s！" % [p.name, p.class_name_str()], 1.2)
			_:
				await ui.popup("现在不能使用。", 1.0)
				continue
		if int(entry.get("slot", -1)) >= 0:
			Game.remove_bag_slot(int(entry["slot"]))
		else:
			Game.remove_item_id(int(entry["id"]))
