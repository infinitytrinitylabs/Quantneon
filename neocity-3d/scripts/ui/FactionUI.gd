## FactionUI.gd
## ----------------------------------------------------------------------------
## Dashboard Control that visualises everything produced by the faction
## subsystems defined in issue #14.
##
## This UI is intentionally defensive: if FactionManager / TerritoryWar /
## SeasonSystem / MiniGameSystem are unavailable (e.g. during unit tests or
## while the player is offline) the UI renders a graceful empty state instead
## of crashing.
##
## The Control builds its own layout procedurally so it can be instantiated
## without an accompanying .tscn. It still supports binding to an existing
## scene via the `@export` NodePaths; any that are left empty are auto-built.
## ----------------------------------------------------------------------------

extends Control

# ---------------------------------------------------------------------------
# Exposed NodePaths — optional bindings for a designer-authored scene.
# ---------------------------------------------------------------------------
@export var member_list_path: NodePath
@export var territory_map_path: NodePath
@export var war_status_path: NodePath
@export var treasury_label_path: NodePath
@export var leaderboard_path: NodePath
@export var season_banner_path: NodePath
@export var chat_log_path: NodePath
@export var chat_input_path: NodePath
@export var tab_container_path: NodePath

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
const LEADERBOARD_LIMIT: int = 15
const MAP_CELL_SIZE: float = 44.0
const MAP_COLS: int = 8
const MAP_ROWS: int = 8
const REFRESH_INTERVAL: float = 1.0
const NEUTRAL_COLOR: Color = Color(0.18, 0.18, 0.22, 0.9)

# ---------------------------------------------------------------------------
# Internal refs
# ---------------------------------------------------------------------------
var _tab_container: TabContainer
var _member_list: VBoxContainer
var _territory_map: Control
var _war_status: VBoxContainer
var _treasury_label: Label
var _leaderboard: VBoxContainer
var _season_banner: Label
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _war_progress_bars: Dictionary = {}   # war_id -> Dictionary{progress:ProgressBar, label:Label, container:Control}
var _map_cells: Dictionary = {}           # zone_id -> ColorRect
var _leaderboard_rows: Array = []
var _member_rows: Dictionary = {}         # player_id -> HBoxContainer

var _faction_manager: Node = null
var _territory_war: Node = null
var _season_system: Node = null
var _mini_game_system: Node = null

var _active_faction_id: String = ""
var _local_player_id: String = ""

var _refresh_timer: Timer

var _signal_bindings: Array = []          # [{source, signal, callable}]


# ---------------------------------------------------------------------------
# Engine lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	_bind_or_build_layout()
	_resolve_services()
	_wire_signals()
	_connect_chat_input()
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL
	_refresh_timer.autostart = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_refresh_all)
	_refresh_all()


func _exit_tree() -> void:
	_disconnect_signals()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func set_local_player(player_id: String) -> void:
	_local_player_id = player_id
	_active_faction_id = _find_player_faction_id(player_id)
	_refresh_all()


func set_active_faction(faction_id: String) -> void:
	_active_faction_id = faction_id
	_refresh_all()


