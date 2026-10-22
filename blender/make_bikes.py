"""Model Dutch city bikes in Blender and export them for the game.

    python blender/make_bikes.py godot-city/models [preview_dir]

(run with a Python that has the `bpy` module, e.g. `pip install bpy`).

Two frames: the step-through "oma" and the diamond "opa", both with 28-inch
wheels, swept-back bars, a closed chain guard, mudguards, a rear rack and a
front lamp. For each:
  bike_<frame>.glb         wheels, crank and kickstand as separate objects
                           (origins on their axles) so the game can spin
                           and fold them;
  bike_<frame>_low.glb     the same at less detail, for the cyclists in traffic;
  bike_<frame>_parked.glb  everything joined into one plainer mesh for the racks.
The frame paint is a material called "paint" so the game can recolour it.
Blender axes: +Y is forward, Z up, the origin on the ground between the
wheels; glTF export turns +Y into -Z, Godot's forward.
"""
import math
import sys
from pathlib import Path

import bpy  # first: bmesh is only importable once bpy is loaded
import bmesh
from mathutils import Vector

R_AXLE = 0.355                       # 28" wheel: tyre outer radius
REAR = Vector((0, -0.56, R_AXLE))
FRONT = Vector((0, 0.58, R_AXLE))
BB = Vector((0, -0.02, 0.29))        # bottom bracket
SEAT_TOP = Vector((0, -0.18, 0.86))
HEAD_LOW = Vector((0, 0.40, 0.70))
HEAD_TOP = Vector((0, 0.36, 0.86))

# Detail levels: the ridden bike is seen up close; parked bikes are many.
HIGH = {"tube": 10, "spokes": 18, "ring": (48, 8), "bevel": 2, "curve": 4, "blob": 16, "box": 3}
LOW = {"tube": 5, "spokes": 8, "ring": (20, 4), "bevel": 0, "curve": 2, "blob": 8, "box": 1}
PARKED = {"tube": 4, "spokes": 0, "ring": (14, 3), "bevel": 0, "curve": 1, "blob": 6, "box": 1}
D = dict(HIGH)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def material(name, color, metal=0.0, rough=0.5, emit=None):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes["Principled BSDF"]
    p.inputs["Base Color"].default_value = (*color, 1)
    p.inputs["Metallic"].default_value = metal
    p.inputs["Roughness"].default_value = rough
    if emit:
        p.inputs["Emission Color"].default_value = (*emit, 1)
        p.inputs["Emission Strength"].default_value = 2.0
    return m


def _assign(obj, m):
    obj.data.materials.clear()
    obj.data.materials.append(m)
    return obj


def tube(p0, p1, r, m, segs=None):
    segs = segs or D["tube"]
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    bpy.ops.mesh.primitive_cylinder_add(vertices=segs, radius=r, depth=d.length, location=(p0 + p1) / 2)
    o = bpy.context.object
    o.rotation_mode = "QUATERNION"
    o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    return _assign(o, m)


def bent(points, r, m):
    """A tube along a smooth curve through the points."""
    cu = bpy.data.curves.new("bent", "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = r
    cu.bevel_resolution = D["bevel"]
    cu.use_fill_caps = True
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for bp, p in zip(sp.bezier_points, points):
        bp.co = p
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    sp.resolution_u = D["curve"]
    o = bpy.data.objects.new("bent", cu)
    bpy.context.collection.objects.link(o)
    bpy.context.view_layer.objects.active = o
    o.select_set(True)
    bpy.ops.object.convert(target="MESH")
    return _assign(bpy.context.object, m)


def torus_x(center, R, r, m, major=None, minor=None):
    """A ring in the bike's plane (around the X axis)."""
    k = D["ring"][0] / 48.0
    major = max(8, int((major or 48) * k)); minor = max(3, int((minor or 8) * D["ring"][1] / 8))
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=major, minor_segments=minor,
                                     location=center, rotation=(0, math.pi / 2, 0))
    return _assign(bpy.context.object, m)


def blob(center, scale, m, segs=None):
    segs = segs or D["blob"]
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segs, ring_count=segs // 2, radius=1, location=center)
    o = bpy.context.object
    o.scale = scale
    return _assign(o, m)


