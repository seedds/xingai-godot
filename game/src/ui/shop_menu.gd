class_name ShopMenu
extends RefCounted
## The R-scene shop (toolbar 0x4196f8: 卖出 → 0x461cf6(1), 买进 → 0x461cf6(0)): dialog 327 买进 (proc 0x46ce1c →
## 0x46aa02) and dialog 329 卖出 (0x46ceae → 0x46b7ce).
## Goods: the shop record of the current file number f = min(GS+6 / 2, 127) (0x415e13 → 0x41b7e0; Data.e5 shops).
##  * 武器店 (0x466ad4 / 0x472bfd): 16 rows; with byte EV[4088] = 0 (the automatic shop) rows 0..12 are the default
##    items of each weapon / armour kind (table 0x482427) plus a tier for the party's average level (> 17: +1, > 37:
##    +2), rows 13..15 the shop's equipment 0..2; with EV[4088] ≠ 0 the shop's 16 equipment ids. Level 1, exp 0.
##  * 道具店 (0x466bff): the shop's 16 items up to the first empty one, then the extra goods of 0x466c7e: EV[4092]
##    (≤ 5) items from 200, EV[4091] + 1 (≤ 3) groups of EV[4090] (≤ 6) items from 208 + 6k, EV[4089] (≤ 3) items
##    from 205.
## Buying equipment (0x4684cc + 0x468d7e) needs a person who can use it (column 装备 ○); the shop's person says the
## price, and on 是 the money is paid and the item is worn at once — the old one going to the warehouse (0x468cdc,
## refused with "仓库的装备已经爆满！" when the warehouse holds 200). Items (0x4688f0): the 输入数值 count dialog (at most
## 255 − held and what the money buys), then count += n. Selling (0x46b0ce / 0x46b479): equipment one by one after
## the person's question (some equipment of level ≥ 3 brings consumables as a bonus, 0x40d514); items with the
## count dialog.

const SHOP_TABS := ["武器店", "道具店"]           # 0x486c47 / 0x486c50


## Entry point (toolbar): `sell` = 卖出.
static func run(ui: GameUI, sell: bool) -> void:
	if Game.autoplay:
		return
	var d: Dlg66 = SellDlg.new() if sell else BuyDlg.new()
	d.call("build")
	await Dlg66.run_dialog(ui, d)


## The file's shop record: [a (u16), b (u16), 16 equipment, 16 items] from shops.json's raw bytes.
static func shop_record() -> PackedByteArray:
	var f := mini(Mem.r16(Mem.GS + 6) >> 1, 127)
	var recs: Array = Game.shops_db
	if f >= recs.size():
		return PackedByteArray()
	var hex := str(recs[f].get("raw", ""))
	return hex.hex_decode()


## Shop person 0x40c755(k): f ≠ 127 → the shop record's person a (k = 0) / b (k = 1); f = 127 → u16 0x510cfa /
## 0x510cfc (0x72 sub 7).
static func shop_person(k: int) -> int:
	var f := mini(Mem.r16(Mem.GS + 6) >> 1, 127)
	if f == 127:
		return Mem.r16(0x510cfa if k == 0 else 0x510cfc)
	var raw := shop_record()
	if raw.size() < 4:
		return 0
	return raw.decode_u16(0 if k == 0 else 2)


## 0x472bfd(shop, k).
static func shop_equipment(k: int) -> int:
	var raw := shop_record()
	if Mem.r8(Mem.EV + 4 * 4088) == 0:
		var avg := Game.party_avg_level()
		var tier := 0
		if avg > 0x11:
			tier = 1
			if avg > 0x25:
				tier = 2
		if k < 13:
			var v := Mem.r8(0x482427 + k)
			return v if v == 0xff else (v + tier) & 0xff
		k -= 13
	return raw[4 + k] if raw.size() > 4 + k else 0xff


## 0x466c7e: the extra goods.
static func extra_items() -> Array:
	var out := []
	var n := Mem.r8(Mem.EV + 4 * 4092)
	for i in mini(n, 5):
		out.append(200 + i)
	var g := Mem.r8(Mem.EV + 4 * 4090)
	if g != 0:
		for k in mini(Mem.r8(Mem.EV + 4 * 4091) + 1, 3):
			for i in mini(g, 6):
				out.append(208 + 6 * k + i)
	n = Mem.r8(Mem.EV + 4 * 4089)
	for i in mini(n, 3):
		out.append(205 + i)
	while out.size() < 12:
		out.append(0xff)
	return out.slice(0, 12)


