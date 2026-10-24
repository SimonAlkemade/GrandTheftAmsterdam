extends SceneTree
## The street traffic's physics on a test layout: cars dip their nose braking
## for a bend and roll out of it, cyclists lean into it, and a tram you drive
## pulls away, brakes, coasts and takes the branch you choose like a tram.
##     godot --headless --path godot-city --script tests/traffic_test.gd

const Traffic := preload("res://scripts/traffic.gd")

var _fails := 0
var traffic


func _initialize() -> void:
	traffic = Traffic.new()
	root.add_child(traffic)
	traffic.set_process(false)      # stepped by hand below, in exact 1/60 s steps
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


# A rounded square of road, `half` metres from the middle to each side.
func _ring(half: float, r: float) -> PackedVector2Array:
	var p := PackedVector2Array()
	var corners := [Vector2(half - r, half - r), Vector2(-(half - r), half - r), Vector2(-(half - r), -(half - r)), Vector2(half - r, -(half - r))]
	for c in 4:
		for k in 9:
			var a := (c + k / 8.0) * PI / 2.0
			p.append(corners[c] + Vector2(cos(a), sin(a)) * r)
	p.append(p[0])
	return p


# A gentle curve that leaves `from` heading east and bends away to `to`.
func _arc(from: Vector2, to: Vector2) -> PackedVector2Array:
	var p := PackedVector2Array()
	for k in 31:
		var t := k / 30.0
		p.append(Vector2(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t * t))
	return p


# One 1/60 s step of the traffic (headless frames come as fast as they can).
func _step() -> void:
	traffic._process(1.0 / 60.0)
	await process_frame


# Steps until cond() holds (or 60 s), keeping the focus on the tram.
func _until(v: Dictionary, cond: Callable) -> void:
	for i in 60 * 60:
		if cond.call(): return
		traffic.focus = Vector3(v.pos.x, 0, v.pos.y)
		await _step()
	print("(gave up waiting: speed %.1f, edge %d)" % [v.speed, v.edge])


func _run() -> void:
	await _bodies()
	await _tram()
	print("traffic test: %d failed" % _fails)
	quit(1 if _fails else 0)


func _bodies() -> void:
	traffic.add_tile("ring", [{"kind": "road", "w": 8.0, "p": _ring(130.0, 60.0)}])   # wide bends, taken at speed
	traffic.focus = Vector3.ZERO
	traffic.target = {"car": 3, "bus": 0, "tram": 0, "bike": 3, "canta": 0}
	var dip := 0.0
	var roll_wrong := 0
	var roll_right := 0
	var lean_right := 0
	var lean_wrong := 0
	var most_roll := 0.0
	var last := {}
	for i in 60 * 40:
		await _step()
		for v in traffic.vehicles:
			var id: int = v.node.get_instance_id()     # (a Dictionary key is its content, which moves)
			if not v.has("spring") or not last.has(id):
				last[id] = v.get("body_yaw", 0.0)
				continue
			var rate: float = wrapf(v.body_yaw - last[id], -PI, PI)
			last[id] = v.body_yaw
			var sp: Array = v.spring
			if v.kind == "car":
				dip = minf(dip, sp[0])
				most_roll = maxf(most_roll, absf(sp[2]))
				if absf(rate) > 0.004 and absf(sp[2]) > 0.004:
					if sp[2] * rate < 0.0: roll_right += 1
					else: roll_wrong += 1
			elif v.kind == "bike" and absf(rate) > 0.004 and absf(sp[2]) > 0.01:
				if sp[2] * rate > 0.0: lean_right += 1
				else: lean_wrong += 1
	print("cars: nose dip %.1f°, most roll %.1f° (outwards %d frames, inwards %d); bikes lean in %d frames, out %d" % [
		rad_to_deg(dip), rad_to_deg(most_roll), roll_right, roll_wrong, lean_right, lean_wrong])
	_check(dip < -deg_to_rad(0.8), "a car dips its nose braking for the bend (%.1f°)" % rad_to_deg(dip))
	_check(most_roll > deg_to_rad(0.8) and most_roll < deg_to_rad(8.0), "and rolls in it, but not over (%.1f°)" % rad_to_deg(most_roll))
	_check(roll_right > roll_wrong * 3, "rolling outwards, away from the turn")
	_check(lean_right > lean_wrong * 3 and lean_right > 0, "cyclists lean into their turns")
	traffic.clear()
	traffic.remove_tile("ring")


