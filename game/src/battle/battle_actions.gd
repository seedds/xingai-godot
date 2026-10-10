class_name BattleActions
extends RefCounted
## Battle mechanics + their on-map presentation (docs/rules.md §4–§9).

var st: BattleStage
var _counter_depth := 0
var _attack_start_actor: BUnit

## Sound ids from the engine (wave player 0x47467a call sites): hit 0x23 / critical 0x24 (0x40437b),
## no-damage 0x1e / 0x1f (0x4043fa), level-up 0x0b (0x4074ff), equipment level-up 0x0d (0x4084db),
## retreat 0x10 (0x441814), vanish 0x11 (0x441be8), appear 0x2a / 0x0f (0x4570ee).
const SE_SWING := ""
const SE_HIT := "se35"
const SE_CRIT := "se36"
const SE_MISS := "se30"
const SE_DIE := "se16"
const SE_HEAL := "se19"
const SE_LEVELUP := "se11"
const SE_EQUIP_UP := "se13"


func _init(s: BattleStage) -> void:
	st = s


func view() -> BattleView:
	return st.view


func wait(t: float) -> void:
	if Game.autoplay or t <= 0:
		return
	await st.get_tree().create_timer(t).timeout


# ------------------------------------------------------------------ ranges
## Attack range code with unit overrides (0x43f8be).
func attack_range_code(u: BUnit) -> int:
	if u.status & BUnit.ST_FEAR:
		return 11
	if u.has_effect(42):
		return u.effect_value(42)
	var c := u.cls()
	if u.has_effect(21) and c >= 15 and c <= 17:
		return [7, 8, 8][c - 15]
	return int(Game.cls(c).get("attack_range", 0))


func attack_cells(u: BUnit, from: Vector2i) -> Array[Vector2i]:
	return Shapes.range_cells(attack_range_code(u), from, view().map_w, view().map_h)


func can_attack(att: BUnit, def: BUnit, from := Vector2i(-1, -1)) -> bool:
	if from.x < 0:
		from = att.pos
	return attack_cells(att, from).has(def.pos)


func attackable_targets(u: BUnit, from: Vector2i) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for c in attack_cells(u, from):
		var t := st.unit_at(c)
		if t and t.is_enemy_of(u) and t.active():
			out.append(t)
	return out


# ------------------------------------------------------------------ movement
func in_zoc(u: BUnit, c: Vector2i) -> bool:
	if u.has_effect(33):
		return false
	for d in Grid.DIRS:
		var o := st.unit_at(c + d)
		if o and o.is_enemy_of(u):
			return true
	return false


## {cell: remaining_mp} reachable by u; `parents` gets the path tree.
func reachable(u: BUnit, parents: Dictionary = {}) -> Dictionary:
	var w := view().map_w
	var h := view().map_h
	if u.status & BUnit.ST_PARALYSIS:
		return {u.pos: 0}
	var cost := func(c: Vector2i) -> int:
		return Rules.move_cost(u, view().terrain_at(c))
	var blocked := func(c: Vector2i) -> bool:
		var o := st.unit_at(c, u)
		return o != null and o.is_enemy_of(u) and not (u.flags & BUnit.F_PASS)
	var stop := func(c: Vector2i) -> bool:
		return in_zoc(u, c)
	var r := Grid.reachable(u.pos, u.move_points(), w, h, cost, blocked, stop, parents)
	# cannot end the move on a cell occupied by another unit
	var out := {}
	for c in r:
		var o := st.unit_at(c, u)
		if o == null:
			out[c] = r[c]
	return out


func move_unit(u: BUnit, path: Array[Vector2i]) -> void:
	BUnit.move_origin = u.pos
	if path.is_empty():
		return
	var n := u.node
	if n == null:
		u.pos = path[-1]
		return
	n.set_pose(UnitSprite.Pose.WALK, u.dir)
	n.walk_speed = 8.0
	for c in path:
		var d := Grid.dir_of(c - u.pos)
		u.dir = d
		n.dir = d
		n.queue_redraw()
		if Game.autoplay:
			n.position = view().cell_pos(c)
		else:
			var tw := n.create_tween()
			tw.tween_property(n, "position", view().cell_pos(c), 0.075)
			await tw.finished
		u.pos = c
	n.walk_speed = 4.0
	n.set_pose(UnitSprite.Pose.STAND, u.dir)
	u.moved = true
	st.refresh_units()


