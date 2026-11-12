extends "res://scripts/jobs/job.gd"
## Mission 7, Canal run: take a boat, fish CRATES crates of contraband out of
## the canals (bobbing under orange beacons) and bring them to the dock before
## the clock runs out. The police on the quays see you at it: a star a crate.
## The targets lie on the water, so no route is drawn along the streets.

const CRATES := 3
const TIME := 300.0
const GRAB := 5.0               # metres from the boat

var phase := "boat"             # boat, crates, deliver
var crates: Array = []          # {pos, node}
var got := 0
var dock := Vector3.INF
var _left := TIME
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	title = "MISSION 7: CANAL RUN"
	briefing = "Take a boat and fish %d crates out of the canals" % CRATES
	reward = 700
	routed = false
	_rng.randomize()


func objective() -> String:
	match phase:
		"boat": return "Get in a boat (E at the quay)"
		"crates": return "Fish the crates out of the canals  ·  %d / %d" % [got, CRATES]
		"deliver": return "Bring the crates to the dock"
	return ""


func clock() -> float:
	return _left if phase != "boat" else -1.0


func _in_boat() -> bool:
	return m.walker.vehicle != null and m.walker.vehicle.kind == "boat"


func step(delta: float) -> void:
	_t -= delta
	for c in crates:                                # bobbing
		c.node.position.y = c.pos.y + sin(Time.get_ticks_msec() / 400.0 + c.pos.x) * 0.08
		c.node.rotation.y += delta * 0.4
	match phase:
		"boat":
			if _in_boat():
				_spread()
				if crates.size() == CRATES:
					phase = "crates"
					say("CRATES IN THE WATER", "Three of them, under orange beacons")
				return
			if _t <= 0.0 and m.boats:
				_t = 1.0
				var b: Dictionary = m.boats.nearest(Vector2(here().x, here().z), 600.0)
				m.target = Vector3(b.pos.x, 0, b.pos.y) if not b.is_empty() else Vector3.INF
		"crates", "deliver":
			_left -= delta
			if _left <= 0.0:
				fail("Out of time: the buyers left")
				return
			if phase == "crates":
				var best = null
				var bd := INF
				for c in crates:
					var d := flat_dist(c.pos, here())
					if d < bd: bd = d; best = c
				if best == null:
					return
				m.target = best.pos
				if _in_boat() and bd < GRAB:
					_grab(best)
			elif _in_boat() and flat_dist(here(), dock) < GRAB + 3.0:
				succeed("The crates are ashore")


func _grab(c: Dictionary) -> void:
	c.node.queue_free()
	crates.erase(c)
	got += 1
	m.crime.stars = mini(maxi(m.crime.stars, 0) + 1, 2)   # (seen from the quays)
	m.crime.last_seen = here(); m.crime.unseen = 0.0
	if got < CRATES:
		say("CRATE %d" % got, "%d to go. The police saw that" % (CRATES - got))
		return
	dock = _water(Vector2(300.0, 700.0))
	if dock == Vector3.INF:
		dock = _water(Vector2(80.0, 1000.0))
	phase = "deliver"
	m.target = dock
	_beacon(dock, Color(1.0, 0.82, 0.08))
	say("ALL THREE", "Bring them to the dock")


# The crates, out on open water round you.
func _spread() -> void:
	var tries := 0
	while crates.size() < CRATES and tries < 3:
		tries += 1
		var at := _water(Vector2(120.0, 450.0))
		if at == Vector3.INF:
			continue
		if crates.any(func(c): return flat_dist(c.pos, at) < 60.0):
			continue
		var n := _crate()
		n.position = at
		add_child(n)
		crates.append({"pos": at, "node": n})


## A point on open canal water (a few metres clear each way) between d.x and
## d.y metres from you, or INF.
func _water(d: Vector2) -> Vector3:
	var s = m.streamer
	for k in 300:                                      # (canals are narrow: many tries)
		var a := _rng.randf() * TAU
		var r := _rng.randf_range(d.x, d.y)
		var p := here() + Vector3(cos(a) * r, 0, sin(a) * r)
		var ok := true
		for o in [Vector3.ZERO, Vector3(3, 0, 0), Vector3(-3, 0, 0), Vector3(0, 0, 3), Vector3(0, 0, -3)]:
			if s.water_at(p + o) != 1:
				ok = false; break
		if ok:
			return Vector3(p.x, -1.25, p.z)
	return Vector3.INF


func _crate() -> Node3D:
	var n := Node3D.new()
	var wood := StandardMaterial3D.new(); wood.albedo_color = Color("6b4a2b"); wood.roughness = 0.9
	var b := BoxMesh.new(); b.size = Vector3(1.0, 0.7, 0.8)
	var mi := MeshInstance3D.new(); mi.mesh = b; mi.material_override = wood
	n.add_child(mi)
	var band := StandardMaterial3D.new(); band.albedo_color = Color("2a2a2a")
	var bb := BoxMesh.new(); bb.size = Vector3(1.02, 0.1, 0.82)
	var bi := MeshInstance3D.new(); bi.mesh = bb; bi.material_override = band; bi.position.y = 0.15
	n.add_child(bi)
	_beacon_on(n, Color(1.0, 0.5, 0.1))
	return n


func _beacon(at: Vector3, col: Color) -> void:
	var n := Node3D.new()
	_beacon_on(n, col)
	n.position = at
	add_child(n)


func _beacon_on(n: Node3D, col: Color) -> void:
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.albedo_color = Color(col.r, col.g, col.b, 0.22)
	var c := CylinderMesh.new(); c.top_radius = 0.35; c.bottom_radius = 0.35; c.height = 40.0
	c.cap_top = false; c.cap_bottom = false; c.radial_segments = 10
	var mi := MeshInstance3D.new(); mi.mesh = c; mi.material_override = bm; mi.position.y = 20.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(mi)
