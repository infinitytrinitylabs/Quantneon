## NPCDialogue.gd
## Template-based dialogue generation system for NPCs in Neo City.
## Handles personality-driven responses, player memory recall, gossip sharing,
## and mini-quest generation based on world state.

extends Node

# ── Signals ─────────────────────────────────────────────────────────────────

signal dialogue_line_ready(line: String)
signal quest_offered(quest: Dictionary)
signal gossip_shared(data: Dictionary)
signal dialogue_ended()

# ── References ───────────────────────────────────────────────────────────────

var brain: Node = null          # NPCBrain reference
var economy: Node = null        # NPCEconomy reference (optional)

# ── State ─────────────────────────────────────────────────────────────────────

var is_in_dialogue: bool = false
var current_player_id: String = ""
var current_player_node: Node = null
var dialogue_history: Array = []   # lines exchanged this session
var session_turn: int = 0

# ── Quest Tracking ────────────────────────────────────────────────────────────

var active_quests: Array = []          # quests currently offered
var completed_quests: Array = []       # quest ids finished

const MAX_ACTIVE_QUESTS: int = 3

# ── Gossip Cache ──────────────────────────────────────────────────────────────

## gossip_pool: Array of { player_id, topic, source_npc }
var gossip_pool: Array = []
const MAX_GOSSIP_POOL: int = 30

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

func setup(npc_brain: Node, npc_economy: Node = null) -> void:
	brain = npc_brain
	economy = npc_economy

# ─────────────────────────────────────────────────────────────────────────────
# Dialogue Session
# ─────────────────────────────────────────────────────────────────────────────

func begin_dialogue(player_id: String, player_node: Node) -> void:
	is_in_dialogue = true
	current_player_id = player_id
	current_player_node = player_node
	session_turn = 0
	dialogue_history.clear()

	var opening = _generate_opening(player_id)
	_emit_line(opening)

func end_dialogue() -> void:
	if not is_in_dialogue:
		return
	var farewell = _generate_farewell()
	_emit_line(farewell)
	is_in_dialogue = false
	current_player_id = ""
	current_player_node = null
	emit_signal("dialogue_ended")

func player_says(player_id: String, message: String) -> void:
	if not is_in_dialogue:
		return
	session_turn += 1
	var response = _generate_response(player_id, message)
	_emit_line(response)

	# Chance to offer quest during conversation
	if session_turn == 2 and active_quests.size() < MAX_ACTIVE_QUESTS:
		if _should_offer_quest():
			var q = generate_quest()
			if not q.is_empty():
				emit_signal("quest_offered", q)

	# Chance to share gossip
	if session_turn >= 3 and randf() < 0.35:
		_share_gossip_with_player()

func _emit_line(line: String) -> void:
	dialogue_history.append({"speaker": _get_npc_name(), "line": line})
	emit_signal("dialogue_line_ready", line)

# ─────────────────────────────────────────────────────────────────────────────
# Opening Lines
# ─────────────────────────────────────────────────────────────────────────────

func _generate_opening(player_id: String) -> String:
	if brain == null:
		return "Hey."

	var has_met: bool = brain.has_met_player(player_id)
	var trust: float = brain.get_player_trust(player_id)
	var mood: String = brain.get_mood_label()
	var friendliness: float = brain.trait_friendliness

	if has_met:
		return _opening_returning_player(player_id, trust, mood)
	else:
		return _opening_new_player(friendliness, mood)

