class_name BattleStage
extends ScriptHost
## Battle (S_###) runner: the battle flow of the 6.6 engine (docs/ai.md §1–§2, docs/battle.md §7) and the battle-only
## script ops (docs/eex.md §5, §8, §10). Scene 0 of an S file is the deployment and opening (op 0x27 mode 3 creates
## the field, BattleStart 0x44d2ca), scene 1 the event loop polled at the battle checkpoints while the round loop
## 0x44eee5 runs, later scenes the aftermath.
##
## State lives in the emulated memory like the original's: units 0x4a7b20 (BUnit), deployment entries 0x494fd4,
## the battle object 0x4b3d08 (+1 result, +2 round, +3 limit, +4 weather level, +0x10 phase, +0x11 climate), the
## map buffer (terrain +0x640, unit grid +0xc80). Saves therefore only add the presentation state.

signal unit_died(u: BUnit)

const PH_PLAYER := 0
const PH_FRIEND := 1
const PH_ENEMY := 2
const B := Rules.B
const READER := 0x492f90
const DEPLOY := 0x494fd4          # 250 × 16 B deployment entries (reader + 0x2044)
const SORTIE := 0x48b350          # u16 sortie list, 0xffff end
const CUR_PERSON := 0x4b5df0      # person of the acting unit (0x406240)
const LAST_ACTION := 0x501bf9     # last action kind: 1 attack, 2 strategy, 5 必杀 / item, 0xff none
const WEATHER_NAMES := ["晴", "阴", "雨", "暴雨", "雪"]

var view: BattleView
var hud: BattleHUD
var units: Array[BUnit] = []
var actions: BattleActions
var strategy: BattleStrategy
var ai: BattleAI
var input: BattleInput
var field_ready := false
var map_id := -1
var victory_text := ""
var goal_text := ""
var current_unit: BUnit
var terrain_changes: Array = []
var _restore: Dictionary = {}
var _in_checkpoint := false
var _resumed := false        # loaded from a save made during the player phase: its start already happened
var duel: DuelLayer
var pictures: Dictionary = {}     # sub-12 map objects: slot → DtPicture
var overview: BattleOverview      # 战场缩小图 window, created on first use
var event_slots: Dictionary = {}  # reader event slots 5 / 6 (victory / defeat latches of ops 0x42 / 0x43)

## Battle object fields.
var result: int:
	get: return Mem.r8(B + 1)
	set(v): Mem.w8(B + 1, v)
## Round counter, 0-based (B+2).
var round_no: int:
	get: return Mem.r8(B + 2)
	set(v): Mem.w8(B + 2, v)
## Shown turn = round + 1.
var turn: int:
	get: return Mem.r8(B + 2) + 1
	set(v): Mem.w8(B + 2, maxi(v - 1, 0))
var turn_limit: int:
	get: return Mem.r8(B + 3)
	set(v): Mem.w8(B + 3, v)
var phase: int:
	get: return Mem.r8(B + 0x10)
	set(v): Mem.w8(B + 0x10, v)
var climate: int:
	get: return Mem.r8(B + 0x11)
	set(v): Mem.w8(B + 0x11, v)
var weather_level: int:
	get: return Mem.r8(B + 4)
	set(v): Mem.w8(B + 4, v)
## The battle's boss (reader +0x3d04 bit 0 / +0x3d06), -1 = none.
var boss_pid: int:
	get: return Mem.r16(READER + 0x3d06) if Mem.r16(READER + 0x3d04) & 1 else -1
## The person whose fall loses the battle (reader +0x3d08 bit 0 / +0x3d0a), -1 = none.
var leader_pid: int:
	get: return Mem.r16(READER + 0x3d0a) if Mem.r16(READER + 0x3d08) & 1 else -1


func _ready() -> void:
	super._ready()
	Effects.battle = self
	view = BattleView.new()
	add_child(view)
	view.input_enabled = false
	view.show_cursor = false
	hud = BattleHUD.new()
	hud.stage = self
	ui.add_child(hud)
	ui.move_child(hud, 0)
	for s in Mem.UNIT_SLOTS:
		units.append(BUnit.at(s))
	actions = BattleActions.new(self)
	strategy = BattleStrategy.new(self)
	ai = BattleAI.new(self)
	input = BattleInput.new(self)


func _exit_tree() -> void:
	if Effects.battle == self:
		Effects.battle = null
	if hud and is_instance_valid(hud):
		hud.queue_free()
	if duel and is_instance_valid(duel):
		duel.queue_free()     # it lives in the UI layer, which outlasts the stage
	if overview and is_instance_valid(overview):
		overview.queue_free()


func in_battle() -> bool:
	return true


func trace_info() -> String:
	return "turn %d phase %d" % [turn, phase]


func battle_finished() -> bool:
	return result != 0 or not vm.active or vm.scene != 1 or not is_inside_tree()


func _battle_finished() -> bool:
	return battle_finished()


# ------------------------------------------------------------------ main loop
func run_file(file: String) -> void:
	vm = EexVM.new()
	vm.host = self
	if not vm.load_script(file):
		return
	if not _restore.is_empty():
		await _apply_restore()
	# scene 0: deployment & opening events
	while vm.active and vm.scene == 0:
		var ran: bool = await vm.poll()
		if not ran:
			break
	if vm.active and vm.scene == 1 and field_ready and Game.autoplay and Game.skip_battle_scenario == Game.scenario:
		print("== flow-test: skipping battle %s" % file)
		Game.skip_battle_scenario = -1
		vm.scene = mini(2, vm.scene_count() - 1)
	elif vm.active and vm.scene == 1 and field_ready:
		# 0x44f058: 自动显示战场缩小图 (GS+0 bit 3) shows the overview before the first round
		if Mem.r8(Mem.GS) & 8 != 0 and not Game.autoplay:
			BattleOverview.ensure(self).open()
		await battle_loop()
		# 0x41ba73: the overview closes with the battle
		if overview and is_instance_valid(overview):
			overview.close()
		if result == 3 and vm.active and vm.scene == 1:
			# out of rounds (B+1 = 3): defeat → game over (scene flag 0x20 of the scene loop 0x42c228)
			await Game.main.game_over()
			vm.abort = true
			vm.active = false
			return
	# aftermath scenes
	while vm.active:
		var ran2: bool = await vm.poll()
		if not ran2:
			break
	hud.visible = false
	SoundMap.stop_loop()


## Poll 0x44c601: up to (number of sections) selections of the event scene (the reader's byte counter R+8 only
## drops to 0 when the scene changes). Selections depend on the memory alone, so when a run made only of memory ops
## (EexVM.PURE_OPS) left the memory as it was, the remaining selections would repeat it: the loop stops. Likewise
## when two such runs undo each other (S_020: a flag set by one section and cleared by the other) the rest
## alternates: one more run if an odd number is left, then stop. Same result as the original's repeated runs.
func checkpoint() -> void:
	if _in_checkpoint or not vm.active or vm.scene != 1:
		return
	_in_checkpoint = true
	var n: int = maxi(vm.sections(vm.scene).size(), 1)
	var prev := {}
	var prev_pure := false
	for k in n:
		if not vm.active or vm.scene != 1:
			break
		vm.impure = false
		Mem.journal_start()
		var ran: bool = await vm.poll()
		var diff := Mem.journal_stop_diff()
		if not ran:
			break
		var pure := not vm.impure and vm.active and vm.scene == 1
		if pure and diff.is_empty():
			break
		if pure and prev_pure and _undoes(diff, prev):
			if (n - k - 1) % 2 == 1 and vm.active and vm.scene == 1:
				await vm.poll()
			break
		prev = diff
		prev_pure = pure
	refresh_units()
	_in_checkpoint = false


## True when the byte changes `d` exactly undo the changes `p` (same bytes, old and new swapped).
static func _undoes(d: Dictionary, p: Dictionary) -> bool:
	if d.size() != p.size():
		return false
	for a in d:
		if not p.has(a) or p[a][0] != d[a][1] or p[a][1] != d[a][0]:
			return false
	return true


## BattleLoop 0x44eee5: rounds until a result; out of rounds → the protagonist's unit retreats and the battle is
## lost; then BattleEnd 0x44ebe8.
func battle_loop() -> void:
	if OS.get_environment("WG_INPUTBOT") != "":
		Game.autoplay = false
	view.input_enabled = true
	view.show_cursor = true
	hud.visible = true
	var resume := _resumed
	_resumed = false
	while result == 0 and not _stopped():
		if round_no >= turn_limit:
			await ui_message(2, "因为战斗时间过长，撤退。")      # 0x42f699(2, 0x48e220)
			var found := false
			for i in 60:
				if units[i].pid == 0:
					await remove_unit(units[i], false, false)
					found = true
					break
			if not found and units[0].state == 2:
				await remove_unit(units[0], false, false)
			result = 3
			break
		Mem.w8(0x4b4238, 0)
		if not resume and round_no != 0:
			_weather_step(0xff)
		await _round(resume)
		resume = false
		if result == 5 or _stopped():
			return
		round_no = round_no + 1
		if _god_cap():
			break
	view.input_enabled = false
	view.show_cursor = false
	view.clear_highlights()
	await _battle_end(((turn_limit - round_no) & 0xff) * 4)


func _stopped() -> bool:
	return not vm.active or vm.scene != 1 or not is_inside_tree()


## Debug flow-test help (WG_GOD with autoplay): enemies cleared after turn 12, aftermath after turn 60.
func _god_cap() -> bool:
	if not (Game.god and Game.autoplay):
		return false
	if turn > 12:
		var keep := _defeat_persons()
		for e in range(60, 250):
			var u := units[e]
			if u.exists() and u.state in [1, 2] and not keep.has(u.pid):
				u.hp = 0
				u.state = 3
		refresh_units()
	if turn > 60:
		print("== flow-test: turn cap, skipping to aftermath of %s" % vm.name)
		vm.scene = mini(2, vm.scene_count() - 1)
		return true
	return false


## Debug (_god_cap): persons whose death loses the battle — the lose-person (reader +0x3d0a) and the persons of
## event sections that test "HP == 0" (op 0x36 attr 7) and end in op 0x0e.
func _defeat_persons() -> Dictionary:
	var out := {}
	if Mem.r16(READER + 0x3d08) & 1:
		out[Mem.r16(READER + 0x3d0a)] = true
	for se in vm.sections(1):
		var lose := false
		for b in se.get("body", []):
			if int(b.get("op", -1)) == 0x0e:
				lose = true
				break
		if not lose:
			continue
		for c in se.get("conditions", []):
			var a: Array = c.get("args", [])
			if str(c.get("name", "")) == "test_attr" and a.size() >= 2 and (a[0] is float or a[0] is int) and int(a[1]) == 7:
				out[int(a[0])] = true
	return out


## One round 0x44ed7f.
func _round(resume: bool) -> void:
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		var n := [0, 0, 0]
		for u in units:
			if u.state == 2:
				n[mini(u.side(), 2)] += 1
		print("round %d (turn %d/%d) t=%d ms: player side %d, enemy side %d, third %d" % [round_no, turn, turn_limit,
				Time.get_ticks_msec(), n[1], n[0], n[2]])
	hud.queue_redraw()
	await _turn_banner(0, resume)
	if not resume:
		phase = PH_PLAYER
		await checkpoint()
		if round_no == 0:
			await checkpoint()
		if result == 0 and not _stopped():
			if Rules.evb(4077) != 2:
				Mem.w32(Mem.EV + 4 * 4077, 0)
			await side_upkeep(0)
			Rules.refill_decks()
			_tick_map_objects()
	if result == 0 and not _stopped():
		Mem.w8(B + 0x520, 1)
		await input.player_phase(resume)
		Mem.w8(B + 0x520, 0)
	if result == 0 and not _stopped():
		await _ai_phases()


## TurnBanner 0x44ac28: "我军阶段" (kind 0, with the turn line) / "敌军阶段"; unless resuming, the acted flags and
## per-phase counters of all 250 units are cleared and KindSwap runs.
func _turn_banner(kind: int, resume: bool) -> void:
	var t := ""
	if kind == 0:
		t = "我军阶段　" + ("最终回合" if turn >= turn_limit else "第%2d回合" % turn)
	else:
		t = "敌军阶段"
	if not resume:
		for u in units:
			u.flags = u.flags & ~6
			Mem.w32(u.addr + 0x22, 0)
			Mem.w8(0x508b00 + u.slot, 0)
		Mem.w8(LAST_ACTION, 0xff)
		_kind_swap(0 if kind == 0 else 2)
		refresh_units()
	await hud.phase_banner(t)


## KindSwap 0x416f38(p): 深入敌后 (Q(0x46, 0x68, 0, 1)) moves a unit to the acting side for that phase; everybody
## else returns to the kind of its slot range (player-phase start) or loses a temporary +3 (enemy-phase start).
func _kind_swap(p: int) -> void:
	for u in units:
		if u.state != 2:
			continue
		var e := u.eff(0x46, 0x68, 0, 1)
		var k := u.kind
		if e == 0:
			if p == 0:
				if u.slot < 20: k = 0
				elif u.slot < 60: k = 1
				elif Mem.r8(0x501ad8 + u.slot) == 0 and k >= 5: k -= 3
			elif u.slot >= 60 and Mem.r8(0x501ad8 + u.slot) == 0 and k >= 5:
				k -= 3
		else:
			if p == 2:
				if u.slot < 60: k = 2
				elif k >= 5: k -= 3
			else:
				if u.slot < 20: k = 0
				elif u.slot < 60: k = 1
				else: k += 3
		u.kind = k & 0xff


## Friend and enemy phases 0x44e825: action order, then two passes over the order numbers; an action may grant
## another one (大杀四方, 二次行动, 围攻 partners).
func _ai_phases() -> void:
	Mem.w32(B + 0x504, 0)
	for ph in 2:
		if result != 0 or _stopped():
			return
		if ph == 1:
			await _turn_banner(1, false)
			phase = PH_ENEMY
			await checkpoint()
			if result != 0 or _stopped():
				return
			if Rules.evb(4077) != 2:
				Mem.w32(Mem.EV + 4 * 4077, 1)
			await side_upkeep(1)
		else:
			phase = PH_FRIEND
			await checkpoint()
			if result != 0 or _stopped():
				return
		var lo := 0 if ph == 0 else 60
		var hi := 60 if ph == 0 else 250
		ai.compute_order(ph == 0)
		for pass_no in 2:
			Mem.w8(0x500c47, pass_no)
			var k := 0
			while result == 0 and k < 250 and not _stopped():
				var u: BUnit = null
				for i in range(lo, hi):
					var x := units[i]
					if x.state == 2 and x.order == k and x.ai != 7 and (x.flags & 6) == 0:
						u = x
						break
				if u != null:
					set_current(u)
					if Rules.can_use_skill(u) == 1:
						Rules.set_attack_mode(2, Rules.pick_skill(u))
					await ai.act(u)
					Rules.set_attack_mode(0)
					if u.flags & 2:
						await unit_acted(u)
					await post_action()
					if extra_action(u):
						k -= 1
					else:
						if free_action(u):
							k -= 1
						while Mem.r8(0x500e9c) != 0:
							var n := Mem.r8(0x500e9c) - 1
							Mem.w8(0x500e9c, n)
							free_action(units[Mem.r8(0x500e9d + n)])
					if result == 0 and u.flags & 2:
						await view.ensure_visible(u.pos)
						await checkpoint()
				if Mem.r32(B + 0x504) != 0:
					ai.compute_order(ph == 0)
					Mem.w32(B + 0x504, 0)
					k = 0
					continue
				k += 1
		Mem.w8(0x500c47, 2)


