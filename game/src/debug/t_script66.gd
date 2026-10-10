extends Node
## Script-side checks of the 6.6 port: text expansion 0x417df6, speaker lookup 0x44deef, op 0x77 width rule,
## op 0x79 compares, keyed lists. Prints "t_script66: PASS" / FAIL lines.

var ok := true


func check(name: String, got: Variant, want: Variant) -> void:
	if str(got) != str(want):
		ok = false
		print("FAIL %s: got %s want %s" % [name, got, want])


func run() -> void:
	var t0 := Time.get_ticks_msec()
	check("speaker 董卓", TextExpand.speaker_of("董卓"), TextExpand.person_by_name("董卓"))
	print("lookup ms ", Time.get_ticks_msec() - t0)
	Mem.set_ev(7, 1234)
	check("*/7", TextExpand.expand("值*/7。"), "值1234。")
	check("stop at \\n&", TextExpand.expand("甲乙\n&丙"), "甲乙")
	check("*.0", TextExpand.expand("*.0来了"), TextExpand.display_name(0) + "来了")
	Mem.set_ev(4071, 1)
	check("*/ in history mode", TextExpand.expand("*/7"), "*/7")
	Mem.set_ev(4071, 0)
	# op 0x77 width: EV[4076] = 1 → byte stores keep the upper bytes
	var h := ScriptHost.new()
	Mem.set_ev(10, 0x12345678)
	Mem.set_ev(4076, 1)
	ScriptHost._store(Mem.EV + 40, 0xff + 2, 0, 0, 2)
	check("byte add wraps", "%x" % Mem.ev(10), "12345679")
	Mem.set_ev(4076, 2)
	ScriptHost._store(Mem.EV + 40, 0x10000, 2, 0, 2)
	check("word store", "%x" % Mem.ev(10), "12340000")
	Mem.set_ev(4076, 0)
	check("test value kind 4", ScriptHost._test_value(4, 10), Mem.ev(10))
	h.free()
	print("t_script66: %s" % ("PASS" if ok else "FAIL"))
