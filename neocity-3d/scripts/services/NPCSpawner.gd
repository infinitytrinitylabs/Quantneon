## NPCSpawner.gd
## Manages NPC spawning, LOD (Level of Detail), day/night cycle,
## and special event NPC pools for each city district.
## Spawns 50–100 NPCs per district with full AI for nearby ones
## and simplified behavior for distant ones.

extends Node

# ── Signals ─────────────────────────────────────────────────────────────────

signal npc_spawned(npc_id: String, district: String)
signal npc_despawned(npc_id: String)
signal district_populated(district: String, count: int)
signal day_cycle_changed(is_daytime: bool)
signal event_npcs_spawned(event_name: String, count: int)
signal event_npcs_cleared(event_name: String)
signal lod_updated(npc_id: String, lod_level: int)

# ── Configuration ─────────────────────────────────────────────────────────────

@export var min_npcs_per_district: int = 50
@export var max_npcs_per_district: int = 100
@export var full_ai_radius: float = 30.0       # meters from player: full AI
@export var simplified_ai_radius: float = 80.0  # meters: simplified behavior
@export var despawn_radius: float = 150.0       # meters: despawn NPC

# ── Districts ─────────────────────────────────────────────────────────────────

## district_id -> { name, center, radius, npc_count, npcs, spawn_points, type }
var districts: Dictionary = {}

## Active NPCs: npc_id -> { brain_node, dialogue_node, economy_node, scene_node, district, lod_level }
var active_npcs: Dictionary = {}

# ── Day/Night Cycle ────────────────────────────────────────────────────────────

var current_game_hour: float = 8.0     # 0–24 game time
var game_time_speed: float = 60.0       # real seconds per game hour
var is_daytime: bool = true
var _time_accumulator: float = 0.0

const DAWN_HOUR: float = 6.0
const DUSK_HOUR: float = 20.0

# ── Player Reference ─────────────────────────────────────────────────────────

var player_node: Node3D = null
var player_position: Vector3 = Vector3.ZERO

# ── Event NPCs ────────────────────────────────────────────────────────────────

## event_pools: event_name -> Array of npc_ids
var event_npc_pools: Dictionary = {}

## active_events: Array of { name, district, duration_hours, start_hour, npc_ids }
var active_events: Array = []

## Event NPC archetypes for FOMO zones
const EVENT_ARCHETYPES: Array = [
	{"role": "event_vendor",   "occupation": "street_vendor",  "faction": "civilian"},
	{"role": "event_guard",    "occupation": "guard",           "faction": "nexus_corp"},
	{"role": "event_dancer",   "occupation": "entertainer",     "faction": "civilian"},
	{"role": "event_reporter", "occupation": "info_broker",     "faction": "civilian"},
	{"role": "event_medic",    "occupation": "medic",           "faction": "ripperdocs"},
]

# ── Occupation Templates by District Type ─────────────────────────────────────

const DISTRICT_OCCUPATIONS: Dictionary = {
	"commercial":  ["merchant", "shopkeeper", "street_vendor", "guard", "civilian", "fixer"],
	"residential": ["civilian", "bartender", "medic", "street_vendor", "courier", "civilian"],
	"industrial":  ["engineer", "guard", "scavenger", "courier", "hacker", "civilian"],
	"underground": ["hacker", "smuggler", "fixer", "shadow_dealer", "info_broker", "civilian"],
	"corporate":   ["guard", "engineer", "info_broker", "courier", "civilian", "fixer"],
	"market":      ["merchant", "shopkeeper", "street_vendor", "fixer", "civilian", "courier"],
}

# ── NPC Scene Path (configurable) ─────────────────────────────────────────────

var npc_scene_path: String = "res://scenes/npc_base.tscn"
var _npc_scene: PackedScene = null
var _use_scene_instances: bool = false   # false = pure-logic nodes for headless testing

# ── Internal ─────────────────────────────────────────────────────────────────

var _lod_update_timer: float = 0.0
const LOD_UPDATE_INTERVAL: float = 1.0   # seconds between LOD passes

var _gossip_timer: float = 0.0
const GOSSIP_INTERVAL: float = 30.0     # seconds between NPC gossip exchanges

var _economy_trade_timer: float = 0.0
const ECONOMY_TRADE_INTERVAL: float = 60.0

