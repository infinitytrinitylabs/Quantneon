## SeasonSystem.gd
## ----------------------------------------------------------------------------
## Governs the 30-day competitive season loop for the Faction Wars metagame.
##
## Per issue #14:
##   * A season lasts exactly 30 days of wall-clock time.
##   * At the end of every season:
##       - All territory ownership resets to neutral.
##       - The top factions (by war points) receive badges, exclusive
##         building skins and banner customisations.
##       - A permanent Hall-of-Fame entry is recorded.
##       - Season statistics held by FactionManager are cleared.
##   * The next season auto-starts after a short off-season break.
##
## This system is intended to run as an autoload singleton, but is also
## serialisable via `save_state()` / `load_state(state)` so that the host
## server can persist progress across process restarts.
## ----------------------------------------------------------------------------

extends Node

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
const SEASON_DURATION_SECONDS: int = 30 * 24 * 60 * 60
const OFFSEASON_DURATION_SECONDS: int = 12 * 60 * 60        # 12 hours break
const TICK_INTERVAL_SECONDS: float = 30.0
const TOP_N_BADGES: int = 10
const PODIUM_SIZE: int = 3
const MIN_POINTS_FOR_BADGE: int = 250
const GRACE_PERIOD_AFTER_CAPTURE: int = 60 * 60 * 24 * 3   # for reset animation

enum SeasonPhase {
	OFFSEASON = 0,
	ACTIVE = 1,
	ENDING = 2,
}

const BADGE_TIERS: Array = [
	{"rank": 1, "id": "season_champion", "name": "Season Champion", "skin": "gold_overlay"},
	{"rank": 2, "id": "season_silver",   "name": "Silver Syndicate", "skin": "silver_overlay"},
	{"rank": 3, "id": "season_bronze",   "name": "Bronze Contender", "skin": "bronze_overlay"},
	{"rank": 4, "id": "season_top5",     "name": "Top 5 Finisher",   "skin": "neon_outline"},
	{"rank": 5, "id": "season_top5",     "name": "Top 5 Finisher",   "skin": "neon_outline"},
	{"rank": 6, "id": "season_top10",    "name": "Top 10 Finisher",  "skin": "chrome_outline"},
	{"rank": 7, "id": "season_top10",    "name": "Top 10 Finisher",  "skin": "chrome_outline"},
	{"rank": 8, "id": "season_top10",    "name": "Top 10 Finisher",  "skin": "chrome_outline"},
	{"rank": 9, "id": "season_top10",    "name": "Top 10 Finisher",  "skin": "chrome_outline"},
	{"rank": 10,"id": "season_top10",    "name": "Top 10 Finisher",  "skin": "chrome_outline"},
]

const EXCLUSIVE_BUILDING_SKINS: Array = [
	"holo_glass_tower",
	"crystal_spire",
	"cyber_pagoda",
	"bio_luminous_arch",
	"mirror_monolith",
	"fractal_pyramid",
	"obsidian_keep",
	"aurora_dome",
]

const BANNER_PALETTES: Array = [
	{"id": "magenta_haze", "colors": ["#ff2bd6", "#1a0027", "#00eaff"]},
	{"id": "solar_flare",  "colors": ["#ffae00", "#ff1f3d", "#2b0a14"]},
	{"id": "glacier",      "colors": ["#8ff7ff", "#0d3b66", "#ffffff"]},
	{"id": "emerald_neon", "colors": ["#30ff9a", "#003d28", "#ccffe5"]},
	{"id": "midnight_ink", "colors": ["#6b2bff", "#110033", "#d7b8ff"]},
	{"id": "crimson_edge", "colors": ["#ff1f3d", "#1a0009", "#ff9aa8"]},
]


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal season_started(number: int)
signal season_ending_soon(number: int, seconds_remaining: int)
signal season_ended(number: int, winners: Array)
signal offseason_started(number: int, ends_at: int)
signal badge_awarded(faction_id: String, badge: Dictionary)
signal skin_unlocked(faction_id: String, skin_id: String)
signal banner_unlocked(faction_id: String, banner_id: String)
signal hall_of_fame_updated(entry: Dictionary)
signal phase_changed(new_phase: int)


