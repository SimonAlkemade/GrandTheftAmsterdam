extends "res://scripts/jobs/job.gd"
## Mission 13, The big one: rob the gun shop on the Dam (walk in, a pistol in
## your hand), then with five stars on you get to a boat and away over the
## water: LOSE metres from the shop by boat and the police lose you in the
## canals. Then the credits.

const LOSE := 400.0
const TAKE := 1000              # in the till

var phase := "arm"              # arm, rob, boat, escape
var _t := 0.0


func _init() -> void:
	title = "MISSION 13: THE BIG ONE"
	briefing = "Rob the gun shop and get away by boat"
	reward = 1500


func objective() -> String:
	match phase:
		"arm": return "Get a pistol (a pickup, or the shop's)"
		"rob": return "Rob %s" % m.crime.shop_name
		"boat": return "Get to a boat!"
		"escape":
			return "Away over the water  ·  %d m" % maxi(0, int(LOSE - flat_dist(here(), m.crime.shop)))
	return ""


func _in_boat() -> bool:
	return m.walker.vehicle != null and m.walker.vehicle.kind == "boat"


func step(delta: float) -> void:
	_t -= delta
	var c = m.crime
	match phase:
		"arm":
			if c.armed:
				phase = "rob"
				say("ARMED", "Now the gun shop")
		"rob":
			if c.shop == Vector3.INF:
				return
			m.target = c.shop
			if not c.armed:
				phase = "arm"; return
			if m.walker.vehicle == null and flat_dist(here(), c.shop) < 3.5:
				m.money += TAKE
				c.stars = 5
				c.last_seen = here(); c.unseen = 0.0
				phase = "boat"
				routed = false
				m._clear()
				say("FIVE STARS!", "+ €%d. Get to a boat!" % TAKE)
		"boat":
			if _in_boat():
				phase = "escape"
				say("FULL THROTTLE", "Get %d m away over the water" % int(LOSE))
				return
			if _t <= 0.0 and m.boats:
				_t = 1.0
				var b: Dictionary = m.boats.nearest(Vector2(here().x, here().z), 800.0)
				m.target = Vector3(b.pos.x, 0, b.pos.y) if not b.is_empty() else Vector3.INF
		"escape":
			m.target = Vector3.INF
			c.stars = maxi(c.stars, 1) if flat_dist(here(), c.shop) < LOSE else c.stars
			if _in_boat() and flat_dist(here(), c.shop) >= LOSE:
				c.stars = 0
				succeed("They lost you in the canals")
