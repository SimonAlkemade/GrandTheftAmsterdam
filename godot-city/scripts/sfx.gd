extends Node
## The game's sounds, made in code at startup: nothing to download, nothing
## to license (docs/juicy-gunfights.md §5.1, §5.2, §2.4, §10.3). Every sound
## is built from noise bursts, filtered noise, decaying sines and clicks, in
## VARIANTS versions, and played round-robin (never one of the last two
## again) with a little pitch and volume jitter, so no shot sounds like the
## last. A shot is layers played together: transient, body, mech, LFE (yours
## only) and a tail that depends on the space (an open square, or a narrow
## street that answers with a slap-back echo).
##     sfx.play("stone", hit_point)          # in the world, on the Impacts bus
##     sfx.play("transient", null, "PlayerWeapon")
## Explosions (§9) have their own layers, played far (on the Explosions bus,
## heard a long way off), fires and jets loop (play_loop), and a blast close
## by leaves you half deaf for a few seconds (deafen: a low-pass over
## everything, opening up again, and a ringing tone).

const RATE := 22050
const VARIANTS := 3
const VOICES_3D := 16
const VOICES_2D := 10
const VOICES_FAR := 8           # explosion layers: heard from far off
const BUSES := ["PlayerWeapon", "Impacts", "Explosions", "UI"]
# name -> [gain dB, pitch jitter]: the pistol (§6.1) and what bullets hit (§7)
const MIX := {
	"transient": [0.0, 0.03], "body": [-2.0, 0.03], "mech": [-10.0, 0.05], "lfe": [-5.0, 0.0],
	"tail_open": [-9.0, 0.03], "tail_street": [-8.0, 0.03], "shell": [-14.0, 0.05], "dry": [-6.0, 0.05],
	"stone": [-3.0, 0.03], "metal": [-5.0, 0.03], "flesh": [-1.0, 0.03], "water": [-5.0, 0.03],
	"ricochet": [-9.0, 0.05], "hit_tick": [-8.0, 0.0], "taser": [-6.0, 0.03],
	# explosions (§9.3-9.5) and grenades
	"he_crack": [2.0, 0.03], "he_boom": [0.0, 0.03], "sub_thump": [-2.0, 0.0], "debris_rain": [-8.0, 0.05],
	"gas_whump": [-1.0, 0.03], "air_rush": [-6.0, 0.03], "gas_hiss": [-10.0, 0.03],
	"fuel_pop": [-4.0, 0.04], "whoomf": [0.0, 0.03], "roar": [-5.0, 0.03], "fire_crackle": [-9.0, 0.03],
	"rumble": [-2.0, 0.03], "tinnitus": [-18.0, 0.0], "pin": [-10.0, 0.04], "clink": [-10.0, 0.06],
}
const LOOPS := ["gas_hiss", "fire_crackle"]

var bank := {}                   # name -> [AudioStreamWAV, ...]
var _last := {}                  # name -> the last two variants played
var _p3: Array[AudioStreamPlayer3D] = []
var _p2: Array[AudioStreamPlayer] = []
var _n3 := 0
var _n2 := 0
var _pf: Array[AudioStreamPlayer3D] = []
var _nf := 0
var deaf := 0.0                  # 0..1: how deaf a blast left you (the low-pass)
var _deaf_secs := 3.0
var _lowpass: AudioEffectLowPassFilter
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_buses()
	build()
	for i in VOICES_3D:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 8.0
		p.max_distance = 220.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p); _p3.append(p)
	for i in VOICES_2D:
		var p := AudioStreamPlayer.new()
		add_child(p); _p2.append(p)
	for i in VOICES_FAR:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 40.0
		p.max_distance = 2500.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.panning_strength = 0.6
		add_child(p); _pf.append(p)


func _process(delta: float) -> void:
	# A blast's deafness wearing off: the low-pass opens up again.
	if deaf > 0.0:
		deaf = maxf(0.0, deaf - delta / _deaf_secs)
	if _lowpass:
		_lowpass.cutoff_hz = lerpf(20000.0, 900.0, deaf * deaf)


