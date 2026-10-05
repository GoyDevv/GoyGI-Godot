#[compute]
#version 450
// GoyGI - real-time irradiance volume for the Mobile renderer (Vulkan 1.1).
//
// One shader, two modes:
//  * NEAR mode: camera-centred toroidal volume (fine cells). Every voxel stores
//      total = slow + fast   (L1 SH irradiance / PI, 3 RGBA16F textures)
//      fast  = direct bounce of DYNAMIC lights (torch, moving lights)
//      slow  = sky light + multi-bounce + STATIC lights (lamps, sun)
//    Work per update (keeps the cost flat, no visible update "waves"):
//      - hot voxels (light changed there recently) and new voxels: full update
//      - voxels inside a dynamic light's update region: fast part every update
//      - everything else: full update only in its slice (1 / slices updates),
//        otherwise the cached result is kept as is.
//  * CACHE mode (flag 16): world-space chunk cache covering the whole map at a
//    coarser resolution. Only the chunks scheduled by the CPU are dispatched
//    (prev_base.xyz = chunk texel offset). Holds static lighting; the near volume
//    falls back to it at its edges, uses it for multi-bounce beyond its bounds
//    and initialises newly covered voxels from it (no black pop when moving).
//
// Sky light: jittered rays through the static 0.25 m occupancy grid.
// Static bounce light (every lamp + the sun): the same rays read the direct
// light cache (gi_direct.glsl, bindings 19-21) and the albedo grid (22) where
// they hit a surface: radiance = albedo * (direct + indirect). Any lit surface
// a voxel can see through a door or window lights it, for any number of lamps
// at a fixed cost. Rays that run out of length under a roof (long corridors)
// read the same estimate at their end point instead of counting as sky.
// Dynamic lights (torch, moving lamps): Virtual Point Lights found by CPU ray
// casts (binding 7), visibility ray-marched through the occupancy grid.
// Ray marching skips empty space with the coarse occupancy mips and only
// tests the 0.25 m level next to geometry (exact through doors / windows).

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D prev_r;
layout(set = 0, binding = 1) uniform sampler3D prev_g;
layout(set = 0, binding = 2) uniform sampler3D prev_b;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D out_r;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image3D out_g;
layout(rgba16f, set = 0, binding = 5) uniform restrict writeonly image3D out_b;
layout(set = 0, binding = 6) uniform sampler3D occ_tex;
layout(set = 0, binding = 7, std430) restrict readonly buffer VPLBuffer {
	vec4 data[]; // 4 x vec4 per VPL: pos+area, flux+cutoff^2, normal+dynamic, albedo
} vpl;
layout(set = 0, binding = 8) uniform sampler3D prev_vr;
layout(set = 0, binding = 9) uniform sampler3D prev_vg;
layout(set = 0, binding = 10) uniform sampler3D prev_vb;
layout(rgba16f, set = 0, binding = 11) uniform restrict writeonly image3D out_vr;
layout(rgba16f, set = 0, binding = 12) uniform restrict writeonly image3D out_vg;
layout(rgba16f, set = 0, binding = 13) uniform restrict writeonly image3D out_vb;
layout(set = 0, binding = 14, std430) restrict buffer ParamBuffer {
	ivec4 cache_base;  // xyz world cell of cache texel 0, w 1 = cache valid
	ivec4 cache_size;  // xyz cache size in cells
	vec4 cache_cell;   // x cache cell (m), y slices for cold voxels, z hot updates, w unused
	vec4 tune;         // x response lo, y response hi, z fast blend max, w slow blend max
	vec4 tune2;        // x denoise weight, y noise tolerance, z frame stamp, w region count
	vec4 regions[8];   // dynamic update regions: min, max pairs (world m)
	uint counters[4];  // 0 full voxel updates, 1 fast-only updates, 2 cache cells, 3 VPLs kept
	ivec4 pool_info;   // x first cluster (VPL index), y cluster count, z buckets x, w buckets z
	vec4 pool_grid;    // xy bucket grid origin (x, z), z bucket size, w split distance (fine VPLs inside)
	vec4 pool_misc;    // x VPLs per workgroup, y -, z static bounce strength, w -
	vec4 dir_origin;   // xyz world origin of the direct cache / albedo grid, w 1 = valid
	vec4 dir_extent;   // xyz size of that grid (m), w roof margin (m)
	vec4 sreg[8];      // light-change boxes (min, max): full update + fast blend
	vec4 sreg_info;    // x box count, y slow blend inside, z -, w -
} prm;
layout(set = 0, binding = 15) uniform sampler3D cache_r;
layout(set = 0, binding = 16) uniform sampler3D cache_g;
layout(set = 0, binding = 17) uniform sampler3D cache_b;
// frame stamp of the last significant light change per voxel (GI Age view, hot voxels)
layout(r32f, set = 0, binding = 18) uniform restrict image3D age_img;
layout(set = 0, binding = 19) uniform sampler3D dir_r; // direct light of static lamps + sun (L1 SH / PI)
layout(set = 0, binding = 20) uniform sampler3D dir_g;
layout(set = 0, binding = 21) uniform sampler3D dir_b;
layout(set = 0, binding = 22) uniform sampler3D alb_tex; // albedo * coverage (premultiplied), 0.5 m
layout(set = 0, binding = 23) uniform sampler2D roof_tex; // r: highest solid y of the column (m)

