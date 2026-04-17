## FactionManager.gd
## ----------------------------------------------------------------------------
## Central service that owns every faction living inside a Neo City district.
##
## Responsibilities:
##   * Keep an authoritative, in-memory registry of all factions, their roles,
##     rosters, treasuries and aggregate statistics.
##   * Enforce the business rules defined in issue #14:
##       - Maximum of three (3) factions per city district.
##       - Minimum of five (5) players required to *form* a faction.
##       - Role hierarchy: Leader (1) / Officer (max 3) / Member (unlimited).
##   * Expose a clean API for join-application, invite, accept/decline, kick
##     and ban flows (all network-replicated through NetworkManager /
##     SocketIOClient when available).
##   * Broadcast faction chat messages on a dedicated Socket.IO channel.
##   * Aggregate statistics consumed by the FactionUI, TerritoryWar service,
##     the SeasonSystem and the MiniGameSystem.
##
## This node is intended to be registered as an autoload singleton so that any
## other system can simply do `FactionManager.get_faction(id)`.
## ----------------------------------------------------------------------------

extends Node

# ---------------------------------------------------------------------------
# Constants — configuration values mandated by the design document
# ---------------------------------------------------------------------------
const MAX_FACTIONS_PER_DISTRICT: int = 3
const MIN_PLAYERS_TO_FORM_FACTION: int = 5
const MAX_OFFICERS_PER_FACTION: int = 3
const CREATE_FACTION_COST: int = 500            # Quant tokens
const RENAME_FACTION_COST: int = 250
const RECOLOR_FACTION_COST: int = 100
const CHAT_HISTORY_LIMIT: int = 200
const INVITE_EXPIRY_SECONDS: int = 60 * 60 * 24 # 24 hours
const APPLICATION_EXPIRY_SECONDS: int = 60 * 60 * 72 # 72 hours
const BAN_COOLDOWN_SECONDS: int = 60 * 60 * 24 * 7   # 7 days

# Role identifiers — stored as ints for compact network encoding
enum Role {
	NONE = 0,
	MEMBER = 1,
	OFFICER = 2,
	LEADER = 3,
}

# Faction-creation outcomes — used by UI layer for localised feedback
enum CreateResult {
	OK,
	DISTRICT_FULL,
	NOT_ENOUGH_MEMBERS,
	DUPLICATE_NAME,
	INSUFFICIENT_FUNDS,
	INVALID_NAME,
	NETWORK_ERROR,
}

enum JoinResult {
	OK,
	FACTION_NOT_FOUND,
	ALREADY_MEMBER,
	BANNED,
	CLOSED_RECRUITMENT,
	APPLICATION_PENDING,
}

# ---------------------------------------------------------------------------
# Signals — the rest of the game listens to these instead of polling
# ---------------------------------------------------------------------------
signal faction_created(faction_id: String, district_id: String)
signal faction_disbanded(faction_id: String, district_id: String)
signal faction_renamed(faction_id: String, new_name: String)
signal faction_recolored(faction_id: String, new_color: Color)
signal member_joined(faction_id: String, player_id: String, role: int)
signal member_left(faction_id: String, player_id: String)
signal member_role_changed(faction_id: String, player_id: String, new_role: int)
signal member_banned(faction_id: String, player_id: String)
signal invite_sent(faction_id: String, player_id: String)
signal invite_cancelled(faction_id: String, player_id: String)
signal application_received(faction_id: String, player_id: String)
signal application_resolved(faction_id: String, player_id: String, accepted: bool)
signal chat_message(faction_id: String, player_id: String, text: String, ts: int)
signal stats_updated(faction_id: String)
signal treasury_changed(faction_id: String, new_balance: int)

# ---------------------------------------------------------------------------
# Internal data classes
# ---------------------------------------------------------------------------
class FactionMember:
	var player_id: String
	var display_name: String
	var role: int = Role.MEMBER
	var joined_at: int = 0
	var contribution_points: int = 0
	var last_active_ts: int = 0

	func _init(p_id: String = "", p_name: String = "", p_role: int = Role.MEMBER) -> void:
		player_id = p_id
		display_name = p_name
		role = p_role
		joined_at = Time.get_unix_time_from_system()
		last_active_ts = joined_at

	func to_dict() -> Dictionary:
		return {
			"player_id": player_id,
			"display_name": display_name,
			"role": role,
			"joined_at": joined_at,
			"contribution_points": contribution_points,
			"last_active_ts": last_active_ts,
		}


