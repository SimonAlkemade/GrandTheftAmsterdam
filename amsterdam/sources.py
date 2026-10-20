"""Read buildings from 3D BAG CityJSON (file, CityJSONSeq, or API pages) or
from a plain OBJ export (e.g. the 3d.amsterdam.nl download tool).

Everything comes out as the same small model: a Building with labelled planar
surfaces (wall / roof / ground) in RD New metres, outward-facing.
"""
from __future__ import annotations

import json
import zlib
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from shapely.geometry import Polygon
from shapely.ops import unary_union

from .mesh import newell_normal, plane_basis, triangulate_2d, shapely_parts

WALL_TYPES = {"WallSurface", "InteriorWallSurface", "ClosureSurface"}
ROOF_TYPES = {"RoofSurface", "OuterCeilingSurface"}
GROUND_TYPES = {"GroundSurface", "OuterFloorSurface", "FloorSurface"}

# Attributes 3D BAG puts on each Building (pand).
YEAR_KEYS = ("oorspronkelijkbouwjaar", "bouwjaar", "yearOfConstruction")
GROUND_KEYS = ("b3_h_maaiveld", "h_maaiveld")


@dataclass
class Surface:
    kind: str                 # "wall" | "roof" | "ground"
    ring: np.ndarray          # (N, 3) exterior, open (first != last)
    holes: list = field(default_factory=list)

    @property
    def normal(self) -> np.ndarray:
        return newell_normal(self.ring)


@dataclass
class Building:
    id: str
    surfaces: list
    year: int | None = None
    ground_z: float | None = None

    def seed(self, world_seed: int) -> int:
        return zlib.crc32(self.id.encode()) ^ (world_seed * 2654435761 & 0xFFFFFFFF)

    def walls(self):
        return [s for s in self.surfaces if s.kind == "wall"]

    def roofs(self):
        return [s for s in self.surfaces if s.kind == "roof"]

    def min_z(self) -> float:
        return float(min(s.ring[:, 2].min() for s in self.surfaces))


def classify(normal: np.ndarray) -> str:
    if abs(normal[2]) < 0.25:
        return "wall"
    return "roof" if normal[2] > 0 else "ground"


def signed_volume(surfaces) -> float:
    vol = 0.0
    for s in surfaces:
        n = s.normal
        if not np.any(n):
            continue
        a, b = plane_basis(n)
        o = s.ring[0]
        to2 = lambda p: np.stack([(p - o) @ a, (p - o) @ b], axis=1)
        pts2, tris = triangulate_2d(to2(s.ring), [to2(h) for h in s.holes])
        if len(tris) == 0:
            continue
        p3 = o + pts2[:, :1] * a + pts2[:, 1:2] * b
        # Earcut does not keep winding: orient each triangle to the surface normal.
        A, B, C = p3[tris[:, 0]], p3[tris[:, 1]], p3[tris[:, 2]]
        cr = np.cross(B - A, C - A)
        sign = np.sign(cr @ n)
        vol += float(np.sum(sign * np.einsum("ij,ij->i", A, cr))) / 6.0
    return vol


def orient_outward(surfaces, relabel: bool = False) -> list:
    """Flip a whole closed shell if it is wound inside-out. relabel re-derives
    wall/roof/ground from the corrected normal (for sources with no semantics)."""
    if signed_volume(surfaces) >= 0:
        return surfaces
    out = []
    for s in surfaces:
        f = Surface(s.kind, s.ring[::-1].copy(), [h[::-1].copy() for h in s.holes])
        if relabel:
            f.kind = classify(f.normal)
        out.append(f)
    return out


# --------------------------------------------------------------------------
# CityJSON

def _decode_vertices(verts, transform) -> np.ndarray:
    v = np.asarray(verts, float)
    if transform:
        v = v * np.asarray(transform["scale"]) + np.asarray(transform["translate"])
    return v


def _pick_geometry(obj):
    geoms = [g for g in obj.get("geometry", [])
             if g.get("type") in ("Solid", "MultiSurface", "CompositeSurface",
                                  "MultiSolid", "CompositeSolid")]
    if not geoms:
        return None

    def lod(g):
        try:
            return float(g.get("lod", 0))
        except (TypeError, ValueError):
            return 0.0
    return max(geoms, key=lod)


