extends CharacterBody3D
## On foot. WASD or the arrow keys to walk (relative to the camera), Shift to run, Space to
## jump, mouse to look (captured), wheel to zoom the camera. Walls stop you;
## canals have no floor, so you fall in and swim, and climb out at a quay.
## Pedestrians walk the streets around you.
## E next to a car takes the wheel (W drives, S brakes and reverses, A/D
## steer, Space is the handbrake: see VehiclePhysics); E
## next to a bike (parked, or a cyclist's) rides it, Shift to pedal hard; E
## next to a bus or tram rides it along its route; E next to a moored boat
## (from the quay, or swimming) takes the helm; E again gets you out.

const Human := preload("res://scripts/human.gd")
const Models := preload("res://scripts/vehicle_models.gd")
const VPhys := preload("res://scripts/vehicle_physics.gd")
const TileBuilder := preload("res://scripts/tile_builder.gd")
const SWIM_Y := -2.65          # your feet while swimming: the canal is 1.4 m below the street
const WATER_Y := -1.4          # the canal surface (TileBuilder.WATER_Y)
const ENTER_RANGE := 3.0
const BOARD_RANGE := 4.0       # a boat lies below the quay: a little more reach
# Per vehicle: camera height above the road, camera distance, half width.
const VEHICLE_CAM := {"car": [1.7, 7.5, 0.9], "bus": [3.2, 15.0, 1.3], "tram": [3.4, 19.0, 1.2], "bike": [1.5, 4.8, 0.4], "canta": [1.9, 6.0, 0.6], "boat": [2.0, 8.5, 1.0]}
# What you can drive (and how) is in VehiclePhysics.SPEC.
const DRIVE := VPhys.SPEC
const LOOK := [Color("f2efe8"), Color("1d1f24"), Color("d9a07a"), Color("2b1d14"), Color("f5f5f5"), Color("3d5a80")]

var streamer
var cam: Camera3D
var active := false
var body: Node3D
var state := "idle"
var speed := 0.0
var heading := 0.0
var vy := 0.0
var grounded := true
var climb_t := 0.0
var cam_yaw := 0.0
var cam_pitch := 0.3
var cam_dist := 5.5
var peds: Array = []
var traffic
var boats                      # the moored sloepen (Boats)
var vehicle = null             # the traffic vehicle you are in, or null
var prompt := ""               # what E does right now, for the HUD
var car_yaw := 0.0
var car_speed := 0.0
var _mouse_idle := 10.0
var _rack_bike := {}
var carrying := false          # a parcel (the courier mission)
var _parcel: MeshInstance3D
var _rng := RandomNumberGenerator.new()


func setup(s, camera: Camera3D) -> void:
	streamer = s
	cam = camera
	var shape := CapsuleShape3D.new(); shape.radius = 0.32; shape.height = 1.75
	var cs := CollisionShape3D.new(); cs.shape = shape; cs.position.y = 0.9
	add_child(cs)
	# On your own layer: you bump into buildings, but the vehicle you sit in
	# (whose wheels and box would otherwise meet you inside it) never sees you.
	collision_layer = 16
	collision_mask = VPhys.WALL_LAYER
	body = Human.new()
	body.callv("build", LOOK.duplicate())   # callv garbles a read-only (const) array
	add_child(body)
	_parcel = MeshInstance3D.new()
	var box := BoxMesh.new(); box.size = Vector3(0.42, 0.3, 0.34)
	var card := StandardMaterial3D.new(); card.albedo_color = Color("b8874f"); card.roughness = 0.9
	_parcel.mesh = box; _parcel.material_override = card
	_parcel.position = Vector3(0, 1.08, -0.34)
	_parcel.visible = false
	body.add_child(_parcel)
	visible = false


func enter(at: Vector3, yaw: float) -> void:
	global_position = Vector3(at.x, 0.0, at.z)
	heading = yaw; cam_yaw = yaw; cam_pitch = 0.3; cam_dist = 5.5
	state = "idle"; speed = 0.0; vy = 0.0; grounded = true
	visible = true
	active = true
	cam.near = 0.15
	cam.fov = 68.0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for i in 24:
		var p := {"h": Human.new(), "pos": Vector3.ZERO, "heading": 0.0, "speed": 1.1 + _rng.randf() * 0.45, "turn": 0.0, "stag": 0.0}
		p.h.random_look(_rng)
		get_parent().add_child(p.h)
		_place(p, true)
		peds.append(p)


