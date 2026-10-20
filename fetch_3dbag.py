"""Download 3D BAG buildings (LoD 2.2, CC BY 4.0) for an area of Amsterdam.

    python fetch_3dbag.py --center 52.3731 4.8926 --size 400 -o data/dam
    python fetch_3dbag.py --bbox 121000 487000 121400 487400 -o data/dam
    python build_city.py data/dam -o out/dam.glb

Pages from the 3D BAG OGC API are saved as they arrive (data/dam/page_0001.json,
...), so an interrupted download resumes where it stopped. This is the same
building data the 3d.amsterdam.nl viewer shows.

If the API shape has changed, the fallback is manual: download the CityJSON
tiles for your area from https://3dbag.nl (the tile viewer has a download
button per tile) and pass those files to build_city.py.
"""
import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.3dbag.nl/collections/pand/items"


def wgs84_to_rd(lat: float, lon: float) -> tuple[float, float]:
    """WGS84 -> RD New (EPSG:28992), Schreutelkamp & Strang van Hees
    polynomial; good to about a metre, plenty for choosing a bbox."""
    dp = 0.36 * (lat - 52.15517440)
    dl = 0.36 * (lon - 5.38720621)
    R = {(0, 1): 190094.945, (1, 1): -11832.228, (2, 1): -114.221, (0, 3): -32.391,
         (1, 0): -0.705, (3, 1): -2.340, (1, 3): -0.608, (0, 2): -0.008, (2, 3): 0.148}
    S = {(1, 0): 309056.544, (0, 2): 3638.893, (2, 0): 73.077, (1, 2): -157.984,
         (3, 0): 59.788, (0, 1): 0.433, (2, 2): -6.439, (1, 1): -0.032,
         (0, 4): 0.092, (1, 4): -0.054}
    x = 155000 + sum(c * dp ** p * dl ** q for (p, q), c in R.items())
    y = 463000 + sum(c * dp ** p * dl ** q for (p, q), c in S.items())
    return x, y


def get_json(url: str, tries: int = 4) -> dict:
    req = urllib.request.Request(url, headers={
        "Accept": "application/city+json, application/json",
        "User-Agent": "gta-amsterdam-fetch/1.0"})
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except Exception as e:  # network hiccup: back off and retry
            if attempt == tries - 1:
                raise
            wait = 2 ** (attempt + 1)
            print(f"  {e}; retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)


def next_link(page: dict) -> str | None:
    for link in page.get("links", []):
        if link.get("rel") == "next":
            return link["href"]
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--bbox", nargs=4, type=float, metavar=("MINX", "MINY", "MAXX", "MAXY"),
                   help="RD New metres")
    g.add_argument("--center", nargs=2, type=float, metavar=("LAT", "LON"))
    ap.add_argument("--size", type=float, default=400, help="square side in metres (with --center)")
    ap.add_argument("-o", "--out", required=True, help="output folder")
    ap.add_argument("--limit", type=int, default=100, help="buildings per page")
    a = ap.parse_args(argv)

    if a.center:
        x, y = wgs84_to_rd(*a.center)
        h = a.size / 2
        bbox = (x - h, y - h, x + h, y + h)
    else:
        bbox = tuple(a.bbox)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    url = API + "?" + urllib.parse.urlencode(
        {"bbox": ",".join(f"{v:.1f}" for v in bbox), "limit": a.limit})
    print(f"bbox RD {tuple(round(v) for v in bbox)}")
    n, total = 0, 0
    while url:
        n += 1
        path = out / f"page_{n:04d}.json"
        if path.exists():                       # resume
            page = json.loads(path.read_text())
        else:
            page = get_json(url)
            path.write_text(json.dumps(page))
        total += len(page.get("features", []))
        print(f"  page {n}: {total} buildings")
        url = next_link(page)
    (out / "SOURCE.txt").write_text(
        "3D BAG (https://3dbag.nl), CC BY 4.0. Credit: 3D BAG by the 3D geoinformation\n"
        f"group, TU Delft / 3DGI. bbox RD New: {bbox}\n")
    print(f"done: {total} buildings in {out}/")


if __name__ == "__main__":
    sys.exit(main())
