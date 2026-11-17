extends Control

const TEXT_PATH := "res://Text/Text.json"
const NODE_SCRIPT := preload("res://addons/dialogue_graph/dialogue_node.gd")
const MINIMAP := true
## 撤销步数上限（需求是至少能撤销前 10 步；这里放宽到 50）
const MAX_UNDO_STEPS := 50

const PREVIEW_COLORS := {
	1: "7fb3ff",
	2: "ffb84d",
	3: "7fd88f",
}

var graph: DialogueGraph
var dirty := false
var current_path := TEXT_PATH

var undo_redo := UndoRedo.new()
var _saved_snapshot := ""
var _edit_before := ""
var _edit_in_progress := false
var _applying_snapshot := false
var _text_undo_timer: Timer
var _selected_node_index := -1

var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _close_dialog: ConfirmationDialog

@onready var graph_edit: GraphEdit = %GraphEdit
@onready var inspector: VBoxContainer = %Inspector
@onready var error_list: ItemList = %ErrorList
@onready var status: Label = %Status

func _ready() -> void:
	# 工具场景不需要 FPS 的指针捕获：InputManager 是 autoload，会在 _ready 里
	# 把鼠标设成 CAPTURED，并在 _process 里每帧重新捕获。这里接管指针控制。
	var input_manager := get_node_or_null("/root/InputManager")
	if input_manager != null:
		input_manager.set_process(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

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
	%UndoButton.pressed.connect(_on_undo)
	%RedoButton.pressed.connect(_on_redo)

	graph_edit.begin_node_move.connect(_begin_edit)
	undo_redo.version_changed.connect(_refresh_undo_buttons)
	if undo_redo.has_method("set_max_steps"):
		undo_redo.set_max_steps(MAX_UNDO_STEPS)

	# 台词连续输入时合并成一步撤销（停止输入 0.7 秒后提交）
	_text_undo_timer = Timer.new()
	_text_undo_timer.one_shot = true
	_text_undo_timer.wait_time = 0.7
	_text_undo_timer.timeout.connect(func() -> void: _commit_edit("编辑台词"))
	add_child(_text_undo_timer)

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
	undo_redo.clear_history()
	_edit_in_progress = false
	_text_undo_timer.stop()
	_saved_snapshot = _snapshot()
	dirty = false
	_refresh_undo_buttons()
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

## 重建图但保持当前选中节点的 Inspector（新增/删除选项、条件、重命名后用）。
func _rebuild_keep_selection() -> void:
	var keep := ""
	if _selected_node_index >= 0 and _selected_node_index < graph.nodes.size():
		keep = graph.get_name_at(_selected_node_index)
	_rebuild()
	if not keep.is_empty():
		_restore_selection(keep)

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
	_begin_edit()
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
	_commit_edit("连接节点")

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var src := _node_by_name(from_node)
	if src == null:
		return
	_begin_edit()
	if graph.has_choices(src.node_index):
		graph.set_choice_links(src.node_index, from_port, "")
	else:
		graph.set_links(src.node_index, "")
	graph_edit.disconnect_node(from_node, from_port, to_node, to_port)
	src.refresh()
	_commit_edit("断开连接")

func _node_by_name(n: StringName) -> DialogueGraphNode:
	var c := graph_edit.get_node_or_null(NodePath(n))
	return c as DialogueGraphNode

func _mark_dirty() -> void:
	if _applying_snapshot:
		return
	dirty = true
	_refresh_status()

# ---------- 撤销 / 重做 ----------

func _snapshot() -> String:
	return DialogueJson.stringify_pretty(graph.to_array())

func _begin_edit() -> void:
	if _applying_snapshot or _edit_in_progress or graph == null:
		return
	_edit_in_progress = true
	_edit_before = _snapshot()

func _commit_edit(action_name: String) -> void:
	if not _edit_in_progress:
		return
	_edit_in_progress = false
	var after := _snapshot()
	if after == _edit_before:
		return
	var before := _edit_before
	undo_redo.create_action(action_name)
	# Godot 4.7：add_do_method / add_undo_method 只接受一个 Callable
	undo_redo.add_do_method(_apply_snapshot.bind(after))
	undo_redo.add_undo_method(_apply_snapshot.bind(before))
	# 界面/模型已经在编辑时更新过，这里不能再执行 do 方法，
	# 否则每次提交历史都会重建整图并把视图拉回选中节点（拖动节点后视角跳走）。
	undo_redo.commit_action(false)
	_mark_dirty()
	_refresh_undo_buttons()

func _apply_snapshot(snapshot: String) -> void:
	var data = DialogueJson.parse(snapshot)
	if not (data is Array):
		return
	var keep_name := ""
	if _selected_node_index >= 0 and _selected_node_index < graph.nodes.size():
		keep_name = graph.get_name_at(_selected_node_index)
	graph = DialogueGraph.from_array(data)
	dirty = _snapshot() != _saved_snapshot
	_applying_snapshot = true
	_rebuild()
	_applying_snapshot = false
	if not keep_name.is_empty():
		_restore_selection(keep_name)
	_refresh_undo_buttons()

## 撤销/重做后恢复选中节点和 Inspector，但保持当前视图滚动位置不变。
func _restore_selection(keep_name: String) -> void:
	var idx := graph.index_of(keep_name)
	if idx < 0:
		return
	var n := graph_edit.get_node_or_null(NodePath("N_%d" % idx))
	if n is GraphNode:
		n.set_selected(true)
		_on_node_selected(n)

func _on_undo() -> void:
	_text_undo_timer.stop()
	_commit_edit("编辑")
	undo_redo.undo()
	_refresh_undo_buttons()

func _on_redo() -> void:
	_text_undo_timer.stop()
	_commit_edit("编辑")
	undo_redo.redo()
	_refresh_undo_buttons()

func _refresh_undo_buttons() -> void:
	if is_instance_valid(%UndoButton):
		%UndoButton.disabled = not undo_redo.has_undo()
	if is_instance_valid(%RedoButton):
		%RedoButton.disabled = not undo_redo.has_redo()

## 全局 Ctrl+Z / Ctrl+Y（含 Ctrl+Shift+Z）：先于 TextEdit 的局部撤销执行，
## 保证撤销的是「对话词条编辑」而不是输入框内的字符。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if not k.is_command_or_control_pressed():
		return
	if k.keycode == KEY_Z and not k.shift_pressed:
		_on_undo()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_Y or (k.keycode == KEY_Z and k.shift_pressed):
		_on_redo()
		get_viewport().set_input_as_handled()

func _clear_inspector() -> void:
	for c in inspector.get_children():
		inspector.remove_child(c)
		c.queue_free()

func _on_node_selected(node: Node) -> void:
	if node is DialogueGraphNode:
		_selected_node_index = node.node_index
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
	_begin_edit()
	for i in idxs:
		graph.remove_node(i)
	_rebuild()
	_commit_edit("删除节点")

func _on_popup_request(at_position: Vector2) -> void:
	var menu := PopupMenu.new()
	add_child(menu)
	menu.add_item("新建对话节点", 0)
	menu.popup_hide.connect(menu.queue_free)
	menu.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_create_node_at(at_position))
	# 用 Popup 自带的父窗口定位：嵌入子窗口 / 屏幕缩放下也能贴住鼠标。
	# 之前用 DisplayServer.mouse_get_position() 是屏幕物理坐标，和嵌入窗口的
	# 逻辑坐标不是同一套，菜单会出现在偏离鼠标的位置。
	menu.popup_on_parent(Rect2i(Vector2i(get_viewport().get_mouse_position()), Vector2i.ZERO))

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
	_begin_edit()
	graph.create_node(new_name, scene_name, graph_pos)
	_rebuild()
	_restore_selection(new_name)   # 建完立即选中，直接编辑/接线
	_commit_edit("新建节点")

