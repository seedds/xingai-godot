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
		await battle_loop()
	# aftermath scenes
	while vm.active:
		var ran2: bool = await vm.poll()
		if not ran2:
			break
	hud.visible = false
	SoundMap.stop_loop()


## Poll 0x44c601: up to (number of sections) selections of the event scene, while a section ran.
func checkpoint() -> void:
	if _in_checkpoint or not vm.active or vm.scene != 1:
		return
	_in_checkpoint = true
	var n: int = vm.sections(vm.scene).size()
	for k in maxi(n, 1):
		if not vm.active or vm.scene != 1:
			break
		var ran: bool = await vm.poll()
		if not ran:
			break
	refresh_units()
	_in_checkpoint = false


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
			await ui.popup("因为战斗时间过长，撤退。")
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
		for e in range(60, 250):
			var u := units[e]
			if u.exists() and u.state in [1, 2]:
				u.hp = 0
				u.state = 3
		refresh_units()
	if turn > 60:
		print("== flow-test: turn cap, skipping to aftermath of %s" % vm.name)
		vm.scene = mini(2, vm.scene_count() - 1)
		return true
	return false


## One round 0x44ed7f.
func _round(resume: bool) -> void:
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


## 功勋 gain 0x42ab8e (person store 0x508000 + 10·id + 2·s; not when the raw ability is 0xff).
func _merit_gain(u: BUnit, s: int, n: int) -> void:
	var p := u.person
	if p.get_raw(s) == 0xff or u.pid >= 0x66:
		return
	var m := n + Effects.any(u.pid, 69, 0x3a, 1, 0)
	if Mem.r8(0x501b00 + u.slot) != 0:
		m += n
	var a := 0x508000 + 10 * u.pid + 2 * s
	Mem.w16(a, Mem.r16(a) + m)


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
		_buff_decay(units[i])
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
			u.status = 0
			hud.popup_number("恢复", u.pos, Color(0.6, 1, 0.6))
			return
	status_tick(u, Rules.recovery_chance(u, 1))


## Ailment tick 0x42402c(u, p): chance ≥ 100 cures; a counter above 1 counts down; at 1 it ends by EV 4023 (0 roll,
## 1 the deck, 2 always).
func status_tick(u: BUnit, p: int) -> void:
	var s := u.status
	for f in 4:
		var v := (s >> (2 * f)) & 3
		if v == 0:
			continue
		var cure := false
		if p >= 100:
			cure = true
		elif v >= 2:
			s = (s & ~(3 << (2 * f))) | ((v - 1) << (2 * f))
		else:
			match Rules.evb(4023):
				0: cure = Rules.chance2(p, 0)
				1:
					var r := Rules.deck(Rules.DECK_CUR + 1, 1)
					cure = p >= r and r != 0
				_: cure = true
		if cure:
			s &= ~(3 << (2 * f))
	u.status = s


## BuffDecay 0x43c940: levels 5/6 count down, 4 wears off with the fade chance, debuffs recover; then the 精进 timer
## (player units) and the 反間計 control counter (slots ≥ 60).
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
			lv -= 1
		elif lv == 4:
			if Rules.chance2(a, 1):
				lv = 3
		elif b == 100:
			lv = 3
		elif lv < 2:
			lv += 1
		elif Rules.chance2(b, 0):
			lv = 3
		u.set_buff(k, lv)
	if u.kind == 0:
		var c := Mem.r8(0x501b00 + u.slot)
		if c > 1:
			Mem.w8(0x501b00 + u.slot, c - 1)
		elif c == 1 and Rules.chance2(a, 1):
			Mem.w8(0x501b00 + u.slot, 0)
	if u.slot >= 60:
		var c2 := Mem.r8(0x501ad8 + u.slot)
		if c2 > 1:
			Mem.w8(0x501ad8 + u.slot, c2 - 1)
		elif c2 == 1:
			Rules.chance2(100, 0)
			release_control(u)


