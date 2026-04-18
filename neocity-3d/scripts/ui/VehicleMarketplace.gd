## VehicleMarketplace — Trade custom vehicles, auction system,
## trending builds leaderboard, and purchase/listing flow.

extends CanvasLayer

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal listing_created(listing: Dictionary)
signal bid_placed(listing_id: String, amount: int)
signal listing_purchased(listing_id: String, price: int)
signal listing_cancelled(listing_id: String)
signal marketplace_opened()
signal marketplace_closed()
signal leaderboard_refreshed(entries: Array)

# ---------------------------------------------------------------------------
# Listing states
# ---------------------------------------------------------------------------
const STATE_ACTIVE    := "active"
const STATE_SOLD      := "sold"
const STATE_EXPIRED   := "expired"
const STATE_CANCELLED := "cancelled"

# Auction type
const AUCTION_FIXED   := "fixed_price"
const AUCTION_BID     := "auction"

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
# A listing has this shape:
# {
#   "id": String,
#   "seller_id": String,
#   "seller_name": String,
#   "vehicle_id": String,
#   "vehicle_name": String,
#   "config": Dictionary,        # VehicleCustomizer config
#   "upgrades": Dictionary,      # PerformanceUpgrades equipped_tiers
#   "auction_type": String,      # fixed_price | auction
#   "buy_now_price": int,
#   "start_bid": int,
#   "current_bid": int,
#   "current_bidder_id": String,
#   "current_bidder_name": String,
#   "ends_at_unix": float,
#   "created_at_unix": float,
#   "state": String,
#   "views": int,
#   "likes": int,
#   "tags": Array[String],
#   "description": String,
# }

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _listings: Array[Dictionary] = []
var _my_listings: Array[Dictionary] = []
var _watch_list: Array[String] = []    # listing IDs
var _leaderboard: Array[Dictionary] = []
var _current_player_id: String = "player_001"
var _current_player_name: String = "You"
var _token_balance: int = 0
var _is_open := false
var _active_tab := 0
var _search_query := ""
var _filter_type := "all"
var _sort_mode := "newest"
var _selected_listing_id := ""

# Auction tick timer
var _auction_timer: float = 0.0
const AUCTION_TICK_INTERVAL := 1.0

# ---------------------------------------------------------------------------
# UI references
# ---------------------------------------------------------------------------
var _root: Control = null
var _tab_bar: HBoxContainer = null
var _pages: Array[Control] = []
var _status_label: Label = null
var _balance_label: Label = null
var _close_btn: Button = null

# Browse tab
var _search_input: LineEdit = null
var _filter_option: OptionButton = null
var _sort_option: OptionButton = null
var _browse_scroll: ScrollContainer = null
var _browse_list: VBoxContainer = null
var _listing_detail_panel: PanelContainer = null
var _detail_title: Label = null
var _detail_color_rect: ColorRect = null
var _detail_seller: Label = null
var _detail_price: Label = null
var _detail_bid_info: Label = null
var _detail_time_left: Label = null
var _detail_description: Label = null
var _detail_buy_btn: Button = null
var _detail_bid_input: SpinBox = null
var _detail_place_bid_btn: Button = null
var _detail_watch_btn: Button = null
var _detail_stats_labels: Dictionary = {}

# Sell tab
var _sell_vehicle_option: OptionButton = null
var _sell_config_option: OptionButton = null
var _sell_type_option: OptionButton = null
var _sell_price_input: SpinBox = null
var _sell_start_bid_input: SpinBox = null
var _sell_duration_option: OptionButton = null
var _sell_description_input: TextEdit = null
var _sell_tags_input: LineEdit = null
var _sell_list_btn: Button = null

# My Listings tab
var _my_listings_scroll: VBoxContainer = null

# Watchlist tab
var _watchlist_scroll: VBoxContainer = null

# Leaderboard tab
var _leaderboard_scroll: VBoxContainer = null
var _leaderboard_period_option: OptionButton = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	layer = 11
	_build_ui()
	visible = false
	_populate_mock_listings()
	_build_leaderboard()

func _process(delta: float) -> void:
	if not _is_open:
		return
	_auction_timer += delta
	if _auction_timer >= AUCTION_TICK_INTERVAL:
		_auction_timer = 0.0
		_tick_auctions()
		if _active_tab == 0 and _selected_listing_id != "":
			_refresh_detail_panel(_selected_listing_id)

# ---------------------------------------------------------------------------
# Open / Close
# ---------------------------------------------------------------------------
func open_marketplace(player_id: String = "", player_name: String = "", balance: int = 0) -> void:
	if player_id != "":
		_current_player_id = player_id
	if player_name != "":
		_current_player_name = player_name
	_token_balance = balance
	_is_open = true
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_update_balance_label()
	_switch_tab(0)
	emit_signal("marketplace_opened")
	print("[VehicleMarketplace] Opened")

func close_marketplace() -> void:
	_is_open = false
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	emit_signal("marketplace_closed")

