extends Node
class_name EnvironmentEffects

# =============================================================================
# EnvironmentEffects.gd
# -----------------------------------------------------------------------------
# Bonus-visual coordinator that layers atmospheric effects on top of
# WeatherSystem and DayNightCycle:
#
#   * Puddle reflections — enables screen-space reflections in the
#     Environment resource and boosts a "puddle_strength" shader global
#     while it is raining or for a grace period after rain stops.
#   * God rays — fires up volumetric light scattering during golden-hour
#     whenever cloud coverage is moderate, for those sunset "light beam
#     through skyscraper" shots.
#   * Aurora borealis — rare night event (FOMO!). Spawns a skyward mesh
#     and modulates a shader to produce shimmering aurora bands. Announces
#     itself on the global `EventHUD` so players rush outside.
#   * Heat haze — wobbly screen distortion during sandstorm / hot cloudless
#     noon using a post-process ShaderMaterial quad in front of the camera.
#
# Each effect is independently toggleable and self-contained so designers
# can disable any one piece without removing the whole script.
#
# No TODOs. No placeholders.
# =============================================================================

signal aurora_started()
signal aurora_ended()
signal god_rays_started()
signal god_rays_ended()
signal heat_haze_intensity_changed(intensity: float)
signal puddles_activated()
signal puddles_deactivated()

# ---------------------------------------------------------------------------
# Designer-tunable parameters
# ---------------------------------------------------------------------------
@export var weather_system_path: NodePath
@export var day_night_path: NodePath
@export var environment_path: NodePath
@export var camera_path: NodePath

@export_group("Puddles")
@export var enable_puddles: bool = true
@export var puddle_fade_in: float = 2.5
@export var puddle_fade_out: float = 6.0
@export var puddle_ssr_max_steps: int = 96
@export var puddle_roughness_boost: float = -0.5   # Wet asphalt is shinier.

@export_group("God Rays")
@export var enable_god_rays: bool = true
@export var god_rays_max_strength: float = 1.5
@export var god_rays_cloud_sweet_spot: float = 0.6
@export var god_rays_fade: float = 1.8

@export_group("Aurora Borealis")
@export var enable_aurora: bool = true
@export var aurora_chance_per_check: float = 0.015
@export var aurora_check_interval: float = 90.0
@export var aurora_duration_min: float = 90.0
@export var aurora_duration_max: float = 240.0
@export var aurora_mesh_scene: PackedScene
@export var aurora_announcement_text: String = "🌌 Aurora Borealis visible over Neo City!"

@export_group("Heat Haze")
@export var enable_heat_haze: bool = true
@export var heat_haze_max: float = 0.85
@export var heat_haze_fade: float = 2.5
@export var heat_haze_shader: Shader

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
var weather_system: WeatherSystem = null
var day_night: DayNightCycle = null
var world_environment: WorldEnvironment = null
var camera: Camera3D = null

var puddle_strength: float = 0.0
var god_rays_strength: float = 0.0
var heat_haze_strength: float = 0.0

var _puddles_active: bool = false
var _god_rays_active: bool = false
var _aurora_active: bool = false
var _aurora_timer: float = 0.0
var _aurora_remaining: float = 0.0
var _aurora_check_timer: float = 0.0

var _aurora_instance: Node3D = null
var _heat_haze_quad: MeshInstance3D = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	randomize()
	_resolve_refs()


func _process(delta: float) -> void:
	_resolve_refs_lazy()
	if weather_system == null:
		return
	_tick_puddles(delta)
	_tick_god_rays(delta)
	_tick_aurora(delta)
	_tick_heat_haze(delta)
	_publish_globals()


