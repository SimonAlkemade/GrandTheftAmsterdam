extends Node3D
const ContactShadow := preload("res://scripts/contact_shadow.gd")
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


var shade: MeshInstance3D           # the soft shadow at their feet (kept flat on the ground)


func build(top: Color, legs: Color, skin: Color, hair: Color, shoe: Color, jacket = null) -> void:
	shade = ContactShadow.add(self, Vector2(1.0, 1.0), true)
	_own_timing()
	var mt := _m(top); var ml := _m(legs); var ms := _m(skin); var mh := _m(hair); var mf := _m(shoe, 0.5)
	var mj: StandardMaterial3D = _m(jacket) if jacket != null else mt
	hips = _joint(self, Vector3(0, 0.93, 0))
	var pelvis := BoxMesh.new(); pelvis.size = Vector3(0.34, 0.16, 0.2)
	_part(hips, pelvis, ml, Vector3(0, 0.02, 0))
	spine = _joint(hips, Vector3(0, 0.08, 0))
	_part(spine, _capsule(0.17, 0.66), mj, Vector3(0, 0.26, 0), Vector3(1.25, 1, 0.75))
	# (Few segments: Godot's default sphere is 4,000 triangles, a whole person's
	# worth many times over at the size of a hand.)
	var neck := CylinderMesh.new(); neck.top_radius = 0.045; neck.bottom_radius = 0.05; neck.height = 0.1; neck.radial_segments = 8; neck.rings = 1
	_part(spine, neck, ms, Vector3(0, 0.55, 0)).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head = _joint(spine, Vector3(0, 0.66, 0))
	var hs := SphereMesh.new(); hs.radius = 0.115; hs.height = 0.25; hs.radial_segments = 12; hs.rings = 6
	_part(head, hs, ms)
	var hair_m := SphereMesh.new(); hair_m.radius = 0.122; hair_m.height = 0.2; hair_m.is_hemisphere = true; hair_m.radial_segments = 12; hair_m.rings = 4
	_part(head, hair_m, mh, Vector3(0, 0.03, 0.006)).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # (the head's shadow is enough)
	var limb := func(parent: Node3D, x: float, y: float, r1: float, h1: float, m1: Material, r2: float, h2: float, m2: Material, knee: float, end_mesh: Mesh, end_m: Material) -> Array:
		var a := _joint(parent, Vector3(x, y, 0))
		_part(a, _capsule(r1, h1), m1, Vector3(0, -h1 / 2.0, 0))
		var b := _joint(a, Vector3(0, knee, 0))
		_part(b, _capsule(r2, h2), m2, Vector3(0, -h2 / 2.0, 0))
		# Hands and feet: too small to need a shadow of their own.
		_part(b, end_mesh, end_m, Vector3(0, -h2 + 0.02, -0.04 if end_mesh is BoxMesh else 0.0)).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		return [a, b]
	var hand := SphereMesh.new(); hand.radius = 0.045; hand.height = 0.1; hand.radial_segments = 6; hand.rings = 3
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


# The gait, the standing and the moments in between (all per person: each has
# their own timing, so a crowd is never in step).
const LEG := 0.9                  # hip to sole, metres
var _gait := 0.0                  # 0 standing .. 1 in the stride (eased: no jump starting or stopping)
var _run_w := 0.0                 # 0 a walk .. 1 a run (by speed)
var _breath := 1.6                # breathing, radians a second
var _shift := 0.0                 # standing: the weight over the right (+1) or left (-1) leg
var _shift_to := 0.0
var _shift_t := 3.0               # seconds to the next shift
var _glance := 0.0                # standing: where the head looks (yaw)
var _glance_to := 0.0
var _glance_t := 5.0


# Each person their own timing (build() calls it).
func _own_timing() -> void:
	phase = randf() * TAU
	t = randf() * 20.0
	_breath = randf_range(1.4, 1.9)
	_shift_t = randf_range(1.0, 5.0)
	_shift_to = 1.0 if randf() < 0.5 else -1.0
	_glance_t = randf_range(3.0, 9.0)


func _ease(n: Node3D, v: Vector3, dt: float, k := 10.0) -> void:
	n.rotation += (v - n.rotation) * minf(1.0, dt * k)