class FactionInvite:
	var faction_id: String
	var player_id: String
	var issued_by: String
	var issued_at: int
	var expires_at: int

	func _init(p_fid: String = "", p_pid: String = "", p_issuer: String = "") -> void:
		faction_id = p_fid
		player_id = p_pid
		issued_by = p_issuer
		issued_at = Time.get_unix_time_from_system()
		expires_at = issued_at + INVITE_EXPIRY_SECONDS


class FactionApplication:
	var faction_id: String
	var player_id: String
	var message: String
	var submitted_at: int
	var expires_at: int

	func _init(p_fid: String = "", p_pid: String = "", p_msg: String = "") -> void:
		faction_id = p_fid
		player_id = p_pid
		message = p_msg
		submitted_at = Time.get_unix_time_from_system()
		expires_at = submitted_at + APPLICATION_EXPIRY_SECONDS


class FactionStats:
	var territory_count: int = 0
	var total_building_value: int = 0
	var member_count: int = 0
	var war_wins: int = 0
	var war_losses: int = 0
	var war_points_season: int = 0
	var mini_games_won: int = 0
	var buildings_constructed: int = 0
	var last_update_ts: int = 0

	func to_dict() -> Dictionary:
		return {
			"territory_count": territory_count,
			"total_building_value": total_building_value,
			"member_count": member_count,
			"war_wins": war_wins,
			"war_losses": war_losses,
			"war_points_season": war_points_season,
			"mini_games_won": mini_games_won,
			"buildings_constructed": buildings_constructed,
			"last_update_ts": last_update_ts,
		}


class Faction:
	var id: String
	var name: String
	var tag: String                           # 3-4 letter tag shown above players
	var color: Color = Color(1, 0.2, 0.7)
	var banner_style: String = "default"
	var motto: String = ""
	var district_id: String
	var created_at: int
	var open_recruitment: bool = true
	var treasury: int = 0
	var members: Dictionary = {}              # player_id -> FactionMember
	var banned_players: Dictionary = {}       # player_id -> expires_at (int)
	var invites: Dictionary = {}              # player_id -> FactionInvite
	var applications: Dictionary = {}         # player_id -> FactionApplication
	var stats: FactionStats = FactionStats.new()
	var chat_history: Array = []              # [{player_id, text, ts}]
	var owned_territories: Array = []         # zone_ids
	var allied_factions: Array = []           # faction_ids
	var hostile_factions: Array = []          # faction_ids

	func _init(p_id: String = "", p_name: String = "", p_district: String = "") -> void:
		id = p_id
		name = p_name
		district_id = p_district
		created_at = Time.get_unix_time_from_system()

	func leader_id() -> String:
		for pid in members:
			var m: FactionMember = members[pid]
			if m.role == Role.LEADER:
				return pid
		return ""

	func officer_count() -> int:
		var c: int = 0
		for pid in members:
			var m: FactionMember = members[pid]
			if m.role == Role.OFFICER:
				c += 1
		return c

	func is_member(pid: String) -> bool:
		return members.has(pid)

	func role_of(pid: String) -> int:
		if members.has(pid):
			return (members[pid] as FactionMember).role
		return Role.NONE

	func to_dict() -> Dictionary:
		var mem_list: Array = []
		for pid in members:
			mem_list.append((members[pid] as FactionMember).to_dict())
		return {
			"id": id,
			"name": name,
			"tag": tag,
			"color": [color.r, color.g, color.b, color.a],
			"banner_style": banner_style,
			"motto": motto,
			"district_id": district_id,
			"created_at": created_at,
			"open_recruitment": open_recruitment,
			"treasury": treasury,
			"members": mem_list,
			"owned_territories": owned_territories.duplicate(),
			"stats": stats.to_dict(),
		}


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var _factions: Dictionary = {}                 # faction_id -> Faction
var _district_to_factions: Dictionary = {}     # district_id -> [faction_id]
var _player_to_faction: Dictionary = {}        # player_id  -> faction_id
var _name_index: Dictionary = {}               # lowercased name -> faction_id
var _ban_journal: Array = []                   # audit trail
var _next_faction_index: int = 1
var _initialised: bool = false
var _cleanup_timer: Timer


