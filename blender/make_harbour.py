"""Model the container yard of the first mission in Blender.

    python blender/make_harbour.py godot-city/models

    container.glb    a 40 ft shipping container (12.19 x 2.44 x 2.59 m): corrugated
                     steel, corner castings, a wooden floor, two doors at its end
                     with locking bars, hinged (nodes door_l, door_r) so the game
                     opens them. Painted white: the game paints each one.
    fence.glb        a 3 m panel of chain-link fence, 2.4 m high, posts, top rail
                     and three strands of barbed wire.
    fence_cut.glb    the same panel with a flap cut out at its foot (node flap,
                     hinged at its top) and the animation "peel": the cut flap
                     bent up and back, the way you go under.
    bolt_cutter.glb  bolt cutters, 0.76 m: two arms on a pivot (arm_a, arm_b) and
                     the animation "cut": the handles squeezed, the jaws shut.
    duffel.glb       a duffel bag, 0.7 m, its origin at the top of its handles.

Blender +Y is forward (the game's -Z); +Z is up; the origin is on the ground.
"""
import math
import sys
from pathlib import Path

import bpy  # first: bmesh is only importable once bpy is loaded
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from make_bikes import box, join, material, reset, tube  # noqa: E402

L, W, H = 12.19, 2.44, 2.59        # the container, outside
WALL = 0.05
FENCE_W, FENCE_H = 3.0, 2.4
HOLE_W, HOLE_H = 1.1, 0.85        # the cut flap
LINK = 0.30                        # metres of chain link one texture tile covers


def _mats():
    return {
        "paint": material("paint", (0.92, 0.92, 0.92), 0.2, 0.55),
        "steel": material("steel", (0.32, 0.33, 0.34), 0.7, 0.45),
        "floor": material("floor", (0.33, 0.22, 0.13), 0.0, 0.85),
        "galv": material("galv", (0.62, 0.64, 0.66), 0.8, 0.35),
        "rubber": material("rubber", (0.72, 0.08, 0.06), 0.0, 0.7),
        "black": material("black", (0.05, 0.05, 0.05), 0.2, 0.6),
        "fabric": material("fabric", (0.045, 0.06, 0.035), 0.0, 0.9),
        "strap": material("strap", (0.06, 0.06, 0.06), 0.0, 0.75),
    }


def export(path: Path, objs, anim=False):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
        for c in o.children_recursive:
            c.select_set(True)
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True, export_yup=True,
                              export_apply=True, export_animations=anim, export_force_sampling=True)


def _keys(obj, name, frames):
    """Keys on obj in the action `name` (one action, a slot for each object it
    moves, so it plays as one animation): [(frame, (rx, ry, rz) degrees), ...] at 24 fps."""
    obj.rotation_mode = "XYZ"
    obj.animation_data_create()
    act = bpy.data.actions.get(name) or bpy.data.actions.new(name)
    obj.animation_data.action = act
    for f, rot in frames:
        obj.rotation_euler = [math.radians(v) for v in rot]
        obj.keyframe_insert("rotation_euler", frame=f)
    obj.rotation_euler = [math.radians(v) for v in frames[0][1]]
    return act


# ---- the container -------------------------------------------------------------------

