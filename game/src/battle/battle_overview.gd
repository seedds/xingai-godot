class_name BattleOverview
extends Control
## 战场缩小图 (menu 情报 → 0x6c → 0x449d96, battle only): the modeless window 0x4b5fd8 (proc 0x4603c1) with the
## battle map at 1/8 scale. Redraw 0x44a88a: the reduced map (built at map load by 0x473ccb: every 8th pixel of every
## 8th row, 6 × 6 px per cell), then the units 0x44a400 and the view frame 0x44a6dd.
##   Units: every unit on the map (state 2) not hidden by the fog (0x42a67b: byte EV[4087] = 0, mode u8 0x501bd2 ≥ 2,
##   visibility 0x4934b0 & 0xd = 0) as a 5 × 5 square at (x·6, y·6) in the colour of its side (+5, 0x413172): 0 →
##   palette 0x28, 1 → 0x24, 2 → 0x36, 3 → 0x36 (0x58 with byte EV[4053] ≠ 0), else 0x7d; a player-controlled unit
##   (+0xe = 7) that has moved and acted (+0xd bits 2 and 4) also gets an inner 3 × 3 square in 0x2e.
##   View frame: the 1-px outline (palette 0xf) of the view, 6 px per cell.
## Mouse (0x460cb1 / 0x460ec0 / 0x461158): a press inside the frame while the player phase waits for input (B+0x520)
## drags the frame in steps of 6 px, kept inside the map; leaving the map cancels; the release scrolls the battle view
## to the frame. Shown by the menu (or brought to the front), at the battle start with 自动显示战场缩小图 (GS+0 bit 3,
## 0x44f058) and during op 0x12's choice box (0x411aa6); hidden by its close box (0x9cbd) and at the end of the battle
## (0x41ba73).
## [G] The port draws the window inside the game screen at its top-right corner (the original places it right of the
## main window's view, 0x44a971) with a plain caption bar; the caption drags it as the OS would; the frame follows the
## port's free camera (camera px / 8).

const S := 6                 # px per cell
const CAP := 18              # caption bar height
const BORDER := 2

var st: BattleStage
var _img: Texture2D
var _img_map := -1
var _drag := false           # dragging the view frame (0x4b5f80 +0)
var _press := Vector2.ZERO
var _frame0 := Vector2.ZERO
var _frame := Vector2.ZERO   # frame top-left (px in the reduced map) while dragging
var _move := false           # dragging the window by its caption
var _move_from := Vector2.ZERO


static func ensure(stage: BattleStage) -> BattleOverview:
	if stage.overview != null and is_instance_valid(stage.overview):
		return stage.overview
	var o := BattleOverview.new()
	o.st = stage
	o.mouse_filter = Control.MOUSE_FILTER_STOP
	o.visible = false
	stage.ui.add_child(o)
	if stage.hud and stage.hud.get_parent() == stage.ui:
		stage.ui.move_child(o, stage.hud.get_index() + 1)
	stage.overview = o
	return o


## 0x449d96: shown (with a full redraw) unless already visible.
func open() -> void:
	if st.view == null or st.view.map_w == 0:
		return
	_build()
	if not visible:
		var vs := st.view.view_size()
		position = Vector2(maxf(0.0, vs.x - size.x - 4), 4)
		visible = true
	queue_redraw()


func close() -> void:
	visible = false
	_drag = false
	_move = false


## The reduced map 0x473ccb (rebuilt when the map changes).
func _build() -> void:
	var v := st.view
	size = Vector2(v.map_w * S + 2 * BORDER, v.map_h * S + CAP + 2 * BORDER)
	if _img_map == v.map_id and _img != null:
		return
	_img_map = v.map_id
	_img = null
	var t := v.map_sprite.texture
	if t == null:
		return
	var src := t.get_image()
	if src == null:
		return
	if src.is_compressed():
		src.decompress()
	var im := src.duplicate() as Image
	im.convert(Image.FORMAT_RGB8)
	im.resize(v.map_w * S, v.map_h * S, Image.INTERPOLATE_NEAREST)     # x·src_w / dst_w: every 8th pixel
	_img = ImageTexture.create_from_image(im)


func _body() -> Vector2:
	return Vector2(BORDER, BORDER + CAP)


## The view frame (0x44a6dd) in reduced-map px: the camera's top-left and the view's size, 1/8 scale.
func _view_frame() -> Rect2:
	var v := st.view
	return Rect2(v.camera.position / 8.0, v.view_size() / 8.0)


