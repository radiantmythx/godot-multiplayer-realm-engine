# res://client/world/ClientWorld.gd
extends Node
class_name ClientWorld

var log: Callable = func(_m): pass

var world_root: Node = null

func clear_world(owner: Node) -> void:
	if world_root and is_instance_valid(world_root):
		world_root.queue_free()
	world_root = null

	# also remove any lingering node named "World"
	var existing := owner.get_node_or_null("World")
	if existing and is_instance_valid(existing):
		existing.queue_free()

func load_world(owner: Node, map_path: String) -> void:
	clear_world(owner)

	var ps := load(map_path)
	if ps == null or not (ps is PackedScene):
		push_error("[CLIENT] Failed to load map: " + map_path)
		return

	world_root = (ps as PackedScene).instantiate()
	world_root.name = "World"
	owner.add_child(world_root)

	log.call("[CLIENT] World loaded: " + map_path)

func get_players_root(owner: Node) -> Node:
	# Prefer cached world_root, but also allow lookup
	var w := world_root
	if w == null or not is_instance_valid(w):
		w = owner.get_node_or_null("World")

	if w == null:
		return null

	var players := (w as Node).get_node_or_null("Players")
	if players == null:
		# keep behavior consistent with your current code (error elsewhere)
		return null
	return players

func get_world_node(owner: Node) -> Node:
	if world_root and is_instance_valid(world_root):
		return world_root
	return owner.get_node_or_null("World")