func animate(dt: float, state: String, speed: float) -> void:
	t += dt
	if shade and is_inside_tree():
		ContactShadow.follow(shade, global_position)
	var moving := state == "walk" or state == "run"
	if moving and _gait == 0.0:          # setting off: from where both knees are straight, either foot first
		phase = PI * (0.5 if randf() < 0.5 else 1.5)
	_gait = move_toward(_gait, 1.0 if moving and speed > 0.05 else 0.0, dt * 3.0)
	if moving:
		_run_w = move_toward(_run_w, clampf((speed - 2.2) / 2.0, 0.0, 1.0), dt * 3.0)
	match state:
		"jump", "fall":
			_untwist(dt)
			_lerp(hp_l, 0.7, dt); _lerp(hp_r, -0.2, dt); _lerp(kn_l, -1.1, dt); _lerp(kn_r, -0.4, dt)
			_lerp(sh_l, 1.1, dt, 8); _lerp(sh_r, 0.9, dt, 8); _lerp(el_l, 0.5, dt); _lerp(el_r, 0.5, dt)
		"swim":
			_untwist(dt)
			phase += dt * 2.6
			rotation.x += ((1.25 if speed > 0.3 else 0.25) - rotation.x) * minf(1.0, dt * 4)
			sh_l.rotation.x = fmod(phase, TAU); sh_r.rotation.x = fmod(phase + PI, TAU)
			el_l.rotation.x = 0.3; el_r.rotation.x = 0.3
			hp_l.rotation.x = sin(phase * 3) * 0.3; hp_r.rotation.x = -hp_l.rotation.x
			kn_l.rotation.x = -0.2; kn_r.rotation.x = -0.2
		"climb":
			_untwist(dt)
			_lerp(sh_l, 2.8, dt, 10); _lerp(sh_r, 2.8, dt, 10); _lerp(hp_l, 1.2, dt, 10); _lerp(kn_l, -1.6, dt, 10)
			rotation.x += (0.0 - rotation.x) * minf(1.0, dt * 8)
		"cut":
			_untwist(dt)
			_kneel_and_cut(dt)
		"crawl":
			_untwist(dt)
			_crawl(dt, speed)
		_:
			_on_feet(dt, speed)


# Walking, running, standing, and the blend between them.
func _on_feet(dt: float, speed: float) -> void:
	rotation.x += (0.0 - rotation.x) * minf(1.0, dt * 6)
	var g := _gait
	var r := _run_w
	var still := 1.0 - g
	# The stride grows with speed and the legs cycle as fast as the ground goes by.
	var stride: float = lerpf(1.25 + 0.15 * speed, 1.5 + 0.25 * speed, r)
	if g > 0.0:
		phase += dt * maxf(speed, 0.6) / maxf(stride, 0.5) * TAU
	var s := sin(phase)
	var c := cos(phase)
	var leg: float = minf(asin(clampf(stride * 0.25 / LEG, 0.0, 0.95)), 0.9) * g
	# Knees: near straight as the heel strikes, bent through the swing, a give as the weight lands.
	var swing: float = lerpf(1.1, 1.7, r)
	var knee_l: float = -(swing * pow(maxf(0.0, c), 1.3) + 0.15 * maxf(0.0, -s) * maxf(0.0, -c)) * g
	var knee_r: float = -(swing * pow(maxf(0.0, -c), 1.3) + 0.15 * maxf(0.0, s) * maxf(0.0, c)) * g
	# Arms against the legs, the elbow bending more as the arm comes forward.
	var arm: float = lerpf(0.35, 0.85, r) * g
	var bend: float = lerpf(0.3, 1.35, r)
	# Standing: breathing, a slow weight shift from leg to leg, a glance now and then.
	var br := sin(t * _breath)
	_shift_t -= dt * still
	if _shift_t <= 0.0:
		_shift_t = randf_range(4.0, 7.0)
		_shift_to = (-1.0 if _shift_to > 0.0 else 1.0) * randf_range(0.6, 1.0)
	_shift += (_shift_to - _shift) * minf(1.0, dt * 1.2)
	if g > 0.5:
		_glance_t = randf_range(3.0, 9.0)        # (walking you look ahead)
		_glance_to = 0.0
	else:
		_glance_t -= dt
		if _glance_t <= 0.0:
			_glance_t = randf_range(3.0, 9.0)
			_glance_to = 0.0 if absf(_glance_to) > 0.05 else randf_range(-0.6, 0.6)
	_glance += (_glance_to - _glance) * minf(1.0, dt * 3.0)
	var lean_shift := _shift * still
	# The legs.
	hp_l.rotation.x = s * leg + 0.04 * r * g
	hp_r.rotation.x = -s * leg + 0.04 * r * g
	kn_l.rotation.x = knee_l - 0.04 - 0.14 * maxf(0.0, lean_shift)       # (the unweighted knee eases)
	kn_r.rotation.x = knee_r - 0.04 - 0.14 * maxf(0.0, -lean_shift)
	# The pelvis: down and up twice a stride (a walk rides high over the planted leg, a run
	# sinks into it), over the standing leg, turning with the leading one.
	var bob: float = lerpf(0.018, -0.035, r) * cos(2.0 * phase) * g
	hips.position.y = 0.93 - lerpf(0.012, 0.06, r) * g + bob + 0.004 * br * still - 0.01 * absf(lean_shift)
	hips.position.x = lerpf(0.025, 0.012, r) * c * g + 0.03 * lean_shift
	var pelvis_yaw: float = -lerpf(0.08, 0.12, r) * s * g
	hips.rotation.y = pelvis_yaw
	hips.rotation.z = 0.035 * c * g * (1.0 - 0.5 * r) - 0.04 * lean_shift
	# The chest turns back against the pelvis, leans into a run, breathes.
	var lean: float = -(0.05 + 0.17 * r) * g + 0.02 * br * still
	spine.rotation.x += (lean - spine.rotation.x) * minf(1.0, dt * 10.0)
	spine.rotation.y = lerpf(0.06, 0.1, r) * s * g - pelvis_yaw
	spine.rotation.z = 0.04 * lean_shift
	# The arms.
	sh_l.rotation.x = -s * arm + 0.02 * br * still
	sh_r.rotation.x = s * arm - 0.02 * br * still
	el_l.rotation.x = 0.15 * still + (bend + 0.3 * maxf(0.0, -s) * (1.0 - r)) * g
	el_r.rotation.x = 0.15 * still + (bend + 0.3 * maxf(0.0, s) * (1.0 - r)) * g
	sh_l.rotation.z = 0.08 + 0.05 * r * g
	sh_r.rotation.z = -0.08 - 0.05 * r * g
	# The head keeps looking ahead (or where it glances), whatever the body does.
	head.rotation.y = -(hips.rotation.y + spine.rotation.y) * 0.85 + _glance * still
	head.rotation.x = -spine.rotation.x * 0.7 + 0.015 * sin(2.0 * phase) * g
	head.rotation.z = -(hips.rotation.z + spine.rotation.z) * 0.7


