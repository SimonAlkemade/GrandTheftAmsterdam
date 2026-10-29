extends Node3D
## A jointed figure (hips, spine, head; shoulders and elbows; hips and knees)
## posed procedurally: idle, walk, run, jump, fall, swim, climb.
## Conventions: +x on a hip or shoulder swings the limb forward (towards -Z),
## +x on an elbow bends the forearm forward, -x on a knee bends the shin back.

var hips: Node3D
var spine: Node3D
var head: Node3D
var sh_l: Node3D; var sh_r: Node3D; var el_l: Node3D; var el_r: Node3D
var hp_l: Node3D; var hp_r: Node3D; var kn_l: Node3D; var kn_r: Node3D
var phase := 0.0
var t := 0.0


static func _m(c: Color, rough := 0.75) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = c; m.roughness = rough
	return m


func _part(parent: Node3D, mesh: Mesh, m: Material, pos := Vector3.ZERO, scl := Vector3.ONE) -> MeshInstance3D:
	var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.material_override = m; mi.position = pos; mi.scale = scl
	parent.add_child(mi)
	return mi


func _joint(parent: Node3D, pos: Vector3) -> Node3D:
	var j := Node3D.new(); j.position = pos
	parent.add_child(j)
	return j


func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new(); c.radius = r; c.height = h; c.radial_segments = 10; c.rings = 3
	return c


func build(top: Color, legs: Color, skin: Color, hair: Color, shoe: Color, jacket = null) -> void:
	var mt := _m(top); var ml := _m(legs); var ms := _m(skin); var mh := _m(hair); var mf := _m(shoe, 0.5)
	var mj: StandardMaterial3D = _m(jacket) if jacket != null else mt
	hips = _joint(self, Vector3(0, 0.93, 0))
	var pelvis := BoxMesh.new(); pelvis.size = Vector3(0.34, 0.16, 0.2)
	_part(hips, pelvis, ml, Vector3(0, 0.02, 0))
	spine = _joint(hips, Vector3(0, 0.08, 0))
	_part(spine, _capsule(0.17, 0.66), mj, Vector3(0, 0.26, 0), Vector3(1.25, 1, 0.75))
	var neck := CylinderMesh.new(); neck.top_radius = 0.045; neck.bottom_radius = 0.05; neck.height = 0.1
	_part(spine, neck, ms, Vector3(0, 0.55, 0))
	head = _joint(spine, Vector3(0, 0.66, 0))
	var hs := SphereMesh.new(); hs.radius = 0.115; hs.height = 0.25
	_part(head, hs, ms)
	var hair_m := SphereMesh.new(); hair_m.radius = 0.122; hair_m.height = 0.2; hair_m.is_hemisphere = true
	_part(head, hair_m, mh, Vector3(0, 0.03, 0.006))
	var limb := func(parent: Node3D, x: float, y: float, r1: float, h1: float, m1: Material, r2: float, h2: float, m2: Material, knee: float, end_mesh: Mesh, end_m: Material) -> Array:
		var a := _joint(parent, Vector3(x, y, 0))
		_part(a, _capsule(r1, h1), m1, Vector3(0, -h1 / 2.0, 0))
		var b := _joint(a, Vector3(0, knee, 0))
		_part(b, _capsule(r2, h2), m2, Vector3(0, -h2 / 2.0, 0))
		_part(b, end_mesh, end_m, Vector3(0, -h2 + 0.02, -0.04 if end_mesh is BoxMesh else 0.0))
		return [a, b]
	var hand := SphereMesh.new(); hand.radius = 0.045; hand.height = 0.1
	var foot := BoxMesh.new(); foot.size = Vector3(0.1, 0.07, 0.24)
	var l = limb.call(spine, -0.235, 0.47, 0.048, 0.32, mj, 0.042, 0.3, mj, -0.3, hand, ms); sh_l = l[0]; el_l = l[1]
	l = limb.call(spine, 0.235, 0.47, 0.048, 0.32, mj, 0.042, 0.3, mj, -0.3, hand, ms); sh_r = l[0]; el_r = l[1]
	l = limb.call(hips, -0.095, -0.02, 0.07, 0.44, ml, 0.055, 0.46, ml, -0.44, foot, mf); hp_l = l[0]; kn_l = l[1]
	l = limb.call(hips, 0.095, -0.02, 0.07, 0.44, ml, 0.055, 0.46, ml, -0.44, foot, mf); hp_r = l[0]; kn_r = l[1]
	sh_l.rotation.z = 0.08; sh_r.rotation.z = -0.08


