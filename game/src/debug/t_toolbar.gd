extends Node
## Visual check of the story-scene toolbar: a StoryStage waiting for clicks with 出征 enabled.
func run() -> void:
	Game.new_game_state()
	var ui := GameUI.new()
	# stand-in for main.gd (ScriptHost reads Game.main.ui)
	var gs := GDScript.new()
	gs.source_code = "extends Node\nvar ui\n"
	gs.reload()
	var m := Node.new()
	m.set_script(gs)
	m.name = "Main"
	Game.main = m
	get_tree().root.add_child.call_deferred(m)
	await get_tree().process_frame
	m.set("ui", ui)
	var st := StoryStage.new()
	add_child(st)
	add_child(ui)
	st.bg.texture = Assets.tex("gfx/screens/17.png")
	st.sortie_enabled = true
	st._waiting_click = true
	for k in 5:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(OS.get_environment("OUT"))