func _rename_node(i: int, new_name: String) -> void:
	if new_name == graph.get_name_at(i):
		return
	if new_name.is_empty() or graph.index_of(new_name) != -1:
		status.text = "DialogueName 为空或重复: " + new_name
		return
	_begin_edit()
	graph.nodes[i]["DialogueName"] = new_name
	graph.rebuild_index()
	_rebuild_keep_selection()
	_commit_edit("重命名节点")

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
	le.focus_entered.connect(_begin_edit)
	le.text_submitted.connect(func(t: String) -> void:
		on_commit.call(t)
		_commit_edit("编辑 " + label_text))
	le.focus_exited.connect(func() -> void:
		on_commit.call(le.text)
		_commit_edit("编辑 " + label_text))
	row.add_child(lb)
	row.add_child(le)
	inspector.add_child(row)
	return le

# 富文本操作后同步模型、预览和撤销历史
func _on_content_edited(te: TextEdit, d: Dictionary, n: DialogueGraphNode, refresh_preview: Callable) -> void:
	if not is_instance_valid(te) or not is_instance_valid(n):
		return
	_begin_edit()
	d["content"] = te.text
	n.refresh()
	refresh_preview.call()
	_mark_dirty()
	_text_undo_timer.start()

# 用 open_tag/close_tag 包住 TextEdit 的选中文字；没有选中就在光标处插入空标记
func _wrap_selection(te: TextEdit, open_tag: String, close_tag: String) -> void:
	if not te.has_selection():
		te.insert_text_at_caret(open_tag + close_tag)
		te.set_caret_column(maxi(0, te.get_caret_column() - close_tag.length()))
		return
	var from_line := te.get_selection_from_line()
	var from_col := te.get_selection_from_column()
	var selected := te.get_selected_text()
	te.delete_selection()
	te.set_caret_line(from_line)
	te.set_caret_column(from_col)
	te.insert_text_at_caret(open_tag + selected + close_tag)

