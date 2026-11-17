# 对话图可视化编辑器（GraphEdit 蓝图式）MVP 实施计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 Godot 4.7 内做一个蓝图式的对话图编辑器：从 `Text/Text.json` 导入节点与连线，可视化编辑后无损写回同一文件，游戏运行时零改动。

**Architecture:** `GraphEdit + GraphNode` 做画布；纯数据层 `DialogueGraph` 负责 JSON ⇄ 内存模型（保留未知字段、无损往返）；`DialogueValidator` 做结构校验；`DialogueAutoLayout` 做确定性的分层排版；编辑器 UI 只负责把模型渲染成节点、把用户操作写回模型。布局坐标以 `_editor.pos` 内嵌在 JSON 节点里（`JsonHelper` 只取已知字段，多余键被忽略，见 `Text/JsonHelper.gd:26`）。

**Tech Stack:** Godot 4.7.2 (GDScript)、GraphEdit/GraphNode、内置 `JsonHelper`、headless `SceneTree` 测试脚本。

---

## 0. 现状与约束（已验证）

| 事实 | 依据 |
|---|---|
| 游戏对话数据唯一来源是 `Text/Text.json` | `Dode/mainpanle.gd:39` |
| 解析器只挑已知键，未知键（如 `_editor`）安全忽略 | `Text/JsonHelper.gd:26-52` |
| 游戏从数组第 **0** 个节点开始播 | `Dode/mainpanle.gd:42` `_show_dialogue(0)` |
| 当前数据：54 节点、5 个分支节点、6 个结局 | 已用 node 脚本统计 |
| 节点实际字段：`Scene / DialogueName / attributes / content / links / choices / set / ending` | 同上；空字段经常省略 |
| 已有编辑器插件先例（启用方式可复制） | `addons/json_editor/plugin.cfg`、`project.godot:34` |
| headless 脚本可跑：`godot --headless --path . --script res://xxx.gd` | 已实测输出 `HEADLESS_OK 4.7.2-stable` |
| Godot 可执行文件 | `D:\Software\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe` |

**必须遵守的语义（来自 `Text/DialogueTemplate.json`）：**
- `DialogueName` 全局唯一，是跳转 ID。
- 节点有 `choices` 时 `links` 必须是 `null`，否则空格会把台词跳过。
- 终点节点：`links: null` 且无 `choices`。
- 选项按数组顺序显示；`if` 为多条 AND；变量没出现过 = 条件不满足。

---

## 1. 关键决策（先定死，避免实现时摇摆）

| 决策 | 选择 | 理由 |
|---|---|---|
| 技术栈 | Godot 内置 GraphEdit，不做 Web 编辑器 | 单一栈、可复用 54 节点、运行时零改动 |
| 真源 | `Text/Text.json` 唯一真源 | 不引入第二份图文件，杜绝同步 bug |
| 布局存储 | 内嵌 `_editor: {"pos": [x, y]}` | 解析器忽略未知键；单文件；不需要 sidecar |
| 往返策略 | 保留每个节点的原始 Dictionary，只 patch 被编辑的键 | `_comment`、自定义字段零丢失 |
| 入口定义 | 数组第 0 个节点为入口 | 与 `mainpanle.gd` 的 `_show_dialogue(0)` 一致 |
| 插件形态 | MVP 先是独立工具场景，插件只加一个"打开编辑器"菜单项 | 避开 EditorUndoRedoManager / panel 生命周期坑 |
| 新建节点字段 | 只写必要键，空数组/空字典不落盘 | 保持文件精简、diff 干净 |
| 测试 | headless `SceneTree` 脚本 + 自写断言 | 不引入 GUT 依赖 |

---

## 2. 图语义（节点端口规则）

```
无 choices 且 links 非空   →  1 个输出口 "→ 目标"
有 choices                →  每个选项 1 个输出口（颜色区别于普通口）
links 为空且无 choices     →  0 个输出口（终点/死路）
所有节点                  →  1 个输入口
```

- 连线写入：普通口 → `links`；第 i 个选项口 → `choices[i].links`。
- 断开连线 → 把对应字段写成 `null`（普通节点写 `null`，与模板一致）。
- 分支节点的选项口数随 `choices` 变化，重建节点时按端口索引重连。

