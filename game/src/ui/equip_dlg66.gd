class_name EquipDlg66
extends Dlg66
## Dialog 328 装备 (toolbar 装备 → 0x461c88, proc 0x46cf31 → 0x46c065): the warehouse list 0x5b1 (仓库列表, class
## vtable 0x4873a0: columns 名称 属性 Lv Exp 效果 特殊效果, the bag in slot order 0x46681b; rows the selected person
## can use (0x407961, 0x46bb6f) are active) and the person panel (PersonPanel66 with the 特技 list box 0x4d3).
##  * A click on an active row (0x46bc8d): the item leaves the warehouse (0x41606a), sound effect 9, and is worn
##    (0x468d7e: the worn one goes back to the warehouse, 0x468cdc / 0x46ba91).
##  * A click in a weapon / armour / accessory frame (0x590..0x592, 0x469b7e → 0x46befb): the item goes back to the
##    warehouse (refused with sound 0 when it holds 200), sound effect 1. Right button: the item's details (0x46a89e).
##  * 自动装备 0x405 → 0x43ee4c(2): every member's equipment into the warehouse, then the protagonist (unless the
##    "may not sortie" ring holds a 0 and [0x501a6d] ≠ 1), the forced sortie persons and — with [0x501a6d] = 1 or while
##    fewer than the sortie maximum — every other member (not in the two rings) take their default equipment back
##    (0x43ef7d: the items recorded in the join history 0x501801 that are in the warehouse and usable); sound 9.
##  * 卸除装备 0x406 → 0x43ee4c(3): every member's equipment into the warehouse.
##  * 设为默认装备 0x407: every member's current equipment becomes the default (0x43edd0), then "设置成功。" (0x48b720).

var panel := PersonPanel66.new()


static func run(ui: GameUI) -> void:
	if Game.autoplay:
		return
	var d := EquipDlg66.new()
	d.build()
	await Dlg66.run_dialog(ui, d)


func build() -> void:
	setup("装备", 452, 273)
	add_group(2, 1, 235, 253, "仓库列表")
	var lv := add_list(0x5b1, 5, 11, 228, 240)
	for k in [0, 3, 1, 2, 5, 10]:
		lv.columns.append(ItemText66.column(k, self))
	add_line(239, 2, 1, 272)
	add_button(0x403, 163, 256, 36, 15, "上一武将")
	add_button(0x404, 200, 256, 36, 15, "下一武将")
	add_button(2, 136, 256, 27, 15, "结束")
	add_button(0x405, 3, 256, 36, 15, "自动装备")
	add_button(0x407, 40, 256, 51, 15, "设为默认装备")
	add_button(0x406, 92, 256, 36, 15, "卸除装备")
	panel.build(self, {
		"combo": [341, 3, 109], "face": [250, 3, 80, 80], "lv_label": [245, 85, 9, 10], "lv": [255, 85, 11, 10],
		"cls": [270, 85, 61, 10], "stat_label_x": 245, "stat_x": 270, "stat_w": 29, "plus_x": 302, "plus_w": 29,
		"stat_ys": [97, 109, 121, 133, 145, 157, 169, 181],
		"slots": [
			{"title": [345, 27, 103, 8], "icon": [345, 39, 23, 23], "lvl_lbl": [369, 41, 8, 8], "lvl": [381, 41, 11, 8],
				"exp_lbl": [394, 41, 12, 8], "bar": [409, 41, 38, 8], "e": [370, 53, 76, 8], "b": [345, 65, 100, 8],
				"frame": [341, 25, 110, 51]},
			{"title": [345, 83, 103, 8], "icon": [345, 95, 23, 23], "lvl_lbl": [369, 97, 9, 8], "lvl": [381, 97, 13, 8],
				"exp_lbl": [394, 97, 15, 8], "bar": [409, 97, 38, 8], "e": [370, 109, 76, 8], "b": [345, 121, 100, 8],
				"frame": [341, 81, 110, 51]},
			{"title": [345, 139, 103, 8], "icon": [345, 151, 23, 23], "b": [345, 177, 100, 8],
				"frame": [341, 137, 110, 51]}],
		"desc": [341, 194, 110, 77], "skills": [242, 194, 97, 79], "prev": [163, 256, 36, 15],
		"next": [200, 256, 36, 15]})
	# the frames are the drop targets (0x469b7e: rects of 0x590 / 0x591 / 0x592)
	add_hot(0x590, 341, 25, 110, 51)
	add_hot(0x591, 341, 81, 110, 51)
	add_hot(0x592, 341, 137, 110, 51)
	_fill()


