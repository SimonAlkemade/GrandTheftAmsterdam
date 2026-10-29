extends SceneTree
## A person knocked over goes limp: hit at 25 km/h on open ground they fly,
## fall flat and tumble on a few metres, the limbs staying joined at the
## shoulders, elbows, hips and knees; they come to rest, and restore() puts
## the figure back together, every mesh on its own joint again. And on the
## street, among pedestrians: a car you drive through someone, or you sprinting
## into them, knocks them down; walking into them does not; and once they lie
## still they get up and walk on.
##     godot --headless --path godot-city --script tests/ragdoll_test.gd

const Human := preload("res://scripts/human.gd")
const Ragdoll := preload("res://scripts/ragdoll.gd")
const Walker := preload("res://scripts/walker.gd")
const Traffic := preload("res://scripts/traffic.gd")


class OpenStreet:                     # open street everywhere
	func water_at(_p: Vector3) -> int: return 0


var _fails := 0


func _initialize() -> void:
	# The street: a big flat floor on the ground layer.
	var floor := StaticBody3D.new()
	floor.collision_layer = 2
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(400, 1, 400)
	cs.shape = box; cs.position.y = -0.5
	floor.add_child(cs)
	root.add_child(floor)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _meshes(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if c is MeshInstance3D: out.append([c, n, c.transform])
		out += _meshes(c)
	return out


func _run() -> void:
	await _alone()
	await _street()
	print("ragdoll test: %d failed" % _fails)
	quit(1 if _fails else 0)


func _alone() -> void:
	var h := Human.new()
	h.random_look(RandomNumberGenerator.new())
	root.add_child(h)
	var before := _meshes(h)
	await physics_frame
	var rag = Ragdoll.knock(h, Vector3(7.0, 1.5, 0.0))
	_check(_meshes(h).is_empty() and rag.bodies.size() == 10, "knocked: the figure's meshes are on %d bodies" % rag.bodies.size())
	# Neighbouring bodies, and how far apart they started.
	var pairs := []
	for k in [[0, 1], [1, 2], [2, 3], [1, 4], [4, 5], [0, 6], [6, 7], [0, 8], [8, 9]]:
		pairs.append([k[0], k[1], rag.bodies[k[0]].global_position.distance_to(rag.bodies[k[1]].global_position)])
	var worst := 0.0
	var lowest := INF
	var t_rest := -1.0
	for i in 60 * 8:
		await physics_frame
		for pr in pairs:
			var d: float = rag.bodies[pr[0]].global_position.distance_to(rag.bodies[pr[1]].global_position)
			worst = maxf(worst, absf(d - pr[2]))
		lowest = minf(lowest, rag.pelvis().y)
		if t_rest < 0.0 and rag.settled():
			t_rest = i / 60.0
			break
	var p: Vector3 = rag.pelvis()
	print("ragdoll: came to rest after %.1f s, %.1f m on, pelvis %.2f m up; joints stretched at most %.2f m" % [t_rest, p.x, p.y, worst])
	_check(p.y < 0.35, "it falls flat (pelvis %.2f m up)" % p.y)
	_check(p.x > 1.5 and p.x < 12.0, "thrown on a few metres (%.1f m)" % p.x)
	_check(lowest > -0.1, "and never through the street (lowest %.2f m)" % lowest)
	_check(worst < 0.12, "the limbs stay joined (stretched at most %.2f m)" % worst)
	_check(t_rest > 0.0, "and it comes to rest (%.1f s)" % t_rest)
	rag.restore()
	await physics_frame
	var after := _meshes(h)
	var same := after.size() == before.size()
	for m in before:                  # (their order among the joint's children may differ)
		var mi: MeshInstance3D = m[0]
		if mi.get_parent() != m[1] or not mi.transform.is_equal_approx(m[2]):
			same = false
	_check(same and h.visible, "restored: every mesh back on its own joint (%d of %d)" % [after.size(), before.size()])
	h.queue_free()


func _street() -> void:
	var traffic = Traffic.new()
	traffic.enabled = false
	root.add_child(traffic)
	var w = Walker.new()
	w.streamer = OpenStreet.new()
	w.traffic = traffic
	root.add_child(w)
	await process_frame
	w.set_physics_process(false)
	w.global_position = Vector3(0, 0, 0)
	var rng := RandomNumberGenerator.new()
	var ped := func(at: Vector3) -> Dictionary:
		var p := {"h": Human.new(), "pos": at, "heading": 0.0, "speed": 0.0, "turn": 1e9, "stag": 0.0}
		p.h.random_look(rng)
		root.add_child(p.h)
		w.peds.append(p)
		return p
	# 1. Walking into someone: they step aside, no more.
	var a: Dictionary = ped.call(Vector3(0, 0, -0.5))
	w.speed = 1.7
	w._peds(1.0 / 60.0)
	_check(not a.has("rag"), "walking into someone only nudges them")
	# 2. Sprinting into someone knocks them down; they lie still, then get up.
	var b: Dictionary = ped.call(Vector3(3, 0, -0.5))
	w.global_position = Vector3(3, 0, 0)
	w.heading = 0.0
	w.speed = 6.2
	w._peds(1.0 / 60.0)
	_check(b.has("rag"), "sprinting into someone knocks them over")
	w.speed = 0.0
	w.global_position = Vector3(-30, 0, 30)
	var up := -1.0
	for i in 60 * 12:
		await physics_frame
		w._peds(1.0 / 60.0)
		if not b.has("rag"):
			up = i / 60.0
			break
	_check(up > 1.0, "and get up again once they lie still (after %.1f s)" % up)
	_check(b.h.visible and absf(b.h.rotation.x) < 0.01, "standing, in one piece")
	# 3. A car driven through someone at 40 km/h.
	var c: Dictionary = ped.call(Vector3(18.0, 0, 0.3))
	var car := {"kind": "car", "parts": [], "speed": 11.0, "pos": Vector2(18.5, 0)}
	var n := Node3D.new(); root.add_child(n)
	n.position = Vector3(18.5 - 2.1, 0, 0); n.rotation.y = -PI / 2.0          # heading +x
	car.parts.append([n, 0.0, 4.2])
	traffic.vehicles.append(car)
	w._peds(1.0 / 60.0)
	_check(c.has("rag"), "a car driven into someone sends them flying")
	if c.has("rag"):
		var v: Vector3 = c.rag.bodies[0].linear_velocity
		_check(v.x > 8.0, "the way the car was going (%.1f m/s)" % v.x)
