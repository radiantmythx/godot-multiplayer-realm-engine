# res://zone/combat/PlayerVitals.gd
extends Node
class_name PlayerVitals

var log: Callable = func(_m): pass

# peer_id -> {hp:int, max_hp:int, alive:bool}
var vitals_by_peer: Dictionary = {}

func has_peer(peer_id: int) -> bool:
	return vitals_by_peer.has(peer_id)

func remove_peer(peer_id: int) -> void:
	vitals_by_peer.erase(peer_id)

func init_peer(peer_id: int, max_hp: int = 10) -> void:
	vitals_by_peer[peer_id] = {
		"hp": max_hp,
		"max_hp": max_hp,
		"alive": true,
	}

func get_hp(peer_id: int) -> int:
	if not vitals_by_peer.has(peer_id):
		return 0
	var v: Dictionary = vitals_by_peer[peer_id]
	return int(v.get("hp", 0))

func get_max_hp(peer_id: int) -> int:
	if not vitals_by_peer.has(peer_id):
		return 0
	var v: Dictionary = vitals_by_peer[peer_id]
	return int(v.get("max_hp", 0))

func is_alive(peer_id: int) -> bool:
	if not vitals_by_peer.has(peer_id):
		return false
	var v: Dictionary = vitals_by_peer[peer_id]
	return bool(v.get("alive", false))

func apply_damage(peer_id: int, dmg: int) -> Dictionary:
	# returns {exists:bool, hp:int, died:bool}
	if not vitals_by_peer.has(peer_id):
		return {"exists": false, "hp": 0, "died": false}

	var v: Dictionary = vitals_by_peer[peer_id]
	if not bool(v.get("alive", true)):
		return {"exists": true, "hp": int(v.get("hp", 0)), "died": false}

	var hp := int(v.get("hp", 0)) - int(dmg)
	hp = max(hp, 0)
	v["hp"] = hp

	var died := false
	if hp <= 0:
		v["alive"] = false
		died = true

	vitals_by_peer[peer_id] = v
	return {"exists": true, "hp": hp, "died": died}

func heal(peer_id: int, amt: int) -> Dictionary:
	# returns {exists:bool, hp:int}
	if not vitals_by_peer.has(peer_id):
		return {"exists": false, "hp": 0}

	var v: Dictionary = vitals_by_peer[peer_id]
	var hp := int(v.get("hp", 0))
	var max_hp := int(v.get("max_hp", 0))
	hp = min(max_hp, hp + int(amt))
	v["hp"] = hp
	if hp > 0:
		v["alive"] = true
	vitals_by_peer[peer_id] = v
	return {"exists": true, "hp": hp}

func build_vitals_bulk_list() -> Array:
	# for late joiners / UI sync
	var out: Array = []
	for pid in vitals_by_peer.keys():
		var v: Dictionary = vitals_by_peer[pid]
		out.append({
			"peer_id": int(pid),
			"hp": int(v.get("hp", 0)),
			"max_hp": int(v.get("max_hp", 0)),
			"alive": bool(v.get("alive", true)),
		})
	return out
