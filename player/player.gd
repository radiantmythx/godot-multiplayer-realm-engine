# res://player/Player.gd
extends Node3D

var character_id: int
@onready var cam: Camera3D = $CameraRig/Camera3D # adjust path
@onready var body: Node3D = $Player  # adjust if your path differs

@onready var name_label: Label3D = $Player/NameLabel

func server_init(cid: int) -> void:
	character_id = cid

func set_body_yaw(yaw: float) -> void:
	if body:
		body.rotation.y = yaw

func set_player_name(n: String) -> void:
	if name_label:
		name_label.text = n
