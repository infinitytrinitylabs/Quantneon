## LandOwnershipUI — Panel for claiming and managing virtual city blocks.
##
## Shows:
##   • A grid/list of nearby city blocks with owner, price, streak, decay info.
##   • Claim / Release / List-for-sale actions for the local player.
##   • Event-zone FOMO countdown banners.
##   • Neighborhood drama toast notifications.
##   • Decoration streak status and gold-glow milestone progress.
##
## The panel is shown by pressing the "L" key or by interacting with a
## Land Terminal object in the 3D world.

extends CanvasLayer

# ── Node references ────────────────────────────────────────────────────────────

@onready var bg_dim: ColorRect        = $BgDim
@onready var main_panel: Panel        = $MainPanel
@onready var close_btn: Button        = $MainPanel/Header/CloseButton
@onready var title_lbl: Label         = $MainPanel/Header/TitleLabel
@onready var balance_lbl: Label       = $MainPanel/Header/BalanceLabel
@onready var tab_bar: HBoxContainer   = $MainPanel/TabBar
@onready var tab_blocks: Button       = $MainPanel/TabBar/TabBlocks
@onready var tab_owned: Button        = $MainPanel/TabBar/TabOwned
@onready var tab_events: Button       = $MainPanel/TabBar/TabEvents
@onready var content_area: ScrollContainer = $MainPanel/ContentArea
@onready var block_list: VBoxContainer = $MainPanel/ContentArea/BlockList
@onready var drama_toast: PanelContainer   = $DramaToast
@onready var drama_label: Label            = $DramaToast/Label
@onready var event_banner: PanelContainer  = $EventBanner
@onready var event_title: Label            = $EventBanner/VBox/EventTitle
@onready var event_timer: Label            = $EventBanner/VBox/EventTimer
@onready var event_reward: Label           = $EventBanner/VBox/EventReward

# ── State ──────────────────────────────────────────────────────────────────────

var _current_tab: String = "blocks"   # "blocks" | "owned" | "events"
var _drama_queue: Array  = []
var _drama_show_timer: float = 0.0
const DRAMA_DISPLAY_SECS: float = 5.0

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()

	close_btn.pressed.connect(_close)
	tab_blocks.pressed.connect(func(): _switch_tab("blocks"))
	tab_owned.pressed.connect(func(): _switch_tab("owned"))
	tab_events.pressed.connect(func(): _switch_tab("events"))

	# Connect to service signals.
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		los.blocks_updated.connect(_on_blocks_updated)
		los.claim_result.connect(_on_claim_result)
		los.release_result.connect(_on_release_result)
		los.owned_blocks_changed.connect(_on_owned_changed)
		los.neighborhood_drama.connect(_on_neighborhood_drama)
		los.event_zones_updated.connect(_on_event_zones_updated)
		los.event_zone_entered.connect(_on_event_zone_entered)
		los.decoration_streak_updated.connect(_on_streak_updated)

	drama_toast.visible = false
	event_banner.visible = false

func _process(delta: float) -> void:
	# Toggle panel with "L" key.
	if Input.is_action_just_pressed("land_panel"):
		if visible:
			_close()
		else:
			open_panel()

	# Drama toast countdown.
	if drama_toast.visible:
		_drama_show_timer -= delta
		if _drama_show_timer <= 0.0:
			drama_toast.visible = false
			if _drama_queue.size() > 0:
				_show_drama_toast(_drama_queue.pop_front())

	# Event banner countdown tick.
	_update_event_banner_timer()

# ── Open / Close ──────────────────────────────────────────────────────────────

func open_panel() -> void:
	show()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_switch_tab(_current_tab)
	_refresh_balance()

func _close() -> void:
	hide()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# ── Tab switching ─────────────────────────────────────────────────────────────

func _switch_tab(tab: String) -> void:
	_current_tab = tab
	_clear_list()
	match tab:
		"blocks":  _populate_all_blocks()
		"owned":   _populate_owned_blocks()
		"events":  _populate_event_zones()

func _clear_list() -> void:
	for child in block_list.get_children():
		child.queue_free()

# ── Populate: All Blocks ──────────────────────────────────────────────────────

