# res://net/RpcContract.gd
extends Node
class_name RpcContract

# ---------------- Realm -> Client (auth/travel/lobby) ----------------

@rpc("authority", "reliable")
func s_auth_ok(_data: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_travel_to_zone(_travel: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_travel_failed(_reason: String) -> void:
	pass

# Lobby list + create failures
@rpc("authority", "reliable")
func s_zone_list(_zones: Array) -> void:
	pass

@rpc("authority", "reliable")
func s_create_zone_failed(_reason: String) -> void:
	pass


# ---------------- Client -> Realm (requests) ----------------

@rpc("any_peer", "reliable")
func c_authenticate(_jwt: String) -> void:
	pass

# Old flow (still supported)
@rpc("any_peer", "reliable")
func c_request_enter_hub(_character_id: int) -> void:
	pass

# New lobby flow
@rpc("any_peer", "reliable")
func c_request_zone_list() -> void:
	pass

@rpc("any_peer", "reliable")
func c_request_create_zone(_map_id: String, _seed: int, _capacity: int) -> void:
	pass

# UPDATED: include character_name so Realm can embed it in the signed join ticket.
@rpc("any_peer", "reliable")
func c_request_enter_instance(_instance_id: int, _character_id: int, _character_name: String) -> void:
	pass

@rpc("any_peer", "reliable")
func c_leave_zone() -> void:
	pass


# ---------------- Client -> Zone (requests) ----------------

@rpc("any_peer", "reliable")
func c_join_instance(_join_ticket: String, _character_id: int) -> void:
	pass

@rpc("any_peer", "unreliable")
func c_set_move_target(_world_pos: Vector3) -> void:
	pass

@rpc("any_peer", "reliable")
func c_fire_projectile(_from: Vector3, _dir: Vector3) -> void:
	pass


# ---------------- Zone -> Client (join/spawn/snapshots/combat) ----------------

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
func s_spawn_player(_peer_id: int, _character_id: int, _name: String, _xform: Transform3D) -> void:
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
	
@rpc("authority", "reliable")
func s_player_hp(_peer_id: int, _hp: int) -> void:
	pass

@rpc("authority", "reliable")
func s_player_died(_peer_id: int) -> void:
	pass

# ---------------- Realm <-> Client (generic lobby gateway) ----------------

@rpc("any_peer", "reliable")
func c_lobby_request(_kind: String, _payload: Dictionary) -> void:
	pass

@rpc("authority", "reliable")
func s_lobby_response(_kind: String, _ok: bool, _payload: Dictionary) -> void:
	pass
