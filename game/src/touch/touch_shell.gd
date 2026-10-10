class_name TouchShell
extends Control
## Mobile front end (the main scene on iOS and Android; run res://src/touch/touch_shell.tscn to try it on a
## desktop).
## The game, still a 640x480 world, runs in a SubViewport scaled to the screen height at 4:3 in the middle of the
## landscape screen; the side bars hold touch buttons for what needs a right button or a key with a mouse. The
## original's right click does two jobs, which get a button each here:
##   返回 = cancel / go back (Esc); dimmed at the top level, where a right click would open the menu instead
##   菜单 = (top left) the system menu (end turn, save, ...), only at the top level: no unit selected / a story
##          scene waiting
##   快进 = holding Ctrl (toggle): fast animations, text skips ahead
## Taps reach the game as left clicks (Godot's touch-to-mouse emulation); Game.touch makes the battle map click on
## release and pan on drag, lets menus scroll by dragging, and makes a tap outside a menu or a target range cancel.

const GAME_SIZE := Vector2i(640, 480)
const BACK := 0
const MENU := 1
const FAST := 2

var _box: SubViewportContainer
var _vp: SubViewport
var _game_rect := Rect2()
var _buttons: Array = []          # {text, sub, rect: Rect2, toggle: bool}
var _held := -1                   # button under the pressing finger / mouse
var _menu_ready := false          # the game waits at its top level (菜单 on, 返回 dimmed)
var _shot_t := 0.0
var _shot_n := 0


func _ready() -> void:
	# lay out in window pixels: the SubViewport renders the game at the screen's resolution (sharp HD art and text)
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	var s := OS.get_environment("WG_SHELLSIZE")      # debug: WxH window size for a desktop layout check
	if s != "" and not OS.has_feature("mobile"):
		get_window().size = Vector2i(int(s.get_slice("x", 0)), int(s.get_slice("x", 1)))
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP          # taps on the side bars never reach the game
	Game.shell = self
	Game.touch = true
	_buttons = [
		{"text": "返回", "toggle": false, "rect": Rect2()},
		{"text": "菜单", "toggle": false, "rect": Rect2()},
		{"text": "快进", "toggle": true, "rect": Rect2()},
	]
	_box = SubViewportContainer.new()
	_box.stretch = true
	add_child(_box)
	_vp = SubViewport.new()
	_vp.size_2d_override = GAME_SIZE
	_vp.size_2d_override_stretch = true
	_box.add_child(_vp)
	get_viewport().size_changed.connect(_layout)
	_layout()
	Assets.set_view(_vp)
	_vp.add_child(load("res://src/main.tscn").instantiate())


## The viewport the game runs in.
func game_viewport() -> SubViewport:
	return _vp


## True if a window position (e.g. of a tap) is on the game picture rather than a side bar.
func over_game(p: Vector2) -> bool:
	return _game_rect.has_point(p)


func _layout() -> void:
	var s := get_viewport_rect().size
	# the picture fills the height; narrower screens (a desktop test window) keep a minimum bar for the buttons
	var bar_min := s.y * 0.16
	var gh := floorf(minf(s.y, (s.x - 2 * bar_min) * 0.75))
	var gw := floorf(gh * 4.0 / 3.0)
	_game_rect = Rect2(floorf((s.x - gw) / 2), floorf((s.y - gh) / 2), gw, gh)
	_box.position = _game_rect.position
	_box.size = _game_rect.size
	# keep the buttons clear of the notch / rounded corners; the notch changes side when the phone turns over
	# (without a resize), so use the larger inset on both sides
	var inset := 0.0
	if OS.has_feature("mobile"):
		var safe := DisplayServer.get_display_safe_area()
		inset = maxf(safe.position.x, s.x - safe.end.x)
	var bar := _game_rect.position.x
	var pad := s.y * 0.02
	var bw := minf(bar - inset - 2 * pad, s.y * 0.24)
	var bh := s.y * 0.17
	var y := s.y * 0.58 - bh / 2              # within thumb reach
	var left_x := inset + (bar - inset - bw) / 2
	_buttons[MENU]["rect"] = Rect2(left_x, s.y * 0.06, bw, bh)           # top left
	_buttons[BACK]["rect"] = Rect2(left_x, y, bw, bh)
	_buttons[FAST]["rect"] = Rect2(s.x - left_x - bw, y, bw, bh)
	queue_redraw()


