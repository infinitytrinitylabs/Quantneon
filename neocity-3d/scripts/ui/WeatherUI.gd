## WeatherUI — HUD overlay for dynamic weather and time display
## Shows current weather, 3-day forecast, weather alerts, and a photo mode
## with weather-appropriate filter presets.
extends CanvasLayer

# ── Signals ───────────────────────────────────────────────────────────────────

signal photo_mode_activated()
signal photo_mode_deactivated()
signal filter_changed(filter_name: String)
signal alert_dismissed(alert_id: int)
signal forecast_expanded()
signal forecast_collapsed()

# ── Exports ───────────────────────────────────────────────────────────────────

@export var show_weather_hud: bool = true
@export var show_forecast: bool = true
@export var show_alerts: bool = true
@export var show_time: bool = true
@export var forecast_days: int = 3
@export var alert_display_duration: float = 8.0
@export var alert_fade_duration: float = 1.5
@export var hud_corner: int = 1  # 0=TL 1=TR 2=BL 3=BR
@export var hud_margin: int = 20
@export var enable_photo_mode: bool = true
@export var animate_transitions: bool = true

# ── Color Theme ───────────────────────────────────────────────────────────────

const COLOR_BG          := Color(0.05, 0.05, 0.12, 0.78)
const COLOR_BORDER      := Color(0.25, 0.82, 1.0, 0.6)
const COLOR_TEXT        := Color(0.9, 0.95, 1.0, 1.0)
const COLOR_SUBTEXT     := Color(0.65, 0.75, 0.88, 0.85)
const COLOR_ALERT_INFO  := Color(0.3, 0.8, 1.0, 1.0)
const COLOR_ALERT_WARN  := Color(1.0, 0.75, 0.1, 1.0)
const COLOR_ALERT_DANGER := Color(1.0, 0.25, 0.2, 1.0)
const COLOR_NEON_CYAN   := Color(0.0, 1.0, 0.95, 1.0)
const COLOR_NEON_PINK   := Color(1.0, 0.1, 0.7, 1.0)
const COLOR_NEON_PURPLE := Color(0.7, 0.2, 1.0, 1.0)

# ── Internal State ─────────────────────────────────────────────────────────────

var weather_system: Node = null
var day_night_cycle: Node = null
var environment_effects: Node = null

var _weather_panel: PanelContainer = null
var _weather_icon_label: Label = null
var _weather_name_label: Label = null
var _temperature_label: Label = null
var _wind_label: Label = null
var _humidity_label: Label = null
var _visibility_label: Label = null
var _time_label: Label = null
var _time_period_label: Label = null
var _moon_phase_label: Label = null

var _forecast_panel: PanelContainer = null
var _forecast_container: HBoxContainer = null
var _forecast_expanded: bool = false

var _alert_container: VBoxContainer = null
var _active_alerts: Array = []  # Array of { id, label, timer, tween }
var _alert_id_counter: int = 0

var _photo_mode_panel: PanelContainer = null
var _photo_mode_active: bool = false
var _current_filter: String = "None"
var _filter_buttons: Dictionary = {}

var _extreme_alert_bar: ColorRect = null
var _extreme_alert_label: Label = null
var _extreme_alert_tween: Tween = null

var _update_timer: float = 0.0
var _update_interval: float = 0.5

# ── Photo Mode Filter Definitions ─────────────────────────────────────────────

