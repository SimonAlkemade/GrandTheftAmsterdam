extends RefCounted
## Real physics for the vehicles you drive: a VehicleBody3D with sprung,
## damped wheels (raycast suspension and tyre grip), on the chunks' ground
## collision. The traffic around you stays on its rails; a car, Canta or bike
## becomes one of these when you take it, and stays one where you leave it.
##
## A VehicleBody3D drives along its own +Z, while the models face -Z, so the
## model sits in the body turned half round.

const GROUND_LAYER := 2              # the chunks' street, bridges, quay walls and canal beds
const WALL_LAYER := 1                # buildings
const TRAFFIC_LAYER := 4             # the solid boxes of the cars, buses and trams around you
const BODY_LAYER := 8                # the vehicles you drive

# Godot scales the spring force by the mass, so under its own weight a wheel
# sinks g / (wheels * spring) metres whatever the mass: keep that well inside
# the travel (car 5 cm of 18, Canta 6 of 13, bike 3 of 10).
# mass kg; wheel radius and where the wheels are (half track, front and rear
# axle along the model's -Z); the chassis box; engine N; brake; steering;
# suspension spring, travel and damping; tyre grip.
const SPEC := {
	"car": {"mass": 1200.0, "r": 0.33, "track": 0.86, "axles": [-1.32, 1.32], "box": Vector3(1.76, 0.95, 4.1), "box_y": 0.95,
		"engine": 4200.0, "brake": 40.0, "steer": 0.55, "top": 17.0, "rev": 5.0, "spring": 45.0, "travel": 0.18,
		"damp_c": 2.6, "damp_r": 3.2, "grip": 2.6, "com": 0.45},
	"canta": {"mass": 450.0, "r": 0.22, "track": 0.5, "axles": [-0.74, 0.76], "box": Vector3(1.06, 1.15, 2.25), "box_y": 0.88,
		"engine": 1500.0, "brake": 16.0, "steer": 0.6, "top": 12.5, "rev": 3.0, "spring": 38.0, "travel": 0.13,
		"damp_c": 2.2, "damp_r": 2.8, "grip": 2.2, "com": 0.4},
	"bike": {"mass": 95.0, "r": 0.355, "track": 0.0, "axles": [-0.58, 0.56], "box": Vector3(0.5, 0.7, 1.5), "box_y": 0.95,
		"engine": 420.0, "boost": 680.0, "brake": 4.0, "steer": 0.5, "top": 5.5, "top_boost": 8.5, "rev": 1.0, "spring": 150.0,
		"travel": 0.1, "damp_c": 8.0, "damp_r": 10.0, "grip": 1.6, "com": 0.55},   # the box clears the hubs
}


