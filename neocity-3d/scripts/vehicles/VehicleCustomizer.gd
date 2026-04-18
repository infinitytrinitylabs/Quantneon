## VehicleCustomizer — Paint, Decals, Wheels, Body Kits, Underglow
## Handles all cosmetic customisation of vehicles in real-time 3D.

extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal customization_applied(config: Dictionary)
signal config_saved(config_id: String)
signal config_loaded(config: Dictionary)
signal decal_changed(decal_id: int)
signal paint_changed(color: Color, finish: String)
signal wheel_style_changed(style_id: int)
signal underglow_changed(color: Color, enabled: bool)

# ---------------------------------------------------------------------------
# Constants — paint finishes
# ---------------------------------------------------------------------------
const FINISH_METALLIC    := "metallic"
const FINISH_MATTE       := "matte"
const FINISH_CHROME      := "chrome"
const FINISH_PEARLESCENT := "pearlescent"
const FINISH_CANDY       := "candy"
const FINISH_SATIN       := "satin"

const ALL_FINISHES := [
	FINISH_METALLIC,
	FINISH_MATTE,
	FINISH_CHROME,
	FINISH_PEARLESCENT,
	FINISH_CANDY,
	FINISH_SATIN,
]

# Decal template library (50+ entries)
const DECAL_TEMPLATES: Array[Dictionary] = [
	{"id": 0,  "name": "None",            "texture": ""},
	{"id": 1,  "name": "Flames Classic",  "texture": "res://materials/decals/flames_classic.png"},
	{"id": 2,  "name": "Flames Modern",   "texture": "res://materials/decals/flames_modern.png"},
	{"id": 3,  "name": "Racing Stripes",  "texture": "res://materials/decals/racing_stripes.png"},
	{"id": 4,  "name": "Tribal",          "texture": "res://materials/decals/tribal.png"},
	{"id": 5,  "name": "Stars",           "texture": "res://materials/decals/stars.png"},
	{"id": 6,  "name": "Skulls",          "texture": "res://materials/decals/skulls.png"},
	{"id": 7,  "name": "Dragon",          "texture": "res://materials/decals/dragon.png"},
	{"id": 8,  "name": "Eagle",           "texture": "res://materials/decals/eagle.png"},
	{"id": 9,  "name": "Cyber Grid",      "texture": "res://materials/decals/cyber_grid.png"},
	{"id": 10, "name": "Neon Lines",      "texture": "res://materials/decals/neon_lines.png"},
	{"id": 11, "name": "Circuit Board",   "texture": "res://materials/decals/circuit_board.png"},
	{"id": 12, "name": "Pixel Camo",      "texture": "res://materials/decals/pixel_camo.png"},
	{"id": 13, "name": "Urban Camo",      "texture": "res://materials/decals/urban_camo.png"},
	{"id": 14, "name": "Desert Camo",     "texture": "res://materials/decals/desert_camo.png"},
	{"id": 15, "name": "Arctic Camo",     "texture": "res://materials/decals/arctic_camo.png"},
	{"id": 16, "name": "Checker",         "texture": "res://materials/decals/checker.png"},
	{"id": 17, "name": "Checker Bold",    "texture": "res://materials/decals/checker_bold.png"},
	{"id": 18, "name": "Crosshatch",      "texture": "res://materials/decals/crosshatch.png"},
	{"id": 19, "name": "Honeycomb",       "texture": "res://materials/decals/honeycomb.png"},
	{"id": 20, "name": "Hexagons",        "texture": "res://materials/decals/hexagons.png"},
	{"id": 21, "name": "Waves",           "texture": "res://materials/decals/waves.png"},
	{"id": 22, "name": "Lightning",       "texture": "res://materials/decals/lightning.png"},
	{"id": 23, "name": "Splatter",        "texture": "res://materials/decals/splatter.png"},
	{"id": 24, "name": "Graffiti Tag",    "texture": "res://materials/decals/graffiti_tag.png"},
	{"id": 25, "name": "Dragon II",       "texture": "res://materials/decals/dragon2.png"},
	{"id": 26, "name": "Koi Fish",        "texture": "res://materials/decals/koi.png"},
	{"id": 27, "name": "Phoenix",         "texture": "res://materials/decals/phoenix.png"},
	{"id": 28, "name": "Rose",            "texture": "res://materials/decals/rose.png"},
	{"id": 29, "name": "Thorns",          "texture": "res://materials/decals/thorns.png"},
	{"id": 30, "name": "Mandala",         "texture": "res://materials/decals/mandala.png"},
	{"id": 31, "name": "Geometric",       "texture": "res://materials/decals/geometric.png"},
	{"id": 32, "name": "Abstract Brush",  "texture": "res://materials/decals/abstract_brush.png"},
	{"id": 33, "name": "Kanji Speed",     "texture": "res://materials/decals/kanji_speed.png"},
	{"id": 34, "name": "Kanji Power",     "texture": "res://materials/decals/kanji_power.png"},
	{"id": 35, "name": "Flag USA",        "texture": "res://materials/decals/flag_usa.png"},
	{"id": 36, "name": "Flag Japan",      "texture": "res://materials/decals/flag_japan.png"},
	{"id": 37, "name": "Flag UK",         "texture": "res://materials/decals/flag_uk.png"},
	{"id": 38, "name": "Skull Candy",     "texture": "res://materials/decals/skull_candy.png"},
	{"id": 39, "name": "Retro Racer",     "texture": "res://materials/decals/retro_racer.png"},
	{"id": 40, "name": "Neon Glow",       "texture": "res://materials/decals/neon_glow.png"},
	{"id": 41, "name": "Holographic",     "texture": "res://materials/decals/holographic.png"},
	{"id": 42, "name": "Bio Hazard",      "texture": "res://materials/decals/biohazard.png"},
	{"id": 43, "name": "Radioactive",     "texture": "res://materials/decals/radioactive.png"},
	{"id": 44, "name": "Crypto Runes",    "texture": "res://materials/decals/crypto_runes.png"},
	{"id": 45, "name": "Ghost Lines",     "texture": "res://materials/decals/ghost_lines.png"},
	{"id": 46, "name": "Ice Crystal",     "texture": "res://materials/decals/ice_crystal.png"},
	{"id": 47, "name": "Lava Flow",       "texture": "res://materials/decals/lava_flow.png"},
	{"id": 48, "name": "Deep Sea",        "texture": "res://materials/decals/deep_sea.png"},
	{"id": 49, "name": "Nebula",          "texture": "res://materials/decals/nebula.png"},
	{"id": 50, "name": "Galaxy Swirl",    "texture": "res://materials/decals/galaxy_swirl.png"},
]

