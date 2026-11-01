extends Node3D
## Explosions (docs/juicy-gunfights.md §9, §10): three kinds on one size
## slider. `size01` (0..1) maps log-linearly to an equivalent mass M of 0.2 to
## 200 kg and a linear scale S = cbrt(M); every radius, time, count, light,
## sound and shake is a formula of S with the kind's coefficients (§9.2), and
## the bigger tiers add layers (§9.2 tiers).
##   gas       (a propane canister): a soft pale WHUMP that fills a cloud, a
##             burning jet at the source, a lingering haze.
##   gasoline  (a car, a bus): the Hollywood fireball, orange and rolling up
##             into a black smoke column, burning wreckage and a burning pool.
##   he        (a grenade): white flash, a crack and a boom, a shock ring and a
##             dust skirt racing out, dirt geysers, fragments, grey-brown smoke.
## What they do (§9.1 layer 11): people knocked down as ragdolls (dead close
## in), you hurt and knocked over by distance, cars thrown (and set burning,
## so they go up in turn), gas canisters set off, everyone round about fleeing;
## and if you set it off it is a crime.
## Also kept here: the burning cars (shot until their tank goes) and the red
## gas canisters standing outside cafes.
## Fire: a Molotov breaking, a burning pool, a burning patch, is a zone that
## sets alight whoever walks into it (they run, burning, and fall), hurts you
## while you stand in it, sets cars' tanks and gas-station pumps going.
##     explosions.explode("he", point, 0.03, true)
##     explosions.molotov(point, true)

const Ragdoll := preload("res://scripts/ragdoll.gd")

const M_MIN := 0.2              # kg (§9.2)
const M_MAX := 200.0
const PRESETS := {
	# k_fb, t_fb, p, k_sh, k_dmg (§9.3-9.5); trauma at the blast, shake Hz, FOV punch, exposure
	"gas": {"k_fb": 2.2, "t_fb": 0.35, "p": 1.0, "k_sh": 4.0, "k_dmg": 1.4, "trauma0": 0.6, "freq": 8.0, "fov": 2.0, "ev": 0.8,
		"flash": Color(1.0, 0.97, 0.9), "light": Color(1.0, 0.93, 0.78)},
	"gasoline": {"k_fb": 2.9, "t_fb": 0.81, "p": 1.0, "k_sh": 3.0, "k_dmg": 1.2, "trauma0": 0.75, "freq": 14.0, "fov": 3.0, "ev": 0.6,
		"flash": Color(1.0, 0.9, 0.7), "light": Color(1.0, 0.55, 0.22)},
	"he": {"k_fb": 1.1, "t_fb": 0.2, "p": 0.75, "k_sh": 6.0, "k_dmg": 2.0, "trauma0": 1.0, "freq": 22.0, "fov": -3.0, "ev": 1.0,
		"flash": Color(1.0, 1.0, 1.0), "light": Color(0.95, 0.97, 1.0)},
}
const FIRE := [Color("fff3c0"), Color("ffb347"), Color("e8591a"), Color(0.42, 0.16, 0.07, 0.8), Color(0.1, 0.09, 0.08, 0.0)]   # §9.4 ramp
const MAX_LIVE := 4             # explosions going off at once (more wait a moment)
const MAX_FIRES := 6            # burning pools and jets at once (the oldest burn out first)
# Burning cars (§9.4): pistol hits each kind takes before its tank goes, and how big that is.
const HP := {"car": 6, "canta": 4, "bus": 10}
const CAR_SIZE := {"car": 0.45, "canta": 0.35, "bus": 0.6}
const FUSE := 1.5               # seconds a car burns before it goes up
const WRECK_FOR := 60.0         # seconds a burnt-out wreck stays
const CANISTERS := 4            # gas canisters about at once
const CANISTER_FROM := Vector2(30.0, 140.0)
const CANISTER_SIZE := 0.3
const LEAK := 1.2               # seconds a shot canister hisses before it goes
const CATCH := 2.0              # x the lethal radius: a fuel tank this close catches fire
const MOLOTOV_R := 3.0          # metres a Molotov's fire covers...
const MOLOTOV_FOR := 10.0       # ...for so many seconds
const BURN_FOR := 2.5           # seconds someone set alight runs before falling
const FIRE_HURTS := 20.0        # health a second, standing in fire
const ZONE_TICK := 0.25         # seconds between fire's checks

var walker
var traffic
var crime
var sfx
var juice
var gun_fx
var streamer
var live := 0                   # explosions still going
var place_canisters := true     # put canisters about by itself (tests place their own)
var fires: Array = []           # burning pools and jets: nodes, oldest first
var canisters: Array = []       # {node, pos, leak}
var burning: Array = []         # traffic vehicles on fire, waiting to go
var wrecks: Array = []          # burnt-out vehicles: [vehicle, seconds left]
var zones: Array = []           # fire on the ground: {pos, r, left, by_you}
var aflame: Array = []          # people burning: {p, left, fx}
var stations                    # the petrol stations (GasStations; optional)
var _zone_t := 0.0
var _now_by_you := false
var _lights: Array = []         # {light, peak, t, attack, hold, decay, flicker}
var _later: Array = []          # [seconds, Callable]
var _rng := RandomNumberGenerator.new()
var _tex := {}
var _mats := {}


func setup(w, t, c, s, j, g, st) -> void:
	walker = w; traffic = t; crime = c; sfx = s; juice = j; gun_fx = g; streamer = st
	_rng.randomize()
	_tex = {"blob": _blob_tex(false), "puff": _blob_tex(true)}


# ---- the slider (§9.2) ------------------------------------------------------------------

static func mass(size01: float) -> float:
	return M_MIN * pow(M_MAX / M_MIN, clampf(size01, 0.0, 1.0))


static func scale_of(size01: float) -> float:
	return pow(mass(size01), 1.0 / 3.0)


static func tier(size01: float) -> String:
	return "small" if size01 < 0.2 else ("medium" if size01 <= 0.6 else "large")


