"""Rig a static, T-posed character mesh (a Tripo .glb) for the game.

    python blender/rig_character.py IN.glb OUT.glb HEIGHT_M

Fits a simple humanoid skeleton to the mesh (hips, spine, head, upper arm,
forearm, hand, thigh, shin and foot each side: the joints of the game's own
figure, scripts/human.gd), binds the mesh to it with automatic weights,
lowers the arms from the T-pose to hanging at the sides and makes that the
rest pose (as the game's figure stands), scales it to HEIGHT_M, shrinks its
texture to 1024 px JPEG for the web build, and writes a skinned .glb with no
animations: the game moves the bones itself (scripts/skinned_person.gd).

The mesh faces +Z in glTF (-Y in Blender) and its left is +X, as Tripo makes
them. Joint positions come from the mesh: where the arms stick out, how wide
the chest is below them, where the legs are.
"""
import statistics
import sys

import bpy
from mathutils import Matrix, Vector

src, dst, height = sys.argv[-3], sys.argv[-2], float(sys.argv[-1])

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
assert len(meshes) == 1, "one mesh expected, got %d" % len(meshes)
mesh = meshes[0]

# Bake every transform into the mesh, drop the empties.
for o in bpy.context.scene.objects:
    o.select_set(False)
mesh.select_set(True)
bpy.context.view_layer.objects.active = mesh
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
for o in list(bpy.context.scene.objects):
    if o is not mesh:
        bpy.data.objects.remove(o, do_unlink=True)

# Feet on the ground, centred, HEIGHT_M tall.
vs = [v.co.copy() for v in mesh.data.vertices]
zmin = min(v.z for v in vs); zmax = max(v.z for v in vs)
xmid = (min(v.x for v in vs) + max(v.x for v in vs)) / 2
ymid = (min(v.y for v in vs) + max(v.y for v in vs)) / 2
s = height / (zmax - zmin)
for v in mesh.data.vertices:
    v.co = Vector(((v.co.x - xmid) * s, (v.co.y - ymid) * s, (v.co.z - zmin) * s))
mesh.data.update()
vs = [v.co.copy() for v in mesh.data.vertices]
H = height

# ---- where the joints are ----------------------------------------------------------------
maxx = max(v.x for v in vs)
arm = [v for v in vs if abs(v.x) > 0.75 * maxx]
arm_z = statistics.median(v.z for v in arm)
arm_y = statistics.median(v.y for v in arm)
torso = [v for v in vs if 0.55 * H < v.z < 0.64 * H]
half = statistics.quantiles([abs(v.x) for v in torso], n=20)[-1]       # (the 95th percentile: not a stray bag strap)
shoulder_x = half * 0.95
wrist_x = maxx - 0.085 * H
elbow_x = (shoulder_x + wrist_x) / 2
legs = [v for v in vs if 0.12 * H < v.z < 0.35 * H]
leg_l = statistics.median(v.x for v in legs if v.x > 0)
leg_r = statistics.median(v.x for v in legs if v.x < 0)
leg_y = statistics.median(v.y for v in legs)
body_y = statistics.median(v.y for v in vs if 0.4 * H < v.z < 0.75 * H)
print("joints: arms at z %.2f, shoulders x %.2f, wrists x %.2f, legs x %.2f / %.2f" % (arm_z, shoulder_x, wrist_x, leg_l, leg_r))

# ---- the skeleton --------------------------------------------------------------------------
arm_data = bpy.data.armatures.new("rig")
rig = bpy.data.objects.new("rig", arm_data)
bpy.context.scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
eb = arm_data.edit_bones


def bone(name, head, tail, parent=None, connect=False):
    b = eb.new(name)
    b.head = Vector(head); b.tail = Vector(tail)
    if parent:
        b.parent = eb[parent]; b.use_connect = connect
    return b


pelvis_z = 0.52 * H
bone("hips", (0, body_y, pelvis_z), (0, body_y, pelvis_z + 0.07 * H))
bone("spine", (0, body_y, pelvis_z + 0.07 * H), (0, body_y, 0.81 * H), "hips", True)
bone("head", (0, body_y, 0.84 * H), (0, body_y, H), "spine")
for side, sx, lx in (("L", 1, leg_l), ("R", -1, leg_r)):
    bone("upperarm." + side, (sx * shoulder_x, arm_y, arm_z), (sx * elbow_x, arm_y, arm_z), "spine")
    bone("forearm." + side, (sx * elbow_x, arm_y, arm_z), (sx * wrist_x, arm_y, arm_z), "upperarm." + side, True)
    bone("hand." + side, (sx * wrist_x, arm_y, arm_z), (sx * (maxx - 0.01 * H), arm_y, arm_z), "forearm." + side, True)
    bone("thigh." + side, (lx, leg_y, pelvis_z - 0.03 * H), (lx, leg_y, 0.28 * H), "hips")
    bone("shin." + side, (lx, leg_y, 0.28 * H), (lx, leg_y, 0.05 * H), "thigh." + side, True)
    bone("foot." + side, (lx, leg_y, 0.05 * H), (lx, leg_y - 0.12 * H, 0.015 * H), "shin." + side, True)