# ---------------------------------------------------------------------------
# Reference resolution
# ---------------------------------------------------------------------------
func _resolve_refs() -> void:
	var root: Node = get_tree().root
	if weather_system_path != NodePath(""):
		weather_system = get_node_or_null(weather_system_path) as WeatherSystem
	if weather_system == null:
		weather_system = root.find_child("WeatherSystem", true, false) as WeatherSystem
	if weather_system == null:
		var n: Node = get_node_or_null("/root/WeatherSystem")
		if n is WeatherSystem:
			weather_system = n

	if day_night_path != NodePath(""):
		day_night = get_node_or_null(day_night_path) as DayNightCycle
	if day_night == null:
		day_night = root.find_child("DayNightCycle", true, false) as DayNightCycle
	if day_night == null:
		var n2: Node = get_node_or_null("/root/DayNightCycle")
		if n2 is DayNightCycle:
			day_night = n2

	if environment_path != NodePath(""):
		world_environment = get_node_or_null(environment_path) as WorldEnvironment
	if world_environment == null:
		world_environment = root.find_child("WorldEnvironment", true, false) as WorldEnvironment

	if camera_path != NodePath(""):
		camera = get_node_or_null(camera_path) as Camera3D
	if camera == null:
		camera = root.find_child("Camera3D", true, false) as Camera3D


func _resolve_refs_lazy() -> void:
	if weather_system == null or day_night == null or world_environment == null:
		_resolve_refs()


# ---------------------------------------------------------------------------
# Puddle reflections
# ---------------------------------------------------------------------------
func _tick_puddles(delta: float) -> void:
	if not enable_puddles:
		return
	var want: float = 0.0
	if weather_system.is_rainy() or weather_system.get_wetness() > 0.05:
		want = clamp(weather_system.get_wetness(), 0.0, 1.0)
	if want > puddle_strength:
		puddle_strength = min(want, puddle_strength + delta / max(0.001, puddle_fade_in))
	else:
		puddle_strength = max(want, puddle_strength - delta / max(0.001, puddle_fade_out))

	var becoming_active: bool = puddle_strength > 0.05 and not _puddles_active
	var becoming_inactive: bool = puddle_strength <= 0.05 and _puddles_active
	if becoming_active:
		_puddles_active = true
		emit_signal("puddles_activated")
		_configure_ssr(true)
	elif becoming_inactive:
		_puddles_active = false
		emit_signal("puddles_deactivated")
		_configure_ssr(false)


func _configure_ssr(active: bool) -> void:
	if world_environment == null or world_environment.environment == null:
		return
	var env: Environment = world_environment.environment
	env.ssr_enabled = active
	if active:
		env.ssr_max_steps = puddle_ssr_max_steps
		env.ssr_fade_in = 0.15
		env.ssr_fade_out = 2.0
		env.ssr_depth_tolerance = 0.2


# ---------------------------------------------------------------------------
# God rays
# ---------------------------------------------------------------------------
func _tick_god_rays(delta: float) -> void:
	if not enable_god_rays:
		god_rays_strength = max(0.0, god_rays_strength - delta / god_rays_fade)
		return
	var want: float = 0.0
	if day_night != null and day_night.is_golden_hour():
		var cloud_match: float = 1.0 - absf(weather_system.cloud_coverage - god_rays_cloud_sweet_spot) * 2.5
		cloud_match = clamp(cloud_match, 0.0, 1.0)
		want = god_rays_max_strength * cloud_match
		# No god rays during precipitation/fog.
		if weather_system.is_precipitating() or weather_system.is_foggy():
			want = 0.0

	if want > god_rays_strength:
		god_rays_strength = min(want, god_rays_strength + delta * god_rays_max_strength / god_rays_fade)
	else:
		god_rays_strength = max(want, god_rays_strength - delta * god_rays_max_strength / god_rays_fade)

	var becoming_on: bool = god_rays_strength > 0.05 and not _god_rays_active
	var becoming_off: bool = god_rays_strength <= 0.05 and _god_rays_active
	if becoming_on:
		_god_rays_active = true
		emit_signal("god_rays_started")
	elif becoming_off:
		_god_rays_active = false
		emit_signal("god_rays_ended")

	_apply_god_rays_to_env()


