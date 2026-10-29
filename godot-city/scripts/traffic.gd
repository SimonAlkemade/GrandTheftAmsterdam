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
	"tram": {"len": 26.8, "max": 11.5, "lane": 0.0, "y": 0.13, "accel": 1.1},
}
const TRAM_SECTIONS := [9.6, 6.6, 9.6]      # a GVB 11G/12G: 27 m in three sections
# The lines it might run, with a terminus each way (the GVB network of the
# 1990s, roughly): each tram shows one line and one end of it. The traffic
# follows the real tracks, not these routes.
const TRAM_LINES := [
	["1", "Osdorp"], ["1", "Centraal Station"], ["2", "Nieuw Sloten"], ["2", "Centraal Station"],
	["4", "Station RAI"], ["4", "Centraal Station"], ["5", "Amstelveen Binnenhof"], ["5", "Centraal Station"],
	["9", "Watergraafsmeer"], ["9", "Centraal Station"], ["13", "Geuzenveld"], ["13", "Centraal Station"],
	["16", "VU Ziekenhuis"], ["16", "Centraal Station"], ["17", "Osdorp"], ["17", "Centraal Station"],
	["24", "VU Ziekenhuis"], ["24", "Centraal Station"], ["25", "President Kennedylaan"], ["25", "Centraal Station"],
]
# Its doors (on the right-hand side), metres from each section's middle.
const TRAM_DOORS := [[-2.6, 2.9], [0.0], [-2.9, 2.6]]
# How each kind's body moves on its springs: radians of pitch per m/s^2 of
# braking or acceleration, radians of roll per m/s^2 of cornering, and the
# spring's natural frequency (rad/s). A bus rolls a lot, a tram hardly at all.
# Cyclists lean into the turn instead, by the angle that balances it.
const SPRINGS := {
	"car": [0.006, 0.015, 9.0], "canta": [0.009, 0.02, 10.0], "bus": [0.005, 0.02, 6.0], "tram": [0.0015, 0.005, 7.0],
}
const GRID := 50.0                # metres: the cells vehicles are sorted into each frame
const FULL_NEAR := 180.0          # metres from the focus within which a vehicle moves every frame
const FAR_EVERY := 3              # ...and beyond it, every this many frames (by the same distance)
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
var pedestrians: Array = []         # [where, walking velocity] of the people on foot near you (Walker sets it)
# How far either side of a vehicle's line a pedestrian makes it brake: its
# half width and a little, so people on the pavement beside it do not.
const PED_ROOM := {"car": 1.8, "canta": 1.4, "bus": 2.2, "tram": 2.1, "bike": 1.1}
const PED_SEES := 25.0              # metres ahead a driver watches for people
const PED_STOP := 3.0               # ... and stops this far short of them
var enabled := true
var street_y: Callable          # (p, base height) -> height: bridges hump over the canals

var edges := {}        # id -> edge
var nodes := {}        # Vector2i -> Array[[edge id, end]]
var by_kind := {"road": [], "tram": [], "bike": []}
var vehicles: Array = []
var _next_id := 0
var _tram_cells := {}           # 8 m cell -> tram edge ids passing through it
var _grid := {}                 # Vector2i cell -> the vehicles in it (rebuilt each frame)
var _frame := 0
var _ped_box := Rect2()          # round everyone on foot, as far as a driver looks out for them
var _field := {}                # a police call's streets: node -> metres by road to the call
var _field_to := Vector2.INF
var _field_near := CALL_NEAR    # how near the street ends it was seeded from are
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
		if l.kind == "tram":
			_index_tram(e)


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
		if e.kind == "tram":
			for c in e.get("cells", []):
				_tram_cells[c] = _tram_cells[c].filter(func(x): return x != id)
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


# ---- one-way tram tracks -----------------------------------------------------------
# Amsterdam's trams run on double track, one track each way, keeping right:
# the other track, the oncoming one, is on a tram's left. So each track has a
# way it is run (`way`: 1 along its points, -1 against them), read off the
# track beside it; a track with none beside it (a single-track stretch, a
# terminus loop) is 0, either way.
const TRAM_CELL := 8.0
const TRAM_PAIR := [1.5, 6.0]        # how far apart the two tracks of a line lie (m)


