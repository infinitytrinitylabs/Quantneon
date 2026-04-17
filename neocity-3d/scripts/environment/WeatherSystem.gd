## WeatherSystem — Dynamic real-time weather for the Neo City metaverse
## Manages 8 weather states with smooth transitions, particle effects,
## volumetric fog, thunder, and gameplay-affecting properties.
extends Node

# ── Signals ───────────────────────────────────────────────────────────────────

signal weather_changed(old_state: int, new_state: int)
signal thunder_strike(intensity: float)
signal weather_alert(message: String, severity: int)
signal weather_transition_started(from_state: int, to_state: int)
signal weather_transition_finished(new_state: int)

# ── Enums ──────────────────────────────────────────────────────────────────────

enum WeatherState {
	CLEAR       = 0,
	CLOUDY      = 1,
	RAIN        = 2,
	HEAVY_RAIN  = 3,
	THUNDERSTORM = 4,
	SNOW        = 5,
	FOG         = 6,
	SANDSTORM   = 7,
}

enum AlertSeverity {
	INFO    = 0,
	WARNING = 1,
	DANGER  = 2,
}

# ── Export Parameters ──────────────────────────────────────────────────────────

@export var start_weather: WeatherState = WeatherState.CLEAR
@export var transition_duration: float = 30.0
@export var min_weather_duration_minutes: float = 15.0
@export var max_weather_duration_minutes: float = 45.0
@export var enable_thunder: bool = true
@export var enable_lightning_flash: bool = true
@export var rain_particle_count: int = 2000
@export var snow_particle_count: int = 1500
@export var sandstorm_particle_count: int = 3000
@export var debug_weather: bool = false

# ── Internal State ─────────────────────────────────────────────────────────────

var current_state: WeatherState = WeatherState.CLEAR
var previous_state: WeatherState = WeatherState.CLEAR
var target_state: WeatherState = WeatherState.CLEAR
var transition_progress: float = 1.0   # 0 = start, 1 = fully in target state
var is_transitioning: bool = false

var time_until_next_change: float = 0.0
var thunder_timer: float = 0.0
var thunder_next_strike: float = 0.0
var lightning_flash_timer: float = 0.0
var lightning_flash_active: bool = false
var rain_ripple_timer: float = 0.0
var wind_strength: float = 0.0
var wind_direction: Vector2 = Vector2.ZERO
var temperature: float = 20.0  # Celsius
var humidity: float = 0.5

# ── Scene References ───────────────────────────────────────────────────────────

var world_environment: WorldEnvironment = null
var directional_light: DirectionalLight3D = null
var rain_particles: GPUParticles3D = null
var snow_particles: GPUParticles3D = null
var sandstorm_particles: GPUParticles3D = null
var fog_particles: GPUParticles3D = null
var splash_particles: GPUParticles3D = null
var thunder_audio: AudioStreamPlayer = null
var rain_audio: AudioStreamPlayer = null
var wind_audio: AudioStreamPlayer = null
var blizzard_audio: AudioStreamPlayer = null
var camera: Camera3D = null

# ── Weather Property Tables ────────────────────────────────────────────────────

