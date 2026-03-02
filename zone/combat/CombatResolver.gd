# res://zone/combat/CombatResolver.gd
extends Node
class_name CombatResolver

var log: Callable = func(_m): pass

var monsters: MonsterSystem = null
var players: ZonePlayers = null

# knobs
var projectile_damage := 1
var allow_friendly_fire := false
var allow_self_hit := false

func configure(_monsters: MonsterSystem, _players: ZonePlayers) -> void:
	monsters = _monsters
	players = _players

# Input: hits = Array[{proj_id:int, kind:String, id:int, owner:int?}]
# Output events ZoneServer can broadcast.
# Monster events:
#  - {"type":"target_hp", "id":int, "hp":int}
#  - {"type":"break_target", "id":int}
# Player events:
#  - {"type":"player_hp", "peer_id":int, "hp":int}
#  - {"type":"player_died", "peer_id":int}
func resolve_projectile_hits(hits: Array) -> Array:
	var events: Array = []
	if hits.is_empty():
		return events

	for h in hits:
		var kind := str(h.get("kind", ""))
		var id := int(h.get("id", 0))
		var owner := int(h.get("owner", 0))

		match kind:
			"monster":
				if not monsters:
					continue

				var r := monsters.apply_damage(id, projectile_damage)

				if bool(r.get("exists", false)):
					events.append({
						"type": "target_hp",
						"id": id,
						"hp": int(r.get("hp", 0)),
					})

				if bool(r.get("died", false)):
					events.append({
						"type": "break_target",
						"id": id,
					})

			"player":
				if not players:
					continue

				# Optional: if you added owner to hit payload, you can prevent friendly fire here later.

				var r := players.apply_damage(id, projectile_damage)
				if not bool(r.get("exists", false)):
					continue

				events.append({
					"type": "player_hp",
					"peer_id": id,
					"hp": int(r.get("hp", 0)),
				})

				if bool(r.get("died", false)):
					events.append({
						"type": "player_died",
						"peer_id": id,
					})

			_:
				pass

	return events
