## NPCDialogue — Template-based dialogue generator for NPCs.
##
## Lines are produced by mixing:
##   • Personality trait thresholds (friendliness, humor, aggression, …).
##   • Current mood (positive / neutral / negative).
##   • Player relationship — first meeting vs returning, trust level.
##   • Recent memory (the latest entry about the player), so the NPC can
##     say things like "Hey, you mentioned you were building on Block 5
##     last time!".
##   • Keyword routing — the player text is scanned for topic keywords
##     (trade, quest, gossip, faction, …) which select a template bucket.
##   • Gossip swap between NPCs: share_gossip_with_npc / receive_gossip.
##   • Per-occupation quest generation with rewards and time limits.
##
## Templates use `{placeholder}` tokens; the generator fills them from a
## context Dictionary.  All outputs are deterministic given the NPCBrain's
## RNG state.

class_name NPCDialogue
extends RefCounted

const NPCBrain = preload("res://scripts/ai/NPCBrain.gd")

const TOPIC_GENERIC: String = "generic"
const TOPIC_TRADE: String = "trade"
const TOPIC_QUEST: String = "quest"
const TOPIC_GOSSIP: String = "gossip"
const TOPIC_FACTION: String = "faction"
const TOPIC_WEATHER: String = "weather"
const TOPIC_BUILDING: String = "building"
const TOPIC_GREETING: String = "greeting"
const TOPIC_FAREWELL: String = "farewell"
const TOPIC_THREAT: String = "threat"
const TOPIC_SELF: String = "self"

const QUEST_MAX_ACTIVE_PER_NPC: int = 3
const QUEST_DEFAULT_TTL_SECS: float = 1800.0
const GOSSIP_DEDUPE_WINDOW_SECS: float = 300.0

var _brain  # NPCBrain reference (typed dynamic to avoid circular class_name)
var _rng: RandomNumberGenerator
var _active_quests: Dictionary = {}  # quest_id -> quest dict
var _completed_quest_ids: Array = []
var _recent_gossip_log: Array = []  # [{from_npc, player_id, at_unix}]


# Template catalog — each bucket is a PackedStringArray keyed by
# (topic, mood_bucket, relationship).  mood_bucket: "bad"|"mid"|"good".
# relationship: "stranger"|"known"|"friend"|"enemy".
# When a specific bucket is missing we fall through to less-specific
# ones in the order: (topic, mood, relationship) → (topic, mood, *) →
# (topic, *, *) → (GENERIC, *, *).
var _templates: Dictionary = {}


func _init(brain) -> void:
	_brain = brain
	_rng = RandomNumberGenerator.new()
	_rng.randomize()
	_build_templates()


# ── Template authoring ────────────────────────────────────────────────