---

## 3. 文件清单

```
addons/dialogue_graph/
  plugin.cfg
  plugin.gd
  dialogue_editor.tscn
  dialogue_editor.gd
  dialogue_node.gd
  graph_model.gd          # class_name DialogueGraph
  validator.gd            # class_name DialogueValidator
  auto_layout.gd          # class_name DialogueAutoLayout
tests/
  run_tests.gd
  test_graph_model.gd
  test_validator.gd
  test_auto_layout.gd
docs/plans/2026-11-17-dialogue-graph-editor.md
```

修改：`project.godot`（`[editor_plugins] enabled` 追加 `dialogue_graph`）。

---

## Task 0：建目录 + headless 测试运行器

**Files:**
- Create: `tests/run_tests.gd`

**Step 1: 写失败测试运行器**（此任务本身就是基础设施，直接写最终版）

```gdscript
extends SceneTree

const TESTS := [
	"res://tests/test_graph_model.gd",
	"res://tests/test_validator.gd",
	"res://tests/test_auto_layout.gd",
]

var _checks := 0
var _failures := 0

func _initialize() -> void:
	for path in TESTS:
		var script: GDScript = load(path)
		if script == null:
			printerr("无法加载测试: ", path)
			_failures += 1
			continue
		print("== ", path)
		var test = script.new()
		test.run(self)
	print("checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("ALL TESTS PASSED")
		quit(0)
	else:
		printerr("TESTS FAILED")
		quit(1)

func expect(actual, expected, msg: String) -> void:
	_checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_failures += 1
		printerr("FAIL: %s (expected=%s actual=%s)" % [msg, str(expected), str(actual)])

func expect_true(cond: bool, msg: String) -> void:
	expect(cond, true, msg)

func expect_false(cond: bool, msg: String) -> void:
	expect(cond, false, msg)

func expect_has_issue(issues: Array, code: String, msg: String) -> void:
	var found := false
	for it in issues:
		if it.get("code", "") == code:
			found = true
			break
	expect_true(found, msg)
```

**Step 2: 先建占位测试文件，跑通命令**

三个测试文件先写成：

```gdscript
extends RefCounted

func run(_t) -> void:
	pass
```

Run:
```bash
"D:/Software/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
  --headless --path "D:/Project/GodotProject/3D" --script res://tests/run_tests.gd
```
Expected: 末尾输出 `checks=0 failures=0` 和 `ALL TESTS PASSED`，退出码 0。

> 若提示找不到 `class_name`，先执行一次
> `godot --headless --path . --editor --quit` 让 Godot 扫描脚本，再跑测试。

**Step 3: Commit**

```bash
git add tests/run_tests.gd tests/test_graph_model.gd tests/test_validator.gd tests/test_auto_layout.gd
git commit -m "test: add headless test runner for dialogue graph editor"
```

---

## Task 1：数据模型 `DialogueGraph`（无损往返）

**Files:**
- Create: `addons/dialogue_graph/graph_model.gd`
- Test: `tests/test_graph_model.gd`

**Step 1: 写失败测试**

