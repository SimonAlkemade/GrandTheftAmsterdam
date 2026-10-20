"""Procedural, tileable PBR textures and the material table.

Every texture is generated from a fixed seed, so the same build always
writes byte-identical PNGs. Each material declares how many metres one
texture tile covers; generators use metric UVs divided by that.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

import numpy as np

SIZE = 512


def png_bytes(img: np.ndarray) -> bytes:
    """uint8 (H, W, 3|4) -> PNG, stdlib only."""
    img = np.ascontiguousarray(img, np.uint8)
    h, w, c = img.shape
    raw = b"".join(b"\x00" + img[y].tobytes() for y in range(h))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    color = {3: 2, 4: 6}[c]
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def _noise(rng, size, octaves=4):
    """Tileable value noise in [0, 1]."""
    out = np.zeros((size, size))
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cells = 4 * 2 ** o
        grid = rng.random((cells, cells))
        x = np.linspace(0, cells, size, endpoint=False)
        i0 = np.floor(x).astype(int)
        t = x - i0
        t = t * t * (3 - 2 * t)
        i1 = (i0 + 1) % cells
        a = grid[np.ix_(i0, i0)] * (1 - t)[None, :] + grid[np.ix_(i0, i1)] * t[None, :]
        b = grid[np.ix_(i1, i0)] * (1 - t)[None, :] + grid[np.ix_(i1, i1)] * t[None, :]
        out += amp * (a * (1 - t)[:, None] + b * t[:, None])
        total += amp
        amp *= 0.5
    return out / total


def _normal_map(height: np.ndarray, strength: float) -> np.ndarray:
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * strength
    dy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * strength
    # Image row r is texcoord v = r / size (glTF has v=0 at the top row), so
    # rows already run along +v and green is -dh/dv.
    n = np.stack([-dx, -dy, np.ones_like(height)], axis=-1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return ((n * 0.5 + 0.5) * 255).astype(np.uint8)


def _rgb(color, shade):
    c = np.asarray(color, float)[None, None, :] * shade[..., None]
    return np.clip(c, 0, 255).astype(np.uint8)


def brick(seed, base, mortar=(178, 170, 156), courses=16, per_row=4, spread=0.18,
          hue_jitter=0.06):
    """1 m tile of Dutch running bond: 16 courses of ~6 cm."""
    rng = np.random.default_rng(seed)
    s = SIZE
    y, x = np.mgrid[0:s, 0:s]
    ch = s // courses
    row = y // ch
    bw = s // per_row
    xo = (x + (row % 2) * bw // 2) % s
    col = xo // bw
    joint = 3
    in_mortar = ((y % ch) < joint) | ((xo % bw) < joint)
    tone = rng.normal(1.0, spread / 2, (courses, per_row + 1))
    hue = rng.normal(0, hue_jitter, (courses, per_row + 1, 3))
    brick_c = np.asarray(base, float)[None, None, :] * (tone[row, col][..., None] + hue[row, col])
    n = _noise(rng, s, 5)
    brick_c *= (0.85 + 0.3 * n)[..., None]
    mort = np.asarray(mortar, float)[None, None, :] * (0.85 + 0.25 * n)[..., None]
    color = np.where(in_mortar[..., None], mort, brick_c)
    height = np.where(in_mortar, 0.0, 1.0) + 0.15 * n
    return np.clip(color, 0, 255).astype(np.uint8), _normal_map(height, 2.5)


def tiles(seed, base, rows=8, per_row=4):
    """Pantiles / slates on a 2 m tile: rows overlap downwards.
    rows and per_row must divide SIZE so the tile repeats seamlessly."""
    rng = np.random.default_rng(seed)
    s = SIZE
    y, x = np.mgrid[0:s, 0:s]
    rh = s // rows
    row = y // rh
    tw = s // per_row
    xo = (x + (row % 2) * tw // 2) % s
    col = xo // tw
    t = (y % rh) / rh                     # 0 at bottom edge of a course
    wave = 0.5 + 0.5 * np.cos(2 * np.pi * (xo % tw) / tw)
    tone = rng.normal(1.0, 0.08, (rows, per_row + 1))[row, col]
    n = _noise(rng, s, 4)
    shade = tone * (0.55 + 0.45 * np.clip(t * 3, 0, 1)) * (0.8 + 0.3 * n) * (0.85 + 0.15 * wave)
    height = t + 0.3 * wave + 0.1 * n
    return _rgb(base, shade), _normal_map(height, 3.0)


def cobbles(seed, base=(118, 112, 104), cells=16):
    """Kinderkopjes: rounded setts in staggered rows on a 2 m tile."""
    rng = np.random.default_rng(seed)
    s = SIZE
    y, x = np.mgrid[0:s, 0:s]
    ch = s // cells
    row = y // ch
    cw = s // (cells // 2)
    xo = (x + (row % 2) * cw // 2) % s
    col = xo // cw
    fy = (y % ch) / ch - 0.5
    fx = (xo % cw) / cw - 0.5
    dome = np.clip(1 - (fx * 2) ** 4 - (fy * 2) ** 4, 0, 1)
    tone = rng.normal(1.0, 0.12, (cells, cells))[row % cells, col % cells]
    n = _noise(rng, s, 5)
    shade = (0.35 + 0.65 * dome ** 0.5) * tone * (0.8 + 0.3 * n)
    return _rgb(base, shade), _normal_map(dome + 0.05 * n, 4.0)


def plain(seed, base, grain=0.12, octaves=5):
    rng = np.random.default_rng(seed)
    n = _noise(rng, SIZE, octaves)
    return _rgb(base, 1 - grain / 2 + grain * n), None


def wood(seed, base):
    rng = np.random.default_rng(seed)
    s = SIZE
    y = np.mgrid[0:s, 0:s][0]
    n = _noise(rng, s, 5)
    streak = 0.85 + 0.15 * np.sin(y / s * 2 * np.pi * 24 + n * 8)
    return _rgb(base, streak * (0.9 + 0.1 * n)), None


@dataclass
class Material:
    name: str
    tile_m: float                     # metres per texture repeat
    color: tuple = (1, 1, 1, 1)       # baseColorFactor
    roughness: float = 0.9
    metallic: float = 0.0
    texture: object = None            # callable -> (rgb, normal|None)


def _brick(base, seed, mortar=(178, 170, 156), painted=False):
    # Paint evens out the bricks: little tone spread and no colour cast.
    if painted:
        return lambda: brick(seed, base, mortar, spread=0.05, hue_jitter=0.0)
    return lambda: brick(seed, base, mortar)


MATERIALS = {m.name: m for m in [
    # Walls. Amsterdam brick runs from near-black brown to orange-red.
    Material("brick_red", 1.0, texture=_brick((150, 62, 44), 11)),
    Material("brick_brown", 1.0, texture=_brick((104, 58, 42), 12)),
    Material("brick_dark", 1.0, texture=_brick((70, 44, 36), 13, (120, 114, 104))),
    Material("brick_orange", 1.0, texture=_brick((168, 92, 56), 14)),
    Material("brick_yellow", 1.0, texture=_brick((176, 146, 98), 15)),
    Material("brick_painted_white", 1.0, roughness=0.8,
             texture=_brick((228, 224, 212), 16, (205, 200, 190), painted=True)),
    Material("brick_painted_grey", 1.0, roughness=0.8,
             texture=_brick((120, 124, 122), 17, (104, 106, 104), painted=True)),
    Material("plaster_cream", 2.0, roughness=0.85,
             texture=lambda: plain(18, (226, 214, 186), 0.08)),
    Material("concrete", 2.0, texture=lambda: plain(19, (150, 148, 142), 0.18)),
    # Trim.
    Material("stone", 1.0, texture=lambda: plain(20, (200, 190, 168), 0.16)),
    Material("frame_white", 1.0, (0.92, 0.92, 0.9, 1), 0.5),
    Material("frame_dark", 1.0, (0.09, 0.1, 0.1, 1), 0.5),
    Material("frame_green", 1.0, (0.08, 0.2, 0.15, 1), 0.5),
    Material("door_green", 1.0, roughness=0.45, texture=lambda: wood(21, (28, 62, 46))),
    Material("door_black", 1.0, roughness=0.4, texture=lambda: wood(22, (26, 26, 28))),
    Material("door_red", 1.0, roughness=0.45, texture=lambda: wood(23, (110, 28, 26))),
    Material("door_wood", 1.0, roughness=0.6, texture=lambda: wood(24, (92, 60, 36))),
    Material("shutter_green", 1.0, roughness=0.5, texture=lambda: wood(25, (30, 76, 52))),
    Material("shutter_red", 1.0, roughness=0.5, texture=lambda: wood(26, (126, 36, 30))),
    Material("timber", 1.0, roughness=0.7, texture=lambda: wood(27, (60, 42, 30))),
    Material("glass", 1.0, (0.05, 0.07, 0.08, 1), 0.08, 0.6),
    Material("glass_shop", 1.0, (0.12, 0.13, 0.12, 1), 0.05, 0.5),
    # Roofs and ground.
    Material("roof_tiles_dark", 2.0, texture=lambda: tiles(30, (64, 62, 62))),
    Material("roof_tiles_red", 2.0, texture=lambda: tiles(31, (132, 56, 40))),
    Material("roof_slate", 2.0, texture=lambda: tiles(32, (58, 64, 74), rows=16, per_row=8)),
    Material("roof_flat", 4.0, texture=lambda: plain(33, (60, 60, 62), 0.3, 6)),
    Material("ground_cobble", 2.0, texture=lambda: cobbles(34)),
]}


def uv_scale(name: str) -> float:
    return MATERIALS[name].tile_m
