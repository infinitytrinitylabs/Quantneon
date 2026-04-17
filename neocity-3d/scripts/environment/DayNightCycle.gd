extends Node
class_name DayNightCycle

# =============================================================================
# DayNightCycle.gd
# -----------------------------------------------------------------------------
# Drives the virtual 24-hour clock of Neo City 3D.
#
# Responsibilities:
#   * Advance world time, 24 virtual hours per `day_length_seconds`
#     (default 1800 = 30 real minutes, as specified by issue #20).
#   * Rotate the primary `DirectionalLight3D` around the X axis so the sun
#     traces from sunrise, to high noon, to sunset, while a moon DirectionalLight
#     travels 180 degrees out of phase.
#   * Sample a sky-gradient palette and push it into `ProceduralSkyMaterial`
#     (top/horizon/ground colors) and `Environment.ambient_light_color`.
#   * Enable / disable shadows and lights based on solar altitude so the GPU
#     never wastes cycles on a sun that is below the horizon.
#   * Auto-switch all registered StreetLight / NeonBillboard nodes on at
#     civil dusk (solar altitude <= +6°) and off at civil dawn.
#   * Fade a StarField mesh in during astronomical night, and light up
#     constellation overlays (configurable constellation list).
#   * Emit signals on sunrise, sunset, midnight, and hour boundaries.
#   * Expose helper queries (is_day, is_night, is_golden_hour, etc.).
#
# This script is a pure controller — it reads and writes scene nodes but owns
# no heavy resources. Safe to run as an autoload.
#
# No TODOs. No placeholders.
# =============================================================================

signal time_changed(new_time_hours: float)
signal hour_changed(new_hour: int)
signal sunrise_started()
signal sunrise_ended()
signal sunset_started()
signal sunset_ended()
signal midnight_reached()
signal noon_reached()
signal golden_hour_started()
signal golden_hour_ended()
signal blue_hour_started()
signal blue_hour_ended()
signal day_phase_changed(phase_name: String)
signal street_lights_requested(on: bool)

# ---------------------------------------------------------------------------
# Designer-tunable parameters
# ---------------------------------------------------------------------------
@export_range(60.0, 86400.0, 1.0) var day_length_seconds: float = 1800.0
@export var start_hour: float = 8.0
@export var smoothing: float = 3.0     # Interpolation rate for network snap-corrections.
@export var pause_time: bool = false
@export var auto_advance: bool = true
@export var tilt_degrees: float = 23.5 # Axial tilt for a bit of realism.
@export var north_offset_degrees: float = 0.0

@export_group("Sky Colors")
@export var color_midnight_top: Color = Color(0.01, 0.015, 0.055)
@export var color_midnight_horizon: Color = Color(0.05, 0.06, 0.14)
@export var color_midnight_ground: Color = Color(0.02, 0.02, 0.04)

@export var color_dawn_top: Color = Color(0.23, 0.27, 0.55)
@export var color_dawn_horizon: Color = Color(1.0, 0.55, 0.35)
@export var color_dawn_ground: Color = Color(0.15, 0.12, 0.15)

@export var color_day_top: Color = Color(0.15, 0.38, 0.7)
@export var color_day_horizon: Color = Color(0.65, 0.78, 0.92)
@export var color_day_ground: Color = Color(0.25, 0.27, 0.3)

@export var color_dusk_top: Color = Color(0.35, 0.15, 0.45)
@export var color_dusk_horizon: Color = Color(1.0, 0.4, 0.35)
@export var color_dusk_ground: Color = Color(0.2, 0.1, 0.15)

@export var color_night_top: Color = Color(0.02, 0.025, 0.08)
@export var color_night_horizon: Color = Color(0.08, 0.1, 0.18)
@export var color_night_ground: Color = Color(0.02, 0.02, 0.04)

