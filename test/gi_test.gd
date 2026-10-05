extends Node3D
## GoyGI visual test / benchmark. This is what runs in CI on every push and
## pull request (see .github/workflows/ci.yml), on the Mobile renderer with
## Mesa's software Vulkan - no phone, no GPU, no human needed.
##
## It builds a small two-room level with a doorway, a colour-bleeding wall and a
## sealed lamp box, runs GoyGI on it, then
##   * writes one screenshot per debug view into res://artifacts,
##   * measures the things that actually regressed in the past:
##       - "voxel blocks": the mean second derivative of the luminance over a
##         flat wall (a sample-point-warping filter makes this explode),
##       - "GI off is dark": the mean luminance of the same view with the GI
##         switched off, which must stay close to the GI on frame (the
##         Environment ambient fallback),
##       - the GI actually reaching the second room and loading its chunks,
##   * and fails the job (exit code 1) when one of the checks does not hold.
##
## Run it locally with:
##   godot --path . --rendering-method mobile --rendering-driver vulkan
## or, with no GPU at all:
##   VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json \
##     xvfb-run -a godot --path . --rendering-method mobile --rendering-driver vulkan

const OUT_DIR := "res://artifacts"
const READY_TIMEOUT_MS := 180000 # wall clock budget for the GI to be prepared
const READY_TIMEOUT_FRAMES := 6000 # ... and a frame budget, whatever is shorter
const SETTLE := 20 # frames between "change something" and "look at it"
const SETTLE_MAX_MS := 20000 # per shot wall clock cap (software Vulkan is slow)

var gi: GIManager
var cam: Camera3D
var level: Node3D
var sun: DirectionalLight3D
var env: WorldEnvironment

var _log: PackedStringArray = []
var _checks: Array = [] # [name, ok, detail]
var _fail := 0

# the crop used for the blockiness metric: a flat, evenly lit wall
const WALL_CROP := Rect2i(120, 280, 120, 120)


func _ready() -> void:
	_build_level()
	_build_gi()
	_watchdog()
	_run.call_deferred()


## The test must always end the process, even if something inside the GI wedges
## on the CI driver: a hung job is worse than a failed one.
func _watchdog() -> void:
	await get_tree().create_timer(900.0).timeout
	print("GoyGI test: FAILED (watchdog: the test did not finish in 15 minutes)")
	get_tree().quit(1)


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	# ---- let the GI come up
	gi.set_loading_boost(true)
	var frames := 0
	# is_prepared() is true as long as the GPU has not come up, so it cannot be
	# used on its own: wait for the pipelines AND for the world around the camera.
	while frames < READY_TIMEOUT_FRAMES and (Time.get_ticks_msec() - t0) < READY_TIMEOUT_MS:
		var st := gi.get_stats()
		if bool(st["gpu"]) and gi.is_gpu_active() and int(st["near_updates"]) >= 6 \
				and int(st["chunks_required_loaded"]) >= int(st["chunks_required"]) and not bool(st["direct_building"]):
			break
		await get_tree().process_frame
		frames += 1
	gi.set_loading_boost(false)
	_note("GI prepared after %d frames (%.1f s), %s" % [frames, (Time.get_ticks_msec() - t0) / 1000.0, _stats_line()])
	_note("adapter: %s | rendering method: %s | RenderingDevice: %s" % [RenderingServer.get_video_adapter_name(),
			str(ProjectSettings.get_setting("rendering/renderer/rendering_method")), str(RenderingServer.get_rendering_device() != null)])
	var s := gi.get_stats()
	_check("gpu active", bool(s["gpu"]) and gi.is_gpu_active(), str(s["gpu"]))
	_check("near volume updated", int(s["near_updates"]) > 2, "updates=%d" % int(s["near_updates"]))
	_check("chunks required loaded", int(s["chunks_required_loaded"]) >= int(s["chunks_required"]),
			"%d/%d (mode %d)" % [int(s["chunks_required_loaded"]), int(s["chunks_required"]), int(s["chunk_mode"])])

	# ---- screenshots of every debug view
	var gi_on := await _shot("00_beauty_default", 0)
	await _shot("01_gi_only", 1)
	await _shot("02_voxels", 2)
	await _shot("03_gi_age", 3)
	await _shot("04_chunks", 4)
	await _shot("05_leak_guard", 5)

	# ---- the second room, seen through the doorway (bounce has to carry there)
	cam.position = Vector3(9.0, 1.6, 9.0)
	cam.look_at(Vector3(14.0, 1.2, 14.0), Vector3.UP)
	var far := await _shot("06_second_room", 0)
	cam.position = Vector3(0.0, 1.7, 4.6)
	cam.look_at(Vector3(0.0, 1.4, -2.0), Vector3.UP)
	# ---- close up of the wall: this is the "pure boxes" test
	cam.position = Vector3(0.2, 1.6, 2.2)
	cam.look_at(Vector3(0.2, 1.5, -6.0), Vector3.UP)
	var wall := await _shot("07_wall_closeup", 0)

	# ---- GI off: must still look like plain Godot (Environment ambient back)
	gi.gi_enabled = false
	var off := await _shot("08_gi_off", 0)
	gi.gi_enabled = true
	await _shot("09_gi_back_on", 0)

	# ---- metrics
	var blk := _blockiness(wall, WALL_CROP)
	_note("blockiness (wall crop, lower is smoother): %.5f" % blk)
	_check("wall is smooth (no voxel blocks)", blk < 0.06, "blockiness=%.5f (limit 0.06)" % blk)
	var on_lum := _mean_luminance(gi_on)
	var off_lum := _mean_luminance(off)
	_note("mean luminance: GI on %.4f, GI off %.4f (%.0f %% of GI on)" % [on_lum, off_lum, 100.0 * off_lum / maxf(on_lum, 1e-4)])
	# The GoyGI materials disable Godot's ambient while the GI is on; with the GI
	# off the Environment ambient has to come back, otherwise the whole scene
	# collapses to direct light only (the old "GI off looks worse than Godot").
	_check("GI off keeps the scene lit (ambient fallback)", off_lum > 0.45 * on_lum,
			"off=%.4f on=%.4f" % [off_lum, on_lum])
	_check("GI reaches the second room", _mean_luminance(far) > 0.0, "lum=%.4f" % _mean_luminance(far))

	_note("CPU %.2f ms/update, %d VPLs (%d dynamic), %d static lights" % [float(s["cpu_ms"]), int(s["vpls"]), int(s["vpls_dynamic"]), int(s["lights_static"])])
	_note("occupancy %s @ %.2f m, near %s @ %.2f m, cache %s @ %.2f m" % [str(s["occ"]), 0.25, str(s["size"]), float(s["cell"]), str(s["cache_size"]), float(s["cache_cell"])])
	_write_log()
	print("\n".join(_log))
	print("GoyGI test: %s (%d checks failed)" % ["FAILED" if _fail > 0 else "OK", _fail])
	get_tree().quit(1 if _fail > 0 else 0)


