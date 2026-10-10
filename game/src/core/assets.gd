extends Node
## Runtime asset access. All converted game data lives under res://assets as plain
## files (PNG/JSON/MP3/WAV/OGV) marked importer="keep", and is loaded on demand.

const ROOT := "res://assets/"
## HD pack (tools/upscale_assets.py): 4x AI-upscaled copies of gfx/**.png as .webp. Each is shown at its
## original's logical size (ImageTexture size override), so no drawing code changes. Release builds ship only
## the HD pack; without it (a source checkout that has not fetched it) the original PNGs are used.
const HD_ROOT := "res://assets_hd/"
## Bytes of HD textures the cache keeps alive (LRU); less on a phone.
var hd_budget := (384 if OS.has_feature("mobile") else 1024) * 1024 * 1024

var hd := true                           # debug: WG_HD=0 shows the original art
var hd_pack := false                     # the pack is installed

var _tex_cache: Dictionary = {}          # rel → Texture2D, or WeakRef for HD textures
var _hd_lru: Array = []                  # [rel, texture, bytes], most recently used last
var _hd_bytes := 0
var _json_cache: Dictionary = {}
var _audio_cache: Dictionary = {}
var _font: Font
var _view: Viewport                      # where the game draws: the window, or the touch shell's SubViewport


func path(rel: String) -> String:
	return ROOT + rel


func exists(rel: String) -> bool:
	return FileAccess.file_exists(ROOT + rel) or (rel.ends_with(".png") and hd_active()
			and FileAccess.file_exists(HD_ROOT + rel.get_basename() + ".webp"))


func _ready() -> void:
	hd_pack = DirAccess.dir_exists_absolute(HD_ROOT + "gfx")
	hd = OS.get_environment("WG_HD") != "0"
	set_view(get_tree().root)


func set_view(v: Viewport) -> void:
	if _view and _view.size_changed.is_connected(_apply_filter):
		_view.size_changed.disconnect(_apply_filter)
	_view = v
	_apply_filter()
	_view.size_changed.connect(_apply_filter)


func hd_active() -> bool:
	return hd and hd_pack


## Pixel art is drawn with nearest-neighbour scaling; HD art is smooth, so filter it bilinearly. Shown
## below about 2.5x the original size the 4x art is shrunk enough to shimmer, so then use its mipmaps.
func _apply_filter() -> void:
	var r := _view
	if not hd_active():
		r.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	elif r.size.x >= 640 * 2.5:
		r.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	else:
		r.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## Load a PNG as a texture (cached). With the HD pack active, its 4x version is used when there is one.
func tex(rel: String) -> Texture2D:
	if _tex_cache.has(rel):
		var c: Variant = _tex_cache[rel]
		if not c is WeakRef:
			return c
		var live: Texture2D = c.get_ref()
		if live:
			_hd_touch(rel, live)
			return live
	var t: Texture2D = _hd_tex(rel) if hd_active() else null
	if t:
		_tex_cache[rel] = weakref(t)
		_hd_touch(rel, t)
		return t
	var img := image(rel)
	if img:
		t = ImageTexture.create_from_image(img)
	_tex_cache[rel] = t
	return t


## The HD version of generated art that has no original PNG (e.g. palette-coloured terrain patches), or null.
func hd_only(rel: String) -> Texture2D:
	if not hd_active() or not FileAccess.file_exists(HD_ROOT + rel.get_basename() + ".webp"):
		return null
	return tex(rel)


func _hd_tex(rel: String) -> Texture2D:
	var p := HD_ROOT + rel.get_basename() + ".webp"
	if not FileAccess.file_exists(p):
		return null
	var img := Image.new()
	if img.load_webp_from_buffer(FileAccess.get_file_as_bytes(p)) != OK:
		return null
	var size := _png_size(ROOT + rel)
	if size == Vector2i.ZERO:
		size = img.get_size() / 4
	# some GPUs take at most 8192 px (one map is 8448 wide); the size override keeps the drawn size
	if OS.has_feature("mobile"):
		# a phone shows the 640x480 screen at about 2.7x: halve the big maps and backgrounds (memory, upload time)
		while maxi(img.get_width(), img.get_height()) > 4096:
			img.shrink_x2()
	var k := 8192.0 / maxi(img.get_width(), img.get_height())
	if k < 1.0:
		img.resize(int(img.get_width() * k), int(img.get_height() * k), Image.INTERPOLATE_CUBIC)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	t.set_size_override(size)
	return t