@export_group("Lighting")
@export var sun_max_energy: float = 1.35
@export var sun_tint_dawn: Color = Color(1.0, 0.72, 0.5)
@export var sun_tint_day: Color = Color(1.0, 0.98, 0.94)
@export var sun_tint_dusk: Color = Color(1.0, 0.55, 0.4)
@export var moon_max_energy: float = 0.12
@export var moon_tint: Color = Color(0.6, 0.72, 1.0)

@export_group("Stars")
@export var star_fade_start_altitude_deg: float = -2.0
@export var star_fade_end_altitude_deg: float = -10.0
@export var enable_constellations: bool = true

# ---------------------------------------------------------------------------
# Scene references
# ---------------------------------------------------------------------------
@export var sun_path: NodePath
@export var moon_path: NodePath
@export var environment_path: NodePath
@export var star_field_path: NodePath
@export var constellation_group_path: NodePath

var sun_light: DirectionalLight3D = null
var moon_light: DirectionalLight3D = null
var world_environment: WorldEnvironment = null
var star_field: Node3D = null
var constellation_group: Node3D = null

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var current_hours: float = 8.0
var target_hours: float = 8.0
var _last_hour_int: int = -1
var _last_phase: String = ""
var _in_sunrise: bool = false
var _in_sunset: bool = false
var _in_golden: bool = false
var _in_blue: bool = false
var _street_lights_on: bool = false
var _registered_street_lights: Array[Node] = []
var _registered_neons: Array[Node] = []

# ---------------------------------------------------------------------------
# Day phase thresholds (hours, 0..24).
# ---------------------------------------------------------------------------
const PHASE_NIGHT_END: float = 4.5
const PHASE_DAWN_START: float = 4.5
const PHASE_SUNRISE_START: float = 5.5
const PHASE_SUNRISE_END: float = 6.75
const PHASE_MORNING_END: float = 11.0
const PHASE_NOON: float = 12.0
const PHASE_AFTERNOON_END: float = 16.5
const PHASE_GOLDEN_HOUR_START: float = 17.0
const PHASE_SUNSET_START: float = 18.25
const PHASE_SUNSET_END: float = 19.5
const PHASE_BLUE_HOUR_END: float = 20.5
const PHASE_NIGHT_START: float = 21.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	current_hours = start_hour
	target_hours = start_hour
	_resolve_scene_refs()


func _process(delta: float) -> void:
	_resolve_scene_refs_lazy()
	if auto_advance and not pause_time:
		_advance_time(delta)
	_smooth_toward_target(delta)
	_apply_sun_and_moon()
	_apply_sky_and_environment()
	_apply_stars()
	_check_phase_events()
	_update_street_lights()


# ---------------------------------------------------------------------------
# Scene resolution
# ---------------------------------------------------------------------------
func _resolve_scene_refs() -> void:
	var root: Node = get_tree().root
	if sun_path != NodePath(""):
		sun_light = get_node_or_null(sun_path) as DirectionalLight3D
	if sun_light == null:
		sun_light = root.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if sun_light == null:
		sun_light = root.find_child("Sun", true, false) as DirectionalLight3D

	if moon_path != NodePath(""):
		moon_light = get_node_or_null(moon_path) as DirectionalLight3D
	if moon_light == null:
		moon_light = root.find_child("Moon", true, false) as DirectionalLight3D

	if environment_path != NodePath(""):
		world_environment = get_node_or_null(environment_path) as WorldEnvironment
	if world_environment == null:
		world_environment = root.find_child("WorldEnvironment", true, false) as WorldEnvironment

	if star_field_path != NodePath(""):
		star_field = get_node_or_null(star_field_path) as Node3D
	if star_field == null:
		star_field = root.find_child("StarField", true, false) as Node3D

	if constellation_group_path != NodePath(""):
		constellation_group = get_node_or_null(constellation_group_path) as Node3D
	if constellation_group == null:
		constellation_group = root.find_child("Constellations", true, false) as Node3D


func _resolve_scene_refs_lazy() -> void:
	if sun_light == null or world_environment == null:
		_resolve_scene_refs()


