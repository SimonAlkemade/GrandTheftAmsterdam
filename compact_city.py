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
        out[k] = [item for item in out[k] if item.get("r") and len(item["r"][0]) >= 6]
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




# ================================================================================================
# Layout v2: the whole city inside the A10, and the Arena, at 0.45 of its size (the map brief)
# ================================================================================================
#
# Where layout v1 keeps the centre 1:1 and squeezes the rest, v2 shrinks the whole
# city alike, as a game map would: every position is brought 0.45 of the way to
# the Dam (a similarity: the shape, the orientation, the districts' places all
# kept), but nothing gets narrower than a game needs: streets keep their real
# widths (car streets at least 6 m), canals are widened back after shrinking,
# buildings keep 0.7 of their footprint around their own centres. So it is a
# simplified city:
#   * fewer canals: the named ones a player knows (the canal ring, the Amstel,
#     the IJ, the docks...) and every large water, the rest filled in;
#   * fewer streets: no footpaths, short stubs or narrow side streets outside
#     the centre, dead ends pruned;
#   * fewer houses, the real ones: up to TARGET buildings, the landmarks first,
#     then the centre outwards, each kept where it is clear of streets, water
#     and the buildings already kept;
#   * a green margin round it, and you are held at its edge.

S = 0.45                 # positions: 0.45 of their distance from the Dam
NUDGE = 60.0             # dm: how far a house may step back off a quay street
FOOT = 0.45              # building footprints: 0.45 of their size (as their streets are)
TARGET = 50000           # buildings, at most
NORTH_CUT = 45000.0      # dm: Noord kept up to 4.5 km north of the origin (its waterfront, NDSM, A'DAM)
ARENA = (31200.0, -67300.0)
PULL_Y = -40000.0         # dm: south of this (the corridor to Zuidoost), distances north-south halved again
PULL = 0.5
MARGIN = 1500.0          # dm of green round the city (scaled metres x 10)
EDGE_OUT = 1200.0        # dm: you are held this far out into it
CANAL_WIDEN = 30.0       # dm each side: canals shrunk to 0.45 are widened back by 3 m a side
MIN_ROAD = 6.0           # m: car streets at least this wide
QUAY = 6.0               # m: and quay streets beside a canal at most
WIDE = 250.0             # dm: water more than 2 x 25 m across is wide water, always kept (the IJ, the Amstel, harbours)
KEEP_CANALS = {
    "Singel", "Herengracht", "Keizersgracht", "Prinsengracht", "Singelgracht", "Brouwersgracht", "Amstel",
    "IJ", "Oosterdok", "Westerdok", "Nieuwe Herengracht", "Nieuwe Keizersgracht", "Nieuwe Prinsengracht",
    "Lijnbaansgracht", "Damrak", "Rokin", "Oudeschans", "Geldersekade", "Kloveniersburgwal", "Reguliersgracht",
    "Leidsegracht", "Amstelkanaal", "Boerenwetering", "Kostverlorenvaart", "Schinkel", "Nieuwe Vaart",
    "Entrepotdok", "Westerkanaal", "Oostelijke Handelskade", "Noordhollandsch Kanaal",
    "Bloemgracht", "Egelantiersgracht", "Lauriergracht", "Oudezijds Voorburgwal", "Oudezijds Achterburgwal",
    "Spiegelgracht", "Looiersgracht",
}
# Landmarks (decimetres from the city origin, checked against the places in the data).
LANDMARKS = {
    "Amsterdam Centraal": (3254, 4407), "Dam / Royal Palace": (-2411, -1344), "Westerkerk": (-7713, 268),
    "Anne Frank House": (-7693, 887), "Rijksmuseum": (-6918, -15910), "Van Gogh Museum": (-9796, -17712),
    "Museumplein": (-9161, -19000), "Vondelpark": (-18715, -19326), "Artis": (11782, -8027),
    "NEMO": (11576, -313), "A'DAM Tower": (4875, 10533), "Magere Brug": (4763, -11996),
    "Rembrandtplein": (926, -9575), "Leidseplein": (-9121, -11591), "Oosterpark": (17306, -16393),
    "Johan Cruijff ArenA": (31200, -67300),
}