const PHOTO_FILTERS: Dictionary = {
	"None": {
		"brightness": 1.0, "contrast": 1.0, "saturation": 1.0,
		"tint": Color(1, 1, 1), "vignette": 0.0, "description": "No filter",
	},
	"Stormy": {
		"brightness": 0.75, "contrast": 1.35, "saturation": 0.5,
		"tint": Color(0.8, 0.85, 1.0), "vignette": 0.4, "description": "Desaturated, dramatic",
	},
	"Golden Hour": {
		"brightness": 1.15, "contrast": 1.1, "saturation": 1.45,
		"tint": Color(1.0, 0.88, 0.65), "vignette": 0.25, "description": "Warm golden tones",
	},
	"Neon Night": {
		"brightness": 0.85, "contrast": 1.5, "saturation": 1.9,
		"tint": Color(0.85, 0.9, 1.05), "vignette": 0.5, "description": "Vivid cyberpunk neon",
	},
	"Blizzard": {
		"brightness": 1.2, "contrast": 0.85, "saturation": 0.3,
		"tint": Color(0.92, 0.95, 1.0), "vignette": 0.15, "description": "Cold, washed-out",
	},
	"Sandstorm": {
		"brightness": 1.0, "contrast": 1.2, "saturation": 0.7,
		"tint": Color(1.0, 0.88, 0.65), "vignette": 0.35, "description": "Warm dusty haze",
	},
	"Foggy City": {
		"brightness": 0.9, "contrast": 0.9, "saturation": 0.65,
		"tint": Color(0.9, 0.92, 0.96), "vignette": 0.3, "description": "Moody atmospheric",
	},
	"Sakura Rain": {
		"brightness": 1.1, "contrast": 1.0, "saturation": 1.2,
		"tint": Color(1.0, 0.92, 0.95), "vignette": 0.2, "description": "Soft pink rainy day",
	},
	"Cyber Noir": {
		"brightness": 0.7, "contrast": 1.6, "saturation": 0.4,
		"tint": Color(0.88, 0.9, 1.0), "vignette": 0.6, "description": "High-contrast monochrome",
	},
}

# ── Weather-Filter Auto-Map ────────────────────────────────────────────────────
# Maps WeatherState int → recommended photo filter

const AUTO_FILTER_MAP: Dictionary = {
	0: "None",        # CLEAR
	1: "None",        # CLOUDY
	2: "Sakura Rain", # RAIN
	3: "Stormy",      # HEAVY_RAIN
	4: "Stormy",      # THUNDERSTORM
	5: "Blizzard",    # SNOW
	6: "Foggy City",  # FOG
	7: "Sandstorm",   # SANDSTORM
}

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_locate_systems()
	_build_ui()
	_connect_signals()
	_update_all()

func _process(delta: float) -> void:
	_update_timer += delta
	if _update_timer >= _update_interval:
		_update_timer = 0.0
		_update_all()
	_process_alerts(delta)

# ── System Discovery ───────────────────────────────────────────────────────────

func _locate_systems() -> void:
	weather_system     = get_tree().root.find_child("WeatherSystem", true, false)
	day_night_cycle    = get_tree().root.find_child("DayNightCycle", true, false)
	environment_effects = get_tree().root.find_child("EnvironmentEffects", true, false)

# ── UI Construction ────────────────────────────────────────────────────────────

func _build_ui() -> void:
	layer = 10
	_build_weather_panel()
	_build_forecast_panel()
	_build_alert_container()
	_build_extreme_alert_bar()
	if enable_photo_mode:
		_build_photo_mode_panel()

