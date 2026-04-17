## RentEconomyUI — Panel for managing rent slots and viewing passive income.
##
## Shows:
##   • Owned blocks with their rent slots, tenant info, and weekly rent.
##   • Income ledger (last 30 payout events).
##   • Controls to open/close slots, set rent rates, and evict tenants.
##   • Income summary: total earned, pending payout, top-earning block.
##
## Toggle with "R" key or via interaction with a Rent Terminal in the world.

extends CanvasLayer

# ── Node references ────────────────────────────────────────────────────────────

@onready var bg_dim: ColorRect         = $BgDim
@onready var close_btn: Button         = $MainPanel/Header/CloseButton
@onready var title_lbl: Label          = $MainPanel/Header/TitleLabel
@onready var summary_lbl: Label        = $MainPanel/SummaryBar/SummaryLabel
@onready var tab_slots: Button         = $MainPanel/TabBar/TabSlots
@onready var tab_history: Button       = $MainPanel/TabBar/TabHistory
@onready var content_list: VBoxContainer = $MainPanel/ContentArea/ContentList
@onready var toast_lbl: Label          = $Toast/ToastLabel

# ── State ──────────────────────────────────────────────────────────────────────

var _current_tab: String = "slots"
var _toast_timer: float  = 0.0
const TOAST_DURATION: float = 4.0

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	hide()
	close_btn.pressed.connect(_close)
	tab_slots.pressed.connect(func(): _switch_tab("slots"))
	tab_history.pressed.connect(func(): _switch_tab("history"))

	var re: Node = get_node_or_null("/root/RentEconomy")
	if re:
		re.rent_slots_updated.connect(_on_slots_updated)
		re.rent_payout_received.connect(_on_payout_received)
		re.tenant_placement_result.connect(_on_placement_result)
		re.tenant_vacated.connect(_on_tenant_vacated)
		re.income_summary_updated.connect(_on_summary_updated)

	$Toast.visible = false

func _process(delta: float) -> void:
	if Input.is_action_just_pressed("rent_panel"):
		if visible:
			_close()
		else:
			open_panel()

	if $Toast.visible:
		_toast_timer -= delta
		if _toast_timer <= 0.0:
			$Toast.visible = false

# ── Open / Close ──────────────────────────────────────────────────────────────

func open_panel() -> void:
	show()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_refresh_summary()
	_switch_tab(_current_tab)

func _close() -> void:
	hide()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

# ── Tab switching ─────────────────────────────────────────────────────────────

func _switch_tab(tab: String) -> void:
	_current_tab = tab
	_clear_list()
	match tab:
		"slots":   _populate_slots()
		"history": _populate_history()

func _clear_list() -> void:
	for child in content_list.get_children():
		child.queue_free()

# ── Populate: Slots ───────────────────────────────────────────────────────────

func _populate_slots() -> void:
	var re: Node  = get_node_or_null("/root/RentEconomy")
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if re == null or los == null:
		return

	var owned_ids: Array = los.owned_block_ids
	if owned_ids.is_empty():
		_add_empty_label("You don't own any land blocks yet.")
		return

	for bid in owned_ids:
		var block_section: VBoxContainer = VBoxContainer.new()
		block_section.add_theme_constant_override("separation", 4)
		content_list.add_child(block_section)

		# Block header.
		var header: Label = Label.new()
		header.text = "▶  Block %s" % bid
		header.add_theme_color_override("font_color", Color(0.0, 1.0, 1.0))
		header.add_theme_font_size_override("font_size", 14)
		block_section.add_child(header)

		var slots: Array = re.get_slots_for_block(bid)

		if slots.is_empty():
			var no_slots: Label = Label.new()
			no_slots.text = "  No rent slots opened on this block yet."
			no_slots.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			no_slots.add_theme_font_size_override("font_size", 12)
			block_section.add_child(no_slots)
		else:
			for slot in slots:
				block_section.add_child(_make_slot_card(slot, bid, re))

		# "Open new slot" row.
		var open_row: HBoxContainer = HBoxContainer.new()
		block_section.add_child(open_row)

		var open_shop_btn: Button = Button.new()
		open_shop_btn.text = "+ Shop Slot"
		open_shop_btn.pressed.connect(func():
			re.open_rent_slot(bid, RentEconomy.SLOT_TYPE_SHOP))
		open_row.add_child(open_shop_btn)

		var open_bb_btn: Button = Button.new()
		open_bb_btn.text = "+ Billboard"
		open_bb_btn.pressed.connect(func():
			re.open_rent_slot(bid, RentEconomy.SLOT_TYPE_BILLBOARD))
		open_row.add_child(open_bb_btn)

		var open_kiosk_btn: Button = Button.new()
		open_kiosk_btn.text = "+ Kiosk"
		open_kiosk_btn.pressed.connect(func():
			re.open_rent_slot(bid, RentEconomy.SLOT_TYPE_KIOSK))
		open_row.add_child(open_kiosk_btn)

		# Spacer.
		var spacer: HSeparator = HSeparator.new()
		content_list.add_child(spacer)