var _npc_id_counter: int = 0

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_try_load_npc_scene()
	_register_default_districts()
	set_process(true)

func _process(delta: float) -> void:
	_advance_time(delta)
	_update_lod(delta)
	_run_gossip_tick(delta)
	_run_economy_trade_tick(delta)
	_update_player_position()
	_check_event_expirations()

# ─────────────────────────────────────────────────────────────────────────────
# District Registration
# ─────────────────────────────────────────────────────────────────────────────

func register_district(district_id: String, district_name: String, center: Vector3,
		radius: float, district_type: String = "commercial") -> void:
	districts[district_id] = {
		"name": district_name,
		"center": center,
		"radius": radius,
		"type": district_type,
		"npcs": [],
		"target_npc_count": randi_range(min_npcs_per_district, max_npcs_per_district),
		"spawn_points": _generate_spawn_points(center, radius, 20),
	}

func _register_default_districts() -> void:
	register_district("central",    "Central Plaza",       Vector3(0, 0, 0),      60.0, "commercial")
	register_district("market",     "Night Market",        Vector3(120, 0, 0),    50.0, "market")
	register_district("industrial", "Industrial Quarter",  Vector3(-120, 0, 0),   70.0, "industrial")
	register_district("residential","Residential Zone",    Vector3(0, 0, 120),    55.0, "residential")
	register_district("underground","Underground Network", Vector3(0, -10, -80),  40.0, "underground")
	register_district("corporate",  "Corp Towers",         Vector3(-80, 0, -80),  65.0, "corporate")

func _generate_spawn_points(center: Vector3, radius: float, count: int) -> Array:
	var points: Array = []
	for i in range(count):
		var angle: float = (float(i) / float(count)) * PI * 2.0 + randf_range(-0.3, 0.3)
		var dist: float = randf_range(radius * 0.2, radius * 0.85)
		points.append(center + Vector3(cos(angle) * dist, 0, sin(angle) * dist))
	return points

# ─────────────────────────────────────────────────────────────────────────────
# NPC Spawning
# ─────────────────────────────────────────────────────────────────────────────

func populate_district(district_id: String) -> void:
	if not districts.has(district_id):
		push_warning("[NPCSpawner] Unknown district: " + district_id)
		return

	var district = districts[district_id]
	var target: int = district.get("target_npc_count", min_npcs_per_district)
	var current: int = district["npcs"].size()
	var to_spawn: int = target - current

	for i in range(to_spawn):
		_spawn_npc_in_district(district_id)

	emit_signal("district_populated", district_id, district["npcs"].size())
	print("[NPCSpawner] District '", district_id, "' populated with ", district["npcs"].size(), " NPCs.")

func populate_all_districts() -> void:
	for district_id in districts.keys():
		populate_district(district_id)

func _spawn_npc_in_district(district_id: String) -> String:
	var district = districts[district_id]
	var occupation: String = _pick_occupation_for_district(district.get("type", "commercial"))
	var spawn_pos: Vector3 = _pick_spawn_point(district)

	var npc_id: String = _generate_npc_id()

	# Create brain
	var brain = NPCBrain.new() if _class_exists("NPCBrain") else Node.new()
	brain.name = "Brain_" + npc_id
	if brain.has_method("randomize_personality"):
		brain.randomize_personality()
	if "occupation" in brain:
		brain.occupation = occupation
	if "faction" in brain:
		brain.faction = _pick_faction_for_district(district.get("type", "commercial"))
	if "home_district" in brain:
		brain.home_district = district_id
	if brain.has_method("update_time"):
		brain.update_time(current_game_hour)

	# Create dialogue
	var dialogue = NPCDialogue.new() if _class_exists("NPCDialogue") else Node.new()
	dialogue.name = "Dialogue_" + npc_id
	if dialogue.has_method("setup"):
		dialogue.setup(brain)

	# Create economy (merchants, shopkeepers, vendors, bartenders get shops)
	var economy: Node = null
	if occupation in ["merchant", "shopkeeper", "street_vendor", "bartender", "smuggler", "fixer", "shadow_dealer"]:
		economy = NPCEconomy.new() if _class_exists("NPCEconomy") else Node.new()
		economy.name = "Economy_" + npc_id
		if "shop_owner_id" in economy:
			economy.shop_owner_id = npc_id
		if "district" in economy:
			economy.district = district_id
		if "shop_type" in economy:
			economy.shop_type = _pick_shop_type(occupation)
		if economy.has_method("set_time"):
			economy.set_time(current_game_hour)
		if dialogue.has_method("setup"):
			dialogue.setup(brain, economy)

	# Create scene node (or logic node)
	var scene_node: Node3D = _create_npc_scene_node(npc_id, spawn_pos)

	# Attach sub-systems
	if scene_node:
		scene_node.add_child(brain)
		scene_node.add_child(dialogue)
		if economy:
			scene_node.add_child(economy)
		get_tree().root.add_child(scene_node)

	# Register
	active_npcs[npc_id] = {
		"brain":      brain,
		"dialogue":   dialogue,
		"economy":    economy,
		"scene_node": scene_node,
		"district":   district_id,
		"lod_level":  0,
		"position":   spawn_pos,
	}

	district["npcs"].append(npc_id)
	emit_signal("npc_spawned", npc_id, district_id)
	return npc_id

