extends ProgressBar

var max_val = 100  # 进度条最大值（默认是100，可以自定义）

func _ready() -> void:
	max_value = max_val  # 设置进度条最大值

func _process(_delta: float) -> void:
	# 右扳机压力 → 进度条值（0 ~ max_val），统一走 InputManager 的动作读取
	var pressure := InputManager.strength(InputManager.BANJI)
	value = pressure * max_val
