@tool
class_name GIManager
extends Node3D
## GoyGI - real-time dynamic global illumination for the Mobile renderer
## (no baking, no VoxelGI/SDFGI - runs on Vulkan 1.1 phones).
##
## Pipeline:
##  1. On load the static level (collision shapes under occupancy_root) is
##     voxelized into a 0.25 m occupancy grid (+2 coarser mips).
##  2. Lights with a GIEmitter child are split into
##       DYNAMIC (torch, moving / animated lights): traced every update,
##               feed the FAST part of the volume, mark "update regions";
##       STATIC  (lamps, fixtures): traced once (re-traced only when they change),
##               their Virtual Point Lights (VPLs) are cached and re-used.
##     The sun / moon is traced around the camera every update (clustered) and
##     once over the whole map for the chunk cache.
##  3. NEAR volume: camera-centred toroidal irradiance volume (L1 SH). Hot voxels
##     (light changed recently) update every time, voxels in dynamic update
##     regions update their fast part every time, everything else is refreshed
##     in slices and otherwise kept cached.
##  4. CHUNK CACHE: coarse world-space volume over the whole map, split into
##     8 x 8 m chunk columns that are computed progressively (player chunk
##     first, then by distance) and kept: never regenerated when you move,
##     only refreshed when the static lighting changes (time of day...).
##     Surfaces beyond the near volume use it (smooth per-chunk fade-in), the
##     near volume uses it for multi-bounce beyond its bounds and to initialise
##     newly covered voxels.
##  5. Every surface shader (gi_surface.gdshader) samples near -> cache ->
##     optional ambient through global shader uniforms.
##
## If no RenderingDevice exists (Compatibility renderer / headless) the GI is
## switched off (direct light only) and the game keeps running.

signal stats_updated(stats: Dictionary)

signal options_applied

## Set for the preview node the GoyGI editor plugin adds to scenes without a
## GIManager. Scene GIManagers preview in the editor when preview_in_editor is on.
var editor_preview := false

## Show this GI live in the editor viewport (like SDFGI / VoxelGI): light,
## sky and material edits update while you work. The "GoyGI" toggle in the 3D
## viewport toolbar switches the preview off for every scene.
@export var preview_in_editor := true
## When the game runs, take the options from the game's settings (a
## "GameSettings" autoload, GoyGIConfig.set_option(), Project Settings
## goygi/options) instead of the values below. In the editor the values below
## are always used. Off: this node is fully controlled by its own values /
## your scripts (gi.intensity = 2.0, gi.apply_preset(GIManager.Preset.HIGH)...).
@export var follow_game_settings := false
## Pick quality_preset from the device's GPU when the game starts
## (see recommended_preset()). Ignored while following the game settings.
@export var auto_quality := false

@export_group("Quality")
## Quality preset. Picking Low..Ultra fills every value of this group; changing one of them
## afterwards switches to Custom. Ultra is not the limit: the values below go higher.
@export_enum("Low", "Medium", "High", "Ultra", "Custom") var quality_preset: int = 1:
	set(v):
		quality_preset = v
		_preset_changed()
## Near GI volume size in voxels (x, height, z; multiples of 4). Bigger = GI reaches further
## around the camera (GPU memory + update cost grow with the voxel count).
@export var volume_size: Vector3i = Vector3i(48, 16, 48):
	set(v):
		volume_size = v
		_option_changed(&"volume_size")
## Near volume voxel size. Smaller = sharper indirect light, but the volume covers less
## (volume_size x voxel_size metres).
@export_range(0.15, 2.0, 0.01, "suffix:m") var voxel_size: float = 0.6:
	set(v):
		voxel_size = v
		_option_changed(&"voxel_size")
## Rays per voxel update (sky light + all static bounce light). More = less noise, faster convergence.
@export_range(1, 32) var sky_rays: int = 6:
	set(v):
		sky_rays = v
		_option_changed(&"sky_rays")
## Ray-march steps per ray (how far rays can travel through complex geometry).
@export_range(16, 200) var march_steps: int = 56:
	set(v):
		march_steps = v
		_option_changed(&"march_steps")
## CPU rays per update for dynamic lights (torch, moving lights).
@export_range(8, 128) var dynamic_rays: int = 48:
	set(v):
		dynamic_rays = v
		_option_changed(&"dynamic_rays")
## Virtual point lights per GPU workgroup for dynamic lights.
@export_range(16, 256) var max_vpls: int = 64:
	set(v):
		max_vpls = v
		_option_changed(&"max_vpls")
## Voxels that saw no light change are refreshed in this many slices (1 = all every update).
@export_range(1, 8) var update_slices: int = 2:
	set(v):
		update_slices = v
		_option_changed(&"update_slices")
## Updates between refreshes of voxels far from any change (higher = cheaper, slower to settle).
@export_range(1, 32) var cold_refresh: int = 4:
	set(v):
		cold_refresh = v
		_option_changed(&"cold_refresh")
## World cache chunk passes per update.
@export_range(1, 16) var chunk_budget: int = 2:
	set(v):
		chunk_budget = v
		_option_changed(&"chunk_budget")
@export_group("Lighting")
## GI on / off (off: direct light only).
@export var gi_enabled: bool = true:
	set(v):
		gi_enabled = v
		_option_changed(&"gi_enabled")
## Overall indirect light multiplier (1 = physically based).
@export_range(0.0, 8.0, 0.01, "or_greater") var intensity: float = 1.0:
	set(v):
		intensity = v
		_option_changed(&"intensity")
## Strength of the light bounced off surfaces lit by lamps, the sun and the moon.
@export_range(0.0, 8.0, 0.01, "or_greater") var bounce_strength: float = 1.6:
	set(v):
		bounce_strength = v
		_option_changed(&"bounce_strength")
## Light keeps bouncing (lit room -> hallway -> next room). Off: a single bounce.
@export var multi_bounce: bool = true:
	set(v):
		multi_bounce = v
		_option_changed(&"multi_bounce")
## Sky light multiplier (light coming in through windows / openings from the sky).
@export_range(0.0, 4.0, 0.01, "or_greater") var sky_strength: float = 1.0:
	set(v):
		sky_strength = v
		_option_changed(&"sky_strength")
## Flat ambient light added everywhere (0 = off; physically based look).
@export_range(0.0, 1.0, 0.01) var ambient: float = 0.0:
	set(v):
		ambient = v
		_option_changed(&"ambient")
## Colour of the flat ambient light.
@export_color_no_alpha var ambient_color: Color = Color(1, 1, 1):
	set(v):
		ambient_color = v
		_option_changed(&"ambient_color")
## Contact occlusion from the 0.25 m occupancy grid (corners, under furniture).
@export var detail_occlusion: bool = true:
	set(v):
		detail_occlusion = v
		_option_changed(&"detail_occlusion")
@export_group("Temporal")
## GI updates per second.
@export_range(5, 120, 1, "suffix:Hz") var update_rate: int = 30:
	set(v):
		update_rate = v
		_option_changed(&"update_rate")
## How quickly the GI reacts to a light change.
@export_range(0.0, 1.0, 0.01) var response: float = 0.7:
	set(v):
		response = v
		_option_changed(&"response")
## Temporal smoothing of the static light (higher = calmer, slower).
@export_range(0.0, 1.0, 0.01) var smoothing: float = 0.75:
	set(v):
		smoothing = v
		_option_changed(&"smoothing")
## Temporal stabilization of dynamic light (torch).
@export_enum("Off", "Low", "Medium", "High") var stabilization: int = 2:
	set(v):
		stabilization = v
		_option_changed(&"stabilization")
## Edge-aware blur between neighbouring voxels (never through walls).
@export_enum("Off", "Low", "Medium", "High") var spatial_filter: int = 2:
	set(v):
		spatial_filter = v
		_option_changed(&"spatial_filter")
## Big light changes blend in immediately, small noise stays smooth.
@export var adaptive_response: bool = true:
	set(v):
		adaptive_response = v
		_option_changed(&"adaptive_response")
## Per-frame display smoothing between GI updates.
@export_enum("Instant", "Fast", "Medium", "Slow") var transition: int = 2:
	set(v):
		transition = v
		_option_changed(&"transition")
## Lowers the update rate while the game runs below target_fps.
@export var auto_budget: bool = true:
	set(v):
		auto_budget = v
		_option_changed(&"auto_budget")
## Frame rate the auto budget aims for (0 = 60).
@export_range(0, 240) var target_fps: int = 60:
	set(v):
		target_fps = v
		_option_changed(&"target_fps")
@export_group("Filtering")
## How surfaces sample the volume. Smooth / Leak-Proof stop light creeping through walls.
@export_enum("Fast", "Smooth", "Leak-Proof") var filtering: int = 1:
	set(v):
		filtering = v
		_option_changed(&"filtering")
@export_group("World Cache")
## World cache (static GI of the whole map, beyond the near volume).
@export_enum("Off", "Near Only", "Balanced", "Full") var chunk_mode: int = 1:
	set(v):
		chunk_mode = v
		_option_changed(&"chunk_mode")
## Distance around the camera the world cache keeps loaded (Near Only / Balanced).
@export_range(8.0, 256.0, 1.0, "suffix:m") var chunk_distance: float = 24.0:
	set(v):
		chunk_distance = v
		_option_changed(&"chunk_distance")
@export_group("Surfaces")
## Normal maps on GoyGI surfaces.
@export var normal_maps: bool = true:
	set(v):
		normal_maps = v
		_option_changed(&"normal_maps")
## One texture projection instead of three on GoyGI surfaces (much cheaper on phones).
@export var fast_triplanar: bool = false:
	set(v):
		fast_triplanar = v
		_option_changed(&"fast_triplanar")
@export_group("Debug")
## Debug view.
@export_enum("Off", "GI Only", "Voxels", "GI Age", "Chunks", "Leak Guard") var debug_view: int = 0:
	set(v):
		debug_view = v
		_option_changed(&"debug_view")
## Draw the virtual point lights.
@export var show_vpls: bool = false:
	set(v):
		show_vpls = v
		_option_changed(&"show_vpls")
## Draw the dynamic light rays.
@export var show_rays: bool = false:
	set(v):
		show_rays = v
		_option_changed(&"show_rays")
## Draw the dynamic update regions.
@export var show_regions: bool = false:
	set(v):
		show_regions = v
		_option_changed(&"show_regions")
## GPU counters readback for stats.
@export var developer_stats: bool = false:
	set(v):
		developer_stats = v
		_option_changed(&"developer_stats")
@export_group("")

## Static geometry that blocks light (its collision shapes are voxelized).
@export var occupancy_root: Node3D
## The main directional light (moon / sun). Optional.
@export var sun: DirectionalLight3D
## Used to read the sky colours for sky lighting. Optional.
@export var world_environment: WorldEnvironment
## Physics layers the GI rays can hit.
@export_flags_3d_physics var collision_mask: int = 1
## Occupancy voxel size in metres.
@export_range(0.1, 1.0, 0.01) var occupancy_cell: float = 0.25
## Distance from the camera at which emitters stop being traced.
@export_range(0.0, 100.0, 0.5) var cull_margin: float = 10.0
## Bounce energy multiplier on top of the physically based value.
@export_range(0.0, 4.0, 0.01) var bounce_scale: float = 1.0
## Extra bounce of the sun / moon only (1 = physical). Raise it so moonlight or a
## low sun carries further into buildings without brightening lamps or GI
## Intensity everywhere. The example game sets it per time of day.
@export_range(0.0, 8.0, 0.01, "or_greater") var sun_bounce: float = 1.0
## Sky light multiplier on top of the sky colours (x Environment Contribution).
@export_range(0.0, 4.0, 0.01) var sky_scale: float = 1.0
## Radiance of open ground beyond the map, relative to the horizon sky.
@export_range(0.0, 1.0, 0.01) var ground_factor: float = 0.25
## Average surface albedo for multi-bounce. Must stay below 1.
@export_range(0.0, 0.9, 0.01) var bounce_albedo: float = 0.75
## Contributions below this (in output radiance) are cut off -> limits VPL range.
@export_range(0.0001, 0.05, 0.0001) var vpl_cutoff: float = 0.0015
@export_range(1.0, 30.0, 0.1) var vpl_max_range: float = 12.0
## World chunk cache (static GI of the whole map, loaded progressively).
@export var chunk_cache_enabled: bool = true
## Which geometry blocks light. Auto: collision shapes under occupancy_root,
## plus the triangles of visible meshes / CSG when there are no static
## collision shapes at all (scenes built without collision). Shapes + Meshes
## always adds the meshes. ConcavePolygonShape3D collision (trimesh) is always
## voxelized from its triangles.
@export_enum("Auto", "Collision Shapes", "Shapes + Meshes") var occupancy_source: int = 0
## Sets a hand-placed GIManager up like the auto-attached one: an empty
## Occupancy Root / Sun / World Environment is found in the scene, scenes
## without collision get helper colliders for the GI rays, Spot / Omni lights
## get GIEmitters and StandardMaterial3D surfaces switch to the GoyGI shader
## (Project Settings goygi/runtime/auto_emitters, convert_materials).
@export var auto_setup: bool = true

const OPTION_KEYS := {
	"gi_quality": &"quality_preset",
	"gi_vpls": &"max_vpls",
	"gi_enabled": &"gi_enabled",
	"gi_power": &"intensity",
	"gi_bounce_strength": &"bounce_strength",
	"gi_bounces": &"multi_bounce",
	"gi_environment": &"sky_strength",
	"gi_ambient": &"ambient",
	"gi_detail_ao": &"detail_occlusion",
	"gi_update_rate": &"update_rate",
	"gi_response": &"response",
	"gi_smoothing": &"smoothing",
	"gi_stabilization": &"stabilization",
	"gi_spatial_filter": &"spatial_filter",
	"gi_adaptive": &"adaptive_response",
	"gi_transition": &"transition",
	"gi_auto_budget": &"auto_budget",
	"max_fps": &"target_fps",
	"gi_filtering": &"filtering",
	"gi_chunk_mode": &"chunk_mode",
	"gi_chunk_distance": &"chunk_distance",
	"normal_maps": &"normal_maps",
	"fast_triplanar": &"fast_triplanar",
	"gi_debug_view": &"debug_view",
	"gi_show_vpls": &"show_vpls",
	"gi_show_rays": &"show_rays",
	"gi_show_regions": &"show_regions",
	"developer_mode": &"developer_stats",
}
## Quality tiers of the presets:
## [resolution, VPLs, ray budget, update budget, filtering, fast triplanar, normal maps]
## Low / Medium are the phone tiers: the single-projection level shader and no
## normal maps keep the fragment cost down (on mobile the level shader, not the
## GI, is usually the expensive part).
const PRESET_TIERS: Array[Array] = [
	[0, 32, 0, 0, 1, true, false],
	[1, 64, 1, 1, 1, true, false],
	[2, 96, 2, 2, 1, false, true],
	[4, 256, 3, 3, 2, false, true],
]
const QUALITY_PROPS: Array[StringName] = [&"volume_size", &"voxel_size", &"sky_rays", &"march_steps", &"dynamic_rays",
		&"max_vpls", &"update_slices", &"cold_refresh", &"chunk_budget", &"filtering"]
