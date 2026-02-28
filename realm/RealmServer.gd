# res://realm/RealmServer.gd
extends RpcContract
class_name RealmServer

const REALM_PORT := 1909
const ZONE_PORT_START := 1910
const ZONE_PORT_END := 1950
const INTERNAL_TCP_PORT := 4001

const HUB_MAP_ID := "res://maps/HubMap.tscn" # change to your hub scene path
const ZONE_EXE_REL := "ZoneServer" # exported name later; for editor runs we’ll use godot --path

const ZONE_HEARTBEAT_TIMEOUT := 6 # seconds (Zone sends every 2s)

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

# peer_id -> { account_id:int, username:String, exp:int }
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

	multiplayer.peer_connected.connect(func(id): ProcLog.lines(["[REALM] client connected: ", id]))
	multiplayer.peer_disconnected.connect(func(id):
		ProcLog.lines(["[REALM] client disconnected: ", id])
		auth_sessions.erase(id)
	)

	# Start internal TCP server (localhost)
	var err2 := tcp_server.listen(INTERNAL_TCP_PORT, "127.0.0.1")
	if err2 != OK:
		push_error("Realm TCP listen failed: %s" % err2)
		return
	ProcLog.lines(["[REALM] Internal TCP listening on 127.0.0.1:", INTERNAL_TCP_PORT])

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

	# iterate backwards so we can remove safely
	for i in range(zone_peers.size() - 1, -1, -1):
		var p := zone_peers[i]
		var status := p.get_status()
		var peer_key := str(p.get_instance_id())

		if status != StreamPeerTCP.STATUS_CONNECTED:
			ProcLog.lines(["[REALM] Zone TCP disconnected: ", peer_key, " status=", status])

			# if this peer owned an instance, kill it
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

			# bind this TCP peer to the instance it owns (so disconnect => instance dead)
			peer_to_instance[peer_key] = instance_id

			# mark instance running
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
	# Remove any peer_to_instance bindings that pointed to this instance.
	# (If the peer disconnect handler already ran, this is a no-op.)
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

# ---------- Client RPCs ----------

@rpc("any_peer", "reliable")
func c_request_enter_hub(character_id: int) -> void:
	var client_peer_id := multiplayer.get_remote_sender_id()
	ProcLog.lines(["[REALM] enter_hub request from client=", client_peer_id, " char=", character_id])

	if auth_sessions.has(client_peer_id) == false:
		ProcLog.lines(["[REALM] enter_hub denied (unauth) peer=", client_peer_id])
		rpc_id(client_peer_id, "s_travel_failed", "unauthenticated")
		return

	var inst = _get_or_create_hub()
	if inst == null:
		rpc_id(client_peer_id, "s_travel_failed", "no_capacity")
		return

	# issue ticket
	var now := int(Time.get_unix_time_from_system())
	var auth = auth_sessions[client_peer_id]
	var payload := {
		"instance_id": int(inst.instance_id),
		"character_id": character_id,
		"account_id": int(auth.account_id),
		"session_id": str(client_peer_id), # simple for now
		"iat": now,
		"exp": now + 20,
		"nonce": randi()
	}
	var token := Ticket.issue(ticket_secret, payload)

	rpc_id(client_peer_id, "s_travel_to_zone", {
		"host": "127.0.0.1", # replace with public IP later
		"port": int(inst.port),
		"instance_id": int(inst.instance_id),
		"map_id": str(inst.map_id),
		"seed": int(inst.seed),
		"join_ticket": token
	})

@rpc("authority", "reliable")
func s_travel_to_zone(_travel: Dictionary) -> void:
	# stub to satisfy editor warnings (client defines this)
	pass

@rpc("authority", "reliable")
func s_travel_failed(_reason: String) -> void:
	pass

# ---------- Instance management ----------