func _index_tram(e: Dictionary) -> void:
	var cells := {}
	var d := 0.0
	while d <= e.len:
		var p: Vector2 = _at(e, d)[0]
		cells[Vector2i(floori(p.x / TRAM_CELL), floori(p.y / TRAM_CELL))] = true
		d += TRAM_CELL / 2.0
	e.cells = cells.keys()
	for c in cells:
		if not _tram_cells.has(c): _tram_cells[c] = []
		_tram_cells[c].append(e.id)
		for dx in range(-1, 2):           # a newly loaded track may pair with one already here
			for dy in range(-1, 2):
				for x in _tram_cells.get(c + Vector2i(dx, dy), []):
					edges[x].erase("way")


func tram_way(e: Dictionary) -> int:
	if e.has("way"):
		return e.way
	var vote := 0
	var at := []
	var d := 3.0
	while d <= e.len - 3.0:
		at.append(d); d += 6.0
	if at.is_empty():
		at.append(e.len / 2.0)
	for a in at:
		var r := _at(e, a)
		var p: Vector2 = r[0]
		var fwd: Vector2 = r[1]
		var right := Vector2(-fwd.y, fwd.x)
		var c := Vector2i(floori(p.x / TRAM_CELL), floori(p.y / TRAM_CELL))
		var best := INF
		var side := 0.0
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for x in _tram_cells.get(c + Vector2i(dx, dy), []):
					if x == e.id: continue
					var o: Dictionary = edges[x]
					var op: PackedVector2Array = o.p
					for i in op.size() - 1:
						var q := Geometry2D.get_closest_point_to_segment(p, op[i], op[i + 1])
						var dist := q.distance_to(p)
						if dist < best and dist >= TRAM_PAIR[0] and dist <= TRAM_PAIR[1] \
								and absf((op[i + 1] - op[i]).normalized().dot(fwd)) > 0.85:
							best = dist; side = (q - p).dot(right)
		if best < INF:
			vote += 1 if side < 0.0 else -1     # the other track on the left: run it this way
	e.way = signi(vote) if absi(vote) >= 2 or (absi(vote) >= 1 and e.len < 15.0) else 0
	return e.way


