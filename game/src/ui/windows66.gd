class_name Windows66
extends RefCounted
## The script windows of the 6.6 engine (Ekd5.exe), built with Win66. GameUI calls these; positions, sizes, colours,
## lines per page and timing are the original's (addresses on each function). Screen = 640×480.

const W := 640
const H := 480
const FACE := Vector2(120, 120)
const BOX := Vector2(344, 84)          # U_select 9 / 10 parchment box (0x158 × 0x54)


## The stage's position of a speaker: Game.main.stage.talk_anchor(pid) → null or a Dictionary.
static func anchor(pid: int) -> Variant:
	var st: Variant = Game.main.stage if Game.main else null
	if st != null and is_instance_valid(st) and st.has_method("talk_anchor"):
		return st.talk_anchor(pid)
	return null


static func in_battle() -> bool:
	var st: Variant = Game.main.stage if Game.main else null
	return st != null and is_instance_valid(st) and st.has_method("in_battle") and st.in_battle()


static func face(pid: int) -> Texture2D:
	return Game.person_face(pid)


## Pages of `n` lines (a trailing "\n" does not open an empty page; 0x42d784 loops while text remains).
static func pages(text: String, n: int) -> Array:
	var ls := Text66.lines(text)
	if ls.size() > 0 and ls[ls.size() - 1] == "":
		ls.resize(ls.size() - 1)
	var out := []
	var i := 0
	while i < ls.size():
		out.append(ls.slice(i, i + n))
		i += n
	return out


static func _open(ui: GameUI) -> Win66:
	var w := Win66.new()
	ui.add_window(w)
	return w


## Show `pages` of text lines at column x `tx`, first line y `ty`, line pitch `pitch`, colour `colour`; one page at
## a time with the typewriter and the page wait (0x42d784..0x42d8a1).
static func _run_pages(win: Win66, pg: Array, tx: float, ty: float, pitch: float, colour: int) -> void:
	var st := {"c": colour, "open": false}
	var typing := Text66.speed() != 0
	for p in pg:
		win.clear_texts()
		st["c"] = colour                     # 0x40ed15 at every page; the markup's saved flag stays as it was
		var y := ty
		for line in p:
			win.text_line(tx, y, line, st)
			y += pitch
		await win.type_page(typing)
		await win.page_wait()


# ------------------------------------------------------------------ 0x42d5b0 talk window
## Story talk window 0x42d5b0(text, pid, flags). pid 0..0x3ff: portrait 120×120 at x 8 (left) or 0x200 (right) by
## the side flag 0x48e864, which toggles whenever the speaker record differs from the last one (0x4b1b24; a box
## without portrait counts as "no record") and is forced to left for pid 0; y = 0x30 when the speaker's actor is
## lower than (H − 40) / 2 on screen, else 0x138 (no actor: 0x138). The parchment box (U_select 9 when the portrait
## is left, 10 when right) is beside it at y + 24 with the name (blue 0x3a) at column 0x13 (0x17 on the right side)
## and y + 29, and three text lines (black) at y + 48 + 20·i. A speech mark (Mark 气泡) is drawn by the actor's head.
## Without a portrait: the 336×144 sand window centred at ((W/2) − 160, ((H − 90) / 2) − 16), four dark-blue lines
## at x + 24, y + 16 + 32·i.
static func talk(ui: GameUI, pid: int, text: String, flags: int) -> void:
	var has_p := pid >= 0 and pid < 0x400
	var a: Variant = anchor(pid) if has_p else null
	if in_battle() and (has_p or (a is Dictionary and bool(a.get("battle", false)))):
		await talk_battle(ui, pid, text, a)
		return
	var rec := pid if has_p else -1
	if rec != ui.talk_last:
		ui.talk_last = rec
		ui.talk_side = 1 if ui.talk_side == 0 else 0
	if pid == 0:
		ui.talk_side = 1
	Text66.trace(Text66.display_name(pid) if has_p else "", text)
	if Game.autoplay:
		return
	var win := _open(ui)
	if not has_p:
		var x := W / 2 - 0xa0
		var y := (H - 0x5a) / 2 - 0x10
		win.frame_window(Rect2(x, y, 0x150, 0x90), false)
		var tx := float(((x + 0x18) >> 3) * 8)
		await _run_pages(win, pages(text, 4), tx, y + 0x10, 0x20, Text66.C_PLAIN)
		win.queue_free()
		return
	var px := 8 if ui.talk_side != 0 else 0x200
	var ax := 0.0
	var ay := 0.0
	var dir := -1
	if a is Dictionary:
		ax = float(a.get("x", 0))
		ay = float(a["top"]) if a.has("top") else float(a.get("y", 0)) - 64.0
		dir = int(a.get("dir", -1))
	var y := 0x30 if ay > (H - 0x28) >> 1 else 0x138
	# speech mark 0x42d53a: facing 0/1 → right of the head (frame 0), 2/3 → left (frame 1)
	if dir >= 0 and dir < 4:
		var right := dir < 2
		win.pic(Assets.tex("gfx/ui/mark/09.png"), Vector2(ax + (40 if right else -16), ay - 16),
				Rect2(0, 0 if right else 24, 24, 24))
	_portrait_box(win, pid, px, y, ui.talk_side, true)
	var tx := 0x13 * 8.0 if ui.talk_side != 0 else 0x17 * 8.0
	await _run_pages(win, pages(text, 3), tx, y + 0x30, 0x14, Text66.C_TEXT)
	win.queue_free()


