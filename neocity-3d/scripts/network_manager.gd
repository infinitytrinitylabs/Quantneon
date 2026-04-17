## Central World Sync Manager
## Orchestrates Socket.IO events and updates the 3D scene.
##
## Spatial-Partitioning layer (10K player support)
## ─────────────────────────────────────────────────
## All remote entities are bucketed into a spatial hash-grid with cell size
## SPATIAL_CELL_SIZE (world units).  Each frame the grid is consulted to find
## which entities share cells with the local player; only those entities receive
## full position/state updates and are kept visible.  Entities that fall outside
## VISUAL_RANGE are hidden (not freed) so they can be cheaply re-shown when the
## local player approaches.
##
## The server snapshot still arrives with ALL players in the zone, but the
## client-side culling pass filters the set before any Tween / Node work is done,
## keeping the per-frame cost proportional to visible density rather than total
## concurrent count.

extends Node

@onready var socket_client: Node = get_node("/root/SocketIOClient")
@onready var quantads_native_bridge = preload("res://scripts/quantads_native_bridge.gd").new()
@export var npc_scene: PackedScene = preload("res://scenes/npc.tscn")
@export var remote_player_scene: PackedScene = preload("res://scenes/player.tscn")
@export var vehicle_scene: PackedScene = preload("res://scenes/vehicle.tscn")
@export var drop_scene: PackedScene = preload("res://scenes/loot_drop.tscn")
@export var capture_point_scene: PackedScene = preload("res://scenes/capture_point.tscn")
@export var vault_door_scene: PackedScene = preload("res://scenes/vault_door.tscn")
@export var data_terminal_scene: PackedScene = preload("res://scenes/data_terminal.tscn")
@export var projectile_tracer_scene: PackedScene = preload("res://scenes/projectile_tracer.tscn")
@export var elevator_scene: PackedScene = preload("res://scenes/elevator_system.tscn")
@export var spatial_anchor_ad_scene: PackedScene = preload("res://scenes/spatial_anchor_ad.tscn")

@export var announcement_scene: PackedScene = preload("res://scenes/announcement_banner.tscn")

# ── Spatial partitioning config ───────────────────────────────────────────────
## World-unit size of each spatial grid cell.
@export var spatial_cell_size: float = 50.0

## Distance (world units) within which remote entities receive full updates.
## Entities beyond this radius are hidden until the player moves closer.
@export var visual_range: float = 120.0

## Number of physics frames between full spatial-partition sweeps.
## At 60 fps and interval=6 this runs at 10 Hz — same rate as the move sync.
@export var spatial_sweep_interval: int = 6

# ── Tracking ─────────────────────────────────────────
var entities: Dictionary = {} # {id: Node3D}
var quantad_anchors: Dictionary = {} # {ad_id: Node3D}
var quantad_fallback_counter: int = 0
var local_player: CharacterBody3D

# Spatial hash grid: maps cell_key (Vector2i) → Array[String] of entity IDs.
# Rebuilt on every zone_update snapshot so it always reflects the server state.
var _spatial_grid: Dictionary = {}

# Last known server-reported world position (in scaled coords x/10, z/10) per entity id.
var _entity_server_pos: Dictionary = {} # {id: Vector3}

signal world_entered(data)
signal zone_update_received(snapshot)



func _ready():
	socket_client.connected.connect(_on_socket_connected)
	socket_client.on_event("zone_update", _handle_zone_update)
	socket_client.on_event("quest_update", _handle_quest_update)
	socket_client.on_event("inventory_update", _handle_inventory_update)
	socket_client.on_event("vehicle_mission_started", _handle_vehicle_mission_started)
	socket_client.on_event("vehicle_mission_update", _handle_vehicle_mission_update)
	socket_client.on_event("world_entered", _handle_world_entered)
	socket_client.on_event("territory_update", _handle_territory_update)
	socket_client.on_event("capture_points_update", _handle_capture_points_update)
	socket_client.on_event("heist_alarm", _handle_heist_alarm)
	socket_client.on_event("zone_notification", _handle_zone_notification)
	socket_client.on_event("zipline_ride", _handle_zipline_ride)
	socket_client.on_event("player_subway", _handle_player_subway)
	socket_client.on_event("global_announcement", _handle_global_announcement)
	socket_client.on_event("quantads_auction_won", _handle_quantads_auction_won)
	socket_client.on_event("land_block_decay_update", _handle_land_block_decay_update)

	print("[Network] Ready to sync world.")
	local_player = get_tree().root.find_child("Player", true, false)
	
	# Instantiate announcement banner
	var banner = announcement_scene.instantiate()
	get_tree().root.call_deferred("add_child", banner)

	# WebGL Export React Bridge (Strict Payload Validation)
	if has_node("/root/ReactBridge"):
		var react_bridge = get_node("/root/ReactBridge")
		react_bridge.auth_token_received.connect(_on_react_auth_token_strict)
		react_bridge.quantads_auction_won_received.connect(_handle_quantads_auction_won)

