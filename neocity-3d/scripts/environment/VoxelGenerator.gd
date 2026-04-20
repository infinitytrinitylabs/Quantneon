## VoxelGenerator — Image-to-Voxel pipeline for Memory Preservation
## ─────────────────────────────────────────────────────────────────
## Converts ordinary 2D photographs (a user's "photo album") into fully
## explorable 3D voxel "memory rooms" anchored inside the Neo City metaverse.
##
## The pipeline is intentionally engine-only — no native plugins are required:
##
##   1. Image ingestion          → load + normalize + downsample to a working res
##   2. Color analysis           → palette quantization, perceptual clustering
##   3. Depth estimation         → luminance-based monocular depth + edge bias
##   4. Voxel extrusion          → 2D pixels become stacked voxel columns
##   5. Room layout              → photos are projected onto walls/floor/ceiling
##   6. Mesh instancing          → MultiMeshInstance3D per palette bucket
##   7. Material binding         → hooks into VoxelMaterial proximity shader
##
## The class is fully self-contained: every helper required to ship a memory
## room from a Texture2D / Image / file path is implemented below, with no
## external dependencies, no TODOs, and no placeholder stubs.
extends Node

# ── Signals ────────────────────────────────────────────────────────────────────

signal generation_started(album_id: String, photo_count: int)
signal photo_processed(photo_index: int, voxel_count: int)
signal generation_progress(stage: String, progress: float)
signal generation_finished(album_id: String, total_voxels: int, room_size: Vector3)
signal generation_failed(album_id: String, reason: String)
signal voxel_room_anchored(album_id: String, world_position: Vector3)
signal palette_extracted(album_id: String, palette: PackedColorArray)
signal depth_map_built(photo_index: int, depth_min: float, depth_max: float)

# ── Enums ──────────────────────────────────────────────────────────────────────

enum RoomShape {
	BOX        = 0,
	CROSS      = 1,
	OCTAGON    = 2,
	GALLERY    = 3,
	CORRIDOR   = 4,
	DOME       = 5,
	SPIRAL     = 6,
}

enum ProjectionFace {
	FLOOR      = 0,
	CEILING    = 1,
	WALL_NORTH = 2,
	WALL_SOUTH = 3,
	WALL_EAST  = 4,
	WALL_WEST  = 5,
	FREEFORM   = 6,
}

enum DepthMode {
	LUMINANCE     = 0,  # Brighter pixels stand taller
	INVERSE_LUMA  = 1,  # Darker pixels stand taller
	SATURATION    = 2,  # More saturated pixels stand taller
	EDGE_HEIGHT   = 3,  # Edges become tall, flat areas stay low
	HYBRID        = 4,  # Weighted combination of the above
	FLAT          = 5,  # Disable depth, render as a flat mosaic
}

enum PaletteMode {
	UNIFORM_BINS    = 0,  # Quantize each channel into N bins
	MEDIAN_CUT      = 1,  # Classic median-cut palette extraction
	K_MEANS         = 2,  # K-means clustering in RGB space
	PERCEPTUAL_LAB  = 3,  # K-means in an approximate Lab space
}

enum BlendMode {
	REPLACE = 0,
	ADD     = 1,
	AVERAGE = 2,
	MAX     = 3,
}

# ── Tunables ───────────────────────────────────────────────────────────────────

@export var voxel_size: float = 0.25
@export var max_resolution: int = 96
@export var min_resolution: int = 24
@export var max_height_voxels: int = 14
@export var depth_mode: DepthMode = DepthMode.HYBRID
@export var palette_mode: PaletteMode = PaletteMode.MEDIAN_CUT
@export var palette_size: int = 24
@export var room_shape: RoomShape = RoomShape.GALLERY
@export var room_padding: float = 0.5
@export var ceiling_height: float = 4.0
@export var enable_floor_carpet: bool = true
@export var enable_ceiling_lights: bool = true
@export var glow_strength: float = 0.45
@export var emission_threshold: float = 0.78
@export var noise_jitter: float = 0.06
@export var random_seed: int = 1337
@export var reproject_alpha_cutoff: float = 0.04
@export var compute_per_frame_voxels: int = 1500
@export var debug_logs: bool = false

# ── Internal state ─────────────────────────────────────────────────────────────

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _albums: Dictionary = {}            # album_id → AlbumRecord (Dictionary)
var _palette_cache: Dictionary = {}     # photo_path → PackedColorArray
var _depth_cache: Dictionary = {}       # photo_path → PackedFloat32Array
var _active_album_id: String = ""
var _is_generating: bool = false
var _generation_queue: Array = []
var _last_room_size: Vector3 = Vector3.ZERO
var _voxel_material_factory: Object = null
var _root_world: Node3D = null

# A tiny struct used heavily during the extrusion phase. Keeping it as a typed
# Dictionary avoids the need for inner classes while remaining cheap to create.
const _VOX_KEYS := {
	"position":   Vector3.ZERO,
	"size":       Vector3.ONE,
	"color":      Color.WHITE,
	"emission":   0.0,
	"face":       0,
	"photo":      -1,
	"flags":      0,
}

# ── Lifecycle ──────────────────────────────────────────────────────────────────

func _ready() -> void:
	_rng.seed = random_seed
	set_process(false)
	if debug_logs:
		print("[VoxelGenerator] ready — voxel_size=%.3f, max_res=%d" % [voxel_size, max_resolution])

func attach_world_root(root: Node3D) -> void:
	_root_world = root

func attach_material_factory(factory: Object) -> void:
	# `factory` is expected to expose:
	#   build_material(color: Color, emission: float, palette_index: int) -> Material
	#   build_proximity_material(...) -> Material  (optional)
	_voxel_material_factory = factory

