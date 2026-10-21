"""Cut the whole-city Overture layers into 1.5 km tiles for the streaming map.

    python prepare_city_tiles.py data/city out/city

Writes out/city/index.json (origin, tile size, which tiles exist),
out/city/search.json (every named place, street and canal, for search) and
out/city/tiles/<i>_<j>.json, each in the same shape the centrum map used:
coordinates are integer decimetres from ORIGIN (RD New, x east, y north).
"""
import json
import math
import pickle
import sys
import zlib
from collections import defaultdict
from pathlib import Path

import numpy as np
from shapely import wkb
from shapely.geometry import Polygon, box
from shapely.geometry.polygon import orient

from amsterdam.overture import to_rd, wgs84_to_rd_np

TILE = 1500.0
FLOOR_H = 3.1
SRC, OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "data/city"), Path(sys.argv[2] if len(sys.argv) > 2 else "out/city")
BBOX = (4.728, 52.278, 5.080, 52.432)
_x, _y = wgs84_to_rd_np(np.array([BBOX[0], BBOX[2]]), np.array([BBOX[1], BBOX[3]]))
AREA = box(float(_x[0]), float(_y[0]), float(_x[1]), float(_y[1]))
# Origin on the Dam, rounded, so tile (0, 0) starts there.
_dx, _dy = wgs84_to_rd_np(np.array([4.8926]), np.array([52.3731]))
ORIGIN = (round(float(_dx[0]) / TILE) * TILE, round(float(_dy[0]) / TILE) * TILE)

tiles = defaultdict(lambda: defaultdict(list))
# Flat geometry for the whole-city overview image, in RD metres.
OV = {"buildings": [], "water": [], "green": [], "roads": []}


def tile_of(x, y):
    return (math.floor((x - ORIGIN[0]) / TILE), math.floor((y - ORIGIN[1]) / TILE))


def tile_box(i, j):
    return box(ORIGIN[0] + i * TILE, ORIGIN[1] + j * TILE, ORIGIN[0] + (i + 1) * TILE, ORIGIN[1] + (j + 1) * TILE)


def tiles_over(g):
    x0, y0, x1, y1 = g.bounds
    i0, j0 = tile_of(x0, y0)
    i1, j1 = tile_of(x1, y1)
    for i in range(i0, i1 + 1):
        for j in range(j0, j1 + 1):
            yield i, j


def dm(coords):
    out = []
    for x, y in coords:
        out += [round((x - ORIGIN[0]) * 10), round((y - ORIGIN[1]) * 10)]
    return out


def ring(c):
    c = list(c)
    if len(c) > 1 and c[0] == c[-1]:
        c = c[:-1]
    return dm(c)


def load(name):
    with open(SRC / f"{name}.pkl", "rb") as f:
        return pickle.load(f)


def name_of(row):
    n = row.get("names")
    return n.get("primary") if isinstance(n, dict) else None


def rnd(key):
    return (zlib.crc32(key.encode()) % 10000) / 10000.0


def polys(g):
    if g.geom_type == "Polygon":
        return [g]
    if hasattr(g, "geoms"):
        return [p for p in g.geoms if p.geom_type == "Polygon"]
    return []


def lines(g):
    if g.geom_type == "LineString":
        return [g]
    if hasattr(g, "geoms"):
        return [p for p in g.geoms if p.geom_type == "LineString"]
    return []


KINDS = {"apartments": 1, "house": 1, "residential": 1, "detached": 1, "terrace": 1, "retail": 2, "hotel": 2,
         "commercial": 3, "office": 3, "industrial": 4, "warehouse": 4, "houseboat": 5}


