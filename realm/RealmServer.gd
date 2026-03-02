# res://realm/RealmServer.gd
extends RpcContract
class_name RealmServer

const REALM_PORT := 1909
const ZONE_PORT_START := 1910
const ZONE_PORT_END := 1950
const INTERNAL_TCP_PORT := 4001

const HUB_MAP_ID := "res://maps/HubMap.tscn"
const ZONE_EXE_REL := "ZoneServer"

const ZONE_HEARTBEAT_TIMEOUT := 6 # seconds

var ticket_secret: String = "dev_secret_change_me"
var jwt_secret: String = "CHANGE_ME_TO_A_LONG_RANDOM_SECRET_AT_LEAST_32_CHARS"

# Instance registry: key -> instance dict
var instances: Dictionary = {}
# port -> bool allocated
var port_alloc: Dictionary = {}

# internal TCP server for zones
var tcp_server := TCPServer.new()
var zone_peers: Array[StreamPeerTCP] = []
var zone_buffers: Dictionary = {} # peer_key(string) -> PackedByteArray
var peer_to_instance: Dictionary = {} # peer_key(string) -> instance_id(int)

# API proxy
var api_base := "http://127.0.0.1:5131"
var http: HTTPRequest

# Queue-based HTTP proxy (no rate limiting / no "busy")
var _http_busy: bool = false
var _http_queue: Array = []      # each: { peer_id, kind, url, method, body, headers:Array[String] }
var _http_active: Dictionary = {} # active: { peer_id, kind }

# peer_id -> { account_id:int, username:String, exp:int, jwt:String }
var auth_sessions: Dictionary = {}

func _ready() -> void:
	ProcLog.lines(["[REALM] path: " + str(get_path())])

	# init ports
	for p in range(ZONE_PORT_START, ZONE_PORT_END + 1):
		port_alloc[p] = false

	# Start ENet for clients
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(REALM_PORT, 128)
	if err != OK:
		push_error("Realm ENet create_server failed: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	ProcLog.lines(["[REALM] ENet listening on ", REALM_PORT])

	multiplayer.peer_connected.connect(func(id):
		ProcLog.lines(["[REALM] client connected: ", id])
	)

	multiplayer.peer_disconnected.connect(func(id):
		ProcLog.lines(["[REALM] client disconnected: ", id])
		auth_sessions.erase(id)

		# prune queued jobs for this peer so we don't reply to dead clients
		_http_queue = _http_queue.filter(func(j):
			return int(j.get("peer_id", 0)) != int(id)
		)

		# if the active job belonged to them, drop it (we can't cancel HTTPRequest, but we can ignore completion)
		if not _http_active.is_empty() and int(_http_active.get("peer_id", 0)) == int(id):
			_http_active.clear()
	)

	# Start internal TCP server (localhost)
	var err2 := tcp_server.listen(INTERNAL_TCP_PORT, "127.0.0.1")
	if err2 != OK:
		push_error("Realm TCP listen failed: %s" % err2)
		return
	ProcLog.lines(["[REALM] Internal TCP listening on 127.0.0.1:", INTERNAL_TCP_PORT])

	# HTTP proxy
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_api_request_completed)

func _process(_dt: float) -> void:
	_accept_zone_tcp()
	_poll_zone_tcp()

func _accept_zone_tcp() -> void:
	while tcp_server.is_connection_available():
		var p := tcp_server.take_connection()
		if p:
			zone_peers.append(p)
			var key := str(p.get_instance_id())
			zone_buffers[key] = PackedByteArray()
			ProcLog.lines(["[REALM] Zone TCP connected: ", key])

func _poll_zone_tcp() -> void:
	var now := int(Time.get_unix_time_from_system())

	for i in range(zone_peers.size() - 1, -1, -1):
		var p := zone_peers[i]
		var status := p.get_status()
		var peer_key := str(p.get_instance_id())

		if status != StreamPeerTCP.STATUS_CONNECTED:
			ProcLog.lines(["[REALM] Zone TCP disconnected: ", peer_key, " status=", status])

			if peer_to_instance.has(peer_key):
				var instance_id := int(peer_to_instance[peer_key])
				peer_to_instance.erase(peer_key)
				_on_instance_dead(instance_id)

			zone_buffers.erase(peer_key)
			zone_peers.remove_at(i)
			continue

		var buf: PackedByteArray = zone_buffers.get(peer_key, PackedByteArray())
		var r := NetJson.poll_lines(p, buf)
		zone_buffers[peer_key] = r.buffer
		for m in r.msgs:
			_on_zone_msg(p, m)

	_prune_dead_instances(now)