func _make_slot_card(slot: Dictionary, block_id: String, re: Node) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_bottom", 4)
	card.add_child(margin)

	var hbox: HBoxContainer = HBoxContainer.new()
	margin.add_child(hbox)

	var info_vbox: VBoxContainer = VBoxContainer.new()
	info_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_vbox)

	var sid: String      = slot.get("slot_id", "?")
	var stype: String    = slot.get("type", "shop").to_upper()
	var occupied: bool   = bool(slot.get("is_occupied", false))
	var tenant: String   = slot.get("tenant_name", "")
	var rent: int        = int(slot.get("weekly_rent", 0))
	var label: String    = slot.get("custom_label", "")

	var slot_lbl: Label = Label.new()
	slot_lbl.text = "[%s]  %s  |  %d QT/week" \
			% [stype, label if label != "" else sid.substr(0, 8), rent]
	slot_lbl.add_theme_color_override("font_color",
			Color(0.5, 1.0, 0.5) if occupied else Color(0.9, 0.9, 0.9))
	slot_lbl.add_theme_font_size_override("font_size", 13)
	info_vbox.add_child(slot_lbl)

	var tenant_lbl: Label = Label.new()
	if occupied:
		tenant_lbl.text = "  Tenant: %s" % tenant
		tenant_lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 1.0))
	else:
		tenant_lbl.text = "  [Open — awaiting tenant]"
		tenant_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	tenant_lbl.add_theme_font_size_override("font_size", 12)
	info_vbox.add_child(tenant_lbl)

	# Buttons.
	var btn_col: VBoxContainer = VBoxContainer.new()
	hbox.add_child(btn_col)

	if occupied:
		var evict_btn: Button = Button.new()
		evict_btn.text = "EVICT"
		evict_btn.pressed.connect(func():
			re.evict_tenant(block_id, sid))
		btn_col.add_child(evict_btn)

	var close_slot_btn: Button = Button.new()
	close_slot_btn.text = "CLOSE SLOT"
	close_slot_btn.pressed.connect(func():
		re.close_rent_slot(block_id, sid))
	btn_col.add_child(close_slot_btn)

	return card

# ── Populate: Income History ──────────────────────────────────────────────────

func _populate_history() -> void:
	var re: Node = get_node_or_null("/root/RentEconomy")
	if re == null:
		return

	var history: Array = re.get_income_history()
	if history.is_empty():
		_add_empty_label("No income events yet.")
		return

	for entry in history:
		content_list.add_child(_make_history_row(entry))

func _make_history_row(entry: Dictionary) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()

	var ts: int    = int(entry.get("timestamp_unix", 0))
	var dt: String = Time.get_datetime_string_from_unix_time(ts)
	var bid: String   = entry.get("block_id", "?")
	var tenant: String = entry.get("tenant_name", "?")
	var amount: int   = int(entry.get("amount", 0))

	var lbl: Label = Label.new()
	lbl.text = "%s  Block %s  ← %d QT from %s" % [dt, bid, amount, tenant]
	lbl.add_theme_color_override("font_color", Color(0.5, 1.0, 0.5))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	return row

# ── Signal handlers ───────────────────────────────────────────────────────────

func _on_slots_updated(block_id: String, _slots: Array) -> void:
	if visible and _current_tab == "slots":
		_populate_slots()

func _on_payout_received(block_id: String, amount: int, _pending: int) -> void:
	_show_toast("💰  +%d QT rent from Block %s!" % [amount, block_id],
			Color(0.5, 1.0, 0.5))
	_refresh_summary()

func _on_placement_result(success: bool, _bid: String, _sid: String,
		reason: String) -> void:
	if success:
		_show_toast("✅  Tenant placed successfully!", Color(0.5, 1.0, 0.5))
	else:
		_show_toast("❌  Placement failed: %s" % reason, Color(1.0, 0.4, 0.4))

func _on_tenant_vacated(block_id: String, _slot_id: String,
		tenant_name: String) -> void:
	_show_toast("📤  %s vacated Block %s." % [tenant_name, block_id],
			Color(1.0, 0.85, 0.0))

func _on_summary_updated(_summary: Dictionary) -> void:
	_refresh_summary()

# ── Helpers ───────────────────────────────────────────────────────────────────

func _refresh_summary() -> void:
	var re: Node = get_node_or_null("/root/RentEconomy")
	if re == null:
		return
	var s: Dictionary = re.get_income_summary()
	summary_lbl.text = (
		"Session: +%d QT  |  Tenants: %d  |  Pending: %d QT"
		% [int(s.get("total_session_income", 0)),
		   int(s.get("total_active_tenants", 0)),
		   int(s.get("total_pending_payout", 0))]
	)

func _add_empty_label(text: String) -> void:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content_list.add_child(lbl)

func _show_toast(message: String, color: Color) -> void:
	toast_lbl.text = message
	toast_lbl.add_theme_color_override("font_color", color)
	$Toast.visible = true
	_toast_timer = TOAST_DURATION
