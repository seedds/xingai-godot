class_name BattleView
extends Node2D
## Map rendering, highlight overlays, cursor and camera for the battle screen.

signal cell_clicked(cell: Vector2i, button: int)
signal cell_hovered(cell: Vector2i)

const CELL := 48

var map_id := -1
var map_w := 0
var map_h := 0
var map_sprite: Sprite2D
var overlay: Node2D
var units_layer: Node2D
var fx_layer: Node2D
var camera: Camera2D
var cursor_cell := Vector2i.ZERO
var show_cursor := true
var input_enabled := true

var _hl_move: Dictionary = {}
var _hl_attack: Dictionary = {}
var _hl_area: Dictionary = {}
var _hl_path: Array[Vector2i] = []
var goal_cells: Array[Vector2i] = []:
	set(v):
		goal_cells = v
		if overlay: overlay.queue_redraw()
var patch_layer: Node2D
var marks: Dictionary = {}
var _drag_from := Vector2.ZERO
var _dragging := false
var _touch_down := false         # touch: a press this view saw, not yet released
var _touch_panned := false       # touch: that press became a drag (pans the map, no click)
var _cam_target := Vector2.ZERO
var _cam_tween: Tween


func _init() -> void:
	map_sprite = Sprite2D.new()
	map_sprite.centered = false
	add_child(map_sprite)
	patch_layer = Node2D.new()
	add_child(patch_layer)
	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	units_layer = Node2D.new()
	units_layer.y_sort_enabled = true
	add_child(units_layer)
	fx_layer = Node2D.new()
	fx_layer.z_index = 5
	add_child(fx_layer)
	var cur := Node2D.new()
	cur.z_index = 6
	cur.name = "Cursor"
	cur.draw.connect(_draw_cursor.bind(cur))
	add_child(cur)
	camera = Camera2D.new()
	camera.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	add_child(camera)


func load_map(id: int, fill_terrain := true) -> void:
	map_id = id
	var idx: Dictionary = Assets.json("gfx/maps/index.json")
	var info: Dictionary = {}
	for m in idx["maps"]:
		if int(m["id"]) == id:
			info = m
			break
	if info.is_empty():
		push_error("map %d not found" % id)
		return
	map_w = int(info["width"])
	map_h = int(info["height"])
	# terrain lives in the engine's map buffer (scripts read it through [0x4aeb44]); a restored save
	# already holds the buffer with the battle's terrain changes
	if fill_terrain or Mem.r32(Mem.MAP_PTR) != Mem.MAP_BUF:
		var rows: Array = info["terrain"]
		for y in map_h:
			var row: Array = rows[y]
			for x in map_w:
				Mem.w8(Mem.MAP_BUF + 0x640 + y * map_w + x, int(row[x]))
		Mem.w32(Mem.MAP_PTR, Mem.MAP_BUF)
	Mem.w8(Mem.MAP_WH, map_w)
	Mem.w8(Mem.MAP_WH + 1, map_h)
	map_sprite.texture = Assets.tex("gfx/maps/" + str(info["image"]))
	camera.limit_left = 0
	camera.limit_top = 0
	camera.limit_right = map_w * CELL
	camera.limit_bottom = map_h * CELL
	camera.make_current()
	overlay.queue_redraw()


func terrain_at(c: Vector2i) -> int:
	if c.x < 0 or c.y < 0 or c.x >= map_w or c.y >= map_h:
		return -1
	return Mem.r8(Mem.MAP_BUF + 0x640 + c.y * map_w + c.x)


func set_terrain(c: Vector2i, t: int) -> void:
	if in_bounds(c):
		Mem.w8(Mem.MAP_BUF + 0x640 + c.y * map_w + c.x, t)


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < map_w and c.y < map_h


func cell_center(c: Vector2i) -> Vector2:
	return Vector2(c.x * CELL + CELL / 2.0, c.y * CELL + CELL / 2.0)


func cell_pos(c: Vector2i) -> Vector2:
	return Vector2(c.x * CELL, c.y * CELL)


func cell_at(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / CELL), floori(world.y / CELL))


# ---------------------------------------------------------------- highlights
func set_move_cells(cells: Dictionary) -> void:
	_hl_move = cells
	overlay.queue_redraw()


func set_attack_cells(cells: Array) -> void:
	_hl_attack = {}
	for c in cells:
		_hl_attack[c] = true
	overlay.queue_redraw()


func set_area_cells(cells: Array) -> void:
	_hl_area = {}
	for c in cells:
		_hl_area[c] = true
	overlay.queue_redraw()


func set_path(p: Array[Vector2i]) -> void:
	_hl_path = p
	overlay.queue_redraw()


func clear_highlights() -> void:
	_hl_move = {}
	_hl_attack = {}
	_hl_area = {}
	_hl_path = []
	overlay.queue_redraw()