func _build_weather_panel() -> void:
	if not show_weather_hud:
		return
	_weather_panel = PanelContainer.new()
	_weather_panel.name = "WeatherPanel"
	_style_panel(_weather_panel, COLOR_BG, COLOR_BORDER)
	_weather_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_weather_panel.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	add_child(_weather_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_weather_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	# Time row
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 8)
	vbox.add_child(time_row)

	_time_label = _make_label("08:00 AM", 20, COLOR_NEON_CYAN, true)
	time_row.add_child(_time_label)

	_time_period_label = _make_label("Daytime", 13, COLOR_SUBTEXT)
	_time_period_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	time_row.add_child(_time_period_label)

	var separator := HSeparator.new()
	separator.add_theme_color_override("color", COLOR_BORDER)
	vbox.add_child(separator)

	# Weather icon + name row
	var weather_row := HBoxContainer.new()
	weather_row.add_theme_constant_override("separation", 8)
	vbox.add_child(weather_row)

	_weather_icon_label = _make_label("☀", 28, COLOR_TEXT)
	weather_row.add_child(_weather_icon_label)

	_weather_name_label = _make_label("Clear", 16, COLOR_TEXT, true)
	_weather_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	weather_row.add_child(_weather_name_label)

	# Stat grid
	var stat_grid := GridContainer.new()
	stat_grid.columns = 2
	stat_grid.add_theme_constant_override("h_separation", 16)
	stat_grid.add_theme_constant_override("v_separation", 2)
	vbox.add_child(stat_grid)

	stat_grid.add_child(_make_label("🌡 Temp:", 12, COLOR_SUBTEXT))
	_temperature_label = _make_label("22°C", 12, COLOR_TEXT)
	stat_grid.add_child(_temperature_label)

	stat_grid.add_child(_make_label("💨 Wind:", 12, COLOR_SUBTEXT))
	_wind_label = _make_label("5 km/h", 12, COLOR_TEXT)
	stat_grid.add_child(_wind_label)

	stat_grid.add_child(_make_label("💧 Humidity:", 12, COLOR_SUBTEXT))
	_humidity_label = _make_label("30%", 12, COLOR_TEXT)
	stat_grid.add_child(_humidity_label)

	stat_grid.add_child(_make_label("👁 Visibility:", 12, COLOR_SUBTEXT))
	_visibility_label = _make_label("100%", 12, COLOR_TEXT)
	stat_grid.add_child(_visibility_label)

	# Moon phase
	_moon_phase_label = _make_label("🌕 Full Moon", 11, COLOR_SUBTEXT)
	vbox.add_child(_moon_phase_label)

	# Photo mode button
	if enable_photo_mode:
		var photo_btn := Button.new()
		photo_btn.text = "📷 Photo Mode"
		photo_btn.add_theme_font_size_override("font_size", 12)
		photo_btn.add_theme_color_override("font_color", COLOR_NEON_PINK)
		photo_btn.pressed.connect(_toggle_photo_mode)
		vbox.add_child(photo_btn)

	_position_panel(_weather_panel)

