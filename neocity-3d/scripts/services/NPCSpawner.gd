## NPCSpawner — Autoload service that instantiates NPCs across the
## procedural cyberpunk city, drives their per-tick AI, implements a
## 3-tier LOD system, day/night scheduling, FOMO event NPCs, and cross-
## NPC gossip + economy ticks.
##
## This is the top-level controller — it owns a dictionary of active
## `NPCBrain` instances keyed by npc_id, an `NPCDialogue` per brain, and
## delegates shops to the `NPCEconomy` autoload.  Avatars (CharacterBody3D
## nodes under `/root/.../NPCRoot`) are optional: if present, the spawner
## drives their `target_position`; if absent, brains still tick "headless".
##
## Public API highlights:
##   • spawn_in_district(district_id, count)
##   • spawn_event_npcs(event, district, count, duration_hours)
##   • get_nearest_npc(position, radius) -> npc_id
##   • player_interact_with_npc(npc_id, player_id, player_node) -> Dictionary
##   • set_world_time(hour)  / set_weather(state)

extends Node

const NPCBrain = preload("res://scripts/ai/NPCBrain.gd")
const NPCDialogue = preload("res://scripts/ai/NPCDialogue.gd")
const _NPCEconomyScript = preload("res://scripts/ai/NPCEconomy.gd")

signal npc_spawned(npc_id: String, district_id: String)
signal npc_despawned(npc_id: String, reason: String)
signal npc_dialogue(npc_id: String, player_id: String, text: String, topic: String)
signal fomo_event_started(event_id: String, district_id: String, npc_count: int)
signal fomo_event_ended(event_id: String)

const LOD_FULL_RADIUS: float = 30.0
const LOD_SIMPLE_RADIUS: float = 80.0
const LOD_SCHEDULE_RADIUS: float = 150.0
const LOD_DESPAWN_RADIUS: float = 250.0

const LOD_FULL: int = 0
const LOD_SIMPLE: int = 1
const LOD_SCHEDULE: int = 2
const LOD_OFFSCREEN: int = 3

const TICK_FULL_HZ: float = 6.0
const TICK_SIMPLE_HZ: float = 2.0
const TICK_SCHEDULE_HZ: float = 0.5
const GOSSIP_TICK_SECS: float = 30.0
const ECONOMY_TICK_SECS: float = 60.0
const LOD_RESCAN_SECS: float = 1.0

const DISTRICT_CENTRAL: String = "central"
const DISTRICT_MARKET: String = "market"
const DISTRICT_INDUSTRIAL: String = "industrial"
const DISTRICT_RESIDENTIAL: String = "residential"
const DISTRICT_UNDERGROUND: String = "underground"
const DISTRICT_CORP: String = "corp"

const _DAWN_HOUR: float = 6.0
const _DUSK_HOUR: float = 20.0
const _DUSK_DESPAWN_RATIO: float = 0.4

# ── Configuration ─────────────────────────────────────────────────────

@export var world_time_speed: float = 60.0  # game seconds per real second
@export var enable_avatars: bool = false      # if true, requires an avatar scene
@export var avatar_scene_path: String = "res://scenes/npc.tscn"
@export var initial_populate_on_ready: bool = false

# ── State ─────────────────────────────────────────────────────────────

var _rng := RandomNumberGenerator.new()

# district_id -> {id, name, type, center, radius, min_npcs, max_npcs,
#                 occupations, factions, color_hex}
var _districts: Dictionary = {}

# npc_id -> { brain, dialogue, avatar (Node|null), lod, last_decision_at,
#             district_id, faction, spawn_kind ("permanent"|"event"),
#             event_id, expires_at }
var _npcs: Dictionary = {}

# event_id -> { id, district_id, started_at, expires_at, npc_ids: [] }
var _events: Dictionary = {}

var _world_hour: float = 12.0
var _world_weather: String = "clear"
var _last_dawn_trigger_day: int = -1
var _last_dusk_trigger_day: int = -1
var _current_day: int = 0

var _economy: Node
var _players: Dictionary = {}  # player_id -> {position, district_id, name}

var _lod_rescan_accum: float = 0.0
var _gossip_accum: float = 0.0
var _economy_accum: float = 0.0
var _tick_full_accum: float = 0.0
var _tick_simple_accum: float = 0.0
var _tick_schedule_accum: float = 0.0


# ── Lifecycle ─────────────────────────────────────────────────────────