func _build_templates() -> void:
	_templates = {
		TOPIC_GREETING: {
			"good": {
				"stranger": [
					"Ha! A new face. Welcome to {district}, stranger.",
					"Oh hey! Never seen you around — what's your name?",
					"Neon be with you, traveler. You lost?",
				],
				"known": [
					"Back again, {player}! How's life been?",
					"{player}! Good to see you.",
				],
				"friend": [
					"My friend {player}! You always know when to show up.",
					"Hah, {player} — the one person I was hoping to run into.",
				],
				"enemy": [
					"…you. I'll still hear you out. Don't push it.",
					"{player}. Didn't expect to see you smiling at me.",
				],
			},
			"mid": {
				"stranger": [
					"Hi. What do you need?",
					"Yeah? You talking to me?",
				],
				"known": [
					"{player}. Back on the grid, huh?",
					"Oh, it's you again.",
				],
				"friend": [
					"Hey {player}. Keeping out of trouble?",
				],
				"enemy": [
					"Make it quick, {player}.",
				],
			},
			"bad": {
				"stranger": [
					"What do you want.",
					"Not in the mood, chummer.",
				],
				"known": [
					"{player}. Today's not the day.",
				],
				"friend": [
					"Ugh — {player}, I'm having a rough one.",
				],
				"enemy": [
					"Walk away, {player}.",
				],
			},
		},
		TOPIC_FAREWELL: {
			"good": {
				"stranger": [
					"Stay neon, stranger.",
					"Catch you in the wires.",
				],
				"known": [
					"Later, {player}!",
					"Don't be a stranger, {player}.",
				],
				"friend": [
					"Take care of yourself, {player}. You know where to find me.",
				],
				"enemy": [
					"Leave. Quietly.",
				],
			},
			"mid": {
				"stranger": ["Bye.", "See you."],
				"known": ["Later, {player}."],
			},
			"bad": {
				"stranger": ["Get out of my face.", "Go."],
				"known": ["Not now, {player}."],
				"enemy": ["If I see you again, {player}, don't smile."],
			},
		},
		TOPIC_TRADE: {
			"good": {
				"stranger": [
					"Take a look at the stall. Prices are fair today.",
					"I've got goods — cheaper than the corp stores, I promise.",
				],
				"known": [
					"{player}, for you — 10% off on {stock_sample}.",
				],
				"friend": [
					"Regular discount applies, {player}. What are you after?",
				],
			},
			"mid": {
				"stranger": ["Prices are on the board. Ask if you need detail."],
				"known": ["Usual rates, {player}."],
			},
			"bad": {
				"stranger": ["Buying or leaving?"],
			},
		},
		TOPIC_QUEST: {
			"good": {
				"stranger": [
					"If you've got time, I could use a hand with something.",
					"Actually… you look capable. Interested in a job?",
				],
				"known": [
					"{player}, I've got a new gig if you want it.",
				],
				"friend": [
					"{player} — got something special this time. Pays well.",
				],
			},
			"mid": {
				"stranger": ["There's work if you want it. Small pay."],
			},
			"bad": {
				"stranger": ["I've got nothing for you."],
			},
		},
		TOPIC_GOSSIP: {
			"good": {
				"stranger": [
					"Oh, you want the word on the street? Sit down.",
					"Rumor mill is spinning — want to hear?",
				],
				"known": [
					"I heard something about {gossip_player} the other night…",
				],
				"friend": [
					"{player}, between us — {gossip_detail}.",
				],
			},
			"mid": {
				"stranger": ["Heard some chatter. Nothing solid."],
			},
			"bad": {
				"stranger": ["Keep your rumors to yourself."],
			},
		},
		TOPIC_FACTION: {
			"good": {
				"stranger": [
					"Factions? {faction} is the one worth talking to around here.",
				],
				"known": [
					"{player}, careful who you run with. {faction} watches this block.",
				],
			},
			"mid": {
				"stranger": ["Stay out of faction business if you know what's good."],
			},
			"bad": {
				"enemy": ["Your colors are not welcome here, {player}."],
			},
		},
		TOPIC_WEATHER: {
			"good": {
				"stranger": [
					"Weather's turning {weather}. Nice change, eh?",
				],
			},
			"mid": {
				"stranger": ["Ugh, this {weather} again."],
			},
			"bad": {
				"stranger": ["This {weather} is killing the mood."],
			},
		},
		TOPIC_BUILDING: {
			"good": {
				"known": [
					"Still building on {memory_detail}? I like what you're doing.",
					"Hey — last time you mentioned {memory_detail}. How's that going?",
				],
				"friend": [
					"{player}, your place on {memory_detail} is the talk of the district.",
				],
			},
			"mid": {
				"known": ["You were on {memory_detail}, right? Fix that roof yet?"],
			},
			"bad": {
				"enemy": ["Stay off {memory_detail} — I mean it."],
			},
		},
		TOPIC_SELF: {
			"good": {
				"stranger": [
					"Name's {npc_name}. I {occupation_verb} around here.",
					"I'm {npc_name}, local {occupation}. Nice to meet you.",
				],
			},
			"mid": {
				"stranger": ["{npc_name}. {occupation}. That's it."],
			},
		},
		TOPIC_THREAT: {
			"bad": {
				"enemy": [
					"One more step and I'm calling security.",
					"I said back off, {player}!",
				],
				"stranger": [
					"Keep your distance, friend.",
				],
			},
		},
		TOPIC_GENERIC: {
			"good": {
				"stranger": [
					"Neon city, endless night. What can I do for you?",
					"Plenty going on. Anything on your mind?",
				],
				"known": [
					"What's up, {player}?",
				],
				"friend": [
					"{player}! Shoot.",
				],
			},
			"mid": {
				"stranger": ["Hm.", "Yeah?"],
			},
			"bad": {
				"stranger": ["I don't have time."],
				"enemy": ["Don't."],
			},
		},
	}


