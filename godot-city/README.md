# Amsterdam in Godot

The whole of Amsterdam (285,000 buildings, from Overture Maps / OpenStreetMap
open data) streams in 375 m chunks around you: the ones nearest you are built
first, one at a time, and the ones far behind you are dropped again. Cars, GVB buses and
three-section trams drive the real street and tram-track network, and you
run around it on foot, GTA-style: you start on the Dam with a minimap in
the corner, among pedestrians, with the traffic stopping for you.

Open the folder in **Godot 4.4 or newer** and press Play (F5). It works on
macOS, Windows and Linux.

## Controls

| On foot (the default) | |
|---|---|
| WASD or arrow keys | move (relative to camera) |
| Shift | run |
| Space | jump |
| Mouse (click to capture) / right-drag / two-finger swipe | look |
| Wheel | camera distance |
| E | get in or out of the car, bus or tram next to you |
| M (or Tab, G) | switch to the map |
| Esc | free the mouse |

| Map mode | |
|---|---|
| Drag / two-finger scroll | pan |
| Right-drag, Q/E, R/F, Shift+scroll | rotate and tilt |
| Wheel, pinch, +/- | zoom |
| WASD / arrows | move |
| M | drop down and walk where the camera is looking |
| "Ride a tram" | follow the nearest tram |

The slider sets the time of day; at night the windows, street lamps,
headlights and the tram and bus destination signs light up. Fall into a
canal and you swim; swim to a quay to climb out.

## Traffic

Cyclists ride the bike paths and the edges of the streets, and parked bikes
stand at the city's bike racks and in small groups along the house fronts. Press E next to a parked bike, or next to a
cyclist, to ride it (Shift pedals hard). Red Cantas, the narrow Dutch microcars, potter along the streets too (E to
drive one, 45 km/h tops). Press E next to a car to take the wheel: WASD or the arrow keys drive,
Space brakes, and walls, canals and other traffic stop you. Press E next to
a bus or tram to ride it along its route. E again gets you out; a car you
leave stays parked where you left it.

`scripts/traffic.gd` joins every tile's road and tram-track polylines into
one graph and drives about 70 cars, 7 buses and 9 trams around you. Cars
keep right and keep their distance, including from you. Everything slows
for bends. Buses use only wide roads; trams use only tram tracks. Buses and
trams stop now and then, as if at a stop. Each 30 m tram is three sections
plus bellows, articulated along the path its front has driven.

## Regenerating the data

`data/` is generated (about 73 MB). From the repository root:

```bash
python fetch_city.py data/city                          # Overture Maps, ~10 min
python prepare_city_tiles.py data/city out/city
python prepare_godot_city.py out/city godot-city/data   # ends by cutting the chunks
```

Each `data/tiles/i_j.json` is one 1.5 km download holding its 16 chunks
(`amsterdam/chunks.py` cuts them; streets, canals and parks are clipped at the
chunk edges so they still join up). To re-cut existing data, for instance at
another size: `python chunk_godot_tiles.py godot-city/data 375`.

## Files

- `scripts/main.gd`: scene setup, sun and sky, UI, mode switching
- `scripts/city_streamer.gd`: streams chunks: threaded loading and meshing, queries
- `scripts/tile_builder.gd`: tile JSON to mesh arrays (facades, roofs, streets, water)
- `scripts/materials.gd`: the texture atlas materials
- `scripts/traffic.gd`, `scripts/vehicle_models.gd`: traffic
- `scripts/walker.gd`, `scripts/human.gd`: the player and pedestrians
- `scripts/bike_rig.gd`: a ridden bike: wheels, crank, and the rider's legs and arms on pedals and grips
- `models/canta.glb`: the Canta, modelled by `blender/make_canta.py`
- `models/bike_*.glb`: the bikes, modelled in Blender by `blender/make_bikes.py`
  (`pip install bpy`, then `python blender/make_bikes.py godot-city/models`)
- `scripts/minimap.gd`: the round minimap (built from the tile meshes)
- `scripts/map_camera.gd`: map-app orbit camera with trackpad gestures

Test render: `godot --path . -- --shot=out.png --view=map|tram|walk --hour=17`
