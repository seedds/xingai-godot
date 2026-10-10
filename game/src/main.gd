extends Node
## Boot + top-level flow: title screen, scenario loop (R_xx story / S_xx battle files),
## save/load, game over and ending.

const SAVE_SLOTS := 10

var ui: GameUI
var stage: ScriptHost
var _title_bg: Sprite2D
var _abort_flow := false
var _flow_running := false
var _flow_gen := 0          # bumped to orphan a running scenario loop (load / title / retry)
var _pending_load: Dictionary = {}
var _retries: Dictionary = {}


func _enter_tree() -> void:
	Game.main = self


func _unhandled_key_input(ev: InputEvent) -> void:
	# Cmd+F / F11 / Alt+Enter toggles full screen
	if Game.shell:
		return
	if ev is InputEventKey and ev.pressed and (ev.keycode == KEY_F11 or (ev.keycode == KEY_F and ev.meta_pressed) or (ev.keycode == KEY_ENTER and ev.alt_pressed)):
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
		get_viewport().set_input_as_handled()


func _process(_d: float) -> void:
	# hold Space / Ctrl (touch: the 快进 toggle) to fast-forward animations (like the original patch's Space fast-click)
	var fast := (Input.is_key_pressed(KEY_SPACE) or Game.skip_held()) and not ui.video.visible
	Engine.time_scale = 4.0 if fast else 1.0
	_autosave_watch()
	_debug_shots()


func _notification(what: int) -> void:
	# iOS may kill a backgrounded app without notice: write the autosave on the way out (~5 s budget there)
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_CLOSE_REQUEST]:
		_autosave_flush()


var _shot_t := 0.0
var _shot_n := 0


## Debug: WG_SHOTS=dir saves a screenshot every WG_SHOT_EVERY seconds (default 3).
func _debug_shots() -> void:
	var dir := OS.get_environment("WG_SHOTS")
	if dir == "":
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _shot_t < float(OS.get_environment("WG_SHOT_EVERY") if OS.get_environment("WG_SHOT_EVERY") != "" else "3"):
		return
	_shot_t = now
	_shot_n += 1
	get_viewport().get_texture().get_image().save_png("%s/%03d.png" % [dir, _shot_n])


func _fit_window() -> void:
	if DisplayServer.get_name() == "headless" or Game.shell:
		return
	var w := get_window()
	if w.mode != Window.MODE_WINDOWED:
		return
	var usable := DisplayServer.screen_get_usable_rect(w.current_screen)
	var scale := 1.0
	for s in [3.0, 2.5, 2.0, 1.5, 1.0]:
		if 640 * s <= usable.size.x * 0.92 and 480 * s <= usable.size.y * 0.9:
			scale = s
			break
	var size := Vector2i(int(640 * scale), int(480 * scale))
	_set_window_size(size)
	w.position = usable.position + (usable.size - size) / 2


# The picture keeps the game's 4:3 shape, so a window resized by one edge only gets black bars and the picture
# does not grow. Once the user stops resizing, snap the window back to 4:3 around the dimension they changed.
var _settled_size := Vector2i.ZERO
var _snapping := false
var _snap_timer: Timer


func _set_window_size(size: Vector2i) -> void:
	_snapping = true
	get_window().size = size
	_settled_size = get_window().size
	_snapping = false


func _on_window_resized() -> void:
	if not _snapping:
		_snap_timer.start()    # restarted on every step of a drag; fires once it has stopped


func _snap_aspect() -> void:
	var w := get_window()
	if w.mode != Window.MODE_WINDOWED:
		return
	var s := w.size
	var target: Vector2i
	if absi(s.x - _settled_size.x) * 3 >= absi(s.y - _settled_size.y) * 4:
		target = Vector2i(s.x, roundi(s.x * 0.75))
	else:
		target = Vector2i(roundi(s.y * 4.0 / 3.0), s.y)
	var usable := DisplayServer.screen_get_usable_rect(w.current_screen)
	var fit := minf(1.0, minf(float(usable.size.x) / target.x, float(usable.size.y) / target.y))
	target = Vector2i(roundi(target.x * fit), roundi(target.y * fit))
	if target != s:
		_set_window_size(target)
		# keep the grown window on screen
		w.position = Vector2i(clampi(w.position.x, usable.position.x, maxi(usable.position.x, usable.end.x - target.x)),
				clampi(w.position.y, usable.position.y, maxi(usable.position.y, usable.end.y - target.y)))
	_settled_size = w.size


