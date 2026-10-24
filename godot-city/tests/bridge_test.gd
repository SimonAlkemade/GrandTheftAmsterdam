extends SceneTree
## In the city: sail a sloep under the bridge over a canal nearest the start
## (it must come out the other side, on the water, with the camera below the
## deck), then walk up onto the bridge (your feet must be on its hump).
##     xvfb-run godot --rendering-driver opengl3 --path godot-city --script tests/bridge_test.gd -- [--bshot=out.png]

const TileBuilder := preload("res://scripts/tile_builder.gd")

var shot := ""
var _fails := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bshot="): shot = a.substr(8)   # not --shot: main.gd takes that one
	var m = load("res://scripts/main.gd").new()
	root.add_child(m)
	_go.call_deferred(m)


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


# Canal water under q, bridge or not (water_at says 2 under a bridge).
func _water(m, q: Vector2) -> bool:
	var r: Dictionary = m.streamer.tile_at(Vector3(q.x, 0, q.y))
	if r.is_empty(): return false
	for rings in r.water:
		if Geometry2D.is_point_in_polygon(q, rings[0]): return true
	return false


func _go(m) -> void:
	while not m.walker.active or m.streamer.stats().loading > 0:
		await process_frame
	var start := Vector2(m.walker.global_position.x, m.walker.global_position.z)
	# The nearest bridge with open canal 16 m either side of its middle.
	var best = null
	for t in m.streamer.tiles.values():
		if t.state != "ready": continue
		for line in t.result.bridges:
			if line.size() < 6: continue
			var mid: Vector2 = line[line.size() / 2]
			var canal: Vector2 = (line[line.size() - 1] - line[0]).normalized().orthogonal()
			var ok := true
			for k in [-16.0, -10.0, 10.0, 16.0]:
				if m.streamer.water_at(Vector3(mid.x + canal.x * k, 0, mid.y + canal.y * k)) != 1: ok = false
			if ok and _water(m, mid) and (best == null or mid.distance_to(start) < best[0].distance_to(start)):
				best = [mid, canal, line]
	if best == null:
		print("FAIL no bridge over a canal near the start"); quit(1); return
	var mid: Vector2 = best[0]; var canal: Vector2 = best[1]; var line: PackedVector2Array = best[2]
	var deck: float = m.streamer.bridge_y(Vector3(mid.x, 0, mid.y))
	var under := deck - TileBuilder.BRIDGE_DEPTH
	print("bridge %.0f m from the start: deck %.2f, underside %.2f, water %.2f" % [mid.distance_to(start), deck, under, -1.4])
	_check(under - (-1.4) > 2.2, "the middle clears the water by %.2f m" % (under + 1.4))

	# Full ahead from 16 m out, straight under it.
	var from := mid - canal * 16.0
	var b: Dictionary = m.boats.add(from, atan2(-canal.x, -canal.y))
	m.walker.global_position = Vector3(from.x, 0, from.y)
	await physics_frame
	m.walker._board(b)
	var boat: RigidBody3D = b.boat
	var top := -9.0
	var passed := false
	var cam_under := false
	for i in 60 * 14:
		boat.throttle = 1.0
		await physics_frame
		top = maxf(top, boat.global_position.y)
		var along: float = (Vector2(boat.global_position.x, boat.global_position.z) - mid).dot(canal)
		if along > 1.5 and not cam_under:
			boat.throttle = 0.0
			boat.linear_velocity = Vector3.ZERO      # hold still under the deck for a look
			for k in 6: await process_frame
			var c: Vector3 = m.walker.cam.global_position
			var over: float = m.streamer.bridge_y(c)
			cam_under = true
			_check(is_nan(over) or c.y < over - TileBuilder.BRIDGE_DEPTH - 0.2,
				"the camera stays below the deck (camera y %.2f)" % c.y)
			if shot != "":
				root.get_texture().get_image().save_png(shot)
		if along > 10.0:
			passed = true; break
	_check(passed, "the boat sails out the other side")
	_check(top < -1.0, "and stays on the water (highest y %.2f)" % top)

	# Ashore at one end, and walk up onto the middle with the real controls.
	m.walker._get_out()
	var end: Vector2 = line[0]
	var up := (mid - end).normalized()
	m.walker.global_position = Vector3(end.x - up.x, 0, end.y - up.y)
	m.walker.state = "idle"; m.walker.grounded = true
	m.walker._mouse_idle = 0.0
	var e := InputEventKey.new(); e.physical_keycode = KEY_W; e.pressed = true
	Input.parse_input_event(e)
	var feet := -9.0
	for i in 60 * 12:
		m.walker.cam_yaw = atan2(-up.x, -up.y)     # W walks where the camera looks: up the bridge
		await physics_frame
		if (Vector2(m.walker.global_position.x, m.walker.global_position.z) - end).dot(up) >= end.distance_to(mid):
			feet = m.walker.global_position.y
			break
	e = InputEventKey.new(); e.physical_keycode = KEY_W; e.pressed = false
	Input.parse_input_event(e)
	_check(absf(feet - deck) < 0.15, "walked up onto the middle of the bridge (feet %.2f, deck %.2f)" % [feet, deck])
	if shot != "":
		for k in 6: await process_frame
		root.get_texture().get_image().save_png(shot.replace(".png", "-top.png"))
	# The street traffic rides over the hump.
	for v in m.traffic.vehicles:
		var n: Node3D = v.parts[0][0]
		var y: float = m.streamer.bridge_y(n.position)
		if not is_nan(y) and v.kind != "bike":
			_check(absf(n.position.y - y) < 0.3, "a %s on a bridge rides its deck (y %.2f, deck %.2f, pitch %.1f°)" % [
				v.kind, n.position.y, y, rad_to_deg(n.rotation.x)])
	print("bridge test: %d failed" % _fails)
	quit(1 if _fails else 0)