# ---------------------------------------------------------------------------
# Engine callbacks
# ---------------------------------------------------------------------------
func _ready() -> void:
	if _initialised:
		return
	_initialised = true
	process_mode = Node.PROCESS_MODE_ALWAYS

	_cleanup_timer = Timer.new()
	_cleanup_timer.wait_time = 60.0
	_cleanup_timer.one_shot = false
	_cleanup_timer.autostart = true
	add_child(_cleanup_timer)
	_cleanup_timer.timeout.connect(_on_cleanup_tick)

	_register_socket_handlers()
	print("[FactionManager] Service ready — awaiting faction activity.")


# ---------------------------------------------------------------------------
# Socket.IO integration — optional; we degrade gracefully offline.
# ---------------------------------------------------------------------------
func _register_socket_handlers() -> void:
	var nm = _get_network_manager()
	if nm == null or nm.socket_client == null:
		return
	var sc = nm.socket_client
	if sc.has_signal("event_received"):
		if not sc.is_connected("event_received", Callable(self, "_on_socket_event")):
			sc.connect("event_received", Callable(self, "_on_socket_event"))


func _get_network_manager() -> Node:
	if Engine.has_singleton("NetworkManager"):
		return Engine.get_singleton("NetworkManager")
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Node = tree.root
	if root != null and root.has_node("NetworkManager"):
		return root.get_node("NetworkManager")
	return null


func _send_socket_event(event_name: String, payload: Dictionary) -> void:
	var nm = _get_network_manager()
	if nm == null or nm.socket_client == null:
		return
	nm.socket_client.send_event(event_name, payload)


func _on_socket_event(event_name: String, data: Variant) -> void:
	# Mirror server-authoritative mutations into the local cache.
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	match event_name:
		"faction:sync":
			_ingest_remote_faction(d)
		"faction:chat":
			_ingest_remote_chat(d)
		"faction:member_update":
			_ingest_remote_member_update(d)
		"faction:disbanded":
			_remove_faction(d.get("faction_id", ""))


# ---------------------------------------------------------------------------
# Public API — creation / disbanding
# ---------------------------------------------------------------------------
func create_faction(
	leader_id: String,
	leader_name: String,
	district_id: String,
	name: String,
	tag: String,
	color: Color,
	founding_members: Array,
	leader_tokens: int,
) -> Dictionary:
	# Validate name and district availability.
	if not _is_valid_faction_name(name):
		return _result(CreateResult.INVALID_NAME, "Invalid faction name.")
	if _name_index.has(name.to_lower()):
		return _result(CreateResult.DUPLICATE_NAME, "Name already taken.")
	if leader_tokens < CREATE_FACTION_COST:
		return _result(CreateResult.INSUFFICIENT_FUNDS,
			"Need %d Quant tokens to create." % CREATE_FACTION_COST)

	var district_factions: Array = _district_to_factions.get(district_id, [])
	if district_factions.size() >= MAX_FACTIONS_PER_DISTRICT:
		return _result(CreateResult.DISTRICT_FULL,
			"District already hosts %d factions." % MAX_FACTIONS_PER_DISTRICT)

	# Count unique founding members including leader.
	var founders: Dictionary = {}
	founders[leader_id] = leader_name
	for entry in founding_members:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var pid: String = str(entry.get("player_id", ""))
		if pid.is_empty() or pid == leader_id:
			continue
		founders[pid] = str(entry.get("display_name", pid))
	if founders.size() < MIN_PLAYERS_TO_FORM_FACTION:
		return _result(CreateResult.NOT_ENOUGH_MEMBERS,
			"At least %d players required." % MIN_PLAYERS_TO_FORM_FACTION)

	# Build faction.
	var faction_id: String = _generate_faction_id(district_id)
	var faction: Faction = Faction.new(faction_id, name, district_id)
	faction.tag = _sanitise_tag(tag)
	faction.color = color
	for pid in founders:
		var role: int = Role.LEADER if pid == leader_id else Role.MEMBER
		var member: FactionMember = FactionMember.new(pid, founders[pid], role)
		faction.members[pid] = member
		_player_to_faction[pid] = faction_id
	faction.stats.member_count = faction.members.size()
	faction.treasury = 0

	_factions[faction_id] = faction
	_name_index[name.to_lower()] = faction_id
	if not _district_to_factions.has(district_id):
		_district_to_factions[district_id] = []
	_district_to_factions[district_id].append(faction_id)

	emit_signal("faction_created", faction_id, district_id)
	for pid in founders:
		emit_signal("member_joined", faction_id, pid, faction.members[pid].role)

	_send_socket_event("faction:create", faction.to_dict())

	var res: Dictionary = _result(CreateResult.OK, "Faction created.")
	res["faction_id"] = faction_id
	return res


