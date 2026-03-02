# res://player/HealthBar3D.gd
extends Node3D
class_name HealthBar3D

@export var max_hp: int = 10

@onready var viewport: SubViewport = $SubViewport
@onready var bar: ProgressBar = $SubViewport/CanvasLayer/Bar

var _hp: int = 10

func _ready() -> void:
	if bar:
		bar.min_value = 0
		bar.max_value = max_hp
		bar.value = _hp

func set_hp(hp: int, new_max: int = -1) -> void:
	_hp = max(hp, 0)
	if new_max > 0:
		max_hp = new_max
	if bar:
		bar.max_value = max_hp
		bar.value = _hp

	# optional: hide at full hp
	visible = (_hp < max_hp)

func set_visible_for_local(is_local: bool) -> void:
	# optional: maybe you want local always visible
	pass
