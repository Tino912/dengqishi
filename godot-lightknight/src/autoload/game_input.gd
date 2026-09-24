extends Node
## GameInput —— 输入映射与边沿检测。
##
## 为什么不用 project.godot 的 [input] 段：
## 那里的 InputEvent 是序列化对象，手写易错且随版本变化；代码注册更可靠、可读、可测。
##
## 为什么自己做"刚按下"检测而不是用 Input.is_action_just_pressed()：
## 世界是以固定步长推进的（step(1/60)），自检时更是由脚本直接驱动，
## Godot 基于帧的 just_pressed 语义在这种驱动方式下不可靠。
## 这里用"每个固定步采样一次、和上一步比对"的方式，游戏内与自检语义完全一致。
##
## 另外提供 set_override()：让自检不依赖操作系统的输入栈，完全确定性地注入按键。

## 每个固定步会被采样一次的动作表 —— **新动作必须加进来**，
## 否则 set_override() 注进去也不会被 sample() 看到（just() 永远是 false）。
const ACTIONS := [
	"move_up", "move_down", "move_left", "move_right",
	"attack", "dash", "skill1", "skill2", "skill3",
	"interact", "pause", "confirm", "restart",
	## 三选一专用：Q / E 左右移动高亮。
	## 单独两个动作而不是复用 move_left/move_right，是因为三选一里
	## **只有这两个键能移动高亮**，A/D 必须无效 —— 复用就做不到这个区分。
	"draft_prev", "draft_next",
]

## 瞄准方式：mouse = 鼠标指向（默认）；move = 跟随移动方向（无鼠标/自检时用）
var aim_mode := "mouse"

var _cur := {}
var _prev := {}
var _override := {}
var mouse_pos := Vector2.ZERO
var mouse_seen := false

## 强制瞄向某个世界坐标（null = 不干预）。自检与机器人回放用它，
## 免得为了瞄准去伪造鼠标事件。
var aim_world = null


func _ready() -> void:
	_register("move_up", [KEY_W, KEY_UP])
	_register("move_down", [KEY_S, KEY_DOWN])
	_register("move_left", [KEY_A, KEY_LEFT])
	_register("move_right", [KEY_D, KEY_RIGHT])
	_register("attack", [KEY_J], [MOUSE_BUTTON_LEFT])
	_register("dash", [KEY_SHIFT, KEY_SPACE])
	_register("skill1", [KEY_1])
	_register("skill2", [KEY_2])
	_register("skill3", [KEY_3])
	_register("interact", [KEY_E, KEY_F])
	_register("pause", [KEY_ESCAPE])
	_register("confirm", [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE])
	_register("restart", [KEY_R])
	_register("draft_prev", [KEY_Q])
	_register("draft_next", [KEY_E])


func _register(action: String, keys: Array, buttons: Array = []) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, 0.2)
	for k in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = k
		InputMap.action_add_event(action, ev)
	for b in buttons:
		var mb := InputEventMouseButton.new()
		mb.button_index = b
		InputMap.action_add_event(action, mb)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_seen = true


# ---------------------------------------------------------------- 采样

## 每个固定步调用一次，必须在 world.step() 之前。
func sample() -> void:
	_prev = _cur
	_cur = {}
	for a in ACTIONS:
		if _override.has(a):
			_cur[a] = bool(_override[a])
		else:
			_cur[a] = InputMap.has_action(a) and Input.is_action_pressed(a)
	if aim_mode == "mouse":
		var vp := get_viewport()
		if vp != null:
			mouse_pos = vp.get_mouse_position()


func held(action: String) -> bool:
	return bool(_cur.get(action, false))


func just(action: String) -> bool:
	return bool(_cur.get(action, false)) and not bool(_prev.get(action, false))


## 移动轴（已归一化，保证斜向不加速）
func axis() -> Vector2:
	var v := Vector2(
		(1.0 if held("move_right") else 0.0) - (1.0 if held("move_left") else 0.0),
		(1.0 if held("move_down") else 0.0) - (1.0 if held("move_up") else 0.0),
	)
	return v.normalized() if v.length_squared() > 1.0 else v


# ---------------------------------------------------------------- 测试注入

## v 为 null 时清除覆写，恢复真实键盘
func set_override(action: String, v) -> void:
	if v == null:
		_override.erase(action)
	else:
		_override[action] = bool(v)


func clear_overrides() -> void:
	_override.clear()


func has_override() -> bool:
	return not _override.is_empty()


func snapshot() -> Dictionary:
	return {"cur": _cur.duplicate(), "prev": _prev.duplicate(), "overrides": _override.duplicate()}
