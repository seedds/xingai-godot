class_name Effects
extends RefCounted
## The 6.6 effect system (docs/skills.md): one query 0x4101d9(unit, sid, eid, mode, a4) over every source of a
## 特效 — personal talents and class skills (table 0x511000), 附加技能 (stream 0x512dc0), equipment item effects,
## 专属 / 套装 (0x50e000) — blocked by an adjacent enemy's 特效屏蔽 and extended by 特效模仿.
## All tables live in the emulated 0x501000 block, so script writes (op 0x72 sub 5/6/10/35) are seen here.
##
## sid = 特效 id (names 0x4cc600 + 16·sid), eid = item effect id 0x1a..0xff (0 = no item effect),
## mode: 0 sum, 1 max, 2 first non-zero (a value 7 overrides), 3 OR; a4 ≠ 0: a matching item counts 100.

const ROWS_PTR := 0x500c3b      # → 0x511000: 255 rows × {4 × (u16 person, u8 value), 2 × (u8 class, u8 value)}
const ADDED := 0x512dc0         # 附加技能 stream: FF sid {value, turns, u16 person}… FF FF (≤ 0x800 bytes)
const STREAM_SCAN := 0x904      # bytes a keyed-list scan looks at (0x900 steps and the last entry)
const EXCL := 0x50e000          # 专属 / 套装 rows: 2 × (u16 person, item, value), 2 × (weapon, armour, accessory, value)
const LEARN := 0x507800         # strategies learned per person: FF strategy {level, u16 person}… FF FF
const GROWTH_ADJ := 0x507ec0    # growth modifiers: FF stat {s8 amount, u16 person}… FF FF

## The running battle (set by BattleStage): queries resolve units and neighbours through it. Outside a battle
## (0x40b922 false) only QuerySources applies.
static var battle = null

## Per-decision cache (AI scoring, previews): nothing that changes a query result may happen between
## begin_cache() and end_cache().
static var _cache: Dictionary = {}
static var _caching := 0


static func begin_cache() -> void:
	_caching += 1


static func end_cache() -> void:
	_caching = maxi(_caching - 1, 0)
	if _caching == 0:
		_cache.clear()
		_flags.clear()


## The combine step 0x413009 → 0x40bf2f: mode 0 sum, 1 max, 3 OR; mode 2 (and others): an empty accumulator
## takes the new value, and the new value wins only if its low byte is 7.
static func combine(mode: int, nv: int, acc: int) -> int:
	match mode:
		0: return (acc + nv) & 0xffffffff
		1: return nv if nv >= acc else acc
		3: return acc | nv
	if mode == 2 and acc == 0:
		acc = nv
	return nv if (nv & 0xff) == 7 else acc


# ------------------------------------------------------------------ sources
## Person entries of row sid (0x4198be): the first entry naming the person gives its value.
static func personal_value(pid: int, sid: int) -> int:
	var row := Mem.r32(ROWS_PTR) + sid * 16
	for k in 4:
		if Mem.r16(row + 3 * k) == pid:
			return Mem.r8(row + 3 * k + 2)
	return 0


## Class entries of row sid (0x4198be → 0x42f998): by default (EV 4058 = 0) an entry also matches higher classes
## of its family; with EV 4058 ≠ 0 only the exact class.
static func class_value(cls: int, sid: int) -> int:
	var row := Mem.r32(ROWS_PTR) + sid * 16
	for k in 2:
		var c := Mem.r8(row + 0xc + 2 * k)
		if class_matches(c, cls):
			return Mem.r8(row + 0xd + 2 * k)
	return 0


static func class_matches(entry: int, cls: int) -> bool:
	if entry >= 0x50:
		return false
	if Mem.r8(Mem.EV + 4 * 4058) != 0:
		return entry == (cls & 0xff)
	return Game.family_of(entry) == Game.family_of(cls & 0xff) and entry <= cls


## Scan a byte stream in the 0x512dc0 format (0x436f16): groups `FF key` followed by entries of `extra + 3`
## bytes whose u16 person is at entry + extra + 1; FF FF ends the list. The scan walks byte by byte between
## groups, as the original does. Returns the entry address or -1.
static func stream_find(base: int, key: int, pid: int, extra: int) -> int:
	var b := Mem.slice(base, STREAM_SCAN)
	var p := 0
	var guard := 0
	key &= 0xff
	pid &= 0xffff
	while guard < 0x900 and p + 1 < STREAM_SCAN:
		guard += 1
		if b[p] == 0xff:
			p += 1
			var k := b[p]
			if k == 0xff:
				return -1
			if k == key:
				var e := p + 1
				while e + extra + 2 < STREAM_SCAN and b[e] != 0xff:
					if (b[e + extra + 1] | (b[e + extra + 2] << 8)) == pid:
						return base + e
					e += extra + 3
				return -1
		p += 1
	return -1


