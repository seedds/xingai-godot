class_name StoryStage
extends ScriptHost
## Story (R_###) scene runner after Ekd5.exe's RPG mode: the 640×400 scene view at y = 40 of the 640×480 screen,
## isometric actors (RpgActor), the town toolbar and point-and-click interaction.
##  * Scene picture (0x40bbaf): Mmap.e5 entry = scene byte + 256·EV[4027] (+ 40 for scene kind 2), op 0x27.
##  * The driver polls the script whenever no actor walks (0x41839c); when no section qualifies it waits for the
##    player: a click on an actor runs one poll with GS+0 bit 0x20 set and event slot 1 = the person (0x418162), so
##    sections testing `test_clicked(pid)` fire.
##  * Toolbar (0x419959, dialog 0x129 ×4): 50×50 buttons from the bottom-right corner, button k at
##    (w − 50(k+1), h − 90) unless bit k of EV[4032] hides it — 0 卖出, 1 买进, 2 装备, 3 出征 (click handler 0x4196f8).
##    They are shown only in sortie mode ([0x501fff] = 1, op 0x06); the system menu (the original's menu bar) is the
##    right click / Esc / 菜单.

signal clicked_actor(pid: int)

const VIEW_Y := 40
const TOOLBAR_LABELS := ["卖出", "买进", "装备", "出征"]
const TOOLBAR_ICONS := [341, 342, 343, 344]     # Ekd5.exe RT_BITMAP 48×48 shop buttons 卖出/买进/装备/出兵

var root2d: Node2D
var bg: Sprite2D
var actor_layer: Node2D
var portrait_layer: Node2D
var actors: Dictionary = {}       # pid -> RpgActor
var portraits: Dictionary = {}    # pid -> Sprite2D (fallback when GameUI has no portrait API)
var click_pid := -1
var in_click := false
var scene_kind := -1
var scene_image := -1
var scene_entry := -1
var _waiting_click := false
var _toolbar: Array[Button] = []
var _toolbar_on := false          # 0x419959(tb, 0): buttons shown
var _toolbar_hidden := false      # hidden while a message window is up (0x4137cd) or by op 0x28 0
var _bar_menu: Button
var duel: DuelLayer


func _ready() -> void:
	super._ready()
	root2d = Node2D.new()
	add_child(root2d)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(640, 480)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root2d.add_child(black)
	bg = Sprite2D.new()
	bg.centered = false
	bg.position = Vector2(0, VIEW_Y)
	root2d.add_child(bg)
	# the scene view (640×400 at y = 40) clips actors like the original blitter
	var clip := Control.new()
	clip.position = Vector2(0, VIEW_Y)
	clip.size = Vector2(640, 400)
	clip.clip_contents = true
	clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root2d.add_child(clip)
	actor_layer = Node2D.new()
	actor_layer.position = Vector2(0, -VIEW_Y)
	clip.add_child(actor_layer)
	portrait_layer = Node2D.new()
	portrait_layer.z_index = 2000     # above the actors, whose z_index is their screen y
	root2d.add_child(portrait_layer)
	for k in 4:
		var b := _tool_button(k)
		_toolbar.append(b)
	_bar_menu = _bar_button("菜单", Vector2(572, 8))
	_bar_menu.pressed.connect(func() -> void:
		if _waiting_click:
			_system_menu())


func _tool_button(k: int) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.size = Vector2(50, 50)
	b.position = Vector2(640 - 50 * (k + 1), 480 - 90)
	b.tooltip_text = TOOLBAR_LABELS[k]
	var icon := "gfx/ui/exe/%d.png" % TOOLBAR_ICONS[k]
	if Assets.exists(icon):
		b.icon = Assets.tex(icon)
		b.expand_icon = true
	else:
		b.text = TOOLBAR_LABELS[k]
	var n := UIStyle.panel_box()
	n.set_content_margin_all(1)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = UIStyle.BG2
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.visible = false
	b.pressed.connect(func() -> void:
		if _waiting_click:
			_toolbar_click(k))
	root2d.add_child(b)
	return b


func _bar_button(text: String, pos: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(60, 26)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", Assets.font())
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UIStyle.NAME_COLOR)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	var n := UIStyle.panel_box()
	n.set_content_margin_all(2)
	var h := n.duplicate() as StyleBoxFlat
	h.bg_color = UIStyle.BG2
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", h)
	b.visible = false
	root2d.add_child(b)
	return b