# ---------------------------------------------------------------------------
# Layout construction
# ---------------------------------------------------------------------------
func _bind_or_build_layout() -> void:
	_tab_container = _get_or_null(tab_container_path) as TabContainer
	if _tab_container == null:
		_tab_container = TabContainer.new()
		_tab_container.name = "FactionTabs"
		_tab_container.anchor_right = 1.0
		_tab_container.anchor_bottom = 1.0
		add_child(_tab_container)

	# Dashboard tab ---------------------------------------------------------
	var dashboard: MarginContainer = _make_margin("Dashboard")
	_tab_container.add_child(dashboard)

	var v: VBoxContainer = VBoxContainer.new()
	v.name = "DashboardContent"
	v.anchor_right = 1.0
	v.anchor_bottom = 1.0
	v.add_theme_constant_override("separation", 8)
	dashboard.add_child(v)

	_season_banner = _get_or_null(season_banner_path) as Label
	if _season_banner == null:
		_season_banner = Label.new()
		_season_banner.name = "SeasonBanner"
		_season_banner.add_theme_font_size_override("font_size", 18)
		v.add_child(_season_banner)

	var dash_row: HBoxContainer = HBoxContainer.new()
	dash_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(dash_row)

	var left_col: VBoxContainer = VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_row.add_child(left_col)

	_treasury_label = _get_or_null(treasury_label_path) as Label
	if _treasury_label == null:
		_treasury_label = Label.new()
		_treasury_label.name = "TreasuryLabel"
		left_col.add_child(_treasury_label)

	var member_box: Panel = Panel.new()
	member_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	member_box.custom_minimum_size = Vector2(260, 200)
	left_col.add_child(member_box)
	var member_scroll: ScrollContainer = ScrollContainer.new()
	member_scroll.anchor_right = 1.0
	member_scroll.anchor_bottom = 1.0
	member_box.add_child(member_scroll)
	_member_list = _get_or_null(member_list_path) as VBoxContainer
	if _member_list == null:
		_member_list = VBoxContainer.new()
		_member_list.name = "MemberList"
		_member_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		member_scroll.add_child(_member_list)
	else:
		# Reparent if provided externally.
		if _member_list.get_parent() != null:
			_member_list.get_parent().remove_child(_member_list)
		member_scroll.add_child(_member_list)

	var right_col: VBoxContainer = VBoxContainer.new()
	right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dash_row.add_child(right_col)

	# Territory map overlay.
	_territory_map = _get_or_null(territory_map_path)
	if _territory_map == null:
		_territory_map = Control.new()
		_territory_map.name = "TerritoryMap"
		_territory_map.custom_minimum_size = Vector2(
			MAP_COLS * MAP_CELL_SIZE + 16.0,
			MAP_ROWS * MAP_CELL_SIZE + 16.0,
		)
		right_col.add_child(_territory_map)
	_build_map_grid(_territory_map)

	# War status tab --------------------------------------------------------
	var war_tab: MarginContainer = _make_margin("Wars")
	_tab_container.add_child(war_tab)
	_war_status = _get_or_null(war_status_path) as VBoxContainer
	if _war_status == null:
		_war_status = VBoxContainer.new()
		_war_status.name = "WarStatus"
		_war_status.add_theme_constant_override("separation", 10)
		war_tab.add_child(_war_status)
	else:
		if _war_status.get_parent() != null:
			_war_status.get_parent().remove_child(_war_status)
		war_tab.add_child(_war_status)

	# Leaderboard tab -------------------------------------------------------
	var lb_tab: MarginContainer = _make_margin("Leaderboard")
	_tab_container.add_child(lb_tab)
	var lb_scroll: ScrollContainer = ScrollContainer.new()
	lb_scroll.anchor_right = 1.0
	lb_scroll.anchor_bottom = 1.0
	lb_tab.add_child(lb_scroll)
	_leaderboard = _get_or_null(leaderboard_path) as VBoxContainer
	if _leaderboard == null:
		_leaderboard = VBoxContainer.new()
		_leaderboard.name = "Leaderboard"
		lb_scroll.add_child(_leaderboard)
	else:
		if _leaderboard.get_parent() != null:
			_leaderboard.get_parent().remove_child(_leaderboard)
		lb_scroll.add_child(_leaderboard)

	# Chat tab --------------------------------------------------------------
	var chat_tab: MarginContainer = _make_margin("Chat")
	_tab_container.add_child(chat_tab)
	var chat_v: VBoxContainer = VBoxContainer.new()
	chat_v.anchor_right = 1.0
	chat_v.anchor_bottom = 1.0
	chat_tab.add_child(chat_v)
	_chat_log = _get_or_null(chat_log_path) as RichTextLabel
	if _chat_log == null:
		_chat_log = RichTextLabel.new()
		_chat_log.name = "ChatLog"
		_chat_log.scroll_following = true
		_chat_log.bbcode_enabled = true
		_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_chat_log.custom_minimum_size = Vector2(400, 240)
		chat_v.add_child(_chat_log)
	_chat_input = _get_or_null(chat_input_path) as LineEdit
	if _chat_input == null:
		_chat_input = LineEdit.new()
		_chat_input.name = "ChatInput"
		_chat_input.placeholder_text = "Message your faction..."
		chat_v.add_child(_chat_input)