layout(push_constant, std430) uniform Params {
	ivec4 base;       // xyz first world cell of the volume, w = VPL count
	ivec4 prev_base;  // near: xyz previous base / cache: chunk texel offset; w = flags
	ivec4 size;       // xyz volume size in cells, w = current slice
	ivec4 misc;       // x slices (cache: VPL offset), y sky rays, z frame counter, w max march steps
	vec4 cell;        // x voxel size (m), y occupancy cell (m), z sky ray length, w blend of the slow part
	vec4 occ_origin;  // xyz occupancy world origin, w blend of the fast part
	vec4 sky_top;     // rgb zenith radiance, w ground radiance factor
	vec4 sky_horizon; // rgb horizon radiance, w average surface albedo for multi-bounce (0 = off)
} pc;

// flags
#define F_RESET 1
#define F_MULTI 2
#define F_DENOISE 4
#define F_ADAPTIVE 8
#define F_CACHE 16

#define PI 3.14159265359
#define MAXV 256

shared vec4 s_pos[MAXV];
shared vec4 s_flux[MAXV];
shared vec4 s_nrm[MAXV]; // w: 1 dynamic, 0 fine static, 2 cluster
shared uint s_cnt[3];
shared uint s_count;     // VPLs appended (may exceed the cap)
shared int s_box[6];     // workgroup world cell bounds
shared uint s_work;      // 1 fast work, 2 full work in this workgroup

ivec3 imod3(ivec3 a, ivec3 b) {
	return a - b * ivec3(floor(vec3(a) / vec3(b)));
}

