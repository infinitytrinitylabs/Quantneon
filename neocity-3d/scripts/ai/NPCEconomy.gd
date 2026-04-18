## NPCEconomy — Shops, pricing, player trading, and NPC↔NPC trading.
##
## Every NPC with a shop-bearing occupation owns a `Shop` (as a
## Dictionary) created from a template catalogue.  Shops hold:
##   • An inventory Dictionary: item_id -> {price_base, stock, illegal}
##   • Dynamic modifiers: price_mod, district_demand_multiplier,
##     night_premium, illegal_risk_premium.
##   • A transaction log.
## This service is designed to live as an autoload (Node) alongside
## NPCSpawner.  The spawner registers each merchant NPC with an
## `attach_shop_to_npc(npc_id, template_id, ...)` call.

extends Node

const NPCBrain = preload("res://scripts/ai/NPCBrain.gd")

signal shop_registered(npc_id: String, template_id: String)
signal shop_restocked(npc_id: String, item_id: String, new_stock: int)
signal item_purchased(npc_id: String, player_id: String, item_id: String, qty: int, price_total: int)
signal item_sold_to_npc(npc_id: String, player_id: String, item_id: String, qty: int, price_total: int)
signal npc_trade(npc_a: String, npc_b: String, item_id: String, qty: int, price_total: int)

const RESTOCK_INTERVAL_SECS: float = 120.0
const PRICE_MOD_FLOOR: float = 0.5
const PRICE_MOD_CEIL: float = 3.0
const DEMAND_MULT_MIN: float = 1.0
const DEMAND_MULT_MAX: float = 2.0
const DEMAND_PLAYER_CAP: int = 20
const NIGHT_PREMIUM: float = 0.15
const ILLEGAL_RISK_PREMIUM: float = 0.5

const SHOP_GENERAL: String = "general"
const SHOP_WEAPONS: String = "weapons"
const SHOP_MEDICAL: String = "medical"
const SHOP_FOOD: String = "food"
const SHOP_TECH: String = "tech"
const SHOP_BLACK_MARKET: String = "black_market"

