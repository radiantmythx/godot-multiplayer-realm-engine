# res://shared/NetJson.gd
extends RefCounted
class_name NetJson

static func send_line(peer: StreamPeerTCP, msg: Dictionary) -> void:
	var line := JSON.stringify(msg) + "\n"
	peer.put_data(line.to_utf8_buffer())

static func poll_lines(peer: StreamPeerTCP, buffer: PackedByteArray) -> Dictionary:
	# Returns { msgs:Array[Dictionary], buffer:PackedByteArray }
	var out: Array[Dictionary] = []

	if peer.get_available_bytes() > 0:
		var res := peer.get_data(peer.get_available_bytes())
		if res[0] == OK:
			buffer.append_array(res[1])

	while true:
		var idx := buffer.find(10) # '\n'
		if idx == -1:
			break
		var line_bytes := buffer.slice(0, idx)
		buffer = buffer.slice(idx + 1, buffer.size()) # keep remainder
		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)

	return { "msgs": out, "buffer": buffer }