# ---------------------------------------------------------------------------
# Internal classes
# ---------------------------------------------------------------------------
class SeasonRecord:
	var number: int = 0
	var phase: int = SeasonPhase.OFFSEASON
	var started_at: int = 0
	var ends_at: int = 0
	var offseason_ends_at: int = 0
	var standings: Array = []         # resolved at season end: [{faction_id,name,score,...}]
	var awarded_skins: Dictionary = {}  # faction_id -> Array[String]
	var awarded_badges: Dictionary = {} # faction_id -> Array[Dictionary]
	var awarded_banners: Dictionary = {} # faction_id -> Array[String]

	func seconds_remaining(now: int) -> int:
		if phase == SeasonPhase.ACTIVE:
			return max(0, ends_at - now)
		if phase == SeasonPhase.OFFSEASON:
			return max(0, offseason_ends_at - now)
		return 0

	func days_remaining(now: int) -> int:
		return int(ceil(seconds_remaining(now) / 86400.0))

	func to_dict() -> Dictionary:
		return {
			"number": number,
			"phase": phase,
			"started_at": started_at,
			"ends_at": ends_at,
			"offseason_ends_at": offseason_ends_at,
			"standings": standings.duplicate(true),
			"awarded_skins": awarded_skins.duplicate(true),
			"awarded_badges": awarded_badges.duplicate(true),
			"awarded_banners": awarded_banners.duplicate(true),
		}


class HallOfFameEntry:
	var season_number: int
	var started_at: int
	var ended_at: int
	var podium: Array = []            # [{faction_id,name,tag,score,district_id}]
	var notable_stats: Dictionary = {}
	var ts_recorded: int = 0

	func _init(p_season: int = 0) -> void:
		season_number = p_season
		ts_recorded = Time.get_unix_time_from_system()

	func to_dict() -> Dictionary:
		return {
			"season_number": season_number,
			"started_at": started_at,
			"ended_at": ended_at,
			"podium": podium.duplicate(true),
			"notable_stats": notable_stats.duplicate(true),
			"ts_recorded": ts_recorded,
		}


# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------
var _current: SeasonRecord = SeasonRecord.new()
var _hall_of_fame: Array = []        # [HallOfFameEntry]
var _tick_timer: Timer
var _warned_24h: bool = false
var _warned_1h: bool = false
var _faction_manager: Node = null
var _territory_war: Node = null
var _auto_rollover: bool = true


# ---------------------------------------------------------------------------
# Engine lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tick_timer = Timer.new()
	_tick_timer.wait_time = TICK_INTERVAL_SECONDS
	_tick_timer.autostart = true
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_on_tick)
	_faction_manager = _resolve_singleton("FactionManager")
	_territory_war = _resolve_singleton("TerritoryWar")
	if _current.phase == SeasonPhase.OFFSEASON and _current.number == 0:
		_current.number = 1
		_current.offseason_ends_at = Time.get_unix_time_from_system()
		_begin_active_season()
	print("[SeasonSystem] Service ready. Active season #%d" % _current.number)


func _resolve_singleton(node_name: String) -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root: Node = tree.root
	if root != null and root.has_node(node_name):
		return root.get_node(node_name)
	return null


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func get_current_season_number() -> int:
	return _current.number


func get_current_phase() -> int:
	return _current.phase


func describe_current_season() -> Dictionary:
	var now: int = Time.get_unix_time_from_system()
	var phase_name: String = ""
	match _current.phase:
		SeasonPhase.ACTIVE:
			phase_name = "active"
		SeasonPhase.OFFSEASON:
			phase_name = "offseason"
		SeasonPhase.ENDING:
			phase_name = "ending"
	return {
		"number": _current.number,
		"phase": phase_name,
		"phase_code": _current.phase,
		"seconds_remaining": _current.seconds_remaining(now),
		"days_remaining": _current.days_remaining(now),
		"started_at": _current.started_at,
		"ends_at": _current.ends_at,
		"offseason_ends_at": _current.offseason_ends_at,
	}


