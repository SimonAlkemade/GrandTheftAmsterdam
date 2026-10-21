"""Prepare the streamed city for the Godot project.

    python prepare_city_tiles.py data/city out/city     # once: cut the tiles
    python prepare_godot_city.py out/city godot-city/data

Copies the tiles and adds what GDScript cannot do cheaply:
  * triangles for every polygon with holes ("t": earcut indices over the
    concatenated rings) -- Godot's Geometry2D cannot triangulate holes;
  * "s": 1 on buildings with a shop, cafe or hotel inside (a shopfront);
and turns the facade bump maps into normal maps.
"""
import json
import re
import shutil
import sys
from pathlib import Path

import mapbox_earcut as earcut
import numpy as np
from shapely import STRtree
from shapely.geometry import Point, Polygon

SHOPPY = re.compile(r"shop|store|restaurant|cafe|coffee|bar|pub|bakery|boutique|retail|market|pharmacy|food|hotel|"
                    r"gallery|salon|butcher|deli|ice_cream|fashion|clothing|jewelry|book|florist|optician")


def tris(rings):
    """earcut over rings given as flat [x, y, ...] decimetre lists."""
    pts = [np.asarray(r, float).reshape(-1, 2) for r in rings if len(r) >= 6]
    if not pts:
        return []
    ends = np.cumsum([len(p) for p in pts]).astype(np.uint32)
    return earcut.triangulate_float64(np.vstack(pts), ends).tolist()


def with_holes(rings):
    return len(rings) > 1


def prepare_tile(t):
    for b in t.get("buildings", []):
        if "r" in b and with_holes(b["r"]):
            b["t"] = tris(b["r"])
    t["water"] = [{"r": rings, **({"t": tris(rings)} if with_holes(rings) else {})} for rings in t.get("water", [])]
    for key in ("green", "plazas"):
        t[key] = [{"c": cls, "r": rings, **({"t": tris(rings)} if with_holes(rings) else {})} for cls, rings in t.get(key, [])]
    # Shopfronts: buildings with a shop-like place inside their outline.
    polys, idx = [], []
    for i, b in enumerate(t.get("buildings", [])):
        ring = b["g"] if "g" in b else b["r"][0]
        p = Polygon(np.asarray(ring, float).reshape(-1, 2))
        if p.is_valid and p.area > 0:
            polys.append(p)
            idx.append(i)
    if polys:
        tree = STRtree(polys)
        for name, cat, x, y, *_ in t.get("places", []):
            if not SHOPPY.search(cat or ""):
                continue
            for k in tree.query(Point(x, y), predicate="within"):
                t["buildings"][idx[k]]["s"] = 1
    return t


def normal_maps(tex_dir):
    """height (bump) -> tangent-space normal map, OpenGL convention."""
    from PIL import Image
    for f in sorted(tex_dir.glob("*_bump.png")):
        h = np.asarray(Image.open(f).convert("L"), float) / 255.0
        dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 2.0
        dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 2.0
        n = np.dstack([-dx, dy, np.ones_like(h)])
        n /= np.linalg.norm(n, axis=2, keepdims=True)
        Image.fromarray(((n * 0.5 + 0.5) * 255).astype(np.uint8)).save(f.with_name(f.name.replace("_bump", "_nrm")))


def main(src="out/city", dst="godot-city/data"):
    src, dst = Path(src), Path(dst)
    (dst / "tiles").mkdir(parents=True, exist_ok=True)
    for name in ("index.json", "search.json", "overview.jpg"):
        shutil.copy(src / name, dst / name)
    n = 0
    for f in sorted((src / "tiles").glob("*.json")):
        t = prepare_tile(json.loads(f.read_text()))
        (dst / "tiles" / f.name).write_text(json.dumps(t, separators=(",", ":"), ensure_ascii=False))
        n += 1
    normal_maps(Path(dst).parent / "textures")
    size = sum(p.stat().st_size for p in (dst / "tiles").glob("*.json"))
    print(f"{n} tiles, {size / 1e6:.1f} MB -> {dst}")


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
