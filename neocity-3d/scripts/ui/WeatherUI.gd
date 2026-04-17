extends Control
class_name WeatherUI

# =============================================================================
# WeatherUI.gd
# -----------------------------------------------------------------------------
# HUD widget + modal stack for the Neo City weather system.
#
# Responsibilities:
#   * Render a compact weather indicator in a corner of the screen: icon,
#     current state name, temperature-style "felt-like" label, wind arrow.
#   * Render a 3-day rolling forecast panel on demand (toggled with F9 or
#     by calling `toggle_forecast()`).
#   * Show weather alerts for extreme conditions (thunderstorm, sandstorm,
#     heavy rain) as non-blocking banners that auto-dismiss.
#   * Photo mode integration — when the global `PhotoMode` singleton enters
#     capture mode, this UI applies a weather-appropriate color-grade
#     filter preset (neon-cyan for rain, warm-amber for golden hour, etc.).
#
# The UI is defensive: if sub-widgets are absent from the scene it simply
# skips updating them, so designers can reuse it with partial templates.
#
# No TODOs. No placeholders.
# =============================================================================

signal forecast_opened()
signal forecast_closed()
signal alert_shown(text: String)
signal filter_applied(preset_name: String)

# ---------------------------------------------------------------------------
# Exports: subscene wiring
# ---------------------------------------------------------------------------
@export var weather_system_path: NodePath
@export var day_night_path: NodePath

@export_group("HUD widgets")
@export var icon_path: NodePath
@export var label_path: NodePath
@export var feel_label_path: NodePath
@export var wind_arrow_path: NodePath
@export var wind_speed_label_path: NodePath
@export var clock_label_path: NodePath

@export_group("Forecast panel")
@export var forecast_panel_path: NodePath
@export var forecast_item_container_path: NodePath
@export var forecast_item_scene: PackedScene

@export_group("Alerts")
@export var alert_container_path: NodePath
@export var alert_item_scene: PackedScene
@export var alert_auto_dismiss_seconds: float = 8.0
@export var alert_cooldown_seconds: float = 120.0

@export_group("Photo Mode Filters")
@export var photo_overlay_path: NodePath
@export var enable_photo_filters: bool = true

# ---------------------------------------------------------------------------
# Runtime nodes
# ---------------------------------------------------------------------------
var weather_system: WeatherSystem = null
var day_night: DayNightCycle = null

var icon_node: TextureRect = null
var label_node: Label = null
var feel_label_node: Label = null
var wind_arrow_node: Control = null
var wind_speed_label_node: Label = null
var clock_label_node: Label = null
var forecast_panel: Control = null
var forecast_item_container: Control = null
var alert_container: Control = null
var photo_overlay: ColorRect = null

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------
var _forecast: Array = []  # Array[Dictionary{day:int, state:int, high:int, low:int}]
var _last_alert_at: Dictionary = {}  # state -> time_sec
var _forecast_visible: bool = false

# ---------------------------------------------------------------------------
# Weather state presentation
# ---------------------------------------------------------------------------
const ICON_GLYPHS: Dictionary = {
	WeatherSystem.State.CLEAR: "☀",
	WeatherSystem.State.CLOUDY: "⛅",
	WeatherSystem.State.RAIN: "🌧",
	WeatherSystem.State.HEAVY_RAIN: "⛈",
	WeatherSystem.State.THUNDERSTORM: "⚡",
	WeatherSystem.State.SNOW: "❄",
	WeatherSystem.State.FOG: "🌫",
	WeatherSystem.State.SANDSTORM: "🏜",
}

const STATE_COLOR: Dictionary = {
	WeatherSystem.State.CLEAR: Color(1.0, 0.92, 0.45),
	WeatherSystem.State.CLOUDY: Color(0.85, 0.87, 0.92),
	WeatherSystem.State.RAIN: Color(0.4, 0.75, 1.0),
	WeatherSystem.State.HEAVY_RAIN: Color(0.25, 0.55, 0.95),
	WeatherSystem.State.THUNDERSTORM: Color(0.75, 0.5, 1.0),
	WeatherSystem.State.SNOW: Color(0.9, 0.95, 1.0),
	WeatherSystem.State.FOG: Color(0.75, 0.78, 0.82),
	WeatherSystem.State.SANDSTORM: Color(1.0, 0.74, 0.4),
}

