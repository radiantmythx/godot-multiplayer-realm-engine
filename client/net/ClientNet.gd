# res://client/net/ClientNet.gd
extends Node
class_name ClientNet

signal realm_connected
signal zone_connected
signal realm_connection_failed
signal zone_connection_failed
signal realm_disconnected
signal zone_disconnected

var log: Callable = func(_m): pass

var realm_host := "127.0.0.1"
var realm_port := 1909

var zone_host := ""
var zone_port := 0

func set_realm(host: String, port: int) -> void:
	realm_host = host
	realm_port = port

func set_zone(host: String, port: int) -> void:
	zone_host = host
	zone_port = port

func connect_realm(multiplayer: MultiplayerAPI) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(realm_host, realm_port)
	if err != OK:
		push_error("[CLIENT] failed to connect realm: %s" % err)
		realm_connection_failed.emit()
		return

	multiplayer.multiplayer_peer = peer

	if not multiplayer.connected_to_server.is_connected(_on_realm_connected):
		multiplayer.connected_to_server.connect(_on_realm_connected.bind(multiplayer))
	if not multiplayer.connection_failed.is_connected(_on_realm_failed):
		multiplayer.connection_failed.connect(_on_realm_failed)
	if not multiplayer.server_disconnected.is_connected(_on_realm_disconnected):
		multiplayer.server_disconnected.connect(_on_realm_disconnected)

func connect_zone(multiplayer: MultiplayerAPI) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(zone_host, zone_port)
	if err != OK:
		push_error("[CLIENT] failed to connect zone: %s" % err)
		zone_connection_failed.emit()
		return

	multiplayer.multiplayer_peer = peer

	if not multiplayer.connected_to_server.is_connected(_on_zone_connected):
		multiplayer.connected_to_server.connect(_on_zone_connected.bind(multiplayer))
	if not multiplayer.connection_failed.is_connected(_on_zone_failed):
		multiplayer.connection_failed.connect(_on_zone_failed)
	if not multiplayer.server_disconnected.is_connected(_on_zone_disconnected):
		multiplayer.server_disconnected.connect(_on_zone_disconnected)

func disconnect_current(multiplayer: MultiplayerAPI) -> void:
	if multiplayer.connected_to_server.is_connected(_on_realm_connected):
		multiplayer.connected_to_server.disconnect(_on_realm_connected)
	if multiplayer.connected_to_server.is_connected(_on_zone_connected):
		multiplayer.connected_to_server.disconnect(_on_zone_connected)

	if multiplayer.connection_failed.is_connected(_on_realm_failed):
		multiplayer.connection_failed.disconnect(_on_realm_failed)
	if multiplayer.connection_failed.is_connected(_on_zone_failed):
		multiplayer.connection_failed.disconnect(_on_zone_failed)

	if multiplayer.server_disconnected.is_connected(_on_realm_disconnected):
		multiplayer.server_disconnected.disconnect(_on_realm_disconnected)
	if multiplayer.server_disconnected.is_connected(_on_zone_disconnected):
		multiplayer.server_disconnected.disconnect(_on_zone_disconnected)

	var old := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = null
	if old:
		old.close()

# --- internal handlers ---

func _on_realm_connected(_multiplayer: MultiplayerAPI) -> void:
	log.call("[CLIENT] Connected to Realm")
	realm_connected.emit()

func _on_zone_connected(_multiplayer: MultiplayerAPI) -> void:
	log.call("[CLIENT] Connected to Zone")
	zone_connected.emit()

func _on_realm_failed() -> void:
	push_error("[CLIENT] realm connection failed")
	realm_connection_failed.emit()

func _on_zone_failed() -> void:
	push_error("[CLIENT] zone connection failed")
	zone_connection_failed.emit()

func _on_realm_disconnected() -> void:
	push_error("[CLIENT] realm disconnected")
	realm_disconnected.emit()

func _on_zone_disconnected() -> void:
	push_error("[CLIENT] zone disconnected")
	zone_disconnected.emit()
