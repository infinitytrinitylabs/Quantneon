## PerformanceUpgrades — Engine, Brakes, Suspension, Nitro upgrade system.
## Upgrade tiers: Stock → Sport → Race → Elite.
## Includes spider chart stat rendering and token cost management.

extends Node

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
signal upgrade_purchased(category: String, tier: int)
signal upgrade_applied(category: String, tier: int)
signal stats_changed(stats: Dictionary)
signal insufficient_funds(cost: int, balance: int)
signal tier_visual_applied(tier: int)

# ---------------------------------------------------------------------------
# Upgrade tier constants
# ---------------------------------------------------------------------------
const TIER_STOCK := 0
const TIER_SPORT := 1
const TIER_RACE  := 2
const TIER_ELITE := 3

const TIER_NAMES := ["Stock", "Sport", "Race", "Elite"]

const TIER_COLORS := [
	Color(0.6, 0.6, 0.6),   # Stock  — grey
	Color(0.2, 0.8, 0.2),   # Sport  — green
	Color(0.2, 0.5, 1.0),   # Race   — blue
	Color(1.0, 0.6, 0.0),   # Elite  — gold
]

# ---------------------------------------------------------------------------
# Upgrade categories
# ---------------------------------------------------------------------------
const CAT_ENGINE     := "engine"
const CAT_BRAKES     := "brakes"
const CAT_SUSPENSION := "suspension"
const CAT_NITRO      := "nitro"
const CAT_TURBO      := "turbo"
const CAT_TIRES      := "tires"

const ALL_CATEGORIES := [CAT_ENGINE, CAT_BRAKES, CAT_SUSPENSION, CAT_NITRO, CAT_TURBO, CAT_TIRES]

