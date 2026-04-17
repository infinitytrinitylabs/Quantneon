## DayNightCycle — Full 24-hour day/night cycle for the Neo City metaverse
## Compresses a 24-hour day into 30 minutes real-time.
## Controls sun/moon DirectionalLight3D, sky gradients, star field,
## and auto-enables/disables street lights at dusk and dawn.
extends Node

# ── Signals ───────────────────────────────────────────────────────────────────

signal hour_changed(new_hour: int)
signal sunrise()
signal sunset()
signal midnight()
signal noon()
signal dusk_started()
signal dawn_started()
signal street_lights_on()
signal street_lights_off()
signal time_of_day_changed(normalized_time: float)

# ── Export Parameters ──────────────────────────────────────────────────────────

@export var day_duration_minutes: float = 30.0
@export var start_hour: float = 8.0
@export var time_scale: float = 1.0
@export var sun_path_tilt_degrees: float = 30.0
@export var moon_phase: int = 4    # 0-7 (0=new, 4=full)
@export var latitude_degrees: float = 37.0
@export var enable_stars: bool = true
@export var enable_moon: bool = true
@export var enable_street_lights: bool = true
@export var street_light_on_hour: float = 19.5
@export var street_light_off_hour: float = 6.5
@export var enable_aurora: bool = true
@export var aurora_chance_per_night: float = 0.15
@export var debug_time: bool = false

# ── Internal State ─────────────────────────────────────────────────────────────

var current_hour: float = 8.0       # 0.0 – 23.999
var current_day: int = 0
var previous_integer_hour: int = -1
var street_lights_enabled: bool = false
var aurora_active: bool = false
var aurora_intensity: float = 0.0
var aurora_duration_remaining: float = 0.0
var star_twinkle_offset: float = 0.0
var sun_intensity_override: float = -1.0  # -1 = auto
var moon_intensity_override: float = -1.0

# ── Cached Sky Gradient Keyframes ─────────────────────────────────────────────
# Each keyframe: [hour, sky_top, sky_horizon, ground, sun_energy, ambient_energy, sun_color]

const SKY_KEYFRAMES: Array = [
	# Midnight
	{ "hour": 0.0,  "sky_top": Color(0.01, 0.01, 0.06), "sky_horizon": Color(0.03, 0.03, 0.08),
	  "ground": Color(0.01, 0.01, 0.02), "sun_energy": 0.0, "ambient": 0.04,
	  "sun_color": Color(0.5, 0.6, 1.0) },
	# Pre-dawn
	{ "hour": 4.5,  "sky_top": Color(0.04, 0.04, 0.12), "sky_horizon": Color(0.12, 0.08, 0.18),
	  "ground": Color(0.02, 0.01, 0.03), "sun_energy": 0.0, "ambient": 0.06,
	  "sun_color": Color(0.6, 0.5, 0.9) },
	# Sunrise start
	{ "hour": 6.0,  "sky_top": Color(0.12, 0.15, 0.4),  "sky_horizon": Color(0.8, 0.45, 0.15),
	  "ground": Color(0.06, 0.04, 0.02), "sun_energy": 0.3, "ambient": 0.25,
	  "sun_color": Color(1.0, 0.6, 0.3) },
	# Golden hour morning
	{ "hour": 7.0,  "sky_top": Color(0.25, 0.35, 0.62), "sky_horizon": Color(0.9, 0.65, 0.3),
	  "ground": Color(0.08, 0.06, 0.03), "sun_energy": 0.65, "ambient": 0.55,
	  "sun_color": Color(1.0, 0.78, 0.45) },
	# Morning
	{ "hour": 9.0,  "sky_top": Color(0.22, 0.38, 0.72), "sky_horizon": Color(0.65, 0.80, 0.92),
	  "ground": Color(0.10, 0.08, 0.04), "sun_energy": 0.9, "ambient": 0.8,
	  "sun_color": Color(1.0, 0.92, 0.75) },
	# Midday
	{ "hour": 12.0, "sky_top": Color(0.18, 0.32, 0.70), "sky_horizon": Color(0.62, 0.78, 0.92),
	  "ground": Color(0.10, 0.08, 0.04), "sun_energy": 1.0, "ambient": 1.0,
	  "sun_color": Color(1.0, 0.97, 0.90) },
	# Afternoon
	{ "hour": 15.0, "sky_top": Color(0.20, 0.34, 0.68), "sky_horizon": Color(0.65, 0.79, 0.91),
	  "ground": Color(0.10, 0.08, 0.04), "sun_energy": 0.88, "ambient": 0.85,
	  "sun_color": Color(1.0, 0.95, 0.80) },
	# Golden hour evening
	{ "hour": 17.5, "sky_top": Color(0.28, 0.22, 0.50), "sky_horizon": Color(0.88, 0.55, 0.25),
	  "ground": Color(0.08, 0.05, 0.02), "sun_energy": 0.55, "ambient": 0.45,
	  "sun_color": Color(1.0, 0.65, 0.2) },
	# Sunset
	{ "hour": 18.5, "sky_top": Color(0.15, 0.10, 0.32), "sky_horizon": Color(0.75, 0.35, 0.15),
	  "ground": Color(0.05, 0.03, 0.01), "sun_energy": 0.25, "ambient": 0.22,
	  "sun_color": Color(1.0, 0.45, 0.1) },
	# Dusk / twilight
	{ "hour": 19.5, "sky_top": Color(0.07, 0.05, 0.18), "sky_horizon": Color(0.25, 0.15, 0.35),
	  "ground": Color(0.02, 0.01, 0.03), "sun_energy": 0.0, "ambient": 0.10,
	  "sun_color": Color(0.8, 0.4, 0.6) },
	# Night
	{ "hour": 21.0, "sky_top": Color(0.02, 0.02, 0.07), "sky_horizon": Color(0.04, 0.04, 0.10),
	  "ground": Color(0.01, 0.01, 0.02), "sun_energy": 0.0, "ambient": 0.05,
	  "sun_color": Color(0.5, 0.55, 1.0) },
	# Late night (wraps back to midnight)
	{ "hour": 24.0, "sky_top": Color(0.01, 0.01, 0.06), "sky_horizon": Color(0.03, 0.03, 0.08),
	  "ground": Color(0.01, 0.01, 0.02), "sun_energy": 0.0, "ambient": 0.04,
	  "sun_color": Color(0.5, 0.6, 1.0) },
]

