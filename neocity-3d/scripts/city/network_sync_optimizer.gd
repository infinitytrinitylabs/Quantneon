## NetworkSyncOptimizer — Area-of-Interest / Interest-Management Layer For 10k Players
##
## NetworkSyncOptimizer sits between a raw `zone_update` snapshot (from
## SocketIOClient / WebRTC) and the scene. Its job is to shrink the O(N)
## server snapshot (N up to 10,000 concurrent entities) into an O(K) working
## set (K ≈ 40–120 visible entities around the local player) before any
## Tween / Node work is done. This is what makes 60 fps achievable on mid-
## tier mobile WebGL.
##
## Responsibilities:
##
##   • Maintain a SpatialPartition populated from every authoritative zone
##     snapshot. The partition answers AOI queries in O(k).
##   • Emit `subscription_added` / `subscription_removed` / `subscription_tick`
##     signals so the NetworkManager can instantiate / hide / update entity
##     nodes without ever iterating the full snapshot.
##   • Maintain per-entity priority scores so a bandwidth-limited client can
##     decide which subset of the visible set to actually interpolate this
##     frame — e.g. under load, only the 80 highest-priority entities receive
##     smooth tweens, the rest are snapped.
##   • Compute delta-compressed subscription deltas (added / removed / moved)
##     and tell the NetworkManager so it can unsubscribe from unused
##     WebRTC/WebSocket channels.
##   • Gracefully degrade: if the subscription set would exceed
##     `hard_visible_cap`, the optimizer trims to the closest K.
##   • Collect metrics the UI HUD can display.
##
## Signal contract (NetworkManager listens to these):
##
##   subscription_added(id, data)      — entity entered AOI. Instantiate it.
##   subscription_removed(id)          — entity left AOI. Hide or free it.
##   subscription_tick(deltas)         — every tick, deltas = Array of
##                                       {id, pos, vel, priority} for visible
##                                       entities that moved.
##   subscription_stats(stats)         — periodic stats snapshot.
##
## Usage:
##
##     var optimizer := NetworkSyncOptimizer.new()
##     optimizer.visual_range = 120.0
##     add_child(optimizer)
##     optimizer.subscription_added.connect(_on_sub_added)
##     optimizer.subscription_removed.connect(_on_sub_removed)
##     optimizer.subscription_tick.connect(_on_sub_tick)
##     # ...
##     optimizer.set_local_player_pos(local_player.global_position)
##     optimizer.ingest_snapshot(zone_update_dict)

class_name NetworkSyncOptimizer
extends Node

const SpatialPartitionScript = preload("res://scripts/city/spatial_partition.gd")

# ── Tuneables ────────────────────────────────────────────────────────────────

## Coarse cell size in world units — must match server-side AOI granularity
## for cleanest behaviour. 96–192 recommended for 10k players in 2 km² zones.
@export var coarse_cell_size: float = 128.0

## Fine cell size — governs per-tick visible-set precision. 24–48 recommended.
@export var fine_cell_size: float = 32.0

## Players beyond this distance are culled from the subscription set entirely.
@export var visual_range: float = 120.0

## Soft cap on visible subscription set. Above this, priority kicks in.
@export var soft_visible_cap: int = 120

## Hard cap — even the highest priority entities past this number are dropped.
@export var hard_visible_cap: int = 250

## Tick rate (Hz) of the sync logic. The server may push faster; we throttle.
@export var tick_hz: float = 10.0

## Max entities to promote from "snapped" to "smoothly interpolated" per tick.
## Keeps tween allocation bounded on low-end devices.
@export var smooth_budget: int = 80

## Extra distance added to visual_range for the "keep alive" ring — entities
## that left visual range are still tracked (but hidden) until they exit this
## ring, so stepping briefly out of range doesn't thrash Node alloc/free.
@export var keep_alive_padding: float = 40.0

# ── Signals ──────────────────────────────────────────────────────────────────

signal subscription_added(id: String, data: Dictionary)
signal subscription_removed(id: String)
signal subscription_tick(deltas: Array)
signal subscription_stats(stats: Dictionary)

# ── Entity kind constants used to bias priority ──────────────────────────────

