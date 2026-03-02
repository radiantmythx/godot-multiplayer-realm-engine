extends Node
class_name ZoneSupervisor

signal zone_ready(instance_id: int, port: int, capacity: int)
signal zone_heartbeat(instance_id: int, player_count: int)
signal zone_shutdown(instance_id: int)
signal zone_disconnected(instance_id: int)

var internal_tcp_port: int = 4001
var listen_host: String = "127.0.0.1"

# internal TCP server for zones
var tcp_server := TCPServer.new()
var zone_peers: Array[StreamPeerTCP] = []
var zone_buffers: Dictionary = {}      # peer_key(string) -> PackedByteArray
var peer_to_instance: Dictionary = {}  # peer_key(string) -> instance_id(int)

func start_tcp(port: int, host: String = "127.0.0.1") -> int:
	internal_tcp_port = port
	listen_host = host
	return tcp_server.listen(internal_tcp_port, listen_host)

func tick() -> void:
	_accept_zone_tcp()
	_poll_zone_tcp()

func _accept_zone_tcp() -> void:
	while tcp_server.is_connection_available():
		var p := tcp_server.take_connection()
		if p:
			zone_peers.append(p)
			var key := str(p.get_instance_id())
			zone_buffers[key] = PackedByteArray()
			ProcLog.lines(["[REALM] Zone TCP connected: ", key])

func _poll_zone_tcp() -> void:
	# iterate backwards so we can remove safely
	for i in range(zone_peers.size() - 1, -1, -1):
		var p := zone_peers[i]
		var status := p.get_status()
		var peer_key := str(p.get_instance_id())

		if status != StreamPeerTCP.STATUS_CONNECTED:
			ProcLog.lines(["[REALM] Zone TCP disconnected: ", peer_key, " status=", status])

			if peer_to_instance.has(peer_key):
				var instance_id := int(peer_to_instance[peer_key])
				peer_to_instance.erase(peer_key)
				emit_signal("zone_disconnected", instance_id)

			zone_buffers.erase(peer_key)
			zone_peers.remove_at(i)
			continue

		var buf: PackedByteArray = zone_buffers.get(peer_key, PackedByteArray())
		var r := NetJson.poll_lines(p, buf)
		zone_buffers[peer_key] = r.buffer

		for m in r.msgs:
			_on_zone_msg(p, m)

func _on_zone_msg(p: StreamPeerTCP, m: Dictionary) -> void:
	var t := str(m.get("type", ""))
	var peer_key := str(p.get_instance_id())

	match t:
		"READY":
			var instance_id := int(m.get("instance_id", -1))
			var port := int(m.get("port", -1))
			var cap := int(m.get("capacity", 0))

			ProcLog.lines(["[REALM] Zone READY instance=", instance_id, " port=", port, " cap=", cap])

			peer_to_instance[peer_key] = instance_id
			emit_signal("zone_ready", instance_id, port, cap)

		"HEARTBEAT":
			var instance_id := int(m.get("instance_id", -1))
			var pc := int(m.get("player_count", 0))
			emit_signal("zone_heartbeat", instance_id, pc)

		"SHUTDOWN":
			var instance_id := int(m.get("instance_id", -1))
			emit_signal("zone_shutdown", instance_id)

		_:
			ProcLog.lines(["[REALM] Unknown zone msg: ", m])

func spawn_zone_process(inst: Dictionary, ticket_secret: String) -> void:
	var exe_path := OS.get_executable_path()

	var log_dir := ProjectSettings.globalize_path("user://zone_logs")
	DirAccess.make_dir_recursive_absolute(log_dir)
	var log_path := "%s/zone_%d_%d.log" % [log_dir, int(inst.port), int(inst.instance_id)]

	var f := FileAccess.open(log_path, FileAccess.WRITE)
	if f:
		f.store_line("[REALM] spawned zone process marker")
		f.close()

	var args := [
		"--mode=zone",
		"--port=%d" % int(inst.port),
		"--instance_id=%d" % int(inst.instance_id),
		"--map_id=%s" % str(inst.map_id),
		"--seed=%d" % int(inst.seed),
		"--realm_port=%d" % internal_tcp_port,
		"--ticket_secret=%s" % ticket_secret,
		"--log=%s" % log_path,
	]

	var pid := OS.create_process(exe_path, args)

	ProcLog.lines(["[REALM] Spawned Zone pid=", pid, " port=", int(inst.port), " instance=", int(inst.instance_id)])
	ProcLog.lines(["[REALM] Zone spawn cmd: ", exe_path, " ", str(args)])
