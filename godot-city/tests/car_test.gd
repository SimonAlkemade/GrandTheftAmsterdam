extends SceneTree
## The handling of the cars you drive, measured on a flat test ground:
## acceleration, top speed, braking, reversing, a handbrake slide and catching
## it, fast cornering without rolling over, and steering in the air.
##     godot --headless --path godot-city --script tests/car_test.gd [-- --kind=canta]

const VPhys := preload("res://scripts/vehicle_physics.gd")
# What each kind should do: the reference speed (m/s) and its name, seconds
# from 0 to it, top speed and stopping distance from it (null: not checked),
# the speeds of the cornering and handbrake tests (handbrake 0: not tested),
# and the least and most roll at full lock.
const EXPECT := {
	"car": {"ref": 27.78, "to": [4.0, 9.0], "top": [115.0, 170.0], "stop": [25.0, 55.0], "corner": 22.0, "hb": 17.0, "roll": [1.0, 15.0]},
	"canta": {"ref": 10.0, "to": [2.0, 8.0], "top": [40.0, 60.0], "stop": null, "corner": 10.0, "hb": 9.0, "roll": [1.0, 15.0]},
	"bus": {"ref": 13.89, "to": [7.0, 20.0], "top": [65.0, 95.0], "stop": [15.0, 45.0], "corner": 11.0, "hb": 0.0, "roll": [1.5, 12.0]},
}
const Models := preload("res://scripts/vehicle_models.gd")

var kind := "car"
var _fails := 0
var _b: VehicleBody3D
# Inputs held each physics frame: throttle -1..1, steer -1 (right)..1 (left), handbrake.
var throttle := 0.0
var steer := 0.0
var handbrake := false


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--kind="): kind = a.substr(7)
	var ground := StaticBody3D.new()
	ground.collision_layer = VPhys.GROUND_LAYER
	var cs := CollisionShape3D.new()
	cs.shape = WorldBoundaryShape3D.new()
	ground.add_child(cs)
	root.add_child(ground)
	physics_frame.connect(_drive)
	_run.call_deferred()


func _drive() -> void:
	if _b:
		VPhys.drive(_b, kind, throttle, steer, handbrake, false, 1.0 / 60.0)


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _fresh(at := Vector3.ZERO, yaw := 0.0) -> void:
	if _b: _b.queue_free()
	var visual: Node3D = Models.canta(Color("9e0b10")) if kind == "canta" else (Models.bus() if kind == "bus" else Models.car(Color("2c4a6e")))
	root.add_child(visual)
	_b = VPhys.make(kind, visual, Transform3D(Basis(Vector3.UP, yaw), at + Vector3(0, 0.1, 0)))
	root.add_child(_b)
	throttle = 0.0; steer = 0.0; handbrake = false


func _frames(n: int) -> void:
	for i in n:
		await physics_frame


# Full throttle until v m/s (or 20 s, if it never gets there).
func _reach(v: float) -> void:
	throttle = 1.0
	for i in 60 * 20:
		if _speed() >= v: return
		await physics_frame


func _front_z() -> float:
	return _b.global_position.z + _b.global_transform.basis.z.z * (VPhys.SPEC[kind].box.z / 2.0)


func _speed() -> float:
	return _b.linear_velocity.dot(_b.global_transform.basis.z)    # the body drives along its +Z


func _yaw() -> float:
	return VPhys.heading(_b)


func _roll() -> float:
	return rad_to_deg(acos(clampf(_b.global_transform.basis.y.dot(Vector3.UP), -1.0, 1.0)))


# The angle between where the car points and where it goes, degrees.
func _slip() -> float:
	var v := Vector3(_b.linear_velocity.x, 0, _b.linear_velocity.z)
	if v.length() < 2.0: return 0.0
	var f := _b.global_transform.basis.z
	return rad_to_deg(absf(atan2(v.dot(_b.global_transform.basis.x), v.dot(f))))


# Ram a stopped street car at 50 km/h (a Canta at what it can): it turns into a real car just before
# the hit and is shunted, and your car carries on (it was not a wall).
func _crash() -> void:
	var Traffic = load("res://scripts/traffic.gd")
	var Walker = load("res://scripts/walker.gd")
	var traffic = Traffic.new()
	traffic.enabled = false
	root.add_child(traffic)
	var model: Node3D = Models.car(Color("7a1e1e"))
	Models.solid(model, Vector3(1.8, 1.3, 4.2), 0.75)
	var node := Node3D.new(); node.add_child(model); traffic.add_child(node)
	var tz := -95.0 if kind == "bus" else -40.0   # a bus needs a longer run-up
	model.position = Vector3(60.0, 0.09, tz)
	model.rotation.y = PI / 2                  # broadside across your path
	var target := {"kind": "car", "edge": -1, "dir": 1, "s": 0.0, "speed": 0.0, "pos": Vector2(60, tz), "parts": [[model, 0.0, 4.2]], "node": node}
	traffic.vehicles.append(target)
	var w = Walker.new()
	root.add_child(w)
	w.traffic = traffic
	_fresh(Vector3(60, 0, 0), 0.0)              # facing -Z, at the parked car (away from the last test's)
	w.vehicle = {"kind": "car", "body": _b}
	await _reach(minf(13.9, VPhys.SPEC[kind].top * 0.8))
	throttle = 0.4
	var before := 0.0
	for i in 60 * 6:
		w._knock_traffic(w._front_of(_b, kind), Vector2(_b.linear_velocity.x, _b.linear_velocity.z))
		await physics_frame
		if _front_z() > tz + 7.0: before = _speed()
		if target.has("body") or _front_z() < tz + 0.5: break
	await _frames(30)
	var after := _speed()
	_check(target.has("body"), "a car you are about to hit becomes a real car")
	if target.has("body"):
		var tb: VehicleBody3D = target.body
		await _frames(30)
		var moved := Vector2(tb.global_position.x - 60.0, tb.global_position.z - tz).length()
		print("crash at %.0f km/h: you carry on at %.0f km/h, the other car is shoved %.1f m" % [before * 3.6, after * 3.6, moved])
		if kind != "canta":                # (a 450 kg Canta bounces off a 1250 kg car, as it should)
			_check(moved > 1.5, "the crash shoves it (%.1f m)" % moved)
			_check(after > before * 0.15, "and you are not stopped dead (%.0f of %.0f km/h)" % [after * 3.6, before * 3.6])


