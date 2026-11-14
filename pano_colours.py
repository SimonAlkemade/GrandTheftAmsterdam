"""Building colours measured from the City of Amsterdam's open street panoramas.

    python pano_colours.py godot-city/data            # the centre: 2 km round the Dam
    python pano_colours.py godot-city/data --radius 3000
    python pano_colours.py godot-city/data --recalibrate   # the colours again, from out/pano_colours.json

For every building in the area its widest street wall (amsterdam/streetview.py
facades) is looked at from the panorama that sees it most squarely and
unhidden (best_pano), cut out straight-on (rectify), and its colour measured:
the paint or brick of the upper floors, past the windows, the sky over the
roofline and the shopfront below (wall_colour). A building no panorama sees
well takes the median colour of its measured neighbours within 30 m (marked
estimated). Each building gets "c": [r, g, b] in its tile record, which the
game uses to choose and tint its facade (scripts/tile_builder.gd).

The panorama camera is not the walls: its pictures are a little cyan and
flat. One correction for the whole run (calibrate) gives the colour back and
takes out the cast, keeping every difference between houses and the
brightness the panoramas show them in.

Panoramas are listed on a grid of the City's `near` queries, thinned to one
every 15 m (one sees many walls), and only the small (2000 x 1000) image is
fetched; images are not kept, the results are (out/pano_colours.json), so a
run resumes where it stopped.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from shapely.geometry import Point, Polygon
from shapely.strtree import STRtree

from amsterdam.streetview import API, MAX_DIST, best_pano, facades, footprint, parse_panoramas, rectify

PX_PER_M = 8              # enough for a colour
THIN = 15.0               # metres: one panorama per cell this size
NEIGHBOURS = 30.0         # metres: an unseen building takes the colour of measured ones this near
DARK = 40                 # luminance below this is a window or shadow
SKY = 200                 # luminance above this, and greyish: sky or glare


# ---- colour ----------------------------------------------------------------------

def lab(rgb) -> np.ndarray:
    """sRGB (0..255, any shape ending in 3) to CIE Lab (D65)."""
    c = np.asarray(rgb, float) / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def luminance(px: np.ndarray) -> np.ndarray:
    return px[..., 0] * 0.2126 + px[..., 1] * 0.7152 + px[..., 2] * 0.0722


def _hue_sat(px: np.ndarray):
    hi = px.max(axis=-1); lo = px.min(axis=-1); d = hi - lo
    sat = d / np.maximum(hi, 1.0)
    r, g, b = px[..., 0], px[..., 1], px[..., 2]
    safe = np.maximum(d, 1e-6)
    hue = np.where(hi == r, ((g - b) / safe) % 6, np.where(hi == g, (b - r) / safe + 2, (r - g) / safe + 4)) * 60.0
    return hue, sat


def wall_colour(photo: np.ndarray):
    """(rgb, share): the colour of a wall photo's upper floors (the band from 12%
    to 70% of its height: under the roofline, over the shopfront). Left out:
    windows and shadow (dark), sky and glare (bright, grey) and leaves (a tree
    in front). Of what is left, the largest patch of one colour (the paint or
    the brick, not the window frames or the glass) gives the answer; share is
    how much of the band that patch is. (None, share) when too little is left,
    or when the picture is more sky than wall (SKY_SHARE: that panorama did not
    see this wall)."""
    h = photo.shape[0]
    if _sky_share(photo.astype(float)) > SKY_SHARE:
        return None, 0.0                                 # (the panorama does not see this wall)
    img = photo[int(h * 0.12):max(int(h * 0.12) + 1, int(h * 0.70))].astype(float)
    if img.size == 0:
        return None, 0.0
    busy = _local_spread(luminance(img)).reshape(-1)
    band = img.reshape(-1, 3)
    L = luminance(band)
    hue, sat = _hue_sat(band)
    leaves = (hue > 55) & (hue < 170) & (sat > 0.18) & (L < 170) & (busy > 9.0)   # (green and busy: paint is even)
    green = (hue > 55) & (hue < 170) & (sat > 0.18) & (L < 170)
    if green.mean() > 0.6 and np.median(busy[green]) > 5.0:
        return None, 0.0                                 # (a tree in front of it, not a green house)
    keep = (L >= DARK) & ~((L > SKY) & (sat < 0.12)) & ~leaves
    if keep.any():
        keep &= L >= 0.6 * np.median(L[keep])           # (windows darker than their wall)
    if keep.mean() < 0.15:
        return None, float(keep.mean())
    px = band[keep]
    labs = lab(px)
    k = _largest_cluster(labs)
    share = float(k.sum()) / len(band)
    if share < 0.1:
        return None, share
    return tuple(int(round(v)) for v in np.median(px[k], axis=0)), share


SKY_SHARE = 0.3          # a cut-out more sky than this is not of the wall


def _sky_share(img: np.ndarray) -> float:
    """How much of a picture is sky: bright, smooth, and grey or blue."""
    L = luminance(img)
    hue, sat = _hue_sat(img.reshape(-1, 3))
    hue = hue.reshape(L.shape); sat = sat.reshape(L.shape)
    sky = (L > 150) & (_local_spread(L) < 6.0) & ((sat < 0.12) | ((hue > 180) & (hue < 250)))
    return float(sky.mean())


def _local_spread(L: np.ndarray) -> np.ndarray:
    """The spread (std) of luminance over each pixel's 5 x 5 neighbourhood."""
    p = np.pad(L, 2, mode="edge")
    acc = np.zeros_like(L); acc2 = np.zeros_like(L)
    for dy in range(5):
        for dx in range(5):
            v = p[dy:dy + L.shape[0], dx:dx + L.shape[1]]
            acc += v; acc2 += v * v
    m = acc / 25.0
    return np.sqrt(np.maximum(acc2 / 25.0 - m * m, 0.0))


