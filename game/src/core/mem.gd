extends Node
## Emulated memory of the original engine.
##
## The mod's scripts read/write raw engine memory (pointer table, unit array, game-state block,
## code tables). To make those pokes behave, engine state that scripts can touch is stored here
## in the original byte layout and the rest of the engine reads it through views
## (Person / BUnit / GS accessors).
##
##   0x400000 .. 0x5a9c00   initial image of wagan.wa (assets/data/exe_image.bin)
##   0x01000000 ..          heap: person table (1024 × 0x48), pointer stored at [0x4d0048]
##   anything else          sparse 4 KiB pages, zero-initialised

const IMG_BASE := 0x400000
const HEAP_PERSONS := 0x01000000
const PERSON_SIZE := 0x48
const PERSON_PTR := 0x4d0048

# well-known addresses
const GS := 0x4b0770              # game-state block
const UNITS := 0x4b2c50           # 115 × 0x24 battle units
const UNIT_SIZE := 0x24
const FLAGS := 0x492fc8           # u32 per flag (Reader+0x38)
const EV := 0x55b000              # mod extended int vars u32[4096]
const PT := 0x563000              # mod pointer table u32[2048]
const BYTEVARS := 0x55a000        # mod byte vars (person.wa sprite overrides live here)
const MAP_WH := 0x4b422c          # map width/height bytes
const MAP_PTR := 0x4aeb44         # u32 pointer to the battle map buffer: 0x640-byte header, then w×h terrain
const MAP_BUF := 0x02000000       # where this port keeps that buffer (paged memory, so it is saved)

var img := PackedByteArray()
var img_end := 0
var heap := PackedByteArray()
var pages: Dictionary = {}
var _initial_img := PackedByteArray()


func _ready() -> void:
	reset()
	var w := OS.get_environment("WG_MEMWATCH")
	if w != "":
		var parts := w.split("-")
		watch_lo = parts[0].hex_to_int()
		watch_hi = parts[1].hex_to_int() if parts.size() > 1 else watch_lo


func reset() -> void:
	if _initial_img.is_empty():
		var p := Assets.path("data/exe_image.bin")
		_initial_img = FileAccess.get_file_as_bytes(p)
	img = _initial_img.duplicate()
	img_end = IMG_BASE + img.size()
	heap = PackedByteArray()
	heap.resize(1024 * PERSON_SIZE)
	pages.clear()
	w32(PERSON_PTR, HEAP_PERSONS)
	# person.wa sprite-override table is loaded at 0x55a000 by the mod
	var pw := FileAccess.get_file_as_bytes(Assets.path("data/person_wa.bin"))
	for i in pw.size():
		w8(BYTEVARS + i, pw[i])


func _page(addr: int) -> PackedByteArray:
	var k := addr >> 12
	if not pages.has(k):
		var b := PackedByteArray()
		b.resize(4096)
		pages[k] = b
	return pages[k]


func r8(addr: int) -> int:
	addr &= 0xffffffff
	if addr >= IMG_BASE and addr < img_end:
		return img[addr - IMG_BASE]
	if addr >= HEAP_PERSONS and addr < HEAP_PERSONS + heap.size():
		return heap[addr - HEAP_PERSONS]
	var k := addr >> 12
	if pages.has(k):
		return pages[k][addr & 0xfff]
	return 0


var watch_lo := -1
var watch_hi := -1


func _watch(addr: int, v: int, size: int) -> void:
	if addr + size > watch_lo and addr <= watch_hi:
		print("MEMWATCH w%d %x = %x" % [size * 8, addr, v])
		print_stack()


func w8(addr: int, v: int) -> void:
	addr &= 0xffffffff
	v &= 0xff
	if watch_lo >= 0: _watch(addr, v, 1)
	if addr >= IMG_BASE and addr < img_end:
		img[addr - IMG_BASE] = v
	elif addr >= HEAP_PERSONS and addr < HEAP_PERSONS + heap.size():
		heap[addr - HEAP_PERSONS] = v
	else:
		var p := _page(addr)
		p[addr & 0xfff] = v
		pages[addr >> 12] = p


func r16(addr: int) -> int:
	addr &= 0xffffffff
	if addr >= IMG_BASE and addr + 1 < img_end:
		return img.decode_u16(addr - IMG_BASE)
	if addr >= HEAP_PERSONS and addr + 1 < HEAP_PERSONS + heap.size():
		return heap.decode_u16(addr - HEAP_PERSONS)
	return r8(addr) | (r8(addr + 1) << 8)


