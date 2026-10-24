extends Node3D
## Cars, buses and trams on the real street and tram network.
##
## Every loaded tile adds its road and tram polylines as edges of one graph;
## edges meet where their ends coincide (tiles were cut along the same lines,
## so the network continues across tile borders). Vehicles drive along an
## edge, pick a next edge at its end (mostly the straightest), keep to the
## right, slow for curves, keep their distance from whatever is ahead of
## them -- including the walking player -- and buses and trams stop now and
## then. Vehicles spawn within `spawn_radius` of `focus` and are dropped
## beyond it.

const Models := preload("res://scripts/vehicle_models.gd")
const BikeRig := preload("res://scripts/bike_rig.gd")
const SNAP := 2.0                 # half-metre grid for joining edge ends
const KINDS := {
	"car": {"len": 4.2, "max": 12.5, "lane": 1.4, "y": 0.09, "accel": 3.0},
	"bike": {"len": 1.8, "max": 5.2, "lane": 2.8, "y": 0.09, "accel": 1.2},
	"canta": {"len": 2.3, "max": 11.0, "lane": 1.4, "y": 0.09, "accel": 2.2},
	"bus": {"len": 12.0, "max": 11.0, "lane": 1.9, "y": 0.09, "accel": 1.5},
	"tram": {"len": 29.8, "max": 11.5, "lane": 0.0, "y": 0.13, "accel": 1.1},
}
const TRAM_SECTIONS := [9.6, 9.6, 9.6]
# How each kind's body moves on its springs: radians of pitch per m/s^2 of
# braking or acceleration, radians of roll per m/s^2 of cornering, and the
# spring's natural frequency (rad/s). A bus rolls a lot, a tram hardly at all.
# Cyclists lean into the turn instead, by the angle that balances it.
const SPRINGS := {
	"car": [0.006, 0.015, 9.0], "canta": [0.009, 0.02, 10.0], "bus": [0.005, 0.02, 6.0], "tram": [0.0015, 0.005, 7.0],
}
const SPRUNG_NEAR := 160.0        # metres from you within which bodies move on their springs
const CAR_COLORS := ["1b1b1b", "f2f2f2", "8a8f94", "2c4a6e", "7a1e1e", "2f5d3a", "c9b48a", "d9d4c7", "0f2a4a", "b3261e", "4a4f55", "e8e8e8"]

var target := {"car": 70, "bus": 7, "tram": 9, "bike": 35, "canta": 8}
# Cantas come in a few reds (and now and then another colour).
const CANTA_COLORS := ["9e0b10", "9e0b10", "b3121a", "8a0a12", "c4161c", "9e0b10", "1d3f73"]
# Most Amsterdam bikes are black; the rest in the usual colours.
const BIKE_COLORS := ["111214", "111214", "111214", "111214", "1d2a3a", "6b1e1e", "2f4f3a", "d8d2c4", "7a8a99"]
var spawn_radius := 420.0
var focus := Vector3.ZERO
var player := Vector3(1e9, 0, 1e9)  # the walker, as an obstacle
var enabled := true
var street_y: Callable          # (p, base height) -> height: bridges hump over the canals

var edges := {}        # id -> edge
var nodes := {}        # Vector2i -> Array[[edge id, end]]
var by_kind := {"road": [], "tram": [], "bike": []}
var vehicles: Array = []
var _next_id := 0
var _rng := RandomNumberGenerator.new()


# ---- the network ------------------------------------------------------------------

func _key(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x * SNAP), roundi(p.y * SNAP))


func add_tile(key: String, lanes: Array) -> void:
	for l in lanes:
		var p: PackedVector2Array = l.p
		if p.size() < 2:
			continue
		var cum := PackedFloat32Array([0.0])
		for i in range(1, p.size()):
			cum.append(cum[i - 1] + p[i - 1].distance_to(p[i]))
		if cum[cum.size() - 1] < 3.0:
			continue
		var id := _next_id; _next_id += 1
		var e := {"id": id, "kind": l.kind, "w": l.w, "p": p, "cum": cum, "len": cum[cum.size() - 1], "tile": key,
			"ends": [_key(p[0]), _key(p[p.size() - 1])]}
		edges[id] = e
		for end in 2:
			var k: Vector2i = e.ends[end]
			if not nodes.has(k): nodes[k] = []
			nodes[k].append([id, end])
		by_kind[l.kind].append(id)


