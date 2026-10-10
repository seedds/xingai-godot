class_name DuelLayer
extends Control
## 单挑 (scripted duel, "system A" of docs/duel.md §1): the duel object 0x4b3c80 (DUEL) and its 624x384 box.
## intro (op 0x68 → 0x4499a3 / 0x4495f4 / 0x4486f4), fighters appear + speak (0x60 → 0x448bae), "胜 负" start
## (0x61 → 0x448cb3), speech bubbles (0x63 → 0x4431af), single actions (0x64 → 0x448497, table 0x4484e7),
## scripted blows (0x65 → 0x448389), specials (0x66 → 0x44867a), result + EXP (0x62 → 0x448e55), close
## (0x5f → 0x4498e5). Purely presentational and fully scripted: no HP, no randomness. 1 tick (T) = 50 ms.
##
## Hosted by a BattleStage or (6.6: duels also run outside a battle) a StoryStage: `stage` is any ScriptHost.
## Units are read straight from the emulated memory (0x4a7b20 + 0x30·slot) so nothing BattleStage-specific
## is needed. Texts arrive already expanded (0x417df6) from the host.
##
## Box geometry (0x4495f4): L = viewW/2 − 312, T = viewH/2 − 0x88 in a battle and viewH/2 − 0xac outside; the
## view object 0x4b4250 is 640x440 (+0x20/+0x22 set at 0x47b56c). [G] The view's surface origin is taken to
## be the screen origin, which gives L = 8 and T = 84 (battle) / 48 (story; the box is then exactly 8 px inside
## the 640x400 scene picture at y = 40).

const BOX_W := 624
const BOX_H := 384
const FY := 144                      # top of a 96 px fighter: DUEL+0x80 = T + 384/2 − 0x30
const HOME_X := [168, 360]           # DUEL+0x24 / +0x50 (S-form 72 / 456 when EV 4083 ≠ 0)
## Portraits: Face.e5 120x120 (0x443a0d → 0x404bcd) at rec+0x10/+0x14 − (16,16) for side 0, − (44,28) side 1.
const PORTRAIT := [Vector2(8, 8), Vector2(492, 252)]
const FACE := 120
## Big intro names (0x443773 mode 0, 64 px bold, drawn from the rect's top-left): side 0 starts at x 136,
## side 1 ends at x 482 (x = 482 − 32·GBK bytes).
const BIG_NAME_Y := [32, 288]
## Small names (0x443773 mode 1 → 0x4403aa): 8-px text columns; side 0 at (144, 14), side 1 at
## (456 − 8·(bytes/2), 286).
const SMALL_NAME_Y := [14, 286]
## Speech bubbles (0x4431af): tail 16x16 (Mark 0x51120 ◀ / 0x51420 ▶), caps 16x64 (0x51720 / 0x52320), white
## fill between the caps, 3 lines at y + 5 + 20·i from the fill's left edge.
const BUBBLE_Y := [32, 304]
const BUBBLE_TAIL := [Vector2(128, 56), Vector2(476, 328)]
const BUBBLE_LCAP_X := [144, 184]
const BUBBLE_RCAP_X := [420, 460]
const TICK := 0.05
## Families whose wind-up is the archer one (0x43fff4: table 0x4d2160[family] ≠ 0): 弓兵, 弓骑兵, 女弓兵, 井栏.
const ARCHER_TABLE := 0x4d2160
const MOVE_KIND_TABLE := 0x4d20c0    # family attribute row 0; 3 = flying (no step sound, 0x43f371)

