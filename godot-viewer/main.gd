extends Node3D
## Amsterdam District Viewer.
##
## Loads a district .glb written by build_city.py at runtime (Open button,
## drag-and-drop, or `-- --glb=path`), then lets you fly or walk through it,
## click a building to inspect it (BAG id, year, era, height, RD position),
## colour the district by era, and change the time of day.
##
## Headless screenshots for CI / docs:
##   godot --path godot-viewer -- --glb=../out/x.glb --shot=out.png --view=street [--era] [--select=N]
##   (--eye=x,y,z --target=x,y,z places the camera exactly, in scene metres)

# Preloaded rather than class_name'd, so a fresh checkout runs without the
# editor having built its global class cache first.
const FlyCamera := preload("res://fly_camera.gd")
const GlbMeta := preload("res://glb_meta.gd")

const ERAS := [
	{"name": "Golden Age (< 1720)", "max": 1720, "color": Color(0.95, 0.65, 0.15)},
	{"name": "Classic (1720–1900)", "max": 1900, "color": Color(0.30, 0.65, 0.95)},
	{"name": "Amsterdam School (1900–1945)", "max": 1945, "color": Color(0.75, 0.35, 0.85)},
	{"name": "Post-war (1945+)", "max": 100000, "color": Color(0.35, 0.80, 0.45)},
]
const UNKNOWN_ERA := {"name": "Unknown year", "color": Color(0.6, 0.6, 0.6)}

var cam: FlyCamera
var sun: DirectionalLight3D
var env: Environment
var district: Node3D
var meta: GlbMeta
var buildings: Array[MeshInstance3D] = []
var info: Dictionary = {}          # MeshInstance3D -> {id, year, tris}
var selected: MeshInstance3D
var era_materials: Array[StandardMaterial3D] = []
var select_material: StandardMaterial3D
var bounds := AABB()

var ui := {}                       # name -> Control
var _args := {}
var _shot_frames := -1


func _init() -> void:
	RenderingServer.set_debug_generate_wireframes(true)


func _ready() -> void:
	_args = _parse_args()
	_build_world()
	_build_materials()
	_build_ui()
	get_window().files_dropped.connect(func(files: PackedStringArray) -> void:
		for f in files:
			if f.to_lower().ends_with(".glb"):
				load_district(f)
				return)
	var path: String = _args.get("glb", "")
	if path == "":
		path = ProjectSettings.globalize_path("res://").path_join("../out/sample_canal.glb").simplify_path()
	elif path.is_relative_path():
		path = ProjectSettings.globalize_path("res://").path_join(path).simplify_path()
	if FileAccess.file_exists(path):
		load_district(path)
	else:
		_set_status("Open a .glb from build_city.py (button, or drag it onto the window).")
	if _args.has("shot"):
		_shot_frames = 3


# --------------------------------------------------------------------------
# World

func _build_world() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.5, 0.75)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.85)
	sky_mat.ground_horizon_color = Color(0.6, 0.62, 0.64)
	sky_mat.ground_bottom_color = Color(0.25, 0.25, 0.26)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.85
	env.ambient_light_sky_contribution = 0.75
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 1.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.78, 0.85)
	env.fog_density = 0.0006
	env.fog_aerial_perspective = 0.4
	env.glow_enabled = true
	env.glow_intensity = 0.3
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.95, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 350.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_bias = 0.03
	add_child(sun)
	set_time_of_day(14.5)

	cam = FlyCamera.new()
	add_child(cam)
	cam.current = true
	cam.look_from(Vector3(60, 80, 120), Vector3.ZERO)