func _populate_all_blocks() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	var sorted_blocks: Array = los.blocks.values()
	sorted_blocks.sort_custom(func(a, b):
		if a.get("district_id", "") != b.get("district_id", ""):
			return a.get("district_id", "") < b.get("district_id", "")
		return int(a.get("grid_x", 0)) < int(b.get("grid_x", 0))
	)

	for block in sorted_blocks:
		block_list.add_child(_make_block_card(block, los))

func _make_block_card(block: Dictionary, los: Node) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 6)
	card.add_child(margin)

	var hbox: HBoxContainer = HBoxContainer.new()
	margin.add_child(hbox)

	# Info column.
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	var bid: String        = block.get("id", "?")
	var owner: String      = block.get("owner_name", "")
	var dist: String       = block.get("district_id", "unknown")
	var streak: int        = int(block.get("decoration_streak", 0))
	var gold: bool         = bool(block.get("has_gold_glow", false))
	var stage: int         = int(block.get("decay_stage", 0))

	var name_lbl: Label = Label.new()
	name_lbl.text = "Block %s  [%s]" % [bid, dist.to_upper()]
	if gold:
		name_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	else:
		name_lbl.add_theme_color_override("font_color", Color(0.0, 1.0, 1.0))
	name_lbl.add_theme_font_size_override("font_size", 14)
	vbox.add_child(name_lbl)

	var status_lbl: Label = Label.new()
	if owner == "":
		status_lbl.text = "Unclaimed  |  Cost: %d QT" % los.get_claim_cost(bid)
		status_lbl.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	elif los.is_owner(bid):
		var streak_str: String = "Streak: %d day%s" \
				% [streak, "s" if streak != 1 else ""]
		if gold:
			streak_str += " ✨ GOLD GLOW"
		var decay_str: String = _decay_label(stage)
		status_lbl.text = "YOURS  |  %s  |  %s" % [streak_str, decay_str]
		status_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.0))
	else:
		status_lbl.text = "Owner: %s  |  Decay: %s" \
				% [owner, _decay_label(stage)]
		status_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	status_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(status_lbl)

	# Action buttons column.
	var btn_vbox: VBoxContainer = VBoxContainer.new()
	hbox.add_child(btn_vbox)

	if owner == "":
		var claim_btn: Button = Button.new()
		claim_btn.text = "CLAIM"
		claim_btn.pressed.connect(func(): _on_claim_pressed(bid))
		btn_vbox.add_child(claim_btn)
	elif los.is_owner(bid):
		var release_btn: Button = Button.new()
		release_btn.text = "RELEASE"
		release_btn.pressed.connect(func(): _on_release_pressed(bid))
		btn_vbox.add_child(release_btn)

		var decorate_btn: Button = Button.new()
		decorate_btn.text = "DECORATE +"
		decorate_btn.pressed.connect(func(): _on_decorate_pressed(bid))
		btn_vbox.add_child(decorate_btn)

	return card

# ── Populate: Owned Blocks ────────────────────────────────────────────────────

func _populate_owned_blocks() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	var owned: Array = los.get_owned_blocks()
	if owned.is_empty():
		var lbl: Label = Label.new()
		lbl.text = "You don't own any blocks yet.\nHead to the market and claim one!"
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		block_list.add_child(lbl)
		return

	for block in owned:
		block_list.add_child(_make_owned_block_card(block))

func _make_owned_block_card(block: Dictionary) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	margin.add_child(vbox)

	var bid: String   = block.get("id", "?")
	var dist: String  = block.get("district_id", "unknown")
	var streak: int   = int(block.get("decoration_streak", 0))
	var gold: bool    = bool(block.get("has_gold_glow", false))
	var stage: int    = int(block.get("decay_stage", 0))
	var income: int   = int(block.get("weekly_income", 0))
	var tenants: int  = int(block.get("active_tenants", 0))
	var slots: int    = int(block.get("rent_slots", 0))

	var header: Label = Label.new()
	header.text = "Block %s — %s" % [bid, dist.to_upper()]
	if gold:
		header.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	else:
		header.add_theme_color_override("font_color", Color(0.0, 1.0, 1.0))
	header.add_theme_font_size_override("font_size", 15)
	vbox.add_child(header)

	var streak_lbl: Label = Label.new()
	var gold_tag: String = " ✨ GOLD GLOW ACTIVE" if gold else \
			(" — %d more days to gold!" % (12 - streak) if streak < 12 else "")
	streak_lbl.text = "Decoration Streak: %d day%s%s" \
			% [streak, "s" if streak != 1 else "", gold_tag]
	streak_lbl.add_theme_color_override("font_color",
			Color(1.0, 0.85, 0.0) if gold else Color(0.9, 0.9, 0.5))
	streak_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(streak_lbl)

	var decay_lbl: Label = Label.new()
	decay_lbl.text = "Condition: %s" % _decay_label(stage)
	decay_lbl.add_theme_color_override("font_color", _decay_color(stage))
	decay_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(decay_lbl)

	var income_lbl: Label = Label.new()
	income_lbl.text = "Weekly Income: %d QT  |  Tenants: %d / %d" \
			% [income, tenants, slots]
	income_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	income_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(income_lbl)

	return card