func _tram() -> void:
	# 1.5 km of straight track east to a set of points at x = 0, a branch
	# bending away each side.
	var y := 300.0
	traffic.add_tile("trunk", [{"kind": "tram", "w": 3.0, "p": PackedVector2Array([Vector2(-1500, y), Vector2(0, y)])}])
	traffic.focus = Vector3(-750, 0, y - 150)    # trams spawn 60-420 m from here
	traffic.target = {"car": 0, "bus": 0, "tram": 1, "bike": 0, "canta": 0}
	var v = null
	for tries in 200:
		await _step()
		if traffic.vehicles.size():
			v = traffic.vehicles[0]
			break
	if v == null:
		_check(false, "a tram spawns on the test track"); return
	traffic.target.tram = 0
	# Put it near the west end, heading east, standing.
	v.dir = 1; v.s = 60.0; v.speed = 0.0; v.trail = []
	var back := 0.0
	while back <= Traffic.KINDS.tram.len + 2.0:
		var vv: Dictionary = v.duplicate(); vv.s = v.s - back
		v.trail.append(traffic._front(vv)[0])
		back += 0.5
	v.trail.reverse()
	v.driven = true; v.rider = true
	traffic.add_tile("left", [{"kind": "tram", "w": 3.0, "p": _arc(Vector2(0, y), Vector2(200, y - 120))}])
	traffic.add_tile("right", [{"kind": "tram", "w": 3.0, "p": _arc(Vector2(0, y), Vector2(200, y + 120))}])
	var left_id: int = traffic.by_kind.tram[traffic.by_kind.tram.size() - 2]
	# Power: 0-30 km/h.
	v.throttle = 1.0
	var t30 := -1.0
	for i in 60 * 30:
		await _step()
		traffic.focus = Vector3(v.pos.x, 0, v.pos.y)
		if t30 < 0.0 and v.speed >= 8.33: t30 = i / 60.0
		if v.speed >= 13.9: break
	print("tram: 0-30 km/h in %.1f s" % t30)
	_check(t30 > 4.5 and t30 < 10.0, "a tram pulls away at a tram's pace (0-30 km/h in %.1f s)" % t30)
	# Service brake from 50 km/h.
	var from: Vector2 = v.pos
	v.throttle = -1.0
	await _until(v, func(): return v.speed <= 0.05)
	var d: float = from.distance_to(v.pos)
	_check(d > 50.0 and d < 95.0, "the service brake stops it from 50 km/h in %.0f m" % d)
	# Emergency brake from 50.
	v.throttle = 1.0
	await _until(v, func(): return v.speed >= 13.9)
	from = v.pos; v.throttle = 0.0; v.ebrake = true
	await _until(v, func(): return v.speed <= 0.05)
	d = from.distance_to(v.pos)
	_check(d > 25.0 and d < 50.0, "the emergency brake (Space) in %.0f m" % d)
	v.ebrake = false
	# Coasting: it rolls on and on.
	v.throttle = 1.0
	await _until(v, func(): return v.speed >= 13.9)
	v.throttle = 0.0
	for i in 60 * 5: await _step()
	_check(v.speed > 12.5, "with the power off it coasts (%.1f m/s after 5 s from 13.9)" % v.speed)
	# At the points, A takes the left branch.
	v.steer = 1.0; v.throttle = 1.0
	for i in 60 * 120:
		await _step()
		traffic.focus = Vector3(v.pos.x, 0, v.pos.y)
		if v.edge != traffic.by_kind.tram[0]: break
	_check(v.edge == left_id, "A at the points takes the left branch")
