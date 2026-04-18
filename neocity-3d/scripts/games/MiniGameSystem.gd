## MiniGameSystem.gd
## ----------------------------------------------------------------------------
## Coordinates the three war-time mini-games (Race / Build / Defend) used to
## earn war points during an active TerritoryWar.
##
## Rules (from issue #14):
##   * Three modes:
##       - RACE:   drive through checkpoints fastest
##       - BUILD:  construct the target structure fastest
##       - DEFEND: survive enemy waves the longest
##   * Each mini-game awards 100-500 war points, scaled by performance.
##   * Mini-games are only playable while a war is active in the zone where
##     the match is staged.
## ----------------------------------------------------------------------------

extends Node

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
enum GameMode {
	RACE = 0,
	BUILD = 1,
	DEFEND = 2,
}

enum MatchState {
	LOBBY = 0,
	COUNTDOWN = 1,
	RUNNING = 2,
	COMPLETED = 3,
	ABORTED = 4,
}

enum JoinResult {
	OK,
	MATCH_NOT_FOUND,
	MATCH_FULL,
	ALREADY_IN_MATCH,
	NOT_IN_FACTION,
	WRONG_FACTION,
}

const MIN_POINTS: int = 100
const MAX_POINTS: int = 500
const COUNTDOWN_SECONDS: int = 10
const DEFAULT_MATCH_DURATION_SECONDS: int = 300    # fallback cap
const RACE_DEFAULT_DURATION: int = 240
const BUILD_DEFAULT_DURATION: int = 360
const DEFEND_DEFAULT_DURATION: int = 600
const MAX_PARTICIPANTS_PER_MATCH: int = 16
const MIN_PARTICIPANTS_TO_START: int = 2
const RACE_CHECKPOINT_POINTS: int = 25
const BUILD_STEP_POINTS: int = 40
const DEFEND_WAVE_POINTS: int = 60

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal match_created(match_id: String, mode: int, zone_id: String)
signal match_started(match_id: String)
signal match_tick(match_id: String, payload: Dictionary)
signal match_completed(match_id: String, winning_faction_id: String, points_awarded: int)
signal match_aborted(match_id: String, reason: String)
signal player_joined(match_id: String, player_id: String, faction_id: String)
signal player_left(match_id: String, player_id: String)
signal checkpoint_reached(match_id: String, player_id: String, checkpoint_index: int)
signal build_step_completed(match_id: String, player_id: String, step: int)
signal wave_survived(match_id: String, wave_index: int, faction_id: String)


# ---------------------------------------------------------------------------
# Internal classes
# ---------------------------------------------------------------------------
class Participant:
	var player_id: String
	var display_name: String
	var faction_id: String
	var joined_at: int
	var score: int = 0
	var checkpoints_hit: int = 0
	var build_steps_done: int = 0
	var damage_dealt: int = 0
	var is_alive: bool = true
	var finish_position: int = -1        # RACE: 1-based; -1 until finished
	var finish_time_ms: int = -1

	func _init(pid: String = "", pname: String = "", fid: String = "") -> void:
		player_id = pid
		display_name = pname
		faction_id = fid
		joined_at = Time.get_unix_time_from_system()

	func to_dict() -> Dictionary:
		return {
			"player_id": player_id,
			"display_name": display_name,
			"faction_id": faction_id,
			"score": score,
			"checkpoints_hit": checkpoints_hit,
			"build_steps_done": build_steps_done,
			"damage_dealt": damage_dealt,
			"finish_position": finish_position,
			"finish_time_ms": finish_time_ms,
			"is_alive": is_alive,
		}


