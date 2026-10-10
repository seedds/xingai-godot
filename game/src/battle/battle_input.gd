class_name BattleInput
extends RefCounted
## The player phase of the 6.6 engine (docs/ai.md §5): the input loop 0x44e0d9, UnitCommand 0x43dde0 with the move
## selection 0x43d4fc, the command menu (dialog 0x117: 攻击 策略 道具 交换 围攻 必杀 待命 取消, enable rules computed
## once per menu), the target picker 0x45533d, the strategy / 武将技 / item lists, 交换 0x4151fe, 围攻 0x41d693,
## AfterPlayerAction (再次移动 0x415d93, 大杀四方 / 二次行动, 围攻 helpers), NextUnit 0x44e706 and the end prompt.
## The original's toolbar (结束回合, 检索未执行部队, 武将一览, 胜利条件, 保存 / 读取, 结束游戏) is a system menu
## opened by a right click on an empty cell; a right click on a unit opens its window.

const MSG_ENEMY := "这是敌军部队。"
const MSG_FRIEND := "这是友军部队。"
const MSG_CONFUSED := "正处于混乱状态。"
const MSG_SEALED := "正处于禁咒状态。"
const MSG_OCCUPIED := "因为有其他部队，所以不能移动。"
const MSG_END := "结束所有部队的命令吗？"
const MSG_NONE_LEFT := "没有可以行动的部队。"
const MSG_OUT := "不在范围之内。"
const MSG_NO_ENEMY := "范围内没有敌军部队。"
const MSG_NO_ALLY := "范围内没有我军部队。"
const MSG_OWN := "不能攻击我军部队。"
const MSG_NO_SIEGE := "不能围攻该部队"
const MENU_LABELS := ["攻击", "策略", "道具", "交换", "围攻", "必杀", "待命", "取消"]
const MENU_SEL := [1, 2, 3, 7, 6, 5, 4, 0xff]        # the dialog's selection ids (button id − 0x506)

var st: BattleStage
var idle := false                # waiting at the top level (no unit selected): the touch shell's 菜单 works
var end_turn := false
var picked_cell := Vector2i(-1, -1)   # the cell of the last picker result 0xfe (an empty cell accepted)
var _bot: InputBot
var _menu_req := false


func _init(s: BattleStage) -> void:
	st = s


# ------------------------------------------------------------------ helpers
func _click() -> Array:
	var r: Array = await st.view.cell_clicked
	return r


## Message box type 2 with SE 2 (0x42a423).
func msg(text: String) -> void:
	Audio.play_se(SoundMap.se_name(2))
	await st.ui.popup(text)


func yes_no(text: String) -> bool:
	var i := await st.ui.menu.choose(["是", "否"], Vector2(-1, -1), true, text)
	return i == 0


## Commandable units of the player side (0x43d4fc: side 1, code 7, no scripted-move flag).
func _player_units() -> Array[BUnit]:
	var out: Array[BUnit] = []
	for i in 60:
		var u := st.units[i]
		if u.state == 2 and u.ai == 7 and (u.flags & 0x80) == 0:
			out.append(u)
	return out


## Picking a cell: a right click cancels; with touch controls so does a tap outside the highlighted cells.
func _cancels(r: Array, cells: Variant) -> bool:
	return r[1] == MOUSE_BUTTON_RIGHT or (Game.touch and not cells.has(r[0]))


func _menu_pos(u: BUnit) -> Vector2:
	var sp := st.view.cell_pos(u.pos) - st.view.camera.position
	var vs := st.view.view_size()
	if sp.x < vs.x / 2:
		return Vector2(sp.x + 56, sp.y - 60)
	return Vector2(maxf(sp.x - 130, 0), sp.y - 60)


