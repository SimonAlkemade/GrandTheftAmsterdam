extends Node3D
## Mission 2: a gun, and the police. A gun shop near the start (a blue
## circle) sells a pistol; left click shoots it where the camera looks. Shots
## bring a wanted level of one to five stars: police cars drive at you along
## the streets with their lights going, officers get out and run you down, and
## one who reaches you while you are on foot (or sitting still in a vehicle)
## arrests you: BUSTED, a fine, and the pistol is gone. Out of their sight the
## stars flash, and once you have stayed out of sight long enough they clear.

signal announce(title: String, sub: String)

const Human := preload("res://scripts/human.gd")
const Models := preload("res://scripts/vehicle_models.gd")
const Ragdoll := preload("res://scripts/ragdoll.gd")

const START_CASH := 60          # enough for a pistol at once
const PISTOL := 50              # € for the pistol and two magazines' worth
const AMMO := 10                # € for 24 more rounds, back at the shop
const MAG := 12
const START_ROUNDS := 24        # carried besides the one in the gun
const RANGE := 150.0
const SHOT_GAP := 0.22          # seconds between shots
const RELOAD := 1.3
const CIRCLE := 3.0
const BLUE := Color(0.25, 0.55, 1.0)
const COP_SPEED := 4.6          # m/s: slower than you running (6.2)
const COP_SEES := 70.0          # metres an officer can see you over, with a clear line
const ARREST := 1.3             # metres: within this for ARREST_TIME, you are taken
const ARREST_TIME := 0.8
const FINE := 100
const COPS_PER_CAR := 2

var streamer
var traffic
var walker
var mission
var state := "off"              # off, shop (go and buy), armed
var shop := Vector3.INF
var shop_name := ""
var armed := false
var mag := 0
var rounds := 0
var stars := 0
var seen := false               # does any officer see you right now
var unseen := 0.0               # seconds since police last saw you (or you last did something)
var last_seen := Vector3.ZERO   # where they last saw you (or heard the shot): where they go
var cops: Array = []            # {h, pos, heading, down, car, last}
var cars: Array = []            # the police cars (Traffic vehicles) on the call
var aim_t := 0.0                # seconds since the last shot (the pose holds a little)
var _cool := 0.0
var _reload := 0.0
var _dispatch := 0.0
var _arrest := 0.0
var _marker: Node3D
var _fx: Node3D
var _rng := RandomNumberGenerator.new()


func setup(s, t, w, m) -> void:
	streamer = s; traffic = t; walker = w; mission = m
	_rng.seed = 11
	_fx = Node3D.new()
	add_child(_fx)


## Begin Mission 2: start cash, and a gun shop placed on a pavement near you.
func start() -> void:
	mission.money += START_CASH
	state = "shop"
	_place_shop()


func objective() -> String:
	match state:
		"shop":
			if shop == Vector3.INF:
				return ""
			return "Mission 2: buy a pistol at %s (€%d)  ·  %d m" % [shop_name, PISTOL, int(_dist(shop))]
		"armed":
			if stars > 0:
				return "Wanted! Lose the police: get out of their sight" if seen else "Out of sight: keep away from the police"
			return "Left click shoots, R reloads. Shooting brings the police; at the shop: more ammo (€%d)" % AMMO
	return ""


## Ammo for the HUD, or "" without a gun.
func ammo_text() -> String:
	if not armed:
		return ""
	return "Pistol  %d / %d%s" % [mag, rounds, "  reloading" if _reload > 0.0 else ""]


func _dist(p: Vector3) -> float:
	return Vector2(p.x, p.z).distance_to(Vector2(walker.global_position.x, walker.global_position.z))


# ---- the shop ----------------------------------------------------------------------

func _place_shop() -> void:
	var from: Vector3 = walker.global_position
	for k in 200:
		var a := _rng.randf() * TAU
		var d := _rng.randf_range(35.0, 80.0)
		var p := from + Vector3(cos(a) * d, 0, sin(a) * d)
		p.y = 0.0
		if streamer.water_at(p) != 0 or not walker._free(p):
			continue
		var clear := true
		for e in [Vector3(CIRCLE, 0, 0), Vector3(-CIRCLE, 0, 0), Vector3(0, 0, CIRCLE), Vector3(0, 0, -CIRCLE)]:
			if streamer.water_at(p + e) != 0 or not walker._free(p + e):
				clear = false
		if not clear:
			continue
		shop = p
		var street: String = streamer.nearest_name(p, 60.0)
		shop_name = "the gun shop" + (" on the " + street if street != "" else "")
		_marker = _build_marker()
		add_child(_marker)
		_marker.position = p
		return


