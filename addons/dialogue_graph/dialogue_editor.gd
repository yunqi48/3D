extends Control

const TEXT_PATH := "res://Text/Text.json"
const NODE_SCRIPT := preload("res://addons/dialogue_graph/dialogue_node.gd")
const MINIMAP := true

var graph: DialogueGraph
var dirty := false
var current_path := TEXT_PATH

var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _close_dialog: ConfirmationDialog

@onready var graph_edit: GraphEdit = %GraphEdit
@onready var inspector: VBoxContainer = %Inspector
@onready var error_list: ItemList = %ErrorList
@onready var status: Label = %Status

func _ready() -> void:
	get_tree().auto_accept_quit = false
	graph_edit.minimap_enabled = MINIMAP
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	graph_edit.end_node_move.connect(_on_end_node_move)
	graph_edit.node_selected.connect(_on_node_selected)
	graph_edit.popup_request.connect(_on_popup_request)
	error_list.item_selected.connect(_on_error_selected)

	%OpenButton.pressed.connect(_on_open)
	%SaveButton.pressed.connect(_on_save)
	%SaveAsButton.pressed.connect(_on_save_as)
	%ValidateButton.pressed.connect(_on_validate)
	%AutoLayoutButton.pressed.connect(_on_auto_layout)
	%SearchEdit.text_submitted.connect(_on_search_submitted)

	_setup_dialogs()
	load_file(current_path)

func _setup_dialogs() -> void:
	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.filters = PackedStringArray(["*.json ; JSON"])
	_open_dialog.current_dir = "res://Text"
	_open_dialog.file_selected.connect(func(path: String) -> void: load_file(path))
	add_child(_open_dialog)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.filters = PackedStringArray(["*.json ; JSON"])
	_save_dialog.current_dir = "res://Text"
	_save_dialog.current_file = "Text.json"
	_save_dialog.file_selected.connect(_write_to)
	add_child(_save_dialog)

	_close_dialog = ConfirmationDialog.new()
	_close_dialog.title = "未保存的修改"
	_close_dialog.dialog_text = "有未保存的修改，确定要关闭编辑器吗？"
	_close_dialog.confirmed.connect(func() -> void: get_tree().quit())
	add_child(_close_dialog)

func load_file(path: String) -> void:
	var data = DialogueJson.read_file(path)
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
	_clear_inspector()
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

func _clear_inspector() -> void:
	for c in inspector.get_children():
		inspector.remove_child(c)
		c.queue_free()

func _on_node_selected(node: Node) -> void:
	if node is DialogueGraphNode:
		_build_inspector(node)

func _on_delete_nodes_request(node_names: Array[StringName]) -> void:
	var idxs: Array[int] = []
	for sn in node_names:
		var n := graph_edit.get_node_or_null(NodePath(sn))
		if n is DialogueGraphNode:
			if n.node_index == 0:
				status.text = "不能删除入口节点（数组第 0 个）"
				return
			idxs.append(n.node_index)
	idxs.sort()
	idxs.reverse()
	for i in idxs:
		graph.remove_node(i)
	_mark_dirty()
	_rebuild()

func _on_popup_request(at_position: Vector2) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("新建对话节点", 0)
	menu.position = DisplayServer.mouse_get_position()
	menu.popup_hide.connect(menu.queue_free)
	menu.popup()
	menu.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_create_node_at(at_position))

func _create_node_at(local_pos: Vector2) -> void:
	var graph_pos: Vector2 = (local_pos + graph_edit.scroll_offset) / graph_edit.zoom
	var scene_name := "Bunker"
	if graph.nodes.size() > 0:
		scene_name = str(graph.nodes[0].get("Scene", "Bunker"))
	var seq := graph.nodes.size() + 1
	var new_name := ""
	while true:
		new_name = "%s.%03d" % [scene_name, seq]
		if graph.index_of(new_name) == -1:
			break
		seq += 1
	graph.create_node(new_name, scene_name, graph_pos)
	_mark_dirty()
	_rebuild()

