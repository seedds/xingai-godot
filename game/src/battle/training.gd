class_name Training
extends Control
## 练武场 (docs/duel.md §2–§3): the modal dialog 330 (proc 0x4207b2) in which two fighters — the player-side unit U0
## (slot 0, 0x4a7b20) and the opponent U60 (slot 60, 0x4a8660) — fight up to 10 rounds on a fake 4×1 map.
##   * 普通模式 (EV 4087 = 1): the normal battle routines (攻击 / 策略 / 道具, then the opponent's AI turn).
##   * 单挑模式 (EV 4087 = 2): the command duel 攻击 / 突击 / 防御 / 回避 with persistent duel data in person 1023.
## Entry points: op 0x68 with byte EV 4087 ≠ 0 (TrainStart 0x41e6a4) → `script_fight`; the menu 功能→练武场
## (0x474e0e → 0x423842) → `menu`. The result goes to EV 4084: 0 lost, 1 won, 2 draw (duel.md §0; the mod's
## variable notes have 0/2 the other way round).
##
## Memory as in the original: DC = 0x500ae0 (+0 A person ptr, +4 B person ptr, +8 arg (landscape U_select[5+arg]),
## +9 opponent level (menu), +0xa round, +0xb started, +0x10 mode, +0x11 [0x500d8f] script/item flag, +0x1c P1023);
## U0 / U60 backed up to 0x500b10 / 0x500b40 and restored at the end; the fake map 0x40ada3 / 0x41d27a.
## The person records are NOT restored: EXP and level-ups of 普通模式 stay (as in the original).
##
## Not ported from the battle engine (the battle track's executors were stubs when this was written) [G]:
## the opponent's AIAct 0x43ad3b is reduced to "attack U0 if it is in range"; the exchange 0x4064f1 runs CalcDamage,
## the critical, the second strike, the counter and PhysEXP (Rules) but not the on-hit skill effects of 0x405966 /
## 0x406b3c (status attacks, reflect, 吸血 …), weapon/armour EXP or the battle animation 0x4526e7 (a short ATK-frame
## animation is drawn instead). 策略 / 道具 run through `cast_hook` / `item_hook` when the battle track sets them;
## without them those buttons stay disabled.

signal closed

const DC := 0x500ae0
const U0 := 0x4a7b20
const U60 := 0x4a8660
const BACKUP0 := 0x500b10
const BACKUP60 := 0x500b40
const START_FLAG := 0x500d8f          # "started by script/item"
const SCENE_MODE := 0x4ac63c          # screen mode byte (3 = battle)
const FONT_PX := 12                   # 宋体 9 pt
const DLU := 1.5                      # dialog unit → pixel (the template's 250×151 DLU dialog; groups 96 DLU = 144 px)
const TICK := 0.05

## Battle-track hooks (callables taking the dialog): 策略 = SelectStrategy 0x4664df + CastStrategy 0x41c0e8 on U0,
## 道具 = SelectItem 0x41e13d + UseItem 0x420271; each returns true when an action was performed. `can_*` tell
## whether the button is enabled (0x43e023 / 0x408e96).
static var cast_hook: Callable
static var item_hook: Callable
static var can_cast_hook: Callable
static var can_item_hook: Callable
## The opponent's turn in 普通模式 (AIAct 0x43ad3b(U60) with the training strategy table MgAIYN2 0x4d1690).
static var ai_hook: Callable

var host: ScriptHost
var mode := 1                         # DC+0x10
var scripted := 1                     # DC+0x11
var win_rect := Rect2()
var client := Vector2(381, 341)
var enabled := {}                     # button id → bool
var _buttons := {}                    # id → [Rect2 (client), text]
var _hover := -1
var _idle := 0                        # idle frame toggle (0x43a51a / byte 0x4ce24c)
var _idle_t := 0.0
var _idle_on := false
var _pressed := -1
var _done := false
var _anim := {}                       # slot → {sheet, idx, mirror, dx, flash, hidden}
var _numbers: Array = []              # [slot, text, colour, until_ms]
var _say := []                        # [slot, text]
var _msg := ""                        # modal message box (0x42f699 owned by the dialog)
var _yesno := false
var _msg_answer := -1
var _tex := {}


# ================================================================== entry points
## op 0x68 with byte EV 4087 ≠ 0 — TrainStart 0x41e6a4(A, B, c): [0x500d8f] += 1, screen mode 1 → battle (0x41de7e),
## then TrainDlgOpen(DC, A, B, arg = c, level 0).
static func script_fight(h: ScriptHost, a: int, b: int, c: int) -> void:
	Mem.w8(START_FLAG, Mem.r8(START_FLAG) + 1)
	_scene_mode_push()
	await _open(h, a, b, c, 0)


## Menu 功能 → 练武场 (0x474e0e): choice box (0x42de7d with person 0x3fe), then 0x423842(choice); afterwards
## EV 4087 = 0, screen mode 2, redraw (0x40dff9). Only enabled outside a battle (0x4759bc).
static func menu(h: ScriptHost) -> void:
	if h.in_battle():
		return
	var opts := ["普通模式", "单挑模式", "自动提升", "取消"]     # 0x500c78
	var i := 0
	if Game.autoplay:
		i = 0
	elif h.ui and h.ui.menu:
		i = await h.ui.menu.choose(opts, Vector2(-1, -1), false)
	var c := i + 1
	if c < 3:
		Mem.w8(Mem.EV + 4 * 4087, c)
	if c != 4:
		await _menu_run(h, c)
	Mem.w8(SCENE_MODE, 2)
	Mem.set_ev(4087, 0)


## 0x423842(choice)
static func _menu_run(h: ScriptHost, c: int) -> void:
	if c == 2:
		# 单挑模式: the first party member by id (0x4184b0) against person 1022, level 0 (duel level based cost)
		var first := -1
		for pid in 1024:
			if _member(pid):
				first = pid
				break
		if first >= 0:
			await _menu_fight(h, first, 0)
		return
	while true:
		var avg := party_average()
		var lst := _below_average(avg)                    # 0x4222ab(0x4b5ee0)
		if lst.is_empty():
			break
		if c != 1:
			# 自动提升: avg·1000 gold, then 0x406cfa
			if not await _pay(h, avg * 1000):
				return
			party_to_average()
			await _message(h, "全队等级提升")
			return
		var names := []
		for pid in lst:
			var p := Game.person(pid)
			names.append("%s  Lv%d" % [p.name if p else str(pid), Mem.r8(Mem.person_addr(pid) + 0x2c)])
		var k := 0
		if not Game.autoplay:
			k = await h.ui.menu.choose(names, Vector2(-1, -1), true, "练武场")     # [G] 选择武将 dialog 0x45e6b3
		if k < 0:
			return
		if not await _menu_fight(h, lst[k], avg):
			return
	await _message(h, "目前无需练武了")


## 0x41ecae(P, x): PayTraining, then TrainDlgOpen(DC, P, person 1022, arg 1, level x).
static func _menu_fight(h: ScriptHost, pid: int, x: int) -> bool:
	if not await _pay_training(h, pid, x):
		return false
	await _open(h, pid, 0x3fe, 1, x)
	return true


