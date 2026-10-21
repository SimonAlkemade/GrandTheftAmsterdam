extends Node3D
## Streams the city in 1.5 km tiles around `focus`. Reading and meshing a
## tile happens on WorkerThreadPool threads; the main thread only turns the
## finished arrays into nodes, one tile per frame, so the game never stalls.

signal tile_added(key: String, result: Dictionary)
signal tile_removed(key: String)

const TileBuilder := preload("res://scripts/tile_builder.gd")
const BUILDING_MATS := ["facade_", "ground_home_", "ground_shop_", "trim_", "office", "boat", "roof_"]
const STREET_MATS := ["road", "bike", "walk", "tram", "rail", "rails", "bridge"]
const MINI_CELL := 64.0
# Minimap layers, drawn in this order, and the surfaces each is made of.
const MINI := {
	"water": ["water"], "green": ["park", "grass", "garden", "pitch"], "walk": ["walk", "plaza", "bike", "bridge"],
	"road": ["road"], "tram": ["tram"], "roof": ["roof_0", "roof_1", "roof_2", "roof_flat"],
}

var mats
var data_dir := "res://data/"
var index := {}
var tile_size := 1500.0
var tiles := {}              # key -> { state, node, result }
var focus := Vector3.ZERO
var radius := 1500.0
var show := {"buildings": true, "streets": true, "trees": true, "furniture": true}
var _done: Array = []
var _mutex := Mutex.new()
var _loading := 0
var _tick := 0.0
var _kit := {}


func setup(materials) -> void:
	mats = materials
	var f := FileAccess.open(data_dir + "index.json", FileAccess.READ)
	if f == null:
		push_error("No city data in %s. Run prepare_godot_city.py first (see README)." % data_dir)
		return
	index = JSON.parse_string(f.get_as_text())
	tile_size = float(index.tile)
	_overview()
	_make_kit()


func start_point() -> Vector3:
	return Vector3(float(index.start[0]) / 10.0, 0, -float(index.start[1]) / 10.0)


func total_buildings() -> int:
	var n := 0
	for t in index.get("tiles", []):
		n += int(t[2])
	return n


# The whole city as one map image under the 3D tiles, visible from any height.
func _overview() -> void:
	var b: Array = index.bounds
	var xs := [float(b[0]) / 10, float(b[2]) / 10, float(b[4]) / 10, float(b[6]) / 10]
	var zs := [-float(b[1]) / 10, -float(b[3]) / 10, -float(b[5]) / 10, -float(b[7]) / 10]
	var x0: float = xs.min(); var x1: float = xs.max(); var z0: float = zs.min(); var z1: float = zs.max()
	var plane := PlaneMesh.new()
	plane.size = Vector2(x1 - x0, z1 - z0)
	var m := StandardMaterial3D.new()
	var img := Image.load_from_file(ProjectSettings.globalize_path(data_dir + "overview.jpg"))
	if img:
		img.generate_mipmaps()
		m.albedo_texture = ImageTexture.create_from_image(img)
	m.roughness = 1.0
	m.disable_fog = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = m
	mi.position = Vector3((x0 + x1) / 2, -0.15, (z0 + z1) / 2)
	add_child(mi)


