## GarageUI — 3D showroom with orbit camera, comparison slider,
## purchase confirmation, and "My Collection" panel.
## Integrates VehicleCustomizer and PerformanceUpgrades.

extends CanvasLayer

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal garage_opened()
signal garage_closed()
signal config_purchase_confirmed(config: Dictionary, cost: int)
signal vehicle_selected(vehicle_id: String)

# ---------------------------------------------------------------------------
# Sub-system references (set from scene or autoload)
# ---------------------------------------------------------------------------
var customizer: Node = null      # VehicleCustomizer instance
var upgrades: Node = null        # PerformanceUpgrades instance
var active_vehicle: Node3D = null

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _is_open := false
var _tab_index := 0              # 0=Paint 1=Decals 2=Wheels 3=Body 4=Performance 5=Collection
var _orbit_yaw := 0.0
var _orbit_pitch := 15.0
var _orbit_distance := 6.0
var _orbit_target := Vector3.ZERO
var _orbit_dragging := false
var _drag_last := Vector2.ZERO
var _comparison_active := false
var _comparison_value := 0.0    # 0.0 = before, 1.0 = after
var _platform_rotation := 0.0
var _auto_rotate := true
var _collection_vehicles: Array[Dictionary] = []
var _selected_collection_index := -1

# 3D viewport / sub-viewport for garage showroom
var _garage_viewport: SubViewport = null
var _garage_camera: Camera3D = null
var _platform_node: Node3D = null
var _studio_lights: Array[DirectionalLight3D] = []

# UI root
var _root_control: Control = null
var _main_panel: PanelContainer = null
var _tab_bar: HBoxContainer = null
var _content_stack: Control = null
var _pages: Array[Control] = []
var _status_bar: Label = null
var _balance_label: Label = null
var _viewport_rect: TextureRect = null
var _comparison_slider: HSlider = null
var _comparison_before_rect: TextureRect = null
var _comparison_after_rect: TextureRect = null
var _comparison_container: Control = null
var _undo_button: Button = null
var _redo_button: Button = null
var _save_button: Button = null
var _randomise_button: Button = null
var _close_button: Button = null
var _spin_toggle: CheckButton = null
var _zoom_slider: HSlider = null

# Paint page
var _paint_color_picker: ColorPickerButton = null
var _secondary_color_picker: ColorPickerButton = null
var _finish_option: OptionButton = null
var _paint_preview_rect: ColorRect = null

# Decal page
var _decal_grid: GridContainer = null
var _decal_color_picker: ColorPickerButton = null
var _decal_opacity_slider: HSlider = null

# Wheel page
var _wheel_grid: GridContainer = null
var _wheel_color_picker: ColorPickerButton = null

# Body kit page
var _spoiler_option: OptionButton = null
var _exhaust_option: OptionButton = null
var _underglow_check: CheckButton = null
var _underglow_color_picker: ColorPickerButton = null
var _underglow_intensity_slider: HSlider = null
var _window_tint_slider: HSlider = null
var _tint_color_picker: ColorPickerButton = null
var _plate_input: LineEdit = null

# Performance page
var _upgrade_panels: Dictionary = {}   # category -> VBoxContainer
var _spider_chart_container: Control = null
var _token_balance_label: Label = null

# Collection page
var _collection_grid: GridContainer = null
var _collection_detail_panel: PanelContainer = null

# Purchase dialog
var _purchase_dialog: AcceptDialog = null
var _pending_purchase: Dictionary = {}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	layer = 10
	_build_ui()
	visible = false
	_load_collection()

func _process(delta: float) -> void:
	if not _is_open:
		return
	if _auto_rotate and not _orbit_dragging:
		_platform_rotation += delta * 20.0
		if active_vehicle:
			active_vehicle.rotation_degrees.y = _platform_rotation
	_update_camera_transform()

# ---------------------------------------------------------------------------
# Open / Close
# ---------------------------------------------------------------------------
func open_garage(vehicle: Node3D = null, cust: Node = null, upg: Node = null) -> void:
	customizer = cust
	upgrades = upg
	active_vehicle = vehicle
	_is_open = true
	visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if customizer:
		customizer.snapshot_before()
		_sync_ui_from_config(customizer.current_config)
	if upgrades:
		_rebuild_performance_page()
		upgrades.refresh_spider_chart()
	_switch_tab(0)
	emit_signal("garage_opened")
	print("[GarageUI] Opened")

func close_garage() -> void:
	_is_open = false
	visible = false
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	emit_signal("garage_closed")
	print("[GarageUI] Closed")

# ---------------------------------------------------------------------------
# UI Construction
# ---------------------------------------------------------------------------
func _build_ui() -> void:
	_root_control = Control.new()
	_root_control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root_control)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.75)
	_root_control.add_child(bg)

	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 0)
	_root_control.add_child(hbox)

	_build_viewport_panel(hbox)
	_build_side_panel(hbox)

	_build_purchase_dialog()

