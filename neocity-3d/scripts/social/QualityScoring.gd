## Dynamic 7-day interaction quality scoring for social resonance clustering.
class_name QualityScoring
extends Node

signal resonance_updated(user_id: String, resonance_score: float)

const ROLLING_WINDOW_SECONDS: int = 7 * 24 * 60 * 60
const MAX_COMMUNICATION_SECONDS: float = 30.0 * 60.0
const BASE_INTERACTION_WEIGHT: float = 0.55
const SHARED_EVENT_WEIGHT: float = 0.25
const COMMUNICATION_WEIGHT: float = 0.20

var _interactions: Dictionary = {}
var _resonance_cache: Dictionary = {}
var _pair_mutual_counts: Dictionary = {}


func record_interaction(
    user_id: String,
    peer_id: String,
    interaction_quality: float,
    shared_event_participation: float = 0.0,
    communication_seconds: float = 0.0,
    timestamp: int = 0
) -> void:
    if user_id == "" or peer_id == "":
        return
    var ts: int = timestamp if timestamp > 0 else Time.get_unix_time_from_system()
    _store_interaction(user_id, peer_id, interaction_quality, shared_event_participation, communication_seconds, ts)
    _store_interaction(peer_id, user_id, interaction_quality, shared_event_participation, communication_seconds, ts)
    _increment_pair_mutual_count(user_id, peer_id)
    _refresh_scores_for_pair(user_id, peer_id)


func record_shared_event_participation(user_ids: Array, event_weight: float = 1.0, timestamp: int = 0) -> void:
    if user_ids.size() < 2:
        return
    var ts: int = timestamp if timestamp > 0 else Time.get_unix_time_from_system()
    var clean_weight: float = clampf(event_weight, 0.0, 1.0)
    for i in range(user_ids.size()):
        for j in range(i + 1, user_ids.size()):
            var uid: String = str(user_ids[i])
            var pid: String = str(user_ids[j])
            record_interaction(uid, pid, 0.5, clean_weight, 0.0, ts)


func get_resonance_score(user_id: String) -> float:
    if _resonance_cache.has(user_id):
        return float(_resonance_cache[user_id])
    var score: float = _recompute_user_score(user_id)
    _resonance_cache[user_id] = score
    return score


func get_resonance_band(user_id: String) -> String:
    var score: float = get_resonance_score(user_id)
    if score < 0.33:
        return "emergent"
    if score < 0.66:
        return "active"
    return "core"


func get_top_resonant_peers(user_id: String, max_results: int = 10) -> Array:
    if not _interactions.has(user_id):
        return []
    var by_peer: Dictionary = {}
    for row in _interactions[user_id]:
        var peer_id: String = str(row.get("peer_id", ""))
        if peer_id == "":
            continue
        if not by_peer.has(peer_id):
            by_peer[peer_id] = {
                "peer_id": peer_id,
                "samples": 0,
                "score_sum": 0.0,
            }
        var entry: Dictionary = by_peer[peer_id]
        entry["samples"] = int(entry["samples"]) + 1
        entry["score_sum"] = float(entry["score_sum"]) + float(row.get("weighted_score", 0.0))
        by_peer[peer_id] = entry

    var ranked: Array = by_peer.values()
    ranked.sort_custom(func(a: Dictionary, b: Dictionary):
        var av: float = float(a["score_sum"]) / max(1.0, float(a["samples"]))
        var bv: float = float(b["score_sum"]) / max(1.0, float(b["samples"]))
        return av > bv
    )
    if ranked.size() > max_results:
        ranked.resize(max_results)
    for item in ranked:
        item["average_score"] = float(item["score_sum"]) / max(1.0, float(item["samples"]))
    return ranked


func get_user_snapshot(user_id: String) -> Dictionary:
    return {
        "user_id": user_id,
        "resonance_score": get_resonance_score(user_id),
        "resonance_band": get_resonance_band(user_id),
        "top_peers": get_top_resonant_peers(user_id, 5),
    }


func _store_interaction(
    user_id: String,
    peer_id: String,
    interaction_quality: float,
    shared_event_participation: float,
    communication_seconds: float,
    timestamp: int
) -> void:
    var quality: float = clampf(interaction_quality, 0.0, 1.0)
    var shared_events: float = clampf(shared_event_participation, 0.0, 1.0)
    var communication_ratio: float = clampf(communication_seconds / MAX_COMMUNICATION_SECONDS, 0.0, 1.0)
    var weighted: float = (
        quality * BASE_INTERACTION_WEIGHT
        + shared_events * SHARED_EVENT_WEIGHT
        + communication_ratio * COMMUNICATION_WEIGHT
    )

    if not _interactions.has(user_id):
        _interactions[user_id] = []
    _interactions[user_id].append({
        "peer_id": peer_id,
        "timestamp": timestamp,
        "interaction_quality": quality,
        "shared_event": shared_events,
        "communication_ratio": communication_ratio,
        "weighted_score": clampf(weighted, 0.0, 1.0),
    })
    _prune_old_interactions(user_id)


func _prune_old_interactions(user_id: String) -> void:
    if not _interactions.has(user_id):
        return
    var now: int = Time.get_unix_time_from_system()
    var cutoff: int = now - ROLLING_WINDOW_SECONDS
    var keep: Array = []
    for row in _interactions[user_id]:
        if int(row.get("timestamp", 0)) >= cutoff:
            keep.append(row)
    _interactions[user_id] = keep


func _increment_pair_mutual_count(user_a: String, user_b: String) -> void:
    var key: String = _pair_key(user_a, user_b)
    _pair_mutual_counts[key] = int(_pair_mutual_counts.get(key, 0)) + 1


func _pair_key(user_a: String, user_b: String) -> String:
    return "%s::%s" % [min(user_a, user_b), max(user_a, user_b)]


func _refresh_scores_for_pair(user_a: String, user_b: String) -> void:
    var score_a: float = _recompute_user_score(user_a)
    var score_b: float = _recompute_user_score(user_b)
    _resonance_cache[user_a] = score_a
    _resonance_cache[user_b] = score_b
    resonance_updated.emit(user_a, score_a)
    resonance_updated.emit(user_b, score_b)


func _recompute_user_score(user_id: String) -> float:
    if not _interactions.has(user_id):
        return 0.0
    _prune_old_interactions(user_id)
    var rows: Array = _interactions[user_id]
    if rows.is_empty():
        return 0.0

    var now: int = Time.get_unix_time_from_system()
    var weighted_sum: float = 0.0
    var decay_sum: float = 0.0

    for row in rows:
        var ts: int = int(row.get("timestamp", now))
        var age_ratio: float = clampf(float(now - ts) / float(ROLLING_WINDOW_SECONDS), 0.0, 1.0)
        var recency_decay: float = 1.0 - age_ratio
        var base_score: float = float(row.get("weighted_score", 0.0))
        var peer_id: String = str(row.get("peer_id", ""))
        var mutual_multiplier: float = _mutual_multiplier(user_id, peer_id)
        weighted_sum += base_score * recency_decay * mutual_multiplier
        decay_sum += recency_decay

    if decay_sum <= 0.0001:
        return 0.0
    return clampf(weighted_sum / decay_sum, 0.0, 1.0)


func _mutual_multiplier(user_id: String, peer_id: String) -> float:
    if peer_id == "":
        return 1.0
    var key: String = _pair_key(user_id, peer_id)
    var interactions: int = int(_pair_mutual_counts.get(key, 0))
    if interactions <= 1:
        return 1.0
    return clampf(1.0 + float(interactions - 1) * 0.03, 1.0, 1.25)
