class_name DuelLayer
extends Control
## 单挑 (duel) screen, following docs/duel.md (object 0x4b3c80). A 624x384 box over the battle map:
## intro (op 0x68), fighters appear + speak (0x60), "胜 负" start (0x61), speech bubbles (0x63), single
## actions (0x64), scripted blows (0x65), specials (0x66), result (0x62, EXP), close (0x5f).
## Purely presentational and fully scripted: no HP bars, no randomness. 1 tick (T) = 50 ms.

const BOX := Vector2(8, 48)          # box origin on the 640x480 screen (centred like the map view)
const BOX_W := 624
const BOX_H := 384
const FY := 144                      # top of a 96 px fighter (box coordinates)
const HOME_X := [168, 360]
const PORTRAIT := [Vector2(16, 24), Vector2(526, 280)]
const NAME_POS := [Vector2(56, 112), Vector2(568, 256)]
const BUBBLE := [Vector2(120, 32), Vector2(184, 288)]
const TICK := 0.05

var stage: BattleStage
var active := false                  # 0x4495f8 result: both persons have a unit on the map
var pids := [-1, -1]
var backdrop_idx := 5
var prev_track := -1
var exp_award := 0
var mode := 0                        # 0 hidden, 1 intro frame, 2 fight backdrop
var fighters: Array = []             # DuelFighter ×2
var intro_names := [false, false]
var show_portrait := [false, false]
var banner := ""                     # "单挑" / "胜 负"
var bubbles := [[], []]              # lines shown per side
var _overlay: Control
var _bold: FontVariation
var _tile: Texture2D


class DuelFighter:
	extends Node2D
	var layer: DuelLayer
	var side := 0
	var entry := 0
	var x := 0
	var dir := 1                     # 1 right, 3 left
	var shown := false
	var sheet := "mov"
	var idx := 8
	var mirror := false
	var dx := 0                      # extra draw offset for this frame (e.g. "at O.x + p")
	var bright := 0                  # 0..15, RGB444 brighten (hit flash 12, glow 0..11, appear 15..0)
	var grey := false
	var ghosts: Array = []           # [[sheet, idx, mirror, x], …] afterimages drawn before the fighter
	var hidden_frame := false        # act 13 / dodge: not drawn
	var _tex := {}
	var _mat: ShaderMaterial
	static var _shader: Shader

	func _init() -> void:
		if _shader == null:
			_shader = Shader.new()
			_shader.code = """
shader_type canvas_item;
uniform float bright = 0.0;
uniform float grey = 0.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	c.rgb = min(c.rgb + vec3(bright), vec3(1.0));
	float v = (c.r + c.g + c.b) / 3.0;
	c.rgb = mix(c.rgb, vec3(v), grey);
	COLOR = c;
}
"""
		_mat = ShaderMaterial.new()
		_mat.shader = _shader
		material = _mat
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR if Assets.hd_active() else CanvasItem.TEXTURE_FILTER_NEAREST

	func setup(e: int) -> void:
		entry = e
		for s in ["mov", "atk", "spc"]:
			_tex[s] = Assets.tex("gfx/units/%s/%03d.png" % [s, e])

	## image in the fighter's own facing (directional frames are left-facing, mirrored when facing right)
	func img(s: String, i: int, directional := true) -> void:
		sheet = s
		idx = i
		mirror = directional and dir == 1
		dx = 0
		hidden_frame = false
		queue_redraw()

	func set_img(s: String, i: int, m: bool) -> void:
		sheet = s
		idx = i
		mirror = m
		dx = 0
		hidden_frame = false
		queue_redraw()

	func _draw_one(s: String, i: int, m: bool, px: int) -> void:
		var t: Texture2D = _tex.get(s)
		if t == null:
			return
		var fw := 64 if s == "atk" else 48
		var size := fw * 2
		var off := -16 if s == "atk" else 0
		var cx := clampi(px + off, 0, DuelLayer.BOX_W - size - 1)
		var pos := DuelLayer.BOX + Vector2(cx, DuelLayer.FY + off)
		var src := Rect2(0, i * fw, fw, fw)
		if m:
			draw_set_transform(pos + Vector2(size, 0), 0, Vector2(-2, 2))
		else:
			draw_set_transform(pos, 0, Vector2(2, 2))
		draw_texture_rect_region(t, Rect2(0, 0, fw, fw), src)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)

	func _draw() -> void:
		_mat.set_shader_parameter("bright", bright / 15.0)
		_mat.set_shader_parameter("grey", 1.0 if grey else 0.0)
		if not shown:
			return
		for g in ghosts:
			_draw_one(g[0], g[1], g[2], g[3])
		if not hidden_frame:
			_draw_one(sheet, idx, mirror, x + dx)


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_bold = FontVariation.new()
	_bold.base_font = Assets.font()
	_bold.variation_embolden = 0.9