enum Preset { LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
const MAX_VPLS := 128
const VPL_STRIDE := 16 # floats per VPL
const DEFAULT_ALBEDO := Color(0.5, 0.5, 0.5)
const SHADER_PATH := "res://addons/goygi/shaders/gi_volume.glsl"
const BLEND_SHADER_PATH := "res://addons/goygi/shaders/gi_blend.glsl"
const DIRECT_SHADER_PATH := "res://addons/goygi/shaders/gi_direct.glsl"
const METER_SHADER_PATH := "res://addons/goygi/shaders/gi_meter.glsl"
const MAX_LIGHTS := 1024 # static lamps in the direct light cache
const DIRECT_BUDGET := 98304 # direct cache work per update: texels x (1 + lights reaching them)
## Gain of the cached direct light where GI rays hit a surface: the 0.5 m cache
## averages bright patches with their darker surroundings (calibrated against
## the Cornell box / sun rooms of 2.5).
const DIRECT_GAIN := 1.5
const DIR_BRICK := 8 # direct cache dirty tracking in bricks of 8^3 texels (4 m)
const SREG_UPDATES := 10 # updates a light-change box keeps forcing full, fast-blended updates
const PARAM_BYTES := 448
## chunk cache
const CHUNK := 8 # cache cells per chunk (x and z); chunks are full-height columns
const CACHE_CELL := 1.0
const LOAD_PASSES := 3 # passes until a chunk counts as loaded
const REFINE_PASSES := 8 # passes until a chunk stops refining
const MAX_CACHE_JOBS := 16 # chunk passes per update (loading boost)
const REGION_GROW := 2.0 # m around the surfaces a dynamic light touches
const HOT_UPDATES := 8.0 # voxels stay "hot" this many updates after a change
enum ChunkMode { PLAYER_ONLY, NEARBY, EXTENDED, LOAD_ALL }

## Camera-centred irradiance volume (ping-pong RGBA16F textures, L1 SH per colour channel).
class Cascade:
	var name := ""
	var size := Vector3i(32, 12, 32)
	var cell := 1.0
	var slices := 2
	var cold := 4
	var sky_rays := 4
	var steps := 48
	var base := Vector3i.ZERO
	var prev_base := Vector3i.ZERO
	var tex: Array[RID] = [] # total [A_r, A_g, A_b, B_r, B_g, B_b], fast [A_vr.. B_vb], [age]
	var sets: Array[RID] = [] # [A -> B, B -> A]
	var proxies: Array[Texture3DRD] = []
	var age_proxy: Texture3DRD
	var cur := 0 # 0: result in A, 1: result in B
	var blend_sets: Array[RID] = [] # display smoothing: [result A -> display, result B -> display]
	var disp_proxies: Array[Texture3DRD] = []
	var disp_base := Vector3i(1 << 29, 0, 0)
	var needs_reset := true
	var updates := 0
	var ready := false # main-thread flag: textures exist and contain data


## World-space chunk cache (static lighting of the whole map).
class ChunkCache:
	var cell := 1.0
	var base := Vector3i.ZERO # world cell of texel 0
	var size := Vector3i.ZERO
	var nx := 0
	var nz := 0
	var passes := PackedInt32Array()
	var stale := PackedByteArray()
	var vis := PackedFloat32Array() # displayed fade-in 0..1
	var mask := PackedByteArray()
	var alloc_key := Vector3i(-1, -1, -1) # (nx, nz, height) the allocated textures belong to
	var tex: Array[RID] = [] # [A_r, A_g, A_b, B_r, B_g, B_b, age dummy]
	var mask_tex: RID
	var uset: RID
	var proxies: Array[Texture3DRD] = []
	var mask_proxy: Texture2DRD
	var ready := false
	var dirty_mask := true
	var updates := 0


var _rd: RenderingDevice
var _gpu_ok := false
var _gpu_init_requested := false
var _gpu_init_done := false # written by the render thread
var _gpu_failed := false
var _shader: RID
var _pipeline: RID
var _blend_shader: RID
var _blend_pipeline: RID
var _transition_tau := 0.12 # s, display smoothing time constant (0 = off)
var _disp_on := false # globals currently point at the display textures
var _filter := Vector2(1.0, 0.5) # GI Filtering mode, sample offset (cells)
var _occ_tex: RID
var _vpl_buf: RID
var _param_buf: RID
var _sampler_linear: RID
var _sampler_clamp: RID
var _sampler_nearest: RID
var _rt_cache_tex: Array[RID] = [] # render-thread copy of the cache textures

var _occ_bytes: PackedByteArray
var _occ_origin := Vector3.ZERO
var _occ_size := Vector3i.ZERO
var _occ_aabb := AABB()
var _geo_aabb := AABB()

var _near := Cascade.new()
var _cache := ChunkCache.new()

var _vpl := PackedFloat32Array() # near VPL list sent to the GPU
var _vpl_count := 0
var _n_dyn := 0
var _n_static := 0
var _query := PhysicsRayQueryParameters3D.new()
var _albedo_cache: Dictionary = {}
var _accum := 0.0
var _frame := 0
var _rays_cast := 0
var _cpu_usec := 0
var _jitter := 0

# cached settings
var _enabled := true
var _power := 1.0
var _quality: Dictionary = {}
var _bounces := 1
var _bounce_strength := 1.6 # gain on the static (sun / lamp) bounce
var _interval := 1.0 / 30.0
var _alpha := 0.3 # history blend without adaptive response
var _alpha_fast := 0.6 # dynamic part blend (Temporal Stabilization)
var _alpha_slow := 0.15 # static part blend (Smoothness)
var _tune := Vector4(0.03, 0.2, 1.0, 0.7) # response lo, hi, fast max, slow max
var _noise_tol := 0.2
var _denoise_w := 0.35
var _display_smooth := 0.6 # display pass: weight of each of the 6 neighbours
var _debug_view := 0
var _show_vpls := false
var _show_rays := false
var _show_regions := false
var _quality_dirty := true
var _adaptive := true
var _detail_ao := true
var _tex_flags := Vector2(1.0, 0.0) # normal maps on, fast triplanar off
var _ambient := Color(0, 0, 0)
var _env_scale := 1.0
var _chunk_mode := ChunkMode.NEARBY
var _chunk_distance := 24.0
var _occ_proxy: Texture3DRD

# adaptive update rate
const MOTION_EPS := 0.02
var _motion_sig: Dictionary = {} # instance id -> [pos, dir, on, energy]
var _last_motion_ms := 0
var _rate_mult := 1.0
## Auto GI Budget governor: 0 = full budget .. 3 = heavily throttled. Raised
## when frames take longer than the FPS target, lowered again when there is
## headroom. Scales the update rate and the cold-voxel refresh period only, so
## image quality stays (lights still respond instantly via the hot path).
var gov_level := 0
var _gov_on := true
var _gov_ema := 16.0
var _gov_t := 0.0

# static lighting
var _static: Dictionary = {} # emitter instance id -> {"em", "sig", "dyn", "box"}
var _auto_dyn: Dictionary = {} # emitter id -> [changes in a row, dynamic until msec]
var _static_boost := 0 # updates with faster static blending after a global lighting change
var _sun_sig := []
# direct light cache (static lamps + sun, world space, occupancy mip 1 grid)
var _dir_size := Vector3i.ZERO
var _dir_cell := 0.5
var _dir_dirty := PackedByteArray() # 1 = brick must be recomputed
var _dir_bricks := Vector3i.ZERO
var _dir_ndirty := 0
var _dir_scan := 0 # round-robin start of the dirty scan
var _dir_initial := true # the first full build is still running
var _lights_bytes := PackedByteArray()
var _lights_n := 0
var _lights_dirty := true
var _sregs: Array = [] # [AABB, updates left]: lamps changed there
var _alb_bytes := PackedByteArray()
var _roof_bytes := PackedByteArray()
var _roof_size := Vector2i.ONE
var _dir_shader: RID
var _dir_pipeline: RID
var _dir_tex: Array[RID] = []
var _alb_tex: RID
var _roof_tex: RID
var _roof_proxy: Texture2DRD
var _light_buf: RID
var _dir_uset: RID
var _regions: Dictionary = {} # emitter id -> [AABB, until msec]
var _region_list: Array[AABB] = []
var _load_all_request := false
var _loading_boost := false
var _cache_jobs_last := 0
var _cache_chunks_last: Array[int] = []

# stats / debug
var _gpu_counts := PackedInt64Array([0, 0, 0])
var _gpu_ms := -1.0
var _dev_mode := false
var debug_rays := PackedVector3Array() # from, to pairs (Ray visualization)
var debug_vpls: Array = [] # [pos, color] (VPL visualization)


var _running := false


## Registers the GoyGI global shader uniforms as soon as this script loads, so
## it works in any project (plugin enabled or not, globals missing from the
## Project Settings, older GoyGI globals list...).
static func _static_init() -> void:
	GoyGISetup.ensure_globals()


func _enter_tree() -> void:
	GoyGISetup.ensure_globals()


var _auto_root: Node
var _auto_emitters: Array[Node] = []
var _auto_filled: Array[StringName] = []


func _scene_root() -> Node:
	if Engine.is_editor_hint():
		var er := get_tree().edited_scene_root
		if er != null and (er == self or er.is_ancestor_of(self)):
			return er
	var cs := get_tree().current_scene
	if cs != null and (cs == self or cs.is_ancestor_of(self)):
		return cs
	return get_parent()


func _auto_setup() -> void:
	if not auto_setup:
		return
	var root := _scene_root()
	if root == null:
		return
	_auto_root = root
	if occupancy_root == null:
		var map := root.get_node_or_null(^"Map") as Node3D
		occupancy_root = map if map else (root as Node3D if root is Node3D else get_parent() as Node3D)
		_auto_filled.append(&"occupancy_root")
	if sun == null:
		sun = GoyGISetup.first_of(root, "DirectionalLight3D") as DirectionalLight3D
		if sun:
			_auto_filled.append(&"sun")
	if world_environment == null:
		world_environment = GoyGISetup.first_of(root, "WorldEnvironment") as WorldEnvironment
		if world_environment:
			_auto_filled.append(&"world_environment")
	var id := get_instance_id()
	if occupancy_root != null and not GoyGISetup._colliders.has(id) and not GoyGISetup.has_static_shapes(occupancy_root):
		var bodies := GoyGISetup.add_mesh_colliders(occupancy_root)
		GoyGISetup._colliders[id] = bodies
		if not bodies.is_empty():
			collision_mask |= 1 << (GoyGISetup.MESH_LAYER - 1)
	if bool(ProjectSettings.get_setting("goygi/runtime/auto_emitters", true)):
		_auto_emitters.append_array(GoyGISetup.add_emitters(root))
	if bool(ProjectSettings.get_setting("goygi/runtime/convert_materials", true)):
		GoyGISetup.convert_materials(root, Engine.is_editor_hint())


## Editor: undoes _auto_setup (nothing of it may end up in the saved scene).
func _auto_teardown() -> void:
	if not Engine.is_editor_hint():
		return
	if _auto_root != null and is_instance_valid(_auto_root):
		GoyGISetup.restore(_auto_root)
	for e in _auto_emitters:
		if is_instance_valid(e) and e.get_parent() != null:
			e.get_parent().remove_child(e)
			e.queue_free()
	_auto_emitters.clear()
	GoyGISetup.detach(self)
	for p in _auto_filled:
		set(p, null)
	_auto_filled.clear()
	_auto_root = null


func _ready() -> void:
	if quality_preset < Preset.CUSTOM:
		_fill_preset(quality_preset)
	if Engine.is_editor_hint():
		set_process(false)
		if editor_preview or (preview_in_editor and editor_preview_allowed()):
			start.call_deferred()
		return
	if auto_quality and not follow_game_settings:
		quality_preset = recommended_preset()
	start()


func _exit_tree() -> void:
	stop()


## The "GoyGI" toggle of the editor's 3D viewport toolbar (Project Setting
## goygi/editor_preview).
static func editor_preview_allowed() -> bool:
	return bool(ProjectSettings.get_setting("goygi/editor_preview", true))


func is_running() -> bool:
	return _running


## Starts the GI (called automatically; in the editor when the preview is on).
func start() -> void:
	if _running or not is_inside_tree():
		return
	_running = true
	set_process(true)
	add_to_group(&"gi_manager")
	# keeps integrating while the game is paused (menu / loading screen backdrop)
	if not Engine.is_editor_hint():
		process_mode = Node.PROCESS_MODE_ALWAYS
	_auto_setup()
	_query.collision_mask = collision_mask
	_query.collide_with_areas = false
	_query.collide_with_bodies = true
	_query.hit_back_faces = false
	_query.hit_from_inside = false
	_vpl.resize(MAX_VPLS * VPL_STRIDE)
	_near.name = "gi_near"
	GoyGIConfig.listen(_on_settings_changed)
	if _follow_active():
		_pull_config()
	_opts_live = true
	_apply_options(&"")
	_bind_placeholder()
	_set_fallback_globals()
	if not Engine.is_editor_hint() and get_node_or_null(^"DebugDraw") == null:
		var dbg := preload("res://addons/goygi/core/gi_debug_draw.gd").new()
		dbg.name = "DebugDraw"
		add_child(dbg)
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_warning("GIManager: no RenderingDevice (Compatibility renderer?) - GI disabled (direct light only).")
		_emit_stats.call_deferred()
		return
	var t0 := Time.get_ticks_usec()
	_build_occupancy()
	_geo_sig = _geometry_signature()
	print("GIManager: occupancy %s cells built in %.1f ms" % [_occ_size, (Time.get_ticks_usec() - t0) / 1000.0])
	_setup_cache()
	_gpu_init_requested = true
	RenderingServer.call_on_render_thread(_rt_init)


## Stops the GI and frees its GPU resources (surfaces fall back to direct light).
func stop() -> void:
	if not _running:
		return
	_running = false
	_opts_live = false
	set_process(false)
	_auto_teardown()
	GoyGIConfig.unlisten(_on_settings_changed)
	# detach the materials from the volume textures before freeing them
	_bind_placeholder()
	_near.proxies.clear()
	_near.disp_proxies.clear()
	_near.age_proxy = null
	_cache.proxies.clear()
	_cache.mask_proxy = null
	_occ_proxy = null
	_roof_proxy = null
	if _rd != null and _gpu_init_requested:
		var mt: Array = _cache.tex.duplicate()
		mt.append(_cache.mask_tex)
		var rids: Array = [_dir_pipeline, _dir_shader, _alb_tex, _roof_tex, _light_buf, _blend_pipeline, _blend_shader, _vpl_buf,
				_param_buf, _dummy3d, _dummy_age, _meter_pipeline, _meter_shader, _meter_buf, _occ_tex, _sampler_linear, _sampler_clamp,
				_sampler_nearest, _pipeline, _shader]
		RenderingServer.call_on_render_thread(_rt_free_all.bind(_near.tex.duplicate(), mt, _dir_tex.duplicate(), _dir_uset, rids))
	_reset_state()


## Rebuilds everything (occupancy grid, caches, GPU resources). Call it after
## moving / adding / removing static level geometry at run time - see the
## implementation further down (it rebuilds in place whenever it can).


func _reset_state() -> void:
	_rd = null
	_gpu_ok = false
	_gpu_init_requested = false
	_gpu_init_done = false
	_gpu_failed = false
	for v: StringName in [&"_shader", &"_pipeline", &"_blend_shader", &"_blend_pipeline", &"_occ_tex", &"_vpl_buf", &"_param_buf",
			&"_sampler_linear", &"_sampler_clamp", &"_sampler_nearest", &"_dir_shader", &"_dir_pipeline", &"_alb_tex", &"_roof_tex",
			&"_light_buf", &"_dir_uset", &"_dummy3d", &"_dummy_age", &"_meter_shader", &"_meter_pipeline", &"_meter_buf"]:
		set(v, RID())
	_dir_tex = []
	_rt_cache_tex = []
	_disp_on = false
	_near = Cascade.new()
	_near.name = "gi_near"
	_cache = ChunkCache.new()
	_vpl_count = 0
	_n_dyn = 0
	_n_static = 0
	_albedo_cache = {}
	_accum = 0.0
	_quality = {}
	_quality_dirty = true
	_motion_sig = {}
	gov_level = 0
	_static = {}
	_auto_dyn = {}
	_static_boost = 0
	_sun_sig = []
	_dir_size = Vector3i.ZERO
	_dir_dirty = PackedByteArray()
	_dir_bricks = Vector3i.ZERO
	_dir_ndirty = 0
	_dir_scan = 0
	_dir_initial = true
	_lights_bytes = PackedByteArray()
	_lights_n = 0
	_lights_dirty = true
	_sregs = []
	_regions = {}
	_region_list = []
	_cache_chunks_last = []
	_gpu_counts = PackedInt64Array([0, 0, 0])
	_gpu_ms = -1.0
	_meter = Vector4(-1, 0, 0, 0)
	_geo_sig = 0
	_last_params = Vector4(-1, -1, -1, -1)
	_last_fallback = Color(-1, -1, -1)
	_last_debug = Vector4(-1, -1, -1, -1)
	_last_filter = Vector4(-1, -1, -1, -1)


## Editor preview: a cheap signature of the static collision shapes, so moving
## a wall / prop in the editor rebuilds the occupancy grid.
var _geo_sig := 0
var _geo_check_t := 0.0

func _geometry_signature() -> int:
	var root: Node = occupancy_root if occupancy_root != null and is_instance_valid(occupancy_root) else get_parent()
	if root == null:
		return 0
	var h := 0
	for n in root.find_children("*", "CollisionShape3D", true, false):
		var cs := n as CollisionShape3D
		if cs.disabled or cs.shape == null:
			continue
		var sh := cs.shape
		var dim: Variant = sh.get_instance_id()
		if sh is BoxShape3D:
			dim = (sh as BoxShape3D).size
		elif sh is SphereShape3D:
			dim = (sh as SphereShape3D).radius
		elif sh is CapsuleShape3D:
			dim = Vector2((sh as CapsuleShape3D).radius, (sh as CapsuleShape3D).height)
		elif sh is CylinderShape3D:
			dim = Vector2((sh as CylinderShape3D).radius, (sh as CylinderShape3D).height)
		elif sh is ConcavePolygonShape3D:
			dim = (sh as ConcavePolygonShape3D).get_faces().size()
		h = hash([h, cs.global_transform, dim])
	for n in root.find_children("*", "CSGShape3D", true, false):
		h = hash([h, (n as Node3D).global_transform])
	return h


var _placeholder: ImageTexture3D
var _placeholder_2d: ImageTexture

## Binds a 1x1x1 black texture to the GI sampler globals.
func _bind_placeholder() -> void:
	if _placeholder == null:
		var img := Image.create_empty(1, 1, false, Image.FORMAT_RGBAH)
		img.fill(Color(0, 0, 0, 0))
		_placeholder = ImageTexture3D.new()
		_placeholder.create(Image.FORMAT_RGBAH, 1, 1, 1, false, [img])
		var im2 := Image.create_empty(1, 1, false, Image.FORMAT_R8)
		im2.fill(Color(0, 0, 0, 0))
		_placeholder_2d = ImageTexture.create_from_image(im2)
	for c in ["gi_near_r", "gi_near_g", "gi_near_b", "gi_far_r", "gi_far_g", "gi_far_b", "gi_occ", "gi_age"]:
		RenderingServer.global_shader_parameter_set(StringName(c), _placeholder)
	_pub_near = [null, null, null]
	RenderingServer.global_shader_parameter_set(&"gi_chunk_mask", _placeholder_2d)
	RenderingServer.global_shader_parameter_set(&"gi_roof", _placeholder_2d)
	RenderingServer.global_shader_parameter_set(&"gi_roof_info", Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_set(&"gi_occ_origin", Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_set(&"gi_near_min", Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_set(&"gi_far_min", Vector4(0, 0, 0, 0))


# ================================================================== options

var _opts_live := false # options are applied (node started)
var _pulling := false
var _applying_preset := false
var _pending_opts: Array[StringName] = []


## Applies a quality preset (Preset.LOW .. Preset.ULTRA) to the Quality values.
func apply_preset(preset: int) -> void:
	quality_preset = clampi(preset, 0, Preset.CUSTOM)


## Sets an option by property name ("intensity") or GoyGIConfig key ("gi_power").
func set_option(key: StringName, value: Variant) -> void:
	var prop: StringName = OPTION_KEYS.get(String(key), key)
	if prop == &"multi_bounce" and typeof(value) == TYPE_INT:
		value = int(value) >= 2
	set(prop, value)


func get_option(key: StringName) -> Variant:
	return get(OPTION_KEYS.get(String(key), key))


## Every option of this node as a Dictionary (property name -> value).
func get_options() -> Dictionary:
	var d := {}
	for p in _option_props():
		d[p] = get(p)
	return d


## Sets several options at once ({"intensity": 1.5, "sky_rays": 12, ...}).
func set_options(d: Dictionary) -> void:
	for k in d:
		set_option(StringName(k), d[k])


static func _option_props() -> Array[StringName]:
	var out: Array[StringName] = [&"quality_preset"]
	out.append_array(QUALITY_PROPS)
	for k: String in OPTION_KEYS:
		var p: StringName = OPTION_KEYS[k]
		if not out.has(p):
			out.append(p)
	out.append(&"ambient_color")
	return out


## Quality preset for this device's GPU: 0 Low (older / entry phones: Mali-G52,
## Mali-G57, Adreno 5xx...), 1 Medium (mid-range phones, integrated PC GPUs),
## 2 High (recent phones: Adreno 7xx, Mali-G710+, Immortalis), 3 Ultra
## (desktop GPUs). Use device_info() to write your own rules.
static func recommended_preset() -> int:
	return int(device_info()["tier"])


## Information to choose settings per device in your own scripts:
## {"adapter", "vendor", "mobile", "cores", "memory_mb", "tier"}.
static func device_info() -> Dictionary:
	var adapter := RenderingServer.get_video_adapter_name()
	var vendor := RenderingServer.get_video_adapter_vendor()
	var a := adapter.to_lower()
	var mobile := OS.has_feature("mobile")
	var mem := int(OS.get_memory_info().get("physical", 0)) / (1024 * 1024)
	var tier := 3
	if a.contains("llvmpipe") or a.contains("swiftshader") or a.contains("lavapipe"):
		tier = 0
	elif mobile:
		tier = 1
		var low := ["mali-t", "mali-g31", "mali-g51", "mali-g52", "mali-g57", "mali-g68", "mali-g71", "mali-g72", "mali-g76",
				"adreno (tm) 3", "adreno (tm) 4", "adreno (tm) 5", "adreno (tm) 610", "adreno (tm) 612", "adreno (tm) 613", "powervr"]
		var high := ["adreno (tm) 7", "adreno (tm) 8", "mali-g710", "mali-g715", "mali-g720", "mali-g925", "immortalis", "xclipse"]
		for k: String in low:
			if a.contains(k):
				tier = 0
		for k: String in high:
			if a.contains(k):
				tier = 2
		if mem > 0 and mem < 3500:
			tier = 0
	elif (a.contains("intel") and not a.contains("arc")) or a.contains("radeon(tm) graphics") or a.contains("vega"):
		tier = 1
	return {"adapter": adapter, "vendor": vendor, "mobile": mobile, "cores": OS.get_processor_count(), "memory_mb": mem, "tier": tier}


func _preset_changed() -> void:
	if quality_preset < Preset.CUSTOM and is_node_ready():
		_fill_preset(quality_preset)
	_option_changed(&"quality_preset")


func _fill_preset(p: int) -> void:
	var t: Array = PRESET_TIERS[clampi(p, 0, PRESET_TIERS.size() - 1)]
	var r: Dictionary = GoyGIConfig.GI_RESOLUTIONS[t[0]]
	var b: Dictionary = GoyGIConfig.GI_RAY_BUDGETS[t[2]]
	var u: Dictionary = GoyGIConfig.GI_UPDATE_BUDGETS[t[3]]
	_applying_preset = true
	volume_size = r["size"]
	voxel_size = r["cell"]
	max_vpls = t[1]
	sky_rays = b["sky_rays"]
	march_steps = b["steps"]
	dynamic_rays = b["dyn_rays"]
	update_slices = u["slices"]
	cold_refresh = u["cold"]
	chunk_budget = u["chunk_budget"]
	filtering = t[4]
	if t.size() > 5:
		fast_triplanar = bool(t[5])
		normal_maps = bool(t[6])
	_applying_preset = false
	if Engine.is_editor_hint():
		notify_property_list_changed()


func _option_changed(prop: StringName) -> void:
	if _pulling or not is_node_ready():
		return
	if not _applying_preset and QUALITY_PROPS.has(prop) and quality_preset != Preset.CUSTOM:
		quality_preset = Preset.CUSTOM # an edited value: the preset no longer applies
	if not _opts_live:
		return
	if _pending_opts.is_empty():
		_flush_options.call_deferred()
	if not _pending_opts.has(prop):
		_pending_opts.append(prop)


func _flush_options() -> void:
	var keys := _pending_opts.duplicate()
	_pending_opts.clear()
	if keys.size() == 1:
		_apply_options(keys[0])
	elif not keys.is_empty():
		_apply_options(&"")
		if keys.has(&"multi_bounce") or keys.has(&"bounce_strength"):
			_on_lighting_changed(true)


func _follow_active() -> bool:
	if Engine.is_editor_hint():
		return editor_preview # the plugin's own preview node uses the Project Settings
	return follow_game_settings


## Game settings / GoyGIConfig changed (key "" = everything).
func _on_settings_changed(key: String) -> void:
	if not _follow_active():
		return
	_pull_config()
	_apply_options(OPTION_KEYS.get(key, StringName(key)))


## Copies the GoyGIConfig values (game settings) into this node's options.
func _pull_config() -> void:
	_pulling = true
	for k: String in OPTION_KEYS:
		var v: Variant = GoyGIConfig.get_value(k)
		if v == null:
			continue
		var prop: StringName = OPTION_KEYS[k]
		if prop == &"multi_bounce":
			v = int(v) >= 2
		set(prop, v)
	var q: Dictionary = GoyGIConfig.get_gi_config()
	volume_size = q.get("size", volume_size)
	voxel_size = float(q.get("cell", voxel_size))
	max_vpls = int(q.get("vpls", max_vpls))
	sky_rays = int(q.get("sky_rays", sky_rays))
	march_steps = int(q.get("steps", march_steps))
	dynamic_rays = int(q.get("dyn_rays", dynamic_rays))
	update_slices = int(q.get("slices", update_slices))
	cold_refresh = int(q.get("cold", cold_refresh))
	chunk_budget = int(q.get("chunk_budget", chunk_budget))
	var amb := GoyGIConfig.get_ambient_color()
	ambient_color = Color(amb.r, amb.g, amb.b) / GoyGIConfig.AMBIENT_MAX
	_pulling = false


func _quality_from_options() -> Dictionary:
	var vs := Vector3i((volume_size.x + 3) / 4 * 4, (volume_size.y + 3) / 4 * 4, (volume_size.z + 3) / 4 * 4)
	vs = vs.clamp(Vector3i(8, 8, 8), Vector3i(256, 96, 256))
	return {"size": vs, "cell": clampf(voxel_size, 0.1, 4.0), "vpls": clampi(max_vpls, 16, 256),
			"sky_rays": clampi(sky_rays, 1, 32), "steps": clampi(march_steps, 8, 200), "dyn_rays": clampi(dynamic_rays, 8, MAX_VPLS),
			"slices": clampi(update_slices, 1, 16), "cold": clampi(cold_refresh, 1, 64), "chunk_budget": clampi(chunk_budget, 1, 32)}


## Applies the node's options to the running GI (prop = the changed one, "" all).
func _apply_options(prop: StringName) -> void:
	_enabled = gi_enabled
	_power = maxf(intensity, 0.0)
	var q: Dictionary = _quality_from_options()
	if q != _quality:
		var res_changed: bool = _quality.get("size") != q.get("size") or _quality.get("cell") != q.get("cell")
		_quality = q
		if res_changed or _near.sets.is_empty():
			_quality_dirty = true
		else:
			_apply_quality_params()
	_bounces = 2 if multi_bounce else 1
	_bounce_strength = maxf(bounce_strength, 0.0)
	_interval = 1.0 / float(clampi(update_rate, 1, 240))
	# Smoothness: static part (sky, lamps, multi-bounce) 0 = responsive, 1 = very smooth
	var sm := clampf(smoothing, 0.0, 1.0)
	_alpha = lerpf(0.65, 0.08, sm)
	# (real light changes are caught by the adaptive response and blend fast;
	# a low steady-state blend averages many more sky rays = no blotches)
	_alpha_slow = lerpf(0.5, 0.03, sqrt(sm))
	# Temporal Stabilization: dynamic part (torch...) Off / Low / Medium / High
	var st := clampi(stabilization, 0, 3)
	_alpha_fast = [1.0, 0.8, 0.6, 0.4][st]
	_noise_tol = [0.08, 0.12, 0.2, 0.3][st]
	# Response Speed: how small a light change triggers the immediate blend
	var r := clampf(response, 0.0, 1.0)
	_tune = Vector4(lerpf(0.08, 0.01, r), lerpf(0.45, 0.1, r), lerpf(0.75, 1.0, r), lerpf(0.4, 0.85, r))
	_denoise_w = [0.0, 0.2, 0.35, 0.5][clampi(spatial_filter, 0, 3)]
	_display_smooth = [0.0, 0.35, 0.6, 0.85][clampi(spatial_filter, 0, 3)]
	_adaptive = adaptive_response
	_gov_on = auto_budget
	if not _gov_on:
		gov_level = 0
	_transition_tau = [0.0, 0.06, 0.12, 0.25][clampi(transition, 0, 3)]
	var fm := clampi(filtering, 0, 2)
	_filter = Vector2(float(fm), 1.0 if fm == 0 else 0.55)
	_detail_ao = detail_occlusion
	_debug_view = clampi(debug_view, 0, 5)
	_show_vpls = show_vpls
	_show_rays = show_rays
	_show_regions = show_regions
	_dev_mode = developer_stats
	_tex_flags = Vector2(1.0 if normal_maps else 0.0, 1.0 if fast_triplanar else 0.0)
	_ambient = Color(ambient_color.r, ambient_color.g, ambient_color.b) * GoyGIConfig.AMBIENT_MAX * clampf(ambient, 0.0, 4.0)
	if not is_equal_approx(sky_strength, _env_scale):
		_env_scale = maxf(sky_strength, 0.0)
		_on_lighting_changed(true)
	_chunk_mode = clampi(chunk_mode, 0, 3) as ChunkMode
	_chunk_distance = maxf(chunk_distance, 4.0)
	if prop in [&"multi_bounce", &"bounce_strength", &"gi_bounces", &"gi_bounce_strength", &"bounce"]:
		_on_lighting_changed(true)
	# any lighting-related change counts as motion -> full update rate right away
	_mark_motion()
	_update_occ_globals()
	if (prop == &"gi_enabled" or prop == &"") and _enabled:
		_near.needs_reset = true
	_update_param_globals()
	options_applied.emit()


func is_gpu_active() -> bool:
	return _gpu_ok and _enabled


## Loading screen: compute as many chunks per update as possible.
func set_loading_boost(on: bool) -> void:
	_loading_boost = on


## "Load All Chunks" button: loads every chunk once (with progress), whatever the mode.
func request_load_all() -> void:
	_load_all_request = true
	_mark_motion()


## Chunk cache progress for loading screens / HUD.
func get_chunk_progress() -> Dictionary:
	var total := _cache.passes.size()
	var loaded := 0
	var need := 0
	var need_loaded := 0
	var cam := _camera() if is_inside_tree() else null
	var all := _chunk_mode == ChunkMode.LOAD_ALL or _load_all_request
	for i in total:
		var ok := _cache.passes[i] >= LOAD_PASSES
		if ok:
			loaded += 1
		if all or (cam != null and _chunk_in_range(i, cam.global_position)):
			need += 1
			if ok:
				need_loaded += 1
	return {"total": total, "loaded": loaded, "required": need, "required_loaded": need_loaded,
			"gpu": _gpu_ok, "enabled": _enabled and chunk_cache_enabled, "near_updates": _near.updates,
			"load_all": all}


## True when the GI around the player is ready (loading screens wait for this).
func is_prepared() -> bool:
	if not _gpu_ok or not _enabled:
		return true
	if _gpu_failed:
		return true
	var p := get_chunk_progress()
	return _near.updates >= 6 and int(p["required_loaded"]) >= int(p["required"]) and not _dir_initial


# ================================================================== per frame

## Game camera, or the editor's 3D viewport camera in the editor preview.
func _camera() -> Camera3D:
	if Engine.is_editor_hint():
		var ei: Object = Engine.get_singleton(&"EditorInterface")
		if ei == null:
			return null
		var vp: SubViewport = ei.call(&"get_editor_viewport_3d", 0)
		return vp.get_camera_3d() if vp else null
	return get_viewport().get_camera_3d()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		if not _running:
			return
		# walls / props moved, added or removed: rebuild the occupancy grid
		_geo_check_t -= delta
		if _geo_check_t <= 0.0:
			_geo_check_t = 1.0
			var sig := _geometry_signature()
			if sig != _geo_sig:
				rebuild()
				return
		# the editor only redraws on changes: keep the viewport refreshing so the
		# GI converges and follows light edits live
		var ei: Object = Engine.get_singleton(&"EditorInterface")
		var bc: Control = ei.call(&"get_base_control") if ei else null
		if bc:
			bc.queue_redraw()
	_process_gi(delta)
	_blend_frame(delta)


func _govern(delta: float) -> void:
	if not _gov_on or _loading_boost:
		return
	_gov_ema = lerpf(_gov_ema, delta * 1000.0, 0.05)
	var fps := target_fps
	var target := 1000.0 / float(fps if fps > 0 else 60)
	_gov_t += delta
	if _gov_ema > target * 1.2 and _gov_t > 1.0 and gov_level < 3:
		gov_level += 1
		_gov_t = 0.0
	elif _gov_ema < target * 0.9 and _gov_t > 3.0 and gov_level > 0:
		gov_level -= 1
		_gov_t = 0.0


## Display smoothing: one tiny pass per rendered frame moves the displayed
## volume towards the latest GI result, so GI updates (15 - 60 Hz) never show
## as steps and light changes fade in smoothly at any frame rate.
func _blend_frame(delta: float) -> void:
	var c := _near
	var want := (_transition_tau > 0.0 or _display_smooth > 0.0) and _gpu_ok and _enabled and c.ready and c.blend_sets.size() == 2 \
			and c.disp_proxies.size() == 3 and _blend_pipeline.is_valid()
	if want != _disp_on:
		_disp_on = want
		c.disp_base = Vector3i(1 << 29, 0, 0)
		_publish(c.ready)
	if not want:
		return
	var k := 1.0 - exp(-maxf(delta, 0.0) / _transition_tau) if _transition_tau > 0.0 else 1.0
	var pc := PackedByteArray()
	pc.resize(96)
	var reset := c.disp_base.x == (1 << 29)
	pc.encode_s32(0, c.base.x); pc.encode_s32(4, c.base.y); pc.encode_s32(8, c.base.z); pc.encode_s32(12, 1 if reset else 0)
	pc.encode_s32(16, c.disp_base.x); pc.encode_s32(20, c.disp_base.y); pc.encode_s32(24, c.disp_base.z)
	pc.encode_s32(32, c.size.x); pc.encode_s32(36, c.size.y); pc.encode_s32(40, c.size.z)
	pc.encode_float(48, k); pc.encode_float(52, 0.35); pc.encode_float(56, 1.0 if _adaptive else 0.0)
	pc.encode_float(64, _occ_origin.x); pc.encode_float(68, _occ_origin.y); pc.encode_float(72, _occ_origin.z)
	pc.encode_float(76, occupancy_cell)
	pc.encode_float(80, c.cell); pc.encode_float(84, _display_smooth)
	c.disp_base = c.base
	var uset: RID = c.blend_sets[c.cur]
	RenderingServer.call_on_render_thread(_rt_blend.bind(uset, pc, Vector3i(c.size.x / 4, c.size.y / 4, c.size.z / 4)))


func _rt_blend(uset: RID, pc: PackedByteArray, groups: Vector3i) -> void:
	if _gpu_failed or not uset.is_valid() or not _rd.uniform_set_is_valid(uset):
		return
	var rd := _rd
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _blend_pipeline)
	rd.compute_list_bind_uniform_set(list, uset, 0)
	rd.compute_list_set_push_constant(list, pc, pc.size())
	rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
	rd.compute_list_end()


func _process_gi(delta: float) -> void:
	_update_param_globals()
	if _gpu_failed or _rd == null:
		return
	if not _gpu_ok:
		if _gpu_init_done:
			_gpu_ok = true
			_quality_dirty = true
			_occ_proxy = Texture3DRD.new()
			_occ_proxy.texture_rd_rid = _occ_tex
			RenderingServer.global_shader_parameter_set(&"gi_occ", _occ_proxy)
			if _roof_tex.is_valid():
				_roof_proxy = Texture2DRD.new()
				_roof_proxy.texture_rd_rid = _roof_tex
				RenderingServer.global_shader_parameter_set(&"gi_roof", _roof_proxy)
			_update_occ_globals()
		else:
			return
	_update_chunk_fade(delta)
	if not _enabled:
		_publish(false)
		_frame += 1
		if _frame % 30 == 0:
			_emit_stats()
		return
	if _quality_dirty:
		_quality_dirty = false
		_apply_quality()
		return
	var cam := _camera()
	if cam == null:
		return
	_detect_motion(cam)
	_govern(delta)
	var interval := _interval * _rate_mult * (1.0 + 0.5 * float(gov_level))
	var boosting := _loading_boost or (_load_all_request and not _all_loaded())
	if boosting:
		interval = 0.0
	_accum += delta
	if _accum < interval:
		return
	_accum = fmod(_accum, interval) if (interval > 0.0 and _accum < interval * 4.0) else 0.0
	var t0 := Time.get_ticks_usec()
	_frame += 1
	_jitter += 1
	_rays_cast = 0
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	_update_static_lights(space, cam)
	_update_sun()
	var near_ok := _near.sets.size() == 2
	if near_ok:
		_place_near(cam)
	_gather_vpls(space, cam)
	var vbytes := _vpl.slice(0, maxi(_vpl_count, 1) * VPL_STRIDE).to_byte_array()
	var light_bytes := PackedByteArray()
	if _lights_dirty:
		_lights_dirty = false
		_build_light_list()
		light_bytes = _lights_bytes
	var dir_jobs := _take_direct_jobs(boosting or _dir_initial)
	var cache_jobs: Array = []
	if _cache.ready and chunk_cache_enabled and not _dir_initial:
		_schedule_chunks(cam, cache_jobs, boosting)
	var near_job: Dictionary = _make_near_job() if near_ok else {}
	var pbytes := _make_params()
	_tick_sregions()
	_cpu_usec = Time.get_ticks_usec() - t0
	var readback := _dev_mode and _frame % 8 == 0
	var meter_job := _make_meter_job(cam)
	RenderingServer.call_on_render_thread(_rt_update.bind(pbytes, vbytes, _vpl_count, near_job, cache_jobs, light_bytes, dir_jobs, readback, meter_job))
	# the result of this update is in the other texture set; the render thread
	# executes the dispatch before drawing the frame that uses these globals
	if not near_job.is_empty():
		_near.cur = 1 - _near.cur
		_near.ready = true
	_publish(true)
	_push_debug()
	if _frame % 10 == 0:
		_emit_stats()


# ================================================================== light meter

var _meter_t := 0

## Light meter job: 64 view rays read the GI where they hit (every 3rd update).
func _make_meter_job(cam: Camera3D) -> Dictionary:
	_meter_t += 1
	if _meter_t % 3 != 0 or not _meter_pipeline.is_valid() or not _near.ready or _near.tex.size() < 6:
		return {}
	var c := _near
	var res := (1 - c.cur) * 3 # the near job writes into the other texture set
	var near: Array = [c.tex[res], c.tex[res + 1], c.tex[res + 2]]
	var pc := PackedByteArray()
	pc.resize(128)
	var p := cam.global_position
	var f := -cam.global_basis.z
	var up := cam.global_basis.y
	var ty := tan(deg_to_rad(cam.fov * 0.5))
	var vp := cam.get_viewport().get_visible_rect().size if cam.get_viewport() else Vector2(16, 9)
	var tx := ty * (vp.x / maxf(vp.y, 1.0))
	pc.encode_float(0, p.x); pc.encode_float(4, p.y); pc.encode_float(8, p.z); pc.encode_float(12, 30.0)
	pc.encode_float(16, f.x); pc.encode_float(20, f.y); pc.encode_float(24, f.z); pc.encode_float(28, tx)
	pc.encode_float(32, up.x); pc.encode_float(36, up.y); pc.encode_float(40, up.z); pc.encode_float(44, ty)
	pc.encode_s32(48, c.base.x); pc.encode_s32(52, c.base.y); pc.encode_s32(56, c.base.z); pc.encode_s32(60, 1)
	pc.encode_s32(64, c.size.x); pc.encode_s32(68, c.size.y); pc.encode_s32(72, c.size.z); pc.encode_s32(76, 1 if _dir_size.x > 0 else 0)
	pc.encode_float(80, _occ_origin.x); pc.encode_float(84, _occ_origin.y); pc.encode_float(88, _occ_origin.z); pc.encode_float(92, occupancy_cell)
	var ext := Vector3(_dir_size) * _dir_cell
	pc.encode_float(96, ext.x); pc.encode_float(100, ext.y); pc.encode_float(104, ext.z); pc.encode_float(108, c.cell)
	pc.encode_float(112, 1.3); pc.encode_float(116, _power)
	return {"pc": pc, "near": near}


## What the camera sees, measured from the GI (for eye adaptation / auto
## exposure): {"valid", "luminance" (linear, of the surfaces in view, sky not
## included), "sky" (fraction of the view that is sky / far away),
## "dynamic" (estimated light of dynamic lights such as a flashlight)}.
func get_view_light() -> Dictionary:
	var ok := _running and _gpu_ok and _enabled and _meter.x >= 0.0 and Time.get_ticks_msec() - _meter_ms < 2000
	return {"valid": ok, "luminance": maxf(_meter.x, 0.0), "sky": _meter.y, "log_luminance": _meter.z,
			"dynamic": _dynamic_view_light() if ok else 0.0}


## Rough light of the dynamic lights (flashlight...) on what the camera looks
## at: their direct light is not in the GI caches.
func _dynamic_view_light() -> float:
	var cam := _camera()
	if cam == null or not is_inside_tree():
		return 0.0
	var space := get_world_3d().direct_space_state
	if space == null:
		return 0.0
	var from := cam.global_position
	var dir := -cam.global_basis.z
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 20.0, collision_mask)
	var hit := space.intersect_ray(q)
	var to: Vector3 = hit["position"] if not hit.is_empty() else from + dir * 20.0
	var total := 0.0
	for st: Dictionary in _static.values():
		if not bool(st.get("dyn", false)):
			continue
		var em: GIEmitter = st["em"]
		if not is_instance_valid(em) or not em.is_emitting() or em.light == null:
			continue
		var l := em.light
		var rng := em.get_range()
		var dv := to - l.global_position
		var d := dv.length()
		if d > rng or d < 0.01:
			continue
		var cover := 1.0
		if l is SpotLight3D:
			var sl := l as SpotLight3D
			var axis := -l.global_basis.z
			if axis.dot(dv / d) < cos(deg_to_rad(sl.spot_angle)):
				continue
			cover = clampf(pow(tan(deg_to_rad(sl.spot_angle)) / tan(deg_to_rad(cam.fov * 0.5)), 2.0), 0.05, 1.0)
		var win := clampf(1.0 - pow(d / rng, 4.0), 0.0, 1.0)
		var c := l.light_color.srgb_to_linear()
		var lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		total += em.get_base_energy() * lum * win * win / maxf(d * d, 0.25) * cover * 0.5
	return total


# ================================================================== near volume

func _make_near_job() -> Dictionary:
	var c := _near
	var flags := 0
	if c.needs_reset:
		flags |= 1
	if _bounces >= 2:
		flags |= 2
	if _denoise_w > 0.0 and not c.needs_reset:
		flags |= 4
	if _adaptive:
		flags |= 8
	var boost := _static_boost > 0
	if boost:
		_static_boost -= 1
	_cur_cold = 1 if (boost or c.needs_reset) else c.cold * (1 + gov_level)
	var a_s := 1.0 if c.needs_reset else (_alpha_slow if _adaptive else _alpha)
	if boost:
		a_s = maxf(a_s, 0.4)
	var a_f := 1.0 if c.needs_reset else (_alpha_fast if _adaptive else _alpha)
	var pc := PackedByteArray()
	pc.resize(128)
	pc.encode_s32(0, c.base.x); pc.encode_s32(4, c.base.y); pc.encode_s32(8, c.base.z)
	pc.encode_s32(12, _vpl_count)
	var pb := c.base if c.needs_reset else c.prev_base
	pc.encode_s32(16, pb.x); pc.encode_s32(20, pb.y); pc.encode_s32(24, pb.z)
	pc.encode_s32(28, flags)
	pc.encode_s32(32, c.size.x); pc.encode_s32(36, c.size.y); pc.encode_s32(40, c.size.z)
	pc.encode_s32(44, 0)
	pc.encode_s32(48, 1 if boost else c.slices); pc.encode_s32(52, c.sky_rays); pc.encode_s32(56, _frame); pc.encode_s32(60, c.steps)
	pc.encode_float(64, c.cell); pc.encode_float(68, occupancy_cell)
	pc.encode_float(72, minf(18.0, c.cell * 24.0)) # sky ray length
	pc.encode_float(76, a_s)
	pc.encode_float(80, _occ_origin.x); pc.encode_float(84, _occ_origin.y); pc.encode_float(88, _occ_origin.z)
	pc.encode_float(92, a_f)
	_encode_sky(pc)
	var job := {"pc": pc, "set": c.sets[c.cur], "groups": Vector3i(c.size.x / 4, c.size.y / 4, c.size.z / 4)}
	c.prev_base = c.base
	c.needs_reset = false
	c.updates += 1
	return job


var _cur_cold := 4

func _encode_sky(pc: PackedByteArray) -> void:
	var sky := _get_sky_colors()
	var top: Color = sky[0]
	var hor: Color = sky[1]
	pc.encode_float(96, top.r); pc.encode_float(100, top.g); pc.encode_float(104, top.b)
	pc.encode_float(108, ground_factor)
	pc.encode_float(112, hor.r); pc.encode_float(116, hor.g); pc.encode_float(120, hor.b)
	# multi-bounce gain: hit points reuse last frame's irradiance (albedo is
	# sampled per hit from the albedo grid)
	pc.encode_float(124, 1.0 if _bounces >= 2 else 0.0)


## Shared parameter buffer (binding 14): cache placement, response tuning,
## dynamic update regions, GPU work counters (reset every update).
func _make_params() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(PARAM_BYTES)
	var cache_on := _cache.ready and chunk_cache_enabled
	b.encode_s32(0, _cache.base.x); b.encode_s32(4, _cache.base.y); b.encode_s32(8, _cache.base.z)
	b.encode_s32(12, 1 if cache_on else 0)
	b.encode_s32(16, _cache.size.x); b.encode_s32(20, _cache.size.y); b.encode_s32(24, _cache.size.z)
	b.encode_s32(28, CHUNK)
	b.encode_float(32, _cache.cell); b.encode_float(36, float(_cur_cold)); b.encode_float(40, HOT_UPDATES); b.encode_float(44, 0.0)
	b.encode_float(48, _tune.x); b.encode_float(52, _tune.y); b.encode_float(56, _tune.z); b.encode_float(60, _tune.w)
	var nreg := mini(_region_list.size(), 4)
	b.encode_float(64, _denoise_w); b.encode_float(68, _noise_tol); b.encode_float(72, float(_near.updates)); b.encode_float(76, float(nreg))
	for i in nreg:
		var a: AABB = _region_list[i]
		var o := 80 + i * 32
		b.encode_float(o, a.position.x); b.encode_float(o + 4, a.position.y); b.encode_float(o + 8, a.position.z)
		b.encode_float(o + 16, a.end.x); b.encode_float(o + 20, a.end.y); b.encode_float(o + 24, a.end.z)
	# 208..223 counters (0), 224..255 unused
	b.encode_float(256, float(clampi(int(_quality.get("vpls", 64)), 8, 256))); b.encode_float(264, _bounce_strength * DIRECT_GAIN)
	# direct light cache / albedo grid (same grid as occupancy mip 1)
	var ext := Vector3(_dir_size) * _dir_cell
	b.encode_float(272, _occ_origin.x); b.encode_float(276, _occ_origin.y); b.encode_float(280, _occ_origin.z)
	b.encode_float(284, 1.0 if _dir_size.x > 0 else 0.0)
	b.encode_float(288, ext.x); b.encode_float(292, ext.y); b.encode_float(296, ext.z); b.encode_float(300, 0.6)
	var ns := mini(_sregs.size(), 4)
	for i in ns:
		var a: AABB = _sregs[i][0]
		var o := 304 + i * 32
		b.encode_float(o, a.position.x); b.encode_float(o + 4, a.position.y); b.encode_float(o + 8, a.position.z)
		b.encode_float(o + 16, a.end.x); b.encode_float(o + 20, a.end.y); b.encode_float(o + 24, a.end.z)
	b.encode_float(432, float(ns)); b.encode_float(436, 0.6)
	return b


## Moves the near volume with the camera. Horizontally it follows (with a bit of
## look-ahead); vertically it is pinned to the map when the map fits (jumping or
## climbing never moves it), otherwise it moves with hysteresis.
func _place_near(cam: Camera3D) -> void:
	var c := _near
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	if fwd.length() > 0.01:
		fwd = fwd.normalized()
	var p := cam.global_position + fwd * (float(c.size.x) * c.cell * 0.22)
	var h := float(c.size.y) * c.cell
	var y_lo := floori((_geo_aabb.position.y - 0.5) / c.cell)
	var ty := c.base.y
	if _geo_aabb.size.y <= h - 1.4:
		ty = y_lo
	else:
		var lo := float(c.base.y) * c.cell
		var cy := cam.global_position.y
		if c.needs_reset or cy < lo + 1.6 or cy > lo + h - 3.0:
			ty = maxi(floori((cy - 2.6) / c.cell), y_lo)
	var target := Vector3i(floori(p.x / c.cell) - c.size.x / 2, ty, floori(p.z / c.cell) - c.size.z / 2)
	var d := (target - c.base).abs()
	if c.needs_reset or maxi(d.x, d.z) >= 2 or d.y != 0:
		c.base = target


## Linear sky radiance [zenith, horizon] (from the ProceduralSkyMaterial).
## `scale` overrides the Sky Strength multipliers (used to read the raw sky
## colours for the Ambient Fallback, which must not inherit them).
func _get_sky_colors(scale := -1.0) -> Array:
	var top := Color(0.02, 0.03, 0.06)
	var hor := Color(0.05, 0.06, 0.1)
	var mult := 1.0
	if world_environment != null and world_environment.environment != null:
		var env := world_environment.environment
		mult = env.background_energy_multiplier
		if env.background_mode == Environment.BG_COLOR:
			top = env.background_color.srgb_to_linear()
			hor = top
		elif env.sky != null and env.sky.sky_material is ProceduralSkyMaterial:
			var m := env.sky.sky_material as ProceduralSkyMaterial
			top = m.sky_top_color.srgb_to_linear()
			hor = m.sky_horizon_color.srgb_to_linear()
			mult *= m.sky_energy_multiplier
		elif env.sky != null and env.sky.sky_material is ShaderMaterial:
			# custom sky shaders: read ProceduralSkyMaterial-style uniforms if present
			var sm := env.sky.sky_material as ShaderMaterial
			var t: Variant = sm.get_shader_parameter(&"sky_top_color")
			var h: Variant = sm.get_shader_parameter(&"sky_horizon_color")
			if t is Color:
				top = (t as Color).srgb_to_linear()
			if h is Color:
				hor = (h as Color).srgb_to_linear()
			var e: Variant = sm.get_shader_parameter(&"sky_energy")
			if e is float:
				mult *= float(e)
		elif env.sky != null and env.sky.sky_material is PhysicalSkyMaterial:
			var ps := env.sky.sky_material as PhysicalSkyMaterial
			top = ps.rayleigh_color.srgb_to_linear() * 0.5
			hor = ps.rayleigh_color.srgb_to_linear().lerp(Color(0.8, 0.8, 0.8), 0.5) * 0.6
			mult *= ps.energy_multiplier
		elif env.sky != null and env.sky.sky_material is PanoramaSkyMaterial:
			var cols := _panorama_colors(env.sky.sky_material as PanoramaSkyMaterial)
			top = cols[0]
			hor = cols[1]
			mult *= (env.sky.sky_material as PanoramaSkyMaterial).energy_multiplier
	mult *= scale if scale >= 0.0 else sky_scale * _env_scale
	return [top * mult, hor * mult]


var _pano_cache: Dictionary = {}

## Average linear colour of the upper sky and the horizon band of a panorama.
func _panorama_colors(m: PanoramaSkyMaterial) -> Array:
	if m.panorama == null:
		return [Color(0.3, 0.4, 0.6), Color(0.5, 0.55, 0.6)]
	var id := m.panorama.get_rid()
	if _pano_cache.has(id):
		return _pano_cache[id]
	var img := m.panorama.get_image()
	var out := [Color(0.3, 0.4, 0.6), Color(0.5, 0.55, 0.6)]
	if img != null and not img.is_empty():
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.resize(32, 16, Image.INTERPOLATE_BILINEAR)
		var top := Color(0, 0, 0)
		var hor := Color(0, 0, 0)
		for x in 32:
			for y in 4:
				top += img.get_pixel(x, y + 1)
				hor += img.get_pixel(x, y + 5)
		var fmt: int = int(m.panorama.get_format())
		var srgb: bool = fmt != Image.FORMAT_RGBAH and fmt != Image.FORMAT_RGBAF and fmt != Image.FORMAT_RGBH and fmt != Image.FORMAT_RGBF
		top = top / 128.0
		hor = hor / 128.0
		out = [top.srgb_to_linear() if srgb else top, hor.srgb_to_linear() if srgb else hor]
	_pano_cache[id] = out
	return out


# ================================================================== static lights

func _emitter_dynamic(em: GIEmitter) -> bool:
	if em.mode == GIEmitter.Mode.DYNAMIC:
		return true
	if em.mode == GIEmitter.Mode.STATIC:
		return false
	var a: Array = _auto_dyn.get(em.get_instance_id(), [])
	return not a.is_empty() and Time.get_ticks_msec() < int(a[1])


func _emitter_sig(em: GIEmitter) -> Array:
	var l := em.light
	return [l.global_transform, em.is_emitting(), snappedf(em.get_base_energy(), 0.001), l.light_color]


## Tracks every GI emitter. Static lights (lamps) live in the direct light
## cache: when one is switched, dimmed, moved or removed, only the box it
## reaches is recomputed, and the GI around it is refreshed with a fast blend
## (no leftover light, no restart needed). Lights in AUTO mode that keep
## changing (animated) are treated as dynamic (traced VPLs) until they stop.
func _update_static_lights(_space: PhysicsDirectSpaceState3D, _cam: Camera3D) -> void:
	var now := Time.get_ticks_msec()
	var seen := {}
	for e in get_tree().get_nodes_in_group(&"gi_emitters"):
		var em := e as GIEmitter
		if em == null or em.light == null or not is_instance_valid(em.light):
			continue
		var id := em.get_instance_id()
		seen[id] = true
		var st: Dictionary = _static.get(id, {})
		var sig := _emitter_sig(em)
		var changed: bool = st.is_empty() or st["sig"] != sig
		if em.mode == GIEmitter.Mode.AUTO and not st.is_empty():
			var a: Array = _auto_dyn.get(id, [0, 0])
			if changed:
				a[0] = int(a[0]) + 1
				if int(a[0]) >= 3:
					a[1] = now + 2500
			else:
				a[0] = 0
			_auto_dyn[id] = a
		var dyn := _emitter_dynamic(em)
		var on := not dyn and em.is_emitting()
		if not st.is_empty() and not changed and bool(st["dyn"]) == dyn:
			continue
		var box := _light_box(em) if on else AABB()
		var was_on := not st.is_empty() and bool(st["on"])
		if was_on:
			_light_changed(st["box"])
		if on:
			_light_changed(box)
		if was_on or on:
			_lights_dirty = true
		_static[id] = {"em": em, "sig": sig, "dyn": dyn, "on": on, "box": box}
	for id in _static.keys():
		if not seen.has(id):
			var st: Dictionary = _static[id]
			if bool(st["on"]):
				_light_changed(st["box"])
				_lights_dirty = true
			_static.erase(id)


func _light_box(em: GIEmitter) -> AABB:
	var r := em.get_range() + 0.5
	return AABB(em.light.global_position - Vector3(r, r, r), Vector3(r, r, r) * 2.0)


## The direct light inside box changed: recompute that part of the direct
## cache and refresh the GI that can see it (bounce reaches a few metres beyond).
func _light_changed(box: AABB) -> void:
	_queue_direct(box)
	_add_sregion(box.grow(3.0))
	var ctr := box.get_center()
	_mark_stale_around(ctr, box.size.x * 0.5 + 6.0)
	_mark_motion()


func _add_sregion(box: AABB) -> void:
	for r: Array in _sregs:
		var a: AABB = r[0]
		if a.intersects(box.grow(1.0)):
			r[0] = a.merge(box)
			r[1] = SREG_UPDATES
			return
	_sregs.append([box, SREG_UPDATES])
	while _sregs.size() > 4:
		var last: Array = _sregs.pop_back()
		_sregs[_sregs.size() - 1][0] = (_sregs[_sregs.size() - 1][0] as AABB).merge(last[0])
		_sregs[_sregs.size() - 1][1] = SREG_UPDATES


func _tick_sregions() -> void:
	for i in range(_sregs.size() - 1, -1, -1):
		_sregs[i][1] = int(_sregs[i][1]) - 1
		if int(_sregs[i][1]) <= 0:
			_sregs.remove_at(i)


func _mark_stale_around(p: Vector3, r: float) -> void:
	for i in _cache.passes.size():
		if _cache.passes[i] <= 0:
			continue
		var rc := _chunk_rect(i)
		var dx := maxf(maxf(rc.position.x - p.x, 0.0), p.x - rc.end.x)
		var dz := maxf(maxf(rc.position.y - p.z, 0.0), p.z - rc.end.y)
		if dx * dx + dz * dz <= r * r:
			_cache.stale[i] = 2
			_cache.passes[i] = mini(_cache.passes[i], 1)


func _mark_all_stale() -> void:
	for i in _cache.passes.size():
		if _cache.passes[i] > 0:
			_cache.stale[i] = 2
			_cache.passes[i] = mini(_cache.passes[i], 1)


## Sky / sun / global GI settings changed: refresh everything progressively
## (the old data stays visible until the refresh blends in - no black frames).
func _on_lighting_changed(_all: bool) -> void:
	_mark_all_stale()
	_static_boost = maxi(_static_boost, 8)
	_mark_motion()


# ================================================================== direct light cache

func _sun_on() -> bool:
	return sun != null and is_instance_valid(sun) and sun.is_visible_in_tree() and sun.light_energy > 0.001 \
			and sun.global_basis.z.normalized().y > 0.03


## The sun / moon moved or changed: its direct light is recomputed everywhere.
func _update_sun() -> void:
	var sig: Array = [false]
	if _sun_on():
		sig = [true, snappedf(sun.light_energy, 0.001), sun.light_color, sun.global_basis.z.snapped(Vector3.ONE * 0.001), bounce_scale, sun_bounce]
	if sig == _sun_sig or _dir_size.x <= 0:
		return
	_sun_sig = sig
	_queue_direct(_occ_aabb)
	_on_lighting_changed(true)


func _queue_direct(box: AABB) -> void:
	if _dir_size.x <= 0:
		return
	var nbk := (_dir_size + Vector3i.ONE * (DIR_BRICK - 1)) / DIR_BRICK
	if nbk != _dir_bricks or _dir_dirty.size() != nbk.x * nbk.y * nbk.z:
		_dir_bricks = nbk
		_dir_dirty.resize(_dir_bricks.x * _dir_bricks.y * _dir_bricks.z)
		_dir_dirty.fill(0)
		_dir_ndirty = 0
	var bw := _dir_cell * DIR_BRICK
	var b0 := Vector3i(((box.position - _occ_origin) / bw).floor()).clamp(Vector3i.ZERO, _dir_bricks - Vector3i.ONE)
	var b1 := Vector3i(((box.end - _occ_origin) / bw).ceil()).clamp(Vector3i.ZERO, _dir_bricks)
	for z in range(b0.z, b1.z):
		for y in range(b0.y, b1.y):
			var o := (z * _dir_bricks.y + y) * _dir_bricks.x
			for x in range(b0.x, b1.x):
				if _dir_dirty[o + x] == 0:
					_dir_dirty[o + x] = 1
					_dir_ndirty += 1


func _direct_pending() -> int:
	return _dir_ndirty * DIR_BRICK * DIR_BRICK * DIR_BRICK


## Dirty bricks as dispatches, within DIRECT_BUDGET. A brick costs its texel
## count times (1 + lights whose range reaches it): switching lights OFF is
## cheap and clears within a couple of updates, heavy lamp clusters spread out.
func _take_direct_jobs(unlimited: bool) -> Array:
	var out: Array = []
	if _dir_ndirty <= 0:
		if _dir_initial and _dir_size.x > 0 and not _dir_dirty.is_empty():
			_dir_initial = false
			_on_lighting_changed(true) # everything computed so far saw a partial cache
		return out
	var budget := 1 << 30 if unlimited else DIRECT_BUDGET
	var sun_on := _sun_on()
	var sd := sun.global_basis.z.normalized() if sun_on else Vector3.UP
	var sc := sun.light_color.srgb_to_linear() * sun.light_energy * bounce_scale * maxf(sun_bounce, 0.0) if sun_on else Color(0, 0, 0)
	var reach := _occ_aabb.size.length()
	var boxes: Array[AABB] = []
	for st: Dictionary in _static.values():
		if bool(st["on"]):
			boxes.append(st["box"])
	var nb := _dir_dirty.size()
	var bt := DIR_BRICK * DIR_BRICK * DIR_BRICK
	var bw := _dir_cell * DIR_BRICK
	var k := 0
	while k < nb and budget > 0 and _dir_ndirty > 0:
		var i := (_dir_scan + k) % nb
		k += 1
		if _dir_dirty[i] == 0:
			continue
		var bx := i % _dir_bricks.x
		var by := (i / _dir_bricks.x) % _dir_bricks.y
		var bz := i / (_dir_bricks.x * _dir_bricks.y)
		var wb := AABB(_occ_origin + Vector3(bx, by, bz) * bw, Vector3.ONE * bw)
		var nl := 0
		for lb: AABB in boxes:
			if lb.intersects(wb):
				nl += 1
		if nl > 0 and budget < bt * (1 + nl) and not out.is_empty():
			break # keep it for the next update
		_dir_dirty[i] = 0
		_dir_ndirty -= 1
		budget -= bt * (1 + nl + (1 if sun_on else 0))
		var t0 := Vector3i(bx, by, bz) * DIR_BRICK
		var sz := (t0 + Vector3i.ONE * DIR_BRICK).min(_dir_size) - t0
		var pc := PackedByteArray()
		pc.resize(96)
		pc.encode_s32(0, t0.x); pc.encode_s32(4, t0.y); pc.encode_s32(8, t0.z); pc.encode_s32(12, _lights_n)
		pc.encode_s32(16, sz.x); pc.encode_s32(20, sz.y); pc.encode_s32(24, sz.z); pc.encode_s32(28, 160)
		pc.encode_float(32, _occ_origin.x); pc.encode_float(36, _occ_origin.y); pc.encode_float(40, _occ_origin.z); pc.encode_float(44, _dir_cell)
		pc.encode_float(48, _occ_origin.x); pc.encode_float(52, _occ_origin.y); pc.encode_float(56, _occ_origin.z); pc.encode_float(60, occupancy_cell)
		pc.encode_float(64, sd.x); pc.encode_float(68, sd.y); pc.encode_float(72, sd.z); pc.encode_float(76, 1.0 if sun_on else 0.0)
		pc.encode_float(80, sc.r); pc.encode_float(84, sc.g); pc.encode_float(88, sc.b); pc.encode_float(92, reach)
		out.append([pc, Vector3i((sz.x + 3) / 4, (sz.y + 3) / 4, (sz.z + 3) / 4)])
	_dir_scan = (_dir_scan + k) % maxi(nb, 1)
	if _dir_initial and _dir_ndirty <= 0:
		_dir_initial = false
		_on_lighting_changed(true)
	return out


## Packs the static lights for the direct cache shader (4 x vec4 each).
func _build_light_list() -> void:
	var f := PackedFloat32Array()
	var n := 0
	for st: Dictionary in _static.values():
		if not bool(st["on"]) or n >= MAX_LIGHTS:
			continue
		var em: GIEmitter = st["em"]
		if not is_instance_valid(em) or em.light == null or not is_instance_valid(em.light):
			continue
		var l := em.light
		var p := l.global_position
		var c := l.light_color.srgb_to_linear() * em.get_base_energy() * em.bounce_gain * bounce_scale
		var decay := 1.0
		var axis := Vector3.ZERO
		var cos_cut := -2.0
		var sexp := 1.0
		if l is SpotLight3D:
			var sl := l as SpotLight3D
			decay = sl.spot_attenuation
			axis = (-l.global_basis.z).normalized()
			cos_cut = cos(deg_to_rad(sl.spot_angle))
			sexp = sl.spot_angle_attenuation
		elif l is OmniLight3D:
			decay = (l as OmniLight3D).omni_attenuation
		f.append_array([p.x, p.y, p.z, em.get_range(), c.r, c.g, c.b, decay,
				axis.x, axis.y, axis.z, cos_cut, sexp, 0.0, 0.0, 0.0])
		n += 1
	if n == 0:
		f.resize(16)
	_lights_n = n
	_n_static = n
	_lights_bytes = f.to_byte_array()


# ================================================================== VPL gathering

# trace target (VPLs are appended here)
var _tgt := PackedFloat32Array()
var _tgt_n := 0
var _tgt_max := MAX_VPLS
var _trace_hits := PackedVector3Array()

func _gather_vpls(space: PhysicsDirectSpaceState3D, cam: Camera3D) -> void:
	# static lights and the sun live in the GPU pool; only dynamic lights are traced per update
	var budget: int = mini(int(_quality.get("dyn_rays", 64)), MAX_VPLS)
	var cam_pos := cam.global_position
	debug_rays.clear()
	var dyn: Array = []
	for e in get_tree().get_nodes_in_group(&"gi_emitters"):
		var em := e as GIEmitter
		if em == null or not em.is_emitting() or not _emitter_dynamic(em):
			continue
		var dist := em.light.global_position.distance_to(cam_pos)
		if dist > em.get_range() + cull_margin + 12.0:
			continue
		dyn.append([em.priority / (1.0 + dist * 0.15), em])
	dyn.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	_tgt = _vpl
	_tgt_n = 0
	_tgt_max = budget
	var total_score := 0.0
	for i in mini(dyn.size(), 4):
		total_score += float(dyn[i][0])
	var now := Time.get_ticks_msec()
	var remaining := budget
	for i in mini(dyn.size(), 4):
		if remaining < 4:
			break
		var em: GIEmitter = dyn[i][1]
		var share := int(round(float(budget) * float(dyn[i][0]) / maxf(total_score, 0.001)))
		var n := clampi(share, 4, remaining)
		n = mini(n, maxi(int(budget * em.max_share * 1.6), 8))
		_trace_hits.clear()
		var before := _tgt_n
		_trace_light(space, em, n, true, fposmod(float(_jitter) * 0.618034, 1.0), em.light.light_energy)
		remaining -= maxi(_tgt_n - before, 1)
		_update_region(em, now)
	_n_dyn = _tgt_n
	_vpl = _tgt
	_vpl_count = _tgt_n
	_build_region_list(now)


## Update region of a dynamic light: everything near the surfaces it lit this
## update and the last one (so the light it leaves behind fades out quickly).
func _update_region(em: GIEmitter, now: int) -> void:
	var id := em.get_instance_id()
	var box := AABB(em.light.global_position, Vector3.ZERO)
	for p in _trace_hits:
		box = box.expand(p)
	box = box.grow(REGION_GROW)
	var old: Array = _regions.get(id, [])
	var merged := box if old.is_empty() else box.merge(old[0])
	_regions[id] = [box, now + 600, merged]


func _build_region_list(now: int) -> void:
	_region_list.clear()
	for id in _regions.keys():
		var r: Array = _regions[id]
		if now > int(r[1]):
			_regions.erase(id)
			continue
		var a: AABB = r[2]
		if _region_list.size() < 4:
			_region_list.append(a)
		else:
			_region_list[3] = _region_list[3].merge(a)
		r[2] = r[0] # next update: merge with this box only


func _trace_light(space: PhysicsDirectSpaceState3D, em: GIEmitter, n: int, dynamic: bool, phase: float, energy_in: float) -> void:
	var light := em.light
	var xf := light.global_transform
	var origin := xf.origin
	var basis := xf.basis.orthonormalized()
	var energy := energy_in * em.bounce_gain
	var color := light.light_color.srgb_to_linear()
	var rng_len := em.get_range()
	var decay := 1.0
	var is_spot := light is SpotLight3D
	var cos_cut := -1.0
	var spot_exp := 1.0
	var solid_angle := 4.0 * PI
	var cos_max := -1.0
	if is_spot:
		var s := light as SpotLight3D
		decay = s.spot_attenuation
		cos_cut = cos(deg_to_rad(s.spot_angle))
		spot_exp = s.spot_angle_attenuation
		cos_max = lerpf(1.0, cos_cut, em.cone_coverage)
		solid_angle = TAU * (1.0 - cos_max)
	elif light is OmniLight3D:
		decay = (light as OmniLight3D).omni_attenuation
	var d_omega := solid_angle / float(n)
	var rot := phase * TAU * 0.61803 + float(_jitter) * 2.39996 * (1.0 if dynamic else 0.0)
	for i in n:
		if _tgt_n >= _tgt_max:
			break
		# stratified (spherical Fibonacci) directions inside the cone, rotated every update
		var u := (float(i) + phase) / float(n)
		var cz := 1.0 - u * (1.0 - cos_max)
		var sz := sqrt(maxf(0.0, 1.0 - cz * cz))
		var ph := float(i) * 2.39996323 + rot
		var local := Vector3(sz * cos(ph), sz * sin(ph), -cz)
		var dir := basis * local
		_query.from = origin
		_query.to = origin + dir * rng_len
		_rays_cast += 1
		var hit := space.intersect_ray(_query)
		if hit.is_empty():
			continue
		var hp: Vector3 = hit["position"]
		var hn: Vector3 = hit["normal"]
		var dist := maxf(origin.distance_to(hp), 0.05)
		var cos_i := -dir.dot(hn)
		if cos_i <= 0.0:
			continue
		# Godot's light falloff (scene_forward_lights_inc.glsl)
		var nd := dist / rng_len
		nd = nd * nd
		nd = nd * nd
		var window := maxf(1.0 - nd, 0.0)
		window *= window
		var atten := window * pow(dist, -decay)
		if is_spot:
			var scos := maxf(cz, cos_cut)
			var rim := maxf(0.0001, (1.0 - scos) / (1.0 - cos_cut))
			atten *= maxf(1.0 - pow(rim, spot_exp), 0.0)
		if atten <= 0.0:
			continue
		var albedo := _get_albedo(hit.get("collider"), hit.get("shape", 0))
		# patch area seen by this ray and the irradiance on it:
		#   E = PI * energy * atten * cos_i    A = d_omega * dist^2 / cos_i
		var area := minf(d_omega * dist * dist / maxf(cos_i, 0.2), 4.0)
		var e_a := PI * energy * atten * d_omega * dist * dist * (cos_i / maxf(cos_i, 0.2))
		if dynamic:
			_trace_hits.append(hp)
			if _show_rays:
				debug_rays.append(origin)
				debug_rays.append(hp)
		_push_vpl(hp, hn, area, Color(color.r * albedo.r * e_a, color.g * albedo.g * e_a, color.b * albedo.b * e_a), albedo, dynamic)


func _push_vpl(pos: Vector3, nrm: Vector3, area: float, flux: Color, albedo: Color, dynamic: bool) -> void:
	var lum := maxf(flux.r, maxf(flux.g, flux.b)) * bounce_scale
	if lum <= 0.0 or _tgt_n >= _tgt_max:
		return
	# radius where the contribution falls below the cutoff: flux / (PI^2 r^2) = cutoff
	var r_cut := clampf(sqrt(lum / (PI * PI * vpl_cutoff)), 0.4, vpl_max_range)
	var o := _tgt_n * VPL_STRIDE
	if _tgt.size() < o + VPL_STRIDE:
		_tgt.resize(o + VPL_STRIDE)
	var p := pos + nrm * 0.08
	_tgt[o] = p.x; _tgt[o + 1] = p.y; _tgt[o + 2] = p.z; _tgt[o + 3] = area
	_tgt[o + 4] = flux.r * bounce_scale; _tgt[o + 5] = flux.g * bounce_scale; _tgt[o + 6] = flux.b * bounce_scale
	_tgt[o + 7] = r_cut * r_cut
	_tgt[o + 8] = nrm.x; _tgt[o + 9] = nrm.y; _tgt[o + 10] = nrm.z; _tgt[o + 11] = 1.0 if dynamic else 0.0
	_tgt[o + 12] = albedo.r; _tgt[o + 13] = albedo.g; _tgt[o + 14] = albedo.b; _tgt[o + 15] = 0.0
	_tgt_n += 1


# ================================================================== map-wide sun (chunk cache)

# ================================================================== chunk cache

## Lays the chunk grid out over the map. Called on every start / rebuild: when
## the grid is unchanged (a prop moved, a light was added) the computed light,
## the fade-in state and the per-chunk progress are KEPT - only a changed grid
## needs new textures and a fresh computation.
func _setup_cache() -> void:
	var c := _cache
	var ext := _geo_aabb.grow(1.0)
	var cell := maxf(CACHE_CELL, maxf(maxf(ext.size.x, ext.size.z) / 192.0, ext.size.y / 32.0))
	var base := Vector3i((ext.position / cell).floor())
	var end := Vector3i((ext.end / cell).ceil())
	var sz := end - base
	sz.x = int(ceil(float(sz.x) / CHUNK)) * CHUNK
	sz.z = int(ceil(float(sz.z) / CHUNK)) * CHUNK
	sz.y = clampi(int(ceil(float(sz.y) / 4.0)) * 4, 4, 32)
	var nx := sz.x / CHUNK
	var nz := sz.z / CHUNK
	if c.ready and c.cell == cell and c.base == base and c.size == sz and c.nx == nx and c.nz == nz:
		return # same grid: keep everything that is already computed
	c.cell = cell
	c.base = base
	c.size = sz
	c.nx = nx
	c.nz = nz
	var n := c.nx * c.nz
	c.passes.resize(n)
	c.passes.fill(0)
	c.stale.resize(n)
	c.stale.fill(0)
	c.vis.resize(n)
	c.vis.fill(0.0)
	c.mask.resize(n)
	c.mask.fill(0)
	c.ready = false
	print("GIManager: chunk cache %s cells @ %.2f m, %d x %d chunks" % [c.size, c.cell, c.nx, c.nz])


## Allocates (or re-allocates) the chunk cache textures when the grid changed.
## Without this a map that grew after a rebuild kept sampling a texture of the
## old size: the cache was silently wrong / empty from then on.
func _ensure_cache_alloc() -> void:
	if not chunk_cache_enabled or _cache.size.x <= 0 or _cache.nx <= 0 or _cache.nz <= 0:
		return
	var key := Vector3i(_cache.nx, _cache.nz, _cache.size.y)
	if _cache.ready and _cache.alloc_key == key:
		return
	_cache.alloc_key = key
	_cache.ready = false
	RenderingServer.call_on_render_thread(_rt_alloc_cache.bind(_cache.size, _cache.nx, _cache.nz))

# ---- in place rebuild ------------------------------------------------------

## Rebuilds everything (occupancy grid, caches, GPU resources). Call it after
## moving / adding / removing static level geometry at run time. In the editor
## the preview does this by itself when collision shapes change.
##
## When the occupancy grid keeps its size the GPU resources are NOT re-created:
## the new occupancy / albedo / roof data is uploaded into the live textures and
## the lighting is refreshed progressively. A full stop() + start() threw away
## the whole chunk cache and the near volume every single time, which is why
## every edit in the editor showed raw, unconverged voxels until the map had
## been recomputed from scratch (and why editing was so expensive).
func rebuild() -> void:
	if _running and _gpu_ok and _gpu_init_done and not _near.tex.is_empty() and _soft_rebuild():
		return
	var was := _running
	stop()
	if was:
		start()


func _soft_rebuild() -> bool:
	if _rd == null or _gpu_failed:
		return false
	var old_size := _occ_size
	var t0 := Time.get_ticks_usec()
	_build_occupancy()
	if _occ_bytes.is_empty() or _occ_size != old_size or _roof_bytes.is_empty():
		return false # a different grid: the GPU resources have to be re-created
	_setup_cache()
	_geo_sig = _geometry_signature()
	var occ := _occ_bytes
	var alb := _alb_bytes
	RenderingServer.call_on_render_thread(_rt_upload_world.bind(occ, alb, _roof_bytes.duplicate()))
	_alb_bytes = PackedByteArray() # uploaded
	_ensure_cache_alloc()
	_queue_direct(_occ_aabb) # the whole direct cache is stale (the geometry moved)
	_lights_dirty = true
	_static_boost = maxi(_static_boost, 8)
	_on_lighting_changed(true)
	_mark_motion()
	_update_occ_globals()
	print("GIManager: occupancy rebuilt in place in %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	return true


## World rect (x, z) of chunk i.
func _chunk_rect(i: int) -> Rect2:
	var cx := i % _cache.nx
	var cz := i / _cache.nx
	var s := float(CHUNK) * _cache.cell
	return Rect2(float(_cache.base.x) * _cache.cell + cx * s, float(_cache.base.z) * _cache.cell + cz * s, s, s)


func _chunk_dist(i: int, p: Vector3) -> float:
	var rc := _chunk_rect(i)
	var dx := maxf(maxf(rc.position.x - p.x, 0.0), p.x - rc.end.x)
	var dz := maxf(maxf(rc.position.y - p.z, 0.0), p.z - rc.end.y)
	return sqrt(dx * dx + dz * dz)


func _chunk_in_range(i: int, p: Vector3) -> bool:
	if _load_all_request:
		return true
	match _chunk_mode:
		ChunkMode.LOAD_ALL:
			return true
		ChunkMode.PLAYER_ONLY:
			return _chunk_dist(i, p) <= 0.0
		ChunkMode.EXTENDED:
			return _chunk_dist(i, p) <= _chunk_distance * 2.0
	return _chunk_dist(i, p) <= _chunk_distance


func _all_loaded() -> bool:
	for v in _cache.passes:
		if v < LOAD_PASSES:
			return false
	return true



## Picks the chunk passes of this update: unloaded chunks in range first
## (player chunk -> nearest), then stale ones, then refinement. Chunks out of
## range are kept as they are (cached), only refreshed when stale.
func _schedule_chunks(cam: Camera3D, jobs: Array, boosting: bool) -> void:
	_cache_chunks_last.clear()
	_cache_jobs_last = 0
	var budget := MAX_CACHE_JOBS if boosting else int(_quality.get("chunk_budget", 2))
	var p := cam.global_position
	var cands: Array = []
	var c := _cache
	for i in c.passes.size():
		var pas := c.passes[i]
		var inr := _chunk_in_range(i, p)
		var pr := -1
		if inr and pas < LOAD_PASSES:
			pr = 0
		elif inr and c.stale[i] != 0:
			pr = 1
		elif inr and pas < REFINE_PASSES:
			pr = 2
		elif c.stale[i] != 0 and pas > 0:
			pr = 3
		if pr < 0:
			continue
		cands.append(float(pr) * 100000.0 + _chunk_dist(i, p) * 10.0 + float(i) * 1e-5)
		cands.append(i)
	if cands.is_empty():
		if _load_all_request and _all_loaded():
			_load_all_request = false
		return
	var order: Array = []
	for k in range(0, cands.size(), 2):
		order.append([cands[k], cands[k + 1]])
	order.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for k in mini(budget, order.size()):
		var i: int = order[k][1]
		var pas := c.passes[i]
		var relit := c.stale[i] == 2 # light changed there: replace, don't average with the old light
		var flags := 16
		if pas == 0:
			flags |= 1
		if _bounces >= 2:
			flags |= 2
		if pas > 0 and _denoise_w > 0.0:
			flags |= 4
		var cx := (i % c.nx) * CHUNK
		var cz := (i / c.nx) * CHUNK
		var pc := PackedByteArray()
		pc.resize(128)
		pc.encode_s32(0, c.base.x); pc.encode_s32(4, c.base.y); pc.encode_s32(8, c.base.z)
		pc.encode_s32(12, 0)
		pc.encode_s32(16, cx); pc.encode_s32(20, 0); pc.encode_s32(24, cz)
		pc.encode_s32(28, flags)
		pc.encode_s32(32, c.size.x); pc.encode_s32(36, c.size.y); pc.encode_s32(40, c.size.z)
		pc.encode_s32(44, 0)
		pc.encode_s32(48, 0); pc.encode_s32(52, maxi(int(_quality.get("sky_rays", 4)), 3)); pc.encode_s32(56, _frame * 7 + k)
		pc.encode_s32(60, 48)
		pc.encode_float(64, c.cell); pc.encode_float(68, occupancy_cell)
		pc.encode_float(72, 18.0)
		pc.encode_float(76, 1.0 if (pas == 0 or relit) else maxf(1.0 / float(pas + 1), 0.12))
		pc.encode_float(80, _occ_origin.x); pc.encode_float(84, _occ_origin.y); pc.encode_float(88, _occ_origin.z)
		pc.encode_float(92, 1.0)
		_encode_sky(pc)
		jobs.append({"pc": pc, "groups": Vector3i(CHUNK / 4, c.size.y / 4, CHUNK / 4),
				"pos": Vector3(cx, 0, cz), "size": Vector3(CHUNK, c.size.y, CHUNK)})
		c.passes[i] = pas + 1
		c.stale[i] = 0
		_cache_chunks_last.append(i)
		if pas + 1 == LOAD_PASSES:
			# neighbours computed earlier saw this chunk empty: refine them twice more
			for nb: int in [i - 1, i + 1, i - c.nx, i + c.nx]:
				if nb >= 0 and nb < c.passes.size() and c.passes[nb] >= REFINE_PASSES:
					c.passes[nb] = REFINE_PASSES - 2
	_cache_jobs_last = jobs.size()
	c.updates += 1


func _update_chunk_fade(delta: float) -> void:
	var c := _cache
	if not c.ready:
		return
	var changed := false
	for i in c.vis.size():
		# A chunk fades IN once it has been computed, and never fades out again:
		# it still holds the last light of its column. Fading it back down while
		# it is recomputed (a lamp switched, the sun moved, geometry edited) used
		# to dim every affected chunk to a third - or, for a chunk whose pass
		# counter was reset, to black. That is what "missing chunks" looked like.
		var target := 1.0 if c.passes[i] >= LOAD_PASSES else clampf(float(c.passes[i]) / float(LOAD_PASSES), 0.0, 1.0)
		var v := c.vis[i]
		if v < target:
			v = minf(target, v + delta * 2.0)
		if v != c.vis[i]:
			c.vis[i] = v
			c.mask[i] = int(round(v * 255.0))
			changed = true
	if changed or c.dirty_mask:
		c.dirty_mask = false
		RenderingServer.call_on_render_thread(_rt_update_mask.bind(c.mask.duplicate()))


# ================================================================== quality

func _apply_quality() -> void:
	var q := _quality
	_near.size = q.get("size", Vector3i(48, 16, 48))
	_near.cell = float(q.get("cell", 0.6))
	_apply_quality_params()
	_near.needs_reset = true
	_near.ready = false
	_publish(false)
	if not _cache.ready and _cache.tex.is_empty() and chunk_cache_enabled:
		_ensure_cache_alloc()
	RenderingServer.call_on_render_thread(_rt_alloc.bind(_near, _near.size))


func _apply_quality_params() -> void:
	var q := _quality
	_near.slices = int(q.get("slices", 2))
	_near.cold = int(q.get("cold", 4))
	_near.sky_rays = int(q.get("sky_rays", 4))
	_near.steps = int(q.get("steps", 56))


# ================================================================== globals

func _set_fallback_globals() -> void:
	RenderingServer.global_shader_parameter_set(&"gi_near_min", Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_set(&"gi_far_min", Vector4(0, 0, 0, 0))
	_update_param_globals()


## The Environment's ambient light (linear), the light plain Godot adds to every
## surface. The GoyGI materials disable it while the GI is on (the traced sky
## light replaces it, so it must not be counted twice); with the GI off it is
## fed back through gi_fallback instead.
func _env_ambient() -> Color:
	if world_environment == null or not is_instance_valid(world_environment) or world_environment.environment == null:
		return Color(0, 0, 0)
	var env := world_environment.environment
	if env.ambient_light_source == Environment.AMBIENT_SOURCE_DISABLED:
		return Color(0, 0, 0)
	var c := env.ambient_light_color.srgb_to_linear()
	var sky_contrib := clampf(env.ambient_light_sky_contribution, 0.0, 1.0)
	if sky_contrib > 0.0:
		# Godot blends the ambient colour with the sky colour
		c = c.lerp((_get_sky_colors(1.0)[1] as Color), sky_contrib)
	return c * maxf(env.ambient_light_energy, 0.0)


var _last_params := Vector4(-1, -1, -1, -1)
var _last_fallback := Color(-1, -1, -1)
var _last_debug := Vector4(-1, -1, -1, -1)
var _last_filter := Vector4(-1, -1, -1, -1)

func _update_param_globals() -> void:
	var on := _enabled and _gpu_ok
	var p := Vector4(_power, float(_debug_view), _tex_flags.x, _tex_flags.y)
	if p != _last_params:
		_last_params = p
		RenderingServer.global_shader_parameter_set(&"gi_params", p)
	# Ambient Contribution: optional flat light (default 0 = off, physically
	# based look). Kept separate from the GI, also applies with GI off.
	var fb := _ambient
	if not _enabled:
		# GI off: hand the Environment's ambient light back to the materials, so a
		# scene with the GI switched off looks like plain Godot instead of losing
		# the ambient contribution on every converted surface.
		fb += _env_ambient()
	if not fb.is_equal_approx(_last_fallback):
		_last_fallback = fb
		RenderingServer.global_shader_parameter_set(&"gi_fallback", Vector4(fb.r, fb.g, fb.b, 0.0))
	var fl := Vector4(_filter.x, _filter.y, 0.0, 0.0)
	if fl != _last_filter:
		_last_filter = fl
		RenderingServer.global_shader_parameter_set(&"gi_filter", fl)
	var dbg := Vector4(float(_debug_view), float(_near.updates), HOT_UPDATES, 1.0 if on else 0.0)
	if dbg != _last_debug:
		_last_debug = dbg
		RenderingServer.global_shader_parameter_set(&"gi_debug", dbg)


func _publish(active: bool) -> void:
	var c := _near
	# Texture globals are only re-set when they really change: every set makes
	# Godot rebuild the uniform sets of ALL materials using them (with display
	# smoothing on, the displayed textures never change).
	if _disp_on and c.disp_proxies.size() == 3:
		_set_near_tex(c.disp_proxies[0], c.disp_proxies[1], c.disp_proxies[2])
	elif c.proxies.size() == 6:
		var o := c.cur * 3
		_set_near_tex(c.proxies[o], c.proxies[o + 1], c.proxies[o + 2])
	var on := active and _gpu_ok and _enabled and c.ready and c.proxies.size() == 6
	if on:
		var mn := Vector3(c.base) * c.cell
		var mx := Vector3(c.base + c.size) * c.cell
		var inv := Vector3.ONE / (Vector3(c.size) * c.cell)
		RenderingServer.global_shader_parameter_set(&"gi_near_inv", Vector4(inv.x, inv.y, inv.z, c.cell))
		RenderingServer.global_shader_parameter_set(&"gi_near_min", Vector4(mn.x, mn.y, mn.z, 1.0))
		RenderingServer.global_shader_parameter_set(&"gi_near_max", Vector4(mx.x, mx.y, mx.z, 0.0))
	else:
		RenderingServer.global_shader_parameter_set(&"gi_near_min", Vector4(0, 0, 0, 0))
	var k := _cache
	var con := _gpu_ok and _enabled and k.ready and chunk_cache_enabled and k.proxies.size() == 3
	if con:
		var mn := Vector3(k.base) * k.cell
		var mx := Vector3(k.base + k.size) * k.cell
		var inv := Vector3.ONE / (Vector3(k.size) * k.cell)
		RenderingServer.global_shader_parameter_set(&"gi_far_inv", Vector4(inv.x, inv.y, inv.z, k.cell))
		RenderingServer.global_shader_parameter_set(&"gi_far_min", Vector4(mn.x, mn.y, mn.z, 1.0))
		RenderingServer.global_shader_parameter_set(&"gi_far_max", Vector4(mx.x, mx.y, mx.z, 0.0))
		RenderingServer.global_shader_parameter_set(&"gi_chunk_info", Vector4(float(CHUNK) * k.cell, float(k.nx), float(k.nz), 0.0))
	else:
		RenderingServer.global_shader_parameter_set(&"gi_far_min", Vector4(0, 0, 0, 0))


var _pub_near: Array = [null, null, null]

func _set_near_tex(r: Texture, g: Texture, b: Texture) -> void:
	if _pub_near[0] == r and _pub_near[1] == g and _pub_near[2] == b:
		return
	_pub_near = [r, g, b]
	RenderingServer.global_shader_parameter_set(&"gi_near_r", r)
	RenderingServer.global_shader_parameter_set(&"gi_near_g", g)
	RenderingServer.global_shader_parameter_set(&"gi_near_b", b)


func _update_occ_globals() -> void:
	if _occ_proxy == null or not _gpu_ok:
		RenderingServer.global_shader_parameter_set(&"gi_occ_origin", Vector4(0, 0, 0, 0))
		return
	var inv := Vector3.ONE / (Vector3(_occ_size) * occupancy_cell)
	var strength := 1.0 if (_detail_ao and _enabled) else 0.0
	RenderingServer.global_shader_parameter_set(&"gi_occ_origin", Vector4(_occ_origin.x, _occ_origin.y, _occ_origin.z, strength))
	# roof map (0.25 m columns): z = 1 when valid
	var ext := Vector2(_roof_size) * occupancy_cell
	RenderingServer.global_shader_parameter_set(&"gi_roof_info", Vector4(_occ_origin.x, _occ_origin.z,
			1.0 / maxf(ext.x, 0.01), 1.0 / maxf(ext.y, 0.01)) if _roof_proxy != null else Vector4(0, 0, 0, 0))
	RenderingServer.global_shader_parameter_set(&"gi_occ_inv", Vector4(inv.x, inv.y, inv.z, occupancy_cell))


func _mark_motion() -> void:
	_last_motion_ms = Time.get_ticks_msec()
	_rate_mult = 1.0


## Tracks light + camera movement for the adaptive update rate.
func _detect_motion(cam: Camera3D) -> void:
	var moved := false
	var seen := {}
	var list: Array = get_tree().get_nodes_in_group(&"gi_emitters")
	list.append(cam)
	if sun != null:
		list.append(sun)
	var cam_pos := cam.global_position
	for n in list:
		var n3: Node3D = (n as GIEmitter).light if n is GIEmitter else n as Node3D
		if n3 == null or not is_instance_valid(n3):
			continue
		if n is GIEmitter and n3.global_position.distance_to(cam_pos) > (n as GIEmitter).get_range() + cull_margin + 12.0:
			continue # too far away to matter
		var id := n3.get_instance_id()
		seen[id] = true
		var on := n3.is_visible_in_tree()
		if n3 is Light3D:
			on = on and (n3 as Light3D).light_energy > 0.001
		var pos := n3.global_position
		var dir := -n3.global_basis.z
		var energy: float = (n3 as Light3D).light_energy if n3 is Light3D else 0.0
		var old: Array = _motion_sig.get(id, [])
		if old.is_empty() or old[2] != on or (old[0] as Vector3).distance_to(pos) > MOTION_EPS \
				or (old[1] as Vector3).angle_to(dir) * 2.0 > MOTION_EPS or absf(float(old[3]) - energy) > 0.15 * maxf(energy, 0.1):
			moved = true
			_motion_sig[id] = [pos, dir, on, energy]
	if _motion_sig.size() != seen.size():
		for id in _motion_sig.keys():
			if not seen.has(id):
				_motion_sig.erase(id)
		moved = true
	if moved or _static_boost > 0 or _dir_ndirty > 0 or not _sregs.is_empty():
		_mark_motion()
		return
	if not _adaptive:
		_rate_mult = 1.0
		return
	var still := float(Time.get_ticks_msec() - _last_motion_ms) / 1000.0
	_rate_mult = 1.0 if still < 0.6 else (2.0 if still < 2.5 else 4.0)


func _emit_stats() -> void:
	stats_updated.emit(get_stats())


func get_stats() -> Dictionary:
	var prog := get_chunk_progress()
	return {
		"gpu": _gpu_ok, "enabled": _enabled,
		"vpls": _vpl_count, "vpls_dynamic": _n_dyn, "lights_static": _n_static,
		"static_lights": _static.size(), "rays": _rays_cast, "direct_pending": _direct_pending(),
		"light_changes": _sregs.size(),
		"cpu_ms": float(_cpu_usec) / 1000.0, "gpu_ms": _gpu_ms,
		"voxels": _near.size.x * _near.size.y * _near.size.z, "cell": _near.cell, "size": _near.size,
		"voxels_full": _gpu_counts[0], "voxels_fast": _gpu_counts[1], "cache_cells": _gpu_counts[2],
		"rate": 1.0 / maxf(_interval * _rate_mult * (1.0 + 0.5 * float(gov_level)), 0.001), "gov_level": gov_level,
		"regions": _region_list.size(),
		"chunks_total": prog["total"], "chunks_loaded": prog["loaded"],
		"chunks_required": prog["required"], "chunks_required_loaded": prog["required_loaded"],
		"chunks_active": _cache_jobs_last, "cache_size": _cache.size, "cache_cell": _cache.cell,
		"chunk_mode": int(_chunk_mode), "load_all": bool(prog["load_all"]),
		"near_updates": _near.updates, "cache_updates": _cache.updates, "occ": _occ_size,
		"direct_building": _dir_initial,
	}


func _push_debug() -> void:
	debug_vpls.clear()
	if _show_vpls:
		for i in _vpl_count:
			var o := i * VPL_STRIDE
			var col := Color(1.0, 0.55, 0.15)
			debug_vpls.append([Vector3(_vpl[o], _vpl[o + 1], _vpl[o + 2]), col])


## For the debug overlay: update regions and the chunks computed this update.
func get_debug_boxes() -> Array:
	var out: Array = []
	if not _show_regions:
		return out
	for a in _region_list:
		out.append([a, Color(1.0, 0.5, 0.1)])
	var y0 := float(_cache.base.y) * _cache.cell
	var h := float(_cache.size.y) * _cache.cell
	for i in _cache_chunks_last:
		var rc := _chunk_rect(i)
		out.append([AABB(Vector3(rc.position.x, y0, rc.position.y), Vector3(rc.size.x, h, rc.size.y)).grow(-0.05), Color(0.2, 0.9, 1.0)])
	if _near.ready:
		out.append([AABB(Vector3(_near.base) * _near.cell, Vector3(_near.size) * _near.cell), Color(0.6, 1.0, 0.4, 0.6)])
	return out


# ================================================================== albedo lookup

func _get_albedo(collider: Object, _shape: int) -> Color:
	if collider == null or not is_instance_valid(collider):
		return DEFAULT_ALBEDO
	var id := collider.get_instance_id()
	if _albedo_cache.has(id):
		return _albedo_cache[id]
	if _albedo_cache.size() > 2048:
		_albedo_cache.clear()
	var c := _resolve_albedo(collider)
	_albedo_cache[id] = c
	return c


## Albedo used for bounce colour: "gi_albedo" metadata on the body, else on
## the material of the first MeshInstance3D child (linear colour).
func _resolve_albedo(collider: Object) -> Color:
	if collider.has_meta(&"gi_albedo"):
		var m: Variant = collider.get_meta(&"gi_albedo")
		if m is Color:
			return _clamp_albedo(m)
	var node := collider as Node
	if node == null:
		return DEFAULT_ALBEDO
	var mesh: MeshInstance3D = node as MeshInstance3D
	for child in node.get_children():
		if mesh != null:
			break
		if child is MeshInstance3D:
			mesh = child
			break
	if mesh == null and node.get_parent() is MeshInstance3D:
		mesh = node.get_parent()
	if mesh == null:
		return DEFAULT_ALBEDO
	var mat: Material = mesh.material_override
	if mat == null and mesh.mesh and mesh.mesh.get_surface_count() > 0:
		mat = mesh.get_active_material(0)
	if mat == null:
		return DEFAULT_ALBEDO
	if mat.has_meta(&"gi_albedo"):
		var mm: Variant = mat.get_meta(&"gi_albedo")
		if mm is Color:
			return _clamp_albedo(mm)
	if mat is ShaderMaterial:
		var v: Variant = (mat as ShaderMaterial).get_shader_parameter(&"albedo_color")
		if v is Color:
			return _clamp_albedo((v as Color).srgb_to_linear() * 0.8)
	if mat is BaseMaterial3D:
		return _clamp_albedo((mat as BaseMaterial3D).albedo_color.srgb_to_linear() * 0.8)
	return DEFAULT_ALBEDO


## Bounce albedo: max 0.9 and slightly desaturated (15 %), so strongly coloured
## walls / grass tint the rooms around them without painting whole ceilings.
static func _clamp_albedo(c: Color) -> Color:
	var l := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	return Color(clampf(lerpf(l, c.r, 0.85), 0.0, 0.9), clampf(lerpf(l, c.g, 0.85), 0.0, 0.9), clampf(lerpf(l, c.b, 0.85), 0.0, 0.9))


# ================================================================== occupancy

## Voxelizes the collision shapes under occupancy_root (3 mip levels, each
## rasterized directly: a cell is solid if its centre lies inside the shape
## grown by half a cell, so thin walls are never missed).
func _build_occupancy() -> void:
	var shapes: Array = []
	var bounds := AABB()
	var first := true
	if occupancy_root != null:
		for n in occupancy_root.find_children("*", "CollisionShape3D", true, false):
			var cs := n as CollisionShape3D
			if cs.disabled or cs.shape == null or not (cs.get_parent() is StaticBody3D):
				continue
			var body := cs.get_parent() as StaticBody3D
			if (body.collision_layer & collision_mask) == 0:
				continue
			var info := _shape_info(cs)
			if info.is_empty():
				continue
			info["alb"] = _get_albedo(body, 0)
			shapes.append(info)
			var wa: AABB = info["aabb"]
			bounds = wa if first else bounds.merge(wa)
			first = false
	if occupancy_root != null and (occupancy_source == 2 or (occupancy_source == 0 and shapes.is_empty())):
		for info: Dictionary in _mesh_infos(occupancy_root):
			shapes.append(info)
			var wa2: AABB = info["aabb"]
			bounds = wa2 if first else bounds.merge(wa2)
			first = false
	if first:
		bounds = AABB(Vector3(-8, -1, -8), Vector3(16, 8, 16))
	_geo_aabb = bounds
	bounds = bounds.grow(1.0)
	var c4 := occupancy_cell * 4.0
	_occ_origin = (bounds.position / c4).floor() * c4
	var end := (bounds.end / c4).ceil() * c4
	_occ_size = Vector3i(((end - _occ_origin) / occupancy_cell).round())
	_occ_size = _occ_size.clamp(Vector3i(4, 4, 4), Vector3i(512, 128, 512))
	_occ_aabb = AABB(_occ_origin, Vector3(_occ_size) * occupancy_cell)
	_occ_bytes = PackedByteArray()
	_dir_size = _occ_size / 2
	_dir_cell = occupancy_cell * 2.0
	for lod in 3:
		var sz := _occ_size / (1 << lod)
		var cell := occupancy_cell * float(1 << lod)
		var grid := PackedByteArray()
		grid.resize(sz.x * sz.y * sz.z)
		var alb := PackedByteArray()
		if lod == 1:
			alb.resize(grid.size() * 4) # albedo grid for the bounce colour (0.5 m)
		for info: Dictionary in shapes:
			_raster_shape(grid, sz, cell, info, alb)
		_occ_bytes.append_array(grid)
		if lod == 0:
			_build_roof(grid, sz, cell) # 0.25 m: exact enough to tell ceilings from the sky above
		if lod == 1:
			_alb_bytes = alb


## Highest solid point of every 0.25 m column: rays that run out of length below
## it are indoors (they see more building, not the sky), and surfaces below it
## ignore GI voxels above the roof (gi_roof, no sky light leaking through ceilings).
func _build_roof(grid: PackedByteArray, sz: Vector3i, cell: float) -> void:
	_roof_size = Vector2i(sz.x, sz.z)
	var roof := PackedFloat32Array()
	roof.resize(sz.x * sz.z)
	var sx := sz.x
	var sxy := sz.x * sz.y
	for z in sz.z:
		for x in sz.x:
			var top := -1.0e4
			var y := sz.y - 1
			while y >= 0:
				if grid[z * sxy + y * sx + x] != 0:
					top = _occ_origin.y + float(y + 1) * cell
					break
				y -= 1
			roof[z * sx + x] = top
	_roof_bytes = roof.to_byte_array()


func _shape_info(cs: CollisionShape3D) -> Dictionary:
	var xf := cs.global_transform
	var s := cs.shape
	var kind := 0 # 0 box, 1 cylinder (y), 2 sphere
	var half := Vector3.ONE
	var radius := 0.0
	var local_center := Vector3.ZERO
	if s is BoxShape3D:
		half = (s as BoxShape3D).size * 0.5
	elif s is CylinderShape3D:
		kind = 1
		radius = (s as CylinderShape3D).radius
		half = Vector3(radius, (s as CylinderShape3D).height * 0.5, radius)
	elif s is CapsuleShape3D:
		kind = 1
		radius = (s as CapsuleShape3D).radius
		half = Vector3(radius, (s as CapsuleShape3D).height * 0.5, radius)
	elif s is SphereShape3D:
		kind = 2
		radius = (s as SphereShape3D).radius
		half = Vector3(radius, radius, radius)
	else:
		var dm := s.get_debug_mesh()
		if dm == null:
			return {}
		var a := dm.get_aabb()
		half = a.size * 0.5
		local_center = a.get_center()
	if s is ConcavePolygonShape3D:
		return _tri_info(xf, (s as ConcavePolygonShape3D).get_faces())
	var lxf := xf * Transform3D(Basis.IDENTITY, local_center)
	var aabb := lxf * AABB(-half, half * 2.0)
	var b := lxf.basis
	var aligned := _is_axis_aligned(b)
	return {"xf": lxf, "inv": lxf.affine_inverse(), "kind": kind, "half": half, "radius": radius,
			"aabb": aabb, "aligned": aligned and kind == 0}


static func _is_axis_aligned(b: Basis) -> bool:
	for v: Vector3 in [b.x, b.y, b.z]:
		var a := v.abs()
		var m := maxf(a.x, maxf(a.y, a.z))
		if a.x + a.y + a.z - m > 0.001 * m:
			return false
	return true


## Triangle soup (world space) for the mesh voxelizer.
func _tri_info(xf: Transform3D, faces: PackedVector3Array) -> Dictionary:
	if faces.size() < 3:
		return {}
	var w := xf * faces
	var aabb := AABB(w[0], Vector3.ZERO)
	for v in w:
		aabb = aabb.expand(v)
	return {"kind": 3, "tris": w, "aabb": aabb}


## Visible static meshes / CSG roots under `root` as triangle soups (used when
## the scene has no collision shapes). Meshes under physics bodies that move
## (RigidBody3D, CharacterBody3D, AnimatableBody3D), in the "goygi_ignore"
## group, or smaller than a voxel are skipped.
func _mesh_infos(root: Node) -> Array:
	var out: Array = []
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var gi_node := n as GeometryInstance3D
		if not gi_node.is_visible_in_tree() or gi_node.is_in_group(&"goygi_ignore"):
			continue
		if gi_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			continue
		var p := gi_node.get_parent()
		var moving := false
		while p != null and p != root:
			if p is RigidBody3D or p is CharacterBody3D or p is AnimatableBody3D:
				moving = true
				break
			p = p.get_parent()
		if moving:
			continue
		var faces := PackedVector3Array()
		if gi_node is MeshInstance3D and (gi_node as MeshInstance3D).mesh != null:
			faces = (gi_node as MeshInstance3D).mesh.get_faces()
		elif gi_node is CSGShape3D and (gi_node as CSGShape3D).is_root_shape():
			var arr: Array = (gi_node as CSGShape3D).get_meshes()
			if arr.size() >= 2 and arr[1] is Mesh:
				faces = (arr[1] as Mesh).get_faces()
		if faces.is_empty():
			continue
		var info := _tri_info(gi_node.global_transform, faces)
		if info.is_empty():
			continue
		info["alb"] = _resolve_albedo(gi_node)
		var sz: Vector3 = (info["aabb"] as AABB).size
		if maxf(sz.x, maxf(sz.y, sz.z)) < occupancy_cell:
			continue
		out.append(info)
	return out


## Marks every cell touched by the triangles: each triangle is sampled on a
## barycentric grid finer than half a cell (surface shell, closed for rays).
func _raster_tris(grid: PackedByteArray, sz: Vector3i, cell: float, info: Dictionary, alb: PackedByteArray) -> void:
	var wa := not alb.is_empty()
	var ac: Color = info.get("alb", DEFAULT_ALBEDO)
	var t: PackedVector3Array = info["tris"]
	var sx := sz.x
	var sxy := sz.x * sz.y
	var step := cell * 0.45
	for i in range(0, t.size() - 2, 3):
		var a := t[i]
		var b := t[i + 1]
		var c := t[i + 2]
		var n := int(ceil(maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a))) / step))
		n = clampi(n, 1, 512)
		for u in n + 1:
			for v in n + 1 - u:
				var p := a + (b - a) * (float(u) / n) + (c - a) * (float(v) / n)
				var q := ((p - _occ_origin) / cell).floor()
				var x := int(q.x)
				var y := int(q.y)
				var z := int(q.z)
				if x >= 0 and y >= 0 and z >= 0 and x < sz.x and y < sz.y and z < sz.z:
					var gi_i := z * sxy + y * sx + x
					grid[gi_i] = 255
					if wa:
						_put_alb(alb, gi_i, ac)


static func _put_alb(alb: PackedByteArray, i: int, c: Color) -> void:
	var o := i * 4
	alb[o] = int(c.r * 255.0)
	alb[o + 1] = int(c.g * 255.0)
	alb[o + 2] = int(c.b * 255.0)
	alb[o + 3] = 255


func _raster_shape(grid: PackedByteArray, sz: Vector3i, cell: float, info: Dictionary, alb: PackedByteArray = PackedByteArray()) -> void:
	if int(info["kind"]) == 3:
		_raster_tris(grid, sz, cell, info, alb)
		return
	var wa := not alb.is_empty()
	var ac: Color = info.get("alb", DEFAULT_ALBEDO)
	var e := cell * 0.5
	var aabb: AABB = info["aabb"]
	var lo := ((aabb.position - Vector3(e, e, e) - _occ_origin) / cell - Vector3(0.5, 0.5, 0.5)).ceil()
	var hi := ((aabb.end + Vector3(e, e, e) - _occ_origin) / cell - Vector3(0.5, 0.5, 0.5)).floor()
	var x0 := maxi(int(lo.x), 0)
	var y0 := maxi(int(lo.y), 0)
	var z0 := maxi(int(lo.z), 0)
	var x1 := mini(int(hi.x), sz.x - 1)
	var y1 := mini(int(hi.y), sz.y - 1)
	var z1 := mini(int(hi.z), sz.z - 1)
	if x0 > x1 or y0 > y1 or z0 > z1:
		return
	var sx := sz.x
	var sxy := sz.x * sz.y
	if info["aligned"]:
		# axis aligned box: the expanded AABB test is exact
		for z in range(z0, z1 + 1):
			for y in range(y0, y1 + 1):
				var row := z * sxy + y * sx
				for x in range(x0, x1 + 1):
					grid[row + x] = 255
					if wa:
						_put_alb(alb, row + x, ac)
		return
	var inv: Transform3D = info["inv"]
	var kind: int = info["kind"]
	var half: Vector3 = info["half"] + Vector3(e, e, e)
	var rr: float = info["radius"] + e
	rr *= rr
	for z in range(z0, z1 + 1):
		for y in range(y0, y1 + 1):
			var row := z * sxy + y * sx
			for x in range(x0, x1 + 1):
				var w := _occ_origin + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * cell
				var l := inv * w
				var inside := false
				if kind == 0:
					inside = absf(l.x) <= half.x and absf(l.y) <= half.y and absf(l.z) <= half.z
				elif kind == 1:
					inside = absf(l.y) <= half.y and l.x * l.x + l.z * l.z <= rr
				else:
					inside = l.length_squared() <= rr
				if inside:
					grid[row + x] = 255
					if wa:
						_put_alb(alb, row + x, ac)




# ================================================================== render thread

var _dummy3d: RID
var _dummy_age: RID
var _meter_shader: RID
var _meter_pipeline: RID
var _meter_buf: RID
# light meter result (render thread writes): x luminance of the seen surfaces,
# y sky fraction, z mean log2 luminance, w hit rays
var _meter := Vector4(-1, 0, 0, 0)
var _meter_ms := 0

static func _uni(type: int, binding: int, ids: Array) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = type as RenderingDevice.UniformType
	u.binding = binding
	for id: RID in ids:
		u.add_id(id)
	return u


func _rt_init() -> void:
	var rd := _rd
	var file := load(SHADER_PATH) as RDShaderFile
	if file == null:
		push_error("GIManager: cannot load %s" % SHADER_PATH)
		_gpu_failed = true
		return
	var spirv := file.get_spirv()
	if spirv == null or spirv.compile_error_compute != "":
		push_error("GIManager: compute shader error: %s" % (spirv.compile_error_compute if spirv else "null"))
		_gpu_failed = true
		return
	_shader = rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		push_error("GIManager: the RenderingDevice refused the GI compute shader (invalid shader RID) - GI disabled, direct light only.")
		_gpu_failed = true
		return
	_pipeline = rd.compute_pipeline_create(_shader)
	var bfile := load(BLEND_SHADER_PATH) as RDShaderFile
	var bsp := bfile.get_spirv() if bfile else null
	if bsp != null and bsp.compile_error_compute == "":
		_blend_shader = rd.shader_create_from_spirv(bsp)
		if _blend_shader.is_valid():
			_blend_pipeline = rd.compute_pipeline_create(_blend_shader)
	else:
		push_warning("GIManager: display smoothing shader unavailable")
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler_linear = rd.sampler_create(ss)
	var sc := RDSamplerState.new()
	sc.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sc.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sc.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sc.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sc.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler_clamp = rd.sampler_create(sc)
	var sn := RDSamplerState.new()
	sn.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sn.max_lod = 4.0
	_sampler_nearest = rd.sampler_create(sn)
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	tf.width = _occ_size.x
	tf.height = _occ_size.y
	tf.depth = _occ_size.z
	tf.mipmaps = 3
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_occ_tex = rd.texture_create(tf, RDTextureView.new(), [_occ_bytes])
	if not _occ_tex.is_valid():
		push_error("GIManager: occupancy texture creation failed")
		_gpu_failed = true
		return
	var zero := PackedByteArray()
	zero.resize(MAX_VPLS * VPL_STRIDE * 4)
	_vpl_buf = rd.storage_buffer_create(zero.size(), zero)
	var zl := PackedByteArray()
	zl.resize(MAX_LIGHTS * 64)
	_light_buf = rd.storage_buffer_create(zl.size(), zl)
	var zp := PackedByteArray()
	zp.resize(PARAM_BYTES)
	_param_buf = rd.storage_buffer_create(zp.size(), zp)
	_dummy3d = _rt_tex3d(Vector3i.ONE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var mfile := load(METER_SHADER_PATH) as RDShaderFile
	var msp := mfile.get_spirv() if mfile else null
	if msp != null and msp.compile_error_compute == "":
		_meter_shader = rd.shader_create_from_spirv(msp)
		if _meter_shader.is_valid():
			_meter_pipeline = rd.compute_pipeline_create(_meter_shader)
			var zm := PackedByteArray()
			zm.resize(16)
			_meter_buf = rd.storage_buffer_create(16, zm)
	else:
		push_warning("GIManager: light meter shader unavailable (eye adaptation falls back)")
	_dummy_age = _rt_tex3d(Vector3i.ONE, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	if not _rt_init_direct():
		push_error("GIManager: the direct light cache could not be created - GI disabled, direct light only.")
		_gpu_failed = true
		return
	_gpu_init_done = true
	print("GIManager: GPU pipelines ready - occupancy %s, direct cache %s, near volume %s" % [_occ_size, _dir_size, _near.size])


## Direct light cache (3 x RGBA16F), albedo grid (RGBA8), roof map (R32F) and
## the shader that fills the cache.
func _rt_init_direct() -> bool:
	var rd := _rd
	var file := load(DIRECT_SHADER_PATH) as RDShaderFile
	var spirv := file.get_spirv() if file else null
	if spirv == null or spirv.compile_error_compute != "":
		push_error("GIManager: direct light shader error: %s" % (spirv.compile_error_compute if spirv else "missing"))
		return false
	_dir_shader = rd.shader_create_from_spirv(spirv)
	if not _dir_shader.is_valid():
		push_error("GIManager: the RenderingDevice refused the direct light compute shader (invalid shader RID).")
		return false
	_dir_pipeline = rd.compute_pipeline_create(_dir_shader)
	_dir_tex.clear()
	for i in 3:
		var t := _rt_tex3d(_dir_size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		if not t.is_valid():
			push_error("GIManager: direct light cache texture creation failed")
			return false
		_dir_tex.append(t)
	var ta := RDTextureFormat.new()
	ta.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	ta.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	ta.width = _dir_size.x
	ta.height = _dir_size.y
	ta.depth = _dir_size.z
	ta.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	_alb_tex = rd.texture_create(ta, RDTextureView.new(), [_alb_bytes])
	var tr := RDTextureFormat.new()
	tr.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tr.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tr.width = _roof_size.x
	tr.height = _roof_size.y
	tr.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	_roof_tex = rd.texture_create(tr, RDTextureView.new(), [_roof_bytes])
	if not _alb_tex.is_valid() or not _roof_tex.is_valid():
		push_error("GIManager: albedo / roof texture creation failed")
		return false
	_alb_bytes = PackedByteArray() # uploaded, the CPU copy is not needed any more
	var I := RenderingDevice.UNIFORM_TYPE_IMAGE
	var S := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	var u: Array[RDUniform] = []
	u.append(_uni(S, 0, [_sampler_nearest, _occ_tex]))
	for k in 3:
		u.append(_uni(I, 1 + k, [_dir_tex[k]]))
	u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_light_buf]))
	_dir_uset = rd.uniform_set_create(u, _dir_shader, 0)
	return _dir_uset.is_valid()


## Bindings 19 - 23 of the GI shader (direct cache, albedo, roof).
func _direct_uniforms(u: Array[RDUniform]) -> void:
	var S := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	for k in 3:
		u.append(_uni(S, 19 + k, [_sampler_clamp, _dir_tex[k]]))
	u.append(_uni(S, 22, [_sampler_clamp, _alb_tex]))
	u.append(_uni(S, 23, [_sampler_clamp, _roof_tex]))


func _rt_tex3d(size: Vector3i, fmt: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	tf.format = fmt as RenderingDevice.DataFormat
	tf.width = size.x
	tf.height = size.y
	tf.depth = size.z
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT \
			| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var t := _rd.texture_create(tf, RDTextureView.new())
	if t.is_valid():
		_rd.texture_clear(t, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return t


func _rt_free_rids(rids: Array) -> void:
	for r: RID in rids:
		if r.is_valid():
			_rd.free_rid(r) # dependent uniform sets are freed automatically


func _rt_alloc_cache(size: Vector3i, nx: int, nz: int) -> void:
	if _gpu_failed:
		return
	var rd := _rd
	# the textures of the previous grid (freed once the new ones are published)
	var old: Array = _rt_cache_tex.duplicate()
	if _cache.mask_tex.is_valid():
		old.append(_cache.mask_tex)
	var tex: Array[RID] = []
	for i in 6:
		var t := _rt_tex3d(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		if not t.is_valid():
			push_error("GIManager: chunk cache texture creation failed")
			_rt_free_rids(tex)
			return
		tex.append(t)
	var tf := RDTextureFormat.new()
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	tf.width = nx
	tf.height = nz
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var zero := PackedByteArray()
	zero.resize(nx * nz)
	var mask := rd.texture_create(tf, RDTextureView.new(), [zero])
	var I := RenderingDevice.UNIFORM_TYPE_IMAGE
	var S := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	var u: Array[RDUniform] = []
	for k in 3:
		u.append(_uni(S, k, [_sampler_clamp, tex[k]]))
		u.append(_uni(I, 3 + k, [tex[3 + k]]))
		u.append(_uni(S, 8 + k, [_sampler_clamp, tex[k]]))
		u.append(_uni(I, 11 + k, [tex[3 + k]]))
		u.append(_uni(S, 15 + k, [_sampler_clamp, tex[k]]))
	u.append(_uni(S, 6, [_sampler_nearest, _occ_tex]))
	u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7, [_vpl_buf]))
	u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 14, [_param_buf]))
	u.append(_uni(I, 18, [_dummy_age]))
	_direct_uniforms(u)
	var uset := rd.uniform_set_create(u, _shader, 0)
	if not uset.is_valid():
		push_error("GIManager: chunk cache uniform set failed")
		_rt_free_rids(tex)
		return
	_rt_cache_tex = tex
	_on_cache_alloc_done.call_deferred(tex, mask, uset, old)