# ------------------------------------------------------------------ the input loop 0x44e0d9
func player_phase(resumed: bool) -> void:
	end_turn = false
	if not st.view.cell_hovered.is_connected(st.hud.set_hover):
		st.view.cell_hovered.connect(st.hud.set_hover)
	var done := _player_units().is_empty()
	_camera_start()
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
			if _bot == null:
				_bot = InputBot.new(st, "")
				st.add_child(_bot)
			await _bot.fx_test(fx.split(","))
			return
		await _auto_phase()
		return
	while not done and not st.battle_finished():
		idle = true
		var r := await _click()
		idle = false
		if st.battle_finished():
			break
		var cell: Vector2i = r[0]
		var btn: int = r[1]
		var acted := false
		var hover := st.unit_at(cell)
		if _menu_req:
			_menu_req = false
			await system_menu()
		elif btn == MOUSE_BUTTON_LEFT:
			if hover != null:
				acted = await unit_command(hover)
				await st.unit_acted(hover)
			elif st.view.in_bounds(cell):
				st.hud.set_hover(cell)       # terrain info (0x45576d) — the panel shows it
		else:
			if hover != null and st.view.in_bounds(cell):
				await StatusPanel.show_person(st.ui, hover.person)
			else:
				await system_menu()
		if st.result != 0:
			return
		if end_turn:
			end_turn = false
			done = await yes_no(MSG_END)
			continue
		if acted and hover != null:
			await after_player_action(hover)
			if st.result != 0:
				return
			await st.checkpoint()
			if st.result != 0:
				return
			if _remaining() == 0:
				done = await yes_no(MSG_END)
	st.view.clear_highlights()


## Camera to the first unit on the map of slots 0..19, else 20..249 (0x428ea8).
func _camera_start() -> void:
	for u in st.units:
		if u.state == 2:
			await st.view.center_on(u.pos)
			st.view.cursor_cell = u.pos
			return


## Code-7 units of all 250 slots without flag 2, not confused (the auto end-prompt count; 麻痹 units still count).
func _remaining() -> int:
	var n := 0
	for u in st.units:
		if (u.flags & 2) == 0 and not u.confused() and u.state == 2 and u.ai == 7:
			n += 1
	return n


## Autoplay / demo: the AI plays each commandable unit (the AI treats code 7 as active), with the same bookkeeping as
## a player command.
func _auto_phase() -> void:
	var guard := 0
	while guard < 400 and not st.battle_finished():
		guard += 1
		var u: BUnit = null
		for x in _player_units():
			if (x.flags & 6) == 0 and not x.confused():
				u = x
				break
		if u == null:
			return
		st.set_current(u)
		if Rules.can_use_skill(u) == 1 and u.person.sp >= Rules.evb(4061):
			Rules.set_attack_mode(2, Rules.pick_skill(u))
		await st.ai.act(u)
		Rules.set_attack_mode(0)
		u.flags = u.flags | 6
		await st.unit_acted(u)
		await after_player_action(u)
		await st.checkpoint()


## AfterPlayerAction (in 0x44e0d9): dead units leave, 再次移动, then 大杀四方 (else 二次行动) for the unit and every 围攻
## helper that attacked.
func after_player_action(u: BUnit) -> void:
	if st.result == 2:
		return
	await st.post_action()
	await move_again(u)
	await st.post_action()
	var s := u.slot
	while true:
		var x := st.units[s]
		if not st.extra_action(x):
			st.free_action(x)
		var n := Mem.r8(0x500e9c)
		if n == 0:
			break
		n -= 1
		Mem.w8(0x500e9c, n)
		s = Mem.r8(0x500e9d + n)
	st.refresh_units()


## 再次移动 0x415d93: alive, not confused, Q(90, 0x5f, 1, 1) → SE 0x27, a plain move (no menu), done.
func move_again(u: BUnit) -> void:
	if u.hp == 0 or u.state != 2 or u.confused():
		return
	if u.eff(90, 0x5f, 1, 1) == 0:
		return
	u.flags = u.flags & ~6
	Audio.play_se(SoundMap.se_name(0x27))
	if Game.autoplay or Game.demo:
		await st.ai.act(u)
	else:
		await move_select(u, [0x0b, 0xff, 0xff, 0xff], 0, 1)
	u.flags = u.flags | 6
	Mem.w8(Rules.WALKED, 0)
	st.refresh_units()