func _ready() -> void:
	_rng.randomize()
	_register_default_districts()
	_resolve_economy()
	if initial_populate_on_ready:
		populate_all_districts()
	set_process(true)


func _resolve_economy() -> void:
	var n: Node = get_node_or_null("/root/NPCEconomy")
	if n != null:
		_economy = n
	else:
		# Fall back to a local child instance so the spawner works standalone
		# in isolated test scenes that don't configure the autoload.
		var inst: Node = Node.new()
		inst.set_script(_NPCEconomyScript)
		inst.name = "NPCEconomyLocal"
		add_child(inst)
		_economy = inst


# ── District registry ─────────────────────────────────────────────────

func _register_default_districts() -> void:
	register_district({
		"id": DISTRICT_CENTRAL,
		"name": "Central Plaza",
		"type": "mixed",
		"center": Vector3(0, 0, 0),
		"radius": 90.0,
		"min_npcs": 55,
		"max_npcs": 80,
		"occupations": [
			NPCBrain.OCC_CIVILIAN, NPCBrain.OCC_MERCHANT, NPCBrain.OCC_GUARD,
		],
		"factions": ["neutral", "merchants", "neon_authority"],
	})
	register_district({
		"id": DISTRICT_MARKET,
		"name": "Night Market",
		"type": "commercial",
		"center": Vector3(150, 0, -90),
		"radius": 70.0,
		"min_npcs": 60,
		"max_npcs": 90,
		"occupations": [
			NPCBrain.OCC_MERCHANT, NPCBrain.OCC_BARTENDER, NPCBrain.OCC_CIVILIAN,
		],
		"factions": ["merchants", "neutral", "street_lords"],
	})
	register_district({
		"id": DISTRICT_INDUSTRIAL,
		"name": "Industrial Sector",
		"type": "industrial",
		"center": Vector3(-180, 0, 120),
		"radius": 100.0,
		"min_npcs": 50,
		"max_npcs": 70,
		"occupations": [
			NPCBrain.OCC_CIVILIAN, NPCBrain.OCC_GUARD, NPCBrain.OCC_MERCHANT,
		],
		"factions": ["corp_drones", "street_lords", "neutral"],
	})
	register_district({
		"id": DISTRICT_RESIDENTIAL,
		"name": "Residential Blocks",
		"type": "residential",
		"center": Vector3(60, 0, 200),
		"radius": 120.0,
		"min_npcs": 65,
		"max_npcs": 100,
		"occupations": [
			NPCBrain.OCC_CIVILIAN, NPCBrain.OCC_MERCHANT, NPCBrain.OCC_RIPPERDOC,
		],
		"factions": ["neutral", "merchants"],
	})
	register_district({
		"id": DISTRICT_UNDERGROUND,
		"name": "Underground",
		"type": "underground",
		"center": Vector3(-60, -5, -180),
		"radius": 80.0,
		"min_npcs": 50,
		"max_npcs": 85,
		"occupations": [
			NPCBrain.OCC_HACKER, NPCBrain.OCC_RIPPERDOC, NPCBrain.OCC_BARTENDER,
			NPCBrain.OCC_CIVILIAN,
		],
		"factions": ["netrunners", "street_lords", "neutral"],
	})
	register_district({
		"id": DISTRICT_CORP,
		"name": "Corp Towers",
		"type": "corporate",
		"center": Vector3(220, 0, 220),
		"radius": 90.0,
		"min_npcs": 55,
		"max_npcs": 75,
		"occupations": [
			NPCBrain.OCC_GUARD, NPCBrain.OCC_CIVILIAN, NPCBrain.OCC_MERCHANT,
		],
		"factions": ["corp_drones", "neon_authority"],
	})


func register_district(d: Dictionary) -> void:
	if not d.has("id"):
		return
	_districts[String(d["id"])] = d


func get_district(district_id: String) -> Dictionary:
	return _districts.get(district_id, {})


# ── Population ────────────────────────────────────────────────────────

func populate_all_districts() -> void:
	for id in _districts.keys():
		var d: Dictionary = _districts[id]
		var target: int = _rng.randi_range(int(d["min_npcs"]), int(d["max_npcs"]))
		spawn_in_district(String(id), target)


