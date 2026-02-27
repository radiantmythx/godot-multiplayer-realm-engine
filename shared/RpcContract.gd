# res://net/RpcContract.gd
extends Node
class_name RpcContract

# ---------------- Realm -> Client (travel) ----------------

@rpc("authority", "reliable")
func s_travel_to_zone(_travel: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_travel_failed(_reason: String) -> void:
	pass

# ---------------- Client -> Realm / Zone (requests) ----------------

@rpc("any_peer", "reliable")
func c_request_enter_hub(_character_id: int) -> void:
	pass

@rpc("any_peer", "reliable")
func c_join_instance(_join_ticket: String, _character_id: int) -> void:
	pass

@rpc("any_peer", "unreliable")
func c_set_move_target(_world_pos: Vector3) -> void:
	pass
	
# Client -> Zone
@rpc("any_peer", "reliable")
func c_fire_projectile(_from: Vector3, _dir: Vector3) -> void:
	pass

# ---------------- Zone -> Client (join/spawn/snapshots) ----------------

@rpc("authority", "reliable")
func s_join_accepted(_data: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_join_rejected(_reason: String) -> void:
	pass

@rpc("authority", "reliable")
func s_spawn_players_bulk(_list: Array) -> void:
	pass

@rpc("authority", "reliable")
func s_spawn_player(_peer_id: int, _character_id: int, _xform: Transform3D) -> void:
	pass

@rpc("authority", "reliable")
func s_despawn_player(_peer_id: int) -> void:
	pass

@rpc("authority", "unreliable")
func s_apply_snapshots(_snaps: Array) -> void:
	pass

@rpc("authority", "reliable")
func s_spawn_projectile(_proj_id: int, _owner_peer: int, _xform: Transform3D, _vel: Vector3) -> void:
	pass

@rpc("authority", "unreliable")
func s_projectile_snapshots(_snaps: Array) -> void:
	pass

@rpc("authority", "reliable")
func s_despawn_projectile(_proj_id: int) -> void:
	pass

@rpc("authority", "reliable")
func s_spawn_target(_target_id: int, _xform: Transform3D, _hp: int) -> void:
	pass

@rpc("authority", "reliable")
func s_target_hp(_target_id: int, _hp: int) -> void:
	pass

@rpc("authority", "reliable")
func s_break_target(_target_id: int) -> void:
	pass