## Paste a Nima.wa 3x3-cell (144x144) terrain patch centred on cell c, coloured with this map's palette.
func add_patch(entry: int, c: Vector2i) -> Node:
	var sp := Sprite2D.new()
	sp.centered = false
	sp.position = cell_pos(c - Vector2i(1, 1))
	# HD pack: pre-upscaled with this map's palette (tools/upscale_assets.py patch_combos)
	sp.texture = Assets.hd_only("gfx/effects/map_patches/map%02d/%03d.png" % [map_id, entry])
	if sp.texture:
		patch_layer.add_child(sp)
		return sp
	var idx := Assets.image("gfx/effects/map_patches/idx/%03d.png" % entry)
	var pals: Variant = Assets.json("gfx/palettes/fei.json")
	if idx == null or pals == null:
		sp.free()
		return null
	var pal: Array = pals[map_id] if pals is Array else pals[str(map_id)]
	var cols: Array[Color] = []
	for h in pal:
		cols.append(Color.html(str(h)))
	idx.convert(Image.FORMAT_L8)
	var img := Image.create(idx.get_width(), idx.get_height(), false, Image.FORMAT_RGBA8)
	for y in idx.get_height():
		for x in idx.get_width():
			var k := int(round(idx.get_pixel(x, y).r * 255.0))
			img.set_pixel(x, y, cols[k] if k < cols.size() else Color.BLACK)
	if Assets.hd_active():
		# no AI-upscaled patch for this palette: a smooth 4x resize blends in with the HD map
		img.resize(img.get_width() * 4, img.get_height() * 4, Image.INTERPOLATE_LANCZOS)
		img.generate_mipmaps()
		var t := ImageTexture.create_from_image(img)
		t.set_size_override(idx.get_size())
		sp.texture = t
	else:
		sp.texture = ImageTexture.create_from_image(img)
	patch_layer.add_child(sp)
	return sp


## Small overlay marks (patch < 4): 0/2 fire, 1/3 other.
func add_mark(kind: int, c: Vector2i) -> void:
	marks[c] = kind
	overlay.queue_redraw()


func _draw_overlay() -> void:
	var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() / 250.0)
	for c in goal_cells:
		overlay.draw_rect(Rect2(cell_pos(c) + Vector2(2, 2), Vector2(CELL - 4, CELL - 4)), Color(1.0, 0.9, 0.2, 0.22 * pulse))
	for c in marks:
		var col := Color(1, 0.4, 0.1, 0.55) if int(marks[c]) in [0, 2] else Color(0.3, 0.3, 0.3, 0.5)
		overlay.draw_circle(cell_center(c), 14, col)
	for c in _hl_move:
		overlay.draw_rect(Rect2(cell_pos(c) + Vector2(1, 1), Vector2(CELL - 2, CELL - 2)), Color(0.25, 0.45, 1.0, 0.38 * pulse))
	for c in _hl_attack:
		overlay.draw_rect(Rect2(cell_pos(c) + Vector2(1, 1), Vector2(CELL - 2, CELL - 2)), Color(1.0, 0.25, 0.2, 0.35 * pulse))
	for c in _hl_area:
		overlay.draw_rect(Rect2(cell_pos(c) + Vector2(3, 3), Vector2(CELL - 6, CELL - 6)), Color(1.0, 0.85, 0.2, 0.45), false, 2.0)
	for c in _hl_path:
		overlay.draw_circle(cell_center(c), 4, Color(1, 1, 1, 0.7))


func _draw_cursor(n: Node2D) -> void:
	if not show_cursor:
		return
	var r := Rect2(cell_pos(cursor_cell), Vector2(CELL, CELL))
	var t := (Time.get_ticks_msec() / 200) % 2
	var g := 2.0 + t
	var col := Color(1, 1, 1)
	var l := 12.0
	var p := r.position - Vector2(g, g)
	var q := r.end + Vector2(g, g)
	for corner in [[p, Vector2(1, 0), Vector2(0, 1)], [Vector2(q.x, p.y), Vector2(-1, 0), Vector2(0, 1)], [Vector2(p.x, q.y), Vector2(1, 0), Vector2(0, -1)], [q, Vector2(-1, 0), Vector2(0, -1)]]:
		n.draw_line(corner[0], corner[0] + corner[1] * l, Color.BLACK, 4)
		n.draw_line(corner[0], corner[0] + corner[2] * l, Color.BLACK, 4)
		n.draw_line(corner[0], corner[0] + corner[1] * l, col, 2)
		n.draw_line(corner[0], corner[0] + corner[2] * l, col, 2)


func _process(delta: float) -> void:
	if not _hl_move.is_empty() or not _hl_attack.is_empty():
		overlay.queue_redraw()
	get_node("Cursor").queue_redraw()
	_edge_scroll(delta)


# ---------------------------------------------------------------- camera
func view_size() -> Vector2:
	return get_viewport_rect().size


func clamp_cam(p: Vector2) -> Vector2:
	var vs := view_size()
	return Vector2(clampf(p.x, 0, maxf(0, map_w * CELL - vs.x)), clampf(p.y, 0, maxf(0, map_h * CELL - vs.y)))


func center_on(c: Vector2i, animate := true) -> void:
	var vs := view_size()
	var target := clamp_cam(cell_center(c) - vs / 2)
	_scroll_to(target, animate)


