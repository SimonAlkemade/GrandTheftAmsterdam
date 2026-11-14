extends SceneTree
## The first mission (scripts/jobs/m00_harbour.gd, the yard scripts/harbour_yard.gd):
## the game starts with it, at the container yard on Zeeburgereiland; the yard
## is fenced (solid), twelve containers, the three of the north row open and
## the duffel bag in one of them; at the fence E cuts it (kneeling, the bolt
## cutters in your hands, the cut flap peeling up), E again crawls you under;
## E takes the bag; you crawl back out and bring it to the van: passed, and on
## to the parcel courier. Busted on it: failed, tried again, your hands empty.
##     godot --headless --path godot-city --script tests/harbour_test.gd

const Walker := preload("res://scripts/walker.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")
const Mission := preload("res://scripts/mission.gd")
const Harbour := preload("res://scripts/jobs/m00_harbour.gd")
const Yard := preload("res://scripts/harbour_yard.gd")
const VPhys := preload("res://scripts/vehicle_physics.gd")

class OpenStreet:
	signal tile_added(key: String, result: Dictionary)
	signal tile_removed(key: String)
	var tiles := {}
	var index := {"stations": []}
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Zuider IJdijk"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

const AT := Vector3(110, 0, -20)          # the yard on the test grid (between its streets)

var _fails := 0
var said := []
var w
var traffic
var crime
var mission