func _create_npc_scene_node(npc_id: String, position: Vector3) -> Node3D:
	if _use_scene_instances and _npc_scene != null:
		var instance = _npc_scene.instantiate()
		if "npc_id" in instance:
			instance.npc_id = npc_id
		instance.position = position
		instance.name = "NPC_" + npc_id
		return instance
	else:
		# Lightweight stand-in for pure-logic mode
		var node = Node3D.new()
		node.name = "NPC_" + npc_id
		node.position = position
		return node

func despawn_npc(npc_id: String) -> void:
	if not active_npcs.has(npc_id):
		return
	var record = active_npcs[npc_id]
	var district_id: String = record.get("district", "")

	if record.get("scene_node") != null:
		record["scene_node"].queue_free()

	if districts.has(district_id):
		districts[district_id]["npcs"].erase(npc_id)

	active_npcs.erase(npc_id)
	emit_signal("npc_despawned", npc_id)

func despawn_all_in_district(district_id: String) -> void:
	if not districts.has(district_id):
		return
	var npc_list: Array = districts[district_id]["npcs"].duplicate()
	for npc_id in npc_list:
		despawn_npc(npc_id)

# ─────────────────────────────────────────────────────────────────────────────
# LOD System
# ─────────────────────────────────────────────────────────────────────────────

## LOD levels:
##  0 = full AI (within full_ai_radius)
##  1 = simplified AI (within simplified_ai_radius)
##  2 = inactive / schedule-only (beyond simplified_ai_radius)
##  3 = despawned (beyond despawn_radius)

func _update_lod(delta: float) -> void:
	_lod_update_timer += delta
	if _lod_update_timer < LOD_UPDATE_INTERVAL:
		return
	_lod_update_timer = 0.0

	if player_node == null:
		return

	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		var npc_pos: Vector3 = _get_npc_position(record)
		var dist: float = player_position.distance_to(npc_pos)

		var new_lod: int = _calculate_lod(dist)
		if new_lod != record.get("lod_level", 0):
			record["lod_level"] = new_lod
			_apply_lod(npc_id, record, new_lod)
			emit_signal("lod_updated", npc_id, new_lod)

func _calculate_lod(distance: float) -> int:
	if distance <= full_ai_radius:
		return 0
	elif distance <= simplified_ai_radius:
		return 1
	elif distance <= despawn_radius:
		return 2
	else:
		return 3

func _apply_lod(npc_id: String, record: Dictionary, lod_level: int) -> void:
	var brain = record.get("brain")
	var scene_node = record.get("scene_node")

	match lod_level:
		0:
			# Full AI — enable all processing
			if brain and brain.has_method("set_lod_simplified"):
				brain.set_lod_simplified(false)
			if brain:
				brain.set_process(true)
			if scene_node:
				scene_node.visible = true
				scene_node.set_process(true)
				scene_node.set_physics_process(true)
		1:
			# Simplified AI — brain runs but less frequently
			if brain and brain.has_method("set_lod_simplified"):
				brain.set_lod_simplified(true)
			if brain:
				brain.set_process(true)
			if scene_node:
				scene_node.visible = true
				scene_node.set_physics_process(false)
		2:
			# Schedule only — brain ticks but no physics/rendering
			if brain and brain.has_method("set_lod_simplified"):
				brain.set_lod_simplified(true)
			if brain:
				brain.set_process(true)
			if scene_node:
				scene_node.visible = false
				scene_node.set_process(false)
				scene_node.set_physics_process(false)
		3:
			# Despawn
			despawn_npc(npc_id)

