# res://client/input/ClientInput.gd
extends Node
class_name ClientInput

signal move_intent(world_pos: Vector3)
signal fire_intent(screen_pos: Vector2) # we emit screen_pos; caller computes dir using their local_player

var log: Callable = func(_m): pass

var is_move_hold := false
var hold_screen_pos := Vector2.ZERO
var hold_send_hz := 20.0
var hold_accum := 0.0

func handle_input_event(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			is_move_hold = true
			hold_screen_pos = event.position
			# emit immediate "move at cursor" intent
			fire_move_from_hold()
		else:
			is_move_hold = false

	if event is InputEventMouseMotion and is_move_hold:
		hold_screen_pos = event.position

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			fire_intent.emit(event.position)

func tick(dt: float) -> void:
	if not is_move_hold:
		return

	hold_accum += dt
	var interval := 1.0 / hold_send_hz
	while hold_accum >= interval:
		hold_accum -= interval
		fire_move_from_hold()

func fire_move_from_hold() -> void:
	# We emit a signal for "current hold pos"; the owner resolves screen_pos -> world_pos.
	# For simplicity we emit move_intent only after owner resolves. So we do nothing here.
	pass

func get_hold_screen_pos() -> Vector2:
	return hold_screen_pos

func is_holding_move() -> bool:
	return is_move_hold
