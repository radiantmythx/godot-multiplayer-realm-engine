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

# Maps UI
@onready var maps_container: Control = $Panel/VBox/MapsContainer
@onready var maps_label: Control = $Panel/VBox/MapsContainer/MapsLabel
@onready var maps_list: ItemList = $Panel/VBox/MapsContainer/MapsList

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

const MODE_LOGIN := 0
const MODE_REGISTER := 1

var _is_authed := false
var _account_id := 0
var _username := ""
var _token := "" # still stored for display / future use; Realm is the source of truth now

var _refresh_timer: Timer
var _zones: Array = []        # last zone list from realm
var _characters: Array = []   # last character list from Realm->API
var _selected_character_id: int = 0
var _selected_character_name: String = ""

# maps state
var _maps: Array = [] # Array[Dictionary]
var _selected_map_scene_path: String = "" # passed to Realm as map_id (scene path)

const DEFAULT_HUB_SCENE := "res://maps/HubMap.tscn"

# simple throttling for lobby gateway (since Realm HTTP is single-flight)
var _retry_timer: Timer
var _pending_lobby_kind: String = "" # "" means idle
var _pending_after: Array[String] = [] # kinds to request after current succeeds (optional)

func _ready() -> void:
	status_lbl.text = ""

	# Auth helper (now expected to use lobby gateway internally, not direct API)
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

	# Maps UI
	maps_list.clear()
	maps_list.item_selected.connect(func(_i): _on_map_selected())

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

	# Retry timer for "rate_limited"
	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	_retry_timer.wait_time = 0.25
	_retry_timer.timeout.connect(_retry_pending_lobby)
	add_child(_retry_timer)

	# Connect to ClientMain lobby_response signal
	_try_bind_client_main()

	_apply_logged_out_ui()

func _try_bind_client_main() -> void:
	var cm := _get_client_main()
	if cm == null:
		return
	# Avoid double connect
	if cm.is_connected("lobby_response", Callable(self, "_on_lobby_response")):
		return
	cm.connect("lobby_response", Callable(self, "_on_lobby_response"))

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

	_try_bind_client_main()

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

	status_lbl.text = "Logged in. Loading characters & maps..."

	_selected_character_id = 0
	_selected_character_name = ""
	_characters.clear()
	chars_list.clear()

	_maps.clear()
	maps_list.clear()
	_selected_map_scene_path = ""

	_zones.clear()
	zones_list.clear()

	_pending_lobby_kind = ""
	_pending_after.clear()
	if _retry_timer:
		_retry_timer.stop()

	_apply_logged_in_ui()

	# IMPORTANT: serialize requests to avoid Realm HTTP single-flight collisions
	_request_maps_then_chars()

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
	_selected_character_name = ""

	_characters.clear()
	chars_list.clear()
	char_name_edit.text = ""

	_maps.clear()
	maps_list.clear()
	_selected_map_scene_path = ""

	_zones.clear()
	zones_list.clear()

	_pending_lobby_kind = ""
	_pending_after.clear()
	if _retry_timer:
		_retry_timer.stop()

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
	user_login_container.visible = true
	logout_container.visible = false
	characters_container.visible = false
	maps_container.visible = false
	zones_container.visible = false

	login_btn.disabled = false
	char_create_btn.disabled = true
	char_delete_btn.disabled = true
	refresh_btn.disabled = true
	create_btn.disabled = true
	join_btn.disabled = true

func _apply_logged_in_ui() -> void:
	user_login_container.visible = false
	logout_container.visible = true
	characters_container.visible = true
	maps_container.visible = true
	zones_container.visible = false

	char_create_btn.disabled = false
	char_delete_btn.disabled = true
	refresh_btn.disabled = true
	create_btn.disabled = true
	join_btn.disabled = true

