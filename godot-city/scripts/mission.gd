extends Node3D
## Mission 1, the parcel courier: pick a parcel up at A and deliver it to B,
## again and again. A and B are yellow circles on the street (with a beam of
## light you can see from afar); the way there is routed over the real street
## and bike-path network and drawn on the minimap and, in the map view, over
## the streets. Deliveries are timed by the length of the route and pay more
## the quicker you are. After PARCELS of them:
##
## Mission 3, tulips for the tourists: fetch a stock of tulips at the
## Bloemenmarkt (the flower market on the Singel) and sell them, a bunch at a
## time, to the tourists among the people in the street (a tulip turns over
## their heads, a pink dot on the minimap). Walk up to one and they wait for
## you; stand by them a moment and they buy. Sold out, fetch more.

signal announce(title: String, sub: String)   # a big message in the middle of the screen

const CIRCLE := 3.0                  # metres: the circles, and how close counts as there
const PICKUP_DIST := Vector2(120.0, 380.0)
const DROP_DIST := Vector2(380.0, 800.0)
const PAY := 25
const ROUTE_KINDS := ["road", "bike"]
const YELLOW := Color(1.0, 0.82, 0.08)
const PARCELS := 5                   # deliveries that finish the courier job
const BLOEMENMARKT := Vector2(-314.8, 821.3)   # the flower market on the Singel (Overture's place, scene metres)
const BUNCHES := 10                  # tulips in a stock from the market
const PRICE := Vector2i(6, 12)       # what a tourist pays for a bunch, €
const TOURISTS := 3                  # tourists about at once
const TOURIST_FROM := Vector2(15.0, 70.0)   # how far from you a new one is picked
const SELL_NEAR := 1.8               # metres: close enough to sell
const SELL_TIME := 0.6               # seconds standing by them
const PINK := Color(1.0, 0.35, 0.62)

var streamer
var traffic
var walker
var state := "off"                   # off; pickup, deliver (Mission 1); tulips_fetch, tulips_sell (Mission 3)
var target := Vector3.ZERO
var target_name := ""
var route := PackedVector2Array()    # from you to the target, along the streets
var route_len := 0.0
var time_left := 0.0
var delivered := 0
var money := 0
var _marker: Node3D
var _ribbon: MeshInstance3D
var _route_from := Vector2(INF, INF)
var _route_t := 0.0
var _wait := 0.0                     # a pause before the next pickup appears
var _rng := RandomNumberGenerator.new()
var _mats := {}
var stall_at := BLOEMENMARKT         # where the tulips are fetched
var tulips := 0                      # bunches in your arms
var sold := 0
var tourists: Array = []             # pedestrians (Walker.peds entries) who want tulips
var _tourist_t := 0.0
var _sale_t := 0.0
var _tulip_mesh: Array = []          # [stem, flower] meshes, for the icons


func setup(s, t, w) -> void:
	streamer = s; traffic = t; walker = w
	_rng.randomize()
	_ribbon = MeshInstance3D.new()
	_ribbon.material_override = _mat(0.85)
	_ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ribbon.visible = false
	add_child(_ribbon)


func start() -> void:
	delivered = 0; money = 0
	announce.emit("MISSION 1: PARCEL COURIER", "Pick up parcels and deliver them across Amsterdam")
	_wait = 3.0
	state = "pickup"
	target = Vector3.INF


## Mission 3 straight away (and the courier job taken as done).
func start_tulips() -> void:
	_clear()
	_set_carrying(false)
	state = "tulips_fetch"
	_wait = 3.0
	announce.emit("MISSION 3: TULIPS", "Fetch a stock of tulips at the Bloemenmarkt and sell them to tourists")


## What to do now, for the top of the screen.
func objective() -> String:
	if state == "tulips_fetch" and target != Vector3.INF:
		return "Fetch tulips at the Bloemenmarkt"
	if state == "tulips_sell":
		return "Sell tulips to the tourists · %d bunch%s left" % [tulips, "" if tulips == 1 else "es"]
	if state == "pickup" and target != Vector3.INF:
		return "Pick up the parcel at %s" % target_name
	if state == "deliver":
		return "Deliver the parcel to %s" % target_name
	return ""


func distance_left() -> float:
	if state == "tulips_sell":
		return _here().distance_to(Vector2(target.x, target.z))
	return route_len if route.size() > 1 else _here().distance_to(Vector2(target.x, target.z))