def container(out: Path) -> int:
    reset()
    M = _mats()
    parts = []
    # Floor, roof, the closed end; the sides corrugated (vertical ribs on a skin).
    parts.append(box((0, 0, 0.08), (L, W, 0.16), M["steel"]))
    parts.append(box((0, 0, 0.165), (L - 0.1, W - 0.1, 0.02), M["floor"]))
    parts.append(box((0, 0, H - WALL / 2), (L, W, WALL), M["paint"]))
    parts.append(box((-L / 2 + WALL / 2, 0, H / 2), (WALL, W, H), M["paint"]))
    pitch = 0.28
    n = int((L - 0.4) / pitch)
    for side in (-1, 1):
        parts.append(box((0, side * (W / 2 - WALL / 2), H / 2), (L, WALL, H - 0.2), M["paint"]))
        for k in range(n):
            x = -L / 2 + 0.2 + (k + 0.5) * pitch
            parts.append(box((x, side * (W / 2 + 0.012), H / 2), (0.12, 0.025, H - 0.3), M["paint"]))
    for k in range(int((L - 0.4) / 0.6)):                   # (the roof's dents)
        parts.append(box((-L / 2 + 0.5 + k * 0.6, 0, H + 0.01), (0.3, W - 0.2, 0.02), M["paint"]))
    # Rails top and bottom, corner posts and castings.
    for z in (0.12, H - 0.1):
        for side in (-1, 1):
            parts.append(box((0, side * (W / 2 - 0.04), z), (L, 0.1, 0.16), M["paint"]))
    for x in (-L / 2 + 0.08, L / 2 - 0.08):
        for side in (-1, 1):
            parts.append(box((x, side * (W / 2 - 0.08), H / 2), (0.16, 0.16, H), M["paint"]))
            for z in (0.09, H - 0.09):
                parts.append(box((x, side * (W / 2 - 0.09), z), (0.18, 0.18, 0.18), M["steel"]))
    body = join(parts, "container")
    # The doors at +X: each 1.2 m, hinged at the corner posts (their origins).
    doors = []
    for name, side in (("door_l", 1), ("door_r", -1)):
        dp = []
        w = W / 2 - 0.1
        dp.append(box((0, -side * w / 2, H / 2), (0.04, w, H - 0.25), M["paint"]))
        for k in range(4):                                  # (pressed panels)
            dp.append(box((0.025, -side * w / 2, 0.45 + k * 0.55), (0.02, w - 0.12, 0.4), M["paint"]))
        for t in (0.3, 0.7):                                # locking bars, handles
            y = -side * w * t
            dp.append(tube((0.06, y, 0.2), (0.06, y, H - 0.2), 0.022, M["steel"]))
            dp.append(box((0.08, y + side * 0.08, 1.2), (0.03, 0.18, 0.05), M["steel"]))
        d = join(dp, name)
        d.location = (L / 2 - 0.02, side * (W / 2 - 0.06), 0)
        d.parent = body
        doors.append(d)
    export(out / "container.glb", [body])
    return sum(len(p.vertices) - 2 for o in [body] + doors for p in o.data.polygons)


# ---- the fence -----------------------------------------------------------------------

def _link_texture(path: Path):
    """Chain link: galvanised diamonds on nothing (alpha), one tile = LINK metres."""
    S = 256
    img = np.zeros((S, S, 4), np.float32)
    yy, xx = np.mgrid[0:S, 0:S]
    period = S / 6                                          # 6 diamonds a tile (5 cm)
    for d in ((xx + yy) % period, (xx - yy) % period):
        wire = np.minimum(d, period - d) < 1.6
        img[wire] = (0.66, 0.68, 0.70, 1.0)
    img[..., :3] *= (0.85 + 0.15 * ((xx + yy) % period < period / 2))[..., None]   # (a twist at each crossing)
    from PIL import Image
    Image.fromarray((img * 255).astype(np.uint8)).save(path)
    return path


def _link_material(tex: Path):
    m = bpy.data.materials.get("link") or bpy.data.materials.new("link")
    m.use_nodes = True
    nt = m.node_tree
    p = nt.nodes["Principled BSDF"]
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images.load(str(tex))
    t.image.pack()
    nt.links.new(t.outputs["Color"], p.inputs["Base Color"])
    nt.links.new(t.outputs["Alpha"], p.inputs["Alpha"])
    p.inputs["Metallic"].default_value = 0.7
    p.inputs["Roughness"].default_value = 0.4
    m.blend_method = "CLIP" if hasattr(m, "blend_method") else m.blend_method
    try:
        m.surface_render_method = "DITHERED"
    except Exception:
        pass
    m.use_backface_culling = False
    return m