func _run() -> void:
	var x: Dictionary = EXPECT[kind]
	var hundred: float = x.ref
	_fresh()
	await _frames(60)
	# Full throttle from a standstill.
	throttle = 1.0
	var t_to := -1.0
	var top := 0.0
	for i in 60 * 40:
		await physics_frame
		top = maxf(top, _speed())
		if t_to < 0.0 and _speed() >= hundred: t_to = i / 60.0
	print("0-%.0f km/h: %.1f s, top speed %.0f km/h" % [hundred * 3.6, t_to, top * 3.6])
	_check(t_to > x.to[0] and t_to < x.to[1], "0-%.0f km/h in %.0f-%.0f s (%.1f s)" % [hundred * 3.6, x.to[0], x.to[1], t_to])
	_check(top * 3.6 > x.top[0] and top * 3.6 < x.top[1], "top speed %.0f-%.0f km/h (%.0f)" % [x.top[0], x.top[1], top * 3.6])
	# Brake from the reference speed (S): stopping distance.
	_fresh(); throttle = 1.0
	await _reach(hundred)
	var from := _b.global_position
	throttle = -1.0
	var frames := 0
	while _speed() > 0.3 and frames < 600:
		await physics_frame; frames += 1
	var dist := Vector2(_b.global_position.x - from.x, _b.global_position.z - from.z).length()
	print("braking from %.0f km/h: %.1f m in %.1f s" % [hundred * 3.6, dist, frames / 60.0])
	if x.stop != null:
		_check(dist > x.stop[0] and dist < x.stop[1], "stops from %.0f km/h in %.0f-%.0f m (%.1f m)" % [hundred * 3.6, x.stop[0], x.stop[1], dist])
	# Keep S held: it reverses.
	await _frames(120)
	_check(_speed() < -1.5, "holding S at a standstill reverses (%.1f m/s)" % _speed())
	# The steering sign: left steer turns left (heading grows).
	_fresh(); throttle = 0.6
	await _frames(90)
	var y0 := _yaw(); steer = 1.0
	await _frames(40)
	_check(wrapf(_yaw() - y0, -PI, PI) > 0.05, "A turns left")
	# Full lock at speed: it corners hard without rolling over.
	_fresh(); throttle = 1.0
	var corner: float = x.corner
	await _reach(corner)
	throttle = 0.4; steer = 1.0
	var roll := 0.0
	for i in 60 * 4:
		await physics_frame
		roll = maxf(roll, _roll())
	print("full lock at %.0f km/h: most roll %.1f°, still %.0f km/h" % [corner * 3.6, roll, _speed() * 3.6])
	_check(roll < x.roll[1], "stays on its wheels at full lock (roll %.1f°)" % roll)
	_check(roll > x.roll[0], "but leans into the corner (roll %.1f°)" % roll)
	if x.hb > 0.0:
		await _handbrake(x.hb)
	# In the air, A/D roll it and W/S pitch it.
	_fresh(Vector3(0, 6, 0)); steer = 1.0
	await _frames(20)
	var w: Vector3 = _b.angular_velocity * _b.global_transform.basis   # in the car's frame
	_check(absf(w.z) > 0.3, "A/D roll it in the air (%.2f rad/s)" % w.z)
	steer = 0.0
	await _frames(150)
	await _crash()
	print("car test (%s): %d failed" % [kind, _fails])
	quit(1 if _fails else 0)


# Handbrake at speed with a flick of steering: the tail comes round, and
# letting go with the wheel straight and some throttle, it gathers itself.
func _handbrake(hb: float) -> void:
	_fresh(); throttle = 1.0
	await _reach(hb)
	throttle = 0.0; steer = 1.0; handbrake = true
	var slip := 0.0
	var y1 := _yaw()
	for i in 60:
		await physics_frame
		slip = maxf(slip, _slip())
	var swung := absf(wrapf(_yaw() - y1, -PI, PI))
	print("handbrake turn from %.0f km/h: slide %.0f°, turned %.0f° in 1 s" % [hb * 3.6, slip, rad_to_deg(swung)])
	_check(slip > 20.0, "the handbrake kicks the tail out (slide %.0f°)" % slip)
	_check(rad_to_deg(swung) < 130.0, "but does not spin it (%.0f° in 1 s)" % rad_to_deg(swung))
	handbrake = false; steer = 0.0; throttle = 0.5
	var recovered := -1.0
	for i in 60 * 4:
		await physics_frame
		if recovered < 0.0 and _slip() < 8.0: recovered = i / 60.0
	_check(recovered >= 0.0 and recovered < 2.5, "and straightens up after it (%.1f s)" % recovered)
	_check(_roll() < 20.0, "on its wheels (roll %.0f°)" % _roll())
