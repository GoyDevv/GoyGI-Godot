#[compute]
#version 450
// GoyGI display smoothing: every rendered frame the displayed near volume
// moves towards the latest GI result (exponential, frame-rate independent).
// GI updates run at 15 - 60 Hz; without this pass every update would be a
// small visible step. Voxels that just entered the moving volume are copied.
// The result is also smoothed with its 6 neighbours on the way (wall-aware:
// neighbours inside geometry or behind a wall are skipped): per-voxel noise
// and the voxel grid itself no longer show on walls and ceilings.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D res_r;
layout(set = 0, binding = 1) uniform sampler3D res_g;
layout(set = 0, binding = 2) uniform sampler3D res_b;
layout(rgba16f, set = 0, binding = 3) uniform restrict image3D disp_r;
layout(rgba16f, set = 0, binding = 4) uniform restrict image3D disp_g;
layout(rgba16f, set = 0, binding = 5) uniform restrict image3D disp_b;
layout(set = 0, binding = 6) uniform sampler3D occ_tex; // 0.25 m occupancy (lod 0)

layout(push_constant, std430) uniform Params {
	ivec4 base;      // xyz world cell of the volume, w 1 = copy everything
	ivec4 prev_base; // xyz base of the displayed data
	ivec4 size;      // xyz volume size
	vec4 k;          // x blend factor this frame, y snap threshold (relative change), z adaptive
	vec4 occ;        // xyz occupancy world origin, w occupancy cell (m)
	vec4 misc;       // x voxel size (m), y neighbour weight (0 = no smoothing)
} pc;

const ivec3 OFS[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));

float occ_at(vec3 p) {
	ivec3 i = ivec3(floor((p - pc.occ.xyz) / pc.occ.w));
	ivec3 sz = textureSize(occ_tex, 0);
	if (any(lessThan(i, ivec3(0))) || any(greaterThanEqual(i, sz))) {
		return 0.0;
	}
	return texelFetch(occ_tex, i, 0).r;
}

ivec3 imod3(ivec3 a, ivec3 b) {
	return a - b * ivec3(floor(vec3(a) / vec3(b)));
}

void main() {
	ivec3 t = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(t, pc.size.xyz))) {
		return;
	}
	ivec3 c = pc.base.xyz + imod3(t - pc.base.xyz, pc.size.xyz);
	bool valid = pc.base.w == 0 && all(greaterThanEqual(c, pc.prev_base.xyz)) && all(lessThan(c, pc.prev_base.xyz + pc.size.xyz));
	vec4 r = texelFetch(res_r, t, 0);
	vec4 g = texelFetch(res_g, t, 0);
	vec4 b = texelFetch(res_b, t, 0);
	float dw = pc.misc.y;
	if (dw > 0.0) {
		float vox = pc.misc.x;
		vec3 x = (vec3(c) + 0.5) * vox;
		if (occ_at(x) < 0.5) {
			vec4 ar = r, ag = g, ab = b;
			float sw = 1.0;
			for (int k = 0; k < 6; k++) {
				ivec3 cn = c + OFS[k];
				if (any(lessThan(cn, pc.base.xyz)) || any(greaterThanEqual(cn, pc.base.xyz + pc.size.xyz))) {
					continue;
				}
				vec3 xn = (vec3(cn) + 0.5) * vox;
				if (occ_at(xn) > 0.5 || occ_at(mix(x, xn, 0.5)) > 0.5) {
					continue;
				}
				ivec3 tn = imod3(cn, pc.size.xyz);
				ar += texelFetch(res_r, tn, 0) * dw;
				ag += texelFetch(res_g, tn, 0) * dw;
				ab += texelFetch(res_b, tn, 0) * dw;
				sw += dw;
			}
			r = ar / sw;
			g = ag / sw;
			b = ab / sw;
		}
	}
	if (valid) {
		vec4 dr = imageLoad(disp_r, t);
		vec4 dg = imageLoad(disp_g, t);
		vec4 db = imageLoad(disp_b, t);
		float a = pc.k.x;
		// big jumps (light switched on / off) still go fast, small ones glide
		float lo = dr.x + dg.x + db.x;
		float hi = r.x + g.x + b.x;
		float rel = abs(hi - lo) / (max(hi, lo) + 0.002);
		a = mix(a, max(a, 0.5), smoothstep(pc.k.y, 1.0, rel) * pc.k.z);
		r = mix(dr, r, a);
		g = mix(dg, g, a);
		b = mix(db, b, a);
	}
	imageStore(disp_r, t, r);
	imageStore(disp_g, t, g);
	imageStore(disp_b, t, b);
}
