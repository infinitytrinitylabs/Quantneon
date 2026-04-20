## ResidencyDashboard.gd
## -----------------------------------------------------------------------------
## Residency HUD exposing digital ownership progression, social prestige,
## and clear next-tier advancement paths.
## -----------------------------------------------------------------------------

extends Control
class_name ResidencyDashboard
const DAILY_GOAL_DAY_KEY: String = "_day"

@export var resident_id: String = ""
@export var residency_service_path: NodePath = NodePath("/root/VirtualResidency")
@export var prestige_service_path: NodePath = NodePath("/root/PrestigeSystem")
@export var refresh_interval_seconds: float = 1.5

var _residency: Node = null
var _prestige: Node = null

var _title_label: Label
var _tier_label: Label
var _points_label: Label
var _days_label: Label
var _next_path_label: RichTextLabel
var _investment_total_label: Label
var _status_marker_label: Label
var _checkin_streak_label: Label
var _goal_list: VBoxContainer
var _limited_items_list: VBoxContainer
var _refresh_timer: Timer

func _ready() -> void:
	anchor_right = 1.0
	anchor_bottom = 1.0
	_bind_services()
	_build_layout()
	_wire_signals()
	_setup_timer()
	_refresh_dashboard()

func _exit_tree() -> void:
	if _refresh_timer != null and _refresh_timer.timeout.is_connected(_refresh_dashboard):
		_refresh_timer.timeout.disconnect(_refresh_dashboard)
	_disconnect_signal_safe(_residency, "profile_updated", _on_residency_profile_updated)
	_disconnect_signal_safe(_residency, "residency_tier_upgraded", _on_tier_upgraded)
	_disconnect_signal_safe(_prestige, "prestige_updated", _on_prestige_updated)
	_disconnect_signal_safe(_prestige, "cooperative_goal_progress", _on_goal_progress)

func set_resident(user_id: String) -> void:
	resident_id = user_id
	_refresh_dashboard()

func _bind_services() -> void:
	_residency = get_node_or_null(residency_service_path)
	_prestige = get_node_or_null(prestige_service_path)
	if resident_id.is_empty():
		resident_id = _resolve_fallback_resident_id()
	if _residency and _residency.has_method("ensure_resident") and not resident_id.is_empty():
		_residency.ensure_resident(resident_id)
	if _prestige and _prestige.has_method("ensure_resident") and not resident_id.is_empty():
		_prestige.ensure_resident(resident_id)

func _build_layout() -> void:
	var root_margin: MarginContainer = MarginContainer.new()
	root_margin.anchor_right = 1.0
	root_margin.anchor_bottom = 1.0
	root_margin.add_theme_constant_override("margin_left", 10)
	root_margin.add_theme_constant_override("margin_right", 10)
	root_margin.add_theme_constant_override("margin_top", 10)
	root_margin.add_theme_constant_override("margin_bottom", 10)
	add_child(root_margin)

	var root_v: VBoxContainer = VBoxContainer.new()
	root_v.anchor_right = 1.0
	root_v.anchor_bottom = 1.0
	root_v.add_theme_constant_override("separation", 8)
	root_margin.add_child(root_v)

	_title_label = Label.new()
	_title_label.text = "Residency Dashboard"
	_title_label.add_theme_font_size_override("font_size", 22)
	root_v.add_child(_title_label)

	var summary_panel: PanelContainer = PanelContainer.new()
	root_v.add_child(summary_panel)
	var summary_v: VBoxContainer = VBoxContainer.new()
	summary_v.add_theme_constant_override("separation", 6)
	summary_panel.add_child(summary_v)

	_tier_label = Label.new()
	summary_v.add_child(_tier_label)
	_points_label = Label.new()
	summary_v.add_child(_points_label)
	_days_label = Label.new()
	summary_v.add_child(_days_label)
	_investment_total_label = Label.new()
	summary_v.add_child(_investment_total_label)

	var path_panel: PanelContainer = PanelContainer.new()
	root_v.add_child(path_panel)
	_next_path_label = RichTextLabel.new()
	_next_path_label.bbcode_enabled = true
	_next_path_label.fit_content = true
	_next_path_label.scroll_active = false
	path_panel.add_child(_next_path_label)

	var social_panel: PanelContainer = PanelContainer.new()
	root_v.add_child(social_panel)
	var social_v: VBoxContainer = VBoxContainer.new()
	social_v.add_theme_constant_override("separation", 6)
	social_panel.add_child(social_v)

	_status_marker_label = Label.new()
	social_v.add_child(_status_marker_label)
	_checkin_streak_label = Label.new()
	social_v.add_child(_checkin_streak_label)

	var split_row: HBoxContainer = HBoxContainer.new()
	split_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split_row.add_theme_constant_override("separation", 8)
	root_v.add_child(split_row)

	var goals_panel: PanelContainer = PanelContainer.new()
	goals_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_row.add_child(goals_panel)
	var goals_v: VBoxContainer = VBoxContainer.new()
	goals_panel.add_child(goals_v)
	var goals_title: Label = Label.new()
	goals_title.text = "Cooperative Goals"
	goals_v.add_child(goals_title)
	var goals_scroll: ScrollContainer = ScrollContainer.new()
	goals_scroll.custom_minimum_size = Vector2(320, 220)
	goals_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	goals_v.add_child(goals_scroll)
	_goal_list = VBoxContainer.new()
	_goal_list.add_theme_constant_override("separation", 4)
	goals_scroll.add_child(_goal_list)

	var items_panel: PanelContainer = PanelContainer.new()
	items_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_row.add_child(items_panel)
	var items_v: VBoxContainer = VBoxContainer.new()
	items_panel.add_child(items_v)
	var items_title: Label = Label.new()
	items_title.text = "Time-Limited Inventory"
	items_v.add_child(items_title)
	var items_scroll: ScrollContainer = ScrollContainer.new()
	items_scroll.custom_minimum_size = Vector2(320, 220)
	items_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	items_v.add_child(items_scroll)
	_limited_items_list = VBoxContainer.new()
	_limited_items_list.add_theme_constant_override("separation", 4)
	items_scroll.add_child(_limited_items_list)

