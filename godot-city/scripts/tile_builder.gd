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


## Call on a fresh instance: TileBuilder.new().build_tile(data).
func build_tile(data: Dictionary) -> Dictionary:
	var ti: int = int(data.tile[0]); var tj: int = int(data.tile[1])
	var tile_size := 1500.0
	var x0 := ti * tile_size; var z1 := -tj * tile_size; var z0 := -(tj + 1) * tile_size
	var seed := absi(hash(Vector2i(ti, tj)))
	var bl: Array = data.get("buildings", [])
	for i in bl.size():
		building(bl[i], i, seed)
	# Ground, green, squares.
	var ground := PackedVector2Array([Vector2(x0, z0), Vector2(x0 + tile_size, z0), Vector2(x0 + tile_size, z1), Vector2(x0, z1)])
	polygon("ground", [ground], 0.0, 3.0)
	for g in data.get("green", []):
		var rings := []
		for r in g.r: rings.append(pts(r))
		polygon(g.c, rings, 0.03, 4.0, g.get("t"))
	for g in data.get("plazas", []):
		var rings := []
		for r in g.r: rings.append(pts(r))
		polygon("plaza", rings, 0.02, 3.0, g.get("t"))
	# Water, with a stone quay along every edge; outlines kept for swimming.
	var water := []
	for w in data.get("water", []):
		var rings := []
		for r in w.r: rings.append(pts(r))
		polygon("water", rings, 0.05, 20.0, w.get("t"))
		for r in rings:
			var closed: PackedVector2Array = r.duplicate(); closed.append(r[0])
			ribbon("quay", closed, 0.6, 0.12, 2.0)
		water.append(rings)
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
	for coords in data.get("bridges", []):
		var p := pts(coords)
		var o := ribbon("bridge", p, 7.0, 0.3)
		if o.size():
			side("bridge_side", o[0], 0.3, 1.1); side("bridge_side", o[1], 0.3, 1.1)
		bridges.append(p)
	var labels := []
	for l in data.get("waterLabels", []):
		labels.append([str(l[0]), Vector2(float(l[1]) / 10.0, -float(l[2]) / 10.0), float(l[3])])
		names.append([Vector2(float(l[1]) / 10.0, -float(l[2]) / 10.0), str(l[0])])
	var points := {}
	for k in ["trees", "lamps", "benches", "bikes", "bins", "signals", "bollards"]:
		points[k] = pts(data.get(k, []))
	var places := []
	for p in data.get("places", []):
		places.append([str(p[0]), str(p[1]), Vector2(float(p[2]) / 10.0, -float(p[3]) / 10.0), int(p[4])])
	return {
		"key": "%d_%d" % [ti, tj], "rect": Rect2(x0, z0, tile_size, tile_size),
		"surfaces": surf, "walls": walls, "lanes": lanes, "water": water, "bridges": bridges,
		"labels": labels, "points": points, "places": places, "names": names, "buildings": bl.size(),
	}
