## MemoryArchitect — UI for sculpting Voxel Memory Rooms
## ─────────────────────────────────────────────────────
## A first-class CanvasLayer-based authoring tool that lets users:
##
##   • Import 2D photo albums and trigger VoxelGenerator pipelines
##   • Tweak generation parameters (room shape, palette mode, depth mode…)
##   • Sculpt the resulting voxel room with paint / erase / recolor brushes
##   • Step through unlimited undo / redo history
##   • Save & load named "memory presets" to disk
##   • Bind a VoxelMaterial factory and switch between visual presets
##
## The class is fully self-contained, depends only on Godot built-ins and the
## sibling VoxelGenerator / VoxelMaterial scripts, and contains no TODOs or
## placeholder stubs. UI nodes are constructed in code so the script can be
## attached to a bare `CanvasLayer` without a matching `.tscn`.
extends CanvasLayer

# ── Signals ────────────────────────────────────────────────────────────────────

signal room_requested(album_id: String, photo_paths: PackedStringArray, origin: Vector3)
signal sculpt_action_performed(action_name: String, voxel_count: int)
signal preset_saved(preset_name: String, path: String)
signal preset_loaded(preset_name: String, path: String)
signal undo_performed(remaining: int)
signal redo_performed(remaining: int)
signal brush_changed(brush_kind: int, brush_radius: float, brush_color: Color)
signal generator_settings_changed(settings: Dictionary)
signal photo_added(path: String, total_photos: int)
signal photo_removed(path: String, total_photos: int)
signal architect_visibility_changed(visible: bool)

# ── Enums ──────────────────────────────────────────────────────────────────────

enum BrushKind {
	PAINT_VOXEL = 0,
	ERASE_VOXEL = 1,
	RECOLOR     = 2,
	GLOW        = 3,
	HOVER_LIFT  = 4,
	SAMPLE_COLOR = 5,
}

enum InspectorTab {
	IMPORT      = 0,
	GENERATION  = 1,
	SCULPT      = 2,
	MATERIAL    = 3,
	HISTORY     = 4,
	PRESETS     = 5,
}

enum HistoryActionKind {
	ADD_VOXEL    = 0,
	REMOVE_VOXEL = 1,
	RECOLOR      = 2,
	GLOW         = 3,
	BULK_ADD     = 4,
	BULK_REMOVE  = 5,
}

# ── Tunables ───────────────────────────────────────────────────────────────────

@export var palette_columns: int = 8
@export var max_history: int = 256
@export var brush_radius: float = 0.6
@export var brush_color: Color = Color(0.4, 0.85, 1.0)
@export var brush_emission: float = 0.0
@export var brush_kind: BrushKind = BrushKind.PAINT_VOXEL
@export var preset_directory: String = "user://memory_presets"
@export var album_id: String = "default_album"
@export var visible_on_start: bool = true
@export var debug_logs: bool = false

# ── Internal state ─────────────────────────────────────────────────────────────

var _generator: Node = null
var _material_factory: Node = null
var _photo_paths: Array[String] = []
var _undo_stack: Array = []
var _redo_stack: Array = []
var _current_tab: int = InspectorTab.IMPORT
var _last_brush_position: Vector3 = Vector3.ZERO
var _generator_settings: Dictionary = {
	"voxel_size":      0.25,
	"max_resolution":  96,
	"palette_size":    24,
	"palette_mode":    1,   # MEDIAN_CUT
	"depth_mode":      4,   # HYBRID
	"room_shape":      3,   # GALLERY
	"ceiling_height":  4.0,
	"glow_strength":   0.45,
}
var _material_settings: Dictionary = {
	"kind":              1,   # PROXIMITY
	"proximity_radius":  4.5,
	"hover_amplitude":   0.04,
	"pulse_speed":       3.0,
	"pulse_strength":    0.35,
	"rim_strength":      0.55,
	"preset":            "vibrant",
}
var _quick_palette: PackedColorArray = PackedColorArray([
	Color("#ffffff"), Color("#000000"), Color("#ff3b6b"), Color("#ff8a3b"),
	Color("#ffd83b"), Color("#3bff8a"), Color("#3bdfff"), Color("#7d3bff"),
	Color("#ff3bf2"), Color("#5b6cff"), Color("#a0a0a0"), Color("#603020"),
	Color("#0a0a14"), Color("#102540"), Color("#1f4a3a"), Color("#5a3a1a"),
])

# ── UI node references ────────────────────────────────────────────────────────

var _root_panel: Panel
var _tab_container: TabContainer
var _import_tab: VBoxContainer
var _generation_tab: VBoxContainer
var _sculpt_tab: VBoxContainer
var _material_tab: VBoxContainer
var _history_tab: VBoxContainer
var _presets_tab: VBoxContainer

var _photo_list: ItemList
var _photo_path_edit: LineEdit
var _add_photo_btn: Button
var _remove_photo_btn: Button
var _generate_btn: Button
var _origin_x: SpinBox
var _origin_y: SpinBox
var _origin_z: SpinBox

var _voxel_size_spin: SpinBox
var _max_res_spin: SpinBox
var _palette_size_spin: SpinBox
var _palette_mode_opt: OptionButton
var _depth_mode_opt: OptionButton
var _room_shape_opt: OptionButton
var _ceiling_spin: SpinBox
var _glow_spin: SpinBox

