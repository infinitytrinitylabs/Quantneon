## NPCBrain.gd
## Core AI decision system for autonomous NPCs in Neo City.
## Manages personality traits, memory bank, mood, daily schedule, and behavior decisions.

extends Node

# ── Signals ─────────────────────────────────────────────────────────────────

signal behavior_changed(new_behavior: String)
signal mood_changed(new_mood: float)
signal memory_stored(player_id: String, entry: Dictionary)
signal interaction_requested(player: Node)
signal schedule_event_triggered(event_name: String)

# ── Identity ─────────────────────────────────────────────────────────────────

@export var npc_name: String = ""
@export var npc_id: String = ""
@export var faction: String = "civilian"
@export var occupation: String = "civilian"
@export var home_district: String = "central"

# ── Personality Traits (0.0 – 1.0) ──────────────────────────────────────────

@export var trait_friendliness: float = 0.5
@export var trait_curiosity: float = 0.5
@export var trait_aggression: float = 0.1
@export var trait_humor: float = 0.4
@export var trait_wisdom: float = 0.5

# ── Mood ─────────────────────────────────────────────────────────────────────

const MOOD_HAPPY: float      = 1.0
const MOOD_CONTENT: float    = 0.6
const MOOD_NEUTRAL: float    = 0.0
const MOOD_UNEASY: float     = -0.4
const MOOD_ANGRY: float      = -0.8
const MOOD_FEARFUL: float    = -1.0

var current_mood: float = 0.0           # -1.0 (worst) to 1.0 (best)
var mood_label: String = "neutral"
var mood_decay_rate: float = 0.02       # per second, mood drifts toward neutral

# ── Memory Bank ──────────────────────────────────────────────────────────────

const MAX_MEMORY_ENTRIES: int = 50

## Each entry: { player_id, timestamp, topic, detail, sentiment }
var memory_bank: Array = []

## Known player roster: player_id -> { name, last_seen, trust, visits }
var known_players: Dictionary = {}

# ── Behavior State Machine ────────────────────────────────────────────────────

enum Behavior {
	IDLE,
	WANDER,
	WORK,
	ENGAGE_PLAYER,
	REACT_EVENT,
	FLEE,
	PATROL,
	SOCIALIZE,
	REST,
	SHOP,
}

var current_behavior: Behavior = Behavior.IDLE
var previous_behavior: Behavior = Behavior.IDLE
var behavior_timer: float = 0.0
var behavior_duration: float = 10.0    # seconds before re-evaluating

# ── Daily Schedule ────────────────────────────────────────────────────────────

## schedule_entries: Array of { hour_start, hour_end, activity, location_hint }
var daily_schedule: Array = []
var current_schedule_entry: Dictionary = {}

# ── Environment Awareness ────────────────────────────────────────────────────

var nearby_players: Array = []          # Node references
var nearby_npcs: Array = []             # Node references
var current_weather: String = "clear"
var current_hour: float = 12.0         # 0–24 game-time hour
var active_faction_events: Array = []

# ── Faction Relations ────────────────────────────────────────────────────────

## faction_id -> relation_score (-1.0 hostile .. 1.0 allied)
var faction_relations: Dictionary = {
	"civilian":  0.5,
	"nexus_corp": 0.0,
	"shadow_syndicate": -0.3,
	"street_runners": 0.2,
	"ripperdocs": 0.4,
}

# ── Internal ─────────────────────────────────────────────────────────────────

var _update_timer: float = 0.0
var _update_interval: float = 0.5      # AI tick rate (seconds)
var _is_lod_simplified: bool = false   # set by NPCSpawner for distant NPCs
var _interaction_cooldown: float = 0.0
const INTERACTION_COOLDOWN_MAX: float = 30.0

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_generate_identity_if_empty()
	_build_default_schedule()
	_randomize_initial_mood()
	set_process(true)

func _process(delta: float) -> void:
	if _is_lod_simplified:
		_simplified_tick(delta)
		return

	_update_timer += delta
	if _update_timer >= _update_interval:
		_update_timer = 0.0
		_full_ai_tick()

	_decay_mood(delta)
	_tick_behavior_timer(delta)
	_tick_interaction_cooldown(delta)

