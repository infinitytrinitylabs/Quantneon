## NPCEconomy.gd
## Simulated economy system for NPCs in Neo City.
## Handles shop inventory, dynamic pricing, player transactions, and NPC-to-NPC trading.

extends Node

# ── Signals ─────────────────────────────────────────────────────────────────

signal item_sold(item_id: String, quantity: int, price: float, buyer_type: String)
signal item_purchased(item_id: String, quantity: int, price: float, seller_type: String)
signal price_updated(item_id: String, new_price: float)
signal trade_completed(partner_id: String, traded_items: Dictionary)
signal shop_opened(npc_id: String)
signal shop_closed(npc_id: String)
signal stock_depleted(item_id: String)
signal stock_restocked(item_id: String, quantity: int)

# ── Shop Identity ────────────────────────────────────────────────────────────

@export var shop_owner_id: String = ""
@export var shop_name: String = ""
@export var shop_type: String = "general"    # general, weapons, medical, food, tech, black_market
@export var district: String = "central"
@export var base_markup: float = 0.2         # 20% over base price

# ── Inventory ─────────────────────────────────────────────────────────────────

## items: item_id -> { name, category, base_price, stock, max_stock, is_illegal }
var inventory: Dictionary = {}

## pending_orders: Array of { item_id, quantity, source_npc_id, arrival_hour }
var pending_orders: Array = []

# ── Dynamic Pricing ───────────────────────────────────────────────────────────

## price_modifiers: item_id -> current modifier (1.0 = base price)
var price_modifiers: Dictionary = {}

const MIN_PRICE_MODIFIER: float = 0.5
const MAX_PRICE_MODIFIER: float = 3.5

## Tracks recent sales for supply/demand calculations
## recent_sales: item_id -> { count_sold, count_bought, last_cycle_count }
var recent_sales: Dictionary = {}

var nearby_player_count: int = 0
var district_demand_multiplier: float = 1.0
var current_hour: float = 12.0

# ── Financial Records ─────────────────────────────────────────────────────────

var total_credits_earned: float = 0.0
var total_credits_spent: float = 0.0
var transaction_log: Array = []    # last 100 transactions
const MAX_TRANSACTION_LOG: int = 100

# ── NPC-to-NPC Trading ────────────────────────────────────────────────────────

## trade_partners: npc_id -> { last_trade_hour, relationship_score, trade_count }
var trade_partners: Dictionary = {}
var _trade_cooldown: float = 0.0
const TRADE_COOLDOWN_MAX: float = 300.0   # 5 minutes between NPC trades

# ── Restock ───────────────────────────────────────────────────────────────────

var _restock_timer: float = 0.0
const RESTOCK_INTERVAL: float = 120.0    # seconds between restock checks
var restock_budget: float = 1000.0

# ── Shop Status ───────────────────────────────────────────────────────────────

var is_open: bool = true
var open_hour: float = 8.0
var close_hour: float = 20.0
var special_event_open: bool = false    # forced open during FOMO events

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_initialize_inventory_by_type()
	_initialize_price_modifiers()
	if shop_name == "":
		shop_name = _generate_shop_name()

func _process(delta: float) -> void:
	_tick_restock(delta)
	_tick_trade_cooldown(delta)
	_update_shop_hours()

# ─────────────────────────────────────────────────────────────────────────────
# Shop Management
# ─────────────────────────────────────────────────────────────────────────────

func open_shop() -> void:
	if is_open:
		return
	is_open = true
	emit_signal("shop_opened", shop_owner_id)

func close_shop() -> void:
	if not is_open:
		return
	is_open = false
	emit_signal("shop_closed", shop_owner_id)

func _update_shop_hours() -> void:
	if special_event_open:
		if not is_open:
			open_shop()
		return
	var should_be_open: bool = current_hour >= open_hour and current_hour < close_hour
	if should_be_open and not is_open:
		open_shop()
	elif not should_be_open and is_open:
		close_shop()

func set_time(hour: float) -> void:
	current_hour = fmod(hour, 24.0)

func set_nearby_player_count(count: int) -> void:
	nearby_player_count = count
	_recalculate_demand_multiplier()

