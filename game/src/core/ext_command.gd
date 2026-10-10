class_name ExtCommand
extends RefCounted
## Op 0x72 信息传送 (`ext_command`, handler 0x47d89e) and op 0x7b 信息传送测试 (`test_ext_command`, 0x47e9f0):
## `call [0x47d8df + 4*sub](string)` (docs/eex.md §6). The string grammar (num() 0x426e64, one separator byte after
## each number) is decoded by tools/eex.py into `ins.ext = {sub, fn, nums, text}`; `nums` hold ints or {"var": N}
## (= EV[N], "neg" for -*N). The fixed-count reader 0x42c6c5(s, n, 2, out) stores every field as a u16, so the
## table writers below take the low word / byte of each field as the original does.
## Battle-only subs (1, 2, 3, 11, 12 in battle, 17, 21 display) are handed to `host.ext_battle(sub, nums, text)`
## after their memory part; BattleStage implements the animations.

const RENAMES := 0x510d00          # 48 × {u16 person (0x400 free), char[14]}
const RENAME_COUNT := 0x5083fe
const LEARN := 0x507800            # keyed list {u8 level, u16 person} under strategy (sub 4)
const SKILL_ROWS_PTR := 0x500c3b   # → 0x511000: 255 × 16 B 特技 rows (sub 5)
const SPECIAL_ROWS_PTR := 0x500c37 # → 0x512000: 80 × 16 B 必杀 rows (sub 6)
const EXCL := 0x50e000             # 255 × 16 B 专属 / 套装 rows (sub 10)
const ADDED := 0x512dc0            # keyed list {u8 value, u8 turns, u16 person} under skill (sub 35)
const GROWTH := 0x507ec0           # keyed list {i8 value, u16 person} under stat (sub 36)
const VOICES := 0x5076c0           # 102 × {u16 person, u8 voice}, 0xffff ends (sub 24)
const PICTURES := 0x507180         # 40 × 32 B (sub 12)


## Resolved numbers of the instruction (EV references read now).
static func nums(ins: Dictionary) -> Array:
	var ext: Dictionary = ins.get("ext", {})
	var out := []
	var raw: Variant = ext.get("nums", [])
	if raw == null:
		return out
	for v in raw:
		if v is Dictionary:
			var x := Mem.r32s(Mem.EV + 4 * int(v.get("var", 0)))
			if bool(v.get("neg", false)):
				x = -x
			out.append(x)
		else:
			out.append(int(v))
	return out


static func field(n: Array, i: int) -> int:
	return int(n[i]) if i < n.size() else 0