# ------------------------------------------------------------------ timing helpers
func _t(n: int) -> void:
	if Game.autoplay or n <= 0:
		return
	await get_tree().create_timer(n * TICK).timeout


## A click or confirm press since Game.clicks was `n`.
func _clicked(n: int) -> bool:
	return Game.clicks != n


## 0x42c646: n × 100 ms, ended early by a click
func _skippable(n: int) -> void:
	if Game.autoplay:
		return
	var end := Time.get_ticks_msec() + int(n * 100 / maxf(Engine.time_scale, 0.01))
	var c := Game.clicks
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame
		if _clicked(c):
			break


func _se(n: int) -> void:
	if not Game.autoplay:
		Audio.se(n)


func _redraw() -> void:
	queue_redraw()
	_overlay.queue_redraw()
	for f in fighters:
		f.queue_redraw()


# ------------------------------------------------------------------ setup / open / close
## 0x44999f: the player-side fighter (party member, else a unit in slots 0..34) is always side 1.
func setup(a: int, b: int, backdrop: int) -> void:
	if Game.is_member(a):
		pids = [b, a]
	elif Game.is_member(b):
		pids = [a, b]
	else:
		var ua := stage.unit_by_pid(a)
		pids = [b, a] if ua != null and ua.slot < 35 else [a, b]
	backdrop_idx = backdrop if backdrop != 0xffff and backdrop < 64 else 5
	# 0x4495f8: both fighters need a unit on the map, else every duel op is skipped
	var u0 := stage.unit_by_pid(pids[0])
	var u1 := stage.unit_by_pid(pids[1])
	active = u0 != null and u1 != null and u0.state == BUnit.STATE_ON_MAP and u1.state == BUnit.STATE_ON_MAP
	if not active:
		return
	exp_award = 0
	for f in fighters:
		f.queue_free()
	fighters.clear()
	for side in 2:
		var u := stage.unit_by_pid(pids[side])
		var f := DuelFighter.new()
		f.layer = self
		f.side = side
		f.setup(Game.person(pids[side]).sprite_entry(mini(u.colour, 2)))
		f.x = HOME_X[side]
		f.dir = 1 if side == 0 else 3
		f.img("mov", 8)
		add_child(f)
		fighters.append(f)
	move_child(_overlay, -1)
	_tile = Assets.tex("gfx/effects/kao/1abc0_48x48.png")
	bubbles = [[], []]
	banner = ""
	intro_names = [false, false]
	show_portrait = [false, false]
	mode = 1
	visible = true
	_redraw()
	# intro (0x4486f4 + mod chain)
	prev_track = Audio.current_track
	if not Game.autoplay:
		Audio.play_bgm(10)
	await _t(10)
	show_portrait[0] = true
	intro_names[0] = true
	_redraw()
	await _t(20)
	banner = "单挑"
	_redraw()
	await _t(20)
	show_portrait[1] = true
	intro_names[1] = true
	_redraw()
	await _t(75)
	banner = ""
	intro_names = [false, false]
	mode = 2
	_redraw()


## 0x61 (0x448ff5): start of the fight — "胜 负" banner.
func open() -> void:
	if not active:
		return
	await _t(20)
	bubbles = [[], []]
	banner = "胜 负"
	_redraw()
	await _t(20)
	banner = ""
	_redraw()
	await _t(10)