# Each entry: { fog_density, fog_height, ambient_energy, sky_energy, wind, temp, humidity, visibility }
const WEATHER_PROPERTIES: Dictionary = {
	WeatherState.CLEAR: {
		"fog_density": 0.001,
		"fog_height": 0.0,
		"ambient_energy": 1.0,
		"sky_energy": 1.0,
		"wind": 0.05,
		"temperature": 22.0,
		"humidity": 0.3,
		"visibility": 1.0,
		"cloud_cover": 0.0,
		"move_penalty": 0.0,
		"sky_top_color": Color(0.18, 0.27, 0.55),
		"sky_horizon_color": Color(0.62, 0.77, 0.88),
		"ground_color": Color(0.1, 0.07, 0.03),
	},
	WeatherState.CLOUDY: {
		"fog_density": 0.004,
		"fog_height": 0.5,
		"ambient_energy": 0.75,
		"sky_energy": 0.7,
		"wind": 0.15,
		"temperature": 18.0,
		"humidity": 0.55,
		"visibility": 0.85,
		"cloud_cover": 0.65,
		"move_penalty": 0.0,
		"sky_top_color": Color(0.35, 0.37, 0.42),
		"sky_horizon_color": Color(0.6, 0.62, 0.65),
		"ground_color": Color(0.08, 0.07, 0.05),
	},
	WeatherState.RAIN: {
		"fog_density": 0.012,
		"fog_height": 1.0,
		"ambient_energy": 0.55,
		"sky_energy": 0.5,
		"wind": 0.25,
		"temperature": 14.0,
		"humidity": 0.85,
		"visibility": 0.65,
		"cloud_cover": 0.85,
		"move_penalty": 0.05,
		"sky_top_color": Color(0.2, 0.22, 0.27),
		"sky_horizon_color": Color(0.45, 0.47, 0.52),
		"ground_color": Color(0.04, 0.04, 0.04),
	},
	WeatherState.HEAVY_RAIN: {
		"fog_density": 0.022,
		"fog_height": 2.0,
		"ambient_energy": 0.35,
		"sky_energy": 0.3,
		"wind": 0.45,
		"temperature": 11.0,
		"humidity": 0.95,
		"visibility": 0.4,
		"cloud_cover": 0.97,
		"move_penalty": 0.12,
		"sky_top_color": Color(0.12, 0.13, 0.16),
		"sky_horizon_color": Color(0.3, 0.32, 0.36),
		"ground_color": Color(0.03, 0.03, 0.04),
	},
	WeatherState.THUNDERSTORM: {
		"fog_density": 0.028,
		"fog_height": 3.0,
		"ambient_energy": 0.25,
		"sky_energy": 0.2,
		"wind": 0.75,
		"temperature": 9.0,
		"humidity": 0.98,
		"visibility": 0.3,
		"cloud_cover": 1.0,
		"move_penalty": 0.2,
		"sky_top_color": Color(0.07, 0.07, 0.1),
		"sky_horizon_color": Color(0.18, 0.19, 0.23),
		"ground_color": Color(0.02, 0.02, 0.03),
	},
	WeatherState.SNOW: {
		"fog_density": 0.018,
		"fog_height": 1.5,
		"ambient_energy": 0.65,
		"sky_energy": 0.6,
		"wind": 0.2,
		"temperature": -4.0,
		"humidity": 0.7,
		"visibility": 0.55,
		"cloud_cover": 0.9,
		"move_penalty": 0.25,
		"sky_top_color": Color(0.55, 0.6, 0.68),
		"sky_horizon_color": Color(0.78, 0.82, 0.88),
		"ground_color": Color(0.55, 0.56, 0.58),
	},
	WeatherState.FOG: {
		"fog_density": 0.045,
		"fog_height": 4.0,
		"ambient_energy": 0.45,
		"sky_energy": 0.4,
		"wind": 0.05,
		"temperature": 10.0,
		"humidity": 0.92,
		"visibility": 0.2,
		"cloud_cover": 0.5,
		"move_penalty": 0.0,
		"sky_top_color": Color(0.6, 0.62, 0.64),
		"sky_horizon_color": Color(0.82, 0.84, 0.86),
		"ground_color": Color(0.1, 0.1, 0.1),
	},
	WeatherState.SANDSTORM: {
		"fog_density": 0.055,
		"fog_height": 6.0,
		"ambient_energy": 0.3,
		"sky_energy": 0.25,
		"wind": 0.9,
		"temperature": 35.0,
		"humidity": 0.1,
		"visibility": 0.15,
		"cloud_cover": 0.4,
		"move_penalty": 0.3,
		"sky_top_color": Color(0.45, 0.28, 0.08),
		"sky_horizon_color": Color(0.7, 0.5, 0.2),
		"ground_color": Color(0.35, 0.22, 0.05),
	},
}