# ─────────────────────────────────────────────────────────────────────────────
# LOD
# ─────────────────────────────────────────────────────────────────────────────

func set_lod_simplified(simplified: bool) -> void:
	_is_lod_simplified = simplified

func _simplified_tick(delta: float) -> void:
	# Distant NPCs just track schedule without running full decision tree
	_update_schedule_by_time()

# ─────────────────────────────────────────────────────────────────────────────
# Full AI Tick
# ─────────────────────────────────────────────────────────────────────────────

func _full_ai_tick() -> void:
	_update_schedule_by_time()
	_evaluate_mood_from_context()
	_run_decision_tree()

func _run_decision_tree() -> void:
	# Priority-based decision tree
	# 1. React to active events (highest priority)
	if active_faction_events.size() > 0:
		_decide_event_reaction()
		return

	# 2. Threatened by nearby aggressor?
	if _detect_threat():
		_set_behavior(Behavior.FLEE)
		return

	# 3. Nearby player and mood/personality support engagement?
	if nearby_players.size() > 0 and _should_engage_player():
		_set_behavior(Behavior.ENGAGE_PLAYER)
		return

	# 4. Follow daily schedule
	var sched_behavior = _get_schedule_behavior()
	if sched_behavior != Behavior.IDLE:
		_set_behavior(sched_behavior)
		return

	# 5. Personality-driven default
	_decide_personality_default()

func _decide_event_reaction() -> void:
	var event = active_faction_events[0]
	var event_faction: String = event.get("faction", "")
	var relation: float = faction_relations.get(event_faction, 0.0)

	if relation >= 0.3:
		# Allied — participate or cheer
		_set_behavior(Behavior.SOCIALIZE)
	elif relation <= -0.3:
		# Hostile — flee or patrol against
		if trait_aggression >= 0.6:
			_set_behavior(Behavior.PATROL)
		else:
			_set_behavior(Behavior.FLEE)
	else:
		# Neutral — wander away from event
		_set_behavior(Behavior.WANDER)

func _detect_threat() -> bool:
	for npc in nearby_npcs:
		if npc == self:
			continue
		if npc.has_method("get_faction"):
			var their_faction: String = npc.get_faction()
			var rel: float = faction_relations.get(their_faction, 0.0)
			if rel <= -0.5 and npc.has_method("is_aggressive") and npc.is_aggressive():
				return true
	return false

func _should_engage_player() -> bool:
	if _interaction_cooldown > 0.0:
		return false
	# Friendly NPCs engage more readily; high curiosity also increases chance
	var engage_chance = (trait_friendliness * 0.6) + (trait_curiosity * 0.4)
	# Bad mood reduces willingness
	engage_chance += current_mood * 0.2
	return randf() < clampf(engage_chance, 0.0, 1.0)

func _get_schedule_behavior() -> Behavior:
	if current_schedule_entry.is_empty():
		return Behavior.IDLE
	var activity: String = current_schedule_entry.get("activity", "")
	match activity:
		"work":
			return Behavior.WORK
		"rest", "sleep":
			return Behavior.REST
		"shop":
			return Behavior.SHOP
		"socialize":
			return Behavior.SOCIALIZE
		"patrol":
			return Behavior.PATROL
		_:
			return Behavior.IDLE

func _decide_personality_default() -> void:
	# Weight options by personality
	var options: Array = []
	options.append({"behavior": Behavior.WANDER,    "weight": 0.3})
	options.append({"behavior": Behavior.SOCIALIZE,  "weight": trait_friendliness * 0.5})
	options.append({"behavior": Behavior.WORK,       "weight": trait_wisdom * 0.3})
	options.append({"behavior": Behavior.PATROL,     "weight": trait_aggression * 0.2})
	options.append({"behavior": Behavior.IDLE,       "weight": 0.1})

	var total_weight: float = 0.0
	for opt in options:
		total_weight += opt.weight

	var roll: float = randf() * total_weight
	var cumulative: float = 0.0
	for opt in options:
		cumulative += opt.weight
		if roll <= cumulative:
			_set_behavior(opt.behavior)
			return

	_set_behavior(Behavior.WANDER)

