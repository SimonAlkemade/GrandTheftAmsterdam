extends Camera3D
## A map-app camera: it orbits a point on the ground.
##   Left-drag or WASD/arrows: pan     Right-drag or Q/E, R/F: rotate and tilt
##   Wheel, +/-: zoom                  Trackpad (Mac): two-finger scroll pans,
##                                      pinch zooms, Shift-scroll rotates.

var target := Vector3.ZERO
var yaw := 0.0                 # 0 looks north
var pitch := deg_to_rad(52.0)  # from straight down
var dist := 1400.0
var active := true
var _drag := 0                 # 1 pan, 2 rotate
var _goal := {}


func _ready() -> void:
	near = 1.0
	far = 80000.0
	fov = 45.0


func fly_to(p: Vector3, d := -1.0, seconds := 1.2) -> void:
	_goal = {"from_t": target, "to_t": p, "from_d": dist, "to_d": d if d > 0 else dist, "t": 0.0, "dur": seconds}


func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT: _drag = 1 if mb.pressed else 0
		elif mb.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]: _drag = 2 if mb.pressed else 0
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP: _zoom(0.85)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN: _zoom(1.18)
	elif event is InputEventMouseMotion and _drag != 0:
		var mm := event as InputEventMouseMotion
		if _drag == 1 and not mm.ctrl_pressed:
			_pan(-mm.relative)
		else:
			_rotate(mm.relative)
	elif event is InputEventPanGesture:         # macOS trackpad
		var pg := event as InputEventPanGesture
		if pg.shift_pressed: _rotate(pg.delta * 8.0)
		else: _pan(-pg.delta * 12.0)
	elif event is InputEventMagnifyGesture:
		_zoom(1.0 / (event as InputEventMagnifyGesture).factor)


func _pan(px: Vector2) -> void:
	var scale := dist * 0.0012
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	target += (right * px.x - fwd * px.y) * scale
	_goal = {}


func _rotate(px: Vector2) -> void:
	yaw -= px.x * 0.005
	pitch = clampf(pitch - px.y * 0.004, 0.02, deg_to_rad(84))


func _zoom(k: float) -> void:
	dist = clampf(dist * k, 25.0, 26000.0)


func _process(delta: float) -> void:
	if not active:
		return
	var s := 600.0 * delta * maxf(0.3, dist / 1000.0)
	var mv := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	if mv != Vector2.ZERO:
		_pan(Vector2(mv.x, mv.y) * s / maxf(0.0012 * dist, 0.01) * 0.001 * dist)
	if Input.is_physical_key_pressed(KEY_Q): yaw += delta * 1.2
	if Input.is_physical_key_pressed(KEY_E): yaw -= delta * 1.2
	if Input.is_physical_key_pressed(KEY_R): pitch = clampf(pitch + delta, 0.02, deg_to_rad(84))
	if Input.is_physical_key_pressed(KEY_F): pitch = clampf(pitch - delta, 0.02, deg_to_rad(84))
	if Input.is_physical_key_pressed(KEY_EQUAL) or Input.is_physical_key_pressed(KEY_KP_ADD): _zoom(1.0 - delta * 1.5)
	if Input.is_physical_key_pressed(KEY_MINUS) or Input.is_physical_key_pressed(KEY_KP_SUBTRACT): _zoom(1.0 + delta * 1.5)
	if not _goal.is_empty():
		_goal.t += delta / _goal.dur
		var k := smoothstep(0.0, 1.0, minf(_goal.t, 1.0))
		target = _goal.from_t.lerp(_goal.to_t, k)
		dist = lerpf(_goal.from_d, _goal.to_d, k)
		if _goal.t >= 1.0: _goal = {}
	var offset := Vector3(sin(yaw) * sin(pitch), cos(pitch), cos(yaw) * sin(pitch)) * dist
	position = target + offset
	look_at(target, Vector3.UP if pitch > 0.03 else Vector3(-sin(yaw), 0, -cos(yaw)))
