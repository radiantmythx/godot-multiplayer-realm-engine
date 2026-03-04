extends Node
class_name ApiGateway

signal response(peer_id: int, kind: String, ok: bool, payload: Dictionary)

var api_base: String = "http://127.0.0.1:5131"

var http: HTTPRequest

var _http_busy: bool = false
var _http_queue: Array = []        # { peer_id, kind, url, method, body, headers:Array[String] }
var _http_active: Dictionary = {}  # { peer_id, kind }

func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

func set_api_base(base_url: String) -> void:
	api_base = base_url

func remove_peer(peer_id: int) -> void:
	_http_queue = _http_queue.filter(func(j):
		return int(j.get("peer_id", 0)) != int(peer_id)
	)
	if not _http_active.is_empty() and int(_http_active.get("peer_id", 0)) == int(peer_id):
		_http_active.clear()

func _bearer(jwt: String) -> Array[String]:
	return [
		"Accept: application/json",
		"Authorization: Bearer " + jwt
	]

# ---- existing endpoints ----

func auth_login(peer_id: int, username_or_email: String, password: String) -> void:
	var url := "%s/api/auth/login" % api_base
	var body := JSON.stringify({
		"usernameOrEmail": username_or_email.strip_edges(),
		"password": password
	})
	enqueue(peer_id, "auth_login", url, HTTPClient.METHOD_POST, body,
		["Content-Type: application/json", "Accept: application/json"])

func auth_register(peer_id: int, username: String, email: String, password: String) -> void:
	var url := "%s/api/auth/register" % api_base
	var body := JSON.stringify({
		"username": username.strip_edges(),
		"email": email.strip_edges(),
		"password": password
	})
	enqueue(peer_id, "auth_register", url, HTTPClient.METHOD_POST, body,
		["Content-Type: application/json", "Accept: application/json"])

func maps_list(peer_id: int, playable: bool, hidden: bool) -> void:
	var url := "%s/api/maps?playable=%s&hidden=%s" % [
		api_base,
		str(playable).to_lower(),
		str(hidden).to_lower()
	]
	enqueue(peer_id, "maps_list", url, HTTPClient.METHOD_GET, "", ["Accept: application/json"])

# NEW: convenient "list everything" for Realm internal lookup
func maps_list_all(peer_id: int) -> void:
	# playable=true, hidden=true -> returns everything in most APIs
	var url := "%s/api/maps?playable=true&hidden=true" % api_base
	enqueue(peer_id, "maps_list_all", url, HTTPClient.METHOD_GET, "", ["Accept: application/json"])

# NEW: GET /api/maps/{id}/spawns
func map_spawns(peer_id: int, map_id: int) -> void:
	var url := "%s/api/maps/%d/spawns" % [api_base, int(map_id)]
	enqueue(peer_id, "map_spawns", url, HTTPClient.METHOD_GET, "", ["Accept: application/json"])

func chars_list(peer_id: int, jwt: String) -> void:
	var url := "%s/api/characters" % api_base
	enqueue(peer_id, "chars_list", url, HTTPClient.METHOD_GET, "", _bearer(jwt))

func char_create(peer_id: int, jwt: String, name: String, class_id: String) -> void:
	var url := "%s/api/characters" % api_base
	var body := JSON.stringify({
		"Name": name.strip_edges(),
		"ClassId": class_id.strip_edges()
	})

	var headers: Array[String] = _bearer(jwt)
	headers.append("Content-Type: application/json; charset=utf-8")

	enqueue(peer_id, "char_create", url, HTTPClient.METHOD_POST, body, headers)

func char_delete(peer_id: int, jwt: String, id: int) -> void:
	var url := "%s/api/characters/%d" % [api_base, id]
	enqueue(peer_id, "char_delete", url, HTTPClient.METHOD_DELETE, "", _bearer(jwt))

# ---- queue plumbing ----

func enqueue(peer_id: int, kind: String, url: String, method: int, body: String, headers: Array[String]) -> void:
	if http == null:
		emit_signal("response", peer_id, kind, false, {"error":"http_not_ready"})
		return

	_http_queue.append({
		"peer_id": peer_id,
		"kind": kind,
		"url": url,
		"method": method,
		"body": body,
		"headers": headers
	})
	_pump()

func _pump() -> void:
	if _http_busy:
		return
	if _http_queue.is_empty():
		return

	var job: Dictionary = _http_queue.pop_front()

	_http_busy = true
	_http_active = {
		"peer_id": int(job.get("peer_id", 0)),
		"kind": str(job.get("kind", "")),
	}

	var url := str(job.get("url", ""))
	var method := int(job.get("method", HTTPClient.METHOD_GET))
	var body := str(job.get("body", ""))
	var headers: Array[String] = job.get("headers", [])

	ProcLog.lines(["[REALM] API ", _http_active.kind, " ", url, " (queued=", _http_queue.size(), ")"])

	var err := http.request(url, headers, method, body)
	if err != OK:
		var pid := int(_http_active.peer_id)
		var k := str(_http_active.kind)
		_http_busy = false
		_http_active.clear()
		emit_signal("response", pid, k, false, {"error":"http_request_failed_" + str(err)})
		_pump()

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _http_active.is_empty():
		_http_busy = false
		_pump()
		return

	var peer_id := int(_http_active.get("peer_id", 0))
	var kind := str(_http_active.get("kind", ""))

	_http_busy = false
	_http_active.clear()

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	var dict: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	if response_code < 200 or response_code >= 300:
		var err_msg := str(dict.get("error", "http_" + str(response_code)))
		emit_signal("response", peer_id, kind, false, {"error": err_msg})
	else:
		emit_signal("response", peer_id, kind, true, dict)

	_pump()