func face(u: BUnit, target: Vector2i) -> void:
	if target == u.pos:
		return
	u.dir = Grid.dir_of(target - u.pos)
	if u.node:
		u.node.dir = u.dir
		u.node.queue_redraw()


# ------------------------------------------------------------------ attack (§4)
## Full attack sequence: strikes (double attack), then counterattack.
func attack(att: BUnit, def: BUnit) -> void:
	var counter := _counter_depth > 0
	if not counter:
		_attack_start_actor = att
		# combat object 0x4927f0 (0x4061fc): attacker and defender slot, read by the scripts' 攻防 tests
		Mem.w8(0x4927f0, att.slot)
		Mem.w8(0x4927f1, def.slot)
	await view().ensure_visible(def.pos)
	face(att, def.pos)
	face(def, att.pos)
	var best_exp := 0
	var total_damage := 0
	var weapon_hit := false
	for strike in 2:
		if not def.active() or not att.active():
			break
		var mode := 1 if counter else 0
		var hit := Rules.chance(Rules.hit_rate(att, def))
		var dmg := 0
		var crit := false
		if hit:
			var ta := view().terrain_at(att.pos)
			var td := view().terrain_at(def.pos)
			dmg = Rules.calc_damage(att, def, ta, td, true, mode)
			if Rules.chance(Rules.crit_rate(att, def)):
				crit = true
				dmg = dmg * 3 / 2
				if def.has_effect(57):
					dmg = 0
			if strike == 1 and def.has_effect(57):
				dmg = 0
			dmg = mini(dmg, def.hp)
		await _anim_strike(att, def, hit, dmg, crit)
		if hit:
			total_damage += dmg
			weapon_hit = weapon_hit or dmg > 0
			var killed := def.hp - dmg <= 0
			_apply_damage(def, dmg)
			if not killed:
				_on_hit_effects(att, def)
			if att.slot < 15:
				best_exp = maxi(best_exp, _phys_exp(att, def, killed))
		if strike == 0 and (not def.active() or not Rules.chance(Rules.double_rate(att, def, counter))):
			break
		if strike == 0 and not Game.autoplay:
			st.hud.popup_number("连击！", att.pos, Color(1, 0.9, 0.3))
	if att.has_effect(81) and total_damage > 0:
		att.hp = mini(att.hp + total_damage / 2, att.max_hp())
	if def.hp <= 0:
		await unit_defeated(def)
	# equipment experience
	if att.slot < 15:
		await _equip_exp(att, true, def, weapon_hit)
	if def.slot < 15 and def.active():
		await _equip_exp(def, false, att, total_damage > 0)
	if best_exp > 0:
		await gain_exp(att, best_exp)
	# counterattack
	if def.active() and att.active():
		var depth := _counter_depth
		var allow := depth == 0 or (depth == 1 and _attack_start_actor and _attack_start_actor.has_effect(40))
		if allow and not (def.status & BUnit.ST_CONFUSION) and not att.has_effect(44) and can_attack(def, att):
			_counter_depth += 1
			await attack(def, att)
			_counter_depth -= 1
	if not counter:
		_counter_depth = 0
	st.refresh_units()


func _phys_exp(a: BUnit, t: BUnit, killed: bool) -> int:
	var la := a.level()
	var lt := t.level()
	var e := 0
	if killed:
		e = mini((lt - la) * 8 + 32, 200) if la < lt else maxi(Rules.sat_sub(32, (la - lt) * 4), 10)
		if t.pid == st.boss_pid:
			e *= 2
	else:
		e = mini((lt - la) * 2 + 8, 100) if la < lt else maxi(Rules.sat_sub(8, la - lt), 1)
	return e * exp_mult(a) / 100


func exp_mult(u: BUnit) -> int:
	return 100 + u.person.equip_bonus(8)


func _on_hit_effects(att: BUnit, def: BUnit) -> void:
	var c := att.cls()
	if (att.has_effect(35) or c == 50) and Rules.chance(60):
		def.status |= BUnit.ST_CONFUSION
	if att.has_effect(36):
		def.status |= BUnit.ST_POISON
	if (c == 45 or att.has_effect(34)) and Rules.chance(60):
		def.status |= BUnit.ST_PARALYSIS
	if c == 38 and Rules.chance(60):
		def.status |= BUnit.ST_LOST
	if att.has_effect(38):
		def.status |= BUnit.ST_SEAL
	if att.has_effect(37):
		def.status |= [BUnit.ST_POISON, BUnit.ST_CONFUSION, BUnit.ST_PARALYSIS, BUnit.ST_SEAL][Rules.rand(4)]