## Everything that follows from the kind and the size.
static func derive(kind: String, size01: float) -> Dictionary:
	var k: Dictionary = PRESETS[kind]
	var s := scale_of(size01)
	return {
		"S": s,
		"fireball": k.k_fb * s,                    # radius, m
		"t_fb": k.t_fb * pow(s, k.p),              # s
		"shock": k.k_sh * s,                       # radius, m
		"shock_t": 0.12 * sqrt(s),
		"lethal": k.k_dmg * s,
		"hurt": 2.5 * k.k_dmg * s,
		"smoke_life": sqrt(s),                     # x a layer's base
		"light_energy": 6.0 * s * s,
		"light_range": 6.0 * s,
		"gain_db": minf(18.0, 20.0 * log(s) / log(10.0)),
		"pitch": pow(s, -0.2),
		"debris_v": pow(s, 0.3),
	}


## How many of something: base x S², at least 1, at most `cap` (§9.2).
static func count(base: float, s: float, cap: int) -> int:
	return clampi(int(round(base * s * s)), 1, cap)


## The camera's trauma `d` metres from a blast (§9.2).
static func trauma_at(kind: String, size01: float, d: float) -> float:
	var k: Dictionary = PRESETS[kind]
	var s := scale_of(size01)
	return clampf(k.trauma0 * pow(s, 1.5) / (1.0 + pow(d / (k.k_dmg * s * 3.0), 2.0)), 0.0, 1.0)


## Seconds the sound takes to reach you: none close by, the speed of sound
## beyond 30 m (§9.2): you see it, feel it, then hear it.
static func sound_delay(d: float) -> float:
	return d / 343.0 if d > 30.0 else 0.0


# ---- an explosion -------------------------------------------------------------------------

## Set one off. `by_you`: you did it (a crime).
func explode(kind: String, at: Vector3, size01: float, by_you := false) -> void:
	if not PRESETS.has(kind):
		return
	if live >= MAX_LIVE:                           # a moment later, not all at once
		later(0.15, explode.bind(kind, at, size01, by_you))
		return
	var x := derive(kind, size01)
	if kind == "gas" and size01 >= 0.4:            # the cloud catching: a rush of air, 150 ms before (§9.6)
		if sfx: sfx.play("air_rush", at, "Explosions", x.gain_db, 0.0, x.pitch)
		later(0.15, _go.bind(kind, at, size01, by_you, x))
		return
	_go(kind, at, size01, by_you, x)


func _go(kind: String, at: Vector3, size01: float, by_you: bool, x: Dictionary) -> void:
	live += 1
	later(maxf(1.5, x.t_fb * 3.0), func(): live -= 1)
	var s: float = x.S
	var big := tier(size01)
	_now_by_you = by_you
	var ear: Vector3 = walker.cam.global_position if walker and walker.cam else at
	var d := ear.distance_to(at)
	_sound(kind, at, x, d)
	_flash(kind, at, x)
	match kind:
		"he": _he(at, s, x, big)
		"gas": _gas(at, s, x, big)
		"gasoline": _gasoline(at, s, x, big)
	# The camera and the ears (§10.1, §10.3).
	if juice:
		var p: Dictionary = PRESETS[kind]
		var near := 1.0 / (1.0 + pow(d / (x.hurt * 2.0), 2.0))
		juice.add(trauma_at(kind, size01, d), p.fov * near, p.ev * near, p.freq)
	var deaf_within: float = x.lethal * (1.5 if kind == "he" else 0.8)
	if sfx and d < deaf_within:
		sfx.deafen(1.0 - d / deaf_within, 2.0 + 2.0 * s)
	_blast(kind, at, x, by_you)


func _sound(kind: String, at: Vector3, x: Dictionary, d: float) -> void:
	if not sfx:
		return
	var t := sound_delay(d)
	var g: float = x.gain_db
	var p: float = x.pitch
	match kind:
		"he":
			if d < 50.0:                                   # close: everything
				sfx.play("he_crack", at, "Explosions", g, t, p)
				sfx.play("he_boom", at, "Explosions", g, t, p)
				sfx.play("sub_thump", null, "Explosions", g - 2.0, t, p)
				sfx.play("debris_rain", at, "Explosions", g - 4.0, t + 0.6, 1.0)
			elif d < 300.0:                                # the boom and a rumble
				sfx.play("he_boom", at, "Explosions", g, t, p * 0.9)
				sfx.play("rumble", at, "Explosions", g, t, p)
			else:                                          # far off: only the low end
				sfx.play("rumble", at, "Explosions", g, t, p * 0.85)
		"gas":
			sfx.play("gas_whump", at, "Explosions", g, t, p)
			if d < 60.0:
				sfx.play("sub_thump", null, "Explosions", g - 6.0, t, p)
		"gasoline":
			sfx.play("fuel_pop", at, "Explosions", g - 2.0, t, p)
			sfx.play("whoomf", at, "Explosions", g, t + 0.09, p)
			sfx.play("roar", at, "Explosions", g - 2.0, t + 0.15, p)
			if d > 150.0:
				sfx.play("rumble", at, "Explosions", g - 4.0, t, p)


# The flash and the big light (§9.1 layers 1 and 8): it lights the streets round about.
func _flash(kind: String, at: Vector3, x: Dictionary) -> void:
	var p: Dictionary = PRESETS[kind]
	var s: float = x.S
	var core := MeshInstance3D.new()
	core.mesh = _sphere(1.0 * s if kind == "he" else x.fireball * 0.5)
	core.material_override = _mat_add("flash_" + kind, p.flash)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(core); core.global_position = at
	var frames: float = {"he": 0.05, "gas": 0.09, "gasoline": 0.04}[kind]
	later(frames, core.queue_free)
	var l := OmniLight3D.new()
	l.light_color = p.light
	l.omni_range = x.light_range * (1.6 if kind == "gasoline" else (2.0 if kind == "he" else 1.0))
	l.shadow_enabled = false
	add_child(l); l.global_position = at + Vector3(0, 1.0, 0)
	match kind:
		"he": _lights.append({"l": l, "peak": x.light_energy * 1.4, "t": 0.0, "attack": 0.0, "hold": 0.03, "decay": 0.08, "flicker": 0.0})
		"gas": _lights.append({"l": l, "peak": x.light_energy, "t": 0.0, "attack": 0.04, "hold": 0.05, "decay": 0.4 * x.S, "flicker": 0.05})
		"gasoline": _lights.append({"l": l, "peak": x.light_energy, "t": 0.0, "attack": 0.08, "hold": x.t_fb, "decay": x.t_fb * 2.0, "flicker": 0.3})


