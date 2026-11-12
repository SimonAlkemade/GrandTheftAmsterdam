"""A compact Amsterdam for the game, made from the real city's data.

    python compact_city.py godot-city/data godot-city/data-compact

The full city is about 24 x 17 km: far too big to play. This keeps its
structure and makes it small:

  * the centre (within CORE of the Dam: the canal ring, the Wallen, the IJ
    front) stays exactly as it is, 1:1;
  * beyond it the city is pulled in towards the Dam by a smooth radial warp
    (the slope 1 at the core's edge, shrinking outwards), so the Jordaan, De
    Pijp, Oost, Westerpark, the Vondelpark and the IJ's far bank all come
    close, and everything out to KEEP lands within ISLAND of the Dam;
  * every street, canal, bridge, park, square, lamp, tree, bench, place and
    petrol station is warped by the same function, so the network stays
    joined and the canals stay rings;
  * buildings are not squashed: each moves whole with its warped centre,
    keeping its real shape, height and roof, and is dropped where it would
    now overlap a street, a canal or a building already kept. So: the same
    structure, fewer houses;
  * the island is ringed by open water (the city as an island, GTA-style),
    and a few of the city's petrol stations beyond it are brought in along
    its outer belt, so there are still plenty.

The result is tiled and chunked like the full data (amsterdam/chunks.py) and
the game streams it the same way (scripts/city_streamer.gd, --city=compact).
"""
from __future__ import annotations

import json
import math
import random
import shutil
import sys
from pathlib import Path

import numpy as np
from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import unary_union

from amsterdam.chunks import POINT_KEYS, POLY_KEYS, _lines, _polys, _rings, _shape, chunk_tile
from chunk_godot_tiles import chunk_data

CORE = 10000.0          # dm: untouched within 1 km of the Dam
KEEP = 24000.0          # dm: the city kept out to 2.4 km of the Dam...
ISLAND = 16000.0        # dm: ...lands within 1.6 km: an island about 3.2 km across
SEA = 20000.0           # dm: open water out to here (square), then nothing
PATHS_BELOW = 0.5       # footpaths are dropped where the city is squeezed to less than this
STEP = 100.0            # dm: lines and outlines get a point every 10 m before warping
TILE = 15000.0          # dm (1500 m tiles, 375 m chunks, as the full data)
STATIONS = 18           # petrol stations wanted on the island


def _solve_a(core: float, keep: float, island: float) -> float:
    """The warp's scale: core + a*ln(1 + (keep - core)/a) == island."""
    lo, hi = 1.0, 1e7
    for _ in range(200):
        mid = (lo + hi) / 2
        if core + mid * math.log1p((keep - core) / mid) > island:
            hi = mid
        else:
            lo = mid
    return (lo + hi) / 2


class Warp:
    def __init__(self, centre, core=CORE, keep=KEEP, island=ISLAND):
        self.c = np.asarray(centre, float)
        self.core, self.keep, self.island = core, keep, island
        self.a = _solve_a(core, keep, island)

    def slope(self, r):
        """How much the city is squeezed at distance r (1 = not at all)."""
        return 1.0 if r <= self.core else 1.0 / (1.0 + (r - self.core) / self.a)

    def radius(self, r):
        r = np.asarray(r, float)
        out = np.where(r <= self.core, r, self.core + self.a * np.log1p(np.maximum(r - self.core, 0) / self.a))
        return out

    def __call__(self, pts):
        """Warp an (n, 2) array of decimetre points."""
        p = np.asarray(pts, float).reshape(-1, 2)
        d = p - self.c
        r = np.hypot(d[:, 0], d[:, 1])
        k = np.ones_like(r)
        far = r > self.core
        k[far] = self.radius(r[far]) / r[far]
        return self.c + d * k[:, None]

    def dist(self, pts):
        p = np.asarray(pts, float).reshape(-1, 2)
        return np.hypot(p[:, 0] - self.c[0], p[:, 1] - self.c[1])


def densify(flat, step=STEP, closed=False):
    """A flat [x, y, ...] list with extra points so no segment is longer than step."""
    p = np.asarray(flat, float).reshape(-1, 2)
    if closed:
        p = np.vstack([p, p[:1]])
    out = [p[0]]
    for a, b in zip(p[:-1], p[1:]):
        n = int(math.ceil(np.hypot(*(b - a)) / step))
        for k in range(1, n + 1):
            out.append(a + (b - a) * (k / n))
    out = np.asarray(out)
    return out[:-1] if closed else out