def _link_quad(x0, z0, x1, z1, m, name="link"):
    """A vertical rectangle of chain link in the panel's plane (y = 0), its UVs by position."""
    me = bpy.data.meshes.new(name)
    vs = [(x0, 0, z0), (x1, 0, z0), (x1, 0, z1), (x0, 0, z1)]
    me.from_pydata(vs, [], [(0, 1, 2, 3)])
    uv = me.uv_layers.new()
    for li, vi in enumerate(me.polygons[0].vertices):
        x, _, z = vs[vi]
        uv.data[li].uv = (x / LINK, z / LINK)
    o = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(o)
    o.data.materials.append(m)
    return o


def _frame(M, w=FENCE_W):
    parts = []
    for x in (-w / 2, w / 2):                               # posts
        parts.append(tube((x, 0, 0), (x, 0, FENCE_H + 0.35), 0.03, M["galv"], segs=8))
        parts.append(tube((x, 0, FENCE_H), (x, 0.22, FENCE_H + 0.3), 0.012, M["galv"], segs=6))   # the arm for the wire
    parts.append(tube((-w / 2, 0, FENCE_H), (w / 2, 0, FENCE_H), 0.02, M["galv"], segs=8))       # top rail
    parts.append(tube((-w / 2, 0, 0.06), (w / 2, 0, 0.06), 0.008, M["galv"], segs=5))            # tension wire
    for k in range(3):                                      # barbed wire
        y = 0.07 + k * 0.075; z = FENCE_H + 0.08 + k * 0.1
        parts.append(tube((-w / 2, y, z), (w / 2, y, z), 0.004, M["galv"], segs=4))
        for b in range(int(w / 0.12)):
            x = -w / 2 + 0.06 + b * 0.12
            parts.append(tube((x - 0.02, y - 0.02, z), (x + 0.02, y + 0.02, z), 0.003, M["galv"], segs=3))
    return parts


def fence(out: Path) -> int:
    reset()
    M = _mats()
    lm = _link_material(_link_texture(Path(bpy.app.tempdir or "/tmp") / "chain_link.png"))
    parts = _frame(M) + [_link_quad(-FENCE_W / 2, 0.04, FENCE_W / 2, FENCE_H, lm)]
    f = join(parts, "fence")
    export(out / "fence.glb", [f])
    n = sum(len(p.vertices) - 2 for p in f.data.polygons)
    # The cut panel: the link round a hole at the foot, and the flap (hinged at its top edge)
    # with the animation that bends it up and back (towards +Y: out of the yard).
    reset()
    M = _mats()
    lm = _link_material(_link_texture(Path(bpy.app.tempdir or "/tmp") / "chain_link.png"))
    hx = HOLE_W / 2
    parts = _frame(M) + [
        _link_quad(-FENCE_W / 2, 0.04, -hx, FENCE_H, lm, "l"), _link_quad(hx, 0.04, FENCE_W / 2, FENCE_H, lm, "r"),
        _link_quad(-hx, 0.04 + HOLE_H, hx, FENCE_H, lm, "top")]
    f = join(parts, "fence_cut")
    flap = _link_quad(-hx, -HOLE_H, hx, 0.0, lm, "flap")    # (its origin on the hinge)
    flap.location = (0, 0, 0.04 + HOLE_H)
    flap.parent = f
    # Cut ends: little bright stubs along the three cut edges.
    stubs = []
    for k in range(int(HOLE_W / 0.05)):
        x = -hx + 0.025 + k * 0.05
        stubs.append(tube((x, 0, 0.04), (x, 0.012, 0.055), 0.003, M["galv"], segs=3))
    for k in range(int(HOLE_H / 0.05)):
        z = 0.06 + k * 0.05
        for x in (-hx, hx):
            stubs.append(tube((x, 0, z), (x + (0.012 if x < 0 else -0.012), 0.012, z), 0.003, M["galv"], segs=3))
    s = join(stubs, "cut_ends")
    s.parent = f
    act = _keys(flap, "peel", [(1, (0, 0, 0)), (6, (-8, 0, 0)), (14, (-48, 0, 1.5)), (22, (-82, 0, 2)), (26, (-78, 0, 2))])
    export(out / "fence_cut.glb", [f], anim=True)
    return n


# ---- the bolt cutters ----------------------------------------------------------------