## A blast close by: `strength` (0..1) of deafness, over `secs` seconds, and
## a ringing in the ears.
func deafen(strength: float, secs: float) -> void:
	if strength > deaf:
		deaf = clampf(strength, 0.0, 1.0)
		_deaf_secs = secs
		play("tinnitus", null, "UI", lerpf(-12.0, 0.0, deaf))


## A looping sound (a fire, a gas jet) at `at` for `secs`, fading out at the end.
func play_loop(name: String, at: Vector3, secs: float, gain_db := 0.0) -> AudioStreamPlayer3D:
	if not bank.has(name) or not is_inside_tree():
		return null
	var p := AudioStreamPlayer3D.new()
	p.stream = bank[name][pick(name)]
	p.volume_db = MIX[name][0] + gain_db
	p.unit_size = 10.0; p.max_distance = 200.0
	p.bus = "Explosions"
	add_child(p)
	p.global_position = at
	p.play()
	var tw := p.create_tween()
	tw.tween_interval(maxf(0.0, secs - 2.0))
	tw.tween_property(p, "volume_db", -60.0, 2.0)
	tw.tween_callback(p.queue_free)
	return p


## Play `name`: in the world at `at` (a Vector3), or straight to your ears
## (null). `delay` seconds later if given.
func play(name: String, at = null, bus := "Impacts", gain_db := 0.0, delay := 0.0, pitch_by := 1.0) -> void:
	if not bank.has(name):
		return
	if delay > 0.0 and is_inside_tree():
		get_tree().create_timer(delay).timeout.connect(play.bind(name, at, bus, gain_db, 0.0, pitch_by))
		return
	var v := pick(name)
	var mix: Array = MIX.get(name, [0.0, 0.03])
	var vol: float = mix[0] + gain_db + _rng.randf_range(-1.5, 1.5)
	var pitch: float = (1.0 + _rng.randf_range(-mix[1], mix[1])) * pitch_by
	if at != null and bus == "Explosions":
		var p := _pf[_nf]; _nf = (_nf + 1) % VOICES_FAR
		p.stream = bank[name][v]; p.volume_db = vol; p.pitch_scale = pitch; p.bus = bus
		p.global_position = at
		p.play()
	elif at != null:
		var p := _p3[_n3]; _n3 = (_n3 + 1) % VOICES_3D     # (the oldest voice gives way)
		p.stream = bank[name][v]; p.volume_db = vol; p.pitch_scale = pitch; p.bus = bus
		p.global_position = at
		p.play()
	else:
		var p := _p2[_n2]; _n2 = (_n2 + 1) % VOICES_2D
		p.stream = bank[name][v]; p.volume_db = vol; p.pitch_scale = pitch; p.bus = bus
		p.play()


## The variant to play next: any but the last two played.
func pick(name: String) -> int:
	var last: Array = _last.get(name, [])
	var free := []
	for i in VARIANTS:
		if not last.has(i):
			free.append(i)
	var v: int = free[_rng.randi() % free.size()] if free.size() else _rng.randi() % VARIANTS
	last.append(v)
	while last.size() > mini(2, VARIANTS - 1):
		last.pop_front()
	_last[name] = last
	return v


func _buses() -> void:
	var master := AudioServer.get_bus_index("Master")
	for k in AudioServer.get_bus_effect_count(master):
		if AudioServer.get_bus_effect(master, k) is AudioEffectLowPassFilter:
			_lowpass = AudioServer.get_bus_effect(master, k)
	if _lowpass == null:                        # the deafness after a blast (§10.3)
		_lowpass = AudioEffectLowPassFilter.new()
		_lowpass.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(master, _lowpass)
	for b in BUSES:
		if AudioServer.get_bus_index(b) != -1:
			continue
		AudioServer.add_bus()
		var i := AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, b)
		AudioServer.set_bus_send(i, "Master")
		if b == "Explosions":                   # big and loud: kept from clipping
			var c := AudioEffectCompressor.new()
			c.threshold = -12.0; c.ratio = 4.0; c.attack_us = 2000.0; c.release_ms = 300.0
			AudioServer.add_bus_effect(i, c)
		if b == "PlayerWeapon":                 # a touch of tape-style saturation (§11)
			var d := AudioEffectDistortion.new()
			d.mode = AudioEffectDistortion.MODE_CLIP
			d.drive = 0.12
			d.post_gain = -1.0
			AudioServer.add_bus_effect(i, d)