func _get_npc_position(record: Dictionary) -> Vector3:
	var scene_node = record.get("scene_node")
	if scene_node and scene_node is Node3D:
		return scene_node.global_position
	return record.get("position", Vector3.ZERO)

# ─────────────────────────────────────────────────────────────────────────────
# Day/Night Cycle
# ─────────────────────────────────────────────────────────────────────────────

func _advance_time(delta: float) -> void:
	_time_accumulator += delta
	if _time_accumulator >= game_time_speed:
		_time_accumulator -= game_time_speed
		current_game_hour = fmod(current_game_hour + 1.0, 24.0)
		_on_hour_changed()

func _on_hour_changed() -> void:
	var was_daytime: bool = is_daytime
	is_daytime = current_game_hour >= DAWN_HOUR and current_game_hour < DUSK_HOUR

	if is_daytime != was_daytime:
		emit_signal("day_cycle_changed", is_daytime)
		if is_daytime:
			_on_dawn()
		else:
			_on_dusk()

	# Push time update to all NPC brains
	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		var brain = record.get("brain")
		if brain and brain.has_method("update_time"):
			brain.update_time(current_game_hour)
		var economy = record.get("economy")
		if economy and economy.has_method("set_time"):
			economy.set_time(current_game_hour)

func _on_dawn() -> void:
	print("[NPCSpawner] Dawn — NPCs returning to daytime schedules.")
	# Spawn any districts that went below minimum at night
	for district_id in districts.keys():
		var district = districts[district_id]
		if district["npcs"].size() < min_npcs_per_district:
			var deficit: int = min_npcs_per_district - district["npcs"].size()
			for i in range(deficit):
				_spawn_npc_in_district(district_id)

func _on_dusk() -> void:
	print("[NPCSpawner] Dusk — NPCs transitioning to night schedules.")
	# Some NPCs leave at night — reduce to 60% of daytime population
	for district_id in districts.keys():
		if district_id == "underground":
			continue   # underground doesn't empty at night
		var district = districts[district_id]
		var target_night: int = int(district["npcs"].size() * 0.6)
		var to_remove: int = district["npcs"].size() - target_night
		var npc_list = district["npcs"].duplicate()
		npc_list.shuffle()
		for i in range(mini(to_remove, npc_list.size())):
			despawn_npc(npc_list[i])

func set_game_hour(hour: float) -> void:
	current_game_hour = fmod(hour, 24.0)
	is_daytime = current_game_hour >= DAWN_HOUR and current_game_hour < DUSK_HOUR
	_on_hour_changed()

func get_game_hour() -> float:
	return current_game_hour

func set_time_speed(real_seconds_per_game_hour: float) -> void:
	game_time_speed = maxf(1.0, real_seconds_per_game_hour)

# ─────────────────────────────────────────────────────────────────────────────
# Event NPC System (FOMO Zones)
# ─────────────────────────────────────────────────────────────────────────────

func spawn_event_npcs(event_name: String, district_id: String,
		npc_count: int = 10, duration_hours: float = 4.0) -> void:
	if not districts.has(district_id):
		push_warning("[NPCSpawner] Cannot spawn event NPCs: unknown district " + district_id)
		return

	var spawned_ids: Array = []

	for i in range(npc_count):
		var archetype = EVENT_ARCHETYPES[i % EVENT_ARCHETYPES.size()]
		var npc_id: String = _spawn_event_npc(district_id, archetype, event_name)
		spawned_ids.append(npc_id)

		# Notify brain of the active event
		var brain = active_npcs[npc_id].get("brain") if active_npcs.has(npc_id) else null
		if brain and brain.has_method("register_faction_event"):
			brain.register_faction_event({
				"name": event_name,
				"type": "fomo_zone",
				"faction": "civilian",
				"district": district_id,
			})

	event_npc_pools[event_name] = spawned_ids

	active_events.append({
		"name": event_name,
		"district": district_id,
		"duration_hours": duration_hours,
		"start_hour": current_game_hour,
		"npc_ids": spawned_ids,
	})

	# Force shops open during event
	for npc_id in spawned_ids:
		var economy = active_npcs[npc_id].get("economy") if active_npcs.has(npc_id) else null
		if economy and "special_event_open" in economy:
			economy.special_event_open = true

	emit_signal("event_npcs_spawned", event_name, npc_count)
	print("[NPCSpawner] Event '", event_name, "' spawned ", npc_count, " NPCs in district '", district_id, "'.")

