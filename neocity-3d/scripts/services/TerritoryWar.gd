## TerritoryWar.gd
## ----------------------------------------------------------------------------
## 48-hour faction-vs-faction war engine for territory control in Neo City.
##
## Design highlights (issue #14):
##   * Any faction may DECLARE war against an *adjacent* territory controlled
##     by another faction. Declaring costs 1,000 Quant tokens pulled from the
##     declaring faction's treasury.
##   * A war runs for a fixed 48 hours. The side with the higher activity
##     score inside the contested zone at the deadline wins.
##   * Activity score = (buildings built * BUILDING_WEIGHT)
##                    + (minutes spent in zone * PRESENCE_WEIGHT)
##                    + (mini-game wins * MINIGAME_WEIGHT).
##   * Winner captures the territory; loser's buildings in the zone are
##     flagged as "damaged" (visual state consumed by BuildingDecaySystem).
##   * A 72-hour cease-fire prevents either side from re-declaring until it
##     elapses.
##
## This service is intended to be registered as an autoload singleton.
## ----------------------------------------------------------------------------

extends Node

# ---------------------------------------------------------------------------
# Tunable constants
# ---------------------------------------------------------------------------
const WAR_DURATION_SECONDS: int = 48 * 60 * 60
const CEASEFIRE_DURATION_SECONDS: int = 72 * 60 * 60
const DECLARE_WAR_COST: int = 1000                       # Quant tokens
const MIN_WAR_PARTICIPANTS_PER_SIDE: int = 2             # forfeits otherwise
const MAX_CONCURRENT_WARS_PER_FACTION: int = 2
const TICK_INTERVAL_SECONDS: float = 10.0                # scheduler tick
const PRESENCE_SAMPLE_SECONDS: int = 60                  # aggregate granularity
const BUILDING_WEIGHT: int = 50
const PRESENCE_WEIGHT: int = 5                           # per minute
const MINIGAME_WEIGHT: int = 120

# War states
enum WarState {
	PENDING = 0,
	ACTIVE = 1,
	ENDED = 2,
	CANCELLED = 3,
	FORFEITED = 4,
}

# Outcomes of `declare_war`
enum DeclareResult {
	OK,
	NOT_ADJACENT,
	TARGET_NOT_OWNED,
	SELF_ATTACK,
	INSUFFICIENT_FUNDS,
	ALREADY_AT_WAR,
	CEASEFIRE_ACTIVE,
	TOO_MANY_WARS,
	TERRITORY_NOT_FOUND,
	FACTION_NOT_FOUND,
	NOT_AUTHORISED,
}


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal war_declared(war_id: String, attacker_id: String, defender_id: String, zone_id: String)
signal war_started(war_id: String)
signal war_tick(war_id: String, attacker_score: int, defender_score: int, seconds_remaining: int)
signal war_ended(war_id: String, winner_id: String, loser_id: String, zone_id: String)
signal war_forfeited(war_id: String, forfeiting_faction: String)
signal ceasefire_started(faction_a: String, faction_b: String, zone_id: String, expires_at: int)
signal ceasefire_expired(faction_a: String, faction_b: String, zone_id: String)
signal territory_captured(zone_id: String, new_owner: String, previous_owner: String)


# ---------------------------------------------------------------------------
# Internal data classes
# ---------------------------------------------------------------------------
class Territory:
	var id: String
	var display_name: String
	var district_id: String
	var owner_faction_id: String = ""
	var neighbours: Array = []            # ids of adjacent zones
	var building_value: int = 0
	var protected_until: int = 0          # newly-captured grace period

	func _init(p_id: String = "", p_name: String = "", p_district: String = "") -> void:
		id = p_id
		display_name = p_name
		district_id = p_district

	func is_neighbour(other_id: String) -> bool:
		return neighbours.has(other_id)

	func to_dict() -> Dictionary:
		return {
			"id": id,
			"display_name": display_name,
			"district_id": district_id,
			"owner_faction_id": owner_faction_id,
			"neighbours": neighbours.duplicate(),
			"building_value": building_value,
			"protected_until": protected_until,
		}