func _recalculate_demand_multiplier() -> void:
	# More players nearby = higher demand = higher prices
	if nearby_player_count <= 2:
		district_demand_multiplier = 1.0
	elif nearby_player_count <= 5:
		district_demand_multiplier = 1.15
	elif nearby_player_count <= 10:
		district_demand_multiplier = 1.35
	elif nearby_player_count <= 20:
		district_demand_multiplier = 1.6
	else:
		district_demand_multiplier = 2.0

# ─────────────────────────────────────────────────────────────────────────────
# Player Transactions
# ─────────────────────────────────────────────────────────────────────────────

func player_buy(player_id: String, item_id: String, quantity: int = 1) -> Dictionary:
	## Returns { success, price_paid, message }
	if not is_open:
		return {"success": false, "price_paid": 0.0, "message": "Shop is closed."}

	if not inventory.has(item_id):
		return {"success": false, "price_paid": 0.0, "message": "Item not in stock."}

	var item = inventory[item_id]
	if item.get("stock", 0) < quantity:
		return {"success": false, "price_paid": 0.0,
			"message": "Only " + str(item.get("stock", 0)) + " in stock."}

	var unit_price: float = get_sell_price(item_id)
	var total_price: float = unit_price * quantity

	# Deduct stock
	item["stock"] -= quantity
	if item["stock"] == 0:
		emit_signal("stock_depleted", item_id)

	# Update sales tracking
	_record_sale(item_id, quantity)

	# Financial tracking
	total_credits_earned += total_price
	_log_transaction({
		"type": "player_buy",
		"item_id": item_id,
		"quantity": quantity,
		"unit_price": unit_price,
		"total": total_price,
		"buyer": player_id,
		"hour": current_hour,
	})

	# Adjust price upward after sale (supply decreased)
	_adjust_price_after_sale(item_id, quantity)

	emit_signal("item_sold", item_id, quantity, total_price, "player")
	return {"success": true, "price_paid": total_price, "message": "Purchased " + str(quantity) + "x " + item.get("name", item_id)}

func player_sell(player_id: String, item_id: String, quantity: int, offered_price: float = -1.0) -> Dictionary:
	## Player sells to the NPC shop. Returns { success, credits_received, message }
	if not is_open:
		return {"success": false, "credits_received": 0.0, "message": "Shop is closed."}

	var buy_price: float = get_buy_price(item_id)
	var total_payout: float = buy_price * quantity

	# Accept or negotiate offered price
	if offered_price > 0.0:
		if offered_price > buy_price * 1.5:
			return {"success": false, "credits_received": 0.0,
				"message": "That price is too high. Best I can do is " + _format_credits(buy_price) + " per unit."}
		total_payout = minf(offered_price * quantity, buy_price * quantity * 1.2)

	# Add to inventory (or create entry)
	if inventory.has(item_id):
		var item = inventory[item_id]
		item["stock"] = mini(item.get("stock", 0) + quantity, item.get("max_stock", 50))
	else:
		inventory[item_id] = {
			"name": item_id.replace("_", " ").capitalize(),
			"category": "misc",
			"base_price": buy_price * 1.3,
			"stock": quantity,
			"max_stock": 20,
			"is_illegal": false,
		}
		price_modifiers[item_id] = 1.0

	# Track purchase
	_record_purchase(item_id, quantity)

	total_credits_spent += total_payout
	_log_transaction({
		"type": "player_sell",
		"item_id": item_id,
		"quantity": quantity,
		"unit_price": buy_price,
		"total": total_payout,
		"seller": player_id,
		"hour": current_hour,
	})

	# Price dips when stock increases
	_adjust_price_after_purchase(item_id, quantity)

	emit_signal("item_purchased", item_id, quantity, total_payout, "player")
	return {"success": true, "credits_received": total_payout,
		"message": "Sold " + str(quantity) + "x " + item_id.replace("_", " ") + " for " + _format_credits(total_payout)}

# ─────────────────────────────────────────────────────────────────────────────
# Price Calculation
# ─────────────────────────────────────────────────────────────────────────────

func get_sell_price(item_id: String) -> float:
	## Price the NPC charges the player to buy
	if not inventory.has(item_id):
		return 0.0
	var base: float = inventory[item_id].get("base_price", 10.0)
	var modifier: float = price_modifiers.get(item_id, 1.0)
	var price: float = base * modifier * district_demand_multiplier * (1.0 + base_markup)

	# Time of day premium (night market prices higher)
	if current_hour >= 22.0 or current_hour < 6.0:
		price *= 1.15

	# Illegal items have additional risk premium
	if inventory[item_id].get("is_illegal", false):
		price *= 1.5

	return snappedf(price, 0.01)

