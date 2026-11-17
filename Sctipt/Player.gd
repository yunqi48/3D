extends CharacterBody3D

## 第三人称移动 + 身体朝向 —— 视角不在本节点。
## 左右/上下视角全部由子节点 SpringArm3D 上挂的 ThirdPersonCamera.gd 负责,
## 本脚本只做三件事:
##   1. 按“镜头视平面”(只取 yaw,pitch 压平)算出移动方向并 move_and_slide;
##   2. 重力 / 跳跃;
##   3. 身体 rotation.y 仅作“面向”外观:移动时平滑朝向移动方向,静止时缓回镜头朝向。
## 移动方向不依赖身体朝向 → 镜头可独立于身体转;身体转向也由第三点反向算回,
## 不会让镜头跟着身体转(ThirdPersonCamera 在它的 _physics_process 里补偿了父节点 yaw)。
##
## 输入每物理帧重读一次:InputManager.look_vector() 由相机消费,本节点只读 move_vector()。

@export_group("移动")
## 移动速度(米/秒)
@export var speed: float = 5.0
## 跳跃初速度(米/秒)
@export var jump_velocity: float = 4.5
## 重力加速度(米/秒²)
@export var gravity: float = 9.8

@export_group("身体朝向")
## 身体转向速度(弧度/秒):移动时朝移动方向、静止时朝镜头缓转的速度
@export var turn_speed: float = 10.0

@onready var cam: Node3D = $SpringArm3D/Camera3D


func _physics_process(delta: float) -> void:
	# —— 镜头视平面方向(压平 pitch,仅保留 yaw) ——
	var f := -cam.global_transform.basis.z
	f.y = 0.0
	var fl := f.length()
	if fl < 0.0001:
		f = Vector3.BACK
	else:
		f /= fl
	# 相机默认不 roll,right 可直接由 f 推出:yaw=0 时 f=(0,0,-1)、right=(1,0,0)
	var right := Vector3(-f.z, 0.0, f.x)

	# —— 移动(相对镜头:move_vector 的 x=右+、y=后+;方向语义与重构前一致) ——
	var move := InputManager.move_vector()
	var dir := right * move.x + f * (-move.y)
	var moving := dir.length() > 0.01
	if moving:
		dir = dir.normalized()
		velocity.x = dir.x * speed
		velocity.z = dir.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0.0, speed)
		velocity.z = move_toward(velocity.z, 0.0, speed)

	# —— 重力 ——
	if not is_on_floor():
		velocity.y -= gravity * delta

	# —— 跳跃 ——
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = jump_velocity

	move_and_slide()

	# —— 身体朝向:移动时朝移动方向,静止时缓回镜头朝向 ——
	var target_yaw := atan2(-dir.x, -dir.z) if moving else atan2(-f.x, -f.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, turn_speed * delta)
