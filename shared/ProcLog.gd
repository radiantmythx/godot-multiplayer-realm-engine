extends Node

var _file: FileAccess = null
var _path: String = ""

func init_from_args(default_name: String) -> void:
	if _file != null:
		return

	var args := OS.get_cmdline_args()
	var log_arg := ""

	for a in args:
		if typeof(a) == TYPE_STRING and a.begins_with("--log="):
			log_arg = a.get_slice("=", 1)
			break

	var final_path := ""
	if log_arg.is_empty():
		final_path = "user://logs/%s.log" % default_name
	else:
		if not (log_arg.contains("/") or log_arg.contains("\\") or log_arg.contains(":")):
			final_path = "user://logs/%s" % log_arg
		else:
			final_path = log_arg

	_path = ProjectSettings.globalize_path(final_path).replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())

	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file:
		_file.store_line("---- LOG START %s ----" % Time.get_datetime_string_from_system())
		_file.flush()

# Pass an array of parts (print-like)
func linev(parts: Array) -> void:
	var msg := _join(parts, "")
	_emit(msg)

# Same, but inserts spaces between parts (often nicer)
func lines(parts: Array) -> void:
	var msg := _join(parts, " ")
	_emit(msg)

# If you already built a string
func line(msg: String) -> void:
	_emit(msg)

func _join(parts: Array, sep: String) -> String:
	var out: Array[String] = []
	out.resize(parts.size())
	for i in parts.size():
		out[i] = str(parts[i])
	return sep.join(out)

func _emit(msg: String) -> void:
	print(msg)
	if _file:
		_file.store_line(msg)
		_file.flush()

func path() -> String:
	return _path