## Whether a button does anything now: 菜单 only at the game's top level, 返回 everywhere else.
func _enabled(i: int) -> bool:
	match i:
		BACK:
			return not _menu_ready
		MENU:
			return _menu_ready
	return true


func _stage() -> Node:
	var m: Variant = Game.main
	if m == null or not is_instance_valid(m) or m.stage == null or not is_instance_valid(m.stage):
		return null
	return m.stage


func _draw() -> void:
	var f := Assets.font()
	var h := get_viewport_rect().size.y
	for i in _buttons.size():
		var b: Dictionary = _buttons[i]
		var r: Rect2 = b["rect"]
		if r.size.x <= 0:
			continue
		UIStyle.draw_panel(self, r)
		var on: bool = b["toggle"] and Game.fast_toggle
		if i == _held or on:
			draw_rect(r.grow(-4), UIStyle.HILITE)
		var fs := int(h * 0.05)
		var col := Color(1, 1, 1) if on else UIStyle.NAME_COLOR
		if not _enabled(i):
			draw_rect(r, Color(0, 0, 0, 0.55))
			col = Color(0.55, 0.55, 0.6)
		var ty := r.position.y + r.size.y * 0.5 + fs * 0.35
		draw_string(f, Vector2(r.position.x + 2, ty + 2), b["text"], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, UIStyle.SHADOW)
		draw_string(f, Vector2(r.position.x, ty), b["text"], HORIZONTAL_ALIGNMENT_CENTER, r.size.x, fs, col)


func _button_at(p: Vector2) -> int:
	for i in _buttons.size():
		if (_buttons[i]["rect"] as Rect2).grow(get_viewport_rect().size.y * 0.02).has_point(p):
			return i
	return -1


## Buttons react to real touches (any finger, so one can be on the map) and to a real mouse, not to the mouse
## events Godot emulates from the first finger (those would count the same tap twice).
func _input(ev: InputEvent) -> void:
	var p: Vector2
	var pressed: bool
	if ev is InputEventScreenTouch:
		p = ev.position
		pressed = ev.pressed
	elif ev is InputEventMouseButton and ev.device != InputEvent.DEVICE_ID_EMULATION and ev.button_index == MOUSE_BUTTON_LEFT:
		p = ev.position
		pressed = ev.pressed
	else:
		return
	var i := _button_at(p)
	if pressed:
		if i >= 0:
			get_viewport().set_input_as_handled()
			if _enabled(i):
				_held = i
				queue_redraw()
		return
	if _held < 0:
		return
	var was := _held
	_held = -1
	queue_redraw()
	get_viewport().set_input_as_handled()
	if i == was and _enabled(i):
		_activate(i)


func _activate(i: int) -> void:
	match i:
		BACK:
			_send_cancel()
		MENU:
			var st := _stage()
			if st:
				st.open_menu()
		FAST:
			Game.fast_toggle = not Game.fast_toggle
			queue_redraw()


## Same as pressing Esc: every place a right click cancels also takes ui_cancel.
func _send_cancel() -> void:
	for pressed in [true, false]:
		var k := InputEventKey.new()
		k.keycode = KEY_ESCAPE
		k.physical_keycode = KEY_ESCAPE
		k.pressed = pressed
		Input.parse_input_event(k)


## Android's back button / gesture does what a right click does: 返回, or 菜单 at the top level (it does not quit
## the app: application/config/quit_on_go_back is off).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_activate(MENU if _menu_ready else BACK)


func _process(_d: float) -> void:
	var st := _stage()
	var ready: bool = st != null and st.menu_ready()
	if ready != _menu_ready:
		_menu_ready = ready
		queue_redraw()
	# debug: WG_SHELLSHOT=dir saves the whole screen (side bars included) every WG_SHOT_EVERY seconds (default 3)
	var dir := OS.get_environment("WG_SHELLSHOT")
	if dir == "":
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - _shot_t < float(OS.get_environment("WG_SHOT_EVERY") if OS.get_environment("WG_SHOT_EVERY") != "" else "3"):
		return
	_shot_t = now
	_shot_n += 1
	if _shot_n == 1:
		DirAccess.make_dir_recursive_absolute(dir)       # e.g. user://shots on a phone
	get_viewport().get_texture().get_image().save_png("%s/shell_%03d.png" % [dir, _shot_n])