class MatchRecord:
	var id: String
	var mode: int
	var zone_id: String
	var war_id: String                       # optional, if tied to a war
	var state: int = MatchState.LOBBY
	var created_at: int = 0
	var started_at: int = 0
	var deadline_ts: int = 0
	var duration_seconds: int = DEFAULT_MATCH_DURATION_SECONDS
	var participants: Dictionary = {}        # player_id -> Participant
	var faction_scores: Dictionary = {}      # faction_id -> int
	var checkpoint_count: int = 0            # RACE
	var build_total_steps: int = 0           # BUILD
	var build_faction_progress: Dictionary = {}   # faction_id -> int (steps)
	var defend_current_wave: int = 0         # DEFEND
	var winner_faction_id: String = ""
	var awarded_points: int = 0
	var config: Dictionary = {}
	var log: Array = []

	func _init(p_id: String = "", p_mode: int = GameMode.RACE, p_zone: String = "") -> void:
		id = p_id
		mode = p_mode
		zone_id = p_zone
		created_at = Time.get_unix_time_from_system()

	func get_participant(player_id: String) -> Participant:
		return participants.get(player_id, null)

	func add_faction_score(fid: String, delta: int) -> void:
		faction_scores[fid] = int(faction_scores.get(fid, 0)) + delta

	func to_dict(now: int) -> Dictionary:
		var people: Array = []
		for p in participants.values():
			people.append((p as Participant).to_dict())
		return {
			"id": id,
			"mode": mode,
			"zone_id": zone_id,
			"war_id": war_id,
			"state": state,
			"started_at": started_at,
			"deadline_ts": deadline_ts,
			"seconds_remaining": max(0, deadline_ts - now),
			"participants": people,
			"faction_scores": faction_scores.duplicate(),
			"winner_faction_id": winner_faction_id,
			"awarded_points": awarded_points,
			"defend_current_wave": defend_current_wave,
			"build_faction_progress": build_faction_progress.duplicate(),
		}


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var _matches: Dictionary = {}            # match_id -> MatchRecord
var _player_to_match: Dictionary = {}    # player_id -> match_id
var _next_match_index: int = 1
var _tick_timer: Timer
var _territory_war: Node = null
var _faction_manager: Node = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tick_timer = Timer.new()
	_tick_timer.wait_time = 1.0
	_tick_timer.autostart = true
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_on_tick)
	_territory_war = _resolve_singleton("TerritoryWar")
	_faction_manager = _resolve_singleton("FactionManager")
	print("[MiniGameSystem] Ready.")


func _resolve_singleton(node_name: String) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Node = tree.root
	if root != null and root.has_node(node_name):
		return root.get_node(node_name)
	return null


# ---------------------------------------------------------------------------
# Creation / joining
# ---------------------------------------------------------------------------
func create_match(mode: int, zone_id: String, config: Dictionary = {}) -> Dictionary:
	# Mini-games can only be played in zones with an active war.
	if not _zone_has_active_war(zone_id):
		return _res("NO_ACTIVE_WAR", "Mini-games require an active war in the zone.")

	var m: MatchRecord = MatchRecord.new(_generate_match_id(), mode, zone_id)
	m.config = config.duplicate(true)
	m.war_id = _get_zone_war_id(zone_id)

	match mode:
		GameMode.RACE:
			m.duration_seconds = int(config.get("duration", RACE_DEFAULT_DURATION))
			m.checkpoint_count = max(3, int(config.get("checkpoints", 8)))
		GameMode.BUILD:
			m.duration_seconds = int(config.get("duration", BUILD_DEFAULT_DURATION))
			m.build_total_steps = max(3, int(config.get("steps", 10)))
		GameMode.DEFEND:
			m.duration_seconds = int(config.get("duration", DEFEND_DEFAULT_DURATION))
		_:
			return _res("INVALID_MODE", "Unknown mini-game mode.")

	m.duration_seconds = clamp(m.duration_seconds, 60, DEFEND_DEFAULT_DURATION * 2)
	_matches[m.id] = m
	m.log.append(_evt("created", {"mode": mode, "zone_id": zone_id}))
	emit_signal("match_created", m.id, mode, zone_id)
	return {"code": "OK", "match_id": m.id}


func join_match(match_id: String, player_id: String, display_name: String, faction_id: String) -> int:
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		return JoinResult.MATCH_NOT_FOUND
	if _player_to_match.has(player_id):
		return JoinResult.ALREADY_IN_MATCH
	if m.participants.size() >= MAX_PARTICIPANTS_PER_MATCH:
		return JoinResult.MATCH_FULL
	if faction_id.is_empty():
		return JoinResult.NOT_IN_FACTION
	if m.state not in [MatchState.LOBBY, MatchState.COUNTDOWN]:
		return JoinResult.MATCH_FULL

	# Ensure participants come from factions actively at war in this zone.
	if _territory_war != null and m.war_id != "":
		var war = _territory_war.get_war(m.war_id) if _territory_war.has_method("get_war") else null
		if war != null and faction_id != war.attacker_id and faction_id != war.defender_id:
			return JoinResult.WRONG_FACTION

	var p: Participant = Participant.new(player_id, display_name, faction_id)
	m.participants[player_id] = p
	_player_to_match[player_id] = match_id
	m.log.append(_evt("joined", {"player_id": player_id, "faction_id": faction_id}))
	emit_signal("player_joined", match_id, player_id, faction_id)
	_maybe_start_countdown(m)
	return JoinResult.OK