## Show the route over the streets (the map view) or not (on foot).
func show_route_3d(on: bool) -> void:
	_ribbon.visible = on and route.size() > 1


func _here() -> Vector2:
	return Vector2(walker.global_position.x, walker.global_position.z)


func _process(delta: float) -> void:
	if state == "off" or traffic == null:
		return
	if state == "tulips_sell":
		_selling(delta)
		return
	if _wait > 0.0:
		_wait -= delta
		if _wait <= 0.0 and state == "pickup":
			_place(_choose(_here(), PICKUP_DIST), "pickup")
		elif _wait <= 0.0 and state == "tulips_fetch":
			_place(_street_near(stall_at), "tulips")
		return
	if target == Vector3.INF:
		_wait = 1.0                       # nowhere suitable yet (the streets may still be loading)
		return
	_pulse(delta)
	var here := _here()
	if state == "deliver":
		time_left -= delta
		if time_left <= 0.0:
			announce.emit("TOO LATE", "The parcel went back to the depot")
			_set_carrying(false)
			_clear()
			state = "pickup"; _wait = 2.5
			return
	if here.distance_to(Vector2(target.x, target.z)) < CIRCLE:
		_arrive()
		return
	# Re-route now and then, and whenever you have strayed from the route.
	_route_t -= delta
	if _route_t <= 0.0 or (here.distance_to(_route_from) > 25.0 and _off_route(here)):
		_route_t = 3.0
		_reroute()


func _arrive() -> void:
	if state == "tulips_fetch":
		tulips = BUNCHES
		_clear()
		state = "tulips_sell"
		_tourist_t = 0.5
		walker.tulips = tulips
		announce.emit("%d BUNCHES OF TULIPS" % BUNCHES, "Sell them to the tourists: walk up to one")
		return
	if state == "pickup":
		_set_carrying(true)
		var from := Vector2(target.x, target.z)
		var at := _choose(from, DROP_DIST)
		if at == Vector3.INF:
			at = _choose(from, Vector2(150.0, 1200.0))
		_place(at, "drop")
		state = "deliver"
		time_left = 30.0 + route_len / 4.5
		announce.emit("PARCEL PICKED UP", "Deliver it to %s" % target_name)
	else:
		var bonus := int(time_left / 6.0)   # €1 for every 6 seconds to spare
		money += PAY + bonus
		delivered += 1
		_set_carrying(false)
		_clear()
		if delivered >= PARCELS:
			announce.emit("COURIER JOB DONE", "%d parcels, €%d. Next: tulips for the tourists" % [delivered, money])
			state = "tulips_fetch"; _wait = 4.0
			return
		announce.emit("PARCEL DELIVERED", "+ €%d%s" % [PAY + bonus, ("  (€%d for speed)" % bonus) if bonus > 0 else ""])
		state = "pickup"; _wait = 2.5


func _set_carrying(on: bool) -> void:
	walker.carrying = on


func _clear() -> void:
	if _marker:
		_marker.queue_free()
		_marker = null
	target = Vector3.INF
	route = PackedVector2Array()
	route_len = 0.0
	_ribbon.mesh = null


# ---- tulips --------------------------------------------------------------------

func _selling(delta: float) -> void:
	var here := _here()
	# Tourists come and go: one who has walked off (or been knocked down,
	# shot, scared) is no longer one.
	for p in tourists.duplicate():
		var gone: bool = not walker.peds.has(p) or p.get("dead", false) or p.has("rag") or p.get("flee", 0.0) > 0.0 \
			or Vector2(p.pos.x, p.pos.z).distance_to(here) > 110.0
		if gone:
			_untourist(p)
	_tourist_t -= delta
	if tourists.size() < TOURISTS and _tourist_t <= 0.0:
		_tourist_t = 1.5
		_new_tourist(here)
	# The nearest one is where you are headed; they wait for you when you come near.
	var best = null
	var bd := INF
	for p in tourists:
		var d := Vector2(p.pos.x, p.pos.z).distance_to(here)
		var icon: Node3D = p.tulip_icon
		icon.position = p.pos + Vector3(0, 2.35 + sin(Time.get_ticks_msec() / 300.0) * 0.08, 0)
		icon.rotation.y += delta * 2.0
		if d < bd:
			bd = d; best = p
	if best == null:
		target = Vector3.INF
		route = PackedVector2Array(); route_len = 0.0; _ribbon.mesh = null
		return
	target = best.pos                         # (close by: the minimap's blip, no route)
	if bd < 7.0:
		best.wait = 1.0                       # they stop, and turn to you
	if bd < SELL_NEAR and walker.vehicle == null:
		_sale_t += delta
		if _sale_t >= SELL_TIME:
			_sell(best)
	else:
		_sale_t = 0.0


