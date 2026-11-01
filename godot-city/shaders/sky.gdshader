shader_type sky;
// The sky over Amsterdam: a gradient from the horizon up, the sun's glow (or
// at night the moon's disc, where the night light comes from), clouds
// drifting with the wind (a noise texture laid flat over the city), and
// stars on a clear night. No TIME in it: Main moves `drift` along a few
// times a second, so the sky's lighting is not redone every frame.

uniform vec3 top : source_color = vec3(0.24, 0.44, 0.68);
uniform vec3 horizon : source_color = vec3(0.66, 0.75, 0.84);
uniform vec3 ground_horizon : source_color = vec3(0.66, 0.75, 0.84);
uniform vec3 ground_bottom : source_color = vec3(0.25, 0.27, 0.3);
uniform vec4 cover_modulate : source_color = vec4(0.92, 0.93, 0.95, 0.15);
uniform sampler2D cover : repeat_enable, filter_linear_mipmap;
uniform vec2 drift = vec2(0.0);       // the wind's offset of the clouds
uniform float night = 0.0;
uniform float warm = 0.0;             // sunrise and sunset
uniform float energy = 1.0;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void sky() {
	vec3 d = EYEDIR;
	float up = clamp(d.y, 0.0, 1.0);
	vec3 col;
	if (d.y >= 0.0) {
		col = mix(horizon, top, pow(up, 0.45));
	} else {
		col = mix(ground_horizon, ground_bottom, clamp(pow(-d.y, 0.35), 0.0, 1.0));
	}
	vec3 ld = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);
	float sd = dot(d, ld);
	// The sun's glow round it (warm low down), or the moon.
	if (LIGHT0_ENABLED) {
		if (night < 0.5) {
			float glow = pow(max(sd, 0.0), 12.0) * 0.45 + pow(max(sd, 0.0), 300.0) * 2.5;
			col += LIGHT0_COLOR * glow * (1.0 + warm) * (AT_CUBEMAP_PASS ? 0.15 : 1.0);   // (seen, not lighting the city)
			if (!AT_CUBEMAP_PASS && sd > 0.99985) col += LIGHT0_COLOR * 6.0;      // the disc
		} else if (!AT_CUBEMAP_PASS) {
			float moon = smoothstep(0.99955, 0.9997, sd);
			float halo = pow(max(sd, 0.0), 120.0) * 0.25;
			col = mix(col, vec3(0.88, 0.9, 0.95) * 1.6, moon) + vec3(0.5, 0.55, 0.7) * halo * night;
		}
	}
	// Stars, a clear night's.
	if (!AT_CUBEMAP_PASS && night > 0.05 && d.y > 0.02) {
		vec3 g = floor(d * 240.0);
		float h = hash(g);
		if (h > 0.9965) {
			vec3 c = (g + 0.5) / 240.0;
			float s = smoothstep(0.0028, 0.0, length(d - normalize(c))) * (h - 0.9965) / 0.0035;
			col += vec3(0.85, 0.9, 1.0) * s * night * 1.5 * smoothstep(0.02, 0.2, d.y);
		}
	}
	// Clouds over the city, drifting; their edges catch the light.
	if (d.y > 0.0) {
		vec2 uv = d.xz / (d.y + 0.12) * 0.09 + drift;
		float c = texture(cover, uv).a;                   // (the noise's density is in its alpha)
		c = mix(c, texture(cover, uv * 2.3 + drift * 0.5).a, 0.35);
		float a = smoothstep(0.0, 0.6, c - (1.0 - cover_modulate.a) * 0.7) * min(1.0, cover_modulate.a * 2.0) * smoothstep(0.0, 0.12, d.y);
		vec3 cc = cover_modulate.rgb * mix(vec3(0.82), horizon * 1.1, 0.35 + warm * 0.4);
		cc += LIGHT0_COLOR * pow(max(sd, 0.0), 6.0) * 0.6 * (1.0 - night);   // the silver lining
		col = mix(col, cc, clamp(a, 0.0, 1.0));
	}
	COLOR = col * energy;
}
