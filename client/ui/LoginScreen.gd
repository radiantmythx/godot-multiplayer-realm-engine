# res://ui/LoginScreen.gd
extends Control

signal login_success(token: String, account_id: int, username: String)

# -------------------------
# Scene tree (new structure)
# -------------------------
@onready var user_login_container: Control = $Panel/VBox/UserLoginContainer
@onready var mode_row: Control = $Panel/VBox/UserLoginContainer/ModeRow
@onready var mode_opt: OptionButton = $Panel/VBox/UserLoginContainer/ModeRow/Mode
@onready var username_edit: LineEdit = $Panel/VBox/UserLoginContainer/Username
@onready var email_edit: LineEdit = $Panel/VBox/UserLoginContainer/Email
@onready var password_edit: LineEdit = $Panel/VBox/UserLoginContainer/Password
@onready var login_btn: Button = $Panel/VBox/UserLoginContainer/LoginButton

@onready var logout_container: Control = $Panel/VBox/LogoutContainer
@onready var logout_btn: Button = $Panel/VBox/LogoutContainer/LogoutButton

@onready var characters_container: Control = $Panel/VBox/CharactersContainer
@onready var char_label: Control = $Panel/VBox/CharactersContainer/CharLabel
@onready var chars_list: ItemList = $Panel/VBox/CharactersContainer/CharactersList
@onready var char_name_edit: LineEdit = $Panel/VBox/CharactersContainer/CharacterName
@onready var char_create_btn: Button = $Panel/VBox/CharactersContainer/CreateCharacterButton
@onready var char_delete_btn: Button = $Panel/VBox/CharactersContainer/DeleteCharacterButton

@onready var zones_container: Control = $Panel/VBox/ZonesContainer
@onready var zone_label: Control = $Panel/VBox/ZonesContainer/ZoneLabel
@onready var zones_list: ItemList = $Panel/VBox/ZonesContainer/ZonesList
@onready var refresh_btn: Button = $Panel/VBox/ZonesContainer/RefreshZonesButton
@onready var join_btn: Button = $Panel/VBox/ZonesContainer/JoinZoneButton
@onready var create_btn: Button = $Panel/VBox/ZonesContainer/CreateZoneButton

@onready var status_lbl: Label = $Panel/VBox/StatusContainer/Status

# -------------------------
# Modules
# -------------------------
var auth: ClientAuth
var chars_api: ClientCharacters

const MODE_LOGIN := 0
const MODE_REGISTER := 1

var _is_authed := false
var _account_id := 0
var _username := ""
var _token := ""

var _refresh_timer: Timer
var _zones: Array = []        # last zone list from realm
var _characters: Array = []   # last character list from API
var _selected_character_id: int = 0
var _selected_character_name: String = "" # NEW

func _ready() -> void:
	status_lbl.text = ""

	# Auth helper (HTTP)
	auth = ClientAuth.new()
	auth.log = func(m): ProcLog.lines([m])
	add_child(auth)
	auth.auth_ok.connect(_on_auth_ok)
	auth.auth_failed.connect(_on_auth_failed)

	# Characters helper (HTTP)
	chars_api = ClientCharacters.new()
	chars_api.log = func(m): ProcLog.lines([m])
	add_child(chars_api)
	chars_api.list_ok.connect(_on_chars_list_ok)
	chars_api.create_ok.connect(_on_chars_create_ok)
	chars_api.delete_ok.connect(_on_chars_delete_ok)
	chars_api.request_failed.connect(_on_chars_failed)

	# Mode selector
	mode_opt.clear()
	mode_opt.add_item("Login", MODE_LOGIN)
	mode_opt.add_item("Register", MODE_REGISTER)
	mode_opt.selected = MODE_LOGIN
	mode_opt.item_selected.connect(_on_mode_changed)
	_on_mode_changed(mode_opt.selected)

	# Login inputs
	login_btn.pressed.connect(_on_submit)
	username_edit.text_submitted.connect(func(_t): _on_submit())
	email_edit.text_submitted.connect(func(_t): _on_submit())
	password_edit.text_submitted.connect(func(_t): _on_submit())

	# Logout
	logout_btn.pressed.connect(_logout)

	# Character UI
	chars_list.clear()
	chars_list.item_selected.connect(func(_i): _on_character_selected())
	char_create_btn.pressed.connect(_create_character)
	char_delete_btn.pressed.connect(_delete_character)

	# Zone UI
	zones_list.clear()
	zones_list.item_selected.connect(func(_i): _sync_gate_visibility_and_enabled())
	refresh_btn.pressed.connect(_refresh_zones)
	join_btn.pressed.connect(_join_selected_zone)
	create_btn.pressed.connect(_create_zone)

	# Refresh timer for zones (only runs while authed)
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 2.0
	_refresh_timer.one_shot = false
	_refresh_timer.timeout.connect(_refresh_zones)
	add_child(_refresh_timer)

	_apply_logged_out_ui()