# Wheel style library (20 entries)
const WHEEL_STYLES: Array[Dictionary] = [
	{"id": 0,  "name": "Stock Steel",     "mesh": "res://materials/wheels/stock_steel.tres"},
	{"id": 1,  "name": "Sport Alloy",     "mesh": "res://materials/wheels/sport_alloy.tres"},
	{"id": 2,  "name": "Deep Dish",       "mesh": "res://materials/wheels/deep_dish.tres"},
	{"id": 3,  "name": "Spokes Classic",  "mesh": "res://materials/wheels/spokes_classic.tres"},
	{"id": 4,  "name": "Spokes Thin",     "mesh": "res://materials/wheels/spokes_thin.tres"},
	{"id": 5,  "name": "Turbine",         "mesh": "res://materials/wheels/turbine.tres"},
	{"id": 6,  "name": "Star Spoke",      "mesh": "res://materials/wheels/star_spoke.tres"},
	{"id": 7,  "name": "Mesh",            "mesh": "res://materials/wheels/mesh_wheel.tres"},
	{"id": 8,  "name": "Blade",           "mesh": "res://materials/wheels/blade.tres"},
	{"id": 9,  "name": "Aero",            "mesh": "res://materials/wheels/aero.tres"},
	{"id": 10, "name": "Split 5",         "mesh": "res://materials/wheels/split5.tres"},
	{"id": 11, "name": "Split 10",        "mesh": "res://materials/wheels/split10.tres"},
	{"id": 12, "name": "Forged Mono",     "mesh": "res://materials/wheels/forged_mono.tres"},
	{"id": 13, "name": "Chrome Bullet",   "mesh": "res://materials/wheels/chrome_bullet.tres"},
	{"id": 14, "name": "Cyber Spoke",     "mesh": "res://materials/wheels/cyber_spoke.tres"},
	{"id": 15, "name": "Neon Ring",       "mesh": "res://materials/wheels/neon_ring.tres"},
	{"id": 16, "name": "Carbon Centre",   "mesh": "res://materials/wheels/carbon_centre.tres"},
	{"id": 17, "name": "Stealth",         "mesh": "res://materials/wheels/stealth.tres"},
	{"id": 18, "name": "Gold Floater",    "mesh": "res://materials/wheels/gold_floater.tres"},
	{"id": 19, "name": "Hologram Rim",    "mesh": "res://materials/wheels/hologram_rim.tres"},
]