## Rough Amsterdam sun: rises in the east at 6, peaks south at 13:30, sets
## in the west at 21. Good enough to read facades in different light.
func set_time_of_day(hour: float) -> void:
	var t := clampf((hour - 6.0) / 15.0, 0.0, 1.0)
	var elevation := deg_to_rad(4.0 + 54.0 * sin(t * PI))
	var azimuth := deg_to_rad(lerpf(80.0, 290.0, t))   # compass bearing
	var dir := Vector3(sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation))
	sun.look_at_from_position(Vector3.ZERO, -dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
	var warm := 1.0 - clampf(rad_to_deg(elevation) / 30.0, 0.0, 1.0)
	sun.light_color = Color(1.0, 0.95 - 0.25 * warm, 0.88 - 0.4 * warm)
	sun.light_energy = 0.6 + 0.9 * sin(elevation)


# --------------------------------------------------------------------------
# Loading

func load_district(path: String) -> void:
	_clear()
	var t0 := Time.get_ticks_msec()
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		_set_status("Could not read %s (error %d)" % [path.get_file(), err])
		return
	print("parsed glb: %d ms" % (Time.get_ticks_msec() - t0))
	district = doc.generate_scene(state) as Node3D
	print("scene generated: %d ms" % (Time.get_ticks_msec() - t0))
	add_child(district)
	_add_mipmaps(district)
	print("mipmaps: %d ms" % (Time.get_ticks_msec() - t0))
	meta = GlbMeta.new()
	meta.read(path)
	var total_tris := 0
	bounds = AABB()
	var first := true
	# generate_scene swaps the importer's nodes for MeshInstance3Ds, so
	# state.get_scene_node() points at freed objects. build_city.py writes one
	# root node per building in glTF node order, which is the child order here.
	var by_name := {}
	for k in meta.nodes.size():
		by_name[meta.name_of(k).validate_node_name()] = k
	var children := district.get_children()
	for k in children.size():
		if not children[k] is MeshInstance3D:
			continue
		var mi := children[k] as MeshInstance3D
		var i := k if meta.name_of(k).validate_node_name() == str(mi.name) else int(by_name.get(str(mi.name), -1))
		var tris := _triangles(mi.mesh)
		total_tris += tris
		var box := mi.global_transform * mi.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
		var gltf_name := meta.name_of(i) if meta.ok else str(mi.name)
		mi.create_trimesh_collision()       # picking and walk mode
		if gltf_name == "ground":
			continue
		var extras := meta.extras(i) if meta.ok else {}
		info[mi] = {"id": gltf_name, "year": extras.get("year", null), "tris": tris}
		buildings.append(mi)
	_set_status("%s · %d buildings · %s triangles · %.1f s" % [
		path.get_file(), buildings.size(), _thousands(total_tris),
		(Time.get_ticks_msec() - t0) / 1000.0])
	ui.era_legend.visible = ui.era.button_pressed
	_apply_era(ui.era.button_pressed)
	view("aerial", false)
	var sel := int(_args.get("select", "-1"))
	if sel >= 0 and sel < buildings.size():
		select(buildings[sel])


## Textures loaded at runtime arrive without mipmaps, which makes cobbles and
## brick shimmer at a distance. Rebuild each one once, shared by all users.
func _add_mipmaps(root: Node) -> void:
	var done := {}
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as BaseMaterial3D
			if mat == null or done.has(mat):
				continue
			done[mat] = true
			for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL]:
				var tex := mat.get_texture(slot)
				if tex == null:
					continue
				var img := tex.get_image()
				if img == null or img.has_mipmaps():
					continue
				if img.is_compressed():
					img.decompress()
				img.generate_mipmaps()
				mat.set_texture(slot, ImageTexture.create_from_image(img))
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


func _clear() -> void:
	select(null)
	if district:
		district.queue_free()
		district = null
	buildings.clear()
	info.clear()


