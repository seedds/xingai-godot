class_name Mines
extends RefCounted
## Mines of the 6.6 engine (modern-war maps): the per-cell record u16 0x510000 + ((map w − 1)·y + x)·2 (0x4362c4; the
## original's width − 1 kept) = {item id, owner: 0 placed by the player, 1 detected, 2 hidden (scripts)}, cleared by
## op 0x0a. Mine items (type 0x40) have the kind at +0x13: 0 普 (goes off when stepped on), 1 引, 2 控 (remote); the
## cell's map object is 0xc9 + kind (the trap icon), 0xcd for a hidden one. Item handler 10 (0x41268e): 0x40 place,
## 0x3e 神工铲 dig up, 0x3f 爆破石 detonate, 0x42 探雷器 detect (0x41 thrown items are BattleActions').

const LAYER := 0x510000
const MINE_MEFF := 0x3a


## Any mine record on the map (the layer is all zeros otherwise).
static func any() -> bool:
	var b := Mem.slice(LAYER, 0xc80)
	return b.count(0) != b.size()


static func rec_addr(c: Vector2i) -> int:
	return LAYER + ((Rules.map_w() - 1) * c.y + c.x) * 2


static func item_at(c: Vector2i) -> int:
	return Mem.r8(rec_addr(c)) if Rules.in_map(c) else 0


## Item kind byte +0x13 (0x412685).
static func kind_of(iid: int) -> int:
	return int(Game.item(iid).get("unk_13", 0))


## 0x4749b5(unit, cell, mode): a 普 mine on a cell that is empty or the unit's own, for a unit whose family is not 25.
static func _armed(u: BUnit, c: Vector2i) -> int:
	if u.family() == 0x19 or not Rules.in_map(c):
		return -1
	var iid := item_at(c)
	if iid == 0 or kind_of(iid) != 0:
		return -1
	var o := Rules.slot_at(c)
	if o != 0xff and o != u.slot:
		return -1
	return Mem.r8(rec_addr(c) + 1)


## Mode 0 (the movement planner's stop test, 0x422663): a player unit (kind 0) stops at a mine it knows (owner ≠ 2).
static func known(u: BUnit, c: Vector2i) -> bool:
	var owner := _armed(u, c)
	return owner >= 0 and owner != 2 and u.kind == 0


## Mode 1 (a step of the walk, 0x4121aa): the owner decides who sets it off — a player's mine everyone but allies
## (kind 1), a detected one only player units, a hidden one player units and allies; then it explodes (0x40d956) and
## the unit has acted. True when it went off.
static func step(st: BattleStage, u: BUnit, c: Vector2i) -> bool:
	var owner := _armed(u, c)
	if owner < 0:
		return false
	var k := u.kind
	var go := false
	match owner:
		0: go = k != 1
		1: go = k == 0
		_: go = k < 2
	if not go:
		return false
	Mem.w8(0x500e7c, 2)
	Mem.w16(0x500e49, c.x | (c.y << 8))
	st.refresh_units()
	await explode(st, c)
	u.flags = u.flags | 6
	return true


## 0x40d956 / 0x42d2d3: the mine on the cell goes off — the view centres on it, the mine is removed (0x41d03e), SE and
## Meff 0x3a, the unit on the cell takes the item's value (+0x0e) and the units of its area (+0x17) the thrown share
## (BattleActions [G]); every other mine inside the blast joins the chain. Then the retreat check.
static func explode(st: BattleStage, start: Vector2i) -> void:
	var pending: Array[Vector2i] = [start]
	var done := {}
	while not pending.is_empty():
		var c: Vector2i = pending.pop_front()
		if done.has(c):
			continue
		done[c] = true
		var iid := item_at(c)
		if iid == 0:
			continue
		var it := Game.item(iid)
		var power := BattleActions.item_value(it)
		if OS.get_environment("WG_TRACE_BATTLE") != "":
			print("  mine %s at %s explodes (power %d)" % [it.get("name", "?"), c, power])
		await st.scroll_cell(c)
		remove(st, c)
		var cells: Array[Vector2i] = [c]
		for p in Rules.area_cells(int(it.get("growth", 0)), c, c):
			if not cells.has(p):
				cells.append(p)
		Audio.se(MINE_MEFF)
		await st.strategy.play_cell_effect(MINE_MEFF, c)
		for p in cells:
			var t := Rules.unit_at(p)
			if t == null or t.state != 2 or t.hp == 0:
				continue
			var d := power
			if p != c:
				var ring := absi(p.x - c.x) + absi(p.y - c.y)
				d = maxi(1, power * maxi(50, 100 - 10 * ring) / 100)
			d = mini(d, t.hp)
			await st.result_panel(t, 0, d, 0, 0, 0, 0)
			t.hp = t.hp - d
			st.refresh_units()
		for p in cells:
			if p != c and item_at(p) != 0 and not done.has(p) and not pending.has(p):
				pending.append(p)
	await st.post_action()


