# res://zone/combat/TargetSystem.gd
extends MonsterSystem
class_name TargetSystem

# Compatibility aliases so existing ZoneServer code keeps working.
# You can delete this file later once you've renamed call sites.

func configure(_target_scene: PackedScene, _world_root: Node) -> void:
	super.configure(_target_scene, _world_root)

func has_targets() -> bool:
	return super.has_monsters()

func get_targets() -> Dictionary:
	return super.get_monsters()

func spawn_test_targets() -> Array:
	return super.spawn_test_monsters()

func spawn_target_at(pos: Vector3, hp: int) -> Dictionary:
	return super.spawn_monster_at(pos, hp)

func apply_damage(target_id: int, dmg: int) -> Dictionary:
	# map MonsterSystem's "died" field back to your old "broke" field
	var r := super.apply_damage(target_id, dmg)
	return {
		"exists": bool(r.get("exists", false)),
		"hp": int(r.get("hp", 0)),
		"broke": bool(r.get("died", false)),
	}

func get_target_snapshot_list() -> Array:
	return super.get_monster_snapshot_list()
