## EnvironmentEffects — Post-process and visual effects layer for Neo City
## Handles puddle reflections after rain, god rays during golden hour,
## aurora borealis overlays, heat haze distortion, and screen-space effects.
extends Node

# ── Signals ───────────────────────────────────────────────────────────────────

signal puddles_forming()
signal puddles_drying()
signal god_rays_active(intensity: float)
signal aurora_overlay_changed(intensity: float)
signal heat_haze_changed(intensity: float)
signal effect_state_changed(effect_name: String, active: bool)

# ── Exports ───────────────────────────────────────────────────────────────────

@export var enable_puddle_reflections: bool = true
@export var enable_god_rays: bool = true
@export var enable_aurora_overlay: bool = true
@export var enable_heat_haze: bool = true
@export var enable_screen_space_reflections: bool = true
@export var puddle_dry_time_seconds: float = 300.0   # 5 minutes after rain stops
@export var puddle_wetness_decay_rate: float = 0.002  # per second
@export var god_ray_max_intensity: float = 1.0
@export var aurora_color_a: Color = Color(0.15, 0.85, 0.5, 0.6)
@export var aurora_color_b: Color = Color(0.3, 0.3, 1.0, 0.7)
@export var aurora_color_c: Color = Color(0.8, 0.2, 0.9, 0.5)
@export var heat_haze_max_intensity: float = 0.8
@export var debug_effects: bool = false

# ── Internal State ─────────────────────────────────────────────────────────────

var surface_wetness: float = 0.0         # 0 = dry, 1 = fully wet
var puddle_coverage: float = 0.0         # 0 = no puddles, 1 = maximum puddles
var is_raining: bool = false
var time_since_rain_stopped: float = 0.0
var god_ray_intensity: float = 0.0
var aurora_overlay_intensity: float = 0.0
var heat_haze_intensity: float = 0.0
var heat_haze_time: float = 0.0
var god_ray_time: float = 0.0
var aurora_wave_time: float = 0.0
var _ssr_was_enabled: bool = false

# ── Scene References ───────────────────────────────────────────────────────────

var weather_system: Node = null
var day_night_cycle: Node = null
var world_environment: WorldEnvironment = null
var post_process_env: Environment = null
var camera: Camera3D = null

# ── Wet Surface Material Cache ─────────────────────────────────────────────────

var _wet_materials: Array = []
var _original_roughness: Dictionary = {}  # material → original roughness value

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_locate_scene_nodes()
	_cache_wet_materials()
	if debug_effects:
		print("[EnvironmentEffects] Initialized — %d wet materials cached." % _wet_materials.size())

func _process(delta: float) -> void:
	_update_puddles(delta)
	_update_god_rays(delta)
	_update_aurora_overlay(delta)
	_update_heat_haze(delta)
	_apply_screen_space_effects()
	heat_haze_time += delta
	god_ray_time   += delta
	aurora_wave_time += delta * 0.4

# ── Node Discovery ─────────────────────────────────────────────────────────────

func _locate_scene_nodes() -> void:
	world_environment = get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_environment:
		post_process_env = world_environment.environment
	camera = get_viewport().get_camera_3d()
	if not camera:
		camera = get_tree().root.find_child("Camera3D", true, false) as Camera3D
	weather_system = get_tree().root.find_child("WeatherSystem", true, false)
	day_night_cycle = get_tree().root.find_child("DayNightCycle", true, false)
	if weather_system and weather_system.has_signal("weather_changed"):
		weather_system.connect("weather_changed", _on_weather_changed)
	if weather_system and weather_system.has_signal("thunder_strike"):
		weather_system.connect("thunder_strike", _on_thunder_strike)

# ── Wet Material Discovery ─────────────────────────────────────────────────────

func _cache_wet_materials() -> void:
	_wet_materials.clear()
	_original_roughness.clear()
	var mesh_instances := get_tree().root.find_children("*", "MeshInstance3D", true, false)
	for mi_node in mesh_instances:
		var mi := mi_node as MeshInstance3D
		if not mi:
			continue
		for i in range(mi.get_surface_override_material_count()):
			var mat := mi.get_surface_override_material(i) as StandardMaterial3D
			if mat and not _wet_materials.has(mat):
				_wet_materials.append(mat)
				_original_roughness[mat] = mat.roughness

# ── Puddle Reflections ─────────────────────────────────────────────────────────