func _build_viewport_panel(parent: Control) -> void:
	var vp_container := PanelContainer.new()
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_stretch_ratio = 2.0
	parent.add_child(vp_container)

	var vbox := VBoxContainer.new()
	vp_container.add_child(vbox)

	_viewport_rect = TextureRect.new()
	_viewport_rect.custom_minimum_size = Vector2(0, 400)
	_viewport_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_viewport_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(_viewport_rect)

	_build_viewport_controls(vbox)
	_build_comparison_area(vbox)

func _build_viewport_controls(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	_spin_toggle = CheckButton.new()
	_spin_toggle.text = "Auto Spin"
	_spin_toggle.button_pressed = true
	_spin_toggle.toggled.connect(_on_auto_spin_toggled)
	row.add_child(_spin_toggle)

	var zoom_lbl := Label.new()
	zoom_lbl.text = "Zoom:"
	row.add_child(zoom_lbl)

	_zoom_slider = HSlider.new()
	_zoom_slider.min_value = 2.0
	_zoom_slider.max_value = 12.0
	_zoom_slider.value = _orbit_distance
	_zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_zoom_slider.value_changed.connect(_on_zoom_changed)
	row.add_child(_zoom_slider)

	var reset_btn := Button.new()
	reset_btn.text = "Reset View"
	reset_btn.pressed.connect(_reset_camera)
	row.add_child(reset_btn)

func _build_comparison_area(parent: Control) -> void:
	_comparison_container = VBoxContainer.new()
	_comparison_container.visible = false
	parent.add_child(_comparison_container)

	var lbl := Label.new()
	lbl.text = "Before ←———— Comparison Slider ————→ After"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_comparison_container.add_child(lbl)

	_comparison_slider = HSlider.new()
	_comparison_slider.min_value = 0.0
	_comparison_slider.max_value = 1.0
	_comparison_slider.value = 1.0
	_comparison_slider.step = 0.01
	_comparison_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_comparison_slider.value_changed.connect(_on_comparison_slider_changed)
	_comparison_container.add_child(_comparison_slider)

	var row := HBoxContainer.new()
	_comparison_container.add_child(row)

	var before_btn := Button.new()
	before_btn.text = "Show Before"
	before_btn.pressed.connect(_on_show_before)
	row.add_child(before_btn)

	var after_btn := Button.new()
	after_btn.text = "Show After"
	after_btn.pressed.connect(_on_show_after)
	row.add_child(after_btn)

func _build_side_panel(parent: Control) -> void:
	_main_panel = PanelContainer.new()
	_main_panel.custom_minimum_size = Vector2(380, 0)
	_main_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_panel.size_flags_stretch_ratio = 1.0
	parent.add_child(_main_panel)

	var vbox := VBoxContainer.new()
	_main_panel.add_child(vbox)

	_build_top_bar(vbox)
	_build_tab_bar(vbox)
	_build_content_area(vbox)
	_build_action_bar(vbox)
	_build_status_bar(vbox)

func _build_top_bar(parent: Control) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var title := Label.new()
	title.text = "▶ GARAGE"
	title.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)

	_balance_label = Label.new()
	_balance_label.text = "⬡ 0 QUANT"
	_balance_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	row.add_child(_balance_label)

	_close_button = Button.new()
	_close_button.text = "✕"
	_close_button.pressed.connect(close_garage)
	row.add_child(_close_button)

func _build_tab_bar(parent: Control) -> void:
	_tab_bar = HBoxContainer.new()
	_tab_bar.add_theme_constant_override("separation", 2)
	parent.add_child(_tab_bar)

	const TAB_NAMES := ["Paint", "Decals", "Wheels", "Body", "Performance", "Collection"]
	for i in range(TAB_NAMES.size()):
		var btn := Button.new()
		btn.text = TAB_NAMES[i]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_switch_tab.bind(i))
		_tab_bar.add_child(btn)

func _build_content_area(parent: Control) -> void:
	_content_stack = Control.new()
	_content_stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_stack.custom_minimum_size = Vector2(0, 400)
	parent.add_child(_content_stack)

	_pages.clear()
	_pages.append(_build_paint_page())
	_pages.append(_build_decals_page())
	_pages.append(_build_wheels_page())
	_pages.append(_build_body_page())
	_pages.append(_build_performance_page())
	_pages.append(_build_collection_page())

	for page in _pages:
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_content_stack.add_child(page)