func _build_marker() -> Node3D:
	var n := Node3D.new()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.35)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	var disk := CylinderMesh.new(); disk.top_radius = CIRCLE; disk.bottom_radius = CIRCLE; disk.height = 0.03; disk.radial_segments = 48
	var beam := CylinderMesh.new(); beam.top_radius = 0.45; beam.bottom_radius = 0.45; beam.height = 70.0
	beam.cap_top = false; beam.cap_bottom = false
	for mesh_y in [[disk, 0.02], [beam, 35.0]]:
		var mi := MeshInstance3D.new(); mi.mesh = mesh_y[0]; mi.material_override = m; mi.position.y = mesh_y[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.add_child(mi)
	var label := Models.sign_text(n, "WAPENS", Vector3(0, 2.6, 0), 0.0, 2.4, 0.5, BLUE, true)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.name = "sign"
	return n


func _at_shop() -> void:
	if walker.vehicle != null or shop == Vector3.INF or _dist(shop) > CIRCLE:
		return
	if not armed:
		if mission.money < PISTOL:
			if Engine.get_process_frames() % 120 == 0:
				announce.emit("€%d short" % (PISTOL - mission.money), "A pistol is €%d: deliver a parcel first" % PISTOL)
			return
		mission.money -= PISTOL
		armed = true; mag = MAG; rounds = START_ROUNDS
		state = "armed"
		announce.emit("Pistol bought", "Left click to shoot, R to reload. Mind the police.")
	elif rounds < START_ROUNDS and mission.money >= AMMO and Engine.get_process_frames() % 30 == 0:
		mission.money -= AMMO
		rounds += 24
		announce.emit("Ammo", "+24 rounds")


# ---- the pistol ----------------------------------------------------------------------

## A shot where the camera looks (from the pistol in your hand).
func fire() -> void:
	if not armed or _cool > 0.0 or _reload > 0.0:
		return
	if mag == 0:
		reload()
		return
	mag -= 1
	_cool = SHOT_GAP
	aim_t = 0.0
	walker.heading = walker.cam_yaw                          # turn to where you aim
	var cam: Camera3D = walker.cam
	var from := cam.global_position
	var dir := -cam.global_transform.basis.z
	var muzzle: Vector3 = walker.global_position + Vector3(0, 1.4, 0) + Vector3(-sin(walker.heading), 0, -cos(walker.heading)) * 0.6
	# What the bullet meets first: a wall, the street, a vehicle, or a person.
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * RANGE, 1 | 2 | 4 | 8)
	q.exclude = [walker.get_rid()]
	var hit: Dictionary = walker.get_world_3d().direct_space_state.intersect_ray(q)
	var t_wall := RANGE if hit.is_empty() else from.distance_to(hit.position)
	var victim = null
	var t_best := t_wall
	for p in walker.peds:
		if p.get("dead", false) or p.has("rag"):         # (someone lying in the street is below the shot)
			continue
		var t := _ray_person(from, dir, p.pos)
		if t < t_best:
			t_best = t; victim = ["ped", p]
	for c in cops:
		if c.down:
			continue
		var t := _ray_person(from, dir, c.pos)
		if t < t_best:
			t_best = t; victim = ["cop", c]
	var at := from + dir * t_best
	_tracer(muzzle, at)
	_flash(muzzle)
	if victim == null and not hit.is_empty():
		_puff(at)
		if hit.collider is RigidBody3D:                     # a real vehicle takes the knock
			(hit.collider as RigidBody3D).apply_impulse(dir * 400.0, at - (hit.collider as RigidBody3D).global_position)
	# Every shot is a crime; who it hits decides how bad.
	stars = maxi(stars, 1)
	if victim != null:
		var shove := Vector3(dir.x, 0, dir.z).normalized() * 3.0 + Vector3.UP * 0.8   # the bullet's knock
		if victim[0] == "ped":
			_down_ped(victim[1])
			walker.knock(victim[1], shove)
			stars = maxi(stars, 2)
		else:
			victim[1].down = true
			victim[1].rag = Ragdoll.knock(victim[1].h, shove)
			stars = clampi(maxi(stars + 1, 3), 1, 5)
	unseen = 0.0                                            # they know where it came from
	last_seen = walker.global_position
	for c in cops:
		if not c.down:
			c.last = last_seen
	_scare(walker.global_position)


