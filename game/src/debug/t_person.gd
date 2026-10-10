extends Node
func run() -> void:
	for pid in [0, 1, 2, 3, 59]:
		var p: Person = Game.person(pid)
		print(pid, " ", p.name, " cls=", p.cls, "(", p.class_name_str(), ") lv=", p.level, " hp=", p.max_hp(), " mp=", p.max_mp(), " atk=", p.stat(0), " def=", p.stat(1), " mv=", p.move_points(), " gfx=", p.graphic_id(), " entry=", p.sprite_entry(2), " face=", p.face, " w=", p.weapon, " a=", p.armor)
	var p1: Person = Game.person(1)
	print("levelup gains ", p1.level_up(1), " lv=", p1.level, " atk=", p1.stat(0))
