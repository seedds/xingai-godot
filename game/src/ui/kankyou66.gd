class_name Kankyou66
extends Dlg66
## Dialog "KANKYOU" 环境设定 (toolbar 0x6b / title 沙場點兵, 0x44f8eb → proc 0x41bad7): the display options are edited
## on a copy (0x500fa4 ← 0x501a65, 32 bytes) and copied back by 确定 (0x41b914); 取消 drops them.
##  * check boxes 0x406..0x40a ← bits 0..4 of GS+0 (听背景音乐, 听音效, 战斗时窗口自动最大化, 自动显示战场缩小图,
##    会话窗口不自动关闭); radio groups 讯息显示速度 (GS+1) and 武将移动速度 (GS+2): 快 / 普通 / 慢 (init 0x41bd7f);
##  * list box 0x4d3: the 21 options (strings 0x4beec0 + 16k, owner-drawn 0x44d6e6 with ImageList 0x492e1c icon
##    7 / 8 = off / on); a click toggles the copy (0x41a155);
##  * combo 0x5d1 加速1..加速4 / 无 ↔ word 0x500ad8 (low byte 0 → 无, else the high byte); combo 0x5d0 花色1..花色4 / 无
##    ↔ the window pattern byte 0x500fa0 (0x40abdc);
##  * track bar 0x411 音量 0..100 (TBM_SETRANGE 0x640000) ↔ GS+3, applied while dragging (WM_HSCROLL → 0x42e218:
##    the BGM volume ×10 via MCI 0x42f7fc), its value in static 0x412.
## [G] Of the settings the display options, 讯息显示速度 (Text66), 武将移动速度 (BattleActions.step_time) and
## 自动显示战场缩小图 (BattleOverview) act in the port; 听背景音乐 pauses the BGM player and the volume sets its level —
## the others (加速 included) are stored for the save file only.

const OPT := 0x501a65
const NAMES := ["5-显示生命条", "6-显示Buff状态", "7-显示部队状态", "8-显示双击暴击", "9-显示地形状态", "a-开启自动存档",
	"b-显示策略等级", "c-攻击方描边", "d-保留装备", "e-显示行动顺序", "f-显示AI仇恨", "g-显示危险区域", "h-显示升级提示",
	"i-显示AI方针", "j-显示Buff回合", "k-连续使用功勋", "l-跳过战斗过程", "m-暴击不语", "n-显示撤退部队", "o-预览行动路线",
	"p-极速移动"]
const CHECKS := [[0x406, 3, 37, 53, 14, "听背景音乐"], [0x407, 3, 53, 43, 14, "听音效"],
	[0x408, 3, 69, 104, 15, "战斗时，窗口自动最大化"], [0x409, 3, 85, 120, 15, "战斗时，自动显示战场缩小图"],
	[0x40a, 3, 101, 90, 15, "会话窗口不自动关闭"]]
const RADIOS := [[0x40b, 10, 129, 20, 8, "快"], [0x40c, 50, 129, 32, 8, "普通"], [0x40d, 94, 129, 20, 8, "慢"],
	[0x40e, 10, 156, 20, 8, "快"], [0x40f, 50, 156, 32, 8, "普通"], [0x410, 94, 156, 20, 8, "慢"]]
const TRACK := 0x411

var copy := PackedByteArray()     # 0x500fa4
var bits := 0                     # GS+0 check boxes
var radio := [0, 0]               # GS+1, GS+2
var volume := 0                   # GS+3
var _vol0 := 0
var _drag_track := false


static func run(ui: Node) -> void:
	if Game.autoplay:
		return
	var d := Kankyou66.new()
	d.build()
	await Dlg66.run_dialog(ui, d)


func build() -> void:
	setup("环境设定", 220, 195)
	copy.resize(32)
	for k in 32:
		copy[k] = Mem.r8(OPT + k)
	bits = Mem.r8(Mem.GS)
	radio = [mini(Mem.r8(Mem.GS + 1), 2), mini(Mem.r8(Mem.GS + 2), 2)]
	volume = mini(Mem.r8(Mem.GS + 3), 100)
	_vol0 = volume
	add_button(1, 50, 177, 50, 14, "确定")
	add_button(2, 120, 177, 50, 14, "取消")
	add_static(null, 3, 5, 102, 8, "请点击项目以设定。")
	add_static(null, 3, 21, 102, 8, "设定结束后请选择[确定]。")
	for c in CHECKS:
		add_hot(c[0], c[1], c[2], c[3], c[4])
	add_group(3, 118, 120, 25, "讯息显示速度")
	add_group(3, 145, 120, 25, "武将移动速度")
	for c in RADIOS:
		add_hot(c[0], c[1], c[2], c[3], c[4])
	add_static(null, 140, 127, 19, 8, "加速")
	add_static(null, 140, 154, 19, 8, "花色")
	var speed := Mem.r16(0x500ad8)
	add_combo(0x5d1, 160, 125, 45, 51, ["加速1", "加速2", "加速3", "加速4", "无"])
	ctrls[0x5d1]["sel"] = 4 if (speed & 0xff) == 0 else clampi(speed >> 8, 0, 4)
	add_combo(0x5d0, 160, 152, 45, 51, ["花色1", "花色2", "花色3", "花色4", "无"])
	ctrls[0x5d0]["sel"] = clampi(Mem.r8(0x500fa0), 0, 4)
	var lb := add_listbox(0x4d3, 126, 5, 91, 109)
	for k in NAMES.size():
		lb.rows.append({"cells": [NAMES[k]], "enabled": true, "data": k})
	_fill_icons()
	add_hot(TRACK, 55, 39, 69, 11)
	add_static(0x412, 96, 53, 15, 11, str(volume))
	add_static(null, 75, 53, 17, 11, "音量")