```gdscript
extends RefCounted

func run(t) -> void:
	var raw := [
		{
			"Scene": "Bunker",
			"DialogueName": "Bunker.001",
			"attributes": {"name": "AI-9", "pid": 1},
			"content": "A",
			"links": "Bunker.002",
			"_comment": "保留我"
		},
		{
			"Scene": "Bunker",
			"DialogueName": "Bunker.002",
			"attributes": {"name": "幸存者", "pid": 2},
			"content": "B",
			"links": null,
			"choices": [
				{"text": "走", "links": "Bunker.003"},
				{"text": "留", "links": null}
			]
		},
		{
			"Scene": "Bunker",
			"DialogueName": "Bunker.003",
			"attributes": {"name": "幸存者", "pid": 2},
			"content": "C",
			"links": null,
			"ending": {"id": "e1"}
		}
	]

	var g := DialogueGraph.from_array(raw)
	t.expect(g.nodes.size(), 3, "节点数")
	t.expect(g.index_of("Bunker.002"), 1, "按名字取索引")
	t.expect(g.index_of("不存在"), -1, "未知名字返回 -1")
	t.expect(g.has_choices(1), true, "Bunker.002 是分支")
	t.expect(g.has_choices(0), false, "Bunker.001 不是分支")

	var edges := g.edges_of(1)
	t.expect(edges.size(), 1, "空 links 的选项不产生边")
	t.expect(edges[0].target, "Bunker.003", "选项边目标")
	t.expect(edges[0].choice_index, 0, "选项边索引")

	t.expect(g.links_of(0), "Bunker.002", "普通 links 读取")
	t.expect(g.links_of(2), "", "null links 归一为空串")

	# 无损往返：未改动时序列化结果与输入完全一致（含 _comment）
	t.expect(JSON.stringify(g.to_array()), JSON.stringify(raw), "无损往返")

	# patch 不丢未知键
	g.set_links(0, "Bunker.003")
	t.expect(g.nodes[0]["_comment"], "保留我", "patch 后未知键仍在")

	# 布局读写
	t.expect_true(is_nan(g.position_of(0).x), "无坐标时返回 NaN")
	g.set_position(0, Vector2(120, 340))
	t.expect(g.position_of(0), Vector2(120, 340), "坐标读写")
	t.expect(JSON.stringify(g.to_array()[0]["_editor"]["pos"]), "[120,340]", "坐标序列化为整数数组")
```

**Step 2: 运行，确认失败**

Run: 同 Task 0 命令
Expected: FAIL 于 `DialogueGraph` 未定义（解析/加载报错），退出码 1。

**Step 3: 实现**

```gdscript
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
	if not nodes[i].has("choices") or not (nodes[i]["choices"] is Array):
		nodes[i]["choices"] = []
		nodes[i]["links"] = null
	return nodes[i]["choices"]

func to_array() -> Array:
	return nodes.duplicate(true)
```

**Step 4: 跑测试**

Expected: `checks=... failures=0` + `ALL TESTS PASSED`.

**Step 5: Commit**

```bash
git add addons/dialogue_graph/graph_model.gd tests/test_graph_model.gd
git commit -m "feat: add lossless DialogueGraph model"
```

---

## Task 2：校验器 `DialogueValidator`

**Files:**
- Create: `addons/dialogue_graph/validator.gd`
- Test: `tests/test_validator.gd`

**Step 1: 写失败测试**

```gdscript
extends RefCounted

func run(t) -> void:
	var raw := [
		{"Scene": "B", "DialogueName": "A", "content": "", "links": "B",
			"attributes": {"pid": 1}},
		{"Scene": "B", "DialogueName": "B", "content": "", "links": "C",
			"choices": [{"text": "x", "links": "A"}], "attributes": {"pid": 1}},
		{"Scene": "B", "DialogueName": "C", "content": "", "links": "失踪",
			"attributes": {"pid": 1}},
		{"Scene": "B", "DialogueName": "C", "content": "", "links": null,
			"attributes": {"pid": 1}},
		{"Scene": "B", "DialogueName": "孤儿", "content": "", "links": null,
			"attributes": {"pid": 1}, "ending": {"id": "e1"}},
		{"Scene": "B", "DialogueName": "坏结局", "content": "", "links": "A",
			"attributes": {"pid": 1}, "ending": {"id": "e1"}},
		{"Scene": "B", "DialogueName": "坏状态", "content": "", "links": null,
			"attributes": {"pid": 1}, "set": [["wat", "x", "set", 1]]},
		{"Scene": "B", "DialogueName": "软锁", "content": "", "links": null,
			"attributes": {"pid": 1},
			"choices": [{"text": "a", "links": "", "if": [["flag", "f", "==", true]]}]}
	]
	var issues := DialogueValidator.validate(DialogueGraph.from_array(raw))

	t.expect_has_issue(issues, "duplicate_name", "重复 DialogueName")
	t.expect_has_issue(issues, "links_and_choices", "links 与 choices 同时存在")
	t.expect_has_issue(issues, "dangling_link", "悬空 links")
	t.expect_has_issue(issues, "unreachable", "不可达节点")
	t.expect_has_issue(issues, "ending_has_exit", "结局节点还有出口")
	t.expect_has_issue(issues, "duplicate_ending_id", "结局 id 重复")
	t.expect_has_issue(issues, "bad_state_expr", "set 表达式非法")
	t.expect_has_issue(issues, "softlock_choices", "选项全被条件过滤且无回退")

	# 每个 issue 必含这些键，UI 依赖
	for it in issues:
		t.expect_true(it.has("level") and it.has("code") and it.has("node_index") and it.has("message"),
			"issue 字段完整: " + str(it.get("code", "")))
```

