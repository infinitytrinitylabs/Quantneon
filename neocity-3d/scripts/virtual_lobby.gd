## Virtual Lobby
## A multiplayer virtual space where users' avatars can interact,
## watch live streams together, and hang out in immersive 3D environments.
## Extends ARVRBase to support both desktop and XR/AR modes.

class_name VirtualLobby
extends ARVRBase

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
/** Interpolation speed for avatar movement smoothing (0–1, higher = snappier). */
@export var position_lerp_speed: float = 0.2
@export var rotation_lerp_speed: float = 0.2
var present_users: Dictionary = {} # { user_id: { display_name, avatar_node } }
var _avatar_scene: PackedScene = null

# ─── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	super._ready()
	_apply_ambient()
	_register_with_network()
	print("[VirtualLobby] '%s' ready (capacity: %d)" % [display_name, max_capacity])

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
		emit_signal("user_joined", uid, dname)

func _on_remote_user_left(data: Dictionary) -> void:
	var uid = data.get("userId", "")
	if uid != "" and present_users.has(uid):
		var entry = present_users[uid]
		if entry.avatar_node and is_instance_valid(entry.avatar_node):
			entry.avatar_node.queue_free()
		present_users.erase(uid)
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
