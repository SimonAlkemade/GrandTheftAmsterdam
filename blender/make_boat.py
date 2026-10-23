"""Model an Amsterdam canal sloep (an open motor launch) in Blender.

    python blender/make_boat.py godot-city/models [preview_dir]

5.4 m long and 1.9 m wide: a white hull lofted from U-shaped sections (a
fine bow, a flat transom), a mahogany rubbing strake, teak floorboards and
benches with navy cushions, a steering console with a wheel at the back, a
little Dutch flag on the stern. The origin is at the waterline in the middle;
Blender +Y is forward (the game's -Z).
"""
import math
import sys
from pathlib import Path

import bpy  # first: bmesh is only importable once bpy is loaded
import bmesh
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).parent))
from make_bikes import box, join, material, reset, tube  # noqa: E402

LENGTH = 5.4
BEAM = 1.9
TOP = 0.62          # gunwale above the waterline
FLOOR = 0.1         # the floorboards sit above it, so the canal never shows inside
KEEL = -0.38        # keel below it


def half_width(t):
    """Half the beam at t (0 = transom, 1 = bow tip)."""
    if t < 0.62:
        return BEAM / 2 * (0.86 + 0.14 * math.sin(t / 0.62 * math.pi / 2))
    u = (t - 0.62) / 0.38
    return BEAM / 2 * math.cos(u * math.pi / 2) ** 0.8


def sheer(t):
    """The gunwale rises towards the bow."""
    return TOP + 0.16 * max(0.0, t - 0.5) ** 2 * 4


def section(t, n=9):
    """A U-shaped cross-section from gunwale to gunwale, as (x, z) points."""
    w = half_width(t)
    top = sheer(t)
    keel = KEEL + 0.2 * max(0.0, t - 0.7) / 0.3      # the forefoot rises at the bow
    pts = []
    for i in range(n):
        a = math.pi * i / (n - 1)                    # 0 .. pi round the bottom
        x = -w * math.cos(a)
        bilge = math.sin(a) ** 0.6                   # full in the middle, flat-ish bottom
        z = top - (top - keel) * bilge
        pts.append((x, z))
    return pts


def hull(m_hull, m_inside, m_trim):
    rows = 22
    bm = bmesh.new()
    grid = []
    for r in range(rows):
        t = r / (rows - 1)
        y = -LENGTH / 2 + t * LENGTH
        grid.append([bm.verts.new((x, y, z)) for x, z in section(t)])
    n = len(grid[0])
    for r in range(rows - 1):
        for i in range(n - 1):
            bm.faces.new((grid[r][i], grid[r][i + 1], grid[r + 1][i + 1], grid[r + 1][i]))
    bm.faces.new(list(reversed(grid[0])))            # the transom
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("hull")
    bm.to_mesh(me)
    o = bpy.data.objects.new("hull", me)
    bpy.context.collection.objects.link(o)
    o.data.materials.append(m_hull)
    o.data.materials.append(m_inside)
    mod = o.modifiers.new("solid", "SOLIDIFY")
    mod.thickness = 0.05
    mod.material_offset = 1                          # the inside is varnished wood
    # The rubbing strake along the gunwale, both sides.
    parts = [o]
    for side in (-1, 1):
        pts = []
        for r in range(rows):
            t = r / (rows - 1)
            pts.append(Vector((side * (half_width(t) + 0.012), -LENGTH / 2 + t * LENGTH, sheer(t) - 0.02)))
        for a, b in zip(pts, pts[1:]):
            parts.append(tube(a, b, 0.035, m_trim, segs=6))
    return parts


def inner(y, z):
    """Half the inside width of the hull at length y and height z."""
    t = (y + LENGTH / 2) / LENGTH
    pts = section(t, 33)[:17]                        # the left side, gunwale down to the keel
    for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
        if z1 <= z <= z0:
            f = (z0 - z) / max(z0 - z1, 1e-6)
            return -(x0 + (x1 - x0) * f) - 0.05
    return 0.0


def floor(m):
    """The floorboards: the hull's outline at FLOOR, from the transom to near the bow."""
    bm = bmesh.new()
    left, right = [], []
    n = 16
    for i in range(n + 1):
        y = -LENGTH / 2 + 0.04 + i / n * (LENGTH * 0.86)
        w = inner(y, FLOOR)
        left.append(bm.verts.new((-w, y, FLOOR)))
        right.append(bm.verts.new((w, y, FLOOR)))
    for i in range(n):
        bm.faces.new((left[i], right[i], right[i + 1], left[i + 1]))
    me = bpy.data.meshes.new("floor")
    bm.to_mesh(me)
    o = bpy.data.objects.new("floor", me)
    bpy.context.collection.objects.link(o)
    o.data.materials.append(m)
    return o