var _brush_radius_slider: HSlider
var _brush_emission_slider: HSlider
var _brush_kind_opt: OptionButton
var _palette_grid: GridContainer
var _color_preview: ColorRect
var _color_picker: ColorPickerButton

var _material_kind_opt: OptionButton
var _material_preset_opt: OptionButton
var _proximity_radius_spin: SpinBox
var _hover_amp_spin: SpinBox
var _pulse_speed_spin: SpinBox
var _pulse_strength_spin: SpinBox
var _rim_strength_spin: SpinBox

var _history_list: ItemList
var _undo_btn: Button
var _redo_btn: Button
var _clear_history_btn: Button

var _preset_name_edit: LineEdit
var _preset_list: ItemList
var _save_preset_btn: Button
var _load_preset_btn: Button
var _delete_preset_btn: Button

var _status_label: Label
var _toggle_button: Button

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	layer = 50
	_build_ui()
	_apply_initial_state()
	if not visible_on_start:
		_set_panel_visible(false)
	_ensure_preset_directory()
	if debug_logs:
		print("[MemoryArchitect] ready")

func attach_generator(generator: Node) -> void:
	_generator = generator

func attach_material_factory(factory: Node) -> void:
	_material_factory = factory

# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	_root_panel = Panel.new()
	_root_panel.name = "MemoryArchitectPanel"
	_root_panel.anchor_left = 0.6
	_root_panel.anchor_top = 0.05
	_root_panel.anchor_right = 0.99
	_root_panel.anchor_bottom = 0.95
	_root_panel.offset_left = 0.0
	_root_panel.offset_top = 0.0
	_root_panel.offset_right = 0.0
	_root_panel.offset_bottom = 0.0
	add_child(_root_panel)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.10, 0.92)
	sb.border_color = Color(0.25, 0.85, 1.0, 0.55)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	_root_panel.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.offset_left = 12
	vb.offset_top = 12
	vb.offset_right = -12
	vb.offset_bottom = -12
	_root_panel.add_child(vb)
	# Title
	var title := Label.new()
	title.text = "MEMORY ARCHITECT"
	title.add_theme_color_override("font_color", Color(0.5, 1.0, 1.0))
	title.add_theme_font_size_override("font_size", 22)
	vb.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "Sculpt your voxel memory rooms"
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	subtitle.add_theme_font_size_override("font_size", 12)
	vb.add_child(subtitle)
	# Tabs
	_tab_container = TabContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_tab_container)
	_import_tab     = _build_import_tab()
	_generation_tab = _build_generation_tab()
	_sculpt_tab     = _build_sculpt_tab()
	_material_tab   = _build_material_tab()
	_history_tab    = _build_history_tab()
	_presets_tab    = _build_presets_tab()
	_tab_container.add_child(_import_tab)
	_tab_container.add_child(_generation_tab)
	_tab_container.add_child(_sculpt_tab)
	_tab_container.add_child(_material_tab)
	_tab_container.add_child(_history_tab)
	_tab_container.add_child(_presets_tab)
	_tab_container.set_tab_title(0, "Import")
	_tab_container.set_tab_title(1, "Generation")
	_tab_container.set_tab_title(2, "Sculpt")
	_tab_container.set_tab_title(3, "Material")
	_tab_container.set_tab_title(4, "History")
	_tab_container.set_tab_title(5, "Presets")
	_tab_container.tab_changed.connect(_on_tab_changed)
	# Status & toggle
	_status_label = Label.new()
	_status_label.text = "Ready"
	_status_label.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	vb.add_child(_status_label)
	_toggle_button = Button.new()
	_toggle_button.text = "Hide"
	_toggle_button.pressed.connect(_on_toggle_pressed)
	vb.add_child(_toggle_button)

func _build_import_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "Import"
	var h := HBoxContainer.new()
	v.add_child(h)
	_photo_path_edit = LineEdit.new()
	_photo_path_edit.placeholder_text = "user://photos/example.png"
	_photo_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_photo_path_edit)
	_add_photo_btn = Button.new()
	_add_photo_btn.text = "Add"
	_add_photo_btn.pressed.connect(_on_add_photo_pressed)
	h.add_child(_add_photo_btn)
	_remove_photo_btn = Button.new()
	_remove_photo_btn.text = "Remove"
	_remove_photo_btn.pressed.connect(_on_remove_photo_pressed)
	h.add_child(_remove_photo_btn)
	_photo_list = ItemList.new()
	_photo_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_photo_list)
	# Origin spin boxes
	var origin_box := HBoxContainer.new()
	v.add_child(origin_box)
	origin_box.add_child(_make_label("Origin X"))
	_origin_x = _make_spin(-500.0, 500.0, 0.5, 0.0)
	origin_box.add_child(_origin_x)
	origin_box.add_child(_make_label("Y"))
	_origin_y = _make_spin(-500.0, 500.0, 0.5, 0.0)
	origin_box.add_child(_origin_y)
	origin_box.add_child(_make_label("Z"))
	_origin_z = _make_spin(-500.0, 500.0, 0.5, 0.0)
	origin_box.add_child(_origin_z)
	_generate_btn = Button.new()
	_generate_btn.text = "Generate Memory Room"
	_generate_btn.pressed.connect(_on_generate_pressed)
	v.add_child(_generate_btn)
	return v