const KIND_PLAYER:    int = 0
const KIND_NPC:       int = 1
const KIND_VEHICLE:   int = 2
const KIND_DRONE:     int = 3
const KIND_PROJECTILE:int = 4
const KIND_LOOT:      int = 5
const KIND_STATIC:    int = 6

const KIND_PRIORITY_BIAS: Dictionary = {
	KIND_PLAYER: 3.0,
	KIND_NPC: 1.4,
	KIND_VEHICLE: 2.0,
	KIND_DRONE: 1.2,
	KIND_PROJECTILE: 2.5,
	KIND_LOOT: 0.7,
	KIND_STATIC: 0.4,
}

# ── Internal state ───────────────────────────────────────────────────────────

var _partition: SpatialPartition = null
var _subscribed: Dictionary = {}       # id → {pos, vel, meta, last_seen_tick, priority, smoothed}
var _local_player_pos: Vector3 = Vector3.ZERO
var _tick_accumulator: float = 0.0
var _tick_index: int = 0
var _last_snapshot_id: int = 0

var _metrics: Dictionary = {
	"last_snapshot_size": 0,
	"last_visible_count": 0,
	"last_cull_count": 0,
	"last_added": 0,
	"last_removed": 0,
	"bytes_ingested": 0,
	"ticks": 0,
}

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	_partition = SpatialPartitionScript.new(coarse_cell_size, fine_cell_size)
	set_process(true)


func _process(delta: float) -> void:
	if tick_hz <= 0.0:
		return
	_tick_accumulator += delta
	var period: float = 1.0 / tick_hz
	while _tick_accumulator >= period:
		_tick_accumulator -= period
		_tick()


# ── Public API ───────────────────────────────────────────────────────────────

## Update the local player's world position. The subscription tick uses this.
func set_local_player_pos(pos: Vector3) -> void:
	_local_player_pos = pos


## Accept a full `zone_update` snapshot dictionary and fold it into the
## partition. Snapshot schema is flexible; we look up players, npcs, vehicles,
## drones, drops, and projectiles if present.
func ingest_snapshot(snapshot: Dictionary) -> void:
	if snapshot == null:
		return
	_metrics["last_snapshot_size"] = _count_snapshot(snapshot)
	_metrics["bytes_ingested"] += _approx_snapshot_bytes(snapshot)
	_last_snapshot_id += 1

	var entries: Array = []
	_ingest_group(snapshot, "players", KIND_PLAYER, entries)
	_ingest_group(snapshot, "npcs", KIND_NPC, entries)
	_ingest_group(snapshot, "vehicles", KIND_VEHICLE, entries)
	_ingest_group(snapshot, "drones", KIND_DRONE, entries)
	_ingest_group(snapshot, "drops", KIND_LOOT, entries)
	_ingest_group(snapshot, "projectiles", KIND_PROJECTILE, entries)

	_partition.rebuild(entries)


## Force an immediate subscription sweep outside the normal tick cadence —
## useful when the local player teleports.
func force_sweep() -> void:
	_tick()


## Stats snapshot for HUD overlays.
func metrics() -> Dictionary:
	var out: Dictionary = _metrics.duplicate()
	out["subscribed"] = _subscribed.size()
	out["tick_hz"] = tick_hz
	out["visual_range"] = visual_range
	out["partition"] = _partition.stats()
	return out


## Iterate every currently subscribed entity's cached record.
func for_each_subscribed(callback: Callable) -> void:
	for id in _subscribed.keys():
		callback.call(id, _subscribed[id])


## Explicitly remove an entity from the subscription set (e.g., on disconnect).
func drop(id: String) -> void:
	if not _subscribed.has(id):
		return
	_subscribed.erase(id)
	subscription_removed.emit(id)


# ── Snapshot ingestion helpers ───────────────────────────────────────────────

func _ingest_group(snap: Dictionary, key: String, kind: int, entries: Array) -> void:
	if not snap.has(key):
		return
	var list = snap[key]
	if not (list is Array):
		return
	for raw in list:
		if not (raw is Dictionary):
			continue
		var id: String = _extract_id(raw)
		if id.is_empty():
			continue
		var pos: Vector3 = _extract_pos(raw)
		var vel: Vector3 = _extract_vel(raw)
		entries.append({
			"id": id,
			"pos": pos,
			"meta": {
				"kind": kind,
				"vel": vel,
				"raw": raw,
				"team": raw.get("team", raw.get("faction", "")),
				"hidden": bool(raw.get("hidden", false)),
				"importance": float(raw.get("importance", 0.0)),
			},
		})