func _make_margin(tab_name: String) -> MarginContainer:
	var mc: MarginContainer = MarginContainer.new()
	mc.name = tab_name
	mc.add_theme_constant_override("margin_top", 8)
	mc.add_theme_constant_override("margin_left", 8)
	mc.add_theme_constant_override("margin_right", 8)
	mc.add_theme_constant_override("margin_bottom", 8)
	mc.anchor_right = 1.0
	mc.anchor_bottom = 1.0
	return mc


func _build_map_grid(parent: Control) -> void:
	# Pre-populate an 8x8 grid; cells get reassigned to territories on refresh.
	for y in MAP_ROWS:
		for x in MAP_COLS:
			var cell: ColorRect = ColorRect.new()
			cell.color = NEUTRAL_COLOR
			cell.custom_minimum_size = Vector2(MAP_CELL_SIZE - 4.0, MAP_CELL_SIZE - 4.0)
			cell.position = Vector2(x * MAP_CELL_SIZE + 2.0, y * MAP_CELL_SIZE + 2.0)
			cell.size = cell.custom_minimum_size
			cell.tooltip_text = "Neutral"
			parent.add_child(cell)


func _get_or_null(path: NodePath) -> Node:
	if path == NodePath(""):
		return null
	if not has_node(path):
		return null
	return get_node(path)


# ---------------------------------------------------------------------------
# Service resolution & signal wiring
# ---------------------------------------------------------------------------
func _resolve_services() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var root: Node = tree.root
	if root == null:
		return
	if root.has_node("FactionManager"):
		_faction_manager = root.get_node("FactionManager")
	if root.has_node("TerritoryWar"):
		_territory_war = root.get_node("TerritoryWar")
	if root.has_node("SeasonSystem"):
		_season_system = root.get_node("SeasonSystem")
	if root.has_node("MiniGameSystem"):
		_mini_game_system = root.get_node("MiniGameSystem")


func _wire_signals() -> void:
	_bind(_faction_manager, "faction_created", Callable(self, "_on_faction_created"))
	_bind(_faction_manager, "faction_disbanded", Callable(self, "_on_faction_disbanded"))
	_bind(_faction_manager, "member_joined", Callable(self, "_on_member_joined"))
	_bind(_faction_manager, "member_left", Callable(self, "_on_member_left"))
	_bind(_faction_manager, "member_role_changed", Callable(self, "_on_member_role_changed"))
	_bind(_faction_manager, "treasury_changed", Callable(self, "_on_treasury_changed"))
	_bind(_faction_manager, "chat_message", Callable(self, "_on_chat_message"))
	_bind(_faction_manager, "stats_updated", Callable(self, "_on_stats_updated"))

	_bind(_territory_war, "war_declared", Callable(self, "_on_war_declared"))
	_bind(_territory_war, "war_tick", Callable(self, "_on_war_tick"))
	_bind(_territory_war, "war_ended", Callable(self, "_on_war_ended"))
	_bind(_territory_war, "territory_captured", Callable(self, "_on_territory_captured"))
	_bind(_territory_war, "ceasefire_started", Callable(self, "_on_ceasefire_started"))

	_bind(_season_system, "season_started", Callable(self, "_on_season_started"))
	_bind(_season_system, "season_ended", Callable(self, "_on_season_ended"))


func _bind(source: Object, signal_name: String, callable: Callable) -> void:
	if source == null:
		return
	if not source.has_signal(signal_name):
		return
	if source.is_connected(signal_name, callable):
		return
	source.connect(signal_name, callable)
	_signal_bindings.append({"source": source, "signal": signal_name, "callable": callable})


func _disconnect_signals() -> void:
	for b in _signal_bindings:
		var source: Object = b["source"]
		if source == null or not is_instance_valid(source):
			continue
		if source.is_connected(b["signal"], b["callable"]):
			source.disconnect(b["signal"], b["callable"])
	_signal_bindings.clear()


