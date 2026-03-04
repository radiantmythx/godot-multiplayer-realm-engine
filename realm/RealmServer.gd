extends RpcContract
class_name RealmServer

const REALM_PORT_DEFAULT := 1909
const ZONE_PORT_START := 1910
const ZONE_PORT_END := 1950
const INTERNAL_TCP_PORT_DEFAULT := 4001

const HUB_MAP_ID := "res://maps/HubMap.tscn"
const ZONE_HEARTBEAT_TIMEOUT := 6

const REALM_INTERNAL_PEER := 0

var ticket_secret: String = "dev_secret_change_me"
var jwt_secret: String = "CHANGE_ME_TO_A_LONG_RANDOM_SECRET_AT_LEAST_32_CHARS"

var api_base := "http://127.0.0.1:5131"

var realm_port: int = REALM_PORT_DEFAULT
var public_host: String = "127.0.0.1"

var internal_tcp_host: String = "127.0.0.1"
var internal_tcp_port: int = INTERNAL_TCP_PORT_DEFAULT

var sessions: RealmSessions
var registry: InstanceRegistry
var zones: ZoneSupervisor
var api: ApiGateway

# instance_id -> { requesting_peer:int, map_id:int }
var pending_zone_creates: Dictionary = {}


func _ready() -> void:

	ProcLog.lines(["[REALM] path: " + str(get_path())])

	_parse_args()

	ProcLog.lines([
		"[REALM] config realm_port=", realm_port,
		" public_host=", public_host,
		" internal_tcp=", internal_tcp_host, ":", internal_tcp_port,
		" api_base=", api_base
	])

	sessions = RealmSessions.new()
	sessions.set_jwt_secret(jwt_secret)
	add_child(sessions)

	registry = InstanceRegistry.new()
	registry.configure_ports(ZONE_PORT_START, ZONE_PORT_END)
	registry.configure_hub(HUB_MAP_ID, 42, 32)
	registry.configure_heartbeat(ZONE_HEARTBEAT_TIMEOUT)
	registry.init_ports()
	add_child(registry)

	zones = ZoneSupervisor.new()
	add_child(zones)

	api = ApiGateway.new()
	api.set_api_base(api_base)
	add_child(api)

	zones.zone_ready.connect(func(instance_id: int, _port: int, cap: int):
		registry.mark_running(instance_id, cap)
	)

	zones.zone_heartbeat.connect(func(instance_id: int, pc: int):
		registry.mark_heartbeat(instance_id, pc)
	)

	zones.zone_shutdown.connect(func(instance_id: int):
		_on_instance_dead(instance_id)
	)

	zones.zone_disconnected.connect(func(instance_id: int):
		_on_instance_dead(instance_id)
	)

	registry.instance_dead.connect(func(instance_id: int):
		ProcLog.lines(["[REALM] Heartbeat timeout instance=", instance_id])
		_on_instance_dead(instance_id)
	)

	api.response.connect(func(peer_id: int, kind: String, ok: bool, payload: Dictionary):

		if peer_id != REALM_INTERNAL_PEER:
			rpc_id(peer_id, "s_lobby_response", kind, ok, payload)
			return

		match kind:
			"map_spawns":
				_on_internal_map_spawns(ok, payload)
			_:
				ProcLog.lines(["[REALM] internal api response kind=", kind, " ok=", ok])
	)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(realm_port, 128)

	if err != OK:
		push_error("Realm ENet create_server failed: %s" % err)
		return

	multiplayer.multiplayer_peer = peer
	ProcLog.lines(["[REALM] ENet listening on ", realm_port])

	multiplayer.peer_connected.connect(func(id):
		ProcLog.lines(["[REALM] client connected: ", id])
	)

	multiplayer.peer_disconnected.connect(func(id):

		ProcLog.lines(["[REALM] client disconnected: ", id])

		sessions.remove_peer(id)
		api.remove_peer(id)
	)

	var err2 := zones.start_tcp(internal_tcp_port, internal_tcp_host)

	if err2 != OK:
		push_error("Realm TCP listen failed: %s" % err2)
		return

	ProcLog.lines(["[REALM] Internal TCP listening on ", internal_tcp_host, ":", internal_tcp_port])


func _process(_dt: float) -> void:
	zones.tick()
	registry.prune_dead_instances()


func _parse_args() -> void:

	var engine_args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()

	var args: Array = []
	args.append_array(user_args)
	args.append_array(engine_args)

	for a in args:
		if typeof(a) != TYPE_STRING:
			continue

		var s: String = a

		if s.begins_with("--realm_port=") or s.begins_with("realm_port="):
			realm_port = int(s.get_slice("=", 1))

		elif s.begins_with("--public_host=") or s.begins_with("public_host="):
			public_host = s.get_slice("=", 1)

		elif s.begins_with("--api_base=") or s.begins_with("api_base="):
			api_base = s.get_slice("=", 1)

		elif s.begins_with("--internal_tcp_host=") or s.begins_with("internal_tcp_host="):
			internal_tcp_host = s.get_slice("=", 1)

		elif s.begins_with("--internal_tcp_port=") or s.begins_with("internal_tcp_port="):
			internal_tcp_port = int(s.get_slice("=", 1))


func _on_instance_dead(instance_id: int) -> void:

	ProcLog.lines(["[REALM] Instance DEAD instance=", instance_id])

	pending_zone_creates.erase(instance_id)

	registry.remove_instance(instance_id)