func _spawn_event_npc(district_id: String, archetype: Dictionary, event_name: String) -> String:
	var occupation: String = archetype.get("occupation", "civilian")
	var faction: String = archetype.get("faction", "civilian")
	var role: String = archetype.get("role", "event_npc")

	var district = districts[district_id]
	var spawn_pos: Vector3 = _pick_spawn_point(district)
	var npc_id: String = _generate_npc_id()

	var brain = NPCBrain.new() if _class_exists("NPCBrain") else Node.new()
	brain.name = "Brain_" + npc_id
	if brain.has_method("randomize_personality"):
		brain.randomize_personality()
	if "occupation" in brain:
		brain.occupation = occupation
	if "faction" in brain:
		brain.faction = faction
	if "home_district" in brain:
		brain.home_district = district_id
	if "trait_friendliness" in brain:
		brain.trait_friendliness = 0.8   # event NPCs are more sociable

	var dialogue = NPCDialogue.new() if _class_exists("NPCDialogue") else Node.new()
	dialogue.name = "Dialogue_" + npc_id

	var economy: Node = null
	if occupation in ["street_vendor", "merchant", "fixer"]:
		economy = NPCEconomy.new() if _class_exists("NPCEconomy") else Node.new()
		economy.name = "Economy_" + npc_id
		if "shop_owner_id" in economy:
			economy.shop_owner_id = npc_id
		if "district" in economy:
			economy.district = district_id
		if "shop_type" in economy:
			economy.shop_type = "general"

	if dialogue.has_method("setup"):
		dialogue.setup(brain, economy)

	var scene_node: Node3D = _create_npc_scene_node(npc_id, spawn_pos)
	if scene_node:
		scene_node.add_child(brain)
		scene_node.add_child(dialogue)
		if economy:
			scene_node.add_child(economy)
		get_tree().root.add_child(scene_node)

	active_npcs[npc_id] = {
		"brain":      brain,
		"dialogue":   dialogue,
		"economy":    economy,
		"scene_node": scene_node,
		"district":   district_id,
		"lod_level":  0,
		"position":   spawn_pos,
		"is_event_npc": true,
		"event_name": event_name,
	}

	district["npcs"].append(npc_id)
	return npc_id

func clear_event_npcs(event_name: String) -> void:
	if not event_npc_pools.has(event_name):
		return

	var npc_list: Array = event_npc_pools[event_name].duplicate()
	for npc_id in npc_list:
		despawn_npc(npc_id)

	event_npc_pools.erase(event_name)

	for i in range(active_events.size() - 1, -1, -1):
		if active_events[i].get("name", "") == event_name:
			active_events.remove_at(i)

	emit_signal("event_npcs_cleared", event_name)
	print("[NPCSpawner] Cleared event NPCs for '", event_name, "'.")

func _check_event_expirations() -> void:
	for i in range(active_events.size() - 1, -1, -1):
		var event = active_events[i]
		var start: float = event.get("start_hour", 0.0)
		var duration: float = event.get("duration_hours", 4.0)
		var elapsed: float = fmod(current_game_hour - start + 24.0, 24.0)
		if elapsed >= duration:
			clear_event_npcs(event.get("name", ""))

# ─────────────────────────────────────────────────────────────────────────────
# Gossip Exchange
# ─────────────────────────────────────────────────────────────────────────────

func _run_gossip_tick(delta: float) -> void:
	_gossip_timer += delta
	if _gossip_timer < GOSSIP_INTERVAL:
		return
	_gossip_timer = 0.0
	_perform_gossip_exchange()