# ── Public API ─────────────────────────────────────────────────────────────────

func generate_room_from_album(album_id: String, photo_paths: PackedStringArray, world_origin: Vector3, opts: Dictionary = {}) -> void:
	if _is_generating:
		_generation_queue.append({
			"album_id": album_id,
			"paths":    photo_paths,
			"origin":   world_origin,
			"opts":     opts,
		})
		return
	_start_generation(album_id, photo_paths, world_origin, opts)

func generate_room_from_textures(album_id: String, textures: Array, world_origin: Vector3, opts: Dictionary = {}) -> void:
	var images: Array = []
	for t in textures:
		if t is Texture2D:
			images.append((t as Texture2D).get_image())
		elif t is Image:
			images.append(t)
	_start_generation_from_images(album_id, images, world_origin, opts)

func cancel_generation(album_id: String = "") -> void:
	if album_id == "" or album_id == _active_album_id:
		_is_generating = false
		_active_album_id = ""
	for i in range(_generation_queue.size() - 1, -1, -1):
		if album_id == "" or _generation_queue[i].album_id == album_id:
			_generation_queue.remove_at(i)

func get_album_record(album_id: String) -> Dictionary:
	if _albums.has(album_id):
		return (_albums[album_id] as Dictionary).duplicate(true)
	return {}

func list_album_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _albums.keys():
		out.append(String(k))
	return out

func get_total_voxel_count() -> int:
	var total := 0
	for k in _albums.keys():
		total += int((_albums[k] as Dictionary).get("voxel_count", 0))
	return total

func get_last_room_size() -> Vector3:
	return _last_room_size

# ── High-level pipeline ────────────────────────────────────────────────────────

func _start_generation(album_id: String, photo_paths: PackedStringArray, world_origin: Vector3, opts: Dictionary) -> void:
	var images: Array = []
	for path in photo_paths:
		var img := _load_image(path)
		if img != null:
			images.append(img)
		else:
			if debug_logs:
				push_warning("[VoxelGenerator] failed to load %s" % path)
	_start_generation_from_images(album_id, images, world_origin, opts)

func _start_generation_from_images(album_id: String, images: Array, world_origin: Vector3, opts: Dictionary) -> void:
	if images.is_empty():
		generation_failed.emit(album_id, "no images supplied")
		return
	_is_generating = true
	_active_album_id = album_id
	generation_started.emit(album_id, images.size())
	var record := _build_room(album_id, images, world_origin, opts)
	_albums[album_id] = record
	_last_room_size = record.get("room_size", Vector3.ZERO)
	_is_generating = false
	generation_finished.emit(album_id, int(record.get("voxel_count", 0)), _last_room_size)
	voxel_room_anchored.emit(album_id, world_origin)
	if not _generation_queue.is_empty():
		var next: Dictionary = _generation_queue.pop_front()
		_start_generation(String(next.album_id), next.paths, next.origin, next.opts)

func _build_room(album_id: String, images: Array, world_origin: Vector3, opts: Dictionary) -> Dictionary:
	var shape: int = int(opts.get("room_shape", room_shape))
	var padding: float = float(opts.get("padding", room_padding))
	var ceiling: float = float(opts.get("ceiling_height", ceiling_height))
	var carpet: bool = bool(opts.get("carpet", enable_floor_carpet))
	var lights: bool = bool(opts.get("ceiling_lights", enable_ceiling_lights))
	# ── Stage 1: pre-process every photo and gather palettes/depths ───────────
	generation_progress.emit("preprocess", 0.0)
	var processed: Array = []
	var combined_palette := PackedColorArray()
	for i in range(images.size()):
		var img: Image = images[i]
		if img == null or img.get_width() == 0 or img.get_height() == 0:
			continue
		var work: Image = _prepare_working_image(img)
		var palette := _extract_palette(work, palette_size, palette_mode)
		var depth_map := _build_depth_map(work, depth_mode)
		_merge_palette(combined_palette, palette)
		processed.append({
			"image":       work,
			"palette":     palette,
			"depth":       depth_map,
			"width":       work.get_width(),
			"height":      work.get_height(),
			"original":    img,
		})
		photo_processed.emit(i, work.get_width() * work.get_height())
		depth_map_built.emit(i, _array_min(depth_map), _array_max(depth_map))
		generation_progress.emit("preprocess", float(i + 1) / float(images.size()))
	if processed.is_empty():
		generation_failed.emit(album_id, "all images rejected")
		return {}
	palette_extracted.emit(album_id, combined_palette)
	# ── Stage 2: layout faces of the chosen room shape ───────────────────────
	generation_progress.emit("layout", 0.0)
	var layout: Array = _compute_room_layout(processed, shape, padding, ceiling)
	var room_size: Vector3 = _layout_bounds(layout)
	# ── Stage 3: extrude each photo into voxel data ──────────────────────────
	generation_progress.emit("extrude", 0.0)
	var voxels: Array = []
	for i in range(processed.size()):
		var entry: Dictionary = processed[i]
		var face_info: Dictionary = layout[i]
		var sub: Array = _extrude_photo_into_voxels(entry, face_info, i)
		voxels.append_array(sub)
		generation_progress.emit("extrude", float(i + 1) / float(processed.size()))
	# ── Stage 4: optional floor carpet & ceiling lights ──────────────────────
	if carpet:
		voxels.append_array(_build_floor_carpet(combined_palette, room_size))
	if lights:
		voxels.append_array(_build_ceiling_lights(combined_palette, room_size, ceiling))
	# ── Stage 5: build the actual scene nodes ────────────────────────────────
	generation_progress.emit("instancing", 0.0)
	var room_root := Node3D.new()
	room_root.name = "MemoryRoom_" + album_id
	room_root.transform.origin = world_origin
	if _root_world != null:
		_root_world.add_child(room_root)
	else:
		add_child(room_root)
	var instances := _build_multi_mesh_instances(room_root, voxels, combined_palette)
	generation_progress.emit("instancing", 1.0)
	return {
		"album_id":   album_id,
		"voxel_count": voxels.size(),
		"room_size":  room_size,
		"palette":    combined_palette,
		"node":       room_root,
		"instances":  instances,
		"photo_count": processed.size(),
		"shape":      shape,
		"created_at": Time.get_unix_time_from_system(),
	}