# 去掉选中文字（或全文）里的 BBCode 标记
func _strip_selection_tags(te: TextEdit) -> void:
	var re := RegEx.new()
	re.compile("\\[[^\\]]*\\]")
	if te.has_selection():
		var from_line := te.get_selection_from_line()
		var from_col := te.get_selection_from_column()
		var cleaned := re.sub(te.get_selected_text(), "", true)
		te.delete_selection()
		te.set_caret_line(from_line)
		te.set_caret_column(from_col)
		te.insert_text_at_caret(cleaned)
	else:
		te.text = re.sub(te.text, "", true)

func _build_inspector(n: DialogueGraphNode) -> void:
	_clear_inspector()
	if n == null or n.node_index < 0 or n.node_index >= graph.nodes.size():
		return
	var i := n.node_index
	var d: Dictionary = graph.nodes[i]
	if not d.has("attributes") or not (d["attributes"] is Dictionary):
		d["attributes"] = {}
	var attrs: Dictionary = d["attributes"]

	# 预览控件先创建，稍后插入到台词输入框下方
	var preview := RichTextLabel.new()
	preview.bbcode_enabled = true
	preview.fit_content = true
	preview.scroll_active = false
	preview.custom_minimum_size = Vector2(0, 72)
	var refresh_preview := func() -> void:
		var pid := int(attrs.get("pid", 1))
		var col: String = PREVIEW_COLORS.get(pid, "9aa0a6")
		preview.text = "[color=#%s]%s[/color]\n%s" % [
			col, str(attrs.get("name", "")), str(d.get("content", ""))]

	_field("Scene", str(d.get("Scene", "")), func(t: String) -> void:
		_begin_edit()
		d["Scene"] = t
		_mark_dirty())
	_field("DialogueName", graph.get_name_at(i), func(t: String) -> void:
		_rename_node(i, t.strip_edges()))
	_field("说话人", str(attrs.get("name", "")), func(t: String) -> void:
		_begin_edit()
		attrs["name"] = t
		n.refresh()
		refresh_preview.call()
		_mark_dirty())
	_field("立绘", str(attrs.get("avatar", "")), func(t: String) -> void:
		_begin_edit()
		attrs["avatar"] = t
		_mark_dirty())
	var links_commit := func(t: String) -> void:
		_begin_edit()
		graph.set_links(i, t.strip_edges())
		n.refresh()
		_mark_dirty()
	_field("links", graph.links_of(i), links_commit, not graph.has_choices(i))

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
	opt.focus_entered.connect(_begin_edit)
	opt.item_selected.connect(func(idx: int) -> void:
		_begin_edit()
		attrs["pid"] = opt.get_item_id(idx)
		n.refresh()
		refresh_preview.call()
		_mark_dirty()
		_commit_edit("修改说话人编号"))
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
	te.deselect_on_focus_loss_enabled = false
	te.focus_entered.connect(_begin_edit)
	te.text_changed.connect(func() -> void:
		_begin_edit()
		d["content"] = te.text
		n.refresh()
		refresh_preview.call()
		_mark_dirty()
		_text_undo_timer.start())
	te.focus_exited.connect(func() -> void:
		_text_undo_timer.stop()
		_commit_edit("编辑台词"))
	inspector.add_child(te)

	# 富文本工具条：给选中文字包上 BBCode 标记
	var fmt := HBoxContainer.new()
	inspector.add_child(fmt)
	for spec in [
		{"text": "B", "open": "[b]", "close": "[/b]"},
		{"text": "I", "open": "[i]", "close": "[/i]"},
		{"text": "U", "open": "[u]", "close": "[/u]"},
		{"text": "S", "open": "[s]", "close": "[/s]"},
	]:
		var b := Button.new()
		b.text = str(spec["text"])
		b.tooltip_text = "给选中文字加标记；未选中时在光标处插入空标记"
		b.pressed.connect(func() -> void:
			_wrap_selection(te, str(spec["open"]), str(spec["close"]))
			_on_content_edited(te, d, n, refresh_preview))
		fmt.add_child(b)

	var color_pairs := [
		["青", "7fb3ff"], ["琥珀", "ffb84d"], ["绿", "7fd88f"],
		["红", "ff6b6b"], ["灰", "9aa0a6"],
	]
	var color_opt := OptionButton.new()
	color_opt.add_item("颜色 ▾")
	for pair in color_pairs:
		color_opt.add_item(str(pair[0]))
	color_opt.item_selected.connect(func(idx: int) -> void:
		if idx <= 0:
			return
		var hex: String = str(color_pairs[idx - 1][1])
		_wrap_selection(te, "[color=#%s]" % hex, "[/color]")
		_on_content_edited(te, d, n, refresh_preview)
		color_opt.select(0))
	fmt.add_child(color_opt)

	var sizes := ["14", "16", "20", "24"]
	var size_opt := OptionButton.new()
	size_opt.add_item("字号 ▾")
	for s in sizes:
		size_opt.add_item(s)
	size_opt.item_selected.connect(func(idx: int) -> void:
		if idx <= 0:
			return
		_wrap_selection(te, "[font_size=%s]" % sizes[idx - 1], "[/font_size]")
		_on_content_edited(te, d, n, refresh_preview)
		size_opt.select(0))
	fmt.add_child(size_opt)

	var clear_btn := Button.new()
	clear_btn.text = "清除格式"
	clear_btn.tooltip_text = "移除选中文字里的 BBCode 标记"
	clear_btn.pressed.connect(func() -> void:
		_strip_selection_tags(te)
		_on_content_edited(te, d, n, refresh_preview))
	fmt.add_child(clear_btn)

	var pv_label := Label.new()
	pv_label.text = "预览"
	inspector.add_child(pv_label)
	inspector.add_child(preview)
	refresh_preview.call()

	# 节点级 set：进入本节点时修改状态
	_build_set_editor(d, "进入本节点时改状态")

	# 普通文本节点：提供「转为分支」入口；结局节点不允许有选项
	if not graph.has_choices(i):
		if not graph.ending_of(i).is_empty():
			var eh := Label.new()
			eh.text = "  （结局节点不能添加选项）"
			eh.add_theme_color_override("font_color", Color("9aa0a6"))
			inspector.add_child(eh)
		else:
			var to_branch := Button.new()
			to_branch.text = "＋ 添加选项（转为分支）"
			to_branch.tooltip_text = "把线性节点变成分支节点；原来的下一条会放进第一个选项"
			to_branch.pressed.connect(func() -> void:
				_begin_edit()
				var old_target := graph.links_of(i)
				var arr := graph.ensure_choices(i)
				arr.append({"text": "新选项", "links": null if old_target.is_empty() else old_target})
				_rebuild_keep_selection()
				_commit_edit("添加选项（转为分支）"))
			inspector.add_child(to_branch)

	# 选项编辑器（仅分支节点）
	if graph.has_choices(i):
		var h := Label.new()
		h.text = "— 选项 —"
		inspector.add_child(h)
		var choices: Array = d["choices"]
		for ci in choices.size():
			var c: Dictionary = choices[ci]
			_field("选项%d 文案" % (ci + 1), str(c.get("text", "")), func(t: String) -> void:
				_begin_edit()
				c["text"] = t
				n.refresh()
				_mark_dirty())
			_field("选项%d 目标" % (ci + 1), "" if c.get("links") == null else str(c.get("links")), func(t: String) -> void:
				_begin_edit()
				c["links"] = null if t.strip_edges().is_empty() else t.strip_edges()
				n.refresh()
				_mark_dirty())
			_build_condition_editor(c)
			# 选项级 set：点选后修改状态
			_build_set_editor(c, "点选后改状态")
			var del := Button.new()
			del.text = "删除选项 %d" % (ci + 1)
			del.pressed.connect(func() -> void:
				_begin_edit()
				choices.remove_at(ci)
				if choices.is_empty():
					d.erase("choices")
				_rebuild_keep_selection()
				_commit_edit("删除选项"))
			inspector.add_child(del)
		var add := Button.new()
		add.text = "＋ 选项"
		add.pressed.connect(func() -> void:
			_begin_edit()
			graph.ensure_choices(i).append({"text": "新选项", "links": null})
			_rebuild_keep_selection()
			_commit_edit("新增选项"))
		inspector.add_child(add)

	# 结局区块：没有 ending 时提供创建入口；有 ending 时编辑 + 移除
	var ending: Dictionary = graph.ending_of(i)
	var end_header := Label.new()
	end_header.text = "— 结局 —"
	inspector.add_child(end_header)
	if ending.is_empty():
		if graph.has_choices(i):
			var end_hint := Label.new()
			end_hint.text = "  分支节点不能设为结局（先删除所有选项）"
			end_hint.add_theme_color_override("font_color", Color("9aa0a6"))
			inspector.add_child(end_hint)
		else:
			var make_ending := Button.new()
			make_ending.text = "＋ 设为结局"
			make_ending.tooltip_text = "结局节点没有下一条；会断开当前连线"
			make_ending.pressed.connect(func() -> void:
				_begin_edit()
				graph.set_ending(i, {
					"id": _default_ending_id(i),
					"title": "结局",
					"subtitle": "",
					"next_scene": "",
				})
				_rebuild_keep_selection()
				_commit_edit("设为结局"))
			inspector.add_child(make_ending)
	else:
		for key in ["id", "title", "subtitle", "next_scene"]:
			_field("ending." + key, str(ending.get(key, "")), func(t: String) -> void:
				_begin_edit()
				ending[key] = t
				_mark_dirty())
		var remove_ending := Button.new()
		remove_ending.text = "移除结局"
		remove_ending.pressed.connect(func() -> void:
			_begin_edit()
			graph.clear_ending(i)
			_rebuild_keep_selection()
			_commit_edit("移除结局"))
		inspector.add_child(remove_ending)