# ---- the three kinds ------------------------------------------------------------------------

func _he(at: Vector3, s: float, x: Dictionary, big: String) -> void:
	var dv: float = x.debris_v
	# Fire: small and brief.
	_spray(at, count(8.0, s, 30), _flame_mat(), x.t_fb, x.t_fb * 1.5, Vector3.UP, 180.0, 1.5 * s, 4.0 * s, Vector3.ZERO, 1.3 * s, x.fireball * 0.4, _ramp([Color(1, 1, 1), Color("ffe9b0"), Color(1.0, 0.6, 0.2, 0.0)]))
	# The shock ring, and the dust skirt racing out along the ground.
	_ring(at + Vector3(0, 0.1, 0), x.shock, x.shock_t, Color(0.9, 0.88, 0.82, 0.55))
	_spray(at + Vector3(0, 0.3, 0), count(20.0 / s, s, 50), _smoke_mat(), 0.7, 1.2 * sqrt(s), Vector3(1, 0, 0), 180.0, x.shock / maxf(x.shock_t, 0.05) * 0.5, x.shock / maxf(x.shock_t, 0.05), Vector3.ZERO, 1.5 * s, 0.3, _ramp([Color("8c7a62"), Color(0.37, 0.33, 0.28, 0.0)]), 1.0)
	# Dirt geysers: a few fast fingers of earth thrown up.
	for i in _rng.randi_range(5, 9):
		var dir := Vector3(_rng.randf_range(-0.5, 0.5), 1.0, _rng.randf_range(-0.5, 0.5)).normalized()
		_spray(at, count(4.0, s, 12), _smoke_mat(), 0.6, 1.4, dir, 8.0, 6.0 * dv, 11.0 * dv, Vector3(0, -9.8, 0), 0.9 * s, 0.2, _ramp([Color("8c7a62"), Color("5e5448"), Color(0.37, 0.33, 0.28, 0.0)]))
	# Fragments: fast streaks.
	var frag := _spray(at, count(40.0, s, 100), _mat_add("frag", Color(1.0, 0.85, 0.6)), 0.12, 0.3, Vector3.UP, 180.0, 60.0, 120.0, Vector3.ZERO, 0.0, 0.2, null, 0.0, _box(0.015, 0.4))
	frag.set_particle_flag(CPUParticles3D.PARTICLE_FLAG_ALIGN_Y_TO_VELOCITY, true)
	# Debris: heavy chunks of stone and earth.
	_spray(at, count(10.0, s, 40), _solid_mat("chunk", Color(0.36, 0.33, 0.3)), 1.4, 2.4, Vector3.UP, 55.0, 5.0 * dv, 12.0 * dv, Vector3(0, -12.0, 0), 0.0, 0.3, null, 0.0, _box(0.12 * s))
	# Smoke: grey, medium life; a column on the bigger ones.
	var life: float = 6.0 + 6.0 * x.smoke_life
	_column(at, count(10.0, s, 40 if big == "small" else 70), _smoke_mat(), life, 0.5 * sqrt(s), 2.2 * s, x.fireball * 0.6, Color("6e6b67"), 1.0 if big == "small" else 2.5)
	if big == "large":                                       # the condensation shell
		var shell := MeshInstance3D.new(); shell.mesh = _sphere(x.shock * 0.5)
		shell.material_override = _mat_alpha("shell", Color(1, 1, 1, 0.22))
		add_child(shell); shell.global_position = at
		later(0.06, shell.queue_free)
	_ground(at, x.fireball * 1.6 + 0.4, "scorch")
	_ground(at, x.fireball * 0.8 + 0.2, "crater")


func _gas(at: Vector3, s: float, x: Dictionary, big: String) -> void:
	# The flame fills the cloud: pale yellow to a blue-white core, all through a sphere.
	_spray(at + Vector3(0, x.fireball * 0.4, 0), count(20.0, s, 70), _flame_mat(), 0.25 * s + 0.15, 0.5 * s + 0.2, Vector3.UP, 180.0, 0.2, 1.5, Vector3(0, 1.5, 0), x.fireball * 0.5, x.fireball * 0.8,
		_ramp([Color(0.75, 0.85, 1.0, 0.9), Color(1.0, 0.92, 0.55), Color(1.0, 0.7, 0.3, 0.85), Color(1.0, 0.55, 0.25, 0.0)]))
	# The pale cloud that lingers, drifting out, low.
	var life: float = (4.0 + 4.0 * _rng.randf()) * x.smoke_life
	_spray(at + Vector3(0, x.fireball * 0.3, 0), count(12.0, s, 45), _smoke_mat(), life * 0.7, life, Vector3(1, 0.2, 0), 180.0, 0.4, 1.4, Vector3(0, 0.15, 0), 2.6 * s, x.fireball * 0.9,
		_ramp([Color(0.85, 0.84, 0.81, 0.0), Color("d8d6cf"), Color(0.66, 0.65, 0.63, 0.0)]), 0.6)
	# A dust skirt low along the ground.
	_spray(at + Vector3(0, 0.2, 0), count(10.0, s, 30), _smoke_mat(), 1.0, 1.6, Vector3(1, 0, 0), 180.0, 3.0 * s, 6.0 * s, Vector3.ZERO, 1.3 * s, 0.3, _ramp([Color(0.8, 0.78, 0.74), Color(0.7, 0.68, 0.64, 0.0)]), 1.0)
	_spray(at, 5, _mat_add("ember", Color(1.0, 0.7, 0.3)), 1.0, 2.0, Vector3.UP, 70.0, 2.0, 5.0, Vector3(0, -4.0, 0), 0.0, 0.3, null, 0.0, _box(0.03))
	_ring(at + Vector3(0, 0.1, 0), x.shock, x.shock_t * 1.6, Color(1.0, 1.0, 1.0, 0.25))
	_ground(at, x.fireball * 1.0, "scorch", 0.5)
	# The source burns on: a jet of flame, 5 to 20 s, hissing.
	_jet(at, s, 5.0 + 8.0 * s)


