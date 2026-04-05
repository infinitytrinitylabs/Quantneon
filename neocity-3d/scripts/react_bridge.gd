## Strict React-Godot Bridge (CEO Audit: Phase 1)
## Handles all JavaScript callbacks safely and translates to native Signals.

extends Node

signal auth_token_received(token: String)
signal quantads_auction_won_received(payload: Dictionary)
signal bridge_ready()

var _js_message_cb = null

func _ready():
	if OS.has_feature("web"):
		_setup_strict_bridge()

func _setup_strict_bridge():
	print("[ReactBridge] Initializing Strict Validation Bridge...")
	
	# The sole entry point for React -> Godot
	_js_message_cb = JavaScriptBridge.create_callback(_on_js_message)
	var window = JavaScriptBridge.get_interface("window")
	if window:
		window.godotReceiveMessage = _js_message_cb
		print("[ReactBridge] Bridge bound to window.godotReceiveMessage.")
		
		# Announce readiness
		_send_to_react("ENGINE_READY", {"status": "ok"})
		emit_signal("bridge_ready")

func _on_js_message(args):
	if args.size() == 0:
		return
		
	var json_str = args[0]
	if typeof(json_str) != TYPE_STRING:
		printerr("[ReactBridge] Expected JSON string payload.")
		return
		
	var json = JSON.new()
	var err = json.parse(json_str)
	if err != OK:
		printerr("[ReactBridge] Invalid JSON from JS: ", json.get_error_message())
		return
		
	var payload = json.get_data()
	if typeof(payload) != TYPE_DICTIONARY:
		return
		
	# Strict Validation of our Contract
	if not payload.has("source") or payload["source"] != "REACT_APP":
		return
		
	if not payload.has("type") or not payload.has("payload"):
		printerr("[ReactBridge] Missing type or payload in bridge message.")
		return
		
	var msg_type = payload["type"]
	var msg_data = payload["payload"]
	
	# Dispatch to native signals
	match msg_type:
		"AUTH_INJECT":
			if msg_data.has("token"):
				print("[ReactBridge] Received AUTH_INJECT")
				emit_signal("auth_token_received", msg_data["token"])
		"QUANTADS_AUCTION_WON":
			if msg_data is Dictionary:
				emit_signal("quantads_auction_won_received", msg_data)
		_:
			print("[ReactBridge] Unhandled message type: ", msg_type)

func send_to_react(type: String, payload: Dictionary):
	if OS.has_feature("web"):
		var msg = {
			"source": "GODOT_ENGINE",
			"type": type,
			"payload": payload
		}
		var json_str = JSON.stringify(msg)
		# We escape the json_str to safely evaluate it in JS
		var escaped = json_str.replace("'", "\\'").replace('"', '\\"')
		JavaScriptBridge.eval("window.parent.postMessage('" + escaped + "', '*');")

func _send_to_react(type: String, payload: Dictionary):
	send_to_react(type, payload)