## 0x41d03e: the map object of the mine is reverted (0x456670: type 0xc9 + kind, 0xcd when hidden) and the record
## cleared.
static func remove(st: BattleStage, c: Vector2i) -> void:
	var a := rec_addr(c)
	var typ := (kind_of(Mem.r8(a)) - 0x37) & 0xff
	if Mem.r8(a + 1) == 2:
		typ = 0xcd
	st.remove_obstacle(c, typ)
	Mem.w16(a, 0)


## 0x43623b: the cell a mine item may target — 神工铲 a mine, 爆破石 a 控 mine, a mine item a cell without one whose
## terrain (0x412557) is below 5 or 7 — only with byte EV[4093] = 1 (modern war); else "不能在这里使用。".
static func cell_ok(st: BattleStage, typ: int, c: Vector2i) -> bool:
	if Rules.evb(4093) == 1 and Rules.in_map(c):
		var iid := item_at(c)
		match typ:
			0x3e:
				if iid != 0:
					return true
			0x3f:
				if iid != 0 and kind_of(iid) == 2:
					return true
			_:
				var t := Rules.raw_terrain(c)
				if iid == 0 and (t < 5 or t == 7):
					return true
	await st.ui_message(2, "不能在这里使用。")
	return false


## The mine items of handler 10 (0x41268e) after the cell was chosen: the user faces it (0x412148); 0x40 places the
## mine (SE 3, 0x40d8dc: map object 0xc9 + kind on the unchanged terrain, record {item, 0}); 0x3e digs it up (SE 2,
## the item back into the bag with its message 0x414a7e); 0x3f sets it off. Returns true when used.
static func use_at(st: BattleStage, u: BUnit, iid: int, c: Vector2i) -> bool:
	var typ := int(Game.item(iid).get("type", 0))
	if not await cell_ok(st, typ, c):
		return false
	st.actions.face(u, c)
	match typ:
		0x40:
			Audio.se(3)
			st.place_obstacle(c, Rules.raw_terrain(c), (kind_of(iid) - 0x37) & 0xff, true, true)
			Mem.w8(rec_addr(c), iid)
			Mem.w8(rec_addr(c) + 1, 0)
		0x3e:
			Audio.se(2)
			var mine := item_at(c)
			remove(st, c)
			Game.consumable_add(mine, 1)
			await st.ui_message(2, "得到了%s！" % str(Game.item(mine).get("name", "")))
		0x3f:
			await explode(st, c)
		_:
			return false
	st.refresh_units()
	return true


## 探雷器 0x412797: the 3 × 3 area around the user blinks (0x416609(1, rect)); hidden mines (map object 0xcd) of the 8
## neighbours become visible traps (0xc9, record owner 1, change record type 0xc9); the user's action 9, or 11 when
## something was found, and "没发现地雷" / "发现地雷".
static func detect(st: BattleStage, u: BUnit) -> void:
	var p := u.pos
	var x0 := maxi(p.x - 1, 0)
	var y0 := maxi(p.y - 1, 0)
	await st.goal_rect(1, x0 | (y0 << 8) | ((p.x + 1) << 16) | ((p.y + 1) << 24))
	var found := 0
	for d in Rules.DIR8:
		var c: Vector2i = p + d
		if not Rules.in_map(c) or not st.view.marks.has(c) or int(st.view.marks[c]) != 0xcd:
			continue
		found += 1
		st.view.add_mark(0xc9, c)
		Mem.w8(rec_addr(c) + 1, 1)
		st.retype_obstacle(c, 0xcd, 0xc9)
	await st.unit_action(u, 0xb if found != 0 else 9, 0, 0)
	await st.ui_message(2, "发现地雷" if found != 0 else "没发现地雷")
