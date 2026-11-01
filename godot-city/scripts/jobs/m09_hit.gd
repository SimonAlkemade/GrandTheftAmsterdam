extends "res://scripts/jobs/job.gd"
## Mission 9, The hit: a man in a white suit is holding court on a corner,
## two bodyguards in black beside him. Find him (the red blip, his
## description at the top of the screen) and take him out, any way you like.
## Come close, shoot, or hurt him and the guards come for you with their
## fists. Then get out of there: lose the police.
##
## They are pedestrians like any other (Walker.peds: bullets, blasts, fire and
## cars all work on them) but `scripted`: this job moves them.

const GUARDS := 2
const NOTICE := 14.0            # metres: come this close and the guards notice you
const PUNCH := 9.0              # health a punch takes
const PUNCH_EVERY := 1.1
const GUARD_SPEED := 4.0

const Human := preload("res://scripts/human.gd")

var phase := "find"             # find, hit, lose
var target: Dictionary = {}
var guards: Array = []
var hostile := false
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	title = "MISSION 9: THE HIT"
	briefing = "The man in the white suit: take him out. Mind his two bodyguards"
	reward = 800
	_rng.randomize()


func objective() -> String:
	match phase:
		"find": return "Find the man in the white suit"
		"hit": return "Take out the man in the white suit"
		"lose": return "Lose the police"
	return ""


func step(delta: float) -> void:
	_t -= delta
	match phase:
		"find":
			if _t <= 0.0:
				_t = 1.0
				_spawn()
		"hit":
			if not m.walker.peds.has(target):
				fail("He got away"); return
			m.target = target.pos
			if target.get("dead", false) or target.has("rag"):      # shot, blown up, burnt, run over
				phase = "lose"
				m._clear()
				say("HE'S DOWN", "Now lose the police")
				return
			if not hostile and (flat_dist(here(), target.pos) < NOTICE or target.has("rag") \
					or guards.any(func(g): return g.get("dead", false) or g.has("rag") or g.get("flee", 0.0) > 0.0)):
				hostile = true
				say("BODYGUARDS!", "They are coming for you")
			if hostile:
				_guards(delta)
			else:
				for g in guards: g.h.animate(delta, "idle", 0.0)
				target.h.animate(delta, "idle", 0.0)
		"lose":
			if hostile:
				_guards(delta)
			if m.crime.stars == 0:
				succeed("The client pays €%d" % reward)


# The man and his guards, on a corner 90-220 m off.
func _spawn() -> void:
	var at: Vector3 = m._choose(Vector2(here().x, here().z), Vector2(90.0, 220.0))
	if at == Vector3.INF:
		return
	target = _person(at, Color("f2f2f2"), Color("e8e8e8"))
	for i in GUARDS:
		var a := TAU * i / GUARDS
		guards.append(_person(at + Vector3(cos(a), 0, sin(a)) * 1.6, Color("141414"), Color("1a1a1a")))
	phase = "hit"
	m.target = target.pos


func _person(at: Vector3, top: Color, legs: Color) -> Dictionary:
	var h = Human.new()
	h.build(top, legs, Color(["f1c7a5", "d9a07a", "a56a43", "6b4128"][_rng.randi() % 4]), Color("1b120c"), Color("141414"))
	m.walker.get_parent().add_child(h)
	h.position = at
	var p := {"h": h, "pos": at, "heading": _rng.randf() * TAU, "speed": 0.0, "turn": 1e9, "stag": 0.0, "scripted": true, "punch": 0.0}
	h.rotation.y = p.heading
	m.walker.peds.append(p)
	return p


# The guards: run at you, and punch when they reach you.
func _guards(delta: float) -> void:
	for g in guards:
		if g.get("dead", false) or g.has("rag") or g.get("hitstop", 0.0) > 0.0:
			continue
		var to: Vector3 = here() - g.pos; to.y = 0.0
		var d := to.length()
		g.heading = atan2(-to.x, -to.z)
		g.h.rotation.y = g.heading
		g.punch = g.punch - delta
		if d > 1.3:
			var step_v: Vector3 = to / maxf(d, 0.01) * GUARD_SPEED * delta
			if m.walker._free(g.pos + step_v * 4.0) or d < 4.0:
				g.pos += step_v
			g.h.position = g.pos
			g.h.animate(delta, "run", GUARD_SPEED)
		else:
			g.h.animate(delta, "idle", 0.0)
			if g.punch <= 0.0 and m.walker.vehicle == null:
				g.punch = PUNCH_EVERY
				m.walker.hurt(PUNCH)
				if m.crime.sfx: m.crime.sfx.play("flesh", here() + Vector3(0, 1.4, 0), "Impacts")
				if m.walker.juice: m.walker.juice.add(0.25, 0.0, 0.0, 12.0)


func _exit_tree() -> void:
	for p in [target] + guards:                       # the job over: they are passers-by again
		if not p.is_empty():
			p.erase("scripted")
