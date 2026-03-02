extends Node
class_name ClientMaps

signal list_ok(maps: Array)
signal request_failed(reason: String)

var log: Callable = func(_m): pass
var api_base: String = "http://localhost:5131"

var http: HTTPRequest
var _pending_kind: String = "" # "list"

func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

# If you keep [Authorize] on MapsController, token is required.
# If you make it [AllowAnonymous], you can pass "" and it will still work.
func list_maps(token: String, playable: bool = true, hidden: bool = false) -> void:
	_pending_kind = "list"
	var url := api_base + "/api/maps?playable=%s&hidden=%s" % [str(playable).to_lower(), str(hidden).to_lower()]
	_request_json(url, HTTPClient.METHOD_GET, token, null)

func _request_json(url: String, method: int, token: String, body_dict: Variant) -> void:
	var headers: Array[String] = [
		"Content-Type: application/json",
		"Accept: application/json",
	]
	if token != "":
		headers.append("Authorization: Bearer " + token)

	var body := ""
	if body_dict != null:
		body = JSON.stringify(body_dict)

	log.call("[CLIENT] Maps " + _pending_kind.to_upper() + " " + url)
	var err := http.request(url, headers, method, body)
	if err != OK:
		emit_signal("request_failed", "http_request_failed_" + str(err))

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()

	var parsed = JSON.parse_string(text)
	var dict = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	if response_code < 200 or response_code >= 300:
		var err_msg := str(dict.get("error", "http_" + str(response_code)))
		log.call("[CLIENT] Maps failed kind=" + _pending_kind + " http=" + str(response_code) + " err=" + err_msg)
		emit_signal("request_failed", err_msg)
		return

	match _pending_kind:
		"list":
			var maps: Array = []
			if typeof(dict) == TYPE_DICTIONARY:
				maps = dict.get("maps", [])
			emit_signal("list_ok", maps)
		_:
			emit_signal("request_failed", "unknown_pending_kind_" + str(_pending_kind))