var stage: ScriptHost
var active := false                  # DUEL+0 (0x4495f4 result)
var pids := [-1, -1]                 # DUEL+0xc / +0x38: side 0 / side 1 person
var slots := [-1, -1]                # DUEL+0x11 / +0x3d: their units
var box := Vector2(8, 84)
var backdrop_idx := 5
var prev_track := 0xff               # DUEL+0x64: GS+4 (current BGM byte) at setup
var exp_award := 0                   # DUEL+0x84
var mode := 0                        # 0 hidden, 1 intro frame, 2 fight backdrop
var fighters: Array = []             # DuelFighter ×2
var intro_names := [false, false]
var show_portrait := [false, false]
var grey_portrait := [false, false]
var banner := ""                     # "单挑" / "胜 负"
var bubbles := [[], []]              # lines shown per side
var bubble_page := [0, 0]            # pages after the first fill 4 px wider (0x4431af quirk)
var _overlay: Control
var _bold: FontVariation
var _tile: Texture2D


class DuelFighter:
	extends Node2D
	var layer: DuelLayer
	var side := 0
	var entry := 0
	var x := 0
	var dir := 1                     # 1 right, 3 left (DUEL rec +0xe)
	var shown := false
	var sheet := "mov"
	var idx := 8
	var mirror := false
	var dx := 0                      # extra draw offset for this frame (e.g. "at O.x + p")
	var blend := 0.0                 # 0x40690c: blend toward blend_colour by this fraction
	var blend_colour := Color.WHITE
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
uniform float blend = 0.0;
uniform vec4 blend_colour : source_color = vec4(1.0);
uniform float grey = 0.0;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	c.rgb = mix(c.rgb, blend_colour.rgb, blend);
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

	func flash(f: float, c := Color.WHITE) -> void:
		blend = f
		blend_colour = c
		queue_redraw()

	func _draw_one(s: String, i: int, m: bool, px: int) -> void:
		var t: Texture2D = _tex.get(s)
		if t == null:
			return
		var fw := 64 if s == "atk" else 48
		var size := fw * 2
		var off := -16 if s == "atk" else 0
		# 0x443c1d: x clamped into the box (DUEL+0x78 .. +0x7c)
		var cx := clampi(px + off, 0, DuelLayer.BOX_W - size - 1)
		var pos := layer.box + Vector2(cx, DuelLayer.FY + off)
		var src := Rect2(0, i * fw, fw, fw)
		if m:
			draw_set_transform(pos + Vector2(size, 0), 0, Vector2(-2, 2))
		else:
			draw_set_transform(pos, 0, Vector2(2, 2))
		draw_texture_rect_region(t, Rect2(0, 0, fw, fw), src)
		draw_set_transform(Vector2.ZERO, 0, Vector2.ONE)

	func _draw() -> void:
		_mat.set_shader_parameter("blend", blend)
		_mat.set_shader_parameter("blend_colour", blend_colour)
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


## Create the layer on the host's GameUI, under the dialog box and menus (as BattleStage._duel() does).
static func attach(host: ScriptHost) -> DuelLayer:
	var d := DuelLayer.new()
	d.stage = host
	host.ui.add_child(d)
	if host.ui.dialog:
		host.ui.move_child(d, host.ui.dialog.get_index())
	return d


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


## 0x4745a7(n): BGM byte GS+4 = n (0x418c99) and play track n; n ≥ 0xff does nothing.
func _bgm(n: int) -> void:
	if n >= 0xff:
		return
	Mem.w8(Mem.GS + 4, n)
	if not Game.autoplay:
		Audio.play_bgm(n)


func _redraw() -> void:
	queue_redraw()
	_overlay.queue_redraw()
	for f in fighters:
		f.queue_redraw()


func _in_battle() -> bool:
	return stage != null and stage.in_battle()


# ------------------------------------------------------------------ units (straight from memory)
static func _uaddr(slot: int) -> int:
	return Mem.UNITS + slot * Mem.UNIT_SIZE


## 0x477adc: in a battle, the first unit slot whose state (+0xc) ≠ 0 holds the person (+0 & 0xfff); in training
## (EV 4087 ≠ 0) slots 1..59 are skipped. Outside a battle −1.
func unit_of(pid: int) -> int:
	if not _in_battle():
		return -1
	var training := Mem.ev(4087) != 0
	var s := 0
	while s < 250:
		var a := _uaddr(s)
		if Mem.r8(a + 0xc) != 0 and (Mem.r16(a) & 0xfff) == pid:
			return s
		s += 1
		if training and s < 60:
			s = 60
	return -1


