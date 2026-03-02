extends Node
class_name RealmSessions

# peer_id -> { account_id:int, username:String, exp:int, jwt:String }
var auth_sessions: Dictionary = {}

var jwt_secret: String = ""

func set_jwt_secret(secret: String) -> void:
	jwt_secret = secret

func remove_peer(peer_id: int) -> void:
	auth_sessions.erase(peer_id)

func is_authed(peer_id: int) -> bool:
	return auth_sessions.has(peer_id)

func get_jwt(peer_id: int) -> String:
	if not auth_sessions.has(peer_id):
		return ""
	return str(auth_sessions[peer_id].get("jwt", ""))

func get_account_id(peer_id: int) -> int:
	if not auth_sessions.has(peer_id):
		return 0
	return int(auth_sessions[peer_id].get("account_id", 0))

func get_username(peer_id: int) -> String:
	if not auth_sessions.has(peer_id):
		return ""
	return str(auth_sessions[peer_id].get("username", ""))

# Returns: { ok:bool, reason:String, account_id:int, username:String, exp:int, claims:Dictionary }
func verify_jwt(jwt: String) -> Dictionary:
	if jwt_secret == "":
		return { "ok": false, "reason": "missing_jwt_secret" }

	var result := JwtHs256.verify_and_decode(jwt, jwt_secret)
	if result.ok == false:
		return { "ok": false, "reason": str(result.reason) }

	var claims: Dictionary = result.claims
	var account_id := int(claims.get("uid", 0))
	var uname := str(claims.get("uname", ""))
	var exp := int(claims.get("exp", 0))

	if account_id <= 0 or uname == "":
		return { "ok": false, "reason": "invalid_claims", "claims": claims }

	return {
		"ok": true,
		"reason": "",
		"account_id": account_id,
		"username": uname,
		"exp": exp,
		"claims": claims
	}

func accept_peer(peer_id: int, jwt: String, claims_info: Dictionary) -> void:
	auth_sessions[peer_id] = {
		"account_id": int(claims_info.get("account_id", 0)),
		"username": str(claims_info.get("username", "")),
		"exp": int(claims_info.get("exp", 0)),
		"jwt": jwt
	}