## 0x4073bc(u, 0): the 反間計 control ends (counter 0, kind − 3, AI code 1) — both changes are undone whatever the
## EV 4078 mode applied.
func release_control(u: BUnit) -> void:
	Mem.w8(0x501ad8 + u.slot, 0)
	u.kind = (u.kind - 3) & 0xff
	u.ai = 1


## Poison 0x44e024(u, 20): max(MaxHP·20 %, 1), never below 1 HP.
func _poison(u: BUnit) -> void:
	if u.state != 2 or not u.poisoned():
		return
	var d := maxi(u.max_hp() * 20 / 100, 1)
	if u.hp <= d:
		d = u.hp - 1
	u.hp = u.hp - d
	if d > 0:
		hud.popup_number(str(d), u.pos, Color(0.7, 0.4, 1))


## Regen 0x43cddd: auras and automatic buffs, terrain / 特效 HP and MP recovery (halved under poison), SP, and the
## per-turn EXP of player units.
func _regen(u: BUnit) -> void:
	if u.state != 2:
		return
	await strategy.turn_auras(u)
	_auto_buffs(u)
	var maxhp := u.max_hp()
	var t := Rules.regen_pct(u.pos)
	var hp := maxhp * t / 100 + maxhp * u.eff(0, 0x25, 0, 0) / 100
	var mp := t + u.eff(1, 0x1b, 0, 0) + u.eff(0x32, 0x44, 0, 0)
	if u.poisoned():
		hp >>= 1
		mp >>= 1
	var sp := u.eff(0x69, 0, 0, 0)
	if sp:
		Rules.add_sp(u.pid, sp, true)
	var g := [0, 0, 0]
	if u.kind == 0:
		var bonus := 100 + (u.person.equip_bonus(8) & 0xff)
		for k in 3:
			g[k] = u.eff(3 + k, [0x1d, 0x73, 0x73][k], 0, 0) * bonus / 100
	if hp > 0 and u.hp < maxhp:
		var h := mini(hp, maxhp - u.hp)
		u.hp = u.hp + h
		hud.popup_number("+%d" % h, u.pos, Color(0.4, 1, 0.4))
	if mp > 0:
		u.mp = mini(u.mp + mp, u.max_mp())
	if g[0] > 0:
		await actions.set_exp(u, g[0])
	if g[1] > 0:
		await actions.equip_exp(u, 0, g[1])
	if g[2] > 0:
		await actions.equip_exp(u, 1, g[2])


## AutoBuffs 0x43d038: 自动提升 rows 0x90..0x96 (masks); 0x3f lifts all six to 6 when any is ≤ 3.
func _auto_buffs(u: BUnit) -> void:
	for i in 7:
		var v := u.eff(0x90 + i, 0x66, 3, 0)
		if v == 0:
			continue
		if v == 0x3f:
			for j in 6:
				if u.buff(j) <= 3:
					for k in 6:
						u.set_buff(k, 6)
					return
			continue
		for j in 6:
			if (v >> j) & 1 and u.buff(j) <= 3:
				u.set_buff(j, Rules.buff_step(u.buff(j), true))


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
	var u := Rules.unit_at(c)
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
## Nearest free cell 0x43f07c(c0, unit, mode 0): c0 if free, else its 4 neighbours; the probe then steps up, right,
## down, left (each step trying the cell and its neighbours); failing that the free cell of least Manhattan distance
## (first in row order).
func nearest_free(c0: Vector2i, u: BUnit) -> Vector2i:
	var c := c0
	for k in 4:
		if Rules.in_map(c):
			if _cell_ok(c, u):
				return c
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
			if _cell_ok(p, u):
				var dd := absi(c0.y - y) + absi(c0.x - x)
				if dd < bd:
					bd = dd
					best = p
	return best if best.x >= 0 else c0


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


