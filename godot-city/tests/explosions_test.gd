extends SceneTree
## Explosions (docs/juicy-gunfights.md §9): the size slider gives the spec's
## masses and scales; counts, radii, the sound's delay and the camera's shake
## follow its formulas; each kind brings its own layers (a shock ring for HE,
## a burning pool for gasoline, a jet for gas); a blast kills those close in,
## knocks down those further off and leaves the rest alone, hurts you by
## distance and stays within the juice budget; a car shot six times smokes,
## burns and goes up, setting the car beside it off too, and makes you wanted;
## a grenade thrown bounces and goes off three seconds later; a gas canister
## shot hisses and goes.
##     godot --headless --path godot-city --script tests/explosions_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")
const Sfx := preload("res://scripts/sfx.gd")
const Juice := preload("res://scripts/juice.gd")
const GunFx := preload("res://scripts/gun_fx.gd")
const Explosions := preload("res://scripts/explosions.gd")


class OpenStreet:
	var tiles := {}
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

class Purse:
	var money := 100

var _fails := 0
var w
var traffic
var crime
var ex
var juice
var said := []


func _initialize() -> void:
	var floor := StaticBody3D.new()                 # the street: what grenades bounce on
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
	w.setup(OpenStreet.new(), cam)
	root.add_child(w)
	w.active = true
	var sfx = Sfx.new(); root.add_child(sfx)
	juice = Juice.new(); root.add_child(juice)
	var gfx = GunFx.new(); root.add_child(gfx)
	gfx.setup(w, w.streamer, sfx, juice)
	crime = Crime.new()
	root.add_child(crime)
	crime.setup(w.streamer, traffic, w, Purse.new())
	crime.announce.connect(func(t, s): said.append(t))
	ex = Explosions.new()
	root.add_child(ex)
	ex.setup(w, traffic, crime, sfx, juice, gfx, w.streamer)
	crime.explosions = ex; crime.sfx = sfx; crime.gun_fx = gfx
	w.juice = juice
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _step(secs: float) -> void:
	for i in int(secs * 60.0):
		ex.step(1.0 / 60.0)
		juice.step(1.0 / 60.0)
		crime._physics_process(1.0 / 60.0)
		await physics_frame


func _ped(at: Vector3) -> Dictionary:
	var p := {"h": Human.new(), "pos": at, "heading": 0.0, "speed": 0.0, "turn": 1e9, "stag": 0.0}
	p.h.random_look(RandomNumberGenerator.new())
	root.add_child(p.h)
	p.h.position = at
	w.peds.append(p)
	return p