# ── Template catalogue ────────────────────────────────────────────────
# Each template lists items this shop type starts with.
# illegal flag contributes a risk premium and gates visibility to
# players with sufficient "underground reputation" (checked by caller).
const _SHOP_TEMPLATES: Dictionary = {
	SHOP_GENERAL: [
		{"id": "ration_pack", "price_base": 15, "stock": 40, "illegal": false},
		{"id": "water_bottle", "price_base": 5, "stock": 80, "illegal": false},
		{"id": "flashlight", "price_base": 25, "stock": 12, "illegal": false},
		{"id": "backpack", "price_base": 120, "stock": 6, "illegal": false},
		{"id": "duct_tape", "price_base": 8, "stock": 50, "illegal": false},
		{"id": "rope_coil", "price_base": 18, "stock": 22, "illegal": false},
		{"id": "lighter", "price_base": 6, "stock": 35, "illegal": false},
		{"id": "map_data", "price_base": 60, "stock": 10, "illegal": false},
	],
	SHOP_WEAPONS: [
		{"id": "pistol_9mm", "price_base": 450, "stock": 8, "illegal": false},
		{"id": "smg", "price_base": 900, "stock": 4, "illegal": false},
		{"id": "shotgun", "price_base": 750, "stock": 5, "illegal": false},
		{"id": "ammo_9mm", "price_base": 35, "stock": 40, "illegal": false},
		{"id": "ammo_12ga", "price_base": 45, "stock": 30, "illegal": false},
		{"id": "combat_knife", "price_base": 85, "stock": 12, "illegal": false},
		{"id": "grenade", "price_base": 250, "stock": 6, "illegal": false},
		{"id": "stun_rod", "price_base": 180, "stock": 7, "illegal": false},
	],
	SHOP_MEDICAL: [
		{"id": "medkit_small", "price_base": 80, "stock": 20, "illegal": false},
		{"id": "medkit_large", "price_base": 220, "stock": 8, "illegal": false},
		{"id": "stimpack", "price_base": 150, "stock": 10, "illegal": false},
		{"id": "painkiller", "price_base": 35, "stock": 30, "illegal": false},
		{"id": "antidote", "price_base": 120, "stock": 12, "illegal": false},
		{"id": "implant_plug", "price_base": 400, "stock": 4, "illegal": false},
		{"id": "combat_stim", "price_base": 300, "stock": 5, "illegal": true},
		{"id": "synth_blood", "price_base": 180, "stock": 8, "illegal": true},
	],
	SHOP_FOOD: [
		{"id": "noodle_bowl", "price_base": 12, "stock": 60, "illegal": false},
		{"id": "skewer", "price_base": 8, "stock": 50, "illegal": false},
		{"id": "synth_protein", "price_base": 22, "stock": 40, "illegal": false},
		{"id": "bao_bun", "price_base": 10, "stock": 45, "illegal": false},
		{"id": "dumpling_box", "price_base": 18, "stock": 30, "illegal": false},
		{"id": "neon_soda", "price_base": 7, "stock": 60, "illegal": false},
		{"id": "sake_flask", "price_base": 40, "stock": 20, "illegal": false},
		{"id": "energy_drink", "price_base": 14, "stock": 40, "illegal": false},
	],
	SHOP_TECH: [
		{"id": "data_shard_1g", "price_base": 50, "stock": 30, "illegal": false},
		{"id": "data_shard_10g", "price_base": 300, "stock": 10, "illegal": false},
		{"id": "decrypter_basic", "price_base": 500, "stock": 4, "illegal": false},
		{"id": "decrypter_adv", "price_base": 1200, "stock": 2, "illegal": true},
		{"id": "drone_parts", "price_base": 220, "stock": 10, "illegal": false},
		{"id": "ai_chipset", "price_base": 800, "stock": 3, "illegal": false},
		{"id": "signal_jammer", "price_base": 400, "stock": 5, "illegal": true},
		{"id": "neural_link", "price_base": 1500, "stock": 2, "illegal": false},
	],
	SHOP_BLACK_MARKET: [
		{"id": "combat_stim", "price_base": 280, "stock": 6, "illegal": true},
		{"id": "neural_hack_tool", "price_base": 1400, "stock": 3, "illegal": true},
		{"id": "contraband_weapon", "price_base": 2200, "stock": 2, "illegal": true},
		{"id": "stolen_datashard", "price_base": 700, "stock": 5, "illegal": true},
		{"id": "black_ice_virus", "price_base": 1800, "stock": 2, "illegal": true},
		{"id": "unlicensed_implant", "price_base": 900, "stock": 3, "illegal": true},
		{"id": "forged_credentials", "price_base": 600, "stock": 4, "illegal": true},
		{"id": "explosive_charge", "price_base": 1100, "stock": 3, "illegal": true},
	],
}

const OCCUPATION_DEFAULT_SHOP: Dictionary = {
	"merchant": SHOP_GENERAL,
	"ripperdoc": SHOP_MEDICAL,
	"bartender": SHOP_FOOD,
	"hacker": SHOP_TECH,
	"guard": SHOP_WEAPONS,
	"civilian": "",
}

# ── State ─────────────────────────────────────────────────────────────

var _shops: Dictionary = {}  # npc_id -> shop dict
var _district_player_counts: Dictionary = {}
var _world_is_night: bool = false
var _restock_budgets: Dictionary = {}  # npc_id -> float credit budget
var _restock_timer: float = 0.0


# ── Public API ────────────────────────────────────────────────────────

func attach_shop_to_npc(npc_id: String, template_id: String, district_id: String = "", starting_budget: float = 500.0) -> Dictionary:
	if npc_id.is_empty():
		return {}
	if not _SHOP_TEMPLATES.has(template_id):
		push_warning("NPCEconomy: unknown shop template '%s'" % template_id)
		return {}
	var inv: Dictionary = {}
	for row in _SHOP_TEMPLATES[template_id]:
		inv[String(row["id"])] = {
			"id": row["id"],
			"price_base": int(row["price_base"]),
			"stock": int(row["stock"]),
			"illegal": bool(row.get("illegal", false)),
			"price_mod": 1.0,
			"last_buy_at": 0.0,
			"last_sell_at": 0.0,
		}
	var shop: Dictionary = {
		"npc_id": npc_id,
		"template_id": template_id,
		"district_id": district_id,
		"inventory": inv,
		"log": [],
		"opened_at": Time.get_unix_time_from_system(),
		"force_open": false,
	}
	_shops[npc_id] = shop
	_restock_budgets[npc_id] = starting_budget
	shop_registered.emit(npc_id, template_id)
	return shop