static func run(host: ScriptHost, ins: Dictionary) -> void:
	var ext: Dictionary = ins.get("ext", {})
	var sub := int(ext.get("sub", -1))
	var n := nums(ins)
	var text := str(ext.get("text", ""))
	match sub:
		0: rename(text)
		4: _keyed_put(LEARN, field(n, 0), field(n, 2), [field(n, 1)], true)
		5: learn_skill(field(n, 0), field(n, 1), field(n, 2), field(n, 3))
		6: learn_special(field(n, 0), field(n, 1), field(n, 2), field(n, 3))
		7:
			# 0x41104b: shop selectors
			Mem.w16(0x510cfa, field(n, 0))
			Mem.w16(0x510cfc, field(n, 1))
		8:
			# 0x41e5bb: EV[4051] = n; stage name (≤ 22 bytes) into 0x4b0758 (also written by op 0x17)
			Mem.set_ev(4051, field(n, 0))
			host.write_cstr(0x4b0758, text, 22)
		9:
			# 0x414571: ending cast, ≤ 127 persons → u32[] 0x4b2b30, count → EV[4056]
			var k := 0
			for v in n:
				if k >= 127:
					break
				Mem.w32(0x4b2b30 + 4 * k, v)
				k += 1
			Mem.set_ev(4056, k)
		10: equip_skill(n)
		14:
			# 0x40dc06: battle tint. u32 0x501bd4 = colour, u8 0x501bd3 = level, u8 0x501bd2 = mode, then a redraw;
			# mode ≠ 0 also runs the tint routine 0x42aa4a(mode, level) (BattleStage draws it)
			Mem.w32(0x501bd4, field(n, 0))
			Mem.w8(0x501bd3, field(n, 1))
			Mem.w8(0x501bd2, field(n, 2))
			host.ext_battle(sub, n, text)
		16:
			host.ext_battle(sub, n, text)
		18: party_to_average_level()
		19: clear_pt_patch(field(n, 0))
		21:
			# 0x4078ed: unit index = low byte of field 1; mode 0 reads the acted bit into EV[c], else sets / clears bits 6
			var u := Mem.UNITS + Mem.UNIT_SIZE * (field(n, 1) & 0xff)
			var c := field(n, 2)
			if field(n, 0) == 0:
				if c >= 0 and c < 4096:
					Mem.set_ev(c, 1 if Mem.r8(u + 0xd) & 2 else 0)
			else:
				if c != 0:
					Mem.w8(u + 0xd, Mem.r8(u + 0xd) | 0x06)
				else:
					Mem.w8(u + 0xd, Mem.r8(u + 0xd) & ~0x06)
				host.ext_battle(sub, n, text)
		22:
			# 0x4211f4: 0x414050(b, a) — the ending routine of op 0x0f
			await host.ending_routine(field(n, 1), field(n, 0))
		23:
			# 0x408cfa: person byte +3 = v for each listed person
			for i in range(1, n.size()):
				var pid := field(n, i)
				if pid >= 0 and pid < 1024:
					Mem.w8(Mem.person_addr(pid) + 3, field(n, 0))
		24: click_voice(field(n, 0), field(n, 1), field(n, 2))
		26:
			# 0x426404: EV[4025] = rand(n) (0x47fb13: 0 for n < 2)
			Mem.set_ev(4025, Rules.rand(field(n, 0)))
		34:
			await choice_menu(host, field(n, 0), field(n, 1), text)
		35: _keyed_put(ADDED, field(n, 0), field(n, 3), [field(n, 1), field(n, 2)], true)
		36:
			# 0x436eb0: value 0 removes the person's entry (0x436ef2), else sets {i8 value, u16 person} under the stat
			if field(n, 1) & 0xff == 0:
				_keyed_remove(GROWTH, field(n, 0), field(n, 2), 0)
			else:
				_keyed_put(GROWTH, field(n, 0), field(n, 2), [field(n, 1)], true)
		1, 2, 3, 11, 12, 15, 17, 20, 25, 27, 28, 30, 31, 32, 33:
			if sub == 12:
				s_picture_record(n)
			elif sub == 17:
				limit_ai_rect(n)
			elif sub == 15:
				var kk := field(n, 0)
				if kk >= 0 and kk < 3:
					for j in 3:
						Mem.w32(0x501aac + 12 * kk + 4 * j, field(n, 1 + j))
			await host.ext_battle(sub, n, text)
		_:
			# 13 / 29 call native code (not portable, unused); anything else ≥ 37 would crash the original
			push_warning("0x72 sub %d (%s) not implemented" % [sub, ext.get("fn", "?")])


# ------------------------------------------------------------------ sub 0: rename (0x4081f2)
## Rename person EV[4054] (< 0x400): the name is cut to 13 bytes (0x41e1a9) and refused when any person already has it
## (0x44deef, the person itself included); the rename slot of that person, or the first free one (count ++), keeps the
## name; the name is copied over +0x08 (strcpy), the rest of its 9 bytes zeroed (0x435ab0) and the tail beyond 8
## bytes copied to +0x3f (0x40a72c).
static func rename(name: String) -> void:
	var pid := Mem.ev(4054) & 0xffff
	if pid >= 0x400:
		return
	var b := TextExpand.gbk(name)
	if b.size() > 13:
		b = b.slice(0, 13)
	if TextExpand.person_by_name(TextExpand.from_gbk(b)) != -1:
		return
	for k in 48:
		var e := RENAMES + 16 * k
		var who := Mem.r16(e)
		if who == 0x400:
			Mem.w8(RENAME_COUNT, Mem.r8(RENAME_COUNT) + 1)
			Mem.w16(e, pid)
			who = pid
		if who == pid:
			for i in b.size():
				Mem.w8(e + 2 + i, b[i])
			Mem.w8(e + 2 + b.size(), 0)
			apply_name(pid, b)
			return


## Name bytes into the person record: strcpy to +0x08, zero-fill to 9 bytes, tail (bytes 8.., ≤ 5, up to a NUL or
## digit) to +0x3f and a NUL after it (0x40a72c).
static func apply_name(pid: int, b: PackedByteArray) -> void:
	var base := Mem.person_addr(pid)
	for i in b.size():
		Mem.w8(base + 8 + i, b[i])
	Mem.w8(base + 8 + b.size(), 0)
	for i in range(b.size() + 1, 9):
		Mem.w8(base + 8 + i, 0)
	var k := 0
	while k < 5:
		var c := Mem.r8(base + 0x10 + k)
		if c == 0 or (c >= 0x30 and c <= 0x39):
			break
		Mem.w8(base + 0x3f + k, c)
		k += 1
	Mem.w8(base + 0x3f + k, 0)
	TextExpand.invalidate()
	var p := Game.person(pid)
	if p:
		p.name = TextExpand.full_name(pid)