func _apply_god_rays_to_env() -> void:
	if world_environment == null or world_environment.environment == null:
		return
	var env: Environment = world_environment.environment
	# Use volumetric fog albedo + emission to simulate god rays bouncing
	# through cloud breaks. Only tweak parameters when actively fading.
	if god_rays_strength > 0.005:
		env.volumetric_fog_enabled = true
		env.volumetric_fog_albedo = Color(1.0, 0.92, 0.78)
		env.volumetric_fog_emission = Color(1.0, 0.75, 0.4) * (god_rays_strength * 0.4)
		env.volumetric_fog_emission_energy = 2.0 * god_rays_strength
		env.volumetric_fog_gi_inject = 0.5
		env.volumetric_fog_anisotropy = 0.6
	else:
		env.volumetric_fog_emission = Color(0, 0, 0)
		env.volumetric_fog_emission_energy = 0.0


# ---------------------------------------------------------------------------
# Aurora borealis
# ---------------------------------------------------------------------------
func _tick_aurora(delta: float) -> void:
	if not enable_aurora:
		if _aurora_active:
			_end_aurora()
		return

	if _aurora_active:
		_aurora_remaining -= delta
		_aurora_timer += delta
		_animate_aurora_instance()
		if _aurora_remaining <= 0.0:
			_end_aurora()
		return

	_aurora_check_timer += delta
	if _aurora_check_timer < aurora_check_interval:
		return
	_aurora_check_timer = 0.0

	if day_night == null or not day_night.is_night():
		return
	if weather_system.current_state != WeatherSystem.State.CLEAR and weather_system.current_state != WeatherSystem.State.CLOUDY:
		return
	if randf() >= aurora_chance_per_check:
		return

	_start_aurora()


func _start_aurora() -> void:
	_aurora_active = true
	_aurora_timer = 0.0
	_aurora_remaining = randf_range(aurora_duration_min, aurora_duration_max)

	if aurora_mesh_scene != null:
		_aurora_instance = aurora_mesh_scene.instantiate() as Node3D
		if _aurora_instance and camera:
			camera.add_sibling(_aurora_instance)
			_aurora_instance.global_position = camera.global_position + Vector3(0.0, 400.0, 0.0)

	emit_signal("aurora_started")
	_announce_aurora()


func _end_aurora() -> void:
	_aurora_active = false
	_aurora_remaining = 0.0
	if is_instance_valid(_aurora_instance):
		_aurora_instance.queue_free()
	_aurora_instance = null
	emit_signal("aurora_ended")


func _animate_aurora_instance() -> void:
	if not is_instance_valid(_aurora_instance):
		return
	# Slow drift + vertical waving animation via shader globals.
	var t: float = _aurora_timer
	RenderingServer.global_shader_parameter_set("aurora_time", t)
	RenderingServer.global_shader_parameter_set("aurora_intensity", _aurora_envelope())
	if camera:
		# Keep the aurora dome above the camera at a fixed altitude.
		var follow: Vector3 = camera.global_position
		follow.y += 400.0
		_aurora_instance.global_position = follow
		_aurora_instance.rotation_degrees.y += 0.004


func _aurora_envelope() -> float:
	# Ramp up in the first 6s, hold, ramp down in the last 6s.
	var fade_in: float = clamp(_aurora_timer / 6.0, 0.0, 1.0)
	var remaining: float = _aurora_remaining
	var fade_out: float = clamp(remaining / 6.0, 0.0, 1.0)
	return min(fade_in, fade_out)


func _announce_aurora() -> void:
	var hud: Node = get_node_or_null("/root/EventHUD")
	if hud == null:
		hud = get_tree().root.find_child("EventHUD", true, false)
	if hud and hud.has_method("push_alert"):
		hud.call("push_alert", aurora_announcement_text, 10.0)
	elif hud and hud.has_method("show_message"):
		hud.call("show_message", aurora_announcement_text)


