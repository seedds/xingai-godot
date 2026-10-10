class_name BattleActions
extends RefCounted
## Physical attacks, movement, EXP / level-ups, equipment EXP, items and retreats of the 6.6 engine
## (docs/battle.md §1, §4, §5; docs/ai.md §4.11, §4.12, §5.3), with their on-map presentation.
##
## The combat object 0x4927f0 is mirrored in memory (+0 attacker slot, +1 current target, +0x10 target list,
## +0x608 strike counter) because the rolls (0x4287a8), CalcDamage and the scripts' action tests read it; the
## per-target values live in a Combat instance (the original's one global object is re-initialised by every
## exchange and nothing reads those values once the exchange is over).

const LAST_ACTION := 0x501bf9     # 1 attack, 2 strategy, 5 必杀, 6 围攻 (BattleStage.LAST_ACTION)
const PRIMARY_DMG := 0x48e8bd     # HP damage dealt to the primary target in this exchange
const STRIKES := 0x492df8         # combat object +0x608
const TARGET_LIST := 0x492800     # combat object +0x10 (0xff-terminated)
const COUNTER_FLAG := 0x501bfa    # depth of the last counter
const SIEGE_PRE := 0x500e99       # 围攻: the target struck first (先手)
const SIEGE_N := 0x500e9c         # 围攻 helpers that attacked
const SIEGE_LIST := 0x500e9d      # 围攻 helpers (0xff-terminated, 8 bytes)
const BAG_COUNT := 0x493a50       # consumable counts by item id (0x420299 / 0x4202c4)
const ITEM_CTX := 0x497750        # item-use context: +0 item, +2 user slot, +3 target slot (0x4083a7)
const NO_CRIT_LINE := 0x501a76    # option 暴击不语
const SKIP_ANIM := 0x501a75       # option 跳过战斗过程
const LEVEL_DETAIL := 0x501a71    # option 显示升级提示: the level-up window lists the gains
const TICK := 0.05                # one tick of 0x423971 / 0x40cb10

## Debuff item effects of 破坏攻击..破坏移动 (table 0x437e19) and of the four status attacks (0x437e1f).
const DEBUFF_EID := [0x34, 0x24, 0x54, 0x2d, 0x2c, 0x5f]
const STATUS_EID := [0x2d, 0x26, 0x2b, 0x2c]
## 随机异常状态 0x42119b: chance(L·mul + add) for each status mask (L = the attacker's weapon level).
const RANDOM_STATUS := [[5, 15, 4], [4, 8, 0x10], [3, 3, 2], [2, 0, 8]]
## Persons with their own critical line (table 0x48b230; line = Imsg 700 + index).
const CRIT_LINE_PERSONS := [0, 1, 2, 3, 6, 7, 9, 13, 15, 16, 17, 33, 34, 36, 57, 84, 95, 108, 109, 119, 32]
## Fruit animation Meff by stat (0x41d233).
const FRUIT_MEFF := [0x22, 0x23, 0x22, 0x24, 0x25]
## Level-up window labels (0x486ae0, 0x48e87e).
const LEVEL_LABELS := ["攻击", "防御", "精神", "爆发", "士气", "HP MAX", "MP MAX"]


class Combat:
	var a: BUnit
	var targets: Array[BUnit] = []
	var dmg: Array[int] = []
	var raw: Array[int] = []
	var mp: Array[int] = []
	var aexp: Array[int] = []
	var exp := 0
	var wexp := 0
	var crit := false
	var player := false

	func resize(n: int) -> void:
		dmg.resize(n)
		raw.resize(n)
		mp.resize(n)
		aexp.resize(n)


var st: BattleStage
var _last_targets: Array[BUnit] = []


func _init(s: BattleStage) -> void:
	st = s


func wait(t: float) -> void:
	if Game.autoplay or t <= 0:
		return
	await st.wait(t)


func ticks(n: int) -> void:
	await wait(n * TICK)


func _se(id: int) -> void:
	if not Game.autoplay:
		Audio.play_se(SoundMap.se_name(id))


func _msg(text: String, style := 2) -> void:
	await st.ui_message(style, text)


## The result panel 0x450986(kind, …, p3 HP loss, p4 MP loss, p5 EXP, p6 weapon EXP, p7 armour EXP, long wait).
func _panel(u: BUnit, kind: int, hp: int, mp: int, e: int, w: int, ae: int) -> void:
	if st.has_method("result_panel"):
		await st.result_panel(u, kind, hp, mp, e, w, ae, true)


## 0x426b33: 2 when the unit has no HP, 8 while it is confused (0x423fe8(8)), else 0.
static func dead_or_confused(u: BUnit) -> int:
	if u.hp == 0:
		return 2
	return BUnit.ST_CONFUSION if u.confused() else 0


static func s8(v: int) -> int:
	v &= 0xff
	return v - 256 if v >= 128 else v


# ------------------------------------------------------------------ facing
## Face 0x412148: same column → down if the cell is below, else up; otherwise right / left.
func dir_to(from: Vector2i, to: Vector2i) -> int:
	if to.x == from.x:
		return 2 if to.y > from.y else 0
	return 1 if to.x > from.x else 3


func _set_dir(u: BUnit, d: int) -> void:
	u.dir = d
	if u.node:
		u.node.dir = d
		u.node.queue_redraw()


## 0x412148 → 0x4575b8: turn toward a cell; SE 6 when the facing changes (not while byte 0x500ad7 = 2).
func face(u: BUnit, cell: Vector2i) -> void:
	if cell == u.pos:
		return
	var d := dir_to(u.pos, cell)
	if d == u.dir:
		return
	if Mem.r8(Rules.STRAT_ITEM) != 2:
		_se(6)
	_set_dir(u, d)


## 0x435829: silent turn toward another unit.
func turn(u: BUnit, t: BUnit) -> void:
	if t != null and t.pos != u.pos:
		_set_dir(u, dir_to(u.pos, t.pos))


func can_attack(a: BUnit, b: BUnit) -> bool:
	return Rules.in_attack_range(a, a.pos, b.pos)


## 0x412b30: is unit `t` among the hostile units on the cells of `codes` around u?
func in_range(u: BUnit, codes: Array, t: BUnit) -> bool:
	return Rules.collect(u, u.pos, codes, 0).has(t)


## The combat object's target list (0x492800) holds the unit (op 0x5e).
func was_target(u: BUnit) -> bool:
	return _last_targets.has(u)


# ------------------------------------------------------------------ movement
## The path walker 0x43d9ed: step by step along `path` (the cells after the start); each step moves the unit
## (0x442000) and runs the 先制攻击 / mine test 0x428b7a with do_it, which ends the walk. False when interrupted.
## [0x500c48] is the planner's (Movement.path_to); the moved flag is the caller's.
func move_unit(u: BUnit, path: Array[Vector2i]) -> bool:
	var n := u.node
	var ok := true
	if n and not Game.autoplay:
		n.set_pose(UnitSprite.Pose.WALK, u.dir)
		n.walk_speed = 8.0
	for c in path:
		var traps := Movement.trap_count(u, c)
		_set_dir(u, dir_to(u.pos, c))
		if n and not Game.autoplay:
			var tw := n.create_tween()
			tw.tween_property(n, "position", st.view.cell_pos(c), 0.075)
			await tw.finished
		u.pos = c
		if n and is_instance_valid(n):
			n.position = st.view.cell_pos(c)
		# 0x428b7a(u, c, 1): the 先制攻击 interceptors, then — the mover still standing — the mine test (0x4749b5)
		var stop := false
		if traps != 0:
			await _trap(u, c)
			stop = true
		if u.state == 2 and u.hp > 0 and await Mines.step(st, u, c):
			stop = true
		if stop:
			ok = false
			break
	if n and is_instance_valid(n):
		n.walk_speed = 4.0
		n.set_pose(UnitSprite.Pose.STAND, u.dir)
	st.refresh_units()
	return ok


## 先制攻击 0x428a53 with do_it: every hostile unit (state 2, HP > 0) whose count +0x22 is below its 先制攻击 value
## and whose attack range covers the cell attacks the mover (count + 1, Attack 0x43db23 with checkPre 1); the mover
## has acted after each; a fallen mover ends the scan.
func _trap(u: BUnit, c: Vector2i) -> void:
	for x: BUnit in st.units:
		if x.state != 2 or x.side() == u.side() or x.hp == 0:
			continue
		var v := x.eff(0x52, 0x51, 0, 0) & 0xff
		if v == 0 or x.byte(0x22) >= v or not Rules.in_attack_range(x, x.pos, c):
			continue
		x.set_byte(0x22, x.byte(0x22) + 1)
		await attack(x, u, true)
		u.flags = u.flags | 6
		st.refresh_units()
		if u.hp == 0:
			return


# ------------------------------------------------------------------ the attack (0x43db23)
## The 攻击 command (player 0x43dada, AI 0x43aaf7): Attack, then the attacker has acted; last action 1.
func attack_command(a: BUnit, t: BUnit, check_pre := true) -> void:
	Mem.w8(LAST_ACTION, 1)
	await attack(a, t, check_pre)
	a.flags = a.flags | 6
	st.refresh_units()


