class_name StatusPanel
extends Control
## Character status window (portrait, class, level, stats, equipment).

signal closed

var person: Person


static func show_person(ui: CanvasLayer, p: Person) -> void:
	var s := StatusPanel.new()
	s.person = p
	ui.add_child(s)
	await s.closed
	s.queue_free()


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _draw() -> void:
	var r := Rect2(60, 50, 520, 380)
	UIStyle.draw_panel(self, r)
	var p := person
	var face := p.face_tex()
	if face:
		draw_texture_rect(face, Rect2(r.position + Vector2(16, 16), Vector2(120, 120)), false)
	var x := r.position.x + 152
	var y := r.position.y + 36
	UIStyle.draw_text(self, Vector2(x, y), p.name, UIStyle.NAME_COLOR, 20)
	UIStyle.draw_text(self, Vector2(x, y + 28), "%s　Lv %d　经验 %s" % [p.class_name_str(), p.level, "—" if p.exp >= 255 else str(p.exp)])
	UIStyle.draw_text(self, Vector2(x, y + 54), "兵力 %d　　策略 %d　　移动 %d" % [p.max_hp(), p.max_mp(), p.move_points()])
	var names := ["攻击", "防御", "精神", "爆发", "士气"]
	for i in 5:
		var yy := r.position.y + 160 + i * 26
		UIStyle.draw_text(self, Vector2(r.position.x + 24, yy), "%s　%4d" % [names[i], p.stat(i)])
		var w := clampf(p.stat(i) / 6.0, 0, 200)
		draw_rect(Rect2(r.position.x + 130, yy - 12, w, 10), Color(0.9, 0.7, 0.2))
	var eq := [["武器", p.weapon, p.weapon_lvl], ["防具", p.armor, p.armor_lvl], ["辅助", p.accessory, 0]]
	for i in 3:
		var e: Array = eq[i]
		var nm := "—"
		if e[1] >= 0:
			nm = str(Game.item(e[1]).get("name", "?"))
			if e[2] > 0 and e[2] < 0xff:
				nm += "  Lv%d" % e[2]
		UIStyle.draw_text(self, Vector2(r.position.x + 350, r.position.y + 160 + i * 30), "%s：%s" % [e[0], nm])
	var bio := Game.text(922 + p.id)
	if bio != "":
		var f := Assets.font()
		draw_multiline_string(f, Vector2(r.position.x + 24, r.position.y + 310), bio, HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 48, 13, -1, Color(0.85, 0.85, 0.9))


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		closed.emit()
		accept_event()


func _unhandled_input(ev: InputEvent) -> void:
	if ev.is_action_pressed("ui_accept") or ev.is_action_pressed("ui_cancel"):
		closed.emit()
		get_viewport().set_input_as_handled()