func spawn_in_district(district_id: String, count: int) -> Array:
	var d: Dictionary = _districts.get(district_id, {})
	if d.is_empty() or count <= 0:
		return []
	var spawned: Array = []
	var occupations: Array = d.get("occupations", [NPCBrain.OCC_CIVILIAN])
	var factions: Array = d.get("factions", ["neutral"])
	for i in range(count):
		var occ: String = String(occupations[_rng.randi_range(0, occupations.size() - 1)])
		var fac: String = String(factions[_rng.randi_range(0, factions.size() - 1)])
		var pos: Vector3 = _random_point_in_district(d)
		var npc_id: String = _spawn_one("permanent", district_id, occ, fac, pos)
		if npc_id != "":
			spawned.append(npc_id)
	return spawned


func _spawn_one(kind: String, district_id: String, occupation: String, faction: String, pos: Vector3, event_id: String = "", expires_at: float = 0.0) -> String:
	var npc_id: String = "npc_%s_%d_%d" % [district_id, Time.get_ticks_msec(), _rng.randi()]
	var display_name: String = _random_name(occupation)
	var brain := NPCBrain.new(npc_id, display_name, occupation)
	brain.faction = faction
	brain.home_district = district_id
	brain.home_position = pos
	brain.current_position = pos
	brain.world_time_hour = _world_hour
	brain.weather_state = _world_weather
	var dialogue := NPCDialogue.new(brain)

	var avatar: Node = null
	if enable_avatars:
		avatar = _spawn_avatar(pos)

	_npcs[npc_id] = {
		"brain": brain,
		"dialogue": dialogue,
		"avatar": avatar,
		"lod": LOD_SCHEDULE,
		"last_decision_at": 0.0,
		"district_id": district_id,
		"faction": faction,
		"spawn_kind": kind,
		"event_id": event_id,
		"expires_at": expires_at,
	}

	if _economy != null and _economy.has_method("auto_attach_shop_by_occupation"):
		_economy.auto_attach_shop_by_occupation(npc_id, occupation, district_id)

	npc_spawned.emit(npc_id, district_id)
	return npc_id


func _spawn_avatar(pos: Vector3) -> Node:
	if avatar_scene_path.is_empty():
		return null
	if not ResourceLoader.exists(avatar_scene_path):
		return null
	var packed: PackedScene = load(avatar_scene_path)
	if packed == null:
		return null
	var inst: Node = packed.instantiate()
	if inst is Node3D:
		(inst as Node3D).global_position = pos
	add_child(inst)
	return inst


func despawn(npc_id: String, reason: String = "generic") -> void:
	if not _npcs.has(npc_id):
		return
	var rec: Dictionary = _npcs[npc_id]
	var avatar = rec.get("avatar", null)
	if avatar != null and is_instance_valid(avatar):
		avatar.queue_free()
	if _economy != null and _economy.has_method("detach_shop"):
		_economy.detach_shop(npc_id)
	_npcs.erase(npc_id)
	npc_despawned.emit(npc_id, reason)


func _random_point_in_district(d: Dictionary) -> Vector3:
	var center: Vector3 = d.get("center", Vector3.ZERO)
	var radius: float = float(d.get("radius", 50.0))
	var angle: float = _rng.randf() * TAU
	var r: float = sqrt(_rng.randf()) * radius  # uniform over disk
	return center + Vector3(cos(angle) * r, 0.0, sin(angle) * r)


const _FIRST_NAMES: Array = [
	"Kai", "Ren", "Nova", "Jax", "Vex", "Lyra", "Orion", "Zara",
	"Echo", "Raven", "Silas", "Mira", "Axel", "Nyx", "Drax", "Kira",
	"Tez", "Yuki", "Cass", "Blaze", "Quinn", "Wren", "Ash", "Indra",
]
const _LAST_NAMES: Array = [
	"Kuro", "Silver", "Wire", "Neon", "Vance", "Steel", "Cipher", "Volt",
	"Rook", "Circuit", "Static", "Ronin", "Ghost", "Drift", "Echo", "Zero",
]
const _OCC_TITLES: Dictionary = {
	"civilian": "",
	"merchant": "the Vendor",
	"guard": "the Guard",
	"ripperdoc": "the Ripper",
	"bartender": "the Pourer",
	"hacker": "the Netrunner",
}


func _random_name(occupation: String) -> String:
	var first: String = _FIRST_NAMES[_rng.randi_range(0, _FIRST_NAMES.size() - 1)]
	var last: String = _LAST_NAMES[_rng.randi_range(0, _LAST_NAMES.size() - 1)]
	var title: String = String(_OCC_TITLES.get(occupation, ""))
	if title.is_empty():
		return "%s %s" % [first, last]
	return "%s %s, %s" % [first, last, title]


