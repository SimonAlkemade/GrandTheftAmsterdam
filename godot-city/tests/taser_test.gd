extends SceneTree
## Pistols in the street, health and the taser, on a grid of test streets:
## pistols lie about; walking over one arms you with ten rounds, gone once
## fired; an officer who sees you close by fires a taser, which takes health
## and puts you down, and then cuffs you; with your health gone you are
## wasted and back at the start; and a car running you over hurts and knocks
## you down too.
##     godot --headless --path godot-city --script tests/taser_test.gd

const Walker := preload("res://scripts/walker.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")


class OpenStreet:
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}

class Purse:
	var money := 0

var _fails := 0
var w
var traffic
var crime
var purse
var said := []


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
	w.traffic = traffic
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(OpenStreet.new(), cam)            # (your body, to go down with)
	root.add_child(w)
	w.active = true
	purse = Purse.new()
	crime = Crime.new()
	root.add_child(crime)
	crime.setup(w.streamer, traffic, w, purse)
	crime.announce.connect(func(t, s): said.append(t); print("  [%s] %s" % [t, s]))
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(n := 1) -> void:
	for i in n:
		crime._physics_process(1.0 / 60.0)
		await process_frame


func _stand(at: Vector3) -> void:
	w.global_position = Vector3(at.x, 0, at.z)
	w.cam.global_position = w.global_position + Vector3(0, 1.6, 0)
	w.cam.look_at(w.global_position + Vector3(0, 1.6, -10), Vector3.UP)
	w.cam_yaw = 0.0


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false)
	_stand(Vector3.ZERO)
	crime.start()
	# 1. Pistols lie about; walk over one.
	await _step(60 * 3)
	_check(crime.pickups.size() == Crime.PICKUPS, "pistols lie in the street (%d)" % crime.pickups.size())
	var near: bool = crime.pickups.all(func(p): return crime._dist(p.pos) > Crime.PICKUP_FROM.x - 1.0 and crime._dist(p.pos) < Crime.PICKUP_FROM.y + 1.0)
	_check(near, "%.0f-%.0f m from you" % [Crime.PICKUP_FROM.x, Crime.PICKUP_FROM.y])
	_stand(crime.pickups[0].pos)
	await _step(2)
	_check(crime.armed and crime.mag == Crime.PICKUP_ROUNDS and crime.rounds == 0, "walking over one: a pistol, %d rounds in it" % crime.mag)
	# 2. Ten shots and it is spent.
	_stand(Vector3.ZERO)
	var shots := 0
	while crime.armed and shots < 20:
		crime.fire(); shots += 1
		await _step(20)
	_check(shots == Crime.PICKUP_ROUNDS and not crime.armed and said.has("OUT OF BULLETS"), "fired %d times, then out of bullets" % shots)
	_check(crime.stars >= 1, "and the shots made you wanted (%d stars)" % crime.stars)
	# 3. An officer 6 m off, who sees you: the taser.
	var car := Node3D.new(); root.add_child(car)
	car.position = Vector3(6, 0, 0)
	crime._arrive({"parts": [[car, 0.0, 4.2]], "speed": 0.0})
	for c in crime.cops: c.pos = Vector3(6, 0, 2.0 * crime.cops.find(c))
	var hit := -1.0
	for i in 60 * 20:
		await _step()
		if w.stun > 0.0:
			hit = i / 60.0
			break
	print("taser: you went down after %.1f s, health %.0f" % [hit, w.health])
	_check(hit >= 0.0 and said.has("TASERED"), "an officer who sees you close by tasers you")
	_check(w.health == w.MAX_HEALTH - Crime.TASER_HURT, "the darts take %.0f health (%.0f left)" % [Crime.TASER_HURT, w.health])
	_check(w._rag != null, "and you go down, limp")
	var cuffed := -1.0
	for i in 60 * 15:
		w.stun -= 1.0 / 60.0                              # (the walker's own clock, held still here)
		await _step()
		if said.has("BUSTED"):
			cuffed = i / 60.0
			break
	print("taser: cuffed %.1f s later" % cuffed)
	_check(cuffed >= 0.0 and cuffed < Crime.TASER_DOWN, "and they cuff you before you are up: BUSTED (%.1f s)" % cuffed)
	_check(w._rag == null and w.stun <= 0.0, "back on your feet after")
	# 4. Health gone: wasted.
	purse.money = 300
	w.hurt(500.0)
	_check(w.health == 0.0, "health never goes below 0")
	await _step(2)
	_check(said.has("WASTED") and w.health == w.MAX_HEALTH, "at 0: WASTED, and well again")
	_check(purse.money == 300 - Crime.HOSPITAL, "the hospital bill: €%d" % Crime.HOSPITAL)
	_check(w.global_position.distance_to(Vector3(5, 0, 5)) < 0.01, "back at the start")
	# 5. Run over: a car at 40 km/h into you.
	w.get_up()
	w.health = w.MAX_HEALTH
	_stand(Vector3(40, 0, 40))
	var n := Node3D.new(); root.add_child(n)
	n.position = Vector3(40.0 - 2.4, 0, 40.0); n.rotation.y = -PI / 2.0      # its nose at your feet, heading +x
	traffic.vehicles.append({"kind": "car", "parts": [[n, 0.0, 4.2]], "speed": 11.0, "pos": Vector2(40.0 - 0.3, 40.0)})
	w._peds(1.0 / 60.0)
	print("run over: health %.0f, down %.1f s" % [w.health, w.stun])
	_check(w.health < w.MAX_HEALTH - 20.0 and w.stun > 0.0 and w._rag != null, "a car at 40 km/h knocks you down and hurts (%.0f left)" % w.health)
	print("taser test: %d failed" % _fails)
	quit(1 if _fails else 0)
