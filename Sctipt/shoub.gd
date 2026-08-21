extends Node

## 手柄陀螺仪数据（角速度，rad/s；Steam 虚拟摇杆模式下为右摇杆量 [-1,1]）
var gyro_data : Vector3 = Vector3.ZERO

## 输出频率：每隔多少秒打印一次（0 = 每帧都打，会刷屏；默认 0.1 秒即 10Hz）
@export var output_interval: float = 0.1

## ===== 陀螺仪 → 输入动作映射 =====
## Godot 的 Input Map 只能绑按键/手柄按钮/摇杆轴，不能直接绑陀螺仪。
## 所以这里做一层"虚拟映射"：把陀螺仪轴的输入按 死区+灵敏度 转成强度，
## 用 Input.action_press() 填进动作，其他脚本就能用
## Input.is_action_pressed() / Input.get_action_strength() 读取。
## 动作名留空 = 该轴不映射；填了动作名而项目里还没定义，会自动注册。

## X 轴角速度（或 Steam 虚拟左摇杆 X）→ 映射到的动作名
@export var gyro_map_x: String = ""
## Y 轴角速度（或 Steam 虚拟左摇杆 Y）→ 映射到的动作名
@export var gyro_map_y: String = ""
## Z 轴角速度 → 映射到的动作名（Steam 虚拟摇杆模式下无 Z 轴，恒 0）
@export var gyro_map_z: String = ""
## 死区：低于此输入量视为 0，防手抖（真陀螺仪按 rad/s，虚拟摇杆按 -1..1 摇杆量）
@export var gyro_deadzone: float = 0.2
## 灵敏度：把 rad/s 缩放到强度 [-1,1]（仅真陀螺仪模式生效；虚拟摇杆已是 -1..1，不再缩放）
@export var gyro_sensitivity: float = 0.5
## 反转：让轴正向映射为负强度（按手柄朝向/手感调整）
@export var gyro_invert: bool = false

## 当前使用的手柄设备号（能提供真陀螺仪数据的手柄，-1 表示无）
var _device_id: int = -1
## Steam 虚拟手柄的设备号（陀螺仪→右摇杆 中转，USB + Steam Input 场景）
var _virtual_device_id: int = -1
## 当前是否在使用 Steam 虚拟右摇杆代替真陀螺仪
var _using_virtual_stick: bool = false
var _timer: float = 0.0
var _printed_no_joypad: bool = false
var _printed_no_source: bool = false
## 已警告过"动作未定义"的轴，避免每帧刷屏
var _warned_actions: Dictionary = {}

var joypads := Input.get_connected_joypads()
var device_id = 0 # 通常第一个手柄的ID是0

func _ready() -> void:
	# 映射里填了但项目还没定义的动作，自动注册，开箱即用
	for action_name in [gyro_map_x, gyro_map_y, gyro_map_z]:
		if not action_name.is_empty() and not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
			print("[shoub] 已自动注册输入动作：%s" % action_name)
	if Input.has_joy_motion_sensors(device_id):
		print("手柄支持运动传感器！")
	else:
		print("手柄不支持运动传感器。")
	