## 0x5f (0x4498e0): close — 3 s skippable hold, map back, BGM restored, EXP to the side-1 player unit.
func close() -> void:
	if not active:
		return
	active = false
	await _skippable(30)
	visible = false
	mode = 0
	for f in fighters:
		f.queue_free()
	fighters.clear()
	if prev_track >= 0 and not Game.autoplay:
		Audio.play_bgm(prev_track)
	var u1 := stage.unit_by_pid(pids[1])
	if exp_award > 0 and u1 != null and u1.colour == 0:
		# 0x4498e0: SetExp gets the whole award (up to 200, 400 against the boss; 0x408950 levels up per 100);
		# only the original's EXP bar stops at 100
		await stage.actions.gain_exp(u1, exp_award)
	exp_award = 0


# ------------------------------------------------------------------ speech
## 0x60 (0x449480): the fighter fades in from a white silhouette, optional action, then speaks.
func appear_say(side: int, text: String, act: int) -> void:
	if not active:
		return
	var f: DuelFighter = fighters[_s(side)]
	f.shown = true
	f.img("mov", 8)
	for k in range(15, -1, -1):
		f.bright = k
		f.queue_redraw()
		await _t(1)
	await _t(5)
	if act != 0:
		await action(side, act)
	await say2(side, text, 1)


## 0x63 (0x4431af): speech bubble; typewriter 1 T/char, 3 lines per page, timed hold (no click wait).
func say2(side: int, text: String, mode_: int) -> void:
	if not active:
		return
	var s := _s(side)
	var cut := text.find("\n&")
	if cut >= 0:
		text = text.substr(0, cut)
	text = Game.substitute_names(text)
	if OS.get_environment("WG_TRACE_TEXT") != "":
		print("  [duel %s] %s" % [Game.person(pids[s]).name, text.replace("\n", " ")])
	if text.strip_edges() == "":
		bubbles[s] = []
		_overlay.queue_redraw()
		return
	var lines := text.split("\n")
	var page := 0
	while page * 3 < lines.size():
		var pl: Array = []
		for i in range(page * 3, mini(page * 3 + 3, lines.size())):
			pl.append(lines[i])
		bubbles[s] = []
		for i in pl.size():
			bubbles[s].append("")
		var skip := false
		var c := Game.clicks
		for li in pl.size():
			var line: String = pl[li]
			for ci in line.length():
				bubbles[s][li] = line.substr(0, ci + 1)
				_overlay.queue_redraw()
				if skip or Game.autoplay:
					continue
				var w := 1 + (1 if line[ci] == "、" else 0)
				var end := Time.get_ticks_msec() + int(w * TICK * 1000 / maxf(Engine.time_scale, 0.01))
				while Time.get_ticks_msec() < end:
					await get_tree().process_frame
					if _clicked(c):
						skip = true
						break
		_overlay.queue_redraw()
		if mode_ != 0:
			var spd := Mem.r8(Mem.GS + 0x10)
			if spd < 3:
				await _skippable([5, 12, 20][spd])
		page += 1


# ------------------------------------------------------------------ actions (op 0x64)
func _s(side: int) -> int:
	return 0 if side == 0 else 1


func _fwd(f: DuelFighter) -> int:
	return 1 if f.dir == 1 else -1


func _step_se(f: DuelFighter) -> void:
	var fam := Game.family_of(Game.person(pids[f.side]).cls)
	if fam in [0, 3, 7, 11, 12, 13, 15, 16, 17, 20, 24]:
		_se(24)
	elif fam in [21, 22, 23]:
		_se(25)
	else:
		_se(23)


func _front(f: DuelFighter) -> void:
	# the acting fighter is drawn last (on top)
	move_child(f, _overlay.get_index() - 1)


