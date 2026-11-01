extends "res://scripts/jobs/job.gd"
## Mission 5, Getaway: steal the marked car (parked, a circle round it),
## drive it to the bank where the crew comes running out with the money, then
## with three stars on you get them to the garage before the clock runs out.
## The car wrecked, left behind, or the clock run out: failed.

const ESCAPE_TIME := 180.0
const LEAVE_GRACE := 12.0       # seconds out of the car before the job is off

var car: Dictionary = {}
var phase := "find"             # find, steal, bank, escape
var _t := 0.0
var _left := ESCAPE_TIME
var _out := 0.0


func _init() -> void:
	title = "MISSION 5: GETAWAY"
	briefing = "Steal the marked car, pick the crew up at the bank, and lose the police"
	reward = 600


func begin() -> void:
	_t = 0.0


func objective() -> String:
	match phase:
		"find": return "Find a car to steal"
		"steal": return "Steal the marked car (E)"
		"bank": return "Drive to the bank on %s to pick up the crew" % m.target_name
		"escape": return "Get the crew to the garage on %s" % m.target_name
	return ""


func clock() -> float:
	return _left if phase == "escape" else -1.0


func step(delta: float) -> void:
	_t -= delta
	match phase:
		"find":
			if _t <= 0.0:
				_t = 1.0
				_mark()
		"steal":
			if not m.traffic.vehicles.has(car) or car.get("wrecked", false):
				phase = "find"; m._clear(); return
			if m.walker.vehicle != null and is_same(m.walker.vehicle, car):
				var at: Vector3 = _somewhere(Vector2(350.0, 750.0))
				if at == Vector3.INF:
					return
				phase = "bank"
				go_to(at, "pickup")
				say("NICE WHEELS", "Now the bank on %s" % m.target_name)
		"bank", "escape":
			if not m.traffic.vehicles.has(car) or car.get("wrecked", false):
				fail("The car is wrecked")
				return
			if m.walker.vehicle == null or not is_same(m.walker.vehicle, car):
				_out += delta
				if _out > LEAVE_GRACE:
					fail("You left the car")
				return
			_out = 0.0
			if phase == "escape":
				_left -= delta
				if _left <= 0.0:
					fail("Too slow: the crew is caught")
					return
			if m.target != Vector3.INF and flat_dist(here(), m.target) < m.CIRCLE + 2.0:
				if phase == "bank":
					_robbed()
				else:
					m.crime.stars = 0
					succeed("The garage door rolls down behind you")


# A car in the street, not too near, parked where it is: the one to steal.
func _mark() -> void:
	var best := {}
	for v in m.traffic.vehicles:
		if v.kind != "car" or v.get("police", false) or v.get("driver", false) or v.get("wrecked", false) or v.has("chase"):
			continue
		var d := flat_dist(Vector3(v.pos.x, 0, v.pos.y), here())
		if d > 30.0 and d < 160.0:
			best = v
			break
	if best.is_empty():
		return
	car = best
	car.parked = true
	car.speed = 0.0
	car.job_car = true
	phase = "steal"
	go_to(Vector3(car.pos.x, 0, car.pos.y), "pickup")


func _robbed() -> void:
	var at: Vector3 = _somewhere(Vector2(500.0, 900.0))
	if at == Vector3.INF:
		return
	phase = "escape"
	_left = ESCAPE_TIME
	go_to(at, "drop")
	m.crime.stars = maxi(m.crime.stars, 3)
	m.crime.last_seen = here()
	m.crime.unseen = 0.0
	say("THE ALARM!", "Three stars. Get the crew to the garage on %s" % m.target_name)


func _somewhere(d: Vector2) -> Vector3:
	var at: Vector3 = m._choose(Vector2(here().x, here().z), d)
	if at == Vector3.INF:
		at = m._choose(Vector2(here().x, here().z), Vector2(150.0, 1200.0))
	return at
