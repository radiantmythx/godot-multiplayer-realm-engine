# res://zone/combat/MonsterSystem.gd
extends Node
class_name MonsterSystem

var log: Callable = func(_m): pass

var monster_scene: PackedScene = null
var world_root: Node = null

# monster_id -> {hp, xform, radius}
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
	# returns list of spawned {id,xform,hp}
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
	var hp := int(m.get("hp", 0)) - dmg
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
	# for sending to late joiners
	var out: Array = []
	for mid in monsters.keys():
		var m: Dictionary = monsters[mid]
		out.append({
			"id": int(mid),
			"xform": m.xform,
			"hp": int(m.hp),
		})
	return out

func get_hurtboxes() -> Array:
	var out: Array = []
	for mid in monsters.keys(): # or monsters
		var m: Dictionary = monsters[mid]
		out.append({
			"kind": "monster",
			"id": int(mid),
			"xform": m.get("xform", Transform3D.IDENTITY),
			"radius": float(m.get("radius", 0.6)),
		})
	return out