func _gasoline(at: Vector3, s: float, x: Dictionary, big: String) -> void:
	var t: float = x.t_fb
	# The fireball, a moment after the tank pops: rolling up (buoyant), orange
	# going to soot.
	later(0.09, func():
		var fb := _spray(at + Vector3(0, 0.6 + x.fireball * 0.3, 0), count(30.0, s, 90), _flame_mat(), t * 0.6, t * 1.2, Vector3.UP, 70.0, 1.5 * s, 3.5 * s, Vector3(0, 3.0 * s, 0), x.fireball * 0.6, x.fireball * 0.45, _ramp(FIRE))
		fb.damping_min = 1.0; fb.damping_max = 2.5
		# Soot: black smoke rolling off the top.
		_spray(at + Vector3(0, x.fireball * 0.7, 0), count(18.0, s, 60), _smoke_mat(), t * 2.5, t * 4.0, Vector3.UP, 50.0, 1.5 * s, 3.0 * s, Vector3(0, 1.2 * s, 0), 2.4 * s, x.fireball * 0.5,
			_ramp([Color(0.1, 0.09, 0.08, 0.0), Color("1a1714"), Color(0.23, 0.22, 0.2, 0.0)]), 0.8)
		_spray(at + Vector3(0, 0.8, 0), count(40.0, s, 120), _mat_add("ember", Color(1.0, 0.7, 0.3)), 2.0, 5.0, Vector3.UP, 60.0, 3.0, 9.0, Vector3(0, -2.5, 0), 0.0, 0.5, null, 0.0, _box(0.03)))
	# Burning debris flung out.
	_spray(at + Vector3(0, 0.5, 0), _rng.randi_range(3, 8), _mat_add("burning", Color(1.0, 0.55, 0.2)), 1.5, 2.5, Vector3.UP, 60.0, 5.0 * x.debris_v, 10.0 * x.debris_v, Vector3(0, -9.8, 0), 0.0, 0.3, null, 0.0, _box(0.25))
	_spray(at + Vector3(0, 0.5, 0), count(6.0, s, 20), _solid_mat("metal_bit", Color(0.15, 0.15, 0.16)), 1.5, 2.5, Vector3.UP, 70.0, 4.0 * x.debris_v, 9.0 * x.debris_v, Vector3(0, -9.8, 0), 0.0, 0.3, null, 0.0, _box(0.2, 0.05))
	_ring(at + Vector3(0, 0.1, 0), x.shock, x.shock_t * 1.4, Color(1.0, 0.9, 0.8, 0.25))
	# The black column, wind-driven, 15 to 40 s.
	_column(at, count(25.0, s, 70), _smoke_mat(), 15.0 + 25.0 * minf(1.0, s / 3.0), 1.5 * sqrt(s), 2.6 * s, x.fireball * 0.5, Color("1a1714"), 3.0)
	_ground(at, x.fireball * 1.5, "scorch")
	# The burning pool, 20 to 60 s.
	_pool(at, s, x, 20.0 + 15.0 * s)


# ---- layers --------------------------------------------------------------------------------

## A spray of `amount` sprites (or meshes) from `at` along `dir`, alive
## life_min..life_max, `spread` degrees, speed v0..v1, `grav`, sprite `size`,
## from a sphere of radius `radius`, coloured by `ramp` over its life.
func _spray(at: Vector3, amount: int, mat: Material, life_min: float, life_max: float, dir: Vector3, spread: float, v0: float, v1: float,
		grav: Vector3, size: float, radius: float, ramp: Gradient, flat := 0.0, mesh: Mesh = null, keep := false) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	if mesh == null:
		var q := QuadMesh.new(); q.size = Vector2.ONE * maxf(size, 0.05)
		mesh = q
	p.mesh = mesh
	p.material_override = mat
	p.amount = maxi(1, amount)
	p.lifetime = maxf(life_max, 0.05)
	p.lifetime_randomness = clampf(1.0 - life_min / maxf(life_max, 0.01), 0.0, 1.0)
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.direction = dir
	p.spread = spread
	p.flatness = flat
	p.initial_velocity_min = v0; p.initial_velocity_max = v1
	p.gravity = grav
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = maxf(radius, 0.01)
	if ramp:
		p.color_ramp = ramp
		var grow := Curve.new(); grow.add_point(Vector2(0, 0.45)); grow.add_point(Vector2(1, 1.0))
		p.scale_amount_curve = grow
	p.angle_min = 0.0; p.angle_max = 360.0
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	p.global_position = at
	p.emitting = true
	if not keep:                                 # (a steady one is freed by whoever keeps it going)
		later(p.lifetime + 0.5, p.queue_free)
	return p


# Stop a steady emitter after `secs`, and free it once its last sprites are gone.
func _stop_after(p: CPUParticles3D, secs: float) -> void:
	later(secs, func(): if is_instance_valid(p): p.emitting = false)
	later(secs + p.lifetime + 0.5, func(): if is_instance_valid(p): p.queue_free())


# A smoke column: emitted for a while, rising, slowly swelling.
func _column(at: Vector3, amount: int, mat: Material, life: float, rise: float, size: float, radius: float, col: Color, emit_for: float) -> void:
	var p := _spray(at + Vector3(0, 1.0, 0), amount, mat, life * 0.7, life, Vector3(0.12, 1, 0.05), 12.0, rise * 0.6, rise, Vector3(0.25, 0.25 * rise, 0.1), size, radius,
		_ramp([Color(col.r, col.g, col.b, 0.0), Color(col.r, col.g, col.b, 0.85), Color(col.r * 1.4, col.g * 1.4, col.b * 1.4, 0.0)]), 0.0, null, true)
	p.explosiveness = 0.0                      # a steady column, not a burst
	p.one_shot = false
	_stop_after(p, emit_for)


