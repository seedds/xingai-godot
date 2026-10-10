extends Node
## Screenshots of the 6.6 menus (run with a window): OUT=dir TEST=res://src/debug/t_menu66_shots.gd
## godot --path . res://src/debug/test_runner.tscn. Prints "t_menu66_shots: done".

var out := ""
var n := 0


func shot(tag: String) -> void:
	for k in 3:
		await get_tree().process_frame
	n += 1
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%02d_%s.png" % [out, n, tag])


func show(d: Control, tag: String) -> void:
	add_child(d)
	await shot(tag)
	d.queue_free()
	await get_tree().process_frame


func run() -> void:
	out = OS.get_environment("OUT")
	if out == "":
		out = "/tmp/menu66"
	DirAccess.make_dir_recursive_absolute(out)
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.25, 0.1)
	bg.size = Vector2(640, 480)
	add_child(bg)
	Game.new_game_state()
	Game.scenario = 4
	for pid in [0, 1, 2, 3, 4]:
		Game.join(pid, 1, 0x65)
	Game.gold = 23456
	Game.bag_put(1, 4, 20)
	Game.bag_put(70, 2, 50)
	Game.bag_put(110, 0xff, 0xff)
	Mem.w8(0x493a50 + 161, 3)
	Mem.w8(0x493a50 + 160, 1)
	var b: Dlg66 = ShopMenu.BuyDlg.new()
	b.build()
	b.list(0x5b1).sel = 0
	b.panel.preview(b.list(0x5b1).rows[0]["data"])
	await show(b, "buy_weapons")
	b = ShopMenu.BuyDlg.new()
	b.build()
	b._tab(1)
	await show(b, "buy_items")
	var s: Dlg66 = ShopMenu.SellDlg.new()
	s.build()
	await show(s, "sell")
	var e := EquipDlg66.new()
	e.build()
	await show(e, "equip")
	var il := ItemList66.new()
	il.build()
	await show(il, "itemlist")
	for t in 3:
		var st := StatusPanel.new()
		st.pids = [0, 1]
		st.build()
		st._tab(t)
		await show(st, "status_%d" % t)
	var ii := ItemInfo66.new()
	ii.iid = 40
	ii.lvl = 3
	ii.xp = 50
	ii.build()
	await show(ii, "iteminfo")
	var c: Dlg66 = ShopMenu.CountDlg.new()
	c.maxn = 25
	c.build()
	await show(c, "count")
	# the shop person's question
	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(holder)
	ShopMenu.say(holder, 0, "短剑的价格是500。\n要买进吗？", 1)
	await shot("say")
	print("t_menu66_shots: done")
