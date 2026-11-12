"""The compact Amsterdam (compact_city.py): the old island layout's warp leaves
the centre alone and pulls the rest in smoothly; the city as built (layout v2,
the map brief) is about 5 x 4 km with some 50,000 buildings apart, its streets
one network, fewer canals with the named ones kept, its bridges over water, its
landmarks in their directions from the Dam, and everything inside its edge.

    python -m unittest tests.test_compact_city
"""
import json
import math
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path

import numpy as np
from shapely.geometry import LineString, Point, Polygon
from shapely.ops import unary_union

import compact_city as cc



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


COMPACT = Path(__file__).resolve().parent.parent / "godot-city" / "data-compact"


@unittest.skipUnless((COMPACT / "index.json").exists(), "the compact city is not built")
class Built(unittest.TestCase):
    """The compact city as built (python compact_city.py, layout v2) and shipped: the map brief's
    city, 0.45 of Amsterdam inside the A10 and the Arena, held to what the brief asks."""

    @classmethod
    def setUpClass(cls):
        cls.index = json.loads((COMPACT / "index.json").read_text())
        cls.c = cls.index["compact"]
        cls.chunks = {}
        for f in (COMPACT / "tiles").glob("*.json"):
            cls.chunks.update(json.loads(f.read_text())["chunks"])
        cls.edge = Polygon(np.asarray(cls.c["edge"], float).reshape(-1, 2))
        cls.dam = np.asarray(cls.c["centre"], float)
        cls.buildings = [bd for c in cls.chunks.values() for bd in c.get("buildings", [])]

    def _all(self, key):
        return [x for c in self.chunks.values() for x in c.get(key, [])]

    def test_size(self):
        x0, y0, x1, y1 = self.edge.bounds
        w, h = (x1 - x0) / 1e4, (y1 - y0) / 1e4
        print("the city: %.2f x %.2f km" % (w, h))
        self.assertTrue(3.5 < w < 5.5 and 3.5 < h < 5.5, "about 5 x 4 km")
        self.assertEqual(self.c["layout"], "v2")
        self.assertAlmostEqual(self.c["scale"], cc.S)

    def test_about_fifty_thousand_buildings(self):
        n = len({json.dumps(bd["r"] if "r" in bd else bd["g"]) for bd in self.buildings})
        self.assertEqual(n, self.c["buildings"])
        self.assertTrue(40000 <= n <= 60000, n)

    def test_buildings_apart(self):
        polys = [_poly(bd).buffer(-5)
                 for bd in {json.dumps(b): b for b in self.buildings}.values() if not bd.get("lm")]
        from shapely import STRtree
        polys = [p for p in polys if not p.is_empty]
        tree = STRtree(polys)
        bad = sum(1 for k, j in zip(*tree.query(polys, predicate="intersects")) if j > k)
        self.assertEqual(bad, 0, "no building overlaps another")

    def test_everything_inside(self):
        from shapely import prepared
        e = prepared.prep(self.edge)
        for bd in self.buildings:
            ring = np.asarray(bd["r"][0] if "r" in bd else bd["g"], float).reshape(-1, 2)
            self.assertTrue(e.contains(Point(*ring.mean(axis=0))))
        for s in self.index["stations"]:
            self.assertTrue(e.contains(Point(s[1], s[2])), s[0])
        self.assertGreaterEqual(len(self.index["stations"]), 15)
        self.assertTrue(e.contains(Point(*self.index["start"])), "you start at the Dam, inside")

    def test_streets_join_up(self):
        """Drop a city's side streets and it falls apart; this one is still one network."""
        roads = [np.round(np.asarray(rd[2], float).reshape(-1, 2) / 10.0) for rd in
                 {json.dumps(r): r for r in self._all("roads")}.values() if rd[0] == "road"]
        share = _joined(roads)
        print("car streets in one connected network: %.1f%%" % (100 * share))
        self.assertGreaterEqual(share, JOINED)

    def test_fewer_canals_the_named_ones_kept(self):
        print("canal water filled in: %.0f%%" % (100 * self.c["canals_filled"]))
        self.assertTrue(0.6 <= self.c["canals_filled"] <= 0.75)
        names = {lab[0] for lab in self._all("waterLabels")}
        for nm in ("Singel", "Herengracht", "Keizersgracht", "Prinsengracht", "IJ"):
            self.assertIn(nm, names, "the %s is still there (and named on its water)" % nm)
        # (The Amstel's one name point in the data is out by Ouderkerk: it is the water under the Magere Brug.)
        water = unary_union([Polygon(np.asarray(w["r"][0], float).reshape(-1, 2)).buffer(0) for w in self._all("water")])
        self.assertLess(water.distance(Point(*self.c["landmarks"]["Magere Brug"])), 200.0, "the Amstel, under the Magere Brug")

    def test_bridges_cross_water(self):
        water = unary_union([Polygon(np.asarray(w["r"][0], float).reshape(-1, 2)).buffer(0) for w in self._all("water")])
        bridges = {json.dumps(b): b for b in self._all("bridges")}.values()
        self.assertGreater(len(bridges), 200)
        # (A bridge is cut at chunk edges: the piece on the bank side is still over water's edge.)
        dry = [b for b in bridges if LineString(np.asarray(b, float).reshape(-1, 2)).distance(water) > 100.0]
        self.assertLess(len(dry), len(bridges) * 0.01, "a bridge is over water")

    def test_landmarks_where_they_were(self):
        lm = self.c["landmarks"]
        self.assertEqual(set(lm), set(cc.LANDMARKS))
        for nm, real in cc.LANDMARKS.items():
            a = math.atan2(real[1] - self.dam[1], real[0] - self.dam[0])
            b = math.atan2(lm[nm][1] - self.dam[1], lm[nm][0] - self.dam[0])
            d = abs((a - b + math.pi) % (2 * math.pi) - math.pi)
            self.assertLess(math.degrees(d), 20.0, "%s: in its direction from the Dam" % nm)
        built = {bd["lm"] for bd in self.buildings if bd.get("lm")}
        for nm in ("Amsterdam Centraal", "Dam / Royal Palace", "Westerkerk", "Rijksmuseum"):
            self.assertIn(nm, built, "%s: its building is there" % nm)


JOINED = 0.9


def _poly(bd):
    """A building's footprint, with its courtyards (another building may stand in one)."""
    rings = [np.asarray(r, float).reshape(-1, 2) for r in (bd["r"] if "r" in bd else [bd["g"]])]
    return Polygon(rings[0], rings[1:]).buffer(0)


def _joined(roads):
    """The share of street length in the biggest end-to-end connected part."""
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


if __name__ == "__main__":
    unittest.main()
