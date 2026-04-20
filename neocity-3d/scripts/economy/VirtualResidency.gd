## VirtualResidency.gd
## -----------------------------------------------------------------------------
## Core residency ownership service.
## -----------------------------------------------------------------------------

extends Node
class_name VirtualResidency

signal resident_registered(user_id: String)
signal profile_updated(user_id: String, profile: Dictionary)
signal residency_tier_upgraded(user_id: String, previous_tier: String, new_tier: String)
signal environment_reacted(user_id: String, environment_state: Dictionary)
signal neighborhood_tier_unlocked(user_id: String, tier_id: String)

const MAX_LAYOUT_SLOTS: int = 48
const MAX_DECOR_PALETTES: int = 16
const MAX_INVESTMENT_LOG_SIZE: int = 300
const CUSTOMIZATION_CATEGORIES: PackedStringArray = [
	"layout",
	"lighting",
	"audio",
	"materials",
	"garden",
	"artifact_wall",
	"ambient_fx",
]

const RESIDENCY_TIERS: Array = [
	{
		"id": "starter",
		"name": "Starter Pod",
		"min_points": 0,
		"min_days": 0,
		"neighborhood": "Neon Courtyard",
		"unlock": ["basic_layout", "warm_lights", "entry_garden"],
	},
	{
		"id": "resident",
		"name": "Resident Loft",
		"min_points": 300,
		"min_days": 5,
		"neighborhood": "Horizon Blocks",
		"unlock": ["split_level_layout", "kinetic_wall", "ambient_music_set"],
	},
	{
		"id": "citizen",
		"name": "City Citizen",
		"min_points": 1100,
		"min_days": 14,
		"neighborhood": "Skyline District",
		"unlock": ["atelier_layout", "holo_balcony", "waterfall_projection"],
	},
	{
		"id": "visionary",
		"name": "Urban Visionary",
		"min_points": 2600,
		"min_days": 35,
		"neighborhood": "Aurora Terraces",
		"unlock": ["atrium_layout", "signature_lighting", "living_sculpture"],
	},
	{
		"id": "sovereign",
		"name": "Digital Sovereign",
		"min_points": 5200,
		"min_days": 75,
		"neighborhood": "Celestial Crown",
		"unlock": ["estate_layout", "climate_orchestra", "legacy_gallery"],
	},
]

const PRESENCE_REACTION_CURVES: Dictionary = {
	"morning": {
		"sky_tint": Color("#77d4ff"),
		"fog_density": 0.08,
		"ambient_track": "dawn_bloom",
		"npc_activity_multiplier": 1.05,
	},
	"day": {
		"sky_tint": Color("#8df5ff"),
		"fog_density": 0.03,
		"ambient_track": "city_hum",
		"npc_activity_multiplier": 1.0,
	},
	"dusk": {
		"sky_tint": Color("#ff8ee5"),
		"fog_density": 0.1,
		"ambient_track": "horizon_pulse",
		"npc_activity_multiplier": 1.15,
	},
	"night": {
		"sky_tint": Color("#5b7dff"),
		"fog_density": 0.18,
		"ambient_track": "nocturne_neon",
		"npc_activity_multiplier": 1.25,
	},
}

