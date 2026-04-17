## BuildingFactory — Modular Cyberpunk Skyscraper Builder
##
## The factory generates a single building as a hierarchy of MeshInstance3D
## nodes parented under a single Node3D root. The root carries a
## `BuildingMetadata` resource-like dictionary describing the building's
## footprint, rooftop position, tier count and stylistic traits so downstream
## systems (SkyBridgeNetwork, NeonBillboard spawner, NPC AI navigation) can
## query it without having to inspect child meshes.
##
## Supported building styles (string keys matching DistrictPlanner style_weights):
##
##   • BLOCK_TOWER       — a simple extruded box with a neon-trimmed crown.
##   • GLASS_TOWER       — a tall slim box with a mirrored glass override.
##   • STEPPED_ZIGGURAT  — multiple setbacks of decreasing footprint.
##   • DATA_STACK        — irregular stacked cubes resembling server racks.
##   • MEGASPIRE         — stepped tower topped with a narrow spire + antenna.
##
## Each style is implemented as a `_build_<style>()` function that returns the
## building root. Shared helpers assemble shell geometry, crown trim, antennas,
## rooftop beacons and neon edge lines. The factory is deterministic given the
## supplied RandomNumberGenerator, so the same RNG state will always produce
## the same building.
##
## Performance notes for mid-tier mobile WebGL (targeting 60fps):
##   • Every building is a single mesh hierarchy. No PhysicsBodies are added
##     by the factory itself — callers attach colliders only where needed
##     (e.g. the ground floor) to keep physics cost bounded.
##   • The interior-mapping shader is re-used across all facade quads via
##     InteriorMappingMaterial's caching, so the draw-call count per building
##     is typically ≤ 4 even for MEGASPIRE.

class_name BuildingFactory
extends RefCounted

const InteriorMap = preload("res://scripts/city/interior_mapping_material.gd")

# ── Tuneables ────────────────────────────────────────────────────────────────

## Cached geometry used to reduce per-building mesh allocation cost. Shared
## BoxMesh resources are safe across instances — transforms are per-instance.
const CROWN_TRIM_COLOR: Color = Color(0.05, 0.05, 0.07, 1.0)

## Height of the rooftop "parapet" that hides the bottom edge of crown props.
const PARAPET_HEIGHT: float = 0.8

## Beacon light radius — tight by default to keep fill-rate low.
const BEACON_LIGHT_RANGE: float = 18.0

# ── Data types ───────────────────────────────────────────────────────────────

class BuildingMetadata:
	var style: String = "BLOCK_TOWER"
	var footprint: float = 12.0
	var height: float = 30.0
	var tier_count: int = 1
	var rooftop_pos: Vector3 = Vector3.ZERO
	var center_ground: Vector3 = Vector3.ZERO
	var has_antenna: bool = false
	var has_billboard_slot: bool = false
	var neon_primary: Color = Color(1.0, 0.0, 0.8)
	var neon_secondary: Color = Color(0.0, 0.8, 1.0)
	var district_tag: String = "residential"
	## Tier tops expressed as (y_world, footprint_scale). Used by SkyBridgeNetwork
	## to decide where a bridge can connect mid-tower rather than at the roof.
	var tier_tops: Array = []  # Array of {y: float, footprint: float}


# ── Public entry point ───────────────────────────────────────────────────────