def box(center, size, m, bevel=0.0):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center)
    o = bpy.context.object
    o.scale = size
    bpy.ops.object.transform_apply(scale=True)
    if bevel:
        mod = o.modifiers.new("bevel", "BEVEL")
        mod.width = bevel
        mod.segments = D["box"]
    return _assign(o, m)


def arc_strip(center, R, a0, a1, width, m, n=None):
    n = n or (28 if D is HIGH or D["tube"] > 6 else 10)
    """A curved strip in the bike's plane: angles from +Y towards +Z."""
    bm = bmesh.new()
    rows = []
    for i in range(n + 1):
        a = math.radians(a0 + (a1 - a0) * i / n)
        y = center[1] + R * math.cos(a); z = center[2] + R * math.sin(a)
        # a slightly domed cross-section, like a real mudguard
        rows.append([bm.verts.new((x, y + 0.012 * (1 - (2 * x / width) ** 2) * math.cos(a),
                                   z + 0.012 * (1 - (2 * x / width) ** 2) * math.sin(a)))
                     for x in (-width / 2, -width / 4, 0, width / 4, width / 2)])
    for i in range(n):
        for k in range(4):
            bm.faces.new((rows[i][k], rows[i + 1][k], rows[i + 1][k + 1], rows[i][k + 1]))
    me = bpy.data.meshes.new("arc")
    bm.to_mesh(me)
    o = bpy.data.objects.new("arc", me)
    bpy.context.collection.objects.link(o)
    mod = o.modifiers.new("solid", "SOLIDIFY")
    mod.thickness = 0.003
    return _assign(o, m)


def join(objs, name, origin=None):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        if o.modifiers:
            for mod in list(o.modifiers):
                bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    o = bpy.context.object
    o.name = name
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if origin is not None:
        bpy.context.scene.cursor.location = origin
        bpy.ops.object.origin_set(type="ORIGIN_CURSOR")
    bpy.ops.object.shade_auto_smooth(angle=math.radians(40))
    return o


def wheel(center, M, name):
    parts = [
        torus_x(center, 0.334, 0.021, M["tyre"]),
        torus_x(center, 0.311, 0.009, M["chrome"], minor=6),
        tube(center + Vector((-0.05, 0, 0)), center + Vector((0.05, 0, 0)), 0.024, M["chrome"]),
    ]
    ns = D["spokes"]
    for i in range(ns):                          # spokes, laced from both hub flanges
        a = 2 * math.pi * i / ns
        side = 0.03 if i % 2 else -0.03
        hub = center + Vector((side, 0.022 * math.cos(a), 0.022 * math.sin(a)))
        rim = center + Vector((0, 0.305 * math.cos(a + 0.35), 0.305 * math.sin(a + 0.35)))
        parts.append(tube(hub, rim, 0.0013, M["chrome"], segs=3))
    return join(parts, name, origin=center)


def crank(M):
    parts = [torus_x(BB + Vector((0.075, 0, 0)), 0.09, 0.006, M["dark"], major=32, minor=6),
             tube(BB + Vector((-0.07, 0, 0)), BB + Vector((0.07, 0, 0)), 0.012, M["dark"])]
    for side, ang in ((0.085, 0.0), (-0.085, math.pi)):
        end = BB + Vector((side, 0.17 * math.cos(ang - 1.2), 0.17 * math.sin(ang - 1.2)))
        parts.append(tube(BB + Vector((side, 0, 0)), end, 0.009, M["chrome"]))
        parts.append(box(end + Vector((0.05 if side > 0 else -0.05, 0, 0)), (0.09, 0.06, 0.02), M["dark"], bevel=0.004))
    return join(parts, "crank", origin=BB)