const PERSONALIZATION_LIBRARY: Dictionary = {
	"layout": [
		{
			"id": "layout_option_01",
			"name": "Space Layout Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["layout", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "layout_option_02",
			"name": "Space Layout Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["layout", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "layout_option_03",
			"name": "Space Layout Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["layout", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "layout_option_04",
			"name": "Space Layout Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["layout", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "layout_option_05",
			"name": "Space Layout Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["layout", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "layout_option_06",
			"name": "Space Layout Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["layout", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "layout_option_07",
			"name": "Space Layout Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["layout", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "layout_option_08",
			"name": "Space Layout Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["layout", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "layout_option_09",
			"name": "Space Layout Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["layout", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "layout_option_10",
			"name": "Space Layout Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["layout", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "layout_option_11",
			"name": "Space Layout Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["layout", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "layout_option_12",
			"name": "Space Layout Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["layout", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "layout_option_13",
			"name": "Space Layout Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["layout", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "layout_option_14",
			"name": "Space Layout Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["layout", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "layout_option_15",
			"name": "Space Layout Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["layout", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "layout_option_16",
			"name": "Space Layout Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["layout", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "layout_option_17",
			"name": "Space Layout Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["layout", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "layout_option_18",
			"name": "Space Layout Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["layout", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "layout_option_19",
			"name": "Space Layout Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["layout", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "layout_option_20",
			"name": "Space Layout Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["layout", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "layout_option_21",
			"name": "Space Layout Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["layout", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "layout_option_22",
			"name": "Space Layout Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["layout", "ownership", "creative", "tier_sovereign"],
		},
	],
	"lighting": [
		{
			"id": "lighting_option_01",
			"name": "Lighting Rig Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["lighting", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "lighting_option_02",
			"name": "Lighting Rig Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["lighting", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "lighting_option_03",
			"name": "Lighting Rig Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["lighting", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "lighting_option_04",
			"name": "Lighting Rig Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["lighting", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "lighting_option_05",
			"name": "Lighting Rig Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["lighting", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "lighting_option_06",
			"name": "Lighting Rig Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["lighting", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "lighting_option_07",
			"name": "Lighting Rig Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["lighting", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "lighting_option_08",
			"name": "Lighting Rig Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["lighting", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "lighting_option_09",
			"name": "Lighting Rig Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["lighting", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "lighting_option_10",
			"name": "Lighting Rig Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["lighting", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "lighting_option_11",
			"name": "Lighting Rig Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["lighting", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "lighting_option_12",
			"name": "Lighting Rig Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["lighting", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "lighting_option_13",
			"name": "Lighting Rig Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["lighting", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "lighting_option_14",
			"name": "Lighting Rig Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["lighting", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "lighting_option_15",
			"name": "Lighting Rig Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["lighting", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "lighting_option_16",
			"name": "Lighting Rig Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["lighting", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "lighting_option_17",
			"name": "Lighting Rig Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["lighting", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "lighting_option_18",
			"name": "Lighting Rig Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["lighting", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "lighting_option_19",
			"name": "Lighting Rig Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["lighting", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "lighting_option_20",
			"name": "Lighting Rig Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["lighting", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "lighting_option_21",
			"name": "Lighting Rig Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["lighting", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "lighting_option_22",
			"name": "Lighting Rig Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["lighting", "ownership", "creative", "tier_sovereign"],
		},
	],
	"audio": [
		{
			"id": "audio_option_01",
			"name": "Audioscape Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["audio", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "audio_option_02",
			"name": "Audioscape Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["audio", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "audio_option_03",
			"name": "Audioscape Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["audio", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "audio_option_04",
			"name": "Audioscape Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["audio", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "audio_option_05",
			"name": "Audioscape Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["audio", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "audio_option_06",
			"name": "Audioscape Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["audio", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "audio_option_07",
			"name": "Audioscape Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["audio", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "audio_option_08",
			"name": "Audioscape Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["audio", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "audio_option_09",
			"name": "Audioscape Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["audio", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "audio_option_10",
			"name": "Audioscape Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["audio", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "audio_option_11",
			"name": "Audioscape Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["audio", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "audio_option_12",
			"name": "Audioscape Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["audio", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "audio_option_13",
			"name": "Audioscape Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["audio", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "audio_option_14",
			"name": "Audioscape Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["audio", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "audio_option_15",
			"name": "Audioscape Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["audio", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "audio_option_16",
			"name": "Audioscape Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["audio", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "audio_option_17",
			"name": "Audioscape Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["audio", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "audio_option_18",
			"name": "Audioscape Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["audio", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "audio_option_19",
			"name": "Audioscape Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["audio", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "audio_option_20",
			"name": "Audioscape Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["audio", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "audio_option_21",
			"name": "Audioscape Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["audio", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "audio_option_22",
			"name": "Audioscape Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["audio", "ownership", "creative", "tier_sovereign"],
		},
	],
	"materials": [
		{
			"id": "materials_option_01",
			"name": "Material Pack Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["materials", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "materials_option_02",
			"name": "Material Pack Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["materials", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "materials_option_03",
			"name": "Material Pack Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["materials", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "materials_option_04",
			"name": "Material Pack Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["materials", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "materials_option_05",
			"name": "Material Pack Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["materials", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "materials_option_06",
			"name": "Material Pack Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["materials", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "materials_option_07",
			"name": "Material Pack Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["materials", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "materials_option_08",
			"name": "Material Pack Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["materials", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "materials_option_09",
			"name": "Material Pack Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["materials", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "materials_option_10",
			"name": "Material Pack Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["materials", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "materials_option_11",
			"name": "Material Pack Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["materials", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "materials_option_12",
			"name": "Material Pack Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["materials", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "materials_option_13",
			"name": "Material Pack Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["materials", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "materials_option_14",
			"name": "Material Pack Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["materials", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "materials_option_15",
			"name": "Material Pack Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["materials", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "materials_option_16",
			"name": "Material Pack Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["materials", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "materials_option_17",
			"name": "Material Pack Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["materials", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "materials_option_18",
			"name": "Material Pack Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["materials", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "materials_option_19",
			"name": "Material Pack Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["materials", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "materials_option_20",
			"name": "Material Pack Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["materials", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "materials_option_21",
			"name": "Material Pack Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["materials", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "materials_option_22",
			"name": "Material Pack Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["materials", "ownership", "creative", "tier_sovereign"],
		},
	],
	"garden": [
		{
			"id": "garden_option_01",
			"name": "Bio Garden Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["garden", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "garden_option_02",
			"name": "Bio Garden Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["garden", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "garden_option_03",
			"name": "Bio Garden Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["garden", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "garden_option_04",
			"name": "Bio Garden Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["garden", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "garden_option_05",
			"name": "Bio Garden Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["garden", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "garden_option_06",
			"name": "Bio Garden Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["garden", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "garden_option_07",
			"name": "Bio Garden Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["garden", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "garden_option_08",
			"name": "Bio Garden Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["garden", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "garden_option_09",
			"name": "Bio Garden Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["garden", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "garden_option_10",
			"name": "Bio Garden Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["garden", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "garden_option_11",
			"name": "Bio Garden Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["garden", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "garden_option_12",
			"name": "Bio Garden Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["garden", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "garden_option_13",
			"name": "Bio Garden Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["garden", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "garden_option_14",
			"name": "Bio Garden Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["garden", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "garden_option_15",
			"name": "Bio Garden Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["garden", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "garden_option_16",
			"name": "Bio Garden Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["garden", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "garden_option_17",
			"name": "Bio Garden Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["garden", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "garden_option_18",
			"name": "Bio Garden Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["garden", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "garden_option_19",
			"name": "Bio Garden Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["garden", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "garden_option_20",
			"name": "Bio Garden Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["garden", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "garden_option_21",
			"name": "Bio Garden Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["garden", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "garden_option_22",
			"name": "Bio Garden Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["garden", "ownership", "creative", "tier_sovereign"],
		},
	],
	"artifact_wall": [
		{
			"id": "artifact_wall_option_01",
			"name": "Artifact Wall Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["artifact_wall", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "artifact_wall_option_02",
			"name": "Artifact Wall Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["artifact_wall", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "artifact_wall_option_03",
			"name": "Artifact Wall Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["artifact_wall", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "artifact_wall_option_04",
			"name": "Artifact Wall Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["artifact_wall", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "artifact_wall_option_05",
			"name": "Artifact Wall Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["artifact_wall", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "artifact_wall_option_06",
			"name": "Artifact Wall Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["artifact_wall", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "artifact_wall_option_07",
			"name": "Artifact Wall Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["artifact_wall", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "artifact_wall_option_08",
			"name": "Artifact Wall Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["artifact_wall", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "artifact_wall_option_09",
			"name": "Artifact Wall Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["artifact_wall", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "artifact_wall_option_10",
			"name": "Artifact Wall Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["artifact_wall", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "artifact_wall_option_11",
			"name": "Artifact Wall Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["artifact_wall", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "artifact_wall_option_12",
			"name": "Artifact Wall Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["artifact_wall", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "artifact_wall_option_13",
			"name": "Artifact Wall Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["artifact_wall", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "artifact_wall_option_14",
			"name": "Artifact Wall Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["artifact_wall", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "artifact_wall_option_15",
			"name": "Artifact Wall Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["artifact_wall", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "artifact_wall_option_16",
			"name": "Artifact Wall Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["artifact_wall", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "artifact_wall_option_17",
			"name": "Artifact Wall Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["artifact_wall", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "artifact_wall_option_18",
			"name": "Artifact Wall Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["artifact_wall", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "artifact_wall_option_19",
			"name": "Artifact Wall Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["artifact_wall", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "artifact_wall_option_20",
			"name": "Artifact Wall Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["artifact_wall", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "artifact_wall_option_21",
			"name": "Artifact Wall Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["artifact_wall", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "artifact_wall_option_22",
			"name": "Artifact Wall Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["artifact_wall", "ownership", "creative", "tier_sovereign"],
		},
	],
	"ambient_fx": [
		{
			"id": "ambient_fx_option_01",
			"name": "Ambient FX Variant 01",
			"required_tier": "starter",
			"investment_floor": 47,
			"prestige_weight": 2,
			"tags": ["ambient_fx", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "ambient_fx_option_02",
			"name": "Ambient FX Variant 02",
			"required_tier": "starter",
			"investment_floor": 54,
			"prestige_weight": 3,
			"tags": ["ambient_fx", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "ambient_fx_option_03",
			"name": "Ambient FX Variant 03",
			"required_tier": "starter",
			"investment_floor": 61,
			"prestige_weight": 4,
			"tags": ["ambient_fx", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "ambient_fx_option_04",
			"name": "Ambient FX Variant 04",
			"required_tier": "starter",
			"investment_floor": 68,
			"prestige_weight": 5,
			"tags": ["ambient_fx", "ownership", "creative", "tier_starter"],
		},
		{
			"id": "ambient_fx_option_05",
			"name": "Ambient FX Variant 05",
			"required_tier": "resident",
			"investment_floor": 75,
			"prestige_weight": 1,
			"tags": ["ambient_fx", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "ambient_fx_option_06",
			"name": "Ambient FX Variant 06",
			"required_tier": "resident",
			"investment_floor": 82,
			"prestige_weight": 2,
			"tags": ["ambient_fx", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "ambient_fx_option_07",
			"name": "Ambient FX Variant 07",
			"required_tier": "resident",
			"investment_floor": 89,
			"prestige_weight": 3,
			"tags": ["ambient_fx", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "ambient_fx_option_08",
			"name": "Ambient FX Variant 08",
			"required_tier": "resident",
			"investment_floor": 96,
			"prestige_weight": 4,
			"tags": ["ambient_fx", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "ambient_fx_option_09",
			"name": "Ambient FX Variant 09",
			"required_tier": "resident",
			"investment_floor": 103,
			"prestige_weight": 5,
			"tags": ["ambient_fx", "ownership", "creative", "tier_resident"],
		},
		{
			"id": "ambient_fx_option_10",
			"name": "Ambient FX Variant 10",
			"required_tier": "citizen",
			"investment_floor": 110,
			"prestige_weight": 1,
			"tags": ["ambient_fx", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "ambient_fx_option_11",
			"name": "Ambient FX Variant 11",
			"required_tier": "citizen",
			"investment_floor": 117,
			"prestige_weight": 2,
			"tags": ["ambient_fx", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "ambient_fx_option_12",
			"name": "Ambient FX Variant 12",
			"required_tier": "citizen",
			"investment_floor": 124,
			"prestige_weight": 3,
			"tags": ["ambient_fx", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "ambient_fx_option_13",
			"name": "Ambient FX Variant 13",
			"required_tier": "citizen",
			"investment_floor": 131,
			"prestige_weight": 4,
			"tags": ["ambient_fx", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "ambient_fx_option_14",
			"name": "Ambient FX Variant 14",
			"required_tier": "citizen",
			"investment_floor": 138,
			"prestige_weight": 5,
			"tags": ["ambient_fx", "ownership", "creative", "tier_citizen"],
		},
		{
			"id": "ambient_fx_option_15",
			"name": "Ambient FX Variant 15",
			"required_tier": "visionary",
			"investment_floor": 145,
			"prestige_weight": 1,
			"tags": ["ambient_fx", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "ambient_fx_option_16",
			"name": "Ambient FX Variant 16",
			"required_tier": "visionary",
			"investment_floor": 152,
			"prestige_weight": 2,
			"tags": ["ambient_fx", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "ambient_fx_option_17",
			"name": "Ambient FX Variant 17",
			"required_tier": "visionary",
			"investment_floor": 159,
			"prestige_weight": 3,
			"tags": ["ambient_fx", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "ambient_fx_option_18",
			"name": "Ambient FX Variant 18",
			"required_tier": "visionary",
			"investment_floor": 166,
			"prestige_weight": 4,
			"tags": ["ambient_fx", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "ambient_fx_option_19",
			"name": "Ambient FX Variant 19",
			"required_tier": "visionary",
			"investment_floor": 173,
			"prestige_weight": 5,
			"tags": ["ambient_fx", "ownership", "creative", "tier_visionary"],
		},
		{
			"id": "ambient_fx_option_20",
			"name": "Ambient FX Variant 20",
			"required_tier": "sovereign",
			"investment_floor": 180,
			"prestige_weight": 1,
			"tags": ["ambient_fx", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "ambient_fx_option_21",
			"name": "Ambient FX Variant 21",
			"required_tier": "sovereign",
			"investment_floor": 187,
			"prestige_weight": 2,
			"tags": ["ambient_fx", "ownership", "creative", "tier_sovereign"],
		},
		{
			"id": "ambient_fx_option_22",
			"name": "Ambient FX Variant 22",
			"required_tier": "sovereign",
			"investment_floor": 194,
			"prestige_weight": 3,
			"tags": ["ambient_fx", "ownership", "creative", "tier_sovereign"],
		},
	],
}

const NEIGHBORHOOD_REACTIVE_SCENARIOS: Array = [
	{
		"id": "scenario_01",
		"name": "Reactive Scenario 01",
		"required_tier": "starter",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_2", "flora_pulse_2", "crowd_echo_2"],
		"duration_seconds": 96,
	},
	{
		"id": "scenario_02",
		"name": "Reactive Scenario 02",
		"required_tier": "starter",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_3", "flora_pulse_3", "crowd_echo_3"],
		"duration_seconds": 102,
	},
	{
		"id": "scenario_03",
		"name": "Reactive Scenario 03",
		"required_tier": "starter",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_4", "flora_pulse_4", "crowd_echo_1"],
		"duration_seconds": 108,
	},
	{
		"id": "scenario_04",
		"name": "Reactive Scenario 04",
		"required_tier": "starter",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_1", "flora_pulse_5", "crowd_echo_2"],
		"duration_seconds": 114,
	},
	{
		"id": "scenario_05",
		"name": "Reactive Scenario 05",
		"required_tier": "starter",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_2", "flora_pulse_1", "crowd_echo_3"],
		"duration_seconds": 120,
	},
	{
		"id": "scenario_06",
		"name": "Reactive Scenario 06",
		"required_tier": "starter",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_3", "flora_pulse_2", "crowd_echo_1"],
		"duration_seconds": 126,
	},
	{
		"id": "scenario_07",
		"name": "Reactive Scenario 07",
		"required_tier": "starter",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_4", "flora_pulse_3", "crowd_echo_2"],
		"duration_seconds": 132,
	},
	{
		"id": "scenario_08",
		"name": "Reactive Scenario 08",
		"required_tier": "resident",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_1", "flora_pulse_4", "crowd_echo_3"],
		"duration_seconds": 138,
	},
	{
		"id": "scenario_09",
		"name": "Reactive Scenario 09",
		"required_tier": "resident",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_2", "flora_pulse_5", "crowd_echo_1"],
		"duration_seconds": 144,
	},
	{
		"id": "scenario_10",
		"name": "Reactive Scenario 10",
		"required_tier": "resident",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_3", "flora_pulse_1", "crowd_echo_2"],
		"duration_seconds": 150,
	},
	{
		"id": "scenario_11",
		"name": "Reactive Scenario 11",
		"required_tier": "resident",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_4", "flora_pulse_2", "crowd_echo_3"],
		"duration_seconds": 156,
	},
	{
		"id": "scenario_12",
		"name": "Reactive Scenario 12",
		"required_tier": "resident",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_1", "flora_pulse_3", "crowd_echo_1"],
		"duration_seconds": 162,
	},
	{
		"id": "scenario_13",
		"name": "Reactive Scenario 13",
		"required_tier": "resident",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_2", "flora_pulse_4", "crowd_echo_2"],
		"duration_seconds": 168,
	},
	{
		"id": "scenario_14",
		"name": "Reactive Scenario 14",
		"required_tier": "resident",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_3", "flora_pulse_5", "crowd_echo_3"],
		"duration_seconds": 174,
	},
	{
		"id": "scenario_15",
		"name": "Reactive Scenario 15",
		"required_tier": "resident",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_4", "flora_pulse_1", "crowd_echo_1"],
		"duration_seconds": 180,
	},
	{
		"id": "scenario_16",
		"name": "Reactive Scenario 16",
		"required_tier": "citizen",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_1", "flora_pulse_2", "crowd_echo_2"],
		"duration_seconds": 186,
	},
	{
		"id": "scenario_17",
		"name": "Reactive Scenario 17",
		"required_tier": "citizen",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_2", "flora_pulse_3", "crowd_echo_3"],
		"duration_seconds": 192,
	},
	{
		"id": "scenario_18",
		"name": "Reactive Scenario 18",
		"required_tier": "citizen",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_3", "flora_pulse_4", "crowd_echo_1"],
		"duration_seconds": 198,
	},
	{
		"id": "scenario_19",
		"name": "Reactive Scenario 19",
		"required_tier": "citizen",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_4", "flora_pulse_5", "crowd_echo_2"],
		"duration_seconds": 204,
	},
	{
		"id": "scenario_20",
		"name": "Reactive Scenario 20",
		"required_tier": "citizen",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_1", "flora_pulse_1", "crowd_echo_3"],
		"duration_seconds": 210,
	},
	{
		"id": "scenario_21",
		"name": "Reactive Scenario 21",
		"required_tier": "citizen",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_2", "flora_pulse_2", "crowd_echo_1"],
		"duration_seconds": 216,
	},
	{
		"id": "scenario_22",
		"name": "Reactive Scenario 22",
		"required_tier": "citizen",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_3", "flora_pulse_3", "crowd_echo_2"],
		"duration_seconds": 222,
	},
	{
		"id": "scenario_23",
		"name": "Reactive Scenario 23",
		"required_tier": "citizen",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_4", "flora_pulse_4", "crowd_echo_3"],
		"duration_seconds": 228,
	},
	{
		"id": "scenario_24",
		"name": "Reactive Scenario 24",
		"required_tier": "visionary",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_1", "flora_pulse_5", "crowd_echo_1"],
		"duration_seconds": 234,
	},
	{
		"id": "scenario_25",
		"name": "Reactive Scenario 25",
		"required_tier": "visionary",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_2", "flora_pulse_1", "crowd_echo_2"],
		"duration_seconds": 240,
	},
	{
		"id": "scenario_26",
		"name": "Reactive Scenario 26",
		"required_tier": "visionary",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_3", "flora_pulse_2", "crowd_echo_3"],
		"duration_seconds": 246,
	},
	{
		"id": "scenario_27",
		"name": "Reactive Scenario 27",
		"required_tier": "visionary",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_4", "flora_pulse_3", "crowd_echo_1"],
		"duration_seconds": 252,
	},
	{
		"id": "scenario_28",
		"name": "Reactive Scenario 28",
		"required_tier": "visionary",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_1", "flora_pulse_4", "crowd_echo_2"],
		"duration_seconds": 258,
	},
	{
		"id": "scenario_29",
		"name": "Reactive Scenario 29",
		"required_tier": "visionary",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_2", "flora_pulse_5", "crowd_echo_3"],
		"duration_seconds": 264,
	},
	{
		"id": "scenario_30",
		"name": "Reactive Scenario 30",
		"required_tier": "visionary",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_3", "flora_pulse_1", "crowd_echo_1"],
		"duration_seconds": 270,
	},
	{
		"id": "scenario_31",
		"name": "Reactive Scenario 31",
		"required_tier": "visionary",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_4", "flora_pulse_2", "crowd_echo_2"],
		"duration_seconds": 276,
	},
	{
		"id": "scenario_32",
		"name": "Reactive Scenario 32",
		"required_tier": "sovereign",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_1", "flora_pulse_3", "crowd_echo_3"],
		"duration_seconds": 282,
	},
	{
		"id": "scenario_33",
		"name": "Reactive Scenario 33",
		"required_tier": "sovereign",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_2", "flora_pulse_4", "crowd_echo_1"],
		"duration_seconds": 288,
	},
	{
		"id": "scenario_34",
		"name": "Reactive Scenario 34",
		"required_tier": "sovereign",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_3", "flora_pulse_5", "crowd_echo_2"],
		"duration_seconds": 294,
	},
	{
		"id": "scenario_35",
		"name": "Reactive Scenario 35",
		"required_tier": "sovereign",
		"trigger": "presence_wave_6",
		"effects": ["sky_shift_4", "flora_pulse_1", "crowd_echo_3"],
		"duration_seconds": 300,
	},
	{
		"id": "scenario_36",
		"name": "Reactive Scenario 36",
		"required_tier": "sovereign",
		"trigger": "presence_wave_1",
		"effects": ["sky_shift_1", "flora_pulse_2", "crowd_echo_1"],
		"duration_seconds": 306,
	},
	{
		"id": "scenario_37",
		"name": "Reactive Scenario 37",
		"required_tier": "sovereign",
		"trigger": "presence_wave_2",
		"effects": ["sky_shift_2", "flora_pulse_3", "crowd_echo_2"],
		"duration_seconds": 312,
	},
	{
		"id": "scenario_38",
		"name": "Reactive Scenario 38",
		"required_tier": "sovereign",
		"trigger": "presence_wave_3",
		"effects": ["sky_shift_3", "flora_pulse_4", "crowd_echo_3"],
		"duration_seconds": 318,
	},
	{
		"id": "scenario_39",
		"name": "Reactive Scenario 39",
		"required_tier": "sovereign",
		"trigger": "presence_wave_4",
		"effects": ["sky_shift_4", "flora_pulse_5", "crowd_echo_1"],
		"duration_seconds": 324,
	},
	{
		"id": "scenario_40",
		"name": "Reactive Scenario 40",
		"required_tier": "sovereign",
		"trigger": "presence_wave_5",
		"effects": ["sky_shift_1", "flora_pulse_1", "crowd_echo_2"],
		"duration_seconds": 330,
	},
]

var resident_profiles: Dictionary = {}
var neighborhood_unlocks: Dictionary = {}
var environment_state: Dictionary = {
	"global_activity": 0.0,
	"dominant_track": "city_hum",
	"shared_sky_tint": Color("#8df5ff"),
	"event_intensity": 0.0,
	"last_updated_unix": 0,
}

func register_resident(user_id: String, display_name: String = "") -> void:
	if user_id.is_empty():
		return
	if resident_profiles.has(user_id):
		return
	resident_profiles[user_id] = _make_profile(user_id, display_name)
	neighborhood_unlocks[user_id] = ["starter"]
	emit_signal("resident_registered", user_id)
	emit_signal("profile_updated", user_id, resident_profiles[user_id])

func ensure_resident(user_id: String) -> void:
	if not resident_profiles.has(user_id):
		register_resident(user_id, user_id)

func invest_in_customization(
	user_id: String,
	category: String,
	option_id: String,
	investment_points: int,
	notes: Dictionary = {}
) -> Dictionary:
	ensure_resident(user_id)
	var profile: Dictionary = resident_profiles[user_id]
	if not CUSTOMIZATION_CATEGORIES.has(category):
		return _result(false, "Unknown customization category.")
	if option_id.is_empty():
		return _result(false, "Option id is required.")
	if investment_points <= 0:
		return _result(false, "Investment points must be positive.")

	var home: Dictionary = profile["home"]
	var investment_log: Array = home.get("investment_log", [])
	investment_log.push_front({
		"category": category,
		"option_id": option_id,
		"points": investment_points,
		"notes": notes,
		"timestamp": int(Time.get_unix_time_from_system()),
	})
	if investment_log.size() > MAX_INVESTMENT_LOG_SIZE:
		investment_log.resize(MAX_INVESTMENT_LOG_SIZE)
	home["investment_log"] = investment_log

	var category_state: Dictionary = home.get("categories", {})
	if not category_state.has(category):
		category_state[category] = {
			"equipped_option": option_id,
			"options": {},
		}
	var category_entry: Dictionary = category_state[category]
	category_entry["equipped_option"] = option_id
	var options: Dictionary = category_entry.get("options", {})
	var prev_points: int = int(options.get(option_id, 0))
	options[option_id] = prev_points + investment_points
	category_entry["options"] = options
	category_state[category] = category_entry
	home["categories"] = category_state

	home["total_investment_points"] = int(home.get("total_investment_points", 0)) + investment_points
	home["last_customized_unix"] = int(Time.get_unix_time_from_system())
	profile["home"] = home

	_add_residency_points(profile, int(round(investment_points * 1.35)))
	_update_progression(profile)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Customization investment recorded.", {"profile": profile})

func apply_layout_blueprint(user_id: String, blueprint_id: String, slots: Array) -> Dictionary:
	ensure_resident(user_id)
	if blueprint_id.is_empty():
		return _result(false, "Blueprint id is required.")
	if slots.size() > MAX_LAYOUT_SLOTS:
		return _result(false, "Layout exceeds max slots.")

	var profile: Dictionary = resident_profiles[user_id]
	var home: Dictionary = profile["home"]
	home["layout"] = {
		"id": blueprint_id,
		"slots": slots.duplicate(true),
		"updated_unix": int(Time.get_unix_time_from_system()),
	}
	profile["home"] = home
	_add_residency_points(profile, 40 + slots.size() * 2)
	_update_progression(profile)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Layout blueprint applied.", {"layout": home["layout"]})

func set_personal_palette(user_id: String, palette: Array) -> Dictionary:
	ensure_resident(user_id)
	if palette.is_empty():
		return _result(false, "Palette cannot be empty.")
	if palette.size() > MAX_DECOR_PALETTES:
		return _result(false, "Palette exceeds max entries.")

	var profile: Dictionary = resident_profiles[user_id]
	profile["home"]["palette"] = palette.duplicate(true)
	profile["home"]["last_customized_unix"] = int(Time.get_unix_time_from_system())
	_add_residency_points(profile, 22 + palette.size())
	_update_progression(profile)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Personal palette updated.", {"palette": palette})

func record_presence(user_id: String, zone_id: String, duration_minutes: int) -> Dictionary:
	ensure_resident(user_id)
	if zone_id.is_empty():
		return _result(false, "Zone id is required.")
	if duration_minutes <= 0:
		return _result(false, "Presence duration must be positive.")

	var profile: Dictionary = resident_profiles[user_id]
	var stats: Dictionary = profile["presence"]
	stats["minutes_total"] = int(stats.get("minutes_total", 0)) + duration_minutes
	stats["last_zone"] = zone_id
	stats["last_seen_unix"] = int(Time.get_unix_time_from_system())

	var daily_checkins: Dictionary = stats.get("daily_checkins", {})
	var today: String = Time.get_date_string_from_system()
	if not daily_checkins.has(today):
		daily_checkins[today] = []
	if not (daily_checkins[today] as Array).has(zone_id):
		(daily_checkins[today] as Array).append(zone_id)
	stats["daily_checkins"] = daily_checkins

	profile["presence"] = stats
	_add_residency_points(profile, min(120, duration_minutes))
	_update_progression(profile)
	_apply_dynamic_environment(user_id, profile)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Presence recorded.", {"presence": stats})

func record_sustained_participation(user_id: String, participation_units: int) -> Dictionary:
	ensure_resident(user_id)
	if participation_units <= 0:
		return _result(false, "Participation units must be positive.")
	var profile: Dictionary = resident_profiles[user_id]
	var continuity: Dictionary = profile["continuity"]
	continuity["days_active"] = int(continuity.get("days_active", 0)) + participation_units
	continuity["last_active_unix"] = int(Time.get_unix_time_from_system())
	profile["continuity"] = continuity
	_add_residency_points(profile, participation_units * 20)
	_update_progression(profile)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Participation streak extended.", {"continuity": continuity})

func force_environment_context(user_id: String, day_phase: String, crowd_intensity: float = 0.5) -> Dictionary:
	ensure_resident(user_id)
	var profile: Dictionary = resident_profiles[user_id]
	_apply_dynamic_environment(user_id, profile, day_phase, crowd_intensity)
	resident_profiles[user_id] = profile
	emit_signal("profile_updated", user_id, profile)
	return _result(true, "Environment context applied.", {"environment": profile["environment"]})

func get_profile(user_id: String) -> Dictionary:
	if not resident_profiles.has(user_id):
		return {}
	return resident_profiles[user_id].duplicate(true)

func get_next_tier_path(user_id: String) -> Dictionary:
	if not resident_profiles.has(user_id):
		return {}
	var profile: Dictionary = resident_profiles[user_id]
	var current_idx: int = _tier_index(profile.get("tier_id", "starter"))
	if current_idx >= RESIDENCY_TIERS.size() - 1:
		return {
			"reached_cap": true,
			"current_tier": profile.get("tier_id", "starter"),
			"next_tier": "",
			"points_remaining": 0,
			"days_remaining": 0,
		}
	var next_tier: Dictionary = RESIDENCY_TIERS[current_idx + 1]
	var progress: Dictionary = profile.get("progress", {})
	return {
		"reached_cap": false,
		"current_tier": profile.get("tier_id", "starter"),
		"next_tier": next_tier.get("id", ""),
		"next_tier_name": next_tier.get("name", ""),
		"points_remaining": max(0, int(next_tier.get("min_points", 0)) - int(progress.get("points", 0))),
		"days_remaining": max(0, int(next_tier.get("min_days", 0)) - int(profile.get("continuity", {}).get("days_active", 0))),
		"unlock_preview": next_tier.get("unlock", []).duplicate(true),
	}

func get_global_environment_state() -> Dictionary:
	return environment_state.duplicate(true)

func get_customization_options(category: String, tier_id: String = "") -> Array:
	if not PERSONALIZATION_LIBRARY.has(category):
		return []
	var tier_idx: int = _tier_index(tier_id if not tier_id.is_empty() else "starter")
	var out: Array = []
	for option in PERSONALIZATION_LIBRARY[category]:
		var required_tier: String = str(option.get("required_tier", "starter"))
		if _tier_index(required_tier) <= tier_idx:
			out.append(option.duplicate(true))
	return out

func get_reactive_scenarios_for_tier(tier_id: String) -> Array:
	var out: Array = []
	var idx: int = _tier_index(tier_id)
	for scenario in NEIGHBORHOOD_REACTIVE_SCENARIOS:
		if _tier_index(str(scenario.get("required_tier", "starter"))) <= idx:
			out.append(scenario.duplicate(true))
	return out

func estimate_home_identity_score(user_id: String) -> Dictionary:
	if not resident_profiles.has(user_id):
		return {"score": 0, "label": "unregistered"}
	var profile: Dictionary = resident_profiles[user_id]
	var home: Dictionary = profile.get("home", {})
	var categories: Dictionary = home.get("categories", {})
	var category_count: int = categories.size()
	var investment: int = int(home.get("total_investment_points", 0))
	var palette_size: int = (home.get("palette", []) as Array).size()
	var streak_days: int = int(profile.get("continuity", {}).get("days_active", 0))
	var score: int = category_count * 50 + palette_size * 8 + int(investment * 0.35) + streak_days * 6
	var label: String = "curious"
	if score >= 2600:
		label = "iconic"
	elif score >= 1600:
		label = "distinctive"
	elif score >= 900:
		label = "settled"
	elif score >= 400:
		label = "growing"
	return {
		"score": score,
		"label": label,
		"category_count": category_count,
		"investment_points": investment,
		"palette_size": palette_size,
		"streak_days": streak_days,
	}

func get_personalization_library_snapshot() -> Dictionary:
	return {
		"categories": PERSONALIZATION_LIBRARY.duplicate(true),
		"scenarios": NEIGHBORHOOD_REACTIVE_SCENARIOS.duplicate(true),
	}


func debug_snapshot() -> Dictionary:
	return {
		"resident_count": resident_profiles.size(),
		"residents": resident_profiles.duplicate(true),
		"environment": environment_state.duplicate(true),
	}

func _make_profile(user_id: String, display_name: String) -> Dictionary:
	var name: String = display_name if not display_name.is_empty() else user_id
	return {
		"user_id": user_id,
		"display_name": name,
		"tier_id": "starter",
		"tier_name": "Starter Pod",
		"progress": {
			"points": 0,
			"points_lifetime": 0,
			"last_progress_unix": int(Time.get_unix_time_from_system()),
		},
		"continuity": {
			"days_active": 0,
			"last_active_unix": 0,
		},
		"home": {
			"layout": {"id": "starter_layout", "slots": [], "updated_unix": 0},
			"palette": [Color("#2f9cff"), Color("#ff4dd0"), Color("#1a1a2f")],
			"categories": {},
			"investment_log": [],
			"total_investment_points": 0,
			"last_customized_unix": 0,
		},
		"presence": {
			"minutes_total": 0,
			"last_zone": "",
			"last_seen_unix": 0,
			"daily_checkins": {},
		},
		"environment": {
			"day_phase": "day",
			"crowd_intensity": 0.0,
			"signature_track": "city_hum",
			"reactive_effects": [],
			"last_reaction_unix": 0,
		},
	}

func _add_residency_points(profile: Dictionary, points: int) -> void:
	if points <= 0:
		return
	var progress: Dictionary = profile["progress"]
	progress["points"] = int(progress.get("points", 0)) + points
	progress["points_lifetime"] = int(progress.get("points_lifetime", 0)) + points
	progress["last_progress_unix"] = int(Time.get_unix_time_from_system())
	profile["progress"] = progress

func _update_progression(profile: Dictionary) -> void:
	var current_tier_id: String = profile.get("tier_id", "starter")
	var progress: Dictionary = profile.get("progress", {})
	var continuity: Dictionary = profile.get("continuity", {})
	var points: int = int(progress.get("points", 0))
	var days_active: int = int(continuity.get("days_active", 0))
	var resolved_tier: Dictionary = RESIDENCY_TIERS[0]
	for tier_data in RESIDENCY_TIERS:
		if points >= int(tier_data.get("min_points", 0)) and days_active >= int(tier_data.get("min_days", 0)):
			resolved_tier = tier_data

	var resolved_tier_id: String = str(resolved_tier.get("id", "starter"))
	profile["tier_id"] = resolved_tier_id
	profile["tier_name"] = str(resolved_tier.get("name", "Starter Pod"))
	profile["neighborhood"] = str(resolved_tier.get("neighborhood", "Neon Courtyard"))
	if current_tier_id != resolved_tier_id:
		var uid: String = str(profile.get("user_id", ""))
		emit_signal("residency_tier_upgraded", uid, current_tier_id, resolved_tier_id)
		_unlock_neighborhood_tier(uid, resolved_tier_id)

func _unlock_neighborhood_tier(user_id: String, tier_id: String) -> void:
	if user_id.is_empty():
		return
	if not neighborhood_unlocks.has(user_id):
		neighborhood_unlocks[user_id] = []
	var unlocked: Array = neighborhood_unlocks[user_id]
	if not unlocked.has(tier_id):
		unlocked.append(tier_id)
		neighborhood_unlocks[user_id] = unlocked
		emit_signal("neighborhood_tier_unlocked", user_id, tier_id)

func _apply_dynamic_environment(
	user_id: String,
	profile: Dictionary,
	override_phase: String = "",
	override_crowd_intensity: float = -1.0
) -> void:
	var phase: String = override_phase
	if phase.is_empty():
		phase = _resolve_day_phase()
	if not PRESENCE_REACTION_CURVES.has(phase):
		phase = "day"

	var curve: Dictionary = PRESENCE_REACTION_CURVES[phase]
	var presence_minutes: int = int(profile.get("presence", {}).get("minutes_total", 0))
	var continuity_days: int = int(profile.get("continuity", {}).get("days_active", 0))
	var crowd_intensity: float = override_crowd_intensity
	if crowd_intensity < 0.0:
		crowd_intensity = clamp((presence_minutes / 300.0) + (continuity_days / 45.0), 0.0, 2.0)

	var effects: Array = []
	if continuity_days >= 7:
		effects.append("flora_bloom")
	if continuity_days >= 21:
		effects.append("district_fireflies")
	if continuity_days >= 60:
		effects.append("skyline_aurora")
	if int(profile.get("home", {}).get("total_investment_points", 0)) >= 1200:
		effects.append("resonant_holograms")

	var resident_env: Dictionary = profile.get("environment", {})
	resident_env["day_phase"] = phase
	resident_env["crowd_intensity"] = crowd_intensity
	resident_env["signature_track"] = str(curve.get("ambient_track", "city_hum"))
	resident_env["sky_tint"] = curve.get("sky_tint", Color("#8df5ff"))
	resident_env["fog_density"] = float(curve.get("fog_density", 0.06))
	resident_env["npc_activity_multiplier"] = float(curve.get("npc_activity_multiplier", 1.0)) + (crowd_intensity * 0.05)
	resident_env["reactive_effects"] = effects
	resident_env["last_reaction_unix"] = int(Time.get_unix_time_from_system())
	profile["environment"] = resident_env
	environment_state["global_activity"] = _compute_global_activity()
	environment_state["dominant_track"] = resident_env["signature_track"]
	environment_state["shared_sky_tint"] = resident_env["sky_tint"]
	environment_state["event_intensity"] = crowd_intensity
	environment_state["last_updated_unix"] = int(Time.get_unix_time_from_system())
	emit_signal("environment_reacted", user_id, resident_env)

func _resolve_day_phase() -> String:
	var hour: int = int(Time.get_datetime_dict_from_system().get("hour", 12))
	if hour >= 6 and hour < 11:
		return "morning"
	if hour >= 11 and hour < 17:
		return "day"
	if hour >= 17 and hour < 21:
		return "dusk"
	return "night"

func _compute_global_activity() -> float:
	if resident_profiles.is_empty():
		return 0.0
	var total: float = 0.0
	for profile in resident_profiles.values():
		total += float(profile.get("environment", {}).get("crowd_intensity", 0.0))
	return total / float(max(1, resident_profiles.size()))

func _tier_index(tier_id: String) -> int:
	for i in range(RESIDENCY_TIERS.size()):
		if str(RESIDENCY_TIERS[i].get("id", "")) == tier_id:
			return i
	return 0

func _result(success: bool, message: String, data: Dictionary = {}) -> Dictionary:
	return {
		"success": success,
		"message": message,
		"data": data,
	}
