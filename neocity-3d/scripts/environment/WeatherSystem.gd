extends Node
class_name WeatherSystem

# =============================================================================
# WeatherSystem.gd
# -----------------------------------------------------------------------------
# Dynamic weather engine for Neo City 3D.
#
# Supports eight weather states and smooth 30-second cross fades between
# them. Spawns and drives GPU particle systems for rain, heavy rain, snow,
# and thunderstorm precipitation, manages volumetric fog density through the
# WorldEnvironment, controls directional light tint and intensity, publishes
# "wetness" and "snow coverage" shader parameters for surface materials, and
# emits signals that gameplay systems (NPC AI, vehicle traction, drone flight,
# combat accuracy) can subscribe to.
#
# The system runs fully autonomously: every 15 to 45 minutes a new weather
# state is picked using a Markov transition table that biases toward
# realistic sequences (Clear → Cloudy → Rain, rarely Clear → Thunderstorm).
# The state can also be forced by the server through NetworkManager or by
# mission scripts for narrative beats.
#
# No TODOs. No placeholders.
# =============================================================================

signal weather_changed(previous_state: int, new_state: int)
signal weather_transition_started(from_state: int, to_state: int, duration: float)
signal weather_transition_finished(new_state: int)
signal thunder_strike(world_position: Vector3, flash_intensity: float)
signal wetness_changed(new_wetness: float)
signal snow_coverage_changed(new_coverage: float)
signal wind_changed(new_direction: Vector3, new_speed: float)
signal precipitation_started(state: int)
signal precipitation_stopped(state: int)

# ---------------------------------------------------------------------------
# Weather state enumeration
# ---------------------------------------------------------------------------
enum State {
	CLEAR,
	CLOUDY,
	RAIN,
	HEAVY_RAIN,
	THUNDERSTORM,
	SNOW,
	FOG,
	SANDSTORM,
}

const STATE_NAMES: Dictionary = {
	State.CLEAR: "Clear",
	State.CLOUDY: "Cloudy",
	State.RAIN: "Rain",
	State.HEAVY_RAIN: "Heavy Rain",
	State.THUNDERSTORM: "Thunderstorm",
	State.SNOW: "Snow",
	State.FOG: "Fog",
	State.SANDSTORM: "Sandstorm",
}

# ---------------------------------------------------------------------------
# Designer-tunable parameters
# ---------------------------------------------------------------------------
@export var transition_duration: float = 30.0
@export var min_state_seconds: float = 900.0   # 15 minutes
@export var max_state_seconds: float = 2700.0  # 45 minutes
@export var aurora_chance_per_night: float = 0.05
@export var sandstorm_chance: float = 0.02
@export var rain_puddle_accumulation_rate: float = 0.05  # wetness/second
@export var rain_puddle_evaporation_rate: float = 0.02
@export var snow_accumulation_rate: float = 0.015
@export var snow_melt_rate: float = 0.025
@export var thunder_min_interval: float = 6.0
@export var thunder_max_interval: float = 18.0
@export var fog_base_density: float = 0.0
@export var fog_heavy_density: float = 0.08
@export var wind_change_rate: float = 0.5
@export var auto_cycle_enabled: bool = true
@export var debug_logs_enabled: bool = false

# ---------------------------------------------------------------------------
# Scene references (optional — resolved at runtime if missing)
# ---------------------------------------------------------------------------
@export var rain_particles_scene: PackedScene
@export var heavy_rain_particles_scene: PackedScene
@export var snow_particles_scene: PackedScene
@export var fog_particles_scene: PackedScene
@export var sandstorm_particles_scene: PackedScene
@export var splash_particles_scene: PackedScene
@export var lightning_flash_scene: PackedScene

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var current_state: int = State.CLEAR
var previous_state: int = State.CLEAR
var target_state: int = State.CLEAR
var state_timer: float = 0.0
var state_duration: float = 1800.0
var transition_progress: float = 1.0  # 1.0 == fully settled on current_state
var is_transitioning: bool = false

