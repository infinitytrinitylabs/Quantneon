## NeonSkyscraper — Animated Landmark Skyscraper
##
## A NeonSkyscraper is a decorated container around a BuildingFactory output
## that adds runtime behaviour:
##
##   • Pulsing neon edge trim whose brightness follows a sine wave.
##   • Rotating holographic logo above the crown.
##   • Scrolling billboard reel playing a deterministic set of ad-text frames.
##   • Aviation beacon blink on the antenna tip (with occasional stutter).
##   • Weather-responsive emissive dampening (rain dims neon by 15-25%).
##
## It is designed to be spawned sparsely — ProceduralCity reserves one
## NeonSkyscraper per DOWNTOWN / ENTERTAINMENT district. The cost of a single
## NeonSkyscraper on mid-tier mobile WebGL is dominated by the rotating
## hologram (a double-sided QuadMesh with unshaded emissive material) and is
## comfortably within the 0.05 ms/frame budget we leave for landmarks.
##
## Usage:
##
##     var landmark := NeonSkyscraper.new()
##     landmark.district_info = info
##     landmark.seed = 42
##     landmark.global_position = pos
##     get_tree().root.add_child(landmark)
##
## The script assumes the landmark is a direct ancestor of the BuildingFactory
## output — it handles construction in `_ready()`.

class_name NeonSkyscraper
extends Node3D

const BuildingFactoryScript = preload("res://scripts/city/building_factory.gd")
const DistrictPlannerScript = preload("res://scripts/city/district_planner.gd")
const InteriorMap = preload("res://scripts/city/interior_mapping_material.gd")

# ── Exports ──────────────────────────────────────────────────────────────────

## DistrictInfo this landmark inherits its palette from. If null, a default
## downtown profile is synthesised.
var district_info = null

## Footprint-size lot hint (same semantics as BuildingFactory.spawn).
@export var lot_size: float = 60.0

## Seed for deterministic geometry + animation.
@export var seed: int = 0

## If true, the landmark automatically deforms its neon pulse with a slight
## per-building phase so a cluster of landmarks does not beat in unison.
@export var unique_phase: bool = true

## Base brightness for the neon pulse. Emission multipliers scale around this.
@export var base_neon_energy: float = 4.5

## Depth of the pulse (0 = static, 1 = full off at trough).
@export var pulse_depth: float = 0.45

## Pulse rate in Hz.
@export var pulse_hz: float = 0.55

## Antenna beacon blink in Hz.
@export var beacon_hz: float = 1.2

## Billboard frames (string lines). The reel cycles one frame every
## billboard_dwell seconds.
@export var billboard_frames: Array[String] = [
	"QUANTNEON",
	"TRUST //NEURAL",
	"NEOCITY 2099",
	"UPGRADE OR DIE",
	"HACK THE PLANET",
	"DREAM.EXE",
]

@export var billboard_dwell: float = 3.5

# ── Internal state ───────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _meta = null  # BuildingMetadata from BuildingFactory
var _neon_materials: Array = []  # Array of StandardMaterial3D whose emission_energy we drive
var _hologram: MeshInstance3D = null
var _hologram_anchor: Node3D = null
var _beacon_lights: Array = []  # Array of OmniLight3D
var _beacon_state: bool = false
var _beacon_next_toggle: float = 0.0
var _billboard_face: MeshInstance3D = null
var _billboard_label: Label3D = null
var _billboard_frame_idx: int = 0
var _billboard_timer: float = 0.0
var _phase_offset: float = 0.0
var _weather_dim: float = 1.0  # 1.0 = dry, 0.75 = rain

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_rng.seed = seed if seed != 0 else int(Time.get_ticks_usec())
	_phase_offset = _rng.randf() * TAU if unique_phase else 0.0

	if district_info == null:
		district_info = _default_downtown_info()

	# Force a MEGASPIRE style for landmark dominance in the skyline.
	var result: Array = BuildingFactoryScript.build_style(
		"MEGASPIRE",
		Vector3.ZERO,  # local origin, we position the landmark itself
		lot_size,
		district_info,
		_rng,
	)
	var core: Node3D = result[0] as Node3D
	_meta = result[1]
	core.name = "Core"
	add_child(core)

	_collect_neon_materials(core)
	_collect_beacon_lights(core)
	_spawn_hologram()
	_spawn_billboard()
	set_process(true)


