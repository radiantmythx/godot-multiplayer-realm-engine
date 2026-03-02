extends Node
class_name ClientCharacters

signal list_ok(characters: Array)
signal create_ok(character: Dictionary)
signal delete_ok(character_id: int)
signal request_failed(reason: String)

var log: Callable = func(_m): pass

var _cm: Node = null
var _pending_kind: String = "" # "list" | "create" | "delete"
var _pending_delete_id: int = 0

func _ready() -> void:
	_cm = get_tree().get_first_node_in_group("client_main")
	if _cm and _cm.has_signal("lobby_response"):
		_cm.connect("lobby_response", Callable(self, "_on_lobby_response"))

func list_characters(_token_ignored: String) -> void:
	if _cm == null:
		emit_signal("request_failed", "no_client_main")
		return
	if not _cm.has_method("lobby_request"):
		emit_signal("request_failed", "client_main_missing_lobby_request")
		return

	_pending_kind = "list"
	log.call("[CLIENT] Characters LIST via Realm RPC")
	_cm.call("lobby_request", "chars_list", {})

func create_character(_token_ignored: String, name: String, class_id: String = "templar") -> void:
	if _cm == null:
		emit_signal("request_failed", "no_client_main")
		return
	if not _cm.has_method("lobby_request"):
		emit_signal("request_failed", "client_main_missing_lobby_request")
		return

	_pending_kind = "create"
	log.call("[CLIENT] Characters CREATE via Realm RPC")
	_cm.call("lobby_request", "char_create", {
		"name": name.strip_edges(),
		"class_id": class_id.strip_edges()
	})

func delete_character(_token_ignored: String, character_id: int) -> void:
	if _cm == null:
		emit_signal("request_failed", "no_client_main")
		return
	if not _cm.has_method("lobby_request"):
		emit_signal("request_failed", "client_main_missing_lobby_request")
		return

	_pending_kind = "delete"
	_pending_delete_id = character_id
	log.call("[CLIENT] Characters DELETE via Realm RPC")
	_cm.call("lobby_request", "char_delete", { "id": character_id })

func _on_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	# Route only character-related responses
	if kind != "chars_list" and kind != "char_create" and kind != "char_delete":
		return

	if not ok:
		var err := str(payload.get("error", "unknown_error"))
		log.call("[CLIENT] Characters failed kind=%s err=%s" % [kind, err])
		emit_signal("request_failed", err)
		_pending_kind = ""
		return

	match kind:
		"chars_list":
			var chars: Array = payload.get("characters", [])
			emit_signal("list_ok", chars)
			_pending_kind = ""

		"char_create":
			# API returns created character dict
			emit_signal("create_ok", payload)
			_pending_kind = ""

		"char_delete":
			emit_signal("delete_ok", _pending_delete_id)
			_pending_kind = ""

		_:
			emit_signal("request_failed", "unknown_kind_" + str(kind))
			_pending_kind = ""
