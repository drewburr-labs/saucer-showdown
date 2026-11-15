extends RefCounted
## Loads the game's art: the SVG sprites in assets/sprites and the fonts in
## assets/fonts.
##
## Sprites are plain SVG files, imported as "keep" so they ship as-is. At load
## time the magenta placeholders (#ff00ff base, #800080 shade, #ff80ff
## highlight) are swapped for a team's colours, and the result is rasterised
## at RS× so it stays sharp when the window is scaled up. Draw them at 1/RS.

const Cfg = preload("res://scripts/sim/config.gd")

const DIR := "res://assets/sprites/"
const RS := 2.0
const BASE := "#ff00ff"
const SHADE := "#800080"
const LIGHT := "#ff80ff"

static var _cache := {}
static var _title: Font
static var _body: Font


## The sprite `name` (file name without .svg), recoloured for `team`, or with
## the placeholders left alone when team is -1.
static func tex(name: String, team: int = -1) -> Texture2D:
	var key := "%s:%d" % [name, team]
	if _cache.has(key):
		return _cache[key]
	var svg := FileAccess.get_file_as_string(DIR + name + ".svg")
	if svg == "":
		push_error("Art: can't read %s%s.svg" % [DIR, name])
	if team >= 0:
		var c: Color = Cfg.TEAM_COLORS[team]
		svg = svg.replace(BASE, "#" + c.to_html(false))
		svg = svg.replace(SHADE, "#" + c.darkened(0.45).to_html(false))
		svg = svg.replace(LIGHT, "#" + c.lightened(0.5).to_html(false))
	var img := Image.new()
	img.load_svg_from_string(svg, RS)
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_cache[key] = t
	return t


## Chunky display face for names, scores and banners.
static func title_font() -> Font:
	if _title == null:
		_title = load("res://assets/fonts/LilitaOne-Regular.ttf")
		_title.fallbacks = [body_font()]
	return _title


## Rounded face for everything else.
static func body_font() -> Font:
	if _body == null:
		var fv := FontVariation.new()
		fv.base_font = load("res://assets/fonts/Fredoka-Variable.ttf")
		var ts := TextServerManager.get_primary_interface()
		fv.variation_opentype = {ts.name_to_tag("wght"): 560}
		_body = fv
	return _body