# ------------------------------------------------------------------ table subs
## sub 5 (0x408811): 特技 row = skill (low byte; 0xff = nothing); slots 0–3 at +3·slot {u16 person, u8 value}, slots
## 4–5 at +12 / +14 {u8 class (low byte of `who`), u8 value}; other slots ignored.
static func learn_skill(skill: int, slot: int, who: int, value: int) -> void:
	skill &= 0xff
	slot &= 0xff
	if skill == 0xff:
		return
	var off := 0
	if slot < 4:
		off = slot * 3
	elif slot <= 5:
		off = (slot - 4) * 2 + 0xc
	else:
		return
	var row := Mem.r32(SKILL_ROWS_PTR) + skill * 16 + off
	if slot < 4:
		Mem.w16(row, who & 0xffff)
		Mem.w8(row + 2, value & 0xff)
	else:
		Mem.w8(row, who & 0xff)
		Mem.w8(row + 1, value & 0xff)


## sub 6 (0x40886e): 必杀 row = id (< 80); slots 0–4 at +3·slot {u16 person, u8 level}; slot ≥ 5 writes only the byte
## row + 3·slot = low byte of the person field (slot 5 = byte 15 = the class).
static func learn_special(id: int, slot: int, level: int, person: int) -> void:
	id &= 0xff
	slot &= 0xff
	if id >= 0x50:
		return
	var a := Mem.r32(SPECIAL_ROWS_PTR) + slot * 3 + id * 16
	if slot < 5:
		Mem.w16(a, person & 0xffff)
		Mem.w8(a + 2, level & 0xff)
	else:
		Mem.w8(a, person & 0xff)


## sub 10 (0x411c4a): mode 0 (专属): slot, row, person, item, value → dword row+4·slot = {u16 person, u8 item, u8 value};
## mode 1 (套装): slot, row, weapon, armour, accessory, value → dword row+8+4·slot; row 0xff (low byte) or slot ≥ 2:
## nothing; mode ≥ 2: nothing.
static func equip_skill(n: Array) -> void:
	var mode := field(n, 0) & 0xff
	if mode >= 2:
		return
	var slot := field(n, 1)
	var row := field(n, 2)
	if row & 0xff == 0xff or slot < 0 or slot >= 2:
		return
	var a := EXCL + slot * 4 + row * 16
	if mode == 0:
		Mem.w16(a, field(n, 3) & 0xffff)
		Mem.w8(a + 2, field(n, 4) & 0xff)
		Mem.w8(a + 3, field(n, 5) & 0xff)
	else:
		a += 8
		for j in 4:
			Mem.w8(a + j, field(n, 3 + j) & 0xff)


## Keyed lists (insert 0x402ac7): Effects.stream_put is the battle track's port of the writer; `data` = the entry's
## leading bytes (C = data.size() − 1).
static func _keyed_put(base: int, key: int, pid: int, data: Array, overwrite: bool) -> void:
	var d := []
	for v in data:
		d.append(int(v) & 0xff)
	Effects.stream_put(base, key & 0xff, pid & 0xffff, d, overwrite)


## Remove a keyed-list entry (0x436ef2 → 0x436f16 lookup, 0x42fce4 memmove): the rest of the list moves down by the
## entry size.
static func _keyed_remove(base: int, key: int, pid: int, extra: int) -> void:
	var e := Effects.stream_find(base, key & 0xff, pid & 0xffff, extra)
	if e < 0:
		return
	var sz := extra + 3
	var end := e
	var guard := 0
	while not (Mem.r8(end) == 0xff and Mem.r8(end + 1) == 0xff) and guard < 0x900:
		end += 1
		guard += 1
	end += 2
	for a in range(e, end - sz):
		Mem.w8(a, Mem.r8(a + sz))
	for a in range(end - sz, end):
		Mem.w8(a, 0)


## sub 18 (0x406cfa): repeat until nothing changes: every member among persons 0..126 below the average level
## (0x40c231) levels up silently to it.
static func party_to_average_level() -> void:
	var changed := true
	var guard := 0
	while changed and guard < 300:
		guard += 1
		changed = false
		var avg := Game.party_avg_level()
		for pid in 127:
			if not Game.is_member(pid):
				continue
			var p := Game.person(pid)
			if p.level < avg:
				p.level_up(avg - p.level)
				changed = true


## sub 19 (0x4290fc): undo one PT patch (200 ≤ n < 481 and PT[n] ≠ 0): restore the original value at the patched
## address (0x42913f), PT[n] = 0 and clear the record.
static func clear_pt_patch(i: int) -> void:
	if i < 200 or i >= 481 or Mem.pt(i) == 0:
		return
	var addr := Mem.pt(i)
	Game.write_width(addr, Mem.r32(0x5068c8 + 4 * i), Mem.r8(0x506f84 + i))
	Mem.set_pt(i, 0)
	Mem.w32(0x506464 + 4 * i, 0)
	Mem.w32(0x5068c8 + 4 * i, 0)
	Mem.w8(0x506f84 + i, 0)