func action(side: int, act: int) -> void:
	if not active:
		return
	var a: DuelFighter = fighters[_s(side)]
	a.shown = true
	a.bright = 0
	a.ghosts.clear()
	_front(a)
	match act:
		0:
			a.img("mov", 8)
			_se(8)
		1:
			a.dir = 3 if a.dir == 1 else 1
			a.img("mov", 8)
			_se(6)
		2:
			for i in 4:
				a.x += 24 * _fwd(a)
				a.img("mov", 4 if i < 2 else 5)
				_step_se(a)
				await _t(1)
		3:
			_step_se(a)
			for i in 4:
				a.x += 8 * _fwd(a)
				a.img("mov", 4 if i < 2 else 5)
				await _t(1)
		4:
			_se(6)
			for i in 4:
				a.x -= 8 * _fwd(a)
				a.img("mov", 4 if i < 2 else 5)
				await _t(1)
		5:
			a.img("spc", 4, false)
			_se(8)
		6:
			a.img("spc", 2)
			_se(8)
		7:
			a.img("spc", 3, false)
			_se(8)
		8:
			a.img("atk", 8)
			_se(8)
		9:
			_se(7)
			for i in 4:
				a.img("atk", 8 + i)
				await _t(1)
		10:
			for r in 2:
				_se(7)
				for i in 4:
					a.img("atk", 8 + i)
					await _t(2)
		11:
			a.img("mov", 9, false)
			_se(8)
		12:
			_se(8)
			for i in 6:
				a.img("mov", 9 + i % 2, false)
				await _t(8)
		13:
			a.img("mov", 8)
			a.hidden_frame = true
			a.queue_redraw()
		14:
			await _war_dance(a)
		15:
			await _look_around(a)


## act 14 (unused by the scripts): spin / cheer / march showcase.
func _war_dance(a: DuelFighter) -> void:
	if not Game.autoplay:
		Audio.play_bgm(21)
	var spin := [["spc", 0, false], ["spc", 2, false], ["spc", 1, false], ["spc", 2, true]]
	for i in 17:
		a.set_img(spin[i % 4][0], spin[i % 4][1], spin[i % 4][2])
		await _t(4)
	await _t(4)
	a.set_img("spc", 4, false)
	await _t(40)
	for d in [-8, 8]:
		for i in 9:
			a.x += d
			a.set_img(spin[i % 4][0], spin[i % 4][1], spin[i % 4][2])
			await _t(4)
		await _t(4)
		a.set_img("spc", 4, false)
		await _t(40 if d > 0 else 20)
	for i in 8:
		a.x += 16
		a.set_img("mov", 4 + i % 2, false)
		await _t(2)
	a.set_img("mov", 9, false)
	await _t(40)
	for i in 4:
		a.x -= 8
		await _t(8)
	await _t(40)


## act 15 (unused): looks around.
func _look_around(a: DuelFighter) -> void:
	if not Game.autoplay:
		Audio.play_bgm(20)
	await _t(20)
	var delays := [4, 8, 8, 4, 4, 4]
	for r in 4:
		var base := 0 if r % 2 == 0 else 2
		for k in 6:
			a.set_img("mov", base + k % 2, false)
			await _t(delays[k])
		await _t(10)
	for m in [false, true]:
		for k in 6:
			a.set_img("mov", 4 + k % 2, m)
			await _t(delays[k])
		await _t(10)


# ------------------------------------------------------------------ attacks (ops 0x65 / 0x66)
func _archer(f: DuelFighter) -> bool:
	# 0x4400a2: table 0x4400df[family] == 0 (弓兵, 弓骑兵, 箭车)
	return Mem.r8(0x4400df + Game.family_of(Game.person(pids[f.side]).cls)) == 0


## 0x445e14: wind-up (charge glow when arg ≠ 0)
func _windup(a: DuelFighter, arg: int) -> void:
	if not _archer(a):
		if arg == 0:
			a.img("atk", 8)
			await _t(2)
		else:
			_se(33)
			a.img("atk", 8)
			for k in 12:
				a.bright = k
				a.queue_redraw()
				await _t(1)
			a.bright = 0
		a.img("atk", 9)
		await _t(1)
	else:
		a.img("atk", 8)
		_se(37)
		await _t(1)
		a.img("atk", 9)
		if arg == 0:
			await _t(8)
		else:
			_se(33)
			for k in 12:
				a.bright = k
				a.queue_redraw()
				await _t(1)
			a.bright = 0