func auto_attach_shop_by_occupation(npc_id: String, occupation: String, district_id: String = "") -> Dictionary:
	var tmpl: String = String(OCCUPATION_DEFAULT_SHOP.get(occupation, ""))
	if tmpl == "":
		return {}
	return attach_shop_to_npc(npc_id, tmpl, district_id)


func detach_shop(npc_id: String) -> void:
	_shops.erase(npc_id)
	_restock_budgets.erase(npc_id)


func has_shop(npc_id: String) -> bool:
	return _shops.has(npc_id)


func get_shop(npc_id: String) -> Dictionary:
	return _shops.get(npc_id, {})


func set_district_player_count(district_id: String, count: int) -> void:
	_district_player_counts[district_id] = max(0, count)


func set_world_is_night(is_night: bool) -> void:
	_world_is_night = is_night


# ── Pricing ───────────────────────────────────────────────────────────

func _demand_multiplier_for(district_id: String) -> float:
	var count: int = int(_district_player_counts.get(district_id, 0))
	# 0 players -> 1.0, DEMAND_PLAYER_CAP+ players -> 2.0, linear in between.
	var m: float = 1.0 + (float(min(count, DEMAND_PLAYER_CAP)) / float(DEMAND_PLAYER_CAP))
	return clamp(m, DEMAND_MULT_MIN, DEMAND_MULT_MAX)


func price_of(npc_id: String, item_id: String, qty: int = 1) -> int:
	if qty <= 0:
		return 0
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return 0
	var inv: Dictionary = shop["inventory"]
	if not inv.has(item_id):
		return 0
	var item: Dictionary = inv[item_id]
	var base: float = float(item["price_base"]) * float(item["price_mod"])
	base *= _demand_multiplier_for(String(shop.get("district_id", "")))
	if _world_is_night:
		base *= (1.0 + NIGHT_PREMIUM)
	if bool(item.get("illegal", false)):
		base *= (1.0 + ILLEGAL_RISK_PREMIUM)
	return int(round(base * float(qty)))


func stock_of(npc_id: String, item_id: String) -> int:
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return 0
	var inv: Dictionary = shop["inventory"]
	if not inv.has(item_id):
		return 0
	return int(inv[item_id]["stock"])


func list_offerings(npc_id: String, include_illegal: bool = true) -> Array:
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return []
	var out: Array = []
	for id in shop["inventory"].keys():
		var item: Dictionary = shop["inventory"][id]
		if not include_illegal and bool(item.get("illegal", false)):
			continue
		out.append({
			"id": id,
			"price": price_of(npc_id, id, 1),
			"stock": int(item["stock"]),
			"illegal": bool(item.get("illegal", false)),
		})
	return out


# ── Buy / sell ────────────────────────────────────────────────────────