func force_end_season() -> void:
	# Admin hook for testing or emergency rollover.
	if _current.phase != SeasonPhase.ACTIVE:
		return
	_end_active_season()


func set_auto_rollover(enabled: bool) -> void:
	_auto_rollover = enabled


func get_hall_of_fame(limit: int = 20) -> Array:
	var out: Array = []
	var start: int = max(0, _hall_of_fame.size() - limit)
	for i in range(start, _hall_of_fame.size()):
		out.append((_hall_of_fame[i] as HallOfFameEntry).to_dict())
	return out


func get_hall_of_fame_entry(season_number: int) -> Dictionary:
	for e in _hall_of_fame:
		var h: HallOfFameEntry = e
		if h.season_number == season_number:
			return h.to_dict()
	return {}


func get_faction_rewards(faction_id: String) -> Dictionary:
	return {
		"skins": _current.awarded_skins.get(faction_id, []).duplicate(),
		"badges": _current.awarded_badges.get(faction_id, []).duplicate(),
		"banners": _current.awarded_banners.get(faction_id, []).duplicate(),
	}


# ---------------------------------------------------------------------------
# Tick loop
# ---------------------------------------------------------------------------
func _on_tick() -> void:
	var now: int = Time.get_unix_time_from_system()
	match _current.phase:
		SeasonPhase.ACTIVE:
			var remaining: int = max(0, _current.ends_at - now)
			if remaining <= 0:
				_end_active_season()
				return
			if remaining <= 3600 and not _warned_1h:
				_warned_1h = true
				emit_signal("season_ending_soon", _current.number, remaining)
			elif remaining <= 86400 and not _warned_24h:
				_warned_24h = true
				emit_signal("season_ending_soon", _current.number, remaining)
		SeasonPhase.OFFSEASON:
			if _auto_rollover and now >= _current.offseason_ends_at:
				_current.number += 1
				_begin_active_season()
		SeasonPhase.ENDING:
			# ENDING is transient — should never linger. Recover.
			_enter_offseason()
		_:
			pass


# ---------------------------------------------------------------------------
# Season transitions
# ---------------------------------------------------------------------------
func _begin_active_season() -> void:
	var now: int = Time.get_unix_time_from_system()
	_current.phase = SeasonPhase.ACTIVE
	_current.started_at = now
	_current.ends_at = now + SEASON_DURATION_SECONDS
	_current.offseason_ends_at = 0
	_current.standings.clear()
	_current.awarded_skins.clear()
	_current.awarded_badges.clear()
	_current.awarded_banners.clear()
	_warned_24h = false
	_warned_1h = false
	emit_signal("phase_changed", _current.phase)
	emit_signal("season_started", _current.number)


func _end_active_season() -> void:
	_current.phase = SeasonPhase.ENDING
	emit_signal("phase_changed", _current.phase)
	var standings: Array = _compute_standings()
	_current.standings = standings

	_distribute_rewards(standings)
	_record_hall_of_fame(standings)
	_reset_territory()
	_reset_faction_stats()

	emit_signal("season_ended", _current.number, standings)
	_enter_offseason()


func _enter_offseason() -> void:
	var now: int = Time.get_unix_time_from_system()
	_current.phase = SeasonPhase.OFFSEASON
	_current.offseason_ends_at = now + OFFSEASON_DURATION_SECONDS
	emit_signal("phase_changed", _current.phase)
	emit_signal("offseason_started", _current.number, _current.offseason_ends_at)


# ---------------------------------------------------------------------------
# Standings & rewards
# ---------------------------------------------------------------------------
func _compute_standings() -> Array:
	if _faction_manager == null or not _faction_manager.has_method("get_leaderboard"):
		return []
	var rows: Array = _faction_manager.get_leaderboard("war_points_season", 100)
	var enriched: Array = []
	for r in rows:
		var entry: Dictionary = {
			"faction_id": r.get("faction_id", ""),
			"name": r.get("name", ""),
			"tag": r.get("tag", ""),
			"district_id": r.get("district_id", ""),
			"score": int(r.get("score", 0)),
			"stats": r.get("stats", {}),
		}
		enriched.append(entry)
	return enriched


