# Amsterdam in Godot

The whole of Amsterdam (285,000 buildings, from Overture Maps / OpenStreetMap
open data) streams in 375 m chunks around you: the ones nearest you are built
first, one at a time (in the browser a slice a frame, so it never freezes),
and the ones far behind you are dropped again. Cars, GVB buses and
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
| Left click / R | shoot / reload the pistol (Mission 2) |
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
the next parcel is waiting. Run out of time and the parcel goes back. Five
parcels delivered and the job is done: on to Mission 3.

## Mission 2: a gun, and the police

You start with €60, and a gun shop (a blue circle with WAPENS over it, a blue
blip on the minimap) stands on a pavement near the Dam. Walk in and a pistol
is yours for €50: 12 rounds in it and 24 more. On foot, **left click** shoots
where the camera looks (a crosshair shows while you hold it; you turn to aim),
**R** reloads, and back at the shop €10 buys 24 more rounds. Bullets stop at
walls, the street and vehicles (a real vehicle takes the knock); a pedestrian
hit goes down, and everyone within 40 m runs from the shot. The traffic within
60 m (cars, Cantas, buses, cyclists) drives off flat out for 12 seconds,
taking whichever way leads away from the shot and stopping for no one on foot
on the way (trams keep to their rails; police cars come the other way).

Shooting makes you wanted, shown as five stars at the top left: any shot is
one star, hitting someone two, hitting a police officer three and up, to five.
Police cars in the Dutch livery (white, the blue and orange stripes, POLITIE,
the blue lights flashing) are sent one at a time, a car per star up to four;
they drive along the streets, at every junction towards where they last saw
you, and stop near you. Two officers get out of each and run there (4.6 m/s:
you can outrun them; 6.2 running). One who reaches you on foot, or in a
vehicle standing still, arrests you: **BUSTED**, a €100 fine (or what you
have) and the pistol gone. While no officer can see you (nothing built in the
way, within 70 m) the stars flash; stay out of sight 10 s plus 5 s a star and
they give up. `tests/crime_test.gd` plays it through on a grid of test streets:

    godot --headless --path godot-city --script tests/crime_test.gd

## Mission 3: tulips for the tourists

After the fifth parcel, the yellow circle leads to the Bloemenmarkt, the
flower market on the Singel (with a tulip turning over it). Walk in and you
have ten bunches of tulips, a bouquet in your hand. Among the people in the
street, up to three at a time are tourists who want some: a tulip turns over
their heads, and they are pink dots on the minimap; the nearest is the yellow
blip. Walk up to one and they stop and turn to you; stand by them a moment
and they buy a bunch for €6 to €12, one each. A tourist you scare off (a
gunshot), knock down or leave far behind is no longer one, and others turn
up. Sold out, it is back to the market for more. (`--mission=tulips` starts
the game straight at Mission 3.) `tests/tulips_test.gd` plays it through on a
grid of test streets:

    godot --headless --path godot-city --script tests/tulips_test.gd

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

A GVB bus is a real vehicle too: E at its front door takes the wheel (E
further back still gets you a seat). It is 12 tonnes on air suspension: 0-50
km/h in about 8 s, 70 km/h flat out, stops from 50 in about 16 m, leans in a
corner, and shoves a car it hits a good 5 m.

`tests/car_test.gd` measures all of it on a flat test ground:

    godot --headless --path godot-city --script tests/car_test.gd [-- --kind=canta|bus]

### Trams

The trams are the yellow GVB trams of the 1990s (the 11G/12G), built in
`vehicle_models.gd`: 27 m in three sections joined by bellows, a boxy
high-floor body over a dark skirt and visible bogies, separate windows between
yellow pillars, folding doors on the right-hand side only, a flat cab with a
split windscreen, the destination box and line number above it and round
headlights, a diamond pantograph on the roof.
Each tram runs under a line number and destination from the GVB network of
the 1990s (1 Osdorp, 2 Nieuw Sloten, 5 Amstelveen Binnenhof, 13 Geuzenveld,
25 President Kennedylaan, and back to Centraal Station...): the number black
on a lit white box and the destination in amber letters over the windscreen,
both again on a side sign by the front door, the number in the back window,
and E next to it says which tram it is. (The traffic follows the real tracks,
not those lines' routes.)

The tracks are one-way, as in Amsterdam: a line is two tracks side by side and
trams keep right, so each track runs the way that puts the other track, the
oncoming one, on a tram's left. That direction is read off the map data (a
track with no partner beside it, a single-track stretch, runs both ways). At
the end of a track a tram crosses over to the track back, as round a terminus
loop, once it is clear. Trams never pass through one another: a tram keeps a
stopping distance behind the one ahead, measured along the rails and over the
points, and waits behind it rather than slipping past.

E at a tram's front cab puts you at its controls. A tram stays on its rails,
so its physics is along them: 35 tonnes, up to 1.3 m/s² of traction fading
towards 70 km/h, **W** power, **S** the service brake (50 km/h to a stop in
about 70 m), **Space** the emergency brake (about 34 m), and with the power off
it coasts on and on. **A/D** set the points: at the next junction it takes the
leftmost or rightmost branch (otherwise the straightest). The three sections
follow the front round the curves, and a car in its way is shoved aside.

### Pedestrians

