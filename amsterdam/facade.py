"""The "upscaler": turn one flat open-data wall into an Amsterdam facade.

The open-data wall polygon is the contract. Its outline, width and height are
kept exactly; detail is added *into* it (openings with depth) and, for gable
ends, *onto* it (a decorative gable silhouette that always covers the roof
triangle, so the roof never shows around it).

Facade space (see mesh.Frame): u runs left to right seen from the street,
v is height above the building's ground level, d points out of the wall.
"""
from __future__ import annotations

import random
from dataclasses import dataclass

import numpy as np
from shapely.geometry import LineString, Polygon, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

from .materials import uv_scale
from .mesh import Frame, LocalBuilder, MeshBuilder, newell_normal, shapely_parts

GABLE_DEPTH = 0.35   # thickness shown at a gable's edges, where it rises free


# --------------------------------------------------------------------------
# Styles: what a building's era says about its front.

@dataclass
class Style:
    era: str
    wall: str
    trim: str
    frame: str
    door: str
    shutter: str | None
    gable: str            # step | neck | bell | spout | plain
    cornice: bool
    bars: tuple           # glazing bars (columns, rows) per sash
    sash: bool
    bay_w: float
    win_w: float
    win_fill: float       # window height as a share of the storey
    ground_h: float
    shop: bool
    bands: bool
    lintels: bool
    hoist: bool
    roof_pitched: str
    roof_flat: str = "roof_flat"


def _era(year: int | None, rng: random.Random) -> str:
    if year is None:
        year = rng.choice([1650, 1700, 1780, 1860, 1880, 1925, 1970])
    if year < 1720:
        return "golden"
    if year < 1900:
        return "classic"
    if year < 1945:
        return "school"
    return "postwar"


def choose_style(year: int | None, rng: random.Random) -> Style:
    era = _era(year, rng)
    pick = rng.choice
    if era == "golden":
        return Style(
            era, pick(["brick_red", "brick_brown", "brick_dark", "brick_orange"]),
            "stone", "frame_white", pick(["door_green", "door_black", "door_red", "door_wood"]),
            pick(["shutter_green", "shutter_red"]) if rng.random() < 0.35 else None,
            rng.choices(["step", "neck", "bell", "spout"], [3, 4, 2, 1.5])[0],
            False, (2, 3), True, 1.7, 1.0, 0.62, 3.9,
            rng.random() < 0.3, rng.random() < 0.5, True, rng.random() < 0.7,
            pick(["roof_tiles_dark", "roof_tiles_red"]))
    if era == "classic":
        painted = rng.random() < 0.4
        wall = (pick(["brick_painted_white", "brick_painted_grey", "plaster_cream"])
                if painted else pick(["brick_red", "brick_brown", "brick_dark"]))
        return Style(
            era, wall, "stone" if not painted else "plaster_cream", "frame_white",
            pick(["door_green", "door_black", "door_black", "door_red"]),
            "shutter_green" if rng.random() < 0.1 else None,
            # "plain" here means a level top with a cornice (lijstgevel); a
            # front whose roof pitches toward the street still gets a gable.
            rng.choices(["neck", "bell", "plain"], [3, 2, 5])[0],
            True, (1, 2), True, 1.8, 1.1, 0.64, 3.8,
            rng.random() < 0.4, False, rng.random() < 0.5, rng.random() < 0.4,
            pick(["roof_tiles_dark", "roof_slate"]))
    if era == "school":
        return Style(
            era, pick(["brick_dark", "brick_brown", "brick_orange"]), "stone",
            pick(["frame_white", "frame_white", "frame_green"]), pick(["door_wood", "door_green"]),
            None, "plain", False, (3, 2), False, 1.6, 1.3, 0.55, 3.4,
            rng.random() < 0.3, True, False, False,
            pick(["roof_tiles_red", "roof_tiles_dark"]))
    return Style(
        era, pick(["concrete", "brick_yellow", "plaster_cream", "brick_brown"]), "concrete",
        pick(["frame_dark", "frame_white"]), "door_black", None, "plain", False,
        (1, 0), False, 2.6, 2.0, 0.55, 3.2, rng.random() < 0.3, False, False, False,
        "roof_tiles_dark")


