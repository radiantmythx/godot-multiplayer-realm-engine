extends Node
class_name ClientMaps

signal list_ok(maps: Array)
signal request_failed(reason: String)

var log: Callable = func(_m): pass

var _cm: Node = null
var _waiting := false

func _ready() -> void:
	_cm = get_tree().get_first_node_in_group("client_main")
	if _cm and _cm.has_signal("lobby_response"):
		_cm.connect("lobby_response", Callable(self, "_on_lobby_response"))

func list_maps(_token_ignored: String, playable: bool = true, hidden: bool = false) -> void:
	if _cm == null:
		emit_signal("request_failed", "no_client_main")
		return
	if not _cm.has_method("lobby_request"):
		emit_signal("request_failed", "client_main_missing_lobby_request")
		return

	_waiting = true
	_cm.call("lobby_request", "maps_list", {
		"playable": playable,
		"hidden": hidden
	})

func _on_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	if kind != "maps_list":
		return
	if not _waiting:
		return
	_waiting = false

	if not ok:
		emit_signal("request_failed", str(payload.get("error", "unknown_error")))
		return

	var maps: Array = payload.get("maps", [])
	emit_signal("list_ok", maps)