func _on_cache_alloc_done(tex: Array[RID], mask: RID, uset: RID, old: Array = []) -> void:
	var c := _cache
	c.tex = tex
	c.mask_tex = mask
	c.uset = uset
	c.proxies.clear()
	for i in 3:
		var p := Texture3DRD.new()
		p.texture_rd_rid = tex[i]
		c.proxies.append(p)
		RenderingServer.global_shader_parameter_set(StringName(["gi_far_r", "gi_far_g", "gi_far_b"][i]), p)
	c.mask_proxy = Texture2DRD.new()
	c.mask_proxy.texture_rd_rid = mask
	RenderingServer.global_shader_parameter_set(&"gi_chunk_mask", c.mask_proxy)
	c.ready = true
	c.dirty_mask = true
	if not old.is_empty():
		RenderingServer.call_on_render_thread(_rt_free_rids.bind(old))


func _rt_alloc(c: Cascade, size: Vector3i) -> void:
	if _gpu_failed:
		return
	var rd := _rd
	var tex: Array[RID] = []
	for i in 12:
		var t := _rt_tex3d(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		if not t.is_valid():
			push_error("GIManager: volume texture creation failed")
			_rt_free_rids(tex)
			return
		tex.append(t)
	var age := _rt_tex3d(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)
	tex.append(age)
	for i in 3: # display (smoothed) copy, 13..15
		tex.append(_rt_tex3d(size, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT))
	var cache_tex: Array[RID] = _rt_cache_tex if _rt_cache_tex.size() >= 3 else [_dummy3d, _dummy3d, _dummy3d]
	var I := RenderingDevice.UNIFORM_TYPE_IMAGE
	var S := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	var sets: Array[RID] = []
	for s in 2:
		var src := s * 3
		var dst := (1 - s) * 3
		var u: Array[RDUniform] = []
		for k in 3:
			u.append(_uni(S, k, [_sampler_linear, tex[src + k]]))
			u.append(_uni(I, 3 + k, [tex[dst + k]]))
			u.append(_uni(S, 8 + k, [_sampler_linear, tex[6 + src + k]]))
			u.append(_uni(I, 11 + k, [tex[6 + dst + k]]))
			u.append(_uni(S, 15 + k, [_sampler_clamp, cache_tex[k]]))
		u.append(_uni(S, 6, [_sampler_nearest, _occ_tex]))
		u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 7, [_vpl_buf]))
		u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 14, [_param_buf]))
		u.append(_uni(I, 18, [age]))
		_direct_uniforms(u)
		sets.append(rd.uniform_set_create(u, _shader, 0))
	var bsets: Array[RID] = []
	if _blend_shader.is_valid():
		for s in 2:
			var u: Array[RDUniform] = []
			for k in 3:
				u.append(_uni(S, k, [_sampler_linear, tex[s * 3 + k]]))
				u.append(_uni(I, 3 + k, [tex[13 + k]]))
			u.append(_uni(S, 6, [_sampler_nearest, _occ_tex]))
			bsets.append(rd.uniform_set_create(u, _blend_shader, 0))
	_on_alloc_done.call_deferred(c, tex, sets, size, bsets)