# ── Transition Weight Table (probability of transitioning between states) ──────
# Higher = more likely to transition to that weather next
const TRANSITION_WEIGHTS: Dictionary = {
	WeatherState.CLEAR:       { WeatherState.CLEAR: 0.4, WeatherState.CLOUDY: 0.4, WeatherState.FOG: 0.1, WeatherState.SANDSTORM: 0.1 },
	WeatherState.CLOUDY:      { WeatherState.CLEAR: 0.25, WeatherState.CLOUDY: 0.2, WeatherState.RAIN: 0.3, WeatherState.FOG: 0.15, WeatherState.SNOW: 0.1 },
	WeatherState.RAIN:        { WeatherState.CLOUDY: 0.3, WeatherState.RAIN: 0.2, WeatherState.HEAVY_RAIN: 0.3, WeatherState.THUNDERSTORM: 0.2 },
	WeatherState.HEAVY_RAIN:  { WeatherState.RAIN: 0.35, WeatherState.HEAVY_RAIN: 0.15, WeatherState.THUNDERSTORM: 0.35, WeatherState.CLOUDY: 0.15 },
	WeatherState.THUNDERSTORM:{ WeatherState.HEAVY_RAIN: 0.4, WeatherState.RAIN: 0.35, WeatherState.CLOUDY: 0.25 },
	WeatherState.SNOW:        { WeatherState.CLOUDY: 0.3, WeatherState.SNOW: 0.4, WeatherState.FOG: 0.2, WeatherState.CLEAR: 0.1 },
	WeatherState.FOG:         { WeatherState.CLEAR: 0.3, WeatherState.CLOUDY: 0.35, WeatherState.FOG: 0.2, WeatherState.RAIN: 0.15 },
	WeatherState.SANDSTORM:   { WeatherState.CLEAR: 0.4, WeatherState.CLOUDY: 0.3, WeatherState.SANDSTORM: 0.2, WeatherState.FOG: 0.1 },
}

# ── Weather State Names (for UI and alerts) ────────────────────────────────────

const WEATHER_NAMES: Dictionary = {
	WeatherState.CLEAR:       "Clear",
	WeatherState.CLOUDY:      "Cloudy",
	WeatherState.RAIN:        "Rain",
	WeatherState.HEAVY_RAIN:  "Heavy Rain",
	WeatherState.THUNDERSTORM:"Thunderstorm",
	WeatherState.SNOW:        "Snow",
	WeatherState.FOG:         "Dense Fog",
	WeatherState.SANDSTORM:   "Sandstorm",
}

const WEATHER_ICONS: Dictionary = {
	WeatherState.CLEAR:       "☀",
	WeatherState.CLOUDY:      "⛅",
	WeatherState.RAIN:        "🌧",
	WeatherState.HEAVY_RAIN:  "🌧🌧",
	WeatherState.THUNDERSTORM:"⛈",
	WeatherState.SNOW:        "🌨",
	WeatherState.FOG:         "🌫",
	WeatherState.SANDSTORM:   "🌪",
}

# ── Blended properties (interpolated during transitions) ─────────────────────

var _blended_fog_density: float = 0.001
var _blended_fog_height: float = 0.0
var _blended_ambient_energy: float = 1.0
var _blended_sky_energy: float = 1.0
var _blended_wind: float = 0.05
var _blended_sky_top: Color = Color(0.18, 0.27, 0.55)
var _blended_sky_horizon: Color = Color(0.62, 0.77, 0.88)
var _blended_ground: Color = Color(0.1, 0.07, 0.03)
var _blended_visibility: float = 1.0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_locate_scene_nodes()
	_create_particle_systems()
	_create_audio_players()
	_schedule_next_weather_change()
	set_weather(start_weather, true)
	if debug_weather:
		print("[WeatherSystem] Initialized. Starting weather: ", WEATHER_NAMES[current_state])