func get_buy_price(item_id: String) -> float:
	## Price the NPC pays the player to sell
	var base: float = 10.0
	if inventory.has(item_id):
		base = inventory[item_id].get("base_price", 10.0)
	var modifier: float = price_modifiers.get(item_id, 1.0)
	# NPC buys at 60% of sell price
	return snappedf(base * modifier * 0.6, 0.01)

func _adjust_price_after_sale(item_id: String, quantity: int) -> void:
	## Prices rise when stock is sold
	if not price_modifiers.has(item_id):
		price_modifiers[item_id] = 1.0
	var delta: float = 0.05 * quantity
	price_modifiers[item_id] = clampf(price_modifiers[item_id] + delta, MIN_PRICE_MODIFIER, MAX_PRICE_MODIFIER)
	emit_signal("price_updated", item_id, get_sell_price(item_id))

func _adjust_price_after_purchase(item_id: String, quantity: int) -> void:
	## Prices fall when stock is added
	if not price_modifiers.has(item_id):
		price_modifiers[item_id] = 1.0
	var delta: float = 0.03 * quantity
	price_modifiers[item_id] = clampf(price_modifiers[item_id] - delta, MIN_PRICE_MODIFIER, MAX_PRICE_MODIFIER)
	emit_signal("price_updated", item_id, get_sell_price(item_id))

func normalize_prices() -> void:
	## Gradually drift prices back toward base (1.0 modifier)
	for item_id in price_modifiers.keys():
		var current: float = price_modifiers[item_id]
		if abs(current - 1.0) < 0.02:
			price_modifiers[item_id] = 1.0
		else:
			price_modifiers[item_id] = lerpf(current, 1.0, 0.01)

# ─────────────────────────────────────────────────────────────────────────────
# Sales Tracking
# ─────────────────────────────────────────────────────────────────────────────

func _record_sale(item_id: String, qty: int) -> void:
	if not recent_sales.has(item_id):
		recent_sales[item_id] = {"count_sold": 0, "count_bought": 0, "last_cycle_count": 0}
	recent_sales[item_id]["count_sold"] += qty

func _record_purchase(item_id: String, qty: int) -> void:
	if not recent_sales.has(item_id):
		recent_sales[item_id] = {"count_sold": 0, "count_bought": 0, "last_cycle_count": 0}
	recent_sales[item_id]["count_bought"] += qty

func get_price_trend(item_id: String) -> String:
	if not price_modifiers.has(item_id):
		return "stable"
	var m: float = price_modifiers[item_id]
	if m >= 1.5:
		return "high"
	elif m >= 1.15:
		return "rising"
	elif m <= 0.7:
		return "low"
	elif m <= 0.85:
		return "falling"
	return "stable"

func get_shop_summary() -> Dictionary:
	var item_count: int = inventory.size()
	var total_stock: int = 0
	var in_stock: int = 0
	for item_id in inventory:
		var s: int = inventory[item_id].get("stock", 0)
		total_stock += s
		if s > 0:
			in_stock += 1
	return {
		"shop_name": shop_name,
		"shop_type": shop_type,
		"item_count": item_count,
		"in_stock": in_stock,
		"total_stock": total_stock,
		"is_open": is_open,
		"price_trend": _overall_price_trend(),
		"total_earned": total_credits_earned,
	}

func _overall_price_trend() -> String:
	if price_modifiers.is_empty():
		return "stable"
	var total: float = 0.0
	for m in price_modifiers.values():
		total += m
	var avg: float = total / price_modifiers.size()
	if avg >= 1.3:
		return "high"
	elif avg >= 1.1:
		return "rising"
	elif avg <= 0.75:
		return "low"
	elif avg <= 0.9:
		return "falling"
	return "stable"

# ─────────────────────────────────────────────────────────────────────────────
# Restock System
# ─────────────────────────────────────────────────────────────────────────────

func _tick_restock(delta: float) -> void:
	_restock_timer += delta
	if _restock_timer >= RESTOCK_INTERVAL:
		_restock_timer = 0.0
		_run_restock_cycle()
		normalize_prices()

