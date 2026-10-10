class_name TitleMenu
extends Control
## Title menu of the boot loop 0x404caf: four 176×44 picture buttons from U_select.e5 [11] (frames 0–3 normal, 4–7
## highlighted; 0x42bc94 / 0x404c33) at x = 432, y = 88 + 64·i on the 640×480 screen. The mouse over a button
## highlights it with sound effect 15 (0x419514 + 0x46d0b7(0xf)); a click picks it: 0 刀兵初現 new game, 1 烽煙再起 load,
## 2 沙場點兵 the 環境 settings dialog (KANKYOU, 0x44f8eb), 3 南山放馬 quit.
## (Keyboard: arrows + Enter, an addition for keyboard and controller players.)

signal chosen(index: int)

const X := 432
const Y0 := 88
const STEP := 64
const W := 176
const H := 44

var hot := -1
var _sheet: Texture2D
var _active := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_sheet = Assets.tex("gfx/ui/u_select/11.png")


func choose() -> int:
	hot = -1
	_active = true
	visible = true
	queue_redraw()
	var i: int = await chosen
	_active = false
	return i


func _item_at(p: Vector2) -> int:
	for i in 4:
		if p.x > X and p.x < X + W and p.y >= Y0 + STEP * i and p.y < Y0 + STEP * i + H:
			return i
	return -1


func _set_hot(i: int) -> void:
	if i == hot:
		return
	hot = i
	if i >= 0:
		Audio.play_se(SoundMap.se_name(0xf))
	queue_redraw()


func _draw() -> void:
	if _sheet == null:
		return
	for i in 4:
		var f := i + 4 if i == hot else i
		draw_texture_rect_region(_sheet, Rect2(X, Y0 + STEP * i, W, H), Rect2(0, H * f, W, H))


func _gui_input(ev: InputEvent) -> void:
	if not _active:
		return
	if ev is InputEventMouseMotion:
		_set_hot(_item_at(ev.position))
	elif ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		var i := _item_at(ev.position)
		if Game.touch:
			if ev.pressed:
				_set_hot(i)
			elif i >= 0 and i == hot:
				accept_event()
				chosen.emit(i)
		elif ev.pressed and i >= 0:
			_set_hot(i)
			accept_event()
			chosen.emit(i)


func _unhandled_input(ev: InputEvent) -> void:
	if not _active or not visible:
		return
	if ev.is_action_pressed("ui_down"):
		_set_hot((hot + 1) % 4)
	elif ev.is_action_pressed("ui_up"):
		_set_hot((hot + 3) % 4 if hot >= 0 else 3)
	elif ev.is_action_pressed("ui_accept") and hot >= 0:
		get_viewport().set_input_as_handled()
		chosen.emit(hot)
