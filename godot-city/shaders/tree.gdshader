shader_type spatial;
// A tree's crown, swaying in the wind: each tree on its own beat (from where
// it stands), the top moving most, a quicker flutter of the leaves over the
// slow sway. `wind` 0..1 (Weather: a breeze, a gale in the rain). The colour
// is the instance's (the MultiMesh gives each tree its own green).

uniform float wind = 0.3;
uniform float roughness_v = 0.9;

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;                     // where this tree stands
	float phase = base.x * 0.13 + base.z * 0.17;
	float up = clamp((VERTEX.y + 4.8) / 9.6, 0.0, 1.0);  // 0 at the crown's foot, 1 at its top
	float sway = sin(TIME * 0.9 + phase) * 0.6 + sin(TIME * 1.7 + phase * 1.3) * 0.25;
	float flutter = sin(TIME * 6.0 + VERTEX.x * 2.1 + VERTEX.z * 1.7 + phase) * 0.06;
	float a = (0.12 + wind * 0.55) * up * up;
	VERTEX.x += (sway * a + flutter * wind) ;
	VERTEX.z += (sway * a * 0.45 + flutter * wind * 0.7);
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = roughness_v;
}