func leave_match(player_id: String) -> bool:
	var match_id: String = _player_to_match.get(player_id, "")
	if match_id.is_empty():
		return false
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		_player_to_match.erase(player_id)
		return false
	m.participants.erase(player_id)
	_player_to_match.erase(player_id)
	m.log.append(_evt("left", {"player_id": player_id}))
	emit_signal("player_left", match_id, player_id)
	if m.state == MatchState.RUNNING and m.participants.is_empty():
		_abort_match(m, "no_participants")
	return true


func start_match_now(match_id: String) -> bool:
	# Manual start hook — normally the countdown triggers this automatically.
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		return false
	if m.state != MatchState.LOBBY and m.state != MatchState.COUNTDOWN:
		return false
	if m.participants.size() < MIN_PARTICIPANTS_TO_START:
		return false
	_begin_running(m)
	return true


# ---------------------------------------------------------------------------
# RACE API
# ---------------------------------------------------------------------------
func race_checkpoint(match_id: String, player_id: String, checkpoint_index: int) -> bool:
	var m: MatchRecord = _require_running(match_id, GameMode.RACE)
	if m == null:
		return false
	var p: Participant = m.get_participant(player_id)
	if p == null:
		return false
	if checkpoint_index < 0 or checkpoint_index >= m.checkpoint_count:
		return false
	if checkpoint_index != p.checkpoints_hit:
		# Must hit checkpoints in order.
		return false
	p.checkpoints_hit += 1
	p.score += RACE_CHECKPOINT_POINTS
	m.add_faction_score(p.faction_id, RACE_CHECKPOINT_POINTS)
	emit_signal("checkpoint_reached", match_id, player_id, checkpoint_index)
	if p.checkpoints_hit >= m.checkpoint_count:
		# Player has finished — award a position bonus.
		var finished: int = 0
		for q in m.participants.values():
			if (q as Participant).finish_position > 0:
				finished += 1
		p.finish_position = finished + 1
		p.finish_time_ms = int((Time.get_unix_time_from_system() - m.started_at) * 1000)
		var bonus: int = max(0, (MAX_PARTICIPANTS_PER_MATCH - p.finish_position)) * 15
		p.score += bonus
		m.add_faction_score(p.faction_id, bonus)
		# Finish the match as soon as someone completes it and the rest have
		# had the duration to react — or immediately if everyone has finished.
		if _all_racers_finished(m):
			_complete_match(m)
	return true


func _all_racers_finished(m: MatchRecord) -> bool:
	for p in m.participants.values():
		if (p as Participant).finish_position <= 0:
			return false
	return true


# ---------------------------------------------------------------------------
# BUILD API
# ---------------------------------------------------------------------------
func build_step(match_id: String, player_id: String) -> bool:
	var m: MatchRecord = _require_running(match_id, GameMode.BUILD)
	if m == null:
		return false
	var p: Participant = m.get_participant(player_id)
	if p == null:
		return false
	p.build_steps_done += 1
	p.score += BUILD_STEP_POINTS
	m.add_faction_score(p.faction_id, BUILD_STEP_POINTS)
	var faction_total: int = int(m.build_faction_progress.get(p.faction_id, 0)) + 1
	m.build_faction_progress[p.faction_id] = faction_total
	emit_signal("build_step_completed", match_id, player_id, faction_total)
	if faction_total >= m.build_total_steps:
		_complete_match(m)
	return true


# ---------------------------------------------------------------------------
# DEFEND API
# ---------------------------------------------------------------------------
func defend_wave_cleared(match_id: String, faction_id: String) -> bool:
	var m: MatchRecord = _require_running(match_id, GameMode.DEFEND)
	if m == null:
		return false
	m.defend_current_wave += 1
	m.add_faction_score(faction_id, DEFEND_WAVE_POINTS)
	emit_signal("wave_survived", match_id, m.defend_current_wave, faction_id)
	return true


func defend_damage(match_id: String, player_id: String, amount: int) -> void:
	var m: MatchRecord = _require_running(match_id, GameMode.DEFEND)
	if m == null:
		return
	var p: Participant = m.get_participant(player_id)
	if p == null:
		return
	p.damage_dealt += max(0, amount)
	# Every 100 damage = 1 point, capped to avoid snowballing.
	var bonus: int = min(30, int(floor(amount / 100.0)))
	if bonus > 0:
		p.score += bonus
		m.add_faction_score(p.faction_id, bonus)


