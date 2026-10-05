// Shared GoyGI sampling (globals are declared in project.godot [shader_globals]
// and written by addons/goygi/core/gi_manager.gd).
global uniform sampler3D gi_near_r : filter_linear, repeat_enable;
global uniform sampler3D gi_near_g : filter_linear, repeat_enable;
global uniform sampler3D gi_near_b : filter_linear, repeat_enable;
global uniform vec4 gi_near_inv; // xyz 1 / volume size (m), w voxel size
global uniform vec4 gi_near_min; // xyz world min, w enabled
global uniform vec4 gi_near_max; // xyz world max
// world chunk cache (static GI of the whole map, "far" in the global names)
global uniform sampler3D gi_far_r : filter_linear, repeat_disable;
global uniform sampler3D gi_far_g : filter_linear, repeat_disable;
global uniform sampler3D gi_far_b : filter_linear, repeat_disable;
global uniform vec4 gi_far_inv;
global uniform vec4 gi_far_min;
global uniform vec4 gi_far_max;
global uniform sampler2D gi_chunk_mask : filter_linear, repeat_disable; // per chunk fade-in 0..1
global uniform vec4 gi_chunk_info; // x chunk size (m), y chunks along x, z chunks along z
global uniform vec4 gi_params;   // x intensity (GI power), y debug view, z normal maps on, w fast triplanar
global uniform vec4 gi_fallback; // rgb flat light added everywhere (Ambient Contribution / GI off fallback)
global uniform sampler3D gi_age : filter_nearest, repeat_enable; // frame stamp of the last light change
global uniform vec4 gi_debug;    // x view, y current frame stamp, z hot updates, w GI on
// 0.25 m occupancy grid (solid = 1) used for detail occlusion of the indirect light
global uniform sampler3D gi_occ : filter_linear, repeat_disable;
global uniform vec4 gi_occ_origin; // xyz world origin, w strength (0 = off)
global uniform vec4 gi_occ_inv;    // xyz 1 / grid size (m), w cell size
// highest solid point of every 0.25 m column (R32F, nearest): surfaces below a
// roof ignore GI voxels above it (sky light can't leak through thin ceilings)
global uniform sampler2D gi_roof : filter_nearest, repeat_disable;
global uniform vec4 gi_roof_info;  // xy world origin (x, z), zw 1 / extent (m), 0 = off
global uniform vec4 gi_filter;     // x GI Filtering (0 fast, 1 smooth, 2 leak-proof), y sample offset (cells)

float gi_fade(vec3 p, vec3 mn, vec3 mx, float margin) {
	vec3 a = clamp((p - mn) / margin, 0.0, 1.0);
	vec3 b = clamp((mx - p) / margin, 0.0, 1.0);
	vec3 f = a * b;
	return f.x * f.y * f.z;
}

vec3 gi_eval(vec4 r, vec4 g, vec4 b, vec3 d) {
	return max(vec3(r.x + dot(r.yzw, d), g.x + dot(g.yzw, d), b.x + dot(b.yzw, d)), vec3(0.0));
}

float gi_chunk_fade(vec3 p) {
	vec2 uv = (p.xz - gi_far_min.xz) / (gi_chunk_info.x * gi_chunk_info.yz);
	return texture(gi_chunk_mask, uv).r;
}

// Occupancy (0.25 m grid, linear) at world position p: ~1 inside walls.
float gi_occ_at(vec3 p) {
	return textureLod(gi_occ, (p - gi_occ_origin.xyz) * gi_occ_inv.xyz, 0.0).r;
}

