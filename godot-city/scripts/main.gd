extends Node3D
## Amsterdam from open data: the city streams in around the camera, cars,
## GVB buses and trams drive the real street and track network, and you can
## drop down and walk.
##   Map mode:  drag to pan, right-drag to rotate, wheel/pinch to zoom.
##   Walk mode: WASD, Shift runs, Space jumps, mouse looks, Esc frees the mouse.
## Test arguments (after `--`): --shot=out.png --view=map|tram|walk --hour=17 --wait=12

const Materials := preload("res://scripts/materials.gd")
const Streamer := preload("res://scripts/city_streamer.gd")
const Traffic := preload("res://scripts/traffic.gd")
const MapCamera := preload("res://scripts/map_camera.gd")
const Walker := preload("res://scripts/walker.gd")
const Models := preload("res://scripts/vehicle_models.gd")

var mats
var streamer
var traffic
var cam: Camera3D
var walker
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ProceduralSkyMaterial
var hour := 15.5
var mode := "map"
var ui := {}
var args := {}
var _shot_t := -1.0
var _follow = null
var traffic_on := true


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	hour = float(args.get("hour", hour))

	_world()
	mats = Materials.new()
	mats.build()
	streamer = Streamer.new()
	add_child(streamer)
	streamer.setup(mats)
	traffic = Traffic.new()
	add_child(traffic)
	streamer.tile_added.connect(func(key, r): traffic.add_tile(key, r.lanes))
	streamer.tile_removed.connect(func(key): traffic.remove_tile(key))

	cam = MapCamera.new()
	add_child(cam)
	cam.current = true
	var start: Vector3 = streamer.start_point()
	cam.target = start
	cam.dist = 900.0
	cam.yaw = deg_to_rad(20)
	walker = Walker.new()
	add_child(walker)
	walker.setup(streamer, cam)

	_ui()
	_set_hour(hour)
	if args.has("shot"):
		_shot_t = float(args.get("wait", "14"))
		streamer.radius = 1600.0
		match args.get("view", "map"):
			"map":
				cam.dist = float(args.get("dist", "650")); cam.pitch = deg_to_rad(float(args.get("pitch", "58")))
			"walk":
				_set_mode("walk")
			"tram":
				cam.dist = 140.0; cam.pitch = deg_to_rad(64)


func _world() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ProceduralSkyMaterial.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_begin = 1400.0
	env.fog_depth_end = 3600.0
	env.fog_sky_affect = 0.0
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.glow_enabled = true
	env.glow_hdr_threshold = 1.2
	env.tonemap_exposure = 0.92
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	add_child(sun)


func _set_hour(h: float) -> void:
	hour = h
	# Amsterdam in early autumn: sunrise ~7:30, sunset ~19:00, low southern sun.
	var day := clampf((h - 7.3) / (19.2 - 7.3), 0.0, 1.0)
	var elev := sin(day * PI) * deg_to_rad(38.0)
	var night := clampf(1.0 - (sin(day * PI) * 6.0 + (0.0 if h > 7.0 and h < 19.6 else -1.0)), 0.0, 1.0)
	if h < 6.8 or h > 19.8:
		night = 1.0
	var azim := deg_to_rad(lerpf(100.0, 260.0, day))       # east -> south -> west
	var warm := clampf(1.0 - sin(day * PI) * 2.2, 0.0, 1.0)
	if night > 0.5:                     # moonlight: dim, cool, from high in the south
		sun.rotation = Vector3(deg_to_rad(-40), deg_to_rad(200), 0)
		sun.light_color = Color(0.62, 0.72, 1.0)
		sun.light_energy = 0.22
	else:
		sun.rotation = Vector3(-maxf(elev, deg_to_rad(4)), PI - azim, 0)
		sun.light_color = Color(1.0, 0.96, 0.9).lerp(Color(1.0, 0.62, 0.38), warm)
		sun.light_energy = lerpf(1.1, 0.2, night * 2.0)
	sky_mat.sky_top_color = Color("3d6fae").lerp(Color("0b1224"), night)
	sky_mat.sky_horizon_color = Color("a9bfd6").lerp(Color("e8a070"), warm * (1.0 - night)).lerp(Color("2a3046"), night)
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky_mat.ground_bottom_color = Color("40464c").lerp(Color("0c0e14"), night)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0 - night * 0.6
	env.ambient_light_color = Color("3a4766")
	env.ambient_light_energy = lerpf(0.6, 0.9, night)
	env.fog_light_color = sky_mat.sky_horizon_color
	env.glow_intensity = lerpf(0.4, 1.0, night)
	mats.set_night(night)
	Models.set_night(night)
	if ui.has("hour"):
		ui.hour_label.text = "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60)]