func remove_tile(key: String) -> void:
	var gone := {}
	for id in edges.keys():
		if edges[id].tile == key:
			gone[id] = true
	for id in gone:
		var e: Dictionary = edges[id]
		for k in e.ends:
			if nodes.has(k):
				nodes[k] = nodes[k].filter(func(x): return not gone.has(x[0]))
				if nodes[k].is_empty(): nodes.erase(k)
		by_kind[e.kind].erase(id)
		edges.erase(id)
	for v in vehicles.duplicate():
		if gone.has(v.edge) and not v.get("driver", false) and not v.get("parked", false):
			_despawn(v)


# Point and direction at distance d from the start of an edge.
func _at(e: Dictionary, d: float) -> Array:
	var p: PackedVector2Array = e.p
	var cum: PackedFloat32Array = e.cum
	d = clampf(d, 0.0, e.len)
	var i := cum.bsearch(d) - 1
	i = clampi(i, 0, p.size() - 2)
	var seg := maxf(cum[i + 1] - cum[i], 1e-4)
	var t := (d - cum[i]) / seg
	return [p[i].lerp(p[i + 1], t), (p[i + 1] - p[i]) / seg]


# Position and heading of a vehicle's front, on its lane.
func _front(v: Dictionary) -> Array:
	var e: Dictionary = edges[v.edge]
	var r := _at(e, v.s if v.dir == 1 else e.len - v.s)
	var fwd: Vector2 = r[1] * v.dir
	var right := Vector2(-fwd.y, fwd.x)
	var lane: float = KINDS[v.kind].lane
	if v.kind == "bike":                  # the middle of a bike path, the edge of a street
		lane = 0.5 if e.kind == "bike" else minf(lane, e.w / 2.0 - 0.6)
	return [r[0] + right * lane, fwd]


func _usable(kind: String, e: Dictionary) -> bool:
	if kind == "tram": return e.kind == "tram"
	if kind == "bike": return e.kind == "bike" or (e.kind == "road" and e.w < 12.0)
	if e.kind == "bike": return false
	if e.kind != "road": return false
	return kind != "bus" or e.w >= 7.0


# ---- vehicles --------------------------------------------------------------------

func _spawn(kind: String) -> void:
	var pool: Array = by_kind["tram" if kind == "tram" else "road"]
	if kind == "bike":
		pool = by_kind["bike"] + by_kind["road"]
	if pool.is_empty():
		return
	var spec: Dictionary = KINDS[kind]
	for attempt in 30:
		var e: Dictionary = edges[pool[_rng.randi() % pool.size()]]
		if not _usable(kind, e) or e.len < spec.len + 6.0:
			continue
		var mid: Vector2 = _at(e, e.len / 2)[0]
		var dist := mid.distance_to(Vector2(focus.x, focus.z))
		if dist > spawn_radius or dist < 60.0:
			continue
		var v := {"kind": kind, "edge": e.id, "dir": 1 if _rng.randf() < 0.5 else -1,
			"s": _rng.randf_range(spec.len + 1.0, e.len - 1.0), "speed": spec.max * 0.6, "stuck": 0.0, "ghost": 0.0,
			"stop_in": _rng.randf_range(150, 400), "dwell": 0.0, "trail": []}
		var f := _front(v)
		var clear := true
		for o in vehicles:
			if o.pos.distance_to(f[0]) < spec.len + 8.0:
				clear = false; break
		if not clear:
			continue
		v.pos = f[0]
		# Seed the trail straight back along the edge, so bodies start on the road.
		var back := 0.0
		while back <= spec.len + 2.0:
			var vv := v.duplicate(); vv.s = v.s - back
			v.trail.append(_front(vv)[0])
			back += 0.5
		v.trail.reverse()
		_build_model(v)
		vehicles.append(v)
		return


