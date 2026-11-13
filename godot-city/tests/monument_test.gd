extends SceneTree
## The National Monument on the Dam (scripts/dam_monument.gd): the pylon alone
## (the model's stray pieces gone), 22 m tall, standing at the centre of its
## round platform as the city data has it, its sculpted front to the Royal
## Palace along the surveyed axis, its curved wall behind it, no house drawn
## over it; the platform's steps underfoot, the pylon solid; and light enough
## for the web.
##     godot --headless --path godot-city --script tests/monument_test.gd

const DamMonument := preload("res://scripts/dam_monument.gd")
const VPhys := preload("res://scripts/vehicle_physics.gd")
const TileBuilder := preload("res://scripts/tile_builder.gd")

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _run() -> void:
	var m = DamMonument.new()
	root.add_child(m)
	m.place(DamMonument.AT)
	await process_frame
	var box := AABB(); var first := true
	var meshes: Array = m.model.find_children("*", "MeshInstance3D", true, false)
	for mi: MeshInstance3D in meshes:
		var bb: AABB = mi.global_transform * mi.get_aabb()
		box = bb if first else box.merge(bb); first = false
	_check(meshes.size() == 1, "one mesh")
	_check(absf(box.size.y - DamMonument.HEIGHT) < 0.3 and box.position.y > 0.2 and box.position.y < 0.5,
		"22 m tall, on the platform (%.1f m, foot at %.2f)" % [box.size.y, box.position.y])
	_check(box.size.x < 9.0 and box.size.z < 9.0, "the pylon alone, no stray pieces round it (%.1f x %.1f m)" % [box.size.x, box.size.z])
	var foot := Vector2(box.get_center().x, box.get_center().z)
	_check(foot.distance_to(DamMonument.AT) < 1.0, "at the centre of its round platform (%.2f m off)" % foot.distance_to(DamMonument.AT))
	var front: Vector3 = (m.model.global_transform.basis.z * Vector3(1, 0, 1)).normalized()
	# The surveyed footprints: the pylon's, and its curved wall's behind it (east). The front faces away from the wall.
	var wall_c := Vector2.ZERO
	var ring := TileBuilder.pts(DamMonument.WALL)
	for q in ring: wall_c += q / ring.size()
	var away := Vector3(DamMonument.AT.x - wall_c.x, 0, DamMonument.AT.y - wall_c.y).normalized()
	_check(rad_to_deg(front.angle_to(away)) < 4.0, "its front faces west, away from its curved wall (%.1f degrees off)" % rad_to_deg(front.angle_to(away)))
	var to_palace := Vector3(DamMonument.PALACE.x - DamMonument.AT.x, 0, DamMonument.PALACE.y - DamMonument.AT.y).normalized()
	_check(rad_to_deg(front.angle_to(to_palace)) < 12.0, "towards the Royal Palace (%.1f degrees off its centre)" % rad_to_deg(front.angle_to(to_palace)))
	# The curved wall, built from its footprint, solid.
	_check(m.wall != null, "its curved wall stands behind it")
	# The city leaves the monument's spot to it: no house drawn on the platform.
	var tb := TileBuilder.new()
	var r: Dictionary = await tb.build_tile({"tile": [-1, -1], "size": 375.0, "buildings": [
		{"r": [[-1074, -1703, -1068, -1687, -1060, -1677, -1089, -1666, -1096, -1694, -1111, -1720, -1081, -1731]], "h": 13.2, "e": 13.2},
		{"r": [[-1500, -1500, -1450, -1500, -1450, -1450, -1500, -1450]], "h": 10.0, "e": 10.0}]})
	_check(int(r.buildings) == 1, "the city leaves the platform to the monument (%d of 2 houses drawn)" % int(r.buildings))
	# Underfoot: the steps are ground (you go up them); the pylon is a wall.
	var space := root.get_world_3d().direct_space_state
	var at := Vector3(DamMonument.AT.x + 14.0, 5.0, DamMonument.AT.y)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(at, at + Vector3.DOWN * 10.0, VPhys.GROUND_LAYER))
	_check(not hit.is_empty() and hit.position.y > 0.1 and hit.position.y < 0.5, "the platform's steps are ground underfoot")
	var side := Vector3(DamMonument.AT.x + 12.0, 1.5, DamMonument.AT.y)
	var wall := space.intersect_ray(PhysicsRayQueryParameters3D.create(side, Vector3(DamMonument.AT.x, 1.5, DamMonument.AT.y), VPhys.WALL_LAYER))
	_check(not wall.is_empty(), "the pylon is solid")
	# Light enough for the web, and the source model kept out of the game.
	var size := FileAccess.open(DamMonument.MODEL, FileAccess.READ).get_length()
	_check(size < 2_500_000, "the model is %.1f MB" % (size / 1e6))
	_check(not FileAccess.file_exists("res://monument obelisk 3d model.glb"), "the source model is not in the game (assets-src/landmarks/)")
	print("monument test: %d failed" % _fails)
	quit(1 if _fails else 0)
