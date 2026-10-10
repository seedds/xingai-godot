extends Node
## BGM (original CD-audio tracks, replaced by numbered MP3s) and sound effects.

var bgm_player: AudioStreamPlayer
var _se_players: Array[AudioStreamPlayer] = []
var current_track := -1
var bgm_volume_db := -4.0
var se_volume_db := -2.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	bgm_player = AudioStreamPlayer.new()
	bgm_player.volume_db = bgm_volume_db
	add_child(bgm_player)
	for i in 6:
		var p := AudioStreamPlayer.new()
		p.volume_db = se_volume_db
		add_child(p)
		_se_players.append(p)


## Play CD track n (the game's track numbering; files are assets/audio/bgm/NN.mp3).
func play_bgm(track: int, loop := true) -> void:
	if track == current_track and bgm_player.playing:
		return
	current_track = track
	var s := Assets.audio("audio/bgm/%02d.mp3" % track)
	if s == null:
		bgm_player.stop()
		return
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = loop
	bgm_player.stream = s
	bgm_player.play()


func stop_bgm() -> void:
	current_track = -1
	bgm_player.stop()


## name like "se00", "se_m_12", "se_e_03".
func play_se(name: String) -> void:
	var s := Assets.audio("audio/se/%s.wav" % name.to_lower())
	if s == null:
		return
	for p in _se_players:
		if not p.playing:
			p.stream = s
			p.play()
			return
	_se_players[0].stream = s
	_se_players[0].play()


func se(n: int) -> void:
	play_se("se%02d" % n)


func se_m(n: int) -> void:
	play_se("se_m_%02d" % n)


func se_e(n: int) -> void:
	play_se("se_e_%02d" % n)