func _process(delta: float) -> void:
	# 每帧查询已连接的手柄（设备号不一定从 0 开始）
	#if Input.has_joy_motion_sensors(device_id):
		#var gyro_data: Vector3 = Input.get_joy_gyroscope(device_id)
		#print(gyro_data)
	
	if joypads.is_empty():
		_device_id = -1
		_virtual_device_id = -1
		_using_virtual_stick = false
		_release_gyro_actions()
		if not _printed_no_joypad:
			print("[shoub] 未检测到手柄，连接后会自动开始输出")
			_printed_no_joypad = true
		return
	_printed_no_joypad = false

	# ① 优先找能提供真陀螺仪数据的手柄（加速度计静止时约 9.8，非 0 即说明 IMU 在线）
	var native_id := _find_native_gyro_device(joypads)
	if native_id != -1:
		if _device_id != native_id:
			_device_id = native_id
			_using_virtual_stick = false
			print("[shoub] 使用真陀螺仪手柄：%s（设备号 %d）" % [Input.get_joy_name(_device_id), _device_id])
		gyro_data = Input.get_joy_gyroscope(_device_id)
		var accel_data := Input.get_joy_accelerometer(_device_id)
		var gravity_data := Input.get_joy_gravity(_device_id)
		_update_gyro_actions()
		_timer += delta
		if _timer >= output_interval:
			_timer = 0.0
			print("[shoub] 真陀螺仪(角速度) %s | 加速度 %s | 重力 %s" % [gyro_data, accel_data, gravity_data])
		return

	# ② 回退：Steam Input 把陀螺仪映射到了虚拟手柄右摇杆（USB + Steam 中转）
	var virtual_id := _find_virtual_gamepad(joypads)
	if virtual_id == -1:
		_using_virtual_stick = false
		gyro_data = Vector3.ZERO
		if not _printed_no_source:
			print("[shoub] 没有真陀螺仪，也没发现 Steam 虚拟手柄——请从 Steam 启动 Godot，")
			print("[shoub] 并在控制器配置里把 陀螺仪 映射为 右摇杆，Steam Input 才会介入")
			_printed_no_source = true
		return
	_printed_no_source = false
	if _virtual_device_id != virtual_id:
		_virtual_device_id = virtual_id
		_using_virtual_stick = true
		print("[shoub] 未读到真陀螺仪，改用 Steam 虚拟手柄左摇杆：%s（设备号 %d）" % [Input.get_joy_name(virtual_id), virtual_id])
	gyro_data = Vector3(
		Input.get_joy_axis(virtual_id, JOY_AXIS_RIGHT_X),
		Input.get_joy_axis(virtual_id, JOY_AXIS_RIGHT_Y),
		0.0
	)
	_update_gyro_actions()
	_timer += delta
	if _timer >= output_interval:
		_timer = 0.0
		print("[shoub] 虚拟右摇杆(代替陀螺仪) %s" % gyro_data)

# ===== 输入来源选择 =====

# 在已连接手柄里找一个 IMU 真正在线的（加速度计静止时约 9.8，length² > 1 即视为在线）
func _find_native_gyro_device(joypads: PackedInt32Array) -> int:
	for id in joypads:
		if Input.get_joy_accelerometer(id).length_squared() > 1.0:
			return id
	return -1

# 优先找 Steam 虚拟手柄（Steam Input 喂给应用的虚拟设备，名字通常带 Steam/Virtual）
func _find_virtual_gamepad(joypads: PackedInt32Array) -> int:
	for id in joypads:
		var joy_name := Input.get_joy_name(id).to_lower()
		if "steam" in joy_name or "virtual" in joy_name:
			return id
	return -1

# ===== 陀螺仪 → 输入动作映射 =====

# 把三个陀螺仪轴分别写入各自映射的动作
func _update_gyro_actions() -> void:
	_apply_gyro_action(gyro_map_x, gyro_data.x)
	_apply_gyro_action(gyro_map_y, gyro_data.y)
	_apply_gyro_action(gyro_map_z, gyro_data.z)

# 单个轴：死区 → 灵敏度(仅真陀螺仪) → 反转，然后按强度 action_press / action_release
func _apply_gyro_action(action_name: String, raw: float) -> void:
	if action_name.is_empty():
		return
	if not InputMap.has_action(action_name):
		if not _warned_actions.get(action_name, false):
			_warned_actions[action_name] = true
			print("[shoub] 警告：Input Map 里没有动作 \"%s\"" % action_name)
		return
	var strength := _normalize(raw)
	if absf(strength) < 0.0001:
		Input.action_release(action_name)
	else:
		Input.action_press(action_name, strength)

# 归一化：死区 + 灵敏度 + 反转，输出 [-1, 1]
func _normalize(raw: float) -> float:
	if absf(raw) < gyro_deadzone:
		return 0.0
	var scaled := raw
	if not _using_virtual_stick:
		scaled = raw * gyro_sensitivity
	if gyro_invert:
		scaled = -scaled
	return clampf(scaled, -1.0, 1.0)

# 手柄断开时释放所有映射的动作，避免残留"按下"状态
func _release_gyro_actions() -> void:
	for action_name in [gyro_map_x, gyro_map_y, gyro_map_z]:
		if not action_name.is_empty() and InputMap.has_action(action_name):
			Input.action_release(action_name)