func _apply_damage(u: BUnit, dmg: int) -> void:
	u.hp = maxi(u.hp - dmg, 0)
	if u.hp == 0:
		u.extra["dying"] = true     # keeps the sprite for the defeat animation
	st.refresh_units()


func _anim_strike(att: BUnit, def: BUnit, hit: bool, dmg: int, crit: bool) -> void:
	if Game.autoplay:
		return
	if att.node:
		await att.node.play_attack(att.dir, 0.07 if not crit else 0.1)
	if def.node:
		if hit:
			Audio.play_se(SE_CRIT if crit else SE_HIT)
			def.node.set_pose(UnitSprite.Pose.HURT, def.dir)
			def.node.flash = 0.7
			st.hud.popup_number(("暴击 " if crit else "") + str(dmg), def.pos, Color(1, 0.3, 0.2) if crit else Color(1, 1, 1))
			await wait(0.18)
			def.node.flash = 0.0
		else:
			Audio.play_se(SE_MISS)
			def.node.set_pose(UnitSprite.Pose.DEFEND, def.dir)
			st.hud.popup_number("格挡", def.pos, Color(0.6, 0.9, 1))
			await wait(0.3)
		def.node.set_pose(UnitSprite.Pose.STAND, def.dir)


func unit_defeated(u: BUnit) -> void:
	u.hp = 0
	u.extra["dying"] = true
	if u.node and not Game.autoplay:
		Audio.play_se(SE_DIE)
		var n := u.node
		for k in 6:
			n.visible = k % 2 == 0
			await wait(0.08)
		n.visible = true
	await st.remove_unit(u, false)
	st.unit_died.emit(u)
	await st.checkpoint()


# ------------------------------------------------------------------ experience (§8)
func gain_exp(u: BUnit, e: int) -> void:
	var p := u.person
	if p.level >= 70 or e <= 0:
		return
	if not Game.autoplay:
		st.hud.popup_number("经验 +%d" % e, u.pos, Color(0.6, 1, 0.6))
	var total := p.exp + e
	while total >= 100 and p.level < 70:
		total -= 100
		if Mem.r32(0x55e1c0) == 4:
			p.bonus_counter = 5     # mod option: every level-up gets the +1 grade bonus
		var g := p.level_up(1)
		u.hp = mini(u.hp + g[5], u.max_hp())
		u.mp = mini(u.mp + g[6], u.max_mp())
		Audio.play_se(SE_LEVELUP)
		await _show_level_up(p, g)
	p.exp = 0xff if p.level >= 70 else total


func _show_level_up(p: Person, g: Array) -> void:
	var names := ["攻击", "防御", "精神", "爆发", "士气", "兵力", "策略"]
	var lines := "%s 的等级上升到 %d！\n" % [p.name, p.level]
	for i in 7:
		if g[i] > 0:
			lines += "%s +%d　" % [names[i], g[i]]
	await st.ui.popup(lines, 0.0 if not Game.demo else 1.2)


func _equip_exp(u: BUnit, weapon: bool, other: BUnit, damaged: bool) -> void:
	var p := u.person
	var iid := p.weapon if weapon else p.armor
	if iid < 0:
		return
	var lvl := p.weapon_lvl if weapon else p.armor_lvl
	var cur := p.weapon_exp if weapon else p.armor_exp
	if cur == 0xff:
		return
	var la := u.level()
	var lt := other.level()
	var gain: int
	if weapon:
		gain = (2 if la > lt else 3) if damaged else 1
	else:
		gain = (3 if la < lt else 4) if damaged else 1
	gain = gain * exp_mult(u) / 100
	if lvl >= 9:
		gain = 1
	var it := Game.item(iid)
	var treasure := bool(it.get("treasure", false))
	var maxl := 10 if treasure else 3
	var thr := 100 + (50 if treasure else 0) + (100 if treasure and lvl == 9 else 0)
	var total := cur + gain
	var up := false
	while total >= thr and lvl < maxl:
		lvl += 1
		total -= thr
		up = true
	if weapon:
		p.weapon_lvl = lvl
		p.weapon_exp = 0xff if lvl >= maxl else total
	else:
		p.armor_lvl = lvl
		p.armor_exp = 0xff if lvl >= maxl else total
	if up:
		Audio.play_se(SE_EQUIP_UP)
		await st.ui.popup("%s 的%s等级上升到 %d！" % [p.name, "武器" if weapon else "防具", lvl], 0.0 if not Game.demo else 1.0)