# Spoiler styles (10 entries)
const SPOILER_STYLES: Array[Dictionary] = [
	{"id": 0, "name": "None",           "mesh": ""},
	{"id": 1, "name": "Ducktail",       "mesh": "res://materials/spoilers/ducktail.tres"},
	{"id": 2, "name": "GT Wing",        "mesh": "res://materials/spoilers/gt_wing.tres"},
	{"id": 3, "name": "Whale Tail",     "mesh": "res://materials/spoilers/whale_tail.tres"},
	{"id": 4, "name": "Low Profile",    "mesh": "res://materials/spoilers/low_profile.tres"},
	{"id": 5, "name": "Carbon Blade",   "mesh": "res://materials/spoilers/carbon_blade.tres"},
	{"id": 6, "name": "Infinity Wing",  "mesh": "res://materials/spoilers/infinity_wing.tres"},
	{"id": 7, "name": "Rally Fin",      "mesh": "res://materials/spoilers/rally_fin.tres"},
	{"id": 8, "name": "Neon Foil",      "mesh": "res://materials/spoilers/neon_foil.tres"},
	{"id": 9, "name": "Cyber Delta",    "mesh": "res://materials/spoilers/cyber_delta.tres"},
]

# Exhaust styles (5 entries)
const EXHAUST_STYLES: Array[Dictionary] = [
	{"id": 0, "name": "Stock",          "mesh": ""},
	{"id": 1, "name": "Dual Round",     "mesh": "res://materials/exhausts/dual_round.tres"},
	{"id": 2, "name": "Quad Sport",     "mesh": "res://materials/exhausts/quad_sport.tres"},
	{"id": 3, "name": "Hex Cluster",    "mesh": "res://materials/exhausts/hex_cluster.tres"},
	{"id": 4, "name": "Side Exit",      "mesh": "res://materials/exhausts/side_exit.tres"},
]

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var vehicle_node: Node3D = null
var body_mesh: MeshInstance3D = null
var decal_nodes: Array[Decal] = []
var wheel_mesh_instances: Array[MeshInstance3D] = []
var spoiler_mesh: MeshInstance3D = null
var exhaust_mesh: MeshInstance3D = null
var underglow_lights: Array[OmniLight3D] = []

var current_config: Dictionary = {
	"paint_color":   Color(0.1, 0.5, 1.0),
	"paint_finish":  FINISH_METALLIC,
	"secondary_color": Color(0.05, 0.05, 0.05),
	"decal_id":      0,
	"decal_color":   Color(1, 1, 1),
	"decal_opacity": 1.0,
	"wheel_id":      0,
	"wheel_color":   Color(0.8, 0.8, 0.8),
	"spoiler_id":    0,
	"exhaust_id":    0,
	"underglow_enabled": false,
	"underglow_color":   Color(0, 1, 1),
	"underglow_intensity": 2.0,
	"tint_opacity":  0.0,
	"tint_color":    Color(0, 0, 0),
	"license_plate": "QUANT01",
}

var _paint_material: ShaderMaterial = null
var _saved_configs: Dictionary = {}
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
const MAX_UNDO := 20