## 0x65 (0x448394): one blow by `side` with a scripted outcome (kind 0 hit … 4 dodge).
func exchange(side: int, kind: int, arg: int) -> void:
	if not active:
		return
	var a: DuelFighter = fighters[_s(side)]
	var o: DuelFighter = fighters[1 - _s(side)]
	a.shown = true
	o.shown = true
	a.ghosts.clear()
	_front(a)
	await _windup(a, arg)
	var fwd := _fwd(a)
	var p := 32 * fwd
	var guard_m := a.dir == 3      # SPC2 of the defender is mirrored when A faces left
	for fr in 6:
		a.img("atk", 10 if fr == 0 else 11)
		match kind:
			0:
				o.set_img("spc", 3, false)
				o.bright = 12 if fr < 2 else 0
				o.dx = p if fr < 2 else 0
				if fr < 2: _se(36)
			1:
				o.set_img("spc", 2, guard_m)
				o.bright = 0
				o.dx = p if fr < 2 else 0
				if fr < 2: _se(31)
			2:
				o.set_img("spc", 2, guard_m)
				o.bright = 12 if fr < 2 else 0
				if fr in [1, 2]: o.x += p
				elif fr in [3, 4]: o.x += p / 2
				if fr < 2: _se(31)
			3:
				if fr < 2:
					o.x += 40 * fwd
					o.img("mov", 4)
					o.dx = 16 * fwd
					_se(7)
				elif fr == 2:
					o.x += 16 * fwd
					o.img("mov", 4)
				else:
					o.img("mov", 5)
			4:
				if fr < 2: _se(7)
				if fr < 5:
					o.hidden_frame = true
				else:
					o.x -= 192 * fwd
					o.dir = a.dir
					o.img("mov", 8)
					move_child(o, _overlay.get_index() - 1)
		o.queue_redraw()
		await _t(1)
	o.bright = 0
	o.dx = 0
	o.queue_redraw()


## 0x66 (0x44847b): special attacks — 0 lunge, 1 afterimage dash-through, 2 clash and cross.
func special(side: int, kind: int, arg: int) -> void:
	if not active:
		return
	var a: DuelFighter = fighters[_s(side)]
	var o: DuelFighter = fighters[1 - _s(side)]
	a.shown = true
	o.shown = true
	_front(a)
	var fwd := _fwd(a)
	var p := 32 * fwd
	var guard_m := a.dir == 3
	match kind:
		0:
			await _windup(a, 0)
			for fr in 6:
				if fr == 0:
					a.x += p
					o.x += p
				a.img("atk", 10 if fr == 0 else 11)
				if fr < 2:
					if arg == 0:
						o.set_img("spc", 3, false)
						_se(36)
					else:
						o.set_img("spc", 2, guard_m)
						_se(31)
					o.bright = 12
					o.dx = p
				else:
					o.bright = 0
					o.dx = 0
				o.queue_redraw()
				await _t(1)
		1:
			var m := a.dir == 1
			for fr in 8:
				a.ghosts.clear()
				match fr:
					0:
						a.ghosts = [["atk", 8, m, a.x], ["atk", 8, m, a.x + p]]
						a.x += 2 * p
						a.set_img("atk", 8, m)
					1:
						a.ghosts = [["atk", 8, m, a.x - 2 * p], ["atk", 8, m, a.x - p], ["atk", 9, m, a.x], ["atk", 9, m, a.x + p]]
						a.x += 2 * p
						a.set_img("atk", 9, m)
					2:
						a.ghosts = [["atk", 8, m, a.x - 4 * p], ["atk", 8, m, a.x - 3 * p], ["atk", 9, m, a.x - 2 * p],
								["atk", 9, m, a.x - p], ["atk", 10, m, a.x], ["atk", 10, m, a.x + p]]
						a.x += 2 * p
						a.set_img("atk", 10, m)
						if arg == 0:
							o.set_img("spc", 3, false)
							o.bright = 12
							_se(36)
						else:
							o.set_img("spc", 2, guard_m)
							_se(31)
						o.dx = p
					3:
						a.ghosts = [["atk", 10, m, a.x - 2 * p], ["atk", 10, m, a.x - p]]
						a.set_img("atk", 11, m)
						o.dx = p
					_:
						a.set_img("atk", 11, m)
						o.bright = 0
						o.dx = 0
				o.queue_redraw()
				a.queue_redraw()
				await _t(1)
			a.ghosts.clear()
			a.queue_redraw()
		2:
			var od := _fwd(o)
			for i in 8:
				var step := 24 if i < 4 else 48
				a.x += step * fwd
				o.x -= step * fwd
				var cross := a.x == o.x
				a.img("mov", 5 if cross else 4 + i % 2)
				o.img("mov", 5 if cross else 4 + i % 2)
				a.bright = 12 if cross else 0
				o.bright = 12 if cross else 0
				if cross:
					_se(31)
				a.queue_redraw()
				o.queue_redraw()
				await _t(1)
			a.bright = 0
			o.bright = 0
			_redraw()
			await _t(20)


