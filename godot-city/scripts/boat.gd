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


func _init() -> void:
	mass = MASS
	collision_layer = 8           # VehiclePhysics.BODY_LAYER
	collision_mask = 1 | 2 | 4 | 8   # buildings, the quay walls and canal bed, traffic, other boats
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, -0.12, 0)
	continuous_cd = true
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
	_t += dt
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


## Speed along the boat, m/s (negative astern).
func speed() -> float:
	return linear_velocity.dot(-global_transform.basis.z)


## The model-facing yaw (forward = (-sin, -cos) in x, z).
func heading() -> float:
	var f := -global_transform.basis.z
	return atan2(-f.x, -f.z)
