extends Node
## Strategy usability (Rules.strat_usable = 0x420422, Rules.strat_castable = 0x41fec9). Prints "t_strat: PASS".

func _check(ok: bool, what: String) -> bool:
	if not ok:
		print("t_strat: FAIL ", what)
	return ok


func _unit(slot: int, pid: int, colour: int, mode: int) -> BUnit:
	var u := BUnit.at(slot)
	u.clear(slot)
	u.pid = pid
	u.colour = colour
	u.mode = mode
	u.state = BUnit.STATE_ON_MAP
	u.hp = u.max_hp()
	u.mp = u.max_mp()
	return u


func run() -> void:
	var ok := true
	Game.new_game_state()
	var ai := _unit(35, 300, 2, 1)        # enemy, AI-controlled
	var pl := _unit(0, 0, 0, 7)           # player unit
	var foe := _unit(36, 301, 2, 1)
	# 伪书 (31): an AI caster skips a confused target; the player may still cast it
	pl.status = BUnit.ST_CONFUSION
	ok = _check(not Rules.strat_usable(31, ai, pl, 0), "AI 伪书 on a confused target") and ok
	ok = _check(Rules.strat_usable(31, pl, pl, 0), "player 伪书 ignores the status") and ok
	pl.status = 0
	ok = _check(Rules.strat_usable(31, ai, pl, 0), "AI 伪书 on a clear target") and ok
	ok = _check(Rules.strat_hit(ai, pl, 31, 0, 0) >= 0, "hit rate defined") and ok
	pl.status = BUnit.ST_CONFUSION
	ok = _check(Rules.strat_hit(ai, pl, 31, 0, 0) == 0, "AI 伪书 hit 0 on a confused target") and ok
	pl.status = 0
	# 毒烟 (33) poisoned, 陷阱 (35) paralysed, 封印 (37) sealed
	pl.status = BUnit.ST_POISON
	ok = _check(not Rules.strat_usable(33, ai, pl, 0), "AI 毒烟 on a poisoned target") and ok
	pl.status = BUnit.ST_PARALYSIS
	ok = _check(not Rules.strat_usable(35, ai, pl, 0), "AI 陷阱 on a paralysed target") and ok
	pl.status = BUnit.ST_SEAL
	ok = _check(not Rules.strat_usable(37, ai, pl, 0), "AI 封印 on a sealed target") and ok
	pl.status = 0
	# heals (39): not on a full-HP target for AI casters
	ok = _check(not Rules.strat_usable(39, ai, foe, 0), "AI heal at full HP") and ok
	foe.hp -= 10
	ok = _check(Rules.strat_usable(39, ai, foe, 0), "AI heal when wounded") and ok
	# debuffs (23) refuse a stat at level 2 only; buffs (49) refuse level >= 4
	pl.set_buff(3, 2)
	ok = _check(not Rules.strat_usable(23, ai, pl, 0), "debuff on level 2") and ok
	pl.set_buff(3, 0)
	ok = _check(Rules.strat_usable(23, ai, pl, 0), "debuff on level 0 allowed") and ok
	foe.set_buff(3, 4)
	ok = _check(not Rules.strat_usable(49, ai, foe, 0), "buff on level 4") and ok
	# 战备 (57): never on oneself; AI only on units that moved or acted
	ok = _check(not Rules.strat_usable(57, ai, ai, 0), "战备 on oneself") and ok
	ok = _check(not Rules.strat_usable(57, ai, foe, 0), "AI 战备 on a unit that has not acted") and ok
	foe.acted = true
	ok = _check(Rules.strat_usable(57, ai, foe, 0), "AI 战备 on a unit that acted") and ok
	# 暗杀 (21, category 17): always allowed by 0x420422
	ok = _check(Rules.strat_usable(21, ai, pl, 0), "暗杀 category 17") and ok
	# 0x41fec9: fire in rain (weather 2) but not when cloudy (1); 战备 once per turn
	ok = _check(Rules.strat_castable(0, ai, 2) != "" and Rules.strat_castable(0, ai, 1) == "", "fire and weather") and ok
	Mem.w8(Rules.ZHANBEI_USED + ai.slot, 1)
	ok = _check(Rules.strat_castable(57, ai, 0) == "不能再用了！", "战备 twice") and ok
	Mem.w8(Rules.ZHANBEI_USED + ai.slot, 0)
	print("t_strat: PASS" if ok else "t_strat: FAILED")