# ---------------------------------------------------------------------------
# Shader source for the paint material
# ---------------------------------------------------------------------------
const PAINT_SHADER_CODE := """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform vec4 albedo_color : source_color = vec4(0.1, 0.5, 1.0, 1.0);
uniform vec4 secondary_color : source_color = vec4(0.05, 0.05, 0.05, 1.0);
uniform float metallic_value : hint_range(0.0, 1.0) = 0.8;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.2;
uniform float specular_value : hint_range(0.0, 1.0) = 0.8;
uniform float clearcoat_value : hint_range(0.0, 1.0) = 0.5;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.05;
uniform float anisotropy_value : hint_range(-1.0, 1.0) = 0.0;
uniform int finish_mode : hint_range(0, 5) = 0;
uniform float flake_strength : hint_range(0.0, 1.0) = 0.0;
uniform float pearl_shift : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D flake_texture : hint_default_white;

varying vec3 world_normal;
varying vec3 world_pos;

float rand(vec2 co) {
	return fract(sin(dot(co, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 base = albedo_color.rgb;

	// Pearl shift based on view angle
	if (finish_mode == 3) { // pearlescent
		float view_dot = abs(dot(normalize(VIEW), normalize(NORMAL)));
		float shift = sin(view_dot * 3.14159 + pearl_shift * 6.28) * 0.5 + 0.5;
		base = mix(base, secondary_color.rgb, shift * 0.6);
	}

	// Candy — deep saturated base with high specular glow
	if (finish_mode == 4) {
		base = pow(base, vec3(1.5));
	}

	// Metallic flakes
	vec2 uv_scaled = UV * 80.0;
	float flake = texture(flake_texture, uv_scaled).r;
	float noise = rand(floor(uv_scaled));
	base += flake * noise * flake_strength * 0.4;

	ALBEDO = base;
	METALLIC = metallic_value;
	ROUGHNESS = roughness_value;
	SPECULAR = specular_value;
	CLEARCOAT = clearcoat_value;
	CLEARCOAT_ROUGHNESS = clearcoat_roughness;
	ANISOTROPY = anisotropy_value;
}
"""

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_build_paint_material()

func attach_vehicle(vehicle: Node3D) -> void:
	vehicle_node = vehicle
	body_mesh = vehicle.get_node_or_null("MeshInstance3D")
	_collect_wheel_meshes()
	_setup_underglow()
	apply_config(current_config)

func detach_vehicle() -> void:
	vehicle_node = null
	body_mesh = null
	wheel_mesh_instances.clear()
	decal_nodes.clear()
	underglow_lights.clear()

# ---------------------------------------------------------------------------
# Paint material
# ---------------------------------------------------------------------------
func _build_paint_material() -> void:
	var shader := Shader.new()
	shader.code = PAINT_SHADER_CODE
	_paint_material = ShaderMaterial.new()
	_paint_material.shader = shader