# ---------------------------------------------------------------------------
# UI Construction
# ---------------------------------------------------------------------------
func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.04, 0.04, 0.08, 0.92)
	_root.add_child(bg)

	var main_vbox := VBoxContainer.new()
	main_vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	main_vbox.add_theme_constant_override("separation", 0)
	_root.add_child(main_vbox)

	_build_header(main_vbox)
	_build_tab_bar_row(main_vbox)

	var content := Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content)

	_pages.clear()
	_pages.append(_build_browse_page())
	_pages.append(_build_sell_page())
	_pages.append(_build_my_listings_page())
	_pages.append(_build_watchlist_page())
	_pages.append(_build_leaderboard_page())

	for page in _pages:
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		content.add_child(page)

	_build_footer(main_vbox)

func _build_header(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)

	var title := Label.new()
	title.text = "⚙ VEHICLE MARKETPLACE"
	title.add_theme_color_override("font_color", Color(1.0, 0.6, 0.1))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	_balance_label = Label.new()
	_balance_label.text = "⬡ 0 QUANT"
	_balance_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	row.add_child(_balance_label)

	_close_btn = Button.new()
	_close_btn.text = "✕ Close"
	_close_btn.pressed.connect(close_marketplace)
	row.add_child(_close_btn)

func _build_tab_bar_row(parent: Control) -> void:
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 4)
	parent.add_child(_tab_bar)

	const TABS := ["🔍 Browse", "📤 Sell", "📋 My Listings", "⭐ Watchlist", "🏆 Leaderboard"]
	for i in range(TABS.size()):
		var btn := Button.new()
		btn.text = TABS[i]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_switch_tab.bind(i))
		_tab_bar.add_child(btn)

func _build_footer(parent: Control) -> void:
	_status_label = Label.new()
	_status_label.text = "Welcome to the Marketplace."
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	parent.add_child(_status_label)

# ---------------------------------------------------------------------------
# Browse page
# ---------------------------------------------------------------------------
func _build_browse_page() -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_stretch_ratio = 1.4
	hbox.add_child(left_vbox)

	_build_browse_filters(left_vbox)

	_browse_scroll = ScrollContainer.new()
	_browse_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(_browse_scroll)

	_browse_list = VBoxContainer.new()
	_browse_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_browse_scroll.add_child(_browse_list)

	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(320, 0)
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_stretch_ratio = 1.0
	hbox.add_child(right_panel)
	_build_detail_panel(right_panel)

	return hbox

func _build_browse_filters(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	_search_input = LineEdit.new()
	_search_input.placeholder_text = "Search vehicles..."
	_search_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_input.text_changed.connect(_on_search_changed)
	row.add_child(_search_input)

	_filter_option = OptionButton.new()
	for opt in ["All", "Fixed Price", "Auction", "My Bids"]:
		_filter_option.add_item(opt)
	_filter_option.item_selected.connect(_on_filter_changed)
	row.add_child(_filter_option)

	_sort_option = OptionButton.new()
	for opt in ["Newest", "Ending Soon", "Price Low", "Price High", "Most Views", "Most Liked"]:
		_sort_option.add_item(opt)
	_sort_option.item_selected.connect(_on_sort_changed)
	row.add_child(_sort_option)

	var refresh_btn := Button.new()
	refresh_btn.text = "↻"
	refresh_btn.pressed.connect(_refresh_browse_list)
	row.add_child(refresh_btn)

func _build_detail_panel(parent: Control) -> void:
	var vbox := VBoxContainer.new()
	parent.add_child(vbox)

	_detail_title = Label.new()
	_detail_title.text = "Select a listing"
	_detail_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
	vbox.add_child(_detail_title)

	_detail_color_rect = ColorRect.new()
	_detail_color_rect.custom_minimum_size = Vector2(0, 50)
	_detail_color_rect.color = Color(0.2, 0.2, 0.3)
	vbox.add_child(_detail_color_rect)

	_detail_seller = Label.new()
	_detail_seller.text = "Seller: —"
	vbox.add_child(_detail_seller)

	_detail_price = Label.new()
	_detail_price.text = "Price: —"
	_detail_price.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	vbox.add_child(_detail_price)

	_detail_bid_info = Label.new()
	_detail_bid_info.text = ""
	vbox.add_child(_detail_bid_info)

	_detail_time_left = Label.new()
	_detail_time_left.text = ""
	vbox.add_child(_detail_time_left)

	_detail_description = Label.new()
	_detail_description.text = ""
	_detail_description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_detail_description)

	vbox.add_child(HSeparator.new())

	var stats_grid := GridContainer.new()
	stats_grid.columns = 2
	vbox.add_child(stats_grid)

	for stat in ["Speed", "Accel", "Handling", "Braking", "Nitro"]:
		var k := Label.new()
		k.text = stat + ":"
		stats_grid.add_child(k)
		var v := Label.new()
		v.text = "—"
		stats_grid.add_child(v)
		_detail_stats_labels[stat.to_lower()] = v

	vbox.add_child(HSeparator.new())

	_detail_buy_btn = Button.new()
	_detail_buy_btn.text = "Buy Now"
	_detail_buy_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.4))
	_detail_buy_btn.visible = false
	_detail_buy_btn.pressed.connect(_on_buy_now_pressed)
	vbox.add_child(_detail_buy_btn)

	var bid_row := HBoxContainer.new()
	vbox.add_child(bid_row)

	_detail_bid_input = SpinBox.new()
	_detail_bid_input.min_value = 0
	_detail_bid_input.max_value = 9999999
	_detail_bid_input.step = 50
	_detail_bid_input.visible = false
	_detail_bid_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bid_row.add_child(_detail_bid_input)

	_detail_place_bid_btn = Button.new()
	_detail_place_bid_btn.text = "Place Bid"
	_detail_place_bid_btn.visible = false
	_detail_place_bid_btn.pressed.connect(_on_place_bid_pressed)
	bid_row.add_child(_detail_place_bid_btn)

	_detail_watch_btn = Button.new()
	_detail_watch_btn.text = "☆ Watch"
	_detail_watch_btn.visible = false
	_detail_watch_btn.pressed.connect(_on_watch_pressed)
	vbox.add_child(_detail_watch_btn)