## Attack 0x43db23(A, T, checkPre): turn, Preempt (策略先手 / 先手攻击), the exchange (T first when preempted),
## FollowUp (奋战 / 引导) and SupportAttacks (同仇敌忾 / 戮力同心) against the last unit 引导 attacked, else T.
func attack(a: BUnit, t: BUnit, check_pre := true) -> void:
	turn(a, t)
	var pre := 0
	if check_pre:
		pre = await preempt(t, a)
	if pre != 0xff:
		if pre != 0:
			await exchange(t, a)
		else:
			await exchange(a, t)
	var led: BUnit = await follow_up(a, t)
	await support_attacks(led if led != null else t, a)


## Preempt 0x410f1c(T, A): a confused T does nothing; 策略先手 casts at A when A is in the strategy's range
## (0xff when that leaves A dead or confused); 先手攻击 with A in T's attack range → T faces A and strikes first.
func preempt(t: BUnit, a: BUnit) -> int:
	if t.confused():
		return 0
	var v := t.eff(0x5e, 0x78, 1, 0) & 0xff
	if v != 0:
		var s := v - 1
		if in_range(t, [Rules.strat_range(t, s), 0xff, 0xff, 0xff], a) and Rules.can_cast(t, s):
			if await st.strategy.cast_at(t, a, s) and dead_or_confused(a) != 0:
				return 0xff
	if t.eff(0x1a, 0x29, 1, 1) != 0 and in_range(t, Rules.attack_codes(t), a):
		face(t, a.pos)
		return 1
	return 0


## Exchange 0x4064f1(X, Y): the targets (Y and the area units), up to two strikes (each followed by 策略追击 and
## the "again" test, which also runs after the second), the post-exchange (reflect, 吸血, 吸收金钱, EXP), the
## attacker's 功勋 conversion (0x42ab32(0)) and, in a normal attack, the counter.
func exchange(x: BUnit, y: BUnit) -> void:
	if Rules.attack_mode() == 1:
		turn(x, y)
	var c := Combat.new()
	c.a = x
	c.player = x.kind == 0
	c.targets = Rules.attack_targets(x, y)
	_sync(c)
	Mem.w8(STRIKES, 0)
	while Mem.r8(STRIKES) <= 1:
		await strike(c)
		await _pursuit(c, y)
		if not _again(c):
			break
		Mem.w8(STRIKES, Mem.r8(STRIKES) + 1)
		if x.confused():
			break
	await _post_exchange(c)
	await st.merit_after_attack(x, false)
	if Rules.attack_mode() == 0:
		await _counter(c)


func _sync(c: Combat) -> void:
	Mem.w8(Rules.COMBAT, c.a.slot)
	Mem.w8(Rules.COMBAT + 1, c.targets[0].slot if not c.targets.is_empty() else 0xff)
	for i in c.targets.size():
		Mem.w8(TARGET_LIST + i, c.targets[i].slot)
	Mem.w8(TARGET_LIST + c.targets.size(), 0xff)
	_last_targets = c.targets.duplicate()


## Strike 0x4527fe: Compute 0x405de1, then 0x452907: 转移伤害 (not with 斩杀攻击), the animation 0x4526e7 and Apply
## 0x405966; the units 转移伤害 appended leave the list again.
func strike(c: Combat) -> void:
	_compute(c)
	var n0 := c.targets.size()
	if c.a.eff(0x6e, 0x7d, 1, 0) == 0:
		_transfer(c)
	await _animate(c)
	await _apply(c)
	if c.targets.size() > n0:
		c.targets.resize(n0)
		c.resize(n0)
		_sync(c)


## Compute 0x405de1: per target the damage (mode 2 for a second strike, 1 in a counter, else 0), the critical of
## the primary target, 防御二次攻击, the MP辅助 drain, MP防御, 金钱防御, the attack EXP (max), weapon EXP (sum),
## armour EXP, the hit counter and the 功勋 gains; at the end 爆发 / 士气 功勋 for a second strike / critical.
func _compute(c: Combat) -> void:
	var n := c.targets.size()
	c.resize(n)
	for i in n:
		c.dmg[i] = 0
		c.mp[i] = 0
	var a := c.a
	var strikes := Mem.r8(STRIKES)
	for i in n:
		var t: BUnit = c.targets[i]
		Mem.w8(Rules.COMBAT + 1, t.slot)
		var mode := 2 if strikes != 0 else (1 if Mem.r32(Rules.COUNTER_DEPTH) != 0 else 0)
		var r: Array = Rules.calc_damage(a, t, false, mode)
		c.dmg[i] = r[0]
		c.raw[i] = r[1]
		if i == 0 and t.hp > 0:
			_critical(c)
		if s8(strikes) > 0 and t.eff(0x31, 0x41, 1, 1) != 0:
			c.dmg[i] = 0
		var d: int = c.dmg[i]
		if d != 0:
			var mp := t.mp & 0xffff
			if _mp_assist(t):
				var loss := 1 if mp > Rules.pct(50, t.max_mp()) else 0
				c.mp[i] = loss
				mp -= loss
			if t.eff(0x32, 0x44, 1, 1) != 0 and mp != 0:
				var x: int
				if d > mp:
					x = mp
				elif d < t.hp:
					x = d
				else:
					x = mini(c.raw[i], mp)
				if t.eff(0x32, 0x44, 1, 1) != 0 and x >= t.hp:
					x = t.hp
				c.mp[i] += x
				c.dmg[i] = 0
			elif not _gold_shield(c, i, t):
				c.dmg[i] = mini(d, t.hp)
		c.exp = maxi(c.exp, _phys_exp(c, i))
		c.wexp += _weapon_exp(c, i)
		st._merit_gain(a, 0, 1)
		c.aexp[i] = _armour_exp(c, i)
		var h := Rules.HITS + t.slot
		if Mem.r8(h) != 0xff:
			Mem.w8(h, Mem.r8(h) + 1)
		st._merit_gain(t, 1, 1)
		if c.dmg[i] == 0 and c.mp[i] == 0:
			st._merit_gain(t, 3, 1)
	if strikes >= 1:
		st._merit_gain(a, 3, 1)
	if c.crit:
		st._merit_gain(a, 4, 1)


## The critical (0x405eb8): 必杀 always (+50 %); otherwise a CritRate up to 100 must pass Roll(rate, 2) and adds 100;
## 防御致命攻击 (unless 忽视暴防) then makes the strike deal 0; the bonus is + damage·(rate/2) %.
func _critical(c: Combat) -> void:
	var t: BUnit = c.targets[0]
	var rate := 100
	if Rules.attack_mode() != 2:
		rate = Rules.crit_rate(c.a, t)
		if rate <= 100:
			if not Rules.roll_acc(rate, 2):
				return
			rate += 100
		if t.eff(0x30, 0x41, 1, 1) != 0 and c.a.eff(0x70, 0x34, 1, 1) == 0:
			c.dmg[0] = 0
			c.crit = true
			return
	c.dmg[0] += Rules.pct(rate >> 1, c.dmg[0])
	c.crit = true


## 0x414d70: any MP辅助 row (0xa2..0xa6).
func _mp_assist(t: BUnit) -> bool:
	for j in 5:
		if t.eff(0xa2 + j, 0x7e, 3, 0) != 0:
			return true
	return false


## 金钱防御 0x42128a: damage > 1 becomes 1; a player-controlled unit pays (damage − 1)·10 gold (not enough → no
## effect).
func _gold_shield(c: Combat, i: int, t: BUnit) -> bool:
	if t.eff(0x6b, 0x5b, 1, 1) == 0 or c.dmg[i] <= 1:
		return false
	if t.ai == 7:
		var cost: int = (c.dmg[i] - 1) * 10
		if Game.gold < cost:
			return false
		Game.gold = Game.gold - cost
	c.dmg[i] = 1
	return true


## 转移伤害 0x418205: each original target T with v = Q(T, 0x57, 0x73) moves dmg·v % to the lowest-HP hostile unit
## in T's attack range (never the attacker) when its damage reaches v; added to that unit's damage (≤ its HP) or
## appended as a new target.
func _transfer(c: Combat) -> void:
	var n := c.targets.size()
	for i in n:
		var t: BUnit = c.targets[i]
		var v := t.eff(0x57, 0x73, 1, 0)
		if v == 0:
			continue
		var best: BUnit = null
		for o in Rules.collect(t, t.pos, Rules.attack_codes(t), 0):
			if o != c.a and (best == null or o.hp < best.hp):
				best = o
		if best == null or c.dmg[i] < v:
			continue
		var m := Rules.pct(v, c.dmg[i])
		c.dmg[i] -= m
		m = mini(m, best.hp)
		var j := c.targets.find(best)
		if j >= 0:
			c.dmg[j] = mini(c.dmg[j] + m, best.hp)
		else:
			c.targets.append(best)
			c.dmg.append(m)
			c.raw.append(m)
			c.mp.append(0)
			c.aexp.append(0)
	if c.targets.size() > n:
		_sync(c)