func _process(_d: float) -> void:
	if _bar_menu == null:
		return
	var player := not Game.autoplay and not Game.demo
	_bar_menu.visible = _waiting_click and player and Game.shell == null
	var hide_bits := Mem.ev(4032)
	for k in 4:
		_toolbar[k].visible = _toolbar_on and not _toolbar_hidden and (hide_bits >> k) & 1 == 0 and player
		_toolbar[k].disabled = not _waiting_click


func menu_ready() -> bool:
	return _waiting_click


func open_menu() -> void:
	if _waiting_click:
		_system_menu()


func trace_info() -> String:
	return ""


# ------------------------------------------------------------------ toolbar (0x419959 / 0x429cab / 0x420660)
func toolbar_show(with_buttons: bool) -> void:
	# 0x419959 also re-arms the three first-use flags at 0x496f4c (shop greetings, see _toolbar_click)
	for k in 3:
		Mem.w32(0x496f4c + 4 * k, 1)
	_toolbar_on = with_buttons
	_toolbar_hidden = false


func toolbar_close() -> void:
	_toolbar_on = false


func toolbar_hide_for_dialog() -> void:
	if Mem.r8(0x501fff) != 0:
		_toolbar_hidden = true


## Toolbar click 0x4196f8 (ignored in a battle scene): 0 卖出 → shop sell (0x461cf6(1)), 1 买进 → shop buy
## (0x461cf6(0)), 2 装备 → warehouse / equipment (0x461c88), 3 出征 → the sortie builder 0x418597(1); on success the
## toolbar window is hidden, the menu flag cleared (0x41196c(0)) and the pending flag 0x4ae4c0 set, which the scene's
## own `test_pending` section consumes. (The first-use greeting of buttons 0..2 — "%s，卖掉物资！" etc. by the
## protagonist and "是！" by the shop's person, 0x40c755 — needs the focused actor [0x49cee4], which only the
## free-walk mode sets; free walk (EV[4072]) is off in this mod, so it never shows.)
func _toolbar_click(k: int) -> void:
	_waiting_click = false
	match k:
		0, 1:
			await _shop(k == 0)
		2:
			await PartyMenu.equip_menu(ui)
		3:
			if await do_sortie():
				clicked_actor.emit(-2)
				return
	_waiting_click = true


## Shop 0x461cf6(sell): the UI's shop window (ui/shop_menu.gd) when it exists.
func _shop(sell: bool) -> void:
	if ResourceLoader.exists("res://src/ui/shop_menu.gd"):
		var sm: Variant = load("res://src/ui/shop_menu.gd")
		if sm != null and sm.has_method("run"):
			await sm.run(ui, sell)
			return
	await PartyMenu.item_menu(ui)


func do_sortie() -> bool:
	if not await build_sortie(1):
		return false
	_toolbar_on = false
	set_menu_flag(0)
	Mem.w32(0x4ae4c0, 1)
	return true


## 0x28 自由R启动指令 (0x406fd9): 0 → hide the 4 toolbar buttons (0x429cab); ≠ 0 → [0x501fff] = 0 and the toolbar
## created / positioned without being shown (0x419959(tb, 1)).
func op_op_28(ins: Dictionary) -> void:
	if u16(ins, 0) == 0:
		_toolbar_hidden = true
	else:
		Mem.w8(0x501fff, 0)
		toolbar_show(false)


# ------------------------------------------------------------------ run loop
var _restore: Dictionary = {}


## Run a story script file until it finishes.
func run_file(file: String) -> void:
	vm = EexVM.new()
	vm.host = self
	if not vm.load_script(file):
		return
	if not _restore.is_empty():
		_apply_restore()
	while vm.active and is_inside_tree():
		var ran: bool = await vm.poll()
		if not vm.active or not is_inside_tree():
			break
		if not ran:
			# nothing qualifies: wait for the player (event-loop scenes)
			var pid := await _wait_for_click()
			if pid == -2:
				continue
			await click(pid)
	SoundMap.stop_loop()


## 0x418162: one poll with GS+0 bit 0x20 and event slot 1 = the clicked person, then GS+0 restored.
func click(pid: int) -> void:
	var g := Mem.r8(Mem.GS)
	click_pid = pid
	in_click = true
	Mem.w8(Mem.GS, g | 0x20)
	await vm.poll()
	Mem.w8(Mem.GS, g)
	in_click = false


