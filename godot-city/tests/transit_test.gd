extends SceneTree
## Getting off a tram or bus at a stop (scripts/transit.gd): riding one as a
## passenger, a list of well-known stops (each on its real street), nearest
## first, the one you are at left out; a number key fades the screen to black,
## takes you off and puts you down at that stop, and fades back in. Driving a
## tram, or on foot, there is no list and the keys do nothing.
##     godot --headless --path godot-city --script tests/transit_test.gd

const Walker := preload("res://scripts/walker.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Transit := preload("res://scripts/transit.gd")
const VPhys := preload("res://scripts/vehicle_physics.gd")

class OpenStreet:
	signal tile_added(key: String, result: Dictionary)
	signal tile_removed(key: String)
	var tiles := {}
	var index := {"stations": []}
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN
	func stats() -> Dictionary: return {"ready": 1, "loading": 0, "buildings": 0}

var _fails := 0
var _tiles := {}               # (the full data's tiles, read once)
var w
var traffic
var transit


func _initialize() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = VPhys.GROUND_LAYER
	var fcs := CollisionShape3D.new(); var fb := BoxShape3D.new(); fb.size = Vector3(3000, 1, 3000)
	fcs.shape = fb; fcs.position.y = -0.5
	floor.add_child(fcs)
	root.add_child(floor)
	traffic = Traffic.new()
	root.add_child(traffic)
	var cut := []
	for k in 7:
		var c := -300.0 + k * 100.0
		for seg in 6:
			var a := -300.0 + seg * 100.0
			cut.append({"kind": "tram", "w": 8.0, "p": PackedVector2Array([Vector2(a, c), Vector2(a + 100.0, c)])})
	traffic.add_tile("grid", cut)
	traffic.target = {"car": 0, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	w = Walker.new()
	w.traffic = traffic
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(OpenStreet.new(), cam)
	root.add_child(w)
	w.active = true
	transit = Transit.new()
	root.add_child(transit)
	transit.setup(w, w.streamer)
	w.transit = transit
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(secs: float) -> void:
	for i in int(secs * 60.0):
		w._physics_process(1.0 / 60.0)
		traffic._process(1.0 / 60.0)
		await physics_frame


func _key(k: Key) -> void:
	var e := InputEventKey.new()
	e.pressed = true; e.physical_keycode = k; e.keycode = k
	w._unhandled_input(e)


# The full city data's chunks round p (data decimetres): the tile it is in and its neighbours.
func _chunks_round(p: Vector2) -> Array:
	var ix = JSON.parse_string(FileAccess.get_file_as_string("res://data/index.json"))
	var size: float = float(ix.tile) * 10.0
	var out := []
	for di in [-1, 0, 1]:
		for dj in [-1, 0, 1]:
			var key := "%d_%d" % [int(floor(p.x / size)) + di, int(floor(p.y / size)) + dj]
			if not _tiles.has(key):
				var path := "res://data/tiles/%s.json" % key
				_tiles[key] = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
			if _tiles[key] != null: out.append_array(_tiles[key].chunks.values())
	return out


# How far (metres) the nearest place called `name` is from p, in the full city data.
func _to_place(name: String, p: Vector2, chunks: Array) -> float:
	var best := INF
	for c in chunks:
		for pl in c.get("places", []):
			if pl[0] == name:
				best = minf(best, Vector2(pl[2], pl[3]).distance_to(p) / 10.0)
	return best


# Whether p stands in a building or in the water.
func _blocked(p: Vector2, chunks: Array) -> bool:
	for c in chunks:
		for bd in c.get("buildings", []):
			var r: Array = bd.r[0] if bd.has("r") else bd.g
			var poly := PackedVector2Array()
			for k in range(0, r.size() - 1, 2): poly.append(Vector2(r[k], r[k + 1]))
			if Geometry2D.is_point_in_polygon(p, poly): return true
		for w in c.get("water", []):
			var r: Array = w.r[0]
			var poly := PackedVector2Array()
			for k in range(0, r.size() - 1, 2): poly.append(Vector2(r[k], r[k + 1]))
			if Geometry2D.is_point_in_polygon(p, poly): return true
	return false


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false)
	# 1. The stops: each at its real place in the city data, on open ground.
	const AT := {"Centraal Station": ["Stationsplein", 40.0], "Rembrandtplein": ["Rembrandtplein", 40.0],
		"Artis": ["Artisplein", 40.0], "De Pijp": ["Albert Cuyp Market", 40.0], "Westerkerk": ["Westerkerk", 60.0],
		"Dam": ["Koninklijk Paleis Amsterdam", 120.0], "Leidseplein": ["Leidseplein Theater", 120.0],
		"Museumplein": ["Van Gogh Museum", 150.0], "Waterlooplein": ["Double M Waterlooplein", 40.0]}
	const PARK_GATE := Vector2(-9031, -14238)              # the Vondelpark's outline at its eastern tip
	var all_at := true
	for st in Transit.STOPS:
		var p := Vector2(st[1], st[2])
		var chunks := _chunks_round(p)
		var off: float = PARK_GATE.distance_to(p) / 10.0 if st[0] == "Vondelpark" else _to_place(AT[st[0]][0], p, chunks)
		var limit: float = 40.0 if st[0] == "Vondelpark" else AT[st[0]][1]
		var blocked := _blocked(p, chunks)
		if off > limit or blocked:
			all_at = false
			print("  %s: %.0f m from its place (at most %.0f)%s" % [st[0], off, limit, ", in a building or the water" if blocked else ""])
	_check(Transit.STOPS.size() == 10 and all_at, "ten stops, each at its real place (the station's front square, the park gate...) on open ground")
	# 2. On the test grid, stops of its own: two near, the rest farther.
	transit.stops = [["Here", Vector2(10, 0)], ["Near", Vector2(330, -150)], ["Far", Vector2(-300, 300)], ["Middle", Vector2(320, 0)]]
	var l: Array = transit.stops_from(Vector2(0, 0))
	_check(l.size() == 3 and l[0][0] == "Middle" and l[2][0] == "Far", "the one you are at left out, nearest first (%s)" % str(l.map(func(x): return x[0])))
	# 3. On foot: no list, the keys do nothing.
	w.global_position = Vector3(0, 0, 0)
	await _step(0.2)
	_check(not transit.panel_shown(), "on foot: no list")
	_key(KEY_1)
	_check(not transit.busy, "and the keys do nothing")
	# 4. A passenger on a tram: the list, and key 2 takes you to the second stop.
	traffic.focus = Vector3(0, 0, 0)
	for k in 20:
		if traffic.vehicles.any(func(v): return v.kind == "tram"): break
		traffic._spawn("tram")
	var tram: Dictionary = traffic.vehicles.filter(func(v): return v.kind == "tram")[0]
	tram.rider = true
	w.vehicle = tram
	await _step(0.2)
	var seat := Vector2(w.global_position.x, w.global_position.z)          # (wherever the tram came)
	transit.stops = [["A", seat + Vector2(320, 0)], ["B", seat + Vector2(0, -360)], ["C", seat + Vector2(-420, 0)]]
	transit._t = 0.0
	await _step(0.1)
	var seen: Array = transit.stops_from(seat)
	var second: Array = seen[1]
	_check(transit.panel_shown() and transit.panel_text().contains("2  %s" % second[0]), "riding a tram: the stops listed")
	_key(KEY_2)
	_check(transit.busy, "a number: the screen fades")
	var darkest := 0.0
	for i in 90:
		await _step(1.0 / 60.0)
		darkest = maxf(darkest, transit.black_alpha())
	var at := Vector2(w.global_position.x, w.global_position.z)
	_check(darkest > 0.99, "to black")
	_check(w.vehicle == null and at.distance_to(second[1]) < 40.0 and absf(w.global_position.y) < 0.5,
		"you get off at that stop, %s (%.0f m from it)" % [second[0], at.distance_to(second[1])])
	_check(not transit.busy and transit.black_alpha() < 0.01, "and the screen is back")
	# 5. Driving a tram: no list, the keys do nothing.
	tram.rider = false; tram.driven = true
	w.vehicle = tram
	await _step(0.2)
	_check(not transit.panel_shown(), "driving a tram: no list")
	_key(KEY_1)
	_check(not transit.busy, "and the keys do nothing")
	print("transit test: %d failed" % _fails)
	quit(1 if _fails else 0)
