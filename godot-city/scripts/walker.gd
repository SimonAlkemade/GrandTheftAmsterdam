extends CharacterBody3D
## On foot. WASD or the arrow keys to walk (relative to the camera), Shift to run, Space to
## jump, mouse to look (captured), wheel to zoom the camera. Walls stop you;
## canals have no floor, so you fall in and swim, and climb out at a quay.
## Pedestrians walk the streets around you.

const Human := preload("res://scripts/human.gd")
const SWIM_Y := -1.2
const BRIDGE_Y := 0.3

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
var _rng := RandomNumberGenerator.new()


func setup(s, camera: Camera3D) -> void:
	streamer = s
	cam = camera
	var shape := CapsuleShape3D.new(); shape.radius = 0.32; shape.height = 1.75
	var cs := CollisionShape3D.new(); cs.shape = shape; cs.position.y = 0.9
	add_child(cs)
	body = Human.new()
	body.build(Color("f2efe8"), Color("1d1f24"), Color("d9a07a"), Color("2b1d14"), Color("f5f5f5"), Color("3d5a80"))
	add_child(body)
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
	if event is InputEventMouseMotion and (Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or event.button_mask & MOUSE_BUTTON_MASK_RIGHT):
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
		2: return BRIDGE_Y
		1: return null
	return 0.0


func _free(p: Vector3) -> bool:
	if streamer.water_at(p) == 1:
		return false
	var q := PhysicsRayQueryParameters3D.create(p + Vector3(0, 1, 0), p + Vector3(0, 1, 0) + Vector3(0.01, 0, 0))
	return get_world_3d().direct_space_state.intersect_ray(q).is_empty()


func _physics_process(delta: float) -> void:
	if not active:
		return
	var key := func(k: Key, alt: Key) -> float:
		return 1.0 if Input.is_physical_key_pressed(k) or Input.is_physical_key_pressed(alt) else 0.0
	var ix: float = key.call(KEY_D, KEY_RIGHT) - key.call(KEY_A, KEY_LEFT)
	var iz: float = key.call(KEY_S, KEY_DOWN) - key.call(KEY_W, KEY_UP)
	var inp := Vector2(ix, iz).limit_length(1.0)
	var run := Input.is_physical_key_pressed(KEY_SHIFT)
	var swimming := state == "swim"
	var top := 1.5 if swimming else (6.2 if run else 1.7)
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
			if speed > 0.4 and _ground(ahead) != null and _free(ahead):
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
	_peds(delta)
	_camera(delta)


func _camera(delta: float) -> void:
	var head := global_position + Vector3(0, 1.55, 0)
	if state == "swim": head.y = SWIM_Y + 2.3
	var dir := Vector3(sin(cam_yaw) * cos(cam_pitch), sin(cam_pitch), cos(cam_yaw) * cos(cam_pitch))
	var d := cam_dist
	var q := PhysicsRayQueryParameters3D.create(head, head + dir * cam_dist)
	q.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		d = maxf(0.8, head.distance_to(hit.position) - 0.3)
	var want := head + dir * d
	want.y = maxf(want.y, 0.3)
	cam.global_position = cam.global_position.lerp(want, 1.0 - exp(-delta * 14.0))
	cam.fov = lerpf(cam.fov, 74.0 if state == "run" else 68.0, 1.0 - exp(-delta * 4.0))
	cam.look_at(head - Vector3(0, 0.2, 0), Vector3.UP)


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