func leave() -> void:
	if vehicle != null:
		_get_out()
	active = false
	visible = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	cam.near = 1.0
	cam.fov = 45.0
	for p in peds:
		p.h.queue_free()
	peds.clear()


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	# Look with the captured mouse, or by dragging when it is free (trackpads).
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		if vehicle != null:
			_get_out()
		else:
			_get_in()
		return
	if event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
		_mouse_idle = 0.0
		cam_yaw -= event.relative.x * 0.0042
		cam_pitch = clampf(cam_pitch + event.relative.y * 0.0035, -0.25, 1.25)
	elif event is InputEventPanGesture:
		cam_yaw -= event.delta.x * 0.03
		cam_pitch = clampf(cam_pitch + event.delta.y * 0.02, -0.25, 1.25)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: cam_dist = maxf(2.2, cam_dist * 0.89)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: cam_dist = minf(14.0, cam_dist * 1.12)
		else: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _ground(p: Vector3):
	match streamer.water_at(p):
		2:
			var y: float = streamer.bridge_y(p)
			return null if is_nan(y) else y
		1: return null
	return 0.0


func _free(p: Vector3) -> bool:
	if streamer.water_at(p) == 1:
		return false
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1, 0), p + Vector3(0, 1, 0) + Vector3(0.01, 0, 0), 1)
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	if not active:
		return
	_mouse_idle += delta
	if vehicle != null:
		if vehicle.kind == "boat":
			_steer_boat(delta)
		elif DRIVE.has(vehicle.kind):
			_drive(delta)
		else:
			_ride()
		prompt = "E  get out"
		_peds(delta)
		_camera(delta)
		return
	var here := Vector2(global_position.x, global_position.z)
	var near: Dictionary = traffic.nearest(here, ENTER_RANGE) if traffic else {}
	prompt = "" if near.is_empty() else {"car": "E  drive this car", "bus": "E  ride the bus", "tram": "E  ride the tram", "bike": "E  ride this bike", "canta": "E  drive this Canta"}[near.kind]
	if prompt == "" and boats and not boats.nearest(here, BOARD_RANGE).is_empty():
		prompt = "E  take the boat"
	if prompt == "" and Engine.get_physics_frames() % 6 == 0:
		_rack_bike = streamer.parked_bike(here, 1.6)
	if prompt == "" and not _rack_bike.is_empty() and _rack_bike.at.distance_to(here) < 1.8:
		prompt = "E  take this bike"
	var key := func(k: Key, alt: Key) -> float:
		return 1.0 if Input.is_physical_key_pressed(k) or Input.is_physical_key_pressed(alt) else 0.0
	var ix: float = key.call(KEY_D, KEY_RIGHT) - key.call(KEY_A, KEY_LEFT)
	var iz: float = key.call(KEY_S, KEY_DOWN) - key.call(KEY_W, KEY_UP)
	var inp := Vector2(ix, iz).limit_length(1.0)
	var run := Input.is_physical_key_pressed(KEY_SHIFT)
	var swimming := state == "swim"
	var top := (2.4 if run else 1.4) if swimming else (6.2 if run else 1.7)   # Shift: a fast crawl
	var move := Vector2(inp.x * cos(cam_yaw) + inp.y * sin(cam_yaw), -inp.x * sin(cam_yaw) + inp.y * cos(cam_yaw))
	var want := inp.length() * top
	speed += (want - speed) * minf(1.0, delta * (6.0 if want > speed else 9.0))
	if move.length() > 0.05:
		var target := atan2(-move.x, -move.y)
		heading += wrapf(target - heading, -PI, PI) * minf(1.0, delta * 10.0)
	var fwd := Vector3(-sin(heading), 0, -cos(heading))
	if state == "climb":
		climb_t += delta
		global_position.y = lerpf(SWIM_Y, 0.0, minf(1.0, climb_t / 0.6))
		if climb_t > 0.6:
			global_position += fwd * 0.8
			global_position.y = 0.0
			state = "idle"; grounded = true
	else:
		velocity = fwd * speed
		velocity.y = 0.0
		var y := global_position.y
		move_and_slide()
		global_position.y = y
		# Pushing against a wall: slow to what you actually make, so you don't run on the spot.
		var real := get_real_velocity(); real.y = 0.0
		speed = minf(speed, real.length() + 0.25)
		var g = _ground(global_position)
		if swimming:
			global_position.y = SWIM_Y
			var ahead := global_position + fwd * 0.9
			if speed > 0.4 and streamer.water_at(ahead) == 0 and _free(ahead):   # a quay, not the bridge overhead
				state = "climb"; climb_t = 0.0
		else:
			if Input.is_physical_key_pressed(KEY_SPACE) and grounded:
				vy = 5.2; grounded = false
			vy -= 15.0 * delta
			global_position.y += vy * delta
			var floor_y: float = SWIM_Y if g == null else g
			if global_position.y <= floor_y:
				if g == null:
					state = "swim"; global_position.y = SWIM_Y; vy = 0.0; speed *= 0.4
				else:
					global_position.y = floor_y; vy = 0.0; grounded = true
			elif global_position.y > floor_y + 0.05:
				grounded = false
		if state != "swim":
			state = ("jump" if vy > 0.0 else "fall") if not grounded else ("run" if speed > 3.2 else ("walk" if speed > 0.6 else "idle"))
	body.rotation.y = heading
	body.position.y = (body.rotation.x / 1.25 * 0.9) if state == "swim" else 0.0
	body.animate(delta, state, speed)
	_parcel.visible = carrying and state != "swim" and state != "climb"
	if _parcel.visible:                  # both arms round the parcel
		for arm in [[body.sh_l, body.el_l], [body.sh_r, body.el_r]]:
			arm[0].rotation.x = 0.55
			arm[1].rotation.x = 1.25
		body.sh_l.rotation.z = 0.3; body.sh_r.rotation.z = -0.3   # hands in towards the middle
	else:
		body.sh_l.rotation.z = 0.08; body.sh_r.rotation.z = -0.08
	_peds(delta)
	_camera(delta)


