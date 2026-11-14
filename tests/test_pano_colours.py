"""Building colours measured from the City's street panoramas (pano_colours.py):
the wall-colour rule finds a wall's paint or brick past its windows, the sky
over it and the shopfront under it; end to end, a building a panorama sees
gets its wall's colour, one no panorama sees well takes its neighbours'
(marked estimated), and one outside the area is left alone.

    python -m unittest tests.test_pano_colours
"""
import math
import unittest

import numpy as np

import pano_colours as pc
from amsterdam.streetview import Facade, Pano
from tests.test_streetview import synthetic_pano

BRICK = (150, 72, 52)
GREEN = (46, 84, 62)


def wall_photo(colour, w=96, h=160):
    """A wall as rectify() gives it: sky over the roofline, rows of dark
    windows, a shopfront at street level."""
    img = np.zeros((h, w, 3), np.uint8)
    img[:] = colour
    img[: h // 10] = (236, 238, 241)                          # sky over the roofline
    for y in range(h // 10 + 8, int(h * 0.7), 22):            # windows
        for x in range(8, w - 12, 20):
            img[y:y + 13, x:x + 9] = (34, 36, 42)
    img[int(h * 0.75):] = (64, 64, 66)                        # the shopfront
    img[int(h * 0.8):int(h * 0.95), 10:40] = (210, 225, 235)  # its glass
    return img


def de(a, b):
    return float(np.linalg.norm(pc.lab(np.asarray(a, float)) - pc.lab(np.asarray(b, float))))


class WallColour(unittest.TestCase):
    def test_a_wall_behind_a_tree_is_no_answer(self):
        img = wall_photo(BRICK)
        rng = np.random.default_rng(2)
        img[:] = np.clip(np.array([62, 108, 48]) + rng.normal(0, 22, img.shape), 0, 255).astype(np.uint8)
        rgb, _ = pc.wall_colour(img)
        self.assertIsNone(rgb, "a wall all leaves is no answer (its neighbours' colour is used)")

    def test_brick_past_windows_sky_and_shopfront(self):
        rgb, share = pc.wall_colour(wall_photo(BRICK))
        self.assertLess(de(rgb, BRICK), 5.0, "%s for %s" % (rgb, BRICK))
        self.assertGreater(share, 0.3)

    def test_a_painted_green_house(self):
        rgb, _ = pc.wall_colour(wall_photo(GREEN))
        self.assertLess(de(rgb, GREEN), 5.0)

    def test_white_window_frames_do_not_wash_out_the_brick(self):
        img = wall_photo(BRICK)
        h = img.shape[0]
        for y in range(h // 10 + 8, int(h * 0.7), 22):            # each window framed in white
            for x in range(8, img.shape[1] - 12, 20):
                img[y - 3:y + 16, x - 3:x + 12] = (236, 236, 230)
                img[y:y + 13, x:x + 9] = (34, 36, 42)
        rgb, _ = pc.wall_colour(img)
        self.assertLess(de(rgb, BRICK), 5.0, "%s for %s" % (rgb, BRICK))

    def test_a_tree_in_front(self):
        img = wall_photo(BRICK)
        rng = np.random.default_rng(1)
        leaves = np.clip(np.array([62, 108, 48]) + rng.normal(0, 18, (100, 50, 3)), 0, 255).astype(np.uint8)
        img[20:120, 10:60] = leaves                                # half the upper floors behind leaves
        rgb, _ = pc.wall_colour(img)
        self.assertLess(de(rgb, BRICK), 5.0, "%s for %s" % (rgb, BRICK))

    def test_calibration_takes_out_the_cameras_cast_and_restores_colour(self):
        """The panorama camera sees everything a little cyan and washed out: one
        correction for the whole collection neutralises the cast (the median wall
        comes out grey) and gives the colour back."""
        rng = np.random.default_rng(3)
        # (In the proportions the centre's walls were measured in: 72% near-neutral (plaster, stone,
        # whitewash), the rest brick, green and brown.)
        true = np.array([BRICK] * 15 + [(120, 124, 126)] * 36 + [(230, 228, 220)] * 36 + [GREEN] * 6 + [(96, 60, 48)] * 7, float)
        seen = true * np.array([0.9, 1.0, 1.04]) * 0.85 + 30           # cyan, flat, hazy
        seen = np.clip(seen + rng.normal(0, 3, seen.shape), 0, 255)
        fix = pc.calibrate(seen)
        out = np.array([fix(c) for c in seen])
        med = np.median(out, axis=0)
        self.assertLess(med.max() - med.min(), 6.0, "the median wall comes out neutral: %s" % med)
        chroma = lambda c: np.hypot(*pc.lab(np.asarray(c, float))[1:])
        self.assertGreater(chroma(fix(seen[0])), chroma(seen[0]) * 1.3, "brick more like brick again")

    def test_blue_is_shade_or_glass_not_paint(self):
        """A wall that comes out blue is in the shade of a blue sky, or glass: grey stone, not blue paint."""
        import colorsys
        raws = [(120, 124, 126)] * 60 + [BRICK] * 20 + [(72, 96, 118)] * 10 + [(138, 203, 250)] * 5 + [(230, 228, 220)] * 30
        fix = pc.calibrate(raws)
        for c in [(72, 96, 118), (138, 203, 250)]:
            r, g, b = (np.array(fix(c)) / 255.0)
            h, l, s = colorsys.rgb_to_hls(r, g, b)
            self.assertLessEqual(s, 0.13, "%s comes out %s: not blue paint" % (c, fix(c)))
        self.assertGreater(colorsys.rgb_to_hls(*(np.array(fix(BRICK)) / 255.0))[2], 0.25, "brick keeps its colour")

    def test_blue_sky_and_its_reflections_are_not_the_wall(self):
        img = wall_photo(BRICK)
        h = img.shape[0]
        img[: h // 6] = (126, 190, 246)                            # a blue sky over the roofline
        for y in range(h // 10 + 8, int(h * 0.7), 22):            # the sky in every window, and big windows
            for x in range(6, img.shape[1] - 10, 20):
                img[y:y + 16, x:x + 13] = (138, 203, 250)
        rgb, _ = pc.wall_colour(img)
        # (Brick, or no answer when so much of it is sky: never the sky's colour.)
        self.assertTrue(rgb is None or de(rgb, BRICK) < 5.0, "%s for %s" % (rgb, BRICK))

    def test_a_photo_mostly_sky_is_no_answer(self):
        """A panorama that does not see the wall (a tram, a tree, a roofline the data puts too high):
        the cut-out is mostly sky over a street, and that is no wall's colour."""
        rng = np.random.default_rng(4)
        img = np.zeros((160, 96, 3), np.uint8)
        img[:100] = (176, 204, 232)                                # sky
        img[100:] = np.clip(np.array([90, 88, 86]) + rng.normal(0, 25, (60, 96, 3)), 0, 255)   # street, cars
        img[20:100, 40:44] = (40, 40, 40)                          # a lamp post
        rgb, _ = pc.wall_colour(img)
        self.assertIsNone(rgb)

    def test_all_windows_is_no_answer(self):
        img = np.full((100, 60, 3), 30, np.uint8)
        rgb, share = pc.wall_colour(img)
        self.assertIsNone(rgb)


def box(x0, y0, x1, y1, h=15.0):
    """A tile building (decimetres), flat-roofed."""
    return {"r": [[x0 * 10, y0 * 10, x1 * 10, y0 * 10, x1 * 10, y1 * 10, x0 * 10, y1 * 10]], "h": h, "e": h}


class FakePanos:
    """One panorama on the street in front of building A, whose wall is BRICK."""

    def __init__(self, pano, wall, colour):
        self.pano, self.wall, self.colour = pano, wall, colour

    def near_many(self, centre, radius):
        return [self.pano]

    def image(self, pano):
        img = synthetic_pano(pano, self.wall, W=2000, H=1000)
        out = np.full_like(img, 200)
        on = img[..., 2] == 255
        out[on] = self.colour
        return out


class EndToEnd(unittest.TestCase):
    def test_measured_estimated_and_left_alone(self):
        # A: a house on the street (its front wall faces south, y = 0), 12 m wide.
        # C: next to it, its only free wall faces north, away from the street: no panorama sees it.
        # B: far outside the area.
        a = box(0, 0, 12, 10)
        c = box(12, -8, 20, 10)
        c_back = box(12, -30, 20, -8.5)          # (C's south side is against this one: a party wall)
        b = box(5000, 0, 5012, 10)
        buildings = [a, c, c_back, b]
        pano = Pano("p", 6.0, -9.0, 0.0, "", h=2.6)
        wall = Facade(0, 0, (0.0, 0.0), (12.0, 0.0), 15.0, (0.0, -1.0))
        res = pc.measure(buildings, FakePanos(pano, wall, BRICK), centre=(0.0, 0.0), radius=500.0, gain=1.0)
        self.assertIn(0, res)
        self.assertFalse(res[0]["est"])
        self.assertLess(de(res[0]["c"], BRICK), 6.0, res[0])
        self.assertIn(1, res, "C takes its neighbours' colour")
        self.assertTrue(res[1]["est"])
        self.assertLess(de(res[1]["c"], BRICK), 6.0)
        self.assertNotIn(3, res, "B is outside the area")


if __name__ == "__main__":
    unittest.main()