## Hostility class 0x406710 of a unit: table 0x40672d[side code +5] (side 3 → entry 4 when byte EV 4053 ≠ 0).
static func hostility(slot: int) -> int:
	if slot < 0:
		return 0
	var c := Mem.r8(_uaddr(slot) + 5)
	if c == 3 and Mem.r8(Mem.EV + 4 * 4053) != 0:
		c += 1
	return Mem.r8(0x40672d + c)


## 0x42ac58: a "member" for the side assignment is any person whose +0x2a is not 0xff.
static func _member(pid: int) -> bool:
	return Mem.r8(Mem.person_addr(pid) + 0x2a) != 0xff


# ------------------------------------------------------------------ setup / open / close
## 0x4499a3(DUEL, A, B, backdrop): the player-side fighter is always side 1.
func setup(a: int, b: int, backdrop: int) -> void:
	if a >= 0x400 or b >= 0x400 or a == b:     # 0x4103ee returns 0
		return
	if _member(a):
		pids = [b, a]
	elif _member(b):
		pids = [a, b]
	else:
		# [G] outside a battle 0x477adc gives 0xff and the original reads unit 255 (past the array); treated as
		# "not player side"
		pids = [b, a] if hostility(unit_of(a)) == 1 else [a, b]
	backdrop_idx = backdrop & 0xffff
	active = _activate()
	if not active:
		return
	for f in fighters:
		f.queue_free()
	fighters.clear()
	for side in 2:
		var p := Game.person(pids[side])
		var f := DuelFighter.new()
		f.layer = self
		f.side = side
		var colour := mini(Mem.r8(_uaddr(slots[side]) + 5), 2)
		f.setup(p.sprite_entry(colour) if p else 0)
		f.x = HOME_X[side]
		f.dir = 1 if side == 0 else 3       # DUEL+0x12 = 1, +0x3e = 3 (MOV caches mirrored, 0x43fd34)
		f.img("mov", 8)
		add_child(f)
		fighters.append(f)
	move_child(_overlay, -1)
	_tile = Assets.tex("gfx/ui/mark/01.png")    # Mark 花色 0x2a0 (0x473202 with flag 1)
	bubbles = [[], []]
	banner = ""
	intro_names = [false, false]
	show_portrait = [false, false]
	grey_portrait = [false, false]
	mode = 1
	visible = true
	_redraw()
	# 0x4486f4: frame, BGM 10, portraits and big names, "单挑", backdrop
	prev_track = Mem.r8(Mem.GS + 4)
	_bgm(10)
	await _t(10)
	show_portrait[0] = true
	intro_names[0] = true
	_redraw()
	await _t(20)
	banner = "单挑"
	_redraw()
	await _t(20)
	intro_names[1] = true
	show_portrait[1] = true
	_redraw()
	await _t(43)
	banner = ""
	intro_names = [false, false]
	mode = 2
	_redraw()


## 0x4495f4: fighters' units — in a battle the persons' own units (both must exist, else the duel stays
## inactive and every op does nothing); outside a battle slots 60 (side 0, colour 2) and 11 are borrowed:
## unit+0 = person, +4 = slot (+5 = 2 for side 0), sprite reloaded (0x43fe2c). Box: §1.2.
func _activate() -> bool:
	if _in_battle():
		slots = [unit_of(pids[0]), unit_of(pids[1])]
		if slots[0] < 0 or slots[1] < 0:
			return false
		box = Vector2(8, 84)
	else:
		slots = [60, 11]
		for side in 2:
			var a := _uaddr(slots[side])
			Mem.w32(a, pids[side])
			Mem.w8(a + 4, slots[side])
			if side == 0:
				Mem.w8(a + 5, 2)
		box = Vector2(8, 48)
	exp_award = 0
	return true


## 0x61 (0x448cb3): start of the fight — bubbles erased, "胜 负" banner.
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