# ── FOMO event NPCs ───────────────────────────────────────────────────

const _EVENT_ARCHETYPES: Dictionary = {
	"vendor": {"occupation": "merchant", "faction": "merchants"},
	"guard": {"occupation": "guard", "faction": "neon_authority"},
	"dancer": {"occupation": "civilian", "faction": "neutral"},
	"reporter": {"occupation": "civilian", "faction": "neutral"},
	"medic": {"occupation": "ripperdoc", "faction": "neutral"},
}


func spawn_event_npcs(event_id: String, district_id: String, count: int, duration_hours: float) -> Array:
	var d: Dictionary = _districts.get(district_id, {})
	if d.is_empty() or count <= 0 or duration_hours <= 0.0:
		return []
	var expires_at: float = Time.get_unix_time_from_system() + duration_hours * 3600.0
	var archetype_keys: Array = _EVENT_ARCHETYPES.keys()
	var ids: Array = []
	for i in range(count):
		var arch_key: String = String(archetype_keys[_rng.randi_range(0, archetype_keys.size() - 1)])
		var arch: Dictionary = _EVENT_ARCHETYPES[arch_key]
		var pos: Vector3 = _random_point_in_district(d)
		var npc_id: String = _spawn_one(
			"event", district_id,
			String(arch["occupation"]), String(arch["faction"]),
			pos, event_id, expires_at,
		)
		if npc_id != "":
			ids.append(npc_id)
			# Event vendors keep shops open around the clock.
			if _economy != null and _economy.has_method("get_shop"):
				var shop: Dictionary = _economy.get_shop(npc_id)
				if not shop.is_empty():
					shop["force_open"] = true
	_events[event_id] = {
		"id": event_id,
		"district_id": district_id,
		"started_at": Time.get_unix_time_from_system(),
		"expires_at": expires_at,
		"npc_ids": ids,
	}
	fomo_event_started.emit(event_id, district_id, ids.size())
	return ids


func _clear_expired_events() -> void:
	var now: float = Time.get_unix_time_from_system()
	var to_end: Array = []
	for eid in _events.keys():
		var ev: Dictionary = _events[eid]
		if float(ev["expires_at"]) <= now:
			to_end.append(eid)
	for eid in to_end:
		var ev: Dictionary = _events[eid]
		for nid in ev["npc_ids"]:
			despawn(String(nid), "event_ended")
		_events.erase(eid)
		fomo_event_ended.emit(String(eid))


# ── World time / weather ──────────────────────────────────────────────

func set_world_time(hour: float) -> void:
	_world_hour = fposmod(hour, 24.0)


func set_weather(state: String) -> void:
	_world_weather = state


func is_night() -> bool:
	return _world_hour < _DAWN_HOUR or _world_hour >= _DUSK_HOUR


# ── Player registry (used for LOD + district demand + engage) ─────────

func register_player(player_id: String, player_name: String, position: Vector3) -> void:
	_players[player_id] = {
		"player_id": player_id,
		"name": player_name,
		"position": position,
		"district_id": _district_containing(position),
	}
	_refresh_district_demand()


func update_player_position(player_id: String, position: Vector3) -> void:
	if not _players.has(player_id):
		return
	var rec: Dictionary = _players[player_id]
	rec["position"] = position
	rec["district_id"] = _district_containing(position)
	_players[player_id] = rec


func unregister_player(player_id: String) -> void:
	_players.erase(player_id)
	_refresh_district_demand()


func _district_containing(position: Vector3) -> String:
	for id in _districts.keys():
		var d: Dictionary = _districts[id]
		var c: Vector3 = d.get("center", Vector3.ZERO)
		var r: float = float(d.get("radius", 0.0))
		if c.distance_to(position) <= r:
			return String(id)
	return ""


func _refresh_district_demand() -> void:
	var counts: Dictionary = {}
	for pid in _players.keys():
		var did: String = String(_players[pid].get("district_id", ""))
		if did == "":
			continue
		counts[did] = int(counts.get(did, 0)) + 1
	if _economy == null:
		return
	for id in _districts.keys():
		_economy.set_district_player_count(String(id), int(counts.get(id, 0)))


# ── Interaction ───────────────────────────────────────────────────────