def _a10(items) -> Polygon:
    """The ring road's outline (from Ringweg-Noord/-Oost/-Zuid/-West in the data)."""
    from shapely import concave_hull
    from shapely.geometry import MultiPoint
    pts = []
    for rd in items["roads"]:
        if rd[3] in ("Ringweg-Noord", "Ringweg-Oost", "Ringweg-Zuid", "Ringweg-West"):
            pts.extend(np.asarray(rd[2], float).reshape(-1, 2).tolist())
    return concave_hull(MultiPoint(pts), ratio=0.35).buffer(0)


def region_of(items, dam) -> Polygon:
    """What v2 keeps (in the real city's coordinates): inside the A10 up to NORTH_CUT, and the
    Arena with a corridor to it along the A2 and the Amstel."""
    ring = _a10(items)
    x0, y0, x1, y1 = ring.bounds
    ring = ring.intersection(box(x0 - 1, y0 - 1, x1 + 1, NORTH_CUT))
    corridor = LineString([(18000.0, -38000.0), ARENA]).buffer(9000.0)
    arena = Point(*ARENA).buffer(10000.0)
    return unary_union([ring, corridor, arena]).buffer(500).buffer(-500)


def _load(src: Path, area):
    index = json.loads((src / "index.json").read_text())
    tile = float(index["tile"]) * 10
    items = {k: [] for k in ("buildings", "roads", "bridges", "places", "waterLabels") + POINT_KEYS + POLY_KEYS}
    for f in sorted((src / "tiles").glob("*.json")):
        i, j = (int(v) for v in f.stem.split("_"))
        if not box(i * tile, j * tile, (i + 1) * tile, (j + 1) * tile).intersects(area):
            continue
        t = json.loads(f.read_text())
        for c in t["chunks"].values():
            for k in items:
                items[k].extend(c.get(k, []))
    return index, items


def _len(flat) -> float:
    p = np.asarray(flat, float).reshape(-1, 2)
    return float(np.hypot(*np.diff(p, axis=0).T).sum()) if len(p) > 1 else 0.0


