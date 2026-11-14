extends CanvasLayer
## Getting off a tram or bus at a stop. Riding one as a passenger, a list of
## well-known stops shows (nearest first, the one you are at left out, keys
## 1-9); a number fades the screen to black, takes you off, puts you down at
## that stop once the streets round it have loaded, and fades back in. (Trams
## and buses here have no fixed routes: they choose at every junction. These
## are the places they go to.)

## [stop, its street, x, y]: data decimetres, a point on that street in the city data.
const STOPS := [
	["Centraal Station", "Stationsplein", 1829, 5075],
	["Dam", "Dam", -1914, -1032],
	["Leidseplein", "Leidseplein", -9121, -11591],
	["Rembrandtplein", "Rembrandtplein", 355, -9540],
	["Museumplein", "Museumplein", -8627, -19200],
	["Waterlooplein", "Waterlooplein", 3403, -7500],
	["De Pijp", "Albert Cuypstraat", -1531, -20964],
	["Vondelpark", "Overtoom", -15358, -14198],
	["Artis", "Plantage Middenlaan", 11262, -8831],
	["Westerkerk", "Westermarkt", -7543, 542],
]
const NEAR := 300.0            # metres: a stop this close is where you are
const SHOWN := 9               # keys 1-9
const FADE := 0.35             # seconds to black, and back
const WAIT_MAX := 4.0          # seconds at most for the streets round the stop to load

var walker
var streamer
var stops: Array = []          # [name, Vector2 scene metres]
var busy := false              # fading or moving
var _panel: PanelContainer
var _list: Label
var _black: ColorRect
var _banner: Label
var _t := 0.0


func setup(w, s) -> void:
	walker = w
	streamer = s
	stops.clear()
	for st in STOPS:
		var p := Vector2(float(st[2]) / 10.0, -float(st[3]) / 10.0)
		if s != null and s.has_method("compact_point"):
			p = s.compact_point(p)
		stops.append([st[0], p])
	layer = 20
	_build()


func _build() -> void:
	_panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.09, 0.82)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 16; sb.content_margin_right = 16; sb.content_margin_top = 12; sb.content_margin_bottom = 12
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.anchor_left = 1.0; _panel.anchor_right = 1.0; _panel.anchor_top = 0.5; _panel.anchor_bottom = 0.5
	_panel.offset_left = -300; _panel.offset_right = -18; _panel.offset_top = -150; _panel.offset_bottom = 150
	_list = Label.new()
	_list.add_theme_font_size_override("font_size", 17)
	_panel.add_child(_list)
	_panel.visible = false
	add_child(_panel)
	_black = ColorRect.new()
	_black.color = Color(0, 0, 0, 0)
	_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_black)
	_banner = Label.new()
	_banner.add_theme_font_size_override("font_size", 40)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 10)
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner.grow_vertical = Control.GROW_DIRECTION_BOTH
	_banner.modulate.a = 0.0
	add_child(_banner)


## Whether you ride a tram or bus as a passenger.
func riding() -> bool:
	var v = walker.vehicle if walker != null else null
	return v != null and (v.kind == "tram" or v.kind == "bus") and v.get("rider", false) \
		and not v.get("driven", false) and not v.get("driver", false)


## The stops worth going to from `here` (scene metres): [name, position, metres], nearest first.
func stops_from(here: Vector2) -> Array:
	var out := []
	for st in stops:
		var d: float = (st[1] as Vector2).distance_to(here)
		if d > NEAR:
			out.append([st[0], st[1], d])
	out.sort_custom(func(a, b): return a[2] < b[2])
	return out.slice(0, SHOWN)


func panel_shown() -> bool:
	return _panel.visible


func panel_text() -> String:
	return _list.text


func black_alpha() -> float:
	return _black.color.a


func _process(delta: float) -> void:
	var show := riding() and not busy
	_panel.visible = show
	_t -= delta
	if show and _t <= 0.0:
		_t = 0.5
		var here := Vector2(walker.global_position.x, walker.global_position.z)
		var lines := ["Get off at:"]
		var k := 1
		for st in stops_from(here):
			var d: float = st[2]
			lines.append("%d  %s  ·  %s" % [k, st[0], ("%.1f km" % (d / 1000.0)) if d >= 1000.0 else ("%d m" % int(d))])
			k += 1
		lines.append("E  get off here")
		_list.text = "\n".join(lines)
	if not show:
		_t = 0.0


## Key `k` (0 for 1) while riding: to that stop. Whether it did anything.
func pick(k: int) -> bool:
	if busy or not riding():
		return false
	var l := stops_from(Vector2(walker.global_position.x, walker.global_position.z))
	if k < 0 or k >= l.size():
		return false
	ride_to(l[k][0], l[k][1])
	return true


## Fade to black, off the vehicle, to `at` (scene metres), wait for the streets there, fade back in.
func ride_to(name: String, at: Vector2) -> void:
	busy = true
	await _fade(1.0)
	walker._get_out()
	walker.global_position = Vector3(at.x, 0.0, at.y)
	walker.velocity = Vector3.ZERO
	walker.speed = 0.0
	var waited := 0.0
	while waited < WAIT_MAX:
		await get_tree().process_frame
		waited += get_process_delta_time()
		if streamer == null or not streamer.has_method("stats") or int(streamer.stats().get("loading", 0)) == 0:
			if waited > 0.2:
				break
	walker.global_position = _clear_spot(Vector3(at.x, 0.0, at.y))
	walker.vy = 0.0
	walker.grounded = true
	walker.state = "idle"
	_banner.text = name.to_upper()
	_banner.modulate.a = 1.0
	await _fade(0.0)
	busy = false
	var tw := create_tween()
	tw.tween_interval(1.2)
	tw.tween_property(_banner, "modulate:a", 0.0, 0.6)


func _fade(to: float) -> void:
	var tw := create_tween()
	tw.tween_property(_black, "color:a", to, FADE)
	await tw.finished


# The stop's point, or the nearest clear spot round it (not in a wall, not in a canal).
func _clear_spot(p: Vector3) -> Vector3:
	if walker._free(p):
		return p
	for r in [1.5, 3.0, 5.0, 8.0, 12.0]:
		for k in 12:
			var q: Vector3 = p + Vector3(cos(k * TAU / 12.0), 0, sin(k * TAU / 12.0)) * float(r)
			if walker._free(q):
				return q
	return p
