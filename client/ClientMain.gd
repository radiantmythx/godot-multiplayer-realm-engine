# res://client/ClientMain.gd
extends RpcContract

@export var player_scene: PackedScene
@export var projectile_scene: PackedScene

# Fallback monster scene (optional)
@export var target_scene: PackedScene

# NEW: single registry shared with server (can be same .tres)
@export var monster_db: MonsterDatabase

# travel state
var current_join_ticket := ""
var current_zone_host := ""
var current_zone_port := 0
var current_character_id := 1

var local_peer_id: int = 0

# existing modules
var net: ClientNet
var world: ClientWorld
var players_view: ClientPlayersView
var combat_view: ClientCombatView
var aim: ClientAim
var input: ClientInput

# services
var session: ClientSession
var conn: ClientConnection
var watchdog: ClientZoneWatchdog
var gameplay: ClientGameplay

@export var login_screen_scene: PackedScene
var login_ui: Control

var last_zone_list: Array = []

signal lobby_response(kind: String, ok: bool, payload: Dictionary)

func _ready() -> void:
	set_process_input(true)
	ProcLog.lines(["[CLIENT] path: ", get_path()])
	ProcLog.lines(["[CLIENT] rpc root name=", name, " path=", get_path()])

	add_to_group("client_main")

	# modules
	net = ClientNet.new()
	net.log = func(m): ProcLog.lines([m])
	add_child(net)

	world = ClientWorld.new()
	world.log = func(m): ProcLog.lines([m])
	add_child(world)

	players_view = ClientPlayersView.new()
	players_view.log = func(m): ProcLog.lines([m])
	players_view.configure(player_scene)
	add_child(players_view)

	combat_view = ClientCombatView.new()
	combat_view.log = func(m): ProcLog.lines([m])

	# Build type -> scene map from MonsterDatabase
	var monster_map: Dictionary = {}
	if monster_db:
		monster_db.validate(func(m): ProcLog.lines([m]))
		monster_map = monster_db.build_scene_map(func(m): ProcLog.lines([m]))
	else:
		ProcLog.lines(["[CLIENT] WARNING: monster_db not assigned; using fallback only"])

	# Default falls back to target_scene if a type isn't mapped yet
	combat_view.configure(projectile_scene, target_scene, monster_map)
	add_child(combat_view)

	aim = ClientAim.new()
	add_child(aim)

	input = ClientInput.new()
	input.log = func(m): ProcLog.lines([m])
	add_child(input)

	# services
	session = ClientSession.new()
	add_child(session)

	conn = ClientConnection.new()
	conn.log = func(m): ProcLog.lines([m])
	add_child(conn)
	conn.configure(multiplayer, net)

	watchdog = ClientZoneWatchdog.new()
	watchdog.timeout_ms = 2500
	add_child(watchdog)

	gameplay = ClientGameplay.new()
	gameplay.log = func(m): ProcLog.lines([m])
	add_child(gameplay)
	gameplay.configure(players_view, aim, input)

	# Wire service signals
	conn.realm_connected.connect(_on_realm_connected)
	conn.zone_connected.connect(_on_zone_connected)
	conn.realm_lost.connect(_on_realm_lost)
	conn.zone_lost.connect(_on_zone_lost)

	watchdog.timeout.connect(func(reason: String):
		if conn.conn_kind == ClientConnection.ConnKind.ZONE:
			_on_zone_lost(reason)
	)

	gameplay.want_back_to_lobby.connect(back_to_lobby)
	gameplay.want_move_target.connect(func(pos: Vector3): send_move_target(pos))
	gameplay.want_fire_projectile.connect(func(from: Vector3, dir: Vector3):
		if conn.conn_kind != ClientConnection.ConnKind.ZONE:
			return
		if not conn.peer_connected():
			return
		rpc_id(1, "c_fire_projectile", from, dir)
	)

	# UI
	if login_screen_scene == null:
		push_error("[CLIENT] login_screen_scene not assigned on ClientMain.tscn!")
		return

	login_ui = login_screen_scene.instantiate()
	add_child(login_ui)

	login_ui.login_success.connect(func(token: String, account_id: int, username: String):
		begin_with_token(token, account_id, username)
		if login_ui.has_method("set_authed"):
			login_ui.call("set_authed", true, account_id, username)
	)

	# Connect to Realm immediately
	conn.set_realm("127.0.0.1", 1909)
	conn.connect_realm()

