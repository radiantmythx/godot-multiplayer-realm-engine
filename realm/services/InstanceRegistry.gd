extends Node
class_name InstanceRegistry

signal instance_dead(instance_id: int)

var zone_port_start: int = 1910
var zone_port_end: int = 1950
var heartbeat_timeout_s: int = 6

var hub_map_id: String = "res://maps/HubMap.tscn"
var hub_seed: int = 42
var hub_capacity: int = 32

# key -> instance dict
var instances: Dictionary = {}
# port -> bool allocated
var port_alloc: Dictionary = {}

func configure_ports(start_port: int, end_port: int) -> void:
	zone_port_start = start_port
	zone_port_end = end_port

func configure_hub(map_id: String, seed: int, cap: int) -> void:
	hub_map_id = map_id
	hub_seed = seed
	hub_capacity = cap

func configure_heartbeat(timeout_s: int) -> void:
	heartbeat_timeout_s = timeout_s

func init_ports() -> void:
	port_alloc.clear()
	for p in range(zone_port_start, zone_port_end + 1):
		port_alloc[p] = false

func alloc_port() -> int:
	for p in range(zone_port_start, zone_port_end + 1):
		if port_alloc.get(p, false) == false:
			port_alloc[p] = true
			return p
	return -1

func free_port(port: int) -> void:
	if port_alloc.has(port):
		port_alloc[port] = false

func make_instance_id() -> int:
	return int(Time.get_unix_time_from_system() * 1000) + randi() % 999

func create_instance(key: String, kind: String, map_id: String, seed: int, capacity: int) -> Variant:
	var port := alloc_port()
	if port == -1:
		return null

	var instance_id := make_instance_id()
	var inst := {
		"instance_id": instance_id,
		"kind": kind,
		"key": key,
		"map_id": map_id,
		"seed": seed,
		"port": port,
		"status": "STARTING",
		"capacity": capacity,
		"player_count": 0,
		"last_heartbeat": Time.get_unix_time_from_system()
	}
	instances[key] = inst
	return inst

func get_or_create_hub() -> Variant:
	var key := "hub:default"
	var now := int(Time.get_unix_time_from_system())

	if instances.has(key):
		var inst = instances[key]

		if str(inst.status) == "RUNNING":
			var last := int(inst.get("last_heartbeat", 0))
			if last > 0 and (now - last) > heartbeat_timeout_s:
				# stale; kill + respawn
				remove_instance(int(inst.instance_id))
			elif int(inst.player_count) < int(inst.capacity):
				return inst

		# dev-friendly: allow STARTING travel
		if str(inst.status) == "STARTING":
			return inst

	# create hub
	return create_instance(key, "HUB", hub_map_id, hub_seed, hub_capacity)

func find_instance_by_id(instance_id: int) -> Variant:
	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			return instances[k]
	return null

func mark_running(instance_id: int, capacity: int) -> void:
	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			instances[k].status = "RUNNING"
			instances[k].capacity = capacity
			instances[k].last_heartbeat = Time.get_unix_time_from_system()
			return

func mark_heartbeat(instance_id: int, player_count: int) -> void:
	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			instances[k].player_count = player_count
			instances[k].last_heartbeat = Time.get_unix_time_from_system()
			return

func prune_dead_instances() -> void:
	var now := int(Time.get_unix_time_from_system())
	for k in instances.keys():
		var inst = instances[k]
		if str(inst.status) != "RUNNING":
			continue
		var last := int(inst.get("last_heartbeat", 0))
		if last > 0 and (now - last) > heartbeat_timeout_s:
			emit_signal("instance_dead", int(inst.instance_id))

func remove_instance(instance_id: int) -> void:
	for k in instances.keys():
		if int(instances[k].instance_id) == instance_id:
			var port := int(instances[k].port)
			free_port(port)
			instances.erase(k)
			return

func get_public_zone_list() -> Array:
	var zones: Array = []
	for k in instances.keys():
		var inst = instances[k]
		var st := str(inst.status)
		if st != "RUNNING" and st != "STARTING":
			continue
		zones.append({
			"key": str(inst.key),
			"instance_id": int(inst.instance_id),
			"kind": str(inst.kind),
			"map_id": str(inst.map_id),
			"seed": int(inst.seed),
			"port": int(inst.port),
			"status": st,
			"capacity": int(inst.capacity),
			"player_count": int(inst.player_count),
		})
	return zones
