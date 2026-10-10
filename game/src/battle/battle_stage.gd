class_name BattleStage
extends ScriptHost
## Battle (S_xx) runner.
## Scene 0 of an S file = deployment + pre-battle events (change_scene mode 3 creates the field),
## scene 1 = event loop polled at battle checkpoints while the turn loop runs,
## later scenes = aftermath (linear). See docs/rules.md §9-§10 and docs/eex.md §4.

signal unit_died(u: BUnit)

const PH_PLAYER := 0
const PH_FRIEND := 1
const PH_ENEMY := 2

var view: BattleView
var hud: BattleHUD
var units: Array[BUnit] = []
var deploy: Array = []            # 115 deployment entries (R+0x2044)
var sortie: Array[int] = []       # persons chosen to sortie (0x48b350 list)
var turn := 0
var turn_limit := 0
var level_offset := 0
var boss_pid := -1
var leader_pid := -1
var climate := 0
var weather_level := 1
var phase := PH_PLAYER
var field_ready := false
var battle_over := false
var victory := false
var map_id := -1
var victory_text := ""
var goal_text := ""
var actions: BattleActions
var ai: BattleAI
var input: BattleInput
var _restore: Dictionary = {}
var _in_checkpoint := false
var current_unit: BUnit
var terrain_changes: Array = []
var _occ: Dictionary = {}    # cell → unit, see unit_at
var _occ_gen := -1
var _resumed := false        # loaded from a save made during the player phase: its start already happened

## deployment ai_mode 0..6 → AI code (table 0x48e380)
const AI_CODE := [3, 1, 2, 0, 0, 4, 4]
const WEATHER_TABLE := [[0, 0, 0, 1, 2, 3], [0, 0, 0, 0, 1, 2], [0, 1, 2, 2, 3, 3], [0, 0, 1, 1, 4, 4], [0, 1, 4, 4, 4, 4]]
const WEATHER_NAMES := ["晴", "阴", "雨", "暴雨", "雪"]


func _ready() -> void:
	super._ready()
	view = BattleView.new()
	add_child(view)
	view.input_enabled = false
	view.show_cursor = false
	hud = BattleHUD.new()
	hud.stage = self
	ui.add_child(hud)
	ui.move_child(hud, 0)
	actions = BattleActions.new(self)
	ai = BattleAI.new(self)
	input = BattleInput.new(self)
	for s in 115:
		var u := BUnit.at(s)
		units.append(u)
	for i in 115:
		deploy.append({"person": 0xffff})


func _exit_tree() -> void:
	if hud and is_instance_valid(hud):
		hud.queue_free()
	if duel and is_instance_valid(duel):
		duel.queue_free()     # it lives in the UI layer, which outlasts the stage


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


func battle_loop() -> void:
	var was_auto := Game.autoplay
	if OS.get_environment("WG_INPUTBOT") != "":
		Game.autoplay = false
	if turn == 0:
		turn = 1
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		for u in units:
			if u.exists() and u.slot < 35:
				print("  start: slot %d %s state %d pos %s hp %d" % [u.slot, u.person.name, u.state, u.pos, u.hp])
	view.input_enabled = true
	view.show_cursor = true
	hud.visible = true
	if OS.get_environment("WG_SAVETEST") != "" and turn >= 2:
		var alive := 0
		for u in units:
			if u.active(): alive += 1
		print("SAVETEST resumed turn %d, %d active units, hero hp %d" % [turn, alive, units[0].hp])
	while not _battle_finished():
		# ---- player phase
		phase = PH_PLAYER
		await hud.phase_banner("第%d回合　我军" % turn)
		if _resumed:
			_resumed = false
		else:
			_phase_start_effects(0, 35)
			await checkpoint()
			if _battle_finished(): break
		await input.player_phase()
		if _battle_finished(): break
		# ---- friend phase (AI-controlled units among 0..34); its events run even without such units (0x44e851)
		phase = PH_FRIEND
		var friends := _has_ai_units(0, 35)
		if friends:
			await hud.phase_banner("友军")
		await checkpoint()
		if _battle_finished(): break
		if friends:
			await ai.run_phase(0, 35)
			if _battle_finished(): break
		# ---- enemy phase
		phase = PH_ENEMY
		await hud.phase_banner("敌军")
		_phase_start_effects(35, 115)
		await checkpoint()
		if _battle_finished(): break
		await ai.run_phase(35, 115)
		if _battle_finished(): break
		# ---- next round
		for u in units:
			if u.exists():
				u.moved = false
				u.acted = false
				if u.node:
					u.node.greyed = false
		turn += 1
		Mem.w8(0x4b3d0a, turn)       # ctx+2 (0x44e851); ctx+1 is the battle-over flag
		if OS.get_environment("WG_SAVETEST") != "" and turn == 2:
			Game.save_game(18, save_state())     # not one of the player's slots 0-9
			var alive := 0
			for u in units:
				if u.active(): alive += 1
			print("SAVETEST saved turn %d, %d active units, hero hp %d" % [turn, alive, units[0].hp])
			get_tree().quit()
			return
		if Game.god and Game.autoplay and turn > 12:
			# debug flow-test cheat: clear the field so scripted victory can trigger
			for e in range(35, 115):
				if units[e].exists() and units[e].state in [BUnit.STATE_HIDDEN, BUnit.STATE_ON_MAP]:
					units[e].hp = 0
					units[e].state = 3
			refresh_units()
		if Game.god and Game.autoplay and turn > 60:
			# flow-test: the victory needs a scripted move the autoplay AI never makes (e.g. a duel
			# that only starts when the hero reaches a certain enemy) — go to the aftermath
			print("== flow-test: turn cap, skipping to aftermath of %s" % vm.name)
			vm.scene = mini(2, vm.scene_count() - 1)
			break
		_update_weather_random()
	view.input_enabled = false
	view.show_cursor = false
	view.clear_highlights()


func trace_info() -> String:
	return "turn %d phase %d" % [turn, phase]


func _battle_finished() -> bool:
	return battle_over or not vm.active or vm.scene != 1 or not is_inside_tree()


func _has_ai_units(a: int, b: int) -> bool:
	for i in range(a, b):
		var u := units[i]
		if u.active() and u.mode != 7:
			return true
	return false


## Battle checkpoint (0x4180c1): one selection over the event scene — the last section whose
## conditions hold runs. (Always-true bookkeeping sections in this mod rely on that.)
func checkpoint() -> void:
	if _in_checkpoint or not vm.active or vm.scene != 1:
		return
	_in_checkpoint = true
	await vm.poll()
	refresh_units()
	_in_checkpoint = false


# ------------------------------------------------------------------ deployment ops
func op_battle_init(_ins: Dictionary) -> void:
	for i in 256:
		Mem.set_flag(i, false)
	Mem.w32(0x55e9d4, 0)
	for i in 115:
		deploy[i] = {"person": 0xffff, "flags": 0}
		Mem.w8(0x55a500 + i, 0)
	# players = sortie list
	var lst := sortie_list()
	for k in mini(lst.size(), 15):
		deploy[k] = {"person": lst[k], "flags": 0, "x": 0, "y": 0, "hidden": false}


