extends Node3D
## Amsterdam from open data: the city streams in around the camera, cars,
## GVB buses and trams drive the real street and track network, and you can
## run around it on foot. You start on the Dam; M switches to the map.
##   On foot: WASD, Shift runs, Space jumps, mouse looks, Esc frees the mouse.
##   Driving: W drives, S brakes and reverses, Space is the handbrake.
##   Map:     drag to pan, right-drag to rotate, wheel/pinch to zoom.
## Test arguments (after `--`): --shot=out.png --view=map|tram|walk --hour=17
##   --wait=12 --run (walk mode: hold W and Shift, then turn, to test running)
##   --vehicle=car|canta|bike|rack|bus|tram|busdrive|tramdrive|boat|swim|damrak (get in, drive, get out)

const Materials := preload("res://scripts/materials.gd")
const Streamer := preload("res://scripts/city_streamer.gd")
const Traffic := preload("res://scripts/traffic.gd")
const MapCamera := preload("res://scripts/map_camera.gd")
const Walker := preload("res://scripts/walker.gd")
const Models := preload("res://scripts/vehicle_models.gd")
const Minimap := preload("res://scripts/minimap.gd")
const Mission := preload("res://scripts/mission.gd")
const Boats := preload("res://scripts/boats.gd")
const Crime := preload("res://scripts/crime.gd")
const CrimeHud := preload("res://scripts/crime_hud.gd")

var mats
var streamer
var traffic
var boats
var crime
var cam: Camera3D
var walker
var mission
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
var _pending_walk := false
var _walk_at := Vector3.ZERO
# The key help top left, for what you are doing.
const HINTS := {
	"foot": "WASD / arrows  move     Shift  run     Space  jump     E  get in or out of a vehicle or boat\nMouse  look     Wheel  zoom     M  map     Esc  free mouse",
	"car": "W  drive     S  brake / reverse     A D  steer     Space  handbrake     E  get out\nIn the air or on its side: A D roll it, W S tip it     Mouse  look     M  map",
	"bike": "W  pedal     S  back     A D  steer     Shift  pedal hard     Space  brake     E  get off\nMouse  look     M  map",
	"boat": "W  throttle     S  astern     A D  outboard     Shift  full power     E  get off\nMouse  look     M  map",
	"tram": "W  power     S  brake     Space  emergency brake     A D  left or right at the next points     E  get off\nMouse  look     M  map",
	"ride": "E  get off\nMouse  look     M  map",
}
# The Damrak basin by the Beurs, where its water comes nearest the Dam: a boat
# always waits at its quay there (scene metres: x east, z south).
const DAMRAK_BOAT := Vector2(172.0, -205.0)
var _damrak_boat := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	hour = float(args.get("hour", hour))

	_world()
	_screen_scale()
	mats = Materials.new()
	mats.build()
	streamer = Streamer.new()
	add_child(streamer)
	streamer.setup(mats)
	traffic = Traffic.new()
	add_child(traffic)
	streamer.tile_added.connect(func(key, r): traffic.add_tile(key, r.lanes))
	streamer.tile_removed.connect(func(key): traffic.remove_tile(key))
	boats = Boats.new()
	boats.streamer = streamer
	add_child(boats)

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
	walker.traffic = traffic
	walker.boats = boats
	traffic.street_y = streamer.street_y
	mission = Mission.new()
	add_child(mission)
	mission.setup(streamer, traffic, walker)
	crime = Crime.new()
	add_child(crime)
	crime.setup(streamer, traffic, walker, mission)
	walker.crime = crime

	_ui()
	_set_hour(hour)
	# Start on foot on the Dam, as soon as the ground there has loaded.
	_walk_at = start
	if args.has("at"):                    # --at=x,y in the data's decimetres (as search.json gives them)
		var xy: PackedStringArray = String(args.at).split(",")
		_walk_at = Vector3(float(xy[0]) / 10.0, 0.0, -float(xy[1]) / 10.0)
		cam.target = _walk_at
	_pending_walk = args.get("view", "walk") == "walk"
	_hud()
	if args.has("shot"):
		_shot_t = float(args.get("wait", "14"))
		streamer.radius = 1600.0
		match args.get("view", "map"):
			"map":
				cam.dist = float(args.get("dist", "650")); cam.pitch = deg_to_rad(float(args.get("pitch", "58")))
				cam.yaw = deg_to_rad(float(args.get("camyaw", "20")))
			"walk":
				pass
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
	env.ssao_enabled = RenderingServer.get_current_rendering_method() == "forward_plus"   # (the browser's renderer has none)
	env.ssao_radius = 1.5
	env.glow_enabled = true
	env.glow_hdr_threshold = 1.2
	env.tonemap_exposure = 0.92
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	add_child(sun)
	_view("map")


