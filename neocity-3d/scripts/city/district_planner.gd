## DistrictPlanner — Voronoi-Style Zoning For Procedural Cyberpunk Cities
##
## The planner carves the city footprint into a small number of themed districts
## using a deterministic weighted Voronoi partition. Every building lot in the
## procedural city asks the planner "which district am I in?" via
## `classify_point()` and receives a `DistrictInfo` struct describing:
##
##   • the district archetype (DOWNTOWN, CORPORATE, RESIDENTIAL, INDUSTRIAL,
##     SLUMS, ENTERTAINMENT, WATERFRONT),
##   • a density multiplier that scales building height / footprint,
##   • a neon palette biased towards the district's mood,
##   • a building-style weight table driving the BuildingFactory's pick,
##   • a sky-bridge density hint used by SkyBridgeNetwork,
##   • an interior-mapping palette used by InteriorMappingMaterial,
##   • a street-light colour and an ambience tag for CityAmbience.
##
## All outputs are deterministic given the same `planner_seed`. The planner is
## a pure-data node — it owns no meshes and can be safely instantiated on the
## headless server for authoritative zoning queries as well as on the client for
## presentation.
##
## Typical usage from ProceduralCity:
##
##     var planner := DistrictPlanner.new()
##     planner.planner_seed = 42
##     planner.city_half_extent = city_radius * (block_size + road_width)
##     planner.district_count   = 9
##     planner.build()
##     var info := planner.classify_point(Vector3(120.0, 0.0, -80.0))
##     building_factory.spawn(info)
##
## Determinism note: every randomised step uses the planner's internal RNG
## seeded from `planner_seed`. The same seed and parameters will always
## reproduce the exact same district map across machines — critical for
## authoritative multiplayer where client and server must agree on zoning.

class_name DistrictPlanner
extends Node

# ── District archetypes ──────────────────────────────────────────────────────

enum DistrictType {
	DOWNTOWN,       # Supertall corporate spires, heavy neon, dense sky-bridges.
	CORPORATE,      # Mid-tall glass towers, subdued palette, clean grid.
	RESIDENTIAL,    # Medium apartment blocks, warm window glow.
	INDUSTRIAL,     # Low wide factories, sodium-orange lighting, smoke.
	SLUMS,          # Short messy stacks, warm magenta glow, graffiti-friendly.
	ENTERTAINMENT,  # Short-to-mid with huge billboards, saturated neon.
	WATERFRONT,     # Scarce buildings, heavy open space, cold palette.
}

## Human-readable tag used by CityAmbience / UI.
const DISTRICT_TAGS: Array[String] = [
	"downtown",
	"corporate",
	"residential",
	"industrial",
	"slums",
	"entertainment",
	"waterfront",
]

# ── Tuneables ────────────────────────────────────────────────────────────────

## Seed for deterministic partitioning. 0 ⇒ pull from the system clock.
@export var planner_seed: int = 0

## Half-extent of the city on the XZ plane (world units). The planner fills a
## square of side 2 * city_half_extent centred on the origin.
@export var city_half_extent: float = 800.0

## How many district seed points to scatter. Must be ≥ 2; practical range 6–14.
@export var district_count: int = 9

## Minimum separation between any two district seed points. Prevents degenerate
## partitions where one district wraps another.
@export var min_seed_separation: float = 160.0

## Chance that the geometric centre is forced to be a DOWNTOWN seed. This is
## what most players expect visually and makes the skyline read as a "city".
@export var force_downtown_center: bool = true

## How strongly the weighted Voronoi biases towards higher-weight seeds.
## 0 = unweighted (classic Voronoi), 1 = strong bias.
@export_range(0.0, 1.0) var weight_bias: float = 0.35

## If true, districts further from the centre are biased towards outskirts
## archetypes (SLUMS / INDUSTRIAL / WATERFRONT).
@export var radial_bias_enabled: bool = true

# ── Runtime state ────────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

## Parallel arrays indexed by seed index.
var _seed_positions: Array[Vector2] = []      # XZ-plane positions.
var _seed_types:     Array[int]     = []      # DistrictType enum values.
var _seed_weights:   Array[float]   = []      # Voronoi weights.

## Precomputed per-archetype presentation data.
var _archetype_cache: Dictionary = {}

## Cheap cache for repeat `classify_point()` calls within the same cell.
var _classify_cache: Dictionary = {}
var _classify_cache_cell: float = 8.0
var _classify_cache_limit: int = 4096

# ── Data types ───────────────────────────────────────────────────────────────

