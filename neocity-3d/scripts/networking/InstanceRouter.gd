## Routes users into socially resonant server instances and emits visual cue data.
class_name InstanceRouter
extends Node

signal user_routed(user_id: String, instance_id: String, resonance_band: String)
signal instance_cue_updated(instance_id: String, cue_payload: Dictionary)

@export var min_instance_size: int = 8
@export var target_instance_size: int = 20
@export var max_instance_size: int = 35

var quality_scoring: QualityScoring

var _user_assignments: Dictionary = {}
var _instances: Dictionary = {}
var _instance_counter: int = 0


func _ready() -> void:
    if quality_scoring != null and not quality_scoring.resonance_updated.is_connected(_on_resonance_updated):
        quality_scoring.resonance_updated.connect(_on_resonance_updated)


func set_quality_scoring(service: QualityScoring) -> void:
    if quality_scoring != null and quality_scoring.resonance_updated.is_connected(_on_resonance_updated):
        quality_scoring.resonance_updated.disconnect(_on_resonance_updated)
    quality_scoring = service
    if quality_scoring != null and not quality_scoring.resonance_updated.is_connected(_on_resonance_updated):
        quality_scoring.resonance_updated.connect(_on_resonance_updated)


func route_user(user_id: String) -> String:
    if user_id == "":
        return ""
    var score: float = _get_score(user_id)
    var band: String = _band_for_score(score)
    var instance_id: String = _select_instance_for_band(band, score)
    _assign_user_to_instance(user_id, instance_id, score, band)
    _emit_instance_cue(instance_id)
    return instance_id


func route_users(user_ids: Array) -> Dictionary:
    var assignments: Dictionary = {}
    for user_id_variant in user_ids:
        var user_id: String = str(user_id_variant)
        if user_id == "":
            continue
        assignments[user_id] = route_user(user_id)
    return assignments


func remove_user(user_id: String) -> void:
    if not _user_assignments.has(user_id):
        return
    var old_instance: String = str(_user_assignments[user_id])
    _user_assignments.erase(user_id)
    if _instances.has(old_instance):
        var users: Array = _instances[old_instance]["users"]
        users.erase(user_id)
        _instances[old_instance]["users"] = users
        _recompute_instance_center(old_instance)
        _emit_instance_cue(old_instance)
        if users.is_empty():
            _instances.erase(old_instance)


func get_user_instance(user_id: String) -> String:
    return str(_user_assignments.get(user_id, ""))


func get_instance_snapshot(instance_id: String) -> Dictionary:
    if not _instances.has(instance_id):
        return {}
    var entry: Dictionary = _instances[instance_id]
    return {
        "instance_id": instance_id,
        "resonance_band": str(entry.get("band", "emergent")),
        "resonance_center": float(entry.get("resonance_center", 0.0)),
        "population": int((entry.get("users", []) as Array).size()),
        "users": (entry.get("users", []) as Array).duplicate(),
        "cue": _build_instance_cue(entry),
    }


func get_all_instance_cues() -> Dictionary:
    var cues: Dictionary = {}
    for instance_id in _instances.keys():
        var entry: Dictionary = _instances[instance_id]
        cues[instance_id] = _build_instance_cue(entry)
    return cues


func _on_resonance_updated(user_id: String, _score: float) -> void:
    if _user_assignments.has(user_id):
        route_user(user_id)


func _get_score(user_id: String) -> float:
    if quality_scoring == null:
        return 0.0
    return quality_scoring.get_resonance_score(user_id)


func _band_for_score(score: float) -> String:
    if score < 0.33:
        return "emergent"
    if score < 0.66:
        return "active"
    return "core"


