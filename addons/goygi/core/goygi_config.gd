@tool
class_name GoyGIConfig
extends RefCounted
## GoyGI options, usable in any project.
##
## Lookup order for every option:
##   1. a host settings autoload named "GameSettings" with get_value(key)
##      (the GoyGI Prototype game; any project can provide the same API),
##   2. values set at runtime with GoyGIConfig.set_option(key, value),
##   3. Project Settings "goygi/options/<key>" (registered by the plugin),
##   4. the defaults below.
## Listeners registered with listen() are called with the changed key.

## GI Resolution tiers: near volume size / voxel size.
const GI_RESOLUTIONS: Array[Dictionary] = [
	{"name": "Low  0.90 m", "size": Vector3i(32, 12, 32), "cell": 0.9},
	{"name": "Medium  0.60 m", "size": Vector3i(48, 16, 48), "cell": 0.6},
	{"name": "High  0.45 m", "size": Vector3i(64, 20, 64), "cell": 0.45},
	{"name": "Ultra  0.36 m", "size": Vector3i(80, 24, 80), "cell": 0.36},
	{"name": "Extreme  0.30 m", "size": Vector3i(96, 28, 96), "cell": 0.3},
]
## Ray Budget: sky rays per voxel, ray-march steps, sun rays per update.
const GI_RAY_BUDGETS: Array[Dictionary] = [
	{"name": "Low", "sky_rays": 5, "steps": 40, "dyn_rays": 32},
	{"name": "Medium", "sky_rays": 6, "steps": 56, "dyn_rays": 48},
	{"name": "High", "sky_rays": 8, "steps": 72, "dyn_rays": 64},
	{"name": "Ultra", "sky_rays": 12, "steps": 96, "dyn_rays": 96},
]
## Dynamic Update Budget.
const GI_UPDATE_BUDGETS: Array[Dictionary] = [
	{"name": "Low", "slices": 4, "cold": 8, "chunk_budget": 1},
	{"name": "Medium", "slices": 2, "cold": 4, "chunk_budget": 2},
	{"name": "High", "slices": 3, "cold": 4, "chunk_budget": 3},
	{"name": "Ultra", "slices": 2, "cold": 3, "chunk_budget": 6},
]
## GI Quality presets (Low / Medium / High / Ultra) for these keys.
const GI_PRESET_KEYS: Array[String] = ["gi_resolution", "gi_vpls", "gi_rays", "gi_update_budget", "gi_filtering"]
const GI_PRESETS: Array[Array] = [[0, 32, 0, 0, 1], [1, 64, 1, 1, 1], [2, 96, 2, 2, 1], [4, 256, 3, 3, 2]]
const AMBIENT_COLORS: Array[Color] = [Color(1, 1, 1), Color(1.0, 0.82, 0.62), Color(0.7, 0.82, 1.0), Color(0.55, 0.62, 0.9)]
const AMBIENT_MAX := 0.12

## Every option GoyGI reads, with its default.
const DEFAULTS := {
	"gi_enabled": true,
	"gi_power": 1.0,
	"gi_quality": 1,
	"gi_resolution": 1,
	"gi_vpls": 64,
	"gi_rays": 1,
	"gi_update_budget": 1,
	"gi_bounces": 2,
	"gi_bounce_strength": 1.6,
	"gi_update_rate": 30,
	"gi_response": 0.7,
	"gi_smoothing": 0.75,
	"gi_stabilization": 2,
	"gi_spatial_filter": 2,
	"gi_adaptive": true,
	"gi_filtering": 1,
	"gi_transition": 2,
	"gi_detail_ao": true,
	"gi_ambient": 0.0,
	"gi_ambient_color": 0,
	"gi_environment": 1.0,
	"gi_chunk_mode": 1,
	"gi_chunk_distance": 24.0,
	"gi_near_mode": 0,
	"gi_unlimited_distance": false,
	"gi_auto_budget": true,
	"gi_debug_view": 0,
	"gi_show_vpls": false,
	"gi_show_rays": false,
	"gi_show_regions": false,
	"developer_mode": false,
	"normal_maps": true,
	"fast_triplanar": false,
	"max_fps": 60,
}
## Editor hints for the Project Settings (type, hint, hint string).
const HINTS := {
	"gi_power": [PROPERTY_HINT_RANGE, "0,4,0.05"],
	"gi_quality": [PROPERTY_HINT_ENUM, "Low,Medium,High,Ultra,Custom"],
	"gi_resolution": [PROPERTY_HINT_ENUM, "Low 0.90 m,Medium 0.60 m,High 0.45 m,Ultra 0.36 m,Extreme 0.30 m"],
	"gi_vpls": [PROPERTY_HINT_RANGE, "16,256,1"],
	"gi_rays": [PROPERTY_HINT_ENUM, "Low,Medium,High,Ultra"],
	"gi_update_budget": [PROPERTY_HINT_ENUM, "Low,Medium,High,Ultra"],
	"gi_bounces": [PROPERTY_HINT_RANGE, "1,2,1"],
	"gi_bounce_strength": [PROPERTY_HINT_RANGE, "0.5,3,0.05"],
	"gi_update_rate": [PROPERTY_HINT_RANGE, "10,60,1"],
	"gi_response": [PROPERTY_HINT_RANGE, "0,1,0.05"],
	"gi_smoothing": [PROPERTY_HINT_RANGE, "0,1,0.05"],
	"gi_stabilization": [PROPERTY_HINT_ENUM, "Off,Low,Medium,High"],
	"gi_spatial_filter": [PROPERTY_HINT_ENUM, "Off,Low,Medium,High"],
	"gi_filtering": [PROPERTY_HINT_ENUM, "Fast,Smooth,Leak-Proof"],
	"gi_transition": [PROPERTY_HINT_ENUM, "Instant,Fast,Medium,Slow"],
	"gi_ambient": [PROPERTY_HINT_RANGE, "0,1,0.05"],
	"gi_ambient_color": [PROPERTY_HINT_ENUM, "Neutral,Warm,Cool,Moonlight"],
	"gi_environment": [PROPERTY_HINT_RANGE, "0,2,0.05"],
	"gi_chunk_mode": [PROPERTY_HINT_ENUM, "Off,Near Only,Balanced,Full"],
	"gi_chunk_distance": [PROPERTY_HINT_RANGE, "8,64,1"],
	"gi_near_mode": [PROPERTY_HINT_ENUM, "Camera,Fixed"],
	"gi_unlimited_distance": [PROPERTY_HINT_NONE, ""],
	"gi_debug_view": [PROPERTY_HINT_ENUM, "Off,GI Only,Voxels,GI Age,Chunks,Leak Guard"],
	"max_fps": [PROPERTY_HINT_RANGE, "0,240,1"],
}
const SETTING_PREFIX := "goygi/options/"