# 结局 id 默认取节点名的蛇形形式，重复时自动加序号
func _default_ending_id(i: int) -> String:
	var base := graph.get_name_at(i).to_lower().replace(".", "_").replace(" ", "_")
	if base.is_empty():
		base = "ending"
	var candidate := base
	var suffix := 2
	while _ending_id_exists(candidate):
		candidate = "%s_%d" % [base, suffix]
		suffix += 1
	return candidate

func _ending_id_exists(ending_id: String) -> bool:
	for j in graph.nodes.size():
		if str(graph.ending_of(j).get("id", "")) == ending_id:
			return true
	return false

# ---------- 分支选项的 if 条件编辑 ----------

func _ensure_conditions(c: Dictionary) -> Array:
	if not c.has("if") or not (c["if"] is Array):
		c["if"] = []
	return c["if"]

func _build_condition_editor(c: Dictionary) -> void:
	var conds: Array = []
	if c.get("if") is Array:
		conds = c["if"]

	var header := Label.new()
	header.text = "  条件（全部满足才显示）"
	inspector.add_child(header)

	if conds.is_empty():
		var hint := Label.new()
		hint.text = "  （无条件：总是显示）"
		hint.add_theme_color_override("font_color", Color("9aa0a6"))
		inspector.add_child(hint)
	for cond_i in conds.size():
		_build_condition_row(c, cond_i)

	var add := Button.new()
	add.text = "＋ 条件"
	add.pressed.connect(func() -> void:
		_begin_edit()
		_ensure_conditions(c).append(["flag", "new_flag", "==", true])
		_rebuild_keep_selection()
		_commit_edit("新增分支条件"))
	inspector.add_child(add)

