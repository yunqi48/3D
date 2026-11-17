extends RefCounted

func run(t) -> void:
	var data := [
		{
			"Scene": "B",
			"DialogueName": "A",
			"links": null,
			"set": [["flag", "x", "set", true]]
		}
	]
	var expected := "[\n\t{\n\t\t\"Scene\": \"B\",\n\t\t\"DialogueName\": \"A\",\n\t\t\"links\": null,\n\t\t\"set\": [[\"flag\", \"x\", \"set\", true]]\n\t}\n]"
	t.expect(DialogueJson.stringify_pretty(data), expected, "内联数组保持单行")

	# 解析器必须保留整数/浮点词法（内置 JSON.parse 会把 1 和 1.0 都变 float）
	var nums: Array = DialogueJson.parse("[1, 1.0, -2, 2.5, true, null]")
	t.expect(typeof(nums[0]), TYPE_INT, "整数保持 int")
	t.expect(typeof(nums[1]), TYPE_FLOAT, "1.0 保持 float")
	t.expect(nums[2], -2, "负整数")
	t.expect(nums[3], 2.5, "小数")
	t.expect(nums[4], true, "true")
	t.expect(nums[5], null, "null")

	var escaped: Dictionary = DialogueJson.parse("{\"a\": \"x\\\"y\\\\z\\n中\"}")
	t.expect(escaped["a"], "x\"y\\z\n中", "字符串转义")

	# 真源文件必须语义与字节都无损往返（编辑器保存零 diff 的基础）
	var f := FileAccess.open("res://Text/Text.json", FileAccess.READ)
	t.expect_true(f != null, "可读取 Text.json")
	if f == null:
		return
	var original := f.get_as_text()
	f.close()
	var parsed = DialogueJson.parse(original)
	t.expect_true(parsed is Array, "Text.json 可解析")
	if not (parsed is Array):
		return
	t.expect(DialogueJson.stringify_pretty(parsed) + "\n", original, "Text.json 字节级无损往返")