## Re-open the movement of a unit (疾行 / 瞬移 / 号令 / 再次移动, 0x40eb7e → 0x43d4fc(u, 0x0b, mp, 1)); mp 0 = its move
## points, 0xff = anywhere (instant placement). Returns true if the unit moved or stayed by choice.
func reopen_move(u: BUnit, mp := 0) -> bool:
	return await move_select(u, [0x0b, 0xff, 0xff, 0xff], mp, 1)


# ------------------------------------------------------------------ UnitCommand 0x43dde0
## Returns true when the unit finished its action.
func unit_command(u: BUnit) -> bool:
	Audio.play_se(SoundMap.se_name(0))
	var save_dir := u.dir
	var save_pos := u.pos
	if not await move_select(u, [], 0, 0):
		return false
	st.set_current(u)
	st.refresh_units()
	var en := _menu_enables(u)
	var sel := 0
	while (u.flags & 2) == 0 and sel != 0xff and not st.battle_finished():
		sel = await command_menu(u, en)
		Mem.w8(BattleStage.LAST_ACTION, sel)
		match sel:
			1: await cmd_attack(u)
			2: await cmd_strategy(u)
			3: await cmd_item(u)
			4: u.flags = u.flags | 6
			5: await cmd_bisha(u)
			6: await cmd_siege(u)
			7: await cmd_exchange(u)
	if sel == 0xff:
		u.flags = u.flags & ~4
		if u.pos != save_pos:
			u.pos = save_pos
		u.dir = save_dir
		if u.node:
			u.node.dir = save_dir
	Mem.w8(Rules.WALKED, 0)
	st.refresh_units()
	return sel != 0xff and (u.flags & 2) != 0


## The menu's enable flags, computed once (0x43dde0 / dialog 0x117 init).
func _menu_enables(u: BUnit) -> Array:
	var codes := Rules.attack_codes(u)
	var atk := not Rules.collect(u, u.pos, codes, 0).is_empty()
	return [atk, knows_strategy(u), bag_has_battle_item(), can_exchange(u), can_siege(u),
		Rules.can_use_skill(u) != 0, true, true]


func command_menu(u: BUnit, en: Array) -> int:
	if st.battle_finished():
		return 0xff
	var i := await st.ui.menu.choose(MENU_LABELS, _menu_pos(u), true, "", en, 56)
	if i < 0:
		return 0xff
	return MENU_SEL[i]


