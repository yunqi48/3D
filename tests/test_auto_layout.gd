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
	t.expect_true(g.position_of(3).y < g.position_of(4).y, "孤儿按原始顺序纵向排列")

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

	# 非破坏式布局计算：只返回坐标，不写模型（编辑器导入时零 diff 依赖此行为）
	var g4 := DialogueGraph.from_array(raw)
	var pos := DialogueAutoLayout.compute_positions(g4)
	t.expect_true(is_nan(g4.position_of(0).x), "compute_positions 不修改模型")
	t.expect(pos.get(0, Vector2(NAN, NAN)), Vector2(0, 0), "compute_positions 返回入口坐标")
