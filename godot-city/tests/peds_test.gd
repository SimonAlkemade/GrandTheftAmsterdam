extends SceneTree
## Pedestrians keep their distance: one walking straight at you veers off and
## walks on, two meeting head-on pass each other, and in a crowd nobody ever
## overlaps anyone, you included.
##     godot --headless --path godot-city --script tests/peds_test.gd

const Walker := preload("res://scripts/walker.gd")
const Human := preload("res://scripts/human.gd")


# The city as far as pedestrians need it: open street everywhere.
class OpenStreet:
	func water_at(_p: Vector3) -> int:
		return 0


var _fails := 0
var w
var rng := RandomNumberGenerator.new()


func _initialize() -> void:
	w = Walker.new()
	w.streamer = OpenStreet.new()
	root.add_child(w)
	w.global_position = Vector3.ZERO
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _ped(at: Vector3, heading: float) -> Dictionary:
	var p := {"h": Human.new(), "pos": at, "heading": heading, "speed": 1.3, "turn": 1e9, "stag": 0.0}
	p.h.random_look(rng)
	root.add_child(p.h)
	w.peds.append(p)
	return p


func _clear() -> void:
	for p in w.peds: p.h.queue_free()
	w.peds.clear()


# Heading that walks from a towards b.
func _toward(a: Vector3, b: Vector3) -> float:
	var d := b - a
	return atan2(-d.x, -d.z)


func _run() -> void:
	rng.seed = 3
	# 1. Someone walks straight at you, standing still.
	var p := _ped(Vector3(0, 0, -8), _toward(Vector3(0, 0, -8), Vector3.ZERO))
	var closest := INF
	for i in 60 * 12:
		w._peds(1.0 / 60.0)
		closest = minf(closest, Vector2(p.pos.x, p.pos.z).length())
		await process_frame
	print("walking at you: closest %.2f m, ended %.1f m away" % [closest, Vector2(p.pos.x, p.pos.z).length()])
	_check(closest > 1.4, "someone walking straight at you veers off (closest %.2f m)" % closest)
	_check(Vector2(p.pos.x, p.pos.z).length() > 5.0, "and walks on past you")
	_clear()
	# 2. Two people meet head-on, 10 m apart, away from you.
	var a := _ped(Vector3(20, 0, -5), PI)            # heading +Z
	var b := _ped(Vector3(20, 0, 5), 0.0)            # heading -Z
	closest = INF
	for i in 60 * 12:
		w._peds(1.0 / 60.0)
		closest = minf(closest, (a.pos - b.pos).length())
		await process_frame
	print("head-on: closest %.2f m; a at z %.1f, b at z %.1f" % [closest, a.pos.z, b.pos.z])
	_check(closest > 0.85, "two people meeting head-on keep apart (closest %.2f m)" % closest)
	_check(a.pos.z > 3.0 and b.pos.z < -3.0, "and pass each other")
	_clear()
	# 3. A crowd of 20 milling round you in 12 x 12 m.
	for k in 20:
		var pt := Vector3(rng.randf_range(-6, 6), 0, rng.randf_range(-6, 6))
		if pt.length() < 1.2: pt = pt.normalized() * 2.0 if pt.length() > 0.01 else Vector3(2, 0, 0)
		var q := _ped(pt, rng.randf() * TAU)
		q.turn = rng.randf_range(0.5, 3.0)
	var worst_pair := INF
	var worst_you := INF
	for i in 60 * 10:
		w._peds(1.0 / 60.0)
		for x in w.peds.size():
			var q: Dictionary = w.peds[x]
			worst_you = minf(worst_you, Vector2(q.pos.x, q.pos.z).length())
			for y in range(x + 1, w.peds.size()):
				var r: Dictionary = w.peds[y]
				worst_pair = minf(worst_pair, Vector2(q.pos.x - r.pos.x, q.pos.z - r.pos.z).length())
		await process_frame
	print("crowd: closest pair %.2f m, closest to you %.2f m" % [worst_pair, worst_you])
	_check(worst_pair >= Walker.PED_GAP - 0.05, "in a crowd nobody overlaps (closest pair %.2f m)" % worst_pair)
	_check(worst_you >= Walker.YOU_GAP - 0.05, "and nobody walks into you (closest %.2f m)" % worst_you)
	print("peds test: %d failed" % _fails)
	quit(1 if _fails else 0)