class ActivityLedger:
	var buildings_built: int = 0
	var mini_game_wins: int = 0
	var presence_seconds: int = 0
	var last_presence_ts: int = 0

	func score() -> int:
		var minutes: int = int(floor(presence_seconds / 60.0))
		return (buildings_built * BUILDING_WEIGHT) \
			 + (minutes * PRESENCE_WEIGHT) \
			 + (mini_game_wins * MINIGAME_WEIGHT)

	func to_dict() -> Dictionary:
		return {
			"buildings_built": buildings_built,
			"mini_game_wins": mini_game_wins,
			"presence_seconds": presence_seconds,
			"score": score(),
		}


class War:
	var id: String
	var attacker_id: String
	var defender_id: String
	var zone_id: String
	var state: int = WarState.PENDING
	var started_at: int = 0
	var ends_at: int = 0
	var attacker_ledger: ActivityLedger = ActivityLedger.new()
	var defender_ledger: ActivityLedger = ActivityLedger.new()
	var participant_count: Dictionary = {}  # faction_id -> Dictionary(player_id -> last_ts)
	var event_log: Array = []               # list of Dictionaries
	var winner_id: String = ""
	var loser_id: String = ""

	func _init(p_id: String = "", p_attacker: String = "", p_defender: String = "", p_zone: String = "") -> void:
		id = p_id
		attacker_id = p_attacker
		defender_id = p_defender
		zone_id = p_zone

	func seconds_remaining(now: int) -> int:
		return max(0, ends_at - now)

	func is_participant(faction_id: String) -> bool:
		return faction_id == attacker_id or faction_id == defender_id

	func ledger_for(faction_id: String) -> ActivityLedger:
		if faction_id == attacker_id:
			return attacker_ledger
		if faction_id == defender_id:
			return defender_ledger
		return null

	func to_dict(now: int) -> Dictionary:
		return {
			"id": id,
			"attacker_id": attacker_id,
			"defender_id": defender_id,
			"zone_id": zone_id,
			"state": state,
			"started_at": started_at,
			"ends_at": ends_at,
			"seconds_remaining": seconds_remaining(now),
			"attacker": attacker_ledger.to_dict(),
			"defender": defender_ledger.to_dict(),
			"winner_id": winner_id,
			"loser_id": loser_id,
		}


class Ceasefire:
	var faction_a: String
	var faction_b: String
	var zone_id: String
	var expires_at: int

	func _init(a: String = "", b: String = "", z: String = "", exp: int = 0) -> void:
		faction_a = a
		faction_b = b
		zone_id = z
		expires_at = exp

	func involves(faction_id: String) -> bool:
		return faction_id == faction_a or faction_id == faction_b


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var _territories: Dictionary = {}          # zone_id -> Territory
var _wars: Dictionary = {}                 # war_id  -> War
var _active_wars_by_zone: Dictionary = {}  # zone_id -> war_id
var _ceasefires: Array = []                # [Ceasefire]
var _presence: Dictionary = {}             # player_id -> Dictionary(zone_id, faction_id, since_ts)
var _next_war_index: int = 1
var _tick_timer: Timer
var _faction_manager: Node = null


# ---------------------------------------------------------------------------
# Engine lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tick_timer = Timer.new()
	_tick_timer.wait_time = TICK_INTERVAL_SECONDS
	_tick_timer.one_shot = false
	_tick_timer.autostart = true
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_on_tick)
	_faction_manager = _resolve_faction_manager()
	print("[TerritoryWar] Service initialised.")


func _resolve_faction_manager() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Node = tree.root
	if root != null and root.has_node("FactionManager"):
		return root.get_node("FactionManager")
	return null


# ---------------------------------------------------------------------------
# Territory registration API — called by the city generator at load time.
# ---------------------------------------------------------------------------
func register_territory(
	zone_id: String,
	display_name: String,
	district_id: String,
	neighbours: Array = [],
	initial_owner: String = "",
	building_value: int = 0,
) -> void:
	var t: Territory = Territory.new(zone_id, display_name, district_id)
	t.neighbours = neighbours.duplicate()
	t.owner_faction_id = initial_owner
	t.building_value = building_value
	_territories[zone_id] = t