## PayTraining 0x4237f9: x = 0 (单挑模式): nothing more to learn once P1023+0x19 ≥ 5, cost = duel level·20; else
## cost = level(P)·10. 0x423820: "资金不足" if gold is short, else "支付%d金？" (yes: SE 10, gold −= cost, screen mode 3).
static func _pay_training(h: ScriptHost, pid: int, x: int) -> bool:
	var cost := 0
	if x == 0:
		var d := _p1023()
		if Mem.r8(0x510cf8) != 0 and Mem.r8(d + 0x19) >= 5:
			await _message(h, "目前无需练武了")
			return false
		var v := 1 if Mem.r8(0x510cf8) == 0 else Mem.r8(d + 0x17)
		cost = v * 2 * 10
	else:
		cost = Mem.r8(Mem.person_addr(pid) + 0x2c) * 10
	return await _pay(h, cost)


static func _pay(h: ScriptHost, cost: int) -> bool:
	if Mem.r32(Mem.GS + 0xc) < cost:
		await _message(h, "资金不足")
		return false
	var ok := true
	if not Game.autoplay:
		ok = await _ask(h, "支付%d金？" % cost)
	if not ok:
		return false
	if not Game.autoplay:
		Audio.se(10)
	Mem.w32(Mem.GS + 0xc, Mem.r32(Mem.GS + 0xc) - cost)
	Mem.w8(SCENE_MODE, 3)
	return true


## TrainDlgOpen 0x418f05: fill DC and run the modal dialog.
static func _open(h: ScriptHost, a: int, b: int, arg: int, x: int) -> void:
	Mem.w32(DC, Mem.person_addr(a))
	Mem.w32(DC + 4, Mem.person_addr(b))
	Mem.w8(DC + 8, arg & 0xff)
	Mem.w32(DC + 9, x)
	Mem.w8(DC + 0xa, 1)
	Mem.w8(DC + 0xb, 0)
	Mem.w32(DC + 0x1c, _p1023())
	Mem.w8(DC + 0x10, Mem.r8(Mem.EV + 4 * 4087))
	Mem.w8(DC + 0x11, Mem.r8(START_FLAG))
	var t := Training.new()
	t.host = h
	h.ui.add_child(t)
	await t._run()
	t.queue_free()


# ================================================================== helpers (memory)
static func _p1023() -> int:
	return Mem.r32(Mem.LAST_PERSON_PTR)


static func _member(pid: int) -> bool:
	return Mem.r8(Mem.person_addr(pid) + 0x2a) != 0xff


## PartyAverageLevel 0x40c231: Σ level / count over persons 0..126 that are members; at least 1.
static func party_average() -> int:
	var s := 0
	var n := 0
	for pid in 127:
		if _member(pid):
			s += Mem.r8(Mem.person_addr(pid) + 0x2c)
			n += 1
	if n == 0:
		return 1
	return maxi(s / n, 1)


## 0x4222ab: members (persons 0..1023) whose level is below the average.
static func _below_average(avg: int) -> Array:
	var out := []
	for pid in 1024:
		if _member(pid) and Mem.r8(Mem.person_addr(pid) + 0x2c) < avg:
			out.append(pid)
	return out


## 0x406cfa: repeat { avg; every member 0..126 below it levels up silently by the difference } until stable.
static func party_to_average() -> void:
	var raised := true
	while raised:
		raised = false
		var avg := party_average()
		for pid in 127:
			if _member(pid):
				var lv := Mem.r8(Mem.person_addr(pid) + 0x2c)
				if lv < avg:
					Game.person(pid).level_up(avg - lv)
					raised = true


## 0x41de7e(&0x4ac63c, 1): P1023+0x1a = screen mode, screen mode = 3; (…, 0) restores it.
static func _scene_mode_push() -> void:
	Mem.w8(_p1023() + 0x1a, Mem.r8(SCENE_MODE))
	Mem.w8(SCENE_MODE, 3)


static func _scene_mode_pop() -> void:
	Mem.w8(SCENE_MODE, Mem.r8(_p1023() + 0x1a))


static func _message(h: ScriptHost, text: String) -> void:
	if Game.autoplay:
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [练武场] ", text)
		return
	var t := Training.new()
	t.host = h
	t.client = Vector2.ZERO
	h.ui.add_child(t)
	await t._show_msg(text, false)
	t.queue_free()


static func _ask(h: ScriptHost, text: String) -> bool:
	var t := Training.new()
	t.host = h
	t.client = Vector2.ZERO
	h.ui.add_child(t)
	var r := await t._show_msg(text, true)
	t.queue_free()
	return r


func _uhp(u: int) -> int:
	return Mem.r32(u + 0x10)


func _usp(u: int) -> int:
	return Mem.r32(u + 0x14)


func _ux(u: int) -> int:
	return Mem.r8(u + 0x21)


func _slot(u: int) -> int:
	return 0 if u == U0 else 60


func _pid(u: int) -> int:
	return Mem.r32(u) & 0xfff


func _person_addr(u: int) -> int:
	return Mem.person_addr(_pid(u))


## Stand-in for the battle stage that Rules / Effects query (Effects.battle) when the fight runs outside a battle:
## the original's training sets the screen mode to 3 (a battle, 0x41de7e), so the battle code sees the global unit
## array as usual. unit_of_person = 0x477adc with EV 4087 ≠ 0 (slot 0, then 60..249).
class Field:
	extends RefCounted
	var units: Array = []

	func _init() -> void:
		for s in Mem.UNIT_SLOTS:
			units.append(BUnit.at(s))

	func unit_of_person(pid: int) -> BUnit:
		var s := 0
		while s < Mem.UNIT_SLOTS:
			var a := Mem.unit_addr(s)
			if Mem.r8(a + 0xc) != 0 and (Mem.r16(a) & 0xfff) == pid:
				return units[s]
			s = 60 if s == 0 else s + 1
		return null

	func unit_at(c: Vector2i) -> BUnit:
		var s := Rules.slot_at(c)
		return null if s == 0xff else units[s]


var _field := false


# ================================================================== the dialog
func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _run() -> void:
	mode = Mem.r8(DC + 0x10)
	scripted = Mem.r8(DC + 0x11)
	if Effects.battle == null:
		Effects.battle = Field.new()
		_field = true
	_init_dialog()
	queue_redraw()
	while not _done:
		await _wait_command()
	_destroy()


## WM_INITDIALOG (0x4207b2 msg 0x110).
func _init_dialog() -> void:
	# back up U0 / U60 (0x40762f)
	Mem.copy(BACKUP0, U0, 0x30)
	Mem.copy(BACKUP60, U60, 0x30)
	_fake_map()
	# (mode ≠ 2 and menu fight: Data.e5 reloaded into the buffer 0x48b100 for 0x45362b — Game.reset_person reads
	# the converted data directly)
	_setup_fighters()        # 0x42b6b7
	_idle_on = true          # SetTimer 0x6e, 300 ms, 0x43a51a
	for id in [0x507, 0x508, 0x509, 0x50a, 0x50b]:
		enabled[id] = id == 0x507
	_layout()                # 0x452fba


