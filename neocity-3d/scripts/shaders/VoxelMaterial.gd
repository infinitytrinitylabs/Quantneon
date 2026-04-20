## VoxelMaterial — Proximity-reactive material factory for memory voxels
## ─────────────────────────────────────────────────────────────────────
## Builds the runtime materials used by VoxelGenerator's voxel rooms.
## Two flavors of material are produced:
##
##   • Standard / preview material — a tuned `StandardMaterial3D` used when
##     the player is far away (cheap, batched, no shader overhead).
##   • Proximity / hero material   — a `ShaderMaterial` driving a custom
##     spatial shader that makes voxels glow, hover, pulse, dissolve and
##     shimmer when the player gets close.
##
## The factory also owns the master shader source code and a small system
## that polls the player's position once per frame and pushes the result
## into every active proximity material as a single uniform — this avoids
## writing per-voxel scripts and keeps the cost flat regardless of how
## many voxels are in the room.
##
## A dedicated palette texture is generated for each registered album so
## that the shader can perform colour-cycling on the GPU using only a
## single sampler lookup.
extends Node

# ── Signals ────────────────────────────────────────────────────────────────────

signal player_position_updated(world_position: Vector3)
signal palette_texture_built(palette_index: int, size: int)
signal proximity_focus_changed(album_id: String, focus: float)
signal material_built(palette_index: int, kind: int)
signal effect_preset_applied(preset_name: String)

# ── Enums ──────────────────────────────────────────────────────────────────────

enum MaterialKind {
	STANDARD       = 0,  # StandardMaterial3D, no shader cost
	PROXIMITY      = 1,  # ShaderMaterial with reactive proximity uniform
	HOLOGRAM       = 2,  # ShaderMaterial with scanline + flicker
	DISSOLVE       = 3,  # ShaderMaterial with edge-dissolve animation
	GLASS_SHARD    = 4,  # Refractive shard with rim light
	NEON_OUTLINE   = 5,  # Solid colour with strong fresnel rim
	LIQUID_PULSE   = 6,  # Wave-based vertex displacement
}

enum EmissionCurve {
	LINEAR     = 0,
	SQUARED    = 1,
	SQRT       = 2,
	PULSE      = 3,
	HEARTBEAT  = 4,
}

enum PaletteFormat {
	RGB8   = 0,
	RGBA8  = 1,
	RGBAF  = 2,
}

# ── Tunables ───────────────────────────────────────────────────────────────────

@export var default_kind: MaterialKind = MaterialKind.PROXIMITY
@export var proximity_radius: float = 4.5
@export var proximity_falloff: float = 2.5
@export var glow_color_blend: float = 0.6
@export var hover_amplitude: float = 0.04
@export var hover_speed: float = 1.6
@export var pulse_speed: float = 3.0
@export var pulse_strength: float = 0.35
@export var rim_strength: float = 0.55
@export var rim_power: float = 2.5
@export var dissolve_speed: float = 0.4
@export var fresnel_color: Color = Color(0.30, 0.95, 1.0, 1.0)
@export var palette_texture_width: int = 64
@export var enable_player_tracking: bool = true
@export var player_node_path: NodePath
@export var debug_logs: bool = false

# ── Internal state ─────────────────────────────────────────────────────────────

var _player: Node3D = null
var _last_player_position: Vector3 = Vector3.ZERO
var _materials_proximity: Array = []
var _palette_textures: Dictionary = {}
var _shader_cache: Dictionary = {}
var _focus_album_id: String = ""
var _focus_value: float = 0.0
var _time_accum: float = 0.0
var _heartbeat_phase: float = 0.0

# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	if player_node_path != NodePath(""):
		var n: Node = get_node_or_null(player_node_path)
		if n is Node3D:
			_player = n
	set_process(enable_player_tracking)
	if debug_logs:
		print("[VoxelMaterial] ready, default kind=%d" % default_kind)

