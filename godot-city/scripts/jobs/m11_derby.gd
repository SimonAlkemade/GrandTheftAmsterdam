extends "res://scripts/jobs/job.gd"
## Mission 11, Demolition derby: TARGETS cars in the streets round you are
## marked (a red arrow over each, red blips). Wreck them all, any way you
## like (ram them, shoot their tanks, a grenade, a Molotov, a petrol pump),
## before the clock runs out. A marked car that drives off out of reach is
## swapped for another.

const TARGETS := 5
const TIME := 240.0

var marked: Array = []          # {v, arrow}
var wrecked := 0
var _left := TIME
var _t := 0.0


func _init() -> void:
	title = "MISSION 11: DEMOLITION DERBY"
	briefing = "Wreck the %d marked cars, any way you like" % TARGETS
	reward = 500
	routed = false


func objective() -> String:
	return "Wreck the marked cars  ·  %d / %d" % [wrecked, TARGETS]


func clock() -> float:
	return _left


func step(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		fail("Out of time: %d of %d wrecked" % [wrecked, TARGETS])
		return
	var here2 := Vector2(here().x, here().z)
	for mk in marked.duplicate():
		var v: Dictionary = mk.v
		if v.get("wrecked", false):
			_unmark(mk)
			wrecked += 1
			if wrecked >= TARGETS:
				succeed("%d cars wrecked, %.0f s to spare" % [wrecked, _left])
				return
			say("WRECKED", "%d to go" % (TARGETS - wrecked))
			continue
		if not m.traffic.vehicles.has(v) or v.pos.distance_to(here2) > 400.0:
			_unmark(mk)                                   # gone: another in its place
			continue
		var n: Node3D = v.get("rig", v.parts[0][0])
		if is_instance_valid(n):
			mk.arrow.global_position = n.global_position + Vector3(0, 3.0 + sin(Time.get_ticks_msec() / 250.0) * 0.2, 0)
			mk.arrow.rotation.y += delta * 2.0
	_t -= delta
	if marked.size() < TARGETS - wrecked and _t <= 0.0:
		_t = 0.5
		_mark()
	# The nearest marked car is the minimap's blip.
	var best := INF
	m.target = Vector3.INF
	for mk in marked:
		var d: float = mk.v.pos.distance_to(here2)
		if d < best:
			best = d
			m.target = Vector3(mk.v.pos.x, 0, mk.v.pos.y)


func _mark() -> void:
	var here2 := Vector2(here().x, here().z)
	for v in m.traffic.vehicles:
		if v.kind != "car" or v.get("police", false) or v.get("wrecked", false) or v.get("driver", false) \
				or v.get("burning", false) or marked.any(func(mk): return is_same(mk.v, v)):
			continue
		var d: float = v.pos.distance_to(here2)
		if d > 20.0 and d < 220.0:
			var a := MeshInstance3D.new()                  # a red arrow, pointing down at it
			var cone := CylinderMesh.new(); cone.top_radius = 0.6; cone.bottom_radius = 0.0; cone.height = 1.1; cone.radial_segments = 4
			a.mesh = cone
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(1.0, 0.18, 0.12)
			mat.no_depth_test = true
			mat.render_priority = 2
			a.material_override = mat
			a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(a)
			marked.append({"v": v, "arrow": a})
			return


func _unmark(mk: Dictionary) -> void:
	marked.erase(mk)
	if is_instance_valid(mk.arrow):
		mk.arrow.queue_free()