def do_buildings():
    n = 0
    for r in load("buildings"):
        if r.get("is_underground"):
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        c = g.centroid
        if not AREA.contains(c):
            continue
        key = str(r["id"])
        h = r.get("height")
        if h is None or not math.isfinite(h) or h < 2:
            nf = r.get("num_floors")
            h = nf * FLOOR_H + 1.5 if nf else 9 + 6 * rnd(key)
        cls = r.get("class") or ""
        boat = cls == "houseboat"
        if boat:
            h = 2.6
        kind = KINDS.get(cls, 0)
        t = tiles[tile_of(c.x, c.y)]
        for poly in polys(g):
            poly = poly if poly.is_valid else poly.buffer(0)
            for p in polys(poly):
                p = orient(p, 1.0)
                if p.area < 6:
                    continue
                rect = p.minimum_rotated_rectangle
                rc = list(rect.exterior.coords)[:4]
                if len(rc) < 4:
                    continue
                sides = [math.dist(rc[k], rc[(k + 1) % 4]) for k in range(4)]
                short, long_ = min(sides[:2]), max(sides[:2])
                rectangular = p.area / max(rect.area, 1e-9) > 0.88 and not p.interiors
                shape = r.get("roof_shape")
                gabled = (not boat and rectangular and h > 6 and
                          (shape in ("gabled", "saltbox", "gambrel") or (shape is None and short <= 11 and long_ >= 1.3 * short)))
                if gabled:
                    s = 0 if sides[0] <= sides[1] else 1
                    corners = [rc[(s + k) % 4] for k in range(4)]
                    pitch = 1.1 + 0.4 * rnd(key + "p")
                    rh = r.get("roof_height")
                    eave = h - rh if rh is not None and math.isfinite(rh) and 0 < rh < h else max(h - pitch * short / 2, 4.0)
                    t["buildings"].append({"g": dm(corners), "e": round(eave, 1), "h": round(h, 1), "k": kind})
                else:
                    t["buildings"].append({"r": [ring(p.exterior.coords)] + [ring(q.coords) for q in p.interiors],
                                           "h": round(h, 1), "k": kind, **({"w": 1} if boat else {})})
                OV["buildings"].append((list(p.exterior.coords), kind))
                n += 1
    return n


def clip_polys(g, key, value_fn):
    for i, j in tiles_over(g):
        part = g.intersection(tile_box(i, j))
        for p in polys(part):
            if p.area > 4:
                tiles[(i, j)][key].append(value_fn([ring(p.exterior.coords)] + [ring(q.coords) for q in p.interiors]))


def clip_lines(g, key, value_fn, min_len=1):
    for i, j in tiles_over(g):
        part = g.intersection(tile_box(i, j))
        for p in lines(part):
            if p.length > min_len:
                tiles[(i, j)][key].append(value_fn(dm(p.coords)))


search_streets = {}


def do_water():
    labels = {}
    for r in load("water"):
        g = to_rd(wkb.loads(r["geometry"])).intersection(AREA)
        if g.is_empty:
            continue
        nm = name_of(r)
        if g.geom_type in ("Polygon", "MultiPolygon"):
            clip_polys(g, "water", lambda v: v)
            OV["water"] += [p for p in polys(g)]
        if nm:
            for piece in lines(g):
                if piece.length > 60 and (nm not in labels or piece.length > labels[nm][1]):
                    mid = piece.interpolate(0.5, normalized=True)
                    a, b = piece.interpolate(0.45, normalized=True), piece.interpolate(0.55, normalized=True)
                    labels[nm] = ((mid.x, mid.y, math.degrees(math.atan2(b.y - a.y, b.x - a.x))), piece.length)
    for nm, ((x, y, ang), _) in labels.items():
        tiles[tile_of(x, y)]["waterLabels"].append([nm, *dm([(x, y)]), round(ang)])
        search_streets[nm] = ("Canal", x, y)


ROAD = {
    "motorway": (12, "road"), "trunk": (11, "road"), "primary": (9, "road"), "secondary": (8, "road"), "tertiary": (7, "road"),
    "residential": (5.5, "road"), "living_street": (5, "road"), "unclassified": (5, "road"), "service": (4, "road"),
    "pedestrian": (5, "walk"), "footway": (2.2, "walk"), "steps": (2, "walk"), "path": (2, "walk"), "track": (3, "walk"),
    "cycleway": (2.6, "bike"), "tram": (1.6, "tram"), "standard_gauge": (1.6, "rail"), "subway": (1.6, "rail"), "light_rail": (1.6, "tram"),
}


