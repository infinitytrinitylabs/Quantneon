## RentEconomy — Virtual Real Estate: Passive Rent Income & Tenant Management
##
## Handles:
##   • Rent slot management — landowners open slots on their blocks; other
##     players place shops or billboards and pay weekly rent in Quant tokens.
##   • Passive income tracking — server pushes rent payouts; this service
##     caches the data and emits signals for the UI.
##   • Tenant placement requests — tenants send "place shop/billboard" events;
##     server validates ownership and deducts from the tenant's balance.
##   • Rent rate negotiation — owner can set a custom rent per slot.
##   • Income history — last 30 payout events stored locally for the ledger UI.
##
## Dependencies (autoloads):
##   SocketIOClient, LandOwnershipService

extends Node

# ── Constants ──────────────────────────────────────────────────────────────────

## Default weekly rent (Quant tokens) for a standard commercial slot.
const DEFAULT_RENT_PER_SLOT: int = 100

## Maximum weekly rent an owner may charge per slot.
const MAX_RENT_PER_SLOT: int = 5000

## Maximum commercial tenants per block (mirrors server cap).
const MAX_TENANTS_PER_BLOCK: int = 4

## Payout history window kept in memory.
const INCOME_HISTORY_MAX: int = 30

## Tenant slot types available for placement on owned land.
const SLOT_TYPE_SHOP: String      = "shop"
const SLOT_TYPE_BILLBOARD: String = "billboard"
const SLOT_TYPE_KIOSK: String     = "kiosk"

# ── State ──────────────────────────────────────────────────────────────────────

## Rent slots keyed by block_id → Array of slot Dictionaries.
## Each slot: {slot_id, block_id, type, tenant_id, tenant_name,
##             weekly_rent, placed_at_unix, is_occupied, custom_label}
var rent_slots: Dictionary = {}

## Accumulated income keyed by block_id → int (lifetime earned, from server).
var block_lifetime_income: Dictionary = {}

## Pending income (unpaid, queued server-side) per block_id → int.
var block_pending_income: Dictionary = {}

## Total balance earned this session (across all owned blocks).
var session_income: int = 0

## Income history: Array of {block_id, tenant_name, amount, timestamp_unix, type}.
var income_history: Array = []

## Local player id (read from LandOwnershipService).
var _local_player_id: String = ""

# ── Signals ───────────────────────────────────────────────────────────────────

## Emitted when rent slot data for one or more blocks is refreshed.
signal rent_slots_updated(block_id: String, slots: Array)

## Emitted when a rent payout is received.
signal rent_payout_received(block_id: String, amount: int, total_pending: int)

## Emitted when a tenant placement attempt resolves.
signal tenant_placement_result(success: bool, block_id: String, slot_id: String,
		reason: String)

## Emitted when a tenant vacates a slot (timeout or manual eviction).
signal tenant_vacated(block_id: String, slot_id: String, tenant_name: String)

## Emitted when the owner changes the rent rate for a slot.
signal rent_rate_changed(block_id: String, slot_id: String, new_rate: int)

## Emitted when cumulative income summary data updates.
signal income_summary_updated(summary: Dictionary)

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_connect_socket_events()
	print("[RentEconomy] Ready.")

# ── Socket wiring ──────────────────────────────────────────────────────────────

func _connect_socket_events() -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket == null:
		push_warning("[RentEconomy] SocketIOClient not found.")
		return

	socket.on_event("rent_slots_snapshot",      _on_rent_slots_snapshot)
	socket.on_event("rent_slot_updated",        _on_rent_slot_updated)
	socket.on_event("rent_payout",              _on_rent_payout)
	socket.on_event("tenant_placement_result",  _on_tenant_placement_result)
	socket.on_event("tenant_vacated",           _on_tenant_vacated)
	socket.on_event("rent_rate_ack",            _on_rent_rate_ack)
	socket.on_event("income_summary",           _on_income_summary)

	var nm: Node = get_node_or_null("/root/NetworkManager")
	if nm:
		nm.world_entered.connect(_on_world_entered)

# ── Server event handlers ──────────────────────────────────────────────────────

func _on_world_entered(data: Dictionary) -> void:
	if data.has("player"):
		_local_player_id = data.player.get("id", "")

	if data.has("rentSlots"):
		_ingest_slots_list(data.rentSlots)

	if data.has("incomeData"):
		_ingest_income_data(data.incomeData)

func _on_rent_slots_snapshot(payload: Array) -> void:
	_ingest_slots_list(payload)

func _on_rent_slot_updated(slot_data: Dictionary) -> void:
	var bid: String  = slot_data.get("blockId", slot_data.get("block_id", ""))
	var sid: String  = slot_data.get("slotId",  slot_data.get("slot_id", ""))
	if bid == "" or sid == "":
		return

	if not rent_slots.has(bid):
		rent_slots[bid] = []

	var found: bool = false
	for i in range(rent_slots[bid].size()):
		if rent_slots[bid][i].get("slot_id", "") == sid:
			rent_slots[bid][i] = _normalise_slot(slot_data)
			found = true
			break
	if not found:
		rent_slots[bid].append(_normalise_slot(slot_data))

	emit_signal("rent_slots_updated", bid, rent_slots[bid])