func _build_condition_row(c: Dictionary, cond_i: int) -> void:
	var conds: Array = c["if"]
	var cond: Array = conds[cond_i]
	var vtype := str(cond[0]) if cond.size() > 0 else "flag"
	var vname := str(cond[1]) if cond.size() > 1 else ""
	var vop := str(cond[2]) if cond.size() > 2 else "=="
	var vval = cond[3] if cond.size() > 3 else true

	var row := HBoxContainer.new()
	inspector.add_child(row)
	var idx_label := Label.new()
	idx_label.text = "%d." % (cond_i + 1)
	row.add_child(idx_label)

	var types := ["flag", "num", "str"]
	var type_opt := OptionButton.new()
	for t in types:
		type_opt.add_item(t)
	type_opt.select(maxi(0, types.find(vtype)))
	type_opt.tooltip_text = "变量类型"
	row.add_child(type_opt)

	var var_edit := LineEdit.new()
	var_edit.text = vname
	var_edit.custom_minimum_size = Vector2(80, 0)
	var_edit.tooltip_text = "变量名（蛇形命名，如 has_chip）"
	row.add_child(var_edit)

	var ops := ["==", "!=", ">", "<", ">=", "<="]
	var op_opt := OptionButton.new()
	for o in ops:
		op_opt.add_item(o)
	op_opt.select(maxi(0, ops.find(vop)))
	op_opt.tooltip_text = "运算符"
	row.add_child(op_opt)

	var val_edit := LineEdit.new()
	val_edit.text = _cond_value_text(vtype, vval)
	val_edit.custom_minimum_size = Vector2(64, 0)
	val_edit.tooltip_text = "比较值（flag 填 true/false）"
	row.add_child(val_edit)

	var del := Button.new()
	del.text = "×"
	del.tooltip_text = "删除这条条件"
	row.add_child(del)

	type_opt.item_selected.connect(func(idx: int) -> void:
		_begin_edit()
		while cond.size() < 4:
			cond.append(null)
		cond[0] = types[idx]
		cond[3] = _default_cond_value(types[idx])
		_rebuild_keep_selection()
		_commit_edit("修改条件类型"))
	op_opt.item_selected.connect(func(idx: int) -> void:
		_begin_edit()
		while cond.size() < 4:
			cond.append(null)
		cond[2] = ops[idx]
		_commit_edit("修改条件运算符"))

	var_edit.focus_entered.connect(_begin_edit)
	var_edit.text_submitted.connect(func(t: String) -> void:
		_begin_edit()
		_write_cond_var(cond, t)
		_commit_edit("编辑条件变量"))
	var_edit.focus_exited.connect(func() -> void:
		_begin_edit()
		_write_cond_var(cond, var_edit.text)
		_commit_edit("编辑条件变量"))

	val_edit.focus_entered.connect(_begin_edit)
	val_edit.text_submitted.connect(func(t: String) -> void:
		_begin_edit()
		_write_cond_value(cond, vtype, t)
		_commit_edit("编辑条件值"))
	val_edit.focus_exited.connect(func() -> void:
		_begin_edit()
		_write_cond_value(cond, vtype, val_edit.text)
		_commit_edit("编辑条件值"))

	del.pressed.connect(func() -> void:
		_begin_edit()
		conds.remove_at(cond_i)
		if conds.is_empty():
			c.erase("if")
		_rebuild_keep_selection()
		_commit_edit("删除分支条件"))

