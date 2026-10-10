class_name Gbk
extends RefCounted
## GBK (code page 936) text without the OS: Godot's String.to_multibyte_char_buffer / get_string_from_multibyte_char
## call iconv, which Android does not have ("Unable to load libiconv"), and Godot 4.7's decoder also hangs on some
## unterminated buffers. Table: assets/data/gbk.bin (tools/gbk_table.py), a u16 code point per lead byte 0x81..0xFE
## × trail byte 0x40..0xFE (0 = no character).

const LEAD0 := 0x81
const TRAIL0 := 0x40
const TRAILS := 0xff - TRAIL0

static var _dec := PackedByteArray()
static var _enc: Dictionary = {}


static func _table() -> PackedByteArray:
	if _dec.is_empty():
		_dec = FileAccess.get_file_as_bytes(Assets.path("data/gbk.bin"))
	return _dec


## GBK bytes → String, up to the first NUL (C strings, as the original reads them). A byte pair that is not a GBK
## character becomes "?".
static func decode(b: PackedByteArray) -> String:
	var t := _table()
	var u := PackedByteArray()
	u.resize(b.size() * 4)
	var n := 0
	var i := 0
	while i < b.size():
		var c := b[i]
		if c == 0:
			break
		var cp := c
		if c >= LEAD0 and c < 0xff and i + 1 < b.size() and b[i + 1] >= TRAIL0 and b[i + 1] < 0xff:
			cp = t.decode_u16(2 * ((c - LEAD0) * TRAILS + b[i + 1] - TRAIL0))
			if cp == 0:
				cp = 0x3f
			i += 2
		else:
			if c >= 0x80:
				cp = 0x3f
			i += 1
		u.encode_u32(4 * n, cp)
		n += 1
	u.resize(4 * n)
	return u.get_string_from_utf32()


## String → GBK bytes (no terminator). A character GBK does not have becomes "?".
static func encode(s: String) -> PackedByteArray:
	if _enc.is_empty():
		var t := _table()
		for k in t.size() / 2:
			var cp := t.decode_u16(2 * k)
			if cp != 0 and not _enc.has(cp):
				_enc[cp] = ((LEAD0 + k / TRAILS) << 8) | (TRAIL0 + k % TRAILS)
	var out := PackedByteArray()
	for ch in s:
		var cp := ch.unicode_at(0)
		if cp < 0x80:
			out.append(cp)
		elif _enc.has(cp):
			var v: int = _enc[cp]
			out.append(v >> 8)
			out.append(v & 0xff)
		else:
			out.append(0x3f)
	return out
