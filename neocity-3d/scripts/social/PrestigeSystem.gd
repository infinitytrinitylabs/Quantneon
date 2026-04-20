## PrestigeSystem.gd
## -----------------------------------------------------------------------------
## Social prestige mechanics and cooperative neighborhood progression.
## -----------------------------------------------------------------------------

extends Node
class_name PrestigeSystem

signal resident_enrolled(user_id: String)
signal prestige_updated(user_id: String, profile: Dictionary)
signal status_marker_unlocked(user_id: String, marker_id: String)
signal cooperative_goal_progress(goal_id: String, current: int, target: int)
signal cooperative_goal_completed(goal_id: String, summary: Dictionary)
signal limited_item_granted(user_id: String, item_id: String)

const STATUS_MARKERS: Array = [
	{"id": "trusted_neighbor", "title": "Trusted Neighbor", "min_points": 200, "aura": "soft_cyan"},
	{"id": "district_ally", "title": "District Ally", "min_points": 700, "aura": "mint_pulse"},
	{"id": "city_icon", "title": "City Icon", "min_points": 1700, "aura": "violet_bloom"},
	{"id": "constellation_head", "title": "Constellation Head", "min_points": 3600, "aura": "gold_singularity"},
]

const ACTIVITY_POINTS: Dictionary = {
	"daily_checkin": 35,
	"cooperative_boost": 60,
	"event_participation": 45,
	"hosting_gathering": 75,
	"mentoring_newcomer": 95,
}
const MAX_ACTIVITY_LOG_SIZE: int = 200
const DAILY_GOAL_DAY_KEY: String = "_day"

const LIMITED_ITEM_POOL: Array = [
	{"id": "aurora_gate_skin", "name": "Aurora Gate", "cost": 220, "duration_days": 10, "rarity": "epic"},
	{"id": "starlit_banner_pack", "name": "Starlit Banners", "cost": 180, "duration_days": 7, "rarity": "rare"},
	{"id": "district_echo_companion", "name": "District Echo", "cost": 300, "duration_days": 12, "rarity": "legendary"},
	{"id": "legacy_hallway_fx", "name": "Legacy Hallway FX", "cost": 260, "duration_days": 9, "rarity": "epic"},
]

const GOAL_TEMPLATES: Array = [
	{
		"id": "daily_sync",
		"label": "Neighborhood Daily Sync",
		"description": "Members check in every day to keep district perks active.",
		"target": 8,
		"reward_points": 140,
		"reward_tokens": 120,
	},
	{
		"id": "wellness_circle",
		"label": "Wellness Circle",
		"description": "Complete a shared calm-space gathering.",
		"target": 5,
		"reward_points": 90,
		"reward_tokens": 80,
	},
	{
		"id": "night_market_run",
		"label": "Night Market Run",
		"description": "Populate market district with active residents tonight.",
		"target": 12,
		"reward_points": 170,
		"reward_tokens": 150,
	},
]