## Main thread: swap in freshly allocated textures, then free the old ones.
func _on_alloc_done(c: Cascade, tex: Array[RID], sets: Array[RID], size: Vector3i, bsets: Array[RID]) -> void:
	var old := c.tex.duplicate()
	c.tex = tex
	c.sets = sets
	c.blend_sets = bsets
	c.disp_base = Vector3i(1 << 29, 0, 0)
	c.disp_proxies.clear()
	for i in 3:
		var dp := Texture3DRD.new()
		dp.texture_rd_rid = tex[13 + i]
		c.disp_proxies.append(dp)
	_disp_on = false
	c.cur = 0
	c.ready = false
	c.needs_reset = true
	if size != c.size:
		# quality changed again meanwhile; a newer allocation is on its way
		c.sets = []
	c.proxies.clear()
	for i in 6:
		var p := Texture3DRD.new()
		p.texture_rd_rid = tex[i]
		c.proxies.append(p)
	c.age_proxy = Texture3DRD.new()
	c.age_proxy.texture_rd_rid = tex[12]
	RenderingServer.global_shader_parameter_set(&"gi_age", c.age_proxy)
	_publish(false)
	if not old.is_empty():
		RenderingServer.call_on_render_thread(_rt_free_rids.bind(old))


func _rt_update_mask(bytes: PackedByteArray) -> void:
	if _gpu_failed or not _cache.mask_tex.is_valid():
		return
	_rd.texture_update(_cache.mask_tex, 0, bytes)


