extends SceneTree
## The characters: the man (you) and the woman in red (one walker in six) are
## rigged models whose bones follow the jointed figure's joints: they load
## with their skeleton and the right height, walk (the legs swing), aim (the
## right hand comes up), hold the pistol in the model's hand, fall with the
## ragdoll and get up again; you are the man, and of the 24 walkers four are
## the woman.
##     godot --headless --path godot-city --script tests/characters_test.gd

const SkinnedPerson := preload("res://scripts/skinned_person.gd")
const Ragdoll := preload("res://scripts/ragdoll.gd")
const Walker := preload("res://scripts/walker.gd")

class OpenStreet:
	var tiles := {}
	func water_at(_p: Vector3) -> int: return 0
	func nearest_name(_p: Vector3, _within := 35.0) -> String: return "Teststraat"
	func start_point() -> Vector3: return Vector3(5, 0, 5)
	func parked_bike(_p: Vector2, _within: float) -> Dictionary: return {}
	func bridge_y(_p: Vector3) -> float: return NAN

var _fails := 0


func _initialize() -> void:
	var floor := StaticBody3D.new()
	floor.collision_layer = 2 | 1
	var cs := CollisionShape3D.new(); var b := BoxShape3D.new(); b.size = Vector3(200, 1, 200)
	cs.shape = b; cs.position.y = -0.5
	floor.add_child(cs)
	root.add_child(floor)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _bone_at(p, name: String) -> Vector3:
	var i: int = p.skel.find_bone(name)
	return p.skel.global_transform * p.skel.get_bone_global_pose(i).origin


func _height(p) -> float:
	var top := -INF
	var bottom := INF
	for mi in p.model.find_children("*", "MeshInstance3D", true, false):
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		top = maxf(top, bb.end.y); bottom = minf(bottom, bb.position.y)
	return top - bottom


func _run() -> void:
	for spec in [["res://models/char_man.glb", 1.82, "the man"], ["res://models/char_woman.glb", 1.70, "the woman"]]:
		var p = SkinnedPerson.new()
		p.build_model(spec[0])
		root.add_child(p)
		_check(p.skel != null and p._links.size() == 11 and p.grip_r != null and p.grip_l != null,
			"%s: a skeleton, 11 bones on the figure's joints, both hands" % spec[2])
		_check(absf(_height(p) - spec[1]) < 0.06, "%s: %.2f m tall" % [spec[2], _height(p)])
		var visible_meshes := p.find_children("*", "MeshInstance3D", true, false).filter(func(m): return m.is_visible_in_tree())
		_check(visible_meshes.size() == 2, "%s: only the model shows, and the shadow at the feet (%d)" % [spec[2], visible_meshes.size()])
		await process_frame
		# Walking: the feet swing apart, front and back.
		var spread := 0.0
		for f in 60:
			p.animate(1.0 / 60.0, "walk", 1.5)
			await process_frame
			spread = maxf(spread, absf(_bone_at(p, "foot.L").z - _bone_at(p, "foot.R").z))
		_check(spread > 0.25, "%s walks: the feet %.2f m apart at the stride" % [spec[2], spread])
		p.free()
	# You: aiming, the pistol in your hand, knocked down and up again.
	var p = SkinnedPerson.new()
	p.build_model("res://models/char_man.glb")
	root.add_child(p)
	var gun := MeshInstance3D.new(); gun.mesh = BoxMesh.new()
	p.grip_r.add_child(gun)
	for f in 5:
		p.animate(1.0 / 60.0, "idle", 0.0)
		await process_frame
	var hand_down := _bone_at(p, "hand.R")
	p.sh_r.rotation.x = 1.5; p.el_r.rotation.x = 0.05            # (as Walker aims)
	p._pose()
	await process_frame
	var hand_up := _bone_at(p, "hand.R")
	_check(hand_up.y > hand_down.y + 0.3 and hand_up.z < hand_down.z - 0.25,
		"aiming: the right hand comes up and forward (%.2f m up, %.2f m forward)" % [hand_up.y - hand_down.y, hand_down.z - hand_up.z])
	_check(gun.global_position.distance_to(hand_up) < 0.12, "the pistol is in the model's hand (%.2f m)" % gun.global_position.distance_to(hand_up))
	p.sh_r.rotation.x = 0.0
	var rag = Ragdoll.knock(p, Vector3(4, 1, 0))
	_check(p.visible and p._rag == rag, "knocked down: the model stays, on the ragdoll")
	for f in 90:
		await physics_frame
	var hips := _bone_at(p, "hips")
	print("ragdoll: pelvis at %s, the model's hips at %s" % [rag.pelvis(), hips])
	_check(hips.distance_to(rag.pelvis()) < 0.35 and hips.y < 0.6, "the model falls with it: its hips where the pelvis lies")
	rag.restore()
	p.position = Vector3.ZERO
	p.animate(1.0 / 60.0, "idle", 0.0)
	await process_frame
	_check(p._rag == null and _bone_at(p, "hips").y > 0.8, "back on their feet: the bones back on the figure")
	p.queue_free()
	# The game: you are the man; four of the 24 walkers are the woman.
	var w = Walker.new()
	var cam := Camera3D.new()
	root.add_child(cam)
	w.setup(OpenStreet.new(), cam)
	root.add_child(w)
	_check(w.body is SkinnedPerson and String(w.body.model.scene_file_path).ends_with("char_man.glb"), "you: the man")
	_check(w._gun.get_parent() == w.body.grip_r and w._bouquet.get_parent() == w.body.grip_l, "the pistol and the tulips in his hands")
	w.enter(Vector3(0, 0, 0), 0.0)
	var women: int = w.peds.filter(func(q): return q.get("model", "") == "woman").size()
	_check(w.peds.size() == 24 and women == 4, "the walkers: %d, of them %d the woman in red" % [w.peds.size(), women])
	print("characters test: %d failed" % _fails)
	quit(1 if _fails else 0)
