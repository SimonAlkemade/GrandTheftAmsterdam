"""Pack Overture layers for central Amsterdam into one compact JSON the web
map builds its 3D scene from (out/centrum/city.json).

Coordinates are RD New metres around ORIGIN, stored as integer decimetres:
x east, y north. Buildings come as either a flat-roofed footprint (rings +
height) or, for narrow deep rectangular lots, a gable box (4 corners with
the short side first, eave and ridge heights).
"""
import json
import math
import pickle
import sys
import zlib
from pathlib import Path

import numpy as np
from shapely import wkb
from shapely.geometry import box
from shapely.geometry.polygon import orient

from amsterdam.overture import to_rd, wgs84_to_rd_np

SRC = Path("data/centrum")
OUT = Path("out/centrum")
BBOX = (4.874, 52.364, 4.906, 52.382)
FLOOR_H = 3.1

x0, y0 = wgs84_to_rd_np(np.array([BBOX[0]]), np.array([BBOX[1]]))
x1, y1 = wgs84_to_rd_np(np.array([BBOX[2]]), np.array([BBOX[3]]))
AREA = box(float(x0[0]), float(y0[0]), float(x1[0]), float(y1[0]))
ORIGIN = (round(AREA.centroid.x), round(AREA.centroid.y))


def dm(coords):
    """Flat list of integer decimetres relative to ORIGIN."""
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
    return pickle.load(open(SRC / f"{name}.pkl", "rb"))


def name_of(row):
    n = row.get("names")
    if isinstance(n, str):
        try:
            n = eval(n, {"None": None})          # stringified by pyarrow's to_pylist on mixed types
        except Exception:
            return None
    return (n or {}).get("primary") if isinstance(n, dict) else None


def rnd(key):
    return (zlib.crc32(key.encode()) % 10000) / 10000.0


def buildings():
    out = []
    for r in load("buildings"):
        if r.get("is_underground"):
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if not AREA.intersects(g):
            continue
        key = str(r["id"])
        h = r.get("height")
        if h is None or not math.isfinite(h) or h < 2:
            n = r.get("num_floors")
            h = n * FLOOR_H + 1.5 if n else 11 + 6 * rnd(key)
        cls = r.get("class") or ""
        boat = cls == "houseboat"
        if boat:
            h = 2.6
        for poly in (g.geoms if g.geom_type == "MultiPolygon" else [g]):
            poly = orient(poly.buffer(0), 1.0) if not poly.is_valid else orient(poly, 1.0)
            if poly.is_empty or poly.area < 6 or poly.geom_type != "Polygon":
                continue
            rect = poly.minimum_rotated_rectangle
            rc = list(rect.exterior.coords)[:4]
            sides = [math.dist(rc[i], rc[(i + 1) % 4]) for i in range(4)]
            short, long_ = min(sides[:2]), max(sides[:2])
            rectangular = poly.area / max(rect.area, 1e-9) > 0.88 and not poly.interiors
            shape = r.get("roof_shape")
            gabled = (not boat and rectangular and h > 6 and
                      (shape in ("gabled", "saltbox", "gambrel") or (shape is None and short <= 11 and long_ >= 1.3 * short)))
            kind = {"apartments": 1, "house": 1, "retail": 2, "commercial": 3, "office": 3,
                    "industrial": 4, "hotel": 2, "houseboat": 5}.get(cls, 0)
            if gabled:
                s = 0 if sides[0] <= sides[1] else 1
                corners = [rc[(s + k) % 4] for k in range(4)]
                pitch = 1.1 + 0.4 * rnd(key + "p")
                rh = r.get("roof_height")
                if rh is not None and math.isfinite(rh) and 0 < rh < h:
                    eave = h - rh
                else:
                    eave = max(h - pitch * short / 2, 4.0)
                out.append({"g": dm(corners), "e": round(eave, 1), "h": round(h, 1), "k": kind})
            else:
                out.append({"r": [ring(poly.exterior.coords)] + [ring(i.coords) for i in poly.interiors],
                            "h": round(h, 1), "k": kind, **({"w": 1} if boat else {})})
    return out


def water():
    polys, labels = [], {}
    for r in load("water_named"):
        g = to_rd(wkb.loads(r["geometry"])).intersection(AREA)
        if g.is_empty:
            continue
        nm = name_of(r)
        if g.geom_type in ("Polygon", "MultiPolygon"):
            for p in (g.geoms if g.geom_type == "MultiPolygon" else [g]):
                if p.area > 4:
                    polys.append([ring(p.exterior.coords)] + [ring(i.coords) for i in p.interiors])
        if nm and g.geom_type in ("LineString", "MultiLineString"):
            # One label per canal name, at the middle of its longest piece.
            parts = list(g.geoms) if g.geom_type == "MultiLineString" else [g]
            piece = max(parts, key=lambda p: p.length)
            if piece.length > 60 and (nm not in labels or piece.length > labels[nm][1]):
                mid = piece.interpolate(0.5, normalized=True)
                a = piece.interpolate(0.45, normalized=True); b = piece.interpolate(0.55, normalized=True)
                ang = math.degrees(math.atan2(b.y - a.y, b.x - a.x))
                labels[nm] = (dm([(mid.x, mid.y)]) + [round(ang)], piece.length)
    return polys, [[n, *v[0]] for n, v in labels.items()]