const MARKER_DISPLAY_LIBRARY: Dictionary = {
	"trusted_neighbor": [
		{
			"variant_id": "trusted_neighbor_display_01",
			"title": "Trusted Neighbor Display 01",
			"hologram_style": "style_2",
			"emblem_color": "#334564",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "trusted_neighbor_display_02",
			"title": "Trusted Neighbor Display 02",
			"hologram_style": "style_3",
			"emblem_color": "#334673",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "trusted_neighbor_display_03",
			"title": "Trusted Neighbor Display 03",
			"hologram_style": "style_4",
			"emblem_color": "#334782",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "trusted_neighbor_display_04",
			"title": "Trusted Neighbor Display 04",
			"hologram_style": "style_5",
			"emblem_color": "#334891",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "trusted_neighbor_display_05",
			"title": "Trusted Neighbor Display 05",
			"hologram_style": "style_6",
			"emblem_color": "#3349a0",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "trusted_neighbor_display_06",
			"title": "Trusted Neighbor Display 06",
			"hologram_style": "style_7",
			"emblem_color": "#334aaf",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "trusted_neighbor_display_07",
			"title": "Trusted Neighbor Display 07",
			"hologram_style": "style_1",
			"emblem_color": "#334bbe",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "trusted_neighbor_display_08",
			"title": "Trusted Neighbor Display 08",
			"hologram_style": "style_2",
			"emblem_color": "#334ccd",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "trusted_neighbor_display_09",
			"title": "Trusted Neighbor Display 09",
			"hologram_style": "style_3",
			"emblem_color": "#334ddc",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "trusted_neighbor_display_10",
			"title": "Trusted Neighbor Display 10",
			"hologram_style": "style_4",
			"emblem_color": "#334eeb",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "trusted_neighbor_display_11",
			"title": "Trusted Neighbor Display 11",
			"hologram_style": "style_5",
			"emblem_color": "#334ffa",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "trusted_neighbor_display_12",
			"title": "Trusted Neighbor Display 12",
			"hologram_style": "style_6",
			"emblem_color": "#335109",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "trusted_neighbor_display_13",
			"title": "Trusted Neighbor Display 13",
			"hologram_style": "style_7",
			"emblem_color": "#335218",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "trusted_neighbor_display_14",
			"title": "Trusted Neighbor Display 14",
			"hologram_style": "style_1",
			"emblem_color": "#335327",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "trusted_neighbor_display_15",
			"title": "Trusted Neighbor Display 15",
			"hologram_style": "style_2",
			"emblem_color": "#335436",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "trusted_neighbor_display_16",
			"title": "Trusted Neighbor Display 16",
			"hologram_style": "style_3",
			"emblem_color": "#335545",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "trusted_neighbor_display_17",
			"title": "Trusted Neighbor Display 17",
			"hologram_style": "style_4",
			"emblem_color": "#335654",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "trusted_neighbor_display_18",
			"title": "Trusted Neighbor Display 18",
			"hologram_style": "style_5",
			"emblem_color": "#335763",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "trusted_neighbor_display_19",
			"title": "Trusted Neighbor Display 19",
			"hologram_style": "style_6",
			"emblem_color": "#335872",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "trusted_neighbor_display_20",
			"title": "Trusted Neighbor Display 20",
			"hologram_style": "style_7",
			"emblem_color": "#335981",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "trusted_neighbor_display_21",
			"title": "Trusted Neighbor Display 21",
			"hologram_style": "style_1",
			"emblem_color": "#335a90",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "trusted_neighbor_display_22",
			"title": "Trusted Neighbor Display 22",
			"hologram_style": "style_2",
			"emblem_color": "#335b9f",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "trusted_neighbor_display_23",
			"title": "Trusted Neighbor Display 23",
			"hologram_style": "style_3",
			"emblem_color": "#335cae",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "trusted_neighbor_display_24",
			"title": "Trusted Neighbor Display 24",
			"hologram_style": "style_4",
			"emblem_color": "#335dbd",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "trusted_neighbor_display_25",
			"title": "Trusted Neighbor Display 25",
			"hologram_style": "style_5",
			"emblem_color": "#335ecc",
			"animation_speed": 0.60,
		},
	],
	"district_ally": [
		{
			"variant_id": "district_ally_display_01",
			"title": "District Ally Display 01",
			"hologram_style": "style_2",
			"emblem_color": "#334564",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "district_ally_display_02",
			"title": "District Ally Display 02",
			"hologram_style": "style_3",
			"emblem_color": "#334673",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "district_ally_display_03",
			"title": "District Ally Display 03",
			"hologram_style": "style_4",
			"emblem_color": "#334782",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "district_ally_display_04",
			"title": "District Ally Display 04",
			"hologram_style": "style_5",
			"emblem_color": "#334891",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "district_ally_display_05",
			"title": "District Ally Display 05",
			"hologram_style": "style_6",
			"emblem_color": "#3349a0",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "district_ally_display_06",
			"title": "District Ally Display 06",
			"hologram_style": "style_7",
			"emblem_color": "#334aaf",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "district_ally_display_07",
			"title": "District Ally Display 07",
			"hologram_style": "style_1",
			"emblem_color": "#334bbe",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "district_ally_display_08",
			"title": "District Ally Display 08",
			"hologram_style": "style_2",
			"emblem_color": "#334ccd",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "district_ally_display_09",
			"title": "District Ally Display 09",
			"hologram_style": "style_3",
			"emblem_color": "#334ddc",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "district_ally_display_10",
			"title": "District Ally Display 10",
			"hologram_style": "style_4",
			"emblem_color": "#334eeb",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "district_ally_display_11",
			"title": "District Ally Display 11",
			"hologram_style": "style_5",
			"emblem_color": "#334ffa",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "district_ally_display_12",
			"title": "District Ally Display 12",
			"hologram_style": "style_6",
			"emblem_color": "#335109",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "district_ally_display_13",
			"title": "District Ally Display 13",
			"hologram_style": "style_7",
			"emblem_color": "#335218",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "district_ally_display_14",
			"title": "District Ally Display 14",
			"hologram_style": "style_1",
			"emblem_color": "#335327",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "district_ally_display_15",
			"title": "District Ally Display 15",
			"hologram_style": "style_2",
			"emblem_color": "#335436",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "district_ally_display_16",
			"title": "District Ally Display 16",
			"hologram_style": "style_3",
			"emblem_color": "#335545",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "district_ally_display_17",
			"title": "District Ally Display 17",
			"hologram_style": "style_4",
			"emblem_color": "#335654",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "district_ally_display_18",
			"title": "District Ally Display 18",
			"hologram_style": "style_5",
			"emblem_color": "#335763",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "district_ally_display_19",
			"title": "District Ally Display 19",
			"hologram_style": "style_6",
			"emblem_color": "#335872",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "district_ally_display_20",
			"title": "District Ally Display 20",
			"hologram_style": "style_7",
			"emblem_color": "#335981",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "district_ally_display_21",
			"title": "District Ally Display 21",
			"hologram_style": "style_1",
			"emblem_color": "#335a90",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "district_ally_display_22",
			"title": "District Ally Display 22",
			"hologram_style": "style_2",
			"emblem_color": "#335b9f",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "district_ally_display_23",
			"title": "District Ally Display 23",
			"hologram_style": "style_3",
			"emblem_color": "#335cae",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "district_ally_display_24",
			"title": "District Ally Display 24",
			"hologram_style": "style_4",
			"emblem_color": "#335dbd",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "district_ally_display_25",
			"title": "District Ally Display 25",
			"hologram_style": "style_5",
			"emblem_color": "#335ecc",
			"animation_speed": 0.60,
		},
	],
	"city_icon": [
		{
			"variant_id": "city_icon_display_01",
			"title": "City Icon Display 01",
			"hologram_style": "style_2",
			"emblem_color": "#334564",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "city_icon_display_02",
			"title": "City Icon Display 02",
			"hologram_style": "style_3",
			"emblem_color": "#334673",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "city_icon_display_03",
			"title": "City Icon Display 03",
			"hologram_style": "style_4",
			"emblem_color": "#334782",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "city_icon_display_04",
			"title": "City Icon Display 04",
			"hologram_style": "style_5",
			"emblem_color": "#334891",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "city_icon_display_05",
			"title": "City Icon Display 05",
			"hologram_style": "style_6",
			"emblem_color": "#3349a0",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "city_icon_display_06",
			"title": "City Icon Display 06",
			"hologram_style": "style_7",
			"emblem_color": "#334aaf",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "city_icon_display_07",
			"title": "City Icon Display 07",
			"hologram_style": "style_1",
			"emblem_color": "#334bbe",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "city_icon_display_08",
			"title": "City Icon Display 08",
			"hologram_style": "style_2",
			"emblem_color": "#334ccd",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "city_icon_display_09",
			"title": "City Icon Display 09",
			"hologram_style": "style_3",
			"emblem_color": "#334ddc",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "city_icon_display_10",
			"title": "City Icon Display 10",
			"hologram_style": "style_4",
			"emblem_color": "#334eeb",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "city_icon_display_11",
			"title": "City Icon Display 11",
			"hologram_style": "style_5",
			"emblem_color": "#334ffa",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "city_icon_display_12",
			"title": "City Icon Display 12",
			"hologram_style": "style_6",
			"emblem_color": "#335109",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "city_icon_display_13",
			"title": "City Icon Display 13",
			"hologram_style": "style_7",
			"emblem_color": "#335218",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "city_icon_display_14",
			"title": "City Icon Display 14",
			"hologram_style": "style_1",
			"emblem_color": "#335327",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "city_icon_display_15",
			"title": "City Icon Display 15",
			"hologram_style": "style_2",
			"emblem_color": "#335436",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "city_icon_display_16",
			"title": "City Icon Display 16",
			"hologram_style": "style_3",
			"emblem_color": "#335545",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "city_icon_display_17",
			"title": "City Icon Display 17",
			"hologram_style": "style_4",
			"emblem_color": "#335654",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "city_icon_display_18",
			"title": "City Icon Display 18",
			"hologram_style": "style_5",
			"emblem_color": "#335763",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "city_icon_display_19",
			"title": "City Icon Display 19",
			"hologram_style": "style_6",
			"emblem_color": "#335872",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "city_icon_display_20",
			"title": "City Icon Display 20",
			"hologram_style": "style_7",
			"emblem_color": "#335981",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "city_icon_display_21",
			"title": "City Icon Display 21",
			"hologram_style": "style_1",
			"emblem_color": "#335a90",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "city_icon_display_22",
			"title": "City Icon Display 22",
			"hologram_style": "style_2",
			"emblem_color": "#335b9f",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "city_icon_display_23",
			"title": "City Icon Display 23",
			"hologram_style": "style_3",
			"emblem_color": "#335cae",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "city_icon_display_24",
			"title": "City Icon Display 24",
			"hologram_style": "style_4",
			"emblem_color": "#335dbd",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "city_icon_display_25",
			"title": "City Icon Display 25",
			"hologram_style": "style_5",
			"emblem_color": "#335ecc",
			"animation_speed": 0.60,
		},
	],
	"constellation_head": [
		{
			"variant_id": "constellation_head_display_01",
			"title": "Constellation Head Display 01",
			"hologram_style": "style_2",
			"emblem_color": "#334564",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "constellation_head_display_02",
			"title": "Constellation Head Display 02",
			"hologram_style": "style_3",
			"emblem_color": "#334673",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "constellation_head_display_03",
			"title": "Constellation Head Display 03",
			"hologram_style": "style_4",
			"emblem_color": "#334782",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "constellation_head_display_04",
			"title": "Constellation Head Display 04",
			"hologram_style": "style_5",
			"emblem_color": "#334891",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "constellation_head_display_05",
			"title": "Constellation Head Display 05",
			"hologram_style": "style_6",
			"emblem_color": "#3349a0",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "constellation_head_display_06",
			"title": "Constellation Head Display 06",
			"hologram_style": "style_7",
			"emblem_color": "#334aaf",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "constellation_head_display_07",
			"title": "Constellation Head Display 07",
			"hologram_style": "style_1",
			"emblem_color": "#334bbe",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "constellation_head_display_08",
			"title": "Constellation Head Display 08",
			"hologram_style": "style_2",
			"emblem_color": "#334ccd",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "constellation_head_display_09",
			"title": "Constellation Head Display 09",
			"hologram_style": "style_3",
			"emblem_color": "#334ddc",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "constellation_head_display_10",
			"title": "Constellation Head Display 10",
			"hologram_style": "style_4",
			"emblem_color": "#334eeb",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "constellation_head_display_11",
			"title": "Constellation Head Display 11",
			"hologram_style": "style_5",
			"emblem_color": "#334ffa",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "constellation_head_display_12",
			"title": "Constellation Head Display 12",
			"hologram_style": "style_6",
			"emblem_color": "#335109",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "constellation_head_display_13",
			"title": "Constellation Head Display 13",
			"hologram_style": "style_7",
			"emblem_color": "#335218",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "constellation_head_display_14",
			"title": "Constellation Head Display 14",
			"hologram_style": "style_1",
			"emblem_color": "#335327",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "constellation_head_display_15",
			"title": "Constellation Head Display 15",
			"hologram_style": "style_2",
			"emblem_color": "#335436",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "constellation_head_display_16",
			"title": "Constellation Head Display 16",
			"hologram_style": "style_3",
			"emblem_color": "#335545",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "constellation_head_display_17",
			"title": "Constellation Head Display 17",
			"hologram_style": "style_4",
			"emblem_color": "#335654",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "constellation_head_display_18",
			"title": "Constellation Head Display 18",
			"hologram_style": "style_5",
			"emblem_color": "#335763",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "constellation_head_display_19",
			"title": "Constellation Head Display 19",
			"hologram_style": "style_6",
			"emblem_color": "#335872",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "constellation_head_display_20",
			"title": "Constellation Head Display 20",
			"hologram_style": "style_7",
			"emblem_color": "#335981",
			"animation_speed": 0.60,
		},
		{
			"variant_id": "constellation_head_display_21",
			"title": "Constellation Head Display 21",
			"hologram_style": "style_1",
			"emblem_color": "#335a90",
			"animation_speed": 0.75,
		},
		{
			"variant_id": "constellation_head_display_22",
			"title": "Constellation Head Display 22",
			"hologram_style": "style_2",
			"emblem_color": "#335b9f",
			"animation_speed": 0.90,
		},
		{
			"variant_id": "constellation_head_display_23",
			"title": "Constellation Head Display 23",
			"hologram_style": "style_3",
			"emblem_color": "#335cae",
			"animation_speed": 1.05,
		},
		{
			"variant_id": "constellation_head_display_24",
			"title": "Constellation Head Display 24",
			"hologram_style": "style_4",
			"emblem_color": "#335dbd",
			"animation_speed": 1.20,
		},
		{
			"variant_id": "constellation_head_display_25",
			"title": "Constellation Head Display 25",
			"hologram_style": "style_5",
			"emblem_color": "#335ecc",
			"animation_speed": 0.60,
		},
	],
}

