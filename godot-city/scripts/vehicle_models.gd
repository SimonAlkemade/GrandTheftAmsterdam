extends RefCounted
## Procedural vehicle models. Forward is -Z, the origin is on the road under
## the middle of the vehicle. Materials are shared; headlights and the
## destination signs glow more at night through `lights`.

static var _mats := {}
static var lights: Array[StandardMaterial3D] = []


static func mat(key: String, color: Color, rough := 0.5, metal := 0.0, glow := Color.BLACK) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if glow != Color.BLACK:
		m.emission_enabled = true
		m.emission = glow
		m.emission_energy_multiplier = 0.4
		lights.append(m)
	_mats[key] = m
	return m


static func box(parent: Node3D, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var b := BoxMesh.new(); b.size = size
	var mi := MeshInstance3D.new(); mi.mesh = b; mi.material_override = m; mi.position = pos
	parent.add_child(mi)
	return mi


static func wheels(parent: Node3D, half_track: float, axles: Array, r := 0.33) -> void:
	var c := CylinderMesh.new(); c.top_radius = r; c.bottom_radius = r; c.height = 0.26; c.radial_segments = 14
	for z in axles:
		for x in [-half_track, half_track]:
			var mi := MeshInstance3D.new(); mi.mesh = c; mi.material_override = mat("tyre", Color("161718"), 0.9)
			mi.name = "wheel"
			mi.rotation.z = PI / 2; mi.position = Vector3(x, r, z)
			parent.add_child(mi)


static func set_night(night: float) -> void:
	for m in lights:
		m.emission_energy_multiplier = 0.4 + night * 3.5


static func car(color: Color) -> Node3D:
	var n := Node3D.new()
	var paint := mat("paint_%s" % color.to_html(false), color, 0.32, 0.55)
	var glass := mat("glass", Color("0d1418"), 0.08, 0.8)
	box(n, Vector3(1.78, 0.62, 4.15), Vector3(0, 0.62, 0), paint)
	box(n, Vector3(1.6, 0.54, 2.1), Vector3(0, 1.19, 0.25), glass)
	box(n, Vector3(1.5, 0.07, 1.9), Vector3(0, 1.49, 0.28), paint)
	box(n, Vector3(1.82, 0.2, 0.18), Vector3(0, 0.42, -2.08), mat("trim", Color("1a1c1e"), 0.6))
	box(n, Vector3(1.82, 0.2, 0.18), Vector3(0, 0.42, 2.08), mat("trim", Color("1a1c1e"), 0.6))
	for x in [-0.6, 0.6]:
		box(n, Vector3(0.4, 0.13, 0.05), Vector3(x, 0.72, -2.09), mat("headlight", Color("fff6d8"), 0.3, 0.0, Color("fff2c0")))
		box(n, Vector3(0.38, 0.13, 0.05), Vector3(x, 0.74, 2.09), mat("taillight", Color("8a0d0d"), 0.3, 0.0, Color("ff1a1a")))
	wheels(n, 0.86, [-1.32, 1.32])
	return n


# A Canta, the narrow Dutch microcar (blender/make_canta.py), in red.
static var _canta: PackedScene

static func canta(color := Color("9e0b10")) -> Node3D:
	if _canta == null:
		_canta = load("res://models/canta.glb")
	var n: Node3D = _canta.instantiate()
	var body: MeshInstance3D = n.find_child("body", true, false)
	for i in body.mesh.get_surface_count():
		var m := body.mesh.surface_get_material(i)
		if m and m.resource_name.begins_with("paint"):
			body.set_surface_override_material(i, mat("canta_%s" % color.to_html(false), color, 0.3, 0.2))
	return n


## A solid box for a vehicle in traffic, so what you drive can hit it (it moves
## with the vehicle; nothing moves it).
static func solid(n: Node3D, size: Vector3, y: float) -> void:
	var b := AnimatableBody3D.new()
	b.collision_layer = 4               # VehiclePhysics.TRAFFIC_LAYER
	b.collision_mask = 0
	b.sync_to_physics = false
	var s := BoxShape3D.new(); s.size = size
	var cs := CollisionShape3D.new(); cs.shape = s; cs.position.y = y
	b.add_child(cs)
	n.add_child(b)


## Turn a vehicle's wheels (children named wheel_*) for the distance it covered.
static func spin_wheels(n: Node3D, distance: float, radius: float) -> void:
	for w in n.find_children("wheel_*", "", true, false):
		(w as Node3D).rotation.x -= distance / radius


# A GVB city bus: white, with the blue band and a lit destination sign.
static func bus() -> Node3D:
	var n := Node3D.new()
	var white := mat("bus_white", Color("eef0f2"), 0.35, 0.2)
	box(n, Vector3(2.55, 2.75, 12.0), Vector3(0, 1.75, 0), white)
	box(n, Vector3(2.57, 1.05, 10.9), Vector3(0, 2.25, 0.4), mat("glass", Color("0d1418"), 0.08, 0.8))
	box(n, Vector3(2.57, 1.7, 0.06), Vector3(0, 1.95, -6.0), mat("glass", Color("0d1418"), 0.08, 0.8))
	box(n, Vector3(2.57, 0.28, 12.02), Vector3(0, 1.1, 0), mat("gvb_blue", Color("1f3f8f"), 0.4))
	box(n, Vector3(1.9, 0.28, 0.05), Vector3(0, 3.0, -6.03), mat("dest", Color("2a1800"), 0.4, 0.0, Color("ffb020")))
	box(n, Vector3(2.4, 0.12, 11.6), Vector3(0, 3.18, 0), mat("bus_roof", Color("c9ccd0"), 0.6))
	for x in [-0.95, 0.95]:
		box(n, Vector3(0.35, 0.18, 0.05), Vector3(x, 0.75, -6.02), mat("headlight", Color("fff6d8"), 0.3, 0.0, Color("fff2c0")))
	wheels(n, 1.1, [-3.9, 3.2], 0.5)
	return n


# One section of an Amsterdam tram (three make a 30 m 15G).
static func tram_section(length: float, cab: int) -> Node3D:
	var n := Node3D.new()
	var white := mat("tram_white", Color("f2f3f4"), 0.35, 0.15)
	box(n, Vector3(2.4, 2.6, length), Vector3(0, 1.85, 0), white)
	box(n, Vector3(2.42, 1.1, length - 0.6), Vector3(0, 2.25, 0), mat("glass", Color("0d1418"), 0.08, 0.8))
	box(n, Vector3(2.42, 0.45, length), Vector3(0, 0.78, 0), mat("tram_skirt", Color("2e3338"), 0.6))
	box(n, Vector3(2.42, 0.16, length), Vector3(0, 1.12, 0), mat("tram_red", Color("c1272d"), 0.4))
	if cab != 0:                               # sloped cab front with a lit sign
		var z := -cab * length / 2.0
		box(n, Vector3(2.3, 1.6, 0.4), Vector3(0, 2.1, z - cab * 0.15), mat("glass", Color("0d1418"), 0.08, 0.8))
		box(n, Vector3(1.6, 0.3, 0.05), Vector3(0, 3.0, z - cab * 0.36), mat("dest", Color("2a1800"), 0.4, 0.0, Color("ffb020")))
		for x in [-0.8, 0.8]:
			box(n, Vector3(0.3, 0.16, 0.05), Vector3(x, 0.95, z - cab * 0.36), mat("headlight", Color("fff6d8"), 0.3, 0.0, Color("fff2c0")))
	if cab == 0:                               # pantograph on the middle section
		box(n, Vector3(1.6, 0.06, 0.08), Vector3(0, 4.05, 0), mat("panto", Color("2a2c2e"), 0.5, 0.6))
		box(n, Vector3(0.06, 0.9, 0.06), Vector3(0, 3.6, -0.4), mat("panto", Color("2a2c2e"), 0.5, 0.6)).rotation.x = 0.6
	box(n, Vector3(1.8, 0.4, length * 0.9), Vector3(0, 3.25, 0), mat("tram_roof", Color("cfd2d6"), 0.6))
	wheels(n, 0.75, [-length * 0.3, length * 0.3], 0.34)
	return n


static func tram_joint() -> MeshInstance3D:
	var b := BoxMesh.new(); b.size = Vector3(2.2, 2.4, 0.9)
	var mi := MeshInstance3D.new(); mi.mesh = b; mi.material_override = mat("bellows", Color("23272b"), 0.9)
	return mi