func _spawn_zone_with_entries(instance_id: int, entries: Array) -> void:

	var inst = registry.find_instance_by_id(instance_id)

	if inst == null:
		ProcLog.lines(["[REALM] spawn_zone missing instance=", instance_id])
		pending_zone_creates.erase(instance_id)
		return

	inst.spawn_entries = entries

	var json := JSON.stringify(entries)
	var b64 := Marshalls.raw_to_base64(json.to_utf8_buffer())

	zones.spawn_zone_process(inst, ticket_secret, b64)

	pending_zone_creates.erase(instance_id)


func _on_internal_map_spawns(ok: bool, payload: Dictionary) -> void:

	var instance_id := 0

	for k in pending_zone_creates.keys():
		instance_id = int(k)
		break

	if instance_id <= 0:
		ProcLog.lines(["[REALM] map_spawns returned but no pending instance"])
		return

	if not ok:
		ProcLog.lines(["[REALM] map_spawns failed instance=", instance_id])
		_spawn_zone_with_entries(instance_id, [])
		return

	var spawns = payload.get("spawns", [])

	if typeof(spawns) != TYPE_ARRAY:
		spawns = []

	ProcLog.lines([
		"[REALM] map_spawns ok instance=", instance_id,
		" entries=", (spawns as Array).size()
	])

	_spawn_zone_with_entries(instance_id, spawns)


@rpc("any_peer", "reliable")
func c_authenticate(jwt: String) -> void:

	var peer_id := multiplayer.get_remote_sender_id()

	var result := sessions.verify_jwt(jwt)

	if not result.ok:
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return

	sessions.accept_peer(peer_id, jwt, result)

	rpc_id(peer_id, "s_auth_ok", {
		"account_id": int(result.account_id),
		"username": str(result.username)
	})


@rpc("any_peer", "reliable")
func c_request_zone_list() -> void:

	var peer_id := multiplayer.get_remote_sender_id()

	var zones_list := registry.get_public_zone_list()

	rpc_id(peer_id, "s_zone_list", zones_list)


@rpc("any_peer", "reliable")
func c_request_create_zone(map_id: int, scene_path: String, seed: int, capacity: int) -> void:

	var peer_id := multiplayer.get_remote_sender_id()

	if not sessions.is_authed(peer_id):
		rpc_id(peer_id, "s_create_zone_failed", "unauthenticated")
		return

	var key := "user:%d:%d" % [peer_id, Time.get_ticks_msec()]

	var inst = registry.create_instance(key, "ZONE", scene_path, seed, capacity)

	if inst == null:
		rpc_id(peer_id, "s_create_zone_failed", "no_capacity")
		return

	pending_zone_creates[int(inst.instance_id)] = {
		"requesting_peer": peer_id,
		"map_id": map_id
	}

	api.map_spawns(REALM_INTERNAL_PEER, map_id)

	c_request_zone_list()


@rpc("any_peer", "reliable")
func c_request_enter_instance(instance_id: int, character_id: int, character_name: String) -> void:

	var peer_id := multiplayer.get_remote_sender_id()

	if not sessions.is_authed(peer_id):
		rpc_id(peer_id, "s_travel_failed", "unauthenticated")
		return

	var inst = registry.find_instance_by_id(instance_id)

	if inst == null:
		rpc_id(peer_id, "s_travel_failed", "instance_not_found")
		return

	if str(inst.status) != "RUNNING" and str(inst.status) != "STARTING":
		rpc_id(peer_id, "s_travel_failed", "instance_not_ready")
		return

	if int(inst.player_count) >= int(inst.capacity):
		rpc_id(peer_id, "s_travel_failed", "instance_full")
		return

	var now := int(Time.get_unix_time_from_system())

	var payload := {
		"instance_id": int(inst.instance_id),
		"character_id": character_id,
		"account_id": sessions.get_account_id(peer_id),
		"character_name": character_name,
		"session_id": str(peer_id),
		"iat": now,
		"exp": now + 20,
		"nonce": randi()
	}

	var token := Ticket.issue(ticket_secret, payload)

	rpc_id(peer_id, "s_travel_to_zone", {
		"host": public_host,
		"port": int(inst.port),
		"instance_id": int(inst.instance_id),
		"map_id": str(inst.map_id),
		"seed": int(inst.seed),
		"join_ticket": token
	})

# ---------------- Pattern B lobby gateway ----------------

@rpc("any_peer", "reliable")
func c_lobby_request(kind: String, payload: Dictionary) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var authed := sessions.is_authed(peer_id)

	match kind:
		# ---- AUTH (does NOT require existing auth_sessions) ----
		"auth_login":
			api.auth_login(peer_id,
				str(payload.get("usernameOrEmail", "")),
				str(payload.get("password", ""))
			)

		"auth_register":
			api.auth_register(peer_id,
				str(payload.get("username", "")),
				str(payload.get("email", "")),
				str(payload.get("password", ""))
			)

		# ---- PUBLIC-ish ----
		"maps_list":
			api.maps_list(peer_id,
				bool(payload.get("playable", true)),
				bool(payload.get("hidden", false))
			)

		# ---- REQUIRES REALM AUTH ----
		"chars_list":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			api.chars_list(peer_id, sessions.get_jwt(peer_id))

		"char_create":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			api.char_create(peer_id, sessions.get_jwt(peer_id),
				str(payload.get("name", "")),
				str(payload.get("class_id", "templar"))
			)

		"char_delete":
			if not authed:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unauthenticated"})
				return
			var id := int(payload.get("id", 0))
			if id <= 0:
				rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"invalid_id"})
				return
			api.char_delete(peer_id, sessions.get_jwt(peer_id), id)

		_:
			rpc_id(peer_id, "s_lobby_response", kind, false, {"error":"unknown_kind"})