func _camera(delta: float) -> void:
	var head := global_position + Vector3(0, 1.55, 0)
	if state == "swim": head.y = SWIM_Y + 2.3
	var reach := cam_dist
	if vehicle != null:
		var vc: Array = VEHICLE_CAM[vehicle.kind]
		head = Vector3(global_position.x, global_position.y + vc[0], global_position.z)
		reach = vc[1] * cam_dist / 5.5
		# Swing in behind the vehicle while it moves and you leave the mouse alone.
		var moving: bool = absf(car_speed) > 2.0 if vehicle.has("driver") and vehicle.driver else vehicle.speed > 1.0
		if moving and _mouse_idle > 1.5:
			cam_yaw = lerp_angle(cam_yaw, heading, 1.0 - exp(-delta * 2.0))
			cam_pitch = lerpf(cam_pitch, 0.28, 1.0 - exp(-delta * 1.0))
	var dir := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch))
	var d := reach
	# Buildings only (not the ground, not your own car); on the water also the
	# quay walls and bridges, so the camera ducks under a bridge with you:
	# under a deck (over you, or where the camera would be) it drops below the
	# deck's underside and looks along the canal, level.
	var afloat: bool = state == "swim" or (vehicle != null and vehicle.kind == "boat")
	if afloat:
		var under := INF
		for at in [head, head + Vector3(dir.x, 0, dir.z) * reach * 0.6]:
			var deck: float = streamer.bridge_y(at)
			if not is_nan(deck):
				under = minf(under, deck - TileBuilder.BRIDGE_DEPTH)
		if under < INF:
			head.y = minf(head.y, under - 0.65)
			dir = Vector3(dir.x, minf(dir.y, 0.03), dir.z).normalized()
	var q := PhysicsRayQueryParameters3D.create(head, head + dir * reach, 1 | (VPhys.GROUND_LAYER if afloat else 0))
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		d = maxf(0.8, head.distance_to(hit.position) - 0.3)
	var want := head + dir * d
	want.y = maxf(want.y, WATER_Y + 0.5 if afloat else 0.3)
	cam.global_position = cam.global_position.lerp(want, 1.0 - exp(-delta * 14.0))
	var fast: bool = state == "run" or (vehicle != null and absf(car_speed) > 11.0)
	cam.fov = lerpf(cam.fov, 74.0 if fast else 68.0, 1.0 - exp(-delta * 4.0))
	cam.look_at(head - Vector3(0, 0.2, 0), Vector3.UP)