## 0x5f (0x4498e5): close — 3 s skippable hold, the map/scene back, overlay flag [0x500ef9] = 0, BGM restored
## (GS+4 at setup), then SetExp 0x4088cd(side-1 person, exp + DUEL+0x84): in a battle only when the side-1 unit is
## player controlled (0x43ff54: unit +5 == 0), after the map EXP popup 0x450986; outside a battle without a popup.
## The host then re-shows the town toolbar (0x411991) when outside a battle.
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
	Mem.w8(0x500ef9, 0)
	_bgm(prev_track)
	var p1 := Game.person(pids[1])
	if _in_battle():
		if Mem.r8(_uaddr(slots[1]) + 5) != 0:
			exp_award = 0
			return
		var acts: Variant = stage.get("actions")
		if exp_award > 0 and acts is Object and (acts as Object).has_method("gain_exp"):
			await acts.gain_exp(BUnit.at(slots[1]), exp_award)
			exp_award = 0
			return
	if p1 and exp_award > 0:
		p1.add_exp(exp_award)
	exp_award = 0


# ------------------------------------------------------------------ speech
## 0x60 (0x448bae): the fighter fades in from white in 10 steps (k = 10..1: 0x40690c toward white by k·10 %,
## 1 T each; k = 0 is never drawn, so with act 0 it stays 10 % whitened until the next redraw — original quirk),
## wait 5, optional action, then speaks (mode 1).
func appear_say(side: int, text: String, act: int) -> void:
	if not active:
		return
	var f: DuelFighter = fighters[_s(side)]
	f.shown = true
	f.img("mov", 8)
	for k in range(10, 0, -1):
		f.flash(k * 0.1)
		await _t(1)
	await _t(5)
	if act != 0:
		await action(side, act)
	await say2(side, text, 1)


## 0x63 (0x4431af): speech bubble; 3 lines per page; empty text erases the bubble. Hold per page by the message
## speed byte GS+1 (0x42401e): 0 → 5, 1 → 12, 2 → 20 (skippable 0x42c646); mode 0 does not wait.
func say2(side: int, text: String, mode_: int) -> void:
	if not active:
		return
	var s := _s(side)
	var cut := text.find("\n&")
	if cut >= 0:
		text = text.substr(0, cut)
	if OS.get_environment("WG_TRACE_TEXT") != "":
		var pn := Game.person(pids[s])
		print("  [duel %s] %s" % [pn.name if pn else "?", text.replace("\n", " ")])
	if text == "":
		bubbles[s] = []
		_overlay.queue_redraw()
		return
	var lines := text.split("\n")
	var spd := 3 if mode_ == 0 else Mem.r8(Mem.GS + 1)
	var page := 0
	bubble_page[s] = 0
	while page * 3 < lines.size():
		var pl: Array = []
		for i in range(page * 3, mini(page * 3 + 3, lines.size())):
			pl.append(lines[i])
		bubble_page[s] = page
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
				# [G] typewriter 1 T per character (0x42c8b0 with flag 1; timing as wg2025)
				var end := Time.get_ticks_msec() + int(TICK * 1000 / maxf(Engine.time_scale, 0.01))
				while Time.get_ticks_msec() < end:
					await get_tree().process_frame
					if _clicked(c):
						skip = true
						break
		_overlay.queue_redraw()
		if spd < 3:
			await _skippable([5, 12, 20][spd])
		page += 1


# ------------------------------------------------------------------ actions (op 0x64)
func _s(side: int) -> int:
	return 0 if side == 0 else 1


func _fwd(f: DuelFighter) -> int:
	return 1 if f.dir == 1 else -1


func _family(f: DuelFighter) -> int:
	var p := Game.person(pids[f.side])
	return Game.family_of(p.cls) if p else 0