# ── Scene References ───────────────────────────────────────────────────────────

var sun_light: DirectionalLight3D = null
var moon_light: DirectionalLight3D = null
var world_environment: WorldEnvironment = null
var street_lights: Array = []
var star_mesh_instance: MeshInstance3D = null
var aurora_mesh: MeshInstance3D = null
var sky_material: ProceduralSkyMaterial = null

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	current_hour = start_hour
	previous_integer_hour = int(current_hour)
	_locate_scene_nodes()
	_setup_moon_light()
	_discover_street_lights()
	_apply_time_of_day(current_hour, true)
	if debug_time:
		print("[DayNightCycle] Ready — start hour: %.1f" % current_hour)

func _process(delta: float) -> void:
	_advance_time(delta)
	_apply_time_of_day(current_hour, false)
	_update_star_field(delta)
	_update_aurora(delta)
	_check_hour_events()
	_update_street_lights()

# ── Node Discovery ─────────────────────────────────────────────────────────────

func _locate_scene_nodes() -> void:
	sun_light = get_tree().root.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	if not sun_light:
		sun_light = get_tree().root.find_child("SunLight", true, false) as DirectionalLight3D
	world_environment = get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if world_environment and world_environment.environment:
		var env := world_environment.environment
		if env.sky and env.sky.sky_material is ProceduralSkyMaterial:
			sky_material = env.sky.sky_material as ProceduralSkyMaterial

func _setup_moon_light() -> void:
	if not enable_moon:
		return
	moon_light = DirectionalLight3D.new()
	moon_light.name = "MoonLight"
	moon_light.light_color = Color(0.72, 0.82, 1.0)
	moon_light.light_energy = 0.0
	moon_light.shadow_enabled = false
	add_child(moon_light)

func _discover_street_lights() -> void:
	street_lights.clear()
	var candidates := get_tree().get_nodes_in_group("street_lights")
	for node in candidates:
		street_lights.append(node)
	var by_name := get_tree().root.find_children("StreetLight*", "Node3D", true, false)
	for node in by_name:
		if not street_lights.has(node):
			street_lights.append(node)
	if debug_time:
		print("[DayNightCycle] Discovered %d street lights." % street_lights.size())

# ── Time Advancement ───────────────────────────────────────────────────────────

func _advance_time(delta: float) -> void:
	var real_seconds_per_game_day := day_duration_minutes * 60.0
	var hours_per_second := 24.0 / real_seconds_per_game_day
	current_hour += delta * hours_per_second * time_scale
	if current_hour >= 24.0:
		current_hour -= 24.0
		current_day += 1
		_on_new_day()
	time_of_day_changed.emit(current_hour / 24.0)

