"""Download Overture Maps buildings and water for an area (no account needed).

    python fetch_overture.py --center 52.3725 4.8865 --size 600 -o data/grachtengordel
    python build_overture.py data/grachtengordel/buildings.pkl data/grachtengordel/water.pkl \
        --center 52.3725 4.8865 --size 450 400 -o out/amsterdam.glb

Overture publishes GeoParquet on a public S3 bucket. Rather than downloading
whole files (~500 MB each), this reads only each file's parquet footer,
finds the row groups whose bbox statistics overlap the area, and fetches
just those over HTTP range requests. For Amsterdam that is a few MB.

Data: Overture Maps Foundation (buildings: ODbL, mostly OpenStreetMap;
water: ODbL). Credit OpenStreetMap contributors and Overture Maps.
"""
import argparse
import io
import math
import os
import pickle
import re
import struct
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pyarrow.compute as pc
import pyarrow.parquet as pq
import requests

BUCKET = "https://overturemaps-us-west-2.s3.us-west-2.amazonaws.com/"
SESSION = requests.Session()
if os.environ.get("REQUESTS_CA_BUNDLE") is None and os.path.exists("/root/.ccr/ca-bundle.crt"):
    SESSION.verify = "/root/.ccr/ca-bundle.crt"

THEMES = {
    "buildings": ("theme=buildings/type=building",
                  ["id", "geometry", "height", "num_floors", "roof_shape", "roof_height",
                   "is_underground", "class"]),
    "water": ("theme=base/type=water", ["id", "geometry", "subtype", "class"]),
}


class RangeFile(io.RawIOBase):
    """A seekable, read-only S3 object, fetched lazily with range requests."""

    def __init__(self, url, size):
        self.url, self.size, self.pos = url, size, 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.size + off}[whence]
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0:
            return b""
        data = _get(self.url, self.pos, self.pos + n - 1)
        self.pos += len(data)
        return data

    def readinto(self, b):
        d = self.read(len(b))
        b[:len(d)] = d
        return len(d)


def _get(url, start, end, tries=4):
    for attempt in range(tries):
        try:
            r = SESSION.get(url, headers={"Range": f"bytes={start}-{end}"}, timeout=120)
            r.raise_for_status()
            return r.content
        except requests.RequestException:
            if attempt == tries - 1:
                raise


def latest_release() -> str:
    t = SESSION.get(BUCKET, params={"list-type": "2", "prefix": "release/", "delimiter": "/"},
                    timeout=60).text
    return sorted(re.findall(r"<Prefix>(release/[^<]+/)</Prefix>", t))[-1]


def list_files(prefix):
    keys, token = [], None
    while True:
        q = {"list-type": "2", "prefix": prefix}
        if token:
            q["continuation-token"] = token
        t = SESSION.get(BUCKET, params=q, timeout=60).text
        keys += [(k, int(s)) for k, s in
                 re.findall(r"<Key>([^<]*\.parquet)</Key>.*?<Size>(\d+)</Size>", t)]
        m = re.search(r"<NextContinuationToken>([^<]*)<", t)
        if not m:
            return keys
        token = m.group(1)


def _footer(key_size):
    key, size = key_size
    url = BUCKET + key
    tail = _get(url, size - 8, size - 1)
    n = struct.unpack("<I", tail[:4])[0]
    return key, size, b"PAR1" + _get(url, size - 8 - n, size - 9) + tail


def matching_row_groups(prefix, bbox):
    W, S, E, N = bbox
    out = []
    with ThreadPoolExecutor(32) as ex:   # threads only fetch; parsing stays here
        for key, size, blob in ex.map(_footer, list_files(prefix)):
            md = pq.ParquetFile(io.BytesIO(blob)).metadata
            names = [md.schema.column(i).path for i in range(md.num_columns)]
            cols = {n: names.index("bbox." + n) for n in ("xmin", "xmax", "ymin", "ymax")}
            hits = []
            for g in range(md.num_row_groups):
                st = {n: md.row_group(g).column(i).statistics for n, i in cols.items()}
                if any(s is None or not s.has_min_max for s in st.values()):
                    continue
                if (st["xmax"].max >= W and st["xmin"].min <= E
                        and st["ymax"].max >= S and st["ymin"].min <= N):
                    hits.append(g)
            if hits:
                out.append((key, size, hits))
    return out


def fetch(prefix, columns, bbox):
    W, S, E, N = bbox
    rows = []
    for key, size, groups in matching_row_groups(prefix, bbox):
        t = pq.ParquetFile(RangeFile(BUCKET + key, size)).read_row_groups(
            groups, columns=columns + ["bbox"])
        b = t.column("bbox")
        f = lambda n: pc.struct_field(b, n)
        keep = pc.and_(pc.and_(pc.greater_equal(f("xmax"), W), pc.less_equal(f("xmin"), E)),
                       pc.and_(pc.greater_equal(f("ymax"), S), pc.less_equal(f("ymin"), N)))
        rows += t.filter(keep).drop(["bbox"]).to_pylist()
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--center", nargs=2, type=float, required=True, metavar=("LAT", "LON"))
    ap.add_argument("--size", type=float, default=600, help="square side in metres")
    ap.add_argument("--release", help="e.g. release/2026-09-23.1/ (default: latest)")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args(argv)
    lat, lon = a.center
    dlat = a.size / 2 / 111_200
    dlon = a.size / 2 / (111_320 * math.cos(math.radians(lat)))
    bbox = (lon - dlon, lat - dlat, lon + dlon, lat + dlat)
    release = a.release or latest_release()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for name, (theme, cols) in THEMES.items():
        rows = fetch(release + theme + "/", cols, bbox)
        with open(out / f"{name}.pkl", "wb") as f:
            pickle.dump(rows, f)
        print(f"{name}: {len(rows)} rows")
    (out / "SOURCE.txt").write_text(
        f"Overture Maps {release} (ODbL). (c) OpenStreetMap contributors, Overture Maps "
        f"Foundation.\nbbox lon/lat: {bbox}\n")


if __name__ == "__main__":
    sys.exit(main())
