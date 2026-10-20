"""Triangle soup per material, plus the helpers every generator uses.

World space is RD New (EPSG:28992): x east, y north, z up, metres. The glTF
writer converts to Y-up on export, nothing else needs to know.
"""
from __future__ import annotations

import numpy as np
import mapbox_earcut as earcut
from shapely.geometry import Polygon, MultiPolygon

UP = np.array([0.0, 0.0, 1.0])


def newell_normal(pts: np.ndarray) -> np.ndarray:
    """Unit normal of a (roughly planar) polygon, following its winding."""
    p = np.asarray(pts, float)
    q = np.roll(p, -1, axis=0)
    n = np.array([
        np.sum((p[:, 1] - q[:, 1]) * (p[:, 2] + q[:, 2])),
        np.sum((p[:, 2] - q[:, 2]) * (p[:, 0] + q[:, 0])),
        np.sum((p[:, 0] - q[:, 0]) * (p[:, 1] + q[:, 1])),
    ])
    length = np.linalg.norm(n)
    return n / length if length > 1e-12 else n


def plane_basis(normal: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Two unit vectors spanning the plane with this normal."""
    helper = UP if abs(normal[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    a = np.cross(helper, normal)
    a /= np.linalg.norm(a)
    b = np.cross(normal, a)
    return a, b


def triangulate_2d(exterior, holes=()) -> tuple[np.ndarray, np.ndarray]:
    """Earcut a 2D polygon with holes. Returns (points (N,2), tris (K,3))."""
    rings = [np.asarray(exterior, float)[:, :2]]
    rings += [np.asarray(h, float)[:, :2] for h in holes]
    rings = [_open_ring(r) for r in rings if len(_open_ring(r)) >= 3]
    if not rings:
        return np.zeros((0, 2)), np.zeros((0, 3), np.int64)
    pts = np.vstack(rings)
    ends = np.cumsum([len(r) for r in rings]).astype(np.uint32)
    idx = earcut.triangulate_float64(pts, ends)
    return pts, np.asarray(idx, np.int64).reshape(-1, 3)


def _open_ring(r: np.ndarray) -> np.ndarray:
    if len(r) > 1 and np.allclose(r[0], r[-1]):
        return r[:-1]
    return r


def shapely_parts(geom):
    """Iterate the Polygons inside any shapely geometry."""
    if geom is None or geom.is_empty:
        return
    if isinstance(geom, Polygon):
        yield geom
    elif isinstance(geom, MultiPolygon):
        yield from geom.geoms
    elif hasattr(geom, "geoms"):
        for g in geom.geoms:
            yield from shapely_parts(g)


class MeshBuilder:
    """Collects flat-shaded triangles, grouped by material name."""

    def __init__(self):
        self.parts: dict[str, list[np.ndarray]] = {}

    def add_triangles(self, mat: str, pos: np.ndarray, uv: np.ndarray,
                      tris: np.ndarray, normal: np.ndarray) -> None:
        if len(tris) == 0:
            return
        pos = np.asarray(pos, float)
        uv = np.asarray(uv, float)
        tris = np.asarray(tris, np.int64)
        a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
        face_n = np.cross(b - a, c - a)
        flip = face_n @ normal < 0
        tris = tris.copy()
        tris[flip] = tris[flip][:, [0, 2, 1]]
        flat = tris.reshape(-1)
        n = np.broadcast_to(normal, (len(flat), 3))
        block = np.hstack([pos[flat], n, uv[flat]])
        self.parts.setdefault(mat, []).append(block)

    def add_polygon3d(self, mat: str, exterior: np.ndarray, holes, normal,
                      uv_fn) -> None:
        """A planar 3D polygon. uv_fn maps (N,3) world points to (N,2)."""
        exterior = _open_ring(np.asarray(exterior, float))
        a, b = plane_basis(normal)
        origin = exterior[0]

        def to2(p):
            d = np.asarray(p, float) - origin
            return np.stack([d @ a, d @ b], axis=1)

        pts2, tris = triangulate_2d(to2(exterior), [to2(h) for h in holes])
        if len(tris) == 0:
            return
        # Lift back on to the plane through the polygon.
        pts3 = origin + pts2[:, :1] * a + pts2[:, 1:2] * b
        self.add_triangles(mat, pts3, uv_fn(pts3), tris, normal)

    def merge(self, other: "MeshBuilder") -> None:
        for mat, blocks in other.parts.items():
            self.parts.setdefault(mat, []).extend(blocks)

    def arrays(self) -> dict[str, np.ndarray]:
        """material -> (N, 8) [pos3, normal3, uv2], three rows per triangle."""
        return {m: np.vstack(b) for m, b in self.parts.items() if b}

    def triangle_count(self) -> int:
        return sum(len(a) for a in self.arrays().values()) // 3


class Frame:
    """Local facade space: u right (seen from outside), v up, d outward."""

    def __init__(self, origin, right, normal):
        self.o = np.asarray(origin, float)
        self.r = np.asarray(right, float)
        self.n = np.asarray(normal, float)
        self.z = UP

    def world(self, u, v, d=0.0):
        u, v, d = (np.asarray(x, float) for x in (u, v, d))
        return (self.o + u[..., None] * self.r + v[..., None] * self.z
                + d[..., None] * self.n)

    def vec(self, du, dv, dd):
        return du * self.r + dv * self.z + dd * self.n


class LocalBuilder:
    """Builds geometry in a facade Frame, with metric UVs per material scale."""

    def __init__(self, mesh: MeshBuilder, frame: Frame, uv_scale, lite=False):
        self.mesh = mesh
        self.f = frame
        self.uv_scale = uv_scale  # callable: material -> metres per texture tile
        self.lite = lite          # web weight: thin trims lose their side faces

    def poly(self, mat: str, poly: Polygon, d: float, facing: int = 1) -> None:
        """A shapely polygon (u, v) lying in the plane at depth d."""
        s = self.uv_scale(mat)
        for p in shapely_parts(poly):
            pts2, tris = triangulate_2d(np.asarray(p.exterior.coords),
                                        [np.asarray(h.coords) for h in p.interiors])
            if len(tris) == 0:
                continue
            pos = self.f.world(pts2[:, 0], pts2[:, 1], np.full(len(pts2), d))
            self.mesh.add_triangles(mat, pos, pts2 / s, tris, self.f.n * facing)

    def quad(self, mat: str, corners, normal_local, uv=None) -> None:
        """Four local (u, v, d) corners in order; UVs from the face's own axes
        unless given."""
        c = np.asarray(corners, float)
        pos = self.f.world(c[:, 0], c[:, 1], c[:, 2])
        e1 = pos[1] - pos[0]
        e2 = pos[3] - pos[0]
        l1, l2 = np.linalg.norm(e1), np.linalg.norm(e2)
        if l1 < 1e-6 or l2 < 1e-6:
            return
        if uv is None:
            s = self.uv_scale(mat)
            uv = np.array([[0, 0], [l1, 0], [l1, l2], [0, l2]]) / s
            # Anchor UVs in facade space so neighbouring quads line up.
            uv += np.array([c[0, 0] + c[0, 2], c[0, 1]]) / s
        else:
            uv = np.asarray(uv, float)
        n = self.f.vec(*normal_local)
        self.mesh.add_triangles(mat, pos, uv, np.array([[0, 1, 2], [0, 2, 3]]), n)

    def box(self, mat: str, u0, u1, v0, v1, d0, d1, back=False, faces="flrtb") -> None:
        """Axis-aligned box in facade space. faces picks which sides to emit:
        f(ront), l(eft), r(ight), t(op), b(ottom). The back (d0) face is
        usually against the wall and omitted."""
        if u1 - u0 < 1e-4 or v1 - v0 < 1e-4 or d1 - d0 < 1e-4:
            return
        if self.lite and d1 - d0 < 0.12:
            faces = "".join(c for c in faces if c in "ft")
        q = self.quad
        if "f" in faces:
            q(mat, [(u0, v0, d1), (u1, v0, d1), (u1, v1, d1), (u0, v1, d1)], (0, 0, 1))
        if "l" in faces:
            q(mat, [(u0, v0, d0), (u0, v0, d1), (u0, v1, d1), (u0, v1, d0)], (-1, 0, 0))
        if "r" in faces:
            q(mat, [(u1, v0, d1), (u1, v0, d0), (u1, v1, d0), (u1, v1, d1)], (1, 0, 0))
        if "t" in faces:
            q(mat, [(u0, v1, d1), (u1, v1, d1), (u1, v1, d0), (u0, v1, d0)], (0, 1, 0))
        if "b" in faces:
            q(mat, [(u0, v0, d0), (u1, v0, d0), (u1, v0, d1), (u0, v0, d1)], (0, -1, 0))
        if back:
            q(mat, [(u1, v0, d0), (u0, v0, d0), (u0, v1, d0), (u1, v1, d0)], (0, 0, -1))
