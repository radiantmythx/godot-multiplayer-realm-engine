# res://zone/combat/ProjectileSystem.gd
extends Node
class_name ProjectileSystem

var log: Callable = func(_m): pass

var projectile_scene: PackedScene = null
var world_root: Node = null

# proj_id -> {pos, vel, owner, ttl}
var projectiles: Dictionary = {}
var projectile_next_id := 1
var projectile_nodes: Dictionary = {} # proj_id -> Node3D

func configure(_projectile_scene: PackedScene, _world_root: Node) -> void:
	projectile_scene = _projectile_scene
	world_root = _world_root

func fire(owner_peer: int, player_xform: Transform3D, dir: Vector3) -> Dictionary:
	# returns spawn event for RPC {proj_id, owner, px, vel}
	if dir.length() < 0.001:
		return {}
	dir = dir.normalized()

	var spawn_pos := player_xform.origin + (dir * 1.0) + Vector3(0, 1.2, 0)

	var proj_id := projectile_next_id
	projectile_next_id += 1

	var speed := 18.0
	var vel := dir * speed

	projectiles[proj_id] = {
		"pos": spawn_pos,
		"vel": vel,
		"owner": owner_peer,
		"ttl": 3.0,
	}

	# Optional: server-side debug node
	if projectile_scene and world_root:
		var inst := projectile_scene.instantiate()
		inst.name = "Proj_%d" % proj_id
		world_root.add_child(inst)
		if inst is Node3D:
			(inst as Node3D).global_position = spawn_pos
		projectile_nodes[proj_id] = inst as Node3D

	var px := Transform3D(Basis.IDENTITY, spawn_pos)
	return {"proj_id": proj_id, "owner": owner_peer, "px": px, "vel": vel}

func tick(dt: float, hurtboxes: Array) -> Dictionary:
	# returns {snaps:Array, despawn:Array[int], hits:Array[{proj_id,kind,id}]}
	if projectiles.is_empty():
		return {"snaps": [], "despawn": [], "hits": []}

	var snaps: Array = []
	var to_despawn: Array[int] = []
	var hits: Array = []

	for proj_id in projectiles.keys():
		var p: Dictionary = projectiles[proj_id]
		var pos: Vector3 = p.pos
		var vel: Vector3 = p.vel
		var ttl: float = p.ttl

		var new_pos := pos + vel * dt
		ttl -= dt

		# Hit test against generic hurtboxes (players + monsters, etc)
		var hit := _projectile_hit(pos, new_pos, hurtboxes, int(p.owner))
		if not hit.is_empty():
			hits.append({
				"proj_id": int(proj_id),
				"kind": str(hit.kind),
				"id": int(hit.id),
				"owner": int(p.owner),
			})
			to_despawn.append(proj_id)
			continue

		if ttl <= 0.0:
			to_despawn.append(proj_id)
			continue

		p.pos = new_pos
		p.ttl = ttl
		projectiles[proj_id] = p

		if projectile_nodes.has(proj_id):
			var n: Node3D = projectile_nodes[proj_id]
			if n and is_instance_valid(n):
				n.global_position = new_pos
			else:
				projectile_nodes.erase(proj_id)

		snaps.append({"id": int(proj_id), "pos": new_pos})

	# cleanup server debug nodes for despawns
	for did in to_despawn:
		projectiles.erase(did)
		if projectile_nodes.has(did):
			var dn: Node3D = projectile_nodes[did]
			if dn and is_instance_valid(dn):
				dn.queue_free()
			projectile_nodes.erase(did)

	return {"snaps": snaps, "despawn": to_despawn, "hits": hits}

func _projectile_hit(a: Vector3, b: Vector3, hurtboxes: Array, owner_peer: int) -> Dictionary:
	for hb in hurtboxes:
		# hb is a Dictionary-like object: {kind,id,xform,radius}
		var kind := str(hb.get("kind", ""))
		var id := int(hb.get("id", 0))

		# Optional: ignore self-hit for player-owned projectiles
		if kind == "player" and id == owner_peer:
			continue

		var xform: Transform3D = hb.get("xform", Transform3D.IDENTITY)
		var center: Vector3 = xform.origin
		var r: float = float(hb.get("radius", 0.6))

		if _segment_sphere(a, b, center, r):
			return {"kind": kind, "id": id}

	return {}

func _segment_sphere(a: Vector3, b: Vector3, c: Vector3, r: float) -> bool:
	var ab := b - a
	var ac := c - a
	var ab_len2 := ab.length_squared()
	if ab_len2 < 0.000001:
		return (a - c).length() <= r

	var t = clamp(ac.dot(ab) / ab_len2, 0.0, 1.0)
	var closest = a + ab * t
	return (closest - c).length() <= r