def fittings(M):
    p = []
    # A floor of teak boards filling the hull at FLOOR, and benches above it.
    p.append(floor(M["teak"]))
    S = FLOOR + 0.3
    for y in (-0.6, 1.0):
        p.append(box((0, y, S), (2 * inner(y, S) - 0.04, 0.34, 0.05), M["teak"]))
        p.append(box((0, y, S + 0.045), (2 * inner(y, S) - 0.12, 0.3, 0.06), M["cushion"], bevel=0.02))
    # A U of benches round the stern.
    p.append(box((0, -2.35, S), (2 * inner(-2.35, S) - 0.04, 0.4, 0.05), M["teak"]))
    p.append(box((0, -2.35, S + 0.045), (2 * inner(-2.35, S) - 0.12, 0.34, 0.06), M["cushion"], bevel=0.02))
    for x in (-1, 1):
        xc = x * (inner(-1.6, S) - 0.2)
        p.append(box((xc, -1.6, S), (0.36, 1.1, 0.05), M["teak"]))
        p.append(box((xc, -1.6, S + 0.045), (0.3, 1.0, 0.06), M["cushion"], bevel=0.02))
    # The steering console and its wheel, forward of the stern benches on the right.
    p.append(box((0.3, -0.95, FLOOR + 0.3), (0.4, 0.3, 0.6), M["teak"], bevel=0.02))
    wheel_c = Vector((0.3, -1.12, FLOOR + 0.62))
    bpy.ops.mesh.primitive_torus_add(major_radius=0.16, minor_radius=0.015, location=wheel_c, rotation=(math.radians(70), 0, 0))
    o = bpy.context.object; o.data.materials.append(M["dark"]); p.append(o)
    p.append(tube(wheel_c, wheel_c + Vector((0, 0.12, 0.04)), 0.015, M["chrome"], segs=6))
    # A fender on each side, a cleat at the bow, the flag on the stern.
    for x in (-1, 1):
        p.append(tube((x * (BEAM / 2 + 0.05), 0.4, TOP - 0.1), (x * (BEAM / 2 + 0.05), 0.4, TOP - 0.45), 0.07, M["fender"], segs=10))
    pole_top = Vector((0, -LENGTH / 2 + 0.08, TOP + 0.75))
    p.append(tube((0, -LENGTH / 2 + 0.08, TOP - 0.05), pole_top, 0.012, M["teak"], segs=6))
    for k, col in enumerate(("red", "white", "blue")):
        p.append(box((0, -LENGTH / 2 - 0.12, pole_top.z - 0.05 - k * 0.07), (0.005, 0.32, 0.07), M[col]))
    return p


def mats():
    return {
        "hull": material("paint", (0.86, 0.87, 0.86), 0.0, 0.3),
        "inside": material("varnish", (0.30, 0.13, 0.05), 0.0, 0.35),
        "trim": material("mahogany", (0.28, 0.10, 0.04), 0.0, 0.35),
        "teak": material("teak", (0.55, 0.38, 0.22), 0.0, 0.6),
        "cushion": material("cushion", (0.06, 0.12, 0.28), 0.0, 0.8),
        "dark": material("dark", (0.04, 0.04, 0.045), 0.1, 0.5),
        "chrome": material("chrome", (0.75, 0.76, 0.78), 1.0, 0.22),
        "fender": material("fender", (0.08, 0.08, 0.09), 0.0, 0.7),
        "red": material("flag_red", (0.68, 0.06, 0.08), 0.0, 0.6),
        "white": material("flag_white", (0.9, 0.9, 0.9), 0.0, 0.6),
        "blue": material("flag_blue", (0.05, 0.15, 0.45), 0.0, 0.6),
    }


def build(out: Path):
    reset()
    M = mats()
    parts = hull(M["hull"], M["inside"], M["trim"]) + fittings(M)
    boat = join(parts, "boat")
    bpy.ops.object.select_all(action="DESELECT")
    boat.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(out / "boat.glb"), export_format="GLB", use_selection=True,
                              export_yup=True, export_apply=True)
    return sum(len(p.vertices) - 2 for p in boat.data.polygons)


def preview(models: Path, path: Path):
    reset()
    bpy.ops.import_scene.gltf(filepath=str(models / "boat.glb"))
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    bpy.context.object.data.materials.append(material("water", (0.08, 0.16, 0.18), 0.0, 0.15))
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    bpy.context.collection.objects.link(cam)
    cam.location = (5.2, 4.4, 2.6)
    cam.rotation_euler = (Vector((0, 0, 0.1)) - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 45
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
    print("boat: %d triangles" % build(out))
    if len(sys.argv) > 2:
        preview(out, Path(sys.argv[2]) / "boat.png")
