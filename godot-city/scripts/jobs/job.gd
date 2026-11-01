extends Node3D
## A job: one of the missions after the first three, run by Mission while its
## state is "job". A job places its target with `go_to` (a yellow circle, the
## route over the streets, the minimap blip, all Mission's) and calls
## `succeed` or `fail` when it is over; Mission pays, announces and moves on
## to the next job (or tries this one again after a failure).
##
## A job subclass fills in:
##   title, briefing, reward
##   begin()               set up: actors, the first target
##   step(delta)           every frame while it runs
##   objective() -> text   for the bar at the top of the screen
##   clock() -> seconds    left on its clock, or -1 for none
##   caught(how)           you were "wasted" or "busted" while on the job

signal finished(ok: bool, why: String)

var m                         # Mission
var title := "A JOB"
var briefing := ""
var reward := 100
var over := false


func begin() -> void:
	pass


func step(_delta: float) -> void:
	pass


func objective() -> String:
	return ""


func clock() -> float:
	return -1.0


## Wasted or busted on the job: by default that is the job failed.
func caught(how: String) -> void:
	fail("You got %s" % how.to_lower())


func succeed(why := "") -> void:
	if over: return
	over = true
	finished.emit(true, why)


func fail(why := "") -> void:
	if over: return
	over = true
	finished.emit(false, why)


# ---- for the jobs ----------------------------------------------------------------

## A yellow circle at `at` (the route there over the streets).
func go_to(at: Vector3, kind := "drop") -> void:
	m._place(at, kind)


## The street spot nearest `at` that the routing reaches (INF while not loaded).
func street_near(at: Vector3) -> Vector3:
	return m._street_near(Vector2(at.x, at.z))


func here() -> Vector3:
	return m.walker.global_position


func flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func say(t: String, s := "") -> void:
	m.announce.emit(t, s)
