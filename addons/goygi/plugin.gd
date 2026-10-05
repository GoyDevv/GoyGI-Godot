@tool
extends EditorPlugin
## GoyGI editor plugin.
##  * registers the GoyGI global shader uniforms and the goygi/* Project
##    Settings (every GI option, runtime switches)
##  * adds the "GoyGIRuntime" autoload (auto-attaches GoyGI to 3D scenes when
##    the game runs; see goygi/runtime/*)
##  * GoyGI Preview: runs a GIManager inside the edited 3D scene so bounce
##    light, sky light and colour bleeding show live in the 3D viewport. Lights
##    without a GIEmitter get a temporary one and StandardMaterial3D surfaces
##    are previewed with the GoyGI Standard shader. Nothing is saved into the
##    scene. Toggle with the "GoyGI" button in the 3D viewport toolbar.

const AUTOLOAD_NAME := "GoyGIRuntime"
const AUTOLOAD_PATH := "res://addons/goygi/runtime/goygi_runtime.gd"
const NODE_NAME := "__GoyGIPreview"

var _button: Button
var _gi: Node3D
var _scene: Node
var _enabled := true
var _rebuild_t := -1.0
var _report_t := -1.0
var _scan_t := 0.0
var _emitters: Array[Node] = []
var _legacy := false # old files were removed, waiting for an editor restart


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	_register(true)


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		remove_autoload_singleton(AUTOLOAD_NAME)


## Files of GoyGI 2.5 and older (before everything moved into addons/goygi).
## When a new version is unpacked over an old project these stay behind and
## clash with the addon ("Class GIManager hides a global script class",
## "UID duplicate detected"). Each is only removed when its replacement exists.
# The helpers are loaded at run time (not referenced by class name) so this
# script still compiles when an old copy of GoyGI makes the classes clash, and
# can clean that copy up.
static func _setup() -> GDScript:
	return load("res://addons/goygi/core/goygi_setup.gd")


static func _cfg() -> GDScript:
	return load("res://addons/goygi/core/goygi_config.gd")


const LEGACY := {
	"res://scripts/gi/gi_manager.gd": "res://addons/goygi/core/gi_manager.gd",
	"res://scripts/gi/gi_emitter.gd": "res://addons/goygi/core/gi_emitter.gd",
	"res://scripts/gi/gi_debug_draw.gd": "res://addons/goygi/core/gi_debug_draw.gd",
	"res://shaders/gi_volume.glsl": "res://addons/goygi/shaders/gi_volume.glsl",
	"res://shaders/gi_blend.glsl": "res://addons/goygi/shaders/gi_blend.glsl",
	"res://shaders/gi_common.gdshaderinc": "res://addons/goygi/shaders/gi_common.gdshaderinc",
	"res://shaders/gi_surface.gdshader": "res://addons/goygi/shaders/gi_surface.gdshader",
	"res://addons/goygi_preview/plugin.gd": "res://addons/goygi/plugin.gd",
	"res://addons/goygi_preview/plugin.cfg": "res://addons/goygi/plugin.cfg",
}
const LEGACY_DIRS := ["res://scripts/gi", "res://shaders", "res://addons/goygi_preview"]


## Removes leftover pre-addon GoyGI files. Returns how many were removed.
static func remove_legacy_files() -> int:
	var removed := 0
	for old: String in LEGACY:
		if not FileAccess.file_exists(old) or not FileAccess.file_exists(LEGACY[old]):
			continue
		for f in [old, old + ".uid", old + ".import"]:
			if FileAccess.file_exists(f) and DirAccess.remove_absolute(ProjectSettings.globalize_path(f)) == OK:
				removed += 1
	for d: String in LEGACY_DIRS:
		var abs := ProjectSettings.globalize_path(d)
		if DirAccess.dir_exists_absolute(abs) and DirAccess.get_files_at(abs).is_empty() \
				and DirAccess.get_directories_at(abs).is_empty():
			DirAccess.remove_absolute(abs)
	return removed


func _enter_tree() -> void:
	var removed := remove_legacy_files()
	if removed > 0:
		push_warning("GoyGI: removed %d leftover files of an older GoyGI version (scripts/gi, shaders, addons/goygi_preview)." % removed)
		_ask_restart.call_deferred(removed)
		_legacy = true
		return # classes are still mixed up until the editor restarts
	_register(false)
	_enabled = bool(ProjectSettings.get_setting("goygi/editor_preview", true))
	_button = Button.new()
	_button.toggle_mode = true
	_button.flat = true
	_button.text = "GoyGI"
	_button.tooltip_text = "GoyGI Preview: real-time GI in the editor viewport"
	_button.button_pressed = _enabled
	_button.toggled.connect(_on_toggled)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	scene_changed.connect(func(_root: Node) -> void: _refresh())
	_refresh.call_deferred()