## 0x2d 武将点击测试 (0x41391a): GS+0 & 0x20 and event slot 1 == person.
func op_test_clicked(ins: Dictionary) -> bool:
	return Mem.r8(Mem.GS) & 0x20 != 0 and click_pid == u16(ins, 0)


var _auto_i := 0


func _wait_for_click() -> int:
	if Game.autoplay or Game.demo:
		if Game.demo:
			await get_tree().create_timer(1.0).timeout
		await get_tree().process_frame
		# only actors a player could click: visible, not hidden via action 18, inside the scene view
		var view := Rect2(0, VIEW_Y, 640, 400)
		var keys := actors.keys().filter(func(k: int) -> bool:
			var a: RpgActor = actors[k]
			return is_instance_valid(a) and a.visible and a.action != 18 and view.intersects(a.screen_rect().grow(-4)))
		_auto_i += 1
		if _auto_i > 2500 and (OS.get_environment("WG_AUTOSAVE") != "" or OS.get_environment("WG_ONEFILE") != ""):
			# flow-test: random clicking is not solving this scene (puzzles, hubs) — end the file
			print("== flow-test: click cap, leaving %s" % vm.name)
			vm.active = false
			return -2
		var sp := OS.get_environment("WG_SORTIE_P")
		var bar := _toolbar_on and not _toolbar_hidden and (Mem.ev(4032) >> 3) & 1 == 0
		if bar and Rules.chance(int(sp) if sp != "" else 12):
			if await do_sortie():
				return -2
		if keys.is_empty():
			if bar and await do_sortie():
				return -2
			await get_tree().create_timer(0.05).timeout
			if _auto_i > 400:
				print("== autoplay: nothing to click in %s scene %d, leaving the file" % [vm.name, vm.scene])
				vm.active = false
			return -2
		# mostly click actors that some section of this scene tests for (like a player would)
		var hot := _clickable_pids().filter(func(x: int) -> bool: return keys.has(x))
		if not hot.is_empty() and Rules.chance(85):
			keys = hot
		var pid: int = keys[Rules.rand(keys.size())] if OS.get_environment("WG_RANDOM") != "" else keys[_auto_i % keys.size()]
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [click] ", pid)
		return pid
	_waiting_click = true
	var r: int = await clicked_actor
	_waiting_click = false
	return r


## Autoplay helper: person ids named by test_clicked conditions in the current scene.
func _clickable_pids() -> Array:
	var out := []
	for sec in vm.sections(vm.scene):
		for c in sec.get("conditions", []):
			if str(c.get("name", "")) == "test_clicked" and not c["args"].is_empty() and c["args"][0] is float:
				var v := int(c["args"][0])
				if not out.has(v):
					out.append(v)
	return out


func _unhandled_input(ev: InputEvent) -> void:
	if not _waiting_click:
		return
	if ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_LEFT:
			var pid := actor_at(ev.position)
			if pid >= 0:
				get_viewport().set_input_as_handled()
				clicked_actor.emit(pid)
		elif ev.button_index == MOUSE_BUTTON_RIGHT:
			get_viewport().set_input_as_handled()
			_system_menu()
	elif ev.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_system_menu()


func actor_at(p: Vector2) -> int:
	if p.y < VIEW_Y or p.y >= VIEW_Y + 400:
		return -1      # outside the scene view, where actors are clipped
	var best := -1
	var best_y := -INF
	for pid in actors:
		var a: RpgActor = actors[pid]
		if not a.visible or a.action == 18:
			continue
		var r := a.screen_rect().grow(-4)
		if r.has_point(p) and a.position.y > best_y:
			best = pid
			best_y = a.position.y
	return best


## The original's menu bar (系统 / 功能) as one menu. 存储进度 follows the save-allowed byte 0x500fff (op 0x74).
func _system_menu() -> void:
	_waiting_click = false
	var items := ["部队状态", "装备", "道具", "历史情报", "存储进度", "读取进度", "回到标题", "练武场"]
	var en := [true, true, true, true, Mem.r8(0x500fff) != 0, true, true, true]
	var i := await ui.menu.choose(items, Vector2(-1, -1), true, "", en)
	match i:
		7:
			await Training.menu(self)
		0:
			await Game.main.show_party_status()
		1:
			await PartyMenu.equip_menu(ui)
		2:
			await PartyMenu.item_menu(ui)
		3:
			await _show_history()
		4:
			await Game.main.save_menu()
		5:
			await Game.main.load_menu()
		6:
			Game.main.to_title()
	_waiting_click = true


