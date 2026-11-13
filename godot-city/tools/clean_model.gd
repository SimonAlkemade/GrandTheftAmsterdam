extends SceneTree
## A generated model (Tripo and the like) made ready for the game: only its
## largest connected piece kept (the stray fragments a generator leaves round
## its subject go), stood on the ground with its foot at the origin, its
## textures shrunk to SIZE px and stored as lossy WebP.
##     godot --headless --path godot-city --script tools/clean_model.gd -- \
##         ../assets-src/landmarks/dam_monument_source.glb models/dam_monument.glb

const SIZE := 1024


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var src := args[0] if args[0].is_absolute_path() else ProjectSettings.globalize_path("res://" + args[0])
	var dst := args[1] if args[1].is_absolute_path() else ProjectSettings.globalize_path("res://" + args[1])
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(src, state) != OK:
		push_error("cannot read " + src)
		quit(1)
		return
	var scene: Node3D = doc.generate_scene(state)
	var mi: MeshInstance3D = scene.find_children("*", "MeshInstance3D", true, false)[0]
	var mesh: Mesh = mi.mesh
	var arrays := mesh.surface_get_arrays(0)
	var mat: Material = mesh.surface_get_material(0)
	var kept := _largest_piece(arrays)
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, kept)
	out.surface_set_material(0, _shrunk(mat))
	var root := Node3D.new()
	root.name = scene.name
	var m := MeshInstance3D.new()
	m.name = "model"
	m.mesh = out
	root.add_child(m)
	m.owner = root
	var w := GLTFDocument.new()
	w.image_format = "Lossy WebP"
	w.lossy_quality = 0.8
	var ws := GLTFState.new()
	w.append_from_scene(root, ws)
	var err := w.write_to_filesystem(ws, dst)
	print("%s: %d of %d triangles kept, %s" % [dst.get_file(), (kept[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3,
		(arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3, "written" if err == OK else "FAILED %d" % err])
	quit(0 if err == OK else 1)


# The surface's largest piece (triangles joined through shared corners, by
# position: a seam in the texture does not split a piece), moved so its foot
# is at the origin.
func _largest_piece(a: Array) -> Array:
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX]
	var parent := PackedInt32Array()
	parent.resize(v.size())
	for i in v.size():
		parent[i] = i
	var find := func(x: int) -> int:
		while parent[x] != x:
			parent[x] = parent[parent[x]]
			x = parent[x]
		return x
	var at := {}
	for i in v.size():
		var k := Vector3i(roundi(v[i].x * 1e5), roundi(v[i].y * 1e5), roundi(v[i].z * 1e5))
		if at.has(k):
			parent[find.call(i)] = find.call(at[k])
		else:
			at[k] = i
	for tri in idx.size() / 3:
		var r0: int = find.call(idx[tri * 3])
		parent[find.call(idx[tri * 3 + 1])] = r0
		parent[find.call(idx[tri * 3 + 2])] = r0
	var count := {}
	for tri in idx.size() / 3:
		var r: int = find.call(idx[tri * 3])
		count[r] = count.get(r, 0) + 1
	var best: int = count.keys().reduce(func(x, y): return x if count[x] >= count[y] else y)
	# The kept triangles, their corners renumbered.
	var remap := {}
	var new_idx := PackedInt32Array()
	for tri in idx.size() / 3:
		if find.call(idx[tri * 3]) != best:
			continue
		for j in 3:
			var o: int = idx[tri * 3 + j]
			if not remap.has(o):
				remap[o] = remap.size()
			new_idx.append(remap[o])
	var order: Array = remap.keys()
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	for t in Mesh.ARRAY_MAX:
		if a[t] == null or t == Mesh.ARRAY_INDEX:
			continue
		var src = a[t]
		var per: int = src.size() / v.size()       # (tangents: 4 floats a corner)
		var dst = src.duplicate()
		dst.resize(order.size() * per)
		for n in order.size():
			for c in per:
				dst[n * per + c] = src[int(order[n]) * per + c]
		out[t] = dst
	out[Mesh.ARRAY_INDEX] = new_idx
	# Its foot at the origin.
	var verts: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	var box := AABB(verts[0], Vector3.ZERO)
	for p in verts:
		box = box.expand(p)
	var shift := Vector3(box.get_center().x, box.position.y, box.get_center().z)
	for n in verts.size():
		verts[n] -= shift
	out[Mesh.ARRAY_VERTEX] = verts
	return out


func _shrunk(mat: Material) -> Material:
	if not mat is BaseMaterial3D:
		return mat
	var m: BaseMaterial3D = mat.duplicate()
	for p in ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture", "orm_texture"]:
		if not p in m:
			continue
		var tex: Texture2D = m.get(p)
		if tex == null:
			continue
		var img := tex.get_image()
		if img.is_compressed():
			img.decompress()
		if img.get_width() > SIZE:
			img.resize(SIZE, SIZE * img.get_height() / img.get_width(), Image.INTERPOLATE_LANCZOS)
		m.set(p, ImageTexture.create_from_image(img))
	return m
