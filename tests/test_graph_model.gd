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

	# 线性节点转为分支：创建 choices 且 links 必须置空
	g.set_links(0, "Bunker.002")
	var arr := g.ensure_choices(0)
	t.expect(arr.size(), 0, "转为分支后 choices 初始为空")
	t.expect(g.nodes[0]["links"], null, "转为分支后 links 置空")
	arr.append({"text": "继续", "links": "Bunker.002"})
	t.expect(g.edges_of(0).size(), 1, "新增选项产生出边")
	t.expect(g.edges_of(0)[0].target, "Bunker.002", "选项目标")

	# 设为结局：links 置空、choices 移除；可再清除
	g.set_ending(0, {"id": "e_test", "title": "结局"})
	t.expect(g.nodes[0]["links"], null, "设为结局后 links 置空")
	t.expect(g.ending_of(0).get("id"), "e_test", "结局可读")
	t.expect(g.has_choices(0), false, "设为结局会移除选项")
	g.clear_ending(0)
	t.expect(g.ending_of(0).is_empty(), true, "移除结局")

	# 布局读写
	t.expect_true(is_nan(g.position_of(0).x), "无坐标时返回 NaN")
	g.set_position(0, Vector2(120, 340))
	t.expect(g.position_of(0), Vector2(120, 340), "坐标读写")
	t.expect(JSON.stringify(g.to_array()[0]["_editor"]["pos"]), "[120,340]", "坐标序列化为整数数组")