func set_neighbours(zone_id: String, neighbours: Array) -> void:
	var t: Territory = _territories.get(zone_id, null)
	if t == null:
		return
	t.neighbours = neighbours.duplicate()


func set_territory_owner(zone_id: String, faction_id: String) -> void:
	var t: Territory = _territories.get(zone_id, null)
	if t == null:
		return
	var previous: String = t.owner_faction_id
	t.owner_faction_id = faction_id
	if previous != faction_id:
		emit_signal("territory_captured", zone_id, faction_id, previous)


func get_territory(zone_id: String) -> Territory:
	return _territories.get(zone_id, null)


func get_territories_for_faction(faction_id: String) -> Array:
	var out: Array = []
	for t in _territories.values():
		if (t as Territory).owner_faction_id == faction_id:
			out.append(t)
	return out


func get_all_territories() -> Array:
	return _territories.values()


# ---------------------------------------------------------------------------
# Declaring / cancelling wars
# ---------------------------------------------------------------------------
func declare_war(
	attacker_faction_id: String,
	zone_id: String,
	acting_player_id: String,
) -> Dictionary:
	var target: Territory = _territories.get(zone_id, null)
	if target == null:
		return _res(DeclareResult.TERRITORY_NOT_FOUND, "Unknown territory.")
	if target.owner_faction_id.is_empty():
		return _res(DeclareResult.TARGET_NOT_OWNED, "Target zone is not owned.")
	if target.owner_faction_id == attacker_faction_id:
		return _res(DeclareResult.SELF_ATTACK, "Cannot attack your own land.")

	var attacker = _get_faction(attacker_faction_id)
	if attacker == null:
		return _res(DeclareResult.FACTION_NOT_FOUND, "Attacker faction missing.")
	# Only leader / officers can declare.
	if _faction_manager != null and not _faction_has_war_authority(attacker, acting_player_id):
		return _res(DeclareResult.NOT_AUTHORISED, "Only officers or leader may declare.")

	# Attacker must own at least one adjacent zone.
	var has_adjacent_ownership: bool = false
	for neighbour_id in target.neighbours:
		var n: Territory = _territories.get(neighbour_id, null)
		if n != null and n.owner_faction_id == attacker_faction_id:
			has_adjacent_ownership = true
			break
	if not has_adjacent_ownership:
		return _res(DeclareResult.NOT_ADJACENT,
			"You must own a zone adjacent to the target.")

	# Respect ceasefires.
	if _is_ceasefire_active(attacker_faction_id, target.owner_faction_id, zone_id):
		return _res(DeclareResult.CEASEFIRE_ACTIVE, "A ceasefire is still in effect.")

	# Already a war going in this zone?
	if _active_wars_by_zone.has(zone_id):
		return _res(DeclareResult.ALREADY_AT_WAR, "Zone already has an active war.")

	if _count_active_wars_for(attacker_faction_id) >= MAX_CONCURRENT_WARS_PER_FACTION:
		return _res(DeclareResult.TOO_MANY_WARS, "Your faction has too many active wars.")

	# Charge the attacker.
	if _faction_manager != null:
		if attacker.treasury < DECLARE_WAR_COST:
			return _res(DeclareResult.INSUFFICIENT_FUNDS,
				"Need %d Quant tokens in treasury." % DECLARE_WAR_COST)
		attacker.treasury -= DECLARE_WAR_COST
		_faction_manager.emit_signal("treasury_changed", attacker.id, attacker.treasury)

	# Instantiate war.
	var war_id: String = _generate_war_id()
	var war: War = War.new(war_id, attacker_faction_id, target.owner_faction_id, zone_id)
	war.state = WarState.ACTIVE
	war.started_at = Time.get_unix_time_from_system()
	war.ends_at = war.started_at + WAR_DURATION_SECONDS
	war.event_log.append(_make_event("declared", {
		"attacker": attacker_faction_id,
		"defender": target.owner_faction_id,
	}))
	_wars[war_id] = war
	_active_wars_by_zone[zone_id] = war_id

	emit_signal("war_declared", war_id, attacker_faction_id,
		target.owner_faction_id, zone_id)
	emit_signal("war_started", war_id)

	var res: Dictionary = _res(DeclareResult.OK, "War declared.")
	res["war_id"] = war_id
	return res