## 0x466bff.
static func shop_items() -> Array:
	var raw := shop_record()
	var extra := extra_items()
	var out := []
	var xi := 0
	for k in 42:
		var iid := 0xff
		if k < 16 and xi == 0 and raw.size() > 20 + k and raw[20 + k] != 0xff:
			iid = raw[20 + k]
		elif xi < extra.size():
			iid = int(extra[xi])
			xi += 1
		if iid != 0xff:
			out.append(iid)
	return out


## The shop person's message 0x46d9a4(…, person, text, style) from the toolbar (the toolbar exists, so not the plain
## Win32 boxes): the person's portrait and the parchment box (dialog 0x159 '透明', drawn by 0x46d424 as the talk
## window: name at column 0x13, lines from y + 0x33, 20 px apart, ≤ 4 lines) — style 0 waits for a click
## (0x46d4d7); styles 1 / 2 add the 346 确认 是 / 否 dialog (0x46dc1c). [G] placed like the talk window's lower
## position (y 0x138), the 是 / 否 dialog centred.
static func say(owner: Control, pid: int, text: String, style: int) -> bool:
	if Game.autoplay:
		return style != 0
	var win := Win66.new()
	owner.add_child(win)
	var y := 0x138
	Windows66._portrait_box(win, pid, 8, y, 1, true)
	var st := {"c": Text66.C_TEXT, "open": false}
	var ly := y + 0x30
	var ls := Text66.lines(text.replace("\r", ""))
	for k in mini(ls.size(), 4):
		win.text_line(0x13 * 8.0, ly, ls[k], st)
		ly += 0x14
	await win.type_page(Text66.speed() != 0)
	var res := true
	if style == 0:
		await win.page_wait()
	else:
		var dlg := SysDialog66.new()
		owner.add_child(dlg)
		res = await dlg.run("确认", "", ["是", "否"])
		dlg.queue_free()
	win.queue_free()
	return res


## UI sound 0x4746ad(n) = sound effect n once.
static func click_se(n: int) -> void:
	SoundMap.play_se_id(n, 1)


## Dialog 320 输入数值 (0x46dd57 / 0x46dc1c): "Count ( 1- max )∶" with an edit box and up / down; OK returns the count,
## 取消 0.
static func ask_count(owner: Control, maxn: int) -> int:
	if maxn <= 0:
		return 0
	if Game.autoplay:
		return 1
	var d := CountDlg.new()
	d.maxn = maxn
	d.build()
	owner.add_child(d)
	var r: Variant = await d.closed
	d.queue_free()
	return int(r) if r != null else 0


