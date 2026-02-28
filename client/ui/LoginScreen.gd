extends Control

signal login_success(token: String, account_id: int, username: String)

@onready var mode_opt: OptionButton = $Panel/VBox/ModeRow/Mode
@onready var username_edit: LineEdit = $Panel/VBox/Username
@onready var email_edit: LineEdit = $Panel/VBox/Email
@onready var password_edit: LineEdit = $Panel/VBox/Password
@onready var login_btn: Button = $Panel/VBox/LoginButton
@onready var status_lbl: Label = $Panel/VBox/Status

@onready var zones_list: ItemList = $Panel/VBox/ZonesList
@onready var refresh_btn: Button = $Panel/VBox/RefreshZonesButton
@onready var join_btn: Button = $Panel/VBox/JoinZoneButton
@onready var create_btn: Button = $Panel/VBox/CreateZoneButton

var auth: ClientAuth

const MODE_LOGIN := 0
const MODE_REGISTER := 1

var _is_authed := false
var _account_id := 0
var _username := ""
var _token := ""
var _refresh_timer: Timer


var _zones: Array = [] # last zone list from realm

func _ready() -> void:
	status_lbl.text = ""

	# Auth helper (HTTP)
	auth = ClientAuth.new()
	auth.log = func(m): ProcLog.lines([m])
	add_child(auth)
	auth.auth_ok.connect(_on_auth_ok)
	auth.auth_failed.connect(_on_auth_failed)

	# Mode selector
	mode_opt.clear()
	mode_opt.add_item("Login", MODE_LOGIN)
	mode_opt.add_item("Register", MODE_REGISTER)
	mode_opt.selected = MODE_LOGIN
	mode_opt.item_selected.connect(_on_mode_changed)
	_on_mode_changed(mode_opt.selected)

	login_btn.pressed.connect(_on_submit)

	username_edit.text_submitted.connect(func(_t): _on_submit())
	email_edit.text_submitted.connect(func(_t): _on_submit())
	password_edit.text_submitted.connect(func(_t): _on_submit())

	# Zone UI
	zones_list.clear()
	refresh_btn.pressed.connect(_refresh_zones)
	join_btn.pressed.connect(_join_selected_zone)
	create_btn.pressed.connect(_create_zone)

	_set_lobby_buttons_enabled(false)

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 2.0
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_refresh_zones)
	add_child(_refresh_timer)
	# DO NOT start yet

func set_authed(enabled: bool, account_id: int = 0, username: String = "") -> void:
	_is_authed = enabled
	_account_id = account_id
	_username = username
	_set_lobby_buttons_enabled(enabled)

func set_status(text: String) -> void:
	status_lbl.text = text

func set_zone_list(zones: Array) -> void:
	_on_zone_list(zones)

func _get_client_main() -> Node:
	var n := get_tree().get_first_node_in_group("client_main")
	return n

func _on_mode_changed(_idx: int) -> void:
	var is_register := mode_opt.get_selected_id() == MODE_REGISTER
	email_edit.visible = is_register
	login_btn.text = "Create Account" if is_register else "Login"
	status_lbl.text = ""

func _on_submit() -> void:
	var is_register := mode_opt.get_selected_id() == MODE_REGISTER

	var u := username_edit.text.strip_edges()
	var p := password_edit.text
	var e := email_edit.text.strip_edges()

	if u == "" or p == "":
		status_lbl.text = "Enter username and password."
		return

	if is_register and e == "":
		status_lbl.text = "Enter email to register."
		return

	login_btn.disabled = true
	status_lbl.text = "Working..."

	if is_register:
		auth.register(u, e, p)
	else:
		auth.login(u, p)

func _on_auth_ok(token: String, account_id: int, username: String) -> void:
	_is_authed = true
	_token = token
	_account_id = account_id
	_username = username

	status_lbl.text = "Logged in. Select a zone to join."
	login_btn.disabled = false
	_set_lobby_buttons_enabled(true)

	emit_signal("login_success", token, account_id, username)

	# Start refresh loop now (client will connect to realm next)
	if _refresh_timer:
		_refresh_timer.start()

	# Try one refresh (will no-op until connected because of ClientMain guard)
	_refresh_zones()

func _on_auth_failed(reason: String) -> void:
	login_btn.disabled = false
	status_lbl.text = "Failed: " + reason

func _set_lobby_buttons_enabled(enabled: bool) -> void:
	join_btn.disabled = not enabled
	create_btn.disabled = not enabled

func _refresh_zones() -> void:
	var cm := _get_client_main()
	if cm == null:
		return
	if cm.has_method("request_zone_list"):
		cm.call("request_zone_list")

func _on_zone_list(zones: Array) -> void:
	_zones = zones
	zones_list.clear()

	_zones.sort_custom(func(a, b):
		var cs := str(a.get("status", ""))
		var bs := str(b.get("status", ""))
		if cs != bs:
			return cs == "RUNNING"
		return int(a.get("player_count", 0)) > int(b.get("player_count", 0))
	)

	for z in _zones:
		var status := str(z.get("status", ""))
		var pc := int(z.get("player_count", 0))
		var cap := int(z.get("capacity", 0))
		var map_id := str(z.get("map_id", ""))
		var iid := int(z.get("instance_id", 0))
		var port := int(z.get("port", 0))

		var label := "[%s] %d/%d  %s  (iid=%d port=%d)" % [status, pc, cap, map_id.get_file(), iid, port]
		zones_list.add_item(label)

func _join_selected_zone() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return

	var sel := zones_list.get_selected_items()
	if sel.is_empty():
		status_lbl.text = "Select a zone."
		return

	var z = _zones[int(sel[0])]
	var instance_id := int(z.get("instance_id", 0))
	if instance_id <= 0:
		status_lbl.text = "Invalid zone."
		return

	status_lbl.text = "Joining zone..."

	var cm := _get_client_main()
	if cm and cm.has_method("request_join_instance"):
		cm.call("request_join_instance", instance_id, 1)

func _create_zone() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return

	var map_id := "res://maps/HubMap.tscn"
	var seed := randi()
	var capacity := 32

	status_lbl.text = "Creating zone..."

	var cm := _get_client_main()
	if cm and cm.has_method("request_create_zone"):
		cm.call("request_create_zone", map_id, seed, capacity)