func _apply_paint_finish(finish: String) -> void:
	match finish:
		FINISH_METALLIC:
			_paint_material.set_shader_parameter("metallic_value", 0.9)
			_paint_material.set_shader_parameter("roughness_value", 0.15)
			_paint_material.set_shader_parameter("clearcoat_value", 0.6)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.05)
			_paint_material.set_shader_parameter("flake_strength", 0.3)
			_paint_material.set_shader_parameter("pearl_shift", 0.0)
			_paint_material.set_shader_parameter("finish_mode", 0)
		FINISH_MATTE:
			_paint_material.set_shader_parameter("metallic_value", 0.0)
			_paint_material.set_shader_parameter("roughness_value", 0.95)
			_paint_material.set_shader_parameter("clearcoat_value", 0.0)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.9)
			_paint_material.set_shader_parameter("flake_strength", 0.0)
			_paint_material.set_shader_parameter("pearl_shift", 0.0)
			_paint_material.set_shader_parameter("finish_mode", 1)
		FINISH_CHROME:
			_paint_material.set_shader_parameter("metallic_value", 1.0)
			_paint_material.set_shader_parameter("roughness_value", 0.02)
			_paint_material.set_shader_parameter("clearcoat_value", 1.0)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.01)
			_paint_material.set_shader_parameter("flake_strength", 0.0)
			_paint_material.set_shader_parameter("pearl_shift", 0.0)
			_paint_material.set_shader_parameter("finish_mode", 2)
		FINISH_PEARLESCENT:
			_paint_material.set_shader_parameter("metallic_value", 0.4)
			_paint_material.set_shader_parameter("roughness_value", 0.1)
			_paint_material.set_shader_parameter("clearcoat_value", 0.8)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.03)
			_paint_material.set_shader_parameter("flake_strength", 0.15)
			_paint_material.set_shader_parameter("pearl_shift", 0.5)
			_paint_material.set_shader_parameter("finish_mode", 3)
		FINISH_CANDY:
			_paint_material.set_shader_parameter("metallic_value", 0.0)
			_paint_material.set_shader_parameter("roughness_value", 0.05)
			_paint_material.set_shader_parameter("clearcoat_value", 1.0)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.02)
			_paint_material.set_shader_parameter("flake_strength", 0.0)
			_paint_material.set_shader_parameter("pearl_shift", 0.0)
			_paint_material.set_shader_parameter("finish_mode", 4)
		FINISH_SATIN:
			_paint_material.set_shader_parameter("metallic_value", 0.2)
			_paint_material.set_shader_parameter("roughness_value", 0.45)
			_paint_material.set_shader_parameter("clearcoat_value", 0.2)
			_paint_material.set_shader_parameter("clearcoat_roughness", 0.3)
			_paint_material.set_shader_parameter("flake_strength", 0.0)
			_paint_material.set_shader_parameter("pearl_shift", 0.0)
			_paint_material.set_shader_parameter("finish_mode", 5)

# ---------------------------------------------------------------------------
# Public customisation API
# ---------------------------------------------------------------------------
func set_paint_color(color: Color, finish: String = FINISH_METALLIC) -> void:
	_push_undo()
	current_config["paint_color"] = color
	current_config["paint_finish"] = finish
	_paint_material.set_shader_parameter("albedo_color", color)
	_apply_paint_finish(finish)
	if body_mesh:
		body_mesh.set_surface_override_material(0, _paint_material)
	emit_signal("paint_changed", color, finish)

func set_secondary_color(color: Color) -> void:
	_push_undo()
	current_config["secondary_color"] = color
	_paint_material.set_shader_parameter("secondary_color", color)

func set_paint_from_hsv(h: float, s: float, v: float, finish: String = FINISH_METALLIC) -> void:
	var color := Color.from_hsv(h, s, v)
	set_paint_color(color, finish)

func set_decal(decal_id: int, color: Color = Color.WHITE, opacity: float = 1.0) -> void:
	_push_undo()
	current_config["decal_id"] = decal_id
	current_config["decal_color"] = color
	current_config["decal_opacity"] = opacity
	_update_decals()
	emit_signal("decal_changed", decal_id)

func set_wheel_style(style_id: int, wheel_color: Color = Color(0.8, 0.8, 0.8)) -> void:
	_push_undo()
	current_config["wheel_id"] = style_id
	current_config["wheel_color"] = wheel_color
	_update_wheel_meshes()
	emit_signal("wheel_style_changed", style_id)

func set_spoiler(spoiler_id: int) -> void:
	_push_undo()
	current_config["spoiler_id"] = spoiler_id
	_update_spoiler()

func set_exhaust(exhaust_id: int) -> void:
	_push_undo()
	current_config["exhaust_id"] = exhaust_id
	_update_exhaust()

func set_underglow(enabled: bool, color: Color = Color(0, 1, 1), intensity: float = 2.0) -> void:
	_push_undo()
	current_config["underglow_enabled"] = enabled
	current_config["underglow_color"] = color
	current_config["underglow_intensity"] = intensity
	_update_underglow()
	emit_signal("underglow_changed", color, enabled)

func set_license_plate(text: String) -> void:
	_push_undo()
	current_config["license_plate"] = text
	_update_license_plate(text)

func set_window_tint(opacity: float, color: Color = Color(0, 0, 0)) -> void:
	_push_undo()
	current_config["tint_opacity"] = clampf(opacity, 0.0, 0.9)
	current_config["tint_color"] = color
	_update_window_tint()

