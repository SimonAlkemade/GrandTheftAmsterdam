extends SceneTree
## The boats you can take (scripts/boats.gd): along a canal there are plenty
## of them, soon, and many close to you, each moored apart from the others on
## open water; the far ones cost nothing (frozen: no physics; out of sight
## range: not drawn).
##     godot --headless --path godot-city --script tests/fleet_test.gd

const Boats := preload("res://scripts/boats.gd")

class Canal:                          # one canal, 1000 by 20 m, along x
	var tiles := {}
	func _init() -> void:
		var ring := PackedVector2Array([Vector2(-500, -10), Vector2(500, -10), Vector2(500, 10), Vector2(-500, 10)])
		tiles["0_0"] = {"state": "ready", "result": {"water": [[ring]]}}
	func water_at(p: Vector3) -> int:
		return 1 if absf(p.x) < 500.0 and absf(p.z) < 10.0 else 0

var _fails := 0


func _initialize() -> void:
	var bed := StaticBody3D.new()               # the canal bed, as the chunks build it
	bed.collision_layer = 2
	var cs := CollisionShape3D.new(); cs.shape = WorldBoundaryShape3D.new()
	bed.add_child(cs)
	bed.position.y = -2.6
	root.add_child(bed)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _run() -> void:
	var s := Canal.new()
	var boats = Boats.new()
	boats.streamer = s
	boats.target = Boats.TARGET
	boats.focus = Vector3.ZERO
	root.add_child(boats)
	for i in 60 * 8:
		await physics_frame
	var n: int = boats.boats.size()
	_check(n >= 100, "a canal is lined with boats after 8 s (%d)" % n)
	var apart := true
	var afloat := true
	var near := 0
	for a in boats.boats:
		if s.water_at(Vector3(a.pos.x, 0, a.pos.y)) != 1: afloat = false
		if a.pos.length() < 200.0: near += 1
		for b in boats.boats:
			if a != b and a.pos.distance_to(b.pos) < 9.0: apart = false
	_check(apart, "each moored apart from the others")
	_check(afloat, "all on the water")
	_check(near >= 30, "and many close to you (%d within 200 m)" % near)
	# The far ones: frozen, and then no physics at all; and not drawn from afar.
	var far = null
	for a in boats.boats:
		if a.pos.length() > 250.0 and a.boat.freeze: far = a; break
	_check(far != null, "far boats are frozen")
	if far != null:
		var t0: float = far.boat._t
		for i in 60:
			await physics_frame
		_check(far.boat._t == t0, "and a frozen boat does no physics work")
	var ranged := true
	for a in boats.boats:
		for mi in (a.boat as Node).find_children("*", "MeshInstance3D", true, false):
			var r: float = (mi as MeshInstance3D).visibility_range_end
			if r <= 0.0 or r > 300.0: ranged = false
	_check(ranged, "a boat is not drawn from further than 300 m")
	print("fleet test: %d failed" % _fails)
	quit(1 if _fails else 0)
