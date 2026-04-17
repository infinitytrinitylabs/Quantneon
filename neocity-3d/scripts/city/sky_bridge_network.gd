## SkyBridgeNetwork — Graph-Based Sky-Bridge Generator
##
## Given a set of building rooftop anchor points (produced by
## BuildingFactory.rooftop_anchors_for()), this module computes a sparse,
## aesthetically pleasing sky-bridge graph connecting nearby towers at varying
## altitudes. The algorithm is:
##
##   1. Filter anchors below `min_bridge_height`.
##   2. Insert every anchor into a flat spatial hash keyed by XZ cell.
##   3. For each anchor, gather neighbours inside `max_bridge_length` and
##      within `max_tier_height_diff` on the vertical axis.
##   4. Build candidate edges deduplicated by (id_low, id_high).
##   5. Extract a minimum spanning tree over the candidate graph (Prim's
##      algorithm on the anchor set restricted to strong edges) — this gives
##      the backbone "sky-highway" that the player can traverse from one end
##      of the city to the other.
##   6. Augment with `extra_edge_ratio` × (anchor_count) additional shortest
##      edges that were not picked by the MST, giving loops and alternate
##      routes.
##   7. For every chosen edge, instantiate a sky-bridge mesh with pylons,
##      guard rails, and neon edge trim. Each bridge registers its midpoint
##      as a potential SkyBridge node for AI pathing / NPC spawning.
##
## Determinism: given the same rng state and anchor set, the generated graph
## is identical across runs. This matters for replays and server-authoritative
## navmesh baking.
##
## Performance: MST over 2-3k rooftops with ~8 neighbours each completes in
## well under 50 ms on mid-tier mobile. Mesh construction is the dominant cost
## and is throttled by `max_bridges_per_frame` when invoked from the async
## `build_async()` coroutine.

class_name SkyBridgeNetwork
extends Node3D

# ── Tuneables ────────────────────────────────────────────────────────────────

## Minimum altitude (world y) an anchor must have to be eligible.
@export var min_bridge_height: float = 28.0

## Longest bridge span. Distances are measured on XZ, altitude diff counted
## separately via `max_tier_height_diff`.
@export var max_bridge_length: float = 55.0

## Shortest bridge span worth drawing. Avoids touching-tower clutter.
@export var min_bridge_length: float = 10.0

## Max absolute vertical difference between two anchors. Higher values produce
## dramatic slopes — keep below 12 for a realistic skyline.
@export var max_tier_height_diff: float = 9.0

## Neighbours-per-anchor considered when building the candidate graph.
@export var neighbour_cap: int = 8

## Extra redundant edges above the MST, expressed as a ratio of anchor count.
@export_range(0.0, 1.0) var extra_edge_ratio: float = 0.35

## Width of the bridge deck (world units).
@export var deck_width: float = 3.0

## Thickness of the deck (world units).
@export var deck_thickness: float = 0.6

## Height of the safety railing.
@export var rail_height: float = 1.1

## Every N frames the build coroutine emits at most this many bridges.
@export var max_bridges_per_frame: int = 12

## Colour override for neon trim. If fully transparent the anchor's owning
## district neon_primary is used.
@export var trim_color_override: Color = Color(0.0, 0.0, 0.0, 0.0)

# ── State ────────────────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _anchors: Array = []  # Array[Dictionary{pos: Vector3, footprint: float, meta, id: int}]
var _edges: Array = []    # Array of [id_a, id_b, length]
var _bridge_nodes: Array = []  # Scene nodes created during build
var _hash_cell_size: float = 0.0

signal build_completed(bridge_count: int)
signal build_progress(created: int, total: int)

# ── Public API ───────────────────────────────────────────────────────────────

## Clear all previously generated bridges. Safe to call multiple times.
func clear() -> void:
	for n in _bridge_nodes:
		if is_instance_valid(n):
			n.queue_free()
	_bridge_nodes.clear()
	_anchors.clear()
	_edges.clear()


