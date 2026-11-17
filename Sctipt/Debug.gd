extends Node

## 全局调试单例（autoload）。
## 用途：
##   1) 数据变动自动打印：任何地方调 Debug.log_change(name, old, new, source)；
##      GameState 已在每次写入时自动调用，无需手写。
##   2) 显示所有属性：按 F3，或代码里调 Debug.dump_all()。
##   3) 开关：按 F4 切换 enabled（关掉后不再打印变动，dump 仍可用）。

## 总开关
var enabled: bool = true

## 只监视这些变量名（空 = 监视全部）。例：watch_filter = ["hp", "score"]
var watch_filter: Array[String] = []

const KEY_DUMP := KEY_F3
const KEY_TOGGLE := KEY_F4


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	print("[Debug] 调试就绪：F3=显示所有属性，F4=开关变动打印")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_DUMP:
			dump_all()
		elif event.keycode == KEY_TOGGLE:
			enabled = not enabled
			print("[Debug] 变动打印已%s" % ("开启" if enabled else "关闭"))


## 数据变动时打印。source 标识来源（如 "GameState"）。
func log_change(var_name: String, old_value, new_value, source: String = "") -> void:
	if not enabled:
		return
	if not watch_filter.is_empty() and not watch_filter.has(var_name):
		return
	print("[Debug][%s] %s: %s -> %s" % [source, var_name, old_value, new_value])


## 直接打印一个值（类似 print，但受 enabled 开关控制）。
func log(value, label: String = "") -> void:
	if not enabled:
		return
	if label.is_empty():
		print("[Debug] ", value)
	else:
		print("[Debug][%s] %s" % [label, value])


## 显示所有属性（当前 = GameState 的全部剧情变量）
func dump_all() -> void:
	print("================ [Debug] 全部剧情变量 ================")
	var vars: Dictionary = GameState.vars
	if vars.is_empty():
		print("  （空，还没有任何变量）")
	else:
		for key in vars.keys():
			var v = vars[key]
			print("  %s = %s   [%s]" % [key, v, type_string(typeof(v))])
	print("================ 共 %d 个变量 ================" % vars.size())
