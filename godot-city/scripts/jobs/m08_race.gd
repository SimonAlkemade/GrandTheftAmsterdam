extends "res://scripts/jobs/job.gd"
## Mission 8, Bike race: on a bike, ride a course of CHECKPOINTS circles
## through the streets against the clock. A countdown, then GO; every
## checkpoint passed puts time back on the clock for the next leg (by its
## length along the streets, at a brisk BIKE_SPEED). Run out and you lose.

const CHECKPOINTS := 6
const BIKE_SPEED := 6.5          # m/s the clock allows: pedalling hard
const SPARE := 8.0               # seconds over, each leg
const LEG := Vector2(110.0, 220.0)     # metres between checkpoints

var phase := "bike"             # bike, ready, race
var passed := 0
var _left := 0.0
var _count := 0.0
var _from := Vector2.INF


func _init() -> void:
	title = "MISSION 8: BIKE RACE"
	briefing = "On a bike: %d checkpoints against the clock" % CHECKPOINTS
	reward = 350


func objective() -> String:
	match phase:
		"bike": return "Get on a bike (E by a parked one)"
		"ready": return "Get ready..."
		"race": return "Checkpoint %d / %d" % [passed + 1, CHECKPOINTS]
	return ""


func clock() -> float:
	return _left if phase == "race" else -1.0


func _on_bike() -> bool:
	return m.walker.vehicle != null and m.walker.vehicle.kind == "bike"


func step(delta: float) -> void:
	match phase:
		"bike":
			if _on_bike():
				phase = "ready"; _count = 3.0
				say("3", "")
		"ready":
			var before := ceili(_count)
			_count -= delta
			if ceili(_count) != before and _count > 0.0:
				say(str(ceili(_count)), "")
			if _count <= 0.0:
				_from = Vector2(here().x, here().z)
				if _next():
					_left = _leg_time()
					phase = "race"
					say("GO!", "%d checkpoints, %.0f seconds to the first" % [CHECKPOINTS, _left])
				else:
					_count = 0.5               # (the streets not loaded yet)
		"race":
			_left -= delta
			if _left <= 0.0:
				fail("Out of time at checkpoint %d" % (passed + 1))
				return
			if m.target != Vector3.INF and flat_dist(here(), m.target) < m.CIRCLE + 2.0:
				passed += 1
				if passed >= CHECKPOINTS:
					succeed("All %d checkpoints, %.0f s to spare" % [CHECKPOINTS, _left])
					return
				_from = Vector2(m.target.x, m.target.z)
				_next()
				var more := _leg_time()
				_left += more
				say("CHECKPOINT %d" % passed, "+%d s" % int(more))


func _leg_time() -> float:
	var d: float = m.route_len if m.route_len > 0.0 else flat_dist(here(), m.target) * 1.4
	return d / BIKE_SPEED + SPARE


func _next() -> bool:
	var at: Vector3 = m._choose(_from, LEG)
	if at == Vector3.INF:
		at = m._choose(_from, Vector2(60.0, 400.0))
	if at == Vector3.INF:
		return false
	go_to(at, "drop")
	return true