## 附加技能 value of a person (0x42fbe1): the entry's value while its turns ≠ 0.
static func added_value(pid: int, sid: int) -> int:
	var e := stream_find(ADDED, sid, pid, 1)
	if e < 0 or Mem.r8(e + 1) == 0:
		return 0
	return Mem.r8(e)


## Insert / update a 附加技能 entry (0x402ac7 on 0x512dc0, entry_extra 1). An existing entry is overwritten
## (`overwrite`) or each byte becomes the larger of old and new; a new person is appended to the end of its group,
## a new sid as a new group at the end. Nothing happens if the list would pass 0x800 bytes.
static func added_set(pid: int, sid: int, value: int, turns: int, overwrite: bool) -> void:
	stream_put(ADDED, sid, pid, [value & 0xff, turns & 0xff], overwrite)


## Generic writer of the stream lists (0x402ac7): `data` is the entry's leading bytes (1 or 2).
static func stream_put(base: int, key: int, pid: int, data: Array, overwrite: bool) -> void:
	var extra: int = data.size() - 1
	var b := Mem.slice(base, STREAM_SCAN)
	var p := 0
	var group := false
	var guard := 0
	while guard < 0x900 and p + 1 < STREAM_SCAN:
		guard += 1
		if b[p] == 0xff:
			var k := b[p + 1]
			if k == 0xff:
				p += 1
				break
			if k == (key & 0xff):
				group = true
				var e := p + 2
				while e + extra + 2 < STREAM_SCAN and b[e] != 0xff:
					if (b[e + extra + 1] | (b[e + extra + 2] << 8)) == (pid & 0xffff):
						var a := base + e
						if extra == 0:
							Mem.w8(a, data[0])
						elif overwrite:
							Mem.w8(a, data[0])
							Mem.w8(a + 1, data[1])
						else:
							if b[e + 1] < data[1]:
								Mem.w8(a + 1, data[1])
							if data[0] > b[e]:
								Mem.w8(a, data[0])
						return
					e += extra + 3
				p = e
				break
			p += 1
		p += 1
	if p >= 0x800:
		return
	var entry: Array = data.duplicate()
	entry.append(pid & 0xff)
	entry.append((pid >> 8) & 0xff)
	p += base
	if group:
		# p = the FF that ends the group: shift the rest (from p) to make room, then write the entry
		var end := p
		var g2 := 0
		while not (b[end - base] == 0xff and b[end - base + 1] == 0xff) and g2 < 0x900 and end - base + 2 < STREAM_SCAN:
			end += 1
			g2 += 1
		var tail := []
		for a in range(p, end + 2):
			tail.append(b[a - base])
		for i in entry.size():
			Mem.w8(p + i, entry[i])
		for i in tail.size():
			Mem.w8(p + entry.size() + i, tail[i])
	else:
		# p = the second FF of the end marker: a new group `FF key entry FF FF`
		Mem.w8(p, key & 0xff)
		for i in entry.size():
			Mem.w8(p + 1 + i, entry[i])
		Mem.w8(p + 1 + entry.size(), 0xff)
		Mem.w8(p + 2 + entry.size(), 0xff)


## The person's equipment ids by slot (weapon, armour, accessory; 0xff = none).
static func _equip(pid: int) -> Array:
	var b := Mem.person_addr(pid)
	return [Mem.r8(b + 0x2e), Mem.r8(b + 0x31), Mem.r8(b + 0x34)]


## Item effect id an equipped item carries in slot k (0x4079da): weapons / armour only as treasures
## (item +0x14), accessories by type (+0x11). -1 if none.
static func slot_effect(item_id: int, k: int) -> int:
	if item_id == 0xff:
		return -1
	var it := Game.item(item_id)
	if it.is_empty():
		return -1
	if k == 2:
		return int(it["type"])
	if not bool(it.get("treasure", false)) or it.get("special") == null:
		return -1
	return int(it["special"])


## Does the person wear an item with effect eid (0x4079da)? eid 0 never matches.
static func has_item_effect(pid: int, eid: int) -> bool:
	if eid == 0:
		return false
	var eq := _equip(pid)
	for k in 3:
		if slot_effect(eq[k], k) == eid:
			return true
	return false


