# res://shared/Ticket.gd
extends RefCounted
class_name Ticket

static func _hmac_sha256(secret: String, data: PackedByteArray) -> PackedByteArray:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, secret.to_utf8_buffer())
	h.update(data)
	return h.finish()

static func issue(secret: String, payload: Dictionary) -> String:
	# payload should include: instance_id, character_id, session_id, iat, exp, nonce
	var json := JSON.stringify(payload)
	var json_bytes := json.to_utf8_buffer()
	var sig := _hmac_sha256(secret, json_bytes)
	return Marshalls.raw_to_base64(json_bytes) + "." + Marshalls.raw_to_base64(sig)

static func verify(secret: String, token: String) -> Dictionary:
	var parts := token.split(".")
	if parts.size() != 2:
		return {"ok": false, "error": "bad_format"}

	var json_bytes := Marshalls.base64_to_raw(parts[0])
	var sig_bytes := Marshalls.base64_to_raw(parts[1])
	var expected := _hmac_sha256(secret, json_bytes)

	if expected.size() != sig_bytes.size():
		return {"ok": false, "error": "bad_sig"}
	for i in expected.size():
		if expected[i] != sig_bytes[i]:
			return {"ok": false, "error": "bad_sig"}

	var payload = JSON.parse_string(json_bytes.get_string_from_utf8())
	if typeof(payload) != TYPE_DICTIONARY:
		return {"ok": false, "error": "bad_payload"}

	var now := int(Time.get_unix_time_from_system())
	if payload.has("exp") and now > int(payload["exp"]):
		return {"ok": false, "error": "expired"}

	return {"ok": true, "payload": payload}