# ------------------------------------------------------------------ 买进 (327)
class BuyDlg:
	extends Dlg66
	var panel := PersonPanel66.new()
	var eq_rows: Array = []
	var it_rows: Array = []

	func build() -> void:
		setup("买进", 452, 258)
		add_group(2, 3, 235, 235, "商品列表")
		add_tab(0x56d, 6, 12, 226, 223, ShopMenu.SHOP_TABS)
		var l1 := add_list(0x5b1, 9, 27, 224, 204)
		for k in [0, 3, 8, 5, 0xb, 7, 6]:
			l1.columns.append(ItemText66.column(k, self))
		var l2 := add_list(0x3eb, 9, 27, 224, 204)
		for k in [0, 4, 5, 0xb, 6]:
			l2.columns.append(ItemText66.column(k, self))
		add_static(null, 86, 245, 19, 8, "现金", 2)
		add_static(0x475, 107, 244, 30, 10, "", 2, true)
		add_button(2, 169, 241, 41, 15, "结束")
		add_line(240, 2, 1, 238)
		panel.build(self, {
			"combo": [244, 6, 100], "face": [244, 25, 80, 80], "lv_label": [350, 8, 8, 8], "lv": [359, 8, 11, 9],
			"cls": [254, 108, 60, 10], "stat_label_x": 252, "stat_x": 274, "stat_w": 20, "plus_x": 296, "plus_w": 18,
			"stat_ys": [121, 134, 147, 160, 173, 186, 199, 212],
			"slots": [
				{"title": [329, 27, 69, 8], "icon": [329, 39, 23, 23], "lvl_lbl": [354, 41, 8, 8], "lvl": [366, 41, 8, 8],
					"exp_lbl": [377, 41, 12, 8], "bar": [392, 41, 52, 8], "e": [354, 53, 92, 8], "b": [329, 65, 63, 8],
					"frame": [326, 25, 124, 51]},
				{"title": [329, 81, 63, 8], "icon": [329, 93, 20, 20], "lvl_lbl": [354, 95, 8, 8], "lvl": [366, 95, 8, 8],
					"exp_lbl": [377, 95, 12, 8], "bar": [392, 95, 52, 8], "e": [354, 107, 63, 8], "b": [329, 119, 63, 8],
					"frame": [326, 79, 124, 51]},
				{"title": [329, 135, 63, 8], "icon": [329, 147, 20, 20], "b": [329, 173, 63, 8],
					"frame": [326, 133, 124, 51]}],
			"desc": [326, 187, 124, 69], "skills": null, "prev": [222, 241, 48, 15], "next": [273, 241, 48, 15]})
		_fill()
		_tab(0)

	## 0x466ad4 / 0x466bff and the per-person usability (0x46871c).
	func _fill() -> void:
		eq_rows.clear()
		for k in 16:
			var iid := ShopMenu.shop_equipment(k)
			if iid == 0xff:
				continue
			eq_rows.append({"item": iid, "lvl": 1, "exp": 0, "k": k})
		it_rows.clear()
		for iid in ShopMenu.shop_items():
			it_rows.append({"item": iid, "lvl": 0, "exp": 0})
		_refresh_rows()

	func _refresh_rows() -> void:
		var p := panel.person()
		var gold := Game.gold
		var l1 := list(0x5b1)
		l1.rows.clear()
		for r in eq_rows:
			r["usable"] = p != null and Game._can_use(p, int(r["item"]))
			var cells := []
			for c in l1.columns:
				cells.append(ItemText66.cell(int(c["kind"]), r))
			# 0x468877: usable (0x467131) and the price within the money
			var on: bool = r["usable"] and ItemText66.buy_price(int(r["item"])) <= gold
			l1.rows.append({"cells": cells, "icon": ItemText66.small_icon(int(r["item"])), "enabled": on, "data": r})
		var l2 := list(0x3eb)
		l2.rows.clear()
		for r in it_rows:
			var cells2 := []
			for c in l2.columns:
				cells2.append(ItemText66.cell(int(c["kind"]), r))
			l2.rows.append({"cells": cells2, "icon": ItemText66.small_icon(int(r["item"])),
				"enabled": ItemText66.buy_price(int(r["item"])) <= gold, "data": r})
		for lv in [l1, l2]:
			lv.fit_columns(self)
			lv.scroll(0)
		set_text(0x475, "%d" % gold)
		queue_redraw()

	## 0x46af6e: tab 0 shows the 武器店 list with the person panel, tab 1 the 道具店 list with the panel disabled.
	func _tab(i: int) -> void:
		ctrl(0x56d)["sel"] = i
		show_ctrl(0x5b1, i == 0)
		show_ctrl(0x3eb, i == 1)
		panel.set_enabled(i == 0)

	func _on_tab(_id: Variant, i: int) -> void:
		ShopMenu.click_se(0)                                # 0x46af6e: a tab change while visible
		_tab(i)

	func _on_combo(id: Variant, i: int) -> void:
		if id == 0x44a:
			ShopMenu.click_se(0)                            # 0x469ecb (a user's change)
			panel.select(i)
			_refresh_rows()

	func _on_command(id: Variant) -> void:
		match id:
			0x403:
				panel.step(-1)
				_refresh_rows()
			0x404:
				panel.step(1)
				_refresh_rows()
			_:
				super._on_command(id)

	func _on_list_select(lid: Variant, row: int) -> void:
		if lid == 0x5b1:
			panel.preview(list(0x5b1).rows[row]["data"])

	func _on_list_click(lid: Variant, row: int) -> void:
		var r: Dictionary = list(lid).rows[row]["data"]
		ShopMenu.click_se(0)                                # 0x4746ad(0) (0x4684cc / 0x468bd1)
		if lid == 0x5b1:
			await _buy_equipment(r)
		else:
			await _buy_items(r)
		_refresh_rows()

	## 0x4684cc + 0x468d7e.
	func _buy_equipment(r: Dictionary) -> void:
		var p := panel.person()
		if p == null or not bool(r.get("usable", false)):
			return
		var iid := int(r["item"])
		var price := ItemText66.buy_price(iid)
		var slot := ItemText66.category(iid)
		var cur := Mem.r8(p.base + 0x2e + 3 * slot)
		if cur != 0xff and ItemText66.bag_count() > 199:
			await ShopMenu.say(self, ShopMenu.shop_person(0), "仓库的装备已经爆满！", 0)
			return
		var yes := await ShopMenu.say(self, ShopMenu.shop_person(1), "%s的价格是%d。\n要买进吗？" % [ItemText66.name(iid), price], 1)
		if not yes:
			return
		Game.gold = maxi(Game.gold - price, 0)            # 0x40d7ee
		if cur != 0xff:
			if not Game.bag_put(cur, Mem.r8(p.base + 0x2f + 3 * slot), Mem.r8(p.base + 0x30 + 3 * slot)):
				return
		var b := p.base + 0x2e + 3 * slot
		Mem.w8(b, iid)                                      # 0x41ca49(person, slot, item, 1, 0)
		if slot != 2:
			Mem.w8(b + 1, int(r["lvl"]))
			Mem.w8(b + 2, int(r["exp"]))
		panel.refresh_slot(slot)
		panel.preview(r)

	## 0x4688f0: count dialog, at most 255 − held and what the money buys.
	func _buy_items(r: Dictionary) -> void:
		var iid := int(r["item"])
		var price := ItemText66.buy_price(iid)
		var held := Mem.r8(0x493a50 + iid)
		var maxn := 255 - held
		var gold := Game.gold
		if price > 0 and gold < price * maxn:
			maxn = gold / price
		var n := await ShopMenu.ask_count(self, maxn)
		if n < 1:
			return
		Mem.w8(0x493a50 + iid, (held + n) & 0xff)          # 0x421894
		Game.gold = maxi(gold - price * n, 0)