# ---------------------------------------------------------------------------
# Internal mesh/node updaters
# ---------------------------------------------------------------------------
func _update_decals() -> void:
	if vehicle_node == null:
		return
	for d in decal_nodes:
		if is_instance_valid(d):
			d.queue_free()
	decal_nodes.clear()

	var decal_id: int = current_config["decal_id"]
	if decal_id == 0:
		return

	var template: Dictionary = {}
	for t in DECAL_TEMPLATES:
		if t["id"] == decal_id:
			template = t
			break
	if template.is_empty() or template["texture"] == "":
		return

	var texture_path: String = template["texture"]
	var tex: Texture2D = null
	if ResourceLoader.exists(texture_path):
		tex = ResourceLoader.load(texture_path)

	var positions := [
		Vector3(0, 0.6, -1.2),
		Vector3(1.0, 0.4, 0),
		Vector3(-1.0, 0.4, 0),
	]

	for pos in positions:
		var decal := Decal.new()
		decal.position = pos
		decal.size = Vector3(2.0, 0.5, 0.1)
		if tex:
			decal.texture_albedo = tex
		decal.modulate = current_config["decal_color"]
		decal.modulate.a = current_config["decal_opacity"]
		vehicle_node.add_child(decal)
		decal_nodes.append(decal)

func _collect_wheel_meshes() -> void:
	wheel_mesh_instances.clear()
	if vehicle_node == null:
		return
	for child in vehicle_node.get_children():
		if child is VehicleWheel3D:
			var mesh := child.get_node_or_null("WheelMesh") as MeshInstance3D
			if mesh:
				wheel_mesh_instances.append(mesh)

func _update_wheel_meshes() -> void:
	var style_id: int = current_config["wheel_id"]
	var wcolor: Color = current_config["wheel_color"]
	for mesh in wheel_mesh_instances:
		if not is_instance_valid(mesh):
			continue
		var mat := StandardMaterial3D.new()
		mat.albedo_color = wcolor
		mat.metallic = 0.7
		mat.roughness = 0.2
		mesh.set_surface_override_material(0, mat)

func _update_spoiler() -> void:
	if vehicle_node == null:
		return
	if spoiler_mesh and is_instance_valid(spoiler_mesh):
		spoiler_mesh.queue_free()
		spoiler_mesh = null

	var sid: int = current_config["spoiler_id"]
	if sid == 0:
		return

	spoiler_mesh = MeshInstance3D.new()
	spoiler_mesh.position = Vector3(0, 0.8, 1.5)
	vehicle_node.add_child(spoiler_mesh)

func _update_exhaust() -> void:
	if vehicle_node == null:
		return
	if exhaust_mesh and is_instance_valid(exhaust_mesh):
		exhaust_mesh.queue_free()
		exhaust_mesh = null

	var eid: int = current_config["exhaust_id"]
	if eid == 0:
		return

	exhaust_mesh = MeshInstance3D.new()
	exhaust_mesh.position = Vector3(0, 0.2, 2.0)
	vehicle_node.add_child(exhaust_mesh)

func _setup_underglow() -> void:
	if vehicle_node == null:
		return
	var offsets := [
		Vector3(0, 0.1, -1.5),
		Vector3(0, 0.1,  1.5),
		Vector3(-1.2, 0.1, 0),
		Vector3( 1.2, 0.1, 0),
	]
	for offset in offsets:
		var light := OmniLight3D.new()
		light.position = offset
		light.omni_range = 2.5
		light.light_energy = 0.0
		vehicle_node.add_child(light)
		underglow_lights.append(light)

func _update_underglow() -> void:
	var enabled: bool = current_config["underglow_enabled"]
	var color: Color = current_config["underglow_color"]
	var intensity: float = current_config["underglow_intensity"]
	for light in underglow_lights:
		if not is_instance_valid(light):
			continue
		light.light_color = color
		light.light_energy = intensity if enabled else 0.0

func _update_window_tint() -> void:
	if vehicle_node == null:
		return
	var opacity: float = current_config["tint_opacity"]
	var color: Color = current_config["tint_color"]
	color.a = opacity
	var window_mesh := vehicle_node.get_node_or_null("WindowMesh") as MeshInstance3D
	if window_mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.0
	mat.metallic = 0.1
	window_mesh.set_surface_override_material(0, mat)