const LIMITED_ITEM_SEASONS: Array = [
	{
		"season_id": "season_01",
		"featured_item": "featured_item_01",
		"label": "Prestige Season 01",
		"duration_days": 14,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_02",
		"featured_item": "featured_item_02",
		"label": "Prestige Season 02",
		"duration_days": 21,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_03",
		"featured_item": "featured_item_03",
		"label": "Prestige Season 03",
		"duration_days": 28,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_04",
		"featured_item": "featured_item_04",
		"label": "Prestige Season 04",
		"duration_days": 7,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_05",
		"featured_item": "featured_item_05",
		"label": "Prestige Season 05",
		"duration_days": 14,
		"min_checkin_streak": 7,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_06",
		"featured_item": "featured_item_06",
		"label": "Prestige Season 06",
		"duration_days": 21,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_07",
		"featured_item": "featured_item_07",
		"label": "Prestige Season 07",
		"duration_days": 28,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_08",
		"featured_item": "featured_item_08",
		"label": "Prestige Season 08",
		"duration_days": 7,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_09",
		"featured_item": "featured_item_09",
		"label": "Prestige Season 09",
		"duration_days": 14,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_10",
		"featured_item": "featured_item_10",
		"label": "Prestige Season 10",
		"duration_days": 21,
		"min_checkin_streak": 6,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_11",
		"featured_item": "featured_item_11",
		"label": "Prestige Season 11",
		"duration_days": 28,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_12",
		"featured_item": "featured_item_12",
		"label": "Prestige Season 12",
		"duration_days": 7,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_13",
		"featured_item": "featured_item_13",
		"label": "Prestige Season 13",
		"duration_days": 14,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_14",
		"featured_item": "featured_item_14",
		"label": "Prestige Season 14",
		"duration_days": 21,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_15",
		"featured_item": "featured_item_15",
		"label": "Prestige Season 15",
		"duration_days": 28,
		"min_checkin_streak": 5,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_16",
		"featured_item": "featured_item_16",
		"label": "Prestige Season 16",
		"duration_days": 7,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_17",
		"featured_item": "featured_item_17",
		"label": "Prestige Season 17",
		"duration_days": 14,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_18",
		"featured_item": "featured_item_18",
		"label": "Prestige Season 18",
		"duration_days": 21,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_19",
		"featured_item": "featured_item_19",
		"label": "Prestige Season 19",
		"duration_days": 28,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_20",
		"featured_item": "featured_item_20",
		"label": "Prestige Season 20",
		"duration_days": 7,
		"min_checkin_streak": 4,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_21",
		"featured_item": "featured_item_21",
		"label": "Prestige Season 21",
		"duration_days": 14,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_22",
		"featured_item": "featured_item_22",
		"label": "Prestige Season 22",
		"duration_days": 21,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_23",
		"featured_item": "featured_item_23",
		"label": "Prestige Season 23",
		"duration_days": 28,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_24",
		"featured_item": "featured_item_24",
		"label": "Prestige Season 24",
		"duration_days": 7,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_25",
		"featured_item": "featured_item_25",
		"label": "Prestige Season 25",
		"duration_days": 14,
		"min_checkin_streak": 3,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_26",
		"featured_item": "featured_item_26",
		"label": "Prestige Season 26",
		"duration_days": 21,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_27",
		"featured_item": "featured_item_27",
		"label": "Prestige Season 27",
		"duration_days": 28,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_28",
		"featured_item": "featured_item_28",
		"label": "Prestige Season 28",
		"duration_days": 7,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_29",
		"featured_item": "featured_item_29",
		"label": "Prestige Season 29",
		"duration_days": 14,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_30",
		"featured_item": "featured_item_30",
		"label": "Prestige Season 30",
		"duration_days": 21,
		"min_checkin_streak": 2,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_31",
		"featured_item": "featured_item_31",
		"label": "Prestige Season 31",
		"duration_days": 28,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_32",
		"featured_item": "featured_item_32",
		"label": "Prestige Season 32",
		"duration_days": 7,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_33",
		"featured_item": "featured_item_33",
		"label": "Prestige Season 33",
		"duration_days": 14,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_34",
		"featured_item": "featured_item_34",
		"label": "Prestige Season 34",
		"duration_days": 21,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_35",
		"featured_item": "featured_item_35",
		"label": "Prestige Season 35",
		"duration_days": 28,
		"min_checkin_streak": 7,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_36",
		"featured_item": "featured_item_36",
		"label": "Prestige Season 36",
		"duration_days": 7,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_37",
		"featured_item": "featured_item_37",
		"label": "Prestige Season 37",
		"duration_days": 14,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_38",
		"featured_item": "featured_item_38",
		"label": "Prestige Season 38",
		"duration_days": 21,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_39",
		"featured_item": "featured_item_39",
		"label": "Prestige Season 39",
		"duration_days": 28,
		"min_checkin_streak": 5,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_40",
		"featured_item": "featured_item_40",
		"label": "Prestige Season 40",
		"duration_days": 7,
		"min_checkin_streak": 6,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_41",
		"featured_item": "featured_item_41",
		"label": "Prestige Season 41",
		"duration_days": 14,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_42",
		"featured_item": "featured_item_42",
		"label": "Prestige Season 42",
		"duration_days": 21,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
	{
		"season_id": "season_43",
		"featured_item": "featured_item_43",
		"label": "Prestige Season 43",
		"duration_days": 28,
		"min_checkin_streak": 3,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_44",
		"featured_item": "featured_item_44",
		"label": "Prestige Season 44",
		"duration_days": 7,
		"min_checkin_streak": 4,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_45",
		"featured_item": "featured_item_45",
		"label": "Prestige Season 45",
		"duration_days": 14,
		"min_checkin_streak": 5,
		"rarity_focus": "legendary",
	},
	{
		"season_id": "season_46",
		"featured_item": "featured_item_46",
		"label": "Prestige Season 46",
		"duration_days": 21,
		"min_checkin_streak": 6,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_47",
		"featured_item": "featured_item_47",
		"label": "Prestige Season 47",
		"duration_days": 28,
		"min_checkin_streak": 7,
		"rarity_focus": "rare",
	},
	{
		"season_id": "season_48",
		"featured_item": "featured_item_48",
		"label": "Prestige Season 48",
		"duration_days": 7,
		"min_checkin_streak": 2,
		"rarity_focus": "epic",
	},
]

const COOPERATIVE_GOAL_LIBRARY: Array = [
	{
		"id": "community_goal_01",
		"label": "Community Goal 01",
		"description": "Coordinate resident check-ins and support loops for wave 01.",
		"target": 5,
		"reward_points": 74,
		"reward_tokens": 53,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_02",
		"label": "Community Goal 02",
		"description": "Coordinate resident check-ins and support loops for wave 02.",
		"target": 6,
		"reward_points": 78,
		"reward_tokens": 56,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_03",
		"label": "Community Goal 03",
		"description": "Coordinate resident check-ins and support loops for wave 03.",
		"target": 7,
		"reward_points": 82,
		"reward_tokens": 59,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_04",
		"label": "Community Goal 04",
		"description": "Coordinate resident check-ins and support loops for wave 04.",
		"target": 8,
		"reward_points": 86,
		"reward_tokens": 62,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_05",
		"label": "Community Goal 05",
		"description": "Coordinate resident check-ins and support loops for wave 05.",
		"target": 9,
		"reward_points": 90,
		"reward_tokens": 65,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_06",
		"label": "Community Goal 06",
		"description": "Coordinate resident check-ins and support loops for wave 06.",
		"target": 10,
		"reward_points": 94,
		"reward_tokens": 68,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_07",
		"label": "Community Goal 07",
		"description": "Coordinate resident check-ins and support loops for wave 07.",
		"target": 11,
		"reward_points": 98,
		"reward_tokens": 71,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_08",
		"label": "Community Goal 08",
		"description": "Coordinate resident check-ins and support loops for wave 08.",
		"target": 12,
		"reward_points": 102,
		"reward_tokens": 74,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_09",
		"label": "Community Goal 09",
		"description": "Coordinate resident check-ins and support loops for wave 09.",
		"target": 13,
		"reward_points": 106,
		"reward_tokens": 77,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_10",
		"label": "Community Goal 10",
		"description": "Coordinate resident check-ins and support loops for wave 10.",
		"target": 4,
		"reward_points": 110,
		"reward_tokens": 80,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_11",
		"label": "Community Goal 11",
		"description": "Coordinate resident check-ins and support loops for wave 11.",
		"target": 5,
		"reward_points": 114,
		"reward_tokens": 83,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_12",
		"label": "Community Goal 12",
		"description": "Coordinate resident check-ins and support loops for wave 12.",
		"target": 6,
		"reward_points": 118,
		"reward_tokens": 86,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_13",
		"label": "Community Goal 13",
		"description": "Coordinate resident check-ins and support loops for wave 13.",
		"target": 7,
		"reward_points": 122,
		"reward_tokens": 89,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_14",
		"label": "Community Goal 14",
		"description": "Coordinate resident check-ins and support loops for wave 14.",
		"target": 8,
		"reward_points": 126,
		"reward_tokens": 92,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_15",
		"label": "Community Goal 15",
		"description": "Coordinate resident check-ins and support loops for wave 15.",
		"target": 9,
		"reward_points": 130,
		"reward_tokens": 95,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_16",
		"label": "Community Goal 16",
		"description": "Coordinate resident check-ins and support loops for wave 16.",
		"target": 10,
		"reward_points": 134,
		"reward_tokens": 98,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_17",
		"label": "Community Goal 17",
		"description": "Coordinate resident check-ins and support loops for wave 17.",
		"target": 11,
		"reward_points": 138,
		"reward_tokens": 101,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_18",
		"label": "Community Goal 18",
		"description": "Coordinate resident check-ins and support loops for wave 18.",
		"target": 12,
		"reward_points": 142,
		"reward_tokens": 104,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_19",
		"label": "Community Goal 19",
		"description": "Coordinate resident check-ins and support loops for wave 19.",
		"target": 13,
		"reward_points": 146,
		"reward_tokens": 107,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_20",
		"label": "Community Goal 20",
		"description": "Coordinate resident check-ins and support loops for wave 20.",
		"target": 4,
		"reward_points": 150,
		"reward_tokens": 110,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_21",
		"label": "Community Goal 21",
		"description": "Coordinate resident check-ins and support loops for wave 21.",
		"target": 5,
		"reward_points": 154,
		"reward_tokens": 113,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_22",
		"label": "Community Goal 22",
		"description": "Coordinate resident check-ins and support loops for wave 22.",
		"target": 6,
		"reward_points": 158,
		"reward_tokens": 116,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_23",
		"label": "Community Goal 23",
		"description": "Coordinate resident check-ins and support loops for wave 23.",
		"target": 7,
		"reward_points": 162,
		"reward_tokens": 119,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_24",
		"label": "Community Goal 24",
		"description": "Coordinate resident check-ins and support loops for wave 24.",
		"target": 8,
		"reward_points": 166,
		"reward_tokens": 122,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_25",
		"label": "Community Goal 25",
		"description": "Coordinate resident check-ins and support loops for wave 25.",
		"target": 9,
		"reward_points": 170,
		"reward_tokens": 125,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_26",
		"label": "Community Goal 26",
		"description": "Coordinate resident check-ins and support loops for wave 26.",
		"target": 10,
		"reward_points": 174,
		"reward_tokens": 128,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_27",
		"label": "Community Goal 27",
		"description": "Coordinate resident check-ins and support loops for wave 27.",
		"target": 11,
		"reward_points": 178,
		"reward_tokens": 131,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_28",
		"label": "Community Goal 28",
		"description": "Coordinate resident check-ins and support loops for wave 28.",
		"target": 12,
		"reward_points": 182,
		"reward_tokens": 134,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_29",
		"label": "Community Goal 29",
		"description": "Coordinate resident check-ins and support loops for wave 29.",
		"target": 13,
		"reward_points": 186,
		"reward_tokens": 137,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_30",
		"label": "Community Goal 30",
		"description": "Coordinate resident check-ins and support loops for wave 30.",
		"target": 4,
		"reward_points": 190,
		"reward_tokens": 140,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_31",
		"label": "Community Goal 31",
		"description": "Coordinate resident check-ins and support loops for wave 31.",
		"target": 5,
		"reward_points": 194,
		"reward_tokens": 143,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_32",
		"label": "Community Goal 32",
		"description": "Coordinate resident check-ins and support loops for wave 32.",
		"target": 6,
		"reward_points": 198,
		"reward_tokens": 146,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_33",
		"label": "Community Goal 33",
		"description": "Coordinate resident check-ins and support loops for wave 33.",
		"target": 7,
		"reward_points": 202,
		"reward_tokens": 149,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_34",
		"label": "Community Goal 34",
		"description": "Coordinate resident check-ins and support loops for wave 34.",
		"target": 8,
		"reward_points": 206,
		"reward_tokens": 152,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_35",
		"label": "Community Goal 35",
		"description": "Coordinate resident check-ins and support loops for wave 35.",
		"target": 9,
		"reward_points": 210,
		"reward_tokens": 155,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_36",
		"label": "Community Goal 36",
		"description": "Coordinate resident check-ins and support loops for wave 36.",
		"target": 10,
		"reward_points": 214,
		"reward_tokens": 158,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_37",
		"label": "Community Goal 37",
		"description": "Coordinate resident check-ins and support loops for wave 37.",
		"target": 11,
		"reward_points": 218,
		"reward_tokens": 161,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_38",
		"label": "Community Goal 38",
		"description": "Coordinate resident check-ins and support loops for wave 38.",
		"target": 12,
		"reward_points": 222,
		"reward_tokens": 164,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_39",
		"label": "Community Goal 39",
		"description": "Coordinate resident check-ins and support loops for wave 39.",
		"target": 13,
		"reward_points": 226,
		"reward_tokens": 167,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_40",
		"label": "Community Goal 40",
		"description": "Coordinate resident check-ins and support loops for wave 40.",
		"target": 4,
		"reward_points": 230,
		"reward_tokens": 170,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_41",
		"label": "Community Goal 41",
		"description": "Coordinate resident check-ins and support loops for wave 41.",
		"target": 5,
		"reward_points": 234,
		"reward_tokens": 173,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_42",
		"label": "Community Goal 42",
		"description": "Coordinate resident check-ins and support loops for wave 42.",
		"target": 6,
		"reward_points": 238,
		"reward_tokens": 176,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_43",
		"label": "Community Goal 43",
		"description": "Coordinate resident check-ins and support loops for wave 43.",
		"target": 7,
		"reward_points": 242,
		"reward_tokens": 179,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_44",
		"label": "Community Goal 44",
		"description": "Coordinate resident check-ins and support loops for wave 44.",
		"target": 8,
		"reward_points": 246,
		"reward_tokens": 182,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_45",
		"label": "Community Goal 45",
		"description": "Coordinate resident check-ins and support loops for wave 45.",
		"target": 9,
		"reward_points": 250,
		"reward_tokens": 185,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_46",
		"label": "Community Goal 46",
		"description": "Coordinate resident check-ins and support loops for wave 46.",
		"target": 10,
		"reward_points": 254,
		"reward_tokens": 188,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_47",
		"label": "Community Goal 47",
		"description": "Coordinate resident check-ins and support loops for wave 47.",
		"target": 11,
		"reward_points": 258,
		"reward_tokens": 191,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_48",
		"label": "Community Goal 48",
		"description": "Coordinate resident check-ins and support loops for wave 48.",
		"target": 12,
		"reward_points": 262,
		"reward_tokens": 194,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_49",
		"label": "Community Goal 49",
		"description": "Coordinate resident check-ins and support loops for wave 49.",
		"target": 13,
		"reward_points": 266,
		"reward_tokens": 197,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_50",
		"label": "Community Goal 50",
		"description": "Coordinate resident check-ins and support loops for wave 50.",
		"target": 4,
		"reward_points": 270,
		"reward_tokens": 200,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_51",
		"label": "Community Goal 51",
		"description": "Coordinate resident check-ins and support loops for wave 51.",
		"target": 5,
		"reward_points": 274,
		"reward_tokens": 203,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_52",
		"label": "Community Goal 52",
		"description": "Coordinate resident check-ins and support loops for wave 52.",
		"target": 6,
		"reward_points": 278,
		"reward_tokens": 206,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_53",
		"label": "Community Goal 53",
		"description": "Coordinate resident check-ins and support loops for wave 53.",
		"target": 7,
		"reward_points": 282,
		"reward_tokens": 209,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_54",
		"label": "Community Goal 54",
		"description": "Coordinate resident check-ins and support loops for wave 54.",
		"target": 8,
		"reward_points": 286,
		"reward_tokens": 212,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_55",
		"label": "Community Goal 55",
		"description": "Coordinate resident check-ins and support loops for wave 55.",
		"target": 9,
		"reward_points": 290,
		"reward_tokens": 215,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_56",
		"label": "Community Goal 56",
		"description": "Coordinate resident check-ins and support loops for wave 56.",
		"target": 10,
		"reward_points": 294,
		"reward_tokens": 218,
		"requires_marker": "trusted_neighbor",
	},
	{
		"id": "community_goal_57",
		"label": "Community Goal 57",
		"description": "Coordinate resident check-ins and support loops for wave 57.",
		"target": 11,
		"reward_points": 298,
		"reward_tokens": 221,
		"requires_marker": "district_ally",
	},
	{
		"id": "community_goal_58",
		"label": "Community Goal 58",
		"description": "Coordinate resident check-ins and support loops for wave 58.",
		"target": 12,
		"reward_points": 302,
		"reward_tokens": 224,
		"requires_marker": "city_icon",
	},
	{
		"id": "community_goal_59",
		"label": "Community Goal 59",
		"description": "Coordinate resident check-ins and support loops for wave 59.",
		"target": 13,
		"reward_points": 306,
		"reward_tokens": 227,
		"requires_marker": "constellation_head",
	},
	{
		"id": "community_goal_60",
		"label": "Community Goal 60",
		"description": "Coordinate resident check-ins and support loops for wave 60.",
		"target": 4,
		"reward_points": 310,
		"reward_tokens": 230,
		"requires_marker": "trusted_neighbor",
	},
]

var prestige_profiles: Dictionary = {}
var active_cooperative_goals: Dictionary = {}

func _ready() -> void:
	_reset_daily_goals_if_needed(true)

func enroll_resident(user_id: String, display_name: String = "") -> void:
	if user_id.is_empty():
		return
	if prestige_profiles.has(user_id):
		return
	prestige_profiles[user_id] = _make_profile(user_id, display_name)
	emit_signal("resident_enrolled", user_id)
	emit_signal("prestige_updated", user_id, prestige_profiles[user_id])

func ensure_resident(user_id: String) -> void:
	if not prestige_profiles.has(user_id):
		enroll_resident(user_id, user_id)

func record_activity(user_id: String, activity_type: String, payload: Dictionary = {}) -> Dictionary:
	ensure_resident(user_id)
	_reset_daily_goals_if_needed(false)
	if not ACTIVITY_POINTS.has(activity_type):
		return _result(false, "Unknown activity type.")

	var profile: Dictionary = prestige_profiles[user_id]
	var points: int = int(ACTIVITY_POINTS[activity_type])
	if activity_type == "event_participation":
		points += int(payload.get("difficulty_bonus", 0))
	points = max(1, points)

	_add_points(profile, points, activity_type)
	_unlock_status_markers(user_id, profile)
	_maybe_progress_goal(user_id, str(payload.get("goal_id", "")), 1)
	prestige_profiles[user_id] = profile
	emit_signal("prestige_updated", user_id, profile)
	return _result(true, "Activity recorded.", {"points_awarded": points, "profile": profile})

func record_daily_checkin(user_id: String, neighborhood_id: String) -> Dictionary:
	ensure_resident(user_id)
	_reset_daily_goals_if_needed(false)
	if neighborhood_id.is_empty():
		return _result(false, "Neighborhood id is required.")

	var profile: Dictionary = prestige_profiles[user_id]
	var today: String = Time.get_date_string_from_system()
	if str(profile.get("last_checkin_date", "")) == today:
		return _result(false, "Already checked in today.")

	profile["last_checkin_date"] = today
	profile["checkin_streak"] = int(profile.get("checkin_streak", 0)) + 1
	profile["neighborhood_id"] = neighborhood_id
	_add_points(profile, ACTIVITY_POINTS["daily_checkin"], "daily_checkin")
	_unlock_status_markers(user_id, profile)
	_maybe_progress_goal(user_id, "daily_sync", 1)
	if int(profile.get("checkin_streak", 0)) % 7 == 0:
		_maybe_grant_limited_item(user_id, profile)
	prestige_profiles[user_id] = profile
	emit_signal("prestige_updated", user_id, profile)
	return _result(true, "Daily check-in successful.", {"profile": profile})

func contribute_to_goal(user_id: String, goal_id: String, contribution: int = 1) -> Dictionary:
	ensure_resident(user_id)
	_reset_daily_goals_if_needed(false)
	if not active_cooperative_goals.has(goal_id):
		return _result(false, "Goal is not active.")
	if contribution <= 0:
		return _result(false, "Contribution must be positive.")

	var goal: Dictionary = active_cooperative_goals[goal_id]
	if bool(goal.get("completed", false)):
		return _result(false, "Goal already completed.")

	var contributors: Dictionary = goal.get("contributors", {})
	contributors[user_id] = int(contributors.get(user_id, 0)) + contribution
	goal["contributors"] = contributors
	goal["progress"] = min(int(goal.get("target", 0)), int(goal.get("progress", 0)) + contribution)
	active_cooperative_goals[goal_id] = goal
	emit_signal("cooperative_goal_progress", goal_id, int(goal.get("progress", 0)), int(goal.get("target", 0)))

	if int(goal.get("progress", 0)) >= int(goal.get("target", 0)):
		_complete_goal(goal_id)

	var profile: Dictionary = prestige_profiles[user_id]
	_add_points(profile, contribution * 5, "goal_contribution")
	_unlock_status_markers(user_id, profile)
	prestige_profiles[user_id] = profile
	emit_signal("prestige_updated", user_id, profile)
	return _result(true, "Contribution recorded.", {"goal": active_cooperative_goals[goal_id]})

func get_profile(user_id: String) -> Dictionary:
	if not prestige_profiles.has(user_id):
		return {}
	return prestige_profiles[user_id].duplicate(true)

func get_active_goals() -> Array:
	_reset_daily_goals_if_needed(false)
	var goals: Array = []
	for g in active_cooperative_goals.values():
		goals.append(g.duplicate(true))
	goals.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("id", "")) < str(b.get("id", ""))
	)
	return goals