# ── Populate: Event Zones ─────────────────────────────────────────────────────

func _populate_event_zones() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null:
		return

	if los.active_event_zones.is_empty():
		var lbl: Label = Label.new()
		lbl.text = "No active event zones right now.\nCheck back later!"
		lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		block_list.add_child(lbl)
		return

	for zone in los.active_event_zones:
		block_list.add_child(_make_event_zone_card(zone))

func _make_event_zone_card(zone: Dictionary) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)

	var vbox: VBoxContainer = VBoxContainer.new()
	margin.add_child(vbox)

	var name_lbl: Label = Label.new()
	name_lbl.text = "🌟  " + zone.get("name", "Event Zone")
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))
	name_lbl.add_theme_font_size_override("font_size", 16)
	vbox.add_child(name_lbl)

	var desc_lbl: Label = Label.new()
	desc_lbl.text = zone.get("description", "")
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	desc_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(desc_lbl)

	var now_unix: int = int(Time.get_unix_time_from_system())
	var exp: int = int(zone.get("expires_unix", 0))
	var secs_left: int = max(0, exp - now_unix)
	var time_str: String = _format_countdown(secs_left)

	var timer_lbl: Label = Label.new()
	timer_lbl.text = "⏱  Expires in: %s" % time_str
	timer_lbl.add_theme_color_override("font_color",
			Color(1.0, 0.3, 0.3) if secs_left < 3600 else Color(1.0, 0.85, 0.0))
	timer_lbl.add_theme_font_size_override("font_size", 13)
	vbox.add_child(timer_lbl)

	var reward_lbl: Label = Label.new()
	reward_lbl.text = "🎁  Reward: %d QT" % int(zone.get("reward_tokens", 0))
	reward_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	reward_lbl.add_theme_font_size_override("font_size", 12)
	vbox.add_child(reward_lbl)

	if bool(zone.get("is_visited", false)):
		var visited_lbl: Label = Label.new()
		visited_lbl.text = "✅  Already visited"
		visited_lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
		visited_lbl.add_theme_font_size_override("font_size", 12)
		vbox.add_child(visited_lbl)

	return card

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_blocks_updated(_ids: Array) -> void:
	if visible:
		_switch_tab(_current_tab)

func _on_owned_changed(_ids: Array) -> void:
	_refresh_balance()
	if visible and _current_tab == "owned":
		_populate_owned_blocks()

func _on_claim_result(success: bool, block_id: String, reason: String) -> void:
	if success:
		_show_toast("✅  Block %s claimed!" % block_id, Color(0.5, 1.0, 0.5))
	else:
		_show_toast("❌  Claim failed: %s" % reason, Color(1.0, 0.4, 0.4))
	if visible:
		_switch_tab(_current_tab)

func _on_release_result(success: bool, block_id: String, reason: String) -> void:
	if success:
		_show_toast("🔓  Block %s released." % block_id, Color(0.8, 0.8, 0.8))
	else:
		_show_toast("❌  Release failed: %s" % reason, Color(1.0, 0.4, 0.4))
	if visible:
		_switch_tab(_current_tab)

func _on_neighborhood_drama(owned_bid: String, _rival_bid: String,
		rival_name: String, message: String) -> void:
	_drama_queue.append({"msg": message, "color": Color(1.0, 0.5, 0.0)})
	if not drama_toast.visible:
		_show_drama_toast(_drama_queue.pop_front())
	# Also flash if the panel is closed.
	if not visible:
		_flash_screen_border(Color(1.0, 0.5, 0.0))