def _largest_cluster(labs: np.ndarray, n: int = 3, rounds: int = 8) -> np.ndarray:
    """Which of the points belong to the biggest of n colour clusters (k-means in Lab)."""
    if len(labs) < n * 4:
        return np.ones(len(labs), bool)
    order = np.argsort(labs[:, 0])
    centres = labs[order[np.linspace(0, len(labs) - 1, n).astype(int)]]
    for _ in range(rounds):
        d = ((labs[:, None, :] - centres[None, :, :]) ** 2).sum(-1)
        lbl = d.argmin(1)
        for c in range(n):
            if (lbl == c).any():
                centres[c] = labs[lbl == c].mean(0)
    counts = np.bincount(lbl, minlength=n)
    return lbl == counts.argmax()


def rgb_from_lab(L) -> np.ndarray:
    """CIE Lab (D65) back to sRGB 0..255 (clipped)."""
    L = np.asarray(L, float)
    fy = (L[..., 0] + 16) / 116; fx = fy + L[..., 1] / 500; fz = fy - L[..., 2] / 200
    f = lambda t: np.where(t ** 3 > 0.008856, t ** 3, (t - 16 / 116) / 7.787)
    xyz = np.stack([f(fx) * 0.95047, f(fy), f(fz) * 1.08883], -1)
    m = np.linalg.inv(np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]]))
    lin = np.clip(xyz @ m.T, 0, 1)
    return np.clip(np.where(lin > 0.0031308, 1.055 * lin ** (1 / 2.4) - 0.055, 12.92 * lin) * 255, 0, 255)


CHROMA = 1.5              # the panoramas' colour is flat (haze, compression): this much stronger


