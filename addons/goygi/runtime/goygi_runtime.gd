extends Node
## GoyGI runtime autoload (registered as "GoyGIRuntime" by the plugin).
## When the current scene is 3D and has no GIManager it adds one, gives lights
## GIEmitters and converts StandardMaterial3D surfaces to the GoyGI Standard
## shader. Lights / meshes spawned later are handled too. Controlled by the
## Project Settings goygi/runtime/* (auto_attach, auto_emitters,
## convert_materials); options: GoyGIConfig.set_option(key, value).

var manager: Node
var _scene: Node
var _pending: Array[Node] = []


func _ready() -> void:
	GoyGISetup.ensure_globals()
	get_tree().node_added.connect(_on_node_added)
	_check_scene.call_deferred()


func _process(_delta: float) -> void:
	var cs := get_tree().current_scene
	if cs != _scene:
		_check_scene()
	if not _pending.is_empty() and manager != null and is_instance_valid(manager):
		var list := _pending.duplicate()
		_pending.clear()
		for n: Node in list:
			if is_instance_valid(n) and n.is_inside_tree():
				_setup_subtree(n)


func _setting(key: String, def: bool) -> bool:
	return bool(ProjectSettings.get_setting("goygi/runtime/" + key, def))


func _check_scene() -> void:
	_scene = get_tree().current_scene
	manager = null
	if _scene == null or not (_scene is Node3D) or not _setting("auto_attach", true):
		return
	# a GIManager set up by hand anywhere in the tree wins
	var own: Node = GoyGISetup.find_manager(_scene)
	if own == null:
		var g := get_tree().get_nodes_in_group(&"gi_manager")
		own = g[0] if not g.is_empty() else null
	if own != null:
		# it sets itself up (auto_setup); lights / meshes spawned later are
		# handled here
		if bool(own.get(&"auto_setup")):
			manager = own
		return
	manager = GoyGISetup.attach(_scene as Node3D)
	_setup_subtree(_scene)
	print("GoyGI: attached to '%s'" % _scene.name)


func _setup_subtree(root: Node) -> void:
	if _setting("auto_emitters", true):
		GoyGISetup.add_emitters(root)
	if _setting("convert_materials", true):
		GoyGISetup.convert_materials(root)


func _on_node_added(n: Node) -> void:
	if manager == null or _scene == null or not (n is GeometryInstance3D or n is Light3D):
		return
	if n is GIEmitter or not _scene.is_ancestor_of(n):
		return
	_pending.append(n)