func _process(delta: float) -> void:
	_update_transition(delta)
	_update_wind(delta)
	_update_thunder(delta)
	_update_lightning_flash(delta)
	_update_rain_ripples(delta)
	_apply_blended_properties()
	_update_weather_timer(delta)

# ── Node Discovery ─────────────────────────────────────────────────────────────

func _locate_scene_nodes() -> void:
	world_environment = get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	directional_light = get_tree().root.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	camera = get_tree().root.find_child("Camera3D", true, false) as Camera3D
	if not camera:
		camera = get_viewport().get_camera_3d()

# ── Particle System Creation ───────────────────────────────────────────────────

func _create_particle_systems() -> void:
	rain_particles = _make_particle_node("RainParticles", rain_particle_count)
	rain_particles.emitting = false
	add_child(rain_particles)

	snow_particles = _make_particle_node("SnowParticles", snow_particle_count)
	snow_particles.emitting = false
	add_child(snow_particles)

	sandstorm_particles = _make_particle_node("SandstormParticles", sandstorm_particle_count)
	sandstorm_particles.emitting = false
	add_child(sandstorm_particles)

	fog_particles = _make_particle_node("FogParticles", 800)
	fog_particles.emitting = false
	add_child(fog_particles)

	splash_particles = _make_particle_node("SplashParticles", 500)
	splash_particles.emitting = false
	add_child(splash_particles)

func _make_particle_node(node_name: String, count: int) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = node_name
	p.amount = count
	p.one_shot = false
	p.lifetime = 2.5
	p.visibility_aabb = AABB(Vector3(-60, -80, -60), Vector3(120, 160, 120))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(50, 1, 50)
	pm.gravity = Vector3(0, -9.8, 0)
	pm.initial_velocity_min = 4.0
	pm.initial_velocity_max = 8.0
	pm.spread = 5.0
	p.process_material = pm
	return p

# ── Audio Players ─────────────────────────────────────────────────────────────

func _create_audio_players() -> void:
	thunder_audio = AudioStreamPlayer.new()
	thunder_audio.name = "ThunderAudio"
	thunder_audio.bus = "SFX"
	thunder_audio.volume_db = 0.0
	add_child(thunder_audio)

	rain_audio = AudioStreamPlayer.new()
	rain_audio.name = "RainAudio"
	rain_audio.bus = "Ambient"
	rain_audio.volume_db = -8.0
	add_child(rain_audio)

	wind_audio = AudioStreamPlayer.new()
	wind_audio.name = "WindAudio"
	wind_audio.bus = "Ambient"
	wind_audio.volume_db = -12.0
	add_child(wind_audio)

	blizzard_audio = AudioStreamPlayer.new()
	blizzard_audio.name = "BlizzardAudio"
	blizzard_audio.bus = "Ambient"
	blizzard_audio.volume_db = -10.0
	add_child(blizzard_audio)

# ── Weather Control ────────────────────────────────────────────────────────────

func set_weather(new_state: WeatherState, instant: bool = false) -> void:
	if new_state == current_state and not instant:
		return

	var old_state := current_state
	previous_state = old_state
	target_state = new_state

	if instant:
		current_state = new_state
		transition_progress = 1.0
		is_transitioning = false
		_snap_to_weather(new_state)
		_update_particles(new_state, 1.0)
		_send_alert_if_severe(new_state)
		weather_changed.emit(old_state, new_state)
		weather_transition_finished.emit(new_state)
	else:
		is_transitioning = true
		transition_progress = 0.0
		weather_transition_started.emit(old_state, new_state)
		_send_alert_if_severe(new_state)
		if debug_weather:
			print("[WeatherSystem] Transitioning from ", WEATHER_NAMES[old_state],
				  " → ", WEATHER_NAMES[new_state])