## Again 0x4060d2: 双枪攻击 gives the second strike; never during a counter; else Roll(DoubleRate, 0) while fewer
## than 2 strikes. Clears the critical flag.
func _again(c: Combat) -> bool:
	Mem.w8(Rules.COMBAT + 1, c.targets[0].slot)
	var strikes := s8(Mem.r8(STRIKES))
	var r := false
	if c.a.eff(0x35, 0x42, 1, 0) != 0 and strikes < 1:
		r = true
	elif Mem.r32(Rules.COUNTER_DEPTH) == 0 and strikes < 2:
		r = Rules.roll_acc(Rules.double_rate(c.a, c.targets[0]), 0)
	c.crit = false
	return r


## 策略追击 0x417983: cast strategy v − 1 at Y (0x4179b4: only when castable); if it is not cast, one more strike
## (the strike counter stays).
func _pursuit(c: Combat, y: BUnit) -> void:
	var v := c.a.eff(0x5d, 0x77, 1, 0) & 0xff
	if v == 0:
		return
	var done := false
	if Rules.can_cast(c.a, v - 1):
		done = await st.strategy.cast_at(c.a, y, v - 1)
	if not done:
		await strike(c)


## Apply 0x405966: per target — a miss: 猛击 / 盾反; a hit: debuffs, random breaks, ailments, 随机异常状态 (on the
## attacker instead when the target has 反弹异常攻击, not in a 必杀); SP gain; the result panel; HP / MP; armour
## EXP; a damaged survivor: 自动使用 and knock-back; the target's 功勋 conversion (0x42ab32(1)).
func _apply(c: Combat) -> void:
	var knocked := 0
	var item_mode := Mem.r8(Rules.ITEM_MODE)
	var k := Rules.skill_id()
	var a := c.a
	for i in c.targets.size():
		var t: BUnit = c.targets[i]
		Mem.w8(Rules.COMBAT + 1, t.slot)
		var d: int = c.dmg[i]
		var m: int = c.mp[i]
		if item_mode == 0:
			if d == 0 and m == 0:
				await _smash_on_miss(a, t)
			else:
				var v := t
				if k == 0 and t.eff(0x12, 0x2a, 1, 1) != 0:
					v = a
				await _debuffs(a, v)
				await _random_break(a, v)
				_statuses(a, v)
				if Rules.forced(0x13) != 0 or a.eff(0x11, 0x1d, 1, 1) != 0:
					_random_status(v, a.person)
		var sp := Rules.sp_gain(t, d)
		await _panel(t, sp, d, m, 0, 0, c.aexp[i] if item_mode == 0 else 0)
		if i == 0:
			Mem.w32(PRIMARY_DMG, Mem.r32(PRIMARY_DMG) + d)
		t.hp = t.hp - d
		t.mp = (t.mp & 0xffff) - m
		await equip_exp(t, 1, c.aexp[i])
		if d > 0 and t.hp != 0:
			await auto_use(t, a)
			if item_mode == 0:
				if await _knock_back(t, a) and i == 0:
					knocked += 1
				if knocked != 0 and i != 0 and i == c.targets.size() - 1:
					_retarget(c)
		t.flags = t.flags & ~0x20
		await st.merit_after_attack(t, true)
	st.refresh_units()


## 猛击 / 盾反 0x422026 on a missed strike: 猛击 (A) takes min(v, 100) % of T's HP and confuses it; then, T alive,
## T's 盾反 takes min(w, 100) % of A's HP and paralyses it.
func _smash_on_miss(a: BUnit, t: BUnit) -> void:
	var v := a.eff(0x72, 0x4a, 1, 0)
	if v != 0:
		await _smash(t, a, BUnit.ST_CONFUSION, mini(v & 0xff, 100))
	if t.hp != 0:
		var w := t.eff(0x73, 0x4a, 1, 0)
		if w != 0:
			await _smash(a, t, BUnit.ST_PARALYSIS, mini(w & 0xff, 100))


## 0x422076 → 0x4220d3: 反弹异常攻击 sends the ailment to the source; a living victim loses p % of its HP (no roll,
## shown in the result panel) and gets the ailment.
func _smash(victim: BUnit, source: BUnit, mask: int, p: int) -> void:
	if victim.eff(0x12, 0x2a, 1, 1) != 0:
		source.inflict(mask)
		mask = 0
	if victim.hp != 0:
		var d := Rules.pct(p, victim.hp)
		victim.inflict(mask)
		await _panel(victim, 0, d, 0, 0, 0, 0)
		victim.hp = victim.hp - d


## Debuffs 0x40399f: 破坏攻击..破坏移动 (or the 必杀 8..13) lower V's buff.
func _debuffs(a: BUnit, v: BUnit) -> void:
	for s in 6:
		if Rules.forced(8 + s) != 0 or a.eff(6 + s, DEBUFF_EID[s], 1, 1) != 0:
			await buff_set(v, s, false)


## RandomBreak 0x472d6e: min(n, 6) distinct stats drawn by rand(6) (a repeat is redrawn) lowered.
func _random_break(a: BUnit, v: BUnit) -> void:
	var n := Rules.forced(0xe)
	if n == 0:
		n = a.eff(0xc, 0x5e, 1, 0)
		if n == 0:
			return
	n = mini(n & 0xff, 6)
	var done := []
	while done.size() < n:
		var s := Rules.rand(6)
		if done.has(s):
			continue
		done.append(s)
		await buff_set(v, s, false)


## Statuses 0x4039f6: 麻痹 / 禁咒 / 混乱 / 中毒 attacks (or the 必杀 15..18), each rolled with Chance2(v, 0).
func _statuses(a: BUnit, v: BUnit) -> void:
	for s in 4:
		var hit := Rules.forced(15 + s) != 0
		if not hit:
			var q := a.eff(0xd + s, STATUS_EID[s], 1, 0 if s == 2 else 1)
			hit = q != 0 and Rules.chance2(q & 0xff, 0)
		if hit:
			v.inflict(2 << s)


## 随机异常状态 0x42119b(V, A's person): chance(L·mul + add) for 禁咒, 中毒, 麻痹, 混乱 (L = weapon level).
func _random_status(v: BUnit, pa: Person) -> void:
	var l := Mem.r8(pa.base + 0x2f)
	for r in RANDOM_STATUS:
		if Rules.chance(l * int(r[0]) + int(r[1])):
			v.inflict(r[2])


## Buff setter 0x409821 → 0x414361 → 0x45aa37 (animated): up → 3 from below 3, else 6; down → 0 from 3 or below,
## else 3.
func buff_set(u: BUnit, s: int, up: bool) -> void:
	var b := u.buff(s)
	var nb: int
	if up:
		nb = 3 if b < 3 else 6
	else:
		nb = 0 if b < 4 else 3
	await st.unit_attr_op(u, s, nb, true)


## Knock-back 0x411072 with flag 1 (突破攻击, or the 必杀 驱逐): the target moves one cell away from the attacker's
## cell when that cell is on the map, empty and passable for it (not in 围攻, not dead / confused); [0x500ad3] = 1
## during the move (0x4594ea).
func _knock_back(t: BUnit, a: BUnit) -> bool:
	if Rules.forced(0x16) == 0 and a.eff(0x61, 0x35, 1, 1) == 0:
		return false
	if Rules.attack_mode() == 1 or dead_or_confused(t) != 0:
		return false
	var cell := t.pos + Vector2i(signi(t.pos.x - a.pos.x), signi(t.pos.y - a.pos.y))
	if not Rules.in_map(cell) or Rules.slot_at(cell) != 0xff:
		return false
	if Rules.move_cost(t, Rules.terrain_at(cell)) >= 0xfe:
		return false
	Mem.w8(Rules.FORCED_MOVE, 1)
	var cp := Mem.r16(BattleStage.CUR_PERSON)
	if t.node and not Game.autoplay:
		var tw := t.node.create_tween()
		tw.tween_property(t.node, "position", st.view.cell_pos(cell), 0.15)
		await tw.finished
	t.pos = cell
	Mem.w8(Rules.FORCED_MOVE, 0)
	face(t, a.pos)
	Mem.w16(BattleStage.CUR_PERSON, cp)
	st.refresh_units()
	return true


## 0x4111a5 after a knock-back with area targets: if the primary target is still in range the area is rebuilt
## around its new cell, otherwise the strike counter becomes 1 (no second strike).
func _retarget(c: Combat) -> void:
	var prim: BUnit = c.targets[0]
	if in_range(c.a, Rules.attack_codes(c.a), prim):
		c.targets = Rules.attack_targets(c.a, prim)
		c.resize(c.targets.size())
		_sync(c)
	else:
		Mem.w8(STRIKES, 1)