func _write_cond_var(cond: Array, value: String) -> void:
	while cond.size() < 4:
		cond.append(null)
	cond[1] = value.strip_edges()

func _write_cond_value(cond: Array, type: String, text: String) -> void:
	while cond.size() < 4:
		cond.append(null)
	cond[3] = _parse_cond_value(type, text)

func _parse_cond_value(type: String, text: String):
	var t := text.strip_edges()
	match type:
		"flag":
			return t.to_lower() == "true"
		"num":
			if t.is_valid_int():
				return int(t)
			return t.to_float()
		_:
			return text

func _cond_value_text(type: String, value) -> String:
	if type == "flag":
		return "true" if bool(value) else "false"
	return str(value)

func _default_cond_value(type: String):
	match type:
		"flag":
			return true
		"num":
			return 0
		_:
			return ""

# ---------- set（状态修改）编辑 ----------

func _ensure_set(target: Dictionary) -> Array:
	if not target.has("set") or not (target["set"] is Array):
		target["set"] = []
	return target["set"]

func _build_set_editor(target: Dictionary, header_text: String) -> void:
	var list: Array = []
	if target.get("set") is Array:
		list = target["set"]

	var header := Label.new()
	header.text = "  " + header_text
	inspector.add_child(header)

	if list.is_empty():
		var hint := Label.new()
		hint.text = "  （不改状态）"
		hint.add_theme_color_override("font_color", Color("9aa0a6"))
		inspector.add_child(hint)
	for set_i in list.size():
		_build_set_row(target, set_i)

	var add := Button.new()
	add.text = "＋ 状态"
	add.pressed.connect(func() -> void:
		_begin_edit()
		_ensure_set(target).append(["flag", "new_flag", "set", true])
		_rebuild_keep_selection()
		_commit_edit("新增状态修改"))
	inspector.add_child(add)

