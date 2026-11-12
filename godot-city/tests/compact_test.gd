extends SceneTree
## The compact city (compact_city.py, res://data-compact/, layout v2: the whole
## city inside the A10 and the Arena at 0.45 of its size): its index loads
## with its outline and petrol stations enough, it is about 5 x 4 km, past its
## edge you are held on it (on foot, swimming, by boat), inside you go where
## you like, and the real city's fixed points (the Bloemenmarkt, the Damrak
## boat) are brought in with it.
##     godot --headless --path godot-city --script tests/compact_test.gd

const Walker := preload("res://scripts/walker.gd")
const Boat := preload("res://scripts/boat.gd")
const Streamer := preload("res://scripts/city_streamer.gd")
const Mission := preload("res://scripts/mission.gd")

class Island:
	var tiles := {}
	var index := {}
	func water_at(_p: Vector3) -> int: return 1
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return ""
	func start_point() -> Vector3: return Vector3.ZERO
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

var _fails := 0


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _dist_to_edge(p: Vector2, edge: PackedVector2Array) -> float:
	var best := INF
	for k in edge.size():
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, edge[k], edge[(k + 1) % edge.size()])))
	return best


func _run() -> void:
	var ix = JSON.parse_string(FileAccess.get_file_as_string("res://data-compact/index.json"))
	_check(typeof(ix) == TYPE_DICTIONARY and ix.has("compact") and ix.compact.has("edge"), "the compact city's index, with its outline")
	var edge := PackedVector2Array()
	var f: Array = ix.compact.edge
	for k in range(0, f.size() - 1, 2):
		edge.append(Vector2(float(f[k]) / 10.0, -float(f[k + 1]) / 10.0))
	var r := Rect2(edge[0], Vector2.ZERO)
	for p in edge:
		r = r.expand(p)
	_check(r.size.x < 5500.0 and r.size.y < 5500.0 and r.size.x > 3500.0, "about 5 x 4 km: %.1f x %.1f km" % [r.size.x / 1000.0, r.size.y / 1000.0])
	_check(ix.chunks.size() < 300, "%d chunks" % ix.chunks.size())
	var inside: bool = ix.stations.all(func(s): return Geometry2D.is_point_in_polygon(Vector2(float(s[1]) / 10.0, -float(s[2]) / 10.0), edge))
	_check(ix.stations.size() >= 15 and inside, "%d petrol stations, all inside" % ix.stations.size())
	# The edge: swim (or sail) out and you are held on it.
	var st := Island.new()
	st.index = ix
	var w = Walker.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(st, cam)
	root.add_child(w)
	w.active = true
	var west := Vector2(r.position.x - 900.0, r.get_center().y)
	w.global_position = Vector3(west.x, -1.4, west.y)
	w._island_edge()
	var at := Vector2(w.global_position.x, w.global_position.z)
	_check(_dist_to_edge(at, edge) < 1.0 and at.x > west.x + 800.0, "swimming out: held on the edge (%.0f m off it)" % _dist_to_edge(at, edge))
	var boat = Boat.new()
	root.add_child(boat)
	var south := Vector2(r.get_center().x, r.end.y + 600.0)
	boat.global_position = Vector3(south.x, -1.4, south.y)
	boat.linear_velocity = Vector3(0, 0, 8.0)                # (sailing on, south: outwards)
	w.vehicle = {"kind": "boat", "boat": boat}
	w._island_edge()
	at = Vector2(boat.global_position.x, boat.global_position.z)
	var outwards := (south - at).normalized()               # (along the edge it may still go)
	var v_out: float = Vector2(boat.linear_velocity.x, boat.linear_velocity.z).dot(outwards)
	_check(_dist_to_edge(at, edge) < 1.0 and v_out < 0.01, "by boat: held there, no speed outwards (%.2f m/s)" % v_out)
	w.vehicle = null
	var dam := Vector2(float(ix.start[0]) / 10.0, -float(ix.start[1]) / 10.0)
	w.global_position = Vector3(dam.x + 100.0, 0, dam.y)
	w._island_edge()
	_check(w.global_position.is_equal_approx(Vector3(dam.x + 100.0, 0, dam.y)), "in the city: free to go anywhere")
	# The real city's fixed points, brought in with it.
	var s = Streamer.new()
	s.index = ix
	_check(s.compact_point(dam).distance_to(dam) < 0.01, "the Dam stays where it is")
	var bm: Vector2 = s.compact_point(Mission.BLOEMENMARKT)
	_check(absf(bm.distance_to(dam) - Mission.BLOEMENMARKT.distance_to(dam) * 0.45) < 1.0, "the Bloemenmarkt: 0.45 as far from the Dam (%.0f m)" % bm.distance_to(dam))
	s.free()
	print("compact test: %d failed" % _fails)
	quit(1 if _fails else 0)
