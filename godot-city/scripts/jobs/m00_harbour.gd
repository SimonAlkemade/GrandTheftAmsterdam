extends "res://scripts/jobs/job.gd"
## The first mission, The container yard: a duffel bag is waiting in one of the
## open containers of a fenced yard in the eastern harbour (Zeeburgereiland,
## scripts/harbour_yard.gd). Get there, cut the fence (E: down on one knee,
## the bolt cutters snipping, the cut flap peeling up), crawl under it (E),
## find the bag in one of the three open containers (E takes it), crawl back
## out and bring it to the van waiting outside.

const Yard := preload("res://scripts/harbour_yard.gd")
const CUT_TIME := 3.2          # seconds at the fence with the cutters (four snips)
const CRAWL_TIME := 2.6        # under the fence
const NEAR := 3.2              # metres from the fence to use it (its circle, Mission.CIRCLE, and a little)
const REACH := 1.6             # metres from the bag to take it
## The cutters in your right hand: turned so the grips are in it, the jaws forward.
const CUTTER_XF := Transform3D(Basis(Vector3.UP, PI), Vector3(0, 0, 0.56))
const BAG_XF := Transform3D(Basis(Vector3.UP, PI / 2), Vector3(0, -0.02, 0))

var yard_origin := Yard.ORIGIN
var yard
var phase := "go"              # go, cut, hole, crawl_in, search, out, crawl_out, deliver
var _arrived := false


func _init() -> void:
	title = "THE CONTAINER YARD"
	briefing = "Get a duffel bag out of a container in the eastern harbour. Go under the fence"
	reward = 400


func begin() -> void:
	var at := yard_origin
	if at == Yard.ORIGIN and m.streamer != null and m.streamer.has_method("compact_point"):
		var c: Vector2 = m.streamer.compact_point(Vector2(at.x, at.z))
		at = Vector3(c.x, 0.0, c.y)
	yard = Yard.new()
	yard.origin = at
	add_child(yard)
	yard.build(randi())
	go_to(yard.cut_out(), "drop")


func objective() -> String:
	match phase:
		"go": return "Get to the container yard on Zeeburgereiland, in the eastern harbour"
		"cut": return "Cut through the fence"
		"hole": return "Crawl under the fence"
		"crawl_in", "crawl_out": return ""
		"search": return "Find the duffel bag in one of the open containers"
		"out": return "Crawl back out under the fence"
		"deliver": return "Bring the bag to the van"
	return ""


func step(_delta: float) -> void:
	var w = m.walker
	if w.performing():
		return
	var on_foot: bool = w.vehicle == null
	match phase:
		"go", "hole":
			if on_foot and flat_dist(here(), yard.cut_out()) < NEAR:
				if not _arrived:
					_arrived = true
					m._clear()                       # (there: the circle and the route go)
				if phase == "go":
					_offer("E  cut the fence", _cut)
				else:
					_offer("E  crawl under the fence", _crawl_in)
			else:
				_withdraw()
		"search":
			var b: Vector3 = yard.bag_at()
			if b != Vector3.INF and flat_dist(here(), b) < REACH:
				_offer("E  take the duffel bag", _take)
			else:
				_withdraw()
		"out":
			if flat_dist(here(), yard.cut_in()) < NEAR:
				_offer("E  crawl under the fence", _crawl_out)
			else:
				_withdraw()
		"deliver":
			if flat_dist(here(), yard.at(Yard.VAN.x, Yard.VAN.y)) < 3.5:
				_withdraw()
				m.walker.drop_held()
				succeed("The bag is in the van")


func _offer(prompt: String, what: Callable) -> void:
	m.walker.task = {"prompt": prompt, "do": what, "job": self}


func _withdraw() -> void:
	if m != null and m.walker != null and m.walker.task.get("job") == self:
		m.walker.task = {}


# The heading that faces from a to b.
static func _facing(a: Vector3, b: Vector3) -> float:
	var d := b - a
	return atan2(-d.x, -d.z)


func _cut() -> void:
	_withdraw()
	phase = "cut"
	var cutter: Node3D = (load("res://models/bolt_cutter.glb") as PackedScene).instantiate()
	m.walker.hold(cutter, CUTTER_XF)
	var ap: AnimationPlayer = cutter.find_child("AnimationPlayer", true, false)
	if ap:
		ap.get_animation("cut").loop_mode = Animation.LOOP_LINEAR
		ap.play("cut")
	m.walker.perform("cut", CUT_TIME, yard.cut_out(), yard.cut_out(), _facing(yard.cut_out(), yard.cut_in()), _cut_done)


func _cut_done() -> void:
	m.walker.drop_held()
	if yard.flap_anim:
		yard.flap_anim.play("peel")
	phase = "hole"
	say("THE FENCE IS CUT", "Crawl under it")


func _crawl_in() -> void:
	_withdraw()
	phase = "crawl_in"
	m.walker.perform("crawl", CRAWL_TIME, yard.cut_out(), yard.cut_in(), _facing(yard.cut_out(), yard.cut_in()),
		func(): phase = "search")


func _take() -> void:
	_withdraw()
	yard.bag.queue_free()
	yard.bag = null
	var bag: Node3D = (load("res://models/duffel.glb") as PackedScene).instantiate()
	m.walker.hold(bag, BAG_XF)
	phase = "out"
	say("GOT IT", "Now out the way you came")


func _crawl_out() -> void:
	_withdraw()
	phase = "crawl_out"
	m.walker.perform("crawl", CRAWL_TIME, yard.cut_in(), yard.cut_out(), _facing(yard.cut_in(), yard.cut_out()),
		func():
			phase = "deliver"
			go_to(yard.at(Yard.VAN.x, Yard.VAN.y), "drop"))


func _exit_tree() -> void:
	_withdraw()
	if m != null and m.walker != null and phase in ["cut", "out", "crawl_out", "deliver", "crawl_in", "search"]:
		m.walker.drop_held()