## PostExchange 0x406b3c: (not for a thrown item) 反弹伤害 (never lethal), 吸血 / 嗜血 on the primary damage,
## 吸收金钱; the attacker's result panel (EXP shown for slots < 16), its HP, EXP and weapon EXP.
func _post_exchange(c: Combat) -> void:
	var a := c.a
	var loss := 0
	var new_hp := a.hp
	if Mem.r8(Rules.ITEM_MODE) != 2:
		loss = _reflect(c)
		new_hp = a.hp - loss
		var p := Rules.forced(0x14)
		if p == 0:
			p = a.eff(0x14, 0x65, 1, 0)
		if p != 0:
			var heal := Rules.pct(mini(p & 0xff, 100), Mem.r32(PRIMARY_DMG))
			new_hp = mini(heal + new_hp, a.max_hp())
			loss = a.hp - new_hp
		if a.eff(0x15, 0x5b, 1, 1) != 0 and not c.targets.is_empty():
			var g := Mem.r32(PRIMARY_DMG)
			if c.targets[0].kind < 2:
				Game.gold = Rules.sat_sub(Game.gold, g)
			else:
				Game.gold = mini(Game.gold + g, 999999)
	await _panel(a, 0x100, loss, 0, c.exp if a.slot <= 0xf else 0, c.wexp, 0)
	if loss != 0:
		a.hp = new_hp
	await set_exp(a, c.exp)
	await equip_exp(a, 0, c.wexp)
	Mem.w32(PRIMARY_DMG, 0)
	Mem.w8(Rules.WALKED, 0)


## 反弹伤害 0x440e06: Σ dmg_i·Q(T_i, 0x13, 0x42) %, at most the attacker's HP − 1 (the last strike's values).
func _reflect(c: Combat) -> int:
	var r := 0
	for i in c.targets.size():
		if c.dmg[i] == 0:
			continue
		var v: int = c.targets[i].eff(0x13, 0x42, 1, 0)
		if v != 0:
			r += Rules.pct(v, c.dmg[i])
	if c.a.hp <= r:
		r = maxi(c.a.hp - 1, 0)
	return r


## Counter 0x406453: the primary target answers (depth 1; depth 2 only with its 反击后反击) unless it is dead or
## confused or the striker has 无反击攻击 — when the striker is in its counter range (策略反击's strategy range when
## castable, else the attack range); a cast 策略反击 ends the chain (0x417941), else an exchange.
func _counter(c: Combat) -> void:
	var t: BUnit = c.targets[0]
	var x := c.a
	Mem.w8(Rules.COMBAT + 1, t.slot)
	var d := Mem.r32(Rules.COUNTER_DEPTH)
	if d < 2 and (d == 0 or t.eff(0x25, 0x30, 1, 1) != 0) and dead_or_confused(t) == 0 \
			and x.eff(0x26, 0x34, 1, 1) == 0:
		var v := t.eff(0x5f, 0x79, 1, 0) & 0xff
		var codes: Array
		if v != 0 and Rules.can_cast(t, v - 1):
			codes = [Rules.strat_range(t, v - 1), 0xff, 0xff, 0xff]
		else:
			codes = Rules.attack_codes(t)
		if in_range(t, codes, x):
			Mem.w32(Rules.COUNTER_DEPTH, d + 1)
			Mem.w8(COUNTER_FLAG, d + 1)
			turn(t, x)
			if v != 0 and Rules.can_cast(t, v - 1) and await st.strategy.cast_at(t, x, v - 1):
				Mem.w32(Rules.COUNTER_DEPTH, 0)
				return
			await exchange(t, x)
			return
	Mem.w32(Rules.COUNTER_DEPTH, 0)


# ------------------------------------------------------------------ follow-ups and support attacks
## FollowUp 0x42c144: 奋战; if it did nothing and the target fell, 引导. Returns the last unit 引导 attacked (the
## support attacks' victim; 0x4212f1 leaves it in ECX) or null.
func follow_up(a: BUnit, t: BUnit) -> BUnit:
	if await _fervent(a, t):
		return null
	if t.hp == 0:
		return await _lead(a)
	return null


## The hostile units in A's attack range (0x436499) ordered by 0x419a67: those a preview CalcDamage would kill
## first, then the rest, each group in collection order.
func _target_list(a: BUnit) -> Array[BUnit]:
	var lst := Rules.collect(a, a.pos, Rules.attack_codes(a), 0)
	var kill: Array[BUnit] = []
	for u in lst:
		if u.hp <= Rules.calc_damage(a, u, true, 0)[0]:
			kill.append(u)
	if kill.is_empty():
		return lst
	for u in lst:
		if not kill.has(u):
			kill.append(u)
	return kill


## 奋战攻击 0x4363f1 (or the 必杀 血戰): exchanges with every other enemy in range — at most 2 (no limit for 血戰) —
## stopping when A falls or is confused. True when it ran (A alive and not confused).
func _fervent(a: BUnit, t: BUnit) -> bool:
	if dead_or_confused(a) != 0:
		return false
	var k := Rules.skill_id()
	if Rules.forced(0x17) == 0 and (a.eff(0x17, 0x36, 1, 0) & 0xff) == 0:
		return false
	var n := 0
	for u in _target_list(a):
		if u == t:
			continue
		turn(a, u)
		await exchange(a, u)
		n += 1
		if k != 0x17 and n > 1:
			break
		if dead_or_confused(a) != 0:
			break
	return true


## 引导攻击 0x4212f1: after a kill, exchanges with the enemies in range, at most 2, stopping when one survives.
func _lead(a: BUnit) -> BUnit:
	if a.eff(0x18, 0x36, 1, 1) == 0:
		return null
	var last: BUnit = null
	var n := 0
	for u in _target_list(a):
		turn(a, u)
		await exchange(a, u)
		last = u
		n += 1
		if n >= 2 or u.hp != 0:
			break
	return last


## SupportAttacks 0x4223a9: 同仇敌忾 (the attacker's allies strike the victim), then 戮力同心 (the victim's allies
## strike the attacker).
func support_attacks(victim: BUnit, a: BUnit) -> void:
	await _support(0, victim, a)
	await _support(1, a, victim)


## 0x438ebd(kind, victim, other): nothing for a fallen victim or with byte EV 4087; joiners = units ≠ other on the
## map on other's side (0x42e2b7 without EV 4019), not dead / confused, below their count +0x23, with the victim in
## their attack range; then 0x41058d: mode word 0, each joiner turns, count + 1, Preempt and an exchange, until the
## victim falls.
func _support(kind: int, victim: BUnit, other: BUnit) -> void:
	if victim == null or other == null or victim.hp == 0 or Rules.evb(4087) != 0:
		return
	var joiners: Array[BUnit] = []
	for u: BUnit in st.units:
		if u == other or u.state != 2 or u.side() != other.side() or dead_or_confused(u) != 0:
			continue
		var v := (u.eff(0x71, 0x58, 1, 0) if kind else u.eff(0x3b, 0x1f, 1, 0)) & 0xff
		if v == 0 or u.byte(0x23) >= v:
			continue
		if Rules.collect(u, u.pos, Rules.attack_codes(u), 2).has(victim):
			joiners.append(u)
	if joiners.is_empty():
		return
	Rules.set_attack_mode(0)
	for u in joiners:
		turn(u, victim)
		u.set_byte(0x23, u.byte(0x23) + 1)
		var pre := await preempt(victim, u)
		if pre != 0xff:
			if pre != 0:
				await exchange(victim, u)
			else:
				await exchange(u, victim)
		if victim.hp == 0:
			break


# ------------------------------------------------------------------ 必杀 (§1.13)
## 0x417a96: SE 5, the 必杀's name (0x41e918, style-2 box); k = 1..6 raises the user's buff k − 1, k = 7 applies
## result code 0x57 (爆发 / 士气 / 攻击 / 防御 up) through the strategy result applier (0x429b67).
func _bisha_message(a: BUnit) -> void:
	_se(5)
	var k := Rules.skill_id()
	await _msg(str(Rules.skill(k).get("name", "")))
	if k >= 1 and k <= 6:
		await buff_set(a, k - 1, true)
	elif k == 7:
		await _result_code(a, 0x57)


## 0x429b67(u) with code c: strategy context 0x4251e1(c, u), u as the only target with code c, applier 0x42269c.
func _result_code(u: BUnit, code: int) -> void:
	var sg := st.strategy
	if not (sg.has_method("_init_ctx") and sg.has_method("_results")):
		return
	sg.call("_init_ctx", code, u)
	Mem.w8(Rules.STRAT_CTX + 0xd, u.slot)
	Mem.w8(Rules.STRAT_CTX + 0x401, code)
	await sg.call("_results")


## A 必杀 attack with the id already in the attack-mode word. Player-controlled user — the 武将技 command 0x423358:
## message, Attack without preemption (with FollowUp and SupportAttacks), SP spent. AI — 0x465fab: message,
## exchange, FollowUp, SP spent, mode 0, then (0x43aaf7) SupportAttacks. The user has acted; last action 5.
func bisha_attack(a: BUnit, t: BUnit) -> void:
	var k := Rules.skill_id()
	await _bisha_message(a)
	if a.ai == 7:
		await attack(a, t, false)
		Rules.spend_sp(a.pid, k)
		Rules.set_attack_mode(0)
	else:
		await exchange(a, t)
		var led: BUnit = await follow_up(a, t)
		Rules.spend_sp(a.pid, k)
		Rules.set_attack_mode(0)
		await support_attacks(led if led != null else t, a)
	a.flags = a.flags | 6
	Mem.w8(LAST_ACTION, 5)
	st.refresh_units()