func _ready() -> void:
	_snap_timer = Timer.new()
	_snap_timer.one_shot = true
	_snap_timer.wait_time = 0.3
	_snap_timer.timeout.connect(_snap_aspect)
	add_child(_snap_timer)
	if not Game.shell:        # the touch shell lays out the window itself
		get_window().size_changed.connect(_on_window_resized)
	_fit_window.call_deferred()
	ui = GameUI.new()
	add_child(ui)
	_boot.call_deferred()


func _boot() -> void:
	if OS.get_environment("WG_ACCEPT_SPAM") != "":
		# debug: tap ui_accept every 0.6 s (advances dialogue, like a player mashing Enter)
		var t := Timer.new()
		t.wait_time = 0.6
		t.autostart = true
		t.timeout.connect(func() -> void:
			if Game.has_meta("bot_owns_input"):
				return
			for pressed in [true, false]:
				var ev := InputEventAction.new()
				ev.action = "ui_accept"
				ev.pressed = pressed
				Input.parse_input_event(ev)
				for k in 2:
					await get_tree().process_frame)
		add_child(t)
	var ls := OS.get_environment("WG_LOADSLOT")
	if ls != "":
		var extra: Variant = Game.load_game(int(ls))
		_pending_load = extra if extra is Dictionary else {}
		print("== loaded slot %s at scenario %d" % [ls, Game.scenario])
		_run_flow()
		return
	var start := OS.get_environment("WG_START")
	if start != "":
		# debug: WG_START=<scenario number> jumps straight into a scenario
		Game.new_game_state()
		Game.scenario = int(start)
		var party := OS.get_environment("WG_PARTY")
		if party != "":
			for x in party.split(","):
				Game.join_party(int(x), 1)
		for fl in OS.get_environment("WG_SETFLAGS").split(",", false):
			Mem.set_flag(int(fl), true)          # debug: story flags an earlier branch would have set
		if Game.scenario % 2 == 1:
			# starting at a battle: no story scene built the sortie list (u32[] @0x48b350, 0xffff end)
			var ids := Game.party_ids()
			var n := mini(ids.size(), 12)
			for i in n:
				Mem.w32(0x48b350 + 4 * i, ids[i])
			Mem.w32(0x48b350 + 4 * n, 0xffff)
		if OS.get_environment("WG_AUTOSAVE") != "":
			Game.save_game(_autoslot(), {})
		_run_flow()
		return
	if OS.get_environment("WG_NOVIDEO") == "":
		await ui.video.play("pre")
	to_title()


# ------------------------------------------------------------------ title
func to_title() -> void:
	_stop_flow()
	if Game.autoplay and OS.get_environment("WG_AUTOSAVE") != "" and not Game.save_info(_autoslot()).is_empty():
		# flow-test: retry from the last autosave instead of restarting the game
		_retry_autosave.call_deferred()
		return
	_title_screen.call_deferred()


## Abandon the running scenario loop and its stage. The loop may be suspended inside the stage
## (often the very call chain that asked for this), so it is orphaned via _flow_gen instead of
## being waited for; anything of it that still resumes sees the stale generation and returns.
func _stop_flow() -> void:
	_flow_gen += 1
	_abort_flow = true
	_flow_running = false
	if stage:
		if stage.vm:
			stage.vm.abort = true
			stage.vm.active = false
		stage.queue_free()
		stage = null
	SoundMap.stop_loop()


## Flow-test autosave slot (WG_AUTOSLOT, default 19) so parallel runs don't share one. Slots 0-9 are the
## player's saves.
func _autoslot() -> int:
	var s := OS.get_environment("WG_AUTOSLOT")
	return int(s) if s != "" else 19


