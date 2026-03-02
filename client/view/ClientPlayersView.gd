# res://client/view/ClientPlayersView.gd
extends Node
class_name ClientPlayersView

var log: Callable = func(_m): pass

var player_scene: PackedScene = null
var puppets: Dictionary = {} # peer_id(str) -> Node3D

var local_peer_id: int = 0
var local_player: Node3D = null
var local_camera: Camera3D = null

func configure(_player_scene: PackedScene) -> void:
	player_scene = _player_scene

func clear() -> void:
	# free any remaining puppet nodes we own references to
	for k in puppets.keys():
		var n: Node3D = puppets[k]
		if n and is_instance_valid(n):
			n.queue_free()
	puppets.clear()
	local_player = null
	local_camera = null

func set_local_peer_id(id: int) -> void:
	local_peer_id = id

func get_local_camera() -> Camera3D:
	return local_camera

func get_local_player() -> Node3D:
	return local_player

func spawn_players_bulk(owner: Node, world: ClientWorld, list: Array) -> void:
	log.call("[CLIENT] bulk spawn count=" + str(list.size()))
	for d in list:
		var pid := int(d.get("peer_id", 0))
		var cid := int(d.get("character_id", 0))
		var xform: Transform3D = d.get("xform", Transform3D.IDENTITY)
		var yaw: float = float(d.get("yaw", 0.0))
		var pname := str(d.get("name", ""))
		_spawn_or_update(owner, world, pid, cid, pname, xform, yaw)

func spawn_player(owner: Node, world: ClientWorld, peer_id: int, character_id: int, name: String, xform: Transform3D) -> void:
	_spawn_or_update(owner, world, peer_id, character_id, name, xform, 0.0)

func despawn_player(owner: Node, world: ClientWorld, peer_id: int) -> void:
	var key := str(peer_id)
	if puppets.has(key):
		var n: Node3D = puppets[key]
		if n and is_instance_valid(n):
			n.queue_free()
		puppets.erase(key)

	# also remove from scene if present
	var players := world.get_players_root(owner)
	if players:
		var existing := players.get_node_or_null(key)
		if existing:
			existing.queue_free()

func apply_snapshots(snaps: Array) -> void:
	for d in snaps:
		var pid := int(d.get("peer_id", 0))
		var xform: Transform3D = d.get("xform", Transform3D.IDENTITY)
		var yaw: float = float(d.get("yaw", 0.0))
		_apply_state(pid, xform, yaw)

func try_activate_local_camera(owner: Node, world: ClientWorld) -> void:
	if local_peer_id <= 0:
		return

	var key := str(local_peer_id)

	# Prefer our puppet cache
	if puppets.has(key) and is_instance_valid(puppets[key]):
		_force_camera_current(puppets[key])
		return

	# Or look it up in the scene
	var players := world.get_players_root(owner)
	if players:
		var n := players.get_node_or_null(key)
		if n:
			_force_camera_current(n)

# --- internals ---

func _spawn_or_update(owner: Node, world: ClientWorld, peer_id: int, character_id: int, name: String, xform: Transform3D, yaw: float) -> void:
	var players := world.get_players_root(owner)
	if players == null:
		push_error("[CLIENT] World/Players missing; can't spawn")
		return
	if player_scene == null:
		push_error("[CLIENT] player_scene not assigned on ClientMain!")
		return

	var key := str(peer_id)
	var n: Node3D = null
	var created := false

	if puppets.has(key) and is_instance_valid(puppets[key]):
		n = puppets[key]
	else:
		var inst := player_scene.instantiate()
		inst.name = key
		players.add_child(inst)
		n = inst as Node3D
		puppets[key] = n
		created = true

	var is_local := (peer_id == local_peer_id)
	log.call("[CLIENT] spawn/update pid=%s local=%s created=%s" % [str(peer_id), str(is_local), str(created)])

	if is_local and n:
		_force_camera_current(n)

	if n:
		n.global_transform = xform
		if n.has_method("set_body_yaw"):
			n.call("set_body_yaw", yaw)
		if _inst_has_method(n, "server_init") and character_id != 0:
			n.call("server_init", character_id)
		if not name.is_empty() and n.has_method("set_player_name"):
			n.call("set_player_name", name)

func _apply_state(peer_id: int, xform: Transform3D, yaw: float) -> void:
	var key := str(peer_id)
	if puppets.has(key):
		var n: Node3D = puppets[key]
		if n and is_instance_valid(n):
			n.global_position = xform.origin
			if n.has_method("set_body_yaw"):
				n.call("set_body_yaw", yaw)

func _inst_has_method(obj: Object, m: String) -> bool:
	return obj != null and obj.has_method(m)

func _force_camera_current(player_root: Node) -> void:
	var cam := player_root.find_child("Camera3D", true, false)
	if cam and cam is Camera3D:
		local_player = player_root as Node3D
		local_camera = cam as Camera3D
		local_camera.current = true
		log.call("[CLIENT] Set local camera current: " + str(local_camera.get_path()))
	else:
		log.call("[CLIENT] WARNING: no Camera3D found under local player: " + str(player_root.get_path()))
