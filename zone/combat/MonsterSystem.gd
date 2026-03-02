# res://zone/combat/MonsterSystem.gd
extends Node
class_name MonsterSystem

var log: Callable = func(_m): pass

var monster_scene: PackedScene = null
var world_root: Node = null

# monster_id -> Dictionary
# {
#   hp:int,
#   xform:Transform3D,
#   radius:float,
#   # AI:
#   aggro_peer:int,
#   aggro_radius:float,
#   move_speed:float,
#   melee_range:float,
#   melee_cooldown:float,
#   melee_cd_left:float
# }
var monsters: Dictionary = {}
var monster_next_id := 1

func configure(_monster_scene: PackedScene, _world_root: Node) -> void:
	monster_scene = _monster_scene
	world_root = _world_root

func has_monsters() -> bool:
	return not monsters.is_empty()

func get_monsters() -> Dictionary:
	return monsters

# TEMP: keep your existing test spawn behavior
func spawn_test_monsters() -> Array:
	var spawned: Array = []
	spawned.append(spawn_monster_at(Vector3(4, 1, -4), 3))
	spawned.append(spawn_monster_at(Vector3(-4, 1, -6), 5))
	return spawned

func spawn_monster_at(pos: Vector3, hp: int) -> Dictionary:
	var id := monster_next_id
	monster_next_id += 1

	var x := Transform3D(Basis.IDENTITY, pos)
	monsters[id] = {
		"hp": hp,
		"xform": x,
		"radius": 0.6,

		# --- AI defaults (tune later / data-drive later) ---
		"aggro_peer": 0,
		"aggro_radius": 10.0,
		"move_speed": 3.5,
		"melee_range": 1.5,
		"melee_cooldown": 1.0,
		"melee_cd_left": 0.0,
	}

	# Optional: server-side debug node
	if monster_scene and world_root:
		var inst := monster_scene.instantiate()
		inst.name = "Monster_%d" % id
		world_root.add_child(inst)
		if inst is Node3D:
			(inst as Node3D).global_transform = x

	return {"id": id, "xform": x, "hp": hp}

func apply_damage(monster_id: int, dmg: int) -> Dictionary:
	# returns {exists: bool, hp: int, died: bool}
	if not monsters.has(monster_id):
		return {"exists": false, "hp": 0, "died": false}

	var m: Dictionary = monsters[monster_id]
	var hp := int(m.get("hp", 0)) - int(dmg)
	m["hp"] = hp
	monsters[monster_id] = m

	if hp > 0:
		return {"exists": true, "hp": hp, "died": false}

	# died
	monsters.erase(monster_id)

	# remove server node if exists
	var n := world_root.get_node_or_null("Monster_%d" % monster_id) if world_root else null
	if n:
		n.queue_free()

	return {"exists": false, "hp": 0, "died": true}

func get_monster_snapshot_list() -> Array:
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		out.append({
			"id": int(mid),
			"xform": m.get("xform", Transform3D.IDENTITY),
			"hp": int(m.get("hp", 0)),
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

# -------------------------------------------------------
# AI tick: aggro → chase → melee
# Returns "attack intents" as events (NOT damage yet)
# -------------------------------------------------------
# Output event shape:
#  {"type":"melee_hit", "monster_id":int, "target_peer":int}
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

		# cooldown tick
		var cd_left := float(m.get("melee_cd_left", 0.0))
		cd_left = max(cd_left - dt, 0.0)
		m["melee_cd_left"] = cd_left

		var mxform: Transform3D = m.get("xform", Transform3D.IDENTITY)
		var mpos: Vector3 = mxform.origin

		# validate / acquire aggro target
		var aggro_peer := int(m.get("aggro_peer", 0))
		if aggro_peer != 0:
			if not players.has_peer(aggro_peer) or not players.is_alive(aggro_peer):
				aggro_peer = 0
				m["aggro_peer"] = 0

		if aggro_peer == 0:
			aggro_peer = _find_nearest_player_in_radius(players, mpos, float(m.get("aggro_radius", 10.0)))
			m["aggro_peer"] = aggro_peer

		# no target → idle
		if aggro_peer == 0:
			monsters[mid] = m
			continue

		# chase target
		var pxform := players.get_player_xform(aggro_peer)
		var ppos := pxform.origin
		ppos.y = mpos.y

		var to := ppos - mpos
		var dist := to.length()

		var melee_range := float(m.get("melee_range", 1.5))
		if dist <= melee_range:
			# in range: swing if cooldown ready
			if cd_left <= 0.0:
				events.append({
					"type": "melee_hit",
					"monster_id": int(mid),
					"target_peer": int(aggro_peer),
				})
				# DEBUG: proves melee is firing
				log.call("[AI] Monster_%d melee_hit -> peer %d" % [int(mid), int(aggro_peer)])

				m["melee_cd_left"] = float(m.get("melee_cooldown", 1.0))
		else:
			# move toward player
			var dir := (to / dist) if dist > 0.001 else Vector3.ZERO
			var speed := float(m.get("move_speed", 3.5))
			var step = min(speed * dt, dist)

			mpos += dir * step
			mxform.origin = mpos
			m["xform"] = mxform

			# sync debug node if exists
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
	# [{id:int, pos:Vector3}]
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		var x: Transform3D = m.get("xform", Transform3D.IDENTITY)
		out.append({
			"id": int(mid),
			"pos": x.origin,
		})
	return out
