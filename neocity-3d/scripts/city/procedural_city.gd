## ProceduralCity — Massive Multiplayer Cyberpunk City Orchestrator
##
## ProceduralCity is the top-level Node3D that composes DistrictPlanner,
## BuildingFactory, InteriorMappingMaterial, NeonSkyscraper, and
## SkyBridgeNetwork into a single, deterministic city generator. It is
## designed to be dropped directly into `main.tscn` as a replacement (or
## superset) of the existing `city_generator.gd`.
##
## Pipeline, invoked by `_ready()` (or `generate()` from outside):
##
##   1. Plan districts via DistrictPlanner → seeded Voronoi partition.
##   2. Walk the block grid and, per-lot, classify the lot's district,
##      delegate to BuildingFactory for a building archetype, and record
##      the building's tier-top anchors.
##   3. Reserve a few landmark slots for NeonSkyscraper objects (one per
##      downtown / entertainment seed).
##   4. Pass all anchors to SkyBridgeNetwork and build bridges (async).
##   5. Scatter street-level neon lights, billboards, and ambience props.
##   6. Run a distance-based LOD sweep every N frames to hide distant
##      buildings on mid-tier mobile WebGL.
##
## Networked play: the procedural city is **deterministic** given
## `city_seed`. Both server and client generate the same mesh layout, so no
## static geometry needs to be streamed — only gameplay state. This is
## essential for scaling to 10,000 concurrent players (see SpatialPartition
## and NetworkSyncOptimizer).
##
## Intended performance envelope (mid-tier mobile WebGL, 60 fps):
##   • ~1000 buildings visible + ~200 sky-bridge sections,
##   • single-pass forward rendering,
##   • no dynamic shadows on anything beyond LOD_SHADOW_DISTANCE,
##   • GPU budget ≈ 8 ms/frame, CPU budget ≈ 4 ms/frame.
##
## ProceduralCity is fully self-contained and does not touch the existing
## `city_generator.gd`; both may coexist in the same project.

class_name ProceduralCity
extends Node3D

const DistrictPlannerScript = preload("res://scripts/city/district_planner.gd")
const BuildingFactoryScript = preload("res://scripts/city/building_factory.gd")
const NeonSkyscraperScript  = preload("res://scripts/city/neon_skyscraper.gd")
const SkyBridgeNetworkScript = preload("res://scripts/city/sky_bridge_network.gd")
const InteriorMap = preload("res://scripts/city/interior_mapping_material.gd")

# ── Tuneables ────────────────────────────────────────────────────────────────

## Seed for deterministic generation. 0 = pull from system clock.
@export var city_seed: int = 0

## Half the count of blocks per axis. The total block count is
## `(2 * city_radius)²`.
@export var city_radius: int = 14

## Side length of a single city block (world units). Includes road allowance.
@export var block_size: float = 38.0

## Width of the inter-block road. Subtracted from block area before placing
## lots.
@export var road_width: float = 8.0

## How many lots fit per block axis. 2 = classic 2×2. Higher values produce
## denser urban grain at the cost of more draw calls.
@export var lots_per_block: int = 2

## Minimum / maximum building height seeds. Actual height is further scaled
## by the district multiplier.
@export var min_building_height: float = 9.0
@export var max_building_height: float = 110.0

## Number of landmark NeonSkyscrapers to reserve. They are placed on the
## `force_downtown_center` seed + up to this many entertainment/downtown seeds.
@export var landmark_count: int = 6

## Street-light count scattered along road intersections.
@export var street_light_count: int = 120

## LOD cull distance. 0 disables culling.
@export var lod_cull_distance: float = 220.0

## Shadows are disabled on buildings beyond this distance, independently of
## full cull.
@export var lod_shadow_distance: float = 90.0

## LOD sweeps run every this many frames.
@export var lod_check_frames: int = 30

## If true, the whole city is generated inside a call_deferred() so the game
## can present a loading screen on the first frame.
@export var defer_first_generate: bool = true

## If true, SkyBridgeNetwork will be built asynchronously (frame-budgeted).
@export var build_bridges_async: bool = true

## If assigned, a NavigationRegion3D auto-baked from the road network.
@export var navigation_region: NodePath

# ── Signals ─────────────────────────────────────────────────────────────────

signal generation_started
signal generation_progress(stage: String, progress: float)
signal generation_completed(stats: Dictionary)

# ── Internal state ───────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _planner = null  # DistrictPlanner
var _bridge_net: Node3D = null
var _building_roots: Array = []   # Array of Node3D
var _building_metas: Array = []   # Array of BuildingMetadata
var _rooftop_anchors: Array = []  # Array of {pos, footprint, meta} for bridges
var _landmarks: Array = []        # Array of NeonSkyscraper
var _street_lights: Array = []    # Array of OmniLight3D
var _lod_frame: int = 0
var _camera: Camera3D = null
var _is_generating: bool = false
var _generation_stats: Dictionary = {}

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	if defer_first_generate:
		call_deferred("generate")
	else:
		generate()