# ---------------------------------------------------------------------------
# Sell page
# ---------------------------------------------------------------------------
func _build_sell_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_h("List a Vehicle for Sale"))

	vbox.add_child(_lbl("Vehicle:"))
	_sell_vehicle_option = OptionButton.new()
	_sell_vehicle_option.add_item("My Car #1 (NeoRacer)")
	_sell_vehicle_option.add_item("My Car #2 (HoverBike)")
	_sell_vehicle_option.add_item("My Car #3 (CyberTruck)")
	vbox.add_child(_sell_vehicle_option)

	vbox.add_child(_lbl("Configuration:"))
	_sell_config_option = OptionButton.new()
	_sell_config_option.add_item("Current Config")
	_sell_config_option.add_item("Default Stock")
	vbox.add_child(_sell_config_option)

	vbox.add_child(_lbl("Sale Type:"))
	_sell_type_option = OptionButton.new()
	_sell_type_option.add_item("Fixed Price")
	_sell_type_option.add_item("Auction")
	_sell_type_option.item_selected.connect(_on_sell_type_changed)
	vbox.add_child(_sell_type_option)

	vbox.add_child(_lbl("Buy Now Price (QUANT):"))
	_sell_price_input = SpinBox.new()
	_sell_price_input.min_value = 100
	_sell_price_input.max_value = 9999999
	_sell_price_input.value = 5000
	_sell_price_input.step = 100
	vbox.add_child(_sell_price_input)

	vbox.add_child(_lbl("Starting Bid (QUANT):"))
	_sell_start_bid_input = SpinBox.new()
	_sell_start_bid_input.min_value = 50
	_sell_start_bid_input.max_value = 9999999
	_sell_start_bid_input.value = 500
	_sell_start_bid_input.step = 50
	_sell_start_bid_input.visible = false
	vbox.add_child(_sell_start_bid_input)

	vbox.add_child(_lbl("Auction Duration:"))
	_sell_duration_option = OptionButton.new()
	for dur in ["1 Hour", "6 Hours", "12 Hours", "24 Hours", "3 Days", "7 Days"]:
		_sell_duration_option.add_item(dur)
	_sell_duration_option.select(3)
	vbox.add_child(_sell_duration_option)

	vbox.add_child(_lbl("Description:"))
	_sell_description_input = TextEdit.new()
	_sell_description_input.placeholder_text = "Describe your build..."
	_sell_description_input.custom_minimum_size = Vector2(0, 80)
	vbox.add_child(_sell_description_input)

	vbox.add_child(_lbl("Tags (comma-separated):"))
	_sell_tags_input = LineEdit.new()
	_sell_tags_input.placeholder_text = "neon, sport, rare..."
	vbox.add_child(_sell_tags_input)

	_sell_list_btn = Button.new()
	_sell_list_btn.text = "📤 List on Marketplace"
	_sell_list_btn.add_theme_color_override("font_color", Color(0.2, 1.0, 0.5))
	_sell_list_btn.pressed.connect(_on_create_listing)
	vbox.add_child(_sell_list_btn)

	return scroll

# ---------------------------------------------------------------------------
# My Listings page
# ---------------------------------------------------------------------------
func _build_my_listings_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_h("My Active Listings"))

	_my_listings_scroll = vbox
	_refresh_my_listings()
	return scroll

# ---------------------------------------------------------------------------
# Watchlist page
# ---------------------------------------------------------------------------
func _build_watchlist_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_h("Watchlist"))

	_watchlist_scroll = vbox
	_refresh_watchlist()
	return scroll

# ---------------------------------------------------------------------------
# Leaderboard page
# ---------------------------------------------------------------------------
func _build_leaderboard_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_h("🏆 Trending Builds"))

	var row := HBoxContainer.new()
	vbox.add_child(row)
	row.add_child(_lbl("Period:"))
	_leaderboard_period_option = OptionButton.new()
	for p in ["Today", "This Week", "This Month", "All Time"]:
		_leaderboard_period_option.add_item(p)
	_leaderboard_period_option.item_selected.connect(_on_leaderboard_period_changed)
	row.add_child(_leaderboard_period_option)

	var refresh_btn := Button.new()
	refresh_btn.text = "↻ Refresh"
	refresh_btn.pressed.connect(_build_leaderboard)
	row.add_child(refresh_btn)

	_leaderboard_scroll = vbox
	return scroll

