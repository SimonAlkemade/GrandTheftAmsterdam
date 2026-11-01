extends "res://scripts/jobs/job.gd"
## Mission 12, Tram heist: board a tram (any line) and ride it while the
## conductor counts the day's takings; at the end of the count you grab the
## cash bag. Then get away from that tram (STEP_OFF metres) and lose the
## police. Off the tram before the count is done and you start over.

const COUNT := 20.0             # seconds riding until the bag is full
const STEP_OFF := 120.0
const TAKINGS := 280            # in the bag (the job's pay on top)

var phase := "board"            # board, ride, escape
var tram: Dictionary = {}
var _count := COUNT
var _t := 0.0


func _init() -> void:
	title = "MISSION 12: TRAM HEIST"
	briefing = "Ride a tram while the conductor counts the takings, then grab the bag"
	reward = 450


func objective() -> String:
	match phase:
		"board": return "Board a tram (E at a stop, or by one)"
		"ride": return "Ride along while the conductor counts the takings"
		"escape":
			var d := flat_dist(here(), _tram_at())
			if d < STEP_OFF: return "Get off and away from the tram  ·  %d m" % int(STEP_OFF - d)
			return "Lose the police"
	return ""


func clock() -> float:
	return _count if phase == "ride" else -1.0


func _on_tram() -> bool:
	var v = m.walker.vehicle
	return v != null and v.kind == "tram"


func _tram_at() -> Vector3:
	if tram.is_empty() or not m.traffic.vehicles.has(tram):
		return Vector3(INF, 0, INF)
	return Vector3(tram.pos.x, 0, tram.pos.y)


func step(delta: float) -> void:
	_t -= delta
	match phase:
		"board":
			if _on_tram():
				tram = m.walker.vehicle
				phase = "ride"; _count = COUNT
				m._clear()
				say("ALL ABOARD", "The conductor starts counting...")
				return
			if _t <= 0.0:
				_t = 1.0
				var best := INF
				m.target = Vector3.INF
				for v in m.traffic.vehicles:
					if v.kind != "tram": continue
					var d: float = v.pos.distance_to(Vector2(here().x, here().z))
					if d < best:
						best = d; m.target = Vector3(v.pos.x, 0, v.pos.y)
		"ride":
			if not _on_tram():
				phase = "board"; tram = {}
				say("YOU GOT OFF", "The count starts over on the next tram")
				return
			_count -= delta
			if _count <= 0.0:
				phase = "escape"
				m.money += TAKINGS
				m.crime.stars = maxi(m.crime.stars, 2)
				m.crime.last_seen = here(); m.crime.unseen = 0.0
				say("GRAB THE BAG!", "+ €%d. Get off and get away" % TAKINGS)
		"escape":
			if flat_dist(here(), _tram_at()) >= STEP_OFF and not _on_tram() and m.crime.stars == 0:
				succeed("€%d in the bag, and away" % TAKINGS)
