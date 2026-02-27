# res://zone/ZoneWorld.gd
extends Node
class_name ZoneWorld

var log: Callable = func(_m): pass

var world_root: Node = null
var players_root: Node = null
var spawn_points: Array[Node3D] = []
var spawn_rr_index := 0

func reset() -> void:
	if world_root and is_instance_valid(world_root):
		world_root.queue_free()
	world_root = null
	players_root = null
	spawn_points.clear()
	spawn_rr_index = 0

func load_map_scene(owner: Node, path: String, _seed: int) -> void:
	reset()

	if path.is_empty():
		log.call("[ZONE] ERROR map_id empty, cannot load.")
		return

	var ps := load(path)
	if ps == null or not (ps is PackedScene):
		log.call("[ZONE] ERROR failed to load map PackedScene: " + path)
		return

	world_root = (ps as PackedScene).instantiate()
	world_root.name = "World"
	owner.add_child(world_root)

	players_root = world_root.get_node_or_null("Players")
	if players_root == null:
		players_root = Node.new()
		players_root.name = "Players"
		world_root.add_child(players_root)

	var sp_container := world_root.get_node_or_null("SpawnPoints")
	if sp_container:
		for c in sp_container.get_children():
			if c is Node3D:
				spawn_points.append(c)

	if spawn_points.is_empty():
		_collect_spawn_markers(world_root)

	log.call("[ZONE] Loaded map: %s | spawn_points=%d" % [path, spawn_points.size()])

func _collect_spawn_markers(root: Node) -> void:
	for c in root.get_children():
		if c is Marker3D:
			var n := (c as Node).name
			if n == "Spawn" or n.begins_with("Spawn_"):
				spawn_points.append(c)
		if c.get_child_count() > 0:
			_collect_spawn_markers(c)

func get_next_spawn_transform() -> Transform3D:
	if spawn_points.size() > 0:
		var sp := spawn_points[spawn_rr_index % spawn_points.size()]
		spawn_rr_index += 1
		return sp.global_transform
	return Transform3D.IDENTITY