def frame(kind, M):
    paint, chrome, dark = M["paint"], M["chrome"], M["dark"]
    p = [tube(BB, SEAT_TOP, 0.016, paint), tube(HEAD_LOW, HEAD_TOP, 0.019, paint)]
    if kind == "oma":                            # two swooping step-through tubes
        p.append(bent([HEAD_TOP + Vector((0, 0.012, -0.05)), Vector((0, 0.22, 0.58)), Vector((0, 0.06, 0.34)), BB + Vector((0, 0.01, 0.01))], 0.016, paint))
        p.append(bent([HEAD_LOW + Vector((0, 0.0, 0.02)), Vector((0, 0.22, 0.47)), Vector((0, 0.08, 0.30)), BB + Vector((0, 0.03, 0.0))], 0.014, paint))
    else:                                        # diamond: top tube and straight down tube
        p.append(tube(HEAD_TOP + Vector((0, 0.01, -0.04)), SEAT_TOP + Vector((0, 0.01, -0.03)), 0.016, paint))
        p.append(tube(HEAD_LOW + Vector((0, 0.0, 0.02)), BB, 0.018, paint))
    for x in (-0.055, 0.055):                    # chain and seat stays, fork legs
        p.append(tube(REAR + Vector((x, 0, 0)), BB + Vector((x * 0.4, 0, 0)), 0.010, paint))
        p.append(tube(REAR + Vector((x, 0, 0)), SEAT_TOP + Vector((x * 0.3, 0.02, -0.07)), 0.009, paint))
        p.append(bent([HEAD_LOW + Vector((x * 0.6, 0, 0.0)), Vector((x, 0.47, 0.53)), FRONT + Vector((x, 0, 0))], 0.011, paint))
    p.append(tube(HEAD_LOW + Vector((-0.06, 0.005, 0)), HEAD_LOW + Vector((0.06, 0.005, 0)), 0.014, paint))   # fork crown
    # Seat post, sprung leather saddle.
    post_top = SEAT_TOP + Vector((0, -0.035, 0.11))
    p.append(tube(SEAT_TOP, post_top, 0.012, chrome))
    p.append(blob(post_top + Vector((0, -0.03, 0.035)), (0.085, 0.13, 0.03), M["leather"]))
    p.append(blob(post_top + Vector((0, 0.045, 0.036)), (0.04, 0.09, 0.024), M["leather"]))   # the nose
    for x in (-0.05, 0.05):
        p.append(tube(post_top + Vector((x, -0.11, -0.005)), post_top + Vector((x, -0.11, 0.03)), 0.012, chrome))
    # Stem and swept-back bars with grips and a bell.
    bar_mid = HEAD_TOP + Vector((0, 0.0, 0.16))
    p.append(tube(HEAD_TOP, bar_mid, 0.012, chrome))
    p.append(bent([Vector((-0.27, 0.12, 1.05)), Vector((-0.26, 0.30, 1.04)), Vector((-0.12, 0.38, 1.02)), bar_mid,
                   Vector((0.12, 0.38, 1.02)), Vector((0.26, 0.30, 1.04)), Vector((0.27, 0.12, 1.05))], 0.011, chrome))
    for x in (-0.27, 0.27):
        p.append(tube(Vector((x, 0.24, 1.047)), Vector((x, 0.10, 1.05)), 0.017, M["grip"]))
    p.append(blob(Vector((-0.13, 0.385, 1.045)), (0.024, 0.024, 0.012), chrome))
    # Lamp on the fork crown.
    p.append(tube(HEAD_LOW + Vector((0, 0.07, 0.02)), HEAD_LOW + Vector((0, 0.13, 0.02)), 0.033, dark))
    p.append(tube(HEAD_LOW + Vector((0, 0.13, 0.02)), HEAD_LOW + Vector((0, 0.135, 0.02)), 0.028, M["lamp"]))
    # Closed chain guard over the chain, on the right.
    p.append(box(Vector((0.075, (BB.y + REAR.y) / 2, (BB.z + REAR.z) / 2 + 0.01)), (0.035, 0.66, 0.15), paint, bevel=0.016))
    # Mudguards.
    p.append(arc_strip(REAR, 0.37, 35, 205, 0.055, paint))
    p.append(arc_strip(FRONT, 0.37, -20, 140, 0.055, paint))
    # Rear rack.
    for x in (-0.07, 0.07):
        p.append(tube(Vector((x, -0.30, 0.64)), Vector((x, -0.86, 0.64)), 0.007, dark))
        p.append(tube(Vector((x, -0.80, 0.64)), REAR + Vector((x * 0.9, 0, 0)), 0.006, dark))
        p.append(tube(Vector((x, -0.32, 0.64)), SEAT_TOP + Vector((x * 0.3, 0.0, -0.12)), 0.005, dark))
    for y in (-0.42, -0.58, -0.74, -0.86):
        p.append(tube(Vector((-0.07, y, 0.64)), Vector((0.07, y, 0.64)), 0.006, dark))
    p.append(blob(Vector((0, -0.87, 0.60)), (0.04, 0.012, 0.022), M["reflector"]))
    return join(p, "frame")


