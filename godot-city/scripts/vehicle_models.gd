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


# A Dutch police car: white, the blue band and red-orange stripe of the
# Politie livery, POLITIE on the doors and the bonnet, and a light bar whose
# two halves flash (`flash_police`) while it is on a call.
static func police_car() -> Node3D:
	var n := car(Color("f4f5f6"))
	var blue := mat("politie_blue", Color("1a3d8f"), 0.4, 0.2)
	var orange := mat("politie_orange", Color("e5522a"), 0.4, 0.1)
	for x in [-1, 1]:
		box(n, Vector3(0.02, 0.2, 3.9), Vector3(x * 0.9, 0.6, 0), blue)
		box(n, Vector3(0.02, 0.06, 3.9), Vector3(x * 0.9, 0.75, 0), orange)
		sign_text(n, "POLITIE", Vector3(x * 0.915, 0.6, 0.2), x * PI / 2, 1.3, 0.13, Color("ffffff"), true)
	sign_text(n, "POLITIE", Vector3(0, 0.935, -1.4), 0.0, 0.9, 0.12, Color("1a3d8f"), true).rotation = Vector3(-PI / 2, PI, 0)
	box(n, Vector3(1.1, 0.1, 0.32), Vector3(0, 1.57, 0.2), mat("beacon_base", Color("222428"), 0.5))
	box(n, Vector3(0.5, 0.1, 0.28), Vector3(-0.27, 1.64, 0.2), mat("beacon_a", Color("0a1f6e"), 0.3, 0.0, Color("3a6bff")))
	box(n, Vector3(0.5, 0.1, 0.28), Vector3(0.27, 1.64, 0.2), mat("beacon_b", Color("0a1f6e"), 0.3, 0.0, Color("3a6bff")))
	return n


## Flash every police car's light bar: the two halves in turn.
static func flash_police(t: float, on: bool) -> void:
	if not _mats.has("beacon_a"):
		return
	var a := fmod(t * 3.0, 1.0) < 0.5
	(_mats.beacon_a as StandardMaterial3D).emission_energy_multiplier = (6.0 if a else 0.2) if on else 0.2
	(_mats.beacon_b as StandardMaterial3D).emission_energy_multiplier = (0.2 if a else 6.0) if on else 0.2


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


## Turn a vehicle's wheels (children named wheel...) for the distance it covered.
static func spin_wheels(n: Node3D, distance: float, radius: float) -> void:
	for w in n.find_children("wheel*", "", true, false):
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


