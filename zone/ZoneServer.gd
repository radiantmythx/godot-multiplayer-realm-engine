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
@export var target_scene: PackedScene # NOTE: keep for now (monster scene). Rename later when you’re ready.

var log_file_path := ""
var log_f: FileAccess = null

var snapshot_timer: Timer
var projectile_timer: Timer
var heartbeat_timer: Timer
var target_snap_timer: Timer

var spawned_test_monsters := false
var _quitting := false

# modules
var world: ZoneWorld
var realm_link: ZoneRealmLink
var players: ZonePlayers
var monsters: MonsterSystem
var projectiles: ProjectileSystem
var combat: CombatResolver

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

	monsters = MonsterSystem.new()
	monsters.log = func(m): _log(m)
	add_child(monsters)

	projectiles = ProjectileSystem.new()
	projectiles.log = func(m): _log(m)
	add_child(projectiles)

	target_snap_timer = Timer.new()
	target_snap_timer.wait_time = 1.0 / 15.0
	target_snap_timer.one_shot = false
	target_snap_timer.timeout.connect(_broadcast_target_snapshots)
	add_child(target_snap_timer)
	target_snap_timer.start()

	combat = CombatResolver.new()
	combat.log = func(m): _log(m)
	add_child(combat)
	combat.configure(monsters, players)

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
	monsters.configure(target_scene, world.world_root) # still using target_scene for now
	projectiles.configure(projectile_scene, world.world_root)

	realm_link.connect_to_realm("127.0.0.1", realm_port)

	var deadline_ms := Time.get_ticks_msec() + 1500
	while not realm_link.realm_tcp_connected() and Time.get_ticks_msec() < deadline_ms:
		realm_link.poll()
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

	# projectile timer (also drives AI right now)
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
	if target_snap_timer: target_snap_timer.stop()

	if realm_link:
		realm_link.send_shutdown(instance_id)

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

	var character_name := str(payload.get("character_name", ""))
	if character_name.is_empty():
		character_name = "Player"

	var spawn_xform := world.get_next_spawn_transform()
	players.add_peer(peer_id, character_id, character_name, spawn_xform)

	rpc_id(peer_id, "s_join_accepted", {
		"instance_id": instance_id,
		"you_peer_id": peer_id
	})

	# send existing players to the joiner
	rpc_id(peer_id, "s_spawn_players_bulk", players.build_spawn_bulk_list())

	# announce joiner to everyone else
	for pid2 in multiplayer.get_peers():
		if pid2 == peer_id:
			continue
		rpc_id(pid2, "s_spawn_player", peer_id, character_id, character_name, spawn_xform)

	# spawn “test monsters” once per zone
	if not spawned_test_monsters:
		spawned_test_monsters = true
		var spawned = monsters.spawn_test_monsters()
		for s in spawned:
			for pid in multiplayer.get_peers():
				rpc_id(pid, "s_spawn_target", int(s.id), s.xform, int(s.hp))

	# send current monsters to the joiner (late join support)
	for tinfo in monsters.get_monster_snapshot_list():
		rpc_id(peer_id, "s_spawn_target", int(tinfo.id), tinfo.xform, int(tinfo.hp))

@rpc("any_peer", "reliable")
func c_leave_zone() -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	_log("[ZONE] leave requested by peer %d" % peer_id)

	players.remove_peer(peer_id)
	for pid in multiplayer.get_peers():
		rpc_id(pid, "s_despawn_player", peer_id)

	multiplayer.disconnect_peer(peer_id)

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

func _broadcast_target_snapshots() -> void:
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		return
	if not monsters or not monsters.has_monsters():
		return

	var snaps := monsters.build_snapshot_list()
	if snaps.is_empty():
		return

	for pid in peers:
		rpc_id(pid, "s_target_snapshots", snaps)

func _broadcast_combat_events(events: Array, peers: Array) -> void:
	if events.is_empty():
		return

	for e in events:
		var t := str(e.get("type", ""))
		match t:
			"target_hp":
				var tid := int(e.get("id", 0))
				var hp := int(e.get("hp", 0))
				for pid in peers:
					rpc_id(pid, "s_target_hp", tid, hp)

			"break_target":
				var tid := int(e.get("id", 0))
				for pid in peers:
					rpc_id(pid, "s_break_target", tid)

			"player_hp":
				var ppeer := int(e.get("peer_id", 0))
				var php := int(e.get("hp", 0))
				for pid in peers:
					rpc_id(pid, "s_player_hp", ppeer, php)

			"player_died":
				var ppeer := int(e.get("peer_id", 0))
				for pid in peers:
					rpc_id(pid, "s_player_died", ppeer)

			_:
				pass

# ---------------- Projectiles + AI ----------------

func _tick_projectiles() -> void:
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		return

	var dt := projectile_timer.wait_time

	# --- AI tick (aggro/chase/melee) ---
	if monsters:
		var ai_events: Array = monsters.tick_ai(dt, players)
		if ai_events.size() > 0:
			_log("[ZONE] ai_events=" + str(ai_events)) # DEBUG: remove later

			if combat and combat.has_method("resolve_ai_events"):
				var cev: Array = combat.call("resolve_ai_events", ai_events)
				if cev.size() > 0:
					_log("[ZONE] combat_events=" + str(cev)) # DEBUG: remove later
					_broadcast_combat_events(cev, peers)

	# --- Projectiles ---
	var hurtboxes: Array = []
	if players and players.has_method("get_hurtboxes"):
		hurtboxes.append_array(players.call("get_hurtboxes"))
	if monsters and monsters.has_method("get_hurtboxes"):
		hurtboxes.append_array(monsters.call("get_hurtboxes"))

	var result := projectiles.tick(dt, hurtboxes)

	var snaps: Array = result.snaps
	var despawn: Array = result.despawn
	var hits: Array = result.hits

	if combat and hits.size() > 0:
		_broadcast_combat_events(combat.resolve_projectile_hits(hits), peers)

	if snaps.size() > 0:
		for pid in peers:
			rpc_id(pid, "s_projectile_snapshots", snaps)

	for proj_id in despawn:
		for pid in peers:
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

	var peers := multiplayer.get_peers()
	for pid in peers:
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
