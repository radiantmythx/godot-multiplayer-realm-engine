# res://zone/ZonePlayers.gd
extends Node
class_name ZonePlayers

var log: Callable = func(_m): pass

var player_scene: PackedScene = null
var players_root: Node = null

# peer_id -> { character_id:int, name:String, xform:Transform3D, target:Vector3, yaw:float }
var players_by_peer: Dictionary = {}

# vitals live in their own module for easy extension
var vitals: PlayerVitals

func configure(_player_scene: PackedScene, _players_root: Node) -> void:
	player_scene = _player_scene
	players_root = _players_root

	# Create vitals as a child module (once)
	if vitals == null:
		vitals = PlayerVitals.new()
		vitals.log = func(m): log.call("[VITALS] " + str(m))
		add_child(vitals)

func has_peer(peer_id: int) -> bool:
	return players_by_peer.has(peer_id)

func get_player_count() -> int:
	return players_by_peer.size()

func remove_peer(peer_id: int) -> void:
	players_by_peer.erase(peer_id)
	if vitals:
		vitals.remove_peer(peer_id)

	var n := players_root.get_node_or_null(str(peer_id)) if players_root else null
	if n:
		n.queue_free()

func add_peer(peer_id: int, character_id: int, character_name: String, xform: Transform3D) -> void:
	players_by_peer[peer_id] = {
		"character_id": character_id,
		"name": character_name,
		"xform": xform,
		"target": xform.origin,
		"yaw": 0.0,
	}

	# init vitals
	if vitals:
		vitals.init_peer(peer_id, 10) # tune later / from DB

	# optional server-side node
	if players_root and is_instance_valid(players_root) and player_scene:
		var p := player_scene.instantiate()
		p.name = str(peer_id)
		players_root.add_child(p)
		p.set_multiplayer_authority(peer_id, true)
		if p is Node3D:
			(p as Node3D).global_transform = xform
		if p.has_method("server_init"):
			p.call("server_init", character_id)
		if p.has_method("set_player_name"):
			p.call("set_player_name", character_name)

func set_move_target(peer_id: int, world_pos: Vector3) -> void:
	if not players_by_peer.has(peer_id):
		return
	var st: Dictionary = players_by_peer[peer_id]
	st["target"] = world_pos
	players_by_peer[peer_id] = st

func set_yaw(peer_id: int, yaw: float) -> void:
	if not players_by_peer.has(peer_id):
		return
	var st: Dictionary = players_by_peer[peer_id]
	st["yaw"] = yaw
	players_by_peer[peer_id] = st

func get_player_xform(peer_id: int) -> Transform3D:
	if not players_by_peer.has(peer_id):
		return Transform3D.IDENTITY
	var st: Dictionary = players_by_peer[peer_id]
	return st.get("xform", Transform3D.IDENTITY)

# ---------------- Vitals pass-through ----------------

func apply_damage(peer_id: int, dmg: int) -> Dictionary:
	if not vitals:
		return {"exists": false, "hp": 0, "died": false}
	return vitals.apply_damage(peer_id, dmg)

func get_hp(peer_id: int) -> int:
	return vitals.get_hp(peer_id) if vitals else 0

func is_alive(peer_id: int) -> bool:
	return vitals.is_alive(peer_id) if vitals else true

func build_vitals_bulk_list() -> Array:
	return vitals.build_vitals_bulk_list() if vitals else []

# ---------------- Replication helpers ----------------

func build_spawn_bulk_list() -> Array:
	var snapshot_list: Array = []
	for pid in players_by_peer.keys():
		var st: Dictionary = players_by_peer[pid]
		snapshot_list.append({
			"peer_id": int(pid),
			"character_id": int(st.get("character_id", 0)),
			"name": str(st.get("name", "")),
			"xform": st.get("xform", Transform3D.IDENTITY),
			"yaw": float(st.get("yaw", 0.0)),
		})
	return snapshot_list

func simulate(dt: float, speed: float) -> Array:
	var out: Array = []

	for pid in players_by_peer.keys():
		var st: Dictionary = players_by_peer[pid]
		var xform: Transform3D = st.get("xform", Transform3D.IDENTITY)
		var target: Vector3 = st.get("target", xform.origin)

		var pos := xform.origin
		var to := target - pos
		var dist := to.length()

		if dist > 0.05:
			var dir := to / dist
			var step = min(speed * dt, dist)
			pos += dir * step
			xform.origin = pos

			var yaw := atan2(dir.x, dir.z)
			st["yaw"] = yaw

		st["xform"] = xform
		players_by_peer[pid] = st

		# keep server node in sync
		var n := players_root.get_node_or_null(str(pid)) if players_root else null
		if n and n is Node3D:
			(n as Node3D).global_transform = xform
			if n.has_method("set_body_yaw"):
				n.call("set_body_yaw", float(st.get("yaw", 0.0)))

		out.append({
			"peer_id": int(pid),
			"xform": xform,
			"yaw": float(st.get("yaw", 0.0)),
		})

	return out

func get_hurtboxes() -> Array:
	var out: Array = []
	for pid in players_by_peer.keys():
		# Optional: don't allow hits on dead players
		if vitals and not vitals.is_alive(int(pid)):
			continue

		var st: Dictionary = players_by_peer[pid]
		out.append({
			"kind": "player",
			"id": int(pid),
			"xform": st.get("xform", Transform3D.IDENTITY),
			"radius": 0.6, # tune later
		})
	return out
