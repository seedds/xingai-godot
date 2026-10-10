class_name StoryStage
extends ScriptHost
## Story (R_xx) scene runner: 640x400 scene view at y=40 of the 640x480 screen,
## isometric actors, portraits, captions, and point-and-click interaction.

signal clicked_actor(pid: int)

const VIEW_Y := 40

var root2d: Node2D
var bg: Sprite2D
var actor_layer: Node2D
var portrait_layer: Node2D
var actors: Dictionary = {}       # pid -> RpgActor
var portraits: Dictionary = {}    # pid -> Sprite2D
var interactive := false
var click_pid := -1
var in_click := false
var scene_kind := -1
var scene_image := -1
var _waiting_click := false
var sortie_enabled := false
var _bar_menu: Button
var _bar_sortie: Button


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
	# the scene view (640x400 at y=40) clips actors like the original blitter
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
	# the original's town toolbar sits outside the scene view; here: buttons in the top black bar,
	# shown while the scene waits for the player (same as right click / Esc)
	_bar_menu = _bar_button("菜单", Vector2(572, 8))
	_bar_menu.pressed.connect(func() -> void:
		if _waiting_click:
			_system_menu())
	_bar_sortie = _bar_button("出征", Vector2(504, 8))
	_bar_sortie.pressed.connect(func() -> void:
		if _waiting_click and sortie_enabled:
			_menu_sortie())


func menu_ready() -> bool:
	return _waiting_click


func open_menu() -> void:
	if _waiting_click:
		_system_menu()


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
	var show := _waiting_click and not Game.autoplay and not Game.demo
	_bar_menu.visible = show
	_bar_sortie.visible = show and sortie_enabled


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
		if not vm.active:
			break
		if not ran:
			# Nothing qualifies: wait for the player to click an actor (event-loop scenes).
			var pid := await _wait_for_click()
			if pid == -2:
				continue
			click_pid = pid
			in_click = true
			Mem.w16(Mem.GS, Mem.r16(Mem.GS) | 0x20)
			await vm.poll()
			Mem.w16(Mem.GS, Mem.r16(Mem.GS) & ~0x20)
			in_click = false
			click_pid = -1
	SoundMap.stop_loop()


var _auto_i := 0


func _wait_for_click() -> int:
	if Game.autoplay or Game.demo:
		if Game.demo:
			await get_tree().create_timer(1.0).timeout
		await get_tree().process_frame
		# only actors a player could click: visible, not hidden via action 18, and inside the scene
		# view (scripts park actors off-screen, e.g. at (90, 90), instead of removing them)
		var view := Rect2(0, VIEW_Y, 640, 400)
		var keys := actors.keys().filter(func(k: int) -> bool:
			var a: RpgActor = actors[k]
			return a.visible and a.action != 18 and view.intersects(a.screen_rect().grow(-4)))
		if keys.is_empty():
			await get_tree().create_timer(0.2).timeout
			return -2
		_auto_i += 1
		if _auto_i > 2500 and OS.get_environment("WG_AUTOSAVE") != "":
			# flow-test: random clicking is not solving this scene (puzzles, hubs) — end the file
			print("== flow-test: click cap, leaving %s" % vm.name)
			vm.active = false
			return -2
		var sp := OS.get_environment("WG_SORTIE_P")
		if sortie_enabled and Rules.chance(int(sp) if sp != "" else 12):
			if await do_sortie():
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


func _system_menu() -> void:
	_waiting_click = false
	var items := ["部队状态", "装备", "道具", "存储进度", "读取进度", "回到标题", "史录"]
	if sortie_enabled:
		items.push_front("出征")
	var i := await ui.menu.choose(items, Vector2(-1, -1), true)
	if sortie_enabled:
		if i == 0:
			await _menu_sortie()
			return
		i -= 1
	match i:
		6:
			await _show_history()
		0:
			await Game.main.show_party_status()
		1:
			await PartyMenu.equip_menu(ui)
		2:
			await PartyMenu.item_menu(ui)
		3:
			await Game.main.save_menu()
		4:
			await Game.main.load_menu()
		5:
			Game.main.to_title()
	_waiting_click = true


func _menu_sortie() -> void:
	_waiting_click = false
	if await do_sortie():
		clicked_actor.emit(-2)
		return
	_waiting_click = true


