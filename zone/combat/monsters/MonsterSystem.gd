# res://zone/combat/MonsterSystem.gd
extends Node
class_name MonsterSystem

var log: Callable = func(_m): pass

var monster_scene_default: PackedScene = null
var world_root: Node = null

# type_id(String) -> MonsterData
var monster_catalog: Dictionary = {}

# monster_id -> Dictionary (runtime state)
var monsters: Dictionary = {}
var monster_next_id := 1

func configure(_monster_scene_default: PackedScene, _world_root: Node, _catalog: Dictionary) -> void:
	monster_scene_default = _monster_scene_default
	world_root = _world_root
	monster_catalog = _catalog if _catalog != null else {}

func has_monsters() -> bool:
	return not monsters.is_empty()

func get_monsters() -> Dictionary:
	return monsters

func get_monster(monster_id: int) -> Dictionary:
	return monsters.get(monster_id, {})

func _get_data(type_id: String) -> MonsterData:
	if type_id.is_empty():
		return null
	if monster_catalog.has(type_id):
		return monster_catalog[type_id] as MonsterData
	return null

# TEMP: keep your existing test spawn behavior (now type-driven)
func spawn_test_monsters() -> Array:
	var spawned: Array = []
	spawned.append(spawn_monster("slime_blue", Vector3(4, 1, -4)))
	spawned.append(spawn_monster("goblin_green", Vector3(-4, 1, -6)))
	return spawned

# -------------------------------------------------------
# NEW: Spawn from map markers + API spawn entries
# -------------------------------------------------------
# Expects:
# - map_root has "MonsterSpawners" Node3D with Marker3D children
# - spawn_entries: Array of Dictionaries like:
#   { typeId, weight, minPackSize, maxPackSize, minPacks, maxPacks, ... }
#
# Returns: Array of spawn_monster() return dicts
func spawn_from_map(map_root: Node, spawn_entries: Array, seed: int) -> Array:
	var out: Array = []

	if map_root == null:
		log.call("[SPAWN] spawn_from_map: map_root null")
		return out
	if spawn_entries.is_empty():
		log.call("[SPAWN] spawn_from_map: spawn_entries empty")
		return out

	var marker_points := _collect_monster_spawn_markers(map_root)
	if marker_points.is_empty():
		log.call("[SPAWN] spawn_from_map: no MonsterSpawners markers")
		return out

	# deterministic RNG per zone
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed) ^ 0x51A3C9D1

	# We'll try not to reuse the same marker as a pack center until we run out
	var available_centers: Array[Marker3D] = marker_points.duplicate()

	# Tune these as you like
	var pack_scatter_radius := 2.75   # how far pack members spread around center
	var pack_min_sep := 0.4           # minimum separation between members (soft)

	# Spawn each rule as its own "species" with 1..N packs
	for entry in spawn_entries:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = entry

		var type_id := str(e.get("typeId", e.get("type_id", "")))
		if type_id.is_empty():
			continue

		# If the monster isn't in the catalog, we can still spawn with fallback defaults
		# but it's useful to log it once.
		if _get_data(type_id) == null:
			log.call("[SPAWN] WARNING: type_id not in catalog: " + type_id)

		var min_packs := int(e.get("minPacks", 1))
		var max_packs := int(e.get("maxPacks", min_packs))
		if max_packs < min_packs:
			max_packs = min_packs

		var packs := rng.randi_range(min_packs, max_packs)

		var min_pack_size := int(e.get("minPackSize", 1))
		var max_pack_size := int(e.get("maxPackSize", min_pack_size))
		if max_pack_size < min_pack_size:
			max_pack_size = min_pack_size

		log.call("[SPAWN] rule type=%s packs=%d pack_size=[%d..%d]" % [type_id, packs, min_pack_size, max_pack_size])

		for _pi in range(packs):
			var center := _pick_pack_center(rng, available_centers, marker_points)
			if center == null:
				break

			var pack_size := rng.randi_range(min_pack_size, max_pack_size)

			# Spawn pack members around center
			for _mi in range(pack_size):
				var pos := _scatter_around_marker(rng, center, pack_scatter_radius, pack_min_sep)
				out.append(spawn_monster(type_id, pos))

	log.call("[SPAWN] spawn_from_map total_spawned=%d" % out.size())
	return out

