extends RefCounted
## Turns one tile's data (decoded JSON) into plain arrays: mesh surfaces per
## material, wall triangles for collision, road and tram polylines for
## traffic, and positions for trees and street furniture. Runs on worker
## threads, so it touches no nodes and no resources.
##
## Coordinates: the data is integer decimetres from the city origin, x east,
## y north. Scene space is metres, x east, y up, z = -north.

const FLOOR := 3.1
const BAY := 2.2
const GROUND_H := 3.8
const CORNICE_H := 0.45
const ATLAS_BAYS := 4
const ATLAS_FLOORS := 3
const STYLES := 7
const SHOP_STYLES := 6
const ROOFS := 3
const LEVEL := {"walk": 0.07, "road": 0.09, "bike": 0.11, "tram": 0.13, "rail": 0.13}
# Bikes parked along the house fronts: a group every so many metres of wall.
const BIKE_EVERY := Vector2(15.0, 30.0)
const BIKE_GROUP := [1, 1, 1, 2, 2, 3]
const BIKE_FROM_WALL := 0.45
const WATER_Y := -1.4          # canal water lies well below the street...
const QUAY_FOOT := -2.6        # ...between stone quay walls that go on down below it
const BIKE_GAP := 0.65
# Bridges hump over the canals the Amsterdam way: the data's bridges run from
# quay to quay, so a ramp rises from each quay to a level middle that leaves a
# sloep (and whoever stands at its helm) room underneath. Heights are above the
# street; the water lies at WATER_Y.
const BRIDGE_END := 0.3        # the deck where it meets the street
const BRIDGE_RISE := 1.2       # how much higher the middle is (less on short bridges)
const BRIDGE_RAMP := 0.3       # each ramp's share of the bridge (2 to 8 m)
const BRIDGE_DEPTH := 0.55     # the deck's thickness: its underside is this far below
const BRIDGE_WIDTH := 7.0
const BRIDGE_CELL := 12.0      # the grid bridge_y looks segments up in

var surf := {}          # material name -> [PackedVector3Array, PackedVector3Array, PackedVector2Array]
var walls := PackedVector3Array()


static func pts(flat: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(flat.size() / 2)
	for i in out.size():
		out[i] = Vector2(float(flat[2 * i]) / 10.0, -float(flat[2 * i + 1]) / 10.0)
	return out


func _s(mat: String) -> Array:
	if not surf.has(mat):
		surf[mat] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array()]
	return surf[mat]