func _exit_tree() -> void:
	if _button == null:
		return
	_remove()
	if _button:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
		_button.queue_free()


func _ask_restart(removed: int) -> void:
	EditorInterface.get_resource_filesystem().scan()
	var dlg := ConfirmationDialog.new()
	dlg.title = "GoyGI updated"
	dlg.dialog_text = ("Removed %d leftover files of an older GoyGI version that clashed with the new addon "
		+ "(scripts/gi, shaders, addons/goygi_preview).\nRestart the editor now to clear the errors?") % removed
	dlg.ok_button_text = "Restart"
	dlg.confirmed.connect(func() -> void: EditorInterface.restart_editor(false))
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()


func _register(force_save: bool) -> void:
	_cfg().register_project_settings()
	var added: bool = _setup().ensure_globals(true)
	if added or force_save:
		ProjectSettings.save()


func _on_toggled(on: bool) -> void:
	_enabled = on
	ProjectSettings.set_setting("goygi/editor_preview", on)
	_refresh()


## Rebuilds the preview a moment after the scene was saved (walls moved...).
func _save_external_data() -> void:
	_rebuild_t = 0.5


func _process(delta: float) -> void:
	if _report_t >= 0.0:
		_report_t -= delta
		if _report_t < 0.0 and _gi != null and is_instance_valid(_gi):
			var st: Dictionary = _gi.call(&"get_stats")
			print("GoyGI Preview: %d VPLs, %d near updates, %d voxels @ %.2f m, cache %d / %d chunks" % [
				int(st.get("vpls", 0)), int(st.get("near_updates", 0)), int(st.get("voxels", 0)), float(st.get("cell", 0.0)),
				int(st.get("chunks_loaded", 0)), int(st.get("chunks_total", 0))])
	if _rebuild_t >= 0.0:
		_rebuild_t -= delta
		if _rebuild_t < 0.0:
			_remove()
			_refresh()
	# lights / meshes added while editing get emitters / preview materials
	_scan_t -= delta
	if _scan_t < 0.0 and _gi != null and is_instance_valid(_gi) and _scene != null and is_instance_valid(_scene):
		_scan_t = 2.0
		_setup_scene(_scene)


func _refresh() -> void:
	if _legacy:
		return
	var root := EditorInterface.get_edited_scene_root()
	# GIManagers saved in the scene (main.tscn) preview themselves
	# (preview_in_editor); the toolbar toggle starts / stops them
	var own: Array[Node] = _scene_managers(root)
	for m in own:
		if _enabled and bool(m.get(&"preview_in_editor")):
			m.call(&"start")
		else:
			m.call(&"stop")
	if not _enabled or not (root is Node3D):
		_remove()
		return
	if _gi != null and is_instance_valid(_gi) and _scene == root:
		return
	_remove()
	if not own.is_empty():
		return
	_scene = root
	_gi = _setup().attach(root as Node3D, true)
	_gi.name = NODE_NAME
	_setup_scene(root)
	print("GoyGI Preview: running in '%s'" % root.name)
	_report_t = 20.0


func _scene_managers(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	if root == null:
		return out
	var script: Script = load("res://addons/goygi/core/gi_manager.gd")
	if root.get_script() == script:
		out.append(root)
	for n in root.find_children("*", "Node3D", true, true):
		if n.get_script() == script and n.name != NODE_NAME:
			out.append(n)
	return out


func _setup_scene(root: Node) -> void:
	if bool(ProjectSettings.get_setting("goygi/runtime/auto_emitters", true)):
		_emitters.append_array(_setup().add_emitters(root))
	if bool(ProjectSettings.get_setting("goygi/runtime/convert_materials", true)):
		_setup().convert_materials(root, true)


func _remove() -> void:
	if _scene != null and is_instance_valid(_scene):
		_setup().restore(_scene)
	for e in _emitters:
		if is_instance_valid(e):
			e.get_parent().remove_child(e)
			e.queue_free()
	_emitters.clear()
	if _gi != null and is_instance_valid(_gi):
		_setup().detach(_gi)
		_gi.get_parent().remove_child(_gi)
		_gi.queue_free()
	_gi = null
	_scene = null
