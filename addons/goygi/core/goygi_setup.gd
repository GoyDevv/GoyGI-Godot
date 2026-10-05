@tool
class_name GoyGISetup
extends RefCounted
## Puts GoyGI into any 3D scene (used by the runtime autoload and the editor
## preview):
##   attach(root)            adds a GIManager (occupancy_root = root, first
##                           DirectionalLight3D / WorldEnvironment found)
##   add_emitters(root)      gives every Omni/Spot light a GIEmitter
##   convert_materials(root) swaps StandardMaterial3D surfaces for the
##                           GoyGI Standard shader so they receive the GI
## Nodes in the "goygi_ignore" group are left alone. In the editor nothing is
## saved into the scene: helper nodes are internal and materials are swapped
## on the RenderingServer only (restore() undoes it).

const GI_SCRIPT := preload("res://addons/goygi/core/gi_manager.gd")
const EMITTER_SCRIPT := preload("res://addons/goygi/core/gi_emitter.gd")
const STANDARD_SHADER := preload("res://addons/goygi/shaders/goygi_standard.gdshader")
const MANAGER_NAME := "GoyGI"
## Physics layer (1-based) of the helper colliders built from meshes for
## scenes without collision (only GoyGI's rays use it).
const MESH_LAYER := 20
const BASE_RENDER_MODE := "render_mode diffuse_burley, specular_schlick_ggx, ambient_light_disabled"

static var _shader_variants: Dictionary = {}
static var _converted: Dictionary = {} # BaseMaterial3D instance id -> [source, ShaderMaterial]
static var _colliders: Dictionary = {} # GIManager id -> helper StaticBody3Ds
static var _done: Dictionary = {} # converted GeometryInstance3D ids (no metadata: it would be saved)


## Global shader uniforms used by the GoyGI shaders: [name, type, default].
const GLOBALS := [
	["gi_filter", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0.5, 0, 0)],
	["gi_occ", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_occ_origin", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_occ_inv", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_near_r", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_near_g", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_near_b", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_near_inv", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_near_min", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_near_max", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_far_r", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_far_g", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_far_b", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_far_inv", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_far_min", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_far_max", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_params", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(1, 0, 1, 0)],
	["gi_fallback", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
	["gi_chunk_mask", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, null],
	["gi_chunk_info", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(8, 1, 1, 0)],
	["gi_age", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D, null],
	["gi_debug", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 8, 0)],
	["gi_roof", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, null],
	["gi_roof_info", RenderingServer.GLOBAL_VAR_TYPE_VEC4, Vector4(0, 0, 0, 0)],
]
const GLOBAL_TYPE_NAMES := {
	RenderingServer.GLOBAL_VAR_TYPE_VEC4: "vec4",
	RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D: "sampler2D",
	RenderingServer.GLOBAL_VAR_TYPE_SAMPLER3D: "sampler3D",
}


## Makes sure the GoyGI global shader uniforms exist on the RenderingServer
## (works at runtime, before the first GoyGI material compiles). With
## `to_project` they are also written to the Project Settings (editor plugin)
## so exported games have them from the start. Returns true if any was added
## to the Project Settings.
static var _globals_added: Dictionary = {} # names this session already added at runtime

static func ensure_globals(to_project := false) -> bool:
	# (the list query is editor-only; at runtime the Project Settings tell
	# which globals the engine already loaded)
	var existing: PackedStringArray = PackedStringArray(_globals_added.keys())
	if Engine.is_editor_hint():
		for nm0 in RenderingServer.global_shader_parameter_get_list():
			existing.append(String(nm0))
	var changed := false
	for g: Array in GLOBALS:
		var nm := StringName(g[0])
		var path := "shader_globals/" + String(g[0])
		if not existing.has(String(nm)) and (Engine.is_editor_hint() or not ProjectSettings.has_setting(path)):
			RenderingServer.global_shader_parameter_add(nm, g[1], g[2])
			_globals_added[String(nm)] = true
		if to_project and not ProjectSettings.has_setting(path):
			ProjectSettings.set_setting(path, {"type": GLOBAL_TYPE_NAMES[g[1]], "value": g[2] if g[2] != null else ""})
			changed = true
	return changed


