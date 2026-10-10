extends Node
## Headless test harness: TEST=res://src/debug/t_xxx.gd godot --headless --path . res://src/debug/test_runner.tscn
func _ready() -> void:
	var path := OS.get_environment("TEST")
	var s: GDScript = load(path)
	var t: Node = s.new()
	add_child(t)
	await t.run()
	get_tree().quit()
