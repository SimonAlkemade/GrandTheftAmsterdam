"""Generate 3D building models with Tripo from photos cut out of the City of
Amsterdam's 360-degree street panoramas.

    python generate_buildings.py godot-city/data out/tripo --tiles -1_0 --limit 20

For each building in the tiles: pick its widest street-facing wall, find the
panorama that sees it most squarely, cut the wall out as a straight-on photo,
send the photo to Tripo (image to 3D) and save the model as
out/tripo/<tile>/<building>.glb. Progress is kept in out/tripo/manifest.json,
so a second run continues where the first stopped.

Exit codes: 0 done, 3 Tripo credits ran out (everything so far is kept),
4 a service could not be reached.
"""
from __future__ import annotations

import argparse
import io
import json
import math
import sys
from pathlib import Path

import numpy as np
import requests
from PIL import Image

from amsterdam.streetview import API as PANO_API, best_pano, facades, parse_panoramas, rectify
from amsterdam.tripo import OutOfCredits, Tripo, TripoError

RD_TO_WGS = None


def rd_to_wgs84(x, y):
    """RD New -> WGS84 (Schreutelkamp & Strang van Hees), good to ~1 m."""
    dx = (x - 155000) * 1e-5
    dy = (y - 463000) * 1e-5
    lat = 52.15517440 + (3235.65389 * dy - 32.58297 * dx ** 2 - 0.24750 * dy ** 2 - 0.84978 * dx ** 2 * dy
                         - 0.06550 * dy ** 3 - 0.01709 * dx ** 2 * dy ** 2 - 0.00738 * dx + 0.00530 * dx ** 4
                         - 0.00039 * dx ** 2 * dy ** 3 + 0.00033 * dx ** 4 * dy - 0.00012 * dx * dy) / 3600
    lon = 5.38720621 + (5260.52916 * dx + 105.94684 * dx * dy + 2.45656 * dx * dy ** 2 - 0.81885 * dx ** 3
                        + 0.05594 * dx * dy ** 3 - 0.05607 * dx ** 3 * dy + 0.01199 * dy - 0.00256 * dx ** 3 * dy ** 2
                        + 0.00128 * dx * dy ** 4 + 0.00022 * dy ** 2 - 0.00022 * dx ** 2 + 0.00026 * dx ** 5) / 3600
    return lon, lat


class Panoramas:
    """Panorama lookup and image download, cached on disk."""

    def __init__(self, origin, cache: Path, http=None):
        self.origin, self.cache = origin, cache
        self.http = http or requests.Session()
        cache.mkdir(parents=True, exist_ok=True)
        from amsterdam.overture import wgs84_to_rd_np
        self._to_rd = wgs84_to_rd_np

    def to_local(self, lon, lat):
        x, y = self._to_rd(np.array([lon]), np.array([lat]))
        return float(x[0]) - self.origin[0], float(y[0]) - self.origin[1]

    def near(self, x, y, radius=25):
        lon, lat = rd_to_wgs84(x + self.origin[0], y + self.origin[1])
        r = self.http.get(PANO_API, params={"near": "%.7f,%.7f" % (lon, lat), "radius": radius,
                                            "newest_in_range": "true", "page_size": 50}, timeout=60)
        r.raise_for_status()
        return parse_panoramas(r.json(), self.to_local)

    def image(self, pano) -> np.ndarray:
        path = self.cache / ("%s.jpg" % pano.id)
        if not path.exists():
            r = self.http.get(pano.url, timeout=120)
            r.raise_for_status()
            path.write_bytes(r.content)
        return np.asarray(Image.open(path).convert("RGB"))


def main_facade(fs):
    """Each building's widest street wall."""
    best = {}
    for f in fs:
        if f.building not in best or f.width > best[f.building].width:
            best[f.building] = f
    return best


def run(data_dir: Path, out: Path, tiles, limit, panos: Panoramas, tripo: Tripo, log=print) -> int:
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    save = lambda: manifest_path.write_text(json.dumps(manifest, indent=1))
    done = 0
    for key in tiles:
        tile = json.loads((data_dir / "tiles" / ("%s.json" % key)).read_text())
        for b, f in sorted(main_facade(facades(tile.get("buildings", []))).items()):
            mid = "%s/%d" % (key, b)
            if manifest.get(mid, {}).get("status") in ("done", "no_view"):
                continue
            if limit is not None and done >= limit:
                save()
                return 0
            pano = best_pano(f, panos.near(f.mid[0] + f.normal[0] * 10, f.mid[1] + f.normal[1] * 10))
            if pano is None:
                manifest[mid] = {"status": "no_view"}
                continue
            photo = rectify(f, pano, panos.image(pano))
            jpg = out / key / ("%d.jpg" % b)
            jpg.parent.mkdir(parents=True, exist_ok=True)
            Image.fromarray(photo).save(jpg, quality=92)
            entry = {"status": "photo", "pano": pano.id, "facade": [f.a, f.b, f.top, f.normal]}
            manifest[mid] = entry
            try:
                task = tripo.wait(tripo.image_to_model(tripo.upload(str(jpg))))
                glb = out / key / ("%d.glb" % b)
                r = tripo.http.get(Tripo.model_url(task), timeout=300)
                r.raise_for_status()
                glb.write_bytes(r.content)
                entry.update(status="done", task=task.get("task_id"))
                done += 1
                log("built %s (%d this run)" % (mid, done))
            except OutOfCredits as e:
                entry["status"] = "photo"          # the photo is kept; the model is retried next run
                save()
                log("Tripo credits ran out after %d models this run: %s" % (done, e))
                return 3
            except TripoError as e:
                entry.update(status="failed", error=str(e))
                log("failed %s: %s" % (mid, e))
            save()
    save()
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--tiles", nargs="+", required=True)
    ap.add_argument("--limit", type=int, default=None, help="models to make this run")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    origin = json.loads((a.data / "index.json").read_text())["origin"]
    try:
        tripo = Tripo()
        log_balance = tripo.balance()
        print("Tripo balance:", log_balance)
    except OutOfCredits:
        print("Tripo credits ran out before starting")
        return 3
    except (TripoError, requests.RequestException) as e:
        print("Tripo unreachable:", e)
        return 4
    try:
        return run(a.data, a.out, a.tiles, a.limit, Panoramas(origin, a.out / "panoramas"), tripo)
    except requests.RequestException as e:
        print("panorama service unreachable:", e)
        return 4


if __name__ == "__main__":
    sys.exit(main())