## The sortie list u32[] @0x48b350 (0xffff-terminated), set by the 出场 screen / scripts.
func sortie_list() -> Array[int]:
	var out: Array[int] = []
	for k in 32:
		var v := Mem.r32(0x48b350 + 4 * k) & 0xffff
		if v == 0xffff:
			break
		out.append(v)
	return out


func set_sortie_list(lst: Array) -> void:
	for k in lst.size():
		Mem.w32(0x48b350 + 4 * k, int(lst[k]))
	Mem.w32(0x48b350 + 4 * lst.size(), 0xffff)


func op_battle_settings(ins: Dictionary) -> void:
	turn_limit = arg(ins, 2)
	var a3 := arg(ins, 3)
	if a3 == 0xffff:
		level_offset = 0
	elif a3 <= 50:
		level_offset = a3
	else:
		level_offset = -(a3 - 50)
	var a5 := arg(ins, 5)
	boss_pid = -1 if a5 == 0xffff else a5
	var a7 := arg(ins, 7)
	leader_pid = -1 if a7 == 0xffff else a7
	var a8 := arg(ins, 8)
	climate = 0 if a8 == 0xffff else clampi(a8, 0, 4)
	var a9 := arg(ins, 9)
	weather_level = 1 if a9 == 0xffff else clampi(a9, 0, 5)


func _entry_from(e: Array, enemy: bool) -> Dictionary:
	var i := 0
	var d := {}
	var v := func(k: int) -> int:
		var x: Variant = e[k]
		if x is Dictionary:
			return Mem.ev(int(x.get("var", 0)))
		return int(x)
	d["person"] = v.call(0)
	i = 1
	d["kind3"] = false
	if enemy:
		d["kind3"] = v.call(1) not in [0, 0xffff]
		i = 2
	d["hidden"] = v.call(i) not in [0, 0xffff]
	d["x"] = v.call(i + 1)
	d["y"] = v.call(i + 2)
	d["dir"] = v.call(i + 3)
	var lv: int = v.call(i + 4)
	d["lv"] = 0 if lv == 0xffff else lv
	var promo: int = v.call(i + 5)
	d["promo"] = 2 if promo == 0xffff else promo
	var aim: int = v.call(i + 6)
	d["ai"] = 1 if aim == 0xffff else aim
	d["ai_person"] = v.call(i + 7)
	d["ai_x"] = v.call(i + 8)
	d["ai_y"] = v.call(i + 9)
	d["flags"] = (1 if enemy else 2) | (2 if d["kind3"] else 0) | (4 if d["hidden"] else 0)
	return d


func op_battle_allies(ins: Dictionary) -> void:
	var a: Array = ins["args"]
	for k in mini(a.size(), 20):
		var d := _entry_from(a[k], false)
		if d["person"] == 0xffff:
			continue
		deploy[15 + k] = d


func op_battle_enemies(ins: Dictionary) -> void:
	var a: Array = ins["args"]
	for k in mini(a.size(), 80):
		var d := _entry_from(a[k], true)
		if d["person"] == 0xffff:
			continue
		deploy[35 + k] = d


## op 0x4b: player deployment entry k → position (x, y), dir.
func op_op_4b(ins: Dictionary) -> void:
	if Mem.r32(0x55e9d4) != 0:
		super.op_op_4b(ins)
		return
	var k := arg(ins, 0)
	if k < 0 or k >= 15:
		return
	var d: Dictionary = deploy[k]
	if int(d.get("person", 0xffff)) == 0xffff or int(d.get("flags", 0)) & 3 != 0:
		return
	d["x"] = arg(ins, 1)
	d["y"] = arg(ins, 2)
	d["dir"] = arg(ins, 3)
	d["hidden"] = arg(ins, 4) not in [0, 0xffff]
	d["flags"] = 4 if d["hidden"] else 0
	deploy[k] = d


## op 0x48 (0x412dd6): equipment codes for the ally/enemy deployment entry of a person (slots 15+),
## used when the battle starts (0x44cc85, see Person.equip_code). 0xffff → 0.
func op_battle_equipment(ins: Dictionary) -> void:
	var pid := arg(ins, 0)
	if pid > 0x3ff:
		return
	for i in range(15, 115):
		var d: Dictionary = deploy[i]
		if int(d.get("person", 0xffff)) == pid:
			var keys := ["weapon", "wlv", "armor", "alv", "acc"]
			for k in 5:
				var v := arg(ins, 1 + k)
				d[keys[k]] = 0 if v == 0xffff else v & 0xff
			deploy[i] = d
			return


## op 0x4a (0x415d92 → 0x41856a): build the sortie list. Forced persons (5 here + any from op 0x06)
## that are party members go first; if all 9 flag bytes are non-zero the protagonist is included;
## when the stored max exceeds the forced count the player picks the rest.
func op_battle_prepare(ins: Dictionary) -> void:
	for k in 5:
		Mem.w32(SORTIE_FORCED + 4 * k, arg(ins, 1 + k))
	for k in 4:
		Mem.w32(SORTIE_FORCED + 4 * (5 + k), arg(ins, 6 + k))
	Mem.w32(SORTIE_FLAGS + 4 * 9, arg(ins, 10))
	await build_sortie()


# ------------------------------------------------------------------ battlefield creation
## Touch shell: at the player phase's top level (no unit selected) its 菜单 is the right click there.
func menu_ready() -> bool:
	return input != null and input.idle


func open_menu() -> void:
	if menu_ready():
		view.cell_clicked.emit(view.cursor_cell, MOUSE_BUTTON_RIGHT)


