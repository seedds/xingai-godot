class_name DataTransfer
extends RefCounted
## EEX op 0x78 数据存取 (mod handler 0x4d05f9 → 0x4d06c7): move a value between EV[a0] and a game field.
##   args: [ev_index, dir (0 read into EV, 1 write from EV), id (person id), field]
## Field table 0x4d0a97 → (kind, offset, size 0=u8 1=u16 2=u32):
##   kind 0 person record: f0 → u16 table 0x565000[id] (mod), f1..f26 → person + offset
##   kind 1 byte var 0x55a000[id] (f27)
##   kind 2 battle unit found by person id (f28..f41) → unit + offset

const FIELDS := [
	[0, 0x02, 1], [0, 0x04, 1], [0, 0x11, 1], [0, 0x13, 1], [0, 0x15, 1], [0, 0x17, 1], [0, 0x19, 1],
	[0, 0x1c, 2], [0, 0x20, 0], [0, 0x21, 0], [0, 0x22, 0], [0, 0x23, 0], [0, 0x24, 0], [0, 0x25, 0],
	[0, 0x27, 0], [0, 0x29, 0], [0, 0x2a, 0], [0, 0x2b, 0], [0, 0x2c, 0], [0, 0x2d, 0], [0, 0x2e, 0],
	[0, 0x2f, 0], [0, 0x30, 0], [0, 0x31, 0], [0, 0x32, 0], [0, 0x33, 0], [0, 0x34, 0],
	[1, 0, 0],
	[2, 0x04, 0], [2, 0x06, 0], [2, 0x07, 0], [2, 0x0d, 0], [2, 0x0e, 0], [2, 0x10, 2], [2, 0x14, 0],
	[2, 0x18, 0], [2, 0x19, 0], [2, 0x1a, 0], [2, 0x1b, 0], [2, 0x1c, 0], [2, 0x1d, 0], [2, 0x1e, 0],
]

const PERSON_EXT_TABLE := 0x565000


## Slot of the battle unit holding person `pid` (0x43e4d6), or -1.
static func unit_slot_of(pid: int) -> int:
	for s in 115:
		var a := Mem.UNITS + s * Mem.UNIT_SIZE
		var v := Mem.r16(a)
		if v != 0xffff and (v & 0xfff) == pid:
			return s
	return -1


static func field_addr(field: int, id: int) -> int:
	if field < 0 or field >= FIELDS.size():
		return -1
	var f: Array = FIELDS[field]
	match f[0]:
		0:
			if f[1] == 2:
				return PERSON_EXT_TABLE + id * 2
			return Mem.person_addr(id) + f[1]
		1:
			return Mem.BYTEVARS + id
		2:
			var s := unit_slot_of(id)
			if s < 0:
				return -1
			return Mem.UNITS + s * Mem.UNIT_SIZE + f[1]
	return -1


static func read_field(field: int, id: int) -> int:
	var a := field_addr(field, id)
	if a < 0:
		return 0
	match int(FIELDS[field][2]):
		0: return Mem.r8(a)
		1: return Mem.r16(a)
	return Mem.r32(a)


static func write_field(field: int, id: int, v: int) -> void:
	var a := field_addr(field, id)
	if a < 0:
		return
	match int(FIELDS[field][2]):
		0: Mem.w8(a, v)
		1: Mem.w16(a, v)
		_: Mem.w32(a, v)


static func run(host: ScriptHost, ins: Dictionary) -> void:
	var evi := host.arg(ins, 0)
	var dir := host.arg(ins, 1)
	var id := host.arg(ins, 2) & 0xffff
	var field := host.arg(ins, 3)
	if dir == 0:
		var a := field_addr(field, id)
		if a < 0:
			return
		Mem.set_ev(evi, read_field(field, id))
	else:
		write_field(field, id, Mem.ev(evi))
		host._after_poke(field_addr(field, id))
		host.on_field_written(field, id)