# ---------------------------------------------------------------------------
# Upgrade definitions
# Multipliers are relative improvements over Stock baseline (1.0)
# ---------------------------------------------------------------------------
const UPGRADE_DATA: Dictionary = {
	CAT_ENGINE: {
		"display_name": "Engine",
		"icon": "res://ui/icons/engine.png",
		"stat_affects": ["speed", "acceleration"],
		TIER_STOCK: {
			"cost": 0,
			"speed_mult": 1.0,
			"accel_mult": 1.0,
			"description": "Factory engine. Reliable but slow.",
		},
		TIER_SPORT: {
			"cost": 500,
			"speed_mult": 1.15,
			"accel_mult": 1.20,
			"description": "Ported and polished. +15% speed, +20% acceleration.",
		},
		TIER_RACE: {
			"cost": 1500,
			"speed_mult": 1.30,
			"accel_mult": 1.40,
			"description": "Race-spec internals. +30% speed, +40% acceleration.",
		},
		TIER_ELITE: {
			"cost": 4000,
			"speed_mult": 1.50,
			"accel_mult": 1.65,
			"description": "Elite hyper-tune. +50% speed, +65% acceleration.",
		},
	},
	CAT_BRAKES: {
		"display_name": "Brakes",
		"icon": "res://ui/icons/brakes.png",
		"stat_affects": ["braking"],
		TIER_STOCK: {
			"cost": 0,
			"brake_mult": 1.0,
			"stop_dist_reduction": 0.0,
			"description": "OEM brake pads. Adequate for street driving.",
		},
		TIER_SPORT: {
			"cost": 400,
			"brake_mult": 1.18,
			"stop_dist_reduction": 0.10,
			"description": "Performance pads and slotted rotors. -10% stopping distance.",
		},
		TIER_RACE: {
			"cost": 1200,
			"brake_mult": 1.32,
			"stop_dist_reduction": 0.25,
			"description": "Race-compound pads and vented rotors. -25% stopping distance.",
		},
		TIER_ELITE: {
			"cost": 3500,
			"brake_mult": 1.45,
			"stop_dist_reduction": 0.40,
			"description": "Carbon-ceramic callipers. -40% stopping distance.",
		},
	},
	CAT_SUSPENSION: {
		"display_name": "Suspension",
		"icon": "res://ui/icons/suspension.png",
		"stat_affects": ["handling"],
		TIER_STOCK: {
			"cost": 0,
			"handling_mult": 1.0,
			"steering_mult": 1.0,
			"description": "Comfort-biased factory suspension.",
		},
		TIER_SPORT: {
			"cost": 450,
			"handling_mult": 1.12,
			"steering_mult": 1.08,
			"description": "Lowered springs with sport dampers. +12% handling.",
		},
		TIER_RACE: {
			"cost": 1400,
			"handling_mult": 1.22,
			"steering_mult": 1.18,
			"description": "Coilover kit with adjustable damping. +22% handling.",
		},
		TIER_ELITE: {
			"cost": 3800,
			"handling_mult": 1.30,
			"steering_mult": 1.28,
			"description": "Active magnetic suspension. +30% handling.",
		},
	},
	CAT_NITRO: {
		"display_name": "Nitro",
		"icon": "res://ui/icons/nitro.png",
		"stat_affects": ["nitro"],
		TIER_STOCK: {
			"cost": 0,
			"boost_mult": 1.0,
			"duration_mult": 1.0,
			"recharge_mult": 1.0,
			"description": "No nitrous. Stock exhaust only.",
		},
		TIER_SPORT: {
			"cost": 600,
			"boost_mult": 1.30,
			"duration_mult": 1.20,
			"recharge_mult": 0.90,
			"description": "Small-shot nitrous kit. +30% boost, +20% duration.",
		},
		TIER_RACE: {
			"cost": 1800,
			"boost_mult": 1.60,
			"duration_mult": 1.55,
			"recharge_mult": 0.75,
			"description": "High-flow nitrous. +60% boost, +55% duration.",
		},
		TIER_ELITE: {
			"cost": 5000,
			"boost_mult": 2.00,
			"duration_mult": 2.00,
			"recharge_mult": 0.50,
			"description": "Twin-stage nitrous with purge valve. Double boost, double duration.",
		},
	},
	CAT_TURBO: {
		"display_name": "Turbo",
		"icon": "res://ui/icons/turbo.png",
		"stat_affects": ["speed", "acceleration"],
		TIER_STOCK: {
			"cost": 0,
			"boost_pressure": 0.0,
			"spool_time": 0.0,
			"description": "Naturally aspirated. No forced induction.",
		},
		TIER_SPORT: {
			"cost": 700,
			"boost_pressure": 0.5,
			"spool_time": 1.2,
			"description": "Single small turbo. +18% peak power.",
		},
		TIER_RACE: {
			"cost": 2200,
			"boost_pressure": 1.0,
			"spool_time": 0.9,
			"description": "Single large turbo. +35% peak power, faster spool.",
		},
		TIER_ELITE: {
			"cost": 6000,
			"boost_pressure": 1.8,
			"spool_time": 0.4,
			"description": "Twin turbo setup. +55% peak power, instant spool.",
		},
	},
	CAT_TIRES: {
		"display_name": "Tires",
		"icon": "res://ui/icons/tires.png",
		"stat_affects": ["handling", "braking"],
		TIER_STOCK: {
			"cost": 0,
			"grip_mult": 1.0,
			"description": "All-season street tires.",
		},
		TIER_SPORT: {
			"cost": 300,
			"grip_mult": 1.14,
			"description": "Performance summer tires. +14% grip.",
		},
		TIER_RACE: {
			"cost": 900,
			"grip_mult": 1.28,
			"description": "Semi-slick compound. +28% grip.",
		},
		TIER_ELITE: {
			"cost": 2800,
			"grip_mult": 1.45,
			"description": "Full slick race tires. +45% grip.",
		},
	},
}