func op_change_scene(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 3:
		var v := arg(ins, 4)
		if v == 0xffff:
			v = 0
		await create_battlefield(v)
	else:
		# story-style picture inside a battle file (rare): show it full screen
		var val := 0
		match mode:
			0: val = arg(ins, 1)
			1: val = arg(ins, 2)
			2: val = arg(ins, 3)
		var entry := val + ({0: 0, 1: 114, 2: 40}.get(mode, 0) as int)
		hud.show_picture(Assets.tex("gfx/backgrounds/%03d.png" % entry))


func trimmed_mean_level() -> int:
	var lv: Array[int] = []
	for pid in sortie_list():
		lv.append(Game.person(pid).level)
	if lv.is_empty():
		return 1
	lv.sort()
	lv.reverse()
	var n := lv.size()
	var cut := n / 4
	var s := 0
	var c := 0
	for i in range(cut, n - cut):
		s += lv[i]
		c += 1
	return s / maxi(c, 1)


func create_battlefield(id: int) -> void:
	map_id = id
	view.load_map(id)
	for u in units:
		u.reset(u.slot)
		if u.node:
			u.node.queue_free()
			u.node = null
	Mem.fill(0x569f00, 115, 0)
	var base := maxi(1, trimmed_mean_level() + level_offset)
	var next_p := 0
	var next_f := 15
	var next_e := 35
	for i in 115:
		var d: Dictionary = deploy[i]
		var pid := int(d.get("person", 0xffff))
		if pid == 0xffff:
			continue
		var flags := int(d.get("flags", 0))
		var slot := -1
		if flags & 3 == 0:
			slot = next_p
			next_p += 1
		elif flags & 1:
			slot = next_e
			next_e += 1
		else:
			slot = next_f
			next_f += 1
		if slot < 0 or slot >= 115 or (flags & 3 == 0 and slot >= 15) or (flags & 1 == 0 and flags & 2 and slot >= 35):
			continue
		var u := units[slot]
		var p := Game.person(pid)
		if p == null:
			continue
		var generated := flags & 3 != 0 and not (flags & 1 == 0 and Game.is_member(pid))
		if generated:
			# reload base data, then level/promotion/equipment from the deployment entry
			Game.reset_person(pid)
			var lv := int(d.get("lv", 0))
			var level := mini(base + lv, 70) if lv <= 50 else maxi(base - (lv - 50), 1)
			_promote(p, int(d.get("promo", 2)), level)
			# 0x44cc85 → 0x4429f9 per slot; ops 0x46/0x47 start entries with code 0 (default equipment for the
			# class and level, 0x407fe7) and level 1, op 0x48 sets other codes
			p.equip_code(0, int(d.get("weapon", 0)), int(d.get("wlv", 1)))
			p.equip_code(1, int(d.get("armor", 0)), int(d.get("alv", 1)))
			p.equip_code(2, int(d.get("acc", 0)), 0xff)
		_unit_init(u, pid, flags, int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("dir", 2)), bool(d.get("hidden", false)))
		if flags & 3 != 0:
			# SetAI refuses party members: one deployed as an ally keeps AI code 0 from the reset and the target
			# point its slot had, and acts in the ally phase (not player-controlled: its colour is 1)
			_set_ai(u, clampi(int(d.get("ai", 1)), 0, 6), int(d.get("ai_person", 0xffff)), int(d.get("ai_x", 0)), int(d.get("ai_y", 0)))
	# after 0x44cc85 (0x44d427): flag 0x80 and status bits 0x1e cleared; player-side units of the player's colour
	# are player-controlled (code 7)
	for u in units:
		u.flags = u.flags & ~0x80
		u.status = u.status & ~0x1e
		if u.slot < 35 and u.state != 0 and u.colour == 0:
			u.mode = 7
	field_ready = true
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("battlefield map=%d sortie=%s" % [id, sortie_list()])
		for u in units:
			if u.exists():
				print("  slot %d pid %d %s state %d pos %s hp %d/%d mode %d lv %d cls %d" % [u.slot, u.pid, u.person.name, u.state, u.pos, u.hp, u.max_hp(), u.mode, u.level(), u.cls()])
	refresh_units()
	hud.visible = true
	Mem.w8(0x4b3d08, map_id)


## Promote (0x442890): promo 0 none; 1 → +1 tier at level ≥ 20; 2 → +1 at ≥ 20, +2 at ≥ 40 (classes ≤ 38).
func _promote(p: Person, promo: int, level: int) -> void:
	if p.cls <= 38:
		var t := p.cls % 3
		var base_c := p.cls - t
		if promo == 1 and level >= 20:
			p.cls = mini(p.cls + 1, base_c + 2)
		elif promo == 2:
			if level >= 40:
				p.cls = mini(p.cls + 2, base_c + 2)
			elif level >= 20:
				p.cls = mini(p.cls + 1, base_c + 2)
	if level > p.level:
		p.level_up(level - p.level)


## SetAI (0x459d8b): ai_mode 0..6 → AI code (table 0x48e380) and clears flag 0x80; modes 3 and 5 also
## set the target person (unit[8] = its slot), 4 and 6 the target point (unit[8] = 0xff, [9], [10] = x, y).
## Other modes change nothing; a target person without a unit (0x45a751) or a point off the map (0x45a6bf)
## leaves the old target. Refused for party members (0x41a190: person byte +0x2a == 0), wherever they stand.
func _set_ai(u: BUnit, ai_mode: int, ai_person: int, ax: int, ay: int) -> void:
	if ai_mode < 0 or ai_mode > 6 or Game.is_member(u.pid):
		return
	u.flags = u.flags & ~0x80
	u.mode = AI_CODE[ai_mode]
	match ai_mode:
		3, 5:
			var s := DataTransfer.unit_slot_of(ai_person) if ai_person != 0xffff else -1
			if s >= 0:
				Mem.w8(u.addr + 8, s)
				u.extra["ai_person"] = ai_person
		4, 6:
			if ax < view.map_w and ay < view.map_h:
				Mem.w8(u.addr + 8, 0xff)
				Mem.w8(u.addr + 9, ax)
				Mem.w8(u.addr + 10, ay)


## A retreated unit re-entering (ops 0x55 / 0x6d → 0x4591a1): UnitInit with the flags of its deployment entry,
## so the colour stays; the AI code and target and the flags are kept.
func _unit_reenter(u: BUnit, x: int, y: int, d: int) -> void:
	var colour := u.colour
	_unit_init(u, u.pid, 0 if u.slot < 15 else (2 if u.slot < 35 else 1), x, y, d, false)
	u.colour = colour


## UnitInit (0x44274c): person, colour (0x449b7b), facing, position and state, full HP/MP, neutral buffs, no
## status. It leaves the AI code and target ([8]..[0xa]), the order byte and the flags as they are.
func _unit_init(u: BUnit, pid: int, flags: int, x: int, y: int, d: int, hidden: bool) -> void:
	u.state = BUnit.STATE_HIDDEN
	u.pid = pid
	var kind := 0
	if flags & 1:
		kind = 3 if flags & 2 else 2
	elif flags & 2:
		kind = 1
	u.colour = kind
	u.dir = d & 3
	if hidden:
		u.pos = Vector2i(x, y)
	else:
		u.state = BUnit.STATE_ON_MAP
		u.pos = nearest_free(Vector2i(x, y), u)
	u.hp = u.max_hp()
	u.mp = u.max_mp()
	for i in 6:
		u.set_buff(i, 3)
	u.status = 0
	var p := u.person
	if Game.is_member(pid):
		Mem.w8(p.base + 0x27, mini(Mem.r8(p.base + 0x27) + 1, 255))
	else:
		for off in [0x27, 0x28, 0x29]:
			Mem.w8(p.base + off, 0)


## Nearest free cell the unit can stand on (0x43f040).
func nearest_free(c: Vector2i, u: BUnit) -> Vector2i:
	for r in range(0, 12):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) + absi(dy) != r:
					continue
				var p := c + Vector2i(dx, dy)
				if not view.in_bounds(p):
					continue
				if unit_at(p, u) != null:
					continue
				if Rules.move_cost(u, view.terrain_at(p)) >= 999:
					continue
				return p
	return c