func _opening_returning_player(player_id: String, trust: float, mood: String) -> String:
	var last_mem = brain.recall_latest_memory_about(player_id)
	var memory_count = brain.get_memory_count(player_id)
	var npc_name_str = _get_npc_name()

	var recall_line: String = ""
	if not last_mem.is_empty():
		var topic: String = last_mem.get("topic", "")
		var detail: String = last_mem.get("detail", "")
		match topic:
			"meeting":
				recall_line = " We've crossed paths before."
			"gift":
				recall_line = " You brought me something last time — I remember."
			"attack":
				recall_line = " Last time you weren't so friendly."
			"building":
				recall_line = " You mentioned " + detail + " last time."
			_:
				recall_line = " I remember you — you mentioned " + detail + "."

	if trust >= 0.5:
		var lines: Array = [
			_get_npc_name() + ": " + player_id + "! Good to see a familiar face." + recall_line,
			_get_npc_name() + ": Back again?" + recall_line + " What brings you this way?",
			_get_npc_name() + ": Ahh, the one who " + _recall_summary(player_id) + ". Welcome back.",
		]
		return lines[randi() % lines.size()]
	elif trust >= 0.0:
		var lines: Array = [
			_get_npc_name() + ": You again." + recall_line,
			_get_npc_name() + ": I know you." + recall_line + " What do you want?",
			_get_npc_name() + ": We've met, right?" + recall_line,
		]
		return lines[randi() % lines.size()]
	else:
		var lines: Array = [
			_get_npc_name() + ": Oh. You." + recall_line + " What now.",
			_get_npc_name() + ": Keep your distance." + recall_line,
			_get_npc_name() + ": I haven't forgotten last time." + recall_line,
		]
		return lines[randi() % lines.size()]

