extends "res://scripts/jobs/job.gd"
## Mission 10, Pizza run: on the Canta (or any car), fetch PIZZAS pizzas from
## the pizzeria and deliver them, one door after the other, while they are
## hot. Each cools from the moment you pick it up; the customer pays more the
## hotter it is, and sends a cold one back. Every pizza delivered, hot or
## cold, and the job is done.

const PIZZAS := 3
const COOL := 100.0             # seconds from the oven to stone cold
const PRICE := 12
const TIP := 10                 # at full heat

var phase := "ride"             # ride, fetch, deliver
var left := 0                   # pizzas still in the box
var heat := 1.0                 # 1 hot .. 0 cold
var earned := 0
var _t := 0.0


func _init() -> void:
	title = "MISSION 10: PIZZA RUN"
	briefing = "Fetch %d pizzas and deliver them while they are hot" % PIZZAS
	reward = 250


func objective() -> String:
	match phase:
		"ride": return "Get in a Canta (or any car) for the pizzas"
		"fetch": return "Fetch the pizzas at the pizzeria on %s" % m.target_name
		"deliver": return "Deliver a pizza to %s  ·  %d left, %d%% hot" % [m.target_name, left, int(heat * 100.0)]
	return ""


func clock() -> float:
	return heat * COOL if phase == "deliver" else -1.0


func _riding() -> bool:
	var v = m.walker.vehicle
	return v != null and v.kind in ["canta", "car"] and v.get("driver", false)


func step(delta: float) -> void:
	_t -= delta
	match phase:
		"ride":
			if _riding() and _t <= 0.0:
				_t = 1.0
				if _place(Vector2(120.0, 350.0)):
					phase = "fetch"
					say("THE PIZZERIA", "On %s" % m.target_name)
		"fetch":
			if m.target != Vector3.INF and flat_dist(here(), m.target) < m.CIRCLE + 2.0:
				left = PIZZAS
				heat = 1.0
				phase = "deliver"
				_place(Vector2(150.0, 400.0))
				say("%d PIZZAS, HOT" % PIZZAS, "First stop: %s" % m.target_name)
		"deliver":
			heat = maxf(0.0, heat - delta / COOL)
			if m.target == Vector3.INF:
				if _t <= 0.0:
					_t = 1.0; _place(Vector2(150.0, 400.0))
				return
			if flat_dist(here(), m.target) < m.CIRCLE + 2.0:
				_deliver()


func _deliver() -> void:
	left -= 1
	if heat < 0.2:
		say("COLD!", "They sent it back. %d left" % left)
	else:
		var pay := PRICE + int(TIP * heat)
		m.money += pay
		earned += pay
		say("DELIVERED", "+ €%d (%d%% hot)  ·  %d left" % [pay, int(heat * 100.0), left])
	if left <= 0:
		m._clear()
		succeed("€%d in pizzas and tips, and the pay" % earned)
		return
	_place(Vector2(150.0, 400.0))


func _place(d: Vector2) -> bool:
	var at: Vector3 = m._choose(Vector2(here().x, here().z), d)
	if at == Vector3.INF:
		return false
	go_to(at, "pickup" if phase == "ride" else "drop")
	return true