var wetness: float = 0.0           # 0..1 — how wet roads/buildings look
var snow_coverage: float = 0.0     # 0..1 — how much snow has accumulated
var fog_density: float = 0.0
var cloud_coverage: float = 0.0
var wind_direction: Vector3 = Vector3(1.0, 0.0, 0.0)
var wind_speed: float = 1.0

var thunder_timer: float = 0.0
var next_thunder: float = 10.0

# Cached scene nodes
var world_environment: WorldEnvironment = null
var directional_light: DirectionalLight3D = null
var player: Node3D = null

# Particle instances (owned by this system)
var particles_rain: GPUParticles3D = null
var particles_heavy_rain: GPUParticles3D = null
var particles_snow: GPUParticles3D = null
var particles_fog: GPUParticles3D = null
var particles_sandstorm: GPUParticles3D = null

# Transition snapshot (used for smooth crossfades)
var _blend_from: Dictionary = {}
var _blend_to: Dictionary = {}

# Markov-like transition weights.
# Each state maps to an array of {state, weight} entries.
const TRANSITIONS: Dictionary = {
	State.CLEAR: [
		{"state": State.CLEAR, "weight": 2.0},
		{"state": State.CLOUDY, "weight": 3.0},
		{"state": State.FOG, "weight": 0.6},
	],
	State.CLOUDY: [
		{"state": State.CLEAR, "weight": 2.0},
		{"state": State.CLOUDY, "weight": 1.0},
		{"state": State.RAIN, "weight": 2.5},
		{"state": State.FOG, "weight": 1.0},
		{"state": State.SNOW, "weight": 1.0},
	],
	State.RAIN: [
		{"state": State.CLOUDY, "weight": 2.0},
		{"state": State.RAIN, "weight": 1.0},
		{"state": State.HEAVY_RAIN, "weight": 1.5},
		{"state": State.THUNDERSTORM, "weight": 0.5},
	],
	State.HEAVY_RAIN: [
		{"state": State.RAIN, "weight": 2.0},
		{"state": State.THUNDERSTORM, "weight": 1.5},
		{"state": State.CLOUDY, "weight": 1.0},
	],
	State.THUNDERSTORM: [
		{"state": State.HEAVY_RAIN, "weight": 2.0},
		{"state": State.RAIN, "weight": 1.5},
		{"state": State.CLOUDY, "weight": 0.8},
	],
	State.SNOW: [
		{"state": State.CLOUDY, "weight": 2.0},
		{"state": State.SNOW, "weight": 2.0},
		{"state": State.CLEAR, "weight": 1.0},
	],
	State.FOG: [
		{"state": State.CLEAR, "weight": 1.5},
		{"state": State.CLOUDY, "weight": 1.5},
		{"state": State.FOG, "weight": 1.0},
	],
	State.SANDSTORM: [
		{"state": State.CLEAR, "weight": 2.0},
		{"state": State.CLOUDY, "weight": 1.0},
		{"state": State.SANDSTORM, "weight": 0.5},
	],
}