## Step sound 0x44eb0a(family) → 0x43f371: none for flying families (row 0x4d20c0 == 3); SE 24 for families 0, 3,
## 4, 11, 13, 15, 18, 23, 32, 34; SE 25 for 5, 28, 30, 33; none for 25, 31, 35; SE 23 otherwise.
func _step_se(f: DuelFighter) -> void:
	var fam := _family(f)
	if Mem.r8(MOVE_KIND_TABLE + fam) == 3 or fam in [25, 31, 35]:
		return
	if fam in [0, 3, 4, 11, 13, 15, 18, 23, 32, 34]:
		_se(24)
	elif fam in [5, 28, 30, 33]:
		_se(25)
	else:
		_se(23)


func _front(f: DuelFighter) -> void:
	# the acting fighter is drawn last (on top)
	move_child(f, _overlay.get_index() - 1)


func action(side: int, act: int) -> void:
	if not active or act > 16:      # 0x448497: acts 0..16
		return
	if act == 16:
		act = 12                     # table 0x4484e7[16] = act 12's routine (0x444bbf)
	var a: DuelFighter = fighters[_s(side)]
	a.shown = true
	a.flash(0.0)
	a.ghosts.clear()
	_front(a)
	match act:
		0:
			a.img("mov", 8)
			_se(8)
		1:
			# 0x444d08: turn round (cache re-mirrored), SE 6
			a.dir = 3 if a.dir == 1 else 1
			a.img("mov", 8)
			_se(6)
		2:
			for i in 4:
				_step_se(a)
				a.x += 24 * _fwd(a)
				a.img("mov", 4 if i < 2 else 5)
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


## act 14 (0x444eea; scripts: 5 uses): spin / cheer / march showcase (wg2025 timeline).
func _war_dance(a: DuelFighter) -> void:
	_bgm(21)
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


## act 15 (0x445943; scripts: 5 uses): looks around (wg2025 timeline).
func _look_around(a: DuelFighter) -> void:
	_bgm(20)
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
	var fam := _family(f)
	return fam < 0x28 and Mem.r8(ARCHER_TABLE + fam) != 0


## 0x407675: charge glow — the attacker blended toward white by 0, 10 … 60 % (0x417383), 1 T each.
func _glow(a: DuelFighter) -> void:
	for pct in range(0, 61, 10):
		a.flash(pct / 100.0)
		await _t(1)
	a.flash(0.0)


## 0x445db8: wind-up, two frames.
##   frame 0: not archer and arg ≠ 0 → SE 33 + glow; else ATK frame 0 and SE 32 (wait 2) / archer SE 37 (wait 1)
##   frame 1: not archer or arg = 0 → ATK frame 1, wait 2 (archer 8); archer with arg ≠ 0 → SE 33 + glow
func _windup(a: DuelFighter, arg: int) -> void:
	var archer := _archer(a)
	a.img("atk", 8)
	if not archer and arg != 0:
		_se(33)
		await _glow(a)
	elif not archer:
		_se(32)
		await _t(2)
	else:
		_se(37)
		await _t(1)
	a.img("atk", 9)
	if not archer or arg == 0:
		await _t(8 if archer else 2)
	else:
		_se(33)
		await _glow(a)


## 0x65 (0x448389): one blow by `side` with a scripted outcome: 0 hit, 1 guard (0x4461cf), 2 guard + knock-back
## (0x44663a), 3 (0x4469eb), 4 dodge (0x446db6). Kinds 5..8 belong to the S-form duel (unreachable here).
## Hit flash (0x40690c): the defender's SPC3 blended 40 % toward red (0xff0000), SE 36.
func exchange(side: int, kind: int, arg: int) -> void:
	if not active or kind > 4:
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
	if kind == 4:
		o.dir = a.dir              # 0x446db6: O turns to A's facing first
	for fr in 6:
		a.img("atk", 10 if fr == 0 else 11)
		match kind:
			0:
				o.set_img("spc", 3, false)
				o.flash(0.4 if fr < 2 else 0.0, Color(1, 0, 0))
				o.dx = p if fr < 2 else 0
				if fr < 2: _se(36)
			1:
				o.set_img("spc", 2, guard_m)
				o.flash(0.0)
				o.dx = p if fr < 2 else 0
				if fr < 2: _se(31)
			2:
				# [G] guard flash as special 0 with arg ≠ 0 (white 40 %); the frame list is a jump table (0x4469d3)
				o.set_img("spc", 2, guard_m)
				o.flash(0.4 if fr < 2 else 0.0)
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
					o.img("mov", 8)
					move_child(o, _overlay.get_index() - 1)
		o.queue_redraw()
		await _t(1)
	o.flash(0.0)
	o.dx = 0
	o.queue_redraw()


