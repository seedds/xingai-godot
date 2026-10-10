extends Node
## Loads every script under res://src so parse errors show up. Prints "t_parse: N scripts".

func _scan(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), out)


func run() -> void:
	var files: Array = []
	_scan("res://src", files)
	var bad := 0
	for f in files:
		var s: GDScript = load(f)
		if s == null or not s.can_instantiate():
			print("t_parse: cannot load ", f)
			bad += 1
	print("t_parse: %d scripts, %d bad" % [files.size(), bad])