# One section of a 1990s Amsterdam tram (a GVB 11G/12G, three sections, 27 m):
# a boxy high-floor body in GVB yellow on a dark skirt, a row of separate
# windows between yellow pillars, folding doors on the right-hand side only
# (the trams run one way), the bogies showing under it. `cab` -1 = the front
# section (its flat cab with a split windscreen, the destination box and the
# line number, round headlights), 1 = the rear (a back window and tail lights),
# 0 = the middle. `doors` = where its doors are, metres from its middle.
# `sign` = [line number, destination]: the front shows both over the
# windscreen and on a side sign by the front door, the back its line number.
# Forward is -Z.
static func tram_section(length: float, cab: int, doors: Array = [], sign: Array = []) -> Node3D:
	var n := Node3D.new()
	var yellow := mat("tram_yellow", Color("e2ac14"), 0.45, 0.05)
	var glass := mat("tram_glass", Color("10171b"), 0.08, 0.7)
	var frame := mat("tram_frame", Color("16181a"), 0.6)
	var dark := mat("tram_skirt", Color("2b2e31"), 0.7)
	var w := 2.35
	box(n, Vector3(w, 2.55, length), Vector3(0, 1.98, 0), yellow)                 # the body, floor at 0.9 m
	box(n, Vector3(w + 0.02, 0.42, length - 0.1), Vector3(0, 0.74, 0), dark)     # the skirt over the bogies
	box(n, Vector3(w + 0.03, 0.05, length), Vector3(0, 1.36, 0), frame)          # the rubbing strip
	# Windows: separate panes between yellow pillars, both sides, except where
	# a door stands on the right.
	var pane := 1.32
	var pitch := pane + 0.2
	var count := int((length - 0.7) / pitch)
	var first := -(count - 1) * pitch / 2.0
	for i in count:
		var z := first + i * pitch
		for side in [-1, 1]:
			var at_door := false
			for d in doors:
				if side == 1 and absf(z - float(d)) < 0.75 + pane / 2.0 - 0.05:   # the door's width
					at_door = true
			if at_door:
				continue
			box(n, Vector3(0.03, 1.12, pane + 0.08), Vector3(side * (w / 2 + 0.01), 2.12, z), frame)
			box(n, Vector3(0.03, 1.02, pane), Vector3(side * (w / 2 + 0.02), 2.13, z), glass)
	# Folding doors (two leaves, tall glass) on the right-hand side.
	for d in doors:
		var dz := float(d)
		box(n, Vector3(0.03, 2.05, 1.36), Vector3(w / 2 + 0.01, 1.78, dz), frame)
		for leaf in [-0.33, 0.33]:
			box(n, Vector3(0.03, 0.85, 0.56), Vector3(w / 2 + 0.02, 2.2, dz + leaf), glass)
			box(n, Vector3(0.03, 0.7, 0.56), Vector3(w / 2 + 0.02, 1.22, dz + leaf), glass)
		box(n, Vector3(0.6, 0.2, 1.2), Vector3(w / 2 - 0.2, 0.62, dz), dark)       # the step
	# The roof: grey, a little narrower, with an equipment box.
	box(n, Vector3(w - 0.12, 0.14, length - 0.05), Vector3(0, 3.31, 0), mat("tram_roof", Color("c9ccd0"), 0.6))
	box(n, Vector3(1.3, 0.3, minf(2.4, length * 0.3)), Vector3(0, 3.53, length * 0.15), mat("tram_roofbox", Color("9ea3a8"), 0.6))
	if cab == -1:
		var z0 := -length / 2.0
		# The flat cab: a split windscreen, the destination box over it with the
		# line number beside it, round headlights and a bumper.
		for x in [-0.56, 0.56]:
			var ws := box(n, Vector3(1.06, 1.15, 0.04), Vector3(x, 2.15, z0 - 0.02), glass)
			ws.rotation.x = -0.07                                                     # raked back a touch
		box(n, Vector3(0.08, 1.2, 0.05), Vector3(0, 2.15, z0 - 0.03), frame)       # the pillar between them
		var blind := mat("tram_blind", Color("0c0a08"), 0.6)
		box(n, Vector3(1.55, 0.34, 0.06), Vector3(0.28, 2.98, z0 - 0.03), blind)
		box(n, Vector3(0.42, 0.34, 0.06), Vector3(-0.82, 2.98, z0 - 0.03), mat("tram_line", Color("e8e8e0"), 0.4, 0.0, Color("fff6e0")))
		if sign.size() == 2:
			# The line number, black on its lit white box; the destination in
			# glowing amber letters on the dark blind; and again on the side.
			sign_text(n, str(sign[0]), Vector3(-0.82, 2.98, z0 - 0.07), PI, 0.36, 0.24, Color("111111"), true)
			sign_text(n, str(sign[1]), Vector3(0.28, 2.98, z0 - 0.07), PI, 1.45, 0.2, Color("ffb020"), false)
			var sz: float = doors[0] - 1.25 if doors.size() else z0 + 1.6
			box(n, Vector3(0.04, 0.28, 1.9), Vector3(w / 2 + 0.02, 2.92, sz), blind)
			sign_text(n, "%s  %s" % [sign[0], sign[1]], Vector3(w / 2 + 0.05, 2.92, sz), PI / 2, 1.8, 0.17, Color("ffb020"), false)
		var lamp := CylinderMesh.new(); lamp.top_radius = 0.11; lamp.bottom_radius = 0.11; lamp.height = 0.06
		for x in [-0.78, 0.78]:
			var mi := MeshInstance3D.new(); mi.mesh = lamp
			mi.material_override = mat("headlight", Color("fff6d8"), 0.3, 0.0, Color("fff2c0"))
			mi.rotation.x = PI / 2; mi.position = Vector3(x, 1.08, z0 - 0.03)
			n.add_child(mi)
		box(n, Vector3(w - 0.1, 0.22, 0.14), Vector3(0, 0.62, z0 - 0.06), dark)   # the bumper
		# The pantograph, a diamond on the roof at the back of the front section.
		var panto := mat("panto", Color("2a2c2e"), 0.5, 0.6)
		var pz := length / 2.0 - 1.6
		box(n, Vector3(1.5, 0.06, 0.1), Vector3(0, 4.34, pz), panto)               # the contact strip
		var foot := Vector2(pz, 3.47); var knee := 0.36; var head := Vector2(pz, 4.32)
		for k in [-1.0, 1.0]:
			var mid := Vector2(pz + k * knee, (foot.y + head.y) / 2.0)
			for arm in [[foot, mid], [mid, head]]:                                  # the lower and upper arm
				var a: Vector2 = arm[0]; var c: Vector2 = arm[1]
				var rod := box(n, Vector3(0.05, a.distance_to(c), 0.05), Vector3(0, (a.y + c.y) / 2.0, (a.x + c.x) / 2.0), panto)
				rod.rotation.x = atan2(c.x - a.x, c.y - a.y)                         # tilt its length from a to c
		box(n, Vector3(0.5, 0.08, 0.5), Vector3(0, 3.43, pz), panto)               # its base
	elif cab == 1:
		var z1 := length / 2.0
		box(n, Vector3(1.7, 0.95, 0.04), Vector3(0, 2.2, z1 + 0.02), glass)        # the back window
		if sign.size() == 2:                                                        # its line number in the back window
			box(n, Vector3(0.42, 0.34, 0.03), Vector3(0.55, 2.45, z1 + 0.045), mat("tram_line", Color("e8e8e0"), 0.4, 0.0, Color("fff6e0")))
			sign_text(n, str(sign[0]), Vector3(0.55, 2.45, z1 + 0.07), 0.0, 0.36, 0.24, Color("111111"), true)
		for x in [-0.85, 0.85]:
			box(n, Vector3(0.22, 0.14, 0.05), Vector3(x, 1.05, z1 + 0.03), mat("taillight", Color("5a0a0a"), 0.4, 0.0, Color("ff2a1a")))
		box(n, Vector3(w - 0.1, 0.22, 0.14), Vector3(0, 0.62, z1 + 0.06), dark)
	wheels(n, 0.75, [-length * 0.28, length * 0.28] if length > 8.0 else [0.0], 0.34)
	return n


