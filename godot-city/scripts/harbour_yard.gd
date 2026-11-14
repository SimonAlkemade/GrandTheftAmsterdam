extends Node3D
## The container yard of the first mission, on Zeeburgereiland in the eastern
## harbour (the open quay by the bunker station, free ground in the city data):
## a chain-link fence round it (models/fence.glb, solid), the panel on the
## street side that is cut (models/fence_cut.glb, its flap peels up: "peel"),
## twelve 40 ft containers (models/container.glb) in three columns of four,
## some stacked two high; the three of the north row stand open, facing the
## open ground by the cut, and the duffel bag lies in one of them. A van
## waits outside.
##
## Yard coordinates: u east from the west fence (0..SIZE.x), v north from the
## south fence (0..SIZE.y), metres; ORIGIN is the fence's south-west corner.

const VPhys := preload("res://scripts/vehicle_physics.gd")
const Models := preload("res://scripts/vehicle_models.gd")

const ORIGIN := Vector3(4263.0, 0.0, -3.0)      # scene metres: the south-west corner (data 42630, 30 dm)
const SIZE := Vector2(44.0, 74.0)
const PANEL := 3.0                               # one fence panel
const CUT_V := 67.5                              # the cut panel's middle, on the west fence
const COLUMNS := [8.0, 20.0, 32.0]               # containers' middles, u
const ROWS := [9.0, 23.5, 38.0, 52.5]            # and v; the last row stands open
const LENGTH := 12.19
const WIDTH := 2.44
const HEIGHT := 2.59
const COLOURS := ["1d4f91", "b3261e", "2f6b3a", "8a8f94", "d0662a", "6b2e5f", "0f6e7a", "c9a227"]
const VAN := Vector2(-10.0, 52.0)                # where the van waits (u, v): outside, by the street

var origin := ORIGIN                             # (a test puts it elsewhere)
var bag_container := -1                          # which of the open ones (0..2) has the bag
var bag: Node3D
var flap_anim: AnimationPlayer
var open_containers: Array = []                  # [node, door end (u, v)]
var _rng := RandomNumberGenerator.new()


## The scene position of yard point (u, v).
func at(u: float, v: float) -> Vector3:
	return origin + Vector3(u, 0.0, -v)


## Outside the cut, and inside it (where you crawl from and to).
func cut_out() -> Vector3:
	return at(-1.6, CUT_V)


func cut_in() -> Vector3:
	return at(1.8, CUT_V)


func build(seed: int) -> void:
	_rng.seed = seed
	_fence()
	_containers()
	_van()


func _fence() -> void:
	var panel: PackedScene = load("res://models/fence.glb")
	var cut: PackedScene = load("res://models/fence_cut.glb")
	# West (the street side, the cut in it), north, east, south: each a line of panels and one solid wall.
	var sides := [[Vector2(0, 0), Vector2(0, SIZE.y)], [Vector2(0, SIZE.y), Vector2(SIZE.x, SIZE.y)],
		[Vector2(SIZE.x, SIZE.y), Vector2(SIZE.x, 0)], [Vector2(SIZE.x, 0), Vector2(0, 0)]]
	for k in sides.size():
		var a: Vector2 = sides[k][0]; var b: Vector2 = sides[k][1]
		var length := a.distance_to(b)
		var n := int(ceil(length / PANEL))
		var dir := (b - a).normalized()
		var pa := at(a.x, a.y); var pb := at(b.x, b.y)
		var yaw := atan2(-(pb - pa).z, (pb - pa).x)      # (the panel's x along the side)
		for i in n:
			var mid_d := (i + 0.5) * length / n
			var mid := a + dir * mid_d
			var is_cut := k == 0 and absf(mid.y - CUT_V) < 0.5 * length / n
			var p: Node3D = (cut if is_cut else panel).instantiate()
			p.position = at(mid.x, mid.y)
			p.rotation.y = yaw
			p.scale.x = (length / n) / PANEL
			add_child(p)
			if is_cut:
				flap_anim = p.find_child("AnimationPlayer", true, false)
		# One wall the length of the side (you cannot walk through it; under it, once cut, you crawl).
		var wall := StaticBody3D.new()
		wall.collision_layer = VPhys.WALL_LAYER
		wall.collision_mask = 0
		var shape := BoxShape3D.new()
		shape.size = Vector3(length, 2.4, 0.12)
		var cs := CollisionShape3D.new(); cs.shape = shape
		cs.position = (pa + pb) / 2.0 + Vector3(0, 1.2, 0)
		cs.rotation.y = yaw
		wall.add_child(cs)
		add_child(wall)