## 0x40ada3: unit grid row (2,0) = U60, (3,0) = U0; terrain of (2,0),(3,0) = 0xff; map 4×1; view origin 0.
func _fake_map() -> void:
	var m := Mem.MAP_BUF
	Mem.w32(DC + 0xc, Mem.r32(m + 0xc80))
	Mem.w32(m + 0xc80, 0x003cffff)
	Mem.w16(DC + 0x1a, Mem.r16(m + 0x642))
	Mem.w16(m + 0x642, 0xffff)
	Mem.w16(DC + 0x12, Mem.r16(Mem.MAP_WH))
	Mem.w16(Mem.MAP_WH, 0x0104)
	Mem.w8(0x500cb0, 1)
	var d := _p1023()
	Mem.w32(d + 0x1b, Mem.r32(0x4b4254))
	Mem.w32(d + 0x1f, Mem.r32(0x4b4258))
	Mem.w32(0x4b4254, 0)
	Mem.w32(0x4b4258, 0)
	Mem.w8(0x4b4290, 0x38)
	Mem.w32(0x4b42a4, 0xffff)
	Mem.w8(0x500c44, 2)
	Mem.w8(0x500e9a, Mem.r8(0x500e9a) + 1)


## WM_DESTROY: timer off; 0x41d27a restores U0/U60, the map cells, size and view, clears DC +0..+0x1f, [0x500c44],
## [0x500e9a] and restores the screen mode; then 0x42a214.
func _destroy() -> void:
	_idle_on = false
	Mem.copy(U0, BACKUP0, 0x30)
	Mem.copy(U60, BACKUP60, 0x30)
	var m := Mem.MAP_BUF
	Mem.w32(m + 0xc80, Mem.r32(DC + 0xc))
	Mem.w16(m + 0x642, Mem.r16(DC + 0x1a))
	Mem.w16(Mem.MAP_WH, Mem.r16(DC + 0x12))
	var d := _p1023()
	Mem.w32(0x4b4254, Mem.r32(d + 0x1b))
	Mem.w32(0x4b4258, Mem.r32(d + 0x1f))
	Mem.fill(DC, 0x20, 0)
	Mem.w8(0x500c44, 0)
	Mem.w8(0x500e9a, 0)
	_scene_mode_pop()
	# 0x42a214
	Mem.w8(0x494698, 0)
	Mem.w8(0x4ae4f8, 0)
	Mem.w8(0x500cb0, 0)
	if Mem.r8(START_FLAG) != 0:
		Mem.set_ev(4087, 0)
		Mem.w8(START_FLAG, 0)
	Mem.set_ev(4086, 0)
	Mem.w32(0x49476c, 0xffffffff)
	Mem.w8(0x494728, 1)
	Mem.set_ev(4085, 5)
	if _field:
		Effects.battle = null
		_field = false
	closed.emit()


## 0x42b6b7: U0 at picture x 240 (y 56); fighters (0x436dd1); mode ≠ 2 → buttons 策略 / 道具; picture; panels.
func _setup_fighters() -> void:
	Mem.w16(U0 + 0x21, 0x38f0)
	_init_fighters()


## 0x436dd1 = InitFighter(U0, A) + SetupEnemy.
func _init_fighters() -> void:
	_init_fighter(U0, Mem.r32(DC))
	_setup_enemy()


## InitFighter 0x436f52(unit, person, mode).
func _init_fighter(u: int, paddr: int) -> void:
	var pid := Mem.r16(paddr) & 0xfff
	Mem.w32(u, pid)
	if mode == 2:
		var d := _p1023()
		var hp := 0
		if u == U0:
			if Mem.r8(0x510cf8) == 0:
				Mem.w8(0x510cf8, 1)
				Mem.w8(d + 0x19, 0)
				Mem.w32(d + 0x15, 0x00010505)    # HP 5, +0x16 5, duel level 1, wins 0
				Mem.w32(d + 0x11, 0x0f553232)    # q0..q3 = 50, 50, 85, 15
			hp = Mem.r8(d + 0x15)
		else:
			Mem.w32(d + 0x38, Mem.ev(4086))      # r0..r3
			Mem.w16(d + 0x3c, 0x500 | (Mem.ev(4085) & 0xff))
			hp = Mem.ev(4085) & 0xff
		Mem.w32(u + 0x10, hp)
		Mem.w32(u + 0x14, 1)
	else:
		var p := Game.person(pid)
		Mem.w32(u + 0x10, p.max_hp() if p else 1)     # 0x407263
		Mem.w32(u + 0x14, p.max_mp() if p else 0)     # 0x40728f
		for k in 6:
			Mem.w8(u + 0x18 + k, 3)


## SetupEnemy 0x436fef: a menu fight builds the opponent (person 1022): 单挑模式 a random class, 普通模式 0x45362b
## (random class at the average level); unit records U0 / U60 per duel.md §3.2.
func _setup_enemy() -> void:
	var b := Mem.r32(DC + 4)
	var bid := Mem.r16(b) & 0xfff
	if scripted == 0:
		if mode == 2:
			Mem.w8(b + 0x2b, _random_class())
		else:
			_random_opponent(bid, Mem.r8(DC + 9))
	Mem.w16(U60 + 0x21, 0x3800)
	_init_fighter(U60, b)
	Mem.w32(U0 + 4, 0x30000 if mode == 1 else 0x40000)       # slot 0, colour 0, x 3 (4), y 0
	Mem.w32(U0 + 0xc, 0x03070002)                              # state 2, flags 0, AI 7, facing 3
	Mem.w32(U60 + 4, 0x2023c if mode == 1 else 0x1023c)       # slot 60, colour 2, x 2 (1), y 0
	Mem.w32(U60 + 0xc, 0x01020002)                             # state 2, flags 0, AI 2 (hold), facing 1
	Mem.w32(U60 + 8, 0xff)


## rand(26): r < 13 → class 3r (a three-tier family), else r + 26.
static func _random_class() -> int:
	var r := Rules.rand(26)
	return r * 3 if r < 13 else r + 26


## 0x45362b(P, L): reset P from Data.e5, random class (+ tier 1 at L ≥ 20, 2 at L ≥ 40 for classes < 38), level 0,
## LevelUp(L) silently, default weapon and armour (0x407fd4).
func _random_opponent(pid: int, lv: int) -> void:
	Game.reset_person(pid)
	var c := _random_class()
	if c < 38:
		c += 2 if lv >= 40 else (1 if lv >= 20 else 0)
	var p := Game.person(pid)
	Mem.w8(p.base + 0x2c, 0)
	Mem.w8(p.base + 0x2b, c)
	p.level_up(lv)
	p.default_equip(0)
	p.default_equip(1)


## 0x452fba: client 381×250 (mode 2) / 381×341, picture (2,2) 294×150, buttons.
func _layout() -> void:
	_buttons.clear()
	if mode == 2:
		client = Vector2(381, 250)
		_buttons[0x507] = [_dlu_rect(199, 19, 49, 14), "攻击" if Mem.r8(DC + 0xb) else "开始"]
		_buttons[0x50a] = [_dlu_rect(200, 46, 49, 14), "突击"]
		_buttons[0x508] = [_dlu_rect(199, 75, 49, 14), "防御"]
		_buttons[0x509] = [_dlu_rect(199, 105, 49, 14), "回避"]
		_buttons[0x50b] = [_dlu_rect(199, 134, 49, 14), "逃跑"]
	else:
		client = Vector2(381, 341)
		var ids := [0x507, 0x508, 0x509, 0x50b]
		var texts := ["攻击" if Mem.r8(DC + 0xb) else "开始", "策略", "道具", "逃跑"]
		for i in 4:
			_buttons[ids[i]] = [Rect2(300, 127 + 54 * i, 72, 22), texts[i]]
	# window: client plus a 3 px frame and a 19 px caption, centred on the 640×480 screen (0x423c6e)
	var w := client + Vector2(6, 25)
	win_rect = Rect2(((Vector2(640, 480) - w) / 2).floor(), w)


