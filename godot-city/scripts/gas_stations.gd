extends Node3D
## Amsterdam's petrol stations, where the map data has them (119 of them:
## index.json's "stations", taken from Overture's places by
## prepare_godot_city.py, charging points left out), built as their chunks
## load: a canopy on four posts with the brand along its edge, two to four
## pumps on their islands, a shop, a price totem; lit up at night.
##
## And how one goes: a pump shot three times (or caught by fire, or by a
## blast) burns for a second or two and goes up (Explosions, gasoline), and
## sets the pumps beside it burning; once two have gone, the tank underneath
## goes too: one big gasoline blast, the canopy torn off and thrown, the place
## left a black ruin.
##     gas_stations.setup(streamer, walker, traffic, explosions)

const Models := preload("res://scripts/vehicle_models.gd")

const PUMP_HP := 3              # bullets a pump takes
const PUMP_SIZE := 0.35         # Explosions' slider: a pump going up
const TANK_SIZE := 0.85         # ...and the tank under the forecourt (the large tier)
const TANK_AFTER := 2           # pumps gone before the tank goes
const SPREAD := 7.5             # metres: a pump going up sets those this close burning
# The brands' colours: fascia, stripe.
const BRANDS := {
	"shell": [Color("f7d117"), Color("dd1d21")], "bp": [Color("009b3a"), Color("ffe100")],
	"esso": [Color("ffffff"), Color("d42e12")], "total": [Color("ffffff"), Color("ed1c24")],
	"tango": [Color("f37021"), Color("ffffff")], "tinq": [Color("00a3a6"), Color("e2001a")],
	"gulf": [Color("f58025"), Color("1c3f94")], "texaco": [Color("e31837"), Color("ffffff")],
	"avia": [Color("e30613"), Color("ffffff")], "ok": [Color("1d4f91"), Color("ffffff")],
}

var streamer
var walker
var traffic
var explosions
var stations: Array = []        # every one in the city: {name, pos, built, node, pumps, gone, ruined, by_you, ...}
var _rng := RandomNumberGenerator.new()


func setup(s, w, t, e) -> void:
	streamer = s; walker = w; traffic = t; explosions = e
	_rng.randomize()
	for st in s.index.get("stations", []):
		stations.append({"name": String(st[0]), "pos": Vector3(float(st[1]) / 10.0, 0.0, -float(st[2]) / 10.0), "node": null, "ruined": false})
	s.tile_added.connect(_on_tile)
	s.tile_removed.connect(_off_tile)


## The nearest station to `p` (built or not), or {}.
func nearest(p: Vector3) -> Dictionary:
	var best := {}
	var bd := INF
	for st in stations:
		var d: float = Vector2(st.pos.x - p.x, st.pos.z - p.z).length()
		if d < bd and not st.ruined:
			bd = d; best = st
	return best


func _on_tile(key: String, r: Dictionary) -> void:
	var rect: Rect2 = r.rect
	var here: Array = stations.filter(func(st): return st.node == null and rect.has_point(Vector2(st.pos.x, st.pos.z)))
	if here.is_empty():
		return
	if is_inside_tree():
		await get_tree().physics_frame             # (the chunk's walls are in the physics world from the next step)
	for st in here:
		if st.node == null:
			st.key = key
			build(st)


func _off_tile(key: String) -> void:
	for st in stations:
		if st.get("key", "") == key and st.node != null:
			st.node.queue_free()
			st.node = null


# ---- building one -----------------------------------------------------------------------

