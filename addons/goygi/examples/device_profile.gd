extends Node
## Example: choose GoyGI settings per device from a script.
##
## Add this node next to (or above) a GIManager, or copy the idea into your own
## game code. Every GIManager option is a normal property (also editable in the
## Inspector), so you can go above the presets, e.g. 24 sky rays on a fast PC.
##
##     gi.intensity = 1.4                 # one option
##     gi.set_options({"sky_rays": 16})   # several (property names or GoyGIConfig keys)
##     gi.apply_preset(GIManager.Preset.HIGH)
##     print(GIManager.device_info())     # adapter, vendor, mobile, cores, memory_mb, tier

## The GIManager to configure (empty = the first one in the scene tree).
@export var gi: GIManager


func _ready() -> void:
	if gi == null:
		gi = get_tree().get_first_node_in_group(&"gi_manager") as GIManager
	if gi == null:
		push_warning("device_profile: no GIManager found")
		return
	# this script owns the settings: don't let the game's settings menu overwrite them
	gi.follow_game_settings = false
	gi.auto_quality = false
	var info := GIManager.device_info()
	var a := String(info["adapter"]).to_lower()
	print("GoyGI device: ", info)
	if a.contains("mali-g52") or a.contains("mali-g57") or a.contains("adreno (tm) 6"):
		# entry phones: lowest cost, a bit more bounce so interiors don't go black
		gi.apply_preset(GIManager.Preset.LOW)
		gi.set_options({
			"update_rate": 10, "filtering": 0, "spatial_filter": 1,
			"bounce_strength": 1.8, "target_fps": 30,
		})
	elif bool(info["mobile"]):
		gi.apply_preset(GIManager.Preset.MEDIUM)
		gi.target_fps = 45
	elif int(info["tier"]) >= 3:
		# desktop GPU: above Ultra
		gi.apply_preset(GIManager.Preset.ULTRA)
		gi.set_options({"sky_rays": 24, "march_steps": 160, "update_rate": 60, "max_vpls": 128})
	else:
		gi.apply_preset(GIManager.recommended_preset())