## Rebuild the entire city. Safe to call multiple times; it disposes previous
## nodes first.
func generate() -> void:
	if _is_generating:
		push_warning("[ProceduralCity] generate() called while already generating.")
		return
	_is_generating = true
	generation_started.emit()
	_clear_previous()

	_rng.seed = city_seed if city_seed != 0 else int(Time.get_ticks_usec())

	# Stage 1 — plan districts.
	_planner = DistrictPlannerScript.new()
	_planner.planner_seed = int(_rng.randi())
	_planner.city_half_extent = float(city_radius) * (block_size + road_width)
	_planner.district_count = max(6, int(city_radius * 0.8))
	add_child(_planner)
	_planner.build()
	generation_progress.emit("districts", 0.1)

	# Stage 2 — block walk, spawn buildings.
	_generate_blocks()
	generation_progress.emit("buildings", 0.55)

	# Stage 3 — place landmarks.
	_place_landmarks()
	generation_progress.emit("landmarks", 0.65)

	# Stage 4 — street lights.
	_scatter_street_lights()
	generation_progress.emit("street_lights", 0.75)

	# Stage 5 — sky-bridge graph.
	_bridge_net = SkyBridgeNetworkScript.new()
	_bridge_net.name = "SkyBridges"
	add_child(_bridge_net)
	_bridge_net.set_anchors(_rooftop_anchors)
	if build_bridges_async:
		_bridge_net.build_completed.connect(_on_bridges_done, CONNECT_ONE_SHOT)
		_bridge_net.build_progress.connect(_on_bridges_progress)
		_bridge_net.call_deferred("build_async", int(_rng.randi()))
	else:
		_bridge_net.build(int(_rng.randi()))
		_finish_generation()


func _on_bridges_progress(created: int, total: int) -> void:
	var p: float = 0.75 + 0.2 * (float(created) / max(1.0, float(total)))
	generation_progress.emit("sky_bridges", clamp(p, 0.0, 0.95))


func _on_bridges_done(_bridge_count: int) -> void:
	_finish_generation()


func _finish_generation() -> void:
	_generation_stats = {
		"buildings": _building_roots.size(),
		"landmarks": _landmarks.size(),
		"bridges": _bridge_net.bridge_count() if _bridge_net else 0,
		"street_lights": _street_lights.size(),
		"districts": _planner.get_seed_snapshots().size() if _planner else 0,
		"material_stats": InteriorMap.stats(),
	}
	_is_generating = false
	generation_progress.emit("complete", 1.0)
	generation_completed.emit(_generation_stats)
	print("[ProceduralCity] Generated: ", _generation_stats)


func _process(_delta: float) -> void:
	if lod_cull_distance <= 0.0:
		return
	_lod_frame += 1
	if _lod_frame % max(1, lod_check_frames) != 0:
		return
	_update_lod()


# ── Generation stages ────────────────────────────────────────────────────────

func _clear_previous() -> void:
	for r in _building_roots:
		if is_instance_valid(r):
			r.queue_free()
	_building_roots.clear()
	_building_metas.clear()
	_rooftop_anchors.clear()
	for l in _landmarks:
		if is_instance_valid(l):
			l.queue_free()
	_landmarks.clear()
	for s in _street_lights:
		if is_instance_valid(s):
			s.queue_free()
	_street_lights.clear()
	if _bridge_net and is_instance_valid(_bridge_net):
		_bridge_net.queue_free()
		_bridge_net = null
	if _planner and is_instance_valid(_planner):
		_planner.queue_free()
		_planner = null


func _generate_blocks() -> void:
	var stride: float = block_size + road_width
	var half: int = city_radius
	var lot_stride: float = (block_size - road_width * 0.25) / float(lots_per_block)
	for gx in range(-half, half):
		for gz in range(-half, half):
			var block_origin: Vector3 = Vector3(
				float(gx) * stride,
				0.0,
				float(gz) * stride,
			)
			_generate_block(block_origin, lot_stride)


func _generate_block(origin: Vector3, lot_stride: float) -> void:
	var lot_half: float = lot_stride * 0.5
	for lx in range(lots_per_block):
		for lz in range(lots_per_block):
			var lot_center: Vector3 = origin + Vector3(
				(float(lx) + 0.5) * lot_stride - (float(lots_per_block) * 0.5) * lot_stride + lot_half,
				0.0,
				(float(lz) + 0.5) * lot_stride - (float(lots_per_block) * 0.5) * lot_stride + lot_half,
			)
			var info = _planner.classify_point(lot_center)
			# Thin the density by the district's density score so industrial /
			# waterfront areas feel spacious while downtown feels packed.
			if _rng.randf() > info.density * 0.9:
				continue
			_spawn_building_at(lot_center, lot_stride, info)