func _rings() -> int:
	var n := 0
	for c in ex.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh is TorusMesh: n += 1
	return n


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false); ex.set_process(false); juice.set_process(false)
	w.global_position = Vector3(0, 0, 200)
	crime.start()
	# 1. The slider (§9.2): M and S as the spec's table.
	var want_m := [0.2, 1.12, 6.32, 35.6, 200.0]
	var want_s := [0.585, 1.04, 1.85, 3.29, 5.85]
	var ok := true
	for i in 5:
		var f := i * 0.25
		if absf(Explosions.mass(f) - want_m[i]) > want_m[i] * 0.01 or absf(Explosions.scale_of(f) - want_s[i]) > 0.01: ok = false
	_check(ok, "the slider: 0.2 / 1.12 / 6.3 / 35.6 / 200 kg, S 0.58 / 1.04 / 1.85 / 3.29 / 5.85")
	_check(Explosions.tier(0.1) == "small" and Explosions.tier(0.4) == "medium" and Explosions.tier(0.8) == "large", "tiers: small, medium, large")
	var a := Explosions.derive("he", 0.0)
	var b := Explosions.derive("he", 1.0)
	_check(is_equal_approx(b.fireball / a.fireball, b.S / a.S) and Explosions.count(30.0, b.S, 90) == 90 and Explosions.count(30.0, a.S, 90) == 10,
		"radii grow with S, counts with S² up to their caps (%d .. %d)" % [Explosions.count(30.0, a.S, 90), Explosions.count(30.0, b.S, 90)])
	_check(absf(Explosions.sound_delay(200.0) - 0.583) < 0.01 and Explosions.sound_delay(20.0) == 0.0, "the sound arrives 0.58 s after a blast 200 m off, at once close by")
	_check(Explosions.trauma_at("he", 0.5, 2.0) > Explosions.trauma_at("he", 0.5, 30.0) and Explosions.trauma_at("he", 0.5, 30.0) > Explosions.trauma_at("he", 0.5, 300.0),
		"the shake falls off with distance")
	# 2. Each kind's own layers.
	var fires: int = ex.fires.size()
	var rings0 := _rings()
	ex.explode("he", Vector3(-150, 0.4, -150), 0.5)
	await _step(0.05)
	_check(_rings() > rings0 and ex.fires.size() == fires, "HE: a shock ring, and no fire left burning")
	ex.explode("gasoline", Vector3(150, 0.4, -150), 0.5)
	await _step(0.3)
	_check(ex.fires.size() == fires + 1, "gasoline: a burning pool")
	ex.explode("gas", Vector3(150, 0.4, 150), 0.6)
	await _step(0.3)
	_check(ex.fires.size() == fires + 2, "gas (big: the air rushes in first): a burning jet")
	_check(juice.trauma <= Juice.MAX_TRAUMA and absf(juice.fov) <= Juice.MAX_FOV, "three blasts in a row stay in the budget")
	await _step(3.0)
	# 3. Who it hurts.
	var x := Explosions.derive("he", 0.3)
	var at := Vector3(0, 0.3, 0)
	var close := _ped(at + Vector3(x.lethal * 0.5, -0.3, 0))
	var mid := _ped(at + Vector3(0, -0.3, (x.lethal + x.hurt) * 0.5))
	var far := _ped(at + Vector3(-x.hurt * 1.5, -0.3, 0))
	w.global_position = at + Vector3(0, -0.3, -x.lethal * 1.5)
	var health: float = w.health
	ex.explode("he", at, 0.3, true)
	await _step(0.1)
	print("blast: lethal %.1f m, hurt %.1f m; you lost %.0f health" % [x.lethal, x.hurt, health - w.health])
	_check(close.get("dead", false) and close.has("rag"), "close in: dead, thrown")
	_check(not mid.get("dead", false) and mid.has("rag"), "further off: knocked down, alive")
	_check(not far.has("rag") and not far.get("dead", false), "beyond: untouched")
	_check(w.health < health and w.stun > 0.0, "you: hurt and knocked over")
	_check(crime.stars >= 2, "you set it off: wanted (%d stars)" % crime.stars)
	w.get_up(); w.health = w.MAX_HEALTH
	crime.stars = 0
	await _step(2.0)
	# 4. A car shot until it goes, and the one next to it.
	traffic.target.car = 6
	traffic.focus = Vector3(0, 0, 0)
	for i in 60:
		traffic._process(1.0 / 60.0)
		await process_frame
	traffic.target.car = 0
	var cars: Array = traffic.vehicles.filter(func(v): return v.kind == "car")
	_check(cars.size() >= 2, "cars on the streets (%d)" % cars.size())
	var c1: Dictionary = cars[0]
	var c2: Dictionary = cars[1]
	c2.pos = c1.pos + Vector2(2.5, 0)                 # (parked right beside it)
	c2.parts[0][0].global_position = c1.parts[0][0].global_position + Vector3(2.5, 0, 0)
	for i in 4: ex.damage(c1, 1, true)
	_check(c1.has("smoke") and not c1.get("burning", false), "four hits: it smokes")
	ex.damage(c1, 1, true); ex.damage(c1, 1, true)
	_check(c1.get("burning", false), "six: it catches fire")
	await _step(Explosions.FUSE + 0.2)
	_check(c1.get("wrecked", false), "and goes up after %.1f s, a wreck" % Explosions.FUSE)
	await _step(1.5)
	_check(c2.get("wrecked", false), "taking the car beside it with it")
	var flung: float = c1.parts[0][0].global_position.y
	_check(flung < 25.0, "the wreck thrown up, not into orbit (%.1f m up)" % flung)
	_check(crime.stars >= 2, "and you are wanted for it")
	crime.stars = 0
	# 5. A grenade.
	crime.grenades = 1
	w.global_position = Vector3(40, 0, 40)
	w.cam.global_position = w.global_position + Vector3(0, 1.8, 3)
	w.cam.look_at(w.global_position + Vector3(0, 1.0, -10))
	var rings1 := _rings()
	crime.throw_grenade()
	_check(crime.grenades == 0 and crime.thrown.size() == 1, "G: a grenade thrown")
	var g: RigidBody3D = crime.thrown[0].body
	var gone := -1.0
	var last := Vector3.ZERO
	var rang := false
	for i in 60 * 4:
		await _step(1.0 / 60.0)
		if is_instance_valid(g): last = g.global_position
		if gone < 0.0 and crime.thrown.is_empty():
			gone = i / 60.0
			rang = _rings() > rings1
	print("grenade: went off after %.1f s, %.1f m out, at y %.2f" % [gone, Vector2(last.x - 40, last.z - 40).length(), last.y])
	_check(absf(gone - Crime.GRENADE_FUSE) < 0.1 and last.y < 0.5 and Vector2(last.x - 40, last.z - 40).length() > 5.0,
		"it lands on the street, out ahead, and goes off after %.0f s" % Crime.GRENADE_FUSE)
	_check(rang, "with a bang (a shock ring)")
	# 6. A gas canister.
	ex.place_canisters = false
	for cn in ex.canisters: cn.node.queue_free()
	ex.canisters.clear()
	ex._place_canister(w.global_position)
	_check(ex.canisters.size() == 1, "a gas canister stands about")
	var fires2: int = ex.fires.size()
	ex.hit_canister(ex.canisters[0])
	await _step(Explosions.LEAK * 0.5)
	_check(ex.canisters.size() == 1, "shot, it hisses a moment...")
	await _step(Explosions.LEAK)
	_check(ex.canisters.is_empty() and ex.fires.size() > fires2, "...and goes: a gas blast, a burning jet")
	print("explosions test: %d failed" % _fails)
	quit(1 if _fails else 0)
