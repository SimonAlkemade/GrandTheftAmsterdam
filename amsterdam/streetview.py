"""Photo facades from the City of Amsterdam's open 360-degree street panoramas.

For every street-facing wall of a building we pick the panorama that sees it
most squarely, cut the wall out of the equirectangular image as a straight-on
(rectified) photo, and pack the photos of a tile into JPEG atlas pages that
the game puts on the walls instead of the generated window patterns.

Coordinates are metres east (x) and north (y) of the city ORIGIN, the same as
the tile data divided by ten; heights are metres above the street.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np
from shapely.geometry import LineString, Point, Polygon
from shapely.strtree import STRtree

PX_PER_M = 32            # photo resolution on the wall
MIN_WIDTH = 3.0          # narrower walls are not worth a photo
MAX_DIST = 28.0          # metres from camera to wall centre
MIN_DIST = 4.0
MAX_OBLIQUE = math.radians(55)   # angle between the view and the wall's normal
CAMERA_H = 2.6           # camera height above the street on the city's car


@dataclass
class Facade:
    building: int        # index in the tile's building list
    edge: int            # edge index (in the building's outer ring; for gabled lots 0 = c0c1, 1 = c2c3)
    a: tuple             # wall start, seen from outside left to right
    b: tuple             # wall end
    top: float           # wall height (ridge for a gable end)
    normal: tuple        # unit outward normal

    @property
    def mid(self):
        return ((self.a[0] + self.b[0]) / 2, (self.a[1] + self.b[1]) / 2)

    @property
    def width(self):
        return math.dist(self.a, self.b)


@dataclass
class Pano:
    id: str
    x: float
    y: float
    heading: float       # bearing (deg, clockwise from north) of the image's centre column
    url: str
    h: float = CAMERA_H
    extra: dict = field(default_factory=dict)


def footprint(bd) -> list:
    """The outer ring of a tile building in metres."""
    flat = bd["g"] if "g" in bd else bd["r"][0]
    return [(flat[i] / 10.0, flat[i + 1] / 10.0) for i in range(0, len(flat), 2)]


def facades(buildings: list, min_width: float = MIN_WIDTH) -> list:
    """Walls that face open space (a street, square or canal), oriented so
    that a is on the left when you look at the wall from outside."""
    polys = []
    for bd in buildings:
        try:
            p = Polygon(footprint(bd)).buffer(0)
        except Exception:
            p = Polygon()
        polys.append(p)
    tree = STRtree(polys)
    out = []
    for i, bd in enumerate(buildings):
        ring = footprint(bd)
        own = polys[i]
        if own.is_empty:
            continue
        if "g" in bd:
            edges = [(0, ring[0], ring[1]), (1, ring[2], ring[3])]   # the gable ends
            top = float(bd["h"])
        else:
            edges = [(k, ring[k], ring[(k + 1) % len(ring)]) for k in range(len(ring))]
            top = float(bd["h"])
        for k, p, q in edges:
            w = math.dist(p, q)
            if w < min_width:
                continue
            dx, dy = (q[0] - p[0]) / w, (q[1] - p[1]) / w
            mid = ((p[0] + q[0]) / 2, (p[1] + q[1]) / 2)
            n = (dy, -dx)
            if own.contains(Point(mid[0] + n[0] * 0.3, mid[1] + n[1] * 0.3)):
                n = (-n[0], -n[1])
            out_pt = Point(mid[0] + n[0] * 4.0, mid[1] + n[1] * 4.0)
            if any(polys[j].contains(out_pt) for j in tree.query(out_pt) if j != i):
                continue                   # a party wall: another building is right there
            # Seen from outside (looking along -n), "left" is the end at -right.
            right = (-n[1], n[0])
            a, b = (p, q) if (q[0] - p[0]) * right[0] + (q[1] - p[1]) * right[1] > 0 else (q, p)
            out.append(Facade(i, k, a, b, top, n))
    return out


def view_score(f: Facade, pano: Pano):
    """Lower is better; None when the panorama cannot see the wall usefully."""
    vx, vy = f.mid[0] - pano.x, f.mid[1] - pano.y
    d = math.hypot(vx, vy)
    if d < MIN_DIST or d > MAX_DIST:
        return None
    facing = -(vx * f.normal[0] + vy * f.normal[1]) / d     # 1 = square on
    if facing < math.cos(MAX_OBLIQUE):
        return None
    return d / MAX_DIST + (1 - facing) * 2


def occluded(f: Facade, pano: Pano, buildings_tree: STRtree, polys: list) -> bool:
    """Whether another building stands between the camera and the wall."""
    ray = LineString([(pano.x, pano.y), (f.mid[0] - f.normal[0] * -0.2, f.mid[1] - f.normal[1] * -0.2)])
    for j in buildings_tree.query(ray):
        if j != f.building and polys[j].intersects(ray):
            return True
    return False


def best_pano(f: Facade, panos: list, tree=None, polys=None):
    best, best_s = None, None
    for p in panos:
        s = view_score(f, p)
        if s is None or (tree is not None and occluded(f, p, tree, polys)):
            continue
        if best_s is None or s < best_s:
            best, best_s = p, s
    return best


def _bilinear(img: np.ndarray, col: np.ndarray, row: np.ndarray) -> np.ndarray:
    H, W = img.shape[:2]
    col = np.mod(col, W)
    row = np.clip(row, 0, H - 1.001)
    c0 = np.floor(col).astype(int); r0 = np.floor(row).astype(int)
    c1 = (c0 + 1) % W; r1 = r0 + 1
    fc = (col - c0)[..., None]; fr = (row - r0)[..., None]
    top = img[r0, c0] * (1 - fc) + img[r0, c1] * fc
    bot = img[r1, c0] * (1 - fc) + img[r1, c1] * fc
    return top * (1 - fr) + bot * fr


def project(pano: Pano, x, y, z, width: int, height: int):
    """Equirectangular pixel (col, row) of world points; z is height above the street."""
    dx = x - pano.x; dy = y - pano.y; dz = z - pano.h
    bearing = np.arctan2(dx, dy)                         # clockwise from north
    pitch = np.arctan2(dz, np.hypot(dx, dy))
    rel = (bearing - math.radians(pano.heading) + math.pi) % (2 * math.pi)   # 0..2pi, pi = centre
    return rel / (2 * math.pi) * width, (0.5 - pitch / math.pi) * height


def rectify(f: Facade, pano: Pano, equirect: np.ndarray, px_per_m: int = PX_PER_M) -> np.ndarray:
    """The wall as a straight-on photo: columns run a -> b, rows top -> street."""
    W = max(8, int(round(f.width * px_per_m)))
    H = max(8, int(round(f.top * px_per_m)))
    u = (np.arange(W) + 0.5) / W
    v = (np.arange(H) + 0.5) / H
    uu, vv = np.meshgrid(u, v)
    x = f.a[0] + (f.b[0] - f.a[0]) * uu
    y = f.a[1] + (f.b[1] - f.a[1]) * uu
    z = f.top * (1 - vv)
    col, row = project(pano, x, y, z, equirect.shape[1], equirect.shape[0])
    out = _bilinear(equirect.astype(np.float32), col, row)
    return np.clip(out, 0, 255).astype(np.uint8)


class AtlasPacker:
    """Shelf packing of facade photos into square pages."""

    def __init__(self, size: int = 2048, pad: int = 2):
        self.size, self.pad = size, pad
        self.pages = []          # numpy images
        self._cursor = None      # (page, x, y, shelf height)

    def _new_page(self):
        self.pages.append(np.zeros((self.size, self.size, 3), np.uint8))
        self._cursor = [len(self.pages) - 1, 0, 0, 0]

    def add(self, img: np.ndarray):
        """Place an image; returns (page, u0, v0, u1, v1) in 0..1 page UVs (v down)."""
        h, w = img.shape[:2]
        if w > self.size or h > self.size:
            k = self.size / max(w, h)
            from PIL import Image
            img = np.asarray(Image.fromarray(img).resize((max(1, int(w * k)), max(1, int(h * k))), Image.LANCZOS))
            h, w = img.shape[:2]
        if self._cursor is None:
            self._new_page()
        page, x, y, shelf = self._cursor
        if x + w > self.size:
            x, y, shelf = 0, y + shelf + self.pad, 0
        if y + h > self.size:
            self._new_page()
            page, x, y, shelf = self._cursor
        self.pages[page][y:y + h, x:x + w] = img
        self._cursor = [page, x + w + self.pad, y, max(shelf, h)]
        s = float(self.size)
        return page, x / s, y / s, (x + w) / s, (y + h) / s


# ---- the City of Amsterdam panorama API ------------------------------------------
# Not yet exercised against the live service (it was unreachable from the
# build machine): field names follow its documented HAL+JSON response and are
# read defensively. Check them on the first real response before a full run.

API = "https://api.data.amsterdam.nl/panorama/panoramas/"


def parse_panoramas(doc: dict, to_local) -> list:
    """Panoramas from one API response. to_local(lon, lat) -> (x, y) metres."""
    items = doc.get("_embedded", {}).get("panoramas", doc.get("results", []))
    out = []
    for it in items:
        coords = (it.get("geometry") or {}).get("coordinates")
        links = it.get("_links", {})
        url = None
        for key in ("equirectangular_medium", "equirectangular_full", "equirectangular_small"):
            if key in links:
                url = links[key]["href"] if isinstance(links[key], dict) else links[key]
                break
        if not coords or url is None:
            continue
        x, y = to_local(coords[0], coords[1])
        out.append(Pano(str(it.get("pano_id", it.get("id"))), x, y, float(it.get("heading", 0.0)), url,
                        extra={"timestamp": it.get("timestamp")}))
    return out