func _sync_gate_visibility_and_enabled() -> void:
	if not _is_authed:
		_apply_logged_out_ui()
		return

	user_login_container.visible = false
	logout_container.visible = true
	characters_container.visible = true
	maps_container.visible = true

	var has_char := _selected_character_id > 0
	zones_container.visible = has_char

	char_create_btn.disabled = false
	char_delete_btn.disabled = not has_char

	refresh_btn.disabled = not has_char
	create_btn.disabled = not has_char

	var has_zone := has_char and not zones_list.get_selected_items().is_empty()
	join_btn.disabled = not has_zone

# -------------------------
# Lobby gateway helpers (ClientMain <-> Realm)
# -------------------------
func _lobby_request(kind: String, payload: Dictionary) -> void:
	var cm := _get_client_main()
	if cm == null:
		status_lbl.text = "ClientMain not found."
		return

	# simple "one at a time" from UI side too (helps reduce collisions)
	if _pending_lobby_kind != "":
		# queue replacement behavior: last request wins
		_pending_after.clear()
		_pending_after.append(kind + "|" + JSON.stringify(payload))
		return

	_pending_lobby_kind = kind
	cm.call("lobby_request", kind, payload)

func _retry_pending_lobby() -> void:
	if _pending_lobby_kind == "":
		return
	# Just re-send the same pending request by asking ClientMain again is tricky (we don't store payload).
	# So for retries we instead re-issue the last "known" sequences.
	# We'll use this only for the startup sequence.
	if _pending_lobby_kind == "maps_list":
		_request_maps_then_chars()
	elif _pending_lobby_kind == "chars_list":
		_request_chars_list()
	elif _pending_lobby_kind == "char_create":
		# user action: let them click again
		status_lbl.text = "Try again."
		_pending_lobby_kind = ""
	elif _pending_lobby_kind == "char_delete":
		status_lbl.text = "Try again."
		_pending_lobby_kind = ""
	else:
		_pending_lobby_kind = ""

func _on_lobby_response(kind: String, ok: bool, payload: Dictionary) -> void:
	# clear pending if it matches (otherwise ignore)
	if kind == _pending_lobby_kind:
		_pending_lobby_kind = ""

	# Handle rate limiting / busy
	if not ok:
		var err := str(payload.get("error", "unknown_error"))
		if err == "rate_limited" or err == "busy":
			# backoff retry for startup list calls
			if kind == "maps_list" or kind == "chars_list":
				status_lbl.text = "%s: %s (retrying...)" % [kind, err]
				if _retry_timer:
					_retry_timer.start()
				_pending_lobby_kind = kind # keep it pending for retry
				return
		# normal error
		if kind.begins_with("char_") or kind == "chars_list":
			status_lbl.text = "Characters: " + err
		elif kind == "maps_list":
			status_lbl.text = "Maps: " + err + " (defaulting to Hub)"
			_maps.clear()
			maps_list.clear()
			_selected_map_scene_path = DEFAULT_HUB_SCENE
		else:
			status_lbl.text = kind + ": " + err
		_sync_gate_visibility_and_enabled()
		return

	# success handlers
	match kind:
		"maps_list":
			var list: Array = payload.get("maps", [])
			_on_maps_list_ok(list)
			# after maps, request characters
			_request_chars_list()

		"chars_list":
			var chars: Array = payload.get("characters", [])
			_on_chars_list_ok(chars)

		"char_create":
			# reload list
			_request_chars_list()

		"char_delete":
			_selected_character_id = 0
			_selected_character_name = ""
			zones_list.deselect_all()
			_request_chars_list()

		_:
			# ignore unknown
			pass

	# if we had a queued "after" request, issue it now
	if _pending_after.size() > 0 and _pending_lobby_kind == "":
		var packed = _pending_after.pop_front()
		var sep = packed.find("|")
		if sep > 0:
			var k = packed.substr(0, sep)
			var js = packed.substr(sep + 1)
			var p = JSON.parse_string(js)
			var d = p if typeof(p) == TYPE_DICTIONARY else {}
			_lobby_request(k, d)