## 0x42d3f5: portrait at (px, y), the parchment box beside it at y + 24, the name in it.
static func _portrait_box(win: Win66, pid: int, px: float, y: float, side: int, story: bool, name_x := -1.0,
		name_y := -1.0) -> void:
	win.pic(face(pid), Vector2(px, y), Rect2(Vector2.ZERO, FACE))
	var left := (px == 8) if story else side != 0
	var bx := px + 0x78 if left else px - 0x158
	win.pic(Assets.tex("gfx/ui/u_select/09.png" if side != 0 else "gfx/ui/u_select/10.png"), Vector2(bx, y + 0x18))
	if name_x < 0:
		name_x = (0x13 if side != 0 else 0x17) * 8.0
		name_y = y + 0x1d
	win.label(name_x, name_y, Text66.display_name(pid), Text66.C_NAME)


## Battle talk window 0x42cd05 (from 0x42d5b0 in a battle for a person, or 0x45965d): placed by the speaker's
## unit cell (0x42ceee), side flag 0x48e860 / last speaker 0x4b1b20 (its own pair), portrait at winx + 0x160 (flag 0)
## or winx − 0x28, box beside it, name at column (winx + 0x18 or + 0x68) / 8 and winy − 2, three lines from
## winy + 17. `a` = talk_anchor: {"battle": true, "cell": Vector2i on-screen cell (or absent), "view": Rect2 of the
## map view on screen}.
static func talk_battle(ui: GameUI, pid: int, text: String, a: Variant) -> void:
	var rec := pid if pid >= 0 and pid < 0x400 else -1
	if a is Dictionary and a.has("pid"):
		rec = int(a["pid"])
	if rec != ui.btalk_last:
		ui.btalk_last = rec
		ui.btalk_side = 1 if ui.btalk_side == 0 else 0
	if pid == 0:
		ui.btalk_side = 1
	Text66.trace(Text66.display_name(rec), text)
	if Game.autoplay:
		return
	var view := Rect2(0, 0, W, H)
	var cell := Vector2i(-1, -1)
	if a is Dictionary:
		view = a.get("view", view)
		cell = a.get("cell", cell)
	var pos := battle_anchor(cell, view)
	var win := _open(ui)
	var mark: Vector2 = pos["mark"]
	if cell.x >= 0:
		win.pic(Assets.tex("gfx/ui/mark/09.png"), mark + Vector2(5, -2), Rect2(0, 0, 24, 24))   # [G] frame 0
	var wx: float = pos["win"].x
	var wy: float = pos["win"].y
	var side := ui.btalk_side
	var px := wx + 0x160 if side == 0 else wx - 0x28
	var top := wy - 0x1f
	var col := float(((int(wx) + (0x68 if side != 0 else 0x18)) >> 3) * 8)
	_portrait_box(win, rec, px, top, side, false, col, wy - 2)
	await _run_pages(win, pages(text, 3), col, wy - 2 + 0x13, 0x14, Text66.C_TEXT)
	win.queue_free()


