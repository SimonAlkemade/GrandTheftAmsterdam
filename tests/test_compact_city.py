"""The compact Amsterdam (compact_city.py): the warp leaves the centre alone
and pulls the rest in smoothly; the built data keeps the city joined up, its
buildings whole and apart, and everything on the island.

    python -m unittest tests.test_compact_city
"""
import json
import math
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

import numpy as np
from shapely.geometry import Polygon

import compact_city as cc

FULL = Path(__file__).resolve().parent.parent / "godot-city" / "data"


class Warp(unittest.TestCase):
    def setUp(self):
        self.w = cc.Warp([0.0, 0.0])

    def test_core_untouched(self):
        p = np.array([[1000.0, 2000.0], [-cc.CORE + 1, 0.0], [0.0, 0.0]])
        self.assertTrue(np.allclose(self.w(p), p))

    def test_keep_lands_on_the_island(self):
        for ang in np.linspace(0, 2 * math.pi, 12, endpoint=False):
            p = np.array([[math.cos(ang) * cc.KEEP, math.sin(ang) * cc.KEEP]])
            self.assertAlmostEqual(float(np.hypot(*self.w(p)[0])), cc.ISLAND, delta=1.0)

    def test_smooth_and_monotonic(self):
        r = np.linspace(0, cc.KEEP * 1.5, 4000)
        rr = self.w.radius(r)
        steps = np.diff(rr)
        self.assertTrue((steps > 0).all(), "the warp never folds the city over")
        # No kink at the core's edge: the slope runs on from 1.
        self.assertAlmostEqual(self.w.slope(cc.CORE + 1), 1.0, delta=0.01)
        self.assertLess(self.w.slope(cc.KEEP), 0.5)

    def test_angles_kept(self):
        p = np.array([[30000.0, 10000.0]])
        q = self.w(p)[0]
        self.assertAlmostEqual(math.atan2(q[1], q[0]), math.atan2(10000, 30000), places=9)


@unittest.skipUnless((FULL / "index.json").exists(), "the full city data is not here")
class Built(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dst = Path(cls.tmp.name) / "data-compact"
        cls.stats = cc.build(FULL, cls.dst)
        cls.index = json.loads((cls.dst / "index.json").read_text())
        cls.chunks = {}
        for f in (cls.dst / "tiles").glob("*.json"):
            cls.chunks.update(json.loads(f.read_text())["chunks"])
        c = cls.index["compact"]
        cls.centre = np.asarray(c["centre"], float)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_small(self):
        x0, y0 = min(self.index["bounds"][0::2]), min(self.index["bounds"][1::2])
        x1, y1 = max(self.index["bounds"][0::2]), max(self.index["bounds"][1::2])
        self.assertLessEqual((x1 - x0) / 10, 4200, "about 3 km of island and its water")
        self.assertLessEqual(len(self.index["chunks"]), 300)
        self.assertGreater(self.stats["kept"], 5000)
        self.assertGreater(self.stats["dropped"], 0, "fewer houses")

    def test_everything_on_the_island(self):
        r_max = cc.ISLAND + 1
        for c in self.chunks.values():
            for bd in c.get("buildings", []):
                ring = np.asarray(bd["r"][0] if "r" in bd else bd["g"], float).reshape(-1, 2)
                self.assertLess(np.hypot(*(ring.mean(axis=0) - self.centre)), r_max)
            for rd in c.get("roads", []):
                p = np.asarray(rd[2], float).reshape(-1, 2)
                self.assertLess(np.hypot(*(p - self.centre).T).max(), r_max)

    def test_buildings_apart(self):
        polys = []
        for c in self.chunks.values():
            for bd in c.get("buildings", []):
                ring = np.asarray(bd["r"][0] if "r" in bd else bd["g"], float).reshape(-1, 2)
                d = np.hypot(*(ring.mean(axis=0) - self.centre))
                if d > cc.CORE:
                    polys.append(Polygon(ring).buffer(-5))
        from shapely import STRtree
        tree = STRtree(polys)
        bad = 0
        for k, p in enumerate(polys):
            for j in tree.query(p):
                if j > k and p.intersects(polys[j]):
                    bad += 1
        self.assertEqual(bad, 0, "no moved building overlaps another")

    @staticmethod
    def _joined(roads):
        """The share of car-street length in the biggest end-to-end connected part."""
        parent = {}

        def find(a):
            while parent.setdefault(a, a) != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        segs = []
        for p in roads:
            a, b = tuple(p[0]), tuple(p[-1])
            parent[find(a)] = find(b)
            segs.append((a, float(np.hypot(*np.diff(p, axis=0).T).sum())))
        length = defaultdict(float)
        for a, l in segs:
            length[find(a)] += l
        return max(length.values()) / sum(length.values())

    def test_streets_join_up(self):
        """The warp keeps the street network as joined up as the real one was
        (measured end to end over the same area)."""
        compact = [np.asarray(rd[2], float).reshape(-1, 2) for c in self.chunks.values()
                   for rd in c.get("roads", []) if rd[0] == "road"]
        w = cc.Warp(self.centre)
        _, it = cc.load_full(FULL, w)
        real = [p for p in (np.asarray(rd[2], float).reshape(-1, 2) for rd in it["roads"] if rd[0] == "road")
                if w.dist(p).max() <= cc.KEEP]
        a, b = self._joined(compact), self._joined(real)
        print("streets joined: compact %.1f%%, the real city over the same area %.1f%%" % (100 * a, 100 * b))
        self.assertGreaterEqual(a, b - 0.01)

    def test_stations_and_start(self):
        st = self.index["stations"]
        self.assertGreaterEqual(len(st), 15)
        for s in st:
            self.assertLess(np.hypot(s[1] - self.centre[0], s[2] - self.centre[1]), cc.ISLAND)
        self.assertEqual(self.index["start"], json.loads((FULL / "index.json").read_text())["start"])


if __name__ == "__main__":
    unittest.main()
