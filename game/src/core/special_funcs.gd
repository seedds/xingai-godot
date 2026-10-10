class_name SpecialFuncs
extends RefCounted
## EEX op 0x71 特殊功能 (handler 0x436436, jump table 0x43646b, ids < 0x14):
##  0 / 4: EV[4088] = rand(EV[4088])  (0x43640e: u32 @0x55efe0 = EV base 0x55b000 + 0x3fe0)
##  5    : write byte EV[2699] to SAVEDATA\Niuniu.wa @0 (persistent system record)  (0x436502 → 0x41a1b0)

const NIUNIU := "user://niuniu.bin"


static func run(_host: ScriptHost, n: int) -> void:
	match n:
		0, 4:
			Mem.set_ev(4088, Rules.rand(Mem.ev(4088)))
		5:
			write_niuniu(0, Mem.ev(2699) & 0xff)
		_:
			push_warning("special_func %d not implemented" % n)


static func read_niuniu() -> PackedByteArray:
	var b := PackedByteArray()
	if FileAccess.file_exists(NIUNIU):
		b = FileAccess.get_file_as_bytes(NIUNIU)
	if b.size() < 108:
		b.resize(108)
	return b


static func write_niuniu(off: int, v: int) -> void:
	var b := read_niuniu()
	b[off] = v
	var f := FileAccess.open(NIUNIU, FileAccess.WRITE)
	if f:
		f.store_buffer(b)
