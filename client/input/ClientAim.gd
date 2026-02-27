# res://client/input/ClientAim.gd
extends Node
class_name ClientAim

func raycast_plane_y0(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	# Intersect mouse ray with a horizontal plane at Y = 0
	var from := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)

	if abs(dir.y) < 0.0001:
		return {}

	var t := -from.y / dir.y
	if t < 0:
		return {}

	var hit_pos := from + dir * t
	return {"position": hit_pos}