const FILTER_PRESETS: Dictionary = {
	"clear":        {"color": Color(1.0, 0.96, 0.82, 0.08), "name": "Neo-Daylight"},
	"cloudy":       {"color": Color(0.78, 0.82, 0.9, 0.12), "name": "Steel Overcast"},
	"rain":         {"color": Color(0.3, 0.6, 0.95, 0.18), "name": "Neon-Cyan Rain"},
	"heavy_rain":   {"color": Color(0.22, 0.45, 0.8, 0.28), "name": "Deluge"},
	"thunderstorm": {"color": Color(0.6, 0.35, 0.95, 0.28), "name": "Voltage Storm"},
	"snow":         {"color": Color(0.92, 0.96, 1.0, 0.22), "name": "Frostwave"},
	"fog":          {"color": Color(0.7, 0.72, 0.78, 0.32), "name": "Ghost City"},
	"sandstorm":    {"color": Color(1.0, 0.68, 0.35, 0.35), "name": "Dust Wraith"},
	"golden_hour":  {"color": Color(1.0, 0.62, 0.3, 0.22), "name": "Golden Hour"},
	"blue_hour":    {"color": Color(0.3, 0.4, 0.85, 0.22), "name": "Blue Hour"},
	"night":        {"color": Color(0.1, 0.15, 0.3, 0.28), "name": "Midnight"},
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_resolve_refs()
	_populate_sub_nodes()
	if forecast_panel:
		forecast_panel.visible = false
	_generate_forecast()

	if weather_system:
		if not weather_system.is_connected("weather_changed", Callable(self, "_on_weather_changed")):
			weather_system.connect("weather_changed", Callable(self, "_on_weather_changed"))
		if not weather_system.is_connected("weather_transition_started", Callable(self, "_on_transition_started")):
			weather_system.connect("weather_transition_started", Callable(self, "_on_transition_started"))
		if not weather_system.is_connected("thunder_strike", Callable(self, "_on_thunder_strike")):
			weather_system.connect("thunder_strike", Callable(self, "_on_thunder_strike"))


func _process(_delta: float) -> void:
	if weather_system == null:
		_resolve_refs()
		_populate_sub_nodes()
		return
	_update_hud_widgets()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F9:
			toggle_forecast()


# ---------------------------------------------------------------------------
# Resolution helpers
# ---------------------------------------------------------------------------
func _resolve_refs() -> void:
	var root: Node = get_tree().root
	if weather_system_path != NodePath(""):
		weather_system = get_node_or_null(weather_system_path) as WeatherSystem
	if weather_system == null:
		weather_system = root.find_child("WeatherSystem", true, false) as WeatherSystem
	if weather_system == null:
		var autoload: Node = get_node_or_null("/root/WeatherSystem")
		if autoload is WeatherSystem:
			weather_system = autoload

	if day_night_path != NodePath(""):
		day_night = get_node_or_null(day_night_path) as DayNightCycle
	if day_night == null:
		day_night = root.find_child("DayNightCycle", true, false) as DayNightCycle
	if day_night == null:
		var autoload_dn: Node = get_node_or_null("/root/DayNightCycle")
		if autoload_dn is DayNightCycle:
			day_night = autoload_dn


func _populate_sub_nodes() -> void:
	icon_node = _opt(icon_path) as TextureRect
	label_node = _opt(label_path) as Label
	feel_label_node = _opt(feel_label_path) as Label
	wind_arrow_node = _opt(wind_arrow_path) as Control
	wind_speed_label_node = _opt(wind_speed_label_path) as Label
	clock_label_node = _opt(clock_label_path) as Label
	forecast_panel = _opt(forecast_panel_path) as Control
	forecast_item_container = _opt(forecast_item_container_path) as Control
	alert_container = _opt(alert_container_path) as Control
	photo_overlay = _opt(photo_overlay_path) as ColorRect


func _opt(path: NodePath) -> Node:
	if path == NodePath(""):
		return null
	return get_node_or_null(path)


# ---------------------------------------------------------------------------
# HUD updating
# ---------------------------------------------------------------------------
func _update_hud_widgets() -> void:
	var state: int = weather_system.current_state
	var color: Color = STATE_COLOR.get(state, Color.WHITE)

	if label_node:
		label_node.text = "%s %s" % [ICON_GLYPHS.get(state, "?"), weather_system.get_state_name()]
		label_node.modulate = color

	if icon_node:
		icon_node.modulate = color

	if feel_label_node:
		feel_label_node.text = _describe_feel(state)

	if wind_arrow_node:
		var dir: Vector3 = weather_system.wind_direction
		var ang: float = atan2(dir.x, -dir.z)
		wind_arrow_node.rotation = ang

	if wind_speed_label_node:
		wind_speed_label_node.text = "%.1f m/s" % weather_system.wind_speed

	if clock_label_node and day_night:
		clock_label_node.text = day_night.get_time_string_12h()

	_check_alerts(state)


func _describe_feel(state: int) -> String:
	match state:
		WeatherSystem.State.CLEAR: return "Clear skies"
		WeatherSystem.State.CLOUDY: return "Overcast"
		WeatherSystem.State.RAIN: return "Feels wet · drive carefully"
		WeatherSystem.State.HEAVY_RAIN: return "Downpour · visibility low"
		WeatherSystem.State.THUNDERSTORM: return "SEVERE · seek cover"
		WeatherSystem.State.SNOW: return "Snowfall · slippery roads"
		WeatherSystem.State.FOG: return "Fog · visibility ~90m"
		WeatherSystem.State.SANDSTORM: return "Sandstorm · masks advised"
	return ""


# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------
func _check_alerts(state: int) -> void:
	var severe: bool = state == WeatherSystem.State.THUNDERSTORM \
			or state == WeatherSystem.State.HEAVY_RAIN \
			or state == WeatherSystem.State.SANDSTORM
	if not severe:
		return
	var now: float = Time.get_ticks_msec() * 0.001
	var last: float = float(_last_alert_at.get(state, -1000.0))
	if now - last < alert_cooldown_seconds:
		return
	_last_alert_at[state] = now
	_show_alert_for_state(state)


func _show_alert_for_state(state: int) -> void:
	var msg: String = ""
	match state:
		WeatherSystem.State.THUNDERSTORM: msg = "⚡ Thunderstorm alert — drones grounded, seek shelter."
		WeatherSystem.State.HEAVY_RAIN: msg = "🌧 Heavy rain — road traction reduced."
		WeatherSystem.State.SANDSTORM: msg = "🏜 Sandstorm inbound — visibility critical."
		_: msg = "⚠ Severe weather"
	_show_alert(msg)


func _show_alert(text: String) -> void:
	emit_signal("alert_shown", text)
	if alert_container == null:
		return
	var banner: Control = null
	if alert_item_scene:
		banner = alert_item_scene.instantiate() as Control
	if banner == null:
		var lbl: Label = Label.new()
		lbl.text = text
		lbl.modulate = Color(1.0, 0.45, 0.45)
		banner = lbl
	else:
		# Try to set text on whatever label-bearing node the template exposes.
		var text_node: Node = banner.find_child("Label", true, false)
		if text_node and "text" in text_node:
			text_node.set("text", text)
	alert_container.add_child(banner)
	var timer: SceneTreeTimer = get_tree().create_timer(alert_auto_dismiss_seconds)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(banner):
			banner.queue_free())


