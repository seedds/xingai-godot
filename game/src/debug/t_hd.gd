extends Node2D
## Check the mechanism the HD pack relies on: an ImageTexture with set_size_override() draws a 4x image
## in the original's pixel units (regions, whole-texture draws). Needs a window (reads rendered pixels):
##   cd game && TEST=res://src/debug/t_hd.gd godot --path . res://src/debug/test_runner.tscn
func run() -> void:
	# 2x1 "logical" image stored at 4x: left pixel red, right pixel blue
	var img := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	img.fill_rect(Rect2i(0, 0, 4, 4), Color.RED)
	img.fill_rect(Rect2i(4, 0, 4, 4), Color.BLUE)
	var t := ImageTexture.create_from_image(img)
	t.set_size_override(Vector2i(2, 1))
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	draw.connect(func() -> void:
		draw_texture_rect_region(t, Rect2(0, 0, 100, 100), Rect2(1, 0, 1, 1))   # region: right pixel only
		draw_texture_rect(t, Rect2(100, 0, 100, 50), false))                     # whole texture
	queue_redraw()
	for k in 5:
		await get_tree().process_frame
	var shot := get_viewport().get_texture().get_image()
	shot.resize(640, 480, Image.INTERPOLATE_NEAREST)
	var ok := t.get_size() == Vector2(2, 1) and shot.get_pixel(50, 50).is_equal_approx(Color.BLUE) \
			and shot.get_pixel(120, 25).is_equal_approx(Color.RED) and shot.get_pixel(180, 25).is_equal_approx(Color.BLUE)
	print("t_hd: ", "PASS" if ok else "FAIL size=%s region=%s left=%s right=%s" % [t.get_size(),
			shot.get_pixel(50, 50), shot.get_pixel(120, 25), shot.get_pixel(180, 25)])
