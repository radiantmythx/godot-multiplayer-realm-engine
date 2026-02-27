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
		mode = "realm" # or client if you prefer

	ProcLog.init_from_args(mode) # default file: user://logs/realm.log, client.log, zone.log
	ProcLog.lines(["[APP] engine_args: %s" % str(engine_args)])
	ProcLog.lines(["[APP] user_args:   %s" % str(user_args)])
	ProcLog.lines(["[APP] mode: %s" % mode])

	match mode:
		"realm":
			add_child(realm_server_scene.instantiate())
		"zone":
			add_child(zone_server_scene.instantiate())
		"client":
			add_child(client_scene.instantiate())
		_:
			ProcLog.lines(["[APP] ERROR unknown mode=" + mode])
			get_tree().quit()

func _extract_arg(args: Array, prefix: String) -> String:
	for a in args:
		if typeof(a) == TYPE_STRING and a.begins_with(prefix):
			return a.get_slice("=", 1)
	return ""

func _append_log(path: String, line: String) -> void:
	if path.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f:
		f.seek_end()
		f.store_line(line)
		f.close()
