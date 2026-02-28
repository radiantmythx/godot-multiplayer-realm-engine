# res://zone/ZoneRealmLink.gd
extends Node
class_name ZoneRealmLink

signal shutdown_requested(reason: String)

var log: Callable = func(_m): pass

var tcp := StreamPeerTCP.new()
var tcp_buf := PackedByteArray()

var _last_status: int = -999
var _target_host: String = ""
var _target_port: int = 0

func connect_to_realm(host: String, port: int) -> void:
	_target_host = host
	_target_port = port

	var e := tcp.connect_to_host(host, port)
	if e != OK:
		log.call("[ZONE] Failed connect_to_host %s:%d err=%s" % [host, port, str(e)])
	else:
		log.call("[ZONE] connect_to_host issued for %s:%d" % [host, port])

	_last_status = -999 # force status log on next poll

func realm_tcp_connected() -> bool:
	return tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED

func poll() -> void:
	# IMPORTANT: StreamPeerTCP requires polling to advance connection state in Godot 4
	tcp.poll()

	var st := tcp.get_status()
	if st != _last_status:
		_last_status = st
		log.call("[ZONE] Realm TCP status -> %s" % _status_name(st))

	# only read when connected
	if st != StreamPeerTCP.STATUS_CONNECTED:
		return

	var r := NetJson.poll_lines(tcp, tcp_buf)
	tcp_buf = r.buffer
	for m in r.msgs:
		_on_realm_msg(m)

func _on_realm_msg(m: Dictionary) -> void:
	if m.get("type", "") == "SHUTDOWN_REQUEST":
		var reason := str(m.get("reason", ""))
		log.call("[ZONE] Shutdown requested by realm: " + reason)
		shutdown_requested.emit(reason)

func send_ready(instance_id: int, port: int, capacity: int) -> void:
	if not realm_tcp_connected():
		return
	NetJson.send_line(tcp, {
		"type": "READY",
		"instance_id": instance_id,
		"port": port,
		"capacity": capacity
	})

func send_heartbeat(instance_id: int, player_count: int) -> void:
	if not realm_tcp_connected():
		return
	NetJson.send_line(tcp, {
		"type": "HEARTBEAT",
		"instance_id": instance_id,
		"player_count": player_count
	})

func send_shutdown(instance_id: int) -> void:
	if not realm_tcp_connected():
		return
	NetJson.send_line(tcp, {
		"type": "SHUTDOWN",
		"instance_id": instance_id
	})

func _status_name(st: int) -> String:
	match st:
		StreamPeerTCP.STATUS_NONE:
			return "NONE"
		StreamPeerTCP.STATUS_CONNECTING:
			return "CONNECTING"
		StreamPeerTCP.STATUS_CONNECTED:
			return "CONNECTED"
		StreamPeerTCP.STATUS_ERROR:
			return "ERROR"
		_:
			return "UNKNOWN(%d)" % st
