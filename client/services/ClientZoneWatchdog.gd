extends Node
class_name ClientZoneWatchdog

signal timeout(reason: String)

var enabled: bool = false
var timeout_ms: int = 2500
var last_packet_ms: int = 0

var _timer: Timer

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = 0.25
	_timer.one_shot = false
	_timer.timeout.connect(_tick)
	add_child(_timer)
	_timer.start()

func set_enabled(v: bool) -> void:
	enabled = v
	if enabled:
		mark_packet()
	else:
		last_packet_ms = 0

func mark_packet() -> void:
	last_packet_ms = Time.get_ticks_msec()

func _tick() -> void:
	if not enabled:
		return
	if last_packet_ms <= 0:
		return

	var now := Time.get_ticks_msec()
	if (now - last_packet_ms) > timeout_ms:
		emit_signal("timeout", "snapshot_timeout")