func _build_set_row(target: Dictionary, set_i: int) -> void:
	var list: Array = target["set"]
	var item: Array = list[set_i]
	var vtype := str(item[0]) if item.size() > 0 else "flag"
	var vname := str(item[1]) if item.size() > 1 else ""
	var vop := str(item[2]) if item.size() > 2 else "set"
	var has_value := vop != "toggle"
	var vval = item[3] if item.size() > 3 else _default_cond_value(vtype)

	var row := HBoxContainer.new()
	inspector.add_child(row)
	var idx_label := Label.new()
	idx_label.text = "%d." % (set_i + 1)
	row.add_child(idx_label)

	var types := ["flag", "num", "str"]
	var type_opt := OptionButton.new()
	for t in types:
		type_opt.add_item(t)
	type_opt.select(maxi(0, types.find(vtype)))
	type_opt.tooltip_text = "变量类型"
	row.add_child(type_opt)

	var var_edit := LineEdit.new()
	var_edit.text = vname
	var_edit.custom_minimum_size = Vector2(80, 0)
	var_edit.tooltip_text = "变量名（蛇形命名）"
	row.add_child(var_edit)

	var ops := ["set", "add", "toggle"]
	var op_opt := OptionButton.new()
	for o in ops:
		op_opt.add_item(o)
	op_opt.select(maxi(0, ops.find(vop)))
	op_opt.tooltip_text = "set=赋值 / add=数字加 / toggle=flag 翻转"
	row.add_child(op_opt)

	var val_edit := LineEdit.new()
	val_edit.text = _cond_value_text(vtype, vval)
	val_edit.custom_minimum_size = Vector2(64, 0)
	val_edit.editable = has_value
	val_edit.placeholder_text = "" if has_value else "toggle 不需要值"
	row.add_child(val_edit)

	var del := Button.new()
	del.text = "×"
	del.tooltip_text = "删除这条状态修改"
	row.add_child(del)

	type_opt.item_selected.connect(func(idx: int) -> void:
		_begin_edit()
		while item.size() < 3:
			item.append(null)
		item[0] = types[idx]
		if item.size() > 3:
			item[3] = _default_cond_value(types[idx])
		_rebuild_keep_selection()
		_commit_edit("修改状态类型"))

	op_opt.item_selected.connect(func(idx: int) -> void:
		_begin_edit()
		var new_op: String = ops[idx]
		while item.size() < 3:
			item.append(null)
		item[2] = new_op
		if new_op == "toggle":
			item.resize(3)   # toggle 是 3 元素，不带值
		else:
			while item.size() < 4:
				item.append(_default_cond_value(str(item[0])))
		_rebuild_keep_selection()
		_commit_edit("修改状态操作"))

	var_edit.focus_entered.connect(_begin_edit)
	var_edit.text_submitted.connect(func(t: String) -> void:
		_begin_edit()
		while item.size() < 3:
			item.append(null)
		item[1] = t.strip_edges()
		_commit_edit("编辑状态变量"))
	var_edit.focus_exited.connect(func() -> void:
		_begin_edit()
		while item.size() < 3:
			item.append(null)
		item[1] = var_edit.text.strip_edges()
		_commit_edit("编辑状态变量"))

	if has_value:
		val_edit.focus_entered.connect(_begin_edit)
		val_edit.text_submitted.connect(func(t: String) -> void:
			_begin_edit()
			while item.size() < 4:
				item.append(null)
			item[3] = _parse_cond_value(vtype, t)
			_commit_edit("编辑状态值"))
		val_edit.focus_exited.connect(func() -> void:
			_begin_edit()
			while item.size() < 4:
				item.append(null)
			item[3] = _parse_cond_value(vtype, val_edit.text)
			_commit_edit("编辑状态值"))

	del.pressed.connect(func() -> void:
		_begin_edit()
		list.remove_at(set_i)
		if list.is_empty():
			target.erase("set")
		_rebuild_keep_selection()
		_commit_edit("删除状态修改"))

func _on_end_node_move() -> void:
	for c in graph_edit.get_children():
		if c is DialogueGraphNode:
			graph.set_position(c.node_index, c.position_offset)
	_commit_edit("移动节点")

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
	_saved_snapshot = _snapshot()
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
	_begin_edit()
	DialogueAutoLayout.apply(graph, false)
	_rebuild()
	_commit_edit("自动布局")

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if dirty:
			_close_dialog.popup_centered()
		else:
			get_tree().quit()