# ---- vehicles ----------------------------------------------------------------------

func _get_in() -> void:
	var here := Vector2(global_position.x, global_position.z)
	var v: Dictionary = traffic.nearest(here, ENTER_RANGE)
	if (v.is_empty() or state == "swim") and boats:
		var bt: Dictionary = boats.nearest(here, BOARD_RANGE)
		if not bt.is_empty():
			_board(bt)
			return
	if v.is_empty():
		var b: Dictionary = streamer.parked_bike(here, 1.8)
		if b.is_empty():
			return
		streamer.take_bike(b)
		v = traffic.add_bike(b.at, b.yaw, b.color)
		_rack_bike = {}
	vehicle = v
	body.visible = false
	speed = 0.0
	state = "idle"
	if DRIVE.has(v.kind):
		v.driver = true
		v.parked = false
		if not v.has("body"):
			_physical(v, v.kind == "bike")
		var b: VehicleBody3D = v.body
		b.sleeping = false
		global_position = Vector3(b.global_position.x, 0.0, b.global_position.z)
		heading = VPhys.heading(b)
		if v.kind == "bike":             # you, on the saddle
			v.rig.add_rider(null, LOOK)
			v.rig.set_parked(false)
	else:
		v.rider = true
		_ride()
	_mouse_idle = 10.0


# From here on a traffic vehicle is a real one: sprung wheels on the street,
# keeping its speed if `moving`. It leaves its route for good.
func _physical(v: Dictionary, moving: bool) -> VehicleBody3D:
	var visual: Node3D = v.parts[0][0]
	var xf := Transform3D(Basis(Vector3.UP, visual.rotation.y), Vector3(visual.position.x, _ground_y(visual.position) + 0.05, visual.position.z))
	var b: VehicleBody3D = VPhys.make(v.kind, visual, xf)
	v.node.add_child(b)
	if moving:
		b.linear_velocity = Vector3(-sin(visual.rotation.y), 0, -cos(visual.rotation.y)) * float(v.speed)
	v.body = b
	v.rig = visual
	v.parts[0][0] = b
	return b


# GTA rules: a car or Canta you are about to hit stops being scenery on rails
# and becomes a real car just before you hit it, so the crash pushes, spins or
# shunts it. (Buses and trams stay on their rails, like the walls they are.)
func _knock_traffic(b: VehicleBody3D) -> void:
	var me := Vector2(b.global_position.x, b.global_position.z)
	var mv := Vector2(b.linear_velocity.x, b.linear_velocity.z)
	if mv.length() < 2.0:
		return
	for v in traffic.vehicles:
		if v == vehicle or v.has("body") or not (v.kind == "car" or v.kind == "canta"):
			continue
		var n: Node3D = v.parts[0][0]
		var at := Vector2(n.position.x, n.position.z)
		var gap := at.distance_to(me)
		if gap > 7.5:
			continue
		var tv := Vector2(-sin(n.rotation.y), -cos(n.rotation.y)) * float(v.speed)
		var closing := (mv - tv).dot((at - me) / maxf(gap, 0.01))
		if closing > 1.5 and gap < 3.2 + closing * 0.12:
			var hit := _physical(v, true)
			for w in hit.get_children():   # its driver stands on the brake: it skids to a stop
				if w is VehicleWheel3D: (w as VehicleWheel3D).brake = 5.0
			v.parked = true                # off its route: it goes where the crash sends it
			v.knocked = true


func _get_out() -> void:
	var v: Dictionary = vehicle
	vehicle = null
	body.visible = true
	if v.kind == "boat":
		_leave_boat(v)
		return
	if DRIVE.has(v.kind):
		v.driver = false
		v.parked = true                  # it stays where you left it, handbrake on
		v.speed = 0.0
		car_speed = 0.0
		VPhys.park(v.body)
		if v.kind == "bike":
			v.rig.set_parked(true)
			v.rig.rotation.z = 0.0
	else:
		v.rider = false
	# Step out on the kerb side, or the other side if that is a wall or a canal.
	var c := Vector2(global_position.x, global_position.z)
	var f := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(-f.y, f.x)
	var half: float = VEHICLE_CAM[v.kind][2] + 1.0
	var spot := c
	for side in [right, -right, f * 3.0, -f * 3.0]:
		var p: Vector2 = c + side * half
		var p3 := Vector3(p.x, 0.0, p.y)
		if streamer.water_at(p3) != 1 and _free(p3) and not traffic.blocked(p, {}):
			spot = p
			break
	global_position = Vector3(spot.x, 0.0, spot.y)
	vy = 0.0; grounded = true; state = "idle"; speed = 0.0