func _distribute_rewards(standings: Array) -> void:
	var rank: int = 0
	for row in standings:
		rank += 1
		if rank > TOP_N_BADGES:
			break
		var fid: String = String(row.get("faction_id", ""))
		if fid.is_empty():
			continue
		var score: int = int(row.get("score", 0))
		if score < MIN_POINTS_FOR_BADGE:
			continue
		_award_badge(fid, rank)
		if rank <= PODIUM_SIZE:
			_award_skin(fid, EXCLUSIVE_BUILDING_SKINS[rank - 1])
			_award_banner(fid, BANNER_PALETTES[rank - 1].id)
		elif rank <= 5:
			_award_skin(fid, EXCLUSIVE_BUILDING_SKINS[(rank - 1) % EXCLUSIVE_BUILDING_SKINS.size()])
		# Participation banner for top 10.
		if rank <= TOP_N_BADGES:
			var banner_idx: int = (rank - 1) % BANNER_PALETTES.size()
			_award_banner(fid, BANNER_PALETTES[banner_idx].id)


func _award_badge(faction_id: String, rank: int) -> void:
	var template: Dictionary = BADGE_TIERS[clamp(rank - 1, 0, BADGE_TIERS.size() - 1)]
	var badge: Dictionary = {
		"id": template.id,
		"name": template.name,
		"skin": template.skin,
		"rank": rank,
		"season_number": _current.number,
		"awarded_at": Time.get_unix_time_from_system(),
	}
	var list: Array = _current.awarded_badges.get(faction_id, [])
	list.append(badge)
	_current.awarded_badges[faction_id] = list
	emit_signal("badge_awarded", faction_id, badge)


func _award_skin(faction_id: String, skin_id: String) -> void:
	var list: Array = _current.awarded_skins.get(faction_id, [])
	if list.has(skin_id):
		return
	list.append(skin_id)
	_current.awarded_skins[faction_id] = list
	emit_signal("skin_unlocked", faction_id, skin_id)


func _award_banner(faction_id: String, banner_id: String) -> void:
	var list: Array = _current.awarded_banners.get(faction_id, [])
	if list.has(banner_id):
		return
	list.append(banner_id)
	_current.awarded_banners[faction_id] = list
	emit_signal("banner_unlocked", faction_id, banner_id)


# ---------------------------------------------------------------------------
# Cleanup at season end
# ---------------------------------------------------------------------------
func _reset_territory() -> void:
	if _territory_war == null or not _territory_war.has_method("get_all_territories"):
		return
	for t in _territory_war.get_all_territories():
		if t.owner_faction_id == "":
			continue
		if _territory_war.has_method("set_territory_owner"):
			_territory_war.set_territory_owner(t.id, "")


func _reset_faction_stats() -> void:
	if _faction_manager == null:
		return
	if _faction_manager.has_method("reset_season_stats"):
		_faction_manager.reset_season_stats()


func _record_hall_of_fame(standings: Array) -> void:
	var entry: HallOfFameEntry = HallOfFameEntry.new(_current.number)
	entry.started_at = _current.started_at
	entry.ended_at = Time.get_unix_time_from_system()
	var podium: Array = []
	var count: int = 0
	for row in standings:
		if count >= PODIUM_SIZE:
			break
		podium.append({
			"faction_id": row.get("faction_id", ""),
			"name": row.get("name", ""),
			"tag": row.get("tag", ""),
			"score": int(row.get("score", 0)),
			"district_id": row.get("district_id", ""),
		})
		count += 1
	entry.podium = podium
	entry.notable_stats = _collect_notable_stats(standings)
	_hall_of_fame.append(entry)
	emit_signal("hall_of_fame_updated", entry.to_dict())


