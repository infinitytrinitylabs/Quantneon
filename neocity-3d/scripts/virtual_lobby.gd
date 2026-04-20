## Virtual Lobby
## A multiplayer virtual space where users' avatars can interact,
## watch live streams together, and hang out in immersive 3D environments.
## Extends ARVRBase to support both desktop and XR/AR modes.

class_name VirtualLobby
extends ARVRBase

const QualityScoringScript = preload("res://scripts/social/QualityScoring.gd")
const InstanceRouterScript = preload("res://scripts/networking/InstanceRouter.gd")

# ─── Signals ──────────────────────────────────────────────────────────────────
signal user_joined(user_id: String, display_name: String)
signal user_left(user_id: String)
signal stream_started(stream_id: String)
signal capacity_reached()

# ─── Config ───────────────────────────────────────────────────────────────────
@export var lobby_id: String = ""
@export var display_name: String = "Virtual Lobby"
@export var max_capacity: int = 50
@export var stream_screen_path: NodePath = NodePath("")
@export var spawn_point: NodePath = NodePath("")
@export var ambient_color: Color = Color(0.05, 0.0, 0.15) # Deep neon purple

# ─── State ────────────────────────────────────────────────────────────────────
## Interpolation speed for avatar position smoothing (0–1, higher = snappier).
@export var position_lerp_speed: float = 0.2
## Interpolation speed for avatar rotation smoothing (0–1, higher = snappier).
@export var rotation_lerp_speed: float = 0.2
var active_stream_id: String = ""
var present_users: Dictionary = {} # { user_id: { display_name, avatar_node } }
var _avatar_scene: PackedScene = null
var quality_scoring: QualityScoring
var instance_router: InstanceRouter
var _instance_aura_cache: Dictionary = {}

# ─── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	super._ready()
	_setup_social_clustering()
	_apply_ambient()
	_register_with_network()
	print("[VirtualLobby] '%s' ready (capacity: %d)" % [display_name, max_capacity])

func _setup_social_clustering() -> void:
	quality_scoring = QualityScoringScript.new()
	instance_router = InstanceRouterScript.new()
	instance_router.set_quality_scoring(quality_scoring)
	instance_router.instance_cue_updated.connect(_on_instance_cue_updated)

func _apply_ambient() -> void:
	var env_node = get_node_or_null("WorldEnvironment")
	if env_node and env_node is WorldEnvironment:
		var world_env = env_node.environment as Environment
		if world_env:
			world_env.background_color = ambient_color
			world_env.ambient_light_color = ambient_color
			world_env.ambient_light_energy = 0.5

func _register_with_network() -> void:
	if has_node("/root/SocketIOClient"):
		var sock = get_node("/root/SocketIOClient")
		if sock.has_method("on_event"):
			sock.on_event("lobby:user_joined", _on_remote_user_joined)
			sock.on_event("lobby:user_left", _on_remote_user_left)
			sock.on_event("avatar:moved", _on_remote_avatar_moved)
			sock.on_event("avatar:emoted", _on_remote_avatar_emoted)
			sock.on_event("stream:viewer_joined", _on_stream_viewer_joined)

# ─── User management ──────────────────────────────────────────────────────────

func join_lobby(user_id: String, dname: String) -> bool:
	if present_users.size() >= max_capacity:
		emit_signal("capacity_reached")
		return false
	
	present_users[user_id] = { "display_name": dname, "avatar_node": null }
	var instance_id: String = instance_router.route_user(user_id)
	present_users[user_id]["instance_id"] = instance_id
	emit_signal("user_joined", user_id, dname)
	
	# Notify server
	if has_node("/root/SocketIOClient"):
		get_node("/root/SocketIOClient").send_event("lobby:join", { "roomId": lobby_id })
	
	print("[VirtualLobby] '%s' joined '%s'" % [dname, display_name])
	return true

func leave_lobby(user_id: String) -> void:
	if present_users.has(user_id):
		var entry = present_users[user_id]
		if entry.avatar_node and is_instance_valid(entry.avatar_node):
			entry.avatar_node.queue_free()
		present_users.erase(user_id)
		instance_router.remove_user(user_id)
		emit_signal("user_left", user_id)
	
	if has_node("/root/SocketIOClient"):
		get_node("/root/SocketIOClient").send_event("lobby:leave", { "roomId": lobby_id })

func get_user_count() -> int:
	return present_users.size()

# ─── Live stream integration ──────────────────────────────────────────────────