## 0x46bbe0 / 0x46bb6f.
func _fill() -> void:
	var lv := list(0x5b1)
	var keep := lv.sel
	lv.rows.clear()
	var p := panel.person()
	for i in Game.BAG_SLOTS:
		var a := Game.BAG + 3 * i
		var iid := Mem.r8(a)
		if iid == 0xff:
			continue
		var r := {"item": iid, "lvl": Mem.r8(a + 1), "exp": Mem.r8(a + 2), "slot": i}
		r["usable"] = p != null and Game._can_use(p, iid)
		var cells := []
		for c in lv.columns:
			cells.append(ItemText66.cell(int(c["kind"]), r))
		lv.rows.append({"cells": cells, "icon": ItemText66.small_icon(iid), "enabled": r["usable"], "data": r})
	lv.fit_columns(self)
	lv.sel = mini(keep, lv.rows.size() - 1)
	lv.scroll(0)
	queue_redraw()


func _on_combo(id: Variant, i: int) -> void:
	if id == 0x44a:
		ShopMenu.click_se(0)
		panel.select(i)
		_fill()


func _on_list_select(lid: Variant, row: int) -> void:
	if lid == 0x5b1:
		panel.preview(list(0x5b1).rows[row]["data"])


## 0x46bc8d.
func _on_list_click(lid: Variant, row: int) -> void:
	if lid != 0x5b1:
		return
	var r: Dictionary = list(0x5b1).rows[row]["data"]
	var p := panel.person()
	if p == null or not Game._can_use(p, int(r["item"])):
		return
	Game.remove_bag_slot(int(r["slot"]))
	SoundMap.play_se_id(9, 1)
	var slot := ItemText66.category(int(r["item"]))
	var b := p.base + 0x2e + 3 * slot
	var cur := Mem.r8(b)
	if cur != 0xff:
		Game.bag_put(cur, Mem.r8(b + 1), Mem.r8(b + 2))
	Mem.w8(b, int(r["item"]))
	if slot != 2:
		Mem.w8(b + 1, int(r["lvl"]))
		Mem.w8(b + 2, int(r["exp"]))
	panel.refresh_slot(slot)
	_fill()
	var lv := list(0x5b1)
	panel.preview(lv.rows[lv.sel]["data"] if lv.sel >= 0 else {})


## 0x46befb (left) / 0x46a89e (right) on a slot frame.
func _on_pic(id: Variant, button: int) -> void:
	var s: int = [0x590, 0x591, 0x592].find(id)
	if s < 0:
		return
	var p := panel.person()
	if p == null:
		return
	var b := p.base + 0x2e + 3 * s
	var cur := Mem.r8(b)
	if cur == 0xff:
		return
	if button == MOUSE_BUTTON_RIGHT:
		await ItemInfo66.show_item(self, cur, Mem.r8(b + 1), Mem.r8(b + 2))
		return
	if ItemText66.bag_count() > 199:
		SoundMap.play_se_id(0, 1)
		return
	Game.bag_put(cur, Mem.r8(b + 1), Mem.r8(b + 2))
	Mem.w8(b, 0xff)
	if s < 2:
		Mem.w8(b + 1, 0)
		Mem.w8(b + 2, 0)
	SoundMap.play_se_id(1, 1)
	panel.refresh_slot(s)
	panel.preview({})
	_fill()


func _on_list_rclick(lid: Variant, row: int) -> void:
	var r: Dictionary = list(lid).rows[row].get("data", {})
	if lid == 0x5b1 and not r.is_empty():
		await ItemInfo66.show_item(self, int(r["item"]), int(r["lvl"]), int(r["exp"]))