func player_interact_with_npc(npc_id: String, player_id: String, player_node = null, player_text: String = "") -> Dictionary:
	if not _npcs.has(npc_id):
		return {"ok": false, "reason": "no_such_npc"}
	if not _players.has(player_id):
		# Accept interaction even without registration, derive name from node.
		var fallback_name: String = ""
		if player_node != null and "name" in player_node:
			fallback_name = String(player_node.name)
		register_player(player_id, fallback_name, Vector3.ZERO)
	var player_name: String = String(_players[player_id].get("name", player_id))
	var dialogue = _npcs[npc_id]["dialogue"]
	var out: Dictionary = dialogue.generate(player_id, player_name, player_text)
	out["npc_id"] = npc_id
	out["ok"] = true
	npc_dialogue.emit(npc_id, player_id, String(out["text"]), String(out["topic"]))
	return out


func get_nearest_npc(position: Vector3, radius: float = 5.0) -> String:
	var best: String = ""
	var best_d: float = radius
	for nid in _npcs.keys():
		var brain = _npcs[nid]["brain"]
		var d: float = brain.current_position.distance_to(position)
		if d < best_d:
			best_d = d
			best = nid
	return best


func get_npcs_in_radius(position: Vector3, radius: float) -> Array:
	var out: Array = []
	for nid in _npcs.keys():
		var brain = _npcs[nid]["brain"]
		if brain.current_position.distance_to(position) <= radius:
			out.append(nid)
	return out


# ── LOD evaluation ────────────────────────────────────────────────────

func _compute_lod_for(npc_pos: Vector3) -> int:
	if _players.is_empty():
		return LOD_SCHEDULE
	var nearest: float = INF
	for pid in _players.keys():
		var d: float = npc_pos.distance_to(_players[pid]["position"])
		if d < nearest:
			nearest = d
	if nearest <= LOD_FULL_RADIUS:
		return LOD_FULL
	if nearest <= LOD_SIMPLE_RADIUS:
		return LOD_SIMPLE
	if nearest <= LOD_SCHEDULE_RADIUS:
		return LOD_SCHEDULE
	return LOD_OFFSCREEN


func _rescan_lod() -> void:
	var offscreen_ids: Array = []
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		var brain = rec["brain"]
		var lod: int = _compute_lod_for(brain.current_position)
		rec["lod"] = lod
		if lod == LOD_OFFSCREEN:
			# Permanent NPCs stay alive; event NPCs past their window die.
			var kind: String = String(rec.get("spawn_kind", "permanent"))
			var avatar = rec.get("avatar", null)
			if avatar != null and is_instance_valid(avatar):
				avatar.queue_free()
				rec["avatar"] = null
			if kind == "event":
				if float(rec.get("expires_at", 0.0)) <= Time.get_unix_time_from_system():
					offscreen_ids.append(nid)
		else:
			if enable_avatars and rec.get("avatar", null) == null:
				rec["avatar"] = _spawn_avatar(brain.current_position)
		_npcs[nid] = rec
	for nid in offscreen_ids:
		despawn(nid, "offscreen_expired")


# ── AI tick ───────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# Advance in-game clock.
	var hour_delta: float = delta * world_time_speed / 3600.0
	var prev_hour: float = _world_hour
	_world_hour = fposmod(_world_hour + hour_delta, 24.0)
	if _world_hour < prev_hour:
		_current_day += 1
	_check_day_night_boundaries()
	if _economy != null and _economy.has_method("set_world_is_night"):
		_economy.set_world_is_night(is_night())

	# LOD rescan periodically.
	_lod_rescan_accum += delta
	if _lod_rescan_accum >= LOD_RESCAN_SECS:
		_lod_rescan_accum = 0.0
		_rescan_lod()

	# Mood ticks for all NPCs every frame (cheap).
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		var brain = rec["brain"]
		brain.weather_state = _world_weather
		brain.world_time_hour = _world_hour
		brain.tick_mood(delta)

	# Full LOD: 6 Hz decisions.
	_tick_full_accum += delta
	if _tick_full_accum >= 1.0 / TICK_FULL_HZ:
		_tick_full_accum = 0.0
		_tick_brains_at_lod(LOD_FULL, delta)

	# Simple LOD: 2 Hz.
	_tick_simple_accum += delta
	if _tick_simple_accum >= 1.0 / TICK_SIMPLE_HZ:
		_tick_simple_accum = 0.0
		_tick_brains_at_lod(LOD_SIMPLE, delta)

	# Schedule-only LOD: 0.5 Hz.
	_tick_schedule_accum += delta
	if _tick_schedule_accum >= 1.0 / TICK_SCHEDULE_HZ:
		_tick_schedule_accum = 0.0
		_tick_brains_at_lod(LOD_SCHEDULE, delta)

	# Gossip exchange between nearby NPCs.
	_gossip_accum += delta
	if _gossip_accum >= GOSSIP_TICK_SECS:
		_gossip_accum = 0.0
		_tick_gossip()

	# NPC-NPC economy trades.
	_economy_accum += delta
	if _economy_accum >= ECONOMY_TICK_SECS:
		_economy_accum = 0.0
		_tick_npc_economy()

	# Expire any ended FOMO events.
	_clear_expired_events()