# ---------------------------------------------------------------------------
# Base stats (Stock = 100 for each axis)
# ---------------------------------------------------------------------------
const BASE_STATS := {
	"speed":        100.0,
	"acceleration": 100.0,
	"handling":     100.0,
	"braking":      100.0,
	"nitro":        100.0,
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var vehicle_node: Node3D = null
var owned_tiers: Dictionary = {
	CAT_ENGINE:     TIER_STOCK,
	CAT_BRAKES:     TIER_STOCK,
	CAT_SUSPENSION: TIER_STOCK,
	CAT_NITRO:      TIER_STOCK,
	CAT_TURBO:      TIER_STOCK,
	CAT_TIRES:      TIER_STOCK,
}
var equipped_tiers: Dictionary = owned_tiers.duplicate()
var player_token_balance: int = 0
var _vehicle_controller = null

# Spider-chart drawing cache
var _stat_values: Dictionary = {}
var _spider_chart_control: Control = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_recalculate_stats()

func attach_vehicle(v: Node3D) -> void:
	vehicle_node = v
	_vehicle_controller = v.get_node_or_null("VehicleController")
	_apply_all_upgrades()

func set_player_balance(balance: int) -> void:
	player_token_balance = balance

# ---------------------------------------------------------------------------
# Purchasing
# ---------------------------------------------------------------------------
func can_purchase(category: String, tier: int) -> bool:
	if not UPGRADE_DATA.has(category):
		return false
	var tier_data: Dictionary = UPGRADE_DATA[category][tier]
	var cost: int = tier_data["cost"]
	if cost > player_token_balance:
		return false
	var current_owned: int = owned_tiers.get(category, TIER_STOCK)
	return tier == current_owned + 1

func purchase_upgrade(category: String, tier: int) -> bool:
	if not can_purchase(category, tier):
		var cost: int = UPGRADE_DATA[category][tier]["cost"]
		emit_signal("insufficient_funds", cost, player_token_balance)
		return false

	var tier_data: Dictionary = UPGRADE_DATA[category][tier]
	var cost: int = tier_data["cost"]
	player_token_balance -= cost

	owned_tiers[category] = tier
	equipped_tiers[category] = tier
	_apply_upgrade(category, tier)
	_recalculate_stats()
	emit_signal("upgrade_purchased", category, tier)
	emit_signal("stats_changed", _stat_values)
	_send_purchase_to_network(category, tier, cost)
	print("[PerformanceUpgrades] Purchased %s tier %d for %d tokens" % [category, tier, cost])
	return true

func _send_purchase_to_network(category: String, tier: int, cost: int) -> void:
	var nm = get_node_or_null("/root/NetworkManager")
	if nm and nm.socket_client:
		nm.socket_client.send_event("vehicle_upgrade_purchased", {
			"category": category,
			"tier": tier,
			"cost": cost,
		})

# ---------------------------------------------------------------------------
# Equip (switch between owned tiers)
# ---------------------------------------------------------------------------
func equip_upgrade(category: String, tier: int) -> bool:
	if not UPGRADE_DATA.has(category):
		return false
	if tier > owned_tiers.get(category, TIER_STOCK):
		return false
	equipped_tiers[category] = tier
	_apply_upgrade(category, tier)
	_recalculate_stats()
	emit_signal("upgrade_applied", category, tier)
	emit_signal("stats_changed", _stat_values)
	return true

# ---------------------------------------------------------------------------
# Applying upgrades to the vehicle
# ---------------------------------------------------------------------------
func _apply_all_upgrades() -> void:
	for cat in ALL_CATEGORIES:
		_apply_upgrade(cat, equipped_tiers.get(cat, TIER_STOCK))

func _apply_upgrade(category: String, tier: int) -> void:
	if vehicle_node == null:
		return
	var vc = vehicle_node.get_node_or_null("VehicleController")
	if vc == null:
		vc = vehicle_node

	match category:
		CAT_ENGINE:
			var data: Dictionary = UPGRADE_DATA[CAT_ENGINE][tier]
			var base_force: float = vc.get("max_engine_force") if vc.get("max_engine_force") != null else 300.0
			vc.set("max_engine_force", 300.0 * data["speed_mult"])
		CAT_BRAKES:
			var data: Dictionary = UPGRADE_DATA[CAT_BRAKES][tier]
			vc.set("brake_force", 20.0 * data["brake_mult"])
		CAT_SUSPENSION:
			var data: Dictionary = UPGRADE_DATA[CAT_SUSPENSION][tier]
			vc.set("max_steering_angle", 0.6 * data["steering_mult"])
		CAT_NITRO:
			var data: Dictionary = UPGRADE_DATA[CAT_NITRO][tier]
			if vc.has_method("set_nitro_params"):
				vc.set_nitro_params(data["boost_mult"], data["duration_mult"], data["recharge_mult"])
		CAT_TURBO:
			pass
		CAT_TIRES:
			pass

	_apply_tier_visuals(tier)
	emit_signal("upgrade_applied", category, tier)

func _apply_tier_visuals(highest_tier: int) -> void:
	if vehicle_node == null:
		return

	var max_tier := TIER_STOCK
	for cat in ALL_CATEGORIES:
		var t := equipped_tiers.get(cat, TIER_STOCK)
		if t > max_tier:
			max_tier = t

	match max_tier:
		TIER_SPORT:
			_attach_body_kit()
		TIER_RACE:
			_attach_body_kit()
			_attach_race_wing()
		TIER_ELITE:
			_attach_body_kit()
			_attach_race_wing()
			_attach_elite_aura()

	emit_signal("tier_visual_applied", max_tier)

func _attach_body_kit() -> void:
	if vehicle_node == null:
		return
	if vehicle_node.has_node("BodyKit"):
		return
	var marker := Node3D.new()
	marker.name = "BodyKit"
	vehicle_node.add_child(marker)

func _attach_race_wing() -> void:
	if vehicle_node == null:
		return
	if vehicle_node.has_node("RaceWing"):
		return
	var wing := MeshInstance3D.new()
	wing.name = "RaceWing"
	wing.position = Vector3(0, 0.9, 1.6)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.6, 0.05, 0.5)
	wing.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05)
	mat.metallic = 0.8
	mat.roughness = 0.1
	wing.set_surface_override_material(0, mat)
	vehicle_node.add_child(wing)