# --------------------------------------------------------------------------
# Gable silhouettes, in units of the gable: x across [0, 1], y up from the
# eaves, 1 = roof apex. Each must contain the triangle (0,0)-(0.5,1)-(1,0):
# tests/test_facade.py checks that for every type.

def _mirror(left):
    """Close a left half-profile (x <= 0.5, bottom to top) symmetrically.
    A point on the centre line is kept once."""
    right = [(1 - x, y) for x, y in reversed(left) if x < 0.5]
    return left + right


def gable_shape(kind: str, steps: int = 4) -> Polygon:
    if kind == "step":
        rects = []
        for k in range(steps):
            top = (k + 1) / steps if k < steps - 1 else 1.12
            rects.append(box(k / (2 * steps), k / steps, 1 - k / (2 * steps), top))
        return unary_union(rects)
    if kind == "neck":
        # Shoulders y = sqrt(x) stay above the roof line y = 2x up to x = 1/4,
        # then a straight neck carries a small pediment above the apex.
        shoulder = [(x, np.sqrt(x)) for x in np.linspace(0, 0.25, 9)]
        left = [(0.0, 0.0)] + shoulder[1:] + [(0.25, 1.08), (0.22, 1.08), (0.5, 1.28)]
        return Polygon(_mirror(left))
    if kind == "bell":
        left = [(0.0, 0.0), (0.04, 0.12), (0.15, 0.3), (0.19, 0.5), (0.25, 0.74),
                (0.33, 0.9), (0.42, 1.0), (0.5, 1.06)]
        return Polygon(_mirror(left))
    if kind == "spout":
        left = [(0.0, 0.0), (0.0, 0.12), (0.12, 0.3), (0.12, 0.42), (0.4, 0.8),
                (0.4, 1.14)]
        return Polygon(_mirror(left))
    return Polygon([(0, 0), (0.5, 1), (1, 0)])


# --------------------------------------------------------------------------

@dataclass
class WallShape:
    frame: Frame
    poly: Polygon        # wall outline in facade space
    width: float
    base: float          # lowest v
    core_top: float      # highest v the wall reaches over its whole width
    peak: float
    apex_u: float


def wall_shape(ring: np.ndarray, holes, ground_z: float) -> WallShape | None:
    n = newell_normal(ring)
    nh = np.array([n[0], n[1], 0.0])
    if np.linalg.norm(nh) < 0.5:
        return None
    nh /= np.linalg.norm(nh)
    right = np.array([-nh[1], nh[0], 0.0])
    rel = ring - ring[0]
    u = rel @ right
    d0 = float(np.mean(rel @ nh))
    origin = ring[0] + u.min() * right + d0 * nh
    origin[2] = ground_z
    frame = Frame(origin, right, nh)

    def local(pts):
        r = pts - origin
        return np.stack([r @ right, pts[:, 2] - ground_z], axis=1)

    poly = Polygon(local(ring), [local(h) for h in holes]).buffer(0)
    if poly.is_empty or poly.area < 0.2:
        return None
    if poly.geom_type != "Polygon":
        poly = max(poly.geoms, key=lambda g: g.area)
    u0, v0, u1, v1 = poly.bounds
    tops, us = [], np.linspace(u0 + 0.002, u1 - 0.002, 41) if u1 - u0 > 0.2 else [0.5 * (u0 + u1)]
    for x in us:
        cut = poly.intersection(LineString([(x, v0 - 1), (x, v1 + 1)]))
        tops.append(cut.bounds[3] if not cut.is_empty else v0)
    tops = np.asarray(tops)
    return WallShape(frame, poly, u1 - u0, v0, float(tops.min()), float(tops.max()),
                     float(np.asarray(us)[int(np.argmax(tops))]))


