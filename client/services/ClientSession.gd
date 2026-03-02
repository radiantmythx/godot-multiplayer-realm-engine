extends Node
class_name ClientSession

signal token_changed(token: String)
signal realm_auth_changed(is_authed: bool)

var jwt_token: String = ""
var auth_account_id: int = 0
var auth_username: String = ""
var is_realm_authed: bool = false

func set_token(token: String, account_id: int, username: String) -> void:
	jwt_token = token
	auth_account_id = account_id
	auth_username = username
	emit_signal("token_changed", jwt_token)

func clear() -> void:
	jwt_token = ""
	auth_account_id = 0
	auth_username = ""
	set_realm_authed(false)

func set_realm_authed(v: bool) -> void:
	if is_realm_authed == v:
		return
	is_realm_authed = v
	emit_signal("realm_auth_changed", is_realm_authed)

func has_token() -> bool:
	return not jwt_token.is_empty()