# ------------------------------------------------------------------ MoveSelect 0x43d4fc
## The move selection of a unit: the range (flood mode 0, zoc 1), the attack shape of `codes` (default the unit's
## attack range) around its current cell. A click on a valid reachable cell walks there, on the unit itself stays;
## other clicks turn the unit toward the cell or report an occupied one; a right click cancels. Units that cannot be
## commanded only show their range and, on the next click, the reason. mp 0 = the unit's move points; 0xff =
## anywhere with an instant placement (瞬移). mode 1 keeps the last-action byte.
func move_select(u: BUnit, codes: Array, mp: int, mode: int) -> bool:
	if mode != 1:
		Mem.w8(BattleStage.LAST_ACTION, 0xff)
	st.set_current(u)
	if Mem.r8(0x508b00 + u.slot) != 0xff:
		Mem.w8(0x508b00 + u.slot, 1 if u.eff(0x38, 0x5a, 1, 1) == 0 else 0)
	if codes.is_empty():
		codes = Rules.attack_codes(u)
	var why := -1
	if u.side() != 1:
		why = 0
	elif (u.flags & 0x80) != 0 or u.ai != 7:
		why = 1
	elif u.confused():
		why = 5
	elif u.flags & 2:
		why = 6
	var points := u.move_points() if mp == 0 else mp
	var reach := {}
	for c in Movement.move_range(u, points):
		reach[c] = Movement.grid_at(c)
	st.view.set_move_cells(reach)
	if codes[0] != 0xff:
		st.view.set_attack_cells(Rules.codes_cells(codes, u.pos))
	var c := Vector2i(0xff, 0xff)
	while why == -1 and not st.battle_finished():
		var r := await _click()
		c = r[0]
		if r[1] == MOUSE_BUTTON_RIGHT:
			why = 2
		elif reach.has(c) and Movement.dest_valid(u, c):
			why = 4
		elif st.unit_at(c) == u:
			why = 3
		elif Game.touch and not reach.has(c):
			why = 2
		else:
			Audio.play_se(SoundMap.se_name(2))
			var o := st.unit_at(c)
			if o == null or not reach.has(c):
				st.actions.face(u, c)
				st.refresh_units()
			else:
				await st.ui.popup(MSG_OCCUPIED)
	match why:
		0, 1, 5:
			var r2 := await _click()
			if r2[1] != MOUSE_BUTTON_RIGHT:
				Audio.play_se(SoundMap.se_name(2))
				await st.ui.popup([MSG_ENEMY, MSG_FRIEND, "", "", "", MSG_CONFUSED][why])
			else:
				Audio.play_se(SoundMap.se_name(1))
		2:
			Audio.play_se(SoundMap.se_name(1))
		6:
			var r3 := await _click()
			if r3[1] != MOUSE_BUTTON_RIGHT:
				Audio.play_se(SoundMap.se_name(2))
				st.actions.face(u, r3[0])
			else:
				Audio.play_se(SoundMap.se_name(1))
				u.dir = 1      # the right click's cell is (0xff, 0xff): Face turns the unit right (quirk)
			st.refresh_units()
	st.view.clear_highlights()
	if why == 3:
		Audio.play_se(SoundMap.se_name(0))
		return true
	if why != 4:
		return false
	if mp == 0xff:
		u.pos = c                         # instant placement (0x41f3fb)
		u.flags = u.flags | 4
		st.refresh_units()
		return true
	var path := Movement.path_to(u, c)
	var ok: bool = await st.actions.move_unit(u, path)
	if ok:
		u.flags = u.flags | 4
	st.refresh_units()
	return true


# ------------------------------------------------------------------ enable rules
## KnowsStrategy 0x43e023: the unit knows a strategy, or (策略模仿) an orthogonal neighbour knows an imitable one.
## MP, 禁咒 and terrain are not checked here.
func knows_strategy(u: BUnit) -> bool:
	if u.eff(45, 0x3b, 1, 1) != 0:
		for o in Effects.neighbours4(u):
			for s in 144:
				if Rules.knows(o, s, true):
					return true
	for s in 144:
		if Rules.knows(u, s):
			return true
	return false


## The consumables the army holds (count array 0x493af0 for ids 0xa0 + i; the port also counts consumables lying in
## the bag), with the battle filter 0x46708c.
func battle_items() -> Array:
	var counts := {}
	for i in 0x60:
		var n := Mem.r8(0x493af0 + i)
		if n > 0:
			counts[0xa0 + i] = n
	for e in Game.bag_entries():
		var iid := int(e["id"])
		if int(Game.item(iid).get("category_code", 0)) == 3:
			counts[iid] = int(counts.get(iid, 0)) + 1
	var out := []
	var ids := counts.keys()
	ids.sort()
	for iid in ids:
		if item_battle_ok(iid):
			out.append([iid, counts[iid]])
	return out


## 0x46708c: effect index k = type − 0x1a not 0x20..0x23 (任务物品 合成材料 工具物品 装备升级); with EV 4087 also not
## 0x17 (单挑) nor 0x24..0x28 (mines).
func item_battle_ok(iid: int) -> bool:
	var it := Game.item(iid)
	if it.is_empty():
		return false
	var k := (int(it.get("type", 0)) - 0x1a) & 0xff
	if k >= 0x20 and k <= 0x23:
		return false
	if Rules.evb(4087) != 0 and (k == 0x17 or (k >= 0x24 and k <= 0x28)):
		return false
	return true


func bag_has_battle_item() -> bool:
	return not battle_items().is_empty()