func _opening_new_player(friendliness: float, mood: String) -> String:
	var npc_name_str = _get_npc_name()
	if friendliness >= 0.7 and mood in ["happy", "content"]:
		var lines: Array = [
			npc_name_str + ": Hey! Haven't seen you around before. Name's " + npc_name_str + ". Welcome to the block.",
			npc_name_str + ": Fresh face! Good timing — it's been quiet around here.",
			npc_name_str + ": Well, look at you. New arrival? Stick around, this district's got character.",
		]
		return lines[randi() % lines.size()]
	elif friendliness >= 0.4:
		var lines: Array = [
			npc_name_str + ": Yo. You lost?",
			npc_name_str + ": First time in this district?",
			npc_name_str + ": What's your business here?",
		]
		return lines[randi() % lines.size()]
	else:
		var lines: Array = [
			npc_name_str + ": Keep walking if you've got nothing to say.",
			npc_name_str + ": Not interested in tourists.",
			npc_name_str + ": Make it quick.",
		]
		return lines[randi() % lines.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Response Generation
# ─────────────────────────────────────────────────────────────────────────────

func _generate_response(player_id: String, message: String) -> String:
	if brain == null:
		return "..."

	var msg_lower: String = message.to_lower()
	var npc_name_str: String = _get_npc_name()

	# Keyword routing
	if _contains_any(msg_lower, ["quest", "job", "mission", "work", "task"]):
		return _respond_quest_inquiry(player_id)
	elif _contains_any(msg_lower, ["buy", "sell", "trade", "shop", "price"]):
		return _respond_trade_inquiry(player_id)
	elif _contains_any(msg_lower, ["gossip", "news", "heard", "rumor", "know about"]):
		return _respond_gossip_inquiry(player_id)
	elif _contains_any(msg_lower, ["building", "block", "land", "property", "plot"]):
		brain.store_memory(player_id, "building", message, 0.05)
		return _respond_building_topic(player_id, message)
	elif _contains_any(msg_lower, ["who are you", "name", "tell me about yourself"]):
		return _respond_self_introduction()
	elif _contains_any(msg_lower, ["weather", "rain", "storm", "sky"]):
		return _respond_weather()
	elif _contains_any(msg_lower, ["faction", "corp", "syndicate", "gang", "crew"]):
		return _respond_faction_topic(player_id)
	elif _contains_any(msg_lower, ["thanks", "thank you", "cheers", "appreciate"]):
		brain.apply_mood_boost(0.05)
		return _respond_thanks()
	elif _contains_any(msg_lower, ["bye", "later", "goodbye", "see you", "gotta go"]):
		end_dialogue()
		return ""
	elif _contains_any(msg_lower, ["help", "lost", "directions", "where"]):
		return _respond_directions()
	else:
		return _respond_generic(player_id, message)

func _respond_quest_inquiry(player_id: String) -> String:
	var npc_name_str = _get_npc_name()
	if active_quests.size() >= MAX_ACTIVE_QUESTS:
		return npc_name_str + ": I've already got people working on enough. Come back later."

	var occupation = brain.occupation if brain else "civilian"
	match occupation:
		"merchant", "shopkeeper":
			return npc_name_str + ": Actually, I could use someone to fetch a supply run. Payment in credits. You in?"
		"guard", "security":
			return npc_name_str + ": There's been suspicious movement near the east perimeter. If you check it out and report back, I'll make it worth your time."
		"hacker":
			return npc_name_str + ": There's a data node I need accessed. Encrypted, naturally. If you can crack it, we split the payload."
		"fixer":
			return npc_name_str + ": I've got three things that need doing. Pick one — courier run, acquisition, or extraction."
		_:
			return npc_name_str + ": I might have something. Let me think on it. Check back tomorrow."

func _respond_trade_inquiry(player_id: String) -> String:
	var npc_name_str = _get_npc_name()
	if economy != null and economy.has_method("get_shop_summary"):
		var summary = economy.get_shop_summary()
		return npc_name_str + ": Running stock of " + str(summary.get("item_count", 0)) + " items. Prices are " + summary.get("price_trend", "stable") + " right now."
	var lines: Array = [
		npc_name_str + ": Depends what you're after. I deal in useful things.",
		npc_name_str + ": Name your item. I'll tell you if I've got it and what it costs.",
		npc_name_str + ": Market's been shifty lately. Make me an offer.",
	]
	return lines[randi() % lines.size()]

func _respond_gossip_inquiry(player_id: String) -> String:
	var npc_name_str = _get_npc_name()
	if gossip_pool.is_empty():
		return npc_name_str + ": Not much to say lately. The district's been quiet."

	var item = gossip_pool[randi() % gossip_pool.size()]
	var pid: String = item.get("player_id", "someone")
	var topic: String = item.get("topic", "things")
	var source: String = item.get("source_npc", "someone I know")

	return npc_name_str + ": Word is " + pid + " has been dealing in " + topic + ". Heard it from " + source + ". Draw your own conclusions."

func _respond_building_topic(player_id: String, message: String) -> String:
	var npc_name_str = _get_npc_name()
	var last = brain.recall_latest_memory_about(player_id) if brain else {}
	var previous_detail = last.get("detail", "") if not last.is_empty() else ""

	if previous_detail != "" and "block" in previous_detail.to_lower():
		return npc_name_str + ": Hey, you mentioned " + previous_detail + " last time we spoke. Is that still going?"
	else:
		var lines: Array = [
			npc_name_str + ": Land around here is valuable. People fight over blocks.",
			npc_name_str + ": Property's the new currency in Neo City. Smart move looking into it.",
			npc_name_str + ": The west blocks are contested right now. Tread carefully.",
		]
		return lines[randi() % lines.size()]

func _respond_self_introduction() -> String:
	if brain == null:
		return "Just an NPC."
	var npc_name_str = _get_npc_name()
	var occupation: String = brain.occupation
	var faction: String = brain.faction
	var mood: String = brain.get_mood_label()

	var personality_phrase: String = _personality_to_phrase()
	return (npc_name_str + ": Name's " + npc_name_str + ". " + occupation.capitalize() +
		" by trade, affiliated with " + faction + ". " + personality_phrase +
		" Currently feeling " + mood + ", if you care.")

func _respond_weather() -> String:
	var npc_name_str = _get_npc_name()
	var weather: String = brain.current_weather if brain else "clear"
	match weather:
		"rain":
			return npc_name_str + ": Acid in the air. My implants hate rain."
		"storm":
			return npc_name_str + ": Storm's interfering with half the grid. Not ideal."
		"acid_rain":
			return npc_name_str + ": Stay under cover. Acid rain corrodes cheap augments."
		"neon_smog":
			return npc_name_str + ": Smog's thick today. Corp vents dumping again."
		_:
			return npc_name_str + ": Clear enough. Good time to be out in the open."

func _respond_faction_topic(player_id: String) -> String:
	var npc_name_str = _get_npc_name()
	if brain == null:
		return npc_name_str + ": Factions are complicated."
	var my_faction: String = brain.faction
	var lines: Array = [
		npc_name_str + ": I run with " + my_faction + ". We keep our own.",
		npc_name_str + ": The corps and the syndicates are always at each other's throats. I stay out of it.",
		npc_name_str + ": Nexus Corp wants control. Shadow Syndicate wants chaos. We just want to live.",
		npc_name_str + ": Choose your allies carefully. Factions have long memories.",
	]
	return lines[randi() % lines.size()]

func _respond_thanks() -> String:
	var npc_name_str = _get_npc_name()
	if brain and brain.trait_friendliness >= 0.6:
		return npc_name_str + ": Anytime. Stay safe out there."
	elif brain and brain.trait_humor >= 0.6:
		return npc_name_str + ": Don't mention it. Literally — don't."
	else:
		return npc_name_str + ": Sure."

func _respond_directions() -> String:
	var npc_name_str = _get_npc_name()
	var lines: Array = [
		npc_name_str + ": Market district is north, corp towers south. The underground is... underground.",
		npc_name_str + ": Subway entrance two blocks east. Faster than walking.",
		npc_name_str + ": Depends where you're going. Be specific.",
	]
	return lines[randi() % lines.size()]

func _respond_generic(player_id: String, message: String) -> String:
	var npc_name_str = _get_npc_name()
	if brain == null:
		return npc_name_str + ": Noted."

	brain.store_memory(player_id, "conversation", message.left(80), 0.02)

	var humor: float = brain.trait_humor
	var wisdom: float = brain.trait_wisdom
	var mood: String = brain.get_mood_label()

	if humor >= 0.7:
		var lines: Array = [
			npc_name_str + ": " + message.left(20) + "... yeah, I've heard stranger things tonight.",
			npc_name_str + ": That's either brilliant or insane. Maybe both.",
			npc_name_str + ": Ha. Sure. Why not.",
		]
		return lines[randi() % lines.size()]
	elif wisdom >= 0.7:
		var lines: Array = [
			npc_name_str + ": Interesting. There's more to that than people think.",
			npc_name_str + ": Worth considering from multiple angles.",
			npc_name_str + ": I've seen enough to know that's not as simple as it sounds.",
		]
		return lines[randi() % lines.size()]
	elif mood == "angry" or mood == "fearful":
		var lines: Array = [
			npc_name_str + ": Not now.",
			npc_name_str + ": I'm not in the mood.",
			npc_name_str + ": Can you come back when things are less tense?",
		]
		return lines[randi() % lines.size()]
	else:
		var lines: Array = [
			npc_name_str + ": Yeah. Sure.",
			npc_name_str + ": Hm.",
			npc_name_str + ": I hear you.",
			npc_name_str + ": Fair enough.",
		]
		return lines[randi() % lines.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Farewell
# ─────────────────────────────────────────────────────────────────────────────

func _generate_farewell() -> String:
	var npc_name_str = _get_npc_name()
	if brain == null:
		return npc_name_str + ": Later."

	var friendliness: float = brain.trait_friendliness
	var trust: float = brain.get_player_trust(current_player_id) if current_player_id != "" else 0.0

	if friendliness >= 0.6 and trust >= 0.2:
		var lines: Array = [
			npc_name_str + ": Watch your back out there.",
			npc_name_str + ": Come find me if you need anything.",
			npc_name_str + ": Good talking. Don't be a stranger.",
		]
		return lines[randi() % lines.size()]
	elif trust <= -0.3:
		var lines: Array = [
			npc_name_str + ": Don't come back.",
			npc_name_str + ": I'll remember this.",
			npc_name_str + ": ...",
		]
		return lines[randi() % lines.size()]
	else:
		var lines: Array = [
			npc_name_str + ": Right.",
			npc_name_str + ": Later.",
			npc_name_str + ": Stay safe.",
		]
		return lines[randi() % lines.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Quest Generation
# ─────────────────────────────────────────────────────────────────────────────

func _should_offer_quest() -> bool:
	if brain == null:
		return false
	var base_chance: float = 0.2
	base_chance += brain.trait_friendliness * 0.15
	base_chance += brain.trait_curiosity * 0.1
	base_chance -= brain.get_player_trust(current_player_id).clampf(-0.1, 0.1) * -0.1
	return randf() < clampf(base_chance, 0.05, 0.8)

func generate_quest() -> Dictionary:
	if brain == null:
		return {}

	var occupation: String = brain.occupation
	var npc_name_str: String = _get_npc_name()
	var quest_id: String = npc_id_str() + "_q_" + str(randi() % 9000 + 1000)
	var trust: float = brain.get_player_trust(current_player_id) if current_player_id != "" else 0.0

	var quest: Dictionary = {}

	match occupation:
		"merchant", "shopkeeper":
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Supply Run",
				"description": "Fetch 5 units of Neon Fuel from the depot at the East Dock. Bring them back undamaged.",
				"objective_type": "fetch",
				"target_item": "neon_fuel",
				"target_count": 5,
				"reward_credits": 200 + int(trust * 50),
				"reward_item": "",
				"difficulty": "easy",
				"time_limit_hours": 6.0,
			}
		"guard", "security":
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Perimeter Check",
				"description": "Suspicious signal detected at Sector 7. Investigate and neutralize any threats.",
				"objective_type": "investigate",
				"target_location": "sector_7",
				"reward_credits": 350,
				"reward_item": "ammo_pack",
				"difficulty": "medium",
				"time_limit_hours": 3.0,
			}
		"hacker":
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Data Extraction",
				"description": "There's an encrypted data node at the abandoned factory. I need what's inside. Don't get caught.",
				"objective_type": "hack",
				"target_node": "factory_data_node",
				"reward_credits": 500,
				"reward_item": "encryption_key",
				"difficulty": "hard",
				"time_limit_hours": 4.0,
			}
		"fixer":
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Package Delivery",
				"description": "Deliver this package to 'Crow' in the Underground Market. Don't open it. Don't be late.",
				"objective_type": "deliver",
				"target_npc": "crow",
				"reward_credits": 400,
				"reward_item": "",
				"difficulty": "medium",
				"time_limit_hours": 2.0,
			}
		"street_vendor":
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Competitor Problem",
				"description": "There's a vendor undercutting my prices nearby. Convince them to move. Peacefully, ideally.",
				"objective_type": "negotiate",
				"target_npc": "rival_vendor",
				"reward_credits": 150,
				"reward_item": "food_pack",
				"difficulty": "easy",
				"time_limit_hours": 8.0,
			}
		_:
			quest = {
				"id": quest_id,
				"giver_npc": npc_id_str(),
				"title": "Small Favor",
				"description": "I need you to deliver a message to someone in the next block. Simple job.",
				"objective_type": "deliver",
				"target_npc": "contact_npc",
				"reward_credits": 100,
				"reward_item": "",
				"difficulty": "easy",
				"time_limit_hours": 12.0,
			}

	active_quests.append(quest)
	return quest

