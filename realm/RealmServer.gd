extends RpcContract
class_name RealmServer

const REALM_PORT_DEFAULT := 1909
const ZONE_PORT_START := 1910
const ZONE_PORT_END := 1950
const INTERNAL_TCP_PORT_DEFAULT := 4001

const HUB_MAP_ID := "res://maps/HubMap.tscn"
const ZONE_EXE_REL := "ZoneServer" # kept for future; not used in editor runs

const ZONE_HEARTBEAT_TIMEOUT := 6 # seconds

var ticket_secret: String = "dev_secret_change_me"
var jwt_secret: String = "CHANGE_ME_TO_A_LONG_RANDOM_SECRET_AT_LEAST_32_CHARS"

# API proxy (Realm -> API)
var api_base := "http://127.0.0.1:5131"

# --- networking config (parsed from args) ---
var realm_port: int = REALM_PORT_DEFAULT

# What the Realm tells clients to use when connecting to Zones.
# For local dev: default = 127.0.0.1
# For friends: set to your public IP or DNS (e.g. myrealm.ddns.net)
var public_host: String = "127.0.0.1"

# Internal TCP for zones -> realm (default local-only)
var internal_tcp_host: String = "127.0.0.1"
var internal_tcp_port: int = INTERNAL_TCP_PORT_DEFAULT

# --- services ---
var sessions: RealmSessions
var registry: InstanceRegistry
var zones: ZoneSupervisor
var api: ApiGateway


func _ready() -> void:
	ProcLog.lines(["[REALM] path: " + str(get_path())])

	_parse_args()

	ProcLog.lines([
		"[REALM] config realm_port=", realm_port,
		" public_host=", public_host,
		" internal_tcp=", internal_tcp_host, ":", internal_tcp_port,
		" api_base=", api_base
	])

	# --- build services ---
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

	# service wiring
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
		# generic lobby gateway response -> client
		rpc_id(peer_id, "s_lobby_response", kind, ok, payload)
	)

	# --- Start ENet for clients ---
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

	# --- Start internal TCP server for zones ---
	var err2 := zones.start_tcp(internal_tcp_port, internal_tcp_host)
	if err2 != OK:
		push_error("Realm TCP listen failed: %s" % err2)
		return
	ProcLog.lines(["[REALM] Internal TCP listening on ", internal_tcp_host, ":", internal_tcp_port])


func _process(_dt: float) -> void:
	zones.tick()
	registry.prune_dead_instances()


# -------------------------
# Arg parsing (same vibe as AppMain)
# -------------------------

func _parse_args() -> void:
	var engine_args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()

	var all_args: Array = []
	all_args.append_array(user_args)
	all_args.append_array(engine_args)

	# realm_port (optional override)
	var rp := _extract_arg_any(all_args, ["--realm_port=", "realm_port="])
	if not rp.is_empty():
		var p := int(rp)
		if p > 0:
			realm_port = p

	# public_host controls what we put in travel.host
	var ph := _extract_arg_any(all_args, ["--public_host=", "public_host="])
	if not ph.is_empty():
		public_host = ph.strip_edges()

	# api_base (optional)
	var ab := _extract_arg_any(all_args, ["--api_base=", "api_base="])
	if not ab.is_empty():
		api_base = ab.strip_edges()

	# internal tcp host/port (optional)
	var ith := _extract_arg_any(all_args, ["--internal_tcp_host=", "internal_tcp_host="])
	if not ith.is_empty():
		internal_tcp_host = ith.strip_edges()

	var itp := _extract_arg_any(all_args, ["--internal_tcp_port=", "internal_tcp_port="])
	if not itp.is_empty():
		var tp := int(itp)
		if tp > 0:
			internal_tcp_port = tp


func _extract_arg_any(args: Array, prefixes: Array[String]) -> String:
	for a in args:
		if typeof(a) != TYPE_STRING:
			continue
		var s: String = a
		for pref in prefixes:
			if s.begins_with(pref):
				return s.get_slice("=", 1)
	return ""


# -------------------------
# Instance lifecycle
# -------------------------

func _on_instance_dead(instance_id: int) -> void:
	# idempotent: removing twice is fine
	ProcLog.lines(["[REALM] Instance DEAD instance=", instance_id])
	registry.remove_instance(instance_id)


# ---------------- RPCs: Client -> Realm ----------------

@rpc("any_peer", "reliable")
func c_authenticate(jwt: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	var result := sessions.verify_jwt(jwt)
	if result.ok == false:
		ProcLog.lines(["[REALM] auth failed peer=", peer_id, " reason=", result.reason])
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return

	sessions.accept_peer(peer_id, jwt, result)
	ProcLog.lines(["[REALM] auth ok peer=", peer_id, " account=", result.account_id, " uname=", result.username])

	rpc_id(peer_id, "s_auth_ok", { "account_id": int(result.account_id), "username": str(result.username) })


@rpc("any_peer", "reliable")
func c_request_zone_list() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var zones_list := registry.get_public_zone_list()
	rpc_id(peer_id, "s_zone_list", zones_list)


@rpc("any_peer", "reliable")
func c_request_create_zone(map_id: String, seed: int, capacity: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	if not sessions.is_authed(peer_id):
		rpc_id(peer_id, "s_create_zone_failed", "unauthenticated")
		return

	var key := "user:%d:%d" % [peer_id, Time.get_ticks_msec()]
	var inst = registry.create_instance(key, "ZONE", map_id, seed, capacity)
	if inst == null:
		rpc_id(peer_id, "s_create_zone_failed", "no_capacity")
		return

	zones.spawn_zone_process(inst, ticket_secret)

	# return updated list
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

	var st := str(inst.status)
	if st != "RUNNING" and st != "STARTING":
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

	# IMPORTANT: send public_host to clients, not localhost,
	# so friends can connect to spawned zones.
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

		# ---- PUBLIC-ish (optional) ----
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