static var _overrides: Dictionary = {}
static var _listeners: Array[Callable] = []


## The host settings autoload (GameSettings) when the project has one.
static func host() -> Object:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	var n := tree.root.get_node_or_null(^"GameSettings")
	if n != null and n.has_method(&"get_value"):
		return n
	return null


static func get_value(key: String) -> Variant:
	var h := host()
	if h != null:
		var v: Variant = h.call(&"get_value", key)
		if v != null:
			return v
	if _overrides.has(key):
		return _overrides[key]
	if ProjectSettings.has_setting(SETTING_PREFIX + key):
		return ProjectSettings.get_setting(SETTING_PREFIX + key)
	return DEFAULTS.get(key)


## Changes an option at runtime (forwarded to the host autoload if there is
## one). Setting "gi_quality" to 0..3 also applies that preset.
static func set_option(key: String, value: Variant) -> void:
	var h := host()
	if h != null and h.has_method(&"set_value"):
		h.call(&"set_value", key, value)
		return
	_overrides[key] = value
	if key == "gi_quality" and int(value) >= 0 and int(value) < GI_PRESETS.size():
		var p: Array = GI_PRESETS[int(value)]
		for i in GI_PRESET_KEYS.size():
			_overrides[GI_PRESET_KEYS[i]] = p[i]
	notify(key)


## Clears runtime overrides (back to Project Settings / defaults).
static func reset_options() -> void:
	_overrides.clear()
	notify("")


## Calls `callable(key: String)` whenever an option changes. Also connects the
## host's `settings_changed(key)` signal when there is a host autoload.
static func listen(callable: Callable) -> void:
	if not _listeners.has(callable):
		_listeners.append(callable)
	var h := host()
	if h != null and h.has_signal(&"settings_changed") and not h.is_connected(&"settings_changed", callable):
		h.connect(&"settings_changed", callable)


static func unlisten(callable: Callable) -> void:
	_listeners.erase(callable)
	var h := host()
	if h != null and h.has_signal(&"settings_changed") and h.is_connected(&"settings_changed", callable):
		h.disconnect(&"settings_changed", callable)


static func notify(key: String) -> void:
	for c in _listeners.duplicate():
		if c.is_valid():
			c.call(key)
		else:
			_listeners.erase(c)


## Effective GI configuration (resolution, VPLs, ray + update budgets).
static func get_gi_config() -> Dictionary:
	var h := host()
	if h != null and h.has_method(&"get_gi_config"):
		return h.call(&"get_gi_config")
	var r: Dictionary = GI_RESOLUTIONS[clampi(int(get_value("gi_resolution")), 0, GI_RESOLUTIONS.size() - 1)]
	var b: Dictionary = GI_RAY_BUDGETS[clampi(int(get_value("gi_rays")), 0, GI_RAY_BUDGETS.size() - 1)]
	var u: Dictionary = GI_UPDATE_BUDGETS[clampi(int(get_value("gi_update_budget")), 0, GI_UPDATE_BUDGETS.size() - 1)]
	return {"size": r["size"], "cell": r["cell"], "vpls": clampi(int(get_value("gi_vpls")), 16, 256),
			"sky_rays": b["sky_rays"], "steps": b["steps"], "dyn_rays": b["dyn_rays"],
			"slices": u["slices"], "cold": u["cold"], "chunk_budget": u["chunk_budget"]}


static func get_ambient_color() -> Color:
	var h := host()
	if h != null and h.has_method(&"get_ambient_color"):
		return h.call(&"get_ambient_color")
	return AMBIENT_COLORS[clampi(int(get_value("gi_ambient_color")), 0, AMBIENT_COLORS.size() - 1)] * AMBIENT_MAX


## Registers every option under goygi/options/ in the Project Settings
## (editor plugin). Values equal to the default are not written to project.godot.
static func register_project_settings() -> void:
	for key: String in DEFAULTS:
		var path := SETTING_PREFIX + key
		var def: Variant = DEFAULTS[key]
		if not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, def)
		ProjectSettings.set_initial_value(path, def)
		var info := {"name": path, "type": typeof(def)}
		if HINTS.has(key):
			info["hint"] = HINTS[key][0]
			info["hint_string"] = HINTS[key][1]
		ProjectSettings.add_property_info(info)
	for extra: Array in [["goygi/runtime/auto_attach", true], ["goygi/runtime/auto_emitters", true],
			["goygi/runtime/convert_materials", true], ["goygi/editor_preview", true]]:
		if not ProjectSettings.has_setting(extra[0]):
			ProjectSettings.set_setting(extra[0], extra[1])
		ProjectSettings.set_initial_value(extra[0], extra[1])
