## Player Character Controller (3rd Person)
## Handles WASD movement, sprint, jump, mouse-look camera, and NPC interaction.

extends CharacterBody3D

# ── Movement Config ──────────────────────────────────
@export var walk_speed: float = 5.0
@export var sprint_speed: float = 9.0
@export var jump_velocity: float = 6.0
@export var mouse_sensitivity: float = 0.003
@export var gravity: float = 20.0
@export var acceleration: float = 10.0
@export var deceleration: float = 15.0

# ── Camera & Components ──────────────────────────────
@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var player_model: Node3D = $PlayerModel
@onready var interaction_ray: RayCast3D = $InteractionRay

# ── State ────────────────────────────────────────────
var current_speed: float = 0.0
var target_rotation: float = 0.0
var is_remote: bool = false
var target_pos: Vector3 = Vector3.ZERO
var target_rot: float = 0.0

@export var max_health: float = 100.0
var current_health: float = max_health
var is_dead: bool = false
var clan_tag: String = ""
var active_cybernetics: Array = []

# ── Parkour State ────────────────────────────────────
var jumps_remaining: int = 2
var max_jumps: int = 2
var is_wall_sliding: bool = false
@export var wall_slide_speed: float = 3.0
var is_on_zipline: bool = false
@onready var name_tag: Label3D = $NameTag if has_node("NameTag") else null

var hp_bar_viewport: SubViewport
var hp_bar: ProgressBar
var hp_sprite: Sprite3D
var damage_text_scene = preload("res://scenes/damage_text.tscn")
var drone_scene = preload("res://scenes/drone_companion.tscn")
var active_drone: Node3D = null
# Reused tween for remote-player position interpolation; killed before each reuse to
# prevent conflicting animations from accumulating when updates arrive rapidly.
var _remote_move_tween: Tween = null

func _ready() -> void:
	if !is_remote:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		if NetworkManager.socket_client:
			NetworkManager.socket_client.on_event("cybernetics_update", _on_cybernetics_update)
			NetworkManager.socket_client.on_event("drone_spawned", _on_drone_spawned)
			NetworkManager.socket_client.on_event("drone_chat_response", _on_drone_chat_response)
	
	_setup_health_bar()
	
	if name_tag == null:
		name_tag = Label3D.new()
		name_tag.name = "NameTag"
		name_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		name_tag.position.y = 2.2
		name_tag.font_size = 48
		name_tag.outline_size = 12
		add_child(name_tag)

	spring_arm.spring_length = 4.0
	spring_arm.position.y = 1.8


func _unhandled_input(event: InputEvent) -> void:
	if is_remote: return
	
	# Mouse look
	if event is InputEventMouseMotion:
		camera_pivot.rotate_y(-event.relative.x * mouse_sensitivity)
		spring_arm.rotate_x(-event.relative.y * mouse_sensitivity)
		spring_arm.rotation.x = clamp(spring_arm.rotation.x, deg_to_rad(-60), deg_to_rad(30))
	
	# Toggle mouse capture
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Interact with NPC
	if event.is_action_pressed("interact"):
		_try_interact()
	
	# Attack
	if event.is_action_pressed("attack"):
		_try_attack()

	# Drone Chat Toggle
	if event is InputEventKey and event.pressed and event.keycode == KEY_T:
		if has_node("/root/Main/HUD/DroneChatBox"):
			get_node("/root/Main/HUD/DroneChatBox").toggle_chat()

	# Spawn Drone
	if event is InputEventKey and event.pressed and event.keycode == KEY_G:
		if NetworkManager.socket_client:
			NetworkManager.socket_client.send_event("spawn_drone", {})