## Retreat line 0x40c00f (Imsg 650 + entry).
func _retreat_line(u: BUnit) -> void:
	var line := Game.text(650 + u.pid) if u.pid < 49 else ""
	if line == "":
		return
	await view.ensure_visible(u.pos)
	await ui.dialog.talk(Game.person_face(u.pid), u.person.name, line, _dialog_top(u.pid))


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


func open_menu() -> void:
	if menu_ready():
		view.cell_clicked.emit(view.cursor_cell, MOUSE_BUTTON_RIGHT)


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
## op 0x44 battle_init (0x4121e2): pages reset, hit counters and 二次行动 bytes cleared, entries 0..19 = the sortie
## list, the rest empty; accumulators = EV 4017; visibility map cleared; sortie lists reset (0x41c96d).
func op_battle_init(_ins: Dictionary) -> void:
	Mem.w16(0x500ad4, 0)
	Mem.fill(0x508a00, 0x200, 0)
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
	await _build_sortie(0)


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


## Sortie builder 0x418597(param): the protagonist first unless a flag-ring entry is 0, then the forced army
## members; the selection screen when the maximum differs from that count (+1 for a battle); writes the u16 list.
func _build_sortie(param: int) -> void:
	var lst: Array[int] = []
	var any_zero := false
	for i in 20:
		if Mem.r16(Game.SORTIE_EXCLUDED + 2 * i) == 0:
			any_zero = true
			break
	if not any_zero:
		lst.append(0)
	for i in 20:
		var f := Mem.r16(Game.SORTIE_FORCED + 2 * i)
		if f != 0 and f != 0xffff and f < 0x400 and Game.is_member(f):
			lst.append(f)
	var n := lst.size() + (1 if param != 1 else 0)
	if Mem.r8(Game.SORTIE_MAX) < n:
		Mem.w8(Game.SORTIE_MAX, n)
	if Mem.r8(Game.SORTIE_MAX) != n:
		var excluded: Array[int] = []
		for i in 20:
			excluded.append(Mem.r16(Game.SORTIE_EXCLUDED + 2 * i))
		lst = await SortieScreen.choose(ui, self, Mem.r8(Game.SORTIE_MAX), lst, excluded)
	for k in lst.size():
		Mem.w16(SORTIE + 2 * k, lst[k])
	if param != 1 and Mem.r32(Game.SORTIE_RING + 4) == 0:
		Game.reset_sortie_params()
	Mem.w16(SORTIE + 2 * lst.size(), 0xffff)
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("  sortie -> %s" % [lst])


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


func _dialog_top(pid: int) -> bool:
	var u := unit_of_person(pid)
	if u and u.on_map():
		var sp := view.cell_pos(u.pos) - view.camera.position
		return sp.y > 260
	return false


func on_speaker(pid: int) -> void:
	var u := unit_of_person(pid)
	if u and u.on_map():
		await view.ensure_visible(u.pos)


# ------------------------------------------------------------------ tests
## op 0x3f: turn (round + 1) compared with the argument.
func op_test_turn(ins: Dictionary) -> bool:
	return Game.compare(turn, arg(ins, 0), arg(ins, 1))


## op 0x40: the phase byte == arg & 0xff.
func op_test_side(ins: Dictionary) -> bool:
	return phase == (arg(ins, 0) & 0xff)


## op 0x42 (0x428f36): a result already set, a unit 60..250 (inclusive) in state 3/4 that is the boss, or no
## 敌军/援军 (CountUnits code 5) on the map.
func op_test_event5(_ins: Dictionary) -> bool:
	if not field_ready:
		return false
	if result != 0:
		return true
	if Mem.r16(READER + 0x3d04) & 1:
		var boss := Mem.r16(READER + 0x3d06)
		for i in range(60, 251):
			var a := Mem.UNITS + i * Mem.UNIT_SIZE
			if Mem.r8(a + 0xc) in [3, 4] and Mem.r16(a) == boss:
				return true
	return Rules.count_units(5)[0] == 0