# ---------------------------------------------------------------------------
# Tab switching
# ---------------------------------------------------------------------------
func _switch_tab(index: int) -> void:
	_active_tab = index
	for i in range(_pages.size()):
		_pages[i].visible = (i == index)
	for i in range(_tab_bar.get_child_count()):
		var btn := _tab_bar.get_child(i) as Button
		if btn:
			btn.add_theme_color_override("font_color",
				Color(1.0, 0.7, 0.2) if i == index else Color(0.8, 0.8, 0.8))
	match index:
		0: _refresh_browse_list()
		2: _refresh_my_listings()
		3: _refresh_watchlist()
		4: _build_leaderboard()

# ---------------------------------------------------------------------------
# Browse list population
# ---------------------------------------------------------------------------
func _refresh_browse_list() -> void:
	if _browse_list == null:
		return
	for c in _browse_list.get_children():
		c.queue_free()

	var filtered := _get_filtered_listings()
	for listing in filtered:
		var row := _build_listing_row(listing)
		_browse_list.add_child(row)

	if filtered.is_empty():
		var lbl := Label.new()
		lbl.text = "No listings found."
		_browse_list.add_child(lbl)

	_set_status("Showing %d listings." % filtered.size())

func _get_filtered_listings() -> Array:
	var result: Array = []
	for listing in _listings:
		if listing["state"] != STATE_ACTIVE:
			continue
		if _search_query != "":
			var q := _search_query.to_lower()
			var match_found := (listing["vehicle_name"].to_lower().contains(q)
				or listing["seller_name"].to_lower().contains(q)
				or listing["description"].to_lower().contains(q))
			if not match_found:
				var tags: Array = listing.get("tags", [])
				for tag in tags:
					if tag.to_lower().contains(q):
						match_found = true
						break
			if not match_found:
				continue
		match _filter_type:
			"fixed_price":
				if listing["auction_type"] != AUCTION_FIXED:
					continue
			"auction":
				if listing["auction_type"] != AUCTION_BID:
					continue
			"my_bids":
				if listing.get("current_bidder_id", "") != _current_player_id:
					continue
		result.append(listing)

	match _sort_mode:
		"newest":
			result.sort_custom(func(a, b): return a["created_at_unix"] > b["created_at_unix"])
		"ending_soon":
			result.sort_custom(func(a, b): return a["ends_at_unix"] < b["ends_at_unix"])
		"price_low":
			result.sort_custom(func(a, b): return _effective_price(a) < _effective_price(b))
		"price_high":
			result.sort_custom(func(a, b): return _effective_price(a) > _effective_price(b))
		"views":
			result.sort_custom(func(a, b): return a["views"] > b["views"])
		"likes":
			result.sort_custom(func(a, b): return a["likes"] > b["likes"])

	return result

func _effective_price(listing: Dictionary) -> int:
	if listing["auction_type"] == AUCTION_FIXED:
		return listing["buy_now_price"]
	return listing["current_bid"]

func _build_listing_row(listing: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 60)
	var hbox := HBoxContainer.new()
	card.add_child(hbox)

	var color_rect := ColorRect.new()
	color_rect.custom_minimum_size = Vector2(48, 0)
	color_rect.color = listing["config"].get("paint_color", Color(0.3, 0.3, 0.5))
	hbox.add_child(color_rect)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = listing["vehicle_name"]
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	vbox.add_child(name_lbl)

	var info_lbl := Label.new()
	var price_str := ""
	if listing["auction_type"] == AUCTION_FIXED:
		price_str = "⬡ %d QUANT (Buy Now)" % listing["buy_now_price"]
	else:
		price_str = "⬡ %d QUANT (Bid) — %d bids" % [listing["current_bid"], listing.get("bid_count", 0)]
	info_lbl.text = "%s  |  Seller: %s  |  %s" % [price_str, listing["seller_name"], _time_left_str(listing)]
	vbox.add_child(info_lbl)

	var tag_str := ""
	var tags: Array = listing.get("tags", [])
	if not tags.is_empty():
		tag_str = "  ".join(tags.map(func(t): return "#" + t))
	if tag_str != "":
		var tag_lbl := Label.new()
		tag_lbl.text = tag_str
		tag_lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
		vbox.add_child(tag_lbl)

	var like_lbl := Label.new()
	like_lbl.text = "👁 %d  ❤ %d" % [listing["views"], listing["likes"]]
	hbox.add_child(like_lbl)

	var select_btn := Button.new()
	select_btn.text = "▶"
	select_btn.pressed.connect(_on_listing_selected.bind(listing["id"]))
	hbox.add_child(select_btn)

	listing["views"] += 1
	return card

# ---------------------------------------------------------------------------
# Listing detail
# ---------------------------------------------------------------------------
func _on_listing_selected(listing_id: String) -> void:
	_selected_listing_id = listing_id
	_refresh_detail_panel(listing_id)

