extends SceneTree
## Pedestrians keep their distance: one walking straight at you veers off and
## walks on, two meeting head-on pass each other, in a crowd nobody ever
## overlaps anyone, you included; and with traffic: they wait for a car to
## cross their way, hurry out of the path of one coming at them, walk round a
## parked bus, and let a tram go by, never once inside a vehicle.
##     godot --headless --path godot-city --script tests/peds_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Models := preload("res://scripts/vehicle_models.gd")


# The city as far as pedestrians need it: open street everywhere.
class OpenStreet:
	func water_at(_p: Vector3) -> int:
		return 0


var _fails := 0
var w
var traffic
var rng := RandomNumberGenerator.new()


func _initialize() -> void:
	w = Walker.new()
	w.streamer = OpenStreet.new()
	traffic = Traffic.new()
	traffic.enabled = false                     # these vehicles are moved by hand below
	root.add_child(traffic)
	w.traffic = traffic
	root.add_child(w)
	w.global_position = Vector3.ZERO
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _ped(at: Vector3, heading: float) -> Dictionary:
	var p := {"h": Human.new(), "pos": at, "heading": heading, "speed": 1.3, "turn": 1e9, "stag": 0.0}
	p.h.random_look(rng)
	root.add_child(p.h)
	w.peds.append(p)
	return p


func _clear() -> void:
	for p in w.peds: p.h.queue_free()
	w.peds.clear()


# Heading that walks from a towards b.
func _toward(a: Vector3, b: Vector3) -> float:
	var d := b - a
	return atan2(-d.x, -d.z)


func _run() -> void:
	rng.seed = 3
	# 1. Someone walks straight at you, standing still.
	var p := _ped(Vector3(0, 0, -8), _toward(Vector3(0, 0, -8), Vector3.ZERO))
	var closest := INF
	for i in 60 * 12:
		w._peds(1.0 / 60.0)
		closest = minf(closest, Vector2(p.pos.x, p.pos.z).length())
		await process_frame
	print("walking at you: closest %.2f m, ended %.1f m away" % [closest, Vector2(p.pos.x, p.pos.z).length()])
	_check(closest > 1.4, "someone walking straight at you veers off (closest %.2f m)" % closest)
	_check(Vector2(p.pos.x, p.pos.z).length() > 5.0, "and walks on past you")
	_clear()
	# 2. Two people meet head-on, 10 m apart, away from you.
	var a := _ped(Vector3(20, 0, -5), PI)            # heading +Z
	var b := _ped(Vector3(20, 0, 5), 0.0)            # heading -Z
	closest = INF
	for i in 60 * 12:
		w._peds(1.0 / 60.0)
		closest = minf(closest, (a.pos - b.pos).length())
		await process_frame
	print("head-on: closest %.2f m; a at z %.1f, b at z %.1f" % [closest, a.pos.z, b.pos.z])
	_check(closest > 0.85, "two people meeting head-on keep apart (closest %.2f m)" % closest)
	_check(a.pos.z > 3.0 and b.pos.z < -3.0, "and pass each other")
	_clear()
	# 3. A crowd of 20 milling round you in 12 x 12 m.
	for k in 20:
		var pt := Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-6, 6))
		if pt.length() < 1.2: pt = pt.normalized() * 2.0 if pt.length() > 0.01 else Vector3(2, 0, 0)
		var q := _ped(pt, rng.randf() * TAU)
		q.turn = rng.randf_range(0.5, 3.0)
	var worst_pair := INF
	var worst_you := INF
	for i in 60 * 10:
		w._peds(1.0 / 60.0)
		for x in w.peds.size():
			var q: Dictionary = w.peds[x]
			worst_you = minf(worst_you, Vector2(q.pos.x, q.pos.z).length())
			for y in range(x + 1, w.peds.size()):
				var r: Dictionary = w.peds[y]
				worst_pair = minf(worst_pair, Vector2(q.pos.x - r.pos.x, q.pos.z - r.pos.z).length())
		await process_frame
	print("crowd: closest pair %.2f m, closest to you %.2f m" % [worst_pair, worst_you])
	_check(worst_pair >= Walker.PED_GAP - 0.05, "in a crowd nobody overlaps (closest pair %.2f m)" % worst_pair)
	_check(worst_you >= Walker.YOU_GAP - 0.05, "and nobody walks into you (closest %.2f m)" % worst_you)
	_clear()
	await _vehicles()
	print("peds test: %d failed" % _fails)
	quit(1 if _fails else 0)