// ---- Leak guard -----------------------------------------------------------
// GoyGI 2.x/3.0 moved the sample point towards the "visible" voxels of the 8
// around the surface (an 8-iteration loop with 4-8 occupancy taps, after which
// the ±weights were folded back into the offset of ONE hardware lookup). The
// weighted offset is a DISCONTINUOUS function of the surface position: when a
// surface crosses a voxel boundary, the set of voxels that gets weight changes,
// so the offset jumps by up to one whole cell and the hardware trilinear blend
// flips between two different voxel neighbourhoods. That is what made the
// voxel grid show up on walls as hard blocks ("pure boxes"), worst of all right
// after a rebuild when the volume is still noisy.
//
// The guard below never touches the sample point. It is a plain, continuous
// weight in [0,1] that removes the indirect light a surface would otherwise
// pick up THROUGH a wall, so it can only darken smoothly - no blocks, no
// popping - and it costs 1-2 occupancy taps instead of ~40 texture fetches per
// pixel (the single biggest fragment cost on phones).
//   taps <= 0 : off (Fast)
//   taps == 1 : the midpoint between the surface and the sample (Smooth)
//   taps >= 2 : midpoint + the near-surface point (Leak-Proof: also catches
//               props and diagonal walls the single midpoint tap can miss)
float gi_leak_guard(vec3 wpos, vec3 geo_n, vec3 sp, int taps) {
	if (taps <= 0 || gi_occ_origin.w <= 0.0) {
		return 1.0;
	}
	float o = gi_occ_at(mix(wpos, sp, 0.5));
	if (taps > 1) {
		o = max(o, gi_occ_at(wpos + geo_n * gi_occ_inv.w * 0.75));
	}
	// never cut fully (0.985): the 0.25 m grid is conservative at corners, and a
	// slightly thick wall must not turn a lit surface pitch black
	return 1.0 - smoothstep(0.35, 0.85, o) * (taps > 1 ? 0.985 : 0.75);
}

// Voxels above the roof slab of a column hold outdoor sky light. Surfaces below
// it must not pick them up (that caused bright strips along the top of walls
// and glowing ceilings). Continuous in the height of the sample point, so it
// fades instead of switching between two voxel layers at once.
float gi_roof_guard(vec3 wpos, vec3 sp) {
	if (gi_roof_info.z <= 0.0) {
		return 1.0;
	}
	vec2 ruv = (sp.xz - gi_roof_info.xy) * gi_roof_info.zw;
	if (any(lessThan(ruv, vec2(0.0))) || any(greaterThan(ruv, vec2(1.0)))) {
		return 1.0;
	}
	float roof = textureLod(gi_roof, ruv, 0.0).r; // top of the highest solid 0.25 m cell
	if (wpos.y >= roof - 0.2) {
		return 1.0; // the surface itself is at or above the roof: outdoors
	}
	return 1.0 - smoothstep(roof - 0.5, roof + 0.3, sp.y);
}

