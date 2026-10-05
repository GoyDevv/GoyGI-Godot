#[compute]
#version 450
// GoyGI direct-light cache (world space, L1 SH irradiance / PI, 0.5 m texels).
//
// Holds the DIRECT light of every static lamp and of the sun, shadowed through
// the occupancy grid. The irradiance volume never loops over static lights:
// its rays read this cache where they hit a surface, so a lit corridor, a sun
// patch or a lamp in the next room bounces into a room through every door and
// window the rays find - for any number of lights at the same cost.
// Recomputed only where lighting changed (light switched / moved, sun moved),
// one box per dispatch.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D occ_tex;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image3D out_r;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D out_g;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D out_b;
layout(set = 0, binding = 4, std430) restrict readonly buffer LightBuffer {
	// 4 x vec4 per light: pos + range, colour * energy (rgb) + decay,
	// spot axis (xyz, 0 = omni) + cos(cutoff), w0: spot angle attenuation
	vec4 data[];
} lights;

layout(push_constant, std430) uniform Params {
	ivec4 region;     // xyz first texel of the box, w light count
	ivec4 rsize;      // xyz box size in texels, w max march steps
	vec4 origin;      // xyz world position of texel 0's corner, w texel size (m)
	vec4 occ_origin;  // xyz occupancy origin, w occupancy cell (m)
	vec4 sun_dir;     // xyz towards the sun, w 1 = sun on
	vec4 sun_col;     // rgb sun irradiance / PI, w ray length to leave the map
} pc;

#define PI 3.14159265359

float occ_at(vec3 p, int lod) {
	float cs = pc.occ_origin.w * float(1 << lod);
	ivec3 i = ivec3(floor((p - pc.occ_origin.xyz) / cs));
	ivec3 sz = textureSize(occ_tex, lod);
	if (any(lessThan(i, ivec3(0))) || any(greaterThanEqual(i, sz))) {
		return 0.0;
	}
	return texelFetch(occ_tex, i, lod).r;
}

float cell_exit(vec3 p, vec3 d, float cs) {
	vec3 rel = (p - pc.occ_origin.xyz) / cs;
	vec3 bound = (floor(rel) + step(0.0, d)) * cs + pc.occ_origin.xyz;
	vec3 ds = mix(vec3(1e-6), d, greaterThan(abs(d), vec3(1e-6)));
	vec3 tt = (bound - p) / ds;
	return max(min(tt.x, min(tt.y, tt.z)), 0.0) + 1e-3;
}

// true if nothing solid lies between t and t_end (hierarchical skip as in gi_volume)
bool clear_path(vec3 a, vec3 d, float t, float t_end) {
	float c0 = pc.occ_origin.w;
	int steps = pc.rsize.w;
	for (int i = 0; i < 400; i++) {
		if (t >= t_end) {
			return true;
		}
		if (i >= steps) {
			return false;
		}
		vec3 p = a + d * t;
		vec3 g = (p - pc.occ_origin.xyz) / c0;
		if (any(lessThan(g, vec3(0.0))) || any(greaterThanEqual(g, vec3(textureSize(occ_tex, 0))))) {
			return true; // left the map: nothing more can block it
		}
		if (occ_at(p, 2) < 0.5) {
			t += cell_exit(p, d, c0 * 4.0);
			continue;
		}
		if (occ_at(p, 1) < 0.5) {
			t += cell_exit(p, d, c0 * 2.0);
			continue;
		}
		if (occ_at(p, 0) > 0.5) {
			return false;
		}
		t += max(cell_exit(p, d, c0), c0 * 0.5);
	}
	return false;
}

const vec3 PROBE[6] = vec3[6](vec3(0, 1, 0), vec3(0, -1, 0), vec3(1, 0, 0), vec3(-1, 0, 0), vec3(0, 0, 1), vec3(0, 0, -1));

void main() {
	ivec3 lt = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(lt, pc.rsize.xyz))) {
		return;
	}
	ivec3 t = pc.region.xyz + lt;
	if (any(greaterThanEqual(t, imageSize(out_r))) || any(lessThan(t, ivec3(0)))) {
		return;
	}
	float cs = pc.origin.w;
	vec3 x = pc.origin.xyz + (vec3(t) + 0.5) * cs;
	float tol = 0.0;
	// texel centre inside geometry: evaluate at the nearest open point instead
	if (occ_at(x, 0) > 0.5) {
		bool found = false;
		for (int k = 0; k < 6; k++) {
			vec3 q = x + PROBE[k] * cs * 0.45;
			if (occ_at(q, 0) < 0.5) {
				x = q;
				found = true;
				break;
			}
		}
		if (!found) {
			imageStore(out_r, t, vec4(0.0));
			imageStore(out_g, t, vec4(0.0));
			imageStore(out_b, t, vec4(0.0));
			return;
		}
	}
	tol = pc.occ_origin.w * 0.6;
	vec3 l0 = vec3(0.0), l1r = vec3(0.0), l1g = vec3(0.0), l1b = vec3(0.0);
	int n = pc.region.w;
	for (int i = 0; i < 1024; i++) {
		if (i >= n) {
			break;
		}
		vec4 p = lights.data[i * 4 + 0];
		vec3 dv = p.xyz - x;
		float r2 = dot(dv, dv);
		if (r2 >= p.w * p.w) {
			continue;
		}
		vec4 col = lights.data[i * 4 + 1];
		vec4 sp = lights.data[i * 4 + 2];
		float r = sqrt(r2);
		vec3 w = dv / max(r, 1e-4);
		float spot = 1.0;
		if (dot(sp.xyz, sp.xyz) > 0.5) {
			float c = dot(-w, sp.xyz);
			if (c <= sp.w) {
				continue;
			}
			float rim = max(1e-4, (1.0 - c) / (1.0 - sp.w));
			spot = max(1.0 - pow(rim, lights.data[i * 4 + 3].x), 0.0);
		}
		// Godot's light falloff; distance clamped (no fireflies next to the bulb)
		float nd = r / p.w;
		nd *= nd;
		nd *= nd;
		float win = max(1.0 - nd, 0.0);
		win *= win;
		float att = win * pow(max(r, 0.4), -col.w) * spot;
		if (att <= 1e-5) {
			continue;
		}
		if (!clear_path(x, w, tol, r - 0.3)) {
			continue;
		}
		vec3 kk = col.rgb * att;
		l0 += 0.25 * kk;
		l1r += 0.5 * kk.r * w;
		l1g += 0.5 * kk.g * w;
		l1b += 0.5 * kk.b * w;
	}
	if (pc.sun_dir.w > 0.5 && clear_path(x, pc.sun_dir.xyz, tol, pc.sun_col.w)) {
		vec3 kk = pc.sun_col.rgb;
		vec3 w = pc.sun_dir.xyz;
		l0 += 0.25 * kk;
		l1r += 0.5 * kk.r * w;
		l1g += 0.5 * kk.g * w;
		l1b += 0.5 * kk.b * w;
	}
	imageStore(out_r, t, vec4(l0.r, l1r));
	imageStore(out_g, t, vec4(l0.g, l1g));
	imageStore(out_b, t, vec4(l0.b, l1b));
}
