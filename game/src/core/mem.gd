extends Node
## Emulated memory of the original engine.
##
## The mod's scripts read/write raw engine memory (pointer table, unit array, game-state block,
## code tables). To make those pokes behave, engine state that scripts can touch is stored here
## in the original byte layout and the rest of the engine reads it through views
## (Person / BUnit / GS accessors).
##
##   0x400000 .. 0x542800   initial image of Ekd5.exe (assets/data/exe_image.bin; BSS zero-filled)
##   0x01000000 ..          heap: person table (1024 × 0x48) then the shops (128 × 0x28), one block as the
##                          original allocates them (0x483bd5); pointers at [0x4cea00] / [0x4cea04]
##   0x02000000 ..          battle map buffer (paged, so it is saved), reached through the object at 0x48b140
##   anything else          sparse 4 KiB pages, zero-initialised
## Layouts and evidence: docs/memory.md.

const IMG_BASE := 0x400000
const HEAP := 0x01000000
const PERSON_SIZE := 0x48
const PERSON_PTR := 0x4cea00      # → persons
const SHOP_PTR := 0x4cea04        # → shops = persons + 0x12000
const LAST_PERSON_PTR := 0x4cea08 # → &person[0x3ff] (scratch record of 0x41de7e / 0x418f1f)
const SHOP_SIZE := 0x28
const HEAP_SIZE := 1024 * PERSON_SIZE + 128 * SHOP_SIZE

# well-known addresses
const GS := 0x4b0770              # game-state block (700 bytes)
const UNITS := 0x4a7b20           # 250 × 0x30 battle units: slots 0..19 player, 20..59 friends, 60..249 enemies
const UNIT_SIZE := 0x30
const UNIT_SLOTS := 250
const FLAGS := 0x492fc8           # flag bits, 0x2000 bytes (Reader 0x492f90 + 0x38): flag i = bit 7 − i%8 of byte i/8
const EV := 0x502000              # script integer variables u32[4096]; config EVs 4016..4095
const PT := 0x506000              # script pointer variables u32[481]
const S_SPRITE := 0x501000        # u16[1024] battle sprite per person (0 = by class)
const SP := 0x501c00              # u8[1024] 必杀 SP per person
const FACE_TABLE := 0x50f000      # u16[1024] face per person (mirrors person +0x04)
const R_SPRITE := 0x50f800        # u16[1024] story sprite per person
const MAP_WH := 0x4b422c          # map width/height bytes
const MAP_OBJ := 0x48b140         # buffer object: u8 type, +4 u32 size, +0xc u32 data pointer (getter 0x401669)
const MAP_BUF := 0x02000000       # where this port keeps that buffer: +0 header, +0x640 terrain, +0xc80 unit grid
const MAP_BUF_SIZE := 0x19000

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
	heap.resize(HEAP_SIZE)
	pages.clear()
	w32(PERSON_PTR, HEAP)
	w32(SHOP_PTR, HEAP + 1024 * PERSON_SIZE)
	w32(LAST_PERSON_PTR, HEAP + 0x3ff * PERSON_SIZE)
	w8(MAP_OBJ, 1)
	w32(MAP_OBJ + 4, MAP_BUF_SIZE)
	w32(MAP_OBJ + 0xc, MAP_BUF)


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
	if addr >= HEAP and addr < HEAP + heap.size():
		return heap[addr - HEAP]
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
	elif addr >= HEAP and addr < HEAP + heap.size():
		heap[addr - HEAP] = v
	else:
		var p := _page(addr)
		p[addr & 0xfff] = v
		pages[addr >> 12] = p


func r16(addr: int) -> int:
	addr &= 0xffffffff
	if addr >= IMG_BASE and addr + 1 < img_end:
		return img.decode_u16(addr - IMG_BASE)
	if addr >= HEAP and addr + 1 < HEAP + heap.size():
		return heap.decode_u16(addr - HEAP)
	return r8(addr) | (r8(addr + 1) << 8)


func w16(addr: int, v: int) -> void:
	addr &= 0xffffffff
	if watch_lo >= 0: _watch(addr, v, 2)
	if addr >= IMG_BASE and addr + 1 < img_end:
		img.encode_u16(addr - IMG_BASE, v & 0xffff)
	elif addr >= HEAP and addr + 1 < HEAP + heap.size():
		heap.encode_u16(addr - HEAP, v & 0xffff)
	else:
		w8(addr, v)
		w8(addr + 1, v >> 8)


func r32(addr: int) -> int:
	addr &= 0xffffffff
	if addr >= IMG_BASE and addr + 3 < img_end:
		return img.decode_u32(addr - IMG_BASE)
	if addr >= HEAP and addr + 3 < HEAP + heap.size():
		return heap.decode_u32(addr - HEAP)
	return r8(addr) | (r8(addr + 1) << 8) | (r8(addr + 2) << 16) | (r8(addr + 3) << 24)


func w32(addr: int, v: int) -> void:
	addr &= 0xffffffff
	v &= 0xffffffff
	if watch_lo >= 0: _watch(addr, v, 4)
	if addr >= IMG_BASE and addr + 3 < img_end:
		img.encode_u32(addr - IMG_BASE, v)
	elif addr >= HEAP and addr + 3 < HEAP + heap.size():
		heap.encode_u32(addr - HEAP, v)
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


## Story flags are bits, most significant first (get 0x40c6a9, set 0x40c6cc).
func flag(i: int) -> bool:
	return (r8(FLAGS + (i >> 3)) >> (7 - (i & 7))) & 1 != 0


func set_flag(i: int, v: bool) -> void:
	var a := FLAGS + (i >> 3)
	var m := 1 << (7 - (i & 7))
	w8(a, (r8(a) | m) if v else (r8(a) & ~m))


func person_addr(pid: int) -> int:
	return r32(PERSON_PTR) + pid * PERSON_SIZE


func unit_addr(slot: int) -> int:
	return UNITS + slot * UNIT_SIZE


# ------------------------------------------------------------------ save / restore
## Writable ranges that make up the persistent state: all of .text2 (CCZ data + BSS: GS, flags, units, actors …)
## and the 6.6 block 0x501000..0x531000 that the original saves raw (docs/memory.md §9). The tables the original
## never saves (items, classes, strategies) are included and simply come back unchanged.
const SAVE_RANGES := [[0x48b000, 0x4be000], [0x501000, 0x531000]]


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
		img = img.slice(0, o) + b + img.slice(o + b.size())
	heap = Marshalls.base64_to_raw(d["heap"])
	pages.clear()
	for k in d.get("pages", {}):
		pages[int(k)] = Marshalls.base64_to_raw(d["pages"][k])