func _connect_chat_input() -> void:
	if _chat_input == null:
		return
	if not _chat_input.text_submitted.is_connected(_on_chat_submitted):
		_chat_input.text_submitted.connect(_on_chat_submitted)


# ---------------------------------------------------------------------------
# Refresh pipeline
# ---------------------------------------------------------------------------
func _refresh_all() -> void:
	_refresh_season_banner()
	_refresh_faction_summary()
	_refresh_member_list()
	_refresh_territory_map()
	_refresh_war_status()
	_refresh_leaderboard()


func _refresh_season_banner() -> void:
	if _season_banner == null:
		return
	if _season_system != null and _season_system.has_method("describe_current_season"):
		var info: Dictionary = _season_system.describe_current_season()
		var days_left: int = int(info.get("days_remaining", 0))
		_season_banner.text = "Season %d · %s · %d day%s remaining" % [
			int(info.get("number", 0)),
			String(info.get("phase", "offseason")).capitalize(),
			days_left,
			"s" if days_left != 1 else "",
		]
	else:
		_season_banner.text = "Season data unavailable"


func _refresh_faction_summary() -> void:
	if _treasury_label == null:
		return
	var f = _get_active_faction()
	if f == null:
		_treasury_label.text = "No faction selected"
		return
	_treasury_label.text = "%s [%s] — Treasury: %d Q · Territories: %d · Members: %d/%s" % [
		f.name,
		f.tag,
		f.treasury,
		f.stats.territory_count,
		f.stats.member_count,
		"∞",
	]


func _refresh_member_list() -> void:
	if _member_list == null:
		return
	var f = _get_active_faction()
	# Clear stale rows.
	for child in _member_list.get_children():
		child.queue_free()
	_member_rows.clear()
	if f == null:
		return
	var sorted: Array = f.members.values()
	sorted.sort_custom(func(a, b): return a.role > b.role or (a.role == b.role and a.display_name < b.display_name))
	for m in sorted:
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var role_label: Label = Label.new()
		role_label.text = _role_to_string(m.role)
		role_label.custom_minimum_size = Vector2(80, 0)
		row.add_child(role_label)
		var name_label: Label = Label.new()
		name_label.text = m.display_name
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var contrib: Label = Label.new()
		contrib.text = "%d pts" % m.contribution_points
		row.add_child(contrib)
		_member_list.add_child(row)
		_member_rows[m.player_id] = row


func _refresh_territory_map() -> void:
	if _territory_map == null:
		return
	for cell in _map_cells.values():
		if is_instance_valid(cell):
			cell.color = NEUTRAL_COLOR
			cell.tooltip_text = "Neutral"
	_map_cells.clear()
	if _territory_war == null or not _territory_war.has_method("get_all_territories"):
		return
	var territories: Array = _territory_war.get_all_territories()
	var cells: Array = _territory_map.get_children()
	var i: int = 0
	for t in territories:
		if i >= cells.size():
			break
		var cell: ColorRect = cells[i]
		var owner_id: String = str(t.owner_faction_id)
		var col: Color = NEUTRAL_COLOR
		var owner_name: String = "Neutral"
		if not owner_id.is_empty():
			var f = _get_faction_by_id(owner_id)
			if f != null:
				col = f.color
				owner_name = f.name
		cell.color = col
		cell.tooltip_text = "%s — %s" % [t.display_name, owner_name]
		_map_cells[t.id] = cell
		i += 1


func _refresh_war_status() -> void:
	if _war_status == null:
		return
	for child in _war_status.get_children():
		child.queue_free()
	_war_progress_bars.clear()
	if _territory_war == null or not _territory_war.has_method("get_all_active_wars"):
		var none: Label = Label.new()
		none.text = "No wars are active."
		_war_status.add_child(none)
		return
	var wars: Array = _territory_war.get_all_active_wars()
	if wars.is_empty():
		var none: Label = Label.new()
		none.text = "No wars are active."
		_war_status.add_child(none)
		return
	for w in wars:
		_war_status.add_child(_build_war_panel(w))