def _flat(pts):
    out = []
    for x, y in pts:
        q = [int(round(x)), int(round(y))]
        if len(out) < 2 or out[-2:] != q:
            out += q
    return out


def warp_line(flat, w):
    return w(densify(flat))


def warp_rings(rings, w):
    out = []
    for r in rings:
        pts = w(densify(r, closed=True))
        f = _flat(pts)
        if len(f) >= 6:
            out.append(f)
    return out


def load_full(src: Path, w: Warp):
    """Everything in the full data within KEEP of the Dam (a little beyond, so lines run on)."""
    index = json.loads((src / "index.json").read_text())
    tile = float(index["tile"]) * 10
    reach = KEEP + 3000
    cx, cy = w.c
    items = {k: [] for k in ("buildings", "roads", "bridges", "places", "waterLabels") + POINT_KEYS + POLY_KEYS}
    for f in sorted((src / "tiles").glob("*.json")):
        i, j = (int(v) for v in f.stem.split("_"))
        bx = box(i * tile, j * tile, (i + 1) * tile, (j + 1) * tile)
        if bx.distance(Point(cx, cy)) > reach:
            continue
        t = json.loads(f.read_text())
        for c in t["chunks"].values():
            for k in items:
                items[k].extend(c.get(k, []))
    return index, items


