extends Node
## The global layer of a gunfight's feel (docs/juicy-gunfights.md §2.1,
## §10.1): one budget everything adds to and nothing can overdo. Camera
## trauma (the shake is trauma squared, so small knocks stay subtle; rotation
## only, from smooth noise), an FOV punch and a one-frame exposure bump, each
## capped. The accessibility settings live here too: how much shake you want
## (0 is none), fewer flashes, and the hit marker on or off.
##     juice.add(0.3)                 # trauma (being knocked down)
##     juice.add(0.0, 3.0, 0.35)      # FOV punch and exposure bump (a big gun)
##     the camera reads juice.shake (pitch, yaw, roll, radians) and juice.fov

const MAX_TRAUMA := 1.0
const MAX_FOV := 6.0            # degrees
const MAX_EV := 0.6
const CALM_EV := 0.2            # with reduce_flashes
const DECAY := 2.0              # trauma per second
const FOV_BACK := 0.2           # seconds for the punch to go back
const MAX_ROT := Vector3(4.0, 4.0, 6.0)   # degrees of pitch, yaw, roll at full shake

var shake_scale := 1.0          # accessibility: 0..1
var reduce_flashes := false
var hitmarker_visual := true

var trauma := 0.0
var freq := 15.0                # Hz: the shake's speed (a gun 15, a blast 22)
var fov := 0.0                  # degrees added to the camera's field of view now
var ev := 0.0                   # exposure bump this frame (EV)
var shake := Vector3.ZERO       # radians: pitch, yaw, roll
var hit_t := 0.0                # seconds the hit marker still shows
var _ev_next := 0.0
var _t := 0.0
var _noise := FastNoiseLite.new()


func _init() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_noise.seed = 7


## An event's juice: `t` trauma, `fov_deg` FOV punch, `ev_bump` exposure for a
## frame, at shake frequency `hz`. All capped (the budget).
func add(t: float, fov_deg := 0.0, ev_bump := 0.0, hz := 15.0) -> void:
	if t > 0.0:
		freq = lerpf(freq, hz, t / maxf(trauma + t, 0.001))   # (blend by who adds most)
		trauma = minf(MAX_TRAUMA, trauma + t)
	fov = minf(MAX_FOV, fov + fov_deg)
	_ev_next = minf(CALM_EV if reduce_flashes else MAX_EV, _ev_next + ev_bump)


## A hit on someone: the marker shows for a moment (if wanted).
func hit() -> void:
	hit_t = 0.12


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	_t += delta
	ev = _ev_next                  # one frame only
	_ev_next = 0.0
	trauma = maxf(0.0, trauma - DECAY * delta)
	fov = move_toward(fov, 0.0, MAX_FOV / FOV_BACK * delta * maxf(fov / MAX_FOV, 0.15))
	hit_t = maxf(0.0, hit_t - delta)
	var s := trauma * trauma * shake_scale
	var x := _t * freq
	shake = Vector3(
		deg_to_rad(MAX_ROT.x) * s * _noise.get_noise_2d(x, 0.0),
		deg_to_rad(MAX_ROT.y) * s * _noise.get_noise_2d(x, 100.0),
		deg_to_rad(MAX_ROT.z) * s * _noise.get_noise_2d(x, 200.0))
