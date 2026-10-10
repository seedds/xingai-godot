extends Node
## 环境设定 dialog (Kankyou66) as opened from the title's 沙場點兵: 确定 (0x41b914) writes the check boxes and radio
## groups into GS+0..2 and the window pattern into 0x500fa0. Runs with Game.autoplay on, so the SV\SV.E5S record of
## the player is not written. Prints "t_kankyou: PASS" or FAIL lines.

var ok := true


func check(name: String, got: Variant, want: Variant) -> void:
	if str(got) != str(want):
		ok = false
		print("FAIL %s: got %s want %s" % [name, got, want])


func run() -> void:
	Game.new_game_state()
	Game.autoplay = true
	var d := Kankyou66.new()
	d.build()
	add_child(d)
	check("bits from GS+0", d.bits, Mem.r8(Mem.GS) & 0xff)
	d.bits ^= 1                    # 听背景音乐 off
	d.radio = [2, 0]               # 讯息显示速度 慢, 武将移动速度 快
	d._apply()
	check("GS+0 bit 0", Mem.r8(Mem.GS) & 1, d.bits & 1)
	check("GS+1", Mem.r8(Mem.GS + 1), 2)
	check("GS+2", Mem.r8(Mem.GS + 2), 0)
	Audio.bgm_player.stream_paused = false
	d.queue_free()
	print("t_kankyou: %s" % ("PASS" if ok else "FAIL"))
