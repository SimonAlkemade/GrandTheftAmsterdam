extends Control
## Mission 2 on screen: the wanted level as five stars at the top left (white
## and lit while the police are after you, flashing while they cannot see you),
## and a crosshair in the middle while you hold the pistol.

const STAR := 15.0              # outer radius, px
const GAP := 38.0

var crime
var walker


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


func _draw() -> void:
	if crime == null or crime.state == "off" or walker == null or not walker.active:
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
