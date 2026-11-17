extends Control

const TEXT_PATH := "res://Text/Text.json"
const NODE_SCRIPT := preload("res://addons/dialogue_graph/dialogue_node.gd")
const MINIMAP := true

var graph: DialogueGraph
var dirty := false
var current_path := TEXT_PATH

@onready var graph_edit: GraphEdit = %GraphEdit
@onready var inspector: VBoxContainer = %Inspector
@onready var error_list: ItemList = %ErrorList
@onready var status: Label = %Status

func _ready() -> void:
	graph_edit.minimap_enabled = MINIMAP
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	load_file(current_path)

func load_file(path: String) -> void:
	var data = JsonHelper.read_json_file(path)
	if not (data is Array):
		status.text = "读取失败: " + path
		return
	graph = DialogueGraph.from_array(data)
	current_path = path
	dirty = false
	_rebuild()

func _clear_graph_nodes() -> void:
	graph_edit.clear_connections()
	for c in graph_edit.get_children():
		if c is GraphNode:
			graph_edit.remove_child(c)
			c.queue_free()

func _rebuild() -> void:
	_clear_graph_nodes()
	# 只计算显示坐标，不写回模型；未编辑时保存 Text.json 零 diff。
	var display_positions := DialogueAutoLayout.compute_positions(graph)
	var created: Dictionary = {}

	# 第一遍：建全部节点，前向连线才有目标可连。
	for i in graph.nodes.size():
		var n: DialogueGraphNode = NODE_SCRIPT.new()
		graph_edit.add_child(n)
		n.setup(graph, i)
		var stored := graph.position_of(i)
		n.position_offset = display_positions.get(i, stored) if is_nan(stored.x) else stored
		created[i] = n

	# 第二遍：连边。
	for i in graph.nodes.size():
		_link_node(created[i], i)

	if is_instance_valid(status):
		_refresh_status()

func _link_node(n: DialogueGraphNode, i: int) -> void:
	for e in graph.edges_of(i):
		var to := graph.index_of(e.target)
		if to < 0:
			continue
		# GraphEdit 的 from_port 是“输出口序号”（从 0 起），不是 GraphNode 的 slot 行号。
		var from_port: int = int(e.choice_index) if e.kind == "choice" else 0
		graph_edit.connect_node(n.name, from_port, "N_%d" % to, 0)

func _refresh_status() -> void:
	status.text = "%d 节点 | %s%s" % [
		graph.nodes.size() if graph != null else 0,
		current_path,
		"  *未保存" if dirty else ""
	]

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if graph_edit.is_node_connected(from_node, from_port, to_node, to_port):
		return
	var src := _node_by_name(from_node)
	var dst := _node_by_name(to_node)
	if src == null or dst == null:
		return
	var target := graph.get_name_at(dst.node_index)
	# 对话语义：一个输出口只能指向一个目标，先断掉同口的旧连线。
	for c in graph_edit.get_connection_list():
		if StringName(c.from_node) == from_node and int(c.from_port) == from_port:
			graph_edit.disconnect_node(StringName(c.from_node), int(c.from_port),
				StringName(c.to_node), int(c.to_port))
	if graph.has_choices(src.node_index):
		graph.set_choice_links(src.node_index, from_port, target)
	else:
		graph.set_links(src.node_index, target)
	graph_edit.connect_node(from_node, from_port, to_node, to_port)
	src.refresh()
	_mark_dirty()

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var src := _node_by_name(from_node)
	if src == null:
		return
	if graph.has_choices(src.node_index):
		graph.set_choice_links(src.node_index, from_port, "")
	else:
		graph.set_links(src.node_index, "")
	graph_edit.disconnect_node(from_node, from_port, to_node, to_port)
	src.refresh()
	_mark_dirty()

func _node_by_name(n: StringName) -> DialogueGraphNode:
	var c := graph_edit.get_node_or_null(NodePath(n))
	return c as DialogueGraphNode

func _mark_dirty() -> void:
	dirty = true
	_refresh_status()