func _on_event_zones_updated(zones: Array) -> void:
	_update_event_banner(zones)
	if visible and _current_tab == "events":
		_populate_event_zones()

func _on_event_zone_entered(zone: Dictionary) -> void:
	_flash_screen_border(Color(1.0, 0.6, 0.0))
	_show_toast("🌟  Entered %s!  +%d QT reward incoming!" \
			% [zone.get("name", "Event Zone"),
			   int(zone.get("reward_tokens", 0))],
			Color(1.0, 0.85, 0.0))

func _on_streak_updated(block_id: String, new_streak: int,
		gold_glow_unlocked: bool) -> void:
	if gold_glow_unlocked:
		_show_toast("✨  Block %s streak = %d days — GOLD GLOW UNLOCKED!" \
				% [block_id, new_streak], Color(1.0, 0.85, 0.0))
	else:
		_show_toast("🎨  Decoration streak: %d day%s!" \
				% [new_streak, "s" if new_streak != 1 else ""],
				Color(0.8, 0.9, 1.0))

# ── Button callbacks ──────────────────────────────────────────────────────────

func _on_claim_pressed(block_id: String) -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		los.claim_block(block_id)

func _on_release_pressed(block_id: String) -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		los.release_block(block_id)

func _on_decorate_pressed(block_id: String) -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		los.report_decoration_update(block_id)

# ── Helpers ───────────────────────────────────────────────────────────────────

func _refresh_balance() -> void:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los:
		balance_lbl.text = "Balance: %d QT" % los.quant_balance
	else:
		balance_lbl.text = "Balance: — QT"

func _show_toast(message: String, color: Color) -> void:
	drama_label.text = message
	drama_label.add_theme_color_override("font_color", color)
	drama_toast.visible = true
	_drama_show_timer = DRAMA_DISPLAY_SECS

func _show_drama_toast(entry: Dictionary) -> void:
	_show_toast(entry.get("msg", ""), entry.get("color", Color.WHITE))

func _update_event_banner(zones: Array) -> void:
	if zones.is_empty():
		event_banner.visible = false
		return

	var zone: Dictionary = zones[0]
	event_title.text = "🌟  " + zone.get("name", "Event Zone")
	event_reward.text = "Reward: %d QT" % int(zone.get("reward_tokens", 0))
	event_banner.visible = true

func _update_event_banner_timer() -> void:
	if not event_banner.visible:
		return
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los == null or los.active_event_zones.is_empty():
		event_banner.visible = false
		return
	var zone: Dictionary = los.active_event_zones[0]
	var now_unix: int = int(Time.get_unix_time_from_system())
	var secs_left: int = max(0, int(zone.get("expires_unix", 0)) - now_unix)
	event_timer.text = "⏱  " + _format_countdown(secs_left)
	event_timer.add_theme_color_override("font_color",
			Color(1.0, 0.3, 0.3) if secs_left < 600 else Color(1.0, 0.85, 0.0))

func _flash_screen_border(color: Color) -> void:
	var rect: ColorRect = ColorRect.new()
	rect.color = Color(color.r, color.g, color.b, 0.35)
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(rect)
	var tween = create_tween().set_loops(2)
	tween.tween_property(rect, "color:a", 0.0, 0.6)
	tween.tween_property(rect, "color:a", 0.35, 0.3)
	get_tree().create_timer(3.0).timeout.connect(rect.queue_free)

func _decay_label(stage: int) -> String:
	match stage:
		0: return "Pristine"
		1: return "Flickering"
		2: return "Dimming"
		3: return "👻 Ghost"
		4: return "💀 Ruins"
		_: return "Unknown"

func _decay_color(stage: int) -> Color:
	match stage:
		0: return Color(0.5, 1.0, 0.5)
		1: return Color(1.0, 1.0, 0.5)
		2: return Color(1.0, 0.7, 0.3)
		3: return Color(0.6, 0.6, 1.0)
		4: return Color(0.5, 0.3, 0.3)
		_: return Color.WHITE

func _format_countdown(secs: int) -> String:
	if secs <= 0:
		return "EXPIRED"
	var h: int = secs / 3600
	var m: int = (secs % 3600) / 60
	var s: int = secs % 60
	if h > 0:
		return "%dh %02dm" % [h, m]
	elif m > 0:
		return "%dm %02ds" % [m, s]
	return "%ds" % s
