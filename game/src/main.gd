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
	if OS.get_environment("WG_ENDTEST") != "":
		# debug: the ending show of ending v, then quit
		await ending_show(int(OS.get_environment("WG_ENDTEST")))
		get_tree().quit()
		return
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
			# starting at a battle: no story scene built the sortie list (u16[] @0x48b350, 0xffff end)
			var ids := Game.party_ids()
			var n := mini(ids.size(), 20)
			for i in n:
				Mem.w16(Game.SORTIE_LIST + 2 * i, ids[i])
			Mem.w16(Game.SORTIE_LIST + 2 * n, 0xffff)
		if OS.get_environment("WG_AUTOSAVE") != "":
			Game.save_game(_autoslot(), {})
		_run_flow()
		return
	if OS.get_environment("WG_NOVIDEO") == "":
		# 0x42b95c → 0x4112cd: movie 0 (Logo.Avi) before the title; the opening (Open.Avi) is played by a script
		await ui.video.play("logo")
	to_title()


# ------------------------------------------------------------------ title
func to_title() -> void:
	_stop_flow()
	if OS.get_environment("WG_ONEFILE") != "":
		print("== file done: back to the title (ending / game over)")
		get_tree().quit()
		return
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
	if was_ending:
		# an ending (op 0x0f, R_058) or a scripted program exit (op 0x6a, R_108 / R_116 / R_117) ends the game
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


var _title_menu: TitleMenu


func _title_screen() -> void:
	await get_tree().process_frame
	_abort_flow = false
	# boot loop 0x404caf: BGM track 0x12 (0x4745a7), title picture, then the four picture buttons
	Audio.play_bgm(0x12)
	if _title_bg == null:
		_title_bg = Sprite2D.new()
		_title_bg.centered = false
		_title_bg.position = Vector2(0, 40)
		add_child(_title_bg)
	# 0x42bd6c: title picture (Logo.e5 0) at (0,40), plus emblem 1..3 (64x64) at (188 + 100i, 340) for each ending
	# i recorded in byte i of SV\SV.E5S (0x41a280)
	_title_bg.texture = Assets.tex("gfx/screens/00.png")
	var nb := SpecialFuncs.sv_read()
	for i in 3:
		var em := _title_bg.get_node_or_null("Emblem%d" % i) as Sprite2D
		if em == null:
			em = Sprite2D.new()
			em.name = "Emblem%d" % i
			em.centered = false
			em.position = Vector2(188 + 100 * i, 300)
			em.texture = Assets.tex("gfx/screens/%02d.png" % (i + 1))
			_title_bg.add_child(em)
		em.visible = nb[i] != 0
	_title_bg.visible = true
	_show_version()
	ui.set_black(false)
	if _title_menu == null:
		_title_menu = TitleMenu.new()
		add_child(_title_menu)
	_title_menu.visible = true
	while true:
		var i := await _title_menu.choose()
		match i:
			0:
				_title_menu.visible = false
				_title_bg.visible = false
				Game.new_game_state()
				Game.scenario = 0
				_run_flow()
				return
			1:
				# 烽煙再起: the save list (the port's autosave 继续游戏 first when there is one)
				if _autosave_enabled() and not Game.save_info(Game.AUTO_SLOT).is_empty():
					var k := await ui.menu.choose(["继续游戏", "读取进度"], Vector2(-1, -1), true)
					if k == 0:
						if await _load_slot(Game.AUTO_SLOT):
							_title_menu.visible = false
							return
						continue
					if k < 0:
						continue
				if await load_menu():
					_title_menu.visible = false
					return
			2:
				pass       # 環境設定 dialog (KANKYOU, 0x41bad7): not ported
			3:
				if not OS.has_feature("mobile"):
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
	return ("R_%03d" if n % 2 == 0 else "S_%03d") % (n / 2)


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
		if stop != "" and n >= int(stop) and n != 300:     # 300 = R_150, the detour R_001 takes on a new game
			get_tree().quit()
			return
		if n % 2 == 1 and OS.get_environment("WG_SKIPBATTLES") != "":
			Game.skip_battle_scenario = n      # debug: story-only flow test, battles go straight to their aftermath
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
		if OS.get_environment("WG_ONEFILE") != "":
			# debug: run one scenario file and quit (tools/runall.sh)
			print("== file done: %s -> next scenario %d" % [file, (Game.scenario + 1) & 0xffff])
			get_tree().quit()
			return
		if _abort_flow or stage == null:
			break
		stage.queue_free()
		stage = null
		Game.scenario = (Game.scenario + 1) & 0xffff
		if OS.get_environment("WG_AUTOSAVE") != "":
			Game.save_game(_autoslot(), {})
	if gen == _flow_gen:
		_flow_running = false