## The active unit on cell c (the lowest slot if several), other than `exclude`. Looked up in a cell → unit
## table that is rebuilt only after a unit moved, appeared, left or fell (BUnit.gen), since the AI asks a lot.
func unit_at(c: Vector2i, exclude: BUnit = null) -> BUnit:
	if _occ_gen != BUnit.gen:
		_occ.clear()
		for u in units:
			if u.active() and not _occ.has(u.pos):
				_occ[u.pos] = u
		_occ_gen = BUnit.gen
	var hit: BUnit = _occ.get(c)
	if hit == null or hit != exclude:
		return hit
	for u in units:      # `exclude` stands there; is anyone else on the same cell?
		if u != exclude and u.active() and u.pos == c:
			return u
	return null


func unit_by_pid(pid: int) -> BUnit:
	for u in units:
		if u.exists() and u.pid == pid:
			return u
	return null


## Person selectors (UnitAt 0x45b371): 0x400 any unit, 0x401 a player-side unit (index < 35),
## 0x402 an enemy unit, else a person id. Only units on the map with HP > 0 count.
func units_for(pid: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for u in units:
		if not u.active():
			continue
		if pid == 0x400 or (pid == 0x401 and u.slot < 35) or (pid == 0x402 and u.slot >= 35) or u.pid == pid:
			out.append(u)
	return out


## Side codes (0x44c8e6): 0 player, 1 friend, 2 enemy, 3 enemy-kind3, 4 player+friend, 5 all enemies, 6 all.
func side_match(u: BUnit, side: int) -> bool:
	var k := u.colour
	match side:
		0: return k == 0
		1: return k == 1
		2: return k == 2
		3: return k == 3
		4: return k <= 1
		5: return k >= 2
	return true


# ------------------------------------------------------------------ sprites
func refresh_units() -> void:
	for u in units:
		# a unit defeated in combat keeps its sprite until it has been removed, so the defeat animation can play
		var show: bool = u.exists() and u.state == BUnit.STATE_ON_MAP and (u.hp > 0 or u.extra.get("dying", false))
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
				var weak := u.hp * 5 < u.max_hp() * 2   # below 40%: kneeling frames
				u.node.set_pose(UnitSprite.Pose.WEAK if weak else UnitSprite.Pose.STAND, u.dir)
			u.node.greyed = u.acted and u.is_player_side() and phase == PH_PLAYER
	hud.queue_redraw()


func _after_poke(addr: int) -> void:
	if addr >= Mem.UNITS and addr < Mem.UNITS + 115 * Mem.UNIT_SIZE:
		BUnit.gen += 1
		refresh_units()


func on_field_written(_field: int, _id: int) -> void:
	BUnit.gen += 1
	refresh_units()


func in_battle() -> bool:
	return true


# ------------------------------------------------------------------ per-phase effects (§9)
func _phase_start_effects(a: int, b: int) -> void:
	for i in range(a, b):
		var u := units[i]
		if not u.active():
			continue
		_status_recovery(u)
		_buff_decay(u)
	Mem.fill(Rules.ZHANBEI_USED + a, b - a, 0)     # 战备 may be cast again (0x44ed93 / 0x44e851)
	for i in range(a, b):
		var u := units[i]
		if u.active() and (u.status & BUnit.ST_POISON):
			var dmg := u.max_hp() / (10 if (i >= 35 and u.pid < 210) else 5)
			u.hp = maxi(u.hp - maxi(dmg, 1), 1)
	for i in range(a, b):
		var u := units[i]
		if u.active():
			_regen(u)
	refresh_units()


func _status_recovery(u: BUnit) -> void:
	if u.status == 0:
		return
	var r := 100 if u.has_effect(20) else u.person.get_raw(4)
	var s := u.status
	for bit in [BUnit.ST_PARALYSIS, BUnit.ST_SEAL, BUnit.ST_POISON]:
		if s & bit and Rules.chance(r):
			s &= ~bit
	for bit in [BUnit.ST_FEAR, BUnit.ST_LOST]:
		if s & bit and (r == 100 or Rules.chance(r - r / 10)):
			s &= ~bit
	if s & BUnit.ST_CONFUSION and (r == 100 or Rules.chance(maxi(Rules.sat_sub(r, 15), 10))):
		s &= ~BUnit.ST_CONFUSION
	u.status = s


func _buff_decay(u: BUnit) -> void:
	var raw4 := u.person.get_raw(4)
	var q := 10 if raw4 > 50 else Rules.sat_sub(60, raw4)
	var r := 100 if u.has_effect(20) else raw4
	for i in 6:
		var b := u.buff(i)
		if b >= 5:
			b -= 1
		elif b <= 1:
			b += 1
		elif b == 4 and Rules.chance(q):
			b = 3
		elif b == 2 and Rules.chance(r):
			b = 3
		u.set_buff(i, b)


func _regen(u: BUnit) -> void:
	var heal := 0
	var t := view.terrain_at(u.pos)
	var pct := {18: 25, 19: 20, 20: 20, 21: 15, 22: 20}
	if pct.has(t):
		heal = u.max_hp() * int(pct[t]) / 100
	if u.has_effect(18):
		heal += u.max_hp() / maxi(u.effect_value(18), 1)
	heal = mini(heal, u.max_hp() - u.hp)
	if heal > 0:
		u.hp += heal
	var mp := u.effect_value(19) if u.has_effect(19) else 0
	mp = mini(mp, u.max_mp() - u.mp)
	if mp > 0:
		u.mp += mp


# ------------------------------------------------------------------ weather
func weather() -> int:
	return WEATHER_TABLE[climate][clampi(weather_level, 0, 5)]


func _update_weather_random() -> void:
	var c := weather_level + 1
	var r := Rules.rand(8)
	if c > r:
		c -= 1
	elif c < r:
		c += 1
	weather_level = 5 if c == 0 else (0 if c == 7 else c - 1)
	hud.queue_redraw()


# ------------------------------------------------------------------ battle-time tests
func op_test_turn(ins: Dictionary) -> bool:
	return Game.compare(turn, arg(ins, 0), arg(ins, 1))


func op_test_side(ins: Dictionary) -> bool:
	return phase == arg(ins, 0)


## op 0x42: default victory — boss defeated, or all enemy units gone.
func op_test_event5(_ins: Dictionary) -> bool:
	if not field_ready:
		return false
	if boss_pid >= 0:
		var b := unit_by_pid(boss_pid)
		if b == null or b.state >= 3 or (b.state == BUnit.STATE_ON_MAP and b.hp <= 0):
			return true
	# 0x44c8e6(5): enemy-coloured units on the map; hidden ones (伏兵 not yet out) do not count
	for u in units:
		if u.exists() and u.state == BUnit.STATE_ON_MAP and u.colour in [2, 3]:
			return false
	return true


## op 0x43: default defeat — protected leader fell, no player units left, or turn limit passed.
func op_test_event6(_ins: Dictionary) -> bool:
	if not field_ready:
		return false
	if leader_pid >= 0:
		var l := unit_by_pid(leader_pid)
		if l != null and l.state >= 3:
			return true
	var any := false
	for i in range(0, 15):
		var u := units[i]
		if u.exists() and u.state in [BUnit.STATE_HIDDEN, BUnit.STATE_ON_MAP] and u.hp > 0:
			any = true
	if not any:
		return true
	return turn_limit > 0 and turn > turn_limit


func op_test_unit_at(ins: Dictionary) -> bool:
	var c := Vector2i(arg(ins, 1), arg(ins, 2))
	for u in units_for(arg(ins, 0)):
		if u.pos == c:
			return true
	return false


func op_test_unit_in_area(ins: Dictionary) -> bool:
	var x0 := mini(arg(ins, 1), arg(ins, 3))
	var x1 := maxi(arg(ins, 1), arg(ins, 3))
	var y0 := mini(arg(ins, 2), arg(ins, 4))
	var y1 := maxi(arg(ins, 2), arg(ins, 4))
	for u in units_for(arg(ins, 0)):
		if u.pos.x >= x0 and u.pos.x <= x1 and u.pos.y >= y0 and u.pos.y <= y1:
			if OS.get_environment("WG_TRACE_BATTLE") != "":
				print("    in_area %s: slot %d %s at %s" % [ins["args"], u.slot, u.person.name, u.pos])
			return true
	return false


## op 0x2e: p2's unit in one of the 8 cells around p1's; loose == 0 also needs mutual attack ability.
func op_test_adjacent(ins: Dictionary) -> bool:
	var loose := arg(ins, 2)
	for ua in units_for(arg(ins, 0)):
		for ub in units_for(arg(ins, 1)):
			if ua == ub:
				continue
			var d := ub.pos - ua.pos
			if absi(d.x) <= 1 and absi(d.y) <= 1:
				if loose != 0:
					return true
				if actions.can_attack(ua, ub) and actions.can_attack(ub, ua):
					return true
	return false


## op 0x41: number of units of `side` (rect_flag 1 → inside the rectangle, else whole map) compared with n.
func op_test_units_in_area(ins: Dictionary) -> bool:
	var side := arg(ins, 0)
	if side == 0xffff:
		side = 6
	var rect := arg(ins, 3) == 1
	var x0 := mini(arg(ins, 4), arg(ins, 6))
	var x1 := maxi(arg(ins, 4), arg(ins, 6))
	var y0 := mini(arg(ins, 5), arg(ins, 7))
	var y1 := maxi(arg(ins, 5), arg(ins, 7))
	var cnt := 0
	for u in units:
		if not u.active() or not side_match(u, side):
			continue
		if rect and (u.pos.x < x0 or u.pos.x > x1 or u.pos.y < y0 or u.pos.y > y1):
			continue
		cnt += 1
	return Game.compare(cnt, arg(ins, 1), arg(ins, 2))


## op 0x36: attribute test of a person/unit (attr ids per op 0x38 table).
func op_test_attr(ins: Dictionary) -> bool:
	var v := BattleAttrs.get_attr(self, arg(ins, 0), arg(ins, 1))
	if v < 0:
		return false
	return Game.compare(v, arg(ins, 2), arg(ins, 3))


func op_set_attr(ins: Dictionary) -> void:
	await BattleAttrs.set_attr(self, arg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3))
	refresh_units()


