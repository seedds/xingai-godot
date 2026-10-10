class_name BattleInput
extends RefCounted
## Player-phase interaction (CCZ-style): select a unit → show move range → move → command menu.

var st: BattleStage
var end_turn := false
var idle := false              # the player phase waits at its top level (no unit selected; touch shell's 菜单)
var _bot: InputBot


func _init(s: BattleStage) -> void:
	st = s


func _player_units() -> Array[BUnit]:
	var out: Array[BUnit] = []
	for i in range(0, 35):
		var u := st.units[i]
		if u.active() and u.mode == 7:
			out.append(u)
	return out


## No player unit left that can act: confused (乱) units do not count (0x44e0d9).
func _all_done() -> bool:
	for u in _player_units():
		if not u.acted and not (u.status & BUnit.ST_CONFUSION):
			return false
	return true


func _click() -> Array:
	var r: Array = await st.view.cell_clicked
	return r


func player_phase() -> void:
	end_turn = false
	if not st.view.cell_hovered.is_connected(st.hud.set_hover):
		st.view.cell_hovered.connect(st.hud.set_hover)
	var pu := _player_units()
	if not pu.is_empty():
		await st.view.center_on(pu[0].pos)
		st.view.cursor_cell = pu[0].pos
	var botdir := OS.get_environment("WG_INPUTBOT")
	if botdir != "":
		if _bot == null:
			_bot = InputBot.new(st, botdir)
			st.add_child(_bot)
		if st.turn > int(OS.get_environment("WG_BOTTURNS") if OS.get_environment("WG_BOTTURNS") != "" else "2"):
			st.get_tree().quit()
			return
		_bot.run_phase()
	elif Game.autoplay or Game.demo:
		var fx := OS.get_environment("WG_FXTEST")
		if fx != "":
			# debug: cast these strategies with autoplay (dialogue skipped) and print each target's outcome
			if _bot == null:
				_bot = InputBot.new(st, "")
				st.add_child(_bot)
			await _bot.fx_test(fx.split(","))
			return
		await _auto_player_phase()
		return
	if pu.is_empty():
		return      # no unit to command (0x44e0d9)
	while not end_turn and not st._battle_finished():
		idle = true
		var r := await _click()
		idle = false
		if st._battle_finished():
			break
		var cell: Vector2i = r[0]
		var btn: int = r[1]
		if btn == MOUSE_BUTTON_RIGHT:
			await system_menu()
			continue
		var u := st.unit_at(cell)
		if u == null:
			continue
		if u.mode == 7 and u.slot < 35 and not u.acted:
			var did := await select_unit(u)
			await st.checkpoint()
			if did and _all_done():
				break       # checked after each action only, so units all under 乱 do not end the phase
		else:
			await show_unit_ranges(u)
	st.view.clear_highlights()


## Autoplay: let the AI drive player units (for headless smoke tests).
func _auto_player_phase() -> void:
	for u in _player_units():
		if st._battle_finished():
			return
		if u.active() and not u.acted:
			await st.ai.act(u)
			await st.checkpoint()


func show_unit_ranges(u: BUnit) -> void:
	var reach := st.actions.reachable(u)
	st.view.set_move_cells(reach)
	var atk: Array[Vector2i] = []
	for c in reach:
		for a in st.actions.attack_cells(u, c):
			if not reach.has(a) and not atk.has(a):
				atk.append(a)
	st.view.set_attack_cells(atk)
	await _click()
	st.view.clear_highlights()


