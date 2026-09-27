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
	## 背包：X 换手（手持 ↔ 背包武器）、C 喝灯油（背包里的回血道具）
	"swap_weapon", "use_potion",
	## F11 全屏。**任何界面都要生效**（标题 / 暂停 / 三选一 / 商店 / 对白），
	## 所以它由 main.advance() 在状态分发**之前**处理，而不是挂在某个状态里。
	##
	## ⚠️ 加新动作**必须同时**加进这张表：只把它装进 InputMap 是不够的 ——
	## 采样只看这张表，漏了它 `just()` 就永远是 false，键按下去毫无反应
	## （而且不会报任何错）。本项目这条已经踩过第二次了。
	## 同时 `DEFAULT_KEYS` / `REBINDABLE` 也要有它，否则设置界面里改不了它。
	"fullscreen",
]

## 设置界面里**可重绑**的动作，顺序就是设置界面的行序。
## 每一项 = [动作, 中文名]。加新动作时这里也要加 ——
## 自检有一条断言专门守它（"每个动作都有中文名 / 都在可重绑表里"）。
const REBINDABLE := [
	["move_up", "上移"], ["move_down", "下移"],
	["move_left", "左移"], ["move_right", "右移"],
	["dash", "冲刺"], ["attack", "攻击"],
	["skill1", "技能 1"], ["skill2", "技能 2"], ["skill3", "技能 3"],
	["swap_weapon", "换手（手持 ↔ 背包）"], ["use_potion", "喝灯油"],
	["interact", "交互 / 上船"], ["confirm", "确认"],
	["pause", "菜单 / 返回"], ["restart", "重开这一关"],
	["draft_prev", "三选一 左移"], ["draft_next", "三选一 右移"],
	["fullscreen", "全屏"],
]

## 出厂按键。**这张表是唯一的默认来源** —— `reset_bindings()` 直接抄它，
## 设置界面的"这一项是否已改过"也拿它比。
##
## 一个动作可以带多个键（上移 = W 与 ↑）；设置界面显示的是整串，
## 重绑会把它**换成单个键**（玩家按下哪个就是哪个）。
const DEFAULT_KEYS := {
	"move_up": [KEY_W, KEY_UP],
	"move_down": [KEY_S, KEY_DOWN],
	"move_left": [KEY_A, KEY_LEFT],
	"move_right": [KEY_D, KEY_RIGHT],
	"attack": [KEY_J],
	"dash": [KEY_SHIFT, KEY_SPACE],
	"skill1": [KEY_1],
	"skill2": [KEY_2],
	"skill3": [KEY_3],
	"interact": [KEY_E, KEY_F],
	"pause": [KEY_ESCAPE],
	"confirm": [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE],
	"restart": [KEY_R],
	"draft_prev": [KEY_Q],
	"draft_next": [KEY_E],
	"swap_weapon": [KEY_X],
	"use_potion": [KEY_C],
	"fullscreen": [KEY_F11],
}

## 鼠标键不算"可重绑的键"，但仍然跟着动作一起装进 InputMap。
const DEFAULT_BUTTONS := {"attack": [MOUSE_BUTTON_LEFT]}

## 自定义按键存哪儿。`user://` 是每个玩家自己的目录，不进仓库。
const BIND_PATH := "user://keybindings.json"

## 瞄准方式：mouse = 鼠标指向（默认）；move = 跟随移动方向（无鼠标/自检时用）
var aim_mode := "mouse"

## 当前生效的按键表：动作 → Array[int]（物理键码）。**装进 InputMap 的就是它。**
var binds := {}
## 正在等玩家按新键的动作（"" = 不在抓键）
var _capture := ""
## 抓到的键（0 = 还没抓到）
var _capture_key := 0
## 上一次重绑的失败原因（"" = 成功）
var bind_error := ""
## 真键盘事件只在这里收；自检用 `inject_key()` 走同一条路。
var _keys_down := {}

var _cur := {}
var _prev := {}
var _override := {}
var mouse_pos := Vector2.ZERO
var mouse_seen := false

## 强制瞄向某个世界坐标（null = 不干预）。自检与机器人回放用它，
## 免得为了瞄准去伪造鼠标事件。
var aim_world = null


func _ready() -> void:
	reset_bindings(false)
	load_bindings()


# ---------------------------------------------------------------- 按键表

## 恢复出厂按键。`persist` = 要不要顺手写进存档（自检里**不要**，
## 否则跑一次自检就把玩家里改好的键位洗掉了）。
func reset_bindings(persist := true) -> void:
	binds = {}
	for a in ACTIONS:
		var d: Array = DEFAULT_KEYS.get(a, [])
		binds[a] = d.duplicate()
	_install()
	if persist:
		save_bindings()