func disband_faction(faction_id: String, acting_player_id: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if f.role_of(acting_player_id) != Role.LEADER:
		push_warning("[FactionManager] Only the leader may disband the faction.")
		return false

	_remove_faction(faction_id)
	_send_socket_event("faction:disband", {"faction_id": faction_id})
	return true


func _remove_faction(faction_id: String) -> void:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return
	for pid in f.members.keys():
		_player_to_faction.erase(pid)
	_factions.erase(faction_id)
	_name_index.erase(f.name.to_lower())
	if _district_to_factions.has(f.district_id):
		var arr: Array = _district_to_factions[f.district_id]
		arr.erase(faction_id)
		if arr.is_empty():
			_district_to_factions.erase(f.district_id)
	emit_signal("faction_disbanded", faction_id, f.district_id)


# ---------------------------------------------------------------------------
# Public API — roster management
# ---------------------------------------------------------------------------
func apply_to_faction(faction_id: String, player_id: String, message: String = "") -> int:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return JoinResult.FACTION_NOT_FOUND
	if f.is_member(player_id):
		return JoinResult.ALREADY_MEMBER
	if _is_player_banned(f, player_id):
		return JoinResult.BANNED
	if not f.open_recruitment:
		return JoinResult.CLOSED_RECRUITMENT
	if f.applications.has(player_id):
		return JoinResult.APPLICATION_PENDING

	var app: FactionApplication = FactionApplication.new(faction_id, player_id, message)
	f.applications[player_id] = app
	emit_signal("application_received", faction_id, player_id)
	_send_socket_event("faction:apply", {
		"faction_id": faction_id,
		"player_id": player_id,
		"message": message,
	})
	return JoinResult.OK


func resolve_application(
	faction_id: String,
	player_id: String,
	acting_player_id: String,
	accept: bool,
	display_name: String = "",
) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if not _has_officer_rights(f, acting_player_id):
		return false
	if not f.applications.has(player_id):
		return false

	f.applications.erase(player_id)
	emit_signal("application_resolved", faction_id, player_id, accept)
	if accept:
		_attach_member(f, player_id, display_name)
	_send_socket_event("faction:application_resolved", {
		"faction_id": faction_id,
		"player_id": player_id,
		"accepted": accept,
	})
	return true


func invite_player(faction_id: String, player_id: String, acting_player_id: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if not _has_officer_rights(f, acting_player_id):
		return false
	if f.is_member(player_id):
		return false
	if _is_player_banned(f, player_id):
		return false
	if f.invites.has(player_id):
		return false

	var inv: FactionInvite = FactionInvite.new(faction_id, player_id, acting_player_id)
	f.invites[player_id] = inv
	emit_signal("invite_sent", faction_id, player_id)
	_send_socket_event("faction:invite", {
		"faction_id": faction_id,
		"player_id": player_id,
		"issued_by": acting_player_id,
	})
	return true


func cancel_invite(faction_id: String, player_id: String, acting_player_id: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.invites.has(player_id):
		return false
	if not _has_officer_rights(f, acting_player_id):
		return false
	f.invites.erase(player_id)
	emit_signal("invite_cancelled", faction_id, player_id)
	_send_socket_event("faction:invite_cancelled", {
		"faction_id": faction_id,
		"player_id": player_id,
	})
	return true


func accept_invite(faction_id: String, player_id: String, display_name: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.invites.has(player_id):
		return false
	f.invites.erase(player_id)
	_attach_member(f, player_id, display_name)
	_send_socket_event("faction:invite_accepted", {
		"faction_id": faction_id,
		"player_id": player_id,
	})
	return true


func decline_invite(faction_id: String, player_id: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.invites.has(player_id):
		return false
	f.invites.erase(player_id)
	_send_socket_event("faction:invite_declined", {
		"faction_id": faction_id,
		"player_id": player_id,
	})
	return true


func leave_faction(player_id: String) -> bool:
	var fid: String = _player_to_faction.get(player_id, "")
	if fid.is_empty():
		return false
	var f: Faction = _factions.get(fid, null)
	if f == null:
		return false
	if f.role_of(player_id) == Role.LEADER and f.members.size() > 1:
		# Promote the most senior officer (or earliest joined member) first.
		_transfer_leadership_to_next(f, player_id)
	_detach_member(f, player_id)
	if f.members.is_empty():
		_remove_faction(fid)
	_send_socket_event("faction:leave", {
		"faction_id": fid,
		"player_id": player_id,
	})
	return true


func kick_member(
	faction_id: String,
	player_id: String,
	acting_player_id: String,
	reason: String = "",
) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.is_member(player_id):
		return false
	if not _has_officer_rights(f, acting_player_id):
		return false
	if f.role_of(player_id) == Role.LEADER:
		return false
	if f.role_of(player_id) == Role.OFFICER and f.role_of(acting_player_id) != Role.LEADER:
		return false
	_detach_member(f, player_id)
	_send_socket_event("faction:kick", {
		"faction_id": faction_id,
		"player_id": player_id,
		"reason": reason,
	})
	return true


func ban_member(
	faction_id: String,
	player_id: String,
	acting_player_id: String,
	reason: String = "",
) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if f.role_of(acting_player_id) != Role.LEADER:
		return false
	if f.role_of(player_id) == Role.LEADER:
		return false
	if f.is_member(player_id):
		_detach_member(f, player_id)
	var expiry: int = Time.get_unix_time_from_system() + BAN_COOLDOWN_SECONDS
	f.banned_players[player_id] = expiry
	_ban_journal.append({
		"faction_id": faction_id,
		"player_id": player_id,
		"acting_player_id": acting_player_id,
		"reason": reason,
		"ts": Time.get_unix_time_from_system(),
	})
	emit_signal("member_banned", faction_id, player_id)
	_send_socket_event("faction:ban", {
		"faction_id": faction_id,
		"player_id": player_id,
		"reason": reason,
		"expires_at": expiry,
	})
	return true


func unban_member(faction_id: String, player_id: String, acting_player_id: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.banned_players.has(player_id):
		return false
	if f.role_of(acting_player_id) != Role.LEADER:
		return false
	f.banned_players.erase(player_id)
	_send_socket_event("faction:unban", {
		"faction_id": faction_id,
		"player_id": player_id,
	})
	return true


func promote_member(
	faction_id: String,
	player_id: String,
	acting_player_id: String,
) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.is_member(player_id):
		return false
	if f.role_of(acting_player_id) != Role.LEADER:
		return false
	var current_role: int = f.role_of(player_id)
	if current_role == Role.LEADER:
		return false
	if current_role == Role.MEMBER:
		if f.officer_count() >= MAX_OFFICERS_PER_FACTION:
			push_warning("[FactionManager] Officer cap reached.")
			return false
		(f.members[player_id] as FactionMember).role = Role.OFFICER
		emit_signal("member_role_changed", faction_id, player_id, Role.OFFICER)
		_send_socket_event("faction:promote", {
			"faction_id": faction_id,
			"player_id": player_id,
			"role": Role.OFFICER,
		})
		return true
	# Promote officer to leader → demote current leader to officer.
	if current_role == Role.OFFICER:
		(f.members[acting_player_id] as FactionMember).role = Role.OFFICER
		(f.members[player_id] as FactionMember).role = Role.LEADER
		emit_signal("member_role_changed", faction_id, acting_player_id, Role.OFFICER)
		emit_signal("member_role_changed", faction_id, player_id, Role.LEADER)
		_send_socket_event("faction:transfer_leadership", {
			"faction_id": faction_id,
			"new_leader": player_id,
		})
		return true
	return false


func demote_member(
	faction_id: String,
	player_id: String,
	acting_player_id: String,
) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.is_member(player_id):
		return false
	if f.role_of(acting_player_id) != Role.LEADER:
		return false
	if f.role_of(player_id) != Role.OFFICER:
		return false
	(f.members[player_id] as FactionMember).role = Role.MEMBER
	emit_signal("member_role_changed", faction_id, player_id, Role.MEMBER)
	_send_socket_event("faction:demote", {
		"faction_id": faction_id,
		"player_id": player_id,
	})
	return true


func set_recruitment_open(faction_id: String, acting_player_id: String, is_open: bool) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if not _has_officer_rights(f, acting_player_id):
		return false
	f.open_recruitment = is_open
	_send_socket_event("faction:recruitment", {
		"faction_id": faction_id,
		"open": is_open,
	})
	return true


# ---------------------------------------------------------------------------
# Public API — chat
# ---------------------------------------------------------------------------
func send_chat(faction_id: String, player_id: String, text: String) -> bool:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.is_member(player_id):
		return false
	var clean: String = text.strip_edges()
	if clean.is_empty():
		return false
	var entry: Dictionary = {
		"player_id": player_id,
		"text": clean,
		"ts": Time.get_unix_time_from_system(),
	}
	f.chat_history.append(entry)
	while f.chat_history.size() > CHAT_HISTORY_LIMIT:
		f.chat_history.pop_front()
	emit_signal("chat_message", faction_id, player_id, clean, entry.ts)
	_send_socket_event("faction:chat", {
		"faction_id": faction_id,
		"player_id": player_id,
		"text": clean,
	})
	return true


func get_chat_history(faction_id: String, limit: int = 50) -> Array:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return []
	var size: int = f.chat_history.size()
	var start: int = max(0, size - limit)
	return f.chat_history.slice(start, size)


# ---------------------------------------------------------------------------
# Public API — treasury & economy hooks
# ---------------------------------------------------------------------------
func deposit(faction_id: String, player_id: String, amount: int) -> bool:
	if amount <= 0:
		return false
	var f: Faction = _factions.get(faction_id, null)
	if f == null or not f.is_member(player_id):
		return false
	f.treasury += amount
	(f.members[player_id] as FactionMember).contribution_points += amount
	emit_signal("treasury_changed", faction_id, f.treasury)
	_send_socket_event("faction:treasury_deposit", {
		"faction_id": faction_id,
		"player_id": player_id,
		"amount": amount,
	})
	return true


func withdraw(faction_id: String, player_id: String, amount: int) -> bool:
	if amount <= 0:
		return false
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return false
	if f.role_of(player_id) < Role.OFFICER:
		return false
	if f.treasury < amount:
		return false
	f.treasury -= amount
	emit_signal("treasury_changed", faction_id, f.treasury)
	_send_socket_event("faction:treasury_withdraw", {
		"faction_id": faction_id,
		"player_id": player_id,
		"amount": amount,
	})
	return true


# ---------------------------------------------------------------------------
# Public API — stats & queries (consumed by FactionUI, SeasonSystem, ...)
# ---------------------------------------------------------------------------
func get_faction(faction_id: String) -> Faction:
	return _factions.get(faction_id, null)


func get_faction_for_player(player_id: String) -> Faction:
	var fid: String = _player_to_faction.get(player_id, "")
	if fid.is_empty():
		return null
	return _factions.get(fid, null)


func get_all_factions() -> Array:
	return _factions.values()


func get_factions_in_district(district_id: String) -> Array:
	var ids: Array = _district_to_factions.get(district_id, [])
	var out: Array = []
	for id in ids:
		var f: Faction = _factions.get(id, null)
		if f != null:
			out.append(f)
	return out


func get_leaderboard(sort_by: String = "war_points_season", limit: int = 25) -> Array:
	var rows: Array = []
	for f in _factions.values():
		var stat_dict: Dictionary = f.stats.to_dict()
		rows.append({
			"faction_id": f.id,
			"name": f.name,
			"tag": f.tag,
			"district_id": f.district_id,
			"color": f.color,
			"score": stat_dict.get(sort_by, 0),
			"stats": stat_dict,
		})
	rows.sort_custom(func(a, b): return a.score > b.score)
	if rows.size() > limit:
		rows.resize(limit)
	return rows


func award_war_points(faction_id: String, amount: int) -> void:
	var f: Faction = _factions.get(faction_id, null)
	if f == null or amount == 0:
		return
	f.stats.war_points_season += amount
	f.stats.last_update_ts = Time.get_unix_time_from_system()
	emit_signal("stats_updated", faction_id)


func register_mini_game_win(faction_id: String) -> void:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return
	f.stats.mini_games_won += 1
	emit_signal("stats_updated", faction_id)


func register_territory_delta(faction_id: String, delta: int, value_delta: int = 0) -> void:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return
	f.stats.territory_count = max(0, f.stats.territory_count + delta)
	f.stats.total_building_value = max(0, f.stats.total_building_value + value_delta)
	emit_signal("stats_updated", faction_id)


func register_war_result(faction_id: String, victory: bool) -> void:
	var f: Faction = _factions.get(faction_id, null)
	if f == null:
		return
	if victory:
		f.stats.war_wins += 1
	else:
		f.stats.war_losses += 1
	emit_signal("stats_updated", faction_id)


func reset_season_stats() -> void:
	# Invoked by SeasonSystem at the end of every 30-day cycle.
	for f in _factions.values():
		f.stats.war_points_season = 0
		f.stats.last_update_ts = Time.get_unix_time_from_system()
		emit_signal("stats_updated", f.id)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------
func _attach_member(f: Faction, player_id: String, display_name: String) -> void:
	if f.is_member(player_id):
		return
	var m: FactionMember = FactionMember.new(player_id, display_name, Role.MEMBER)
	f.members[player_id] = m
	f.stats.member_count = f.members.size()
	_player_to_faction[player_id] = f.id
	emit_signal("member_joined", f.id, player_id, Role.MEMBER)
	emit_signal("stats_updated", f.id)


func _detach_member(f: Faction, player_id: String) -> void:
	if not f.members.has(player_id):
		return
	f.members.erase(player_id)
	f.stats.member_count = f.members.size()
	_player_to_faction.erase(player_id)
	emit_signal("member_left", f.id, player_id)
	emit_signal("stats_updated", f.id)


func _transfer_leadership_to_next(f: Faction, leaving_leader: String) -> void:
	# Prefer an officer, then the earliest-joined member.
	var candidate: String = ""
	var best_ts: int = 0x7FFFFFFFFFFFFFFF
	for pid in f.members:
		if pid == leaving_leader:
			continue
		var m: FactionMember = f.members[pid]
		if m.role == Role.OFFICER:
			candidate = pid
			break
		if m.joined_at < best_ts:
			best_ts = m.joined_at
			candidate = pid
	if candidate.is_empty():
		return
	(f.members[candidate] as FactionMember).role = Role.LEADER
	emit_signal("member_role_changed", f.id, candidate, Role.LEADER)


func _has_officer_rights(f: Faction, player_id: String) -> bool:
	var r: int = f.role_of(player_id)
	return r == Role.OFFICER or r == Role.LEADER


func _is_player_banned(f: Faction, player_id: String) -> bool:
	if not f.banned_players.has(player_id):
		return false
	var expires_at: int = int(f.banned_players[player_id])
	if Time.get_unix_time_from_system() >= expires_at:
		f.banned_players.erase(player_id)
		return false
	return true


func _is_valid_faction_name(name: String) -> bool:
	var n: String = name.strip_edges()
	if n.length() < 3 or n.length() > 24:
		return false
	# Allowed characters: alphanumerics, spaces, dashes and apostrophes.
	for i in n.length():
		var c: String = n.substr(i, 1)
		var code: int = c.unicode_at(0)
		var is_alpha: bool = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_digit: bool = code >= 48 and code <= 57
		if not (is_alpha or is_digit or c == " " or c == "-" or c == "'"):
			return false
	return true


func _sanitise_tag(tag: String) -> String:
	var t: String = tag.strip_edges().to_upper()
	if t.length() > 4:
		t = t.substr(0, 4)
	return t


func _generate_faction_id(district_id: String) -> String:
	var idx: int = _next_faction_index
	_next_faction_index += 1
	var short_district: String = district_id.substr(0, 4).to_upper()
	return "FCT-%s-%04d" % [short_district, idx]


func _result(code: int, message: String) -> Dictionary:
	return {"code": code, "message": message}


# ---------------------------------------------------------------------------
# Periodic cleanup — expire invites / applications / bans.
# ---------------------------------------------------------------------------
func _on_cleanup_tick() -> void:
	var now: int = Time.get_unix_time_from_system()
	for f in _factions.values():
		var expired_invites: Array = []
		for pid in f.invites:
			var inv: FactionInvite = f.invites[pid]
			if inv.expires_at <= now:
				expired_invites.append(pid)
		for pid in expired_invites:
			f.invites.erase(pid)
			emit_signal("invite_cancelled", f.id, pid)

		var expired_apps: Array = []
		for pid in f.applications:
			var app: FactionApplication = f.applications[pid]
			if app.expires_at <= now:
				expired_apps.append(pid)
		for pid in expired_apps:
			f.applications.erase(pid)
			emit_signal("application_resolved", f.id, pid, false)

		var expired_bans: Array = []
		for pid in f.banned_players:
			if int(f.banned_players[pid]) <= now:
				expired_bans.append(pid)
		for pid in expired_bans:
			f.banned_players.erase(pid)


# ---------------------------------------------------------------------------
# Server reconciliation helpers
# ---------------------------------------------------------------------------
func _ingest_remote_faction(data: Dictionary) -> void:
	var fid: String = str(data.get("id", ""))
	if fid.is_empty():
		return
	var f: Faction = _factions.get(fid, null)
	var is_new: bool = f == null
	if is_new:
		f = Faction.new(fid, str(data.get("name", "")), str(data.get("district_id", "")))
		_factions[fid] = f
		_name_index[f.name.to_lower()] = fid
		if not _district_to_factions.has(f.district_id):
			_district_to_factions[f.district_id] = []
		_district_to_factions[f.district_id].append(fid)
	f.tag = str(data.get("tag", f.tag))
	f.motto = str(data.get("motto", f.motto))
	f.banner_style = str(data.get("banner_style", f.banner_style))
	f.open_recruitment = bool(data.get("open_recruitment", f.open_recruitment))
	f.treasury = int(data.get("treasury", f.treasury))
	if data.has("color") and typeof(data["color"]) == TYPE_ARRAY:
		var c: Array = data["color"]
		if c.size() >= 3:
			f.color = Color(c[0], c[1], c[2], c[3] if c.size() > 3 else 1.0)

	if data.has("members") and typeof(data["members"]) == TYPE_ARRAY:
		f.members.clear()
		for raw in data["members"]:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			var m: FactionMember = FactionMember.new(
				str(raw.get("player_id", "")),
				str(raw.get("display_name", "")),
				int(raw.get("role", Role.MEMBER)),
			)
			m.joined_at = int(raw.get("joined_at", m.joined_at))
			m.contribution_points = int(raw.get("contribution_points", 0))
			f.members[m.player_id] = m
			_player_to_faction[m.player_id] = fid
		f.stats.member_count = f.members.size()

	if data.has("owned_territories"):
		f.owned_territories = (data["owned_territories"] as Array).duplicate()

	if data.has("stats") and typeof(data["stats"]) == TYPE_DICTIONARY:
		var s: Dictionary = data["stats"]
		f.stats.territory_count = int(s.get("territory_count", 0))
		f.stats.total_building_value = int(s.get("total_building_value", 0))
		f.stats.war_wins = int(s.get("war_wins", 0))
		f.stats.war_losses = int(s.get("war_losses", 0))
		f.stats.war_points_season = int(s.get("war_points_season", 0))
		f.stats.mini_games_won = int(s.get("mini_games_won", 0))
		f.stats.buildings_constructed = int(s.get("buildings_constructed", 0))
		f.stats.last_update_ts = int(s.get("last_update_ts", 0))

	if is_new:
		emit_signal("faction_created", fid, f.district_id)
	emit_signal("stats_updated", fid)


func _ingest_remote_chat(data: Dictionary) -> void:
	var fid: String = str(data.get("faction_id", ""))
	var f: Faction = _factions.get(fid, null)
	if f == null:
		return
	var entry: Dictionary = {
		"player_id": str(data.get("player_id", "")),
		"text": str(data.get("text", "")),
		"ts": int(data.get("ts", Time.get_unix_time_from_system())),
	}
	f.chat_history.append(entry)
	while f.chat_history.size() > CHAT_HISTORY_LIMIT:
		f.chat_history.pop_front()
	emit_signal("chat_message", fid, entry.player_id, entry.text, entry.ts)


func _ingest_remote_member_update(data: Dictionary) -> void:
	var fid: String = str(data.get("faction_id", ""))
	var pid: String = str(data.get("player_id", ""))
	var role: int = int(data.get("role", Role.MEMBER))
	var f: Faction = _factions.get(fid, null)
	if f == null or not f.is_member(pid):
		return
	(f.members[pid] as FactionMember).role = role
	emit_signal("member_role_changed", fid, pid, role)


# ---------------------------------------------------------------------------
# Debug / testing helpers
# ---------------------------------------------------------------------------
func debug_dump_state() -> Dictionary:
	var out: Dictionary = {
		"faction_count": _factions.size(),
		"districts": _district_to_factions.keys(),
		"factions": [],
	}
	for f in _factions.values():
		out["factions"].append(f.to_dict())
	return out


func debug_force_create(
	faction_id: String,
	name: String,
	district_id: String,
	members: Dictionary,
	color: Color = Color(1, 0.2, 0.7),
) -> void:
	# Test hook: bypass validation in unit tests.
	var f: Faction = Faction.new(faction_id, name, district_id)
	f.color = color
	for pid in members:
		var role: int = int(members[pid].get("role", Role.MEMBER))
		var m: FactionMember = FactionMember.new(pid, str(members[pid].get("display_name", pid)), role)
		f.members[pid] = m
		_player_to_faction[pid] = faction_id
	f.stats.member_count = f.members.size()
	_factions[faction_id] = f
	_name_index[name.to_lower()] = faction_id
	if not _district_to_factions.has(district_id):
		_district_to_factions[district_id] = []
	_district_to_factions[district_id].append(faction_id)
	emit_signal("faction_created", faction_id, district_id)