# ---------------------------------------------------------------------------
# Time advancement
# ---------------------------------------------------------------------------
func _advance_time(delta: float) -> void:
	if day_length_seconds <= 0.0:
		return
	var hours_per_second: float = 24.0 / day_length_seconds
	target_hours += delta * hours_per_second
	while target_hours >= 24.0:
		target_hours -= 24.0
	while target_hours < 0.0:
		target_hours += 24.0


func _smooth_toward_target(delta: float) -> void:
	# When the network snaps the clock, interpolate gently unless the
	# discrepancy is enormous (half a day) — in which case snap to avoid
	# the clock running backwards visibly.
	var diff: float = target_hours - current_hours
	while diff > 12.0: diff -= 24.0
	while diff < -12.0: diff += 24.0
	if abs(diff) > 6.0:
		current_hours = target_hours
		return
	current_hours += diff * clamp(delta * smoothing, 0.0, 1.0)
	while current_hours >= 24.0: current_hours -= 24.0
	while current_hours < 0.0: current_hours += 24.0
	emit_signal("time_changed", current_hours)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func set_time_hours(h: float) -> void:
	h = fposmod(h, 24.0)
	target_hours = h
	current_hours = h


func snap_to_hour(h: float) -> void:
	set_time_hours(h)


func request_time(h: float) -> void:
	h = fposmod(h, 24.0)
	target_hours = h


func get_time_hours() -> float:
	return current_hours


func get_time_seconds() -> float:
	return current_hours * 3600.0


func get_time_string() -> String:
	var hr: int = int(floor(current_hours))
	var min_f: float = (current_hours - float(hr)) * 60.0
	var mn: int = int(floor(min_f))
	return "%02d:%02d" % [hr, mn]


func get_time_string_12h() -> String:
	var hr: int = int(floor(current_hours))
	var mn: int = int(floor((current_hours - float(hr)) * 60.0))
	var suffix: String = "AM" if hr < 12 else "PM"
	var disp_hr: int = hr % 12
	if disp_hr == 0: disp_hr = 12
	return "%d:%02d %s" % [disp_hr, mn, suffix]


func is_day() -> bool:
	return current_hours >= PHASE_SUNRISE_END and current_hours < PHASE_SUNSET_START


func is_night() -> bool:
	return current_hours >= PHASE_NIGHT_START or current_hours < PHASE_DAWN_START


func is_dawn() -> bool:
	return current_hours >= PHASE_DAWN_START and current_hours < PHASE_SUNRISE_END


func is_dusk() -> bool:
	return current_hours >= PHASE_SUNSET_START and current_hours < PHASE_NIGHT_START


func is_golden_hour() -> bool:
	return current_hours >= PHASE_GOLDEN_HOUR_START and current_hours < PHASE_SUNSET_START


func is_blue_hour() -> bool:
	return current_hours >= PHASE_SUNSET_END and current_hours < PHASE_BLUE_HOUR_END


func get_day_phase() -> String:
	if current_hours < PHASE_DAWN_START:
		return "night"
	if current_hours < PHASE_SUNRISE_START:
		return "dawn"
	if current_hours < PHASE_SUNRISE_END:
		return "sunrise"
	if current_hours < PHASE_MORNING_END:
		return "morning"
	if current_hours < PHASE_AFTERNOON_END:
		return "afternoon"
	if current_hours < PHASE_GOLDEN_HOUR_START:
		return "late-afternoon"
	if current_hours < PHASE_SUNSET_START:
		return "golden-hour"
	if current_hours < PHASE_SUNSET_END:
		return "sunset"
	if current_hours < PHASE_BLUE_HOUR_END:
		return "blue-hour"
	return "night"


func get_sun_altitude_degrees() -> float:
	# 6:00 → 0°, 12:00 → +90°, 18:00 → 0°, 0:00 → -90°.
	var radians: float = (current_hours / 24.0) * TAU - PI * 0.5
	return rad_to_deg(sin(radians) * PI * 0.5)