func begin_with_token(token: String, account_id: int, username: String) -> void:
	session.set_token(token, account_id, username)
	ProcLog.lines(["[CLIENT] begin_with_token account=", account_id, " user=", username])

	if conn.conn_kind == ClientConnection.ConnKind.REALM and conn.peer_connected():
		_send_realm_authenticate()

func _send_realm_authenticate() -> void:
	session.set_realm_authed(false)

	if not session.has_token():
		return

	ProcLog.lines(["[CLIENT] Sending c_authenticate to Realm..."])
	rpc_id(1, "c_authenticate", session.jwt_token)

func _input(event: InputEvent) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.ZONE:
		if event.is_action_pressed("ui_cancel"):
			back_to_lobby()
		return
	if not conn.peer_connected():
		return

	gameplay.handle_input(event)

func _process(dt: float) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.ZONE:
		return
	if not conn.peer_connected():
		return

	gameplay.tick(dt)

# Net callbacks
func _on_realm_connected() -> void:
	ProcLog.lines(["[CLIENT] Realm connected"])
	_send_realm_authenticate()

	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Connected to Realm.")

func _on_zone_connected() -> void:
	ProcLog.lines(["[CLIENT] Connected to Zone. Joining instance..."])
	watchdog.set_enabled(true)

	if conn.peer_connected():
		rpc_id(1, "c_join_instance", current_join_ticket, current_character_id)

func _on_realm_lost(reason: String) -> void:
	session.set_realm_authed(false)
	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Realm connection lost: " + reason)

func _on_zone_lost(reason: String) -> void:
	if conn.conn_kind == ClientConnection.ConnKind.ZONE:
		ProcLog.lines(["[CLIENT] Zone lost (", reason, ") -> back to lobby"])

	watchdog.set_enabled(false)
	local_peer_id = 0
	gameplay.set_local_peer_id(0)

	if input and input.has_method("cancel_holding_move"):
		input.call("cancel_holding_move")

	back_to_lobby()

	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Zone disconnected (" + reason + "). Back in lobby.")

# Lobby helpers
func request_zone_list() -> void:
	if conn.conn_kind != ClientConnection.ConnKind.REALM:
		return
	if not conn.peer_connected():
		return
	if not session.is_realm_authed:
		return
	rpc_id(1, "c_request_zone_list")

func request_create_zone(map_id: String, seed: int, capacity: int) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.REALM:
		return
	if not conn.peer_connected():
		return
	if not session.is_realm_authed:
		return
	rpc_id(1, "c_request_create_zone", map_id, seed, capacity)

func request_join_instance(instance_id: int, character_id: int, character_name: String) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.REALM:
		return
	if not conn.peer_connected():
		return
	if not session.is_realm_authed:
		return

	current_character_id = character_id

	var safe_name := (character_name if character_name != null else "").strip_edges()
	if safe_name.is_empty():
		safe_name = "Player"

	rpc_id(1, "c_request_enter_instance", instance_id, character_id, safe_name)

func lobby_request(kind: String, payload: Dictionary) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.REALM:
		return
	if not conn.peer_connected():
		return
	rpc_id(1, "c_lobby_request", kind, payload)

func back_to_lobby() -> void:
	ProcLog.lines(["[CLIENT] Back to lobby requested"])

	if conn.conn_kind == ClientConnection.ConnKind.REALM:
		if is_instance_valid(login_ui):
			login_ui.visible = true
			if login_ui.has_method("set_status"):
				login_ui.call("set_status", "Back in lobby. Choose a zone.")
		request_zone_list()
		return

	if conn.conn_kind == ClientConnection.ConnKind.ZONE and conn.peer_connected():
		rpc_id(1, "c_leave_zone")

	local_peer_id = 0
	current_join_ticket = ""
	current_zone_host = ""
	current_zone_port = 0

	watchdog.set_enabled(false)

	players_view.clear()
	combat_view.clear()

	if world and world.has_method("unload_world"):
		world.call("unload_world")

	conn.disconnect_current()

	session.set_realm_authed(false)
	conn.set_realm("127.0.0.1", 1909)
	conn.connect_realm()

	if is_instance_valid(login_ui):
		login_ui.visible = true
		if login_ui.has_method("set_status"):
			login_ui.call("set_status", "Connecting to Realm...")

# -------------------------
# RPCs (checksum safe)
# -------------------------

@rpc("authority", "reliable")
func s_auth_ok(data: Dictionary) -> void:
	session.set_realm_authed(true)
	ProcLog.lines(["[CLIENT] Realm auth ok: ", data])
	if conn.conn_kind == ClientConnection.ConnKind.REALM and conn.peer_connected():
		rpc_id(1, "c_request_zone_list")

