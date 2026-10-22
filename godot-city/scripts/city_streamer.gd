extends Node3D
## Streams the city around `focus` in chunks (375 m; chunk_godot_tiles.py
## cuts them), nearest first, and drops them again behind you. A chunk lives
## in its 1.5 km tile file, which is read once while any of its chunks is
## wanted. Reading and meshing happen on WorkerThreadPool threads; the main
## thread only turns finished arrays into nodes, one chunk per frame. (Data
## without chunks streams whole tiles the same way.) In this script a "tile"
## is the streamed unit, a chunk.

signal tile_added(key: String, result: Dictionary)
signal tile_removed(key: String)

const TileBuilder := preload("res://scripts/tile_builder.gd")
const BUILDING_MATS := ["facade_", "ground_home_", "ground_shop_", "trim_", "office", "boat", "roof_"]
const STREET_MATS := ["road", "bike", "walk", "tram", "rail", "rails", "bridge"]
const MINI_CELL := 64.0
const BIKE_CELL := 100.0     # parked bikes are drawn per block of this size...
const BIKE_SEEN := 140.0     # ...and only this close to the camera
const JS_FETCH := """
window.amsFetch = function (path, id, binary) {
  fetch(path).then(function (r) {
    if (!r.ok) throw new Error(path + " returned " + r.status);
    return binary ? r.blob() : r.text();
  }).then(function (d) {
    if (!binary) { window.amsDone(id, 200, d); return; }
    var fr = new FileReader();
    fr.onload = function () { window.amsDone(id, 200, String(fr.result).split(",")[1] || ""); };
    fr.readAsDataURL(d);
  }).catch(function (e) {
    console.error("Amsterdam: could not load " + path, e);
    window.amsDone(id, 0, "");
  });
};
"""
# Minimap layers, drawn in this order, and the surfaces each is made of.
const MINI := {
	"water": ["water"], "green": ["park", "grass", "garden", "pitch"], "walk": ["walk", "plaza", "bike", "bridge"],
	"road": ["road"], "tram": ["tram"], "roof": ["roof_0", "roof_1", "roof_2", "roof_flat"],
}

var mats
var data_dir := "res://data/"
var index := {}
var tile_size := 1500.0      # the streamed unit: a chunk (or a whole tile in unchunked data)
var file_size := 1500.0      # a tile file
var tiles := {}              # chunk key -> { state, node, result }
var _files := {}             # tile file key -> its parsed data (null while a browser fetch is on its way)
var _file_mutex := Mutex.new()
var _per_file := 1           # chunks along a tile file's side
var focus := Vector3.ZERO
var radius := 1500.0
var show := {"buildings": true, "streets": true, "trees": true, "furniture": true}
var _done: Array = []
var _mutex := Mutex.new()
var _loading := 0
var _tick := 0.0
var _kit := {}
# In a browser there are no threads and no tile files on disk: tiles are
# fetched next to the page and built on the main thread, one per frame.
var _web := OS.has_feature("web")
var _fetched: Array = []
var _js_done                 # JavaScriptObject callback, kept alive here
var _js_pending := {}
var _js_next := 0
var failed := 0              # tiles that could not be loaded


func setup(materials) -> void:
	mats = materials
	var f := FileAccess.open(data_dir + "index.json", FileAccess.READ)
	if f == null:
		push_error("No city data in %s. Run prepare_godot_city.py first (see README)." % data_dir)
		return
	index = JSON.parse_string(f.get_as_text())
	file_size = float(index.tile)
	tile_size = float(index.get("chunk", index.tile))
	_per_file = int(round(file_size / tile_size))
	if _web:
		# The page's own fetch() resolves paths the way the host serves them;
		# an absolute URL built from location.href does not always.
		JavaScriptBridge.eval(JS_FETCH, true)
		_js_done = JavaScriptBridge.create_callback(_on_js_done)
		JavaScriptBridge.get_interface("window").amsDone = _js_done
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
	var set_image := func(bytes: PackedByteArray) -> void:
		var img := Image.new()
		if bytes.size() and img.load_jpg_from_buffer(bytes) == OK:
			img.generate_mipmaps()
			m.albedo_texture = ImageTexture.create_from_image(img)
	if _web:
		_http_get("data/overview.jpg", true, func(code: int, data: String):
			set_image.call(Marshalls.base64_to_raw(data) if code == 200 else PackedByteArray()))
	else:
		set_image.call(FileAccess.get_file_as_bytes(data_dir + "overview.jpg"))
	m.roughness = 1.0
	m.disable_fog = true
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = m
	mi.position = Vector3((x0 + x1) / 2, -3.0, (z0 + z1) / 2)   # below the canal water
	add_child(mi)


