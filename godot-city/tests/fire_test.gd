extends SceneTree
## Molotovs and petrol stations: the city has at least fifteen stations (and no
## charging points among them); one is built with its canopy and pumps; a pump
## shot three times burns, goes up, sets the next one going, and then the tank
## goes, throwing the canopy and leaving a ruin, and you are wanted for it. A
## Molotov thrown breaks where it lands (no fuse) and leaves fire on the
## ground: someone walking into it burns and falls, you standing in it lose
## health, a car in it burns and goes up, a pump in it catches.
##     godot --headless --path godot-city --script tests/fire_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")
const Traffic := preload("res://scripts/traffic.gd")
const Crime := preload("res://scripts/crime.gd")
const Sfx := preload("res://scripts/sfx.gd")
const Juice := preload("res://scripts/juice.gd")
const GunFx := preload("res://scripts/gun_fx.gd")
const Explosions := preload("res://scripts/explosions.gd")
const GasStations := preload("res://scripts/gas_stations.gd")


class OpenStreet:
	signal tile_added(key: String, result: Dictionary)
	signal tile_removed(key: String)
	var tiles := {}
	var index := {"stations": [["Shell Teststraat", 600, -600], ["Tango Proef", 1600, 600]]}
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
var gs


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
	crime.setup(w.streamer, traffic, w, Purse.new())
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