# -------------------------
# Maps list
# -------------------------
func _request_maps_then_chars() -> void:
	_request_maps_list()

func _request_maps_list() -> void:
	_lobby_request("maps_list", {
		"playable": true,
		"hidden": false
	})

func _on_maps_list_ok(list: Array) -> void:
	_maps = list
	_render_maps()
	_auto_select_default_map()
	_sync_gate_visibility_and_enabled()

func _render_maps() -> void:
	maps_list.clear()

	_maps.sort_custom(func(a, b):
		var sa := int(a.get("sortOrder", a.get("sort_order", 0)))
		var sb := int(b.get("sortOrder", b.get("sort_order", 0)))
		if sa != sb:
			return sa < sb
		return int(a.get("id", 0)) < int(b.get("id", 0))
	)

	for m in _maps:
		var name := str(m.get("name", m.get("displayName", m.get("display_name", ""))))
		var kind := str(m.get("kind", ""))
		var scene_path := str(m.get("scenePath", m.get("scene_path", "")))

		var label := name
		if kind != "":
			label += "  [%s]" % kind
		if scene_path == "":
			label += "  (missing scenePath!)"

		maps_list.add_item(label)

func _auto_select_default_map() -> void:
	_selected_map_scene_path = ""

	# Prefer slug == "hub"
	var hub_index := -1
	for i in range(_maps.size()):
		var slug := str(_maps[i].get("slug", ""))
		if slug == "hub":
			hub_index = i
			break

	if hub_index >= 0:
		maps_list.select(hub_index)
		_on_map_selected()
		return

	if _maps.size() > 0:
		maps_list.select(0)
		_on_map_selected()
		return

	_selected_map_scene_path = DEFAULT_HUB_SCENE

func _on_map_selected() -> void:
	var sel := maps_list.get_selected_items()
	if sel.is_empty():
		_selected_map_scene_path = DEFAULT_HUB_SCENE
		return

	var m = _maps[int(sel[0])]
	_selected_map_scene_path = str(m.get("scenePath", m.get("scene_path", ""))).strip_edges()
	if _selected_map_scene_path == "":
		_selected_map_scene_path = DEFAULT_HUB_SCENE

# -------------------------
# Characters list
# -------------------------
func _request_chars_list() -> void:
	_lobby_request("chars_list", {})

func _on_chars_list_ok(list: Array) -> void:
	_characters = list
	_render_characters()

	_selected_character_id = 0
	_selected_character_name = ""
	zones_list.deselect_all()
	status_lbl.text = "Select a character."
	_sync_gate_visibility_and_enabled()

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
		_selected_character_name = ""
	else:
		var ch = _characters[int(sel[0])]
		_selected_character_id = int(ch.get("id", 0))
		_selected_character_name = str(ch.get("name", ""))
		zones_list.deselect_all()

	_sync_gate_visibility_and_enabled()

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

	# serialize UI requests too
	status_lbl.text = "Creating character..."
	char_name_edit.text = ""

	_lobby_request("char_create", {
		"name": name,
		"class_id": "templar"
	})

func _delete_character() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return
	if _selected_character_id <= 0:
		status_lbl.text = "Select a character to delete."
		return

	status_lbl.text = "Deleting character..."
	_lobby_request("char_delete", { "id": _selected_character_id })

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
		cm.call("request_join_instance", instance_id, _selected_character_id, _selected_character_name)

func _create_zone() -> void:
	if not _is_authed:
		status_lbl.text = "Login first."
		return
	if _selected_character_id <= 0:
		status_lbl.text = "Select a character first."
		return

	var map_id := _selected_map_scene_path if _selected_map_scene_path != "" else DEFAULT_HUB_SCENE
	var seed := randi()
	var capacity := 32

	status_lbl.text = "Creating zone..."

	var cm := _get_client_main()
	if cm and cm.has_method("request_create_zone"):
		cm.call("request_create_zone", map_id, seed, capacity)
