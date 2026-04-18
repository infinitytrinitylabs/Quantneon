## NPCBrain — Per-NPC AI core.
##
## Each NPC instance owns one NPCBrain. The brain holds:
##   • Identity (id, name, occupation, faction).
##   • A 5-trait personality vector (friendliness, curiosity, aggression,
##     humor, wisdom), each in [0.0, 1.0].
##   • A persistent memory bank (FIFO, last 50 interactions per NPC) keyed
##     by player_id, recording topic, detail and sentiment.
##   • A mood value in [-1.0, +1.0] that drifts toward 0.0 and is nudged by
##     weather, time-of-day, recent interactions and hostile events.
##   • A per-occupation daily schedule of (activity, location_hint) windows.
##   • A priority-ordered decision tree producing a next Action every tick.
##
## The brain is pure data + pure functions — it does NOT touch the scene
## tree. The NPCSpawner drives ticks and applies resulting actions to a
## CharacterBody3D / NPC avatar; NPCDialogue reads personality + mood +
## memory to generate lines; NPCEconomy reads occupation to attach shops.
##
## All randomness goes through an injectable RNG seed so behavior is
## deterministic in replay / test scenarios.

class_name NPCBrain
extends RefCounted

# ── Constants ──────────────────────────────────────────────────────────

const MEMORY_CAP: int = 50
const TRAIT_COUNT: int = 5
const MOOD_MIN: float = -1.0
const MOOD_MAX: float = 1.0
const MOOD_DECAY_PER_SEC: float = 0.015
const TRUST_THRESHOLD_FRIEND: float = 0.55
const TRUST_THRESHOLD_ENEMY: float = -0.45
const HOSTILE_COOLDOWN_SECS: float = 30.0
const ENGAGE_RADIUS_METERS: float = 6.0
const ENGAGE_COOLDOWN_SECS: float = 12.0
const WANDER_RADIUS_METERS: float = 18.0

# Action tags the spawner / avatar understands.
const ACTION_IDLE: String = "idle"
const ACTION_WANDER: String = "wander"
const ACTION_ENGAGE_PLAYER: String = "engage_player"
const ACTION_WORK: String = "work"
const ACTION_GO_TO: String = "go_to"
const ACTION_FLEE: String = "flee"
const ACTION_GUARD: String = "guard"
const ACTION_CELEBRATE: String = "celebrate"
const ACTION_GOSSIP: String = "gossip"
const ACTION_SLEEP: String = "sleep"

# Occupation catalogue — each maps to a canned daily schedule and
# default shop template in NPCEconomy.
const OCC_CIVILIAN: String = "civilian"
const OCC_MERCHANT: String = "merchant"
const OCC_GUARD: String = "guard"
const OCC_RIPPERDOC: String = "ripperdoc"
const OCC_BARTENDER: String = "bartender"
const OCC_HACKER: String = "hacker"
const OCC_ALL: Array = [
	OCC_CIVILIAN, OCC_MERCHANT, OCC_GUARD,
	OCC_RIPPERDOC, OCC_BARTENDER, OCC_HACKER,
]

# ── Identity ───────────────────────────────────────────────────────────

var id: String = ""
var display_name: String = ""
var occupation: String = OCC_CIVILIAN
var faction: String = "neutral"
var home_district: String = ""
var home_position: Vector3 = Vector3.ZERO
var current_position: Vector3 = Vector3.ZERO

# ── Personality & mood ─────────────────────────────────────────────────

var traits: Dictionary = {
	"friendliness": 0.5,
	"curiosity": 0.5,
	"aggression": 0.2,
	"humor": 0.5,
	"wisdom": 0.5,
}
var mood: float = 0.0
var last_mood_update_secs: float = 0.0

# ── Memory bank ────────────────────────────────────────────────────────
# FIFO of up to MEMORY_CAP entries. Each entry is a Dictionary:
#   { player_id, player_name, topic, detail, sentiment, at_unix }
var memory: Array = []
# Per-player rolling trust score in [-1, 1].
var _trust: Dictionary = {}
# Per-player last-interaction timestamp (unix seconds).
var _last_interaction: Dictionary = {}

# ── Schedule & context ─────────────────────────────────────────────────

var schedule: Array = []
var current_activity: String = ACTION_IDLE
var current_location_hint: String = ""
var _engage_cooldown: float = 0.0
var _hostile_cooldown: float = 0.0
var _last_action: String = ACTION_IDLE

# ── External context (written by spawner/world) ────────────────────────

