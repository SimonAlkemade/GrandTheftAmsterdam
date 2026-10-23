extends Node3D
## Sloepen moored in the canals around you, each a floating Boat you can take.
##
## Boats appear on canal water within `radius` of `focus` (lying along the
## canal, close to a quay, apart from each other) and go again when you are
## far away, except the one you are in or left somewhere.

const Boat := preload("res://scripts/boat.gd")
const COLORS := ["e6e6e2", "e6e6e2", "1d2e45", "e6e6e2", "2d4a34", "7a1e1e"]

var streamer
var target := 14
var radius := 320.0
var focus := Vector3.ZERO
var boats: Array = []             # {"boat": Boat, "pos": Vector2, "driver": bool, "kept": bool}
var _scene: PackedScene
var _rng := RandomNumberGenerator.new()
var _wait := 0.0
var _water: Array = []            # [ring, bounding Rect2] of the canals near focus
var _water_at := Vector2(INF, INF)


func _ready() -> void:
	_scene = load("res://models/boat.glb")
	_rng.seed = 7


func _physics_process(dt: float) -> void:
	var f := Vector2(focus.x, focus.z)
	for b in boats.duplicate():
		b.pos = Vector2(b.boat.global_position.x, b.boat.global_position.z)
		var far: bool = b.pos.distance_to(f) > radius + 140.0
		if far and not b.driver and not b.kept:
			b.boat.queue_free()
			boats.erase(b)
		elif b.boat.global_position.y < -30.0:   # its chunk went: it fell
			b.boat.queue_free()
			boats.erase(b)
		else:
			# Far ones hold still (no ground may be under them yet).
			b.boat.freeze = b.pos.distance_to(f) > 180.0 and not b.driver
	_wait -= dt
	if boats.size() < target and _wait <= 0.0:
		_wait = 0.25
		_try_spawn(f)