**Step 2: 运行确认失败**

**Step 3: 实现**

```gdscript
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
```

**Step 4: 跑测试**

Expected: `ALL TESTS PASSED`。

**Step 5: Commit**

```bash
git add addons/dialogue_graph/validator.gd tests/test_validator.gd
git commit -m "feat: add dialogue graph validator"
```

---

## Task 3：自动布局 `DialogueAutoLayout`

**Files:**
- Create: `addons/dialogue_graph/auto_layout.gd`
- Test: `tests/test_auto_layout.gd`

**Step 1: 写失败测试**

```gdscript
extends RefCounted

func run(t) -> void:
	# 链式 A -> B -> C，外加两个孤儿
	var raw := [
		{"DialogueName": "A", "links": "B", "attributes": {"pid": 1}},
		{"DialogueName": "B", "links": "C", "attributes": {"pid": 1}},
		{"DialogueName": "C", "links": null, "attributes": {"pid": 1}},
		{"DialogueName": "X", "links": null, "attributes": {"pid": 1}},
		{"DialogueName": "Y", "links": "X", "attributes": {"pid": 1}}
	]
	var g := DialogueGraph.from_array(raw)
	DialogueAutoLayout.apply(g)

	t.expect(g.position_of(0), Vector2(0, 0), "入口在第一层第一行")
	t.expect(g.position_of(1), Vector2(360, 0), "B 在第二层")
	t.expect(g.position_of(2), Vector2(720, 0), "C 在第三层")
	t.expect_true(g.position_of(3).x > 720, "不可达节点排在可达区右侧")
	t.expect(g.position_of(3).y < g.position_of(4).y, "孤儿按原始顺序纵向排列")

	# 已有坐标不被覆盖
	g.set_position(1, Vector2(999, 999))
	DialogueAutoLayout.apply(g)
	t.expect(g.position_of(1), Vector2(999, 999), "已有坐标保留")

	# 确定性：同样输入跑两次结果一致
	var g2 := DialogueGraph.from_array(raw)
	var g3 := DialogueGraph.from_array(raw)
	DialogueAutoLayout.apply(g2)
	DialogueAutoLayout.apply(g3)
	t.expect(JSON.stringify(g2.to_array()), JSON.stringify(g3.to_array()), "相同输入布局确定")
```

**Step 2: 运行确认失败**

**Step 3: 实现**

```gdscript
class_name DialogueAutoLayout
extends RefCounted

const X_STEP := 360.0
const Y_STEP := 220.0
const ORPHAN_GAP := 60.0

## only_missing=true 时，已有 _editor.pos 的节点不动
static func apply(g: DialogueGraph, only_missing := true) -> void:
	if g.nodes.is_empty():
		return
	var layers := _layers(g)
	var orphan_start := layers.size()

	for layer_idx in layers.size():
		var row := 0
		for idx in layers[layer_idx]:
			if only_missing and not is_nan(g.position_of(idx).x):
				row += 1
				continue
			g.set_position(idx, Vector2(layer_idx * X_STEP, row * Y_STEP))
			row += 1

	# 不可达节点：单独一列，按原始顺序
	var orphans: Array = _unreachable(g)
	if not orphans.is_empty():
		var x := orphan_start * X_STEP
		for k in orphans.size():
			var idx: int = orphans[k]
			if only_missing and not is_nan(g.position_of(idx).x):
				continue
			g.set_position(idx, Vector2(x, k * (Y_STEP - ORPHAN_GAP)))

static func _layers(g: DialogueGraph) -> Array:
	# BFS 分层，层内按“首次遇到顺序”的原始索引稳定排序
	var depth: Dictionary = {}
	var queue: Array[int] = [0]
	depth[0] = 0
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for e in g.edges_of(cur):
			var to := g.index_of(e.target)
			if to >= 0 and not depth.has(to):
				depth[to] = depth[cur] + 1
				queue.append(to)
	var layers: Array = []
	var max_layer := 0
	for i in depth.keys():
		if int(depth[i]) > max_layer:
			max_layer = int(depth[i])
	for _l in max_layer + 1:
		layers.append([])
	for i in range(g.nodes.size()):
		if depth.has(i):
			layers[int(depth[i])].append(i)
	return layers

static func _unreachable(g: DialogueGraph) -> Array:
	var seen := {}
	var queue: Array[int] = [0]
	seen[0] = true
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		for e in g.edges_of(cur):
			var to := g.index_of(e.target)
			if to >= 0 and not seen.has(to):
				seen[to] = true
				queue.append(to)
	var out: Array = []
	for i in range(g.nodes.size()):
		if not seen.has(i):
			out.append(i)
	return out
```