func _build_model(v: Dictionary) -> void:
	var root := Node3D.new()
	v.parts = []
	match v.kind:
		"car":
			var c: Node3D = Models.car(Color(CAR_COLORS[_rng.randi() % CAR_COLORS.size()]))
			Models.solid(c, Vector3(1.8, 1.3, 4.2), 0.75)
			root.add_child(c); v.parts.append([c, 0.0, 4.2])
		"bus":
			var b: Node3D = Models.bus()
			Models.solid(b, Vector3(2.55, 3.0, 12.0), 1.6)
			root.add_child(b); v.parts.append([b, 0.0, 12.0])
		"canta":
			var c: Node3D = Models.canta(Color(CANTA_COLORS[_rng.randi() % CANTA_COLORS.size()]))
			Models.solid(c, Vector3(1.08, 1.4, 2.3), 0.8)
			root.add_child(c); v.parts.append([c, 0.0, 2.3])
		"bike":
			var rig: Node3D = BikeRig.new()
			rig.build("oma" if _rng.randf() < 0.55 else "opa", Color(BIKE_COLORS[_rng.randi() % BIKE_COLORS.size()]), "_low")
			rig.add_rider(_rng)
			root.add_child(rig); v.parts.append([rig, 0.0, 1.8])
		"tram":
			var off := 0.0
			for k in TRAM_SECTIONS.size():
				var cab := -1 if k == 0 else (1 if k == TRAM_SECTIONS.size() - 1 else 0)
				var sec: Node3D = Models.tram_section(TRAM_SECTIONS[k], cab)
				Models.solid(sec, Vector3(2.4, 3.0, TRAM_SECTIONS[k]), 1.7)
				root.add_child(sec)
				v.parts.append([sec, off, TRAM_SECTIONS[k]])
				off += TRAM_SECTIONS[k] + 0.5
				if k < TRAM_SECTIONS.size() - 1:
					var j := Models.tram_joint()
					root.add_child(j)
					v.parts.append([j, off - 0.5, 0.5])
	add_child(root)
	v.node = root


func _despawn(v: Dictionary) -> void:
	if is_instance_valid(v.node):
		v.node.queue_free()
	vehicles.erase(v)


# Choose where to go at the end of an edge: mostly the straightest way on.
func _next(v: Dictionary) -> bool:
	var e: Dictionary = edges[v.edge]
	var at_end := 1 if v.dir == 1 else 0
	var k: Vector2i = e.ends[at_end]
	var heading: Vector2 = _front(v)[1]
	var options := []
	for x in nodes.get(k, []):
		if x[0] == v.edge: continue
		var ne: Dictionary = edges[x[0]]
		if not _usable(v.kind, ne): continue
		var ndir := 1 if x[1] == 0 else -1
		var start := _at(ne, 0.0 if ndir == 1 else ne.len)
		var turn: float = heading.dot(start[1] * ndir)
		options.append([x[0], ndir, turn])
	if options.is_empty():
		return false
	if v.get("driven", false):
		# At the points you choose: A the leftmost branch, D the rightmost, else
		# the straightest. (A left turn has a negative cross product here.)
		var steer: float = v.get("steer", 0.0)
		var best = options[0]
		for o in options:
			var side: float = heading.cross((_at(edges[o[0]], 0.0 if o[1] == 1 else edges[o[0]].len)[1] * o[1]) as Vector2)
			o.append(side)
		for o in options:
			if steer > 0.0 and o[3] < best[3]: best = o
			elif steer < 0.0 and o[3] > best[3]: best = o
			elif steer == 0.0 and o[2] > best[2]: best = o
		v.edge = best[0]; v.dir = best[1]
		return true
	var total := 0.0
	for o in options:
		o[2] = pow(maxf(o[2] + 1.05, 0.05), 3.0)    # straight on is likely, U-turns rare
		total += o[2]
	var pick := _rng.randf() * total
	for o in options:
		pick -= o[2]
		if pick <= 0.0:
			v.edge = o[0]; v.dir = o[1]
			return true
	v.edge = options[0][0]; v.dir = options[0][1]
	return true


