"""Model a Canta, the narrow Dutch two-seat microcar, in Blender.

    python blender/make_canta.py godot-city/models [preview_dir]

About 2.3 m long, 1.1 m wide and 1.5 m tall, with a short sloping nose, a
tall glasshouse, ten-inch wheels and yellow Dutch number plates. The body is
red (the material "paint", so the game can recolour it); the four wheels are
separate objects with their origins on the axles so the game can spin them.
Blender axes: +Y forward, Z up, origin on the ground in the middle.
"""
import math
import sys
from pathlib import Path

import bpy  # first: bmesh is only importable once bpy is loaded
import bmesh
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).parent))
from make_bikes import box, join, material, reset, tube  # noqa: E402

WIDTH = 1.08
WHEEL_R = 0.22
AXLES = (0.74, -0.76)
# Side profile (y forward, z up), clockwise from the bottom of the tail.
PROFILE = [(-1.12, 0.20), (-1.13, 1.30), (-1.06, 1.45), (0.28, 1.49), (0.40, 1.44),
           (0.84, 0.97), (1.07, 0.80), (1.15, 0.62), (1.15, 0.24), (1.08, 0.18)]


def prism(profile, x0, x1, m, name, bevel=0.0):
    """The profile extruded across the car from x0 to x1."""
    bm = bmesh.new()
    left = [bm.verts.new((x0, y, z)) for y, z in profile]
    right = [bm.verts.new((x1, y, z)) for y, z in profile]
    bm.faces.new(list(reversed(left)))
    bm.faces.new(right)
    n = len(profile)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((left[i], left[j], right[j], right[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 3
        mod.limit_method = "ANGLE"
    o.data.materials.append(m)
    return o


def panel(corners, m, name):
    """A flat quad (glass, a plate) through four points."""
    bm = bmesh.new()
    bm.faces.new([bm.verts.new(c) for c in corners])
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    mod = o.modifiers.new("solid", "SOLIDIFY")
    mod.thickness = 0.01
    o.data.materials.append(m)
    return o


def wheel(y, x, M, name):
    c = Vector((x, y, WHEEL_R))
    s = 1 if x > 0 else -1
    parts = [tube(c - Vector((0.06, 0, 0)), c + Vector((0.06, 0, 0)), WHEEL_R, M["tyre"], segs=20),
             tube(c + Vector((s * 0.055, 0, 0)), c + Vector((s * 0.064, 0, 0)), 0.13, M["chrome"], segs=16)]
    for k in range(4):                               # wheel nuts, so the spin shows
        a = k * math.pi / 2
        p = c + Vector((s * 0.066, 0.06 * math.cos(a), 0.06 * math.sin(a)))
        parts.append(tube(p, p + Vector((s * 0.012, 0, 0)), 0.014, M["dark"], segs=6))
    return join(parts, name, origin=c)


def canta(M):
    half = WIDTH / 2
    p = [prism(PROFILE, -half, half, M["paint"], "shell", bevel=0.07)]
    # Glass: side windows, windscreen, rear window.
    for x in (-half - 0.004, half + 0.004):
        p.append(panel([(x, -0.98, 0.98), (x, 0.70, 0.98), (x, 0.30, 1.40), (x, -0.98, 1.38)], M["glass"], "side"))
    p.append(panel([(-0.46, 0.83, 1.00), (0.46, 0.83, 1.00), (0.44, 0.40, 1.455), (-0.44, 0.40, 1.455)], M["glass"], "screen"))
    p.append(panel([(-0.42, -1.137, 0.98), (0.42, -1.137, 0.98), (0.40, -1.137, 1.34), (-0.40, -1.137, 1.34)], M["glass"], "rear"))
    # Door seams, bumpers, lights, plates, mirrors.
    for x in (-half - 0.006, half + 0.006):
        p.append(box((x, 0.70, 0.62), (0.006, 0.012, 0.62), M["dark"]))
        p.append(box((x, -0.40, 0.62), (0.006, 0.012, 0.62), M["dark"]))
        p.append(box((x, 0.12, 0.78), (0.012, 0.12, 0.02), M["chrome"]))   # door handle strip
        p.append(box((x + (0.06 if x > 0 else -0.06), 0.62, 1.05), (0.1, 0.03, 0.08), M["dark"], bevel=0.01))
    p.append(box((0, 1.17, 0.30), (WIDTH + 0.02, 0.08, 0.14), M["dark"], bevel=0.03))
    p.append(box((0, -1.15, 0.30), (WIDTH + 0.02, 0.08, 0.14), M["dark"], bevel=0.03))
    for x in (-0.36, 0.36):
        p.append(tube((x, 1.13, 0.62), (x, 1.17, 0.62), 0.07, M["lamp"], segs=16))
        p.append(box((x, -1.145, 0.68), (0.16, 0.02, 0.1), M["tail"]))
    p.append(box((0, 1.215, 0.30), (0.34, 0.01, 0.09), M["plate"]))
    p.append(box((0, -1.195, 0.55), (0.34, 0.01, 0.09), M["plate"]))
    p.append(tube((-0.30, 0.80, 1.02), (0.12, 0.72, 1.10), 0.008, M["dark"], segs=4))   # the wiper
    return join(p, "body")


def mats():
    return {
        "paint": material("paint", (0.62, 0.03, 0.04), 0.2, 0.3),
        "glass": material("glass", (0.03, 0.05, 0.06), 0.6, 0.08),
        "dark": material("dark", (0.04, 0.04, 0.045), 0.1, 0.6),
        "tyre": material("tyre", (0.03, 0.03, 0.03), 0.0, 0.85),
        "chrome": material("chrome", (0.75, 0.76, 0.78), 1.0, 0.22),
        "lamp": material("lamp", (1.0, 0.97, 0.88), 0.0, 0.15, emit=(1.0, 0.92, 0.75)),
        "tail": material("tail", (0.55, 0.02, 0.02), 0.0, 0.3, emit=(0.6, 0.02, 0.02)),
        "plate": material("plate", (0.95, 0.75, 0.05), 0.0, 0.4),
    }


def build(out: Path):
    reset()
    M = mats()
    parts = [canta(M)]
    for y, front in zip(AXLES, ("f", "r")):
        for x, side in ((-0.50, "l"), (0.50, "r")):
            parts.append(wheel(y, x, M, "wheel_%s%s" % (front, side)))
    bpy.ops.object.select_all(action="DESELECT")
    for o in parts:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(out / "canta.glb"), export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True)
    return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in parts)


def preview(models: Path, path: Path):
    reset()
    bpy.ops.import_scene.gltf(filepath=str(models / "canta.glb"))
    bpy.ops.mesh.primitive_plane_add(size=20)
    bpy.context.object.data.materials.append(material("floor", (0.55, 0.53, 0.5), 0, 0.8))
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    bpy.context.collection.objects.link(cam)
    cam.location = (3.6, 3.0, 1.7)
    cam.rotation_euler = (Vector((0, 0, 0.7)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 50
    bpy.context.scene.camera = cam
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4.0
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(140))
    bpy.context.collection.objects.link(sun)
    world = bpy.data.worlds.new("w"); world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.6, 0.7, 0.85, 1)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8
    bpy.context.scene.world = world
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 48
    sc.render.resolution_x, sc.render.resolution_y = 1280, 720
    sc.render.filepath = str(path)
    bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    print("canta: %d triangles" % build(out))
    if len(sys.argv) > 2:
        preview(out, Path(sys.argv[2]) / "canta.png")