# ---- making them ----------------------------------------------------------------------

func build() -> void:
	for name in MIX:
		var list := []
		for v in VARIANTS:
			var seed := hash(name) + v * 7919
			var w := _wav(_make(name, seed))
			list.append(_loop(w) if name in LOOPS else w)
		bank[name] = list


func _make(name: String, seed: int) -> PackedFloat32Array:
	var r := RandomNumberGenerator.new(); r.seed = seed
	var j := func(x: float) -> float: return x * r.randf_range(0.9, 1.1)   # each variant a little different
	match name:
		"transient":                      # the crack: a 2-4 kHz snap, 25 ms
			return _gain(_decay(_hp(_noise(0.03, r), j.call(2200.0)), 0.006), 1.0)
		"body":                           # the bang: 200-800 Hz, 120 ms, a little saturated
			var b := _mix(_decay(_lp(_hp(_noise(0.16, r), 180.0), j.call(850.0)), 0.04), _decay(_sine(0.16, j.call(190.0)), 0.035), 0.5)
			return _sat(_gain(b, 2.2), 1.6)
		"mech":                           # the polymer slide: tick ... clack
			var m := _mix(_click(0.09, 0.0, r), _click(0.09, j.call(0.055), r), 1.0)
			return _mix(m, _delay(_decay(_sine(0.05, j.call(2300.0)), 0.008), 0.055), 0.3)
		"lfe":                            # the thump you feel: a sub sine falling 60 -> 40 Hz
			return _gain(_decay(_sweep(0.22, j.call(62.0), j.call(40.0)), 0.07), 0.9)
		"tail_open":                      # an open square: a soft roll, 0.9 s
			return _attack(_decay(_lp(_noise(0.9, r), j.call(500.0)), 0.25), 0.03)
		"tail_street":                    # a narrow street: the walls answer back
			var t := _decay(_lp(_noise(0.45, r), j.call(1300.0)), 0.07)
			return _mix(_mix(t, _delay(t, j.call(0.085)), 0.55), _delay(t, j.call(0.17)), 0.3)
		"shell":                          # brass on stone: tink, and a smaller bounce
			var s := _mix(_mix(_decay(_sine(0.3, j.call(3150.0)), 0.035), _decay(_sine(0.3, j.call(5280.0)), 0.025), 0.6), _decay(_sine(0.3, j.call(7930.0)), 0.015), 0.4)
			return _mix(s, _delay(_gain(s, 0.4), j.call(0.09)), 1.0)
		"dry":                            # an empty click
			return _mix(_click(0.06, 0.0, r), _decay(_sine(0.06, 1250.0), 0.006), 0.4)
		"stone":                          # tchk, and grit trickling down
			var k := _decay(_hp(_noise(0.3, r), j.call(1500.0)), 0.009)
			return _mix(k, _attack(_decay(_lp(_hp(_noise(0.3, r), 900.0), 3000.0), 0.08), 0.02), 0.18)
		"metal":                          # ting: inharmonic partials ringing on
			var f0: float = j.call(2350.0)
			var m := _mix(_mix(_decay(_sine(0.6, f0), 0.13), _decay(_sine(0.6, f0 * 1.58), 0.09), 0.7), _decay(_sine(0.6, f0 * 2.51), 0.05), 0.5)
			return _mix(m, _decay(_hp(_noise(0.6, r), 3000.0), 0.004), 0.8)
		"flesh":                          # a thwack: a low thump and something wet
			var f := _decay(_sweep(0.2, j.call(110.0), 60.0), 0.05)
			return _mix(_mix(f, _decay(_lp(_noise(0.2, r), 450.0), 0.03), 1.2), _decay(_hp(_noise(0.2, r), 2500.0), 0.006), 0.35)
		"water":                          # plip, and the splash
			return _mix(_decay(_sweep(0.35, j.call(1300.0), 380.0), 0.035), _attack(_decay(_lp(_noise(0.35, r), 2500.0), 0.11), 0.01), 0.45)
		"ricochet":                       # the whine of a bullet going on
			return _attack(_decay(_vibrato(_sweep(0.5, j.call(2700.0), 1500.0), 14.0, 0.02), 0.2), 0.01)
		"hit_tick":                       # a hit: two quick high ticks
			return _mix(_decay(_sine(0.07, j.call(1850.0)), 0.012), _delay(_decay(_sine(0.07, j.call(2450.0)), 0.01), 0.028), 0.8)
		"taser":                          # a crackling buzz
			var z := _mix(_sat(_gain(_sine(0.7, j.call(62.0)), 4.0), 1.0), _gate(_hp(_noise(0.7, r), 1800.0), r), 0.7)
			return _decay(z, 0.35)
		"he_crack":                       # the crack: sharp, broadband, the loudest thing
			return _sat(_gain(_decay(_hp(_noise(0.06, r), j.call(700.0)), 0.012), 2.0), 2.0)
		"he_boom":                        # the boom: 40-120 Hz body, half a second
			var b := _mix(_decay(_lp(_noise(1.0, r), j.call(220.0)), 0.28), _decay(_sweep(1.0, j.call(75.0), 38.0), 0.32), 0.9)
			return _sat(_gain(b, 2.5), 1.8)
		"sub_thump":                      # what your chest feels
			return _decay(_sweep(0.7, j.call(48.0), 26.0), 0.2)
		"debris_rain":                    # gravel and bits pattering down
			var d := _gate(_hp(_noise(2.6, r), 1500.0), r)
			return _attack(_decay(_lp(d, 5000.0), 0.9), 0.3)
		"gas_whump":                      # a soft, low WHUMP, not a crack
			return _attack(_decay(_mix(_lp(_noise(1.1, r), j.call(160.0)), _sine(1.1, j.call(55.0)), 0.6), 0.3), 0.03)
		"air_rush":                       # the cloud catching: an inward rush, cut off
			var a := _lp(_noise(0.25, r), 1200.0)
			for i in a.size(): a[i] *= pow(float(i) / a.size(), 2.0)
			return a
		"gas_hiss":                       # a burning jet (loops)
			return _gain(_hp(_noise(1.0, r), j.call(2200.0)), 0.6)
		"fuel_pop":                       # the tank giving way
			return _mix(_click(0.15, 0.0, r), _decay(_lp(_noise(0.15, r), 1500.0), 0.03), 0.8)
		"whoomf":                         # the fireball: rich, slow attack, long body
			var w := _mix(_decay(_lp(_noise(1.4, r), j.call(420.0)), 0.42), _decay(_sweep(1.4, j.call(95.0), 48.0), 0.38), 0.8)
			return _sat(_attack(w, 0.06), 1.5)
		"roar":                           # the fireball burning
			var o := _mix(_lp(_noise(2.2, r), j.call(300.0)), _gate(_hp(_noise(2.2, r), 2500.0), r), 0.15)
			return _attack(_decay(o, 0.9), 0.2)
		"fire_crackle":                   # a fire burning on (loops)
			return _mix(_gain(_lp(_noise(2.0, r), 220.0), 0.6), _gate(_decay(_hp(_noise(2.0, r), 3000.0), 99.0), r), 0.3)
		"rumble":                         # far off: only the low end arrives
			return _attack(_decay(_lp(_noise(3.0, r), j.call(90.0)), 1.1), 0.25)
		"tinnitus":                       # the ringing after a blast
			return _attack(_decay(_sine(3.0, j.call(3500.0)), 1.0), 0.05)
		"pin":                            # a grenade's pin and lever
			return _mix(_mix(_click(0.2, 0.0, r), _click(0.2, j.call(0.08), r), 0.8), _delay(_decay(_sine(0.1, j.call(4100.0)), 0.02), 0.08), 0.3)
		"clink":                          # a grenade bouncing on the stones
			return _mix(_decay(_sine(0.15, j.call(2900.0)), 0.025), _decay(_hp(_noise(0.15, r), 3000.0), 0.004), 0.6)
	return PackedFloat32Array([0.0])


