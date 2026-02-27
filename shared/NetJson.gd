# res://shared/NetJson.gd
extends RefCounted
class_name NetJson

static func send_line(peer: StreamPeerTCP, msg: Dictionary) -> void:
	var line := JSON.stringify(msg) + "\n"
	peer.put_data(line.to_utf8_buffer())

static func poll_lines(peer: StreamPeerTCP, buffer: PackedByteArray) -> Array[Dictionary]:
	# Returns parsed JSON objects from buffer; keeps partial line in buffer.
	var out: Array[Dictionary] = []
	if peer.get_available_bytes() > 0:
		var chunk = peer.get_data(peer.get_available_bytes())[1]
		buffer.append_array(chunk)

	while true:
		var idx := buffer.find(10) # '\n'
		if idx == -1:
			break
		var line_bytes := buffer.slice(0, idx)
		buffer = buffer.slice(idx + 1, buffer.size())
		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line.is_empty():
			continue
		var parsed = JSON.parse_string(line)
		if typeof(parsed) == TYPE_DICTIONARY:
			out.append(parsed)
	return out