# At the end of a one-way track: over on to the track back, beside it (as
# round a terminus loop): 1. -1 while another tram is just there on it (wait);
# 0 when there is no such track (it turns round instead).
func _turn_tram(v: Dictionary) -> int:
	var e: Dictionary = edges[v.edge]
	if v.kind != "tram" or v.get("driven", false) or tram_way(e) == 0:
		return 0
	var f := _front(v)
	var p: Vector2 = f[0]
	var c := Vector2i(floori(p.x / TRAM_CELL), floori(p.y / TRAM_CELL))
	var best := 9.0
	var pick := []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for x in _tram_cells.get(c + Vector2i(dx, dy), []):
				var o: Dictionary = edges[x]
				var way := tram_way(o)
				if x == v.edge or way == 0: continue
				var op: PackedVector2Array = o.p
				for i in op.size() - 1:
					var q := Geometry2D.get_closest_point_to_segment(p, op[i], op[i + 1])
					var seg := (op[i + 1] - op[i]).normalized() * way
					if q.distance_to(p) < best and seg.dot(f[1]) < -0.85:
						best = q.distance_to(p)
						var along: float = o.cum[i] + op[i].distance_to(q)
						pick = [x, way, along if way == 1 else o.len - along]
	if pick.is_empty():
		return 0
	# Room on it: a tram's length past the one ahead, and one coming up behind
	# able to stop short of us.
	for o in vehicles:
		if o == v or o.kind != "tram" or o.edge != pick[0]:
			continue
		var ahead: float = float(o.s) - float(pick[2])
		var stop: float = o.speed * o.speed / (2.0 * KINDS.tram.accel * 2.5)
		if (ahead >= 0.0 and ahead < KINDS.tram.len + 6.0) or (ahead < 0.0 and -ahead < KINDS.tram.len + 6.0 + stop + 10.0):
			return -1
	v.edge = pick[0]; v.dir = pick[1]; v.s = pick[2]
	return 1


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
		var dir := 1 if _rng.randf() < 0.5 else -1
		if kind == "tram" and tram_way(e) != 0:
			dir = tram_way(e)
		var v := {"kind": kind, "edge": e.id, "dir": dir,
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
			var col: String = CAR_COLORS[_rng.randi() % CAR_COLORS.size()]
			var c: Node3D = Models.police_car() if v.get("police", false) else Models.car(Color(col))
			Models.bake(c, "police" if v.get("police", false) else "car_" + col)
			Models.solid(c, Vector3(1.8, 1.3, 4.2), 0.75)
			root.add_child(c); v.parts.append([c, 0.0, 4.2])
		"bus":
			var b: Node3D = Models.bus()
			Models.bake(b, "bus")
			Models.solid(b, Vector3(2.55, 3.0, 12.0), 1.6)
			root.add_child(b); v.parts.append([b, 0.0, 12.0])
		"canta":
			var col: String = CANTA_COLORS[_rng.randi() % CANTA_COLORS.size()]
			var c: Node3D = Models.canta(Color(col))
			Models.bake(c, "canta_" + col)
			Models.solid(c, Vector3(1.08, 1.4, 2.3), 0.8)
			root.add_child(c); v.parts.append([c, 0.0, 2.3])
		"bike":
			var rig: Node3D = BikeRig.new()
			rig.build("oma" if _rng.randf() < 0.55 else "opa", Color(BIKE_COLORS[_rng.randi() % BIKE_COLORS.size()]), "_low")
			rig.add_rider(_rng)
			for g in rig.find_children("*", "GeometryInstance3D", true, false):
				(g as GeometryInstance3D).visibility_range_end = 160.0      # small: not drawn far off
			root.add_child(rig); v.parts.append([rig, 0.0, 1.8])
		"tram":
			v.line = TRAM_LINES[_rng.randi() % TRAM_LINES.size()]
			var off := 0.0
			for k in TRAM_SECTIONS.size():
				var cab := -1 if k == 0 else (1 if k == TRAM_SECTIONS.size() - 1 else 0)
				var sec: Node3D = Models.tram_section(TRAM_SECTIONS[k], cab, TRAM_DOORS[k], v.line)
				Models.bake(sec, "tram_%d" % k)
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


## A police car on its way to `to`: it starts on a street 70-180 m away and
## drives fast along the network, at every junction taking the branch that
## heads most towards `to` (keep it up to date in v.chase). {} if no street
## fits yet.
const CALL_NEAR := 60.0        # street ends this close to a police call count as there (or the nearest)


## How far each street end is from `to` by road (Dijkstra out from the ends
## within CALL_NEAR of it, starting at their straight-line distance). Kept
## until the call moves.
func chase_field(to: Vector2) -> Dictionary:
	if _field_to.distance_to(to) < 10.0 and not _field.is_empty():
		return _field
	_field_to = to
	var dist := {}
	var heap := []
	# Seeded from the street ends nearest it (a square like the Dam has no
	# road in it): those within CALL_NEAR, or within 30 m of the nearest.
	var near := {}
	var nearest := INF
	for k in nodes:
		var d := (Vector2(k) / SNAP).distance_to(to)
		if d < nearest + 30.0 and nodes[k].any(func(x): return _usable("car", edges[x[0]])):
			near[k] = d
			nearest = minf(nearest, d)
	_field_near = maxf(CALL_NEAR, nearest + 30.0)
	for k in near:
		if near[k] <= _field_near:
			dist[k] = near[k]
			_heap_push(heap, [near[k], k])
	while heap.size():
		var top: Array = _heap_pop(heap)
		var k: Vector2i = top[1]
		if top[0] > dist[k] + 0.01:
			continue
		for x in nodes.get(k, []):
			var e: Dictionary = edges[x[0]]
			if not _usable("car", e):
				continue
			var n: Vector2i = e.ends[1 - x[1]]
			var c: float = top[0] + e.len
			if c < dist.get(n, INF):
				dist[n] = c
				_heap_push(heap, [c, n])
	_field = dist
	return dist


func _heap_push(h: Array, item: Array) -> void:
	h.append(item)
	var i := h.size() - 1
	while i > 0:
		var up := (i - 1) / 2
		if h[up][0] <= h[i][0]:
			break
		var t = h[up]; h[up] = h[i]; h[i] = t
		i = up


func _heap_pop(h: Array) -> Array:
	var top: Array = h[0]
	var last: Array = h.pop_back()
	if h.size():
		h[0] = last
		var i := 0
		while true:
			var l := i * 2 + 1
			var m := i
			if l < h.size() and h[l][0] < h[m][0]: m = l
			if l + 1 < h.size() and h[l + 1][0] < h[m][0]: m = l + 1
			if m == i:
				break
			var t = h[m]; h[m] = h[i]; h[i] = t
			i = m
	return top


func spawn_police(to: Vector2) -> Dictionary:
	var spec: Dictionary = KINDS.car
	# The streets 60-220 m by road from the call (joined to it: the loaded
	# streets have islands a car could never get out of).
	var field := chase_field(to)
	var pool := []
	for id in by_kind["road"]:
		var ce: Dictionary = edges[id]
		if ce.len >= spec.len + 6.0 and _usable("car", ce):
			var dr := minf(field.get(ce.ends[0], INF), field.get(ce.ends[1], INF))
			if dr > 60.0 and dr < 220.0:
				pool.append(id)
	if pool.is_empty():
		return {}
	for attempt in 10:
		var e: Dictionary = edges[pool[_rng.randi() % pool.size()]]
		var s := _rng.randf_range(spec.len + 1.0, e.len - 1.0)
		var mid: Vector2 = _at(e, s)[0]
		if blocked(mid, {}):
			continue
		# Head the way that is shorter by road to `to`.
		var dir := 1 if e.len - s + float(field.get(e.ends[1], 1e6)) <= s + float(field.get(e.ends[0], 1e6)) else -1
		var v := {"kind": "car", "edge": e.id, "dir": dir, "s": s if dir == 1 else e.len - s, "speed": spec.max, "stuck": 0.0,
			"ghost": 0.0, "stop_in": 1e9, "dwell": 0.0, "trail": [], "police": true, "chase": to}
		var f := _front(v)
		v.pos = f[0]
		var back := 0.0
		while back <= spec.len + 2.0:
			var vv := v.duplicate(); vv.s = v.s - back
			v.trail.append(_front(vv)[0])
			back += 0.5
		v.trail.reverse()
		_build_model(v)
		vehicles.append(v)
		return v
	return {}


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
		if v.kind == "tram" and not v.get("driven", false):
			var way := tram_way(ne)
			if way != 0 and way != ndir: continue     # the other line's track
		var start := _at(ne, 0.0 if ndir == 1 else ne.len)
		var turn: float = heading.dot(start[1] * ndir)
		options.append([x[0], ndir, turn])
	if options.is_empty():
		return false
	if v.has("chase"):
		# A police car: the shortest way by road to the call. Once at a street
		# end right by it, it has arrived.
		var field := chase_field(v.chase)
		if field.get(k, INF) <= _field_near:
			v.there = true
		var best = options[0]
		var bd := INF
		for o in options:
			var ne: Dictionary = edges[o[0]]
			var d: float = ne.len + float(field.get(ne.ends[1 if o[1] == 1 else 0], 1e6))
			if d < bd:
				bd = d; best = o
		v.edge = best[0]; v.dir = best[1]
		return true
	if v.get("flee", 0.0) > 0.0:
		# Fleeing a gunshot: the branch whose far end is furthest from it.
		var best = options[0]
		var bd := -INF
		for o in options:
			var ne: Dictionary = edges[o[0]]
			var far: Vector2 = _at(ne, ne.len if o[1] == 1 else 0.0)[0]
			var d: float = far.distance_to(v.flee_from) + float(o[2]) * 3.0    # (and rather straight on)
			if d > bd:
				bd = d; best = o
		v.edge = best[0]; v.dir = best[1]
		return true
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
	_ped_box = Rect2()
	if pedestrians.size():
		_ped_box = Rect2(pedestrians[0][0], Vector2.ZERO)
		for q in pedestrians:
			_ped_box = _ped_box.expand(q[0])
		_ped_box = _ped_box.grow(PED_SEES + 5.0)
	# Who is where, so each vehicle looks only at those near it.
	_grid.clear()
	for v in vehicles:
		var c := Vector2i(floori(v.pos.x / GRID), floori(v.pos.y / GRID))
		if _grid.has(c): _grid[c].append(v)
		else: _grid[c] = [v]
	# Those far from you move in bigger steps, a few frames apart (each on its
	# own frame, so the work is spread).
	_frame += 1
	var f2 := Vector2(focus.x, focus.z)
	for v in vehicles.duplicate():
		if v.get("driver", false) or v.get("parked", false):
			continue
		if not v.has("slot"):
			v.slot = _rng.randi() % FAR_EVERY
		var acc: float = v.get("dt", 0.0) + delta
		if v.pos.distance_to(f2) > FULL_NEAR and not v.has("chase") and not v.get("driven", false) \
				and (_frame + int(v.get("slot", 0))) % FAR_EVERY != 0 and acc < 0.25:
			v.dt = acc
			continue
		v.dt = 0.0
		_drive(v, acc)


## A gunshot at `at`: the cars, Cantas, buses and cyclists within `radius`
## flee, flat out and away from it, for FLEE_TIME seconds, no longer stopping
## for anyone on foot. (Police cars come; trams keep to their rails.)
const FLEE_TIME := 12.0
const FLEE_KINDS := ["car", "canta", "bus", "bike"]

func scare(at: Vector3, radius := 60.0) -> int:
	var n := 0
	var p := Vector2(at.x, at.z)
	for v in vehicles:
		if not (v.kind in FLEE_KINDS) or v.has("chase") or v.get("driver", false) or v.get("parked", false) or v.get("driven", false):
			continue
		if v.pos.distance_to(p) < radius:
			v.flee = FLEE_TIME
			v.flee_from = p
			v.dwell = 0.0                       # a bus at its stop goes too
			n += 1
	return n


# The vehicles in the grid cells along the way `fwd` from p, up to `reach` ahead.
func _near(p: Vector2, fwd: Vector2, reach: float) -> Array:
	var q := p + fwd * reach
	var c0 := Vector2i(floori((minf(p.x, q.x) - 10.0) / GRID), floori((minf(p.y, q.y) - 10.0) / GRID))
	var c1 := Vector2i(floori((maxf(p.x, q.x) + 10.0) / GRID), floori((maxf(p.y, q.y) + 10.0) / GRID))
	var out := []
	for cx in range(c0.x, c1.x + 1):
		for cy in range(c0.y, c1.y + 1):
			var cell = _grid.get(Vector2i(cx, cy))
			if cell != null:
				out.append_array(cell)
	return out


func _drive(v: Dictionary, dt: float) -> void:
	var spec: Dictionary = KINDS[v.kind]
	var e: Dictionary = edges.get(v.edge, {})
	if e.is_empty():
		_despawn(v); return
	var f := _front(v)
	var fwd: Vector2 = f[1]
	# Slow for the bend ahead.
	var s_ahead: float = minf(v.s + 14.0, e.len)
	var fwd_ahead: Vector2 = _at(e, s_ahead if v.dir == 1 else e.len - s_ahead)[1] * v.dir
	var bend: float = acos(clampf(fwd.dot(fwd_ahead), -1.0, 1.0))
	var want: float = spec.max * clampf(1.0 - bend / 1.1, 0.3, 1.0)
	if v.has("chase"):
		want = spec.max * 1.5 * clampf(1.0 - bend / 1.6, 0.45, 1.0)   # on a call: fast, and through the others
		v.ghost = 1.0
	var fleeing: bool = v.get("flee", 0.0) > 0.0
	if fleeing:
		v.flee -= dt
		want = spec.max * (1.35 if v.kind == "bike" else 1.7) * clampf(1.0 - bend / 1.5, 0.4, 1.0)   # away, flat out
	# Keep a gap to anything in front: other vehicles and the walker.
	# (A tram never goes through another tram, ghosting or not.)
	var gap := 1e9
	var olen_tram: float = KINDS.tram.len
	for o in _near(v.pos, fwd, 70.0):
		if o == v: continue
		if v.ghost > 0.0 and not (v.kind == "tram" and o.kind == "tram"): continue
		if (o.kind == "bike") != (v.kind == "bike"): continue   # bikes keep to their own edge of the street
		# The tram on the other track, coming the other way, is no obstacle.
		if v.kind == "tram" and o.kind == "tram" and o.edge != v.edge \
				and Vector2(-sin(o.get("yaw", 0.0)), -cos(o.get("yaw", 0.0))).dot(fwd) < 0.0:
			continue
		if v.kind == "tram" and o.kind == "tram" and o.edge == v.edge and o.dir == v.dir:
			if o.s > v.s:                      # on the same rails: measured along them, round bends too
				gap = minf(gap, o.s - v.s - olen_tram - 2.0)
			continue
		if v.kind == "tram" and o.kind == "tram" and edges.has(o.edge):
			var oe: Dictionary = edges[o.edge]
			if oe.ends[0 if o.dir == 1 else 1] == e.ends[1 if v.dir == 1 else 0]:
				gap = minf(gap, e.len - v.s + o.s - olen_tram - 2.0)   # just over the points ahead
				continue
		# Its position is its front (a knocked car's, the middle of its body).
		var olen: float = KINDS[o.kind].len * (0.5 if o.has("body") else 1.0)
		var d: Vector2 = o.pos - v.pos
		var along := d.dot(fwd)
		if along <= 0.0 or along > 40.0 + olen: continue
		if absf(d.cross(fwd)) > 2.4: continue
		gap = minf(gap, along - olen - 2.0)
	var pp: Vector2 = Vector2(player.x, player.z) - v.pos
	if not fleeing and pp.dot(fwd) > 0.0 and pp.dot(fwd) < 25.0 and absf(pp.cross(fwd)) < 2.6:
		gap = minf(gap, pp.dot(fwd) - 3.0)
	# And for pedestrians: anyone in its way ahead, or walking into it before
	# it gets there (looking a second and a half ahead), it stops short of.
	var room: float = PED_ROOM[v.kind]
	for q in (pedestrians if _ped_box.has_point(v.pos) and not fleeing else []):
		var rel: Vector2 = q[0] - v.pos
		var along := rel.dot(fwd)
		if along <= 0.0 or along > PED_SEES:
			continue
		var lat := rel.cross(fwd)
		var then := lat + (q[1] as Vector2).cross(fwd) * minf(along / maxf(v.speed, 1.0), 1.5)
		if absf(lat) < room or (absf(lat) < 6.0 and (absf(then) < room or signf(then) != signf(lat))):
			gap = minf(gap, along - PED_STOP)
	want = minf(want, maxf(0.0, (gap - 1.0) / 1.3))
	want = minf(want, sqrt(2.0 * spec.accel * 2.0 * maxf(0.0, gap - 1.0)))   # and able to stop in it
	# Buses and trams stop now and then, as if at a stop.
	if (v.kind == "bus" or v.kind == "tram") and not fleeing:
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
		if v.stuck > 5.0 and v.kind != "tram":
			v.ghost = 2.5; v.stuck = 0.0
		elif v.stuck > 30.0 and v.pos.distance_to(Vector2(focus.x, focus.z)) > 120.0 and not _occupied(v):
			_despawn(v); return                 # trams wait their turn; one jammed out of sight is taken off
	else:
		v.stuck = 0.0
	v.ghost = maxf(0.0, v.ghost - dt)
	# Move, crossing to the next edge at the end of this one.
	v.s += v.speed * dt
	var guard := 0
	while v.s > edges[v.edge].len and guard < 4:
		var over: float = v.s - edges[v.edge].len
		var turn := 2 if _next(v) else _turn_tram(v)
		if turn == 2:
			v.s = over
		elif turn == 1:
			v.s += over
		elif turn == -1:
			v.s = edges[v.edge].len; v.speed = 0.0   # the track back is not clear yet: wait at the end
			break
		else:
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