def do_roads():
    for r in load("segments"):
        cls = r.get("class")
        if cls not in ROAD:
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if not AREA.intersects(g):
            continue
        w, layer = ROAD[cls]
        OV["roads"].append((g, w, layer))
        nm = name_of(r) or ""
        clip_lines(g, "roads", lambda c: [layer, w, c, nm])
        if nm and layer in ("road", "walk", "bike") and nm not in search_streets:
            mid = g.interpolate(0.5, normalized=True)
            search_streets[nm] = ("Street", mid.x, mid.y)


def do_land():
    infra_pts = {"street_lamp": "lamps", "bench": "benches", "bicycle_parking": "bikes", "waste_basket": "bins",
                 "traffic_signals": "signals", "bollard": "bollards"}
    for r in load("infrastructure"):
        c = r.get("class")
        if c in infra_pts:
            g = to_rd(wkb.loads(r["geometry"]))
            if g.geom_type == "Point" and AREA.contains(g):
                tiles[tile_of(g.x, g.y)][infra_pts[c]] += dm([(g.x, g.y)])
        elif c == "bridge":
            g = to_rd(wkb.loads(r["geometry"]))
            if g.geom_type in ("LineString", "MultiLineString"):
                clip_lines(g, "bridges", lambda v: v, 2)
    green = {"park": "park", "grass": "grass", "garden": "garden", "flowerbed": "flower", "playground": "play",
             "pitch": "pitch", "cemetery": "park", "allotments": "garden", "meadow": "grass", "village_green": "grass",
             "recreation_ground": "grass", "golf_course": "grass", "forest": "park"}
    plaza = {"pedestrian": "plaza", "plaza": "plaza"}
    for r in load("land_use"):
        c = r.get("class")
        if c not in green and c not in plaza:
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if not AREA.intersects(g):
            continue
        if c in green:
            clip_polys(g, "green", lambda v, c=c: [green[c], v])
            OV["green"] += polys(g.intersection(AREA))
        else:
            clip_polys(g, "plazas", lambda v: ["plaza", v])
    for r in load("land"):
        c = r.get("class")
        g = to_rd(wkb.loads(r["geometry"]))
        if c == "tree" and g.geom_type == "Point" and AREA.contains(g):
            tiles[tile_of(g.x, g.y)]["trees"] += dm([(g.x, g.y)])
        elif c == "tree_row":
            for p in lines(g.intersection(AREA)):
                for d in np.arange(0, p.length, 9.0):
                    q = p.interpolate(d)
                    tiles[tile_of(q.x, q.y)]["trees"] += dm([(q.x, q.y)])
        elif c in ("forest", "grassland", "scrub", "grass", "wood", "meadow") and g.geom_type in ("Polygon", "MultiPolygon"):
            if AREA.intersects(g):
                clip_polys(g, "green", lambda v, c=c: ["park" if c in ("forest", "wood") else "grass", v])


MAJOR = {"museum", "art_museum", "history_museum", "landmark_and_historical_building", "church_cathedral",
         "christian_place_of_worship", "jewish_place_of_worship", "train_station", "palace", "monument",
         "theatre", "concert_hall", "park", "tourist_attraction", "castle", "public_square", "historical_landmark",
         "stadium_arena", "zoo", "airport"}
search_places = []


def latin(nm):
    return not any(ord(ch) > 0x24F and not 0x2000 <= ord(ch) <= 0x206F for ch in nm)