## Returns true when a unit finished its action.
func select_unit(u: BUnit) -> bool:
	Audio.play_se("se00")
	if u.status & (BUnit.ST_CONFUSION | BUnit.ST_LOST):
		# 0x43d544 / 0x43d5f8: the range is shown and a click on the map only brings up the message
		var reach := st.actions.reachable(u)
		st.view.set_move_cells(reach)
		var r := await _click()
		st.view.clear_highlights()
		if r[1] != MOUSE_BUTTON_RIGHT and st.view.in_bounds(r[0]):
			await st.ui.popup("正处于混乱状态。" if u.status & BUnit.ST_CONFUSION else "正处于迷失状态。")
		return false
	while true:
		var parents := {}
		var reach := st.actions.reachable(u, parents)
		st.view.set_move_cells(reach)
		var atk: Array[Vector2i] = []
		for c in reach:
			for a in st.actions.attack_cells(u, c):
				if not reach.has(a) and not atk.has(a):
					atk.append(a)
		st.view.set_attack_cells(atk)
		var r := await _click()
		st.view.clear_highlights()
		if st._battle_finished():
			return false
		var cell: Vector2i = r[0]
		if r[1] == MOUSE_BUTTON_RIGHT:
			return false
		if not reach.has(cell):
			var other := st.unit_at(cell)
			if other and other != u and other.mode == 7 and other.slot < 35 and not other.acted:
				if other.status & (BUnit.ST_CONFUSION | BUnit.ST_LOST):
					return await select_unit(other)
				u = other
				continue
			return false
		var orig := u.pos
		var orig_dir := u.dir
		var path := Grid.path_to(parents, u.pos, cell)
		await st.actions.move_unit(u, path)
		var done := await command_menu(u)
		if done:
			u.moved = true
			u.acted = true
			if u.node:
				u.node.greyed = true
			st.refresh_units()
			return true
		# cancelled: undo the move
		u.pos = orig
		u.dir = orig_dir
		u.moved = false
		st.refresh_units()
	return false


## Returns true when the unit's action is finished.
func command_menu(u: BUnit) -> bool:
	while true:
		var targets := st.actions.attackable_targets(u, u.pos)
		var strats := st.actions.known_strategies(u)
		var items := st.actions.usable_items()
		var labels := ["攻击", "策略", "道具", "待命"]
		var en := [not targets.is_empty(), not strats.is_empty() and not (u.status & BUnit.ST_SEAL), not items.is_empty(), true]
		var sp := st.view.cell_pos(u.pos) - st.view.camera.position + Vector2(56, -10)
		var i := await st.ui.menu.choose(labels, sp, true, "", en, 60)
		match i:
			-1:
				return false
			0:
				if await _do_attack(u, targets):
					return true
			1:
				if await _do_strategy(u, strats):
					return true
			2:
				if await _do_item(u, items):
					return true
			3:
				return true
	return false


## Picking a target: a right click cancels; with touch controls so does a tap outside the highlighted cells
## (a tap inside them that hits no target is ignored, as with a mouse).
func _cancels(r: Array, cells: Array) -> bool:
	return r[1] == MOUSE_BUTTON_RIGHT or (Game.touch and not cells.has(r[0]))


func _do_attack(u: BUnit, targets: Array[BUnit]) -> bool:
	var cells := st.actions.attack_cells(u, u.pos)
	st.view.set_attack_cells(cells)
	while true:
		var r := await _click()
		if _cancels(r, cells):
			st.view.clear_highlights()
			return false
		var t := st.unit_at(r[0])
		if t and targets.has(t):
			st.view.clear_highlights()
			await st.actions.attack(u, t)
			return true
	return false


