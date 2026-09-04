extends Node2D

var tween = create_tween()
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	tween.tween_property($Icon.material,'shader_parameter/move_x',100,2.0)
	tween.tween_property($Icon.material,'shader_parameter/move_x',0,2.0)
	tween.tween_property($Icon.material,'shader_parameter/Alpha',0.8,2.0)
	tween.tween_property($Icon.material,'shader_parameter/Alpha',0.3,2.0)