var world_time_hour: float = 12.0  # 0..24
var weather_state: String = "clear"
var faction_relations: Dictionary = {}  # faction_id -> float [-1, 1]
var nearby_hostiles: int = 0

# ── RNG ────────────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator

# ── Construction ───────────────────────────────────────────────────────

func _init(npc_id: String = "", npc_name: String = "", occ: String = OCC_CIVILIAN, seed_value: int = 0) -> void:
	id = npc_id
	display_name = npc_name
	occupation = occ if OCC_ALL.has(occ) else OCC_CIVILIAN
	_rng = RandomNumberGenerator.new()
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	_roll_personality()
	schedule = build_schedule_for_occupation(occupation)


## Generate a random personality vector biased slightly by occupation.
func _roll_personality() -> void:
	traits["friendliness"] = _rng.randf_range(0.1, 0.95)
	traits["curiosity"] = _rng.randf_range(0.1, 0.95)
	traits["aggression"] = _rng.randf_range(0.0, 0.9)
	traits["humor"] = _rng.randf_range(0.05, 0.95)
	traits["wisdom"] = _rng.randf_range(0.1, 0.95)
	match occupation:
		OCC_GUARD:
			traits["aggression"] = clamp(traits["aggression"] + 0.25, 0.0, 1.0)
			traits["friendliness"] = clamp(traits["friendliness"] - 0.15, 0.0, 1.0)
		OCC_MERCHANT:
			traits["friendliness"] = clamp(traits["friendliness"] + 0.2, 0.0, 1.0)
			traits["aggression"] = clamp(traits["aggression"] - 0.2, 0.0, 1.0)
		OCC_BARTENDER:
			traits["humor"] = clamp(traits["humor"] + 0.25, 0.0, 1.0)
			traits["friendliness"] = clamp(traits["friendliness"] + 0.15, 0.0, 1.0)
		OCC_RIPPERDOC:
			traits["wisdom"] = clamp(traits["wisdom"] + 0.25, 0.0, 1.0)
		OCC_HACKER:
			traits["curiosity"] = clamp(traits["curiosity"] + 0.3, 0.0, 1.0)
			traits["wisdom"] = clamp(traits["wisdom"] + 0.15, 0.0, 1.0)


# ── Schedule ───────────────────────────────────────────────────────────