static func _dlu_rect(x: int, y: int, w: int, h: int) -> Rect2:
	return Rect2(floorf(x * DLU), floorf(y * DLU), floorf(w * DLU), floorf(h * DLU))


func _client_origin() -> Vector2:
	return win_rect.position + Vector2(3, 22)


# ================================================================== commands (WM_COMMAND 0x45321a)
func _wait_command() -> void:
	_pressed = -1
	queue_redraw()
	if Game.autoplay or Game.demo:
		if Game.demo:
			await get_tree().create_timer(0.8).timeout
		else:
			await get_tree().process_frame
		_pressed = _auto_choice()
	else:
		while _pressed < 0 and is_inside_tree():
			await get_tree().process_frame
	if _pressed >= 0:
		await _command(_pressed)


## [G] autoplay policy: 开始 / 攻击 in 普通模式; a random enabled command in 单挑模式.
func _auto_choice() -> int:
	if mode != 2 or Mem.r8(DC + 0xb) == 0:
		return 0x507
	var c := [0x507, 0x508, 0x509]
	if enabled.get(0x50a, false):
		c.append(0x50a)
	return c[Rules.rand(c.size())]


func _command(id: int) -> void:
	if id < 0x507:
		return
	for i in 5:
		enabled[0x507 + i] = false
	var k := id - 0x505
	if k == 6:                                  # 逃跑
		Mem.set_ev(4084, 0)
		_done = true
		return
	var acted := true
	if k == 2:
		if Mem.r8(DC + 0xb) == 0:               # the first press is 开始
			Mem.w8(DC + 0xb, 1)
			_buttons[0x507][1] = "攻击"
			_idle_on = false
			if mode == 2:
				await _walk(0x30, 0xc0)
			else:
				await _walk(0x60, 0x90)
			_enable()
			return
		if mode != 2:
			_idle_on = false
			await _exchange(U0, U60)
		else:
			await _duel_cmd(1)
	elif k == 3:
		if mode != 2:
			acted = await _hook(cast_hook)
		else:
			await _duel_cmd(3)
	elif k == 4:
		if mode != 2:
			acted = await _hook(item_hook)
		else:
			await _duel_cmd(4)
	elif k == 5:
		await _duel_cmd(2)
	if not acted:
		_enable()
		return
	# the opponent's turn (its ailments are wiped every round)
	Mem.w8(U60 + 0x1e, 0)
	if _uhp(U60) > 0 and mode != 2:
		Mem.w8(U0 + 0xd, 0)
		await _enemy_turn()
		Mem.w8(U60 + 0xd, 0)
	if not await _round_end():
		_done = true
		return
	if mode == 2:
		await _walk(0x30, 0xc0)
	_enable()


func _hook(c: Callable) -> bool:
	if not c.is_valid():
		return false
	_idle_on = false
	var r: Variant = await c.call(self)
	return bool(r) and (Mem.r8(U0 + 0xd) & 2) != 0


## ENABLE: mode 1 — 攻击, 策略 if U0 can cast (0x43e023), 道具 if it has a usable item (0x408e96), 突击 (hidden);
## mode 2 — 攻击 / 防御 / 回避, 突击 iff U0's SP ≥ 3 (0x4162f0); menu fights also 逃跑.
func _enable() -> void:
	_idle_on = true
	if mode == 1:
		enabled[0x507] = true
		enabled[0x508] = can_cast_hook.is_valid() and bool(can_cast_hook.call(self))
		enabled[0x509] = can_item_hook.is_valid() and bool(can_item_hook.call(self))
		enabled[0x50a] = true
	else:
		enabled[0x507] = true
		enabled[0x508] = true
		enabled[0x509] = true
		enabled[0x50a] = _usp(U0) > 2
	if scripted == 0:
		enabled[0x50b] = true
	queue_redraw()


## [G] AIAct 0x43ad3b(U60) reduced to its attack: U60 strikes U0 when U0 is inside its attack range.
func _enemy_turn() -> void:
	if ai_hook.is_valid():
		await ai_hook.call(self)
		return
	var e := BUnit.at(60)
	var p := BUnit.at(0)
	if p.hp > 0 and Rules.in_attack_range(e, e.pos, p.pos):
		await _exchange(U60, U0)


## RoundEnd 0x41cf04: U0 dead → lost; U60 dead → won; round < 10 → next round (mode ≠ 1: both SP + 1, cap 5);
## round 10 survived → draw. Script/item fights end at once; menu fights show 战败 / 平手, run DuelLevelUp and offer
## the next paid opponent.
func _round_end() -> bool:
	var next := false
	if _uhp(U0) == 0:
		Mem.set_ev(4084, 0)
		if scripted != 1:
			await _show_msg("战败", false)
		return false
	if _uhp(U60) == 0:
		Mem.set_ev(4084, 1)
		next = true
	elif Mem.r8(DC + 0xa) < 10:
		Mem.w8(DC + 0xa, Mem.r8(DC + 0xa) + 1)
		if mode != 1:
			_add_sp(U60, 0)
			_add_sp(U0, 0)
		queue_redraw()
		return true
	else:
		Mem.set_ev(4084, 2)
		if scripted == 1:
			return false
		await _show_msg("平手", false)
		next = true
	if next:
		await _duel_level_up()
		if scripted == 1:
			return false
		var avg := party_average()
		var x := 0
		if mode != 2:
			if Mem.r8(Mem.r32(DC) + 0x2c) >= avg:
				await _show_msg("你已经没有对手了。", false)
				return false
			x = avg
			Mem.w8(DC + 9, x)
		Mem.w8(0x500cb0, 0)
		if not await _pay_training(host, Mem.r16(Mem.r32(DC)) & 0xfff, x):
			return false
		Mem.w8(0x500cb0, 1)
		_init_fighters()
		Mem.w8(DC + 0xa, 1)
		queue_redraw()
		if mode != 2:
			await _walk(0x60, 0x90)
	return true


## 0x44de51 with mode 0: SP += n (n = 1 at the round end via 0x4254b4, the damage taken after a hit), cap 5.
func _add_sp(u: int, _mode: int, n := 1) -> void:
	var v := _usp(u) + n
	Mem.w32(u + 0x14, v if (v & 0xff) < 5 else 5)


## DuelLevelUp 0x4107c3 (mode 2 only): a menu fight counts toward P1023+0x19; below duel level 43 every 5th win
## raises the level and one random ability (q0/q1 < 60, q2 ≠ 95, q3 ≠ 25, HP < 7), SE 11, "单挑等级提升".
func _duel_level_up() -> void:
	if mode != 2:
		return
	var d := _p1023()
	if Mem.r8(DC + 0x11) == 0:
		Mem.w8(d + 0x19, Mem.r8(d + 0x19) + 1)
	if Mem.r8(d + 0x17) >= 0x2b:
		return
	if Mem.r8(d + 0x18) < 4:
		Mem.w8(d + 0x18, Mem.r8(d + 0x18) + 1)
		return
	Mem.w8(d + 0x18, 0)
	Mem.w8(d + 0x17, Mem.r8(d + 0x17) + 1)
	var r := 0
	while true:
		r = Rules.rand(5)
		var v := Mem.r8(d + 0x11 + r)
		if (r <= 1 and v < 60) or (r == 2 and v != 95) or (r == 3 and v != 25) or (r == 4 and v < 7):
			break
	Mem.w8(d + 0x11 + r, Mem.r8(d + 0x11 + r) + 1)
	_se(11)
	await _show_msg("单挑等级提升", false)


