extends Node3D
## A person gone limp: the figure's meshes (Human) moved on to eleven rigid
## bodies -- pelvis, torso with the head, upper and lower arms and legs --
## joined at the waist, shoulders, elbows, hips and knees, thrown with the
## velocity of whatever hit them. It falls, tumbles and settles under the
## physics; restore() puts the meshes back on the figure's joints so the
## person can get up again.
##     var rag := Ragdoll.knock(human, Vector3(6, 2, 0))
##     ... rag.settled(), rag.pelvis(), rag.restore()

const Human := preload("res://scripts/human.gd")

const LAYER := 32               # ragdolls (people knocked down)
const MASK := 1 | 2 | 4 | 8 | 16 | 32   # buildings, ground, traffic, your vehicle, you, other ragdolls

var bodies: Array[RigidBody3D] = []
var _moved := []                # [mesh, its parent on the figure, its transform there]
var _human: Node3D
var _still := 0.0
var age := 0.0
var _mask := MASK


## Sends `h` flying with velocity `vel` (m/s), spinning a little; returns the
## ragdoll, a node beside it in the scene (placed in the world, so it stays
## where it falls whatever its parent does). `you`: the figure is yours, and
## the limbs do not knock against your own body.
static func knock(h: Node3D, vel: Vector3, spin := 1.0, you := false) -> Node3D:
	var r: Node3D = load("res://scripts/ragdoll.gd").new()
	r.top_level = true
	h.get_parent().add_child(r)
	r._mask = MASK & ~16 if you else MASK
	r._build(h, vel, spin)
	return r


func _physics_process(delta: float) -> void:
	age += delta
	var fast := 0.0
	for b in bodies:
		fast = maxf(fast, b.linear_velocity.length())
	_still = _still + delta if fast < 0.35 else 0.0


## At rest (for half a second) after its first second.
func settled() -> bool:
	return age > 1.0 and _still > 0.5


func pelvis() -> Vector3:
	return bodies[0].global_position


## The way the torso lies (a heading to stand up facing).
func facing() -> float:
	var up: Vector3 = bodies[1].global_transform.basis.y
	return atan2(up.x, up.z) if Vector2(up.x, up.z).length() > 0.2 else bodies[1].rotation.y


## Puts the figure back together, upright (its owner places it), and is gone.
func restore() -> void:
	for m in _moved:
		var mi: Node3D = m[0]
		if is_instance_valid(mi) and is_instance_valid(m[1]):
			mi.reparent(m[1], false)
			mi.transform = m[2]
	_moved.clear()
	if is_instance_valid(_human):
		_human.visible = true
	queue_free()


func _build(h: Node3D, vel: Vector3, spin: float) -> void:
	_human = h
	# Each body: [the figure's joint it takes over, the joints below it it
	# also carries (their meshes), shapes, mass].
	var torso_shapes := [[_box(Vector3(0.4, 0.62, 0.26)), Vector3(0, 0.27, 0)], [_sphere(0.12), Vector3(0, 0.68, 0)]]
	var spec := [
		[h.hips, [], [[_box(Vector3(0.34, 0.18, 0.22)), Vector3(0, 0.02, 0)]], 12.0],
		[h.spine, [h.head], torso_shapes, 32.0],
	]
	for pair in [[h.sh_l, h.el_l, 0.048, 0.32, 0.042, 0.3, 2.4, 1.8], [h.sh_r, h.el_r, 0.048, 0.32, 0.042, 0.3, 2.4, 1.8],
			[h.hp_l, h.kn_l, 0.07, 0.44, 0.055, 0.46, 9.0, 5.0], [h.hp_r, h.kn_r, 0.07, 0.44, 0.055, 0.46, 9.0, 5.0]]:
		spec.append([pair[0], [], [[_capsule(pair[2], pair[3]), Vector3(0, -pair[3] / 2.0, 0)]], pair[6]])
		spec.append([pair[1], [], [[_capsule(pair[4], pair[5] + 0.08), Vector3(0, -pair[5] / 2.0 - 0.02, 0)]], pair[7]])
	var made := {}
	for s in spec:
		var j: Node3D = s[0]
		var b := RigidBody3D.new()
		b.collision_layer = LAYER
		b.collision_mask = _mask
		b.mass = s[3]
		b.linear_damp = 0.05
		b.angular_damp = 1.5
		b.continuous_cd = true
		var pm := PhysicsMaterial.new(); pm.friction = 0.9; pm.bounce = 0.05
		b.physics_material_override = pm
		add_child(b)
		b.global_transform = j.global_transform
		for sh in s[2]:
			var cs := CollisionShape3D.new()
			cs.shape = sh[0]
			cs.position = sh[1]
			b.add_child(cs)
		# The joint's own meshes (the torso's, the head's too).
		for carried in [j] + s[1]:
			for c in carried.get_children():
				if c is MeshInstance3D:
					_moved.append([c, carried, c.transform])
					c.reparent(b, true)
		made[j] = b
		bodies.append(b)
	# Joints: [parent body's joint, child body's joint, swing, twist].
	for link in [[h.hips, h.spine, 0.6, 0.4],
			[h.spine, h.sh_l, 1.5, 0.6], [h.spine, h.sh_r, 1.5, 0.6], [h.sh_l, h.el_l, 1.2, 0.1], [h.sh_r, h.el_r, 1.2, 0.1],
			[h.hips, h.hp_l, 1.0, 0.3], [h.hips, h.hp_r, 1.0, 0.3], [h.hp_l, h.kn_l, 1.1, 0.1], [h.hp_r, h.kn_r, 1.1, 0.1]]:
		var a: RigidBody3D = made[link[0]]
		var b: RigidBody3D = made[link[1]]
		var jt := ConeTwistJoint3D.new()
		add_child(jt)
		# The cone's axis (the joint's X) along the limb: down the child body.
		jt.global_transform = Transform3D(b.global_transform.basis.orthonormalized() * Basis(Vector3.BACK, -PI / 2.0), b.global_position)
		jt.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, link[2])
		jt.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, link[3])
		jt.set_param(ConeTwistJoint3D.PARAM_SOFTNESS, 0.6)
		jt.set_param(ConeTwistJoint3D.PARAM_RELAXATION, 0.8)
		jt.node_a = jt.get_path_to(a)
		jt.node_b = jt.get_path_to(b)
	# Thrown: everything moving with the hit, the trunk turning over.
	var axis := Vector3.UP.cross(Vector3(vel.x, 0, vel.z)).normalized() if Vector2(vel.x, vel.z).length() > 0.1 else Vector3.RIGHT
	for b in bodies:
		b.linear_velocity = vel
		b.angular_velocity = axis * spin * 3.0
	h.visible = false               # what is left of it: the bare joints


static func _box(size: Vector3) -> BoxShape3D:
	var s := BoxShape3D.new(); s.size = size
	return s


static func _sphere(r: float) -> SphereShape3D:
	var s := SphereShape3D.new(); s.radius = r
	return s


static func _capsule(r: float, h: float) -> CapsuleShape3D:
	var s := CapsuleShape3D.new(); s.radius = r; s.height = maxf(h, r * 2.0 + 0.01)
	return s
