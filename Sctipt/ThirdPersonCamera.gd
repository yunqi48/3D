extends SpringArm3D

## 第三人称相机 —— 挂到 Player 下的 SpringArm3D 节点上。
## 视角代码整体收在本节点,让 Player 根脚本只负责移动与身体朝向。
## 节点分工:
##   Player (CharacterBody3D)  : 位移 + 身体 rotation.y(仅“面向”外观,会随移动/视角转)
##   SpringArm3D (本节点)      : yaw / pitch / 肩偏位置 / 距离全部在自身保存并应用。
##                              其「世界 yaw」就是镜头朝向,Player 移动脚本按它算方向。
##   Camera3D                  : 子节点,位于臂末端。
##
## 为什么要在自身补偿父节点旋转:
##   Player 为了“身体跟随”会自己转 rotation.y;若本节点不补偿,镜头会跟着身体一起转,
##   失去“镜头独立”。所以每帧写 rotation.y = 世界yaw − 父节点rotation.y,保证无论身体
##   转到哪,镜头的世界朝向都稳定在 _yaw_world。
##
## 参数语义(与重构前一致):
##   shoulder_height / shoulder_offset  —— 本节点相对 Player 的位置(机位转轴:肩高 + 左右偏肩)
##   camera_distance  —— spring_length:镜头后退距离(撞墙自动缩回)
##   camera_height    —— 只计入默认俯角反推(作为转轴附加高度)
##   aim_height       —— 无视角输入时屏幕中心对准的角色身上高度(脚底=0);用于反推默认俯角
##   pitch_limit      —— 围绕 _base_pitch 可上下旋转的最大角度(度)
##
## 说明:已验证本引擎(4.7)SpringArm3D 把子节点(Camera3D)沿自身 +Z 推出,
## 故相机置于 pivot 的 +Z 即角色正后方(角色前向 -Z),无需任何 180° 镜像节点。

@export_group("机位")
## 转轴离地高度(构图主变量,决定角色在画面里的上下位置)
@export_range(0.0, 50.0, 0.1) var shoulder_height: float = 1.9
## 转轴相对 Player 的左右偏移:正数 = 偏向镜头/玩家右侧
@export_range(-5.0, 5.0, 0.1) var shoulder_offset: float = 0.55
## 镜头后退距离(SpringArm 长度)
@export_range(0.5, 50.0, 0.1) var camera_distance: float = 3.6
## 计入默认俯角反推的附加高度(Camera3D 本身保持 ZERO)
@export_range(-5.0, 5.0, 0.1) var camera_height: float = 0.1
## 无视角输入时屏幕中心对准的角色身上高度(脚底 = 0)
@export_range(0.0, 4.0, 0.1) var aim_height: float = 1.35
## SpringArm 撞墙后镜头与墙保留的最小间距
@export_range(0.0, 2.0, 0.05) var spring_margin: float = 0.25

@export_group("视角")
## 围绕默认俯角可上下旋转的最大范围(度)
@export_range(1.0, 89.0, 0.1) var pitch_limit: float = 50.0

## 镜头朝向(世界帧):yaw 左右、pitch 上下(弧度)
var _yaw_world: float = 0.0
var _pitch: float = 0.0
## 默认俯角(由机位参数反推)
var _base_pitch: float = 0.0

func _ready() -> void:
	_apply_rig_from_params()
	_yaw_world = _parent_yaw()
	_base_pitch = _compute_base_pitch()
	_pitch = _base_pitch
	_apply_rotation()

## SpringArm 撞墙探测只碰 layer 1(环境/地面/墙);Player 在 layer 2,不会自撞。
func _apply_rig_from_params() -> void:
	position = Vector3(shoulder_offset, shoulder_height, 0.0)
	spring_length = camera_distance
	margin = spring_margin
	collision_mask = 1

## 世界 yaw 与父节点旋转的换算里,需要把父节点当前的 rotation.y 读出来。
func _parent_yaw() -> float:
	var p := get_parent()
	return p.rotation.y if p else 0.0

## 基础俯视角:根据 转轴(含附加)高度、瞄准点高度、后退距离 反推默认往下看的俯角。
## 调 shoulder_height / camera_height / aim_height / camera_distance 后会自动重算。
func _compute_base_pitch() -> float:
	var cam_y := shoulder_height + camera_height
	var dy := cam_y - aim_height
	if dy <= 0.0:
		return 0.0  # 转轴不高于瞄准点,无需下俯
	return -atan2(dy, camera_distance)

func _physics_process(_delta: float) -> void:
	var look := InputManager.look_vector()
	_yaw_world -= look.x
	_pitch = clampf(_pitch - look.y,
		_base_pitch - deg_to_rad(pitch_limit),
		_base_pitch + deg_to_rad(pitch_limit))
	_apply_rotation()

func _apply_rotation() -> void:
	# 本节点 yaw = 世界 yaw − 父节点 yaw:无论身体转到哪,镜头世界朝向稳定在 _yaw_world。
	rotation.y = _yaw_world - _parent_yaw()
	rotation.x = _pitch