func defend_player_down(match_id: String, player_id: String) -> void:
	var m: MatchRecord = _require_running(match_id, GameMode.DEFEND)
	if m == null:
		return
	var p: Participant = m.get_participant(player_id)
	if p != null:
		p.is_alive = false
	if _all_defenders_dead(m):
		_complete_match(m)


func _all_defenders_dead(m: MatchRecord) -> bool:
	for p in m.participants.values():
		if (p as Participant).is_alive:
			return false
	return true


# ---------------------------------------------------------------------------
# Tick / lifecycle
# ---------------------------------------------------------------------------
func _on_tick() -> void:
	var now: int = Time.get_unix_time_from_system()
	var expiring: Array = []
	for m in _matches.values():
		var rec: MatchRecord = m
		match rec.state:
			MatchState.COUNTDOWN:
				if now >= rec.deadline_ts:
					_begin_running(rec)
			MatchState.RUNNING:
				emit_signal("match_tick", rec.id, rec.to_dict(now))
				if now >= rec.deadline_ts:
					_complete_match(rec)
			MatchState.COMPLETED, MatchState.ABORTED:
				if now - rec.started_at > 60 * 30: # keep 30 min for UI
					expiring.append(rec.id)
			_:
				pass
	for id in expiring:
		_matches.erase(id)


func _maybe_start_countdown(m: MatchRecord) -> void:
	if m.state != MatchState.LOBBY:
		return
	if m.participants.size() < MIN_PARTICIPANTS_TO_START:
		return
	m.state = MatchState.COUNTDOWN
	m.deadline_ts = Time.get_unix_time_from_system() + COUNTDOWN_SECONDS
	m.log.append(_evt("countdown_started", {}))


func _begin_running(m: MatchRecord) -> void:
	m.state = MatchState.RUNNING
	m.started_at = Time.get_unix_time_from_system()
	m.deadline_ts = m.started_at + m.duration_seconds
	m.log.append(_evt("running", {}))
	emit_signal("match_started", m.id)


func _complete_match(m: MatchRecord) -> void:
	if m.state != MatchState.RUNNING:
		return
	m.state = MatchState.COMPLETED
	m.winner_faction_id = _decide_winner(m)
	m.awarded_points = _compute_award(m)
	m.log.append(_evt("completed", {
		"winner_faction_id": m.winner_faction_id,
		"awarded_points": m.awarded_points,
	}))
	_distribute_rewards(m)
	# Detach players.
	for pid in m.participants.keys():
		_player_to_match.erase(pid)
	emit_signal("match_completed", m.id, m.winner_faction_id, m.awarded_points)


func _abort_match(m: MatchRecord, reason: String) -> void:
	m.state = MatchState.ABORTED
	m.log.append(_evt("aborted", {"reason": reason}))
	for pid in m.participants.keys():
		_player_to_match.erase(pid)
	emit_signal("match_aborted", m.id, reason)


# ---------------------------------------------------------------------------
# Scoring / rewards
# ---------------------------------------------------------------------------
func _decide_winner(m: MatchRecord) -> String:
	var best_id: String = ""
	var best_score: int = -1
	for fid in m.faction_scores.keys():
		var s: int = int(m.faction_scores[fid])
		if s > best_score:
			best_score = s
			best_id = fid
		elif s == best_score and best_id != "":
			# Tie-breaker: prefer the faction with the most participants still alive.
			var alive_best: int = _count_alive(m, best_id)
			var alive_new: int = _count_alive(m, fid)
			if alive_new > alive_best:
				best_id = fid
	return best_id


func _count_alive(m: MatchRecord, faction_id: String) -> int:
	var c: int = 0
	for p in m.participants.values():
		var pa: Participant = p
		if pa.faction_id == faction_id and pa.is_alive:
			c += 1
	return c


func _compute_award(m: MatchRecord) -> int:
	# Map the winning faction's score onto the [MIN_POINTS, MAX_POINTS] range.
	if m.winner_faction_id.is_empty():
		return 0
	var max_score: int = 0
	for fid in m.faction_scores.keys():
		max_score = max(max_score, int(m.faction_scores[fid]))
	if max_score <= 0:
		return MIN_POINTS
	var winner_score: int = int(m.faction_scores[m.winner_faction_id])
	var ratio: float = float(winner_score) / float(max_score)
	# Mini bonus based on mode & completion level.
	var completion: float = _completion_factor(m)
	var normalised: float = clamp(ratio * completion, 0.2, 1.0)
	var awarded: int = int(round(lerp(float(MIN_POINTS), float(MAX_POINTS), normalised)))
	return clamp(awarded, MIN_POINTS, MAX_POINTS)