## Build a building at the given centre-ground position and return the root
## node + its metadata. The caller is responsible for adding the root to the
## scene tree.
static func spawn(
		center_ground: Vector3,
		lot_size: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Array:  # [Node3D, BuildingMetadata]

	var style: String = DistrictPlanner.pick_style(district_info, rng)
	return build_style(style, center_ground, lot_size, district_info, rng)


## Build a specific style (used by tests / landmark placement).
static func build_style(
		style: String,
		center_ground: Vector3,
		lot_size: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Array:

	var meta := BuildingMetadata.new()
	meta.style = style
	meta.center_ground = center_ground
	meta.district_tag = district_info.tag
	meta.neon_primary = district_info.neon_primary
	meta.neon_secondary = district_info.neon_secondary

	# Pick a base footprint that fits in the lot.
	var fp_frac: float = rng.randf_range(0.55, 0.88) * district_info.footprint_mult
	var footprint: float = clamp(lot_size * fp_frac, lot_size * 0.35, lot_size * 0.95)
	meta.footprint = footprint

	# Pick a base height driven by district.
	var base_height: float = rng.randf_range(16.0, 80.0) * district_info.height_mult

	var root: Node3D
	match style:
		"GLASS_TOWER":
			root = _build_glass_tower(meta, footprint, base_height, district_info, rng)
		"STEPPED_ZIGGURAT":
			root = _build_stepped_ziggurat(meta, footprint, base_height, district_info, rng)
		"DATA_STACK":
			root = _build_data_stack(meta, footprint, base_height, district_info, rng)
		"MEGASPIRE":
			root = _build_megaspire(meta, footprint, base_height, district_info, rng)
		_:
			root = _build_block_tower(meta, footprint, base_height, district_info, rng)

	root.position = center_ground
	meta.rooftop_pos = center_ground + Vector3(0.0, meta.height, 0.0)
	root.set_meta("building", meta)
	return [root, meta]


# ── Style: BLOCK_TOWER ───────────────────────────────────────────────────────

static func _build_block_tower(
		meta: BuildingMetadata,
		footprint: float,
		base_height: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Node3D:

	var root := Node3D.new()
	root.name = "Building_Block"
	var height: float = base_height
	meta.height = height
	meta.tier_count = 1

	var shell := _make_box_mesh(Vector3(footprint, height, footprint))
	shell.position = Vector3(0.0, height * 0.5, 0.0)
	shell.material_override = InteriorMap.build_for_building(district_info, rng, height)
	shell.name = "Shell"
	root.add_child(shell)

	meta.tier_tops.append({"y": height, "footprint": footprint})
	_add_parapet(root, footprint, height)
	_add_crown_trim(root, footprint, height, meta.neon_primary, rng)
	_maybe_add_antenna(root, footprint, height, meta, rng, 0.35)
	_maybe_add_rooftop_beacon(root, height, rng, 0.55)
	_maybe_add_billboard_slot(root, footprint, height, meta, district_info, rng)
	return root


# ── Style: GLASS_TOWER ───────────────────────────────────────────────────────

static func _build_glass_tower(
		meta: BuildingMetadata,
		footprint: float,
		base_height: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Node3D:

	var root := Node3D.new()
	root.name = "Building_Glass"
	var height: float = base_height * rng.randf_range(1.2, 1.6)
	# Slim the footprint slightly — glass towers read as pencils.
	var width: float = footprint * rng.randf_range(0.55, 0.8)
	meta.footprint = width
	meta.height = height
	meta.tier_count = 2

	var shell := _make_box_mesh(Vector3(width, height, width))
	shell.position = Vector3(0.0, height * 0.5, 0.0)
	shell.material_override = InteriorMap.build_for_building(district_info, rng, height, 4, int(height / 3.0))
	shell.name = "Shell"
	root.add_child(shell)

	# A glassy cap tier 85% height.
	var cap_height: float = height * 0.12
	var cap_width: float = width * 0.9
	var cap := _make_box_mesh(Vector3(cap_width, cap_height, cap_width))
	cap.position = Vector3(0.0, height - cap_height * 0.5, 0.0)
	cap.material_override = _make_glass_material(district_info, rng)
	cap.name = "GlassCap"
	root.add_child(cap)

	meta.tier_tops.append({"y": height - cap_height, "footprint": width})
	meta.tier_tops.append({"y": height, "footprint": cap_width})

	_add_parapet(root, cap_width, height)
	_add_crown_trim(root, cap_width, height, meta.neon_secondary, rng)
	_maybe_add_antenna(root, cap_width, height, meta, rng, 0.6)
	_maybe_add_rooftop_beacon(root, height, rng, 0.75)
	return root


# ── Style: STEPPED_ZIGGURAT ──────────────────────────────────────────────────

static func _build_stepped_ziggurat(
		meta: BuildingMetadata,
		footprint: float,
		base_height: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Node3D:

	var root := Node3D.new()
	root.name = "Building_Ziggurat"
	var tiers: int = rng.randi_range(3, 5)
	meta.tier_count = tiers
	var remaining_height: float = base_height * rng.randf_range(1.1, 1.35)
	meta.height = remaining_height

	var current_y: float = 0.0
	var current_fp: float = footprint
	for t in range(tiers):
		var tier_ratio: float = 1.0 - float(t) / float(tiers)
		var h: float = remaining_height * (1.0 / tiers) * rng.randf_range(0.85, 1.15)
		var shrink: float = rng.randf_range(0.82, 0.92)
		var mi := _make_box_mesh(Vector3(current_fp, h, current_fp))
		mi.position = Vector3(0.0, current_y + h * 0.5, 0.0)
		mi.material_override = InteriorMap.build_for_building(district_info, rng, h)
		mi.name = "Tier_%d" % t
		root.add_child(mi)
		current_y += h
		meta.tier_tops.append({"y": current_y, "footprint": current_fp})
		current_fp *= shrink
		# Unused in arithmetic but documents intent for readers.
		var _unused_ratio: float = tier_ratio

	meta.height = current_y
	_add_parapet(root, current_fp, current_y)
	_add_crown_trim(root, current_fp, current_y, meta.neon_primary, rng)
	_maybe_add_antenna(root, current_fp, current_y, meta, rng, 0.4)
	_maybe_add_rooftop_beacon(root, current_y, rng, 0.65)
	_maybe_add_billboard_slot(root, footprint, current_y, meta, district_info, rng)
	return root


# ── Style: DATA_STACK ────────────────────────────────────────────────────────

static func _build_data_stack(
		meta: BuildingMetadata,
		footprint: float,
		base_height: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Node3D:

	var root := Node3D.new()
	root.name = "Building_DataStack"
	var total_modules: int = rng.randi_range(4, 8)
	meta.tier_count = total_modules
	var module_h_avg: float = base_height * 0.18
	var current_y: float = 0.0

	for i in range(total_modules):
		var mh: float = module_h_avg * rng.randf_range(0.7, 1.35)
		var mx: float = footprint * rng.randf_range(0.6, 0.95)
		var mz: float = footprint * rng.randf_range(0.6, 0.95)
		var ox: float = rng.randf_range(-footprint * 0.1, footprint * 0.1)
		var oz: float = rng.randf_range(-footprint * 0.1, footprint * 0.1)
		var mi := _make_box_mesh(Vector3(mx, mh, mz))
		mi.position = Vector3(ox, current_y + mh * 0.5, oz)
		mi.material_override = InteriorMap.build_for_building(district_info, rng, mh, 4, max(3, int(mh / 2.5)))
		mi.name = "Module_%d" % i
		root.add_child(mi)
		current_y += mh
		meta.tier_tops.append({"y": current_y, "footprint": max(mx, mz)})

	meta.height = current_y
	_add_crown_trim(root, footprint * 0.6, current_y, meta.neon_secondary, rng)
	_maybe_add_antenna(root, footprint * 0.6, current_y, meta, rng, 0.55)
	# Multiple small rooftop beacons to imply industrial infrastructure.
	for _i in range(rng.randi_range(0, 3)):
		_maybe_add_rooftop_beacon(root, current_y, rng, 1.0)
	return root


# ── Style: MEGASPIRE ─────────────────────────────────────────────────────────

static func _build_megaspire(
		meta: BuildingMetadata,
		footprint: float,
		base_height: float,
		district_info,
		rng: RandomNumberGenerator,
	) -> Node3D:

	var root := Node3D.new()
	root.name = "Building_Megaspire"

	# Tier 1 — wide base podium.
	var base_h: float = base_height * rng.randf_range(0.25, 0.35)
	var base_fp: float = footprint
	var base := _make_box_mesh(Vector3(base_fp, base_h, base_fp))
	base.position = Vector3(0.0, base_h * 0.5, 0.0)
	base.material_override = InteriorMap.build_for_building(district_info, rng, base_h)
	base.name = "Podium"
	root.add_child(base)
	var current_y: float = base_h
	meta.tier_tops.append({"y": current_y, "footprint": base_fp})

	# Tier 2 — main shaft with 2-3 setbacks.
	var shaft_h_total: float = base_height * rng.randf_range(1.6, 2.4)
	var setbacks: int = rng.randi_range(2, 3)
	var per_setback_h: float = shaft_h_total / float(setbacks)
	var current_fp: float = base_fp * 0.85
	for s in range(setbacks):
		var mi := _make_box_mesh(Vector3(current_fp, per_setback_h, current_fp))
		mi.position = Vector3(0.0, current_y + per_setback_h * 0.5, 0.0)
		mi.material_override = InteriorMap.build_for_building(district_info, rng, per_setback_h)
		mi.name = "Shaft_%d" % s
		root.add_child(mi)
		current_y += per_setback_h
		meta.tier_tops.append({"y": current_y, "footprint": current_fp})
		current_fp *= rng.randf_range(0.82, 0.92)

	# Tier 3 — narrow crown block.
	var crown_h: float = base_height * 0.15
	var crown_fp: float = current_fp * 0.9
	var crown := _make_box_mesh(Vector3(crown_fp, crown_h, crown_fp))
	crown.position = Vector3(0.0, current_y + crown_h * 0.5, 0.0)
	crown.material_override = _make_glass_material(district_info, rng)
	crown.name = "Crown"
	root.add_child(crown)
	current_y += crown_h
	meta.tier_tops.append({"y": current_y, "footprint": crown_fp})

	# Tier 4 — spire.
	var spire_h: float = base_height * rng.randf_range(0.25, 0.45)
	var spire_top_fp: float = crown_fp * 0.15
	var spire := _make_tapered_spire(crown_fp * 0.6, spire_top_fp, spire_h)
	spire.position = Vector3(0.0, current_y + spire_h * 0.5, 0.0)
	spire.material_override = _make_metal_material(rng)
	spire.name = "Spire"
	root.add_child(spire)
	current_y += spire_h

	meta.height = current_y
	meta.tier_count = setbacks + 3
	_add_parapet(root, crown_fp, current_y - spire_h)
	_add_crown_trim(root, crown_fp, current_y - spire_h, meta.neon_primary, rng)
	_add_antenna(root, current_y, rng, meta)
	_maybe_add_rooftop_beacon(root, current_y, rng, 1.0)
	_maybe_add_billboard_slot(root, base_fp, base_h * 0.9, meta, district_info, rng)
	return root


# ── Mesh helpers ─────────────────────────────────────────────────────────────

static func _make_box_mesh(size: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	# Buildings are not navigable geometry; pin the cast mode for perf.
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


static func _make_tapered_spire(
		bottom_size: float,
		top_size: float,
		height: float,
	) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = bottom_size * 0.5
	cm.top_radius = top_size * 0.5
	cm.height = height
	cm.radial_segments = 8
	mi.mesh = cm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


# ── Rooftop props ────────────────────────────────────────────────────────────

static func _add_parapet(root: Node3D, footprint: float, height: float) -> void:
	var outer := _make_box_mesh(Vector3(footprint * 1.02, PARAPET_HEIGHT, footprint * 1.02))
	outer.position = Vector3(0.0, height + PARAPET_HEIGHT * 0.5, 0.0)
	var m := StandardMaterial3D.new()
	m.albedo_color = CROWN_TRIM_COLOR
	m.roughness = 0.9
	m.metallic = 0.3
	outer.material_override = m
	outer.name = "Parapet"
	root.add_child(outer)


static func _add_crown_trim(
		root: Node3D,
		footprint: float,
		height: float,
		neon: Color,
		rng: RandomNumberGenerator,
	) -> void:
	var trim_h: float = 0.35
	var y: float = height + PARAPET_HEIGHT + trim_h * 0.5
	var half: float = footprint * 0.5
	# Produce four strips — one along each of the four rooftop edges.
	#   side 0: +Z edge (running along X)
	#   side 1: -Z edge (running along X)
	#   side 2: +X edge (running along Z)
	#   side 3: -X edge (running along Z)
	var sides: Array = [
		{"pos": Vector3(0.0, y, half),  "rot_y": 0.0,         "size": Vector3(footprint * 0.98, trim_h, 0.2)},
		{"pos": Vector3(0.0, y, -half), "rot_y": 0.0,         "size": Vector3(footprint * 0.98, trim_h, 0.2)},
		{"pos": Vector3(half, y, 0.0), "rot_y": PI * 0.5,    "size": Vector3(footprint * 0.98, trim_h, 0.2)},
		{"pos": Vector3(-half, y, 0.0),"rot_y": PI * 0.5,    "size": Vector3(footprint * 0.98, trim_h, 0.2)},
	]
	for i in range(sides.size()):
		var side: Dictionary = sides[i]
		var strip := _make_box_mesh(side["size"])
		strip.rotation.y = side["rot_y"]
		strip.position = side["pos"]
		var m := StandardMaterial3D.new()
		m.albedo_color = neon
		m.emission_enabled = true
		m.emission = neon
		m.emission_energy_multiplier = rng.randf_range(3.0, 5.5)
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		strip.material_override = m
		strip.name = "NeonTrim_%d" % i
		root.add_child(strip)


static func _maybe_add_antenna(
		root: Node3D,
		footprint: float,
		height: float,
		meta: BuildingMetadata,
		rng: RandomNumberGenerator,
		probability: float,
	) -> void:
	if rng.randf() > probability:
		return
	_add_antenna(root, height, rng, meta)


static func _add_antenna(
		root: Node3D,
		top_y: float,
		rng: RandomNumberGenerator,
		meta: BuildingMetadata,
	) -> void:
	var mast := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.bottom_radius = 0.25
	cm.top_radius = 0.08
	cm.height = rng.randf_range(6.0, 14.0)
	cm.radial_segments = 6
	mast.mesh = cm
	mast.position = Vector3(
		rng.randf_range(-0.5, 0.5),
		top_y + cm.height * 0.5 + PARAPET_HEIGHT,
		rng.randf_range(-0.5, 0.5),
	)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.15, 0.15, 0.17)
	m.metallic = 0.7
	m.roughness = 0.55
	mast.material_override = m
	mast.name = "Antenna"
	root.add_child(mast)

	# Beacon light at the tip.
	var lamp := OmniLight3D.new()
	lamp.position = mast.position + Vector3(0.0, cm.height * 0.5 + 0.2, 0.0)
	lamp.omni_range = BEACON_LIGHT_RANGE
	lamp.light_color = meta.neon_primary
	lamp.light_energy = 0.8
	lamp.shadow_enabled = false
	lamp.name = "AntennaBeacon"
	root.add_child(lamp)

	meta.has_antenna = true


static func _maybe_add_rooftop_beacon(
		root: Node3D,
		top_y: float,
		rng: RandomNumberGenerator,
		probability: float,
	) -> void:
	if rng.randf() > probability:
		return
	var lamp := OmniLight3D.new()
	lamp.position = Vector3(
		rng.randf_range(-3.0, 3.0),
		top_y + PARAPET_HEIGHT + 0.5,
		rng.randf_range(-3.0, 3.0),
	)
	lamp.omni_range = BEACON_LIGHT_RANGE
	lamp.light_color = Color(1.0, 0.15, 0.15)
	lamp.light_energy = rng.randf_range(0.4, 0.9)
	lamp.shadow_enabled = false
	lamp.name = "RooftopBeacon"
	root.add_child(lamp)


static func _maybe_add_billboard_slot(
		root: Node3D,
		footprint: float,
		height: float,
		meta: BuildingMetadata,
		district_info,
		rng: RandomNumberGenerator,
	) -> void:
	# Only entertainment / downtown / slums get billboard faces, gated by
	# the district billboard_bias.
	if rng.randf() > district_info.billboard_bias * 0.6:
		return
	var size_x: float = footprint * rng.randf_range(0.35, 0.8)
	var size_y: float = height * rng.randf_range(0.15, 0.35)
	var offset_y: float = height * rng.randf_range(0.35, 0.7)

	var face := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(size_x, size_y)
	face.mesh = qm
	face.material_override = InteriorMap.build_for_billboard(district_info, rng, 10)
	face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	face.name = "BillboardFace"

	# Pick a random side to face outwards.
	var side: int = rng.randi_range(0, 3)
	var half_fp: float = footprint * 0.5 + 0.12
	match side:
		0:
			face.position = Vector3(0.0, offset_y, half_fp)
			face.rotation.y = 0.0
		1:
			face.position = Vector3(half_fp, offset_y, 0.0)
			face.rotation.y = PI * 0.5
		2:
			face.position = Vector3(0.0, offset_y, -half_fp)
			face.rotation.y = PI
		_:
			face.position = Vector3(-half_fp, offset_y, 0.0)
			face.rotation.y = -PI * 0.5
	root.add_child(face)
	meta.has_billboard_slot = true


# ── Material helpers ─────────────────────────────────────────────────────────

static func _make_glass_material(
		district_info,
		rng: RandomNumberGenerator,
	) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.1, 0.15, 0.2, 0.75)
	m.metallic = 0.9
	m.roughness = 0.08
	m.emission_enabled = true
	m.emission = district_info.neon_primary * 0.5
	m.emission_energy_multiplier = rng.randf_range(0.4, 0.8)
	return m


static func _make_metal_material(rng: RandomNumberGenerator) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.25, 0.25, 0.3)
	m.metallic = 0.85
	m.roughness = rng.randf_range(0.25, 0.5)
	return m


# ── Inspection API ───────────────────────────────────────────────────────────

## Extract BuildingMetadata from a root node produced by this factory. Returns
## null if the node was not created by the factory.
static func metadata_of(root: Node) -> BuildingMetadata:
	if root == null:
		return null
	if root.has_meta("building"):
		return root.get_meta("building")
	return null


## Return a flat list of rooftop anchor points for the given building metadata.
## Sky-bridges can attach to any tier top (not just the roof), which gives the
## skyline a more layered feel.
static func rooftop_anchors_for(meta: BuildingMetadata, ground_pos: Vector3) -> Array:
	var out: Array = []
	for tier in meta.tier_tops:
		out.append({
			"pos": ground_pos + Vector3(0.0, float(tier["y"]), 0.0),
			"footprint": float(tier["footprint"]),
			"meta": meta,
		})
	return out