def build(src: Path, dst: Path, seed: int = 7) -> dict:
    full = json.loads((src / "index.json").read_text())
    w = Warp(full["start"])
    index, it = load_full(src, w)
    island = Point(*w.c).buffer(ISLAND, 128)
    shore = Point(*w.c).buffer(ISLAND - 30, 128)                # streets end a few metres short of the water
    out = {k: [] for k in it}

    # Streets and bridges: densified, warped, cut at the shore.
    for rd in it["roads"]:
        if rd[0] == "walk":                 # footpaths only where the city keeps its scale
            mid = np.asarray(rd[2], float).reshape(-1, 2).mean(axis=0)
            if w.slope(float(w.dist(mid)[0])) < PATHS_BELOW:
                continue
        line = LineString(warp_line(rd[2], w))
        for piece in _lines(line.intersection(shore)):
            f = _flat(piece.coords)
            if len(f) >= 4:
                out["roads"].append([rd[0], rd[1], f, rd[3]])
    for br in it["bridges"]:
        line = LineString(warp_line(br, w))
        for piece in _lines(line.intersection(shore)):
            f = _flat(piece.coords)
            if len(f) >= 4:
                out["bridges"].append(f)
    # Canals, parks, squares: the same, cut at the island's edge.
    for k in POLY_KEYS:
        for item in it[k]:
            rings = warp_rings(item["r"], w)
            if not rings:
                continue
            for piece in _polys(_shape(rings).intersection(island)):
                if piece.area < 1.0:
                    continue
                rec = {"r": _rings(piece)}
                if "c" in item:
                    rec["c"] = item["c"]
                if rec["r"]:
                    out[k].append(rec)
    # The sea round the island.
    sea = box(w.c[0] - SEA, w.c[1] - SEA, w.c[0] + SEA, w.c[1] + SEA).difference(island)
    for piece in _polys(sea):
        out["water"].append({"r": _rings(piece)})

    # Buildings: whole, moved with their centre, kept where they fit.
    water_u = unary_union([_shape(x["r"]) for x in out["water"]]).buffer(0)
    road_u = unary_union([LineString(np.asarray(r[2], float).reshape(-1, 2)).buffer(max(float(r[1]), 1.0) * 5.0, 4)
                          for r in out["roads"] if r[0] in ("road", "tram", "bike")])
    blocked = water_u.union(road_u)
    from shapely import STRtree, prepared
    blk = prepared.prep(blocked)
    water_p = prepared.prep(water_u)
    cell = 600.0
    grid: dict = {}
    rng = random.Random(seed)

    def near(poly):
        x0, y0, x1, y1 = poly.bounds
        for a in range(int(math.floor(x0 / cell)), int(math.floor(x1 / cell)) + 1):
            for b in range(int(math.floor(y0 / cell)), int(math.floor(y1 / cell)) + 1):
                yield from grid.get((a, b), [])

    def add(poly):
        x0, y0, x1, y1 = poly.bounds
        for a in range(int(math.floor(x0 / cell)), int(math.floor(x1 / cell)) + 1):
            for b in range(int(math.floor(y0 / cell)), int(math.floor(y1 / cell)) + 1):
                grid.setdefault((a, b), []).append(poly)

    rows = []
    for bd in it["buildings"]:
        rings = bd["r"] if "r" in bd else [bd["g"]]
        ring = np.asarray(rings[0], float).reshape(-1, 2)
        c = ring.mean(axis=0)
        r = float(w.dist(c)[0])
        if r > KEEP:
            continue
        rows.append((r, c, bd, rings))
    rows.sort(key=lambda x: x[0])
    kept = dropped = 0
    for r, c, bd, rings in rows:
        shift = w(c)[0] - c
        poly = _shape([[v + (shift[k % 2]) for k, v in enumerate(rr)] for rr in rings])
        if poly.is_empty or not island.contains(poly.centroid):
            dropped += 1
            continue
        if r > CORE:
            core_poly = poly.buffer(-4.0)                     # (40 cm of slack where walls meet)
            if core_poly.is_empty or blk.intersects(core_poly) or any(core_poly.intersects(o) for o in near(core_poly)):
                dropped += 1
                continue
        nb = dict(bd)
        if "r" in bd:
            nb["r"] = [[int(round(v + shift[k % 2])) for k, v in enumerate(rr)] for rr in rings]
        else:
            nb["g"] = [int(round(v + shift[k % 2])) for k, v in enumerate(bd["g"])]
        out["buildings"].append(nb)
        add(poly)
        kept += 1

    # Points: warped; not inside a building now, nor in the water.
    def free(x, y):
        p = Point(x, y)
        if not island.contains(p) or water_p.contains(p):
            return False
        return not any(o.contains(p) for o in near(p.buffer(1)))

    for k in POINT_KEYS:
        flat = it[k]
        pts = np.asarray(flat, float).reshape(-1, 2) if flat else np.zeros((0, 2))
        keep = w.dist(pts) <= KEEP
        for x, y in w(pts[keep]) if keep.any() else []:
            if free(x, y):
                out[k] += [int(round(x)), int(round(y))]
    for pl in it["places"]:
        if w.dist([pl[2], pl[3]])[0] <= KEEP:
            (x, y), = w([pl[2], pl[3]])
            out["places"].append([pl[0], pl[1], int(round(x)), int(round(y))] + list(pl[4:]))
    for lab in it["waterLabels"]:
        if w.dist([lab[1], lab[2]])[0] <= KEEP:
            (x, y), = w([lab[1], lab[2]])
            out["waterLabels"].append([lab[0], int(round(x)), int(round(y))] + list(lab[3:]))

    # Petrol stations: those within reach warped in; more from further out
    # brought to the island's outer belt along their own bearing.
    stations = []
    for st in full.get("stations", []):
        p = np.asarray([st[1], st[2]], float)
        r = float(w.dist(p)[0])
        if r <= KEEP:
            (x, y), = w(p)
        else:
            d = (p - w.c) / r
            rr = ISLAND * rng.uniform(0.80, 0.93)
            x, y = w.c + d * rr
        if any(math.hypot(x - s[1], y - s[2]) < 1500 for s in stations):    # 150 m apart at least
            continue
        stations.append([st[0], int(round(x)), int(round(y)), r])
    stations.sort(key=lambda s: s[3])
    stations = [s[:3] for s in stations[:STATIONS]]

    # Tiles: everything in each 1500 m tile it touches (lines and areas in all
    # of them: the chunker clips), then chunked.
    if dst.exists():
        shutil.rmtree(dst)
    (dst / "tiles").mkdir(parents=True)
    x0, y0, x1, y1 = w.c[0] - SEA, w.c[1] - SEA, w.c[0] + SEA, w.c[1] + SEA
    tiles = {}
    for i in range(int(math.floor(x0 / TILE)), int(math.floor((x1 - 1) / TILE)) + 1):
        for j in range(int(math.floor(y0 / TILE)), int(math.floor((y1 - 1) / TILE)) + 1):
            tiles[(i, j)] = {"tile": [i, j]}

    def at(x, y):
        return (int(math.floor(x / TILE)), int(math.floor(y / TILE)))

    def over(xs, ys):
        for i in range(int(math.floor(min(xs) / TILE)), int(math.floor(max(xs) / TILE)) + 1):
            for j in range(int(math.floor(min(ys) / TILE)), int(math.floor(max(ys) / TILE)) + 1):
                if (i, j) in tiles:
                    yield tiles[(i, j)]

    put = lambda t, k, v: t.setdefault(k, []).append(v)
    for bd in out["buildings"]:
        ring = np.asarray(bd["r"][0] if "r" in bd else bd["g"], float).reshape(-1, 2)
        t = tiles.get(at(*ring.mean(axis=0)))
        if t is not None:
            put(t, "buildings", bd)
    for k in POINT_KEYS:
        f = out[k]
        for n in range(0, len(f) - 1, 2):
            t = tiles.get(at(f[n], f[n + 1]))
            if t is not None:
                t.setdefault(k, []).extend(f[n:n + 2])
    for pl in out["places"]:
        t = tiles.get(at(pl[2], pl[3]))
        if t is not None:
            put(t, "places", pl)
    for lab in out["waterLabels"]:
        t = tiles.get(at(lab[1], lab[2]))
        if t is not None:
            put(t, "waterLabels", lab)
    for rd in out["roads"]:
        for t in over(rd[2][0::2], rd[2][1::2]):
            put(t, "roads", rd)
    for br in out["bridges"]:
        for t in over(br[0::2], br[1::2]):
            put(t, "bridges", br)
    for k in POLY_KEYS:
        for item in out[k]:
            r0 = item["r"][0]
            for t in over(r0[0::2], r0[1::2]):
                put(t, k, item)
    rows = []
    for (i, j), t in tiles.items():
        n = len(t.get("buildings", []))
        (dst / "tiles" / ("%d_%d.json" % (i, j))).write_text(json.dumps(chunk_tile(t, TILE, 3750.0), separators=(",", ":"),
                                                                          ensure_ascii=False))
        rows.append([i, j, 0, n])
    new = {
        "origin": full["origin"], "tile": full["tile"], "tiles": sorted(rows),
        "bounds": [x1, y0, x1, y1, x0, y1, x0, y0], "start": full["start"],
        "stations": stations, "compact": {"core": CORE, "keep": KEEP, "island": ISLAND, "a": w.a, "centre": list(w.c)},
    }
    (dst / "index.json").write_text(json.dumps(new, separators=(",", ":")))
    nchunks = chunk_data(dst)
    render_overview(dst / "overview.jpg", out, (x0, y0, x1, y1))
    return {"kept": kept, "dropped": dropped, "roads": len(out["roads"]), "chunks": nchunks, "stations": len(stations),
            "tiles": len(tiles)}


