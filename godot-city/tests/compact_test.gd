extends SceneTree
## The compact city (compact_city.py, res://data-compact/): its index loads
## with the island's shape and petrol stations enough, it is small, and out on
## the water round the island you are held a little way off its shore, on
## foot or in a boat.
##     godot --headless --path godot-city --script tests/compact_test.gd

const Walker := preload("res://scripts/walker.gd")
const Boat := preload("res://scripts/boat.gd")

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


func _run() -> void:
	var ix = JSON.parse_string(FileAccess.get_file_as_string("res://data-compact/index.json"))
	_check(typeof(ix) == TYPE_DICTIONARY and ix.has("compact"), "the compact city's index")
	var b: Array = ix.bounds
	var across: float = (float(b.slice(0, 8, 2).max()) - float(b.slice(0, 8, 2).min())) / 10.0
	_check(across < 4200.0 and ix.chunks.size() < 300, "small: %.1f km across with its water, %d chunks" % [across / 1000.0, ix.chunks.size()])
	_check(ix.stations.size() >= 15, "%d petrol stations on the island" % ix.stations.size())
	var island_r: float = float(ix.compact.island) / 10.0
	var centre := Vector2(float(ix.compact.centre[0]) / 10.0, -float(ix.compact.centre[1]) / 10.0)
	var all_on: bool = ix.stations.all(func(s): return Vector2(float(s[1]) / 10.0, -float(s[2]) / 10.0).distance_to(centre) < island_r)
	_check(all_on, "every station on the island")
	# The edge: swim (or sail) out and you are held there.
	var st := Island.new()
	st.index = ix
	var w = Walker.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(st, cam)
	root.add_child(w)
	w.active = true
	w.global_position = Vector3(centre.x + island_r + 900.0, -1.4, centre.y)
	w._island_edge()
	var d: float = Vector2(w.global_position.x, w.global_position.z).distance_to(centre)
	_check(absf(d - (island_r + Walker.EDGE)) < 1.0, "swimming out: held %.0f m off the shore" % (d - island_r))
	var boat = Boat.new()
	root.add_child(boat)
	boat.global_position = Vector3(centre.x, -1.4, centre.y - island_r - 600.0)
	boat.linear_velocity = Vector3(0, 0, -8.0)
	w.vehicle = {"kind": "boat", "boat": boat}
	w._island_edge()
	d = Vector2(boat.global_position.x, boat.global_position.z).distance_to(centre)
	_check(absf(d - (island_r + Walker.EDGE)) < 1.0 and boat.linear_velocity.z > -0.01, "by boat: held there, no speed outwards")
	w.vehicle = null
	w.global_position = Vector3(centre.x + 100.0, 0, centre.y)
	w._island_edge()
	_check(w.global_position.is_equal_approx(Vector3(centre.x + 100.0, 0, centre.y)), "on the island: free to go anywhere")
	print("compact test: %d failed" % _fails)
	quit(1 if _fails else 0)
