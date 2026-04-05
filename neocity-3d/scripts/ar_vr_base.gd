## AR/VR Base Node
## Base class for all immersive 3D UI elements and AR-ready Godot nodes.
## Provides hooks for XR mode, holographic rendering, and spatial anchoring.

class_name ARVRBase
extends Node3D

# ─── Signals ──────────────────────────────────────────────────────────────────
signal xr_mode_changed(enabled: bool)
signal interaction_started(user_id: String)
signal interaction_ended(user_id: String)
signal anchor_placed(position: Vector3)

# ─── XR State ─────────────────────────────────────────────────────────────────
@export var xr_enabled: bool = false
@export var hologram_tint: Color = Color(0.2, 0.8, 1.0, 0.85) # Neon cyan
@export var interaction_radius: float = 2.0

var _xr_interface: XRInterface = null
var _is_immersive: bool = false

# ─── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	if xr_enabled:
		_try_init_xr()
	_apply_hologram_material()
	_setup_interaction_area()

func _try_init_xr() -> void:
	_xr_interface = XRServer.find_interface("WebXR")
	if _xr_interface == null:
		_xr_interface = XRServer.find_interface("OpenXR")
	
	if _xr_interface and _xr_interface.is_initialized():
		get_viewport().use_xr = true
		_is_immersive = true
		print("[ARVRBase] XR interface active: ", _xr_interface.get_name())
		emit_signal("xr_mode_changed", true)
	else:
		print("[ARVRBase] No XR interface found — running in desktop 3D mode")

func _apply_hologram_material() -> void:
	# Apply a neon hologram shader to all MeshInstance3D children
	for child in get_children():
		if child is MeshInstance3D:
			var mat = StandardMaterial3D.new()
			mat.albedo_color = hologram_tint
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.emission_enabled = true
			mat.emission = hologram_tint
			mat.emission_energy_multiplier = 1.5
			child.material_override = mat

func _setup_interaction_area() -> void:
	var area = Area3D.new()
	var shape = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = interaction_radius
	shape.shape = sphere
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_body_entered_interaction)
	area.body_exited.connect(_on_body_exited_interaction)

# ─── Virtual methods (override in subclasses) ─────────────────────────────────

func on_xr_activated() -> void:
	pass

func on_xr_deactivated() -> void:
	pass

func on_user_interact(user_id: String) -> void:
	pass

# ─── Interaction callbacks ────────────────────────────────────────────────────

func _on_body_entered_interaction(body: Node3D) -> void:
	if body.name == "Player" or body.is_in_group("players"):
		var uid = body.get("user_id") if "user_id" in body else body.name
		emit_signal("interaction_started", str(uid))
		on_user_interact(str(uid))

func _on_body_exited_interaction(body: Node3D) -> void:
	if body.name == "Player" or body.is_in_group("players"):
		var uid = body.get("user_id") if "user_id" in body else body.name
		emit_signal("interaction_ended", str(uid))

# ─── Spatial anchor helpers ───────────────────────────────────────────────────

## Place this node at a real-world anchor position (AR mode only).
func place_anchor(world_position: Vector3) -> void:
	global_position = world_position
	emit_signal("anchor_placed", world_position)
	print("[ARVRBase] Anchor placed at: ", world_position)

## Toggle XR immersive mode at runtime.
func set_xr_mode(enabled: bool) -> void:
	xr_enabled = enabled
	if enabled:
		_try_init_xr()
	else:
		get_viewport().use_xr = false
		_is_immersive = false
		emit_signal("xr_mode_changed", false)

func is_immersive() -> bool:
	return _is_immersive