func _build_forecast_panel() -> void:
	if not show_forecast:
		return
	_forecast_panel = PanelContainer.new()
	_forecast_panel.name = "ForecastPanel"
	_style_panel(_forecast_panel, COLOR_BG, COLOR_BORDER)
	add_child(_forecast_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_forecast_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	vbox.add_child(header_row)

	var forecast_title := _make_label("3-Day Forecast", 14, COLOR_NEON_CYAN, true)
	header_row.add_child(forecast_title)

	var expand_btn := Button.new()
	expand_btn.text = "▼"
	expand_btn.add_theme_font_size_override("font_size", 11)
	expand_btn.pressed.connect(_toggle_forecast_expand)
	header_row.add_child(expand_btn)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", COLOR_BORDER)
	vbox.add_child(sep)

	_forecast_container = HBoxContainer.new()
	_forecast_container.add_theme_constant_override("separation", 16)
	vbox.add_child(_forecast_container)

	_position_panel_below(_forecast_panel, _weather_panel if _weather_panel else null)

func _build_alert_container() -> void:
	if not show_alerts:
		return
	_alert_container = VBoxContainer.new()
	_alert_container.name = "AlertContainer"
	_alert_container.add_theme_constant_override("separation", 4)
	add_child(_alert_container)
	_alert_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_alert_container.position = Vector2(0, 80)
	_alert_container.size = Vector2(get_viewport().size.x, 200)

func _build_extreme_alert_bar() -> void:
	_extreme_alert_bar = ColorRect.new()
	_extreme_alert_bar.name = "ExtremeAlertBar"
	_extreme_alert_bar.color = Color(1.0, 0.15, 0.1, 0.85)
	_extreme_alert_bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_extreme_alert_bar.size = Vector2(get_viewport().size.x, 36)
	_extreme_alert_bar.visible = false
	add_child(_extreme_alert_bar)

	_extreme_alert_label = Label.new()
	_extreme_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_extreme_alert_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_extreme_alert_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_extreme_alert_label.add_theme_font_size_override("font_size", 14)
	_extreme_alert_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_extreme_alert_bar.add_child(_extreme_alert_label)

func _build_photo_mode_panel() -> void:
	_photo_mode_panel = PanelContainer.new()
	_photo_mode_panel.name = "PhotoModePanel"
	_style_panel(_photo_mode_panel, Color(0.0, 0.0, 0.08, 0.92), COLOR_NEON_PINK)
	_photo_mode_panel.visible = false
	_photo_mode_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_photo_mode_panel.position = Vector2(
		get_viewport().size.x * 0.5 - 400,
		get_viewport().size.y - 160
	)
	add_child(_photo_mode_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	_photo_mode_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 12)
	vbox.add_child(title_row)

	var title_lbl := _make_label("📷 PHOTO MODE", 16, COLOR_NEON_PINK, true)
	title_row.add_child(title_lbl)

	var auto_lbl := _make_label("Auto:", 12, COLOR_SUBTEXT)
	title_row.add_child(auto_lbl)

	var auto_btn := Button.new()
	auto_btn.text = "✨ Weather Filter"
	auto_btn.add_theme_font_size_override("font_size", 12)
	auto_btn.pressed.connect(_apply_auto_filter)
	title_row.add_child(auto_btn)

	var close_btn := Button.new()
	close_btn.text = "✕ Close"
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.pressed.connect(_toggle_photo_mode)
	title_row.add_child(close_btn)

	var filter_grid := GridContainer.new()
	filter_grid.columns = 5
	filter_grid.add_theme_constant_override("h_separation", 8)
	filter_grid.add_theme_constant_override("v_separation", 6)
	vbox.add_child(filter_grid)

	for filter_name in PHOTO_FILTERS.keys():
		var btn := Button.new()
		btn.text = filter_name
		btn.add_theme_font_size_override("font_size", 11)
		var filter_data: Dictionary = PHOTO_FILTERS[filter_name]
		btn.tooltip_text = filter_data["description"]
		btn.pressed.connect(_apply_filter.bind(filter_name))
		_filter_buttons[filter_name] = btn
		filter_grid.add_child(btn)

# ── UI Update ──────────────────────────────────────────────────────────────────

func _update_all() -> void:
	_update_weather_display()
	_update_time_display()
	_update_forecast_display()

func _update_weather_display() -> void:
	if not weather_system:
		return
	if _weather_icon_label and weather_system.has_method("get_weather_icon"):
		_weather_icon_label.text = weather_system.get_weather_icon()
	if _weather_name_label and weather_system.has_method("get_weather_name"):
		_weather_name_label.text = weather_system.get_weather_name()
	if _temperature_label and weather_system.has_method("get_temperature"):
		var temp: float = weather_system.get_temperature()
		_temperature_label.text = "%.0f°C" % temp
		if temp <= 0:
			_temperature_label.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
		elif temp >= 35:
			_temperature_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.1))
		else:
			_temperature_label.add_theme_color_override("font_color", COLOR_TEXT)
	if _wind_label and weather_system.has_method("get_wind_strength"):
		var wind: float = weather_system.get_wind_strength()
		_wind_label.text = "%.0f km/h" % (wind * 100.0)
		var wind_color := COLOR_TEXT
		if wind > 0.6:
			wind_color = COLOR_ALERT_WARN
		elif wind > 0.8:
			wind_color = COLOR_ALERT_DANGER
		_wind_label.add_theme_color_override("font_color", wind_color)
	if _humidity_label and weather_system.has_method("get_humidity"):
		_humidity_label.text = "%.0f%%" % (weather_system.get_humidity() * 100.0)
	if _visibility_label and weather_system.has_method("get_visibility"):
		var vis: float = weather_system.get_visibility()
		_visibility_label.text = "%.0f%%" % (vis * 100.0)
		var vis_color := COLOR_TEXT
		if vis < 0.4:
			vis_color = COLOR_ALERT_WARN
		elif vis < 0.2:
			vis_color = COLOR_ALERT_DANGER
		_visibility_label.add_theme_color_override("font_color", vis_color)

func _update_time_display() -> void:
	if not day_night_cycle:
		return
	if _time_label and day_night_cycle.has_method("get_hour_string"):
		_time_label.text = day_night_cycle.get_hour_string()
	if _time_period_label and day_night_cycle.has_method("get_status_string"):
		if day_night_cycle.has_method("is_golden_hour") and day_night_cycle.is_golden_hour():
			_time_period_label.text = "✨ Golden Hour"
			_time_period_label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.3))
		elif day_night_cycle.has_method("is_nighttime") and day_night_cycle.is_nighttime():
			_time_period_label.text = "🌙 Night"
			_time_period_label.add_theme_color_override("font_color", Color(0.7, 0.7, 1.0))
		elif day_night_cycle.has_method("is_sunrise") and day_night_cycle.is_sunrise():
			_time_period_label.text = "🌅 Sunrise"
			_time_period_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
		elif day_night_cycle.has_method("is_sunset") and day_night_cycle.is_sunset():
			_time_period_label.text = "🌇 Sunset"
			_time_period_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.3))
		else:
			_time_period_label.text = "☀ Daytime"
			_time_period_label.add_theme_color_override("font_color", COLOR_SUBTEXT)
	if _moon_phase_label and day_night_cycle.has_method("get_moon_phase_name"):
		_moon_phase_label.text = day_night_cycle.get_moon_phase_name()
		_moon_phase_label.visible = day_night_cycle.is_nighttime() if day_night_cycle.has_method("is_nighttime") else false