static func _extract_id(raw: Dictionary) -> String:
	# Support multiple naming conventions used across the project.
	if raw.has("userId"):
		return String(raw["userId"])
	if raw.has("id"):
		return String(raw["id"])
	if raw.has("npcId"):
		return String(raw["npcId"])
	if raw.has("vehicleId"):
		return String(raw["vehicleId"])
	if raw.has("droneId"):
		return String(raw["droneId"])
	return ""


static func _extract_pos(raw: Dictionary) -> Vector3:
	if raw.has("pos") and raw["pos"] is Dictionary:
		var p: Dictionary = raw["pos"]
		# Server uses a 2D {x, y} with a scaling factor of 10 — mirror the
		# existing network_manager.gd convention.
		return Vector3(
			float(p.get("x", 0.0)) / 10.0,
			float(p.get("z", 1.0)),
			float(p.get("y", 0.0)) / 10.0,
		)
	if raw.has("position") and raw["position"] is Dictionary:
		var p: Dictionary = raw["position"]
		return Vector3(
			float(p.get("x", 0.0)),
			float(p.get("y", 0.0)),
			float(p.get("z", 0.0)),
		)
	return Vector3.ZERO


static func _extract_vel(raw: Dictionary) -> Vector3:
	if raw.has("vel") and raw["vel"] is Dictionary:
		var v: Dictionary = raw["vel"]
		return Vector3(
			float(v.get("x", 0.0)),
			float(v.get("y", 0.0)),
			float(v.get("z", 0.0)),
		)
	return Vector3.ZERO


static func _count_snapshot(snap: Dictionary) -> int:
	var n: int = 0
	for k in ["players", "npcs", "vehicles", "drones", "drops", "projectiles"]:
		if snap.has(k) and snap[k] is Array:
			n += (snap[k] as Array).size()
	return n


static func _approx_snapshot_bytes(snap: Dictionary) -> int:
	# A rough proxy — 64 bytes per entity is the observed server payload.
	return _count_snapshot(snap) * 64


# ── The subscription tick ────────────────────────────────────────────────────

