extends SceneTree
## The boats you can take (scripts/boats.gd): along a canal there are plenty
## of them, soon, and some close to you, each moored apart from the others on
## open water.
##     godot --headless --path godot-city --script tests/fleet_test.gd

const Boats := preload("res://scripts/boats.gd")

class Canal:                          # one canal, 600 by 20 m, along x
	var tiles := {}
	func _init() -> void:
		var ring := PackedVector2Array([Vector2(-300, -10), Vector2(300, -10), Vector2(300, 10), Vector2(-300, 10)])
		tiles["0_0"] = {"state": "ready", "result": {"water": [[ring]]}}
	func water_at(p: Vector3) -> int:
		return 1 if absf(p.x) < 300.0 and absf(p.z) < 10.0 else 0

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
	for i in 60 * 5:
		await physics_frame
	var n: int = boats.boats.size()
	_check(n >= 30, "a canal has plenty of boats after 5 s (%d)" % n)
	var apart := true
	var afloat := true
	var near := 0
	for a in boats.boats:
		if s.water_at(Vector3(a.pos.x, 0, a.pos.y)) != 1: afloat = false
		if a.pos.length() < 150.0: near += 1
		for b in boats.boats:
			if a != b and a.pos.distance_to(b.pos) < 9.0: apart = false
	_check(apart, "each moored apart from the others")
	_check(afloat, "all on the water")
	_check(near >= 6, "and some close to you (%d within 150 m)" % near)
	print("fleet test: %d failed" % _fails)
	quit(1 if _fails else 0)