## Footprint of an in-place rebuild: re-uploads the occupancy grid (all three
## mips in one call, the way texture_create takes it), the albedo grid and the
## roof map of a grid that kept its size.
func _rt_upload_world(occ: PackedByteArray, alb: PackedByteArray, roof: PackedByteArray) -> void:
	if _gpu_failed:
		return
	if not occ.is_empty() and _occ_tex.is_valid():
		_rd.texture_update(_occ_tex, 0, occ)
	if not alb.is_empty() and _alb_tex.is_valid():
		_rd.texture_update(_alb_tex, 0, alb)
	if not roof.is_empty() and _roof_tex.is_valid():
		_rd.texture_update(_roof_tex, 0, roof)


func _rt_update(pbytes: PackedByteArray, vbytes: PackedByteArray, count: int, near_job: Dictionary,
		cache_jobs: Array, light_bytes: PackedByteArray, dir_jobs: Array, readback: bool, meter_job: Dictionary = {}) -> void:
	if _gpu_failed:
		return
	var rd := _rd
	if readback:
		_rt_read_timestamps()
		rd.capture_timestamp("GoyGI begin")
	rd.buffer_update(_param_buf, 0, pbytes.size(), pbytes)
	if count > 0:
		rd.buffer_update(_vpl_buf, 0, vbytes.size(), vbytes)
	if not light_bytes.is_empty():
		rd.buffer_update(_light_buf, 0, mini(light_bytes.size(), MAX_LIGHTS * 64), light_bytes)
	if not dir_jobs.is_empty() and _dir_uset.is_valid():
		var dl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(dl, _dir_pipeline)
		rd.compute_list_bind_uniform_set(dl, _dir_uset, 0)
		for j: Array in dir_jobs:
			var dpc: PackedByteArray = j[0]
			var g: Vector3i = j[1]
			rd.compute_list_set_push_constant(dl, dpc, dpc.size())
			rd.compute_list_dispatch(dl, g.x, g.y, g.z)
		rd.compute_list_end()
	var cache := _cache
	if not cache_jobs.is_empty() and cache.uset.is_valid() and _rt_cache_tex.size() == 6:
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline)
		rd.compute_list_bind_uniform_set(list, cache.uset, 0)
		for j: Dictionary in cache_jobs:
			var pc: PackedByteArray = j["pc"]
			var g: Vector3i = j["groups"]
			rd.compute_list_set_push_constant(list, pc, pc.size())
			rd.compute_list_dispatch(list, g.x, g.y, g.z)
		rd.compute_list_end()
		# results of the computed chunks: B -> A (surfaces and the near volume read A)
		for j: Dictionary in cache_jobs:
			var pos: Vector3 = j["pos"]
			var sz: Vector3 = j["size"]
			for k in 3:
				rd.texture_copy(_rt_cache_tex[3 + k], _rt_cache_tex[k], pos, pos, sz, 0, 0, 0, 0)
	if not near_job.is_empty():
		var uset: RID = near_job["set"]
		if uset.is_valid():
			var pc: PackedByteArray = near_job["pc"]
			var groups: Vector3i = near_job["groups"]
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, _pipeline)
			rd.compute_list_bind_uniform_set(list, uset, 0)
			rd.compute_list_set_push_constant(list, pc, pc.size())
			rd.compute_list_dispatch(list, groups.x, groups.y, groups.z)
			rd.compute_list_end()
	if not meter_job.is_empty() and _meter_pipeline.is_valid():
		var S := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		var nt: Array = meter_job["near"]
		var u: Array[RDUniform] = [_uni(S, 0, [_sampler_nearest, _occ_tex])]
		for k in 3:
			u.append(_uni(S, 1 + k, [_sampler_linear, nt[k] if nt.size() == 3 else _dummy3d]))
		for k in 3:
			u.append(_uni(S, 4 + k, [_sampler_clamp, _dir_tex[k] if _dir_tex.size() == 3 else _dummy3d]))
		u.append(_uni(S, 7, [_sampler_clamp, _alb_tex if _alb_tex.is_valid() else _dummy3d]))
		u.append(_uni(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 8, [_meter_buf]))
		var mset := UniformSetCacheRD.get_cache(_meter_shader, 0, u)
		if mset.is_valid():
			var mpc: PackedByteArray = meter_job["pc"]
			var ml := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(ml, _meter_pipeline)
			rd.compute_list_bind_uniform_set(ml, mset, 0)
			rd.compute_list_set_push_constant(ml, mpc, mpc.size())
			rd.compute_list_dispatch(ml, 1, 1, 1)
			rd.compute_list_end()
			if rd.has_method(&"buffer_get_data_async"):
				rd.buffer_get_data_async(_meter_buf, _rt_on_meter, 0, 16)
	if readback:
		rd.capture_timestamp("GoyGI end")
		if rd.has_method(&"buffer_get_data_async"):
			rd.buffer_get_data_async(_param_buf, _rt_on_counters, 208, 16)


