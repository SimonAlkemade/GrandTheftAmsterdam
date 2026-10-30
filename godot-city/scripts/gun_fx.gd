extends Node3D
## How the pistol feels: everything at the gun and everything where the
## bullet lands (docs/juicy-gunfights.md §4, §5.1, §5.2, §7; the pistol is
## §6.1, third person as §6.9).
##
## A shot, on the frame you fire it: the layered sound (transient, body, mech,
## LFE, and a tail that a narrow street answers with a slap-back), a flash of
## crossed cards and a warm light for one frame, three smoke wisps, a brass
## shell that tinkles on the stones, the arm kicking up on a snappy spring and
## the camera a little, almost all of which comes back.
## Where it lands, one frame later: by what it hit (stone, metal, water, a
## person) a fast layer and a slow one (chips and dust, sparks and a light
## blip, a splash and a ring, blood mist and drops), a mark on the surface
## (64 at most, the oldest go), and its own sound; a person freezes for a
## moment before going limp (enemy-local hitstop).
##     gun_fx.fire(muzzle, aim_dir, right); gun_fx.impact(point, normal, dir, "stone")

const CALIBER := 0.6            # the pistol's scale on impacts (§7)
# Recoil (§6.1, §6.9): the arm carries it, the camera half the FPS kick.
const ARM_KICK := 0.16          # radians (about 9°): the wrist flips up...
const CAM_KICK := deg_to_rad(0.3)   # ...the camera barely
const RECOVER := 0.9            # of the camera kick that comes back by itself
const SPRING := Vector2(180.0, 22.0)  # stiffness, damping: snappy (§6.1)
const FLASH := 0.18             # metres: the star card (0.12 m x 1.5 for third person)
const LIGHT := Color(1.0, 0.74, 0.47)  # about 3200 K
const DECALS := 64
const NOISE_RADIUS := 45.0      # §6.1: AI hearing (the scared people use 40 m today)

var walker
var streamer
var sfx
var juice
var arm := 0.0                  # radians the arm is kicked up now
var cam := 0.0                  # radians the camera is kicked up now
var decals: Array = []          # the marks, oldest first
var shots := 0
var _arm_v := 0.0
var _cam_v := 0.0
var _live: Array = []           # [node, frame it was made on, frames to show, seconds to show]
var _later: Array = []          # [seconds left, Callable]
var _pending: Array = []        # impacts to show on the next physics frame (F1)
var _shells: Array = []
var _rng := RandomNumberGenerator.new()
var _tex := {}
var _mats := {}


func setup(w, s, fx_sfx, fx_juice) -> void:
	walker = w; streamer = s; sfx = fx_sfx; juice = fx_juice
	_rng.randomize()
	_tex = {"star": _star_tex(), "hole": _mark_tex("hole"), "crater": _mark_tex("crater"), "blood": _mark_tex("blood")}


## A shot from `muzzle` along `dir` (right: the shooter's right, for the shell).
func fire(muzzle: Vector3, dir: Vector3, right: Vector3) -> void:
	shots += 1
	# Sound, this frame: four layers to your ears, the tail by the space round you.
	if sfx:
		for layer in ["transient", "body", "mech", "lfe"]:
			sfx.play(layer, null, "PlayerWeapon")
		sfx.play("tail_street" if _narrow(muzzle) else "tail_open", null, "PlayerWeapon")
	_flash(muzzle, dir)
	_smoke(muzzle + dir * 0.05)
	_shell(muzzle - dir * 0.14 + Vector3(0, 0.03, 0), dir, right)
	# Recoil: the arm's spring, and the camera's (a tenth of it stays: aim down again).
	arm += ARM_KICK * _rng.randf_range(0.9, 1.1)
	cam += CAM_KICK * RECOVER
	if walker:
		walker.cam_pitch -= CAM_KICK * (1.0 - RECOVER)
	if juice:
		juice.add(0.0, 0.0, 0.1)        # a one-frame exposure bump, no shake (§6.1)


## The bullet lands at `at` on `surface` (stone, metal, water, flesh): shown
## on the next physics frame.
func impact(at: Vector3, normal: Vector3, dir: Vector3, surface: String) -> void:
	_pending.append([at, normal.normalized() if normal.length() > 0.01 else -dir, dir, surface])


## What a ray hit is made of, for impact().
func surface_of(hit: Dictionary, at: Vector3) -> String:
	var c = hit.get("collider")
	var layer: int = (c as CollisionObject3D).collision_layer if c is CollisionObject3D else 1
	if layer & (4 | 8):
		return "metal"                   # cars, buses, trams, boats
	if layer & 2 and streamer and streamer.water_at(at) == 1:
		return "water"
	return "stone"                       # walls, setts, quays, bridges


