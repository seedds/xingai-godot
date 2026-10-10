class_name UIStyle
extends RefCounted
## Shared look for windows/text. Classic CCZ-style framed panels.

const FONT_SIZE := 16
const FONT_SIZE_SMALL := 14
const TEXT_COLOR := Color(1, 1, 1)
const NAME_COLOR := Color(1.0, 0.92, 0.55)
const SHADOW := Color(0, 0, 0, 0.8)
const BG := Color(0.07, 0.10, 0.22, 0.92)
const BG2 := Color(0.12, 0.18, 0.36, 0.92)
const BORDER_OUT := Color(0.55, 0.45, 0.22)
const BORDER_IN := Color(0.95, 0.85, 0.55)
const HILITE := Color(0.95, 0.75, 0.25, 0.35)


static func panel_box() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = BG
	s.border_color = BORDER_IN
	s.set_border_width_all(2)
	s.set_corner_radius_all(3)
	s.shadow_color = Color(0, 0, 0, 0.5)
	s.shadow_size = 3
	s.set_content_margin_all(8)
	return s


static var _panel_tex: Texture2D
static var _panel_tried := false


## Original window texture: Qusi.wa blue dragon pattern (400x128 / 400x296).
static func panel_texture() -> Texture2D:
	if not _panel_tried:
		_panel_tried = true
		_panel_tex = Assets.tex("gfx/effects/qusi/03.png")
	return _panel_tex


static func draw_panel(ci: CanvasItem, r: Rect2) -> void:
	var t := panel_texture()
	if t:
		ci.draw_texture_rect(t, r, true, Color(1, 1, 1, 0.97))
		ci.draw_rect(r, Color(0, 0, 0.1, 0.25), true)
	else:
		ci.draw_rect(r, BG, true)
	ci.draw_rect(r, Color(0.05, 0.05, 0.15), false, 2.0)
	ci.draw_rect(r.grow(-2), BORDER_OUT, false, 1.0)
	ci.draw_rect(r.grow(-3), BORDER_IN, false, 1.0)


static func draw_text(ci: CanvasItem, pos: Vector2, text: String, color := TEXT_COLOR, size := FONT_SIZE) -> void:
	var f := Assets.font()
	ci.draw_string(f, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, SHADOW)
	ci.draw_string(f, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func label(text := "", size := FONT_SIZE, color := TEXT_COLOR) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Assets.font())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", SHADOW)
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l