def calibrate(raws):
    """One correction for the whole collection (the camera, not each photo):
    colour CHROMA times stronger (the panoramas are flat: haze, compression),
    then per-channel gains that make the median measured wall neutral (the
    camera's cast). That takes most walls to be near-neutral (plaster, stone,
    whitewash: 72% of the centre's, as measured), so that each channel's
    median is one of them. The walls keep the brightness the panoramas show
    them in.
    Returns rgb -> [r, g, b]."""
    def boost(rgb):
        L = lab(np.clip(np.asarray(rgb, float), 0, 255))
        L[..., 1:] *= CHROMA
        return rgb_from_lab(L)
    boosted = boost(np.asarray(raws, float))
    med = np.median(boosted, axis=0)
    cast = med.mean() / np.maximum(med, 1.0)

    def fix(rgb):
        out = np.clip(boost(rgb) * cast, 0, 255)
        return [int(round(v)) for v in _no_blue(out)]
    return fix


COOL = (170.0, 260.0)     # hues (degrees) that are shade, glass or sky on a wall here, not paint
COOL_SAT = 0.12           # the most saturation they keep


def _no_blue(rgb: np.ndarray) -> np.ndarray:
    """A wall that comes out blue or cyan is in the shade of a blue sky, or glass,
    or sky over a roofline: in Amsterdam it is not blue paint. Its saturation is
    held to COOL_SAT (grey stone), its hue and lightness kept."""
    import colorsys
    h, l, sat = colorsys.rgb_to_hls(*(np.asarray(rgb, float) / 255.0))
    if COOL[0] <= h * 360.0 <= COOL[1] and sat > COOL_SAT:
        return np.array(colorsys.hls_to_rgb(h, l, COOL_SAT)) * 255.0
    return np.asarray(rgb, float)


# ---- measuring ---------------------------------------------------------------------

def _centroid(bd):
    ring = footprint(bd)
    return (sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring))


def thin(panos: list, cell: float = THIN) -> list:
    """One panorama per cell (the first of each)."""
    seen = {}
    for p in panos:
        k = (math.floor(p.x / cell), math.floor(p.y / cell))
        seen.setdefault(k, p)
    return list(seen.values())


def measure(buildings: list, panos, centre, radius: float, gain: float = 1.0, done: dict | None = None,
            save=None, log=print, workers: int = 6) -> dict:
    """{building index: {"c": [r, g, b], "est": bool, ...}} for the buildings within
    `radius` metres of `centre`. `panos` gives near_many(centre, radius) -> [Pano]
    and image(pano) -> HxWx3 array. `done` holds results of an earlier run
    (measured buildings are not looked at again); `save(res)` is called now and then."""
    res = dict(done or {})
    cents = [_centroid(bd) for bd in buildings]
    inside = {i for i, c in enumerate(cents) if math.dist(c, centre) <= radius}
    polys = []
    for bd in buildings:
        try:
            polys.append(Polygon(footprint(bd)).buffer(0))
        except Exception:
            polys.append(Polygon())
    tree = STRtree(polys)
    walls = {}
    for f in facades(buildings):                       # (all of them: a party wall is known by its neighbour)
        if f.building in inside and (f.building not in walls or f.width > walls[f.building].width):
            walls[f.building] = f
    todo = {i: f for i, f in walls.items() if i not in res or res[i].get("est")}
    all_panos = thin(panos.near_many(centre, radius + MAX_DIST))
    log("%d buildings in the area, %d with a street wall to measure, %d panoramas" % (len(inside), len(todo), len(all_panos)))
    ptree = STRtree([Point(p.x, p.y) for p in all_panos])
    by_pano = {}
    for i, f in todo.items():
        cands = [all_panos[k] for k in ptree.query(Point(*f.mid).buffer(MAX_DIST))]
        p = best_pano(f, cands, tree, polys)
        if p is not None:
            by_pano.setdefault(p.id, (p, []))[1].append((i, f))
    log("%d walls seen from %d panoramas" % (sum(len(v[1]) for v in by_pano.values()), len(by_pano)))
    jobs = list(by_pano.values())
    t0 = time.time()
    with ThreadPoolExecutor(workers) as ex:
        images = ex.map(lambda job: _fetch(panos, job[0]), jobs)
        for n, ((p, fs), img) in enumerate(zip(jobs, images)):
            if img is None:
                continue
            for i, f in fs:
                rgb, share = wall_colour(rectify(f, p, img, px_per_m=PX_PER_M))
                if rgb is not None:
                    res[i] = {"raw": list(rgb), "est": False, "pano": p.id, "share": round(share, 2)}
            if save and (n + 1) % 200 == 0:
                save(res)
                rate = (n + 1) / max(time.time() - t0, 1e-6)
                log("  %d of %d panoramas, %d buildings measured (%.1f a second, %.0f min to go)" % (
                    n + 1, len(jobs), sum(1 for r in res.values() if not r["est"]), rate, (len(jobs) - n - 1) / rate / 60))
    # Unseen: the median of measured neighbours.
    measured = [i for i in res if not res[i]["est"] and i in inside]
    if measured:
        mt = STRtree([Point(*cents[i]) for i in measured])
        for i in inside:
            if i in res and not res[i]["est"]:
                continue
            near = [measured[k] for k in mt.query(Point(*cents[i]).buffer(NEIGHBOURS))]
            near = [j for j in near if math.dist(cents[j], cents[i]) <= NEIGHBOURS]
            if near:
                res[i] = {"raw": [int(v) for v in np.median([res[j]["raw"] for j in near], axis=0)], "est": True}
    for r in res.values():
        r["c"] = [int(min(255, max(0, round(v * gain)))) for v in r["raw"]]
    return res