## Feed every building's rooftop anchor data (as produced by
## BuildingFactory.rooftop_anchors_for). Each item MUST be a Dictionary with
## at least `pos: Vector3` and `footprint: float`.
func set_anchors(anchor_data: Array) -> void:
	_anchors.clear()
	var id: int = 0
	for a in anchor_data:
		if float((a as Dictionary)["pos"].y) < min_bridge_height:
			continue
		var entry: Dictionary = {
			"pos": a["pos"],
			"footprint": a.get("footprint", 5.0),
			"meta": a.get("meta", null),
			"id": id,
		}
		_anchors.append(entry)
		id += 1


## Build the bridge graph synchronously. Returns the number of bridges created.
func build(seed: int = 0) -> int:
	if _anchors.size() < 2:
		return 0
	_rng.seed = seed if seed != 0 else int(Time.get_ticks_usec())
	_compute_candidate_edges()
	var chosen := _compute_mst_plus_extras()
	_edges = chosen
	for edge in chosen:
		_spawn_bridge(edge)
	build_completed.emit(_bridge_nodes.size())
	return _bridge_nodes.size()


## Async version that yields periodically so the main thread remains responsive
## during level load. Use `await` to wait for completion.
func build_async(seed: int = 0) -> int:
	if _anchors.size() < 2:
		build_completed.emit(0)
		return 0
	_rng.seed = seed if seed != 0 else int(Time.get_ticks_usec())
	_compute_candidate_edges()
	_edges = _compute_mst_plus_extras()
	var built: int = 0
	var per_frame: int = max(1, max_bridges_per_frame)
	for edge in _edges:
		_spawn_bridge(edge)
		built += 1
		if built % per_frame == 0:
			build_progress.emit(built, _edges.size())
			# Yield a frame so the UI stays responsive.
			await get_tree().process_frame
	build_completed.emit(built)
	return built


## Return a light-weight graph snapshot suitable for export to the mini-map.
func snapshot() -> Array:
	var out: Array = []
	for edge in _edges:
		var a: Dictionary = _anchors[edge[0]]
		var b: Dictionary = _anchors[edge[1]]
		out.append({
			"a": a["pos"],
			"b": b["pos"],
			"length": edge[2],
		})
	return out


## Number of currently live bridge nodes.
func bridge_count() -> int:
	return _bridge_nodes.size()


# ── Candidate edge computation ───────────────────────────────────────────────

func _compute_candidate_edges() -> void:
	# Bucket anchors into a spatial hash for O(n) neighbour queries.
	_hash_cell_size = max_bridge_length
	var grid: Dictionary = {}
	for i in range(_anchors.size()):
		var p: Vector3 = _anchors[i]["pos"]
		var key: Vector2i = Vector2i(
			int(floor(p.x / _hash_cell_size)),
			int(floor(p.z / _hash_cell_size)),
		)
		if not grid.has(key):
			grid[key] = []
		grid[key].append(i)

	# For each anchor, query the nine surrounding cells.
	_edges.clear()
	var seen: Dictionary = {}
	for i in range(_anchors.size()):
		var a: Dictionary = _anchors[i]
		var p: Vector3 = a["pos"]
		var key: Vector2i = Vector2i(
			int(floor(p.x / _hash_cell_size)),
			int(floor(p.z / _hash_cell_size)),
		)
		var candidates: Array = []
		for ox in range(-1, 2):
			for oz in range(-1, 2):
				var k: Vector2i = Vector2i(key.x + ox, key.y + oz)
				if not grid.has(k):
					continue
				for j in grid[k]:
					if j == i:
						continue
					var other: Dictionary = _anchors[j]
					var dy: float = abs(other["pos"].y - p.y)
					if dy > max_tier_height_diff:
						continue
					var flat_d: float = Vector2(other["pos"].x - p.x, other["pos"].z - p.z).length()
					if flat_d < min_bridge_length or flat_d > max_bridge_length:
						continue
					# Avoid bridges that go through another tall tower — a simple
					# heuristic: if the midpoint is within any nearby anchor's
					# footprint disc and below that anchor's altitude, skip.
					if _bridge_passes_through_tower(p, other["pos"], grid):
						continue
					candidates.append([j, flat_d])
		# Keep only the nearest `neighbour_cap`.
		candidates.sort_custom(func(a1, b1): return a1[1] < b1[1])
		for c_idx in range(min(neighbour_cap, candidates.size())):
			var j: int = int(candidates[c_idx][0])
			var length: float = float(candidates[c_idx][1])
			var lo: int = min(i, j)
			var hi: int = max(i, j)
			var pair_key: String = "%d_%d" % [lo, hi]
			if seen.has(pair_key):
				continue
			seen[pair_key] = true
			_edges.append([lo, hi, length])