func start_stream(stream_id: String) -> void:
	active_stream_id = stream_id
	emit_signal("stream_started", stream_id)
	
	var screen = get_node_or_null(stream_screen_path)
	if screen and screen.has_method("load_stream"):
		screen.load_stream(stream_id)
	
	if has_node("/root/SocketIOClient"):
		get_node("/root/SocketIOClient").send_event("stream:join", { "streamId": stream_id })
	
	print("[VirtualLobby] Stream '%s' started in lobby '%s'" % [stream_id, lobby_id])

func stop_stream() -> void:
	if active_stream_id == "":
		return
	if has_node("/root/SocketIOClient"):
		get_node("/root/SocketIOClient").send_event("stream:leave", { "streamId": active_stream_id })
	active_stream_id = ""

# ─── Network event handlers ───────────────────────────────────────────────────

func _on_remote_user_joined(data: Dictionary) -> void:
	var uid = data.get("userId", "")
	var dname = data.get("username", uid)
	if uid != "" and not present_users.has(uid):
		present_users[uid] = { "display_name": dname, "avatar_node": null }
		present_users[uid]["instance_id"] = instance_router.route_user(uid)
		emit_signal("user_joined", uid, dname)

func _on_remote_user_left(data: Dictionary) -> void:
	var uid = data.get("userId", "")
	if uid != "" and present_users.has(uid):
		var entry = present_users[uid]
		if entry.avatar_node and is_instance_valid(entry.avatar_node):
			entry.avatar_node.queue_free()
		present_users.erase(uid)
		instance_router.remove_user(uid)
		emit_signal("user_left", uid)

func _on_remote_avatar_moved(data: Dictionary) -> void:
	var uid = data.get("userId", "")
	if uid == "" or not present_users.has(uid):
		return
	var entry = present_users[uid]
	if entry.avatar_node and is_instance_valid(entry.avatar_node):
		var target = Vector3(
			data.get("x", 0.0),
			data.get("y", 0.0),
			data.get("z", 0.0)
		)
		entry.avatar_node.global_position = entry.avatar_node.global_position.lerp(target, position_lerp_speed)
		entry.avatar_node.rotation.y = lerp_angle(
			entry.avatar_node.rotation.y,
			data.get("r", 0.0),
			rotation_lerp_speed
		)

func _on_remote_avatar_emoted(data: Dictionary) -> void:
	var uid = data.get("userId", "")
	if present_users.has(uid):
		var entry = present_users[uid]
		if entry.avatar_node and is_instance_valid(entry.avatar_node):
			if entry.avatar_node.has_method("play_emote"):
				entry.avatar_node.play_emote(data.get("emote", "wave"))

func _on_stream_viewer_joined(data: Dictionary) -> void:
	print("[VirtualLobby] Viewer joined stream: ", data.get("username", "?"))

# ─── Override: user interaction ───────────────────────────────────────────────

func on_user_interact(user_id: String) -> void:
	print("[VirtualLobby] User '%s' is interacting with lobby '%s'" % [user_id, lobby_id])

func record_social_interaction(
	user_id: String,
	peer_id: String,
	interaction_quality: float,
	shared_event_participation: float = 0.0,
	communication_seconds: float = 0.0
) -> void:
	if quality_scoring == null or instance_router == null:
		return
	quality_scoring.record_interaction(
		user_id,
		peer_id,
		interaction_quality,
		shared_event_participation,
		communication_seconds
	)
	if present_users.has(user_id):
		present_users[user_id]["instance_id"] = instance_router.route_user(user_id)
	if present_users.has(peer_id):
		present_users[peer_id]["instance_id"] = instance_router.route_user(peer_id)

func _on_instance_cue_updated(instance_id: String, cue_payload: Dictionary) -> void:
	_instance_aura_cache[instance_id] = cue_payload
	_apply_resonance_ambience()

func _apply_resonance_ambience() -> void:
	if _instance_aura_cache.is_empty():
		return
	var strongest_cue: Dictionary = {}
	var best_intensity: float = -1.0
	for cue in _instance_aura_cache.values():
		var intensity: float = float(cue.get("aura_intensity", 0.0))
		if intensity > best_intensity:
			best_intensity = intensity
			strongest_cue = cue
	if strongest_cue.is_empty():
		return

	var env_node = get_node_or_null("WorldEnvironment")
	if env_node == null or not (env_node is WorldEnvironment):
		return
	var world_env = env_node.environment as Environment
	if world_env == null:
		return

	var cue_color: Color = strongest_cue.get("aura_color", ambient_color)
	var cue_intensity: float = clampf(float(strongest_cue.get("aura_intensity", 0.0)), 0.0, 1.0)
	world_env.background_color = ambient_color.lerp(cue_color, cue_intensity * 0.25)
	world_env.ambient_light_color = ambient_color.lerp(cue_color, cue_intensity * 0.35)
	world_env.ambient_light_energy = lerpf(0.5, 0.9, cue_intensity)
