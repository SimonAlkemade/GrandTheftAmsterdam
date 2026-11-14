extends SceneTree
## How the people move (human.gd animate(), which the rigged man and woman
## copy): the legs keep pace with the ground (no skating), the body moves in
## the gait (the pelvis sways and turns, the shoulders turn against it, the
## head stays steady), they start off without a jump, stand with a living
## weight shift, out of step with each other, and stand straight again.
##     godot --headless --path godot-city --script tests/anim_test.gd

const Human := preload("res://scripts/human.gd")
const DT := 1.0 / 60.0

var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _person(seed: int) -> Node3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var h = Human.new()
	h.random_look(rng)
	root.add_child(h)
	return h


# The stride (metres a full leg cycle covers) at `speed`, from the left hip's
# upward zero crossings over 6 s.
func _stride(h, state: String, speed: float) -> float:
	for i in 120:
		h.animate(DT, state, speed)                # (settle into the gait)
	var crossings: Array = []
	var last: float = h.hp_l.rotation.x
	for i in 360:
		h.animate(DT, state, speed)
		var now: float = h.hp_l.rotation.x
		if last < 0.0 and now >= 0.0:
			crossings.append(i * DT)
		last = now
	if crossings.size() < 2:
		return INF
	var period: float = (crossings[-1] - crossings[0]) / (crossings.size() - 1)
	return period * speed


func _range(f: Callable, h, state: String, speed: float, frames: int) -> float:
	var lo := INF; var hi := -INF
	for i in frames:
		h.animate(DT, state, speed)
		var v: float = f.call(h)
		lo = minf(lo, v); hi = maxf(hi, v)
	return hi - lo


func _run() -> void:
	var h = _person(1)
	# 1. No skating: the legs cycle as fast as the ground goes by.
	var walk := _stride(h, "walk", 1.5)
	_check(walk > 1.1 and walk < 1.8, "walking at 1.5 m/s: a stride of %.2f m (a person's is about 1.4)" % walk)
	var run := _stride(h, "run", 5.0)
	_check(run > 1.8 and run < 3.2, "running at 5 m/s: a stride of %.2f m" % run)
	# 2. The body in the gait.
	var sway := _range(func(p): return p.hips.position.x, h, "walk", 1.5, 120)
	_check(sway > 0.015, "the hips sway side to side (%.1f cm)" % (sway * 100.0))
	var opposite := 0
	var samples := 0
	var head_lo := INF; var head_hi := -INF; var sp_lo := INF; var sp_hi := -INF
	for i in 120:
		h.animate(DT, "walk", 1.5)
		var pel: float = h.hips.rotation.y
		var chest: float = h.spine.rotation.y          # (relative to the pelvis)
		if absf(pel) > 0.02:
			samples += 1
			if pel * (pel + chest) < pel * pel: opposite += 1   # the shoulders turn back against it
		var hy: float = h.head.global_transform.basis.get_euler().y
		var sy: float = h.spine.global_transform.basis.get_euler().y
		head_lo = minf(head_lo, hy); head_hi = maxf(head_hi, hy)
		sp_lo = minf(sp_lo, sy); sp_hi = maxf(sp_hi, sy)
	_check(samples > 20 and opposite > samples * 0.8, "the pelvis turns with the stride and the shoulders against it (%d of %d)" % [opposite, samples])
	_check(head_hi - head_lo < (sp_hi - sp_lo) * 0.5 + 0.005, "the head stays steady (%.3f rad against the chest's %.3f)" % [head_hi - head_lo, sp_hi - sp_lo])
	# 3. Starting off: no joint jumps.
	var s = _person(2)
	for i in 240:
		s.animate(DT, "idle", 0.0)
	var joints := ["hp_l", "hp_r", "kn_l", "kn_r", "sh_l", "sh_r", "el_l", "el_r", "spine"]
	var before := {}
	for j in joints: before[j] = (s.get(j) as Node3D).rotation
	var step := func(frames: int) -> float:       # the most any joint turns in a frame
		var most := 0.0
		for i in frames:
			s.animate(DT, "walk", 1.5)
			for j in joints:
				var d: Vector3 = ((s.get(j) as Node3D).rotation - before[j]).abs()
				most = maxf(most, d[d.max_axis_index()])
				before[j] = (s.get(j) as Node3D).rotation
		return most
	var start: float = step.call(40)
	var walking: float = step.call(120)
	_check(start <= walking * 1.1 + 0.005, "starting to walk is as smooth as walking (most in a frame %.3f rad, walking %.3f)" % [start, walking])
	# 4. Standing: a weight shift, and not in step with the others.
	var a = _person(3)
	var b = _person(4)
	var lo := INF; var hi := -INF
	var apart := 0.0
	for i in 60 * 8:                     # (side by side, from the same moment)
		a.animate(DT, "idle", 0.0); b.animate(DT, "idle", 0.0)
		lo = minf(lo, a.hips.position.x); hi = maxf(hi, a.hips.position.x)
		apart = maxf(apart, absf(a.spine.rotation.x - b.spine.rotation.x) + absf(a.hips.position.x - b.hips.position.x))
	_check(hi - lo > 0.01, "standing, the weight shifts (%.1f cm)" % ((hi - lo) * 100.0))
	_check(apart > 0.004, "two people standing are not in step (%.4f)" % apart)
	# 5. And straight again after walking.
	for i in 120:
		h.animate(DT, "idle", 0.0)
	var twist: float = absf(h.hips.rotation.y) + absf(h.hips.rotation.z) + absf(h.spine.rotation.y) + absf(h.head.rotation.y)
	_check(twist < 0.12, "standing again, the walk's twist is gone (%.3f rad)" % twist)
	# 6. Kneeling at the fence with the bolt cutters: low, both hands forward, squeezing.
	var k = _person(5)
	for i in 90:
		k.animate(DT, "cut", 0.0)
	_check(k.hips.position.y < 0.65 and k.rotation.x < 0.3, "cutting: down on one knee (hips at %.2f m)" % k.hips.position.y)
	_check(k.sh_l.rotation.x > 0.5 and k.sh_r.rotation.x > 0.5, "both hands forward on the handles")
	var squeeze := _range(func(p): return p.sh_r.rotation.z, k, "cut", 0.0, 60)
	_check(squeeze > 0.05, "and squeezing them (%.2f rad)" % squeeze)
	# 7. Crawling under the fence: flat on the ground, arms and legs working in turns.
	var c = _person(6)
	for i in 60:
		c.animate(DT, "crawl", 0.6)
	_check(absf(c.rotation.x) > 1.2 and c.head.global_position.z < c.global_position.z - 1.0 and c.head.global_position.y < 0.6,
		"crawling: lying low, head first, the way it goes (-Z) (head at %s)" % c.head.global_position)
	var reach := _range(func(p): return p.sh_l.rotation.x - p.sh_r.rotation.x, c, "crawl", 0.6, 120)
	_check(reach > 0.4, "the arms reach forward in turns")
	print("anim test: %d failed" % _fails)
	quit(1 if _fails else 0)
