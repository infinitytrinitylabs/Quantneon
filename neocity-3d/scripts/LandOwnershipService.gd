## LandOwnershipService — Virtual Real Estate Economy: Land Ownership
##
## Handles:
##   • Virtual land-block claiming and ownership in the procedural city grid.
##   • Per-block metadata: owner, district, price, claim timestamp.
##   • Building customization streaks — daily decoration updates tracked locally
##     and validated server-side; gold-glow milestone at streak ≥ 12 days.
##   • Neighborhood drama notifications when a rival block is claimed adjacent
##     to a player-owned parcel.
##   • Time-limited Event Zones (FOMO) — server broadcasts active zones with
##     an expiry countdown; the service emits signals so UI can react.
##   • City leaderboard data refresh via REST/socket.
##
## All persistence lives on the backend; this service mirrors state locally and
## emits signals that UI panels and the BuildingDecaySystem consume.

extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

## Days of inactivity before ghost-building decay begins (mirrors server rule).
const DECAY_THRESHOLD_DAYS: int = 7

## Maximum number of blocks a single player may own simultaneously.
const MAX_BLOCKS_PER_PLAYER: int = 10

## Quant-token cost to claim an unclaimed block.
const BASE_CLAIM_COST: int = 500

## Extra cost multiplier for high-value district blocks.
const PREMIUM_DISTRICT_MULTIPLIER: float = 2.5

## Streak milestone at which the building receives the gold-glow decoration.
const GOLD_GLOW_STREAK: int = 12

## Polling interval (seconds) for the city leaderboard refresh.
const LEADERBOARD_POLL_INTERVAL: float = 60.0

## How many seconds before an event zone expires to begin flashing the FOMO UI.
const FOMO_FLASH_THRESHOLD_SECS: float = 600.0

# ── District definitions ────────────────────────────────────────────────────────
## Registered districts; populated from server on world_entered.
var districts: Dictionary = {}
## {district_id: {id, name, multiplier, color_hex}}

# ── Block registry ─────────────────────────────────────────────────────────────
## All known blocks keyed by block_id ("gx_gz" grid coordinates).
## Each entry is a Dictionary with keys:
##   id, grid_x, grid_z, district_id, owner_id, owner_name,
##   claim_time_unix, last_visit_unix, decoration_streak,
##   has_gold_glow, is_for_sale, sale_price, is_event_zone
var blocks: Dictionary = {}

# ── Local player state ─────────────────────────────────────────────────────────
var local_player_id: String = ""
var local_player_name: String = ""
var owned_block_ids: Array = []       # block_ids owned by the local player
var quant_balance: int = 0            # mirrors server token balance (read-only here)

# ── Leaderboard ────────────────────────────────────────────────────────────────
## Array of {rank, player_id, player_name, block_count, weekly_rent_income}.
var leaderboard: Array = []
var _leaderboard_timer: float = 0.0

# ── Event zones ────────────────────────────────────────────────────────────────
## Active event zones: Array of {zone_id, name, description, expires_unix,
##   reward_tokens, position_x, position_z, radius, is_visited}.
var active_event_zones: Array = []
var _event_zone_check_timer: float = 0.0

# ── Streak cache ───────────────────────────────────────────────────────────────
## Local cache of today's date string used to deduplicate streak calls.
var _last_streak_date: String = ""

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when the block registry is updated (bulk or single block).
signal blocks_updated(changed_block_ids: Array)

## Emitted when a block claim attempt resolves.
signal claim_result(success: bool, block_id: String, reason: String)

## Emitted when a block release attempt resolves.
signal release_result(success: bool, block_id: String, reason: String)

## Emitted when the city leaderboard data refreshes.
signal leaderboard_updated(entries: Array)

## Emitted when a rival player claims a block adjacent to an owned parcel.
signal neighborhood_drama(owned_block_id: String, rival_block_id: String,
		rival_name: String, message: String)

## Emitted when an event zone becomes active or its countdown changes.
signal event_zones_updated(zones: Array)

## Emitted when the player enters an active event zone.
signal event_zone_entered(zone: Dictionary)

## Emitted when the player's decoration streak increments.
signal decoration_streak_updated(block_id: String, new_streak: int,
		gold_glow_unlocked: bool)

## Emitted when the local player's owned blocks list changes.
signal owned_blocks_changed(block_ids: Array)

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_connect_socket_events()
	print("[LandOwnershipService] Ready.")

func _process(delta: float) -> void:
	_leaderboard_timer += delta
	if _leaderboard_timer >= LEADERBOARD_POLL_INTERVAL:
		_leaderboard_timer = 0.0
		request_leaderboard()

	_event_zone_check_timer += delta
	if _event_zone_check_timer >= 5.0:
		_event_zone_check_timer = 0.0
		_tick_event_zones()
		_check_player_in_event_zone()

