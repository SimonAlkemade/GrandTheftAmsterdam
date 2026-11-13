extends RigidBody3D
## A canal sloep that floats: a rigid body held up by buoyancy, not by rails.
##
## Eight points round the bottom of the hull each push up in proportion to how
## deep they are under the surface (and damp their own bobbing), so the boat
## finds its own waterline, and pitches, rolls and settles back by itself.
## The water drags weakly along the hull and hard across it, so it glides on
## when you let go and slides out in a turn. The motor pushes at the stern and
## A/D swing its thrust like an outboard, so it steers best under power; the
## rudder bites a little when it only drifts. The model faces -Z.
##
## Under way it leaves a wake: foam spreading out flat on the water behind the
## stern and from the bow, and spray off the bow at speed.

const WATER_Y := -1.4             # the canal surface (TileBuilder.WATER_Y)
const MASS := 900.0
const LENGTH := 5.4
const BEAM := 1.9
const DRAFT := 0.3                # the hull points sit this far under the waterline at rest
const DEPTH_MAX := 0.95           # ...and stop adding lift once the gunwale is under
const THRUST := 3200.0            # N, full ahead
const BOOST := 1.6                # with Shift
const STEER := 0.6                # how far the outboard swings, radians
const DRAG_ALONG := Vector2(60.0, 45.0)     # quadratic, linear: a hull slips through lengthways
const DRAG_ACROSS := Vector2(900.0, 700.0)  # and hardly at all sideways
const YAW_DAMP := Vector2(9000.0, 5000.0)   # quadratic, linear
const RUDDER := 260.0             # sideways force at the stern per m/s and radian

var throttle := 0.0               # -1 .. 1
var steer := 0.0                  # -1 (right) .. 1 (left)
var boost := false
var rudder := 0.0                 # the outboard's angle now: it swings, it does not jump
var _points: Array[Vector3] = []
var _k := 0.0                     # lift per metre under, per point
var _c := 0.0                     # damping per m/s, per point
var _t := 0.0
var wake: CPUParticles3D          # foam behind, lying on the water
var bow_foam: CPUParticles3D      # foam pushed aside by the bow
var spray: CPUParticles3D         # droplets thrown off the bow at speed
static var _foam_mat: StandardMaterial3D


func _init() -> void:
	mass = MASS
	collision_layer = 8           # VehiclePhysics.BODY_LAYER
	collision_mask = 1 | 2 | 4 | 8   # buildings, the quay walls and canal bed, traffic, other boats
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.12, 0)
	continuous_cd = true
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.bounce = 0.1
	physics_material_override.friction = 0.3   # it scrapes along a quay rather than climbing it
	can_sleep = false             # it never quite stops moving on the water
	gravity_scale = 1.0
	# Two rows of four along the bottom of the hull.
	for z in [-1.9, -0.65, 0.65, 2.0]:
		var w := 0.62 if z > -1.5 else 0.4    # the bow is fine
		for x in [-w, w]:
			_points.append(Vector3(x, -DRAFT, z))
	# At rest every point is DRAFT deep and together they carry the weight.
	_k = MASS * 9.8 / (_points.size() * DRAFT)
	# About a third of critical damping on the heave.
	_c = 0.35 * 2.0 * MASS * sqrt(_points.size() * _k / MASS) / _points.size()
	_hull_shape()
	wake = _foam(120, 3.5, Vector3(0, 0, LENGTH / 2 - 0.3), 0.8, 3.2)
	bow_foam = _foam(50, 1.8, Vector3(0, 0, -LENGTH / 2 + 0.9), 0.5, 2.0)
	spray = CPUParticles3D.new()
	spray.amount = 30; spray.lifetime = 0.7; spray.local_coords = false
	var sq := QuadMesh.new(); sq.size = Vector2(0.12, 0.12)
	spray.mesh = sq; spray.material_override = _foam_material()
	spray.direction = Vector3(0, 1, -0.4); spray.spread = 35.0
	spray.initial_velocity_min = 1.5; spray.initial_velocity_max = 3.5
	spray.gravity = Vector3(0, -9.8, 0)
	spray.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX; spray.emission_box_extents = Vector3(0.6, 0.05, 0.2)
	spray.position = Vector3(0, -0.15, -LENGTH / 2 + 0.4)
	spray.emitting = false
	spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(spray)


# Foam lying flat on the water, `amount` patches living `life` seconds, emitted
# across `width` at `at`, growing to `grow` metres.
func _foam(amount: int, life: float, at: Vector3, width: float, grow: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount; p.lifetime = life; p.local_coords = false
	var q := PlaneMesh.new(); q.size = Vector2(1.0, 1.0)
	p.mesh = q; p.material_override = _foam_material()
	p.particle_flag_rotate_y = true            # (patches turn about the vertical, staying flat)
	p.direction = Vector3(0, 0, 1); p.spread = 80.0; p.flatness = 1.0   # (fanning out sideways: a V)
	p.initial_velocity_min = 0.6; p.initial_velocity_max = 1.6
	p.gravity = Vector3.ZERO
	p.damping_min = 0.3; p.damping_max = 0.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX; p.emission_box_extents = Vector3(width, 0.0, 0.2)
	p.angle_min = 0.0; p.angle_max = 360.0
	var curve := Curve.new(); curve.add_point(Vector2(0, 0.6)); curve.add_point(Vector2(1, grow))
	curve.max_value = grow
	p.scale_amount_curve = curve
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.45)); g.set_color(1, Color(1, 1, 1, 0.0))
	p.color_ramp = g
	p.position = at
	p.emitting = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	return p