## Build `st` where it stands (moved to the nearest open ground, and turned
## along the nearest street).
func build(st: Dictionary) -> void:
	var at: Vector3 = st.pos
	var yaw := _road_yaw(at)
	if not st.has("at"):                          # (once: it stands in the same place when its chunk comes back)
		var near := _ways_near(st.pos, 150.0)
		for k in 220:                             # a spiral out to about 120 m for open ground the size of it
			var a := k * 2.4
			var p: Vector3 = st.pos + Vector3(cos(a), 0, sin(a)) * (sqrt(k) * 8.0)
			if _off_ways(p, near) and _clear(p, yaw):
				at = p; break
		st.at = at
		st.yaw = _road_yaw(at)
	at = st.at
	yaw = st.yaw
	var n := Node3D.new()
	n.name = "station"
	add_child(n)
	n.global_position = at
	n.rotation.y = yaw
	st.node = n
	var key: String = st.name.to_lower()
	var brand: Array = [Color("d0d4d8"), Color("c0392b")]
	for b in BRANDS:
		if key.contains(b): brand = BRANDS[b]
	var white := Models.mat("st_white", Color("eceeef"), 0.6)
	var roof := Models.mat("st_roof", Color("6d7378"), 0.8)
	var wall := Models.mat("st_wall", Color("a9aeb2"), 0.85)
	var face := Models.mat("st_face_" + brand[0].to_html(false), brand[0], 0.5)
	var stripe := Models.mat("st_stripe_" + brand[1].to_html(false), brand[1], 0.5)
	var lamp := Models.mat("st_lamp", Color("f6f2e2"), 0.4, 0.0, Color("fff3d6"))   # lit at night (Models.lights)
	st.mats = []
	# The canopy over the forecourt, its lights underneath, the brand along its edges.
	var canopy := Node3D.new(); canopy.name = "canopy"
	n.add_child(canopy)
	_box(canopy, Vector3(13.0, 0.7, 8.5), Vector3(0, 5.35, 0), white)
	_box(canopy, Vector3(12.6, 0.06, 8.1), Vector3(0, 5.72, 0), roof)
	_box(canopy, Vector3(13.1, 0.36, 8.6), Vector3(0, 5.3, 0), face)
	_box(canopy, Vector3(13.12, 0.1, 8.62), Vector3(0, 5.08, 0), stripe)
	for x in [-4.0, 0.0, 4.0]:
		_box(canopy, Vector3(2.2, 0.04, 1.2), Vector3(x, 4.98, 0), lamp)
	for side in [-1, 1]:
		var l := Models.sign_text(canopy, st.name, Vector3(0, 5.3, side * 4.33), 0.0 if side > 0 else PI, 9.0, 0.32,
			brand[1] if brand[0].v > 0.7 else Color.WHITE, true)
		l.double_sided = false
	for p in [Vector3(-5.0, 0, -3.0), Vector3(5.0, 0, -3.0), Vector3(-5.0, 0, 3.0), Vector3(5.0, 0, 3.0)]:
		_cyl(canopy, 0.18, 4.9, p + Vector3(0, 2.45, 0), white)
	# The islands and their pumps.
	var count := 2 + absi(hash(st.name)) % 3
	st.pumps = []
	for i in count:
		var x := (i - (count - 1) / 2.0) * (10.0 / count)
		_box(n, Vector3(1.4, 0.15, 3.2), Vector3(x, 0.075, 0), Models.mat("st_kerb", Color("9a9a96"), 0.9))
		var pump := StaticBody3D.new()
		pump.collision_layer = 4               # bullets meet it, as they meet a car
		pump.collision_mask = 0
		var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(0.7, 1.8, 1.0)
		cs.shape = bs; cs.position.y = 1.05
		pump.add_child(cs)
		_box(pump, Vector3(0.7, 1.7, 1.0), Vector3(0, 1.0, 0), white)
		_box(pump, Vector3(0.72, 0.3, 1.02), Vector3(0, 1.75, 0), face)
		_box(pump, Vector3(0.74, 0.08, 1.04), Vector3(0, 1.55, 0), stripe)
		_box(pump, Vector3(0.05, 0.3, 0.45), Vector3(0.37, 1.25, 0), Models.mat("st_screen", Color("1c2a35"), 0.2, 0.0, Color("6fc3ff")))
		n.add_child(pump)
		pump.position = Vector3(x, 0, 0)
		var pd := {"node": pump, "station": st, "hp": PUMP_HP, "burning": false, "gone": false}
		pump.set_meta("pump", pd)
		st.pumps.append(pd)
	# The shop behind, and the price totem by the street.
	var shop := StaticBody3D.new()
	shop.collision_layer = 1                   # a wall to walk into
	var scs := CollisionShape3D.new(); var sbs := BoxShape3D.new(); sbs.size = Vector3(8.0, 3.4, 5.0)
	scs.shape = sbs; scs.position = Vector3(0, 1.7, -9.5)
	shop.add_child(scs)
	_box(shop, Vector3(8.0, 3.4, 5.0), Vector3(0, 1.7, -9.5), wall)
	_box(shop, Vector3(7.6, 0.06, 4.6), Vector3(0, 3.47, -9.5), roof)
	_box(shop, Vector3(5.5, 2.2, 0.05), Vector3(0, 1.3, -6.97), Models.mat("st_glass", Color("2a3b44"), 0.1, 0.5, Color("ffe9b8")))
	_box(shop, Vector3(8.1, 0.5, 5.1), Vector3(0, 3.2, -9.5), face)
	n.add_child(shop)
	_cyl(n, 0.15, 6.0, Vector3(8.5, 3.0, 4.5), Models.mat("st_pole", Color("5c6166"), 0.5, 0.5))
	_box(n, Vector3(1.6, 2.4, 0.3), Vector3(8.5, 6.0, 4.5), face)
	_box(n, Vector3(1.4, 1.2, 0.32), Vector3(8.5, 5.4, 4.5), Models.mat("st_prices", Color("111417"), 0.3, 0.0, Color("ff3b2f")))
	st.gone = 0
	st.tank = false
	if st.ruined:                              # come back to a ruin: no canopy, no pumps
		canopy.free()
		for pd in st.pumps:
			pd.gone = true; pd.node.visible = false; pd.node.collision_layer = 0
		st.tank = true
		_ruin(st)