# ── Socket wiring ──────────────────────────────────────────────────────────────

func _connect_socket_events() -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket == null:
		push_warning("[LandOwnershipService] SocketIOClient not found.")
		return

	socket.on_event("land_blocks_snapshot",   _on_land_blocks_snapshot)
	socket.on_event("land_block_updated",     _on_land_block_updated)
	socket.on_event("land_claim_result",      _on_land_claim_result)
	socket.on_event("land_release_result",    _on_land_release_result)
	socket.on_event("land_leaderboard",       _on_leaderboard_data)
	socket.on_event("event_zones_update",     _on_event_zones_update)
	socket.on_event("decoration_streak_ack",  _on_decoration_streak_ack)
	socket.on_event("player_balance_update",  _on_player_balance_update)

	# Also hook NetworkManager's world_entered to seed local state.
	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.world_entered.connect(_on_world_entered)

# ── Server event handlers ──────────────────────────────────────────────────────

func _on_world_entered(data: Dictionary) -> void:
	if data.has("player"):
		var p: Dictionary = data.player
		local_player_id   = p.get("id", "")
		local_player_name = p.get("username", "")
		quant_balance      = int(p.get("quantBalance", 0))

		if p.has("ownedBlockIds"):
			owned_block_ids = p.ownedBlockIds.duplicate()

	if data.has("districts"):
		_load_districts(data.districts)

	if data.has("landBlocks"):
		_ingest_block_list(data.landBlocks)

	if data.has("eventZones"):
		_ingest_event_zones(data.eventZones)

	# Kick off leaderboard immediately.
	request_leaderboard()
	emit_signal("owned_blocks_changed", owned_block_ids)

func _on_land_blocks_snapshot(block_list: Array) -> void:
	_ingest_block_list(block_list)

func _on_land_block_updated(block_data: Dictionary) -> void:
	var bid: String = block_data.get("id", "")
	if bid == "":
		return
	var old_owner: String = blocks.get(bid, {}).get("owner_id", "")
	_merge_block(block_data)

	# Check for neighborhood drama: a rival claimed a block next to one we own.
	if block_data.get("owner_id", "") != "" \
			and block_data.get("owner_id", "") != local_player_id \
			and old_owner != block_data.get("owner_id", ""):
		_check_neighborhood_drama(bid, block_data)

	emit_signal("blocks_updated", [bid])

func _on_land_claim_result(result: Dictionary) -> void:
	var success: bool   = result.get("success", false)
	var bid: String     = result.get("blockId", "")
	var reason: String  = result.get("reason", "")

	if success and bid != "" and not owned_block_ids.has(bid):
		owned_block_ids.append(bid)
		emit_signal("owned_blocks_changed", owned_block_ids)

	emit_signal("claim_result", success, bid, reason)

func _on_land_release_result(result: Dictionary) -> void:
	var success: bool   = result.get("success", false)
	var bid: String     = result.get("blockId", "")
	var reason: String  = result.get("reason", "")

	if success and bid != "":
		owned_block_ids.erase(bid)
		emit_signal("owned_blocks_changed", owned_block_ids)

	emit_signal("release_result", success, bid, reason)

func _on_leaderboard_data(data: Array) -> void:
	leaderboard = data.duplicate()
	emit_signal("leaderboard_updated", leaderboard)

func _on_event_zones_update(zones: Array) -> void:
	_ingest_event_zones(zones)

func _on_decoration_streak_ack(data: Dictionary) -> void:
	var bid: String   = data.get("blockId", "")
	var streak: int   = int(data.get("streak", 0))
	var gold: bool    = streak >= GOLD_GLOW_STREAK

	if bid != "" and blocks.has(bid):
		blocks[bid]["decoration_streak"] = streak
		blocks[bid]["has_gold_glow"]     = gold
		emit_signal("blocks_updated", [bid])

	emit_signal("decoration_streak_updated", bid, streak, gold)

func _on_player_balance_update(data: Dictionary) -> void:
	quant_balance = int(data.get("balance", quant_balance))

# ── Public API ─────────────────────────────────────────────────────────────────

## Attempt to claim an unclaimed block. The server validates token balance.
func claim_block(block_id: String) -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket == null:
		emit_signal("claim_result", false, block_id, "Not connected.")
		return

	socket.emit_event("land_claim_block", {"blockId": block_id,
			"playerId": local_player_id})
	print("[LandOwnershipService] Claim requested: ", block_id)