func _on_react_auth_token_strict(token: String):
	print("[NetworkManager] Passing strict Auth Token to SocketIO Client")
	if socket_client.has_method("set_token"):
		socket_client.set_token(token)

func _on_socket_connected(sid: String):
	print("[NetworkManager] SID: ", sid)
	# Join the world
	socket_client.send_event("enter_world", {"zoneId": "downtown"})

func _handle_weapon_fire(data: Dictionary):
	if data.has("weapon") and data.weapon == "none": return
	
	var id = data.userId
	var start_pos = Vector3.ZERO
	var target_pos = Vector3(data.pos.x / 10.0, 1.0, data.pos.y / 10.0)
	
	if entities.has(id):
		var inst = entities[id]
		start_pos = inst.global_position + Vector3(0, 1.5, 0) # Chest height
		
		# Trigger muzzle flash on the remote player model
		if inst.has_node("MuzzleFlash"):
			inst.get_node("MuzzleFlash").flash()
	elif local_player and id == socket_client.sid:
		start_pos = local_player.global_position + Vector3(0, 1.5, 0)
	
	# Spawn Tracer
	if start_pos != Vector3.ZERO:
		var tracer = projectile_tracer_scene.instantiate()
		get_tree().root.add_child(tracer)
		tracer.setup(start_pos, target_pos)

func _handle_npc_damaged(data: Dictionary):
	var id = data.npcId
	if entities.has(id):
		var inst = entities[id]
		if inst.has_method("take_damage"):
			inst.take_damage(data.damage)

func _handle_npc_response(data: Dictionary):
	if has_node("/root/DialogueSystem"):
		get_node("/root/DialogueSystem").update_text(data.message)

func _handle_world_entered(data: Dictionary):
	print("[NetworkManager] World entered. Snapshot NPCs: ", data.snapshot.npcs.size())
	_handle_zone_update(data.snapshot)
	emit_signal("world_entered", data)

func _handle_zone_update(snapshot: Dictionary):
	# 1. Update NPCs
	for npc_data in snapshot.npcs:
		_update_or_create_entity(npc_data, npc_scene, "npc")
	
	# 2. Update Other Players
	for player_data in snapshot.players:
		if player_data.userId != socket_client.sid:
			_update_or_create_entity(player_data, remote_player_scene, "player")
		else:
			# Sync self-state (Wanted Level)
			if has_node("/root/WantedHUD"):
				get_node("/root/WantedHUD").update_wanted_level(player_data.wanted)
			
			# Sync Mission HUD
			if has_node("/root/MissionHUD"):
				get_node("/root/MissionHUD").update_quest(player_data.quest)
				
	emit_signal("zone_update_received", snapshot)

	# 3. Update Vehicles
	if snapshot.has("vehicles"):
		for vehicle_data in snapshot.vehicles:
			_update_or_create_entity(vehicle_data, vehicle_scene, "vehicle")

	# 4. Update Loot Drops
	if snapshot.has("drops") and drop_scene:
		# Track current drops to remove stale ones
		var current_drop_ids = []
		for drop_data in snapshot.drops:
			current_drop_ids.append(drop_data.id)
			_update_or_create_entity(drop_data, drop_scene, "drop")
		
		# Clean up consumed drops
		for entity_id in entities.keys():
			if entities[entity_id].name.begins_with("drop_") and not current_drop_ids.has(entity_id):
				entities[entity_id].queue_free()
				entities.erase(entity_id)

	# 5. Update Vaults
	if snapshot.has("vaults"):
		for vault_data in snapshot.vaults:
			_update_or_create_entity(vault_data, vault_door_scene, "vault")

	# 6. Update Data Terminals
	if snapshot.has("dataTerminals"):
		for dt_data in snapshot.dataTerminals:
			_update_or_create_entity(dt_data, data_terminal_scene, "data_terminal")

	# 7. Update Capture Points
	if snapshot.has("capturePoints"):
		for cp_data in snapshot.capturePoints:
			_update_or_create_entity(cp_data, capture_point_scene, "capture_point")

	# 8. Update Elevators
	if snapshot.has("elevators"):
		for elev_data in snapshot.elevators:
			_update_or_create_entity(elev_data, elevator_scene, "elevator")

	# 9. Rebuild spatial grid after snapshot is fully processed so the
	#    visibility sweep on the next physics frame uses fresh positions.
	_rebuild_spatial_grid()

