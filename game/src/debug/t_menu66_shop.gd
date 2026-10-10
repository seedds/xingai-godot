extends Node
## Shop / equipment / item-list / 武将情报 dialogs of the 6.6 port: buying and selling change gold, the bag, the worn
## items and the consumable counts as the original's handlers do (0x4684cc / 0x4688f0 / 0x46b0ce / 0x46b479 /
## 0x46bc8d / 0x46befb / 0x43ee4c). Prints "t_menu66_shop: PASS" or FAIL lines.

var ok := true


func check(name: String, got: Variant, want: Variant) -> void:
	if str(got) != str(want):
		ok = false
		print("FAIL %s: got %s want %s" % [name, got, want])


func run() -> void:
	Game.new_game_state()
	Game.autoplay = true                       # shop person answers 是, count dialogs answer 1
	Game.scenario = 4                          # file 2: shop record 2
	for pid in [0, 1, 2, 3]:
		Game.join(pid, 1, 0x65)
	Game.gold = 50000
	var p := Game.person(0)
	# ---- 买进: the first equipment row the protagonist can use
	var buy: Dlg66 = ShopMenu.BuyDlg.new()
	buy.build()
	add_child(buy)
	var rows: Array = buy.list(0x5b1).rows
	check("weapon rows", rows.size() > 0, true)
	var row: Dictionary = {}
	for r in rows:
		if r["enabled"]:
			row = r["data"]
			break
	check("a usable row", row.is_empty(), false)
	print("weapon shop: %d rows, buying %s; item shop: %d rows" % [rows.size(), ItemText66.name(int(row.get("item", 0xff))),
			buy.list(0x3eb).rows.size()])
	for r in rows.slice(0, 4):
		print("  ", r["cells"], " enabled=", r["enabled"])
	if not row.is_empty():
		var iid := int(row["item"])
		var slot := ItemText66.category(iid)
		var old := Mem.r8(p.base + 0x2e + 3 * slot)
		var price := ItemText66.buy_price(iid)
		var bag0 := ItemText66.bag_count()
		await buy._buy_equipment(row)
		check("gold after buying", Game.gold, 50000 - price)
		check("worn after buying", Mem.r8(p.base + 0x2e + 3 * slot), iid)
		check("bought level", Mem.r8(p.base + 0x2f + 3 * slot) if slot < 2 else 1, 1)
		check("old item to the warehouse", ItemText66.bag_count(), bag0 + (1 if old != 0xff else 0))
	# ---- 道具店
	var irows: Array = buy.list(0x3eb).rows
	if not irows.is_empty():
		var ir: Dictionary = irows[0]["data"]
		var iid2 := int(ir["item"])
		var before := Mem.r8(0x493a50 + iid2)
		var g0 := Game.gold
		await buy._buy_items(ir)
		check("item count +1", Mem.r8(0x493a50 + iid2), before + 1)
		check("gold after item", Game.gold, g0 - ItemText66.buy_price(iid2))
	buy.queue_free()
	# ---- 卖出
	Game.bag_put(1, 4, 20)                      # 长剑 Lv 4 → sells with a bonus (level ≥ 3)
	var sell: Dlg66 = ShopMenu.SellDlg.new()
	sell.build()
	add_child(sell)
	var srow: Dictionary = {}
	for r in sell.list(0x5b1).rows:
		if int(r["data"]["item"]) == 1:
			srow = r["data"]
	check("sell row", srow.is_empty(), false)
	if not srow.is_empty():
		var g1 := Game.gold
		var sp := ItemText66.sell_price(1, 4)
		var bonus := Mem.r8(0x40d597 + (int(Game.item(1)["type"]) >> 1))
		var cnt := Mem.r8(0x493a50 + bonus)
		await sell._sell_equipment(srow)
		check("gold after selling", Game.gold, g1 + sp)
		check("bag slot freed", Mem.r8(Game.BAG + 3 * int(srow["slot"])), 0xff)
		check("sell bonus (Lv 4 → 1)", Mem.r8(0x493a50 + bonus), cnt + 1)
	var it_rows: Array = sell.list(0x3eb).rows
	if not it_rows.is_empty():
		var ir2: Dictionary = it_rows[0]["data"]
		var iid3 := int(ir2["item"])
		var c0 := Mem.r8(0x493a50 + iid3)
		var g2 := Game.gold
		await sell._sell_items(ir2)
		check("item sold", Mem.r8(0x493a50 + iid3), c0 - 1)
		check("gold after item sale", Game.gold, mini(g2 + ItemText66.sell_price(iid3, 0), 999999))
	sell.queue_free()
	# ---- 装备
	var eqd := EquipDlg66.new()
	eqd.build()
	add_child(eqd)
	var w := Mem.r8(p.base + 0x2e)
	if w != 0xff:
		var n0 := ItemText66.bag_count()
		await eqd._on_pic(0x590, MOUSE_BUTTON_LEFT)
		check("unequip to warehouse", Mem.r8(p.base + 0x2e), 0xff)
		check("warehouse +1", ItemText66.bag_count(), n0 + 1)
		# equip it again from the list
		var lv := eqd.list(0x5b1)
		for i in lv.rows.size():
			if int(lv.rows[i]["data"]["item"]) == w and lv.rows[i]["enabled"]:
				lv.sel = i
				await eqd._on_list_click(0x5b1, i)
				break
		check("equip from warehouse", Mem.r8(p.base + 0x2e), w)
	EquipDlg66.record_default(0)
	EquipDlg66.auto_equip(3)
	check("卸除装备", Mem.r8(p.base + 0x2e), 0xff)
	EquipDlg66.auto_equip(2)
	check("自动装备 (default restored)", Mem.r8(p.base + 0x2e), w)
	eqd.queue_free()
	# ---- 道具一览 / 武将情报 build without errors
	var il := ItemList66.new()
	il.build()
	add_child(il)
	check("item list rows", il.list(0x5b1).rows.size() > 0, true)
	il.queue_free()
	var st := StatusPanel.new()
	st.pids = [0, 1]
	st.idx = 0
	st.build()
	add_child(st)
	check("status name", st.ctrl(0x3f6)["text"], TextExpand.display_name(0))
	st._on_command(0x404)
	check("status next", st.pid, 1)
	st.queue_free()
	var ul := UnitList66.new()
	ul.build()
	add_child(ul)
	check("unit list rows", ul.list(0x402).rows.size(), Game.party_ids().size())
	ul.sort_col = 2
	ul._fill()
	ul.queue_free()
	print("t_menu66_shop: %s" % ("PASS" if ok else "FAIL"))