## CanExchange 0x41bc16: EV 4052 (0 or 4) or the unit's kind 0; the unit's 0x501a84 byte clear; at least two units of
## side code EV 4052 in its 3×3 box (itself included).
func can_exchange(u: BUnit) -> bool:
	var e := Rules.evb(4052)
	if e == 0 and u.kind != 0:
		return false
	if Mem.r8(0x501a84 + u.slot) != 0:
		return false
	var r := Rules.count_units(e, true, maxi(u.pos.x - 1, 0), maxi(u.pos.y - 1, 0), u.pos.x + 1, u.pos.y + 1)
	return r[0] >= 2


## CanSiege 0x419d74: some attackable target has a 围攻 helper (never true with the shipped family data).
func can_siege(u: BUnit) -> bool:
	for t in Rules.collect(u, u.pos, Rules.attack_codes(u), 0):
		if not siege_helpers(u, t, false).is_empty():
			return true
	return false


## SiegeHelpers 0x405bf2 → 0x416e53: units on the 8 cells around t (orthogonal first) on a's side, family row 7 = 0,
## AI units only below EV 4061 SP, not acted, not confused, whose attack shape covers that neighbour.
func siege_helpers(a: BUnit, t: BUnit, collect: bool) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for k in 8:
		var c: Vector2i = t.pos + Rules.DIR8[k]
		var h := st.unit_at(c)
		if h == null or h == a or h.side() != a.side():
			continue
		if Rules.fam_attr(7, h.family()) != 0:
			continue
		if h.ai != 7 and h.person.sp >= Rules.evb(4061):
			continue
		if (h.flags & 2) or h.confused():
			continue
		if not Rules.codes_cells(Rules.attack_codes(h), h.pos).has(t.pos):
			continue
		out.append(h)
		if not collect:
			return out
	return out


# ------------------------------------------------------------------ the target picker 0x45533d
## Highlight `codes` around the unit and wait for a target. mode 1 attack, 2 strategy on enemies, 3 strategy on allies,
## 4 a cell / an ally (items, 交换, 纵火 …); `s` the strategy (or item) id, `item_mode` the byte 0x500ad7 (1 thrown
## item, 3 exchange). Returns the target slot, 0xfe for an accepted empty cell (picked_cell) or 0xff when cancelled /
## nothing is in range.
func pick_target(u: BUnit, codes: Array, mode: int, s := -1, item_mode := 0) -> int:
	var ally := (mode == 3 or mode == 4) and item_mode <= 1
	var cells := Rules.codes_cells(codes, u.pos, ally)
	var found := Rules.collect(u, u.pos, codes, 1 if ally else 0)
	if found.is_empty():
		if ally:
			await msg(MSG_NO_ALLY)
			return 0xff
		if item_mode <= 1:
			await msg(MSG_NO_ENEMY)
			return 0xff
	if item_mode > 1:
		ally = true
	var area := 0
	if mode == 1:
		area = Rules.phys_area(u)
	elif mode == 2 or mode == 3:
		if item_mode == 1:
			area = int(Game.item(s).get("growth", 0)) if s >= 0 else 0
		elif s >= 0 and Rules.mg(Rules.MG_ID, s) != 0x1a:
			area = Rules.strat_area(u, s)
	st.view.set_attack_cells(cells)
	var result := 0xff
	while not st.battle_finished():
		var r := await _click()
		if _cancels(r, cells):
			result = 0xff
			break
		var c: Vector2i = r[0]
		if not cells.has(c):
			await msg(MSG_OUT)
			continue
		var t := st.unit_at(c)
		var slot := t.slot if t != null else 0xff
		if mode >= 4:
			var chk := 0
			if st.strategy.has_method("cell_check"):
				chk = st.strategy.cell_check(s, c)
			if chk == 1:
				continue
			if chk >= 2:
				picked_cell = c
				result = 0xfe
				break
		elif slot == 0xff:
			if area == 0:
				continue
			if not _empty_cell_ok(u, c, area, mode, ally, s, item_mode):
				continue
			picked_cell = c
			slot = 0xfe
		if slot == 0xff:
			continue
		if ally:
			if slot == 0xfe:
				result = slot
				break
			if t.side() != u.side():
				await msg(MSG_ENEMY)
				continue
			if item_mode > 1 and Rules.evb(4052) != 4 and t.kind != 0:
				await msg(MSG_FRIEND)
				continue
			result = slot
			break
		if slot == 0xfe:
			result = slot
			break
		if t.side() == u.side():
			await msg(MSG_OWN)
			continue
		result = slot
		break
	st.view.clear_highlights()
	return result


