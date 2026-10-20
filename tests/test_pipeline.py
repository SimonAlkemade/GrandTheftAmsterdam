import json
import random
import struct
import tempfile
import unittest
from pathlib import Path

import numpy as np
from shapely.geometry import Polygon

from tests.helpers import sample_doc, two_houses
from amsterdam.city import build_district, party_walls
from amsterdam.facade import FacadeBuilder, choose_style, gable_shape, wall_shape
from amsterdam.gltf import write_glb
from amsterdam.mesh import MeshBuilder
from amsterdam.sources import (Surface, load_cityjson_doc, load_obj,
                               orient_outward, signed_volume)
from fetch_3dbag import wgs84_to_rd

ROOF_TRIANGLE = Polygon([(0, 0), (0.5, 1), (1, 0)])


class Gables(unittest.TestCase):
    def test_every_gable_hides_the_roof_triangle(self):
        for kind in ("step", "neck", "bell", "spout", "plain"):
            for steps in (3, 4, 5):
                g = gable_shape(kind, steps)
                self.assertTrue(g.is_valid, kind)
                self.assertLess(ROOF_TRIANGLE.difference(g).area, 1e-9, (kind, steps))

    def test_gables_stay_within_the_wall_width(self):
        for kind in ("step", "neck", "bell", "spout"):
            x0, y0, x1, _ = gable_shape(kind).bounds
            self.assertGreaterEqual(x0, -1e-9, kind)
            self.assertLessEqual(x1, 1 + 1e-9, kind)
            self.assertGreaterEqual(y0, -1e-9, kind)


class Sources(unittest.TestCase):
    def test_sample_reads_as_3dbag(self):
        bs = load_cityjson_doc(sample_doc())
        self.assertEqual(len(bs), 49)
        for b in bs:
            self.assertIsNotNone(b.year)
            self.assertAlmostEqual(b.ground_z, 0.4)
            self.assertGreaterEqual(len(b.walls()), 4)
            self.assertGreaterEqual(len(b.roofs()), 1)
            self.assertGreater(signed_volume(b.surfaces), 0, b.id)
            for r in b.roofs():
                self.assertGreater(r.normal[2], 0)

    def test_inside_out_shell_is_flipped_but_keeps_its_labels(self):
        b = load_cityjson_doc(sample_doc())[0]
        inverted = [Surface(s.kind, s.ring[::-1].copy()) for s in b.surfaces]
        fixed = orient_outward(inverted)
        self.assertGreater(signed_volume(fixed), 0)
        self.assertEqual([s.kind for s in fixed], [s.kind for s in b.surfaces])

    def test_obj_triangles_merge_back_into_planar_walls(self):
        b = load_cityjson_doc(sample_doc())[0]
        lines, base = [], 1
        for s in b.surfaces:            # fan-triangulate every face, Y-up
            for p in s.ring:
                lines.append(f"v {p[0]} {p[2]} {-p[1]}")
            for i in range(1, len(s.ring) - 1):
                lines.append(f"f {base} {base + i} {base + i + 1}")
            base += len(s.ring)
        with tempfile.NamedTemporaryFile("w", suffix=".obj", delete=False) as f:
            f.write("\n".join(lines))
        got = load_obj(f.name, up="y")
        self.assertEqual(len(got), 1)
        self.assertEqual(len(got[0].walls()), len(b.walls()))
        self.assertEqual(len(got[0].roofs()), len(b.roofs()))
        self.assertGreater(signed_volume(got[0].surfaces), 0)


class PartyWalls(unittest.TestCase):
    def test_the_shared_wall_is_hidden_on_both_sides_and_nothing_else(self):
        bs = two_houses()
        hidden = party_walls(bs)
        self.assertEqual(sorted(bi for bi, _ in hidden), [0, 1])
        for bi, si in hidden:
            n = bs[bi].surfaces[si].normal
            self.assertAlmostEqual(abs(n[0]), 1.0, places=6)   # the x = 6 wall


class Facades(unittest.TestCase):
    def _front(self, b):
        return next(s for s in b.walls() if s.normal[1] < -0.99)

    def test_openings_stay_inside_the_wall(self):
        for b in load_cityjson_doc(sample_doc())[:20]:
            shape = wall_shape(self._front(b).ring, [], b.ground_z)
            rng = random.Random(1)
            fb = FacadeBuilder(MeshBuilder(), shape, choose_style(b.year, rng), rng)
            fb.build()
            ops = fb._layout("plain")
            for o in ops:
                self.assertTrue(fb.outline.buffer(1e-6).contains(
                    Polygon([(o[1], o[3]), (o[2], o[3]), (o[2], o[4]), (o[1], o[4])])), b.id)

    def test_a_canal_house_front_gets_a_door_and_windows(self):
        b = two_houses()[0]
        shape = wall_shape(self._front(b).ring, [], b.ground_z)
        rng = random.Random(3)
        fb = FacadeBuilder(MeshBuilder(), shape, choose_style(1650, rng), rng)
        fb.build()
        kinds = [o[0] for o in fb._layout("plain")]
        self.assertIn("door", kinds)
        self.assertGreaterEqual(kinds.count("window"), 4)

    def test_the_wall_outline_is_kept(self):
        b = two_houses()[1]
        front = self._front(b)
        shape = wall_shape(front.ring, [], b.ground_z)
        self.assertAlmostEqual(shape.width, 5.0, places=6)
        self.assertAlmostEqual(shape.core_top, 13.0, delta=0.01)  # eave above ground
        self.assertAlmostEqual(shape.peak, front.ring[:, 2].max() - b.ground_z, places=6)


