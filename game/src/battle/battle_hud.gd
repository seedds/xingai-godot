class_name BattleHUD
extends Control
## Battle overlay: the hovered unit's panel (portrait, class / level, HP / MP / SP, the four ailment counters, buff
## arrows, terrain and its effect %), the turn / limit with the weather panel (Weather.e5 frames, 0x449ef0),
## phase banners (我军阶段 / 敌军阶段), the victory-condition panel, floating numbers and story pictures; the display
## options of 环境设定 (docs/ai.md §5.6, bytes 0x501a65 + k, hotkeys '5'..'9' / 'A'..'P'): HP bars, buff arrows,
## 行动顺序 / AI仇恨 numbers, 危险区域 / Buff / 中毒 sprite tints, the AI方针 line and the 预览行动路线 arrows.

const AILMENTS := [["麻", BUnit.ST_PARALYSIS], ["禁", BUnit.ST_SEAL], ["乱", BUnit.ST_CONFUSION], ["毒", BUnit.ST_POISON]]
const BUFF_NAMES := ["攻", "防", "精", "爆", "士", "移"]
const OPT := 0x501a65          # display option bytes (k = 0..20), saved with the game
const OPT_HP := 0              # 5 显示生命条
const OPT_BUFF := 1            # 6 显示Buff状态
const OPT_ORDER := 9           # e 显示行动顺序
const OPT_AIVAL := 10          # f 显示AI仇恨
const OPT_THREAT := 11         # g 显示危险区域
const OPT_POLICY := 13         # i 显示AI方针
const OPT_PATH := 19           # o 预览行动路线
const TINT_AMOUNT := 0x28 / 100.0   # 0x40690c(…, 0x28, colour, 1): a 40 % blend
## [G] HP bar colours by unit colour (U+5): 我军, 友军, enemies (the original's 3-row palette table 0x43ed2e is
## not decoded).
const HP_COLORS := [Color8(64, 128, 255), Color8(64, 200, 96), Color8(232, 64, 48)]

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
var _under: Node2D            # 预览行动路线 (between the range overlay and the units)
var _over: Node2D             # HP bars, buff arrows, numbers (over the units, under the battle tint)
var _tinted: Dictionary = {}  # slot → true: sprite tints set here
var _threat: Dictionary = {}  # slot → true: enemies that could hit the current unit (危险区域)
var _threat_key: Array = []
var _order_key: Array = []
var _path_key: Array = []
var _path: Array[Vector2i] = []


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false


func _process(delta: float) -> void:
	_options_frame()
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
	UIStyle.draw_text(self, Vector2(r.end.x - 96, r.position.y + 98), policy_label(u), Color(0.85, 0.9, 1.0), 12)
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


# ------------------------------------------------------------------ display options (§5.6)
static func opt(k: int) -> bool:
	return Mem.r8(OPT + k) != 0


## Keyboard hook 0x413296: '5'..'9' toggle option key − '5', 'A'..'P' option key − 0x3c (no auto-repeat).
## [G] battle only, and not with a modifier (⌘F is the full-screen key).
func _unhandled_key_input(ev: InputEvent) -> void:
	if not visible or not (ev is InputEventKey) or not ev.pressed or ev.echo:
		return
	var k: InputEventKey = ev
	if k.ctrl_pressed or k.meta_pressed or k.alt_pressed:
		return
	var n := -1
	if k.keycode >= KEY_5 and k.keycode <= KEY_9:
		n = k.keycode - KEY_5
	elif k.keycode >= KEY_A and k.keycode <= KEY_P:
		n = k.keycode - KEY_A + 5
	if n < 0:
		return
	Mem.w8(OPT + n, Mem.r8(OPT + n) ^ 1)
	get_viewport().set_input_as_handled()
	queue_redraw()


func _ensure_layers() -> void:
	if _over != null and is_instance_valid(_over):
		return
	if stage == null or stage.view == null or stage.view.overlay == null:
		return
	_under = Node2D.new()
	_under.draw.connect(_draw_under)
	stage.view.add_child(_under)
	stage.view.move_child(_under, stage.view.overlay.get_index() + 1)
	_over = Node2D.new()
	_over.z_index = 3
	_over.draw.connect(_draw_over)
	stage.view.add_child(_over)


func _options_frame() -> void:
	var on := visible and stage != null and stage.field_ready
	if not on:
		if _over != null and is_instance_valid(_over):
			_over.visible = false
			_under.visible = false
		if not _tinted.is_empty():
			_set_tints({})
		return
	_ensure_layers()
	if _over == null:
		return
	_over.visible = true
	_under.visible = true
	_update_tints()
	_over.queue_redraw()
	_under.queue_redraw()


## The player phase's selection state (BattleInput.display) and its current unit.
func _cur() -> BUnit:
	return stage.current_unit if stage.current_unit != null and stage.current_unit.on_map() else null