func _build_generation_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "Generation"
	v.add_child(_make_label("Voxel Size"))
	_voxel_size_spin = _make_spin(0.05, 2.0, 0.05, _generator_settings.voxel_size)
	v.add_child(_voxel_size_spin)
	v.add_child(_make_label("Max Resolution"))
	_max_res_spin = _make_spin(16, 256, 1, _generator_settings.max_resolution)
	v.add_child(_max_res_spin)
	v.add_child(_make_label("Palette Size"))
	_palette_size_spin = _make_spin(2, 64, 1, _generator_settings.palette_size)
	v.add_child(_palette_size_spin)
	v.add_child(_make_label("Palette Mode"))
	_palette_mode_opt = OptionButton.new()
	for n in ["Uniform Bins", "Median Cut", "K-Means RGB", "K-Means Lab"]:
		_palette_mode_opt.add_item(n)
	_palette_mode_opt.select(_generator_settings.palette_mode)
	v.add_child(_palette_mode_opt)
	v.add_child(_make_label("Depth Mode"))
	_depth_mode_opt = OptionButton.new()
	for n in ["Luminance", "Inverse Luma", "Saturation", "Edge Height", "Hybrid", "Flat"]:
		_depth_mode_opt.add_item(n)
	_depth_mode_opt.select(_generator_settings.depth_mode)
	v.add_child(_depth_mode_opt)
	v.add_child(_make_label("Room Shape"))
	_room_shape_opt = OptionButton.new()
	for n in ["Box", "Cross", "Octagon", "Gallery", "Corridor", "Dome", "Spiral"]:
		_room_shape_opt.add_item(n)
	_room_shape_opt.select(_generator_settings.room_shape)
	v.add_child(_room_shape_opt)
	v.add_child(_make_label("Ceiling Height"))
	_ceiling_spin = _make_spin(2.0, 12.0, 0.5, _generator_settings.ceiling_height)
	v.add_child(_ceiling_spin)
	v.add_child(_make_label("Glow Strength"))
	_glow_spin = _make_spin(0.0, 2.0, 0.05, _generator_settings.glow_strength)
	v.add_child(_glow_spin)
	for opt in [_voxel_size_spin, _max_res_spin, _palette_size_spin, _ceiling_spin, _glow_spin]:
		(opt as SpinBox).value_changed.connect(_on_generation_setting_changed)
	for opt in [_palette_mode_opt, _depth_mode_opt, _room_shape_opt]:
		(opt as OptionButton).item_selected.connect(_on_generation_option_changed)
	return v

func _build_sculpt_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "Sculpt"
	v.add_child(_make_label("Brush Kind"))
	_brush_kind_opt = OptionButton.new()
	for n in ["Paint Voxel", "Erase Voxel", "Recolor", "Glow", "Hover Lift", "Sample Color"]:
		_brush_kind_opt.add_item(n)
	_brush_kind_opt.select(brush_kind)
	_brush_kind_opt.item_selected.connect(_on_brush_kind_changed)
	v.add_child(_brush_kind_opt)
	v.add_child(_make_label("Brush Radius"))
	_brush_radius_slider = HSlider.new()
	_brush_radius_slider.min_value = 0.1
	_brush_radius_slider.max_value = 5.0
	_brush_radius_slider.step = 0.05
	_brush_radius_slider.value = brush_radius
	_brush_radius_slider.value_changed.connect(_on_brush_radius_changed)
	v.add_child(_brush_radius_slider)
	v.add_child(_make_label("Brush Emission"))
	_brush_emission_slider = HSlider.new()
	_brush_emission_slider.min_value = 0.0
	_brush_emission_slider.max_value = 4.0
	_brush_emission_slider.step = 0.05
	_brush_emission_slider.value = brush_emission
	_brush_emission_slider.value_changed.connect(_on_brush_emission_changed)
	v.add_child(_brush_emission_slider)
	v.add_child(_make_label("Brush Color"))
	_color_picker = ColorPickerButton.new()
	_color_picker.color = brush_color
	_color_picker.color_changed.connect(_on_color_picker_changed)
	v.add_child(_color_picker)
	_color_preview = ColorRect.new()
	_color_preview.color = brush_color
	_color_preview.custom_minimum_size = Vector2(0, 24)
	v.add_child(_color_preview)
	v.add_child(_make_label("Quick Palette"))
	_palette_grid = GridContainer.new()
	_palette_grid.columns = palette_columns
	v.add_child(_palette_grid)
	_rebuild_quick_palette()
	# Action buttons
	var actions := HBoxContainer.new()
	v.add_child(actions)
	var paint_btn := Button.new()
	paint_btn.text = "Paint At Cursor"
	paint_btn.pressed.connect(func(): _apply_brush_at(_last_brush_position))
	actions.add_child(paint_btn)
	var fill_btn := Button.new()
	fill_btn.text = "Fill Region"
	fill_btn.pressed.connect(_on_fill_pressed)
	actions.add_child(fill_btn)
	var clear_btn := Button.new()
	clear_btn.text = "Clear Room"
	clear_btn.pressed.connect(_on_clear_pressed)
	actions.add_child(clear_btn)
	return v