# On foot you see 950 m, the fog closing in from 300 m, and shadows within
# 160 m (two cascades); from the map camera, far more of the city.
const WALK_RADIUS := 850.0       # chunks loaded round you on foot
const WALK_FOG := [300.0, 900.0]
const MAP_FOG := [1400.0, 3600.0]

func _view(m: String) -> void:
	var walk := m == "walk"
	env.fog_depth_begin = WALK_FOG[0] if walk else MAP_FOG[0]
	env.fog_depth_end = WALK_FOG[1] if walk else MAP_FOG[1]
	sun.directional_shadow_max_distance = 160.0 if walk else 600.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if walk else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS


# On a high-density (Retina) screen the browser has two or three times the
# pixels: draw the 3D world at about normal density and scale it up (the
# HUD and text stay sharp).
func _screen_scale() -> void:
	if not OS.has_feature("web"):
		return
	var sc := DisplayServer.screen_get_scale()
	if sc > 1.25:
		get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		get_viewport().scaling_3d_scale = clampf(1.25 / sc, 0.5, 1.0)


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
	ui.panel = panel
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
		b.text = "Map" if m == "map" else "On foot (M)"
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


# The on-foot HUD: minimap bottom left, key hints top left.
func _hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var mm := Minimap.new()
	mm.streamer = streamer; mm.traffic = traffic; mm.walker = walker; mm.boats = boats; mm.crime = crime
	mm.anchor_top = 1.0; mm.anchor_bottom = 1.0
	layer.add_child(mm)
	mm.offset_left = 22; mm.offset_right = 22 + Minimap.SIZE
	mm.offset_top = -Minimap.SIZE - 22; mm.offset_bottom = -22
	mm.visible = false
	mm.mission = mission
	ui.minimap = mm
	_mission_hud(layer)
	var hint := Label.new()
	hint.text = HINTS.foot
	hint.add_theme_font_size_override("font_size", 13)
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	hint.add_theme_constant_override("outline_size", 4)
	hint.position = Vector2(20, 56)              # under the wanted stars
	hint.visible = false
	layer.add_child(hint)
	ui.walk_hint = hint
	# What E does here: "E  drive this car", "E  get out"...
	var prompt := Label.new()
	prompt.add_theme_font_size_override("font_size", 20)
	prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	prompt.add_theme_constant_override("outline_size", 6)
	prompt.anchor_left = 0.5; prompt.anchor_right = 0.5; prompt.anchor_top = 1.0; prompt.anchor_bottom = 1.0
	prompt.offset_left = -200; prompt.offset_right = 200; prompt.offset_top = -118; prompt.offset_bottom = -88
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.visible = false
	layer.add_child(prompt)
	ui.prompt = prompt
	var loading := Label.new()
	loading.text = "Loading Amsterdam..."
	loading.add_theme_font_size_override("font_size", 30)
	loading.add_theme_color_override("font_outline_color", Color.BLACK)
	loading.add_theme_constant_override("outline_size", 8)
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.grow_horizontal = Control.GROW_DIRECTION_BOTH
	loading.grow_vertical = Control.GROW_DIRECTION_BOTH
	loading.visible = _pending_walk
	layer.add_child(loading)
	ui.loading = loading