# ------------------------------------------------------------------ 围攻 (§1.14)
## SiegeHelpers 0x405bf2 → 0x416e53: units on the 8 cells around the target (up, right, down, left, diagonals) on
## the attacker's side, family row-7 byte 0, AI units only below EV 4061 SP, not acted, not confused, whose range
## shape class (0x40ae26, table 0x43784a) fits the cell; written to 0x500e9d. Every family has row-7 byte 1 in the
## shipped data, so nobody qualifies.
func siege_helpers(a: BUnit, t: BUnit, collect_all := true) -> Array[BUnit]:
	var out: Array[BUnit] = []
	for i in 8:
		Mem.w8(SIEGE_LIST + i, 0xff)
	for k in 8:
		var h := Rules.unit_at(t.pos + Rules.DIR8[k])
		if h == null or h == a or h.side() != a.side():
			continue
		if Rules.fam_attr(7, h.family()) != 0:
			continue
		if h.ai != 7 and h.person.sp >= Rules.evb(4061):
			continue
		if (h.flags & 2) or h.confused():
			continue
		var cls := _shape_class(h)
		if cls == 0xff or (cls != 2 and cls != (k >> 2)):
			continue
		Mem.w8(SIEGE_LIST + out.size(), h.slot)
		out.append(h)
		if not collect_all:
			break
	return out


## 0x40ae26: the range shape class of the unit's attack codes (table 0x43784a: 0 orthogonal, 1 diagonal, 2 both).
func _shape_class(u: BUnit) -> int:
	var cls := 0xff
	for cv: int in Rules.attack_codes(u):
		if cv == 0xff or cv > 32:
			continue
		var v := Mem.r8(0x43784a + cv)
		if v == 0xff:
			continue
		if v == 2:
			return 2
		cls &= v
	return cls


## CanSiege 0x419d74: some attackable target has a helper.
func can_siege(a: BUnit) -> bool:
	for t in Rules.collect(a, a.pos, Rules.attack_codes(a), 0):
		if not siege_helpers(a, t, false).is_empty():
			return true
	return false


## The 围攻 command 0x41d693 after the target choice (the callers show 不能围攻该部队 when there is no helper):
## 0x417c67, SupportAttacks against the unit 引导 last attacked (else the target), the initiator has acted.
func siege_command(a: BUnit, t: BUnit, helpers: Array = []) -> bool:
	var hs: Array[BUnit] = []
	for h in helpers:
		hs.append(h if h is BUnit else st.units[int(h)])
	if hs.is_empty():
		hs = siege_helpers(a, t, true)
	else:
		for i in 8:
			Mem.w8(SIEGE_LIST + i, hs[i].slot if i < hs.size() else 0xff)
	if hs.is_empty():
		Rules.set_attack_mode(0)
		return false
	Rules.set_attack_mode(1)
	var led := await _siege(t, a, hs)
	await support_attacks(led if led != null else t, a)
	a.flags = a.flags | 6
	Rules.set_attack_mode(0)
	st.refresh_units()
	return true


## 0x417c67: SE 5, "围攻", mode 1; the initiator and then each helper attack (0x417bf2) until the target falls
## (then 引导 for the last striker); a helper has acted after its blow; if the target survives everyone it counters
## the initiator once (unless it struck first); 0x500e9c = helpers that attacked, last action 6.
func _siege(t: BUnit, a: BUnit, helpers: Array[BUnit]) -> BUnit:
	_se(5)
	await _msg("围攻")
	Rules.set_attack_mode(1)
	await _siege_strike(a, t)
	var cnt := 0
	var last := a
	var led: BUnit = null
	while true:
		if t.hp == 0:
			Mem.w8(SIEGE_LIST + cnt, 0xff)
			Rules.set_attack_mode(0)
			Mem.w8(Rules.COMBAT, a.slot)
			led = await _lead(last)
			break
		if cnt != 0:
			last.flags = last.flags | 6
		if cnt == helpers.size():
			Rules.set_attack_mode(0)
			last = a
			if Mem.r8(SIEGE_PRE) == 0:
				var c := Combat.new()
				c.a = a
				c.targets = [t]
				Mem.w8(Rules.COMBAT, a.slot)
				await _counter(c)
			break
		var h: BUnit = helpers[cnt]
		await _siege_strike(h, t)
		cnt += 1
		last = h
	last.flags = last.flags | 6
	Mem.w8(SIEGE_N, cnt)
	Mem.w8(LAST_ACTION, 6)
	return led


## 0x417bf2: one 围攻 blow with the 先手 check: a preempting target strikes first; the striker then attacks unless it
## fell (removed from the map) or is confused.
func _siege_strike(x: BUnit, t: BUnit) -> void:
	if dead_or_confused(x) != 0:
		return
	var pre := await preempt(t, x)
	if pre == 0xff:
		return
	if pre == 0:
		Mem.w8(SIEGE_PRE, 0)
	else:
		Mem.w8(SIEGE_PRE, 1)
		await exchange(t, x)
		var dc := dead_or_confused(x)
		if dc != 0:
			if dc != BUnit.ST_CONFUSION:
				await st.remove_unit(x, false, false)
			return
	await exchange(x, t)


# ------------------------------------------------------------------ EXP (§5)
## AttackExp 0x4037a3 for target i: a kill (damage ≥ HP; a living target also runs the kill hook) gives a player
## attacker 48 against the battle's boss (reader +0x3d06), else 64 / (max(La − Lt, 0) + 2), and +1 功勋 in every
## stat (0x42a9c4); every strike adds 2·clamp(Lt − La, −1, 47) + 6; through ExpMod. Non-player attackers get 0.
func _phys_exp(c: Combat, i: int) -> int:
	var a := c.a
	var t: BUnit = c.targets[i]
	var la := a.person.level
	var lt := t.person.level
	var e := 0
	if t.hp <= c.dmg[i]:
		if t.hp != 0:
			kill_hook(a, c.player)
		if not c.player:
			return 0
		for s in 5:
			st._merit_gain(a, s, 1)
		if t.pid == Mem.r16(BattleStage.READER + 0x3d06):
			e = 0x30
		else:
			e = 64 / ((maxi(s8(la - lt), 0) + 2) & 0xff)
	if not c.player:
		return 0
	var d := clampi(s8(lt - la), -1, 47)
	return exp_mod(a, e + d * 2 + 6, true, a.slot)


## Kill hook 0x4290c8: 大杀四方 restore pending (+0x24 bit 7) while the count is below its value; a player
## attacker's kill count + 1 (0x426ba0, not in 練武場).
func kill_hook(a: BUnit, player: bool) -> void:
	var v := a.eff(0x40, 0x54, 1, 0) & 0xff
	if v != 0 and a.byte(0x24) < v:
		a.set_byte(0x24, a.byte(0x24) | 0x80)
	if player and Rules.evb(4087) == 0:
		a.person.kills = (a.person.kills + 1) & 0xffff


## ExpMod 0x42104f: v·(100 + EXP bonus) %; then for equipment EXP always, for person EXP only with byte EV 4079
## (0x403d5a): ×2 with 精进 (0x42545f(slot)), ×2 more in 围攻.
func exp_mod(u: BUnit, v: int, is_person: bool, slot: int) -> int:
	v = Rules.pct(v, 100 + (u.person.equip_bonus(8) & 0xff))
	if not is_person or Rules.evb(4079) != 0:
		if slot >= 0 and slot < 250 and Mem.r8(0x501b00 + slot) != 0 and st.units[slot].kind == 0:
			v <<= 1
		if Rules.attack_mode() == 1:
			v <<= 1
	return v


## EquipExpEnabled 0x403262.
static func equip_exp_enabled() -> bool:
	return Rules.evb(4087) == 0 or Mem.r8(0x4ce24b) == 1 or Mem.r8(0x500af1) == 1


## WeaponExp 0x403870: a player attacker whose weapon raises 攻击 (or 精神 / both, or has effect 0x18): 3 on damage
## (2 against a lower level), +1 critical; 1 on a miss.
func _weapon_exp(c: Combat, i: int) -> int:
	if not equip_exp_enabled() or not c.player:
		return 0
	var p := c.a.person
	var w := Mem.r8(p.base + 0x2e)
	if w == 0xff:
		return 0
	var it := Game.item(w)
	var stt := Person.stat_of_type(int(it.get("type", 0)))
	var sp: Variant = it.get("special")
	if not (stt == 0 or stt == 10 or (sp != null and int(sp) == 0x18)):
		return 0
	var v := 1
	if c.dmg[i] != 0 or c.mp[i] != 0:
		v = 3
		if c.targets[i].person.level < p.level:
			v -= 1
		if c.crit:
			v += 1
	return exp_mod(c.a, v, false, c.a.slot)


## ArmourExp 0x403a8a: a target of the player's army (0x43ff54): 4 when struck (3 by a lower-level attacker), 1 on a
## miss.
func _armour_exp(c: Combat, i: int) -> int:
	if not equip_exp_enabled():
		return 0
	var t: BUnit = c.targets[i]
	if t.kind != 0:
		return 0
	var v := 4
	if c.dmg[i] == 0 and c.mp[i] == 0:
		v = 1
	elif c.a.person.level < t.person.level:
		v = 3
	return exp_mod(t, v, false, t.slot)