func _refresh_detail_panel(listing_id: String) -> void:
	var listing := _find_listing(listing_id)
	if listing.is_empty():
		return

	if _detail_title:
		_detail_title.text = listing["vehicle_name"]
	if _detail_color_rect:
		_detail_color_rect.color = listing["config"].get("paint_color", Color(0.3, 0.3, 0.5))
	if _detail_seller:
		_detail_seller.text = "Seller: " + listing["seller_name"]

	if listing["auction_type"] == AUCTION_FIXED:
		if _detail_price:
			_detail_price.text = "⬡ %d QUANT (Fixed Price)" % listing["buy_now_price"]
		if _detail_bid_info:
			_detail_bid_info.text = ""
		if _detail_buy_btn:
			_detail_buy_btn.visible = listing["seller_id"] != _current_player_id
		if _detail_bid_input:
			_detail_bid_input.visible = false
		if _detail_place_bid_btn:
			_detail_place_bid_btn.visible = false
	else:
		if _detail_price:
			_detail_price.text = "⬡ %d QUANT (Current Bid)" % listing["current_bid"]
		if _detail_bid_info:
			var bidder := listing.get("current_bidder_name", "No bids yet")
			_detail_bid_info.text = "Top bidder: %s  |  %d bids" % [bidder, listing.get("bid_count", 0)]
		if _detail_buy_btn:
			_detail_buy_btn.visible = listing["buy_now_price"] > 0 and listing["seller_id"] != _current_player_id
			_detail_buy_btn.text = "Buy Now — ⬡ %d" % listing["buy_now_price"]
		if _detail_bid_input:
			_detail_bid_input.visible = listing["seller_id"] != _current_player_id
			_detail_bid_input.value = listing["current_bid"] + 50
			_detail_bid_input.min_value = listing["current_bid"] + 1
		if _detail_place_bid_btn:
			_detail_place_bid_btn.visible = listing["seller_id"] != _current_player_id

	if _detail_time_left:
		_detail_time_left.text = "⏱ " + _time_left_str(listing)

	if _detail_description:
		_detail_description.text = listing.get("description", "")

	var upgrades: Dictionary = listing.get("upgrades", {})
	for stat_key in _detail_stats_labels.keys():
		var lbl := _detail_stats_labels[stat_key] as Label
		if lbl:
			lbl.text = str(upgrades.get(stat_key, "Stock"))

	if _detail_watch_btn:
		_detail_watch_btn.visible = listing["seller_id"] != _current_player_id
		var watched := _watch_list.has(listing_id)
		_detail_watch_btn.text = "★ Watching" if watched else "☆ Watch"

# ---------------------------------------------------------------------------
# Browse filter callbacks
# ---------------------------------------------------------------------------
func _on_search_changed(text: String) -> void:
	_search_query = text
	_refresh_browse_list()

func _on_filter_changed(index: int) -> void:
	match index:
		0: _filter_type = "all"
		1: _filter_type = "fixed_price"
		2: _filter_type = "auction"
		3: _filter_type = "my_bids"
	_refresh_browse_list()

func _on_sort_changed(index: int) -> void:
	match index:
		0: _sort_mode = "newest"
		1: _sort_mode = "ending_soon"
		2: _sort_mode = "price_low"
		3: _sort_mode = "price_high"
		4: _sort_mode = "views"
		5: _sort_mode = "likes"
	_refresh_browse_list()

# ---------------------------------------------------------------------------
# Buy / Bid
# ---------------------------------------------------------------------------
func _on_buy_now_pressed() -> void:
	var listing := _find_listing(_selected_listing_id)
	if listing.is_empty():
		return
	var price: int = listing["buy_now_price"]
	if _token_balance < price:
		_set_status("Insufficient QUANT tokens. Need ⬡ %d, have ⬡ %d." % [price, _token_balance])
		return

	var dialog := AcceptDialog.new()
	dialog.title = "Confirm Purchase"
	dialog.dialog_text = "Buy '%s' for ⬡ %d QUANT?" % [listing["vehicle_name"], price]
	dialog.add_cancel_button("Cancel")
	dialog.confirmed.connect(func():
		_execute_buy_now(listing)
	)
	_root.add_child(dialog)
	dialog.popup_centered()

func _execute_buy_now(listing: Dictionary) -> void:
	_token_balance -= listing["buy_now_price"]
	listing["state"] = STATE_SOLD
	_update_balance_label()
	_set_status("Purchased '%s' for ⬡ %d!" % [listing["vehicle_name"], listing["buy_now_price"]])
	emit_signal("listing_purchased", listing["id"], listing["buy_now_price"])
	_send_purchase_event(listing["id"], listing["buy_now_price"])
	_refresh_browse_list()

func _on_place_bid_pressed() -> void:
	var listing := _find_listing(_selected_listing_id)
	if listing.is_empty():
		return
	if _detail_bid_input == null:
		return

	var bid_amount := int(_detail_bid_input.value)
	if bid_amount <= listing["current_bid"]:
		_set_status("Bid must be higher than current bid (⬡ %d)." % listing["current_bid"])
		return
	if _token_balance < bid_amount:
		_set_status("Insufficient QUANT tokens.")
		return

	listing["current_bid"] = bid_amount
	listing["current_bidder_id"] = _current_player_id
	listing["current_bidder_name"] = _current_player_name
	listing["bid_count"] = listing.get("bid_count", 0) + 1

	emit_signal("bid_placed", listing["id"], bid_amount)
	_send_bid_event(listing["id"], bid_amount)
	_set_status("Bid placed: ⬡ %d on '%s'." % [bid_amount, listing["vehicle_name"]])
	_refresh_detail_panel(listing["id"])

func _on_watch_pressed() -> void:
	if _selected_listing_id == "":
		return
	if _watch_list.has(_selected_listing_id):
		_watch_list.erase(_selected_listing_id)
		_set_status("Removed from watchlist.")
	else:
		_watch_list.append(_selected_listing_id)
		_set_status("Added to watchlist.")
	_refresh_detail_panel(_selected_listing_id)