# The Blender bike (blender/make_bikes.py), low detail, with its paint taking
# each instance's colour so a rack of one mesh shows bikes of many colours.
func _parked_bike_mesh() -> Mesh:
	var sc: Node = load("res://models/bike_oma_parked.glb").instantiate()
	var mi: MeshInstance3D = sc.find_children("*", "MeshInstance3D", true, false)[0]
	var mesh: ArrayMesh = mi.mesh.duplicate()
	sc.free()
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i)
		if m and m.resource_name.begins_with("paint"):
			var p := StandardMaterial3D.new()
			p.vertex_color_use_as_albedo = true
			p.metallic = 0.3
			p.roughness = 0.35
			mesh.surface_set_material(i, p)
	return mesh


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
	var bike := _parked_bike_mesh()
	_kit = {
		"trees": [[cyl.call(0.22, 0.32, 5.0), mat.call("4b3a2c"), 2.5, false], [crown, leaves, 8.0, true]],
		"lamps": [[cyl.call(0.07, 0.11, 4.5), mat.call("1f3a2c", 0.6), 2.25, false], [cyl.call(0.22, 0.12, 0.42), mats.get_mat("lamp_glass"), 4.72, false]],
		"benches": [[bench, mat.call("5a3f2a"), 0.45, false]],
		"bikes": [[bike, null, 0.0, true]],
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
		# Integrate the finished chunk nearest to the focus first.
		var best := 0
		for i in _done.size():
			if _done[i].rect.get_center().distance_to(Vector2(focus.x, focus.z)) < _done[best].rect.get_center().distance_to(Vector2(focus.x, focus.z)):
				best = i
		r = _done[best]
		_done.remove_at(best)
	_mutex.unlock()
	if r != null:
		_integrate(r)
	elif _fetched.size():
		# Browser: build the nearest wanted chunk whose file has arrived.
		for n in _fetched.size():
			var key: String = _fetched[n]
			var fk := _file_of(key)
			if not _files.has(fk):
				_fetch_file(fk)
			elif _files[fk] != null:
				_fetched.remove_at(n)
				_build(key, _chunk_data(fk, key))
				break


func _tile_distance(i: int, j: int) -> float:
	var c := Vector2((i + 0.5) * tile_size, -(j + 0.5) * tile_size)
	return c.distance_to(Vector2(focus.x, focus.z)) - tile_size * 0.71


func _update_tiles() -> void:
	if index.is_empty():
		return
	var want := []
	for t in index.get("chunks", index.tiles):
		var d := _tile_distance(int(t[0]), int(t[1]))
		if d < radius:
			want.append([maxf(d, 0.0), "%d_%d" % [int(t[0]), int(t[1])]])
	want.sort_custom(func(a, b): return a[0] < b[0])
	for w in want:
		if _loading >= (8 if _web else 4):
			break
		if tiles.has(w[1]):
			continue
		tiles[w[1]] = {"state": "loading"}
		_loading += 1
		if _web:
			_fetched.append(w[1])
			_fetch_file(_file_of(w[1]))
		else:
			WorkerThreadPool.add_task(_task.bind(w[1]))
	# Drop chunks well behind you (the margin stops them flickering in and out).
	var keep := radius + maxf(500.0, tile_size)
	for key in tiles.keys():
		var t: Dictionary = tiles[key]
		if t.state == "loading":
			continue
		var ij: PackedStringArray = key.split("_")
		if _tile_distance(int(ij[0]), int(ij[1])) > keep:
			if t.state == "ready":
				t.node.queue_free()
				tile_removed.emit(key)
			tiles.erase(key)
	# Let go of tile files none of whose chunks are wanted any more.
	var needed := {}
	for key in tiles:
		needed[_file_of(key)] = true
	for key in _fetched:
		needed[_file_of(key)] = true
	_file_mutex.lock()
	for fk in _files.keys():
		if not needed.has(fk) and _files[fk] != null:
			_files.erase(fk)
	_file_mutex.unlock()


## The tile file a chunk lives in.
func _file_of(key: String) -> String:
	if _per_file == 1:
		return key
	var ij := key.split("_")
	return "%d_%d" % [floori(float(int(ij[0])) / _per_file), floori(float(int(ij[1])) / _per_file)]


## One chunk out of its parsed tile file (an unchunked file is its own chunk).
func _chunk_data(fk: String, key: String):
	var d = _files.get(fk)
	if typeof(d) != TYPE_DICTIONARY:
		return null
	if d.has("chunks"):
		return d.chunks.get(key)
	return d


# Browser: fetch a tile file once; its chunks are built as they come up.
func _fetch_file(fk: String) -> void:
	if _files.has(fk):
		return
	_files[fk] = null
	_http_get("data/tiles/%s.json" % fk, false, func(code: int, text: String):
		var d = JSON.parse_string(text) if code == 200 and text != "" else null
		_files[fk] = d if typeof(d) == TYPE_DICTIONARY else {})


# Fetch a file published next to the page; `done(code, text)` gets the text,
# or base64 for `binary`.
func _http_get(path: String, binary: bool, done: Callable) -> void:
	var id := _js_next
	_js_next += 1
	_js_pending[id] = done
	JavaScriptBridge.eval("window.amsFetch(%s, %d, %s)" % [JSON.stringify(path), id, "true" if binary else "false"], true)


func _on_js_done(args: Array) -> void:
	var id := int(args[0])
	var done: Callable = _js_pending.get(id, Callable())
	_js_pending.erase(id)
	if done.is_valid():
		done.call(int(args[1]), str(args[2]))


# Worker thread: mesh one chunk, reading its tile file first if no other
# chunk has (the lock makes the others wait for that one read).
func _task(key: String) -> void:
	var fk := _file_of(key)
	_file_mutex.lock()
	if not _files.has(fk):
		var f := FileAccess.open(data_dir + "tiles/%s.json" % fk, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text()) if f else null
		_files[fk] = d if typeof(d) == TYPE_DICTIONARY else {}
	var data = _chunk_data(fk, key)
	_file_mutex.unlock()
	_build(key, data)


func _build(key: String, data) -> void:
	var r := {}
	if typeof(data) == TYPE_DICTIONARY:
		r = TileBuilder.new().build_tile(data)
		r.instances = _instance_buffers(r.points, r.street_bikes)
		r.mini = _minimap_cells(r.surfaces)
	else:
		r = {"key": key, "failed": true, "rect": Rect2()}
		push_error("Could not load tile %s" % key)
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
func _instance_buffers(points: Dictionary, street_bikes: Array) -> Dictionary:
	var out := {}
	var rng := RandomNumberGenerator.new()
	for kind in points:
		var p: PackedVector2Array = points[kind]
		rng.seed = p.size() * 31 + kind.length()
		var yaws := PackedFloat32Array()
		if kind == "bikes":                  # three parked bikes side by side per rack
			var q := PackedVector2Array()
			for v in p:
				var rack := rng.randf() * TAU
				var side := Vector2(cos(rack), -sin(rack))
				for k in [-0.65, 0.0, 0.65]:
					q.append(v + side * k)
					yaws.append(rack + rng.randf_range(-0.08, 0.08))
			q.append_array(street_bikes[0])  # and the ones along the house fronts
			yaws.append_array(street_bikes[1])
			p = q
		var buf := PackedFloat32Array()
		buf.resize(p.size() * 16)
		for i in p.size():
			var s := 1.0
			var yaw := rng.randf() * TAU
			if kind == "trees":
				s = 0.75 + rng.randf() * 0.55
			if kind == "bikes":
				yaw = yaws[i]
			var bas := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
			var o := i * 16
			buf[o] = bas.x.x; buf[o + 1] = bas.y.x; buf[o + 2] = bas.z.x; buf[o + 3] = p[i].x
			buf[o + 4] = bas.x.y; buf[o + 5] = bas.y.y; buf[o + 6] = bas.z.y; buf[o + 7] = 0.0
			buf[o + 8] = bas.x.z; buf[o + 9] = bas.y.z; buf[o + 10] = bas.z.z; buf[o + 11] = p[i].y
			var c := Color.from_hsv(0.24 + rng.randf() * 0.06, 0.45 + rng.randf() * 0.15, 0.32 + rng.randf() * 0.12)
			if kind == "bikes":
				c = Color(["111214", "111214", "111214", "1d2a3a", "6b1e1e", "2f4f3a", "d8d2c4"][rng.randi() % 7])
			buf[o + 12] = c.r; buf[o + 13] = c.g; buf[o + 14] = c.b; buf[o + 15] = 1.0
		out[kind] = [p.size(), buf]
	return out


func _integrate(r: Dictionary) -> void:
	if not tiles.has(r.key):
		return
	if r.get("failed", false):
		tiles[r.key] = {"state": "failed"}    # don't retry it every 0.4 s
		failed += 1
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
	# The ground vehicles drive on (people keep to their own way of walking:
	# this is on its own collision layer).
	if r.get("ground_faces", PackedVector3Array()).size():
		var floor := StaticBody3D.new()
		floor.collision_layer = 2       # VehiclePhysics.GROUND_LAYER
		floor.collision_mask = 0
		var fshape := ConcavePolygonShape3D.new()
		fshape.backface_collision = true
		fshape.set_faces(r.ground_faces)
		var fcs := CollisionShape3D.new(); fcs.shape = fshape
		floor.add_child(fcs)
		root.add_child(floor)
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
	r.bike_mm = []
	for kind in r.instances:
		var n: int = r.instances[kind][0]
		if n == 0 or not _kit.has(kind):
			continue
		if kind == "bikes":
			_parked_bikes(r, groups["furniture"])
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
		lab.position = Vector3(l[1].x, float(r.get("water_y", 0.0)) + 0.05, l[1].y)   # on the water
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


# Parked bikes are many and detailed: one MultiMesh per block, each drawn only
# when the camera is near it, and none of them casting shadows.
func _parked_bikes(r: Dictionary, parent: Node3D) -> void:
	var n: int = r.instances.bikes[0]
	var buf: PackedFloat32Array = r.instances.bikes[1]
	var cells := {}
	for i in n:
		var k := Vector2i(floori(buf[i * 16 + 3] / BIKE_CELL), floori(buf[i * 16 + 11] / BIKE_CELL))
		if not cells.has(k):
			cells[k] = PackedFloat32Array()
		cells[k].append_array(buf.slice(i * 16, i * 16 + 16))
	for k in cells:
		var cb: PackedFloat32Array = cells[k]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _kit.bikes[0][0]
		mm.instance_count = cb.size() / 16
		mm.buffer = cb
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = BIKE_SEEN
		mmi.visibility_range_end_margin = 15.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		parent.add_child(mmi)
		r.bike_mm.append(mm)


## The parked bike nearest p within `within` metres: {tile, mm, i, at, yaw, color}, or {}.
func parked_bike(p: Vector2, within: float) -> Dictionary:
	var best := {}
	var bd := within
	for key in tiles:
		var t: Dictionary = tiles[key]
		if t.state != "ready" or not t.result.has("bike_mm"):
			continue
		var r: Dictionary = t.result
		if not (r.rect as Rect2).grow(within).has_point(p):
			continue
		var taken: Dictionary = r.get("taken", {})
		for m in r.bike_mm.size():
			var mm: MultiMesh = r.bike_mm[m]
			if not mm.get_aabb().grow(within + 2.0).has_point(Vector3(p.x, 0.5, p.y)):
				continue
			for i in mm.instance_count:
				if taken.has(Vector2i(m, i)):
					continue
				var xf := mm.get_instance_transform(i)
				var d := Vector2(xf.origin.x, xf.origin.z).distance_to(p)
				if d < bd:
					bd = d
					best = {"tile": key, "mm": m, "i": i, "at": Vector2(xf.origin.x, xf.origin.z), "yaw": xf.basis.get_euler().y,
						"color": mm.get_instance_color(i)}
	return best


## Take a parked bike off its rack (it stops being drawn there).
func take_bike(b: Dictionary) -> void:
	var r: Dictionary = tiles[b.tile].result
	var mm: MultiMesh = r.bike_mm[b.mm]
	var xf := mm.get_instance_transform(b.i)
	mm.set_instance_transform(b.i, Transform3D(Basis().scaled(Vector3.ZERO), xf.origin))
	if not r.has("taken"):
		r.taken = {}
	r.taken[Vector2i(b.mm, b.i)] = true


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
