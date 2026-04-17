## BuildingDecaySystem — Ghost Building Decay for Inactive Landowners
##
## Handles:
##   • Monitoring all owned and nearby blocks for inactivity.
##   • 5-stage visual decay applied to building meshes in the 3D world:
##       Stage 0 — pristine (normal neon glow)
##       Stage 1 — slight flicker (48 h since last visit)
##       Stage 2 — dim glow + crack overlay (4 days)
##       Stage 3 — ghost / semi-transparent + static noise (7 days — full ghost)
##       Stage 4 — ruins mesh + no glow (14 days — maximum shame)
##   • Social shame broadcast — when a block reaches stage 3 nearby players
##     receive a zone notification so they can see the abandoned building.
##   • Restoration — visiting the block (or triggering restore_block()) resets
##     the decay stage immediately and notifies the server.
##   • Gold-glow enforcement — when LandOwnershipService reports a gold-glow
##     streak milestone, this system applies the particle effect to the mesh.
##
## The system works purely on client-side visual changes based on server data
## pushed via LandOwnershipService signals. No direct socket calls are made
## here; the service layer handles all persistence.
##
## Dependencies (autoloads):
##   LandOwnershipService, SocketIOClient

extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

## Seconds between local decay checks (lightweight; server is authoritative).
const LOCAL_CHECK_INTERVAL: float = 30.0

## Days of inactivity per decay stage transition.
const STAGE_THRESHOLDS_DAYS: Array = [0, 2, 4, 7, 14]

## Alpha (transparency) applied to building material per stage.
const STAGE_ALPHA: Array = [1.0, 0.95, 0.8, 0.45, 0.2]

## Emission energy multiplier per stage (1.0 = full neon glow, 0 = no glow).
const STAGE_EMISSION: Array = [1.0, 0.7, 0.4, 0.1, 0.0]

## Color tint applied per stage (additive mix toward grey/ghost).
const STAGE_COLOR_TINT: Array = [
	Color(1.0, 1.0, 1.0, 1.0),   # Stage 0 — pristine
	Color(0.9, 0.9, 1.0, 0.95),  # Stage 1 — cool blue hint
	Color(0.7, 0.7, 0.8, 0.80),  # Stage 2 — desaturated
	Color(0.5, 0.5, 0.6, 0.45),  # Stage 3 — ghost translucent
	Color(0.3, 0.3, 0.3, 0.20),  # Stage 4 — ruin silhouette
]

## Gold glow emission color applied when decoration streak ≥ GOLD_GLOW_STREAK.
const GOLD_GLOW_COLOR: Color = Color(1.0, 0.85, 0.0, 1.0)
const GOLD_GLOW_ENERGY: float = 3.0

## Social shame notification cooldown per block (seconds) to avoid spam.
const SHAME_NOTIFICATION_COOLDOWN: float = 300.0

# ── State ──────────────────────────────────────────────────────────────────────

## Maps block_id → Node3D building mesh node (populated by register_building).
var building_nodes: Dictionary = {}

## Maps block_id → current applied decay stage (0-4).
var applied_stages: Dictionary = {}

## Maps block_id → unix timestamp of last shame broadcast.
var shame_broadcast_times: Dictionary = {}

## Timer accumulator.
var _check_timer: float = 0.0

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when a building's visual decay stage changes.
signal decay_stage_changed(block_id: String, old_stage: int, new_stage: int)

## Emitted when a building is visually restored to stage 0.
signal building_restored(block_id: String)

## Emitted when gold-glow is applied to a building.
signal gold_glow_applied(block_id: String)

## Emitted when social-shame notification fires for an abandoned building.
signal shame_notification_sent(block_id: String, stage: int, owner_name: String)

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_connect_los_signals()
	print("[BuildingDecaySystem] Ready.")

func _process(delta: float) -> void:
	_check_timer += delta
	if _check_timer >= LOCAL_CHECK_INTERVAL:
		_check_timer = 0.0
		_run_decay_check()

# ── Signal wiring ──────────────────────────────────────────────────────────────

func _connect_los_signals() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		push_warning("[BuildingDecaySystem] LandOwnershipService not found.")
		return

	los.blocks_updated.connect(_on_blocks_updated)
	los.decoration_streak_updated.connect(_on_decoration_streak_updated)
	los.owned_blocks_changed.connect(_on_owned_blocks_changed)

# ── Public API ─────────────────────────────────────────────────────────────────

## Register a 3D building node so the decay system can modify its materials.
## Call this from CityGenerator or a building placement script.
func register_building(block_id: String, building_node: Node3D) -> void:
	building_nodes[block_id] = building_node
	applied_stages[block_id] = -1   # Force initial apply
	_apply_decay_stage_to_node(block_id)