func _update_forecast_display() -> void:
	if not _forecast_container or not weather_system:
		return
	if not weather_system.has_method("get_forecast"):
		return
	var forecast: Array = weather_system.get_forecast(forecast_days)
	for child in _forecast_container.get_children():
		child.queue_free()
	var day_data: Dictionary = {}
	for entry in forecast:
		var hour_offset: int = entry.get("hour_offset", 0)
		var day_idx := hour_offset / 24
		if not day_data.has(day_idx):
			day_data[day_idx] = []
		day_data[day_idx].append(entry)

	for day_idx in range(forecast_days):
		if not day_data.has(day_idx):
			continue
		var entries: Array = day_data[day_idx]
		var day_panel := _build_forecast_day_card(day_idx, entries)
		_forecast_container.add_child(day_panel)

func _build_forecast_day_card(day_offset: int, entries: Array) -> PanelContainer:
	var card := PanelContainer.new()
	_style_panel(card, Color(0.04, 0.04, 0.10, 0.85), Color(0.2, 0.6, 0.9, 0.5))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	card.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	var day_name := "Today" if day_offset == 0 else ("Tomorrow" if day_offset == 1 else "Day +%d" % (day_offset + 1))
	vbox.add_child(_make_label(day_name, 13, COLOR_NEON_CYAN, true))

	var icons_seen: Dictionary = {}
	for entry in entries:
		var icon: String = entry.get("icon", "?")
		if not icons_seen.has(icon):
			icons_seen[icon] = entry.get("name", "")
	var icon_row := HBoxContainer.new()
	for icon in icons_seen.keys():
		var lbl := _make_label(icon, 20, COLOR_TEXT)
		icon_row.add_child(lbl)
	vbox.add_child(icon_row)

	if not entries.is_empty():
		var primary_entry: Dictionary = entries[entries.size() / 2]
		vbox.add_child(_make_label(primary_entry.get("name", ""), 11, COLOR_SUBTEXT))

	if _forecast_expanded and entries.size() > 1:
		for i in range(0, entries.size(), 2):
			var e: Dictionary = entries[i]
			var hour_off: int = e.get("hour_offset", 0)
			var h_in_day := hour_off % 24
			var row_lbl := _make_label("+%dh: %s %s" % [hour_off, e.get("icon", ""), e.get("name", "")], 10, COLOR_SUBTEXT)
			vbox.add_child(row_lbl)

	return card

# ── Alert System ──────────────────────────────────────────────────────────────

func show_alert(message: String, severity: int = 0) -> int:
	if not show_alerts or not _alert_container:
		return -1
	var alert_id := _alert_id_counter
	_alert_id_counter += 1

	if severity == 2:
		_show_extreme_alert_bar(message)

	var alert_panel := PanelContainer.new()
	var alert_color: Color
	match severity:
		0: alert_color = Color(0.1, 0.35, 0.55, 0.88)
		1: alert_color = Color(0.45, 0.32, 0.0, 0.88)
		2: alert_color = Color(0.55, 0.05, 0.05, 0.92)
		_: alert_color = Color(0.1, 0.35, 0.55, 0.88)
	_style_panel(alert_panel, alert_color, COLOR_ALERT_DANGER if severity == 2 else (COLOR_ALERT_WARN if severity == 1 else COLOR_ALERT_INFO))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	alert_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var text_color: Color
	match severity:
		0: text_color = COLOR_ALERT_INFO
		1: text_color = COLOR_ALERT_WARN
		2: text_color = COLOR_ALERT_DANGER
		_: text_color = COLOR_TEXT
	var msg_label := _make_label(message, 13, text_color)
	msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	msg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(msg_label)

	var dismiss_btn := Button.new()
	dismiss_btn.text = "✕"
	dismiss_btn.add_theme_font_size_override("font_size", 12)
	dismiss_btn.pressed.connect(_dismiss_alert.bind(alert_id))
	row.add_child(dismiss_btn)

	_alert_container.add_child(alert_panel)
	alert_panel.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(alert_panel, "modulate:a", 1.0, 0.4)

	_active_alerts.append({
		"id": alert_id,
		"panel": alert_panel,
		"timer": alert_display_duration,
		"fading": false,
	})
	return alert_id