func _completion_factor(m: MatchRecord) -> float:
	match m.mode:
		GameMode.RACE:
			var finished: int = 0
			for p in m.participants.values():
				if (p as Participant).finish_position > 0:
					finished += 1
			if m.participants.is_empty():
				return 0.5
			return clamp(float(finished) / float(m.participants.size()), 0.3, 1.0)
		GameMode.BUILD:
			if m.build_total_steps <= 0:
				return 0.5
			var best_progress: int = 0
			for fid in m.build_faction_progress.keys():
				best_progress = max(best_progress, int(m.build_faction_progress[fid]))
			return clamp(float(best_progress) / float(m.build_total_steps), 0.3, 1.0)
		GameMode.DEFEND:
			# Deeper waves = larger payout.
			return clamp(0.3 + 0.1 * float(m.defend_current_wave), 0.3, 1.0)
	return 0.5


func _distribute_rewards(m: MatchRecord) -> void:
	if m.winner_faction_id.is_empty() or m.awarded_points <= 0:
		return
	if _territory_war != null and _territory_war.has_method("register_mini_game_victory"):
		_territory_war.register_mini_game_victory(
			m.winner_faction_id,
			m.zone_id,
			max(1, int(round(m.awarded_points / 100.0))),
		)
	if _faction_manager != null:
		if _faction_manager.has_method("award_war_points"):
			_faction_manager.award_war_points(m.winner_faction_id, m.awarded_points)
		if _faction_manager.has_method("register_mini_game_win"):
			_faction_manager.register_mini_game_win(m.winner_faction_id)


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------
func get_match(match_id: String) -> MatchRecord:
	return _matches.get(match_id, null)


func get_match_for_player(player_id: String) -> MatchRecord:
	var mid: String = _player_to_match.get(player_id, "")
	if mid.is_empty():
		return null
	return _matches.get(mid, null)


func list_active_matches() -> Array:
	var out: Array = []
	for m in _matches.values():
		if (m as MatchRecord).state in [MatchState.LOBBY, MatchState.COUNTDOWN, MatchState.RUNNING]:
			out.append(m)
	return out


func list_matches_in_zone(zone_id: String) -> Array:
	var out: Array = []
	for m in _matches.values():
		if (m as MatchRecord).zone_id == zone_id:
			out.append(m)
	return out


func get_leaderboard(match_id: String) -> Array:
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		return []
	var rows: Array = []
	for p in m.participants.values():
		rows.append((p as Participant).to_dict())
	rows.sort_custom(func(a, b): return a.score > b.score)
	return rows


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _require_running(match_id: String, expected_mode: int) -> MatchRecord:
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		return null
	if m.mode != expected_mode:
		push_warning("[MiniGameSystem] Mode mismatch for match %s" % match_id)
		return null
	if m.state != MatchState.RUNNING:
		return null
	return m


func _zone_has_active_war(zone_id: String) -> bool:
	if _territory_war == null:
		return true # offline fallback — allow testing without a war
	if _territory_war.has_method("get_active_war_in_zone"):
		var w = _territory_war.get_active_war_in_zone(zone_id)
		return w != null
	return false


func _get_zone_war_id(zone_id: String) -> String:
	if _territory_war == null or not _territory_war.has_method("get_active_war_in_zone"):
		return ""
	var w = _territory_war.get_active_war_in_zone(zone_id)
	if w == null:
		return ""
	return w.id


func _generate_match_id() -> String:
	var idx: int = _next_match_index
	_next_match_index += 1
	return "MG-%06d" % idx


func _evt(type: String, payload: Dictionary) -> Dictionary:
	return {"type": type, "ts": Time.get_unix_time_from_system(), "payload": payload}


func _res(code: String, message: String) -> Dictionary:
	return {"code": code, "message": message}


# ---------------------------------------------------------------------------
# Debug helpers
# ---------------------------------------------------------------------------
func debug_state() -> Dictionary:
	var now: int = Time.get_unix_time_from_system()
	var matches_out: Array = []
	for m in _matches.values():
		matches_out.append((m as MatchRecord).to_dict(now))
	return {"matches": matches_out}


func debug_force_complete(match_id: String, winner_faction_id: String) -> void:
	var m: MatchRecord = _matches.get(match_id, null)
	if m == null:
		return
	if m.state != MatchState.RUNNING:
		_begin_running(m)
	m.add_faction_score(winner_faction_id, 9999)
	_complete_match(m)