# Driving is physics: the inputs go to the engine, brakes and steering of the
# VehicleBody3D, and you (and the camera) go where it goes.
func _drive(dt: float) -> void:
	var key := func(k: Key, alt: Key) -> float:
		return 1.0 if Input.is_physical_key_pressed(k) or Input.is_physical_key_pressed(alt) else 0.0
	var throttle: float = key.call(KEY_W, KEY_UP) - key.call(KEY_S, KEY_DOWN)
	var steer: float = key.call(KEY_A, KEY_LEFT) - key.call(KEY_D, KEY_RIGHT)
	var b: VehicleBody3D = vehicle.body
	var spec: Dictionary = DRIVE[vehicle.kind]
	var p := b.global_position
	var sunk := p.y < WATER_Y + 0.2       # it went into a canal: no more driving
	if vehicle.kind != "bike":
		_knock_traffic(b)
	car_speed = VPhys.drive(b, vehicle.kind, 0.0 if sunk else throttle, steer, Input.is_physical_key_pressed(KEY_SPACE),
		Input.is_physical_key_pressed(KEY_SHIFT), dt)
	b.linear_damp = 2.5 if sunk else 0.0
	heading = VPhys.heading(b)
	var f := Vector2(-sin(heading), -cos(heading))
	vehicle.pos = Vector2(p.x, p.z) + f * spec.box.z * 0.5   # the front, for the traffic behind you
	vehicle.speed = absf(car_speed)
	global_position = Vector3(p.x, p.y, p.z)
	speed = absf(car_speed)
	if vehicle.kind == "bike":
		var rig: Node3D = vehicle.rig
		rig.pedal(dt, car_speed)
		# The lean that balances the turn: tan(lean) = v * yaw rate / g.
		var lean := clampf(atan(car_speed * b.angular_velocity.y / 9.81), -0.6, 0.6)
		rig.rotation.z = lerpf(rig.rotation.z, lean, 1.0 - exp(-dt * 8.0))


# ---- the boat ---------------------------------------------------------------------

func _board(b: Dictionary) -> void:
	vehicle = b
	b.driver = true
	b.kept = true                    # where you leave it, it stays
	state = "idle"; speed = 0.0; vy = 0.0
	_steer_boat(0.0)
	_mouse_idle = 10.0


# At the helm: the keys go to the motor and the outboard, and you stand at the
# console while the boat goes where the water and the physics take it.
func _steer_boat(dt: float) -> void:
	var key := func(k: Key, alt: Key) -> float:
		return 1.0 if Input.is_physical_key_pressed(k) or Input.is_physical_key_pressed(alt) else 0.0
	var boat: RigidBody3D = vehicle.boat
	boat.throttle = key.call(KEY_W, KEY_UP) - key.call(KEY_S, KEY_DOWN)
	boat.steer = key.call(KEY_A, KEY_LEFT) - key.call(KEY_D, KEY_RIGHT)
	boat.boost = Input.is_physical_key_pressed(KEY_SHIFT)
	car_speed = boat.speed()
	speed = absf(car_speed)
	heading = boat.heading()
	vehicle.pos = Vector2(boat.global_position.x, boat.global_position.z)
	# On the floorboards behind the wheel, hands on it.
	global_position = boat.global_transform * Vector3(0.3, 0.1, 1.5)
	body.rotation = Vector3(0, heading, 0)
	body.position.y = 0.0
	body.animate(maxf(dt, 0.0), "idle", 0.0)
	for arm in [[body.sh_l, body.el_l], [body.sh_r, body.el_r]]:
		arm[0].rotation.x = 0.75
		arm[1].rotation.x = 0.7
	body.sh_l.rotation.z = 0.25; body.sh_r.rotation.z = -0.25
	_parcel.visible = false


