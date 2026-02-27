# res://client/net/ClientNet.gd
extends Node
class_name ClientNet

signal realm_connected
signal zone_connected
signal realm_connection_failed
signal zone_connection_failed

var log: Callable = func(_m): pass

var realm_host := "127.0.0.1"
var realm_port := 1909

var zone_host := ""
var zone_port := 0

func connect_realm(multiplayer: MultiplayerAPI) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(realm_host, realm_port)
	if err != OK:
		push_error("[CLIENT] failed to connect realm: %s" % err)
		return

	multiplayer.multiplayer_peer = peer

	# connect once
	if not multiplayer.connected_to_server.is_connected(_on_realm_connected):
		multiplayer.connected_to_server.connect(_on_realm_connected.bind(multiplayer))
	if not multiplayer.connection_failed.is_connected(_on_realm_failed):
		multiplayer.connection_failed.connect(_on_realm_failed)

func set_zone(host: String, port: int) -> void:
	zone_host = host
	zone_port = port

func disconnect_current(multiplayer: MultiplayerAPI) -> void:
	# Disconnect signals to avoid double-calls
	if multiplayer.connected_to_server.is_connected(_on_realm_connected):
		multiplayer.connected_to_server.disconnect(_on_realm_connected)
	if multiplayer.connected_to_server.is_connected(_on_zone_connected):
		multiplayer.connected_to_server.disconnect(_on_zone_connected)

	var old := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = null
	if old:
		old.close()

func connect_zone(multiplayer: MultiplayerAPI) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(zone_host, zone_port)
	if err != OK:
		push_error("[CLIENT] failed to connect zone: %s" % err)
		return

	multiplayer.multiplayer_peer = peer

	if not multiplayer.connected_to_server.is_connected(_on_zone_connected):
		multiplayer.connected_to_server.connect(_on_zone_connected.bind(multiplayer))
	if not multiplayer.connection_failed.is_connected(_on_zone_failed):
		multiplayer.connection_failed.connect(_on_zone_failed)

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