# The job on screen: what to do and how far (bottom middle), the clock while a parcel
# is on board, money (top right), and big announcements in the middle.
func _mission_hud(layer: CanvasLayer) -> void:
	var bar := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.06, 0.72); sb.set_corner_radius_all(6); sb.set_content_margin_all(10)
	sb.border_color = Color(1.0, 0.82, 0.08); sb.border_width_left = 4
	bar.add_theme_stylebox_override("panel", sb)
	bar.anchor_left = 0.5; bar.anchor_right = 0.5; bar.anchor_top = 1.0; bar.anchor_bottom = 1.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_bottom = -26
	bar.visible = false
	layer.add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	bar.add_child(row)
	var obj := Label.new()
	obj.add_theme_font_size_override("font_size", 20)
	row.add_child(obj)
	var clock := Label.new()
	clock.add_theme_font_size_override("font_size", 20)
	clock.add_theme_color_override("font_color", Color(1.0, 0.82, 0.08))
	row.add_child(clock)
	ui.mission_bar = bar; ui.mission_text = obj; ui.mission_clock = clock
	var cash := Label.new()
	cash.add_theme_font_size_override("font_size", 30)
	cash.add_theme_color_override("font_color", Color("6fd36a"))
	cash.add_theme_color_override("font_outline_color", Color.BLACK)
	cash.add_theme_constant_override("outline_size", 8)
	cash.anchor_left = 1.0; cash.anchor_right = 1.0
	cash.offset_left = -320; cash.offset_right = -24; cash.offset_top = 14
	cash.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cash.visible = false
	layer.add_child(cash)
	ui.cash = cash
	var big := VBoxContainer.new()
	big.set_anchors_preset(Control.PRESET_CENTER)
	big.grow_horizontal = Control.GROW_DIRECTION_BOTH; big.grow_vertical = Control.GROW_DIRECTION_BOTH
	big.offset_top = -150; big.offset_bottom = -60
	big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(big)
	for k in [["title", 44, Color(1.0, 0.82, 0.08)], ["sub", 22, Color.WHITE]]:
		var l := Label.new()
		l.add_theme_font_size_override("font_size", k[1])
		l.add_theme_color_override("font_color", k[2])
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 10)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		big.add_child(l)
		ui["big_" + k[0]] = l
	ui.big = big
	big.modulate.a = 0.0
	var say := func(title, sub):
		ui.big_title.text = title
		ui.big_sub.text = sub
		ui.big_title.add_theme_color_override("font_color", Color(0.95, 0.2, 0.2) if title == "BUSTED" else Color(1.0, 0.82, 0.08))
		big.modulate.a = 1.0
		var tw := create_tween()
		tw.tween_interval(3.0)
		tw.tween_property(big, "modulate:a", 0.0, 0.8)
	mission.announce.connect(say)
	crime.announce.connect(say)
	# Mission 2: its objective under the cash, the ammo, the stars and the crosshair.
	var line := Label.new()
	line.add_theme_font_size_override("font_size", 17)
	line.add_theme_color_override("font_color", Color(0.75, 0.86, 1.0))
	line.add_theme_color_override("font_outline_color", Color.BLACK)
	line.add_theme_constant_override("outline_size", 6)
	line.anchor_left = 1.0; line.anchor_right = 1.0
	line.offset_left = -620; line.offset_right = -24; line.offset_top = 96
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layer.add_child(line)
	ui.crime_text = line
	var hud := CrimeHud.new()
	hud.crime = crime; hud.walker = walker
	layer.add_child(hud)