def build_v2(src: Path, dst: Path, seed: int = 7, target: int = TARGET) -> dict:
    from shapely import STRtree, prepared
    full = json.loads((src / "index.json").read_text())
    dam = np.asarray(full["start"], float)
    def T(pts):
        p = np.asarray(pts, float).reshape(-1, 2).copy()
        south = p[:, 1] < PULL_Y                       # (the road to the Arena: half as long again)
        p[south, 1] = PULL_Y + (p[south, 1] - PULL_Y) * PULL
        return dam + (p - dam) * S
    rng = random.Random(seed)
    # Everything near the A10 and the Arena first (a generous box), then the exact region.
    _, everything = _load(src, box(-60000, -80000, 70000, 70000))
    region = region_of(everything, dam)
    reg_p = prepared.prep(region)
    region_s = Polygon(T(np.asarray(region.exterior.coords)))
    world = region_s.buffer(MARGIN)
    out = {k: [] for k in everything}
    stats = {}

    # ---- water: all the wide water (the IJ, the Amstel, harbours, lakes); of the canals, the named ones ----
    # (The data's water arrives cut at tile edges, so it is merged first and judged as a whole.)
    all_w = unary_union([_shape(i["r"]) for i in everything["water"]]).buffer(2).buffer(-2)
    wide = all_w.buffer(-WIDE, 6).buffer(WIDE + 20, 6).intersection(all_w)
    named = [(LineString(np.asarray(r[2], float).reshape(-1, 2)), r[3]) for r in everything["roads"]
             if r[3] and len(r[2]) >= 4]
    tree = STRtree([g for g, _ in named])
    narrow_kept = []
    total = kept_a = 0.0
    for piece in _polys(all_w.difference(wide).intersection(region)):
        if piece.area < 50.0:
            continue
        total += piece.area
        names = set()
        for k in tree.query(piece.buffer(150.0)):
            g, nm = named[k]
            if g.distance(piece) < 150.0:
                names.add(nm)
        if any(nm in KEEP_CANALS or nm.startswith("Amstel") for nm in names) or piece.area < 2000.0 and piece.distance(wide) < 1:
            narrow_kept.append(piece)
            kept_a += piece.area
    stats["canals_filled"] = round(1.0 - kept_a / max(total, 1.0), 3)     # (share of the canals' water)
    water_real = unary_union([wide.intersection(region.buffer(MARGIN / S))] + narrow_kept).buffer(0)

    def scaled(g):
        return Polygon(T(np.asarray(g.exterior.coords)), [T(np.asarray(h.coords)) for h in g.interiors]).buffer(0)
    wide_s = unary_union([scaled(g) for g in _polys(wide) if g.intersects(region.buffer(MARGIN / S))])
    canals_raw = unary_union([scaled(g) for g in narrow_kept]).buffer(0)

    # ---- streets ----
    core_r = 16000.0
    kept_roads = []
    for rd in everything["roads"]:
        kind, w, flat, name = rd
        if kind == "walk":
            continue
        L = _len(flat)
        p = np.asarray(flat, float).reshape(-1, 2)
        mid = p.mean(axis=0)
        central = float(np.hypot(*(mid - dam))) < core_r
        if kind == "bike" and L < 3000:
            continue
        if kind == "road" and float(w) < 5 and not central and L < 1000:
            continue
        line = LineString(p)
        if not reg_p.intersects(line):
            continue
        for piece in _lines(line.intersection(region)):
            f = _flat(T(np.asarray(piece.coords)))
            if len(f) >= 4:
                ww = max(float(w), MIN_ROAD) if kind == "road" else float(w)
                kept_roads.append([kind, ww, f, name])
    # Prune dead ends, a few rounds: a street piece hanging by one end, shorter than 25 m.
    def key(x, y):
        return (int(round(x / 5.0)), int(round(y / 5.0)))
    for _ in range(4):
        deg = {}
        for rd in kept_roads:
            for x, y in ((rd[2][0], rd[2][1]), (rd[2][-2], rd[2][-1])):
                deg[key(x, y)] = deg.get(key(x, y), 0) + 1
        before = len(kept_roads)
        kept_roads = [rd for rd in kept_roads if not (rd[0] == "road" and _len(rd[2]) < 250.0 and
                      (deg[key(rd[2][0], rd[2][1])] == 1 or deg[key(rd[2][-2], rd[2][-1])] == 1))]
        if len(kept_roads) == before:
            break
    out["roads"] = kept_roads
    stats["roads"] = len(kept_roads)

    # The canals, widened back (boats fit) where no quay street runs beside them: a street
    # crossing a canal (on its bridge) does not stop it, one running along its quay does.
    from shapely import prepared as _pp
    raw_p = _pp.prep(canals_raw)
    # A quay street is 6 m at most (the canal beside it is the room it gives up), and the water
    # stops at its kerb.
    near = _pp.prep(canals_raw.buffer(150.0))
    quays = []
    for r in kept_roads:
        line = LineString(np.asarray(r[2], float).reshape(-1, 2))
        if r[0] not in ("road", "tram", "bike") or raw_p.intersects(line) or not near.intersects(line):
            continue
        if r[0] == "road":
            r[1] = min(float(r[1]), QUAY)
        quays.append(line.buffer(float(r[1]) * 5.0, 4))
    quay_u = unary_union(quays)
    canals_s = canals_raw.buffer(CANAL_WIDEN, 8).difference(quay_u)
    water_s = unary_union([wide_s, canals_s]).intersection(world).buffer(0)
    land_in = region_s.buffer(-50.0)                     # (water out in the margin only where it runs on from the city: the IJ)
    water_s = unary_union([g for g in _polys(water_s) if g.intersects(land_in)]).buffer(0)
    for piece in _polys(water_s):
        if piece.area > 10.0:
            out["water"].append({"r": _rings(piece)})
    water_p = prepared.prep(water_s)


    # ---- bridges: where a kept street crosses kept water ----
    for br in everything["bridges"]:
        line = LineString(np.asarray(br, float).reshape(-1, 2))
        if line.length == 0 or not reg_p.intersects(line) or not water_real.intersects(line):
            continue
        p = T(np.asarray(line.coords))
        a, b = p[0], p[-1]
        d = (b - a) / max(np.hypot(*(b - a)), 1e-6)
        p[0] = a - d * (CANAL_WIDEN + 15.0)           # (as long as the widened canal is wide)
        p[-1] = b + d * (CANAL_WIDEN + 15.0)
        if water_p.intersects(LineString(p)):            # (still over water once the city is shrunk)
            out["bridges"].append(_flat(p))

    # ---- parks, squares; the green margin ----
    for k in ("green", "plazas"):
        for item in everything[k]:
            shape = _shape(item["r"])
            if shape.is_empty or not reg_p.intersects(shape):
                continue
            for g in _polys(shape.intersection(region)):
                sg = Polygon(T(np.asarray(g.exterior.coords)), [T(np.asarray(h.coords)) for h in g.interiors]).buffer(0)
                sg = sg.difference(water_s) if k == "green" else sg
                for piece in _polys(sg):
                    if piece.area > 20.0:
                        rec = {"r": _rings(piece)}
                        if "c" in item:
                            rec["c"] = item["c"]
                        out[k].append(rec)
    for piece in _polys(world.difference(region_s.buffer(-5.0)).difference(water_s)):
        out["green"].append({"r": _rings(piece), "c": "grass"})

    # ---- buildings ----
    # What a house may not stand on: each street (its centreline: the way out is away from it) and
    # each piece of water (away from its shore).
    from shapely.ops import nearest_points
    cores, parts = [], []
    for rd in out["roads"]:
        if rd[0] in ("road", "tram", "bike", "rail"):
            line = LineString(np.asarray(rd[2], float).reshape(-1, 2))
            cores.append(line)
            parts.append(line.buffer(float(rd[1]) * 5.0 + 3.0, 4))
    for g in _polys(water_s):
        cores.append(g)
        parts.append(g)
    blk_tree = STRtree(parts)

    def clash(g):
        return blk_tree.query(g, predicate="intersects")

    def away(at, hits):
        """Which way out from what `at` stands on (a unit vector, or None)."""
        v = np.zeros(2)
        p = Point(*at)
        for h in hits:
            core = cores[h]
            if core.geom_type == "Polygon":
                q = nearest_points(core.exterior, p)[0]
                d = np.asarray([q.x - at[0], q.y - at[1]]) if core.contains(p) else np.asarray([at[0] - q.x, at[1] - q.y])
            else:
                q = nearest_points(core, p)[0]
                d = np.asarray([at[0] - q.x, at[1] - q.y])
            n = float(np.hypot(*d))
            if n > 1e-6:
                v += d / n
        n = float(np.hypot(*v))
        return v / n if n > 1e-6 else None
    lm_pts = {nm: Point(*xy) for nm, xy in LANDMARKS.items()}
    rows = []
    for bd in everything["buildings"]:
        rings = bd["r"] if "r" in bd else [bd["g"]]
        ring = np.asarray(rings[0], float).reshape(-1, 2)
        c = ring.mean(axis=0)
        if not reg_p.contains(Point(*c)):
            continue
        poly = _shape(rings)
        lm = next((nm for nm, pt in lm_pts.items() if poly.buffer(80).contains(pt)), None)
        r = float(np.hypot(*(c - dam)))
        rows.append((0 if lm else 1, r, c, bd, rings, lm))
    rows.sort(key=lambda x: (x[0], x[1]))
    cell = 400.0
    grid = {}

    def cells(b):
        x0, y0, x1, y1 = b
        for a in range(int(math.floor(x0 / cell)), int(math.floor(x1 / cell)) + 1):
            for bb in range(int(math.floor(y0 / cell)), int(math.floor(y1 / cell)) + 1):
                yield (a, bb)

    landmarks_kept = {}
    radii = []
    kept = dropped = 0
    for prio, r, c, bd, rings, lm in rows:
        cs = T(c)[0]
        new_rings = []
        for rr in rings:
            p = np.asarray(rr, float).reshape(-1, 2)
            new_rings.append(_flat(cs + (p - c) * FOOT))
        if len(new_rings[0]) < 6:
            dropped += 1
            continue
        poly = _shape(new_rings)
        if poly.is_empty:
            dropped += 1
            continue
        test = poly.buffer(-3.0)
        if not lm:
            if test.is_empty:
                dropped += 1
                continue
            # On a street or in a canal (the quays come in as the city shrinks): stepped back
            # from it, up to NUDGE, before it is given up.
            hits = clash(test)
            step = 0.0
            while len(hits) and step < NUDGE:
                v = away(cs, hits)
                if v is None:
                    break
                step += NUDGE / 4.0
                dv = v * (NUDGE / 4.0)
                cs = cs + dv
                new_rings = [_flat(np.asarray(rr, float).reshape(-1, 2) + dv) for rr in new_rings]
                poly = _shape(new_rings)
                test = poly.buffer(-3.0)
                hits = clash(test)
            if len(hits) or any(test.intersects(o) for k in cells(test.bounds) for o in grid.get(k, [])):
                dropped += 1
                continue
        nb = dict(bd)
        nb.pop("t", None)
        if "r" in bd:
            nb["r"] = new_rings
            if len(new_rings) > 1:
                nb["t"] = _tris(new_rings)
        else:
            nb["g"] = new_rings[0]
        if lm:
            nb["lm"] = lm
            landmarks_kept[lm] = [int(round(cs[0])), int(round(cs[1]))]
        out["buildings"].append(nb)
        radii.append(-1.0 if lm else r)
        for k in cells(poly.bounds):
            grid.setdefault(k, []).append(poly)
        kept += 1
    # More fit than the city should have: thin out the houses beyond the centre, evenly, at random
    # (the centre and the landmarks all stay; the outer districts keep their streets' rhythm, less dense).
    if kept > target:
        outer = [n for n, rr in enumerate(radii) if rr >= core_r]
        gone = set(rng.sample(outer, min(len(outer), kept - target)))
        out["buildings"] = [bd for n, bd in enumerate(out["buildings"]) if n not in gone]
        grid = {}
        for bd in out["buildings"]:
            poly = _shape(bd["r"] if "r" in bd else [bd["g"]])
            for k in cells(poly.bounds):
                grid.setdefault(k, []).append(poly)
        dropped += len(gone)
        kept -= len(gone)
    stats.update(kept=kept, dropped=dropped)
    for nm, xy in LANDMARKS.items():                      # (squares and parks: where they are)
        landmarks_kept.setdefault(nm, [int(round(v)) for v in T(xy)[0]])

    # ---- the small things: a third of them (the city is a fifth the area) ----
    def clear(x, y):
        p = Point(x, y)
        if not region_s.contains(p) or water_p.contains(p):
            return False
        return not any(o.contains(p) for o in grid.get((int(math.floor(x / cell)), int(math.floor(y / cell))), []))
    for k in POINT_KEYS:
        f = everything[k]
        for n in range(0, len(f) - 1, 2):
            if rng.random() > 0.33 or not reg_p.contains(Point(f[n], f[n + 1])):
                continue
            (x, y), = T([f[n], f[n + 1]])
            if clear(x, y):
                out[k] += [int(round(x)), int(round(y))]
    for pl in everything["places"]:
        if reg_p.contains(Point(pl[2], pl[3])):
            (x, y), = T([pl[2], pl[3]])
            out["places"].append([pl[0], pl[1], int(round(x)), int(round(y))] + list(pl[4:]))
    for lab in everything["waterLabels"]:
        (x, y), = T([lab[1], lab[2]])
        if water_s.distance(Point(x, y)) < 300.0:        # (a label's point is on its water, or by it)
            out["waterLabels"].append([lab[0], int(round(x)), int(round(y))] + list(lab[3:]))

    # ---- petrol stations: those in the region; more along its edge from further out ----
    stations = []
    inner = region_s.buffer(-1200.0)
    for st in sorted(full.get("stations", []), key=lambda s: math.hypot(s[1] - dam[0], s[2] - dam[1])):
        if reg_p.contains(Point(st[1], st[2])):
            (x, y), = T([st[1], st[2]])
        else:
            d = np.asarray([st[1], st[2]], float) - dam
            d /= max(np.hypot(*d), 1e-6)
            hit = LineString([dam, dam + d * 1e6]).intersection(inner.exterior)
            if hit.is_empty:
                continue
            q = min(_points(hit), key=lambda q: math.hypot(q[0] - dam[0], q[1] - dam[1]))
            x, y = q
        if any(math.hypot(x - s[1], y - s[2]) < 2500 for s in stations):
            continue
        stations.append([st[0], int(round(x)), int(round(y))])
        if len(stations) >= STATIONS:
            break

    # ---- tiles, index, map ----
    x0, y0, x1, y1 = world.bounds
    meta = {"layout": "v2", "centre": [float(dam[0]), float(dam[1])], "scale": S,
            "edge": _flat(np.asarray(region_s.buffer(EDGE_OUT).simplify(50.0).exterior.coords)[:-1]),
            "landmarks": landmarks_kept, "canals_filled": stats["canals_filled"], "buildings": kept}
    out["_land"] = _rings(region_s)
    _write(dst, full, out, (x0, y0, x1, y1), stations, meta)
    render_map(out, (x0, y0, x1, y1), dst / "overview.jpg", size=2048)
    stats.update(chunks=len(json.loads((dst / "index.json").read_text())["chunks"]), stations=len(stations),
                 size_km=[round((x1 - x0) / 1e4, 2), round((y1 - y0) / 1e4, 2)])
    stats["_out"] = out
    stats["_bounds"] = (x0, y0, x1, y1)
    return stats


