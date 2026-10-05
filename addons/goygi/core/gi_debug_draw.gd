extends Node3D
## GoyGI debug overlay in 3D: VPLs (spheres), CPU light rays (lines) and the
## update regions / chunks computed this update (boxes). Only active while the
## matching Advanced GoyGI option is on - costs nothing otherwise.

var _mm: MultiMeshInstance3D
var _lines: MeshInstance3D
var _imm: ImmediateMesh


func _ready() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	var sphere := SphereMesh.new()
	sphere.radius = 0.07
	sphere.height = 0.14
	sphere.radial_segments = 8
	sphere.rings = 4
	sphere.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = sphere
	_mm = MultiMeshInstance3D.new()
	_mm.multimesh = mm
	_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mm)
	_imm = ImmediateMesh.new()
	_lines = MeshInstance3D.new()
	_lines.mesh = _imm
	_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var lm := StandardMaterial3D.new()
	lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lm.vertex_color_use_as_albedo = true
	lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	lm.no_depth_test = true
	_lines.material_override = lm
	add_child(_lines)
	top_level = true


func _process(_delta: float) -> void:
	var gi := get_parent() as GIManager
	if gi == null:
		return
	var vpls: Array = gi.debug_vpls
	var mm := _mm.multimesh
	mm.instance_count = vpls.size()
	for i in vpls.size():
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, vpls[i][0]))
		mm.set_instance_color(i, vpls[i][1])
	_imm.clear_surfaces()
	var rays := gi.debug_rays
	var boxes := gi.get_debug_boxes()
	if rays.is_empty() and boxes.is_empty():
		return
	_imm.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(0, rays.size() - 1, 2):
		_imm.surface_set_color(Color(1.0, 0.85, 0.3, 0.35))
		_imm.surface_add_vertex(rays[i])
		_imm.surface_set_color(Color(1.0, 0.5, 0.1, 0.9))
		_imm.surface_add_vertex(rays[i + 1])
	for b: Array in boxes:
		_box(b[0], b[1])
	_imm.surface_end()


func _box(a: AABB, c: Color) -> void:
	for e in 12:
		var p0: Vector3
		var p1: Vector3
		if e < 4:
			p0 = a.get_endpoint([0, 1, 4, 5][e]); p1 = a.get_endpoint([2, 3, 6, 7][e])
		elif e < 8:
			p0 = a.get_endpoint([0, 2, 4, 6][e - 4]); p1 = a.get_endpoint([1, 3, 5, 7][e - 4])
		else:
			p0 = a.get_endpoint([0, 1, 2, 3][e - 8]); p1 = a.get_endpoint([4, 5, 6, 7][e - 8])
		_imm.surface_set_color(c)
		_imm.surface_add_vertex(p0)
		_imm.surface_set_color(c)
		_imm.surface_add_vertex(p1)
