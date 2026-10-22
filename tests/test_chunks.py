import json
import unittest
from collections import Counter
from pathlib import Path

import numpy as np
from shapely.geometry import Polygon

from amsterdam.chunks import split_tile

TILE = Path(__file__).resolve().parent.parent / "godot-city" / "data" / "tiles" / "-1_0.json"


def area(rings):
    shell = np.asarray(rings[0], float).reshape(-1, 2)
    return Polygon(shell, [np.asarray(r, float).reshape(-1, 2) for r in rings[1:]]).buffer(0).area


class Split(unittest.TestCase):
    def synthetic(self):
        return {
            "tile": [0, 0],
            "buildings": [{"r": [[100, 100, 200, 100, 200, 200, 100, 200]], "h": 10, "k": 1},
                          {"r": [[3800, 100, 3900, 100, 3900, 200, 3800, 200]], "h": 10, "k": 1}],
            "roads": [["road", 8, [0, 1000, 15000, 1000], "Straat"]],
            "water": [{"r": [[3000, 3000, 9000, 3000, 9000, 9000, 3000, 9000],
                             [5000, 5000, 5000, 6000, 6000, 6000, 6000, 5000]]}],
            "trees": [10, 10, 4000, 4000],
            "places": [["Café", "cafe", 4000, 4000, 0, "", ""]],
        }

    def test_every_chunk_exists_with_its_own_ground(self):
        out = split_tile(self.synthetic(), 15000, 3750)
        self.assertEqual(len(out), 16)
        self.assertEqual(out["1_1"]["tile"], [1, 1])
        self.assertEqual(out["1_1"]["size"], 375.0)

    def test_things_go_to_the_chunk_they_stand_in(self):
        out = split_tile(self.synthetic(), 15000, 3750)
        self.assertEqual(len(out["0_0"]["buildings"]), 1)
        self.assertEqual(len(out["1_0"]["buildings"]), 1)
        self.assertEqual(out["0_0"]["trees"], [10, 10])
        self.assertEqual(out["1_1"]["trees"], [4000, 4000])
        self.assertEqual(out["1_1"]["places"][0][0], "Café")

    def test_buildings_by_a_border_are_known_next_door(self):
        t = {"tile": [0, 0], "buildings": [{"r": [[3700, 100, 3740, 100, 3740, 200, 3700, 200]], "h": 10, "k": 1}]}
        out = split_tile(t, 15000, 3750)
        self.assertEqual(len(out["0_0"]["buildings"]), 1)
        self.assertEqual(out["1_0"]["nb"], [t["buildings"][0]["r"][0]])
        self.assertNotIn("nb", out["0_0"])

    def test_a_street_cut_at_a_border_meets_itself(self):
        out = split_tile(self.synthetic(), 15000, 3750)
        pieces = [r[2] for c in out.values() for r in c.get("roads", [])]
        self.assertEqual(len(pieces), 4)
        ends = Counter()
        for p in pieces:
            ends[(p[0], p[1])] += 1
            ends[(p[-2], p[-1])] += 1
        self.assertEqual(sorted(k for k, n in ends.items() if n == 2), [(3750, 1000), (7500, 1000), (11250, 1000)])
        self.assertEqual(sum(np.hypot(np.diff(np.reshape(p, (-1, 2))[:, 0]), np.diff(np.reshape(p, (-1, 2))[:, 1])).sum() for p in pieces), 15000)

    def test_canal_pieces_add_up_and_keep_their_island(self):
        t = self.synthetic()
        out = split_tile(t, 15000, 3750)
        pieces = [w for c in out.values() for w in c.get("water", [])]
        self.assertAlmostEqual(sum(area(w["r"]) for w in pieces), area(t["water"][0]["r"]), delta=5)
        self.assertTrue(any("t" in w for w in pieces), "the island stays a hole somewhere")

    @unittest.skipUnless(TILE.exists() and "chunks" not in json.loads(TILE.read_text()), "needs an unchunked city tile")
    def test_a_real_tile_loses_nothing(self):
        t = json.loads(TILE.read_text())
        out = split_tile(t, 15000, 3750)
        self.assertEqual(sum(len(c.get("buildings", [])) for c in out.values()), len(t["buildings"]))
        self.assertEqual(sum(len(c.get("trees", [])) for c in out.values()), len(t["trees"]))
        self.assertEqual(sum(len(c.get("places", [])) for c in out.values()), len(t["places"]))
        for field in ("water", "green"):
            whole = sum(area(w["r"]) for w in t[field])
            parts = sum(area(w["r"]) for c in out.values() for w in c.get(field, []))
            self.assertAlmostEqual(parts / whole, 1.0, delta=0.002, msg=field)


if __name__ == "__main__":
    unittest.main()
