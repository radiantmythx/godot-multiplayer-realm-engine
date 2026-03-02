extends Node
class_name ClientConnection

signal realm_connected
signal zone_connected
signal realm_lost(reason: String)
signal zone_lost(reason: String)

enum ConnKind { NONE, REALM, ZONE }

var conn_kind: ConnKind = ConnKind.NONE

var log: Callable = func(_m): pass

var net: ClientNet
var mp: MultiplayerAPI   # ← renamed from "multiplayer"

var realm_host := "127.0.0.1"
var realm_port := 1909

var zone_host := ""
var zone_port := 0

func configure(multiplayer_api: MultiplayerAPI, net_node: ClientNet) -> void:
	mp = multiplayer_api
	net = net_node

	# wire net signals
	net.realm_connected.connect(_on_realm_connected)
	net.zone_connected.connect(_on_zone_connected)

	net.zone_disconnected.connect(func(): _on_zone_lost("server_disconnected"))
	net.zone_connection_failed.connect(func(): _on_zone_lost("connection_failed"))

	net.realm_disconnected.connect(func(): _on_realm_lost("realm_disconnected"))
	net.realm_connection_failed.connect(func(): _on_realm_lost("realm_connection_failed"))

func set_realm(host: String, port: int) -> void:
	realm_host = host
	realm_port = port
	net.set_realm(host, port)

func set_zone(host: String, port: int) -> void:
	zone_host = host
	zone_port = port
	net.set_zone(host, port)

func connect_realm() -> void:
	conn_kind = ConnKind.NONE
	net.connect_realm(mp)

func connect_zone() -> void:
	conn_kind = ConnKind.NONE
	net.connect_zone(mp)

func disconnect_current() -> void:
	net.disconnect_current(mp)
	conn_kind = ConnKind.NONE

func peer_connected() -> bool:
	if mp == null or mp.multiplayer_peer == null:
		return false

	var p := mp.multiplayer_peer
	if p is ENetMultiplayerPeer:
		return p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

	return true

# --- internal handlers ---

func _on_realm_connected() -> void:
	conn_kind = ConnKind.REALM
	log.call("[CLIENT] Realm connected")
	emit_signal("realm_connected")

func _on_zone_connected() -> void:
	conn_kind = ConnKind.ZONE
	log.call("[CLIENT] Zone connected")
	emit_signal("zone_connected")

func _on_realm_lost(reason: String) -> void:
	if conn_kind == ConnKind.REALM:
		conn_kind = ConnKind.NONE
	emit_signal("realm_lost", reason)

func _on_zone_lost(reason: String) -> void:
	if conn_kind == ConnKind.ZONE:
		conn_kind = ConnKind.NONE
	emit_signal("zone_lost", reason)