## Item part value (0x407aed): weapon/armour by level (0x4200f5), accessory its value; slots merged by 0x407b9e.
## The scan stops at an empty accessory slot only (weapon/armour slots are skipped when empty).
static func item_value(pid: int, eid: int, mode: int) -> int:
	var b := Mem.person_addr(pid)
	var acc := 0
	for k in 3:
		var iid := Mem.r8(b + 0x2e + 3 * k)
		if iid == 0xff:
			continue
		if slot_effect(iid, k) != eid:
			continue
		var it := Game.item(iid)
		var v: int
		if k < 2:
			v = value_at_level(it, Mem.r8(b + 0x2f + 3 * k))
		else:
			v = int(it.get("value", 0))
		acc = slot_merge(acc, v, mode, k)
	return acc


## 0x407b9e: merge a slot's value into the accumulator (byte): 0 sum, 1 max, 2 "7 sticks, else the latest",
## 3 OR, 4 the latest, ≥ 5 slot mode−5 wins, otherwise the first non-zero. Clamped to 255.
static func slot_merge(acc: int, nv: int, mode: int, slot: int) -> int:
	var r := acc
	match mode:
		0: r = acc + nv
		1: r = nv if nv > acc else acc
		2: r = acc if acc == 7 else nv
		3: r = acc | nv
		4: r = nv
		_: r = nv if (slot == mode - 5 or acc == 0) else acc
	return mini(r, 0xff)


## Treasure special value at an equipment level (0x4200f5; sv = item +0x16, e = item +0x14).
static func value_at_level(it: Dictionary, lvl: int) -> int:
	var sv := int(it.get("special_value", 0))
	var e := int(it.get("special", 0)) if it.get("special") != null else 0xff
	var k := (e - 0x1a) & 0xff
	var v := sv
	if e == 0x1f:
		v = sv * (lvl + 1)
	else:
		if lvl < 7:
			return sv
		if e == 0x72:
			v = sv * 3 >> 2
		elif e == 0x33:
			return 7 if sv == 4 else sv
		elif e == 0x32:
			return sv << 1
		elif e in [0x36, 0x42, 0x46]:
			return sv + 1
		elif Mem.r8(0x4cb6ba + k) < 7:
			v = sv * 3 >> 1
	if lvl > 9 and Mem.r8(0x4cb5ca + k) != 0xfe:
		return Mem.r8(0x4cb5ca + k)
	return v


## 专属 (0x402cf9 part 1): an entry naming the person whose item is worn in any slot.
static func exclusive_value(pid: int, sid: int) -> int:
	var row := EXCL + sid * 16
	var eq := _equip(pid)
	for k in 2:
		var e := row + 4 * k
		if Mem.r16(e) == pid:
			for j in 3:
				if eq[j] != 0xff and eq[j] == Mem.r8(e + 2):
					return Mem.r8(e + 3)
	return 0


## 套装 (0x402cf9 part 2): every named slot (≠ 0xff) holds that item, at least two slots named.
static func set_value(pid: int, sid: int) -> int:
	var row := EXCL + sid * 16 + 8
	var eq := _equip(pid)
	for k in 2:
		var e := row + 4 * k
		var n := 0
		var ok := true
		for j in 3:
			var c := Mem.r8(e + j)
			if c != 0xff:
				if c != eq[j]:
					ok = false
					break
				n += 1
		if ok and n > 1:
			return Mem.r8(e + 3)
	return 0


# ------------------------------------------------------------------ queries
## QuerySources 0x41301e: personal → 附加技能 → class → item → 专属 → 套装. Returns [value, item part].
static func query_sources(pid: int, sid: int, eid: int, mode: int, a4: int) -> Array:
	if pid < 0 or pid >= 1024:
		return [0, 0]
	sid &= 0xff
	var s := personal_value(pid, sid)
	s = combine(mode, added_value(pid, sid), s)
	var b := Mem.person_addr(pid)
	s = combine(mode, class_value(Mem.r8(b + 0x2b), sid), s)
	var eq := [Mem.r8(b + 0x2e), Mem.r8(b + 0x31), Mem.r8(b + 0x34)]
	var item := 0
	if eid != 0 and (eq[0] != 0xff or eq[1] != 0xff or eq[2] != 0xff) and has_item_effect(pid, eid):
		item = 100 if a4 != 0 else item_value(pid, eid, mode)
	var v := combine(mode, item, s)
	var row := EXCL + sid * 16
	if Mem.r32(row) != 0 or Mem.r32(row + 4) != 0:
		v = combine(mode, v, exclusive_value(pid, sid))
	else:
		v = combine(mode, v, 0)
	if Mem.r32(row + 8) != 0 or Mem.r32(row + 12) != 0:
		v = combine(mode, v, set_value(pid, sid))
	else:
		v = combine(mode, v, 0)
	return [v, item]


