## SpatialAnchorAd — Renders high-value Quantads auction payloads as in-world anchors
extends Node3D

@onready var anchor_mesh: MeshInstance3D = $AnchorMesh
@onready var label_3d: Label3D = $AnchorLabel

var _base_y: float = 0.0
var _cpc: float = 0.0
var _ad_id: String = ""

func _ready():
	_base_y = anchor_mesh.position.y

func configure_from_payload(payload: Dictionary):
	_ad_id = str(payload.get("id", "quantad"))
	_cpc = float(payload.get("cpc", 0.0))
	name = "quantad_anchor_%s_%s" % [str(_ad_id.hash()), str(_ad_id.length())]
	
	# Payload uses backend 2D plane coordinates x/y; world vertical is z -> y-axis in Godot.
	var world_x = float(payload.get("x", 0.0)) / 10.0
	var world_z = float(payload.get("y", 0.0)) / 10.0
	var world_y = float(payload.get("z", 1.4))
	global_position = Vector3(world_x, world_y, world_z)
	
	var ad_title = str(payload.get("title", "Sponsored"))
	label_3d.text = "%s\n$%.2f CPC" % [ad_title, _cpc]

func _process(delta: float):
	rotation.y += 0.6 * delta
	anchor_mesh.position.y = _base_y + sin(Time.get_ticks_msec() * 0.003) * 0.08