# ------------------------------------------------------------------ strategies (§5)
func known_strategies(u: BUnit) -> Array[int]:
	var out: Array[int] = []
	var c := str(u.cls())
	for s in Game.strategies_db:
		if not s.get("loaded_by_exe", true):
			continue
		var lv: Dictionary = s.get("learn_level_by_class", {})
		if lv.has(c) and int(lv[c]) > 0 and int(lv[c]) <= u.level():
			out.append(int(s["id"]))
	return out


func strategy_mp(s: int) -> int:
	return int(Game.strategy(s).get("mp", 0))


func strategy_cast_cells(u: BUnit, s: int) -> Array[Vector2i]:
	var sd := Game.strategy(s)
	var ally := int(sd.get("target", 0)) == 1
	# range 11: cast on the caster's own cell (weather 58-60, 飓风, the self buffs)
	return Shapes.range_cells(int(sd.get("range", 0)), u.pos, view().map_w, view().map_h, ally or int(sd.get("range", 0)) == 11)


func strategy_area(u: BUnit, s: int, target: Vector2i) -> Array[Vector2i]:
	return Shapes.area_cells(int(Game.strategy(s).get("area", 0)), u.pos, target, view().map_w, view().map_h)


## Units affected by casting s at `target` (side filter 0 enemy, 1 ally).
func strategy_targets(u: BUnit, s: int, target: Vector2i) -> Array[BUnit]:
	var side := int(Game.strategy(s).get("target", 0))
	var out: Array[BUnit] = []
	if s == 14:
		# 飓风 (0x42423a): every opposing unit on the map where the strategy is usable
		for t in st.units:
			if t.active() and t.is_enemy_of(u) and usable_on(u, s, t):
				out.append(t)
		return out
	if s == 66:
		# 玄武 (0x424810): every unit on the map, of either side (0x42097a passes for strategies >= 0x14)
		for t in st.units:
			if t.active():
				out.append(t)
		return out
	# the unit on the target cell must pass 0x420422, else nothing happens; the others in the area only need a
	# fitting terrain for element strategies (0x425349 → 0x42097a)
	var main := st.unit_at(target)
	if main == null or not _side_ok(u, side, main) or not usable_on(u, s, main):
		return out
	for c in strategy_area(u, s, target):
		var t := st.unit_at(c)
		if t == null or not t.active() or not _side_ok(u, side, t):
			continue
		if t == main or Rules.strat_terrain_ok(s, u, view().terrain_at(t.pos)):
			out.append(t)
	return out


func _side_ok(u: BUnit, side: int, t: BUnit) -> bool:
	if side == 0:
		return t.is_enemy_of(u)
	if side == 1:
		return not t.is_enemy_of(u)
	return true


## Can u use strategy s on t (0x420422, see Rules.strat_usable)?
func usable_on(u: BUnit, s: int, t: BUnit) -> bool:
	return Rules.strat_usable(s, u, t, view().terrain_at(t.pos))


func can_cast(u: BUnit, s: int) -> bool:
	if u.status & BUnit.ST_SEAL:
		return false
	return u.mp >= strategy_mp(s)


## Why u cannot cast s right now (0x41fec9), or "".
func cast_refusal(u: BUnit, s: int) -> String:
	return Rules.strat_castable(s, u, st.weather())


func cast(u: BUnit, s: int, target: Vector2i) -> void:
	var sd := Game.strategy(s)
	var cost := strategy_mp(s)
	u.mp = maxi(u.mp - cost, 0)
	face(u, target)
	var targets := strategy_targets(u, s, target)
	if s == 57 and not targets.is_empty():
		Mem.w8(Rules.ZHANBEI_USED + u.slot, 1)     # 0x423960: once per turn (0x41fec9)
	await view().ensure_visible(target)
	if not Game.autoplay:
		st.hud.popup_number(str(sd.get("name", "")), u.pos, Color(0.8, 0.9, 1))
		if u.node:
			u.node.set_pose(UnitSprite.Pose.CHEER, u.dir)
		await _play_strategy_effect(s, target, targets)
		if u.node:
			u.node.set_pose(UnitSprite.Pose.STAND, u.dir)
	var best_exp := 0
	if s in [58, 59, 60]:
		st.weather_level = [4, 0, 2][s - 58] if st.climate != 4 else st.weather_level
		best_exp = 20
	for t in targets:
		var e := await _apply_strategy(u, s, t)
		best_exp = maxi(best_exp, e)
	if u.slot < 15 and best_exp > 0:
		await gain_exp(u, best_exp * exp_mult(u) / 100)
	st.refresh_units()