## 历史情报 (records 0x509000, op 0x16 with EV[4071]): GameUI's window when it exists, else a plain list.
func _show_history() -> void:
	if ui.has_method("history_window"):
		await ui.history_window()
		return
	var entries := Game.history_entries()
	if entries.is_empty():
		await ui.popup("暂无情报。", 1.0)
		return
	var lines := []
	for h in entries:
		lines.append(TextExpand.expand(str(h["text"])).replace("\n", " ").replace("\r", ""))
	var k := 0
	while true:
		k = await ui.menu.choose(lines, Vector2(-1, -1), true, "历史情报", [], 400, k)
		if k < 0:
			return
		await ui.popup(TextExpand.expand(str(entries[k]["text"])).replace("\r", ""))


# ------------------------------------------------------------------ dialog placement
## Talk-window anchor: the speaker actor's foot point on the 640×480 screen and its facing.
func talk_anchor(pid: int) -> Variant:
	if not actors.has(pid):
		return null
	var a: RpgActor = actors[pid]
	if not is_instance_valid(a):
		return null
	return {"x": a.position.x, "y": a.position.y, "dir": a.dir}


# ------------------------------------------------------------------ scene
## 0x27 背景显示 (0x413d13): stored byte by mode (0: a1; 1: a2 == 0 → 114, a1 == 0xffff → a3 + 40 (a3 == 0xffff →
## 114), else a1; 2: a3; 0xffff → 0); mode 3 = battle map (word 0x510cfe = a4 (0xffff → 99) + 100·EV[4051], EV[4051] =
## 0). 0x428346: scene struct 0x4ac63c = {mode, byte}; the picture is loaded at the next frame (status 2, yield).
func op_change_scene(ins: Dictionary) -> void:
	var mode := u16(ins, 0) & 0xff
	var a1 := u16(ins, 1)
	var a2 := u16(ins, 2)
	var a3 := u16(ins, 3)
	var a4 := u16(ins, 4)
	var v := 0
	match mode:
		0:
			v = 0 if a1 == 0xffff else a1
		1:
			if a2 == 0:
				v = 0x72
			elif a1 == 0xffff:
				v = 0x72 if a3 == 0xffff else a3 + 0x28
			else:
				v = a1
		2:
			v = 0 if a3 == 0xffff else a3
		3:
			var m := 99 if a4 == 0xffff else a4
			Mem.w16(0x510cfe, m + (Mem.ev(4051) & 0xff) * 100)
			Mem.set_ev(4051, 0)
		_:
			await get_tree().process_frame
			return
	Mem.w8(0x4ac63c, mode)
	Mem.w8(0x4ac63d, 0xff if mode == 3 else v & 0xff)
	scene_kind = mode
	scene_image = v & 0xff
	ui.clear_captions()      # the new picture is drawn over the whole view, map texts included
	if mode == 3:
		bg.texture = null
	else:
		_load_scene_picture()
	await get_tree().process_frame


## 0x40bbaf: entry = byte + 256·EV[4027] (+ 40 for kind 2); Mmap.e5 → gfx/backgrounds (index.json `file`).
func _load_scene_picture() -> void:
	var entry := scene_image + 256 * Mem.ev(4027) + (40 if scene_kind == 2 else 0)
	scene_entry = entry
	bg.texture = background_texture(entry)


static var _bg_index: Array = []


static func background_texture(entry: int) -> Texture2D:
	if _bg_index.is_empty():
		var d: Variant = Assets.json("gfx/backgrounds/index.json")
		if d is Dictionary:
			_bg_index = d.get("images", [])
	if entry < 0 or entry >= _bg_index.size():
		entry = 0       # an index past the archive reads entry 0 (0x41fc89)
	if _bg_index.is_empty():
		return null
	return Assets.tex("gfx/backgrounds/" + str(_bg_index[entry]["file"]))


func clear_actors() -> void:
	for pid in actors:
		if is_instance_valid(actors[pid]):
			(actors[pid] as Node).queue_free()
	actors.clear()