# Off your feet: the gait's twist and sway eased out.
func _untwist(dt: float) -> void:
	var k := minf(1.0, dt * 8.0)
	hips.position.x += (0.0 - hips.position.x) * k
	hips.rotation.y += (0.0 - hips.rotation.y) * k
	hips.rotation.z += (0.0 - hips.rotation.z) * k
	spine.rotation.y += (0.0 - spine.rotation.y) * k
	spine.rotation.z += (0.0 - spine.rotation.z) * k
	head.rotation = head.rotation * (1.0 - k)


## Down on the right knee at a fence, bolt cutters in both hands, squeezing
## them shut and open again (CUT_BEAT, as the cutters' own "cut" animation).
const CUT_BEAT := 0.8
func _kneel_and_cut(dt: float) -> void:
	var k := minf(1.0, dt * 8.0)
	rotation.x += (0.0 - rotation.x) * k
	hips.position.y += (0.5 - hips.position.y) * k
	_lerp(hp_l, 1.45, dt, 8)          # the left foot planted forward, thigh level
	_lerp(kn_l, -1.5, dt, 8)
	_lerp(hp_r, -0.15, dt, 8)         # the right knee on the ground, shin back along it
	_lerp(kn_r, -1.75, dt, 8)
	_lerp(spine, -0.32, dt, 8)        # leaning in to the fence
	var beat := 0.5 - 0.5 * cos(t / CUT_BEAT * TAU)     # 0 open .. 1 squeezed
	_lerp(sh_l, 1.0 + 0.1 * beat, dt, 14); _lerp(sh_r, 1.0 + 0.1 * beat, dt, 14)
	_lerp(el_l, 0.45, dt, 10); _lerp(el_r, 0.45, dt, 10)
	sh_l.rotation.z = 0.08 - 0.22 * beat                # the hands come together on the handles
	sh_r.rotation.z = -0.08 + 0.22 * beat
	head.rotation.x += (0.25 - head.rotation.x) * k     # (looking down at the wire)


## Flat on the ground, pulling along on the elbows, knees working (under a fence).
func _crawl(dt: float, speed: float) -> void:
	var k := minf(1.0, dt * 6.0)
	rotation.x += (-1.42 - rotation.x) * k             # (tipped forward, head first: -x)
	hips.position.y += (0.93 - hips.position.y) * k
	phase += dt * (2.0 + speed * 4.0)
	var s := sin(phase)
	sh_l.rotation.x = 2.5 + 0.45 * s; sh_r.rotation.x = 2.5 - 0.45 * s     # (overhead, lying: forward)
	el_l.rotation.x = 1.1 - 0.4 * s; el_r.rotation.x = 1.1 + 0.4 * s
	hp_l.rotation.x = 0.35 - 0.35 * s; hp_r.rotation.x = 0.35 + 0.35 * s
	kn_l.rotation.x = -0.9 + 0.4 * s; kn_r.rotation.x = -0.9 - 0.4 * s
	sh_l.rotation.z = 0.25; sh_r.rotation.z = -0.25
	head.rotation.x += (-0.9 - head.rotation.x) * k     # (head up, looking ahead)