# ── Keyword routing ───────────────────────────────────────────────────

const _KEYWORDS: Dictionary = {
	TOPIC_TRADE: ["buy", "sell", "price", "shop", "store", "stall", "trade", "barter", "cost"],
	TOPIC_QUEST: ["quest", "job", "mission", "task", "bounty", "contract", "work", "help"],
	TOPIC_GOSSIP: ["rumor", "rumour", "gossip", "news", "heard", "word", "story"],
	TOPIC_FACTION: ["faction", "gang", "clan", "territory", "war", "zone"],
	TOPIC_WEATHER: ["weather", "rain", "storm", "fog", "snow", "clear", "sandstorm"],
	TOPIC_BUILDING: ["block", "build", "building", "rent", "land", "plot", "property"],
	TOPIC_SELF: ["who are you", "your name", "yourself", "about you"],
	TOPIC_GREETING: ["hi", "hey", "hello", "yo ", "greetings"],
	TOPIC_FAREWELL: ["bye", "later", "farewell", "goodbye", "cya", "see ya"],
	TOPIC_THREAT: ["die", "kill", "attack", "fight", "shoot"],
}


func route_topic(player_text: String) -> String:
	var t: String = player_text.to_lower()
	# Exact phrase topics first.
	for topic in [TOPIC_SELF, TOPIC_FAREWELL, TOPIC_GREETING, TOPIC_THREAT]:
		for kw in _KEYWORDS[topic]:
			if t.find(kw) != -1:
				return topic
	# Then substring topics.
	for topic in [TOPIC_TRADE, TOPIC_QUEST, TOPIC_GOSSIP, TOPIC_FACTION, TOPIC_WEATHER, TOPIC_BUILDING]:
		for kw in _KEYWORDS[topic]:
			if t.find(kw) != -1:
				return topic
	return TOPIC_GENERIC


# ── Dialogue generation ───────────────────────────────────────────────

## Generate a line of dialogue for `player_id` / `player_name` given the
## optional `player_text` (may be empty for greeting / idle barks).
## Returns a Dictionary: { text, topic, used_memory, quest }
func generate(player_id: String, player_name: String, player_text: String = "") -> Dictionary:
	var topic: String
	if player_text.strip_edges().is_empty():
		topic = TOPIC_GREETING if not _brain.has_met(player_id) else TOPIC_GENERIC
	else:
		topic = route_topic(player_text)

	var mood_bucket: String = _mood_bucket()
	var relation: String = _relationship(player_id)
	var template: String = _pick_template(topic, mood_bucket, relation)
	var ctx: Dictionary = _build_context(player_id, player_name, topic)
	var text: String = _fill(template, ctx)

	# If a memory-eligible topic, try to weave in a recall snippet.
	var used_memory: bool = false
	if topic in [TOPIC_BUILDING, TOPIC_GREETING, TOPIC_GENERIC]:
		var recall: Dictionary = _brain.recall_latest_memory_about(player_id)
		if not recall.is_empty() and _rng.randf() < 0.55:
			var snippet: String = _memory_snippet(recall)
			if snippet != "":
				text = "%s  %s" % [text, snippet]
				used_memory = true

	var quest: Dictionary = {}
	if topic == TOPIC_QUEST:
		quest = generate_quest_for(player_id)
		if not quest.is_empty():
			text = "%s  [%s — reward %d credits]" % [text, quest["title"], int(quest["reward"])]

	# Record this interaction so future lines see it.
	_brain.remember(
		player_id, player_name,
		topic,
		player_text if not player_text.is_empty() else "spoken:" + topic,
		_sentiment_for(topic, relation),
	)
	return {
		"text": text,
		"topic": topic,
		"used_memory": used_memory,
		"quest": quest,
	}