func _collect_notable_stats(standings: Array) -> Dictionary:
	var most_wars: Dictionary = {"faction_id": "", "value": 0}
	var most_territory: Dictionary = {"faction_id": "", "value": 0}
	var most_minigames: Dictionary = {"faction_id": "", "value": 0}
	var total_points: int = 0
	for row in standings:
		var stats: Dictionary = row.get("stats", {})
		total_points += int(row.get("score", 0))
		var wars: int = int(stats.get("war_wins", 0))
		if wars > int(most_wars["value"]):
			most_wars = {"faction_id": row.get("faction_id", ""), "value": wars}
		var terr: int = int(stats.get("territory_count", 0))
		if terr > int(most_territory["value"]):
			most_territory = {"faction_id": row.get("faction_id", ""), "value": terr}
		var mg: int = int(stats.get("mini_games_won", 0))
		if mg > int(most_minigames["value"]):
			most_minigames = {"faction_id": row.get("faction_id", ""), "value": mg}
	return {
		"most_wars_won": most_wars,
		"most_territory_held": most_territory,
		"most_mini_game_wins": most_minigames,
		"total_war_points": total_points,
		"participating_factions": standings.size(),
	}


# ---------------------------------------------------------------------------
# Serialisation
# ---------------------------------------------------------------------------
func save_state() -> Dictionary:
	var hof: Array = []
	for h in _hall_of_fame:
		hof.append((h as HallOfFameEntry).to_dict())
	return {
		"current": _current.to_dict(),
		"hall_of_fame": hof,
		"warned_24h": _warned_24h,
		"warned_1h": _warned_1h,
		"auto_rollover": _auto_rollover,
	}


func load_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	var cur: Dictionary = state.get("current", {})
	if typeof(cur) == TYPE_DICTIONARY and not cur.is_empty():
		_current = SeasonRecord.new()
		_current.number = int(cur.get("number", 1))
		_current.phase = int(cur.get("phase", SeasonPhase.OFFSEASON))
		_current.started_at = int(cur.get("started_at", 0))
		_current.ends_at = int(cur.get("ends_at", 0))
		_current.offseason_ends_at = int(cur.get("offseason_ends_at", 0))
		_current.standings = (cur.get("standings", []) as Array).duplicate(true)
		_current.awarded_skins = (cur.get("awarded_skins", {}) as Dictionary).duplicate(true)
		_current.awarded_badges = (cur.get("awarded_badges", {}) as Dictionary).duplicate(true)
		_current.awarded_banners = (cur.get("awarded_banners", {}) as Dictionary).duplicate(true)
	_hall_of_fame.clear()
	for raw in state.get("hall_of_fame", []):
		var h: HallOfFameEntry = HallOfFameEntry.new(int(raw.get("season_number", 0)))
		h.started_at = int(raw.get("started_at", 0))
		h.ended_at = int(raw.get("ended_at", 0))
		h.podium = (raw.get("podium", []) as Array).duplicate(true)
		h.notable_stats = (raw.get("notable_stats", {}) as Dictionary).duplicate(true)
		h.ts_recorded = int(raw.get("ts_recorded", 0))
		_hall_of_fame.append(h)
	_warned_24h = bool(state.get("warned_24h", false))
	_warned_1h = bool(state.get("warned_1h", false))
	_auto_rollover = bool(state.get("auto_rollover", true))


# ---------------------------------------------------------------------------
# Debug / test helpers
# ---------------------------------------------------------------------------
func debug_set_remaining_seconds(seconds: int) -> void:
	if _current.phase != SeasonPhase.ACTIVE:
		return
	_current.ends_at = Time.get_unix_time_from_system() + max(0, seconds)


func debug_snapshot() -> Dictionary:
	return {
		"current": _current.to_dict(),
		"hall_of_fame_size": _hall_of_fame.size(),
	}


func debug_bootstrap_mock_season(badges_for: Array) -> void:
	# Manufacture a dummy standings set to exercise reward logic.
	var standings: Array = []
	var i: int = 0
	for fid in badges_for:
		i += 1
		standings.append({
			"faction_id": fid,
			"name": "Mock %s" % fid,
			"tag": "MCK",
			"district_id": "D0",
			"score": 1000 - i * 50,
			"stats": {
				"war_wins": 5 - i,
				"territory_count": 10 - i,
				"mini_games_won": 20 - i,
			},
		})
	_current.standings = standings
	_distribute_rewards(standings)
	_record_hall_of_fame(standings)
