extends RefCounted
## A soft dark patch on the ground under something: the contact shadow the
## browser's renderer has no ambient occlusion for (cars, people, pickups
## would otherwise float on the stones). A flat quad, multiplied over the
## ground, darkest in the middle. One shared material.
##     ContactShadow.add(node, Vector2(width, length))

static var _mat: StandardMaterial3D
static var _mesh := {}


static func material() -> StandardMaterial3D:
	if _mat:
		return _mat
	# Black, its alpha falling off from the middle. (Not a multiply blend: with
	# glow on, the browser's renderer draws those as black squares.)
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0.62)); g.set_color(1, Color(0, 0, 0, 0.0))
	g.add_point(0.5, Color(0, 0, 0, 0.3))
	var t := GradientTexture2D.new(); t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL; t.fill_from = Vector2(0.5, 0.5); t.fill_to = Vector2(0.5, 0.0)
	t.width = 64; t.height = 64
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.albedo_texture = t
	m.render_priority = 1
	_mat = m
	return _mat


## A patch `size` (x across, y along) under `parent`, lying on the ground at
## its origin; `free` (top_level) for one that must stay flat whatever its
## parent does (a person: move it with `follow`).
static func add(parent: Node3D, size: Vector2, free := false) -> MeshInstance3D:
	var key := size
	if not _mesh.has(key):
		var q := PlaneMesh.new(); q.size = size
		_mesh[key] = q
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh[key]
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "contact_shadow"
	mi.position.y = 0.035
	parent.add_child(mi)
	mi.top_level = free
	return mi


## Keep a free patch flat on the ground under `at`.
static func follow(mi: MeshInstance3D, at: Vector3) -> void:
	mi.global_transform = Transform3D(Basis(), Vector3(at.x, at.y + 0.035, at.z))