# ─────────────────────────────────────────────────────────────────────────────
# Behavior Helpers
# ─────────────────────────────────────────────────────────────────────────────

func _set_behavior(b: Behavior) -> void:
	if b == current_behavior:
		return
	previous_behavior = current_behavior
	current_behavior = b
	behavior_timer = 0.0
	behavior_duration = _get_behavior_duration(b)
	emit_signal("behavior_changed", Behavior.keys()[b])

func _get_behavior_duration(b: Behavior) -> float:
	match b:
		Behavior.WORK:      return randf_range(60.0, 180.0)
		Behavior.REST:      return randf_range(120.0, 300.0)
		Behavior.WANDER:    return randf_range(10.0, 30.0)
		Behavior.SOCIALIZE: return randf_range(15.0, 60.0)
		Behavior.ENGAGE_PLAYER: return randf_range(5.0, 20.0)
		Behavior.FLEE:      return randf_range(8.0, 15.0)
		Behavior.PATROL:    return randf_range(30.0, 90.0)
		Behavior.SHOP:      return randf_range(20.0, 60.0)
		_:                  return randf_range(5.0, 15.0)

func _tick_behavior_timer(delta: float) -> void:
	behavior_timer += delta
	if behavior_timer >= behavior_duration:
		# Force re-evaluation next full tick
		current_behavior = Behavior.IDLE
		behavior_timer = 0.0

func _tick_interaction_cooldown(delta: float) -> void:
	if _interaction_cooldown > 0.0:
		_interaction_cooldown -= delta

# ─────────────────────────────────────────────────────────────────────────────
# Mood System
# ─────────────────────────────────────────────────────────────────────────────

func _randomize_initial_mood() -> void:
	# Friendly NPCs start happier
	current_mood = clampf((trait_friendliness - 0.5) + randf_range(-0.3, 0.3), -1.0, 1.0)
	_update_mood_label()

func _evaluate_mood_from_context() -> void:
	var mood_delta: float = 0.0

	# Weather effects
	match current_weather:
		"clear":       mood_delta += 0.05
		"rain":        mood_delta -= 0.03
		"storm":       mood_delta -= 0.08
		"acid_rain":   mood_delta -= 0.15
		"neon_smog":   mood_delta -= 0.05

	# Time of day effects
	if current_hour >= 6.0 and current_hour <= 18.0:
		mood_delta += 0.02   # daytime slight boost
	else:
		mood_delta -= 0.02   # nighttime slight negative

	# Recent memory sentiment
	var recent_sentiment = _get_recent_memory_sentiment()
	mood_delta += recent_sentiment * 0.1

	# Active hostile events
	for event in active_faction_events:
		var event_type: String = event.get("type", "")
		if event_type == "attack" or event_type == "raid":
			mood_delta -= 0.1

	current_mood = clampf(current_mood + mood_delta, -1.0, 1.0)
	_update_mood_label()
	emit_signal("mood_changed", current_mood)

func _decay_mood(delta: float) -> void:
	if abs(current_mood) < 0.01:
		return
	var direction: float = -1.0 if current_mood > 0.0 else 1.0
	current_mood += direction * mood_decay_rate * delta
	_update_mood_label()

func _update_mood_label() -> void:
	if current_mood >= 0.7:
		mood_label = "happy"
	elif current_mood >= 0.3:
		mood_label = "content"
	elif current_mood >= -0.2:
		mood_label = "neutral"
	elif current_mood >= -0.5:
		mood_label = "uneasy"
	elif current_mood >= -0.8:
		mood_label = "angry"
	else:
		mood_label = "fearful"

func apply_mood_boost(amount: float) -> void:
	current_mood = clampf(current_mood + amount, -1.0, 1.0)
	_update_mood_label()
	emit_signal("mood_changed", current_mood)

