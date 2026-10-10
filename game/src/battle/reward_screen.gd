class_name RewardScreen
extends Control
## The battle reward screen of op 0x59 (0x44b5a8(gold, items, mode, levels)): BGM 9 (0x4745a7), the title
## "作战结束" (mode 0) / "全程作战结束" in 48-px (64 when the view has 15 or more rows) white letters at the top of the
## window, 10 ticks, then "酬金   %5u" (mode 0, colour 0x43) or "恭贺您实现统一大业" four title heights lower,
## 30 rounds or a click; mode 0 then lists the items (0x44b0a1): "战利品", and per item (20 ticks apart) a 240 × 48
## sand box (Mark 标志) with the 32 × 32 icon at +16, +8 and the name (consumables "%s×%d", count = level + 1) in
## dark blue (0xac) at column +10, y + 16; boxes 0x60 apart from the middle of the window (+0x60 with fewer than 3
## items); 20 ticks and 30 rounds. [G] Letter outline and the exact title rectangle are approximations.

const W := 640
const H := 480

var items: Array = []        # [text, pos, size, colour]
var pics: Array = []         # [texture, rect, src]


static func present(st: BattleStage, gold: int, ids: Array, mode: int, levels: Array) -> void:
	SoundMap.play_bgm_id(9)
	if Game.autoplay:
		return
	var s := RewardScreen.new()
	s.set_anchors_preset(Control.PRESET_FULL_RECT)
	s.mouse_filter = Control.MOUSE_FILTER_STOP
	st.ui.add_window(s)
	var rows := int(st.view.view_size().y) / 48
	var size := 0x40 if rows >= 15 else 0x30
	s._text("全程作战结束" if mode != 0 else "作战结束", size, size * 0.5, 0x12)
	await s._ticks(10)
	var line := "酬金   %5d" % gold if mode == 0 else "恭贺您实现统一大业"
	s._text(line, size, size * 0.5 + size * 4, 0x43 if mode == 0 else 0x12)
	await s._rounds(30)
	if mode == 0:
		var n := 0
		for v in ids:
			if int(v) < 0x200:
				n += 1
		if n != 0:
			s.items.clear()
			s.pics.clear()
			s._text("战利品", size, size * 0.5, 0x12)
			var bx := W / 2 - 120
			var by := H / 2 + (0x60 if n < 3 else 0)
			for k in ids.size():
				var iid := int(ids[k])
				if iid == 0xffff:
					continue
				await s._ticks(20)
				s._box(bx, by)
				var it := Game.item(iid & 0xff)
				s.pics.append([ItemText66.large_icon(iid & 0xff), Rect2(bx + 16, by + 8, 32, 32), Rect2()])
				var nm := str(it.get("name", ""))
				if Person.slot_of(it) == 3:
					nm = "%s×%d" % [nm, int(levels[k]) + 1]
				s.items.append([nm, Vector2(((bx >> 3) + 10) * 8, by + 16), 16, 0xac])
				s.queue_redraw()
				by += 0x60
			await s._ticks(20)
			await s._rounds(30)
	s.queue_free()


func _text(t: String, size: int, y: float, colour: int) -> void:
	var f := Assets.font()
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	items.append([t, Vector2((W - w) / 2, y), size, colour])
	queue_redraw()


func _box(x: int, y: int) -> void:
	var tile := Assets.tex("gfx/ui/mark/07.png")
	for i in 5:
		pics.append([tile, Rect2(x + 48 * i, y, 48, 48), Rect2(0, 0, 48, 48)])
	queue_redraw()


func _ticks(n: int) -> void:
	await get_tree().create_timer(n * 0.05).timeout


## 0x42c646(n): n rounds of 2 ticks, a click ends it.
func _rounds(n: int) -> void:
	var c := Game.clicks
	var t := 0.0
	while t < n * 0.1 and Game.clicks == c and not Game.skip_held() and is_inside_tree():
		await get_tree().process_frame
		t += get_process_delta_time()


func _draw() -> void:
	for p in pics:
		if p[0] == null:
			continue
		if (p[2] as Rect2).size == Vector2.ZERO:
			draw_texture_rect(p[0], p[1], false)
		else:
			draw_texture_rect_region(p[0], p[1], p[2])
	var f := Assets.font()
	for it in items:
		var size: int = it[2]
		var pos: Vector2 = it[1] + Vector2(0, f.get_ascent(size))
		if size > 16:
			draw_string_outline(f, pos, it[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, Color.BLACK)
		draw_string(f, pos, it[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, Text66.pal(it[3]))