func _show_history() -> void:
	if Game.history.is_empty():
		await ui.popup("暂无史录。", 1.0)
		return
	# chronicle first (category 1), then deeds (3, 4) and items (2), each by entry number
	var entries := Game.history.duplicate()
	var rank := {1: 0, 3: 1, 4: 2, 2: 3}
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = rank.get(int(a["cat"]), 4)
		var rb: int = rank.get(int(b["cat"]), 4)
		return ra < rb or (ra == rb and int(a["id"]) < int(b["id"])))
	var lines := []
	for h in entries:
		lines.append(str(h["text"]).replace("\n", ""))
	# one scrolling list; a chosen entry is shown in full
	var k := 0
	while true:
		k = await ui.menu.choose(lines, Vector2(-1, -1), true, "史录", [], 400, k)
		if k < 0:
			return
		await ui.popup(str(entries[k]["text"]))


# ------------------------------------------------------------------ dialog placement
func _dialog_top(pid: int) -> bool:
	if actors.has(pid):
		return (actors[pid] as RpgActor).position.y > 300
	return false


# ------------------------------------------------------------------ scene
## op 0x27: mode 0 = CG (Giji 0..39), 1 = scene 114+, 2 = room 40+, 3 = battle map.
func op_change_scene(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var val := 0
	match mode:
		0: val = arg(ins, 1)
		1: val = arg(ins, 2)
		2: val = arg(ins, 3)
		3: val = arg(ins, 4)
	if val == 0xffff:
		val = 0
	if Mem.r32(0x55bfe4) == 1:
		val += 0x100
	scene_kind = mode
	scene_image = val
	Mem.w8(0x4ac63c, mode)
	Mem.w16(0x4ac63d, val)
	var entry := val + ({0: 0, 1: 114, 2: 40}.get(mode, 0) as int)
	if mode == 3:
		bg.texture = null
		return
	bg.texture = Assets.tex("gfx/backgrounds/%03d.png" % entry)
	_clear_actors()
	_clear_portraits()
	ui.clear_captions()


func _clear_portraits() -> void:
	for pid in portraits:
		(portraits[pid] as Node).queue_free()
	portraits.clear()


func _clear_actors() -> void:
	for pid in actors:
		(actors[pid] as Node).queue_free()
	actors.clear()


func _sprite_for(pid: int) -> int:
	if pid >= 0 and pid < 1024:
		return Mem.r16(DataTransfer.PERSON_EXT_TABLE + pid * 2)
	return pid & 0x3ff


func op_actor_appear(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if actors.has(pid):
		(actors[pid] as Node).queue_free()
	var a := RpgActor.new()
	actor_layer.add_child(a)
	a.setup(pid, _sprite_for(pid), arg(ins, 1), arg(ins, 2), arg(ins, 3), arg(ins, 4))
	actors[pid] = a


## op 0x31 in story mode removes the actor (0x428b22).
func op_actor_select(ins: Dictionary) -> void:
	var pid := arg(ins, 1) & 0xfff
	if actors.has(pid):
		(actors[pid] as Node).queue_free()
		actors.erase(pid)


## op 0x32 (0x4132d4): when the next instruction is another move it returns at once, so a run of moves
## walks in parallel; the last one yields until no actor is walking.
func op_actor_move(ins: Dictionary) -> void:
	var pid := arg(ins, 1) & 0xfff
	if actors.has(pid):
		var a: RpgActor = actors[pid]
		if vm and vm.next_op == 0x32:
			a.walk_to(arg(ins, 3), arg(ins, 4), arg(ins, 5), fast or Game.autoplay)
			return
		await a.walk_to(arg(ins, 3), arg(ins, 4), arg(ins, 5), fast or Game.autoplay)
	elif vm and vm.next_op == 0x32:
		return
	await _actors_idle()


## op 0x1e: the RPG driver resumes only once no actor is walking (0x4182a4).
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


## op 0x33 (0x428b87): set action and facing; 0xFFFF keeps the current one.
func op_actor_face(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if actors.has(pid):
		var a: RpgActor = actors[pid]
		if arg(ins, 2) != 0xffff:
			a.dir = arg(ins, 2) & 3
		a.set_action(a.action if arg(ins, 1) == 0xffff else arg(ins, 1))


func op_actor_action(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if actors.has(pid):
		(actors[pid] as RpgActor).set_action(arg(ins, 1))


func op_actor_state(_ins: Dictionary) -> void:
	pass


## op 0x2f (0x426c32): reset the actor list.
func op_op_2f(_ins: Dictionary) -> void:
	_clear_actors()


func op_test_clicked(ins: Dictionary) -> bool:
	return in_click and click_pid == (arg(ins, 0) & 0xfff)


## op 0x28: 1 = enable player interaction (town toolbar without 出征), 0 = disable.
func op_op_28(ins: Dictionary) -> void:
	interactive = arg(ins, 0) != 0
	sortie_enabled = false
	Mem.w8(0x55ac02, 0)


## op 0x06 (0x415b45): store sortie parameters; flag != 0 also enables the toolbar with 出征.
func op_battle_select_units(ins: Dictionary) -> void:
	super.op_battle_select_units(ins)
	if arg(ins, 0) != 0:
		interactive = true
		sortie_enabled = true
		Mem.w8(0x55ac02, 1)
	else:
		sortie_enabled = false


## Toolbar 出征 (0x41973c case 3): build the sortie; on success advance to the next scene and set
## the pending flag that the "出战" section tests with op 0x07.
func do_sortie() -> bool:
	if not await build_sortie():
		return false
	# toolbar 出征 (0x41973c case 3): sortie list built, toolbar hidden, pending flag set; the next
	# poll runs the scene's own test_pending section (出战), which leaves the scene / jumps scenario
	sortie_enabled = false
	Mem.w32(0x4ae4c0, 1)
	return true


## op 0x6a: GAME OVER (0x42c0a2): stop audio, show GHAI #7, back to the title.
func op_op_6a(_ins: Dictionary) -> void:
	Audio.stop_bgm()
	SoundMap.stop_loop()
	await Game.main.game_over()
	vm.abort = true
	vm.active = false


# ------------------------------------------------------------------ portraits (ops 0x29/0x2a/0x2b)
func op_op_29(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if portraits.has(pid):
		(portraits[pid] as Node).queue_free()
	var s := Sprite2D.new()
	s.centered = false
	s.texture = Game.person_face(pid)
	s.position = Vector2(arg(ins, 1), arg(ins, 2))
	s.modulate.a = 0
	portrait_layer.add_child(s)
	portraits[pid] = s
	var tw := create_tween()
	tw.tween_property(s, "modulate:a", 1.0, 0.3)
	await tw.finished


func op_op_2a(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if not portraits.has(pid):
		return
	var s: Sprite2D = portraits[pid]
	var tw := create_tween()
	tw.tween_property(s, "position", Vector2(arg(ins, 1), arg(ins, 2)), 0.4)
	await tw.finished


func op_op_2b(ins: Dictionary) -> void:
	var pid := arg(ins, 0) & 0xfff
	if not portraits.has(pid):
		return
	var s: Sprite2D = portraits[pid]
	portraits.erase(pid)
	var tw := create_tween()
	tw.tween_property(s, "modulate:a", 0.0, 0.3)
	await tw.finished
	s.queue_free()


func on_field_written(field: int, id: int) -> void:
	# sprite (field 0) changed: refresh an on-screen actor
	if field == 0 and actors.has(id):
		(actors[id] as RpgActor).set_sprite(_sprite_for(id))


# ------------------------------------------------------------------ save / restore
func save_state() -> Dictionary:
	var acts := []
	for pid in actors:
		var a: RpgActor = actors[pid]
		acts.append([pid, a.sprite_id, a.gx, a.gy, a.dir, a.action])
	return {"kind": "story", "scene": vm.scene if vm else 0, "scene_kind": scene_kind, "scene_image": scene_image,
		"actors": acts, "bgm": Audio.current_track, "interactive": interactive, "sortie_enabled": sortie_enabled}


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
		var entry := scene_image + ({0: 0, 1: 114, 2: 40}.get(mode, 0) as int)
		bg.texture = Assets.tex("gfx/backgrounds/%03d.png" % entry)
	for e in d.get("actors", []):
		var a := RpgActor.new()
		actor_layer.add_child(a)
		a.setup(int(e[0]), int(e[1]), int(e[2]), int(e[3]), int(e[4]), int(e[5]))
		actors[int(e[0])] = a
	interactive = bool(d.get("interactive", false))
	sortie_enabled = bool(d.get("sortie_enabled", false))
	if int(d.get("bgm", -1)) >= 0:
		Audio.play_bgm(int(d["bgm"]))
	ui.set_black(false)
