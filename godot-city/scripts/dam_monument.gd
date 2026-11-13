extends Node3D
## The National Monument on the Dam: the 22 m pylon (models/dam_monument.glb,
## cleaned from assets-src/landmarks/ by tools/clean_model.gd) on its round
## stepped platform, its sculpted front to the Royal Palace, its curved wall
## behind it. The city draws no house over it (TileBuilder.cleared): the data
## maps the pylon and the wall as buildings.
##
## Where: the city data maps the platform as a 37 m circle cut out of the
## square on the Dam's east side, in front of the Krasnapolsky; the pylon
## stands at its centre. (The monument's published position, 52°22'22"N
## 4°53'37"E, falls 7 m from it: within that figure's own rounding.)

const VPhys := preload("res://scripts/vehicle_physics.gd")
const TileBuilder := preload("res://scripts/tile_builder.gd")
const MODEL := "res://models/dam_monument.glb"
const AT := Vector2(-108.50, 169.84)       # scene metres (x east, z south): the platform's centre
const PALACE := Vector2(-268.5, 132.2)     # the Royal Palace's centre, across the square
## The way the front faces, degrees anticlockwise from east (the data's frame):
## square to the long side of the pylon's surveyed footprint (68.4 degrees, and
## its curved wall's 68.0), away from the wall: 22 degrees north of west.
const FRONT := 158.4
## The curved wall behind the pylon, its surveyed footprint (data decimetres).
const WALL := [-1018, -1649, -1025, -1640, -1043, -1658, -1038, -1663, -1034, -1670, -1031, -1676, -1029, -1683,
	-1027, -1691, -1027, -1698, -1027, -1706, -1029, -1713, -1031, -1720, -1034, -1727, -1038, -1733, -1043, -1739,
	-1049, -1744, -1055, -1748, -1061, -1752, -1068, -1754, -1076, -1756, -1083, -1757, -1082, -1782, -1071, -1781,
	-1061, -1778, -1051, -1774, -1042, -1769, -1033, -1763, -1025, -1756, -1018, -1748, -1013, -1739, -1008, -1729,
	-1005, -1719, -1003, -1709, -1002, -1698, -1002, -1688, -1004, -1677, -1008, -1667, -1012, -1658]
const WALL_H := 3.0                        # (its survey height, 11.8 m, is the trees over it)
const HEIGHT := 22.0                       # the pylon, metres
const STEPS := [[18.5, 0.15], [15.5, 0.30]]   # the platform: radius and top of each step
const STONE := Color("c4bdae")

var model: Node3D
var wall: StaticBody3D


## Put it at `at` (scene metres: AT in the full city; streamer.compact_point(AT) in the compact one).
func place(at: Vector2) -> void:
	position = Vector3(at.x, 0.0, at.y)
	TileBuilder.cleared = [[at, STEPS[0][0]]]   # (no house drawn over it)
	if model == null:
		_build()


func _build() -> void:
	var stone := StandardMaterial3D.new()
	stone.albedo_color = STONE
	stone.roughness = 0.9
	stone.cull_mode = BaseMaterial3D.CULL_DISABLED
	var ground := StaticBody3D.new()
	ground.collision_layer = VPhys.GROUND_LAYER
	ground.collision_mask = 0
	add_child(ground)
	for s in STEPS:
		var r: float = s[0]
		var top: float = s[1]
		var c := CylinderMesh.new()
		c.top_radius = r; c.bottom_radius = r; c.height = top; c.radial_segments = 64; c.rings = 1
		var mi := MeshInstance3D.new()
		mi.mesh = c; mi.material_override = stone; mi.position.y = top / 2.0
		add_child(mi)
		var shape := CylinderShape3D.new()
		shape.radius = r; shape.height = top
		var cs := CollisionShape3D.new()
		cs.shape = shape; cs.position.y = top / 2.0
		ground.add_child(cs)
	var top: float = STEPS[-1][1]
	model = (load(MODEL) as PackedScene).instantiate()
	add_child(model)
	var box := _box(model)
	var k := HEIGHT / box.size.y
	model.scale = Vector3.ONE * k
	model.position.y = top
	# The front (the model's +Z) along the surveyed axis.
	var b := deg_to_rad(FRONT)
	model.rotation.y = atan2(cos(b), -sin(b))
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# The pylon is solid: a box round its foot, the whole height.
	var solid := StaticBody3D.new()
	solid.collision_layer = VPhys.WALL_LAYER
	solid.collision_mask = 0
	solid.rotation.y = model.rotation.y
	add_child(solid)
	var shape := BoxShape3D.new()
	shape.size = Vector3(box.size.x * k, HEIGHT, box.size.z * k)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(box.get_center().x * k, top + HEIGHT / 2.0, box.get_center().z * k)
	solid.add_child(cs)
	_wall(stone, top)


# The curved wall behind it, raised in stone from its footprint (placed as
# far from the pylon as the survey has it).
func _wall(stone: Material, y0: float) -> void:
	var ring := TileBuilder.pts(WALL)
	for n in ring.size():
		ring[n] -= AT
	if Geometry2D.is_polygon_clockwise(ring):
		ring.reverse()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y1 := y0 + WALL_H
	var faces := PackedVector3Array()
	var tris := Geometry2D.triangulate_polygon(ring)
	for i in range(0, tris.size(), 3):
		for j in [0, 1, 2]:
			var q := ring[tris[i + j]]
			st.set_normal(Vector3.UP); st.add_vertex(Vector3(q.x, y1, q.y))
	for n in ring.size():
		var a := ring[n]; var c := ring[(n + 1) % ring.size()]
		var out := Vector3(c.y - a.y, 0, -(c.x - a.x)).normalized()
		var quad := [Vector3(a.x, y0, a.y), Vector3(c.x, y0, c.y), Vector3(c.x, y1, c.y), Vector3(a.x, y1, a.y)]
		for idx in [0, 1, 2, 0, 2, 3]:
			st.set_normal(out); st.add_vertex(quad[idx])
			faces.append(quad[idx])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = stone
	add_child(mi)
	wall = StaticBody3D.new()
	wall.collision_layer = VPhys.WALL_LAYER
	wall.collision_mask = 0
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	wall.add_child(cs)
	add_child(wall)


# The model's bounds in its own frame.
func _box(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		var xf := Transform3D.IDENTITY
		var up: Node = m
		while up != null and up != n:
			xf = (up as Node3D).transform * xf
			up = up.get_parent()
		var bb: AABB = xf * m.get_aabb()
		box = bb if first else box.merge(bb)
		first = false
	return box
