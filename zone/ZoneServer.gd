# res://zone/ZoneServer.gd
extends RpcContract
class_name ZoneServer

var port: int
var instance_id: int
var map_id: String
var seed: int
var realm_port: int = 4001
var ticket_secret: String = "dev_secret_change_me"

@export var player_scene: PackedScene
@export var projectile_scene: PackedScene
@export var target_scene: PackedScene

var log_file_path := ""
var log_f: FileAccess = null

var snapshot_timer: Timer
var projectile_timer: Timer
var heartbeat_timer: Timer

var spawned_test_targets := false
var _quitting := false

# modules
var world: ZoneWorld
var realm_link: ZoneRealmLink
var players: ZonePlayers
var targets: TargetSystem
var projectiles: ProjectileSystem

func _log(msg: String) -> void:
	ProcLog.lines([msg])
	if log_f:
		log_f.store_line(msg)
		log_f.flush()

func _ready() -> void:
	_parse_args()

	if not log_file_path.is_empty():
		log_f = FileAccess.open(log_file_path, FileAccess.WRITE)
		_log("[ZONE] Logging to " + log_file_path)

	_log("[ZONE] args: " + str(OS.get_cmdline_args()))
	_log("[ZONE] parsed port=%d instance_id=%d map=%s seed=%d realm_port=%d" % [port, instance_id, map_id, seed, realm_port])

	# create modules
	world = ZoneWorld.new()
	world.log = func(m): _log(m)
	add_child(world)

	realm_link = ZoneRealmLink.new()
	realm_link.log = func(m): _log(m)
	realm_link.shutdown_requested.connect(_on_realm_shutdown_requested)
	add_child(realm_link)

	players = ZonePlayers.new()
	players.log = func(m): _log(m)
	add_child(players)

	targets = TargetSystem.new()
	targets.log = func(m): _log(m)
	add_child(targets)

	projectiles = ProjectileSystem.new()
	projectiles.log = func(m): _log(m)
	add_child(projectiles)

	# Start ENet server for clients
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 32)
	if err != OK:
		_log("[ZONE] ENet create_server failed on port %d err=%s" % [port, str(err)])
		get_tree().quit()
		return

	multiplayer.multiplayer_peer = peer
	_log("[ZONE] ENet listening on %d instance=%d map=%s" % [port, instance_id, map_id])

	multiplayer.peer_connected.connect(_on_client_connected)
	multiplayer.peer_disconnected.connect(_on_client_disconnected)

	# Load map
	world.load_map_scene(self, map_id, seed)

	# configure systems that need world roots
	players.configure(player_scene, world.players_root)
	targets.configure(target_scene, world.world_root)
	projectiles.configure(projectile_scene, world.world_root)

	realm_link.connect_to_realm("127.0.0.1", realm_port)

	var deadline_ms := Time.get_ticks_msec() + 1500
	while not realm_link.realm_tcp_connected() and Time.get_ticks_msec() < deadline_ms:
		realm_link.poll() # drives StreamPeerTCP state machine
		await get_tree().process_frame

	if realm_link.realm_tcp_connected():
		realm_link.send_ready(instance_id, port, 32)
		_log("[ZONE] Sent READY to Realm")
	else:
		_log("[ZONE] WARNING: Realm TCP never connected; continuing without READY")

	# heartbeat timer
	heartbeat_timer = Timer.new()
	heartbeat_timer.wait_time = 2.0
	heartbeat_timer.one_shot = false
	heartbeat_timer.timeout.connect(func():
		realm_link.send_heartbeat(instance_id, players.get_player_count())
	)
	add_child(heartbeat_timer)
	heartbeat_timer.start()

	# snapshot timer
	snapshot_timer = Timer.new()
	snapshot_timer.wait_time = 1.0 / 60.0
	snapshot_timer.one_shot = false
	snapshot_timer.timeout.connect(_broadcast_snapshots)
	add_child(snapshot_timer)
	snapshot_timer.start()

	# projectile timer
	projectile_timer = Timer.new()
	projectile_timer.wait_time = 1.0 / 60.0
	projectile_timer.one_shot = false
	projectile_timer.timeout.connect(_tick_projectiles)
	add_child(projectile_timer)
	projectile_timer.start()

func _process(_dt: float) -> void:
	realm_link.poll()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_log("[ZONE] WM_CLOSE_REQUEST")
		_graceful_shutdown("window_close")

func _exit_tree() -> void:
	# best-effort on any exit path
	if realm_link:
		realm_link.send_shutdown(instance_id)

func _on_realm_shutdown_requested(reason: String) -> void:
	_graceful_shutdown("realm_request:" + reason)

func _graceful_shutdown(_reason: String) -> void:
	if _quitting:
		return
	_quitting = true

	if heartbeat_timer: heartbeat_timer.stop()
	if snapshot_timer: snapshot_timer.stop()
	if projectile_timer: projectile_timer.stop()

	if realm_link:
		realm_link.send_shutdown(instance_id)

	# give TCP a moment to flush (best-effort)
	await get_tree().create_timer(0.05).timeout
	get_tree().quit()

# ---------------- Client connections ----------------

func _on_client_connected(id: int) -> void:
	_log("[ZONE] client connected: %d" % id)

