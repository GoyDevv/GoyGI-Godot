#[compute]
#version 450
// GoyGI light meter (eye adaptation). 64 view rays in front of the camera are
// marched through the occupancy grid; at the first surface the light leaving
// it is estimated from the GI (direct light cache + near irradiance volume) and
// the albedo grid. Writes the average luminance and the fraction of rays that
// see the sky. Cheap: one 64-thread workgroup, read back asynchronously.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler3D occ_tex;
layout(set = 0, binding = 1) uniform sampler3D near_r;
layout(set = 0, binding = 2) uniform sampler3D near_g;
layout(set = 0, binding = 3) uniform sampler3D near_b;
layout(set = 0, binding = 4) uniform sampler3D dir_r;
layout(set = 0, binding = 5) uniform sampler3D dir_g;
layout(set = 0, binding = 6) uniform sampler3D dir_b;
layout(set = 0, binding = 7) uniform sampler3D alb_tex;
layout(set = 0, binding = 8, std430) restrict writeonly buffer OutBuf {
	vec4 result; // x mean luminance of the seen surfaces, y sky fraction, z mean log2 luminance, w hits
} outb;

layout(push_constant, std430) uniform Params {
	vec4 cam;   // xyz camera position, w ray length
	vec4 fwd;   // xyz forward, w tan(half fov x)
	vec4 up;    // xyz up, w tan(half fov y)
	ivec4 nbase; // near volume first world cell, w 1 = near valid
	ivec4 nsize; // near volume size, w 1 = direct cache valid
	vec4 occ;   // xyz occupancy (and direct cache) origin, w occupancy cell
	vec4 dext;  // xyz direct cache extent (m), w near voxel size
	vec4 gain;  // x static bounce gain (direct cache), y GI power, zw -
} pc;

shared vec4 s_acc[64];

float occ_at(vec3 p, int lod) {
	float cs = pc.occ.w * float(1 << lod);
	ivec3 i = ivec3(floor((p - pc.occ.xyz) / cs));
	ivec3 sz = textureSize(occ_tex, lod);
	if (any(lessThan(i, ivec3(0))) || any(greaterThanEqual(i, sz))) {
		return 0.0;
	}
	return texelFetch(occ_tex, i, lod).r;
}

float cell_exit(vec3 p, vec3 d, float cs) {
	vec3 rel = (p - pc.occ.xyz) / cs;
	vec3 bound = (floor(rel) + step(0.0, d)) * cs + pc.occ.xyz;
	vec3 ds = mix(vec3(1e-6), d, greaterThan(abs(d), vec3(1e-6)));
	vec3 tt = (bound - p) / ds;
	return max(min(tt.x, min(tt.y, tt.z)), 0.0) + 1e-3;
}

float march(vec3 a, vec3 d, float t_end) {
	float c0 = pc.occ.w;
	float t = 0.05;
	for (int i = 0; i < 160; i++) {
		if (t >= t_end) {
			return -1.0;
		}
		vec3 p = a + d * t;
		if (occ_at(p, 2) < 0.5) {
			t += cell_exit(p, d, c0 * 4.0);
			continue;
		}
		if (occ_at(p, 1) < 0.5) {
			t += cell_exit(p, d, c0 * 2.0);
			continue;
		}
		if (occ_at(p, 0) > 0.5) {
			return t;
		}
		t += max(cell_exit(p, d, c0), c0 * 0.5);
	}
	return -1.0;
}

vec3 sh_eval(vec4 r, vec4 g, vec4 b, vec3 n) {
	return max(vec3(r.x + dot(r.yzw, n), g.x + dot(g.yzw, n), b.x + dot(b.yzw, n)), vec3(0.0));
}

void main() {
	uint i = gl_LocalInvocationIndex;
	// 8 x 8 grid over the central 80 % of the view
	float u = ((float(i % 8u) + 0.5) / 8.0 * 2.0 - 1.0) * 0.8;
	float v = ((float(i / 8u) + 0.5) / 8.0 * 2.0 - 1.0) * 0.8;
	vec3 f = normalize(pc.fwd.xyz);
	vec3 up = normalize(pc.up.xyz);
	vec3 right = normalize(cross(f, up));
	vec3 d = normalize(f + right * (u * pc.fwd.w) + up * (v * pc.up.w));
	float th = march(pc.cam.xyz, d, pc.cam.w);
	vec4 acc = vec4(0.0);
	if (th < 0.0) {
		acc.y = 1.0; // sky or far away (the CPU adds the sky brightness)
	} else {
		vec3 hp = pc.cam.xyz + d * th;
		// surface normal: the open face of the hit cell on the side we came from
		float c0 = pc.occ.w;
		vec3 hc = pc.occ.xyz + (floor((hp - pc.occ.xyz) / c0) + 0.5) * c0;
		vec3 n = -d;
		float best = 0.0;
		for (int k = 0; k < 3; k++) {
			float dk = d[k];
			if (abs(dk) < 0.05 || abs(dk) <= best) {
				continue;
			}
			vec3 e = vec3(float(k == 0), float(k == 1), float(k == 2)) * -sign(dk);
			if (occ_at(hc + e * c0, 0) < 0.5) {
				n = e;
				best = abs(dk);
			}
		}
		vec3 face = best > 0.0 ? hp + n * (dot(hc - hp, n) + c0 * 0.5) : hp - d * 0.05;
		vec3 e = vec3(0.0);
		vec3 alb = vec3(0.5);
		if (pc.nsize.w > 0) {
			vec3 uvw = (face + n * 0.25 - pc.occ.xyz) / pc.dext.xyz;
			e += sh_eval(textureLod(dir_r, uvw, 0.0), textureLod(dir_g, uvw, 0.0), textureLod(dir_b, uvw, 0.0), n);
			vec4 a = textureLod(alb_tex, (face - n * 0.1 - pc.occ.xyz) / pc.dext.xyz, 0.0);
			alb = a.a > 0.02 ? a.rgb / a.a : vec3(0.5);
		}
		if (pc.nbase.w > 0) {
			float cell = pc.dext.w;
			vec3 sp = face + n * cell * 0.6;
			vec3 cp = sp / cell;
			if (all(greaterThanEqual(cp, vec3(pc.nbase.xyz) + 0.5)) && all(lessThanEqual(cp, vec3(pc.nbase.xyz + pc.nsize.xyz) - 0.5))) {
				vec3 uvw = cp / vec3(pc.nsize.xyz);
				e += sh_eval(textureLod(near_r, uvw, 0.0), textureLod(near_g, uvw, 0.0), textureLod(near_b, uvw, 0.0), n) * pc.gain.y;
			}
		}
		vec3 l = alb * e;
		float lum = dot(l, vec3(0.2126, 0.7152, 0.0722));
		acc = vec4(lum, 0.0, log2(max(lum, 1e-5)), 1.0);
	}
	s_acc[i] = acc;
	barrier();
	for (uint s = 32u; s > 0u; s >>= 1u) {
		if (i < s) {
			s_acc[i] += s_acc[i + s];
		}
		barrier();
	}
	if (i == 0u) {
		vec4 t = s_acc[0];
		float hits = max(t.w, 1.0);
		outb.result = vec4(t.x / hits, t.y / 64.0, t.z / hits, t.w);
	}
}