## Return a list of `{start_hour, end_hour, activity, location_hint}` rows
## covering the full 24 h day, sorted by start_hour.
static func build_schedule_for_occupation(occ: String) -> Array:
	match occ:
		OCC_MERCHANT:
			return [
				{"start_hour": 0.0, "end_hour": 7.0, "activity": ACTION_SLEEP, "location_hint": "home"},
				{"start_hour": 7.0, "end_hour": 9.0, "activity": ACTION_GO_TO, "location_hint": "market"},
				{"start_hour": 9.0, "end_hour": 19.0, "activity": ACTION_WORK, "location_hint": "stall"},
				{"start_hour": 19.0, "end_hour": 22.0, "activity": ACTION_WANDER, "location_hint": "plaza"},
				{"start_hour": 22.0, "end_hour": 24.0, "activity": ACTION_SLEEP, "location_hint": "home"},
			]
		OCC_GUARD:
			return [
				{"start_hour": 0.0, "end_hour": 6.0, "activity": ACTION_GUARD, "location_hint": "patrol"},
				{"start_hour": 6.0, "end_hour": 8.0, "activity": ACTION_GO_TO, "location_hint": "barracks"},
				{"start_hour": 8.0, "end_hour": 14.0, "activity": ACTION_SLEEP, "location_hint": "barracks"},
				{"start_hour": 14.0, "end_hour": 18.0, "activity": ACTION_WANDER, "location_hint": "plaza"},
				{"start_hour": 18.0, "end_hour": 24.0, "activity": ACTION_GUARD, "location_hint": "patrol"},
			]
		OCC_BARTENDER:
			return [
				{"start_hour": 0.0, "end_hour": 3.0, "activity": ACTION_WORK, "location_hint": "bar"},
				{"start_hour": 3.0, "end_hour": 13.0, "activity": ACTION_SLEEP, "location_hint": "home"},
				{"start_hour": 13.0, "end_hour": 16.0, "activity": ACTION_WANDER, "location_hint": "plaza"},
				{"start_hour": 16.0, "end_hour": 18.0, "activity": ACTION_GO_TO, "location_hint": "bar"},
				{"start_hour": 18.0, "end_hour": 24.0, "activity": ACTION_WORK, "location_hint": "bar"},
			]
		OCC_RIPPERDOC:
			return [
				{"start_hour": 0.0, "end_hour": 8.0, "activity": ACTION_SLEEP, "location_hint": "home"},
				{"start_hour": 8.0, "end_hour": 10.0, "activity": ACTION_GO_TO, "location_hint": "clinic"},
				{"start_hour": 10.0, "end_hour": 20.0, "activity": ACTION_WORK, "location_hint": "clinic"},
				{"start_hour": 20.0, "end_hour": 24.0, "activity": ACTION_WANDER, "location_hint": "clinic"},
			]
		OCC_HACKER:
			return [
				{"start_hour": 0.0, "end_hour": 4.0, "activity": ACTION_WORK, "location_hint": "den"},
				{"start_hour": 4.0, "end_hour": 12.0, "activity": ACTION_SLEEP, "location_hint": "den"},
				{"start_hour": 12.0, "end_hour": 16.0, "activity": ACTION_WANDER, "location_hint": "underground"},
				{"start_hour": 16.0, "end_hour": 20.0, "activity": ACTION_GOSSIP, "location_hint": "underground"},
				{"start_hour": 20.0, "end_hour": 24.0, "activity": ACTION_WORK, "location_hint": "den"},
			]
		_:
			return [
				{"start_hour": 0.0, "end_hour": 7.0, "activity": ACTION_SLEEP, "location_hint": "home"},
				{"start_hour": 7.0, "end_hour": 9.0, "activity": ACTION_GO_TO, "location_hint": "plaza"},
				{"start_hour": 9.0, "end_hour": 13.0, "activity": ACTION_WANDER, "location_hint": "plaza"},
				{"start_hour": 13.0, "end_hour": 14.0, "activity": ACTION_GO_TO, "location_hint": "market"},
				{"start_hour": 14.0, "end_hour": 18.0, "activity": ACTION_WANDER, "location_hint": "market"},
				{"start_hour": 18.0, "end_hour": 22.0, "activity": ACTION_GOSSIP, "location_hint": "plaza"},
				{"start_hour": 22.0, "end_hour": 24.0, "activity": ACTION_GO_TO, "location_hint": "home"},
			]


## Locate the schedule entry active at `hour` (0..24).
func current_schedule_entry(hour: float) -> Dictionary:
	for row in schedule:
		if hour >= row["start_hour"] and hour < row["end_hour"]:
			return row
	return schedule[0] if not schedule.is_empty() else {
		"start_hour": 0.0, "end_hour": 24.0,
		"activity": ACTION_IDLE, "location_hint": "home",
	}


# ── Mood ───────────────────────────────────────────────────────────────

## Decay mood toward 0.0 and apply passive weather/time-of-day modifiers.
func tick_mood(delta: float) -> void:
	# Linear decay toward zero.
	if mood > 0.0:
		mood = max(0.0, mood - MOOD_DECAY_PER_SEC * delta)
	elif mood < 0.0:
		mood = min(0.0, mood + MOOD_DECAY_PER_SEC * delta)
	# Weather pressure.
	var weather_delta: float = 0.0
	match weather_state:
		"clear": weather_delta = 0.005
		"cloudy": weather_delta = 0.0
		"rain", "heavy_rain": weather_delta = -0.01
		"thunderstorm": weather_delta = -0.02
		"snow": weather_delta = -0.005
		"fog": weather_delta = -0.008
		"sandstorm": weather_delta = -0.015
	mood = clamp(mood + weather_delta * delta, MOOD_MIN, MOOD_MAX)
	# Time-of-day pressure — bartenders and hackers prefer night, others day.
	var is_night: bool = world_time_hour < 6.0 or world_time_hour >= 20.0
	var night_pref: bool = occupation == OCC_BARTENDER or occupation == OCC_HACKER
	var tod_delta: float = 0.004 if (is_night == night_pref) else -0.004
	mood = clamp(mood + tod_delta * delta, MOOD_MIN, MOOD_MAX)
	# Hostiles nearby degrade mood proportionally.
	if nearby_hostiles > 0:
		mood = clamp(mood - 0.02 * delta * float(nearby_hostiles), MOOD_MIN, MOOD_MAX)
	_engage_cooldown = max(0.0, _engage_cooldown - delta)
	_hostile_cooldown = max(0.0, _hostile_cooldown - delta)