# ------------------------------------------------------------------ texts / UI ops
func op_victory_cond_text(ins: Dictionary) -> void:
	victory_text = sarg(ins, 0)
	await ui.dialog.talk(null, "", victory_text, false)


func op_battle_goal_text(ins: Dictionary) -> void:
	goal_text = sarg(ins, 0)
	await hud.goal_banner(goal_text)


## op 0x49: the battle is over (both outcomes) — leave the turn loop.
func op_ui_49(_ins: Dictionary) -> void:
	battle_over = true


## op 0x0e: battle lost → game over.
func op_ui_0e(_ins: Dictionary) -> void:
	battle_over = true
	if OS.get_environment("WG_TRACE_BATTLE") != "":
		print("GAME OVER at turn %d" % turn)
	await Game.main.game_over()
	vm.abort = true
	vm.active = false


func op_ui_5a(_ins: Dictionary) -> void:
	pass


func op_ui_54(_ins: Dictionary) -> void:
	pass


func op_scroll_to(ins: Dictionary) -> void:
	await view.center_on(Vector2i(arg(ins, 0), arg(ins, 1)))


func _dialog_top(pid: int) -> bool:
	var u := unit_by_pid(pid)
	if u and u.active():
		var sp := view.cell_pos(u.pos) - view.camera.position
		return sp.y > 260
	return false


func on_speaker(pid: int) -> void:
	var u := unit_by_pid(pid)
	if u and u.active():
		await view.ensure_visible(u.pos)