# ---- the pieces they are made of ------------------------------------------------------

func _noise(secs: float, r: RandomNumberGenerator) -> PackedFloat32Array:
	var a := PackedFloat32Array(); a.resize(int(secs * RATE))
	for i in a.size(): a[i] = r.randf_range(-1.0, 1.0)
	return a


func _sine(secs: float, f: float) -> PackedFloat32Array:
	var a := PackedFloat32Array(); a.resize(int(secs * RATE))
	for i in a.size(): a[i] = sin(TAU * f * i / RATE)
	return a


func _sweep(secs: float, f0: float, f1: float) -> PackedFloat32Array:
	var a := PackedFloat32Array(); a.resize(int(secs * RATE))
	var ph := 0.0
	for i in a.size():
		ph += TAU * lerpf(f0, f1, float(i) / a.size()) / RATE
		a[i] = sin(ph)
	return a


func _vibrato(a: PackedFloat32Array, f: float, depth: float) -> PackedFloat32Array:
	var o := PackedFloat32Array(); o.resize(a.size())
	for i in a.size():
		var k := clampi(int(i + sin(TAU * f * i / RATE) * depth * RATE), 0, a.size() - 1)
		o[i] = a[k]
	return o


func _click(secs: float, at: float, r: RandomNumberGenerator) -> PackedFloat32Array:
	return _delay(_decay(_hp(_noise(secs, r), 3000.0), 0.0025), at)