func _update_or_create_entity(data: Dictionary, scene: PackedScene, type: String):
	var id = data.id if data.has("id") else data.userId
	
	if not entities.has(id):
		var inst = scene.instantiate()
		inst.name = type + "_" + id.substr(0, 8)
		get_tree().root.add_child(inst)
		entities[id] = inst
		
		# If it's an NPC, we might want to disable its local AI if it's strictly server-pushed
		if inst.has_method("set_remote_mode"):
			inst.set_remote_mode(true)
		
		if "npc_id" in inst:
			inst.npc_id = id
	
	# Update position/rotation
	var entity = entities[id]
	
	# Skip update if we are driving it
	if entity.has_method("get_driver") and entity.driver != null:
		if entity.driver == local_player:
			return

	var target_pos = Vector3(data.x / 10.0, 1.0, data.y / 10.0)

	# Keep the spatial index up-to-date for this entity regardless of distance.
	# The position must always be fresh so the visibility sweep can correctly
	# show the node the moment the player walks within visual_range.
	_entity_server_pos[id] = target_pos

	# Skip the expensive Tween/state work for entities outside visual range.
	# Their node is already hidden by _run_spatial_visibility_sweep; the
	# recorded position above ensures they re-appear correctly when approached.
	if local_player != null:
		var dist_sq: float = local_player.global_position.distance_squared_to(target_pos)
		if dist_sq > visual_range * visual_range:
			return
	
	if entity.has_method("set_remote_mode"):
		entity.is_remote = true
		entity.target_pos = target_pos
		if data.has("r"):
			entity.target_rot = data.r
		if data.has("behavior") and "behavior_type" in entity:
			entity.behavior_type = data.behavior
	else:
		# Smooth interpolation for simple entities
		var tween = create_tween().set_parallel(true)
		tween.tween_property(entity, "global_position", target_pos, 0.1)
		
		# Rotate to face movement direction
		if data.has("r"):
			entity.rotation.y = lerp_angle(entity.rotation.y, data.r, 0.2)
	
	# Handle Faction/Capture Point/Vault/Player specific state — call once via the
	# generic check to avoid double-applying state for player and npc entities.
	if entity.has_method("update_state"):
		entity.update_state(data)
	
	# Handle Death
	if data.has("dead") and data.dead:
		if entity.has_method("die") and not entity.is_dead:
			entity.die()
			entities.erase(id)
			_entity_server_pos.erase(id)

func _handle_quest_update(data: Dictionary):
	if has_node("/root/MissionHUD"):
		if data.status == "completed":
			get_node("/root/MissionHUD").show_completion(data.quest.title)
		else:
			get_node("/root/MissionHUD").update_quest(data.quest)

func _handle_inventory_update(data: Dictionary):
	if has_node("/root/InventoryUI"):
		get_node("/root/InventoryUI").sync_inventory(data)

func _handle_vehicle_mission_started(data: Dictionary):
	if has_node("/root/VehicleMissionHUD"):
		get_node("/root/VehicleMissionHUD").start_mission(data)

func _handle_vehicle_mission_update(data: Dictionary):
	if has_node("/root/VehicleMissionHUD"):
		get_node("/root/VehicleMissionHUD").update_mission_state(data)