## Plain-data snapshot returned from classify_point().
class DistrictInfo:
	var type: int = DistrictPlanner.DistrictType.RESIDENTIAL
	var tag: String = "residential"
	var density: float = 1.0
	var height_mult: float = 1.0
	var footprint_mult: float = 1.0
	var neon_primary: Color = Color(1.0, 0.0, 0.8)
	var neon_secondary: Color = Color(0.0, 0.8, 1.0)
	var street_light_color: Color = Color(1.0, 0.5, 0.2)
	var window_warmth: float = 0.5
	var sky_bridge_bias: float = 0.5
	var billboard_bias: float = 0.3
	var rain_noise_bias: float = 1.0
	var style_weights: Dictionary = {}  # {BuildingFactory.Style: weight}
	var interior_palette: Array = []    # Array[Color] for InteriorMappingMaterial

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	if _seed_positions.is_empty():
		build()


func _init() -> void:
	_build_archetype_cache()


## Rebuild the full district partition. Safe to call multiple times.
func build() -> void:
	if district_count < 2:
		district_count = 2
	_rng.seed = planner_seed if planner_seed != 0 else int(Time.get_ticks_usec())
	_seed_positions.clear()
	_seed_types.clear()
	_seed_weights.clear()
	_classify_cache.clear()
	_scatter_seeds()
	_assign_archetypes()


# ── Seed scattering ──────────────────────────────────────────────────────────

func _scatter_seeds() -> void:
	var attempts_per_seed: int = 48
	var half: float = city_half_extent

	# Optional: downtown forced at the centre.
	if force_downtown_center:
		_seed_positions.append(Vector2.ZERO)
		_seed_types.append(DistrictType.DOWNTOWN)
		_seed_weights.append(1.6)

	# Sample the remaining seeds with Poisson-style rejection to keep separation.
	while _seed_positions.size() < district_count:
		var placed: bool = false
		for _attempt in range(attempts_per_seed):
			var candidate := Vector2(
				_rng.randf_range(-half, half),
				_rng.randf_range(-half, half),
			)
			var ok: bool = true
			for existing in _seed_positions:
				if candidate.distance_to(existing) < min_seed_separation:
					ok = false
					break
			if ok:
				_seed_positions.append(candidate)
				_seed_types.append(DistrictType.RESIDENTIAL)  # placeholder, assigned later
				_seed_weights.append(_rng.randf_range(0.7, 1.3))
				placed = true
				break
		if not placed:
			# Ran out of attempts — shrink separation requirement and try once more.
			min_seed_separation = max(40.0, min_seed_separation * 0.85)


# ── Archetype assignment ─────────────────────────────────────────────────────

func _assign_archetypes() -> void:
	# Build a weighted archetype pool with approximate target frequencies.
	# Frequencies are tuned to feel like a believable mega-city skyline.
	var pool: Array[int] = []
	var target_counts: Dictionary = {
		DistrictType.DOWNTOWN:      max(1, int(district_count * 0.10)),
		DistrictType.CORPORATE:     max(1, int(district_count * 0.18)),
		DistrictType.RESIDENTIAL:   max(1, int(district_count * 0.28)),
		DistrictType.INDUSTRIAL:    max(1, int(district_count * 0.14)),
		DistrictType.SLUMS:         max(1, int(district_count * 0.14)),
		DistrictType.ENTERTAINMENT: max(1, int(district_count * 0.10)),
		DistrictType.WATERFRONT:    max(0, int(district_count * 0.06)),
	}

	for arch in target_counts.keys():
		for _i in range(target_counts[arch]):
			pool.append(arch)

	# Top up / trim to exact seed count.
	while pool.size() < _seed_positions.size():
		pool.append(DistrictType.RESIDENTIAL)
	while pool.size() > _seed_positions.size():
		pool.pop_back()

	# Place DOWNTOWN tightly towards the centre when present.
	pool.shuffle()

	# Sort seed indices by distance from origin so outer rings get outskirt-
	# biased archetypes when radial_bias_enabled is true.
	var indices: Array[int] = []
	for i in range(_seed_positions.size()):
		indices.append(i)

	if radial_bias_enabled:
		indices.sort_custom(func(a: int, b: int) -> bool:
			return _seed_positions[a].length_squared() < _seed_positions[b].length_squared()
		)
		pool.sort_custom(func(a: int, b: int) -> bool:
			return _radial_preference(a) < _radial_preference(b)
		)

	# Assign: forced downtown seed at index 0 stays DOWNTOWN when enabled.
	for slot in range(indices.size()):
		var seed_idx: int = indices[slot]
		if force_downtown_center and seed_idx == 0:
			_seed_types[seed_idx] = DistrictType.DOWNTOWN
			_seed_weights[seed_idx] = 1.7
			continue
		_seed_types[seed_idx] = pool[slot] if slot < pool.size() else DistrictType.RESIDENTIAL
		_seed_weights[seed_idx] = _weight_for_type(_seed_types[seed_idx])