func _on_client_disconnected(id: int) -> void:
	_log("[ZONE] client disconnected: %d" % id)

	players.remove_peer(id)

	for pid in multiplayer.get_peers():
		rpc_id(pid, "s_despawn_player", id)

# ---------------- Join / auth ----------------

@rpc("any_peer", "reliable")
func c_join_instance(join_ticket: String, character_id: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()

	var res := Ticket.verify(ticket_secret, join_ticket)
	if not res.ok:
		_log("[ZONE] join rejected peer=%d reason=%s" % [peer_id, str(res.error)])
		rpc_id(peer_id, "s_join_rejected", str(res.error))
		multiplayer.disconnect_peer(peer_id)
		return

	var payload: Dictionary = res.payload
	if int(payload.get("instance_id", -1)) != instance_id:
		rpc_id(peer_id, "s_join_rejected", "wrong_instance")
		multiplayer.disconnect_peer(peer_id)
		return
	if int(payload.get("character_id", -1)) != character_id:
		rpc_id(peer_id, "s_join_rejected", "wrong_character")
		multiplayer.disconnect_peer(peer_id)
		return

	var spawn_xform := world.get_next_spawn_transform()
	players.add_peer(peer_id, character_id, spawn_xform)

	rpc_id(peer_id, "s_join_accepted", {
		"instance_id": instance_id,
		"you_peer_id": peer_id
	})

	rpc_id(peer_id, "s_spawn_players_bulk", players.build_spawn_bulk_list())

	for pid2 in multiplayer.get_peers():
		if pid2 == peer_id:
			continue
		rpc_id(pid2, "s_spawn_player", peer_id, character_id, spawn_xform)

	if not spawned_test_targets:
		spawned_test_targets = true
		var spawned := targets.spawn_test_targets()
		for s in spawned:
			for pid in multiplayer.get_peers():
				rpc_id(pid, "s_spawn_target", int(s.id), s.xform, int(s.hp))

	for tinfo in targets.get_target_snapshot_list():
		rpc_id(peer_id, "s_spawn_target", int(tinfo.id), tinfo.xform, int(tinfo.hp))

# ---------------- Movement ----------------

@rpc("any_peer", "unreliable")
func c_set_move_target(world_pos: Vector3) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	players.set_move_target(peer_id, world_pos)

# ---------------- Snapshot replication ----------------

func _broadcast_snapshots() -> void:
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		return

	var dt := snapshot_timer.wait_time
	var speed := 6.0

	var out := players.simulate(dt, speed)
	for p in peers:
		rpc_id(p, "s_apply_snapshots", out)

# ---------------- Projectiles ----------------

func _tick_projectiles() -> void:
	var dt := projectile_timer.wait_time
	var result := projectiles.tick(dt, targets.get_targets())

	var snaps: Array = result.snaps
	var despawn: Array = result.despawn
	var hits: Array = result.hits

	for h in hits:
		var tid := int(h.target_id)
		var r := targets.apply_damage(tid, 1)

		if r.exists:
			for pid in multiplayer.get_peers():
				rpc_id(pid, "s_target_hp", tid, int(r.hp))
		elif r.broke:
			for pid in multiplayer.get_peers():
				rpc_id(pid, "s_break_target", tid)

	if snaps.size() > 0:
		for pid in multiplayer.get_peers():
			rpc_id(pid, "s_projectile_snapshots", snaps)

	for proj_id in despawn:
		for pid in multiplayer.get_peers():
			rpc_id(pid, "s_despawn_projectile", int(proj_id))

@rpc("any_peer", "reliable")
func c_fire_projectile(_from: Vector3, dir: Vector3) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	if not players.has_peer(peer_id):
		return

	if dir.length() < 0.001:
		return
	dir = dir.normalized()

	var yaw := atan2(dir.x, dir.z)
	players.set_yaw(peer_id, yaw)

	var xform := players.get_player_xform(peer_id)
	xform.basis = Basis(Vector3.UP, yaw)

	var st: Dictionary = players.players_by_peer[peer_id]
	st["xform"] = xform
	st["yaw"] = yaw
	players.players_by_peer[peer_id] = st

	var spawn := projectiles.fire(peer_id, xform, dir)
	if spawn.is_empty():
		return

	for pid in multiplayer.get_peers():
		rpc_id(pid, "s_spawn_projectile", int(spawn.proj_id), int(spawn.owner), spawn.px, spawn.vel)

# ---------------- Args ----------------

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = OS.get_cmdline_args()

	for a in args:
		if a.begins_with("--port="):
			port = int(a.get_slice("=", 1))
		elif a.begins_with("--instance_id="):
			instance_id = int(a.get_slice("=", 1))
		elif a.begins_with("--map_id="):
			map_id = a.get_slice("=", 1)
		elif a.begins_with("--seed="):
			seed = int(a.get_slice("=", 1))
		elif a.begins_with("--realm_port="):
			realm_port = int(a.get_slice("=", 1))
		elif a.begins_with("--ticket_secret="):
			ticket_secret = a.get_slice("=", 1)
		elif a.begins_with("--log_file=") or a.begins_with("--log="):
			log_file_path = a.get_slice("=", 1)

	if port <= 0:
		push_error("[ZONE] Missing --port")
	if instance_id <= 0:
		push_error("[ZONE] Missing --instance_id")
	if map_id.is_empty():
		push_error("[ZONE] Missing --map_id")