func _process(delta: float) -> void:
	if not enabled:
		return
	delta = minf(delta, 0.1)
	var counts := {"car": 0, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	for v in vehicles.duplicate():
		if v.has("body") and not v.get("driver", false):   # a knocked or left car: where it is now
			var bp: Vector3 = v.body.global_position
			v.pos = Vector2(bp.x, bp.z)
		if v.pos.distance_to(Vector2(focus.x, focus.z)) > spawn_radius + 160.0 and not _occupied(v):
			_despawn(v)
		else:
			counts[v.kind] += 1
	for kind in counts:
		if counts[kind] < target[kind]:
			_spawn(kind)                  # one per kind per frame: no bursts
	for v in vehicles.duplicate():
		if not v.get("driver", false) and not v.get("parked", false):
			_drive(v, delta)


func _drive(v: Dictionary, dt: float) -> void:
	var spec: Dictionary = KINDS[v.kind]
	var e: Dictionary = edges.get(v.edge, {})
	if e.is_empty():
		_despawn(v); return
	var f := _front(v)
	var fwd: Vector2 = f[1]
	# Slow for the bend ahead.
	var ahead := v.duplicate(); ahead.s = minf(v.s + 14.0, e.len)
	var bend: float = acos(clampf(fwd.dot(_front(ahead)[1]), -1.0, 1.0))
	var want: float = spec.max * clampf(1.0 - bend / 1.1, 0.3, 1.0)
	# Keep a gap to anything in front: other vehicles and the walker.
	var gap := 1e9
	if v.ghost <= 0.0:
		for o in vehicles:
			if o == v: continue
			if (o.kind == "bike") != (v.kind == "bike"): continue   # bikes keep to their own edge of the street
			var d: Vector2 = o.pos - v.pos
			var along := d.dot(fwd)
			if along <= 0.0 or along > 40.0: continue
			if absf(d.cross(fwd)) > 2.4: continue
			gap = minf(gap, along - KINDS[o.kind].len * 0.5 - 2.0)
	var pp: Vector2 = Vector2(player.x, player.z) - v.pos
	if pp.dot(fwd) > 0.0 and pp.dot(fwd) < 25.0 and absf(pp.cross(fwd)) < 2.6:
		gap = minf(gap, pp.dot(fwd) - 3.0)
	want = minf(want, maxf(0.0, (gap - 1.0) / 1.3))
	# Buses and trams stop now and then, as if at a stop.
	if v.kind == "bus" or v.kind == "tram":
		v.stop_in -= v.speed * dt
		if v.stop_in < 30.0 and v.dwell <= 0.0:
			want = minf(want, maxf(0.0, v.stop_in / 3.0))
			if v.stop_in <= 0.5 and v.speed < 0.3:
				v.dwell = _rng.randf_range(6.0, 11.0)
		if v.dwell > 0.0:
			want = 0.0
			v.dwell -= dt
			if v.dwell <= 0.0:
				v.stop_in = _rng.randf_range(250, 500)
	var acc: float = spec.accel if want > v.speed else spec.accel * 2.5
	if v.get("driven", false):
		v.speed = _tram_speed(v, dt)    # you are at the controls: your power and brakes, not the timetable
	else:
		v.speed = move_toward(v.speed, want, acc * dt)
	# Stuck behind something that is stuck behind us: one of us goes first.
	if v.speed < 0.2 and want < 0.2 and v.dwell <= 0.0:
		v.stuck += dt
		if v.stuck > 5.0:
			v.ghost = 2.5; v.stuck = 0.0
	else:
		v.stuck = 0.0
	v.ghost = maxf(0.0, v.ghost - dt)
	# Move, crossing to the next edge at the end of this one.
	v.s += v.speed * dt
	var guard := 0
	while v.s > edges[v.edge].len and guard < 4:
		var over: float = v.s - edges[v.edge].len
		if not _next(v):
			v.dir = -v.dir                  # dead end: turn round
		v.s = over
		guard += 1
	f = _front(v)
	v.pos = f[0]
	v.yaw = atan2(-f[1].x, -f[1].y)
	# The trail of the front: bodies and tram sections follow it.
	var trail: Array = v.trail
	if trail.is_empty() or trail[trail.size() - 1].distance_to(v.pos) > 0.4:
		trail.append(v.pos)
		while trail.size() > int((spec.len + 6.0) / 0.4):
			trail.pop_front()
	for part in v.parts:
		var a := _behind(trail, v.pos, part[1])
		var b := _behind(trail, v.pos, part[1] + part[2])
		var mid: Vector2 = (a + b) / 2.0
		var dir: Vector2 = (a - b).normalized() if a.distance_to(b) > 0.01 else fwd
		var y: float = spec.y
		var pitch := 0.0
		if street_y.is_valid():          # up and over a bridge, nose up on the ramp
			y = street_y.call(mid, spec.y)
			var ya: float = street_y.call(a, spec.y); var yb: float = street_y.call(b, spec.y)
			pitch = atan2(ya - yb, maxf(a.distance_to(b), 0.5))
		var yaw := atan2(-dir.x, -dir.y)
		if part == v.parts[0]:
			# Its acceleration along and across (from how its body turns, which
			# follows the trail, rather than the lane's corners), on its springs.
			var last_speed: float = v.get("last_speed", v.speed)
			var last_yaw: float = v.get("body_yaw", yaw)
			_springs(v, (v.speed - last_speed) / dt, v.speed * wrapf(yaw - last_yaw, -PI, PI) / dt, dt)
			v.last_speed = v.speed
			v.body_yaw = yaw
		var sp: Array = v.get("spring", [0.0, 0.0, 0.0, 0.0])
		part[0].position = Vector3(mid.x, y, mid.y)
		part[0].rotation = Vector3(pitch + sp[0], yaw, sp[2])
	if v.kind == "bike":
		v.parts[0][0].pedal(dt, v.speed)
	elif v.kind == "canta":
		Models.spin_wheels(v.parts[0][0], v.speed * dt, 0.22)
	elif v.kind == "car" or v.kind == "bus":
		Models.spin_wheels(v.parts[0][0], v.speed * dt, 0.33 if v.kind == "car" else 0.5)


# A tram driven by you: 35 tonnes on steel rails. Up to 1.3 m/s^2 of traction
# (fading towards 70 km/h), 1.4 m/s^2 of service brake, 2.8 of emergency
# brake, and it rolls on a long way with the power off.
const TRAM := {"accel": 1.3, "top": 19.5, "brake": 1.4, "emergency": 2.8, "roll": 0.06}

func _tram_speed(v: Dictionary, dt: float) -> float:
	var s: float = v.speed
	var throttle: float = v.get("throttle", 0.0)
	var a := -TRAM.roll - 0.0003 * s * s               # rolling resistance and air
	if v.get("ebrake", false):
		a = -TRAM.emergency
	elif throttle > 0.0:
		a += TRAM.accel * throttle * clampf(1.0 - pow(s / TRAM.top, 3.0), 0.0, 1.0)
	elif throttle < 0.0:
		a = -TRAM.brake
	v.dwell = 0.0
	v.stop_in = 1e9                                 # no timetable stops: you stop where you like
	return maxf(0.0, s + a * dt)


# The body on its springs: it dips its nose braking, squats pulling away and
# rolls out of a corner, then settles (a damped spring per axis, from the
# vehicle's real acceleration `along` and cornering `across`, m/s^2). A cyclist
# leans into the turn instead. Only near you: far away nobody sees it.
func _springs(v: Dictionary, along: float, across: float, dt: float) -> void:
	if v.pos.distance_to(Vector2(focus.x, focus.z)) > SPRUNG_NEAR or dt <= 0.0:
		v.spring = [0.0, 0.0, 0.0, 0.0]
		return
	var sp: Array = v.get("spring", [0.0, 0.0, 0.0, 0.0])   # pitch, its rate, roll, its rate
	# The lane is drawn in straight pieces: smooth the cornering over a few
	# tenths of a second, as a real body's turn is smooth.
	across = clampf(across, -5.0, 5.0)
	v.across = lerpf(float(v.get("across", 0.0)), across, 1.0 - exp(-dt * 5.0))
	across = v.across
	if v.kind == "bike":
		var lean := clampf(atan(across / 9.81), -0.5, 0.5)   # tan(lean) = v * yaw rate / g, into the turn
		sp[2] = lerpf(sp[2], lean, 1.0 - exp(-dt * 6.0))
		v.spring = sp
		return
	var k: Array = SPRINGS[v.kind]
	var w: float = k[2]
	# Braking (along < 0) dips the nose: model -Z is the front, +x rotation lifts it.
	var aim_pitch: float = clampf(along, -9.0, 6.0) * k[0]
	# Turning left (across > 0) throws the body right: right side down, -z rotation.
	var aim_roll: float = -clampf(across, -8.0, 8.0) * k[1]
	for i in [0, 2]:
		var aim: float = aim_pitch if i == 0 else aim_roll
		var acc: float = w * w * (aim - sp[i]) - 2.0 * 0.35 * w * sp[i + 1]
		sp[i + 1] += acc * dt
		sp[i] += sp[i + 1] * dt
	v.spring = sp


# The point `back` metres behind the front along the trail.
func _behind(trail: Array, front: Vector2, back: float) -> Vector2:
	var p := front
	var left := back
	for i in range(trail.size() - 1, -1, -1):
		var q: Vector2 = trail[i]
		var d := p.distance_to(q)
		if d >= left and d > 0.0:
			return p.lerp(q, left / d)
		left -= d
		p = q
	return p


# ---- the player and vehicles ------------------------------------------------------

const RADIUS := {"car": 1.3, "bus": 1.5, "tram": 1.5, "bike": 0.5, "canta": 0.8}   # half widths, roughly


## A bike you took from a rack, as a traffic vehicle you drive.
func add_bike(at: Vector2, yaw: float, color: Color, kind := "oma") -> Dictionary:
	var rig: Node3D = BikeRig.new()
	rig.build(kind, color)
	var root := Node3D.new()
	root.add_child(rig)
	add_child(root)
	rig.position = Vector3(at.x, KINDS.bike.y, at.y)
	rig.rotation.y = yaw
	var v := {"kind": "bike", "edge": -1, "dir": 1, "s": 0.0, "speed": 0.0, "stuck": 0.0, "ghost": 0.0,
		"stop_in": 0.0, "dwell": 0.0, "trail": [], "pos": at, "parts": [[rig, 0.0, 1.8]], "node": root}
	vehicles.append(v)
	return v


func _occupied(v: Dictionary) -> bool:
	return v.get("driver", false) or v.get("rider", false)


# Distance from p to a vehicle's body: each section is a segment along its length.
func body_distance(v: Dictionary, p: Vector2) -> float:
	var best := INF
	for part in v.parts:
		if part[2] < 1.0:
			continue                          # tram bellows
		var n: Node3D = part[0]
		var c := Vector2(n.position.x, n.position.z)
		var f: Vector2 = Vector2(-sin(n.rotation.y), -cos(n.rotation.y)) * (part[2] / 2.0 - 0.8)
		best = minf(best, Geometry2D.get_closest_point_to_segment(p, c - f, c + f).distance_to(p))
	return best


## The vehicle whose body is closest to p, within `within` metres of its side, or {}.
func nearest(p: Vector2, within: float) -> Dictionary:
	var best := {}
	var bd := within
	for v in vehicles:
		if v.pos.distance_to(p) > 40.0:
			continue
		var d: float = body_distance(v, p) - RADIUS[v.kind]
		if d < bd:
			bd = d; best = v
	return best


## Whether p is inside some vehicle other than `except`.
func blocked(p: Vector2, except: Dictionary) -> bool:
	for v in vehicles:
		if v == except or v.pos.distance_to(p) > 40.0:
			continue
		if body_distance(v, p) < RADIUS[v.kind] - 0.2:
			return true
	return false


func count() -> Dictionary:
	var c := {"car": 0, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	for v in vehicles: c[v.kind] += 1
	return c


func clear() -> void:
	for v in vehicles.duplicate():
		_despawn(v)
