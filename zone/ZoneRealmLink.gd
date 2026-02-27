# res://zone/ZoneRealmLink.gd
extends Node
class_name ZoneRealmLink

signal shutdown_requested(reason: String)

var log: Callable = func(_m): pass

var tcp := StreamPeerTCP.new()
var tcp_buf := PackedByteArray()

func connect_to_realm(host: String, port: int) -> void:
	var e := tcp.connect_to_host(host, port)
	if e != OK:
		log.call("[ZONE] Failed connect to Realm TCP: %s" % str(e))
	else:
		log.call("[ZONE] Connected to Realm TCP on %d" % port)

func poll() -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return

	var msgs := NetJson.poll_lines(tcp, tcp_buf)
	for m in msgs:
		_on_realm_msg(m)

func _on_realm_msg(m: Dictionary) -> void:
	if m.get("type", "") == "SHUTDOWN_REQUEST":
		var reason := str(m.get("reason", ""))
		log.call("[ZONE] Shutdown requested by realm: " + reason)
		shutdown_requested.emit(reason)

func send_ready(instance_id: int, port: int, capacity: int) -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	NetJson.send_line(tcp, {
		"type": "READY",
		"instance_id": instance_id,
		"port": port,
		"capacity": capacity
	})

func send_heartbeat(instance_id: int, player_count: int) -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	NetJson.send_line(tcp, {
		"type": "HEARTBEAT",
		"instance_id": instance_id,
		"player_count": player_count
	})

func send_shutdown(instance_id: int) -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	NetJson.send_line(tcp, {
		"type": "SHUTDOWN",
		"instance_id": instance_id
	})
