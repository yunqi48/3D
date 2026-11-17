class_name DialogueGraph
extends RefCounted

const LAYOUT_KEY := "_editor"

var nodes: Array = []
var _index_by_name: Dictionary = {}

static func from_array(data: Array) -> DialogueGraph:
	var g := DialogueGraph.new()
	g.nodes = data.duplicate(true)
	g.rebuild_index()
	return g

static func empty() -> DialogueGraph:
	return from_array([])

func rebuild_index() -> void:
	_index_by_name.clear()
	for i in nodes.size():
		var n := get_name_at(i)
		if not n.is_empty():
			_index_by_name[n] = i

func get_name_at(i: int) -> String:
	if i < 0 or i >= nodes.size():
		return ""
	return str(nodes[i].get("DialogueName", ""))

func index_of(name: String) -> int:
	return int(_index_by_name.get(name, -1))

func get_node_by_name(name: String) -> Dictionary:
	var i := index_of(name)
	return nodes[i] if i >= 0 else {}

func has_choices(i: int) -> bool:
	if i < 0 or i >= nodes.size():
		return false
	var c = nodes[i].get("choices", [])
	return c is Array and not c.is_empty()

func links_of(i: int) -> String:
	if i < 0 or i >= nodes.size():
		return ""
	var l = nodes[i].get("links", "")
	return "" if l == null else str(l)

func ending_of(i: int) -> Dictionary:
	if i < 0 or i >= nodes.size():
		return {}
	var e = nodes[i].get("ending", {})
	return e if e is Dictionary else {}

## 设为结局：结局节点不能有出口，也不能有选项（模板规则）。
func set_ending(i: int, ending: Dictionary) -> void:
	if i < 0 or i >= nodes.size():
		return
	nodes[i]["ending"] = ending.duplicate(true)
	nodes[i]["links"] = null
	nodes[i].erase("choices")

func clear_ending(i: int) -> void:
	if i < 0 or i >= nodes.size():
		return
	nodes[i].erase("ending")

## 出边列表：[{kind:"link"/"choice", choice_index:int, target:String}]
func edges_of(i: int) -> Array:
	var out: Array = []
	if has_choices(i):
		var choices: Array = nodes[i].get("choices", [])
		for ci in choices.size():
			var t = choices[ci].get("links", "")
			if t != null and str(t) != "":
				out.append({"kind": "choice", "choice_index": ci, "target": str(t)})
	else:
		var t := links_of(i)
		if not t.is_empty():
			out.append({"kind": "link", "choice_index": -1, "target": t})
	return out

func set_links(i: int, target: String) -> void:
	if i < 0 or i >= nodes.size():
		return
	nodes[i]["links"] = null if target.is_empty() else target

func set_choice_links(i: int, choice_index: int, target: String) -> void:
	if i < 0 or i >= nodes.size() or not has_choices(i):
		return
	var choices: Array = nodes[i]["choices"]
	if choice_index < 0 or choice_index >= choices.size():
		return
	choices[choice_index]["links"] = null if target.is_empty() else target

func set_position(i: int, pos: Vector2) -> void:
	if i < 0 or i >= nodes.size():
		return
	if not nodes[i].has(LAYOUT_KEY) or not (nodes[i][LAYOUT_KEY] is Dictionary):
		nodes[i][LAYOUT_KEY] = {}
	nodes[i][LAYOUT_KEY]["pos"] = [int(pos.x), int(pos.y)]

func position_of(i: int) -> Vector2:
	if i < 0 or i >= nodes.size():
		return Vector2(NAN, NAN)
	var e = nodes[i].get(LAYOUT_KEY, {})
	if not (e is Dictionary):
		return Vector2(NAN, NAN)
	var p = e.get("pos", [])
	if p is Array and p.size() == 2:
		return Vector2(float(p[0]), float(p[1]))
	return Vector2(NAN, NAN)

## 生成新节点（只写必要键，空 choices/set/ending 不落盘）
func create_node(dialogue_name: String, scene_name: String, pos: Vector2) -> int:
	var d := {
		"Scene": scene_name,
		"DialogueName": dialogue_name,
		"attributes": {"name": "", "pid": 1},
		"content": "",
		"links": null
	}
	d[LAYOUT_KEY] = {"pos": [int(pos.x), int(pos.y)]}
	nodes.append(d)
	rebuild_index()
	return nodes.size() - 1

func remove_node(i: int) -> void:
	if i < 0 or i >= nodes.size():
		return
	nodes.remove_at(i)
	rebuild_index()

func ensure_choices(i: int) -> Array:
	if i < 0 or i >= nodes.size():
		return []
	if not nodes[i].has("choices") or not (nodes[i]["choices"] is Array):
		nodes[i]["choices"] = []
	# 模板规则：有 choices 的节点 links 必须是 null，否则空格推进会把选项跳过
	nodes[i]["links"] = null
	return nodes[i]["choices"]

func to_array() -> Array:
	return nodes.duplicate(true)