func _strat_exp(u: BUnit, t: BUnit, killed: bool, damage_strat: bool) -> int:
	var la := u.level()
	var lt := t.level()
	if t.is_enemy_of(u) and damage_strat and killed:
		var e := mini((lt - la) * 8 + 32, 200) if la < lt else maxi(Rules.sat_sub(32, (la - lt) * 4), 10)
		return e * (2 if t.pid == st.boss_pid else 1)
	return mini((lt - la) * 4 + 10, 100) if la < lt else maxi(Rules.sat_sub(10, (la - lt) / 2), 5)


func _apply_strategy(u: BUnit, s: int, t: BUnit) -> int:
	if s == 38 or s == 66:
		return await _apply_random_strategy(u, s, t)
	var damage_set := s in Rules.DAMAGE_STRATS or s == 21
	# heals (0x42378d) have no hit roll: the amount is capped by what is missing
	var hit := s in [39, 40, 41, 42, 43, 44, 45] or Rules.chance(Rules.strat_hit(u, t, s, view().terrain_at(t.pos), st.weather()))
	if not hit:
		if not Game.autoplay:
			st.hud.popup_number("失败", t.pos, Color(0.7, 0.7, 0.7))
		return _strat_exp(u, t, false, false) if not t.is_enemy_of(u) else (mini((t.level() - u.level()) * 4 + 10, 100) if u.level() < t.level() else maxi(Rules.sat_sub(10, (u.level() - t.level()) / 2), 5))
	if s == 21:
		# 暗杀: marks the target for instant defeat
		Mem.w8(0x569f00 + t.slot, 2)
		await unit_defeated(t)
		return _strat_exp(u, t, true, true)
	if damage_set and s != 38 and s != 66:
		var dmg := Rules.strat_damage(u, t, s, false)
		if s == 22:
			t.mp = maxi(t.mp - dmg, 0)
			if not Game.autoplay:
				st.hud.popup_number("策略 -%d" % dmg, t.pos, Color(0.5, 0.6, 1))
			return _strat_exp(u, t, false, true)
		var killed := dmg >= t.hp
		if not Game.autoplay:
			st.hud.popup_number(str(dmg), t.pos)
			if t.node:
				t.node.set_pose(UnitSprite.Pose.HURT, t.dir)
				await wait(0.25)
				t.node.set_pose(UnitSprite.Pose.STAND, t.dir)
		_apply_damage(t, dmg)
		if s == 20:   # 暗算: absorb HP
			u.hp = mini(u.hp + dmg, u.max_hp())
		if killed:
			await unit_defeated(t)
		else:
			if s in [33, 34]:
				t.status |= BUnit.ST_POISON
			elif s in [35, 36]:
				t.status |= BUnit.ST_PARALYSIS
		return _strat_exp(u, t, killed, true)
	match s:
		23, 24: _buff(t, 3, false)
		25, 26: _buff(t, 4, false)
		27, 28: _buff(t, 2 if t.family() in [8, 9, 10, 18] else 0, false)
		29, 30: _buff(t, 1, false)
		31, 32: t.status |= BUnit.ST_CONFUSION
		37: t.status |= BUnit.ST_SEAL
		39, 40, 41, 42, 43, 67:
			var h2 := Rules.heal_amount(u, t, s, false)
			t.hp = mini(t.hp + h2, t.max_hp())
			Audio.play_se(SE_HEAL)
			if not Game.autoplay: st.hud.popup_number("+%d" % h2, t.pos, Color(0.4, 1, 0.4))
		44, 45:
			var m := Rules.heal_amount(u, t, s, false)
			t.mp = mini(t.mp + m, t.max_mp())
			if not Game.autoplay: st.hud.popup_number("策略 +%d" % m, t.pos, Color(0.5, 0.7, 1))
		46, 47: t.status &= ~0x7e
		48: _buff(t, 5, true)
		49, 50: _buff(t, 3, true)
		51, 52: _buff(t, 4, true)
		53, 54:
			if t.cls() == 50 or (t.cls() >= 24 and t.cls() <= 26):
				_buff(t, 0, true)
				_buff(t, 2, true)
			else:
				_buff(t, 2 if t.family() in [8, 9, 10, 18] else 0, true)
		55, 56: _buff(t, 1, true)
		57:
			t.moved = false
			t.acted = false
		61:
			_stat_code(t, 0x35)                  # 聚气: code 0xa0
		62:
			t.mp = mini(t.mp + t.max_mp() / 4, t.max_mp())
		63:
			for c in [0x31, 0x33, 0x35, 0x37]:   # 豪气: code 0xaf
				_stat_code(t, c)
		_:
			pass
	st.refresh_units()
	return _strat_exp(u, t, false, false)


