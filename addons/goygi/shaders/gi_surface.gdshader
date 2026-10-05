// Standard surface for every level material: triplanar albedo/roughness +
// normal map, lit directly by Godot lights and indirectly by the real-time GI
// volume (global uniforms written by GIManager).
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://addons/goygi/shaders/gi_common.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
// rgb = albedo, a = roughness variation (0.5 = neutral)
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float uv_scale = 0.5;
// true: texture in world space (walls, floors) / false: sticks to the object
uniform bool world_space = true;
uniform float normal_strength : hint_range(0.0, 3.0) = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float roughness_variation : hint_range(0.0, 2.0) = 0.6;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float blend_sharpness : hint_range(1.0, 16.0) = 6.0;
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;
// per instance: 0 when the lamp of this fixture is switched off (LightSwitch)
instance uniform float lamp_emission : hint_range(0.0, 1.0) = 1.0;

varying vec3 v_tpos;
varying vec3 v_tnrm;
varying vec3 v_wpos;
varying vec3 v_wnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (world_space) {
		v_tpos = v_wpos;
		v_tnrm = v_wnrm;
	} else {
		v_tpos = VERTEX;
		v_tnrm = NORMAL;
	}
}

vec3 unpack_n(vec4 s) {
	vec2 xy = (s.xy * 2.0 - 1.0) * normal_strength;
	return vec3(xy, sqrt(max(1.0 - dot(xy, xy), 0.0)));
}

void fragment() {
	vec3 n = normalize(v_tnrm);
	vec3 bw = pow(abs(n), vec3(blend_sharpness));
	bw /= max(bw.x + bw.y + bw.z, 1e-5);
	vec3 sgn = vec3(n.x < 0.0 ? -1.0 : 1.0, n.y < 0.0 ? -1.0 : 1.0, n.z < 0.0 ? -1.0 : 1.0);
	vec3 p = v_tpos * uv_scale;
	vec2 uvx = vec2(p.z * sgn.x, p.y);
	vec2 uvy = vec2(p.x * sgn.y, p.z);
	vec2 uvz = vec2(-p.x * sgn.z, p.y);

	vec4 a;
	vec3 nn;
	if (gi_params.w > 0.5) {
		// fast mode: one projection (dominant axis) -> 1 albedo + 1 normal fetch instead of 3 + 3
		vec3 an = abs(n);
		int ax_i = (an.x >= an.y && an.x >= an.z) ? 0 : (an.y >= an.z ? 1 : 2);
		vec2 uv = ax_i == 0 ? uvx : (ax_i == 1 ? uvy : uvz);
		a = texture(albedo_tex, uv);
		nn = n;
		if (gi_params.z > 0.5) {
			vec3 tn = unpack_n(texture(normal_tex, uv));
			if (ax_i == 0) {
				tn.x *= sgn.x;
				nn = normalize(vec3(abs(tn.z) * n.x, tn.y + n.y, tn.x + n.z));
			} else if (ax_i == 1) {
				tn.x *= sgn.y;
				nn = normalize(vec3(tn.x + n.x, abs(tn.z) * n.y, tn.y + n.z));
			} else {
				tn.x *= -sgn.z;
				nn = normalize(vec3(tn.x + n.x, tn.y + n.y, abs(tn.z) * n.z));
			}
		}
	} else {
		vec4 ax = texture(albedo_tex, uvx);
		vec4 ay = texture(albedo_tex, uvy);
		vec4 az = texture(albedo_tex, uvz);
		a = ax * bw.x + ay * bw.y + az * bw.z;
		nn = n;
		if (gi_params.z > 0.5) {
			// whiteout-blended triplanar normal mapping
			vec3 tx = unpack_n(texture(normal_tex, uvx));
			vec3 ty = unpack_n(texture(normal_tex, uvy));
			vec3 tz = unpack_n(texture(normal_tex, uvz));
			tx.x *= sgn.x;
			ty.x *= sgn.y;
			tz.x *= -sgn.z;
			tx = vec3(tx.xy + n.zy, abs(tx.z) * n.x);
			ty = vec3(ty.xy + n.xz, abs(ty.z) * n.y);
			tz = vec3(tz.xy + n.xy, abs(tz.z) * n.z);
			nn = normalize(tx.zyx * bw.x + ty.xzy * bw.y + tz.xyz * bw.z);
		}
	}
	vec3 nw = world_space ? nn : normalize(mat3(MODEL_MATRIX) * nn);
	if (!FRONT_FACING) {
		nw = -nw;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);

	vec3 alb = albedo_color.rgb * a.rgb;
	float rough = clamp(roughness + (a.a - 0.5) * roughness_variation, 0.04, 1.0);
	ALBEDO = alb;
	ROUGHNESS = rough;
	METALLIC = metallic;
	SPECULAR = specular;

	vec3 geo_n = normalize(v_wnrm) * (FRONT_FACING ? 1.0 : -1.0);
	vec3 view_w = normalize(CAMERA_POSITION_WORLD - v_wpos);
	vec3 refl_w = reflect(-view_w, nw);
	vec3 irr;
	vec3 rad;
	gi_sample(v_wpos, geo_n, nw, refl_w, irr, rad);
	float ao = gi_detail_ao(v_wpos, geo_n);
	irr *= ao;
	rad *= ao;
	float nv = clamp(dot(nw, view_w), 0.0, 1.0);
	vec3 f0 = mix(vec3(0.16 * specular * specular), alb, metallic);
	vec2 ab = gi_env_brdf(rough, nv);
	vec3 spec = (f0 * ab.x + ab.y) * rad;
	if (gi_params.y > 0.5) {
		// debug views: 1 indirect light only (white surfaces), 2 voxels, 3 GI age, 4 chunks
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		EMISSION = gi_params.y < 1.5 ? irr * gi_params.x : gi_debug_color(v_wpos, geo_n, nw, irr);
	} else {
		EMISSION = (alb * (1.0 - metallic) * irr + spec) * gi_params.x + emission_color * emission_energy * lamp_emission;
	}
}