# ---------------------------------------------------------------------------
# Sell / Create Listing
# ---------------------------------------------------------------------------
func _on_sell_type_changed(index: int) -> void:
	if _sell_start_bid_input:
		_sell_start_bid_input.visible = (index == 1)

func _on_create_listing() -> void:
	var vehicle_name := "Unknown Vehicle"
	if _sell_vehicle_option:
		vehicle_name = _sell_vehicle_option.get_item_text(_sell_vehicle_option.selected)

	var auction_type := AUCTION_FIXED
	if _sell_type_option and _sell_type_option.selected == 1:
		auction_type = AUCTION_BID

	var buy_now := int(_sell_price_input.value) if _sell_price_input else 5000
	var start_bid := int(_sell_start_bid_input.value) if _sell_start_bid_input else 500

	var duration_hours := _get_duration_hours()
	var ends_at := Time.get_unix_time_from_system() + duration_hours * 3600.0

	var desc := _sell_description_input.text.strip_edges() if _sell_description_input else ""
	var tags_raw := _sell_tags_input.text.strip_edges() if _sell_tags_input else ""
	var tags: Array[String] = []
	for t in tags_raw.split(","):
		var stripped := t.strip_edges()
		if stripped != "":
			tags.append(stripped.to_lower())

	var listing: Dictionary = {
		"id":                  "lst_" + str(Time.get_unix_time_from_system()) + "_" + str(randi() % 9999),
		"seller_id":           _current_player_id,
		"seller_name":         _current_player_name,
		"vehicle_id":          "vehicle_" + str(randi() % 100),
		"vehicle_name":        vehicle_name,
		"config":              {},
		"upgrades":            {},
		"auction_type":        auction_type,
		"buy_now_price":       buy_now if auction_type == AUCTION_FIXED else buy_now,
		"start_bid":           start_bid,
		"current_bid":         start_bid,
		"current_bidder_id":   "",
		"current_bidder_name": "No bids yet",
		"bid_count":           0,
		"ends_at_unix":        ends_at,
		"created_at_unix":     Time.get_unix_time_from_system(),
		"state":               STATE_ACTIVE,
		"views":               0,
		"likes":               0,
		"tags":                tags,
		"description":         desc,
	}

	_listings.append(listing)
	_my_listings.append(listing)
	emit_signal("listing_created", listing)
	_send_listing_event(listing)
	_set_status("Listing created: '%s' for ⬡ %d." % [vehicle_name, buy_now])
	_switch_tab(2)

func _get_duration_hours() -> float:
	if _sell_duration_option == null:
		return 24.0
	match _sell_duration_option.selected:
		0: return 1.0
		1: return 6.0
		2: return 12.0
		3: return 24.0
		4: return 72.0
		5: return 168.0
	return 24.0

# ---------------------------------------------------------------------------
# My Listings refresh
# ---------------------------------------------------------------------------
func _refresh_my_listings() -> void:
	if _my_listings_scroll == null:
		return
	for c in _my_listings_scroll.get_children():
		if c is not Label:
			c.queue_free()

	var mine := _listings.filter(func(l): return l["seller_id"] == _current_player_id)
	if mine.is_empty():
		var lbl := Label.new()
		lbl.text = "You have no active listings."
		_my_listings_scroll.add_child(lbl)
		return

	for listing in mine:
		var row := _build_my_listing_row(listing)
		_my_listings_scroll.add_child(row)

func _build_my_listing_row(listing: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 70)
	var hbox := HBoxContainer.new()
	card.add_child(hbox)

	var color_rect := ColorRect.new()
	color_rect.custom_minimum_size = Vector2(40, 0)
	color_rect.color = listing["config"].get("paint_color", Color(0.3, 0.3, 0.5))
	hbox.add_child(color_rect)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = listing["vehicle_name"]
	vbox.add_child(name_lbl)

	var state_lbl := Label.new()
	state_lbl.text = "State: %s  |  %s" % [listing["state"].capitalize(), _time_left_str(listing)]
	vbox.add_child(state_lbl)

	if listing["auction_type"] == AUCTION_BID:
		var bid_lbl := Label.new()
		bid_lbl.text = "Current bid: ⬡ %d  (%d bids)  Top: %s" % [
			listing["current_bid"],
			listing.get("bid_count", 0),
			listing.get("current_bidder_name", "—"),
		]
		vbox.add_child(bid_lbl)

	if listing["state"] == STATE_ACTIVE:
		var cancel_btn := Button.new()
		cancel_btn.text = "Cancel Listing"
		cancel_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		cancel_btn.pressed.connect(_on_cancel_listing.bind(listing["id"]))
		hbox.add_child(cancel_btn)

	return card

func _on_cancel_listing(listing_id: String) -> void:
	var listing := _find_listing(listing_id)
	if listing.is_empty():
		return
	if listing["seller_id"] != _current_player_id:
		_set_status("You can only cancel your own listings.")
		return
	listing["state"] = STATE_CANCELLED
	emit_signal("listing_cancelled", listing_id)
	_set_status("Listing cancelled.")
	_refresh_my_listings()