func _update_license_plate(text: String) -> void:
	if vehicle_node == null:
		return
	var plate_label := vehicle_node.get_node_or_null("LicensePlate/Label3D") as Label3D
	if plate_label:
		plate_label.text = text

# ---------------------------------------------------------------------------
# Batch apply
# ---------------------------------------------------------------------------
func apply_config(config: Dictionary) -> void:
	current_config = config.duplicate(true)
	if body_mesh == null:
		return
	_paint_material.set_shader_parameter("albedo_color", current_config["paint_color"])
	_paint_material.set_shader_parameter("secondary_color", current_config.get("secondary_color", Color(0.05, 0.05, 0.05)))
	_apply_paint_finish(current_config.get("paint_finish", FINISH_METALLIC))
	body_mesh.set_surface_override_material(0, _paint_material)
	_update_decals()
	_update_wheel_meshes()
	_update_spoiler()
	_update_exhaust()
	_update_underglow()
	_update_window_tint()
	emit_signal("customization_applied", current_config)

# ---------------------------------------------------------------------------
# Undo / Redo
# ---------------------------------------------------------------------------
func _push_undo() -> void:
	_undo_stack.append(current_config.duplicate(true))
	if _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()

func undo() -> void:
	if _undo_stack.is_empty():
		return
	_redo_stack.append(current_config.duplicate(true))
	var prev := _undo_stack.pop_back()
	apply_config(prev)

func redo() -> void:
	if _redo_stack.is_empty():
		return
	_undo_stack.append(current_config.duplicate(true))
	var next := _redo_stack.pop_back()
	apply_config(next)

func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

# ---------------------------------------------------------------------------
# Save / Load configurations
# ---------------------------------------------------------------------------
func save_config(config_name: String) -> String:
	var config_id := config_name.strip_edges().replace(" ", "_").to_lower()
	if config_id == "":
		config_id = "config_" + str(Time.get_unix_time_from_system())
	_saved_configs[config_id] = current_config.duplicate(true)
	_persist_configs()
	emit_signal("config_saved", config_id)
	print("[VehicleCustomizer] Config saved: ", config_id)
	return config_id

func load_config(config_id: String) -> bool:
	if not _saved_configs.has(config_id):
		print("[VehicleCustomizer] Config not found: ", config_id)
		return false
	apply_config(_saved_configs[config_id])
	emit_signal("config_loaded", current_config)
	return true

func delete_config(config_id: String) -> void:
	_saved_configs.erase(config_id)
	_persist_configs()

func get_saved_config_ids() -> Array:
	return _saved_configs.keys()

func get_config_preview(config_id: String) -> Dictionary:
	return _saved_configs.get(config_id, {})

func _persist_configs() -> void:
	var player_data := get_node_or_null("/root/PlayerData")
	if player_data and player_data.has_method("set_vehicle_configs"):
		player_data.set_vehicle_configs(_saved_configs)
	else:
		var file := FileAccess.open("user://vehicle_configs.json", FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(_saved_configs, "\t"))

func load_persisted_configs() -> void:
	var player_data := get_node_or_null("/root/PlayerData")
	if player_data and player_data.has_method("get_vehicle_configs"):
		_saved_configs = player_data.get_vehicle_configs()
		return
	if FileAccess.file_exists("user://vehicle_configs.json"):
		var file := FileAccess.open("user://vehicle_configs.json", FileAccess.READ)
		if file:
			var result := JSON.parse_string(file.get_as_text())
			if result is Dictionary:
				_saved_configs = result

# ---------------------------------------------------------------------------
# Config serialisation helpers (for network / marketplace)
# ---------------------------------------------------------------------------
func config_to_json() -> String:
	var export_config := current_config.duplicate(true)
	export_config["paint_color"] = _color_to_dict(current_config["paint_color"])
	export_config["secondary_color"] = _color_to_dict(current_config.get("secondary_color", Color.BLACK))
	export_config["decal_color"] = _color_to_dict(current_config["decal_color"])
	export_config["wheel_color"] = _color_to_dict(current_config["wheel_color"])
	export_config["underglow_color"] = _color_to_dict(current_config["underglow_color"])
	export_config["tint_color"] = _color_to_dict(current_config.get("tint_color", Color.BLACK))
	return JSON.stringify(export_config)

