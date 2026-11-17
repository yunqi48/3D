@tool
extends EditorPlugin

const EDITOR_SCENE := "res://addons/dialogue_graph/dialogue_editor.tscn"
const MENU_ITEM := "打开对话图编辑器"

func _enter_tree() -> void:
	add_tool_menu_item(MENU_ITEM, _open_editor)

func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)

func _open_editor() -> void:
	EditorInterface.open_scene_from_path(EDITOR_SCENE)