func _on_new_day() -> void:
	if debug_time:
		print("[DayNightCycle] New day: %d" % current_day)
	if enable_aurora and randf() < aurora_chance_per_night:
		_start_aurora()

# ── Sun/Moon Rotation ─────────────────────────────────────────────────────────

func _compute_sun_angle_deg(hour: float) -> float:
	# Sun rises at hour 6, sets at hour 18; below horizon otherwise
	var solar_noon := 12.0
	var angle := (hour - solar_noon) / 12.0 * 180.0
	return angle

func _compute_moon_angle_deg(hour: float) -> float:
	# Moon is roughly opposite the sun
	var solar_noon := 12.0
	var angle := (hour - solar_noon) / 12.0 * 180.0 + 180.0
	return angle

func _apply_sun_rotation(hour: float) -> void:
	if not sun_light:
		return
	var angle := _compute_sun_angle_deg(hour)
	var tilt := sun_path_tilt_degrees
	sun_light.rotation_degrees = Vector3(-angle, tilt, 0.0)

func _apply_moon_rotation(hour: float) -> void:
	if not moon_light:
		return
	var angle := _compute_moon_angle_deg(hour)
	sun_light.rotation_degrees if sun_light else Vector3.ZERO
	moon_light.rotation_degrees = Vector3(-angle, -sun_path_tilt_degrees * 0.5, 0.0)

# ── Sky Gradient Interpolation ────────────────────────────────────────────────

func _sample_sky_keyframe(hour: float) -> Dictionary:
	var h := fmod(hour, 24.0)
	var prev_kf: Dictionary = SKY_KEYFRAMES[0]
	var next_kf: Dictionary = SKY_KEYFRAMES[0]

	for i in range(SKY_KEYFRAMES.size()):
		var kf: Dictionary = SKY_KEYFRAMES[i]
		var kf_hour: float = kf["hour"]
		if kf_hour <= h:
			prev_kf = kf
		else:
			next_kf = kf
			break

	var span: float = next_kf["hour"] - prev_kf["hour"]
	var t: float = 0.0
	if span > 0.001:
		t = (h - prev_kf["hour"]) / span
	t = clampf(t, 0.0, 1.0)
	t = _smooth_step(t)

	return {
		"sky_top":     (prev_kf["sky_top"] as Color).lerp(next_kf["sky_top"], t),
		"sky_horizon": (prev_kf["sky_horizon"] as Color).lerp(next_kf["sky_horizon"], t),
		"ground":      (prev_kf["ground"] as Color).lerp(next_kf["ground"], t),
		"sun_energy":  lerpf(prev_kf["sun_energy"], next_kf["sun_energy"], t),
		"ambient":     lerpf(prev_kf["ambient"], next_kf["ambient"], t),
		"sun_color":   (prev_kf["sun_color"] as Color).lerp(next_kf["sun_color"], t),
	}

# ── Apply All Time-of-Day Effects ─────────────────────────────────────────────

func _apply_time_of_day(hour: float, instant: bool) -> void:
	var kf := _sample_sky_keyframe(hour)

	_apply_sun_rotation(hour)
	_apply_moon_rotation(hour)

	if sun_light:
		var energy := kf["sun_energy"] as float
		if sun_intensity_override >= 0.0:
			energy = sun_intensity_override
		if instant:
			sun_light.light_energy = energy
			sun_light.light_color = kf["sun_color"]
		else:
			sun_light.light_energy = lerpf(sun_light.light_energy, energy, 0.05)
			sun_light.light_color  = (sun_light.light_color as Color).lerp(kf["sun_color"], 0.05)
		sun_light.shadow_enabled = kf["sun_energy"] > 0.15

	if moon_light and enable_moon:
		var moon_energy := _compute_moon_energy(hour)
		if moon_intensity_override >= 0.0:
			moon_energy = moon_intensity_override
		moon_light.light_energy = moon_energy
		moon_light.shadow_enabled = moon_energy > 0.1

	if sky_material:
		if instant:
			sky_material.sky_top_color       = kf["sky_top"]
			sky_material.sky_horizon_color    = kf["sky_horizon"]
			sky_material.ground_bottom_color  = kf["ground"]
			sky_material.sky_energy_multiplier    = kf["sun_energy"] + kf["ambient"]
			sky_material.ground_energy_multiplier = kf["ambient"] * 0.5
		else:
			sky_material.sky_top_color = (sky_material.sky_top_color as Color).lerp(kf["sky_top"], 0.03)
			sky_material.sky_horizon_color = (sky_material.sky_horizon_color as Color).lerp(kf["sky_horizon"], 0.03)
			sky_material.ground_bottom_color = (sky_material.ground_bottom_color as Color).lerp(kf["ground"], 0.03)
			var target_energy := kf["sun_energy"] + kf["ambient"]
			sky_material.sky_energy_multiplier = lerpf(sky_material.sky_energy_multiplier, target_energy, 0.03)

	if world_environment and world_environment.environment:
		var env := world_environment.environment
		var target_ambient := kf["ambient"] as float
		env.ambient_light_energy = lerpf(env.ambient_light_energy, target_ambient, 0.04 if not instant else 1.0)