func _initialize() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = VPhys.GROUND_LAYER
	var fcs := CollisionShape3D.new(); var fb := BoxShape3D.new(); fb.size = Vector3(800, 1, 800)
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
			cut.append({"kind": "road", "w": 8.0, "p": PackedVector2Array([Vector2(a, c), Vector2(a + 100.0, c)])})
			cut.append({"kind": "road", "w": 8.0, "p": PackedVector2Array([Vector2(c, a), Vector2(c, a + 100.0)])})
	traffic.add_tile("grid", cut)
	traffic.target = {"car": 0, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	w = Walker.new()
	w.traffic = traffic
	var cam := Camera3D.new()
	root.add_child(cam)
	var street := OpenStreet.new()
	w.setup(street, cam)
	root.add_child(w)
	w.active = true
	crime = Crime.new()
	root.add_child(crime)
	mission = Mission.new()
	root.add_child(mission)
	mission.setup(street, traffic, w)
	crime.setup(w.streamer, traffic, w, mission)
	mission.crime = crime
	w.crime = crime
	crime.caught.connect(mission.caught)
	mission.announce.connect(func(t, s): said.append(t); print("  [%s] %s" % [t, s]))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(secs: float) -> void:
	for i in int(secs * 60.0):
		w._physics_process(1.0 / 60.0)
		mission._process(1.0 / 60.0)
		await physics_frame


func _stand(p: Vector3) -> void:
	w.global_position = Vector3(p.x, 0.0, p.z)


func _ray(a: Vector3, b: Vector3, mask: int) -> bool:
	return not w.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, mask)).is_empty()


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false); mission.set_process(false)
	crime.start()
	w.streamer.tile_added.emit("t", {"rect": Rect2(-300, -300, 600, 600)})
	await physics_frame
	# 1. The game starts with it, at the yard on Zeeburgereiland.
	mission.start()
	var job = mission.job
	_check(mission.state == "job" and job is Harbour and said.has(job.title), "the first mission: %s" % (job.title if job else "none"))
	_check(mission.target != Vector3.INF and Vector2(mission.target.x, mission.target.z).distance_to(
		Vector2(Yard.ORIGIN.x, Yard.ORIGIN.z)) < 120.0, "its target: the container yard in the eastern harbour")
	# 2. The same mission, its yard put on the test grid.
	mission.start_job_node(Harbour.new(), 0, AT)
	job = mission.job
	var yard = job.yard
	_check(yard.open_containers.size() == 3, "three containers stand open")
	var solid := 0
	for c in Yard.COLUMNS:
		for r in Yard.ROWS.slice(0, 3):
			var p: Vector3 = yard.at(c, r)
			if _ray(p + Vector3(-3, 1, 0), p + Vector3(0, 1, 0), VPhys.WALL_LAYER): solid += 1
	_check(solid == 9, "the other nine are solid (%d)" % solid)
	var bag: Vector3 = yard.bag_at()
	var inside := false
	for oc in yard.open_containers:
		var n: Node3D = oc[0]
		if absf(bag.x - n.position.x) < Yard.WIDTH / 2.0 and absf(bag.z - n.position.z) < Yard.LENGTH / 2.0: inside = true
	_check(inside, "the duffel bag lies in one of the open ones")
	_check(_ray(yard.cut_out() + Vector3(0, 1, 0), yard.cut_in() + Vector3(0, 1, 0), VPhys.WALL_LAYER), "the fence is solid")
	# 3. To the fence (anywhere in its circle): cut it.
	_stand(yard.cut_out() + Vector3(-2.9, 0, 0))
	await _step(0.2)
	_check(w.task.get("prompt", "") == "E  cut the fence", "in the circle by the fence: '%s'" % w.task.get("prompt", ""))
	_stand(yard.cut_out())
	await _step(0.2)
	_check(w.task.get("prompt", "") == "E  cut the fence", "at the fence: '%s'" % w.task.get("prompt", ""))
	(w.task.do as Callable).call()
	await _step(0.5)
	_check(w.performing() and w.state == "cut" and w.held != null, "cutting: kneeling, the bolt cutters in your hands")
	var cutter_anim: AnimationPlayer = w.held.find_child("AnimationPlayer", true, false) if w.held else null
	_check(cutter_anim != null and cutter_anim.is_playing() and cutter_anim.current_animation == "cut", "the cutters snipping")
	await _step(4.0)
	_check(not w.performing() and w.held == null, "done: the cutters put away")
	_check(yard.flap_anim != null and yard.flap_anim.current_animation == "peel" or (yard.flap_anim != null and yard.flap_anim.current_animation_position > 0.0),
		"the cut flap peels up")
	_check(w.task.get("prompt", "") == "E  crawl under the fence", "then: '%s'" % w.task.get("prompt", ""))
	# 4. Under it.
	(w.task.do as Callable).call()
	await _step(0.4)
	_check(w.state == "crawl", "crawling under")
	await _step(3.0)
	_check(w.global_position.x > yard.at(1.0, 0).x and job.phase == "search", "in the yard (%s)" % job.phase)
	_check(mission.objective().contains("duffel bag"), "objective: '%s'" % mission.objective())
	# 5. The bag.
	_stand(bag + Vector3(0, 0, 1.0))
	await _step(0.2)
	_check(w.task.get("prompt", "") == "E  take the duffel bag", "by the bag: '%s'" % w.task.get("prompt", ""))
	(w.task.do as Callable).call()
	await _step(0.2)
	_check(w.held != null and yard.bag_at() == Vector3.INF, "the bag in your hand")
	# 6. Out the way you came, to the van.
	_stand(yard.cut_in())
	await _step(0.2)
	_check(w.task.get("prompt", "") == "E  crawl under the fence", "back at the hole: '%s'" % w.task.get("prompt", ""))
	(w.task.do as Callable).call()
	await _step(3.5)
	_check(w.global_position.x < yard.at(0, 0).x and w.held != null, "out, with the bag")
	_check(mission.objective().contains("van"), "objective: '%s'" % mission.objective())
	var money_before: int = mission.money
	_stand(yard.at(Yard.VAN.x + 2.5, Yard.VAN.y))
	await _step(0.5)
	_check(said.has("MISSION PASSED") and mission.money > money_before, "at the van: passed (+€%d)" % (mission.money - money_before))
	_check(w.held == null and w.task.is_empty(), "your hands empty again")
	await _step(6.0)
	_check(mission.state == "pickup", "and on to the parcel courier (%s)" % mission.state)
	# 7. Busted on it: failed, tried again.
	said.clear()
	mission.start_job_node(Harbour.new(), 0, AT)
	job = mission.job
	_stand(job.yard.cut_out())
	await _step(0.2)
	(w.task.do as Callable).call()
	await _step(0.3)
	mission.caught("BUSTED")
	await _step(0.2)
	_check(said.has("MISSION FAILED") and mission.state == "job_wait" and mission.job_no == 0, "busted on it: failed, tried again")
	_check(w.held == null and w.task.is_empty(), "and nothing left in your hands")
	print("harbour test: %d failed" % _fails)
	quit(1 if _fails else 0)