func _build_war_panel(w) -> Control:
	var panel: PanelContainer = PanelContainer.new()
	var vb: VBoxContainer = VBoxContainer.new()
	panel.add_child(vb)

	var attacker = _get_faction_by_id(w.attacker_id)
	var defender = _get_faction_by_id(w.defender_id)
	var header: Label = Label.new()
	header.text = "%s  vs  %s · Zone: %s" % [
		_faction_display(attacker, w.attacker_id),
		_faction_display(defender, w.defender_id),
		_zone_name(w.zone_id),
	]
	vb.add_child(header)

	var now: int = Time.get_unix_time_from_system()
	var remaining: int = w.seconds_remaining(now) if w.has_method("seconds_remaining") else max(0, w.ends_at - now)
	var time_label: Label = Label.new()
	time_label.text = "Time remaining: %s" % _format_duration(remaining)
	vb.add_child(time_label)

	var a_score: int = w.attacker_ledger.score() if w.attacker_ledger != null else 0
	var d_score: int = w.defender_ledger.score() if w.defender_ledger != null else 0
	var total: int = max(1, a_score + d_score)
	var bar: ProgressBar = ProgressBar.new()
	bar.min_value = 0
	bar.max_value = total
	bar.value = a_score
	bar.custom_minimum_size = Vector2(320, 18)
	vb.add_child(bar)

	var score_label: Label = Label.new()
	score_label.text = "Attacker: %d · Defender: %d" % [a_score, d_score]
	vb.add_child(score_label)

	_war_progress_bars[w.id] = {
		"progress": bar,
		"label": score_label,
		"time_label": time_label,
		"container": panel,
	}
	return panel


func _refresh_leaderboard() -> void:
	if _leaderboard == null:
		return
	for child in _leaderboard.get_children():
		child.queue_free()
	_leaderboard_rows.clear()
	if _faction_manager == null or not _faction_manager.has_method("get_leaderboard"):
		var none: Label = Label.new()
		none.text = "Leaderboard unavailable."
		_leaderboard.add_child(none)
		return
	var rows: Array = _faction_manager.get_leaderboard("war_points_season", LEADERBOARD_LIMIT)
	var rank: int = 1
	for row in rows:
		var line: HBoxContainer = HBoxContainer.new()
		line.add_theme_constant_override("separation", 10)
		var rank_label: Label = Label.new()
		rank_label.text = "#%d" % rank
		rank_label.custom_minimum_size = Vector2(36, 0)
		line.add_child(rank_label)
		var swatch: ColorRect = ColorRect.new()
		swatch.color = row.get("color", NEUTRAL_COLOR)
		swatch.custom_minimum_size = Vector2(18, 18)
		line.add_child(swatch)
		var name_label: Label = Label.new()
		name_label.text = "%s [%s]" % [row.get("name", "?"), row.get("tag", "")]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(name_label)
		var district_label: Label = Label.new()
		district_label.text = row.get("district_id", "-")
		district_label.custom_minimum_size = Vector2(100, 0)
		line.add_child(district_label)
		var score_label: Label = Label.new()
		score_label.text = "%d pts" % int(row.get("score", 0))
		line.add_child(score_label)
		_leaderboard.add_child(line)
		_leaderboard_rows.append(line)
		rank += 1


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------
func _on_faction_created(_faction_id: String, _district_id: String) -> void:
	_refresh_all()


func _on_faction_disbanded(_faction_id: String, _district_id: String) -> void:
	_refresh_all()


func _on_member_joined(faction_id: String, _player_id: String, _role: int) -> void:
	if faction_id == _active_faction_id:
		_refresh_member_list()


func _on_member_left(faction_id: String, _player_id: String) -> void:
	if faction_id == _active_faction_id:
		_refresh_member_list()


func _on_member_role_changed(faction_id: String, _player_id: String, _role: int) -> void:
	if faction_id == _active_faction_id:
		_refresh_member_list()


func _on_treasury_changed(faction_id: String, _balance: int) -> void:
	if faction_id == _active_faction_id:
		_refresh_faction_summary()


func _on_stats_updated(_faction_id: String) -> void:
	_refresh_faction_summary()
	_refresh_leaderboard()