func _run_restock_cycle() -> void:
	if restock_budget <= 0.0:
		return

	for item_id in inventory.keys():
		var item = inventory[item_id]
		var stock: int = item.get("stock", 0)
		var max_stock: int = item.get("max_stock", 10)

		if stock < max_stock / 2:
			var restock_qty: int = randi_range(1, max_stock - stock)
			var cost: float = item.get("base_price", 5.0) * restock_qty * 0.4   # wholesale cost

			if cost <= restock_budget:
				item["stock"] = mini(stock + restock_qty, max_stock)
				restock_budget -= cost
				emit_signal("stock_restocked", item_id, restock_qty)
				_adjust_price_after_purchase(item_id, restock_qty)

func add_restock_budget(amount: float) -> void:
	restock_budget = minf(restock_budget + amount, 5000.0)

# ─────────────────────────────────────────────────────────────────────────────
# NPC-to-NPC Trading
# ─────────────────────────────────────────────────────────────────────────────

func _tick_trade_cooldown(delta: float) -> void:
	if _trade_cooldown > 0.0:
		_trade_cooldown -= delta

func can_trade_with_npc() -> bool:
	return _trade_cooldown <= 0.0 and is_open

func initiate_npc_trade(partner_economy: Node) -> Dictionary:
	## Attempt to trade surplus stock with a partner NPC's economy.
	## Returns a summary of what was traded.
	if not can_trade_with_npc():
		return {"success": false, "reason": "cooling down"}
	if partner_economy == null or not partner_economy.has_method("receive_npc_trade"):
		return {"success": false, "reason": "invalid partner"}

	var offer: Dictionary = _build_trade_offer()
	if offer.is_empty():
		return {"success": false, "reason": "nothing to offer"}

	var partner_id: String = partner_economy.shop_owner_id
	var result = partner_economy.receive_npc_trade(shop_owner_id, offer)
	if result.get("accepted", false):
		_apply_trade_result(offer, result)
		_trade_cooldown = TRADE_COOLDOWN_MAX
		_register_trade_partner(partner_id, true)
		var traded = {"offered": offer, "received": result.get("counter_offer", {})}
		emit_signal("trade_completed", partner_id, traded)
		return {"success": true, "traded": traded}

	_register_trade_partner(partner_id, false)
	return {"success": false, "reason": "partner declined"}

func receive_npc_trade(sender_id: String, offer: Dictionary) -> Dictionary:
	## Evaluate and respond to an incoming NPC trade offer.
	var relationship: float = _get_partner_relationship(sender_id)
	var acceptance_threshold: float = 0.3 - (relationship * 0.2)   # better relationship = more likely to accept

	if randf() < acceptance_threshold:
		return {"accepted": false}

	# Build a counter-offer based on what the partner needs and we have surplus of
	var counter: Dictionary = _build_counter_offer(offer)
	_apply_received_trade(offer, counter)
	_register_trade_partner(sender_id, true)
	return {"accepted": true, "counter_offer": counter}

func _build_trade_offer() -> Dictionary:
	## Find items with high stock to offer for trade
	var offer: Dictionary = {}
	for item_id in inventory.keys():
		var item = inventory[item_id]
		var stock: int = item.get("stock", 0)
		var max_stock: int = item.get("max_stock", 10)
		if stock > max_stock * 0.7:
			var offer_qty: int = randi_range(1, int(stock * 0.3))
			offer[item_id] = {"quantity": offer_qty, "unit_value": get_buy_price(item_id)}
	return offer

func _build_counter_offer(incoming: Dictionary) -> Dictionary:
	## Respond with items we have surplus of
	var counter: Dictionary = {}
	for item_id in inventory.keys():
		if item_id in incoming:
			continue
		var item = inventory[item_id]
		var stock: int = item.get("stock", 0)
		var max_stock: int = item.get("max_stock", 10)
		if stock > max_stock * 0.5:
			var qty: int = randi_range(1, int(stock * 0.2))
			counter[item_id] = {"quantity": qty, "unit_value": get_buy_price(item_id)}
	return counter