func _mood_bucket() -> String:
	if _brain.mood >= 0.25:
		return "good"
	if _brain.mood <= -0.25:
		return "bad"
	return "mid"


func _relationship(player_id: String) -> String:
	if _brain.is_enemy(player_id):
		return "enemy"
	if _brain.is_friend(player_id):
		return "friend"
	if _brain.has_met(player_id):
		return "known"
	return "stranger"


func _pick_template(topic: String, mood_bucket: String, relation: String) -> String:
	var by_topic: Dictionary = _templates.get(topic, {})
	var by_mood: Dictionary = by_topic.get(mood_bucket, {})
	var arr = by_mood.get(relation, [])
	if typeof(arr) == TYPE_ARRAY and not (arr as Array).is_empty():
		return _rng_pick(arr)
	# Fallback 1: same topic & mood, any relation.
	for rel in ["stranger", "known", "friend", "enemy"]:
		var a = by_mood.get(rel, [])
		if typeof(a) == TYPE_ARRAY and not (a as Array).is_empty():
			return _rng_pick(a)
	# Fallback 2: same topic, any mood/relation.
	for mb in ["mid", "good", "bad"]:
		var m = by_topic.get(mb, {})
		for rel2 in ["stranger", "known", "friend", "enemy"]:
			var a2 = m.get(rel2, [])
			if typeof(a2) == TYPE_ARRAY and not (a2 as Array).is_empty():
				return _rng_pick(a2)
	# Fallback 3: generic.
	if topic != TOPIC_GENERIC:
		return _pick_template(TOPIC_GENERIC, mood_bucket, relation)
	return "…"


func _rng_pick(arr: Array) -> String:
	var idx: int = _rng.randi_range(0, arr.size() - 1)
	return String(arr[idx])


func _build_context(player_id: String, player_name: String, topic: String) -> Dictionary:
	var gossip_target: Dictionary = _pick_gossip_target(player_id)
	return {
		"player": player_name if player_name != "" else "stranger",
		"npc_name": _brain.display_name,
		"occupation": _brain.occupation,
		"occupation_verb": _occupation_verb(_brain.occupation),
		"faction": _brain.faction,
		"district": _brain.home_district if _brain.home_district != "" else "this block",
		"weather": _brain.weather_state,
		"stock_sample": "tonight's stock",
		"gossip_player": String(gossip_target.get("player_name", "someone")),
		"gossip_detail": String(gossip_target.get("detail", "rumors")),
		"memory_detail": _memory_block_hint(player_id),
	}


func _occupation_verb(occ: String) -> String:
	match occ:
		NPCBrain.OCC_MERCHANT: return "run a stall"
		NPCBrain.OCC_GUARD: return "keep the peace"
		NPCBrain.OCC_BARTENDER: return "pour drinks"
		NPCBrain.OCC_RIPPERDOC: return "patch up cybernetics"
		NPCBrain.OCC_HACKER: return "move data"
		_: return "get by"


func _fill(template: String, ctx: Dictionary) -> String:
	var out: String = template
	for key in ctx.keys():
		out = out.replace("{%s}" % key, String(ctx[key]))
	return out


func _memory_snippet(recall: Dictionary) -> String:
	var topic: String = String(recall.get("topic", ""))
	var detail: String = String(recall.get("detail", ""))
	if detail.is_empty():
		return ""
	if topic.begins_with("gossip:"):
		return "I heard something about you — %s." % detail
	match topic:
		TOPIC_BUILDING:
			return "Last time you mentioned %s." % detail
		TOPIC_TRADE:
			return "You were asking about %s, right?" % detail
		TOPIC_QUEST:
			return "Still on that %s job?" % detail
		TOPIC_FACTION:
			return "Still running with %s?" % detail
		_:
			if detail.length() <= 48:
				return "Last time you said: \"%s\"." % detail
	return ""


