class_name VideoLayer
extends Control
## Full-screen cutscene player (converted WMV -> OGV). Click / Enter / Esc skips.

signal done

var _player: VideoStreamPlayer
var _gen := 0


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_player = VideoStreamPlayer.new()
	_player.expand = true
	_player.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_player)
	_player.finished.connect(_on_finished)
	visible = false


## name: e.g. "pre", "end", "001"
func play(name: String) -> void:
	var v := Assets.video("video/%s.ogv" % name.to_lower())
	if v == null or Game.autoplay:
		return
	var prev_track := Audio.current_track
	Audio.bgm_player.stream_paused = true
	_player.stream = v
	visible = true
	_fit()
	_player.play()
	_gen += 1
	_check_started(_gen)
	await done
	_player.stop()
	visible = false
	Audio.bgm_player.stream_paused = false


## A video that cannot be decoded never plays and never finishes: give up on it after a few frames.
func _check_started(gen: int) -> void:
	for k in 15:
		await get_tree().process_frame
	if gen == _gen and visible and not _player.is_playing():
		push_warning("video did not start")
		done.emit()


func _fit() -> void:
	var vs := get_viewport_rect().size
	var tex := _player.get_video_texture()
	var aspect := 16.0 / 9.0
	if tex and tex.get_height() > 0:
		aspect = float(tex.get_width()) / tex.get_height()
	var w := vs.x
	var h := w / aspect
	if h > vs.y:
		h = vs.y
		w = h * aspect
	_player.position = (vs - Vector2(w, h)) / 2
	_player.size = Vector2(w, h)


func _process(_d: float) -> void:
	if visible:
		_fit()


func _on_finished() -> void:
	done.emit()


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed:
		done.emit()
		accept_event()


func _unhandled_input(ev: InputEvent) -> void:
	if visible and (ev.is_action_pressed("ui_accept") or ev.is_action_pressed("ui_cancel")):
		done.emit()
		get_viewport().set_input_as_handled()
