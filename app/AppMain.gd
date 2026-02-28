# res://app/AppMain.gd
extends Node

@export var realm_server_scene: PackedScene
@export var zone_server_scene: PackedScene
@export var client_scene: PackedScene

func _ready() -> void:
	var engine_args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()

	var mode := _extract_arg(user_args, "--mode=")
	if mode.is_empty():
		mode = _extract_arg(engine_args, "--mode=")
	if mode.is_empty():
		mode = "client"

	ProcLog.init_from_args(mode)
	ProcLog.lines(["[APP] engine_args: %s" % str(engine_args)])
	ProcLog.lines(["[APP] user_args:   %s" % str(user_args)])
	ProcLog.lines(["[APP] mode: %s" % mode])

	match mode:
		"realm":
			_spawn_as_net(realm_server_scene)
		"zone":
			_spawn_as_net(zone_server_scene)
		"client":
			_spawn_as_net(client_scene) # this should be LoginScreen OR ClientMain depending on your flow
		_:
			ProcLog.lines(["[APP] ERROR unknown mode=" + mode])
			get_tree().quit()

func _spawn_as_net(scene: PackedScene) -> void:
	var n := scene.instantiate()
	n.name = "Net"  # <-- CRITICAL: makes the RPC node path /root/Net
	add_child(n)

func _extract_arg(args: Array, prefix: String) -> String:
	for a in args:
		if typeof(a) == TYPE_STRING and a.begins_with(prefix):
			return a.get_slice("=", 1)
	return ""