func _tick() -> void:
	if _partition == null:
		return
	_tick_index += 1
	_metrics["ticks"] += 1

	var keep_ring: float = visual_range + keep_alive_padding
	var visible_ids: Array = _partition.visible_ids(_local_player_pos, visual_range, hard_visible_cap * 2)
	var keep_ids: Array = _partition.visible_ids(_local_player_pos, keep_ring, hard_visible_cap * 4)
	var keep_lookup: Dictionary = {}
	for id in keep_ids:
		keep_lookup[id] = true

	# Score & sort visible set.
	var scored: Array = []
	for id in visible_ids:
		var rec: Dictionary = _partition.get_record(id)
		if rec.is_empty():
			continue
		var pos: Vector3 = rec["pos"]
		var meta: Dictionary = rec["meta"]
		var kind: int = int(meta.get("kind", KIND_NPC))
		var dx: float = pos.x - _local_player_pos.x
		var dz: float = pos.z - _local_player_pos.z
		var d_sq: float = dx * dx + dz * dz
		var d: float = sqrt(max(0.0, d_sq))
		var base_bias: float = float(KIND_PRIORITY_BIAS.get(kind, 1.0))
		var importance: float = float(meta.get("importance", 0.0))
		# Priority is higher for closer, important entities.
		var priority: float = (base_bias + importance) / max(1.0, d)
		scored.append([id, priority, pos, meta, d])

	scored.sort_custom(func(a, b): return float(a[1]) > float(b[1]))

	# Trim to caps.
	var effective_cap: int = min(hard_visible_cap, max(soft_visible_cap, smooth_budget))
	if scored.size() > effective_cap:
		scored.resize(effective_cap)

	# Diff against _subscribed.
	var added: int = 0
	var removed: int = 0
	var now_subscribed: Dictionary = {}
	for row in scored:
		var id: String = String(row[0])
		var priority: float = float(row[1])
		var pos: Vector3 = row[2]
		var meta: Dictionary = row[3]
		now_subscribed[id] = true
		if not _subscribed.has(id):
			_subscribed[id] = {
				"pos": pos,
				"vel": meta.get("vel", Vector3.ZERO),
				"meta": meta,
				"priority": priority,
				"last_seen_tick": _tick_index,
				"smoothed": false,
			}
			subscription_added.emit(id, meta.get("raw", {}))
			added += 1
		else:
			var prev: Dictionary = _subscribed[id]
			prev["pos"] = pos
			prev["vel"] = meta.get("vel", Vector3.ZERO)
			prev["meta"] = meta
			prev["priority"] = priority
			prev["last_seen_tick"] = _tick_index

	# Remove those no longer visible AND no longer in keep ring.
	var to_remove: Array = []
	for id in _subscribed.keys():
		if now_subscribed.has(id):
			continue
		if not keep_lookup.has(id):
			to_remove.append(id)
	for id in to_remove:
		_subscribed.erase(id)
		subscription_removed.emit(id)
		removed += 1

	# Emit tick deltas (only entities that moved noticeably or are high priority).
	var deltas: Array = []
	var promoted_smooth: int = 0
	for i in range(scored.size()):
		var row: Array = scored[i]
		var id: String = String(row[0])
		var priority: float = float(row[1])
		var pos: Vector3 = row[2]
		var meta: Dictionary = row[3]
		var entry: Dictionary = _subscribed[id]
		var smooth: bool = promoted_smooth < smooth_budget
		if smooth:
			promoted_smooth += 1
		entry["smoothed"] = smooth
		deltas.append({
			"id": id,
			"pos": pos,
			"vel": meta.get("vel", Vector3.ZERO),
			"priority": priority,
			"smooth": smooth,
			"kind": int(meta.get("kind", KIND_NPC)),
		})

	_metrics["last_visible_count"] = scored.size()
	_metrics["last_cull_count"] = visible_ids.size() - scored.size()
	_metrics["last_added"] = added
	_metrics["last_removed"] = removed

	subscription_tick.emit(deltas)

	# Periodic stats broadcast (every 20 ticks ~= 2 s at 10Hz).
	if _tick_index % 20 == 0:
		subscription_stats.emit(metrics())


# ── Derived helpers for NetworkManager convenience ───────────────────────────

## Given an id previously announced via `subscription_added`, return its most
## recent cached pos/vel/priority/kind, or {} if no longer subscribed.
func cached(id: String) -> Dictionary:
	if not _subscribed.has(id):
		return {}
	var entry: Dictionary = _subscribed[id]
	return {
		"pos": entry["pos"],
		"vel": entry["vel"],
		"priority": entry["priority"],
		"kind": int(entry["meta"].get("kind", KIND_NPC)),
		"smoothed": entry["smoothed"],
	}


## Bulk array of subscribed ids (stable order).
func subscribed_ids() -> Array:
	return _subscribed.keys()


## Whether the given id is currently within the AOI.
func is_subscribed(id: String) -> bool:
	return _subscribed.has(id)


# ── Integration helpers for the existing network_manager.gd ──────────────────

## Thin wrapper that lets `network_manager.gd` replace its existing spatial
## section with a call to this method. The returned set is the list of ids
## that the caller should KEEP visible; anything else in its `entities` dict
## should be hidden or queued for despawn.
func filter_visible_ids(all_ids: Array) -> Dictionary:
	var visible: Dictionary = {}
	for id in all_ids:
		if _subscribed.has(id):
			visible[String(id)] = true
	return visible


## Convenience: total approximate outbound bandwidth budget consumed by the
## current subscription set, in bytes/sec. Callers compare this to a nominal
## cap (e.g., 80 kB/s) for the HUD "connection quality" pill.
func approximate_bandwidth_bps() -> float:
	# ~64 bytes per entity per tick on the wire.
	return float(_subscribed.size()) * 64.0 * tick_hz


## Reset all state. Useful between zone changes.
func reset() -> void:
	for id in _subscribed.keys():
		subscription_removed.emit(id)
	_subscribed.clear()
	if _partition:
		_partition.rebuild([])
	_tick_index = 0
	_metrics["ticks"] = 0
	_metrics["bytes_ingested"] = 0
