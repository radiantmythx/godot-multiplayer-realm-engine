extends RefCounted
class_name JwtHs256

static func verify_and_decode(token: String, secret: String) -> Dictionary:
	# Returns { ok:bool, reason:String, claims:Dictionary }
	var parts := token.split(".")
	if parts.size() != 3:
		return { "ok": false, "reason": "bad_format" }

	var header_b64 := parts[0]
	var payload_b64 := parts[1]
	var sig_b64 := parts[2]

	var signing_input := (header_b64 + "." + payload_b64).to_utf8_buffer()

	# Verify signature (HS256)
	var expected_sig := _hmac_sha256(signing_input, secret.to_utf8_buffer())
	var expected_b64 := _b64url_encode(expected_sig)

	# Constant-time compare would be ideal; this is fine for dev
	if expected_b64 != sig_b64:
		return { "ok": false, "reason": "bad_signature" }

	# Decode header/payload JSON
	var header_json := _b64url_decode_to_string(header_b64)
	var payload_json := _b64url_decode_to_string(payload_b64)

	var header := _json_to_dict(header_json)
	var claims := _json_to_dict(payload_json)

	if header.is_empty() or claims.is_empty():
		return { "ok": false, "reason": "bad_json" }

	# Basic checks
	if str(header.get("alg", "")) != "HS256":
		return { "ok": false, "reason": "alg_not_hs256" }

	var now := int(Time.get_unix_time_from_system())
	var exp := int(claims.get("exp", 0))
	if exp != 0 and now > exp:
		return { "ok": false, "reason": "expired" }

	# Optional issuer/audience checks (enable if you set these in API)
	# if str(claims.get("iss","")) != "RealmAuthApi": return {ok:false, reason:"bad_iss"}
	# if str(claims.get("aud","")) != "RealmGame": return {ok:false, reason:"bad_aud"}

	return { "ok": true, "reason": "", "claims": claims }

static func _hmac_sha256(data: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, key)
	h.update(data)
	return h.finish()

static func _json_to_dict(s: String) -> Dictionary:
	var p = JSON.parse_string(s)
	if typeof(p) == TYPE_DICTIONARY:
		return p
	return {}

static func _b64url_decode_to_string(s: String) -> String:
	var bytes := _b64url_decode(s)
	return bytes.get_string_from_utf8()

static func _b64url_decode(s: String) -> PackedByteArray:
	var b := s.replace("-", "+").replace("_", "/")
	while (b.length() % 4) != 0:
		b += "="
	return Marshalls.base64_to_raw(b)

static func _b64url_encode(bytes: PackedByteArray) -> String:
	var b := Marshalls.raw_to_base64(bytes)
	b = b.replace("+", "-").replace("/", "_").replace("=", "")
	return b