# ================================================================== 单挑模式 (DuelCmd 0x437645, Resolve 0x40a5c5)
## Commands: 1 攻击, 2 突击 (−3 SP), 3 防御, 4 回避. The enemy's pick: rand(4), 突击 only with SP ≥ 3, 回避 only when
## the player has SP ≥ 3, at most 3 passive picks in a row (counter U0+0x20, never initialised — original quirk).
func _duel_cmd(pc: int) -> void:
	_idle_on = false
	var r := 0
	while true:
		r = Rules.rand(4)
		if r == 1 and (_usp(U60) & 0xff) < 3:
			continue
		if r == 3 and (_usp(U0) & 0xff) < 3:
			continue
		if r < 2:
			Mem.w8(U0 + 0x20, 0)
			break
		if Mem.r8(U0 + 0x20) < 3:
			Mem.w8(U0 + 0x20, Mem.r8(U0 + 0x20) + 1)
			break
	var e := r + 1
	var c := 0
	if e < 3:
		c = 1 if pc < 3 else 2
	else:
		c = 3 if pc < 3 else 4
	var marks: Array = [[0x60, 0x90], [0x90, 0xc0], [0x30, 0x60], [0x30, 0xc0]][c - 1]
	await _walk(marks[0], marks[1])
	await _resolve(pc, e, c)


## Resolve 0x40a5c5: 突击 costs 3 SP; c 4 (both passive) → nothing (SE 6); c 3 (player active) → 0x40a652(pc, U0
## vs U60's e); c 2 (enemy active) → 0x40a652(e, U60 vs U0's pc); c 1 (both active) → 0x43e1c3.
func _resolve(pc: int, e: int, c: int) -> void:
	if pc == 2:
		Mem.w32(U0 + 0x14, _usp(U0) - 3)
	if e == 2:
		Mem.w32(U60 + 0x14, _usp(U60) - 3)
	match c:
		4:
			queue_redraw()
			_se(6)
			await _t(2)
		3:
			await _act(pc, U0, U60, e, true)
		2:
			await _act(e, U60, U0, pc, false)
		1:
			await _both_active(pc, e)


## 0x40a652(cmd, A, T, T's command, A is the player): vs 回避 — 攻击 hits for 1; 突击 succeeds with the evade chance
## (A says "早就知道你要躲。", hits 1) or whiffs ("失手了！", T steps to its end mark and hits back for 2). Vs 防御 —
## 攻击 succeeds with the defence chance ("哼！防的住吗？", hits 1) or whiffs ("失手了！", T hits back 1); 突击 hits 1.
func _act(cmd: int, a: int, t: int, tcmd: int, player: bool) -> void:
	if tcmd == 4:
		if cmd == 1:
			await _hit(a, 1, 0)
		elif not _chance(player, 1):
			await _hit(a, 0, 0)
			await _speak(a, "失手了！")
			Mem.w8(t + 0x21, 0xc0 if t == U0 else 0x30)
			await _hit(t, 2, 0)
		else:
			await _speak(a, "早就知道你要躲。")
			await _hit(a, 1, 0)
		return
	if cmd == 1:
		if not _chance(player, 0):
			await _hit(a, 0, 3)
			await _speak(a, "失手了！")
			await _hit(t, 1, 0)
			return
		await _speak(a, "哼！防的住吗？")
	await _hit(a, 1, 3)


## 0x43e1c3 (both attack or 突击): 攻击/攻击 → clash, both lose 1; 突击 against 攻击 → the 突击 side hits for 2;
## 突击/突击 → rand(4): 0 clash without damage ("哼！再来！"), 1 the player hits 2, 2 the enemy hits 2 (each with
## "疾如流星，势如闪电！"), 3 clash, both lose 2 (then "哼！再来！" if both stand).
func _both_active(pc: int, e: int) -> void:
	if e == 1:
		if pc == 1:
			await _clash(1, 2)
		else:
			await _hit(U0, 2, 0)
	elif pc == 1:
		await _hit(U60, 2, 0)
	else:
		match Rules.rand(4):
			0:
				await _clash(0, 2)
				await _speak(U0, "哼！再来！")
			1:
				await _speak(U0, "疾如流星，势如闪电！")
				await _hit(U0, 2, 1)
			2:
				await _speak(U60, "疾如流星，势如闪电！")
				await _hit(U60, 2, 1)
			3:
				await _clash(2, 2)
				if _uhp(U60) != 0 and _uhp(U0) != 0:
					await _speak(U0, "哼！再来！")


## 0x44df5b(ctx, player acts, kind): q = P1023+0x11.., r = P1023+0x38.. (the enemy's EV 4086 bytes).
## kind 0 (攻击 vs 防御): player q0 − r0 (≥ 0), enemy (100 + r1 − q1) & 0xff; kind 1 (突击 vs 回避): player
## q3 − r3 (≥ 0), enemy (100 + r2 − q2) & 0xff. Then chance(p).
func _chance(player: bool, kind: int) -> bool:
	var d := _p1023()
	var q := d + 0x11
	var r := d + 0x38
	var p := 0
	if kind == 0:
		if player:
			p = maxi(Mem.r8(q) - Mem.r8(r), 0)
		else:
			p = (Mem.r8(r + 1) + 100 - Mem.r8(q + 1)) & 0xff
	elif player:
		p = maxi(Mem.r8(q + 3) - Mem.r8(r + 3), 0)
	else:
		p = (Mem.r8(r + 2) + 100 - Mem.r8(q + 2)) & 0xff
	return Rules.chance(p)


func _other(u: int) -> int:
	return U60 if u == U0 else U0


## 0x4370f3(X, n, k): X's 5-frame attack (SE by its attack kind, 0x465dba); on frame 3 the hit sound (0x4234b8:
## n = 0 → SE 30 (k 3) / 31 (k 2) / 7, and with k 0 X overshoots to its end mark; n ≥ 1 → SE 35 / 36); then the
## other side loses n HP (0x4153c9, floor 0) and gains n SP (cap 5); a 2-point hit that leaves it standing flashes
## 2×2 times with SE 6.
func _hit(x: int, n: int, k: int) -> void:
	var o := _other(x)
	_se(32 if not _archer(x) else 37)
	for f in 5:
		if f == 3:
			if n == 0:
				_se(30 if k == 3 else (31 if k == 2 else 7))
				if k == 0:
					Mem.w8(x + 0x21, 0xd0 if x == U0 else 0x20)
			else:
				_se(35 if n == 1 else 36)
		_anim[_slot(x)] = {"sheet": "atk", "idx": 8 + mini(f, 3)} if f < 4 else {}
		if f == 3 and n > 0:
			_anim[_slot(o)] = {"sheet": "spc", "idx": 3, "flash": 0.4}
		queue_redraw()
		await _t(2)
	_anim.erase(_slot(x))
	_anim.erase(_slot(o))
	_damage(o, n)
	if n == 2 and _uhp(o) != 0:
		for i in 4:
			_anim[_slot(o)] = {"sheet": "spc", "idx": 3, "flash": 0.6 if i % 2 == 0 else 0.0}
			queue_redraw()
			_se(6)
			await _t(4)
		_anim.erase(_slot(o))
	queue_redraw()


