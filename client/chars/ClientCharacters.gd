extends Node
class_name ClientCharacters

signal list_ok(characters: Array)
signal create_ok(character: Dictionary)
signal delete_ok(character_id: int)
signal request_failed(reason: String)

var log: Callable = func(_m): pass
var api_base: String = "http://localhost:5131"

var http: HTTPRequest
var _pending_kind: String = "" # "list" | "create" | "delete"
var _pending_delete_id: int = 0

func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

func list_characters(token: String) -> void:
	_pending_kind = "list"
	var url := api_base + "/api/characters"
	_request_json(url, HTTPClient.METHOD_GET, token, null)

func create_character(token: String, name: String, class_id: String = "templar") -> void:
	_pending_kind = "create"
	var url := api_base + "/api/characters"

	_request_json(url, HTTPClient.METHOD_POST, token, {
		"Name": name.strip_edges(),
		"ClassId": class_id.strip_edges()
	})

func delete_character(token: String, character_id: int) -> void:
	_pending_kind = "delete"
	_pending_delete_id = character_id
	var url := api_base + "/api/characters/%d" % character_id
	_request_json(url, HTTPClient.METHOD_DELETE, token, null)

func _request_json(url: String, method: int, token: String, body_dict: Variant) -> void:
	var headers: Array[String] = [
		"Content-Type: application/json",
		"Accept: application/json",
		"Authorization: Bearer " + token
	]

	var body := ""
	if body_dict != null:
		body = JSON.stringify(body_dict)

	log.call("[CLIENT] Characters " + _pending_kind.to_upper() + " " + url)
	var err := http.request(url, headers, method, body)
	if err != OK:
		emit_signal("request_failed", "http_request_failed_" + str(err))

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()

	# Try to parse JSON either way (errors come back as json)
	var parsed = JSON.parse_string(text)
	var dict = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	if response_code < 200 or response_code >= 300:
		var err_msg := str(dict.get("error", "http_" + str(response_code)))
		log.call("[CLIENT] Characters failed kind=" + _pending_kind + " http=" + str(response_code) + " err=" + err_msg)
		emit_signal("request_failed", err_msg)
		return

	match _pending_kind:
		"list":
			var chars: Array = []
			if typeof(dict) == TYPE_DICTIONARY:
				chars = dict.get("characters", [])
			emit_signal("list_ok", chars)

		"create":
			# Your controller returns the created character object (dict)
			emit_signal("create_ok", dict)

		"delete":
			emit_signal("delete_ok", _pending_delete_id)

		_:
			# Unknown state, still treat as error-ish
			emit_signal("request_failed", "unknown_pending_kind_" + str(_pending_kind))