def _fetch(panos, p):
    for attempt in range(4):
        try:
            return panos.image(p)
        except Exception as e:                       # (a slow or busy service: try again, then skip)
            time.sleep(2 ** attempt)
            err = e
    print("  skipped panorama %s: %s" % (p.id, err), file=sys.stderr)
    return None


# ---- the City's service ------------------------------------------------------------

class CityPanoramas:
    """The City of Amsterdam's panoramas: listed with `near` queries on a grid,
    images fetched small, nothing cached."""

    def __init__(self, origin, http=None, grid: float = 200.0):
        import requests
        from amsterdam.overture import wgs84_to_rd_np
        from generate_buildings import rd_to_wgs84
        self.origin, self.grid = origin, grid
        self.http = http or requests.Session()
        self.http.headers["User-Agent"] = "gta-amsterdam-colours/1.0"
        self._to_rd, self._to_wgs = wgs84_to_rd_np, rd_to_wgs84

    def to_local(self, lon, lat):
        x, y = self._to_rd(np.array([lon]), np.array([lat]))
        return float(x[0]) - self.origin[0], float(y[0]) - self.origin[1]

    def near_many(self, centre, radius):
        out = {}
        r = self.grid * 0.75                           # (circles that cover the grid's squares)
        steps = int(math.ceil(radius / self.grid))
        for gx in range(-steps, steps + 1):
            for gy in range(-steps, steps + 1):
                x, y = centre[0] + gx * self.grid, centre[1] + gy * self.grid
                if math.hypot(x - centre[0], y - centre[1]) > radius + self.grid:
                    continue
                lon, lat = self._to_wgs(x + self.origin[0], y + self.origin[1])
                url, params = API, {"near": "%.7f,%.7f" % (lon, lat), "radius": int(r), "newest_in_range": "true", "page_size": 500}
                while url:
                    doc = self._get(url, params)
                    for p in parse_panoramas(doc, self.to_local):
                        out[p.id] = p
                    url, params = ((doc.get("_links") or {}).get("next") or {}).get("href"), None
        return list(out.values())

    def _get(self, url, params):
        for attempt in range(5):
            try:
                r = self.http.get(url, params=params, timeout=60)
                r.raise_for_status()
                return r.json()
            except Exception:
                time.sleep(2 ** attempt)
        raise RuntimeError("the panorama service did not answer: " + url)

    def image(self, p):
        from io import BytesIO
        from PIL import Image
        url = p.url.replace("panorama_4000.jpg", "panorama_2000.jpg").replace("panorama_8000.jpg", "panorama_2000.jpg")
        r = self.http.get(url, timeout=60)
        r.raise_for_status()
        return np.asarray(Image.open(BytesIO(r.content)).convert("RGB"))