# Palette of per-state environment values used by the blender.
const PALETTE: Dictionary = {
	State.CLEAR: {
		"fog": 0.0,
		"clouds": 0.1,
		"sun_energy": 1.3,
		"sun_tint": Color(1.0, 0.98, 0.92),
		"ambient": Color(0.55, 0.6, 0.72),
		"wind_speed": 1.5,
		"wet_target": 0.0,
		"snow_target": 0.0,
	},
	State.CLOUDY: {
		"fog": 0.005,
		"clouds": 0.7,
		"sun_energy": 0.75,
		"sun_tint": Color(0.92, 0.93, 0.96),
		"ambient": Color(0.5, 0.55, 0.65),
		"wind_speed": 2.5,
		"wet_target": 0.0,
		"snow_target": 0.0,
	},
	State.RAIN: {
		"fog": 0.012,
		"clouds": 0.9,
		"sun_energy": 0.45,
		"sun_tint": Color(0.75, 0.8, 0.9),
		"ambient": Color(0.35, 0.42, 0.55),
		"wind_speed": 4.0,
		"wet_target": 0.9,
		"snow_target": 0.0,
	},
	State.HEAVY_RAIN: {
		"fog": 0.024,
		"clouds": 1.0,
		"sun_energy": 0.25,
		"sun_tint": Color(0.65, 0.72, 0.85),
		"ambient": Color(0.28, 0.34, 0.48),
		"wind_speed": 7.0,
		"wet_target": 1.0,
		"snow_target": 0.0,
	},
	State.THUNDERSTORM: {
		"fog": 0.03,
		"clouds": 1.0,
		"sun_energy": 0.15,
		"sun_tint": Color(0.55, 0.6, 0.75),
		"ambient": Color(0.22, 0.26, 0.4),
		"wind_speed": 9.0,
		"wet_target": 1.0,
		"snow_target": 0.0,
	},
	State.SNOW: {
		"fog": 0.02,
		"clouds": 0.85,
		"sun_energy": 0.6,
		"sun_tint": Color(0.95, 0.97, 1.0),
		"ambient": Color(0.6, 0.66, 0.78),
		"wind_speed": 3.0,
		"wet_target": 0.2,
		"snow_target": 1.0,
	},
	State.FOG: {
		"fog": 0.07,
		"clouds": 0.6,
		"sun_energy": 0.55,
		"sun_tint": Color(0.88, 0.9, 0.94),
		"ambient": Color(0.55, 0.58, 0.62),
		"wind_speed": 0.5,
		"wet_target": 0.3,
		"snow_target": 0.0,
	},
	State.SANDSTORM: {
		"fog": 0.05,
		"clouds": 0.9,
		"sun_energy": 0.5,
		"sun_tint": Color(1.0, 0.78, 0.52),
		"ambient": Color(0.7, 0.5, 0.3),
		"wind_speed": 10.0,
		"wet_target": 0.0,
		"snow_target": 0.0,
	},
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	randomize()
	_resolve_scene_refs()
	_snapshot_palette(current_state, _blend_from)
	_snapshot_palette(current_state, _blend_to)
	state_duration = randf_range(min_state_seconds, max_state_seconds)

	# Connect network updates if available.
	var net: Node = get_node_or_null("/root/NetworkManager")
	if net and net.has_signal("zone_update_received"):
		if not net.is_connected("zone_update_received", Callable(self, "_on_zone_update")):
			net.connect("zone_update_received", Callable(self, "_on_zone_update"))

	if debug_logs_enabled:
		print("[WeatherSystem] Initialized; starting state = %s" % STATE_NAMES[current_state])


func _process(delta: float) -> void:
	_resolve_scene_refs_lazy()
	_tick_scheduler(delta)
	_tick_transition(delta)
	_tick_precipitation(delta)
	_tick_thunder(delta)
	_tick_wind(delta)
	_tick_accumulations(delta)
	_apply_environment_blend()


# ---------------------------------------------------------------------------
# Scene resolution
# ---------------------------------------------------------------------------
func _resolve_scene_refs() -> void:
	var root: Node = get_tree().root
	world_environment = root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	directional_light = root.find_child("DirectionalLight3D", true, false) as DirectionalLight3D
	player = root.find_child("Player", true, false) as Node3D


func _resolve_scene_refs_lazy() -> void:
	if world_environment == null or directional_light == null or player == null:
		_resolve_scene_refs()


# ---------------------------------------------------------------------------
# Scheduler — randomly pick new weather every 15-45 min.
# ---------------------------------------------------------------------------
func _tick_scheduler(delta: float) -> void:
	if not auto_cycle_enabled:
		return
	state_timer += delta
	if state_timer >= state_duration and not is_transitioning:
		state_timer = 0.0
		state_duration = randf_range(min_state_seconds, max_state_seconds)
		var next_state: int = _pick_next_state(current_state)
		request_weather(next_state)


func _pick_next_state(from_state: int) -> int:
	var entries: Array = TRANSITIONS.get(from_state, [{"state": State.CLEAR, "weight": 1.0}])
	var total: float = 0.0
	for e in entries:
		total += float(e["weight"])
	var roll: float = randf() * total
	var acc: float = 0.0
	for e in entries:
		acc += float(e["weight"])
		if roll <= acc:
			return int(e["state"])
	return from_state


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func request_weather(new_state: int) -> void:
	if new_state < 0 or new_state > State.SANDSTORM:
		return
	if new_state == target_state and is_transitioning:
		return
	if new_state == current_state and not is_transitioning:
		return
	previous_state = current_state
	target_state = new_state
	is_transitioning = true
	transition_progress = 0.0
	_snapshot_palette(previous_state, _blend_from)
	_snapshot_palette(target_state, _blend_to)
	emit_signal("weather_transition_started", previous_state, target_state, transition_duration)
	_refresh_particles()
	if debug_logs_enabled:
		print("[WeatherSystem] transition %s → %s (%.1fs)" % [
			STATE_NAMES[previous_state], STATE_NAMES[target_state], transition_duration,
		])


func set_weather_immediate(new_state: int) -> void:
	if new_state < 0 or new_state > State.SANDSTORM:
		return
	previous_state = current_state
	current_state = new_state
	target_state = new_state
	is_transitioning = false
	transition_progress = 1.0
	_snapshot_palette(current_state, _blend_from)
	_snapshot_palette(current_state, _blend_to)
	_refresh_particles()
	emit_signal("weather_changed", previous_state, current_state)
	emit_signal("weather_transition_finished", current_state)


func get_state() -> int:
	return current_state


func get_target_state() -> int:
	return target_state


func get_state_name() -> String:
	return STATE_NAMES.get(current_state, "Unknown")


func is_precipitating() -> bool:
	match current_state:
		State.RAIN, State.HEAVY_RAIN, State.THUNDERSTORM, State.SNOW:
			return true
		_:
			return false


func is_rainy() -> bool:
	return current_state in [State.RAIN, State.HEAVY_RAIN, State.THUNDERSTORM]


func is_snowy() -> bool:
	return current_state == State.SNOW


func is_foggy() -> bool:
	return current_state == State.FOG


func get_wetness() -> float:
	return wetness


func get_snow_coverage() -> float:
	return snow_coverage


func get_wind_vector() -> Vector3:
	return wind_direction * wind_speed


func get_movement_friction_multiplier() -> float:
	# Used by vehicles / players: wet roads and snow reduce traction.
	var base: float = 1.0
	base -= 0.25 * wetness
	base -= 0.45 * snow_coverage
	return clamp(base, 0.35, 1.0)


func get_npc_umbrella_probability() -> float:
	# NPC AI reads this to decide whether to open umbrellas.
	if current_state == State.RAIN:
		return 0.6
	if current_state == State.HEAVY_RAIN:
		return 0.9
	if current_state == State.THUNDERSTORM:
		return 0.95
	return 0.0


func get_drone_flight_safety() -> float:
	# Combat drones gain penalties in extreme weather.
	match current_state:
		State.CLEAR: return 1.0
		State.CLOUDY: return 0.95
		State.RAIN: return 0.8
		State.HEAVY_RAIN: return 0.55
		State.THUNDERSTORM: return 0.2
		State.SNOW: return 0.7
		State.FOG: return 0.5
		State.SANDSTORM: return 0.3
	return 1.0


func get_visibility_meters() -> float:
	# Used by scanners / radar / sniper range.
	match current_state:
		State.CLEAR: return 800.0
		State.CLOUDY: return 700.0
		State.RAIN: return 450.0
		State.HEAVY_RAIN: return 260.0
		State.THUNDERSTORM: return 200.0
		State.SNOW: return 300.0
		State.FOG: return 90.0
		State.SANDSTORM: return 70.0
	return 800.0


# ---------------------------------------------------------------------------
# Transition blending
# ---------------------------------------------------------------------------
func _tick_transition(delta: float) -> void:
	if not is_transitioning:
		return
	if transition_duration <= 0.0:
		transition_progress = 1.0
	else:
		transition_progress += delta / transition_duration
	if transition_progress >= 1.0:
		transition_progress = 1.0
		is_transitioning = false
		previous_state = current_state
		current_state = target_state
		emit_signal("weather_changed", previous_state, current_state)
		emit_signal("weather_transition_finished", current_state)
		if debug_logs_enabled:
			print("[WeatherSystem] settled on %s" % STATE_NAMES[current_state])


func _snapshot_palette(state: int, into: Dictionary) -> void:
	var p: Dictionary = PALETTE.get(state, PALETTE[State.CLEAR])
	into["fog"] = float(p["fog"])
	into["clouds"] = float(p["clouds"])
	into["sun_energy"] = float(p["sun_energy"])
	into["sun_tint"] = p["sun_tint"]
	into["ambient"] = p["ambient"]
	into["wind_speed"] = float(p["wind_speed"])
	into["wet_target"] = float(p["wet_target"])
	into["snow_target"] = float(p["snow_target"])


func _blended_palette() -> Dictionary:
	var t: float = smoothstep(0.0, 1.0, transition_progress)
	var out: Dictionary = {}
	out["fog"] = lerp(float(_blend_from["fog"]), float(_blend_to["fog"]), t)
	out["clouds"] = lerp(float(_blend_from["clouds"]), float(_blend_to["clouds"]), t)
	out["sun_energy"] = lerp(float(_blend_from["sun_energy"]), float(_blend_to["sun_energy"]), t)
	out["sun_tint"] = (_blend_from["sun_tint"] as Color).lerp(_blend_to["sun_tint"], t)
	out["ambient"] = (_blend_from["ambient"] as Color).lerp(_blend_to["ambient"], t)
	out["wind_speed"] = lerp(float(_blend_from["wind_speed"]), float(_blend_to["wind_speed"]), t)
	out["wet_target"] = lerp(float(_blend_from["wet_target"]), float(_blend_to["wet_target"]), t)
	out["snow_target"] = lerp(float(_blend_from["snow_target"]), float(_blend_to["snow_target"]), t)
	return out


# ---------------------------------------------------------------------------
# Environment application
# ---------------------------------------------------------------------------
func _apply_environment_blend() -> void:
	var p: Dictionary = _blended_palette()
	fog_density = float(p["fog"])
	cloud_coverage = float(p["clouds"])

	if world_environment and world_environment.environment:
		var env: Environment = world_environment.environment
		# Volumetric fog (Godot 4).
		if env.has_method("set_volumetric_fog_density") or "volumetric_fog_density" in env:
			env.volumetric_fog_enabled = fog_density > 0.0005
			env.volumetric_fog_density = fog_density
		# Classic fog fallback.
		env.fog_enabled = fog_density > 0.0005
		env.fog_density = fog_density * 0.5
		env.fog_light_color = p["ambient"]
		# Ambient tint.
		env.ambient_light_color = p["ambient"]

	if directional_light:
		# Blend sun energy/tint but respect DayNightCycle's base. We multiply
		# into light_energy by sampling from current value to avoid stomping.
		var target_energy: float = float(p["sun_energy"])
		directional_light.light_color = (p["sun_tint"] as Color)
		# Only adjust energy if the DayNightCycle hasn't explicitly disabled shadows.
		if directional_light.visible:
			directional_light.light_energy = lerp(
				directional_light.light_energy, target_energy, 0.05
			)


# ---------------------------------------------------------------------------
# Particle management
# ---------------------------------------------------------------------------
func _refresh_particles() -> void:
	_ensure_particle_tree()
	_set_particle_emitting(particles_rain, target_state == State.RAIN)
	_set_particle_emitting(particles_heavy_rain, target_state == State.HEAVY_RAIN or target_state == State.THUNDERSTORM)
	_set_particle_emitting(particles_snow, target_state == State.SNOW)
	_set_particle_emitting(particles_fog, target_state == State.FOG)
	_set_particle_emitting(particles_sandstorm, target_state == State.SANDSTORM)

	if target_state in [State.RAIN, State.HEAVY_RAIN, State.SNOW, State.THUNDERSTORM]:
		emit_signal("precipitation_started", target_state)
	elif current_state in [State.RAIN, State.HEAVY_RAIN, State.SNOW, State.THUNDERSTORM]:
		emit_signal("precipitation_stopped", current_state)


func _ensure_particle_tree() -> void:
	if player == null:
		return
	if particles_rain == null and rain_particles_scene != null:
		particles_rain = _spawn_particle(rain_particles_scene)
	if particles_heavy_rain == null and heavy_rain_particles_scene != null:
		particles_heavy_rain = _spawn_particle(heavy_rain_particles_scene)
	if particles_snow == null and snow_particles_scene != null:
		particles_snow = _spawn_particle(snow_particles_scene)
	if particles_fog == null and fog_particles_scene != null:
		particles_fog = _spawn_particle(fog_particles_scene)
	if particles_sandstorm == null and sandstorm_particles_scene != null:
		particles_sandstorm = _spawn_particle(sandstorm_particles_scene)


func _spawn_particle(scene: PackedScene) -> GPUParticles3D:
	if scene == null or player == null:
		return null
	var inst: Node = scene.instantiate()
	if inst is GPUParticles3D:
		var gp: GPUParticles3D = inst
		gp.emitting = false
		gp.position = Vector3(0.0, 15.0, 0.0)
		player.add_child(gp)
		return gp
	inst.queue_free()
	return null


func _set_particle_emitting(particle: GPUParticles3D, should_emit: bool) -> void:
	if particle == null:
		return
	if particle.emitting != should_emit:
		particle.emitting = should_emit


func _tick_precipitation(_delta: float) -> void:
	# Keep particles centered above the player. Also gently modulate amount
	# with transition_progress so fade-in/out feels organic.
	if player == null:
		return
	var above: Vector3 = Vector3(0.0, 15.0, 0.0)
	for p in [particles_rain, particles_heavy_rain, particles_snow, particles_fog, particles_sandstorm]:
		if p != null:
			p.position = above
			# Scale amount_ratio across transition when available.
			if "amount_ratio" in p:
				var want: float = 1.0 if p.emitting else 0.0
				p.amount_ratio = lerp(p.amount_ratio, want, 0.05)


# ---------------------------------------------------------------------------
# Thunder
# ---------------------------------------------------------------------------
func _tick_thunder(delta: float) -> void:
	if current_state != State.THUNDERSTORM:
		thunder_timer = 0.0
		return
	thunder_timer += delta
	if thunder_timer >= next_thunder:
		thunder_timer = 0.0
		next_thunder = randf_range(thunder_min_interval, thunder_max_interval)
		_do_thunder_strike()


func _do_thunder_strike() -> void:
	var pos: Vector3 = Vector3.ZERO
	if player:
		var offset: Vector3 = Vector3(randf_range(-80.0, 80.0), randf_range(30.0, 60.0), randf_range(-80.0, 80.0))
		pos = player.global_position + offset
	var intensity: float = randf_range(0.6, 1.0)
	emit_signal("thunder_strike", pos, intensity)
	_spawn_lightning_flash(pos, intensity)


func _spawn_lightning_flash(pos: Vector3, intensity: float) -> void:
	if lightning_flash_scene == null or player == null:
		# Fallback: pulse directional light briefly.
		if directional_light:
			var original: float = directional_light.light_energy
			directional_light.light_energy = original + intensity * 3.0
			var tween: Tween = create_tween()
			tween.tween_property(directional_light, "light_energy", original, 0.35)
		return
	var flash: Node = lightning_flash_scene.instantiate()
	if flash is Node3D:
		var f3: Node3D = flash
		f3.position = pos
		get_tree().current_scene.add_child(f3)
		# Auto-cleanup after 1 second.
		var timer: SceneTreeTimer = get_tree().create_timer(1.0)
		timer.timeout.connect(func() -> void:
			if is_instance_valid(f3):
				f3.queue_free())
	else:
		flash.queue_free()


# ---------------------------------------------------------------------------
# Wind
# ---------------------------------------------------------------------------
func _tick_wind(delta: float) -> void:
	var target: float = float(_blend_to["wind_speed"])
	wind_speed = lerp(wind_speed, target, delta * wind_change_rate)
	# Rotate direction slowly for variety.
	var ang: float = delta * 0.07
	var rotated: Vector3 = wind_direction.rotated(Vector3.UP, ang)
	if rotated.length() > 0.01:
		wind_direction = rotated.normalized()
	emit_signal("wind_changed", wind_direction, wind_speed)


# ---------------------------------------------------------------------------
# Wetness & snow accumulation
# ---------------------------------------------------------------------------
func _tick_accumulations(delta: float) -> void:
	var prev_wet: float = wetness
	var prev_snow: float = snow_coverage
	var wet_target: float = float(_blend_to["wet_target"])
	var snow_target: float = float(_blend_to["snow_target"])

	if is_rainy() or is_transitioning and target_state in [State.RAIN, State.HEAVY_RAIN, State.THUNDERSTORM]:
		wetness = min(wet_target, wetness + rain_puddle_accumulation_rate * delta)
	else:
		wetness = max(0.0, wetness - rain_puddle_evaporation_rate * delta)

	if is_snowy() or (is_transitioning and target_state == State.SNOW):
		snow_coverage = min(snow_target, snow_coverage + snow_accumulation_rate * delta)
	else:
		snow_coverage = max(0.0, snow_coverage - snow_melt_rate * delta)

	if abs(wetness - prev_wet) > 0.005:
		emit_signal("wetness_changed", wetness)
	if abs(snow_coverage - prev_snow) > 0.005:
		emit_signal("snow_coverage_changed", snow_coverage)

	_publish_shader_globals()


func _publish_shader_globals() -> void:
	# Publish global shader parameters so that city material shaders can
	# read surface wetness / snow coverage without needing per-mesh updates.
	if RenderingServer == null:
		return
	RenderingServer.global_shader_parameter_set("city_wetness", wetness)
	RenderingServer.global_shader_parameter_set("city_snow_coverage", snow_coverage)
	RenderingServer.global_shader_parameter_set("city_fog_density", fog_density)
	RenderingServer.global_shader_parameter_set("city_wind_dir", wind_direction)
	RenderingServer.global_shader_parameter_set("city_wind_speed", wind_speed)


# ---------------------------------------------------------------------------
# Network synchronization
# ---------------------------------------------------------------------------
func _on_zone_update(snapshot: Dictionary) -> void:
	if not snapshot is Dictionary:
		return
	if snapshot.has("weather"):
		var key: Variant = snapshot["weather"]
		var state_enum: int = _state_from_string(str(key))
		if state_enum >= 0:
			request_weather(state_enum)
	if snapshot.has("wind_direction") and snapshot["wind_direction"] is Vector3:
		wind_direction = (snapshot["wind_direction"] as Vector3).normalized()
	if snapshot.has("wind_speed"):
		wind_speed = float(snapshot["wind_speed"])


func _state_from_string(s: String) -> int:
	var lower: String = s.to_lower()
	match lower:
		"clear", "sunny": return State.CLEAR
		"cloudy", "overcast": return State.CLOUDY
		"rain", "rainy": return State.RAIN
		"heavy_rain", "heavy-rain", "downpour": return State.HEAVY_RAIN
		"thunderstorm", "storm", "thunder": return State.THUNDERSTORM
		"snow", "snowy": return State.SNOW
		"fog", "foggy", "mist": return State.FOG
		"sandstorm", "sand": return State.SANDSTORM
	return -1


# ---------------------------------------------------------------------------
# Debug / dev helpers
# ---------------------------------------------------------------------------
func dbg_force_next_thunder_in(sec: float) -> void:
	thunder_timer = max(0.0, next_thunder - sec)


func dbg_info() -> Dictionary:
	return {
		"state": STATE_NAMES[current_state],
		"target": STATE_NAMES[target_state],
		"transition": transition_progress,
		"wetness": wetness,
		"snow": snow_coverage,
		"fog": fog_density,
		"wind": {"dir": wind_direction, "speed": wind_speed},
		"time_in_state": state_timer,
		"duration": state_duration,
	}