func _do_strategy(u: BUnit, strats: Array[int]) -> bool:
	while true:
		var labels := []
		var en := []
		for s in strats:
			var sd := Game.strategy(s)
			labels.append("%s　%d" % [sd.get("name", "?"), st.actions.strategy_mp(s)])
			en.append(st.actions.can_cast(u, s))
		var i := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "策略　（策略值 %d）" % u.mp, en, 160)
		if i < 0:
			return false
		var s: int = strats[i]
		var why := st.actions.cast_refusal(u, s)
		if why != "":
			await st.ui.popup(why)       # 0x41fec9 with its message
			continue
		var cells := st.actions.strategy_cast_cells(u, s)
		st.view.set_attack_cells(cells)
		var chosen := false
		while true:
			var r := await _click()
			if _cancels(r, cells):
				break
			var c: Vector2i = r[0]
			if not cells.has(c):
				continue
			var tg := st.actions.strategy_targets(u, s, c)
			if tg.is_empty() and not (s in [58, 59, 60]):
				var main := st.unit_at(c)
				if main and not st.actions.usable_on(u, s, main):
					# 0x420422's messages for a player-commanded caster
					var cat: int = Rules.STRAT_CATEGORY[s] if s < Rules.STRAT_CATEGORY.size() else 17
					if cat <= 3:
						await st.ui.popup("不能在这里使用。")
					elif cat == 15 and main == u:
						await st.ui.popup("不能对自己使用。")
				continue
			st.view.set_area_cells(st.actions.strategy_area(u, s, c))
			var hr := 100
			if not tg.is_empty():
				hr = Rules.strat_hit(u, tg[0], s, st.view.terrain_at(tg[0].pos), st.weather())
			var ok := await st.ui.menu.choose(["执行（成功率 %d%%）" % hr, "取消"], Vector2(-1, -1), true)
			st.view.set_area_cells([])
			if ok == 0:
				st.view.clear_highlights()
				await st.actions.cast(u, s, c)
				chosen = true
				break
		st.view.clear_highlights()
		if chosen:
			return true
	return false


func _do_item(u: BUnit, items: Array) -> bool:
	var labels := []
	for e in items:
		var it := Game.item(int(e["id"]))
		var cnt := ("×%d" % int(e["count"])) if e.has("count") else ""
		labels.append("%s %s" % [it.get("name", "?"), cnt])
	var i := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "道具", [], 160)
	if i < 0:
		return false
	var entry: Dictionary = items[i]
	var cells: Array[Vector2i] = [u.pos]
	for d in Grid.DIRS:
		cells.append(u.pos + d)
	st.view.set_attack_cells(cells)
	while true:
		var r := await _click()
		if _cancels(r, cells):
			st.view.clear_highlights()
			return false
		var t := st.unit_at(r[0])
		if t and cells.has(t.pos) and not t.is_enemy_of(u) and st.actions.item_usable_on(int(entry["id"]), t):
			st.view.clear_highlights()
			await st.actions.use_item(u, entry, t)
			return true
	return false


## 部队一览: every unit on the field by side; picking one centres the camera and shows its status.
func unit_list() -> void:
	var lst: Array[BUnit] = []
	var labels := []
	for side_name in [["我军", 0, 15], ["友军", 15, 35], ["敌军", 35, 115]]:
		for i in range(side_name[1], side_name[2]):
			var u := st.units[i]
			if u.active():
				lst.append(u)
				labels.append("%s %s　%s Lv%d　兵 %d/%d%s" % [side_name[0], u.person.name, u.person.class_name_str(), u.level(), u.hp, u.max_hp(), "　（已行动）" if u.acted and i < 35 else ""])
	if lst.is_empty():
		return
	while true:
		var k := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "部队一览", [], 320)
		if k < 0:
			return
		var u := lst[k]
		await st.view.center_on(u.pos)
		st.view.cursor_cell = u.pos
		st.hud.set_hover(u.pos)
		await StatusPanel.show_person(st.ui, u.person)


func system_menu() -> void:
	var i := await st.ui.menu.choose(["回合结束", "部队一览", "胜利条件", "存储进度", "读取进度", "回到标题"], Vector2(-1, -1), true)
	var main: Node = Game.main
	match i:
		0:
			end_turn = true
		1:
			await unit_list()
		2:
			await st.ui.dialog.talk(null, "", st.victory_text if st.victory_text != "" else st.goal_text, false)
		3:
			await main.save_menu()
		4:
			await main.load_menu()
		5:
			main.to_title()
