# res://client/ClientMain.gd
extends RpcContract

@export var player_scene: PackedScene
@export var projectile_scene: PackedScene
@export var target_scene: PackedScene

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

# services (new)
var session: ClientSession
var conn: ClientConnection
var watchdog: ClientZoneWatchdog
var gameplay: ClientGameplay

@export var login_screen_scene: PackedScene
var login_ui: Control

# lobby state
var last_zone_list: Array = []

# Pattern B: generic lobby envelope
signal lobby_response(kind: String, ok: bool, payload: Dictionary)

func _ready() -> void:
	set_process_input(true)
	ProcLog.lines(["[CLIENT] path: ", get_path()])
	ProcLog.lines(["[CLIENT] rpc root name=", name, " path=", get_path()])

	add_to_group("client_main")

	# -------------------------
	# Build existing modules
	# -------------------------
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
	combat_view.configure(projectile_scene, target_scene)
	add_child(combat_view)

	aim = ClientAim.new()
	add_child(aim)

	input = ClientInput.new()
	input.log = func(m): ProcLog.lines([m])
	add_child(input)

	# -------------------------
	# Build services
	# -------------------------
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

	# -------------------------
	# Wire service signals
	# -------------------------
	conn.realm_connected.connect(_on_realm_connected)
	conn.zone_connected.connect(_on_zone_connected)
	conn.realm_lost.connect(_on_realm_lost)
	conn.zone_lost.connect(_on_zone_lost)

	watchdog.timeout.connect(func(reason: String):
		# only matters if we're currently in zone
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

	# -------------------------
	# UI
	# -------------------------
	if login_screen_scene == null:
		push_error("[CLIENT] login_screen_scene not assigned on ClientMain.tscn!")
		return

	login_ui = login_screen_scene.instantiate()
	add_child(login_ui)

	# LoginScreen must have signal login_success(token, account_id, username)
	login_ui.login_success.connect(func(token: String, account_id: int, username: String):
		begin_with_token(token, account_id, username)
		if login_ui.has_method("set_authed"):
			login_ui.call("set_authed", true, account_id, username)
	)

	# Connect to Realm immediately (Option B: Realm is gateway)
	conn.set_realm("127.0.0.1", 1909)
	conn.connect_realm()

# Called by LoginScreen after Realm-gateway auth succeeds
func begin_with_token(token: String, account_id: int, username: String) -> void:
	session.set_token(token, account_id, username)

	ProcLog.lines(["[CLIENT] begin_with_token account=", account_id, " user=", username])

	# If already connected to Realm, authenticate now.
	# If not connected yet, _on_realm_connected will authenticate when it does connect.
	if conn.conn_kind == ClientConnection.ConnKind.REALM and conn.peer_connected():
		_send_realm_authenticate()

# -------------------------
# Realm auth
# -------------------------
func _send_realm_authenticate() -> void:
	session.set_realm_authed(false)

	if not session.has_token():
		# Not logged in yet; OK in Option B (stay connected to realm)
		return

	ProcLog.lines(["[CLIENT] Sending c_authenticate to Realm..."])
	rpc_id(1, "c_authenticate", session.jwt_token)

# -------------------------
# Input / tick
# -------------------------
func _input(event: InputEvent) -> void:
	# gameplay only when in-zone + connected
	if conn.conn_kind != ClientConnection.ConnKind.ZONE:
		# still allow ESC to go back
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

# -------------------------
# Net callbacks
# -------------------------
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

# -------------------------
# Lobby helper methods (called by LoginScreen/Lobby UI)
# -------------------------
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
	# Pattern B: generic lobby request envelope (Realm is our gateway)
	if conn.conn_kind != ClientConnection.ConnKind.REALM:
		return
	if not conn.peer_connected():
		return
	rpc_id(1, "c_lobby_request", kind, payload)

func back_to_lobby() -> void:
	ProcLog.lines(["[CLIENT] Back to lobby requested"])

	# If already connected to Realm, just show UI and refresh
	if conn.conn_kind == ClientConnection.ConnKind.REALM:
		if is_instance_valid(login_ui):
			login_ui.visible = true
			if login_ui.has_method("set_status"):
				login_ui.call("set_status", "Back in lobby. Choose a zone.")
		request_zone_list()
		return

	# Best-effort tell the ZONE you’re leaving (only if still connected)
	if conn.conn_kind == ClientConnection.ConnKind.ZONE and conn.peer_connected():
		rpc_id(1, "c_leave_zone")

	# Clear world visuals/state
	local_peer_id = 0
	current_join_ticket = ""
	current_zone_host = ""
	current_zone_port = 0

	watchdog.set_enabled(false)

	players_view.clear()
	combat_view.clear()

	if world and world.has_method("unload_world"):
		world.call("unload_world")

	# Disconnect whatever is current (zone or half-dead)
	conn.disconnect_current()

	# Reconnect to realm (dev default)
	session.set_realm_authed(false)
	conn.set_realm("127.0.0.1", 1909)
	conn.connect_realm()

	if is_instance_valid(login_ui):
		login_ui.visible = true
		if login_ui.has_method("set_status"):
			login_ui.call("set_status", "Connecting to Realm...")

# -------------------------
# RPCs (stay here for checksum safety)
# -------------------------
@rpc("authority", "reliable")
func s_auth_ok(data: Dictionary) -> void:
	session.set_realm_authed(true)
	ProcLog.lines(["[CLIENT] Realm auth ok: ", data])

	# Now that we're authed, populate lobby.
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

	# swap from realm to zone
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
	
@rpc("authority", "reliable")
func s_player_hp(peer_id: int, hp: int) -> void:
	# For now, just log. Later: update UI health bars.
	# Only trust server.
	ProcLog.lines(["[CLIENT] player_hp peer=", peer_id, " hp=", hp])

@rpc("authority", "reliable")
func s_player_died(peer_id: int) -> void:
	ProcLog.lines(["[CLIENT] player_died peer=", peer_id])

	# If *you* died, immediately go back to lobby (your requested behavior)
	if peer_id == local_peer_id:
		back_to_lobby()

# ---- projectiles ----
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

# ---- targets ----
@rpc("authority", "reliable")
func s_spawn_target(target_id: int, xform: Transform3D, _hp: int) -> void:
	combat_view.spawn_target(self, world, target_id, xform)

@rpc("authority", "reliable")
func s_target_hp(_target_id: int, _hp: int) -> void:
	pass

@rpc("authority", "reliable")
func s_break_target(target_id: int) -> void:
	combat_view.break_target(target_id)
	
@rpc("authority", "unreliable")
func s_target_snapshots(snaps: Array) -> void:
	watchdog.mark_packet()
	combat_view.target_snapshots(snaps)

# ---- Pattern B envelope ----
@rpc("authority", "reliable")
func s_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] lobby_response kind=", kind, " ok=", ok])
	emit_signal("lobby_response", kind, ok, payload)

# -------------------------
# client -> server intents
# -------------------------
func send_move_target(world_pos: Vector3) -> void:
	if conn.conn_kind != ClientConnection.ConnKind.ZONE:
		return
	if not conn.peer_connected():
		return
	rpc_id(1, "c_set_move_target", world_pos)