## Release (put back on the market) a block the local player owns.
func release_block(block_id: String) -> void:
	if not owned_block_ids.has(block_id):
		emit_signal("release_result", false, block_id, "You do not own this block.")
		return

	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket == null:
		emit_signal("release_result", false, block_id, "Not connected.")
		return

	socket.emit_event("land_release_block", {"blockId": block_id,
			"playerId": local_player_id})

## List a block for sale at a custom price (tokens).
func list_block_for_sale(block_id: String, price: int) -> void:
	if not owned_block_ids.has(block_id):
		push_warning("[LandOwnershipService] Cannot list block we don't own.")
		return

	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("land_list_for_sale", {"blockId": block_id,
				"price": price, "playerId": local_player_id})

## Report a decoration update for today — increments the streak server-side.
func report_decoration_update(block_id: String) -> void:
	if not owned_block_ids.has(block_id):
		return

	var today: String = Time.get_date_string_from_system()
	if today == _last_streak_date:
		push_warning("[LandOwnershipService] Streak already reported today.")
		return

	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		_last_streak_date = today
		socket.emit_event("land_decoration_update", {"blockId": block_id,
				"playerId": local_player_id,
				"date": today})

## Request the current city leaderboard from the server.
func request_leaderboard() -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("land_get_leaderboard", {})

## Get a block's data dictionary by id. Returns empty dict if unknown.
func get_block(block_id: String) -> Dictionary:
	return blocks.get(block_id, {})

## Returns true if the local player owns block_id.
func is_owner(block_id: String) -> bool:
	return owned_block_ids.has(block_id)

## Returns the claim cost in Quant tokens for a specific block.
func get_claim_cost(block_id: String) -> int:
	var block: Dictionary = blocks.get(block_id, {})
	if block.is_empty():
		return BASE_CLAIM_COST
	if block.get("is_for_sale", false) and block.get("sale_price", 0) > 0:
		return int(block.sale_price)
	var dist_id: String = block.get("district_id", "")
	var mult: float = districts.get(dist_id, {}).get("multiplier", 1.0)
	return int(BASE_CLAIM_COST * mult)

## Returns an Array of block Dictionaries adjacent (N/S/E/W) to block_id.
func get_adjacent_blocks(block_id: String) -> Array:
	var block: Dictionary = blocks.get(block_id, {})
	if block.is_empty():
		return []
	var gx: int = int(block.get("grid_x", 0))
	var gz: int = int(block.get("grid_z", 0))
	var neighbors: Array = []
	for delta in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nb_id: String = _make_block_id(gx + delta.x, gz + delta.y)
		if blocks.has(nb_id):
			neighbors.append(blocks[nb_id])
	return neighbors

## Returns all blocks owned by the local player as an Array of Dictionaries.
func get_owned_blocks() -> Array:
	var result: Array = []
	for bid in owned_block_ids:
		if blocks.has(bid):
			result.append(blocks[bid])
	return result

## Returns the block_id string for a given grid position.
func get_block_id_at(grid_x: int, grid_z: int) -> String:
	return _make_block_id(grid_x, grid_z)

## Returns whether the local player is currently inside any active event zone
## (based on world-space position).
func get_current_event_zone(world_pos: Vector3) -> Dictionary:
	for zone in active_event_zones:
		var zx: float = float(zone.get("position_x", 0.0))
		var zz: float = float(zone.get("position_z", 0.0))
		var radius: float = float(zone.get("radius", 30.0))
		var dist_sq: float = (world_pos.x - zx) * (world_pos.x - zx) \
				+ (world_pos.z - zz) * (world_pos.z - zz)
		if dist_sq <= radius * radius:
			return zone
	return {}

# ── Internal helpers ───────────────────────────────────────────────────────────

func _load_districts(dist_list: Array) -> void:
	districts.clear()
	for d in dist_list:
		var did: String = d.get("id", "")
		if did != "":
			districts[did] = d

func _ingest_block_list(block_list: Array) -> void:
	var changed_ids: Array = []
	for b in block_list:
		var bid: String = _resolve_block_id(b)
		if bid != "":
			_merge_block(b)
			changed_ids.append(bid)
	if changed_ids.size() > 0:
		emit_signal("blocks_updated", changed_ids)