func _on_zone_msg(p: StreamPeerTCP, m: Dictionary) -> void:
	var t = m.get("type", "")
	var peer_key := str(p.get_instance_id())

	match t:
		"READY":
			var instance_id := int(m.get("instance_id", -1))
			var port := int(m.get("port", -1))
			var cap := int(m.get("capacity", 0))

			ProcLog.lines(["[REALM] Zone READY instance=", instance_id, " port=", port, " cap=", cap])

			peer_to_instance[peer_key] = instance_id

			for k in instances.keys():
				if int(instances[k].instance_id) == instance_id:
					instances[k].status = "RUNNING"
					instances[k].capacity = cap
					instances[k].last_heartbeat = Time.get_unix_time_from_system()

		"HEARTBEAT":
			var instance_id := int(m.get("instance_id", -1))
			var pc := int(m.get("player_count", 0))
			for k in instances.keys():
				if int(instances[k].instance_id) == instance_id:
					instances[k].player_count = pc
					instances[k].last_heartbeat = Time.get_unix_time_from_system()

		"SHUTDOWN":
			var instance_id := int(m.get("instance_id", -1))
			_on_instance_dead(instance_id)

		_:
			ProcLog.lines(["[REALM] Unknown zone msg: ", m])

func _prune_dead_instances(now: int) -> void:
	for k in instances.keys():
		var inst = instances[k]
		if inst.status != "RUNNING":
			continue
		var last := int(inst.get("last_heartbeat", 0))
		if last > 0 and (now - last) > ZONE_HEARTBEAT_TIMEOUT:
			ProcLog.lines(["[REALM] Heartbeat timeout instance=", inst.instance_id, " last=", last, " now=", now])
			_on_instance_dead(int(inst.instance_id))

func _on_instance_dead(instance_id: int) -> void:
	for pk in peer_to_instance.keys():
		if int(peer_to_instance[pk]) == instance_id:
			peer_to_instance.erase(pk)
			break

	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			var port = int(instances[k].port)
			ProcLog.lines(["[REALM] Instance DEAD instance=", instance_id, " freeing port ", port])
			port_alloc[port] = false
			instances.erase(k)
			return

# ---------- Instance management ----------

func _get_or_create_hub() -> Variant:
	var key := "hub:default"
	var now := int(Time.get_unix_time_from_system())

	if instances.has(key):
		var inst = instances[key]

		if inst.status == "RUNNING":
			var last := int(inst.get("last_heartbeat", 0))
			if last > 0 and (now - last) > ZONE_HEARTBEAT_TIMEOUT:
				ProcLog.lines(["[REALM] Hub stale; respawning instance=", inst.instance_id])
				_on_instance_dead(int(inst.instance_id))
			elif inst.player_count < inst.capacity:
				return inst

		if inst.status == "STARTING":
			return inst

	return _create_instance(key, "HUB", HUB_MAP_ID, 42, 32)

func _create_instance(key: String, kind: String, map_id: String, seed: int, capacity: int) -> Variant:
	var port := _alloc_port()
	if port == -1:
		push_error("[REALM] No free zone ports!")
		return null

	var instance_id := int(Time.get_unix_time_from_system() * 1000) + randi() % 999
	var inst := {
		"instance_id": instance_id,
		"kind": kind,
		"key": key,
		"map_id": map_id,
		"seed": seed,
		"port": port,
		"status": "STARTING",
		"capacity": capacity,
		"player_count": 0,
		"last_heartbeat": Time.get_unix_time_from_system()
	}
	instances[key] = inst

	_spawn_zone_process(inst)
	return inst

func _alloc_port() -> int:
	for p in range(ZONE_PORT_START, ZONE_PORT_END + 1):
		if port_alloc[p] == false:
			port_alloc[p] = true
			return p
	return -1

