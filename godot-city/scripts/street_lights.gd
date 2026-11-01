extends Node3D
## At night the street lamps nearest you light the street for real: a small
## pool of warm OmniLights moved to the LIGHTS nearest lamps (from the loaded
## chunks' lamp positions), so people, cars and walls round you catch their
## light. Every other lamp only glows (its head, and the pool on the stones:
## Materials' "lamp_pool"). Off by day.
##     street_lights.setup(streamer); street_lights.night = 0..1; street_lights.focus = position

const LIGHTS := 6
const RANGE := 11.0
const ENERGY := 1.6
const EVERY := 0.4               # seconds between looking for the nearest lamps

var streamer
var night := 0.0
var focus := Vector3.ZERO
var lights: Array[OmniLight3D] = []
var _t := 0.0


func setup(s) -> void:
	streamer = s
	for i in LIGHTS:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.78, 0.5)
		l.omni_range = RANGE
		l.omni_attenuation = 1.4
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		lights.append(l)


## The lamps within `r` of `p` in the loaded chunks, nearest first.
func lamps_near(p: Vector3, r: float) -> Array:
	var out := []
	if streamer == null:
		return out
	for t in streamer.tiles.values():
		if t.get("state") != "ready":
			continue
		var res: Dictionary = t.result
		var rect: Rect2 = res.rect
		if not rect.grow(r).has_point(Vector2(p.x, p.z)) or not res.instances.has("lamps"):
			continue
		var n: int = res.instances.lamps[0]
		var buf: PackedFloat32Array = res.instances.lamps[1]
		for i in n:
			var x := buf[i * 16 + 3]
			var z := buf[i * 16 + 11]
			var d := Vector2(x - p.x, z - p.z).length()
			if d < r:
				out.append([d, Vector3(x, 0.0, z)])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out.map(func(a): return a[1])


func _process(delta: float) -> void:
	var on := night > 0.15
	_t -= delta
	if on and _t <= 0.0:
		_t = EVERY
		var near := lamps_near(focus, 70.0)
		for i in LIGHTS:
			var l := lights[i]
			l.visible = i < near.size()
			if l.visible:
				l.global_position = near[i] + Vector3(0, 4.4, 0)
	for l in lights:
		if not on:
			l.visible = false
		l.light_energy = ENERGY * clampf((night - 0.15) / 0.5, 0.0, 1.0)