func complete_quest(quest_id: String) -> bool:
	for i in range(active_quests.size()):
		if active_quests[i].get("id", "") == quest_id:
			completed_quests.append(active_quests[i])
			active_quests.remove_at(i)
			if brain:
				brain.apply_mood_boost(0.15)
				if current_player_id != "":
					brain.store_memory(current_player_id, "quest_complete", "completed quest " + quest_id, 0.4)
			return true
	return false

func fail_quest(quest_id: String) -> bool:
	for i in range(active_quests.size()):
		if active_quests[i].get("id", "") == quest_id:
			active_quests.remove_at(i)
			if brain:
				brain.apply_mood_boost(-0.1)
				if current_player_id != "":
					brain.store_memory(current_player_id, "quest_fail", "failed quest " + quest_id, -0.3)
			return true
	return false

# ─────────────────────────────────────────────────────────────────────────────
# Gossip System
# ─────────────────────────────────────────────────────────────────────────────

func receive_gossip(gossip_entries: Array) -> void:
	for entry in gossip_entries:
		gossip_pool.append(entry)
		if brain:
			brain.receive_gossip(entry)

	# Trim pool
	while gossip_pool.size() > MAX_GOSSIP_POOL:
		gossip_pool.pop_front()

func share_gossip_with_npc(target_npc_dialogue: Node) -> void:
	if brain == null or target_npc_dialogue == null:
		return
	var my_gossip = brain.get_all_gossip_data()
	if my_gossip.is_empty():
		return
	# Share a random subset (up to 5 items)
	my_gossip.shuffle()
	var share_count: int = mini(5, my_gossip.size())
	var to_share: Array = my_gossip.slice(0, share_count)
	if target_npc_dialogue.has_method("receive_gossip"):
		target_npc_dialogue.receive_gossip(to_share)
	emit_signal("gossip_shared", {"target": target_npc_dialogue.npc_id_str(), "items": to_share})