## 0x4536c7(U0, n, k): both attack at once, then both lose n (flash as 0x4370f3 when both stand after a 2).
func _clash(n: int, _k: int) -> void:
	_se(32)
	for f in 5:
		for u in [U0, U60]:
			_anim[_slot(u)] = {"sheet": "atk", "idx": 8 + mini(f, 3)} if f < 4 else {}
		if f == 3:
			_se(35 if n == 1 else (36 if n == 2 else 31))
		queue_redraw()
		await _t(2)
	_anim.clear()
	_damage(U60, n)
	_damage(U0, n)
	if n == 2 and _uhp(U0) != 0 and _uhp(U60) != 0:
		for i in 4:
			for u in [U0, U60]:
				_anim[_slot(u)] = {"sheet": "spc", "idx": 3, "flash": 0.6 if i % 2 == 0 else 0.0}
			queue_redraw()
			_se(6)
			await _t(4)
		_anim.clear()
	queue_redraw()


## 0x4153c9: HP −= n (floor 0), then SP += n (cap 5) (0x44de51 mode 0).
func _damage(u: int, n: int) -> void:
	if n & 0xff == 0:
		return
	var hp := _uhp(u)
	Mem.w32(u + 0x10, hp - n if n < hp else 0)
	_add_sp(u, 0, n)
	_numbers.append([_slot(u), str(n), Color(1, 0.3, 0.2), Time.get_ticks_msec() + 700])


## 0x416a75 → 0x46d9a4: the fighter's line in a small window. [G] drawn as a box over the picture, held 1 s (or
## until a click).
func _speak(u: int, text: String) -> void:
	_say = [_slot(u), text]
	if OS.get_environment("WG_TRACE_TEXT") != "":
		var p := Game.person(_pid(u))
		print("  [练武场 %s] %s" % [p.name if p else "?", text])
	queue_redraw()
	if not Game.autoplay:
		var c := Game.clicks
		var end := Time.get_ticks_msec() + 1000
		while Time.get_ticks_msec() < end and Game.clicks == c:
			await get_tree().process_frame
	_say = []
	queue_redraw()


## Walk 0x41da18(enemy x, player x): both step 8 px per frame toward their marks.
func _walk(ex: int, px: int) -> void:
	var guard := 0
	while (_ux(U0) != px or _ux(U60) != ex) and guard < 64:
		guard += 1
		for pair in [[U0, px], [U60, ex]]:
			var u: int = pair[0]
			var x := _ux(u)
			var to: int = pair[1]
			if x != to:
				x += 8 if to > x else -8
				if absi(to - x) < 8:
					x = to
				Mem.w8(u + 0x21, x)
				_anim[_slot(u)] = {"sheet": "mov", "idx": 4 + guard % 2}
			else:
				_anim.erase(_slot(u))
		queue_redraw()
		await _t(1)
	_anim.clear()
	queue_redraw()


# ================================================================== 普通模式: the exchange (0x4064f1)
## Exchange(X, Y) — Strike (CalcDamage + critical for the target, 0x405de1) up to twice (Again 0x4060d2), PhysEXP and
## SetExp of a player-side attacker (0x406b3c), then Counter (0x406453). See the class comment for what is left out.
func _exchange(xa: int, ya: int) -> void:
	var x := BUnit.at(_slot(xa))
	var y := BUnit.at(_slot(ya))
	Mem.w8(Rules.COMBAT, x.slot)
	Mem.w8(Rules.COMBAT + 1, y.slot)
	var depth := Mem.r8(Rules.COUNTER_DEPTH)
	if Mem.r8(Rules.ATTACK_MODE) == 1:
		# 0x435829: the attacker turns toward the target (same row: right if it is to the right)
		Mem.w8(xa + 0xf, 1 if Mem.r8(ya + 6) > Mem.r8(xa + 6) else 3)
	var exp := 0
	var strikes := 0
	while strikes < 2:
		var hp_before := y.hp
		if hp_before > 0:
			var dmode := (1 if strikes == 0 else 2) if depth > 0 else (0 if strikes == 0 else 2)
			var r := Rules.calc_damage(x, y, false, dmode)
			var dmg: int = r[0]
			# 0x405de1: the critical for target 0 (a miss can "crit" for 0)
			var rate := Rules.crit_rate(x, y)
			var crit := true
			if rate <= 100:
				crit = Rules.roll_acc(rate, 2)
				rate += 100
			if crit:
				if y.eff(0x30, 0x41, 1, 1) != 0 and x.eff(0x70, 0x34, 1, 1) == 0:
					dmg = 0
				else:
					dmg += dmg * (rate >> 1) / 100
			if strikes > 0 and y.eff(0x31, 0x41, 1, 1) != 0:
				dmg = 0
			dmg = mini(dmg, hp_before)
			await _strike_anim(xa, ya, dmg, crit)
			Mem.w32(ya + 0x10, hp_before - dmg)
			if OS.get_environment("WG_TRACE_BATTLE") != "":
				print("  [练武场] %d → %d: %d%s (HP %d → %d)%s" % [x.slot, y.slot, dmg, " crit" if crit else "",
						hp_before, hp_before - dmg, " counter" if depth > 0 else ""])
			exp = maxi(exp, _phys_exp(x, y, dmg, hp_before))
		# Again 0x4060d2
		var again := false
		if x.eff(0x35, 0x42, 1, 0) != 0 and strikes < 1:
			again = true
		elif depth > 0 or strikes > 1:
			again = false
		else:
			again = Rules.roll_acc(Rules.double_rate(x, y), 0)
		if not again:
			break
		strikes += 1
		if x.confused():
			break
	if exp > 0 and Mem.r8(xa + 5) == 0:
		var p := x.person
		p.add_exp(exp)
	queue_redraw()
	# 0x406570: the counter only in attack mode 0 — the fake map (0x40ada3) raised the mode byte 0x500e9a to 1
	# (围攻), so a training exchange has no counter-attack (and the 围攻 +5 % / EXP rules apply)
	if Mem.r8(Rules.ATTACK_MODE) == 0:
		await _counter(y, x)


## Counter 0x406453(T = the struck unit, X = the striker).
func _counter(t: BUnit, x: BUnit) -> void:
	var d := Mem.r8(Rules.COUNTER_DEPTH)
	if d > 1 or (d == 1 and t.eff(0x25, 0x30, 1, 1) == 0) or t.hp == 0 or t.confused() \
			or x.eff(0x26, 0x34, 1, 1) != 0 or not Rules.in_attack_range(t, t.pos, x.pos):
		Mem.w8(Rules.COUNTER_DEPTH, 0)
		return
	Mem.w8(Rules.COUNTER_DEPTH, d + 1)
	Mem.w8(0x501bfa, d + 1)
	await _exchange(t.addr, x.addr)
	Mem.w8(Rules.COUNTER_DEPTH, 0)


