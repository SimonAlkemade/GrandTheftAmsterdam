"""Download every Overture layer the city map uses for all of Amsterdam.

    python fetch_city.py data/city

Reads only the parquet row groups whose bbox statistics overlap the city,
and writes one pickle per layer (lists of row dicts, geometry as WKB).
"""
import pickle
import sys
import time
from pathlib import Path

import pyarrow.compute as pc
import pyarrow.parquet as pq

import fetch_overture as fo

# The municipality of Amsterdam, with a little margin.
BBOX = (4.728, 52.278, 5.080, 52.432)
LAYERS = {
    "buildings": ("theme=buildings/type=building",
                  ["id", "geometry", "height", "num_floors", "roof_shape", "roof_height", "is_underground", "class"]),
    "water": ("theme=base/type=water", ["id", "geometry", "subtype", "class", "names"]),
    "segments": ("theme=transportation/type=segment", ["id", "geometry", "subtype", "class", "names"]),
    "land": ("theme=base/type=land", ["id", "geometry", "subtype", "class"]),
    "land_use": ("theme=base/type=land_use", ["id", "geometry", "subtype", "class"]),
    "infrastructure": ("theme=base/type=infrastructure", ["id", "geometry", "subtype", "class"]),
    "places": ("theme=places/type=place", ["id", "geometry", "names", "confidence", "basic_category", "addresses", "websites"]),
}


def fetch(prefix, columns, bbox):
    W, S, E, N = bbox
    rows = []
    for key, size, groups in fo.matching_row_groups(prefix, bbox):
        pf = pq.ParquetFile(fo.RangeFile(fo.BUCKET + key, size))
        have = set(pf.schema_arrow.names)
        cols = [c for c in columns if c in have] + ["bbox"]
        for g in groups:                          # one group at a time keeps memory flat
            t = pf.read_row_groups([g], columns=cols)
            b = t.column("bbox")
            f = lambda n: pc.struct_field(b, n)
            keep = pc.and_(pc.and_(pc.greater_equal(f("xmax"), W), pc.less_equal(f("xmin"), E)),
                           pc.and_(pc.greater_equal(f("ymax"), S), pc.less_equal(f("ymin"), N)))
            rows += t.filter(keep).drop(["bbox"]).to_pylist()
    return rows


def main(out="data/city"):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    release = fo.latest_release()
    for name, (theme, cols) in LAYERS.items():
        path = out / f"{name}.pkl"
        if path.exists():
            print(f"{name}: already there", flush=True)
            continue
        t = time.time()
        rows = fetch(release + theme + "/", cols, BBOX)
        with open(path, "wb") as f:
            pickle.dump(rows, f)
        print(f"{name}: {len(rows):,} rows in {time.time() - t:.0f}s", flush=True)
    (out / "SOURCE.txt").write_text(f"Overture Maps {release} (ODbL). bbox lon/lat {BBOX}\n")


if __name__ == "__main__":
    main(*sys.argv[1:])