func _share_gossip_with_player() -> void:
	if gossip_pool.is_empty():
		return
	var item = gossip_pool[randi() % gossip_pool.size()]
	var npc_name_str = _get_npc_name()
	var pid: String = item.get("player_id", "someone")
	var topic: String = item.get("topic", "something")
	var line: String = npc_name_str + ": By the way, word on the street is that " + pid + " has been involved in " + topic + ". Just saying."
	_emit_line(line)

func get_gossip_count() -> int:
	return gossip_pool.size()

# ─────────────────────────────────────────────────────────────────────────────
# Ambient Dialogue (called when not in active session)
# ─────────────────────────────────────────────────────────────────────────────

func get_ambient_line() -> String:
	if brain == null:
		return "..."

	var mood: String = brain.get_mood_label()
	var weather: String = brain.current_weather
	var hour: float = brain.current_hour
	var npc_name_str = _get_npc_name()

	var lines: Array = []

	# Time of day lines
	if hour >= 0.0 and hour < 6.0:
		lines.append_array([
			"Should be asleep by now...",
			"Night shift never ends.",
			"The city never sleeps. Neither do I.",
		])
	elif hour >= 6.0 and hour < 12.0:
		lines.append_array([
			"Another cycle begins.",
			"Coffee would help. If the dispensers weren't broken again.",
			"Morning grid checks. Same as always.",
		])
	elif hour >= 12.0 and hour < 18.0:
		lines.append_array([
			"Midday. Time moves differently here.",
			"Busy district today.",
			"Keeping an eye on things.",
		])
	else:
		lines.append_array([
			"Evening brings out the interesting ones.",
			"Night market should be setting up soon.",
			"The corps pull back at night. We come alive.",
		])

	# Weather lines
	match weather:
		"rain":
			lines.append_array(["This rain is terrible for my circuits.", "At least it keeps the hawkers inside."])
		"storm":
			lines.append_array(["Storm's knocked out half the signs.", "Grid's unstable in this weather."])
		"acid_rain":
			lines.append_array(["Don't let that stuff touch your skin.", "Acid's eating the paint off everything again."])

	# Mood lines
	match mood:
		"happy":
			lines.append_array(["Good day, all things considered.", "Things are looking up in this district."])
		"angry":
			lines.append_array(["Don't even try me right now.", "Someone's going to answer for this."])
		"fearful":
			lines.append_array(["Something's off today. Stay alert.", "Keep moving. Don't linger."])

	if lines.is_empty():
		return "..."

	return lines[randi() % lines.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────────

func _get_npc_name() -> String:
	if brain and brain.npc_name != "":
		return brain.npc_name
	return "NPC"

func npc_id_str() -> String:
	if brain and brain.npc_id != "":
		return brain.npc_id
	return "unknown_npc"

func _recall_summary(player_id: String) -> String:
	var entries = brain.recall_memories_about(player_id) if brain else []
	if entries.is_empty():
		return "came by before"
	var last = entries[entries.size() - 1]
	return last.get("detail", "was here before")

func _personality_to_phrase() -> String:
	if brain == null:
		return ""
	var f: float = brain.trait_friendliness
	var c: float = brain.trait_curiosity
	var a: float = brain.trait_aggression
	var h: float = brain.trait_humor
	var w: float = brain.trait_wisdom

	if f >= 0.7:
		return "People say I'm approachable."
	elif a >= 0.7:
		return "I don't back down easily."
	elif w >= 0.7:
		return "I've seen enough to know how things work."
	elif h >= 0.7:
		return "I try not to take things too seriously."
	elif c >= 0.7:
		return "Always curious about what's going on."
	else:
		return "I keep to myself mostly."

func _contains_any(text: String, keywords: Array) -> bool:
	for kw in keywords:
		if kw in text:
			return true
	return false