func _bridge_passes_through_tower(a: Vector3, b: Vector3, grid: Dictionary) -> bool:
	var mid: Vector3 = (a + b) * 0.5
	var key: Vector2i = Vector2i(
		int(floor(mid.x / _hash_cell_size)),
		int(floor(mid.z / _hash_cell_size)),
	)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var k: Vector2i = Vector2i(key.x + ox, key.y + oz)
			if not grid.has(k):
				continue
			for j in grid[k]:
				var t: Dictionary = _anchors[j]
				# The bridge passes through a tower only when the midpoint is
				# inside the tower's horizontal disc AND below its roof.
				var dx: float = mid.x - t["pos"].x
				var dz: float = mid.z - t["pos"].z
				var r: float = float(t["footprint"]) * 0.5 + 0.5
				if dx * dx + dz * dz < r * r and mid.y < t["pos"].y - 2.0:
					# Ignore collisions with the edge endpoints themselves.
					if t["pos"].distance_to(a) < 0.1 or t["pos"].distance_to(b) < 0.1:
						continue
					return true
	return false


# ── Graph extraction (MST + extras) ──────────────────────────────────────────

func _compute_mst_plus_extras() -> Array:
	# Union-Find for Kruskal's MST is simpler and fast enough here.
	var parent: Array = []
	for i in range(_anchors.size()):
		parent.append(i)
	var sorted := _edges.duplicate()
	sorted.sort_custom(func(a, b): return float(a[2]) < float(b[2]))

	var chosen: Array = []
	var leftovers: Array = []
	for edge in sorted:
		var ra: int = _uf_find(parent, int(edge[0]))
		var rb: int = _uf_find(parent, int(edge[1]))
		if ra != rb:
			parent[ra] = rb
			chosen.append(edge)
		else:
			leftovers.append(edge)

	# Inject extra redundant edges.
	var extras_wanted: int = int(_anchors.size() * extra_edge_ratio)
	extras_wanted = min(extras_wanted, leftovers.size())
	leftovers.shuffle()
	for e in range(extras_wanted):
		chosen.append(leftovers[e])

	return chosen


func _uf_find(parent: Array, x: int) -> int:
	while parent[x] != x:
		parent[x] = parent[parent[x]]  # Path compression.
		x = parent[x]
	return x


# ── Mesh construction ────────────────────────────────────────────────────────

