extends SceneTree
## How the pistol feels (docs/juicy-gunfights.md): every sound comes in three
## different versions, played round-robin, never one of the last two again; a
## shot on its own frame plays its layers, flashes and lights for one frame
## and throws a shell that tinkles when it lands; the arm's kick and the
## camera's spring back (a tenth of the camera's stays); what a bullet hits
## answers by its surface, a frame later (chips and a mark on stone, sparks and
## a light on metal, a splash on water and no mark); the juice budget never
## goes past its caps, and shake 0 is no shake; marks never pile up past 64.
##     godot --headless --path godot-city --script tests/gunfx_test.gd

const Sfx := preload("res://scripts/sfx.gd")
const Juice := preload("res://scripts/juice.gd")
const GunFx := preload("res://scripts/gun_fx.gd")


class Water:                          # the streets: a canal west of x = 0
	func water_at(p: Vector3) -> int: return 1 if p.x < 0.0 else 0


class You extends Node3D:             # what GunFx needs of the walker
	var cam_pitch := 0.3


var _fails := 0
var sfx
var juice
var fx
var you
var played := []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	print(("ok   " if ok else "FAIL ") + what)
	if not ok: _fails += 1


func _frames(n: int) -> void:
	for i in n:
		fx.step(1.0 / 60.0)
		juice.step(1.0 / 60.0)
		fx._physics_process(1.0 / 60.0)
		await process_frame


