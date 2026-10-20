"""Minimal glTF 2.0 binary writer: one node per building, one primitive per
material, textures embedded. Y-up on export: (x, y, z)_RD -> (x, z, -y)."""
from __future__ import annotations

import json
import struct

import numpy as np

from .materials import MATERIALS, png_bytes

FLOAT, UINT32 = 5126, 5125
ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER = 34962, 34963


def _to_y_up(v: np.ndarray) -> np.ndarray:
    return np.stack([v[:, 0], v[:, 2], -v[:, 1]], axis=1)


class _Buffer:
    def __init__(self):
        self.chunks: list[bytes] = []
        self.length = 0
        self.views: list[dict] = []

    def add(self, data: bytes, target=None) -> int:
        pad = (-self.length) % 4
        if pad:
            self.chunks.append(b"\x00" * pad)
            self.length += pad
        view = {"buffer": 0, "byteOffset": self.length, "byteLength": len(data)}
        if target:
            view["target"] = target
        self.chunks.append(data)
        self.length += len(data)
        self.views.append(view)
        return len(self.views) - 1


def write_glb(path, district, scene_name="amsterdam") -> dict:
    buf = _Buffer()
    accessors, meshes, nodes = [], [], []
    used: dict[str, int] = {}

    def accessor(arr: np.ndarray, kind: str, target, comp=FLOAT, minmax=False) -> int:
        dtype = np.float32 if comp == FLOAT else np.uint32
        data = np.ascontiguousarray(arr, dtype)
        acc = {"bufferView": buf.add(data.tobytes(), target), "componentType": comp,
               "count": int(len(data)), "type": kind}
        if minmax:
            acc["min"] = data.min(0).tolist()
            acc["max"] = data.max(0).tolist()
        accessors.append(acc)
        return len(accessors) - 1

    for name, mesh, extras in district.nodes:
        prims = []
        for mat, rows in sorted(mesh.arrays().items()):
            pos = _to_y_up(rows[:, 0:3])
            nrm = _to_y_up(rows[:, 3:6])
            uv = rows[:, 6:8]
            verts = np.hstack([pos, nrm, uv]).astype(np.float32)
            uniq, index = np.unique(verts, axis=0, return_inverse=True)
            index = index.reshape(-1)
            prims.append({
                "attributes": {
                    "POSITION": accessor(uniq[:, 0:3], "VEC3", ARRAY_BUFFER, minmax=True),
                    "NORMAL": accessor(uniq[:, 3:6], "VEC3", ARRAY_BUFFER),
                    "TEXCOORD_0": accessor(uniq[:, 6:8], "VEC2", ARRAY_BUFFER),
                },
                "indices": accessor(index, "SCALAR", ELEMENT_ARRAY_BUFFER, UINT32),
                "material": used.setdefault(mat, len(used)),
            })
        if not prims:
            continue
        meshes.append({"name": name, "primitives": prims})
        node = {"name": name, "mesh": len(meshes) - 1}
        clean = {k: v for k, v in extras.items() if v is not None}
        if clean:
            node["extras"] = clean
        nodes.append(node)

    images, textures, materials = [], [], []

    def texture(img) -> int:
        images.append({"bufferView": buf.add(png_bytes(img)), "mimeType": "image/png"})
        textures.append({"source": len(images) - 1, "sampler": 0})
        return len(textures) - 1

    for mat in sorted(used, key=used.get):
        m = MATERIALS[mat]
        pbr = {"baseColorFactor": list(m.color), "metallicFactor": m.metallic,
               "roughnessFactor": m.roughness}
        entry = {"name": mat, "pbrMetallicRoughness": pbr}
        if m.texture:
            color, normal = m.texture()
            pbr["baseColorTexture"] = {"index": texture(color)}
            if normal is not None:
                entry["normalTexture"] = {"index": texture(normal)}
        materials.append(entry)

    o = district.origin
    doc = {
        "asset": {"version": "2.0", "generator": "gta-amsterdam facade upscaler"},
        "scene": 0,
        "scenes": [{"name": scene_name, "nodes": list(range(len(nodes))),
                    "extras": {"crs": "EPSG:28992",
                               "origin_rd": [float(o[0]), float(o[1]), float(o[2])],
                               "axes": "glTF +X = RD east, +Y = up, -Z = RD north"}}],
        "nodes": nodes, "meshes": meshes, "materials": materials,
        "textures": textures, "images": images,
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "accessors": accessors, "bufferViews": buf.views,
        "buffers": [{"byteLength": buf.length}],
    }
    bin_data = b"".join(buf.chunks)
    bin_data += b"\x00" * ((-len(bin_data)) % 4)
    doc["buffers"][0]["byteLength"] = len(bin_data)
    js = json.dumps(doc, separators=(",", ":")).encode()
    js += b" " * ((-len(js)) % 4)
    total = 12 + 8 + len(js) + 8 + len(bin_data)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(js), 0x4E4F534A) + js)
        f.write(struct.pack("<II", len(bin_data), 0x004E4942) + bin_data)
    return {"nodes": len(nodes), "materials": len(materials), "bytes": total,
            "triangles": district.triangle_count()}
