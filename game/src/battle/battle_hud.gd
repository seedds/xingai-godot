class_name BattleHUD
extends Control
## Battle overlay: hovered-unit info, terrain, turn/weather, phase & goal banners, HP popups.

var stage: BattleStage
var hover_unit: BUnit
var hover_cell := Vector2i(-1, -1)
var _banner_text := ""
var _banner_a := 0.0
var _picture: Texture2D
var popups: Array = []     # [{text, pos(world), t, color}]


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	var alive := []
	for p in popups:
		p["t"] += delta
		if p["t"] < 1.0:
			alive.append(p)
	popups = alive
	queue_redraw()


func set_hover(c: Vector2i) -> void:
	hover_cell = c
	hover_unit = stage.unit_at(c) if stage else null
	queue_redraw()


func popup_number(text: String, cell: Vector2i, color := Color(1, 1, 1)) -> void:
	popups.append({"text": text, "cell": cell, "t": 0.0, "color": color})


func phase_banner(text: String) -> void:
	_banner_text = text
	if Game.autoplay:
		return
	var tw := create_tween()
	tw.tween_property(self, "_banner_a", 1.0, 0.25)
	tw.tween_interval(0.7)
	tw.tween_property(self, "_banner_a", 0.0, 0.25)
	await tw.finished


func goal_banner(text: String) -> void:
	await phase_banner(text)


func show_picture(t: Texture2D) -> void:
	_picture = t
	queue_redraw()


func _draw() -> void:
	if stage == null:
		return
	var vs := get_viewport_rect().size
	if _picture:
		draw_texture(_picture, Vector2(0, 40))
	# floating numbers
	for p in popups:
		var c: Vector2i = p["cell"]
		var wp := stage.view.cell_pos(c) - stage.view.camera.position + Vector2(24, 10 - 22 * float(p["t"]))
		var col: Color = p["color"]
		col.a = 1.0 - maxf(float(p["t"]) - 0.6, 0) / 0.4
		UIStyle.draw_text(self, wp - Vector2(Assets.font().get_string_size(p["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x / 2, 0), p["text"], col, 18)
	if not stage.field_ready:
		return
	# turn / weather (top right) — only once the battle proper has started
	if stage.turn <= 0:
		return
	var t := "第 %d 回合" % stage.turn
	if stage.turn_limit > 0:
		t += " / %d" % stage.turn_limit
	t += "　" + BattleStage.WEATHER_NAMES[stage.weather()]
	var tw := Assets.font().get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var tr := Rect2(vs.x - tw - 20, 4, tw + 16, 22)
	draw_rect(tr, Color(0, 0, 0, 0.55))
	UIStyle.draw_text(self, tr.position + Vector2(8, 16), t, Color(1, 1, 1), 14)
	# hovered unit / terrain panel
	if hover_cell.x >= 0 and stage.view.in_bounds(hover_cell):
		_draw_info(vs)
	# phase banner
	if _banner_a > 0.01:
		var f := Assets.font()
		var sz := f.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28)
		var r := Rect2((vs.x - sz.x) / 2 - 30, vs.y * 0.42 - 30, sz.x + 60, 46)
		draw_rect(r, Color(0, 0, 0, 0.6 * _banner_a))
		UIStyle.draw_text(self, Vector2((vs.x - sz.x) / 2, vs.y * 0.42 + 2), _banner_text, Color(1, 0.9, 0.6, _banner_a), 28)


func _draw_info(vs: Vector2) -> void:
	var u := hover_unit
	var terr := stage.view.terrain_at(hover_cell)
	var tname := Game.terrain_name(terr)
	var cam := stage.view.camera.position
	var cell_screen := stage.view.cell_pos(hover_cell) - cam
	var on_left := cell_screen.x > vs.x / 2
	var w := 268.0 if u else 120.0
	var h := 96.0 if u else 30.0
	var x := 6.0 if on_left else vs.x - w - 6
	var y := vs.y - h - 6
	var r := Rect2(x, y, w, h)
	UIStyle.draw_panel(self, r)
	if u == null:
		UIStyle.draw_text(self, r.position + Vector2(10, 20), tname, Color(1, 1, 1), 14)
		return
	var p := u.person
	var face := p.face_tex(true)
	if face == null:
		face = p.face_tex()
	if face:
		draw_texture_rect(face, Rect2(r.position + Vector2(6, 8), Vector2(80, 80)), false)
	var tx := r.position.x + 92
	var col := Color(1, 0.55, 0.5) if u.side == BUnit.Side.ENEMY else (Color(0.6, 1, 0.6) if u.side == BUnit.Side.FRIEND else UIStyle.NAME_COLOR)
	UIStyle.draw_text(self, Vector2(tx, r.position.y + 20), p.name, col, 15)
	UIStyle.draw_text(self, Vector2(tx, r.position.y + 38), "%s Lv%d" % [p.class_name_str(), p.level], Color(1, 1, 1), 13)
	_bar(Vector2(tx, r.position.y + 46), 110, u.hp, u.max_hp(), Color(0.9, 0.25, 0.2), "兵")
	_bar(Vector2(tx, r.position.y + 64), 110, u.mp, u.max_mp(), Color(0.3, 0.5, 1.0), "策")
	var eff := Rules.terrain_effect(u, terr) * 10
	UIStyle.draw_text(self, Vector2(tx, r.position.y + 92), "%s %d%%" % [tname, eff], Color(0.85, 0.85, 0.7), 12)
	var st := ""
	if u.status & BUnit.ST_POISON: st += "毒"
	if u.status & BUnit.ST_CONFUSION: st += "乱"
	if u.status & BUnit.ST_PARALYSIS: st += "麻"
	if u.status & BUnit.ST_SEAL: st += "封"
	if u.status & BUnit.ST_FEAR: st += "怯"
	if st != "":
		UIStyle.draw_text(self, Vector2(r.end.x - 40, r.position.y + 20), st, Color(1, 0.4, 1), 13)


func _bar(pos: Vector2, w: float, v: int, m: int, c: Color, label: String) -> void:
	UIStyle.draw_text(self, pos + Vector2(0, 13), label, Color(0.9, 0.9, 0.9), 12)
	var r := Rect2(pos + Vector2(16, 3), Vector2(w - 16, 10))
	draw_rect(r, Color(0.1, 0.1, 0.1))
	if m > 0:
		draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(float(v) / m, 0, 1), r.size.y)), c)
	draw_rect(r, Color(0.8, 0.7, 0.4), false, 1)
	UIStyle.draw_text(self, pos + Vector2(w + 4, 13), "%d/%d" % [v, m], Color(1, 1, 1), 11)