## 八阵 (0x423edc) and 玄武 (0x424810): no hit roll; each target gets one random outcome. 八阵 draws rand(8):
## 0 八阵 damage, 1 混乱, 2 麻痹, 3 封策, 4 毒烟 damage + 中毒, 5 爆发/士气/攻击/防御↓ (code 0x6f),
## 6 the same ↑ (0xaf), 7 兵力 to full (0x43c548: MaxHP − HP). 玄武 draws rand(7) of 混乱, 麻痹, 封策, 中毒,
## 0x6f, 0xaf, full 兵力. 八阵's statuses only stick if the target survives the damage (0x4224a8). EXP (0x420efb):
## 八阵 is a damage strategy, so its kill formula applies when the stored amount is not below the target's
## 兵力 (a heal is stored negated and compares as a huge unsigned value); 玄武 always gives the small one.
func _apply_random_strategy(u: BUnit, s: int, t: BUnit) -> int:
	var k: int = Rules.rand(8) if s == 38 else Rules.rand(7) + 1
	var amount := 0       # damage, or −heal
	match k:
		0, 4:
			if s == 38:
				var hs := 38 if k == 0 else 33
				if Rules.chance(Rules.strat_hit(u, t, hs, view().terrain_at(t.pos), st.weather())):
					amount = Rules.strat_damage(u, t, hs, false)
		7:
			amount = -(t.max_hp() - t.hp)
	var stored := amount if amount >= 0 else 0x100000000 + amount
	var e := _strat_exp(u, t, s == 38 and stored >= t.hp, s == 38)
	var survives := amount < t.hp
	match k:
		1:
			if survives: t.status |= BUnit.ST_CONFUSION
		2:
			if survives: t.status |= BUnit.ST_PARALYSIS
		3:
			if survives: t.status |= BUnit.ST_SEAL
		4:
			if survives: t.status |= BUnit.ST_POISON
		5:
			for c in [0x17, 0x19, 0x1b, 0x1d]:
				_stat_code(t, c)
		6:
			for c in [0x31, 0x33, 0x35, 0x37]:
				_stat_code(t, c)
	if amount > 0:
		var dmg := mini(amount, t.hp)
		if not Game.autoplay:
			st.hud.popup_number(str(dmg), t.pos)
		_apply_damage(t, dmg)
		if t.hp == 0:
			await unit_defeated(t)
	elif amount < 0:
		t.hp -= amount
		Audio.play_se(SE_HEAL)
		if not Game.autoplay:
			st.hud.popup_number("+%d" % -amount, t.pos, Color(0.4, 1, 0.4))
	st.refresh_units()
	return e


## Stat change codes of 0x420cb2: 0x17 爆发↓ 0x19 士气↓ 0x1b 攻击↓ (精神 for caster families, 0x43ffed)
## 0x1d 防御↓; 0x30 移动↑ 0x31 爆发↑ 0x33 士气↑ 0x37 防御↑; 0x35 (mod 0x4d8985): classes 24-26 and 50 raise
## both 攻击 and 精神, others 精神 if a caster family, else 攻击.
func _stat_code(t: BUnit, code: int) -> void:
	var magic := t.family() in [8, 9, 10, 18]
	match code:
		0x17, 0x18: _buff(t, 3, false)
		0x19, 0x1a: _buff(t, 4, false)
		0x1b, 0x1c: _buff(t, 2 if magic else 0, false)
		0x1d, 0x1e: _buff(t, 1, false)
		0x30: _buff(t, 5, true)
		0x31, 0x32: _buff(t, 3, true)
		0x33, 0x34: _buff(t, 4, true)
		0x35, 0x36:
			if t.cls() == 50 or (t.cls() >= 24 and t.cls() <= 26):
				_buff(t, 2, true)
				_buff(t, 0, true)
			else:
				_buff(t, 2 if magic else 0, true)
		0x37, 0x38: _buff(t, 1, true)