func _process(_d: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	if st == null or st.view == null:
		return
	var v := st.view
	var w := v.map_w * S
	var h := v.map_h * S
	# window: 3-D border, caption with the title and the close box
	draw_rect(Rect2(Vector2.ZERO, size), Color8(192, 192, 192))
	draw_rect(Rect2(0, 0, size.x, 1), Color.WHITE)
	draw_rect(Rect2(0, 0, 1, size.y), Color.WHITE)
	draw_rect(Rect2(0, size.y - 1, size.x, 1), Color8(64, 64, 64))
	draw_rect(Rect2(size.x - 1, 0, 1, size.y), Color8(64, 64, 64))
	draw_rect(Rect2(BORDER, BORDER, w, CAP - 1), Color8(0, 0, 128))
	var f := Assets.font()
	draw_string(f, Vector2(BORDER + 4, BORDER + 13), "战场缩小图", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	var cb := _close_box()
	draw_rect(cb, Color8(192, 192, 192))
	draw_string(f, cb.position + Vector2(3, 11), "×", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.BLACK)
	var o := _body()
	if _img:
		draw_texture(_img, o)
	else:
		draw_rect(Rect2(o, Vector2(w, h)), Color.BLACK)
	# units 0x44a400
	var fog := Mem.r8(0x501bd2) >= 2 and Rules.evb(4087) == 0
	if fog:
		Rules.vis_update()
	for u: BUnit in st.units:
		if u.pid < 0 or u.state != BUnit.STATE_ON_MAP:
			continue
		var p := u.pos
		if fog and Mem.r8(Rules.VIS + p.x + p.y * v.map_w) & 0xd == 0:
			continue
		var side := u.kind
		if side > 6:
			side = 0
		var col := 0x7d
		match side:
			0: col = 0x28
			1: col = 0x24
			2: col = 0x36
			3: col = 0x58 if Rules.evb(4053) != 0 else 0x36
		var at := o + Vector2(p * S)
		draw_rect(Rect2(at, Vector2(5, 5)), Text66.pal(col))
		if u.ai == 7 and u.flags & 6 == 6:
			draw_rect(Rect2(at + Vector2(1, 1), Vector2(3, 3)), Text66.pal(0x2e))
	# view frame 0x44a6dd
	var fr := _view_frame()
	if _drag:
		fr.position = _frame
	fr.position += o
	draw_rect(Rect2(fr.position + Vector2(0.5, 0.5), fr.size - Vector2.ONE), Text66.pal(0xf), false, 1.0)


func _close_box() -> Rect2:
	return Rect2(size.x - BORDER - 16, BORDER + 2, 14, CAP - 5)


func _gui_input(ev: InputEvent) -> void:
	if st == null or st.view == null:
		return
	var mb := ev as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if mb.pressed:
			if _close_box().has_point(mb.position):
				close()
			elif mb.position.y < BORDER + CAP:
				_move = true
				_move_from = mb.position
			elif Mem.r8(BattleStage.B + 0x520) != 0:
				# 0x460cb1: only a press inside the frame starts a drag
				var p := mb.position - _body()
				var fr := _view_frame()
				if fr.grow(0.5).has_point(p):
					_drag = true
					_press = p
					_frame0 = fr.position
					_frame = fr.position
		else:
			_move = false
			if _drag:
				# 0x461158: the view goes to the frame
				_drag = false
				var v := st.view
				v.camera.position = v.clamp_cam(_frame * 8.0)
		return
	var mm := ev as InputEventMouseMotion
	if mm == null:
		return
	accept_event()
	if _move:
		var vs := st.view.view_size()
		position = (position + mm.position - _move_from).clamp(Vector2.ZERO, (vs - size).max(Vector2.ZERO))
	elif _drag:
		# 0x460ec0: steps of 6 px from the press, the frame kept inside the map; leaving the map cancels
		var p := mm.position - _body()
		var map := Vector2(st.view.map_w * S, st.view.map_h * S)
		if p.x < 0 or p.y < 0 or p.x >= map.x or p.y >= map.y:
			_drag = false
			return
		var d := Vector2(int((p.x - _press.x) / S) * S, int((p.y - _press.y) / S) * S)
		var fs := _view_frame().size
		_frame = (_frame0 + d).clamp(Vector2.ZERO, (map - fs).max(Vector2.ZERO))