func _ring(at: Vector3, radius: float, secs: float, col: Color) -> void:
	var t := TorusMesh.new(); t.inner_radius = 0.85; t.outer_radius = 1.0; t.rings = 32; t.ring_segments = 4
	var mi := MeshInstance3D.new(); mi.mesh = t
	var m := _mat_alpha("ring", col).duplicate()
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi); mi.global_position = at
	mi.scale = Vector3(0.2, 0.3, 0.2)
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3(radius, 0.6, radius), maxf(secs, 0.05)).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(m, "albedo_color:a", 0.0, maxf(secs, 0.05) * 1.6)
	tw.tween_callback(mi.queue_free)


# A burning pool (gasoline): low flames from a disc, a flickering light, crackling.
func _pool(at: Vector3, s: float, x: Dictionary, secs: float) -> void:
	var p := _spray(at + Vector3(0, 0.15, 0), count(30.0, s, 60), _flame_mat(), 0.4, 0.9, Vector3.UP, 15.0, 0.6, 1.8, Vector3(0, 1.5, 0), 1.3 * sqrt(s), x.fireball * 0.45, _ramp(FIRE), 0.0, null, true)
	p.explosiveness = 0.0
	p.one_shot = false
	_stop_after(p, secs)
	var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.5, 0.2); l.omni_range = x.fireball * 2.5 + 3.0
	add_child(l); l.global_position = at + Vector3(0, 1.0, 0)
	_lights.append({"l": l, "peak": 1.5 * sqrt(s), "t": 0.0, "attack": 0.5, "hold": secs, "decay": 2.0, "flicker": 0.35})
	if sfx: sfx.play_loop("fire_crackle", at, secs)
	_fire(p)
	zone(at, x.fireball * 0.45 + 0.6, secs, _now_by_you)


## Fire on the ground at `at`, `r` metres across, for `secs`.
func zone(at: Vector3, r: float, secs: float, by_you := false) -> void:
	zones.append({"pos": at, "r": r, "left": secs, "by_you": by_you})


# ---- Molotov cocktails -------------------------------------------------------------------------

## A Molotov breaking at `at`: glass, a whoosh, and a patch of burning fuel
## MOLOTOV_R across for MOLOTOV_FOR seconds (no blast: it is the fire that does it).
func molotov(at: Vector3, by_you := true) -> void:
	if sfx:
		sfx.play("glass_smash", at, "Impacts")
		sfx.play("fire_whoosh", at, "Explosions")
	_spray(at + Vector3(0, 0.3, 0), 26, _flame_mat(), 0.35, 0.8, Vector3.UP, 70.0, 2.0, 5.0, Vector3(0, 2.0, 0), 1.3, 1.0, _ramp(FIRE))
	_spray(at + Vector3(0, 0.2, 0), 12, _mat_add("shard", Color(0.6, 0.9, 0.6)), 0.3, 0.6, Vector3.UP, 80.0, 2.0, 4.0, Vector3(0, -9.8, 0), 0.0, 0.1, null, 0.0, _box(0.03))
	var p := _spray(at + Vector3(0, 0.15, 0), 90, _flame_mat(), 0.5, 1.1, Vector3.UP, 12.0, 0.6, 1.8, Vector3(0, 1.4, 0), 1.4, MOLOTOV_R * 0.8, _ramp(FIRE), 0.0, null, true)
	p.explosiveness = 0.0
	p.one_shot = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX        # spread over the ground, not hanging in the air
	p.emission_box_extents = Vector3(MOLOTOV_R * 0.75, 0.05, MOLOTOV_R * 0.75)
	var sm := _spray(at + Vector3(0, 2.2, 0), 18, _smoke_mat(), 2.0, 3.5, Vector3.UP, 15.0, 1.0, 2.0, Vector3(0, 0.8, 0), 2.2, MOLOTOV_R * 0.5, _ramp([Color(0.15, 0.13, 0.12, 0.55), Color(0.2, 0.19, 0.18, 0.0)]), 0.0, null, true)
	sm.explosiveness = 0.0
	sm.one_shot = false
	_stop_after(sm, MOLOTOV_FOR)
	_stop_after(p, MOLOTOV_FOR)
	var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.55, 0.25); l.omni_range = 9.0
	add_child(l); l.global_position = at + Vector3(0, 1.2, 0)
	_lights.append({"l": l, "peak": 2.2, "t": 0.0, "attack": 0.08, "hold": MOLOTOV_FOR - 1.5, "decay": 1.5, "flicker": 0.35})
	if sfx: sfx.play_loop("fire_crackle", at, MOLOTOV_FOR)
	_fire(p)
	_ground(at, MOLOTOV_R * 1.4, "scorch", 0.7)
	if juice and walker:
		juice.add(0.0, 0.0, 0.25 / (1.0 + walker.global_position.distance_to(at) / 10.0))
	zone(at, MOLOTOV_R, MOLOTOV_FOR, by_you)
	if crime:
		crime._scare(at)
	_crime(at, by_you, false)


# Fire's work, a few times a second: what stands in it catches.
func _zones(delta: float) -> void:
	for z in zones.duplicate():
		z.left -= delta
		if z.left <= 0.0:
			zones.erase(z)
	for b in aflame.duplicate():                      # the burning run, then fall
		b.left -= delta
		var p: Dictionary = b.p
		if b.left <= 0.0 or not walker or not walker.peds.has(p):
			aflame.erase(b)
			p.aflame = false
			if is_instance_valid(b.fx): _stop_after(b.fx, 0.0)
			if walker and walker.peds.has(p) and not p.get("dead", false):
				if crime: crime._down_ped(p)
				else: p.dead = true
				walker.knock(p, Vector3(_rng.randf_range(-1, 1), 1.0, _rng.randf_range(-1, 1)))
	_zone_t -= delta
	if _zone_t > 0.0 or zones.is_empty():
		return
	_zone_t = ZONE_TICK
	for z in zones:
		var at: Vector3 = z.pos
		var r: float = z.r
		if walker:
			for p in walker.peds:
				if p.get("dead", false) or p.has("rag") or p.get("aflame", false):
					continue
				if Vector2(p.pos.x - at.x, p.pos.z - at.z).length() < r:
					_set_alight(p, at)
			if walker.vehicle == null and Vector2(walker.global_position.x - at.x, walker.global_position.z - at.z).length() < r \
					and absf(walker.global_position.y - at.y) < 2.5:
				walker.hurt(FIRE_HURTS * ZONE_TICK)
				if juice: juice.add(0.12, 0.0, 0.05, 12.0)
		if traffic:
			for v in traffic.vehicles:
				if HP.has(v.kind) and not v.get("wrecked", false) and v.pos.distance_to(Vector2(at.x, at.z)) < r + 1.0:
					v.fire_t = float(v.get("fire_t", 0.0)) + ZONE_TICK
					if v.fire_t >= 0.7:
						v.fire_t = 0.0
						damage(v, 1, z.by_you)
		for c in canisters:
			if c.leak < 0.0 and c.pos.distance_to(at) < r + 0.5:
				c.leak = LEAK
				c.by_you = z.by_you
		if stations:
			stations.burn_near(at, r + 0.8, z.by_you)