# The canal outlines of the loaded chunks that reach within `radius` of f.
func _canals(f: Vector2) -> void:
	_water.clear()
	_water_at = f
	var near := Rect2(f - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	for t in streamer.tiles.values():
		if t.state != "ready":
			continue
		for rings in t.result.water:
			var box := Rect2(rings[0][0], Vector2.ZERO)
			for q in rings[0]:
				box = box.expand(q)
			if box.intersects(near):
				_water.append([rings[0], box.intersection(near)])


func _try_spawn(f: Vector2) -> void:
	if f.distance_to(_water_at) > 40.0 or _water.is_empty() and Engine.get_physics_frames() % 120 == 0:
		_canals(f)
	if _water.is_empty():
		return
	var w: Array = _water[_rng.randi() % _water.size()]
	var box: Rect2 = w[1]
	var p := box.position + Vector2(_rng.randf() * box.size.x, _rng.randf() * box.size.y)
	if p.distance_to(f) < 12.0 or p.distance_to(f) > radius:
		return
	if streamer.water_at(Vector3(p.x, 0, p.y)) != 1:
		return
	var along := _along(p, 12.0)
	if along == Vector2.ZERO:
		return                        # not a canal: a basin corner or a sliver
	# Moor close to the nearer quay.
	var across := Vector2(-along.y, along.x)
	var wl := _run(p, across, 20.0)
	var wr := _run(p, -across, 20.0)
	if wl + wr < 6.0:
		return                        # too narrow to leave a boat in
	var to := across * (wl - 1.5) if wl < wr else -across * (wr - 1.5)
	p = _clear(p + to, along, -to.normalized())
	if p == Vector2.INF:
		return
	for b in boats:
		if b.pos.distance_to(p) < 9.0:
			return
	var yaw := atan2(-along.x, -along.y) + (PI if _rng.randf() < 0.5 else 0.0)
	add(p, yaw)


## Moor a boat for good at the quay of the water at p on the side facing
## `toward` (the Damrak by the start, say), bow to the open water. {} if p is
## not open water yet.
func moor(p: Vector2, toward: Vector2) -> Dictionary:
	if streamer.water_at(Vector3(p.x, 0, p.y)) != 1:
		return {}
	var along := _along(p, 120.0)     # a basin is wide: look far to find which way it runs
	if along == Vector2.ZERO:
		return {}
	var across := Vector2(-along.y, along.x)
	if across.dot(toward - p) < 0.0:
		across = -across
	if _run(p, along, 200.0) < _run(p, -along, 200.0):
		along = -along                # bow out, not into the end of the basin
	var to_quay := _run(p, across, 120.0)
	p = _clear(p + across * maxf(0.0, to_quay - 1.6), along, -across)
	if p == Vector2.INF:
		return {}
	var yaw := atan2(-along.x, -along.y)
	var b := add(p, yaw, Color(COLORS[0]))
	b.kept = true
	return b


# p, or p moved out along `away` until the hull and half a metre round it lie
# on open water (never in a quay wall: the physics would fling it out). INF if
# it does not fit.
func _clear(p: Vector2, along: Vector2, away: Vector2) -> Vector2:
	var across := Vector2(-along.y, along.x)
	for k in 12:
		var q := p + away * 0.5 * k
		var ok := true
		for a in [-3.2, -1.6, 0.0, 1.6, 3.2]:
			for c in [-1.5, 1.5]:
				var t: Vector2 = q + along * a + across * c
				if streamer.water_at(Vector3(t.x, 0, t.y)) != 1:
					ok = false
		if ok:
			return q
	return Vector2.INF


# The direction of the longest open water through p (the canal's), or zero if
# it runs less than 14 m.
func _along(p: Vector2, reach: float) -> Vector2:
	var best := -1.0
	var along := Vector2.ZERO
	for k in 12:
		var a := k * PI / 12.0
		var dir := Vector2(cos(a), sin(a))
		var run := _run(p, dir, reach) + _run(p, -dir, reach)
		if run > best:
			best = run; along = dir
	return along if best >= 14.0 else Vector2.ZERO


# How far open water runs from p along dir (up to max).
func _run(p: Vector2, dir: Vector2, max_d: float) -> float:
	var d := 0.0
	while d < max_d:
		if streamer.water_at(Vector3(p.x + dir.x * (d + 1.0), 0, p.y + dir.y * (d + 1.0))) != 1:
			return d
		d += 1.0
	return max_d


func add(p: Vector2, yaw: float, col := Color.TRANSPARENT) -> Dictionary:
	var boat: RigidBody3D = Boat.new()
	var model: Node3D = _scene.instantiate()
	var hull := model.find_children("*", "MeshInstance3D", true, false)
	if col.a == 0.0:
		col = Color(COLORS[_rng.randi() % COLORS.size()])
	if col != Color(COLORS[0]):
		for mi: MeshInstance3D in hull:   # repaint the topsides
			for s in mi.mesh.get_surface_count():
				var m := mi.mesh.surface_get_material(s)
				if m is StandardMaterial3D and m.resource_name == "paint":
					var m2: StandardMaterial3D = m.duplicate()
					m2.albedo_color = col
					mi.set_surface_override_material(s, m2)
	boat.add_child(model)
	add_child(boat)
	boat.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, Boat.WATER_Y, p.y))
	var b := {"boat": boat, "pos": p, "driver": false, "kept": false, "kind": "boat"}
	boats.append(b)
	return b


## The boat nearest p within `within` metres of its hull, or {}.
func nearest(p: Vector2, within: float) -> Dictionary:
	var best := {}
	var bd := within
	for b in boats:
		var boat: Node3D = b.boat
		var f := Vector2(-boat.global_transform.basis.z.x, -boat.global_transform.basis.z.z).normalized() * (Boat.LENGTH / 2 - 0.9)
		var d := Geometry2D.get_closest_point_to_segment(p, b.pos - f, b.pos + f).distance_to(p) - Boat.BEAM / 2
		if d < bd:
			bd = d; best = b
	return best


func clear() -> void:
	for b in boats:
		b.boat.queue_free()
	boats.clear()