## SetExp 0x4088cd(person, exp + add, show): every 100 points a LevelUp 0x4073f3 with its window.
func set_exp(u: BUnit, add: int) -> void:
	var p := u.person
	if p == null or add <= 0 or p.level >= 100:
		return
	var lv0 := p.level
	var gains: Array = p.add_exp(add)
	for k in gains.size():
		await _level_window(u, lv0 + k + 1, gains[k])
	st.refresh_units()


func gain_exp(u: BUnit, add: int) -> void:
	await set_exp(u, add)


## LevelUp's window part (0x4073f3, show = 1): the unit's action 11 in a battle, SE 0xb, "%s升为%u级" (0x44cfc8:
## with option 0x501a71 the seven gains in the 确认 dialog, else the style-2 box), then the strategies learned at
## this level (class table or the person list 0x507800: "学会了策略「%s」！") and, unless byte EV 4059 = 1, the 必杀
## whose learner slot names this person and level ("领悟必杀技「%s」！").
func _level_window(u: BUnit, lv: int, g: Array) -> void:
	var p := u.person
	if u.state == 2:
		await unit_pose(u, 11)
	_se(0xb)
	var t := "%s升为%d级" % [p.name, lv]
	if Mem.r8(LEVEL_DETAIL) != 0:
		t += "\n"
		for i in 7:
			var v := int(g[i])
			t += "\n%s%s %d" % [LEVEL_LABELS[i], "减少了" if v < 0 else "增加了", absi(v)]
		await _msg(t, 0)
	else:
		await _msg(t)
	for s in 0x90:
		var ll: Dictionary = Rules.strat(s).get("learn_level_by_class", {})
		var hit := int(ll.get(str(p.cls), 0)) == lv
		if not hit:
			var e := Effects.stream_find(Effects.LEARN, s, p.id, 0)
			hit = e >= 0 and Mem.r8(e) == lv
		if hit:
			await _msg("学会了策略「%s」！" % str(Rules.strat(s).get("name", "")))
	if Rules.evb(4059) != 1:
		var base := Mem.r32(0x500c37)
		for k in 0x1b:
			for j in 5:
				var a := base + 16 * k + 3 * j
				if Mem.r16(a) == p.id and Mem.r8(a + 2) == lv:
					await _msg("领悟必杀技「%s」！" % str(Rules.skill(k).get("name", "")))
					break
	if u.node and is_instance_valid(u.node):
		u.node.set_pose(UnitSprite.Pose.STAND, u.dir)


## Equipment EXP 0x4082dd(person, slot 0 weapon / 1 armour, add); each level gained shows 0x4083f9 in a battle: the
## unit's action 12, then (weapon) 7, 1 or (armour) 2, 0, 2 ticks, 2, 0, 1; SE 0xd; "武器等级上升！" / "护具等级上升！".
func equip_exp(u: BUnit, slot: int, add: int) -> void:
	if add <= 0 or u.pid < 0:
		return
	var n := u.person.equip_exp_add(slot, add)
	for k in n:
		if u.state == 2:
			await unit_pose(u, 12)
			if slot == 0:
				await unit_pose(u, 7)
				await unit_pose(u, 1)
			else:
				await unit_pose(u, 2)
				await unit_pose(u, 0)
				await ticks(2)
				await unit_pose(u, 2)
				await unit_pose(u, 0)
				await unit_pose(u, 1)
		_se(0xd)
		await _msg("武器等级上升！" if slot == 0 else "护具等级上升！")
		if u.node and is_instance_valid(u.node):
			u.node.set_pose(UnitSprite.Pose.STAND, u.dir)


# ------------------------------------------------------------------ items (§4.3 / §4.4)
## Consumable count (0x4202c4: byte 0x493a50 + item id).
static func bag_count(id: int) -> int:
	return Mem.r8(BAG_COUNT + id)


## 0x420299(1): one used (when there is one).
static func bag_take(id: int) -> void:
	var a := BAG_COUNT + id
	if Mem.r8(a) >= 1:
		Mem.w8(a, Mem.r8(a) - 1)


## The item menu filter 0x46708c: not 任务物品 / 合成材料 / 工具物品 / 装备升级 (type − 0x1a in 0x20..0x23); in 練武場
## also not 单挑 (0x17) nor the mine items (0x24..0x28).
static func item_menu_ok(id: int) -> bool:
	var it := Game.item(id)
	if it.is_empty():
		return false
	var k := (int(it.get("type", 0)) - 0x1a) & 0xff
	if k >= 0x20 and k <= 0x23:
		return false
	if Rules.evb(4087) != 0 and (k == 0x17 or (k >= 0x24 and k <= 0x28)):
		return false
	return true


## The consumables the battle item menu lists (0x408e96 scans the counts of ids 0xa0..).
static func battle_items() -> Array[int]:
	var out: Array[int] = []
	for id in range(0xa0, 0x100):
		if bag_count(id) != 0 and item_menu_ok(id):
			out.append(id)
	return out


## Handler index of an item (table 0x44f366 by type); −1 past the handler table 0x44f330 (types 0x35..0x39,
## 0x3a..0x3d, ≥ 0x43 — their slots hold no handler).
static func item_handler(id: int) -> int:
	var t := int(Game.item(id).get("type", 0))
	if t < 0x1a or t > 0x42:
		return -1
	var idx := Mem.r8(0x44f366 + t)
	return idx if idx < 14 else -1


## The item's value word (0x41dd72: value | special_value << 8).
static func item_value(it: Dictionary) -> int:
	return int(it.get("value", 0)) | (int(it.get("special_value", 0)) << 8)


## 0x41c50c(item, target, check): cures need the ailment (any for 恢复状态) when `check`, 增加经验 a level below 100,
## 兵种上升 CanPromote; everything else is usable. The refusal messages are use_item's.
func item_usable(id: int, target: BUnit, check: Variant = 1) -> bool:
	var b := (int(Game.item(id).get("type", 0)) - 0x1a) & 0xff
	if b > 0xd or b < 2:
		return true
	if b < 7:
		if not check:
			return true
		match b:
			2: return target.confused()
			3: return target.poisoned()
			4: return target.paralysed()
			5: return target.sealed()
		return target.status != 0
	if b < 0xc:
		return true
	if b == 0xc:
		return target.person.level < 100
	return target.person.promote_refusal() == ""


## 0x41c50c with check 0 inside the handlers: the 增加经验 refusal "不能再升级了。", the promotion refusals.
func _usable_or_say(id: int, target: BUnit) -> bool:
	if item_usable(id, target, 0):
		return true
	var b := (int(Game.item(id).get("type", 0)) - 0x1a) & 0xff
	if b == 0xc:
		await _msg("不能再升级了。")
	elif b == 0xd:
		await _msg(target.person.promote_refusal())
	return false


## Amount 0x43c44a: the HP / MP / SP missing; value byte 0xff = all of it, else min(missing, value word).
func _amount(it: Dictionary, t: BUnit) -> int:
	var missing := 0
	match int(it.get("type", 0)):
		0x1a: missing = t.max_hp() - t.hp
		0x1b: missing = t.max_mp() - (t.mp & 0xffff)
		0x28: missing = 0xff - t.person.sp
	if int(it.get("value", 0)) == 0xff:
		return missing
	return mini(missing, item_value(it))


## UseItem 0x44f2ac(item, user, target, consume): the handler of the item's type (table 0x44f366 → 0x44f330) on the
## chosen target; a used item is consumed unless its flags have bit 1 (unk_18 & 2) or `consume` is false. Returns
## whether it was used.
func use_item(user: BUnit, id: int, target: BUnit, consume := true) -> bool:
	var it := Game.item(id)
	var idx := item_handler(id)
	if idx < 0 or target == null:
		return false
	Mem.w16(ITEM_CTX, id)
	Mem.w8(ITEM_CTX + 2, user.slot)
	Mem.w8(ITEM_CTX + 3, target.slot)
	var used := false
	var typ := int(it.get("type", 0))
	match idx:
		0, 1:
			if not await _usable_or_say(id, target):
				return false
			var h := _amount(it, target)
			await _use_anim(user, target, 0xff)
			if idx == 0:
				await _panel(target, 0, -h, 0, 0, 0, 0)
				target.hp = target.hp + h
			else:
				h &= 0xffff
				await _panel(target, 0, 0, -h, 0, 0, 0)
				target.mp = (target.mp & 0xffff) + h
			used = true
		2:
			if not await _usable_or_say(id, target):
				return false
			await _use_anim(user, target, 0x2c)
			var mask: int = {0x1c: 8, 0x1d: 0x10, 0x1e: 2, 0x1f: 4, 0x20: 0x1e}.get(typ, 0)
			target.cure(mask)
			used = true
		3:
			used = await _use_fruit(user, target, it)
		4:
			if not await _usable_or_say(id, target):
				return false
			await _use_anim(user, target, 0xff)
			await set_exp(target, item_value(it))
			target.hp = target.max_hp()
			target.mp = target.max_mp()
			used = true
		5:
			if not await _usable_or_say(id, target):
				return false
			await _use_anim(user, target, 0xff)
			await promote_unit(target)
			used = true
		6:
			await _use_anim(user, target, 0xff)
			var g := Rules.add_sp(target.pid, _amount(it, target), true)
			await _panel(target, g, 0, 0, 0, 0, 0)
			used = true
		7:
			used = await _use_merit_item(user, target, it)
		8:
			used = await _use_duel_item(user, target, it)
		9:
			if typ == 0x32:
				var s := (int(it.get("value", 0)) - 1) & 0xff
				Effects.stream_put(Effects.LEARN, s, target.pid, [1], false)
				await _use_anim(user, target, 0xff)
				_se(0x11)
				await _msg("学会了策略「%s」！" % str(Rules.strat(s).get("name", "")))
				used = true
			else:
				Mem.w8(0x500fcc, Mem.r8(0x500fcc) + 1)
				st.strategy.item_value = item_value(it)
				used = await st.strategy.cast(int(it.get("value", 0)) - 1, user, target.pos)
				Mem.w8(0x500fcc, 0)
		10:
			if typ == 0x41:
				used = await thrown_attack(user, id, target.pos)
		13:
			await _use_anim(user, target, 0xff)
			Effects.added_set(target.pid, int(it.get("value", 0)), int(it.get("special_value", 0)),
				int(it.get("growth", 0)), true)
			_se(0x11)
			used = true
	if used:
		if consume and (int(it.get("unk_18", 0)) & 2) == 0:
			bag_take(id)
		st.refresh_units()
	return used