func _handle_npc_interaction(data: Dictionary):
	if has_node("/root/DialogueSystem"):
		get_node("/root/DialogueSystem").start_dialogue(data)

func _handle_territory_update(data: Dictionary):
	if has_node("/root/HUD/WarMap"):
		get_node("/root/HUD/WarMap").update_zone(data)
		
	# Broadcast to chat
	if has_node("/root/HUD/ChatBox"):
		get_node("/root/HUD/ChatBox").add_message("NEO-NET", "Territory '%s' captured by %s!" % [data.zoneId, data.faction], "SYSTEM")

func _handle_capture_points_update(points: Array):
	for cp_data in points:
		_update_or_create_entity(cp_data, capture_point_scene, "capture_point")

func _handle_heist_alarm(data: Dictionary):
	if has_node("/root/HUD/WarMap"):
		get_node("/root/HUD/WarMap").trigger_alarm(data.vaultId)
		
	if has_node("/root/HUD/ChatBox"):
		get_node("/root/HUD/ChatBox").add_message("NEO-NET", "SECURITY ALERT: Vault lockdown overridden! Enforcers dispatched.", "SYSTEM")

	# Screen Flash Effect
	var flash = ColorRect.new()
	flash.color = Color(1, 0, 0, 0.4) # Transparent Red
	flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(flash)
	
	var tween = create_tween().set_loops(3) # Flash 3 times
	tween.tween_property(flash, "color:a", 0.0, 0.5)
	tween.tween_property(flash, "color:a", 0.4, 0.5)
	
	# Cleanup after flashes
	get_tree().create_timer(4.0).timeout.connect(flash.queue_free)

func _handle_zone_notification(data: Dictionary):
	print("[Zone Notification] ", data.message)

func _physics_process(_delta):
	var frame: int = Engine.get_physics_frames()

	# Sync local player movement to server at ~10Hz
	if frame % 6 == 0:
		if local_player and socket_client.is_connected:
			var intent = {
				"x": local_player.velocity.x,
				"y": local_player.velocity.z
			}
			socket_client.send_event("player_move", {"intent": intent})

	# Spatial-partition visibility sweep at the same 10 Hz cadence.
	if frame % spatial_sweep_interval == 0:
		_run_spatial_visibility_sweep()


# ── Spatial Partitioning Helpers ──────────────────────────────────────────────

## Returns the grid cell key for a world-space XZ position.
func _cell_key(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		int(floor(world_pos.x / spatial_cell_size)),
		int(floor(world_pos.z / spatial_cell_size))
	)

## Rebuilds the spatial hash grid from the current _entity_server_pos map.
func _rebuild_spatial_grid() -> void:
	_spatial_grid.clear()
	for id in _entity_server_pos:
		var pos: Vector3 = _entity_server_pos[id]
		var key: Vector2i = _cell_key(pos)
		if not _spatial_grid.has(key):
			_spatial_grid[key] = []
		_spatial_grid[key].append(id)

## Returns the set of entity IDs that are within visual_range of the local player.
## Uses the spatial grid to avoid an O(N) linear scan across all entities.
func _get_ids_in_visual_range() -> Dictionary:
	var visible_ids: Dictionary = {}
	if local_player == null:
		return visible_ids

	var player_pos: Vector3 = local_player.global_position
	var player_cell: Vector2i = _cell_key(player_pos)

	# Calculate how many cells we need to check in each direction.
	var cell_radius: int = int(ceil(visual_range / spatial_cell_size)) + 1

	for dx in range(-cell_radius, cell_radius + 1):
		for dz in range(-cell_radius, cell_radius + 1):
			var check_key: Vector2i = player_cell + Vector2i(dx, dz)
			if not _spatial_grid.has(check_key):
				continue
			for id in _spatial_grid[check_key]:
				if visible_ids.has(id):
					continue
				# Fine-grained distance check inside the candidate cell.
				var ep: Vector3 = _entity_server_pos.get(id, Vector3.ZERO)
				if player_pos.distance_squared_to(ep) <= visual_range * visual_range:
					visible_ids[id] = true
	return visible_ids

