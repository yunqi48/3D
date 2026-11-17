class_name DialogueAutoLayout
extends RefCounted

const X_STEP := 360.0
const Y_STEP := 220.0
const ORPHAN_GAP := 60.0

## only_missing=true 时，已有 _editor.pos 的节点不动
static func apply(g: DialogueGraph, only_missing := true) -> void:
	var positions := compute_positions(g, only_missing)
	for idx in positions:
		g.set_position(int(idx), positions[idx])

## 非破坏式布局：只计算坐标（idx -> Vector2），不写回模型。
## 编辑器首次导入用它摆放 GraphNode，从而保证未编辑时保存零 diff。
static func compute_positions(g: DialogueGraph, only_missing := true) -> Dictionary:
	var out: Dictionary = {}
	if g.nodes.is_empty():
		return out
	var layers := _layers(g)
	var orphan_start := layers.size()

	for layer_idx in layers.size():
		var row := 0
		for idx in layers[layer_idx]:
			if only_missing and not is_nan(g.position_of(idx).x):
				row += 1
				continue
			out[idx] = Vector2(layer_idx * X_STEP, row * Y_STEP)
			row += 1

	# 不可达节点：单独一列，按原始顺序
	var orphans: Array = _unreachable(g)
	if not orphans.is_empty():
		var x := orphan_start * X_STEP
		for k in orphans.size():
			var idx: int = orphans[k]
			if only_missing and not is_nan(g.position_of(idx).x):
				continue
			out[idx] = Vector2(x, k * (Y_STEP - ORPHAN_GAP))
	return out

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