func _triangles(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var idx = arrays[Mesh.ARRAY_INDEX]
		n += (idx.size() if idx != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return n


# --------------------------------------------------------------------------
# Views, picking, era colours

func view(kind: String, animate := true) -> void:
	if bounds.size == Vector3.ZERO:
		return
	var c := bounds.get_center()
	var eye: Vector3
	var target: Vector3
	match kind:
		"street":
			eye = Vector3(c.x - 30, bounds.position.y + 1.7, c.z + 4)
			target = Vector3(c.x + 10, bounds.position.y + 8, c.z - 12)
		"gable":
			eye = Vector3(c.x + 6, bounds.position.y + 6, c.z + 2)
			target = Vector3(c.x + 6, bounds.position.y + 12, c.z - 16)
		_:
			var r := maxf(bounds.size.x, bounds.size.z)
			eye = c + Vector3(r * 0.35, r * 0.42, r * 0.6)
			target = Vector3(c.x, bounds.position.y + 4, c.z)
	if animate:
		cam.fly_to(eye, target)
	else:
		cam.look_from(eye, target)


func era_of(year) -> Dictionary:
	if year == null:
		return UNKNOWN_ERA
	for e in ERAS:
		if int(year) < e.max:
			return e
	return UNKNOWN_ERA


func _build_materials() -> void:
	for e in ERAS + [UNKNOWN_ERA]:
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(e.color, 0.85)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		era_materials.append(m)
	select_material = StandardMaterial3D.new()
	select_material.albedo_color = Color(1.0, 0.2, 0.55, 0.6)
	select_material.emission_enabled = true
	select_material.emission = Color(1.0, 0.15, 0.5)
	select_material.emission_energy_multiplier = 0.8
	select_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


func _overlay_for(mi: MeshInstance3D) -> Material:
	if mi == selected:
		return select_material
	if not ui.era.button_pressed:
		return null
	var e := era_of(info[mi].year)
	var i := ERAS.find(e)
	return era_materials[i if i >= 0 else ERAS.size()]


func _apply_era(_on: bool) -> void:
	for mi in buildings:
		mi.material_overlay = _overlay_for(mi)


func select(mi: MeshInstance3D) -> void:
	var previous := selected
	selected = mi
	if previous and is_instance_valid(previous):
		previous.material_overlay = _overlay_for(previous)
	if mi == null:
		if ui.has("selection"):
			ui.selection.text = "Click a building to inspect it."
		return
	mi.material_overlay = select_material
	var d: Dictionary = info[mi]
	var box := mi.global_transform * mi.get_aabb()
	var e := era_of(d.year)
	var rd := meta.to_rd(box.get_center()) if meta and meta.ok else Vector3.ZERO
	var ground_rd := meta.to_rd(box.position).z if meta and meta.ok else box.position.y
	ui.selection.text = "\n".join([
		str(d.id),
		"Built: %s  (%s)" % [str(int(d.year)) if d.year != null else "?", e.name],
		"Height: %.1f m   Footprint: %.1f × %.1f m" % [box.size.y, box.size.x, box.size.z],
		"Ground: %.2f m NAP" % ground_rd,
		"RD New: %.1f, %.1f" % [rd.x, rd.y],
		"Triangles: %s" % _thousands(d.tris),
	])


func fly_to_building(mi: MeshInstance3D) -> void:
	var box := mi.global_transform * mi.get_aabb()
	var c := box.get_center()
	var r := maxf(box.size.length(), 12.0)
	cam.fly_to(c + Vector3(r * 0.6, r * 0.35, r * 0.9), c)
	select(mi)


func _find(query: String) -> void:
	query = query.strip_edges().to_lower()
	if query == "":
		return
	for mi in buildings:
		if str(info[mi].id).to_lower().contains(query):
			fly_to_building(mi)
			return
	_set_status("No building matches \"%s\"" % query)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var mp: Vector2 = event.position
		var from := cam.project_ray_origin(mp)
		var to := from + cam.project_ray_normal(mp) * 3000.0
		var hit := get_world_3d().direct_space_state.intersect_ray(
			PhysicsRayQueryParameters3D.create(from, to))
		var mi: MeshInstance3D = null
		if not hit.is_empty():
			mi = hit.collider.get_parent() as MeshInstance3D
		select(mi if mi in info else null)
		if event.double_click and mi in info:
			fly_to_building(mi)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_F:
				ui.walk.button_pressed = not ui.walk.button_pressed
			KEY_C:
				ui.era.button_pressed = not ui.era.button_pressed
			KEY_F12:
				_screenshot(OS.get_user_data_dir().path_join("shot_%d.png" % Time.get_unix_time_from_system()))
			KEY_H:
				ui.panel.visible = not ui.panel.visible
			KEY_ESCAPE:
				select(null)


func _process(_delta: float) -> void:
	if meta and meta.ok and ui.has("coords"):
		var rd := meta.to_rd(cam.global_position)
		ui.coords.text = "Camera RD %.0f, %.0f · %.1f m · speed %.0f m/s%s" % [
			rd.x, rd.y, rd.z, cam.speed, "  · WALK" if cam.walk else ""]
	if _shot_frames > 0:
		_shot_frames -= 1
		if _shot_frames == 0:
			_take_requested_shot()


func _take_requested_shot() -> void:
	view(_args.get("view", "aerial"), false)
	if _args.has("eye") and _args.has("target"):
		cam.look_from(_vec(_args.eye), _vec(_args.target))
	if _args.has("era"):
		ui.era.button_pressed = true
	if _args.has("nopanel"):
		ui.panel.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_screenshot(_args.shot)
	get_tree().quit()


func _screenshot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot %s -> %s" % ["ok" if err == OK else "FAILED", path])


# --------------------------------------------------------------------------
# UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	panel.custom_minimum_size = Vector2(330, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.1, 0.82)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	ui.panel = panel
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = "Amsterdam District Viewer"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)
	ui.status = _label(box, "", 12, Color(0.75, 0.78, 0.8))
	ui.status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var row := HBoxContainer.new()
	box.add_child(row)
	var open := Button.new()
	open.text = "Open .glb…"
	open.pressed.connect(_open_dialog)
	row.add_child(open)
	for v in ["aerial", "street", "gable"]:
		var b := Button.new()
		b.text = v.capitalize()
		b.pressed.connect(view.bind(v))
		row.add_child(b)

	var search := LineEdit.new()
	search.placeholder_text = "Find building by BAG id…"
	search.text_submitted.connect(func(t: String) -> void:
		_find(t)
		search.release_focus())
	box.add_child(search)

	_label(box, "Time of day", 12, Color(0.75, 0.78, 0.8))
	var tod := HSlider.new()
	tod.min_value = 6.0
	tod.max_value = 21.0
	tod.step = 0.25
	tod.value = 14.5
	tod.value_changed.connect(set_time_of_day)
	box.add_child(tod)

	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	ui.era = _check(grid, "Colour by era (C)", false, func(on: bool) -> void:
		ui.era_legend.visible = on
		_apply_era(on))
	ui.walk = _check(grid, "Walk mode (F)", false, func(on: bool) -> void:
		cam.walk = on
		if on and bounds.size != Vector3.ZERO:
			cam.global_position.y = bounds.position.y + FlyCamera.EYE_HEIGHT)
	_check(grid, "Shadows", true, func(on: bool) -> void: sun.shadow_enabled = on)
	_check(grid, "Ambient occlusion", true, func(on: bool) -> void: env.ssao_enabled = on)
	_check(grid, "Fog", true, func(on: bool) -> void: env.fog_enabled = on)
	_check(grid, "Wireframe", false, func(on: bool) -> void:
		get_viewport().debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if on else Viewport.DEBUG_DRAW_DISABLED)

	ui.era_legend = VBoxContainer.new()
	ui.era_legend.visible = false
	box.add_child(ui.era_legend)
	for e in ERAS + [UNKNOWN_ERA]:
		var l := HBoxContainer.new()
		var swatch := ColorRect.new()
		swatch.color = e.color
		swatch.custom_minimum_size = Vector2(14, 14)
		l.add_child(swatch)
		_label(l, e.name, 12, Color.WHITE)
		ui.era_legend.add_child(l)

	box.add_child(HSeparator.new())
	ui.selection = _label(box, "Click a building to inspect it.", 13, Color.WHITE)
	box.add_child(HSeparator.new())
	_label(box, "Right-drag look · WASD move · Q/E down/up · Shift fast\n"
		+ "Wheel: speed · Click: select · Double-click: fly to · F12: screenshot\n"
		+ "H: hide panel · Drop a .glb on the window to open it", 11, Color(0.6, 0.63, 0.66))

	ui.coords = Label.new()
	ui.coords.add_theme_font_size_override("font_size", 12)
	ui.coords.add_theme_color_override("font_shadow_color", Color.BLACK)
	ui.coords.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)
	ui.coords.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ui.coords.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(ui.coords)

	ui.dialog = FileDialog.new()
	ui.dialog.access = FileDialog.ACCESS_FILESYSTEM
	ui.dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	ui.dialog.filters = PackedStringArray(["*.glb ; glTF binary"])
	ui.dialog.size = Vector2i(900, 600)
	ui.dialog.file_selected.connect(load_district)
	add_child(ui.dialog)


func _open_dialog() -> void:
	ui.dialog.popup_centered()


func _label(parent: Node, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _check(parent: Node, text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	c.focus_mode = Control.FOCUS_NONE
	parent.add_child(c)
	return c


func _set_status(text: String) -> void:
	if ui.has("status"):
		ui.status.text = text
	print(text)


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


func _vec(csv: String) -> Vector3:
	var p := csv.split(",")
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _parse_args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else "true"
	return out