func _physics_process(delta: float) -> void:
	if is_remote: return
	if is_on_zipline: return  # Zipline script handles movement
	
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	
	# Reset jumps on landing
	if is_on_floor():
		jumps_remaining = max_jumps
	
	# Jump (with double-jump support)
	if Input.is_action_just_pressed("jump") and jumps_remaining > 0:
		jumps_remaining -= 1
		if jumps_remaining == max_jumps - 1:
			velocity.y = jump_velocity  # First jump - full power
		else:
			velocity.y = jump_velocity * 0.8  # Air jump - reduced
			# Squash-stretch visual
			var tween = create_tween()
			tween.tween_property(player_model, "scale", Vector3(1.2, 0.8, 1.2), 0.05)
			tween.tween_property(player_model, "scale", Vector3(1, 1, 1), 0.15)
	
	# Movement direction (relative to camera)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (camera_pivot.global_basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	direction.y = 0
	
	# Speed (walk vs sprint)
	var is_sprinting := Input.is_action_pressed("sprint")
	var target_speed := sprint_speed if is_sprinting else walk_speed
	
	if direction.length() > 0.1:
		# Smoothly accelerate
		current_speed = lerp(current_speed, target_speed, acceleration * delta)
		velocity.x = direction.x * current_speed
		velocity.z = direction.z * current_speed
		
		# Rotate player model to face movement direction
		target_rotation = atan2(direction.x, direction.z)
		player_model.rotation.y = lerp_angle(player_model.rotation.y, target_rotation, 10.0 * delta)
	else:
		# Smoothly decelerate
		current_speed = lerp(current_speed, 0.0, deceleration * delta)
		velocity.x = move_toward(velocity.x, 0.0, deceleration * delta)
		velocity.z = move_toward(velocity.z, 0.0, deceleration * delta)
	
	# Wall-slide: slow descent when pressing into a wall while falling
	is_wall_sliding = false
	if not is_on_floor() and is_on_wall() and velocity.y < 0:
		var wall_input := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
		if wall_input.length() > 0.1:
			is_wall_sliding = true
			velocity.y = max(velocity.y, -wall_slide_speed)
			# Allow wall-jump
			if Input.is_action_just_pressed("jump"):
				var wall_normal = get_wall_normal()
				velocity = wall_normal * sprint_speed * 0.7
				velocity.y = jump_velocity * 0.9
				jumps_remaining = 1  # Allow one more air jump after wall-jump
	
	move_and_slide()


func set_remote_mode(remote: bool):
	is_remote = remote
	if remote:
		set_physics_process(false)
		if has_node("CameraPivot"):
			$CameraPivot.queue_free()

func update_state(data: Dictionary):
	if data.has("clanTag"):
		clan_tag = data.get("clanTag", "")
	
	var display_name = data.userId.substr(0, 8)
	if data.has("username"):
		display_name = data.username
	
	if name_tag:
		if clan_tag != "" and clan_tag != null:
			name_tag.text = "[" + clan_tag + "] " + display_name
		else:
			name_tag.text = display_name
	
	if data.has("hp"):
		var old_hp = current_health
		current_health = data.hp
		if hp_bar: hp_bar.value = current_health
		
		# Show damage text if decreased externally
		if current_health < old_hp and is_remote:
			hp_sprite.visible = true
			if damage_text_scene:
				var dtext = damage_text_scene.instantiate()
				get_tree().root.add_child(dtext)
				dtext.global_position = global_position + Vector3(0, 2.5, 0)
				dtext.setup(old_hp - current_health)
				
		if current_health <= 0 and !is_dead:
			die()
			
	if data.has("cybernetics"):
		_apply_cybernetics(data.cybernetics)
	
	if is_remote and data.has("x"):
		target_pos = Vector3(data.x / 10.0, 1.0, data.y / 10.0)
		target_rot = data.r if data.has("r") else 0.0
		# Kill any in-flight tween before starting a new one to avoid conflicting
		# animations accumulating when network updates arrive rapidly.
		if _remote_move_tween and _remote_move_tween.is_running():
			_remote_move_tween.kill()
		_remote_move_tween = create_tween().set_parallel(true)
		_remote_move_tween.tween_property(self, "global_position", target_pos, 0.1)
		_remote_move_tween.tween_property(self, "rotation:y", target_rot, 0.1)


func die():
	is_dead = true
	# Visual feedback for death
	if has_node("PlayerModel"):
		var tween = create_tween()
		tween.tween_property($PlayerModel, "rotation_degrees:x", -90, 0.3)
		tween.tween_property($PlayerModel, "position:y", -0.9, 0.3)
	
	if hp_sprite: hp_sprite.visible = false
	if name_tag: name_tag.visible = false
		
	set_physics_process(false)

func _setup_health_bar():
	hp_bar_viewport = SubViewport.new()
	hp_bar_viewport.transparent_bg = true
	hp_bar_viewport.size = Vector2(200, 20)
	
	hp_bar = ProgressBar.new()
	hp_bar.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp_bar.show_percentage = false
	hp_bar.max_value = max_health
	hp_bar.value = current_health
	
	var style_bg = StyleBoxFlat.new()
	style_bg.bg_color = Color(0.1, 0.1, 0.1, 0.8)
	var style_fg = StyleBoxFlat.new()
	style_fg.bg_color = Color(0.2, 0.8, 1.0, 1.0) # Player gets Cyan HP bar
	if is_remote:
		style_fg.bg_color = Color(1.0, 0.5, 0.0, 1.0) # Remote players get Orange

	hp_bar.add_theme_stylebox_override("background", style_bg)
	hp_bar.add_theme_stylebox_override("fill", style_fg)
	
	hp_bar_viewport.add_child(hp_bar)
	add_child(hp_bar_viewport)
	
	hp_sprite = Sprite3D.new()
	hp_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hp_sprite.texture = hp_bar_viewport.get_texture()
	hp_sprite.position = Vector3(0, 2.8, 0)
	hp_sprite.visible = false # Hide by default
	add_child(hp_sprite)