## 0x406e2b: an empty cell is accepted when the area around it hits a unit — attacks (not in 围攻) hostile units;
## strategies only with 洪荒之力 (Q(68, 0x6e, 1, 1)).
func _empty_cell_ok(u: BUnit, c: Vector2i, area: int, mode: int, ally: bool, s: int, item_mode: int) -> bool:
	if mode == 1:
		if Rules.attack_mode() == 1:
			return false
		for p in Rules.area_cells(area, c, Rules.unit_tile(u, 2)):
			var o := st.unit_at(p)
			if o != null and o.hp > 0 and o.side() != u.side():
				return true
		return false
	if item_mode != 1 and u.eff(68, 0x6e, 1, 1) == 0:
		return false
	var hit := false
	if s >= 0 and st.strategy.has_method("targets_for"):
		hit = not st.strategy.targets_for(s, u, c).is_empty()
	else:
		for p in Rules.area_cells(area, c, u.pos):
			var o := st.unit_at(p)
			if o != null and o.hp > 0 and (o.side() == u.side()) == ally:
				hit = true
	return hit


# ------------------------------------------------------------------ 攻击 0x43dada
func cmd_attack(u: BUnit) -> void:
	var t := await pick_target(u, Rules.attack_codes(u), 1)
	if t == 0xff:
		return
	var tu: BUnit
	if t == 0xfe:
		# area weapon on an empty cell: the area around it is the target list [G: first hostile unit of the area]
		for p in Rules.area_cells(Rules.phys_area(u), picked_cell, u.pos):
			var o := st.unit_at(p)
			if o != null and o.hp > 0 and o.side() != u.side():
				tu = o
				break
		if tu == null:
			return
	else:
		tu = st.units[t]
	await st.actions.attack_command(u, tu, true)
	u.flags = u.flags | 6
	st.refresh_units()


# ------------------------------------------------------------------ 策略 0x42c177(u, 0)
func cmd_strategy(u: BUnit) -> void:
	if u.sealed():
		await msg(MSG_SEALED)
		return
	while (u.flags & 2) == 0 and not st.battle_finished():
		var s := await strategy_list(u)
		if s < 0:
			return
		if await cast_flow(u, s):
			u.flags = u.flags | 6
			return


## The strategy list (dialog 0x11a): known strategies (策略模仿 adds the neighbours' imitable ones) with their MP
## cost; rows the unit cannot cast now (MP) are greyed.
func strategy_list(u: BUnit) -> int:
	var strats := Rules.known_strategies(u, true)
	if strats.is_empty():
		return -1
	var labels := []
	var en := []
	for s in strats:
		var sd := Rules.strat(s)
		labels.append("%s　%d" % [sd.get("name", "?"), Rules.mp_cost(u, s)])
		en.append(Rules.can_cast(u, s))
	var i := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "策略　（ＭＰ %d）" % u.mp, en, 160)
	if i < 0:
		return -1
	return strats[i]


## How the dispatcher picks the target of strategy s (0x4233f8 → 0x45533d): 0 none (self / whole map), 2 an enemy,
## 3 an ally, 4 a cell.
func strategy_pick_mode(s: int) -> int:
	if st.strategy.has_method("pick_mode"):
		return st.strategy.pick_mode(s)
	match Rules.mg(Rules.MG_ID, s):
		1, 22, 23, 24, 25, 28, 29, 31, 34, 35:
			return 0
		27:
			return 4
	return 3 if Rules.s_side(s) == 1 else 2


