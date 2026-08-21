extends Camera3D

## 平移速度（米/秒）
@export var move_speed: float = 5.0
## 鼠标灵敏度（弧度/像素）
@export var mouse_sensitivity: float = 0.0025
## 手柄右摇杆视角速度（弧度/秒，满摇杆量）
@export var joy_look_speed: float = 3.0
## 手柄摇杆死区
@export var joy_deadzone: float = 0.15
## 捕获鼠标（Esc 释放，点窗口重新捕获）。
## 对话系统要点按钮选分支，所以默认保持鼠标可见可点。
@export var capture_mouse: bool = false

## 当前俯仰角（绕局部 X 轴，限制 ±89°）
var _pitch: float = 0.0

func _ready() -> void:
	if capture_mouse:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _unhandled_input(event: InputEvent) -> void:
	# 鼠标转动视角
	if event is InputEventMouseMotion:
		if capture_mouse and Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			return
		rotate_y(-event.relative.x * mouse_sensitivity)
		_apply_pitch(-event.relative.y * mouse_sensitivity)
	elif capture_mouse:
		# 捕获模式下 Esc 释放、点窗口重新捕获
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta: float) -> void:
	# 平移：WASD + 手柄左摇杆（贴地走，高度不变）
	var input_vec := Input.get_vector("move_left", "move_right", "move_on", "move_under")
	if input_vec.length() > 0.01:
		var dir := global_transform.basis * Vector3(input_vec.x, 0.0, input_vec.y)
		dir.y = 0.0
		dir = dir.normalized()
		global_translate(dir * move_speed * delta)

	# 视角：手柄右摇杆（Steam 映射下陀螺仪会叠在右摇杆上，一起生效）
	var joy := _active_joypad()
	if joy != -1:
		var look_x := Input.get_joy_axis(joy, JOY_AXIS_RIGHT_X)
		var look_y := Input.get_joy_axis(joy, JOY_AXIS_RIGHT_Y)
		if absf(look_x) > joy_deadzone or absf(look_y) > joy_deadzone:
			rotate_y(-look_x * joy_look_speed * delta)
			_apply_pitch(-look_y * joy_look_speed * delta)

## 返回第一个已连接的手柄设备号，没有则 -1
func _active_joypad() -> int:
	var joypads := Input.get_connected_joypads()
	if joypads.is_empty():
		return -1
	return joypads[0]

## 在局部 X 轴上应用俯仰角，限制在 ±89°，防止翻转过顶
func _apply_pitch(angle: float) -> void:
	_pitch = clampf(_pitch + angle, deg_to_rad(-89.0), deg_to_rad(89.0))
	rotation.x = _pitch