func _clear_portraits() -> void:
	for pid in portraits:
		(portraits[pid] as Node).queue_free()
	portraits.clear()


## Pmapobj character of a person: u16 R table 0x50f800[pid] (0x409038).
func _sprite_for(pid: int) -> int:
	if pid >= 0 and pid < 1024:
		return Mem.r16(Mem.R_SPRITE + pid * 2)
	return 0


## 0x30 武将出现 (0x411dae → 0x428c8e(p | 0x1000, x, y, dir & 3, act > 18 → 0)): a person who already has an actor
## is left as it is (0x428969 finds it → nothing).
func op_actor_appear(ins: Dictionary) -> void:
	var pid := u16(ins, 0) & 0xfff
	if actors.has(pid) and is_instance_valid(actors[pid]):
		return
	var act := u16(ins, 4)
	var a := RpgActor.new()
	actor_layer.add_child(a)
	a.setup(pid, _sprite_for(pid), arg(ins, 1), arg(ins, 2), u16(ins, 3) & 3, 0 if act > 18 else act)
	actors[pid] = a


## 0x31 武将消失 (0x413522): the actor of the person is removed (0x428b22).
func op_actor_select(ins: Dictionary) -> void:
	var pid := u16(ins, 1) & 0xfff
	if actors.has(pid):
		if is_instance_valid(actors[pid]):
			(actors[pid] as Node).queue_free()
		actors.erase(pid)


## 0x32 武将移动 (0x4133b2 → 0x429159): when the next instruction is another move it returns at once, so a run of moves
## walks in parallel; the last one yields until no actor walks.
func op_actor_move(ins: Dictionary) -> void:
	var pid := u16(ins, 1) & 0xfff
	var d := u16(ins, 5)
	var end_dir := -1 if d == 0xffff else d
	if actors.has(pid) and is_instance_valid(actors[pid]):
		var a: RpgActor = actors[pid]
		if vm and vm.next_op == 0x32:
			a.walk_to(arg(ins, 3), arg(ins, 4), end_dir, fast or Game.autoplay)
			return
		await a.walk_to(arg(ins, 3), arg(ins, 4), end_dir, fast or Game.autoplay)
	elif vm and vm.next_op == 0x32:
		return
	await _actors_idle()


## 0x1e 武将重绘: the RPG driver resumes only once no actor walks (0x41839c).
func op_wait_frame(_ins: Dictionary) -> void:
	await get_tree().process_frame
	await _actors_idle()


func _actors_idle() -> void:
	while is_inside_tree() and not (vm and vm.abort):
		var busy := false
		for pid in actors:
			var a: Variant = actors[pid]
			if is_instance_valid(a) and (a as RpgActor).walking:
				busy = true
				break
		if not busy:
			return
		await get_tree().process_frame


## 0x33 武将转向 (0x411e79 → 0x428845): action and facing; 0xffff keeps the current one.
func op_actor_face(ins: Dictionary) -> void:
	var pid := u16(ins, 0) & 0xfff
	if actors.has(pid) and is_instance_valid(actors[pid]):
		var a: RpgActor = actors[pid]
		if u16(ins, 2) != 0xffff:
			a.dir = u16(ins, 2) & 3
		a.set_action(a.action if u16(ins, 1) == 0xffff else u16(ins, 1))


## 0x34 武将动作 (0x411ede).
func op_actor_action(ins: Dictionary) -> void:
	var pid := u16(ins, 0) & 0xfff
	if actors.has(pid) and is_instance_valid(actors[pid]):
		(actors[pid] as RpgActor).set_action(u16(ins, 1))


## 0x2f 清除人物 (0x413647 → 0x426c3b): all actors cleared.
func op_op_2f(_ins: Dictionary) -> void:
	clear_actors()


## 0x26 in a story file (0x411f75, unused by the shipped R files): true once when RPG actor 0–24 enters the rect.
func op_test_unit_in_area(_ins: Dictionary) -> bool:
	return false


# ------------------------------------------------------------------ portraits (ops 0x29/0x2a/0x2b, 0x42c4a5…)
func op_op_29(ins: Dictionary) -> bool:
	var pid := u16(ins, 0)
	if pid >= 0x400:
		return false
	if ui.has_method("portrait_show"):
		await ui.portrait_show(pid, arg(ins, 1), arg(ins, 2))
		return true
	if portraits.has(pid):
		(portraits[pid] as Node).queue_free()
	var s := Sprite2D.new()
	s.centered = false
	s.texture = Game.person_face(pid)
	s.position = Vector2(arg(ins, 1), arg(ins, 2))
	portrait_layer.add_child(s)
	portraits[pid] = s
	return true