func get_marker_display_variants(marker_id: String) -> Array:
	if not MARKER_DISPLAY_LIBRARY.has(marker_id):
		return []
	return (MARKER_DISPLAY_LIBRARY[marker_id] as Array).duplicate(true)

func get_limited_item_schedule() -> Array:
	return LIMITED_ITEM_SEASONS.duplicate(true)

func get_rotating_community_goal_templates(min_points: int = 0) -> Array:
	var out: Array = []
	for goal in COOPERATIVE_GOAL_LIBRARY:
		if int(goal.get("reward_points", 0)) >= min_points:
			out.append(goal.duplicate(true))
	return out

func generate_goal_rotation(seed_day: String = "") -> Array:
	var day_key: String = seed_day if not seed_day.is_empty() else Time.get_date_string_from_system()
	var hash_seed: int = 0
	for i in range(day_key.length()):
		hash_seed += day_key.unicode_at(i)
	var pool: Array = COOPERATIVE_GOAL_LIBRARY.duplicate(true)
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var av: int = (int(a.get("target", 0)) * 17 + hash_seed) % 101
		var bv: int = (int(b.get("target", 0)) * 17 + hash_seed) % 101
		return av < bv
	)
	var out: Array = []
	for i in range(min(5, pool.size())):
		out.append(pool[i])
	return out