func _count(kind: String) -> int:
	var n := 0
	for c in fx.get_children():
		if kind == "light" and c is OmniLight3D: n += 1
		elif kind == "light" and c is Node3D and c.find_children("*", "OmniLight3D", true, false).size(): n += 1
		elif kind == "burst" and c is CPUParticles3D: n += 1
	return n


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	sfx = Sfx.new()
	root.add_child(sfx)
	print("sounds made in %d ms" % (Time.get_ticks_msec() - t0))
	# 1. The sound bank.
	var all_ok := true
	for name in Sfx.MIX:
		var v: Array = sfx.bank[name]
		if v.size() != Sfx.VARIANTS: all_ok = false
		for w in v:
			if (w as AudioStreamWAV).data.size() < 200: all_ok = false
		if v[0].data == v[1].data or v[1].data == v[2].data: all_ok = false
	_check(all_ok, "every sound in %d different versions (%d sounds)" % [Sfx.VARIANTS, Sfx.MIX.size()])
	var seq := []
	for i in 50: seq.append(sfx.pick("stone"))
	var repeats := 0
	for i in range(2, seq.size()):
		if seq[i] == seq[i - 1] or seq[i] == seq[i - 2]: repeats += 1
	_check(repeats == 0, "played round-robin: never one of the last two again (%s...)" % str(seq.slice(0, 8)))
	all_ok = true
	for b in Sfx.BUSES:
		if AudioServer.get_bus_index(b) == -1: all_ok = false
	_check(all_ok, "on their own buses: %s" % ", ".join(Sfx.BUSES))
	# 2. A shot.
	juice = Juice.new(); root.add_child(juice)
	juice.set_process(false)
	you = You.new(); root.add_child(you)
	fx = GunFx.new(); root.add_child(fx)
	fx.set_process(false); fx.set_physics_process(false)
	fx.setup(you, Water.new(), sfx, juice)
	var wall := StaticBody3D.new(); wall.collision_layer = 1
	var cs := CollisionShape3D.new(); var bs := BoxShape3D.new(); bs.size = Vector3(1, 6, 40); cs.shape = bs
	wall.add_child(cs); wall.position = Vector3(30, 0, 0)
	root.add_child(wall)
	await process_frame
	fx.fire(Vector3(0.5, 1.4, 0), Vector3(0, 0, -1), Vector3(1, 0, 0))
	var playing := 0
	for p in sfx._p2:
		if (p as AudioStreamPlayer).playing: playing += 1
	_check(playing >= 5, "the shot's sound starts on its own frame: %d layers" % playing)
	_check(_count("light") == 1, "a flash and its light, this frame")
	_check(fx.arm > 0.1 and fx.cam > 0.0, "the arm kicks up (%.2f rad), and the camera (%.4f rad)" % [fx.arm, fx.cam])
	_check(is_equal_approx(juice._ev_next, 0.1), "and a one-frame exposure bump (%.2f EV)" % juice._ev_next)
	await _frames(2)
	_check(_count("light") == 0, "gone the next frame")
	var arm_peak: float = fx.arm
	var landed := false
	for i in 60:
		await _frames(1)
		if fx._shells.size() and fx._shells[0].hops > 0: landed = true
	print("recoil: arm %.4f, camera %.5f rad after 1 s; pitch %.4f" % [fx.arm, fx.cam, you.cam_pitch])
	_check(absf(fx.arm) < 0.02 * arm_peak + 0.001 and absf(fx.cam) < 0.0005, "the springs bring arm and camera back (arm %.4f)" % fx.arm)
	_check(you.cam_pitch < 0.3 and you.cam_pitch > 0.3 - GunFx.CAM_KICK * 0.2, "a tenth of the camera's kick stays (aim down again)")
	_check(landed, "the shell lands (and tinkles)")
	# 3. Impacts, by surface, on the next physics frame.
	var marks: int = fx.decals.size()
	fx.impact(Vector3(29.5, 1.0, 0), Vector3(-1, 0, 0), Vector3(1, 0, 0), "stone")
	_check(_count("burst") == 0, "nothing where it lands on the firing frame")
	await _frames(1)
	_check(_count("burst") == 1 and fx.decals.size() == marks + 1 and _count("light") == 0, "stone: chips, dust and a mark, no light")
	await _frames(40)
	fx.impact(Vector3(5, 0.8, 0), Vector3(-1, 0, 0), Vector3(1, 0, 0), "metal")
	await _frames(1)
	_check(_count("light") == 1 and fx.decals.size() == marks + 2, "metal: sparks, a blip of light and a hole")
	await _frames(40)
	var hit := {"collider": wall}
	var ground := StaticBody3D.new(); ground.collision_layer = 2
	_check(fx.surface_of(hit, Vector3(29.5, 1, 0)) == "stone" and fx.surface_of({"collider": ground}, Vector3(-3, 0, 0)) == "water" \
		and fx.surface_of({"collider": ground}, Vector3(3, 0, 0)) == "stone", "what a bullet hit: a wall is stone, the canal water, the street stone")
	ground.free()
	fx.impact(Vector3(-3, -1.4, 0), Vector3.UP, Vector3(0, -1, 0), "water")
	await _frames(1)
	_check(fx.decals.size() == marks + 2, "water: a splash and a ring, no mark")
	# 4. The juice budget.
	for i in 20:
		juice.add(0.5, 3.0, 0.4)
	_check(juice.trauma <= Juice.MAX_TRAUMA and juice.fov <= Juice.MAX_FOV and juice._ev_next <= Juice.MAX_EV,
		"twenty big events in one frame stay in the budget (trauma %.2f, FOV %.1f°, %.2f EV)" % [juice.trauma, juice.fov, juice._ev_next])
	juice.step(1.0 / 60.0)
	_check(juice.shake.length() > 0.0, "and shake the camera")
	juice.shake_scale = 0.0
	juice.step(1.0 / 60.0)
	_check(juice.shake == Vector3.ZERO, "shake 0: no shake at all")
	juice.shake_scale = 1.0
	juice.reduce_flashes = true
	juice.add(0.0, 0.0, 0.5)
	_check(juice._ev_next <= Juice.CALM_EV + 0.001, "fewer flashes: the bump held to %.1f EV" % Juice.CALM_EV)
	for i in 60: juice.step(1.0 / 60.0)
	_check(juice.trauma == 0.0 and juice.fov < 0.01, "and it all dies away")
	# 5. Marks never pile up.
	for i in 100:
		fx.impact(Vector3(29.5, 1.0 + i * 0.01, 0), Vector3(-1, 0, 0), Vector3(1, 0, 0), "stone")
		fx._physics_process(1.0 / 60.0)
	_check(fx.decals.size() == GunFx.DECALS, "a hundred shots at a wall: %d marks, the oldest gone" % fx.decals.size())
	print("gunfx test: %d failed" % _fails)
	quit(1 if _fails else 0)