## Nudge mood by a signed amount (used by dialogue / events).
func nudge_mood(amount: float) -> void:
	mood = clamp(mood + amount, MOOD_MIN, MOOD_MAX)


# ── Memory ─────────────────────────────────────────────────────────────

## Record a player interaction in the FIFO memory bank.
## `sentiment` in [-1, 1]: negative = hostile, positive = friendly.
func remember(player_id: String, player_name: String, topic: String, detail: String, sentiment: float) -> void:
	if player_id.is_empty():
		return
	var entry: Dictionary = {
		"player_id": player_id,
		"player_name": player_name,
		"topic": topic,
		"detail": detail,
		"sentiment": clamp(sentiment, -1.0, 1.0),
		"at_unix": Time.get_unix_time_from_system(),
	}
	memory.append(entry)
	while memory.size() > MEMORY_CAP:
		memory.pop_front()
	# Update rolling trust — EMA toward new sentiment.
	var prior: float = float(_trust.get(player_id, 0.0))
	_trust[player_id] = clamp(prior * 0.75 + entry["sentiment"] * 0.25, -1.0, 1.0)
	_last_interaction[player_id] = entry["at_unix"]
	# Mood reacts to interaction in proportion to friendliness trait.
	nudge_mood(entry["sentiment"] * 0.15 * float(traits.get("friendliness", 0.5)))


func trust_of(player_id: String) -> float:
	return float(_trust.get(player_id, 0.0))


func is_friend(player_id: String) -> bool:
	return trust_of(player_id) >= TRUST_THRESHOLD_FRIEND


func is_enemy(player_id: String) -> bool:
	return trust_of(player_id) <= TRUST_THRESHOLD_ENEMY


func has_met(player_id: String) -> bool:
	return _trust.has(player_id)


## Return the most recent memory entry about `player_id` or {} if none.
func recall_latest_memory_about(player_id: String) -> Dictionary:
	for i in range(memory.size() - 1, -1, -1):
		var e: Dictionary = memory[i]
		if String(e.get("player_id", "")) == player_id:
			return e
	return {}


## Return all memories about `player_id`, newest first.
func recall_all_memories_about(player_id: String) -> Array:
	var out: Array = []
	for i in range(memory.size() - 1, -1, -1):
		var e: Dictionary = memory[i]
		if String(e.get("player_id", "")) == player_id:
			out.append(e)
	return out


## Summarize exportable "gossip" about a player — used by NPCDialogue.
func export_gossip_about(player_id: String) -> Dictionary:
	var latest: Dictionary = recall_latest_memory_about(player_id)
	if latest.is_empty():
		return {}
	return {
		"player_id": player_id,
		"player_name": latest.get("player_name", ""),
		"topic": latest.get("topic", ""),
		"detail": latest.get("detail", ""),
		"trust": trust_of(player_id),
		"from_npc": id,
	}


## Ingest gossip from another NPC.  Stored as a memory entry at reduced
## sentiment weight because it's second-hand.
func ingest_gossip(gossip: Dictionary) -> void:
	if gossip.is_empty():
		return
	var pid: String = String(gossip.get("player_id", ""))
	if pid.is_empty():
		return
	var second_hand_sentiment: float = float(gossip.get("trust", 0.0)) * 0.5
	remember(
		pid,
		String(gossip.get("player_name", "")),
		"gossip:" + String(gossip.get("topic", "")),
		String(gossip.get("detail", "")),
		second_hand_sentiment,
	)


# ── Hostile event hooks ────────────────────────────────────────────────

func note_hostile_event(severity: float = 1.0) -> void:
	_hostile_cooldown = HOSTILE_COOLDOWN_SECS
	nudge_mood(-0.1 * severity)


func note_faction_event(other_faction: String, delta: float) -> void:
	var cur: float = float(faction_relations.get(other_faction, 0.0))
	faction_relations[other_faction] = clamp(cur + delta, -1.0, 1.0)


# ── Decision tree ──────────────────────────────────────────────────────