func w16(addr: int, v: int) -> void:
	addr &= 0xffffffff
	if watch_lo >= 0: _watch(addr, v, 2)
	if addr >= IMG_BASE and addr + 1 < img_end:
		img.encode_u16(addr - IMG_BASE, v & 0xffff)
	elif addr >= HEAP_PERSONS and addr + 1 < HEAP_PERSONS + heap.size():
		heap.encode_u16(addr - HEAP_PERSONS, v & 0xffff)
	else:
		w8(addr, v)
		w8(addr + 1, v >> 8)


func r32(addr: int) -> int:
	addr &= 0xffffffff
	if addr >= IMG_BASE and addr + 3 < img_end:
		return img.decode_u32(addr - IMG_BASE)
	if addr >= HEAP_PERSONS and addr + 3 < HEAP_PERSONS + heap.size():
		return heap.decode_u32(addr - HEAP_PERSONS)
	return r8(addr) | (r8(addr + 1) << 8) | (r8(addr + 2) << 16) | (r8(addr + 3) << 24)


func w32(addr: int, v: int) -> void:
	addr &= 0xffffffff
	v &= 0xffffffff
	if watch_lo >= 0: _watch(addr, v, 4)
	if addr >= IMG_BASE and addr + 3 < img_end:
		img.encode_u32(addr - IMG_BASE, v)
	elif addr >= HEAP_PERSONS and addr + 3 < HEAP_PERSONS + heap.size():
		heap.encode_u32(addr - HEAP_PERSONS, v)
	else:
		w8(addr, v)
		w8(addr + 1, v >> 8)
		w8(addr + 2, v >> 16)
		w8(addr + 3, v >> 24)


func r32s(addr: int) -> int:
	var v := r32(addr)
	return v - 0x100000000 if v >= 0x80000000 else v


func r16s(addr: int) -> int:
	var v := r16(addr)
	return v - 0x10000 if v >= 0x8000 else v


func r8s(addr: int) -> int:
	var v := r8(addr)
	return v - 0x100 if v >= 0x80 else v


func fill(addr: int, n: int, v: int) -> void:
	for i in n:
		w8(addr + i, v)


func copy(dst: int, src: int, n: int) -> void:
	for i in n:
		w8(dst + i, r8(src + i))


# ------------------------------------------------------------------ script variables
func ev(i: int) -> int:
	return r32(EV + 4 * i)


func set_ev(i: int, v: int) -> void:
	w32(EV + 4 * i, v)


func pt(i: int) -> int:
	return r32(PT + 4 * i)


func set_pt(i: int, v: int) -> void:
	w32(PT + 4 * i, v)


func flag(i: int) -> bool:
	return r32(FLAGS + 4 * i) != 0


func set_flag(i: int, v: bool) -> void:
	w32(FLAGS + 4 * i, 1 if v else 0)


func person_addr(pid: int) -> int:
	return r32(PERSON_PTR) + pid * PERSON_SIZE


func unit_addr(slot: int) -> int:
	return UNITS + slot * UNIT_SIZE


# ------------------------------------------------------------------ save / restore
## Writable ranges that make up the persistent state.
const SAVE_RANGES := [[0x48b000, 0x4ccbbc], [0x4ce000, 0x4d0000], [0x55a000, 0x59a960]]


func snapshot() -> Dictionary:
	var parts := []
	for r in SAVE_RANGES:
		parts.append(Marshalls.raw_to_base64(img.slice(r[0] - IMG_BASE, r[1] - IMG_BASE)))
	var pg := {}
	for k in pages:
		pg[str(k)] = Marshalls.raw_to_base64(pages[k])
	return {"ranges": parts, "heap": Marshalls.raw_to_base64(heap), "pages": pg}


func restore(d: Dictionary) -> void:
	reset()
	var parts: Array = d["ranges"]
	for i in SAVE_RANGES.size():
		var b := Marshalls.base64_to_raw(parts[i])
		var o: int = SAVE_RANGES[i][0] - IMG_BASE
		for j in b.size():
			img[o + j] = b[j]
	heap = Marshalls.base64_to_raw(d["heap"])
	pages.clear()
	for k in d.get("pages", {}):
		pages[int(k)] = Marshalls.base64_to_raw(d["pages"][k])