def _iter_surfaces(geom):
    """Yield (surface_rings, semantic_index_or_None) for any CityJSON geometry."""
    t = geom["type"]
    b = geom["boundaries"]
    values = (geom.get("semantics") or {}).get("values")
    if t in ("MultiSurface", "CompositeSurface"):
        for i, srf in enumerate(b):
            yield srf, (values[i] if values else None)
    elif t == "Solid":
        for si, shell in enumerate(b):
            for i, srf in enumerate(shell):
                yield srf, (values[si][i] if values and values[si] else None)
    else:  # MultiSolid / CompositeSolid
        for ki, solid in enumerate(b):
            for si, shell in enumerate(solid):
                for i, srf in enumerate(shell):
                    v = None
                    if values and values[ki] and values[ki][si]:
                        v = values[ki][si][i]
                    yield srf, v


def _surfaces_from(geom, vertices) -> list:
    sem = (geom.get("semantics") or {}).get("surfaces", [])
    out = []
    for rings, si in _iter_surfaces(geom):
        ext = vertices[rings[0]]
        if len(ext) < 3:
            continue
        holes = [vertices[r] for r in rings[1:] if len(r) >= 3]
        stype = sem[si]["type"] if si is not None and si < len(sem) else None
        n = newell_normal(ext)
        if not np.any(n):
            continue
        if stype in WALL_TYPES:
            kind = "wall"
        elif stype in ROOF_TYPES:
            kind = "roof"
        elif stype in GROUND_TYPES:
            kind = "ground"
        else:
            kind = classify(n)
        out.append(Surface(kind, ext, holes))
    return out


def _first_attr(attrs, keys):
    for k in keys:
        if attrs.get(k) not in (None, ""):
            return attrs[k]
    return None


def _buildings_from_objects(objects: dict, vertices: np.ndarray) -> list:
    out = []
    for oid, obj in objects.items():
        geom = _pick_geometry(obj)
        if geom is None or float(geom.get("lod", 2)) < 1:
            continue
        attrs = dict(obj.get("attributes") or {})
        for pid in obj.get("parents", []):
            parent_attrs = (objects.get(pid) or {}).get("attributes") or {}
            for k, v in parent_attrs.items():
                attrs.setdefault(k, v)
        surfaces = _surfaces_from(geom, vertices)
        if not any(s.kind == "wall" for s in surfaces):
            continue
        if geom["type"] in ("Solid", "MultiSolid", "CompositeSolid"):
            surfaces = orient_outward(surfaces)
        year = _first_attr(attrs, YEAR_KEYS)
        ground = _first_attr(attrs, GROUND_KEYS)
        out.append(Building(
            id=str(oid), surfaces=surfaces,
            year=int(year) if year is not None else None,
            ground_z=float(ground) if ground is not None else None))
    return out


def load_cityjson(path: str | Path) -> list:
    """A CityJSON file, a CityJSONSeq (.jsonl), or a saved 3D BAG API page."""
    text = Path(path).read_text()
    stripped = text.lstrip()
    if stripped.startswith("{") and "\n{" in stripped.strip():
        try:
            json.loads(stripped)
        except json.JSONDecodeError:
            return _load_seq(stripped.splitlines())
    doc = json.loads(text)
    return load_cityjson_doc(doc)


def load_cityjson_doc(doc: dict) -> list:
    if "features" in doc:  # 3D BAG OGC API page: header + CityJSONFeatures
        meta = doc.get("metadata") or {}
        transform = meta.get("transform") or doc.get("transform")
        out = []
        for feat in doc["features"]:
            verts = _decode_vertices(feat.get("vertices", []), transform)
            out += _buildings_from_objects(feat.get("CityObjects", {}), verts)
        return out
    verts = _decode_vertices(doc.get("vertices", []), doc.get("transform"))
    return _buildings_from_objects(doc.get("CityObjects", {}), verts)