## Game over 0x42c09e (battle lost, op 0x0e): GS+5 = 0, the scenario counter reset (0x418ab1(0)), music stopped, SE 40,
## Logo.e5 [7] (GAME OVER), 50 ticks, then the yes/no box "再玩一次吗？" (0x48c808): yes → the title, no → the program
## ends (phones: the title).
func game_over() -> void:
	Mem.w8(Mem.GS + 5, 0)
	Audio.stop_bgm()
	SoundMap.stop_loop()
	Audio.play_se(SoundMap.se_name(0x28))
	ui.set_black(true)
	var s := Sprite2D.new()
	s.centered = false
	s.position = Vector2(0, 40)
	s.texture = Assets.tex("gfx/screens/07.png")
	s.z_index = 50
	ui.add_child(s)
	ui.set_black(false)
	if not Game.autoplay:
		await get_tree().create_timer(2.5).timeout
	var again := true
	if ui.has_method("yes_no"):
		again = await ui.yes_no("再玩一次吗？")
	s.queue_free()
	if not again and not OS.has_feature("mobile") and not Game.autoplay:
		get_tree().quit()
		return
	to_title()


## Ending show 0x4317ab(v) (op 0x0f / 0x414050): BGM track 0x10, Logo.e5 [4] as the backdrop; per round 10 ticks, a
## credits page of Imsg 800.. (0x431543: up to ";", "//n" skipped, "%" lines 32 px at x 208, other lines 64 px at x 240,
## the block centred in the 400-pixel view) for the first 24 rounds; after page 22 the 中文简体版 / 天津光荣 / 软件有限公司
## screen (0x431967, 1 s + 4 s); then 0x431a0a(v): 总制作 / EIJI FUKUZAWA (+ the ending emblem Logo [v + 1] at
## (288, 340) for v < 2), 127 ticks; the KOEI logo (Logo [6]) 50 ticks. [G] The cast portraits of 0x431c19 (persons
## u32 0x4b2b30[k], filled by 0x72 sub 9 which no script uses) are not shown, and each page holds 4 s (a click moves
## on) where the original's portrait animation sets the pace.
func ending_show(v: int) -> void:
	Audio.play_bgm(0x10)
	var layer := Control.new()
	layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(layer)
	var back := TextureRect.new()
	back.texture = Assets.tex("gfx/screens/04.png")
	back.position = Vector2(0, 40)
	layer.add_child(back)
	ui.set_black(false)
	var idx := 800
	for k in 0x18:
		await _end_wait(0.5)
		var lines := []
		while idx < 3000:
			var t := Game.text(idx)
			idx += 1
			if t.begins_with(";"):
				break
			if t.begins_with("//"):
				continue
			lines.append(t)
		if lines.is_empty():
			break
		var h := 0
		var heads := 0
		var rows := 0
		for t in lines:
			if str(t).begins_with("%"):
				h += 0x20
				if heads > 0 and str(t).length() > 1 and str(t)[1] != " ":
					h += 0x20
				heads += 1
			else:
				h += 0x40 + (0x10 if rows > 0 or heads > 0 else 0)
				rows += 1
		var page := Control.new()
		page.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(page)
		var y := 40 - (h / 2 - 200)
		heads = 0
		rows = 0
		for t in lines:
			var head: bool = str(t).begins_with("%")
			if head:
				if heads > 0 and str(t).length() > 1 and str(t)[1] != " ":
					y += 0x20
				_end_text(page, str(t).substr(1).lstrip("%"), Vector2(208, y), 26)
				y += 0x20
				heads += 1
			else:
				if rows > 0 or heads > 0:
					y += 0x10
				_end_text(page, str(t), Vector2(240, y), 52)
				y += 0x40
				rows += 1
		await _end_wait(4.0)
		page.queue_free()
		if k == 0x16:
			await _end_wait(0.5)
			var p2 := Control.new()
			layer.add_child(p2)
			_end_text(p2, "中文简体版", Vector2(208, 160), 26)
			await _end_wait(1.0)
			_end_text(p2, "      天津光荣", Vector2(208, 200), 52)
			_end_text(p2, "    软件有限公司", Vector2(208, 264), 52)
			await _end_wait(4.0)
			p2.queue_free()
	var p3 := Control.new()
	layer.add_child(p3)
	_end_text(p3, "总制作", Vector2(64, 160), 26)
	_end_text(p3, "EIJI FUKUZAWA", Vector2(128, 208), 52)
	if v < 2:
		var em := TextureRect.new()
		em.texture = Assets.tex("gfx/screens/%02d.png" % (v + 1))
		em.position = Vector2(288, 340)
		p3.add_child(em)
	await _end_wait(6.35)
	p3.queue_free()
	back.texture = Assets.tex("gfx/screens/06.png")
	await _end_wait(2.5)
	layer.queue_free()
	Audio.stop_bgm()


func _end_text(parent: Control, t: String, at: Vector2, size: int) -> void:
	var l := UIStyle.label(t, size, Color(1, 1, 1))
	l.position = at
	parent.add_child(l)


## A wait of the ending show: skipped under autoplay; a click ends it early.
func _end_wait(sec: float) -> void:
	if Game.autoplay:
		return
	var n0 := Game.clicks
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < sec * 1000.0 and Game.clicks == n0:
		await get_tree().process_frame


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
## 武将一览 (dialog 186, PartyMenu.unit_list); a row opens 武将情报.
func show_party_status() -> void:
	await PartyMenu.unit_list(ui)