func _spawn_zone_process(inst: Dictionary) -> void:
	var exe_path := OS.get_executable_path()

	var log_dir := ProjectSettings.globalize_path("user://zone_logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	var log_path := "%s/zone_%d_%d.log" % [log_dir, int(inst.port), int(inst.instance_id)]

	var f := FileAccess.open(log_path, FileAccess.WRITE)
	if f:
		f.store_line("[REALM] spawned zone process marker")
		f.close()

	var args := [
		"--mode=zone",
		"--port=%d" % int(inst.port),
		"--instance_id=%d" % int(inst.instance_id),
		"--map_id=%s" % str(inst.map_id),
		"--seed=%d" % int(inst.seed),
		"--realm_port=%d" % INTERNAL_TCP_PORT,
		"--ticket_secret=%s" % ticket_secret,
		"--log=%s" % log_path,
	]

	var pid := OS.create_process(exe_path, args)

	ProcLog.lines(["[REALM] Spawned Zone pid=", pid, " port=", int(inst.port), " instance=", int(inst.instance_id)])
	ProcLog.lines(["[REALM] Zone spawn cmd: ", exe_path, " ", str(args)])

# ---------- Client RPCs ----------

@rpc("any_peer", "reliable")
func c_authenticate(jwt: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	var result := JwtHs256.verify_and_decode(jwt, jwt_secret)
	if result.ok == false:
		ProcLog.lines(["[REALM] auth failed peer=", peer_id, " reason=", result.reason])
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return

	var claims: Dictionary = result.claims
	var account_id := int(claims.get("uid", 0))
	var uname := str(claims.get("uname", ""))

	auth_sessions[peer_id] = {
		"account_id": account_id,
		"username": uname,
		"exp": int(claims.get("exp", 0)),
		"jwt": jwt
	}

	ProcLog.lines(["[REALM] auth ok peer=", peer_id, " account=", account_id, " uname=", uname])
	rpc_id(peer_id, "s_auth_ok", { "account_id": account_id, "username": uname })

@rpc("any_peer", "reliable")
func c_request_zone_list() -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	var zones: Array = []
	for k in instances.keys():
		var inst = instances[k]
		if inst.status != "RUNNING" and inst.status != "STARTING":
			continue
		zones.append({
			"key": str(inst.key),
			"instance_id": int(inst.instance_id),
			"kind": str(inst.kind),
			"map_id": str(inst.map_id),
			"seed": int(inst.seed),
			"port": int(inst.port),
			"status": str(inst.status),
			"capacity": int(inst.capacity),
			"player_count": int(inst.player_count),
		})

	rpc_id(peer_id, "s_zone_list", zones)

@rpc("authority", "reliable")
func s_zone_list(_zones: Array) -> void:
	pass

@rpc("any_peer", "reliable")
func c_request_create_zone(map_id: String, seed: int, capacity: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	if auth_sessions.has(peer_id) == false:
		rpc_id(peer_id, "s_create_zone_failed", "unauthenticated")
		return

	var key := "user:%d:%d" % [peer_id, Time.get_ticks_msec()]
	var inst = _create_instance(key, "ZONE", map_id, seed, capacity)
	if inst == null:
		rpc_id(peer_id, "s_create_zone_failed", "no_capacity")
		return

	c_request_zone_list()

@rpc("any_peer", "reliable")
func c_request_enter_instance(instance_id: int, character_id: int, character_name: String) -> void:
	var client_peer_id := multiplayer.get_remote_sender_id()

	if auth_sessions.has(client_peer_id) == false:
		rpc_id(client_peer_id, "s_travel_failed", "unauthenticated")
		return

	var inst: Variant = null
	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			inst = instances[k]
			break

	if inst == null:
		rpc_id(client_peer_id, "s_travel_failed", "instance_not_found")
		return

	if str(inst.status) != "RUNNING" and str(inst.status) != "STARTING":
		rpc_id(client_peer_id, "s_travel_failed", "instance_not_ready")
		return

	if int(inst.player_count) >= int(inst.capacity):
		rpc_id(client_peer_id, "s_travel_failed", "instance_full")
		return

	var now := int(Time.get_unix_time_from_system())
	var auth = auth_sessions[client_peer_id]
	var payload := {
		"instance_id": int(inst.instance_id),
		"character_id": character_id,
		"account_id": int(auth.account_id),
		"character_name": character_name,
		"session_id": str(client_peer_id),
		"iat": now,
		"exp": now + 20,
		"nonce": randi()
	}
	var token := Ticket.issue(ticket_secret, payload)

	rpc_id(client_peer_id, "s_travel_to_zone", {
		"host": "127.0.0.1",
		"port": int(inst.port),
		"instance_id": int(inst.instance_id),
		"map_id": str(inst.map_id),
		"seed": int(inst.seed),
		"join_ticket": token
	})

# ---------- Pattern B lobby gateway ----------

@rpc("any_peer", "reliable")
func c_lobby_request(kind: String, payload: Dictionary) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var authed := auth_sessions.has(peer_id)

	match kind:
		# ---- AUTH (does NOT require existing auth_sessions) ----
		"auth_login":
			_call_api_auth_login(peer_id, payload)

		"auth_register":
			_call_api_auth_register(peer_id, payload)

		# ---- PUBLIC-ish (optional) ----
		"maps_list":
			_call_api_maps_list(peer_id, payload)

		# ---- REQUIRES REALM AUTH ----
		"chars_list":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			_call_api_chars_list(peer_id)

		"char_create":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			_call_api_char_create(peer_id, payload)

		"char_delete":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			_call_api_char_delete(peer_id, payload)

		_:
			rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unknown_kind"})

# ---- AUTH proxy ----

func _call_api_auth_login(peer_id: int, payload: Dictionary) -> void:
	var url := "%s/api/auth/login" % api_base
	var body := JSON.stringify({
		"usernameOrEmail": str(payload.get("usernameOrEmail", "")).strip_edges(),
		"password": str(payload.get("password", ""))
	})
	_api_request(peer_id, "auth_login", url, HTTPClient.METHOD_POST, body, ["Content-Type: application/json", "Accept: application/json"])

func _call_api_auth_register(peer_id: int, payload: Dictionary) -> void:
	var url := "%s/api/auth/register" % api_base
	var body := JSON.stringify({
		"username": str(payload.get("username", "")).strip_edges(),
		"email": str(payload.get("email", "")).strip_edges(),
		"password": str(payload.get("password", ""))
	})
	_api_request(peer_id, "auth_register", url, HTTPClient.METHOD_POST, body, ["Content-Type: application/json", "Accept: application/json"])

# ---- Maps proxy ----

func _call_api_maps_list(peer_id: int, payload: Dictionary) -> void:
	var playable := bool(payload.get("playable", true))
	var hidden := bool(payload.get("hidden", false))

	var url := "%s/api/maps?playable=%s&hidden=%s" % [
		api_base,
		str(playable).to_lower(),
		str(hidden).to_lower()
	]
	_api_request(peer_id, "maps_list", url, HTTPClient.METHOD_GET, "", ["Accept: application/json"])

# ---- Characters proxy ----

func _call_api_chars_list(peer_id: int) -> void:
	var jwt := str(auth_sessions[peer_id].get("jwt", ""))
	var url := "%s/api/characters" % api_base
	_api_request(peer_id, "chars_list", url, HTTPClient.METHOD_GET, "", _bearer(jwt))

func _call_api_char_create(peer_id: int, payload: Dictionary) -> void:
	var jwt := str(auth_sessions[peer_id].get("jwt", ""))
	var url := "%s/api/characters" % api_base
	var body := JSON.stringify({
		"Name": str(payload.get("name", "")).strip_edges(),
		"ClassId": str(payload.get("class_id", "templar")).strip_edges()
	})
	_api_request(peer_id, "char_create", url, HTTPClient.METHOD_POST, body, _bearer(jwt) + ["Content-Type: application/json"])

func _call_api_char_delete(peer_id: int, payload: Dictionary) -> void:
	var jwt := str(auth_sessions[peer_id].get("jwt", ""))
	var id := int(payload.get("id", 0))
	if id <= 0:
		rpc_id(peer_id, "s_lobby_response", "char_delete", false, {"error":"invalid_id"})
		return
	var url := "%s/api/characters/%d" % [api_base, id]
	_api_request(peer_id, "char_delete", url, HTTPClient.METHOD_DELETE, "", _bearer(jwt))

func _bearer(jwt: String) -> Array[String]:
	return [
		"Accept: application/json",
		"Authorization: Bearer " + jwt
	]

# ---- HTTP plumbing (QUEUE) ----

func _api_request(peer_id: int, kind: String, url: String, method: int, body: String, headers: Array) -> void:
	if http == null:
		rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"http_not_ready"})
		return

	var req_headers: Array[String] = []
	for h in headers:
		req_headers.append(str(h))

	_http_queue.append({
		"peer_id": peer_id,
		"kind": kind,
		"url": url,
		"method": method,
		"body": body,
		"headers": req_headers
	})

	_pump_http_queue()

func _pump_http_queue() -> void:
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
		var peer_id := int(_http_active.peer_id)
		var kind := str(_http_active.kind)
		_http_busy = false
		_http_active.clear()
		rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"http_request_failed_" + str(err)})
		_pump_http_queue()

func _on_api_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	# If we dropped active (disconnect), ignore, and continue queue.
	if _http_active.is_empty():
		_http_busy = false
		_pump_http_queue()
		return

	var peer_id := int(_http_active.get("peer_id", 0))
	var kind := str(_http_active.get("kind", ""))

	_http_busy = false
	_http_active.clear()

	var text := body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	var dict = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

	if response_code < 200 or response_code >= 300:
		var err_msg := str(dict.get("error", "http_" + str(response_code)))
		rpc_id(peer_id, "s_lobby_response", kind, false, {"error": err_msg})
	else:
		rpc_id(peer_id, "s_lobby_response", kind, true, dict)

	_pump_http_queue()
