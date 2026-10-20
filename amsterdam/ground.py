"""Streets and canals: a cobbled ground with the water cut out of it, a water
surface below street level, and brick quay walls down to it."""
from __future__ import annotations

import numpy as np
from shapely.geometry import box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

from .materials import uv_scale
from .mesh import MeshBuilder, UP, shapely_parts

QUAY_DROP = 1.4         # street to water surface, metres


def ground_with_water(bounds, water, street_z: float) -> MeshBuilder:
    """bounds: (minx, miny, maxx, maxy); water: shapely geometry, same frame."""
    area = box(*bounds)
    water = unary_union([w.buffer(0) for w in water]).intersection(area) if water else None
    land = area.difference(water) if water is not None else area
    wz = street_z - QUAY_DROP
    mesh = MeshBuilder()
    flat_uv = lambda mat: (lambda p: p[:, :2] / uv_scale(mat))
    for part in shapely_parts(land):
        mesh.add_polygon3d("ground_cobble", _lift(part.exterior.coords, street_z),
                           [_lift(h.coords, street_z) for h in part.interiors], UP,
                           flat_uv("ground_cobble"))
    if water is None:
        return mesh
    for part in shapely_parts(water):
        part = orient(part, 1.0)
        mesh.add_polygon3d("water", _lift(part.exterior.coords, wz),
                           [_lift(h.coords, wz) for h in part.interiors], UP, flat_uv("water"))
        for ring in [part.exterior, *part.interiors]:
            _quay(mesh, np.asarray(ring.coords), street_z, wz, area)
    return mesh


def _lift(coords, z):
    c = np.asarray(coords)[:-1]
    return np.column_stack([c[:, 0], c[:, 1], np.full(len(c), z)])


def _quay(mesh, ring, top, bottom, area):
    """Brick wall from street down to the water, facing the water, with a
    stone kerb along the top. Edges on the tile boundary are left open."""
    edge = area.boundary.buffer(0.05)
    tile = uv_scale("brick_dark")
    run = 0.0
    for a, b in zip(ring[:-1], ring[1:]):
        d = b - a
        length = float(np.hypot(*d))
        if length < 0.05:
            continue
        if edge.contains(box(*np.minimum(a, b), *np.maximum(a, b)).buffer(0.01)):
            continue
        # Water lies to the left of a CCW exterior (and of a CW hole), so the
        # wall faces left: n = (-dy, dx).
        n = np.array([-d[1], d[0], 0.0]) / length
        quad = np.array([[a[0], a[1], bottom], [b[0], b[1], bottom],
                         [b[0], b[1], top], [a[0], a[1], top]])
        uv = np.array([[run, bottom], [run + length, bottom],
                       [run + length, top], [run, top]]) / tile
        mesh.add_triangles("brick_dark", quad, uv, np.array([[0, 1, 2], [0, 2, 3]]), n)
        kerb = np.array([[a[0], a[1], top + 0.06], [b[0], b[1], top + 0.06],
                         [b[0] + n[0] * 0.25, b[1] + n[1] * 0.25, top + 0.06],
                         [a[0] + n[0] * 0.25, a[1] + n[1] * 0.25, top + 0.06]])
        mesh.add_triangles("stone", kerb, kerb[:, :2] / uv_scale("stone"),
                           np.array([[0, 1, 2], [0, 2, 3]]), UP)
        run += length