## Call `cb` `secs` seconds from now (hitstop: a person goes limp after it).
func later(secs: float, cb: Callable) -> void:
	_later.append([secs, cb])


func _physics_process(_delta: float) -> void:
	for p in _pending:
		_land(p[0], p[1], p[2], p[3])
	_pending.clear()


func _process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	# The springs (in small steps, steady at any frame rate).
	var left := delta
	while left > 0.0:
		var h := minf(left, 1.0 / 240.0)
		_arm_v += (-SPRING.x * arm - SPRING.y * _arm_v) * h
		arm += _arm_v * h
		_cam_v += (-SPRING.x * cam - SPRING.y * _cam_v) * h
		cam += _cam_v * h
		left -= h
	# (A one-frame flash made on input, before this frame's update, is still
	# drawn this frame: it counts frames from the one it was made on.)
	var now := Engine.get_process_frames()
	for l in _live.duplicate():
		l[3] -= delta
		if now - l[1] >= l[2] and l[3] <= 0.0:
			if is_instance_valid(l[0]): l[0].queue_free()
			_live.erase(l)
	for l in _later.duplicate():
		l[0] -= delta
		if l[0] <= 0.0:
			_later.erase(l)
			(l[1] as Callable).call()
	_shells_step(delta)


# ---- at the gun --------------------------------------------------------------------

# Is the shooter in a narrow street (walls close on two or more sides)? Then
# the tail has a slap-back.
func _narrow(at: Vector3) -> bool:
	if not is_inside_tree():
		return false
	var space := get_world_3d().direct_space_state
	var close := 0
	for k in 4:
		var d := Vector3(cos(k * PI / 2.0 + 0.4), 0, sin(k * PI / 2.0 + 0.4))
		var q := PhysicsRayQueryParameters3D.create(at, at + d * 14.0, 1)
		if not space.intersect_ray(q).is_empty():
			close += 1
	return close >= 2


# The flash: a star card across the barrel and two petal cards along it,
# rolled at random, and a warm light: one frame.
func _flash(at: Vector3, dir: Vector3) -> void:
	var n := Node3D.new()
	add_child(n)
	var up := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	n.global_transform = Transform3D(Basis.looking_at(dir, up), at)
	n.rotate_object_local(Vector3(0, 0, 1), _rng.randf() * TAU)
	var m := _mat("flash", Color(1.0, 0.86, 0.55), true, _tex.star)
	var star := QuadMesh.new(); star.size = Vector2.ONE * FLASH * 2.0
	var s := MeshInstance3D.new(); s.mesh = star; s.material_override = m
	n.add_child(s)
	s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for k in 2:                          # the petals, crossed, reaching forward along the barrel
		var pivot := Node3D.new(); pivot.rotation.z = k * PI / 2.0
		n.add_child(pivot)
		var petal := QuadMesh.new(); petal.size = Vector2(FLASH * 1.2, FLASH * 3.0)
		var p := MeshInstance3D.new(); p.mesh = petal; p.material_override = m
		p.rotation.x = -PI / 2.0         # (its long side now runs forward)
		p.position = Vector3(0, 0, -FLASH * 1.3)
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		pivot.add_child(p)
	var l := OmniLight3D.new(); l.light_color = LIGHT; l.light_energy = 2.5; l.omni_range = 3.0
	n.add_child(l)
	_live.append([n, Engine.get_process_frames(), 1, 0.0])


func _smoke(at: Vector3) -> void:
	var p := _burst(at, Vector3.UP, _sphere(0.05), _mat("smoke", Color(0.75, 0.74, 0.72, 0.35)), 3, 0.4, 0.2, 0.5, 40.0, Vector3(0, 0.6, 0))
	p.scale_amount_min = 1.0; p.scale_amount_max = 2.2


# A brass case flicked out to the right, tumbling, bouncing on the stones.
func _shell(at: Vector3, dir: Vector3, right: Vector3) -> void:
	var b := BoxMesh.new(); b.size = Vector3(0.012, 0.012, 0.022)
	var mi := MeshInstance3D.new(); mi.mesh = b
	mi.material_override = _mat("brass", Color(0.86, 0.66, 0.28), false, null, 0.6)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	mi.global_position = at
	var v := right * _rng.randf_range(1.6, 2.3) + Vector3.UP * _rng.randf_range(1.8, 2.5) - dir * 0.3
	var floor_y: float = walker.global_position.y + 0.02 if walker else at.y - 1.3
	_shells.append({"n": mi, "v": v, "spin": Vector3(_rng.randf_range(-20, 20), _rng.randf_range(-20, 20), 0), "floor": floor_y, "hops": 0, "t": 0.0})
	while _shells.size() > 16:
		var old: Dictionary = _shells.pop_front()
		if is_instance_valid(old.n): old.n.queue_free()


