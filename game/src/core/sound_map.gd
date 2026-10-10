class_name SoundMap
extends RefCounted
## Script audio (the parser's op names are swapped relative to the behaviour):
##   op 0x24 "play_sound" → BGM (0x4157fa): id 0xff → GS+4 (current track, 0x418c99) = 0xff and the music stops (0x417740); else
##        0x4745a7(id + 2): tracks < 0xff play `SoundTrk\NN-AudioTrack NN.mp3` (not restarted when already playing),
##        larger ones do nothing. Files: assets/audio/bgm/NN.mp3.
##   op 0x23 "play_music" → sound effect (0x4157b9 → 0x474a44): mode 0 loop (0x4746ca), 0xff stop (0x474652), 1 once
##        (0x46d0b7), other n → 0x474777(id, n). File `WAV\` + format[id / 100] % (id % 100) (table 0x474878):
##        SE%02u, SE_M_%02u, SE_E_%02u; a missing file plays nothing. 0x474777 plays nothing while a looping effect
##        is active (wave object 0x4b69b0 +4, set by 0x4746ca, cleared by the stop) and for ids with low byte 0xff.
##   click voices (0x40904c): `WAV\SE_V_%03u.WAV`.

static var _loop_player: AudioStreamPlayer
static var loop_active := false


static func play_bgm_id(id: int) -> void:
	if id == 0xff:
		Mem.w8(Mem.GS + 4, 0xff)
		Audio.stop_bgm()
		return
	var track := id + 2
	if track >= 0xff:
		return
	Mem.w8(Mem.GS + 4, track)
	Audio.play_bgm(track, true)


static func se_name(id: int) -> String:
	if id >= 300:
		return "none"     # past the 3-entry format table 0x474878
	var fmt: String = ["se%02d", "se_m_%02d", "se_e_%02d"][id / 100]
	return fmt % (id % 100)


static func voice_name(v: int) -> String:
	return "se_v_%03d" % v


static func play_se_id(id: int, mode: int) -> void:
	if mode == 0xff:
		stop_loop()
		return
	if loop_active or (id & 0xff) == 0xff:
		return
	var s := Assets.audio("audio/se/%s.wav" % se_name(id))
	if s == null:
		return
	if mode == 0:
		if _loop_player == null:
			_loop_player = AudioStreamPlayer.new()
			_loop_player.volume_db = Audio.se_volume_db
			Audio.add_child(_loop_player)
		if s is AudioStreamWAV:
			var w := (s as AudioStreamWAV).duplicate() as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			# the mixer plays the frame at loop_end too: the last one (one past it is outside the sample data, a read
			# that crashed the Android build when the loop came round)
			w.loop_end = roundi(w.get_length() * w.mix_rate) - 1
			s = w
		_loop_player.stream = s
		_loop_player.play()
		loop_active = true
		return
	if mode == 1 or Game.autoplay:
		Audio.play_se(se_name(id))
		return
	# n ≥ 2: played n times, the script waiting for each
	var tree := Audio.get_tree()
	for k in mini(mode, 50):
		Audio.play_se(se_name(id))
		await tree.create_timer(maxf(s.get_length(), 0.05)).timeout


static func play_voice(v: int) -> void:
	if loop_active:
		return
	Audio.play_se(voice_name(v))


static func stop_loop() -> void:
	loop_active = false
	if _loop_player:
		_loop_player.stop()