func _update_puddles(delta: float) -> void:
	if not enable_puddle_reflections:
		return
	if is_raining:
		surface_wetness = minf(surface_wetness + delta * 0.04, 1.0)
		time_since_rain_stopped = 0.0
	else:
		time_since_rain_stopped += delta
		var dry_rate := 1.0 / puddle_dry_time_seconds
		surface_wetness = maxf(surface_wetness - delta * dry_rate, 0.0)

	var prev_coverage := puddle_coverage
	puddle_coverage = surface_wetness * surface_wetness

	if prev_coverage < 0.05 and puddle_coverage >= 0.05:
		puddles_forming.emit()
		effect_state_changed.emit("puddles", true)
	elif prev_coverage >= 0.05 and puddle_coverage < 0.05:
		puddles_drying.emit()
		effect_state_changed.emit("puddles", false)

	_apply_wet_surfaces(puddle_coverage)
	_apply_screen_space_reflections_strength(puddle_coverage)

func _apply_wet_surfaces(wetness: float) -> void:
	for mat in _wet_materials:
		if not is_instance_valid(mat):
			continue
		var original_rough: float = _original_roughness.get(mat, 0.8)
		var wet_roughness := lerpf(original_rough, 0.05, wetness * 0.8)
		mat.roughness = wet_roughness
		var orig_metallic: float = mat.metallic
		mat.metallic = lerpf(orig_metallic, 0.4, wetness * 0.6)

func _apply_screen_space_reflections_strength(wetness: float) -> void:
	if not post_process_env or not enable_screen_space_reflections:
		return
	var ssr_enabled := wetness > 0.1
	if ssr_enabled != _ssr_was_enabled:
		_ssr_was_enabled = ssr_enabled
		post_process_env.ssr_enabled = ssr_enabled
	if ssr_enabled:
		post_process_env.ssr_max_steps = int(lerpf(16.0, 64.0, wetness))
		post_process_env.ssr_depth_tolerance = lerpf(0.5, 0.15, wetness)

# ── God Rays ──────────────────────────────────────────────────────────────────

func _update_god_rays(delta: float) -> void:
	if not enable_god_rays:
		god_ray_intensity = 0.0
		return
	var target_intensity := _compute_god_ray_target()
	god_ray_intensity = lerpf(god_ray_intensity, target_intensity, delta * 0.5)
	_apply_god_rays(god_ray_intensity)
	if god_ray_intensity > 0.05:
		god_rays_active.emit(god_ray_intensity)

func _compute_god_ray_target() -> float:
	if not day_night_cycle:
		return 0.0
	if not day_night_cycle.has_method("is_golden_hour"):
		return 0.0
	var is_golden: bool = day_night_cycle.is_golden_hour()
	if not is_golden:
		return 0.0
	var cloud_factor := 1.0
	if weather_system and weather_system.has_method("get_visibility"):
		cloud_factor = weather_system.get_visibility()
	return cloud_factor * god_ray_max_intensity

func _apply_god_rays(intensity: float) -> void:
	if not post_process_env:
		return
	var active := intensity > 0.05
	post_process_env.volumetric_fog_enabled = active or (post_process_env.fog_enabled and post_process_env.fog_density > 0.01)
	if active:
		post_process_env.volumetric_fog_density = intensity * 0.08
		post_process_env.volumetric_fog_gi_inject = intensity * 0.5
		post_process_env.volumetric_fog_sky_affect = intensity * 0.7
		post_process_env.volumetric_fog_anisotropy = 0.8

# ── Aurora Borealis Overlay ────────────────────────────────────────────────────

func _update_aurora_overlay(delta: float) -> void:
	if not enable_aurora_overlay:
		aurora_overlay_intensity = 0.0
		return
	var target := 0.0
	if day_night_cycle and day_night_cycle.has_method("get_aurora_intensity"):
		target = day_night_cycle.get_aurora_intensity()
	aurora_overlay_intensity = lerpf(aurora_overlay_intensity, target, delta * 0.3)
	_apply_aurora_visual(aurora_overlay_intensity)
	aurora_overlay_changed.emit(aurora_overlay_intensity)

