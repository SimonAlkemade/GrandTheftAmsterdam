extends CanvasLayer
## The end: the credits roll up the screen over the game, then go.

const LINES := [
	"[font_size=56][b]GRAND THEFT AMSTERDAM[/b][/font_size]", "",
	"Every job done.", "",
	"[b]The city[/b]", "Amsterdam, from open data:", "3DBAG (3dbag.nl, TU Delft, CC BY 4.0)", "OpenStreetMap contributors", "Overture Maps Foundation", "",
	"[b]The engine[/b]", "Godot 4", "",
	"[b]Made with[/b]", "Claude Code", "",
	"[b]Thanks for playing[/b]", "", "Amsterdam is yours. Keep exploring.",
]
const ROLL := 22.0              # seconds

var _t := 0.0
var _text: RichTextLabel


func _ready() -> void:
	layer = 5
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_size_override("normal_font_size", 28)
	_text.add_theme_font_size_override("bold_font_size", 30)
	_text.text = "[center]" + "\n".join(LINES) + "[/center]"
	_text.set_anchors_preset(Control.PRESET_TOP_WIDE)
	add_child(_text)


func _process(delta: float) -> void:
	_t += delta
	var h := get_viewport().get_visible_rect().size.y
	_text.position.y = h - (_t / ROLL) * (h + _text.size.y + 40.0)
	(get_child(0) as ColorRect).color.a = 0.55 * clampf(minf(_t, ROLL - _t) / 1.5, 0.0, 1.0)
	if _t >= ROLL:
		queue_free()
