extends Node3D
## At night the street lamps nearest you light the street for real: a small
## pool of warm OmniLights moved to the LIGHTS nearest lamps (from the loaded
## chunks' lamp positions), so people, cars and walls round you catch their
## light. Every other lamp only glows (its head, and the pool on the stones:
## Materials' "lamp_pool"). Off by day.
##
## The same for headlights: the CARS cars, Cantas and buses nearest you (yours
## first) shine real spotlights down the street ahead of them; the rest only
## have their beams on the stones (Models.beams).
##     street_lights.setup(streamer, traffic); street_lights.night = 0..1; street_lights.focus = position

const LIGHTS := 6
const RANGE := 11.0
const ENERGY := 1.6
const EVERY := 0.4               # seconds between looking for the nearest lamps
const CARS := 3
const LIT_KINDS := ["car", "canta", "bus"]

var streamer
var traffic
var spots: Array[SpotLight3D] = []
var _cars: Array = []            # the vehicles the spots are on just now
var night := 0.0
var focus := Vector3.ZERO
var lights: Array[OmniLight3D] = []
var _t := 0.0


func setup(s, t = null) -> void:
	streamer = s
	traffic = t
	for i in CARS:
		var sp := SpotLight3D.new()
		sp.light_color = Color(1.0, 0.93, 0.8)
		sp.spot_range = 24.0
		sp.spot_angle = 32.0
		sp.spot_attenuation = 1.2
		sp.shadow_enabled = false
		sp.visible = false
		add_child(sp)
		spots.append(sp)
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
	if traffic == null:
		return
	if on and _t >= EVERY - delta - 0.001:          # (with the lamps: who is nearest)
		_cars = cars_near(focus, 60.0).slice(0, CARS)
	for i in CARS:
		var sp := spots[i]
		sp.visible = on and i < _cars.size()
		if not sp.visible:
			continue
		var model := _model(_cars[i])
		var beam: Node3D = model.get_node_or_null("beam") if model else null
		if beam == null or not beam.is_visible_in_tree():
			sp.visible = false
			continue
		var front: float = beam.position.z + 4.6
		sp.global_transform = model.global_transform * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-9.0)), Vector3(0, 0.8, front))
		sp.light_energy = 2.2 * clampf((night - 0.15) / 0.5, 0.0, 1.0)


## The lit vehicles within `r` of `p`, nearest first (the one you drive first of all).
func cars_near(p: Vector3, r: float) -> Array:
	var out := []
	for v in traffic.vehicles:
		if not (v.kind in LIT_KINDS) or v.get("wrecked", false):
			continue
		var d: float = v.pos.distance_to(Vector2(p.x, p.z))
		if v.get("driver", false):
			d = -1.0
		if d < r:
			out.append([d, v])
	out.sort_custom(func(a, b): return a[0] < b[0])
	return out.map(func(a): return a[1])


func _model(v: Dictionary) -> Node3D:
	var m = v.get("rig", null)
	if m == null or not is_instance_valid(m):
		m = v.parts[0][0]
	return m if is_instance_valid(m) else null