# Shared meshes for instanced things: built once, used by every tile.
func _make_kit() -> void:
	var cyl := func(top: float, bottom: float, h: float, segs := 6) -> CylinderMesh:
		var c := CylinderMesh.new(); c.top_radius = top; c.bottom_radius = bottom; c.height = h; c.radial_segments = segs; c.rings = 1
		return c
	var mat := func(c: String, rough := 0.7) -> StandardMaterial3D:
		var m := StandardMaterial3D.new(); m.albedo_color = Color(c); m.roughness = rough
		return m
	var leaves := StandardMaterial3D.new(); leaves.vertex_color_use_as_albedo = true; leaves.roughness = 0.9
	var crown := SphereMesh.new(); crown.radius = 4.2; crown.height = 9.6; crown.radial_segments = 8; crown.rings = 5
	var bench := BoxMesh.new(); bench.size = Vector3(1.8, 0.5, 0.5)
	var bike := BoxMesh.new(); bike.size = Vector3(1.7, 0.9, 0.08)
	var bikes := StandardMaterial3D.new(); bikes.vertex_color_use_as_albedo = true
	_kit = {
		"trees": [[cyl.call(0.22, 0.32, 5.0), mat.call("4b3a2c"), 2.5, false], [crown, leaves, 8.0, true]],
		"lamps": [[cyl.call(0.07, 0.11, 4.5), mat.call("1f3a2c", 0.6), 2.25, false], [cyl.call(0.22, 0.12, 0.42), mats.get_mat("lamp_glass"), 4.72, false]],
		"benches": [[bench, mat.call("5a3f2a"), 0.45, false]],
		"bikes": [[bike, bikes, 0.45, true]],
		"bins": [[cyl.call(0.28, 0.28, 0.95, 8), mat.call("1f3a2c", 0.6), 0.48, false]],
		"signals": [[cyl.call(0.06, 0.06, 3.2), mat.call("1b1d1f", 0.6), 1.6, false]],
		"bollards": [[cyl.call(0.1, 0.12, 0.85, 8), mat.call("6b2a1d"), 0.43, false]],
	}


func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = 0.4
		_update_tiles()
	var r = null
	_mutex.lock()
	if _done.size():
		# Integrate the finished tile nearest to the focus first.
		var best := 0
		for i in _done.size():
			if _done[i].rect.get_center().distance_to(Vector2(focus.x, focus.z)) < _done[best].rect.get_center().distance_to(Vector2(focus.x, focus.z)):
				best = i
		r = _done[best]
		_done.remove_at(best)
	_mutex.unlock()
	if r != null:
		_integrate(r)


func _tile_distance(i: int, j: int) -> float:
	var c := Vector2((i + 0.5) * tile_size, -(j + 0.5) * tile_size)
	return c.distance_to(Vector2(focus.x, focus.z)) - tile_size * 0.71


func _update_tiles() -> void:
	if index.is_empty():
		return
	var want := []
	for t in index.tiles:
		var d := _tile_distance(int(t[0]), int(t[1]))
		if d < radius:
			want.append([maxf(d, 0.0), "%d_%d" % [int(t[0]), int(t[1])]])
	want.sort_custom(func(a, b): return a[0] < b[0])
	for w in want:
		if _loading >= 3:
			break
		if tiles.has(w[1]):
			continue
		tiles[w[1]] = {"state": "loading"}
		_loading += 1
		WorkerThreadPool.add_task(_task.bind(w[1]))
	for key in tiles.keys():
		var t: Dictionary = tiles[key]
		if t.state != "ready":
			continue
		var ij: PackedStringArray = key.split("_")
		if _tile_distance(int(ij[0]), int(ij[1])) > radius + 1600.0:
			t.node.queue_free()
			tiles.erase(key)
			tile_removed.emit(key)


# Worker thread: read, decode and mesh one tile.
func _task(key: String) -> void:
	var f := FileAccess.open(data_dir + "tiles/%s.json" % key, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text()) if f else null
	var r := {}
	if typeof(data) == TYPE_DICTIONARY:
		r = TileBuilder.new().build_tile(data)
		r.instances = _instance_buffers(r.points)
		r.mini = _minimap_cells(r.surfaces)
	else:
		r = {"key": key, "failed": true, "rect": Rect2()}
	_mutex.lock()
	_done.append(r)
	_loading -= 1
	_mutex.unlock()