# ------------------------------------------------------------------ result (op 0x62)
## 0x4490da(winner): loser greyed; EXP when side 1 (player army) wins.
func result(winner: int) -> void:
	if not active:
		return
	var w := _s(winner)
	await _t(20)
	bubbles = [[], []]
	var loser: DuelFighter = fighters[1 - w]
	loser.grey = true
	_redraw()
	var u1 := stage.unit_by_pid(pids[1])
	if w == 1 and u1 != null and u1.colour == 0:
		var lw := Game.person(pids[1]).level
		var ll := Game.person(pids[0]).level
		var e := mini(32 + 8 * (ll - lw), 200) if lw < ll else maxi(Rules.sat_sub(32, 4 * (lw - ll)), 10)
		if pids[0] == stage.boss_pid:
			e *= 2
		exp_award = e
	await _t(20)


# ------------------------------------------------------------------ drawing
static func _grey(idx: int) -> Color:
	# shared palette range 0x12..0x1f: #fff #eee #ddd … #444 #222 #000
	var v := 0.0
	if idx <= 0x1d:
		v = (15 - (idx - 0x12)) / 15.0
	elif idx == 0x1e:
		v = 2 / 15.0
	return Color(v, v, v)


func _hline(y: float, x0: float, x1: float, c: Color) -> void:
	draw_rect(Rect2(BOX + Vector2(x0, y), Vector2(x1 - x0 + 1, 1)), c)


func _vline(x: float, y0: float, y1: float, c: Color) -> void:
	draw_rect(Rect2(BOX + Vector2(x, y0), Vector2(1, y1 - y0 + 1)), c)


func _bevel(fight: bool) -> void:
	var R := BOX_W
	var B := BOX_H
	for i in 12:
		var c := _grey(0x1f - i) if fight else _grey(0x19 - (i >> 1))
		_hline(B - 12 + i, 0, R - 1, c)
		_vline(R - 12 + i, 0, B - 1, c)
	for i in 8:
		var ci: int
		if i < 3:
			ci = 0x13
		elif fight:
			ci = 0x14 if i == 3 else (0x15 if i == 4 else 0x16 + 3 * (i - 5))
		else:
			ci = i + 0x11
		var cut := 3 * (i - 4) if i >= 5 else 0
		_hline(i, i, R - 1 - cut, _grey(ci))
		_vline(i, i, B - 1 - cut, _grey(ci))


