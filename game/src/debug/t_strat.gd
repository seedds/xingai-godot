extends Node
## Superseded by t_strat66 (the 6.6 strategy engine, BattleStrategy); kept so `tools/gtest.sh t_strat` runs it.

func run() -> void:
	var t: Node = load("res://src/debug/t_strat66.gd").new()
	add_child(t)
	await t.run()
