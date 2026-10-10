class_name BattleStrategy
extends RefCounted
## Strategies (策略), 军师技 and turn-start auras (docs/battle.md §2, docs/skills.md §3.4, §5.2).
## STUB: the interface the stage, the AI and the player phase use; implemented by the strategy track.

var st: BattleStage


func _init(s: BattleStage) -> void:
	st = s


## Dispatcher 0x425627: cast strategy s by `caster` with the chosen target cell. Returns true if performed.
func cast(s: int, caster: BUnit, target: Vector2i) -> bool:
	return false


## 0x4179b4: cast s at a unit (策略先手 / 追击 / 反击).
func cast_at(caster: BUnit, target: BUnit, s: int) -> bool:
	return false


## 军师技 (0x467c9e). Returns true if performed.
func family_special(u: BUnit) -> bool:
	return false


## Auras 0x42f8d9 at the unit's side's turn start.
func turn_auras(u: BUnit) -> void:
	pass


func remove_map_object(c: Vector2i) -> void:
	pass


func play_cell_effect(eff: int, c: Vector2i) -> void:
	pass