# The tile's surfaces flattened to 2D triangles per minimap layer, bucketed
# into cells so the minimap draws only what is near the player. A triangle
# goes into every cell its bounding box touches (canals are big triangles).
func _minimap_cells(surfaces: Dictionary) -> Dictionary:
	var cells := {}
	for layer in MINI:
		for mname in MINI[layer]:
			if not surfaces.has(mname):
				continue
			var v: PackedVector3Array = surfaces[mname][0]
			for t in range(0, v.size() - 2, 3):
				var a := Vector2(v[t].x, v[t].z); var b := Vector2(v[t + 1].x, v[t + 1].z); var c := Vector2(v[t + 2].x, v[t + 2].z)
				if absf((b - a).cross(c - a)) < 0.05:
					continue                    # edge-on from above (gable ends): no area
				var c0 := Vector2i(floori(minf(a.x, minf(b.x, c.x)) / MINI_CELL), floori(minf(a.y, minf(b.y, c.y)) / MINI_CELL))
				var c1 := Vector2i(floori(maxf(a.x, maxf(b.x, c.x)) / MINI_CELL), floori(maxf(a.y, maxf(b.y, c.y)) / MINI_CELL))
				for cx in range(c0.x, c1.x + 1):
					for cy in range(c0.y, c1.y + 1):
						var k := Vector2i(cx, cy)
						if not cells.has(k):
							cells[k] = {}
						if not cells[k].has(layer):
							cells[k][layer] = PackedVector2Array()
						var arr: PackedVector2Array = cells[k][layer]
						arr.append(a); arr.append(b); arr.append(c)
						cells[k][layer] = arr
	return cells


## Minimap triangles of every loaded tile near `p`: [[layer, PackedVector2Array], ...] in MINI order.
func minimap_near(p: Vector2, radius: float) -> Array:
	var out := []
	var r := ceili(radius / MINI_CELL)
	var cp := Vector2i(floori(p.x / MINI_CELL), floori(p.y / MINI_CELL))
	for layer in MINI:
		for t in tiles.values():
			if t.state != "ready" or not t.result.has("mini"):
				continue
			var rect: Rect2 = t.result.rect
			if not rect.grow(radius).has_point(p):
				continue
			var cells: Dictionary = t.result.mini
			for cx in range(cp.x - r, cp.x + r + 1):
				for cy in range(cp.y - r, cp.y + r + 1):
					var c = cells.get(Vector2i(cx, cy))
					if c != null and c.has(layer):
						out.append([layer, c[layer]])
	return out


# MultiMesh buffers (3x4 transform + colour per instance), built off-thread.
func _instance_buffers(points: Dictionary) -> Dictionary:
	var out := {}
	var rng := RandomNumberGenerator.new()
	for kind in points:
		var p: PackedVector2Array = points[kind]
		if kind == "bikes":                  # three parked bikes per rack
			var q := PackedVector2Array()
			for v in p:
				for k in [-0.7, 0.0, 0.7]:
					q.append(v + Vector2(k, 0))
			p = q
		rng.seed = p.size() * 31 + kind.length()
		var buf := PackedFloat32Array()
		buf.resize(p.size() * 16)
		for i in p.size():
			var s := 1.0
			var yaw := rng.randf() * TAU
			if kind == "trees":
				s = 0.75 + rng.randf() * 0.55
			if kind == "bikes":
				yaw = 0.0
			var bas := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
			var o := i * 16
			buf[o] = bas.x.x; buf[o + 1] = bas.y.x; buf[o + 2] = bas.z.x; buf[o + 3] = p[i].x
			buf[o + 4] = bas.x.y; buf[o + 5] = bas.y.y; buf[o + 6] = bas.z.y; buf[o + 7] = 0.0
			buf[o + 8] = bas.x.z; buf[o + 9] = bas.y.z; buf[o + 10] = bas.z.z; buf[o + 11] = p[i].y
			var c := Color.from_hsv(0.24 + rng.randf() * 0.06, 0.45 + rng.randf() * 0.15, 0.32 + rng.randf() * 0.12)
			if kind == "bikes":
				c = [Color("1b1b1b"), Color("2c4a6e"), Color("7a1e1e"), Color("2f5d3a"), Color("d9d4c7")][i % 5]
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = 1.0
		out[kind] = [p.size(), buf]
	return out


