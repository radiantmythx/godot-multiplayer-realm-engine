# res://client/ClientMain.gd
extends RpcContract

@export var player_scene: PackedScene
@export var projectile_scene: PackedScene
@export var target_scene: PackedScene

var current_join_ticket := ""
var current_zone_host := ""
var current_zone_port := 0
var current_character_id := 1

var local_peer_id: int = 0

# modules
var net: ClientNet
var world: ClientWorld
var players_view: ClientPlayersView
var combat_view: ClientCombatView
var aim: ClientAim
var input: ClientInput

# Auth/session
var jwt_token: String = ""
var is_realm_authed: bool = false
var auth_account_id: int = 0
var auth_username: String = ""

enum ConnKind { NONE, REALM, ZONE }
var conn_kind: ConnKind = ConnKind.NONE

@export var login_screen_scene: PackedScene
var login_ui: Control

# lobby state
var last_zone_list: Array = []

# ---- Zone watchdog ----
var last_zone_packet_ms: int = 0
var zone_watchdog: Timer
const ZONE_TIMEOUT_MS := 2500

# Generic lobby envelope (Pattern B)
signal lobby_response(kind: String, ok: bool, payload: Dictionary)

func _ready() -> void:
	set_process_input(true)
	ProcLog.lines(["[CLIENT] path: ", get_path()])
	ProcLog.lines(["[CLIENT] rpc root name=", name, " path=", get_path()])

	# build modules
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

	# wire net signals
	net.realm_connected.connect(_on_realm_connected)
	net.zone_connected.connect(_on_zone_connected)

	net.zone_disconnected.connect(func(): _on_zone_lost("server_disconnected"))
	net.zone_connection_failed.connect(func(): _on_zone_lost("connection_failed"))

	net.realm_disconnected.connect(func(): _on_realm_lost("realm_disconnected"))
	net.realm_connection_failed.connect(func(): _on_realm_lost("realm_connection_failed"))

	# watchdog timer (always running)
	zone_watchdog = Timer.new()
	zone_watchdog.wait_time = 0.25
	zone_watchdog.one_shot = false
	zone_watchdog.timeout.connect(_zone_watchdog_tick)
	add_child(zone_watchdog)
	zone_watchdog.start()

	# Show login UI overlay
	if login_screen_scene == null:
		push_error("[CLIENT] login_screen_scene not assigned on ClientMain.tscn!")
		return

	add_to_group("client_main")

	login_ui = login_screen_scene.instantiate()
	add_child(login_ui)

	# Connect to Realm immediately (Option B: Realm is the gateway)
	# NOTE: set_realm will be overridden later by config; for now keep localhost dev.
	net.set_realm("127.0.0.1", 1909)
	net.connect_realm(multiplayer)

	# LoginScreen must have signal login_success(token, account_id, username)
	login_ui.login_success.connect(func(token: String, account_id: int, username: String):
		begin_with_token(token, account_id, username)

		if login_ui.has_method("set_authed"):
			login_ui.call("set_authed", true, account_id, username)
	)

# Called by LoginScreen after Realm-gateway auth succeeds
func begin_with_token(token: String, account_id: int, username: String) -> void:
	jwt_token = token
	auth_account_id = account_id
	auth_username = username

	ProcLog.lines(["[CLIENT] begin_with_token account=", account_id, " user=", username])

	# If we're already connected to Realm, authenticate now.
	# If not connected yet, _on_realm_connected will authenticate when it does connect.
	if conn_kind == ConnKind.REALM and _peer_connected():
		_send_realm_authenticate()

# ---------------- Connection helpers ----------------

func _peer_connected() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	var p := multiplayer.multiplayer_peer
	if p is ENetMultiplayerPeer:
		return p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED
	return true

func _send_realm_authenticate() -> void:
	is_realm_authed = false

	if jwt_token.is_empty():
		# Not logged in yet; that's OK in Option B (we still stay connected to Realm)
		return

	ProcLog.lines(["[CLIENT] Sending c_authenticate to Realm..."])
	rpc_id(1, "c_authenticate", jwt_token)