## sub 24 (0x4236c2): mode, person, voice (stops at the first empty field). mode 0 deletes the person's entry
## (memmove up to 0x5077f2), otherwise update / append (the next entry's person = 0xffff).
static func click_voice(mode: int, pid: int, voice: int) -> void:
	pid &= 0xffff
	for k in 102:
		var e := VOICES + 3 * k
		var who := Mem.r16(e)
		if mode & 0xff == 0:
			if who == pid:
				for a in range(e, 0x5077f2):
					Mem.w8(a, Mem.r8(a + 3))
				return
		else:
			if who == pid:
				Mem.w8(e + 2, voice & 0xff)
				return
			if who == 0xffff:
				Mem.w16(e, pid)
				Mem.w16(e + 3, 0xffff)
				Mem.w8(e + 2, voice & 0xff)
				return


## Click voice of a person (table 0x5076c0) or -1.
static func voice_of(pid: int) -> int:
	for k in 102:
		var e := VOICES + 3 * k
		var who := Mem.r16(e)
		if who == 0xffff:
			return -1
		if who == pid:
			return Mem.r8(e + 2)
	return -1


## sub 12 record (0x4295fb): slot < 40: +0 slot, +1 battle flag, +2 x, +4 y, +6..+0x13 the six numbers n3..n8 (u16);
## fewer than 10 numbers or anim 0 removes it (0x40519f).
static func s_picture_record(n: Array) -> void:
	var slot := field(n, 0)
	if slot < 0 or slot >= 40:
		return
	var a := PICTURES + 32 * slot
	if n.size() < 10 or field(n, 9) == 0:
		Mem.fill(a, 32, 0)
		return
	Mem.w8(a, slot)
	Mem.w8(a + 1, 1 if Game.main and Game.main.stage and Game.main.stage.in_battle() else 0)
	Mem.w16(a + 2, field(n, 1))
	Mem.w16(a + 4, field(n, 2))
	for j in 7:
		Mem.w16(a + 6 + 2 * j, field(n, 3 + j))


## sub 17 (0x42c846): every unit inside the u-rect (unless unit+0xe == 7) gets the AI action area: u16 unit+9 =
## (ax1, ay1), u16 unit+0x20 = (ax2, ay2).
static func limit_ai_rect(n: Array) -> void:
	var ax1 := field(n, 0)
	var ay1 := field(n, 1)
	var ax2 := field(n, 2)
	var ay2 := field(n, 3)
	for s in Mem.UNIT_SLOTS:
		var u := Mem.unit_addr(s)
		if Mem.r16(u) == 0xffff or Mem.r8(u + 0xc) != 2 or Mem.r8(u + 0xe) == 7:
			continue
		var x := Mem.r8(u + 6)
		var y := Mem.r8(u + 7)
		if x >= field(n, 4) and x <= field(n, 6) and y >= field(n, 5) and y <= field(n, 7):
			Mem.w8(u + 9, ax1)
			Mem.w8(u + 10, ay1)
			Mem.w8(u + 0x20, ax2)
			Mem.w8(u + 0x21, ay2)


# ------------------------------------------------------------------ sub 34: modal choice (0x42c992)
## a = 0: radio buttons; OK → choice register = index + 1 (tested with op 0x13). a ≠ 0: check boxes; EV[0..n-1] = 0 on
## open, at most b checked, OK sets EV[i] = 1 per checked option. Options = the expanded text split on '\n' (≤ 9).
static func choice_menu(host: ScriptHost, a: int, b: int, text: String) -> void:
	var opts := []
	for line in TextExpand.expand(text).split("\n", false):
		var l := line.strip_edges()
		if l != "":
			opts.append(l)
		if opts.size() >= 9:
			break
	if opts.is_empty():
		return
	if a != 0:
		for i in opts.size():
			Mem.set_ev(i, 0)
	var sel: Array = await host.ui_choice_modal(opts, a != 0, b)
	if a == 0:
		if not sel.is_empty():
			host.choice_result = int(sel[0]) + 1
	else:
		for i in sel:
			Mem.set_ev(int(i), 1)


# ------------------------------------------------------------------ 0x7b tests (0x47e9f0)
## Unused by the shipped scripts (0 uses); the six tests (docs/eex.md §6) are not traced, so this reports false.
static func test(_host: ScriptHost, ins: Dictionary) -> bool:
	push_warning("0x7b test_ext_command %s not implemented (unused by the scripts)" % [ins.get("ext", {})])
	return false