## Unregister a building node (called when the block is freed).
func unregister_building(block_id: String) -> void:
	building_nodes.erase(block_id)
	applied_stages.erase(block_id)
	shame_broadcast_times.erase(block_id)

## Immediately restore a block's decay to stage 0.
## Called when the local player visits or decorates their block.
func restore_block(block_id: String) -> void:
	_set_stage(block_id, 0, true)
	_notify_server_visit(block_id)
	emit_signal("building_restored", block_id)

## Force re-evaluate decay for a specific block.
func refresh_block(block_id: String) -> void:
	_apply_decay_stage_to_node(block_id)

## Returns the current decay stage (0-4) for a block, or 0 if not tracked.
func get_decay_stage(block_id: String) -> int:
	return int(applied_stages.get(block_id, 0))

## Returns a human-readable description of a decay stage.
func get_stage_description(stage: int) -> String:
	match stage:
		0: return "Pristine — glowing neon"
		1: return "Flickering — owner absent 2+ days"
		2: return "Dimming — structural wear visible (4+ days)"
		3: return "Ghost Building — owner missing 7 days"
		4: return "Ruins — abandoned 14+ days"
		_: return "Unknown"

## Returns the Color tint for a given stage.
func get_stage_color(stage: int) -> Color:
	if stage < 0 or stage >= STAGE_COLOR_TINT.size():
		return Color.WHITE
	return STAGE_COLOR_TINT[stage]

# ── Internal decay logic ───────────────────────────────────────────────────────

func _run_decay_check() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	var now_unix: int = int(Time.get_unix_time_from_system())
	# Check all blocks we know about (not just owned ones) for visual variety.
	for block_id in los.blocks:
		var block: Dictionary = los.blocks[block_id]
		var stage: int = _compute_stage(block, now_unix)
		var old_stage: int = int(applied_stages.get(block_id, 0))
		if stage != old_stage:
			_set_stage(block_id, stage, false)

func _on_blocks_updated(changed_ids: Array) -> void:
	var now_unix: int = int(Time.get_unix_time_from_system())
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return
	for bid in changed_ids:
		if los.blocks.has(bid):
			var stage: int = _compute_stage(los.blocks[bid], now_unix)
			_set_stage(bid, stage, false)

func _on_decoration_streak_updated(block_id: String,
		new_streak: int, gold_glow_unlocked: bool) -> void:
	if gold_glow_unlocked:
		_apply_gold_glow(block_id)

func _on_owned_blocks_changed(_block_ids: Array) -> void:
	# Re-evaluate all known blocks when ownership changes.
	_run_decay_check()

func _compute_stage(block: Dictionary, now_unix: int) -> int:
	# Server-authoritative stage takes priority if present.
	var server_stage: int = int(block.get("decay_stage", -1))
	if server_stage >= 0:
		return clamp(server_stage, 0, 4)

	var last_visit: int = int(block.get("last_visit_unix", 0))
	if last_visit == 0:
		return 0   # No data — assume pristine.

	var days_since: float = float(now_unix - last_visit) / 86400.0

	if days_since >= float(STAGE_THRESHOLDS_DAYS[4]):
		return 4
	elif days_since >= float(STAGE_THRESHOLDS_DAYS[3]):
		return 3
	elif days_since >= float(STAGE_THRESHOLDS_DAYS[2]):
		return 2
	elif days_since >= float(STAGE_THRESHOLDS_DAYS[1]):
		return 1
	return 0

func _set_stage(block_id: String, new_stage: int, force: bool) -> void:
	var old_stage: int = int(applied_stages.get(block_id, 0))
	if not force and old_stage == new_stage:
		return

	applied_stages[block_id] = new_stage
	_apply_decay_stage_to_node(block_id)

	if new_stage != old_stage:
		emit_signal("decay_stage_changed", block_id, old_stage, new_stage)

	if new_stage >= 3:
		_maybe_broadcast_shame(block_id, new_stage)

func _apply_decay_stage_to_node(block_id: String) -> void:
	if not building_nodes.has(block_id):
		return
	var node: Node3D = building_nodes[block_id]
	if not is_instance_valid(node):
		building_nodes.erase(block_id)
		return

	var stage: int = int(applied_stages.get(block_id, 0))
	var alpha: float   = float(STAGE_ALPHA[clamp(stage, 0, 4)])
	var emission: float = float(STAGE_EMISSION[clamp(stage, 0, 4)])
	var tint: Color    = STAGE_COLOR_TINT[clamp(stage, 0, 4)]

	_apply_material_overrides(node, alpha, emission, tint)