func _process_alerts(delta: float) -> void:
	for i in range(_active_alerts.size() - 1, -1, -1):
		var alert_data: Dictionary = _active_alerts[i]
		alert_data["timer"] -= delta
		if alert_data["timer"] <= 0.0 and not alert_data["fading"]:
			alert_data["fading"] = true
			var panel: PanelContainer = alert_data["panel"]
			if is_instance_valid(panel):
				var tween := create_tween()
				tween.tween_property(panel, "modulate:a", 0.0, alert_fade_duration)
				tween.tween_callback(panel.queue_free)
			_active_alerts.remove_at(i)

func _dismiss_alert(alert_id: int) -> void:
	for i in range(_active_alerts.size() - 1, -1, -1):
		var alert_data: Dictionary = _active_alerts[i]
		if alert_data["id"] == alert_id:
			var panel: PanelContainer = alert_data["panel"]
			if is_instance_valid(panel):
				var tween := create_tween()
				tween.tween_property(panel, "modulate:a", 0.0, 0.3)
				tween.tween_callback(panel.queue_free)
			_active_alerts.remove_at(i)
			alert_dismissed.emit(alert_id)
			break

func _show_extreme_alert_bar(message: String) -> void:
	if not _extreme_alert_bar:
		return
	_extreme_alert_label.text = "⚠ " + message + " ⚠"
	_extreme_alert_bar.visible = true
	if _extreme_alert_tween and _extreme_alert_tween.is_valid():
		_extreme_alert_tween.kill()
	_extreme_alert_tween = create_tween()
	_extreme_alert_tween.tween_property(_extreme_alert_bar, "modulate:a", 1.0, 0.3)
	_extreme_alert_tween.tween_delay(10.0)
	_extreme_alert_tween.tween_property(_extreme_alert_bar, "modulate:a", 0.0, 1.5)
	_extreme_alert_tween.tween_callback(func(): _extreme_alert_bar.visible = false)

# ── Photo Mode ─────────────────────────────────────────────────────────────────

func _toggle_photo_mode() -> void:
	_photo_mode_active = not _photo_mode_active
	if _photo_mode_panel:
		_photo_mode_panel.visible = _photo_mode_active
	if _photo_mode_active:
		photo_mode_activated.emit()
	else:
		_apply_filter("None")
		photo_mode_deactivated.emit()

func _apply_filter(filter_name: String) -> void:
	if not PHOTO_FILTERS.has(filter_name):
		return
	_current_filter = filter_name
	_highlight_active_filter_button(filter_name)
	filter_changed.emit(filter_name)
	_apply_filter_to_environment(filter_name)

func _apply_auto_filter() -> void:
	var weather_state := 0
	if weather_system and weather_system.has_method("get"):
		weather_state = int(weather_system.current_state) if "current_state" in weather_system else 0
	var filter_name: String = AUTO_FILTER_MAP.get(weather_state, "None")
	_apply_filter(filter_name)

func _highlight_active_filter_button(active_name: String) -> void:
	for name_key in _filter_buttons.keys():
		var btn: Button = _filter_buttons[name_key]
		if not is_instance_valid(btn):
			continue
		if name_key == active_name:
			btn.add_theme_color_override("font_color", COLOR_NEON_PINK)
			btn.add_theme_stylebox_override("normal", _make_stylebox_flat(Color(0.3, 0.05, 0.3, 0.8), COLOR_NEON_PINK))
		else:
			btn.remove_theme_color_override("font_color")
			btn.remove_theme_stylebox_override("normal")

