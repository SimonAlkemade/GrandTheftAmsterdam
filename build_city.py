"""Build a detailed district from open data.

    python build_city.py data/centrum.city.json -o out/centrum.glb
    python build_city.py export.obj --obj-up y -o out/export.glb

Inputs: 3D BAG CityJSON / CityJSONSeq / a folder of API pages (from
fetch_3dbag.py), or an OBJ (e.g. exported from 3d.amsterdam.nl). Several inputs are merged.
"""
import argparse
import sys
import time
from pathlib import Path

from amsterdam.city import build_district
from amsterdam.gltf import write_glb
from amsterdam.sources import load_cityjson, load_obj


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--out", default="out/district.glb")
    ap.add_argument("--seed", type=int, default=1,
                    help="world seed: same input + seed = byte-identical output")
    ap.add_argument("--obj-up", choices=["z", "y"], default="z",
                    help="up axis of OBJ inputs (3d.amsterdam.nl exports may be Y-up)")
    ap.add_argument("--no-ground", action="store_true")
    a = ap.parse_args(argv)

    t = time.time()
    buildings = []
    paths = []
    for p in a.inputs:              # a folder from fetch_3dbag.py = all its pages
        p = Path(p)
        paths += sorted(map(str, p.glob("*.json"))) if p.is_dir() else [str(p)]
    for path in paths:
        if path.lower().endswith(".obj"):
            buildings += load_obj(path, up=a.obj_up)
        else:
            buildings += load_cityjson(path)
    print(f"read {len(buildings)} buildings from {len(paths)} file(s)")
    district = build_district(buildings, a.seed, ground=not a.no_ground)
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    stats = write_glb(a.out, district)
    print(f"wrote {a.out}: {stats['nodes']} nodes, {stats['triangles']:,} triangles, "
          f"{stats['materials']} materials, {stats['bytes'] / 1e6:.1f} MB "
          f"in {time.time() - t:.1f}s; origin RD {district.origin.tolist()}")


if __name__ == "__main__":
    sys.exit(main())
