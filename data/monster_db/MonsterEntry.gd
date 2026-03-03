extends Resource
class_name MonsterEntry

@export var type_id: String = ""
@export var data: MonsterData
@export var scene: PackedScene  # client visual prefab (can be null early in dev)