func _apply_filter_to_environment(filter_name: String) -> void:
	var world_env := get_tree().root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if not world_env or not world_env.environment:
		return
	var env := world_env.environment
	if not PHOTO_FILTERS.has(filter_name):
		return
	var f: Dictionary = PHOTO_FILTERS[filter_name]
	env.adjustment_enabled = filter_name != "None"
	if env.adjustment_enabled:
		env.adjustment_brightness  = f["brightness"]
		env.adjustment_contrast    = f["contrast"]
		env.adjustment_saturation  = f["saturation"]
	else:
		env.adjustment_brightness  = 1.0
		env.adjustment_contrast    = 1.0
		env.adjustment_saturation  = 1.0

func get_current_filter() -> String:
	return _current_filter

func is_photo_mode_active() -> bool:
	return _photo_mode_active

# ── Signal Connections ─────────────────────────────────────────────────────────

func _connect_signals() -> void:
	if weather_system:
		if weather_system.has_signal("weather_alert"):
			weather_system.connect("weather_alert", _on_weather_alert)
		if weather_system.has_signal("weather_changed"):
			weather_system.connect("weather_changed", _on_weather_state_changed)
	if day_night_cycle:
		if day_night_cycle.has_signal("sunrise"):
			day_night_cycle.connect("sunrise", _on_sunrise)
		if day_night_cycle.has_signal("sunset"):
			day_night_cycle.connect("sunset", _on_sunset)
		if day_night_cycle.has_signal("midnight"):
			day_night_cycle.connect("midnight", _on_midnight)

func _on_weather_alert(message: String, severity: int) -> void:
	show_alert(message, severity)

func _on_weather_state_changed(_old: int, _new: int) -> void:
	_update_weather_display()

func _on_sunrise() -> void:
	show_alert("🌅 Sunrise — A new day begins in Neo City.", 0)

func _on_sunset() -> void:
	show_alert("🌇 Sunset — The neon lights are coming on.", 0)

func _on_midnight() -> void:
	show_alert("🌃 Midnight — Neo City never sleeps.", 0)

# ── Forecast Toggle ────────────────────────────────────────────────────────────

func _toggle_forecast_expand() -> void:
	_forecast_expanded = not _forecast_expanded
	if _forecast_expanded:
		forecast_expanded.emit()
	else:
		forecast_collapsed.emit()
	_update_forecast_display()

# ── UI Helpers ─────────────────────────────────────────────────────────────────

func _make_label(text: String, font_size: int, color: Color, bold: bool = false) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl

func _style_panel(panel: PanelContainer, bg: Color, border: Color) -> void:
	var sb := _make_stylebox_flat(bg, border)
	panel.add_theme_stylebox_override("panel", sb)

func _make_stylebox_flat(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.border_width_left   = 1
	sb.border_width_right  = 1
	sb.border_width_top    = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left     = 6
	sb.corner_radius_top_right    = 6
	sb.corner_radius_bottom_left  = 6
	sb.corner_radius_bottom_right = 6
	return sb

func _position_panel(panel: Control) -> void:
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(
		get_viewport().size.x - panel.size.x - hud_margin,
		hud_margin + 40
	)

func _position_panel_below(panel: Control, above: Control) -> void:
	if above == null:
		panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		panel.position = Vector2(get_viewport().size.x - panel.size.x - hud_margin, hud_margin + 40)
		return
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(
		get_viewport().size.x - panel.size.x - hud_margin,
		above.position.y + above.size.y + 8
	)

# ── Visibility Toggles ─────────────────────────────────────────────────────────

func set_hud_visible(visible_flag: bool) -> void:
	if _weather_panel:
		_weather_panel.visible = visible_flag
	if _forecast_panel:
		_forecast_panel.visible = visible_flag

func set_alerts_visible(visible_flag: bool) -> void:
	if _alert_container:
		_alert_container.visible = visible_flag

## Returns a summary string for accessibility / screen readers.
func get_accessibility_summary() -> String:
	var parts := []
	if weather_system and weather_system.has_method("get_status_string"):
		parts.append(weather_system.get_status_string())
	if day_night_cycle and day_night_cycle.has_method("get_status_string"):
		parts.append(day_night_cycle.get_status_string())
	return "\n".join(parts)
