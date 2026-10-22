extends RefCounted
## Every material the city uses, by the names tile_builder.gd gives its
## surfaces. Textures come from textures/ (exported from the web map), with
## mipmaps; windows, shopfronts and lamps glow at night through `glowing`.

const TRIM := ["#d8cfba", "#d8cfba", "#cfc6b0", "#e0d8c4", "#ffffff", "#e9e6df", "#efe7d2"]

var lib := {}
var glowing: Array[StandardMaterial3D] = []


func _tex(name: String) -> Texture2D:
	var path := "res://textures/%s.png" % name
	if not ResourceLoader.exists(path):
		return null
	var img: Image = load(path).get_image()
	if img.is_compressed():
		img.decompress()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _textured(name: String, rough := 0.85, glow := false, normal := false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = _tex(name)
	m.roughness = rough
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if normal:
		var n := _tex(name + "_nrm")
		if n:
			m.normal_enabled = true
			m.normal_texture = n
			m.normal_scale = 0.6
	if glow:
		var g := _tex(name + "_glow")
		if g:
			m.emission_enabled = true
			m.emission = Color.WHITE
			m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY   # ADD would light the whole wall
			m.emission_texture = g
			m.emission_energy_multiplier = 0.0
			glowing.append(m)
	return m


func _plain(c: Color, rough := 0.85, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func build() -> void:
	for i in 7:
		lib["facade_%d" % i] = _textured("facade_%d" % i, 0.82, true, true)
		lib["ground_home_%d" % i] = _textured("ground_home_%d" % i, 0.8, true, true)
		lib["trim_%d" % i] = _plain(Color(TRIM[i]), 0.7)
	for i in 6:
		lib["ground_shop_%d" % i] = _textured("ground_shop_%d" % i, 0.6, true, true)
		lib["ground_shop_%d" % i].set_meta("shop", true)
	lib["office"] = _textured("office", 0.25); lib["office"].metallic = 0.3
	lib["boat"] = _textured("boat", 0.8, true, true)
	for i in 3:
		lib["roof_%d" % i] = _textured("roof_%d" % i)
	lib["roof_flat"] = _textured("roof_flat")
	for k in ["ground", "road", "walk", "plaza", "bridge", "park", "grass", "garden"]:
		lib[k] = _textured(k, 0.95 if k == "road" else 0.85)
		if k in ["plaza", "walk", "ground"]:
			lib[k].albedo_color = Color(0.72, 0.72, 0.72)   # pale stone glares in full sun
	lib["bike"] = _plain(Color("9c3f33"), 0.9)
	lib["tram"] = _plain(Color("5f6266"))
	lib["rail"] = _plain(Color("55504a"))
	lib["rails"] = _plain(Color("2a2c2e"), 0.4, 0.6)
	lib["water"] = _plain(Color("1c3438"), 0.35, 0.0)   # dark and only a little glossy, like canal water
	lib["water"].metallic_specular = 0.12              # it mirrors the sky far less than glass would
	lib["quay"] = _plain(Color("cfc6b2"))
	lib["bridge_side"] = _plain(Color("6d3b2c"))
	lib["quay_wall"] = _textured("walk", 0.95)       # stone setts, standing on end
	lib["quay_wall"].albedo_color = Color(0.3, 0.27, 0.24)   # old, darkened stone
	lib["flower"] = _plain(Color("b8607a"))
	lib["play"] = _plain(Color("c7a46a"))
	lib["pitch"] = _plain(Color("4f8d4a"))
	lib["lamp_glass"] = _plain(Color("fff3d0")); lib["lamp_glass"].emission_enabled = true
	lib["lamp_glass"].emission = Color("ffd58a"); lib["lamp_glass"].emission_energy_multiplier = 0.0


func get_mat(name: String) -> Material:
	if not lib.has(name):
		lib[name] = _plain(Color(1, 0, 1))      # loud magenta: a name the builder made up
	return lib[name]


func set_night(night: float) -> void:
	for m in glowing:
		m.emission_energy_multiplier = night * (0.7 if m.has_meta("shop") else 1.4)
	lib["lamp_glass"].emission_energy_multiplier = night * 4.0
