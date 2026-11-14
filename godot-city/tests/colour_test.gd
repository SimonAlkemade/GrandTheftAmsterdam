extends SceneTree
## Building colours from the panoramas (pano_colours.py puts "c" in a
## building's record): the house gets the facade style nearest its colour,
## tinted so its upper walls come out as measured (texture x tint), the
## shopfront and roof left as they are; a house without "c" is as before.
##     godot --headless --path godot-city --script tests/colour_test.gd

const TileBuilder := preload("res://scripts/tile_builder.gd")
const Materials := preload("res://scripts/materials.gd")

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


static func _lin(c: Color) -> Color:
	return c.srgb_to_linear()


# The colour a wall comes out (sRGB): its style's wall colour x the vertex
# colour x the material's albedo (all in linear light).
func _seen(style: int, v: Color, mat: StandardMaterial3D) -> Color:
	var w := _lin(TileBuilder.WALL_RGB[style])
	var a := mat.albedo_color.srgb_to_linear()         # (as the renderer reads it)
	var t := v.srgb_to_linear()                        # (the renderer reads vertex colours as sRGB, measured: tests/colour_test.gd)
	return Color(w.r * t.r * a.r, w.g * t.g * a.g, w.b * t.b * a.b).linear_to_srgb()


func _de(a: Color, b: Color) -> float:
	var la := TileBuilder.lab(a); var lb := TileBuilder.lab(b)
	return la.distance_to(lb)


func _house(x: float, c = null) -> Dictionary:
	var bd := {"r": [[x, -1500, x + 80, -1500, x + 80, -1400, x, -1400]], "h": 12.0, "e": 12.0}
	if c != null:
		bd["c"] = c
	return bd


func _run() -> void:
	var mats = Materials.new()
	mats.build()
	for spec in [[[150, 72, 52], "a brick house"], [[46, 84, 62], "a canal-green house"], [[236, 232, 222], "a white house"],
			[[120, 124, 126], "a grey stone house"]]:
		var c := Color8(spec[0][0], spec[0][1], spec[0][2])
		var tb := TileBuilder.new()
		var r: Dictionary = await tb.build_tile({"tile": [0, -1], "size": 375.0, "buildings": [_house(100.0, spec[0])]})
		var facade := ""
		for name in r.surfaces:
			if String(name).begins_with("facade_"): facade = name
		_check(facade != "", "%s: its walls are a facade style" % spec[1])
		if facade == "":
			continue
		var style := int(facade.substr(7))
		_check(style == int(TileBuilder.style_for(c)[0]), "%s: the style that can be brought nearest its colour (%d)" % [spec[1], style])
		var cols: PackedColorArray = r.surfaces[facade][3]
		var seen := _seen(style, cols[0], mats.get_mat(facade))
		_check(_de(seen, c) < 8.0, "%s: its walls come out as measured (dE %.1f: %s for %s)" % [spec[1], _de(seen, c), seen.to_html(false), c.to_html(false)])
		var ground_white := true
		for name in r.surfaces:
			if String(name).begins_with("ground_") or String(name).begins_with("roof"):
				for v in (r.surfaces[name][3] as PackedColorArray):
					if not v.is_equal_approx(Color.WHITE): ground_white = false
		_check(ground_white, "%s: shopfront and roof as they are" % spec[1])
	# Without a measured colour: as before (the style by hash, the walls as the texture).
	var tb := TileBuilder.new()
	var r: Dictionary = await tb.build_tile({"tile": [0, -1], "size": 375.0, "buildings": [_house(100.0)]})
	var plain := true
	for name in r.surfaces:
		if String(name).begins_with("facade_"):
			var style := int(String(name).substr(7))
			var seen := _seen(style, (r.surfaces[name][3] as PackedColorArray)[0], mats.get_mat(name))
			if _de(seen, TileBuilder.WALL_RGB[style]) > 1.0: plain = false
	_check(plain, "a house without a measured colour: its walls as the texture")
	print("colour test: %d failed" % _fails)
	quit(1 if _fails else 0)
