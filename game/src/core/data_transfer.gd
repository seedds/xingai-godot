class_name DataTransfer
extends RefCounted
## EEX op 0x78 整型变量赋值 `data_transfer var, dir, id, field` (0x416dcd → 0x4202d8, field decoder 0x415418;
## docs/eex.md §7.1). var ≥ 0x1000 → the error box "变量值溢出". dir 0: EV[var] = field (zero-extended); dir ≠ 0:
## field = EV[var] truncated to the field size. Person record = [0x4cea00] + id·0x48 (no bounds check). Unit = the
## first of the 250 unit records whose dword +0 == id (0x43e4d6; state not checked; EV[4031] does not apply); no unit →
## nothing happens.

enum { PERSON, R_IMG, S_IMG, UNIT }

## field → [kind, offset, size in bytes]
const FIELDS := [
	[R_IMG, 0, 2],                                                          # 0 R形象 u16 0x50f800[id]
	[PERSON, 0x04, 2],                                                      # 1 头像 (+ face table 0x50f000)
	[PERSON, 0x11, 2], [PERSON, 0x13, 2], [PERSON, 0x15, 2], [PERSON, 0x17, 2], [PERSON, 0x19, 2],  # 2–6 攻防精爆士
	[PERSON, 0x1b, 2],                                                      # 7 HP
	[PERSON, 0x1f, 2],                                                      # 8 MP
	[PERSON, 0x21, 1], [PERSON, 0x22, 1], [PERSON, 0x23, 1], [PERSON, 0x24, 1], [PERSON, 0x25, 1],  # 9–13 武统智敏运
	[PERSON, 0x27, 1],                                                      # 14 出战场数
	[PERSON, 0x29, 1],                                                      # 15 撤退场数
	[PERSON, 0x2a, 1],                                                      # 16 我军标识
	[PERSON, 0x2b, 1],                                                      # 17 兵种
	[PERSON, 0x2c, 1],                                                      # 18 人物等级 (write: level-up)
	[PERSON, 0x2d, 1],                                                      # 19 经验值
	[PERSON, 0x2e, 1], [PERSON, 0x2f, 1], [PERSON, 0x30, 1],                # 20–22 武器 / 等级 / 经验
	[PERSON, 0x31, 1], [PERSON, 0x32, 1], [PERSON, 0x33, 1],                # 23–25 防具 / 等级 / 经验
	[PERSON, 0x34, 1],                                                      # 26 辅助
	[S_IMG, 0, 2],                                                          # 27 战场特殊形象 u16 0x501000[id]
	[UNIT, 0x04, 1], [UNIT, 0x06, 1], [UNIT, 0x07, 1],                      # 28 编号, 29 x, 30 y
	[PERSON, 0x35, 2],                                                      # 31 杀敌数
	[UNIT, 0x0e, 1],                                                        # 32 可以控制
	[UNIT, 0x10, 4], [UNIT, 0x14, 4],                                       # 33 HP, 34 MP (no death check)
]


## Unit record of a person for op 0x78 (0x43e4d6): the first slot whose dword +0 equals id, or -1.
static func unit_addr_of(id: int) -> int:
	for s in Mem.UNIT_SLOTS:
		var a := Mem.unit_addr(s)
		if Mem.r32(a) == id:
			return a
	return -1


## Compatibility: slot of that unit or -1.
static func unit_slot_of(pid: int) -> int:
	var a := unit_addr_of(pid)
	return -1 if a < 0 else (a - Mem.UNITS) / Mem.UNIT_SIZE


## [address, size] of a field, or [] when there is none (no unit).
static func field_loc(field: int, id: int) -> Array:
	var f: Array
	if field < FIELDS.size():
		f = FIELDS[field]
	else:
		f = [UNIT, field - 0x0b, 1]         # 35..41 buffs / ailments and beyond: unit + (f − 0x0b), no bound check
	match int(f[0]):
		PERSON:
			return [Mem.person_addr(id) + int(f[1]), int(f[2])]
		R_IMG:
			return [Mem.R_SPRITE + 2 * id, 2]
		S_IMG:
			return [Mem.S_SPRITE + 2 * id, 2]
		UNIT:
			var u := unit_addr_of(id)
			if u < 0:
				return []
			return [u + int(f[1]), int(f[2])]
	return []


static func _read(loc: Array) -> int:
	match int(loc[1]):
		1: return Mem.r8(loc[0])
		2: return Mem.r16(loc[0])
	return Mem.r32(loc[0])


static func read_field(field: int, id: int) -> int:
	var loc := field_loc(field, id)
	return 0 if loc.is_empty() else _read(loc)


static func run(host: ScriptHost, ins: Dictionary) -> void:
	var evi := host.arg(ins, 0)
	if evi > 0xfff:
		await host.ui_message(0, "变量值溢出")
		return
	var dir := host.u16(ins, 1)
	var id := host.u16(ins, 2)
	var field := host.u16(ins, 3)
	var loc := field_loc(field, id)
	if loc.is_empty():
		return
	if dir == 0:
		Mem.set_ev(evi, _read(loc))
		return
	write_field(field, id, Mem.ev(evi))
	host._after_poke(int(loc[0]))
	host.on_field_written(field, id)


## Write side of op 0x78 with its side effects: f1 also sets the face table (0x423e30); f2–f8 run the 功勋 hook first
## (0x408b52 mode 0); f18 with a value above the level levels up silently (0x4073f3), else stores.
static func write_field(field: int, id: int, v: int) -> void:
	var loc := field_loc(field, id)
	if loc.is_empty():
		return
	if field >= 2 and field <= 8:
		merit_set(id, field - 2, v & 0xffff)
	if field == 18:
		var p := Game.person(id)
		if p != null and (v & 0xff) > p.level:
			p.level_up((v & 0xff) - p.level)
			return
	match int(loc[1]):
		1: Mem.w8(loc[0], v)
		2: Mem.w16(loc[0], v)
		_: Mem.w32(loc[0], v)
	if field == 1:
		Mem.w16(Mem.FACE_TABLE + 2 * id, v & 0xffff)


## 功勋 hook 0x408b52(value, 0, stat) for ids < 102 that are not 0xff in +0x2a: the bonus s16 0x508400[id·7 + stat] =
## value − base; base = current word − bonus for HP (+0x1b) / MP (+0x1f), growth sum (0x408a60) + raw ability for
## stats 0..4.
static func merit_set(id: int, stat: int, value: int) -> void:
	if id > 0x65:
		return
	var base_addr := Mem.person_addr(id)
	if Mem.r8(base_addr + 0x2a) == 0xff:
		return
	var b := 0x508400 + 14 * id + 2 * stat
	var base := 0
	if stat == 5:
		base = Mem.r16(base_addr + 0x1b) - Mem.r16s(b)
	elif stat == 6:
		base = Mem.r16(base_addr + 0x1f) - Mem.r16s(b)
	else:
		var p := Game.person(id)
		base = p.growth_sum(stat) + Mem.r8(base_addr + 0x21 + stat)
	Mem.w16(b, (value - base) & 0xffff)
