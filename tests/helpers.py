import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import make_sample  # noqa: E402
from amsterdam.sources import load_cityjson_doc  # noqa: E402


def sample_doc(seed=7):
    return make_sample.to_cityjson(make_sample.street(seed))


def two_houses():
    """Two flat-roofed houses sharing one side wall, as 3D BAG would give them."""
    import random
    rng = random.Random(0)
    a = make_sample.house(0, 6, 0, 12, -1, 10, "flat", rng)
    b = make_sample.house(6, 5, 0, 12, -1, 13, "gable_front", rng)
    return load_cityjson_doc(make_sample.to_cityjson([(a, 1650), (b, 1680)]))
