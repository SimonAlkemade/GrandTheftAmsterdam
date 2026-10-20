"""Buildings and water from Overture Maps (ODbL / CDLA, mostly OpenStreetMap).

Overture gives footprints with height, floors and sometimes roof shape, but
no construction year and no LoD2 roofs. So this is a coarser skeleton than
3D BAG: walls come straight from the footprint, and roofs are either the
tagged shape or, in the old centre, a heuristic: a narrow, deep, rectangular
lot gets the canal-house gable roof with its ridge running back from the
street. The facade upscaler then treats both sources the same way.
"""
from __future__ import annotations

import zlib

import numpy as np
from shapely import wkb
from shapely.geometry import Polygon
from shapely.geometry.polygon import orient

from .sources import Building, Surface

FLOOR_H = 3.1
GROUND_Z = 0.5          # NAP, roughly street level in the canal ring
GABLE_SHAPES = {"gabled", "saltbox", "gambrel"}


def wgs84_to_rd_np(lon: np.ndarray, lat: np.ndarray):
    """Vectorised Schreutelkamp & Strang van Hees WGS84 -> RD New (~1 m)."""
    dp = 0.36 * (lat - 52.15517440)
    dl = 0.36 * (lon - 5.38720621)
    x = (155000 + 190094.945 * dl - 11832.228 * dp * dl - 114.221 * dp ** 2 * dl
         - 32.391 * dl ** 3 - 0.705 * dp - 2.340 * dp ** 3 * dl - 0.608 * dp * dl ** 3
         - 0.008 * dl ** 2 + 0.148 * dp ** 2 * dl ** 3)
    y = (463000 + 309056.544 * dp + 3638.893 * dl ** 2 + 73.077 * dp ** 2
         - 157.984 * dp * dl ** 2 + 59.788 * dp ** 3 + 0.433 * dl - 6.439 * dp ** 2 * dl ** 2
         - 0.032 * dp * dl + 0.092 * dl ** 4 - 0.054 * dp * dl ** 4)
    return x, y


def to_rd(geom):
    """Shapely lon/lat geometry -> RD New metres."""
    from shapely import transform
    def f(c):
        x, y = wgs84_to_rd_np(c[:, 0], c[:, 1])
        return np.stack([x, y], axis=1)
    return transform(geom, f)


def _rng(key: str) -> float:
    return (zlib.crc32(key.encode()) % 10000) / 10000.0


def _height(row, key) -> float:
    h = row.get("height")
    if h is not None and np.isfinite(h) and h > 2:
        return float(h)
    n = row.get("num_floors")
    if n is not None and n > 0:
        return float(n) * FLOOR_H + 1.5
    return 11.0 + 6.0 * _rng(key)        # untagged: a 3-5 storey canal house


def _prism(poly: Polygon, z0: float, z1: float) -> list:
    poly = orient(poly, 1.0)             # exterior CCW, holes CW
    out = []
    for ring in [poly.exterior, *poly.interiors]:
        c = np.asarray(ring.coords)[:-1]
        for a, b in zip(c, np.roll(c, -1, axis=0)):
            if np.hypot(*(b - a)) < 0.05:
                continue
            out.append(Surface("wall", np.array([[a[0], a[1], z0], [b[0], b[1], z0],
                                                  [b[0], b[1], z1], [a[0], a[1], z1]])))
    lift = lambda r, z: np.column_stack([np.asarray(r.coords)[:-1], np.full(len(r.coords) - 1, z)])
    out.append(Surface("roof", lift(poly.exterior, z1), [lift(h, z1) for h in poly.interiors]))
    out.append(Surface("ground", lift(poly.exterior, z0)[::-1],
                       [lift(h, z0)[::-1] for h in poly.interiors]))
    return out


def _gabled(rect: Polygon, z0: float, eave: float, pitch: float) -> list:
    """Gable roof on a rectangle, ridge along its long axis."""
    c = np.asarray(orient(rect, 1.0).exterior.coords)[:-1]
    edges = [np.hypot(*(c[(i + 1) % 4] - c[i])) for i in range(4)]
    s = int(np.argmin(edges[:2]))        # c[s] -> c[s+1] is a short side
    p = [c[(s + k) % 4] for k in range(4)]
    w = edges[s]
    ridge = eave + pitch * w / 2
    m0, m1 = (p[0] + p[1]) / 2, (p[2] + p[3]) / 2
    P = lambda q, z: [q[0], q[1], z]
    faces = [
        ("wall", [P(p[0], z0), P(p[1], z0), P(p[1], eave), P(m0, ridge), P(p[0], eave)]),
        ("wall", [P(p[2], z0), P(p[3], z0), P(p[3], eave), P(m1, ridge), P(p[2], eave)]),
        ("wall", [P(p[1], z0), P(p[2], z0), P(p[2], eave), P(p[1], eave)]),
        ("wall", [P(p[3], z0), P(p[0], z0), P(p[0], eave), P(p[3], eave)]),
        ("roof", [P(p[1], eave), P(p[2], eave), P(m1, ridge), P(m0, ridge)]),
        ("roof", [P(p[3], eave), P(p[0], eave), P(m0, ridge), P(m1, ridge)]),
        ("ground", [P(q, z0) for q in p[::-1]]),
    ]
    centre = np.array([*rect.centroid.coords[0], (z0 + eave) / 2])
    out = []
    for kind, pts in faces:
        a = np.asarray(pts, float)
        n = np.cross(a[1] - a[0], a[2] - a[0])
        if n @ (a.mean(0) - centre) < 0:
            a = a[::-1]
        out.append(Surface(kind, a))
    return out


def building_from_row(row: dict) -> Building | None:
    if row.get("is_underground"):
        return None
    geom = to_rd(wkb.loads(row["geometry"]))
    parts = list(geom.geoms) if geom.geom_type == "MultiPolygon" else [geom]
    key = str(row.get("id"))
    h = _height(row, key)
    z0 = GROUND_Z
    if row.get("class") == "houseboat":     # moored at water level, one storey
        from .ground import QUAY_DROP
        z0 = GROUND_Z - QUAY_DROP + 0.3
        h = 2.6
        row = dict(row, roof_shape="flat")
    shape = row.get("roof_shape")
    surfaces = []
    for poly in parts:
        poly = poly.buffer(0)
        if poly.is_empty or poly.area < 6:
            continue
        rect = poly.minimum_rotated_rectangle
        rc = np.asarray(rect.exterior.coords)
        sides = sorted([np.hypot(*(rc[1] - rc[0])), np.hypot(*(rc[2] - rc[1]))])
        rectangular = poly.area / max(rect.area, 1e-9) > 0.88 and not poly.interiors
        narrow = sides[0] <= 11.0 and sides[1] >= 1.3 * sides[0]
        if rectangular and (shape in GABLE_SHAPES or (shape is None and narrow)):
            roof_h = row.get("roof_height")
            pitch = 1.1 + 0.4 * _rng(key + "p")
            if roof_h is not None and np.isfinite(roof_h) and 0 < roof_h < h:
                eave = z0 + h - roof_h
                pitch = 2 * roof_h / sides[0]
            else:
                eave = z0 + max(h - pitch * sides[0] / 2, 4.0)
            surfaces += _gabled(rect, z0, eave, pitch)
        else:
            surfaces += _prism(poly, z0, z0 + h)
    if not surfaces:
        return None
    return Building(id=key, surfaces=surfaces, year=None, ground_z=z0)
