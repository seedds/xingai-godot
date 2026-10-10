class_name DtPicture
extends Node2D
## One animated map object of op 0x72 sub 12 (S插图, records 0x507180 + 32·slot, docs/eex.md §6, gfx.md §7.2): DT.e5
## entry (u16 +0x12) − 1 drawn at the record's position (u16 +2 / +4, pixels in a battle) plus the frame's dx / dy,
## at the frame's opacity, under the units (+6 bit 0 = 0) or over them (bit 0 = 1) (0x404f59 → 0x41f008 → 0x439485).
## Frames step as 0x40505e: every `+8` ms (0xff = still) the frame byte +7 advances; past the end frame (+0x11, 0 =
## the animation's last) it returns to +9 while the loop count +0xe (0 = forever) allows (counter +0xf); loops used up
## → frame +0x10, or the object is removed when +0x10 = 0xff (0x42c395).

const RECORDS := 0x507180

var slot := 0
var dt := -1
var records: Array = []
var images: Array[Texture2D] = []
var _last_ms := 0
var _acc := 0.0


func _init(s: int) -> void:
	slot = s


func addr() -> int:
	return RECORDS + 32 * slot


## (Re)load the DT entry when the record's number changed.
func sync() -> void:
	var n := Mem.r16(addr() + 0x12)
	if n - 1 != dt:
		dt = n - 1
		var a := EffectPlayer.anim_of("dt", dt)
		records = a.get("records", [])
		images.clear()
		for i in int(a.get("images", 0)):
			images.append(Assets.tex("gfx/effects/dt/%02d/img_%02d.png" % [dt, i]))
		_last_ms = 0
	queue_redraw()


## +6 bit 0: drawn over the units.
func over_units() -> bool:
	return Mem.r8(addr() + 6) & 1 != 0


func _process(delta: float) -> void:
	_acc += delta
	if _acc < 0.05:
		return
	_acc = 0.0
	_step(Time.get_ticks_msec())


func _step(now: int) -> void:
	var a := addr()
	if records.is_empty() or Mem.r8(a + 8) == 0xff:
		return
	var loops := Mem.r8(a + 0xe)
	if loops != 0 and Mem.r8(a + 0xf) >= loops:
		if Mem.r8(a + 0x10) == 0xff:
			Mem.w16(a + 0x12, 0)
			queue_free()
		else:
			Mem.w8(a + 7, Mem.r8(a + 0x10))
			queue_redraw()
		return
	var el := now - _last_ms
	if el < Mem.r8(a + 8):
		return
	_last_ms += el
	var f := (Mem.r8(a + 7) + 1) & 0xff
	var end := Mem.r8(a + 0x11)
	if end == 0:
		if f >= records.size():
			if loops == 0:
				f = Mem.r8(a + 9)
			else:
				Mem.w8(a + 0xf, Mem.r8(a + 0xf) + 1)
				if Mem.r8(a + 0xf) >= loops:
					return
				f = Mem.r8(a + 9)
	elif f >= end:
		f = Mem.r8(a + 9)
	Mem.w8(a + 7, f)
	queue_redraw()


func _draw() -> void:
	if records.is_empty():
		return
	var a := addr()
	var r: Dictionary = records[mini(Mem.r8(a + 7), records.size() - 1)]
	var k := int(r.get("image", 0))
	if k < 0 or k >= images.size() or images[k] == null:
		return
	var x := Mem.r16s(a + 2)
	var y := Mem.r16s(a + 4)
	if y < 0:
		# [G] edge-sliding objects (negative positions, 0x4284c5 / 0x429abe) are not used by the shipped scripts:
		# drawn at the stored slide position
		x = Mem.r16s(a + 0x14)
		y = Mem.r16s(a + 0x16)
	else:
		x += int(r.get("dx", 0))
		y += int(r.get("dy", 0))
	draw_texture(images[k], Vector2(x, y), Color(1, 1, 1, clampf(float(r.get("opacity", 1.0)), 0.0, 1.0)))