def do_places():
    for r in load("places"):
        nm = name_of(r)
        try:
            conf = float(r.get("confidence") or 0)
        except (TypeError, ValueError):
            conf = 0
        if not nm or conf < 0.55 or not latin(nm):
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if g.geom_type != "Point" or not AREA.contains(g):
            continue
        cat = r.get("basic_category") or ""
        a = r.get("addresses") or []
        addr = (a[0] or {}).get("freeform") or "" if a else ""
        w = r.get("websites") or []
        web = w[0] if w else ""
        major = 1 if (cat in MAJOR and conf > 0.8) else 0
        x, y = dm([(g.x, g.y)])
        tiles[tile_of(g.x, g.y)]["places"].append([nm, cat, x, y, major, addr, web])
        search_places.append([nm, cat, x, y])


def render_overview(path, width=4096):
    """The whole city as one map image, draped under the 3D tiles."""
    from PIL import Image, ImageDraw
    x0, y0, x1, y1 = AREA.bounds
    s = width / (x1 - x0)
    height = round((y1 - y0) * s)
    img = Image.new("RGB", (width, height), (178, 172, 160))
    d = ImageDraw.Draw(img)
    P = lambda coords: [((x - x0) * s, (y1 - y) * s) for x, y in coords]
    for g in OV["green"]:
        d.polygon(P(g.exterior.coords), fill=(110, 148, 86))
    for g in OV["water"]:
        d.polygon(P(g.exterior.coords), fill=(52, 88, 96))
        for h in g.interiors:
            d.polygon(P(h.coords), fill=(178, 172, 160))
    col = {"road": (70, 73, 75), "walk": (196, 188, 172), "bike": (156, 70, 56), "tram": (95, 98, 102), "rail": (85, 80, 74)}
    for g, w, layer in sorted(OV["roads"], key=lambda r: ["walk", "bike", "road", "tram", "rail"].index(r[2])):
        for ln in lines(g):
            d.line(P(ln.coords), fill=col[layer], width=max(1, round(w * s * 1.4)))
    shade = {0: (196, 170, 150), 1: (176, 112, 88), 2: (168, 96, 80), 3: (170, 176, 182), 4: (160, 156, 150), 5: (70, 100, 84)}
    for coords, kind in OV["buildings"]:
        d.polygon(P(coords), fill=shade.get(kind, (190, 160, 140)), outline=(120, 90, 76))
    img.save(path, "JPEG", quality=84, optimize=True, progressive=True)
    return width, height


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "tiles").mkdir(exist_ok=True)
    print("buildings", do_buildings(), flush=True)
    do_water(); print("water", flush=True)
    do_roads(); print("roads", flush=True)
    do_land(); print("land", flush=True)
    do_places(); print("places", len(search_places), flush=True)
    index, total = [], 0
    for (i, j), t in sorted(tiles.items()):
        if not any(t.values()):
            continue
        data = {"tile": [i, j], **{k: v for k, v in t.items()}}
        s = json.dumps(data, separators=(",", ":"), ensure_ascii=False)
        (OUT / "tiles" / f"{i}_{j}.json").write_text(s)
        total += len(s)
        index.append([i, j, len(t.get("buildings", [])), len(s)])
    streets = [[n, kind, *dm([(x, y)])] for n, (kind, x, y) in search_streets.items()]
    (OUT / "search.json").write_text(json.dumps({"places": search_places, "streets": streets}, separators=(",", ":"), ensure_ascii=False))
    ow, oh = render_overview(OUT / "overview.jpg")
    print(f"overview {ow}x{oh}, {(OUT / 'overview.jpg').stat().st_size / 1e6:.1f} MB", flush=True)
    (OUT / "index.json").write_text(json.dumps({
        "origin": ORIGIN, "tile": TILE, "tiles": index, "bounds": dm(list(AREA.exterior.coords)[:4]),
        "start": [round(float(_dx[0] - ORIGIN[0]) * 10), round(float(_dy[0] - ORIGIN[1]) * 10)],
    }, separators=(",", ":")))
    big = max(index, key=lambda r: r[3])
    print(f"{len(index)} tiles, {total / 1e6:.1f} MB, largest tile {big[:2]} {big[3] / 1e6:.2f} MB, "
          f"{sum(r[2] for r in index):,} buildings; search {(OUT / 'search.json').stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