## 把 `binds` 装进 InputMap（先清空这个动作的旧绑定，再按当前表重装）。
##
## 为什么每次全量重装而不是"只改一个动作"：那样调用点就要自己记得清旧的，
## 迟早有一处忘掉 —— 而**忘掉的症状是"旧键还能用"**，玩家只会觉得"改了没用"。
func _install() -> void:
	for a in ACTIONS:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.2)
		InputMap.action_erase_events(a)
		for k in binds.get(a, []):
			var ev := InputEventKey.new()
			ev.physical_keycode = int(k)
			InputMap.action_add_event(a, ev)
		for b in DEFAULT_BUTTONS.get(a, []):
			var mb := InputEventMouseButton.new()
			mb.button_index = int(b)
			InputMap.action_add_event(a, mb)


## 真键盘事件只在这里收：一是鼠标见过没有（瞄准方式切换用），
## 二是"设置界面正在等一个键"时把那个键收下来。
##
## ⚠️ 这里**只收下来**，不在这里改键位 —— 改键位要经过 `set_bind()`（有冲突检查），
## 而且必须在固定步里做（自检是手动步进的，事件回调什么时候来是说不准的）。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_seen = true
	if event is InputEventKey and event.pressed and not event.echo:
		_keys_down[event.physical_keycode] = true
		inject_key(event.physical_keycode)


func keys_of(action: String) -> Array:
	return binds.get(action, [])



func is_default(action: String) -> bool:
	var d: Array = DEFAULT_KEYS.get(action, [])
	var c: Array = binds.get(action, [])
	if d.size() != c.size():
		return false
	for i in d.size():
		if int(d[i]) != int(c[i]):
			return false
	return true


## "W / ↑" 这种给人看的串（键名由引擎给，省得自己维护一张表）
func key_names(action: String) -> String:
	var names := []
	for k in binds.get(action, []):
		names.append(OS.get_keycode_string(int(k)))
	return " / ".join(names)


## 哪个动作占着这个键（"" = 没人占）。用来拦"两个动作绑同一个键"。
## `except_action` 自己不算（同一个动作内部重复是允许的）。
func action_using(key: int, except_action: String) -> String:
	for a in binds.keys():
		if a == except_action:
			continue
		if (binds[a] as Array).has(key):
			return a
	return ""


## 把某个动作绑到一个**新的键**上。返回 "" 表示成功，否则是给玩家看的原因。
##
## 冲突**直接拒绝**而不是"把旧的那边顶掉"：把那一边顶掉会让另一个动作
## 变成没有按键的死动作，而玩家根本没碰过它 —— 静默改掉一个自己没动的东西
## 比"这次没改成"糟得多。
func set_bind(action: String, key: int) -> String:
	if key == 0:
		return "没抓到按键。"
	if not ACTIONS.has(action):
		return "未知动作：%s" % action
	var other := action_using(key, action)
	if other != "":
		return "「%s」已经用在「%s」上。" % [OS.get_keycode_string(key), label_of(other)]
	binds[action] = [key]
	bind_error = ""
	_install()
	save_bindings()
	return ""


## 动作的中文名（设置界面用的那张表）
func label_of(action: String) -> String:
	for it in REBINDABLE:
		if str(it[0]) == action:
			return str(it[1])
	return action


# ---------------------------------------------------------------- 抓键

func begin_capture(action: String) -> void:
	_capture = action
	_capture_key = 0
	bind_error = ""


func capture_action() -> String:
	return _capture


func end_capture() -> void:
	_capture = ""
	_capture_key = 0


## 收到一个键。真键盘与自检注入都走这里。
func inject_key(key: int) -> void:
	if _capture != "":
		_capture_key = key


## 取走抓到的键（0 = 还没抓到）。取走即清空。
func poll_capture() -> int:
	var k := _capture_key
	_capture_key = 0
	return k


# ---------------------------------------------------------------- 存档

func save_bindings() -> void:
	var out := {}
	for a in binds.keys():
		var ks := []
		for k in binds[a]:
			ks.append(int(k))
		out[a] = ks
	var f := FileAccess.open(BIND_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"v": 1, "keys": out}, "  "))
	f.close()


## 读存档。**读不出来就当出厂设置**，并且**不改写文件** ——
## 玩家手滑把 json 改坏了不该被静默洗掉（他至少还能自己修回去）。
func load_bindings() -> void:
	if not FileAccess.file_exists(BIND_PATH):
		return
	var f := FileAccess.open(BIND_PATH, FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var keys = parsed.get("keys", {})
	if typeof(keys) != TYPE_DICTIONARY:
		return
	var applied := 0
	for a in keys.keys():
		if not ACTIONS.has(str(a)):
			continue
		var ks = keys[a]
		if typeof(ks) != TYPE_ARRAY or (ks as Array).is_empty():
			continue
		var arr := []
		for k in ks:
			if typeof(k) == TYPE_FLOAT or typeof(k) == TYPE_INT:
				arr.append(int(k))
		if arr.is_empty():
			continue
		binds[str(a)] = arr
		applied += 1
	if applied > 0:
		_install()



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
