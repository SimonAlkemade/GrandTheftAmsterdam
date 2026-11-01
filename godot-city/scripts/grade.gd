extends CanvasLayer
## The picture's last touch, over the 3D and under the HUD: a soft vignette
## always, red closing in from the edges for a moment when you are hurt, and
## a slow red pulse while your health is low. (The colour grading itself is
## the Environment's adjustments, set by the hour in Main.)
##     grade.hurt(0..1); grade.low = 0..1

const SHADER := """
shader_type canvas_item;
uniform float vignette = 0.32;
uniform float red = 0.0;
void fragment() {
	vec2 d = UV - 0.5;
	d.x *= 1.35;
	float r = length(d);
	float v = smoothstep(0.35, 0.85, r);
	float edge = smoothstep(0.25, 0.75, r);
	COLOR = vec4(mix(vec3(0.0), vec3(0.55, 0.0, 0.0), clamp(red * 2.0, 0.0, 1.0)), max(v * vignette, edge * red * 0.8));
}
"""

var low := 0.0                  # 0..1: how low your health is
var _flash := 0.0
var _mat: ShaderMaterial


func _ready() -> void:
	layer = -1                  # (over the 3D, under the HUD's layers)
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new(); sh.code = SHADER
	_mat = ShaderMaterial.new(); _mat.shader = sh
	r.material = _mat
	add_child(r)


## Hurt by `amount` (0..1 of your health): a red flash from the edges.
func hurt(amount: float) -> void:
	_flash = clampf(maxf(_flash, 0.35 + amount * 3.0), 0.0, 1.0)


func _process(delta: float) -> void:
	_flash = maxf(0.0, _flash - delta * 1.6)
	var pulse := low * (0.25 + 0.15 * sin(Time.get_ticks_msec() / 220.0))
	_mat.set_shader_parameter("red", maxf(_flash * 0.6, pulse))