func _shells_step(delta: float) -> void:
	for s in _shells.duplicate():
		var n: MeshInstance3D = s.n
		if not is_instance_valid(n):
			_shells.erase(s); continue
		s.t += delta
		if s.hops < 3:
			s.v += Vector3(0, -9.8, 0) * delta
			n.global_position += s.v * delta
			n.rotation += s.spin * delta
			if n.global_position.y < s.floor and s.v.y < 0.0:
				n.global_position.y = s.floor
				if s.hops == 0 and sfx:
					sfx.play("shell", n.global_position, "Impacts")     # tink (§4: on landing)
				s.hops += 1
				s.v = Vector3(s.v.x * 0.45, -s.v.y * 0.35, s.v.z * 0.45)
				s.spin *= 0.5
		if s.t > 4.0:
			n.queue_free(); _shells.erase(s)


# ---- where it lands --------------------------------------------------------------------

func _land(at: Vector3, normal: Vector3, dir: Vector3, surface: String) -> void:
	var k := CALIBER
	match surface:
		"stone":                         # chips and a dust puff, a crater mark; now and then a ricochet
			_burst(at, normal, _box(0.03), _mat("chip", Color(0.55, 0.53, 0.5)), _n(8.0 * k), 0.45, 2.5, 5.0, 35.0, Vector3(0, -9.8, 0))
			_puff(at + normal * 0.1, Color(0.7, 0.68, 0.64, 0.55), 0.4 * k + 0.15, 0.8)
			_mark(at, normal, "crater", 0.13)
			if sfx:
				sfx.play("stone", at)
				if _rng.randf() < 0.1 and absf(normal.dot(dir)) < 0.5:
					sfx.play("ricochet", at)
		"metal":                         # sparks and a blip of light, a bright hole
			var sp := _burst(at, normal, _box(0.012, 0.09), _mat("spark", Color(1.0, 0.8, 0.35), true), _n(16.0 * k), 0.15, 4.0, 8.0, 50.0, Vector3(0, -3.0, 0))
			sp.set_particle_flag(CPUParticles3D.PARTICLE_FLAG_ALIGN_Y_TO_VELOCITY, true)   # streaks
			var l := OmniLight3D.new(); l.light_color = Color(1.0, 0.78, 0.5); l.light_energy = 2.0; l.omni_range = 2.0
			add_child(l); l.global_position = at + normal * 0.2
			_live.append([l, Engine.get_process_frames(), 1, 0.05])
			_mark(at, normal, "hole", 0.07)
			if sfx: sfx.play("metal", at)
		"water":                         # a splash column and a ring, no mark
			_burst(at, Vector3.UP, _sphere(0.04), _mat("spray", Color(0.85, 0.92, 0.95, 0.7)), _n(14.0), 0.6, 2.5, 4.0, 14.0, Vector3(0, -9.8, 0))
			_ring(at + Vector3(0, 0.02, 0))
			if sfx: sfx.play("water", at)
		"flesh":                         # blood mist and drops, a splash on the wall behind
			_puff(at, Color(0.45, 0.04, 0.04, 0.7), 0.25, 0.4)
			_burst(at, -dir, _sphere(0.025), _mat("blood", Color(0.4, 0.02, 0.02)), _n(5.0), 0.5, 1.5, 3.0, 40.0, Vector3(0, -9.8, 0))
			if is_inside_tree():
				var q := PhysicsRayQueryParameters3D.create(at, at + dir * 2.0, 1)
				var behind := get_world_3d().direct_space_state.intersect_ray(q)
				if not behind.is_empty():
					_mark(behind.position, behind.normal, "blood", 0.35)
			if sfx:
				sfx.play("flesh", at, "Impacts", 3.0)                # (player-heard +3 dB, §7)
				sfx.play("hit_tick", null, "UI")
			if juice: juice.hit()


func _n(base: float) -> int:
	return maxi(1, int(round(base * _rng.randf_range(0.8, 1.2))))    # ±20% (§2.4)


# A one-shot spray of `amount` meshes along `dir` (spread degrees), falling
# with `grav`, gone after `life` seconds.
func _burst(at: Vector3, dir: Vector3, mesh: Mesh, mat: Material, amount: int, life: float, v0: float, v1: float, spread: float, grav: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.mesh = mesh
	p.material_override = mat
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 1.0
	p.local_coords = false
	p.direction = dir
	p.spread = spread
	p.initial_velocity_min = v0; p.initial_velocity_max = v1
	p.gravity = grav
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p)
	p.global_position = at
	p.emitting = true
	_live.append([p, Engine.get_process_frames(), 1, life + 0.3])
	return p