func _shown() -> int:
	if stage.input == null or stage.phase != BattleStage.PH_PLAYER:
		return 0
	return stage.input.display


## Sprite tints of the unit drawer 0x43eae4 (40 % blends): 我军 / 友军 colours: Buff (option 6, slots < 20 with
## 0x501b00[slot] ≠ 0) orange 0xff8000; enemy colours: 中毒 green 0xa500, else 危险区域 red 0xff0000 when the
## threat probe 0x421cd6 says it could hit the current unit. [G] set only while the player phase waits for input
## (the hit flash of an attack uses the same tint).
func _update_tints() -> void:
	var want := {}
	var inp = stage.input
	var waiting: bool = inp != null and stage.phase == BattleStage.PH_PLAYER and (inp.idle or inp.display != 0)
	if waiting:
		_update_threat()
		for u in stage.units:
			if u.node == null or not u.on_map():
				continue
			if u.colour < 2:
				if opt(OPT_BUFF) and u.slot < 20 and Mem.r8(0x501b00 + u.slot) != 0:
					want[u.slot] = Color(1.0, 0x80 / 255.0, 0.0, TINT_AMOUNT)
			elif u.poisoned():
				want[u.slot] = Color(0.0, 0xa5 / 255.0, 0.0, TINT_AMOUNT)
			elif _threat.has(u.slot):
				want[u.slot] = Color(1.0, 0.0, 0.0, TINT_AMOUNT)
	_set_tints(want)


func _set_tints(want: Dictionary) -> void:
	for slot in _tinted.keys():
		if not want.has(slot):
			var n: UnitSprite = stage.units[slot].node if stage else null
			if n != null and is_instance_valid(n) and "tint" in n:
				n.set("tint", Color(0, 0, 0, 0))
			_tinted.erase(slot)
	for slot in want:
		var n2: UnitSprite = stage.units[slot].node
		if n2 != null and is_instance_valid(n2) and "tint" in n2 and n2.get("tint") != want[slot]:
			n2.set("tint", want[slot])
		_tinted[slot] = true


## 危险区域 0x421cd6 for every enemy-coloured unit: option on, an attack-range overlay up and a current unit of code
## 7; probed once per selection (the original probes while drawing each sprite).
func _update_threat() -> void:
	var cur := _cur()
	if not opt(OPT_THREAT) or not stage.input.range_up or cur == null or cur.ai != 7 or stage.ai == null:
		_threat = {}
		_threat_key = []
		return
	var key := [cur.slot, cur.pos, BUnit.gen, stage.input.display]
	if key == _threat_key:
		return
	_threat_key = key
	_threat = {}
	for e in stage.units:
		if e.active() and e.colour >= 2 and stage.ai.threat(e, cur):
			_threat[e.slot] = true


## 预览行动路线 0x427739: while a move range is shown, the path from the current unit to the cell under the cursor
## (0x437e23 / 0x427653), drawn with U_select[23] (10 frames 48×48: arrow heads ↑ → ↓ ←, ‖, =, ┌ ┘ ┐ └); the
## first cell is not drawn. [G] AI phases (the AI's destination 0x4b2c20) are not shown.
func _draw_under() -> void:
	if not opt(OPT_PATH) or _shown() != 1:
		return
	var cur := _cur()
	var c := hover_cell
	if cur == null or not stage.input.shown_reach.has(c) or c == cur.pos:
		return
	var key := [cur.slot, cur.pos, c, BUnit.gen]
	if key != _path_key:
		_path_key = key
		_path = [cur.pos]
		_path.append_array(Movement.path_to(cur, c))
	var path := _path
	if path.size() < 2:
		return
	var tex := Assets.tex("gfx/ui/u_select/23.png")
	if tex == null:
		return
	for i in range(1, path.size()):
		var a := path[i - 1] - path[i]                       # towards the previous cell
		var f := 0
		if i == path.size() - 1:
			f = _arrow_frame(-a)
		else:
			var b := path[i + 1] - path[i]                   # towards the next cell
			f = _join_frame(a, b)
		_under.draw_texture_rect_region(tex, Rect2(stage.view.cell_pos(path[i]), Vector2(48, 48)), Rect2(0, f * 48, 48, 48))


static func _arrow_frame(d: Vector2i) -> int:
	if d.y < 0:
		return 0
	if d.x > 0:
		return 1
	if d.y > 0:
		return 2
	return 3


static func _join_frame(a: Vector2i, b: Vector2i) -> int:
	if a.x == 0 and b.x == 0:
		return 4
	if a.y == 0 and b.y == 0:
		return 5
	var up := a.y < 0 or b.y < 0
	var left := a.x < 0 or b.x < 0
	if not up and not left:
		return 6          # ┌ right + down
	if up and left:
		return 7          # ┘
	if left:
		return 8          # ┐ left + down
	return 9              # └ up + right