func _mark_zone_packet() -> void:
	last_zone_packet_ms = Time.get_ticks_msec()

func _zone_watchdog_tick() -> void:
	if conn_kind != ConnKind.ZONE:
		return

	if not _peer_connected():
		_on_zone_lost("peer_not_connected")
		return

	var now := Time.get_ticks_msec()
	if last_zone_packet_ms > 0 and (now - last_zone_packet_ms) > ZONE_TIMEOUT_MS:
		_on_zone_lost("snapshot_timeout")

# ---------------- Input / tick ----------------

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		back_to_lobby()
		return

	if conn_kind != ConnKind.ZONE:
		return
	if not _peer_connected():
		return

	input.handle_input_event(event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_try_fire_at_screen(event.position)

func _process(dt: float) -> void:
	if conn_kind != ConnKind.ZONE:
		return
	if not _peer_connected():
		return

	input.tick(dt)
	if input.is_holding_move():
		_send_move_intent_at_screen(input.get_hold_screen_pos())

# ---------------- Net callbacks ----------------

func _on_realm_connected() -> void:
	conn_kind = ConnKind.REALM

	ProcLog.lines(["[CLIENT] Realm connected"])
	_send_realm_authenticate()

	# If your UI wants to show "connected", do it here:
	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Connected to Realm.")

func _on_zone_connected() -> void:
	conn_kind = ConnKind.ZONE
	_mark_zone_packet()

	ProcLog.lines(["[CLIENT] Connected to Zone. Joining instance..."])
	if _peer_connected():
		rpc_id(1, "c_join_instance", current_join_ticket, current_character_id)

func _on_realm_lost(reason: String) -> void:
	if conn_kind == ConnKind.REALM:
		conn_kind = ConnKind.NONE
		is_realm_authed = false

		if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
			login_ui.call("set_status", "Realm connection lost: " + reason)

func _on_zone_lost(reason: String) -> void:
	if conn_kind != ConnKind.ZONE:
		return

	ProcLog.lines(["[CLIENT] Zone lost (", reason, ") -> back to lobby"])

	conn_kind = ConnKind.NONE
	local_peer_id = 0

	if input and input.has_method("cancel_holding_move"):
		input.call("cancel_holding_move")

	back_to_lobby()

	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Zone disconnected (" + reason + "). Back in lobby.")

# ---------------- Lobby helper methods (called by LoginScreen/Lobby UI) ----------------

func request_zone_list() -> void:
	if conn_kind != ConnKind.REALM:
		return
	if not _peer_connected():
		return
	if not is_realm_authed:
		return
	rpc_id(1, "c_request_zone_list")

func request_create_zone(map_id: String, seed: int, capacity: int) -> void:
	if conn_kind != ConnKind.REALM:
		return
	if not _peer_connected():
		return
	if not is_realm_authed:
		return
	rpc_id(1, "c_request_create_zone", map_id, seed, capacity)

func request_join_instance(instance_id: int, character_id: int, character_name: String) -> void:
	if conn_kind != ConnKind.REALM:
		return
	if not _peer_connected():
		return
	if not is_realm_authed:
		return

	current_character_id = character_id

	var safe_name := (character_name if character_name != null else "").strip_edges()
	if safe_name.is_empty():
		safe_name = "Player"

	rpc_id(1, "c_request_enter_instance", instance_id, character_id, safe_name)

func lobby_request(kind: String, payload: Dictionary) -> void:
	# Pattern B: generic lobby request envelope (Realm is our gateway)
	if conn_kind != ConnKind.REALM:
		return
	if not _peer_connected():
		return
	rpc_id(1, "c_lobby_request", kind, payload)

func back_to_lobby() -> void:
	ProcLog.lines(["[CLIENT] Back to lobby requested"])

	# If already connected to Realm, just show UI and refresh
	if conn_kind == ConnKind.REALM:
		if is_instance_valid(login_ui):
			login_ui.visible = true
			if login_ui.has_method("set_status"):
				login_ui.call("set_status", "Back in lobby. Choose a zone.")
		request_zone_list()
		return

	# Best-effort tell the ZONE you’re leaving (only if still connected)
	if conn_kind == ConnKind.ZONE and _peer_connected():
		rpc_id(1, "c_leave_zone")

	# Clear world visuals/state
	local_peer_id = 0
	current_join_ticket = ""
	current_zone_host = ""
	current_zone_port = 0
	last_zone_packet_ms = 0

	players_view.clear()
	combat_view.clear()

	if world and world.has_method("unload_world"):
		world.call("unload_world")

	# Disconnect whatever is current (zone or half-dead)
	net.disconnect_current(multiplayer)

	# Reconnect to realm (dev default)
	conn_kind = ConnKind.NONE
	is_realm_authed = false
	net.set_realm("127.0.0.1", 1909)
	net.connect_realm(multiplayer)

	if is_instance_valid(login_ui):
		login_ui.visible = true
		if login_ui.has_method("set_status"):
			login_ui.call("set_status", "Connecting to Realm...")

# ---------------- RPCs (stay here for checksum safety) ----------------

@rpc("authority", "reliable")
func s_auth_ok(data: Dictionary) -> void:
	is_realm_authed = true
	ProcLog.lines(["[CLIENT] Realm auth ok: ", data])

	# Now that we're authed, populate lobby.
	if conn_kind == ConnKind.REALM and _peer_connected():
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
	last_zone_packet_ms = 0

	players_view.clear()
	combat_view.clear()

	world.load_world(self, str(travel.map_id))

	# swap from realm to zone
	net.disconnect_current(multiplayer)
	net.set_zone(current_zone_host, current_zone_port)
	net.connect_zone(multiplayer)

@rpc("authority", "reliable")
func s_travel_failed(reason: String) -> void:
	push_error("[CLIENT] Travel failed: " + reason)
	if is_instance_valid(login_ui) and login_ui.has_method("set_status"):
		login_ui.call("set_status", "Join failed: " + reason)

@rpc("authority", "reliable")
func s_join_accepted(_data: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] Join accepted!"])
	local_peer_id = int(_data.get("you_peer_id", 0))
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
	_mark_zone_packet()
	players_view.apply_snapshots(snaps)

# ---- projectiles ----

@rpc("authority", "reliable")
func s_spawn_projectile(proj_id: int, _owner_peer: int, xform: Transform3D, _vel: Vector3) -> void:
	combat_view.spawn_projectile(self, world, proj_id, xform)

@rpc("authority", "unreliable")
func s_projectile_snapshots(snaps: Array) -> void:
	_mark_zone_packet()
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

# ---- Pattern B envelope ----

@rpc("authority", "reliable")
func s_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] lobby_response kind=", kind, " ok=", ok])
	emit_signal("lobby_response", kind, ok, payload)

# ---------------- client -> server intents ----------------

func send_move_target(world_pos: Vector3) -> void:
	if conn_kind != ConnKind.ZONE:
		return
	if not _peer_connected():
		return
	rpc_id(1, "c_set_move_target", world_pos)

func _send_move_intent_at_screen(screen_pos: Vector2) -> void:
	var cam := players_view.get_local_camera()
	if cam == null:
		return

	var hit := aim.raycast_plane_y0(cam, screen_pos)
	if hit.has("position"):
		send_move_target(hit.position)

func _try_fire_at_screen(screen_pos: Vector2) -> void:
	if conn_kind != ConnKind.ZONE:
		return
	if not _peer_connected():
		return

	var cam := players_view.get_local_camera()
	if cam == null:
		return
	if local_peer_id <= 0:
		return

	var hit := aim.raycast_plane_y0(cam, screen_pos)
	if not hit.has("position"):
		return

	var target_pos: Vector3 = hit.position
	var lp := players_view.get_local_player()
	var from := lp.global_position if lp else Vector3.ZERO
	var dir := (target_pos - from)
	dir.y = 0.0
	if dir.length() < 0.001:
		return
	dir = dir.normalized()

	rpc_id(1, "c_fire_projectile", from, dir)