func request_limited_item_redemption(user_id: String, item_id: String) -> Dictionary:
	ensure_resident(user_id)
	if item_id.is_empty():
		return _result(false, "Item id is required.")
	for item in LIMITED_ITEM_POOL:
		if str(item.get("id", "")) == item_id:
			var profile: Dictionary = prestige_profiles[user_id]
			var points: int = int(profile.get("prestige_points", 0))
			var cost: int = int(item.get("cost", 0))
			if points < cost:
				return _result(false, "Not enough prestige points.")
			profile["prestige_points"] = points - cost
			_maybe_grant_limited_item(user_id, profile)
			prestige_profiles[user_id] = profile
			emit_signal("prestige_updated", user_id, profile)
			return _result(true, "Limited item redeemed.", {"remaining_points": profile.get("prestige_points", 0)})
	return _result(false, "Item not found.")

func get_available_limited_items(user_id: String) -> Array:
	ensure_resident(user_id)
	var profile: Dictionary = prestige_profiles[user_id]
	var now_unix: int = int(Time.get_unix_time_from_system())
	var inventory: Array = profile.get("limited_inventory", [])
	var owned_ids: Dictionary = {}
	for item in inventory:
		if int(item.get("expires_unix", 0)) > now_unix:
			owned_ids[str(item.get("id", ""))] = true
	var available: Array = []
	for item_data in LIMITED_ITEM_POOL:
		if not owned_ids.has(str(item_data.get("id", ""))):
			available.append(item_data.duplicate(true))
	return available

