@tool
class_name GIEmitter
extends Node
## Add this node as a CHILD of any SpotLight3D or OmniLight3D to make that light
## contribute real-time bounce lighting through the GIManager: the manager
## casts rays through the light's cone/sphere and turns every lit surface point
## into a Virtual Point Light that feeds the irradiance volume.

## STATIC lights are traced once and cached (re-traced only when they are
## switched, moved or their energy changes). DYNAMIC lights (torch, moving /
## animated lights) are traced every GI update, feed the fast-responding part
## of the volume and get an "update region". AUTO starts static and switches to
## dynamic while the light keeps moving.
enum Mode { AUTO, STATIC, DYNAMIC }

@export var mode: Mode = Mode.AUTO
## Multiplies the bounced light of this emitter.
@export_range(0.0, 4.0, 0.01) var bounce_gain: float = 1.0
## How important this emitter is when the GI ray budget is shared.
@export_range(0.05, 4.0, 0.01) var priority: float = 1.0
## Max ray distance. 0 = use the light's range.
@export_range(0.0, 60.0, 0.1) var max_distance: float = 0.0
## Fraction of the spot cone sampled (1 = whole cone).
@export_range(0.2, 1.0, 0.01) var cone_coverage: float = 0.85
## Max fraction of the GI ray budget this emitter may use.
@export_range(0.05, 1.0, 0.01) var max_share: float = 0.6

var light: Light3D


func _ready() -> void:
	light = get_parent() as Light3D
	if light == null:
		push_warning("GIEmitter '%s' must be a child of a SpotLight3D or OmniLight3D." % name)
		return
	add_to_group(&"gi_emitters")


func _exit_tree() -> void:
	remove_from_group(&"gi_emitters")


func is_emitting() -> bool:
	return light != null and is_instance_valid(light) and light.is_visible_in_tree() \
		and light.light_energy > 0.001


## Energy without flicker / animation (static lights are cached with it).
func get_base_energy() -> float:
	if light != null and not Engine.is_editor_hint() and light.has_method(&"get_base_energy"):
		return float(light.call(&"get_base_energy"))
	return light.light_energy if light != null else 0.0


func get_range() -> float:
	var r := 10.0
	if light is SpotLight3D:
		r = (light as SpotLight3D).spot_range
	elif light is OmniLight3D:
		r = (light as OmniLight3D).omni_range
	if max_distance > 0.0:
		r = minf(r, max_distance)
	return maxf(r, 0.5)