func _on_chat_message(faction_id: String, player_id: String, text: String, ts: int) -> void:
	if faction_id != _active_faction_id:
		return
	if _chat_log == null:
		return
	var time_str: String = Time.get_time_string_from_unix_time(ts)
	var display: String = _lookup_member_name(faction_id, player_id)
	_chat_log.append_text("[b][%s] %s:[/b] %s\n" % [time_str, display, text])


func _on_chat_submitted(text: String) -> void:
	if text.strip_edges().is_empty():
		return
	if _chat_input != null:
		_chat_input.text = ""
	if _faction_manager == null or _active_faction_id.is_empty() or _local_player_id.is_empty():
		return
	if _faction_manager.has_method("send_chat"):
		_faction_manager.send_chat(_active_faction_id, _local_player_id, text)


func _on_war_declared(_war_id: String, _attacker_id: String, _defender_id: String, _zone_id: String) -> void:
	_refresh_war_status()
	_refresh_territory_map()


func _on_war_tick(war_id: String, attacker_score: int, defender_score: int, seconds_remaining: int) -> void:
	var entry: Dictionary = _war_progress_bars.get(war_id, {})
	if entry.is_empty():
		return
	var bar: ProgressBar = entry.get("progress", null)
	var label: Label = entry.get("label", null)
	var time_label: Label = entry.get("time_label", null)
	var total: int = max(1, attacker_score + defender_score)
	if bar != null:
		bar.max_value = total
		bar.value = attacker_score
	if label != null:
		label.text = "Attacker: %d · Defender: %d" % [attacker_score, defender_score]
	if time_label != null:
		time_label.text = "Time remaining: %s" % _format_duration(seconds_remaining)


func _on_war_ended(_war_id: String, _winner_id: String, _loser_id: String, _zone_id: String) -> void:
	_refresh_war_status()
	_refresh_territory_map()
	_refresh_faction_summary()


func _on_territory_captured(_zone_id: String, _new_owner: String, _previous_owner: String) -> void:
	_refresh_territory_map()


func _on_ceasefire_started(_a: String, _b: String, _zone_id: String, _expires_at: int) -> void:
	_refresh_war_status()


func _on_season_started(_number: int) -> void:
	_refresh_season_banner()


func _on_season_ended(_number: int, _winners: Array) -> void:
	_refresh_season_banner()
	_refresh_leaderboard()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _get_active_faction():
	if _faction_manager == null:
		return null
	if _active_faction_id.is_empty():
		return null
	if not _faction_manager.has_method("get_faction"):
		return null
	return _faction_manager.get_faction(_active_faction_id)


func _get_faction_by_id(faction_id: String):
	if _faction_manager == null or faction_id.is_empty():
		return null
	if _faction_manager.has_method("get_faction"):
		return _faction_manager.get_faction(faction_id)
	return null


func _find_player_faction_id(player_id: String) -> String:
	if _faction_manager == null or not _faction_manager.has_method("get_faction_for_player"):
		return ""
	var f = _faction_manager.get_faction_for_player(player_id)
	if f == null:
		return ""
	return f.id


func _lookup_member_name(faction_id: String, player_id: String) -> String:
	var f = _get_faction_by_id(faction_id)
	if f == null or not f.is_member(player_id):
		return player_id
	return (f.members[player_id] as Object).display_name


func _faction_display(f, fallback: String) -> String:
	if f == null:
		return fallback
	return "%s [%s]" % [f.name, f.tag]


func _zone_name(zone_id: String) -> String:
	if _territory_war == null or not _territory_war.has_method("get_territory"):
		return zone_id
	var t = _territory_war.get_territory(zone_id)
	if t == null:
		return zone_id
	return t.display_name


func _role_to_string(role: int) -> String:
	match role:
		3: return "Leader"
		2: return "Officer"
		1: return "Member"
		_: return "—"


func _format_duration(seconds: int) -> String:
	if seconds <= 0:
		return "00:00"
	var h: int = int(seconds / 3600)
	var m: int = int((seconds % 3600) / 60)
	var s: int = seconds % 60
	if h > 0:
		return "%02d:%02d:%02d" % [h, m, s]
	return "%02d:%02d" % [m, s]
