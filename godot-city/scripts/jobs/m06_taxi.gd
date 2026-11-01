extends "res://scripts/jobs/job.gd"
## Mission 6, Taxi: in any car, pick up the people hailing a taxi ("TAXI!"
## over their heads) and drive them where they want to go before their
## patience runs out: a fare and a tip for the time to spare. FARES fares
## done (late ones still count, without pay) and the job pays its bonus.

const FARES := 5
const FARE := 15
const PICKUP_NEAR := 7.0

var phase := "car"              # car, hail, ride
var fare: Dictionary = {}       # the person waiting, or riding
var done := 0
var earned := 0
var _left := 0.0
var _t := 0.0
var _sign: Label3D


func _init() -> void:
	title = "MISSION 6: TAXI"
	briefing = "Get in a car and drive %d fares across town" % FARES
	reward = 300


func objective() -> String:
	match phase:
		"car": return "Get in a car to drive the taxi"
		"hail": return "Pick up the fare hailing you  ·  %d / %d" % [done, FARES]
		"ride": return "Drive the fare to %s  ·  %d / %d" % [m.target_name, done, FARES]
	return ""


func clock() -> float:
	return _left if phase == "ride" else -1.0


func _in_car() -> bool:
	var v = m.walker.vehicle
	return v != null and v.kind in ["car", "canta"] and v.get("driver", false)


func step(delta: float) -> void:
	_t -= delta
	match phase:
		"car":
			if _in_car():
				phase = "hail"; _t = 0.0
		"hail":
			if fare.is_empty() or not m.walker.peds.has(fare) or fare.get("dead", false) or fare.has("rag"):
				_drop_sign()
				fare = {}
				if _t <= 0.0:
					_t = 1.0
					_hail()
				return
			_sign.global_position = fare.pos + Vector3(0, 2.6, 0)
			fare.wait = 1.0                     # waiting at the kerb
			m.target = fare.pos
			if _in_car() and flat_dist(here(), fare.pos) < PICKUP_NEAR:
				_board()
		"ride":
			fare.pos = here()                   # (riding along: never left behind)
			_left -= delta
			if not _in_car():
				return
			if m.target != Vector3.INF and flat_dist(here(), m.target) < m.CIRCLE + 3.0:
				_arrive()
			elif _left <= 0.0 and not fare.get("late", false):
				fare.late = true
				say("TOO SLOW", "No fare for this one: get them there anyway")


# Someone on the pavement 25-90 m off hails you.
func _hail() -> void:
	var pool := []
	for p in m.walker.peds:
		if p.get("dead", false) or p.has("rag") or p.get("flee", 0.0) > 0.0 or p.get("aflame", false) or m.tourists.has(p):
			continue
		var d := flat_dist(p.pos, here())
		if d > 25.0 and d < 90.0:
			pool.append(p)
	if pool.is_empty():
		return
	fare = pool[m._rng.randi() % pool.size()]
	_sign = Label3D.new()
	_sign.text = "TAXI!"
	_sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sign.font_size = 96; _sign.pixel_size = 0.006
	_sign.modulate = Color(1.0, 0.85, 0.1)
	_sign.outline_size = 18
	_sign.no_depth_test = true
	add_child(_sign)
	_sign.global_position = fare.pos + Vector3(0, 2.6, 0)


func _board() -> void:
	var at: Vector3 = m._choose(Vector2(here().x, here().z), Vector2(250.0, 650.0))
	if at == Vector3.INF:
		return
	_drop_sign()
	fare.h.visible = false
	fare.in_taxi = true
	phase = "ride"
	go_to(at, "drop")
	_left = 25.0 + m.route_len / 7.0
	say("FARE", "To %s" % m.target_name)


func _arrive() -> void:
	var tip := 0 if fare.get("late", false) else int(_left / 3.0)
	var pay := 0 if fare.get("late", false) else FARE + tip
	m.money += pay
	earned += pay
	done += 1
	fare.h.visible = true
	fare.erase("in_taxi"); fare.erase("late")
	fare.pos = here() + Vector3(2.5, 0, 0)
	fare.h.position = fare.pos
	fare = {}
	m._clear()
	if done >= FARES:
		succeed("%d fares, €%d in fares and tips, and the bonus" % [done, earned])
		return
	say("FARE PAID", "+ €%d%s" % [pay, ("  (€%d tip)" % tip) if tip > 0 else ""])
	phase = "hail"; _t = 1.5


func _drop_sign() -> void:
	if _sign:
		_sign.queue_free()
		_sign = null


func _exit_tree() -> void:
	if not fare.is_empty() and fare.get("in_taxi", false):
		fare.h.visible = true
		fare.erase("in_taxi")
