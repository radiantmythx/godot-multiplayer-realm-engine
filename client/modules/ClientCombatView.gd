# res://client/view/ClientCombatView.gd
extends Node
class_name ClientCombatView

var log: Callable = func(_m): pass

var projectile_scene: PackedScene = null

# Monster visuals
var default_monster_scene: PackedScene = null
var monster_scene_by_type: Dictionary = {} # type_id(String) -> PackedScene

var projectile_nodes: Dictionary = {} # proj_id(str) -> Node3D
var monster_nodes: Dictionary = {}    # monster_id(str) -> Node3D

func configure(_projectile_scene: PackedScene, _default_monster_scene: PackedScene, _monster_scene_by_type: Dictionary) -> void:
	projectile_scene = _projectile_scene
	default_monster_scene = _default_monster_scene
	monster_scene_by_type = _monster_scene_by_type if _monster_scene_by_type != null else {}

func clear() -> void:
	for k in projectile_nodes.keys():
		var n: Node3D = projectile_nodes[k]
		if n and is_instance_valid(n):
			n.queue_free()
	projectile_nodes.clear()

	for k2 in monster_nodes.keys():
		var t: Node3D = monster_nodes[k2]
		if t and is_instance_valid(t):
			t.queue_free()
	monster_nodes.clear()

# ---------------- Projectiles ----------------

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

# ---------------- Monsters ----------------

func _scene_for_type(type_id: String) -> PackedScene:
	if monster_scene_by_type.has(type_id):
		return monster_scene_by_type[type_id]
	return default_monster_scene

func spawn_monster(owner: Node, world: ClientWorld, monster_id: int, type_id: String, name: String, xform: Transform3D, hp: int, max_hp: int) -> void:
	var scene := _scene_for_type(type_id)
	if scene == null:
		push_error("[CLIENT] No monster scene assigned (default or type)!")
		return

	var w := world.get_world_node(owner)
	if w == null:
		push_error("[CLIENT] World missing when spawning monster")
		return

	var key := str(monster_id)
	if monster_nodes.has(key) and is_instance_valid(monster_nodes[key]):
		# already exists; update it
		var existing: Node3D = monster_nodes[key]
		existing.global_transform = xform
		_apply_monster_meta(existing, type_id, name, hp, max_hp)
		return

	var inst := scene.instantiate()
	inst.name = "Monster_%s" % key
	w.add_child(inst)
	if inst is Node3D:
		(inst as Node3D).global_transform = xform

	monster_nodes[key] = inst as Node3D
	_apply_monster_meta(inst, type_id, name, hp, max_hp)
	
	

func _apply_monster_meta(inst: Node, type_id: String, name: String, hp: int, max_hp: int) -> void:
	# Optional hooks if your monster scenes implement them
	if inst.has_method("set_monster_type"):
		inst.call("set_monster_type", type_id)
	if inst.has_method("set_display_name"):
		inst.call("set_display_name", name)
	elif inst.has_method("set_player_name"):
		# fallback for Label3D rename reuse
		inst.call("set_player_name", name)

	if inst.has_method("set_hp"):
		inst.call("set_hp", hp, max_hp)

func monster_snapshots(snaps: Array) -> void:
	# snaps: [{id:int, pos:Vector3}]
	for d in snaps:
		var id := str(int(d.get("id", 0)))
		var pos: Vector3 = d.get("pos", Vector3.ZERO)
		if monster_nodes.has(id) and is_instance_valid(monster_nodes[id]):
			monster_nodes[id].global_position = pos

func monster_hp(monster_id: int, hp: int, max_hp: int) -> void:
	var key := str(monster_id)
	if monster_nodes.has(key) and is_instance_valid(monster_nodes[key]):
		var n: Node3D = monster_nodes[key]
		if n.has_method("set_hp"):
			n.call("set_hp", hp, max_hp)

func break_monster(monster_id: int) -> void:
	var key := str(monster_id)
	if monster_nodes.has(key):
		var n: Node3D = monster_nodes[key]
		if n and is_instance_valid(n):
			n.queue_free()
		monster_nodes.erase(key)