## PhysEXP 0x4037a3 for a player-side attacker (unit +5 == 0): a kill gives 48 against the battle's leader
## (Reader+0x3d06), else 64 / (max(lvA − lvT, 0) + 2); then + 2·clamp(lvT − lvA, −1, 47) + 6; ExpMod 0x42104f
## (辅助获得Exp; with EV 4079 the 精进 and 围攻 doublings). Training: no kill count (0x426ba0).
func _phys_exp(a: BUnit, t: BUnit, dmg: int, hp_before: int) -> int:
	if Mem.r8(a.addr + 5) != 0:
		return 0
	var lva := a.level()
	var lvt := t.level()
	var e := 0
	if dmg >= hp_before and hp_before > 0:
		if (Mem.r32(t.addr) & 0xffff) == Mem.r16(0x496c96):
			e += 48
		else:
			e += 64 / (maxi(lva - lvt, 0) + 2)
	e += 2 * clampi(lvt - lva, -1, 47) + 6
	e = e * (100 + (a.person.equip_bonus(8) & 0xff)) / 100
	if Mem.ev(4079) != 0:
		if Mem.r8(0x501b00 + a.slot) != 0:
			e *= 2
		if Mem.r8(Rules.ATTACK_MODE) == 1:
			e *= 2
	return e


## [G] the battle animation 0x4526e7 is not ported: the attacker shows its ATK frames, the target its hurt (or
## guard on a miss) frame, and the damage as a number.
func _strike_anim(xa: int, ya: int, dmg: int, crit: bool) -> void:
	_se(37 if _archer(xa) else 32)
	for f in 4:
		_anim[_slot(xa)] = {"sheet": "atk", "idx": 8 + f}
		if f == 2:
			_anim[_slot(ya)] = {"sheet": "spc", "idx": 3 if dmg > 0 else 2, "flash": 0.4 if crit and dmg > 0 else 0.0}
			_se(36 if crit else (35 if dmg > 0 else 7))
			_numbers.append([_slot(ya), str(dmg) if dmg > 0 else "MISS", Color(1, 0.3, 0.2), Time.get_ticks_msec() + 800])
		queue_redraw()
		await _t(2)
	_anim.clear()
	queue_redraw()
	await _t(4)


func _archer(u: int) -> bool:
	var p := Game.person(_pid(u))
	if p == null:
		return false
	var fam := Game.family_of(p.cls)
	return fam < 0x28 and Mem.r8(0x4d2160 + fam) != 0


# ================================================================== timing / sound
func _t(n: int) -> void:
	if Game.autoplay or n <= 0:
		return
	await get_tree().create_timer(n * TICK).timeout


func _se(n: int) -> void:
	if not Game.autoplay:
		Audio.se(n)


func _process(delta: float) -> void:
	if _idle_on and not Game.autoplay:
		_idle_t += delta
		if _idle_t >= 0.3:            # timer 0x6e, 300 ms
			_idle_t = 0.0
			_idle = (_idle + 1) % 2
			queue_redraw()
	if not _numbers.is_empty():
		var now := Time.get_ticks_msec()
		_numbers = _numbers.filter(func(n: Array) -> bool: return n[3] > now)
		queue_redraw()


# ================================================================== message boxes owned by the dialog
func _show_msg(text: String, yesno: bool) -> bool:
	if Game.autoplay:
		if OS.get_environment("WG_TRACE_TEXT") != "":
			print("  [练武场] ", text)
		return true
	_msg = text
	_yesno = yesno
	_msg_answer = -1
	queue_redraw()
	while _msg_answer < 0 and is_inside_tree():
		await get_tree().process_frame
	_msg = ""
	queue_redraw()
	return _msg_answer == 1


func _msg_rects() -> Dictionary:
	var size := Vector2(220, 96)
	var r := Rect2(((Vector2(640, 480) - size) / 2).floor(), size)
	var out := {"box": r}
	if _yesno:
		out[1] = Rect2(r.position + Vector2(40, 62), Vector2(60, 22))
		out[0] = Rect2(r.position + Vector2(120, 62), Vector2(60, 22))
	else:
		out[1] = Rect2(r.position + Vector2(80, 62), Vector2(60, 22))
	return out


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion:
		var h := _button_at(ev.position)
		if h != _hover:
			_hover = h
			queue_redraw()
	elif ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		if _msg != "":
			var mr := _msg_rects()
			for k in [0, 1]:
				if mr.has(k) and (mr[k] as Rect2).has_point(ev.position):
					_msg_answer = k
			return
		var b := _button_at(ev.position)
		if b >= 0 and enabled.get(b, false) and _pressed < 0:
			_pressed = b


func _unhandled_input(ev: InputEvent) -> void:
	if _msg != "" and (ev.is_action_pressed("ui_accept") or ev.is_action_pressed("ui_cancel")):
		_msg_answer = 1 if ev.is_action_pressed("ui_accept") or not _yesno else 0
		get_viewport().set_input_as_handled()


func _button_at(p: Vector2) -> int:
	var o := _client_origin()
	for id in _buttons:
		if (_buttons[id][0] as Rect2).has_point(p - o):
			return id
	return -1


# ================================================================== drawing (Win32 dialog look)
const FACE := Color("#d4d0c8")
const SHADOW := Color("#808080")
const DARK := Color("#404040")
const LIGHT := Color("#ffffff")


func _font() -> Font:
	return Assets.font()


func _text(p: Vector2, s: String, c := Color.BLACK, size := FONT_PX) -> void:
	draw_string(_font(), p + Vector2(0, _font().get_ascent(size)), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, c)


func _text_center(r: Rect2, s: String, c := Color.BLACK, size := FONT_PX) -> void:
	var w := _font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	_text(Vector2(r.position.x + (r.size.x - w) / 2, r.position.y + (r.size.y - size) / 2), s, c, size)


func _bevel(r: Rect2, raised: bool) -> void:
	var tl := LIGHT if raised else SHADOW
	var br := DARK if raised else LIGHT
	draw_line(r.position, Vector2(r.end.x, r.position.y), tl)
	draw_line(r.position, Vector2(r.position.x, r.end.y), tl)
	draw_line(Vector2(r.position.x, r.end.y), r.end, br)
	draw_line(Vector2(r.end.x, r.position.y), r.end, br)


func _tex_of(rel: String) -> Texture2D:
	if not _tex.has(rel):
		_tex[rel] = Assets.tex(rel)
	return _tex[rel]


func _draw() -> void:
	if client != Vector2.ZERO and not win_rect.has_area():
		return
	if client != Vector2.ZERO:
		_draw_dialog()
	if _msg != "":
		_draw_msg()