func build_status_marker_payload(user_id: String) -> Dictionary:
	ensure_resident(user_id)
	var profile: Dictionary = prestige_profiles[user_id]
	return {
		"user_id": user_id,
		"display_name": profile.get("display_name", user_id),
		"status_title": profile.get("active_marker_title", "Resident"),
		"status_aura": profile.get("active_marker_aura", "soft_cyan"),
		"prestige_points": profile.get("prestige_points", 0),
		"checkin_streak": profile.get("checkin_streak", 0),
	}

func debug_snapshot() -> Dictionary:
	return {
		"profiles": prestige_profiles.duplicate(true),
		"active_goals": active_cooperative_goals.duplicate(true),
	}

func _make_profile(user_id: String, display_name: String) -> Dictionary:
	return {
		"user_id": user_id,
		"display_name": display_name if not display_name.is_empty() else user_id,
		"prestige_points": 0,
		"status_markers": [],
		"active_marker_id": "",
		"active_marker_title": "Resident",
		"active_marker_aura": "soft_cyan",
		"last_checkin_date": "",
		"checkin_streak": 0,
		"limited_inventory": [],
		"activity_log": [],
		"neighborhood_id": "",
	}

func _add_points(profile: Dictionary, points: int, reason: String) -> void:
	profile["prestige_points"] = int(profile.get("prestige_points", 0)) + points
	var log: Array = profile.get("activity_log", [])
	log.push_front({
		"reason": reason,
		"points": points,
		"timestamp": int(Time.get_unix_time_from_system()),
	})
	if log.size() > MAX_ACTIVITY_LOG_SIZE:
		log.resize(MAX_ACTIVITY_LOG_SIZE)
	profile["activity_log"] = log