## Lower preference value ⇒ closer to the centre.
func _radial_preference(archetype: int) -> float:
	match archetype:
		DistrictType.DOWNTOWN:      return 0.0
		DistrictType.CORPORATE:     return 0.2
		DistrictType.ENTERTAINMENT: return 0.35
		DistrictType.RESIDENTIAL:   return 0.55
		DistrictType.INDUSTRIAL:    return 0.8
		DistrictType.SLUMS:         return 0.85
		DistrictType.WATERFRONT:    return 0.95
	return 0.5


func _weight_for_type(t: int) -> float:
	match t:
		DistrictType.DOWNTOWN:      return 1.7
		DistrictType.CORPORATE:     return 1.25
		DistrictType.ENTERTAINMENT: return 1.1
		DistrictType.RESIDENTIAL:   return 1.0
		DistrictType.INDUSTRIAL:    return 0.9
		DistrictType.SLUMS:         return 0.8
		DistrictType.WATERFRONT:    return 0.6
	return 1.0


# ── Public query API ─────────────────────────────────────────────────────────

## Classify a world-space XZ point into a DistrictInfo snapshot.
## Thread-safe? No — call from the main thread only.
func classify_point(world_pos: Vector3) -> DistrictInfo:
	var key: Vector2i = Vector2i(
		int(floor(world_pos.x / _classify_cache_cell)),
		int(floor(world_pos.z / _classify_cache_cell)),
	)
	if _classify_cache.has(key):
		return _classify_cache[key]

	var p := Vector2(world_pos.x, world_pos.z)
	var best_idx: int = 0
	var best_score: float = INF
	for i in range(_seed_positions.size()):
		var d: float = p.distance_to(_seed_positions[i])
		# Weighted Voronoi: higher weight ⇒ smaller effective distance.
		var w: float = lerp(1.0, _seed_weights[i], weight_bias)
		var score: float = d / max(0.001, w)
		if score < best_score:
			best_score = score
			best_idx = i

	var info := _archetype_info(_seed_types[best_idx])

	# Smoothly vary properties within a district so buildings near edges blend.
	var dist_norm: float = clamp(best_score / max(1.0, city_half_extent * 0.25), 0.0, 1.0)
	info.height_mult = info.height_mult * lerp(1.0, 0.85, dist_norm * 0.4)
	info.density     = info.density     * lerp(1.0, 0.9,  dist_norm * 0.3)

	# Cache bounded.
	if _classify_cache.size() < _classify_cache_limit:
		_classify_cache[key] = info
	return info


## Return an array of {pos: Vector2, type: int} snapshots for debug overlays.
func get_seed_snapshots() -> Array:
	var out: Array = []
	for i in range(_seed_positions.size()):
		out.append({
			"pos": _seed_positions[i],
			"type": _seed_types[i],
			"weight": _seed_weights[i],
			"tag": DISTRICT_TAGS[_seed_types[i]],
		})
	return out


## True if a world-space XZ point is inside the city footprint.
func is_in_city_bounds(world_pos: Vector3) -> bool:
	return abs(world_pos.x) <= city_half_extent and abs(world_pos.z) <= city_half_extent


# ── Archetype presentation cache ─────────────────────────────────────────────