## The per-sprite part of 0x43eae4 / 0x43e782: HP bar (option 5: the U_select[15] frame at y + 42, a 3-pixel bar of
## HP·40 / max HP, at least 1, at y + 43), buff arrows (option 6: 12×12 U_select[24], up i / down i + 6, 攻 防 精
## down the left edge and 爆 士 移 at x + 36, 15 px apart), 行动顺序 (option e: U+0xb of units with code ≠ 7; in the
## player phase only while a move range is shown, both sides' orders recomputed first by 0x44da7a) and AI仇恨
## (option f: 0x412f37 against the current unit while its move range — or, for a player unit, a target picker — is
## shown). A unit with HP 0 has no bar and no numbers.
func _draw_over() -> void:
	var hp_on := opt(OPT_HP)
	var buff_on := opt(OPT_BUFF)
	var order_on := opt(OPT_ORDER)
	var val_on := opt(OPT_AIVAL)
	if not (hp_on or buff_on or order_on or val_on):
		return
	var shown := _shown()
	var cur := _cur()
	var player := stage.phase == BattleStage.PH_PLAYER
	if order_on and player:
		if shown == 0:
			order_on = false
		else:
			var key := [shown, cur.slot if cur else -1, BUnit.gen]
			if key != _order_key and stage.ai != null:
				_order_key = key
				stage.ai.compute_order(false)
				stage.ai.compute_order(true)
	var val_ok := val_on and cur != null and (shown == 1 or (shown == 2 and cur.side() == 1)) and stage.ai != null
	var frame := Assets.tex("gfx/ui/u_select/15.png")
	var arrows := Assets.tex("gfx/ui/u_select/24.png")
	var f := Assets.font()
	for u in stage.units:
		if u.node == null or not u.on_map():
			continue
		var p: Vector2 = u.node.position
		var off: Variant = u.node.get("offset_px")       # the walking offset, while it moves
		if off is Vector2:
			p += off
		if hp_on:
			if u.hp == 0:
				continue
			var m := maxi(u.max_hp(), 1)
			var w := maxi(u.hp * 40 / m, 1)
			if frame:
				_over.draw_texture_rect_region(frame, Rect2(p + Vector2(0, 42), Vector2(48, 5)), Rect2(0, 5, 48, 5))
			var col: Color = HP_COLORS[clampi(u.colour, 0, 2)]
			_over.draw_rect(Rect2(p + Vector2(4, 43), Vector2(w, 1)), col.lightened(0.35))
			_over.draw_rect(Rect2(p + Vector2(4, 44), Vector2(w, 1)), col)
			_over.draw_rect(Rect2(p + Vector2(4, 45), Vector2(w, 1)), col.darkened(0.35))
		if buff_on and arrows:
			for i in 6:
				var b := u.buff(i)
				if b == 3:
					continue
				var icon := i if b > 3 else i + 6
				var q := p + Vector2(36 if i >= 3 else 0, 15 * (i % 3))
				_over.draw_texture_rect_region(arrows, Rect2(q, Vector2(12, 12)), Rect2(0, icon * 12, 12, 12))
		if order_on and u.ai != 7:
			_number(f, p + Vector2(4, 16), u.order, Color8(255, 255, 96))
		if val_ok and u.side() != cur.side():
			var v: int = stage.ai.ai_value(u, cur)
			if v != 0:
				_number(f, p + Vector2(18, 40), v, Color8(255, 128, 64))


## The numbers of 0x421da8 (font height 0x12, colours 0x3a / 0x28 of the text painter). [G] outlined text, the order
## at the top left, the AI value low in the middle (the original's offsets are not decoded; both at the top left
## would overlap).
func _number(f: Font, base: Vector2, v: int, col: Color) -> void:
	var s := str(v)
	_over.draw_string_outline(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 3, Color(0, 0, 0))
	_over.draw_string(f, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, col)


## AI方针 (option i, 0x42641e): the unit's policy label, else "友军" / "敌军" (the caller's default 0x440ba4).
func policy_label(u: BUnit) -> String:
	if not opt(OPT_POLICY):
		return "友军" if u.side() == 1 else "敌军"
	var t := u.target
	if t == 0xff:
		match u.ai:
			0: return "前往(%2d:%2d)" % [u.point.x, u.point.y]
			4: return "逃往(%2d:%2d)" % [u.point.x, u.point.y]
			1: return "出击"
			2: return "坚守"
			3: return "防御"
		return "可控" if u.ai >= 7 else ""
	var o: BUnit = stage.units[t] if t < stage.units.size() else null
	var name := o.person.name if o != null and o.pid >= 0 else ""
	return ("跟随" if (u.ai >> 2) != 0 else "锁定") + name
