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
| E | get in or out of the car, Canta, bike, bus, tram or boat next to you |
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
canal and you swim (Shift for a faster crawl); swim to a quay to climb out,
or up to a boat and press E to climb aboard.

## Boats

Sloepen, the open motor launches of the canals, lie moored along the quays
around you (`scripts/boats.gd` puts them on the loaded canal polygons, along
the canal and close to a quay). E from the quay or the water takes the helm:
W/S are the throttle (and astern), A/D swing the outboard, Shift opens it up.
E again steps you onto the quay, or into the water if there is none in reach;
the boat stays where you left it. One sloep always lies at the Damrak quay by
the Beurs, the canal water nearest the Dam where you start: walk up the
Damrak (about 450 m, the street with the tram line) to find it.

Each boat is a RigidBody3D (`scripts/boat.gd`) held up by buoyancy: eight
points round the bottom of the hull each lift in proportion to how deep they
are below a gently swelling surface, and damp their own bobbing, so it finds
its own waterline, rights itself when heeled and pitches and rolls as it
goes. The water drags weakly along the hull and hard across it, so the boat
glides on when you let go and its stern slides out in a turn; the thrust acts
at the stern along the outboard's angle, so it steers best under power. It
bumps off quay walls. `tests/boat_test.gd` checks the waterline, the
righting, the speed, the glide, the turn and ramming a quay on flat water:

    godot --headless --path godot-city --script tests/boat_test.gd

## Bridges

The bridges hump over the canals the Amsterdam way (`TileBuilder._bridge`):
the data's bridges run from quay to quay, so a ramp rises from each quay over
the first and last ~30% of the bridge to a level middle 1.2 m above the
street, with railings, a stone edge and a stone underside 0.55 m below the
deck. That leaves about 2.35 m of water clearance in the middle, so a sloep
and the person at its helm pass underneath, and the camera drops under the
deck with you. Where a chunk border cuts a bridge, its end there stays at full
height, so the two halves meet. On foot you walk up and over, the cars, buses,
trams and cyclists of the traffic ride over the hump (pitched on the ramps),
the cars you drive climb it on their suspension, and lamps and benches on a
bridge stand on its deck. Swimming under a bridge you climb out only at a
quay, not up onto the bridge overhead.

## Mission 1: parcel courier

As soon as you are on your feet the job starts. A yellow circle (with a beam
of light you can see over the roofs) marks where to pick up a parcel; walk,
cycle or drive into it and you carry the parcel, and a second circle marks
where it goes. The text at the bottom says what to do and how far it is; the
route along the streets is drawn in yellow on the minimap and, in the map
view (M), over the streets themselves. Each delivery has a clock set by the
length of the route and pays €25 plus €1 for every 6 seconds to spare; then
the next parcel is waiting. Run out of time and the parcel goes back.

## Driving physics

What you drive is a real vehicle (Godot's VehicleBody3D, `scripts/vehicle_physics.gd`):
each wheel is a damped spring with tyre grip, the engine pulls through the
driven wheels, and the body pitches under braking and acceleration and rolls
in corners. It hits buildings, quay walls, bridge railings and the traffic
around you, and a car that goes off a quay ends up on the canal bed. The bike
leans by exactly the angle that balances its turn (tan lean = speed x yaw rate
/ g). Each chunk carries the collision floor for this: the street, bridge
decks, quay walls and canal beds. The traffic itself stays on its routes, but
each vehicle in it is solid.

Cars and Cantas handle the GTA way:

| | Car | Canta |
|---|---|---|
| 0-100 km/h | 4.7 s | (0-36 km/h in 2.2 s) |
| Top speed | 125 km/h | 46 km/h |
| Braking from 100 km/h | 51 m | |

- **W** drives, **S** brakes and then reverses, **A/D** steer: less lock the
  faster you go, and when the tail steps out the steering helps you catch it.
- **Space** is the handbrake: the rear wheels lock and lose their grip, so a
  flick of steering swings the tail out (a 45° slide and a 110° turn in a
  second from 60 km/h) and it gathers itself when you let go.
- Downforce and an anti-roll bar: it leans into a fast corner (about 3°) and
  stays on its wheels at full lock at 80 km/h.
- In the air, or on its side, **A/D** roll it and **W/S** tip it.
- A street car or Canta you are about to hit stops being scenery on rails and
  becomes a real car just before the hit: a crash shoves it, spins it, or (in a
  450 kg Canta against a 1250 kg car) bounces you off it. Its driver then
  brakes, so it skids to a stop where the crash left it. Buses and trams stay
  on their rails.

`tests/car_test.gd` measures all of it on a flat test ground:

    godot --headless --path godot-city --script tests/car_test.gd [-- --kind=canta]

## Traffic

Cyclists ride the bike paths and the edges of the streets, and parked bikes
stand at the city's bike racks and in small groups along the house fronts. Press E next to a parked bike, or next to a
cyclist, to ride it (Shift pedals hard). Red Cantas, the narrow Dutch microcars, potter along the streets too (E to
drive one, 45 km/h tops). Press E next to a car to take the wheel (see
Driving physics above for the controls). Press E next to
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
- `scripts/vehicle_physics.gd`: suspension, engine, brakes and steering for what you drive
- `scripts/walker.gd`, `scripts/human.gd`: the player and pedestrians
- `scripts/bike_rig.gd`: a ridden bike: wheels, crank, and the rider's legs and arms on pedals and grips
- `scripts/boat.gd`, `scripts/boats.gd`: the floating boats and where they are moored
- `models/canta.glb`: the Canta, modelled by `blender/make_canta.py`
- `models/boat.glb`: the sloep, modelled by `blender/make_boat.py`
- `models/bike_*.glb`: the bikes, modelled in Blender by `blender/make_bikes.py`
  (`pip install bpy`, then `python blender/make_bikes.py godot-city/models`)
- `scripts/mission.gd`: the parcel courier: circles, routing (A* over the street graph), clock and pay
- `scripts/minimap.gd`: the round minimap (built from the tile meshes)
- `scripts/map_camera.gd`: map-app orbit camera with trackpad gestures

Test render: `godot --path . -- --shot=out.png --view=map|tram|walk --hour=17`