func _unlock_status_markers(user_id: String, profile: Dictionary) -> void:
	var current_points: int = int(profile.get("prestige_points", 0))
	var unlocked_ids: Array = profile.get("status_markers", [])
	for marker in STATUS_MARKERS:
		var marker_id: String = str(marker.get("id", ""))
		if current_points >= int(marker.get("min_points", 0)) and not unlocked_ids.has(marker_id):
			unlocked_ids.append(marker_id)
			emit_signal("status_marker_unlocked", user_id, marker_id)
	profile["status_markers"] = unlocked_ids

	var active_marker: Dictionary = {"id": "", "title": "Resident", "aura": "soft_cyan"}
	for marker in STATUS_MARKERS:
		if unlocked_ids.has(str(marker.get("id", ""))):
			active_marker = marker
	profile["active_marker_id"] = str(active_marker.get("id", ""))
	profile["active_marker_title"] = str(active_marker.get("title", "Resident"))
	profile["active_marker_aura"] = str(active_marker.get("aura", "soft_cyan"))

func _reset_daily_goals_if_needed(force: bool) -> void:
	var today: String = Time.get_date_string_from_system()
	var current_day: String = str(active_cooperative_goals.get(DAILY_GOAL_DAY_KEY, ""))
	if not force and current_day == today and active_cooperative_goals.size() > 0:
		return

	active_cooperative_goals.clear()
	for template in GOAL_TEMPLATES:
		var id: String = str(template.get("id", ""))
		active_cooperative_goals[id] = {
			"id": id,
			"label": template.get("label", id),
			"description": template.get("description", ""),
			"target": int(template.get("target", 0)),
			"progress": 0,
			"reward_points": int(template.get("reward_points", 0)),
			"reward_tokens": int(template.get("reward_tokens", 0)),
			"contributors": {},
			"completed": false,
			"created_date": today,
			"completed_unix": 0,
		}
	active_cooperative_goals[DAILY_GOAL_DAY_KEY] = today

