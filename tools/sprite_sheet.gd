extends SceneTree
## Saves every sprite (both team colourings) on one sheet, for reviewing art.
##   godot --headless --path . --script tools/sprite_sheet.gd -- out.png [scale]

const Art = preload("res://scripts/view/art.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://sprites.png"
	var zoom: float = float(args[1]) if args.size() > 1 else 1.0
	var names: Array[String] = []
	for f in DirAccess.get_files_at(Art.DIR):
		if f.ends_with(".svg") and f != "backdrop.svg":
			names.append(f.get_basename())
	var sheet := Image.create(1400, 900, false, Image.FORMAT_RGBA8)
	sheet.fill(Color("3a3f5c"))
	var x := 10
	var y := 10
	var row_h := 0
	for n in names:
		for team in [0, 1]:
			var img := Art.tex(n, team).get_image()
			img.clear_mipmaps()
			if zoom != 1.0:
				img.resize(int(img.get_width() * zoom), int(img.get_height() * zoom))
			if x + img.get_width() > sheet.get_width():
				x = 10
				y += row_h + 10
				row_h = 0
			sheet.blend_rect(img, Rect2i(Vector2i.ZERO, img.get_size()), Vector2i(x, y))
			x += img.get_width() + 10
			row_h = maxi(row_h, img.get_height())
	sheet.save_png(out)
	print("saved ", out)
	quit()