static func _foam_material() -> StandardMaterial3D:
	if _foam_mat:
		return _foam_mat
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 0.9)); g.set_color(1, Color(1, 1, 1, 0.0))
	g.add_point(0.5, Color(1, 1, 1, 0.45))
	var t := GradientTexture2D.new(); t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL; t.fill_from = Vector2(0.5, 0.5); t.fill_to = Vector2(0.5, 0.0)
	t.width = 32; t.height = 32
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = t
	m.albedo_color = Color(0.92, 0.95, 0.97)
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	_foam_mat = m
	return _foam_mat


# A convex hull round the boat: the gunwale outline on top, a narrower keel below.
func _hull_shape() -> void:
	var pts := PackedVector3Array()
	for i in 9:
		var t := i / 8.0                       # 0 = stern .. 1 = bow
		var z := LENGTH / 2 - t * LENGTH
		var w := BEAM / 2 * (0.86 + 0.14 * sin(minf(t, 0.62) / 0.62 * PI / 2))
		if t > 0.62:
			w = BEAM / 2 * pow(cos((t - 0.62) / 0.38 * PI / 2), 0.8)
		pts.append(Vector3(-w, 0.62, z)); pts.append(Vector3(w, 0.62, z))
		pts.append(Vector3(-w * 0.55, -0.36, z)); pts.append(Vector3(w * 0.55, -0.36, z))
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	var cs := CollisionShape3D.new()
	cs.shape = shape
	add_child(cs)


## The surface under p: flat canal water with a slow swell.
func water_y(p: Vector3) -> float:
	return WATER_Y + 0.025 * sin(_t * 1.3 + p.x * 0.35) + 0.02 * sin(_t * 0.9 - p.z * 0.27)


func _physics_process(dt: float) -> void:
	if freeze:                           # (moored far off, held still: nothing to work out)
		return
	_t += dt
	# Boats do not fly: a hard knock on a quay wall may not throw one up out of
	# the canal (the collision solver can push a lot harder than water lifts).
	if linear_velocity.y > 2.5:
		linear_velocity.y = 2.5
	if angular_velocity.length() > 2.5:
		angular_velocity = angular_velocity.normalized() * 2.5
	var xf := global_transform
	# Buoyancy and heave damping, point by point.
	for lp in _points:
		var p := xf * lp
		var depth := clampf(water_y(p) - p.y, 0.0, DEPTH_MAX)
		if depth <= 0.0:
			continue
		var r := p - global_position
		var vy := (linear_velocity + angular_velocity.cross(r)).y
		apply_force(Vector3.UP * (depth * _k - vy * _c * minf(1.0, depth / 0.1)), r)
	# Drag in the boat's own frame: along, across.
	var fwd := -xf.basis.z
	var side := xf.basis.x
	var flat := Vector3(linear_velocity.x, 0, linear_velocity.z)
	var va := flat.dot(fwd)
	var vs := flat.dot(side)
	var fa := -(DRAG_ALONG.x * va * absf(va) + DRAG_ALONG.y * va)
	var fs := -(DRAG_ACROSS.x * vs * absf(vs) + DRAG_ACROSS.y * vs)
	# The keel resists sideways a little ahead of the middle: in a turn the stern slides out.
	apply_force(fwd * fa)
	apply_force(side * fs, fwd * 0.3)
	# Yaw damping: the whole hull swept sideways through the water.
	var w := angular_velocity.y
	apply_torque(-Vector3.UP * (YAW_DAMP.x * w * absf(w) + YAW_DAMP.y * w))
	# The motor: thrust at the stern along the outboard's angle.
	rudder = move_toward(rudder, steer * STEER, dt * 1.8)
	var stern := xf.basis.z * (LENGTH / 2 - 0.2) + xf.basis.y * -0.25
	var dir := xf.basis * Vector3(sin(rudder), 0, -cos(rudder))
	var power := THRUST * (BOOST if boost else 1.0)
	var push := throttle * power * (1.0 if throttle > 0.0 else 0.5)
	apply_force(dir * push, stern)
	# The rudder in the flow: some steering while it only drifts.
	apply_force(side * (RUDDER * va * sin(rudder)), stern)
	_wake(absf(va))


# The wake: foam while it makes way, more the faster; spray at speed. The
# foam is kept on the surface whatever the hull does.
func _wake(v: float) -> void:
	if wake == null:
		return
	wake.emitting = v > 1.0
	bow_foam.emitting = v > 2.0
	spray.emitting = v > 4.5
	wake.speed_scale = clampf(0.6 + v / 6.0, 0.6, 1.6)
	for f in [wake, bow_foam]:
		var gp: Vector3 = (f as Node3D).global_position
		(f as Node3D).global_position = Vector3(gp.x, WATER_Y + 0.04, gp.z)


## Speed along the boat, m/s (negative astern).
func speed() -> float:
	return linear_velocity.dot(-global_transform.basis.z)


## The model-facing yaw (forward = (-sin, -cos) in x, z).
func heading() -> float:
	var f := -global_transform.basis.z
	return atan2(-f.x, -f.z)