func _process(delta: float) -> void:
	_time_accum += delta
	_heartbeat_phase = fmod(_heartbeat_phase + delta * 1.2, TAU)
	if _player == null:
		return
	var pos: Vector3 = _player.global_transform.origin
	if pos.distance_squared_to(_last_player_position) < 0.0009:
		return
	_last_player_position = pos
	_push_player_to_materials(pos)
	player_position_updated.emit(pos)

func attach_player(player: Node3D) -> void:
	_player = player

func set_focus(album_id: String, focus: float) -> void:
	_focus_album_id = album_id
	_focus_value = clamp(focus, 0.0, 1.0)
	for ref in _materials_proximity:
		if ref is ShaderMaterial:
			(ref as ShaderMaterial).set_shader_parameter("focus", _focus_value)
	proximity_focus_changed.emit(album_id, _focus_value)

# ── Public façade matching VoxelGenerator's expectation ───────────────────────

func build_material(color: Color, emission: float, palette_index: int) -> Material:
	match default_kind:
		MaterialKind.STANDARD:     return _build_standard(color, emission)
		MaterialKind.PROXIMITY:    return _build_proximity(color, emission, palette_index)
		MaterialKind.HOLOGRAM:     return _build_hologram(color, emission, palette_index)
		MaterialKind.DISSOLVE:     return _build_dissolve(color, emission, palette_index)
		MaterialKind.GLASS_SHARD:  return _build_glass_shard(color, emission, palette_index)
		MaterialKind.NEON_OUTLINE: return _build_neon_outline(color, emission, palette_index)
		MaterialKind.LIQUID_PULSE: return _build_liquid_pulse(color, emission, palette_index)
	return _build_standard(color, emission)

func build_proximity_material(color: Color, emission: float, palette_index: int) -> Material:
	return _build_proximity(color, emission, palette_index)

func build_for_kind(kind: int, color: Color, emission: float, palette_index: int) -> Material:
	var prev: int = default_kind
	default_kind = kind
	var m := build_material(color, emission, palette_index)
	default_kind = prev
	return m

# ── Standard (cheap) material ─────────────────────────────────────────────────

func _build_standard(color: Color, emission: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.06
	mat.roughness = 0.55
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = clamp(emission, 0.0, 6.0)
	mat.rim_enabled = true
	mat.rim = clamp(rim_strength * 0.5, 0.0, 1.0)
	mat.rim_tint = 0.4
	return mat

# ── Proximity material ────────────────────────────────────────────────────────

func _build_proximity(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.PROXIMITY, _shader_source_proximity())
	_apply_common_proximity_params(mat, color, emission, palette_index)
	mat.set_shader_parameter("hover_amplitude", hover_amplitude)
	mat.set_shader_parameter("hover_speed", hover_speed)
	mat.set_shader_parameter("pulse_speed", pulse_speed)
	mat.set_shader_parameter("pulse_strength", pulse_strength)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.PROXIMITY)
	return mat

# ── Hologram material ─────────────────────────────────────────────────────────

func _build_hologram(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.HOLOGRAM, _shader_source_hologram())
	_apply_common_proximity_params(mat, color, emission + 0.6, palette_index)
	mat.set_shader_parameter("scanline_speed", 1.7)
	mat.set_shader_parameter("scanline_density", 64.0)
	mat.set_shader_parameter("flicker_amount", 0.06)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.HOLOGRAM)
	return mat

# ── Dissolve material ─────────────────────────────────────────────────────────

func _build_dissolve(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.DISSOLVE, _shader_source_dissolve())
	_apply_common_proximity_params(mat, color, emission, palette_index)
	mat.set_shader_parameter("dissolve_amount", 0.0)
	mat.set_shader_parameter("dissolve_speed", dissolve_speed)
	mat.set_shader_parameter("edge_color", Color(1.0, 0.55, 0.15, 1.0))
	mat.set_shader_parameter("edge_width", 0.08)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.DISSOLVE)
	return mat

# ── Glass shard material ──────────────────────────────────────────────────────

func _build_glass_shard(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.GLASS_SHARD, _shader_source_glass())
	_apply_common_proximity_params(mat, color, emission, palette_index)
	mat.set_shader_parameter("ior", 1.45)
	mat.set_shader_parameter("transparency_strength", 0.55)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.GLASS_SHARD)
	return mat