// irr: irradiance / PI for the shading normal, rad: approx. radiance from the reflection dir
// near volume -> (smooth edge) -> chunk cache (per chunk fade-in) -> ambient
void gi_sample(vec3 wpos, vec3 geo_n, vec3 nrm, vec3 refl, out vec3 irr, out vec3 rad) {
	irr = vec3(0.0);
	rad = vec3(0.0);
	int mode = int(gi_filter.x + 0.5);
	float cov = 0.0;
	if (gi_near_min.w > 0.5) {
		float cell = gi_near_inv.w;
		// sample in front of the surface, then plain hardware trilinear
		vec3 sp = wpos + geo_n * cell * gi_filter.y;
		float w = gi_fade(sp, gi_near_min.xyz, gi_near_max.xyz, cell * 2.0);
		if (w > 0.0) {
			w *= gi_leak_guard(wpos, geo_n, sp, mode) * gi_roof_guard(wpos, sp);
			// toroidal volume: texel index = world cell mod size, so the
			// normalised coordinate really is world position / volume extent
			vec3 uvw = sp * gi_near_inv.xyz;
			vec4 r = texture(gi_near_r, uvw);
			vec4 g = texture(gi_near_g, uvw);
			vec4 b = texture(gi_near_b, uvw);
			irr = gi_eval(r, g, b, nrm) * w;
			rad = gi_eval(r, g, b, refl) * w;
			cov = w;
		}
	}
	if (cov < 1.0 && gi_far_min.w > 0.5) {
		float cell = gi_far_inv.w;
		vec3 sp = wpos + geo_n * cell * 0.55;
		// the cache is coarse (1 m): coverage fades towards the near volume, and
		// the same guard keeps sky-lit outside light from bleeding into rooms
		float w = gi_fade(sp, gi_far_min.xyz, gi_far_max.xyz, cell * 0.5) * gi_chunk_fade(sp) * (1.0 - cov);
		if (w > 0.0) {
			w *= gi_leak_guard(wpos, geo_n, sp, mode) * gi_roof_guard(wpos, sp);
			vec3 uvw = (sp - gi_far_min.xyz) * gi_far_inv.xyz;
			vec4 r = texture(gi_far_r, uvw);
			vec4 g = texture(gi_far_g, uvw);
			vec4 b = texture(gi_far_b, uvw);
			irr += gi_eval(r, g, b, nrm) * w;
			rad += gi_eval(r, g, b, refl) * w;
		}
	}
	// flat light: the Ambient Contribution option, plus the Environment's
	// ambient light while the GI is switched off (so a scene with the GI off
	// looks like plain Godot again)
	irr += gi_fallback.rgb;
	rad += gi_fallback.rgb;
}

float gi_grid_line(vec3 p, vec3 n, float cell) {
	vec3 f = fract(p / cell);
	vec3 e = min(f, 1.0 - f);
	vec3 an = abs(n);
	// ignore the axis the surface faces
	if (an.x > an.y && an.x > an.z) { e.x = 1.0; } else if (an.y > an.z) { e.y = 1.0; } else { e.z = 1.0; }
	float m = min(e.x, min(e.y, e.z));
	return 1.0 - smoothstep(0.015, 0.045, m);
}

vec3 gi_heat(float t) {
	// 0 = just changed (white/red) -> 1 = old (blue)
	vec3 a = mix(vec3(1.0, 0.95, 0.8), vec3(1.0, 0.35, 0.05), smoothstep(0.0, 0.3, t));
	return mix(a, vec3(0.08, 0.2, 0.6), smoothstep(0.3, 1.0, t));
}