# ------------------------------------------------------------------ 卖出 (329)
class SellDlg:
	extends Dlg66
	var eq_rows: Array = []
	var it_rows: Array = []

	func build() -> void:
		setup("卖出", 317, 227)
		add_group(2, 2, 312, 204, "仓库列表")
		add_tab(0x56e, 6, 11, 304, 192, ShopMenu.SHOP_TABS)
		var l1 := add_list(0x5b1, 7, 26, 302, 175)
		for k in [0, 3, 1, 2, 5, 9]:
			l1.columns.append(ItemText66.column(k, self))
		var l2 := add_list(0x3eb, 7, 26, 287, 175)
		for k in [0, 4, 5, 0xb, 9]:
			l2.columns.append(ItemText66.column(k, self))
		add_static(null, 108, 213, 25, 8, "现金", 2)
		add_static(0x475, 135, 212, 28, 10, "", 2, true)
		add_button(2, 267, 209, 41, 15, "结束")
		_fill()
		_tab(0)

	## 0x46681b (the warehouse, slot order) and 0x466a6c (items with a count).
	func _fill() -> void:
		eq_rows.clear()
		for i in Game.BAG_SLOTS:
			var a := Game.BAG + 3 * i
			if Mem.r8(a) != 0xff:
				eq_rows.append({"item": Mem.r8(a), "lvl": Mem.r8(a + 1), "exp": Mem.r8(a + 2), "slot": i})
		it_rows.clear()
		for iid in 0x160:
			if iid < 0xff and Mem.r8(0x493a50 + iid) != 0:
				it_rows.append({"item": iid, "lvl": 0, "exp": 0})
		var l1 := list(0x5b1)
		l1.rows.clear()
		for r in eq_rows:
			l1.rows.append(_row(l1, r))
		var l2 := list(0x3eb)
		l2.rows.clear()
		for r in it_rows:
			l2.rows.append(_row(l2, r, true))
		for lv in [l1, l2]:
			lv.fit_columns(self)
			lv.scroll(0)
			lv.sel = mini(lv.sel, lv.rows.size() - 1)
		set_text(0x475, "%d" % Game.gold)
		queue_redraw()

	## Rows are enabled when the item can be sold (0x46b41f / 0x46b742: price byte ≠ 0xff).
	func _row(lv: Dlg66.ListView, r: Dictionary, items := false) -> Dictionary:
		var cells := []
		for c in lv.columns:
			cells.append(ItemText66.cell(int(c["kind"]), r))
		var price := ItemText66.sell_price(int(r["item"]), 0 if items else int(r["lvl"]))
		return {"cells": cells, "icon": ItemText66.small_icon(int(r["item"])), "enabled": price >= 0, "data": r}

	func _tab(i: int) -> void:
		ctrl(0x56e)["sel"] = i
		show_ctrl(0x5b1, i == 0)
		show_ctrl(0x3eb, i == 1)

	func _on_tab(_id: Variant, i: int) -> void:
		ShopMenu.click_se(0)                                # 0x46b9dc
		_tab(i)

	func _on_list_click(lid: Variant, row: int) -> void:
		var r: Dictionary = list(lid).rows[row]["data"]
		ShopMenu.click_se(0)                                # 0x4746ad(0) (0x46b3da / 0x46b671)
		if lid == 0x5b1:
			await _sell_equipment(r)
		else:
			await _sell_items(r)
		_fill()

	## 0x46b0ce.
	func _sell_equipment(r: Dictionary) -> void:
		var iid := int(r["item"])
		var lvl := int(r["lvl"])
		var price := ItemText66.sell_price(iid, lvl)
		if price < 0:
			return
		var text := ""
		if ItemText66.category(iid) == 2:
			text = "%s的价格为%d。\n要卖掉吗？" % [ItemText66.name(iid), price]
		else:
			text = "Lv.%2d的%s可卖%d。\n要卖掉吗？" % [lvl, ItemText66.name(iid), price]
		if not await ShopMenu.say(self, ShopMenu.shop_person(1), text, 2):
			return
		Game.gold = mini(Game.gold + price, 999999)           # 0x40da71
		var slot := int(r["slot"])
		if slot < 200:
			Game.remove_bag_slot(slot)                         # 0x41606a
			# 0x40d514: plain (non-treasure) equipment of level ≥ 3 brings (level − 1) / 2 consumables of its kind
			var t := int(ItemText66.it(iid).get("type", 0))
			if ItemText66.is_equipment(iid) and not ItemText66.is_treasure(iid) and Mem.r8(Mem.EV + 4 * 4039) == 0 \
					and lvl >= 3 and t <= 0x18:
				var bonus := Mem.r8(0x40d597 + (t >> 1))
				var n := (lvl - 1) >> 1
				await ShopMenu.say(self, ShopMenu.shop_person(1), "商人好像对Lv.%2d的\n%s非常中意，所以\n又给了我们%d个%s。" %
						[lvl, ItemText66.name(iid), n, ItemText66.name(bonus)], 0)
				for k in n:
					var c := 0x493a50 + bonus
					if Mem.r8(c) != 0xff:
						Mem.w8(c, Mem.r8(c) + 1)

	## 0x46b479.
	func _sell_items(r: Dictionary) -> void:
		var iid := int(r["item"])
		var price := ItemText66.sell_price(iid, 0)
		if price < 0:
			return
		var held := Mem.r8(0x493a50 + iid)
		var n := await ShopMenu.ask_count(self, held)
		if n < 1:
			return
		Mem.w8(0x493a50 + iid, held - n)
		Game.gold = mini(Game.gold + price * n, 999999)