# The streets, tram lines and bike paths within `r` of `p`: [a, b, half width].
func _ways_near(p: Vector3, r: float) -> Array:
	var out := []
	if traffic == null:
		return out
	var q := Vector2(p.x, p.z)
	for id in traffic.edges:
		var e: Dictionary = traffic.edges[id]
		var pts: PackedVector2Array = e.p
		var hw: float = float(e.get("w", 6.0)) / 2.0
		for i in pts.size() - 1:
			if Geometry2D.get_closest_point_to_segment(q, pts[i], pts[i + 1]).distance_to(q) < r:
				out.append([pts[i], pts[i + 1], hw])
	return out


# Not on any of them: the forecourt (about 10 m round its middle) clear of the carriageway.
func _off_ways(p: Vector3, ways: Array) -> bool:
	var q := Vector2(p.x, p.z)
	for wy in ways:
		if Geometry2D.get_closest_point_to_segment(q, wy[0], wy[1]).distance_to(q) < wy[2] + 10.5:
			return false
	return true


# Open ground for the forecourt, the shop and the totem at `p`, turned `yaw`:
# no water under it, no wall in it.
func _clear(p: Vector3, yaw: float) -> bool:
	var b := Basis(Vector3.UP, yaw)
	for o in [Vector3.ZERO, Vector3(7, 0, 5), Vector3(-7, 0, 5), Vector3(7, 0, -12), Vector3(-7, 0, -12), Vector3(9, 0, 5)]:
		if streamer and streamer.has_method("water_at") and streamer.water_at(p + b * o) != 0:
			return false
	if not is_inside_tree():
		return true
	var q := PhysicsShapeQueryParameters3D.new()
	var box := BoxShape3D.new(); box.size = Vector3(19.0, 3.0, 19.0)
	q.shape = box
	q.collision_mask = 1
	q.transform = Transform3D(b, p + b * Vector3(0.5, 2.0, -3.0))
	var space := get_world_3d().direct_space_state
	if not space.intersect_shape(q, 1).is_empty():
		return false
	# (a box wholly inside a building meets none of its walls: no roof over it, from the minimap's)
	if streamer and streamer.has_method("minimap_near"):
		var roofs: Array = streamer.minimap_near(Vector2(p.x, p.z), 20.0).filter(func(l): return l[0] == "roof")
		for o in [Vector3.ZERO, Vector3(7, 0, 5), Vector3(-7, 0, 5), Vector3(7, 0, -12), Vector3(-7, 0, -12), Vector3(0, 0, -9), Vector3(9, 0, 5)]:
			var at: Vector3 = p + b * o
			var q2 := Vector2(at.x, at.z)
			for l in roofs:
				var t: PackedVector2Array = l[1]
				for i in range(0, t.size() - 2, 3):
					if Geometry2D.point_is_inside_triangle(q2, t[i], t[i + 1], t[i + 2]):
						return false
	return true


# The canopy runs along the nearest street (or north-south when none is near).
func _road_yaw(p: Vector3) -> float:
	if traffic == null:
		return 0.0
	var best := 60.0
	var yaw := 0.0
	var q := Vector2(p.x, p.z)
	for id in traffic.by_kind.get("road", []):
		var e: Dictionary = traffic.edges[id]
		var pts: PackedVector2Array = e.p
		for i in pts.size() - 1:
			var c := Geometry2D.get_closest_point_to_segment(q, pts[i], pts[i + 1])
			if c.distance_to(q) < best:
				best = c.distance_to(q)
				var d := pts[i + 1] - pts[i]
				yaw = atan2(-d.x, -d.y) + PI / 2.0
	return yaw


func _box(parent: Node3D, size: Vector3, pos: Vector3, m: Material) -> MeshInstance3D:
	var b := BoxMesh.new(); b.size = size
	var mi := MeshInstance3D.new(); mi.mesh = b; mi.material_override = m; mi.position = pos
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, r: float, h: float, pos: Vector3, m: Material) -> void:
	var c := CylinderMesh.new(); c.top_radius = r; c.bottom_radius = r; c.height = h; c.radial_segments = 10; c.rings = 1
	var mi := MeshInstance3D.new(); mi.mesh = c; mi.material_override = m; mi.position = pos
	parent.add_child(mi)


# ---- blowing one up ------------------------------------------------------------------------

## A bullet in a pump.
func hit_pump(pd: Dictionary, by_you := true) -> void:
	if pd.gone or pd.burning:
		return
	pd.hp -= 1
	pd.station.by_you = by_you or pd.station.get("by_you", false)
	if pd.hp <= 0:
		ignite(pd, _rng.randf_range(1.0, 2.0))