func _wire_signals() -> void:
	if _residency != null:
		_connect_signal_safe(_residency, "profile_updated", _on_residency_profile_updated)
		_connect_signal_safe(_residency, "residency_tier_upgraded", _on_tier_upgraded)
	if _prestige != null:
		_connect_signal_safe(_prestige, "prestige_updated", _on_prestige_updated)
		_connect_signal_safe(_prestige, "cooperative_goal_progress", _on_goal_progress)

func _setup_timer() -> void:
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = max(0.35, refresh_interval_seconds)
	_refresh_timer.autostart = true
	add_child(_refresh_timer)
	_refresh_timer.timeout.connect(_refresh_dashboard)

func _refresh_dashboard() -> void:
	if resident_id.is_empty():
		resident_id = _resolve_fallback_resident_id()
	if resident_id.is_empty():
		_render_empty_state("No resident selected.")
		return

	if _residency == null or _prestige == null:
		_bind_services()
	if _residency == null or _prestige == null:
		_render_empty_state("Residency services unavailable.")
		return

	var residency_profile: Dictionary = {}
	if _residency.has_method("get_profile"):
		residency_profile = _residency.get_profile(resident_id)
	if residency_profile.is_empty():
		if _residency.has_method("ensure_resident"):
			_residency.ensure_resident(resident_id)
		if _residency.has_method("get_profile"):
			residency_profile = _residency.get_profile(resident_id)

	var prestige_profile: Dictionary = {}
	if _prestige.has_method("get_profile"):
		prestige_profile = _prestige.get_profile(resident_id)
	if prestige_profile.is_empty():
		if _prestige.has_method("ensure_resident"):
			_prestige.ensure_resident(resident_id)
		if _prestige.has_method("get_profile"):
			prestige_profile = _prestige.get_profile(resident_id)

	_render_summary(residency_profile, prestige_profile)
	_render_next_tier_path()
	_render_goals()
	_render_limited_inventory(prestige_profile)

func _render_summary(residency_profile: Dictionary, prestige_profile: Dictionary) -> void:
	var tier_name: String = str(residency_profile.get("tier_name", "Starter Pod"))
	var neighborhood: String = str(residency_profile.get("neighborhood", "Neon Courtyard"))
	var points: int = int(residency_profile.get("progress", {}).get("points", 0))
	var days_active: int = int(residency_profile.get("continuity", {}).get("days_active", 0))
	var investment: int = int(residency_profile.get("home", {}).get("total_investment_points", 0))
	var marker_title: String = str(prestige_profile.get("active_marker_title", "Resident"))
	var checkin_streak: int = int(prestige_profile.get("checkin_streak", 0))
	var prestige_points: int = int(prestige_profile.get("prestige_points", 0))

	_tier_label.text = "Tier: %s | Neighborhood: %s" % [tier_name, neighborhood]
	_points_label.text = "Residency Points: %d" % points
	_days_label.text = "Sustained Participation Days: %d" % days_active
	_investment_total_label.text = "Home Investment Score: %d" % investment
	_status_marker_label.text = "Social Marker: %s (%d prestige points)" % [marker_title, prestige_points]
	_checkin_streak_label.text = "Daily Check-In Streak: %d" % checkin_streak

