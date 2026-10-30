extends Node3D
## The weather over Amsterdam, and the clock. A game hour passes in CLOCK
## real seconds (a day in 24 minutes). The weather drifts between sunshine,
## clouds and rain, each spell lasting a few game hours and blending into the
## next over a minute or so: `cloud` and `rain` (0..1) are what Main lights
## the sky, the sun and the fog by. Rain falls round the camera, and the
## streets get wet while it does (darker, and glossy) and dry slowly after.
##     weather.setup(materials); each frame: weather.tick(delta, camera position)

const CLOCK := 60.0             # real seconds per game hour
const SPELL := Vector2(2.0, 6.0)  # game hours a spell of weather lasts
const BLEND := 20.0             # seconds: cloud and rain follow the weather (settled in about a minute)
const WET_IN := 1.0 / 40.0      # the streets get wet in about 40 s of rain...
const DRY_OUT := 1.0 / 150.0    # ...and dry in about two and a half minutes
const KINDS := ["sun", "clouds", "rain"]
const ODDS := [0.45, 0.3, 0.25] # how often each comes (Amsterdam: rain a quarter of the time)
const LOOK := {"sun": [0.0, 0.0], "clouds": [0.75, 0.0], "rain": [1.0, 1.0]}   # [cloud, rain]
const WET_MATS := ["road", "walk", "plaza", "ground", "bridge", "tram", "bike", "rail", "quay"]

var mode := "auto"              # auto (it changes by itself), or one of KINDS held
var now := "sun"                # the weather it is turning into (or is)
var cloud := 0.0
var rain := 0.0
var wet := 0.0
var _left := 3.0                # game hours until the weather changes
var _rng := RandomNumberGenerator.new()
var _mats
var _base := {}                 # street material -> [albedo, roughness] when dry
var _drops: CPUParticles3D


func setup(materials) -> void:
	_mats = materials
	_rng.randomize()
	for k in WET_MATS:
		var m: StandardMaterial3D = _mats.get_mat(k)
		_base[k] = [m.albedo_color, m.roughness]
	_drops = _rain_particles()
	add_child(_drops)


## Hold one weather (sun, clouds, rain), or "auto" to let it change.
func set_mode(m: String) -> void:
	mode = m
	if m != "auto":
		now = m
	else:
		_left = _rng.randf_range(SPELL.x, SPELL.y)


## Straight to a weather, no blending (for screenshots and tests).
func set_now(kind: String) -> void:
	now = kind
	cloud = LOOK[kind][0]; rain = LOOK[kind][1]
	wet = rain
	_wet_streets()


## `hours`: game hours gone by since the last tick (0 with the clock stopped).
func tick(delta: float, hours: float, cam: Vector3) -> void:
	if mode == "auto":
		_left -= hours
		if _left <= 0.0:
			_left = _rng.randf_range(SPELL.x, SPELL.y)
			now = _pick()
	var want: Array = LOOK[now]
	var k := 1.0 - exp(-delta / BLEND)
	cloud = lerpf(cloud, want[0], k)
	rain = lerpf(rain, want[1], k)
	if absf(cloud - want[0]) < 0.002: cloud = want[0]
	if absf(rain - want[1]) < 0.002: rain = want[1]
	wet = move_toward(wet, 1.0 if rain > 0.3 else 0.0, delta * (WET_IN if rain > 0.3 else DRY_OUT))
	_wet_streets()
	_drops.emitting = rain > 0.15
	_drops.global_position = cam + Vector3(0, 16, 0)


## What to show: "Sunny", "Cloudy", "Rain".
func label() -> String:
	if rain > 0.3:
		return "Rain"
	if cloud > 0.4:
		return "Cloudy"
	return "Sunny"


func _pick() -> String:
	var r := _rng.randf()
	for i in KINDS.size():
		r -= ODDS[i]
		if r <= 0.0 and KINDS[i] != now:
			return KINDS[i]
	return "sun" if now != "sun" else "clouds"


# Wet streets: darker, and smooth enough to shine.
func _wet_streets() -> void:
	for k in _base:
		var m: StandardMaterial3D = _mats.get_mat(k)
		m.albedo_color = (_base[k][0] as Color).darkened(0.45 * wet)
		m.roughness = lerpf(_base[k][1], 0.35, wet)


# Rain round the camera: thin streaks falling at 15 m/s out of a 50 m square
# above it, in the world (so they do not move with you).
func _rain_particles() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 3000
	p.lifetime = 1.3
	p.local_coords = false
	p.emitting = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(25, 2, 25)
	p.direction = Vector3(0.08, -1, 0.04)
	p.spread = 2.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = 14.0
	p.initial_velocity_max = 17.0
	var drop := BoxMesh.new(); drop.size = Vector3(0.012, 0.55, 0.012)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.78, 0.84, 0.92, 0.45)
	drop.material = m
	p.mesh = drop
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-30, -25, -30), Vector3(60, 30, 60))
	return p