func get_weather_name() -> String:
	return WEATHER_NAMES.get(current_state, "Unknown")

func get_weather_icon() -> String:
	return WEATHER_ICONS.get(current_state, "?")

func get_movement_penalty() -> float:
	var props: Dictionary = WEATHER_PROPERTIES[current_state]
	return props.get("move_penalty", 0.0)

func get_visibility() -> float:
	return _blended_visibility

func get_wind_strength() -> float:
	return _blended_wind

func get_temperature() -> float:
	return temperature

func get_humidity() -> float:
	return humidity

func is_precipitation_active() -> bool:
	return current_state in [WeatherState.RAIN, WeatherState.HEAVY_RAIN,
		WeatherState.THUNDERSTORM, WeatherState.SNOW]

func is_severe_weather() -> bool:
	return current_state in [WeatherState.THUNDERSTORM, WeatherState.SANDSTORM,
		WeatherState.HEAVY_RAIN]

# ── Transition Logic ───────────────────────────────────────────────────────────

func _update_transition(delta: float) -> void:
	if not is_transitioning:
		return

	transition_progress += delta / transition_duration
	transition_progress = clampf(transition_progress, 0.0, 1.0)

	var t := _smooth_step(transition_progress)
	var prev_props: Dictionary = WEATHER_PROPERTIES[previous_state]
	var next_props: Dictionary = WEATHER_PROPERTIES[target_state]

	_blended_fog_density  = lerpf(prev_props["fog_density"],  next_props["fog_density"],  t)
	_blended_fog_height   = lerpf(prev_props["fog_height"],   next_props["fog_height"],   t)
	_blended_ambient_energy = lerpf(prev_props["ambient_energy"], next_props["ambient_energy"], t)
	_blended_sky_energy   = lerpf(prev_props["sky_energy"],   next_props["sky_energy"],   t)
	_blended_wind         = lerpf(prev_props["wind"],         next_props["wind"],         t)
	_blended_visibility   = lerpf(prev_props["visibility"],   next_props["visibility"],   t)
	_blended_sky_top      = prev_props["sky_top_color"].lerp(next_props["sky_top_color"], t)
	_blended_sky_horizon  = prev_props["sky_horizon_color"].lerp(next_props["sky_horizon_color"], t)
	_blended_ground       = prev_props["ground_color"].lerp(next_props["ground_color"], t)
	temperature           = lerpf(prev_props["temperature"], next_props["temperature"], t)
	humidity              = lerpf(prev_props["humidity"],    next_props["humidity"],    t)

	_update_particles(target_state, t)

	if transition_progress >= 1.0:
		current_state = target_state
		is_transitioning = false
		_snap_to_weather(current_state)
		weather_changed.emit(previous_state, current_state)
		weather_transition_finished.emit(current_state)
		if debug_weather:
			print("[WeatherSystem] Transition complete → ", WEATHER_NAMES[current_state])

func _snap_to_weather(state: WeatherState) -> void:
	var props: Dictionary = WEATHER_PROPERTIES[state]
	_blended_fog_density   = props["fog_density"]
	_blended_fog_height    = props["fog_height"]
	_blended_ambient_energy = props["ambient_energy"]
	_blended_sky_energy    = props["sky_energy"]
	_blended_wind          = props["wind"]
	_blended_visibility    = props["visibility"]
	_blended_sky_top       = props["sky_top_color"]
	_blended_sky_horizon   = props["sky_horizon_color"]
	_blended_ground        = props["ground_color"]
	temperature            = props["temperature"]
	humidity               = props["humidity"]

# ── Scene Property Application ─────────────────────────────────────────────────

func _apply_blended_properties() -> void:
	_apply_fog()
	_apply_sky_colors()