func _on_command(id: Variant) -> void:
	match id:
		0x403:
			panel.step(-1)
			_fill()
		0x404:
			panel.step(1)
			_fill()
		0x405:
			auto_equip(2)
			_after_all()
		0x406:
			auto_equip(3)
			_after_all()
		0x407:
			for pid in 0x3fe:
				record_default(pid)
			await msg_box("设置成功。")
		_:
			super._on_command(id)


func _after_all() -> void:
	for s in 3:
		panel.refresh_slot(s)
	panel.preview({})
	_fill()


## 0x43ee4c(mode).
static func auto_equip(mode: int) -> void:
	for pid in 0x3fe:
		if Mem.r8(Mem.person_addr(pid) + 0x2a) == 0:
			for s in 3:
				Game.take_off(pid, s, true)
	if mode == 3:
		return
	var all := Mem.r8(0x501a6d) == 1
	var count := 0
	var skip0 := false
	if not all:
		for i in 20:
			if Mem.r16(Game.SORTIE_EXCLUDED + 2 * i) == 0:
				skip0 = true
				break
	if not skip0:
		count = 1
		equip_default(0)
	for i in 20:
		var f := Mem.r16(Game.SORTIE_FORCED + 2 * i)
		if f != 0 and f != 0xffff:
			equip_default(f)
			count = (count + 1) & 0xff
	if all or count < Mem.r8(Game.SORTIE_MAX):
		for pid in range(1, 0x3fe):
			var listed := false
			for i in 20:
				if (not all and Mem.r16(Game.SORTIE_EXCLUDED + 2 * i) == pid) or Mem.r16(Game.SORTIE_FORCED + 2 * i) == pid:
					listed = true
					break
			if not listed:
				equip_default(pid)
	SoundMap.play_se_id(9, 1)


## 0x43ef7d: a member takes the items of its join-history entry (0x501801: {u16 person, u8, weapon, armour,
## accessory}) back from the warehouse — the first warehouse slot holding each (0x41e327), if usable.
static func equip_default(pid: int) -> void:
	var base := Mem.person_addr(pid)
	if Mem.r8(base + 0x2a) != 0:
		return
	var p := Game.person(pid)
	for k in 0x67:
		var e := 0x501801 + 6 * k
		var who := Mem.r16(e)
		if who == 0xffff:
			return
		if who != pid:
			continue
		for s in 3:
			var want := Mem.r8(e + 3 + s)
			if want == 0xff:
				continue
			for i in Game.BAG_SLOTS:
				var a := Game.BAG + 3 * i
				if Mem.r8(a) == want:
					if Game._can_use(p, want):
						var lvl := Mem.r8(a + 1)
						var xp := Mem.r8(a + 2)
						Game.remove_bag_slot(i)
						Mem.w8(base + 0x2e + 3 * s, want)
						if s < 2:
							Mem.w8(base + 0x2f + 3 * s, lvl)
							Mem.w8(base + 0x30 + 3 * s, xp)
					break
		return


## 0x43edd0: a member's current equipment becomes its join-history default (an entry is appended when missing).
static func record_default(pid: int) -> void:
	if pid == 0 and Mem.r16(0x501805) == 0:
		Mem.w16(0x501801, 0xffff)
	var base := Mem.person_addr(pid)
	if Mem.r8(base + 0x2a) != 0:
		return
	for k in 0x67:
		var e := 0x501801 + 6 * k
		var who := Mem.r16(e)
		if who == 0xffff:
			Mem.w16(e, pid)
			Mem.w16(e + 6, 0xffff)
			Mem.w8(e + 2, 0)
			Mem.w8(0x501800, Mem.r8(0x501800) + 1)
			who = pid
		if who == pid:
			Mem.w8(e + 3, Mem.r8(base + 0x2e))
			Mem.w8(e + 4, Mem.r8(base + 0x31))
			Mem.w8(e + 5, Mem.r8(base + 0x34))
			return
