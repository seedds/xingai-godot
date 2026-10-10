class_name UnitList66
extends Dlg66
## Dialog 186 部队情报一览 (menu 情报 → 武将一览, 0x47af8a → proc 0x47aea6; list class vtable 0x487700): a list view
## 0x402 with the columns 武将名 部队属性 Lv Exp HP MP 攻击 防御 精神 爆发 士气 (headers 0x47a49d, LVCFMT 0x47a4c9,
## width samples 0x479ddc + padding 0x479e08), rows the members in person order outside a battle (0x4768c0); the
## 我军 / 敌军 radio buttons 0x409 / 0x40a only in a battle (0x4091c1). Cells (0x47a64f): the class grey when the
## person can be promoted (0x4358c5), HP red when poisoned, MP red with 禁咒, values red / blue when a buff lowers /
## raises them, a retreated unit (state 3) red. A click opens 武将情报 for the row (0x47ade4); a column header sorts
## by it (0x479f91: a − b; retreated units last).
## [G] in a battle the rows are the units of the chosen group on the field (我军: sides 0 / 1, 敌军: the others) with
## the person's values; the original takes the unit's (0x440151, battle track).

const TITLES := ["武将名", "部队属性", "Lv", "Exp", "HP", "MP", "攻击", "防御", "精神", "爆发", "士气"]
const LVCFMT := [0, 2, 1, 1, 2, 2, 1, 1, 1, 1, 1]
const SAMPLES := ["最多武将数", "部队属性", "Lv", "MAX", "999/999", "999/999", "攻击", "防御", "精神", "爆发", "士气"]
const PAD := [-2, 12, 12, 10, 16, 10, 12, 12, 12, 12, 12]

var mine := true
var sort_col := -1
var sort_desc := false


static func run(ui: GameUI) -> void:
	if Game.autoplay:
		return
	var d := UnitList66.new()
	d.build()
	await Dlg66.run_dialog(ui, d)


func build() -> void:
	setup("部队情报一览", 383, 220)
	var lv := add_list(0x402, 2, 2, 379, 200)
	for k in 11:
		lv.columns.append({"title": TITLES[k], "w": _tw(SAMPLES[k]) + PAD[k] * 1.5, "align": [0, 2, 1][LVCFMT[k]],
			"kind": k})
	var battle := StatusPanel._battle()
	add_button(0x409, 13, 207, 35, 9, "我军")
	add_button(0x40a, 53, 207, 35, 9, "敌军")
	show_ctrl(0x409, battle)
	show_ctrl(0x40a, battle)
	add_button(2, 336, 205, 45, 13, "确定")
	_fill()


func _rows() -> Array:
	var out := []
	if not StatusPanel._battle():
		for pid in 0x400:
			if Mem.r8(Mem.person_addr(pid) + 0x2a) != 0xff:
				out.append({"pid": pid, "unit": -1})
		return out
	for s in Mem.UNIT_SLOTS:
		var a := Mem.unit_addr(s)
		var who := Mem.r32(a)
		if who >= 0x400 or Mem.r8(a + 0xc) == 0 or Mem.r8(a + 0xc) == 1:
			continue
		var side := Mem.r8(a + 5)
		if (side < 2) == mine:
			out.append({"pid": who, "unit": a})
	return out


func _value(r: Dictionary, k: int) -> int:
	var p := Game.person(int(r["pid"]))
	var u: int = r["unit"]
	match k:
		0: return int(r["pid"])
		1: return p.cls
		2: return p.level
		3: return p.exp
		4: return Mem.r32(u + 0x10) if u >= 0 else p.max_hp()
		5: return Mem.r32(u + 0x14) if u >= 0 else p.max_mp()
	return p.stat(k - 6)


func _fill() -> void:
	var lv := list(0x402)
	var rows := _rows()
	if sort_col >= 0:
		var c := sort_col
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var ra := int(a["unit"]) >= 0 and Mem.r8(int(a["unit"]) + 0xc) == 3
			var rb := int(b["unit"]) >= 0 and Mem.r8(int(b["unit"]) + 0xc) == 3
			if ra != rb:
				return rb
			var d := _value(a, c) - _value(b, c)
			return d > 0 if sort_desc else d < 0)
	lv.rows.clear()
	for r in rows:
		var p := Game.person(int(r["pid"]))
		var u: int = r["unit"]
		var cells := [TextExpand.display_name(p.id), p.class_name_str(), "%d" % p.level,
			"MAX" if p.exp == 0xff else "%d" % p.exp]
		var hp := p.max_hp()
		var mp := p.max_mp()
		cells.append("%3d/%3d" % [Mem.r32(u + 0x10) if u >= 0 else hp, hp])
		cells.append("%3d/%3d" % [Mem.r32(u + 0x14) if u >= 0 else mp, mp])
		for s in 5:
			cells.append("%d" % p.stat(s))
		lv.rows.append({"cells": cells, "enabled": true, "data": r})
	lv.fit_columns(self)
	lv.scroll(0)
	queue_redraw()


func _on_command(id: Variant) -> void:
	match id:
		0x409, 0x40a:
			var m: bool = id == 0x409
			if m != mine:
				ShopMenu.click_se(0)
				mine = m
				_fill()
		_:
			super._on_command(id)


## Header clicks are not routed by Dlg66 to a virtual: handled here through the press position.
func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		var lv := list(0x402)
		if lv.header_rect().has_point(ev.position):
			var x: float = lv.header_rect().position.x
			for k in lv.columns.size():
				var w: float = lv.columns[k]["w"]
				if ev.position.x < x + w:
					sort_desc = not sort_desc if sort_col == k else false
					sort_col = k
					_fill()
					break
				x += w
			accept_event()
			return
	super._gui_input(ev)


func _on_list_click(_lid: Variant, row: int) -> void:
	var r: Dictionary = list(0x402).rows[row]["data"]
	await StatusPanel.show_person(get_parent() if get_parent() != null else self, Game.person(int(r["pid"])))