**Step 4: 跑测试** → `ALL TESTS PASSED`

**Step 5: Commit**

```bash
git add addons/dialogue_graph/auto_layout.gd tests/test_auto_layout.gd
git commit -m "feat: add deterministic auto layout"
```

---

## Task 4：节点控件 `DialogueGraphNode`

**Files:**
- Create: `addons/dialogue_graph/dialogue_node.gd`

节点规则见「2. 图语义」。

```gdscript
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
	if not target.is_empty():
		return [{"label": "→ " + target, "color": DEF_COLOR, "port": true}]
	var is_ending := not graph.ending_of(node_index).is_empty()
	return [{"label": "■ 结局" if is_ending else "× 无出口", "color": DEAD_COLOR, "port": false}]

func _preview(s: String, max_len := 48) -> String:
	s = s.replace("\n", " ")
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len) + "…"

func _short(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n) + "…"
```

**验证（手动）：** 此任务无自动化测试；在 Task 5 完成后一起看。

**Commit:** `feat: add dialogue graph node control`

---

## Task 5：编辑器主界面 + 导入渲染

**Files:**
- Create: `addons/dialogue_graph/dialogue_editor.tscn`
- Create: `addons/dialogue_graph/dialogue_editor.gd`

**场景结构：**

```
DialogueEditor (Control, full rect)
└── VBox
    ├── Toolbar (HBox)
    │   ├── Button 打开  Button 保存  Button 另存为
    │   ├── Button 校验  Button 自动布局
    │   └── LineEdit 搜索（placeholder: 跳转到 DialogueName）
    ├── HSplit
    │   ├── GraphEdit (size_flags expand)
    │   └── Inspector (ScrollContainer, min 320)
    └── ErrorList (ItemList, 高 120, 可折叠)
```

**Step 1: 写主脚本（核心导入逻辑）**

```gdscript
extends Control

const TEXT_PATH := "res://Text/Text.json"
const NODE_SCENE_SCRIPT := preload("res://addons/dialogue_graph/dialogue_node.gd")
const MINIMAP := true

var graph: DialogueGraph
var dirty := false
var current_path := TEXT_PATH

@onready var graph_edit: GraphEdit = %GraphEdit
@onready var inspector: VBoxContainer = %Inspector
@onready var error_list: ItemList = %ErrorList
@onready var status: Label = %Status

func _ready() -> void:
	graph_edit.connection_request.connect(_on_connection_request)
	graph_edit.disconnection_request.connect(_on_disconnection_request)
	graph_edit.delete_nodes_request.connect(_on_delete_nodes_request)
	graph_edit.end_node_move.connect(_on_end_node_move)
	graph_edit.node_selected.connect(_on_node_selected)
	graph_edit.popup_request.connect(_on_popup_request)
	graph_edit.minimap_enabled = MINIMAP
	error_list.item_selected.connect(_on_error_selected)
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

func _rebuild() -> void:
	graph_edit.clear_connections()
	for c in graph_edit.get_children():
		if c is GraphNode:
			graph_edit.remove_child(c)
			c.queue_free()
	DialogueAutoLayout.apply(graph)   # 只补缺失坐标，已有坐标不动
	for i in graph.nodes.size():
		var n: DialogueGraphNode = NODE_SCENE_SCRIPT.new()
		graph_edit.add_child(n)
		n.setup(graph, i)
		n.position_offset = graph.position_of(i)
		_link_node(n, i)
	_refresh_status()

func _link_node(n: DialogueGraphNode, i: int) -> void:
	for e in graph.edges_of(i):
		var to := graph.index_of(e.target)
		if to < 0:
			continue
		var from_port := 1 + (e.choice_index if e.kind == "choice" else 0)
		graph_edit.connect_node(n.name, from_port, "N_%d" % to, 0)
```

