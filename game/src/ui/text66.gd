class_name Text66
extends RefCounted
## Text rules of the 6.6 engine's windows (Ekd5.exe), shared by Win66 and GameUI.
##
## * Text is drawn on a grid of 8-px columns: a GBK byte takes one column, so an ASCII character is 8 px wide and a
##   Chinese one 16 px (line painter 0x42c8b0, column argument = x / 8). Lines end at "\n" only; nothing wraps.
## * Colour markup (0x423776 / 0x41ca71): "[C" + two upper-case hex digits switches to that palette colour and saves
##   the previous one; "]" switches back, but only while a "[C" is open (otherwise it is drawn). The state is kept
##   across lines; each page starts again in the window's own colour (the saved flag stays set).
## * Colours are indices into the exe palette at 0x4cb1c0 (256 RGBQUADs), read from the emulated image.
## * Times are in the engine's ticks of 50 ms (GetTickCount / 50, 0x47eb97).

const PALETTE := 0x4cb1c0
const TICK := 0.05
const FONT_SIZE := 16
const COL := 8.0            # px per byte column

## Engine colour indices used by the windows.
const C_TEXT := 0x1f        # black: text on parchment (0x42d81e)
const C_NAME := 0x3a        # blue: speaker names (0x42d4b1)
const C_PLAIN := 0xac       # dark blue: text in the sand windows (0x42d81c, 0x42f448)
const C_WHITE := 0x12       # white: captions, title fields (0x412e88 / 0x4766cc)

static var _pal_cache: Dictionary = {}


## Palette colour i (BGR order in memory).
static func pal(i: int) -> Color:
	i &= 0xff
	if _pal_cache.has(i):
		return _pal_cache[i]
	var a := PALETTE + 4 * i
	var c := Color8(Mem.r8(a + 2), Mem.r8(a + 1), Mem.r8(a))
	_pal_cache[i] = c
	return c


## Bytes of a character in GBK (the column count it takes).
static func char_bytes(ch: String) -> int:
	return 1 if ch.unicode_at(0) < 0x80 else 2


## strlen of the GBK text (0x47fc5a).
static func gbk_len(s: String) -> int:
	var n := 0
	for i in s.length():
		n += char_bytes(s[i])
	return n


## Display name of a person (0x407775): the name at record +8 up to the first digit or NUL, at most 8 bytes (the
## engine copies it to +0x37). Renamed persons (0x72 sub 0) have the new name there.
static func display_name(pid: int) -> String:
	if pid < 0 or pid >= 0x400:
		return ""
	var a := Mem.person_addr(pid) + 8
	var b := PackedByteArray()
	for k in 8:
		var c := Mem.r8(a + k)
		if c == 0 or (c >= 0x30 and c <= 0x39):
			break
		b.append(c)
	if b.is_empty():
		return ""
	var s := b.get_string_from_multibyte_char("GBK")
	if s == "" and Game.person(pid) != null:
		s = Game.person(pid).name
	return s


## The text split into lines the way 0x42c8b0 consumes them ("\n" ends a line; "\r" is dropped).
static func lines(text: String) -> PackedStringArray:
	return text.replace("\r", "").split("\n")


## One line as glyphs [char, palette index, column] with the colour markup applied. `st` = {"c": current colour,
## "open": bool, "saved": colour} and is updated (the markup state runs on across lines and pages).
static func glyphs(line: String, st: Dictionary) -> Array:
	var out := []
	var col := 0
	var i := 0
	var n := line.length()
	while i < n:
		var ch := line[i]
		if ch == "]" and bool(st.get("open", false)):
			st["open"] = false
			st["c"] = st.get("saved", st["c"])
			i += 1
			continue
		if ch == "[" and i + 3 < n and line[i + 1] == "C" and _hex(line[i + 2]) >= 0 and _hex(line[i + 3]) >= 0:
			st["saved"] = st["c"]
			st["open"] = true
			st["c"] = _hex(line[i + 2]) * 16 + _hex(line[i + 3])
			i += 4
			continue
		out.append([ch, int(st["c"]), col])
		col += char_bytes(ch)
		i += 1
	return out


## Column width of a line after markup (for centring).
static func line_cols(line: String) -> int:
	var st := {"c": 0, "open": false}
	var g := glyphs(line, st)
	if g.is_empty():
		return 0
	var last: Array = g[g.size() - 1]
	return int(last[2]) + char_bytes(last[0])


static func _hex(ch: String) -> int:
	var c := ch.unicode_at(0)
	if c >= 0x30 and c <= 0x39:
		return c - 0x30
	if c >= 0x41 and c <= 0x46:
		return c - 0x37
	return -1


## Message speed setting GS+1 (0x42401e): 0 = no typewriter; 1 / 2 = one tick per character.
static func speed() -> int:
	return Mem.r8(Mem.GS + 1)


## Page wait mode (0x42db12): GS+0 bit 0x10 → wait for a click (mode 3), else the speed's timed wait.
static func click_mode() -> bool:
	return Mem.r8(Mem.GS) & 0x10 != 0


static func trace(tag: String, text: String) -> void:
	if OS.get_environment("WG_TRACE_TEXT") != "":
		print("  [%s] %s" % [tag, text.replace("\n", " ")])