func _draw() -> void:
	if mode == 0:
		return
	var R := BOX_W
	var B := BOX_H
	# drop shadow outside the box + 1 px light edge
	for i in 3:
		var c := _grey([0x18, 0x1a, 0x1c][i])
		_hline(B + i, i, R, c)
		_vline(R + i, i, B + 2, c)
	_hline(-1, -1, R, _grey(0x13))
	_vline(-1, -1, B, _grey(0x13))
	if mode == 1:
		if _tile:
			for ty in 8:
				for tx in 13:
					draw_texture(_tile, BOX + Vector2(tx * 48, ty * 48))
		_bevel(false)
	else:
		var bd := Assets.tex("gfx/screens/%02d.png" % backdrop_idx)
		if bd:
			draw_texture(bd, BOX)
		else:
			draw_rect(Rect2(BOX, Vector2(R, B)), Color(0.3, 0.3, 0.3))
		_bevel(true)
	for s in 2:
		if not show_portrait[s]:
			continue
		var face := Game.person_face(pids[s], true)
		if face:
			draw_texture_rect(face, Rect2(BOX + PORTRAIT[s], Vector2(80, 80)), false)
		if mode == 2:
			_small_name(s)


func _army_colour(s: int) -> Color:
	var u := stage.unit_by_pid(pids[s]) if stage else null
	var k := u.colour if u else 2
	return Color("#c30000") if k == 0 else (Color("#c25502") if k == 1 else Color("#001f7b"))


func _plain_name(s: int) -> String:
	var p := Game.person(pids[s])
	var n := p.name if p else ""
	var out := ""
	for ch in n:
		if not (ch >= "0" and ch <= "9"):
			out += ch
	return out


func _small_name(s: int) -> void:
	var f := Assets.font()
	var n := _plain_name(s)
	var w := f.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var pos: Vector2 = BOX + NAME_POS[s] + Vector2(-w / 2, 14)
	draw_string_outline(f, pos, n, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, _army_colour(s))
	draw_string(f, pos, n, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)


func _layered(ci: CanvasItem, pos: Vector2, text: String, size: int, layers: Array) -> void:
	# layers: [[offset, colour], …] drawn back to front
	for l in layers:
		ci.draw_string(_bold, pos + Vector2(l[0], l[0]), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, l[1])


func _draw_overlay() -> void:
	if mode == 0:
		return
	var c := _overlay
	# big intro names (宋体 bold, 32-px half-width cells)
	for s in 2:
		if not intro_names[s]:
			continue
		var n := _plain_name(s)
		var w := _bold.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1, 64).x
		var pos: Vector2 = BOX + (Vector2(120, 32) if s == 0 else Vector2(504 - w, 288)) + Vector2(0, 56)
		if s == 0:
			_layered(c, pos, n, 64, [[7, _grey(0x18)], [6, _grey(0x18)], [2, Color("#001f7b")], [1, Color("#0000c3")], [0, Color("#0000ff")]])
		else:
			_layered(c, pos, n, 64, [[7, _grey(0x18)], [6, _grey(0x18)], [2, Color("#c30000")], [1, Color("#c30000")], [0, Color("#ff0000")]])
	# banners
	if banner != "":
		var size := 64 if banner == "单挑" else 96
		var w := _bold.get_string_size(banner, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var top := 160.0 if banner == "单挑" else 144.0
		var pos := BOX + Vector2(312 - w / 2, top + size * 0.86)
		_layered(c, pos, banner, size, [[3, _grey(0x1f)], [2, _grey(0x18)], [1, _grey(0x15)], [0, Color.WHITE]])
	# speech bubbles
	var lcap := Assets.tex("gfx/effects/kao/19ac0_16x64.png")
	var rcap := Assets.tex("gfx/effects/kao/19ec0_16x64.png")
	for s in 2:
		var lines: Array = bubbles[s]
		if lines.is_empty():
			continue
		var b: Vector2 = BOX + BUBBLE[s]
		if lcap: c.draw_texture(lcap, b)
		if rcap: c.draw_texture(rcap, b + Vector2(304, 0))
		c.draw_rect(Rect2(b + Vector2(16, 0), Vector2(288, 64)), Color.WHITE)
		var tail := Assets.tex("gfx/effects/kao/%s_16x16.png" % ("198c0" if s == 0 else "199c0"))
		if tail:
			c.draw_texture(tail, b + (Vector2(-16, 24) if s == 0 else Vector2(320, 24)))
		for i in lines.size():
			c.draw_string(Assets.font(), b + Vector2(16, 5 + 20 * i + 15), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
