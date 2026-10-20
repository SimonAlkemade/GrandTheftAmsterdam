extends Camera3D
## Fly camera: hold the right mouse button to look, WASD to move, Q/E down/up,
## Shift to sprint, mouse wheel to change speed. In walk mode the camera keeps
## eye height above whatever is below it and slides along walls.

signal speed_changed(speed: float)

const EYE_HEIGHT := 1.7
const LOOK_SENSITIVITY := 0.0025

var speed := 20.0
var walk := false
var yaw := 0.0
var pitch := 0.0
var _tween: Tween


func _ready() -> void:
	near = 0.1
	far = 5000.0
	fov = 60.0


func look_from(eye: Vector3, target: Vector3) -> void:
	global_position = eye
	var dir := (target - eye).normalized()
	yaw = atan2(-dir.x, -dir.z)
	pitch = asin(clampf(dir.y, -1.0, 1.0))
	_apply_rotation()


func fly_to(eye: Vector3, target: Vector3, seconds := 0.8) -> void:
	if _tween:
		_tween.kill()
	var start := global_position
	var start_yaw := yaw
	var start_pitch := pitch
	look_from(eye, target)
	var end_yaw := yaw
	var end_pitch := pitch
	# Take the short way round.
	end_yaw = start_yaw + wrapf(end_yaw - start_yaw, -PI, PI)
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_method(func(t: float) -> void:
		global_position = start.lerp(eye, t)
		yaw = lerpf(start_yaw, end_yaw, t)
		pitch = lerpf(start_pitch, end_pitch, t)
		_apply_rotation(), 0.0, 1.0, seconds)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.25, 500.0)
			speed_changed.emit(speed)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.25, 1.0)
			speed_changed.emit(speed)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * LOOK_SENSITIVITY
		pitch = clampf(pitch - mm.relative.y * LOOK_SENSITIVITY, -1.55, 1.55)
		_apply_rotation()


func _process(delta: float) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	var input := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): input.z -= 1
	if Input.is_physical_key_pressed(KEY_S): input.z += 1
	if Input.is_physical_key_pressed(KEY_A): input.x -= 1
	if Input.is_physical_key_pressed(KEY_D): input.x += 1
	if Input.is_physical_key_pressed(KEY_E): input.y += 1
	if Input.is_physical_key_pressed(KEY_Q): input.y -= 1
	var v := speed * (3.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	if walk:
		v = 4.0 * (2.5 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
		var flat := Basis(Vector3.UP, yaw)
		var step := flat * Vector3(input.x, 0, input.z).normalized() * v * delta
		global_position = _slide(global_position, step)
		_stick_to_ground()
	elif input != Vector3.ZERO:
		global_position += global_basis * input.normalized() * v * delta


func _apply_rotation() -> void:
	basis = Basis.from_euler(Vector3(pitch, yaw, 0.0))


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	return get_world_3d().direct_space_state.intersect_ray(q)


func _slide(pos: Vector3, step: Vector3) -> Vector3:
	if step.length() < 1e-5:
		return pos
	var reach := step + step.normalized() * 0.4
	var hit := _ray(pos, pos + reach)
	if hit.is_empty():
		return pos + step
	var n: Vector3 = hit.normal
	n.y = 0.0
	if n.length() < 0.1:
		return pos + step
	n = n.normalized()
	return pos + (step - n * step.dot(n))


func _stick_to_ground() -> void:
	var p := global_position
	var hit := _ray(p + Vector3.UP * 0.5, p + Vector3.DOWN * 200.0)
	if not hit.is_empty():
		global_position.y = hit.position.y + EYE_HEIGHT