## 0x66 (0x44867a): special attacks — 0 lunge (0x44711f), 1 afterimage dash-through (0x4475a2), 2 clash and
## cross (0x448004). Lunge: wind-up without glow; frame 0 moves both by 32·fwd; frames 0-1 the defender at +32
## blended 40 % toward red (arg 0, SPC3, SE 36) or white (arg ≠ 0, SPC2, SE 31).
func special(side: int, kind: int, arg: int) -> void:
	if not active or kind > 2:
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
						o.flash(0.4, Color(1, 0, 0))
						_se(36)
					else:
						o.set_img("spc", 2, guard_m)
						o.flash(0.4)
						_se(31)
					o.dx = p
				else:
					o.flash(0.0)
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
							o.flash(0.4, Color(1, 0, 0))     # [G] same red hit blend as 0x44711f
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
						o.flash(0.0)
						o.dx = 0
				o.queue_redraw()
				a.queue_redraw()
				await _t(1)
			a.ghosts.clear()
			a.queue_redraw()
		2:
			for i in 8:
				var step := 24 if i < 4 else 48
				a.x += step * fwd
				o.x -= step * fwd
				var cross := a.x == o.x
				a.img("mov", 5 if cross else 4 + i % 2)
				o.img("mov", 5 if cross else 4 + i % 2)
				a.flash(0.4 if cross else 0.0)          # [G] white 40 % at the crossing
				o.flash(0.4 if cross else 0.0)
				if cross:
					_se(31)
				await _t(1)
			a.flash(0.0)
			o.flash(0.0)
			_redraw()
			await _t(20)


# ------------------------------------------------------------------ result (op 0x62)
## 0x448e55(winner): wait 20; the loser's image and portrait greyed (0x448d91; the bubbles stay); EXP when side 1
## wins and its unit is player controlled (0x43ff54: unit +5 == 0). lw / ll = levels (+0x2c) of side 1 / side 0:
## lw < ll → min(32 + 8(ll − lw), 200), else max(sat_sub(32, 4(lw − ll)), 10); ×2 when side 0 is the battle boss
## (Reader+0x3d06 = u16 0x496c96, 0x406604). Wait 20.
func result(winner: int) -> void:
	if not active:
		return
	var w := _s(winner)
	await _t(20)
	var loser: DuelFighter = fighters[1 - w]
	loser.grey = true
	grey_portrait[1 - w] = true
	_redraw()
	if w == 1 and Mem.r8(_uaddr(slots[1]) + 5) == 0:
		var lw := Mem.r8(Mem.person_addr(pids[1]) + 0x2c)
		var ll := Mem.r8(Mem.person_addr(pids[0]) + 0x2c)
		var e := 0
		if lw < ll:
			e = mini((ll - lw) * 8 + 32, 200)
		else:
			e = maxi(maxi(32 - (lw - ll) * 4, 0), 10)
		if pids[0] == Mem.r16(0x496c96):
			e <<= 1
		exp_award = e
	await _t(20)


# ------------------------------------------------------------------ drawing
static func _pal(idx: int) -> Color:
	# exe palette 0x4cb1c0 entries used by the duel screen
	match idx:
		0x12: return Color("#ffffff")
		0x13: return Color("#eeeeee")
		0x14: return Color("#dddddd")
		0x15: return Color("#cccccc")
		0x16: return Color("#bbbbbb")
		0x17: return Color("#aaaaaa")
		0x18: return Color("#999999")
		0x19: return Color("#888888")
		0x1a: return Color("#777777")
		0x1c: return Color("#555555")
		0x1f: return Color("#000000")
		0x28: return Color("#ff0000")
		0x2a: return Color("#c30000")
		0x3a: return Color("#0000ff")
		0x3c: return Color("#0000c3")
		0x5c: return Color("#008000")
		0xac: return Color("#001f7b")
		0xad: return Color("#c25502")
	return Color.BLACK