## op 0x43 (0x44ca6d): a unit 0..60 (inclusive) in state 3/4 that is the lose-person; else (unit 0's person ≠ 0)
## no kind-0 unit on the map, or (person 0 in slot 0) no unit 0..20 in state 1/2.
func op_test_event6(_ins: Dictionary) -> bool:
	if not field_ready:
		return false
	if result != 0:
		return true
	if Mem.r16(READER + 0x3d08) & 1:
		var lp := Mem.r16(READER + 0x3d0a)
		for i in range(0, 61):
			var u := units[i]
			if u.state in [3, 4] and Mem.r16(u.addr) == lp:
				return true
	if Mem.r32(units[0].addr) != 0:
		return Rules.count_units(0)[0] == 0
	for i in range(0, 21):
		if units[i].state in [1, 2]:
			return false
	return true


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
	for y in range(y1, y2 + 1):
		for x in range(x1, x2 + 1):
			if sel_matches_cell(sel, Vector2i(x, y)):
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
	return BattleAttrs.test(self, arg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3))


func op_set_attr(ins: Dictionary) -> void:
	await BattleAttrs.set_attr(self, arg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3))
	refresh_units()


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


func op_ui_5a(_ins: Dictionary) -> void:
	pass


## op 0x54: the retreat check pass (0x42bc14).
func op_ui_54(_ins: Dictionary) -> void:
	await post_action()


func op_scroll_to(ins: Dictionary) -> void:
	if Rules.evb(4087) != 0:
		return
	await view.center_on(Vector2i(arg(ins, 0), arg(ins, 1)))


## op 0x15 in a battle: a bubble at a0's unit when a1 ≠ −1.
func op_unit_say(ins: Dictionary) -> void:
	var u := unit_sel(arg(ins, 0))
	if u == null or not u.on_map():
		return
	await view.ensure_visible(u.pos)
	hud.popup_number(sarg(ins, 2), u.pos, Color(1, 1, 0.6))
	await wait(0.9)


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


## op 0x4d (0x415551, eex.md §10.1): buffs, ailments (2-bit counters) and HP / MP (EV 4044) of a unit / units.
func op_unit_op_4d(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var tg: Array[BUnit] = []
	if mode == 0 or mode == 0xffff:
		var u := unit_sel_cur(arg(ins, 1))
		if u != null and u.state == 2:
			tg.append(u)
	elif mode == 1:
		var s := arg(ins, 2) & 0xff
		if s < 250 and units[s].state == 2:
			tg.append(units[s])
	else:
		tg = _targets_rect(arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6), arg(ins, 7))
	var bi := arg(ins, 8)
	var bv := arg(ins, 9)
	var stv := arg(ins, 10)
	var hpd := arg(ins, 11)
	var mpd := arg(ins, 12)
	for u in tg:
		if bi != 0xffff and bi < 6 and bv != 0xffff:
			u.set_buff(bi, 6 if bv == 2 else (3 if bv == 1 else bv & 0xff))
		if stv != 0xffff:
			if stv & 0x80:
				u.cure(stv & 0x1e)
			else:
				u.inflict(stv & 0x1e)
		if hpd != 0 and hpd != 0xffff:
			u.hp = mini(hp_op(u.hp, hpd), u.max_hp())
			if not Game.autoplay:
				hud.popup_number(str(hpd), u.pos)
		if mpd != 0 and mpd != 0xffff:
			u.mp = mini(hp_op(u.mp, mpd), u.max_mp())
		if not Game.autoplay and u.node:
			u.node.flash = 0.6
			await wait(0.25)
			u.node.flash = 0.0
	refresh_units()
	await post_action()


## 0x40da4a with EV 4044: 0 subtract (never below 1), 1 add, 2 set.
func hp_op(cur: int, v: int) -> int:
	match Rules.evb(4044):
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