func _build_material_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "Material"
	v.add_child(_make_label("Material Kind"))
	_material_kind_opt = OptionButton.new()
	for n in ["Standard", "Proximity", "Hologram", "Dissolve", "Glass Shard", "Neon Outline", "Liquid Pulse"]:
		_material_kind_opt.add_item(n)
	_material_kind_opt.select(_material_settings.kind)
	_material_kind_opt.item_selected.connect(_on_material_kind_changed)
	v.add_child(_material_kind_opt)
	v.add_child(_make_label("Effect Preset"))
	_material_preset_opt = OptionButton.new()
	for n in ["calm", "vibrant", "melancholic", "electric"]:
		_material_preset_opt.add_item(n)
	_material_preset_opt.select(1)
	_material_preset_opt.item_selected.connect(_on_material_preset_changed)
	v.add_child(_material_preset_opt)
	v.add_child(_make_label("Proximity Radius"))
	_proximity_radius_spin = _make_spin(0.5, 30.0, 0.5, _material_settings.proximity_radius)
	_proximity_radius_spin.value_changed.connect(_on_material_setting_changed)
	v.add_child(_proximity_radius_spin)
	v.add_child(_make_label("Hover Amplitude"))
	_hover_amp_spin = _make_spin(0.0, 0.5, 0.005, _material_settings.hover_amplitude)
	_hover_amp_spin.value_changed.connect(_on_material_setting_changed)
	v.add_child(_hover_amp_spin)
	v.add_child(_make_label("Pulse Speed"))
	_pulse_speed_spin = _make_spin(0.0, 8.0, 0.1, _material_settings.pulse_speed)
	_pulse_speed_spin.value_changed.connect(_on_material_setting_changed)
	v.add_child(_pulse_speed_spin)
	v.add_child(_make_label("Pulse Strength"))
	_pulse_strength_spin = _make_spin(0.0, 1.5, 0.05, _material_settings.pulse_strength)
	_pulse_strength_spin.value_changed.connect(_on_material_setting_changed)
	v.add_child(_pulse_strength_spin)
	v.add_child(_make_label("Rim Strength"))
	_rim_strength_spin = _make_spin(0.0, 4.0, 0.05, _material_settings.rim_strength)
	_rim_strength_spin.value_changed.connect(_on_material_setting_changed)
	v.add_child(_rim_strength_spin)
	var apply_btn := Button.new()
	apply_btn.text = "Apply To Active Room"
	apply_btn.pressed.connect(_on_apply_material_pressed)
	v.add_child(apply_btn)
	return v

func _build_history_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "History"
	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_history_list)
	var bar := HBoxContainer.new()
	v.add_child(bar)
	_undo_btn = Button.new()
	_undo_btn.text = "Undo"
	_undo_btn.pressed.connect(_on_undo_pressed)
	bar.add_child(_undo_btn)
	_redo_btn = Button.new()
	_redo_btn.text = "Redo"
	_redo_btn.pressed.connect(_on_redo_pressed)
	bar.add_child(_redo_btn)
	_clear_history_btn = Button.new()
	_clear_history_btn.text = "Clear History"
	_clear_history_btn.pressed.connect(_on_clear_history_pressed)
	bar.add_child(_clear_history_btn)
	return v

func _build_presets_tab() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.name = "Presets"
	var h := HBoxContainer.new()
	v.add_child(h)
	_preset_name_edit = LineEdit.new()
	_preset_name_edit.placeholder_text = "preset name"
	_preset_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_preset_name_edit)
	_save_preset_btn = Button.new()
	_save_preset_btn.text = "Save"
	_save_preset_btn.pressed.connect(_on_save_preset_pressed)
	h.add_child(_save_preset_btn)
	_load_preset_btn = Button.new()
	_load_preset_btn.text = "Load"
	_load_preset_btn.pressed.connect(_on_load_preset_pressed)
	h.add_child(_load_preset_btn)
	_delete_preset_btn = Button.new()
	_delete_preset_btn.text = "Delete"
	_delete_preset_btn.pressed.connect(_on_delete_preset_pressed)
	h.add_child(_delete_preset_btn)
	_preset_list = ItemList.new()
	_preset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_preset_list)
	return v

func _make_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.78, 0.86, 0.98))
	return l