# ------------------------------------------------------------------ save / restore
func save_state() -> Dictionary:
	return {"kind": "battle", "scene": vm.scene if vm else 0, "turn": turn, "phase": phase, "map": map_id,
		"turn_limit": turn_limit, "boss": boss_pid, "leader": leader_pid, "climate": climate,
		"weather_level": weather_level, "deploy": deploy, "field_ready": field_ready,
		"victory_text": victory_text, "goal_text": goal_text, "bgm": Audio.current_track,
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
	turn = int(d.get("turn", 1))
	_resumed = vm.scene == 1 and int(d.get("phase", PH_PLAYER)) == PH_PLAYER and bool(d.get("field_ready", false))
	turn_limit = int(d.get("turn_limit", 0))
	boss_pid = int(d.get("boss", -1))
	leader_pid = int(d.get("leader", -1))
	climate = int(d.get("climate", 0))
	weather_level = int(d.get("weather_level", 1))
	deploy = d.get("deploy", deploy)
	victory_text = str(d.get("victory_text", ""))
	goal_text = str(d.get("goal_text", ""))
	if OS.get_environment("WG_SAVETEST") != "":
		print("SAVETEST restoring battle turn %s scene %s" % [d.get("turn"), d.get("scene")])
	if bool(d.get("field_ready", false)) and int(d.get("map", -1)) >= 0:
		map_id = int(d["map"])
		view.load_map(map_id, false)
		# the terrain bytes came back with the memory; redraw the changed tiles
		terrain_changes = []
		for e: Dictionary in d.get("terrain_changes", []):
			var c := Vector2i(int(e["x"]), int(e["y"]))
			var patch := int(e["patch"])
			var node: Node = null
			if patch >= 4:
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
		if lead.active():
			view.center_on(lead.pos, false)
	if int(d.get("bgm", -1)) >= 0:
		Audio.play_bgm(int(d["bgm"]))
	ui.set_black(false)


# ------------------------------------------------------------------ unit ops (§10.6.1)
## op 0x4c: reveal a hidden/off-map unit (mode 0: by person; mode 1: player slot).
func op_unit_op_4c(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 0xffff:
		mode = 0
	var u: BUnit = null
	if mode == 0:
		var pid := arg(ins, 1)
		for x in units:
			if x.exists() and x.pid == pid and x.state != 0:
				u = x
				break
	else:
		var sl := arg(ins, 2)
		if sl < 15:
			u = units[sl]
	if u == null or not u.exists() or u.state != BUnit.STATE_HIDDEN:
		return
	var d := _entry_of(u)
	var c := Vector2i(int(d.get("x", u.pos.x)), int(d.get("y", u.pos.y))) if not d.is_empty() else u.pos
	u.pos = nearest_free(c, u)
	u.state = BUnit.STATE_ON_MAP
	u.hp = maxi(u.hp, 1)
	await view.center_on(u.pos)
	Audio.play_se("se42")
	refresh_units()
	if u.node and not Game.autoplay:
		u.node.fade = 0.0
		var tw := u.node.create_tween()
		tw.tween_property(u.node, "fade", 1.0, 0.4)
		await tw.finished


func _entry_of(u: BUnit) -> Dictionary:
	for d in deploy:
		if int(d.get("person", 0xffff)) == u.pid:
			return d
	return {}


func _targets_mode(mode: int, pid: int, slot: int, x1: int, y1: int, x2: int, y2: int, side: int) -> Array[BUnit]:
	var out: Array[BUnit] = []
	match mode:
		0:
			var u := unit_by_pid(pid)
			if u and u.state == BUnit.STATE_ON_MAP:
				out.append(u)
		1:
			if slot < 15 and units[slot].state == BUnit.STATE_ON_MAP:
				out.append(units[slot])
		_:
			if side == 0xffff:
				side = 6
			for u in units:
				if u.active() and side_match(u, side) and u.pos.x >= mini(x1, x2) and u.pos.x <= maxi(x1, x2) and u.pos.y >= mini(y1, y2) and u.pos.y <= maxi(y1, y2):
					out.append(u)
	return out


## op 0x4d: change buffs/status/HP/MP of units.
func op_unit_op_4d(ins: Dictionary) -> void:
	var tg := _targets_mode(arg(ins, 0), arg(ins, 1), arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6), arg(ins, 7))
	var bi := arg(ins, 8)
	var bl := arg(ins, 9)
	var stv := arg(ins, 10)
	var hpd := arg(ins, 11)
	var mpd := arg(ins, 12)
	for u in tg:
		if bi != 0xffff and bi < 6:
			u.set_buff(bi, {0: 0, 1: 3, 2: 6}.get(bl, 3))
		if stv != 0xffff:
			if stv & 0x80:
				u.status = u.status & ~stv & 0x7f
			else:
				u.status = u.status | stv
		if hpd != 0 and hpd != 0xffff:
			var nh := u.hp - mini(u.hp, hpd & 0xffff)
			if nh <= 1:
				nh = 0
			u.hp = nh
			if nh <= 0:
				u.extra["dying"] = true
			if not Game.autoplay:
				hud.popup_number(str(hpd & 0xffff), u.pos)
			if nh <= 0:
				await actions.unit_defeated(u)
		if mpd != 0 and mpd != 0xffff:
			u.mp = maxi(u.mp - mpd, 1)
	refresh_units()


## op 0x4e: change AI (mode 0: one person; else every unit of `side` in the rectangle).
func op_unit_op_4e(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var ai_mode := arg(ins, 7)
	var tg: Array[BUnit] = []
	if mode == 0 or mode == 0xffff:
		var u := unit_by_pid(arg(ins, 1))
		if u:
			tg.append(u)
	else:
		tg = _targets_mode(2, 0, 0, arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6))
	for u in tg:
		_set_ai(u, ai_mode, arg(ins, 8), arg(ins, 9), arg(ins, 10))


## op 0x4f: unit p1 turns to `dir` or toward p2.
func op_unit_op_4f(ins: Dictionary) -> void:
	var u := unit_by_pid(arg(ins, 0))
	if u == null or u.state != BUnit.STATE_ON_MAP:
		return
	var p2 := arg(ins, 1)
	var scroll := arg(ins, 4)
	var wt := arg(ins, 5)
	if scroll != 0:
		await view.ensure_visible(u.pos)
		await wait(0.4)
	if p2 != 0xffff:
		var t := unit_by_pid(p2)
		if t and t.state == BUnit.STATE_ON_MAP:
			actions.face(u, t.pos)
	else:
		u.dir = arg(ins, 2) & 3
		if u.node:
			u.node.dir = u.dir
			u.node.queue_redraw()
	Audio.play_se("se06")
	if wt != 0:
		await wait(0.4)


## op 0x50: play a battle-sprite pose/animation on the person's unit (action 0..12).
func op_unit_status(ins: Dictionary) -> void:
	var u := unit_by_pid(arg(ins, 0))
	if u == null or u.state != BUnit.STATE_ON_MAP or u.node == null:
		return
	var action := arg(ins, 1)
	var pre := arg(ins, 2)
	var post := arg(ins, 3)
	await view.ensure_visible(u.pos)
	if pre != 0 and action != 0 and action != 11:
		await wait(0.4)
	var n := u.node
	match action:
		0: n.set_pose(UnitSprite.Pose.STAND, u.dir)
		1, 10: n.set_pose(UnitSprite.Pose.DEFEND, u.dir)
		2: n.set_pose(UnitSprite.Pose.HURT, u.dir)
		3: n.set_pose(UnitSprite.Pose.CHEER, u.dir)
		4, 12: n.set_pose(UnitSprite.Pose.WEAK, u.dir)
		5:
			if not Game.autoplay:
				await n.play_attack(u.dir)
		6:
			n.set_pose(UnitSprite.Pose.ATTACK, u.dir)
			n.frame = 1
			n.queue_redraw()
		7:
			n.set_pose(UnitSprite.Pose.ATTACK, u.dir)
			n.frame = 3
			n.queue_redraw()
		8, 9, 11: n.set_pose(UnitSprite.Pose.WALK, u.dir)
	if post != 0 and action != 0 and action != 11:
		await wait(0.4)


## op 0x32 in a battle: move a unit (story-op name) — select 1 = player slot, else person.
func op_actor_move(ins: Dictionary) -> void:
	var u: BUnit = null
	var sel := arg(ins, 0)
	if sel == 1 and arg(ins, 2) < 15:
		u = units[arg(ins, 2)]
	else:
		u = unit_by_pid(arg(ins, 1))
	if u == null or u.state != BUnit.STATE_ON_MAP:
		return
	await _script_move(u, Vector2i(arg(ins, 3), arg(ins, 4)), arg(ins, 5))


func _script_move(u: BUnit, goal: Vector2i, d: int) -> void:
	await view.ensure_visible(u.pos)
	# an occupied goal: stop at the nearest free cell instead of on top of the other unit
	if goal != u.pos and unit_at(goal, u) != null:
		goal = nearest_free(goal, u)
	# scripted moves ignore movement points; path by BFS over passable cells
	var parents := {}
	var cost := func(c: Vector2i) -> int: return mini(Rules.move_cost(u, view.terrain_at(c)), 1) if Rules.move_cost(u, view.terrain_at(c)) < 999 else 999
	var blocked := func(c: Vector2i) -> bool: return unit_at(c, u) != null
	Grid.reachable(u.pos, 200, view.map_w, view.map_h, cost, blocked, Callable(), parents)
	var path := Grid.path_to(parents, u.pos, goal)
	if path.is_empty() and goal != u.pos:
		u.pos = nearest_free(goal, u)
	else:
		await actions.move_unit(u, path)
	u.moved = false
	if d != 0xffff and d >= 0:
		u.dir = d & 3
	refresh_units()


## RemoveUnit (0x441744): unit leaves the map (state 3). Non-silent: player units (kind 0, pid < 49)
## speak their retreat line (text #650+pid) if their retreat-line flag (U+0x20) is set.
func remove_unit(u: BUnit, silent: bool) -> void:
	if u.state != BUnit.STATE_ON_MAP:
		return
	current_unit = u
	if not silent and Mem.r8(u.addr + 0x20) != 0 and u.colour == 0 and u.pid < 49:
		var line := Game.text(650 + u.pid)
		if line != "":
			await view.ensure_visible(u.pos)
			await ui.dialog.talk(Game.person_face(u.pid), u.person.name, line, _dialog_top(u.pid))
	if u.node and not Game.autoplay:
		Audio.play_se("se16")
		var tw := u.node.create_tween()
		tw.tween_property(u.node, "fade", 0.0, 0.35)
		await tw.finished
	u.state = 3
	u.status = 0
	u.extra.erase("dying")
	if Game.is_member(u.pid):
		var pb := u.person.base
		Mem.w8(pb + 0x29, mini(Mem.r8(pb + 0x29) + 1, 255))
	for o in units:
		if o.exists() and Mem.r8(o.addr + 8) == u.slot and o.mode in [0, 4]:
			o.mode = 1
			Mem.w8(o.addr + 8, 0xff)
	refresh_units()


## op 0x31 (battle): mode 0 → remove person's unit silently; else every unit of `side` in the rectangle.
func op_actor_select(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var tg := _targets_mode(0 if mode == 0 else 2, arg(ins, 1), 0, arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6))
	for u in tg:
		await remove_unit(u, true)


## op 0x53: unit retreats (with its retreat line).
func op_unit_op_53(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	var tg := _targets_mode(0 if mode == 0 else 2, arg(ins, 1), 0, arg(ins, 2), arg(ins, 3), arg(ins, 4), arg(ins, 5), arg(ins, 6))
	for u in tg:
		await remove_unit(u, false)


## op 0x1b: retreat-line flag of the person's unit.
func op_op_1b(ins: Dictionary) -> void:
	var u := unit_by_pid(arg(ins, 0))
	if u:
		Mem.w8(u.addr + 0x20, 1 if arg(ins, 1) != 0 else 0)


## op 0x55: a retreated unit (state 3) re-enters at (x, y) with full HP/MP.
func op_unit_move(ins: Dictionary) -> void:
	var mode := arg(ins, 0)
	if mode == 0xffff:
		mode = 0
	var u: BUnit = null
	if mode == 0:
		var pid := arg(ins, 1)
		for x in units:
			if x.exists() and x.pid == pid:
				u = x
				break
	elif arg(ins, 2) < 15:
		u = units[arg(ins, 2)]
	if u == null or u.state != 3:
		return
	var d := arg(ins, 5)
	_unit_reenter(u, arg(ins, 3), arg(ins, 4), 2 if d == 0xffff else d)
	await view.center_on(u.pos)
	Audio.play_se("se42")
	refresh_units()


## op 0x52 (battle): selectors 0x400..0x402 mean the current unit.
func op_op_52(ins: Dictionary) -> void:
	var pid := arg(ins, 0)
	if pid >= 0x400 and pid <= 0x402 and current_unit:
		ins = ins.duplicate(true)
		ins["args"][0] = current_unit.pid
	super.op_op_52(ins)
	refresh_units()


## op 0x5b: show a destination area (到达指定地点).
func op_op_5b(ins: Dictionary) -> void:
	var cells: Array[Vector2i] = []
	for y in range(mini(arg(ins, 1), arg(ins, 3)), maxi(arg(ins, 1), arg(ins, 3)) + 1):
		for x in range(mini(arg(ins, 0), arg(ins, 2)), maxi(arg(ins, 0), arg(ins, 2)) + 1):
			cells.append(Vector2i(x, y))
	view.goal_cells = cells
	if not cells.is_empty():
		await view.center_on(cells[cells.size() / 2])


## op 0x58: terrain change at (x, y) with optional 3x3 map patch (Nima.wa 2*patch-8).
func op_op_58(ins: Dictionary) -> void:
	var patch := arg(ins, 0)
	var alt := arg(ins, 1)
	var terr := arg(ins, 2)
	var c := Vector2i(arg(ins, 3), arg(ins, 4))
	var scroll := arg(ins, 5)
	var silent := arg(ins, 6)
	if not view.in_bounds(c):
		return
	if scroll != 0 and scroll != 0xffff:
		await view.center_on(c)
	if alt == 0:
		var old := view.terrain_at(c)
		view.set_terrain(c, terr)
		var node: Node = null
		if patch >= 4 and silent != 1:
			node = view.add_patch(2 * patch - 8, c)
		elif patch < 4:
			view.add_mark(patch, c)
		if patch in [0, 2]:
			Audio.play_se("se19")
		terrain_changes.append({"x": c.x, "y": c.y, "new": terr, "old": old, "patch": patch, "silent": silent == 1, "node": node})
	refresh_units()


## op 0x6b: effect animation at a cell.
func op_op_6b(ins: Dictionary) -> void:
	var c := Vector2i(arg(ins, 0), arg(ins, 1))
	var eff := arg(ins, 2)
	if arg(ins, 3) != 0 and arg(ins, 3) != 0xffff:
		await view.center_on(c)
	if Game.autoplay:
		return
	var e: EffectPlayer = null
	if eff < 100:
		e = EffectPlayer.create("xben", eff)
		if e:
			e.position = view.cell_center(c)
			view.fx_layer.add_child(e)
	elif eff < 109:
		e = EffectPlayer.create("mcall", eff - 100)
		if e:
			e.position = view.cell_center(c)
			view.fx_layer.add_child(e)
	if e:
		await e.done


## op 0x30 in a battle: place a person's unit at (x, y) (0x4570ee with coordinates).
func op_actor_appear(ins: Dictionary) -> void:
	var u := unit_by_pid(arg(ins, 0) & 0xfff)
	if u == null:
		return
	u.pos = nearest_free(Vector2i(arg(ins, 1), arg(ins, 2)), u)
	u.state = BUnit.STATE_ON_MAP
	refresh_units()


func wait(sec: float) -> void:
	if fast or sec <= 0 or Game.autoplay:
		return
	await get_tree().create_timer(sec).timeout


# ------------------------------------------------------------------ misc battle ops (Ghidra)
## op 0x15: floating message at the unit (0x459777).
func op_unit_say(ins: Dictionary) -> void:
	var u := unit_by_pid(arg(ins, 1) if arg(ins, 1) != 0xffff else arg(ins, 0))
	if u == null or not u.active():
		return
	await view.ensure_visible(u.pos)
	hud.popup_number(sarg(ins, 2), u.pos, Color(1, 1, 0.6))
	await wait(0.9)


## op 0x51 (0x41626a): battle won — every unit on the map is fully healed, status/buffs cleared.
func op_op_51(_ins: Dictionary) -> void:
	for u in units:
		if u.exists() and u.state == BUnit.STATE_ON_MAP:
			for i in 6:
				u.set_buff(i, 3)
			u.status = 0
			u.hp = u.max_hp()
			u.mp = u.max_mp()
	refresh_units()


## op 0x59 (0x41688b): rewards. gold += avg_party_level*100 + 700 + base; up to 3 items (id, level).
func op_op_59(ins: Dictionary) -> void:
	var gold := Game.party_avg_level() * 100 + 700 + arg(ins, 0)
	Game.gold = Game.gold + gold
	await ui.popup("得到了 %d 两黄金。" % gold, 0.0 if not Game.demo else 1.0)
	var avg := Game.party_avg_level()
	for k in 3:
		var iid := arg(ins, 1 + 2 * k)
		if iid == 0xffff or iid >= 0xff:
			continue
		var lvl := arg(ins, 2 + 2 * k)
		var it := Game.item(iid)
		if lvl == 0xffff or lvl == 0:
			if String(it.get("category", "")) in ["weapon", "armor"]:
				if bool(it.get("treasure", false)):
					lvl = mini(avg / 7 + 1, 10)
				else:
					lvl = Rules.rand(3) + 1 if avg < 48 else 3
			else:
				lvl = 0
		Game.add_item(iid, maxi(lvl, 1))
		await ui.popup("得到了%s%s。" % [it.get("name", "?"), ("（Lv%d）" % lvl) if lvl > 0 and String(it.get("category", "")) in ["weapon", "armor"] else ""], 0.0 if not Game.demo else 1.0)
		if bool(it.get("treasure", false)):
			SpecialFuncs.write_niuniu(iid + 3, 1)


## op 0x5c (0x416e17): blink the person's unit three times (camera centred).
func op_op_5c(ins: Dictionary) -> bool:
	var u := unit_by_pid(arg(ins, 0))
	if u == null or not u.active():
		return false
	await view.center_on(u.pos)
	if u.node and not Game.autoplay:
		for k in 3:
			u.node.flash = 0.8
			await wait(0.5)
			u.node.flash = 0.0
			await wait(0.5)
	return true


## op 0x5d (0x417068): turn limit — mode 0 set (only if > current turn + 1), 1 add.
func op_op_5d(ins: Dictionary) -> bool:
	var mode := arg(ins, 0)
	var v := arg(ins, 1) & 0xff
	if mode == 0:
		if v <= turn:
			return false
		turn_limit = v
	elif mode == 1:
		turn_limit += v
	else:
		return false
	hud.queue_redraw()
	return true


## op 0x21 map_mark: undo a recorded terrain change at (x, y): mode 0 any, mode 1 matching patch p1.
func op_map_mark(ins: Dictionary) -> void:
	var c := Vector2i(arg(ins, 0), arg(ins, 1))
	var mode := arg(ins, 2)
	var patch := arg(ins, 3)
	for i in terrain_changes.size():
		var e: Dictionary = terrain_changes[i]
		if int(e["x"]) == c.x and int(e["y"]) == c.y and (mode == 0 or int(e["patch"]) == patch):
			view.set_terrain(c, int(e["old"]))
			var n: Variant = e.get("node")
			if n and is_instance_valid(n):
				(n as Node).queue_free()
			view.marks.erase(c)
			view.overlay.queue_redraw()
			terrain_changes.remove_at(i)
			if mode == 0:
				Audio.play_se("se18")
			break


# ------------------------------------------------------------------ duel (单挑) ops 0x5f-0x68
var duel: DuelLayer

func _duel() -> DuelLayer:
	if duel == null:
		duel = DuelLayer.new()
		duel.stage = self
		ui.add_child(duel)
		# under the dialog box / menus, above the map HUD
		ui.move_child(duel, ui.dialog.get_index())
	return duel


## 0x68 (0x44999f): duel between two persons on the map, 3rd arg = GHAI backdrop; plays the intro.
func op_duel_setup(ins: Dictionary) -> void:
	await _duel().setup(arg(ins, 0), arg(ins, 1), arg(ins, 2))


## 0x60 (0x449480): fighter appears (fade from white), optional action, then speaks.
func op_duel_say(ins: Dictionary) -> void:
	await _duel().appear_say(arg(ins, 0), sarg(ins, 1), arg(ins, 2))


## 0x61 (0x448ff5, parser name misleading): start of the fight ("胜 负").
func op_duel_end(_ins: Dictionary) -> void:
	await _duel().open()


## 0x5f (0x4498e0, parser name misleading): close the duel; restores BGM, gives the winner's EXP.
func op_duel_start(_ins: Dictionary) -> void:
	if duel:
		await duel.close()


## 0x63 (0x4431af): speech bubble (empty text erases it).
func op_duel_say2(ins: Dictionary) -> void:
	await _duel().say2(arg(ins, 0), sarg(ins, 1), arg(ins, 2))


## 0x64 (0x448524): single-fighter action 0..15.
func op_duel_action(ins: Dictionary) -> void:
	await _duel().action(arg(ins, 0), arg(ins, 1))


## 0x65 (0x448394): one blow with a scripted outcome.
func op_duel_action2(ins: Dictionary) -> void:
	await _duel().exchange(arg(ins, 0), arg(ins, 1), arg(ins, 2))


## 0x66 (0x44847b): special attack.
func op_duel_action3(ins: Dictionary) -> void:
	await _duel().special(arg(ins, 0), arg(ins, 1), arg(ins, 2))


## 0x62 (0x4490da): result — arg = winner side; loser greyed, EXP computed.
func op_duel_62(ins: Dictionary) -> void:
	await _duel().result(arg(ins, 0))


## op 0x6d (0x410cfc): move (or, last arg 1, re-enter) a unit to the position of another person's
## unit offset by (dx, dy) (values > 40 mean −(v−40)).
func op_op_6d(ins: Dictionary) -> bool:
	var sel := arg(ins, 0)
	if sel == 0xffff:
		sel = 0
	var reenter := arg(ins, 7) == 1
	var pid := 0xffff
	if sel == 1 and arg(ins, 2) < 15:
		var su := units[arg(ins, 2)]
		if su.exists() and su.state == (3 if reenter else 2):
			pid = su.pid
	elif sel == 0:
		pid = arg(ins, 1)
	if pid >= 0x400:
		return false
	var ref := unit_by_pid(arg(ins, 3))
	if ref == null:
		return false
	var dx := arg(ins, 4)
	var dy := arg(ins, 5)
	var x := ref.pos.x + dx if dx < 0x29 else maxi(ref.pos.x - (dx - 0x28), 0)
	var y := ref.pos.y + dy if dy < 0x29 else maxi(ref.pos.y - (dy - 0x28), 0)
	var u := unit_by_pid(pid)
	if u == null:
		return false
	if reenter:
		if u.state == 3:
			_unit_reenter(u, x, y, arg(ins, 6) if arg(ins, 6) != 0xffff else 2)
			refresh_units()
	elif u.state == BUnit.STATE_ON_MAP:
		await _script_move(u, Vector2i(x, y), arg(ins, 6))
	return true
