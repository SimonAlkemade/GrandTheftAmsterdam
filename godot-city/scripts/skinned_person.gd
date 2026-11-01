extends "res://scripts/human.gd"
## A rigged character model (models/char_*.glb, rigged by
## blender/rig_character.py) in place of the jointed figure, moving exactly as
## the figure would: the figure is still built (its joints, invisibly), all the
## code that animates it, aims its arm, swims or climbs with it keeps doing
## so, and every frame the model's bones copy its joints' rotations. Knocked
## down, the bones follow the ragdoll's bodies instead. The copy is made late
## in each frame (_process, after everything else), so whatever set the joints
## (the walk, an aimed arm, hands on a boat's wheel, legs on a bike's pedals)
## the model shows it.
##     var p := SkinnedPerson.new(); p.build_model("res://models/char_man.glb")
##
## The model and the figure stand alike at rest (arms down at the sides): the
## offset of each bone from its joint is measured once, then kept.

## The model's bones, and the figure's joint each one follows (parents first).
const BONES := [
	["hips", "hips"], ["spine", "spine"], ["head", "head"],
	["upperarm.L", "sh_l"], ["forearm.L", "el_l"], ["upperarm.R", "sh_r"], ["forearm.R", "el_r"],
	["thigh.L", "hp_l"], ["shin.L", "kn_l"], ["thigh.R", "hp_r"], ["shin.R", "kn_r"],
]

var model: Node3D
var skel: Skeleton3D
var grip_r: BoneAttachment3D    # the right hand (the pistol), the left (the tulips)
var grip_l: BoneAttachment3D
var _links: Array = []          # [bone index, joint, offset basis (joint -> bone), parent bone index or -1]
var _skel_rest: Basis           # the skeleton's frame in this person's
var _hips_rest: Vector3         # where the hips joint was at rest (this person's frame)
var _rag = null                 # the ragdoll while knocked down


## Builds the (hidden) figure and the model over it.
func build_model(path: String) -> void:
	build(Color.GRAY, Color.GRAY, Color.GRAY, Color.GRAY, Color.GRAY)
	for mi in find_children("*", "MeshInstance3D", true, false):
		if mi != shade:
			(mi as MeshInstance3D).visible = false
	model = (load(path) as PackedScene).instantiate()
	model.rotation.y = PI                       # (the models face +Z; everything here faces -Z)
	add_child(model)
	skel = model.find_children("*", "Skeleton3D", true, false)[0]
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_skel_rest = _rel(skel).basis
	for pair in BONES:
		var i := skel.find_bone(pair[0])
		if i < 0:
			push_warning("%s: no bone %s" % [path, pair[0]])
			continue
		var j: Node3D = get(pair[1])
		var bone_rest: Basis = _skel_rest * skel.get_bone_global_rest(i).basis
		var off: Basis = _rel(j).basis.inverse() * bone_rest
		var parent := skel.get_bone_parent(i)
		_links.append([i, j, off, parent])
	_hips_rest = _rel(hips).origin
	grip_r = _grip("hand.R")
	grip_l = _grip("hand.L")
	process_priority = 100                      # (after whoever poses the joints this frame)
	_pose()


func _grip(bone: String) -> BoneAttachment3D:
	var a := BoneAttachment3D.new()
	a.bone_name = bone
	skel.add_child(a)
	return a


## Knocked down (`rag` the Ragdoll) or back on their feet (null).
func ragdolled(rag) -> void:
	_rag = rag
	if rag == null:
		_pose()


func _process(_delta: float) -> void:
	if is_visible_in_tree():
		_pose()


# The bones to the joints (or, knocked down, to the ragdoll's bodies).
func _pose() -> void:
	if skel == null:
		return
	var inv := global_transform.affine_inverse() if is_inside_tree() else Transform3D.IDENTITY
	var g := {}                                  # bone -> its basis in the skeleton's frame, as set
	var to_skel := _skel_rest.inverse()
	for l in _links:
		var i: int = l[0]
		var j: Node3D = l[1]
		var xf: Transform3D
		xf = _rel(j)
		if _rag != null and is_instance_valid(_rag):
			# The body that took this joint over, or its nearest ancestor's (the
			# head rides on the torso's), carrying the joint along with it.
			var up: Node = j
			while up != null and up != self and not _rag.joint_body.has(up):
				up = up.get_parent()
			if up != null and up != self:
				var body_xf: Transform3D = inv * (_rag.joint_body[up] as Node3D).global_transform
				xf = body_xf * (_rel(up as Node3D).affine_inverse() * xf)
		var want: Basis = to_skel * (xf.basis.orthonormalized() * l[2])
		var parent: int = l[3]
		var pb: Basis = g[parent] if g.has(parent) else (skel.get_bone_global_rest(parent).basis if parent >= 0 else Basis())
		skel.set_bone_pose_rotation(i, (pb.inverse() * want).orthonormalized().get_rotation_quaternion())
		g[i] = want
		if parent < 0:                           # the hips: where they are, too
			var at: Vector3 = to_skel * (xf.origin - _hips_rest)
			skel.set_bone_pose_position(i, skel.get_bone_rest(i).origin + at)


# `n`'s transform in this person's frame (whether or not it is in the tree).
func _rel(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var at: Node = n
	while at != null and at != self:
		xf = (at as Node3D).transform * xf
		at = at.get_parent()
	return xf
