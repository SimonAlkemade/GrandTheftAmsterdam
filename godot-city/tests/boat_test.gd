extends SceneTree
## The sloep floats, holds level, glides, steers and drifts.
##     godot --headless --path godot-city --script tests/boat_test.gd

const Boat := preload("res://scripts/boat.gd")

var _fails := 0


func _initialize() -> void:
	var bed := StaticBody3D.new()               # the canal bed, as the chunks build it
	bed.collision_layer = 2
	var shape := WorldBoundaryShape3D.new()
	var cs := CollisionShape3D.new(); cs.shape = shape
	bed.add_child(cs)
	bed.position.y = -2.6
	root.add_child(bed)
	_run.call_deferred()


# A quay wall across the canal at z, two-sided triangles from the bed to the
# street, as the chunks build it.
func _quay(z: float) -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = 2
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	var a := Vector3(-30, -2.6, z); var b := Vector3(30, -2.6, z)
	var c := Vector3(30, 0.09, z); var d := Vector3(-30, 0.09, z)
	var e := Vector3(-30, 0.09, z - 20); var f := Vector3(30, 0.09, z - 20)
	shape.set_faces(PackedVector3Array([a, b, c, a, c, d, d, c, f, d, f, e]))
	var cs := CollisionShape3D.new(); cs.shape = shape
	wall.add_child(cs)
	root.add_child(wall)


func _step(n: int) -> void:
	for i in n:
		await physics_frame


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _run() -> void:
	var b: RigidBody3D = Boat.new()
	root.add_child(b)
	# Dropped in from half a metre up, it settles at its waterline, level.
	b.global_position = Vector3(0, Boat.WATER_Y + 0.5, 0)
	await _step(60 * 8)
	var y := b.global_position.y
	_check(absf(y - Boat.WATER_Y) < 0.06, "floats at its waterline (y %.3f, water %.2f)" % [y, Boat.WATER_Y])
	_check(absf(b.rotation.x) < 0.03 and absf(b.rotation.z) < 0.03, "floats level (pitch %.3f roll %.3f)" % [b.rotation.x, b.rotation.z])
	# Heeled over, it rights itself.
	b.rotation.z = 0.35
	await _step(60 * 5)
	_check(absf(b.rotation.z) < 0.04, "rights itself after a 20 degree heel (roll %.3f)" % b.rotation.z)
	# Full ahead.
	b.throttle = 1.0
	await _step(60 * 10)
	var v: float = b.speed()
	_check(v > 5.0 and v < 9.0, "full ahead makes way (%.2f m/s)" % v)
	_check(absf(b.global_position.y - Boat.WATER_Y) < 0.25, "and stays on the water (y %.3f)" % b.global_position.y)
	# Let go: it glides on.
	b.throttle = 0.0
	await _step(60 * 2)
	var glide: float = b.speed()
	_check(glide > 1.2, "glides on with the motor off (%.2f m/s after 2 s)" % glide)
	await _step(60 * 20)
	_check(absf(b.speed()) < 0.3, "and comes to rest (%.2f m/s)" % b.speed())
	# Left rudder under power turns left (heading grows), and the stern slides out.
	var h: float = b.heading()
	var turned := 0.0
	var slide := 0.0
	b.throttle = 1.0; b.steer = 1.0
	for i in 180:
		await physics_frame
		turned += wrapf(b.heading() - h, -PI, PI); h = b.heading()
		slide = maxf(slide, absf(b.linear_velocity.dot(b.global_transform.basis.x)))
	_check(turned > 0.8 and turned < 3.0, "left rudder turns it left (%.2f rad in 3 s)" % turned)
	_check(slide > 0.15, "drifts sideways in the turn (%.2f m/s across)" % slide)
	var rate := absf(b.angular_velocity.y)
	_check(rate < 1.2, "turns at a boat's pace (%.2f rad/s)" % rate)
	# Rammed into a quay wall at full power, it stays in the canal.
	b.throttle = 0.0; b.steer = 0.0
	b.rudder = 0.0
	b.linear_velocity = Vector3.ZERO; b.angular_velocity = Vector3.ZERO
	b.global_transform = Transform3D(Basis(Vector3.UP, 0.25), Vector3(0, Boat.WATER_Y, 0))
	_quay(-45.0)
	await _step(30)
	b.throttle = 1.0; b.boost = true
	var top := -10.0
	var tilt := 0.0
	for i in 60 * 14:
		await physics_frame
		top = maxf(top, b.global_position.y)
		tilt = maxf(tilt, maxf(absf(b.rotation.x), absf(b.rotation.z)))
	_check(top < Boat.WATER_Y + 0.8, "rams a quay wall without leaving the water (highest y %.2f)" % top)
	_check(b.global_position.z > -45.0, "and does not go through it (z %.2f)" % b.global_position.z)
	_check(tilt < 0.6, "nor tip over (most tilt %.2f rad)" % tilt)
	print("boat test: %d failed" % _fails)
	quit(1 if _fails else 0)