# Someone set alight: flames on them, running wild, then they fall.
func _set_alight(p: Dictionary, from: Vector3) -> void:
	p.aflame = true
	p.flee = BURN_FOR + 1.0
	p.flee_from = from
	var fx := _spray(Vector3.ZERO, 16, _flame_mat(), 0.3, 0.6, Vector3.UP, 15.0, 0.5, 1.5, Vector3(0, 1.5, 0), 0.5, 0.35, _ramp(FIRE), 0.0, null, true)
	fx.explosiveness = 0.0; fx.one_shot = false
	fx.reparent(p.h, false)
	fx.position = Vector3(0, 1.0, 0)
	aflame.append({"p": p, "left": BURN_FOR, "fx": fx})


# A gas jet: a cone of flame from the burst source, hissing.
func _jet(at: Vector3, s: float, secs: float) -> void:
	var p := _spray(at + Vector3(0, 0.5, 0), count(25.0, s, 50), _flame_mat(), 0.3, 0.6, Vector3(0.2, 1, 0).normalized(), 9.0, 4.0, 7.0, Vector3.ZERO, 0.8 * sqrt(s), 0.05,
		_ramp([Color(0.5, 0.65, 1.0), Color(1.0, 0.8, 0.45), Color(1.0, 0.5, 0.2, 0.0)]), 0.0, null, true)
	p.explosiveness = 0.0
	p.one_shot = false
	_stop_after(p, secs)
	var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.75, 0.45); l.omni_range = 5.0
	add_child(l); l.global_position = at + Vector3(0, 1.5, 0)
	_lights.append({"l": l, "peak": 1.2, "t": 0.0, "attack": 0.1, "hold": secs, "decay": 1.0, "flicker": 0.3})
	if sfx: sfx.play_loop("gas_hiss", at, secs)
	_fire(p)


func _fire(p: Node) -> void:
	fires.append(p)
	while fires.size() > MAX_FIRES:              # the oldest burns out early
		var old = fires.pop_front()
		if is_instance_valid(old): old.emitting = false