func _get_recent_memory_sentiment() -> float:
	if memory_bank.is_empty():
		return 0.0
	var count: int = mini(5, memory_bank.size())
	var total: float = 0.0
	for i in range(memory_bank.size() - count, memory_bank.size()):
		total += memory_bank[i].get("sentiment", 0.0)
	return total / float(count)

# ─────────────────────────────────────────────────────────────────────────────
# Memory System
# ─────────────────────────────────────────────────────────────────────────────

func store_memory(player_id: String, topic: String, detail: String, sentiment: float = 0.0) -> void:
	var entry: Dictionary = {
		"player_id": player_id,
		"timestamp": current_hour,
		"topic": topic,
		"detail": detail,
		"sentiment": clampf(sentiment, -1.0, 1.0),
	}
	memory_bank.append(entry)

	# Trim to max size (FIFO)
	while memory_bank.size() > MAX_MEMORY_ENTRIES:
		memory_bank.pop_front()

	# Update known players registry
	_update_known_player(player_id, sentiment)

	emit_signal("memory_stored", player_id, entry)

func _update_known_player(player_id: String, sentiment: float) -> void:
	if not known_players.has(player_id):
		known_players[player_id] = {
			"name": player_id,
			"last_seen": current_hour,
			"trust": 0.0,
			"visits": 0,
		}
	var record = known_players[player_id]
	record["last_seen"] = current_hour
	record["visits"] = record["visits"] + 1
	record["trust"] = clampf(record["trust"] + sentiment * 0.1, -1.0, 1.0)

func recall_memories_about(player_id: String) -> Array:
	var results: Array = []
	for entry in memory_bank:
		if entry.get("player_id", "") == player_id:
			results.append(entry)
	return results

func recall_latest_memory_about(player_id: String) -> Dictionary:
	var entries = recall_memories_about(player_id)
	if entries.is_empty():
		return {}
	return entries[entries.size() - 1]

func has_met_player(player_id: String) -> bool:
	return known_players.has(player_id)

func get_player_trust(player_id: String) -> float:
	if not known_players.has(player_id):
		return 0.0
	return known_players[player_id].get("trust", 0.0)

func get_memory_count(player_id: String) -> int:
	return recall_memories_about(player_id).size()

func get_all_gossip_data() -> Array:
	## Returns a lightweight copy of memories suitable for NPC-to-NPC gossip
	var gossip: Array = []
	for entry in memory_bank:
		gossip.append({
			"player_id": entry.get("player_id", ""),
			"topic": entry.get("topic", ""),
			"source_npc": npc_id,
		})
	return gossip

func receive_gossip(gossip_entry: Dictionary) -> void:
	var pid: String = gossip_entry.get("player_id", "")
	var topic: String = gossip_entry.get("topic", "gossip")
	var source: String = gossip_entry.get("source_npc", "unknown")
	store_memory(pid, topic, "heard from " + source, 0.0)

# ─────────────────────────────────────────────────────────────────────────────
# Daily Schedule
# ─────────────────────────────────────────────────────────────────────────────

func _build_default_schedule() -> void:
	daily_schedule.clear()
	match occupation:
		"merchant", "shopkeeper":
			daily_schedule = _schedule_merchant()
		"guard", "security":
			daily_schedule = _schedule_guard()
		"ripperdoc":
			daily_schedule = _schedule_ripperdoc()
		"bartender":
			daily_schedule = _schedule_bartender()
		"hacker":
			daily_schedule = _schedule_hacker()
		_:
			daily_schedule = _schedule_civilian()

func _schedule_civilian() -> Array:
	return [
		{"hour_start": 6.0,  "hour_end": 8.0,  "activity": "rest",      "location_hint": "home"},
		{"hour_start": 8.0,  "hour_end": 9.0,  "activity": "socialize",  "location_hint": "cafe"},
		{"hour_start": 9.0,  "hour_end": 17.0, "activity": "work",       "location_hint": "district_work"},
		{"hour_start": 17.0, "hour_end": 19.0, "activity": "shop",       "location_hint": "market"},
		{"hour_start": 19.0, "hour_end": 22.0, "activity": "socialize",  "location_hint": "plaza"},
		{"hour_start": 22.0, "hour_end": 24.0, "activity": "rest",       "location_hint": "home"},
		{"hour_start": 0.0,  "hour_end": 6.0,  "activity": "sleep",      "location_hint": "home"},
	]