func _containers() -> void:
	var scene: PackedScene = load("res://models/container.glb")
	bag_container = _rng.randi() % COLUMNS.size()
	for r in ROWS.size():
		for c in COLUMNS.size():
			var open: bool = r == ROWS.size() - 1
			var stack := 1 if open or _rng.randf() < 0.6 else 2
			for level in stack:
				var n: Node3D = scene.instantiate()
				n.position = at(COLUMNS[c], ROWS[r]) + Vector3(0, level * HEIGHT, 0)
				n.rotation.y = PI / 2                   # (its length north-south, doors north)
				_paint(n, Color(COLOURS[_rng.randi() % COLOURS.size()]))
				add_child(n)
				if open and level == 0:
					var dl: Node3D = n.find_child("door_l", true, false)
					var dr: Node3D = n.find_child("door_r", true, false)
					if dl: dl.rotation.y = deg_to_rad(100)
					if dr: dr.rotation.y = deg_to_rad(-100)
					_hollow(n.position)
					open_containers.append([n, Vector2(COLUMNS[c], ROWS[r] + LENGTH / 2.0)])
					if c == bag_container:
						bag = (load("res://models/duffel.glb") as PackedScene).instantiate()
						bag.position = n.position + Vector3(0, 0.65, -(LENGTH / 2.0 - 4.0))
						bag.rotation.y = 0.3
						add_child(bag)
				elif level == 0:
					_solid(n.position + Vector3(0, HEIGHT * stack / 2.0, 0), Vector3(WIDTH, HEIGHT * stack, LENGTH))


func _paint(n: Node3D, col: Color) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		for s in m.mesh.get_surface_count():
			var mat := m.mesh.surface_get_material(s)
			if mat is StandardMaterial3D and mat.resource_name == "paint":
				var p: StandardMaterial3D = mat.duplicate()
				p.albedo_color = col
				m.set_surface_override_material(s, p)


func _solid(centre: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	b.collision_layer = VPhys.WALL_LAYER
	b.collision_mask = 0
	var shape := BoxShape3D.new(); shape.size = size
	var cs := CollisionShape3D.new(); cs.shape = shape; cs.position = centre
	b.add_child(cs)
	add_child(b)


# An open container: its two sides, its back and its roof are walls, its floor is ground.
func _hollow(base: Vector3) -> void:
	var half := LENGTH / 2.0
	_solid(base + Vector3(-WIDTH / 2.0 + 0.04, HEIGHT / 2.0, 0), Vector3(0.08, HEIGHT, LENGTH))
	_solid(base + Vector3(WIDTH / 2.0 - 0.04, HEIGHT / 2.0, 0), Vector3(0.08, HEIGHT, LENGTH))
	_solid(base + Vector3(0, HEIGHT / 2.0, half - 0.04), Vector3(WIDTH, HEIGHT, 0.08))   # the back (south)
	_solid(base + Vector3(0, HEIGHT - 0.04, 0), Vector3(WIDTH, 0.08, LENGTH))
	var floor := StaticBody3D.new()
	floor.collision_layer = VPhys.GROUND_LAYER
	floor.collision_mask = 0
	var shape := BoxShape3D.new(); shape.size = Vector3(WIDTH - 0.1, 0.175, LENGTH - 0.1)
	var cs := CollisionShape3D.new(); cs.shape = shape; cs.position = base + Vector3(0, 0.0875, 0)
	floor.add_child(cs)
	add_child(floor)


func _van() -> void:
	var van: Node3D = Models.car(Color("1d2126"))
	van.position = at(VAN.x, VAN.y)
	van.rotation.y = 0.0                               # (facing north, along the street)
	add_child(van)
	_solid(van.position + Vector3(0, 0.75, 0), Vector3(1.8, 1.5, 4.4))


## Where the bag lies (scene), or INF once taken.
func bag_at() -> Vector3:
	return bag.global_position if bag != null and is_instance_valid(bag) else Vector3.INF
