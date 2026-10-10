extends Node
func _ready() -> void:
	var v := BattleView.new()
	add_child(v)
	v.load_map(int(OS.get_environment("MAP_ID")) if OS.get_environment("MAP_ID") != "" else 13)
	var mv := {}
	for y in range(5, 10):
		for x in range(8, 13):
			mv[Vector2i(x, y)] = 1
	v.set_move_cells(mv)
	v.cursor_cell = Vector2i(10, 7)
	v.center_on(Vector2i(10, 7), false)