func _apply_fog() -> void:
	if not world_environment:
		return
	var env := world_environment.environment
	if not env:
		return
	env.fog_enabled = _blended_fog_density > 0.002
	env.fog_density = _blended_fog_density
	env.fog_height = -_blended_fog_height * 5.0
	env.fog_height_density = _blended_fog_height * 0.5

func _apply_sky_colors() -> void:
	if not world_environment:
		return
	var env := world_environment.environment
	if not env or env.sky == null:
		return
	var sky_mat := env.sky.sky_material
	if sky_mat is ProceduralSkyMaterial:
		var psm := sky_mat as ProceduralSkyMaterial
		psm.sky_top_color      = _blended_sky_top
		psm.sky_horizon_color  = _blended_sky_horizon
		psm.ground_bottom_color = _blended_ground
		psm.sky_energy_multiplier  = _blended_sky_energy
		psm.ground_energy_multiplier = _blended_sky_energy * 0.4

# ── Particle Updates ───────────────────────────────────────────────────────────

func _update_particles(state: WeatherState, blend: float) -> void:
	match state:
		WeatherState.RAIN:
			_set_rain_particles(true, blend, false)
			_set_snow_particles(false, 0.0)
			_set_sandstorm_particles(false, 0.0)
		WeatherState.HEAVY_RAIN:
			_set_rain_particles(true, blend, true)
			_set_snow_particles(false, 0.0)
			_set_sandstorm_particles(false, 0.0)
		WeatherState.THUNDERSTORM:
			_set_rain_particles(true, blend, true)
			_set_snow_particles(false, 0.0)
			_set_sandstorm_particles(false, 0.0)
		WeatherState.SNOW:
			_set_rain_particles(false, 0.0, false)
			_set_snow_particles(true, blend)
			_set_sandstorm_particles(false, 0.0)
		WeatherState.SANDSTORM:
			_set_rain_particles(false, 0.0, false)
			_set_snow_particles(false, 0.0)
			_set_sandstorm_particles(true, blend)
		_:
			_set_rain_particles(false, 0.0, false)
			_set_snow_particles(false, 0.0)
			_set_sandstorm_particles(false, 0.0)

func _set_rain_particles(active: bool, intensity: float, heavy: bool) -> void:
	if not rain_particles:
		return
	rain_particles.emitting = active
	splash_particles.emitting = active
	if active and rain_particles.process_material is ParticleProcessMaterial:
		var pm := rain_particles.process_material as ParticleProcessMaterial
		pm.initial_velocity_min = lerp(8.0, 18.0, intensity)
		pm.initial_velocity_max = lerp(12.0, 25.0, intensity)
		var amount := int(lerp(500.0, float(rain_particle_count), intensity))
		if heavy:
			amount = int(float(amount) * 1.5)
		rain_particles.amount = clampi(amount, 100, rain_particle_count * 2)
		pm.gravity = Vector3(wind_direction.x * _blended_wind * 3.0, -9.8,
							  wind_direction.y * _blended_wind * 3.0)

func _set_snow_particles(active: bool, intensity: float) -> void:
	if not snow_particles:
		return
	snow_particles.emitting = active
	if active and snow_particles.process_material is ParticleProcessMaterial:
		var pm := snow_particles.process_material as ParticleProcessMaterial
		pm.initial_velocity_min = lerp(0.5, 3.0, intensity)
		pm.initial_velocity_max = lerp(1.5, 5.0, intensity)
		pm.gravity = Vector3(wind_direction.x * _blended_wind * 1.5, -2.5,
							  wind_direction.y * _blended_wind * 1.5)
		snow_particles.amount = int(lerp(200.0, float(snow_particle_count), intensity))