## Situation check, target choice and the cast. Returns true when the strategy was performed.
func cast_flow(u: BUnit, s: int) -> bool:
	var why := Rules.situation(s, u)
	if why != "":
		if why != "-":
			await msg(why)
		return false
	var mode := strategy_pick_mode(s)
	var cell := u.pos
	if mode != 0:
		var codes := [Rules.strat_range(u, s), 0xff, 0xff, 0xff]
		while true:
			var t := await pick_target(u, codes, mode, s)
			if t == 0xff:
				return false
			if t == 0xfe:
				cell = picked_cell
				break
			var tu := st.units[t]
			var v := Rules.target_valid(s, u, tu)
			if v != "":
				if v != "-":
					await msg(v)
				continue
			cell = tu.pos
			break
	st.actions.face(u, cell)
	return await st.strategy.cast(s, u, cell)


# ------------------------------------------------------------------ 道具 0x40a985
func cmd_item(u: BUnit) -> void:
	while (u.flags & 2) == 0 and not st.battle_finished():
		var items := battle_items()
		if items.is_empty():
			return
		var labels := []
		for e in items:
			labels.append("%s　×%d" % [Game.item(e[0]).get("name", "?"), e[1]])
		var i := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "道具", [], 160)
		if i < 0:
			return
		var iid: int = items[i][0]
		var t := await pick_target(u, [1, 0xff, 0xff, 0xff], 4, iid)
		if t == 0xff or t == 0xfe:
			continue
		var tu := st.units[t]
		if st.actions.has_method("item_usable") and not st.actions.item_usable(iid, tu, 1):
			await msg("不能在这里使用。")
			continue
		if await st.actions.use_item(u, iid, tu):
			u.flags = u.flags | 6


# ------------------------------------------------------------------ 必杀 (0x467c9e / 0x423358)
func cmd_bisha(u: BUnit) -> void:
	var fam_skill := Rules.fam_attr(8, u.family())
	if Rules.ev(4087) == 0 and fam_skill != 0 and Rules.can_use_skill(u) != 0:
		if await st.strategy.family_special(u):
			u.flags = u.flags | 6
		return
	if u.sealed():
		await msg(MSG_SEALED)
		return
	while not st.battle_finished():
		var k := await skill_list(u)
		if k < 0:
			Rules.set_attack_mode(0)
			return
		Rules.set_attack_mode(2, k)
		var t := await pick_target(u, Rules.attack_codes(u), 1)
		if t == 0xff or t == 0xfe:
			continue
		await st.actions.bisha_attack(u, st.units[t])
		u.flags = u.flags | 6
		Rules.set_attack_mode(0)
		st.refresh_units()
		return


## The 武将技 list 0x411261: 重击 always, then every 武将技 1..0x4f the person knows (a 军师技 family only its own);
## a row is selectable when its SP cost ≤ SP (0x465bcd).
func skill_list(u: BUnit) -> int:
	var ids: Array[int] = []
	var a := Rules.fam_attr(8, u.family())
	if a == 0:
		ids.append(0)
		for k in range(1, 0x50):
			if Rules.knows_skill(u.pid, k):
				ids.append(k)
	else:
		ids.append(a + 0x4f)
	var sp := u.person.sp
	var labels := []
	var en := []
	for k in ids:
		var r := Rules.skill(k)
		var cost := int(r.get("sp_cost", 255))
		labels.append("%s　%d" % [r.get("name", "?"), cost])
		en.append(cost <= sp)
	var i := await st.ui.menu.choose(labels, Vector2(-1, -1), true, "必杀　（气 %d）" % sp, en, 160)
	if i < 0:
		return -1
	return ids[i]


# ------------------------------------------------------------------ 围攻 0x41d693
func cmd_siege(u: BUnit) -> void:
	Rules.set_attack_mode(1)
	while not st.battle_finished():
		var t := await pick_target(u, Rules.attack_codes(u), 1)
		if t == 0xff or t == 0xfe:
			Rules.set_attack_mode(0)
			return
		var helpers := siege_helpers(u, st.units[t], true)
		if helpers.is_empty():
			await msg(MSG_NO_SIEGE)
			continue
		if st.actions.has_method("siege_command"):
			await st.actions.siege_command(u, st.units[t], helpers)
		u.flags = u.flags | 6
		break
	Rules.set_attack_mode(0)