## 0x42ceee: speech-mark and window anchors for a unit at on-screen cell (cx, cy) of a view of cols × rows cells.
static func battle_anchor(cell: Vector2i, view: Rect2) -> Dictionary:
	var cols := int(view.size.x) / 48
	var rows := int(view.size.y) / 48
	var hc := rows / 2
	var mark := Vector2.ZERO
	var win := Vector2.ZERO
	if cell.x < 0:
		win = Vector2((cols / 2) * 48 - 0xd8, hc * 48 - 0x30)
	else:
		var cx := cell.x
		var cy := cell.y
		var lower := false
		if cx < 2:
			mark.x = (cx + 1) * 48 - 0x14
			win.x = (cx + 1) * 48 + 0x10
			lower = true
		elif cx < cols - 2:
			if cx * 48 < 200:
				win.x = cx * 48 - 0x28
			elif (cx + 1) * 48 + 200 < int(view.size.x):
				win.x = cx * 48 - 0xb8
			else:
				win.x = (cols - 1) * 48 - 0x1b8
			mark.x = cx * 48 + 0x10
			if cy < hc:
				mark.y = (cy + 1) * 48 - 0x40
				win.y = (cy + 1) * 48 + 0x10
			else:
				win.y = cy * 48 - 0x70
				mark.y = cy * 48 - 0x10
		else:
			win.x = cx * 48 - 0x1d8
			mark.x = cx * 48 + 0x10
			lower = true
		if lower:
			win.y = cy * 48 + 0x40 if cy < hc else (cy + 1) * 48 - 0xa0
			mark.y = cy * 48 - 0x12
	return {"mark": mark + view.position, "win": win + view.position}


# ------------------------------------------------------------------ 0x42f699 message boxes
## Style 2 (0x42f448): one line in a sand window of n 48-px tiles (3 full-width characters per tile, at least 2,
## 0x42f542), centred on x 320 at y 160 (battle: the view centre, y = H/2 − 48), dark-blue text centred by the
## padding of 0x42f542, shown for (speed + 1) · 10 rounds of 2 ticks or until a click.
static func message2(ui: GameUI, text: String) -> void:
	Text66.trace("popup", text)
	if Game.autoplay:
		return
	var len := Text66.gbk_len(text.split("\n")[0])
	var c := (len >> 1) + (len & 1)
	var q := c / 3
	var r := c % 3
	var pad := 0x18
	var tiles := q
	match r:
		0:
			tiles += 1
			pad = 0x18
		1:
			tiles += 1
			pad = 0x10
		2:
			tiles += 2
			pad = 0x20
	tiles = maxi(tiles, 2)
	var cx := 0x140
	var y := 0xa0
	if in_battle():
		cx = W / 2
		y = H / 2 - 0x30
	var x := cx - (tiles * 0x30 >> 1)
	var win := _open(ui)
	win.frame_window(Rect2(x, y, tiles * 0x30, 0x30), false)
	var st := {"c": Text66.C_PLAIN, "open": false}
	for line in [text.split("\n")[0]]:
		win.text_line(float(((x + pad) >> 3) * 8), y + 0x10, line, st)
	await win.type_page(false)
	if Game.demo:
		await win.get_tree().create_timer(1.2).timeout
	else:
		await win.rounds_or_click((Text66.speed() + 1) * 10)
	win.queue_free()


## Styles 0 / 1: the Win32 dialogs 339 (确认, OK) and 340 (是 / 否, caption 三国志曹操传 0x48c8d8), modal.
## Returns true for OK / 是.
static func dialog(ui: GameUI, text: String, yes_no: bool) -> bool:
	Text66.trace("yes/no" if yes_no else "ok", text)
	if Game.autoplay:
		return true
	if Game.demo:
		await ui.get_tree().create_timer(1.0).timeout
		return true
	var d := SysDialog66.new()
	ui.add_window(d)
	var r: bool = await d.run("三国志曹操传" if yes_no else "确认", text, ["是", "否"] if yes_no else ["OK"])
	d.queue_free()
	return r


# ------------------------------------------------------------------ 0x42de7d choice window
const CHOICE_ROWS := {3: [0x1a, 0x40], 4: [0x14, 0x50], 5: [0x0a, 0x63], 6: [0x00, 0x78]}   # table 0x42de75