## op 0x4f (0x415f47): turn a unit toward another (or to a direction; back > 0 turns away); SE 6.
func op_unit_op_4f(ins: Dictionary) -> void:
	var u := unit_sel(arg(ins, 0))
	if u == null or u.state != 2:
		return
	var p2 := arg(ins, 1)
	var back := arg(ins, 3)
	var scroll := arg(ins, 4)
	var wt := arg(ins, 5)
	if scroll != 0 and scroll != 0xffff:
		await view.ensure_visible(u.pos)
		await wait(0.4)
	var d := u.dir
	if p2 != 0xffff:
		var t := unit_sel(p2)
		if t and t.state == 2:
			d = actions.dir_to(u.pos, t.pos)
	else:
		d = arg(ins, 2) & 3
	if back != 0xffff and back > 0:
		d = (d + 2) & 3
	if d != u.dir:
		u.dir = d
		if u.node:
			u.node.dir = d
			u.node.queue_redraw()
		if Mem.r8(Rules.STRAT_ITEM) != 2:
			Audio.play_se(SoundMap.se_name(6))
	if wt != 0 and wt != 0xffff:
		await wait(0.4)


## op 0x50 (0x415fee): a battle-sprite action 0..12 of a unit; pre / post waits when the flags are non-zero.
func op_unit_status(ins: Dictionary) -> void:
	var u := unit_sel(arg(ins, 0))
	if u == null or u.state != 2 or u.node == null:
		return
	var action := arg(ins, 1)
	if action == 0xffff:
		return
	var pre := arg(ins, 2)
	var post := arg(ins, 3)
	var waits := action != 0 and action != 11
	await view.ensure_visible(u.pos)
	if pre != 0 and pre != 0xffff and waits:
		await wait(0.4)
	await actions.unit_pose(u, action)
	if post != 0 and post != 0xffff and waits:
		await wait(0.4)


## op 0x51 (0x416276): every unit on the map may act again, loses its ailments and gets full HP (MP untouched).
func op_op_51(_ins: Dictionary) -> void:
	for u in units:
		if u.state == 2:
			u.flags = u.flags & ~6
			u.status = 0
			u.hp = u.max_hp()
	refresh_units()


## op 0x52 in a battle: selectors 0x400..0x402 mean the current unit; the unit is refreshed.
func op_op_52(ins: Dictionary) -> void:
	var pid := arg(ins, 0)
	if pid >= 0x400 and pid <= 0x402:
		if current_unit == null:
			return
		ins = ins.duplicate(true)
		ins["args"][0] = current_unit.pid
	elif pid >= 0x400:
		return
	super.op_op_52(ins)
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
		u = unit_sel(arg(ins, 1))
	await scripted_move(u, Vector2i(arg(ins, 3), arg(ins, 4)), arg(ins, 5))


## Scripted move 0x4594ea: the unit walks to the cell through the AI (flag 0x80, code 0, target point = the cell,
## 100 move points, no attack); target, code, flags and point are restored afterwards; then the facing.
func scripted_move(u: BUnit, goal: Vector2i, d: int) -> void:
	if u == null or u.state != 2 or goal == u.pos or goal.x >= Rules.map_w() or goal.y >= Rules.map_h():
		return
	var tgt := u.target
	var code := u.ai
	var fl := u.flags
	var pt := u.point
	u.flags = (u.flags & ~6) | 0x80
	u.ai = 0
	u.point = goal
	await view.ensure_visible(u.pos)
	await ai.act(u)
	u.ai = code
	u.flags = fl & ~0x80 & 0xf7
	u.point = pt
	u.target = tgt
	if d != 0xffff and d < 4:
		u.dir = d
		if u.node:
			u.node.dir = d
	refresh_units()


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
	if x >= 40:
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
		var old := view.terrain_at(c)
		view.set_terrain(c, terr)
		var node: Node = null
		if typ >= 4 and typ <= 200:
			node = view.add_patch(2 * typ - 8, c)
		else:
			view.add_mark(typ, c)
		terrain_changes.append({"x": c.x, "y": c.y, "new": terr, "old": old, "patch": typ, "silent": a6 == 1, "node": node})
		_record_terrain(c, terr, old, typ)
	if (typ == 0 or typ == 2) and a6 == 0:
		Audio.play_se(SoundMap.se_name(0x13))
	refresh_units()


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