def bolt_cutter(out: Path) -> int:
    reset()
    M = _mats()
    root = bpy.data.objects.new("bolt_cutter", None)
    bpy.context.collection.objects.link(root)
    arms = []
    for name, side in (("arm_a", 1), ("arm_b", -1)):
        p = []
        # The jaw ahead of the pivot (+Y), the handle behind it, the grip at its end.
        p.append(box((side * 0.012, 0.05, 0), (0.022, 0.1, 0.03), M["steel"]))
        p.append(box((side * 0.004, 0.105, 0), (0.012, 0.03, 0.026), M["steel"]))           # the cutting edge
        p.append(tube((side * 0.018, -0.01, 0), (side * 0.05, -0.36, 0), 0.011, M["steel"], segs=8))
        p.append(tube((side * 0.05, -0.36, 0), (side * 0.06, -0.62, 0), 0.016, M["rubber"], segs=8))
        p.append(tube((0, -0.015, -0.018), (0, -0.015, 0.018), 0.012, M["black"], segs=8))      # the pivot bolt
        a = join(p, name)
        a.parent = root
        arms.append(a)
    # "cut": open, squeeze shut (the jaws bite), open again; 0.8 s at 24 fps.
    for a, side in zip(arms, (1, -1)):
        _keys(a, "cut", [(1, (0, 0, side * 9)), (8, (0, 0, side * 1)), (10, (0, 0, side * 0.5)), (19, (0, 0, side * 9))])
    root.location = (0, 0, 0)
    export(out / "bolt_cutter.glb", [root], anim=True)
    return sum(len(p.vertices) - 2 for a in arms for p in a.data.polygons)


# ---- the duffel bag ------------------------------------------------------------------

def duffel(out: Path) -> int:
    reset()
    M = _mats()
    p = []
    LEN, R = 0.66, 0.17
    bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=R, depth=LEN, location=(0, 0, -0.3), rotation=(0, math.pi / 2, 0))
    o = bpy.context.object
    o.scale = (1.0, 1.0, 0.92)
    bpy.ops.object.transform_apply(scale=True)
    mod = o.modifiers.new("bevel", "BEVEL"); mod.width = 0.05; mod.segments = 3
    o.data.materials.append(M["fabric"]); p.append(o)
    for x in (-LEN / 2 + 0.02, LEN / 2 - 0.02):             # the round ends, piped
        bpy.ops.mesh.primitive_torus_add(major_radius=R - 0.035, minor_radius=0.01, location=(x, 0, -0.3), rotation=(0, math.pi / 2, 0),
                                         major_segments=20, minor_segments=5)
        t = bpy.context.object; t.data.materials.append(M["strap"]); p.append(t)
    p.append(box((0, 0, -0.3 + R * 0.92), (LEN * 0.9, 0.02, 0.012), M["strap"]))           # the zip
    for x in (-0.12, 0.12):                                 # handles: from the bag's top up to the grip
        p.append(tube((x, -0.02, -0.3 + R * 0.85), (x * 0.4, 0, -0.02), 0.012, M["strap"], segs=6))
        p.append(tube((x, 0.02, -0.3 + R * 0.85), (x * 0.4, 0, -0.02), 0.012, M["strap"], segs=6))
    p.append(tube((-0.06, 0, -0.01), (0.06, 0, -0.01), 0.02, M["strap"], segs=8))           # the grip
    for x in (-0.2, 0.2):                                   # straps round it
        bpy.ops.mesh.primitive_torus_add(major_radius=R - 0.003, minor_radius=0.008, location=(x, 0, -0.3), rotation=(0, math.pi / 2, 0),
                                         major_segments=20, minor_segments=4)
        t = bpy.context.object; t.data.materials.append(M["strap"]); p.append(t)
    d = join(p, "duffel")
    export(out / "duffel.glb", [d])
    return sum(len(q.vertices) - 2 for q in d.data.polygons)


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "godot-city/models")
    out.mkdir(parents=True, exist_ok=True)
    for f in (container, fence, bolt_cutter, duffel):
        print(f.__name__, f(out), "triangles")