## Op 0x12 window 0x42de7d: portrait of pid at ((W − 0x1d0)/2, (H − 0x50)/2), the ◀ of Mark 单挑框 at +(120, 60),
## a white list box (288 wide) at +(0x98, off) whose height and offset depend on the row count (≥ 3), rows
## "N.text" (numbered by 0x42c9fc) appearing one by one 3 ticks apart at 19-px pitch; the row under the mouse is
## drawn white on blue (0x42e195), a left click picks it. Returns the 0-based index.
static func choose(ui: GameUI, options: Array, pid: int) -> int:
	var opts: Array = options.slice(0, 6)
	var labels := []
	for k in opts.size():
		labels.append("%d.%s" % [k + 1, str(opts[k])])
	if Game.autoplay or Game.demo:
		if Game.demo:
			await ui.get_tree().create_timer(1.0).timeout
		var pick := 0
		if OS.get_environment("WG_RANDOM") != "" and not labels.is_empty():
			pick = Rules.rand(labels.size())
		Text66.trace("menu", "%s -> %s" % [labels, labels[pick] if pick < labels.size() else "?"])
		return pick
	var c := ChoiceWin66.new()
	ui.add_window(c)
	var r: int = await c.run(labels, pid if pid >= 0 and pid < 0x400 else 0)
	c.queue_free()
	return r


# ------------------------------------------------------------------ 0x72 sub 34 (dialog 342)
static func choice_modal(ui: GameUI, options: Array, checkboxes: bool, max_checked: int) -> Array:
	var labels := []
	for k in mini(options.size(), 9):
		labels.append("%d.%s" % [k + 1, str(options[k])])
	if Game.autoplay or Game.demo:
		if Game.demo:
			await ui.get_tree().create_timer(1.0).timeout
		Text66.trace("menu", "%s -> %s" % [labels, labels[0] if not labels.is_empty() else "?"])
		return [0] if not labels.is_empty() else []
	var d := SysDialog66.new()
	ui.add_window(d)
	var r: Array = await d.run_options(labels, checkboxes, max_checked)
	d.queue_free()
	return r


# ------------------------------------------------------------------ 0x42d8bf three-portrait window
## 0x42d8bf / 0x42d0a9: window 600 × 356 at (20, 84) (battle ((W − 600)/2, H − 300)); three 192×272 Fb portraits at
## x + 198·i + 6 (spacing 72 when only left and middle are used); a slot whose mask bit (4 left, 2 middle, 1 right)
## is clear is darkened 40 % (0x40690c) and its name is not written; the 600×84 white box (U_select 22) below at
## y + 272 holds the lit names ("%s " each, blue) at (x + 20, y + 277) and three black lines from y + 296.
static func dialog3(ui: GameUI, persons: Array, mask: int, text: String) -> void:
	var names := ""
	for i in 3:
		var p := int(persons[i]) if i < persons.size() else -1
		if p >= 0 and p < 0x400 and (mask >> (2 - i)) & 1 != 0:
			names += Text66.display_name(p) + " "
	Text66.trace(names.strip_edges(), text)
	if Game.autoplay:
		return
	var x := 0x14
	var y := 0x54
	if in_battle():
		x = (W - 600) >> 1
		y = H - 300
	var win := _open(ui)
	var cnt := 0
	for i in 3:
		var p := int(persons[i]) if i < persons.size() else -1
		if p != -1:
			cnt += -1 if i == 2 else 1
	var sp := 0x48 if cnt == 2 else 6
	for i in 3:
		var p := int(persons[i]) if i < persons.size() else -1
		if p < 0 or p >= 0x400:
			continue
		var lit := (mask >> (2 - i)) & 1 != 0
		var t := Game.person_face(p, true)
		var slot := Vector2(x + (0xc0 + sp) * i + sp, y)
		if t != null:
			var sz := t.get_size()
			var mod := Color(1, 1, 1) if lit else Color(0.6, 0.6, 0.6)
			if sz.x >= 0xc0:
				win.pic(t, slot, Rect2(0, 0, 0xc0, minf(sz.y, 0x110)), mod)
			else:
				# [G] a 120×120 Face.e5 picture (no Fb entry): the engine blits 192×272 from it (garbage); placed
				# at the bottom centre of the slot instead
				win.pic(t, slot + Vector2((0xc0 - sz.x) / 2, 0x110 - minf(sz.y, 0x110)), Rect2(0, 0, sz.x, minf(sz.y, 0x110)), mod)
	win.pic(Assets.tex("gfx/ui/u_select/22.png"), Vector2(x, y + 0x110))
	var tx := float(((x + 0x14) >> 3) * 8)
	win.label(tx, y + 0x115, names, Text66.C_NAME)
	await _run_pages(win, pages(text, 3), tx, y + 0x115 + 0x13, 0x14, Text66.C_TEXT)
	win.queue_free()
