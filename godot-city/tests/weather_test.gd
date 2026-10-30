extends SceneTree
## The weather: held at rain it clouds over, rains (the drops falling round
## the camera) and the streets get wet, darker and glossy; held at sun it
## clears and they dry back to just as they were; left to itself it changes
## every few game hours, through all three kinds.
##     godot --headless --path godot-city --script tests/weather_test.gd

const Materials := preload("res://scripts/materials.gd")
const Weather := preload("res://scripts/weather.gd")

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _run() -> void:
	var mats = Materials.new()
	mats.build()
	var w = Weather.new()
	root.add_child(w)
	w.setup(mats)
	var road: StandardMaterial3D = mats.get_mat("road")
	var dry_col := road.albedo_color
	var dry_rough := road.roughness
	var dt := 1.0 / 30.0
	_check(w.label() == "Sunny" and w.rain == 0.0 and w.wet == 0.0, "it starts fine and dry")
	# Rain.
	w.set_mode("rain")
	var t_rain := -1.0
	for i in 30 * 150:
		w.tick(dt, 0.0, Vector3(10, 0, 20))
		if t_rain < 0.0 and w.label() == "Rain": t_rain = i * dt
	print("rain: raining after %.0f s; cloud %.2f, rain %.2f, wet %.2f" % [t_rain, w.cloud, w.rain, w.wet])
	_check(t_rain > 5.0 and t_rain < 60.0, "held at rain, it comes on over a while (%.0f s)" % t_rain)
	_check(w.cloud > 0.98 and w.rain > 0.98 and w._drops.emitting, "it rains (the drops falling)")
	_check(w._drops.global_position.distance_to(Vector3(10, 16, 20)) < 0.01, "round the camera")
	_check(w.wet > 0.99 and road.albedo_color.v < dry_col.v * 0.7 and road.roughness < dry_rough - 0.3,
		"and the streets are wet: darker (%.2f of %.2f) and glossy (roughness %.2f of %.2f)" % [road.albedo_color.v, dry_col.v, road.roughness, dry_rough])
	# Sun again.
	w.set_mode("sun")
	var t_dry := -1.0
	for i in 30 * 400:
		w.tick(dt, 0.0, Vector3.ZERO)
		if t_dry < 0.0 and w.wet == 0.0: t_dry = i * dt
	print("sun: dry after %.0f s; cloud %.2f, rain %.2f" % [t_dry, w.cloud, w.rain])
	_check(w.rain == 0.0 and w.cloud == 0.0 and not w._drops.emitting, "held at sun, it clears")
	_check(t_dry > 60.0 and road.albedo_color.is_equal_approx(dry_col) and is_equal_approx(road.roughness, dry_rough),
		"and the streets dry, slowly (%.0f s), back to just as they were" % t_dry)
	# Left to itself, over two game days at an hour a step.
	w.set_mode("auto")
	var seen := {}
	var changes := 0
	var last: String = w.now
	for hour in 48 * 4:
		for k in 30:
			w.tick(dt, 0.25 / 30.0, Vector3.ZERO)       # a quarter of a game hour, in a second
		seen[w.now] = true
		if w.now != last:
			changes += 1; last = w.now
		if w.cloud < 0.0 or w.cloud > 1.0 or w.rain < 0.0 or w.rain > 1.0: _fails += 1
	print("auto: %d changes in two game days, %s" % [changes, seen.keys()])
	_check(changes >= 6 and seen.size() == 3, "left to itself it changes every few hours (%d times), sun, clouds and rain" % changes)
	print("weather test: %d failed" % _fails)
	quit(1 if _fails else 0)