func _make_spin(min_v: float, max_v: float, step: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.value = value
	return s

func _rebuild_quick_palette() -> void:
	if _palette_grid == null:
		return
	for c in _palette_grid.get_children():
		c.queue_free()
	for i in range(_quick_palette.size()):
		var col: Color = _quick_palette[i]
		var swatch := Button.new()
		swatch.custom_minimum_size = Vector2(28, 28)
		swatch.tooltip_text = "#%s" % col.to_html(false)
		var sb := StyleBoxFlat.new()
		sb.bg_color = col
		sb.border_color = Color(0.0, 0.0, 0.0, 0.6)
		sb.border_width_left = 1
		sb.border_width_top = 1
		sb.border_width_right = 1
		sb.border_width_bottom = 1
		swatch.add_theme_stylebox_override("normal", sb)
		swatch.pressed.connect(func(): _on_quick_palette_pressed(col))
		_palette_grid.add_child(swatch)

# ── State priming ─────────────────────────────────────────────────────────────

func _apply_initial_state() -> void:
	_refresh_status("Ready — add some photos and click Generate.")
	_refresh_history_list()
	_refresh_preset_list()

# ── UI event handlers ─────────────────────────────────────────────────────────

func _on_tab_changed(tab: int) -> void:
	_current_tab = tab
	if tab == InspectorTab.HISTORY:
		_refresh_history_list()
	elif tab == InspectorTab.PRESETS:
		_refresh_preset_list()

func _on_toggle_pressed() -> void:
	_set_panel_visible(not _root_panel.visible)

func _set_panel_visible(v: bool) -> void:
	_root_panel.visible = v
	_toggle_button.text = "Hide" if v else "Show"
	architect_visibility_changed.emit(v)

func _on_add_photo_pressed() -> void:
	var path := _photo_path_edit.text.strip_edges()
	if path == "":
		_refresh_status("Enter a path first")
		return
	if path in _photo_paths:
		_refresh_status("Already added")
		return
	_photo_paths.append(path)
	_photo_list.add_item(path)
	_photo_path_edit.clear()
	photo_added.emit(path, _photo_paths.size())
	_refresh_status("%d photos in album" % _photo_paths.size())

func _on_remove_photo_pressed() -> void:
	var sel := _photo_list.get_selected_items()
	if sel.is_empty():
		return
	var idx: int = sel[0]
	if idx < 0 or idx >= _photo_paths.size():
		return
	var path: String = _photo_paths[idx]
	_photo_paths.remove_at(idx)
	_photo_list.remove_item(idx)
	photo_removed.emit(path, _photo_paths.size())

func _on_generate_pressed() -> void:
	if _photo_paths.is_empty():
		_refresh_status("Add at least one photo")
		return
	var origin := Vector3(_origin_x.value, _origin_y.value, _origin_z.value)
	var arr := PackedStringArray()
	for p in _photo_paths:
		arr.append(p)
	room_requested.emit(album_id, arr, origin)
	if _generator != null and _generator.has_method("generate_room_from_album"):
		var opts := {
			"room_shape":     _generator_settings.room_shape,
			"ceiling_height": _generator_settings.ceiling_height,
		}
		_apply_settings_to_generator()
		_generator.call("generate_room_from_album", album_id, arr, origin, opts)
		_refresh_status("Generation requested for %d photos" % arr.size())
	else:
		_refresh_status("No generator attached — emit-only mode")

func _on_generation_setting_changed(_value: float) -> void:
	_generator_settings.voxel_size      = _voxel_size_spin.value
	_generator_settings.max_resolution  = int(_max_res_spin.value)
	_generator_settings.palette_size    = int(_palette_size_spin.value)
	_generator_settings.ceiling_height  = _ceiling_spin.value
	_generator_settings.glow_strength   = _glow_spin.value
	generator_settings_changed.emit(_generator_settings.duplicate(true))

func _on_generation_option_changed(_index: int) -> void:
	_generator_settings.palette_mode = _palette_mode_opt.selected
	_generator_settings.depth_mode   = _depth_mode_opt.selected
	_generator_settings.room_shape   = _room_shape_opt.selected
	generator_settings_changed.emit(_generator_settings.duplicate(true))

func _apply_settings_to_generator() -> void:
	if _generator == null:
		return
	if _generator.has_method("set"):
		_generator.set("voxel_size",     _generator_settings.voxel_size)
		_generator.set("max_resolution", int(_generator_settings.max_resolution))
		_generator.set("palette_size",   int(_generator_settings.palette_size))
		_generator.set("palette_mode",   int(_generator_settings.palette_mode))
		_generator.set("depth_mode",     int(_generator_settings.depth_mode))
		_generator.set("room_shape",     int(_generator_settings.room_shape))
		_generator.set("ceiling_height", _generator_settings.ceiling_height)
		_generator.set("glow_strength",  _generator_settings.glow_strength)

func _on_brush_kind_changed(idx: int) -> void:
	brush_kind = idx
	brush_changed.emit(brush_kind, brush_radius, brush_color)

func _on_brush_radius_changed(value: float) -> void:
	brush_radius = value
	brush_changed.emit(brush_kind, brush_radius, brush_color)

func _on_brush_emission_changed(value: float) -> void:
	brush_emission = value

func _on_color_picker_changed(c: Color) -> void:
	brush_color = c
	_color_preview.color = c
	brush_changed.emit(brush_kind, brush_radius, brush_color)

func _on_quick_palette_pressed(c: Color) -> void:
	brush_color = c
	_color_preview.color = c
	_color_picker.color = c
	brush_changed.emit(brush_kind, brush_radius, brush_color)

func _on_material_kind_changed(idx: int) -> void:
	_material_settings.kind = idx
	if _material_factory != null and _material_factory.has_method("set"):
		_material_factory.set("default_kind", idx)

func _on_material_preset_changed(idx: int) -> void:
	var name: String = _material_preset_opt.get_item_text(idx)
	_material_settings.preset = name
	if _material_factory != null and _material_factory.has_method("apply_preset"):
		_material_factory.call("apply_preset", name)

func _on_material_setting_changed(_value: float) -> void:
	_material_settings.proximity_radius = _proximity_radius_spin.value
	_material_settings.hover_amplitude  = _hover_amp_spin.value
	_material_settings.pulse_speed      = _pulse_speed_spin.value
	_material_settings.pulse_strength   = _pulse_strength_spin.value
	_material_settings.rim_strength     = _rim_strength_spin.value
	_apply_settings_to_material_factory()

func _apply_settings_to_material_factory() -> void:
	if _material_factory == null:
		return
	_material_factory.set("proximity_radius", _material_settings.proximity_radius)
	_material_factory.set("hover_amplitude",  _material_settings.hover_amplitude)
	_material_factory.set("pulse_speed",      _material_settings.pulse_speed)
	_material_factory.set("pulse_strength",   _material_settings.pulse_strength)
	_material_factory.set("rim_strength",     _material_settings.rim_strength)
	if _material_factory.has_method("_repush_globals_to_all_materials"):
		_material_factory.call("_repush_globals_to_all_materials")

func _on_apply_material_pressed() -> void:
	_apply_settings_to_material_factory()
	_refresh_status("Material settings pushed to live shaders")

# ── Sculpting actions ─────────────────────────────────────────────────────────

func set_brush_position(world_position: Vector3) -> void:
	_last_brush_position = world_position

func _apply_brush_at(world_position: Vector3) -> void:
	if _generator == null:
		_refresh_status("Generator not attached — cannot sculpt")
		return
	var count := 0
	var action_name := ""
	match brush_kind:
		BrushKind.PAINT_VOXEL:
			var ok: bool = _generator.call("add_single_voxel", album_id, world_position, brush_color, brush_emission)
			count = 1 if ok else 0
			action_name = "paint"
			if ok:
				_push_undo({
					"kind":     HistoryActionKind.ADD_VOXEL,
					"position": world_position,
					"color":    brush_color,
					"emission": brush_emission,
				})
		BrushKind.ERASE_VOXEL:
			var captured: Array = _generator.call("capture_voxels_in_radius", album_id, world_position, brush_radius)
			count = int(_generator.call("remove_voxel_at", album_id, world_position, brush_radius))
			action_name = "erase"
			if count > 0:
				_push_undo({
					"kind":     HistoryActionKind.BULK_REMOVE,
					"position": world_position,
					"radius":   brush_radius,
					"count":    count,
					"voxels":   captured,
				})
		BrushKind.RECOLOR:
			var before: Array = _generator.call("capture_voxels_in_radius", album_id, world_position, brush_radius)
			count = int(_generator.call("recolor_voxels_at", album_id, world_position, brush_radius, brush_color))
			action_name = "recolor"
			if count > 0:
				_push_undo({
					"kind":     HistoryActionKind.RECOLOR,
					"position": world_position,
					"radius":   brush_radius,
					"color":    brush_color,
					"count":    count,
					"voxels":   before,
				})
		BrushKind.GLOW:
			var glow_before: Array = _generator.call("capture_voxels_in_radius", album_id, world_position, brush_radius)
			# Use a positive emission step so the brush truly *glows* rather than
			# silently aliasing to the recolor brush.
			var glow_step: float = max(brush_emission, 0.5)
			count = int(_generator.call("boost_emission_at", album_id, world_position, brush_radius, glow_step))
			action_name = "glow"
			if count > 0:
				_push_undo({
					"kind":     HistoryActionKind.GLOW,
					"position": world_position,
					"radius":   brush_radius,
					"delta":    glow_step,
					"count":    count,
					"voxels":   glow_before,
				})
		BrushKind.HOVER_LIFT:
			if _generator.has_method("translate_room"):
				_generator.call("translate_room", album_id, Vector3(0, brush_emission * 0.1, 0))
			action_name = "lift"
		BrushKind.SAMPLE_COLOR:
			action_name = "sample"
			# In a full editor we'd raycast — here we simply confirm the position.
			_refresh_status("Sample at %s" % str(world_position))
			return
	sculpt_action_performed.emit(action_name, count)
	_refresh_status("%s — %d voxels affected" % [action_name, count])
	_refresh_history_list()

func _on_fill_pressed() -> void:
	if _generator == null:
		return
	var center := _last_brush_position
	var step: float = max(0.1, brush_radius * 0.5)
	var added := 0
	var added_positions: Array = []
	for x in range(-2, 3):
		for y in range(-2, 3):
			for z in range(-2, 3):
				var p: Vector3 = center + Vector3(float(x), float(y), float(z)) * step
				if p.distance_to(center) <= brush_radius:
					if _generator.call("add_single_voxel", album_id, p, brush_color, brush_emission):
						added += 1
						added_positions.append(p)
	_push_undo({
		"kind":      HistoryActionKind.BULK_ADD,
		"position":  center,
		"radius":    brush_radius,
		"step":      step,
		"count":     added,
		"color":     brush_color,
		"emission":  brush_emission,
		"positions": added_positions,
	})
	sculpt_action_performed.emit("fill", added)
	_refresh_status("Fill — %d voxels added" % added)
	_refresh_history_list()

func _on_clear_pressed() -> void:
	if _generator == null:
		return
	if _generator.has_method("destroy_room"):
		_generator.call("destroy_room", album_id)
		_clear_history_internal()
		_refresh_status("Room cleared")

# ── Undo/Redo ─────────────────────────────────────────────────────────────────

func _push_undo(action: Dictionary) -> void:
	_undo_stack.append(action)
	if _undo_stack.size() > max_history:
		_undo_stack.pop_front()
	_redo_stack.clear()

func _on_undo_pressed() -> void:
	if _undo_stack.is_empty():
		_refresh_status("Nothing to undo")
		return
	var action: Dictionary = _undo_stack.pop_back()
	_apply_inverse(action)
	_redo_stack.append(action)
	undo_performed.emit(_undo_stack.size())
	_refresh_history_list()

func _on_redo_pressed() -> void:
	if _redo_stack.is_empty():
		_refresh_status("Nothing to redo")
		return
	var action: Dictionary = _redo_stack.pop_back()
	_reapply(action)
	_undo_stack.append(action)
	redo_performed.emit(_redo_stack.size())
	_refresh_history_list()

func _on_clear_history_pressed() -> void:
	_clear_history_internal()

func _clear_history_internal() -> void:
	_undo_stack.clear()
	_redo_stack.clear()
	_refresh_history_list()

func _apply_inverse(action: Dictionary) -> void:
	if _generator == null:
		return
	match int(action.get("kind", -1)):
		HistoryActionKind.ADD_VOXEL:
			_generator.call("remove_voxel_at", album_id, action.position, 0.0)
		HistoryActionKind.BULK_ADD:
			# Remove every voxel we recorded as added, one-by-one for accuracy.
			for p in action.get("positions", []):
				_generator.call("remove_voxel_at", album_id, p, 0.0)
		HistoryActionKind.REMOVE_VOXEL, HistoryActionKind.BULK_REMOVE:
			# Restore the captured voxels with their *original* colour/emission.
			_generator.call("add_voxel_batch", album_id, action.get("voxels", []))
		HistoryActionKind.RECOLOR:
			# Restore each captured voxel's original colour by recoloring tiny
			# spheres centred on each one.
			for v in action.get("voxels", []):
				_generator.call("recolor_voxels_at", album_id, v.position, 0.001, v.color)
		HistoryActionKind.GLOW:
			# Reverse the emission boost on each captured voxel.
			var d: float = -float(action.get("delta", 0.0))
			for v in action.get("voxels", []):
				_generator.call("boost_emission_at", album_id, v.position, 0.001, d)

func _reapply(action: Dictionary) -> void:
	if _generator == null:
		return
	match int(action.get("kind", -1)):
		HistoryActionKind.ADD_VOXEL:
			_generator.call("add_single_voxel", album_id, action.position, action.color, action.emission)
		HistoryActionKind.BULK_ADD:
			# Replay the original positions/color/emission, not the current cursor.
			var col: Color = action.get("color", Color.WHITE)
			var em: float = float(action.get("emission", 0.0))
			for p in action.get("positions", []):
				_generator.call("add_single_voxel", album_id, p, col, em)
		HistoryActionKind.REMOVE_VOXEL, HistoryActionKind.BULK_REMOVE:
			_generator.call("remove_voxel_at", album_id, action.position, action.get("radius", 0.0))
		HistoryActionKind.RECOLOR:
			_generator.call("recolor_voxels_at", album_id, action.position, action.radius, action.color)
		HistoryActionKind.GLOW:
			_generator.call("boost_emission_at", album_id, action.position, action.radius, float(action.get("delta", 0.5)))

func _refresh_history_list() -> void:
	if _history_list == null:
		return
	_history_list.clear()
	for i in range(_undo_stack.size()):
		var action: Dictionary = _undo_stack[i]
		_history_list.add_item("%d  %s @ %s" % [i + 1, _action_kind_name(int(action.get("kind", -1))), str(action.get("position", Vector3.ZERO))])

func _action_kind_name(k: int) -> String:
	match k:
		HistoryActionKind.ADD_VOXEL:    return "add"
		HistoryActionKind.REMOVE_VOXEL: return "remove"
		HistoryActionKind.RECOLOR:      return "recolor"
		HistoryActionKind.GLOW:         return "glow"
		HistoryActionKind.BULK_ADD:     return "bulk_add"
		HistoryActionKind.BULK_REMOVE:  return "bulk_remove"
	return "unknown"

# ── Presets ───────────────────────────────────────────────────────────────────

func _ensure_preset_directory() -> void:
	if not DirAccess.dir_exists_absolute(preset_directory):
		var err := DirAccess.make_dir_recursive_absolute(preset_directory)
		if err != OK and debug_logs:
			push_warning("[MemoryArchitect] could not create preset dir: %d" % err)

func _on_save_preset_pressed() -> void:
	var name := _preset_name_edit.text.strip_edges()
	if name == "":
		_refresh_status("Preset name required")
		return
	var path := "%s/%s.json" % [preset_directory, name]
	var data := _build_preset_payload(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_refresh_status("Could not write %s" % path)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	preset_saved.emit(name, path)
	_refresh_preset_list()
	_refresh_status("Saved preset %s" % name)

func _on_load_preset_pressed() -> void:
	var sel := _preset_list.get_selected_items()
	if sel.is_empty():
		_refresh_status("Pick a preset first")
		return
	var name: String = _preset_list.get_item_text(sel[0])
	var path := "%s/%s.json" % [preset_directory, name]
	if not FileAccess.file_exists(path):
		_refresh_status("Preset file missing")
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_refresh_status("Preset file corrupt")
		return
	_apply_preset_payload(parsed)
	preset_loaded.emit(name, path)
	_refresh_status("Loaded preset %s" % name)

func _on_delete_preset_pressed() -> void:
	var sel := _preset_list.get_selected_items()
	if sel.is_empty():
		return
	var name: String = _preset_list.get_item_text(sel[0])
	var path := "%s/%s.json" % [preset_directory, name]
	if FileAccess.file_exists(path):
		var dir := DirAccess.open(preset_directory)
		if dir != null:
			dir.remove(name + ".json")
	_refresh_preset_list()

func _refresh_preset_list() -> void:
	if _preset_list == null:
		return
	_preset_list.clear()
	if not DirAccess.dir_exists_absolute(preset_directory):
		return
	var dir := DirAccess.open(preset_directory)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var f := dir.get_next()
		if f == "":
			break
		if f.ends_with(".json"):
			_preset_list.add_item(f.get_basename())
	dir.list_dir_end()

func _build_preset_payload(name: String) -> Dictionary:
	var palette_arr := []
	for c in _quick_palette:
		palette_arr.append([c.r, c.g, c.b, c.a])
	return {
		"name":              name,
		"album_id":          album_id,
		"photos":            _photo_paths,
		"generator":         _generator_settings.duplicate(true),
		"material":          _material_settings.duplicate(true),
		"brush_kind":        brush_kind,
		"brush_radius":      brush_radius,
		"brush_color":       [brush_color.r, brush_color.g, brush_color.b, brush_color.a],
		"brush_emission":    brush_emission,
		"quick_palette":     palette_arr,
		"saved_at":          Time.get_unix_time_from_system(),
	}

func _apply_preset_payload(data: Dictionary) -> void:
	album_id = String(data.get("album_id", album_id))
	_photo_paths.clear()
	_photo_list.clear()
	for p in data.get("photos", []):
		_photo_paths.append(String(p))
		_photo_list.add_item(String(p))
	if data.has("generator") and typeof(data.generator) == TYPE_DICTIONARY:
		for k in data.generator.keys():
			_generator_settings[k] = data.generator[k]
		_voxel_size_spin.value     = float(_generator_settings.voxel_size)
		_max_res_spin.value        = float(_generator_settings.max_resolution)
		_palette_size_spin.value   = float(_generator_settings.palette_size)
		_palette_mode_opt.select(int(_generator_settings.palette_mode))
		_depth_mode_opt.select(int(_generator_settings.depth_mode))
		_room_shape_opt.select(int(_generator_settings.room_shape))
		_ceiling_spin.value        = float(_generator_settings.ceiling_height)
		_glow_spin.value           = float(_generator_settings.glow_strength)
	if data.has("material") and typeof(data.material) == TYPE_DICTIONARY:
		for k in data.material.keys():
			_material_settings[k] = data.material[k]
		_material_kind_opt.select(int(_material_settings.kind))
		_proximity_radius_spin.value = float(_material_settings.proximity_radius)
		_hover_amp_spin.value        = float(_material_settings.hover_amplitude)
		_pulse_speed_spin.value      = float(_material_settings.pulse_speed)
		_pulse_strength_spin.value   = float(_material_settings.pulse_strength)
		_rim_strength_spin.value     = float(_material_settings.rim_strength)
	brush_kind     = int(data.get("brush_kind", brush_kind))
	brush_radius   = float(data.get("brush_radius", brush_radius))
	brush_emission = float(data.get("brush_emission", brush_emission))
	var bc = data.get("brush_color", null)
	if typeof(bc) == TYPE_ARRAY and bc.size() >= 4:
		brush_color = Color(bc[0], bc[1], bc[2], bc[3])
		_color_preview.color = brush_color
		_color_picker.color = brush_color
	var qp = data.get("quick_palette", null)
	if typeof(qp) == TYPE_ARRAY:
		_quick_palette = PackedColorArray()
		for entry in qp:
			if typeof(entry) == TYPE_ARRAY and entry.size() >= 4:
				_quick_palette.append(Color(entry[0], entry[1], entry[2], entry[3]))
		_rebuild_quick_palette()
	_brush_radius_slider.value = brush_radius
	_brush_emission_slider.value = brush_emission
	_brush_kind_opt.select(brush_kind)

# ── Status ────────────────────────────────────────────────────────────────────

func _refresh_status(msg: String) -> void:
	if _status_label != null:
		_status_label.text = msg
	if debug_logs:
		print("[MemoryArchitect] %s" % msg)

# ── Diagnostics ───────────────────────────────────────────────────────────────

func get_diagnostics() -> Dictionary:
	return {
		"photos":        _photo_paths.size(),
		"undo":          _undo_stack.size(),
		"redo":          _redo_stack.size(),
		"album_id":      album_id,
		"brush_kind":    brush_kind,
		"brush_radius":  brush_radius,
		"brush_emission": brush_emission,
		"current_tab":   _current_tab,
	}