# Optional hooks from outside
func set_authed(enabled: bool, account_id: int = 0, username: String = "") -> void:
	_is_authed = enabled
	_account_id = account_id
	_username = username
	_sync_gate_visibility_and_enabled()

func set_status(text: String) -> void:
	status_lbl.text = text

func set_zone_list(zones: Array) -> void:
	_on_zone_list(zones)

func _get_client_main() -> Node:
	return get_tree().get_first_node_in_group("client_main")

# -------------------------
# Login/Register flow
# -------------------------
func _on_mode_changed(_idx: int) -> void:
	if _is_authed:
		return
	var is_register := mode_opt.get_selected_id() == MODE_REGISTER
	email_edit.visible = is_register
	login_btn.text = "Create Account" if is_register else "Login"
	status_lbl.text = ""

func _on_submit() -> void:
	if _is_authed:
		return

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
	login_btn.disabled = false

	emit_signal("login_success", token, account_id, username)

	status_lbl.text = "Logged in. Loading characters..."

	_selected_character_id = 0
	_selected_character_name = "" # NEW
	_characters.clear()
	chars_list.clear()
	_zones.clear()
	zones_list.clear()

	_apply_logged_in_ui()

	# Load characters
	chars_api.list_characters(_token)

	# Start refresh loop (realm will connect shortly)
	if _refresh_timer:
		_refresh_timer.start()
	_refresh_zones()

func _on_auth_failed(reason: String) -> void:
	login_btn.disabled = false
	status_lbl.text = "Failed: " + reason

# -------------------------
# Logout flow
# -------------------------
func _logout() -> void:
	if not _is_authed:
		return

	if _refresh_timer:
		_refresh_timer.stop()

	_is_authed = false
	_token = ""
	_account_id = 0
	_username = ""
	_selected_character_id = 0
	_selected_character_name = "" # NEW

	_characters.clear()
	chars_list.clear()
	char_name_edit.text = ""

	_zones.clear()
	zones_list.clear()

	# Reset login form a bit
	password_edit.text = ""
	_on_mode_changed(mode_opt.selected)

	status_lbl.text = "Logged out."
	_apply_logged_out_ui()

	var cm := _get_client_main()
	if cm and cm.has_method("on_logout"):
		cm.call("on_logout")

# -------------------------
# UI gating / visibility
# -------------------------
func _apply_logged_out_ui() -> void:
	# Show login; hide everything else
	user_login_container.visible = true
	logout_container.visible = false
	characters_container.visible = false
	zones_container.visible = false

	# Enable/disable
	login_btn.disabled = false
	char_create_btn.disabled = true
	char_delete_btn.disabled = true
	refresh_btn.disabled = true
	create_btn.disabled = true
	join_btn.disabled = true