uint hash_u(uint x) {
	x ^= x >> 16u; x *= 0x7feb352du;
	x ^= x >> 15u; x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float rand01(inout uint s) {
	s = hash_u(s);
	return float(s & 0x00ffffffu) / 16777216.0;
}

float lum3(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float occ_at(vec3 p, int lod) {
	float cs = pc.cell.y * float(1 << lod);
	ivec3 i = ivec3(floor((p - pc.occ_origin.xyz) / cs));
	ivec3 sz = textureSize(occ_tex, lod);
	if (any(lessThan(i, ivec3(0))) || any(greaterThanEqual(i, sz))) {
		return 0.0; // outside the occupancy grid = open air
	}
	return texelFetch(occ_tex, i, lod).r;
}

// distance along d to the exit of the occupancy cell (size cs) containing p
float cell_exit(vec3 p, vec3 d, float cs) {
	vec3 rel = (p - pc.occ_origin.xyz) / cs;
	vec3 bound = (floor(rel) + step(0.0, d)) * cs + pc.occ_origin.xyz;
	vec3 ds = mix(vec3(1e-6), d, greaterThan(abs(d), vec3(1e-6)));
	vec3 tt = (bound - p) / ds;
	return max(min(tt.x, min(tt.y, tt.z)), 0.0) + 1e-3;
}

// Hierarchical march from t to t_end: empty 1 m / 0.5 m cells are skipped in
// one step, only cells next to geometry are tested at 0.25 m. Returns the hit
// distance or -1. (The coarse mips are conservative, so skipping is exact:
// light gets through every door and window the 0.25 m grid has.)
float march(vec3 a, vec3 d, float t, float t_end, int steps) {
	float c0 = pc.cell.y;
	for (int i = 0; i < 200; i++) {
		if (t >= t_end) {
			return -1.0;
		}
		if (i >= steps) {
			return t; // out of steps: count as blocked (never invent sky light)
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
	return t;
}

// Binary visibility a -> b. Solid cells closer than tol_a / tol_b to the ends are ignored.
bool visible(vec3 a, vec3 b, float tol_a, float tol_b, int extra) {
	vec3 d = b - a;
	float len = length(d);
	if (len < 1e-3) {
		return true;
	}
	d /= len;
	// VPL visibility: the end point is known, give it a generous step budget so
	// long rays along floors / walls are not cut off (that darkened whole rooms)
	return march(a, d, tol_a, len - tol_b, min(pc.misc.w + extra, 128)) < 0.0;
}

// Marches a sky ray. Returns the distance to the hit or -1 if it escapes.
float sky_ray_hit(vec3 a, vec3 d, float tol) {
	return march(a, d, tol, pc.cell.z, pc.misc.w);
}

vec3 sh_eval(vec4 r, vec4 g, vec4 b, vec3 n) {
	return max(vec3(r.x + dot(r.yzw, n), g.x + dot(g.yzw, n), b.x + dot(b.yzw, n)), vec3(0.0));
}

// ---- direct light cache + albedo grid (world space, 0.5 m)
vec3 dir_uvw(vec3 p) {
	return (p - prm.dir_origin.xyz) / prm.dir_extent.xyz;
}

vec3 direct_at(vec3 p, vec3 n) {
	vec3 uvw = dir_uvw(p);
	return sh_eval(textureLod(dir_r, uvw, 0.0), textureLod(dir_g, uvw, 0.0), textureLod(dir_b, uvw, 0.0), n);
}

vec3 albedo_at(vec3 p) {
	vec4 a = textureLod(alb_tex, dir_uvw(p), 0.0);
	return a.a > 0.02 ? a.rgb / a.a : vec3(0.5);
}

vec3 prev_irradiance(vec3 p, vec3 n);

// Normal of the surface a ray hit: the face of the solid 0.25 m cell it entered
// (an open neighbour on the side the ray came from). Boxy levels: exact.
vec3 hit_normal(vec3 hp, vec3 d, out vec3 face) {
	float c0 = pc.cell.y;
	vec3 hc = pc.occ_origin.xyz + (floor((hp - pc.occ_origin.xyz) / c0) + 0.5) * c0;
	vec3 n = -d;
	float best = 0.0;
	for (int i = 0; i < 3; i++) {
		float di = d[i];
		if (abs(di) < 0.05 || abs(di) <= best) {
			continue;
		}
		vec3 e = vec3(float(i == 0), float(i == 1), float(i == 2)) * -sign(di);
		if (occ_at(hc + e * c0, 0) < 0.5) {
			n = e;
			best = abs(di);
		}
	}
	face = best > 0.0 ? hp + n * (dot(hc - hp, n) + c0 * 0.5) : hp;
	return n;
}

// Light leaving the surface a ray hit: albedo * (direct + indirect) / PI,
// both evaluated for the real surface normal (evaluating them towards the ray
// lost most of the light of surfaces seen at grazing angles: floors seen from
// across a room, sunlit patches seen from a doorway).
vec3 hit_radiance(vec3 x, vec3 d, float th) {
	vec3 face;
	vec3 n = hit_normal(x + d * th, d, face);
	vec3 alb = albedo_at(face - n * 0.1);
	vec3 e = vec3(0.0);
	if (prm.dir_origin.w > 0.5) {
		e = direct_at(face + n * 0.25, n) * prm.pool_misc.z;
	}
	if (pc.sky_horizon.w > 0.0) {
		e += pc.sky_horizon.w * prev_irradiance(face + n * max(pc.cell.x * 0.5, 0.3), n);
	}
	return alb * e;
}

// A ray that ran out of length under a roof: the light of the building around
// its end point (no surface known: evaluated towards the ray).
vec3 end_radiance(vec3 x, vec3 d, float th) {
	vec3 alb = albedo_at(x + d * max(th - 0.05, 0.0));
	vec3 e = vec3(0.0);
	if (prm.dir_origin.w > 0.5) {
		e = direct_at(x + d * max(th - 0.3, 0.0), -d) * prm.pool_misc.z;
	}
	if (pc.sky_horizon.w > 0.0) {
		vec3 hp = x + d * max(th - pc.cell.y * 1.5 - pc.cell.x * 0.5, 0.0);
		e += pc.sky_horizon.w * prev_irradiance(hp, -d);
	}
	return alb * e;
}

// A ray that ran out of length: still under a roof (corridor, big hall) it
// sees more of the building, not the sky.
bool under_roof(vec3 p) {
	if (prm.dir_origin.w < 0.5) {
		return false;
	}
	vec3 uvw = dir_uvw(p);
	if (any(lessThan(uvw.xz, vec2(0.0))) || any(greaterThan(uvw.xz, vec2(1.0)))) {
		return false;
	}
	ivec2 rs = textureSize(roof_tex, 0);
	return p.y < texelFetch(roof_tex, clamp(ivec2(uvw.xz * vec2(rs)), ivec2(0), rs - 1), 0).r - prm.dir_extent.w;
}

// highest solid point of the column at p (-1e4 = no geometry)
float roof_at(vec3 p) {
	vec3 uvw = dir_uvw(p);
	if (any(lessThan(uvw.xz, vec2(0.0))) || any(greaterThan(uvw.xz, vec2(1.0)))) {
		return -1.0e4;
	}
	ivec2 rs = textureSize(roof_tex, 0);
	return texelFetch(roof_tex, clamp(ivec2(uvw.xz * vec2(rs)), ivec2(0), rs - 1), 0).r;
}

vec3 sky_radiance(vec3 d) {
	if (d.y >= 0.0) {
		return mix(pc.sky_horizon.rgb, pc.sky_top.rgb, sqrt(d.y));
	}
	// below the horizon: open ground beyond the map, lit by the sky
	return pc.sky_horizon.rgb * pc.sky_top.w;
}

bool cache_mode() {
	return (pc.prev_base.w & F_CACHE) != 0;
}

// ---- world chunk cache (static lighting of the whole map)
bool cache_uvw(vec3 p, out vec3 uvw) {
	uvw = (p / prm.cache_cell.x - vec3(prm.cache_base.xyz)) / vec3(prm.cache_size.xyz);
	return prm.cache_base.w > 0 && all(greaterThanEqual(uvw, vec3(0.0))) && all(lessThanEqual(uvw, vec3(1.0)));
}

vec3 cache_irradiance(vec3 p, vec3 n) {
	vec3 uvw;
	if (!cache_uvw(p, uvw)) {
		return vec3(0.0);
	}
	return sh_eval(textureLod(cache_r, uvw, 0.0), textureLod(cache_g, uvw, 0.0), textureLod(cache_b, uvw, 0.0), n);
}

// ---- previous near volume
bool prev_inside(vec3 p) {
	vec3 cellp = p / pc.cell.x;
	vec3 lo = vec3(pc.prev_base.xyz) + 0.5;
	vec3 hi = vec3(pc.prev_base.xyz + pc.size.xyz) - 0.5;
	return all(greaterThanEqual(cellp, lo)) && all(lessThanEqual(cellp, hi));
}

// Indirect light (/PI) arriving at p for normal n, from the last result.
// Near mode: the previous near volume, beyond it the chunk cache (never the
// sky: that leaked blue light into rooms at the volume edges).
vec3 prev_irradiance(vec3 p, vec3 n) {
	if (cache_mode()) {
		return cache_irradiance(p, n);
	}
	if ((pc.prev_base.w & F_RESET) != 0 || !prev_inside(p)) {
		return cache_irradiance(p, n);
	}
	vec3 uvw = p / pc.cell.x / vec3(pc.size.xyz); // repeat sampler -> toroidal
	return sh_eval(textureLod(prev_r, uvw, 0.0), textureLod(prev_g, uvw, 0.0), textureLod(prev_b, uvw, 0.0), n);
}

bool in_sregion(vec3 x) {
	int n = int(prm.sreg_info.x);
	for (int i = 0; i < 4; i++) {
		if (i >= n) {
			break;
		}
		if (all(greaterThanEqual(x, prm.sreg[i * 2].xyz)) && all(lessThanEqual(x, prm.sreg[i * 2 + 1].xyz))) {
			return true;
		}
	}
	return false;
}

bool in_region(vec3 x) {
	int n = int(prm.tune2.w);
	for (int i = 0; i < 4; i++) {
		if (i >= n) {
			break;
		}
		if (all(greaterThanEqual(x, prm.regions[i * 2].xyz)) && all(lessThanEqual(x, prm.regions[i * 2 + 1].xyz))) {
			return true;
		}
	}
	return false;
}

const ivec3 OFS[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));

const ivec3 DIAG[12] = ivec3[12](ivec3(1, 1, 0), ivec3(1, -1, 0), ivec3(-1, 1, 0), ivec3(-1, -1, 0),
		ivec3(1, 0, 1), ivec3(1, 0, -1), ivec3(-1, 0, 1), ivec3(-1, 0, -1),
		ivec3(0, 1, 1), ivec3(0, 1, -1), ivec3(0, -1, 1), ivec3(0, -1, -1));

// texel of world cell cn in the previous result, false if not available
bool prev_texel(ivec3 cn, out ivec3 tn) {
	if (cache_mode()) {
		tn = cn - pc.base.xyz;
		return all(greaterThanEqual(tn, ivec3(0))) && all(lessThan(tn, pc.size.xyz));
	}
	tn = imod3(cn, pc.size.xyz);
	return (pc.prev_base.w & F_RESET) == 0 && all(greaterThanEqual(cn, pc.prev_base.xyz)) && all(lessThan(cn, pc.prev_base.xyz + pc.size.xyz));
}

void store(ivec3 t, vec4 r, vec4 g, vec4 b, vec4 vr, vec4 vg, vec4 vb) {
	imageStore(out_r, t, r);
	imageStore(out_g, t, g);
	imageStore(out_b, t, b);
	if (!cache_mode()) {
		imageStore(out_vr, t, vr);
		imageStore(out_vg, t, vg);
		imageStore(out_vb, t, vb);
	}
}

// How much work voxel t needs: -1 outside, 0 keep, 1 fast part only, 2 full update.
int voxel_work(out ivec3 t, out ivec3 c, out bool was_valid, out float age) {
	ivec3 size = pc.size.xyz;
	bool cmode = cache_mode();
	t = cmode ? pc.prev_base.xyz + ivec3(gl_GlobalInvocationID) : ivec3(gl_GlobalInvocationID);
	c = ivec3(0);
	was_valid = false;
	age = 0.0;
	if (any(greaterThanEqual(t, size))) {
		return -1;
	}
	bool reset = (pc.prev_base.w & F_RESET) != 0;
	c = cmode ? pc.base.xyz + t : pc.base.xyz + imod3(t - pc.base.xyz, size); // world cell of texel t
	was_valid = cmode ? !reset : (!reset && all(greaterThanEqual(c, pc.prev_base.xyz)) && all(lessThan(c, pc.prev_base.xyz + size)));
	int frame = int(prm.tune2.z);
	age = float(frame);
	if (cmode) {
		return 2;
	}
	age = was_valid ? imageLoad(age_img, t).r : float(frame);
	bool fresh = !was_valid || in_sregion((vec3(c) + 0.5) * pc.cell.x);
	bool hot = float(frame) - age < prm.cache_cell.z;
	int slices = max(pc.misc.x, 1);
	int cold = max(int(prm.cache_cell.y), slices);
	// workgroup granularity (whole warps skip), scattered pattern instead of diagonal waves
	ivec3 wgc = c >> 2;
	uint h = hash_u(uint(wgc.x * 73856093) ^ uint(wgc.y * 19349663) ^ uint(wgc.z * 83492791));
	bool in_slice = int(h % uint(cold)) == frame % cold;
	if (fresh || in_slice) {
		return 2;
	}
	// Light that keeps changing (torch, moving lights): hot voxels and the fast
	// part inside update regions are refreshed by half of the workgroups per
	// update (checkerboard); the display smoothing hides it. This gather is by
	// far the most expensive part of the GI on phones.
	bool turn = ((wgc.x + wgc.y + wgc.z + frame) & 1) == 0;
	if (!turn) {
		return 0;
	}
	// Hot voxels only refresh the fast (dynamic light) part: static light
	// changes (lamps switched) are fresh voxels above and get the full update.
	// The sky rays of a full update are the expensive part, and a sweeping torch
	// made hundreds of voxels hot every update (torch lag on phones).
	return (hot || in_region((vec3(c) + 0.5) * pc.cell.x)) ? 1 : 0;
}

// returns: -1 nothing, 0 kept, 1 fast part only, 2 full update
int process(int work, ivec3 t, ivec3 c, bool was_valid, float age) {
	if (work < 0) {
		return -1;
	}
	ivec3 size = pc.size.xyz;
	bool cmode = cache_mode();
	int flags = pc.prev_base.w;
	vec3 x = (vec3(c) + 0.5) * pc.cell.x;
	float vox = pc.cell.x;
	int frame = int(prm.tune2.z);
	bool full = work == 2;
	if (work == 0) {
		imageStore(out_r, t, texelFetch(prev_r, t, 0));
		imageStore(out_g, t, texelFetch(prev_g, t, 0));
		imageStore(out_b, t, texelFetch(prev_b, t, 0));
		imageStore(out_vr, t, texelFetch(prev_vr, t, 0));
		imageStore(out_vg, t, texelFetch(prev_vg, t, 0));
		imageStore(out_vb, t, texelFetch(prev_vb, t, 0));
		return 0;
	}

	// ---- voxel centres buried inside geometry (walls, floors, ceiling slabs)
	// never probe from inside: rays started there skipped the thin wall / slab
	// and saw the other side (sky light in rooms: bright strips along the top of
	// walls, bright ceilings with a dot grid). They take the average of their
	// open neighbours instead - indoor neighbours (under a roof) only when there
	// are any, so a wall or ceiling voxel never mixes outdoor sky light into the
	// room it bounds.
	bool solid = occ_at(x, 0) > 0.5;
	float tol = 0.0;
	if (solid) {
		vec4 ar = vec4(0.0), ag = vec4(0.0), ab = vec4(0.0), avr = vec4(0.0), avg = vec4(0.0), avb = vec4(0.0);
		vec4 br = vec4(0.0), bg = vec4(0.0), bb = vec4(0.0), bvr = vec4(0.0), bvg = vec4(0.0), bvb = vec4(0.0);
		float n_in = 0.0;
		float n_out = 0.0;
		int open_k = -1;
		bool open_in = false;
		bool roofs = prm.dir_origin.w > 0.5;
		for (int k = 0; k < 6; k++) {
			ivec3 cn = c + OFS[k];
			vec3 xn = (vec3(cn) + 0.5) * vox;
			if (occ_at(xn, 0) > 0.5) {
				continue;
			}
			bool indoor = roofs && xn.y < roof_at(xn) - 0.1;
			if (open_k < 0 || (indoor && !open_in)) {
				open_k = k;
				open_in = indoor;
			}
			ivec3 tn;
			if (!prev_texel(cn, tn)) {
				continue;
			}
			vec4 r = texelFetch(prev_r, tn, 0), g = texelFetch(prev_g, tn, 0), b = texelFetch(prev_b, tn, 0);
			vec4 vr = vec4(0.0), vg = vec4(0.0), vb = vec4(0.0);
			if (!cmode) {
				vr = texelFetch(prev_vr, tn, 0); vg = texelFetch(prev_vg, tn, 0); vb = texelFetch(prev_vb, tn, 0);
			}
			if (indoor) {
				ar += r; ag += g; ab += b; avr += vr; avg += vg; avb += vb;
				n_in += 1.0;
			} else {
				br += r; bg += g; bb += b; bvr += vr; bvg += vg; bvb += vb;
				n_out += 1.0;
			}
		}
		if (n_in == 0.0 && roofs) {
			// a corner voxel (wall top meets the ceiling): the room is diagonal to it
			for (int k = 0; k < 12; k++) {
				ivec3 cn = c + DIAG[k];
				vec3 xn = (vec3(cn) + 0.5) * vox;
				ivec3 tn;
				if (occ_at(xn, 0) > 0.5 || !(xn.y < roof_at(xn) - 0.1) || !prev_texel(cn, tn)) {
					continue;
				}
				ar += texelFetch(prev_r, tn, 0); ag += texelFetch(prev_g, tn, 0); ab += texelFetch(prev_b, tn, 0);
				if (!cmode) {
					avr += texelFetch(prev_vr, tn, 0); avg += texelFetch(prev_vg, tn, 0); avb += texelFetch(prev_vb, tn, 0);
				}
				n_in += 1.0;
			}
		}
		if (open_in && n_in == 0.0) {
			n_out = 0.0; // the indoor side is not ready yet: probe it (below), never use the outdoor side
		}
		if (n_in > 0.0 || n_out > 0.0) {
			if (n_in > 0.0) {
				float inv = 1.0 / n_in;
				store(t, ar * inv, ag * inv, ab * inv, avr * inv, avg * inv, avb * inv);
			} else {
				float inv = 1.0 / n_out;
				store(t, br * inv, bg * inv, bb * inv, bvr * inv, bvg * inv, bvb * inv);
			}
			if (!cmode) {
				imageStore(age_img, t, vec4(age));
			}
			return full ? 2 : 1;
		}
		if (open_k < 0) {
			// fully buried: nothing samples it
			store(t, vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0));
			if (!cmode) {
				imageStore(age_img, t, vec4(age));
			}
			return full ? 2 : 1;
		}
		// no usable neighbour yet (they just entered the volume too): light it
		// like the open neighbour (indoor first), probed from there
		x = (vec3(c + OFS[open_k]) + 0.5) * vox;
		solid = false;
		full = true;
	}

	vec3 l0 = vec3(0.0);
	vec3 l1r = vec3(0.0);
	vec3 l1g = vec3(0.0);
	vec3 l1b = vec3(0.0);
	uint vseed = hash_u(uint(c.x * 73856093) ^ uint(c.y * 19349663) ^ uint(c.z * 83492791));
	uint seed = hash_u(vseed ^ uint(pc.misc.z * 2654435761u));

	// ---- sky light (uniform sphere, jittered spherical Fibonacci) -> slow part
	if (full) {
		int nsky = max(pc.misc.y, 1);
		// low-discrepancy over time (golden-ratio sequences per voxel) instead of
		// white noise: the accumulated history converges several times faster,
		// far less voxel-to-voxel noise (blotches) for the same ray count
		float fu = float(frame);
		float off = fract(float(vseed & 0xffffu) / 65536.0 + fu * 0.61803399);
		float rot = fract(float(vseed >> 16u) / 65536.0 + fu * 0.75487767) * 2.0 * PI;
		float w_sky = 4.0 * PI / float(nsky);
		for (int k = 0; k < 32; k++) {
			if (k >= nsky) {
				break;
			}
			float zz = 1.0 - 2.0 * (float(k) + off) / float(nsky);
			float rr = sqrt(max(0.0, 1.0 - zz * zz));
			float ph = float(k) * 2.39996323 + rot;
			vec3 d = vec3(rr * cos(ph), zz, rr * sin(ph));
			float th = sky_ray_hit(x, d, tol);
			vec3 kk;
			if (th >= 0.0) {
				kk = hit_radiance(x, d, th) * w_sky;
			} else if (under_roof(x + d * pc.cell.z)) {
				kk = end_radiance(x, d, pc.cell.z) * w_sky;
			} else {
				kk = sky_radiance(d) * w_sky;
			}
			l0 += 0.25 * kk;
			l1r += 0.5 * kk.r * d;
			l1g += 0.5 * kk.g * d;
			l1b += 0.5 * kk.b * d;
		}
	}

	// ---- one bounce from VPLs: dynamic lights -> fast part, static -> slow part
	vec3 v0 = vec3(0.0);
	vec3 v1r = vec3(0.0);
	vec3 v1g = vec3(0.0);
	vec3 v1b = vec3(0.0);
	int count = int(min(s_count, uint(clamp(int(prm.pool_misc.x), 8, MAXV))));
	for (int i = 0; i < MAXV; i++) {
		if (i >= count) {
			break;
		}
		vec4 nr = s_nrm[i];
		bool dyn = nr.w > 0.5 && nr.w < 1.5;
		if (!full && !dyn) {
			continue;
		}
		vec4 p = s_pos[i];
		vec4 f = s_flux[i];
		vec3 dv = p.xyz - x;
		float r2 = dot(dv, dv);
		if (r2 >= f.w) {
			continue;
		}
		float r = sqrt(r2) + 1e-4;
		vec3 w = dv / r; // towards the VPL
		float cos_e = -dot(nr.xyz, w);
		if (cos_e <= 0.0) {
			continue; // voxel is behind the patch
		}
		// dynamic VPLs (torch) are re-gathered every update: shorter step budget
		if (!visible(x, p.xyz, tol, 0.35, dyn ? 8 : 40)) {
			continue;
		}
		float q = r2 / f.w;
		float window = (1.0 - q * q);
		window *= window;
		// near-field clamp at voxel scale: a VPL right next to one voxel no longer
		// lights just that voxel (bright / dark neighbouring cells = blotches)
		vec3 kk = f.rgb * (cos_e * window / (PI * (r2 + max(p.w, 0.5 * vox * vox))));
		if (dyn) {
			v0 += 0.25 * kk;
			v1r += 0.5 * kk.r * w;
			v1g += 0.5 * kk.g * w;
			v1b += 0.5 * kk.b * w;
		} else {
			l0 += 0.25 * kk;
			l1r += 0.5 * kk.r * w;
			l1g += 0.5 * kk.g * w;
			l1b += 0.5 * kk.b * w;
		}
	}

	// store irradiance / PI  (= outgoing radiance of a white Lambertian surface)
	vec4 sr_n = vec4(l0.r, l1r) / PI;
	vec4 sg_n = vec4(l0.g, l1g) / PI;
	vec4 sb_n = vec4(l0.b, l1b) / PI;
	vec4 vr_n = vec4(v0.r, v1r) / PI;
	vec4 vg_n = vec4(v0.g, v1g) / PI;
	vec4 vb_n = vec4(v0.b, v1b) / PI;

	float a_s = pc.cell.w;       // slow part blend
	if (prm.sreg_info.x > 0.0 && in_sregion(x)) {
		a_s = max(a_s, prm.sreg_info.y); // a lamp changed here: drop the old light fast
	}
	float a_f = pc.occ_origin.w; // fast part blend
	vec4 tr, tg, tb, vr, vg, vb;
	bool have_prev = was_valid;
	if (was_valid) {
		tr = texelFetch(prev_r, t, 0);
		tg = texelFetch(prev_g, t, 0);
		tb = texelFetch(prev_b, t, 0);
		vr = cmode ? vec4(0.0) : texelFetch(prev_vr, t, 0);
		vg = cmode ? vec4(0.0) : texelFetch(prev_vg, t, 0);
		vb = cmode ? vec4(0.0) : texelFetch(prev_vb, t, 0);
		float dw = prm.tune2.x;
		if ((flags & F_DENOISE) != 0 && dw > 0.0) {
			// Edge-aware blur of the history with the 6 neighbours.
			// Neighbours behind a wall (solid in between) are skipped -> no leaks.
			vec4 a_tr = tr, a_tg = tg, a_tb = tb, a_vr = vr, a_vg = vg, a_vb = vb;
			float sw = 1.0;
			for (int k = 0; k < 6; k++) {
				ivec3 cn = c + OFS[k];
				ivec3 tn;
				if (!prev_texel(cn, tn)) {
					continue;
				}
				vec3 xn = (vec3(cn) + 0.5) * vox;
				if (occ_at(xn, 0) > 0.5 || occ_at(mix(x, xn, 0.5), 0) > 0.5) {
					continue;
				}
				a_tr += texelFetch(prev_r, tn, 0) * dw;
				a_tg += texelFetch(prev_g, tn, 0) * dw;
				a_tb += texelFetch(prev_b, tn, 0) * dw;
				if (!cmode) {
					a_vr += texelFetch(prev_vr, tn, 0) * dw;
					a_vg += texelFetch(prev_vg, tn, 0) * dw;
					a_vb += texelFetch(prev_vb, tn, 0) * dw;
				}
				sw += dw;
			}
			tr = a_tr / sw; tg = a_tg / sw; tb = a_tb / sw;
			vr = a_vr / sw; vg = a_vg / sw; vb = a_vb / sw;
		}
	} else if (!cmode) {
		// newly covered voxel: start from the cached static lighting instead of black
		vec3 uvw;
		if (cache_uvw(x, uvw)) {
			tr = textureLod(cache_r, uvw, 0.0);
			tg = textureLod(cache_g, uvw, 0.0);
			tb = textureLod(cache_b, uvw, 0.0);
			if (tr.x + tg.x + tb.x > 1e-5) {
				vr = vec4(0.0); vg = vec4(0.0); vb = vec4(0.0);
				have_prev = true;
				a_s = max(a_s, 0.35);
				a_f = 1.0;
			}
		}
	}

	bool changed = !was_valid;
	if (have_prev) {
		if ((flags & F_ADAPTIVE) != 0 && !cmode) {
			// Adaptive temporal response: where the dynamic light really changed
			// (torch moved / switched), blend (almost) immediately - both parts, as
			// the multi-bounce follows the same light. Small changes (VPL jitter
			// noise) stay smoothly blended.
			float ln = lum3(vec3(vr_n.x, vg_n.x, vb_n.x));
			float lp = lum3(vec3(vr.x, vg.x, vb.x));
			float lt = lum3(vec3(tr.x, tg.x, tb.x));
			float m = max(ln, lp);
			float excess = max(abs(ln - lp) - prm.tune2.y * m - 0.001, 0.0) / (max(lt, m) + 0.004);
			float k = smoothstep(prm.tune.x, prm.tune.y, excess);
			a_f = mix(a_f, prm.tune.z, k);
			a_s = mix(a_s, prm.tune.w, k);
			changed = changed || k > 0.3;
		}
		vec4 sr_p = tr - vr, sg_p = tg - vg, sb_p = tb - vb; // previous slow part
		vr_n = mix(vr, vr_n, a_f);
		vg_n = mix(vg, vg_n, a_f);
		vb_n = mix(vb, vb_n, a_f);
		if (full) {
			sr_n = mix(sr_p, sr_n, a_s);
			sg_n = mix(sg_p, sg_n, a_s);
			sb_n = mix(sb_p, sb_n, a_s);
		} else {
			sr_n = sr_p; sg_n = sg_p; sb_n = sb_p;
		}
	}
	store(t, sr_n + vr_n, sg_n + vg_n, sb_n + vb_n, vr_n, vg_n, vb_n);
	if (!cmode) {
		imageStore(age_img, t, vec4(changed ? float(frame) : age));
	}
	return cmode ? 2 : (full ? 2 : 1);
}

float dist2_box(vec3 p, vec3 lo, vec3 hi) {
	vec3 q = clamp(p, lo, hi) - p;
	return dot(q, q);
}

// some point of the box lies in front of the VPL's surface
bool faces_box(vec3 p, vec3 n, vec3 lo, vec3 hi, float slack) {
	vec3 sp = mix(lo, hi, step(0.0, n));
	return dot(n, sp - p) > -slack;
}

void put_vpl(uint k, vec4 p, vec4 f, vec4 n, vec3 alb, float kind) {
	if ((pc.prev_base.w & F_MULTI) != 0) {
		// multi-bounce: re-emit the indirect light that reaches this patch
		vec3 e_ind = prev_irradiance(p.xyz + n.xyz * pc.cell.x * 0.5, n.xyz) * PI;
		f.rgb += alb * e_ind * p.w;
	}
	s_pos[k] = vec4(p.xyz, p.w / PI); // w: disk regularisation (R^2 = A / PI)
	s_flux[k] = f;
	s_nrm[k] = vec4(n.xyz, kind);
}

void main() {
	uint lid = gl_LocalInvocationIndex;
	bool cmode = cache_mode();
	if (lid == 0u) {
		s_count = 0u;
		s_work = 0u;
		s_box[0] = 1 << 30; s_box[1] = 1 << 30; s_box[2] = 1 << 30;
		s_box[3] = -(1 << 30); s_box[4] = -(1 << 30); s_box[5] = -(1 << 30);
	}
	if (lid < 3u) {
		s_cnt[lid] = 0u;
	}
	barrier();
	ivec3 t, c;
	bool was_valid;
	float age;
	int work = voxel_work(t, c, was_valid, age);
	if (work > 0) {
		atomicMax(s_work, uint(work));
		atomicMin(s_box[0], c.x); atomicMin(s_box[1], c.y); atomicMin(s_box[2], c.z);
		atomicMax(s_box[3], c.x); atomicMax(s_box[4], c.y); atomicMax(s_box[5], c.z);
	}
	barrier();
	// ---- dynamic VPLs (torch, moving lamps) reaching this workgroup
	int ndyn = cmode ? 0 : min(pc.base.w, MAXV);
	if (s_work > 0u && ndyn > 0) {
		float vox = pc.cell.x;
		vec3 lo = vec3(s_box[0], s_box[1], s_box[2]) * vox;
		vec3 hi = vec3(s_box[3] + 1, s_box[4] + 1, s_box[5] + 1) * vox;
		uint cap = uint(clamp(int(prm.pool_misc.x), 8, MAXV));
		for (uint i = lid; i < uint(ndyn); i += 64u) {
			uint o = i * 4u;
			vec4 p = vpl.data[o + 0u];
			vec4 f = vpl.data[o + 1u];
			vec4 n = vpl.data[o + 2u];
			if (dist2_box(p.xyz, lo, hi) > f.w || !faces_box(p.xyz, n.xyz, lo, hi, 0.0)) {
				continue;
			}
			uint k = atomicAdd(s_count, 1u);
			if (k < cap) {
				put_vpl(k, p, f, n, vpl.data[o + 3u].rgb, 1.0);
			}
		}
		barrier();
		if (lid == 0u && s_count > 0u) {
			atomicAdd(prm.counters[3], min(s_count, cap));
		}
	}
	barrier();
	int r = process(work, t, c, was_valid, age);
	if (r >= 1) {
		atomicAdd(s_cnt[r == 2 ? (cmode ? 2 : 0) : 1], 1u);
	}
	barrier();
	if (lid < 3u && s_cnt[lid] > 0u) {
		atomicAdd(prm.counters[lid], s_cnt[lid]);
	}
}