func _on_rent_payout(data: Dictionary) -> void:
	var bid: String    = data.get("blockId", data.get("block_id", ""))
	var amount: int    = int(data.get("amount", 0))
	var tenant: String = data.get("tenantName", data.get("tenant_name", "tenant"))

	session_income += amount
	block_lifetime_income[bid] = int(block_lifetime_income.get(bid, 0)) + amount
	block_pending_income[bid]  = 0

	_record_income_event(bid, tenant, amount, SLOT_TYPE_SHOP)
	emit_signal("rent_payout_received", bid, amount,
			int(block_pending_income.get(bid, 0)))
	_emit_income_summary()

func _on_tenant_placement_result(result: Dictionary) -> void:
	var success: bool   = result.get("success", false)
	var bid: String     = result.get("blockId", result.get("block_id", ""))
	var sid: String     = result.get("slotId",  result.get("slot_id", ""))
	var reason: String  = result.get("reason", "")
	emit_signal("tenant_placement_result", success, bid, sid, reason)

func _on_tenant_vacated(data: Dictionary) -> void:
	var bid: String    = data.get("blockId", data.get("block_id", ""))
	var sid: String    = data.get("slotId",  data.get("slot_id", ""))
	var t_name: String = data.get("tenantName", data.get("tenant_name", ""))

	if rent_slots.has(bid):
		for slot in rent_slots[bid]:
			if slot.get("slot_id", "") == sid:
				slot["is_occupied"]  = false
				slot["tenant_id"]    = ""
				slot["tenant_name"]  = ""
				slot["placed_at_unix"] = 0
				break
		emit_signal("rent_slots_updated", bid, rent_slots[bid])

	emit_signal("tenant_vacated", bid, sid, t_name)

func _on_rent_rate_ack(data: Dictionary) -> void:
	var bid: String  = data.get("blockId", data.get("block_id", ""))
	var sid: String  = data.get("slotId",  data.get("slot_id", ""))
	var rate: int    = int(data.get("weeklyRent", data.get("weekly_rent", 0)))

	if rent_slots.has(bid):
		for slot in rent_slots[bid]:
			if slot.get("slot_id", "") == sid:
				slot["weekly_rent"] = rate
				break
		emit_signal("rent_slots_updated", bid, rent_slots[bid])

	emit_signal("rent_rate_changed", bid, sid, rate)

func _on_income_summary(data: Dictionary) -> void:
	var bid: String = data.get("blockId", data.get("block_id", ""))
	if bid != "":
		block_lifetime_income[bid] = int(data.get("lifetime", 0))
		block_pending_income[bid]  = int(data.get("pending", 0))
	_emit_income_summary()

# ── Public API ─────────────────────────────────────────────────────────────────

## Open a new rent slot on a block we own. type = SLOT_TYPE_*.
func open_rent_slot(block_id: String, slot_type: String,
		weekly_rent: int = DEFAULT_RENT_PER_SLOT) -> void:
	if not _is_owner(block_id):
		push_warning("[RentEconomy] Cannot open slot on block we don't own.")
		return

	var clamped_rent: int = clamp(weekly_rent, 1, MAX_RENT_PER_SLOT)
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_open_slot", {
			"blockId":    block_id,
			"slotType":   slot_type,
			"weeklyRent": clamped_rent,
			"playerId":   _local_player_id,
		})

## Close (remove) a rent slot on a block we own, evicting the current tenant.
func close_rent_slot(block_id: String, slot_id: String) -> void:
	if not _is_owner(block_id):
		return

	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_close_slot", {
			"blockId":  block_id,
			"slotId":   slot_id,
			"playerId": _local_player_id,
		})

## Place a shop or billboard on someone else's block as a tenant.
func place_tenant(block_id: String, slot_id: String,
		slot_type: String, custom_label: String = "") -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_place_tenant", {
			"blockId":     block_id,
			"slotId":      slot_id,
			"slotType":    slot_type,
			"customLabel": custom_label,
			"playerId":    _local_player_id,
		})

## Evict a tenant from a slot on an owned block.
func evict_tenant(block_id: String, slot_id: String) -> void:
	if not _is_owner(block_id):
		return

	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_evict_tenant", {
			"blockId":  block_id,
			"slotId":   slot_id,
			"playerId": _local_player_id,
		})

## Update the weekly rent charged for a slot.
func set_rent_rate(block_id: String, slot_id: String, new_rate: int) -> void:
	if not _is_owner(block_id):
		return

	var clamped: int = clamp(new_rate, 1, MAX_RENT_PER_SLOT)
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_set_rate", {
			"blockId":    block_id,
			"slotId":     slot_id,
			"weeklyRent": clamped,
			"playerId":   _local_player_id,
		})