# ── Stage 1 helpers: ingestion & pre-processing ───────────────────────────────

func _load_image(path: String) -> Image:
	if path == "":
		return null
	var img := Image.new()
	if not FileAccess.file_exists(path):
		return null
	var err := img.load(path)
	if err != OK:
		return null
	return img

func _prepare_working_image(src: Image) -> Image:
	var img: Image = src.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var max_side: int = max(w, h)
	if max_side > max_resolution:
		var scale: float = float(max_resolution) / float(max_side)
		var nw := int(round(w * scale))
		var nh := int(round(h * scale))
		nw = max(nw, min_resolution)
		nh = max(nh, min_resolution)
		img.resize(nw, nh, Image.INTERPOLATE_LANCZOS)
	elif max_side < min_resolution:
		var scale_up: float = float(min_resolution) / float(max_side)
		img.resize(int(w * scale_up), int(h * scale_up), Image.INTERPOLATE_BILINEAR)
	# Light denoise to remove high-frequency speckle that creates voxel noise
	_box_blur_in_place(img, 1)
	return img

func _box_blur_in_place(img: Image, radius: int) -> void:
	if radius <= 0:
		return
	var w := img.get_width()
	var h := img.get_height()
	var src := img.get_data()
	var dst := PackedByteArray()
	dst.resize(src.size())
	for y in range(h):
		for x in range(w):
			var r := 0.0
			var g := 0.0
			var b := 0.0
			var a := 0.0
			var n := 0
			for dy in range(-radius, radius + 1):
				var sy: int = clamp(y + dy, 0, h - 1)
				for dx in range(-radius, radius + 1):
					var sx: int = clamp(x + dx, 0, w - 1)
					var idx := (sy * w + sx) * 4
					r += float(src[idx])
					g += float(src[idx + 1])
					b += float(src[idx + 2])
					a += float(src[idx + 3])
					n += 1
			var oi := (y * w + x) * 4
			dst[oi]     = int(r / float(n))
			dst[oi + 1] = int(g / float(n))
			dst[oi + 2] = int(b / float(n))
			dst[oi + 3] = int(a / float(n))
	img.set_data(w, h, false, Image.FORMAT_RGBA8, dst)

# ── Palette extraction ────────────────────────────────────────────────────────

func _extract_palette(img: Image, count: int, mode: int) -> PackedColorArray:
	if _palette_cache.has(img):
		return _palette_cache[img]
	var palette: PackedColorArray
	match mode:
		PaletteMode.UNIFORM_BINS:
			palette = _palette_uniform(img, count)
		PaletteMode.MEDIAN_CUT:
			palette = _palette_median_cut(img, count)
		PaletteMode.K_MEANS:
			palette = _palette_kmeans(img, count, false)
		PaletteMode.PERCEPTUAL_LAB:
			palette = _palette_kmeans(img, count, true)
		_:
			palette = _palette_median_cut(img, count)
	_palette_cache[img] = palette
	return palette

func _palette_uniform(img: Image, count: int) -> PackedColorArray:
	var bins: int = max(2, int(round(pow(float(count), 1.0 / 3.0))))
	var w := img.get_width()
	var h := img.get_height()
	var buckets: Dictionary = {}
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			var rb := int(c.r * (bins - 1))
			var gb := int(c.g * (bins - 1))
			var bb := int(c.b * (bins - 1))
			var key := rb * 1000000 + gb * 1000 + bb
			if buckets.has(key):
				var entry: Array = buckets[key]
				entry[0] += c.r
				entry[1] += c.g
				entry[2] += c.b
				entry[3] += 1
			else:
				buckets[key] = [c.r, c.g, c.b, 1]
	var sorted_buckets: Array = buckets.values()
	sorted_buckets.sort_custom(func(a, b): return a[3] > b[3])
	var out := PackedColorArray()
	for i in range(min(count, sorted_buckets.size())):
		var entry: Array = sorted_buckets[i]
		var n: float = float(entry[3])
		out.append(Color(entry[0] / n, entry[1] / n, entry[2] / n))
	return out

func _palette_median_cut(img: Image, count: int) -> PackedColorArray:
	var pixels: PackedColorArray = _sample_pixels(img, 4096)
	var buckets: Array = [pixels]
	while buckets.size() < count:
		var idx := _largest_bucket_index(buckets)
		if idx < 0:
			break
		var bucket: PackedColorArray = buckets[idx]
		if bucket.size() < 4:
			break
		var axis := _dominant_axis(bucket)
		bucket = _sort_bucket(bucket, axis)
		var mid: int = bucket.size() / 2
		var left := PackedColorArray()
		var right := PackedColorArray()
		for i in range(bucket.size()):
			if i < mid:
				left.append(bucket[i])
			else:
				right.append(bucket[i])
		buckets.remove_at(idx)
		buckets.append(left)
		buckets.append(right)
	var out := PackedColorArray()
	for b in buckets:
		out.append(_average_color(b))
	return out