func _render_next_tier_path() -> void:
	if _residency == null or not _residency.has_method("get_next_tier_path"):
		_next_path_label.text = ""
		return
	var path: Dictionary = _residency.get_next_tier_path(resident_id)
	if bool(path.get("reached_cap", false)):
		_next_path_label.text = "[b]You reached the highest residency tier.[/b]"
		return
	var next_name: String = str(path.get("next_tier_name", ""))
	var points_remaining: int = int(path.get("points_remaining", 0))
	var days_remaining: int = int(path.get("days_remaining", 0))
	var unlocks: Array = path.get("unlock_preview", [])
	var unlock_text: String = ", ".join(unlocks)
	_next_path_label.text = (
		"[b]Path to %s[/b]\n" % next_name
		+ "• Points Needed: %d\n" % points_remaining
		+ "• Participation Days Needed: %d\n" % days_remaining
		+ "• Upcoming Unlocks: %s" % unlock_text
	)

func _render_goals() -> void:
	for child in _goal_list.get_children():
		child.queue_free()
	if _prestige == null or not _prestige.has_method("get_active_goals"):
		_goal_list.add_child(_make_small_label("No goal data available."))
		return
	var goals: Array = _prestige.get_active_goals()
	if goals.is_empty():
		_goal_list.add_child(_make_small_label("No active cooperative goals."))
		return
	for goal in goals:
		if str(goal.get("id", "")) == DAILY_GOAL_DAY_KEY:
			continue
		var label: Label = Label.new()
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = "%s\nProgress: %d/%d%s" % [
			str(goal.get("label", "Goal")),
			int(goal.get("progress", 0)),
			int(goal.get("target", 0)),
			" ✅" if bool(goal.get("completed", false)) else "",
		]
		_goal_list.add_child(label)

func _render_limited_inventory(prestige_profile: Dictionary) -> void:
	for child in _limited_items_list.get_children():
		child.queue_free()
	var inventory: Array = prestige_profile.get("limited_inventory", [])
	if inventory.is_empty():
		_limited_items_list.add_child(_make_small_label("No limited items acquired yet."))
		return
	var now_unix: int = int(Time.get_unix_time_from_system())
	for item in inventory:
		var expires_unix: int = int(item.get("expires_unix", 0))
		var remaining_hours: int = max(0, int((expires_unix - now_unix) / 3600))
		var row: Label = Label.new()
		row.text = "%s (%s) • %dh remaining" % [
			str(item.get("name", item.get("id", "Item"))),
			str(item.get("rarity", "common")),
			remaining_hours,
		]
		_limited_items_list.add_child(row)

func _render_empty_state(reason: String) -> void:
	_tier_label.text = "Tier: -"
	_points_label.text = "Residency Points: -"
	_days_label.text = "Sustained Participation Days: -"
	_investment_total_label.text = "Home Investment Score: -"
	_status_marker_label.text = "Social Marker: -"
	_checkin_streak_label.text = "Daily Check-In Streak: -"
	_next_path_label.text = "[b]Dashboard unavailable[/b]\n%s" % reason
	for child in _goal_list.get_children():
		child.queue_free()
	_goal_list.add_child(_make_small_label(reason))
	for child in _limited_items_list.get_children():
		child.queue_free()
	_limited_items_list.add_child(_make_small_label(reason))

func _on_residency_profile_updated(user_id: String, _profile: Dictionary) -> void:
	if user_id == resident_id:
		_refresh_dashboard()

func _on_tier_upgraded(user_id: String, _previous_tier: String, _new_tier: String) -> void:
	if user_id == resident_id:
		_refresh_dashboard()

func _on_prestige_updated(user_id: String, _profile: Dictionary) -> void:
	if user_id == resident_id:
		_refresh_dashboard()

func _on_goal_progress(_goal_id: String, _current: int, _target: int) -> void:
	_refresh_dashboard()

func _resolve_fallback_resident_id() -> String:
	var network_manager: Node = get_node_or_null("/root/NetworkManager")
	if network_manager and network_manager.has_method("get_local_player_id"):
		return str(network_manager.get_local_player_id())
	var ownership: Node = get_node_or_null("/root/LandOwnershipService")
	if ownership != null and ownership.get("local_player_id") != null:
		return str(ownership.get("local_player_id"))
	return ""

func _make_small_label(text: String) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

func _connect_signal_safe(source: Object, signal_name: StringName, callable: Callable) -> void:
	if source == null:
		return
	if not source.has_signal(signal_name):
		return
	if not source.is_connected(signal_name, callable):
		source.connect(signal_name, callable)

func _disconnect_signal_safe(source: Object, signal_name: StringName, callable: Callable) -> void:
	if source == null:
		return
	if not source.has_signal(signal_name):
		return
	if source.is_connected(signal_name, callable):
		source.disconnect(signal_name, callable)