def stand(M):
    return join([tube(Vector((-0.04, -0.30, 0.32)), Vector((-0.17, -0.36, 0.004)), 0.009, M["dark"]),
                 box(Vector((-0.17, -0.36, 0.006)), (0.03, 0.05, 0.012), M["dark"])], "stand")


def mats():
    return {
        "paint": material("paint", (0.02, 0.022, 0.025), 0.3, 0.35),
        "chrome": material("chrome", (0.75, 0.76, 0.78), 1.0, 0.22),
        "dark": material("dark", (0.04, 0.04, 0.045), 0.2, 0.5),
        "tyre": material("tyre", (0.03, 0.03, 0.03), 0.0, 0.85),
        "leather": material("leather", (0.20, 0.10, 0.05), 0.0, 0.55),
        "grip": material("grip", (0.18, 0.09, 0.04), 0.0, 0.6),
        "lamp": material("lamp", (1.0, 0.95, 0.8), 0.0, 0.2, emit=(1.0, 0.9, 0.7)),
        "reflector": material("reflector", (0.7, 0.02, 0.02), 0.0, 0.3),
    }


def export(path, objs):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True, export_materials="EXPORT")


def _tris(objs):
    return sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in objs)


def _parts(kind):
    M = mats()
    return [frame(kind, M), wheel(REAR, M, "wheel_rear"), wheel(FRONT, M, "wheel_front"), crank(M), stand(M)]


def build(kind, out: Path):
    D.clear(); D.update(HIGH)
    reset()
    parts = _parts(kind)
    export(out / ("bike_%s.glb" % kind), parts)
    high = _tris(parts)
    D.clear(); D.update(LOW)
    reset()
    parts = _parts(kind)
    export(out / ("bike_%s_low.glb" % kind), parts)
    low = _tris(parts)
    # The parked bike: one plain mesh, kickstand down.
    D.clear(); D.update(PARKED)
    reset()
    parked = join(_parts(kind), "bike_parked")
    export(out / ("bike_%s_parked.glb" % kind), [parked])
    return high, low, _tris([parked])


def preview(models: Path, path: Path):
    """A studio render of both ridden-detail bikes side by side."""
    reset()
    for i, kind in enumerate(("oma", "opa")):
        bpy.ops.import_scene.gltf(filepath=str(models / ("bike_%s.glb" % kind)))
        for o in bpy.context.selected_objects:
            o.location.x += -0.55 + 1.1 * i
            if kind == "opa":
                for s in o.material_slots:
                    if s.material and s.material.name.startswith("paint"):
                        m = s.material.copy(); s.material = m
                        m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.05, 0.16, 0.10, 1)
    bpy.ops.mesh.primitive_plane_add(size=20)
    bpy.context.object.data.materials.append(material("floor", (0.55, 0.53, 0.5), 0, 0.8))
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    bpy.context.collection.objects.link(cam)
    cam.location = (3.4, 1.0, 1.25)
    d = Vector((0, 0, 0.55)) - cam.location
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 50
    bpy.context.scene.camera = cam
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 4.0
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(30))
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
    for kind in ("oma", "opa"):
        high, low, parked = build(kind, out)
        print("%s: %d triangles ridden, %d in traffic, %d parked" % (kind, high, low, parked))
    if len(sys.argv) > 2:
        preview(out, Path(sys.argv[2]) / "bikes.png")