func _apply_trade_result(offered: Dictionary, result: Dictionary) -> void:
	## Remove offered items, add received items
	for item_id in offered.keys():
		if inventory.has(item_id):
			var qty = offered[item_id].get("quantity", 0)
			inventory[item_id]["stock"] = maxi(0, inventory[item_id].get("stock", 0) - qty)

	var received = result.get("counter_offer", {})
	for item_id in received.keys():
		var qty = received[item_id].get("quantity", 0)
		if inventory.has(item_id):
			inventory[item_id]["stock"] = mini(
				inventory[item_id].get("stock", 0) + qty,
				inventory[item_id].get("max_stock", 50)
			)
		else:
			inventory[item_id] = {
				"name": item_id.replace("_", " ").capitalize(),
				"category": "misc",
				"base_price": received[item_id].get("unit_value", 10.0) * 1.3,
				"stock": qty,
				"max_stock": 20,
				"is_illegal": false,
			}
			price_modifiers[item_id] = 1.0

func _apply_received_trade(incoming: Dictionary, counter: Dictionary) -> void:
	## Add incoming items, remove countered items
	for item_id in incoming.keys():
		var qty = incoming[item_id].get("quantity", 0)
		if inventory.has(item_id):
			inventory[item_id]["stock"] = mini(
				inventory[item_id].get("stock", 0) + qty,
				inventory[item_id].get("max_stock", 50)
			)
		else:
			inventory[item_id] = {
				"name": item_id.replace("_", " ").capitalize(),
				"category": "misc",
				"base_price": incoming[item_id].get("unit_value", 10.0) * 1.3,
				"stock": qty,
				"max_stock": 20,
				"is_illegal": false,
			}
			price_modifiers[item_id] = 1.0

	for item_id in counter.keys():
		if inventory.has(item_id):
			var qty = counter[item_id].get("quantity", 0)
			inventory[item_id]["stock"] = maxi(0, inventory[item_id].get("stock", 0) - qty)

func _get_partner_relationship(partner_id: String) -> float:
	if not trade_partners.has(partner_id):
		return 0.0
	return trade_partners[partner_id].get("relationship_score", 0.0)

func _register_trade_partner(partner_id: String, success: bool) -> void:
	if not trade_partners.has(partner_id):
		trade_partners[partner_id] = {
			"last_trade_hour": current_hour,
			"relationship_score": 0.0,
			"trade_count": 0,
		}
	var record = trade_partners[partner_id]
	record["last_trade_hour"] = current_hour
	record["trade_count"] = record["trade_count"] + 1
	if success:
		record["relationship_score"] = clampf(record["relationship_score"] + 0.1, -1.0, 1.0)
	else:
		record["relationship_score"] = clampf(record["relationship_score"] - 0.05, -1.0, 1.0)

# ─────────────────────────────────────────────────────────────────────────────
# Inventory Initialization
# ─────────────────────────────────────────────────────────────────────────────

func _initialize_inventory_by_type() -> void:
	inventory.clear()
	price_modifiers.clear()
	match shop_type:
		"general":
			_stock_general_store()
		"weapons":
			_stock_weapons_dealer()
		"medical":
			_stock_medical_supplier()
		"food":
			_stock_food_stall()
		"tech":
			_stock_tech_shop()
		"black_market":
			_stock_black_market()
		_:
			_stock_general_store()

func _initialize_price_modifiers() -> void:
	for item_id in inventory.keys():
		if not price_modifiers.has(item_id):
			price_modifiers[item_id] = 1.0 + randf_range(-0.1, 0.1)

func _add_item(item_id: String, name: String, category: String, base_price: float,
		stock: int, max_stock: int, is_illegal: bool = false) -> void:
	inventory[item_id] = {
		"name": name,
		"category": category,
		"base_price": base_price,
		"stock": stock,
		"max_stock": max_stock,
		"is_illegal": is_illegal,
	}

func _stock_general_store() -> void:
	_add_item("water_bottle",     "Water Bottle",      "consumable", 5.0,   15, 30)
	_add_item("energy_bar",       "Energy Bar",        "consumable", 8.0,   10, 20)
	_add_item("stim_pack",        "Stim Pack",         "medical",    35.0,  8,  15)
	_add_item("torch",            "Pocket Torch",      "tool",       12.0,  10, 20)
	_add_item("neon_paint",       "Neon Paint Can",    "cosmetic",   20.0,  5,  10)
	_add_item("data_chip_blank",  "Blank Data Chip",   "tech",       15.0,  12, 25)
	_add_item("street_map",       "Street Map",        "info",       3.0,   20, 40)
	_add_item("duct_tape",        "Duct Tape",         "tool",       6.0,   8,  15)
	_add_item("battery_cell",     "Battery Cell",      "tech",       22.0,  10, 20)
	_add_item("smoke_grenade",    "Smoke Grenade",     "equipment",  45.0,  5,  10)