## Handler 10 (0x41268e) on its own target: 0x41 thrown at the chosen cell (byte 0x500ad7 = 1 during the pick), the
## mine items 0x3e / 0x3f / 0x40 at the chosen cell and the 探雷器 0x42 around the user (0x500ad7 = 2; Mines); used
## items are consumed as 0x44f2ac does (not with item flag 2).
func use_item_at(user: BUnit, id: int, cell: Vector2i) -> bool:
	var it := Game.item(id)
	var used := false
	match int(it.get("type", 0)):
		0x41:
			used = await thrown_attack(user, id, cell)
		0x42:
			await Mines.detect(st, user)
			used = true
		0x3e, 0x3f, 0x40:
			used = await Mines.use_at(st, user, id, cell)
	Mem.w8(Rules.STRAT_ITEM, 0)
	if used and (int(it.get("unk_18", 0)) & 2) == 0:
		bag_take(id)
	st.refresh_units()
	return used


## The use animation 0x41c74d: the item over the user (5 ticks), SE 0x29, then over the target (10 ticks), then the
## result Meff on the target's cell (0xff none).
func _use_anim(user: BUnit, target: BUnit, eff: int) -> void:
	_se(0x29)
	if Game.autoplay:
		return
	await ticks(15)
	if eff != 0xff:
		await st.strategy.play_cell_effect(eff, target.pos)


## Fruits 0x41d14a: stat word += value (≤ 9999), raw ability += value (0x404df7: ≤ 110; one already beyond stays),
## the stat's buff up (0x43f98e), the fruit's Meff; byte EV 4074 makes the value 0; byte EV 4094 recalculates.
func _use_fruit(user: BUnit, target: BUnit, it: Dictionary) -> bool:
	var s := int(it.get("type", 0)) - 0x21
	if s < 0 or s > 4:
		return false
	var v := item_value(it)
	if Rules.evb(4074) != 0:
		v = 0
	var p := target.person
	var raw := p.get_raw(s)
	p.set_stat_word(s, mini(p.get_stat_word(s) + v, 9999))
	if raw < 110:
		p.set_raw(s, mini(raw + v, 110))
	target.set_buff(s, Rules.buff_step(target.buff(s), true))
	await _use_anim(user, target, FRUIT_MEFF[s])
	if Rules.evb(4094) != 0:
		p.recalc(s)
	return true


## 获得功勋 / HP上升 / MP上升 0x4224d4: persons with a 功勋 store only ("不能在这里使用。"); 功勋[攻击] += value, or the
## base HP / MP word += value (≤ 0xffff) with the 功勋 bonus table 0x508400 (stats 5 / 6); SE 0x11.
func _use_merit_item(user: BUnit, target: BUnit, it: Dictionary) -> bool:
	var store: int = st.merit_store(target.pid) if st.has_method("merit_store") else -1
	if store < 0:
		await _msg("不能在这里使用。")
		return false
	var typ := int(it.get("type", 0))
	var v := item_value(it)
	await _use_anim(user, target, 0xff)
	if typ == 0x29:
		Mem.w16(store, Mem.r16(store) + v)
	else:
		var k := typ - 0x2a
		var wa := target.person.base + 0x1b + 4 * k
		Mem.w16(wa, mini(v + Mem.r16(wa), 0xffff))
		var ba := 0x508400 + 14 * target.pid + 2 * (5 + k)
		Mem.w16(ba, Mem.r16(ba) + v)
	_se(0x11)
	return true


## 单挑 item 0x425e4c: against a hostile unit; value 0 → byte EV 4087 = 1 (练武场 duel), else EV 4083 = value; the
## duel itself is the duel track's (st.item_duel when present).
func _use_duel_item(user: BUnit, target: BUnit, it: Dictionary) -> bool:
	if not target.is_hostile(user) or not st.has_method("item_duel"):
		return false
	var v := int(it.get("value", 0))
	if v == 0:
		Mem.w8(Mem.EV + 4 * 4087, 1)
	else:
		Mem.w8(Mem.EV + 4 * 4083, v)
	await st.call("item_duel", user, target)
	return true


## Promotion 0x41d468: the unit's action 11, class + 1 with the HP / MP gains (Person.promote), HP / MP refilled
## (0x41a0df), SE 0x21, a 10-frame white blend, SE 0xc, "%s的兵种提升为%s！", then the strategies the new class
## knows at the person's level that the old one did not (0x40f082: "学会了「%s」策略！").
func promote_unit(u: BUnit) -> void:
	var p := u.person
	var old_cls := p.cls
	await unit_pose(u, 11)
	p.promote()
	u.hp = u.max_hp()
	u.mp = u.max_mp()
	_se(0x21)
	if u.node and not Game.autoplay:
		for k in 10:
			u.node.flash = k / 10.0
			await ticks(1)
		u.node.flash = 0.0
	_se(0xc)
	st.refresh_units()
	await _msg("%s的兵种提升为%s！" % [p.name, p.class_name_str()])
	for s in 0x60:
		var ll: Dictionary = Rules.strat(s).get("learn_level_by_class", {})
		var lo := int(ll.get(str(old_cls), 0))
		var ln := int(ll.get(str(p.cls), 0))
		if lo == 0 and ln != 0 and ln <= p.level:
			await _msg("学会了「%s」策略！" % str(Rules.strat(s).get("name", "")))
	if u.node and is_instance_valid(u.node):
		u.node.set_pose(UnitSprite.Pose.STAND, u.dir)


## 自动使用 0x416442 → 0x422edf: after damage a surviving unit uses the item Q(T, 0x6c, 0x46) names on itself; a unit
## of the player's army not when it would pass its max HP, and (byte EV 4035 = 0) only from the stock, consumed;
## other units for free.
func auto_use(u: BUnit, _attacker: BUnit = null) -> void:
	var id := u.eff(0x6c, 0x46, 1, 0) & 0xff
	if id == 0:
		return
	var it := Game.item(id)
	if it.is_empty():
		return
	if u.kind == 0 and u.max_hp() < u.hp + item_value(it):
		return
	var consume := false
	if Rules.evb(4035) == 0 and u.kind == 0:
		if bag_count(id) == 0:
			return
		consume = true
	await use_item(u, id, u, consume)


## Thrown attack items (type 0x41: byte 0x500ad7 = 1, 0x404b46 with [0x500c44] = 2): no hit roll; the unit on the
## cell takes the value, the area units (code item +0x17) 0x407398's share [G: max(1, value·max(50, 100 − 10·d)
## / 100), d = distance]; capped at the HP, +24 EXP per hostile unit whose HP was below it; then the AttackExp of
## every target, the animation, Apply and PostExchange (without reflect / 吸血 / gold).
func thrown_attack(user: BUnit, id: int, cell: Vector2i) -> bool:
	var it := Game.item(id)
	var val := item_value(it)
	var c := Combat.new()
	c.a = user
	c.player = user.kind == 0
	var prim := Rules.unit_at(cell)
	if prim != null and prim.hp > 0:
		c.targets.append(prim)
	for p in Rules.area_cells(int(it.get("growth", 0)), cell, user.pos):
		var o := Rules.unit_at(p)
		if o != null and o.hp > 0 and not c.targets.has(o):
			c.targets.append(o)
	if c.targets.is_empty():
		return false
	Mem.w8(Rules.STRAT_ITEM, 1)
	Mem.w8(Rules.ITEM_MODE, 2)
	st.strategy.item_value = val
	face(user, cell)
	_sync(c)
	var n := c.targets.size()
	c.resize(n)
	for i in n:
		var t: BUnit = c.targets[i]
		var d := val
		if t.pos != cell:
			var ring := absi(t.pos.x - cell.x) + absi(t.pos.y - cell.y)
			d = maxi(1, val * maxi(50, 100 - 10 * ring) / 100)
		if t.hp < d:
			d = t.hp
			if t.kind > 1:
				c.exp += 24
		c.dmg[i] = d
		c.raw[i] = d
		c.mp[i] = 0
		c.aexp[i] = 0
	for i in n:
		c.exp = maxi(c.exp, _phys_exp(c, i))
	await _animate(c)
	await _apply(c)
	await _post_exchange(c)
	Mem.w8(Rules.ITEM_MODE, 0)
	Mem.w8(Rules.STRAT_ITEM, 0)
	return true