# ── Neon outline material ─────────────────────────────────────────────────────

func _build_neon_outline(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.NEON_OUTLINE, _shader_source_neon_outline())
	_apply_common_proximity_params(mat, color, emission + 0.4, palette_index)
	mat.set_shader_parameter("outline_strength", rim_strength * 1.5)
	mat.set_shader_parameter("outline_power", rim_power)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.NEON_OUTLINE)
	return mat

# ── Liquid pulse material ─────────────────────────────────────────────────────

func _build_liquid_pulse(color: Color, emission: float, palette_index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _get_or_create_shader(MaterialKind.LIQUID_PULSE, _shader_source_liquid_pulse())
	_apply_common_proximity_params(mat, color, emission, palette_index)
	mat.set_shader_parameter("wave_speed", 2.4)
	mat.set_shader_parameter("wave_frequency", 6.0)
	mat.set_shader_parameter("wave_amplitude", 0.05)
	_register_proximity_material(mat)
	material_built.emit(palette_index, MaterialKind.LIQUID_PULSE)
	return mat

# ── Common parameter binding ──────────────────────────────────────────────────

func _apply_common_proximity_params(mat: ShaderMaterial, color: Color, emission: float, palette_index: int) -> void:
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("emission_strength", emission)
	mat.set_shader_parameter("glow_blend", glow_color_blend)
	mat.set_shader_parameter("rim_color", fresnel_color)
	mat.set_shader_parameter("rim_strength", rim_strength)
	mat.set_shader_parameter("rim_power", rim_power)
	mat.set_shader_parameter("proximity_radius", proximity_radius)
	mat.set_shader_parameter("proximity_falloff", proximity_falloff)
	mat.set_shader_parameter("player_position", _last_player_position)
	mat.set_shader_parameter("focus", _focus_value)
	mat.set_shader_parameter("palette_index", palette_index)
	if _palette_textures.has(palette_index):
		mat.set_shader_parameter("palette_tex", _palette_textures[palette_index])

func _register_proximity_material(mat: ShaderMaterial) -> void:
	_materials_proximity.append(mat)
	if _materials_proximity.size() > 1024:
		_cull_dead_materials()

func _cull_dead_materials() -> void:
	var alive: Array = []
	for m in _materials_proximity:
		if m is Material and is_instance_valid(m):
			alive.append(m)
	_materials_proximity = alive

func _push_player_to_materials(pos: Vector3) -> void:
	var dead := false
	for m in _materials_proximity:
		if m is ShaderMaterial and is_instance_valid(m):
			(m as ShaderMaterial).set_shader_parameter("player_position", pos)
		else:
			dead = true
	if dead:
		_cull_dead_materials()

func _get_or_create_shader(kind: int, src: String) -> Shader:
	if _shader_cache.has(kind):
		return _shader_cache[kind]
	var s := Shader.new()
	s.code = src
	_shader_cache[kind] = s
	return s

# ── Palette texture management ────────────────────────────────────────────────

func register_palette(palette_index: int, palette: PackedColorArray, fmt: int = PaletteFormat.RGBA8) -> ImageTexture:
	if palette.size() == 0:
		return null
	var w: int = max(palette.size(), 4)
	var image_format: int = Image.FORMAT_RGBA8
	if fmt == PaletteFormat.RGB8:
		image_format = Image.FORMAT_RGB8
	elif fmt == PaletteFormat.RGBAF:
		image_format = Image.FORMAT_RGBAF
	var img := Image.create(w, 1, false, image_format)
	for i in range(w):
		var c: Color
		if i < palette.size():
			c = palette[i]
		else:
			c = palette[i % palette.size()]
		img.set_pixel(i, 0, c)
	var tex := ImageTexture.create_from_image(img)
	_palette_textures[palette_index] = tex
	palette_texture_built.emit(palette_index, w)
	return tex

func get_palette_texture(palette_index: int) -> ImageTexture:
	return _palette_textures.get(palette_index, null)

func clear_palettes() -> void:
	_palette_textures.clear()

# ── Effect presets ────────────────────────────────────────────────────────────

func apply_preset(preset_name: String) -> void:
	match preset_name:
		"calm":
			pulse_speed = 1.4
			pulse_strength = 0.18
			hover_amplitude = 0.02
			hover_speed = 1.0
			rim_strength = 0.4
			fresnel_color = Color(0.4, 0.8, 1.0)
		"vibrant":
			pulse_speed = 3.4
			pulse_strength = 0.42
			hover_amplitude = 0.06
			hover_speed = 2.0
			rim_strength = 0.8
			fresnel_color = Color(1.0, 0.4, 0.9)
		"melancholic":
			pulse_speed = 0.8
			pulse_strength = 0.12
			hover_amplitude = 0.01
			hover_speed = 0.5
			rim_strength = 0.25
			fresnel_color = Color(0.6, 0.6, 0.85)
		"electric":
			pulse_speed = 5.0
			pulse_strength = 0.55
			hover_amplitude = 0.08
			hover_speed = 2.5
			rim_strength = 1.0
			fresnel_color = Color(0.4, 1.0, 1.0)
		_:
			return
	_repush_globals_to_all_materials()
	effect_preset_applied.emit(preset_name)

func _repush_globals_to_all_materials() -> void:
	for m in _materials_proximity:
		if m is ShaderMaterial and is_instance_valid(m):
			var sm := m as ShaderMaterial
			sm.set_shader_parameter("pulse_speed", pulse_speed)
			sm.set_shader_parameter("pulse_strength", pulse_strength)
			sm.set_shader_parameter("hover_amplitude", hover_amplitude)
			sm.set_shader_parameter("hover_speed", hover_speed)
			sm.set_shader_parameter("rim_strength", rim_strength)
			sm.set_shader_parameter("rim_color", fresnel_color)

# ── Emission curve helper ─────────────────────────────────────────────────────

func evaluate_emission_curve(curve: int, t: float) -> float:
	t = clamp(t, 0.0, 1.0)
	match curve:
		EmissionCurve.LINEAR:    return t
		EmissionCurve.SQUARED:   return t * t
		EmissionCurve.SQRT:      return sqrt(t)
		EmissionCurve.PULSE:     return 0.5 + 0.5 * sin(t * TAU)
		EmissionCurve.HEARTBEAT:
			var h := pow(sin(t * TAU * 2.0), 8.0)
			return clamp(h, 0.0, 1.0)
	return t

# ── Diagnostics ───────────────────────────────────────────────────────────────

func get_diagnostics() -> Dictionary:
	return {
		"proximity_materials": _materials_proximity.size(),
		"palettes":            _palette_textures.size(),
		"shaders_cached":      _shader_cache.size(),
		"player_attached":     _player != null,
		"focus_album":         _focus_album_id,
		"focus_value":         _focus_value,
		"time":                _time_accum,
	}

# ── Shader sources ────────────────────────────────────────────────────────────
# All shader strings are kept as code-only (no .gdshader files). Each shader
# accepts the same set of "common" uniforms and adds a few extras of its own.

func _common_shader_header() -> String:
	return """shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform float emission_strength : hint_range(0.0, 8.0) = 0.0;
uniform float glow_blend : hint_range(0.0, 1.0) = 0.6;
uniform vec4 rim_color : source_color = vec4(0.3, 0.95, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 4.0) = 0.55;
uniform float rim_power : hint_range(0.5, 8.0) = 2.5;
uniform float proximity_radius : hint_range(0.1, 50.0) = 4.5;
uniform float proximity_falloff : hint_range(0.1, 8.0) = 2.5;
uniform vec3 player_position = vec3(0.0);
uniform float focus : hint_range(0.0, 1.0) = 0.0;
uniform int palette_index = 0;
uniform sampler2D palette_tex : hint_default_white;
"""

func _proximity_helpers() -> String:
	return """
float compute_proximity(vec3 world_pos) {
	float d = distance(world_pos, player_position);
	float t = 1.0 - clamp(d / proximity_radius, 0.0, 1.0);
	return pow(t, proximity_falloff);
}
vec3 palette_sample(int idx) {
	float u = (float(idx) + 0.5) / float(textureSize(palette_tex, 0).x);
	return texture(palette_tex, vec2(u, 0.5)).rgb;
}
float n21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
"""

func _shader_source_proximity() -> String:
	return _common_shader_header() + """
uniform float hover_amplitude : hint_range(0.0, 0.5) = 0.04;
uniform float hover_speed : hint_range(0.0, 6.0) = 1.6;
uniform float pulse_speed : hint_range(0.0, 8.0) = 3.0;
uniform float pulse_strength : hint_range(0.0, 1.5) = 0.35;
varying vec3 v_world_pos;
varying float v_prox;
""" + _proximity_helpers() + """
void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float prox = compute_proximity(world);
	float hover = sin(TIME * hover_speed + world.x * 0.7 + world.z * 0.4) * hover_amplitude * prox;
	VERTEX.y += hover;
	v_world_pos = world;
	v_prox = prox;
}
void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir = normalize(cam - v_world_pos);
	float ndv = clamp(dot(NORMAL, view_dir), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	float pulse = 0.5 + 0.5 * sin(TIME * pulse_speed + float(palette_index));
	pulse = mix(1.0, pulse, pulse_strength);
	vec3 albedo = mix(base_color.rgb, rim_color.rgb, glow_blend * v_prox);
	ALBEDO = albedo * pulse;
	float em = emission_strength + v_prox * 1.5 + focus * 1.2;
	EMISSION = albedo * em + rim_color.rgb * fres * rim_strength * (0.4 + v_prox);
	METALLIC = 0.05;
	ROUGHNESS = mix(0.6, 0.25, v_prox);
	ALPHA = base_color.a;
}
"""

func _shader_source_hologram() -> String:
	return _common_shader_header() + """
uniform float scanline_speed : hint_range(0.0, 8.0) = 1.7;
uniform float scanline_density : hint_range(4.0, 256.0) = 64.0;
uniform float flicker_amount : hint_range(0.0, 0.5) = 0.06;
varying vec3 v_world_pos;
""" + _proximity_helpers() + """
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float prox = compute_proximity(v_world_pos);
	float scan = 0.5 + 0.5 * sin(v_world_pos.y * scanline_density - TIME * scanline_speed);
	float flick = 1.0 - flicker_amount * n21(vec2(TIME * 7.31, v_world_pos.y * 5.0));
	vec3 col = base_color.rgb * (0.6 + 0.4 * scan) * flick;
	ALBEDO = col;
	EMISSION = col * (emission_strength + prox + focus);
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float fres = pow(1.0 - clamp(dot(NORMAL, normalize(cam - v_world_pos)), 0.0, 1.0), rim_power);
	EMISSION += rim_color.rgb * fres * rim_strength;
	ALPHA = mix(0.55, 0.95, prox);
}
"""

func _shader_source_dissolve() -> String:
	return _common_shader_header() + """
uniform float dissolve_amount : hint_range(0.0, 1.0) = 0.0;
uniform float dissolve_speed : hint_range(0.0, 4.0) = 0.4;
uniform vec4 edge_color : source_color = vec4(1.0, 0.55, 0.15, 1.0);
uniform float edge_width : hint_range(0.0, 0.5) = 0.08;
varying vec3 v_world_pos;
""" + _proximity_helpers() + """
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	float prox = compute_proximity(v_world_pos);
	float n = n21(floor(v_world_pos.xz * 8.0) + vec2(floor(v_world_pos.y * 8.0)));
	float threshold = clamp(dissolve_amount + sin(TIME * dissolve_speed) * 0.05, 0.0, 1.0);
	if (n < threshold - edge_width) {
		discard;
	}
	float edge = smoothstep(threshold - edge_width, threshold, n);
	ALBEDO = mix(edge_color.rgb, base_color.rgb, edge);
	EMISSION = base_color.rgb * (emission_strength + prox + focus) + edge_color.rgb * (1.0 - edge) * 2.0;
	METALLIC = 0.05;
	ROUGHNESS = 0.4;
	ALPHA = base_color.a;
}
"""

func _shader_source_glass() -> String:
	return _common_shader_header() + """
uniform float ior : hint_range(1.0, 2.5) = 1.45;
uniform float transparency_strength : hint_range(0.0, 1.0) = 0.55;
varying vec3 v_world_pos;
""" + _proximity_helpers() + """
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir = normalize(cam - v_world_pos);
	float ndv = clamp(dot(NORMAL, view_dir), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	float prox = compute_proximity(v_world_pos);
	ALBEDO = base_color.rgb;
	EMISSION = rim_color.rgb * fres * rim_strength + base_color.rgb * (emission_strength + prox * 0.5);
	METALLIC = 0.0;
	ROUGHNESS = mix(0.05, 0.2, 1.0 - prox);
	ALPHA = mix(1.0 - transparency_strength, 1.0, fres);
}
"""

func _shader_source_neon_outline() -> String:
	return _common_shader_header() + """
uniform float outline_strength : hint_range(0.0, 4.0) = 0.8;
uniform float outline_power : hint_range(0.5, 8.0) = 2.5;
varying vec3 v_world_pos;
""" + _proximity_helpers() + """
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir = normalize(cam - v_world_pos);
	float ndv = clamp(dot(NORMAL, view_dir), 0.0, 1.0);
	float fres = pow(1.0 - ndv, outline_power);
	float prox = compute_proximity(v_world_pos);
	ALBEDO = base_color.rgb * 0.18;
	EMISSION = rim_color.rgb * fres * outline_strength * (1.0 + prox) + base_color.rgb * emission_strength;
	METALLIC = 0.2;
	ROUGHNESS = 0.4;
	ALPHA = base_color.a;
}
"""

func _shader_source_liquid_pulse() -> String:
	return _common_shader_header() + """
uniform float wave_speed : hint_range(0.0, 8.0) = 2.4;
uniform float wave_frequency : hint_range(0.5, 32.0) = 6.0;
uniform float wave_amplitude : hint_range(0.0, 0.4) = 0.05;
varying vec3 v_world_pos;
varying float v_prox;
""" + _proximity_helpers() + """
void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float prox = compute_proximity(world);
	float wave = sin((world.x + world.z) * wave_frequency + TIME * wave_speed);
	VERTEX += NORMAL * wave * wave_amplitude * (0.4 + prox);
	v_world_pos = world;
	v_prox = prox;
}
void fragment() {
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 view_dir = normalize(cam - v_world_pos);
	float ndv = clamp(dot(NORMAL, view_dir), 0.0, 1.0);
	float fres = pow(1.0 - ndv, rim_power);
	ALBEDO = mix(base_color.rgb, rim_color.rgb, glow_blend * v_prox);
	EMISSION = base_color.rgb * (emission_strength + v_prox + focus) + rim_color.rgb * fres * rim_strength;
	METALLIC = 0.1;
	ROUGHNESS = 0.3;
	ALPHA = base_color.a;
}
"""

# ── Convenience: precompile all shaders ───────────────────────────────────────

func precompile_all_shaders() -> void:
	for k in [
		MaterialKind.PROXIMITY,
		MaterialKind.HOLOGRAM,
		MaterialKind.DISSOLVE,
		MaterialKind.GLASS_SHARD,
		MaterialKind.NEON_OUTLINE,
		MaterialKind.LIQUID_PULSE,
	]:
		var src: String = ""
		match k:
			MaterialKind.PROXIMITY:    src = _shader_source_proximity()
			MaterialKind.HOLOGRAM:     src = _shader_source_hologram()
			MaterialKind.DISSOLVE:     src = _shader_source_dissolve()
			MaterialKind.GLASS_SHARD:  src = _shader_source_glass()
			MaterialKind.NEON_OUTLINE: src = _shader_source_neon_outline()
			MaterialKind.LIQUID_PULSE: src = _shader_source_liquid_pulse()
		_get_or_create_shader(k, src)