func reload() -> void:
	if armed and _reload <= 0.0 and mag < MAG and rounds > 0:
		_reload = RELOAD


# How far along the ray (from, dir) a person standing at p is hit, or INF:
# a body of radius 0.35 m from the knees to the head.
func _ray_person(from: Vector3, dir: Vector3, p: Vector3) -> float:
	var a := p + Vector3(0, 0.5, 0)
	var b := p + Vector3(0, 1.75, 0)
	var r := Geometry3D.get_closest_points_between_segments(from, from + dir * RANGE, a, b)
	if (r[0] as Vector3).distance_to(r[1]) > 0.35:
		return INF
	return from.distance_to(r[0])


func _down_ped(p: Dictionary) -> void:
	p.dead = true
	p.dead_t = 25.0
	p.speed_was = p.speed


# Everyone near a gunshot runs from it.
func _scare(at: Vector3) -> void:
	for p in walker.peds:
		if p.get("dead", false):
			continue
		if p.pos.distance_to(at) < 40.0:
			p.flee = 8.0
			p.flee_from = at


func _tracer(a: Vector3, b: Vector3) -> void:
	var im := ImmediateMesh.new()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.45)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, m)
	im.surface_add_vertex(a); im.surface_add_vertex(b)
	im.surface_end()
	var mi := MeshInstance3D.new(); mi.mesh = im
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_fx.add_child(mi)
	_fade(mi, m, 0.08)


func _flash(at: Vector3) -> void:
	var s := SphereMesh.new(); s.radius = 0.12; s.height = 0.24
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.8, 0.3)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := MeshInstance3D.new(); mi.mesh = s; mi.material_override = m; mi.position = at
	_fx.add_child(mi)
	var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.75, 0.35); l.light_energy = 3.0; l.omni_range = 6.0
	mi.add_child(l)
	_fade(mi, m, 0.06)


func _puff(at: Vector3) -> void:
	var s := SphereMesh.new(); s.radius = 0.15; s.height = 0.3
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.6, 0.6, 0.58, 0.8)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var mi := MeshInstance3D.new(); mi.mesh = s; mi.material_override = m; mi.position = at
	_fx.add_child(mi)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * 3.0, 0.5)
	tw.parallel().tween_property(m, "albedo_color:a", 0.0, 0.5)
	tw.tween_callback(mi.queue_free)


func _fade(n: Node, m: StandardMaterial3D, t: float) -> void:
	var tw := n.create_tween()
	tw.tween_property(m, "albedo_color:a", 0.0, t)
	tw.tween_callback(n.queue_free)


# ---- the wanted level and the police ----------------------------------------------------