## Request updated income summary from the server for a specific block.
func request_income_summary(block_id: String) -> void:
	var socket: Node = get_node_or_null("/root/SocketIOClient")
	if socket:
		socket.emit_event("rent_get_income_summary", {
			"blockId":  block_id,
			"playerId": _local_player_id,
		})

## Returns an Array of slot Dictionaries for the given block_id.
func get_slots_for_block(block_id: String) -> Array:
	return rent_slots.get(block_id, [])

## Returns how many open (unoccupied) slots exist on a block.
func get_open_slot_count(block_id: String) -> int:
	var count: int = 0
	for slot in get_slots_for_block(block_id):
		if not slot.get("is_occupied", false):
			count += 1
	return count

## Returns the pending payout amount for a block.
func get_pending_income(block_id: String) -> int:
	return int(block_pending_income.get(block_id, 0))

## Returns total income earned on a block (lifetime).
func get_lifetime_income(block_id: String) -> int:
	return int(block_lifetime_income.get(block_id, 0))

## Returns the last INCOME_HISTORY_MAX payout events.
func get_income_history() -> Array:
	return income_history.duplicate()

## Returns a summary Dictionary:
##   total_session_income, owned_blocks_with_slots, total_active_tenants,
##   total_pending_payout, highest_earning_block_id
func get_income_summary() -> Dictionary:
	var total_pending: int = 0
	var total_tenants: int = 0
	var blocks_with_slots: int = 0
	var highest_bid: String = ""
	var highest_val: int = 0

	for bid in block_lifetime_income:
		var inc: int = int(block_lifetime_income[bid])
		if inc > highest_val:
			highest_val = inc
			highest_bid = bid

	for bid in block_pending_income:
		total_pending += int(block_pending_income[bid])

	for bid in rent_slots:
		if rent_slots[bid].size() > 0:
			blocks_with_slots += 1
		for slot in rent_slots[bid]:
			if slot.get("is_occupied", false):
				total_tenants += 1

	return {
		"total_session_income":      session_income,
		"owned_blocks_with_slots":   blocks_with_slots,
		"total_active_tenants":      total_tenants,
		"total_pending_payout":      total_pending,
		"highest_earning_block_id":  highest_bid,
	}

# ── Internal helpers ───────────────────────────────────────────────────────────

func _is_owner(block_id: String) -> bool:
	var los: Node = get_node_or_null("/root/LandOwnershipService")
	if los and los.has_method("is_owner"):
		return los.is_owner(block_id)
	return false

func _ingest_slots_list(payload: Array) -> void:
	for slot_data in payload:
		var bid: String = slot_data.get("blockId",
				slot_data.get("block_id", ""))
		if bid == "":
			continue
		if not rent_slots.has(bid):
			rent_slots[bid] = []

		var sid: String = slot_data.get("slotId",
				slot_data.get("slot_id", ""))
		var found: bool = false
		for i in range(rent_slots[bid].size()):
			if rent_slots[bid][i].get("slot_id", "") == sid:
				rent_slots[bid][i] = _normalise_slot(slot_data)
				found = true
				break
		if not found:
			rent_slots[bid].append(_normalise_slot(slot_data))

	for bid in rent_slots:
		emit_signal("rent_slots_updated", bid, rent_slots[bid])

func _normalise_slot(data: Dictionary) -> Dictionary:
	return {
		"slot_id":       data.get("slotId",       data.get("slot_id",       "")),
		"block_id":      data.get("blockId",       data.get("block_id",      "")),
		"type":          data.get("slotType",      data.get("type",          SLOT_TYPE_SHOP)),
		"tenant_id":     data.get("tenantId",      data.get("tenant_id",     "")),
		"tenant_name":   data.get("tenantName",    data.get("tenant_name",   "")),
		"weekly_rent":   int(data.get("weeklyRent",data.get("weekly_rent",   DEFAULT_RENT_PER_SLOT))),
		"placed_at_unix":int(data.get("placedAt",  data.get("placed_at_unix",0))),
		"is_occupied":   bool(data.get("isOccupied",data.get("is_occupied",  false))),
		"custom_label":  data.get("customLabel",   data.get("custom_label",  "")),
	}

func _ingest_income_data(income_list: Array) -> void:
	for entry in income_list:
		var bid: String = entry.get("blockId", entry.get("block_id", ""))
		if bid != "":
			block_lifetime_income[bid] = int(entry.get("lifetime", 0))
			block_pending_income[bid]  = int(entry.get("pending",  0))
	_emit_income_summary()

func _record_income_event(block_id: String, tenant_name: String,
		amount: int, event_type: String) -> void:
	income_history.push_front({
		"block_id":       block_id,
		"tenant_name":    tenant_name,
		"amount":         amount,
		"timestamp_unix": int(Time.get_unix_time_from_system()),
		"type":           event_type,
	})
	if income_history.size() > INCOME_HISTORY_MAX:
		income_history.resize(INCOME_HISTORY_MAX)

func _emit_income_summary() -> void:
	emit_signal("income_summary_updated", get_income_summary())
