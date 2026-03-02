extends Node
class_name ClientAuth

signal auth_ok(token: String, account_id: int, username: String)
signal auth_failed(reason: String)

var log: Callable = func(_m): pass
var api_base: String = "http://localhost:5131"

var http: HTTPRequest
var _pending_kind: String = "" # "login" or "register"

func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

func login(username_or_email: String, password: String) -> void:
	_pending_kind = "login"
	var url := api_base + "/api/auth/login"
	_post_json(url, {
		"usernameOrEmail": username_or_email,
		"password": password
	})

func register(username: String, email: String, password: String) -> void:
	_pending_kind = "register"
	var url := api_base + "/api/auth/register"
	_post_json(url, {
		"username": username,
		"email": email,
		"password": password
	})

func _post_json(url: String, body_dict: Dictionary) -> void:
	var headers := ["Content-Type: application/json"]
	var body := JSON.stringify(body_dict)

	log.call("[CLIENT] Auth POST " + url)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		emit_signal("auth_failed", "http_request_failed_" + str(err))

func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var text := body.get_string_from_utf8()

	# Try to parse JSON either way (errors come back as json)
	var parsed = JSON.parse_string(text)
	var dict = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	if response_code < 200 or response_code >= 300:
		var err_msg := str(dict.get("error", "http_" + str(response_code)))
		log.call("[CLIENT] Auth failed kind=" + _pending_kind + " http=" + str(response_code) + " err=" + err_msg)
		emit_signal("auth_failed", err_msg)
		return

	var token := str(dict.get("token", ""))
	if token == "":
		emit_signal("auth_failed", "missing_token")
		return

	var account_id := int(dict.get("accountId", 0))
	var username := str(dict.get("username", ""))

	emit_signal("auth_ok", token, account_id, username)