> 注意：`GraphNode` 的端口 0 是输入；输出从 1 开始，所以普通链接口是 1，分支第 i 个选项口是 `1+i`。

**Step 2: 手动验证导入**

Run:
```bash
"D:/Software/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
  --path "D:/Project/GodotProject/3D" res://addons/dialogue_graph/dialogue_editor.tscn
```
Expected:
- 打开独立窗口，显示 54 个节点
- 5 个分支节点出现琥珀色选项口（`Bunker.*` 中有 choices 的那 5 个）
- 6 个结局节点显示红色 `■ 结局`
- 连线数量 = JSON 中非空 links 总数
- 未保存前 `git diff --exit-code Text/Text.json` 应为 0 差异（导入只读）

**Commit:** `feat: add dialogue editor scene with graph import`

---

## Task 6：连线增删写回模型

**Files:**
- Modify: `addons/dialogue_graph/dialogue_editor.gd`

```gdscript
func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if graph_edit.is_node_connected(from_node, from_port, to_node, to_port):
		return
	var src := _node_by_name(from_node)
	var dst := _node_by_name(to_node)
	if src == null or dst == null:
		return
	var target := graph.get_name_at(dst.node_index)
	var out_idx := from_port - 1
	if graph.has_choices(src.node_index):
		graph.set_choice_links(src.node_index, out_idx, target)
	else:
		graph.set_links(src.node_index, target)
	graph_edit.connect_node(from_node, from_port, to_node, to_port)
	src.refresh()
	_mark_dirty()

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	var src := _node_by_name(from_node)
	if src == null:
		return
	var out_idx := from_port - 1
	if graph.has_choices(src.node_index):
		graph.set_choice_links(src.node_index, out_idx, "")
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
```

**手动验证：**
1. 拖一条线：普通节点输出口 → 另一节点输入口
2. 关闭编辑器，`node -e "const d=require('./Text/Text.json')..."` 或 `git diff Text/Text.json` 看到对应 `links` 变化（保存后）
3. 断开线 → `links` 变 `null`

**Commit:** `feat: wire graph connections to dialogue model`

---

## Task 7：Inspector 编辑面板 + 新建节点

**Files:**
- Modify: `addons/dialogue_graph/dialogue_editor.gd`

面板按选中节点重建，编辑即写模型（`_mark_dirty()`），不需要"应用"按钮。

控件映射：

| 字段 | 控件 | 写回 |
|---|---|---|
| `Scene` | LineEdit | `nodes[i]["Scene"]` |
| `DialogueName` | LineEdit（失焦时查重，重复标红且不写） | `nodes[i]["DialogueName"]` + `rebuild_index()` |
| `attributes.name` | LineEdit | 同上嵌套键 |
| `attributes.pid` | OptionButton（1/2/3） | 同上 |
| `attributes.avatar` | LineEdit | 同上 |
| `content` | TextEdit（高 120） | 同上 |
| `links` | LineEdit（有 choices 时禁用） | `set_links` |
| `ending.*` | id/title/subtitle/next_scene 四个 LineEdit | 直接写 `ending` 字典 |
| `set` / `if` | TextEdit 显示 JSON + 失焦解析，非法时标红不写 | `JSON.parse_string` |
| `choices` | 每项：text LineEdit + links LineEdit + 删除按钮；底部"＋ 选项" | 数组增删 |

