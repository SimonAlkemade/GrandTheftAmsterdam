"""Cut a prepared Godot tile into smaller chunks the game streams one by one.

A tile file stays the download unit (so the web build has few files), but
inside it the city is split into CHUNK x CHUNK chunks, each a complete little
tile of its own: buildings by their centre, points by where they stand, and
streets, bridges, canals, parks and squares clipped at the chunk edges. A
street cut at an edge ends on exactly the same decimetre in both chunks, so
the traffic graph still joins it up.

Coordinates are integer decimetres from the city origin (x east, y north),
as everywhere in the tile data.
"""
from __future__ import annotations

import math

import mapbox_earcut as earcut
import numpy as np
from shapely.geometry import LineString, MultiLineString, MultiPolygon, Polygon, box
from shapely.geometry.base import BaseGeometry
from shapely.ops import unary_union

POINT_KEYS = ("trees", "lamps", "benches", "bikes", "bins", "signals", "bollards")
POLY_KEYS = ("water", "green", "plazas")


def tris(rings):
    """earcut over rings given as flat [x, y, ...] decimetre lists."""
    pts = [np.asarray(r, float).reshape(-1, 2) for r in rings if len(r) >= 6]
    if not pts:
        return []
    ends = np.cumsum([len(p) for p in pts]).astype(np.uint32)
    return earcut.triangulate_float64(np.vstack(pts), ends).tolist()


def _flat(coords):
    out = []
    for x, y in coords:
        q = [int(round(x)), int(round(y))]
        if len(out) < 2 or out[-2:] != q:
            out += q
    return out


def _polys(g: BaseGeometry):
    if isinstance(g, Polygon):
        return [g] if not g.is_empty else []
    if hasattr(g, "geoms"):
        return [p for sub in g.geoms for p in _polys(sub)]
    return []


def _lines(g: BaseGeometry):
    if isinstance(g, LineString):
        return [g] if not g.is_empty else []
    if hasattr(g, "geoms"):
        return [l for sub in g.geoms for l in _lines(sub)]
    return []


def _shape(rings) -> Polygon:
    shell = np.asarray(rings[0], float).reshape(-1, 2)
    holes = [np.asarray(r, float).reshape(-1, 2) for r in rings[1:] if len(r) >= 6]
    p = Polygon(shell, holes)
    return p if p.is_valid else p.buffer(0)


def _rings(p: Polygon):
    rings = [_flat(list(p.exterior.coords)[:-1])] + [_flat(list(h.coords)[:-1]) for h in p.interiors]
    return [r for r in rings if len(r) >= 6]


def _key(x, y, size, tile=None, n=1):
    """The chunk a point falls in; with tile, clamped into that tile's chunks
    (a tile also carries things that overlap its edge from outside)."""
    a, b = math.floor(x / size), math.floor(y / size)
    if tile is not None:
        a = min(max(a, tile[0] * n), tile[0] * n + n - 1)
        b = min(max(b, tile[1] * n), tile[1] * n + n - 1)
    return "%d_%d" % (a, b)