class FacadeBuilder:
    def __init__(self, mesh: MeshBuilder, shape: WallShape, style: Style,
                 rng: random.Random):
        self.s = shape
        self.st = style
        self.rng = rng
        self.lb = LocalBuilder(mesh, shape.frame, uv_scale)
        self.outline = shape.poly
        self.inner = shape.poly

    # -- public ----------------------------------------------------------

    def plain(self) -> None:
        self.lb.poly(self.st.wall, self.s.poly, 0.0)

    def build(self) -> None:
        s, st = self.s, self.st
        pitched = s.peak - s.core_top > 1.2
        symmetric = abs(s.apex_u - (s.poly.bounds[0] + s.width / 2)) < 0.15 * s.width
        gable = st.gable if pitched and symmetric else "plain"
        if gable == "plain" and pitched and symmetric and st.era == "classic":
            gable = self.rng.choice(["neck", "bell"])
        if gable != "plain":
            self._gable(gable)
        self.inner = self.outline.buffer(-0.3)
        openings = self._layout(gable)
        holes = unary_union([box(o[1], o[3], o[2], o[4]) for o in openings]) if openings else None
        wall = self.outline.difference(holes) if holes is not None else self.outline
        self.lb.poly(st.wall, wall, 0.0)
        for o in openings:
            getattr(self, "_" + o[0])(*o[1:])
        if not pitched:
            self._top_trim()
        if st.bands:
            self._bands(openings)

    # -- layout ----------------------------------------------------------

    def _fits(self, u0, u1, v0, v1, margin=0.0) -> bool:
        return self.inner.buffer(margin).contains(box(u0, v0, u1, v1))

    def _layout(self, gable) -> list:
        s, st = self.s, self.st
        u_left = s.poly.bounds[0]
        core_h = s.core_top - s.base
        out = []
        if core_h < 2.4 or s.width < 1.4:
            return out
        street = s.base < 0.8
        n = max(1, round(s.width / st.bay_w))
        while n > 1 and s.width / n < st.win_w + 0.45:
            n -= 1
        bay = s.width / n
        ww = min(st.win_w, bay - 0.45)
        centres = [u_left + bay * (i + 0.5) for i in range(n)]

        gh = 0.0
        if street:
            gh = min(st.ground_h, core_h - 0.4)
            out += self._ground_floor(centres, bay, ww, gh)
        top_margin = 0.7 if st.cornice else 0.4
        start = s.base + gh
        rest = s.core_top - start - top_margin
        floors = int(rest // 2.7) if rest > 2.2 else 0
        if floors == 0 and rest > 2.2:
            floors = 1
        fh = rest / floors if floors else 0.0
        self.floor_lines = [start + i * fh for i in range(floors + 1)] if floors else []
        if ww >= 0.45:
            for i in range(floors):
                f0 = start + i * fh
                wh = fh * st.win_fill * (1 - 0.04 * i)
                v0 = f0 + (fh - wh) * 0.55
                for c in centres:
                    if self._fits(c - ww / 2, c + ww / 2, v0, v0 + wh):
                        out.append(("window", c - ww / 2, c + ww / 2, v0, v0 + wh, True))
        if gable != "plain":
            out += self._gable_windows(ww)
        return out

    def _ground_floor(self, centres, bay, ww, gh) -> list:
        s, st, rng = self.s, self.st, self.rng
        out = []
        n = len(centres)
        door_i = rng.choice([0, n - 1])
        stoop = st.era in ("golden", "classic") and gh > 3.2
        dw = min(1.05, bay - 0.4)
        dv0 = s.base + (0.35 if stoop else 0.02)
        dh = min(2.6, gh - 0.5)
        c = centres[door_i]
        if dw > 0.7 and self._fits(c - dw / 2, c + dw / 2, dv0, dv0 + dh, margin=0.31):
            out.append(("door", c - dw / 2, c + dw / 2, dv0, dv0 + dh, stoop))
        rest = [x for i, x in enumerate(centres) if i != door_i]
        if not rest:
            return out
        if st.shop and len(rest) >= 1:
            u0 = min(rest) - bay / 2 + 0.25
            u1 = max(rest) + bay / 2 - 0.25
            v0, v1 = s.base + 0.45, s.base + gh - 0.45
            if self._fits(u0, u1, v0, v1 + 0.5, margin=0.31):
                out.append(("shop", u0, u1, v0, v1, False))
                return out
        for c in rest:
            v0 = s.base + gh * 0.28
            v1 = s.base + gh * 0.82
            if self._fits(c - ww / 2, c + ww / 2, v0, v1):
                out.append(("window", c - ww / 2, c + ww / 2, v0, v1, False))
        return out

    def _gable_windows(self, ww) -> list:
        s = self.s
        out = []
        w = min(0.9, ww * 0.85)
        h = 1.4
        v = s.core_top + 0.5
        while v + h < s.peak - 0.4:
            row = []
            for c in (s.apex_u - w * 0.75, s.apex_u + w * 0.75):
                if self._fits(c - w / 2, c + w / 2, v, v + h):
                    row.append(("window", c - w / 2, c + w / 2, v, v + h, False))
            if len(row) < 2:
                row = []
                if self._fits(s.apex_u - w / 2, s.apex_u + w / 2, v, v + h):
                    row = [("window", s.apex_u - w / 2, s.apex_u + w / 2, v, v + h, False)]
            out += row
            v += 2.5
        return out

    # -- gable ------------------------------------------------------------

    def _gable(self, kind: str) -> None:
        s, lb, st = self.s, self.lb, self.st
        u0 = s.poly.bounds[0]
        H = s.peak - s.core_top
        sil = gable_shape(kind, steps=4 if H > 3.5 else 3)
        coords = [(u0 + x * s.width, s.core_top + y * H) for x, y in sil.exterior.coords]
        sil = Polygon(coords).buffer(0)
        self.outline = orient(unary_union([s.poly, sil]).buffer(0.001).buffer(-0.001), 1.0)
        if self.outline.geom_type != "Polygon":
            self.outline = max(self.outline.geoms, key=lambda g: g.area)
        free = self.outline.difference(s.poly.buffer(0.01))
        # The gable's back, seen over the roof from behind.
        for part in shapely_parts(free):
            lb.poly(st.wall, part, -GABLE_DEPTH, facing=-1)
        # Edges that stand free get thickness and a stone coping.
        ring = np.asarray(self.outline.exterior.coords)
        inside = s.poly.buffer(0.02)
        for a, b in zip(ring[:-1], ring[1:]):
            mid = (a + b) / 2
            if mid[1] < s.core_top - 0.01 or inside.contains(_pt(mid)):
                continue
            du, dv = b - a
            length = np.hypot(du, dv)
            if length < 1e-3:
                continue
            nrm = (dv / length, -du / length, 0.0)
            lb.quad(st.trim, [(a[0], a[1], 0), (b[0], b[1], 0),
                              (b[0], b[1], -GABLE_DEPTH), (a[0], a[1], -GABLE_DEPTH)], nrm)
            if abs(dv) < 1e-3 and nrm[1] > 0:     # a level top: cap stone
                lo, hi = sorted((a[0], b[0]))
                lb.box(st.trim, lo - 0.05, hi + 0.05, a[1], a[1] + 0.12,
                       -GABLE_DEPTH - 0.03, 0.06, back=True)
        if st.hoist:
            top = self.outline.bounds[3]
            v = min(s.peak - 0.2, top - 0.9)
            lb.box("timber", s.apex_u - 0.09, s.apex_u + 0.09, v, v + 0.2, 0.0, 0.95)

    # -- trim -------------------------------------------------------------

    def _top_trim(self) -> None:
        s, st, lb = self.s, self.st, self.lb
        u0, u1 = s.poly.bounds[0], s.poly.bounds[2]
        t = s.core_top
        if s.peak - t > 0.3:
            return
        if st.cornice:
            lb.box(st.trim, u0, u1, t - 0.5, t - 0.3, 0.0, 0.1)
            lb.box(st.trim, u0 - 0.05, u1 + 0.05, t - 0.3, t - 0.12, 0.0, 0.24)
            lb.box(st.trim, u0 - 0.1, u1 + 0.1, t - 0.12, t + 0.06, 0.0, 0.4, back=True)
            # Consoles under the cornice.
            for x in np.linspace(u0 + 0.3, u1 - 0.3, max(2, int((u1 - u0) / 1.2))):
                lb.box(st.trim, x - 0.08, x + 0.08, t - 0.62, t - 0.3, 0.0, 0.22)
        else:
            lb.box(st.trim, u0, u1, t - 0.14, t + 0.04, 0.0, 0.07, back=True)

    def _bands(self, openings) -> None:
        s, st, lb = self.s, self.st, self.lb
        u0, u1 = s.poly.bounds[0], s.poly.bounds[2]
        for v in getattr(self, "floor_lines", [])[:-1]:
            if any(o[3] < v + 0.1 and o[4] > v - 0.1 for o in openings):
                continue
            if self.outline.buffer(0.01).contains(box(u0, v - 0.08, u1, v + 0.08)):
                lb.box(st.trim, u0, u1, v - 0.08, v + 0.08, 0.0, 0.035)

    # -- openings ---------------------------------------------------------

    def _reveal(self, u0, u1, v0, v1, depth, mat, bottom=False):
        q = self.lb.quad
        q(mat, [(u0, v0, 0), (u0, v0, -depth), (u0, v1, -depth), (u0, v1, 0)], (1, 0, 0))
        q(mat, [(u1, v0, -depth), (u1, v0, 0), (u1, v1, 0), (u1, v1, -depth)], (-1, 0, 0))
        q(mat, [(u0, v1, 0), (u0, v1, -depth), (u1, v1, -depth), (u1, v1, 0)], (0, -1, 0))
        if bottom:
            q(mat, [(u0, v0, -depth), (u0, v0, 0), (u1, v0, 0), (u1, v0, -depth)], (0, 1, 0))

    def _frame_ring(self, u0, u1, v0, v1, d, t, depth, mat):
        b = self.lb.box
        b(mat, u0, u0 + t, v0, v1, d, d + depth)
        b(mat, u1 - t, u1, v0, v1, d, d + depth)
        b(mat, u0 + t, u1 - t, v1 - t, v1, d, d + depth)
        b(mat, u0 + t, u1 - t, v0, v0 + t, d, d + depth)

    def _bars(self, u0, u1, v0, v1, d, cols, rows, mat, t=0.03):
        for i in range(1, cols):
            x = u0 + (u1 - u0) * i / cols
            self.lb.box(mat, x - t / 2, x + t / 2, v0, v1, d, d + 0.035)
        for j in range(1, rows):
            y = v0 + (v1 - v0) * j / rows
            self.lb.box(mat, u0, u1, y - t / 2, y + t / 2, d, d + 0.035)

    def _window(self, u0, u1, v0, v1, upper):
        st, lb, rng = self.st, self.lb, self.rng
        R, t = 0.14, 0.07
        self._reveal(u0, u1, v0, v1, R, st.wall)
        lb.quad("glass", [(u0, v0, -R), (u1, v0, -R), (u1, v1, -R), (u0, v1, -R)], (0, 0, 1))
        self._frame_ring(u0, u1, v0, v1, -R, t, 0.07, st.frame)
        iu0, iu1, iv0, iv1 = u0 + t, u1 - t, v0 + t, v1 - t
        cols, rows = st.bars
        if st.sash:
            mid = iv0 + (iv1 - iv0) * 0.5
            lb.box(st.frame, iu0, iu1, mid - 0.03, mid + 0.03, -R, -R + 0.06)
            self._bars(iu0, iu1, mid, iv1, -R, cols, rows, st.frame)
            self._bars(iu0, iu1, iv0, mid, -R, cols, rows, st.frame)
        else:
            self._bars(iu0, iu1, iv0, iv1, -R, cols, max(rows, 1), st.frame)
        lb.box(st.trim, u0 - 0.06, u1 + 0.06, v0 - 0.08, v0 + 0.01, -R, 0.07)
        if st.lintels:
            lb.box(st.trim, u0 - 0.1, u1 + 0.1, v1, v1 + 0.22, 0.0, 0.025)
        if upper and st.shutter and rng.random() < 0.8:
            w = (u1 - u0) / 2
            for a, b in ((u0 - w - 0.03, u0 - 0.03), (u1 + 0.03, u1 + 0.03 + w)):
                if self.outline.contains(box(a, v0, b, v1)):
                    lb.box(st.shutter, a, b, v0, v1, 0.0, 0.05)

    def _door(self, u0, u1, v0, v1, stoop):
        st, lb = self.st, self.lb
        R, t = 0.3, 0.08
        fan = 0.5
        self._reveal(u0, u1, v0, v1, R, st.wall)
        lb.quad(st.trim, [(u0, v0, -R), (u0, v0, 0), (u1, v0, 0), (u1, v0, -R)], (0, 1, 0))
        dv1 = v1 - fan
        lb.quad(st.door, [(u0, v0, -R), (u1, v0, -R), (u1, dv1, -R), (u0, dv1, -R)], (0, 0, 1))
        lb.quad("glass", [(u0, dv1, -R), (u1, dv1, -R), (u1, v1, -R), (u0, v1, -R)], (0, 0, 1))
        self._frame_ring(u0, u1, v0, v1, -R, t, 0.08, st.frame)
        lb.box(st.frame, u0, u1, dv1 - 0.04, dv1 + 0.04, -R, -R + 0.08)
        self._bars(u0 + t, u1 - t, dv1, v1 - t, -R, 3, 1, st.frame)
        # Raised panels on the door leaf.
        pw = (u1 - u0 - 2 * t) * 0.32
        for cx in (u0 + (u1 - u0) * 0.3, u0 + (u1 - u0) * 0.7):
            lb.box(st.door, cx - pw / 2, cx + pw / 2, v0 + 0.25, dv1 - 0.25, -R, -R + 0.03)
        lb.box("frame_dark", u1 - t - 0.16, u1 - t - 0.12, v0 + 1.0, v0 + 1.08, -R, -R + 0.07)
        if stoop:
            lb.box(st.trim, u0 - 0.35, u1 + 0.35, self.s.base, v0, 0.0, 0.9, back=True)
            lb.box(st.trim, u0 - 0.2, u1 + 0.2, self.s.base, v0 - 0.17, 0.9, 1.25, back=True)

    def _shop(self, u0, u1, v0, v1, _):
        st, lb = self.st, self.lb
        R, t = 0.12, 0.08
        frame = "frame_dark" if st.frame == "frame_white" and self.rng.random() < 0.5 else st.frame
        self._reveal(u0, u1, v0, v1, R, st.wall)
        lb.quad("glass_shop", [(u0, v0, -R), (u1, v0, -R), (u1, v1, -R), (u0, v1, -R)], (0, 0, 1))
        self._frame_ring(u0, u1, v0, v1, -R, t, 0.09, frame)
        panes = max(1, int((u1 - u0) / 1.5))
        self._bars(u0 + t, u1 - t, v0 + t, v1 - t, -R, panes, 1, frame, t=0.07)
        tv = v1 - 0.5
        lb.box(frame, u0 + t, u1 - t, tv - 0.04, tv + 0.04, -R, -R + 0.09)
        lb.box(st.trim, u0 - 0.05, u1 + 0.05, v0 - 0.08, v0 + 0.01, -R, 0.06)
        if self.outline.contains(box(u0, v1 + 0.05, u1, v1 + 0.5)):
            lb.box("frame_dark", u0, u1, v1 + 0.08, v1 + 0.5, 0.0, 0.1)


def _pt(p):
    from shapely.geometry import Point
    return Point(float(p[0]), float(p[1]))