func cancel_war(war_id: String, acting_faction_id: String, acting_player_id: String) -> bool:
	var w: War = _wars.get(war_id, null)
	if w == null or w.state != WarState.ACTIVE:
		return false
	if acting_faction_id != w.attacker_id:
		return false
	var f = _get_faction(acting_faction_id)
	if f != null and not _faction_has_war_authority(f, acting_player_id):
		return false
	# Cancellation forfeits the war to the defender (no refund, per design).
	_end_war(w, w.defender_id, w.attacker_id, WarState.CANCELLED)
	return true


# ---------------------------------------------------------------------------
# Activity ingestion API — called by the rest of the game
# ---------------------------------------------------------------------------
func register_player_enter_zone(
	player_id: String,
	faction_id: String,
	zone_id: String,
) -> void:
	var now: int = Time.get_unix_time_from_system()
	var prior: Dictionary = _presence.get(player_id, {})
	if prior.has("zone_id") and prior["zone_id"] != zone_id:
		# Commit time accrued in the prior zone first.
		_commit_presence(player_id, prior, now)
	_presence[player_id] = {
		"zone_id": zone_id,
		"faction_id": faction_id,
		"since_ts": now,
	}


func register_player_leave_zone(player_id: String) -> void:
	if not _presence.has(player_id):
		return
	var now: int = Time.get_unix_time_from_system()
	_commit_presence(player_id, _presence[player_id], now)
	_presence.erase(player_id)


func register_building_built(faction_id: String, zone_id: String) -> void:
	var war_id: String = _active_wars_by_zone.get(zone_id, "")
	if war_id.is_empty():
		return
	var w: War = _wars[war_id]
	var ledger: ActivityLedger = w.ledger_for(faction_id)
	if ledger == null:
		return
	ledger.buildings_built += 1
	w.event_log.append(_make_event("building_built", {
		"faction": faction_id,
		"zone": zone_id,
	}))
	_notify_progress(w)


func register_mini_game_victory(faction_id: String, zone_id: String, points: int = 1) -> void:
	var war_id: String = _active_wars_by_zone.get(zone_id, "")
	if war_id.is_empty():
		return
	var w: War = _wars[war_id]
	var ledger: ActivityLedger = w.ledger_for(faction_id)
	if ledger == null:
		return
	ledger.mini_game_wins += points
	w.event_log.append(_make_event("mini_game_win", {
		"faction": faction_id,
		"zone": zone_id,
		"points": points,
	}))
	_notify_progress(w)


# ---------------------------------------------------------------------------
# Query API
# ---------------------------------------------------------------------------
func get_war(war_id: String) -> War:
	return _wars.get(war_id, null)


func get_active_war_in_zone(zone_id: String) -> War:
	var id: String = _active_wars_by_zone.get(zone_id, "")
	if id.is_empty():
		return null
	return _wars.get(id, null)


func get_active_wars_for_faction(faction_id: String) -> Array:
	var out: Array = []
	for w in _wars.values():
		if (w as War).state == WarState.ACTIVE and w.is_participant(faction_id):
			out.append(w)
	return out


func get_all_active_wars() -> Array:
	var out: Array = []
	for w in _wars.values():
		if (w as War).state == WarState.ACTIVE:
			out.append(w)
	return out


func get_war_log(war_id: String) -> Array:
	var w: War = _wars.get(war_id, null)
	if w == null:
		return []
	return w.event_log.duplicate(true)


func get_active_ceasefires() -> Array:
	return _ceasefires.duplicate()


# ---------------------------------------------------------------------------
# Internal — tick loop
# ---------------------------------------------------------------------------
func _on_tick() -> void:
	var now: int = Time.get_unix_time_from_system()

	# Accrue presence for still-in-zone players.
	for pid in _presence.keys():
		var p: Dictionary = _presence[pid]
		_commit_presence(pid, p, now)
		p["since_ts"] = now
		_presence[pid] = p

	# Progress / end active wars.
	var to_end: Array = []
	for w in _wars.values():
		var war: War = w
		if war.state != WarState.ACTIVE:
			continue
		_notify_progress(war)
		if now >= war.ends_at:
			to_end.append(war)
	for war in to_end:
		_resolve_war(war)

	# Expire ceasefires.
	var fresh: Array = []
	for cf in _ceasefires:
		if (cf as Ceasefire).expires_at <= now:
			emit_signal("ceasefire_expired", cf.faction_a, cf.faction_b, cf.zone_id)
		else:
			fresh.append(cf)
	_ceasefires = fresh