# A vehicle as Traffic keeps one, heading along `dir` (x, z) at `speed`.
func _vehicle(kind: String, at: Vector2, dir: Vector2, speed: float) -> Dictionary:
	var root3 := Node3D.new(); traffic.add_child(root3)
	var v := {"kind": kind, "speed": speed, "pos": at, "parts": [], "node": root3, "parked": speed == 0.0}
	var yaw := atan2(-dir.x, -dir.y)
	var lens: Array = Traffic.TRAM_SECTIONS if kind == "tram" else [4.2 if kind == "car" else 12.0]
	var off := 0.0
	for L in lens:
		var n := Node3D.new(); root3.add_child(n)
		var c: Vector2 = at - dir * (off + float(L) / 2.0)
		n.position = Vector3(c.x, 0, c.y); n.rotation.y = yaw
		v.parts.append([n, off, L])
		off += L + 0.5
	traffic.vehicles.append(v)
	return v


func _drive(v: Dictionary, dir: Vector2, dt: float) -> void:
	for part in v.parts:
		part[0].position += Vector3(dir.x, 0, dir.y) * v.speed * dt


# How far a pedestrian is from a vehicle's body (from its side), metres.
func _gap(p: Dictionary, v: Dictionary) -> float:
	var best := INF
	for part in v.parts:
		var n: Node3D = part[0]
		var ax: Vector2 = Vector2(-sin(n.rotation.y), -cos(n.rotation.y)) * (float(part[2]) / 2.0)
		var c := Vector2(n.position.x, n.position.z)
		best = minf(best, Geometry2D.get_closest_point_to_segment(Vector2(p.pos.x, p.pos.z), c - ax, c + ax).distance_to(Vector2(p.pos.x, p.pos.z)))
	return best - float(Walker.HALF_WIDTH[v.kind])


func _vehicles() -> void:
	w.global_position = Vector3(0, 0, 60)             # you stand out of the way (but near enough for them to be about)
	var dt := 1.0 / 60.0
	# A. A car at 30 km/h along +x crosses where a pedestrian walking north
	#    (-z) would be: she waits for it, then crosses.
	var east := Vector2(1, 0)
	var car := _vehicle("car", Vector2(-30, 0), east, 8.3)
	var p := _ped(Vector3(0, 0, 6), 0.0)              # heading -Z, across the car's way
	var closest := INF
	for i in 60 * 12:
		w._peds(dt); _drive(car, east, dt)
		closest = minf(closest, _gap(p, car))
		await process_frame
	print("crossing: closest %.2f m from the car's side, ended at z %.1f" % [closest, p.pos.z])
	_check(closest > 0.7, "she waits for a car to cross her way (closest %.2f m from its side)" % closest)
	_check(p.pos.z < -3.0, "and then crosses (z %.1f)" % p.pos.z)
	_clear(); traffic.vehicles.clear()
	# B. A car comes straight at a pedestrian walking along its road.
	car = _vehicle("car", Vector2(-40, 0), east, 8.3)
	p = _ped(Vector3(0, 0, 0.2), -PI / 2)              # heading +x too, slowly, in the lane
	closest = INF
	for i in 60 * 10:
		w._peds(dt); _drive(car, east, dt)
		closest = minf(closest, _gap(p, car))
		await process_frame
	print("in the road: closest %.2f m from the car's side" % closest)
	_check(closest > 0.25, "he gets out of the way of a car coming at him (closest %.2f m)" % closest)
	_clear(); traffic.vehicles.clear()
	# C. A parked bus across a pedestrian's way: round it, never into it.
	var bus := _vehicle("bus", Vector2(6, 0), east, 0.0)   # its body from x = -6 to 6
	p = _ped(Vector3(0, 0, 8), 0.0)                    # heading -Z, straight at its middle
	closest = INF
	for i in 60 * 30:
		w._peds(dt)
		closest = minf(closest, _gap(p, bus))
		await process_frame
	print("parked bus: closest %.2f m from its side, ended at %s" % [closest, p.pos.snapped(Vector3.ONE * 0.1)])
	_check(closest >= Walker.VEHICLE_GAP - 0.05, "never walks into a parked bus (closest %.2f m)" % closest)
	_check(p.pos.z < -2.0 or absf(p.pos.x) > 7.0, "and finds a way round it")
	_clear(); traffic.vehicles.clear()
	# D. A 27 m tram at 40 km/h: wait until all three sections are by.
	var tram := _vehicle("tram", Vector2(-40, 0), east, 11.0)
	p = _ped(Vector3(0, 0, 5), 0.0)
	closest = INF
	for i in 60 * 12:
		w._peds(dt); _drive(tram, east, dt)
		closest = minf(closest, _gap(p, tram))
		await process_frame
	print("tram: closest %.2f m from its side, ended at z %.1f" % [closest, p.pos.z])
	_check(closest > 0.7, "she lets a tram go by (closest %.2f m)" % closest)
	_check(p.pos.z < -3.0, "and crosses behind it")