func _hline(y: float, x0: float, x1: float, c: Color) -> void:
	draw_rect(Rect2(box + Vector2(x0, y), Vector2(x1 - x0 + 1, 1)), c)


func _vline(x: float, y0: float, y1: float, c: Color) -> void:
	draw_rect(Rect2(box + Vector2(x, y0), Vector2(1, y1 - y0 + 1)), c)


## 0x4486f4: 12 shading lines on the bottom and right (colour 0x19 − i/2), then 8 on the top and left (0x13 for
## i < 3, then 0x11 + i, the last three shortened by 3(i − 4) at the far end). Drawn once over the tiled frame;
## the backdrop later covers everything inside (8, 8)–(612, 372), leaving these edges visible (no second pass).
func _bevel() -> void:
	var R := BOX_W
	var B := BOX_H
	for i in 12:
		var c := _pal(0x19 - (i >> 1))
		_hline(B - 12 + i, 0, R - 1, c)
		_vline(R - 12 + i, 0, B - 1, c)
	for i in 8:
		var ci := 0x13 if i < 3 else i + 0x11
		var cut := 3 * (i - 4) if i >= 5 else 0
		_hline(i, i, R - 1 - cut, _pal(ci))
		_vline(i, i, B - 1 - cut, _pal(ci))


func _draw() -> void:
	if mode == 0:
		return
	var R := BOX_W
	var B := BOX_H
	# [G] 0x473202's window frame: a 3 px drop shadow outside the box and a light edge (wg2025 analysis of the
	# same routine)
	for i in 3:
		var c := _pal([0x18, 0x1a, 0x1c][i])
		_hline(B + i, i, R, c)
		_vline(R + i, i, B + 2, c)
	_hline(-1, -1, R, _pal(0x13))
	_vline(-1, -1, B, _pal(0x13))
	if _tile:
		for ty in 8:
			for tx in 13:
				draw_texture(_tile, box + Vector2(tx * 48, ty * 48))
	_bevel()
	if mode == 2:
		# backdrop = Logo.e5 entry `backdrop` (604x364) at (8, 8)
		var bd := Assets.tex("gfx/screens/%02d.png" % backdrop_idx)
		if bd:
			draw_texture_rect(bd, Rect2(box + Vector2(8, 8), Vector2(604, 364)), false)
	for s in 2:
		if not show_portrait[s]:
			continue
		var face := Game.person_face(pids[s])
		if face:
			# the engine blits the top 120 rows of taller pictures; the loser's is greyed (0x421841)
			if grey_portrait[s]:
				face = _greyed(face)
			var h := minf(face.get_height(), FACE)
			var r := Rect2(box + PORTRAIT[s], Vector2(FACE, h))
			draw_texture_rect_region(face, r, Rect2(0, 0, FACE, h))
		if mode == 2:
			_small_name(s)


var _grey_cache := {}


## 0x4302a6: a picture converted to grey (average of R, G, B), transparent pixels kept.
func _greyed(t: Texture2D) -> Texture2D:
	if _grey_cache.has(t):
		return _grey_cache[t]
	var img := t.get_image()
	if img == null:
		return t
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var v := (c.r + c.g + c.b) / 3.0
			img.set_pixel(x, y, Color(v, v, v, c.a))
	var g := ImageTexture.create_from_image(img)
	g.set_size_override(t.get_size())
	_grey_cache[t] = g
	return g


func _plain_name(s: int) -> String:
	# 0x407775: the display name (name without trailing digits)
	var p := Game.person(pids[s])
	var n := p.name if p else ""
	var out := ""
	for ch in n:
		if not (ch >= "0" and ch <= "9"):
			out += ch
	return out


