extends Resource
class_name MonsterDatabase

@export var entries: Array[MonsterEntry] = []

func build_data_catalog(log: Callable = func(_m): pass) -> Dictionary:
	var catalog: Dictionary = {}

	for e in entries:
		if e == null:
			continue

		var tid := (e.type_id if e.type_id != null else "").strip_edges()
		if tid.is_empty():
			log.call("[MONDB] WARNING: entry missing type_id")
			continue

		if catalog.has(tid):
			log.call("[MONDB] ERROR: duplicate type_id: " + tid)
			continue

		if e.data == null:
			log.call("[MONDB] ERROR: %s has no MonsterData" % tid)
			continue

		# Optional sanity: if MonsterData has type_id, enforce match
		if e.data.type_id.strip_edges() != "" and e.data.type_id != tid:
			log.call("[MONDB] ERROR: %s MonsterData.type_id mismatch: %s"
				% [tid, e.data.type_id])

		catalog[tid] = e.data

	log.call("[MONDB] Loaded MonsterData count=" + str(catalog.size()))
	return catalog

func build_scene_map(log: Callable = func(_m): pass) -> Dictionary:
	var out: Dictionary = {}
	for e in entries:
		if e == null:
			continue
		var tid := (e.type_id if e.type_id != null else "").strip_edges()
		if tid.is_empty():
			continue
		if e.scene != null:
			out[tid] = e.scene
	log.call("[MONDB] Loaded monster scene mappings=" + str(out.size()))
	return out

func validate(log: Callable = func(_m): pass) -> bool:
	var ok := true
	var seen := {}

	for e in entries:
		if e == null:
			ok = false
			log.call("[MONDB] ERROR: null entry")
			continue

		var tid := (e.type_id if e.type_id != null else "").strip_edges()
		if tid.is_empty():
			ok = false
			log.call("[MONDB] ERROR: entry has empty type_id")
			continue

		if seen.has(tid):
			ok = false
			log.call("[MONDB] ERROR: duplicate type_id " + tid)
		seen[tid] = true

		if e.data == null:
			ok = false
			log.call("[MONDB] ERROR: %s missing data" % tid)

		# scene can be null in early dev, so we don't fail hard unless you want to:
		# if e.scene == null:
		#   ok = false
		#   log.call("[MONDB] ERROR: %s missing scene" % tid)

	log.call("[MONDB] validate ok=" + str(ok))
	return ok