# ------------------------------------------------------------------ presentation
## Sound kind of the attacker (0x403d19: family table 0x4d2110; 2 for an item used as a strategy on modern-war
## maps).
func _sound_kind(a: BUnit) -> int:
	if Mem.r8(Rules.STRAT_ITEM) == 1 and Rules.evb(4093) == 1:
		return 2
	var f := a.family()
	return Mem.r8(0x4d2110 + f) if f < 40 else 0


## Bow flag of the attacker's family (0x43fff4, table 0x4d2160).
func _bow(a: BUnit) -> int:
	var f := a.family()
	return Mem.r8(0x4d2160 + f) if f < 40 else 0


## The strike animation 0x4526e7: the view on the attacker, the critical line (chance(25) — drawn even when skipped,
## the RNG stream needs it; generic lines draw rand(3)), then 0x404388 unless 跳过战斗过程: attack frames 0..3 (2, 6,
## 4 or 12 for bows, 1 ticks; the swing SE of 0x4040b2; a critical flashes white with SE 0x21), the primary target's
## reaction — at 0 HP SE 7, a miss defends (SE 0x1e / 0x1f critical), a hit turns red (SE 0x23 / 0x24); sound kinds
## ≥ 2 use kind + 0x38 — and the damage number.
func _animate(c: Combat) -> void:
	if c.targets.is_empty():
		return
	var a := c.a
	var t: BUnit = c.targets[0]
	Mem.w8(Rules.COMBAT + 1, t.slot)
	var shown := st.view != null and not Game.autoplay
	if shown and Rules.evb(4087) == 0:
		await st.view.ensure_visible(a.pos)
	if c.crit and Mem.r8(NO_CRIT_LINE) == 0 and Rules.chance(25):
		var line := _crit_line(a)
		if line != "" and shown:
			await st.battle_talk(a.pid, line)
	if Mem.r8(SKIP_ANIM) != 0 or not shown:
		return
	var k := _sound_kind(a)
	var bow := _bow(a)
	var tdir := t.dir
	turn(t, a)
	var n := a.node
	var tn := t.node
	if n:
		n.attack_frame(a.dir, 0)
	await ticks(2)
	var sw := 0x22
	if k != 0:
		if k < 3 and bow == 0:
			sw = 0x20
		elif k < 3 and k != 2:
			sw = 0x25
		else:
			sw = k + 0x31
	_se(sw)
	if n:
		n.attack_frame(a.dir, 1)
	await ticks(6)
	if n:
		n.attack_frame(a.dir, 2)
	if c.crit and n:
		_se(0x21)
		for i in 8:
			n.flash = i * 0.1
			await ticks(1)
		n.flash = 0.0
	await ticks(12 if bow != 0 else 4)
	if n:
		n.attack_frame(a.dir, 3)
	await ticks(1)
	if t.hp == 0:
		_se(7 if k < 2 else k + 0x38)
	elif c.dmg[0] == 0 and c.mp[0] == 0:
		if tn:
			tn.set_pose(UnitSprite.Pose.DEFEND, t.dir)
		_se((0x1f if c.crit else 0x1e) if k < 2 else k + 0x38)
	else:
		if tn:
			tn.set_pose(UnitSprite.Pose.HURT, t.dir)
			tn.tint = Color(1, 0, 0, (0x50 if c.crit else 0x28) / 255.0)
		_se((0x24 if c.crit else 0x23) if k < 2 else k + 0x38)
	await ticks(3)
	if c.dmg[0] != 0:
		st.hud.popup_number(str(c.dmg[0]), t.pos, Color(1, 0.3, 0.2) if c.crit else Color(1, 1, 1))
	elif c.mp[0] != 0:
		st.hud.popup_number(str(c.mp[0]), t.pos, Color(0.5, 0.6, 1))
	await ticks(8)
	if tn and is_instance_valid(tn):
		tn.tint = Color(0, 0, 0, 0)
		tn.set_pose(UnitSprite.Pose.STAND, tdir)
	_set_dir(t, tdir)
	if n and is_instance_valid(n):
		n.set_pose(UnitSprite.Pose.STAND, a.dir)
	await ticks(3)


## Critical line 0x40c099: persons of table 0x48b230 have their own (Imsg 700 + index), others 700 + 0x15 + voice·3
## + rand(3).
func _crit_line(a: BUnit) -> String:
	var i := CRIT_LINE_PERSONS.find(a.pid)
	if i < 0:
		i = a.person.voice * 3 + 0x15 + Rules.rand(3)
	return Game.text(700 + i)


## Retreat animation 0x4419b6 for RemoveUnit: kind 0 (SE 0x10, two blinks of 3 ticks), 1 silent (SE 6, 4 ticks, SE
## 0x11, the frame sinks away in 12 frames), 2 (the protagonist or an explicit animation: the view on the unit, 4
## blinks of 3 ticks and 6 of 1, SE 0x16, a white fade in 11 frames).
func retreat_animation(u: BUnit, silent: bool, anim: bool) -> void:
	var n := u.node
	var kind := 1 if silent else (2 if anim else 0)
	if kind == 0:
		_se(0x10)
	elif kind == 2 and not Game.autoplay and st.view != null:
		await st.view.center_on(u.pos)
	if n == null or Game.autoplay:
		return
	match kind:
		0:
			for k in 2:
				n.visible = false
				await ticks(3)
				n.visible = true
				await ticks(3)
		1:
			_se(6)
			await ticks(4)
			_se(0x11)
			for k in 12:
				n.shrink = (48.0 - 4.0 * k) / 48.0
				await ticks(1)
		2:
			for l in [1, 2]:
				for k in 2 * l + 2:
					n.visible = false
					await ticks(5 - 2 * l)
					n.visible = true
					await ticks(5 - 2 * l)
			_se(0x16)
			for k in 11:
				n.flash = k / 10.0
				await ticks(1)


## Op 0x50's unit actions 0x45778f(unit, person, action, pre, post): pre / post wait 8 ticks (not for actions 0 and
## 11). 0 the standing frame; 1 cheer, 2 defend, 3 hurt, 4 weak (SE 8, held); 5 an attack frame (SE 8); 6 attack
## (SE 7, 4 frames); 7 two attacks (SE 7 each, 2 ticks a frame); 8 looking around (SE 6: right, left, then up,
## down, walking frames of 2 ticks); 9 weak (SE 8, 6 × 8 ticks); 10 hurt with a dim flash (SE 8, 2 + 3 ticks); 11
## turning round (9 still frames down, left, up, right…, 2 ticks) ending in the cheer frame; 12 the same with 3
## ticks.
func unit_pose(u: BUnit, action: int, pre := 0, post := 0) -> void:
	var n := u.node
	if n == null or u.state != 2:
		return
	if pre != 0 and action != 0 and action != 11:
		await ticks(8)
	match action:
		0:
			n.set_pose(UnitSprite.Pose.STAND, u.dir)
		1, 2, 3, 4:
			_se(8)
			n.set_pose([UnitSprite.Pose.CHEER, UnitSprite.Pose.DEFEND, UnitSprite.Pose.HURT,
				UnitSprite.Pose.WEAK][action - 1], u.dir)
		5:
			_se(8)
			n.attack_frame(u.dir, 0)
		6:
			_se(7)
			for f in 4:
				n.attack_frame(u.dir, f)
				await ticks(1)
			n.set_pose(UnitSprite.Pose.STAND, u.dir)
		7:
			for r in 2:
				_se(7)
				for f in 4:
					n.attack_frame(u.dir, f)
					await ticks(2)
			n.set_pose(UnitSprite.Pose.STAND, u.dir)
		8:
			for pair in [[1, 3], [0, 2]]:
				_se(6)
				for d in pair:
					n.set_pose(UnitSprite.Pose.WALK, d)
					await ticks(8)
			n.set_pose(UnitSprite.Pose.STAND, u.dir)
		9:
			_se(8)
			n.set_pose(UnitSprite.Pose.WEAK, u.dir)
			await ticks(48)
		10:
			_se(8)
			n.set_pose(UnitSprite.Pose.HURT, u.dir)
			n.greyed = true
			await ticks(2)
			n.greyed = false
			await ticks(3)
			n.set_pose(UnitSprite.Pose.STAND, u.dir)
		11, 12:
			for k in 9:
				n.set_still([2, 3, 0, 1][k & 3])
				await ticks(2 if action == 11 else 3)
			if action == 11:
				n.set_pose(UnitSprite.Pose.CHEER, u.dir)
			else:
				n.set_pose(UnitSprite.Pose.STAND, u.dir)
	if post != 0 and action != 0 and action != 11:
		await ticks(8)
