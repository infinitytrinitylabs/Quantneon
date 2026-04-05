## Central World Sync Manager
## Orchestrates Socket.IO events and updates the 3D scene.

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

# ── Tracking ─────────────────────────────────────────
var entities: Dictionary = {} # {id: Node3D}
var quantad_anchors: Dictionary = {} # {ad_id: Node3D}
var quantad_fallback_counter: int = 0
var local_player: CharacterBody3D

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
	
	# Handle Faction/Capture Point/Vault/Player specific state
	if type == "player" and entity.has_method("update_state"):
		entity.update_state(data)
	
	if type == "npc" and entity.has_method("update_state"):
		entity.update_state(data)
	if entity.has_method("update_state"):
		entity.update_state(data)
	
	# Handle Death
	if data.has("dead") and data.dead:
		if entity.has_method("die") and not entity.is_dead:
			entity.die()
			entities.erase(id)

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
	# Sync local player movement to server at ~10Hz
	if Engine.get_physics_frames() % 6 == 0: # 60fps / 6 = 10Hz
		if local_player and socket_client.is_connected:
			var intent = {
				"x": local_player.velocity.x,
				"y": local_player.velocity.z
			}
			socket_client.send_event("player_move", {"intent": intent})

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