ROAD = {  # class -> (width m, layer)
    "primary": (9, "road"), "secondary": (8, "road"), "tertiary": (7, "road"), "residential": (5.5, "road"),
    "living_street": (5, "road"), "unclassified": (5, "road"), "service": (4, "road"),
    "pedestrian": (5, "walk"), "footway": (2.2, "walk"), "steps": (2, "walk"), "path": (2, "walk"),
    "cycleway": (2.6, "bike"), "tram": (1.6, "tram"), "standard_gauge": (1.6, "rail"),
}


def roads():
    out = []
    for r in load("segments"):
        cls = r.get("class")
        if cls not in ROAD:
            continue
        g = to_rd(wkb.loads(r["geometry"])).intersection(AREA)
        if g.is_empty:
            continue
        w, layer = ROAD[cls]
        for p in (g.geoms if g.geom_type == "MultiLineString" else [g]):
            if p.geom_type == "LineString" and p.length > 1:
                out.append([layer, w, dm(p.coords), name_of(r) or ""])
    return out


def points(rows, cls_set):
    pts = {c: [] for c in cls_set}
    for r in rows:
        c = r.get("class")
        if c not in pts:
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if g.geom_type == "Point" and AREA.contains(g):
            pts[c] += dm([(g.x, g.y)])
        elif g.geom_type == "LineString" and c == "tree_row":
            g = g.intersection(AREA)
            for p in (g.geoms if g.geom_type == "MultiLineString" else [g] if not g.is_empty else []):
                for d in np.arange(0, p.length, 9.0):
                    q = p.interpolate(d)
                    pts[c] += dm([(q.x, q.y)])
    return pts


def areas(rows, classes):
    out = []
    for r in rows:
        c = r.get("class")
        if c not in classes:
            continue
        g = to_rd(wkb.loads(r["geometry"])).intersection(AREA)
        for p in (g.geoms if g.geom_type == "MultiPolygon" else [g] if g.geom_type == "Polygon" else []):
            if p.area > 4:
                out.append([classes[c], [ring(p.exterior.coords)] + [ring(i.coords) for i in p.interiors]])
    return out


def bridges():
    """Bridge outlines come as open lines along each bridge: drawn as decks."""
    out = []
    for r in load("infrastructure"):
        if r.get("class") != "bridge":
            continue
        g = to_rd(wkb.loads(r["geometry"])).intersection(AREA)
        for p in (g.geoms if g.geom_type == "MultiLineString" else [g] if g.geom_type == "LineString" else []):
            if p.length > 2:
                out.append(dm(p.coords))
    return out


MAJOR = {"museum", "art_museum", "history_museum", "landmark_and_historical_building", "church_cathedral",
         "christian_place_of_worship", "jewish_place_of_worship", "train_station", "palace", "monument",
         "theatre", "concert_hall", "park", "tourist_attraction", "castle", "public_square", "historical_landmark"}


def places():
    out = []
    for r in load("places"):
        nm = name_of(r)
        try:
            conf = float(r.get("confidence") or 0)
        except ValueError:
            conf = 0
        if not nm or conf < 0.55:
            continue
        # Some sources give a translated primary name (Chinese, Russian...);
        # keep the Latin-script names a visitor sees on the street.
        if any(ord(ch) > 0x24F and not 0x2000 <= ord(ch) <= 0x206F for ch in nm):
            continue
        g = to_rd(wkb.loads(r["geometry"]))
        if not AREA.contains(g):
            continue
        cat = r.get("basic_category") or ""
        addr = ""
        a = r.get("addresses")
        if isinstance(a, str) and "freeform" in a:
            try:
                addr = (eval(a, {"None": None}) or [{}])[0].get("freeform") or ""
            except Exception:
                addr = ""
        web = ""
        w = r.get("websites")
        if isinstance(w, str) and w.startswith("["):
            try:
                web = (eval(w) or [""])[0] or ""
            except Exception:
                web = ""
        major = 1 if (cat in MAJOR and conf > 0.8) else 0
        out.append([nm, cat, *dm([(g.x, g.y)]), major, addr, web])
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    w, labels = water()
    land = load("land")
    infra = load("infrastructure")
    pts = points(infra, {"street_lamp", "bench", "bicycle_parking", "waste_basket", "traffic_signals", "bollard"})
    trees = points(land, {"tree", "tree_row"})
    city = {
        "origin": ORIGIN, "bounds": dm(list(AREA.exterior.coords)[:4]),
        "buildings": buildings(), "water": w, "waterLabels": labels, "roads": roads(),
        "bridges": bridges(),
        "green": areas(load("land_use"), {"park": "park", "grass": "grass", "garden": "garden",
                                          "flowerbed": "flower", "playground": "play", "pitch": "pitch"})
                 + areas(land, {"forest": "park", "grassland": "grass", "scrub": "grass"}),
        "plazas": areas(load("land_use"), {"pedestrian": "plaza", "plaza": "plaza"}),
        "trees": trees["tree"] + trees["tree_row"],
        "lamps": pts["street_lamp"], "benches": pts["bench"], "bikes": pts["bicycle_parking"],
        "bins": pts["waste_basket"], "signals": pts["traffic_signals"], "bollards": pts["bollard"],
        "places": places(),
    }
    s = json.dumps(city, separators=(",", ":"), ensure_ascii=False)
    (OUT / "city.json").write_text(s)
    print({k: len(v) for k, v in city.items() if isinstance(v, list)}, f"{len(s) / 1e6:.2f} MB")


if __name__ == "__main__":
    sys.exit(main())