## A body for `kind` at `xf` (a model-facing transform), carrying `visual`.
## The visual's wheels move onto the physics wheels, so they steer, spin and
## ride the suspension (the bike keeps its own wheels: its rig turns them).
static func make(kind: String, visual: Node3D, xf: Transform3D) -> VehicleBody3D:
	var s: Dictionary = SPEC[kind]
	var b := VehicleBody3D.new()
	b.mass = s.mass
	b.collision_layer = BODY_LAYER
	b.collision_mask = GROUND_LAYER | WALL_LAYER | TRAFFIC_LAYER | BODY_LAYER
	b.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	b.center_of_mass = Vector3(0, s.com, 0)
	b.continuous_cd = true
	b.can_sleep = true
	if kind == "bike":
		# Two wheels in a line cannot stand; a real rider balances it. Lock
		# roll and pitch, and show the lean the turn calls for instead.
		b.axis_lock_angular_x = true
		b.axis_lock_angular_z = true
	var shape := BoxShape3D.new()
	shape.size = s.box
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = s.box_y
	b.add_child(cs)
	b.transform = Transform3D(xf.basis * Basis(Vector3.UP, PI), xf.origin)
	# The model, turned to face the body's +Z (without the solid box it had in traffic).
	for solid in visual.find_children("*", "AnimatableBody3D", true, false):
		solid.free()
	if visual.get_parent():
		visual.get_parent().remove_child(visual)
	visual.transform = Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	b.add_child(visual)
	var meshes := _wheel_meshes(kind, visual)
	var k := 0
	for z in s.axles:                     # model -Z (front) is the body's +Z
		for x in ([-s.track, s.track] if s.track > 0.0 else [0.0]):
			var w := VehicleWheel3D.new()
			w.wheel_radius = s.r
			w.wheel_rest_length = s.travel
			w.suspension_travel = s.travel
			w.suspension_stiffness = s.spring
			w.suspension_max_force = s.mass * 9.81 * 2.0
			w.damping_compression = s.damp_c
			w.damping_relaxation = s.damp_r
			w.wheel_friction_slip = s.grip
			w.wheel_roll_influence = 0.15
			var front: bool = z < 0.0
			w.use_as_steering = front
			w.use_as_traction = not front if kind != "canta" else front   # the Canta pulls with its front wheels
			# Model (x, z) -> body (-x, -z); the hub sits at rest above the ground.
			w.position = Vector3(-x, s.r + s.travel * 0.6, -z)
			b.add_child(w)
			if k < meshes.size():
				var m: Node3D = meshes[k]
				var keep := _relative(m, visual)
				m.owner = null
				m.get_parent().remove_child(m)
				w.add_child(m)
				m.transform = Transform3D(Basis(Vector3.UP, PI) * keep.basis, Vector3.ZERO)
			k += 1
	return b


static func _relative(n: Node3D, root: Node3D) -> Transform3D:
	var xf := n.transform
	var p := n.get_parent()
	while p != null and p != root:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


# The visual's wheels, in the order the physics wheels are made (front left,
# front right, rear left, rear right in the model's own frame).
static func _wheel_meshes(kind: String, visual: Node3D) -> Array:
	if kind == "bike":
		return []
	var found := visual.find_children("wheel*", "Node3D", true, false)
	var order := []
	for want in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:   # (x sign, z sign): -z is the front
		for n in found:
			var p: Vector3 = (n as Node3D).position
			if signf(p.x) == want.x and signf(p.z) == want.y and not order.has(n):
				order.append(n)
				break
	return order


## One physics frame of driving. Returns the speed along the vehicle (m/s,
## negative backwards).
static func drive(b: VehicleBody3D, kind: String, throttle: float, steer: float, brake: bool, boost: bool, dt: float) -> float:
	var s: Dictionary = SPEC[kind]
	var fwd := b.global_transform.basis.z
	var v := b.linear_velocity.dot(fwd)
	# Steering eases in, and less of it at speed.
	var lock: float = s.steer * clampf(1.0 - absf(v) / (s.top * 1.6), 0.3, 1.0)
	b.steering = move_toward(b.steering, steer * lock, dt * 2.2)
	var top: float = s.get("top_boost", s.top) if boost else s.top
	var engine: float = s.get("boost", s.engine) if boost else s.engine
	b.engine_force = 0.0
	b.brake = 0.0
	if brake:
		b.brake = s.brake
	elif throttle > 0.0:
		if v < -0.5:
			b.brake = s.brake               # moving backwards: brake first
		else:
			b.engine_force = engine * clampf(1.0 - v / top, 0.0, 1.0)
	elif throttle < 0.0:
		if v > 0.5:
			b.brake = s.brake
		else:
			b.engine_force = -engine * 0.6 * clampf(1.0 + v / s.rev, 0.0, 1.0)
	else:
		b.brake = s.brake * 0.04            # rolling resistance
	if b.engine_force != 0.0 or b.steering != 0.0:
		b.sleeping = false
	return v


## Leave it where it is, handbrake on.
static func park(b: VehicleBody3D) -> void:
	b.engine_force = 0.0
	b.steering = 0.0
	b.brake = SPEC.car.brake


## The model-facing yaw (forward = (-sin, -cos) in x, z) of a body.
static func heading(b: VehicleBody3D) -> float:
	var f := b.global_transform.basis.z
	return atan2(-f.x, -f.z)
