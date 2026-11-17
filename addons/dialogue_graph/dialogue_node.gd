class_name DialogueGraphNode
extends GraphNode

const PID_COLORS := {
	1: Color("7fb3ff"),   # AI-9 青
	2: Color("ffb84d"),   # 幸存者 琥珀
	3: Color("7fd88f"),   # 林岚 绿
}
const DEF_COLOR := Color("9aa0a6")
const CHOICE_COLOR := Color("e0a44c")
const DEAD_COLOR := Color("c05050")

var graph: DialogueGraph
var node_index := -1

func setup(g: DialogueGraph, idx: int) -> void:
	graph = g
	node_index = idx
	name = "N_%d" % idx
	refresh()

func refresh() -> void:
	var d: Dictionary = graph.nodes[node_index]
	var attrs: Dictionary = d.get("attributes", {})
	var pid := int(attrs.get("pid", -1))
	title = "%s  ·  %s" % [graph.get_name_at(node_index), str(attrs.get("name", "?"))]
	add_theme_color_override("title_color", PID_COLORS.get(pid, Color.WHITE))

	for c in get_children():
		remove_child(c)
		c.queue_free()

	# 第 0 行 = 正文行，左侧输入口
	var body := Label.new()
	body.text = _preview(str(d.get("content", "")))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(280, 0)
	add_child(body)

	# 第 1..n 行 = 输出口；终点行有标签但没有右侧端口
	var rows := _output_rows()
	for r in rows:
		var l := Label.new()
		l.text = r.label
		l.add_theme_color_override("font_color", r.color)
		add_child(l)

	clear_all_slots()
	set_slot(0, true, 0, DEF_COLOR, false, 0, Color())
	for i in rows.size():
		set_slot(i + 1, false, 0, Color(), rows[i].port, 0, rows[i].color)

func _output_rows() -> Array:
	var d: Dictionary = graph.nodes[node_index]
	if graph.has_choices(node_index):
		var rows: Array = []
		var choices: Array = d.get("choices", [])
		for ci in choices.size():
			var t := str(choices[ci].get("text", ""))
			rows.append({"label": "选项%d：%s" % [ci + 1, _short(t, 12)], "color": CHOICE_COLOR, "port": true})
		return rows
	var target := graph.links_of(node_index)
	# 结局节点是真正的终点；其余节点即使是新建/未连接，也保留「下一条」输出口，
	# 否则新建节点只有输入口，没法继续连线。
	var is_ending := not graph.ending_of(node_index).is_empty()
	if is_ending:
		return [{"label": "■ 结局", "color": DEAD_COLOR, "port": false}]
	if target.is_empty():
		return [{"label": "→ 未连接（拖线到这里）", "color": DEF_COLOR, "port": true}]
	return [{"label": "→ " + target, "color": DEF_COLOR, "port": true}]

func _preview(s: String, max_len := 48) -> String:
	s = s.replace("\n", " ")
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len) + "…"

func _short(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n) + "…"