func _attach_elite_aura() -> void:
	if vehicle_node == null:
		return
	if vehicle_node.has_node("EliteAura"):
		return
	var aura := OmniLight3D.new()
	aura.name = "EliteAura"
	aura.light_color = TIER_COLORS[TIER_ELITE]
	aura.light_energy = 3.0
	aura.omni_range = 4.0
	vehicle_node.add_child(aura)

# ---------------------------------------------------------------------------
# Stat calculation
# ---------------------------------------------------------------------------
func _recalculate_stats() -> void:
	var stats := BASE_STATS.duplicate()

	var eng_tier := equipped_tiers.get(CAT_ENGINE, TIER_STOCK)
	stats["speed"]        *= UPGRADE_DATA[CAT_ENGINE][eng_tier]["speed_mult"]
	stats["acceleration"] *= UPGRADE_DATA[CAT_ENGINE][eng_tier]["accel_mult"]

	var brk_tier := equipped_tiers.get(CAT_BRAKES, TIER_STOCK)
	stats["braking"] *= UPGRADE_DATA[CAT_BRAKES][brk_tier]["brake_mult"]

	var sus_tier := equipped_tiers.get(CAT_SUSPENSION, TIER_STOCK)
	stats["handling"] *= UPGRADE_DATA[CAT_SUSPENSION][sus_tier]["handling_mult"]

	var nit_tier := equipped_tiers.get(CAT_NITRO, TIER_STOCK)
	stats["nitro"] *= UPGRADE_DATA[CAT_NITRO][nit_tier]["boost_mult"]

	var tir_tier := equipped_tiers.get(CAT_TIRES, TIER_STOCK)
	stats["handling"] *= UPGRADE_DATA[CAT_TIRES][tir_tier]["grip_mult"]
	stats["braking"]  *= UPGRADE_DATA[CAT_TIRES][tir_tier]["grip_mult"]

	for key in stats:
		stats[key] = minf(stats[key], 200.0)

	_stat_values = stats

func get_stats() -> Dictionary:
	return _stat_values.duplicate()

func get_stat_normalized(stat: String) -> float:
	var val: float = _stat_values.get(stat, 100.0)
	return clampf(val / 200.0, 0.0, 1.0)

# ---------------------------------------------------------------------------
# Spider chart — draws onto a Control node using _draw()
# ---------------------------------------------------------------------------
func create_spider_chart(parent: Control) -> Control:
	var chart := _SpiderChart.new()
	chart.custom_minimum_size = Vector2(220, 220)
	chart.set_upgrader(self)
	parent.add_child(chart)
	_spider_chart_control = chart
	return chart

func refresh_spider_chart() -> void:
	if _spider_chart_control and is_instance_valid(_spider_chart_control):
		_spider_chart_control.queue_redraw()

# ---------------------------------------------------------------------------
# Save / Load
# ---------------------------------------------------------------------------
func save_upgrades() -> void:
	var data := {
		"owned": owned_tiers,
		"equipped": equipped_tiers,
	}
	var file := FileAccess.open("user://vehicle_upgrades.json", FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))

func load_upgrades() -> void:
	if not FileAccess.file_exists("user://vehicle_upgrades.json"):
		return
	var file := FileAccess.open("user://vehicle_upgrades.json", FileAccess.READ)
	if not file:
		return
	var result = JSON.parse_string(file.get_as_text())
	if not result is Dictionary:
		return
	if result.has("owned"):
		for cat in ALL_CATEGORIES:
			if result["owned"].has(cat):
				owned_tiers[cat] = int(result["owned"][cat])
	if result.has("equipped"):
		for cat in ALL_CATEGORIES:
			if result["equipped"].has(cat):
				equipped_tiers[cat] = int(result["equipped"][cat])
	_recalculate_stats()