static func _gbk_len(s: String) -> int:
	return s.to_multibyte_char_buffer("GBK").size()


## 0x4403aa: white text outlined in the army colour of the fighter's unit (0x413172: side code +5 0 → 0x2a,
## 1 → 0xad, 2 → 0x3a, 3 → 0x5c, other → 0x1f).
func _small_name(s: int) -> void:
	var f := Assets.font()
	var n := _plain_name(s)
	var code := Mem.r8(_uaddr(slots[s]) + 5) if slots[s] >= 0 else 0
	var oc := _pal([0x2a, 0xad, 0x3a, 0x5c][code] if code <= 3 else 0x1f)
	var x := 144.0 if s == 0 else 456.0 - 8 * (_gbk_len(n) >> 1)
	var pos := box + Vector2(x, SMALL_NAME_Y[s] + f.get_ascent(16))
	draw_string_outline(f, pos, n, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, oc)
	draw_string(f, pos, n, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)


func _layered(ci: CanvasItem, top_left: Vector2, text: String, size: int, layers: Array) -> void:
	# layers: [[offset, colour], …] drawn back to front; positions are the text's top-left (0x41e997 flags 0/1)
	var base := top_left + Vector2(0, _bold.get_ascent(size))
	for l in layers:
		ci.draw_string(_bold, base + Vector2(l[0], l[0]), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, l[1])


func _draw_overlay() -> void:
	if mode == 0:
		return
	var c := _overlay
	# big intro names (0x443884: layers at +7/+6 grey 0x18, +2/+1 army colours, top colour)
	for s in 2:
		if not intro_names[s]:
			continue
		var n := _plain_name(s)
		var x := 136.0 if s == 0 else 482.0 - 32 * _gbk_len(n)
		var tl := box + Vector2(x, BIG_NAME_Y[s])
		if s == 0:
			_layered(c, tl, n, 64, [[7, _pal(0x18)], [6, _pal(0x18)], [2, _pal(0xac)], [1, _pal(0x3c)], [0, _pal(0x3a)]])
		else:
			_layered(c, tl, n, 64, [[7, _pal(0x18)], [6, _pal(0x18)], [2, _pal(0x2a)], [1, _pal(0x2a)], [0, _pal(0x28)]])
	# banners (0x431b4d "单挑" 64 px at (245, 160); 0x431b99 "胜 负" 96 px at (192, 144); layers 0x1f/0x18/0x15)
	if banner != "":
		var big := banner != "单挑"
		var tl := box + (Vector2(192, 144) if big else Vector2(245, 160))
		_layered(c, tl, banner, 96 if big else 64, [[3, _pal(0x1f)], [2, _pal(0x18)], [1, _pal(0x15)], [0, Color.WHITE]])
	# speech bubbles (Mark.e5 piece 11 = the compat copies under effects/kao)
	var lcap := Assets.tex("gfx/effects/kao/19ac0_16x64.png")
	var rcap := Assets.tex("gfx/effects/kao/19ec0_16x64.png")
	for s in 2:
		var lines: Array = bubbles[s]
		if lines.is_empty():
			continue
		var y: float = BUBBLE_Y[s]
		var lx: float = BUBBLE_LCAP_X[s]
		var rx: float = BUBBLE_RCAP_X[s]
		if lcap: c.draw_texture(lcap, box + Vector2(lx, y))
		if rcap: c.draw_texture(rcap, box + Vector2(rx, y))
		var fw := 0x104 + (4 if bubble_page[s] > 0 else 0)
		c.draw_rect(Rect2(box + Vector2(lx + 16, y), Vector2(fw + 1, 64)), Color.WHITE)
		var tail := Assets.tex("gfx/effects/kao/%s_16x16.png" % ("198c0" if s == 0 else "199c0"))
		if tail:
			c.draw_texture(tail, box + BUBBLE_TAIL[s])
		var f := Assets.font()
		for i in lines.size():
			c.draw_string(f, box + Vector2(lx + 16, y + 5 + 20 * i + f.get_ascent(16)), lines[i],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