func _integrate(r: Dictionary) -> void:
	if r.get("failed", false) or not tiles.has(r.key):
		tiles.erase(r.key)
		return
	var root := Node3D.new()
	root.name = "tile_" + r.key
	var groups := {"buildings": Node3D.new(), "streets": Node3D.new(), "base": Node3D.new(), "trees": Node3D.new(), "furniture": Node3D.new()}
	for g in groups:
		groups[g].name = g
		root.add_child(groups[g])
		if show.has(g):
			groups[g].visible = show[g]
	# One mesh per group, one surface per material.
	var meshes := {"buildings": ArrayMesh.new(), "streets": ArrayMesh.new(), "base": ArrayMesh.new()}
	for name in r.surfaces:
		var s: Array = r.surfaces[name]
		if s[0].size() == 0:
			continue
		var g := "base"
		for p in BUILDING_MATS:
			if name.begins_with(p): g = "buildings"
		if name in STREET_MATS or name == "bridge_side": g = "streets"
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = s[0]; arrays[Mesh.ARRAY_NORMAL] = s[1]; arrays[Mesh.ARRAY_TEX_UV] = s[2]
		var m: ArrayMesh = meshes[g]
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		m.surface_set_material(m.get_surface_count() - 1, mats.get_mat(name))
	for g in meshes:
		if meshes[g].get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = meshes[g]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if g == "buildings" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		groups[g].add_child(mi)
	# Walls to walk into.
	if r.walls.size():
		var body := StaticBody3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.backface_collision = true
		shape.set_faces(r.walls)
		var cs := CollisionShape3D.new(); cs.shape = shape
		body.add_child(cs)
		root.add_child(body)
	# Trees and street furniture, instanced.
	for kind in r.instances:
		var n: int = r.instances[kind][0]
		if n == 0 or not _kit.has(kind):
			continue
		for part in _kit[kind]:
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = part[0]
			mm.instance_count = n
			var buf: PackedFloat32Array = r.instances[kind][1].duplicate()
			for i in n:
				buf[i * 16 + 7] = part[2]          # lift each part to its height
			mm.buffer = buf
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = part[1]
			groups["trees" if kind == "trees" else "furniture"].add_child(mmi)
	# Canal names, lying on the water.
	for l in r.labels:
		var lab := Label3D.new()
		lab.text = l[0]
		lab.font_size = 160
		lab.pixel_size = 0.02
		lab.modulate = Color(0.86, 0.93, 0.95, 0.85)
		lab.outline_size = 0
		lab.position = Vector3(l[1].x, 0.1, l[1].y)
		var ang := deg_to_rad(-float(l[2]))
		if absf(float(l[2])) > 90.0:
			ang += PI
		lab.rotation = Vector3(-PI / 2, ang, 0)
		lab.rotation_order = EULER_ORDER_YXZ
		root.add_child(lab)
	add_child(root)
	tiles[r.key] = {"state": "ready", "node": root, "result": r, "groups": groups}
	tile_added.emit(r.key, r)


func set_layer(layer: String, on: bool) -> void:
	show[layer] = on
	for t in tiles.values():
		if t.state == "ready":
			t.groups[layer].visible = on


# ---- queries --------------------------------------------------------------------

func tile_at(p: Vector3) -> Dictionary:
	var key := "%d_%d" % [floori(p.x / tile_size), floori(-p.z / tile_size)]
	var t = tiles.get(key)
	return t.result if t and t.state == "ready" else {}


## 0 = land, 1 = water, 2 = on a bridge.
func water_at(p: Vector3) -> int:
	var r := tile_at(p)
	if r.is_empty():
		return 0
	var q := Vector2(p.x, p.z)
	for line in r.bridges:
		for i in line.size() - 1:
			if Geometry2D.get_closest_point_to_segment(q, line[i], line[i + 1]).distance_to(q) < 3.5:
				return 2
	for rings in r.water:
		if Geometry2D.is_point_in_polygon(q, rings[0]):
			var in_hole := false
			for k in range(1, rings.size()):
				if Geometry2D.is_point_in_polygon(q, rings[k]):
					in_hole = true
			if not in_hole:
				return 1
	return 0


func nearest_name(p: Vector3, within := 35.0) -> String:
	var best := ""
	var bd := within
	for t in tiles.values():
		if t.state != "ready":
			continue
		for n in t.result.names:
			var d: float = n[0].distance_to(Vector2(p.x, p.z))
			if d < bd:
				bd = d; best = n[1]
	return best


func stats() -> Dictionary:
	var ready := 0; var buildings := 0
	for t in tiles.values():
		if t.state == "ready":
			ready += 1; buildings += t.result.buildings
	return {"ready": ready, "loading": tiles.size() - ready, "buildings": buildings}