func _maybe_progress_goal(user_id: String, preferred_goal_id: String, amount: int) -> void:
	if amount <= 0:
		return
	if not preferred_goal_id.is_empty() and active_cooperative_goals.has(preferred_goal_id):
		var goal: Dictionary = active_cooperative_goals[preferred_goal_id]
		if not bool(goal.get("completed", false)):
			_apply_goal_contribution(preferred_goal_id, user_id, amount)
		return
	if active_cooperative_goals.has("daily_sync"):
		var fallback: Dictionary = active_cooperative_goals["daily_sync"]
		if not bool(fallback.get("completed", false)):
			_apply_goal_contribution("daily_sync", user_id, amount)

func _apply_goal_contribution(goal_id: String, user_id: String, contribution: int) -> void:
	if not active_cooperative_goals.has(goal_id):
		return
	var goal: Dictionary = active_cooperative_goals[goal_id]
	var contributors: Dictionary = goal.get("contributors", {})
	contributors[user_id] = int(contributors.get(user_id, 0)) + contribution
	goal["contributors"] = contributors
	goal["progress"] = min(int(goal.get("target", 0)), int(goal.get("progress", 0)) + contribution)
	active_cooperative_goals[goal_id] = goal
	emit_signal("cooperative_goal_progress", goal_id, int(goal.get("progress", 0)), int(goal.get("target", 0)))
	if int(goal.get("progress", 0)) >= int(goal.get("target", 0)):
		_complete_goal(goal_id)

func _complete_goal(goal_id: String) -> void:
	if not active_cooperative_goals.has(goal_id):
		return
	var goal: Dictionary = active_cooperative_goals[goal_id]
	if bool(goal.get("completed", false)):
		return

	goal["completed"] = true
	goal["completed_unix"] = int(Time.get_unix_time_from_system())
	active_cooperative_goals[goal_id] = goal

	var contributors: Dictionary = goal.get("contributors", {})
	for uid in contributors.keys():
		if not prestige_profiles.has(uid):
			continue
		var profile: Dictionary = prestige_profiles[uid]
		var weight: int = int(contributors[uid])
		_add_points(profile, int(goal.get("reward_points", 0)) + weight * 3, "cooperative_goal_reward")
		_unlock_status_markers(uid, profile)
		if weight >= 2:
			_maybe_grant_limited_item(uid, profile)
		prestige_profiles[uid] = profile
		emit_signal("prestige_updated", uid, profile)

	emit_signal("cooperative_goal_completed", goal_id, goal.duplicate(true))

func _maybe_grant_limited_item(user_id: String, profile: Dictionary) -> void:
	var available: Array = get_available_limited_items(user_id)
	if available.is_empty():
		return
	available.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("cost", 0)) > int(b.get("cost", 0))
	)
	var item: Dictionary = available[0]
	var inventory: Array = profile.get("limited_inventory", [])
	inventory.append({
		"id": item.get("id", ""),
		"name": item.get("name", ""),
		"rarity": item.get("rarity", ""),
		"granted_unix": int(Time.get_unix_time_from_system()),
		"expires_unix": int(Time.get_unix_time_from_system()) + int(item.get("duration_days", 0)) * 86400,
	})
	profile["limited_inventory"] = inventory
	emit_signal("limited_item_granted", user_id, str(item.get("id", "")))

func _result(success: bool, message: String, data: Dictionary = {}) -> Dictionary:
	return {
		"success": success,
		"message": message,
		"data": data,
	}