func _build_archetype_cache() -> void:
	_archetype_cache[DistrictType.DOWNTOWN] = {
		"tag": "downtown",
		"density": 1.6,
		"height_mult": 1.8,
		"footprint_mult": 0.85,
		"neon_primary": Color(0.0, 0.8, 1.0),
		"neon_secondary": Color(1.0, 0.0, 0.8),
		"street_light_color": Color(0.2, 0.8, 1.0),
		"window_warmth": 0.35,
		"sky_bridge_bias": 1.0,
		"billboard_bias": 0.9,
		"rain_noise_bias": 1.0,
		"style_weights": {
			"MEGASPIRE": 0.45,
			"GLASS_TOWER": 0.3,
			"STEPPED_ZIGGURAT": 0.15,
			"DATA_STACK": 0.1,
		},
		"interior_palette": [
			Color(0.02, 0.10, 0.18),
			Color(0.05, 0.15, 0.25),
			Color(0.10, 0.08, 0.20),
		],
	}
	_archetype_cache[DistrictType.CORPORATE] = {
		"tag": "corporate",
		"density": 1.3,
		"height_mult": 1.4,
		"footprint_mult": 1.0,
		"neon_primary": Color(0.3, 0.9, 1.0),
		"neon_secondary": Color(0.8, 0.8, 1.0),
		"street_light_color": Color(0.6, 0.8, 1.0),
		"window_warmth": 0.25,
		"sky_bridge_bias": 0.75,
		"billboard_bias": 0.45,
		"rain_noise_bias": 0.9,
		"style_weights": {
			"GLASS_TOWER": 0.55,
			"MEGASPIRE": 0.2,
			"STEPPED_ZIGGURAT": 0.15,
			"BLOCK_TOWER": 0.1,
		},
		"interior_palette": [
			Color(0.05, 0.12, 0.18),
			Color(0.10, 0.15, 0.22),
			Color(0.08, 0.18, 0.20),
		],
	}
	_archetype_cache[DistrictType.RESIDENTIAL] = {
		"tag": "residential",
		"density": 1.0,
		"height_mult": 0.8,
		"footprint_mult": 1.1,
		"neon_primary": Color(1.0, 0.5, 0.3),
		"neon_secondary": Color(0.3, 0.8, 1.0),
		"street_light_color": Color(1.0, 0.6, 0.3),
		"window_warmth": 0.85,
		"sky_bridge_bias": 0.35,
		"billboard_bias": 0.2,
		"rain_noise_bias": 0.85,
		"style_weights": {
			"BLOCK_TOWER": 0.5,
			"STEPPED_ZIGGURAT": 0.25,
			"GLASS_TOWER": 0.15,
			"DATA_STACK": 0.1,
		},
		"interior_palette": [
			Color(0.20, 0.12, 0.05),
			Color(0.25, 0.15, 0.08),
			Color(0.18, 0.10, 0.04),
			Color(0.22, 0.18, 0.10),
		],
	}
	_archetype_cache[DistrictType.INDUSTRIAL] = {
		"tag": "industrial",
		"density": 0.7,
		"height_mult": 0.45,
		"footprint_mult": 1.5,
		"neon_primary": Color(1.0, 0.6, 0.0),
		"neon_secondary": Color(1.0, 0.25, 0.0),
		"street_light_color": Color(1.0, 0.5, 0.15),
		"window_warmth": 0.75,
		"sky_bridge_bias": 0.15,
		"billboard_bias": 0.15,
		"rain_noise_bias": 0.7,
		"style_weights": {
			"DATA_STACK": 0.4,
			"BLOCK_TOWER": 0.4,
			"STEPPED_ZIGGURAT": 0.15,
			"GLASS_TOWER": 0.05,
		},
		"interior_palette": [
			Color(0.25, 0.15, 0.04),
			Color(0.18, 0.10, 0.02),
			Color(0.14, 0.08, 0.02),
		],
	}
	_archetype_cache[DistrictType.SLUMS] = {
		"tag": "slums",
		"density": 1.3,
		"height_mult": 0.5,
		"footprint_mult": 1.2,
		"neon_primary": Color(1.0, 0.1, 0.6),
		"neon_secondary": Color(0.9, 0.7, 0.1),
		"street_light_color": Color(1.0, 0.25, 0.4),
		"window_warmth": 0.9,
		"sky_bridge_bias": 0.25,
		"billboard_bias": 0.6,
		"rain_noise_bias": 1.1,
		"style_weights": {
			"DATA_STACK": 0.55,
			"BLOCK_TOWER": 0.3,
			"STEPPED_ZIGGURAT": 0.1,
			"GLASS_TOWER": 0.05,
		},
		"interior_palette": [
			Color(0.22, 0.08, 0.12),
			Color(0.18, 0.06, 0.04),
			Color(0.25, 0.18, 0.05),
			Color(0.15, 0.04, 0.20),
		],
	}
	_archetype_cache[DistrictType.ENTERTAINMENT] = {
		"tag": "entertainment",
		"density": 1.15,
		"height_mult": 0.9,
		"footprint_mult": 1.0,
		"neon_primary": Color(1.0, 0.0, 0.8),
		"neon_secondary": Color(0.0, 1.0, 0.8),
		"street_light_color": Color(1.0, 0.2, 0.8),
		"window_warmth": 0.55,
		"sky_bridge_bias": 0.5,
		"billboard_bias": 1.0,
		"rain_noise_bias": 0.95,
		"style_weights": {
			"BLOCK_TOWER": 0.35,
			"STEPPED_ZIGGURAT": 0.25,
			"GLASS_TOWER": 0.2,
			"MEGASPIRE": 0.1,
			"DATA_STACK": 0.1,
		},
		"interior_palette": [
			Color(0.30, 0.05, 0.30),
			Color(0.05, 0.30, 0.25),
			Color(0.40, 0.20, 0.05),
		],
	}
	_archetype_cache[DistrictType.WATERFRONT] = {
		"tag": "waterfront",
		"density": 0.4,
		"height_mult": 0.55,
		"footprint_mult": 0.9,
		"neon_primary": Color(0.2, 0.7, 1.0),
		"neon_secondary": Color(0.8, 0.9, 1.0),
		"street_light_color": Color(0.6, 0.9, 1.0),
		"window_warmth": 0.3,
		"sky_bridge_bias": 0.1,
		"billboard_bias": 0.1,
		"rain_noise_bias": 1.3,
		"style_weights": {
			"GLASS_TOWER": 0.55,
			"BLOCK_TOWER": 0.25,
			"STEPPED_ZIGGURAT": 0.15,
			"DATA_STACK": 0.05,
		},
		"interior_palette": [
			Color(0.05, 0.15, 0.22),
			Color(0.08, 0.18, 0.28),
			Color(0.04, 0.10, 0.18),
		],
	}