## BattleEnd 0x44ebe8: after a victory every army member's unit in slots 0..34 on the map gets 功勋 (4 per remaining
## round, all five abilities) and a won battle (+0x28); then 功勋 pooling (0x408fa0).
func _battle_end(bonus: int) -> void:
	if result != 2:
		return
	for i in 35:
		var u := units[i]
		if u.state != 2 or u.pid < 0 or not Game.is_member(u.pid):
			continue
		var p := u.person
		if u.pid < 0x66:
			for s in 5:
				_merit_gain(u, s, bonus)
		Mem.w8(p.base + 0x28, mini(Mem.r8(p.base + 0x28) + 1, 255))
	# 0x408fa0 (EV 4047 功勋分配模式): persons 0..101 move the 功勋 of every ability whose +0x02 bit is clear to the
	# shared pool EV 4048
	if Rules.ev(4047) != 0:
		for pid in 102:
			var pb := Mem.person_addr(pid)
			for s in 5:
				if (Mem.r8(pb + 2) >> s) & 1 == 0:
					var a := 0x508000 + 10 * pid + 2 * s
					Mem.w32(Mem.EV + 4 * 4048, Rules.ev(4048) + Mem.r16(a))
					Mem.w16(a, 0)


## The person's 功勋 store (0x42acd2): 0x508000 + 10·person for persons < 0x66 not marked 0xff (+0x2a); else −1.
static func merit_store(pid: int) -> int:
	if pid < 0 or pid >= 0x66 or Mem.r8(Mem.person_addr(pid) + 0x2a) == 0xff:
		return -1
	return 0x508000 + 10 * pid


## 功勋 gain 0x42aa0b → 0x42ab8e(n, store, person, s) (not when the raw ability is 0xff): n, doubled during a 围攻
## (byte 0x500e9a = 1) unless byte EV[4087] ≠ 0 — then nothing at all with byte EV[4055] ≠ 0 —, plus 获得功勋
## (QueryAny 69, 0x3a), plus n again with 精进 (0x501b00 of the person's unit); the word wraps.
func _merit_gain(u: BUnit, s: int, n: int) -> void:
	var a := merit_store(u.pid)
	if a < 0 or Mem.r8(Mem.person_addr(u.pid) + 0x21 + s) == 0xff:
		return
	var m := n
	if Mem.r8(Rules.ATTACK_MODE) == 1:
		if Rules.evb(4087) == 0:
			m = 2 * n
		elif Rules.evb(4055) != 0:
			return
	m += Effects.any(u.pid, 0x45, 0x3a, 1, 0)
	var su := unit_of_person(u.pid)
	if su != null and Mem.r8(0x501b00 + su.slot) != 0:
		m += n
	Mem.w16(a + 2 * s, Mem.r16(a + 2 * s) + m)


## 功勋 conversion 0x423f4b(store, person, s): while byte EV[4074] ≠ 0 and bit s of person +2 is set, a raw ability
## below 110 whose 功勋 covers the cost (0x42ac8f: raw < 80 → 50, else (raw − 79)·10 + 55) gains one point and the
## stat is recalculated with its display (0x43a409); further points only while byte 0x501a74 ≠ 0.
func merit_convert(pid: int, s: int) -> void:
	var a := merit_store(pid)
	if a < 0:
		return
	var pb := Mem.person_addr(pid)
	while Rules.evb(4074) != 0 and (Mem.r8(pb + 2) >> s) & 1 != 0:
		var raw := Mem.r8(pb + 0x21 + s)
		if raw >= 0x6e:
			return
		var cost := 50 if raw < 80 else (raw - 79) * 10 + 55
		if Mem.r16(a + 2 * s) < cost:
			return
		Mem.w16(a + 2 * s, Mem.r16(a + 2 * s) - cost)
		Mem.w8(pb + 0x21 + s, raw + 1)
		await _stat_up(pid, s)
		if Mem.r8(0x501a74) == 0:
			return


## 0x42ab32: conversions after an attack — attacker (mode 0) 武力, 敏捷, 运气; target (mode 1) 统率, 敏捷 (0x41a139).
func merit_after_attack(u: BUnit, target_side: bool) -> void:
	if u == null:
		return
	for s in ([1, 3] if target_side else [0, 3, 4]):
		await merit_convert(u.pid, s)


## 0x41d238: conversions after a strategy — 智力, and 运气 too for a strategy target (0x41a13e).
func merit_after_strategy(u: BUnit, also_luck: bool) -> void:
	if u == null:
		return
	await merit_convert(u.pid, 2)
	if also_luck:
		await merit_convert(u.pid, 4)


const STAT_UP := ["武力上升", "统率上升", "智力上升", "敏捷上升", "运气上升"]


## 0x43a409(person, s, show): the stat recalculated (Person.recalc); in a battle with byte EV[4022] = 0 the person's
## unit gets the buff of that stat raised (0x414361: below 3 → 3, else 6, with its animation); SE 11 and
## "%s的%s了" (0x48c538). [G] The battle box 0x419b92 also shows the grade change (0x4781c6); the port shows the
## line in the style-2 message box (what the original uses when byte EV[4087] ≠ 0).
func _stat_up(pid: int, s: int) -> void:
	var p := Game.person(pid)
	p.recalc(s)
	if Rules.evb(4022) == 0:
		var u := unit_of_person(pid)
		if u != null and u.state == 2:
			await unit_attr_op(u, s, 3 if u.buff(s) < 3 else 6, true)
	Audio.se(11)
	await ui_message(2, "%s的%s了" % [TextExpand.display_name(pid), STAT_UP[s]])


# ------------------------------------------------------------------ action bookkeeping
## CurrentUnit 0x406240: the acting unit (pending 大杀四方 bit cleared).
func set_current(u: BUnit) -> void:
	current_unit = u
	u.set_byte(0x24, u.byte(0x24) & 0x7f)
	Mem.w16(CUR_PERSON, u.pid)
	Mem.w8(Rules.CUR_UNIT, u.slot)


## UnitActed 0x45b609: event context {person, x, y} and a poll.
func unit_acted(u: BUnit) -> void:
	if result != 0 or u.state != 2:
		return
	current_unit = u
	await checkpoint()


## PostAction 0x42bc14: units with HP 0 leave the map (0x40502b), then 反弹异常攻击 holders shed ailments and debuffs.
func post_action() -> void:
	for u in units:
		if u.state == 2 and u.hp == 0:
			await remove_unit(u, false, false)
	for u in units:
		if u.state == 2 and u.hp != 0 and u.eff(0x12, 0x2a, 1, 1) != 0:
			if u.status != 0:
				u.status = 0
			for b in 6:
				if u.buff(b) < 3:
					u.set_buff(b, 3)
	refresh_units()


## ExtraAction 0x41b508 (大杀四方): a pending restore (+0x24 bit 7) gives the unit its action back.
func extra_action(u: BUnit) -> bool:
	var v := u.byte(0x24)
	if v & 0x80:
		v &= 0x7f
		if u.state == 2:
			v = (v + 1) & 0xff
			u.set_byte(0x24, v)
			reenable(u)
		else:
			u.set_byte(0x24, v)
		return true
	return false


## FreeAction 0x412d52 (二次行动): once per phase (0x508b00[slot]).
func free_action(u: BUnit) -> bool:
	if u.pid >= 0 and u.hp != 0 and Mem.r8(0x508b00 + u.slot) == 0 and u.eff(0x38, 0x5a, 1, 1) != 0:
		reenable(u)
		Mem.w8(0x508b00 + u.slot, 0xff)
		return true
	return false


## 0x412d9d: the unit may act again.
func reenable(u: BUnit) -> void:
	u.flags = u.flags & ~6
	refresh_units()


# ------------------------------------------------------------------ side upkeep (0x44ee30)
## Start of the player phase (side 0: slots 0..59) or the enemy phase (side 1: 60..249).
func side_upkeep(s: int) -> void:
	var lo := 0 if s == 0 else 60
	var hi := 60 if s == 0 else 250
	_added_countdown(s)
	for i in range(lo, hi):
		await _status_recovery(units[i])
		await _buff_decay(units[i])
	var olo := 60 if s == 0 else 0
	var ohi := 250 if s == 0 else 60
	for j in range(olo, ohi):
		Mem.w8(Rules.HITS + j, 0)
	for i in range(lo, hi):
		await _poison(units[i])
	for i in range(lo, hi):
		await _regen(units[i])
	refresh_units()


## 0x42fc0c: 附加技能 count-down; a side's entries count at its own phase start, persons without a unit at both;
## the last turn ends only with the buff-fade roll.
func _added_countdown(ph: int) -> void:
	var p := Effects.ADDED
	var guard := 0
	while guard < 0x400:
		guard += 1
		if Mem.r8(p) == 0xff:
			if Mem.r8(p + 1) == 0xff:
				return
			p += 2
		var turns := Mem.r8(p + 1)
		if turns != 0 and turns < 100:
			var u := unit_of_person(Mem.r16(p + 2))
			var dec := true
			if u != null:
				if (u.side() & 1) == ph:
					dec = false
				elif turns == 1 and not Rules.chance2(Rules.recovery_chance(u, 0), 1):
					dec = false
			if dec:
				Mem.w8(p + 1, turns - 1)
		p += 4


## StatusRecovery 0x4263b0: a same-side 健康光环 neighbour cures everything, else each ailment ticks (0x42402c).
func _status_recovery(u: BUnit) -> void:
	if u.state != 2 or u.status == 0:
		return
	for d in Rules.DIR8:
		var n := Rules.unit_at(u.pos + d)
		if n != null and n.state == 2 and n.side() == u.side() and n.eff(0x64, 0x7b, 1, 1) != 0:
			await unit_attr_op(u, 6, 0x9e, true)      # 0x45aa37(person, 6, 0x9e, 1, slot): cure all, animated
			return
	await status_tick(u, Rules.recovery_chance(u, 1))


## Ailment tick 0x42402c(u, p), per field (麻痹, 禁咒, 混乱, 中毒): p ≥ 100 cures; a counter above 1 counts down; at 1
## it ends by byte EV[4023] (0: Chance(p, 0); 1: the deck 0x455e25(0x501bf5, 1) — row 1 with the cursor 0x501bf6 —
## cures when p ≥ the card; else always). A cure goes through 0x45aa37(person, 6, mask | 0x80, 1) with its animation.
func status_tick(u: BUnit, p: int) -> void:
	for f in 4:
		var mask := 2 << f
		var v := u.status_count(mask)
		if v == 0:
			continue
		var cure := false
		if p >= 100:
			cure = true
		elif v != 1:
			u.status = (u.status & ~(3 << (2 * f))) | ((v - 1) << (2 * f))
		else:
			match Rules.evb(4023):
				0: cure = Rules.chance2(p, 0)
				1: cure = p >= Rules.deck(Rules.DOOM_CUR + 1, 1)
				_: cure = true
		if cure:
			await unit_attr_op(u, 6, mask | 0x80, true)


## BuffDecay 0x43c940: levels 5/6 count down, 4 wears off with the fade chance, debuffs recover (0 → 1 → 2 directly,
## 2 → 3 by chance); the returns to 3 go through 0x45aa37 with their animation. Then the 精进 timer (player kind:
## 1 ends by chance with Meff 0x2f) and the 反間計 control counter (slots ≥ 60: 1 ends with Meff 0x2c, 0x4073bc).
func _buff_decay(u: BUnit) -> void:
	if u.state != 2:
		return
	var a := Rules.recovery_chance(u, 0)
	var b := Rules.recovery_chance(u, 1)
	for k in 6:
		var lv := u.buff(k)
		if lv == 3:
			continue
		if lv >= 5:
			u.set_buff(k, lv - 1)
		elif lv == 4:
			if Rules.chance2(a, 1):
				await unit_attr_op(u, k, 3, true)
		elif b == 100:
			await unit_attr_op(u, k, 3, true)
		elif lv < 2:
			u.set_buff(k, lv + 1)
		elif Rules.chance2(b, 0):
			await unit_attr_op(u, k, 3, true)
	if u.kind == 0:
		var c := Mem.r8(0x501b00 + u.slot)
		if c > 1:
			Mem.w8(0x501b00 + u.slot, c - 1)
		elif c == 1 and Rules.chance2(a, 1):
			await unit_meff(u, 0x2f)
			Mem.w8(0x501b00 + u.slot, 0)
	if u.slot >= 60:
		var c2 := Mem.r8(0x501ad8 + u.slot)
		if c2 > 1:
			Mem.w8(0x501ad8 + u.slot, c2 - 1)
		elif c2 == 1:
			if Rules.chance2(100, 0):
				await unit_meff(u, 0x2c)
				release_control(u)


## 0x427cbc(n): Meff n on the unit when it is in view, then its redraw.
func unit_meff(u: BUnit, n: int) -> void:
	var cells: Array[Vector2i] = [u.pos]
	await strategy.script_anim(n, cells, [], 0x40)
	refresh_units()


## 0x4073bc(u, 0): the 反間計 control ends (counter 0, kind − 3, AI code 1) — both changes are undone whatever the
## EV 4078 mode applied.
func release_control(u: BUnit) -> void:
	Mem.w8(0x501ad8 + u.slot, 0)
	u.kind = (u.kind - 3) & 0xff
	u.ai = 1


## Poison 0x44e024(u, 20, show): max(MaxHP·20 %, 1), never below 1 HP; the view centres on the unit and the result
## window shows the loss (0x450986(0, slot, −1, d, …, 1)) before it is written.
func _poison(u: BUnit) -> void:
	if u.state != 2 or not u.poisoned():
		return
	var d := maxi(u.max_hp() * 20 / 100, 1)
	if u.hp <= d:
		d = u.hp - 1
	await scroll_cell(u.pos)
	await result_panel(u, 0, d, 0, 0, 0, 0, true)
	u.hp = u.hp - d
	refresh_units()


## Regen 0x43cddd: auras and automatic buffs, terrain / 特效 HP and MP recovery (halved under poison), SP, and the
## per-turn EXP of player units.
func _regen(u: BUnit) -> void:
	if u.state != 2:
		return
	await strategy.turn_auras(u)
	await _auto_buffs(u)
	var maxhp := u.max_hp()
	var t := Rules.regen_pct(u.pos)
	var hp := maxhp * t / 100 + maxhp * u.eff(0, 0x25, 0, 0) / 100
	var mp := t + u.eff(1, 0x1b, 0, 0) + u.eff(0x32, 0x44, 0, 0)
	if u.poisoned():
		hp >>= 1
		mp >>= 1
	if hp > 0 and u.hp + hp > maxhp:
		hp = maxhp - u.hp
	var sp_gain := 0
	var sp := u.eff(0x69, 0, 0, 0)
	if sp:
		sp_gain = Rules.add_sp(u.pid, sp, true)
	if mp > 0 and u.mp + mp > u.max_mp():
		mp = u.max_mp() - u.mp
	var g := [0, 0, 0]
	if u.kind == 0:
		var bonus := 100 + (u.person.equip_bonus(8) & 0xff)
		for k in 3:
			g[k] = u.eff(3 + k, [0x1d, 0x73, 0x73][k], 0, 0) * bonus / 100
	# 0x43cf26: any gain → the view centres on the unit and the result window (kind = the SP gain, else 0x100)
	if hp > 0 or mp > 0 or g[0] > 0 or g[1] > 0 or g[2] > 0 or sp_gain > 0:
		await scroll_cell(u.pos)
		await result_panel(u, sp_gain if sp_gain != 0 else 0x100, -hp, -mp, g[0], g[1], g[2], true)
	u.hp = u.hp + hp
	u.mp = u.mp + mp
	refresh_units()
	if g[0] > 0:
		await actions.set_exp(u, g[0])
	if g[1] > 0:
		await actions.equip_exp(u, 0, g[1])
	if g[2] > 0:
		await actions.equip_exp(u, 1, g[2])


## AutoBuffs 0x43d038: 自动提升 rows 0x90..0x96 (QueryAny(0x90 + i, 0x66, 3, 0), stat masks); 0x3f sets all six
## to 6 when any is below 4 (Meff 0x26) and stops; other bits raise each such stat below 4 through 0x414361 (below 3
## → 3, else 6, animated).
func _auto_buffs(u: BUnit) -> void:
	for i in 7:
		var v := u.eff(0x90 + i, 0x66, 3, 0) & 0xff
		if v == 0:
			continue
		if v == 0x3f:
			for j in 6:
				if u.buff(j) < 4:
					for k in 6:
						u.set_buff(k, 6)
					await unit_meff(u, 0x26)
					return
			return
		for j in 6:
			if (v >> j) & 1 and u.buff(j) < 4:
				await unit_attr_op(u, j, 3 if u.buff(j) < 3 else 6, true)


