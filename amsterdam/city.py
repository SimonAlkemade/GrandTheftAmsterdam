"""Whole-district assembly: party walls, facades, roofs, ground."""
from __future__ import annotations

import random
from collections import defaultdict
from dataclasses import dataclass, field

import numpy as np

from .facade import FacadeBuilder, choose_style, wall_shape
from .materials import uv_scale
from .mesh import MeshBuilder, UP
from .sources import Building, Surface


@dataclass
class District:
    origin: np.ndarray                         # RD New point at scene (0, 0, 0)
    nodes: list = field(default_factory=list)  # (name, MeshBuilder, extras)

    def triangle_count(self) -> int:
        return sum(m.triangle_count() for _, m, _ in self.nodes)


def _recentre(buildings, origin) -> list:
    out = []
    for b in buildings:
        surfaces = [Surface(s.kind, s.ring - origin, [h - origin for h in s.holes])
                    for s in b.surfaces]
        g = b.ground_z - origin[2] if b.ground_z is not None else None
        out.append(Building(b.id, surfaces, b.year, g))
    return out


def party_walls(buildings, tol=0.4, share=0.5) -> set:
    """(building index, surface index) of walls pressed against a neighbour's
    wall. Those stay plain brick: nobody sees them, and a window in one would
    open into the house next door."""
    walls = []
    for bi, b in enumerate(buildings):
        for si, s in enumerate(b.surfaces):
            if s.kind != "wall":
                continue
            n = s.normal.copy()
            n[2] = 0
            if np.linalg.norm(n) < 0.5:
                continue
            n /= np.linalg.norm(n)
            walls.append((bi, si, n, float(n @ s.ring.mean(0)), s.ring))
    grid = defaultdict(list)
    cell = 25.0
    for w in walls:
        c = w[4].mean(0)
        grid[(int(c[0] // cell), int(c[1] // cell))].append(w)
    hidden = set()
    for (gx, gy), bucket in grid.items():
        near = [w for dx in (-1, 0, 1) for dy in (-1, 0, 1)
                for w in grid.get((gx + dx, gy + dy), [])]
        for a in bucket:
            bi, si, n, off, ring = a
            right = np.array([-n[1], n[0], 0.0])
            ua = ring @ right
            width = ua.max() - ua.min()
            if width < 1e-3:
                continue
            for b in near:
                if b[0] == bi or n @ b[2] > -0.95 or abs(off + b[3]) > tol:
                    continue
                ub = b[4] @ right
                overlap = min(ua.max(), ub.max()) - max(ua.min(), ub.min())
                if overlap > share * width:
                    hidden.add((bi, si))
                    break
    return hidden


def _roof(mesh: MeshBuilder, s: Surface, style) -> None:
    n = s.normal
    flat = n[2] > 0.97
    mat = style.roof_flat if flat else style.roof_pitched
    tile = uv_scale(mat)
    if flat:
        uv_fn = lambda p: p[:, :2] / tile
    else:
        down = np.array([n[0], n[1], 0.0])
        down /= np.linalg.norm(down)
        across = np.array([-down[1], down[0], 0.0])
        along = np.cross(n, across)
        uv_fn = lambda p: np.stack([p @ across, p @ along], axis=1) / tile
    mesh.add_polygon3d(mat, s.ring, s.holes, n, uv_fn)


def build_building(b: Building, hidden_walls: set, world_seed: int) -> MeshBuilder:
    rng = random.Random(b.seed(world_seed))
    style = choose_style(b.year, rng)
    ground = b.ground_z if b.ground_z is not None else b.min_z()
    mesh = MeshBuilder()
    for si, s in enumerate(b.surfaces):
        if s.kind == "roof":
            _roof(mesh, s, style)
            continue
        if s.kind != "wall":
            continue        # ground surfaces face the earth: never seen
        shape = wall_shape(s.ring, s.holes, ground)
        if shape is None:
            mesh.add_polygon3d(style.wall, s.ring, s.holes, s.normal,
                               lambda p: p[:, :2] / uv_scale(style.wall))
            continue
        fb = FacadeBuilder(mesh, shape, style, random.Random(rng.random()))
        if si in hidden_walls:
            fb.plain()
        else:
            fb.build()
    return mesh


def ground_plane(buildings, margin=25.0) -> MeshBuilder:
    pts = np.vstack([s.ring for b in buildings for s in b.surfaces])
    x0, y0 = pts[:, :2].min(0) - margin
    x1, y1 = pts[:, :2].max(0) + margin
    z = float(np.median([b.ground_z if b.ground_z is not None else b.min_z()
                         for b in buildings])) - 0.02
    quad = np.array([[x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z]])
    mesh = MeshBuilder()
    mesh.add_polygon3d("ground_cobble", quad, [], UP,
                       lambda p: p[:, :2] / uv_scale("ground_cobble"))
    return mesh


def build_district(buildings, world_seed: int = 1, ground: bool = True) -> District:
    if not buildings:
        raise ValueError("no buildings with walls in the input")
    pts = np.vstack([s.ring for b in buildings for s in b.surfaces])
    lo, hi = pts.min(0), pts.max(0)
    origin = np.array([round((lo[0] + hi[0]) / 2), round((lo[1] + hi[1]) / 2),
                       round(float(lo[2]), 2)])
    local = _recentre(buildings, origin)
    hidden = party_walls(local)
    by_building = defaultdict(set)
    for bi, si in hidden:
        by_building[bi].add(si)
    district = District(origin)
    for bi, b in enumerate(local):
        mesh = build_building(b, by_building[bi], world_seed)
        district.nodes.append((b.id, mesh, {"year": b.year}))
    if ground:
        district.nodes.append(("ground", ground_plane(local), {}))
    return district