func _retry_autosave() -> void:
	var failed := Game.scenario            # the scenario that just ended in game over / an ending
	var was_ending := Game.ending_reached
	Game.ending_reached = false
	if was_ending and failed >= 106:
		# the endgame (R_53 / R_54 hub) ends the game: the playthrough is complete
		print("== flow-test: reached an ending in %s" % scenario_file(failed))
		get_tree().quit()
		return
	_stop_flow()
	await get_tree().process_frame
	var saved: Variant = Game.load_game(_autoslot())
	_pending_load = saved if saved is Dictionary else {}
	var tries := int(_retries.get(failed, 0)) + 1
	_retries[failed] = tries
	# a battle random play keeps losing (scripted objective): jump to its aftermath on the next try
	if failed % 2 == 1 and tries >= 3:
		Game.skip_battle_scenario = failed   # cleared by the battle when it is used
	print("== retry from autosave at scenario %d (scenario %d failed, try %d)" % [Game.scenario, failed, tries])
	if failed % 2 == 0 and tries >= 30 and Game.scenario == failed:
		# a story scene random play keeps losing (chained 单挑 mini-games) — move on
		print("== flow-test: skipping story %s" % scenario_file(failed))
		_pending_load = {}
		Game.scenario += 1
		Game.save_game(_autoslot(), {})      # don't come back to it on the next retry
	_run_flow()


func _title_screen() -> void:
	await get_tree().process_frame
	_abort_flow = false
	Audio.play_bgm(2)
	if _title_bg == null:
		_title_bg = Sprite2D.new()
		_title_bg.centered = false
		_title_bg.position = Vector2(0, 40)
		add_child(_title_bg)
	# 0x42bd90: title picture 0, or 12 + Niuniu.wa[0] (13..15) once an ending has been recorded
	var nb := SpecialFuncs.read_niuniu()
	var v := nb[0]
	_title_bg.texture = Assets.tex("gfx/screens/%02d.png" % (12 + v if v >= 1 and v <= 3 else 0))
	_title_bg.visible = true
	_show_version()
	ui.set_black(false)
	while true:
		var items: Array = ["开始新游戏", "读取进度"]
		if _autosave_enabled() and not Game.save_info(Game.AUTO_SLOT).is_empty():
			items.push_front("继续游戏")
		if not OS.has_feature("mobile"):
			items.append("结束游戏")      # phone apps don't quit themselves
		# the bottom row stays where the original's three-item menu ends, inside the title picture
		var i := await ui.menu.choose(items, Vector2(250, 330 - 24 * (items.size() - 3)), false, "", [], 140)
		match items[i]:
			"继续游戏":
				if await _load_slot(Game.AUTO_SLOT):
					return
			"开始新游戏":
				_title_bg.visible = false
				Game.new_game_state()
				Game.scenario = 0
				_run_flow()
				return
			"读取进度":
				if await load_menu():
					return
			_:
				get_tree().quit()
				return


## Build number in the title screen's corner (application/config/version, set by the release workflow).
func _show_version() -> void:
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	if ver == "" or _title_bg.has_node("Version"):
		return
	var l := UIStyle.label("版本 " + ver, 12, Color(1, 1, 1, 0.75))
	l.name = "Version"
	l.position = Vector2(540, 380)
	l.size = Vector2(96, 16)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_title_bg.add_child(l)


# ------------------------------------------------------------------ scenario loop
func scenario_file(n: int) -> String:
	return ("R_%02d" if n % 2 == 0 else "S_%02d") % (n / 2)


func _run_flow() -> void:
	if _flow_running:
		return
	_flow_running = true
	_abort_flow = false
	_flow_gen += 1
	var gen := _flow_gen
	while not _abort_flow:
		var n := Game.scenario
		var file := scenario_file(n)
		if not Assets.exists("scripts/%s.json" % file):
			if Game.autoplay and OS.get_environment("WG_AUTOSAVE") != "":
				print("== flow-test: reached the end of the game")
				get_tree().quit()
				return
			await ending()
			return
		Game.scenario_jumped = false
		# a new game, the next scenario or a loaded save: the start of this stage is a checkpoint
		_autosave_checkpoint(_pending_load, true)
		print("== scenario %d: %s" % [n, file])
		var stop := OS.get_environment("WG_STOP")
		if stop != "" and n >= int(stop):
			get_tree().quit()
			return
		if n % 2 == 0:
			stage = StoryStage.new()
		else:
			stage = BattleStage.new()
		stage.name = "Stage"
		add_child(stage)
		move_child(stage, 0)
		if not _pending_load.is_empty():
			stage.restore_state(_pending_load)
			_pending_load = {}
		var st := stage
		await st.run_file(file)
		if gen != _flow_gen:
			return
		if _abort_flow or stage == null:
			break
		stage.queue_free()
		stage = null
		Game.scenario = (Game.scenario + 1) & 0xff
		if OS.get_environment("WG_AUTOSAVE") != "":
			Game.save_game(_autoslot(), {})
	if gen == _flow_gen:
		_flow_running = false