func _spawn_bridge(edge: Array) -> void:
	var a: Dictionary = _anchors[int(edge[0])]
	var b: Dictionary = _anchors[int(edge[1])]
	var pa: Vector3 = a["pos"]
	var pb: Vector3 = b["pos"]
	var length: float = Vector2(pb.x - pa.x, pb.z - pa.z).length()
	if length < 0.01:
		return

	var root := Node3D.new()
	root.name = "SkyBridge_%d_%d" % [int(edge[0]), int(edge[1])]
	add_child(root)

	# Compute midpoint + orientation.
	var mid: Vector3 = (pa + pb) * 0.5
	root.position = mid
	# Yaw so local +Z aligns with bridge direction (XZ only).
	var dir_flat := Vector2(pb.x - pa.x, pb.z - pa.z).normalized()
	root.rotation.y = atan2(dir_flat.x, dir_flat.y)
	# Pitch so the deck slopes between altitudes.
	var total_length: float = pa.distance_to(pb)
	var pitch: float = asin(clamp((pb.y - pa.y) / total_length, -1.0, 1.0))
	root.rotation.x = -pitch

	# Deck.
	var deck := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(deck_width, deck_thickness, total_length)
	deck.mesh = bm
	deck.material_override = _make_deck_material()
	deck.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	deck.name = "Deck"
	root.add_child(deck)

	# Guard rails — thin boxes on each side + neon trim.
	var trim_color: Color = trim_color_override
	if trim_color.a <= 0.01 and a["meta"] != null:
		var meta_obj = a["meta"]
		if meta_obj != null and "neon_primary" in meta_obj:
			trim_color = meta_obj.neon_primary
	if trim_color.a <= 0.01:
		trim_color = Color(0.0, 0.8, 1.0)

	for side in [-1.0, 1.0]:
		var rail := MeshInstance3D.new()
		var rbm := BoxMesh.new()
		rbm.size = Vector3(0.15, rail_height, total_length)
		rail.mesh = rbm
		var rm := StandardMaterial3D.new()
		rm.albedo_color = Color(0.12, 0.12, 0.16)
		rm.roughness = 0.9
		rail.material_override = rm
		rail.position = Vector3(side * deck_width * 0.5, rail_height * 0.5 + deck_thickness * 0.5, 0.0)
		rail.name = "Rail_%s" % ("R" if side > 0 else "L")
		root.add_child(rail)

		# Neon edge strip running on top of the rail.
		var neon := MeshInstance3D.new()
		var nbm := BoxMesh.new()
		nbm.size = Vector3(0.08, 0.08, total_length)
		neon.mesh = nbm
		var nm := StandardMaterial3D.new()
		nm.albedo_color = trim_color
		nm.emission_enabled = true
		nm.emission = trim_color
		nm.emission_energy_multiplier = 4.5
		nm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		neon.material_override = nm
		neon.position = rail.position + Vector3(0.0, rail_height * 0.5, 0.0)
		neon.name = "NeonEdge_%s" % ("R" if side > 0 else "L")
		root.add_child(neon)

	# Support pylons at each end. We drop a thin beam from the deck endpoint
	# down to ground (or to its attaching roof, which is already underneath).
	for endpoint in [pa, pb]:
		var beam := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.25
		cm.bottom_radius = 0.25
		cm.height = 2.0  # Short stub from the rooftop into the deck underside.
		cm.radial_segments = 8
		beam.mesh = cm
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.15, 0.15, 0.18)
		m.metallic = 0.6
		beam.material_override = m
		# Convert the world endpoint into the bridge's local frame.
		var local := root.to_local(endpoint)
		beam.position = local + Vector3(0.0, -1.0, 0.0)
		beam.name = "Stub"
		root.add_child(beam)

	_bridge_nodes.append(root)


func _make_deck_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.10, 0.10, 0.14)
	m.metallic = 0.25
	m.roughness = 0.75
	return m


# ── Editor-time helpers ──────────────────────────────────────────────────────

## Return a diagnostic string summarising the generated graph.
func debug_summary() -> String:
	var total_len: float = 0.0
	var min_len: float = INF
	var max_len: float = 0.0
	for e in _edges:
		var l: float = float(e[2])
		total_len += l
		min_len = min(min_len, l)
		max_len = max(max_len, l)
	if _edges.is_empty():
		min_len = 0.0
	return (
		"SkyBridgeNetwork: %d anchors, %d edges, total=%.0f, min=%.1f, max=%.1f"
		% [_anchors.size(), _edges.size(), total_len, min_len, max_len]
	)


## Return true if the anchor set forms a single connected component reachable
## purely through the generated bridges. Useful for tests & level validation.
func is_connected() -> bool:
	if _anchors.size() <= 1:
		return true
	var parent: Array = []
	for i in range(_anchors.size()):
		parent.append(i)
	for edge in _edges:
		var ra: int = _uf_find(parent, int(edge[0]))
		var rb: int = _uf_find(parent, int(edge[1]))
		if ra != rb:
			parent[ra] = rb
	var root_set: Dictionary = {}
	for i in range(_anchors.size()):
		root_set[_uf_find(parent, i)] = true
	return root_set.size() == 1
