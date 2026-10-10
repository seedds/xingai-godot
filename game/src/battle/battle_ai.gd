class_name BattleAI
extends RefCounted
## The AI (docs/ai.md §2.2, §4). STUB: implemented by the AI track.

var st: BattleStage


func _init(s: BattleStage) -> void:
	st = s


## Action order 0x44da7a.
func compute_order(player_side: bool) -> void:
	var lo := 0 if player_side else 60
	var hi := 59 if player_side else 250
	var n := 0
	for i in range(lo, hi):
		var u := st.units[i]
		u.order = 0xff
		if u.state == 2:
			u.order = n
			n += 1


## AIAct 0x43ad3b.
func act(u: BUnit) -> void:
	pass