func _stock_weapons_dealer() -> void:
	_add_item("ammo_pistol_9mm",  "9mm Ammo (50)",     "ammo",       25.0,  10, 20)
	_add_item("ammo_rifle",       "Rifle Rounds (30)", "ammo",       40.0,  8,  15)
	_add_item("ammo_energy",      "Energy Cells (20)", "ammo",       55.0,  6,  12)
	_add_item("laser_sight",      "Laser Sight",       "weapon_mod", 120.0, 4,  8)
	_add_item("suppressor",       "Suppressor",        "weapon_mod", 180.0, 3,  6)
	_add_item("extended_mag",     "Extended Magazine", "weapon_mod", 95.0,  5,  10)
	_add_item("stun_grenade",     "Stun Grenade",      "equipment",  65.0,  4,  8)
	_add_item("frag_grenade",     "Frag Grenade",      "equipment",  80.0,  3,  6)
	_add_item("combat_knife",     "Combat Knife",      "weapon",     150.0, 3,  5)
	_add_item("emp_device",       "EMP Device",        "equipment",  200.0, 2,  4)
	_add_item("black_market_gun", "Unregistered Pistol","weapon",   400.0, 2,  4, true)

func _stock_medical_supplier() -> void:
	_add_item("medkit_basic",     "Basic Medkit",      "medical",    50.0,  8,  15)
	_add_item("medkit_advanced",  "Advanced Medkit",   "medical",    150.0, 4,  8)
	_add_item("antitoxin",        "Antitoxin",         "medical",    75.0,  6,  12)
	_add_item("pain_blocker",     "Pain Blocker",      "medical",    40.0,  10, 20)
	_add_item("stim_pack",        "Combat Stim",       "medical",    35.0,  8,  15)
	_add_item("nano_repair",      "Nano Repair Kit",   "medical",    250.0, 2,  5)
	_add_item("blood_filter",     "Blood Filter",      "medical",    300.0, 2,  4)
	_add_item("neural_stabilizer","Neural Stabilizer", "medical",    180.0, 3,  6)
	_add_item("rad_pills",        "Rad Pills (10)",    "medical",    60.0,  5,  10)
	_add_item("stims_illegal",    "Boosted Stims",     "medical",    120.0, 3,  6, true)

func _stock_food_stall() -> void:
	_add_item("noodle_pack",      "Noodle Pack",       "food",       8.0,   20, 40)
	_add_item("synth_burger",     "Synth Burger",      "food",       12.0,  15, 30)
	_add_item("protein_shake",    "Protein Shake",     "food",       10.0,  12, 25)
	_add_item("water_purified",   "Purified Water",    "food",       6.0,   20, 40)
	_add_item("caffeine_tab",     "Caffeine Tab",      "consumable", 5.0,   15, 30)
	_add_item("street_taco",      "Street Taco",       "food",       7.0,   15, 30)
	_add_item("energy_drink",     "Energy Drink",      "food",       9.0,   12, 25)
	_add_item("nutrition_bar",    "Nutrition Bar",     "food",       4.0,   20, 40)

func _stock_tech_shop() -> void:
	_add_item("data_chip_blank",  "Blank Data Chip",   "tech",       15.0,  10, 20)
	_add_item("encryption_key",   "Encryption Key",    "tech",       200.0, 3,  6)
	_add_item("battery_cell",     "Battery Cell",      "tech",       22.0,  8,  15)
	_add_item("circuit_board",    "Circuit Board",     "tech",       80.0,  5,  10)
	_add_item("neural_interface", "Neural Interface",  "augment",    500.0, 2,  4)
	_add_item("holo_projector",   "Holo Projector",    "tech",       350.0, 2,  4)
	_add_item("signal_jammer",    "Signal Jammer",     "tech",       280.0, 2,  3)
	_add_item("tracker_bug",      "Tracker Bug",       "tech",       120.0, 4,  8)
	_add_item("cyber_eye",        "Cyber Eye Mod",     "augment",    800.0, 1,  2)
	_add_item("emp_shielding",    "EMP Shielding",     "tech",       400.0, 1,  2)