func _mission_ui() -> void:
	var text: String = mission.objective()
	ui.mission_bar.visible = text != ""
	if text != "":
		var d: float = mission.distance_left()
		if mission.target == Vector3.INF:      # (no tourist about just now)
			ui.mission_text.text = text
		else:
			ui.mission_text.text = "%s  ·  %s" % [text, ("%d m" % d) if d < 1000.0 else ("%.1f km" % (d / 1000.0))]
		ui.mission_clock.visible = mission.state == "deliver"
		var t := maxf(mission.time_left, 0.0)
		ui.mission_clock.text = "%d:%02d" % [int(t) / 60, int(t) % 60]
		ui.mission_clock.add_theme_color_override("font_color", Color(1, 0.3, 0.25) if t < 15.0 else Color(1.0, 0.82, 0.08))
	ui.cash.visible = mission.state != "off"
	if mission.state.begins_with("tulips"):
		ui.cash.text = "€ %d\n%d tulip%s" % [mission.money, mission.tulips, "" if mission.tulips == 1 else "s"]
	else:
		ui.cash.text = "€ %d\n%d parcel%s" % [mission.money, mission.delivered, "" if mission.delivered == 1 else "s"]
	var ammo: String = crime.ammo_text()
	ui.crime_text.visible = mode == "walk" and crime.state != "off"
	ui.crime_text.text = crime.objective() + ("\n" + ammo if ammo != "" else "")
	mission.show_route_3d(mode == "map")


func _help() -> void:
	ui.help.text = ("Drag: pan   Right-drag / Q E R F: rotate & tilt\nWheel or pinch: zoom   WASD: move   M: walk here"
		if mode == "map" else
		"WASD / arrows: walk   Shift: run   Space: jump\nMouse: look   Wheel: camera distance   Esc: mouse   M: map")


func _set_mode(m: String) -> void:
	_follow = null
	_pending_walk = false
	if m == mode:
		ui["mode_" + m].button_pressed = true
		return
	mode = m
	_view(m)
	ui.mode_map.button_pressed = m == "map"
	ui.mode_walk.button_pressed = m == "walk"
	if m == "walk":
		cam.active = false
		var at: Vector3 = cam.target
		if streamer.water_at(at) == 1 or not walker._free(at):
			at = _nearest_street(at)
		walker.enter(at, cam.yaw)
	else:
		ui.area.text = ""
		walker.leave()
		cam.active = true
		cam.target = walker.global_position
		cam.dist = 260.0
	ui.prompt.visible = false
	ui.panel.visible = m == "map"
	ui.minimap.visible = m == "walk"
	ui.walk_hint.visible = m == "walk"
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
		if event.physical_keycode in [KEY_G, KEY_M, KEY_TAB]:
			_set_mode("map" if mode == "walk" else "walk")
		elif event.physical_keycode == KEY_ESCAPE and mode == "walk":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if event is InputEventMouseButton and event.pressed and _follow != null and event.button_index == MOUSE_BUTTON_LEFT:
		_follow = null


func _process(delta: float) -> void:
	if _pending_walk and streamer.failed > 0:
		ui.loading.text = "Could not load the city's map tiles.\nReload the page; if it keeps happening, the browser console says which file failed."
	if _pending_walk and not streamer.tile_at(_walk_at).is_empty():
		_pending_walk = false
		cam.target = _walk_at
		await get_tree().physics_frame         # let the new walls join the physics world
		_set_mode("walk")
		ui.loading.visible = false
		if mission.state == "off" and not args.has("nomission"):
			mission.start()
			if args.get("mission", "") == "tulips":     # --mission=tulips: straight to Mission 3
				mission.start_tulips()
			crime.start()
		return
	var focus: Vector3
	if mode == "walk":
		focus = walker.global_position
		if _damrak_boat.is_empty() and not streamer.tile_at(Vector3(DAMRAK_BOAT.x, 0, DAMRAK_BOAT.y)).is_empty():
			_damrak_boat = boats.moor(DAMRAK_BOAT, Vector2(_walk_at.x, _walk_at.z))
		streamer.radius = WALK_RADIUS
		traffic.player = walker.global_position if walker.vehicle == null else Vector3(1e9, 0, 1e9)
		ui.prompt.text = walker.prompt
		var doing := "foot"
		if walker.vehicle != null:
			var k: String = walker.vehicle.kind
			if walker.vehicle.get("driven", false): doing = "tram"
			elif k == "boat" or k == "bike": doing = k
			elif walker.vehicle.get("driver", false): doing = "car"   # a car, Canta or bus at the wheel
			else: doing = "ride"
		ui.walk_hint.text = HINTS[doing]
		ui.prompt.visible = walker.prompt != ""
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
	boats.focus = focus
	boats.target = 14 if mode == "walk" else 0
	traffic.enabled = traffic_on and (mode == "walk" or cam.dist < 1600.0)
	var s: Dictionary = streamer.stats()
	var c: Dictionary = traffic.count()
	ui.stats.text = "%d chunks (%d loading) · %s buildings\n%d cars · %d buses · %d trams · %d Cantas · %d cyclists · %d boats · %d fps" % [
		s.ready, s.loading, _thousands(s.buildings), c.car, c.bus, c.tram, c.canta, c.bike, boats.boats.size(), Engine.get_frames_per_second()]
	sun.global_position = focus
	_mission_ui()
	if _shot_t >= 0.0:
		_shot_t -= delta
		if Engine.get_process_frames() % 20 == 0:
			print("t=%.1f %s" % [_shot_t, ui.stats.text.replace("\n", " | ")])
		if args.has("yaw") and walker.active:
			walker.cam_yaw = float(args.yaw)
			walker.cam_pitch = 0.18
		if args.has("run") and walker.active:
			_test_run()
		if args.has("vehicle") and walker.active:
			_test_vehicle(args.vehicle)
		if args.has("crime") and walker.active:
			_test_crime()
		if args.has("mission") and (walker.active or _mis_step == 3):   # step 3 is in the map view
			_test_mission()
		if args.get("view") == "tram" and _follow == null and traffic.count().tram > 0 and _shot_t < 6.0:
			_ride()
		if _shot_t < 0.0:
			var img := get_viewport().get_texture().get_image()
			img.save_png(args.shot)
			print("shot saved: ", args.shot, " ", ui.stats.text.replace("\n", " | "))
			get_tree().quit()