# The slow layer: a soft ball that swells and fades.
func _puff(at: Vector3, col: Color, size: float, life: float) -> void:
	var mi := MeshInstance3D.new(); mi.mesh = _sphere(size * 0.5)
	var m := _mat("puff_%s" % col.to_html(), col).duplicate()
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi); mi.global_position = at
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3.ONE * 2.6, life).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tw.parallel().tween_property(m, "albedo_color:a", 0.0, life)
	tw.tween_callback(mi.queue_free)


func _ring(at: Vector3) -> void:
	var t := TorusMesh.new(); t.inner_radius = 0.16; t.outer_radius = 0.2; t.rings = 16; t.ring_segments = 4
	var mi := MeshInstance3D.new(); mi.mesh = t
	var m := _mat("ring", Color(0.9, 0.95, 1.0, 0.6)).duplicate()
	mi.material_override = m
	add_child(mi); mi.global_position = at
	var tw := mi.create_tween()
	tw.tween_property(mi, "scale", Vector3(5, 1, 5), 0.8)
	tw.parallel().tween_property(m, "albedo_color:a", 0.0, 0.8)
	tw.tween_callback(mi.queue_free)


# A mark lying flat on the surface (a card, so it works in the browser's
# renderer too, which has no decals), rolled at random; DECALS at most.
func _mark(at: Vector3, normal: Vector3, kind: String, size: float) -> void:
	var q := QuadMesh.new(); q.size = Vector2.ONE * size
	var mi := MeshInstance3D.new(); mi.mesh = q
	mi.material_override = _mat("mark_" + kind, Color.WHITE, false, _tex[kind])
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var z := normal.normalized()
	var x := z.cross(Vector3.UP if absf(z.y) < 0.95 else Vector3.RIGHT).normalized()
	mi.global_transform = Transform3D(Basis(x, z.cross(x), z), at + z * 0.012)
	mi.rotate_object_local(Vector3(0, 0, 1), _rng.randf() * TAU)
	decals.append(mi)
	while decals.size() > DECALS:
		var old = decals.pop_front()
		if is_instance_valid(old): old.queue_free()


# ---- looks ---------------------------------------------------------------------------

func _mat(key: String, col: Color, additive := false, tex: Texture2D = null, metal := 0.0) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.metallic = metal
	if additive:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	elif col.a < 1.0 or tex != null:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if tex:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST     # point-sampled, chunky (§11)
	if key.begins_with("mark_"):
		m.roughness = 0.9
	_mats[key] = m
	return m


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new(); s.radius = r; s.height = r * 2.0; s.radial_segments = 6; s.rings = 3
	return s


func _box(w: float, h := -1.0) -> BoxMesh:
	var b := BoxMesh.new(); b.size = Vector3(w, h if h > 0.0 else w, w)
	return b


# A soft star: a bright core with four spikes, white on black (added).
func _star_tex() -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5) / 15.5
			var core := clampf(1.0 - d.length(), 0.0, 1.0)
			var spike := clampf(1.0 - absf(d.x) * 6.0, 0.0, 1.0) * clampf(1.0 - absf(d.y), 0.0, 1.0) \
				+ clampf(1.0 - absf(d.y) * 6.0, 0.0, 1.0) * clampf(1.0 - absf(d.x), 0.0, 1.0)
			var a := clampf(pow(core, 1.5) + spike * 0.7, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


# A 32 px mark: a bullet hole, a chipped crater, a splash of blood.
func _mark_tex(kind: String) -> ImageTexture:
	var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var r := RandomNumberGenerator.new(); r.seed = hash(kind)
	var blobs := []
	if kind == "blood":
		for i in 9: blobs.append([Vector2(r.randf_range(4, 28), r.randf_range(4, 28)), r.randf_range(1.5, 5.0)])
	for y in 32:
		for x in 32:
			var p := Vector2(x - 15.5, y - 15.5)
			var c := Color(0, 0, 0, 0)
			match kind:
				"hole":
					var d := p.length()
					if d < 3.5: c = Color(0.04, 0.04, 0.04, 1)
					elif d < 7.0: c = Color(0.55, 0.55, 0.57, 0.9 * (1.0 - (d - 3.5) / 3.5))
				"crater":
					var d := p.length() * (1.0 + 0.25 * sin(atan2(p.y, p.x) * 5.0 + 1.3))
					if d < 3.0: c = Color(0.1, 0.09, 0.08, 1)
					elif d < 13.0: c = Color(0.32, 0.3, 0.28, 0.85 * (1.0 - (d - 3.0) / 10.0))
				"blood":
					var on := p.length() < 7.0
					for b in blobs:
						if Vector2(x, y).distance_to(b[0]) < b[1]: on = true
					if on: c = Color(0.32, 0.02, 0.02, 0.9)
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)