@rpc("authority", "reliable")
func s_zone_list(zones: Array) -> void:
	last_zone_list = zones
	ProcLog.lines(["[CLIENT] zone_list count=", zones.size()])
	if is_instance_valid(login_ui) and login_ui.has_method("set_zone_list"):
		login_ui.call("set_zone_list", zones)

@rpc("authority", "reliable")
func s_create_zone_failed(reason: String) -> void:
	push_error("[CLIENT] Create zone failed: " + reason)
	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Create failed: " + reason)

@rpc("authority", "reliable")
func s_travel_to_zone(travel: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] Travel order: ", travel])

	current_zone_host = travel.host
	current_zone_port = int(travel.port)
	current_join_ticket = travel.join_ticket

	players_view.clear()
	combat_view.clear()

	world.load_world(self, str(travel.map_id))

	conn.disconnect_current()
	conn.set_zone(current_zone_host, current_zone_port)
	conn.connect_zone()

@rpc("authority", "reliable")
func s_travel_failed(reason: String) -> void:
	push_error("[CLIENT] Travel failed: " + reason)
	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Join failed: " + reason)

@rpc("authority", "reliable")
func s_join_accepted(data: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] Join accepted!"])

	local_peer_id = int(data.get("you_peer_id", 0))
	gameplay.set_local_peer_id(local_peer_id)

	players_view.set_local_peer_id(local_peer_id)
	players_view.try_activate_local_camera(self, world)

	if is_instance_valid(login_ui):
		login_ui.visible = false

@rpc("authority", "reliable")
func s_join_rejected(reason: String) -> void:
	push_error("[CLIENT] Join rejected: %s" % reason)

@rpc("authority", "reliable")
func s_spawn_players_bulk(list: Array) -> void:
	players_view.spawn_players_bulk(self, world, list)

@rpc("authority", "reliable")
func s_spawn_player(peer_id: int, character_id: int, name: String, xform: Transform3D) -> void:
	players_view.spawn_player(self, world, peer_id, character_id, name, xform)

@rpc("authority", "reliable")
func s_despawn_player(peer_id: int) -> void:
	players_view.despawn_player(self, world, peer_id)

@rpc("authority", "unreliable")
func s_apply_snapshots(snaps: Array) -> void:
	watchdog.mark_packet()
	players_view.apply_snapshots(snaps)

# Projectiles
@rpc("authority", "reliable")
func s_spawn_projectile(proj_id: int, _owner_peer: int, xform: Transform3D, _vel: Vector3) -> void:
	combat_view.spawn_projectile(self, world, proj_id, xform)

@rpc("authority", "unreliable")
func s_projectile_snapshots(snaps: Array) -> void:
	watchdog.mark_packet()
	combat_view.projectile_snapshots(snaps)

@rpc("authority", "reliable")
func s_despawn_projectile(proj_id: int) -> void:
	combat_view.despawn_projectile(proj_id)

# Monsters
@rpc("authority", "reliable")
func s_spawn_monster(monster_id: int, type_id: String, name: String, xform: Transform3D, hp: int, max_hp: int) -> void:
	combat_view.spawn_monster(self, world, monster_id, type_id, name, xform, hp, max_hp)

@rpc("authority", "unreliable")
func s_monster_snapshots(snaps: Array) -> void:
	watchdog.mark_packet()
	combat_view.monster_snapshots(snaps)

@rpc("authority", "reliable")
func s_monster_hp(monster_id: int, hp: int, max_hp: int) -> void:
	combat_view.monster_hp(monster_id, hp, max_hp)

@rpc("authority", "reliable")
func s_break_monster(monster_id: int) -> void:
	combat_view.break_monster(monster_id)

# Player vitals
@rpc("authority", "reliable")
func s_player_hp(peer_id: int, hp: int) -> void:
	players_view.set_player_hp(peer_id, hp)

@rpc("authority", "reliable")
func s_player_died(peer_id: int) -> void:
	ProcLog.lines(["[CLIENT] player_died peer=", peer_id])
	if peer_id == local_peer_id:
		back_to_lobby()

# Lobby envelope
@rpc("authority", "reliable")
func s_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] lobby_response kind=", kind, " ok=", ok])
	emit_signal("lobby_response", kind, ok, payload)

# Client -> Zone intents
func send_move_target(world_pos: Vector3) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.ZONE:
		return
	if not conn.peer_connected():
		return
	rpc_id(1, "c_set_move_target", world_pos)