func _schedule_merchant() -> Array:
	return [
		{"hour_start": 0.0,  "hour_end": 7.0,  "activity": "sleep",  "location_hint": "home"},
		{"hour_start": 7.0,  "hour_end": 8.0,  "activity": "rest",   "location_hint": "home"},
		{"hour_start": 8.0,  "hour_end": 20.0, "activity": "work",   "location_hint": "shop"},
		{"hour_start": 20.0, "hour_end": 22.0, "activity": "shop",   "location_hint": "market"},
		{"hour_start": 22.0, "hour_end": 24.0, "activity": "rest",   "location_hint": "home"},
	]

func _schedule_guard() -> Array:
	# Two shifts covered; this NPC on day shift
	return [
		{"hour_start": 0.0,  "hour_end": 6.0,  "activity": "sleep",   "location_hint": "barracks"},
		{"hour_start": 6.0,  "hour_end": 18.0, "activity": "patrol",  "location_hint": "patrol_route"},
		{"hour_start": 18.0, "hour_end": 20.0, "activity": "rest",    "location_hint": "barracks"},
		{"hour_start": 20.0, "hour_end": 22.0, "activity": "socialize","location_hint": "barracks_lounge"},
		{"hour_start": 22.0, "hour_end": 24.0, "activity": "sleep",   "location_hint": "barracks"},
	]

func _schedule_ripperdoc() -> Array:
	return [
		{"hour_start": 0.0,  "hour_end": 9.0,  "activity": "sleep",   "location_hint": "home"},
		{"hour_start": 9.0,  "hour_end": 22.0, "activity": "work",    "location_hint": "clinic"},
		{"hour_start": 22.0, "hour_end": 24.0, "activity": "rest",    "location_hint": "home"},
	]

func _schedule_bartender() -> Array:
	return [
		{"hour_start": 0.0,  "hour_end": 4.0,  "activity": "work",    "location_hint": "bar"},
		{"hour_start": 4.0,  "hour_end": 12.0, "activity": "sleep",   "location_hint": "home"},
		{"hour_start": 12.0, "hour_end": 16.0, "activity": "shop",    "location_hint": "market"},
		{"hour_start": 16.0, "hour_end": 24.0, "activity": "work",    "location_hint": "bar"},
	]

func _schedule_hacker() -> Array:
	return [
		{"hour_start": 0.0,  "hour_end": 6.0,  "activity": "work",    "location_hint": "den"},
		{"hour_start": 6.0,  "hour_end": 10.0, "activity": "sleep",   "location_hint": "den"},
		{"hour_start": 10.0, "hour_end": 14.0, "activity": "socialize","location_hint": "plaza"},
		{"hour_start": 14.0, "hour_end": 22.0, "activity": "work",    "location_hint": "den"},
		{"hour_start": 22.0, "hour_end": 24.0, "activity": "socialize","location_hint": "underground"},
	]

func _update_schedule_by_time() -> void:
	for entry in daily_schedule:
		var hs: float = entry.get("hour_start", 0.0)
		var he: float = entry.get("hour_end", 0.0)
		if current_hour >= hs and current_hour < he:
			if current_schedule_entry != entry:
				current_schedule_entry = entry
				emit_signal("schedule_event_triggered", entry.get("activity", "idle"))
			return
	current_schedule_entry = {}

# ─────────────────────────────────────────────────────────────────────────────
# Environment Updates (called by NPCSpawner / WorldManager)
# ─────────────────────────────────────────────────────────────────────────────

func update_time(hour: float) -> void:
	current_hour = fmod(hour, 24.0)

func update_weather(weather: String) -> void:
	current_weather = weather

func update_nearby_players(players: Array) -> void:
	nearby_players = players