func _draw_dialog() -> void:
	var w := win_rect
	draw_rect(w, FACE)
	_bevel(w, true)
	_bevel(w.grow(-1), true)
	# caption (title "练武场", "单挑" for script / item fights)
	var cap := Rect2(w.position + Vector2(3, 3), Vector2(w.size.x - 6, 18))
	draw_rect(cap, Color("#0a246a"))
	draw_rect(Rect2(cap.position + Vector2(cap.size.x / 2, 0), Vector2(cap.size.x / 2, cap.size.y)), Color("#3a6ea5"))
	_text(cap.position + Vector2(4, 3), "单挑" if scripted != 0 else "练武场", LIGHT)
	var o := _client_origin()
	# picture 0x4c3 (2,2) 294×150, the view inside it: landscape U_select[5 + DC+8] (0x40a52e), fighters at y 56
	var pic := Rect2(o + Vector2(2, 2), Vector2(294, 150))
	draw_rect(pic, Color.BLACK)
	_bevel(pic.grow(1), false)
	var land := _tex_of("gfx/ui/u_select/%02d.png" % (5 + Mem.r8(DC + 8)))
	if land:
		draw_texture_rect(land, Rect2(pic.position, Vector2(288, 144)), false)
	_draw_fighter(U60, pic.position)
	_draw_fighter(U0, pic.position)
	for n in _numbers:
		var u := U0 if n[0] == 0 else U60
		_text(pic.position + Vector2(_ux(u) + 16, 40), n[1], n[2], 14)
	if not _say.is_empty():
		var su := U0 if _say[0] == 0 else U60
		var sw := _font().get_string_size(_say[1], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_PX).x + 12
		var sx := clampf(pic.position.x + _ux(su) + 24 - sw / 2, pic.position.x, pic.end.x - sw)
		var br := Rect2(sx, pic.position.y + 8, sw, 20)
		draw_rect(br, LIGHT)
		draw_rect(br, Color.BLACK, false)
		_text(br.position + Vector2(6, 4), _say[1])
	# 回合数 n/10
	_text(o + Vector2(298, 4), "回合数")
	var rr := Rect2(o + Vector2(339, 3), Vector2(33, 13))
	draw_rect(rr, LIGHT)
	_bevel(rr, false)
	_text_center(rr, "%d/%d" % [Mem.r8(DC + 0xa), 10])
	# panels: the opponent (group 0x55a) left, the player (0x557) right
	_draw_panel(U60, o + Vector2(1, 154))
	_draw_panel(U0, o + Vector2(151, 154))
	for id in _buttons:
		var r: Rect2 = _buttons[id][0]
		r.position += o
		var on: bool = enabled.get(id, false) and _msg == ""
		draw_rect(r, FACE)
		_bevel(r, true)
		if on and _hover == id:
			draw_rect(r.grow(-2), Color(1, 1, 1, 0.25))
		_text_center(r, _buttons[id][1], Color.BLACK if on else SHADOW)


func _draw_fighter(u: int, origin: Vector2) -> void:
	var p := Game.person(_pid(u))
	if p == null or Mem.r8(u + 0xc) == 0:
		return
	var entry := p.sprite_entry(mini(Mem.r8(u + 5), 2))
	var a: Dictionary = _anim.get(_slot(u), {})
	var sheet: String = a.get("sheet", "mov")
	var idx: int = a.get("idx", (4 + _idle) if _idle_on else 8)
	var t := _tex_of("gfx/units/%s/%03d.png" % [sheet, entry])
	if t == null:
		return
	var fw := 64 if sheet == "atk" else 48
	# facing +0xf: 3 left (frames as stored), 1 right (mirrored); ATK frames at x − 8 (U0) / x, y 48 (0x411224)
	var mirror := Mem.r8(u + 0xf) == 1 and not (sheet == "spc" and idx in [3, 4])
	var pos := origin + Vector2(_ux(u), 56)
	if sheet == "atk":
		pos = origin + Vector2(_ux(u) - (8 if u == U0 else 0), 48)
	var dst := Rect2(pos, Vector2(fw, fw))
	if mirror:
		dst = Rect2(pos + Vector2(fw, 0), Vector2(-fw, fw))
	var f: float = a.get("flash", 0.0)
	draw_texture_rect_region(t, dst, Rect2(0, idx * fw, fw, fw))
	if f > 0:
		draw_texture_rect_region(t, dst, Rect2(0, idx * fw, fw, fw), Color(1, 0.2, 0.2, f))


## Group box (0x42c5ac): caption = display name (0x407775), class name (0x55b/0x558), Lv; bars HP, SP (MP in
## 普通模式), Exp and the five stats (mode 1 only). Positions = template DLU × 1.5, the group moved to 144×160.
func _draw_panel(u: int, at: Vector2) -> void:
	var p := Game.person(_pid(u))
	if p == null:
		return
	var h := 160.0 if mode == 1 else 69.0
	var g := Rect2(at + Vector2(0, 6), Vector2(144, h - 6))
	draw_rect(g, SHADOW, false)
	draw_rect(Rect2(g.position + Vector2(1, 1), g.size), LIGHT, false)
	var name := _display_name(p.name)
	var nw := _font().get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_PX).x
	draw_rect(Rect2(at + Vector2(7, 0), Vector2(nw + 4, 13)), FACE)
	_text(at + Vector2(9, 0), name)
	var row := func(dly: int) -> float: return floorf(dly * DLU) - 154 + at.y
	var x0 := at.x + 11
	_text(Vector2(x0, row.call(115)), p.class_name_str())
	if mode == 1:
		_text(Vector2(x0 + 90, row.call(115)), "Lv")
		_text(Vector2(x0 + 106, row.call(115)), str(p.level))
	var bars := [["HP", _uhp(u), p.max_hp() if mode == 1 else 7, Color("#e03030")]]
	bars.append(["MP" if mode == 1 else "SP", _usp(u), p.max_mp() if mode == 1 else 5, Color("#3050e0")])
	if mode == 1:
		bars.append(["Exp", p.exp if p.exp != 0xff else 100, 100, Color("#e0c030")])
		var names := ["攻击", "防御", "精神", "爆发", "士气"]
		var bu := BUnit.at(_slot(u))
		for k in 5:
			bars.append([names[k], Rules.unit_stat(bu, k, 0), 500, Color("#30a040")])     # [G] bar scale
	for i in bars.size():
		var y: float = row.call([127, 137, 147, 157, 167, 177, 187, 197][i])
		var lbl: String = bars[i][0]
		_text(Vector2(x0, y), lbl)
		var bx := x0 + (21.0 if i < 3 else 27.0)
		var bw := 103.0 if i < 3 else 97.0
		var r := Rect2(bx, y, bw, 12)
		draw_rect(r, LIGHT)
		_bevel(r, false)
		var v: int = bars[i][1]
		var mx: int = maxi(bars[i][2], 1)
		draw_rect(Rect2(r.position + Vector2(1, 1), Vector2((bw - 2) * clampf(float(v) / mx, 0, 1), 10)), bars[i][3])
		_text(r.position + Vector2(2, 0), str(v) if i >= 3 or mode == 2 else "%d/%d" % [v, mx], Color.BLACK)


static func _display_name(n: String) -> String:
	var out := ""
	for ch in n:
		if not (ch >= "0" and ch <= "9"):
			out += ch
	return out


func _draw_msg() -> void:
	var mr := _msg_rects()
	var r: Rect2 = mr["box"]
	draw_rect(r, FACE)
	_bevel(r, true)
	var lines := _msg.split("\n")
	for i in lines.size():
		_text_center(Rect2(r.position + Vector2(0, 14 + 16 * i), Vector2(r.size.x, 16)), lines[i])
	for k in [1, 0]:
		if not mr.has(k):
			continue
		var b: Rect2 = mr[k]
		draw_rect(b, FACE)
		_bevel(b, true)
		_text_center(b, ("是" if k == 1 else "否") if _yesno else "确定")
