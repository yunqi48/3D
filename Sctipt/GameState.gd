extends Node

## 全局剧情状态（autoload 单例，project.godot 里注册）
## 扁平 name->value 存储；kind（flag/num/str）由条件/效果里的访问点携带，无需嵌套。
## 存档：user://save_data.json（JsonHelper 读写，复用现有工具）

const SAVE_PATH := "user://save_data.json"

## 所有剧情变量：name -> bool / float / String
var vars: Dictionary = {}


func _ready() -> void:
	# 不自动 load_save()：当前没有主菜单，直接读旧档会让分支变量污染新局。
	# 状态目前只做单向记录（结局），record_ending() 自己会存档。
	print("[GameState] 存档路径: %s" % ProjectSettings.globalize_path(SAVE_PATH))


# ===== 条件求值 =====

# 多条条件全部 AND；空数组 / 无 if = true（旧选项永远显示）
func evaluate_conditions(conds: Array) -> bool:
	for cond in conds:
		if not evaluate_condition(cond):
			return false
	return true


# 单条条件 [kind, name, op, value]。变量缺失 -> false（保守：选项只有条件可证成立才显示）
func evaluate_condition(cond) -> bool:
	if not (cond is Array) or cond.size() < 4:
		return false
	var kind := str(cond[0])
	var var_name := str(cond[1])
	var op := str(cond[2])
	var expected = cond[3]
	if not vars.has(var_name):
		return false
	var actual = vars[var_name]
	match kind:
		"flag":
			var a := bool(actual)
			var b := bool(expected)
			match op:
				"==": return a == b
				"!=": return a != b
		"num":
			var a := float(actual)
			var b := float(expected)
			match op:
				"==": return is_equal_approx(a, b)
				"!=": return not is_equal_approx(a, b)
				">": return a > b
				"<": return a < b
				">=": return a >= b
				"<=": return a <= b
		"str":
			var a := str(actual)
			var b := str(expected)
			match op:
				"==": return a == b
				"!=": return a != b
				">": return a > b
				"<": return a < b
				">=": return a >= b
				"<=": return a <= b
	return false


# ===== 状态改写 =====

# 效果数组 [kind, name, op, value?]；空 = no-op
func apply_effects(effects: Array) -> void:
	for e in effects:
		if not (e is Array) or e.is_empty():
			continue
		var kind := str(e[0])
		var var_name := str(e[1])
		var op := str(e[2]) if e.size() > 2 else "set"
		var value = e[3] if e.size() > 3 else null
		match kind:
			"flag":
				if op == "set":
					vars[var_name] = bool(value)
				elif op == "toggle":
					vars[var_name] = not bool(vars.get(var_name, false))
			"num":
				if op == "set":
					vars[var_name] = float(value)
				elif op == "add":
					vars[var_name] = float(vars.get(var_name, 0.0)) + float(value)
			"str":
				vars[var_name] = str(value)


# ===== 结局 =====

# 记录已达成结局并立即存档
func record_ending(ending_id: String) -> void:
	if ending_id.is_empty():
		return
	var endings: Array = vars.get("endings", [])
	if not endings.has(ending_id):
		endings.append(ending_id)
	vars["endings"] = endings
	vars["last_ending"] = ending_id
	save()


# ===== 存档 =====

func save() -> void:
	JsonHelper.save_json_file(SAVE_PATH, vars)


func load_save() -> void:
	var data = JsonHelper.read_json_file(SAVE_PATH)
	if data is Dictionary:
		vars = data