def _points(g):
    if g.geom_type == "Point":
        return [(g.x, g.y)]
    return [(p.x, p.y) for p in getattr(g, "geoms", []) if p.geom_type == "Point"]


def _tris(rings):
    from amsterdam.chunks import tris
    return tris(rings)


def _write(dst: Path, full: dict, out: dict, bounds, stations, meta) -> None:
    """Tile, chunk and index `out` (as build() does)."""
    if (dst / "tiles").exists():                         # (the rest stays: the editor's .import files)
        shutil.rmtree(dst / "tiles")
    (dst / "tiles").mkdir(parents=True)
    x0, y0, x1, y1 = bounds
    tiles = {}
    for i in range(int(math.floor(x0 / TILE)), int(math.floor((x1 - 1) / TILE)) + 1):
        for j in range(int(math.floor(y0 / TILE)), int(math.floor((y1 - 1) / TILE)) + 1):
            tiles[(i, j)] = {"tile": [i, j]}
    at = lambda x, y: (int(math.floor(x / TILE)), int(math.floor(y / TILE)))

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
        out[k] = [item for item in out[k] if item.get("r") and len(item["r"][0]) >= 6]
        for item in out[k]:
            r0 = item["r"][0]
            for t in over(r0[0::2], r0[1::2]):
                put(t, k, item)
    rows = []
    for (i, j), t in tiles.items():
        (dst / "tiles" / ("%d_%d.json" % (i, j))).write_text(
            json.dumps(chunk_tile(t, TILE, 3750.0), separators=(",", ":"), ensure_ascii=False))
        rows.append([i, j, 0, len(t.get("buildings", []))])
    new = {"origin": full["origin"], "tile": full["tile"], "tiles": sorted(rows),
           "bounds": [x1, y0, x1, y1, x0, y1, x0, y0], "start": full["start"], "stations": stations, "compact": meta}
    (dst / "index.json").write_text(json.dumps(new, separators=(",", ":")))
    chunk_data(dst)