func _memory_block_hint(player_id: String) -> String:
	var recall: Dictionary = _brain.recall_latest_memory_about(player_id)
	if recall.is_empty():
		return "your block"
	var d: String = String(recall.get("detail", ""))
	return d if d != "" else "your block"


func _sentiment_for(topic: String, relation: String) -> float:
	match topic:
		TOPIC_THREAT: return -0.7
		TOPIC_FAREWELL: return 0.05
		TOPIC_GREETING: return 0.1
		TOPIC_TRADE: return 0.05
		TOPIC_QUEST: return 0.15
		TOPIC_GOSSIP: return 0.0
		_:
			if relation == "enemy":
				return -0.1
			return 0.05


# ── Gossip ────────────────────────────────────────────────────────────

func _pick_gossip_target(exclude_player_id: String) -> Dictionary:
	for i in range(_brain.memory.size() - 1, -1, -1):
		var e: Dictionary = _brain.memory[i]
		var pid: String = String(e.get("player_id", ""))
		if pid == "" or pid == exclude_player_id:
			continue
		return e
	return {}


## Package gossip about `player_id` to share with another NPC.
## Returns {} if nothing to share.
func share_gossip_with_npc(player_id: String, other_brain, other_dialogue = null) -> Dictionary:
	var gossip: Dictionary = _brain.export_gossip_about(player_id)
	if gossip.is_empty() or other_brain == null:
		return {}
	# De-duplicate: don't share the same player twice in the dedupe window.
	var now: float = Time.get_unix_time_from_system()
	for row in _recent_gossip_log:
		if row["player_id"] == player_id and (now - float(row["at_unix"])) < GOSSIP_DEDUPE_WINDOW_SECS:
			return {}
	_recent_gossip_log.append({
		"from_npc": _brain.id,
		"player_id": player_id,
		"at_unix": now,
	})
	while _recent_gossip_log.size() > 32:
		_recent_gossip_log.pop_front()
	other_brain.ingest_gossip(gossip)
	if other_dialogue != null and other_dialogue.has_method("receive_gossip"):
		other_dialogue.receive_gossip(gossip)
	return gossip


func receive_gossip(gossip: Dictionary) -> void:
	# The gossip is already stored by NPCBrain.ingest_gossip; here we could
	# adjust dialogue-specific state (e.g. clear dedupe).  Keep as hook.
	if gossip.is_empty():
		return
	_recent_gossip_log.append({
		"from_npc": String(gossip.get("from_npc", "")),
		"player_id": String(gossip.get("player_id", "")),
		"at_unix": Time.get_unix_time_from_system(),
	})
	while _recent_gossip_log.size() > 32:
		_recent_gossip_log.pop_front()


# ── Quest generation ──────────────────────────────────────────────────

