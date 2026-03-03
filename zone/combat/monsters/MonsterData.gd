# res://zone/combat/MonsterData.gd
extends Resource
class_name MonsterData

@export var type_id: String = ""            # e.g. "slime_blue"
@export var display_name: String = ""       # e.g. "Blue Slime"

@export var max_hp: int = 5

# Optional: helpful for client visuals (you can ignore for now)
@export var tint: Color = Color.WHITE

# AI defaults (data-driven later)
@export var aggro_radius: float = 10.0
@export var move_speed: float = 3.5
@export var melee_range: float = 1.5
@export var melee_cooldown: float = 1.0
@export var melee_damage: int = 1
