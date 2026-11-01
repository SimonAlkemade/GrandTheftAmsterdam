extends SceneTree
## The jobs (Mission 4 on, scripts/jobs/) on a grid of test streets: each
## starts with its target and objective, is passed or failed (busted or wasted
## on the job is a failure, tried again), pays, and leads on to the next.
##     godot --headless --path godot-city --script tests/jobs_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")
const Sfx := preload("res://scripts/sfx.gd")
const Juice := preload("res://scripts/juice.gd")
const GunFx := preload("res://scripts/gun_fx.gd")
const Explosions := preload("res://scripts/explosions.gd")
const GasStations := preload("res://scripts/gas_stations.gd")
const Mission := preload("res://scripts/mission.gd")


class OpenStreet:
	signal tile_added(key: String, result: Dictionary)
	signal tile_removed(key: String)
	var tiles := {}
	var index := {"stations": [["Shell Teststraat", 600, -600], ["Tango Proef", 1600, 600]]}
	var wet := Rect2()                                  # (a canal, for the boat jobs)
	func water_at(p: Vector3) -> int: return 1 if wet.has_point(Vector2(p.x, p.z)) else 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

class Purse:
	var money := 100

var _fails := 0
var said := []
var w
var traffic
var crime
var ex
var juice
var gs
var mission


func _initialize() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = 2
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
	var sfx = Sfx.new(); root.add_child(sfx)
	juice = Juice.new(); root.add_child(juice)
	var gfx = GunFx.new(); root.add_child(gfx)
	gfx.setup(w, w.streamer, sfx, juice)
	crime = Crime.new()
	root.add_child(crime)
	mission = Mission.new()
	root.add_child(mission)
	mission.setup(street, traffic, w)
	crime.setup(w.streamer, traffic, w, mission)
	ex = Explosions.new()
	root.add_child(ex)
	ex.setup(w, traffic, crime, sfx, juice, gfx, w.streamer)
	ex.place_canisters = false
	gs = GasStations.new()
	root.add_child(gs)
	gs.setup(street, w, traffic, ex)
	ex.stations = gs
	crime.explosions = ex; crime.sfx = sfx; crime.gun_fx = gfx; crime.stations = gs
	w.juice = juice
	mission.crime = crime; mission.explosions = ex; mission.stations = gs
	crime.caught.connect(mission.caught)
	mission.announce.connect(func(t, s): said.append(t))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(secs: float) -> void:
	for i in int(secs * 60.0):
		ex.step(1.0 / 60.0)
		juice.step(1.0 / 60.0)
		crime._physics_process(1.0 / 60.0)
		mission._process(1.0 / 60.0)
		await physics_frame