func _apply_logged_in_ui() -> void:
	# Hide login; show logout + characters
	user_login_container.visible = false
	logout_container.visible = true
	characters_container.visible = true

	# Zones stay hidden until character selected
	zones_container.visible = false

	# Enable/disable
	char_create_btn.disabled = false
	char_delete_btn.disabled = true
	refresh_btn.disabled = true
	create_btn.disabled = true
	join_btn.disabled = true

func _sync_gate_visibility_and_enabled() -> void:
	if not _is_authed:
		_apply_logged_out_ui()
		return

	# Logged in always shows logout + characters
	user_login_container.visible = false
	logout_container.visible = true
	characters_container.visible = true

	var has_char := _selected_character_id > 0
	zones_container.visible = has_char

	# Character controls
	char_create_btn.disabled = false
	char_delete_btn.disabled = not has_char

	# Zone controls (only usable once character selected)
	refresh_btn.disabled = not has_char
	create_btn.disabled = not has_char

	# Join requires zone selection too
	var has_zone := has_char and not zones_list.get_selected_items().is_empty()
	join_btn.disabled = not has_zone

# -------------------------
# Zone list
# -------------------------
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

	_sync_gate_visibility_and_enabled()

func _join_selected_zone() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return
	if _selected_character_id <= 0:
		status_lbl.text = "Select a character."
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
		cm.call("request_join_instance", instance_id, _selected_character_id, _selected_character_name) # NEW

func _create_zone() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return
	if _selected_character_id <= 0:
		status_lbl.text = "Select a character first."
		return

	var map_id := "res://maps/HubMap.tscn"
	var seed := randi()
	var capacity := 32

	status_lbl.text = "Creating zone..."

	var cm := _get_client_main()
	if cm and cm.has_method("request_create_zone"):
		cm.call("request_create_zone", map_id, seed, capacity)

# -------------------------
# Characters UI + API
# -------------------------
func _on_chars_list_ok(list: Array) -> void:
	_characters = list
	_render_characters()

	_selected_character_id = 0
	_selected_character_name = "" # NEW
	zones_list.deselect_all()
	status_lbl.text = "Select a character."
	_sync_gate_visibility_and_enabled()

func _on_chars_create_ok(_character: Dictionary) -> void:
	chars_api.list_characters(_token)

func _on_chars_delete_ok(_character_id: int) -> void:
	_selected_character_id = 0
	_selected_character_name = "" # NEW
	zones_list.deselect_all()
	chars_api.list_characters(_token)
	_sync_gate_visibility_and_enabled()

func _on_chars_failed(reason: String) -> void:
	status_lbl.text = "Characters: " + reason

func _render_characters() -> void:
	chars_list.clear()

	_characters.sort_custom(func(a, b):
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)

	for ch in _characters:
		var id := int(ch.get("id", 0))
		var name := str(ch.get("name", ""))
		var cls := str(ch.get("classId", ch.get("class_id", "")))
		var lvl := int(ch.get("level", 1))
		chars_list.add_item("#%d  %s  (%s Lv%d)" % [id, name, cls, lvl])

func _on_character_selected() -> void:
	var sel := chars_list.get_selected_items()
	if sel.is_empty():
		_selected_character_id = 0
		_selected_character_name = "" # NEW
	else:
		var ch = _characters[int(sel[0])]
		_selected_character_id = int(ch.get("id", 0))
		_selected_character_name = str(ch.get("name", "")) # NEW
		zones_list.deselect_all()

	_sync_gate_visibility_and_enabled()

	# Nice UX: once a character is selected, fetch zones immediately
	if _selected_character_id > 0:
		_refresh_zones()

func _create_character() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return

	var name := char_name_edit.text.strip_edges()
	if name == "":
		status_lbl.text = "Enter a character name."
		return

	status_lbl.text = "Creating character..."
	chars_api.create_character(_token, name, "templar")
	char_name_edit.text = ""

func _delete_character() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return
	if _selected_character_id <= 0:
		status_lbl.text = "Select a character to delete."
		return

	status_lbl.text = "Deleting character..."
	chars_api.delete_character(_token, _selected_character_id)