class Output(unittest.TestCase):
    def _build(self, path, seed=1):
        bs = load_cityjson_doc(sample_doc())[:8]
        return write_glb(path, build_district(bs, seed))

    def test_same_input_and_seed_give_identical_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            self._build(f"{d}/a.glb")
            self._build(f"{d}/b.glb")
            self._build(f"{d}/c.glb", seed=2)
            a, b, c = (Path(d, n).read_bytes() for n in ("a.glb", "b.glb", "c.glb"))
            self.assertEqual(a, b)
            self.assertNotEqual(a, c)

    def test_glb_is_well_formed(self):
        with tempfile.TemporaryDirectory() as d:
            stats = self._build(f"{d}/a.glb")
            data = Path(d, "a.glb").read_bytes()
        magic, version, total = struct.unpack_from("<III", data)
        self.assertEqual((magic, version, total), (0x46546C67, 2, len(data)))
        jlen, jtype = struct.unpack_from("<II", data, 12)
        self.assertEqual(jtype, 0x4E4F534A)
        doc = json.loads(data[20:20 + jlen])
        blen, btype = struct.unpack_from("<II", data, 20 + jlen)
        self.assertEqual(btype, 0x004E4942)
        binary = data[28 + jlen:28 + jlen + blen]
        size = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}
        for acc in doc["accessors"]:
            view = doc["bufferViews"][acc["bufferView"]]
            self.assertEqual(view["byteLength"], acc["count"] * size[acc["type"]] * 4)
            self.assertLessEqual(view["byteOffset"] + view["byteLength"], len(binary))
        tris = 0
        for mesh in doc["meshes"]:
            for prim in mesh["primitives"]:
                nverts = doc["accessors"][prim["attributes"]["POSITION"]]["count"]
                ia = doc["accessors"][prim["indices"]]
                v = doc["bufferViews"][ia["bufferView"]]
                idx = np.frombuffer(binary, np.uint32, ia["count"], v["byteOffset"])
                self.assertLess(idx.max(), nverts)
                tris += ia["count"] // 3
        self.assertEqual(tris, stats["triangles"])
        self.assertEqual(len(doc["images"]), len(doc["textures"]))


class Coordinates(unittest.TestCase):
    def test_amersfoort_is_the_rd_origin(self):
        x, y = wgs84_to_rd(52.15517440, 5.38720621)
        self.assertAlmostEqual(x, 155000, places=3)
        self.assertAlmostEqual(y, 463000, places=3)

    def test_dam_square_lands_in_central_amsterdam(self):
        x, y = wgs84_to_rd(52.3731, 4.8926)
        self.assertTrue(121000 < x < 122000 and 487000 < y < 488000, (x, y))


if __name__ == "__main__":
    unittest.main()


class OvertureRows(unittest.TestCase):
    def _row(self, w_m, d_m, **kw):
        from shapely.geometry import box as sbox
        # A w x d metre lot near the Dam, in lon/lat.
        lon, lat = 4.8926, 52.3731
        dlon, dlat = w_m / 68000.0, d_m / 111200.0
        g = sbox(lon, lat, lon + dlon, lat + dlat)
        return dict({"id": "t", "geometry": g.wkb, "height": 14.0, "num_floors": None,
                     "roof_shape": None, "roof_height": None, "class": None,
                     "is_underground": False}, **kw)

    def test_narrow_deep_lot_gets_a_canal_house_gable(self):
        from amsterdam.overture import building_from_row
        b = building_from_row(self._row(6, 18))
        pentagons = [s for s in b.walls() if len(s.ring) == 5]
        self.assertEqual(len(pentagons), 2)            # front and back gable ends
        self.assertEqual(len(b.roofs()), 2)
        top = max(s.ring[:, 2].max() for s in b.surfaces)
        self.assertAlmostEqual(top - b.ground_z, 14.0, delta=0.05)  # height kept
        self.assertGreater(signed_volume(b.surfaces), 0)

    def test_wide_or_tagged_flat_buildings_stay_flat(self):
        from amsterdam.overture import building_from_row
        for row in (self._row(30, 25), self._row(6, 18, roof_shape="flat")):
            b = building_from_row(row)
            self.assertEqual(len(b.roofs()), 1)
            self.assertTrue(all(len(s.ring) == 4 for s in b.walls()))
            self.assertGreater(signed_volume(b.surfaces), 0)

    def test_houseboats_float_below_the_street(self):
        from amsterdam.overture import GROUND_Z, building_from_row
        b = building_from_row(self._row(4, 20, **{"class": "houseboat"}))
        self.assertLess(b.ground_z, GROUND_Z - 1.0)
        self.assertLess(b.min_z(), GROUND_Z)