func _commit_presence(player_id: String, p: Dictionary, now: int) -> void:
	if not p.has("zone_id") or not p.has("faction_id"):
		return
	var zone_id: String = p["zone_id"]
	var faction_id: String = p["faction_id"]
	var since_ts: int = int(p.get("since_ts", now))
	var elapsed: int = max(0, now - since_ts)
	if elapsed <= 0:
		return
	var war_id: String = _active_wars_by_zone.get(zone_id, "")
	if war_id.is_empty():
		return
	var w: War = _wars[war_id]
	var ledger: ActivityLedger = w.ledger_for(faction_id)
	if ledger == null:
		return
	ledger.presence_seconds += elapsed
	ledger.last_presence_ts = now
	# Track unique participants.
	if not w.participant_count.has(faction_id):
		w.participant_count[faction_id] = {}
	(w.participant_count[faction_id] as Dictionary)[player_id] = now


func _notify_progress(w: War) -> void:
	var now: int = Time.get_unix_time_from_system()
	emit_signal(
		"war_tick",
		w.id,
		w.attacker_ledger.score(),
		w.defender_ledger.score(),
		w.seconds_remaining(now),
	)


# ---------------------------------------------------------------------------
# Internal — war resolution
# ---------------------------------------------------------------------------
func _resolve_war(w: War) -> void:
	var a_score: int = w.attacker_ledger.score()
	var d_score: int = w.defender_ledger.score()

	# Forfeit check — not enough unique participants on a side.
	var a_part: int = (w.participant_count.get(w.attacker_id, {}) as Dictionary).size()
	var d_part: int = (w.participant_count.get(w.defender_id, {}) as Dictionary).size()
	if a_part < MIN_WAR_PARTICIPANTS_PER_SIDE and d_part >= MIN_WAR_PARTICIPANTS_PER_SIDE:
		_end_war(w, w.defender_id, w.attacker_id, WarState.FORFEITED)
		return
	if d_part < MIN_WAR_PARTICIPANTS_PER_SIDE and a_part >= MIN_WAR_PARTICIPANTS_PER_SIDE:
		_end_war(w, w.attacker_id, w.defender_id, WarState.FORFEITED)
		return

	# Defender wins ties (status-quo bias).
	if a_score > d_score:
		_end_war(w, w.attacker_id, w.defender_id, WarState.ENDED)
	else:
		_end_war(w, w.defender_id, w.attacker_id, WarState.ENDED)


func _end_war(w: War, winner_id: String, loser_id: String, final_state: int) -> void:
	w.state = final_state
	w.winner_id = winner_id
	w.loser_id = loser_id
	w.event_log.append(_make_event("ended", {
		"winner": winner_id,
		"loser": loser_id,
		"state": final_state,
	}))
	_active_wars_by_zone.erase(w.zone_id)

	# Apply territory transfer if the attacker won.
	var t: Territory = _territories.get(w.zone_id, null)
	if t != null and winner_id == w.attacker_id:
		var previous: String = t.owner_faction_id
		t.owner_faction_id = winner_id
		t.protected_until = Time.get_unix_time_from_system() + CEASEFIRE_DURATION_SECONDS
		emit_signal("territory_captured", w.zone_id, winner_id, previous)
		_flag_loser_buildings_damaged(w.zone_id, loser_id)

	# Update faction stats via FactionManager (if available).
	if _faction_manager != null:
		if _faction_manager.has_method("register_war_result"):
			_faction_manager.register_war_result(winner_id, true)
			_faction_manager.register_war_result(loser_id, false)
		if _faction_manager.has_method("register_territory_delta") \
				and winner_id == w.attacker_id and t != null:
			_faction_manager.register_territory_delta(winner_id, 1, t.building_value)
			_faction_manager.register_territory_delta(loser_id, -1, -t.building_value)

	emit_signal("war_ended", w.id, winner_id, loser_id, w.zone_id)
	if final_state == WarState.FORFEITED:
		emit_signal("war_forfeited", w.id, loser_id)

	# Start ceasefire between the two factions for this zone.
	_start_ceasefire(w.attacker_id, w.defender_id, w.zone_id)