func _rename_node(i: int, new_name: String) -> void:
	if new_name.is_empty() or (new_name != graph.get_name_at(i) and graph.index_of(new_name) != -1):
		status.text = "DialogueName 为空或重复: " + new_name
		return
	graph.nodes[i]["DialogueName"] = new_name
	graph.rebuild_index()
	_mark_dirty()
	_rebuild()

# 通用单行字段：回车或失焦时写回
func _field(label_text: String, value: String, on_commit: Callable, editable := true) -> LineEdit:
	var row := HBoxContainer.new()
	var lb := Label.new()
	lb.text = label_text
	lb.custom_minimum_size = Vector2(96, 0)
	var le := LineEdit.new()
	le.text = value
	le.editable = editable
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_submitted.connect(func(t: String) -> void: on_commit.call(t))
	le.focus_exited.connect(func() -> void: on_commit.call(le.text))
	row.add_child(lb)
	row.add_child(le)
	inspector.add_child(row)
	return le

func _build_inspector(n: DialogueGraphNode) -> void:
	_clear_inspector()
	if n == null or n.node_index < 0 or n.node_index >= graph.nodes.size():
		return
	var i := n.node_index
	var d: Dictionary = graph.nodes[i]
	if not d.has("attributes") or not (d["attributes"] is Dictionary):
		d["attributes"] = {}
	var attrs: Dictionary = d["attributes"]

	_field("Scene", str(d.get("Scene", "")), func(t: String) -> void:
		d["Scene"] = t
		_mark_dirty())
	_field("DialogueName", graph.get_name_at(i), func(t: String) -> void:
		_rename_node(i, t.strip_edges()))
	_field("说话人", str(attrs.get("name", "")), func(t: String) -> void:
		attrs["name"] = t
		n.refresh()
		_mark_dirty())
	_field("立绘", str(attrs.get("avatar", "")), func(t: String) -> void:
		attrs["avatar"] = t
		_mark_dirty())
	_field("links", graph.links_of(i), func(t: String) -> void:
		graph.set_links(i, t.strip_edges())
		n.refresh()
		_mark_dirty(), not graph.has_choices(i))

	# pid 下拉
	var pid_row := HBoxContainer.new()
	var pid_label := Label.new()
	pid_label.text = "pid"
	pid_label.custom_minimum_size = Vector2(96, 0)
	var opt := OptionButton.new()
	opt.add_item("1 · AI-9", 1)
	opt.add_item("2 · 幸存者", 2)
	opt.add_item("3 · 林岚", 3)
	var pid_index := opt.get_item_index(int(attrs.get("pid", 1)))
	opt.select(maxi(0, pid_index))
	opt.item_selected.connect(func(idx: int) -> void:
		attrs["pid"] = opt.get_item_id(idx)
		n.refresh()
		_mark_dirty())
	pid_row.add_child(pid_label)
	pid_row.add_child(opt)
	inspector.add_child(pid_row)

	# 台词
	var ct := Label.new()
	ct.text = "content"
	inspector.add_child(ct)
	var te := TextEdit.new()
	te.text = str(d.get("content", ""))
	te.custom_minimum_size = Vector2(0, 120)
	te.text_changed.connect(func() -> void:
		d["content"] = te.text
		n.refresh()
		_mark_dirty())
	inspector.add_child(te)

	# 选项编辑器（仅分支节点）
	if graph.has_choices(i):
		var h := Label.new()
		h.text = "— 选项 —"
		inspector.add_child(h)
		var choices: Array = d["choices"]
		for ci in choices.size():
			var c: Dictionary = choices[ci]
			_field("选项%d 文案" % (ci + 1), str(c.get("text", "")), func(t: String) -> void:
				c["text"] = t
				n.refresh()
				_mark_dirty())
			_field("选项%d 目标" % (ci + 1), "" if c.get("links") == null else str(c.get("links")), func(t: String) -> void:
				c["links"] = null if t.strip_edges().is_empty() else t.strip_edges()
				n.refresh()
				_mark_dirty())
			var del := Button.new()
			del.text = "删除选项 %d" % (ci + 1)
			del.pressed.connect(func() -> void:
				choices.remove_at(ci)
				if choices.is_empty():
					d.erase("choices")
				_mark_dirty()
				_rebuild())
			inspector.add_child(del)
		var add := Button.new()
		add.text = "＋ 选项"
		add.pressed.connect(func() -> void:
			graph.ensure_choices(i).append({"text": "新选项", "links": null})
			_mark_dirty()
			_rebuild())
		inspector.add_child(add)

	# 结局字段（仅当节点已有 ending 时显示）
	var ending: Dictionary = graph.ending_of(i)
	if not ending.is_empty():
		for key in ["id", "title", "subtitle", "next_scene"]:
			_field("ending." + key, str(ending.get(key, "")), func(t: String) -> void:
				ending[key] = t
				_mark_dirty())