func config_from_json(json_str: String) -> Dictionary:
	var parsed = JSON.parse_string(json_str)
	if not parsed is Dictionary:
		return {}
	if parsed.has("paint_color"):
		parsed["paint_color"] = _dict_to_color(parsed["paint_color"])
	if parsed.has("secondary_color"):
		parsed["secondary_color"] = _dict_to_color(parsed["secondary_color"])
	if parsed.has("decal_color"):
		parsed["decal_color"] = _dict_to_color(parsed["decal_color"])
	if parsed.has("wheel_color"):
		parsed["wheel_color"] = _dict_to_color(parsed["wheel_color"])
	if parsed.has("underglow_color"):
		parsed["underglow_color"] = _dict_to_color(parsed["underglow_color"])
	if parsed.has("tint_color"):
		parsed["tint_color"] = _dict_to_color(parsed["tint_color"])
	return parsed

func _color_to_dict(c: Color) -> Dictionary:
	return {"r": c.r, "g": c.g, "b": c.b, "a": c.a}

func _dict_to_color(d: Dictionary) -> Color:
	return Color(d.get("r", 0), d.get("g", 0), d.get("b", 0), d.get("a", 1))

# ---------------------------------------------------------------------------
# Randomise
# ---------------------------------------------------------------------------
func randomise_paint() -> void:
	var h := randf()
	var s := randf_range(0.6, 1.0)
	var brightness := randf_range(0.5, 1.0)
	var finish := ALL_FINISHES[randi() % ALL_FINISHES.size()]
	set_paint_from_hsv(h, s, brightness, finish)

func randomise_decal() -> void:
	var id := randi() % DECAL_TEMPLATES.size()
	var color := Color(randf(), randf(), randf())
	set_decal(id, color, randf_range(0.5, 1.0))

func randomise_wheels() -> void:
	var id := randi() % WHEEL_STYLES.size()
	var color := Color(randf_range(0.3, 1.0), randf_range(0.3, 1.0), randf_range(0.3, 1.0))
	set_wheel_style(id, color)

func randomise_all() -> void:
	randomise_paint()
	randomise_decal()
	randomise_wheels()
	set_spoiler(randi() % SPOILER_STYLES.size())
	set_exhaust(randi() % EXHAUST_STYLES.size())
	set_underglow(randf() > 0.5, Color(randf(), randf(), randf()), randf_range(1.0, 4.0))

# ---------------------------------------------------------------------------
# Getters for UI
# ---------------------------------------------------------------------------
func get_decal_name(id: int) -> String:
	for t in DECAL_TEMPLATES:
		if t["id"] == id:
			return t["name"]
	return "Unknown"

func get_wheel_name(id: int) -> String:
	for w in WHEEL_STYLES:
		if w["id"] == id:
			return w["name"]
	return "Unknown"

func get_spoiler_name(id: int) -> String:
	for s in SPOILER_STYLES:
		if s["id"] == id:
			return s["name"]
	return "Unknown"

func get_exhaust_name(id: int) -> String:
	for e in EXHAUST_STYLES:
		if e["id"] == id:
			return e["name"]
	return "Unknown"

func get_finish_display_name(finish: String) -> String:
	match finish:
		FINISH_METALLIC:    return "Metallic"
		FINISH_MATTE:       return "Matte"
		FINISH_CHROME:      return "Chrome"
		FINISH_PEARLESCENT: return "Pearlescent"
		FINISH_CANDY:       return "Candy"
		FINISH_SATIN:       return "Satin"
	return finish.capitalize()

# ---------------------------------------------------------------------------
# Before / after snapshot for comparison slider
# ---------------------------------------------------------------------------
var _before_config: Dictionary = {}

func snapshot_before() -> void:
	_before_config = current_config.duplicate(true)

func restore_before() -> void:
	if not _before_config.is_empty():
		apply_config(_before_config)

func get_before_config() -> Dictionary:
	return _before_config.duplicate(true)