func op_op_2a(ins: Dictionary) -> bool:
	var pid := u16(ins, 0)
	if pid >= 0x400:
		return false
	if ui.has_method("portrait_move"):
		await ui.portrait_move(pid, arg(ins, 1), arg(ins, 2))
		return true
	if portraits.has(pid):
		var s: Sprite2D = portraits[pid]
		var tw := create_tween()
		tw.tween_property(s, "position", Vector2(arg(ins, 1), arg(ins, 2)), 0.4)
		await tw.finished
	return true


func op_op_2b(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if pid >= 0x400:
		return
	if ui.has_method("portrait_hide"):
		await ui.portrait_hide(pid)
		return
	if portraits.has(pid):
		(portraits[pid] as Node).queue_free()
		portraits.erase(pid)


func on_field_written(field: int, id: int) -> void:
	# R image (field 0 / op 0x35) changed: refresh an on-screen actor
	if field == 0 and actors.has(id) and is_instance_valid(actors[id]):
		(actors[id] as RpgActor).set_sprite(_sprite_for(id))


# ------------------------------------------------------------------ duel outside a battle
## Classic duel (System A) hosted by the story scene; 0x5f restores the R scene afterwards (0x411991).
func story_duel(a: int, b: int, backdrop: int) -> void:
	duel = DuelLayer.attach(self)
	await duel.setup(a, b, backdrop)


func op_duel_say(ins: Dictionary) -> void:
	if duel:
		await duel.appear_say(u16(ins, 0), TextExpand.expand(sarg(ins, 1)), u16(ins, 2))


func op_duel_end(_ins: Dictionary) -> void:
	if duel:
		await duel.open()


func op_duel_start(_ins: Dictionary) -> void:
	if duel:
		await duel.close()
		duel = null
	toolbar_reshow_if_menu()


func op_duel_say2(ins: Dictionary) -> void:
	if duel:
		await duel.say2(u16(ins, 0), TextExpand.expand(sarg(ins, 1)), u16(ins, 2))


func op_duel_action(ins: Dictionary) -> void:
	if duel:
		await duel.action(u16(ins, 0), u16(ins, 1))


func op_duel_action2(ins: Dictionary) -> void:
	if duel:
		await duel.exchange(u16(ins, 0), u16(ins, 1), u16(ins, 2))


func op_duel_action3(ins: Dictionary) -> void:
	if duel:
		await duel.special(u16(ins, 0), u16(ins, 1), u16(ins, 2))


func op_duel_62(ins: Dictionary) -> void:
	if duel:
		await duel.result(u16(ins, 0))


# ------------------------------------------------------------------ save / restore
func save_state() -> Dictionary:
	var acts := []
	for pid in actors:
		var a: RpgActor = actors[pid]
		if is_instance_valid(a):
			acts.append([pid, a.sprite_id, a.gx, a.gy, a.dir, a.action])
	return {"kind": "story", "scene": vm.scene if vm else 0, "scene_kind": scene_kind, "scene_image": scene_image,
		"actors": acts, "bgm": Audio.current_track, "toolbar": _toolbar_on}


func restore_state(d: Dictionary) -> void:
	_restore = d


func _apply_restore() -> void:
	var d := _restore
	_restore = {}
	if d.get("kind", "") != "story":
		return
	vm.scene = int(d.get("scene", 0))
	var mode := int(d.get("scene_kind", -1))
	if mode >= 0 and mode != 3:
		scene_kind = mode
		scene_image = int(d.get("scene_image", 0))
		_load_scene_picture()
	for e in d.get("actors", []):
		var a := RpgActor.new()
		actor_layer.add_child(a)
		a.setup(int(e[0]), int(e[1]), int(e[2]), int(e[3]), int(e[4]), int(e[5]))
		actors[int(e[0])] = a
	_toolbar_on = bool(d.get("toolbar", false))
	if int(d.get("bgm", -1)) >= 0:
		Audio.play_bgm(int(d["bgm"]))
	ui.set_black(false)
