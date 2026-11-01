extends "res://scripts/jobs/job.gd"
## Mission 4, Burn it down: a fixer wants a petrol station gone (the nearest
## one standing). Two Molotovs come with the job. Get there, blow it up (its
## tank has to go: the canopy thrown, the place a ruin), then lose the police.

var station: Dictionary = {}
var phase := "go"             # go, burn, lose
var _t := 0.0


func _init() -> void:
	title = "MISSION 4: BURN IT DOWN"
	reward = 400


func begin() -> void:
	m.crime.molotovs = maxi(m.crime.molotovs, 2)
	station = m.stations.nearest(here()) if m.stations else {}
	if station.is_empty():
		fail("No petrol station anywhere")
		return
	briefing = "A fixer wants the %s gone. Two Molotovs are in your pocket (F)" % station.name
	_aim()


func _aim() -> void:
	var at := street_near(station.pos)
	if at == Vector3.INF:
		at = Vector3(station.pos.x, 0, station.pos.z)
	go_to(at, "drop")


func objective() -> String:
	match phase:
		"go": return "Get to the %s" % station.get("name", "petrol station")
		"burn": return "Blow up the %s: Molotovs (F), or shoot its pumps" % station.get("name", "station")
		"lose": return "Lose the police"
	return ""


func step(delta: float) -> void:
	if station.get("ruined", false) and phase != "lose":
		phase = "lose"
		m._clear()
		say("IT'S GONE", "Now lose the police")
	match phase:
		"go":
			if m.target == Vector3.INF:
				_t -= delta
				if _t <= 0.0:
					_t = 1.0; _aim()
			elif flat_dist(here(), station.get("at", station.pos)) < 45.0:
				phase = "burn"
				m._clear()
				say("THERE IT IS", "Blow it up: the pumps, then the tank under them")
		"burn":
			if flat_dist(here(), station.get("at", station.pos)) > 250.0:
				phase = "go"; _aim()                # wandered off: back you go
		"lose":
			if m.crime.stars == 0:
				succeed("The fixer pays €%d" % reward)