## 0x40ec9d: the 10 timed map objects of 纵火 / 修筑 (0x501ae2: x, y, timer; 0xff free) count down and vanish at 0.
func _tick_map_objects() -> void:
	for i in 10:
		var a := 0x501ae2 + 3 * i
		var t := Mem.r8(a + 2)
		if t == 0xff:
			continue
		if t == 0:
			strategy.remove_map_object(Vector2i(Mem.r8(a), Mem.r8(a + 1)))
			Mem.w8(0x501ae1, Mem.r8(0x501ae1) - 1)
			Mem.w16(a, 0xffff)
		Mem.w8(a + 2, t - 1)


## Weather 0x449f91: w < 6 sets the level, else a random step (rand(8)).
func _weather_step(w: int) -> void:
	var before := Rules.weather()
	if w < 6:
		weather_level = w
	else:
		var r := Rules.rand(8)
		var c := (weather_level + 1) & 0xff
		if c > r:
			c -= 1
		elif c != r:
			c += 1
		weather_level = 5 if c == 0 else (0 if c == 7 else c - 1)
	if Rules.weather() != before:
		hud.weather_changed()
	hud.queue_redraw()


func weather() -> int:
	return Rules.weather()


func set_weather(w: int) -> void:
	_weather_step(w)


# ------------------------------------------------------------------ units: lookup
func unit_at(c: Vector2i, exclude: BUnit = null) -> BUnit:
	var u := Rules.unit_at(c)
	if u != null and u == exclude:
		return null
	return u


## 0x43e4d6: the first slot holding the person (any state), or null.
func unit_of_person(pid: int) -> BUnit:
	for u in units:
		if u.pid == pid:
			return u
	return null


func unit_by_pid(pid: int) -> BUnit:
	return unit_of_person(pid)


## Unit selector 0x41b882 (+ 0x456079): v ≥ 0x404 → unit v − 0x404 (null if empty); EV 4031 → v < 250 is a unit
## index; else the first unit with that person and state ≠ 0.
func unit_sel(v: int) -> BUnit:
	if v >= 0x404 or (Rules.evb(4031) != 0 and (v & 0xffff) < 250):
		var s := (v - 0x404 if v >= 0x404 else v) & 0xff
		if s >= 250 or units[s].pid < 0:
			return null
		return units[s]
	for u in units:
		if u.pid == v and u.state != 0:
			return u
	return null


## Selector 0x400..0x402 → the current unit (0x4d, 0x52, 0x53).
func unit_sel_cur(v: int) -> BUnit:
	if v >= 0x400 and v <= 0x402:
		return current_unit
	return unit_sel(v)


## 0x45b50a: does the selector match the unit on the cell (state 2, HP > 0)? 0x400 any, 0x401 home side 1, 0x402
## not side 1, ≤ 0x403 that person, ≥ 0x404 that unit index.
func sel_matches_cell(sel: int, c: Vector2i) -> bool:
	return _sel_matches_unit(sel, Rules.unit_at(c))


func _sel_matches_unit(sel: int, u: BUnit) -> bool:
	if u == null or u.state != 2 or u.hp == 0:
		return false
	match sel:
		0x400: return true
		0x401: return Movement.home_side(u) == 1
		0x402: return Movement.home_side(u) != 1
	if sel < 0x404:
		return u.pid == sel
	return ((sel - 4) & 0xff) == u.slot


func _entry(j: int) -> int:
	return DEPLOY + 16 * j


## The deployment entry of a unit (0x4103cd, else the first entry with its person).
func entry_of(u: BUnit) -> int:
	for j in 250:
		if Mem.r16(_entry(j)) == u.pid:
			return _entry(j)
	return -1


## Side codes of CountUnits (0x44cb12).
func side_match(u: BUnit, side: int) -> bool:
	return Rules.kind_matches(u, side)


