extends Node3D
## A ridden bike from the Blender models (blender/make_bikes.py): wheels and
## crank turn with the speed, and the rider's legs follow the pedals.
## Forward is -Z; the origin is on the ground between the wheels.

const Human := preload("res://scripts/human.gd")
const WHEEL_R := 0.355
const GEAR := 2.6                         # wheel turns per crank turn
const SEAT := Vector3(0.0, 0.09, 0.24)    # where the rider's origin sits on the bike
const THIGH := 0.44
const SHIN := 0.48
const PEDAL := 0.17
const UPPER_ARM := 0.30
const FOREARM := 0.28
const GRIP := Vector3(0.0, 1.05, -0.17)   # handlebar grips (x left out: the shoulders are about as wide)
const LEAN := -0.38                       # negative leans the back forward

static var _scenes := {}

var frame: MeshInstance3D
var wheels: Array[Node3D] = []
var crank: Node3D
var stand: Node3D
var rider: Node3D
var paint: StandardMaterial3D


## kind is "oma" or "opa"; detail "" for the bike you ride, "_low" for traffic.
static func scene(kind: String, detail := "") -> PackedScene:
	var key := kind + detail
	if not _scenes.has(key):
		_scenes[key] = load("res://models/bike_%s%s.glb" % [kind, detail])
	return _scenes[key]


func build(kind: String, color: Color, detail := "") -> void:
	var s: Node3D = scene(kind, detail).instantiate()
	add_child(s)
	frame = s.find_child("frame", true, false)
	for n in ["wheel_rear", "wheel_front"]:
		wheels.append(s.find_child(n, true, false))
	crank = s.find_child("crank", true, false)
	stand = s.find_child("stand", true, false)
	# Recolour the frame: the paint is its own material in the model.
	paint = StandardMaterial3D.new()
	paint.albedo_color = color
	paint.metallic = 0.3
	paint.roughness = 0.35
	for i in frame.mesh.get_surface_count():
		var m := frame.mesh.surface_get_material(i)
		if m and m.resource_name.begins_with("paint"):
			frame.set_surface_override_material(i, paint)
	set_parked(false)


## A rider: random, or with the given look ([top, legs, skin, hair, shoe, jacket]).
func add_rider(rng: RandomNumberGenerator = null, look: Array = []) -> void:
	if rider:
		rider.queue_free()
	rider = Human.new()
	if look.size():
		rider.callv("build", look.duplicate())   # callv garbles a read-only (const) array
	else:
		rider.random_look(rng)
	rider.position = SEAT
	add_child(rider)
	_pose_rider()


func set_parked(on: bool) -> void:
	if stand: stand.visible = on
	if rider: rider.visible = not on


func pedal(dt: float, speed: float) -> void:
	var turn := speed / WHEEL_R * dt
	for w in wheels:
		w.rotation.x -= turn
	crank.rotation.x -= turn / GEAR
	if rider and rider.visible:
		_pose_rider()


# Two bones in the bike's side plane: the angles (from straight down, forward
# positive) of the first bone and the bend at the joint, reaching from `root`
# to `target`. `knee_forward` bends the middle joint forward (a knee) rather
# than back (an elbow seen from the side).
static func _two_bone(root: Vector3, target: Vector3, a: float, b: float, knee_forward: bool) -> Vector2:
	var d := target - root
	var fwd := -d.z
	var down := -d.y
	var reach := clampf(Vector2(fwd, down).length(), absf(a - b) + 0.01, a + b - 0.002)
	var phi := atan2(fwd, down)
	var alpha := acos(clampf((a * a + reach * reach - b * b) / (2 * a * reach), -1, 1))
	var beta := acos(clampf((a * a + b * b - reach * reach) / (2 * a * b), -1, 1))
	return Vector2(phi + alpha, -(PI - beta)) if knee_forward else Vector2(phi - alpha, PI - beta)


# Legs from each hip to its pedal, hands from each shoulder to the grips.
func _pose_rider() -> void:
	var h: Node3D = rider
	h.hips.position.y = 0.93
	h.spine.rotation = Vector3(LEAN, 0, 0)
	# The grips in the spine's own frame, where the shoulders hang.
	var spine_at: Vector3 = SEAT + h.hips.position + h.spine.position
	var grip: Vector3 = h.spine.basis.inverse() * (GRIP - spine_at)
	for arm in [[h.sh_l, h.el_l], [h.sh_r, h.el_r]]:
		var r := _two_bone((arm[0] as Node3D).position, grip, UPPER_ARM, FOREARM, false)
		(arm[0] as Node3D).rotation.x = r.x
		(arm[1] as Node3D).rotation.x = r.y
	var crank_basis := Basis(Vector3.RIGHT, crank.rotation.x)
	for leg in [[h.hp_r, h.kn_r, 1.0], [h.hp_l, h.kn_l, -1.0]]:
		var arm: Vector3 = Vector3(0, sin(-1.2), -cos(-1.2)) * PEDAL * leg[2]   # the right arm, mirrored for the left
		var pedal_at: Vector3 = crank.position + crank_basis * arm
		var hip: Vector3 = SEAT + h.hips.position + (leg[0] as Node3D).position
		var r := _two_bone(hip, pedal_at, THIGH, SHIN, true)
		(leg[0] as Node3D).rotation.x = r.x
		(leg[1] as Node3D).rotation.x = r.y