def split_tile(t: dict, tile_dm: float, chunk_dm: float) -> dict:
    """{chunk key: chunk data}; every chunk of the tile is present (each has ground)."""
    i, j = t["tile"]
    n = int(round(tile_dm / chunk_dm))
    out = {}
    for a in range(i * n, (i + 1) * n):
        for b in range(j * n, (j + 1) * n):
            out["%d_%d" % (a, b)] = {"tile": [a, b], "size": chunk_dm / 10.0}
    put = lambda key, field, item: out[key].setdefault(field, []).append(item)

    near = 50.0                          # dm: neighbours this close across a border are listed
    for bd in t.get("buildings", []):
        flat = bd["g"] if "g" in bd else bd["r"][0]
        ring = np.asarray(flat, float).reshape(-1, 2)
        cx, cy = ring.mean(axis=0)
        own = _key(cx, cy, chunk_dm, (i, j), n)
        put(own, "buildings", bd)
        # Its outline, for the chunks next door: so a bike there is not parked inside it.
        (x0, y0), (x1, y1) = ring.min(axis=0) - near, ring.max(axis=0) + near
        for a in range(math.floor(x0 / chunk_dm), math.floor(x1 / chunk_dm) + 1):
            for b in range(math.floor(y0 / chunk_dm), math.floor(y1 / chunk_dm) + 1):
                key = "%d_%d" % (a, b)
                if key != own and key in out:
                    put(key, "nb", flat)
    for field in POINT_KEYS:
        flat = t.get(field, [])
        for k in range(0, len(flat) - 1, 2):
            out[_key(flat[k], flat[k + 1], chunk_dm, (i, j), n)].setdefault(field, []).extend(flat[k:k + 2])
    for lab in t.get("waterLabels", []):
        put(_key(lab[1], lab[2], chunk_dm, (i, j), n), "waterLabels", lab)
    for pl in t.get("places", []):
        put(_key(pl[2], pl[3], chunk_dm, (i, j), n), "places", pl)

    boxes = {key: box(c["tile"][0] * chunk_dm, c["tile"][1] * chunk_dm,
                      (c["tile"][0] + 1) * chunk_dm, (c["tile"][1] + 1) * chunk_dm) for key, c in out.items()}

    def overlapping(g):
        x0, y0, x1, y1 = g.bounds
        for a in range(math.floor(x0 / chunk_dm), math.floor(x1 / chunk_dm) + 1):
            for b in range(math.floor(y0 / chunk_dm), math.floor(y1 / chunk_dm) + 1):
                key = "%d_%d" % (a, b)
                if key in boxes:
                    yield key

    for field in POLY_KEYS:
        for item in t.get(field, []):
            shape = _shape(item["r"])
            for key in overlapping(shape):
                for piece in _polys(shape.intersection(boxes[key])):
                    if piece.area < 1.0:
                        continue
                    rings = _rings(piece)
                    if not rings:
                        continue
                    rec = {"r": rings}
                    if "c" in item:
                        rec["c"] = item["c"]
                    if len(rings) > 1:
                        rec["t"] = tris(rings)
                    put(key, field, rec)

    def clip_lines(coords):
        line = LineString(np.asarray(coords, float).reshape(-1, 2))
        if line.length == 0:
            return
        for key in overlapping(line):
            for piece in _lines(line.intersection(boxes[key])):
                flat = _flat(piece.coords)
                if len(flat) >= 4:
                    yield key, flat

    for rd in t.get("roads", []):
        for key, flat in clip_lines(rd[2]):
            put(key, "roads", [rd[0], rd[1], flat, rd[3]])
    for br in t.get("bridges", []):
        for key, flat in clip_lines(br):
            put(key, "bridges", flat)
    for c in out.values():
        add_ground(c, chunk_dm)
    return out


def add_ground(c: dict, chunk_dm: float) -> None:
    """The chunk's street-level ground with its canals cut out (so the water
    can lie lower), as {"r": rings, "t": triangles} pieces."""
    a, b = c["tile"]
    area = box(a * chunk_dm, b * chunk_dm, (a + 1) * chunk_dm, (b + 1) * chunk_dm)
    water = [_shape(w["r"]) for w in c.get("water", [])]
    if water:
        area = area.difference(unary_union(water).buffer(0))
    pieces = []
    for p in _polys(area):
        if p.area < 1.0:
            continue
        rings = _rings(p)
        if rings:
            pieces.append({"r": rings, "t": tris(rings)})
    c["ground"] = pieces


def chunk_tile(t: dict, tile_dm: float, chunk_dm: float) -> dict:
    """The tile file in its chunked form."""
    return {"tile": t["tile"], "chunk": chunk_dm / 10.0, "chunks": split_tile(t, tile_dm, chunk_dm)}