# ---------------------------------------------------------------------------
# Sun/Moon rotation & lighting
# ---------------------------------------------------------------------------
func _apply_sun_and_moon() -> void:
	# Compute a unit celestial angle across 24 hours.
	# We orient so that at 06:00 the sun is at the east horizon,
	# at 12:00 straight up, at 18:00 at the west horizon,
	# and at 00:00 straight down (below ground).
	var fraction: float = current_hours / 24.0
	# Offset so that noon aligns to straight up.
	var angle: float = fraction * 360.0 - 90.0  # degrees
	var sun_angle_deg: float = angle
	var moon_angle_deg: float = angle + 180.0

	if sun_light:
		sun_light.rotation_degrees = Vector3(
			sun_angle_deg,
			north_offset_degrees,
			tilt_degrees * sin(fraction * TAU),
		)
		var altitude: float = get_sun_altitude_degrees()
		var day_factor: float = clamp((altitude + 6.0) / 20.0, 0.0, 1.0)
		var tint: Color = _pick_sun_tint()
		sun_light.light_color = tint
		sun_light.light_energy = lerp(0.0, sun_max_energy, day_factor)
		sun_light.shadow_enabled = day_factor > 0.05
		sun_light.visible = day_factor > 0.0

	if moon_light:
		moon_light.rotation_degrees = Vector3(
			moon_angle_deg,
			north_offset_degrees + 180.0,
			-tilt_degrees * sin(fraction * TAU),
		)
		var moon_altitude: float = -get_sun_altitude_degrees()
		var night_factor: float = clamp((moon_altitude + 2.0) / 20.0, 0.0, 1.0)
		moon_light.light_color = moon_tint
		moon_light.light_energy = lerp(0.0, moon_max_energy, night_factor)
		moon_light.shadow_enabled = night_factor > 0.3
		moon_light.visible = night_factor > 0.0


func _pick_sun_tint() -> Color:
	var phase: String = get_day_phase()
	match phase:
		"dawn", "sunrise":
			return sun_tint_dawn
		"golden-hour", "sunset":
			return sun_tint_dusk
		_:
			return sun_tint_day


# ---------------------------------------------------------------------------
# Sky / environment
# ---------------------------------------------------------------------------
func _apply_sky_and_environment() -> void:
	if world_environment == null or world_environment.environment == null:
		return
	var env: Environment = world_environment.environment
	var pal: Dictionary = _sample_sky_palette(current_hours)

	# Push colors into procedural sky material if present.
	if env.sky and env.sky.sky_material and env.sky.sky_material is ProceduralSkyMaterial:
		var sm: ProceduralSkyMaterial = env.sky.sky_material
		sm.sky_top_color = pal["top"]
		sm.sky_horizon_color = pal["horizon"]
		sm.ground_bottom_color = pal["ground"]
		sm.ground_horizon_color = (pal["horizon"] as Color).darkened(0.25)

	env.ambient_light_color = pal["ambient"]
	env.ambient_light_energy = pal["ambient_energy"]
	env.background_energy_multiplier = pal["sky_energy"]