func _on_end_node_move() -> void:
	for c in graph_edit.get_children():
		if c is DialogueGraphNode:
			graph.set_position(c.node_index, c.position_offset)
	_mark_dirty()

func _on_open() -> void:
	_open_dialog.current_dir = current_path.get_base_dir()
	_open_dialog.current_file = current_path.get_file()
	_open_dialog.popup_centered(Vector2i(900, 600))

func _on_save() -> void:
	_write_to(current_path)

func _on_save_as() -> void:
	_save_dialog.current_dir = current_path.get_base_dir()
	_save_dialog.current_file = current_path.get_file()
	_save_dialog.popup_centered(Vector2i(900, 600))

func _write_to(path: String) -> bool:
	if graph == null:
		status.text = "没有可保存的图"
		return false
	if not DialogueJson.save(path, graph.to_array()):
		status.text = "保存失败: " + path
		return false
	current_path = path
	dirty = false
	_refresh_status()
	status.text = "已保存: " + path
	return true

func _on_validate() -> void:
	error_list.clear()
	var issues := DialogueValidator.validate(graph)
	for it in issues:
		var prefix := "错误" if str(it.get("level", "warning")) == "error" else "警告"
		var idx := error_list.add_item("%s | %s: %s" % [
			prefix, graph.get_name_at(int(it.get("node_index", -1))), str(it.get("message", ""))])
		error_list.set_item_metadata(idx, int(it.get("node_index", -1)))
	status.text = "校验完成：%d 个问题" % issues.size()

func _on_error_selected(item: int) -> void:
	var node_index: int = int(error_list.get_item_metadata(item))
	if _focus_node(node_index):
		status.text = "定位: " + graph.get_name_at(node_index)

func _on_search_submitted(text: String) -> void:
	var key := text.strip_edges()
	if key.is_empty():
		return
	var idx := graph.index_of(key)
	if idx < 0:
		status.text = "找不到 DialogueName: " + key
		return
	_focus_node(idx)
	status.text = "定位: " + key

func _focus_node(node_index: int) -> bool:
	var n := graph_edit.get_node_or_null(NodePath("N_%d" % node_index))
	if not (n is GraphNode):
		return false
	for c in graph_edit.get_children():
		if c is GraphNode:
			c.set_selected(false)
	n.set_selected(true)
	var target: Vector2 = n.position_offset - graph_edit.size * 0.5
	graph_edit.set_scroll_offset(Vector2(maxf(0.0, target.x), maxf(0.0, target.y)))
	_on_node_selected(n)
	return true

func _on_auto_layout() -> void:
	DialogueAutoLayout.apply(graph, false)
	_mark_dirty()
	_rebuild()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if dirty:
			_close_dialog.popup_centered()
		else:
			get_tree().quit()