func _rt_on_meter(data: PackedByteArray) -> void:
	if data.size() >= 16:
		_meter = Vector4(data.decode_float(0), data.decode_float(4), data.decode_float(8), data.decode_float(12))
		_meter_ms = Time.get_ticks_msec()


func _rt_on_counters(data: PackedByteArray) -> void:
	if data.size() >= 12:
		var v := PackedInt64Array([data.decode_u32(0), data.decode_u32(4), data.decode_u32(8)])
		_set_counts.call_deferred(v)


func _set_counts(v: PackedInt64Array) -> void:
	_gpu_counts = v


func _rt_read_timestamps() -> void:
	var rd := _rd
	var t0 := -1
	var t1 := -1
	for i in rd.get_captured_timestamps_count():
		var n := rd.get_captured_timestamp_name(i)
		if n == "GoyGI begin":
			t0 = rd.get_captured_timestamp_gpu_time(i)
		elif n == "GoyGI end":
			t1 = rd.get_captured_timestamp_gpu_time(i)
	if t0 >= 0 and t1 >= t0:
		_set_gpu_ms.call_deferred(float(t1 - t0) / 1000.0)


func _set_gpu_ms(ms: float) -> void:
	_gpu_ms = ms


func _rt_free_all(near_tex: Array, cache_tex: Array, dir_tex: Array, dir_uset: RID, rids: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return
	if dir_uset.is_valid() and rd.uniform_set_is_valid(dir_uset):
		rd.free_rid(dir_uset) # before its textures (freeing them drops the set)
	for list: Array in [near_tex, cache_tex, dir_tex]:
		for r: RID in list:
			if r.is_valid():
				rd.free_rid(r)
	for r: RID in rids:
		if r.is_valid():
			rd.free_rid(r)