func _decay(a: PackedFloat32Array, tau: float) -> PackedFloat32Array:
	for i in a.size(): a[i] *= exp(-float(i) / RATE / tau)
	return a


func _attack(a: PackedFloat32Array, secs: float) -> PackedFloat32Array:
	var n := int(secs * RATE)
	for i in mini(n, a.size()): a[i] *= float(i) / n
	return a


func _lp(a: PackedFloat32Array, f: float) -> PackedFloat32Array:
	var k := 1.0 - exp(-TAU * f / RATE)
	var y := 0.0
	for i in a.size():
		y += (a[i] - y) * k
		a[i] = y
	return a


func _hp(a: PackedFloat32Array, f: float) -> PackedFloat32Array:
	var low := _lp(a.duplicate(), f)
	for i in a.size(): a[i] -= low[i]
	return a


func _gate(a: PackedFloat32Array, r: RandomNumberGenerator) -> PackedFloat32Array:
	var on := true
	var left := 0
	for i in a.size():
		if left <= 0:
			on = r.randf() < 0.55; left = r.randi_range(80, 600)
		left -= 1
		if not on: a[i] = 0.0
	return a


func _gain(a: PackedFloat32Array, g: float) -> PackedFloat32Array:
	for i in a.size(): a[i] *= g
	return a


func _sat(a: PackedFloat32Array, drive: float) -> PackedFloat32Array:
	for i in a.size(): a[i] = tanh(a[i] * drive) / tanh(drive)
	return a


func _delay(a: PackedFloat32Array, secs: float) -> PackedFloat32Array:
	var n := int(secs * RATE)
	var o := PackedFloat32Array(); o.resize(a.size() + n)
	for i in a.size(): o[i + n] = a[i]
	return o


func _mix(a: PackedFloat32Array, b: PackedFloat32Array, gb: float) -> PackedFloat32Array:
	var o := a.duplicate()
	if b.size() > o.size(): o.resize(b.size())
	for i in b.size(): o[i] += b[i] * gb
	return o


# Normalized to -1 dBFS, as 16-bit mono.
func _wav(a: PackedFloat32Array) -> AudioStreamWAV:
	var peak := 0.0001
	for x in a: peak = maxf(peak, absf(x))
	var g := 0.89 / peak
	var bytes := PackedByteArray(); bytes.resize(a.size() * 2)
	for i in a.size():
		bytes.encode_s16(i * 2, int(clampf(a[i] * g, -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	return w


func _loop(w: AudioStreamWAV) -> AudioStreamWAV:
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = w.data.size() / 2
	return w