# On the physics tick: the same police at any frame rate.
func _physics_process(delta: float) -> void:
	if state == "off" or not walker.active:
		return
	_cool = maxf(0.0, _cool - delta)
	aim_t += delta
	if _reload > 0.0:
		_reload -= delta
		if _reload <= 0.0:
			var take := mini(MAG - mag, rounds)
			mag += take; rounds -= take
	if armed and mag == 0 and rounds > 0 and _reload <= 0.0:
		reload()
	_at_shop()
	if _marker:
		_marker.visible = state == "shop" or (armed and rounds < START_ROUNDS)
		_marker.get_node("sign").position.y = 2.6 + sin(Time.get_ticks_msec() / 400.0) * 0.15
	_dead_peds(delta)
	Models.flash_police(Time.get_ticks_msec() / 1000.0, stars > 0)
	if stars == 0:
		_stand_down(delta)
		return
	var you := Vector2(walker.global_position.x, walker.global_position.z)
	# Dispatch: a car per star (up to four on the call), one every few seconds.
	cars = cars.filter(func(v): return traffic.vehicles.has(v))
	_dispatch -= delta
	if _dispatch <= 0.0 and cars.size() < mini(stars, 4):
		var v: Dictionary = traffic.spawn_police(Vector2(last_seen.x, last_seen.z))   # sent to where it happened
		if not v.is_empty():
			cars.append(v)
		_dispatch = maxf(2.0, 8.0 - stars * 1.2)
	for v in cars:
		v.call_t = float(v.get("call_t", 0.0)) + delta
		if v.get("parked", false):
			continue
		v.chase = Vector2(last_seen.x, last_seen.z)          # where they last saw you, not where you are
		# It stops (and its officers get out) once it is close, or as close as
		# the streets take it (Traffic routes it there), or held up.
		var d: float = minf(v.pos.distance_to(you), v.pos.distance_to(v.chase))
		v.held = float(v.get("held", 0.0)) + delta if v.speed < 0.5 else 0.0
		if d < 25.0 or v.get("there", false) or v.held > 3.0 or v.call_t > 30.0:
			_arrive(v)
	# The officers on foot.
	seen = false
	var head: Vector3 = walker.global_position + Vector3(0, 1.5, 0)
	for c in cops:
		if c.down:
			_lie(c)
			continue
		var d: float = Vector2(c.pos.x, c.pos.z).distance_to(you)
		c.sees = d < COP_SEES and _sees(c.pos + Vector3(0, 1.6, 0), head)
		if c.sees:
			seen = true
	if seen:
		last_seen = walker.global_position
	for c in cops:
		if c.down:
			continue
		var d: float = Vector2(c.pos.x, c.pos.z).distance_to(you)
		if c.sees or seen and d < 30.0:
			c.last = walker.global_position                  # a colleague's radio, close by
		_run_cop(c, delta)
		# Caught: on foot, or sitting still in a vehicle.
		if d < ARREST and (walker.vehicle == null or absf(walker.car_speed) < 1.5):
			_arrest += delta
	for v in cars:                                          # a car on your tail sees you too
		if v.pos.distance_to(you) < 35.0:
			seen = true
			last_seen = walker.global_position
	if _arrest > ARREST_TIME:
		_busted()
		return
	if not seen:
		_arrest = maxf(0.0, _arrest - delta)
	# The search only counts once officers are at the place they were sent to.
	# While they are still on their way they hold on.
	var searching := cops.any(func(c): return not c.down and Vector2(c.pos.x, c.pos.z).distance_to(Vector2(last_seen.x, last_seen.z)) < 40.0) \
		or cars.any(func(v): return v.get("parked", false) and v.get("call_t", 0.0) > 60.0)   # or long enough
	if seen or not searching:
		unseen = 0.0
	else:
		unseen += delta
	if unseen > 10.0 + 5.0 * stars:
		stars = 0
		announce.emit("Lost them", "The police have given up the search")


# A police car on the scene: it stops, and its officers get out.
func _arrive(v: Dictionary) -> void:
	v.parked = true
	v.speed = 0.0
	var n: Node3D = v.parts[0][0]
	var right := Vector3(cos(n.rotation.y), 0, -sin(n.rotation.y))
	var fwd := Vector3(-sin(n.rotation.y), 0, -cos(n.rotation.y))
	var mid := Vector3(n.position.x, 0, n.position.z)
	for k in COPS_PER_CAR:
		# Out of its doors, on whichever side has street (not a house front) there.
		var at := mid + right * 1.6 + fwd * (0.6 - k * 1.2)
		if not walker._free(at):
			at = mid - right * 1.6 + fwd * (0.6 - k * 1.2)
		var h: Node3D = Human.new()
		h.build(Color("cfdcec"), Color("1c2333"), Color(["f1c7a5", "d9a07a", "a56a43", "6b4128"][_rng.randi() % 4]),
			Color("1a1a1a"), Color("111111"), Color("1d2f57"))
		add_child(h)
		var cap := MeshInstance3D.new()
		var cm := CylinderMesh.new(); cm.top_radius = 0.13; cm.bottom_radius = 0.125; cm.height = 0.08; cm.radial_segments = 10; cm.rings = 1
		cap.mesh = cm; cap.material_override = Human._m(Color("1d2f57"))
		cap.position.y = 0.12
		h.head.add_child(cap)
		cops.append({"h": h, "pos": at, "heading": n.rotation.y, "down": false, "car": v, "last": last_seen})


# Can someone at `eye` see `head` (nothing built in between)?
func _sees(eye: Vector3, head: Vector3) -> bool:
	var q := PhysicsRayQueryParameters3D.create(eye, head, 1)
	return walker.get_world_3d().direct_space_state.intersect_ray(q).is_empty()