func _select_instance_for_band(band: String, score: float) -> String:
    var best_instance: String = ""
    var best_gap: float = INF
    for instance_id in _instances.keys():
        var entry: Dictionary = _instances[instance_id]
        if str(entry.get("band", "")) != band:
            continue
        var users: Array = entry.get("users", [])
        if users.size() >= max_instance_size:
            continue
        if users.size() >= target_instance_size:
            continue
        var center: float = float(entry.get("resonance_center", 0.0))
        var gap: float = absf(center - score)
        if gap < best_gap:
            best_gap = gap
            best_instance = instance_id

    if best_instance != "":
        return best_instance
    return _create_instance(band)


func _create_instance(band: String) -> String:
    _instance_counter += 1
    var instance_id: String = "social_%s_%03d" % [band, _instance_counter]
    _instances[instance_id] = {
        "band": band,
        "users": [],
        "resonance_center": 0.0,
        "last_updated": Time.get_unix_time_from_system(),
    }
    return instance_id


func _assign_user_to_instance(user_id: String, instance_id: String, _score: float, band: String) -> void:
    var previous_instance: String = str(_user_assignments.get(user_id, ""))
    if previous_instance != "" and previous_instance == instance_id:
        _recompute_instance_center(instance_id)
        return
    if previous_instance != "":
        _remove_user_from_instance(user_id, previous_instance)
    _user_assignments[user_id] = instance_id

    var users: Array = _instances[instance_id]["users"]
    if not users.has(user_id):
        users.append(user_id)
    _instances[instance_id]["users"] = users
    _instances[instance_id]["band"] = band
    _instances[instance_id]["last_updated"] = Time.get_unix_time_from_system()
    _recompute_instance_center(instance_id)
    user_routed.emit(user_id, instance_id, band)


func _remove_user_from_instance(user_id: String, instance_id: String) -> void:
    if not _instances.has(instance_id):
        return
    var users: Array = _instances[instance_id]["users"]
    users.erase(user_id)
    _instances[instance_id]["users"] = users
    if users.is_empty():
        _instances.erase(instance_id)
        return
    _recompute_instance_center(instance_id)
    _emit_instance_cue(instance_id)


func _recompute_instance_center(instance_id: String) -> void:
    if not _instances.has(instance_id):
        return
    var entry: Dictionary = _instances[instance_id]
    var users: Array = entry.get("users", [])
    if users.is_empty():
        entry["resonance_center"] = 0.0
        _instances[instance_id] = entry
        return

    var total: float = 0.0
    for user_id_variant in users:
        var user_id: String = str(user_id_variant)
        total += _get_score(user_id)
    entry["resonance_center"] = clampf(total / float(users.size()), 0.0, 1.0)
    entry["last_updated"] = Time.get_unix_time_from_system()
    _instances[instance_id] = entry


func _emit_instance_cue(instance_id: String) -> void:
    if not _instances.has(instance_id):
        return
    var cue: Dictionary = _build_instance_cue(_instances[instance_id])
    instance_cue_updated.emit(instance_id, cue)


func _build_instance_cue(entry: Dictionary) -> Dictionary:
    var band: String = str(entry.get("band", "emergent"))
    var center: float = float(entry.get("resonance_center", 0.0))
    var users: Array = entry.get("users", [])
    var density_ratio: float = clampf(float(users.size()) / float(max(1, max_instance_size)), 0.0, 1.0)

    var color: Color = _color_for_band(band)
    var intensity: float = clampf((center * 0.65) + (density_ratio * 0.35), 0.1, 1.0)
    var pulse_speed: float = lerpf(0.6, 2.2, center)
    var environmental_reverb: float = lerpf(0.05, 0.35, center)

    return {
        "aura_color": color,
        "aura_intensity": intensity,
        "pulse_speed": pulse_speed,
        "environmental_reverb": environmental_reverb,
        "band": band,
        "population": users.size(),
        "under_populated": users.size() < min_instance_size,
    }


func _color_for_band(band: String) -> Color:
    match band:
        "core":
            return Color(0.95, 0.35, 1.0, 1.0)
        "active":
            return Color(0.30, 0.80, 1.0, 1.0)
        _:
            return Color(0.50, 0.55, 0.70, 1.0)
