extends Node3D
## The air over the city: mist on the canals at dawn and dusk (two sheets of
## drifting noise just above the water, under the streets, so only the canals
## show it: shaders/mist.gdshader), and birds wheeling over the rooftops by
## day, a few flocks of gulls and pigeons flapping round in loose circles.
##     atmosphere.set_hour(h, cloud, rain, tint); atmosphere.focus = camera position

const WATER_Y := -1.4
const BIRDS := 36
const FLOCKS := 4

var focus := Vector3.ZERO
var mist: Array[MeshInstance3D] = []
var _mist_mat: ShaderMaterial
var _birds: MultiMeshInstance3D
var _flocks: Array = []         # {centre offset, radius, height, speed, phase}
var _bird_seed: Array = []      # per bird: [flock, offset angle, offset radius, height jitter, flap phase]
var _day := 1.0
var _t := 0.0


func _init() -> void:                 # (built at once: Main sets the hour before it is in the tree)
	var tex := NoiseTexture2D.new()
	var n := FastNoiseLite.new(); n.frequency = 0.015; n.fractal_octaves = 3
	tex.noise = n; tex.seamless = true; tex.width = 256; tex.height = 256
	_mist_mat = ShaderMaterial.new()
	_mist_mat.shader = load("res://shaders/mist.gdshader")
	_mist_mat.set_shader_parameter("noise", tex)
	for y in [WATER_Y + 0.35, WATER_Y + 0.9]:
		var mi := MeshInstance3D.new()
		var pm := PlaneMesh.new(); pm.size = Vector2(500, 500)
		mi.mesh = pm
		mi.material_override = _mist_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position.y = y
		add_child(mi)
		mist.append(mi)
	_make_birds()


## The hour (0-24), cloud and rain (0..1), and the colour of the air.
func set_hour(h: float, cloud: float, rain: float, tint: Color) -> void:
	var dawn := clampf(1.0 - absf(h - 7.0) / 2.0, 0.0, 1.0)
	var dusk := clampf(1.0 - absf(h - 19.5) / 2.0, 0.0, 1.0)
	var night := 1.0 if h < 6.0 or h > 21.5 else 0.0
	var amount := maxf(maxf(dawn, dusk), night * 0.45) * 0.9 + 0.12 + rain * 0.25 + cloud * 0.08
	_mist_mat.set_shader_parameter("amount", clampf(amount, 0.0, 1.0))
	_mist_mat.set_shader_parameter("tint", tint)
	_day = clampf(1.0 - night, 0.0, 1.0) * (1.0 - rain * 0.8)
	_birds.visible = _day > 0.2


func _process(delta: float) -> void:
	_t += delta
	for mi in mist:
		mi.global_position = Vector3(focus.x, mi.global_position.y, focus.z)
	_mist_mat.set_shader_parameter("drift", Vector2(_t * 0.004, _t * 0.0016))
	if _birds.visible:
		_fly()


# ---- birds -------------------------------------------------------------------------------

func _make_birds() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	for f in FLOCKS:
		_flocks.append([Vector2(rng.randf_range(-60, 60), rng.randf_range(-60, 60)), rng.randf_range(18, 40),
			rng.randf_range(26, 45), rng.randf_range(0.12, 0.25) * (1 if rng.randf() < 0.5 else -1), rng.randf() * TAU])
	for i in BIRDS:
		_bird_seed.append([i % FLOCKS, rng.randf() * TAU, rng.randf_range(0, 9), rng.randf_range(-3, 3), rng.randf() * TAU, rng.randf_range(7, 10)])
	# A bird: two flat wings, a V, dark against the sky.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		st.add_vertex(Vector3(0, 0, -0.35)); st.add_vertex(Vector3(side * 1.1, 0.25, 0.1)); st.add_vertex(Vector3(0, 0, 0.4))
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0.16, 0.17, 0.19)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mesh := st.commit()
	mesh.surface_set_material(0, m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = BIRDS
	_birds = MultiMeshInstance3D.new()
	_birds.multimesh = mm
	_birds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_birds)


func _fly() -> void:
	var mm := _birds.multimesh
	var c2 := Vector2(focus.x, focus.z)
	for i in BIRDS:
		var s: Array = _bird_seed[i]
		var f: Array = _flocks[s[0]]
		var a: float = f[4] + _t * f[3] + s[1] * 0.08
		var centre: Vector2 = c2 + f[0]
		var r: float = f[1] + s[2]
		var p := Vector3(centre.x + cos(a) * r, focus.y + f[2] + s[3] + sin(_t * 0.5 + s[1]) * 1.5, centre.y + sin(a) * r)
		var tangent := Vector3(-sin(a), 0, cos(a)) * signf(f[3])
		var flap := sin(_t * s[5] + s[4])
		var b := Basis.looking_at(tangent, Vector3.UP)
		b = b * Basis(Vector3.FORWARD, 0.0).scaled(Vector3(1.0, 1.0 + flap * 2.2, 1.0))
		mm.set_instance_transform(i, Transform3D(b, p))