func _tick_brains_at_lod(lod: int, delta: float) -> void:
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		if int(rec["lod"]) != lod:
			continue
		var brain = rec["brain"]
		var dialogue = rec["dialogue"]
		dialogue.tick(delta)
		# Build nearby player context only at FULL LOD (expensive).
		var nearby: Array = []
		if lod == LOD_FULL:
			for pid in _players.keys():
				var p: Dictionary = _players[pid]
				if brain.current_position.distance_to(p["position"]) <= NPCBrain.ENGAGE_RADIUS_METERS:
					nearby.append({
						"player_id": pid,
						"position": p["position"],
					})
		var action: Dictionary = brain.decide(_world_hour, nearby, {}, [])
		_apply_action(nid, rec, action, lod)


func _apply_action(nid: String, rec: Dictionary, action: Dictionary, lod: int) -> void:
	var brain = rec["brain"]
	var kind: String = String(action.get("action", NPCBrain.ACTION_IDLE))
	match kind:
		NPCBrain.ACTION_WANDER, NPCBrain.ACTION_GO_TO, NPCBrain.ACTION_FLEE, NPCBrain.ACTION_GUARD:
			var target: Vector3 = action.get("target_position", brain.current_position)
			_move_toward(brain, target, lod)
		NPCBrain.ACTION_ENGAGE_PLAYER:
			var pid: String = String(action.get("target_id", ""))
			if pid != "" and _players.has(pid):
				var line: Dictionary = rec["dialogue"].generate(pid, String(_players[pid].get("name", "")), "")
				npc_dialogue.emit(nid, pid, String(line["text"]), String(line["topic"]))
		NPCBrain.ACTION_SLEEP:
			# Stay at home position.
			_move_toward(brain, brain.home_position, lod)
		_:
			# idle / work / gossip / celebrate — keep brain in place but animate.
			pass
	rec["last_decision_at"] = Time.get_unix_time_from_system()
	_npcs[nid] = rec


func _move_toward(brain, target: Vector3, lod: int) -> void:
	var step_speed: float = 2.5 if lod == LOD_FULL else (1.8 if lod == LOD_SIMPLE else 0.8)
	# Approximate 1 decision-interval step.
	var dt: float = (1.0 / TICK_FULL_HZ) if lod == LOD_FULL else ((1.0 / TICK_SIMPLE_HZ) if lod == LOD_SIMPLE else (1.0 / TICK_SCHEDULE_HZ))
	var step: float = step_speed * dt
	var to_target: Vector3 = target - brain.current_position
	var dist: float = to_target.length()
	if dist <= step:
		brain.current_position = target
	else:
		brain.current_position = brain.current_position + to_target.normalized() * step


# ── Gossip tick ───────────────────────────────────────────────────────

func _tick_gossip() -> void:
	var ids: Array = _npcs.keys()
	for i in range(ids.size()):
		var a: Dictionary = _npcs[ids[i]]
		if int(a["lod"]) == LOD_OFFSCREEN:
			continue
		for j in range(i + 1, ids.size()):
			var b: Dictionary = _npcs[ids[j]]
			if int(b["lod"]) == LOD_OFFSCREEN:
				continue
			var da: float = a["brain"].current_position.distance_to(b["brain"].current_position)
			if da > 8.0:
				continue
			# Pick a random player known to A, share with B.
			var mem: Array = a["brain"].memory
			if mem.is_empty():
				continue
			var e: Dictionary = mem[_rng.randi_range(0, mem.size() - 1)]
			var pid: String = String(e.get("player_id", ""))
			if pid == "":
				continue
			a["dialogue"].share_gossip_with_npc(pid, b["brain"], b["dialogue"])


