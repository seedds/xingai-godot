class_name BUnit
extends RefCounted
## View of one battle unit record (0x30 bytes at 0x4a7b20 + slot·0x30, 250 slots; docs/memory.md §4).
## Slots 0..19 player (我军), 20..59 friends (友军), 60..249 enemies (敌军 / 援军); slot 60 = the enemy leader.
##   +0x00 u32 person id (0xffff empty)   +0x04 own slot   +0x05 kind / colour (0 我 1 友 2 敌 3 援; 5/6 controlled)
##   +0x06/+0x07 x, y   +0x08 AI target slot   +0x09/+0x0a AI point (= activity-area corner 1)   +0x0b action order
##   +0x0c state (1 created/hidden, 2 on the map, 3/4 retreated)   +0x0d flags (2 acted, 4 moved, 0x80 scripted move)
##   +0x0e AI code (7 = player-controlled)   +0x0f facing 0 up 1 right 2 down 3 left   +0x10 u32 HP   +0x14 u32 MP
##   +0x18..+0x1d buff levels 攻 防 精 爆 士 移 (3 normal, 0..2 down, 4..6 up)
##   +0x1e status: four 2-bit counters 麻痹 0-1, 禁咒 2-3, 混乱 4-5, 中毒 6-7   +0x1f retreat-line flag
##   +0x20/+0x21 activity-area corner 2   +0x22 先制攻击 count   +0x23 support-attack count   +0x24 大杀四方 count|0x80
## The map buffer's unit grid (+0xc80, one slot byte per cell, 0xff empty) follows the on-map units: position and
## state writes through this view keep it up to date.

enum Side { PLAYER, FRIEND, ENEMY }

## status masks of 0x423fe8 / 0x4240d6 / 0x423fb9
const ST_PARALYSIS := 0x02
const ST_SEAL := 0x04
const ST_CONFUSION := 0x08
const ST_POISON := 0x10
const ST_ALL := 0x1e

const F_ACTED := 0x02
const F_MOVED := 0x04
const F_SCRIPTED := 0x80
const F_PASS := 0x80          # (old name)

const STATE_NONE := 0
const STATE_HIDDEN := 1
const STATE_ON_MAP := 2
const STATE_GONE := 3

## side() table 0x40672d by kind: 0/1 → 1 (player camp), 2/3 → 0 (enemy camp), 4 → 2 (third party), 5/6 → 1
const SIDE_TABLE := [1, 1, 0, 0, 2, 1, 1]

var slot := 0
var node: UnitSprite
static var gen := 0     # bumped whenever who stands where may have changed
var extra: Dictionary = {}

var addr: int:
	get: return Mem.UNITS + slot * Mem.UNIT_SIZE

## Person id; -1 for an empty slot (record value 0xffff).
var pid: int:
	get:
		var v := Mem.r16(addr)
		return -1 if v == 0xffff else (v & 0xfff)
	set(v):
		Mem.w32(addr, 0xffff if v < 0 else v)
		gen += 1
## Kind / colour byte +5.
var kind: int:
	get: return Mem.r8(addr + 5)
	set(v): Mem.w8(addr + 5, v)
var colour: int:
	get: return Mem.r8(addr + 5)
	set(v): Mem.w8(addr + 5, v)
var pos: Vector2i:
	get: return Vector2i(Mem.r8(addr + 6), Mem.r8(addr + 7))
	set(v):
		if Mem.r8(addr + 0xc) == STATE_ON_MAP:
			_grid_clear()
		Mem.w8(addr + 6, v.x)
		Mem.w8(addr + 7, v.y)
		if Mem.r8(addr + 0xc) == STATE_ON_MAP:
			_grid_set()
		gen += 1
var target: int:
	get: return Mem.r8(addr + 8)
	set(v): Mem.w8(addr + 8, v)
var point: Vector2i:
	get: return Vector2i(Mem.r8(addr + 9), Mem.r8(addr + 0xa))
	set(v):
		Mem.w8(addr + 9, v.x)
		Mem.w8(addr + 0xa, v.y)
var order: int:
	get: return Mem.r8(addr + 0xb)
	set(v): Mem.w8(addr + 0xb, v)
var state: int:
	get: return Mem.r8(addr + 0xc)
	set(v):
		var was := Mem.r8(addr + 0xc)
		if was == STATE_ON_MAP and v != STATE_ON_MAP:
			_grid_clear()
		Mem.w8(addr + 0xc, v)
		if v == STATE_ON_MAP and was != STATE_ON_MAP:
			_grid_set()
		gen += 1
var flags: int:
	get: return Mem.r8(addr + 0xd)
	set(v): Mem.w8(addr + 0xd, v)
## AI code +0xe (0 target, 1 active, 2 hold, 3 passive, 4 follow/flee, 7 player-controlled).
var ai: int:
	get: return Mem.r8(addr + 0xe)
	set(v): Mem.w8(addr + 0xe, v)
var mode: int:
	get: return Mem.r8(addr + 0xe)
	set(v): Mem.w8(addr + 0xe, v)
var dir: int:
	get: return Mem.r8(addr + 0xf) & 3
	set(v): Mem.w8(addr + 0xf, v & 3)
var hp: int:
	get: return Mem.r32(addr + 0x10)
	set(v):
		if (v > 0) != (Mem.r32(addr + 0x10) > 0):
			gen += 1
		Mem.w32(addr + 0x10, maxi(v, 0))
var mp: int:
	get: return Mem.r32(addr + 0x14)
	set(v): Mem.w32(addr + 0x14, maxi(v, 0))
