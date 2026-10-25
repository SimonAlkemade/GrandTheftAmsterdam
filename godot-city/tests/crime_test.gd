extends SceneTree
## Mission 2 end to end, on a grid of test streets: buy a pistol, a shot in
## the air is one star and a pedestrian hit is two (they go down, the people
## round them flee), a police car drives up the streets, its officers get out
## and arrest you (fined, the pistol gone); and having fired again, getting
## well out of their sight loses them.
##     godot --headless --path godot-city --script tests/crime_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")


class OpenStreet:                     # open street everywhere, no names
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"

class Purse:                          # what Crime needs of the courier mission: the cash
	var money := 0

var _fails := 0
var w
var traffic
var crime
var purse
var cam: Camera3D
var said := []


func _initialize() -> void:
	traffic = Traffic.new()
	root.add_child(traffic)
	traffic.set_process(false)
	# A 600 m grid of streets, 100 m apart.
	var lanes := []
	for k in 7:
		var c := -300.0 + k * 100.0
		lanes.append({"kind": "road", "w": 8.0, "p": PackedVector2Array([Vector2(-300, c), Vector2(300, c)])})
		lanes.append({"kind": "road", "w": 8.0, "p": PackedVector2Array([Vector2(c, -300), Vector2(c, 300)])})
	# Cut the lines at every crossing, so the streets meet at junctions.
	var cut := []
	for l in lanes:
		var a: Vector2 = l.p[0]; var b: Vector2 = l.p[1]
		for k in 6:
			cut.append({"kind": "road", "w": 8.0, "p": PackedVector2Array([a.lerp(b, k / 6.0), a.lerp(b, (k + 1) / 6.0)])})
	traffic.add_tile("grid", cut)
	traffic.target = {"car": 0, "bus": 0, "tram": 0, "bike": 0, "canta": 0}
	w = Walker.new()
	w.streamer = OpenStreet.new()
	w.traffic = traffic
	root.add_child(w)
	w.set_physics_process(false)      # we move you by hand
	w.active = true
	cam = Camera3D.new()
	root.add_child(cam)
	w.cam = cam
	purse = Purse.new()
	crime = Crime.new()
	root.add_child(crime)
	crime.set_physics_process(false)
	crime.setup(w.streamer, traffic, w, purse)
	crime.announce.connect(func(t, s): said.append(t); print("  [%s] %s" % [t, s]))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(n := 1) -> void:
	for i in n:
		traffic._process(1.0 / 60.0)
		crime._physics_process(1.0 / 60.0)
		await process_frame


func _stand(at: Vector3) -> void:
	w.global_position = at
	cam.global_position = at + Vector3(0, 1.6, 0)
	cam.look_at(at + Vector3(0, 1.6, -10), Vector3.UP)   # looking north (-Z)
	w.cam_yaw = 0.0


func _ped(at: Vector3) -> Dictionary:
	var p := {"h": Human.new(), "pos": at, "heading": 0.0, "speed": 1.2, "turn": 1e9, "stag": 0.0}
	var rng := RandomNumberGenerator.new()
	p.h.random_look(rng)
	root.add_child(p.h)
	w.peds.append(p)
	return p


func _shoot() -> void:
	crime.fire()
	await _step(20)                   # past the gap between shots


func _run() -> void:
	# (Godot turns processing on when the tree becomes ready, after _initialize.)
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false)
	_stand(Vector3(0, 0, 0))
	crime.start()
	_check(purse.money == Crime.START_CASH and crime.shop != Vector3.INF, "Mission 2 starts with €%d and a gun shop %.0f m away" % [purse.money, crime._dist(crime.shop)])
	# 1. Buy the pistol.
	_stand(crime.shop)
	await _step(2)
	_check(crime.armed and crime.mag == Crime.MAG, "walking into the shop buys a pistol (%d rounds in it)" % crime.mag)
	_check(purse.money == Crime.START_CASH - Crime.PISTOL, "for €%d (€%d left)" % [Crime.PISTOL, purse.money])
	# 2. A shot in the air: one star. A pedestrian hit: two, down, the others flee.
	_stand(Vector3(0, 0, 0))
	await _shoot()
	_check(crime.stars == 1, "a shot is a crime: one star (%d)" % crime.stars)
	var victim := _ped(Vector3(0, 0, -12))
	var bystander := _ped(Vector3(6, 0, -14))
	await _shoot()
	_check(victim.get("dead", false), "a pedestrian in your sights goes down")
	_check(crime.stars == 2, "two stars for that (%d)" % crime.stars)
	_check(bystander.get("flee", 0.0) > 0.0, "and the people round them run")
	_check(crime.mag == Crime.MAG - 2, "each shot uses a round (%d left)" % crime.mag)
	# 3. The police come up the streets, get out and arrest you.
	var t_car := -1.0
	var t_cops := -1.0
	var t_busted := -1.0
	for i in 60 * 120:
		await _step()
		if t_car < 0.0 and crime.cars.size() > 0: t_car = i / 60.0
		if t_cops < 0.0 and crime.cops.size() > 0: t_cops = i / 60.0
		if said.has("BUSTED"):
			t_busted = i / 60.0
			break
	print("police: a car dispatched after %.1f s, officers on foot after %.1f s, busted after %.1f s" % [t_car, t_cops, t_busted])
	_check(t_car >= 0.0, "a police car is sent")
	_check(t_cops >= 0.0, "it drives up the streets and its officers get out")
	_check(t_busted >= 0.0, "and they arrest you: BUSTED")
	_check(not crime.armed and crime.stars == 0, "the pistol is gone and the stars cleared")
	_check(purse.money == 0, "and the fine took the rest of your cash (€%d)" % purse.money)
	# 4. Buy again, fire, and get well away: they lose you.
	purse.money = 60
	said.clear()
	_stand(crime.shop)
	await _step(2)
	_stand(Vector3(0, 0, 0))
	await _shoot()
	_stand(Vector3(0, 0, 600))       # far off, out of sight
	var t_lost := -1.0
	for i in 60 * 60:
		await _step()
		if said.has("Lost them"):
			t_lost = i / 60.0
			break
	print("lost them after %.1f s" % t_lost)
	_check(t_lost > 5.0 and crime.stars == 0, "out of their sight long enough, the stars clear (%.1f s)" % t_lost)
	print("crime test: %d failed" % _fails)
	quit(1 if _fails else 0)