## Decide next action given current world context.  Returns a Dictionary:
##   { action, target_id, target_position, location_hint, reason }
## The caller (NPCSpawner) is responsible for moving the avatar.
func decide(
	hour: float,
	nearby_players: Array = [],
	faction_event: Dictionary = {},
	threats: Array = []
) -> Dictionary:
	world_time_hour = hour
	nearby_hostiles = threats.size()

	# Priority 1: active faction event (e.g. faction_war_started).
	if not faction_event.is_empty():
		var ev_faction: String = String(faction_event.get("faction", ""))
		if ev_faction == faction and ev_faction != "":
			return _mk_action(ACTION_CELEBRATE, "", current_position, "rally", "faction_event")
		if ev_faction != "" and float(faction_relations.get(ev_faction, 0.0)) < -0.3:
			return _mk_action(ACTION_FLEE, "", home_position, "home", "rival_faction_active")

	# Priority 2: hostile threat nearby.
	if _hostile_cooldown > 0.0 or not threats.is_empty():
		if traits.get("aggression", 0.0) > 0.6 and occupation == OCC_GUARD:
			var tgt_pos: Vector3 = current_position
			if not threats.is_empty() and typeof(threats[0]) == TYPE_DICTIONARY:
				tgt_pos = threats[0].get("position", current_position)
			return _mk_action(ACTION_GUARD, "", tgt_pos, "threat", "defend")
		return _mk_action(ACTION_FLEE, "", home_position, "home", "threat")

	# Priority 3: engage with a nearby player if mood / personality allow.
	if _engage_cooldown <= 0.0 and not nearby_players.is_empty():
		var best: Dictionary = _pick_engage_target(nearby_players)
		if not best.is_empty():
			_engage_cooldown = ENGAGE_COOLDOWN_SECS
			return _mk_action(
				ACTION_ENGAGE_PLAYER,
				String(best.get("player_id", "")),
				best.get("position", current_position),
				"player",
				"engage",
			)

	# Priority 4: follow the daily schedule.
	var entry: Dictionary = current_schedule_entry(hour)
	current_activity = String(entry.get("activity", ACTION_IDLE))
	current_location_hint = String(entry.get("location_hint", ""))

	# Priority 5: personality-weighted fallback jitter.
	if current_activity == ACTION_IDLE or current_activity == ACTION_WANDER:
		var jitter: float = _rng.randf()
		if jitter < float(traits.get("curiosity", 0.5)) * 0.25:
			var target: Vector3 = current_position + _random_offset(WANDER_RADIUS_METERS)
			return _mk_action(ACTION_WANDER, "", target, current_location_hint, "curiosity")
		if jitter > 1.0 - float(traits.get("humor", 0.5)) * 0.15:
			return _mk_action(ACTION_GOSSIP, "", current_position, current_location_hint, "humor")
	return _mk_action(current_activity, "", home_position, current_location_hint, "schedule")


func _pick_engage_target(players: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -INF
	for p in players:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var pid: String = String(p.get("player_id", ""))
		if pid.is_empty():
			continue
		var pos: Vector3 = p.get("position", current_position)
		var dist: float = current_position.distance_to(pos)
		if dist > ENGAGE_RADIUS_METERS:
			continue
		var score: float = float(traits.get("friendliness", 0.5))
		score += float(traits.get("curiosity", 0.5)) * 0.5
		score += trust_of(pid) * 0.75
		score += mood * 0.25
		score -= float(traits.get("aggression", 0.0)) * 0.5 * float(is_enemy(pid))
		score -= dist / ENGAGE_RADIUS_METERS
		if score > best_score:
			best_score = score
			best = p
	# Only engage if the score crosses a personality-dependent threshold.
	var threshold: float = 0.35 + (0.5 - float(traits.get("friendliness", 0.5))) * 0.6
	if best_score < threshold:
		return {}
	return best


func _mk_action(action: String, tid: String, tpos: Vector3, loc: String, reason: String) -> Dictionary:
	_last_action = action
	return {
		"action": action,
		"target_id": tid,
		"target_position": tpos,
		"location_hint": loc,
		"reason": reason,
	}


func _random_offset(radius: float) -> Vector3:
	var angle: float = _rng.randf() * TAU
	var r: float = _rng.randf() * radius
	return Vector3(cos(angle) * r, 0.0, sin(angle) * r)


# ── Introspection ──────────────────────────────────────────────────────

func snapshot() -> Dictionary:
	return {
		"id": id,
		"name": display_name,
		"occupation": occupation,
		"faction": faction,
		"traits": traits.duplicate(),
		"mood": mood,
		"memory_count": memory.size(),
		"trust": _trust.duplicate(),
		"activity": current_activity,
		"location_hint": current_location_hint,
	}


## Compact string for logs / tooltips.
func describe() -> String:
	return "%s (%s/%s) mood=%0.2f fr=%0.2f ag=%0.2f" % [
		display_name, occupation, faction,
		mood,
		float(traits.get("friendliness", 0.5)),
		float(traits.get("aggression", 0.0)),
	]