func _fill_icons() -> void:
	var lb := list(0x4d3)
	for row in lb.rows:
		var k: int = row["data"]
		row["icon"] = Assets.tex("gfx/icons/list16/%02d.png" % (7 + (1 if copy[k] != 0 else 0)))
	queue_redraw()


func _on_list_click(_lid: Variant, row: int) -> void:
	var k: int = list(0x4d3).rows[row]["data"]
	copy[k] = copy[k] ^ 1
	_fill_icons()


func _on_pic(id: Variant, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	if id is int and id >= 0x406 and id <= 0x40a:
		bits = bits ^ (1 << (id - 0x406))
	elif id is int and id >= 0x40b and id <= 0x410:
		var g: int = (id - 0x40b) / 3
		radio[g] = (id - 0x40b) % 3
	queue_redraw()


func _on_command(id: Variant) -> void:
	if id == 1:
		_apply()
		close(1)
		return
	if id == 2 and volume != _vol0:
		_set_volume(_vol0)
	super._on_command(id)


## 确定 0x41b914.
func _apply() -> void:
	var was_bgm := Mem.r8(Mem.GS) & 1
	Mem.w8(Mem.GS, (Mem.r8(Mem.GS) & ~0x1f) | (bits & 0x1f))
	Mem.w8(Mem.GS + 1, radio[0])
	Mem.w8(Mem.GS + 2, radio[1])
	Mem.w8(Mem.GS + 3, volume)
	var sp := int(ctrls[0x5d1]["sel"])
	var w := Mem.r16(0x500ad8)
	Mem.w16(0x500ad8, (w & 0xff00) if sp == 4 else ((sp << 8) | 1))
	var pat := int(ctrls[0x5d0]["sel"])
	if pat != Mem.r8(0x500fa0):
		SpecialFuncs.sv_write(3, pat)          # 0x40abdc(n, 1): the window pattern is kept in byte 3 of SV\SV.E5S
	Mem.w8(0x500fa0, pat)
	# 0x42416a(4, 4, GS): GS+0..3 become the settings bytes 4..7 of SV\SV.E5S, which a new game starts from (0x4241a3)
	for k in 4:
		SpecialFuncs.sv_write(4 + k, Mem.r8(Mem.GS + k))
	for k in 32:
		Mem.w8(OPT + k, copy[k])
	if (bits & 1) != was_bgm:
		Audio.bgm_player.stream_paused = (bits & 1) == 0


func _set_volume(v: int) -> void:
	volume = clampi(v, 0, 100)
	set_text(0x412, str(volume))
	Mem.w8(Mem.GS + 3, volume)
	Audio.bgm_volume_db = linear_to_db(maxf(volume / 100.0, 0.001))
	Audio.bgm_player.volume_db = Audio.bgm_volume_db


func _track_value(x: float) -> int:
	var rr: Rect2 = ctrls[TRACK]["r"]
	return roundi(clampf((x - rr.position.x - 5) / maxf(rr.size.x - 10, 1.0), 0.0, 1.0) * 100)


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		var rr: Rect2 = ctrls[TRACK]["r"]
		if ev.pressed and rr.has_point(ev.position) and _combo_open == null:
			_drag_track = true
			_set_volume(_track_value(ev.position.x))
			accept_event()
			return
		if not ev.pressed and _drag_track:
			_drag_track = false
			accept_event()
			return
	if ev is InputEventMouseMotion and _drag_track:
		_set_volume(_track_value(ev.position.x))
		accept_event()
		return
	super._gui_input(ev)


# ------------------------------------------------------------------ drawing of the controls Dlg66 lacks
func _draw() -> void:
	super._draw()
	for c in CHECKS:
		_draw_check(ctrls[c[0]]["r"], c[5], (bits >> (int(c[0]) - 0x406)) & 1 != 0)
	for c in RADIOS:
		var k: int = int(c[0]) - 0x40b
		_draw_radio(ctrls[c[0]]["r"], c[5], radio[k / 3] == k % 3)
	_draw_track(ctrls[TRACK]["r"])
	if _combo_open != null:
		_draw_combo_drop(ctrls[_combo_open])


func _draw_check(rr: Rect2, text: String, on: bool) -> void:
	var b := Rect2(rr.position.x, rr.position.y + (rr.size.y - 13) / 2, 13, 13)
	draw_rect(b, WINDOW, true)
	bevel(b, true, false)
	if on:
		var p := b.position
		draw_polyline(PackedVector2Array([p + Vector2(3, 6), p + Vector2(5, 9), p + Vector2(10, 3)]), TEXT, 2.0)
	text_at(Rect2(b.end.x + 4, rr.position.y, rr.size.x - 17, rr.size.y), text)


func _draw_radio(rr: Rect2, text: String, on: bool) -> void:
	var c := Vector2(rr.position.x + 6, rr.position.y + rr.size.y / 2)
	draw_circle(c, 6, DARK)
	draw_circle(c, 5, WINDOW)
	if on:
		draw_circle(c, 2.5, TEXT)
	text_at(Rect2(c.x + 9, rr.position.y - 2, rr.size.x, rr.size.y + 4), text)


func _draw_track(rr: Rect2) -> void:
	var y := rr.position.y + rr.size.y / 2
	var ch := Rect2(rr.position.x + 5, y - 2, rr.size.x - 10, 4)
	bevel(ch, true, true)
	var x := ch.position.x + ch.size.x * volume / 100.0
	bevel(Rect2(x - 4, rr.position.y, 9, rr.size.y))