var status: int:
	get: return Mem.r8(addr + 0x1e)
	set(v): Mem.w8(addr + 0x1e, v)
var moved: bool:
	get: return (flags & F_MOVED) != 0
	set(v): flags = (flags | F_MOVED) if v else (flags & ~F_MOVED)
var acted: bool:
	get: return (flags & F_ACTED) != 0
	set(v): flags = (flags | F_ACTED) if v else (flags & ~F_ACTED)

var person: Person:
	get: return Game.person(pid)


static func at(s: int) -> BUnit:
	var u := BUnit.new()
	u.slot = s
	return u


func byte(off: int) -> int:
	return Mem.r8(addr + off)


func set_byte(off: int, v: int) -> void:
	Mem.w8(addr + off, v)


func buff(i: int) -> int:
	return Mem.r8(addr + 0x18 + i)


func set_buff(i: int, v: int) -> void:
	Mem.w8(addr + 0x18 + i, v)


# ------------------------------------------------------------------ map grid (map buffer +0xc80)
func _cell_addr(c: Vector2i) -> int:
	var w := Mem.r8(Mem.MAP_WH)
	var h := Mem.r8(Mem.MAP_WH + 1)
	if c.x < 0 or c.y < 0 or c.x >= w or c.y >= h:
		return -1
	return Mem.MAP_BUF + 0xc80 + c.x + c.y * w


func _grid_clear() -> void:
	var a := _cell_addr(Vector2i(Mem.r8(addr + 6), Mem.r8(addr + 7)))
	if a >= 0 and Mem.r8(a) == slot:
		Mem.w8(a, 0xff)


func _grid_set() -> void:
	var a := _cell_addr(Vector2i(Mem.r8(addr + 6), Mem.r8(addr + 7)))
	if a >= 0:
		Mem.w8(a, slot)


# ------------------------------------------------------------------ sides
## side() 0x406710: 1 = player camp (kinds 0, 1, 5, 6), 0 = enemy camp (2, 3), 2 = third party (kind 3 with
## EV 4053 援军和敌军对攻).
func side() -> int:
	var k := kind
	if k == 3 and Mem.r8(Mem.EV + 4 * 4053) != 0:
		k = 4
	return SIDE_TABLE[k] if k < SIDE_TABLE.size() else Mem.r8(0x40672d + k)


## Two units are hostile iff their sides differ (0x406710).
func is_hostile(o: BUnit) -> bool:
	return side() != o.side()


func is_enemy_of(o: BUnit) -> bool:
	return side() != o.side()


## 0x43ff54: the player's own army (kind 0).
func is_player() -> bool:
	return kind == 0


func is_player_side() -> bool:
	return side() == 1


## Three-way side by slot range (display only).
var side_code: int:
	get:
		if slot < 20: return Side.PLAYER
		if slot < 60: return Side.FRIEND
		return Side.ENEMY


func exists() -> bool:
	return pid >= 0


## On the map and alive.
func active() -> bool:
	return pid >= 0 and state == STATE_ON_MAP and hp > 0


func on_map() -> bool:
	return pid >= 0 and state == STATE_ON_MAP


# ------------------------------------------------------------------ status (0x423fe8 / 0x4240d6 / 0x423fb9)
## Counter of the first status field selected by `mask` (2 麻痹, 4 禁咒, 8 混乱, 0x10 中毒); 0 = none.
func status_count(mask: int) -> int:
	var s := status
	for f in 4:
		if mask & (2 << f):
			return (s >> (2 * f)) & 3
	return 0


func has_status(mask: int) -> bool:
	return status_count(mask) != 0


func paralysed() -> bool:
	return status_count(ST_PARALYSIS) != 0


func sealed() -> bool:
	return status_count(ST_SEAL) != 0


func confused() -> bool:
	return status_count(ST_CONFUSION) != 0


func poisoned() -> bool:
	return status_count(ST_POISON) != 0


## Inflict (0x4240d6): OR the field's initial counter in (0x4240ce: 麻痹 1, 禁咒 2, 混乱 1, 中毒 3).
func inflict(mask: int) -> void:
	var s := status
	for f in 4:
		if mask & (2 << f):
			s |= Mem.r8(0x4240ce + f)
	status = s


## Cure (0x423fb9): clear the selected fields.
func cure(mask: int) -> void:
	var s := status
	for f in 4:
		if mask & (2 << f):
			s &= ~(3 << (2 * f))
	status = s


# ------------------------------------------------------------------ person-derived
func level() -> int:
	return person.level


func max_hp() -> int:
	return person.max_hp()


func max_mp() -> int:
	return person.max_mp()


## Class family of the unit (0x43b4a7).
func family() -> int:
	return person.family()


func cls() -> int:
	return person.cls


## Effect query 0x4101d9 on this unit.
func eff(sid: int, eid: int, m: int, a4: int) -> int:
	return Effects.query(self, sid, eid, m, a4)


## Move points 0x43f74f: the person's move (0x4072bb); 0 while paralysed; move buff ≥ 4 → +2 (≤ 255), other
## than 3 → −2 (≥ 0).
func move_points() -> int:
	if paralysed():
		return 0
	var m := person.move_points()
	var b := buff(5)
	if b >= 4:
		m = mini(m + 2, 255)
	elif b != 3:
		m = Rules.sat_sub(m, 2)
	return m


func sprite_entry() -> int:
	return person.sprite_entry(kind)


func display_name() -> String:
	return person.name if person else "?"
