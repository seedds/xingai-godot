class_name ItemList66
extends Dlg66
## Dialog 325 道具一览 (menu 情报 → 持有道具一览, 0x43fdef → proc 0x41428e → 0x4680da): two tabs, 武具一览 and 道具一览
## (0x486c69 / 0x486c72; the 装备情报 mode with [0x500ad0] = 1 shows the 专属 / 套装 tables instead — not ported).
##  * 武具一览, list 0x5b1 (vtable 0x487140, 0x467f25): 名称 持有者 属性 效果 Lv Exp 特殊效果 — the warehouse
##    (0x4668e5, holder 仓库), then the weapons, armour and accessories worn by members (0x466d6e, persons in id order).
##  * 道具一览, list 0x3eb (vtable 0x487198, 0x40d47c): 名称 库存 功效 效果 — the items with a count (0x466a6c).
## Every row is active (0x472d38); a click (0x472b60) or the right button opens the item's details (0x467721).
## 现金 0x475; 确定 (id 2) closes.

static func run(ui: GameUI) -> void:
	if Game.autoplay:
		return
	var d := ItemList66.new()
	d.build()
	await Dlg66.run_dialog(ui, d)


func build() -> void:
	setup("道具一览", 318, 211)
	add_tab(0x405, 1, 1, 316, 192, ["武具一览", "道具一览"])
	var l1 := add_list(0x5b1, 2, 15, 307, 173)
	for k in [0, 0xc, 3, 5, 1, 2, 10]:
		l1.columns.append(ItemText66.column(k, self))
	var l2 := add_list(0x3eb, 2, 15, 253, 173)
	for k in [0, 0xb, 4, 5]:
		l2.columns.append(ItemText66.column(k, self))
	add_static(null, 9, 199, 17, 9, "现金", 2)
	add_static(0x475, 28, 198, 27, 10, "%d" % Game.gold, 2, true)
	add_button(2, 267, 196, 50, 14, "确定")
	for i in Game.BAG_SLOTS:
		var a := Game.BAG + 3 * i
		if Mem.r8(a) != 0xff:
			_add_row(l1, {"item": Mem.r8(a), "lvl": Mem.r8(a + 1), "exp": Mem.r8(a + 2), "holder": -1})
	for s in 3:
		for pid in 0x400:
			var b := Mem.person_addr(pid)
			if Mem.r8(b + 0x2a) == 0xff:
				continue
			var iid := Mem.r8(b + 0x2e + 3 * s)
			if iid != 0xff:
				_add_row(l1, {"item": iid, "lvl": Mem.r8(b + 0x2f + 3 * s), "exp": Mem.r8(b + 0x30 + 3 * s), "holder": pid})
	for iid in 0x160:
		if iid < 0xff and Mem.r8(0x493a50 + iid) != 0:
			_add_row(l2, {"item": iid, "lvl": 0, "exp": 0})
	for lv in [l1, l2]:
		lv.fit_columns(self)
	_tab(0)


func _add_row(lv: Dlg66.ListView, r: Dictionary) -> void:
	var cells := []
	for c in lv.columns:
		cells.append(ItemText66.cell(int(c["kind"]), r))
	lv.rows.append({"cells": cells, "icon": ItemText66.small_icon(int(r["item"])), "enabled": true, "data": r})


func _tab(i: int) -> void:
	ctrl(0x405)["sel"] = i
	show_ctrl(0x5b1, i == 0)
	show_ctrl(0x3eb, i == 1)


func _on_tab(_id: Variant, i: int) -> void:
	ShopMenu.click_se(0)                    # 0x4682d6
	_tab(i)


func _on_list_click(lid: Variant, row: int) -> void:
	var r: Dictionary = list(lid).rows[row]["data"]
	await ItemInfo66.show_item(self, int(r["item"]), int(r["lvl"]), int(r["exp"]))


func _on_list_rclick(lid: Variant, row: int) -> void:
	await _on_list_click(lid, row)