# ---------------------------------------------------------------------------
# Watchlist refresh
# ---------------------------------------------------------------------------
func _refresh_watchlist() -> void:
	if _watchlist_scroll == null:
		return
	for c in _watchlist_scroll.get_children():
		if c is not Label:
			c.queue_free()

	if _watch_list.is_empty():
		var lbl := Label.new()
		lbl.text = "Your watchlist is empty."
		_watchlist_scroll.add_child(lbl)
		return

	for lid in _watch_list:
		var listing := _find_listing(lid)
		if listing.is_empty():
			continue
		var row := _build_listing_row(listing)
		_watchlist_scroll.add_child(row)

# ---------------------------------------------------------------------------
# Leaderboard
# ---------------------------------------------------------------------------
func _build_leaderboard() -> void:
	if _leaderboard_scroll == null:
		return

	for c in _leaderboard_scroll.get_children():
		if c is not Label and c is not HBoxContainer:
			c.queue_free()

	_leaderboard = _compute_leaderboard()

	if _leaderboard.is_empty():
		var lbl := Label.new()
		lbl.text = "No leaderboard data yet."
		_leaderboard_scroll.add_child(lbl)
		return

	for i in range(_leaderboard.size()):
		var entry: Dictionary = _leaderboard[i]
		var row := _build_leaderboard_row(i + 1, entry)
		_leaderboard_scroll.add_child(row)

	emit_signal("leaderboard_refreshed", _leaderboard)

func _compute_leaderboard() -> Array:
	var scored: Array = []
	for listing in _listings:
		if listing["state"] == STATE_ACTIVE or listing["state"] == STATE_SOLD:
			scored.append(listing)
	scored.sort_custom(func(a, b): return (a["likes"] + a["views"] * 0.1) > (b["likes"] + b["views"] * 0.1))
	return scored.slice(0, 20)

func _build_leaderboard_row(rank: int, listing: Dictionary) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(0, 55)
	var hbox := HBoxContainer.new()
	card.add_child(hbox)

	var rank_lbl := Label.new()
	rank_lbl.text = "#%d" % rank
	rank_lbl.custom_minimum_size = Vector2(36, 0)
	var rank_color := Color(1.0, 0.85, 0.0) if rank <= 3 else Color(0.8, 0.8, 0.8)
	rank_lbl.add_theme_color_override("font_color", rank_color)
	hbox.add_child(rank_lbl)

	var color_rect := ColorRect.new()
	color_rect.custom_minimum_size = Vector2(36, 0)
	color_rect.color = listing["config"].get("paint_color", Color(0.3, 0.3, 0.5))
	hbox.add_child(color_rect)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = listing["vehicle_name"]
	name_lbl.add_theme_color_override("font_color", Color(1.0, 0.9, 0.5))
	vbox.add_child(name_lbl)

	var info_lbl := Label.new()
	info_lbl.text = "By %s  |  ❤ %d  |  👁 %d  |  ⬡ %d" % [
		listing["seller_name"],
		listing["likes"],
		listing["views"],
		_effective_price(listing),
	]
	vbox.add_child(info_lbl)

	var tags_str := "  ".join(listing.get("tags", []).map(func(t): return "#" + t))
	if tags_str != "":
		var tag_lbl := Label.new()
		tag_lbl.text = tags_str
		tag_lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
		vbox.add_child(tag_lbl)

	var like_btn := Button.new()
	like_btn.text = "❤ Like"
	like_btn.pressed.connect(_on_like_listing.bind(listing["id"]))
	hbox.add_child(like_btn)

	return card

func _on_like_listing(listing_id: String) -> void:
	var listing := _find_listing(listing_id)
	if not listing.is_empty():
		listing["likes"] += 1
		_set_status("Liked listing!")
		_build_leaderboard()

func _on_leaderboard_period_changed(_index: int) -> void:
	_build_leaderboard()

# ---------------------------------------------------------------------------
# Auction tick
# ---------------------------------------------------------------------------
func _tick_auctions() -> void:
	var now := Time.get_unix_time_from_system()
	for listing in _listings:
		if listing["state"] != STATE_ACTIVE:
			continue
		if listing["ends_at_unix"] <= now:
			_finalise_auction(listing)

func _finalise_auction(listing: Dictionary) -> void:
	if listing["auction_type"] == AUCTION_BID and listing.get("current_bidder_id", "") != "":
		listing["state"] = STATE_SOLD
		_set_status("Auction ended: '%s' sold to %s for ⬡ %d!" % [
			listing["vehicle_name"],
			listing["current_bidder_name"],
			listing["current_bid"],
		])
		emit_signal("listing_purchased", listing["id"], listing["current_bid"])
	else:
		listing["state"] = STATE_EXPIRED
		_set_status("Listing '%s' expired with no bids." % listing["vehicle_name"])

# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------
func _send_bid_event(listing_id: String, amount: int) -> void:
	var nm := get_node_or_null("/root/NetworkManager")
	if nm and nm.socket_client:
		nm.socket_client.send_event("marketplace_bid", {
			"listing_id": listing_id,
			"amount": amount,
			"bidder_id": _current_player_id,
		})

func _send_purchase_event(listing_id: String, price: int) -> void:
	var nm := get_node_or_null("/root/NetworkManager")
	if nm and nm.socket_client:
		nm.socket_client.send_event("marketplace_purchase", {
			"listing_id": listing_id,
			"price": price,
			"buyer_id": _current_player_id,
		})