bpy.ops.object.mode_set(mode="OBJECT")

# Tripo meshes come in loose pieces (every UV seam split): weld them, or bone
# heat weighting finds no solution.
bpy.context.view_layer.objects.active = mesh
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.remove_doubles(threshold=0.0008 * H)
bpy.ops.object.mode_set(mode="OBJECT")
print("welded: %d vertices" % len(mesh.data.vertices))

# ---- skin it ---------------------------------------------------------------------------------
for o in bpy.context.scene.objects:
    o.select_set(False)
mesh.select_set(True); rig.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.parent_set(type="ARMATURE_AUTO")
groups = {g.index: g.name for g in mesh.vertex_groups}
unweighted = sum(1 for v in mesh.data.vertices if not any(g.weight > 0.01 for g in v.groups))
print("weights: %d vertex groups, %d of %d vertices unweighted" % (len(groups), unweighted, len(mesh.data.vertices)))
if unweighted > len(mesh.data.vertices) * 0.02:
    # Bone heat failed (a mesh it cannot solve): weight every vertex softly by
    # its distance to the bones near it, the nearest two or three blended, so
    # the joints bend rather than crease.
    segs = [(b.name, rig.matrix_world @ b.head_local, rig.matrix_world @ b.tail_local) for b in arm_data.bones]
    for g in list(mesh.vertex_groups):
        mesh.vertex_groups.remove(g)
    vg = {name: mesh.vertex_groups.new(name=name) for name, _, _ in segs}
    for v in mesh.data.vertices:
        ds = []
        for name, a, b in segs:
            ab = b - a
            t = max(0.0, min(1.0, (v.co - a).dot(ab) / max(ab.length_squared, 1e-9)))
            ds.append(((a + ab * t - v.co).length, name))
        ds.sort()
        near = ds[:3]
        d0 = near[0][0]
        ws = [(name, 1.0 / (1e-4 + (d - d0 + 0.02 * H) ** 4)) for d, name in near if d - d0 < 0.06 * H]
        tot = sum(w for _, w in ws)
        for name, w in ws:
            vg[name].add([v.index], w / tot, "REPLACE")
    print("weights: bone heat failed, weighted softly by distance to the bones")

# ---- arms down: the rest pose the game's figure has ---------------------------------------------
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="POSE")
hang = 0.10                                     # radians out from straight down
for side, sx in (("L", 1), ("R", -1)):
    pb = rig.pose.bones["upperarm." + side]
    rest = pb.bone.matrix_local.to_3x3()
    want = Vector((sx * __import__("math").sin(hang), 0, -__import__("math").cos(hang)))
    have = (pb.bone.tail_local - pb.bone.head_local).normalized()
    rot = have.rotation_difference(want).to_matrix()
    pb.rotation_mode = "QUATERNION"
    pb.rotation_quaternion = (rest.inverted() @ rot @ rest).to_quaternion()
bpy.ops.object.mode_set(mode="OBJECT")
bpy.context.view_layer.update()
# Bake the pose into the mesh, make it the rest pose, and skin again.
bpy.context.view_layer.objects.active = mesh
mod = next(m for m in mesh.modifiers if m.type == "ARMATURE")
bpy.ops.object.modifier_apply(modifier=mod.name)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="POSE")
bpy.ops.pose.armature_apply(selected=False)
bpy.ops.object.mode_set(mode="OBJECT")
m2 = mesh.modifiers.new("Armature", "ARMATURE")
m2.object = rig

# ---- the texture: 1024 px, JPEG ---------------------------------------------------------------------
for img in bpy.data.images:
    if img.size[0] > 1024:
        img.scale(1024, 1024)

for o in bpy.context.scene.objects:
    o.select_set(True)
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", export_animations=False, export_skins=True,
                          export_yup=True, export_image_format="JPEG", export_jpeg_quality=85, export_apply=False)
print("wrote", dst)