func _apply_aurora_visual(intensity: float) -> void:
	if not post_process_env or intensity < 0.01:
		return
	var wave1 := (sin(aurora_wave_time * 0.8 + 1.2) * 0.5 + 0.5)
	var wave2 := (sin(aurora_wave_time * 1.3 + 2.4) * 0.5 + 0.5)
	var blended_aurora := aurora_color_a.lerp(aurora_color_b, wave1).lerp(aurora_color_c, wave2 * 0.4)
	post_process_env.adjustment_enabled = intensity > 0.2
	if post_process_env.adjustment_enabled:
		var base_color_correction := Color(1.0, 1.0, 1.0)
		var aurora_tint := base_color_correction.lerp(
			Color(1.0 + blended_aurora.r * intensity * 0.15,
				  1.0 + blended_aurora.g * intensity * 0.12,
				  1.0 + blended_aurora.b * intensity * 0.18),
			intensity
		)
		post_process_env.adjustment_color_correction = null

# ── Heat Haze ─────────────────────────────────────────────────────────────────

func _update_heat_haze(delta: float) -> void:
	if not enable_heat_haze:
		heat_haze_intensity = 0.0
		return
	var target := _compute_heat_haze_target()
	heat_haze_intensity = lerpf(heat_haze_intensity, target, delta * 0.4)
	heat_haze_changed.emit(heat_haze_intensity)

func _compute_heat_haze_target() -> float:
	if not weather_system:
		return 0.0
	if not weather_system.has_method("get_temperature"):
		return 0.0
	var temp: float = weather_system.get_temperature()
	if temp < 28.0:
		return 0.0
	var noon_factor := 0.0
	if day_night_cycle and day_night_cycle.has_method("get_hour"):
		var hour: float = day_night_cycle.get_hour()
		noon_factor = 1.0 - absf(hour - 13.0) / 7.0
		noon_factor = clampf(noon_factor, 0.0, 1.0)
	var temp_factor := clampf((temp - 28.0) / 15.0, 0.0, 1.0)
	return temp_factor * noon_factor * heat_haze_max_intensity

func get_heat_haze_intensity() -> float:
	return heat_haze_intensity

func get_heat_haze_wave(uv_x: float, uv_y: float) -> Vector2:
	var t := heat_haze_time
	var wave_x := sin(uv_y * 8.0 + t * 2.1) * 0.003 * heat_haze_intensity
	var wave_y := sin(uv_x * 6.0 + t * 1.7) * 0.002 * heat_haze_intensity
	return Vector2(wave_x, wave_y)

# ── Screen Space Effects ───────────────────────────────────────────────────────

func _apply_screen_space_effects() -> void:
	if not post_process_env:
		return
	_apply_exposure_from_time()
	_apply_ssao_from_weather()

func _apply_exposure_from_time() -> void:
	if not day_night_cycle or not day_night_cycle.has_method("is_nighttime"):
		return
	var target_exposure := 1.0
	if day_night_cycle.is_nighttime():
		target_exposure = 1.4
	elif day_night_cycle.is_golden_hour():
		target_exposure = 0.9
	post_process_env.tonemap_exposure = lerpf(post_process_env.tonemap_exposure, target_exposure, 0.02)

func _apply_ssao_from_weather() -> void:
	if not weather_system or not weather_system.has_method("get_visibility"):
		return
	var visibility: float = weather_system.get_visibility()
	post_process_env.ssao_enabled = true
	post_process_env.ssao_radius = lerpf(1.0, 2.5, 1.0 - visibility)
	post_process_env.ssao_intensity = lerpf(2.0, 5.0, 1.0 - visibility)

# ── Weather Event Handlers ─────────────────────────────────────────────────────

func _on_weather_changed(old_state: int, new_state: int) -> void:
	var rain_states := [2, 3, 4]  # RAIN, HEAVY_RAIN, THUNDERSTORM
	is_raining = new_state in rain_states
	if not is_raining and old_state in rain_states:
		time_since_rain_stopped = 0.0
	if debug_effects:
		print("[EnvironmentEffects] Weather changed: %d → %d  raining=%s" % [old_state, new_state, str(is_raining)])

func _on_thunder_strike(intensity: float) -> void:
	_trigger_thunder_flash(intensity)

func _trigger_thunder_flash(intensity: float) -> void:
	if not post_process_env:
		return
	var original_exposure := post_process_env.tonemap_exposure
	post_process_env.tonemap_exposure = original_exposure + intensity * 2.0
	var tween := create_tween()
	tween.tween_property(post_process_env, "tonemap_exposure", original_exposure, 0.3)

# ── Glow / Bloom Adjustments ───────────────────────────────────────────────────

func set_neon_glow_intensity(multiplier: float) -> void:
	if not post_process_env:
		return
	post_process_env.glow_enabled = multiplier > 0.01
	if post_process_env.glow_enabled:
		post_process_env.glow_intensity = multiplier
		post_process_env.glow_strength  = multiplier * 0.8
		post_process_env.glow_bloom     = multiplier * 0.2