# ── NPC ↔ NPC economy tick ────────────────────────────────────────────

func _tick_npc_economy() -> void:
	if _economy == null or not _economy.has_method("initiate_npc_trade"):
		return
	# Find merchant-ish NPCs and pair nearby ones.
	var merchants: Array = []
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		if int(rec["lod"]) == LOD_OFFSCREEN:
			continue
		if _economy.has_method("has_shop") and _economy.has_shop(nid):
			merchants.append(nid)
	for i in range(merchants.size()):
		for j in range(i + 1, merchants.size()):
			var a_id: String = String(merchants[i])
			var b_id: String = String(merchants[j])
			var a = _npcs[a_id]["brain"]
			var b = _npcs[b_id]["brain"]
			if a.current_position.distance_to(b.current_position) > 30.0:
				continue
			# Relationship = avg of both sides' faction relations + random jitter.
			var rel: float = 0.0
			rel += float(a.faction_relations.get(b.faction, 0.0))
			rel += float(b.faction_relations.get(a.faction, 0.0))
			rel = rel * 0.5 + _rng.randf_range(-0.15, 0.15)
			_economy.initiate_npc_trade(a_id, b_id, rel)


# ── Day/night cycle ───────────────────────────────────────────────────

func _check_day_night_boundaries() -> void:
	# Dawn: repopulate districts back up to at least min_npcs.
	if _world_hour >= _DAWN_HOUR and _world_hour < _DAWN_HOUR + 0.5:
		if _last_dawn_trigger_day != _current_day:
			_last_dawn_trigger_day = _current_day
			_dawn_repopulate()
	# Dusk: despawn ~40% of NPCs (except underground).
	if _world_hour >= _DUSK_HOUR and _world_hour < _DUSK_HOUR + 0.5:
		if _last_dusk_trigger_day != _current_day:
			_last_dusk_trigger_day = _current_day
			_dusk_thin_out()


func _dawn_repopulate() -> void:
	for id in _districts.keys():
		var d: Dictionary = _districts[id]
		var min_n: int = int(d.get("min_npcs", 0))
		var current: int = _count_npcs_in_district(String(id), "permanent")
		if current < min_n:
			spawn_in_district(String(id), min_n - current)


func _dusk_thin_out() -> void:
	for id in _districts.keys():
		var d: Dictionary = _districts[id]
		if String(d.get("type", "")) == "underground":
			continue
		var ids_here: Array = []
		for nid in _npcs.keys():
			var rec: Dictionary = _npcs[nid]
			if String(rec["district_id"]) == String(id) and String(rec["spawn_kind"]) == "permanent":
				ids_here.append(nid)
		# Shuffle and despawn the configured dusk ratio.
		ids_here.shuffle()
		var cull: int = int(round(float(ids_here.size()) * _DUSK_DESPAWN_RATIO))
		for i in range(cull):
			despawn(String(ids_here[i]), "dusk")


func _count_npcs_in_district(district_id: String, kind: String = "") -> int:
	var n: int = 0
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		if String(rec["district_id"]) != district_id:
			continue
		if kind != "" and String(rec["spawn_kind"]) != kind:
			continue
		n += 1
	return n


# ── Debug / inspection ────────────────────────────────────────────────

func describe_npc(npc_id: String) -> Dictionary:
	if not _npcs.has(npc_id):
		return {}
	var rec: Dictionary = _npcs[npc_id]
	var s: Dictionary = rec["brain"].snapshot()
	s["lod"] = int(rec["lod"])
	s["spawn_kind"] = rec["spawn_kind"]
	s["district_id"] = rec["district_id"]
	return s


func summary() -> Dictionary:
	var by_district: Dictionary = {}
	var by_lod: Dictionary = {0: 0, 1: 0, 2: 0, 3: 0}
	for nid in _npcs.keys():
		var rec: Dictionary = _npcs[nid]
		var did: String = String(rec["district_id"])
		by_district[did] = int(by_district.get(did, 0)) + 1
		by_lod[int(rec["lod"])] = int(by_lod.get(int(rec["lod"]), 0)) + 1
	return {
		"npcs": _npcs.size(),
		"districts": by_district,
		"by_lod": by_lod,
		"events": _events.size(),
		"hour": _world_hour,
		"weather": _world_weather,
		"players": _players.size(),
	}
