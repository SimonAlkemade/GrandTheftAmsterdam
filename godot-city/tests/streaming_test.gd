extends SceneTree
## A chunk built in slices (as the browser does it, with no threads) comes out
## the same as one built at once, while the game keeps getting frames: no
## gap between two frames of more than a few slices' time. And the parked
## bikes in it stand at least 3 m apart.
##     godot --headless --path godot-city --script tests/streaming_test.gd

const TileBuilder := preload("res://scripts/tile_builder.gd")
const Streamer := preload("res://scripts/city_streamer.gd")

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _run() -> void:
	# The busiest file: the old centre.
	var d = JSON.parse_string(FileAccess.get_file_as_string("res://data/tiles/-1_-1.json"))
	var key: String = ""
	for k in d.chunks:
		if key == "" or d.chunks[k].get("buildings", []).size() > d.chunks[key].get("buildings", []).size():
			key = k
	var c: Dictionary = d.chunks[key]
	var a := Time.get_ticks_usec()
	var whole = await TileBuilder.new().build_tile(c)
	var at_once := (Time.get_ticks_usec() - a) / 1000.0
	var tb := TileBuilder.new()
	tb.budget_usec = 4000
	var gaps := []
	var last := [Time.get_ticks_usec()]
	var tick := func():
		var now := Time.get_ticks_usec()
		gaps.append((now - last[0]) / 1000.0); last[0] = now
	process_frame.connect(tick)
	var sliced = await tb.build_tile(c)
	process_frame.disconnect(tick)
	var longest: float = gaps.max() if gaps.size() else at_once
	print("chunk %s (%d buildings): %.0f ms at once; in slices over %d frames, the longest %.1f ms" % [key, c.buildings.size(), at_once, gaps.size(), longest])
	_check(gaps.size() > 5, "built a slice a frame (%d frames)" % gaps.size())
	_check(longest < at_once / 4.0, "never holding a frame up for long (%.1f of %.0f ms)" % [longest, at_once])
	var same: bool = whole.surfaces.keys() == sliced.surfaces.keys() and whole.walls.size() == sliced.walls.size() \
		and whole.ground_faces.size() == sliced.ground_faces.size() and whole.street_bikes[0].size() == sliced.street_bikes[0].size()
	for m in whole.surfaces:
		if whole.surfaces[m][0].size() != sliced.surfaces[m][0].size(): same = false
	_check(same, "and the same chunk as built at once")
	# Its parked bikes: in racks, and in groups along the house fronts.
	var st = Streamer.new()
	var inst: Dictionary = st._instance_buffers(whole.points, whole.street_bikes, whole.bridge_cells)
	var n: int = inst.bikes[0]
	var buf: PackedFloat32Array = inst.bikes[1]
	var closest := INF
	for i in n:
		var bi := Vector2(buf[i * 16 + 3], buf[i * 16 + 11])
		for j in range(i + 1, n):
			closest = minf(closest, bi.distance_to(Vector2(buf[j * 16 + 3], buf[j * 16 + 11])))
	st.free()
	print("parked bikes: %d, the closest two %.2f m apart" % [n, closest])
	_check(n > 20 and closest >= Streamer.BIKE_SPACE - 0.001, "parked bikes stand at least %.0f m apart (closest %.2f m, %d bikes)" % [Streamer.BIKE_SPACE, closest, n])
	print("streaming test: %d failed" % _fails)
	quit(1 if _fails else 0)
