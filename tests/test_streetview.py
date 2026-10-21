import math
import unittest

import numpy as np

from amsterdam.streetview import AtlasPacker, Facade, Pano, best_pano, facades, rectify


def synthetic_pano(pano, f, W=2048, H=1024):
    """An equirectangular image of one wall whose pixels encode where on the
    wall they are: red = across (a -> b), green = down (top -> street)."""
    img = np.zeros((H, W, 3), np.uint8)
    cols, rows = np.meshgrid(np.arange(W) + 0.5, np.arange(H) + 0.5)
    bearing = (cols / W) * 2 * math.pi - math.pi + math.radians(pano.heading)
    pitch = (0.5 - rows / H) * math.pi
    d = np.stack([np.sin(bearing) * np.cos(pitch), np.cos(bearing) * np.cos(pitch), np.sin(pitch)], -1)
    n = np.array([f.normal[0], f.normal[1], 0.0])
    a = np.array([f.a[0], f.a[1], 0.0]); b = np.array([f.b[0], f.b[1], 0.0])
    c = np.array([pano.x, pano.y, pano.h])
    t = ((a - c) @ n) / (d @ n)
    hit = c + d * t[..., None]
    along = (b - a) / np.linalg.norm(b - a)
    u = ((hit - a) @ along) / np.linalg.norm(b - a)
    v = 1 - hit[..., 2] / f.top
    ok = (t > 0) & (u >= 0) & (u <= 1) & (v >= 0) & (v <= 1)
    img[ok, 0] = (u[ok] * 255).astype(np.uint8)
    img[ok, 1] = (v[ok] * 255).astype(np.uint8)
    img[ok, 2] = 255
    return img


class Rectify(unittest.TestCase):
    def check(self, pano, f):
        photo = rectify(f, pano, synthetic_pano(pano, f), px_per_m=16)
        H, W = photo.shape[:2]
        self.assertEqual((W, H), (round(f.width * 16), round(f.top * 16)))
        inner = photo[2:-2, 2:-2].astype(float)
        self.assertTrue((inner[..., 2] > 200).all(), "every pixel lands on the wall")
        u = (np.arange(W) + 0.5) / W * 255
        v = (np.arange(H) + 0.5) / H * 255
        self.assertLess(np.abs(photo[..., 0].astype(float) - u[None, :])[2:-2, 2:-2].max(), 6)
        self.assertLess(np.abs(photo[..., 1].astype(float) - v[:, None])[2:-2, 2:-2].max(), 6)

    def test_square_on(self):
        f = Facade(0, 0, (-3.0, 0.0), (3.0, 0.0), 12.0, (0.0, -1.0))
        self.check(Pano("p", 0.0, -10.0, 0.0, ""), f)

    def test_oblique_and_turned_camera(self):
        f = Facade(0, 0, (10.0, 5.0), (10.0, -2.0), 9.0, (-1.0, 0.0))   # faces west
        self.check(Pano("p", 1.0, -6.0, 137.0, ""), f)


def rect(x0, y0, x1, y1, h=10.0):
    ring = [x0, y0, x1, y0, x1, y1, x0, y1]
    return {"r": [[int(c * 10) for c in ring]], "h": h, "k": 1}


class Facades(unittest.TestCase):
    def test_party_walls_are_skipped_and_fronts_face_out(self):
        # Two houses side by side along a street to their south.
        fs = facades([rect(0, 0, 6, 12), rect(6, 0, 12, 12)])
        walls = {(f.building, round(f.normal[0]), round(f.normal[1])) for f in fs}
        self.assertIn((0, 0, -1), walls)          # street front
        self.assertIn((1, 0, -1), walls)
        self.assertNotIn((0, 1, 0), walls)        # the shared wall
        self.assertNotIn((1, -1, 0), walls)
        front = next(f for f in fs if f.building == 0 and f.normal == (0.0, -1.0))
        self.assertEqual((front.a, front.b), ((0.0, 0.0), (6.0, 0.0)))   # left to right from the street

    def test_best_pano_prefers_square_on_and_near(self):
        f = Facade(0, 0, (-3.0, 0.0), (3.0, 0.0), 12.0, (0.0, -1.0))
        panos = [Pano("behind", 0, 10, 0, ""), Pano("far", 0, -40, 0, ""), Pano("side", 15, -3, 0, ""), Pano("good", 1, -9, 0, "")]
        self.assertEqual(best_pano(f, panos).id, "good")


class Atlas(unittest.TestCase):
    def test_pages_fill_and_uvs_point_at_the_pixels(self):
        pk = AtlasPacker(size=64)
        spots = [pk.add(np.full((20, 30, 3), i * 10, np.uint8)) for i in range(8)]
        self.assertGreater(len(pk.pages), 1)
        for i, (page, u0, v0, u1, v1) in enumerate(spots):
            x, y = int(u0 * 64), int(v0 * 64)
            self.assertEqual(pk.pages[page][y + 5, x + 5, 0], i * 10)
            self.assertAlmostEqual((u1 - u0) * 64, 30)


if __name__ == "__main__":
    unittest.main()


class CreditsRunOut(unittest.TestCase):
    """The run stops at the first out-of-credits answer, keeps what it made
    and the photo it could not send, and continues there next time."""

    def test_stop_and_resume(self):
        import json, tempfile
        from pathlib import Path
        from amsterdam.tripo import OutOfCredits
        from generate_buildings import run
        from tests.test_streetview import synthetic_pano

        houses = [rect(i * 7, 0, i * 7 + 6, 12) for i in range(0, 12, 2)]   # detached, street to the south

        class FakePanos:
            def near(self, x, y, radius=25):
                return [Pano("p%d_%d" % (round(x), round(y)), x, y, 0.0, "")]   # square on, 10 m out
            def image(self, pano):
                return np.full((256, 512, 3), 90, np.uint8)

        class FakeHttp:
            def get(self, url, timeout=0):
                class R:
                    content = b"glTF"
                    def raise_for_status(self): pass
                return R()

        class FakeTripo:
            http = FakeHttp()
            def __init__(self, credits): self.credits = credits
            def upload(self, path): return "tok"
            def image_to_model(self, tok):
                if self.credits == 0:
                    raise OutOfCredits("insufficient balance")
                self.credits -= 1
                return "t"
            def wait(self, t): return {"task_id": t, "output": {"model": "https://x/m.glb"}}

        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / "data" / "tiles").mkdir(parents=True)
            (d / "data" / "tiles" / "0_0.json").write_text(json.dumps({"buildings": houses}))
            out = d / "out"; out.mkdir()
            code = run(d / "data", out, ["0_0"], None, FakePanos(), FakeTripo(2), log=lambda *a: None)
            self.assertEqual(code, 3)
            m = json.loads((out / "manifest.json").read_text())
            self.assertEqual(sum(v["status"] == "done" for v in m.values()), 2)
            self.assertEqual(len(list(out.glob("0_0/*.glb"))), 2)
            code = run(d / "data", out, ["0_0"], None, FakePanos(), FakeTripo(100), log=lambda *a: None)
            self.assertEqual(code, 0)
            m = json.loads((out / "manifest.json").read_text())
            self.assertEqual(sum(v["status"] == "done" for v in m.values()), len(houses))
