"""Write a SYNTHETIC canal street in 3D BAG's CityJSON layout.

This is test data, not Amsterdam: it exists so the pipeline can be run and
checked without network access. Two rows of narrow houses face each other
across a canal, in blocks split by cross streets, with the same structure
3D BAG uses (Building + BuildingPart, LoD 2.2 Solid, semantic surfaces,
oorspronkelijkbouwjaar / b3_h_maaiveld attributes).

    python make_sample.py data/sample_canal.city.json
"""
import json
import random
import sys

import numpy as np

ORIGIN = np.array([121300.0, 487200.0])   # around the Herengracht, in RD New
GROUND = 0.4
CANAL_HALF = 14.0


def house(x0, w, front_y, depth, facing, eave, roof, rng):
    """facing = -1: front faces south (north row); +1: faces north."""
    y0, y1 = (front_y, front_y + depth) if facing < 0 else (front_y - depth, front_y)
    x1 = x0 + w
    g, e = GROUND, GROUND + eave
    pitch = rng.uniform(0.9, 1.3)
    faces = []

    def wall(*pts):
        faces.append(("WallSurface", pts))

    def roof_(*pts):
        faces.append(("RoofSurface", pts))
    faces.append(("GroundSurface", [(x0, y0, g), (x1, y0, g), (x1, y1, g), (x0, y1, g)]))
    if roof == "flat":
        wall((x0, y0, g), (x1, y0, g), (x1, y0, e), (x0, y0, e))
        wall((x1, y1, g), (x0, y1, g), (x0, y1, e), (x1, y1, e))
        wall((x0, y0, g), (x0, y1, g), (x0, y1, e), (x0, y0, e))
        wall((x1, y0, g), (x1, y1, g), (x1, y1, e), (x1, y0, e))
        roof_((x0, y0, e), (x1, y0, e), (x1, y1, e), (x0, y1, e))
    elif roof == "gable_front":       # ridge runs back from the canal
        xm, top = (x0 + x1) / 2, e + pitch * w / 2
        wall((x0, y0, g), (x1, y0, g), (x1, y0, e), (xm, y0, top), (x0, y0, e))
        wall((x0, y1, g), (x1, y1, g), (x1, y1, e), (xm, y1, top), (x0, y1, e))
        wall((x0, y0, g), (x0, y1, g), (x0, y1, e), (x0, y0, e))
        wall((x1, y0, g), (x1, y1, g), (x1, y1, e), (x1, y0, e))
        roof_((x0, y0, e), (x0, y1, e), (xm, y1, top), (xm, y0, top))
        roof_((x1, y0, e), (x1, y1, e), (xm, y1, top), (xm, y0, top))
    else:                             # ridge parallel to the canal
        ym, top = (y0 + y1) / 2, e + 0.5 * min(depth, 10) / 2
        wall((x0, y0, g), (x1, y0, g), (x1, y0, e), (x0, y0, e))
        wall((x0, y1, g), (x1, y1, g), (x1, y1, e), (x0, y1, e))
        wall((x0, y0, g), (x0, y1, g), (x0, y1, e), (x0, ym, top), (x0, y0, e))
        wall((x1, y0, g), (x1, y1, g), (x1, y1, e), (x1, ym, top), (x1, y0, e))
        roof_((x0, y0, e), (x1, y0, e), (x1, ym, top), (x0, ym, top))
        roof_((x0, y1, e), (x1, y1, e), (x1, ym, top), (x0, ym, top))
    # Wind every face outward (the solid is convex, so its centre is inside).
    c = np.array([(x0 + x1) / 2, (y0 + y1) / 2, (g + e) / 2])
    out = []
    for kind, pts in faces:
        p = np.asarray(pts, float)
        n = np.cross(p[1] - p[0], p[2] - p[0])
        if n @ (p.mean(0) - c) < 0:
            p = p[::-1]
        out.append((kind, p))
    return out


def street(seed=7):
    rng = random.Random(seed)
    houses = []
    for facing, front_y in ((-1, CANAL_HALF), (1, -CANAL_HALF)):
        x = -95.0
        while x < 95.0:
            block_end = x + rng.uniform(55, 75)
            while x < block_end - 4:
                era = rng.choices(["golden", "classic", "school", "postwar"], [5, 4, 1.5, 1])[0]
                if era == "golden":
                    w, eave, roof = rng.uniform(4.5, 7), rng.uniform(9, 14), "gable_front"
                    year = rng.randint(1600, 1715)
                elif era == "classic":
                    w = rng.uniform(5.5, 11)
                    eave = rng.uniform(11, 16)
                    roof = rng.choice(["gable_front", "ridge_parallel", "ridge_parallel"])
                    year = rng.randint(1725, 1895)
                elif era == "school":
                    w, eave, roof = rng.uniform(8, 14), rng.uniform(12, 15), "ridge_parallel"
                    year = rng.randint(1905, 1940)
                else:
                    w, eave, roof = rng.uniform(10, 18), rng.uniform(13, 18), "flat"
                    year = rng.randint(1955, 1995)
                w = min(w, block_end - x)
                depth = rng.uniform(14, 22)
                houses.append((house(x, w, front_y, depth, facing, eave, roof, rng), year))
                x += w
            x = block_end + 9.0     # cross street
    return houses


def to_cityjson(houses):
    scale = 0.001
    verts, index = [], {}
    objects = {}

    def vid(p):
        key = tuple(int(round(c / scale)) for c in (p[0] + ORIGIN[0], p[1] + ORIGIN[1], p[2]))
        if key not in index:
            index[key] = len(verts)
            verts.append(list(key))
        return index[key]
    for i, (faces, year) in enumerate(houses):
        bid = f"NL.IMBAG.Pand.sample{i:04d}"
        kinds = ["GroundSurface", "WallSurface", "RoofSurface"]
        shell = [[[vid(p) for p in pts]] for _, pts in faces]
        values = [kinds.index(k) for k, _ in faces]
        objects[bid] = {"type": "Building", "children": [bid + "-0"],
                        "attributes": {"oorspronkelijkbouwjaar": year,
                                       "b3_h_maaiveld": GROUND},
                        "geometry": []}
        objects[bid + "-0"] = {
            "type": "BuildingPart", "parents": [bid],
            "geometry": [{"type": "Solid", "lod": "2.2", "boundaries": [shell],
                          "semantics": {"surfaces": [{"type": k} for k in kinds],
                                        "values": [values]}}]}
    return {"type": "CityJSON", "version": "2.0",
            "metadata": {"referenceSystem": "https://www.opengis.net/def/crs/EPSG/0/7415",
                         "title": "SYNTHETIC canal street (test data, not real Amsterdam)"},
            "transform": {"scale": [scale] * 3, "translate": [0, 0, 0]},
            "CityObjects": objects, "vertices": verts}


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "data/sample_canal.city.json"
    import os
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    doc = to_cityjson(street())
    with open(out, "w") as f:
        json.dump(doc, f)
    print(f"wrote {out}: {len(doc['CityObjects']) // 2} buildings")