# ---- UI ---------------------------------------------------------------------------

func _ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(14, 14)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.82); sb.set_corner_radius_all(8); sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var title := Label.new()
	title.text = "Amsterdam"
	title.add_theme_font_size_override("font_size", 22)
	box.add_child(title)

	var modes := HBoxContainer.new()
	box.add_child(modes)
	for m in ["map", "walk"]:
		var b := Button.new()
		b.text = "Map" if m == "map" else "Walk (G)"
		b.toggle_mode = true
		b.button_pressed = m == mode
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_mode.bind(m))
		modes.add_child(b)
		ui["mode_" + m] = b

	var hrow := HBoxContainer.new()
	box.add_child(hrow)
	var hl := Label.new(); hl.custom_minimum_size.x = 52
	hrow.add_child(hl)
	ui.hour_label = hl
	var slider := HSlider.new()
	slider.min_value = 0; slider.max_value = 24; slider.step = 0.05; slider.value = hour
	slider.custom_minimum_size.x = 190
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(_set_hour)
	hrow.add_child(slider)
	ui.hour = slider

	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for l in ["buildings", "streets", "trees", "furniture"]:
		var c := CheckBox.new()
		c.text = l.capitalize(); c.button_pressed = true; c.focus_mode = Control.FOCUS_NONE
		c.toggled.connect(func(on): streamer.set_layer(l, on))
		grid.add_child(c)
	var tc := CheckBox.new()
	tc.text = "Traffic"; tc.button_pressed = true; tc.focus_mode = Control.FOCUS_NONE
	tc.toggled.connect(func(on):
		traffic_on = on
		if not on: traffic.clear())
	grid.add_child(tc)
	var fc := Button.new()
	fc.text = "Ride a tram"; fc.focus_mode = Control.FOCUS_NONE
	fc.pressed.connect(_ride)
	grid.add_child(fc)

	var stats := Label.new()
	stats.add_theme_font_size_override("font_size", 13)
	stats.modulate = Color(0.8, 0.84, 0.9)
	box.add_child(stats)
	ui.stats = stats
	var help := Label.new()
	help.add_theme_font_size_override("font_size", 12)
	help.modulate = Color(0.62, 0.66, 0.72)
	box.add_child(help)
	ui.help = help

	var area := Label.new()
	area.add_theme_font_size_override("font_size", 26)
	area.add_theme_color_override("font_outline_color", Color.BLACK)
	area.add_theme_constant_override("outline_size", 6)
	area.anchor_left = 1.0; area.anchor_right = 1.0; area.anchor_top = 1.0; area.anchor_bottom = 1.0
	area.offset_left = -520; area.offset_right = -24; area.offset_top = -64; area.offset_bottom = -20
	area.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	layer.add_child(area)
	ui.area = area
	_help()


func _help() -> void:
	ui.help.text = ("Drag: pan   Right-drag / Q E R F: rotate & tilt\nWheel or pinch: zoom   WASD: move   G: walk here"
		if mode == "map" else
		"WASD: walk   Shift: run   Space: jump\nMouse: look   Wheel: camera distance   Esc: mouse   G: map")