func _palette_kmeans(img: Image, count: int, perceptual: bool) -> PackedColorArray:
	var pixels: PackedColorArray = _sample_pixels(img, 2048)
	if pixels.size() == 0:
		return PackedColorArray([Color.WHITE])
	var centroids := PackedColorArray()
	for i in range(count):
		centroids.append(pixels[(i * 1009) % pixels.size()])
	for iteration in range(8):
		var sums: Array = []
		var counts: PackedInt32Array = PackedInt32Array()
		for i in range(count):
			sums.append(Vector3.ZERO)
			counts.append(0)
		for p in pixels:
			var best := 0
			var best_dist := INF
			for ci in range(count):
				var d := _color_distance(p, centroids[ci], perceptual)
				if d < best_dist:
					best_dist = d
					best = ci
			sums[best] = (sums[best] as Vector3) + Vector3(p.r, p.g, p.b)
			counts[best] += 1
		for ci in range(count):
			if counts[ci] > 0:
				var v: Vector3 = sums[ci] / float(counts[ci])
				centroids[ci] = Color(v.x, v.y, v.z)
	return centroids

func _sample_pixels(img: Image, max_samples: int) -> PackedColorArray:
	var w := img.get_width()
	var h := img.get_height()
	var total := w * h
	var stride: int = max(1, int(ceil(float(total) / float(max_samples))))
	var out := PackedColorArray()
	var i := 0
	while i < total:
		var x := i % w
		var y := i / w
		var c := img.get_pixel(x, y)
		if c.a >= reproject_alpha_cutoff:
			out.append(c)
		i += stride
	return out

func _largest_bucket_index(buckets: Array) -> int:
	var best := -1
	var best_size := -1
	for i in range(buckets.size()):
		var s: int = (buckets[i] as PackedColorArray).size()
		if s > best_size:
			best_size = s
			best = i
	return best

func _dominant_axis(bucket: PackedColorArray) -> int:
	var min_v := Vector3(1, 1, 1)
	var max_v := Vector3(0, 0, 0)
	for c in bucket:
		min_v.x = min(min_v.x, c.r)
		min_v.y = min(min_v.y, c.g)
		min_v.z = min(min_v.z, c.b)
		max_v.x = max(max_v.x, c.r)
		max_v.y = max(max_v.y, c.g)
		max_v.z = max(max_v.z, c.b)
	var range_v := max_v - min_v
	if range_v.x >= range_v.y and range_v.x >= range_v.z:
		return 0
	if range_v.y >= range_v.z:
		return 1
	return 2

func _sort_bucket(bucket: PackedColorArray, axis: int) -> PackedColorArray:
	var arr: Array = []
	for c in bucket:
		arr.append(c)
	match axis:
		0: arr.sort_custom(func(a, b): return a.r < b.r)
		1: arr.sort_custom(func(a, b): return a.g < b.g)
		_: arr.sort_custom(func(a, b): return a.b < b.b)
	var out := PackedColorArray()
	for c in arr:
		out.append(c)
	return out

func _average_color(bucket: PackedColorArray) -> Color:
	if bucket.size() == 0:
		return Color.BLACK
	var r := 0.0
	var g := 0.0
	var b := 0.0
	for c in bucket:
		r += c.r
		g += c.g
		b += c.b
	var n := float(bucket.size())
	return Color(r / n, g / n, b / n)

func _color_distance(a: Color, b: Color, perceptual: bool) -> float:
	if not perceptual:
		var dr := a.r - b.r
		var dg := a.g - b.g
		var db := a.b - b.b
		return dr * dr + dg * dg + db * db
	# Approximate perceptual distance using a weighted RGB metric
	# (https://www.compuphase.com/cmetric.htm)
	var rmean := (a.r + b.r) * 0.5
	var dr2 := a.r - b.r
	var dg2 := a.g - b.g
	var db2 := a.b - b.b
	return ((2.0 + rmean) * dr2 * dr2) + (4.0 * dg2 * dg2) + ((3.0 - rmean) * db2 * db2)

func _merge_palette(target: PackedColorArray, src: PackedColorArray) -> void:
	for c in src:
		var dup := false
		for t in target:
			if _color_distance(c, t, true) < 0.005:
				dup = true
				break
		if not dup:
			target.append(c)

func _palette_index_for(palette: PackedColorArray, c: Color) -> int:
	if palette.size() == 0:
		return -1
	var best := 0
	var best_d := INF
	for i in range(palette.size()):
		var d := _color_distance(c, palette[i], true)
		if d < best_d:
			best_d = d
			best = i
	return best

# ── Depth estimation ──────────────────────────────────────────────────────────

func _build_depth_map(img: Image, mode: int) -> PackedFloat32Array:
	var w := img.get_width()
	var h := img.get_height()
	var out := PackedFloat32Array()
	out.resize(w * h)
	var luma_map := PackedFloat32Array()
	luma_map.resize(w * h)
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			var l := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			luma_map[y * w + x] = l
	match mode:
		DepthMode.LUMINANCE:
			for i in range(out.size()):
				out[i] = luma_map[i]
		DepthMode.INVERSE_LUMA:
			for i in range(out.size()):
				out[i] = 1.0 - luma_map[i]
		DepthMode.SATURATION:
			for y in range(h):
				for x in range(w):
					var c := img.get_pixel(x, y)
					out[y * w + x] = c.s
		DepthMode.EDGE_HEIGHT:
			out = _sobel_edges(luma_map, w, h)
		DepthMode.HYBRID:
			var edges := _sobel_edges(luma_map, w, h)
			for i in range(out.size()):
				var e := edges[i]
				var l := luma_map[i]
				out[i] = clamp(0.45 * l + 0.55 * e, 0.0, 1.0)
		DepthMode.FLAT:
			for i in range(out.size()):
				out[i] = 0.0
		_:
			for i in range(out.size()):
				out[i] = luma_map[i]
	# Smooth the depth map for nicer voxel terraces.
	out = _smooth_float_map(out, w, h, 1)
	return out