func _ground(at: Vector3, size: float, kind: String, alpha := 1.0) -> void:
	if gun_fx == null or not is_inside_tree():
		return
	var q := PhysicsRayQueryParameters3D.create(at + Vector3(0, 1.0, 0), at - Vector3(0, 4.0, 0), 2 | 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var p: Vector3 = hit.position if not hit.is_empty() else Vector3(at.x, at.y - 0.5, at.z)
	gun_fx.mark(p, hit.normal if not hit.is_empty() else Vector3.UP, kind, size)


# ---- what it does ---------------------------------------------------------------------------

func _blast(kind: String, at: Vector3, x: Dictionary, by_you: bool) -> void:
	var lethal: float = x.lethal
	var hurt: float = x.hurt
	var push: float = 10.0 * x.debris_v
	var flat := Vector2(at.x, at.z)
	var hit_cop := false
	if walker:
		for p in walker.peds:
			if p.get("dead", false):
				continue
			var d: float = p.pos.distance_to(Vector3(at.x, p.pos.y, at.z))
			if d > hurt:
				continue
			var f := 1.0 / (1.0 + pow(d / lethal, 2.0))
			var away: Vector3 = (p.pos - at); away.y = 0.0
			away = away.normalized() if away.length() > 0.05 else Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized()
			if d < lethal:
				if crime: crime._down_ped(p)
				else: p.dead = true
			walker.knock(p, away * push * f + Vector3.UP * (2.0 + push * f * 0.6))
		# You.
		var dy: float = walker.global_position.distance_to(at)
		if dy < hurt:
			var harm := 110.0 / (1.0 + pow(dy / lethal, 2.0))
			if walker.vehicle != null:
				harm *= 0.5
			walker.hurt(harm)
			var away: Vector3 = walker.global_position - at; away.y = 0.0
			away = away.normalized() if away.length() > 0.05 else Vector3.FORWARD
			var f := 1.0 / (1.0 + pow(dy / lethal, 2.0))
			walker.knock_down(away * push * f * 0.7 + Vector3.UP * (1.5 + push * f * 0.4), 2.0 + 2.0 * f)
	if crime:
		for c in crime.cops:
			if c.down:
				continue
			var d: float = c.pos.distance_to(Vector3(at.x, c.pos.y, at.z))
			if d < hurt:
				var away: Vector3 = (c.pos - at); away.y = 0.0
				c.down = true
				c.rag = Ragdoll.knock(c.h, away.normalized() * push / (1.0 + pow(d / lethal, 2.0)) + Vector3.UP * 3.0)
				hit_cop = true
	# Vehicles: thrown; close in, their tanks catch.
	if traffic:
		for v in traffic.vehicles.duplicate():
			if not HP.has(v.kind):
				continue
			var d: float = v.pos.distance_to(flat)
			if d > hurt:
				continue
			var f := 1.0 / (1.0 + pow(d / lethal, 2.0))
			_throw(v, at, (push * 0.6) * f)
			if d < lethal * CATCH and not v.get("wrecked", false):
				damage(v, 999, by_you)
	# Canisters close by go too.
	for c in canisters.duplicate():
		if c.pos.distance_to(at) < lethal * 1.5 and c.leak < 0.0:
			c.leak = _rng.randf_range(0.2, 0.5)
	# Petrol-station pumps close by catch.
	if stations:
		stations.burn_near(at, lethal * CATCH * 1.3, by_you)
	# Everyone round about runs.
	if crime:
		crime._scare(at)
	if traffic:
		traffic.scare(at, 3.0 * x.lethal + 40.0)
	_crime(at, by_you, hit_cop)


# If you did it, it is a crime: two stars (three with an officer caught).
func _crime(at: Vector3, by_you: bool, hit_cop: bool) -> void:
	if by_you and crime:
		crime.stars = maxi(crime.stars, 3 if hit_cop else 2)
		crime.last_seen = walker.global_position if walker else at
		crime.unseen = 0.0


# A vehicle in the blast: a real body now, shoved away and up, spinning.
func _throw(v: Dictionary, at: Vector3, dv: float) -> void:
	if dv < 0.3 or walker == null:
		return
	var b = v.get("body")
	if b == null and v.get("driver", false) == false and not v.get("driven", false):
		b = walker._physical(v, false)
		v.parked = true
		v.knocked = true
	if b is RigidBody3D:
		var away: Vector3 = (b as RigidBody3D).global_position - at; away.y = 0.0
		away = away.normalized() if away.length() > 0.05 else Vector3.FORWARD
		var rb: RigidBody3D = b
		rb.apply_central_impulse((away * dv + Vector3.UP * dv * 0.8) * rb.mass)
		rb.apply_torque_impulse(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * rb.mass * dv * 0.6)


# ---- burning cars ------------------------------------------------------------------------------

## `n` hits on a car, Canta or bus: it smokes when badly hit, catches fire
## when its last is gone, and goes up FUSE seconds later.
func damage(v: Dictionary, n: int, by_you := true) -> void:
	if not HP.has(v.kind) or v.get("wrecked", false) or v.get("burning", false):
		return
	v.hp = int(v.get("hp", HP[v.kind])) - n
	v.by_you = by_you or v.get("by_you", false)
	var at: Node3D = v.parts[0][0]
	if v.hp <= HP[v.kind] / 3 and not v.has("smoke"):
		var sm := _spray(Vector3.ZERO, 14, _smoke_mat(), 1.5, 2.5, Vector3.UP, 15.0, 1.0, 2.0, Vector3(0, 0.5, 0), 0.6, 0.3,
			_ramp([Color(0.3, 0.3, 0.3, 0.0), Color(0.25, 0.25, 0.25, 0.7), Color(0.4, 0.4, 0.4, 0.0)]), 0.0, null, true)
		sm.explosiveness = 0.0; sm.one_shot = false
		sm.local_coords = false
		sm.reparent(at, false)
		sm.position = Vector3(0, 1.1, -1.4 if v.kind != "bus" else -5.0)   # the engine
		v.smoke = sm
	if v.hp <= 0:
		v.burning = true
		var fl := _spray(Vector3.ZERO, 24, _flame_mat(), 0.4, 0.8, Vector3.UP, 20.0, 0.8, 2.0, Vector3(0, 1.0, 0), 0.6, 0.6, _ramp(FIRE), 0.0, null, true)
		fl.explosiveness = 0.0; fl.one_shot = false
		fl.reparent(at, false)
		fl.position = Vector3(0, 0.9, -1.2 if v.kind != "bus" else -4.5)
		v.flames = fl
		burning.append(v)
		later(FUSE if n < 999 else _rng.randf_range(0.4, 1.2), _car_boom.bind(v))


func _car_boom(v: Dictionary) -> void:
	burning.erase(v)
	if v.get("wrecked", false) or traffic == null or not traffic.vehicles.has(v):
		return
	v.wrecked = true
	v.parked = true
	var n: Node3D = v.parts[0][0]
	var at := n.global_position + Vector3(0, 0.6, 0)
	if walker and walker.vehicle == v:                # you were in it
		walker._get_out()
	explode("gasoline", at, CAR_SIZE[v.kind], v.get("by_you", false))
	# Burnt out: black, still, cleared in a while.
	for g in v.node.find_children("*", "GeometryInstance3D", true, false):
		if g is MeshInstance3D and (g.name == "beam" or g.name == "tailglow" or g.name == "contact_shadow"):
			g.visible = false                       # (its lights are out)
		elif g is MeshInstance3D:
			(g as MeshInstance3D).material_override = _solid_mat("charred", Color(0.07, 0.065, 0.06))
	if v.has("smoke") and is_instance_valid(v.smoke): v.smoke.emitting = false
	if v.has("flames") and is_instance_valid(v.flames):
		_stop_after(v.flames, 8.0)               # (the wreck burns a while on)
	_throw(v, at - Vector3(0, 1.5, 0), 5.0)
	wrecks.append([v, WRECK_FOR])


# ---- gas canisters ------------------------------------------------------------------------------

## A bullet in a canister: it hisses, then goes.
func hit_canister(c: Dictionary) -> void:
	if c.leak < 0.0:
		c.leak = LEAK
		c.by_you = true
		if sfx: sfx.play_loop("gas_hiss", c.pos + Vector3(0, 0.9, 0), LEAK + 0.5, 4.0)
		var j := _spray(c.pos + Vector3(0, 0.95, 0), 20, _smoke_mat(), 0.4, 0.8, Vector3(0.6, 0.5, 0).normalized(), 10.0, 3.0, 5.0, Vector3.ZERO, 0.25, 0.02,
			_ramp([Color(0.9, 0.92, 0.95, 0.6), Color(1, 1, 1, 0.0)]), 0.0, null, true)
		j.explosiveness = 0.0; j.one_shot = false
		_stop_after(j, LEAK)


func _canisters(delta: float) -> void:
	if walker == null or streamer == null or not walker.active:
		return
	var here: Vector3 = walker.global_position
	for c in canisters.duplicate():
		if c.leak >= 0.0:
			c.leak -= delta
			if c.leak < 0.0:
				canisters.erase(c)
				c.node.queue_free()
				explode("gas", c.pos + Vector3(0, 0.5, 0), CANISTER_SIZE, c.get("by_you", false))
				continue
		elif c.pos.distance_to(here) > CANISTER_FROM.y + 120.0:
			canisters.erase(c)
			c.node.queue_free()
	if place_canisters and canisters.size() < CANISTERS and Engine.get_physics_frames() % 45 == 0:
		_place_canister(here)


# A red propane canister outside a cafe, a restaurant or a bar (or, failing
# that, on any free spot of pavement).
func _place_canister(from: Vector3) -> void:
	var spots := []
	for t in streamer.tiles.values():
		if t.state != "ready":
			continue
		for pl in t.result.get("places", []):
			var cat := String(pl[1])
			if cat.contains("cafe") or cat.contains("restaurant") or cat.contains("bar") or cat.contains("coffee"):
				var p := Vector3(pl[2].x, 0, pl[2].y)
				var d := p.distance_to(from)
				if d > CANISTER_FROM.x and d < CANISTER_FROM.y:
					spots.append(p)
	for k in 12:
		var p: Vector3
		if spots.size():
			p = spots[_rng.randi() % spots.size()] + Vector3(_rng.randf_range(-3, 3), 0, _rng.randf_range(-3, 3))
		else:
			var a := _rng.randf() * TAU
			p = from + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(CANISTER_FROM.x, CANISTER_FROM.y)
		p.y = 0.0
		if not walker._free(p) or streamer.water_at(p) != 0:
			continue
		if canisters.any(func(c): return c.pos.distance_to(p) < 20.0):
			continue
		var body := StaticBody3D.new()
		body.collision_layer = 4                # bullets meet it (TRAFFIC_LAYER), nothing else
		body.collision_mask = 0
		var cs := CollisionShape3D.new(); var cyl := CylinderShape3D.new(); cyl.radius = 0.18; cyl.height = 0.95
		cs.shape = cyl; cs.position.y = 0.48
		body.add_child(cs)
		var m := CylinderMesh.new(); m.top_radius = 0.17; m.bottom_radius = 0.18; m.height = 0.9; m.radial_segments = 12; m.rings = 1
		var mi := MeshInstance3D.new(); mi.mesh = m; mi.position.y = 0.45
		mi.material_override = _solid_mat("canister", Color(0.78, 0.1, 0.08), 0.35)
		body.add_child(mi)
		var valve := CylinderMesh.new(); valve.top_radius = 0.05; valve.bottom_radius = 0.06; valve.height = 0.12; valve.radial_segments = 8
		var vi := MeshInstance3D.new(); vi.mesh = valve; vi.position.y = 0.96
		vi.material_override = _solid_mat("valve", Color(0.6, 0.6, 0.62), 0.3)
		body.add_child(vi)
		add_child(body)
		body.global_position = p
		var c := {"node": body, "pos": p, "leak": -1.0}
		body.set_meta("canister", c)
		canisters.append(c)
		return


# ---- the clock -----------------------------------------------------------------------------------

## Call `cb` `secs` seconds from now.
func later(secs: float, cb: Callable) -> void:
	_later.append([secs, cb])


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	for l in _later.duplicate():
		l[0] -= delta
		if l[0] <= 0.0:
			_later.erase(l)
			(l[1] as Callable).call()
	for e in _lights.duplicate():
		e.t += delta
		var l: OmniLight3D = e.l
		if not is_instance_valid(l):
			_lights.erase(e); continue
		var k := 1.0
		if e.t < e.attack: k = e.t / e.attack
		elif e.t > e.attack + e.hold: k = maxf(0.0, 1.0 - (e.t - e.attack - e.hold) / maxf(e.decay, 0.01))
		var fl: float = 1.0 + e.flicker * sin(e.t * 47.0) * sin(e.t * 13.0 + 1.0)
		l.light_energy = e.peak * k * fl
		if k <= 0.0 and e.t > e.attack + e.hold:
			l.queue_free(); _lights.erase(e)
	for w in wrecks.duplicate():
		w[1] -= delta
		if w[1] <= 0.0:
			wrecks.erase(w)
			var v: Dictionary = w[0]
			if traffic and traffic.vehicles.has(v) and not (walker and walker.vehicle == v):
				traffic._despawn(v)
	_zones(delta)
	_canisters(delta)


# ---- looks -------------------------------------------------------------------------------------------

func _ramp(cols: Array) -> Gradient:
	var g := Gradient.new()
	g.colors = PackedColorArray(cols)
	var offs := PackedFloat32Array()
	for i in cols.size(): offs.append(float(i) / maxf(cols.size() - 1, 1))
	g.offsets = offs
	return g


# Sprites (§11: point-sampled, chunky): fire is added light, smoke is lit.
func _flame_mat() -> StandardMaterial3D:
	if not _mats.has("flame"):
		# Solid flame sprites (alpha, not added: added light washes out to
		# nothing against a bright sky or pale stone); lit by nothing but themselves.
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _tex.blob
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		_mats.flame = m
	return _mats.flame


func _smoke_mat() -> StandardMaterial3D:
	if not _mats.has("smoke"):
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = _tex.puff
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		m.roughness = 1.0
		_mats.smoke = m
	return _mats.smoke


func _mat_add(key: String, col: Color) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = col
		_mats[key] = m
	return _mats[key]


func _mat_alpha(key: String, col: Color) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_color = col
		_mats[key] = m
	return _mats[key]


func _solid_mat(key: String, col: Color, rough := 0.9) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = rough
		_mats[key] = m
	return _mats[key]


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new(); s.radius = r; s.height = r * 2.0; s.radial_segments = 12; s.rings = 6
	return s


func _box(w: float, h := -1.0) -> BoxMesh:
	var b := BoxMesh.new(); b.size = Vector3(w, h if h > 0.0 else w, w)
	return b


# A 32 px soft blob (fire) or a lumpy puff (smoke), white, for the ramps to colour.
func _blob_tex(lumpy: bool) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new(); r.seed = 5 if lumpy else 3
	var lumps := []
	for i in 6: lumps.append([Vector2(r.randf_range(9, 23), r.randf_range(9, 23)), r.randf_range(5, 9)])
	for y in 32:
		for x in 32:
			var a: float
			if lumpy:
				a = 0.0
				for l in lumps:
					a = maxf(a, 1.0 - Vector2(x, y).distance_to(l[0]) / l[1])
				a = clampf(a * 1.6, 0.0, 1.0)
			else:
				a = clampf(1.0 - Vector2(x - 15.5, y - 15.5).length() / 15.5, 0.0, 1.0)
				a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
