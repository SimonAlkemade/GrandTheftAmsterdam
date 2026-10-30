extends Control
## A GTA-style round minimap: the streets, canals, parks and rooftops around
## the player, turned so that up is where the camera looks, with traffic as
## dots and the player as an arrow. Built from the same tile meshes as the
## city (see `CityStreamer.minimap_near`).

const SIZE := 230.0
const VIEW := 180.0                  # metres from centre to rim
const COLORS := {
	"water": Color("3a78b0"), "green": Color("3f7a4a"), "walk": Color("4b5057"),
	"road": Color("c9ccd1"), "tram": Color("8e6b4a"), "roof": Color("858a93"),
}
const VEHICLE := {"car": Color("e8e8e8"), "bus": Color("4f8dff"), "tram": Color("ff5a4f"), "bike": Color("ffd166"), "canta": Color("ff3b3b"), "boat": Color("ffffff")}
const MISSION := Color(1.0, 0.82, 0.08)
const DOT := {"car": 4.5, "bus": 7.0, "tram": 7.0, "bike": 2.6, "canta": 3.5, "boat": 4.0}

var streamer
var traffic
var boats
var crime                            # the police and the gun shop show here too
var walker
var mission                          # the current job: its route and target show here
var _tris: Array = []
var _cached_at := Vector2(INF, INF)
var _disc: Panel
var _map: Control
var _top: Control


func _ready() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The round mask: children are clipped to the disc this panel draws.
	_disc = Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("24282d")
	sb.set_corner_radius_all(int(SIZE / 2))
	sb.anti_aliasing = true
	_disc.add_theme_stylebox_override("panel", sb)
	_disc.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	_disc.size = size
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_disc)
	_map = Control.new()
	_map.size = size
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.draw.connect(_draw_map)
	_disc.add_child(_map)
	_top = Control.new()
	_top.size = size
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.draw.connect(_draw_top)
	add_child(_top)


func _process(_dt: float) -> void:
	if not visible or walker == null:
		return
	var p := Vector2(walker.global_position.x, walker.global_position.z)
	if p.distance_to(_cached_at) > 24.0:
		_tris = streamer.minimap_near(p, VIEW + 40.0)
		_cached_at = p
	_map.queue_redraw()
	_top.queue_redraw()


func _draw_map() -> void:
	var p := Vector2(walker.global_position.x, walker.global_position.z)
	var k := (SIZE / 2.0) / VIEW
	var xf := Transform2D(walker.cam_yaw, Vector2(k, k), 0.0, size / 2.0) * Transform2D(0.0, -p)
	_map.draw_set_transform_matrix(xf)
	var ci := _map.get_canvas_item()
	for t in _tris:
		RenderingServer.canvas_item_add_triangle_array(ci, PackedInt32Array(), t[1], PackedColorArray([COLORS[t[0]]]))
	if mission and mission.route.size() > 1:
		_map.draw_polyline(mission.route, Color(0, 0, 0, 0.5), 12.0, true)
		_map.draw_polyline(mission.route, MISSION, 7.0, true)
	for v in traffic.vehicles:
		if v.pos.distance_to(p) < VIEW + 10.0:
			if v.get("police", false):         # a police car on a call: flashing red and blue
				var on := fmod(Time.get_ticks_msec() / 1000.0, 0.5) < 0.25
				_map.draw_circle(v.pos, DOT.car + 2.0, Color(0.15, 0.35, 1.0) if on else Color(1.0, 0.15, 0.15))
			else:
				_map.draw_circle(v.pos, DOT[v.kind], VEHICLE[v.kind])
	if mission:                           # tourists who want tulips: pink, ringed white
		for t in mission.tourists:
			var tp := Vector2(t.pos.x, t.pos.z)
			if tp.distance_to(p) < VIEW + 10.0:
				_map.draw_circle(tp, 4.6, Color.WHITE)
				_map.draw_circle(tp, 3.4, mission.PINK)
	if crime:
		for q in crime.pickups:               # pistols lying about: orange
			var qp := Vector2(q.pos.x, q.pos.z)
			if qp.distance_to(p) < VIEW + 10.0:
				_map.draw_circle(qp, 5.0, Color(0, 0, 0, 0.7))
				_map.draw_circle(qp, 3.8, crime.ORANGE)
		for c in crime.cops:
			if not c.down and Vector2(c.pos.x, c.pos.z).distance_to(p) < VIEW + 10.0:
				_map.draw_circle(Vector2(c.pos.x, c.pos.z), 3.2, Color(0.2, 0.45, 1.0))
	if boats:
		for b in boats.boats:             # boats: a white dot ringed in canal blue
			if b.pos.distance_to(p) < VIEW + 10.0:
				_map.draw_circle(b.pos, DOT.boat + 1.5, Color("173a5c"))
				_map.draw_circle(b.pos, DOT.boat, VEHICLE.boat)
	_map.draw_set_transform_matrix(Transform2D())


# Rim, north marker and the player arrow, on top of the clipped map.
func _draw_top() -> void:
	var c := size / 2.0
	_top.draw_arc(c, SIZE / 2.0 - 2.0, 0, TAU, 96, Color(0, 0, 0, 0.85), 4.0, true)
	_top.draw_arc(c, SIZE / 2.0 - 5.0, 0, TAU, 96, Color(1, 1, 1, 0.25), 1.5, true)
	# The target: a yellow blip, held on the rim while it is out of range.
	if mission and mission.target != Vector3.INF:
		var d := Vector2(mission.target.x, mission.target.z) - Vector2(walker.global_position.x, walker.global_position.z)
		var on := d.rotated(walker.cam_yaw) * ((SIZE / 2.0) / VIEW)
		var far := on.length() > SIZE / 2.0 - 16.0
		if far:
			on = on.normalized() * (SIZE / 2.0 - 16.0)
		_top.draw_circle(c + on, 10.0 if not far else 8.0, Color(0, 0, 0, 0.7))
		_top.draw_circle(c + on, 7.5 if not far else 6.0, MISSION)
	# The gun shop: a blue blip, held on the rim while it is out of range.
	if crime and crime.shop != Vector3.INF and (crime.state == "shop" or crime.armed and crime.rounds < crime.START_ROUNDS):
		var ds := Vector2(crime.shop.x, crime.shop.z) - Vector2(walker.global_position.x, walker.global_position.z)
		var os := ds.rotated(walker.cam_yaw) * ((SIZE / 2.0) / VIEW)
		if os.length() > SIZE / 2.0 - 16.0:
			os = os.normalized() * (SIZE / 2.0 - 16.0)
		_top.draw_circle(c + os, 8.5, Color(0, 0, 0, 0.7))
		_top.draw_circle(c + os, 6.0, crime.BLUE)
	var north := c + Vector2(0, -1).rotated(walker.cam_yaw) * (SIZE / 2.0 - 14.0)
	_top.draw_circle(north, 10.0, Color("1b1e22"))
	_top.draw_string(get_theme_default_font(), north + Vector2(-5, 5), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	# Heading relative to the camera: straight up when walking away from it.
	var a: float = walker.cam_yaw - walker.heading
	var f := Vector2(0, -1).rotated(a)
	var r := f.orthogonal()
	var arrow := PackedVector2Array([c + f * 11.0, c - f * 7.0 + r * 7.5, c - f * 3.5, c - f * 7.0 - r * 7.5])
	_top.draw_colored_polygon(arrow, Color("1b1e22"))
	var inner := PackedVector2Array()
	for q in arrow:
		inner.append(c + (q - c) * 0.72)
	_top.draw_colored_polygon(inner, Color("ffffff"))
