extends Control

signal login_success(token: String, account_id: int, username: String)

@onready var mode_opt: OptionButton = $Panel/VBox/ModeRow/Mode
@onready var username_edit: LineEdit = $Panel/VBox/Username
@onready var email_edit: LineEdit = $Panel/VBox/Email
@onready var password_edit: LineEdit = $Panel/VBox/Password
@onready var login_btn: Button = $Panel/VBox/LoginButton
@onready var status_lbl: Label = $Panel/VBox/Status

var auth: ClientAuth

const MODE_LOGIN := 0
const MODE_REGISTER := 1

func _ready() -> void:
	status_lbl.text = ""

	# Build auth helper
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

	# Enter to submit
	username_edit.text_submitted.connect(func(_t): _on_submit())
	email_edit.text_submitted.connect(func(_t): _on_submit())
	password_edit.text_submitted.connect(func(_t): _on_submit())

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
	status_lbl.text = "Success."
	emit_signal("login_success", token, account_id, username)

func _on_auth_failed(reason: String) -> void:
	login_btn.disabled = false
	status_lbl.text = "Failed: " + reason