## The GIManager already in `root` (game scenes that set one up by hand).
static func find_manager(root: Node) -> Node:
	if root == null:
		return null
	for n in root.find_children("*", "Node3D", true, false):
		if n.get_script() == GI_SCRIPT:
			return n
	for n in root.get_children(true):
		if n.get_script() == GI_SCRIPT:
			return n
	return null


static func first_of(root: Node, type: String) -> Node:
	var l := root.find_children("*", type, true, false)
	for n in l:
		if not n.is_in_group(&"goygi_ignore"):
			return n
	return null


## Adds a GIManager to `root` (internal child, never saved). Returns it.
static func attach(root: Node3D, editor := false) -> Node:
	var gi: Node = find_manager(root)
	if gi != null:
		return gi
	gi = GI_SCRIPT.new()
	gi.name = MANAGER_NAME
	if editor:
		gi.set(&"editor_preview", true)
	# auto-attached: options come from the Project Settings / game settings
	gi.set(&"follow_game_settings", true)
	var map := root.get_node_or_null(^"Map") as Node3D
	var occ_root: Node3D = map if map else root
	gi.set(&"occupancy_root", occ_root)
	# scenes without collision: GoyGI traces light with physics rays, so the
	# visible meshes get helper trimesh colliders on their own layer
	if not has_static_shapes(occ_root):
		var bodies := add_mesh_colliders(occ_root)
		if not bodies.is_empty():
			gi.set(&"collision_mask", int(gi.get(&"collision_mask")) | (1 << (MESH_LAYER - 1)))
			_colliders[gi.get_instance_id()] = bodies
	var sun := first_of(root, "DirectionalLight3D")
	if sun:
		gi.set(&"sun", sun)
	var env := first_of(root, "WorldEnvironment")
	if env:
		gi.set(&"world_environment", env)
	root.add_child(gi, false, Node.INTERNAL_MODE_BACK)
	return gi


static func has_static_shapes(root: Node) -> bool:
	for n in root.find_children("*", "CollisionShape3D", true, false):
		var cs := n as CollisionShape3D
		if not cs.disabled and cs.shape != null and cs.get_parent() is StaticBody3D:
			return true
	return false


