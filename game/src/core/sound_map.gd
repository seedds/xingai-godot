class_name SoundMap
extends RefCounted
## Script audio. NOTE the parser's op names are swapped relative to behaviour:
##   op 0x24 "play_sound" → BGM: CD track = id + 2 (0x41581c → 0x4745fe on the CD player 0x4b69b8);
##                           255 stops the music. Tracks map to assets/audio/bgm/NN.mp3.
##   op 0x23 "play_music" → sound effect (0x4157b4 → 0x474a07 on the wave player 0x4b69b0):
##        id 0..99 → SeNN.wav, 100..199 → Se_m_(id-100).wav, 200.. → Se_e_(id-200).wav
##        mode 1 = play once, 0 = loop (ambient), 255 = stop.

static var _loop_player: AudioStreamPlayer


static func play_bgm_id(id: int) -> void:
	if id == 255 or id == 0xffff:
		Audio.stop_bgm()
		return
	Audio.play_bgm(id + 2, true)


static func se_name(id: int) -> String:
	if id >= 200:
		return "se_e_%02d" % (id - 200)
	if id >= 100:
		return "se_m_%02d" % (id - 100)
	return "se%02d" % id


static func play_se_id(id: int, mode: int) -> void:
	if mode == 255:
		stop_loop()
		return
	if mode == 0:
		stop_loop()
		var s := Assets.audio("audio/se/%s.wav" % se_name(id))
		if s == null:
			return
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
		return
	Audio.play_se(se_name(id))


static func stop_loop() -> void:
	if _loop_player:
		_loop_player.stop()