func _set_sandstorm_particles(active: bool, intensity: float) -> void:
	if not sandstorm_particles:
		return
	sandstorm_particles.emitting = active
	if active and sandstorm_particles.process_material is ParticleProcessMaterial:
		var pm := sandstorm_particles.process_material as ParticleProcessMaterial
		pm.initial_velocity_min = lerp(5.0, 25.0, intensity)
		pm.initial_velocity_max = lerp(10.0, 40.0, intensity)
		pm.gravity = Vector3(wind_direction.x * _blended_wind * 8.0, 0.0,
							  wind_direction.y * _blended_wind * 8.0)
		sandstorm_particles.amount = int(lerp(500.0, float(sandstorm_particle_count), intensity))

# ── Particle Positioning (follow camera/player) ────────────────────────────────

func _position_particles_on_camera() -> void:
	if not camera:
		return
	var cam_pos := camera.global_position
	var overhead := cam_pos + Vector3(0, 25, 0)
	if rain_particles and rain_particles.emitting:
		rain_particles.global_position = overhead
	if snow_particles and snow_particles.emitting:
		snow_particles.global_position = overhead
	if sandstorm_particles and sandstorm_particles.emitting:
		sandstorm_particles.global_position = cam_pos + Vector3(0, 3, 0)
	if splash_particles and splash_particles.emitting:
		splash_particles.global_position = cam_pos + Vector3(0, 0.1, 0)

# ── Wind Simulation ────────────────────────────────────────────────────────────

func _update_wind(delta: float) -> void:
	var wind_target := WEATHER_PROPERTIES[current_state].get("wind", 0.0) as float
	_blended_wind = lerpf(_blended_wind, wind_target, delta * 0.5)
	wind_direction += Vector2(
		sin(Time.get_ticks_msec() * 0.0003) * delta,
		cos(Time.get_ticks_msec() * 0.0002) * delta
	)
	wind_direction = wind_direction.normalized() if wind_direction.length() > 0.001 else wind_direction
	_position_particles_on_camera()

# ── Thunder & Lightning ────────────────────────────────────────────────────────

func _update_thunder(delta: float) -> void:
	if current_state != WeatherState.THUNDERSTORM or not enable_thunder:
		return
	thunder_timer += delta
	if thunder_timer >= thunder_next_strike:
		thunder_timer = 0.0
		thunder_next_strike = randf_range(4.0, 18.0)
		var intensity := randf_range(0.4, 1.0)
		_trigger_thunder(intensity)

func _trigger_thunder(intensity: float) -> void:
	thunder_strike.emit(intensity)
	if enable_lightning_flash:
		lightning_flash_active = true
		lightning_flash_timer = 0.0
	if directional_light:
		var original_energy := directional_light.light_energy
		directional_light.light_energy = original_energy + intensity * 3.0
		var tween := create_tween()
		tween.tween_property(directional_light, "light_energy", original_energy, 0.35)
	if debug_weather:
		print("[WeatherSystem] Thunder strike! Intensity: %.2f" % intensity)

func _update_lightning_flash(delta: float) -> void:
	if not lightning_flash_active:
		return
	lightning_flash_timer += delta
	var flash_duration := 0.2
	if lightning_flash_timer >= flash_duration:
		lightning_flash_active = false

func get_lightning_flash_intensity() -> float:
	if not lightning_flash_active:
		return 0.0
	var t := lightning_flash_timer / 0.2
	return 1.0 - t

# ── Rain Ripple Updates ────────────────────────────────────────────────────────

func _update_rain_ripples(delta: float) -> void:
	if not is_precipitation_active():
		return
	rain_ripple_timer += delta

# ── Weather Timer ─────────────────────────────────────────────────────────────

func _update_weather_timer(delta: float) -> void:
	if is_transitioning:
		return
	time_until_next_change -= delta
	if time_until_next_change <= 0.0:
		_schedule_next_weather_change()
		var next := _pick_next_weather()
		set_weather(next)

func _schedule_next_weather_change() -> void:
	time_until_next_change = randf_range(
		min_weather_duration_minutes * 60.0,
		max_weather_duration_minutes * 60.0
	)
	if debug_weather:
		print("[WeatherSystem] Next change in %.1f min" % (time_until_next_change / 60.0))