## Scroll only if the cell is not comfortably inside the view.
func ensure_visible(c: Vector2i, animate := true) -> void:
	var vs := view_size()
	var p := cell_pos(c)
	var cam := camera.position
	var margin := CELL * 1.5
	if p.x < cam.x + margin or p.y < cam.y + margin or p.x + CELL > cam.x + vs.x - margin or p.y + CELL > cam.y + vs.y - margin:
		center_on(c, animate)


func _scroll_to(target: Vector2, animate: bool) -> void:
	if _cam_tween:
		_cam_tween.kill()
	if not animate or camera.position.distance_to(target) < 1:
		camera.position = target
		return
	_cam_tween = create_tween()
	_cam_tween.tween_property(camera, "position", target, clampf(camera.position.distance_to(target) / 900.0, 0.12, 0.45))
	await _cam_tween.finished


func scroll_by(d: Vector2) -> void:
	camera.position = clamp_cam(camera.position + d)


## Pixels per second the map scrolls while the mouse rests at a screen edge (frame-rate independent).
const EDGE_SCROLL_SPEED := 720.0


func _edge_scroll(delta: float) -> void:
	if Game.touch or not input_enabled or not get_window().has_focus():
		return     # (a touch screen leaves the pointer where the last tap was)
	var vs := view_size()
	var m := get_viewport().get_mouse_position()
	if m.x < 0 or m.y < 0 or m.x > vs.x or m.y > vs.y:
		return
	var d := Vector2.ZERO
	var e := 6.0
	if m.x < e: d.x = -1
	elif m.x > vs.x - e: d.x = 1
	if m.y < e: d.y = -1
	elif m.y > vs.y - e: d.y = 1
	if d != Vector2.ZERO:
		scroll_by(d * EDGE_SCROLL_SPEED * delta)


func move_cursor(c: Vector2i) -> void:
	if not in_bounds(c):
		return
	cursor_cell = c
	ensure_visible(c, true)
	cell_hovered.emit(c)


## World position of a mouse event (event position is in viewport coordinates).
func _world_of(ev: InputEventMouse) -> Vector2:
	return get_canvas_transform().affine_inverse() * ev.position


## Finger travel (viewport px) before a touch counts as a drag instead of a tap.
const TAP_SLOP := 10.0


## Touch: a tap clicks a cell on release (and shows its unit / terrain, as hovering does with a mouse); dragging
## pans the map. A release whose press this view didn't get (it closed a dialog or menu) is ignored.
func _touch_input(ev: InputEventMouse) -> void:
	if ev is InputEventMouseMotion:
		if not _touch_down or not (ev.button_mask & MOUSE_BUTTON_MASK_LEFT):
			return
		var mm := ev as InputEventMouseMotion
		if _touch_panned:
			scroll_by(-mm.relative)
		elif mm.position.distance_to(_drag_from) > TAP_SLOP:
			_touch_panned = true
			if _cam_tween:
				_cam_tween.kill()
			scroll_by(_drag_from - mm.position)     # include the slop, so the map stays under the finger
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_touch_down = true
			_touch_panned = false
			_drag_from = mb.position
		elif _touch_down:
			_touch_down = false
			if not _touch_panned:
				var c := cell_at(_world_of(mb))
				if in_bounds(c):
					cursor_cell = c
					cell_hovered.emit(c)
				cell_clicked.emit(c, MOUSE_BUTTON_LEFT)
		get_viewport().set_input_as_handled()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		cell_clicked.emit(cursor_cell, MOUSE_BUTTON_RIGHT)
		get_viewport().set_input_as_handled()


func _unhandled_input(ev: InputEvent) -> void:
	if not input_enabled:
		_touch_down = false
		return
	if Game.touch and ev is InputEventMouse:
		_touch_input(ev)
		return
	if ev is InputEventMouseMotion:
		if _dragging:
			scroll_by(-ev.relative)
			return
		var c := cell_at(_world_of(ev))
		if in_bounds(c) and c != cursor_cell:
			cursor_cell = c
			cell_hovered.emit(c)
	elif ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = ev.pressed
		elif ev.pressed and ev.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			var c := cell_at(_world_of(ev))
			if in_bounds(c):
				cursor_cell = c
			cell_clicked.emit(c, ev.button_index)
			get_viewport().set_input_as_handled()
	elif ev is InputEventKey and ev.pressed:
		var d := Vector2i.ZERO
		if ev.is_action_pressed("ui_left", true): d = Vector2i(-1, 0)
		elif ev.is_action_pressed("ui_right", true): d = Vector2i(1, 0)
		elif ev.is_action_pressed("ui_up", true): d = Vector2i(0, -1)
		elif ev.is_action_pressed("ui_down", true): d = Vector2i(0, 1)
		if d != Vector2i.ZERO:
			move_cursor(cursor_cell + d)
			get_viewport().set_input_as_handled()
		elif ev.is_action_pressed("ui_accept"):
			cell_clicked.emit(cursor_cell, MOUSE_BUTTON_LEFT)
			get_viewport().set_input_as_handled()
		elif ev.is_action_pressed("ui_cancel"):
			cell_clicked.emit(cursor_cell, MOUSE_BUTTON_RIGHT)
			get_viewport().set_input_as_handled()