func boost_neon_at_night() -> void:
	if not day_night_cycle:
		return
	var night_factor := 0.0
	if day_night_cycle.has_method("_get_night_factor"):
		var hour: float = day_night_cycle.get_hour()
		if hour >= 21.0 or hour < 5.0:
			night_factor = 1.0
		elif hour >= 19.0:
			night_factor = (hour - 19.0) / 2.0
		elif hour >= 5.0 and hour < 7.0:
			night_factor = 1.0 - (hour - 5.0) / 2.0
	var rain_boost := 0.0
	if is_raining:
		rain_boost = surface_wetness * 0.3
	var glow_mult := lerpf(0.8, 1.8, night_factor) + rain_boost
	set_neon_glow_intensity(glow_mult)

# ── Chromatic Aberration (Thunderstorm / Sandstorm) ───────────────────────────

func set_chromatic_aberration(strength: float) -> void:
	if not camera:
		return

# ── Depth of Field (Fog weather) ──────────────────────────────────────────────

func update_dof_for_weather() -> void:
	if not post_process_env or not weather_system:
		return
	var vis := 1.0
	if weather_system.has_method("get_visibility"):
		vis = weather_system.get_visibility()
	var use_dof := vis < 0.4
	post_process_env.dof_blur_far_enabled = use_dof
	if use_dof:
		post_process_env.dof_blur_far_distance = lerpf(5.0, 80.0, vis)
		post_process_env.dof_blur_far_transition = lerpf(2.0, 20.0, vis)
		post_process_env.dof_blur_amount = lerpf(0.6, 0.1, vis)

# ── Serialization ─────────────────────────────────────────────────────────────

func serialize() -> Dictionary:
	return {
		"surface_wetness": surface_wetness,
		"puddle_coverage": puddle_coverage,
		"is_raining": is_raining,
		"time_since_rain_stopped": time_since_rain_stopped,
		"god_ray_intensity": god_ray_intensity,
		"aurora_overlay_intensity": aurora_overlay_intensity,
		"heat_haze_intensity": heat_haze_intensity,
	}

func deserialize(data: Dictionary) -> void:
	surface_wetness           = data.get("surface_wetness", 0.0)
	puddle_coverage           = data.get("puddle_coverage", 0.0)
	is_raining                = data.get("is_raining", false)
	time_since_rain_stopped   = data.get("time_since_rain_stopped", 0.0)
	god_ray_intensity         = data.get("god_ray_intensity", 0.0)
	aurora_overlay_intensity  = data.get("aurora_overlay_intensity", 0.0)
	heat_haze_intensity       = data.get("heat_haze_intensity", 0.0)

## Returns a debug string summarizing active effects.
func get_debug_string() -> String:
	var parts := []
	if puddle_coverage > 0.05:
		parts.append("Puddles:%.0f%%" % (puddle_coverage * 100))
	if god_ray_intensity > 0.05:
		parts.append("GodRays:%.2f" % god_ray_intensity)
	if aurora_overlay_intensity > 0.05:
		parts.append("Aurora:%.2f" % aurora_overlay_intensity)
	if heat_haze_intensity > 0.05:
		parts.append("HeatHaze:%.2f" % heat_haze_intensity)
	if parts.is_empty():
		return "EnvironmentEffects: idle"
	return "EnvironmentEffects: " + ", ".join(parts)

## Force-refresh all material wetness immediately (e.g. zone load).
func refresh_wet_materials() -> void:
	_cache_wet_materials()
	_apply_wet_surfaces(puddle_coverage)

## Register a material to receive wetness effects dynamically.
func register_wet_material(mat: StandardMaterial3D) -> void:
	if mat and not _wet_materials.has(mat):
		_wet_materials.append(mat)
		_original_roughness[mat] = mat.roughness

## Unregister a material from wetness effects.
func unregister_wet_material(mat: StandardMaterial3D) -> void:
	_wet_materials.erase(mat)
	_original_roughness.erase(mat)

## Instantly set surface wetness (e.g., for zone transitions into a rainy area).
func set_surface_wetness(value: float) -> void:
	surface_wetness = clampf(value, 0.0, 1.0)
	puddle_coverage = surface_wetness * surface_wetness
	_apply_wet_surfaces(puddle_coverage)
	_apply_screen_space_reflections_strength(puddle_coverage)