func _compute_moon_energy(hour: float) -> float:
	var moon_angle := _compute_moon_angle_deg(hour)
	var moon_above := sinf(deg_to_rad(moon_angle))
	var phase_factor := float(moon_phase) / 7.0 * 0.18 + 0.02
	return clampf(moon_above * phase_factor, 0.0, 0.2)

# ── Hour Events ───────────────────────────────────────────────────────────────

func _check_hour_events() -> void:
	var int_hour := int(current_hour)
	if int_hour == previous_integer_hour:
		return
	previous_integer_hour = int_hour
	hour_changed.emit(int_hour)

	match int_hour:
		0:
			midnight.emit()
		6:
			sunrise.emit()
			dawn_started.emit()
		12:
			noon.emit()
		18:
			sunset.emit()
		19:
			dusk_started.emit()

# ── Street Light Automation ────────────────────────────────────────────────────

func _update_street_lights() -> void:
	if not enable_street_lights:
		return
	var should_be_on := _street_lights_should_be_on(current_hour)
	if should_be_on == street_lights_enabled:
		return
	street_lights_enabled = should_be_on
	_set_all_street_lights(should_be_on)
	if should_be_on:
		street_lights_on.emit()
		if debug_time:
			print("[DayNightCycle] Street lights ON at %.2f" % current_hour)
	else:
		street_lights_off.emit()
		if debug_time:
			print("[DayNightCycle] Street lights OFF at %.2f" % current_hour)

func _street_lights_should_be_on(hour: float) -> bool:
	if street_light_on_hour > street_light_off_hour:
		return hour >= street_light_on_hour or hour < street_light_off_hour
	else:
		return hour >= street_light_on_hour and hour < street_light_off_hour

func _set_all_street_lights(on: bool) -> void:
	for light_node in street_lights:
		if not is_instance_valid(light_node):
			continue
		if light_node.has_method("set_enabled"):
			light_node.set_enabled(on)
			continue
		var light := light_node.find_child("OmniLight3D", true, false) as OmniLight3D
		if not light:
			light = light_node.find_child("SpotLight3D", true, false) as OmniLight3D
		if light:
			light.visible = on

func refresh_street_lights() -> void:
	_discover_street_lights()

# ── Star Field ────────────────────────────────────────────────────────────────

func _update_star_field(delta: float) -> void:
	if not enable_stars or not sky_material:
		return
	star_twinkle_offset += delta * 0.5
	var night_factor := _get_night_factor(current_hour)
	if sky_material is ProceduralSkyMaterial:
		var psm := sky_material as ProceduralSkyMaterial
		var star_brightness := night_factor * (0.9 + sin(star_twinkle_offset * 2.3) * 0.05)
		psm.sky_energy_multiplier = lerpf(psm.sky_energy_multiplier,
			_compute_sky_energy(current_hour) + star_brightness * 0.12, 0.02)

func _get_night_factor(hour: float) -> float:
	if hour >= 21.0 or hour < 5.0:
		return 1.0
	if hour >= 5.0 and hour < 7.0:
		return 1.0 - (hour - 5.0) / 2.0
	if hour >= 19.0 and hour < 21.0:
		return (hour - 19.0) / 2.0
	return 0.0

func _compute_sky_energy(hour: float) -> float:
	var kf := _sample_sky_keyframe(hour)
	return kf["sun_energy"] + kf["ambient"]

# ── Aurora Borealis ────────────────────────────────────────────────────────────

func _start_aurora() -> void:
	aurora_active = true
	aurora_duration_remaining = randf_range(180.0, 600.0)
	aurora_intensity = 0.0
	if debug_time:
		print("[DayNightCycle] Aurora borealis starting! Duration: %.0fs" % aurora_duration_remaining)

func _update_aurora(delta: float) -> void:
	if not aurora_active:
		return
	aurora_duration_remaining -= delta
	var fade_time := 30.0
	if aurora_duration_remaining > fade_time:
		aurora_intensity = minf(aurora_intensity + delta * 0.015, 1.0)
	else:
		aurora_intensity = maxf(aurora_intensity - delta * 0.02, 0.0)
	if aurora_duration_remaining <= 0.0:
		aurora_active = false
		aurora_intensity = 0.0