func _sell(p: Dictionary) -> void:
	_sale_t = 0.0
	var price := _rng.randi_range(PRICE.x, PRICE.y)
	money += price
	tulips -= 1
	sold += 1
	walker.tulips = tulips
	p.bought = true                           # one bunch each
	_untourist(p)
	_tourist_t = 2.0
	if tulips > 0:
		announce.emit("SOLD", "+ €%d  ·  %d bunch%s left" % [price, tulips, "" if tulips == 1 else "es"])
		return
	for t in tourists.duplicate():
		_untourist(t)
	target = Vector3.INF
	route = PackedVector2Array(); route_len = 0.0; _ribbon.mesh = null
	announce.emit("SOLD OUT", "+ €%d. Fetch more tulips at the Bloemenmarkt" % price)
	state = "tulips_fetch"; _wait = 3.0


# Someone in the street, not too near and not too far, becomes a tourist who
# wants tulips.
func _new_tourist(here: Vector2) -> void:
	var pool := []
	for p in walker.peds:
		if tourists.has(p) or p.get("bought", false) or p.get("dead", false) or p.has("rag") or p.get("flee", 0.0) > 0.0:
			continue
		var d := Vector2(p.pos.x, p.pos.z).distance_to(here)
		if d > TOURIST_FROM.x and d < TOURIST_FROM.y:
			pool.append(p)
	if pool.is_empty():
		return
	var p: Dictionary = pool[_rng.randi() % pool.size()]
	p.tulip_icon = _tulip_icon(1.0)
	add_child(p.tulip_icon)
	tourists.append(p)


func _untourist(p: Dictionary) -> void:
	tourists.erase(p)
	if p.has("tulip_icon"):
		p.tulip_icon.queue_free()
		p.erase("tulip_icon")


# A street spot by `at` that the courier's routing reaches from you (the
# market itself lies on the water, and a scrap of street by it may join
# nothing); INF while the streets there are not loaded.
func _street_near(at: Vector2) -> Vector3:
	var near := []                       # [distance, point]: the nearest point of each street
	for kind in ROUTE_KINDS:
		for id in traffic.by_kind[kind]:
			var e: Dictionary = traffic.edges[id]
			var pts: PackedVector2Array = e.p
			var bd := 150.0
			var bq := Vector2.INF
			for i in pts.size() - 1:
				var q := Geometry2D.get_closest_point_to_segment(at, pts[i], pts[i + 1])
				if q.distance_to(at) < bd:
					bd = q.distance_to(at); bq = q
			if bq != Vector2.INF and streamer.water_at(Vector3(bq.x, 0, bq.y)) != 1:
				near.append([bd, bq])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for k in mini(near.size(), 8):
		var q: Vector2 = near[k][1]
		if _path(_here(), q).size() >= 2:
			return Vector3(q.x, 0.0, q.y)
	return Vector3.INF


# A tulip: a green stem and leaf, a red cup on top, `s` times life size x 6.
func _tulip_icon(s: float) -> Node3D:
	if _tulip_mesh.is_empty():
		var stem := CylinderMesh.new(); stem.top_radius = 0.03; stem.bottom_radius = 0.035; stem.height = 0.5; stem.radial_segments = 6; stem.rings = 1
		var cup := CylinderMesh.new(); cup.top_radius = 0.17; cup.bottom_radius = 0.09; cup.height = 0.26; cup.radial_segments = 6; cup.rings = 1
		var gm := StandardMaterial3D.new(); gm.albedo_color = Color("3f8f3a"); gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var rm := StandardMaterial3D.new(); rm.albedo_color = Color("e8213f"); rm.emission_enabled = true; rm.emission = Color("ff3355"); rm.emission_energy_multiplier = 0.6
		_tulip_mesh = [stem, gm, cup, rm]
	var n := Node3D.new()
	var a := MeshInstance3D.new(); a.mesh = _tulip_mesh[0]; a.material_override = _tulip_mesh[1]; a.position.y = 0.25
	var b := MeshInstance3D.new(); b.mesh = _tulip_mesh[2]; b.material_override = _tulip_mesh[3]; b.position.y = 0.6
	for m in [a, b]:
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.add_child(m)
	n.scale = Vector3.ONE * s
	return n