func _process(delta: float) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0

	# Neon pulse.
	var pulse_energy: float = base_neon_energy * _weather_dim * (
		1.0 - pulse_depth * 0.5 * (1.0 - cos(now * TAU * pulse_hz + _phase_offset))
	)
	for m in _neon_materials:
		if m is StandardMaterial3D:
			m.emission_energy_multiplier = pulse_energy

	# Hologram rotation.
	if _hologram_anchor != null:
		_hologram_anchor.rotation.y += delta * 0.5

	# Beacon blink with stutter.
	_beacon_next_toggle -= delta
	if _beacon_next_toggle <= 0.0:
		_beacon_state = not _beacon_state
		_beacon_next_toggle = (1.0 / max(0.1, beacon_hz)) * (_rng.randf_range(0.9, 1.1) if _beacon_state else _rng.randf_range(0.5, 0.8))
		for l in _beacon_lights:
			if l is OmniLight3D:
				l.light_energy = 1.6 if _beacon_state else 0.15

	# Billboard reel.
	_billboard_timer += delta
	if _billboard_timer >= billboard_dwell and _billboard_label != null and billboard_frames.size() > 0:
		_billboard_timer = 0.0
		_billboard_frame_idx = (_billboard_frame_idx + 1) % billboard_frames.size()
		_billboard_label.text = billboard_frames[_billboard_frame_idx]


## Inform the landmark of a weather change. t=0 clear, t=1 storm.
func apply_weather(storm_intensity: float) -> void:
	_weather_dim = lerp(1.0, 0.72, clamp(storm_intensity, 0.0, 1.0))


## Return the rooftop world position (for sky-bridge attachment).
func rooftop_position() -> Vector3:
	if _meta == null:
		return global_position
	return global_position + Vector3(0.0, _meta.height, 0.0)


## Return a plain dictionary describing this landmark, suitable for serialising
## to telemetry / minimap APIs.
func describe() -> Dictionary:
	return {
		"style": _meta.style if _meta else "unknown",
		"height": _meta.height if _meta else 0.0,
		"footprint": _meta.footprint if _meta else 0.0,
		"district": district_info.tag if district_info else "unknown",
		"has_hologram": _hologram != null,
		"has_billboard": _billboard_face != null,
		"beacons": _beacon_lights.size(),
	}


# ── Setup helpers ────────────────────────────────────────────────────────────

func _collect_neon_materials(root: Node) -> void:
	for child in root.get_children():
		if child is MeshInstance3D and child.name.begins_with("NeonTrim_"):
			var mat := child.material_override
			if mat is StandardMaterial3D and mat.emission_enabled:
				_neon_materials.append(mat)
		elif child is Node:
			_collect_neon_materials(child)


func _collect_beacon_lights(root: Node) -> void:
	for child in root.get_children():
		if child is OmniLight3D:
			_beacon_lights.append(child)
		elif child is Node:
			_collect_beacon_lights(child)


func _spawn_hologram() -> void:
	if _meta == null:
		return
	# Anchor node so we rotate the hologram, not the quad itself (otherwise the
	# face would rotate out of the double-sided orientation).
	var anchor := Node3D.new()
	anchor.position = Vector3(0.0, _meta.height + 6.0, 0.0)
	add_child(anchor)
	_hologram_anchor = anchor

	var hologram := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(lot_size * 0.45, lot_size * 0.25)
	hologram.mesh = quad
	hologram.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = district_info.neon_primary
	m.albedo_color.a = 0.35
	m.emission_enabled = true
	m.emission = district_info.neon_primary
	m.emission_energy_multiplier = 5.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	hologram.material_override = m
	anchor.add_child(hologram)
	_hologram = hologram


func _spawn_billboard() -> void:
	if _meta == null:
		return
	if billboard_frames.is_empty():
		return
	# Mount on a mid-height ring facing +Z.
	var face := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(lot_size * 0.6, lot_size * 0.2)
	face.mesh = q
	face.position = Vector3(0.0, _meta.height * 0.55, _meta.footprint * 0.55 + 0.2)
	face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	face.material_override = InteriorMap.build_for_billboard(district_info, _rng, 12)
	add_child(face)
	_billboard_face = face

	var label := Label3D.new()
	label.text = billboard_frames[0]
	label.modulate = Color(1, 1, 1, 1)
	label.outline_modulate = Color(0, 0, 0, 1)
	label.outline_size = 6
	label.pixel_size = 0.02
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.double_sided = true
	label.no_depth_test = false
	label.font_size = 64
	label.position = face.position + Vector3(0.0, 0.0, 0.05)
	add_child(label)
	_billboard_label = label


func _default_downtown_info():
	# DistrictPlanner's _init builds the archetype cache, so .new() is enough.
	var planner = DistrictPlannerScript.new()
	return planner._archetype_info(DistrictPlanner.DistrictType.DOWNTOWN)