func _set_mode(m: String) -> void:
	_follow = null
	if m == mode:
		ui["mode_" + m].button_pressed = true
		return
	mode = m
	ui.mode_map.button_pressed = m == "map"
	ui.mode_walk.button_pressed = m == "walk"
	if m == "walk":
		cam.active = false
		var at: Vector3 = cam.target
		if streamer.water_at(at) == 1 or not walker._free(at):
			at = _nearest_street(at)
		walker.enter(at, cam.yaw)
	else:
		walker.leave()
		cam.active = true
		cam.target = walker.global_position
		cam.dist = 260.0
	_help()


# A point on the nearest walkable lane, so you never start inside a house.
func _nearest_street(p: Vector3) -> Vector3:
	var best := p
	var bd := INF
	for t in streamer.tiles.values():
		if t.state != "ready":
			continue
		for lane in t.result.lanes:
			if lane.kind != "road" and lane.kind != "walk":
				continue
			var pts: PackedVector2Array = lane.p
			for i in pts.size() - 1:
				var q := Geometry2D.get_closest_point_to_segment(Vector2(p.x, p.z), pts[i], pts[i + 1])
				var d := q.distance_to(Vector2(p.x, p.z))
				if d < bd:
					bd = d; best = Vector3(q.x, 0, q.y)
	return best


# Follow the nearest tram with the map camera.
func _ride() -> void:
	var best = null
	var bd := INF
	for v in traffic.vehicles:
		if v.kind != "tram":
			continue
		var d: float = v.pos.distance_to(Vector2(cam.target.x, cam.target.z))
		if d < bd:
			bd = d; best = v
	if best == null:
		return
	if mode == "walk":
		_set_mode("map")
	_follow = best
	cam.dist = 75.0
	cam.pitch = deg_to_rad(52)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_G:
			_set_mode("map" if mode == "walk" else "walk")
		elif event.physical_keycode == KEY_ESCAPE and mode == "walk":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and event.pressed and _follow != null and event.button_index == MOUSE_BUTTON_LEFT:
		_follow = null


func _process(delta: float) -> void:
	var focus: Vector3
	if mode == "walk":
		focus = walker.global_position
		streamer.radius = 1100.0
		traffic.player = walker.global_position
		var n: String = streamer.nearest_name(focus)
		if n != "":
			ui.area.text = n
	else:
		if _follow != null:
			if not traffic.vehicles.has(_follow):
				_follow = null
			else:
				var p: Vector2 = _follow.pos
				cam.target = cam.target.lerp(Vector3(p.x, 0, p.y), 1.0 - exp(-delta * 4.0))
				cam.yaw = lerp_angle(cam.yaw, float(_follow.get("yaw", cam.yaw)), 1.0 - exp(-delta * 1.5))
		focus = cam.target
		if not args.has("shot"):
			streamer.radius = clampf(cam.dist * 0.9, 1000.0, 2800.0)
		traffic.player = Vector3(1e9, 0, 1e9)
		ui.area.text = streamer.nearest_name(focus, 60.0) if cam.dist < 500.0 else ""
	streamer.focus = focus
	traffic.focus = focus
	traffic.enabled = traffic_on and (mode == "walk" or cam.dist < 1600.0)
	var s: Dictionary = streamer.stats()
	var c: Dictionary = traffic.count()
	ui.stats.text = "%d tiles (%d loading) · %s buildings\n%d cars · %d buses · %d trams · %d fps" % [
		s.ready, s.loading, _thousands(s.buildings), c.car, c.bus, c.tram, Engine.get_frames_per_second()]
	sun.global_position = focus
	if _shot_t >= 0.0:
		_shot_t -= delta
		if Engine.get_process_frames() % 20 == 0:
			print("t=%.1f %s" % [_shot_t, ui.stats.text.replace("\n", " | ")])
		if args.get("view") == "tram" and _follow == null and traffic.count().tram > 0 and _shot_t < 6.0:
			_ride()
		if _shot_t < 0.0:
			var img := get_viewport().get_texture().get_image()
			img.save_png(args.shot)
			print("shot saved: ", args.shot, " ", ui.stats.text.replace("\n", " | "))
			get_tree().quit()


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
