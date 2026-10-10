class_name SpecialFuncs
extends RefCounted
## Op 0x71 特效请求 (0x403936, unused by the shipped scripts): byte 0x500acd = n; `call [0x409693 + 4n]`: n = 0, 1,
## 3, 4, 5 → the custom-person dialog 0x41ff21 (resource 0x150) for EV[4054]; n = 2 → 0x41e34e. Not ported.
##
## And the persistent system record `SV\SV.E5S` (0x41a280 read byte, 0x41a1c6 write byte; a missing file is created by
## 0x42225a): 0x10f bytes, bytes 4..7 = 1f 01 01 64 (the GS settings copied at new game), the rest 0. Byte 0..2 = the
## endings reached (title emblems 1..3), byte 3 = window pattern, byte item + 0x10 = item collected (0x408b0d).
## Kept as user://sv.e5s.

const SV := "user://sv.e5s"
const SV_SIZE := 0x10f


static func run(_host: ScriptHost, n: int) -> void:
	push_warning("special_func (op 0x71) %d not implemented (unused by the scripts)" % n)


static func sv_read() -> PackedByteArray:
	var b := PackedByteArray()
	if FileAccess.file_exists(SV):
		b = FileAccess.get_file_as_bytes(SV)
	if b.size() < SV_SIZE:
		var fresh := b.is_empty()
		b.resize(SV_SIZE)
		if fresh:
			b[4] = 0x1f
			b[5] = 1
			b[6] = 1
			b[7] = 0x64
	return b


static func sv_write(off: int, v: int) -> void:
	if off < 0 or off >= SV_SIZE:
		return
	if Game.autoplay or Game.demo:
		return      # test runs must not change the player's endings / item record
	var b := sv_read()
	b[off] = v & 0xff
	var f := FileAccess.open(SV, FileAccess.WRITE)
	if f:
		f.store_buffer(b)


## Compatibility name (title screen).
static func read_niuniu() -> PackedByteArray:
	return sv_read()