func update_nearby_npcs(npcs: Array) -> void:
	nearby_npcs = npcs

func register_faction_event(event: Dictionary) -> void:
	active_faction_events.append(event)

func clear_faction_events() -> void:
	active_faction_events.clear()

# ─────────────────────────────────────────────────────────────────────────────
# Player Interaction Entry Point
# ─────────────────────────────────────────────────────────────────────────────

func on_player_interaction(player_id: String, player_node: Node) -> void:
	_interaction_cooldown = INTERACTION_COOLDOWN_MAX
	store_memory(player_id, "meeting", "player spoke to me", 0.1)
	emit_signal("interaction_requested", player_node)
	apply_mood_boost(trait_friendliness * 0.1)

func on_player_gift(player_id: String, item_name: String) -> void:
	store_memory(player_id, "gift", "gave me " + item_name, 0.3)
	apply_mood_boost(0.2)

func on_player_attack(player_id: String) -> void:
	store_memory(player_id, "attack", "attacked me", -0.8)
	apply_mood_boost(-0.4)
	if known_players.has(player_id):
		known_players[player_id]["trust"] = clampf(
			known_players[player_id]["trust"] - 0.5, -1.0, 1.0
		)

# ─────────────────────────────────────────────────────────────────────────────
# Public Getters
# ─────────────────────────────────────────────────────────────────────────────

func get_personality_summary() -> Dictionary:
	return {
		"friendliness": trait_friendliness,
		"curiosity":    trait_curiosity,
		"aggression":   trait_aggression,
		"humor":        trait_humor,
		"wisdom":       trait_wisdom,
	}

func get_current_behavior_name() -> String:
	return Behavior.keys()[current_behavior]

func get_mood() -> float:
	return current_mood

func get_mood_label() -> String:
	return mood_label

func get_faction() -> String:
	return faction

func is_aggressive() -> bool:
	return trait_aggression >= 0.7 and current_mood <= -0.5

func get_location_hint() -> String:
	return current_schedule_entry.get("location_hint", "wander")

# ─────────────────────────────────────────────────────────────────────────────
# Identity Generation
# ─────────────────────────────────────────────────────────────────────────────

func _generate_identity_if_empty() -> void:
	if npc_name == "":
		npc_name = _random_npc_name()
	if npc_id == "":
		npc_id = npc_name.to_lower().replace(" ", "_") + "_" + str(randi() % 9000 + 1000)
	if occupation == "" or occupation == "civilian":
		occupation = _random_occupation()

func _random_npc_name() -> String:
	var first_names: Array = [
		"Kyra", "Dex", "Nova", "Rynn", "Cipher", "Blaze", "Vera", "Zion",
		"Echo", "Nyx", "Atlas", "Rune", "Coda", "Flux", "Sable", "Vex",
		"Mira", "Jett", "Lyra", "Hex", "Orion", "Kira", "Dante", "Zephyr",
		"Axel", "Crow", "Lace", "Thorn", "Vex", "Nora", "Slate", "Reign",
	]
	var last_names: Array = [
		"Voss", "Kade", "Neon", "Steele", "Cross", "Hollow", "Pierce", "Raven",
		"Storm", "Wire", "Glitch", "Fade", "Ghost", "Byte", "Void", "Spark",
		"Drake", "Shard", "Fuse", "Null", "Hex", "Chrome", "Ash", "Cipher",
	]
	return first_names[randi() % first_names.size()] + " " + last_names[randi() % last_names.size()]

func _random_occupation() -> String:
	var occupations: Array = [
		"civilian", "merchant", "guard", "hacker", "ripperdoc",
		"bartender", "smuggler", "fixer", "courier", "engineer",
		"street_vendor", "info_broker", "medic", "scavenger", "entertainer",
	]
	return occupations[randi() % occupations.size()]

func randomize_personality() -> void:
	trait_friendliness = randf()
	trait_curiosity    = randf()
	trait_aggression   = randf_range(0.0, 0.5)   # cap aggression for most NPCs
	trait_humor        = randf()
	trait_wisdom       = randf()
