class_name TextExpand
extends RefCounted
## Script text expansion 0x417df6 (used by ops 0x12, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x2c, 0x60, 0x67, 0x69,
## 0x7a and 0x72 sub 34) and the person-name helpers it needs. Works on the GBK bytes like the original:
##  * the copy loop takes control bytes (< 0x20) one at a time and every other byte as a 2-byte unit (it assumes
##    DBCS text), so an escape is only recognised where a unit starts;
##  * it stops at "\n&" (the next dialog segment) or NUL;
##  * `*` escapes (0x44cf28), only when the byte after the marker is a digit:
##      `*/N` → EV[N] as "%d" (0x4246ae), not expanded while EV[4071] ≠ 0 (history records keep the escape);
##      `*.N` → display name of person N (GetName 0x407775);
##      `*+N` `*,N` `*-N` → form 0/1/2 of the custom-name table 0x512500 (20 × {u16 person, 3 × char[5]}), at most
##      4 bytes (0x40c828 with limit 4); a person without an entry leaves the escape as it is.
##    Anything else after `*` stays literal.

const CUSTOM_NAMES := 0x512500


## String → GBK bytes (core/gbk.gd: no iconv, which Android lacks).
static func gbk(s: String) -> PackedByteArray:
	return Gbk.encode(s)


## GBK bytes → String, up to the first NUL.
static func from_gbk(b: PackedByteArray) -> String:
	return Gbk.decode(b)


## 0x417df6 on a script string.
static func expand(s: String) -> String:
	return from_gbk(expand_bytes(gbk(s)))


static func expand_bytes(b: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	var n := b.size()
	while i < n:
		var c := b[i]
		if c == 0:
			break
		if c == 0x2a:
			var r := _escape(b, i)
			if not r.is_empty():
				out.append_array(r[1])
				i += int(r[0])
				continue
		if c < 0x20:
			if c == 0x0a and i + 1 < n and b[i + 1] == 0x26:
				break
			out.append(c)
			i += 1
		else:
			out.append(c)
			if i + 1 < n and b[i + 1] != 0:
				out.append(b[i + 1])
			i += 2
	return out


## Number at b[p] as 0x426e64 reads it (digits only here: the caller checked the first is a digit).
## Returns [value, length].
static func _digits(b: PackedByteArray, p: int) -> Array:
	var v := 0
	var k := 0
	while p + k < b.size() and b[p + k] >= 0x30 and b[p + k] <= 0x39:
		v = v * 10 + (b[p + k] - 0x30)
		k += 1
	return [v, k]


## 0x44cf28: [bytes consumed, expansion] or [] when the `*` is literal.
static func _escape(b: PackedByteArray, i: int) -> Array:
	if i + 2 >= b.size():
		return []
	var kind := b[i + 1] - 0x2b
	if kind < 0 or kind >= 5:
		return []
	var d := b[i + 2]
	if d < 0x30 or d > 0x39:
		return []
	var nv: Array = _digits(b, i + 2)
	var v: int = nv[0]
	var used: int = int(nv[1]) + 2
	match kind:
		4:    # '/': EV value (wsprintf "%d" @0x48b3bd)
			if Mem.ev(4071) != 0:
				return []
			if v < 0 or v >= 4096:
				return []
			return [used, gbk(str(Mem.r32s(Mem.EV + 4 * v)))]
		3:    # '.': person name
			return [used, display_name_bytes(v)]
		_:    # '+' ',' '-': custom name form 0..2
			for k in 20:
				var e := CUSTOM_NAMES + 16 * k
				if Mem.r16(e) == (v & 0xffff):
					var s := PackedByteArray()
					var a := e + 2 + 5 * kind
					while s.size() < 4:
						var ch := Mem.r8(a + s.size())
						if ch == 0:
							break
						s.append(ch)
					return [used, s]
	return []


## Full name bytes of a person: +0x08 (8 bytes) followed by the tail at +0x3f for longer names (0x40a72c).
static func name_bytes(pid: int) -> PackedByteArray:
	return _name(pid, false)


## Display name GetName 0x407775: the name up to the first digit (generic soldiers "士兵1" → "士兵").
static func display_name_bytes(pid: int) -> PackedByteArray:
	return _name(pid, true)


static func _name(pid: int, stop_digit: bool) -> PackedByteArray:
	var out := PackedByteArray()
	if pid < 0 or pid >= 1024:
		return out
	var base := Mem.person_addr(pid)
	for k in 8:
		var c := Mem.r8(base + 8 + k)
		if c == 0 or (stop_digit and c >= 0x30 and c <= 0x39):
			return out
		out.append(c)
	# 8 bytes taken: GetName runs on into +0x3f, where long names keep their tail
	for k in 9:
		var c2 := Mem.r8(base + 0x3f + k)
		if c2 == 0 or (stop_digit and c2 >= 0x30 and c2 <= 0x39):
			break
		out.append(c2)
	return out


static func display_name(pid: int) -> String:
	return from_gbk(display_name_bytes(pid))


static func full_name(pid: int) -> String:
	return from_gbk(name_bytes(pid))


static var _by_name: Dictionary = {}


## Names changed (rename, load, new game): rebuild the lookup on next use.
static func invalidate() -> void:
	_by_name.clear()


## Speaker lookup 0x44deef: the first person 0..0x3ff whose name (+0x08) or display name (+0x37) equals `n`; -1 if none.
static func person_by_name(n: String) -> int:
	if n == "":
		return -1
	if _by_name.is_empty():
		for pid in 1024:
			for nb in [name_bytes(pid), display_name_bytes(pid)]:
				var k := from_gbk(nb)
				if k != "" and not _by_name.has(k):
					_by_name[k] = pid
	return int(_by_name.get(n, -1))


## Dialog speaker header 0x413656: up to '\n' or ',' (≤ 16 bytes); "*.N" names person N directly (0x4082ac).
static func speaker_of(header: String) -> int:
	var b := gbk(header)
	if b.size() >= 3 and b[0] == 0x2a and b[1] == 0x2e and b[2] >= 0x30 and b[2] <= 0x39:
		return int(_digits(b, 2)[0])
	var cut := PackedByteArray()
	for c in b:
		if c == 0x0a or c == 0x2c:
			break
		cut.append(c)
		if cut.size() > 16:
			break
	return person_by_name(from_gbk(cut))