# Step onto the quay if there is one within reach, else into the canal.
func _leave_boat(v: Dictionary) -> void:
	var boat: RigidBody3D = v.boat
	v.driver = false
	boat.throttle = 0.0; boat.steer = 0.0; boat.boost = false
	car_speed = 0.0
	var c := Vector2(boat.global_position.x, boat.global_position.z)
	var f := Vector2(-sin(heading), -cos(heading))
	var right := Vector2(-f.y, f.x)
	for d in [1.8, 2.4, 3.0, 3.6]:
		for side in [right, -right, f * 1.8, -f * 1.6]:
			var p: Vector2 = c + side * d
			var p3 := Vector3(p.x, 0.0, p.y)
			if streamer.water_at(p3) == 0 and _free(p3) and not traffic.blocked(p, {}):   # the quay, not a bridge overhead
				global_position = Vector3(p.x, 0.0, p.y)
				vy = 0.0; grounded = true; state = "idle"; speed = 0.0
				return
	var p: Vector2 = c + right * 1.9
	global_position = Vector3(p.x, SWIM_Y, p.y)
	vy = 0.0; grounded = false; state = "swim"; speed = 0.0


# The height of what vehicles drive on (street, bridge deck) under p.
func _ground_y(p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, 6.0, p.z), Vector3(p.x, -4.0, p.z), VPhys.GROUND_LAYER)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if not hit.is_empty() else 0.09


# As a passenger: sit in the middle of the bus or tram as it drives its route.
func _ride() -> void:
	if not traffic.vehicles.has(vehicle):
		var last: Vector3 = global_position
		vehicle = null                  # it left the map: step off where it was
		body.visible = true
		global_position = Vector3(last.x, 0.0, last.z)
		return
	var mid: Array = vehicle.parts[vehicle.parts.size() / 2]
	var n: Node3D = mid[0]
	global_position = Vector3(n.position.x, 0.0, n.position.z)
	heading = n.rotation.y
	speed = vehicle.speed


# ---- pedestrians ------------------------------------------------------------------

func _place(p: Dictionary, near: bool) -> void:
	for k in 30:
		var ang := _rng.randf() * TAU
		var d := (6.0 + _rng.randf() * 50.0) if near else (45.0 + _rng.randf() * 30.0)
		var at := global_position + Vector3(cos(ang) * d, 0, sin(ang) * d)
		at.y = 0.0
		if _free(at) and _free(at + Vector3(0.6, 0, 0)):
			p.pos = at; p.heading = _rng.randf() * TAU
			return


func _peds(delta: float) -> void:
	for p in peds:
		if p.pos.distance_to(global_position) > 85.0:
			_place(p, false)
		var h: Node3D = p.h
		if p.stag > 0.0:
			p.stag -= delta
			h.animate(delta, "idle", 0.0)
			h.spine.rotation.x = -0.4
		else:
			p.turn -= delta
			if p.turn <= 0.0:
				p.heading += _rng.randf_range(-0.6, 0.6); p.turn = _rng.randf_range(2.0, 6.0)
			var off: Vector3 = p.pos - global_position
			if off.length() < 2.2:          # step aside for the player
				p.heading += wrapf(atan2(-off.x, -off.z) + PI - p.heading, -PI, PI) * delta * 3.0
			var f := Vector3(-sin(p.heading), 0, -cos(p.heading))
			if _free(p.pos + f * 1.2):
				p.pos += f * p.speed * delta
			else:
				for t in [0.6, -0.6, 1.3, -1.3, 2.2, -2.2, PI]:
					var hh: float = p.heading + t
					if _free(p.pos + Vector3(-sin(hh), 0, -cos(hh)) * 1.2):
						p.heading = hh; break
			h.animate(delta, "walk", p.speed)
		var off2: Vector3 = p.pos - global_position
		off2.y = 0.0
		if off2.length() < 0.65 and off2.length() > 0.01:
			p.pos += off2.normalized() * (0.65 - off2.length())
			if speed > 3.5 and p.stag <= 0.0: p.stag = 0.9
		var gy = _ground(p.pos)
		h.position = Vector3(p.pos.x, gy if gy != null else 0.0, p.pos.z)
		h.rotation.y = p.heading