## Fire or a blast at `at`, reaching `radius`: the pumps in it catch.
func burn_near(at: Vector3, radius: float, by_you := false) -> void:
	for st in stations:
		if st.node == null or st.ruined:
			continue
		if Vector2(st.at.x - at.x, st.at.z - at.z).length() > radius + 12.0:
			continue
		for pd in st.pumps:
			if not pd.gone and not pd.burning and (pd.node as Node3D).global_position.distance_to(at) < radius:
				st.by_you = by_you or st.get("by_you", false)
				ignite(pd, _rng.randf_range(0.8, 1.6))


## A pump on fire: flames and smoke, and in `secs` it goes.
func ignite(pd: Dictionary, secs: float) -> void:
	if pd.gone or pd.burning:
		return
	pd.burning = true
	var at: Vector3 = (pd.node as Node3D).global_position + Vector3(0, 1.6, 0)
	if explosions:
		var fl: CPUParticles3D = explosions._spray(at, 20, explosions._flame_mat(), 0.4, 0.8, Vector3.UP, 20.0, 0.8, 2.0, Vector3(0, 1.0, 0), 0.7, 0.4, explosions._ramp(explosions.FIRE), 0.0, null, true)
		fl.explosiveness = 0.0; fl.one_shot = false
		explosions._stop_after(fl, secs + 0.2)
		explosions.later(secs, _pump_boom.bind(pd))
	else:
		_pump_boom(pd)


func _pump_boom(pd: Dictionary) -> void:
	if pd.gone:
		return
	pd.gone = true
	var st: Dictionary = pd.station
	var p: Node3D = pd.node
	if not is_instance_valid(p):
		return
	var at := p.global_position + Vector3(0, 0.8, 0)
	p.visible = false
	p.collision_layer = 0
	if explosions:
		explosions.explode("gasoline", at, PUMP_SIZE, st.get("by_you", false))
	st.gone += 1
	for o in st.pumps:                                     # the next one along catches
		if not o.gone and not o.burning and (o.node as Node3D).global_position.distance_to(p.global_position) < SPREAD:
			ignite(o, _rng.randf_range(0.6, 1.4))
	if not st.tank and (st.gone >= TANK_AFTER or st.gone >= st.pumps.size()):
		st.tank = true
		if explosions:
			explosions.later(1.2, _tank_boom.bind(st))
		else:
			_tank_boom(st)


# The tank under the forecourt: the big one. The canopy is torn off and
# thrown; what is left is a black ruin.
func _tank_boom(st: Dictionary) -> void:
	if st.ruined or st.node == null:
		return
	st.ruined = true
	var n: Node3D = st.node
	var at := n.global_position + Vector3(0, 0.6, 0)
	if explosions:
		explosions.explode("gasoline", at, TANK_SIZE, st.get("by_you", false))
	for pd in st.pumps:
		if not pd.gone:
			pd.gone = true
			if is_instance_valid(pd.node): pd.node.visible = false
	# The canopy, thrown: a real body for a few seconds' flight.
	var canopy: Node3D = n.get_node_or_null("canopy")
	if canopy:
		var b := RigidBody3D.new()
		b.mass = 900.0
		b.collision_layer = 0
		b.collision_mask = 1 | 2
		var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(13.0, 0.7, 8.5)
		cs.shape = bs; cs.position.y = 5.35
		b.add_child(cs)
		add_child(b)
		b.global_transform = canopy.global_transform
		canopy.reparent(b, true)
		# (velocities, not impulses: a body just made has no mass yet the frame it is added)
		b.linear_velocity = Vector3(_rng.randf_range(-3, 3), 9.0, _rng.randf_range(-3, 3))
		b.angular_velocity = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-0.4, 0.4), _rng.randf_range(-1, 1)) * 0.8
		st.canopy = b
		get_tree().create_timer(30.0).timeout.connect(func(): if is_instance_valid(b): b.queue_free())
		if explosions and explosions.sfx: explosions.sfx.play("metal_groan", at, "Explosions", 0.0, 0.4)
	_ruin(st)


func _ruin(st: Dictionary) -> void:
	var dark := Models.mat("st_charred", Color(0.06, 0.055, 0.05), 1.0)
	for g in (st.node as Node3D).find_children("*", "MeshInstance3D", true, false):
		(g as MeshInstance3D).material_override = dark
	for l in (st.node as Node3D).find_children("*", "Label3D", true, false):
		l.visible = false
	if st.has("canopy") and is_instance_valid(st.canopy):
		for g in (st.canopy as Node3D).find_children("*", "MeshInstance3D", true, false):
			(g as MeshInstance3D).material_override = dark