# ------------------------------------------------------------------ 输入数值 (320)
class CountDlg:
	extends Dlg66
	var maxn := 1
	var value := 1

	func build() -> void:
		setup("输入数值", 140, 53)
		add_static(0x59c, 11, 11, 69, 8, "Count ( 1-%3d )∶" % maxn, 2)
		add_static(0x59d, 82, 7, 29, 16, "1", 2, true)
		add_button(0x59e, 112, 7, 14, 8, "▲")
		add_button(0x59f, 112, 15, 14, 8, "▼")
		add_button(1, 15, 32, 50, 14, "OK")
		add_button(2, 73, 32, 50, 14, "取消")

	func _set_value(v: int) -> void:
		value = clampi(v, 1, maxn)
		set_text(0x59d, "%d" % value)

	func _on_command(id: Variant) -> void:
		match id:
			1:
				close(value)
			2:
				close(0)
			0x59e:
				_set_value(value + 1)
			0x59f:
				_set_value(value - 1)

	func _on_key(ev: InputEvent) -> void:
		if ev.is_action_pressed("ui_up") or ev.is_action_pressed("ui_right"):
			_set_value(value + 1)
		elif ev.is_action_pressed("ui_down") or ev.is_action_pressed("ui_left"):
			_set_value(value - 1)
		elif ev.is_action_pressed("ui_accept"):
			close(value)
		elif ev is InputEventKey and ev.unicode >= 0x30 and ev.unicode <= 0x39:
			var nv: int = value * 10 + (ev.unicode - 0x30)
			_set_value(nv if nv <= maxn else ev.unicode - 0x30)