func _run() -> void:
	w.set_physics_process(false); traffic.set_process(false); crime.set_physics_process(false); ex.set_process(false); juice.set_process(false)
	w.global_position = Vector3(0, 0, 200)
	crime.start()
	# 1. The real city's stations.
	var f := FileAccess.open("res://data/index.json", FileAccess.READ)
	var idx: Dictionary = JSON.parse_string(f.get_as_text())
	var real: Array = idx.get("stations", [])
	var charger := RegEx.create_from_string("(?i)charg|laad|allego|pulse|fastned|tesla|ionity|evbox|recharge")
	_check(real.size() >= 15 and not real.any(func(s): return charger.search(String(s[0])) != null),
		"the city has %d petrol stations, none of them a charging point" % real.size())
	_check(gs.stations.size() == 2 and gs.stations[0].pos.is_equal_approx(Vector3(60, 0, 60)), "stations read from the index (decimetres, y north)")
	# 2. One built: canopy, pumps.
	var st: Dictionary = gs.stations[0]
	var wall := StaticBody3D.new(); wall.collision_layer = 1
	var wcs := CollisionShape3D.new(); var wb := BoxShape3D.new(); wb.size = Vector3(12, 10, 0.3)
	wcs.shape = wb; wcs.position = Vector3(60, 5, 60)
	wall.add_child(wcs); root.add_child(wall)
	await physics_frame
	w.streamer.tile_added.emit("t", {"rect": Rect2(0, 0, 200, 200)})
	await physics_frame; await physics_frame
	_check(st.node != null and st.node.get_node_or_null("canopy") != null and st.pumps.size() >= 2,
		"built when its chunk loads: a canopy and %d pumps" % st.pumps.size())
	_check(Vector2(st.at.x - 60, st.at.z - 60).length() > 5.0 and Vector2(st.at.x - 60, st.at.z - 60).length() < 40.0,
		"moved off the wall standing where the map puts it, to open ground %.0f m away" % Vector2(st.at.x - 60, st.at.z - 60).length())
	_check(not is_same(gs.stations[1].node, st.node) and gs.stations[1].node == null, "the one in a chunk not loaded is not built")
	_check(is_same(gs.nearest(Vector3(50, 0, 50)), st), "the nearest one found")
	# 3. Shot until it goes.
	w.global_position = st.at + Vector3(0, 0, 60)
	var pd: Dictionary = st.pumps[0]
	gs.hit_pump(pd); gs.hit_pump(pd)
	_check(not pd.burning, "two bullets: a pump holds")
	gs.hit_pump(pd)
	_check(pd.burning and not pd.gone, "three: it burns...")
	await _step(2.2)
	_check(pd.gone, "...and goes up")
	await _step(5.0)
	var all_gone: bool = st.pumps.all(func(o): return o.gone)
	_check(all_gone, "taking the pumps beside it with it")
	_check(st.ruined and st.has("canopy") and st.canopy is RigidBody3D, "then the tank: the canopy torn off, the place a ruin")
	var lift: float = st.canopy.global_position.y if is_instance_valid(st.canopy) else 0.0
	print("canopy at y %.1f" % lift)
	_check(lift < 30.0, "thrown, not launched into orbit")
	_check(crime.stars >= 2, "and you are wanted for it (%d stars)" % crime.stars)
	_check(not is_same(gs.nearest(st.at), st), "a ruin is not the nearest station any more")
	crime.stars = 0
	w.streamer.tile_removed.emit("t")
	await process_frame
	w.streamer.tile_added.emit("t", {"rect": Rect2(0, 0, 200, 200)})
	await physics_frame; await physics_frame
	_check(st.node != null and st.node.get_node_or_null("canopy") == null and st.pumps.all(func(o): return o.gone and o.node.collision_layer == 0),
		"come back to it: still a ruin")
	await _step(3.0)
	# 4. A Molotov.
	crime.molotovs = 1
	w.global_position = Vector3(-100, 0, -100)
	w.cam.global_position = w.global_position + Vector3(0, 1.8, 3)
	w.cam.look_at(w.global_position + Vector3(0, 1.0, -10))
	crime.throw_molotov()
	_check(crime.molotovs == 0 and crime.bottles.size() == 1, "F: a Molotov thrown")
	var z0: int = ex.zones.size()
	var broke := -1.0
	for i in 60 * 3:
		await _step(1.0 / 60.0)
		if crime.bottles.is_empty():
			broke = i / 60.0; break
	_check(broke > 0.0 and broke < 2.0 and ex.zones.size() == z0 + 1, "it breaks where it lands (%.2f s), no fuse: fire on the ground" % broke)
	var z: Dictionary = ex.zones[-1]
	var at: Vector3 = z.pos
	print("molotov: fire at %s, %.1f m across, for %.0f s" % [at, z.r, z.left])
	_check(Vector2(at.x + 100, at.z + 100).length() > 4.0 and at.y < 0.3 and absf(z.r - Explosions.MOLOTOV_R) < 0.01, "out ahead, on the street, %.0f m across" % Explosions.MOLOTOV_R)
	_check(crime.stars >= 2, "a crime")
	crime.stars = 0
	# Someone walks into it.
	var p := _ped(at + Vector3(1.0, 0, 0))
	await _step(0.5)
	_check(p.get("aflame", false), "someone in it catches fire")
	await _step(Explosions.BURN_FOR + 0.3)
	_check(p.get("dead", false) and p.has("rag"), "and falls, dead")
	# You stand in it.
	w.global_position = at
	var h: float = w.health
	await _step(1.0)
	_check(w.health < h - 10.0 and w.health > h - 30.0, "you, standing in it: %.0f health a second gone" % (h - w.health))
	w.global_position = Vector3(-100, 0, -60)
	w.health = w.MAX_HEALTH
	# A car in it.
	traffic.target.car = 4
	traffic.focus = Vector3(-100, 0, -100)
	for i in 60:
		traffic._process(1.0 / 60.0)
		await process_frame
	traffic.target.car = 0
	var cars: Array = traffic.vehicles.filter(func(v): return v.kind == "car")
	_check(cars.size() >= 1, "a car about")
	var car: Dictionary = cars[0]
	car.pos = Vector2(at.x, at.z) + Vector2(1.0, 0)
	car.parts[0][0].position = Vector3(car.pos.x, 0, car.pos.y)
	ex.zone(at, Explosions.MOLOTOV_R, 15.0, false)            # (fuel enough to see it through)
	await _step(8.5)
	_check(car.get("wrecked", false), "a car in it burns and goes up")
	# A pump in it.
	var st2: Dictionary = gs.stations[1]
	w.streamer.tile_added.emit("t2", {"rect": Rect2(150, -100, 50, 50)})
	await physics_frame; await physics_frame
	_check(st2.node != null, "a second station")
	ex.molotov(st2.pumps[0].node.global_position + Vector3(1.2, 0, 0), true)
	await _step(0.5)
	_check(st2.pumps[0].burning or st2.pumps[0].gone, "a Molotov by a pump: it catches")
	print("fire test: %d failed" % _fails)
	quit(1 if _fails else 0)
