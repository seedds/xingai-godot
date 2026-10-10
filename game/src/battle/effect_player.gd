class_name EffectPlayer
extends Node2D
## KoeiAnim player for the 6.6 effects (docs/gfx.md §7): Meff.e5 small animations (`xben`, one copy per target
## point, 0x40bcd2 / 0x40196f / 0x401e5d) and the Mcall00-22 full animations (`mcall`, one copy, 0x40eb54 →
## 0x403035). One record per `delay_ms`; frame top-left = point − (W, H)/2 + (dx, dy); records are drawn at the
## converter's `opacity` (= (p3·6 + 4) %, key pixels transparent). Sound `id + 100` (se_m_NN) on frame 0 unless its
## cue is 2, and on every frame with cue 3 (0x41c4ef / 0x403206). A record with cue 1 is the hit frame: `on_hit`
## runs there (0x421ab6 draws the targets' hurt / cheer / defend frames and the numbers). In Game.autoplay nothing
## is drawn and nothing waits; `on_hit` still runs.

signal hit
signal done

var kind := "xben"
var id := 0
var anim: Dictionary = {}
var records: Array = []
var images: Array[Texture2D] = []
var points: Array = []
var size := Vector2(64, 64)
var delay := 0.05
var _cur: Dictionary = {}

static var _index: Dictionary = {}


static func index() -> Dictionary:
	if _index.is_empty():
		_index = Assets.json("gfx/effects/index.json")
	return _index


## The animation record of `k` ("xben", "mcall", "dt") number `n`, {} if missing.
static func anim_of(k: String, n: int) -> Dictionary:
	var anims: Variant = index().get(k, {}).get("anims", {})
	if anims is Dictionary:
		var a: Variant = (anims as Dictionary).get("%02d" % n, (anims as Dictionary).get(str(n), {}))
		return a if a is Dictionary else {}
	return {}


## A player for animation `n` of `k`, or null when the entry does not exist.
static func create(k: String, n: int) -> EffectPlayer:
	var a := anim_of(k, n)
	if a.is_empty() or (a.get("records", []) as Array).is_empty():
		return null
	var e := EffectPlayer.new()
	e.kind = k
	e.id = n
	e.anim = a
	e.records = a.get("records", [])
	e.delay = maxf(float(a.get("delay_ms", 50)) / 1000.0, 0.02)
	var sz: Array = a.get("size", [64, 64])
	e.size = Vector2(int(sz[0]), int(sz[1]))
	if not Game.autoplay:
		for i in int(a.get("images", 0)):
			e.images.append(Assets.tex("gfx/effects/%s/%02d/img_%02d.png" % [k, n, i]))
	return e


## Play animation `n` of `k` centred on each of `pts` (world points) on `layer`; awaits the end. Returns false when
## the entry does not exist (nothing played, `on_hit` not run).
static func play(k: String, n: int, layer: Node, pts: Array, on_hit := Callable()) -> bool:
	var e := create(k, n)
	if e == null:
		return false
	await e.run(layer, pts, on_hit)
	return true


func run(layer: Node, pts: Array, on_hit := Callable()) -> void:
	points = pts
	if Game.autoplay or layer == null or not layer.is_inside_tree():
		for r in records:
			if int(r.get("cue", 0)) == 1:
				hit.emit()
				if on_hit.is_valid():
					on_hit.call()
				break
		done.emit()
		call_deferred("free")   # not `free.call_deferred()`: the exported (binary token) build rejects that form
		return
	layer.add_child(self)
	var snd := int(anim.get("sound", int(anim.get("id", 0)) & 0xff))
	for i in records.size():
		_cur = records[i]
		queue_redraw()
		var cue := int(_cur.get("cue", 0))
		if (i == 0 and cue != 2) or cue == 3:
			Audio.play_se(SoundMap.se_name(snd + 100))
		if cue == 1:
			hit.emit()
			if on_hit.is_valid():
				on_hit.call()
		await get_tree().create_timer(delay).timeout
	_cur = {}
	done.emit()
	queue_free()


func _draw() -> void:
	if _cur.is_empty():
		return
	var k := int(_cur.get("image", 0))
	if k < 0 or k >= images.size() or images[k] == null:
		return
	var t := images[k]
	var off := Vector2(int(_cur.get("dx", 0)), int(_cur.get("dy", 0))) - size / 2
	var col := Color(1, 1, 1, clampf(float(_cur.get("opacity", 1.0)), 0.0, 1.0))
	for p in points:
		draw_texture(t, (p as Vector2) + off, col)