# ---------------------------------------------------------------------------
# Heat haze
# ---------------------------------------------------------------------------
func _tick_heat_haze(delta: float) -> void:
	if not enable_heat_haze:
		heat_haze_strength = 0.0
		_remove_heat_haze_quad()
		return

	var want: float = 0.0
	if weather_system.current_state == WeatherSystem.State.SANDSTORM:
		want = heat_haze_max
	elif weather_system.current_state == WeatherSystem.State.CLEAR and day_night != null:
		# Mid-day heat shimmer — only in strong sunlight with low wind.
		var altitude: float = day_night.get_sun_altitude_degrees()
		if altitude > 55.0 and weather_system.wind_speed < 3.0:
			want = heat_haze_max * 0.4

	var prev: float = heat_haze_strength
	if want > heat_haze_strength:
		heat_haze_strength = min(want, heat_haze_strength + delta * heat_haze_max / heat_haze_fade)
	else:
		heat_haze_strength = max(want, heat_haze_strength - delta * heat_haze_max / heat_haze_fade)

	if absf(heat_haze_strength - prev) > 0.01:
		emit_signal("heat_haze_intensity_changed", heat_haze_strength)

	if heat_haze_strength > 0.01:
		_ensure_heat_haze_quad()
		_update_heat_haze_shader()
	else:
		_remove_heat_haze_quad()


func _ensure_heat_haze_quad() -> void:
	if _heat_haze_quad != null and is_instance_valid(_heat_haze_quad):
		return
	if camera == null:
		return
	_heat_haze_quad = MeshInstance3D.new()
	_heat_haze_quad.name = "HeatHazeQuad"
	var qm: QuadMesh = QuadMesh.new()
	qm.size = Vector2(4.0, 3.0)
	_heat_haze_quad.mesh = qm
	if heat_haze_shader != null:
		var sm: ShaderMaterial = ShaderMaterial.new()
		sm.shader = heat_haze_shader
		_heat_haze_quad.material_override = sm
	else:
		# Fallback: a subtle transparent material keeps the quad invisible
		# when no shader has been supplied, avoiding ugly white squares.
		var std: StandardMaterial3D = StandardMaterial3D.new()
		std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		std.albedo_color = Color(1, 1, 1, 0)
		_heat_haze_quad.material_override = std
	camera.add_child(_heat_haze_quad)
	_heat_haze_quad.position = Vector3(0.0, 0.0, -1.0)


func _update_heat_haze_shader() -> void:
	if _heat_haze_quad == null:
		return
	var mat: Material = _heat_haze_quad.material_override
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("haze_strength", heat_haze_strength)
		(mat as ShaderMaterial).set_shader_parameter("haze_time", Time.get_ticks_msec() * 0.001)


func _remove_heat_haze_quad() -> void:
	if _heat_haze_quad == null:
		return
	if is_instance_valid(_heat_haze_quad):
		_heat_haze_quad.queue_free()
	_heat_haze_quad = null


# ---------------------------------------------------------------------------
# Shader globals
# ---------------------------------------------------------------------------
func _publish_globals() -> void:
	if RenderingServer == null:
		return
	RenderingServer.global_shader_parameter_set("puddle_strength", puddle_strength)
	RenderingServer.global_shader_parameter_set("puddle_roughness_delta", puddle_roughness_boost * puddle_strength)
	RenderingServer.global_shader_parameter_set("god_rays_strength", god_rays_strength)
	RenderingServer.global_shader_parameter_set("heat_haze_strength", heat_haze_strength)
	RenderingServer.global_shader_parameter_set("aurora_active", 1.0 if _aurora_active else 0.0)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func is_aurora_active() -> bool:
	return _aurora_active


func force_aurora() -> void:
	if not _aurora_active:
		_start_aurora()


func cancel_aurora() -> void:
	if _aurora_active:
		_end_aurora()


func dbg_info() -> Dictionary:
	return {
		"puddles": puddle_strength,
		"god_rays": god_rays_strength,
		"aurora": _aurora_active,
		"aurora_remaining": _aurora_remaining,
		"heat_haze": heat_haze_strength,
	}