# ================================================================== level

func _build_level() -> void:
	level = Node3D.new()
	level.name = "Map"
	add_child(level)

	env = WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.22, 0.38, 0.72)
	psm.sky_horizon_color = Color(0.55, 0.62, 0.72)
	psm.ground_bottom_color = Color(0.12, 0.12, 0.13)
	psm.ground_horizon_color = Color(0.3, 0.3, 0.32)
	psm.sky_energy_multiplier = 1.0
	sky.sky_material = psm
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_BG
	e.ambient_light_energy = 0.35
	e.ambient_light_sky_contribution = 1.0
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.ssao_enabled = false
	e.glow_enabled = false
	env.environment = e
	add_child(env)

	sun = DirectionalLight3D.new()
	sun.position = Vector3(-8, 12, 6)
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.shadow_enabled = true
	add_child(sun)
	sun.look_at(Vector3(0, 0, 0), Vector3.UP)

	# ---- room 1 (the lit one): floor, ceiling, 4 walls, a doorway in the -Z wall
	_box(Vector3(0, -0.1, 0), Vector3(12, 0.2, 12), Color(0.62, 0.6, 0.56))
	_box(Vector3(0, 3.1, 0), Vector3(12, 0.2, 12), Color(0.72, 0.72, 0.72))
	_box(Vector3(6.0, 1.5, 0), Vector3(0.2, 3.0, 12), Color(0.75, 0.22, 0.18)) # red wall: colour bleeding
	_box(Vector3(-6.0, 1.5, 0), Vector3(0.2, 3.0, 12), Color(0.2, 0.65, 0.28)) # green wall
	_box(Vector3(0, 1.5, 6.0), Vector3(12, 3.0, 0.2), Color(0.7, 0.68, 0.64))
	_box(Vector3(-3.5, 1.5, -6.0), Vector3(5.0, 3.0, 0.2), Color(0.7, 0.68, 0.64)) # doorway: 2 m gap
	_box(Vector3(3.5, 1.5, -6.0), Vector3(5.0, 3.0, 0.2), Color(0.7, 0.68, 0.64))
	_box(Vector3(0, 2.7, -6.0), Vector3(2.0, 0.6, 0.2), Color(0.7, 0.68, 0.64)) # lintel over the doorway

	# ---- room 2: only reachable through the doorway (tests bounce carrying light)
	_box(Vector3(0, -0.1, -14.0), Vector3(12, 0.2, 16), Color(0.34, 0.33, 0.3))
	_box(Vector3(0, 3.1, -14.0), Vector3(12, 0.2, 16), Color(0.4, 0.4, 0.4))
	_box(Vector3(6.0, 1.5, -14.0), Vector3(0.2, 3.0, 16), Color(0.36, 0.34, 0.32))
	_box(Vector3(-6.0, 1.5, -14.0), Vector3(0.2, 3.0, 16), Color(0.36, 0.34, 0.32))
	_box(Vector3(0, 1.5, -22.0), Vector3(12, 3.0, 0.2), Color(0.36, 0.34, 0.32))

	# ---- sealed box with a bright lamp inside: nothing may leak out of it
	_box(Vector3(9.0, 1.0, 9.0), Vector3(2.4, 2.4, 2.4), Color(0.8, 0.78, 0.75))

	var trap := OmniLight3D.new()
	trap.position = Vector3(9.0, 1.0, 9.0)
	trap.light_energy = 6.0
	trap.omni_range = 3.0
	trap.light_color = Color(1.0, 0.5, 0.2)
	add_child(trap)

	# ---- the room lamp (the main indirect light source indoors)
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(0.0, 2.5, -1.0)
	lamp.light_energy = 3.0
	lamp.omni_range = 12.0
	lamp.light_color = Color(1.0, 0.86, 0.7)
	lamp.shadow_enabled = true
	add_child(lamp)

	cam = Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 4.6)
	cam.fov = 70.0
	add_child(cam)
	cam.look_at(Vector3(0.0, 1.5, -3.0), Vector3.UP)
	cam.current = true


