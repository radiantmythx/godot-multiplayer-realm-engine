extends Node
class_name ClientGameplay

signal want_move_target(world_pos: Vector3)
signal want_fire_projectile(from: Vector3, dir: Vector3)
signal want_back_to_lobby

var log: Callable = func(_m): pass

var aim: ClientAim
var input: ClientInput
var players_view: ClientPlayersView

var local_peer_id: int = 0

func configure(pv: ClientPlayersView, aim_node: ClientAim, input_node: ClientInput) -> void:
	players_view = pv
	aim = aim_node
	input = input_node

func set_local_peer_id(pid: int) -> void:
	local_peer_id = pid

func handle_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		emit_signal("want_back_to_lobby")
		return

	input.handle_input_event(event)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_try_fire_at_screen(event.position)

func tick(dt: float) -> void:
	input.tick(dt)
	if input.is_holding_move():
		_send_move_intent_at_screen(input.get_hold_screen_pos())

func _send_move_intent_at_screen(screen_pos: Vector2) -> void:
	var cam := players_view.get_local_camera()
	if cam == null:
		return

	var hit := aim.raycast_plane_y0(cam, screen_pos)
	if hit.has("position"):
		emit_signal("want_move_target", hit.position)

func _try_fire_at_screen(screen_pos: Vector2) -> void:
	if local_peer_id <= 0:
		return

	var cam := players_view.get_local_camera()
	if cam == null:
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

	emit_signal("want_fire_projectile", from, dir)
