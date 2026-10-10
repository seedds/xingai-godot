class_name BattleHUD
extends Control
## Battle overlay: the hovered unit's panel (portrait, class / level, HP / MP / SP, the four ailment counters, buff
## arrows, terrain and its effect %), the turn / limit with the weather panel (Weather.e5 frames, 0x449ef0),
## phase banners (我军阶段 / 敌军阶段), the victory-condition panel, floating numbers and story pictures.

const AILMENTS := [["麻", BUnit.ST_PARALYSIS], ["禁", BUnit.ST_SEAL], ["乱", BUnit.ST_CONFUSION], ["毒", BUnit.ST_POISON]]
const BUFF_NAMES := ["攻", "防", "精", "爆", "士", "移"]

var stage: BattleStage
var hover_unit: BUnit
var hover_cell := Vector2i(-1, -1)
var show_panel := true
var _banner_text := ""
var _banner_a := 0.0
var _picture: Texture2D
var popups: Array = []     # [{text, cell, t, color}]
var _weather_tex: Array[Texture2D] = []
var _anim_t := 0.0


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_anim_t += delta
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
	if Game.autoplay:
		return
	popups.append({"text": text, "cell": cell, "t": 0.0, "color": color})


## Phase banner (TurnBanner 0x44ac28): "我军阶段" with the turn line / "敌军阶段".
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


## op 0x1a: the victory-condition panel (0x44be80) with the stored lines and a line for the turn limit.
func goal_panel(text: String, limit: int) -> void:
	var t := text
	if limit > 0:
		t += "\n回合限制：%d回合" % limit
	await stage.ui.dialog.talk(null, "", t, false)


## The weather panel is redrawn when the shown weather changes (0x449f91).
func weather_changed() -> void:
	queue_redraw()


func show_picture(t: Texture2D) -> void:
	_picture = t
	queue_redraw()


func _weather_frames(w: int) -> Texture2D:
	if _weather_tex.is_empty():
		for i in 5:
			var p := "gfx/effects/weather/%d.png" % i
			_weather_tex.append(Assets.tex(p) if Assets.exists(p) else null)
	return _weather_tex[clampi(w, 0, 4)]


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
	_draw_turn(vs)
	if show_panel and hover_cell.x >= 0 and stage.view.in_bounds(hover_cell):
		hover_unit = stage.unit_at(hover_cell)
		_draw_info(vs)
	if _banner_a > 0.01:
		var f := Assets.font()
		var sz := f.get_string_size(_banner_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 28)
		var r := Rect2((vs.x - sz.x) / 2 - 30, vs.y * 0.42 - 30, sz.x + 60, 46)
		draw_rect(r, Color(0, 0, 0, 0.6 * _banner_a))
		UIStyle.draw_text(self, Vector2((vs.x - sz.x) / 2, vs.y * 0.42 + 2), _banner_text, Color(1, 0.9, 0.6, _banner_a), 28)


## Turn / limit and the weather panel (Weather.e5: 4 frames of 216×50, picked by the shown weather) in the top
## right corner.
func _draw_turn(vs: Vector2) -> void:
	if not stage.view.input_enabled:
		return      # the opening (scene 0) has no turn yet
	var w := stage.weather()
	var wt := _weather_frames(w)
	var x0 := vs.x - 216 - 4
	var y0 := 4.0
	if wt:
		var fr := int(_anim_t * 6.0) % 4
		draw_texture_rect_region(wt, Rect2(x0, y0, 216, 50), Rect2(0, fr * 50, 216, 50))
		draw_rect(Rect2(x0, y0, 216, 50), Color(0.25, 0.2, 0.1), false, 1.0)
	var t := ("最终回合" if stage.turn >= stage.turn_limit else "第 %d 回合" % stage.turn)
	if stage.turn_limit > 0:
		t += " / %d" % stage.turn_limit
	t += "　" + BattleStage.WEATHER_NAMES[clampi(w, 0, 4)]
	var f := Assets.font()
	var tw := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
	var tr := Rect2(vs.x - tw - 20, y0 + 52, tw + 16, 22)
	draw_rect(tr, Color(0, 0, 0, 0.55))
	UIStyle.draw_text(self, tr.position + Vector2(8, 16), t, Color(1, 1, 1), 14)


