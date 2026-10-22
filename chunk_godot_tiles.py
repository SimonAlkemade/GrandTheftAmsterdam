"""Cut the prepared Godot tiles into streaming chunks, in place.

    python chunk_godot_tiles.py godot-city/data [chunk metres, default 375]

Each data/tiles/i_j.json becomes {"tile", "chunk", "chunks": {key: chunk}}
and index.json gains "chunk" and "chunks" (one [a, b, buildings] per chunk),
which is what the game streams. Tiles already chunked are left alone.
prepare_godot_city.py does this as its last step for freshly prepared data.
"""
import json
import sys
from pathlib import Path

from amsterdam.chunks import chunk_tile


def chunk_data(dst: Path, chunk_m: float = 375.0) -> int:
    index = json.loads((dst / "index.json").read_text())
    tile_dm = float(index["tile"]) * 10
    chunk_dm = chunk_m * 10
    chunks = []
    for f in sorted((dst / "tiles").glob("*.json")):
        t = json.loads(f.read_text())
        if "chunks" not in t:
            t = chunk_tile(t, tile_dm, chunk_dm)
            f.write_text(json.dumps(t, separators=(",", ":")))
        for key, c in t["chunks"].items():
            a, b = c["tile"]
            chunks.append([a, b, len(c.get("buildings", []))])
    index["chunk"] = chunk_m
    index["chunks"] = sorted(chunks)
    (dst / "index.json").write_text(json.dumps(index, separators=(",", ":")))
    return len(chunks)


if __name__ == "__main__":
    n = chunk_data(Path(sys.argv[1]), float(sys.argv[2]) if len(sys.argv) > 2 else 375.0)
    print("%d chunks" % n)
