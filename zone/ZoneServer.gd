# res://zone/ZoneServer.gd
extends RpcContract
class_name ZoneServer

var port: int
var instance_id: int
var map_id: String
var seed: int

# Spawn config passed from Realm
# Prefer spawns_b64 (base64 JSON array), keep spawns_json for compatibility/testing.
var spawns_json: String = ""
var spawns_b64: String = ""
var spawn_entries: Array = []

# Realm internal TCP link (Zone -> Realm)
var realm_host: String = "127.0.0.1"
var realm_port: int = 4001

var ticket_secret: String = "dev_secret_change_me"

@export var player_scene: PackedScene
@export var projectile_scene: PackedScene
@export var target_scene: PackedScene # server-side debug node for monsters (optional)

@export var monster_db: MonsterDatabase

var log_file_path := ""
var log_f: FileAccess = null

var snapshot_timer: Timer
var projectile_timer: Timer
var heartbeat_timer: Timer
var monster_snap_timer: Timer

var spawned_monsters_once := false
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
	_log("[ZONE] parsed port=%d instance_id=%d map=%s seed=%d realm_host=%s realm_port=%d spawns_json_len=%d spawns_b64_len=%d" % [
		port, instance_id, map_id, seed, realm_host, realm_port, spawns_json.length(), spawns_b64.length()
	])

	_decode_spawn_entries()

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

	combat = CombatResolver.new()
	combat.log = func(m): _log(m)
	add_child(combat)
	combat.configure(monsters, players)

	# Build monster catalog from MonsterDatabase
	var catalog: Dictionary = {}
	if monster_db:
		monster_db.validate(func(m): _log(m))
		catalog = monster_db.build_data_catalog(func(m): _log(m))
	else:
		_log("[ZONE] WARNING: monster_db not assigned; monsters will use fallback defaults")

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

	# Monsters:
	# target_scene is server-side debug visual (optional); catalog drives stats
	monsters.configure(target_scene, world.world_root, catalog)

	projectiles.configure(projectile_scene, world.world_root)

	# Connect to Realm internal TCP (configurable host)
	realm_link.connect_to_realm(realm_host, realm_port)

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

	# projectile timer (also drives AI)
	projectile_timer = Timer.new()
	projectile_timer.wait_time = 1.0 / 60.0
	projectile_timer.one_shot = false
	projectile_timer.timeout.connect(_tick_projectiles)
	add_child(projectile_timer)
	projectile_timer.start()

	# monster snapshots @ 15Hz
	monster_snap_timer = Timer.new()
	monster_snap_timer.wait_time = 1.0 / 15.0
	monster_snap_timer.one_shot = false
	monster_snap_timer.timeout.connect(_broadcast_monster_snapshots)
	add_child(monster_snap_timer)
	monster_snap_timer.start()

func _decode_spawn_entries() -> void:
	spawn_entries = []

	if not spawns_b64.is_empty():
		var txt := _b64_to_utf8_safe(spawns_b64)
		if txt.is_empty():
			_log("[ZONE] WARNING: spawns_b64 decode failed; spawning 0 monsters")
			return

		var parsed = JSON.parse_string(txt)
		if typeof(parsed) == TYPE_ARRAY:
			spawn_entries = parsed
			_log("[ZONE] parsed spawn_entries from spawns_b64 count=%d" % spawn_entries.size())
		else:
			_log("[ZONE] WARNING: spawns_b64 decoded but did not parse as Array type=%s txt=%s" % [str(typeof(parsed)), txt])
		return

	# fallback: direct json
	if not spawns_json.is_empty():
		var parsed2 = JSON.parse_string(spawns_json)
		if typeof(parsed2) == TYPE_ARRAY:
			spawn_entries = parsed2
			_log("[ZONE] parsed spawn_entries from spawns_json count=%d" % spawn_entries.size())
		else:
			_log("[ZONE] WARNING: spawns_json did not parse as Array type=%s" % str(typeof(parsed2)))


func _b64_to_utf8_safe(b64: String) -> String:
	# First try Godot helper (best case)
	var s := Marshalls.base64_to_utf8(b64)
	if not s.is_empty():
		return s

	# Normalize URL-safe base64 -> standard base64
	var norm := b64.replace("-", "+").replace("_", "/")

	# Add padding if missing
	var mod := norm.length() % 4
	if mod == 2:
		norm += "=="
	elif mod == 3:
		norm += "="
	elif mod == 1:
		# impossible/invalid base64 length
		return ""

	# Try again
	return Marshalls.base64_to_utf8(norm)

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
	if monster_snap_timer: monster_snap_timer.stop()

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

	# Spawn monsters once per zone (on first join)
	if not spawned_monsters_once:
		spawned_monsters_once = true
		_spawn_monsters_for_zone()

	# Late join support (send all current monsters)
	for minfo in monsters.get_monster_snapshot_list():
		rpc_id(peer_id, "s_spawn_monster",
			int(minfo.id),
			str(minfo.type_id),
			str(minfo.name),
			minfo.xform,
			int(minfo.hp),
			int(minfo.max_hp)
		)