const _QUEST_TEMPLATES_BY_OCC: Dictionary = {
	"merchant": [
		{"title": "Deliver crate to Block {n}", "type": "delivery", "reward": 150, "difficulty": 1},
		{"title": "Recover stolen inventory", "type": "retrieve", "reward": 300, "difficulty": 2},
		{"title": "Escort the shipment", "type": "escort", "reward": 400, "difficulty": 3},
	],
	"guard": [
		{"title": "Clear {n} ganger from District", "type": "combat", "reward": 250, "difficulty": 2},
		{"title": "Patrol the {district} perimeter", "type": "patrol", "reward": 180, "difficulty": 1},
		{"title": "Capture the fugitive", "type": "capture", "reward": 500, "difficulty": 3},
	],
	"bartender": [
		{"title": "Collect unpaid tabs", "type": "collect", "reward": 120, "difficulty": 1},
		{"title": "Eject rowdy patrons", "type": "combat", "reward": 200, "difficulty": 2},
	],
	"ripperdoc": [
		{"title": "Fetch experimental implant part", "type": "fetch", "reward": 350, "difficulty": 2},
		{"title": "Transport patient discreetly", "type": "escort", "reward": 450, "difficulty": 3},
	],
	"hacker": [
		{"title": "Plant data-leech on corp kiosk", "type": "infiltration", "reward": 500, "difficulty": 3},
		{"title": "Retrieve encrypted shard from drop", "type": "fetch", "reward": 300, "difficulty": 2},
	],
	"civilian": [
		{"title": "Find my lost {item}", "type": "fetch", "reward": 100, "difficulty": 1},
		{"title": "Message delivery to Block {n}", "type": "delivery", "reward": 150, "difficulty": 1},
	],
}


func generate_quest_for(player_id: String) -> Dictionary:
	if _active_quests.size() >= QUEST_MAX_ACTIVE_PER_NPC:
		return {}
	var pool = _QUEST_TEMPLATES_BY_OCC.get(_brain.occupation, _QUEST_TEMPLATES_BY_OCC[NPCBrain.OCC_CIVILIAN])
	if (pool as Array).is_empty():
		return {}
	var tmpl: Dictionary = (pool as Array)[_rng.randi_range(0, pool.size() - 1)]
	var qid: String = "q_%s_%d" % [_brain.id, Time.get_ticks_msec()]
	var reward: int = int(tmpl.get("reward", 100))
	# Trust and mood can give a bonus.
	reward += int(max(0.0, _brain.trust_of(player_id)) * 50.0)
	reward += int(max(0.0, _brain.mood) * 40.0)
	var quest: Dictionary = {
		"id": qid,
		"title": _fill(String(tmpl.get("title", "Quest")), {
			"n": str(_rng.randi_range(1, 99)),
			"district": _brain.home_district if _brain.home_district != "" else "central",
			"item": "datashard",
		}),
		"type": String(tmpl.get("type", "fetch")),
		"difficulty": int(tmpl.get("difficulty", 1)),
		"reward": reward,
		"giver_npc": _brain.id,
		"player_id": player_id,
		"accepted_at": Time.get_unix_time_from_system(),
		"expires_at": Time.get_unix_time_from_system() + QUEST_DEFAULT_TTL_SECS,
		"state": "offered",
	}
	_active_quests[qid] = quest
	return quest


func accept_quest(qid: String, player_id: String) -> bool:
	if not _active_quests.has(qid):
		return false
	var q: Dictionary = _active_quests[qid]
	if String(q.get("player_id", "")) != player_id:
		return false
	q["state"] = "active"
	_active_quests[qid] = q
	return true


func complete_quest(qid: String, success: bool) -> Dictionary:
	if not _active_quests.has(qid):
		return {}
	var q: Dictionary = _active_quests[qid]
	q["state"] = "completed" if success else "failed"
	q["completed_at"] = Time.get_unix_time_from_system()
	_active_quests.erase(qid)
	_completed_quest_ids.append(qid)
	while _completed_quest_ids.size() > 64:
		_completed_quest_ids.pop_front()
	return q


func active_quests() -> Array:
	return _active_quests.values()


# ── Tick / maintenance ────────────────────────────────────────────────

func tick(delta: float) -> void:
	var now: float = Time.get_unix_time_from_system()
	# Expire stale quests.
	var expired: Array = []
	for qid in _active_quests.keys():
		var q: Dictionary = _active_quests[qid]
		if float(q.get("expires_at", 0.0)) < now:
			expired.append(qid)
	for qid in expired:
		complete_quest(qid, false)
	# Trim old gossip entries beyond window.
	var cutoff: float = now - GOSSIP_DEDUPE_WINDOW_SECS * 4.0
	_recent_gossip_log = _recent_gossip_log.filter(func(r): return float(r["at_unix"]) >= cutoff)