// Debug views 2-5 (Voxels, GI Age, Chunks). Returns the emission colour.
vec3 gi_debug_color(vec3 wpos, vec3 geo_n, vec3 nrm, vec3 irr) {
	int view = int(gi_debug.x + 0.5);
	float shade = clamp(dot(irr, vec3(0.3, 0.5, 0.2)) * 4.0, 0.0, 1.0);
	bool in_near = gi_near_min.w > 0.5 && all(greaterThan(wpos, gi_near_min.xyz)) && all(lessThan(wpos, gi_near_max.xyz));
	if (view == 2) {
		if (in_near) {
			float cell = gi_near_inv.w;
			vec3 sp = wpos + geo_n * cell * 0.5;
			vec3 uvw = (floor(sp / cell) + 0.5) * cell * gi_near_inv.xyz;
			vec3 c = gi_eval(texture(gi_near_r, uvw), texture(gi_near_g, uvw), texture(gi_near_b, uvw), nrm);
			return mix(c * gi_params.x, vec3(0.9, 0.95, 1.0), gi_grid_line(sp, geo_n, cell) * 0.6);
		}
		if (gi_far_min.w > 0.5) {
			float cell = gi_far_inv.w;
			vec3 sp = wpos + geo_n * cell * 0.5;
			vec3 uvw = (floor((sp - gi_far_min.xyz) / cell) + 0.5) * cell * gi_far_inv.xyz;
			vec3 c = gi_eval(texture(gi_far_r, uvw), texture(gi_far_g, uvw), texture(gi_far_b, uvw), nrm) * gi_chunk_fade(sp);
			return mix(c * gi_params.x, vec3(0.4, 0.8, 1.0), gi_grid_line(sp - gi_far_min.xyz, geo_n, cell) * 0.5);
		}
		return irr;
	}
	if (view == 3) {
		if (!in_near) {
			return vec3(0.06) * (0.3 + shade);
		}
		float cell = gi_near_inv.w;
		vec3 sp = wpos + geo_n * cell * 0.5;
		float stamp = texture(gi_age, sp * gi_near_inv.xyz).r;
		float age = max(gi_debug.y - stamp, 0.0);
		return gi_heat(clamp(age / (gi_debug.z * 6.0), 0.0, 1.0)) * (0.35 + 0.65 * shade);
	}
	if (view == 4) {
		if (gi_far_min.w < 0.5) {
			return vec3(0.3, 0.0, 0.0);
		}
		vec2 q = (wpos.xz - gi_far_min.xz) / gi_chunk_info.x;
		vec2 id = floor(q);
		float checker = mod(id.x + id.y, 2.0);
		float m = gi_chunk_fade(wpos);
		vec3 base = mix(vec3(0.75, 0.12, 0.08), vec3(0.15, 0.8, 0.3), m);
		base *= 0.75 + 0.25 * checker;
		vec2 f = fract(q);
		float line = 1.0 - smoothstep(0.0, 0.02, min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)));
		return mix(base * (0.35 + 0.65 * shade), vec3(1.0), line * 0.8);
	}
	if (view == 5) {
		// Leak guard: what the leak/roof weights remove on this surface. Red where
		// light is cut, so walls that lose their indirect light are easy to spot.
		float cell = gi_near_min.w > 0.5 ? gi_near_inv.w : gi_far_inv.w;
		vec3 sp = wpos + geo_n * cell * gi_filter.y;
		float g = gi_leak_guard(wpos, geo_n, sp, max(int(gi_filter.x + 0.5), 1)) * gi_roof_guard(wpos, sp);
		return vec3(1.0 - g, g * 0.9, 0.1);
	}
	return irr * gi_params.x;
}

// Detail occlusion: how much of the hemisphere above the surface is blocked by
// nearby geometry (0.3 - 0.8 m), from the occupancy grid. 5 taps. Adds contact
// shadows the 0.6 m irradiance volume is too coarse for.
float gi_detail_ao(vec3 wpos, vec3 n) {
	if (gi_occ_origin.w <= 0.0) {
		return 1.0;
	}
	vec3 up = abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 t1 = normalize(cross(up, n));
	vec3 t2 = cross(n, t1);
	vec3 base = wpos - gi_occ_origin.xyz;
	float occ = 0.0;
	occ += textureLod(gi_occ, (base + n * 0.4) * gi_occ_inv.xyz, 0.0).r * 0.3;
	occ += textureLod(gi_occ, (base + n * 0.45 + t1 * 0.45) * gi_occ_inv.xyz, 0.0).r * 0.175;
	occ += textureLod(gi_occ, (base + n * 0.45 - t1 * 0.45) * gi_occ_inv.xyz, 0.0).r * 0.175;
	occ += textureLod(gi_occ, (base + n * 0.45 + t2 * 0.45) * gi_occ_inv.xyz, 0.0).r * 0.175;
	occ += textureLod(gi_occ, (base + n * 0.45 - t2 * 0.45) * gi_occ_inv.xyz, 0.0).r * 0.175;
	return 1.0 - clamp(occ * 1.25, 0.0, 0.8) * gi_occ_origin.w;
}

// Karis' analytic approximation of the split-sum environment BRDF (mobile).
vec2 gi_env_brdf(float roughness, float nv) {
	const vec4 c0 = vec4(-1.0, -0.0275, -0.572, 0.022);
	const vec4 c1 = vec4(1.0, 0.0425, 1.04, -0.04);
	vec4 r = roughness * c0 + c1;
	float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
	return vec2(-1.04, 1.04) * a004 + r.zw;
}
