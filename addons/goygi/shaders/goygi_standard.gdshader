// GoyGI Standard: a drop-in replacement for StandardMaterial3D that receives
// GoyGI real-time indirect light (bounce, sky, colour bleeding) through
// EMISSION, like gi_surface.gdshader. GoyGISetup converts StandardMaterial3D
// surfaces to it automatically (editor preview + runtime); you can also
// assign it by hand. Supported: albedo colour/texture (+ vertex colour),
// roughness / metallic (+ textures, channel select), normal map, emission
// (+ texture), UV1 scale/offset, UV1 triplanar (local / world), alpha scissor
// (variant), double sided (variant). Not supported: transparency, clearcoat,
// rim, anisotropy, detail / AO / height maps, subsurface, billboards.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, ambient_light_disabled;

#include "res://addons/goygi/shaders/gi_common.gdshaderinc"

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_vertex_color = false;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D roughness_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D metallic_texture : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec4 metallic_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform bool use_normal_map = false;
uniform sampler2D normal_texture : hint_roughness_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;
uniform bool use_emission = false;
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 1.0;
uniform sampler2D emission_texture : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform bool uv1_triplanar = false;
uniform bool uv1_world_triplanar = false;
uniform float uv1_blend_sharpness = 1.0;
uniform float alpha_scissor_threshold = 0.5;
// multiplies the GoyGI indirect light on this material
uniform float gi_gain = 1.0;

varying vec3 v_wpos;
varying vec3 v_wnrm;
varying vec3 v_tpos;
varying vec3 v_tnrm;

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_tpos = (uv1_world_triplanar ? v_wpos : VERTEX) * uv1_scale + uv1_offset;
	v_tnrm = uv1_world_triplanar ? v_wnrm : NORMAL;
	UV = UV * uv1_scale.xy + uv1_offset.xy;
}

// macro (not a function): samplers with different hints can't share a helper
#define TEX(s) (uv1_triplanar ? (texture(s, v_tpos.zy) * bw.x + texture(s, v_tpos.xz) * bw.y + texture(s, v_tpos.xy) * bw.z) : texture(s, UV))

void fragment() {
	vec3 bw = pow(abs(normalize(v_tnrm)), vec3(uv1_blend_sharpness));
	bw /= max(bw.x + bw.y + bw.z, 1e-5);
	vec4 a = albedo_color * TEX(albedo_texture);
	if (use_vertex_color) {
		a *= COLOR;
	}
#ifdef GOYGI_SCISSOR
	ALPHA = a.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
#endif
	float rough = roughness * dot(TEX(roughness_texture), roughness_channel);
	float metal = metallic * dot(TEX(metallic_texture), metallic_channel);
	vec3 n_view = NORMAL;
	if (use_normal_map && !uv1_triplanar) {
		vec3 t = texture(normal_texture, UV).xyz * 2.0 - 1.0;
		t.xy *= normal_scale;
		n_view = normalize(TANGENT * t.x + BINORMAL * t.y + NORMAL * max(t.z, 1e-3));
		NORMAL = n_view;
	}
	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(n_view, 0.0)).xyz);
	ALBEDO = a.rgb;
	ROUGHNESS = rough;
	METALLIC = metal;
	SPECULAR = specular;

	vec3 geo_n = normalize(v_wnrm) * (FRONT_FACING ? 1.0 : -1.0);
	vec3 view_w = normalize(CAMERA_POSITION_WORLD - v_wpos);
	vec3 irr;
	vec3 rad;
	gi_sample(v_wpos, geo_n, nw, reflect(-view_w, nw), irr, rad);
	float ao = gi_detail_ao(v_wpos, geo_n);
	irr *= ao * gi_gain;
	rad *= ao * gi_gain;
	vec3 em = use_emission ? emission.rgb * emission_energy * texture(emission_texture, UV).rgb : vec3(0.0);
	float nv = clamp(dot(nw, view_w), 0.0, 1.0);
	vec3 f0 = mix(vec3(0.16 * specular * specular), a.rgb, metal);
	vec2 ab = gi_env_brdf(clamp(rough, 0.04, 1.0), nv);
	if (gi_params.y > 0.5) {
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		EMISSION = gi_params.y < 1.5 ? irr * gi_params.x : gi_debug_color(v_wpos, geo_n, nw, irr);
	} else {
		EMISSION = (a.rgb * (1.0 - metal) * irr + (f0 * ab.x + ab.y) * rad) * gi_params.x + em;
	}
}
