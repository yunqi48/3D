extends Node
## 输入统一入口（autoload 单例）。
## 所有脚本只消费它，不直接碰 Input / 设备号 / get_joy_axis。
##
## 增删按键的唯一真相源是 Godot 内置「输入映射」（项目设置 → 输入映射）：
##   - 加一个键：给某动作加一个事件（键盘 / 手柄按钮 / 摇杆），代码零改动。
##   - 减一个键：删掉该事件，is_action_pressed() 自动返回 false，不会崩。
## 新增动作 = 在下方常量表加一行 const + 在输入映射里加事件；
## _ensure_actions() 会在启动时补齐缺失的动作，保证引用不报错。

# —— 动作名常量表 ——
const MOVE_LEFT   := "move_left"
const MOVE_RIGHT  := "move_right"
const MOVE_ON     := "move_on"
const MOVE_UNDER  := "move_under"
const LOOK_LEFT   := "look_left"
const LOOK_RIGHT  := "look_right"
const LOOK_UP     := "look_up"
const LOOK_DOWN   := "look_down"
const ADVANCE     := "advance"
const CANCEL      := "cancel"
const BANJI       := "banji"
const SWITCH_SHOULDER := "switch_shoulder"
const SHOW_CURSOR := "show_cursor"
const SHOW_CURSOR_PRESS  := "show_cursor_press"   # 按住 → 临时解锁指针（默认 ALT，仅在 UI 未打开时生效）
const SHOW_CURSOR_SWITCH := "show_cursor_switch"  # 点按 → 打开/关闭 UI 主开关（默认 TAB），优先级高于 ALT

## 所有动作名，供 _ensure_actions 批量注册
const ALL_ACTIONS: Array[StringName] = [
	MOVE_LEFT, MOVE_RIGHT, MOVE_ON, MOVE_UNDER,
	LOOK_LEFT, LOOK_RIGHT, LOOK_UP, LOOK_DOWN,
	ADVANCE, CANCEL, BANJI, SWITCH_SHOULDER,
	SHOW_CURSOR, SHOW_CURSOR_PRESS, SHOW_CURSOR_SWITCH
]

## 当前活动手柄设备号；热插拔自动更新，无手柄 = -1
var active_joypad: int = -1

## 最近一次输入来源是不是手柄（true=手柄，false=键盘/鼠标）
var using_gamepad: bool = false
## 最近一次输入来源：gamepad / mouse / keyboard
var last_source: String = ""

## 鼠标视角：本物理帧累计、尚未被消费的位移（像素，x=右+，y=下+）
var _look_mouse := Vector2.ZERO
## 该累计所属的物理帧号（跨帧区分用）
var _look_mouse_phys_frame := -1

func _ready() -> void:
	_ensure_actions()
	_refresh_joypad()
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _process(_delta: float) -> void:
	_update_cursor()


## 追踪最近一次输入来源（区分手柄 / 鼠标 / 键盘）
func _input(event: InputEvent) -> void:
	_handle_cursor_toggle(event)
	_accumulate_mouse_look(event)
	var new_source := ""
	if event is InputEventJoypadMotion or event is InputEventJoypadButton:
		new_source = "gamepad"
	elif event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey:
		new_source = "mouse & keyboard"
	if new_source.is_empty() or new_source == last_source:
		return
	last_source = new_source
	using_gamepad = new_source == "gamepad"	 

func _on_joy_connection_changed(_device: int, _connected: bool) -> void:
	_refresh_joypad()
	# 连接/断开时打印活动设备，方便排查 Steam Input 是否生效
	if active_joypad != -1:
		print("[InputManager] 活动手柄：%s" % Input.get_joy_name(active_joypad))
	else:
		print("[InputManager] 没有已连接的手柄")

func _refresh_joypad() -> void:
	var pads := Input.get_connected_joypads()
	active_joypad = pads[0] if not pads.is_empty() else -1

# 自动注册常量表里缺失的动作（空绑定），删键/删动作后引用不崩
func _ensure_actions() -> void:
	for action in ALL_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)

# ===== 摇杆型：合并成 Vector2 =====

## 移动：左摇杆 + WASD → Vector2（x=右+，y=后+，与原有语义一致）
func move_vector() -> Vector2:
	return Input.get_vector(MOVE_LEFT, MOVE_RIGHT, MOVE_ON, MOVE_UNDER)

## 视角灵敏度（全局统一，在这里调；别再放回各玩家脚本里）
var joy_look_speed: float = 3.0       # 右摇杆（弧度/秒，满杆量）
var mouse_sensitivity: float = 0.003  # 鼠标（弧度/像素）