# ---- the map, drawn: flat pastel vector (the brief) ----------------------------------------------

PALETTE = {
    "ground": "#ece3d2", "margin": "#dfe6cf", "water": "#9db9c6", "green": "#b5cfa4", "plaza": "#e4dccb",
    "road": "#cfcdc8", "road_edge": "#b9b5ad", "tram": "#c4c1bb", "rail": "#aaa49b", "bike": "#d6c9bd",
    "bridge": "#d9d6cf", "outline": "#9a7a63",
    "buildings": ["#d9a283", "#cf8f6e", "#e0b896", "#c98468", "#e6c8a6", "#d3a98a"],
    "industrial": "#c2bcb2", "landmark": "#c07355",
}


def render_map(out: dict, bounds, path: Path, size: int = 8192, svg: Path | None = None) -> None:
    """The city as a flat 2D map, north up, no labels: an SVG (vector), and a raster at `size` px
    (the overview the game drapes under its tiles, or the big map)."""
    x0, y0, x1, y1 = bounds
    W, H = x1 - x0, y1 - y0
    pal = PALETTE

    def pts(f):
        return " ".join("%.1f,%.1f" % (f[k] - x0, y1 - f[k + 1]) for k in range(0, len(f) - 1, 2))

    def poly_path(rings):
        return " ".join("M" + pts(r).replace(" ", " L") + "Z" for r in rings)
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" shape-rendering="geometricPrecision">'
             % (W, H, size, int(round(size * H / W)))]
    parts.append('<rect width="%d" height="%d" fill="%s"/>' % (W, H, pal["margin"]))
    if out.get("_land"):
        parts.append('<path fill="%s" fill-rule="evenodd" d="%s"/>' % (pal["ground"], poly_path(out["_land"])))
    parts.append('<g fill="%s">' % pal["green"])
    for g in out["green"]:
        if g.get("c") == "grass" and out.get("_land"):
            continue                                   # (the margin: the background already)
        parts.append('<path fill-rule="evenodd" d="%s"/>' % poly_path(g["r"]))
    parts.append('</g><g fill="%s">' % pal["plaza"])
    for g in out["plazas"]:
        parts.append('<path fill-rule="evenodd" d="%s"/>' % poly_path(g["r"]))
    parts.append('</g><g fill="%s">' % pal["water"])
    for g in out["water"]:
        parts.append('<path fill-rule="evenodd" d="%s"/>' % poly_path(g["r"]))
    parts.append('</g>')
    order = {"bike": 0, "rail": 1, "road": 2, "tram": 3}
    style = {"road": pal["road"], "tram": pal["road"], "bike": pal["bike"], "rail": pal["rail"]}
    parts.append('<g fill="none" stroke-linecap="round" stroke-linejoin="round">')
    for edge in (True, False):
        for rd in sorted(out["roads"], key=lambda r: order.get(r[0], 2)):
            w = float(rd[1]) * 10.0
            if edge and rd[0] != "road":
                continue
            col = pal["road_edge"] if edge else style.get(rd[0], pal["road"])
            parts.append('<polyline points="%s" stroke="%s" stroke-width="%.1f"/>' % (pts(rd[2]), col, w + (8 if edge else 0)))
    for br in out["bridges"]:
        parts.append('<polyline points="%s" stroke="%s" stroke-width="70" stroke-linecap="butt"/>' % (pts(br), pal["bridge"]))
    parts.append('</g><g stroke="%s" stroke-width="2.5" stroke-linejoin="round">' % pal["outline"])
    rng = random.Random(3)
    for bd in out["buildings"]:
        if bd.get("lm"):
            col = pal["landmark"]
        elif bd.get("k") in (3, 4):
            col = pal["industrial"]
        else:
            col = pal["buildings"][rng.randrange(len(pal["buildings"]))]
        parts.append('<path fill="%s" fill-rule="evenodd" d="%s"/>' % (col, poly_path(bd["r"] if "r" in bd else [bd["g"]])))
    parts.append('</g></svg>')
    text = "\n".join(parts)
    if svg is not None:
        svg.write_text(text)
    _svg_to_raster(text, path, size, int(round(size * H / W)))


