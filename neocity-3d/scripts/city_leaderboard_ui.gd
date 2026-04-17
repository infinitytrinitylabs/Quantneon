## CityLeaderboardUI — Top Landowners weekly leaderboard panel.
##
## Shows:
##   • Ranked list of top landowners: rank, player name, block count,
##     weekly rent income, gold-glow count.
##   • Auto-refreshes every LEADERBOARD_POLL_INTERVAL seconds (driven by
##     LandOwnershipService which requests the data from the server).
##   • Highlights the local player's row.
##   • Toggle with "Tab" key or via the Land panel's leaderboard button.

extends CanvasLayer

# ── Node references ────────────────────────────────────────────────────────────

@onready var close_btn: Button        = $MainPanel/Header/CloseButton
@onready var title_lbl: Label         = $MainPanel/Header/TitleLabel
@onready var last_updated_lbl: Label  = $MainPanel/Header/UpdatedLabel
@onready var entry_list: VBoxContainer = $MainPanel/ScrollArea/EntryList
@onready var refresh_btn: Button      = $MainPanel/Footer/RefreshButton
@onready var local_rank_lbl: Label    = $MainPanel/Footer/LocalRankLabel

# ── State ──────────────────────────────────────────────────────────────────────

var _last_refresh_unix: int = 0

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()
	close_btn.pressed.connect(_close)
	refresh_btn.pressed.connect(_on_refresh_pressed)

	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		los.leaderboard_updated.connect(_on_leaderboard_updated)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("leaderboard_panel"):
		if visible:
			_close()
		else:
			open_panel()

# ── Open / Close ──────────────────────────────────────────────────────────────

func open_panel() -> void:
	show()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_populate_leaderboard()
	_request_refresh()

func _close() -> void:
	hide()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# ── Populate ──────────────────────────────────────────────────────────────────

func _populate_leaderboard() -> void:
	_clear_list()

	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	if los.leaderboard.is_empty():
		var lbl: Label = Label.new()
		lbl.text = "Leaderboard is loading…"
		lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		entry_list.add_child(lbl)
		return

	var local_rank: int = -1
	for entry in los.leaderboard:
		var row: Control = _make_entry_row(entry, los.local_player_id)
		entry_list.add_child(row)
		if str(entry.get("player_id", "")) == los.local_player_id:
			local_rank = int(entry.get("rank", -1))

	# Update footer.
	if local_rank > 0:
		local_rank_lbl.text = "Your Rank: #%d" % local_rank
		local_rank_lbl.add_theme_color_override("font_color",
				Color(1.0, 0.85, 0.0))
	else:
		local_rank_lbl.text = "You're not on the leaderboard yet."
		local_rank_lbl.add_theme_color_override("font_color",
				Color(0.6, 0.6, 0.6))

	if _last_refresh_unix > 0:
		var dt: String = Time.get_datetime_string_from_unix_time(_last_refresh_unix)
		last_updated_lbl.text = "Updated: %s" % dt
	else:
		last_updated_lbl.text = ""

func _make_entry_row(entry: Dictionary,
		local_player_id: String) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 5)
	card.add_child(margin)

	var hbox: HBoxContainer = HBoxContainer.new()
	margin.add_child(hbox)

	var rank: int          = int(entry.get("rank", 0))
	var pid: String        = str(entry.get("player_id", ""))
	var pname: String      = entry.get("player_name", "Unknown")
	var blocks: int        = int(entry.get("block_count", 0))
	var income: int        = int(entry.get("weekly_rent_income", 0))
	var gold_count: int    = int(entry.get("gold_glow_count", 0))
	var is_local: bool     = pid == local_player_id

	# Rank badge.
	var rank_lbl: Label = Label.new()
	rank_lbl.custom_minimum_size = Vector2(40, 0)
	rank_lbl.text = _rank_badge(rank)
	rank_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	rank_lbl.add_theme_font_size_override("font_size", 16)
	hbox.add_child(rank_lbl)

	# Player info.
	var info_col: VBoxContainer = VBoxContainer.new()
	info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_col)

	var name_lbl: Label = Label.new()
	var gold_tag: String = " ✨×%d" % gold_count if gold_count > 0 else ""
	name_lbl.text = pname + gold_tag
	if is_local:
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	else:
		match rank:
			1: name_lbl.add_theme_color_override("font_color", Color(1.0, 0.84, 0.0))
			2: name_lbl.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
			3: name_lbl.add_theme_color_override("font_color", Color(0.8, 0.5, 0.2))
			_: name_lbl.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	name_lbl.add_theme_font_size_override("font_size", 14)
	info_col.add_child(name_lbl)

	var stats_lbl: Label = Label.new()
	stats_lbl.text = "Blocks: %d  |  Weekly: %d QT" % [blocks, income]
	stats_lbl.add_theme_color_override("font_color", Color(0.6, 0.9, 0.6))
	stats_lbl.add_theme_font_size_override("font_size", 12)
	info_col.add_child(stats_lbl)

	if is_local:
		var you_tag: Label = Label.new()
		you_tag.text = "← YOU"
		you_tag.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
		you_tag.add_theme_font_size_override("font_size", 12)
		hbox.add_child(you_tag)

	return card

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_leaderboard_updated(_entries: Array) -> void:
	_last_refresh_unix = int(Time.get_unix_time_from_system())
	if visible:
		_populate_leaderboard()

# ── Button callbacks ──────────────────────────────────────────────────────────

func _on_refresh_pressed() -> void:
	_request_refresh()

func _request_refresh() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los and los.has_method("request_leaderboard"):
		los.request_leaderboard()

# ── Helpers ───────────────────────────────────────────────────────────────────

func _clear_list() -> void:
	for child in entry_list.get_children():
		child.queue_free()

func _rank_badge(rank: int) -> String:
	match rank:
		1: return "🥇"
		2: return "🥈"
		3: return "🥉"
		_: return "#%d" % rank