func _pick_next_weather() -> WeatherState:
	var weights: Dictionary = TRANSITION_WEIGHTS.get(current_state, {})
	var total_weight := 0.0
	for w in weights.values():
		total_weight += w
	var roll := randf() * total_weight
	var cumulative := 0.0
	for state in weights.keys():
		cumulative += weights[state]
		if roll <= cumulative:
			return state as WeatherState
	return WeatherState.CLEAR

# ── Alert Dispatch ────────────────────────────────────────────────────────────

func _send_alert_if_severe(state: WeatherState) -> void:
	match state:
		WeatherState.THUNDERSTORM:
			weather_alert.emit("⚡ THUNDERSTORM WARNING — Seek shelter immediately!", AlertSeverity.DANGER)
		WeatherState.SANDSTORM:
			weather_alert.emit("🌪 SANDSTORM ALERT — Visibility severely reduced!", AlertSeverity.DANGER)
		WeatherState.HEAVY_RAIN:
			weather_alert.emit("🌧 HEAVY RAIN — Movement slowed. Wet surfaces.", AlertSeverity.WARNING)
		WeatherState.FOG:
			weather_alert.emit("🌫 DENSE FOG — Visibility critically low.", AlertSeverity.WARNING)
		WeatherState.SNOW:
			weather_alert.emit("❄ SNOWFALL — Slippery surfaces detected.", AlertSeverity.INFO)

# ── Utility ───────────────────────────────────────────────────────────────────

func _smooth_step(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)

func force_weather(state_name: String) -> void:
	for key in WEATHER_NAMES:
		if WEATHER_NAMES[key].to_lower() == state_name.to_lower():
			set_weather(key as WeatherState)
			return
	push_warning("[WeatherSystem] Unknown weather state: " + state_name)

func get_forecast(days: int = 3) -> Array:
	var forecast := []
	var last_state := current_state
	for i in range(days * 4):
		var weights: Dictionary = TRANSITION_WEIGHTS.get(last_state, {})
		var best_state := last_state
		var best_w := 0.0
		for s in weights.keys():
			if weights[s] > best_w:
				best_w = weights[s]
				best_state = s
		forecast.append({
			"state": best_state,
			"name": WEATHER_NAMES[best_state],
			"icon": WEATHER_ICONS[best_state],
			"hour_offset": (i + 1) * 6,
		})
		last_state = best_state
	return forecast

func serialize() -> Dictionary:
	return {
		"current_state": int(current_state),
		"target_state": int(target_state),
		"transition_progress": transition_progress,
		"time_until_next_change": time_until_next_change,
		"temperature": temperature,
		"humidity": humidity,
		"wind_strength": _blended_wind,
		"wind_dir_x": wind_direction.x,
		"wind_dir_y": wind_direction.y,
	}

func deserialize(data: Dictionary) -> void:
	if data.has("current_state"):
		set_weather(data["current_state"] as WeatherState, true)
	if data.has("time_until_next_change"):
		time_until_next_change = data["time_until_next_change"]
	if data.has("temperature"):
		temperature = data["temperature"]
	if data.has("humidity"):
		humidity = data["humidity"]
	if data.has("wind_dir_x") and data.has("wind_dir_y"):
		wind_direction = Vector2(data["wind_dir_x"], data["wind_dir_y"])

## Returns a human-readable status string for HUD display.
func get_status_string() -> String:
	var icon := get_weather_icon()
	var name := get_weather_name()
	var temp_str := "%.0f°C" % temperature
	var wind_str := "%.0f km/h" % (_blended_wind * 100.0)
	var vis_str  := "%.0f%%" % (_blended_visibility * 100.0)
	return "%s %s  %s  💨%s  👁%s" % [icon, name, temp_str, wind_str, vis_str]
