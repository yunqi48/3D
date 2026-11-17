extends Control

## 解析后的对话数据列表，每个元素形如：
## { "index": int, "scene": String, "dialogue_name": String, "pid": int, "name": String, "text": String,
##   "links": String, "choices": Array, "set": Array, "if": Array, "ending": Dictionary, "avatar": String }
var dialogues: Array = []
## 当前显示的是第几条对话（数组下标）
var current_index: int = 0
## 打字机：每秒显示的字符数
const TYPING_SPEED: float = 40.0
## 当前是否正在逐字打印
var _typing: bool = false
## 当前打字 Tween（跳过/切句时取消）
var _typing_tween: Tween
## 手柄刚选中选项的那一帧置位，用来挡住同帧的推进逻辑（防止把新台词立刻跳过）
var _choice_just_selected: bool = false

## 结局横幅展示后，游戏层可用它感知结局
signal dialogue_ended(ending_id: String)

## 结局横幅展示后是否自动跳转到 next_scene（暂无目标场景，先保持 false）
const AUTO_NEXT_SCENE: bool = false

## pid -> 说话人名字颜色（与正文 BBCode 里用过的色一致）
const SPEAKER_COLORS := {
	1: Color("#7fb3ff"),   # AI-9   冷青
	2: Color("#ffcc66"),   # 幸存者 暖琥珀
	3: Color("#7fff8f"),   # 林岚   草绿
}
const SPEAKER_COLOR_DEFAULT := Color(0.68, 0.68, 0.68)

## 结局已展示：锁住推进
var _dialogue_over: bool = false
## 当前说话人立绘路径（已解析，暂未渲染）
var _current_avatar: String = ""

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var data = JsonHelper.read_json_file("res://Text/Text.json")
	if data is Array:
		dialogues = JsonHelper.parse_dialogue(data)
		_show_dialogue(0)
	else:
		print("读取失败，JSON 顶层不是数组: ", data)

func _process(_delta: float) -> void:
	# 手柄选中选项的那一帧跳过推进，避免把新台词立刻跳过
	if _choice_just_selected:
		_choice_just_selected = false
	elif not _dialogue_over and InputManager.just_pressed(InputManager.ADVANCE):
		_advance()

# 空格/回车/手柄 A 键：打字中跳过，无选项时推进（有选项时由选项按钮接管）
func _advance() -> void:
	if _dialogue_over:
		return
	if _typing:
		_skip_typing()
	elif not _has_choices():
		_show_next()

# 根据当前对话的 links 字段（下一条对话的名字）跳转
func _show_next() -> void:
	var current: Dictionary = dialogues[current_index]
	var next_name: String = current["links"]
	if next_name.is_empty():
		print("对话结束")
		return
	var next_index := _find_by_name(next_name)
	if next_index == -1:
		print("找不到名为 \"%s\" 的下一条对话" % next_name)
		return
	_show_dialogue(next_index)

# 在对话列表中按 DialogueName 查找，找不到返回 -1
func _find_by_name(target_name: String) -> int:
	for i in dialogues.size():
		if dialogues[i]["dialogue_name"] == target_name:
			return i
	return -1

# 显示第 index 条对话（index 是对话在数组中的下标）
func _show_dialogue(index: int) -> void:
	if index < 0 or index >= dialogues.size():
		print("没有第 %d 条对话（共 %d 条）" % [index, dialogues.size()])
		return
	current_index = index
	var d: Dictionary = dialogues[current_index]

	_dialogue_over = false
	# 节点级 set：先于台词展示生效，本节点选项与后续节点都能读到
	GameState.apply_effects(d.get("set", []))
	$EndingBanner.hide()

	# pid 配色：说话人名字着色
	var pid := int(d.get("pid", -1))
	$SpeakerText.add_theme_color_override("font_color", SPEAKER_COLORS.get(pid, SPEAKER_COLOR_DEFAULT))
	$SpeakerText.text = "%s:" % d.name

	# 立绘路径已解析，暂未渲染
	_current_avatar = d.get("avatar", "")

	$SpeakText.text = d.text
	_clear_choices()
	_start_typing(d)
	print("显示第 %d 条: %s" % [current_index, d.text])

