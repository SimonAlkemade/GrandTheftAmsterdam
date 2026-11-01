shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, shadows_disabled;
// Mist lying on the canals: a sheet of drifting noise just above the water,
// below the streets (they hide it), so it shows only in the canals. Thick at
// dawn and dusk, thin by day; `amount`, `tint` set by Main from the hour.

uniform sampler2D noise : repeat_enable, filter_linear_mipmap;
uniform float amount = 0.0;
uniform vec3 tint : source_color = vec3(0.8, 0.82, 0.86);
uniform vec2 drift = vec2(0.0);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = wpos.xz * 0.012 + drift;
	float n = texture(noise, uv).r * 0.65 + texture(noise, uv * 2.7 - drift * 1.7).r * 0.35;
	float a = smoothstep(0.35, 0.8, n) * amount;
	float near = clamp(length(VERTEX) / 6.0, 0.0, 1.0);       // (not in your face)
	ALBEDO = tint;
	ALPHA = a * near * 0.75;
}