# One triangle facing n (Godot draws clockwise faces as front faces).
func tri(mat: String, a: Vector3, b: Vector3, c: Vector3, n: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	var s := _s(mat)
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b; b = c; c = t
		var tu := ub; ub = uc; uc = tu
	s[0].append(a); s[0].append(b); s[0].append(c)
	s[1].append(n); s[1].append(n); s[1].append(n)
	# Images have v = 0 at the top row; the layouts below count v upward.
	s[2].append(Vector2(ua.x, 1.0 - ua.y)); s[2].append(Vector2(ub.x, 1.0 - ub.y)); s[2].append(Vector2(uc.x, 1.0 - uc.y))


func quad(mat: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, uv: Array) -> void:
	tri(mat, a, b, c, n, uv[0], uv[1], uv[2])
	tri(mat, a, c, d, n, uv[0], uv[2], uv[3])


# A flat polygon at height y facing up; rings as PackedVector2Array (x, z).
func polygon(mat: String, rings: Array, y: float, uv_scale: float, tris = null) -> void:
	var all := PackedVector2Array()
	for r in rings:
		all.append_array(r)
	var idx: PackedInt32Array
	if tris != null:
		idx = PackedInt32Array(tris)
	else:
		idx = Geometry2D.triangulate_polygon(rings[0])
	for k in range(0, idx.size() - 2, 3):
		var p: Vector2 = all[idx[k]]; var q: Vector2 = all[idx[k + 1]]; var r: Vector2 = all[idx[k + 2]]
		tri(mat, Vector3(p.x, y, p.y), Vector3(q.x, y, q.y), Vector3(r.x, y, r.y), Vector3.UP,
			p / uv_scale, q / uv_scale, r / uv_scale)


# ---- buildings ---------------------------------------------------------------

func mats_for(bd: Dictionary, i: int, seed: int) -> Dictionary:
	var h := absi(hash(seed + i * 7919))
	if int(bd.get("k", 0)) == 5:
		return {"ground": "boat", "upper": "boat", "trim": "boat", "roof": "roof_flat", "flat": "roof_flat"}
	var s := h % STYLES
	var shop := bd.has("s") or int(bd.get("k", 0)) == 2
	return {
		"ground": ("ground_shop_%d" % ((h >> 4) % SHOP_STYLES)) if shop else ("ground_home_%d" % s),
		"upper": "office" if int(bd.get("k", 0)) == 3 else "facade_%d" % s,
		"trim": "trim_%d" % s,
		"roof": "roof_%d" % ((h >> 8) % ROOFS),
		"flat": "roof_flat",
	}


# A wall from a to b cut into ground floor, upper storeys and a cornice.
func wall(m: Dictionary, a: Vector2, b: Vector2, y0: float, top: float, n: Vector3, run: float, apex = null) -> float:
	var length := a.distance_to(b)
	if length < 0.05:
		return run
	var tall := top - y0 > 5.0
	var g := y0 + minf(GROUND_H, (top - y0) * 0.45) if tall else y0
	var c := top - CORNICE_H if tall else top
	var u0 := run; var u1 := run + length
	var A := func(y): return Vector3(a.x, y, a.y)
	var Bv := func(y): return Vector3(b.x, y, b.y)
	if tall:
		quad(m.ground, A.call(y0), Bv.call(y0), Bv.call(g), A.call(g), n,
			[Vector2(u0 / (2 * BAY), 0), Vector2(u1 / (2 * BAY), 0), Vector2(u1 / (2 * BAY), 1), Vector2(u0 / (2 * BAY), 1)])
	var UB := ATLAS_BAYS * BAY; var VF := ATLAS_FLOORS * FLOOR
	if c - g > 0.01:
		quad(m.upper, A.call(g), Bv.call(g), Bv.call(c), A.call(c), n,
			[Vector2(u0 / UB, 0), Vector2(u1 / UB, 0), Vector2(u1 / UB, (c - g) / VF), Vector2(u0 / UB, (c - g) / VF)])
	if tall and apex == null:
		quad(m.trim, A.call(c), Bv.call(c), Bv.call(top), A.call(top), n,
			[Vector2(u0 / 2, 0), Vector2(u1 / 2, 0), Vector2(u1 / 2, 1), Vector2(u0 / 2, 1)])
	if apex != null:
		var mp: Vector3 = apex
		tri(m.upper, A.call(top), Bv.call(top), mp, n,
			Vector2(u0 / UB, (top - g) / VF), Vector2(u1 / UB, (top - g) / VF), Vector2((u0 + u1) / 2 / UB, (mp.y - g) / VF))
		for p in [a, b]:          # stone coping along the gable's sloping edges
			quad(m.trim, Vector3(p.x, top, p.y), mp, mp + Vector3(0, 0.35, 0), Vector3(p.x, top + 0.35, p.y), n,
				[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	# Collision: the plain wall, ground to top.
	walls.append_array(PackedVector3Array([A.call(0.0), Bv.call(0.0), Bv.call(top), A.call(0.0), Bv.call(top), A.call(top)]))
	return run + length


func building(bd: Dictionary, i: int, seed: int) -> void:
	var m := mats_for(bd, i, seed)
	var y0 := -1.1 if bd.has("w") else 0.0
	if bd.has("g"):
		var c := pts(bd.g)
		var eave := float(bd.e); var ridge := float(bd.h)
		var m01 := (c[0] + c[1]) / 2.0; var m23 := (c[2] + c[3]) / 2.0
		var ctr := (c[0] + c[2]) / 2.0
		var out := func(p: Vector2, q: Vector2) -> Vector3:
			var d := ((p + q) / 2.0 - ctr).normalized()
			return Vector3(d.x, 0, d.y)
		var run := 0.0
		for e in [[c[1], c[2]], [c[3], c[0]]]:
			run = wall(m, e[0], e[1], y0, eave, out.call(e[0], e[1]), run)
		for e in [[c[0], c[1], m01], [c[2], c[3], m23]]:
			wall(m, e[0], e[1], y0, eave, out.call(e[0], e[1]), 0.0, Vector3(e[2].x, ridge, e[2].y))
		var L := c[1].distance_to(c[2])
		for e in [[c[1], c[2], m01, m23], [c[3], c[0], m23, m01]]:
			var p: Vector2 = e[0]; var q: Vector2 = e[1]; var ma: Vector2 = e[2]; var mb: Vector2 = e[3]
			var P0 := Vector3(p.x, eave, p.y); var P1 := Vector3(q.x, eave, q.y)
			var P2 := Vector3(mb.x, ridge, mb.y); var P3 := Vector3(ma.x, ridge, ma.y)
			var n := (P1 - P0).cross(P3 - P0).normalized()
			if n.y < 0: n = -n
			var sl := P0.distance_to(P3)
			quad(m.roof, P0, P1, P2, P3, n, [Vector2(0, 0), Vector2(L / 4, 0), Vector2(L / 4, sl / 4), Vector2(0, sl / 4)])
	else:
		var rings := []
		for r in bd.r:
			rings.append(pts(r))
		var top := y0 + float(bd.h)
		for ring in rings:
			var run := 0.0
			for k in ring.size():
				var a: Vector2 = ring[k]; var b: Vector2 = ring[(k + 1) % ring.size()]
				var d := b - a
				if d.length() < 0.05: continue
				# Rings run counter-clockwise on the north-up map; with z = -north
				# the outside of each edge is (-dz, dx). Holes run the other way.
				var n := Vector3(-d.y, 0, d.x).normalized()
				run = wall(m, a, b, y0, top, n, run)
		polygon(m.flat, rings, top, 6.0, bd.get("t"))


# Spots along the outside walls of buildings where bikes stand, parallel to
# the wall on the pavement: [positions, yaws]. A spot is dropped when it
# would be inside another building (a party wall), in a canal, or hard
# against something across the way.
func _street_bikes(bl: Array, water: Array, seed: int, neighbours: Array = []) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed + 77
	const CELL := 25.0
	var rings := []
	var grid := {}
	# This chunk's buildings, then the outlines of those just across its edges.
	for i in bl.size() + neighbours.size():
		var ring: PackedVector2Array
		if i < bl.size():
			ring = pts(bl[i].g) if bl[i].has("g") else pts(bl[i].r[0])
		else:
			ring = pts(neighbours[i - bl.size()])
		rings.append(ring)
		var box := Rect2(ring[0], Vector2.ZERO)
		for q in ring: box = box.expand(q)
		for cx in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
			for cy in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
				var k := Vector2i(cx, cy)
				if not grid.has(k): grid[k] = []
				grid[k].append(i)
	var in_building := func(p: Vector2, skip: int) -> bool:
		for j in grid.get(Vector2i(floori(p.x / CELL), floori(p.y / CELL)), []):
			if j != skip and Geometry2D.is_point_in_polygon(p, rings[j]):
				return true
		return false
	var in_water := func(p: Vector2) -> bool:
		for w in water:
			if Geometry2D.is_point_in_polygon(p, w[0]):
				return true
		return false
	var at := PackedVector2Array()
	var yaw := PackedFloat32Array()
	var until := rng.randf_range(BIKE_EVERY.x, BIKE_EVERY.y)
	for i in bl.size():
		if bl[i].has("w"):
			continue                          # houseboats
		var ring: PackedVector2Array = rings[i]
		for e in ring.size():
			var a: Vector2 = ring[e]; var b: Vector2 = ring[(e + 1) % ring.size()]
			var length := a.distance_to(b)
			if length < 0.5:
				continue
			var dir := (b - a) / length
			var n := Vector2(-dir.y, dir.x)
			if Geometry2D.is_point_in_polygon((a + b) / 2.0 + n * 0.3, ring):
				n = -n                        # make n point out of the building
			var t := until
			while t < length:
				var k: int = BIKE_GROUP[rng.randi() % BIKE_GROUP.size()]
				var span := (k - 1) * BIKE_GAP
				if t > 1.0 and t + span < length - 1.0:
					var base := a + dir * t + n * BIKE_FROM_WALL
					var clear: bool = not in_building.call(base, i) and not in_building.call(base + n * 1.4, -1) \
						and not in_water.call(base) and not in_water.call(base + n * 0.8)
					if clear:
						var facing := 1.0 if rng.randf() < 0.5 else -1.0
						for m in k:
							at.append(base + dir * (m * BIKE_GAP))
							var d := dir * facing
							yaw.append(atan2(-d.x, -d.y) + rng.randf_range(-0.06, 0.06))
				t += rng.randf_range(BIKE_EVERY.x, BIKE_EVERY.y)
			until = t - length
	return [at, yaw]


# What vehicles drive on and into: the street level (at road height), bridge
# decks and railings, the quay walls and the canal beds.
func _ground_faces(sunk: bool) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not sunk:
		return out
	for name in ["ground", "bridge", "bridge_side", "quay_wall", "water"]:
		if not surf.has(name):
			continue
		var lift: float = {"ground": 0.09, "water": QUAY_FOOT - WATER_Y}.get(name, 0.0)   # the bed lies at the quays' foot
		for v in surf[name][0]:
			out.append(Vector3(v.x, v.y + lift, v.z))
	return out


# Whether p is on the water of any polygon but `skip`.
static func _wet(p: Vector2, water: Array, skip: int) -> bool:
	for j in water.size():
		if j == skip or not Geometry2D.is_point_in_polygon(p, water[j][0]):
			continue
		var hole := false
		for k in range(1, water[j].size()):
			if Geometry2D.is_point_in_polygon(p, water[j][k]): hole = true
		if not hole:
			return true
	return false


# A canal's stone quay wall along one ring of its outline, facing the water
# (with `walls`; the flat data of an unsunk tile has none). Edges along the
# chunk's border are only where the data was cut, and edges with water beyond
# them are where it split a canal: no quay at either. Returns the shore as
# runs of consecutive edges, for the kerb along its top.
func _quay_wall(ring: PackedVector2Array, outer: bool, rect: Rect2, water: Array, me: int, walls := true) -> Array:
	var area := 0.0
	for i in ring.size():
		var a: Vector2 = ring[i]; var b: Vector2 = ring[(i + 1) % ring.size()]
		area += a.x * b.y - b.x * a.y
	var on_edge := func(p: Vector2) -> int:
		var m := 0
		if absf(p.x - rect.position.x) < 0.05: m |= 1
		if absf(p.x - rect.end.x) < 0.05: m |= 2
		if absf(p.y - rect.position.y) < 0.05: m |= 4
		if absf(p.y - rect.end.y) < 0.05: m |= 8
		return m
	var run := 0.0
	var shore := []                     # runs of consecutive shore edges
	var cur := PackedVector2Array()
	for i in ring.size():
		var a: Vector2 = ring[i]; var b: Vector2 = ring[(i + 1) % ring.size()]
		var length := a.distance_to(b)
		if length < 0.01:
			continue
		var d := (b - a) / length
		var inward := Vector2(-d.y, d.x) if area > 0.0 else Vector2(d.y, -d.x)
		var n2 := inward if outer else -inward   # the water is inside the outline, outside an island
		if (on_edge.call(a) & on_edge.call(b)) != 0 or _wet((a + b) / 2.0 - n2 * 0.4, water, me):
			if cur.size() > 1: shore.append(cur)
			cur = PackedVector2Array()
			continue
		if cur.is_empty(): cur.append(a)
		cur.append(b)
		if walls:
			var n := Vector3(n2.x, 0, n2.y)
			quad("quay_wall", Vector3(a.x, QUAY_FOOT, a.y), Vector3(b.x, QUAY_FOOT, b.y), Vector3(b.x, 0.0, b.y), Vector3(a.x, 0.0, a.y), n,
				[Vector2(run / 3.0, 0), Vector2((run + length) / 3.0, 0), Vector2((run + length) / 3.0, -QUAY_FOOT / 3.0), Vector2(run / 3.0, -QUAY_FOOT / 3.0)])
		run += length
	if cur.size() > 1:
		# A run that goes on round the ring's start joins the first one.
		if not shore.is_empty() and shore[0][0] == cur[cur.size() - 1]:
			cur.append_array(shore[0].slice(1)); shore[0] = cur
		else:
			shore.append(cur)
	return shore


# ---- streets, water, green ----------------------------------------------------

# A polyline as a flat ribbon with mitred joins. Returns the two edges.
func ribbon(mat: String, p: PackedVector2Array, width: float, y: float, uv_scale := 4.0) -> Array:
	if p.size() < 2:
		return []
	var hw := width / 2.0
	var L := PackedVector2Array(); var R := PackedVector2Array()
	for i in p.size():
		var a := p[maxi(0, i - 1)]; var c := p[mini(p.size() - 1, i + 1)]
		var d1 := (p[i] - a).normalized(); var d2 := (c - p[i]).normalized()
		if i == 0: d1 = d2
		if i == p.size() - 1: d2 = d1
		var nrm := Vector2(-(d1.y + d2.y), d1.x + d2.x).normalized()
		var k := minf(2.5, 1.0 / maxf(0.4, nrm.dot(Vector2(-d2.y, d2.x))))
		L.append(p[i] + nrm * hw * k); R.append(p[i] - nrm * hw * k)
	if mat != "":
		var run := 0.0
		for i in p.size() - 1:
			var seg := p[i].distance_to(p[i + 1])
			quad(mat, Vector3(L[i].x, y, L[i].y), Vector3(R[i].x, y, R[i].y), Vector3(R[i + 1].x, y, R[i + 1].y), Vector3(L[i + 1].x, y, L[i + 1].y), Vector3.UP,
				[Vector2(0, run / uv_scale), Vector2(width / uv_scale, run / uv_scale), Vector2(width / uv_scale, (run + seg) / uv_scale), Vector2(0, (run + seg) / uv_scale)])
			run += seg
	return [L, R]


func side(mat: String, p: PackedVector2Array, y0: float, y1: float) -> void:
	for i in p.size() - 1:
		var a := p[i]; var b := p[i + 1]
		var d := (b - a).normalized()
		var n := Vector3(-d.y, 0, d.x)
		var seg_len := a.distance_to(b)
		for sgn in [1.0, -1.0]:
			quad(mat, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y), n * sgn,
				[Vector2(0, 0), Vector2(seg_len, 0), Vector2(seg_len, 1), Vector2(0, 1)])


# The deck height `s` metres along a bridge `length` long. An end cut by the
# chunk border has no ramp (the bridge goes on in the next chunk at full
# height, where the same rule meets it).
static func bridge_height(s: float, length: float, ramp_start: bool, ramp_end: bool) -> float:
	var rise := BRIDGE_RISE if not (ramp_start and ramp_end) else clampf(length * 0.1, 0.5, BRIDGE_RISE)
	var ramp := clampf(length * BRIDGE_RAMP, 2.0, 8.0)
	var t := 1.0
	if ramp_start: t = minf(t, s / ramp)
	if ramp_end: t = minf(t, (length - s) / ramp)
	t = clampf(t, 0.0, 1.0)
	return BRIDGE_END + rise * t * t * (3.0 - 2.0 * t)


# A humped bridge along centre line p: the deck, a railing each side, the
# stone edge under the deck and its underside (the last three are solid).
# Returns [points every 2 m or less, deck height at each], or [].
func _bridge(p: PackedVector2Array, rect: Rect2) -> Array:
	if p.size() < 2:
		return []
	var cut := func(e: Vector2) -> bool:
		return absf(e.x - rect.position.x) < 0.05 or absf(e.x - rect.end.x) < 0.05 \
			or absf(e.y - rect.position.y) < 0.05 or absf(e.y - rect.end.y) < 0.05
	var ramp_a: bool = not cut.call(p[0])
	var ramp_b: bool = not cut.call(p[p.size() - 1])
	var q := PackedVector2Array([p[0]])
	for i in p.size() - 1:
		var n := maxi(1, ceili(p[i].distance_to(p[i + 1]) / 2.0))
		for k in range(1, n + 1):
			q.append(p[i].lerp(p[i + 1], float(k) / n))
	var along := PackedFloat32Array([0.0])
	for i in range(1, q.size()):
		along.append(along[i - 1] + q[i - 1].distance_to(q[i]))
	var length: float = along[along.size() - 1]
	var h := PackedFloat32Array()
	for d in along:
		h.append(bridge_height(d, length, ramp_a, ramp_b))
	var o := ribbon("", q, BRIDGE_WIDTH, 0.0)
	if o.is_empty():
		return []
	var L: PackedVector2Array = o[0]; var R: PackedVector2Array = o[1]
	var v3 := func(e: Vector2, y: float) -> Vector3: return Vector3(e.x, y, e.y)
	for i in q.size() - 1:
		var y0: float = h[i]; var y1: float = h[i + 1]
		var a: Vector3 = v3.call(L[i], y0); var b: Vector3 = v3.call(R[i], y0)
		var c: Vector3 = v3.call(R[i + 1], y1); var d: Vector3 = v3.call(L[i + 1], y1)
		var up := (d - a).cross(b - a).normalized()
		if up.y < 0.0: up = -up
		var u0 := along[i] / 4.0; var u1 := along[i + 1] / 4.0; var wv := BRIDGE_WIDTH / 4.0
		quad("bridge", a, b, c, d, up, [Vector2(0, u0), Vector2(wv, u0), Vector2(wv, u1), Vector2(0, u1)])
		var dn := Vector3(0, -BRIDGE_DEPTH, 0)
		quad("quay_wall", a + dn, b + dn, c + dn, d + dn, -up, [Vector2(0, u0), Vector2(wv, u0), Vector2(wv, u1), Vector2(0, u1)])
		for e in [L, R]:
			var e0: Vector2 = e[i]; var e1: Vector2 = e[i + 1]
			var seg := (e1 - e0).normalized()
			var n := Vector3(-seg.y, 0, seg.x)
			var run := along[i]; var run1 := along[i + 1]
			for sgn in [1.0, -1.0]:
				quad("bridge_side", v3.call(e0, y0), v3.call(e1, y1), v3.call(e1, y1 + 0.8), v3.call(e0, y0 + 0.8), n * sgn,
					[Vector2(run, 0), Vector2(run1, 0), Vector2(run1, 1), Vector2(run, 1)])
				quad("quay_wall", v3.call(e0, y0 - BRIDGE_DEPTH), v3.call(e1, y1 - BRIDGE_DEPTH), v3.call(e1, y1), v3.call(e0, y0), n * sgn,
					[Vector2(run / 3.0, 0), Vector2(run1 / 3.0, 0), Vector2(run1 / 3.0, BRIDGE_DEPTH / 3.0), Vector2(run / 3.0, BRIDGE_DEPTH / 3.0)])
	return [q, h]


# Each bridge segment, with its end heights, in every grid cell it passes near.
func _index_bridge(q: PackedVector2Array, h: PackedFloat32Array, cells: Dictionary) -> void:
	var reach := BRIDGE_WIDTH / 2.0
	for i in q.size() - 1:
		var lo := Vector2(minf(q[i].x, q[i + 1].x), minf(q[i].y, q[i + 1].y)) - Vector2.ONE * reach
		var hi := Vector2(maxf(q[i].x, q[i + 1].x), maxf(q[i].y, q[i + 1].y)) + Vector2.ONE * reach
		for cx in range(floori(lo.x / BRIDGE_CELL), floori(hi.x / BRIDGE_CELL) + 1):
			for cz in range(floori(lo.y / BRIDGE_CELL), floori(hi.y / BRIDGE_CELL) + 1):
				var k := Vector2i(cx, cz)
				if not cells.has(k):
					cells[k] = []
				cells[k].append([q[i], q[i + 1], h[i], h[i + 1]])


## The deck height of the bridge over p (from a built tile's bridge_cells), or NAN.
static func bridge_y(cells: Dictionary, p: Vector2) -> float:
	var segs = cells.get(Vector2i(floori(p.x / BRIDGE_CELL), floori(p.y / BRIDGE_CELL)))
	if segs == null:
		return NAN
	var best := BRIDGE_WIDTH / 2.0
	var y := NAN
	for sg in segs:
		var a: Vector2 = sg[0]; var b: Vector2 = sg[1]
		var c := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := c.distance_to(p)
		if d < best:
			best = d
			var t := c.distance_to(a) / maxf(a.distance_to(b), 0.001)
			y = lerpf(float(sg[2]), float(sg[3]), t)
	return y


## Call on a fresh instance: TileBuilder.new().build_tile(data).
func build_tile(data: Dictionary) -> Dictionary:
	var ti: int = int(data.tile[0]); var tj: int = int(data.tile[1])
	var tile_size := float(data.get("size", 1500.0))   # a chunk's size, or a whole tile's
	var x0 := ti * tile_size; var z1 := -tj * tile_size; var z0 := -(tj + 1) * tile_size
	var seed := absi(hash(Vector2i(ti, tj)))
	var bl: Array = data.get("buildings", [])
	for i in bl.size():
		building(bl[i], i, seed)
	# Ground, green, squares.
	var ground := PackedVector2Array([Vector2(x0, z0), Vector2(x0 + tile_size, z0), Vector2(x0 + tile_size, z1), Vector2(x0, z1)])
	if data.has("ground"):                # the street level, with the canals cut out
		for g in data.ground:
			var rings := []
			for r in g.r: rings.append(pts(r))
			polygon("ground", rings, 0.0, 3.0, g.get("t"))
	else:
		polygon("ground", [ground], 0.0, 3.0)
	for g in data.get("green", []):
		var rings := []
		for r in g.r: rings.append(pts(r))
		polygon(g.c, rings, 0.03, 4.0, g.get("t"))
	for g in data.get("plazas", []):
		var rings := []
		for r in g.r: rings.append(pts(r))
		polygon("plaza", rings, 0.02, 3.0, g.get("t"))
	# Water, with a stone quay along every edge that is a shore; outlines kept
	# for swimming. (The data splits a canal into pieces, often under a bridge:
	# where two pieces meet there is water on both sides and no quay.)
	var water := []
	for w in data.get("water", []):
		var rings := []
		for r in w.r: rings.append(pts(r))
		water.append(rings)
	for i in water.size():
		var rings: Array = water[i]
		var t = data.water[i].get("t")
		polygon("water", rings, WATER_Y if data.has("ground") else 0.05, 20.0, t)
		for k in rings.size():
			for run in _quay_wall(rings[k], k == 0, Rect2(x0, z0, tile_size, tile_size), water, i, data.has("ground")):
				ribbon("quay", run, 0.6, 0.12, 2.0)
	# Streets, tram and rail; polylines kept for traffic and street names.
	var lanes := []
	var names := []
	for rd in data.get("roads", []):
		var layer: String = rd[0]; var w: float = float(rd[1]); var p := pts(rd[2])
		ribbon(layer, p, w, LEVEL.get(layer, 0.08))
		if layer == "tram" or layer == "rail":
			var o := ribbon("", p, 1.435, 0.0)
			if o.size():
				ribbon("rails", o[0], 0.12, 0.16); ribbon("rails", o[1], 0.12, 0.16)
		if layer == "road" or layer == "tram" or layer == "bike":
			lanes.append({"kind": layer, "w": w, "p": p})
		if str(rd[3]) != "":
			names.append([p[p.size() / 2], str(rd[3])])
	var bridges := []
	var bridge_cells := {}
	for coords in data.get("bridges", []):
		var b := _bridge(pts(coords), Rect2(x0, z0, tile_size, tile_size))
		if b.is_empty():
			continue
		bridges.append(b[0])
		_index_bridge(b[0], b[1], bridge_cells)
	var labels := []
	for l in data.get("waterLabels", []):
		labels.append([str(l[0]), Vector2(float(l[1]) / 10.0, -float(l[2]) / 10.0), float(l[3])])
		names.append([Vector2(float(l[1]) / 10.0, -float(l[2]) / 10.0), str(l[0])])
	var street_bikes := _street_bikes(bl, water, seed, data.get("nb", []))
	var points := {}
	for k in ["trees", "lamps", "benches", "bikes", "bins", "signals", "bollards"]:
		points[k] = pts(data.get(k, []))
	var places := []
	for p in data.get("places", []):
		places.append([str(p[0]), str(p[1]), Vector2(float(p[2]) / 10.0, -float(p[3]) / 10.0), int(p[4])])
	return {
		"key": "%d_%d" % [ti, tj], "rect": Rect2(x0, z0, tile_size, tile_size),
		"surfaces": surf, "walls": walls, "lanes": lanes, "water": water, "bridges": bridges, "bridge_cells": bridge_cells,
		"labels": labels, "points": points, "places": places, "names": names, "buildings": bl.size(),
		"street_bikes": street_bikes,
		"water_y": (WATER_Y if data.has("ground") else 0.05),
		"ground_faces": _ground_faces(data.has("ground")),
	}
