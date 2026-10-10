class_name BattleActions
extends RefCounted
## Physical attacks, movement, EXP / level-ups, equipment EXP, items, retreats (docs/battle.md §1, §4, §5).
## STUB: the interface the stage, the AI and the player phase use; implemented by the combat track.

var st: BattleStage


func _init(s: BattleStage) -> void:
	st = s


func wait(t: float) -> void:
	if Game.autoplay or t <= 0:
		return
	await st.get_tree().create_timer(t).timeout


## Face 0x412148: same column → down if the cell is below else up; otherwise right / left.
func dir_to(from: Vector2i, to: Vector2i) -> int:
	if to.x == from.x:
		return 2 if to.y > from.y else 0
	return 1 if to.x > from.x else 3


func face(u: BUnit, cell: Vector2i) -> void:
	if cell == u.pos:
		return
	u.dir = dir_to(u.pos, cell)
	if u.node:
		u.node.dir = u.dir
		u.node.queue_redraw()


func can_attack(a: BUnit, b: BUnit) -> bool:
	return Rules.in_attack_range(a, a.pos, b.pos)


## Walk along `path` (cells after the start); false when interrupted (先制攻击).
func move_unit(u: BUnit, path: Array[Vector2i]) -> bool:
	for c in path:
		u.dir = dir_to(u.pos, c)
		u.pos = c
	Mem.w8(Rules.WALKED, path.size())
	if not path.is_empty():
		u.flags = u.flags | 4
	st.refresh_units()
	return true


## The player / AI attack command 0x43db23.
func attack_command(a: BUnit, t: BUnit, check_pre := true) -> void:
	pass


## 必杀 attack (0x423358 / 0x465fab) with the 必杀 id already in the attack-mode word.
func bisha_attack(a: BUnit, t: BUnit) -> void:
	pass


func set_exp(u: BUnit, add: int) -> void:
	u.person.add_exp(add)


func gain_exp(u: BUnit, add: int) -> void:
	await set_exp(u, add)


func equip_exp(u: BUnit, slot: int, add: int) -> void:
	u.person.equip_exp_add(slot, add)


func retreat_animation(u: BUnit, silent: bool, anim: bool) -> void:
	pass


func unit_pose(u: BUnit, action: int) -> void:
	pass


func was_target(u: BUnit) -> bool:
	return false