# --run: hold W (and Shift after a moment), then turn with the mouse; prints
# where the player got to so a headless run can check it moved.
var _run_t := 0.0
func _test_run() -> void:
	var dt := get_process_delta_time()
	_run_t += dt
	var key := func(k: Key) -> void:
		var e := InputEventKey.new(); e.physical_keycode = k; e.keycode = k; e.pressed = true
		Input.parse_input_event(e)
	if _run_t < 0.3:
		key.call(KEY_W)
	if _run_t > 1.5 and _run_t < 1.5 + dt * 1.5:
		key.call(KEY_SHIFT)
	if _run_t > 4.0 and _run_t < 6.0:
		walker.cam_yaw -= dt * 0.8
	if Engine.get_process_frames() % 10 == 0:
		print("run t=%.1f pos=%s state=%s speed=%.1f" % [_run_t, walker.global_position.snapped(Vector3.ONE * 0.1), walker.state, walker.speed])


# --vehicle=car|bus|tram: walk up to the nearest one, press E, drive (or ride)
# for a while, save <shot>-in.png, press E again; logs every step.
var _veh_t := 0.0
var _veh_step := 0
var _veh_target = null
var _rack_shot := false
func _test_vehicle(kind: String) -> void:
	_veh_t += get_process_delta_time()
	var press := func(k: Key, down := true) -> void:
		var e := InputEventKey.new(); e.physical_keycode = k; e.keycode = k; e.pressed = down
		Input.parse_input_event(e)
	if _veh_step == 0 and _veh_t > 1.0 and kind == "rack":
		var here := Vector2(walker.global_position.x, walker.global_position.z)
		var b: Dictionary = streamer.parked_bike(here, 3000.0)
		if b.is_empty():
			return
		var side := Vector2(cos(b.yaw), -sin(b.yaw))
		var at: Vector2 = b.at + side * 1.1
		walker.global_position = Vector3(at.x, 0.0, at.y)
		var d: Vector2 = b.at - at
		walker.cam_yaw = atan2(-d.x, -d.y) + 0.5
		walker.cam_pitch = 0.25
		print("veh: next to a parked bike %.0f m from the start" % b.at.distance_to(here))
		_veh_step = 1; _veh_t = 0.0
	elif _veh_step == 0 and _veh_t > 1.0 and (kind == "boat" or kind == "swim" or kind == "damrak"):
		var here := Vector2(walker.global_position.x, walker.global_position.z)
		var best = null
		for b in boats.boats:
			if best == null or b.pos.distance_to(here) < best.pos.distance_to(here):
				best = b
		if kind == "damrak":
			best = null if _damrak_boat.is_empty() else _damrak_boat
		if best == null or _veh_t < 4.0:
			return                        # let a few moor first
		var boat: Node3D = best.boat
		var right := Vector2(boat.global_transform.basis.x.x, boat.global_transform.basis.x.z)
		var at := Vector2.INF
		if kind == "swim":                # in the water beside it
			at = best.pos - right * 2.0
			walker.global_position = Vector3(at.x, walker.SWIM_Y, at.y)
			walker.state = "swim"; walker.grounded = false
		else:                             # on the quay it is moored along
			for d in range(8, 36):
				for sd in [right, -right]:
					var p: Vector2 = best.pos + sd * d * 0.25
					if at == Vector2.INF and streamer.water_at(Vector3(p.x, 0, p.y)) != 1:
						at = p
			if at == Vector2.INF:
				return
			walker.global_position = Vector3(at.x, 0.0, at.y)
		var d: Vector2 = best.pos - at
		walker.cam_yaw = atan2(-d.x, -d.y) + PI + 0.4
		walker.cam_pitch = 0.3
		print("veh: %s next to a boat %.0f m from the start, state=%s" % [kind, best.pos.distance_to(here), walker.state])
		_veh_step = 1; _veh_t = 0.0
	elif _veh_step == 0 and _veh_t > 1.0:
		var drive_cab := kind.ends_with("drive")        # busdrive, tramdrive: at the driver's door
		var want := kind.trim_suffix("drive")
		var best = null
		for v in traffic.vehicles:
			if v.kind == want and (best == null or v.pos.distance_to(Vector2(walker.global_position.x, walker.global_position.z)) < best.pos.distance_to(Vector2(walker.global_position.x, walker.global_position.z))):
				best = v
		if best == null:
			return
		_veh_target = best
		_beside(best, drive_cab)
		walker.cam_yaw = best.parts[0][0].rotation.y + PI / 2
		print("veh: next to a %s, prompt in a moment" % kind)
		_veh_step = 1; _veh_t = 0.0
	elif _veh_step == 1 and _veh_t > 2.5 and kind == "rack" and not _rack_shot:
		get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-rack.png"))
		_rack_shot = true
	elif _veh_step == 1 and _veh_t > 0.5 and (kind != "rack" or _rack_shot):
		if _veh_target != null:
			_beside(_veh_target, kind.ends_with("drive"))   # it may have driven on meanwhile
		print("veh: prompt='%s'" % walker.prompt)
		press.call(KEY_E); press.call(KEY_E, false)
		_veh_step = 2; _veh_t = 0.0
	elif _veh_step == 2 and _veh_t > 0.3:
		if walker.vehicle == null:
			print("veh: FAILED to get in"); _veh_step = 9; return
		if kind != "bus" and kind != "tram":
			if _veh_t < 0.6: press.call(KEY_W)
			if kind == "tramdrive" and _veh_t > 7.0 and _veh_t < 7.3: press.call(KEY_W, false); press.call(KEY_S)
			if (kind == "bike" or kind == "rack") and _veh_t > 2.0 and _veh_t < 2.3: press.call(KEY_SHIFT)
			if _veh_t > 4.0 and _veh_t < 4.3: press.call(KEY_A)
			if _veh_t > 5.5 and _veh_t < 5.8: press.call(KEY_A, false)
		if args.has("side"):             # look at the rider from the side, close up
			walker.cam_yaw = walker.heading + PI / 2
			walker.cam_pitch = 0.12
			walker.cam_dist = 2.6
			walker._mouse_idle = 0.0
		if Engine.get_process_frames() % 10 == 0:
			var physics := ""
			if walker.vehicle.kind == "boat":   # afloat: waterline, pitch and roll
				var bt: RigidBody3D = walker.vehicle.boat
				var e := bt.global_transform.basis.get_euler()
				physics = " y=%.3f pitch=%.2f° roll=%.2f° rudder=%.2f slide=%.2f" % [bt.global_position.y, rad_to_deg(e.x), rad_to_deg(e.z), bt.rudder,
					bt.linear_velocity.dot(bt.global_transform.basis.x)]
			elif walker.vehicle.get("driven", false):   # at a tram's controls
				physics = " tram %.1f m/s on edge %d" % [walker.vehicle.speed, walker.vehicle.edge]
			elif walker.vehicle.has("body"):   # the suspension at work: ride height, pitch and roll
				var b: VehicleBody3D = walker.vehicle.body
				var e := b.global_transform.basis.get_euler()
				physics = " y=%.3f pitch=%.2f° roll=%.2f° steer=%.2f" % [b.global_position.y, rad_to_deg(e.x), rad_to_deg(e.z), b.steering]
			print("veh: in %s at %s speed=%.1f%s" % [walker.vehicle.kind, walker.global_position.snapped(Vector3.ONE * 0.1), walker.speed, physics])
		if _veh_t > 9.0:
			get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-in.png"))
			press.call(KEY_W, false); press.call(KEY_SHIFT, false)
			press.call(KEY_E); press.call(KEY_E, false)
			_veh_step = 3; _veh_t = 0.0
	elif _veh_step == 3 and _veh_t > 0.5:
		print("veh: out=%s at %s body=%s state=%s" % [walker.vehicle == null, walker.global_position.snapped(Vector3.ONE * 0.1), walker.body.visible, walker.state])
		_veh_step = 4