新建节点：`GraphEdit.popup_request` 记录鼠标位置 → 右键菜单"新建对话节点" → 自动命名（`Scene.下一个序号`，用现有名字扫描，如 `Bunker.055`）→ `graph.create_node(...)` → `_rebuild()`。

**公共辅助函数（Task 5/6 的导入、选中、删除、右键都依赖这些）：**

```gdscript
func _refresh_status() -> void:
	status.text = "%d 节点 | %s%s" % [
		graph.nodes.size() if graph != null else 0,
		current_path,
		"  *未保存" if dirty else ""
	]

func _on_node_selected(node: Node) -> void:
	if node is DialogueGraphNode:
		_build_inspector(node)

func _on_error_selected(item: int) -> void:
	var node_index: int = int(error_list.get_item_metadata(item))
	var n := graph_edit.get_node_or_null(NodePath("N_%d" % node_index))
	if n is GraphNode:
		graph_edit.set_scroll_offset(n.position_offset - graph_edit.size * 0.5)

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
	menu.popup()
	menu.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			_create_node_at(at_position)
		menu.queue_free())

func _create_node_at(local_pos: Vector2) -> void:
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
	graph.create_node(new_name, scene_name, local_pos)
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
	for c in inspector.get_children():
		c.queue_free()
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
	opt.select(max(0, int(attrs.get("pid", 1)) - 1))
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
```

**手动验证：**
- 改名、改台词、加选项，保存后 JSON 正确
- 新建节点只有必要键（无空 `choices`/`set`/`ending`）
- 把 `DialogueName` 改成重复值 → 标红、不写回

**Commit:** `feat: add inspector editing and node creation`

---

## Task 8：工具条（打开/保存/另存/校验/自动布局/搜索）

**Files:**
- Modify: `addons/dialogue_graph/dialogue_editor.gd`

```gdscript
func _on_save() -> void:
	if not JsonHelper.save_json_file(current_path, graph.to_array()):
		status.text = "保存失败"
		return
	dirty = false
	_refresh_status()
	status.text = "已保存: " + current_path

func _on_validate() -> void:
	error_list.clear()
	var issues := DialogueValidator.validate(graph)
	for it in issues:
		var prefix := "错误" if it.level == "error" else "警告"
		var idx := error_list.add_item("%s | %s: %s" % [prefix, graph.get_name_at(it.node_index), it.message])
		error_list.set_item_metadata(idx, it.node_index)
	status.text = "校验完成：%d 个问题" % issues.size()
```

- 搜索框 `text_submitted` → `index_of` → 选中并 `graph_edit.center_node_on_node(...)`? Godot 4.7 GraphEdit 无 `center_node_on_node`，改用 `graph_edit.set_scroll_offset(node.position_offset - graph_edit.size / 2)` 并调用 `node.set_selected(true)`（`GraphNode` 有 `set_selected`？实际是 `graph.selected_nodes`）。实现时以 4.7 文档为准；MVP 允许退化为"高亮节点"。
- 自动布局按钮 → `DialogueAutoLayout.apply(graph, false)` → `_rebuild()`。
- 关闭时 `dirty` 为真弹确认（`ConfirmationDialog`）。

**手动验证：**
1. 不改任何东西，点保存 → `git diff --exit-code Text/Text.json` 为 0（关键验收）
2. 拖动一个节点后保存 → diff 只增加 `_editor.pos`
3. 校验按钮列出 Task 2 注入的错误
4. 自动布局后节点分层排列

**Commit:** `feat: add save/validate/autolayout toolbar`

---

## Task 9：插件封装并启用

**Files:**
- Create: `addons/dialogue_graph/plugin.cfg`
- Create: `addons/dialogue_graph/plugin.gd`
- Modify: `project.godot:34`（`enabled` 追加 `dialogue_graph`）

`plugin.cfg`:
```ini
[plugin]

name="Dialogue Graph"
description="Visual dialogue graph editor (GraphEdit) for Text/Text.json"
author="yunqi48"
version="0.1.0"
script="plugin.gd"
```