func _collect_monster_spawn_markers(map_root: Node) -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	var spawners := map_root.get_node_or_null("MonsterSpawners")
	if spawners == null:
		return out

	for c in spawners.get_children():
		if c is Marker3D:
			out.append(c as Marker3D)

	return out

func _pick_pack_center(rng: RandomNumberGenerator, available: Array, all_markers: Array) -> Marker3D:
	# Prefer unused centers first
	if not available.is_empty():
		var idx := rng.randi_range(0, available.size() - 1)
		var m := available[idx] as Marker3D
		available.remove_at(idx)
		return m

	# If we used them all, allow reuse
	if all_markers.is_empty():
		return null
	return all_markers[rng.randi_range(0, all_markers.size() - 1)] as Marker3D

func _scatter_around_marker(rng: RandomNumberGenerator, center: Marker3D, radius: float, _min_sep: float) -> Vector3:
	# Simple uniform-ish scatter in a disk around marker.
	# (min_sep is a placeholder if you want to do rejection sampling later.)
	var r := radius * sqrt(rng.randf())
	var theta := rng.randf_range(0.0, TAU)
	var offset := Vector3(cos(theta) * r, 0.0, sin(theta) * r)

	var base := center.global_transform.origin
	return base + offset

# -------------------------------------------------------
# Existing spawn_monster() etc.
# -------------------------------------------------------

func spawn_monster(type_id: String, pos: Vector3) -> Dictionary:
	var data := _get_data(type_id)

	# Fallback if data missing
	var max_hp := 5
	var name := type_id
	var aggro_radius := 10.0
	var move_speed := 3.5
	var melee_range := 1.5
	var melee_cooldown := 1.0
	var melee_damage := 1

	if data:
		if not data.display_name.is_empty():
			name = data.display_name
		max_hp = int(data.max_hp)
		aggro_radius = float(data.aggro_radius)
		move_speed = float(data.move_speed)
		melee_range = float(data.melee_range)
		melee_cooldown = float(data.melee_cooldown)
		melee_damage = int(data.melee_damage)

	var id := monster_next_id
	monster_next_id += 1

	var x := Transform3D(Basis.IDENTITY, pos)

	monsters[id] = {
		"type_id": type_id,
		"name": name,
		"hp": max_hp,
		"max_hp": max_hp,
		"xform": x,
		"radius": 0.6,

		# AI
		"aggro_peer": 0,
		"aggro_radius": aggro_radius,
		"move_speed": move_speed,
		"melee_range": melee_range,
		"melee_cooldown": melee_cooldown,
		"melee_cd_left": 0.0,
		"melee_damage": melee_damage,
	}

	log.call("[SPAWN] id=%d type=%s name=%s" % [id, type_id, name])

	# Optional: server-side debug node
	if monster_scene_default and world_root:
		var inst := monster_scene_default.instantiate()
		inst.name = "Monster_%d" % id
		world_root.add_child(inst)
		if inst is Node3D:
			(inst as Node3D).global_transform = x

	return {
		"id": id,
		"type_id": type_id,
		"name": name,
		"xform": x,
		"hp": max_hp,
		"max_hp": max_hp
	}

