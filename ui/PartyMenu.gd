# res://ui/PartyMenu.gd
extends CanvasLayer
class_name PartyMenu

@onready var list: ItemList = $Panel/VBoxContainer/InstanceList
@onready var create_btn: Button = $Panel/VBoxContainer/CreateButton
@onready var join_btn: Button = $Panel/VBoxContainer/JoinButton
@onready var close_btn: Button = $Panel/VBoxContainer/CloseButton

var _instances: Array[Dictionary] = []  # each: {id, name, players, max}

func _ready() -> void:
	visible = false
	create_btn.pressed.connect(_on_create)
	join_btn.pressed.connect(_on_join)
	close_btn.pressed.connect(hide)
	add_to_group("party_menu")

func toggle() -> void:
	visible = !visible


func set_instances(instances: Array[Dictionary]) -> void:
	_instances = instances
	list.clear()
	for inst in _instances:
		var text := "Zone %d (%d/%d)" % [int(inst["id"]), int(inst["players"]), int(inst["max_players"])]
		list.add_item(text)

func _on_create() -> void:
	pass

func _on_join() -> void:
	var idx := list.get_selected_items()
	if idx.is_empty():
		return
	var inst_id := int(_instances[idx[0]]["id"])
	pass
