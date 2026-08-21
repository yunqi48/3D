class_name JsonHelper
extends RefCounted

static func read_json_file(file_path: String):
	if not FileAccess.file_exists(file_path):
		print("文件不存在: ", file_path)
		return null
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		print("无法打开文件: ", file_path)
		return null
	
	var content = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var error = json.parse(content)
	
	if error != OK:
		print("JSON解析错误: ", json.get_error_message())
		return null
	
	return json.data

static func parse_dialogue(json_array: Array) -> Array:
	var dialogues: Array = []
	
	for i in json_array.size():
		var raw = json_array[i]
		if not raw is Dictionary:
			continue
		var attrs: Dictionary = raw.get("attributes", {})
		var links: Variant = raw.get("links", "")
		var choices : Variant = raw.get("choices",[])
		if links == null:
			links = ""
		dialogues.append({
			"index": i,
			"scene": raw.get("Scene", ""),
			"dialogue_name": raw.get("DialogueName", ""),
			"pid": int(attrs.get("pid", -1)),
			"name": attrs.get("name", ""),
			"text": raw.get("content", ""),
			"links": links,
			"choices":choices,
			"set": raw.get("set", []),
			"if": raw.get("if", []),
			"ending": raw.get("ending", {}),
			"avatar": attrs.get("avatar", "")
		})
	return dialogues

static func save_json_file(file_path: String, data):
	var json_string = JSON.stringify(data, "  ")
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		print("无法保存文件: ", file_path)
		return false
	file.store_string(json_string)
	file.close()
	return true
