## InteriorMappingMaterial — Runtime Factory For The Interior-Mapping Shader
##
## The existing `res://materials/interior_mapping.gdshader` implements the
## fake-interior technique used by every neon window in the city. This helper
## wraps that shader into per-building `ShaderMaterial` instances with the
## correct uniforms derived from a DistrictInfo and a couple of local
## parameters. It also owns a tiny cache so identical configurations share a
## single material — critical for draw-call batching on WebGL where every
## unique material breaks instancing.
##
## The factory is a pure helper; it owns no nodes and never touches the scene
## tree. It can therefore be created on the client OR the server (the server
## can be asked to produce a deterministic material hash for lockstep
## validation).
##
## Typical usage from BuildingFactory:
##
##     var mat := InteriorMappingMaterial.build_for_building(
##         district_info,
##         building_rng,
##         height,
##         window_columns,
##         window_rows,
##     )
##     mesh_inst.material_override = mat
##
## Uniform names must match `materials/interior_mapping.gdshader`.

class_name InteriorMappingMaterial
extends RefCounted

# ── Configuration constants ──────────────────────────────────────────────────

const SHADER_PATH: String = "res://materials/interior_mapping.gdshader"

## How many fundamental variants to cache before flushing. Keeping this modest
## trades a bit of GPU RAM for far fewer unique materials (better batching).
const CACHE_LIMIT: int = 128

## The default column / row counts when a building does not override them.
const DEFAULT_WINDOW_COLUMNS: int = 6
const DEFAULT_WINDOW_ROWS: int = 10

## Minimum / maximum window sizes picked procedurally.
const MIN_WINDOW_COLUMNS: int = 3
const MAX_WINDOW_COLUMNS: int = 14
const MIN_WINDOW_ROWS: int = 4
const MAX_WINDOW_ROWS: int = 24

# ── Internal ─────────────────────────────────────────────────────────────────

static var _shader: Shader = null
static var _cache: Dictionary = {}
static var _cache_stats: Dictionary = {
	"hits": 0,
	"misses": 0,
	"evictions": 0,
}


# ── Public API ───────────────────────────────────────────────────────────────

## Produce (or reuse) a ShaderMaterial for a building. The returned material
## MUST be treated as read-only by callers — tweaking it would affect every
## other building sharing the same variant.
static func build_for_building(
		info,                                 # DistrictPlanner.DistrictInfo (untyped for cross-module use)
		rng: RandomNumberGenerator,
		building_height: float,
		window_columns: int = -1,
		window_rows: int = -1,
	) -> ShaderMaterial:

	# Derive window grid from height when not explicitly supplied.
	var cols: int = window_columns
	var rows: int = window_rows
	if cols < 0:
		cols = int(clamp(
			round(DEFAULT_WINDOW_COLUMNS * info.footprint_mult),
			MIN_WINDOW_COLUMNS,
			MAX_WINDOW_COLUMNS
		))
	if rows < 0:
		rows = int(clamp(
			round(building_height / 4.0),
			MIN_WINDOW_ROWS,
			MAX_WINDOW_ROWS
		))

	# Pick room colour from the district's interior palette.
	var palette: Array = info.interior_palette
	var room_color: Color = Color(0.1, 0.1, 0.15)
	if palette.size() > 0:
		room_color = palette[rng.randi_range(0, palette.size() - 1)]

	# Slight per-building jitter on colours and emissive strength.
	var warmth: float = info.window_warmth
	var emissive_boost: float = rng.randf_range(0.85, 1.25)
	var neon_primary: Color = info.neon_primary
	var neon_secondary: Color = info.neon_secondary
	var neon_edge_color: Color = neon_primary if rng.randf() < 0.5 else neon_secondary
	var neon_edge_str: float = rng.randf_range(3.5, 7.5) * emissive_boost

	var facade_color: Color = _pick_facade_color(info.tag, rng)
	var frame_color: Color = facade_color * 1.7
	frame_color.a = 1.0

	# Cache key: coarse-grained to maximise reuse.
	var key := _cache_key(info.tag, cols, rows, room_color, neon_edge_color)
	if _cache.has(key):
		_cache_stats["hits"] += 1
		return _cache[key]
	_cache_stats["misses"] += 1

	var shader := _get_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader

	# Required uniforms.
	mat.set_shader_parameter("window_columns", cols)
	mat.set_shader_parameter("window_rows", rows)
	mat.set_shader_parameter("window_gap", rng.randf_range(0.04, 0.09))
	mat.set_shader_parameter("window_depth", rng.randf_range(1.1, 2.6))

	# Facade / frame / neon trim.
	mat.set_shader_parameter("facade_color", facade_color)
	mat.set_shader_parameter("frame_color", frame_color)
	mat.set_shader_parameter("neon_edge_color", neon_edge_color)
	mat.set_shader_parameter("neon_edge_str", neon_edge_str)

	# Interior room fallback (procedural, no atlas).
	mat.set_shader_parameter("use_atlas", false)
	mat.set_shader_parameter("atlas_columns", 4)
	mat.set_shader_parameter("room_tint", _apply_warmth(room_color, warmth))
	mat.set_shader_parameter("room_ambient", Color(0.02, 0.02, 0.04) * 1.0)
	mat.set_shader_parameter("room_emissive_strength", 1.0 + warmth * 1.5)

	# Animation seeds for per-building uniqueness (shader reads these for
	# random-but-stable window flicker / blinds-closed probability).
	mat.set_shader_parameter("random_seed", rng.randf_range(0.0, 1000.0))
	mat.set_shader_parameter("lit_probability", _district_lit_probability(info.tag))

	_remember(key, mat)
	return mat


