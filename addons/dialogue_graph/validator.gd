class_name DialogueValidator
extends RefCounted

const VAR_TYPES := ["flag", "num", "str"]
const COMPARE_OPS := ["==", "!=", ">", "<", ">=", "<="]
const MUTATE_OPS := ["set", "add", "toggle"]

static func validate(g: DialogueGraph) -> Array:
	var issues: Array = []
	var seen_names: Dictionary = {}
	var seen_endings: Dictionary = {}
	var var_types: Dictionary = {}
	var refs: Dictionary = {}   # 被引用的 DialogueName -> true

	# 1) 名字/结局 id 唯一性 + 状态表达式
	for i in g.nodes.size():
		var n: String = g.get_name_at(i)
		if n.is_empty():
			_add(issues, "error", "empty_name", i, "DialogueName 为空")
		elif seen_names.has(n):
			_add(issues, "error", "duplicate_name", i, "DialogueName 重复: " + n)
		else:
			seen_names[n] = i

		var ending: Dictionary = g.ending_of(i)
		if not ending.is_empty():
			var eid := str(ending.get("id", ""))
			if eid.is_empty():
				_add(issues, "warning", "ending_no_id", i, "结局缺少 id")
			elif seen_endings.has(eid):
				_add(issues, "warning", "duplicate_ending_id", i, "结局 id 重复: " + eid)
			else:
				seen_endings[eid] = i

		if g.has_choices(i) and not g.links_of(i).is_empty():
			_add(issues, "error", "links_and_choices", i, "分支节点同时设置了 links，会被跳过")

		_check_state_exprs(g.nodes[i].get("set", []), "set", i, issues, var_types)
		_check_choices(g, i, issues, var_types)

	# 2) 悬空链接 + 引用收集
	for i in g.nodes.size():
		var n := g.get_name_at(i)
		for e in g.edges_of(i):
			refs[e.target] = true
			if g.index_of(e.target) == -1:
				_add(issues, "error", "dangling_link", i,
					"%s 指向不存在的节点 %s" % [n, e.target])

	# 3) 结局节点不该有出口
	for i in g.nodes.size():
		if not g.ending_of(i).is_empty() and not g.edges_of(i).is_empty():
			_add(issues, "error", "ending_has_exit", i, "结局节点仍挂着出口")
		if not g.ending_of(i).is_empty() and g.has_choices(i):
			_add(issues, "error", "ending_has_choices", i, "结局节点不能有选项")

	# 4) 从入口（第 0 个节点）可达性
	var reachable := {}
	if g.nodes.size() > 0:
		var queue: Array[int] = [0]
		while not queue.is_empty():
			var cur: int = queue.pop_front()
			if reachable.has(cur):
				continue
			reachable[cur] = true
			for e in g.edges_of(cur):
				var to := g.index_of(e.target)
				if to >= 0 and not reachable.has(to):
					queue.append(to)
	for i in g.nodes.size():
		if not reachable.has(i):
			_add(issues, "warning", "unreachable", i,
				"从入口不可达: " + g.get_name_at(i))

	return issues

static func _check_choices(g: DialogueGraph, i: int, issues: Array, var_types: Dictionary) -> void:
	if not g.has_choices(i):
		return
	var choices: Array = g.nodes[i]["choices"]
	var all_gated := true
	var all_dead := true
	for ci in choices.size():
		var c: Dictionary = choices[ci]
		if str(c.get("text", "")).strip_edges().is_empty():
			_add(issues, "error", "choice_no_text", i, "选项 %d 缺少文案" % (ci + 1))
		if c.has("if") and c["if"] is Array and not c["if"].is_empty():
			_check_if(c["if"], i, issues, var_types)
		else:
			all_gated = false
		var t = c.get("links", "")
		if t != null and str(t) != "":
			all_dead = false
		_check_state_exprs(c.get("set", []), "set", i, issues, var_types)
	if all_gated and all_dead:
		_add(issues, "warning", "softlock_choices", i,
			"所有选项都带 if 且没有回退 links，可能软锁")

static func _check_state_exprs(exprs, ctx: String, node_index: int, issues: Array, var_types: Dictionary) -> void:
	if exprs == null:
		return
	if not (exprs is Array):
		_add(issues, "error", "bad_state_expr", node_index, ctx + " 必须是数组")
		return
	for ex in exprs:
		if not (ex is Array) or ex.size() < 3 or not VAR_TYPES.has(str(ex[0])) or not MUTATE_OPS.has(str(ex[2])):
			_add(issues, "error", "bad_state_expr", node_index, ctx + " 表达式非法: " + str(ex))
			continue
		if str(ex[2]) != "toggle" and ex.size() < 4:
			_add(issues, "error", "bad_state_expr", node_index, ctx + " 缺少值: " + str(ex))
		var vn := str(ex[1])
		var vt := str(ex[0])
		if var_types.has(vn) and var_types[vn] != vt:
			_add(issues, "warning", "var_type_conflict", node_index,
				"变量 %s 类型不一致: %s vs %s" % [vn, var_types[vn], vt])
		var_types[vn] = vt

static func _check_if(conds, node_index: int, issues: Array, var_types: Dictionary) -> void:
	if not (conds is Array):
		_add(issues, "error", "bad_if", node_index, "if 必须是数组")
		return
	for c in conds:
		if not (c is Array) or c.size() < 4 or not VAR_TYPES.has(str(c[0])) or not COMPARE_OPS.has(str(c[2])):
			_add(issues, "error", "bad_if", node_index, "if 条件非法: " + str(c))
			continue
		var vn := str(c[1])
		var vt := str(c[0])
		if var_types.has(vn) and var_types[vn] != vt:
			_add(issues, "warning", "var_type_conflict", node_index,
				"变量 %s 类型不一致: %s vs %s" % [vn, var_types[vn], vt])
		var_types[vn] = vt

static func _add(issues: Array, level: String, code: String, idx: int, msg: String) -> void:
	issues.append({"level": level, "code": code, "node_index": idx, "message": msg})