def _svg_to_raster(text: str, path: Path, w: int, h: int, tile: int = 2048) -> None:
    """Rasterise with the browser (Playwright's Chromium, through Node): smooth edges, exact
    geometry. In tiles of `tile` px (the viewBox moved over the map), as a browser will not
    draw one 8192 px page, and stitched."""
    import os
    import subprocess
    import tempfile
    from PIL import Image
    js = """const { chromium } = require('playwright');
(async () => {
  const [svg, dir, W, H, T] = process.argv.slice(2).map((v, i) => i < 2 ? v : +v);
  const b = await chromium.launch();
  const page = await b.newPage({ viewport: { width: T, height: T } });
  await page.goto('file://' + svg);
  const vb = await page.evaluate(() => document.documentElement.getAttribute('viewBox').split(' ').map(Number));
  const k = vb[2] / W;                                    // map units a pixel
  for (let y = 0; y < H; y += T) for (let x = 0; x < W; x += T) {
    await page.evaluate(([x, y, T, k]) => {
      const s = document.documentElement;
      s.setAttribute('width', T); s.setAttribute('height', T);
      s.setAttribute('viewBox', [x * k, y * k, T * k, T * k].join(' '));
    }, [x, y, T, k]);
    await page.screenshot({ path: dir + '/' + x + '_' + y + '.png' });
  }
  await b.close();
})();"""
    with tempfile.TemporaryDirectory() as d:
        svg, script = Path(d) / "map.svg", Path(d) / "raster.js"
        svg.write_text(text)
        script.write_text(js)
        root = subprocess.run(["npm", "root", "-g"], capture_output=True, text=True).stdout.strip()
        subprocess.run(["node", str(script), str(svg), d, str(w), str(h), str(tile)], check=True,
                       env=dict(os.environ, NODE_PATH=root))
        im = Image.new("RGB", (w, h))
        for y in range(0, h, tile):
            for x in range(0, w, tile):
                im.paste(Image.open(Path(d) / ("%d_%d.png" % (x, y))).convert("RGB"), (x, y))
        if str(path).endswith(".jpg"):
            im.save(path, "JPEG", quality=86, optimize=True, progressive=True)
        else:
            im.save(path, optimize=True)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    layout = next((a.split("=", 1)[1] for a in sys.argv[1:] if a.startswith("--layout=")), "v2")
    src = Path(args[0] if args else "godot-city/data")
    dst = Path(args[1] if len(args) > 1 else "godot-city/data-compact")
    if layout == "v1":
        print(build(src, dst))
    else:
        st = build_v2(src, dst)
        out, bounds = st.pop("_out"), st.pop("_bounds")
        print(st)
        mapdir = Path("map")
        mapdir.mkdir(exist_ok=True)
        render_map(out, bounds, mapdir / "amsterdam_game_map.png", size=8192, svg=mapdir / "amsterdam_game_map.svg")
        from PIL import Image
        Image.MAX_IMAGE_PIXELS = None
        im = Image.open(mapdir / "amsterdam_game_map.png")
        im.resize((4096, round(4096 * im.size[1] / im.size[0])), Image.LANCZOS).save(
            mapdir / "amsterdam_game_map_4096.png", optimize=True)
        print("map: map/amsterdam_game_map.svg, .png (8192 px, not committed) and _4096.png")