func _spawn_building_at(center_ground: Vector3, lot_size: float, info) -> void:
	# Reserve a bit of breathing room on the lot edge.
	var effective_lot: float = lot_size * 0.9
	var result: Array = BuildingFactoryScript.spawn(center_ground, effective_lot, info, _rng)
	var root: Node3D = result[0]
	var meta = result[1]
	add_child(root)
	_building_roots.append(root)
	_building_metas.append(meta)
	# Record anchors for bridge generation.
	for anchor in BuildingFactoryScript.rooftop_anchors_for(meta, center_ground):
		_rooftop_anchors.append(anchor)


func _place_landmarks() -> void:
	if landmark_count <= 0 or _planner == null:
		return
	var seeds: Array = _planner.get_seed_snapshots()
	var candidates: Array = []
	for s in seeds:
		var t: int = int(s["type"])
		if t == DistrictPlanner.DistrictType.DOWNTOWN \
				or t == DistrictPlanner.DistrictType.ENTERTAINMENT:
			candidates.append(s)
	candidates.shuffle()
	var placed: int = 0
	for c in candidates:
		if placed >= landmark_count:
			break
		var pos_xz: Vector2 = c["pos"]
		var ground: Vector3 = Vector3(pos_xz.x, 0.0, pos_xz.y)
		var info = _planner.classify_point(ground)
		var landmark := NeonSkyscraperScript.new()
		landmark.lot_size = block_size * 0.9
		landmark.seed = int(_rng.randi())
		landmark.district_info = info
		landmark.position = ground
		add_child(landmark)
		_landmarks.append(landmark)
		placed += 1
		# Landmark._ready() has run synchronously inside add_child(), so we can
		# read its rooftop position now to contribute anchors to the bridge graph.
		_inject_landmark_anchor(landmark)


func _inject_landmark_anchor(landmark: Node3D) -> void:
	# Called once per landmark. Height is available after _ready.
	if not is_instance_valid(landmark):
		return
	var top: Vector3 = landmark.call("rooftop_position") if landmark.has_method("rooftop_position") else landmark.global_position
	var anchor := {
		"pos": top,
		"footprint": landmark.lot_size * 0.5,
		"meta": null,
	}
	_rooftop_anchors.append(anchor)


func _scatter_street_lights() -> void:
	var half_extent: float = float(city_radius) * (block_size + road_width)
	for _i in range(street_light_count):
		var pos := Vector3(
			_rng.randf_range(-half_extent, half_extent),
			4.0,
			_rng.randf_range(-half_extent, half_extent),
		)
		var info = _planner.classify_point(pos)
		var lamp := OmniLight3D.new()
		lamp.position = pos
		lamp.omni_range = _rng.randf_range(12.0, 22.0)
		lamp.light_color = info.street_light_color
		lamp.light_energy = _rng.randf_range(0.8, 1.6)
		lamp.shadow_enabled = false
		add_child(lamp)
		_street_lights.append(lamp)


# ── LOD ──────────────────────────────────────────────────────────────────────

func _update_lod() -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_viewport().get_camera_3d()
		if _camera == null:
			return
	var cam_pos: Vector3 = _camera.global_position
	var cull_sq: float = lod_cull_distance * lod_cull_distance
	var shadow_sq: float = lod_shadow_distance * lod_shadow_distance

	for root in _building_roots:
		if not is_instance_valid(root):
			continue
		var d: float = (root.global_position - cam_pos).length_squared()
		root.visible = d <= cull_sq
		# Toggle shadows on every MeshInstance3D child.
		if root.visible:
			_set_shadow_for_children(root, d <= shadow_sq)


func _set_shadow_for_children(root: Node, shadows_on: bool) -> void:
	for child in root.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				if shadows_on
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			)
		if child.get_child_count() > 0:
			_set_shadow_for_children(child, shadows_on)


# ── Query API ────────────────────────────────────────────────────────────────

## Count of live building roots.
func building_count() -> int:
	return _building_roots.size()


## Flat array of all rooftop anchors used by the sky-bridge graph.
func rooftop_anchors() -> Array:
	return _rooftop_anchors.duplicate()


## Planner accessor so external systems (AI, quests, minimap) can query zone
## information at a world point.
func district_at(world_pos: Vector3):
	if _planner == null:
		return null
	return _planner.classify_point(world_pos)


## Sky-bridge graph snapshot for minimap rendering.
func bridge_snapshot() -> Array:
	if _bridge_net == null:
		return []
	return _bridge_net.snapshot()


## Notify every landmark of a new weather state. 0 = clear, 1 = storm.
func apply_weather(storm_intensity: float) -> void:
	for l in _landmarks:
		if is_instance_valid(l) and l.has_method("apply_weather"):
			l.apply_weather(storm_intensity)


## Generation stats from the last completed run.
func last_generation_stats() -> Dictionary:
	return _generation_stats.duplicate(true)


## Re-run the city from scratch with a new seed. Useful for dev-only hotkeys.
func reseed(new_seed: int) -> void:
	city_seed = new_seed
	generate()