func _archetype_info(archetype: int) -> DistrictInfo:
	var data: Dictionary = _archetype_cache.get(archetype, _archetype_cache[DistrictType.RESIDENTIAL])
	var info := DistrictInfo.new()
	info.type = archetype
	info.tag = data["tag"]
	info.density = data["density"]
	info.height_mult = data["height_mult"]
	info.footprint_mult = data["footprint_mult"]
	info.neon_primary = data["neon_primary"]
	info.neon_secondary = data["neon_secondary"]
	info.street_light_color = data["street_light_color"]
	info.window_warmth = data["window_warmth"]
	info.sky_bridge_bias = data["sky_bridge_bias"]
	info.billboard_bias = data["billboard_bias"]
	info.rain_noise_bias = data["rain_noise_bias"]
	info.style_weights = (data["style_weights"] as Dictionary).duplicate()
	info.interior_palette = (data["interior_palette"] as Array).duplicate()
	return info


# ── Utility helpers consumed by other modules ────────────────────────────────

## Pick a weighted style string from a DistrictInfo. Accepts a local RNG so
## callers can keep their own deterministic stream.
static func pick_style(info: DistrictInfo, rng: RandomNumberGenerator) -> String:
	var total: float = 0.0
	for v in info.style_weights.values():
		total += float(v)
	if total <= 0.0:
		return "BLOCK_TOWER"
	var roll: float = rng.randf() * total
	var cum: float = 0.0
	for k in info.style_weights.keys():
		cum += float(info.style_weights[k])
		if roll <= cum:
			return String(k)
	return String(info.style_weights.keys()[0])


## Blend two colors using HSV to avoid muddy results — useful when sampling
## neon colour for a facade near a district boundary.
static func blend_neon(a: Color, b: Color, t: float) -> Color:
	var ha: Vector3 = Vector3(a.h, a.s, a.v)
	var hb: Vector3 = Vector3(b.h, b.s, b.v)
	# Hue shortest path.
	var dh: float = hb.x - ha.x
	if dh > 0.5: dh -= 1.0
	elif dh < -0.5: dh += 1.0
	var h: float = fposmod(ha.x + dh * t, 1.0)
	var s: float = lerp(ha.y, hb.y, t)
	var v: float = lerp(ha.z, hb.z, t)
	var c := Color.from_hsv(h, s, v)
	c.a = lerp(a.a, b.a, t)
	return c


## Return a textual dump suitable for editor debug prints.
func debug_dump() -> String:
	var lines: Array[String] = []
	lines.append("DistrictPlanner: %d seeds, half_extent=%.1f" % [
		_seed_positions.size(), city_half_extent,
	])
	for i in range(_seed_positions.size()):
		var pos: Vector2 = _seed_positions[i]
		lines.append("  [%d] %-12s at (%6.1f,%6.1f) w=%.2f" % [
			i,
			DISTRICT_TAGS[_seed_types[i]],
			pos.x, pos.y,
			_seed_weights[i],
		])
	return "\n".join(lines)