# 开始逐字打印当前台词（支持 BBCode 富文本）
func _start_typing(d: Dictionary) -> void:
	if _typing_tween:
		_typing_tween.kill()
	var chars: int = _plain_length(d.text)
	$SpeakText.visible_ratio = 0.0
	if chars <= 0:
		# 空文本直接显示完成，无需打字
		$SpeakText.visible_ratio = 1.0
		_typing = false
		_typing_finished()
		return
	_typing = true
	var duration: float = float(chars) / TYPING_SPEED
	_typing_tween = create_tween()
	_typing_tween.tween_property($SpeakText, "visible_ratio", 1.0, duration)
	_typing_tween.tween_callback(_typing_finished)

# 空格跳过：立即显示全文
func _skip_typing() -> void:
	if _typing_tween:
		_typing_tween.kill()
	$SpeakText.visible_ratio = 1.0
	_typing = false
	_typing_finished()

# 一句话打印完毕（打完或跳过都会走到这里），此时才弹出选项
func _typing_finished() -> void:
	_typing = false
	var d: Dictionary = dialogues[current_index]
	var ending: Dictionary = d.get("ending", {})
	if not ending.is_empty():
		_show_ending(ending)
		return
	_update_choices(d)

# 结局节点：显示标题横幅、锁推进、发信号、记录结局并存档
func _show_ending(ending: Dictionary) -> void:
	var ending_id := str(ending.get("id", ""))
	$EndingBanner/EndingCenter/EndingTitle.text = str(ending.get("title", ""))
	$EndingBanner/EndingCenter/EndingSubtitle.text = str(ending.get("subtitle", ""))
	$EndingBanner.show()
	_dialogue_over = true
	dialogue_ended.emit(ending_id)
	GameState.record_ending(ending_id)
	if AUTO_NEXT_SCENE and not str(ending.get("next_scene", "")).is_empty():
		get_tree().change_scene_to_file(str(ending["next_scene"]))

# 统计去掉 BBCode 标签后的可见字符数，用来算打字时长
static func _plain_length(bbcode_text: String) -> int:
	var regex := RegEx.new()
	regex.compile("\\[[^\\]]*\\]")
	return regex.sub(bbcode_text, "").length()

# 当前对话是否有分支选项（有选项时不允许空格线性推进）
func _has_choices() -> bool:
	if current_index < 0 or current_index >= dialogues.size():
		return false
	return not _get_visible_choices(dialogues[current_index]).is_empty()

# 按选项级 if 条件过滤可见选项；无 if / 空数组 = 无条件（旧选项始终显示）
func _get_visible_choices(d: Dictionary) -> Array:
	var raw: Array = d.get("choices", [])
	if raw.is_empty():
		return []
	var visible_choices: Array = []
	for c in raw:
		if c is Dictionary and GameState.evaluate_conditions(c.get("if", [])):
			visible_choices.append(c)
	return visible_choices

# 根据当前对话的可见选项刷新按钮；没有选项则清空并隐藏
func _update_choices(d: Dictionary) -> void:
	_clear_choices()
	var raw: Array = d.get("choices", [])
	var visible_choices := _get_visible_choices(d)
	if visible_choices.is_empty():
		if not raw.is_empty():
			# 有选项但全被条件过滤掉：回退到线性 links 推进，避免软锁
			print("全部选项被条件过滤掉，回退到线性 links 推进")
		return
	var buttons: Array[Button] = []
	for c in visible_choices:
		var btn := Button.new()
		btn.text = c.get("text", "")
		btn.pressed.connect(_on_choice_selected.bind(c))
		$ChoiceBox.add_child(btn)
		buttons.append(btn)
	# 手柄/方向键支持：上下键在选项间移动焦点，A/空格 选中；鼠标点击照常可用
	for i in buttons.size():
		if i > 0:
			buttons[i].focus_neighbor_top = buttons[i - 1].get_path()
		if i < buttons.size() - 1:
			buttons[i].focus_neighbor_bottom = buttons[i + 1].get_path()
	buttons[0].grab_focus()
	$ChoiceBox.show()

# 清空并隐藏选项按钮
func _clear_choices() -> void:
	for child in $ChoiceBox.get_children():
		child.queue_free()
	$ChoiceBox.hide()

# 点击某个选项：先应用选项级 set，再跳到它指向的对话
func _on_choice_selected(choice: Dictionary) -> void:
	_choice_just_selected = true
	GameState.apply_effects(choice.get("set", []))
	var target_name: String = str(choice.get("links", ""))
	var next_index := _find_by_name(target_name)
	if next_index == -1:
		print("找不到名为 \"%s\" 的分支目标" % target_name)
		return
	_show_dialogue(next_index)