func _draw_info(vs: Vector2) -> void:
	var u := hover_unit
	var terr := Rules.terrain_at(hover_cell)
	var tname := Game.terrain_name(terr) if terr != 0xff else ""
	var cam := stage.view.camera.position
	var cell_screen := stage.view.cell_pos(hover_cell) - cam
	var on_left := cell_screen.x > vs.x / 2
	var w := 300.0 if u else 150.0
	var h := 122.0 if u else 50.0
	var x := 6.0 if on_left else vs.x - w - 6
	var y := vs.y - h - 6
	var r := Rect2(x, y, w, h)
	UIStyle.draw_panel(self, r)
	if u == null:
		UIStyle.draw_text(self, r.position + Vector2(10, 20), tname, Color(1, 1, 1), 14)
		var rg := Rules.regen_pct(hover_cell)
		if rg > 0:
			UIStyle.draw_text(self, r.position + Vector2(10, 40), "恢复 %d%%" % rg, Color(0.6, 1, 0.6), 12)
		return
	var p := u.person
	var face := p.face_tex()
	if face:
		draw_texture_rect(face, Rect2(r.position + Vector2(6, 8), Vector2(80, 80)), false)
	var tx := r.position.x + 92
	var col := Color(1, 0.55, 0.5) if u.side() == 0 else (Color(0.6, 1, 0.6) if u.kind == 1 else UIStyle.NAME_COLOR)
	UIStyle.draw_text(self, Vector2(tx, r.position.y + 20), p.name, col, 15)
	UIStyle.draw_text(self, Vector2(tx + 92, r.position.y + 20), "%s Lv%d" % [p.class_name_str(), p.level], Color(1, 1, 1), 13)
	_bar(Vector2(tx, r.position.y + 28), 140, u.hp, u.max_hp(), Color(0.9, 0.25, 0.2), "兵")
	_bar(Vector2(tx, r.position.y + 46), 140, u.mp, u.max_mp(), Color(0.3, 0.5, 1.0), "策")
	if Rules.ev(4059) == 0:
		_bar(Vector2(tx, r.position.y + 64), 140, p.sp, 255, Color(0.95, 0.75, 0.2), "气")
	# ailments: the 2-bit turn counters
	var ax := tx
	for a in AILMENTS:
		var n := u.status_count(a[1])
		if n > 0:
			UIStyle.draw_text(self, Vector2(ax, r.position.y + 98), "%s%d" % [a[0], n], Color(1, 0.4, 1), 13)
			ax += 34
	# buff arrows (levels 4..6 up, 0..2 down)
	var bx := r.position.x + 8
	for i in 6:
		var b := u.buff(i)
		if b == 3:
			continue
		var up := b > 3
		var s: String = BUFF_NAMES[i] + ("↑" if up else "↓")
		UIStyle.draw_text(self, Vector2(bx, r.position.y + 116), s, Color(1, 0.85, 0.3) if up else Color(0.6, 0.6, 1), 12)
		bx += 30
	var eff: int = Rules.terrain_pct(u, terr)[1] if terr != 0xff else 100
	UIStyle.draw_text(self, Vector2(r.end.x - 96, r.position.y + 116), "%s %d%%" % [tname, eff], Color(0.85, 0.85, 0.7), 12)


func _bar(pos: Vector2, w: float, v: int, m: int, c: Color, label: String) -> void:
	UIStyle.draw_text(self, pos + Vector2(0, 13), label, Color(0.9, 0.9, 0.9), 12)
	var r := Rect2(pos + Vector2(16, 3), Vector2(w - 16, 10))
	draw_rect(r, Color(0.1, 0.1, 0.1))
	if m > 0:
		draw_rect(Rect2(r.position, Vector2(r.size.x * clampf(float(v) / m, 0, 1), r.size.y)), c)
	draw_rect(r, Color(0.8, 0.7, 0.4), false, 1)
	UIStyle.draw_text(self, pos + Vector2(w + 4, 13), "%d/%d" % [v, m], Color(1, 1, 1), 11)