func _perform_gossip_exchange() -> void:
	var npc_ids: Array = active_npcs.keys()
	if npc_ids.size() < 2:
		return

	# Randomly pick pairs of nearby NPCs to gossip
	npc_ids.shuffle()
	var pair_count: int = mini(5, npc_ids.size() / 2)
	for i in range(pair_count):
		var id_a: String = npc_ids[i * 2]
		var id_b: String = npc_ids[i * 2 + 1]

		var record_a = active_npcs.get(id_a, {})
		var record_b = active_npcs.get(id_b, {})

		var pos_a: Vector3 = _get_npc_position(record_a)
		var pos_b: Vector3 = _get_npc_position(record_b)

		if pos_a.distance_to(pos_b) > 20.0:
			continue   # too far apart for gossip

		var dialogue_a = record_a.get("dialogue")
		var dialogue_b = record_b.get("dialogue")

		if dialogue_a and dialogue_a.has_method("share_gossip_with_npc") and dialogue_b:
			dialogue_a.share_gossip_with_npc(dialogue_b)
		if dialogue_b and dialogue_b.has_method("share_gossip_with_npc") and dialogue_a:
			dialogue_b.share_gossip_with_npc(dialogue_a)

# ─────────────────────────────────────────────────────────────────────────────
# Economy Trade Tick
# ─────────────────────────────────────────────────────────────────────────────

func _run_economy_trade_tick(delta: float) -> void:
	_economy_trade_timer += delta
	if _economy_trade_timer < ECONOMY_TRADE_INTERVAL:
		return
	_economy_trade_timer = 0.0
	_perform_npc_economy_trades()

func _perform_npc_economy_trades() -> void:
	var merchants: Array = []
	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		if record.get("economy") != null:
			merchants.append(record)

	if merchants.size() < 2:
		return

	merchants.shuffle()
	var trade_pairs: int = mini(3, merchants.size() / 2)
	for i in range(trade_pairs):
		var econ_a = merchants[i * 2].get("economy")
		var econ_b = merchants[i * 2 + 1].get("economy")
		if econ_a and econ_a.has_method("initiate_npc_trade") and econ_b:
			econ_a.initiate_npc_trade(econ_b)

# ─────────────────────────────────────────────────────────────────────────────
# Player Tracking
# ─────────────────────────────────────────────────────────────────────────────

func set_player(p: Node3D) -> void:
	player_node = p

func _update_player_position() -> void:
	if player_node != null and player_node is Node3D:
		player_position = player_node.global_position
		_update_nearby_player_counts()

func _update_nearby_player_counts() -> void:
	for district_id in districts.keys():
		var district = districts[district_id]
		var center: Vector3 = district.get("center", Vector3.ZERO)
		var radius: float = district.get("radius", 50.0)
		var player_nearby: bool = player_position.distance_to(center) <= radius

		for npc_id in district.get("npcs", []):
			var record = active_npcs.get(npc_id, {})
			var economy = record.get("economy")
			if economy and economy.has_method("set_nearby_player_count"):
				economy.set_nearby_player_count(1 if player_nearby else 0)

# ─────────────────────────────────────────────────────────────────────────────
# Interact With NPC
# ─────────────────────────────────────────────────────────────────────────────

