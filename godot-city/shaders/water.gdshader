shader_type spatial;
// Canal water: slow ripples moving over it, the sky mirrored in it at a
// glancing angle (Fresnel), the sun glinting off it, and rain rings when it
// rains. Cheap enough for the browser's renderer: a few sines, no textures.
// Materials sets `sky`, `night` and `rain` from the clock and the weather.

uniform vec3 deep : source_color = vec3(0.06, 0.13, 0.14);
uniform vec3 sky : source_color = vec3(0.66, 0.75, 0.84);
uniform float night = 0.0;
uniform float rain = 0.0;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float waves(vec2 p, float t) {
	return sin(p.x * 0.55 + p.y * 0.21 + t * 0.9) * 0.5
		+ sin(p.y * 0.8 - p.x * 0.33 - t * 0.7) * 0.4
		+ sin((p.x + p.y) * 1.7 + t * 1.6) * 0.22
		+ sin((p.x - p.y * 0.6) * 3.9 - t * 2.2) * 0.1;
}

// Rain: rings spreading out from drops, one in each half-metre cell.
float rings(vec2 p, float t) {
	vec2 c = floor(p * 1.6);
	vec2 f = fract(p * 1.6) - 0.5;
	float h = fract(sin(dot(c, vec2(12.9898, 78.233))) * 43758.5453);
	float age = fract(t * 0.9 + h);
	float r = length(f - (vec2(h, fract(h * 7.31)) - 0.5) * 0.4);
	return sin((r - age * 0.45) * 60.0) * smoothstep(0.08, 0.0, abs(r - age * 0.45)) * (1.0 - age);
}

void fragment() {
	vec2 p = wpos.xz;
	float t = TIME;
	float far = clamp(1.0 - length(VERTEX) / 180.0, 0.0, 1.0);    // (calm far off: no shimmer)
	float e = 0.2;
	float dx = waves(p + vec2(e, 0.0), t) - waves(p - vec2(e, 0.0), t);
	float dz = waves(p + vec2(0.0, e), t) - waves(p - vec2(0.0, e), t);
	if (rain > 0.01) {
		dx += (rings(p + vec2(0.03, 0.0), t) - rings(p - vec2(0.03, 0.0), t)) * rain * 0.6;
		dz += (rings(p + vec2(0.0, 0.03), t) - rings(p - vec2(0.0, 0.03), t)) * rain * 0.6;
	}
	vec3 n = normalize(vec3(-dx * 0.22 * far, 1.0, -dz * 0.22 * far));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = deep * (1.0 - night * 0.6);
	EMISSION = sky * fres * 0.45 * (1.0 - night * 0.75);
	ROUGHNESS = 0.06 + rain * 0.2;
	SPECULAR = 0.65;
	METALLIC = 0.0;
}