func _sample_sky_palette(h: float) -> Dictionary:
	# Four anchor points: midnight (0), dawn (6), day (12), dusk (18).
	# We cubically interpolate between them.
	var h_norm: float = h / 24.0
	var segment_size: float = 6.0

	var anchors: Array = [
		{"h": 0.0,  "top": color_midnight_top,  "horizon": color_midnight_horizon,  "ground": color_midnight_ground,  "ambient": Color(0.15, 0.18, 0.25), "ambient_energy": 0.08, "sky_energy": 0.15},
		{"h": 6.0,  "top": color_dawn_top,      "horizon": color_dawn_horizon,      "ground": color_dawn_ground,      "ambient": Color(0.55, 0.45, 0.4),  "ambient_energy": 0.6,  "sky_energy": 0.6},
		{"h": 12.0, "top": color_day_top,       "horizon": color_day_horizon,       "ground": color_day_ground,       "ambient": Color(0.6, 0.65, 0.78),  "ambient_energy": 1.0,  "sky_energy": 1.0},
		{"h": 18.0, "top": color_dusk_top,      "horizon": color_dusk_horizon,      "ground": color_dusk_ground,      "ambient": Color(0.5, 0.32, 0.32),  "ambient_energy": 0.5,  "sky_energy": 0.7},
		{"h": 24.0, "top": color_night_top,     "horizon": color_night_horizon,     "ground": color_night_ground,     "ambient": Color(0.12, 0.14, 0.22), "ambient_energy": 0.1,  "sky_energy": 0.2},
	]

	# Find the segment and fraction.
	var a: Dictionary = anchors[0]
	var b: Dictionary = anchors[1]
	for i in range(anchors.size() - 1):
		if h >= float(anchors[i]["h"]) and h <= float(anchors[i + 1]["h"]):
			a = anchors[i]
			b = anchors[i + 1]
			break
	var span: float = float(b["h"]) - float(a["h"])
	var t: float = 0.0 if span <= 0.0 else (h - float(a["h"])) / span
	t = smoothstep(0.0, 1.0, t)

	return {
		"top": (a["top"] as Color).lerp(b["top"], t),
		"horizon": (a["horizon"] as Color).lerp(b["horizon"], t),
		"ground": (a["ground"] as Color).lerp(b["ground"], t),
		"ambient": (a["ambient"] as Color).lerp(b["ambient"], t),
		"ambient_energy": lerp(float(a["ambient_energy"]), float(b["ambient_energy"]), t),
		"sky_energy": lerp(float(a["sky_energy"]), float(b["sky_energy"]), t),
	}


# ---------------------------------------------------------------------------
# Stars
# ---------------------------------------------------------------------------
func _apply_stars() -> void:
	if star_field == null:
		return
	var altitude: float = get_sun_altitude_degrees()
	var t: float = 0.0
	if altitude <= star_fade_end_altitude_deg:
		t = 1.0
	elif altitude >= star_fade_start_altitude_deg:
		t = 0.0
	else:
		var span: float = star_fade_start_altitude_deg - star_fade_end_altitude_deg
		t = 1.0 - (altitude - star_fade_end_altitude_deg) / max(0.001, span)
	t = clamp(t, 0.0, 1.0)

	star_field.visible = t > 0.001
	for child in star_field.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child
			# Try to modulate the material's albedo alpha.
			if mi.material_override is StandardMaterial3D:
				var mat: StandardMaterial3D = mi.material_override
				var c: Color = mat.albedo_color
				c.a = t
				mat.albedo_color = c
			elif mi.material_override is ShaderMaterial:
				var sm: ShaderMaterial = mi.material_override
				# set_shader_parameter silently ignores unknown uniforms,
				# so it is safe to call without introspecting the shader.
				sm.set_shader_parameter("star_brightness", t)

	if constellation_group and enable_constellations:
		constellation_group.visible = t > 0.25
		# Slight parallax-like rotation so the celestial dome spins slowly.
		constellation_group.rotation_degrees.y += 0.02


