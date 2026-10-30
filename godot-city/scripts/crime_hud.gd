extends Control
## Mission 2 on screen: the wanted level as five stars at the top left (white
## and lit while the police are after you, flashing while they cannot see you),
## and a crosshair in the middle while you hold the pistol; your health as a
## bar beside the stars (green, red when low, flashing as it is taken); the
## screen flickering blue while a taser has you down.

const STAR := 15.0              # outer radius, px
const GAP := 38.0

var crime
var walker
var juice


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_dt: float) -> void:
	queue_redraw()


func _star(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 10:
		var a := -PI / 2.0 + k * PI / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * (r if k % 2 == 0 else r * 0.45))
	return pts


var _shown := 100.0             # the health the bar shows, catching up with the real one


func _health_bar() -> void:
	var h: float = walker.health / walker.MAX_HEALTH
	_shown = lerpf(_shown, walker.health, 0.08) if absf(_shown - walker.health) > 0.5 else walker.health
	var r := Rect2(Vector2(32 + 4 * GAP + STAR + 38, 22), Vector2(170, 16))   # right of the stars, a cross before it
	draw_rect(r.grow(3.0), Color(0, 0, 0, 0.75))
	draw_rect(r, Color(0.25, 0.08, 0.08, 0.9))
	var lost := r; lost.size.x *= _shown / walker.MAX_HEALTH
	draw_rect(lost, Color(1, 1, 1, 0.85))                     # what was just taken, fading
	var left := r; left.size.x *= h
	var low := h < 0.3 and fmod(Time.get_ticks_msec() / 1000.0, 0.5) < 0.25
	draw_rect(left, Color(0.9, 0.15, 0.15) if h < 0.3 and not low else (Color(0.95, 0.45, 0.45) if low else Color(0.25, 0.8, 0.3)))
	# a cross, for health
	var c := r.position + Vector2(-14, r.size.y / 2.0)
	draw_rect(Rect2(c - Vector2(6, 2), Vector2(12, 4)), Color.WHITE)
	draw_rect(Rect2(c - Vector2(2, 6), Vector2(4, 12)), Color.WHITE)


func _draw() -> void:
	if walker == null or not walker.active:
		return
	if walker.stun > 0.0:                    # tasered or run over: the world flickers
		var a := 0.12 + 0.1 * sin(Time.get_ticks_msec() / 40.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.6, 0.8, 1.0, a))
	_health_bar()
	if crime == null or crime.state == "off":
		return
	var blink: bool = not crime.seen and fmod(Time.get_ticks_msec() / 1000.0, 0.6) < 0.3
	for k in 5:
		var c := Vector2(32 + k * GAP, 30)
		var lit: bool = k < crime.stars and not blink
		draw_colored_polygon(_star(c, STAR + 2.5), Color(0, 0, 0, 0.75))
		draw_colored_polygon(_star(c, STAR), Color(1, 1, 1) if lit else Color(1, 1, 1, 0.18))
	if crime.armed and walker.vehicle == null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var m := size / 2.0
		for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			draw_line(m + d * 5.0, m + d * 13.0, Color(0, 0, 0, 0.7), 4.0)
			draw_line(m + d * 5.0, m + d * 13.0, Color(1, 1, 1, 0.95), 2.0)
		draw_circle(m, 1.6, Color(1, 1, 1, 0.95))
		if juice and juice.hitmarker_visual and juice.hit_t > 0.0:     # a hit: four short ticks round the middle
			for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
				draw_line(m + d * 7.0, m + d * 14.0, Color(0, 0, 0, 0.7), 4.0)
				draw_line(m + d * 7.0, m + d * 14.0, Color(1, 1, 1), 2.0)
