# res://zone/combat/TargetSystem.gd
extends Node
class_name TargetSystem

var log: Callable = func(_m): pass

var target_scene: PackedScene = null
var world_root: Node = null

# target_id -> {hp, xform, radius}
var targets: Dictionary = {}
var target_next_id := 1

func configure(_target_scene: PackedScene, _world_root: Node) -> void:
	target_scene = _target_scene
	world_root = _world_root

func has_targets() -> bool:
	return not targets.is_empty()

func get_targets() -> Dictionary:
	return targets

func spawn_test_targets() -> Array:
	# returns list of spawned {id,xform,hp}
	var spawned: Array = []
	spawned.append(spawn_target_at(Vector3(4, 1, -4), 3))
	spawned.append(spawn_target_at(Vector3(-4, 1, -6), 5))
	return spawned

func spawn_target_at(pos: Vector3, hp: int) -> Dictionary:
	var id := target_next_id
	target_next_id += 1

	var x := Transform3D(Basis.IDENTITY, pos)
	targets[id] = {
		"hp": hp,
		"xform": x,
		"radius": 0.6,
	}

	# Optional: server-side debug node
	if target_scene and world_root:
		var inst := target_scene.instantiate()
		inst.name = "Target_%d" % id
		world_root.add_child(inst)
		if inst is Node3D:
			(inst as Node3D).global_transform = x

	return {"id": id, "xform": x, "hp": hp}

func apply_damage(target_id: int, dmg: int) -> Dictionary:
	# returns {exists, hp, broke}
	if not targets.has(target_id):
		return {"exists": false, "hp": 0, "broke": false}

	var t: Dictionary = targets[target_id]
	var hp := int(t.hp) - dmg
	t.hp = hp
	targets[target_id] = t

	if hp > 0:
		return {"exists": true, "hp": hp, "broke": false}

	# broke
	targets.erase(target_id)

	# remove server node if exists
	var n := world_root.get_node_or_null("Target_%d" % target_id) if world_root else null
	if n:
		n.queue_free()

	return {"exists": false, "hp": 0, "broke": true}

func get_target_snapshot_list() -> Array:
	# for sending to late joiners
	var out: Array = []
	for tid in targets.keys():
		var t: Dictionary = targets[tid]
		out.append({
			"id": int(tid),
			"xform": t.xform,
			"hp": int(t.hp),
		})
	return out