func _send_listing_event(listing: Dictionary) -> void:
	var nm := get_node_or_null("/root/NetworkManager")
	if nm and nm.socket_client:
		nm.socket_client.send_event("marketplace_new_listing", {
			"listing_id": listing["id"],
			"vehicle_name": listing["vehicle_name"],
			"auction_type": listing["auction_type"],
			"price": listing["buy_now_price"],
		})

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------
func _find_listing(listing_id: String) -> Dictionary:
	for l in _listings:
		if l["id"] == listing_id:
			return l
	return {}

func _time_left_str(listing: Dictionary) -> String:
	var now := Time.get_unix_time_from_system()
	var diff := listing["ends_at_unix"] - now
	if diff <= 0.0:
		return "Ended"
	if diff < 60.0:
		return "%ds left" % int(diff)
	if diff < 3600.0:
		return "%dm left" % int(diff / 60.0)
	if diff < 86400.0:
		return "%dh %dm left" % [int(diff / 3600.0), int(fmod(diff, 3600.0) / 60.0)]
	return "%dd left" % int(diff / 86400.0)

func _set_status(msg: String) -> void:
	if _status_label:
		_status_label.text = msg

func _update_balance_label() -> void:
	if _balance_label:
		_balance_label.text = "⬡ %d QUANT" % _token_balance

func _h(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.2))
	return lbl

func _lbl(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl

# ---------------------------------------------------------------------------
# Populate mock data (used when backend is unavailable)
# ---------------------------------------------------------------------------
func _populate_mock_listings() -> void:
	var now := Time.get_unix_time_from_system()
	var mock_data: Array[Dictionary] = [
		{
			"vehicle_name": "NeoRacer S1",
			"seller_name": "CyberAce",
			"auction_type": AUCTION_FIXED,
			"buy_now_price": 8500,
			"start_bid": 0,
			"current_bid": 0,
			"ends_at_unix": now + 3600 * 48,
			"paint_color": Color(0.0, 0.8, 1.0),
			"tags": ["neon", "sport", "race"],
			"description": "Fully maxed Race-tier upgrades. Chrome paint with cyan underglow.",
			"likes": 34, "views": 210,
		},
		{
			"vehicle_name": "Phantom GT",
			"seller_name": "GhostRider",
			"auction_type": AUCTION_BID,
			"buy_now_price": 15000,
			"start_bid": 3000,
			"current_bid": 5200,
			"ends_at_unix": now + 3600 * 6,
			"paint_color": Color(0.05, 0.05, 0.05),
			"tags": ["matte", "stealth", "elite"],
			"description": "Elite tier everything. Ultra-rare stealth matte black finish.",
			"likes": 88, "views": 540,
		},
		{
			"vehicle_name": "HoverBike X",
			"seller_name": "NeonQueen",
			"auction_type": AUCTION_FIXED,
			"buy_now_price": 4200,
			"start_bid": 0,
			"current_bid": 0,
			"ends_at_unix": now + 3600 * 72,
			"paint_color": Color(1.0, 0.2, 0.8),
			"tags": ["hover", "pink", "custom"],
			"description": "Pearlescent magenta with flames decal and sport upgrades.",
			"likes": 22, "views": 130,
		},
		{
			"vehicle_name": "CyberTruck Z",
			"seller_name": "TechDragon",
			"auction_type": AUCTION_BID,
			"buy_now_price": 25000,
			"start_bid": 10000,
			"current_bid": 12500,
			"ends_at_unix": now + 3600 * 2,
			"paint_color": Color(0.6, 0.6, 0.7),
			"tags": ["chrome", "elite", "truck"],
			"description": "Chrome finish, elite engine & brakes. Spider chart maxed.",
			"likes": 105, "views": 890,
		},
		{
			"vehicle_name": "SkyDart Coupe",
			"seller_name": "UrbanPilot",
			"auction_type": AUCTION_FIXED,
			"buy_now_price": 6700,
			"start_bid": 0,
			"current_bid": 0,
			"ends_at_unix": now + 3600 * 24 * 3,
			"paint_color": Color(0.1, 0.9, 0.3),
			"tags": ["candy", "green", "sport"],
			"description": "Candy apple green with racing stripes. Race suspension.",
			"likes": 19, "views": 95,
		},
	]

	for i in range(mock_data.size()):
		var m := mock_data[i]
		var listing: Dictionary = {
			"id":                  "mock_%d" % i,
			"seller_id":           "seller_%d" % i,
			"seller_name":         m["seller_name"],
			"vehicle_id":          "vehicle_%d" % i,
			"vehicle_name":        m["vehicle_name"],
			"config":              {"paint_color": m["paint_color"]},
			"upgrades":            {},
			"auction_type":        m["auction_type"],
			"buy_now_price":       m["buy_now_price"],
			"start_bid":           m["start_bid"],
			"current_bid":         m["current_bid"],
			"current_bidder_id":   "",
			"current_bidder_name": "No bids yet",
			"bid_count":           0,
			"ends_at_unix":        m["ends_at_unix"],
			"created_at_unix":     now - randi_range(60, 7200),
			"state":               STATE_ACTIVE,
			"views":               m["views"],
			"likes":               m["likes"],
			"tags":                m["tags"],
			"description":         m["description"],
		}
		_listings.append(listing)