# ------------------------------------------------------------------ 交换 0x4151fe
func cmd_exchange(u: BUnit) -> void:
	var k := await st.ui.menu.choose(["交换武器", "交换护具", "交换辅助装备"], Vector2(-1, -1), true)
	if k < 0:
		return
	var p := u.person
	var own := Mem.r8(p.base + 0x2e + 3 * k)
	if own == 0xff:
		await msg("没有此项装备")
		return
	Mem.w8(Rules.STRAT_ITEM, 3)
	while not st.battle_finished():
		var t := await pick_target(u, [1, 0xff, 0xff, 0xff], 4, -1, 3)
		if t == 0xff or t == 0xfe:
			break
		var o := st.units[t]
		if Mem.r8(0x501a84 + o.slot) != 0:
			await msg("目前禁止交换")
			break
		var q := o.person
		var theirs := Mem.r8(q.base + 0x2e + 3 * k)
		if (theirs != 0xff and not p.can_equip(theirs)) or not q.can_equip(own):
			await msg("装备不匹配")
			continue
		var a := p.base + 0x2e + 3 * k
		var b := q.base + 0x2e + 3 * k
		var n := 1 if k == 2 else 3
		for i in n:
			var x := Mem.r8(a + i)
			Mem.w8(a + i, Mem.r8(b + i))
			Mem.w8(b + i, x)
		if theirs == 0xff and k < 2:
			Mem.w8(a + 1, 0xff)
			Mem.w8(a + 2, 0xff)
		u.flags = u.flags | 6
		await msg("装备交换完成")
		break
	Mem.w8(Rules.STRAT_ITEM, 0)
	st.refresh_units()


# ------------------------------------------------------------------ toolbar / system menu
## The touch shell's 菜单 (BattleStage.open_menu while idle): the system menu, whatever is under the cursor.
func request_menu() -> void:
	if not idle:
		return
	_menu_req = true
	st.view.cell_clicked.emit(st.view.cursor_cell, MOUSE_BUTTON_RIGHT)


## NextUnit 0x44e706: the next player unit (slots 0..59, kind 0, code 7, not acted / moved, not confused); none →
## "没有可以行动的部队。" and the end prompt.
func next_unit() -> bool:
	var lst: Array[BUnit] = []
	for i in 60:
		var u := st.units[i]
		if (u.flags & 6) == 0 and u.state == 2 and u.ai == 7 and u.kind == 0 and not u.confused():
			lst.append(u)
	if lst.is_empty():
		await st.ui.popup(MSG_NONE_LEFT)
		return false
	var k := Mem.r8(0x4b4238) + 1
	if k >= lst.size():
		k = 0
	Mem.w8(0x4b4238, k)
	await st.view.center_on(lst[k].pos)
	st.view.cursor_cell = lst[k].pos
	st.hud.set_hover(lst[k].pos)
	return true


## 部队一览: every unit on the field by side; picking one centres the camera and shows its status.
func unit_list() -> void:
	var lst: Array[BUnit] = []
	var labels := []
	for grp in [["我军", 0, 20], ["友军", 20, 60], ["敌军", 60, 250]]:
		for i in range(grp[1], grp[2]):
			var u := st.units[i]
			if u.state == 2 and u.pid >= 0:
				lst.append(u)
				labels.append("%s %s　%s Lv%d　兵 %d/%d%s" % [grp[0], u.person.name, u.person.class_name_str(), u.level(), u.hp, u.max_hp(), "　（已行动）" if (u.flags & 2) and i < 60 else ""])
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
	var i := await st.ui.menu.choose(["结束回合", "检索未执行部队", "部队一览", "胜利条件", "存储进度", "读取进度", "回到标题"], Vector2(-1, -1), true)
	var main: Node = Game.main
	match i:
		0:
			end_turn = true
		1:
			if not await next_unit():
				end_turn = true
		2:
			await unit_list()
		3:
			var t := st.victory_text if st.victory_text != "" else st.goal_text
			await st.ui.dialog.talk(null, "", t if t != "" else "现在无法显示", false)
		4:
			await main.save_menu()
		5:
			await main.load_menu()
		6:
			main.to_title()