# ---- the game's data ---------------------------------------------------------------

def load(data_dir: Path, centre, radius: float):
    """The buildings of the tiles that reach into the area (and a margin, for
    party walls and occlusion), and where each one is: (file, chunk, index)."""
    index = json.loads((data_dir / "index.json").read_text())
    tile = float(index["tile"])                        # metres
    buildings, refs = [], []
    for f in sorted((data_dir / "tiles").glob("*.json")):
        i, j = (int(v) for v in f.stem.split("_"))
        cx, cy = (i + 0.5) * tile, (j + 0.5) * tile
        if abs(cx - centre[0]) > radius + tile and abs(cy - centre[1]) > radius + tile:
            continue
        if math.hypot(max(0.0, abs(cx - centre[0]) - tile / 2), max(0.0, abs(cy - centre[1]) - tile / 2)) > radius + 100:
            continue
        t = json.loads(f.read_text())
        for key, c in t["chunks"].items():
            for k, bd in enumerate(c.get("buildings", [])):
                buildings.append(bd)
                refs.append((f.name, key, k))
    return index, buildings, refs


def write(data_dir: Path, refs: list, res: dict) -> int:
    """Put each result's "c" in its tile record; buildings without a result lose any old "c"."""
    by_file = {}
    for i, (name, key, k) in enumerate(refs):
        by_file.setdefault(name, []).append((i, key, k))
    n = 0
    for name, items in by_file.items():
        path = data_dir / "tiles" / name
        t = json.loads(path.read_text())
        for i, key, k in items:
            bd = t["chunks"][key]["buildings"][k]
            if i in res:
                bd["c"] = res[i]["c"]
                n += 1
            else:
                bd.pop("c", None)
        path.write_text(json.dumps(t, separators=(",", ":"), ensure_ascii=False))
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("data", type=Path, nargs="?", default=Path("godot-city/data"))
    ap.add_argument("--radius", type=float, default=2000.0, help="metres round the Dam")
    ap.add_argument("--results", type=Path, default=Path("out/pano_colours.json"))
    ap.add_argument("--recalibrate", action="store_true", help="no measuring: the colours again from the stored results")
    a = ap.parse_args()
    index = json.loads((a.data / "index.json").read_text())
    centre = (index["start"][0] / 10.0, index["start"][1] / 10.0)          # the Dam (metres)
    index, buildings, refs = load(a.data, centre, a.radius)
    a.results.parent.mkdir(parents=True, exist_ok=True)
    key = lambda i: "%s/%s/%d" % refs[i]
    done = {}
    if a.results.exists():
        old = json.loads(a.results.read_text())
        at = {key(i): i for i in range(len(refs))}
        done = {at[k]: v for k, v in old.items() if k in at}

    def save(res):
        a.results.write_text(json.dumps({key(i): v for i, v in res.items()}))
    if a.recalibrate:
        res = done
    else:
        res = measure(buildings, CityPanoramas(index["origin"]), centre, a.radius, gain=1.0, done=done, save=save)
    fix = calibrate([r["raw"] for r in res.values() if not r["est"]])
    for r in res.values():
        r["c"] = fix(r["raw"])
    save(res)
    n = write(a.data, refs, res)
    est = sum(1 for r in res.values() if r["est"])
    print("%d buildings coloured (%d measured, %d from their neighbours)" % (n, n - est, est))


if __name__ == "__main__":
    main()