`plugin.gd`:
```gdscript
@tool
extends EditorPlugin

const EDITOR_SCENE := "res://addons/dialogue_graph/dialogue_editor.tscn"

func _enter_tree() -> void:
	add_tool_menu_item("打开对话图编辑器", _open_editor)

func _exit_tree() -> void:
	remove_tool_menu_item("打开对话图编辑器")

func _open_editor() -> void:
	EditorInterface.open_scene_from_path(EDITOR_SCENE)
```

启用后：菜单 **项目 → 工具 → 打开对话图编辑器**，打开场景后 **F6（运行当前场景）** 进入编辑窗口。

> MVP 用 F6 运行而非 @tool 内嵌编辑：避开编辑器内 GraphEdit 的主题/生命周期坑；`res://` 在编辑器运行时可写，导出后不可写（工具本就只在开发期用）。

**验证：**
- 重启编辑器，插件列表出现 Dialogue Graph 且已启用
- 菜单项能打开场景，F6 正常运行

**Commit:** `feat: package dialogue graph editor as plugin`

---

## Task 10：端到端验收

1. **单测**
   ```bash
   "D:/Software/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
     --headless --path "D:/Project/GodotProject/3D" --script res://tests/run_tests.gd
   ```
   Expected: `ALL TESTS PASSED`，退出码 0。
2. **无损往返**：打开 `Text.json` → 保存 → `git diff --exit-code Text/Text.json` 为 0。
3. **图形正确**：54 节点、5 分支、6 结局；连线数与 JSON 非空 links 总数一致。
4. **改数据链路**：新增一条连线 → 保存 → 游戏里能走到目标节点。
   ```bash
   "D:/Software/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
     --headless --path "D:/Project/GodotProject/3D" --quit-after 180
   ```
   Expected: 启动日志里 `显示第 0 条: ...` 正常，无 JSON 解析错误。
5. **校验器回归**：临时把某个 `DialogueName` 改成重复值 → 校验面板出现 `duplicate_name` → 改回。
6. **提交**
   ```bash
   git add addons/dialogue_graph project.godot tests docs
   git commit -m "feat: add visual dialogue graph editor MVP"
   ```

---

## 验收标准（Definition of Done）

- [ ] headless 测试全绿，覆盖模型/校验/布局
- [ ] 导入 54 节点、5 分支、6 结局，连线与 JSON 一致
- [ ] 原样保存零 diff（无损往返）
- [ ] 拖动节点保存只新增 `_editor.pos`
- [ ] 连线/断线正确改写 `links` / `choices[i].links`
- [ ] 校验器能报：重复 ID、悬空链接、links+choices 共存、不可达、结局带出口、非法表达式、软锁风险
- [ ] 自动布局确定性、已有坐标不覆盖
- [ ] 游戏运行时对 `Text.json` 的行为完全不变

---

## 风险与后续

| 风险 | 处理 |
|---|---|
| 4.7 GraphEdit 部分 API 与 4.2 文档有差异（如居中节点） | 实现时以 4.7.2 内置文档为准，必要时降级为"高亮" |
| GraphNode 主题在非编辑器环境简陋 | MVP 接受；v2 套 `EditorTheme` 或自定义 StyleBox |
| `res://` 只在编辑器运行时可写 | 工具场景仅开发期使用；如需导出，改成 `user://` + 导入导出对话框 |
| 大图性能 | 300+ 节点时关闭 minimap/自动重排；MVP 54 节点无压力 |
| 删除节点改变数组索引 | MVP 禁止删除第 0 个节点；删除后 `rebuild_index()` 并重建全图 |
| 撤销/重做缺失 | v2 用 `UndoRedo` + `GraphEdit` 信号补齐 |
| 分支选项口重排导致连线丢失 | `_rebuild` 按 `choices` 索引重建，不做增量 port 变更 |

**v2 候选：** 撤销重做、搜索跳转、复制粘贴、Scene 分组框、内嵌实时预览（直接跑 `mainpanle.gd` 的对话运行时）、导出前 diff 预览、图内截图。

---

## 执行方式

建议先开分支：

```bash
git switch -c feature/dialogue-graph-editor
```

然后按 Task 0 → 10 顺序执行，每个 Task 结束跑一次全量测试并提交。