static func src(pid: int, sid: int, eid: int, mode: int, a4: int) -> int:
	return query_sources(pid, sid, eid, mode, a4)[0]


## Query 0x4101d9 on a battle unit. Returns the value (eax); query_item() gives the item part (edx).
static func query(u: BUnit, sid: int, eid: int, mode: int, a4: int) -> int:
	return query2(u, sid, eid, mode, a4)[0]


static func query_item(u: BUnit, sid: int, eid: int, mode: int, a4: int) -> int:
	return query2(u, sid, eid, mode, a4)[1]


static func query2(u: BUnit, sid: int, eid: int, mode: int, a4: int) -> Array:
	if u == null:
		return [0, 0]
	var key := 0
	if _caching > 0:
		key = (((u.slot * 256 + (sid & 0xff)) * 256 + (eid & 0xff)) * 4 + (mode & 3)) * 2 + (1 if a4 != 0 else 0)
		if mode > 3:
			key = -key - 1
		if _cache.has(key):
			return _cache[key]
	var r := _query(u, sid, eid, mode, a4)
	if _caching > 0:
		_cache[key] = r
	return r


static func _query(u: BUnit, sid: int, eid: int, mode: int, a4: int) -> Array:
	var pid := u.pid
	if pid < 0:
		return [0, 0]
	var gate := Mem.r32(u.addr) < Mem.r32(Mem.EV + 4 * 4062)
	if gate and enemy_shield_adjacent(u) and not shielded(u):
		return [0, 0]
	var r := query_sources(pid, sid, eid, mode, a4)
	var v: int = r[0]
	if gate and _flag(pid, 88, 0x74) != 0:
		for o in neighbours4(u):
			var nv := src(o.pid, sid, eid, mode, a4)
			if nv != 0:
				v = combine(mode, nv, v)
	return [v, r[1]]


## QueryAny 0x42518f on a person: in a battle the query on the person's unit (0 when the person has none),
## otherwise QuerySources. Returns [value, item part].
static func query_any(pid: int, sid: int, eid: int, mode: int, a4: int) -> Array:
	if battle != null:
		var u: BUnit = battle.unit_of_person(pid)
		if u == null:
			return [0, 0]
		return query2(u, sid, eid, mode, a4)
	return query_sources(pid, sid, eid, mode, a4)


static func any(pid: int, sid: int, eid: int, mode: int, a4: int) -> int:
	return query_any(pid, sid, eid, mode, a4)[0]


## Units on the 4 orthogonal neighbour cells (0x41031c / 0x435884: up, right, down, left).
static func neighbours4(u: BUnit) -> Array:
	var out := []
	if battle == null:
		return out
	for d in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]:
		var o: BUnit = battle.unit_at(u.pos + d)
		if o != null:
			out.append(o)
	return out


## 0x40f1ac: the unit's person has 特效屏蔽, or it has 特效模仿 and a same-side 屏蔽 holder is among its 4
## neighbours while no other-side one is (an other-side holder ends the scan with "no").
static func shielded(u: BUnit) -> bool:
	if _flag(u.pid, 89, 0x75) != 0:
		return true
	if _flag(u.pid, 88, 0x74) == 0:
		return false
	var sd := u.side()
	var r := false
	for o in neighbours4(u):
		if _flag(o.pid, 89, 0x75) != 0:
			if o.side() != sd:
				return false
			r = true
	return r


static var _flags: Dictionary = {}


## 特效模仿 / 特效屏蔽 presence (QuerySources(sid, eid, 1, 1), 0x43c414 / 0x43c426), kept for a cache scope.
static func _flag(pid: int, sid: int, eid: int) -> int:
	if _caching > 0:
		var k := pid * 2 + (1 if sid == 89 else 0)
		if _flags.has(k):
			return _flags[k]
		var v := src(pid, sid, eid, 1, 1)
		_flags[k] = v
		return v
	return src(pid, sid, eid, 1, 1)


## 0x425390: an orthogonal neighbour of another side is shielded.
static func enemy_shield_adjacent(u: BUnit) -> bool:
	var sd := u.side()
	for o in neighbours4(u):
		if o.side() != sd and shielded(o):
			return true
	return false