# ---- where ------------------------------------------------------------------------

## A spot on a named street, between d.x and d.y metres from `from` as the
## crow flies, that the street network reaches; INF when none is loaded yet.
func _choose(from: Vector2, d: Vector2) -> Vector3:
	var pool: Array = traffic.by_kind["road"]
	if pool.is_empty():
		return Vector3.INF
	var checks := 0
	for attempt in 80:
		var e: Dictionary = traffic.edges[pool[_rng.randi() % pool.size()]]
		if e.w < 5.0 or e.len < 12.0:
			continue
		var at: Vector2 = traffic._at(e, e.len * _rng.randf_range(0.3, 0.7))[0]
		var dist := at.distance_to(from)
		if dist < d.x or dist > d.y:
			continue
		if streamer.water_at(Vector3(at.x, 0, at.y)) == 1 or streamer.nearest_name(Vector3(at.x, 0, at.y), 60.0) == "":
			continue
		checks += 1
		if _path(from, at).size() < 2:
			if checks >= 6:
				break                         # routing is the dear part: try again later
			continue
		return Vector3(at.x, 0.0, at.y)
	return Vector3.INF


func _place(at: Vector3, kind: String) -> void:
	_clear()
	if at == Vector3.INF:
		return
	target = at
	target_name = streamer.nearest_name(at, 60.0)
	_marker = _build_marker(kind)
	_marker.position = Vector3(at.x, 0.1, at.z)
	add_child(_marker)
	_reroute()


# ---- the route ------------------------------------------------------------------

func _reroute() -> void:
	var here := _here()
	_route_from = here
	var p := _path(here, Vector2(target.x, target.z))
	route = p
	route_len = 0.0
	for i in range(1, p.size()):
		route_len += p[i - 1].distance_to(p[i])
	_ribbon.mesh = _ribbon_mesh(p, 6.0) if p.size() > 1 else null


func _off_route(p: Vector2) -> bool:
	for i in range(1, route.size()):
		if Geometry2D.get_closest_point_to_segment(p, route[i - 1], route[i]).distance_to(p) < 20.0:
			return false
	return true


func _node_pos(k: Vector2i) -> Vector2:
	return Vector2(k) / traffic.SNAP


func _usable(k: Vector2i) -> bool:
	for x in traffic.nodes.get(k, []):
		if traffic.edges[x[0]].kind in ROUTE_KINDS:
			return true
	return false


func _nearest_node(p: Vector2) -> Variant:
	var best = null
	var bd := 120.0
	for k in traffic.nodes:
		var d := _node_pos(k).distance_to(p)
		if d < bd and _usable(k):
			bd = d; best = k
	return best


## The shortest way along streets and bike paths (A*), as a polyline that
## starts at `from` and ends at `to`; empty when the loaded streets don't join.
func _path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var s = _nearest_node(from)
	var g = _nearest_node(to)
	if s == null or g == null:
		return PackedVector2Array()
	var goal := _node_pos(g)
	var best := {s: 0.0}
	var came := {}
	var heap := [[_node_pos(s).distance_to(goal), s]]
	var found: bool = s == g
	var steps := 0
	while heap.size() and not found and steps < 60000:
		steps += 1
		var top: Array = _pop(heap)
		var k: Vector2i = top[1]
		if k == g:
			found = true
			break
		var gk: float = best[k]
		if top[0] > gk + _node_pos(k).distance_to(goal) + 0.01:
			continue                        # a stale entry
		for x in traffic.nodes.get(k, []):
			var e: Dictionary = traffic.edges[x[0]]
			if not (e.kind in ROUTE_KINDS):
				continue
			var n: Vector2i = e.ends[1 - x[1]]
			var cost: float = gk + e.len
			if cost < best.get(n, INF):
				best[n] = cost
				came[n] = [k, x[0], x[1]]
				_push(heap, [cost + _node_pos(n).distance_to(goal), n])
	if not found:
		return PackedVector2Array()
	# Walk back from the goal, then lay the edges' own shapes end to end.
	var legs := []
	var k = g
	while came.has(k):
		legs.push_front(came[k])
		k = came[k][0]
	var out := PackedVector2Array([from])
	for leg in legs:
		var pts: PackedVector2Array = traffic.edges[leg[1]].p
		if leg[2] == 1:
			pts = pts.duplicate(); pts.reverse()
		for q in pts:
			if out[out.size() - 1].distance_to(q) > 0.5:
				out.append(q)
	out.append(to)
	return out


