extends SceneTree
## Into the water with a car: WASTED. Drive a car (Canta, bus) into a canal
## or the IJ and, once it has gone in, you are wasted: the hospital bill, back
## on your feet at the start, the car left in the water. Not at once (you see
## it go in), and not on a bike: off a bike you swim.
##     godot --headless --path godot-city --script tests/canal_test.gd

const Walker := preload("res://scripts/walker.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")
const VPhys := preload("res://scripts/vehicle_physics.gd")
const Models := preload("res://scripts/vehicle_models.gd")
const BikeRig := preload("res://scripts/bike_rig.gd")

class Canal:                          # water everywhere
	var tiles := {}
	func water_at(_p: Vector3) -> int: return 1
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return ""
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

class Purse:
	var money := 0

var _fails := 0
var w
var crime
var purse
var said := []


func _initialize() -> void:
	var traffic = Traffic.new()
	traffic.enabled = false
	root.add_child(traffic)
	w = Walker.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(Canal.new(), cam)
	w.traffic = traffic
	root.add_child(w)
	purse = Purse.new()
	crime = Crime.new()
	root.add_child(crime)
	crime.setup(w.streamer, traffic, w, purse)
	crime.announce.connect(func(t, s): said.append([t, s]); print("  [%s] %s" % [t, s]))
	w.crime = crime
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


# Into the water with `kind`: the body under the water line, you at its wheel.
func _sink(kind: String) -> Dictionary:
	var visual: Node3D
	if kind == "bike":
		visual = BikeRig.new()
		visual.build("oma", Color("2f4f3a"))
	else:
		visual = Models.car(Color("2c4a6e"))
	var node := Node3D.new()
	root.add_child(node)
	node.add_child(visual)
	var b: VehicleBody3D = VPhys.make(kind, visual, Transform3D(Basis(), Vector3(0, -2.0, 0)))
	node.add_child(b)
	var v := {"kind": kind, "body": b, "driver": true, "rig": visual, "node": node, "parts": [[b, 0.0, 4.2]]}
	w.vehicle = v
	w._sunk_t = 0.0
	return v


func _seconds(s: float) -> void:
	for i in int(s * 60):
		if w.vehicle != null and w.vehicle.get("driver", false):
			w._drive(1.0 / 60.0)
		crime._physics_process(1.0 / 60.0)
		await process_frame


func _run() -> void:
	w.set_physics_process(false); crime.set_physics_process(false)
	w.active = true
	crime.state = "shop"                # (as the game has it from the start: crime.start())
	purse.money = 400
	# A car into the canal.
	var car := _sink("car")
	await _seconds(1.0)
	_check(said.is_empty() and w.vehicle == car, "the first second: the car goes in, you are still at the wheel")
	await _seconds(1.0)
	var wasted: Array = said.filter(func(x): return x[0] == "WASTED")
	_check(wasted.size() == 1, "then: WASTED")
	_check(wasted.size() == 1 and String(wasted[0][1]).begins_with("You drove into the canal"), "and why")
	_check(w.vehicle == null and w.health == w.MAX_HEALTH, "out of the car, back to full health")
	_check(w.global_position.distance_to(Vector3(5, 0, 5)) < 0.5, "back at the start")
	_check(purse.money == 400 - Crime.HOSPITAL, "the hospital bill (€%d left)" % purse.money)
	_check(is_instance_valid(car.body) and car.body.global_position.y < -1.0, "the car is left in the water")
	# Off a bike into the canal: you swim, nothing more.
	said.clear()
	_sink("bike")
	await _seconds(3.0)
	_check(said.is_empty(), "a bike in the canal is not WASTED")
	print("canal test: %d failed" % _fails)
	quit(1 if _fails else 0)