# An officer on foot: straight at you once they can see you; otherwise along
# the streets (the courier's route finder) to where you were last seen.
func _run_cop(c: Dictionary, delta: float) -> void:
	var goal: Vector3 = c.last
	var h: Node3D = c.h
	if not c.get("sees", false) and mission.has_method("_path"):
		c.route_t = float(c.get("route_t", 0.0)) - delta
		var stale: bool = c.get("route_to", Vector3.INF).distance_to(goal) > 8.0
		var here := Vector2(c.pos.x, c.pos.z)
		if stale or (c.route_t <= 0.0 and c.get("route", PackedVector2Array()).is_empty()):
			var fresh: PackedVector2Array = mission._path(here, Vector2(goal.x, goal.z))
			# Skip the corners it starts by doubling back to.
			while fresh.size() > 2 and here.distance_to(fresh[2]) < fresh[1].distance_to(fresh[2]):
				fresh.remove_at(1)
			c.route = fresh
			c.route_to = goal
			c.route_t = 3.0
		var route: PackedVector2Array = c.get("route", PackedVector2Array())
		# The next corner along it, at least 2.5 m ahead (the last leg: straight to `goal`).
		while route.size() > 0 and route[0].distance_to(here) < 2.5:
			route.remove_at(0)
		c.route = route
		if route.size() > 0 and here.distance_to(Vector2(goal.x, goal.z)) > 12.0:
			goal = Vector3(route[0].x, 0, route[0].y)
	var to: Vector3 = goal - c.pos
	to.y = 0.0
	if to.length() < 0.9:
		h.animate(delta, "idle", 0.0)
	else:
		var want := atan2(-to.x, -to.z)
		c.heading += clampf(wrapf(want - c.heading, -PI, PI), -6.0 * delta, 6.0 * delta)
		var f := Vector3(-sin(c.heading), 0, -cos(c.heading))
		if walker._free(c.pos + f * 0.9):
			c.pos += f * COP_SPEED * delta
		else:
			for t in [0.5, -0.5, 1.0, -1.0, 1.6, -1.6]:
				var hh: float = c.heading + t
				if walker._free(c.pos + Vector3(-sin(hh), 0, -cos(hh)) * 0.9):
					c.heading = hh; break
		h.animate(delta, "run", COP_SPEED)
	var gy = walker._ground(c.pos)
	h.position = Vector3(c.pos.x, gy if gy != null else 0.0, c.pos.z)
	h.rotation = Vector3(0, c.heading, 0)


func _free_cop(c: Dictionary) -> void:
	if c.has("rag"):
		c.rag.queue_free()
	c.h.queue_free()


func _lie(c: Dictionary) -> void:
	if c.has("rag"):                                     # limp where they fell
		var at: Vector3 = c.rag.pelvis()
		c.pos = Vector3(at.x, 0.0, at.z)
		return
	var h: Node3D = c.h
	h.rotation = Vector3(-PI / 2, c.heading, 0)
	h.position = Vector3(c.pos.x, 0.18, c.pos.z)


# Shot pedestrians lie where they fell for a while, then the street forgets them.
func _dead_peds(delta: float) -> void:
	for p in walker.peds:
		if not p.get("dead", false):
			continue
		p.dead_t -= delta
		if p.dead_t <= 0.0:
			p.dead = false
			p.flee = 0.0
			walker._place(p, false)


# No call: the police leave (gone once you are a little way off).
func _stand_down(_delta: float) -> void:
	for c in cops.duplicate():
		if _dist(c.pos) > 45.0 or c.down and _dist(c.pos) > 25.0:
			_free_cop(c)
			cops.erase(c)
		elif not c.down:
			c.h.animate(_delta, "idle", 0.0)
	for v in cars.duplicate():
		if not traffic.vehicles.has(v):
			cars.erase(v)
		elif _dist(Vector3(v.pos.x, 0, v.pos.y)) > 60.0:
			traffic._despawn(v)
			cars.erase(v)
	seen = false
	_arrest = 0.0


func _busted() -> void:
	var fine: int = mini(FINE, mission.money)
	mission.money -= fine
	armed = false; mag = 0; rounds = 0
	stars = 0
	_arrest = 0.0
	state = "shop"
	if walker.vehicle != null:
		walker._get_out()
	for c in cops:
		_free_cop(c)
	cops.clear()
	for v in cars:
		if traffic.vehicles.has(v):
			traffic._despawn(v)
	cars.clear()
	announce.emit("BUSTED", "Fined €%d. The police took your pistol." % fine)