func _push(h: Array, item: Array) -> void:
	h.append(item)
	var i := h.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if h[parent][0] <= h[i][0]:
			break
		var t = h[parent]; h[parent] = h[i]; h[i] = t
		i = parent


func _pop(h: Array) -> Array:
	var top: Array = h[0]
	var last: Array = h.pop_back()
	if h.size():
		h[0] = last
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < h.size() and h[l][0] < h[m][0]: m = l
			if r < h.size() and h[r][0] < h[m][0]: m = r
			if m == i:
				break
			var t = h[m]; h[m] = h[i]; h[i] = t
			i = m
	return top


# ---- looks ------------------------------------------------------------------------

func _mat(alpha: float) -> StandardMaterial3D:
	var key := "a%.2f" % alpha
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.albedo_color = Color(YELLOW.r, YELLOW.g, YELLOW.b, alpha)
		m.disable_fog = true
		_mats[key] = m
	return _mats[key]


func _part(parent: Node3D, mesh: Mesh, alpha: float, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(alpha)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position.y = y
	parent.add_child(mi)
	return mi


# A GTA-style circle: a glowing ring on the street, a low translucent wall,
# a beam into the sky, and above it a parcel (pick up) or an arrow (drop off).
func _build_marker(kind: String) -> Node3D:
	var n := Node3D.new()
	var disk := CylinderMesh.new(); disk.top_radius = CIRCLE; disk.bottom_radius = CIRCLE; disk.height = 0.03; disk.radial_segments = 48
	_part(n, disk, 0.32, 0.0)
	var wall := CylinderMesh.new(); wall.top_radius = CIRCLE; wall.bottom_radius = CIRCLE; wall.height = 1.0
	wall.radial_segments = 48; wall.cap_top = false; wall.cap_bottom = false
	_part(n, wall, 0.38, 0.5)
	var rim := TorusMesh.new(); rim.inner_radius = CIRCLE - 0.12; rim.outer_radius = CIRCLE + 0.05; rim.rings = 48
	_part(n, rim, 0.9, 0.04)
	var beam := CylinderMesh.new(); beam.top_radius = 0.45; beam.bottom_radius = 0.45; beam.height = 70.0; beam.radial_segments = 12
	beam.cap_top = false; beam.cap_bottom = false
	_part(n, beam, 0.16, 35.0)
	var icon: Node3D
	if kind == "pickup":
		var box := BoxMesh.new(); box.size = Vector3(0.7, 0.5, 0.55)
		icon = _part(n, box, 0.95, 2.4)
	elif kind == "tulips":
		icon = _tulip_icon(2.2)
		n.add_child(icon)
	else:
		var cone := CylinderMesh.new(); cone.top_radius = 0.55; cone.bottom_radius = 0.0; cone.height = 0.9; cone.radial_segments = 4
		icon = _part(n, cone, 0.95, 2.6)
	icon.name = "icon"
	return n


func _pulse(delta: float) -> void:
	if _marker == null:
		return
	var t := Time.get_ticks_msec() / 1000.0
	var icon: Node3D = _marker.get_node("icon")
	icon.rotation.y += delta * 1.6
	icon.position.y = 2.5 + sin(t * 2.2) * 0.25
	var s := 1.0 + sin(t * 3.0) * 0.04
	_marker.scale = Vector3(s, 1.0, s)


# The route as a flat yellow band over the streets.
func _ribbon_mesh(p: PackedVector2Array, width: float) -> ArrayMesh:
	var v := PackedVector3Array()
	for i in p.size() - 1:
		var a: Vector2 = p[i]; var b: Vector2 = p[i + 1]
		if a.distance_to(b) < 0.01:
			continue
		var n := (b - a).normalized().orthogonal() * width / 2.0
		var y := 0.6
		var A0 := Vector3(a.x + n.x, y, a.y + n.y); var A1 := Vector3(a.x - n.x, y, a.y - n.y)
		var B0 := Vector3(b.x + n.x, y, b.y + n.y); var B1 := Vector3(b.x - n.x, y, b.y - n.y)
		v.append_array([A0, B0, B1, A0, B1, A1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var m := ArrayMesh.new()
	if v.size():
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