func _build_action_bar(parent: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	_undo_button = Button.new()
	_undo_button.text = "↩ Undo"
	_undo_button.pressed.connect(_on_undo)
	row.add_child(_undo_button)

	_redo_button = Button.new()
	_redo_button.text = "↪ Redo"
	_redo_button.pressed.connect(_on_redo)
	row.add_child(_redo_button)

	_randomise_button = Button.new()
	_randomise_button.text = "🎲 Random"
	_randomise_button.pressed.connect(_on_randomise)
	row.add_child(_randomise_button)

	var compare_btn := Button.new()
	compare_btn.text = "⇌ Compare"
	compare_btn.pressed.connect(_on_toggle_comparison)
	row.add_child(compare_btn)

	_save_button = Button.new()
	_save_button.text = "💾 Save"
	_save_button.pressed.connect(_on_save_config)
	row.add_child(_save_button)

func _build_status_bar(parent: Control) -> void:
	_status_bar = Label.new()
	_status_bar.text = "Ready."
	_status_bar.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	parent.add_child(_status_bar)

# ---------------------------------------------------------------------------
# Individual page builders
# ---------------------------------------------------------------------------
func _build_paint_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_section_label("Body Color"))

	var color_row := HBoxContainer.new()
	vbox.add_child(color_row)
	var cl := Label.new()
	cl.text = "Primary:"
	color_row.add_child(cl)
	_paint_color_picker = ColorPickerButton.new()
	_paint_color_picker.color = Color(0.1, 0.5, 1.0)
	_paint_color_picker.custom_minimum_size = Vector2(120, 32)
	_paint_color_picker.color_changed.connect(_on_paint_color_changed)
	color_row.add_child(_paint_color_picker)

	var sec_row := HBoxContainer.new()
	vbox.add_child(sec_row)
	var sl := Label.new()
	sl.text = "Secondary:"
	sec_row.add_child(sl)
	_secondary_color_picker = ColorPickerButton.new()
	_secondary_color_picker.color = Color(0.05, 0.05, 0.05)
	_secondary_color_picker.custom_minimum_size = Vector2(120, 32)
	_secondary_color_picker.color_changed.connect(_on_secondary_color_changed)
	sec_row.add_child(_secondary_color_picker)

	vbox.add_child(_section_label("Paint Finish"))
	_finish_option = OptionButton.new()
	for finish in ["Metallic", "Matte", "Chrome", "Pearlescent", "Candy", "Satin"]:
		_finish_option.add_item(finish)
	_finish_option.item_selected.connect(_on_finish_selected)
	vbox.add_child(_finish_option)

	_paint_preview_rect = ColorRect.new()
	_paint_preview_rect.custom_minimum_size = Vector2(0, 40)
	_paint_preview_rect.color = Color(0.1, 0.5, 1.0)
	vbox.add_child(_paint_preview_rect)

	vbox.add_child(_section_label("Quick Presets"))
	var preset_grid := GridContainer.new()
	preset_grid.columns = 6
	var presets := [
		Color.RED, Color.ORANGE, Color.YELLOW, Color.GREEN,
		Color.CYAN, Color.BLUE, Color.PURPLE, Color.MAGENTA,
		Color.WHITE, Color.SILVER, Color.BLACK, Color(0.02, 0.02, 0.02),
	]
	for c in presets:
		var swatch := ColorRect.new()
		swatch.custom_minimum_size = Vector2(36, 36)
		swatch.color = c
		var btn_overlay := Button.new()
		btn_overlay.flat = true
		btn_overlay.pressed.connect(_on_preset_color.bind(c))
		btn_overlay.custom_minimum_size = Vector2(36, 36)
		var container := PanelContainer.new()
		container.add_child(swatch)
		container.add_child(btn_overlay)
		preset_grid.add_child(container)
	vbox.add_child(preset_grid)

	return scroll

func _build_decals_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_section_label("Decal Template"))

	_decal_grid = GridContainer.new()
	_decal_grid.columns = 3
	_populate_decal_grid()
	vbox.add_child(_decal_grid)

	vbox.add_child(_section_label("Decal Color"))
	var row := HBoxContainer.new()
	vbox.add_child(row)
	row.add_child(_make_label("Color:"))
	_decal_color_picker = ColorPickerButton.new()
	_decal_color_picker.color = Color.WHITE
	_decal_color_picker.custom_minimum_size = Vector2(100, 30)
	_decal_color_picker.color_changed.connect(_on_decal_color_changed)
	row.add_child(_decal_color_picker)

	var op_row := HBoxContainer.new()
	vbox.add_child(op_row)
	op_row.add_child(_make_label("Opacity:"))
	_decal_opacity_slider = HSlider.new()
	_decal_opacity_slider.min_value = 0.0
	_decal_opacity_slider.max_value = 1.0
	_decal_opacity_slider.value = 1.0
	_decal_opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_decal_opacity_slider.value_changed.connect(_on_decal_opacity_changed)
	op_row.add_child(_decal_opacity_slider)

	return scroll

func _populate_decal_grid() -> void:
	if _decal_grid == null:
		return
	for c in _decal_grid.get_children():
		c.queue_free()
	if customizer == null:
		return
	for template in customizer.DECAL_TEMPLATES:
		var btn := Button.new()
		btn.text = template["name"]
		btn.custom_minimum_size = Vector2(110, 40)
		btn.pressed.connect(_on_decal_selected.bind(template["id"]))
		if customizer.current_config.get("decal_id", 0) == template["id"]:
			btn.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		_decal_grid.add_child(btn)