func _try_interact() -> void:
	if interaction_ray.is_colliding():
		var collider = interaction_ray.get_collider()
		if collider.has_method("interact"):
			collider.interact(self)


func _try_attack():
	# Visual Recoil
	var tween = create_tween()
	tween.tween_property(player_model, "position:z", 0.2, 0.05)
	tween.tween_property(player_model, "position:z", 0.0, 0.1)

	# Setup RayCast query from Center of Screen (Camera)
	var space_state = get_world_3d().direct_space_state
	var screen_center = get_viewport().get_visible_rect().size / 2.0
	var from_ray = camera.project_ray_origin(screen_center)
	var to_ray = from_ray + camera.project_ray_normal(screen_center) * 50.0 # 50m range
	
	var query = PhysicsRayQueryParameters3D.create(from_ray, to_ray)
	query.exclude = [self.get_rid()] # Exclude self
	var result = space_state.intersect_ray(query)
	
	var hit_point = to_ray
	
	var nm = get_node_or_null("/root/NetworkManager")
	
	if result and !result.is_empty():
		hit_point = result.position
		var collider = result.collider
		
		# Check if we hit a player or npc
		if collider.is_in_group("players") or collider.is_in_group("npcs") or collider.has_method("die"):
			# Find the network ID. Usually the node name is like player_abc123 or npc_xyz
			var hit_id = collider.name.replace("player_", "").replace("npc_", "")
			
			if "npc_id" in collider:
				hit_id = collider.npc_id
				
			if nm and nm.socket_client:
				nm.socket_client.send_event("player_attack", {
					"target_id": hit_id,
					"weapon": "pistol"
				})
	
	# Draw temporary tracer line
	_draw_tracer(player_model.global_position + Vector3(0, 1.5, 0), hit_point)
	
	# Network Sync visual fire effect
	if nm and nm.socket_client:
		nm.socket_client.send_event("player_weapon_fire", {
			"weapon": "pistol",
			"pos": {"x": global_position.x * 10, "y": global_position.z * 10}
		})

func _draw_tracer(start: Vector3, end: Vector3):
	var mesh_inst = MeshInstance3D.new()
	var imesh = ImmediateMesh.new()
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.2, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2, 1.0)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	
	imesh.surface_begin(Mesh.PRIMITIVE_LINES)
	imesh.surface_add_vertex(start)
	imesh.surface_add_vertex(end)
	imesh.surface_end()
	
	mesh_inst.mesh = imesh
	mesh_inst.material_override = mat
	get_tree().root.add_child(mesh_inst)
	
	var tween = create_tween()
	tween.tween_property(mat, "albedo_color:a", 0.0, 0.1)
	tween.tween_callback(mesh_inst.queue_free)


func _on_cybernetics_update(data: Dictionary) -> void:
	if data.has("cybernetics"):
		_apply_cybernetics(data.cybernetics)

func _apply_cybernetics(implants: Array) -> void:
	active_cybernetics = implants
	# Reset to baselines
	walk_speed = 5.0
	sprint_speed = 9.0
	max_health = 100.0
	jump_velocity = 6.0
	max_jumps = 2
	
	# Apply augments
	if "neural_accelerator" in implants:
		walk_speed *= 1.4
		sprint_speed *= 1.4
	
	if "titanium_bones" in implants:
		max_health += 50.0
	
	if "leg_servos" in implants:
		max_jumps = 3  # Triple jump!
		jump_velocity *= 1.2

# ── Drone Companion ──────────────────────────────────
func _on_drone_spawned(data: Dictionary) -> void:
	var target_owner_id = data.get("userId", "")
	
	# Only spawn for the matching player
	if is_remote and target_owner_id != name.replace("player_", ""):
		return
	if !is_remote and NetworkManager.socket_client.sid != target_owner_id:
		return
		
	if active_drone:
		active_drone.queue_free()
		
	active_drone = drone_scene.instantiate()
	get_tree().root.add_child(active_drone)
	# Position slightly behind
	active_drone.global_position = global_position + Vector3(0, 2, -2)
	active_drone.setup(self, is_remote)
	
	# Initial greeting
	if data.has("greeting"):
		active_drone.show_message(data.greeting, 5.0)

func _on_drone_chat_response(data: Dictionary) -> void:
	var target_owner_id = data.get("userId", "")
	# Process only if we own this drone
	if (!is_remote and NetworkManager.socket_client.sid == target_owner_id) or (is_remote and target_owner_id == name.replace("player_", "")):
		if active_drone and is_instance_valid(active_drone):
			active_drone.show_message(data.message, 8.0)