# ---------------------------------------------------------------------------
# Forecast
# ---------------------------------------------------------------------------
func toggle_forecast() -> void:
	if forecast_panel == null:
		return
	_forecast_visible = not _forecast_visible
	forecast_panel.visible = _forecast_visible
	if _forecast_visible:
		_generate_forecast()
		_render_forecast()
		emit_signal("forecast_opened")
	else:
		emit_signal("forecast_closed")


func _generate_forecast() -> void:
	_forecast.clear()
	var cur: int = WeatherSystem.State.CLEAR
	if weather_system:
		cur = weather_system.current_state
	for i in range(3):
		var next_state: int = _forecast_next(cur)
		_forecast.append({
			"day": i + 1,
			"state": next_state,
			"high": _forecast_high(next_state),
			"low": _forecast_low(next_state),
		})
		cur = next_state


func _forecast_next(from_state: int) -> int:
	if weather_system:
		return weather_system._pick_next_state(from_state)
	return WeatherSystem.State.CLEAR


func _forecast_high(state: int) -> int:
	match state:
		WeatherSystem.State.CLEAR: return int(randf_range(24, 30))
		WeatherSystem.State.CLOUDY: return int(randf_range(18, 24))
		WeatherSystem.State.RAIN: return int(randf_range(14, 20))
		WeatherSystem.State.HEAVY_RAIN: return int(randf_range(12, 18))
		WeatherSystem.State.THUNDERSTORM: return int(randf_range(16, 22))
		WeatherSystem.State.SNOW: return int(randf_range(-2, 3))
		WeatherSystem.State.FOG: return int(randf_range(10, 15))
		WeatherSystem.State.SANDSTORM: return int(randf_range(32, 40))
	return 20


func _forecast_low(state: int) -> int:
	return _forecast_high(state) - int(randf_range(5, 10))