func _build_wheels_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_section_label("Wheel Style"))
	_wheel_grid = GridContainer.new()
	_wheel_grid.columns = 2
	_populate_wheel_grid()
	vbox.add_child(_wheel_grid)

	vbox.add_child(_section_label("Rim Color"))
	var row := HBoxContainer.new()
	vbox.add_child(row)
	row.add_child(_make_label("Color:"))
	_wheel_color_picker = ColorPickerButton.new()
	_wheel_color_picker.color = Color(0.8, 0.8, 0.8)
	_wheel_color_picker.custom_minimum_size = Vector2(100, 30)
	_wheel_color_picker.color_changed.connect(_on_wheel_color_changed)
	row.add_child(_wheel_color_picker)

	return scroll

func _populate_wheel_grid() -> void:
	if _wheel_grid == null:
		return
	for c in _wheel_grid.get_children():
		c.queue_free()
	if customizer == null:
		return
	for style in customizer.WHEEL_STYLES:
		var btn := Button.new()
		btn.text = style["name"]
		btn.custom_minimum_size = Vector2(160, 40)
		btn.pressed.connect(_on_wheel_selected.bind(style["id"]))
		if customizer.current_config.get("wheel_id", 0) == style["id"]:
			btn.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
		_wheel_grid.add_child(btn)

func _build_body_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_section_label("Spoiler"))
	_spoiler_option = OptionButton.new()
	if customizer:
		for s in customizer.SPOILER_STYLES:
			_spoiler_option.add_item(s["name"])
	_spoiler_option.item_selected.connect(_on_spoiler_selected)
	vbox.add_child(_spoiler_option)

	vbox.add_child(_section_label("Exhaust"))
	_exhaust_option = OptionButton.new()
	if customizer:
		for e in customizer.EXHAUST_STYLES:
			_exhaust_option.add_item(e["name"])
	_exhaust_option.item_selected.connect(_on_exhaust_selected)
	vbox.add_child(_exhaust_option)

	vbox.add_child(_section_label("Underglow"))
	var ug_row := HBoxContainer.new()
	vbox.add_child(ug_row)
	_underglow_check = CheckButton.new()
	_underglow_check.text = "Enable Underglow"
	_underglow_check.toggled.connect(_on_underglow_toggled)
	ug_row.add_child(_underglow_check)

	var ug_color_row := HBoxContainer.new()
	vbox.add_child(ug_color_row)
	ug_color_row.add_child(_make_label("Color:"))
	_underglow_color_picker = ColorPickerButton.new()
	_underglow_color_picker.color = Color(0, 1, 1)
	_underglow_color_picker.custom_minimum_size = Vector2(100, 30)
	_underglow_color_picker.color_changed.connect(_on_underglow_color_changed)
	ug_color_row.add_child(_underglow_color_picker)

	var ug_int_row := HBoxContainer.new()
	vbox.add_child(ug_int_row)
	ug_int_row.add_child(_make_label("Intensity:"))
	_underglow_intensity_slider = HSlider.new()
	_underglow_intensity_slider.min_value = 0.5
	_underglow_intensity_slider.max_value = 6.0
	_underglow_intensity_slider.value = 2.0
	_underglow_intensity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_underglow_intensity_slider.value_changed.connect(_on_underglow_intensity_changed)
	ug_int_row.add_child(_underglow_intensity_slider)

	vbox.add_child(_section_label("Window Tint"))
	var tint_row := HBoxContainer.new()
	vbox.add_child(tint_row)
	tint_row.add_child(_make_label("Opacity:"))
	_window_tint_slider = HSlider.new()
	_window_tint_slider.min_value = 0.0
	_window_tint_slider.max_value = 0.9
	_window_tint_slider.value = 0.0
	_window_tint_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_window_tint_slider.value_changed.connect(_on_tint_opacity_changed)
	tint_row.add_child(_window_tint_slider)

	var tint_color_row := HBoxContainer.new()
	vbox.add_child(tint_color_row)
	tint_color_row.add_child(_make_label("Tint:"))
	_tint_color_picker = ColorPickerButton.new()
	_tint_color_picker.color = Color(0, 0, 0)
	_tint_color_picker.custom_minimum_size = Vector2(100, 30)
	_tint_color_picker.color_changed.connect(_on_tint_color_changed)
	tint_color_row.add_child(_tint_color_picker)

	vbox.add_child(_section_label("License Plate"))
	_plate_input = LineEdit.new()
	_plate_input.placeholder_text = "QUANT01"
	_plate_input.max_length = 8
	_plate_input.text_submitted.connect(_on_plate_submitted)
	vbox.add_child(_plate_input)

	return scroll