## op 0x59 (0x41688b): rewards: gold = arg + (L + 7)·100 (L = the army's mean level 0x40c231); up to 3 items
## (equipment level 0 → automatic for L).
func op_op_59(ins: Dictionary) -> void:
	var avg := _army_avg_level()
	var gold := arg(ins, 0) + (avg + 7) * 100
	Game.gold = Game.gold + gold
	await ui.popup("得到了 %d 两黄金。" % gold, 0.0 if not Game.demo else 1.0)
	for k in 3:
		var iid := arg(ins, 1 + 2 * k)
		if iid == 0xffff or iid > 0xff:
			continue
		var lvl := arg(ins, 2 + 2 * k)
		if lvl == 0xffff:
			lvl = 0
		var it := Game.item(iid)
		var equip := Person.slot_of(it) < 2
		var xp := 0
		if equip:
			if lvl == 0:
				lvl = Person.auto_level_at(it, avg)
			xp = Person.exp_at_level(lvl, Person.max_item_level(it))
		Game.add_item(iid, maxi(lvl, 1) if equip else 0, xp)
		await ui.popup("得到了%s%s。" % [it.get("name", "?"), ("（Lv%d）" % lvl) if equip else ""], 0.0 if not Game.demo else 1.0)


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


## op 0x5b: highlight a rectangle.
func op_op_5b(ins: Dictionary) -> void:
	var cells: Array[Vector2i] = []
	for y in range(mini(arg(ins, 1), arg(ins, 3)), maxi(arg(ins, 1), arg(ins, 3)) + 1):
		for x in range(mini(arg(ins, 0), arg(ins, 2)), maxi(arg(ins, 0), arg(ins, 2)) + 1):
			cells.append(Vector2i(x, y))
	view.goal_cells = cells
	if not cells.is_empty():
		await view.center_on(cells[cells.size() / 2])


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
func _duel() -> DuelLayer:
	if duel == null:
		duel = DuelLayer.new()
		duel.stage = self
		ui.add_child(duel)
		ui.move_child(duel, ui.dialog.get_index())
	return duel


func op_duel_setup(ins: Dictionary) -> void:
	await _duel().setup(arg(ins, 0), arg(ins, 1), arg(ins, 2))


func op_duel_say(ins: Dictionary) -> void:
	await _duel().appear_say(arg(ins, 0), sarg(ins, 1), arg(ins, 2))


func op_duel_end(_ins: Dictionary) -> void:
	await _duel().open()


func op_duel_start(_ins: Dictionary) -> void:
	if duel:
		await duel.close()


func op_duel_say2(ins: Dictionary) -> void:
	await _duel().say2(arg(ins, 0), sarg(ins, 1), arg(ins, 2))


func op_duel_action(ins: Dictionary) -> void:
	await _duel().action(arg(ins, 0), arg(ins, 1))


func op_duel_action2(ins: Dictionary) -> void:
	await _duel().exchange(arg(ins, 0), arg(ins, 1), arg(ins, 2))


func op_duel_action3(ins: Dictionary) -> void:
	await _duel().special(arg(ins, 0), arg(ins, 1), arg(ins, 2))


func op_duel_62(ins: Dictionary) -> void:
	await _duel().result(arg(ins, 0))


# ------------------------------------------------------------------ save / restore
func save_state() -> Dictionary:
	return {"kind": "battle", "scene": vm.scene if vm else 0, "phase": phase, "map": map_id,
		"field_ready": field_ready, "victory_text": victory_text, "goal_text": goal_text, "bgm": Audio.current_track,
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
		var lead := units[0]
		if lead.on_map():
			view.center_on(lead.pos, false)
	if int(d.get("bgm", -1)) >= 0:
		Audio.play_bgm(int(d["bgm"]))
	ui.set_black(false)
