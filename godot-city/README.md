# Amsterdam in Godot

The whole of Amsterdam (285,000 buildings, from Overture Maps / OpenStreetMap
open data) streams in 1.5 km tiles around you. Cars, GVB buses and
three-section trams drive the real street and tram-track network, and you
can drop down and walk among pedestrians.

Open the folder in **Godot 4.4 or newer** and press Play (F5). It works on
macOS, Windows and Linux.

## Controls

| Map mode | |
|---|---|
| Drag / two-finger scroll | pan |
| Right-drag, Q/E, R/F, Shift+scroll | rotate and tilt |
| Wheel, pinch, +/- | zoom |
| WASD / arrows | move |
| G | walk where the camera is looking |
| "Ride a tram" | follow the nearest tram |

| Walk mode | |
|---|---|
| WASD | walk (relative to camera) |
| Shift | run |
| Space | jump |
| Mouse | look (Esc frees the mouse) |
| Wheel | camera distance |
| G | back to the map |

The slider sets the time of day; at night the windows, street lamps,
headlights and the tram and bus destination signs light up. Fall into a
canal and you swim; swim to a quay to climb out.

## Traffic

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
python prepare_godot_city.py out/city godot-city/data
```

## Files

- `scripts/main.gd`: scene setup, sun and sky, UI, mode switching
- `scripts/city_streamer.gd`: threaded tile loading and meshing, queries
- `scripts/tile_builder.gd`: tile JSON to mesh arrays (facades, roofs, streets, water)
- `scripts/materials.gd`: the texture atlas materials
- `scripts/traffic.gd`, `scripts/vehicle_models.gd`: traffic
- `scripts/walker.gd`, `scripts/human.gd`: the player and pedestrians
- `scripts/map_camera.gd`: map-app orbit camera with trackpad gestures

Test render: `godot --path . -- --shot=out.png --view=map|tram|walk --hour=17`