## Words on a sign: a Label3D on the sign's face, facing `yaw` (0 = +Z), its
## letters `height` m tall but shrunk to fit `width` m; unlit, so a lit sign
## reads at night. `bold` for a line number.
static func sign_text(parent: Node3D, text: String, pos: Vector3, yaw: float, width: float, height: float, color: Color, bold: bool) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 64
	l.outline_size = 0
	l.modulate = color
	l.double_sided = false
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if bold:
		var f := SystemFont.new(); f.font_weight = 800
		l.font = f
	# A letter is about 0.55 of the font size wide: shrink long names to fit.
	var per_px := height / 64.0
	var wide := text.length() * 0.56 * 64.0 * per_px
	if wide > width:
		per_px *= width / wide
	l.pixel_size = per_px
	l.position = pos
	l.rotation.y = yaw
	parent.add_child(l)
	return l


## The bellows between two sections, standing on the rails as they do.
static func tram_joint() -> Node3D:
	var n := Node3D.new()
	var b := BoxMesh.new(); b.size = Vector3(2.15, 2.4, 0.9)
	var mi := MeshInstance3D.new(); mi.mesh = b; mi.material_override = mat("bellows", Color("23272b"), 0.9)
	mi.position.y = 1.95
	n.add_child(mi)
	return n