func _build_performance_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	_token_balance_label = Label.new()
	_token_balance_label.text = "Balance: 0 QUANT"
	_token_balance_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.0))
	vbox.add_child(_token_balance_label)

	_spider_chart_container = Control.new()
	_spider_chart_container.custom_minimum_size = Vector2(220, 220)
	vbox.add_child(_spider_chart_container)

	_upgrade_panels.clear()
	for cat in ["engine", "brakes", "suspension", "nitro", "turbo", "tires"]:
		var panel := _build_upgrade_category_panel(cat)
		vbox.add_child(panel)
		_upgrade_panels[cat] = panel

	return scroll

func _build_upgrade_category_panel(category: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	if upgrades == null:
		return panel

	var data: Dictionary = upgrades.UPGRADE_DATA.get(category, {})
	var header := Label.new()
	header.text = data.get("display_name", category.capitalize())
	header.add_theme_color_override("font_color", Color(0.9, 0.9, 1.0))
	vbox.add_child(header)

	var tier_row := HBoxContainer.new()
	tier_row.add_theme_constant_override("separation", 4)
	vbox.add_child(tier_row)

	for tier in range(4):
		var tier_btn := Button.new()
		var tier_data: Dictionary = data.get(tier, {})
		var tier_name: String = upgrades.TIER_NAMES[tier]
		var cost: int = tier_data.get("cost", 0)
		tier_btn.text = "%s\n%d ⬡" % [tier_name, cost]
		tier_btn.custom_minimum_size = Vector2(80, 50)
		tier_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		var owned := upgrades.get_owned_tier(category)
		var equipped := upgrades.get_equipped_tier(category)

		if tier <= owned:
			tier_btn.add_theme_color_override("font_color", upgrades.TIER_COLORS[tier])
		if tier == equipped:
			tier_btn.add_theme_stylebox_override("normal", _make_highlight_style())

		tier_btn.pressed.connect(_on_upgrade_tier_pressed.bind(category, tier))
		tier_btn.tooltip_text = tier_data.get("description", "")
		tier_row.add_child(tier_btn)

	return panel

func _rebuild_performance_page() -> void:
	for cat in _upgrade_panels.keys():
		var old_panel = _upgrade_panels[cat]
		if is_instance_valid(old_panel):
			old_panel.queue_free()
	_upgrade_panels.clear()

	var perf_page: ScrollContainer = _pages[4] as ScrollContainer
	if perf_page == null:
		return
	var vbox := perf_page.get_child(0) as VBoxContainer
	if vbox == null:
		return

	for cat in ["engine", "brakes", "suspension", "nitro", "turbo", "tires"]:
		var panel := _build_upgrade_category_panel(cat)
		vbox.add_child(panel)
		_upgrade_panels[cat] = panel

	if upgrades and _spider_chart_container:
		upgrades.create_spider_chart(_spider_chart_container)

func _build_collection_page() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var vbox := VBoxContainer.new()
	scroll.add_child(vbox)

	vbox.add_child(_section_label("My Vehicles & Configs"))

	_collection_grid = GridContainer.new()
	_collection_grid.columns = 2
	vbox.add_child(_collection_grid)

	_collection_detail_panel = PanelContainer.new()
	_collection_detail_panel.custom_minimum_size = Vector2(0, 120)
	_collection_detail_panel.visible = false
	vbox.add_child(_collection_detail_panel)

	var load_btn := Button.new()
	load_btn.text = "↻ Refresh Collection"
	load_btn.pressed.connect(_load_collection)
	vbox.add_child(load_btn)

	return scroll

func _build_purchase_dialog() -> void:
	_purchase_dialog = AcceptDialog.new()
	_purchase_dialog.title = "Confirm Purchase"
	_purchase_dialog.dialog_text = "Are you sure?"
	_purchase_dialog.add_cancel_button("Cancel")
	_purchase_dialog.confirmed.connect(_on_purchase_confirmed)
	_root_control.add_child(_purchase_dialog)

# ---------------------------------------------------------------------------
# Tab switching
# ---------------------------------------------------------------------------
func _switch_tab(index: int) -> void:
	_tab_index = index
	for i in range(_pages.size()):
		_pages[i].visible = (i == index)
	for i in range(_tab_bar.get_child_count()):
		var btn := _tab_bar.get_child(i) as Button
		if btn:
			btn.add_theme_color_override("font_color",
				Color(0.3, 0.8, 1.0) if i == index else Color(0.8, 0.8, 0.8))

	if index == 5:
		_refresh_collection_grid()
	if index == 4 and upgrades:
		upgrades.refresh_spider_chart()

# ---------------------------------------------------------------------------
# Paint callbacks
# ---------------------------------------------------------------------------
func _on_paint_color_changed(color: Color) -> void:
	if _paint_preview_rect:
		_paint_preview_rect.color = color
	if customizer:
		var finish := customizer.ALL_FINISHES[_finish_option.selected if _finish_option else 0]
		customizer.set_paint_color(color, finish)
	_set_status("Paint color updated.")

func _on_secondary_color_changed(color: Color) -> void:
	if customizer:
		customizer.set_secondary_color(color)

func _on_finish_selected(index: int) -> void:
	if customizer == null:
		return
	var finish := customizer.ALL_FINISHES[index]
	var color: Color = customizer.current_config["paint_color"]
	customizer.set_paint_color(color, finish)
	_set_status("Finish: " + customizer.get_finish_display_name(finish))

func _on_preset_color(color: Color) -> void:
	if _paint_color_picker:
		_paint_color_picker.color = color
	if _paint_preview_rect:
		_paint_preview_rect.color = color
	if customizer:
		var finish := customizer.ALL_FINISHES[_finish_option.selected if _finish_option else 0]
		customizer.set_paint_color(color, finish)

# ---------------------------------------------------------------------------
# Decal callbacks
# ---------------------------------------------------------------------------
func _on_decal_selected(decal_id: int) -> void:
	if customizer == null:
		return
	var color: Color = _decal_color_picker.color if _decal_color_picker else Color.WHITE
	var opacity: float = _decal_opacity_slider.value if _decal_opacity_slider else 1.0
	customizer.set_decal(decal_id, color, opacity)
	_set_status("Decal: " + customizer.get_decal_name(decal_id))

func _on_decal_color_changed(color: Color) -> void:
	if customizer == null:
		return
	var id := customizer.current_config.get("decal_id", 0)
	var opacity := _decal_opacity_slider.value if _decal_opacity_slider else 1.0
	customizer.set_decal(id, color, opacity)

func _on_decal_opacity_changed(value: float) -> void:
	if customizer == null:
		return
	var id := customizer.current_config.get("decal_id", 0)
	var color := _decal_color_picker.color if _decal_color_picker else Color.WHITE
	customizer.set_decal(id, color, value)

# ---------------------------------------------------------------------------
# Wheel callbacks
# ---------------------------------------------------------------------------
func _on_wheel_selected(style_id: int) -> void:
	if customizer == null:
		return
	var color: Color = _wheel_color_picker.color if _wheel_color_picker else Color(0.8, 0.8, 0.8)
	customizer.set_wheel_style(style_id, color)
	_set_status("Wheels: " + customizer.get_wheel_name(style_id))

func _on_wheel_color_changed(color: Color) -> void:
	if customizer == null:
		return
	var id := customizer.current_config.get("wheel_id", 0)
	customizer.set_wheel_style(id, color)

# ---------------------------------------------------------------------------
# Body callbacks
# ---------------------------------------------------------------------------
func _on_spoiler_selected(index: int) -> void:
	if customizer:
		customizer.set_spoiler(index)
		_set_status("Spoiler: " + customizer.get_spoiler_name(index))

func _on_exhaust_selected(index: int) -> void:
	if customizer:
		customizer.set_exhaust(index)
		_set_status("Exhaust: " + customizer.get_exhaust_name(index))

func _on_underglow_toggled(state: bool) -> void:
	if customizer == null:
		return
	var color := _underglow_color_picker.color if _underglow_color_picker else Color(0, 1, 1)
	var intensity := _underglow_intensity_slider.value if _underglow_intensity_slider else 2.0
	customizer.set_underglow(state, color, intensity)
	_set_status("Underglow: " + ("ON" if state else "OFF"))

func _on_underglow_color_changed(color: Color) -> void:
	if customizer == null:
		return
	var enabled := _underglow_check.button_pressed if _underglow_check else false
	var intensity := _underglow_intensity_slider.value if _underglow_intensity_slider else 2.0
	customizer.set_underglow(enabled, color, intensity)

func _on_underglow_intensity_changed(value: float) -> void:
	if customizer == null:
		return
	var enabled := _underglow_check.button_pressed if _underglow_check else false
	var color := _underglow_color_picker.color if _underglow_color_picker else Color(0, 1, 1)
	customizer.set_underglow(enabled, color, value)

func _on_tint_opacity_changed(value: float) -> void:
	if customizer == null:
		return
	var color := _tint_color_picker.color if _tint_color_picker else Color.BLACK
	customizer.set_window_tint(value, color)

func _on_tint_color_changed(color: Color) -> void:
	if customizer == null:
		return
	var opacity := _window_tint_slider.value if _window_tint_slider else 0.0
	customizer.set_window_tint(opacity, color)

func _on_plate_submitted(text: String) -> void:
	if customizer:
		customizer.set_license_plate(text.strip_edges().to_upper())
		_set_status("Plate set: " + text.strip_edges().to_upper())

# ---------------------------------------------------------------------------
# Performance callbacks
# ---------------------------------------------------------------------------
func _on_upgrade_tier_pressed(category: String, tier: int) -> void:
	if upgrades == null:
		return
	var owned := upgrades.get_owned_tier(category)
	if tier <= owned:
		upgrades.equip_upgrade(category, tier)
		_set_status("Equipped: " + upgrades.UPGRADE_DATA[category].get("display_name", category) + " Tier " + upgrades.TIER_NAMES[tier])
		_rebuild_performance_page()
		return

	var cost := upgrades.get_upgrade_cost(category, tier)
	var desc := upgrades.get_upgrade_description(category, tier)
	_pending_purchase = {"category": category, "tier": tier, "cost": cost}
	_purchase_dialog.dialog_text = "Purchase %s %s for %d QUANT?\n\n%s" % [
		upgrades.UPGRADE_DATA[category].get("display_name", category),
		upgrades.TIER_NAMES[tier],
		cost,
		desc,
	]
	_purchase_dialog.popup_centered()

func _on_purchase_confirmed() -> void:
	if upgrades == null or _pending_purchase.is_empty():
		return
	var cat: String = _pending_purchase["category"]
	var tier: int = _pending_purchase["tier"]
	if upgrades.purchase_upgrade(cat, tier):
		_set_status("Purchased %s %s!" % [upgrades.UPGRADE_DATA[cat].get("display_name", cat), upgrades.TIER_NAMES[tier]])
		_rebuild_performance_page()
		_update_balance_label()
		emit_signal("config_purchase_confirmed", upgrades.equipped_tiers, _pending_purchase["cost"])
	else:
		_set_status("Purchase failed — insufficient QUANT tokens.")
	_pending_purchase = {}

# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------
func _on_toggle_comparison() -> void:
	_comparison_active = not _comparison_active
	_comparison_container.visible = _comparison_active
	if _comparison_active and customizer:
		_set_status("Comparison mode ON — drag slider to blend before/after.")
	else:
		_set_status("Comparison mode OFF.")

func _on_comparison_slider_changed(value: float) -> void:
	_comparison_value = value
	if customizer == null:
		return
	if value < 0.5:
		customizer.restore_before()
	else:
		customizer.apply_config(customizer.current_config)

func _on_show_before() -> void:
	if customizer:
		customizer.restore_before()
	if _comparison_slider:
		_comparison_slider.value = 0.0

func _on_show_after() -> void:
	if _comparison_slider:
		_comparison_slider.value = 1.0

# ---------------------------------------------------------------------------
# Undo / Redo / Randomise / Save
# ---------------------------------------------------------------------------
func _on_undo() -> void:
	if customizer and customizer.can_undo():
		customizer.undo()
		_sync_ui_from_config(customizer.current_config)
		_set_status("Undo applied.")
	else:
		_set_status("Nothing to undo.")

func _on_redo() -> void:
	if customizer and customizer.can_redo():
		customizer.redo()
		_sync_ui_from_config(customizer.current_config)
		_set_status("Redo applied.")
	else:
		_set_status("Nothing to redo.")

func _on_randomise() -> void:
	if customizer == null:
		return
	customizer.randomise_all()
	_sync_ui_from_config(customizer.current_config)
	_set_status("Random config applied!")

func _on_save_config() -> void:
	if customizer == null:
		return
	var dialog := AcceptDialog.new()
	dialog.title = "Save Configuration"
	var input := LineEdit.new()
	input.placeholder_text = "Config name..."
	dialog.add_child(input)
	dialog.confirmed.connect(func():
		var name := input.text.strip_edges()
		if name == "":
			name = "My Config"
		var id := customizer.save_config(name)
		_set_status("Config saved as: " + id)
		_refresh_collection_grid()
	)
	_root_control.add_child(dialog)
	dialog.popup_centered_ratio(0.4)

# ---------------------------------------------------------------------------
# Camera orbit
# ---------------------------------------------------------------------------
func _update_camera_transform() -> void:
	if _garage_camera == null:
		return
	var yaw_rad := deg_to_rad(_orbit_yaw)
	var pitch_rad := deg_to_rad(_orbit_pitch)
	var offset := Vector3(
		sin(yaw_rad) * cos(pitch_rad),
		sin(pitch_rad),
		cos(yaw_rad) * cos(pitch_rad)
	) * _orbit_distance
	_garage_camera.global_position = _orbit_target + offset
	_garage_camera.look_at(_orbit_target, Vector3.UP)

func _reset_camera() -> void:
	_orbit_yaw = 0.0
	_orbit_pitch = 15.0
	_orbit_distance = 6.0
	if _zoom_slider:
		_zoom_slider.value = _orbit_distance

func _on_auto_spin_toggled(state: bool) -> void:
	_auto_rotate = state

func _on_zoom_changed(value: float) -> void:
	_orbit_distance = value

func _input(event: InputEvent) -> void:
	if not _is_open:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_orbit_dragging = event.pressed
			_drag_last = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_orbit_distance = maxf(2.0, _orbit_distance - 0.4)
			if _zoom_slider:
				_zoom_slider.value = _orbit_distance
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_orbit_distance = minf(12.0, _orbit_distance + 0.4)
			if _zoom_slider:
				_zoom_slider.value = _orbit_distance
	elif event is InputEventMouseMotion and _orbit_dragging:
		var delta_v: Vector2 = event.position - _drag_last
		_orbit_yaw   -= delta_v.x * 0.4
		_orbit_pitch  = clampf(_orbit_pitch + delta_v.y * 0.3, -30.0, 60.0)
		_drag_last = event.position
		_auto_rotate = false
		if _spin_toggle:
			_spin_toggle.button_pressed = false

# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------
func _load_collection() -> void:
	_collection_vehicles.clear()
	if customizer == null:
		return
	customizer.load_persisted_configs()
	for id in customizer.get_saved_config_ids():
		var conf := customizer.get_config_preview(id)
		_collection_vehicles.append({"id": id, "config": conf})
	_refresh_collection_grid()

func _refresh_collection_grid() -> void:
	if _collection_grid == null:
		return
	for c in _collection_grid.get_children():
		c.queue_free()

	if customizer == null:
		return

	for i in range(_collection_vehicles.size()):
		var entry: Dictionary = _collection_vehicles[i]
		var card := _build_collection_card(entry, i)
		_collection_grid.add_child(card)

	if _collection_vehicles.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No saved configurations.\nCustomize and save your ride!"
		_collection_grid.add_child(empty_lbl)

func _build_collection_card(entry: Dictionary, index: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(160, 80)
	var vbox := VBoxContainer.new()
	card.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = entry["id"].replace("_", " ").capitalize()
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)

	var color_rect := ColorRect.new()
	color_rect.custom_minimum_size = Vector2(0, 20)
	var conf: Dictionary = entry.get("config", {})
	color_rect.color = conf.get("paint_color", Color(0.5, 0.5, 0.5))
	vbox.add_child(color_rect)

	var row := HBoxContainer.new()
	vbox.add_child(row)

	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_btn.pressed.connect(_on_load_collection_entry.bind(entry["id"]))
	row.add_child(load_btn)

	var del_btn := Button.new()
	del_btn.text = "🗑"
	del_btn.pressed.connect(_on_delete_collection_entry.bind(entry["id"]))
	row.add_child(del_btn)

	return card

func _on_load_collection_entry(config_id: String) -> void:
	if customizer:
		customizer.load_config(config_id)
		_sync_ui_from_config(customizer.current_config)
		_set_status("Loaded config: " + config_id)
		_switch_tab(0)

func _on_delete_collection_entry(config_id: String) -> void:
	if customizer:
		customizer.delete_config(config_id)
		_load_collection()
		_set_status("Deleted: " + config_id)

# ---------------------------------------------------------------------------
# Sync UI from config
# ---------------------------------------------------------------------------
func _sync_ui_from_config(conf: Dictionary) -> void:
	if _paint_color_picker:
		_paint_color_picker.color = conf.get("paint_color", Color(0.1, 0.5, 1.0))
	if _paint_preview_rect:
		_paint_preview_rect.color = conf.get("paint_color", Color(0.1, 0.5, 1.0))
	if _secondary_color_picker:
		_secondary_color_picker.color = conf.get("secondary_color", Color(0.05, 0.05, 0.05))
	if _finish_option and customizer:
		var finish: String = conf.get("paint_finish", "metallic")
		var idx := customizer.ALL_FINISHES.find(finish)
		if idx >= 0:
			_finish_option.select(idx)
	if _decal_color_picker:
		_decal_color_picker.color = conf.get("decal_color", Color.WHITE)
	if _decal_opacity_slider:
		_decal_opacity_slider.value = conf.get("decal_opacity", 1.0)
	if _wheel_color_picker:
		_wheel_color_picker.color = conf.get("wheel_color", Color(0.8, 0.8, 0.8))
	if _underglow_check:
		_underglow_check.button_pressed = conf.get("underglow_enabled", false)
	if _underglow_color_picker:
		_underglow_color_picker.color = conf.get("underglow_color", Color(0, 1, 1))
	if _underglow_intensity_slider:
		_underglow_intensity_slider.value = conf.get("underglow_intensity", 2.0)
	if _window_tint_slider:
		_window_tint_slider.value = conf.get("tint_opacity", 0.0)
	if _plate_input:
		_plate_input.text = conf.get("license_plate", "QUANT01")

# ---------------------------------------------------------------------------
# Status / balance helpers
# ---------------------------------------------------------------------------
func _set_status(msg: String) -> void:
	if _status_bar:
		_status_bar.text = msg

func set_token_balance(balance: int) -> void:
	if _balance_label:
		_balance_label.text = "⬡ %d QUANT" % balance
	if _token_balance_label:
		_token_balance_label.text = "Balance: %d QUANT" % balance
	if upgrades:
		upgrades.set_player_balance(balance)

func _update_balance_label() -> void:
	if upgrades == null:
		return
	set_token_balance(upgrades.player_token_balance)

# ---------------------------------------------------------------------------
# Helper constructors
# ---------------------------------------------------------------------------
func _section_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = "— " + text + " —"
	lbl.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	return lbl

func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl

func _make_highlight_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.5, 0.8, 0.4)
	style.border_color = Color(0.3, 0.7, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	return style