func _stock_black_market() -> void:
	_add_item("black_market_gun",  "Unregistered Pistol","weapon",  400.0, 3,  5, true)
	_add_item("stims_illegal",     "Boosted Stims",    "medical",   120.0, 5,  10, true)
	_add_item("hacked_keycard",    "Hacked Keycard",   "tool",      300.0, 3,  6, true)
	_add_item("stolen_data_chip",  "Stolen Data Chip", "tech",      250.0, 4,  8, true)
	_add_item("black_market_aug",  "Black Market Aug", "augment",  1200.0, 1,  2, true)
	_add_item("fake_id",           "Fake ID",          "document",  500.0, 2,  4, true)
	_add_item("contraband_crate",  "Contraband Crate", "misc",      800.0, 2,  3, true)
	_add_item("military_ammo",     "Military Ammo",    "ammo",      150.0, 4,  8, true)
	_add_item("decryption_tool",   "Decryption Tool",  "tech",      600.0, 2,  4, true)
	_add_item("virus_chip",        "Virus Chip",       "tech",      900.0, 1,  2, true)

# ─────────────────────────────────────────────────────────────────────────────
# Transaction Log
# ─────────────────────────────────────────────────────────────────────────────

func _log_transaction(entry: Dictionary) -> void:
	transaction_log.append(entry)
	while transaction_log.size() > MAX_TRANSACTION_LOG:
		transaction_log.pop_front()

func get_transaction_summary(last_n: int = 10) -> Array:
	var count: int = mini(last_n, transaction_log.size())
	return transaction_log.slice(transaction_log.size() - count)

# ─────────────────────────────────────────────────────────────────────────────
# Shop Name Generation
# ─────────────────────────────────────────────────────────────────────────────

func _generate_shop_name() -> String:
	var prefixes: Array = ["Neo", "Chrome", "Neon", "Dark", "Cyber", "Grid", "Flux", "Static", "Void", "Binary"]
	var suffixes: Array = ["Emporium", "Trading Post", "Exchange", "Depot", "Stash", "Cache", "Bazaar", "Hub", "Market"]
	match shop_type:
		"weapons":
			var names: Array = ["Iron Exchange", "Ballistic Depot", "Combat Cache", "Grid Armory", "Steel Flux Market"]
			return names[randi() % names.size()]
		"medical":
			var names: Array = ["Vital Systems", "NeuroMed Supplies", "Chrome Cross", "Grid Health Depot", "Body Shop Supplies"]
			return names[randi() % names.size()]
		"food":
			var names: Array = ["Neon Bites", "Grid Kitchen", "Street Fuel", "Synth Eats", "Byte Bowl"]
			return names[randi() % names.size()]
		"tech":
			var names: Array = ["Binary Parts", "Circuit Flux", "Core Tech", "Chrome Components", "Data Cache"]
			return names[randi() % names.size()]
		"black_market":
			var names: Array = ["The Gray Node", "Void Exchange", "Shadow Cache", "Static Underground", "The Null Market"]
			return names[randi() % names.size()]
		_:
			return prefixes[randi() % prefixes.size()] + " " + suffixes[randi() % suffixes.size()]

# ─────────────────────────────────────────────────────────────────────────────
# Utility
# ─────────────────────────────────────────────────────────────────────────────

func _format_credits(amount: float) -> String:
	return str(snappedf(amount, 0.01)) + "₵"

func get_item_list() -> Array:
	var result: Array = []
	for item_id in inventory.keys():
		var item = inventory[item_id]
		result.append({
			"id": item_id,
			"name": item.get("name", item_id),
			"sell_price": get_sell_price(item_id),
			"buy_price": get_buy_price(item_id),
			"stock": item.get("stock", 0),
			"category": item.get("category", "misc"),
			"is_illegal": item.get("is_illegal", false),
		})
	return result

func has_item(item_id: String) -> bool:
	return inventory.has(item_id) and inventory[item_id].get("stock", 0) > 0

func get_stock(item_id: String) -> int:
	if not inventory.has(item_id):
		return 0
	return inventory[item_id].get("stock", 0)