func get_aurora_intensity() -> float:
	var night_factor := _get_night_factor(current_hour)
	return aurora_intensity * night_factor

func trigger_aurora_now(duration_seconds: float = 300.0) -> void:
	aurora_active = true
	aurora_duration_remaining = duration_seconds
	aurora_intensity = 0.0

# ── Utility / Queries ──────────────────────────────────────────────────────────

func _smooth_step(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

func get_hour() -> float:
	return current_hour

func get_hour_string() -> String:
	var h := int(current_hour)
	var m := int(fmod(current_hour, 1.0) * 60.0)
	var suffix := "AM" if h < 12 else "PM"
	var display_h := h % 12
	if display_h == 0:
		display_h = 12
	return "%02d:%02d %s" % [display_h, m, suffix]

func get_time_24() -> String:
	var h := int(current_hour)
	var m := int(fmod(current_hour, 1.0) * 60.0)
	return "%02d:%02d" % [h, m]

func is_daytime() -> bool:
	return current_hour >= 6.0 and current_hour < 19.0

func is_nighttime() -> bool:
	return not is_daytime()

func is_golden_hour() -> bool:
	return (current_hour >= 6.0 and current_hour <= 8.0) or \
		   (current_hour >= 16.5 and current_hour <= 18.5)

func is_sunrise() -> bool:
	return current_hour >= 5.5 and current_hour < 7.5

func is_sunset() -> bool:
	return current_hour >= 17.5 and current_hour < 19.5

func get_day_progress() -> float:
	return current_hour / 24.0

func get_sun_direction() -> Vector3:
	if sun_light:
		return -sun_light.global_transform.basis.z
	return Vector3.DOWN

func get_moon_direction() -> Vector3:
	if moon_light:
		return -moon_light.global_transform.basis.z
	return Vector3.UP

func set_time(hour: float, instant: bool = false) -> void:
	current_hour = clampf(fmod(hour, 24.0), 0.0, 23.999)
	if instant:
		_apply_time_of_day(current_hour, true)

func serialize() -> Dictionary:
	return {
		"current_hour": current_hour,
		"current_day": current_day,
		"time_scale": time_scale,
		"moon_phase": moon_phase,
		"aurora_active": aurora_active,
		"aurora_duration_remaining": aurora_duration_remaining,
		"street_lights_enabled": street_lights_enabled,
	}

func deserialize(data: Dictionary) -> void:
	if data.has("current_hour"):
		set_time(data["current_hour"], true)
	if data.has("current_day"):
		current_day = data["current_day"]
	if data.has("time_scale"):
		time_scale = data["time_scale"]
	if data.has("moon_phase"):
		moon_phase = data["moon_phase"]
	if data.has("aurora_active") and data["aurora_active"]:
		aurora_active = true
		aurora_duration_remaining = data.get("aurora_duration_remaining", 120.0)

## Returns a status string for HUD.
func get_status_string() -> String:
	var time_str := get_hour_string()
	var period := "Day" if is_daytime() else "Night"
	if is_golden_hour():
		period = "Golden Hour"
	elif is_sunrise():
		period = "Sunrise"
	elif is_sunset():
		period = "Sunset"
	var aurora_str := " 🌌 Aurora!" if aurora_active and aurora_intensity > 0.3 else ""
	return "🕐 %s  (%s)%s" % [time_str, period, aurora_str]

## Returns the moon phase name.
func get_moon_phase_name() -> String:
	match moon_phase:
		0: return "New Moon 🌑"
		1: return "Waxing Crescent 🌒"
		2: return "First Quarter 🌓"
		3: return "Waxing Gibbous 🌔"
		4: return "Full Moon 🌕"
		5: return "Waning Gibbous 🌖"
		6: return "Last Quarter 🌗"
		7: return "Waning Crescent 🌘"
	return "Unknown"

## Advance moon phase each day.
func advance_moon_phase() -> void:
	moon_phase = (moon_phase + 1) % 8

## Speed multiplier for time progression.
func set_time_scale(scale: float) -> void:
	time_scale = clampf(scale, 0.0, 100.0)

## Add a street light node dynamically (e.g. procedurally placed).
func register_street_light(light_node: Node) -> void:
	if not street_lights.has(light_node):
		street_lights.append(light_node)
		if street_lights_enabled:
			if light_node.has_method("set_enabled"):
				light_node.set_enabled(true)