## Width and height from a PNG header, without decoding the image.
func _png_size(p: String) -> Vector2i:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null or f.get_length() < 24:
		return Vector2i.ZERO
	f.big_endian = true
	f.seek(16)
	return Vector2i(f.get_32(), f.get_32())


## Keep recently used HD textures alive up to hd_budget bytes; older ones live only while something uses them.
func _hd_touch(rel: String, t: Texture2D) -> void:
	for i in range(_hd_lru.size() - 1, -1, -1):
		if _hd_lru[i][0] == rel:
			_hd_lru.append(_hd_lru.pop_at(i))
			return
	var bytes := int(t.get_width()) * t.get_height() * 85    # 4x4 texels per logical pixel, 4 bytes each, +1/3 mipmaps
	_hd_lru.append([rel, t, bytes])
	_hd_bytes += bytes
	while _hd_bytes > hd_budget and _hd_lru.size() > 1:
		_hd_bytes -= int(_hd_lru.pop_front()[2])


## Load a PNG as an Image (not cached).
func image(rel: String) -> Image:
	var p := ROOT + rel
	if not FileAccess.file_exists(p):
		push_warning("missing image: " + rel)
		return null
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(p)) != OK:
		return null
	return img


## Parsed JSON, cached unless `keep` is false (scenario scripts: one is in use at a time and a whole
## playthrough's worth would take gigabytes).
func json(rel: String, keep := true) -> Variant:
	if _json_cache.has(rel):
		return _json_cache[rel]
	var p := ROOT + rel
	var v: Variant = null
	if FileAccess.file_exists(p):
		v = JSON.parse_string(FileAccess.get_file_as_string(p))
	else:
		push_warning("missing json: " + rel)
	if keep:
		_json_cache[rel] = v
	return v


func audio(rel: String) -> AudioStream:
	if _audio_cache.has(rel):
		return _audio_cache[rel]
	var p := ROOT + rel
	var s: AudioStream = null
	if FileAccess.file_exists(p):
		var bytes := FileAccess.get_file_as_bytes(p)
		if rel.ends_with(".mp3"):
			var m := AudioStreamMP3.new()
			m.data = bytes
			s = m
		elif rel.ends_with(".wav"):
			s = AudioStreamWAV.load_from_buffer(bytes)
		elif rel.ends_with(".ogg"):
			s = AudioStreamOggVorbis.load_from_buffer(bytes)
	if not rel.ends_with(".mp3"):      # music is streamed one track at a time; sound effects are reused
		_audio_cache[rel] = s
	return s


func video(rel: String) -> VideoStream:
	var p := ROOT + rel
	if not FileAccess.file_exists(p):
		return null
	var v := VideoStreamTheora.new()
	v.file = p
	return v


## CJK-capable UI font (system Song/Hei fonts on macOS and Windows; a bundled Song font on mobile).
func font() -> Font:
	if _font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["SimSun", "Songti SC", "STSong", "Heiti SC", "PingFang SC"])
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		f.hinting = TextServer.HINTING_NORMAL
		# Songti SC lacks ~130 of the game's characters (珪, 吽, traditional forms …); the first two
		# cover all of them on macOS, the others are Windows' standard Chinese fonts
		var fb: Array[Font] = []
		for n in ["Hiragino Sans GB", "Heiti SC", "Microsoft YaHei", "SimHei"]:
			var g := SystemFont.new()
			g.font_names = PackedStringArray([n])
			g.antialiasing = f.antialiasing
			fb.append(g)
		f.fallbacks = fb
		_font = f
		if OS.has_feature("mobile") or OS.get_environment("WG_BUNDLED_FONT") != "":
			# iOS has no Song face (only PingFang): use the bundled Noto Serif SC cut to the game's characters
			# (tools/subset_font.py), the system fonts above as its fallback
			var nf := FontFile.new()
			if nf.load_dynamic_font(ROOT + "fonts/NotoSerifSC-game.otf") == OK:
				nf.antialiasing = f.antialiasing
				nf.hinting = f.hinting
				nf.fallbacks = [f] as Array[Font]
				_font = nf
	return _font


func clear_cache() -> void:
	_tex_cache.clear()
	_hd_lru.clear()
	_hd_bytes = 0
	_json_cache.clear()