func game_over() -> void:
	ui.set_black(true)
	var s := Sprite2D.new()
	s.centered = false
	s.position = Vector2(0, 40)
	s.texture = Assets.tex("gfx/screens/07.png")
	s.z_index = 50
	ui.add_child(s)
	await ui.fade_from_black()
	await ui.popup("", 4.0)
	s.queue_free()
	to_title()


func ending() -> void:
	# the game is finished: nothing to continue
	_autosave = {}
	Game.delete_save(Game.AUTO_SLOT)
	await ui.video.play("end")
	to_title()


# ------------------------------------------------------------------ save / load
func _slot_labels() -> Array:
	var out := []
	for i in SAVE_SLOTS:
		var info := Game.save_info(i)
		if info.is_empty():
			out.append("%2d：——空——" % (i + 1))
		else:
			out.append("%2d：%s  %s" % [i + 1, str(info.get("chapter_title", "")), str(info.get("time", "")).substr(0, 16)])
	return out


func save_menu() -> void:
	var i := await ui.menu.choose(_slot_labels(), Vector2(-1, -1), true, "存储进度")
	if i < 0:
		return
	var extra := {}
	if stage and stage.has_method("save_state"):
		extra = stage.save_state()
	if Game.save_game(i, extra):
		await ui.popup("进度已保存。", 1.0)
	else:
		await ui.popup("进度保存失败。", 1.2)


func load_menu() -> bool:
	var i := await ui.menu.choose(_slot_labels(), Vector2(-1, -1), true, "读取进度")
	if i < 0 or Game.save_info(i).is_empty():
		return false
	return await _load_slot(i)


func _load_slot(i: int) -> bool:
	if Game.read_save(i) == null:
		await ui.popup("无法读取这个进度。", 1.2)
		return false
	_stop_flow()
	var extra: Variant = Game.load_game(i)
	if extra == null:
		extra = {}
	if _title_bg:
		_title_bg.visible = false
	_pending_load = extra
	# start after the caller's chain (possibly inside the old stage) has unwound
	_run_flow.call_deferred()
	return true


# ------------------------------------------------------------------ autosave (继续游戏)
# A running script lives in await chains and cannot be saved, so the autosave holds the last checkpoint: a
# stage start, or the stage waiting at its top level (story click / player phase), where 存储进度 works too.
# It is taken in memory there and written when the app goes to the background or closes (plus once a minute).
const AUTOSAVE_EVERY_MS := 60000

var _autosave: Dictionary = {}         # capture_save() of the last checkpoint
var _autosave_dirty := false
var _autosave_written_ms := 0
var _was_menu_ready := false


## Flow tests and bots must not overwrite the player's autosave.
func _autosave_enabled() -> bool:
	if Game.autoplay or Game.demo:
		return false
	for e in ["WG_START", "WG_AUTOSAVE", "WG_INPUTBOT"]:
		if OS.get_environment(e) != "":
			return false
	return true


func _autosave_watch() -> void:
	var ready := stage != null and stage.menu_ready()
	if ready and not _was_menu_ready:
		_autosave_checkpoint(stage.save_state())
	_was_menu_ready = ready


func _autosave_checkpoint(extra: Dictionary, write_now := false) -> void:
	if not _autosave_enabled():
		return
	_autosave = Game.capture_save(extra)
	_autosave_dirty = true
	if write_now or Time.get_ticks_msec() - _autosave_written_ms >= AUTOSAVE_EVERY_MS:
		_autosave_flush()


func _autosave_flush() -> void:
	if not _autosave_dirty or _autosave.is_empty():
		return
	_autosave_dirty = false
	_autosave_written_ms = Time.get_ticks_msec()
	if not Game.write_capture(Game.AUTO_SLOT, _autosave):
		push_warning("autosave could not be written")


# ------------------------------------------------------------------ status screens
func show_party_status() -> void:
	var ids := Game.party_ids()
	if ids.is_empty():
		await ui.popup("没有部队。", 1.0)
		return
	var labels := []
	for pid in ids:
		var p := Game.person(pid)
		labels.append("%s  %s  Lv%d" % [p.name, p.class_name_str(), p.level])
	while true:
		var i := await ui.menu.choose(labels, Vector2(-1, -1), true, "部队")
		if i < 0:
			return
		await StatusPanel.show_person(ui, Game.person(ids[i]))
