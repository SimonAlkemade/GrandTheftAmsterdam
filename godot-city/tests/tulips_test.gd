extends SceneTree
## Mission 3 on a grid of test streets: the fifth parcel ends the courier job
## and sends you to the flower market; there you get ten bunches of tulips;
## tourists turn up among the people in the street, wait for you when you come
## near, and buy a bunch each (€6-12) when you stand by them; sold out, it is
## back to the market.
##     godot --headless --path godot-city --script tests/tulips_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Mission := preload("res://scripts/mission.gd")


class OpenStreet:                     # open street everywhere, all of it called Teststraat
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"

var _fails := 0
var w
var traffic
var mission
var said := []
var rng := RandomNumberGenerator.new()


func _initialize() -> void:
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
	w.streamer = OpenStreet.new()
	w.traffic = traffic
	var cam := Camera3D.new()
	root.add_child(cam)
	w.cam = cam
	root.add_child(w)
	mission = Mission.new()
	root.add_child(mission)
	mission.setup(w.streamer, traffic, w)
	mission.announce.connect(func(t, s): said.append(t); print("  [%s] %s" % [t, s]))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(n := 1) -> void:
	for i in n:
		w._peds(1.0 / 60.0)
		mission._process(1.0 / 60.0)
		await process_frame


func _stand(at: Vector3) -> void:
	w.global_position = Vector3(at.x, 0, at.z)


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); mission.set_process(false)
	rng.seed = 7
	_stand(Vector3(0, 0, 0))
	mission.start()
	# 1. The fifth parcel delivered ends the courier job.
	mission.delivered = Mission.PARCELS - 1
	mission.state = "deliver"; mission.time_left = 60.0
	mission._arrive()
	_check(said.has("COURIER JOB DONE") and mission.state == "tulips_fetch", "the fifth parcel ends the courier job (%s)" % mission.state)
	# 2. To the flower market (here: by a street corner of the test grid).
	mission.stall_at = Vector2(103, 48)
	await _step(60 * 5)
	_check(mission.target != Vector3.INF and Vector2(mission.target.x, mission.target.z).distance_to(mission.stall_at) < 10.0,
		"the market is marked on the street by it (%s)" % mission.target)
	_check(mission.route.size() > 1, "and the way there is routed")
	_stand(mission.target)
	await _step(2)
	_check(mission.state == "tulips_sell" and mission.tulips == Mission.BUNCHES and w.tulips == Mission.BUNCHES,
		"at the market: %d bunches of tulips in your hands" % mission.tulips)
	# 3. People in the street; tourists among them.
	for k in 24:
		var ang := rng.randf() * TAU
		var at: Vector3 = w.global_position + Vector3(cos(ang), 0, sin(ang)) * rng.randf_range(20.0, 60.0)
		var p := {"h": Human.new(), "pos": at, "heading": rng.randf() * TAU, "speed": 1.2, "turn": 2.0, "stag": 0.0}
		p.h.random_look(rng)
		root.add_child(p.h)
		w.peds.append(p)
	await _step(60 * 6)
	_check(mission.tourists.size() == Mission.TOURISTS, "tourists turn up (%d), a tulip over each head" % mission.tourists.size())
	_check(mission.objective().begins_with("Sell tulips"), "'%s'" % mission.objective())
	# 4. Walk up to them, one after another, and sell.
	var cash: int = mission.money
	var waited := false
	var sales := 0
	for i in 60 * 240:
		if mission.state != "tulips_sell":
			break
		if mission.target != Vector3.INF:
			var to: Vector3 = mission.target - w.global_position; to.y = 0.0
			var near_now := to.length() < 6.0
			# walk at 3 m/s towards the nearest tourist, stopping a metre short
			if to.length() > 1.0:
				_stand(w.global_position + to.normalized() * minf(3.0 / 60.0, to.length() - 1.0))
			if near_now:
				for t in mission.tourists:
					if Vector2(t.pos.x, t.pos.z).distance_to(Vector2(w.global_position.x, w.global_position.z)) < 6.0 and t.get("wait", 0.0) > 0.0:
						waited = true
		var before: int = mission.tulips
		await _step()
		if mission.tulips < before or mission.state == "tulips_fetch": sales += 1
	var earned: int = mission.money - cash
	print("tulips: sold %d bunches for €%d" % [mission.sold, earned])
	_check(waited, "a tourist waits for you when you come near")
	_check(mission.sold == Mission.BUNCHES and mission.tulips == 0, "all %d bunches sold (%d)" % [Mission.BUNCHES, mission.sold])
	_check(earned >= Mission.BUNCHES * Mission.PRICE.x and earned <= Mission.BUNCHES * Mission.PRICE.y, "for €%d (€6-12 a bunch)" % earned)
	_check(mission.state == "tulips_fetch" and said.has("SOLD OUT"), "sold out: back to the market for more")
	_check(w.tulips == 0 and mission.tourists.is_empty(), "the bouquet and the tourists' tulips gone")
	print("tulips test: %d failed" % _fails)
	quit(1 if _fails else 0)
