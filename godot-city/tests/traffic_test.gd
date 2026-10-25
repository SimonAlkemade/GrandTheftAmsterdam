extends SceneTree
## The street traffic's physics on a test layout: cars dip their nose braking
## for a bend and roll out of it, cyclists lean into it, cars brake for
## pedestrians in their way (and not for those on the pavement), and a tram
## you drive pulls away, brakes, coasts and takes the branch you choose; and
## on double track trams keep right, one way per track, turn round on to the
## other track at the end of the line, and never run through one another.
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
	await _brakes()
	await _tram()
	await _tram_lines()
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


# A car on a straight street, and pedestrians placed round it.
func _brakes() -> void:
	var y := 1000.0
	traffic.add_tile("street", [{"kind": "road", "w": 8.0, "p": PackedVector2Array([Vector2(-600, y), Vector2(600, y)])}])
	traffic.focus = Vector3(0, 0, y - 150)
	traffic.target = {"car": 1, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	var v = null
	for i in 200:
		await _step()
		if traffic.vehicles.size():
			v = traffic.vehicles[0]; break
	traffic.target.car = 0
	if v == null:
		_check(false, "a car spawns on the test street"); return
	# From near the west end, heading east: room ahead for everything below.
	v.dir = 1; v.s = 120.0; v.trail = []
	v.pos = traffic._front(v)[0]
	for i in 60 * 6: await _step()                 # up to speed
	var fwd: Vector2 = traffic._front(v)[1]
	var right := Vector2(-fwd.y, fwd.x)
	var cruise: float = v.speed
	# 1. Someone standing in its lane 40 m ahead: it stops short and waits.
	var at: Vector2 = v.pos + fwd * 40.0
	traffic.pedestrians = [[at, Vector2.ZERO]]
	for i in 60 * 10: await _step()
	var short: float = (at - v.pos).dot(fwd)
	print("brakes: cruising %.1f m/s, stopped %.1f m short (speed %.2f)" % [cruise, short, v.speed])
	_check(v.speed < 0.2, "a car stops for someone standing in its lane (%.2f m/s)" % v.speed)
	_check(short > 1.5 and short < 6.0, "a few metres short of them (%.1f m)" % short)
	# They step out of the way: it drives on.
	traffic.pedestrians = []
	for i in 60 * 5: await _step()
	_check(v.speed > 4.0, "and drives on once they have gone (%.1f m/s)" % v.speed)
	for i in 60 * 4: await _step()
	# 2. Someone on the pavement beside it, 4 m off its line: no braking.
	var slowest := INF
	at = v.pos + fwd * 30.0 + right * 4.0
	traffic.pedestrians = [[at, Vector2.ZERO]]
	for i in 60 * 4:
		await _step()
		slowest = minf(slowest, v.speed)
	_check(slowest > cruise * 0.85, "but not for someone on the pavement beside it (slowest %.1f of %.1f m/s)" % [slowest, cruise])
	traffic.pedestrians = []
	for i in 60 * 4: await _step()
	# 3. Someone stepping off the kerb 3 m off its line, walking into its way 20 m ahead.
	slowest = INF
	at = v.pos + fwd * 20.0 + right * 3.0
	for i in 60 * 3:
		traffic.pedestrians = [[at, -right * 1.3]]
		at += -right * 1.3 / 60.0
		await _step()
		slowest = minf(slowest, v.speed)
	_check(slowest < cruise * 0.6, "and slows for someone walking into its way (slowest %.1f of %.1f m/s)" % [slowest, cruise])
	traffic.pedestrians = []
	traffic.clear()
	traffic.remove_tile("street")


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


func _tram_lines() -> void:
	traffic.clear()
	for t in ["trunk", "left", "right"]: traffic.remove_tile(t)
	# A line of double track 1 km long, east-west, the tracks 3 m apart, both
	# drawn west to east. Keeping right, the south track runs east.
	var y := -2000.0
	traffic.add_tile("line", [
		{"kind": "tram", "w": 3.0, "p": PackedVector2Array([Vector2(-500, y - 1.5), Vector2(500, y - 1.5)])},
		{"kind": "tram", "w": 3.0, "p": PackedVector2Array([Vector2(-500, y + 1.5), Vector2(500, y + 1.5)])}])
	var north: Dictionary = traffic.edges[traffic.by_kind.tram[-2]]
	var south: Dictionary = traffic.edges[traffic.by_kind.tram[-1]]
	_check(traffic.tram_way(south) == 1 and traffic.tram_way(north) == -1,
		"each track runs one way, keeping right (south track %d, north track %d)" % [traffic.tram_way(south), traffic.tram_way(north)])
	traffic.focus = Vector3(0, 0, y - 150.0)    # (trams spawn 60 m and more away)
	traffic.spawn_radius = 420.0
	traffic.target = {"car": 0, "bus": 0, "tram": 6, "bike": 0, "canta": 0}
	for i in 60 * 3: await _step()
	traffic.target.tram = 0
	var trams: Array = traffic.vehicles.filter(func(v): return v.kind == "tram")
	print("tram lines: %d trams on the line" % trams.size())
	var wrong := 0
	var overlap := INF
	var turned := 0
	var last_edge := trams.map(func(v): return v.edge)
	for i in 60 * 120:
		await _step()
		for k in trams.size():
			var v: Dictionary = trams[k]
			if not traffic.vehicles.has(v): continue
			if v.dir != traffic.tram_way(traffic.edges[v.edge]): wrong += 1
			if v.edge != last_edge[k]:
				turned += 1; last_edge[k] = v.edge
			for o in trams:
				if o == v or o.edge != v.edge or not traffic.vehicles.has(o): continue
				overlap = minf(overlap, absf(v.s - o.s))
	print("tram lines: %d steps against the track's way, %d turnarounds, closest on one track %.1f m" % [wrong, turned, overlap])
	_check(trams.size() >= 3, "trams run on the line (%d)" % trams.size())
	_check(wrong == 0, "always the way their track runs (%d steps wrong)" % wrong)
	_check(turned > 0, "at the end of the line they come back on the other track (%d)" % turned)
	_check(overlap >= Traffic.KINDS.tram.len, "and never run into or through each other (closest %.1f m, front to front)" % overlap)