func _spawn_monsters_for_zone() -> void:
	var spawned: Array = []

	# Requirement: if no MonsterSpawner markers, spawn nothing.
	var root := world.world_root
	if root == null:
		_log("[ZONE] No world_root; skipping monster spawn")
		return

	var spawners := root.get_node_or_null("MonsterSpawners")
	if spawners == null:
		_log("[ZONE] No MonsterSpawners node; spawning 0 monsters (as requested)")
		return

	# If we have markers but no spawn entries from API, we still spawn nothing.
	if spawn_entries.is_empty():
		_log("[ZONE] MonsterSpawners exists but spawn_entries empty; spawning 0 monsters")
		return

	# Delegate actual placement logic to MonsterSystem (uses Marker3Ds under MonsterSpawners)
	spawned = monsters.spawn_from_map(root, spawn_entries, seed)
	_log("[ZONE] spawn_from_map spawned=%d" % spawned.size())

	# Replicate spawns to clients
	for s in spawned:
		for pid in multiplayer.get_peers():
			rpc_id(pid, "s_spawn_monster",
				int(s.id),
				str(s.type_id),
				str(s.name),
				s.xform,
				int(s.hp),
				int(s.max_hp)
			)

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

func _broadcast_monster_snapshots() -> void:
	var peers := multiplayer.get_peers()
	if peers.is_empty():
		return
	if not monsters or not monsters.has_monsters():
		return

	var snaps := monsters.build_snapshot_list()
	if snaps.is_empty():
		return

	for pid in peers:
		rpc_id(pid, "s_monster_snapshots", snaps)

func _broadcast_combat_events(events: Array, peers: Array) -> void:
	if events.is_empty():
		return

	for e in events:
		var t := str(e.get("type", ""))
		match t:
			"target_hp":
				var mid := int(e.get("id", 0))
				var hp := int(e.get("hp", 0))
				var max_hp := 0
				if monsters:
					var m := monsters.get_monster(mid)
					max_hp = int(m.get("max_hp", 0))
				for pid in peers:
					rpc_id(pid, "s_monster_hp", mid, hp, max_hp)

			"break_target":
				var mid := int(e.get("id", 0))
				for pid in peers:
					rpc_id(pid, "s_break_monster", mid)

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

	# AI tick → resolve into player_hp/player_died
	if monsters:
		var ai_events: Array = monsters.tick_ai(dt, players)
		if ai_events.size() > 0 and combat and combat.has_method("resolve_ai_events"):
			_broadcast_combat_events(combat.call("resolve_ai_events", ai_events), peers)

	# Projectiles
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
	var engine_args := OS.get_cmdline_args()
	var user_args := OS.get_cmdline_user_args()

	var args: Array = []
	args.append_array(user_args)
	args.append_array(engine_args)

	for a in args:
		if typeof(a) != TYPE_STRING:
			continue
		var s: String = a

		if s.begins_with("--"):
			s = s.substr(2)

		if s.begins_with("port="):
			port = int(s.get_slice("=", 1))
		elif s.begins_with("instance_id="):
			instance_id = int(s.get_slice("=", 1))
		elif s.begins_with("map_id="):
			map_id = s.get_slice("=", 1)
		elif s.begins_with("seed="):
			seed = int(s.get_slice("=", 1))

		# spawn config
		elif s.begins_with("spawns_json="):
			spawns_json = s.get_slice("=", 1)
		elif s.begins_with("spawns_b64="):
			spawns_b64 = s.get_slice("=", 1)

		# internal tcp target (Zone -> Realm)
		elif s.begins_with("realm_host="):
			realm_host = s.get_slice("=", 1).strip_edges()
		elif s.begins_with("realm_port="):
			realm_port = int(s.get_slice("=", 1))

		elif s.begins_with("ticket_secret="):
			ticket_secret = s.get_slice("=", 1)

		elif s.begins_with("log_file=") or s.begins_with("log="):
			log_file_path = s.get_slice("=", 1)

	if port <= 0:
		push_error("[ZONE] Missing --port / port=")
	if instance_id <= 0:
		push_error("[ZONE] Missing --instance_id / instance_id=")
	if map_id.is_empty():
		push_error("[ZONE] Missing --map_id / map_id=")