## 视角增量（弧度，适用于当前物理帧；请在 _physics_process 每帧调用一次，鼠标位移取走后即清空）：
##   x=右+，y=下+（与 get_joy_axis 同约定）。
## 右摇杆 + 鼠标合并：
##   摇杆 = axis * joy_look_speed * delta
##   鼠标 = 本物理帧累计位移(px) * mouse_sensitivity
## 消费端直接把它加到 yaw/pitch 即可，不要再乘任何速度或时间。
func look_vector() -> Vector2:
	var stick := Input.get_vector(LOOK_LEFT, LOOK_RIGHT, LOOK_UP, LOOK_DOWN)
	var out := stick * joy_look_speed * get_physics_process_delta_time()
	out += _take_look_mouse() * mouse_sensitivity
	return out

## 取走并清空累计的鼠标位移（look_vector 每帧消费一份）
func _take_look_mouse() -> Vector2:
	var m := _look_mouse
	_look_mouse = Vector2.ZERO
	return m

## 仅在鼠标被捕获（游戏视角锁定）时累计位移。UI 打开 / ALT 临时解锁时指针可见，
## 鼠标用于点选，不转动视角。
func _accumulate_mouse_look(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var f := Engine.get_physics_frames()
		if _look_mouse_phys_frame != f:
			_look_mouse_phys_frame = f
			_look_mouse = Vector2.ZERO  # 新物理帧：丢弃上一帧没被读走的残留
		_look_mouse += event.relative

# ===== 按键型 =====

func just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(action)

func is_pressed(action: String) -> bool:
	return Input.is_action_pressed(action)

func released(action: String) -> bool:
	return Input.is_action_just_released(action)

func strength(action: String) -> float:
	return Input.get_action_strength(action)

# ===== 可选：代码内增删绑定（对应「更方便添加/减少按键」） =====

func add_key(action: String, keycode: Key) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = keycode
	InputMap.action_add_event(action, e)

func add_joy_button(action: String, button: JoyButton) -> void:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	InputMap.action_add_event(action, e)

func remove_binding(action: String, event: InputEvent) -> void:
	InputMap.action_erase_event(action, event)

# ===== 鼠标指针（显示 / 锁定） =====

## TAB 驱动的「UI 打开」主开关：打开 → 指针解锁，关闭 → 指针锁定（FPS 捕获）。
## 后续打开 / 关闭 UI 的场景（菜单、背包等）就接在这个状态上，TAB 只是它的输入源。
var _ui_open: bool = false

## UI 主开关变化时发出（true=打开/解锁）。以后要随 UI 暂停游戏、收走玩家输入等，连这个信号即可。
signal ui_toggled(open: bool)

## 键鼠输入下的指针策略（TAB 优先级高于 ALT）：
##   - 点按 show_cursor_switch（默认 TAB）→ 翻转 _ui_open：打开持续解锁 / 关闭恢复锁定（在 _input 事件里翻转）
##   - 按住 show_cursor_press（默认 ALT）→ 仅当 UI 未打开（主状态锁定）时临时解锁，松开即恢复锁定
## 解锁 = 指针可见（MOUSE_MODE_VISIBLE）；锁定 = 隐藏并捕获（MOUSE_MODE_CAPTURED）。
func _update_cursor() -> void:
	var unlock := _ui_open
	if not _ui_open and Input.is_action_pressed(SHOW_CURSOR_PRESS):
		unlock = true  # ALT 永远只做「UI 关闭时」的临时解锁，无法覆盖 TAB 的主状态
	_apply_cursor_mode(unlock)

## TAB 翻转放事件里做、显式排除 echo：按住 TAB 的系统自动重复不会反复翻转。
## ALT+TAB 同按时 TAB 照常翻转主状态（ALT 不会干扰）。
func _handle_cursor_toggle(event: InputEvent) -> void:
	if event.is_action_pressed(SHOW_CURSOR_SWITCH):  # allow_echo 默认 false → 只认物理按下
		_ui_open = not _ui_open
		ui_toggled.emit(_ui_open)
		print("[InputManager] UI 指针解锁：%s" % _ui_open)

## 只在模式真的变化时才调用 set_mouse_mode，避免每帧重复设置
func _apply_cursor_mode(unlock: bool) -> void:
	var target := Input.MOUSE_MODE_VISIBLE if unlock else Input.MOUSE_MODE_CAPTURED
	if Input.mouse_mode != target:
		Input.set_mouse_mode(target)

## 只读：UI 主开关当前是否打开（指针处于解锁）
func ui_open() -> bool:
	return _ui_open

## 只读：当前指针是否处于解锁（可见）状态，供对话面板等需要点选的地方查询
func cursor_unlocked() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_VISIBLE