## Player buys `qty` of `item_id` from `npc_id`.  `player_credits` is the
## current balance passed in by the caller; the caller is responsible for
## actually deducting credits in their inventory system.
## Returns { ok, price_total, remaining_stock, reason }.
func player_buy(npc_id: String, player_id: String, item_id: String, qty: int, player_credits: int, negotiate_bonus: float = 0.0) -> Dictionary:
	if qty <= 0:
		return {"ok": false, "reason": "bad_qty"}
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return {"ok": false, "reason": "no_shop"}
	var inv: Dictionary = shop["inventory"]
	if not inv.has(item_id):
		return {"ok": false, "reason": "no_item"}
	var item: Dictionary = inv[item_id]
	if int(item["stock"]) < qty:
		return {"ok": false, "reason": "insufficient_stock", "remaining_stock": int(item["stock"])}
	var price_total: int = price_of(npc_id, item_id, qty)
	price_total = int(round(float(price_total) * clamp(1.0 - negotiate_bonus, 0.6, 1.0)))
	if player_credits < price_total:
		return {"ok": false, "reason": "insufficient_credits", "price_total": price_total}
	item["stock"] = int(item["stock"]) - qty
	item["last_buy_at"] = Time.get_unix_time_from_system()
	# Price rises as stock drops (supply shock).
	var drop_frac: float = float(qty) / max(1.0, float(int(item["stock"]) + qty))
	item["price_mod"] = clamp(float(item["price_mod"]) * (1.0 + drop_frac * 0.15), PRICE_MOD_FLOOR, PRICE_MOD_CEIL)
	inv[item_id] = item
	_log_tx(shop, {
		"kind": "buy",
		"player_id": player_id,
		"item_id": item_id,
		"qty": qty,
		"price_total": price_total,
		"at_unix": Time.get_unix_time_from_system(),
	})
	item_purchased.emit(npc_id, player_id, item_id, qty, price_total)
	return {
		"ok": true,
		"price_total": price_total,
		"remaining_stock": int(item["stock"]),
		"reason": "ok",
	}


func player_sell(npc_id: String, player_id: String, item_id: String, qty: int, offered_unit_price: int = -1) -> Dictionary:
	if qty <= 0:
		return {"ok": false, "reason": "bad_qty"}
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return {"ok": false, "reason": "no_shop"}
	var inv: Dictionary = shop["inventory"]
	var buy_unit: int
	if inv.has(item_id):
		# Buy-back: 50% of current sale price.
		buy_unit = int(round(float(price_of(npc_id, item_id, 1)) * 0.5))
	else:
		buy_unit = 10  # fallback floor price
	if offered_unit_price > 0:
		buy_unit = min(buy_unit, offered_unit_price)
	var total: int = buy_unit * qty
	var budget: float = float(_restock_budgets.get(npc_id, 0.0))
	if budget < float(total):
		return {"ok": false, "reason": "npc_broke", "price_total": total}
	_restock_budgets[npc_id] = budget - float(total)
	if inv.has(item_id):
		var item: Dictionary = inv[item_id]
		item["stock"] = int(item["stock"]) + qty
		item["last_sell_at"] = Time.get_unix_time_from_system()
		item["price_mod"] = clamp(float(item["price_mod"]) * 0.96, PRICE_MOD_FLOOR, PRICE_MOD_CEIL)
		inv[item_id] = item
	else:
		inv[item_id] = {
			"id": item_id,
			"price_base": int(buy_unit * 2),
			"stock": qty,
			"illegal": false,
			"price_mod": 1.0,
			"last_buy_at": 0.0,
			"last_sell_at": Time.get_unix_time_from_system(),
		}
	_log_tx(shop, {
		"kind": "sell",
		"player_id": player_id,
		"item_id": item_id,
		"qty": qty,
		"price_total": total,
		"at_unix": Time.get_unix_time_from_system(),
	})
	item_sold_to_npc.emit(npc_id, player_id, item_id, qty, total)
	return {"ok": true, "price_total": total, "reason": "ok"}


# ── NPC-to-NPC trade ──────────────────────────────────────────────────