# --mission: walk up to the pickup (shot <shot>-pickup.png), step into it, look
# at the route in the map view (<shot>-map.png), then step into the drop-off.
var _mis_t := 0.0
var _mis_step := 0
func _test_mission() -> void:
	_mis_t += get_process_delta_time()
	var m = mission
	if _mis_step == 0 and m.state == "pickup" and m.target != Vector3.INF and m.route.size() > 2:
		# Stand on the route about 15 m short of the circle, facing it.
		var r: PackedVector2Array = m.route
		var at: Vector2 = r[r.size() - 1]
		var walked := 0.0
		for i in range(r.size() - 1, 0, -1):
			walked += r[i].distance_to(r[i - 1])
			at = r[i - 1]
			if walked > 15.0: break
		walker.global_position = Vector3(at.x, 0, at.y)
		var d := Vector2(m.target.x, m.target.z) - at
		walker.cam_yaw = atan2(-d.x, -d.y)
		walker.cam_pitch = 0.22
		print("mis: pickup at %s, %.0f m by road; objective '%s'" % [m.target_name, m.route_len, m.objective()])
		_mis_step = 1; _mis_t = 0.0
	elif _mis_step == 1:
		var d := Vector2(m.target.x, m.target.z) - Vector2(walker.global_position.x, walker.global_position.z)
		walker.cam_yaw = atan2(-d.x, -d.y)
		if _mis_t > 4.0:
			get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-pickup.png"))
			walker.global_position = m.target
			_mis_step = 2; _mis_t = 0.0
	elif _mis_step == 2 and _mis_t > 4.0:
		print("mis: state=%s carrying=%s objective='%s' route=%.0f m clock=%.0f s" % [m.state, walker.carrying, m.objective(), m.route_len, m.time_left])
		get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-carry.png"))
		_set_mode("map")
		cam.dist = 900.0; cam.pitch = deg_to_rad(28.0)
		cam.target = (walker.global_position + m.target) / 2.0
		_mis_step = 3; _mis_t = 0.0
	elif _mis_step == 3 and _mis_t > 6.0:
		get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-map.png"))
		_set_mode("walk")
		walker.global_position = m.target
		_mis_step = 4; _mis_t = 0.0
	elif _mis_step == 4 and _mis_t > 1.5:
		print("mis: after the drop-off: state=%s delivered=%d money=%d carrying=%s" % [m.state, m.delivered, m.money, walker.carrying])
		_mis_step = 5


