# res://player/Player.gd
extends Node3D

var character_id: int

@onready var cam: Camera3D = $CameraRig/Camera3D
@onready var body: Node3D = $Player
@onready var name_label: Label3D = $Player/NameLabel
@onready var health_bar: HealthBar3D = $Player/HealthBar

var max_hp: int = 10
var hp: int = 10

func server_init(cid: int) -> void:
	character_id = cid

func set_body_yaw(yaw: float) -> void:
	if body:
		body.rotation.y = yaw

func set_player_name(n: String) -> void:
	if name_label:
		name_label.text = n

func set_hp(new_hp: int, new_max_hp: int = -1) -> void:
	hp = max(new_hp, 0)
	if new_max_hp > 0:
		max_hp = new_max_hp
	if health_bar:
		health_bar.set_hp(hp, max_hp)