func get_nearest_npc(from_position: Vector3, max_distance: float = 5.0) -> String:
	var nearest_id: String = ""
	var nearest_dist: float = max_distance + 1.0

	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		var npc_pos: Vector3 = _get_npc_position(record)
		var dist: float = from_position.distance_to(npc_pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = npc_id

	return nearest_id

func player_interact_with_npc(npc_id: String, player_id: String, player_node_ref: Node) -> bool:
	if not active_npcs.has(npc_id):
		return false

	var record = active_npcs[npc_id]
	var brain = record.get("brain")
	var dialogue = record.get("dialogue")

	if brain and brain.has_method("on_player_interaction"):
		brain.on_player_interaction(player_id, player_node_ref)

	if dialogue and dialogue.has_method("begin_dialogue"):
		dialogue.begin_dialogue(player_id, player_node_ref)
		return true

	return false

func get_npc_brain(npc_id: String) -> Node:
	if not active_npcs.has(npc_id):
		return null
	return active_npcs[npc_id].get("brain")

func get_npc_dialogue(npc_id: String) -> Node:
	if not active_npcs.has(npc_id):
		return null
	return active_npcs[npc_id].get("dialogue")

func get_npc_economy(npc_id: String) -> Node:
	if not active_npcs.has(npc_id):
		return null
	return active_npcs[npc_id].get("economy")

# ─────────────────────────────────────────────────────────────────────────────
# Weather Broadcast
# ─────────────────────────────────────────────────────────────────────────────

func broadcast_weather(weather: String) -> void:
	for npc_id in active_npcs.keys():
		var brain = active_npcs[npc_id].get("brain")
		if brain and brain.has_method("update_weather"):
			brain.update_weather(weather)

# ─────────────────────────────────────────────────────────────────────────────
# Faction Events
# ─────────────────────────────────────────────────────────────────────────────

func broadcast_faction_event(event: Dictionary, district_id: String = "") -> void:
	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		if district_id != "" and record.get("district", "") != district_id:
			continue
		var brain = record.get("brain")
		if brain and brain.has_method("register_faction_event"):
			brain.register_faction_event(event)

func clear_faction_events(district_id: String = "") -> void:
	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		if district_id != "" and record.get("district", "") != district_id:
			continue
		var brain = record.get("brain")
		if brain and brain.has_method("clear_faction_events"):
			brain.clear_faction_events()

# ─────────────────────────────────────────────────────────────────────────────
# Statistics
# ─────────────────────────────────────────────────────────────────────────────

func get_spawn_stats() -> Dictionary:
	var total_npcs: int = active_npcs.size()
	var by_district: Dictionary = {}
	var by_lod: Dictionary = {0: 0, 1: 0, 2: 0}
	var merchants: int = 0
	var event_npcs: int = 0

	for npc_id in active_npcs.keys():
		var record = active_npcs[npc_id]
		var district_id: String = record.get("district", "unknown")
		by_district[district_id] = by_district.get(district_id, 0) + 1
		var lod: int = record.get("lod_level", 0)
		by_lod[lod] = by_lod.get(lod, 0) + 1
		if record.get("economy") != null:
			merchants += 1
		if record.get("is_event_npc", false):
			event_npcs += 1

	return {
		"total": total_npcs,
		"by_district": by_district,
		"by_lod": by_lod,
		"merchants": merchants,
		"event_npcs": event_npcs,
		"is_daytime": is_daytime,
		"game_hour": current_game_hour,
		"active_events": active_events.size(),
	}

func get_district_info(district_id: String) -> Dictionary:
	if not districts.has(district_id):
		return {}
	var d = districts[district_id]
	return {
		"id": district_id,
		"name": d.get("name", ""),
		"type": d.get("type", ""),
		"npc_count": d.get("npcs", []).size(),
		"target_count": d.get("target_npc_count", 0),
	}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Occupation / Faction / Shop Selection
# ─────────────────────────────────────────────────────────────────────────────

func _pick_occupation_for_district(district_type: String) -> String:
	var pool: Array = DISTRICT_OCCUPATIONS.get(district_type, ["civilian"])
	return pool[randi() % pool.size()]

func _pick_faction_for_district(district_type: String) -> String:
	match district_type:
		"corporate":   return "nexus_corp"
		"underground": return "shadow_syndicate"
		"industrial":  return "street_runners"
		_:             return "civilian"

func _pick_shop_type(occupation: String) -> String:
	match occupation:
		"merchant", "shopkeeper": return "general"
		"street_vendor":          return "food"
		"bartender":              return "food"
		"smuggler", "shadow_dealer": return "black_market"
		"fixer":                  return "general"
		_:                        return "general"

func _pick_spawn_point(district: Dictionary) -> Vector3:
	var points: Array = district.get("spawn_points", [])
	if points.is_empty():
		var center: Vector3 = district.get("center", Vector3.ZERO)
		var radius: float = district.get("radius", 30.0)
		var angle: float = randf() * PI * 2.0
		var dist: float = randf_range(5.0, radius * 0.8)
		return center + Vector3(cos(angle) * dist, 0, sin(angle) * dist)
	return points[randi() % points.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────────

func _generate_npc_id() -> String:
	_npc_id_counter += 1
	return "npc_" + str(_npc_id_counter).pad_zeros(5)

func _try_load_npc_scene() -> void:
	if ResourceLoader.exists(npc_scene_path):
		_npc_scene = load(npc_scene_path)
		_use_scene_instances = true
	else:
		_use_scene_instances = false

func _class_exists(class_name_str: String) -> bool:
	return ClassDB.class_exists(class_name_str)