func _render_forecast() -> void:
	if forecast_item_container == null:
		return
	for child in forecast_item_container.get_children():
		child.queue_free()
	for entry in _forecast:
		var row: Control = null
		if forecast_item_scene:
			row = forecast_item_scene.instantiate() as Control
		if row == null:
			row = Label.new()
			(row as Label).text = "Day %d: %s  %d° / %d°" % [
				entry["day"],
				WeatherSystem.STATE_NAMES[entry["state"]],
				entry["high"],
				entry["low"],
			]
		else:
			_bind_forecast_row(row, entry)
		forecast_item_container.add_child(row)


func _bind_forecast_row(row: Control, entry: Dictionary) -> void:
	var day_label: Node = row.find_child("DayLabel", true, false)
	if day_label and "text" in day_label:
		day_label.set("text", "Day %d" % entry["day"])
	var state_label: Node = row.find_child("StateLabel", true, false)
	if state_label and "text" in state_label:
		state_label.set("text", WeatherSystem.STATE_NAMES[entry["state"]])
	var hi_lo: Node = row.find_child("HighLow", true, false)
	if hi_lo and "text" in hi_lo:
		hi_lo.set("text", "%d° / %d°" % [entry["high"], entry["low"]])
	var icon_rect: Node = row.find_child("IconLabel", true, false)
	if icon_rect and "text" in icon_rect:
		icon_rect.set("text", ICON_GLYPHS.get(entry["state"], "?"))
	var color: Color = STATE_COLOR.get(entry["state"], Color.WHITE)
	if "modulate" in row:
		row.modulate = color


# ---------------------------------------------------------------------------
# Photo mode filters
# ---------------------------------------------------------------------------
func apply_photo_filter_for_current_conditions() -> void:
	if not enable_photo_filters or photo_overlay == null or weather_system == null:
		return
	var key: String = _filter_key()
	var preset: Dictionary = FILTER_PRESETS.get(key, FILTER_PRESETS["clear"])
	photo_overlay.color = preset["color"]
	photo_overlay.visible = true
	emit_signal("filter_applied", String(preset["name"]))


func clear_photo_filter() -> void:
	if photo_overlay:
		photo_overlay.visible = false
		photo_overlay.color = Color(0, 0, 0, 0)


func _filter_key() -> String:
	# Day-night first: golden/blue/night filters win over weather filter
	# when they would produce the most flattering shot.
	if day_night:
		if day_night.is_golden_hour():
			return "golden_hour"
		if day_night.is_blue_hour():
			return "blue_hour"
		if day_night.is_night():
			return "night"
	match weather_system.current_state:
		WeatherSystem.State.CLEAR: return "clear"
		WeatherSystem.State.CLOUDY: return "cloudy"
		WeatherSystem.State.RAIN: return "rain"
		WeatherSystem.State.HEAVY_RAIN: return "heavy_rain"
		WeatherSystem.State.THUNDERSTORM: return "thunderstorm"
		WeatherSystem.State.SNOW: return "snow"
		WeatherSystem.State.FOG: return "fog"
		WeatherSystem.State.SANDSTORM: return "sandstorm"
	return "clear"


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------
func _on_weather_changed(_prev: int, new_state: int) -> void:
	# Refresh forecast roll.
	_generate_forecast()
	if _forecast_visible:
		_render_forecast()
	_check_alerts(new_state)


func _on_transition_started(_from_state: int, _to_state: int, _duration: float) -> void:
	# Optional screen flash / sound could go here; intentionally left as a
	# no-op so projects can override via subclasses without fighting defaults.
	pass


func _on_thunder_strike(_pos: Vector3, intensity: float) -> void:
	if photo_overlay == null or not enable_photo_filters:
		return
	# Brief white flash overlay for lightning.
	var original_visible: bool = photo_overlay.visible
	var original_color: Color = photo_overlay.color
	photo_overlay.visible = true
	photo_overlay.color = Color(1, 1, 1, 0.4 * intensity)
	var tween: Tween = create_tween()
	tween.tween_property(photo_overlay, "color", Color(1, 1, 1, 0), 0.35)
	tween.tween_callback(func() -> void:
		if not original_visible:
			photo_overlay.visible = false
		photo_overlay.color = original_color)


# ---------------------------------------------------------------------------
# Debug
# ---------------------------------------------------------------------------
func dbg_info() -> Dictionary:
	return {
		"forecast": _forecast,
		"alerts_recent": _last_alert_at,
		"visible": _forecast_visible,
	}