## Builds internal StaticBody3D + trimesh children for the visible static
## meshes / CSG under `root` (layer MESH_LAYER, mask 0: nothing collides with
## them, only rays that ask for the layer hit them).
static func add_mesh_colliders(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if not g.is_visible_in_tree() or g.is_in_group(&"goygi_ignore"):
			continue
		if g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			continue
		var p := g.get_parent()
		var moving := false
		while p != null and p != root.get_parent():
			if p is RigidBody3D or p is CharacterBody3D or p is AnimatableBody3D:
				moving = true
				break
			p = p.get_parent()
		if moving:
			continue
		var mesh: Mesh = null
		if g is MeshInstance3D:
			mesh = (g as MeshInstance3D).mesh
		elif g is CSGShape3D and (g as CSGShape3D).is_root_shape():
			var arr: Array = (g as CSGShape3D).get_meshes()
			if arr.size() >= 2 and arr[1] is Mesh:
				mesh = arr[1]
		if mesh == null:
			continue
		var faces := mesh.get_faces()
		if faces.size() < 3:
			continue
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		shape.backface_collision = true
		var body := StaticBody3D.new()
		body.name = "GoyGICollider"
		body.collision_layer = 1 << (MESH_LAYER - 1)
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		g.add_child(body, false, Node.INTERNAL_MODE_BACK)
		out.append(body)
	return out


## Removes the helper colliders made for `gi` (editor preview teardown).
static func detach(gi: Node) -> void:
	if gi == null:
		return
	for b: Node in _colliders.get(gi.get_instance_id(), []):
		if is_instance_valid(b):
			b.get_parent().remove_child(b)
			b.queue_free()
	_colliders.erase(gi.get_instance_id())


## Gives every visible SpotLight3D / OmniLight3D without a GIEmitter one
## (mode AUTO). Returns the emitters added.
static func add_emitters(root: Node) -> Array[Node]:
	var added: Array[Node] = []
	for l in root.find_children("*", "Light3D", true, false):
		if not (l is SpotLight3D or l is OmniLight3D) or l.is_in_group(&"goygi_ignore"):
			continue
		var has := false
		for c in l.get_children(true):
			if c is GIEmitter:
				has = true
				break
		if has:
			continue
		var em: Node = EMITTER_SCRIPT.new()
		em.name = "GIEmitter"
		l.add_child(em, false, Node.INTERNAL_MODE_BACK)
		added.append(em)
	return added


## Converts the StandardMaterial3D surfaces under `root`. In the editor the
## swap only happens on the RenderingServer (not saved). Returns the count.
static func convert_materials(root: Node, editor := false) -> int:
	var count := 0
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if g.is_in_group(&"goygi_ignore") or _done.has(g.get_instance_id()):
			continue
		var done := false
		if g.material_override is BaseMaterial3D:
			var sm := to_goygi(g.material_override as BaseMaterial3D)
			if sm:
				if editor:
					RenderingServer.instance_geometry_set_material_override(g.get_instance(), sm.get_rid())
				else:
					g.material_override = sm
				done = true
				count += 1
		elif g is MeshInstance3D and (g as MeshInstance3D).mesh != null:
			var mi := g as MeshInstance3D
			for i in mi.get_surface_override_material_count():
				var m := mi.get_active_material(i)
				if m is BaseMaterial3D:
					var sm2 := to_goygi(m as BaseMaterial3D)
					if sm2:
						if editor:
							RenderingServer.instance_set_surface_override_material(mi.get_instance(), i, sm2.get_rid())
						else:
							mi.set_surface_override_material(i, sm2)
						done = true
						count += 1
		elif g is CSGShape3D and (g as CSGShape3D).is_root_shape():
			var arr: Array = (g as CSGShape3D).get_meshes()
			if arr.size() >= 2 and arr[1] is Mesh:
				var mesh := arr[1] as Mesh
				for i in mesh.get_surface_count():
					var m3 := mesh.surface_get_material(i)
					if m3 is BaseMaterial3D:
						var sm3 := to_goygi(m3 as BaseMaterial3D)
						if sm3:
							RenderingServer.instance_set_surface_override_material(g.get_instance(), i, sm3.get_rid())
							done = true
							count += 1
		if done:
			_done[g.get_instance_id()] = true
	return count


## Undoes convert_materials(editor = true): gives the instances their own
## materials back.
static func restore(root: Node) -> void:
	if root == null:
		return
	for n in root.find_children("*", "GeometryInstance3D", true, false):
		var g := n as GeometryInstance3D
		if not _done.has(g.get_instance_id()):
			continue
		_done.erase(g.get_instance_id())
		var ov := g.material_override
		RenderingServer.instance_geometry_set_material_override(g.get_instance(), ov.get_rid() if ov else RID())
		if g is MeshInstance3D:
			var mi := g as MeshInstance3D
			for i in mi.get_surface_override_material_count():
				var m := mi.get_surface_override_material(i)
				RenderingServer.instance_set_surface_override_material(mi.get_instance(), i, m.get_rid() if m else RID())
		elif g is CSGShape3D:
			var arr: Array = (g as CSGShape3D).get_meshes()
			if arr.size() >= 2 and arr[1] is Mesh:
				for i in (arr[1] as Mesh).get_surface_count():
					RenderingServer.instance_set_surface_override_material(g.get_instance(), i, RID())


## Can this material be converted without visibly changing its look?
static func can_convert(m: BaseMaterial3D) -> bool:
	if m == null or not (m is StandardMaterial3D or m is ORMMaterial3D):
		return false
	if m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
		return false
	if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and m.transparency != BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
		return false
	if m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED or m.next_pass != null:
		return false
	return true


## GoyGI Standard ShaderMaterial for a StandardMaterial3D (cached; null if
## the material uses features the shader does not have).
static func to_goygi(m: BaseMaterial3D) -> ShaderMaterial:
	if not can_convert(m):
		return null
	var key := m.get_instance_id()
	if _converted.has(key) and _converted[key][0] == m:
		return _converted[key][1]
	var sm := ShaderMaterial.new()
	var scissor := m.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var two_sided := m.cull_mode == BaseMaterial3D.CULL_DISABLED
	sm.shader = _variant(scissor, two_sided)
	sm.resource_name = m.resource_name + " (GoyGI)"
	sm.set_shader_parameter(&"albedo_color", m.albedo_color)
	sm.set_shader_parameter(&"albedo_texture", m.albedo_texture)
	sm.set_shader_parameter(&"use_vertex_color", m.vertex_color_use_as_albedo)
	if m is ORMMaterial3D:
		# ORM: occlusion R, roughness G, metallic B in one texture
		var orm := (m as ORMMaterial3D).orm_texture
		sm.set_shader_parameter(&"roughness_texture", orm)
		sm.set_shader_parameter(&"roughness_channel", Vector4(0, 1, 0, 0))
		sm.set_shader_parameter(&"metallic_texture", orm)
		sm.set_shader_parameter(&"metallic_channel", Vector4(0, 0, 1, 0))
	else:
		sm.set_shader_parameter(&"roughness_texture", m.roughness_texture)
		sm.set_shader_parameter(&"roughness_channel", _channel(m.roughness_texture_channel))
		sm.set_shader_parameter(&"metallic_texture", m.metallic_texture)
		sm.set_shader_parameter(&"metallic_channel", _channel(m.metallic_texture_channel))
	sm.set_shader_parameter(&"roughness", m.roughness)
	sm.set_shader_parameter(&"metallic", m.metallic)
	sm.set_shader_parameter(&"specular", m.metallic_specular)
	sm.set_shader_parameter(&"use_normal_map", m.normal_enabled and m.normal_texture != null)
	sm.set_shader_parameter(&"normal_texture", m.normal_texture)
	sm.set_shader_parameter(&"normal_scale", m.normal_scale)
	sm.set_shader_parameter(&"use_emission", m.emission_enabled)
	sm.set_shader_parameter(&"emission", m.emission)
	sm.set_shader_parameter(&"emission_energy", m.emission_energy_multiplier)
	sm.set_shader_parameter(&"emission_texture", m.emission_texture)
	sm.set_shader_parameter(&"uv1_scale", m.uv1_scale)
	sm.set_shader_parameter(&"uv1_offset", m.uv1_offset)
	sm.set_shader_parameter(&"uv1_triplanar", m.uv1_triplanar)
	sm.set_shader_parameter(&"uv1_world_triplanar", m.uv1_world_triplanar)
	sm.set_shader_parameter(&"uv1_blend_sharpness", m.uv1_triplanar_sharpness)
	sm.set_shader_parameter(&"alpha_scissor_threshold", m.alpha_scissor_threshold)
	_converted[key] = [m, sm]
	return sm


static func _channel(c: int) -> Vector4:
	match c:
		BaseMaterial3D.TEXTURE_CHANNEL_GREEN:
			return Vector4(0, 1, 0, 0)
		BaseMaterial3D.TEXTURE_CHANNEL_BLUE:
			return Vector4(0, 0, 1, 0)
		BaseMaterial3D.TEXTURE_CHANNEL_ALPHA:
			return Vector4(0, 0, 0, 1)
		BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE:
			return Vector4(0.333, 0.333, 0.333, 0)
	return Vector4(1, 0, 0, 0)


static func _variant(scissor: bool, two_sided: bool) -> Shader:
	if not scissor and not two_sided:
		return STANDARD_SHADER
	var key := int(scissor) + int(two_sided) * 2
	if _shader_variants.has(key):
		return _shader_variants[key]
	var code := STANDARD_SHADER.code
	code = code.replace(BASE_RENDER_MODE, BASE_RENDER_MODE + (", cull_disabled" if two_sided else ""))
	if scissor:
		code = code.replace("shader_type spatial;", "shader_type spatial;\n#define GOYGI_SCISSOR")
	var sh := Shader.new()
	sh.code = code
	_shader_variants[key] = sh
	return sh