func apply_damage(monster_id: int, dmg: int) -> Dictionary:
	if not monsters.has(monster_id):
		return {"exists": false, "hp": 0, "max_hp": 0, "died": false}

	var m: Dictionary = monsters[monster_id]
	var hp := int(m.get("hp", 0)) - int(dmg)
	m["hp"] = hp
	monsters[monster_id] = m

	if hp > 0:
		return {"exists": true, "hp": hp, "max_hp": int(m.get("max_hp", 0)), "died": false}

	monsters.erase(monster_id)

	var n := world_root.get_node_or_null("Monster_%d" % monster_id) if world_root else null
	if n:
		n.queue_free()

	return {"exists": false, "hp": 0, "max_hp": 0, "died": true}

func get_monster_snapshot_list() -> Array:
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		out.append({
			"id": int(mid),
			"type_id": str(m.get("type_id", "")),
			"name": str(m.get("name", "")),
			"xform": m.get("xform", Transform3D.IDENTITY),
			"hp": int(m.get("hp", 0)),
			"max_hp": int(m.get("max_hp", 0)),
		})
	return out

func get_hurtboxes() -> Array:
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		out.append({
			"kind": "monster",
			"id": int(mid),
			"xform": m.get("xform", Transform3D.IDENTITY),
			"radius": float(m.get("radius", 0.6)),
		})
	return out

func tick_ai(dt: float, players: ZonePlayers) -> Array:
	var events: Array = []
	if monsters.is_empty():
		return events
	if players == null:
		return events

	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		if int(m.get("hp", 0)) <= 0:
			continue

		var cd_left := float(m.get("melee_cd_left", 0.0))
		cd_left = max(cd_left - dt, 0.0)
		m["melee_cd_left"] = cd_left

		var mxform: Transform3D = m.get("xform", Transform3D.IDENTITY)
		var mpos: Vector3 = mxform.origin

		var aggro_peer := int(m.get("aggro_peer", 0))
		if aggro_peer != 0:
			if not players.has_peer(aggro_peer) or not players.is_alive(aggro_peer):
				aggro_peer = 0
				m["aggro_peer"] = 0

		if aggro_peer == 0:
			aggro_peer = _find_nearest_player_in_radius(players, mpos, float(m.get("aggro_radius", 10.0)))
			m["aggro_peer"] = aggro_peer

		if aggro_peer == 0:
			monsters[mid] = m
			continue

		var pxform := players.get_player_xform(aggro_peer)
		var ppos := pxform.origin
		ppos.y = mpos.y

		var to := ppos - mpos
		var dist := to.length()

		var melee_range := float(m.get("melee_range", 1.5))
		if dist <= melee_range:
			if cd_left <= 0.0:
				var dmg := int(m.get("melee_damage", 1))
				events.append({
					"type": "melee_hit",
					"monster_id": int(mid),
					"target_peer": int(aggro_peer),
					"damage": dmg,
				})
				m["melee_cd_left"] = float(m.get("melee_cooldown", 1.0))
		else:
			var dir := (to / dist) if dist > 0.001 else Vector3.ZERO
			var speed := float(m.get("move_speed", 3.5))
			var step = min(speed * dt, dist)

			mpos += dir * step
			mxform.origin = mpos
			m["xform"] = mxform

			var n := world_root.get_node_or_null("Monster_%d" % int(mid)) if world_root else null
			if n and n is Node3D:
				(n as Node3D).global_transform = mxform

		monsters[mid] = m

	return events

func _find_nearest_player_in_radius(players: ZonePlayers, from_pos: Vector3, radius: float) -> int:
	var best_peer := 0
	var best_d2 := radius * radius

	for pid in players.players_by_peer.keys():
		var peer_id := int(pid)
		if not players.is_alive(peer_id):
			continue
		var pxform := players.get_player_xform(peer_id)
		var ppos := pxform.origin
		ppos.y = from_pos.y

		var d2 := (ppos - from_pos).length_squared()
		if d2 <= best_d2:
			best_d2 = d2
			best_peer = peer_id

	return best_peer

func build_snapshot_list() -> Array:
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		var x: Transform3D = m.get("xform", Transform3D.IDENTITY)
		out.append({
			"id": int(mid),
			"pos": x.origin,
		})
	return out