func _buff(t: BUnit, i: int, up: bool) -> void:
	t.set_buff(i, Rules.buff_step(t.buff(i), up))
	if not Game.autoplay:
		var names := ["攻击", "防御", "精神", "爆发", "士气", "移动"]
		st.hud.popup_number(names[i] + ("↑" if up else "↓"), t.pos, Color(1, 0.9, 0.4) if up else Color(0.7, 0.6, 1))


func _play_strategy_effect(s: int, target: Vector2i, targets: Array[BUnit]) -> void:
	var tbl: Array = EffectPlayer.index().get("strategy_effect_table", {}).get("values", [])
	if s < 0 or s >= tbl.size():
		return
	var v := int(tbl[s])
	if v == 255:
		return
	if v >= 100:
		# MCALL animations are centred on the target point (0x402cb5), like the small effects
		var e := EffectPlayer.create("mcall", v - 100)
		if e:
			e.position = view().cell_center(target)
			e.z_index = 10
			view().fx_layer.add_child(e)
			await e.done
		return
	var cells: Array[Vector2i] = []
	for t in targets:
		cells.append(t.pos)
	if cells.is_empty():
		cells.append(target)
	var last: EffectPlayer = null
	for c in cells:
		var e2 := EffectPlayer.create("xben", v)
		if e2 == null:
			return
		e2.position = view().cell_center(c)
		view().fx_layer.add_child(e2)
		last = e2
	if last:
		await last.done


# ------------------------------------------------------------------ items
func usable_items() -> Array:
	var out := []
	for e in Game.bag_entries():
		var it := Game.item(int(e["id"]))
		if String(it.get("category", "")) == "consumable":
			out.append(e)
	return out


func item_usable_on(iid: int, t: BUnit) -> bool:
	var it := Game.item(iid)
	match int(it.get("type", 0)):
		63: return t.hp < t.max_hp()
		64: return t.mp < t.max_mp()
		65: return t.status & 0x48 != 0
		66: return t.status & 0x12 != 0
		67: return t.status & 0x7e != 0
		68: return t.status & 0x24 != 0
		76: return t.cls() <= 38 and t.cls() % 3 < 2 and t.level() >= (20 if t.cls() % 3 == 0 else 40)
	return true


func use_item(u: BUnit, entry: Dictionary, t: BUnit) -> void:
	var iid := int(entry["id"])
	var it := Game.item(iid)
	var v := int(it.get("value", 0))
	var p := t.person
	face(u, t.pos)
	Audio.play_se(SE_HEAL)
	match int(it.get("type", 0)):
		63:
			var h := mini(v, t.max_hp() - t.hp)
			t.hp += h
			st.hud.popup_number("+%d" % h, t.pos, Color(0.4, 1, 0.4))
		64:
			var m := mini(v, t.max_mp() - t.mp)
			t.mp += m
			st.hud.popup_number("策略 +%d" % m, t.pos, Color(0.5, 0.7, 1))
		65: t.status &= ~0x48
		66: t.status &= ~0x12
		67: t.status &= ~0x7e
		68: t.status &= ~0x24
		69:
			for i in 5:
				t.set_buff(i, 6)
		70, 71, 72, 73, 74:
			var si: int = [0, 2, 1, 3, 4][int(it["type"]) - 70]
			p.set_stat_word(si, mini(p.get_stat_word(si) + v, 9999))
			p.set_raw(si, mini(p.get_raw(si) + v, 100))
			await st.ui.popup("%s 的能力上升了！" % p.name, 0.0 if not Game.demo else 1.0)
		75:
			p.bonus_counter = 5
			var g := p.level_up(1)
			t.hp = t.max_hp()
			t.mp = t.max_mp()
			await _show_level_up(p, g)
		76:
			p.cls = p.cls + 1
			await st.ui.popup("%s 晋升为 %s！" % [p.name, p.class_name_str()], 0.0 if not Game.demo else 1.0)
	_consume(entry)
	st.refresh_units()


func _consume(entry: Dictionary) -> void:
	var iid := int(entry["id"])
	if int(entry.get("slot", -1)) >= 0:
		Game.remove_bag_slot(int(entry["slot"]))
	else:
		Game.remove_item_id(iid)