func initiate_npc_trade(npc_a: String, npc_b: String, relationship_score: float = 0.0) -> Dictionary:
	if not (_shops.has(npc_a) and _shops.has(npc_b)):
		return {"ok": false, "reason": "no_shops"}
	if npc_a == npc_b:
		return {"ok": false, "reason": "same_npc"}
	# Probability of acceptance is relationship-weighted.
	var accept_chance: float = clamp(0.45 + relationship_score * 0.35, 0.1, 0.95)
	if randf() > accept_chance:
		return {"ok": false, "reason": "declined"}
	# Pick the highest-stock item in A's inventory where B's stock < half A's.
	var shop_a: Dictionary = _shops[npc_a]
	var shop_b: Dictionary = _shops[npc_b]
	var best_id: String = ""
	var best_diff: int = 0
	for id in shop_a["inventory"].keys():
		if not shop_b["inventory"].has(id):
			continue
		var sa: int = int(shop_a["inventory"][id]["stock"])
		var sb: int = int(shop_b["inventory"][id]["stock"])
		if sa - sb > best_diff and sa >= 4:
			best_diff = sa - sb
			best_id = id
	if best_id == "":
		return {"ok": false, "reason": "no_surplus"}
	var qty: int = max(1, int(best_diff / 4))
	qty = min(qty, 6)
	var unit_price: int = int(round(float(shop_a["inventory"][best_id]["price_base"]) * 0.6))
	var total: int = unit_price * qty
	# Move stock.
	shop_a["inventory"][best_id]["stock"] = int(shop_a["inventory"][best_id]["stock"]) - qty
	shop_b["inventory"][best_id]["stock"] = int(shop_b["inventory"][best_id]["stock"]) + qty
	# Credits move from B to A.
	_restock_budgets[npc_a] = float(_restock_budgets.get(npc_a, 0.0)) + float(total)
	_restock_budgets[npc_b] = max(0.0, float(_restock_budgets.get(npc_b, 0.0)) - float(total))
	_log_tx(shop_a, {
		"kind": "npc_sell",
		"partner": npc_b,
		"item_id": best_id,
		"qty": qty,
		"price_total": total,
		"at_unix": Time.get_unix_time_from_system(),
	})
	_log_tx(shop_b, {
		"kind": "npc_buy",
		"partner": npc_a,
		"item_id": best_id,
		"qty": qty,
		"price_total": total,
		"at_unix": Time.get_unix_time_from_system(),
	})
	npc_trade.emit(npc_a, npc_b, best_id, qty, total)
	return {"ok": true, "item_id": best_id, "qty": qty, "price_total": total}


# ── Restocking ────────────────────────────────────────────────────────

func _log_tx(shop: Dictionary, tx: Dictionary) -> void:
	shop["log"].append(tx)
	while (shop["log"] as Array).size() > 64:
		(shop["log"] as Array).pop_front()


func _restock_shop(npc_id: String) -> void:
	var shop: Dictionary = _shops.get(npc_id, {})
	if shop.is_empty():
		return
	var budget: float = float(_restock_budgets.get(npc_id, 0.0))
	if budget <= 0.0:
		# Slow refill from "earnings" if no budget: grant 50 credits per tick.
		budget = 50.0
	var inv: Dictionary = shop["inventory"]
	var template: Array = _SHOP_TEMPLATES.get(String(shop["template_id"]), [])
	var refill_map: Dictionary = {}
	for row in template:
		refill_map[String(row["id"])] = int(row["stock"])
	for id in inv.keys():
		var item: Dictionary = inv[id]
		var target: int = int(refill_map.get(id, int(item["stock"])))
		if int(item["stock"]) < target:
			var gap: int = target - int(item["stock"])
			var unit_cost: float = float(item["price_base"]) * 0.5
			var affordable: int = min(gap, int(budget / max(1.0, unit_cost)))
			if affordable > 0:
				item["stock"] = int(item["stock"]) + affordable
				budget -= float(affordable) * unit_cost
				item["price_mod"] = clamp(float(item["price_mod"]) * 0.98, PRICE_MOD_FLOOR, PRICE_MOD_CEIL)
				inv[id] = item
				shop_restocked.emit(npc_id, id, int(item["stock"]))
	_restock_budgets[npc_id] = max(0.0, budget)


func _process(delta: float) -> void:
	_restock_timer += delta
	if _restock_timer >= RESTOCK_INTERVAL_SECS:
		_restock_timer = 0.0
		for npc_id in _shops.keys():
			_restock_shop(npc_id)


# ── Debug / inspection ────────────────────────────────────────────────

func summary() -> Dictionary:
	var total_stock: int = 0
	var total_items: int = 0
	for npc_id in _shops.keys():
		for id in _shops[npc_id]["inventory"].keys():
			total_stock += int(_shops[npc_id]["inventory"][id]["stock"])
			total_items += 1
	return {
		"shops": _shops.size(),
		"items_tracked": total_items,
		"total_stock": total_stock,
		"night": _world_is_night,
		"districts": _district_player_counts.duplicate(),
	}