# --crime: walk into the gun shop, shoot at the nearest pedestrian, look at
# the police arriving (<shot>-police.png), and let them arrest you.
var _cr_t := 0.0
var _cr_step := 0
func _test_crime() -> void:
	_cr_t += get_process_delta_time()
	if _cr_step == 0 and crime.shop != Vector3.INF and _cr_t > 2.0:
		walker.global_position = crime.shop
		print("crime: at the shop (%s), money %d" % [crime.shop_name, mission.money])
		_cr_step = 1; _cr_t = 0.0
	elif _cr_step == 1 and _cr_t > 1.5:
		print("crime: armed=%s ammo='%s'" % [crime.armed, crime.ammo_text()])
		var best = null
		for p in walker.peds:
			if best == null or p.pos.distance_to(walker.global_position) < best.pos.distance_to(walker.global_position):
				best = p
		if best != null:
			var d: Vector3 = best.pos - walker.global_position
			walker.cam_yaw = atan2(-d.x, -d.z)
			walker.cam_pitch = 0.05
			walker._mouse_idle = 0.0
		_cr_step = 2; _cr_t = 0.0
	elif _cr_step == 2 and _cr_t > 1.0:
		crime.fire()
		print("crime: fired; stars=%d  objective='%s'" % [crime.stars, crime.objective()])
		_cr_step = 3; _cr_t = 0.0
	elif _cr_step == 3 and _cr_t > 0.6:
		# Aim over the shoulder at the nearest pedestrian (the camera sits 0.6 m right).
		var best = null
		for p in walker.peds:
			if not p.get("dead", false) and (best == null or p.pos.distance_to(walker.global_position) < best.pos.distance_to(walker.global_position)):
				best = p
		if best != null:
			var right := Vector3(cos(walker.cam_yaw), 0, -sin(walker.cam_yaw))
			var d: Vector3 = best.pos - (walker.global_position + right * 0.6)
			walker.cam_yaw = atan2(-d.x, -d.z)
			walker.cam_pitch = 0.02
		_cr_step = 31; _cr_t = 0.0
	elif _cr_step == 31 and _cr_t > 0.8:             # the camera has turned: fire
		crime.fire()
		get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-shot.png"))
		print("crime: second shot; stars=%d, a pedestrian down: %s" % [crime.stars, walker.peds.any(func(p): return p.get("dead", false))])
		_cr_step = 4; _cr_t = 0.0
	elif _cr_step == 4:
		if Engine.get_process_frames() % 4 == 0:
			for c in crime.cops:
				print("crime:   cop at %s, %.0f m from you, sees=%s route=%d down=%s" % [c.pos.snapped(Vector3.ONE), c.pos.distance_to(walker.global_position), c.get("sees", false), c.get("route", PackedVector2Array()).size(), c.down])
		if crime.cops.size() > 0 and _cr_t > 12.0 or _cr_t > 60.0:
			var c: Dictionary = crime.cops[0] if crime.cops.size() else {}
			if not c.is_empty():
				var d: Vector3 = c.pos - walker.global_position
				walker.cam_yaw = atan2(d.x, d.z)      # camera behind you, the police in front
			get_viewport().get_texture().get_image().save_png(String(args.shot).replace(".png", "-police.png"))
			print("crime: %d police cars, %d officers after %.0f s; stars=%d seen=%s" % [crime.cars.size(), crime.cops.size(), _cr_t, crime.stars, crime.seen])
			_cr_step = 5; _cr_t = 0.0
	elif _cr_step == 5 and (crime.stars == 0 or _cr_t > 40.0):
		print("crime: after %.0f s: stars=%d armed=%s money=%d" % [_cr_t, crime.stars, crime.armed, mission.money])
		_cr_step = 6


func _beside(v: Dictionary, cab := false) -> void:
	var n: Node3D = v.parts[0 if cab else v.parts.size() / 2][0]
	var f := Vector2(-sin(n.rotation.y), -cos(n.rotation.y))
	var side := Vector2(-f.y, f.x) * 2.2
	var along := f * (float(v.parts[0][2]) / 2.0 - 2.0) if cab else Vector2.ZERO
	walker.global_position = Vector3(n.position.x + side.x + along.x, 0.0, n.position.z + side.y + along.y)


func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out