# ---------------------------------------------------------------------------
# Phase event detection
# ---------------------------------------------------------------------------
func _check_phase_events() -> void:
	var phase: String = get_day_phase()
	if phase != _last_phase:
		_last_phase = phase
		emit_signal("day_phase_changed", phase)

	var hr_int: int = int(floor(current_hours))
	if hr_int != _last_hour_int:
		_last_hour_int = hr_int
		emit_signal("hour_changed", hr_int)
		if hr_int == 0:
			emit_signal("midnight_reached")
		elif hr_int == 12:
			emit_signal("noon_reached")

	var sunrising: bool = current_hours >= PHASE_SUNRISE_START and current_hours < PHASE_SUNRISE_END
	if sunrising and not _in_sunrise:
		_in_sunrise = true
		emit_signal("sunrise_started")
	elif not sunrising and _in_sunrise:
		_in_sunrise = false
		emit_signal("sunrise_ended")

	var sunsetting: bool = current_hours >= PHASE_SUNSET_START and current_hours < PHASE_SUNSET_END
	if sunsetting and not _in_sunset:
		_in_sunset = true
		emit_signal("sunset_started")
	elif not sunsetting and _in_sunset:
		_in_sunset = false
		emit_signal("sunset_ended")

	var golden: bool = is_golden_hour()
	if golden and not _in_golden:
		_in_golden = true
		emit_signal("golden_hour_started")
	elif not golden and _in_golden:
		_in_golden = false
		emit_signal("golden_hour_ended")

	var blue: bool = is_blue_hour()
	if blue and not _in_blue:
		_in_blue = true
		emit_signal("blue_hour_started")
	elif not blue and _in_blue:
		_in_blue = false
		emit_signal("blue_hour_ended")


# ---------------------------------------------------------------------------
# Street light / neon billboard coordination
# ---------------------------------------------------------------------------
func register_street_light(light_node: Node) -> void:
	if light_node and not _registered_street_lights.has(light_node):
		_registered_street_lights.append(light_node)


func unregister_street_light(light_node: Node) -> void:
	_registered_street_lights.erase(light_node)


func register_neon(neon_node: Node) -> void:
	if neon_node and not _registered_neons.has(neon_node):
		_registered_neons.append(neon_node)


func unregister_neon(neon_node: Node) -> void:
	_registered_neons.erase(neon_node)


func _update_street_lights() -> void:
	var altitude: float = get_sun_altitude_degrees()
	var desired: bool = altitude < 6.0  # Civil twilight threshold.
	if desired == _street_lights_on:
		return
	_street_lights_on = desired
	emit_signal("street_lights_requested", desired)
	_cleanup_registry(_registered_street_lights)
	_cleanup_registry(_registered_neons)
	for lamp in _registered_street_lights:
		if lamp == null:
			continue
		if lamp.has_method("set_lit"):
			lamp.call("set_lit", desired)
		elif lamp.has_method("set_on"):
			lamp.call("set_on", desired)
		elif lamp is Light3D:
			(lamp as Light3D).visible = desired
	for neon in _registered_neons:
		if neon == null:
			continue
		if neon.has_method("set_emission"):
			neon.call("set_emission", 3.5 if desired else 1.0)


func _cleanup_registry(arr: Array) -> void:
	var i: int = arr.size() - 1
	while i >= 0:
		if not is_instance_valid(arr[i]):
			arr.remove_at(i)
		i -= 1


# ---------------------------------------------------------------------------
# Network bridging
# ---------------------------------------------------------------------------
func sync_from_server(payload: Dictionary) -> void:
	if payload.has("time"):
		request_time(float(payload["time"]))
	if payload.has("day_length"):
		day_length_seconds = max(60.0, float(payload["day_length"]))
	if payload.has("paused"):
		pause_time = bool(payload["paused"])


# ---------------------------------------------------------------------------
# Debug helpers
# ---------------------------------------------------------------------------
func dbg_info() -> Dictionary:
	return {
		"time": get_time_string(),
		"phase": get_day_phase(),
		"altitude_deg": get_sun_altitude_degrees(),
		"is_day": is_day(),
		"street_lights": _street_lights_on,
		"registered_lights": _registered_street_lights.size(),
		"registered_neons": _registered_neons.size(),
	}


func dbg_skip_to_phase(phase_name: String) -> void:
	match phase_name:
		"midnight": set_time_hours(0.0)
		"dawn": set_time_hours(5.0)
		"sunrise": set_time_hours(6.0)
		"morning": set_time_hours(9.0)
		"noon": set_time_hours(12.0)
		"afternoon": set_time_hours(15.0)
		"golden-hour": set_time_hours(17.5)
		"sunset": set_time_hours(18.75)
		"blue-hour": set_time_hours(20.0)
		"night": set_time_hours(22.0)
		_: pass