func _get_or_create_hub() -> Variant:
	var key := "hub:default"
	var now := int(Time.get_unix_time_from_system())

	# reuse if running with capacity AND not stale
	if instances.has(key):
		var inst = instances[key]

		if inst.status == "RUNNING":
			var last := int(inst.get("last_heartbeat", 0))
			if last > 0 and (now - last) > ZONE_HEARTBEAT_TIMEOUT:
				ProcLog.lines(["[REALM] Hub stale; respawning instance=", inst.instance_id])
				_on_instance_dead(int(inst.instance_id))
			elif inst.player_count < inst.capacity:
				return inst

		# If STARTING, allow travel anyway? I prefer not: wait until READY.
		if inst.status == "STARTING":
			return inst # okay for early dev; client will connect shortly after READY

	# otherwise create
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
	# When running from exported GameDev.exe,
	# this already points to GameDev.exe
	var exe_path := OS.get_executable_path()

	# Optional per-zone log file
	var log_dir := ProjectSettings.globalize_path("user://zone_logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	var log_path := "%s/zone_%d_%d.log" % [log_dir, int(inst.port), int(inst.instance_id)]

	# Spawn marker (so we know Realm attempted it)
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
		"--log=%s" % log_path, # optional custom log arg
	]

	var pid := OS.create_process(exe_path, args)

	ProcLog.lines(["[REALM] Spawned Zone pid=", pid,
		" port=", int(inst.port),
		" instance=", int(inst.instance_id)])
	ProcLog.lines(["[REALM] Zone spawn cmd: ", exe_path, " ", str(args)])

@rpc("any_peer", "reliable")
func c_authenticate(jwt: String) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	var result := JwtHs256.verify_and_decode(jwt, jwt_secret)
	if result.ok == false:
		ProcLog.lines(["[REALM] auth failed peer=", peer_id, " reason=", result.reason])
		# Optional: kick them
		multiplayer.multiplayer_peer.disconnect_peer(peer_id)
		return

	var claims: Dictionary = result.claims
	# We set these in the API token service:
	# uid (account id), uname (username), exp (unix seconds)
	var account_id := int(claims.get("uid", 0))
	var uname := str(claims.get("uname", ""))

	auth_sessions[peer_id] = {
		"account_id": account_id,
		"username": uname,
		"exp": int(claims.get("exp", 0))
	}

	ProcLog.lines(["[REALM] auth ok peer=", peer_id, " account=", account_id, " uname=", uname])

	# optional ack to client
	rpc_id(peer_id, "s_auth_ok", { "account_id": account_id, "username": uname })
	
	
	
@rpc("any_peer", "reliable")
func c_request_zone_list() -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	# You can allow unauth listing, or require auth. I'll allow it:
	var zones: Array = []
	for k in instances.keys():
		var inst = instances[k]
		# only show running or starting zones
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

	# For now, create a unique key each time
	var key := "user:%d:%d" % [peer_id, Time.get_ticks_msec()]
	var inst = _create_instance(key, "ZONE", map_id, seed, capacity)
	if inst == null:
		rpc_id(peer_id, "s_create_zone_failed", "no_capacity")
		return

	# return the updated list (or just ack)
	c_request_zone_list()

@rpc("any_peer", "reliable")
func c_request_enter_instance(instance_id: int, character_id: int) -> void:
	var client_peer_id := multiplayer.get_remote_sender_id()

	if auth_sessions.has(client_peer_id) == false:
		rpc_id(client_peer_id, "s_travel_failed", "unauthenticated")
		return

	# find instance by id
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

	# issue ticket (same as hub)
	var now := int(Time.get_unix_time_from_system())
	var auth = auth_sessions[client_peer_id]
	var payload := {
		"instance_id": int(inst.instance_id),
		"character_id": character_id,
		"account_id": int(auth.account_id),
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


@rpc("authority", "reliable")
func s_create_zone_failed(_reason: String) -> void:
	pass

@rpc("authority", "reliable")
func s_join_accepted(_data: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_join_rejected(_reason: String) -> void:
	pass

@rpc("any_peer", "reliable")
func c_join_instance(_join_ticket: String, _character_id: int) -> void:
	pass

@rpc("any_peer", "unreliable")
func c_set_move_target(_world_pos: Vector3) -> void: pass

@rpc("authority", "reliable")
func s_spawn_players_bulk(_list: Array) -> void: pass

@rpc("authority", "reliable")
func s_spawn_player(_peer_id: int, _character_id: int, _xform: Transform3D) -> void: pass

@rpc("authority", "reliable")
func s_despawn_player(_peer_id: int) -> void: pass

@rpc("authority", "unreliable")
func s_apply_snapshots(_snaps: Array) -> void: pass

@rpc("authority", "reliable")
func s_auth_ok(_data: Dictionary) -> void:
	pass