func units_for(pid: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for u in units:
		if u.active() and sel_matches_cell(pid, u.pos):
			out.append(u)
	return out


# ------------------------------------------------------------------ units: placing, removing
## Nearest free cell 0x43f07c(c0, unit, mode): c0 if free (mode 0; mode 1 goes straight to the scan), else its 4
## neighbours; the probe then steps up, right, down, left (each step trying the cell and its neighbours); failing
## that the free cell of least Manhattan distance (first in row order), in mode 1 only among the cells the last
## flood reached. Nothing: mode 0 → c0, mode 1 → (0xff, 0xff).
func nearest_free(c0: Vector2i, u: BUnit, mode := 0) -> Vector2i:
	var c := c0
	for k in 4:
		if Rules.in_map(c):
			if _cell_ok(c, u):
				if mode == 0:
					return c
				break
			for d in Rules.DIR4:
				var n: Vector2i = c + d
				if Rules.in_map(n) and _cell_ok(n, u):
					return n
		c = c + Rules.DIR4[k]
	var best := Vector2i(-1, -1)
	var bd := 0xffff
	for y in Rules.map_h():
		for x in Rules.map_w():
			var p := Vector2i(x, y)
			if (mode == 0 or Movement.grid_at(p) != 0xff) and _cell_ok(p, u):
				var dd := absi(c0.y - y) + absi(c0.x - x)
				if dd < bd:
					bd = dd
					best = p
	if best.x >= 0:
		return best
	return c0 if mode == 0 else Vector2i(0xff, 0xff)


## 0x41c2e6: empty and passable for the unit (0x45936d).
func _cell_ok(c: Vector2i, u: BUnit) -> bool:
	return Rules.slot_at(c) == 0xff and Rules.move_cost(u, Rules.terrain_at(c)) < 0xfe


## Place 0x442b03(u, x, y, mirror, hidden): a hidden unit stays off the map; a unit already on the map is moved to
## (x, y) as given; otherwise it appears at the nearest free cell.
func place(u: BUnit, c: Vector2i, hidden: bool) -> void:
	if hidden:
		return
	if u.state == 2:
		u.pos = c
	else:
		u.pos = Vector2i(0xff, 0xff)
		u.state = 2
		u.pos = nearest_free(c, u)
	BUnit.gen += 1


## UnitInit 0x44274c(u, person, flags, x, y, keep): person, state 1, kind from flags & 3, facing from the
## direction bits, full HP / MP, buffs 3, no ailment, placed; unless `keep` the battle counters of the person
## (sorties +1 for members, else zeroed).
func unit_init(u: BUnit, pid: int, flags: int, c: Vector2i, keep: bool) -> void:
	u.state = 1
	u.pid = pid
	Mem.w32(u.addr, pid)
	u.kind = (3 if flags & 2 else 2) if flags & 1 else (1 if flags & 2 else 0)
	u.dir = 1 if flags & 8 else (3 if flags & 0x10 else (0 if flags & 0x20 else 2))
	u.hp = u.max_hp()
	u.mp = u.max_mp()
	for i in 6:
		u.set_buff(i, 3)
	u.status = 0
	place(u, c, (flags & 4) != 0)
	if not keep:
		var p := u.person
		if not Game.is_member(pid):
			Mem.w8(p.base + 0x27, 0)
			Mem.w8(p.base + 0x28, 0)
			Mem.w8(p.base + 0x29, 0)
		else:
			Mem.w8(p.base + 0x27, mini(Mem.r8(p.base + 0x27) + 1, 255))


## Direction bits of an entry's flags (0x449b29): 0 → 0x20, 1 → 8, 3 → 0x10, else 0x40.
static func dir_bits(d: int) -> int:
	match d & 0xff:
		0: return 0x20
		1: return 8
		3: return 0x10
	return 0x40


## RemoveUnit 0x441744(u, silent, anim): the retreat line (+0x1f, player units), the leaving animation, off the
## map (state 3), ailments cleared, retreat count of army members; units that targeted it with AI code 0 / 4 turn
## to code 1.
func remove_unit(u: BUnit, silent: bool, anim := false) -> void:
	if u.state != 2:
		return
	if not silent:
		if u.byte(0x1f) != 0 and u.kind == 0:
			await _retreat_line(u)
	await actions.retreat_animation(u, silent, anim or u.pid == 0)
	u.state = 3
	if not silent and Game.is_member(u.pid):
		var pb := u.person.base
		if Mem.r8(pb + 0x29) != 0xff:
			Mem.w8(pb + 0x29, Mem.r8(pb + 0x29) + 1)
	u.status = 0
	u.extra.erase("dying")
	for o in units:
		if o.target == u.slot and o.ai in [0, 4]:
			o.target = 0xff
			o.ai = 1
	refresh_units()
	unit_died.emit(u)


## Retreat line 0x40c00f: persons < 49 say Imsg record 0x99a + person through the battle talk 0x45965d.
func _retreat_line(u: BUnit) -> void:
	var line := Game.text(0x99a + u.pid) if u.pid >= 0 and u.pid < 49 else ""
	if line == "":
		return
	await battle_talk(u.pid, line)


## Revive 0x4092c0(person or selector, x, y, dir): a unit not on the map re-enters at (x, y) (x = 0xff: its
## deployment position) with UnitInit keep = 1; SP reset unless EV 4095 (0x4277a9).
func revive(u: BUnit, x: int, y: int, d: int) -> void:
	if u == null or u.state == 2:
		return
	var e := entry_of(u)
	if e < 0:
		return
	_reenter_reset(u)
	var f := Mem.r8(e + 8)
	if (x & 0xff) == 0xff:
		x = Mem.r8(e + 4)
		y = Mem.r8(e + 5)
		f &= 0x93
	else:
		f = (f & 0x83) | dir_bits(d)
	Mem.w8(e + 8, f)
	unit_init(u, u.pid, f, Vector2i(x, y), true)
	Audio.play_se(SoundMap.se_name(0xf))
	await view.center_on(u.pos)
	refresh_units()


## 0x4277a9: SP 0 unless EV 4095; a unit with HP 0 gets its roll accumulators back; enemy slots clear 0x501b14.
func _reenter_reset(u: BUnit) -> void:
	if Rules.evb(4095) == 0:
		Mem.w8(Mem.SP + u.pid, 0)
	if u.hp == 0:
		Rules.reset_acc(u.slot)
	if u.slot >= 60:
		Mem.w8(0x501b14 + u.slot - 60, 0)


## 0x409229: a hidden unit appears at its entry's position (nearest free cell), SE 15, camera.
func appear(u: BUnit, e: int) -> void:
	var c := Vector2i(Mem.r8(e + 4), Mem.r8(e + 5))
	place(u, c, false)
	Audio.play_se(SoundMap.se_name(0xf))
	refresh_units()
	await view.center_on(u.pos)
	if u.node and not Game.autoplay:
		u.node.fade = 0.0
		var tw := u.node.create_tween()
		tw.tween_property(u.node, "fade", 1.0, 0.3)
		await tw.finished
	await wait(0.2)


# ------------------------------------------------------------------ battle setup (BattleStart 0x44d2ca)
## Touch shell: at the player phase's top level (no unit selected) its 菜单 is the right click there.
func menu_ready() -> bool:
	return input != null and input.idle


## The touch shell's 菜单 / Android back: the system menu even when a unit is under the cursor (a right click there
## would open its 武将情报).
func open_menu() -> void:
	if menu_ready():
		input.request_menu()


## op 0x27 in a battle file: mode 3 creates the battlefield (map = a4 (0xffff → 99) + 100·EV 4051, EV 4051 consumed).
func op_change_scene(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 3:
		var v := arg(ins, 4)
		if v == 0xffff:
			v = 99
		v += (Rules.evb(4051)) * 100
		Mem.w32(Mem.EV + 4 * 4051, 0)
		Mem.w16(0x510cfe, v)
		await create_battlefield(v)
	else:
		# a story picture inside a battle file (rare; eex.md §11.4): stored byte + 256·EV 4027
		var v2 := 0
		match mode:
			0: v2 = 0 if arg(ins, 1) == 0xffff else arg(ins, 1)
			1:
				if arg(ins, 2) == 0: v2 = 114
				elif arg(ins, 1) != 0xffff: v2 = arg(ins, 1)
				else: v2 = 114 if arg(ins, 3) == 0xffff else arg(ins, 3) + 40
			2: v2 = 0 if arg(ins, 3) == 0xffff else arg(ins, 3)
		var entry := (v2 & 0xff) + 256 * Rules.evb(4027)
		var idx: Variant = Assets.json("gfx/backgrounds/index.json")
		if idx is Dictionary:
			for im in idx.get("images", []):
				if int(im.get("entry", -1)) == entry:
					hud.show_picture(Assets.tex("gfx/backgrounds/" + str(im["file"])))
					break


func create_battlefield(id: int) -> void:
	map_id = id
	Rules.srand(_battle_seed())
	Mem.w8(Mem.GS + 5, Mem.r8(B))
	Mem.w8(0x4b4234, 0)
	Mem.w8(B + 5, 0)
	Mem.w16(B + 1, 0)
	Mem.w32(B + 8, 0)
	Mem.w32(B + 0xc, 0)
	Mem.w8(B + 0x10, 0)
	Mem.w32(B + 0x4fc, 0)
	Mem.w32(B + 0x500, 0)
	Mem.w8(B + 0x11, Mem.r8(0x496e21))
	Mem.w8(B + 4, Mem.r8(0x496e22))
	Mem.w8(0x501ae1, 0)
	Mem.fill(0x501ae2, 0x1e, 0xff)
	Mem.w8(B + 3, Mem.r8(READER + 0x3d0e))
	view.load_map(id)
	Mem.fill(0x4b3d21, 0x4e2, 0xff)
	Mem.w32(CUR_PERSON, 0)
	Mem.w32(CUR_PERSON + 4, 0xffff)
	for u in units:
		if u.node:
			u.node.queue_free()
			u.node = null
		_reset_unit(u)
	_create_units()
	for u in units:
		u.flags = u.flags & ~0x80
		u.status = 0
		if u.slot < 60 and u.state != 0 and (u.kind if u.kind <= 6 else 0) == 0:
			u.ai = 7
	field_ready = true
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("battlefield map=%d sortie=%s" % [id, sortie_list()])
		for u in units:
			if u.exists():
				print("  slot %d pid %d %s state %d pos %s hp %d/%d ai %d lv %d cls %d kind %d" % [u.slot, u.pid, u.person.name, u.state, u.pos, u.hp, u.max_hp(), u.ai, u.level(), u.cls(), u.kind])
	refresh_units()
	refresh_pictures()
	hud.visible = true
	var lead := units[0]
	if lead.state == 2:
		view.center_on(lead.pos, false)


## The original seeds the RNG with GetTickCount at each battle start (0x42c228); deterministic autoplay keeps
## a fixed seed per scenario.
func _battle_seed() -> int:
	if Game.autoplay and OS.get_environment("WG_RANDOM") == "":
		return 1 + Game.scenario
	return Time.get_ticks_msec() & 0x7fffffff


## 0x47d0bc (per slot, via 0x435a8d): empty record; the AI point (+9/+0xa) and the order byte are kept.
func _reset_unit(u: BUnit) -> void:
	var a := u.addr
	Mem.w8(a + 4, u.slot)
	Mem.w8(a + 0xc, 0)
	Mem.w8(a + 0x2f, 0)
	Mem.w16(a + 0xd, 0)
	Mem.w32(a, 0xffff)
	Mem.w16(a + 6, 0xffff)
	Mem.w8(a + 8, 0xff)
	Mem.w32(a + 0x20, 0xffff)
	Mem.w8(a + 0x1f, 1)
	u.extra = {}
	BUnit.gen += 1


## CreateUnits 0x43bb15: the entries in order fill player slots from 0, friends from 20, enemies from 60; army
## members deployed as friends keep their data (UnitInit 0x40c990), everybody else is generated (0x42ad35); AI
## orders through SetAI (refused for army members).
func _create_units() -> void:
	var np := 0
	var nf := 20
	var ne := 60
	for j in 250:
		var e := _entry(j)
		var pid := Mem.r16(e)
		if pid == 0xffff:
			continue
		var f := Mem.r8(e + 8)
		var c := Vector2i(Mem.r8(e + 4), Mem.r8(e + 5))
		var slot := 0
		if f & 3 == 0:
			if np >= 250:
				continue
			_unit_init_upgrade(units[np], pid, f, c)
			np += 1
			continue
		if (f & 1) == 0 and (f & 2) != 0:
			slot = nf
			nf += 1
			if Game.is_member(pid):
				_unit_init_upgrade(units[slot], pid, f, c)
			else:
				_generate(units[slot], f, e, pid, c)
		else:
			slot = ne
			ne += 1
			_generate(units[slot], f, e, pid, c)
		if slot < 250:
			set_ai(units[slot], Mem.r8(e + 0xc), Mem.r16(e + 0xe), Mem.r8(e + 0xe), Mem.r8(e + 0xf))


## 0x40c990: UnitInit plus the EV 4039 equipment auto-upgrade.
func _unit_init_upgrade(u: BUnit, pid: int, f: int, c: Vector2i) -> void:
	if u.slot >= 250:
		return
	unit_init(u, pid, f, c, false)
	if Rules.evb(4039) == 0:
		return
	var p := u.person
	var avg := _army_avg_level()
	for k in 2:
		var iid := Mem.r8(p.base + 0x2e + 3 * k)
		if iid == 0xff:
			continue
		var it := Game.item(iid)
		var maxl := Person.max_item_level(it)
		var target := Person.auto_level_at(it, avg)
		if not Person.is_treasure(it):
			var first := Mem.r8(0x482427 + (int(it["type"]) >> 1)) + avg / 20
			if iid > first:
				continue
			if iid != first:
				target = maxl
		var cur := Mem.r8(p.base + 0x2f + 3 * k)
		if cur < target:
			Mem.w8(p.base + 0x2f + 3 * k, target)
			Mem.w8(p.base + 0x30 + 3 * k, Person.exp_at_level(target, maxl))


## Generate 0x42ad35: reload the person from Data.e5 (0x46206c), UnitInit, class tier and level (0x442890),
## equipment by the entry's codes (0x44299b), full HP / MP.
func _generate(u: BUnit, f: int, e: int, pid: int, c: Vector2i) -> void:
	if u.slot >= 250:
		return
	Game.reset_person(pid)
	unit_init(u, pid, f, c, false)
	_promote_deploy(u.person, Mem.r8(e + 2), Mem.r8(e + 3))
	var p := u.person
	p.equip_code(0, Mem.r8(e + 9), Mem.r8(e + 6))
	p.equip_code(1, Mem.r8(e + 0xa), Mem.r8(e + 7))
	p.equip_code(2, Mem.r8(e + 0xb), 0xff)
	u.hp = p.max_hp()
	u.mp = p.max_mp()


## 0x442890(promo, level): promo 1 → one tier up from level 15; 2 → one tier from 15, two from 30 (classes < 60,
## the same family, 0x422e07); level set; every stat and HP/MP + its growth sum (0x408a60) on the Data.e5 values.
func _promote_deploy(p: Person, promo: int, lvl: int) -> void:
	var c := p.cls
	if c < 60:
		var n := 0
		if promo == 1 and lvl > 14:
			n = 1
		elif promo == 2:
			n = 2 if lvl >= 30 else (1 if lvl > 14 else 0)
		while n > 0:
			if Game.family_of(c + n) == Game.family_of(c):
				p.cls = c + n
				break
			if n < 2:
				break
			n -= 1
	p.level = lvl
	for i in 7:
		var g := p.growth_sum(i)
		p.add_stat(i, g)


## SetAI 0x459d95(unit, mode, target person, x, y): modes 0..7 → code by table 0x48e379 (3 1 2 0 0 4 4 7); refused
## for army members; 3 / 5 set the target unit, 4 / 6 the point (inside the map).
func set_ai(u: BUnit, m: int, tperson: int, tx: int, ty: int) -> bool:
	if u == null or u.pid < 0:
		return false
	if m >= 0x80 or m >= 8 or Game.is_member(u.pid):
		return false
	u.flags = u.flags & ~0x80
	u.target = 0xff
	u.ai = Mem.r8(0x48e379 + m)
	if m == 3 or m == 5:
		var t := unit_sel(tperson)
		if t != null:
			u.target = t.slot
	elif m == 4 or m == 6:
		if tx < Rules.map_w() and ty < Rules.map_h():
			u.point = Vector2i(tx, ty)
			u.target = 0xff
	return true


## The sortie list u16[] @0x48b350 (0xffff-terminated).
func sortie_list() -> Array[int]:
	var out: Array[int] = []
	for k in 20:
		var v := Mem.r16(SORTIE + 2 * k)
		if v == 0xffff:
			break
		out.append(v)
	return out


# ------------------------------------------------------------------ deployment ops
## op 0x44 battle_init (0x4121e2): pages reset, hit counters and 二次行动 bytes cleared, flags 0..255 cleared
## (0x40c6cc), entries 0..19 = the sortie
## list, the rest empty; accumulators = EV 4017; visibility map cleared; sortie lists reset (0x41c96d).
func op_battle_init(_ins: Dictionary) -> void:
	Mem.w16(0x500ad4, 0)
	Mem.w8(Mem.person_addr(0x3ff) + 0x19, 0)
	Mem.fill(0x508a00, 0x200, 0)
	for i in 256:
		Mem.set_flag(i, false)
	var ended := false
	for j in 250:
		var e := _entry(j)
		var pid := 0xffff
		if j < 20 and not ended:
			var v := Mem.r16(SORTIE + 2 * j)
			if v == 0xffff:
				ended = true
			else:
				pid = v
		Mem.w32(e, pid)
		Mem.w32(e + 8, 0)
	Rules.reset_acc()
	Mem.fill(0x4934b0, 0x640, 0)
	Game.reset_sortie_params()


## op 0x45 battle_settings (0x4122c3).
func op_battle_settings(ins: Dictionary) -> void:
	var a0 := arg(ins, 0)
	var a3 := arg(ins, 3)
	if a3 == 0xffff:
		a3 = 0
	if a3 > 100:
		a3 = -(a3 - 100)
	var a8 := arg(ins, 8)
	var a9 := arg(ins, 9)
	Mem.w32(Mem.EV + 4 * 4057, 0xffff)
	Mem.w8(0x501bf4, a3)
	Mem.w8(0x496e21, 0 if a8 == 0xffff else a8)
	Mem.w8(0x496e22, 0 if a9 == 0xffff else a9)
	Mem.w8(READER + 0x3d0f, arg(ins, 1))
	Mem.w8(READER + 0x3d0e, arg(ins, 2))
	var a7 := arg(ins, 7)
	Mem.w16(READER + 0x3d0a, a7)
	Mem.w16(READER + 0x3d08, 1 if a7 != 0xffff else 0)
	var a5 := arg(ins, 5)
	Mem.w16(READER + 0x3d06, a5)
	Mem.w16(READER + 0x3d04, 1 if a5 != 0xffff else 0)
	Mem.w16(0x494fd0, 1 if a0 != 0 else 0)


## Deployment level 0x4123c8: base = mean of the top 4 sortie levels (0x4184dd) + i8 0x501bf4, at least 1;
## code ≤ 100 → min(base + code, 110); else max(base − (code − 100), 1).
func _deploy_level(code: int) -> int:
	var base := maxi(_sortie_level() + Mem.r8s(0x501bf4), 1)
	if code < 0x65:
		return mini((base & 0xff) + (code & 0xff), 110)
	var v := Rules.sat_sub(base & 0xff, (code + 0x9c) & 0xff)
	return v if v != 0 else 1


## 0x4184dd: average of the 4 highest levels in the sortie list (all of them if fewer).
func _sortie_level() -> int:
	var lv: Array[int] = []
	for pid in sortie_list():
		lv.append(Game.person(pid).level & 0xff)
	if lv.is_empty():
		return 0
	lv.sort()
	lv.reverse()
	var n := lv.size()
	var skip := maxi(n - 4, 0)
	var s := 0
	for i in n - skip:
		s += lv[i]
	return s / (n - skip)


## ops 0x46 / 0x47 (0x41240b): entry j of page p → entry 20 + 20p + j (allies) / 60 + 80p + j (enemies).
func _deploy_entries(ins: Dictionary, enemy: bool) -> void:
	var page_addr := 0x500ad5 if enemy else 0x500ad4
	var page := Mem.r8(page_addr)
	var lst: Array = ins["args"]
	var base := 60 + 80 * page if enemy else 20 + 20 * page
	for j in lst.size():
		var r: Array = lst[j]
		var v := func(k: int) -> int:
			if k >= r.size():
				return 0
			var x: Variant = r[k]
			if x is Dictionary:
				return Mem.ev(int(x.get("var", 0))) & 0xffff
			return int(x) & 0xffff
		var pid: int = v.call(0)
		if pid == 0xffff:
			continue
		var o := 1 if enemy else 0
		var reinf: int = v.call(1) if enemy else 0
		var hidden: int = v.call(1 + o)
		var x: int = v.call(2 + o)
		var y: int = v.call(3 + o)
		var d: int = v.call(4 + o)
		var lvc: int = v.call(5 + o)
		var promo: int = v.call(6 + o)
		var aim: int = v.call(7 + o)
		var tp: int = v.call(8 + o)
		var tx: int = v.call(9 + o)
		var ty: int = v.call(10 + o)
		if hidden == 0xffff: hidden = 0
		if reinf == 0xffff: reinf = 0
		if aim == 0xffff: aim = 1
		if lvc == 0xffff: lvc = 0
		if promo == 0xffff: promo = 2
		var idx := base + j
		if idx >= 250:
			continue
		var e := _entry(idx)
		Mem.w32(e, pid)
		Mem.w8(e + 4, x)
		Mem.w8(e + 5, y)
		var f := (4 if hidden != 0 else 0)
		if enemy:
			f |= 1 | (2 if reinf != 0 else 0)
		else:
			f |= 2
		Mem.w8(e + 8, f | dir_bits(d))
		# 0x4264c6: default codes from the person's Data.e5 record (0xff weapon/armour → 0 = class default),
		# levels 0xfe (= the code is an item id)
		var recs: Array = Assets.json("data/persons.json")
		var rec: Dictionary = recs[pid] if pid < recs.size() else {}
		var w := 0xff if rec.get("weapon") == null else int(rec["weapon"])
		var a := 0xff if rec.get("armor") == null else int(rec["armor"])
		var acc := 0xff if rec.get("accessory") == null else int(rec["accessory"])
		Mem.w8(e + 9, (w + 1) & 0xff if w == 0xff else w)
		Mem.w8(e + 0xa, (a + 1) & 0xff if a == 0xff else a)
		Mem.w8(e + 0xb, acc)
		Mem.w16(e + 6, 0xfefe)
		Mem.w8(e + 2, promo)
		Mem.w8(e + 3, _deploy_level(lvc))
		Mem.w8(e + 0xc, aim)
		if aim > 2 and aim < 7:
			if aim == 4 or aim == 6:
				Mem.w8(e + 0xe, tx)
				Mem.w8(e + 0xf, ty)
			else:
				Mem.w16(e + 0xe, tp)
	Mem.w8(page_addr, page + 1)


func op_battle_allies(ins: Dictionary) -> void:
	_deploy_entries(ins, false)


func op_battle_enemies(ins: Dictionary) -> void:
	_deploy_entries(ins, true)


## op 0x48 battle_equipment (0x411cdb): the first entry 20..249 of the person gets weapon / armour / accessory codes
## and weapon / armour levels (−1 → 0).
func op_battle_equipment(ins: Dictionary) -> bool:
	var pid := arg(ins, 0)
	var vals := []
	for k in 5:
		var v := arg(ins, 1 + k)
		vals.append(0 if v == 0xffff else v & 0xff)
	for j in range(20, 250):
		var e := _entry(j)
		if Mem.r16(e) == pid:
			Mem.w8(e + 9, vals[0])
			Mem.w8(e + 6, vals[1])
			Mem.w8(e + 0xa, vals[2])
			Mem.w8(e + 7, vals[3])
			Mem.w8(e + 0xb, vals[4])
			return true
	return false


## op 0x4a battle_prepare (0x415bd0): 5 forced persons and 5 flag persons into the GS rings (0x415c0d), sortie
## maximum 1, then the sortie builder 0x418597(0).
func op_battle_prepare(ins: Dictionary) -> void:
	_sortie_rings(ins, 1)
	Mem.w8(Game.SORTIE_MAX, 1)
	await build_sortie(0)      # ScriptHost: 0x418597 (max = 1 here, so never the selection window)


## 0x415c0d: 5 × u16 into the forced ring @0x4b09dc at [0x4b0a2c], 5 into the flag ring @0x4b0a04 at [0x4b0a30];
## each base moves on to its last index + 1 (wrapping at 20).
func _sortie_rings(ins: Dictionary, first: int) -> void:
	var r1 := Mem.r32(Game.SORTIE_RING)
	var last := r1
	for k in 5:
		last = k + r1
		Mem.w16(Game.SORTIE_FORCED + 2 * (last % 20), arg(ins, first + k))
	Mem.w32(Game.SORTIE_RING, 0 if last + 1 == 20 else last + 1)
	var r2 := Mem.r32(Game.SORTIE_RING + 4)
	var last2 := r2
	for k in 5:
		last2 = k + r2
		Mem.w16(Game.SORTIE_EXCLUDED + 2 * (last2 % 20), arg(ins, first + 5 + k))
	Mem.w32(Game.SORTIE_RING + 4, 0 if last2 + 1 == 20 else last2 + 1)


## op 0x4b (0x415e33): slot, x, y, dir, hidden (−1 → 0). In a battle (EV 4057 = 0xffff) a player entry gets the
## position and flags; otherwise the sortie-preview table 0x507680.
func op_op_4b(ins: Dictionary) -> void:
	var k := arg(ins, 0)
	var hidden := arg(ins, 4)
	if hidden == 0xffff:
		hidden = 0
	if Mem.r32(Mem.EV + 4 * 4057) == 0xffff:
		if k >= 250:
			return
		var e := _entry(k)
		if Mem.r32(e) != 0xffff and (Mem.r8(e + 8) & 3) == 0:
			Mem.w8(e + 4, arg(ins, 1))
			Mem.w8(e + 5, arg(ins, 2))
			Mem.w32(e + 8, (4 if hidden != 0 else 0) | dir_bits(arg(ins, 3)))
	else:
		Mem.w8(0x507680 + 3 * k, arg(ins, 1))
		Mem.w8(0x507680 + 3 * k + 1, arg(ins, 2))
		Mem.w8(0x507680 + 3 * k + 2, hidden & 0xff)


# ------------------------------------------------------------------ sprites
func refresh_units() -> void:
	if view == null:
		return
	for u in units:
		var show: bool = u.pid >= 0 and u.state == BUnit.STATE_ON_MAP
		if show and u.node == null:
			var n := UnitSprite.new()
			view.units_layer.add_child(n)
			u.node = n
		if u.node:
			if not show:
				u.node.queue_free()
				u.node = null
				continue
			if u.node.entry != u.sprite_entry() or u.node._mov == null:
				u.node.set_entry(u.sprite_entry())
			u.node.position = view.cell_pos(u.pos)
			if u.node.pose == UnitSprite.Pose.STAND or u.node.pose == UnitSprite.Pose.WEAK:
				var weak := u.hp * 5 < u.max_hp() * 2 if u.hp > 0 else true
				u.node.set_pose(UnitSprite.Pose.WEAK if weak else UnitSprite.Pose.STAND, u.dir)
			u.node.greyed = (u.flags & 6) == 6 and u.hp > 0
	if hud:
		hud.queue_redraw()


## The sub-12 map objects (0x507180, 40 slots): a DtPicture per record with a DT number, under the units (patch
## layer) or over them (z 3) by +6 bit 0; records cleared → removed (redraw 0x465973).
func refresh_pictures() -> void:
	if view == null:
		return
	for k in 40:
		var n := Mem.r16(DtPicture.RECORDS + 32 * k + 0x12)
		var node: DtPicture = pictures.get(k)
		if node != null and not is_instance_valid(node):
			node = null
		if n == 0:
			if node != null:
				node.queue_free()
			pictures.erase(k)
			continue
		if node == null:
			node = DtPicture.new(k)
			pictures[k] = node
		var parent: Node = view if node.over_units() else view.patch_layer
		if node.get_parent() != parent:
			if node.get_parent():
				node.get_parent().remove_child(node)
			parent.add_child(node)
		node.z_index = 3 if node.over_units() else 0
		node.sync()


func _after_poke(addr: int) -> void:
	if addr >= Mem.UNITS and addr < Mem.UNITS + Mem.UNIT_SLOTS * Mem.UNIT_SIZE:
		_rebuild_grid()
		refresh_units()


func on_field_written(_field: int, _id: int) -> void:
	_rebuild_grid()
	refresh_units()


## The unit grid from the records (after raw writes to positions or states).
func _rebuild_grid() -> void:
	if not field_ready:
		return
	Mem.fill(Mem.MAP_BUF + 0xc80, 0x640, 0xff)
	for u in units:
		if u.state == 2 and Rules.in_map(u.pos):
			Mem.w8(Mem.MAP_BUF + 0xc80 + u.pos.x + u.pos.y * Rules.map_w(), u.slot)
	BUnit.gen += 1


func wait(sec: float) -> void:
	if fast or sec <= 0 or Game.autoplay:
		return
	await get_tree().create_timer(sec).timeout


# ------------------------------------------------------------------ tests
## op 0x3f: turn (round + 1) compared with the argument.
func op_test_turn(ins: Dictionary) -> bool:
	return Game.compare(turn, arg(ins, 0), arg(ins, 1))


## op 0x40: the phase byte == arg & 0xff.
func op_test_side(ins: Dictionary) -> bool:
	return phase == (arg(ins, 0) & 0xff)


## op 0x42 (0x411bd0): VictoryTest 0x428f36, then event slot 5 == 1. While the battle has no result the test sets the
## slot (0x44f840(1)) when a unit 60..250 (inclusive) in state 3 / 4 is the boss (reader +0x3d04 bit 0, +0x3d06) or
## no 敌军 / 援军 is on the map (CountUnits 5); the slot keeps its value (it is not set when there is a result).
func op_test_event5(_ins: Dictionary) -> bool:
	if field_ready and result == 0:
		var hit := false
		if Mem.r16(READER + 0x3d04) & 1:
			var boss := Mem.r16(READER + 0x3d06)
			for i in range(60, 251):
				var a := Mem.UNITS + i * Mem.UNIT_SIZE
				if Mem.r8(a + 0xc) in [3, 4] and Mem.r16(a) == boss:
					hit = true
					break
		if hit or Rules.count_units(5)[0] == 0:
			event_slots[5] = 1
	return int(event_slots.get(5, 0)) == 1


## op 0x43 (0x411ba5): DefeatTest 0x44ca6d, then event slot 6 == 1. Without a result the slot is set (0x44f880(1))
## when a unit 0..60 (inclusive) in state 3 / 4 is the lose-person (reader +0x3d08 bit 0, +0x3d0a), or — unit 0's
## person ≠ 0 — no kind-0 unit is on the map, or — person 0 in slot 0 — no unit 0..20 is in state 1 / 2.
func op_test_event6(_ins: Dictionary) -> bool:
	if field_ready and result == 0:
		var lose := false
		if Mem.r16(READER + 0x3d08) & 1:
			var lp := Mem.r16(READER + 0x3d0a)
			for i in range(0, 61):
				var u := units[i]
				if u.state in [3, 4] and Mem.r16(u.addr) == lp:
					lose = true
					break
		if not lose:
			if Mem.r32(units[0].addr) != 0:
				lose = Rules.count_units(0)[0] == 0
			else:
				lose = true
				for i in range(0, 21):
					if units[i].state in [1, 2]:
						lose = false
						break
		if lose:
			event_slots[6] = 1
	return int(event_slots.get(6, 0)) == 1


## op 0x25: a unit matching the selector stands on (x, y) (0x45b50a).
func op_test_unit_at(ins: Dictionary) -> bool:
	return sel_matches_cell(arg(ins, 0), Vector2i(arg(ins, 1), arg(ins, 2)))


## op 0x26 (0x45b597): any cell of the rectangle (rows y1..y2, columns x1..x2) holds a matching unit.
func op_test_unit_in_area(ins: Dictionary) -> bool:
	var sel := arg(ins, 0)
	if sel == 0xffff:
		return false
	var x1 := arg(ins, 1) & 0xff
	var y1 := arg(ins, 2) & 0xff
	var x2 := arg(ins, 3) & 0xff
	var y2 := arg(ins, 4) & 0xff
	# the cells hold units through the map grid: scanning the units standing in the rectangle is the same test
	for u in units:
		var c := u.pos
		if u.state == 2 and c.x >= x1 and c.x <= x2 and c.y >= y1 and c.y <= y2 and Rules.unit_at(c) == u \
				and _sel_matches_unit(sel, u):
			return true
	return false


## op 0x2e (0x45afca): B (person / selector) on one of the 8 cells around A's unit; loose = 0 also needs A and B able
## to attack each other (0x426981).
func op_test_adjacent(ins: Dictionary) -> bool:
	var a := arg(ins, 0)
	var b := arg(ins, 1)
	var loose := arg(ins, 2)
	var ua: BUnit
	if a < 0x400 or a < 0x404:
		var pa := a if a < 0x400 else Mem.r16(CUR_PERSON)
		ua = _unit_on_map(pa)
	else:
		ua = units[(a - 0x404) & 0xff]
	if ua == null:
		return false
	var ub: BUnit = null
	if b < 0x400:
		ub = _unit_on_map(b)
		if ub == null:
			return false
	for d in Rules.DIR8:
		var c: Vector2i = ua.pos + d
		if not Rules.in_map(c):
			continue
		var hit: BUnit = null
		if b < 0x400:
			if Rules.unit_at(c) == ub:
				hit = ub
		elif sel_matches_cell(b, c):
			hit = Rules.unit_at(c)
		if hit != null:
			if loose != 0:
				return true
			return actions.can_attack(ua, hit) and actions.can_attack(hit, ua)
	return false


## 0x42466d: the person's unit on the map.
func _unit_on_map(pid: int) -> BUnit:
	for u in units:
		if u.pid == pid and u.state == 2:
			return u
	return null


## op 0x41 (0x411507): number of units of a side (−1 → 6) on the map or in a rectangle, compared.
func op_test_units_in_area(ins: Dictionary) -> bool:
	var side := arg(ins, 0)
	if side == 0xffff:
		side = 6
	var rect := arg(ins, 3)
	if rect == 0xffff:
		rect = 0
	var r := Rules.count_units(side, rect == 1, arg(ins, 4) & 0xff, arg(ins, 5) & 0xff, arg(ins, 6) & 0xff, arg(ins, 7) & 0xff)
	return Game.compare(r[0], arg(ins, 1), arg(ins, 2))


## op 0x3c test_last_action (0x415d34): last action code == a1·2 + a2 + 1 (a1 0xff → 2) and the acting unit is the
## person (0x400 = anyone).
func op_test_last_action(ins: Dictionary) -> bool:
	var p := arg(ins, 0)
	var a1 := arg(ins, 1) & 0xff
	var a2 := arg(ins, 2) & 0xff
	if a1 == 0xff:
		a1 = 2
	if Mem.r8(LAST_ACTION) != ((a1 * 2 + a2 + 1) & 0xff):
		return false
	if p == 0x400:
		return true
	if p > 0x400:
		var u := unit_sel(p)
		return u != null and u.pid == Mem.r16(CUR_PERSON)
	return Mem.r16(CUR_PERSON) == p


## op 0x5e test_action_pair (0x44e642, eex.md §10.3): A acts in the current action and B is one of its targets (or
## by B's selector class).
func op_test_action_pair(ins: Dictionary) -> bool:
	var a := arg(ins, 0)
	var b := arg(ins, 1)
	if a == 0xffff: a = 0x400
	if b == 0xffff: b = 0x400
	var actor := Mem.r16(CUR_PERSON) if a >= 0x400 else a
	var au := unit_of_person(actor)
	if au == null:
		return false
	var kind := Mem.r8(LAST_ACTION)
	var ok := false
	if kind in [1, 5, 6]:
		ok = au.slot == Mem.r8(Rules.COMBAT) or (Mem.r8(0x501bfa) == 1 and au.slot == Mem.r8(Rules.COMBAT + 1))
	elif kind == 2:
		ok = Mem.r8(Rules.STRAT_CTX + 1) == au.slot
	if not ok:
		return false
	if b < 0x400:
		var bu := unit_of_person(b)
		if bu == null:
			return false
		if kind == 2:
			for i in 249:
				var s := Mem.r8(Rules.STRAT_CTX + 0xd + i)
				if s == 0xff:
					break
				if s == bu.slot:
					return true
			return false
		return bu.slot == Mem.r8(Rules.COMBAT) or bu.slot == Mem.r8(Rules.COMBAT + 1) or actions.was_target(bu)
	var cls := au.side()
	match b:
		0x400: return true
		0x401: return cls == 1
		0x402: return cls != 0
	return cls == 1 and current_unit == au


## op 0x36 / 0x38 in a battle (eex.md §11.5).
func op_test_attr(ins: Dictionary) -> bool:
	return BattleAttrs.test(self, u16(ins, 0), u16(ins, 1) & 0xff, arg(ins, 2), u16(ins, 3) & 0xff)


## Op 0x38 in a battle (0x412007): persons 0x400..0x402 = the acting unit's person ([0x4b5df0]); the rest is the
## shared setter (PersonAttrs; HP / MP through unit_hp_mp_op).
func op_set_attr(ins: Dictionary) -> void:
	var pid := u16(ins, 0)
	if pid >= 0x400 and pid < 0x403:
		pid = current_unit_person()
	PersonAttrs.set_attr(self, pid, u16(ins, 1), u16(ins, 2), arg(ins, 3))


# ------------------------------------------------------------------ texts / UI ops
## op 0x19: store the victory conditions (0x496ca0); no window.
func op_victory_cond_text(ins: Dictionary) -> void:
	victory_text = sarg(ins, 0)
	Mem.w8(0x4b3d10, 0)


## op 0x1a: the victory-condition panel with the stored lines and the turn limit.
func op_battle_goal_text(ins: Dictionary) -> void:
	goal_text = sarg(ins, 0)
	await hud.goal_panel(victory_text if victory_text != "" else goal_text, turn_limit)


## op 0x49: the battle is won (result 2).
func op_ui_49(_ins: Dictionary) -> void:
	result = 2


## op 0x0e: the battle is lost → game over.
func op_ui_0e(_ins: Dictionary) -> void:
	result = 3
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("GAME OVER at turn %d" % turn)
	await Game.main.game_over()
	vm.abort = true
	vm.active = false


## op 0x12 in a battle (0x411aa6): the 战场缩小图 is shown while the choice box is open and hidden again afterwards
## unless it was already visible.
func op_choice(ins: Dictionary) -> void:
	if Game.autoplay or view == null:
		await super.op_choice(ins)
		return
	var ov := BattleOverview.ensure(self)
	var was := ov.visible
	ov.open()
	await super.op_choice(ins)
	if not was and is_instance_valid(ov):
		ov.close()


## op 0x5a (0x44bac2 → 0x44b328(0x48e1c8)): "开始作战" over the map for 20 ticks.
func op_ui_5a(_ins: Dictionary) -> void:
	await RewardScreen.banner(self, "开始作战")


## op 0x54: the retreat check pass (0x42bc14).
func op_ui_54(_ins: Dictionary) -> void:
	await post_action()


func op_scroll_to(ins: Dictionary) -> void:
	if Rules.evb(4087) != 0:
		return
	await view.center_on(Vector2i(arg(ins, 0), arg(ins, 1)))


## Unit result window 0x450986 (ResultPanel): kind = the SP already gained (third bar SP) or 0x100 (third bar EXP
## rising by exp_gain); call it before writing HP / MP / EXP.
func result_panel(u: BUnit, kind: int, hp_loss: int, mp_loss: int, exp_gain: int, wexp: int, aexp: int,
		long_wait := false) -> void:
	await ResultPanel.show(self, u, kind, hp_loss, mp_loss, exp_gain, wexp, aexp, long_wait)


## AI action preview 0x441488(u, mode, t, s) (mode 0 move, 1 attack, 2 strategy): the view centres on the unit;
## unless (mode 0 with 极速移动, byte 0x501a79) or the unit is hidden by the fog (0x42a67b), two frames of 4 rounds
## (a click ends them): the cursor on the unit, the range (s = 0xff: the attack shape 0x43f8c0, else the strategy's
## range) — for mode 0 only in the second frame — and for modes 1 / 2 the cursor on the target in the second frame.
## [G] Mode 0's range is taken as the movement range (view flag +0x68), the action marker 0x44049e is not drawn.
func ai_preview(u: BUnit, mode: int, t: int, s: int) -> void:
	await scroll_cell(u.pos)
	if Game.autoplay or view == null:
		return
	if mode == 0 and Mem.r8(0x501a79) != 0:
		return
	if Mem.r8(0x501bd2) >= 2 and Rules.evb(4087) == 0:
		Rules.vis_update()
		if Mem.r8(Rules.VIS + u.pos.x + u.pos.y * Rules.map_w()) & 0xd == 0:
			return
	view.cursor_cell = u.pos
	for k in 2:
		if mode == 0:
			if k == 1:
				var cells := {}
				for c in Movement.move_range(u, u.move_points()):
					cells[c] = true
				view.set_move_cells(cells)
		elif k == 0:
			if s == 0xff:
				view.set_attack_cells(Rules.attack_cells(u, u.pos))
			else:
				view.set_attack_cells(Rules.range_cells(Rules.strat_range(u, s), u.pos))
		elif t >= 0 and t < 250 and units[t].state == 2:
			view.cursor_cell = units[t].pos
		var clicks := Game.clicks
		await wait(0.4)
		if Game.clicks != clicks:
			break
	view.clear_highlights()
	ai.clear_ai_values()


## 0x45503f: centre the view on a cell (scrolled by 0x454cef, clamped to the map); nothing while byte EV[4087] ≠ 0.
func scroll_cell(c: Vector2i) -> void:
	if Rules.evb(4087) != 0 or view == null:
		return
	await view.center_on(c)


# ------------------------------------------------------------------ ScriptHost hooks (shared ops in a battle)
## Person of the acting unit ([0x4b5df0], set by 0x406240).
func current_unit_person() -> int:
	return Mem.r16(CUR_PERSON)


## The speaker's unit for the battle talk window 0x42cd05: the selector (0x41b882), else the person's first unit
## (0x477adc).
func _speaker_unit(pid: int) -> BUnit:
	var u := unit_sel(pid)
	if u == null and pid >= 0 and pid < 0x400:
		u = unit_of_person(pid)
	return u


## Talk-window anchor (0x42cd05 → 0x42ceee): the speaker unit's cell in the view when it is on the map. A selector
## ≥ 0x400 without a unit gets the story window (0x42d5b0), hence null.
func talk_anchor(pid: int) -> Variant:
	var u := _speaker_unit(pid)
	if u == null and pid >= 0x400:
		return null
	var cam := view.camera.position
	var org := Vector2i(floori(cam.x / BattleView.CELL), floori(cam.y / BattleView.CELL))
	var a := {"battle": true, "view": Rect2(Vector2(org * BattleView.CELL) - cam, view.view_size())}
	if u != null:
		a["pid"] = u.pid
		if u.state == 2:
			a["cell"] = u.pos - org
	return a


## 0x4596bd: the view centred on the speaker's unit before its talk window.
func talk_focus(pid: int) -> void:
	var u := _speaker_unit(pid)
	if u != null and u.state == 2:
		await scroll_cell(u.pos)


## 0x45965d (op 0x14 in a battle): only a speaker whose unit is on the map talks; the view centres on it and the
## talk window 0x42d5b0(text, pid, 0) opens beside it (0x4596ce).
func battle_talk(pid: int, text: String) -> void:
	var u := _speaker_unit(pid)
	if u == null or u.state != 2:
		return
	await scroll_cell(u.pos)
	await _talk_at(u, pid, text)


## 0x45972e (op 0x15 in a battle): the view goes to a0's unit (selector on the map), else to the first live unit
## of person a0 or of person a1 (0x42466d); the talk window always shows a1 (0x42d5b0(text, a1, 0)).
func battle_unit_say(pid: int, a1: int, text: String) -> void:
	var u := unit_sel(pid)
	if u == null or u.state != 2:
		u = _live_unit_of(pid)
		if u == null:
			u = _live_unit_of(a1)
	if u == null:
		await ui_talk(a1, text, 0)
		return
	await scroll_cell(u.pos)
	await _talk_at(u, a1, text)


## 0x42466d: the first unit of the person on the map with HP > 0.
func _live_unit_of(pid: int) -> BUnit:
	for u in units:
		if u.pid == pid and u.state == 2 and u.hp != 0:
			return u
	return null


## 0x4596ce: a unit drawn grey (acted, bits 2 | 4) is shown in colour while the window is open, then grey again.
func _talk_at(u: BUnit, pid: int, text: String) -> void:
	if u.flags & 6 != 6:
		await ui_talk(pid, text, 0)
		return
	u.flags = u.flags & ~6
	refresh_units()
	await ui_talk(pid, text, 0)
	u.flags = u.flags | 6
	refresh_units()


## Op 0x7a in a battle (0x42d8bf): f2..f4 through the unit selector (or the person's first unit) to the units'
## persons; the first one on the map is focused (0x4596bd). None on the map: skipped unless f2 == f3 == f4 ≠ −1, then
## the slots outside the speaker mask are emptied.
func dialog3_battle_persons(persons: Array, mask := 7) -> Array:
	var out := []
	var focus: BUnit = null
	for v in persons:
		var p := int(v)
		var u: BUnit = null
		if p != -1:
			u = unit_sel(p)
			if u == null and p >= 0 and p < 0x400:
				u = unit_of_person(p)
		out.append(u.pid if u != null else p)
		if focus == null and u != null and u.state == 2:
			focus = u
	if focus == null:
		if int(persons[0]) == -1 or persons[0] != persons[1] or persons[1] != persons[2]:
			return []
		for j in 3:
			if mask & (4 >> j) == 0:
				out[j] = -1
		return out
	await scroll_cell(focus.pos)
	return out


## Op 0x3b in a battle (0x45b771): the person's unit (state ≠ 0) changes sides — 0 player slots 0..19, 1 ally 20..59,
## else enemy 60..249. A retreated unit only changes membership; otherwise the record moves to the first free slot of
## the range (0x4081a6: kind = side (0xff → 2), AI 7 for side 0 else 1, target 0xff, the entry's person) and the old
## slot is reset (0x47d0bc); without a free slot the unit leaves the map (0x441744). Membership 0x4095b9: side 0 joins,
## leaving the player kind leaves (0xff). Side 0 records the person's three equipment items (0x408b0d).
func battle_join(pid: int, side: int) -> void:
	var u: BUnit = null
	for o in units:
		if o.pid == pid and o.state != 0:
			u = o
			break
	if u == null:
		return
	side &= 0xff
	var lo := 0
	var hi := 20
	var k := side
	if side == 1:
		lo = 20
		hi = 60
	elif side != 0:
		lo = 60
		hi = 250
		k = 2
	if u.kind == k:
		return
	if u.state == 3:
		if lo == 0:
			Game.set_membership(pid, 0, 0)
		elif u.kind == 0:
			Game.set_membership(pid, 0xff, 0)
	else:
		var free: BUnit = null
		for s in range(lo, hi):
			if units[s].state == 0:
				free = units[s]
				break
		if free == null:
			await remove_unit(u, false, false)
		if lo == 0:
			Game.set_membership(pid, 0, 0)
		elif u.kind == 0:
			Game.set_membership(pid, 0xff, 0)
		if free != null:
			if free != u:
				Mem.copy(free.addr, u.addr, Mem.UNIT_SIZE)
				free.kind = 2 if side == 0xff else side
				free.ai = 7 if side == 0 else 1
				Mem.w32(free.addr + 8, 0xff)
				Mem.w8(free.addr + 4, free.slot)
				Mem.w32(_entry(free.slot), Mem.r32(u.addr))
				free.extra = u.extra.duplicate()
				_reset_unit(u)
			_rebuild_grid()
			refresh_units()
	if lo == 0:
		var p := Game.person(pid)
		for slot in 3:
			var it := Mem.r8(p.base + 0x2e + 3 * slot)
			if it != 0xff:
				Game.record_item(it)


## Op 0x3d in a battle (0x459950 → 0x4144ef(…, show 1)): with flag ≠ 0 the receiving unit — person < 0x400: its first
## live unit on the map (0x42466d); 0x400..0x402: the acting unit when on the map — raises the item (pose 1,
## 0x45778f) while the 32×32 icon rises 7 px over 8 ticks above it (SE 14), 5 ticks, then the message; the cell is
## redrawn afterwards.
func battle_get_item(iid: int, lvl: int, flag: int, person: int) -> void:
	var u: BUnit = null
	if flag != 0:
		if person < 0x400:
			u = _live_unit_of(person)
		elif person < 0x403 and current_unit != null and current_unit.state == 2:
			u = current_unit
		# [G] 0x403 / acting unit off the map: the original reads the pointer 0x500ac4 (never set by any code found);
		# > 0x403: an uninitialised local — no animation in both cases
	if u != null:
		await unit_action(u, 1, 0, 0)
		var icon := Sprite2D.new()
		icon.centered = false
		icon.texture = ItemText66.large_icon(iid & 0xff)
		view.fx_layer.add_child(icon)
		Audio.se(14)
		for i in 8:
			icon.position = view.cell_pos(u.pos) + Vector2(8, 7 - i)
			await wait(0.05)
		await wait(0.25)
		await story_get_item(iid & 0xff, lvl, true)
		icon.queue_free()
		if u.node:
			u.node.set_pose(UnitSprite.Pose.STAND, u.dir)
		refresh_units()
		return
	await story_get_item(iid & 0xff, lvl, true)


## Op 0x3e in a battle (0x416326): the first unit (state ≠ 0) of the person, each slot with a non-zero code through
## 0x44299b (code low byte; level = the weapon level for code 1, else the slot's, accessory 0xff).
func battle_set_equipment(pid: int, c: Array) -> void:
	var u: BUnit = null
	for o in units:
		if o.state != 0 and o.pid == pid:
			u = o
			break
	if u == null:
		return
	for slot in 3:
		var code: int = int(c[slot * 2])
		if code == 0:
			continue
		var lvl: int = int(c[1]) if code == 1 else (int(c[slot * 2 + 1]) if slot < 2 else 0xff)
		u.person.equip_code(slot, code & 0xff, lvl & 0xff)
	refresh_units()


## 0x45aa37(person, 7 / 8, v, 1, 0) for op 0x38: the selector's unit (else the person's first, persons ≤ 0x400) on
## the map; HP (dword) / MP (word v) through 0x40da4a with EV[4044] = mode (0 subtract, never below 1; 1 add; 2 set),
## capped at the maximum (0x43f6db / 0x43f715); EV[4044] back to 0.
func unit_hp_mp_op(pid: int, attr: int, v: int, mode: int) -> void:
	var u := unit_sel(pid)
	if u == null:
		if pid > 0x400:
			return
		u = unit_of_person(pid)
	if u == null or u.state != 2:
		return
	Mem.w8(Mem.EV + 4 * 4044, mode)
	if attr == 7:
		u.hp = mini(hp_op(u.hp, v & 0xffffffff), u.max_hp())
	else:
		u.mp = mini(hp_op(u.mp, v & 0xffff), u.max_mp())
	Mem.w8(Mem.EV + 4 * 4044, 0)
	refresh_units()


# ------------------------------------------------------------------ op 0x72 battle sub-functions
## The battle part of op 0x72 (memory parts in ExtCommand): 1 / 2 / 3 strategy animations with HP changes, 11 AI areas
## per unit, 12 picture redraw, 21 / 14 / 17 redraws, 31 battle viewport.
func ext_battle(sub: int, nums: Array, _text: String) -> void:
	match sub:
		1: await _cast_on_persons(nums)
		2: await _cast_on_points(nums, _points_list(nums))
		3: await _cast_on_points(nums, _points_rect(nums))
		11: _ai_area_units(nums)
		12: refresh_pictures()
		31: _viewport(nums)
		_: refresh_units()


static func _n(nums: Array, i: int) -> int:
	return int(nums[i]) if i < nums.size() else 0


## Sub 1 (0x40c4b7): [power, strategy, camera, persons…]; strategy < 100; the context 0x497af8 is set up for slot 60
## (0x4251e1(ctx, s, 0x3c)); persons < 0x400 through the unit selector (else the person's first unit) whose unit is
## on the map → the context's target list (≤ 250); camera ≠ 0 → the view centres on the first; then 0x406d64.
func _cast_on_persons(nums: Array) -> void:
	var s := _n(nums, 1)
	if s < 0 or s >= 100:
		return
	strategy._init_ctx(s, units[0x3c])
	var tg: Array[BUnit] = []
	for i in range(3, nums.size()):
		var v := _n(nums, i)
		if v < 0 or v >= 0x400:
			continue
		var u := unit_sel(v)
		if u == null:
			u = unit_of_person(v)
		if u != null and u.state == 2:
			if tg.size() >= 250:
				break
			tg.append(u)
	if tg.is_empty():
		return
	if _n(nums, 2) != 0:
		await scroll_cell(tg[0].pos)
	var cells: Array[Vector2i] = []
	for u in tg:
		cells.append(u.pos)
	await _script_cast(s, tg, cells, _n(nums, 0))


## Sub 2 (0x41419f): x, y pairs after [power, strategy, camera, side] (≤ 120 points; each point written with a 0xff
## terminator after it).
func _points_list(nums: Array) -> Array[Vector2i]:
	var pts: Array[Vector2i] = []
	var i := 4
	while i + 1 < nums.size() and pts.size() < 120:
		pts.append(Vector2i(_n(nums, i) & 0xff, _n(nums, i + 1) & 0xff))
		i += 2
	return pts


## Sub 3 (0x40221b): the rectangle x1, y1, x2, y2 (all four needed) row by row (≤ 120 points).
func _points_rect(nums: Array) -> Array[Vector2i]:
	var pts: Array[Vector2i] = []
	if nums.size() < 8:
		return pts
	var x1 := _n(nums, 4) & 0xff
	var y1 := _n(nums, 5) & 0xff
	var x2 := _n(nums, 6) & 0xff
	var y2 := _n(nums, 7) & 0xff
	for y in range(y1, y2 + 1):
		for x in range(x1, x2 + 1):
			if pts.size() >= 120:
				return pts
			pts.append(Vector2i(x, y))
	return pts


## 0x4022ca: the points up to the first x = 0xff; camera → the view centres on the first point; per point the unit
## standing there (on the map) whose home code (0x42e2ed) matches `side` (0x45aed1: < 4 equal, 4 below 2, 5 two or
## three, 6 any) is a target; 0x406d64 animates on the points.
func _cast_on_points(nums: Array, pts: Array[Vector2i]) -> void:
	var s := _n(nums, 1)
	if s < 0 or s >= 100:
		return
	strategy._init_ctx(s, units[0x3c])
	var cells: Array[Vector2i] = []
	for c in pts:
		if c.x == 0xff:
			break
		cells.append(c)
	if cells.is_empty() or cells[0].y == 0xff:
		return
	if _n(nums, 2) != 0:
		await scroll_cell(cells[0])
	var side := _n(nums, 3) & 0xff
	var tg: Array[BUnit] = []
	for c in cells:
		var u := Rules.unit_at(c) if Rules.in_map(c) else null
		if u == null or u.state != 2:
			continue
		if home_code_ok(u, side):
			tg.append(u)
	await _script_cast(s, tg, cells, _n(nums, 0))


## 0x406d64(targets, s, n, mode, power): power ≠ 0 → each target's HP += power clamped to [1, max HP] (0x4142dd), the
## applied change (negated) and the number kind (0x40 damage / 0x50 heal) kept in the context; then the Meff animation
## on the cells inside the view (BattleStrategy.script_anim); when it played: Poll + PostAction (0x46d05a).
func _script_cast(s: int, tg: Array[BUnit], cells: Array[Vector2i], power: int) -> void:
	var C := Rules.STRAT_CTX
	for k in tg.size():
		Mem.w8(C + 0xd + k, tg[k].slot)
	var numbers := []
	var kind := 0x40 if power < 0 else 0x50
	if power != 0:
		Mem.w8(C + 0x400, kind)
		var by_cell := {}
		for k in tg.size():
			var u := tg[k]
			var d := power
			if u.hp + d < 1:
				d = 1 - u.hp
			elif u.hp + d > u.max_hp():
				d = u.max_hp() - u.hp
			u.hp = u.hp + d
			Mem.w32(C + 0x108 + 4 * k, (-d) & 0xffffffff)
			Mem.w8(C + 0x401 + k, kind)
			by_cell[u.pos] = -d
		for c in cells:
			numbers.append(by_cell.get(c, 0))
	refresh_units()
	if await strategy.script_anim(s, cells, numbers, kind):
		await checkpoint()
		await post_action()


## Sub 11 (0x44ce20): bytes x1, y1, x2, y2, mode, then a list — mode 0 persons (their first unit, 0x43e4d6), else
## unit indices (< 250); units not under player control (AI ≠ 7) get the AI action area u16 +9 = (x1, y1),
## u16 +0x20 = (x2, y2).
func _ai_area_units(nums: Array) -> void:
	var tl := (_n(nums, 0) & 0xff) | ((_n(nums, 1) & 0xff) << 8)
	var br := (_n(nums, 2) & 0xff) | ((_n(nums, 3) & 0xff) << 8)
	var mode := _n(nums, 4) & 0xff
	for i in range(5, nums.size()):
		var v := _n(nums, i)
		var u: BUnit = null
		if mode != 0:
			if v & 0xff > 0xf9:
				continue
			u = units[v & 0xff]
		else:
			u = unit_of_person(v)
		if u != null and u.ai != 7:
			Mem.w16(u.addr + 9, tl)
			Mem.w16(u.addr + 0x20, br)


## Sub 31 (0x42d260, unused by the scripts): u32 0x501bf0 = the 4 bytes (x, y, w, h) — the movement rectangle; the
## original also resizes its view surface to w × h cells and scrolls to (0, 0) (not reproduced: no script uses it).
func _viewport(nums: Array) -> void:
	var v := 0
	for i in 4:
		v |= (_n(nums, i) & 0xff) << (8 * i)
	Mem.w32(Rules.MOVE_RECT, v)


## op 0x1b: retreat-line flag (+0x1f) of the person's unit.
func op_op_1b(ins: Dictionary) -> void:
	var u := unit_sel(arg(ins, 0))
	if u:
		u.set_byte(0x1f, 1 if arg(ins, 1) != 0 else 0)


# ------------------------------------------------------------------ unit ops
## op 0x4c (0x414adc): mode 0 → a unit (selector) not on the map appears at its deployment entry; mode 1 → unit
## index arg2 in state 1 appears at entry arg2.
func op_unit_op_4c(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 0xffff:
		mode = 0
	if mode == 0:
		var u := unit_sel(arg(ins, 1))
		if u == null or u.state == 2:
			return
		var e := entry_of(u)
		if e < 0:
			return
		await appear(u, e)
	elif mode == 1:
		var s := arg(ins, 2) & 0xff
		if s < 250 and units[s].state == 1:
			await appear(units[s], _entry(s))


func _targets_rect(x1: int, y1: int, x2: int, y2: int, side: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	if side == 0xffff:
		side = 6
	x2 = mini(x2 & 0xff, Rules.map_w() - 1)
	y2 = mini(y2 & 0xff, Rules.map_h() - 1)
	for y in range(y1 & 0xff, y2 + 1):
		for x in range(x1 & 0xff, x2 + 1):
			var u := Rules.unit_at(Vector2i(x, y))
			if u != null and u.state == 2 and Rules.kind_matches(u, side):
				out.append(u)
	return out


## op 0x4d (0x415551, eex.md §10.1): buff (value 2 → 6, 1 → 3, else raw), ailments (6), HP (7, int32), MP (8) of one
## unit — mode 0 person (0x400..0x402 = the acting person), 1 the person of unit index arg2 (on the map), others
## person arg1 — or (mode 2) of every unit of `side` (0xffff → 6) in the rectangle (0x45ade7); then PostAction.
func op_unit_op_4d(ins: Dictionary) -> void:
	var mode := arg(ins, 0) & 0xffff
	var pid := arg(ins, 1) & 0xffff
	if mode == 0 and pid >= 0x400 and pid < 0x403:
		pid = Mem.r16(CUR_PERSON)
	if mode == 1:
		var su := units[arg(ins, 2) & 0xff] if (arg(ins, 2) & 0xff) < 250 else null
		if su == null or su.state != 2:
			return
		pid = su.pid
	var side := arg(ins, 7) & 0xffff
	if mode == 2 and side == 0xffff:
		side = 6
	var rect := [arg(ins, 3) & 0xff, arg(ins, 4) & 0xff, arg(ins, 5) & 0xff, arg(ins, 6) & 0xff]
	var bi := arg(ins, 8) & 0xffff
	var bv := arg(ins, 9) & 0xffff
	if bi != 0xffff and bv != 0xffff:
		if bv == 2:
			bv = 6
		elif bv == 1:
			bv = 3
		await _op4d_apply(mode, pid, rect, side, bi & 0xff, bv)
	var stv := arg(ins, 10) & 0xffff
	if stv != 0xffff:
		await _op4d_apply(mode, pid, rect, side, 6, stv)
	var hpd := arg(ins, 11)
	if hpd != 0:
		await _op4d_apply(mode, pid, rect, side, 7, hpd)
	var mpd := arg(ins, 12) & 0xffff
	if mpd != 0:
		await _op4d_apply(mode, pid, rect, side, 8, mpd)
	await post_action()


## 0x420eb9: mode 2 → the rectangle (0x45ade7), else the person's unit with the animation (0x45aa37(…, 1, 0)).
func _op4d_apply(mode: int, pid: int, rect: Array, side: int, idx: int, v: int) -> void:
	if mode != 2:
		var u := unit_sel(pid)
		if u == null:
			if pid > 0x400:
				return
			u = unit_of_person(pid)
		await unit_attr_op(u, idx, v, true)
		return
	# 0x45ade7: rows y1..y2, columns x1..x2; the units (on the map, home code 0x45aed1) of buffs / ailments are
	# collected in the strategy context for one group animation unless EV[4043] ≠ 0 (then each unit animates)
	if idx < 7:
		strategy._init_ctx(0, units[0x3c])
	var each := Mem.ev(4043) != 0
	var tg: Array[BUnit] = []
	for y in range(rect[1], rect[3] + 1):
		for x in range(rect[0], rect[2] + 1):
			var c := Vector2i(x, y)
			var u := Rules.unit_at(c) if Rules.in_map(c) else null
			if u == null or u.state != 2 or not home_code_ok(u, side):
				continue
			if idx < 7:
				Mem.w8(Rules.STRAT_CTX + 0xd + tg.size(), u.slot)
				tg.append(u)
			await unit_attr_op(u, idx, v, each)
	if tg.is_empty() or each:
		return
	var anim := 0x2c
	if idx == 6:
		anim = _status_anim(v)
	elif v == 0:
		anim = Mem.r8(0x43e776 + 2 * idx)
	elif v == 6:
		anim = Mem.r8(0x43e777 + 2 * idx)
	if anim == 0xff:
		return
	var cells: Array[Vector2i] = []
	for u in tg:
		cells.append(u.pos)
	if await strategy.script_anim(anim, cells, [], 0x40):
		await checkpoint()
		await post_action()


## 0x45aed1's side filter on the home code (0x42e2ed): < 4 equal, 4 below 2, 5 two or three, 6 any.
static func home_code_ok(u: BUnit, side: int) -> bool:
	var k := Movement.home_code(u)
	return (side < 4 and k == side) or (side == 4 and k < 2) or (side == 5 and (k == 2 or k == 3)) or side == 6


## 0x45aa37 on a unit on the map: idx 0..5 buff level = v, 6 ailments (v & 0x80 cures 0x423fb9, else inflicts
## 0x4240d6), 7 HP / 8 MP through 0x40da4a (EV[4044]) capped at the maximum; idx ≤ 6 with `anim` first plays the
## change on the unit (0x43e6aa).
func unit_attr_op(u: BUnit, idx: int, v: int, anim: bool) -> void:
	if u == null or u.state != 2 or idx > 8:
		return
	if idx < 7 and anim:
		await _attr_anim(u, idx, v & 0xff)
	match idx:
		6:
			if v & 0x80:
				u.cure(v & 0xff)
			else:
				u.inflict(v & 0xff)
		7: u.hp = mini(hp_op(u.hp, v & 0xffffffff), u.max_hp())
		8: u.mp = mini(hp_op(u.mp, v & 0xffff), u.max_mp())
		_: u.set_buff(idx, v & 0xff)
	refresh_units()


## 0x43e6aa(slot, idx, v): the view centres on the unit; a buff going down plays Meff [0x43e776 + 2·idx], going up
## [0x43e777 + 2·idx], unchanged nothing; ailments the 0x40ddaf animation.
func _attr_anim(u: BUnit, idx: int, v: int) -> void:
	await scroll_cell(u.pos)
	var anim := 0xff
	if idx == 6:
		anim = _status_anim(v)
	else:
		var old := u.buff(idx)
		if v < old:
			anim = Mem.r8(0x43e776 + 2 * idx)
		elif v > old:
			anim = Mem.r8(0x43e777 + 2 * idx)
	if anim != 0xff:
		var cells: Array[Vector2i] = [u.pos]
		await strategy.script_anim(anim, cells, [], 0x40)


## 0x40ddaf: 0x80 (cure) → 44; else the last of 麻痹 2 → 50, 禁咒 4 → 51, 混乱 8 → 48, 中毒 0x10 → 49; none → 0xff.
static func _status_anim(v: int) -> int:
	if v & 0x80:
		return 0x2c
	var a := 0xff
	if v & 2:
		a = 0x32
	if v & 4:
		a = 0x33
	if v & 8:
		a = 0x30
	if v & 0x10:
		a = 0x31
	return a


## 0x40da4a with EV[4044] (dword): 0 subtract (never below 1), 1 add, else set.
func hp_op(cur: int, v: int) -> int:
	match Mem.ev(4044):
		0: return cur - v if v < cur else 1
		1: return cur + v
	return v


## op 0x4e (0x4146d4): AI change of one unit (selector) or of every unit of a side in a rectangle (0x459e79).
func op_unit_op_4e(ins: Dictionary) -> void:
	var mode := arg(ins, 0) & 0xff
	var m := arg(ins, 7) & 0xff
	var tp := arg(ins, 8)
	var tx := arg(ins, 9) & 0xff
	var ty := arg(ins, 10) & 0xff
	if mode == 0 or mode == 0xff:
		set_ai(unit_sel(arg(ins, 1)), m, tp, tx, ty)
	else:
		for u in _targets_rect(arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6) & 0xff):
			set_ai(u, m, tp, tx, ty)


## op 0x4f (0x415f47 → 0x4575b8(unit, target, dir, back, scroll, wait)): the unit (selector, else the person's
## first unit) on the map turns to `dir` (target 0xffff) or toward the target unit (0x435539) — away from it with
## back > 0; nothing at all when the facing does not change. A change first centres the view on the unit with
## scroll ≠ 0 (+8 ticks, 0x457771), plays SE 6 (for a direction turn not when byte 0x500ad7 = 2); wait ≠ 0 → 8 ticks.
func op_unit_op_4f(ins: Dictionary) -> void:
	var u := _unit_or_person(arg(ins, 0) & 0xffff)
	if u == null or u.state != 2:
		return
	var tsel := arg(ins, 1) & 0xffff
	var back := arg(ins, 3) & 0xffff
	var scroll := arg(ins, 4)
	var wt := arg(ins, 5)
	var cur := u.dir
	if tsel == 0xffff:
		var d := arg(ins, 2) & 0xff
		if d == cur:
			return
		await _turn_scroll(u, scroll)
		if Mem.r8(Rules.STRAT_ITEM) != 2:
			Audio.play_se(SoundMap.se_name(6))
		u.dir = d
	else:
		var t := _unit_or_person(tsel)
		if t == null or t.state != 2:
			return
		var d2 := actions.dir_to(u.pos, t.pos)
		if d2 == cur:
			return
		await _turn_scroll(u, scroll)
		Audio.play_se(SoundMap.se_name(6))
		u.dir = d2
		if back < 0x8000 and back > 0 and d2 < 4:
			u.dir = [2, 3, 0, 1][d2]
	if u.node:
		u.node.dir = u.dir
		u.node.queue_redraw()
	refresh_units()
	if wt != 0:
		await wait(0.4)


## 0x41b882, else (values < 0x400) the first unit holding the person (0x4029c2, any state).
func _unit_or_person(v: int) -> BUnit:
	var u := unit_sel(v)
	if u == null and v < 0x400:
		u = unit_of_person(v)
	return u


## 0x457771: scroll ≠ 0 → the view centres on the unit, 8 ticks.
func _turn_scroll(u: BUnit, scroll: int) -> void:
	if scroll != 0:
		await scroll_cell(u.pos)
		await wait(0.4)


## op 0x50 (0x415fee): battle only; action 0xffff nothing; the selector's unit, else the person's first unit (a
## person < 0x400, 0x45778f) → unit_action.
func op_unit_status(ins: Dictionary) -> void:
	var action := arg(ins, 1) & 0xffff
	if action == 0xffff:
		return
	var u := _unit_or_person(arg(ins, 0) & 0xffff)
	await unit_action(u, action & 0xff, arg(ins, 2) & 0xffff, arg(ins, 3) & 0xffff)


## 0x45778f(unit, person, action, pre, post): a unit on the map; the view centres on it; pre ≠ 0 → 8 ticks before,
## post ≠ 0 → 8 ticks after (not for actions 0 and 11; 0xffff counts as non-zero); the action itself is
## BattleActions.unit_pose (cases 0..12).
func unit_action(u: BUnit, action: int, pre: int, post: int) -> void:
	if u == null or u.state != 2:
		return
	await scroll_cell(u.pos)
	var waits := action != 0 and action != 11
	if pre != 0 and waits:
		await wait(0.4)
	await actions.unit_pose(u, action)
	if post != 0 and waits:
		await wait(0.4)


## op 0x51 (0x416276): every unit on the map may act again, loses its ailments and gets full HP (MP untouched).
func op_op_51(_ins: Dictionary) -> void:
	for u in units:
		if u.state == 2:
			u.flags = u.flags & ~6
			u.status = 0
			u.hp = u.max_hp()
	refresh_units()


## op 0x53 (0x41569e): retreat one unit (selector) or every unit of a side in a rectangle.
func op_unit_op_53(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var flag := arg(ins, 7)
	if flag == 0xffff:
		flag = 0
	var tg: Array[BUnit] = []
	if mode == 0 or mode == 0xffff:
		var u := unit_sel_cur(arg(ins, 1))
		if u != null:
			tg.append(u)
	else:
		tg = _targets_rect(arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6))
	for u in tg:
		u.flags = u.flags | 0x80
		await remove_unit(u, false, flag != 0)
		u.flags = u.flags & ~0x80


## op 0x31 in a battle: mode 0 removes the person's unit silently; else every unit of a side in a rectangle.
func op_actor_select(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var tg: Array[BUnit] = []
	if mode == 0:
		var u := unit_sel_cur(arg(ins, 1))
		if u != null:
			tg.append(u)
	else:
		tg = _targets_rect(arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6))
	for u in tg:
		await remove_unit(u, true)


## op 0x55 (0x415932): revive a unit (mode 0 selector / mode 1 unit index) at (x, y) or its deployment position.
func op_unit_move(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 0xffff:
		mode = 0
	var u: BUnit = null
	if mode == 0:
		u = unit_sel(arg(ins, 1))
	else:
		var s := arg(ins, 2) & 0xff
		if s < 250 and units[s].state != 2:
			u = units[s]
	var d := arg(ins, 5)
	await revive(u, arg(ins, 3), arg(ins, 4), 2 if d == 0xffff else d)


## op 0x30 in a battle (0x40216a): a unit not on the map appears at its deployment entry.
func op_actor_appear(ins: Dictionary) -> void:
	var u := unit_sel(arg(ins, 0))
	if u == null or u.state == 2:
		return
	var e := entry_of(u)
	if e >= 0:
		await appear(u, e)


## op 0x32 in a battle: scripted move (0x4594ea) — mode 1 picks player slot arg2 (< 20).
func op_actor_move(ins: Dictionary) -> void:
	var u: BUnit = null
	if arg(ins, 0) == 1:
		var s := arg(ins, 2)
		if s < 20:
			u = units[s]
	else:
		var sel := arg(ins, 1)
		u = unit_sel(sel)
		if u == null and sel == 0x401 and Mem.r16(CUR_PERSON) != 0xffff:
			# 0x4594ea: 0x401 = the acting person's first unit (0x456079)
			for o in units:
				if o.pid == Mem.r16(CUR_PERSON) and o.state != 0:
					u = o
					break
	await scripted_move(u, Vector2i(arg(ins, 3), arg(ins, 4)), arg(ins, 5))


## Scripted move 0x4594ea: the unit walks through the AI (flags 6 cleared, 0x80 set, code 0) to the goal made
## reachable by 0x41e6df, set as its point (0x44268c, target 0xff); afterwards the code comes back, 0x80 is cleared
## and the saved flags (bit 3 dropped) are ORed in again, the point (0x44268c) and then the target byte are restored;
## then the facing.
func scripted_move(u: BUnit, goal: Vector2i, d: int) -> void:
	if u == null or u.state != 2 or goal == u.pos or goal.x >= Rules.map_w() or goal.y >= Rules.map_h():
		return
	var tgt := u.target
	var code := u.ai
	var fl := u.flags
	var pt := u.point
	u.flags = (u.flags & ~6) | 0x80
	u.ai = 0
	_set_point(u, _reachable_goal(u, goal))
	await ai.act(u)
	u.ai = code
	u.flags = (u.flags & ~0x80) | (fl & 0xf7)
	_set_point(u, pt)
	u.target = tgt
	if d != 0xffff and d < 4:
		u.dir = d
		if u.node:
			u.node.dir = d
	refresh_units()


## 0x41e6df: while a flood without zones (mp 255, mode 2) cannot reach the goal or the goal is occupied, the next
## goal is 0x43f07c(goal, unit, 1). [G] The original loops forever when no reachable free cell exists: the goal is
## then kept.
func _reachable_goal(u: BUnit, goal: Vector2i) -> Vector2i:
	var g := goal
	for guard in 8:
		if Movement.flood(u, u.pos, 0xff, 2, g, 0) != Movement.NONE and Rules.slot_at(g) == 0xff:
			return g
		g = nearest_free(g, u, 1)
		if g.x == 0xff:
			break
	return goal


## Point setter 0x44268c: inside the map → point = c, target = 0xff.
func _set_point(u: BUnit, c: Vector2i) -> void:
	if c.x >= 0 and c.y >= 0 and c.x < Rules.map_w() and c.y < Rules.map_h():
		u.point = c
		u.target = 0xff


## op 0x6d (0x410d3b): move or revive a unit next to a reference unit (offsets > 40 are negative).
func op_op_6d(ins: Dictionary) -> bool:
	var sel := arg(ins, 0)
	if sel == 0xffff:
		sel = 0
	var reenter := arg(ins, 7) == 1
	var u: BUnit = null
	if sel == 1:
		var s := arg(ins, 2)
		if s < 20 and units[s].state == (3 if reenter else 2):
			u = units[s]
	else:
		u = unit_sel(arg(ins, 1))
	if u == null:
		return false
	var ref := unit_sel(arg(ins, 3))
	if ref == null:
		return false
	var dx := arg(ins, 4)
	var dy := arg(ins, 5)
	var x := ref.pos.x + dx if dx <= 40 else Rules.sat_sub(ref.pos.x, dx - 40)
	var y := ref.pos.y + dy if dy <= 40 else Rules.sat_sub(ref.pos.y, dy - 40)
	if reenter:
		await revive(u, x, y, arg(ins, 6) if arg(ins, 6) != 0xffff else 2)
	else:
		await scripted_move(u, Vector2i(x, y), arg(ins, 6))
	return true


## op 0x58 (0x416796, eex.md §10.2): terrain change / obstacle at a cell or the rectangle from EV 4050.
func op_op_58(ins: Dictionary) -> void:
	var typ := arg(ins, 0) & 0xff
	var revert := arg(ins, 1)
	var terr := arg(ins, 2) & 0xff
	var x := arg(ins, 3) & 0xff
	var y := arg(ins, 4) & 0xff
	var a5 := arg(ins, 5)
	var a6 := arg(ins, 6)
	if a5 == 0xffff: a5 = 0
	if a6 == 0xffff: a6 = 0
	var special := x >= 40
	if special:
		x -= 40
		typ = 0xcd if a5 == 1 else 0xc9
	var origin := Mem.r16(Mem.EV + 4 * 4050)
	Mem.w16(Mem.EV + 4 * 4050, 0xffff)
	var cells: Array[Vector2i] = []
	if origin != 0xffff:
		var ox := origin >> 8
		var oy := origin & 0xff
		for yy in range(mini(oy, y), maxi(oy, y) + 1):
			for xx in range(mini(ox, x), maxi(ox, x) + 1):
				cells.append(Vector2i(xx, yy))
	else:
		cells.append(Vector2i(x, y))
	if Rules.evb(4036) == 0:
		if typ == 0:
			terr = 0x1a
		elif typ == 1 or typ == 2:
			terr = 0x1b
	for c in cells:
		if not view.in_bounds(c):
			continue
		if revert != 0 and revert != 0xffff:
			_revert_terrain(c, -1)
			continue
		place_obstacle(c, terr, typ, a6 == 1, false)
		if special:
			# 0x40b183: the mine record {item 0xd0 + type argument, owner a5 + 1 (0 when a5 = 0)}
			Mem.w8(Mines.rec_addr(c), (arg(ins, 0) + 0xd0) & 0xff)
			Mem.w8(Mines.rec_addr(c) + 1, a5 + 1 if a5 != 0 else 0)
	if (typ == 0 or typ == 2) and a6 == 0:
		Audio.play_se(SoundMap.se_name(0x13))
	refresh_units()


## One cell of 0x4560f3: the terrain becomes `terr`, types 4..200 paste the Gate patch 2·type − 8, the others are
## kept as the cell's map object (drawn by 0x4525da); the change record 0x4b3d21. `mine` is the player's placement
## (no sound here).
func place_obstacle(c: Vector2i, terr: int, typ: int, silent: bool, mine: bool) -> void:
	var old := view.terrain_at(c)
	view.set_terrain(c, terr)
	var node: Node = null
	if typ >= 4 and typ <= 200:
		node = view.add_patch(2 * typ - 8, c)
	else:
		view.add_mark(typ, c)
	terrain_changes.append({"x": c.x, "y": c.y, "new": terr, "old": old, "patch": typ, "silent": silent or mine,
		"node": node})
	_record_terrain(c, terr, old, typ)


## 0x456670(cell, type, 0): the change of that type on the cell is undone.
func remove_obstacle(c: Vector2i, typ: int) -> void:
	_revert_terrain(c, typ)
	refresh_units()


## The 探雷器's retyping of a change record (0x4b3d21 +4) and its map object.
func retype_obstacle(c: Vector2i, from_t: int, to_t: int) -> void:
	for e in terrain_changes:
		if int(e["x"]) == c.x and int(e["y"]) == c.y and int(e["patch"]) == from_t:
			e["patch"] = to_t
	for k in 250:
		var a := 0x4b3d21 + 5 * k
		if Mem.r8(a) == c.x and Mem.r8(a + 1) == c.y:
			Mem.w8(a + 4, to_t)
			break


## Terrain change records 0x4b3d21 (250 × {x, y, new, old, type}).
func _record_terrain(c: Vector2i, new: int, old: int, typ: int) -> void:
	for i in 250:
		var a := 0x4b3d21 + 5 * i
		if Mem.r8(a) == 0xff:
			Mem.w8(a, c.x)
			Mem.w8(a + 1, c.y)
			Mem.w8(a + 2, new)
			Mem.w8(a + 3, old)
			Mem.w8(a + 4, typ)
			return


func _revert_terrain(c: Vector2i, patch: int) -> bool:
	for i in terrain_changes.size():
		var e: Dictionary = terrain_changes[i]
		if int(e["x"]) == c.x and int(e["y"]) == c.y and (patch < 0 or int(e["patch"]) == patch):
			view.set_terrain(c, int(e["old"]))
			var n: Variant = e.get("node")
			if n and is_instance_valid(n):
				(n as Node).queue_free()
			view.marks.erase(c)
			view.overlay.queue_redraw()
			terrain_changes.remove_at(i)
			for k in 250:
				var a := 0x4b3d21 + 5 * k
				if Mem.r8(a) == c.x and Mem.r8(a + 1) == c.y:
					Mem.fill(a, 5, 0xff)
					break
			return true
	return false


## op 0x21 map_mark: kind 0 places an obstacle (like 0x58), kind 1 reverts the cell.
func op_map_mark(ins: Dictionary) -> void:
	var c := Vector2i(arg(ins, 0), arg(ins, 1))
	var kind := arg(ins, 2)
	if kind == 1:
		if _revert_terrain(c, -1):
			Audio.play_se(SoundMap.se_name(0x12))
	else:
		var old := view.terrain_at(c)
		view.set_terrain(c, 0x1a)
		view.add_mark(0, c)
		terrain_changes.append({"x": c.x, "y": c.y, "new": 0x1a, "old": old, "patch": 0, "silent": false, "node": null})
		_record_terrain(c, 0x1a, old, 0)
	refresh_units()


## op 0x59 (0x41688b): gold (int32) + 3 × (item, level: 0xffff → 0, else the low byte) + mode (0xffff → 0);
## gold += (L + 7)·100 (L = 0x40c231); the reward screen 0x44b5a8; GS gold += gold (0x40da71); each item ≠ 0xffff:
## equipment with level 0 gets the level for L (0x407da3), then 0x459950(item, level, flag 0, 0xffff, show 0) —
## silently into the bag — and the item record 0x408b0d.
func op_op_59(ins: Dictionary) -> void:
	var gold := arg(ins, 0) & 0xffffffff
	var ids := []
	var lv := []
	for k in 3:
		ids.append(arg(ins, 1 + 2 * k) & 0xffff)
		var l := arg(ins, 2 + 2 * k) & 0xffff
		lv.append(0 if l == 0xffff else l & 0xff)
	var mode := arg(ins, 7) & 0xffff
	if mode == 0xffff:
		mode = 0
	var avg := _army_avg_level()
	gold += (avg + 7) * 100
	await RewardScreen.present(self, gold, ids, mode, lv)
	Game.change_resource(0, 1, gold)
	for k in 3:
		var iid: int = ids[k]
		if iid == 0xffff:
			continue
		var it := Game.item(iid & 0xff)
		var lvl: int = lv[k]
		if Person.slot_of(it) <= 1 and lvl == 0:
			lvl = Person.auto_level_at(it, avg) & 0xff
		await story_get_item(iid & 0xff, lvl, false)
		Game.record_item(iid)


## 0x40c231: mean level of the army members among persons 0..126 (≥ 1).
func _army_avg_level() -> int:
	var s := 0
	var n := 0
	for pid in 0x7f:
		if Game.is_member(pid):
			s += Game.person(pid).level
			n += 1
	if n == 0:
		return 1
	return maxi(s / n, 1)


## op 0x5b (0x416ae3): rectangle x1, y1, x2, y2 (bytes) and flag (0xffff → 0), battle only → 0x416609.
func op_op_5b(ins: Dictionary) -> void:
	var r := 0
	for i in 4:
		r |= (arg(ins, i) & 0xff) << (8 * i)
	var flag := arg(ins, 4) & 0xffff
	if flag == 0xffff:
		flag = 0
	await goal_rect(flag, r)


## 0x416609(flag, rect): flag 0 keeps the rectangle as the battle's goal area (B+0xc, B+8 = 1; op 0x19 clears B+8);
## another flag shows it once and keeps the stored one; rect −1 shows the stored one. Shown (stored area or flag
## ≠ 0): clamped to the map, the view centred on its middle (0x4165d4), three blinks of 10 ticks on / 10 off.
func goal_rect(flag: int, rect: int) -> void:
	var prev := 0
	if rect != -1:
		if Mem.r8(B + 8) == 1:
			prev = Mem.r32(B + 0xc)
		Mem.w32(B + 0xc, rect)
		if flag == 0:
			Mem.w8(B + 8, 1)
	var r := Mem.r32(B + 0xc)
	if rect != -1 and flag != 0:
		Mem.w32(B + 0xc, prev)
	if Mem.r8(B + 8) == 0 and flag == 0:
		return
	var v := [r & 0xff, (r >> 8) & 0xff, (r >> 16) & 0xff, (r >> 24) & 0xff]
	for i in 4:
		v[i] = mini(v[i], (Rules.map_w() if i % 2 == 0 else Rules.map_h()) - 1)
	if v[0] > v[2] or v[1] > v[3]:
		return
	await scroll_cell(Vector2i(_mid(v[0], v[2]), _mid(v[1], v[3])))
	var cells: Array[Vector2i] = []
	for y in range(v[1], v[3] + 1):
		for x in range(v[0], v[2] + 1):
			cells.append(Vector2i(x, y))
	for k in 3:
		view.goal_cells = cells
		await wait(0.5)
		view.goal_cells = []
		await wait(0.5)


## 0x4165d4: a + ⌈(b − a) / 2⌉ when b − a > 2, else a.
static func _mid(a: int, b: int) -> int:
	var d := b - a
	return a + d / 2 + d % 2 if d > 2 else a


## op 0x5c: blink the person's unit three times.
func op_op_5c(ins: Dictionary) -> bool:
	var p := arg(ins, 0)
	if p >= 0x400:
		return false
	var u := _unit_on_map(p)
	if u == null:
		return false
	await view.center_on(u.pos)
	if u.node and not Game.autoplay:
		for k in 3:
			u.node.flash = 0.8
			await wait(0.5)
			u.node.flash = 0.0
			await wait(0.5)
	return true


## op 0x5d (0x41709c): turn limit — 0 set (≥ turn + 1), 1 add (≤ 255), ≥ 2 subtract (≥ turn + 1); 0xffff → nothing.
func op_op_5d(ins: Dictionary) -> bool:
	var op := arg(ins, 0)
	var v := arg(ins, 1)
	if op == 0xffff:
		return true
	match op:
		0: turn_limit = maxi(v & 0xff, turn)
		1: turn_limit = mini(turn_limit + v, 255)
		_: turn_limit = maxi(turn_limit - v, turn)
	hud.queue_redraw()
	return true


## op 0x6b: effect animation at a cell.
func op_op_6b(ins: Dictionary) -> void:
	var c := Vector2i(arg(ins, 0), arg(ins, 1))
	var eff := arg(ins, 2)
	if arg(ins, 3) != 0 and arg(ins, 3) != 0xffff:
		await view.center_on(c)
	await strategy.play_cell_effect(eff, c)


# ------------------------------------------------------------------ duel (单挑) ops 0x5f-0x68 (DuelLayer)
## Op 0x68 is ScriptHost.op_duel_setup (练武场 fight when byte EV[4087] ≠ 0); the classic duel opens on the battle.
func story_duel(a: int, b: int, backdrop: int) -> void:
	await _duel().setup(a, b, backdrop)


## The battle's DuelLayer (DuelLayer.attach on first use).
func _duel() -> DuelLayer:
	if duel == null or not is_instance_valid(duel):
		duel = DuelLayer.attach(self)
	return duel


func op_duel_say(ins: Dictionary) -> void:
	if duel:
		await duel.appear_say(u16(ins, 0), TextExpand.expand(sarg(ins, 1)), u16(ins, 2))


func op_duel_end(_ins: Dictionary) -> void:
	if duel:
		await duel.open()


func op_duel_start(_ins: Dictionary) -> void:
	if duel:
		await duel.close()
		duel.queue_free()
		duel = null


func op_duel_say2(ins: Dictionary) -> void:
	if duel:
		await duel.say2(u16(ins, 0), TextExpand.expand(sarg(ins, 1)), u16(ins, 2))


func op_duel_action(ins: Dictionary) -> void:
	if duel:
		await duel.action(u16(ins, 0), u16(ins, 1))


func op_duel_action2(ins: Dictionary) -> void:
	if duel:
		await duel.exchange(u16(ins, 0), u16(ins, 1), u16(ins, 2))


func op_duel_action3(ins: Dictionary) -> void:
	if duel:
		await duel.special(u16(ins, 0), u16(ins, 1), u16(ins, 2))


func op_duel_62(ins: Dictionary) -> void:
	if duel:
		await duel.result(u16(ins, 0))


# ------------------------------------------------------------------ save / restore
func save_state() -> Dictionary:
	return {"kind": "battle", "scene": vm.scene if vm else 0, "phase": phase, "map": map_id,
		"field_ready": field_ready, "victory_text": victory_text, "goal_text": goal_text, "bgm": Audio.current_track,
		"event_slots": event_slots.duplicate(),
		"terrain_changes": terrain_changes.map(func(e: Dictionary) -> Dictionary:
			var c := e.duplicate()
			c.erase("node")
			return c)}


func restore_state(d: Dictionary) -> void:
	_restore = d


func _apply_restore() -> void:
	var d := _restore
	_restore = {}
	if d.get("kind", "") != "battle":
		return
	vm.scene = int(d.get("scene", 0))
	_resumed = vm.scene == 1 and int(d.get("phase", PH_PLAYER)) == PH_PLAYER and bool(d.get("field_ready", false))
	victory_text = str(d.get("victory_text", ""))
	goal_text = str(d.get("goal_text", ""))
	event_slots = {}
	var es: Dictionary = d.get("event_slots", {})
	for k in es:
		event_slots[int(k)] = int(es[k])
	if bool(d.get("field_ready", false)) and int(d.get("map", -1)) >= 0:
		map_id = int(d["map"])
		view.load_map(map_id, false)
		terrain_changes = []
		for e: Dictionary in d.get("terrain_changes", []):
			var c := Vector2i(int(e["x"]), int(e["y"]))
			var patch := int(e["patch"])
			var node: Node = null
			if patch >= 4 and patch <= 200:
				if not bool(e.get("silent", false)):
					node = view.add_patch(2 * patch - 8, c)
			else:
				view.add_mark(patch, c)
			var e2 := e.duplicate()
			e2["node"] = node
			terrain_changes.append(e2)
		field_ready = true
		refresh_units()
		refresh_pictures()
		var lead := units[0]
		if lead.on_map():
			view.center_on(lead.pos, false)
	if int(d.get("bgm", -1)) >= 0:
		Audio.play_bgm(int(d["bgm"]))
	ui.set_black(false)
