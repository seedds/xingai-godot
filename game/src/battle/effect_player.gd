class_name EffectPlayer
extends Node2D
## Plays a KoeiAnim effect (Xben small effects / MCALL full-screen strategy animations).
## Records are shown one per delay tick; blending approximated with alpha = strength/16.

var frames: Array = []
var images: Array[Texture2D] = []
var delay := 0.05
var _i := 0
var _t := 0.0
var _cur: Dictionary = {}
signal done

static var _index: Dictionary = {}


static func index() -> Dictionary:
	if _index.is_empty():
		_index = Assets.json("gfx/effects/index.json")
	return _index


## kind "xben" or "mcall", id = animation number. Returns null if missing.
static func create(kind: String, id: int) -> EffectPlayer:
	var idx: Dictionary = index().get(kind, {})
	var anims: Variant = idx.get("anims", {})
	var a: Dictionary = {}
	if anims is Dictionary:
		a = (anims as Dictionary).get(str(id), (anims as Dictionary).get("%02d" % id, {}))
	elif anims is Array:
		for x in anims:
			if int(x.get("id", -1)) == id:
				a = x
				break
	if a.is_empty() or (a.get("records", []) as Array).is_empty():
		return null
	var e := EffectPlayer.new()
	e.delay = maxf(float(a.get("delay_ms", 50)) / 1000.0, 0.02)
	e.frames = a.get("records", [])
	for k in int(a.get("images", 0)):
		e.images.append(Assets.tex("gfx/effects/%s/%02d/img_%02d.png" % [kind, id, k]))
	return e


func _ready() -> void:
	# start on the next frame so callers can `await done` right after add_child()
	_show.call_deferred(0)


func _show(i: int) -> void:
	_i = i
	if i >= frames.size():
		done.emit()
		queue_free()
		return
	_cur = frames[i]
	queue_redraw()


func _process(d: float) -> void:
	_t += d
	while _t >= delay:
		_t -= delay
		_show(_i + 1)
		if _i >= frames.size():
			return


func _draw() -> void:
	if _cur.is_empty():
		return
	var k := int(_cur.get("image", 0))
	if k < 0 or k >= images.size() or images[k] == null:
		return
	var t := images[k]
	var a := clampf(float(_cur.get("p3", 16)) / 16.0, 0.15, 1.0)
	draw_texture(t, -t.get_size() / 2, Color(1, 1, 1, a))