## Shows/hides entity nodes based on proximity to the local player.
## This is the key performance win for 10 K concurrent connections: nodes
## outside visual_range are hidden (not freed) so no transform/tween work
## is wasted on them each frame.
func _run_spatial_visibility_sweep() -> void:
	if local_player == null or _spatial_grid.is_empty():
		return

	var visible_ids: Dictionary = _get_ids_in_visual_range()

	for id in entities:
		var node: Node3D = entities[id]
		if not is_instance_valid(node):
			continue
		var should_show: bool = visible_ids.has(id)
		if node.visible != should_show:
			node.visible = should_show

func _handle_zipline_ride(data: Dictionary):
	var user_id = data.get("userId", "")
	if user_id == "" or user_id == socket_client.sid:
		return  # Don't animate ourselves
	
	if !entities.has(user_id):
		return  # Player not spawned yet
	
	var remote_player = entities[user_id]
	var start = Vector3(data.startPos.x, data.startPos.y, data.startPos.z)
	var end_p = Vector3(data.endPos.x, data.endPos.y, data.endPos.z)
	var direction = data.get("direction", 1)
	
	# Calculate ride duration based on distance
	var distance = start.distance_to(end_p)
	var duration = distance / 15.0  # 15 units/sec ride speed
	
	# Animate the remote player along the cable
	var from_pos = start if direction == 1 else end_p
	var to_pos = end_p if direction == 1 else start
	from_pos.y -= 1.0  # Hang below cable
	to_pos.y -= 1.0
	
	var tween = create_tween()
	tween.tween_property(remote_player, "global_position", to_pos, duration)

func _handle_player_subway(data: Dictionary):
	var user_id = data.get("userId", "")
	if user_id == "" or user_id == socket_client.sid:
		return
	
	if !entities.has(user_id):
		return
	
	var remote_player = entities[user_id]
	
	# Flash effect on the remote player (disappear/reappear)
	var tween = create_tween()
	tween.tween_property(remote_player, "scale", Vector3(1, 0.01, 1), 0.2)
	tween.tween_interval(0.5)
	tween.tween_property(remote_player, "scale", Vector3(1, 1, 1), 0.2)
	
	print("[Network] Player %s used subway: %s -> %s" % [user_id.substr(0, 8), data.get("from", "?"), data.get("to", "?")])

func _handle_global_announcement(data: Dictionary):
	print("[Global Announcement] ", data.message)
	# Find our banner in the tree
	var banners = get_tree().get_nodes_in_group("announcement_banner")
	if banners.size() > 0:
		var banner = banners[0]
		if banner.has_method("show_announcement"):
			banner.show_announcement(data.message, data.get("duration", 4.0))

func _handle_quantads_auction_won(data: Dictionary):
	var cpc = float(data.get("cpc", 0.0))
	if not quantads_native_bridge.is_high_value_auction(cpc):
		return
	
	var ad_id = str(data.get("id", ""))
	if ad_id == "":
		quantad_fallback_counter += 1
		ad_id = "auction_%s_%d" % [str(Time.get_ticks_usec()), quantad_fallback_counter]
	
	var anchor = quantad_anchors.get(ad_id, null)
	if anchor == null:
		anchor = spatial_anchor_ad_scene.instantiate()
		quantad_anchors[ad_id] = anchor
		get_tree().root.add_child(anchor)
	
	# Existing anchors are refreshed in place so repeated wins for the same ad id
	# continue to feel like one persistent in-world spatial object.
	if anchor.has_method("configure_from_payload"):
		anchor.configure_from_payload(data)

func _handle_land_block_decay_update(data: Dictionary):
	# Forward server-authoritative decay updates to BuildingDecaySystem.
	if has_node("/root/BuildingDecaySystem"):
		var bds: Node = get_node("/root/BuildingDecaySystem")
		var bid: String = data.get("blockId", data.get("block_id", ""))
		var stage: int  = int(data.get("decayStage", data.get("decay_stage", 0)))
		if bid != "" and bds.has_method("get_decay_stage"):
			# Notify LandOwnershipService so it can update its block registry.
			if has_node("/root/LandOwnershipService"):
				var los: Node = get_node("/root/LandOwnershipService")
				if los.blocks.has(bid):
					los.blocks[bid]["decay_stage"] = stage
					los.emit_signal("blocks_updated", [bid])