func _apply_material_overrides(node: Node3D, alpha: float,
		emission_energy: float, tint: Color) -> void:
	# Walk MeshInstance3D children to update materials.
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child as MeshInstance3D
			for surf_idx in range(mi.get_surface_override_material_count()):
				var mat = mi.get_surface_override_material(surf_idx)
				if mat == null:
					mat = mi.mesh.surface_get_material(surf_idx)
				if mat == null:
					continue
				# Clone to avoid mutating shared resources.
				mat = mat.duplicate() as Material
				mi.set_surface_override_material(surf_idx, mat)

				if mat is StandardMaterial3D:
					var std_mat: StandardMaterial3D = mat as StandardMaterial3D
					std_mat.albedo_color = Color(
							tint.r, tint.g, tint.b, alpha)
					if alpha < 1.0:
						std_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
					std_mat.emission_energy_multiplier = emission_energy

				elif mat is ShaderMaterial:
					# Cyber-building shader — set known uniform names.
					var sm: ShaderMaterial = mat as ShaderMaterial
					if sm.shader and sm.shader.has_parameter("albedo_alpha"):
						sm.set_shader_parameter("albedo_alpha", alpha)
					if sm.shader and sm.shader.has_parameter("emission_multiplier"):
						sm.set_shader_parameter("emission_multiplier",
								emission_energy)
					if sm.shader and sm.shader.has_parameter("tint_color"):
						sm.set_shader_parameter("tint_color", tint)
		# Recurse into children (e.g. LOD sub-nodes).
		if child.get_child_count() > 0:
			_apply_material_overrides(child as Node3D, alpha,
					emission_energy, tint)

func _apply_gold_glow(block_id: String) -> void:
	if not building_nodes.has(block_id):
		return
	var node: Node3D = building_nodes[block_id]
	if not is_instance_valid(node):
		return

	# Reset decay to 0 and apply gold tint.
	applied_stages[block_id] = 0
	_apply_material_overrides_gold(node)
	emit_signal("gold_glow_applied", block_id)
	print("[BuildingDecaySystem] Gold glow applied to block: ", block_id)

func _apply_material_overrides_gold(node: Node3D) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi: MeshInstance3D = child as MeshInstance3D
			for surf_idx in range(mi.get_surface_override_material_count()):
				var mat = mi.get_surface_override_material(surf_idx)
				if mat == null:
					mat = mi.mesh.surface_get_material(surf_idx)
				if mat == null:
					continue
				mat = mat.duplicate() as Material
				mi.set_surface_override_material(surf_idx, mat)

				if mat is StandardMaterial3D:
					var std_mat: StandardMaterial3D = mat as StandardMaterial3D
					std_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
					std_mat.emission_enabled = true
					std_mat.emission = GOLD_GLOW_COLOR
					std_mat.emission_energy_multiplier = GOLD_GLOW_ENERGY

				elif mat is ShaderMaterial:
					var sm: ShaderMaterial = mat as ShaderMaterial
					if sm.shader and sm.shader.has_parameter("emission_multiplier"):
						sm.set_shader_parameter("emission_multiplier",
								GOLD_GLOW_ENERGY)
					if sm.shader and sm.shader.has_parameter("tint_color"):
						sm.set_shader_parameter("tint_color", GOLD_GLOW_COLOR)
		if child.get_child_count() > 0:
			_apply_material_overrides_gold(child as Node3D)

func _maybe_broadcast_shame(block_id: String, stage: int) -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	var now: float = Time.get_ticks_msec() / 1000.0
	var last_time: float = float(shame_broadcast_times.get(block_id, -9999.0))
	if now - last_time < SHAME_NOTIFICATION_COOLDOWN:
		return

	shame_broadcast_times[block_id] = now

	var block: Dictionary = los.get_block(block_id)
	var owner_name: String = block.get("owner_name", "Unknown")

	emit_signal("shame_notification_sent", block_id, stage, owner_name)

	# Broadcast in-world notification so nearby players see it.
	var banners: Array = get_tree().get_nodes_in_group("announcement_banner")
	for banner in banners:
		if banner.has_method("show_announcement"):
			var msg: String
			if stage == 3:
				msg = "👻  %s's building is fading — they haven't visited in 7 days!" \
						% owner_name
			else:
				msg = "💀  %s's block is in ruins — 14 days abandoned!" \
						% owner_name
			banner.show_announcement(msg, 5.0)
			break

func _notify_server_visit(block_id: String) -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket == null:
		return
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	var player_id: String = ""
	if los:
		player_id = los.local_player_id

	socket.emit_event("land_block_visit", {
		"blockId":  block_id,
		"playerId": player_id,
	})
