"""Build a district from Overture Maps rows (buildings + water).

    python build_overture.py buildings.pkl water.pkl --center 52.3725 4.8865 --size 450 400 -o out/amsterdam.glb

The .pkl files are lists of row dicts (id, geometry WKB, height, num_floors,
roof_shape, roof_height, class, ...) as read from Overture's GeoParquet.
"""
import argparse
import pickle
import time

import numpy as np
from shapely import wkb
from shapely.geometry import box

from amsterdam.city import build_district
from amsterdam.ground import ground_with_water
from amsterdam.gltf import write_glb
from amsterdam.overture import GROUND_Z, building_from_row, to_rd, wgs84_to_rd_np


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("buildings")
    ap.add_argument("water")
    ap.add_argument("--center", nargs=2, type=float, required=True, metavar=("LAT", "LON"))
    ap.add_argument("--size", nargs=2, type=float, default=(450, 400), metavar=("W", "H"))
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-o", "--out", default="out/amsterdam.glb")
    a = ap.parse_args(argv)
    t = time.time()
    cx, cy = (float(v[0]) for v in wgs84_to_rd_np(np.array([a.center[1]]), np.array([a.center[0]])))
    area = box(cx - a.size[0] / 2, cy - a.size[1] / 2, cx + a.size[0] / 2, cy + a.size[1] / 2)

    buildings = []
    for row in pickle.load(open(a.buildings, "rb")):
        g = to_rd(wkb.loads(row["geometry"]))
        if not area.contains(g.centroid):
            continue
        b = building_from_row(row)
        if b:
            buildings.append(b)
    water = [to_rd(wkb.loads(r["geometry"])) for r in pickle.load(open(a.water, "rb"))]
    water = [w.intersection(area) for w in water if w.intersects(area)]
    print(f"{len(buildings)} buildings, {len(water)} water polygons in the area")

    district = build_district(buildings, a.seed, ground=False)
    o = district.origin
    from shapely.affinity import translate
    local_water = [translate(w, -o[0], -o[1]) for w in water]
    x0, y0, x1, y1 = area.bounds
    ground = ground_with_water((x0 - o[0], y0 - o[1], x1 - o[0], y1 - o[1]),
                               local_water, GROUND_Z - o[2])
    district.nodes.append(("ground", ground, {}))
    stats = write_glb(a.out, district)
    print(f"wrote {a.out}: {stats['nodes']} nodes, {stats['triangles']:,} triangles, "
          f"{stats['bytes'] / 1e6:.1f} MB in {time.time() - t:.0f}s; origin RD {o.tolist()}")


if __name__ == "__main__":
    main()
