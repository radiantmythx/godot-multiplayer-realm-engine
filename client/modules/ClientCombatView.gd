# res://client/view/ClientCombatView.gd
extends Node
class_name ClientCombatView

var log: Callable = func(_m): pass

var projectile_scene: PackedScene = null
var target_scene: PackedScene = null

var projectile_nodes: Dictionary = {} # proj_id(str) -> Node3D
var target_nodes: Dictionary = {}     # target_id(str) -> Node3D

func configure(_projectile_scene: PackedScene, _target_scene: PackedScene) -> void:
	projectile_scene = _projectile_scene
	target_scene = _target_scene

func clear() -> void:
	for k in projectile_nodes.keys():
		var n: Node3D = projectile_nodes[k]
		if n and is_instance_valid(n):
			n.queue_free()
	projectile_nodes.clear()

	for k2 in target_nodes.keys():
		var t: Node3D = target_nodes[k2]
		if t and is_instance_valid(t):
			t.queue_free()
	target_nodes.clear()

func spawn_projectile(owner: Node, world: ClientWorld, proj_id: int, xform: Transform3D) -> void:
	if projectile_scene == null:
		push_error("[CLIENT] projectile_scene not assigned!")
		return

	var w := world.get_world_node(owner)
	if w == null:
		push_error("[CLIENT] World missing when spawning projectile")
		return

	var key := str(proj_id)
	if projectile_nodes.has(key) and is_instance_valid(projectile_nodes[key]):
		return

	var inst := projectile_scene.instantiate()
	inst.name = "Proj_%s" % key
	w.add_child(inst)
	if inst is Node3D:
		(inst as Node3D).global_transform = xform
	projectile_nodes[key] = inst as Node3D

func projectile_snapshots(snaps: Array) -> void:
	for d in snaps:
		var id := str(int(d.get("id", 0)))
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		if projectile_nodes.has(id) and is_instance_valid(projectile_nodes[id]):
			projectile_nodes[id].global_position = pos

func despawn_projectile(proj_id: int) -> void:
	var key := str(proj_id)
	if projectile_nodes.has(key):
		var n: Node3D = projectile_nodes[key]
		if n and is_instance_valid(n):
			n.queue_free()
		projectile_nodes.erase(key)

func spawn_target(owner: Node, world: ClientWorld, target_id: int, xform: Transform3D) -> void:
	if target_scene == null:
		push_error("[CLIENT] target_scene not assigned!")
		return

	var w := world.get_world_node(owner)
	if w == null:
		push_error("[CLIENT] World missing when spawning target")
		return

	var key := str(target_id)
	if target_nodes.has(key) and is_instance_valid(target_nodes[key]):
		return

	var inst := target_scene.instantiate()
	inst.name = "Target_%s" % key
	w.add_child(inst)
	if inst is Node3D:
		(inst as Node3D).global_transform = xform
	target_nodes[key] = inst as Node3D

func break_target(target_id: int) -> void:
	var key := str(target_id)
	if target_nodes.has(key):
		var n: Node3D = target_nodes[key]
		if n and is_instance_valid(n):
			n.queue_free()
		target_nodes.erase(key)

func target_snapshots(snaps: Array) -> void:
	for d in snaps:
		var id := str(int(d.get("id", 0)))
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		if target_nodes.has(id) and is_instance_valid(target_nodes[id]):
			target_nodes[id].global_position = pos