func _ped(at: Vector3) -> Dictionary:
	var p := {"h": Human.new(), "pos": at, "heading": 0.0, "speed": 0.0, "turn": 1e9, "stag": 0.0}
	p.h.random_look(RandomNumberGenerator.new())
	root.add_child(p.h)
	p.h.position = at
	w.peds.append(p)
	return p


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false); ex.set_process(false); juice.set_process(false)
	mission.set_process(false)
	w.global_position = Vector3(-150, 0, -150)
	crime.start()
	w.streamer.tile_added.emit("t", {"rect": Rect2(-300, -300, 600, 600)})
	await physics_frame; await physics_frame
	# Mission 4, Burn it down.
	mission.start_job(4)
	var job = mission.job
	_check(mission.state == "job" and job != null and said.has(job.title), "--mission=4: %s" % (job.title if job else "none"))
	_check(crime.molotovs >= 2, "two Molotovs come with the job")
	var st: Dictionary = job.station
	_check(not st.is_empty() and mission.target != Vector3.INF and mission.route.size() > 1,
		"the target: the %s, a route there (%.0f m)" % [st.get("name", "?"), mission.route_len])
	_check(mission.objective().begins_with("Get to the"), "objective: '%s'" % mission.objective())
	w.global_position = st.at + Vector3(0, 0, 30)
	await _step(0.2)
	_check(job.phase == "burn" and mission.objective().begins_with("Blow up"), "close by: '%s'" % mission.objective())
	for pd in st.pumps:
		for k in 3: gs.hit_pump(pd)
	await _step(6.0)
	_check(st.ruined and job.phase == "lose" and crime.stars >= 2, "blown up: lose the police (%d stars)" % crime.stars)
	var money: int = mission.money
	var reward: int = job.reward
	crime.stars = 0
	await _step(0.2)
	_check(said.has("MISSION PASSED") and mission.money == money + reward, "stars gone: mission passed, +€%d" % reward)
	_check(mission.state == "job_wait" and mission.job_no == 5, "and on to the next job")
	# A failure: busted on the job, it is tried again.
	said.clear()
	mission.start_job(4)
	var job2 = mission.job
	_check(job2 != null and not is_same(job2.station, st), "again: a station still standing this time (%s)" % job2.station.get("name", "?"))
	crime._busted()
	await _step(0.1)
	_check(said.has("MISSION FAILED") and mission.state == "job_wait" and mission.job_no == 4, "busted on the job: failed, tried again")
	await _step(5.5)
	_check(mission.state == "job" and mission.job != null and mission.job_no == 4, "five seconds later, Mission 4 again")
	# Mission 5, Getaway.
	said.clear()
	crime.stars = 0
	w.global_position = Vector3(-50, 0, -50)
	traffic.target.car = 8
	traffic.focus = w.global_position
	for i in 90:
		traffic._process(1.0 / 60.0)
		await process_frame
	traffic.target.car = 0
	var parked: Array = traffic.vehicles.filter(func(v): return v.kind == "car" and not v.get("police", false))
	_check(parked.size() >= 1, "cars about (%d)" % parked.size())
	if parked.is_empty():
		quit(1); return
	var pc: Dictionary = parked[0]                      # (one 60 m off, so there is one to mark)
	pc.pos = Vector2(w.global_position.x + 60.0, w.global_position.z)
	pc.parts[0][0].position = Vector3(pc.pos.x, 0, pc.pos.y)
	mission.start_job(5)
	var g = mission.job
	_check(said.has(g.title) and g.objective() == "Find a car to steal", "Mission 5: %s" % g.title)
	await _step(1.2)
	_check(g.phase == "steal" and g.car.get("parked", false) and mission.target != Vector3.INF, "a car marked to steal: '%s'" % g.objective())
	if g.phase != "steal":
		print("jobs test: %d failed" % (_fails + 1)); quit(1); return
	var c: Dictionary = g.car
	w.global_position = Vector3(c.pos.x + 1.5, 0, c.pos.y)
	w._get_in()
	_check(is_same(w.vehicle, c), "E: in the marked car")
	await _step(0.2)
	_check(g.phase == "bank" and g.objective().begins_with("Drive to the bank"), "'%s'" % g.objective())
	w.global_position = mission.target
	await _step(0.2)
	_check(g.phase == "escape" and crime.stars >= 3 and g.clock() > 0.0, "the crew in, the alarm: %d stars, %.0f s on the clock" % [crime.stars, g.clock()])
	money = mission.money
	w.global_position = mission.target
	await _step(0.2)
	_check(said.has("MISSION PASSED") and crime.stars == 0 and mission.money == money + 600, "at the garage: passed, the stars gone, +€600")
	# ...and failed by leaving the car.
	said.clear()
	w._get_out()
	pc = c                                              # (the car to mark: 60 m off again)
	pc.pos = Vector2(w.global_position.x + 60.0, w.global_position.z)
	pc.parts[0][0].global_position = Vector3(pc.pos.x, 0, pc.pos.y)
	mission.start_job(5)
	var g2 = mission.job
	await _step(1.2)
	if g2.phase == "steal":
		var c2: Dictionary = g2.car
		w.global_position = Vector3(c2.pos.x + 1.5, 0, c2.pos.y)
		w._get_in()
		await _step(0.2)
		w._get_out()
		await _step(g2.LEAVE_GRACE + 0.5)
	_check(said.has("MISSION FAILED"), "out of the car too long: failed")
	# Mission 6, Taxi.
	said.clear()
	crime.stars = 0
	if w.vehicle != null: w._get_out()
	mission.start_job(6)
	var tx = mission.job
	_check(said.has(tx.title) and tx.phase == "car", "Mission 6: %s, '%s'" % [tx.title, tx.objective()])
	var cab: Dictionary = {}
	for v in traffic.vehicles:
		if v.kind == "car" and not v.get("wrecked", false) and not v.get("police", false):
			cab = v; break
	w.global_position = Vector3(cab.pos.x + 1.5, 0, cab.pos.y)
	w._get_in()
	await _step(0.1)
	_check(tx.phase == "hail", "in a car: '%s'" % tx.objective())
	money = mission.money
	var rides := 0
	var fares: int = tx.FARES
	var bonus: int = tx.reward
	for k in fares:
		var p := _ped(w.global_position + Vector3(0, 0, 50))
		var waited := 0
		while tx.fare.is_empty() and waited < 300:
			await _step(1.0 / 60.0); waited += 1
		if tx.fare.is_empty(): break
		w.global_position = tx.fare.pos + Vector3(2.0, 0, 0)
		await _step(0.1)
		if tx.phase != "ride": break
		if k == 0:
			_check(not tx.fare.h.visible and tx.clock() > 0.0 and mission.target != Vector3.INF,
				"a fare hails, gets in: '%s', %.0f s" % [tx.objective(), tx.clock()])
		w.global_position = mission.target
		await _step(0.1)
		rides += 1
	_check(rides == fares and said.has("MISSION PASSED") and mission.money > money + bonus,
		"%d fares driven: passed, €%d earned" % [rides, mission.money - money])
	# Mission 7, Canal run.
	said.clear()
	crime.stars = 0
	if w.vehicle != null: w._get_out()
	w.streamer.wet = Rect2(-600, 380, 1200, 40)          # a long canal along z = 400
	w.global_position = Vector3(0, 0, 400)
	mission.start_job(7)
	var cr = mission.job
	_check(said.has(cr.title) and cr.phase == "boat" and cr.clock() < 0.0, "Mission 7: %s, '%s'" % [cr.title, cr.objective()])
	w.vehicle = {"kind": "boat"}                        # (in a boat)
	await _step(0.1)
	_check(cr.phase == "crates" and cr.crates.size() == 3 and cr.crates.all(func(c): return w.streamer.water_at(c.pos) == 1),
		"in a boat: three crates out on the water, %.0f s on the clock" % cr.clock())
	_check(mission.route.is_empty() and mission.target != Vector3.INF, "the nearest crate is the target, no street route")
	for k in 3:
		w.global_position = mission.target
		await _step(0.1)
	_check(cr.phase == "deliver" and crime.stars >= 1 and w.streamer.water_at(cr.dock) == 1, "all three fished out (%d stars): to the dock" % crime.stars)
	money = mission.money
	w.global_position = cr.dock
	await _step(0.1)
	_check(said.has("MISSION PASSED") and mission.money == money + 700, "at the dock: passed, +€700")
	# ...and out of time.
	said.clear()
	mission.start_job(7)
	var cr2 = mission.job
	await _step(0.1)
	cr2._left = 0.05
	await _step(0.2)
	_check(said.has("MISSION FAILED"), "the clock run out: failed")
	w.vehicle = null
	w.streamer.wet = Rect2()
	# Mission 8, Bike race.
	said.clear()
	crime.stars = 0
	w.global_position = Vector3(-150, 0, -150)
	mission.start_job(8)
	var rc = mission.job
	_check(said.has(rc.title) and rc.phase == "bike", "Mission 8: %s, '%s'" % [rc.title, rc.objective()])
	w.vehicle = {"kind": "bike"}                        # (on a bike)
	await _step(1.5)
	_check(rc.phase == "ready" and said.has("3") and said.has("2"), "on a bike: the countdown")
	await _step(2.0)
	_check(rc.phase == "race" and said.has("GO!") and mission.target != Vector3.INF and rc.clock() > 0.0,
		"GO: the first checkpoint %.0f m off, %.0f s" % [mission.route_len, rc.clock()])
	money = mission.money
	for k in rc.CHECKPOINTS:
		var before: float = rc.clock() if is_instance_valid(rc) and not rc.over else 0.0
		w.global_position = mission.target
		await _step(0.1)
		if k == 0:
			_check(rc.passed == 1 and rc.clock() > before + 10.0, "a checkpoint: time back on the clock (%.0f s)" % rc.clock())
	_check(said.has("MISSION PASSED") and mission.money == money + 350, "all six: passed, +€350")
	said.clear()
	mission.start_job(8)
	var rc2 = mission.job
	await _step(3.5)
	rc2._left = 0.05
	await _step(0.2)
	_check(said.has("MISSION FAILED"), "out of time: failed")
	w.vehicle = null
	# Mission 9, The hit.
	said.clear()
	crime.stars = 0
	w.health = w.MAX_HEALTH
	w.global_position = Vector3(-150, 0, -150)
	mission.start_job(9)
	var ht = mission.job
	await _step(1.2)
	var tg: Dictionary = ht.target
	_check(ht.phase == "hit" and not tg.is_empty() and ht.guards.size() == 2 and w.peds.has(tg) and tg.get("scripted", false),
		"Mission 9: the man in white and two guards, %.0f m off" % Vector2(tg.pos.x + 150, tg.pos.z + 150).length())
	_check(mission.target.distance_to(tg.pos) < 0.5, "he is the target on the minimap")
	var gd: Dictionary = ht.guards[0]
	w.global_position = tg.pos + Vector3(10, 0, 0)
	var d0: float = Vector2(gd.pos.x - w.global_position.x, gd.pos.z - w.global_position.z).length()
	await _step(1.0)
	var d1: float = Vector2(gd.pos.x - w.global_position.x, gd.pos.z - w.global_position.z).length()
	_check(ht.hostile and said.has("BODYGUARDS!") and d1 < d0 - 2.0, "close in: the guards come for you (%.1f m -> %.1f m)" % [d0, d1])
	var hp: float = w.health
	await _step(3.0)
	_check(w.health < hp, "and their fists hurt (%.0f health gone)" % (hp - w.health))
	crime.stars = 2                                     # (a shot in the street)
	crime._down_ped(tg)
	await _step(0.1)
	_check(ht.phase == "lose", "he is down: lose the police")
	money = mission.money
	crime.stars = 0
	await _step(0.1)
	_check(said.has("MISSION PASSED") and mission.money == money + 800 and not tg.has("scripted"), "passed, +€800; they are passers-by again")
	w.health = w.MAX_HEALTH
	# Mission 10, Pizza run.
	said.clear()
	crime.stars = 0
	w.global_position = Vector3(-150, 0, -150)
	mission.start_job(10)
	var pz = mission.job
	_check(said.has(pz.title) and pz.phase == "ride", "Mission 10: %s, '%s'" % [pz.title, pz.objective()])
	w.vehicle = {"kind": "canta", "driver": true}          # (on the Canta)
	await _step(1.1)
	_check(pz.phase == "fetch" and mission.target != Vector3.INF, "'%s'" % pz.objective())
	w.global_position = mission.target
	await _step(0.1)
	_check(pz.phase == "deliver" and pz.left == 3 and pz.clock() > 90.0, "three hot pizzas: '%s'" % pz.objective())
	money = mission.money
	w.global_position = mission.target
	await _step(0.1)
	_check(said.has("DELIVERED") and mission.money > money + 12, "the first, hot: paid with a tip (€%d)" % (mission.money - money))
	pz.heat = 0.1
	var m2: int = mission.money
	w.global_position = mission.target
	await _step(0.1)
	_check(said.has("COLD!") and mission.money == m2, "a cold one: sent back, no pay")
	w.global_position = mission.target
	await _step(0.1)
	_check(said.has("MISSION PASSED"), "the third: passed")
	w.vehicle = null
	# Mission 11, Demolition derby.
	said.clear()
	crime.stars = 0
	w.global_position = Vector3(-50, 0, -50)
	traffic.target.car = 14
	traffic.focus = w.global_position
	for i in 120:
		traffic._process(1.0 / 60.0)
		await process_frame
	traffic.target.car = 0
	var placed := 0
	for v in traffic.vehicles:                          # (eight within reach, held still, 10 m apart)
		if v.kind == "car" and not v.get("wrecked", false) and not v.get("police", false) and placed < 8 and not is_same(v, w.vehicle):
			v.parked = true
			v.pos = Vector2(w.global_position.x + 40.0 + placed * 10.0, w.global_position.z + 30.0)
			v.parts[0][0].global_position = Vector3(v.pos.x, 0, v.pos.y)
			placed += 1
	print("derby: %d cars placed" % placed)
	mission.start_job(11)
	var db = mission.job
	await _step(3.0)
	_check(said.has(db.title) and db.marked.size() >= 3 and db.clock() > 200.0, "Mission 11: %d cars marked, %.0f s" % [db.marked.size(), db.clock()])
	_check(mission.target != Vector3.INF and mission.route.is_empty(), "the nearest is the blip")
	money = mission.money
	var booms := 0
	while is_instance_valid(db) and not db.over and booms < 12:
		if db.marked.is_empty():
			await _step(0.6); booms += 1; continue
		var mk: Dictionary = db.marked[0]
		ex._car_boom(mk.v)
		await _step(0.1)
		booms += 1
	_check(said.has("MISSION PASSED") and mission.money == money + 500, "five wrecked: passed, +€500")
	said.clear()
	mission.start_job(11)
	var db2 = mission.job
	await _step(0.2)
	db2._left = 0.05
	await _step(0.2)
	_check(said.has("MISSION FAILED"), "out of time: failed")
	# Past the last job: free roam.
	mission.start_job(mission.FIRST_JOB + mission.JOBS.size())
	_check(mission.state == "free" and said.has("ALL JOBS DONE"), "after the last job: free roam")
	print("jobs test: %d failed" % _fails)
	quit(1 if _fails else 0)
