class_name BUnit
extends RefCounted
## View of one battle unit record in emulated memory (unit array 0x4b2c50: 115 slots × 0x24 bytes).
## Slots 0..14 player, 15..34 friendly, 35..114 enemy.
## Known layout: +0 u16 person id (0xffff empty) · +4 slot index · +5 colour variant · +6 x · +7 y
## +0xb AI order group · +0xc state (2 = on map) · +0xd flags (4 moved, 2 action finished, 0x80 scripted move)
## +0xe control mode (7 = scripted/inactive) · +0xf dir (0 up 1 right 2 down 3 left)
## +0x10 u32 HP · +0x14 u32 MP · +0x18..+0x1d buff levels (atk def spi agi mor move; 3 neutral)
## +0x1e status bits · +0x1f.. AI params

enum Side { PLAYER, FRIEND, ENEMY }

const ST_PARALYSIS := 0x02
const ST_SEAL := 0x04
const ST_CONFUSION := 0x08
const ST_POISON := 0x10
const ST_FEAR := 0x20
const ST_LOST := 0x40

const F_MOVED := 0x04
const F_ACTED := 0x02
const F_PASS := 0x80

const STATE_NONE := 0
const STATE_HIDDEN := 1
const STATE_ON_MAP := 2

var slot := 0
var node: UnitSprite
static var gen := 0     # bumped whenever who stands where may have changed (BattleStage.unit_at's cache)
static var move_origin := Vector2i.ZERO   # [0x4cfc00]: where the acting unit started its move (冲锋 effect 89)
var grudge := 0
var extra: Dictionary = {}

var addr: int:
	get: return Mem.UNITS + slot * Mem.UNIT_SIZE

var pid: int:
	get:
		var v := Mem.r16(addr)
		return -1 if v == 0xffff else (v & 0xfff)
	set(v):
		Mem.w32(addr, 0xffffffff if v < 0 else v)
		gen += 1
var colour: int:
	get: return Mem.r8(addr + 5)
	set(v): Mem.w8(addr + 5, v)
var pos: Vector2i:
	get: return Vector2i(Mem.r8(addr + 6), Mem.r8(addr + 7))
	set(v):
		Mem.w8(addr + 6, v.x)
		Mem.w8(addr + 7, v.y)
		gen += 1
var order: int:
	get: return Mem.r8(addr + 0xb)
	set(v): Mem.w8(addr + 0xb, v)
var state: int:
	get: return Mem.r8(addr + 0xc)
	set(v):
		Mem.w8(addr + 0xc, v)
		gen += 1
var flags: int:
	get: return Mem.r8(addr + 0xd)
	set(v): Mem.w8(addr + 0xd, v)
var mode: int:
	get: return Mem.r8(addr + 0xe)
	set(v): Mem.w8(addr + 0xe, v)
var dir: int:
	get: return Mem.r8(addr + 0xf) & 3
	set(v): Mem.w8(addr + 0xf, v)
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

var side: int:
	get:
		if slot < 15: return Side.PLAYER
		if slot < 35: return Side.FRIEND
		return Side.ENEMY


static func at(s: int) -> BUnit:
	var u := BUnit.new()
	u.slot = s
	return u


func buff(i: int) -> int:
	return Mem.r8(addr + 0x18 + i)


func set_buff(i: int, v: int) -> void:
	Mem.w8(addr + 0x18 + i, v)


func clear(s: int) -> void:
	slot = s
	extra = {}
	gen += 1
	Mem.fill(addr, Mem.UNIT_SIZE, 0)
	Mem.w32(addr, 0xffffffff)   # +0 u32 person id, empty = 0xffffffff
	Mem.w8(addr + 4, s)
	for i in 6:
		set_buff(i, 3)


## The battle-start reset of a record (0x442613, before 0x44cc85). Only these fields: the AI target point
## [9],[10], the order byte, buffs and the rest keep what the slot's previous unit left there.
func reset(s: int) -> void:
	slot = s
	extra = {}
	gen += 1
	Mem.w32(addr, 0xffff)
	Mem.w8(addr + 4, s)
	Mem.w8(addr + 6, 0xff)
	Mem.w8(addr + 7, 0xff)
	Mem.w8(addr + 8, 0xff)
	Mem.w8(addr + 0xe, 0)
	Mem.w8(addr + 0xc, 0)
	Mem.w8(addr + 0xd, 0)
	Mem.w32(addr + 0x20, 1)


func exists() -> bool:
	return pid >= 0


## On the map and alive (engine: state byte == 2).
func active() -> bool:
	return pid >= 0 and state == STATE_ON_MAP and hp > 0


func is_enemy_of(o: BUnit) -> bool:
	return (side == Side.ENEMY) != (o.side == Side.ENEMY)


func is_player_side() -> bool:
	return side != Side.ENEMY


func level() -> int:
	return person.level


func max_hp() -> int:
	return person.max_hp()


func max_mp() -> int:
	return person.max_mp()


func family() -> int:
	return person.family()


func cls() -> int:
	return person.cls


func has_effect(e: int) -> bool:
	return person.has_effect(e)


func effect_value(e: int) -> int:
	return person.effect_value(e)


func _buffed(v: int, b: int) -> int:
	if b >= 4:
		v = v * 120 / 100
	elif b <= 2:
		v = v * 80 / 100
	return mini(v, 9999)


## Battle stat s (0 atk 1 def 2 spirit 3 agility 4 morale) with buff level applied.
func stat(s: int) -> int:
	return _buffed(person.stat(s), buff(s))


func atk() -> int:
	var a := stat(0)
	if has_effect(54):   # 能力校准
		a = maxi(a, stat(2))
	return a


func def() -> int:
	return stat(1)


func spirit() -> int:
	var s := stat(2)
	if has_effect(54):
		s = maxi(s, stat(0))
	return s


func agi() -> int:
	return stat(3)


func morale() -> int:
	return stat(4)


## MovePoints (0x43f74f): 0 when paralysed; move buff >= 4 → +2 (at most 255), < 3 → −2 (at least 0).
func move_points() -> int:
	if status & ST_PARALYSIS:
		return 0
	var m := person.move_points()
	var b := buff(5)
	if b >= 4:
		m = mini(m + 2, 255)
	elif b < 3:
		m = Rules.sat_sub(m, 2)
	return m


func sprite_entry() -> int:
	return person.sprite_entry(colour)


func display_name() -> String:
	return person.name if person else "?"