func get_owned_tier(category: String) -> int:
	return owned_tiers.get(category, TIER_STOCK)

func get_equipped_tier(category: String) -> int:
	return equipped_tiers.get(category, TIER_STOCK)

func get_total_cost_to_max() -> int:
	var total := 0
	for cat in ALL_CATEGORIES:
		var owned := owned_tiers.get(cat, TIER_STOCK)
		for tier in range(owned + 1, TIER_ELITE + 1):
			total += UPGRADE_DATA[cat][tier]["cost"]
	return total

func get_upgrade_cost(category: String, tier: int) -> int:
	if not UPGRADE_DATA.has(category):
		return 0
	return UPGRADE_DATA[category][tier].get("cost", 0)

func get_upgrade_description(category: String, tier: int) -> String:
	if not UPGRADE_DATA.has(category):
		return ""
	return UPGRADE_DATA[category][tier].get("description", "")

# ---------------------------------------------------------------------------
# Inner class — spider chart Control
# ---------------------------------------------------------------------------
class _SpiderChart extends Control:
	var _upgrader: Node = null
	const AXES := ["speed", "acceleration", "handling", "braking", "nitro"]
	const AXIS_LABELS := ["Speed", "Accel", "Handle", "Brake", "Nitro"]
	const RING_COUNT := 4
	const BG_COLOR    := Color(0.08, 0.08, 0.12, 0.9)
	const RING_COLOR  := Color(0.3, 0.3, 0.4, 0.5)
	const AXIS_COLOR  := Color(0.5, 0.5, 0.6, 0.8)
	const FILL_COLOR  := Color(0.2, 0.6, 1.0, 0.35)
	const STROKE_COLOR := Color(0.3, 0.8, 1.0, 0.9)
	const LABEL_COLOR := Color(0.9, 0.9, 1.0, 1.0)

	func set_upgrader(u: Node) -> void:
		_upgrader = u

	func _draw() -> void:
		if _upgrader == null:
			return
		var center := size / 2.0
		var radius := minf(size.x, size.y) / 2.0 - 28.0
		var n := AXES.size()
		var angle_step := TAU / float(n)

		draw_rect(Rect2(Vector2.ZERO, size), BG_COLOR, true)

		# Rings
		for ring in range(1, RING_COUNT + 1):
			var r := radius * float(ring) / float(RING_COUNT)
			var pts: PackedVector2Array = PackedVector2Array()
			for i in range(n):
				var angle := -PI / 2.0 + angle_step * i
				pts.append(center + Vector2(cos(angle), sin(angle)) * r)
			draw_polyline(pts + PackedVector2Array([pts[0]]), RING_COLOR, 1.0)

		# Axis lines
		for i in range(n):
			var angle := -PI / 2.0 + angle_step * i
			var end := center + Vector2(cos(angle), sin(angle)) * radius
			draw_line(center, end, AXIS_COLOR, 1.0)

		# Data polygon
		var stats_pts: PackedVector2Array = PackedVector2Array()
		for i in range(n):
			var stat_name := AXES[i]
			var val := _upgrader.get_stat_normalized(stat_name) if _upgrader.has_method("get_stat_normalized") else 0.5
			var angle := -PI / 2.0 + angle_step * i
			stats_pts.append(center + Vector2(cos(angle), sin(angle)) * radius * val)

		draw_colored_polygon(stats_pts, FILL_COLOR)
		draw_polyline(stats_pts + PackedVector2Array([stats_pts[0]]), STROKE_COLOR, 2.0)

		# Dots on vertices
		for pt in stats_pts:
			draw_circle(pt, 4.0, STROKE_COLOR)

		# Labels
		for i in range(n):
			var angle := -PI / 2.0 + angle_step * i
			var lbl_pos := center + Vector2(cos(angle), sin(angle)) * (radius + 18.0)
			var font := ThemeDB.fallback_font
			var font_size := 11
			draw_string(font, lbl_pos - Vector2(20, 6), AXIS_LABELS[i], HORIZONTAL_ALIGNMENT_CENTER, 50, font_size, LABEL_COLOR)