def render_overview(path, out, bounds, width=2048):
    """The island as one map image under the 3D tiles (as prepare_city_tiles.render_overview)."""
    from PIL import Image, ImageDraw
    x0, y0, x1, y1 = bounds
    s = width / (x1 - x0)
    img = Image.new("RGB", (width, round((y1 - y0) * s)), (178, 172, 160))
    d = ImageDraw.Draw(img)
    P = lambda f: [((f[k] - x0) * s, (y1 - f[k + 1]) * s) for k in range(0, len(f) - 1, 2)]
    for g in out["green"]:
        d.polygon(P(g["r"][0]), fill=(110, 148, 86))
    for g in sorted(out["water"], key=lambda g: -len(g["r"])):      # (the sea, with the island as its hole, first)
        d.polygon(P(g["r"][0]), fill=(52, 88, 96))
        for h in g["r"][1:]:
            d.polygon(P(h), fill=(178, 172, 160))
    col = {"road": (70, 73, 75), "walk": (196, 188, 172), "bike": (156, 70, 56), "tram": (95, 98, 102), "rail": (85, 80, 74)}
    order = ["walk", "bike", "road", "tram", "rail"]
    for rd in sorted(out["roads"], key=lambda r: order.index(r[0]) if r[0] in order else 0):
        d.line(P(rd[2]), fill=col.get(rd[0], (70, 73, 75)), width=max(1, round(float(rd[1]) * 10 * s * 1.4)))
    shade = {0: (196, 170, 150), 1: (176, 112, 88), 2: (168, 96, 80), 3: (170, 176, 182), 4: (160, 156, 150), 5: (70, 100, 84)}
    for bd in out["buildings"]:
        f = bd["r"][0] if "r" in bd else bd["g"]
        d.polygon(P(f), fill=shade.get(bd.get("k", 0), (190, 160, 140)), outline=(120, 90, 76))
    img.save(path, "JPEG", quality=84, optimize=True, progressive=True)


if __name__ == "__main__":
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "godot-city/data")
    dst = Path(sys.argv[2] if len(sys.argv) > 2 else "godot-city/data-compact")
    print(build(src, dst))