The 24 people walking the streets around you keep their distance the way
people do: each looks up to three seconds ahead for anyone who will pass too
close (you, the vehicle you are in, or another pedestrian) and sidesteps
early, to its right when the other comes straight at it, so two people
meeting pass each other; it gives room to anyone already close, slows in a
crowd, and nobody ever overlaps anyone. Run into one and they stagger.
They watch the traffic too, measuring against each car's, bus's, tram's and
bike's whole body: they wait at the kerb for one about to cross their way
(a whole 27 m tram goes by first), hurry sideways out of the path of one
coming at them, walk round one that is parked, and are never inside one.
Drivers brake for them in turn: every car, Canta, bus, tram and cyclist
watches 25 m ahead and stops about 3 m short of anyone standing in its way or
walking into it within the next second and a half, ignores people on the
pavement beside it, and drives on once the way is clear. (A pedestrian waits
only for a vehicle still moving, so when a car stops for one, they cross.)
`tests/peds_test.gd` checks someone walking at you, two meeting head-on, a
crowd of 20, a car crossing, a car coming at someone in the road, a parked bus
and a passing tram:

    godot --headless --path godot-city --script tests/peds_test.gd

### Knocked over: ragdolls

Hit hard enough, a person goes limp: a car, bus, tram or bike doing more than
about 11 km/h that runs into them, you sprinting into them (walking or jogging
into someone only nudges them or makes them stagger), or a bullet. Their
figure comes apart into ten rigid bodies, pelvis, torso and head, upper and
lower arms and legs, joined at the waist, shoulders, elbows, hips and knees,
and is thrown the way the hit was going. It tumbles, slides and settles on the
street, and you, your vehicle and other traffic can push it about. Once they
have lain still for two seconds they get up and walk on (unless they were
shot); at most eight people lie in the street at once, and a ninth only
staggers. `tests/ragdoll_test.gd` checks that a person hit at 25 km/h falls
flat a few metres on with the limbs joined, comes to rest and is put back
together; that walking into someone only nudges them, sprinting into them or
driving into them knocks them over, and that they get up again:

    godot --headless --path godot-city --script tests/ragdoll_test.gd

### The traffic on its springs

Every car, Canta, bus and tram near you rides on springs: a damped spring per
axis, driven by its real acceleration along and across, so it dips its nose
braking for a bend (about 4°), squats pulling away, rolls out of a corner
(about 4° for a car, more for a bus, hardly at all for a tram) and settles.
Cyclists lean into their turns by the angle that balances them. Car and bus
wheels turn. A cyclist you hit goes down, bike and all.
`tests/traffic_test.gd` checks the springs, the lean, the one-way double track and the tram's
traction, brakes, coasting and points on a test layout:

    godot --headless --path godot-city --script tests/traffic_test.gd

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
keep their distance, including from you, and everything slows for bends.

The streets are one-way wherever they can be, and cars, Cantas and buses
drive down the middle of them: nothing comes the other way to hit. (The map
data has no one-way signs, so the ways are made up, but so that every corner
can still be reached from every other: a depth-first search over the street
network, Robbins's way, gives every street on a loop a direction, down the
search tree and back up the loops.) A street everything beyond hangs on, a
dead end, stays two-way, each way keeping to its side, and a car that comes
to the end of one turns round. In the old centre about three streets in five
come out one-way. A street keeps its way once it has one: as chunks stream
in, only their new streets are given ways, with the network already there
counting as one corner, so the loops close through it. Cyclists still ride
both ways, at the side of the street; police cars on a call go any way they
like; what you drive is up to you. Buses use only wide roads; trams use only tram tracks. Buses and
trams stop now and then, as if at a stop. Each 30 m tram is three sections
plus bellows, articulated along the path its front has driven.

## Frame rate

What a frame costs, standing on the Dam (measured natively on the
browser's renderer, Compatibility; before → after the frame-rate pass):

| | before | after |
|---|---|---|
| draw calls | 10,991 | about 2,600 |
| triangles | 5.9 million | about 1.0 million |
| traffic script | 33 ms | about 6 ms |
| a chunk loading in the browser | one 100-170 ms freeze per chunk, plus about 115 ms parsing its 1.5 km file | 4 ms slices over about 25 frames |

How:

- **On foot you see 950 m**, the fog closing in from 300 m (the map camera
  still sees the whole city), and the chunks loaded round you reach 850 m
  instead of 1,100 m. The sun's shadows reach 160 m in two cascades (they
  were 600 m in four, and the shadow pass drew more than the picture).
- **Fewer, bigger meshes.** A vehicle's parts are merged into one mesh per
  material (`VehicleModels.bake`; a tram was 115 meshes, now about a dozen
  surfaces), its wheels left free to turn. Lamps, benches, bins, signals and
  bollards are instanced per 100 m block and drawn within 220 m, with no
  shadows; cyclists within 160 m. People's heads and hands are low-poly
  spheres (Godot's default sphere is 4,000 triangles), and hands, feet, hair
  and necks cast no shadow of their own.
- **Traffic** sorts its vehicles into a 50 m grid each frame, so each one
  checks only its neighbours for the gap ahead (it used to check every other
  vehicle), and vehicles over 180 m away move every third frame.
- **Streaming without freezes in the browser**, which has no threads: the
  browser parses a tile file and keeps each chunk as its own string; the game
  then builds and adds one chunk at a time a 4 ms slice per frame
  (`TileBuilder.budget_usec`), so a chunk arrives over about 25 frames instead
  of freezing one. On the desktop chunks are still built on worker threads.
- On a high-density (Retina) screen the browser draws the 3D world at about
  normal density, scaled up; the HUD stays sharp.

The data's 375 m chunks stay as they are: smaller ones would multiply the
draw calls (a chunk's buildings are one mesh with a surface per material),
and slicing already takes the freeze out of loading one.
`tests/streaming_test.gd` checks that a chunk built in slices is the same
chunk and never holds a frame up for long:

    godot --headless --path godot-city --script tests/streaming_test.gd

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
- `scripts/ragdoll.gd`: a person knocked over, gone limp
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
