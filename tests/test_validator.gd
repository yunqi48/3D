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