func random_look(rng: RandomNumberGenerator) -> void:
	var pick := func(a: Array) -> Color: return Color(a[rng.randi() % a.size()])
	build(pick.call(["2f4f7f", "c0392b", "e6e2d8", "27ae60", "1c1c1c", "f39c12", "8e44ad", "16a085", "7f8c8d", "d35400"]),
		pick.call(["1f2a44", "2b2b2b", "4a4a4a", "6d5843", "1d3557"]),
		pick.call(["f1c7a5", "d9a07a", "a56a43", "6b4128", "e8b590"]),
		pick.call(["2b1d14", "5a3a1e", "d9b26f", "111111", "8a8a8a"]),
		pick.call(["141414", "f2f2f2", "6b3a22"]))


func _lerp(n: Node3D, v: float, dt: float, k := 12.0) -> void:
	n.rotation.x += (v - n.rotation.x) * minf(1.0, dt * k)


func animate(dt: float, state: String, speed: float) -> void:
	t += dt
	match state:
		"walk", "run":
			var run := state == "run"
			phase += dt * (2.1 if run else 1.75) * maxf(1.2, speed) * (0.95 if run else 1.15)
			var s := sin(phase)
			var leg := s * (0.85 if run else 0.5)
			var arm := s * (0.9 if run else 0.4)
			var knee := 1.4 if run else 0.75
			hp_l.rotation.x = leg; hp_r.rotation.x = -leg
			kn_l.rotation.x = -maxf(0.0, sin(phase + 0.9)) * knee - 0.05
			kn_r.rotation.x = -maxf(0.0, sin(phase + 0.9 + PI)) * knee - 0.05
			sh_l.rotation.x = -arm; sh_r.rotation.x = arm
			el_l.rotation.x = 1.35 if run else 0.35; el_r.rotation.x = el_l.rotation.x
			spine.rotation.y = s * (0.12 if run else 0.06)
			_lerp(spine, -0.22 if run else -0.05, dt)   # negative x leans the back forward
			hips.position.y = 0.93 - (0.06 if run else 0.02) + absf(cos(phase)) * (0.07 if run else 0.035)
			rotation.x = 0.0
		"jump", "fall":
			_lerp(hp_l, 0.7, dt); _lerp(hp_r, -0.2, dt); _lerp(kn_l, -1.1, dt); _lerp(kn_r, -0.4, dt)
			_lerp(sh_l, 1.1, dt, 8); _lerp(sh_r, 0.9, dt, 8); _lerp(el_l, 0.5, dt); _lerp(el_r, 0.5, dt)
		"swim":
			phase += dt * 2.6
			rotation.x += ((1.25 if speed > 0.3 else 0.25) - rotation.x) * minf(1.0, dt * 4)
			sh_l.rotation.x = fmod(phase, TAU); sh_r.rotation.x = fmod(phase + PI, TAU)
			el_l.rotation.x = 0.3; el_r.rotation.x = 0.3
			hp_l.rotation.x = sin(phase * 3) * 0.3; hp_r.rotation.x = -hp_l.rotation.x
			kn_l.rotation.x = -0.2; kn_r.rotation.x = -0.2
		"climb":
			_lerp(sh_l, 2.8, dt, 10); _lerp(sh_r, 2.8, dt, 10); _lerp(hp_l, 1.2, dt, 10); _lerp(kn_l, -1.6, dt, 10)
			rotation.x += (0.0 - rotation.x) * minf(1.0, dt * 8)
		_:
			var br := sin(t * 1.8)
			rotation.x += (0.0 - rotation.x) * minf(1.0, dt * 6)
			_lerp(hp_l, 0.0, dt); _lerp(hp_r, 0.0, dt); _lerp(kn_l, -0.04, dt); _lerp(kn_r, -0.04, dt)
			_lerp(sh_l, 0.03 * br, dt); _lerp(sh_r, -0.03 * br, dt); _lerp(el_l, 0.15, dt); _lerp(el_r, 0.15, dt)
			_lerp(spine, 0.02 * br, dt)
			spine.rotation.y *= 0.9
			hips.position.y = 0.93 + 0.004 * br