def _load_seq(lines) -> list:
    transform = None
    out = []
    for line in lines:
        if not line.strip():
            continue
        d = json.loads(line)
        if d.get("type") == "CityJSON":
            transform = d.get("transform")
        elif d.get("type") == "CityJSONFeature":
            verts = _decode_vertices(d.get("vertices", []), transform)
            out += _buildings_from_objects(d.get("CityObjects", {}), verts)
    return out


# --------------------------------------------------------------------------
# OBJ (no semantics: classify by normal, merge coplanar triangles)

def load_obj(path: str | Path, up: str = "z", min_area: float = 0.05) -> list:
    """Each OBJ object/group becomes a building; with no groups, each
    connected component does. Triangles are merged back into planar faces so
    a facade is one wall again rather than two hundred slivers."""
    verts, faces, groups = [], [], []
    group = None
    for line in Path(path).read_text(errors="replace").splitlines():
        if line.startswith("v "):
            verts.append([float(x) for x in line.split()[1:4]])
        elif line.startswith(("o ", "g ")):
            group = line.split(maxsplit=1)[1].strip() if len(line.split()) > 1 else None
        elif line.startswith("f "):
            idx = []
            for tok in line.split()[1:]:
                i = int(tok.split("/")[0])
                idx.append(i - 1 if i > 0 else len(verts) + i)
            faces.append(idx)
            groups.append(group)
    v = np.asarray(verts, float)
    if up == "y":  # Y-up export: (x, y, z) -> (x, -z, y)
        v = np.stack([v[:, 0], -v[:, 2], v[:, 1]], axis=1)

    if len(set(groups)) > 1 or groups and groups[0] is not None:
        clusters: dict = {}
        for f, g in zip(faces, groups):
            clusters.setdefault(g, []).append(f)
    else:
        # Exporters often split vertices per face (for normals or UVs), so
        # weld by position first or every face is its own "building".
        _, weld = np.unique(np.round(v, 3), axis=0, return_inverse=True)
        weld = weld.reshape(-1)
        clusters = _components([[int(weld[i]) for i in f] for f in faces], len(v))
        # Components were found on welded ids; faces keep their own vertices.
        by_key = {}
        for f in faces:
            by_key.setdefault(tuple(int(weld[i]) for i in f), []).append(f)
        clusters = {k: [f for wf in fs for f in by_key.pop(tuple(wf), [])]
                    for k, fs in clusters.items()}

    out = []
    for name, cfaces in clusters.items():
        surfaces = _merge_coplanar(v, cfaces, min_area)
        if not any(s.kind == "wall" for s in surfaces):
            continue
        surfaces = orient_outward(surfaces, relabel=True)
        out.append(Building(id=str(name), surfaces=surfaces))
    return out


def _components(faces, nverts) -> dict:
    parent = list(range(nverts))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    for f in faces:
        for i in f[1:]:
            ra, rb = find(f[0]), find(i)
            if ra != rb:
                parent[rb] = ra
    clusters: dict = {}
    for f in faces:
        clusters.setdefault(f"part_{find(f[0])}", []).append(f)
    return clusters


def _merge_coplanar(v, faces, min_area) -> list:
    planes = []  # (normal, offset, [polys2d])
    for f in faces:
        p = v[f]
        n = newell_normal(p)
        if not np.any(n):
            continue
        off = float(n @ p[0])
        for plane in planes:
            if plane[0] @ n > 0.996 and abs(plane[1] - off) < 0.08:
                plane[2].append(p)
                break
        else:
            planes.append((n, off, [p]))
    out = []
    for n, off, polys in planes:
        a, b = plane_basis(n)
        o = n * off
        shapes = [Polygon(np.stack([(p - o) @ a, (p - o) @ b], axis=1)).buffer(0)
                  for p in polys]
        merged = unary_union(shapes).buffer(0.01).buffer(-0.01)
        for part in shapely_parts(merged):
            if part.area < min_area:
                continue
            part = part.simplify(0.02)
            lift = lambda c: o + np.asarray(c)[:-1, :1] * a + np.asarray(c)[:-1, 1:2] * b
            ext = lift(part.exterior.coords)
            if Polygon(part.exterior.coords).exterior.is_ccw is False:
                ext = ext[::-1]
            holes = [lift(h.coords) for h in part.interiors]
            out.append(Surface(classify(n), ext, holes))
    return out