func _merge_block(data: Dictionary) -> void:
	var bid: String = _resolve_block_id(data)
	if bid == "":
		return

	if not blocks.has(bid):
		blocks[bid] = {}

	var b: Dictionary = blocks[bid]
	b["id"]               = bid
	b["grid_x"]           = int(data.get("gridX",  data.get("grid_x", 0)))
	b["grid_z"]           = int(data.get("gridZ",  data.get("grid_z", 0)))
	b["district_id"]      = data.get("districtId", data.get("district_id", "unknown"))
	b["owner_id"]         = data.get("ownerId",    data.get("owner_id", ""))
	b["owner_name"]       = data.get("ownerName",  data.get("owner_name", ""))
	b["claim_time_unix"]  = int(data.get("claimTime", data.get("claim_time_unix", 0)))
	b["last_visit_unix"]  = int(data.get("lastVisit", data.get("last_visit_unix", 0)))
	b["decoration_streak"]= int(data.get("decorationStreak",
			data.get("decoration_streak", 0)))
	b["has_gold_glow"]    = bool(data.get("hasGoldGlow",
			data.get("has_gold_glow", false)))
	b["is_for_sale"]      = bool(data.get("isForSale",
			data.get("is_for_sale", b.get("owner_id", "") == "")))
	b["sale_price"]       = int(data.get("salePrice", data.get("sale_price", 0)))
	b["is_event_zone"]    = bool(data.get("isEventZone",
			data.get("is_event_zone", false)))
	b["rent_slots"]       = int(data.get("rentSlots", data.get("rent_slots", 2)))
	b["active_tenants"]   = int(data.get("activeTenants",
			data.get("active_tenants", 0)))
	b["weekly_income"]    = int(data.get("weeklyIncome",
			data.get("weekly_income", 0)))
	b["decay_stage"]      = int(data.get("decayStage",
			data.get("decay_stage", 0)))

func _resolve_block_id(data: Dictionary) -> String:
	if data.has("id"):
		return str(data.id)
	var gx = data.get("gridX", data.get("grid_x", null))
	var gz = data.get("gridZ", data.get("grid_z", null))
	if gx != null and gz != null:
		return _make_block_id(int(gx), int(gz))
	return ""

func _make_block_id(gx: int, gz: int) -> String:
	return "%d_%d" % [gx, gz]

func _ingest_event_zones(zones: Array) -> void:
	active_event_zones.clear()
	var now_unix: int = int(Time.get_unix_time_from_system())
	for z in zones:
		var exp: int = int(z.get("expiresUnix", z.get("expires_unix", 0)))
		if exp == 0 or exp > now_unix:
			active_event_zones.append({
				"zone_id":     z.get("zoneId",     z.get("zone_id", "")),
				"name":        z.get("name",        "Event Zone"),
				"description": z.get("description", ""),
				"expires_unix":exp,
				"reward_tokens":int(z.get("rewardTokens", z.get("reward_tokens", 0))),
				"position_x":  float(z.get("posX",  z.get("position_x", 0.0))),
				"position_z":  float(z.get("posZ",  z.get("position_z", 0.0))),
				"radius":      float(z.get("radius", 30.0)),
				"is_visited":  bool(z.get("isVisited", z.get("is_visited", false))),
			})
	emit_signal("event_zones_updated", active_event_zones)

func _tick_event_zones() -> void:
	var now_unix: int = int(Time.get_unix_time_from_system())
	var dirty: bool = false
	var i: int = active_event_zones.size() - 1
	while i >= 0:
		var z: Dictionary = active_event_zones[i]
		var exp: int = int(z.get("expires_unix", 0))
		if exp > 0 and now_unix >= exp:
			active_event_zones.remove_at(i)
			dirty = true
		i -= 1
	if dirty:
		emit_signal("event_zones_updated", active_event_zones)

func _check_player_in_event_zone() -> void:
	var player: Node3D = get_tree().root.find_child("Player", true, false) as Node3D
	if player == null:
		return
	var pos: Vector3 = player.global_position
	var zone: Dictionary = get_current_event_zone(pos)
	if not zone.is_empty() and not zone.get("is_visited", false):
		zone["is_visited"] = true
		emit_signal("event_zone_entered", zone)
		var socket: Node = get_node_or_null("/root/SocketIOClient")
		if socket:
			socket.emit_event("land_event_zone_visit", {
				"zoneId":   zone.get("zone_id", ""),
				"playerId": local_player_id,
			})

func _check_neighborhood_drama(new_bid: String, block_data: Dictionary) -> void:
	var rival_id:   String = block_data.get("owner_id", "")
	var rival_name: String = block_data.get("owner_name", "Stranger")

	for owned_bid in owned_block_ids:
		var adj_ids: Array = get_adjacent_blocks(owned_bid)
		for adj in adj_ids:
			if adj.get("id", "") == new_bid:
				var district: String = block_data.get("district_id", "the district")
				var msg: String = (
					"⚠️  %s just claimed Block %s in %s — right next to yours!\n"
					% [rival_name, new_bid, district]
					+ "Defend your territory with better decorations!"
				)
				emit_signal("neighborhood_drama", owned_bid, new_bid,
						rival_name, msg)
				print("[LandOwnershipService] DRAMA: ", msg)
				return