func _sobel_edges(luma: PackedFloat32Array, w: int, h: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	var gx := [-1.0, 0.0, 1.0, -2.0, 0.0, 2.0, -1.0, 0.0, 1.0]
	var gy := [-1.0, -2.0, -1.0, 0.0, 0.0, 0.0, 1.0, 2.0, 1.0]
	var max_v := 0.0
	for y in range(h):
		for x in range(w):
			var sx := 0.0
			var sy := 0.0
			for ky in range(-1, 2):
				for kx in range(-1, 2):
					var px: int = clamp(x + kx, 0, w - 1)
					var py: int = clamp(y + ky, 0, h - 1)
					var l := luma[py * w + px]
					var ki := (ky + 1) * 3 + (kx + 1)
					sx += l * float(gx[ki])
					sy += l * float(gy[ki])
			var mag: float = sqrt(sx * sx + sy * sy)
			out[y * w + x] = mag
			if mag > max_v:
				max_v = mag
	if max_v > 0.0:
		for i in range(out.size()):
			out[i] = out[i] / max_v
	return out

func _smooth_float_map(map: PackedFloat32Array, w: int, h: int, radius: int) -> PackedFloat32Array:
	if radius <= 0:
		return map
	var out := PackedFloat32Array()
	out.resize(map.size())
	for y in range(h):
		for x in range(w):
			var s := 0.0
			var n := 0
			for dy in range(-radius, radius + 1):
				var sy: int = clamp(y + dy, 0, h - 1)
				for dx in range(-radius, radius + 1):
					var sx: int = clamp(x + dx, 0, w - 1)
					s += map[sy * w + sx]
					n += 1
			out[y * w + x] = s / float(n)
	return out

func _array_min(a: PackedFloat32Array) -> float:
	if a.size() == 0:
		return 0.0
	var v := a[0]
	for i in range(1, a.size()):
		if a[i] < v:
			v = a[i]
	return v

func _array_max(a: PackedFloat32Array) -> float:
	if a.size() == 0:
		return 0.0
	var v := a[0]
	for i in range(1, a.size()):
		if a[i] > v:
			v = a[i]
	return v

# ── Layout: distribute photos across faces of the chosen room shape ───────────

func _compute_room_layout(processed: Array, shape: int, padding: float, ceiling: float) -> Array:
	var faces: Array = []
	match shape:
		RoomShape.BOX:
			faces = _layout_box(processed.size(), padding, ceiling)
		RoomShape.CROSS:
			faces = _layout_cross(processed.size(), padding, ceiling)
		RoomShape.OCTAGON:
			faces = _layout_octagon(processed.size(), padding, ceiling)
		RoomShape.GALLERY:
			faces = _layout_gallery(processed.size(), padding, ceiling)
		RoomShape.CORRIDOR:
			faces = _layout_corridor(processed.size(), padding, ceiling)
		RoomShape.DOME:
			faces = _layout_dome(processed.size(), padding, ceiling)
		RoomShape.SPIRAL:
			faces = _layout_spiral(processed.size(), padding, ceiling)
		_:
			faces = _layout_box(processed.size(), padding, ceiling)
	# Ensure we always have one face per photo.
	while faces.size() < processed.size():
		faces.append(faces.back().duplicate(true))
	for i in range(processed.size()):
		faces[i]["index"] = i
		faces[i]["aspect"] = float(processed[i].width) / float(processed[i].height)
	return faces

func _layout_box(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var positions := [
		{"face": ProjectionFace.WALL_NORTH, "origin": Vector3(-4, 0, -4), "u": Vector3(1, 0, 0), "v": Vector3(0, 1, 0), "extent": Vector2(8, ceiling)},
		{"face": ProjectionFace.WALL_SOUTH, "origin": Vector3(4, 0, 4),  "u": Vector3(-1, 0, 0), "v": Vector3(0, 1, 0), "extent": Vector2(8, ceiling)},
		{"face": ProjectionFace.WALL_EAST,  "origin": Vector3(4, 0, -4), "u": Vector3(0, 0, 1), "v": Vector3(0, 1, 0), "extent": Vector2(8, ceiling)},
		{"face": ProjectionFace.WALL_WEST,  "origin": Vector3(-4, 0, 4), "u": Vector3(0, 0, -1), "v": Vector3(0, 1, 0), "extent": Vector2(8, ceiling)},
		{"face": ProjectionFace.FLOOR,      "origin": Vector3(-4, 0, -4), "u": Vector3(1, 0, 0), "v": Vector3(0, 0, 1), "extent": Vector2(8, 8)},
		{"face": ProjectionFace.CEILING,    "origin": Vector3(-4, ceiling, 4), "u": Vector3(1, 0, 0), "v": Vector3(0, 0, -1), "extent": Vector2(8, 8)},
	]
	for i in range(n):
		var slot: Dictionary = positions[i % positions.size()].duplicate(true)
		slot["padding"] = padding
		faces.append(slot)
	return faces

func _layout_cross(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var arms := [
		Vector3(0, 0, -6), Vector3(0, 0, 6), Vector3(-6, 0, 0), Vector3(6, 0, 0),
	]
	for i in range(n):
		var arm: Vector3 = arms[i % arms.size()]
		var u: Vector3 = (Vector3(1, 0, 0) if abs(arm.z) > abs(arm.x) else Vector3(0, 0, 1))
		faces.append({
			"face":    ProjectionFace.WALL_NORTH,
			"origin":  arm + Vector3(-3, 0, 0) * (1.0 if arm.z != 0 else 0.0) + Vector3(0, 0, -3) * (1.0 if arm.x != 0 else 0.0),
			"u":       u,
			"v":       Vector3(0, 1, 0),
			"extent":  Vector2(6, ceiling),
			"padding": padding,
		})
	return faces

func _layout_octagon(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var radius: float = 6.0
	var sides: int = 8
	for i in range(n):
		var side: int = i % sides
		var angle: float = float(side) / float(sides) * TAU
		var center := Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var width: float = TAU * radius / float(sides)
		faces.append({
			"face":    ProjectionFace.WALL_NORTH,
			"origin":  center - tangent * (width * 0.5),
			"u":       tangent,
			"v":       Vector3(0, 1, 0),
			"extent":  Vector2(width, ceiling),
			"padding": padding,
		})
	return faces

func _layout_gallery(n: int, padding: float, ceiling: float) -> Array:
	# Two long facing walls with photos placed left-to-right.
	var faces := []
	var per_wall: int = max(1, int(ceil(float(n) / 2.0)))
	var width: float = 4.0
	var spacing: float = padding + width
	for i in range(n):
		var wall_index: int = i % 2
		var slot: int = i / 2
		var z_origin: float = -spacing * (per_wall - 1) * 0.5 + slot * spacing - width * 0.5
		if wall_index == 0:
			faces.append({
				"face":    ProjectionFace.WALL_EAST,
				"origin":  Vector3(5, 0, z_origin),
				"u":       Vector3(0, 0, 1),
				"v":       Vector3(0, 1, 0),
				"extent":  Vector2(width, ceiling - 0.5),
				"padding": padding,
			})
		else:
			faces.append({
				"face":    ProjectionFace.WALL_WEST,
				"origin":  Vector3(-5, 0, z_origin + width),
				"u":       Vector3(0, 0, -1),
				"v":       Vector3(0, 1, 0),
				"extent":  Vector2(width, ceiling - 0.5),
				"padding": padding,
			})
	return faces

func _layout_corridor(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var spacing: float = 3.0 + padding
	for i in range(n):
		var z := -float(n - 1) * spacing * 0.5 + float(i) * spacing
		faces.append({
			"face":    ProjectionFace.WALL_EAST,
			"origin":  Vector3(3, 0, z - 1.5),
			"u":       Vector3(0, 0, 1),
			"v":       Vector3(0, 1, 0),
			"extent":  Vector2(3, ceiling - 0.5),
			"padding": padding,
		})
	return faces

func _layout_dome(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var radius: float = 7.0
	for i in range(n):
		var golden := PI * (3.0 - sqrt(5.0))
		var theta: float = golden * float(i)
		var z: float = 1.0 - (float(i) / max(1.0, float(n - 1))) * 0.85
		var r: float = sqrt(max(0.0, 1.0 - z * z))
		var center := Vector3(cos(theta) * r * radius, ceiling * (1.0 - z), sin(theta) * r * radius)
		var normal := -center.normalized()
		var tangent: Vector3 = normal.cross(Vector3.UP).normalized()
		if tangent.length() < 0.01:
			tangent = Vector3.RIGHT
		var up_axis: Vector3 = tangent.cross(normal).normalized()
		faces.append({
			"face":    ProjectionFace.FREEFORM,
			"origin":  center - tangent * 1.5 - up_axis * 1.5,
			"u":       tangent,
			"v":       up_axis,
			"extent":  Vector2(3.0, 3.0),
			"padding": padding,
		})
	return faces

func _layout_spiral(n: int, padding: float, ceiling: float) -> Array:
	var faces := []
	var radius: float = 5.0
	for i in range(n):
		var t: float = float(i) / max(1.0, float(n - 1))
		var angle: float = t * TAU * 1.6
		var height: float = t * (ceiling - 0.5) + 0.25
		var center := Vector3(cos(angle) * radius, height, sin(angle) * radius)
		var tangent: Vector3 = Vector3(-sin(angle), 0.0, cos(angle))
		faces.append({
			"face":    ProjectionFace.FREEFORM,
			"origin":  center - tangent * 1.5,
			"u":       tangent,
			"v":       Vector3(0, 1, 0),
			"extent":  Vector2(3.0, 1.8),
			"padding": padding,
		})
	return faces

func _layout_bounds(layout: Array) -> Vector3:
	var min_v := Vector3.INF
	var max_v := -Vector3.INF
	for slot in layout:
		var origin: Vector3 = slot["origin"]
		var u: Vector3 = slot["u"]
		var v: Vector3 = slot["v"]
		var extent: Vector2 = slot["extent"]
		var corners := [
			origin,
			origin + u * extent.x,
			origin + v * extent.y,
			origin + u * extent.x + v * extent.y,
		]
		for c in corners:
			min_v.x = min(min_v.x, c.x)
			min_v.y = min(min_v.y, c.y)
			min_v.z = min(min_v.z, c.z)
			max_v.x = max(max_v.x, c.x)
			max_v.y = max(max_v.y, c.y)
			max_v.z = max(max_v.z, c.z)
	if min_v == Vector3.INF:
		return Vector3.ZERO
	return max_v - min_v

# ── Stage 3: extrude per-photo voxels ─────────────────────────────────────────

func _extrude_photo_into_voxels(entry: Dictionary, slot: Dictionary, photo_index: int) -> Array:
	var img: Image = entry["image"]
	var depth: PackedFloat32Array = entry["depth"]
	var w: int = entry["width"]
	var h: int = entry["height"]
	var origin: Vector3 = slot["origin"]
	var u: Vector3 = slot["u"]
	var v: Vector3 = slot["v"]
	var extent: Vector2 = slot["extent"]
	var face_id: int = slot["face"]
	var normal: Vector3 = u.cross(v).normalized()
	if normal.length() < 0.01:
		normal = Vector3.UP
	var unit_u: float = extent.x / float(w)
	var unit_v: float = extent.y / float(h)
	var unit: float = min(unit_u, unit_v)
	# Re-center the projection so it doesn't overflow when w/h aspect differs
	var actual_w: float = unit * float(w)
	var actual_h: float = unit * float(h)
	var offset_u: float = (extent.x - actual_w) * 0.5
	var offset_v: float = (extent.y - actual_h) * 0.5
	var voxels: Array = []
	for y in range(h):
		for x in range(w):
			var pixel: Color = img.get_pixel(x, y)
			if pixel.a < reproject_alpha_cutoff:
				continue
			var d := depth[y * w + x]
			var height_units: int = int(round(d * float(max_height_voxels)))
			if depth_mode == DepthMode.FLAT:
				height_units = 1
			height_units = max(1, height_units)
			# Build a stacked column of voxels along the face normal.
			for layer in range(height_units):
				var jitter: Vector3 = Vector3(
					_rng.randf_range(-noise_jitter, noise_jitter),
					_rng.randf_range(-noise_jitter, noise_jitter),
					_rng.randf_range(-noise_jitter, noise_jitter),
				) * voxel_size
				var pos: Vector3 = origin \
					+ u * (offset_u + (float(x) + 0.5) * unit) \
					+ v * (offset_v + (float(h - y - 1) + 0.5) * unit) \
					+ normal * (float(layer) + 0.5) * voxel_size
				pos += jitter
				var emis: float = 0.0
				if pixel.get_luminance() > emission_threshold:
					emis = (pixel.get_luminance() - emission_threshold) * glow_strength * 4.0
				voxels.append({
					"position":  pos,
					"size":      Vector3.ONE * voxel_size,
					"color":     pixel,
					"emission":  emis,
					"face":      face_id,
					"photo":     photo_index,
					"flags":     0,
				})
	return voxels

# ── Stage 4: floor & lights ───────────────────────────────────────────────────

func _build_floor_carpet(palette: PackedColorArray, room_size: Vector3) -> Array:
	if palette.size() == 0:
		return []
	var voxels: Array = []
	var size_x: int = max(8, int(round(room_size.x / voxel_size)))
	var size_z: int = max(8, int(round(room_size.z / voxel_size)))
	var origin := Vector3(-room_size.x * 0.5, -voxel_size, -room_size.z * 0.5)
	for z in range(size_z):
		for x in range(size_x):
			var pal_idx: int = (x * 31 + z * 17) % palette.size()
			var c: Color = palette[pal_idx].lerp(Color(0.05, 0.05, 0.07), 0.6)
			voxels.append({
				"position": origin + Vector3(float(x) * voxel_size, 0, float(z) * voxel_size),
				"size":     Vector3(voxel_size, voxel_size * 0.25, voxel_size),
				"color":    c,
				"emission": 0.0,
				"face":     ProjectionFace.FLOOR,
				"photo":    -1,
				"flags":    1,
			})
	return voxels

func _build_ceiling_lights(palette: PackedColorArray, room_size: Vector3, ceiling: float) -> Array:
	if palette.size() == 0:
		return []
	var voxels: Array = []
	var step := 2.0
	var x_count: int = max(2, int(room_size.x / step))
	var z_count: int = max(2, int(room_size.z / step))
	for ix in range(x_count):
		for iz in range(z_count):
			var pal_idx: int = (ix * 7 + iz * 13) % palette.size()
			var c: Color = palette[pal_idx]
			voxels.append({
				"position": Vector3(-room_size.x * 0.5 + (float(ix) + 0.5) * step, ceiling - voxel_size, -room_size.z * 0.5 + (float(iz) + 0.5) * step),
				"size":     Vector3(voxel_size * 1.5, voxel_size * 0.5, voxel_size * 1.5),
				"color":    c,
				"emission": 1.6,
				"face":     ProjectionFace.CEILING,
				"photo":    -1,
				"flags":    2,
			})
	return voxels

# ── Stage 5: build MultiMeshInstance3D nodes ──────────────────────────────────

func _build_multi_mesh_instances(parent: Node3D, voxels: Array, palette: PackedColorArray) -> Array:
	# Group voxels by palette bucket so that all voxels sharing a color share a
	# single MultiMesh + Material. This keeps draw-call counts very low even for
	# rooms with tens of thousands of voxels.
	var groups: Dictionary = {}
	for v in voxels:
		var idx: int = _palette_index_for(palette, v.color)
		if not groups.has(idx):
			groups[idx] = []
		(groups[idx] as Array).append(v)
	var instances: Array = []
	for key in groups.keys():
		var arr: Array = groups[key]
		var color: Color = palette[key] if key >= 0 and key < palette.size() else Color.WHITE
		var emission_total := 0.0
		for v in arr:
			emission_total += float(v.emission)
		var avg_emission: float = emission_total / float(arr.size())
		var mesh: BoxMesh = BoxMesh.new()
		mesh.size = Vector3.ONE * voxel_size
		var multi := MultiMesh.new()
		multi.mesh = mesh
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = true
		multi.instance_count = arr.size()
		for i in range(arr.size()):
			var v: Dictionary = arr[i]
			var t := Transform3D()
			var sx: float = float(v.size.x) / voxel_size
			var sy: float = float(v.size.y) / voxel_size
			var sz: float = float(v.size.z) / voxel_size
			t.basis = Basis().scaled(Vector3(sx, sy, sz))
			t.origin = v.position
			multi.set_instance_transform(i, t)
			multi.set_instance_color(i, v.color)
		var inst := MultiMeshInstance3D.new()
		inst.multimesh = multi
		inst.name = "VoxelGroup_%d" % int(key)
		var mat: Material = _resolve_material(color, avg_emission, int(key))
		if mat != null:
			inst.material_override = mat
		parent.add_child(inst)
		instances.append(inst)
	return instances

func _resolve_material(color: Color, emission: float, palette_index: int) -> Material:
	if _voxel_material_factory != null and _voxel_material_factory.has_method("build_material"):
		return _voxel_material_factory.call("build_material", color, emission, palette_index)
	# Fallback: simple StandardMaterial3D so the room is still visible if no
	# external factory is attached.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if emission > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission
	mat.metallic = 0.05
	mat.roughness = 0.65
	return mat

# ── Editing helpers (used by MemoryArchitect.gd) ──────────────────────────────

func add_single_voxel(album_id: String, world_position: Vector3, color: Color, emission: float = 0.0) -> bool:
	if not _albums.has(album_id):
		return false
	var record: Dictionary = _albums[album_id]
	var parent: Node3D = record.node
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * voxel_size
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.transform.origin = world_position - parent.global_transform.origin
	inst.material_override = _resolve_material(color, emission, -1)
	inst.set_meta("voxel_color", color)
	inst.set_meta("voxel_emission", emission)
	parent.add_child(inst)
	record["voxel_count"] = int(record.get("voxel_count", 0)) + 1
	return true

func remove_voxel_at(album_id: String, world_position: Vector3, radius: float = 0.0) -> int:
	if not _albums.has(album_id):
		return 0
	var record: Dictionary = _albums[album_id]
	var parent: Node3D = record.node
	var removed := 0
	var test_radius: float = max(radius, voxel_size * 0.5)
	for child in parent.get_children():
		if child is MeshInstance3D:
			var dist: float = parent.to_global(child.transform.origin).distance_to(world_position)
			if dist <= test_radius:
				child.queue_free()
				removed += 1
	record["voxel_count"] = max(0, int(record.get("voxel_count", 0)) - removed)
	return removed

func recolor_voxels_at(album_id: String, world_position: Vector3, radius: float, new_color: Color) -> int:
	if not _albums.has(album_id):
		return 0
	var record: Dictionary = _albums[album_id]
	var parent: Node3D = record.node
	var changed := 0
	for child in parent.get_children():
		if child is MeshInstance3D:
			var dist: float = parent.to_global(child.transform.origin).distance_to(world_position)
			if dist <= radius:
				var emis: float = float(child.get_meta("voxel_emission", 0.0))
				child.material_override = _resolve_material(new_color, emis, -1)
				child.set_meta("voxel_color", new_color)
				changed += 1
	return changed

func translate_room(album_id: String, delta: Vector3) -> void:
	if not _albums.has(album_id):
		return
	var record: Dictionary = _albums[album_id]
	(record.node as Node3D).transform.origin += delta

func rotate_room(album_id: String, axis: Vector3, angle_rad: float) -> void:
	if not _albums.has(album_id):
		return
	var record: Dictionary = _albums[album_id]
	(record.node as Node3D).rotate(axis.normalized(), angle_rad)

func scale_room(album_id: String, factor: float) -> void:
	if not _albums.has(album_id):
		return
	var record: Dictionary = _albums[album_id]
	(record.node as Node3D).scale = (record.node as Node3D).scale * factor

func destroy_room(album_id: String) -> void:
	if not _albums.has(album_id):
		return
	var record: Dictionary = _albums[album_id]
	if record.node and is_instance_valid(record.node):
		(record.node as Node3D).queue_free()
	_albums.erase(album_id)

# ── Persistence helpers ───────────────────────────────────────────────────────

func serialize_album(album_id: String) -> Dictionary:
	if not _albums.has(album_id):
		return {}
	var record: Dictionary = _albums[album_id]
	var palette_arr := []
	for c in (record.palette as PackedColorArray):
		palette_arr.append([c.r, c.g, c.b, c.a])
	return {
		"album_id":    album_id,
		"voxel_count": record.voxel_count,
		"shape":       record.shape,
		"room_size":   [record.room_size.x, record.room_size.y, record.room_size.z],
		"palette":     palette_arr,
		"created_at":  record.created_at,
	}

func save_album_to_disk(album_id: String, path: String) -> bool:
	var data := serialize_album(album_id)
	if data.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true

func load_album_descriptor(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

# ── Diagnostics ───────────────────────────────────────────────────────────────

func get_diagnostics() -> Dictionary:
	return {
		"albums":          _albums.size(),
		"is_generating":   _is_generating,
		"queue_length":    _generation_queue.size(),
		"total_voxels":    get_total_voxel_count(),
		"palette_cached":  _palette_cache.size(),
		"depth_cached":    _depth_cache.size(),
		"voxel_size":      voxel_size,
		"max_resolution":  max_resolution,
	}

func clear_caches() -> void:
	_palette_cache.clear()
	_depth_cache.clear()
