class_name BattleInput
extends RefCounted
## The player phase (docs/ai.md §5). STUB: implemented by the player-phase track.

var st: BattleStage
var idle := false


func _init(s: BattleStage) -> void:
	st = s


## Player input loop 0x44e0d9.
func player_phase(resumed: bool) -> void:
	if Game.autoplay or Game.demo:
		for u in st.units.slice(0, 60):
			if st.battle_finished():
				return
			if u.state == 2 and u.ai == 7 and (u.flags & 2) == 0 and not u.confused():
				st.set_current(u)
				await st.ai.act(u)
				await st.unit_acted(u)
				await st.post_action()
		return
	while not st.battle_finished():
		idle = true
		var r: Array = await st.view.cell_clicked
		idle = false
		if r[1] == MOUSE_BUTTON_RIGHT:
			return


func system_menu() -> void:
	pass