func _start_ceasefire(faction_a: String, faction_b: String, zone_id: String) -> void:
	var now: int = Time.get_unix_time_from_system()
	var cf: Ceasefire = Ceasefire.new(faction_a, faction_b, zone_id, now + CEASEFIRE_DURATION_SECONDS)
	_ceasefires.append(cf)
	emit_signal("ceasefire_started", faction_a, faction_b, zone_id, cf.expires_at)


func _flag_loser_buildings_damaged(zone_id: String, loser_faction: String) -> void:
	# The BuildingDecaySystem subscribes to this signal via a top-level hook;
	# we emit through the FactionManager so it is observable without a
	# hard dependency on the decay subsystem.
	if _faction_manager != null and _faction_manager.has_signal("stats_updated"):
		_faction_manager.emit_signal("stats_updated", loser_faction)
	# The concrete decay pass happens when BuildingDecaySystem reads
	# `Territory.protected_until` / the owner transition.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for group_name in ["building_decay_listeners"]:
		for listener in tree.get_nodes_in_group(group_name):
			if listener.has_method("on_territory_captured"):
				listener.on_territory_captured(zone_id, loser_faction)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _is_ceasefire_active(faction_a: String, faction_b: String, zone_id: String) -> bool:
	var now: int = Time.get_unix_time_from_system()
	for cf in _ceasefires:
		var c: Ceasefire = cf
		if c.expires_at <= now:
			continue
		if c.zone_id != zone_id:
			continue
		if (c.faction_a == faction_a and c.faction_b == faction_b) \
				or (c.faction_a == faction_b and c.faction_b == faction_a):
			return true
	return false


func _count_active_wars_for(faction_id: String) -> int:
	var c: int = 0
	for w in _wars.values():
		if (w as War).state == WarState.ACTIVE and w.is_participant(faction_id):
			c += 1
	return c


func _generate_war_id() -> String:
	var idx: int = _next_war_index
	_next_war_index += 1
	return "WAR-%06d" % idx


func _make_event(event_type: String, payload: Dictionary) -> Dictionary:
	return {
		"type": event_type,
		"ts": Time.get_unix_time_from_system(),
		"payload": payload,
	}


func _res(code: int, message: String) -> Dictionary:
	return {"code": code, "message": message}


func _get_faction(faction_id: String):
	if _faction_manager == null:
		return null
	if _faction_manager.has_method("get_faction"):
		return _faction_manager.get_faction(faction_id)
	return null


func _faction_has_war_authority(f: Object, player_id: String) -> bool:
	if f == null:
		return false
	if not f.has_method("role_of"):
		return true
	var role: int = f.role_of(player_id)
	# Role.OFFICER == 2, Role.LEADER == 3 in FactionManager
	return role >= 2


# ---------------------------------------------------------------------------
# Debug helpers
# ---------------------------------------------------------------------------
func debug_force_end(war_id: String, winner_id: String) -> void:
	var w: War = _wars.get(war_id, null)
	if w == null or w.state != WarState.ACTIVE:
		return
	var loser_id: String = w.defender_id if winner_id == w.attacker_id else w.attacker_id
	_end_war(w, winner_id, loser_id, WarState.ENDED)


func debug_state_snapshot() -> Dictionary:
	var now: int = Time.get_unix_time_from_system()
	var wars_out: Array = []
	for w in _wars.values():
		wars_out.append((w as War).to_dict(now))
	var cfs_out: Array = []
	for cf in _ceasefires:
		cfs_out.append({
			"faction_a": (cf as Ceasefire).faction_a,
			"faction_b": cf.faction_b,
			"zone_id": cf.zone_id,
			"expires_at": cf.expires_at,
		})
	var zones: Array = []
	for z in _territories.values():
		zones.append((z as Territory).to_dict())
	return {
		"territories": zones,
		"wars": wars_out,
		"ceasefires": cfs_out,
	}