## A static box: collision shape (what the GI voxelizes) + mesh + StandardMaterial
## (converted to the GoyGI Standard shader by auto_setup).
func _box(pos: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.92
	mat.metallic = 0.0
	mi.material_override = mat
	body.add_child(mi)
	level.add_child(body)


func _build_gi() -> void:
	gi = GIManager.new()
	gi.name = "GIManager"
	gi.occupancy_root = level
	gi.sun = sun
	gi.world_environment = env
	# deterministic settings: no device detection, no live settings binding
	gi.follow_game_settings = false
	gi.auto_quality = false
	gi.preview_in_editor = false
	gi.auto_setup = true
	gi.quality_preset = GIManager.Preset.HIGH
	# the whole map has to be covered, and the software renderer in CI is slow:
	# run as many updates as the machine allows, without the FPS governor
	gi.chunk_cache_enabled = true
	gi.chunk_mode = 2 # Balanced: chunk_distance either side of the camera
	gi.chunk_distance = 48.0
	gi.update_rate = 60
	gi.auto_budget = false
	add_child(gi)


# ================================================================== shots

## Sets a debug view, lets the GI settle, captures the viewport and returns the
## image. Writes res://artifacts/<name>.png.
func _shot(name: String, debug_view: int) -> Image:
	gi.debug_view = debug_view
	await _settle(SETTLE)
	var img := get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	_ensure_dir()
	var err := img.save_png(OUT_DIR + "/" + name + ".png")
	_note("shot %s (%dx%d)%s" % [name, img.get_width(), img.get_height(), "" if err == OK else " - SAVE FAILED"])
	return img


## Waits `frames` rendered frames, but never longer than SETTLE_MAX_MS: CI runs on
## a software Vulkan driver, so a frame can take a second or more.
func _settle(frames: int) -> void:
	var t := Time.get_ticks_msec()
	for i in frames:
		if (Time.get_ticks_msec() - t) > SETTLE_MAX_MS:
			break
		await get_tree().process_frame


# ================================================================== metrics

## Mean absolute second derivative of the luminance along x, over a crop:
## the cheapest honest "are the voxels showing as blocks" number. A filter that
## warps the sample point produces one-cell-wide steps -> large jumps here.
func _blockiness(img: Image, rect: Rect2i) -> float:
	var sum := 0.0
	var n := 0
	var r := rect.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	for y in range(r.position.y, r.end.y, 2):
		var a := _lum(img.get_pixel(r.position.x, y))
		var b := _lum(img.get_pixel(r.position.x + 1, y))
		for x in range(r.position.x + 2, r.end.x, 2):
			var c := _lum(img.get_pixel(x, y))
			sum += absf(b * 2.0 - a - c)
			n += 1
			a = b
			b = c
	return sum / maxf(float(n), 1.0)


func _mean_luminance(img: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			sum += _lum(img.get_pixel(x, y))
			n += 1
	return sum / maxf(float(n), 1.0)


static func _lum(c: Color) -> float:
	return c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722


# ================================================================== report

func _check(name: String, ok: bool, detail: String) -> void:
	_checks.append([name, ok, detail])
	if not ok:
		_fail += 1
	_note("%s %s (%s)" % ["PASS" if ok else "FAIL", name, detail])


func _note(text: String) -> void:
	_log.append(text)


func _stats_line() -> String:
	var s := gi.get_stats()
	return "near %d voxels, cache %d chunks, %d VPLs, cpu %.2f ms" % [int(s["voxels"]), int(s["chunks_loaded"]), int(s["vpls"]), float(s["cpu_ms"])]


func _ensure_dir() -> void:
	var abs := ProjectSettings.globalize_path(OUT_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


func _write_log() -> void:
	_ensure_dir()
	var f := FileAccess.open(OUT_DIR + "/summary.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_line("GoyGI visual test")
	for l in _log:
		f.store_line(l)
	f.store_line("")
	f.store_line("checks:")
	for c in _checks:
		f.store_line("  %s %s (%s)" % ["PASS" if c[1] else "FAIL", c[0], c[2]])
	f.close()