## Build a dedicated material for a billboard face. Billboards share the
## shader but invert a couple of uniforms to produce a super-bright, always-on
## neon surface rather than a window grid.
static func build_for_billboard(
		info,
		rng: RandomNumberGenerator,
		width_cells: int = 8,
	) -> ShaderMaterial:

	var shader := _get_shader()
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("window_columns", width_cells)
	mat.set_shader_parameter("window_rows", 4)
	mat.set_shader_parameter("window_gap", 0.02)
	mat.set_shader_parameter("window_depth", 0.4)
	mat.set_shader_parameter("facade_color", Color(0.01, 0.01, 0.02, 1.0))
	mat.set_shader_parameter("frame_color", Color(0.05, 0.05, 0.08, 1.0))
	mat.set_shader_parameter("neon_edge_color", info.neon_primary)
	mat.set_shader_parameter("neon_edge_str", rng.randf_range(9.0, 16.0))
	mat.set_shader_parameter("use_atlas", false)
	mat.set_shader_parameter("atlas_columns", 4)
	mat.set_shader_parameter("room_tint", info.neon_secondary * 2.0)
	mat.set_shader_parameter("room_ambient", Color(0.05, 0.05, 0.08))
	mat.set_shader_parameter("room_emissive_strength", 3.5)
	mat.set_shader_parameter("random_seed", rng.randf_range(0.0, 1000.0))
	mat.set_shader_parameter("lit_probability", 1.0)
	return mat


## Flush the internal cache — e.g. between scene loads or when memory pressure
## is detected on a low-end device.
static func flush_cache() -> void:
	_cache_stats["evictions"] += _cache.size()
	_cache.clear()


## Return usage statistics for profiling overlays.
static func stats() -> Dictionary:
	return {
		"cache_size": _cache.size(),
		"hits": _cache_stats["hits"],
		"misses": _cache_stats["misses"],
		"evictions": _cache_stats["evictions"],
	}


# ── Internal helpers ─────────────────────────────────────────────────────────

static func _get_shader() -> Shader:
	if _shader == null:
		_shader = load(SHADER_PATH) as Shader
	return _shader


static func _cache_key(
		tag: String,
		cols: int,
		rows: int,
		room: Color,
		neon: Color,
	) -> String:
	# Quantise colours to 5 bits/channel so mildly different buildings reuse
	# the same material.
	return "%s|%d|%d|%d|%d|%d|%d|%d" % [
		tag, cols, rows,
		int(room.r * 32), int(room.g * 32), int(room.b * 32),
		int(neon.r * 32), int(neon.g * 32),
	]


static func _remember(key: String, mat: ShaderMaterial) -> void:
	if _cache.size() >= CACHE_LIMIT:
		# Drop a random key to keep total bounded. This is cheaper than LRU
		# tracking and good enough for a city of tens of thousands of windows
		# where the hit rate is dominated by a small set of variants.
		var k = _cache.keys()[0]
		_cache.erase(k)
		_cache_stats["evictions"] += 1
	_cache[key] = mat


static func _pick_facade_color(tag: String, rng: RandomNumberGenerator) -> Color:
	match tag:
		"downtown":
			return Color(0.02, 0.03, 0.06)
		"corporate":
			return Color(0.04, 0.06, 0.09)
		"residential":
			return Color(0.08, 0.06, 0.05)
		"industrial":
			return Color(0.05, 0.04, 0.03) * rng.randf_range(0.9, 1.15)
		"slums":
			return Color(0.07, 0.05, 0.05) * rng.randf_range(0.85, 1.1)
		"entertainment":
			return Color(0.03, 0.02, 0.04)
		"waterfront":
			return Color(0.03, 0.05, 0.08)
	return Color(0.05, 0.05, 0.08)


static func _apply_warmth(c: Color, warmth: float) -> Color:
	# Shift colour towards amber when warmth is high, towards cyan when low.
	var warm := Color(1.0, 0.75, 0.4)
	var cool := Color(0.4, 0.75, 1.0)
	var bias := warm.lerp(cool, 1.0 - clamp(warmth, 0.0, 1.0))
	var r := c.r * (0.5 + 0.5 * bias.r)
	var g := c.g * (0.5 + 0.5 * bias.g)
	var b := c.b * (0.5 + 0.5 * bias.b)
	return Color(r, g, b, 1.0)


static func _district_lit_probability(tag: String) -> float:
	match tag:
		"downtown":      return 0.78
		"corporate":     return 0.55
		"residential":   return 0.65
		"industrial":    return 0.30
		"slums":         return 0.72
		"entertainment": return 0.90
		"waterfront":    return 0.40
	return 0.60
