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

var jwt_token: String = "" # set this after HTTP login later
var is_realm_authed: bool = false

# auth
var auth: ClientAuth
var auth_account_id: int = 0
var auth_username: String = ""

var has_started: bool = false

@export var login_screen_scene: PackedScene
var login_ui: Control

func begin_with_token(token: String, account_id: int, username: String) -> void:
	if has_started:
		return
	has_started = true

	jwt_token = token
	auth_account_id = account_id
	auth_username = username

	ProcLog.lines(["[CLIENT] begin_with_token account=", account_id, " user=", username])

	# Connect realm now that we have JWT
	net.connect_realm(multiplayer)

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

	# Show login UI overlay
	if login_screen_scene == null:
		push_error("[CLIENT] login_screen_scene not assigned on ClientMain.tscn!")
		return

	login_ui = login_screen_scene.instantiate()
	add_child(login_ui)

	# IMPORTANT: LoginScreen must have signal login_success
	login_ui.login_success.connect(func(token: String, account_id: int, username: String):
		if is_instance_valid(login_ui):
			login_ui.queue_free()
		begin_with_token(token, account_id, username)
	)

func _on_login_ok(token: String, account_id: int, username: String) -> void:
	jwt_token = token
	auth_account_id = account_id
	auth_username = username
	ProcLog.lines(["[CLIENT] Login OK account=", account_id, " user=", username])

	# Now connect to realm
	net.connect_realm(multiplayer)

func _on_login_failed(reason: String) -> void:
	push_error("[CLIENT] Login FAILED: " + reason)

func _input(event: InputEvent) -> void:
	input.handle_input_event(event)

	# right-click fire is emitted as screen_pos
	# (we don't subscribe to signal to keep wiring minimal; we handle it inline)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_try_fire_at_screen(event.position)

func _process(dt: float) -> void:
	# hold-to-move tick
	input.tick(dt)
	if input.is_holding_move():
		_send_move_intent_at_screen(input.get_hold_screen_pos())

func _on_realm_connected() -> void:
	is_realm_authed = false

	if jwt_token == "":
		push_error("[CLIENT] No jwt_token set; cannot authenticate with Realm.")
		return

	ProcLog.lines(["[CLIENT] Sending c_authenticate to Realm..."])
	rpc_id(1, "c_authenticate", jwt_token)

func _on_zone_connected() -> void:
	ProcLog.lines(["[CLIENT] Connected to Zone. Joining instance..."])
	rpc_id(1, "c_join_instance", current_join_ticket, current_character_id)

# ---------------- RPCs (stay here for checksum safety) ----------------

@rpc("authority", "reliable")
func s_auth_ok(data: Dictionary) -> void:
	is_realm_authed = true
	ProcLog.lines(["[CLIENT] Realm auth ok: ", data])
	ProcLog.lines(["[CLIENT] Sending c_request_enter_hub to server..."])
	rpc_id(1, "c_request_enter_hub", current_character_id)

@rpc("authority", "reliable")
func s_travel_to_zone(travel: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] Travel order: ", travel])

	current_zone_host = travel.host
	current_zone_port = int(travel.port)
	current_join_ticket = travel.join_ticket

	# reset per-world visuals
	players_view.clear()
	combat_view.clear()

	world.load_world(self, str(travel.map_id))

	# swap from realm to zone
	net.disconnect_current(multiplayer)
	net.set_zone(current_zone_host, current_zone_port)
	net.connect_zone(multiplayer)

@rpc("authority", "reliable")
func s_travel_failed(_reason: String) -> void:
	pass

@rpc("authority", "reliable")
func s_join_accepted(_data: Dictionary) -> void:
	ProcLog.lines(["[CLIENT] Join accepted!"])
	local_peer_id = int(_data.get("you_peer_id", 0))
	players_view.set_local_peer_id(local_peer_id)
	players_view.try_activate_local_camera(self, world)

@rpc("authority", "reliable")
func s_join_rejected(reason: String) -> void:
	push_error("[CLIENT] Join rejected: %s" % reason)

@rpc("authority", "reliable")
func s_spawn_players_bulk(list: Array) -> void:
	players_view.spawn_players_bulk(self, world, list)

@rpc("authority", "reliable")
func s_spawn_player(peer_id: int, character_id: int, xform: Transform3D) -> void:
	players_view.spawn_player(self, world, peer_id, character_id, xform)

@rpc("authority", "reliable")
func s_despawn_player(peer_id: int) -> void:
	players_view.despawn_player(self, world, peer_id)

@rpc("authority", "unreliable")
func s_apply_snapshots(snaps: Array) -> void:
	players_view.apply_snapshots(snaps)

# ---- projectiles ----

@rpc("authority", "reliable")
func s_spawn_projectile(proj_id: int, _owner_peer: int, xform: Transform3D, _vel: Vector3) -> void:
	combat_view.spawn_projectile(self, world, proj_id, xform)

@rpc("authority", "unreliable")
func s_projectile_snapshots(snaps: Array) -> void:
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

# ---------------- client -> server intents ----------------

func send_move_target(world_pos: Vector3) -> void:
	if multiplayer.multiplayer_peer == null:
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
