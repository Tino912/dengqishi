class_name Main
extends Node2D
## Main —— 引导、状态机与固定步长驱动。
##
## 固定步长很关键：游戏内与自检走同一条代码路径（advance），
## 只是自检把 advance() 直接调 N 次而不等真实帧。
## 这让"在真引擎里跑逻辑"和"在真引擎里渲染"用的是同一份世界状态。

const STEP := 1.0 / 60.0

## 自检模式：不自动跑 _process，由外部逐个 advance()
var manual := false

var world: World
var hud: Hud

## title | play | dialogue | menu | draft
var state := "title"

var prog := {
	"coins": 0, "wicks": 0,
	"up": {"hp": 0, "light": 0, "edge": 0},
	"shop": {"ember": 0, "brightoil": 0},
	"weapon": "blade",
	"kills": 0, "deaths": 0, "max_combo": 0,
	## 当前关卡（0 = 灯堡外庭，1 = 灯堡深处·无芯之暗）
	"level": 0,
	## 局内恩赐（肉鸽）。死亡 / 重开清空，过关带走。
	"boons": {},
}

var dev_spawn := false

var _acc := 0.0
var _dlg_lines := []
var _dlg_i := 0
var _pending_dlg := []
var _clear_pending := false
var _menu_kind := ""

## 三选一
var _pending_draft := false
var _draft_items := []
var _draft_index := 0
## 自检用：面板打开过几次（"确实走到了肉鸽循环"的可核对证据）
var draft_opens := 0


func _ready() -> void:
	GameInput.aim_mode = "mouse"
	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)

	for a in OS.get_cmdline_user_args():
		if a == "--dev-spawn":
			dev_spawn = true
		if a == "--no-dialogue":
			skip_dialogue = true

	show_title()


## 命令行 --no-dialogue：跳过开场对白（方便录像/截图）
var skip_dialogue := false


func _process(delta: float) -> void:
	if manual:
		return
	_acc += minf(delta, 0.25)
	var guard := 0
	while _acc >= STEP and guard < 8:
		advance(STEP)
		_acc -= STEP
		guard += 1


# ---------------------------------------------------------------- 状态机

func show_title() -> void:
	state = "title"
	_menu_kind = "title"
	_free_world()
	prog["level"] = 0
	prog["boons"] = {}
	hud.hide_draft()
	hud.show_overlay(
		"灯 骑 士",
		"第一关 · 灯堡外庭　→　第二关 · 灯堡深处 · 无芯之暗\n"
		+ "「外庭的灯还亮着，这是你最好的日子。」\n\n"
		+ "WASD 移动　鼠标瞄准　J 挥击　Shift 冲刺　1/2/3 技能　E 交互\n"
		+ "清空一波会跳出三选一：Q / E 左右看，空格拿走。死了就重来一趟。\n"
		+ "连击就是你的光：打得越顺，灯越亮；停下来，黑暗会咬住你。",
		"按 空格 / 点击 开始"
	)


func start_level() -> void:
	_free_world()
	world = World.new()
	world.name = "World"
	world.prog = prog
	add_child(world)
	move_child(world, 0)
	world.setup(dev_spawn, int(prog["level"]))
	state = "play"
	_menu_kind = ""
	_clear_pending = false
	_pending_draft = false
	hud.hide_draft()
	hud.hide_overlay()
	hud.show_dialogue(false)
	if not skip_dialogue:
		var lv := int(prog["level"])
		play_dialogue("l1_start" if lv == 0 else "l2_start")


## 下一关（清空当前关后由玩家确认）
func next_level() -> void:
	prog["level"] = mini(int(prog["level"]) + 1, Content.level_count() - 1)
	start_level()


func _free_world() -> void:
	if world != null:
		# 立刻从树上摘下来（否则它还会继续 _draw），再排队释放
		remove_child(world)
		world.queue_free()
		world = null


## 一次固定步进：采样输入 → 推进世界 → 路由事件 → 刷新界面
func advance(dt: float) -> void:
	GameInput.sample()

	match state:
		"title":
			if GameInput.just("confirm") or GameInput.just("attack"):
				Sound.play("ui_big")
				start_level()
		"play":
			if GameInput.just("pause"):
				_menu_kind = "pause"
				state = "menu"
				hud.show_overlay("暂　停", _stats_text(), "Esc 继续　·　R 重新开始　·　E 回标题", "pause")
			else:
				world.step(dt)
		"dialogue":
			# 与 Web 版一致：空格 / 回车 / E / F 都能翻页
			if GameInput.just("confirm") or GameInput.just("attack") or GameInput.just("interact"):
				_dlg_next()
		"menu":
			_menu_input()
		"draft":
			_draft_input(dt)

	if world != null:
		_drain_events()
		hud.refresh(world)
	hud.tick(dt)


func _menu_input() -> void:
	if _menu_kind == "pause":
		if GameInput.just("pause"):
			state = "play"
			_menu_kind = ""
			hud.hide_overlay()
		elif GameInput.just("restart"):
			restart_level()
		elif GameInput.just("interact"):
			show_title()
	elif _menu_kind == "death":
		if GameInput.just("restart") or GameInput.just("confirm"):
			respawn()
		elif GameInput.just("pause"):
			show_title()
	elif _menu_kind == "clear":
		if GameInput.just("restart") or GameInput.just("confirm"):
			# 还有下一关就去下一关，否则重开这一关
			if int(prog["level"]) < Content.level_count() - 1:
				next_level()
			else:
				restart_level()
		elif GameInput.just("pause"):
			show_title()


# ---------------------------------------------------------------- 三选一（肉鸽）

## 面板打开后，确认键要等这么久才"装填"完毕。
##
## 为什么需要：清空一波的瞬间玩家往往正在连打空格（冲刺键就是空格），
## 那个按键边沿会被当成"确认第一张"，手一抖就白丢一次三选一。
## 0.35 秒刚好是读完三张卡标题的时间，正常玩完全感觉不到。
const DRAFT_ARM := 0.35

var _draft_t := 0.0


func _draft_armed() -> bool:
	return _draft_t >= DRAFT_ARM


## 三选一的输入：**只有 Q/E 能移动高亮，只有空格/回车能拿走**。
##
## 1/2/3、A/D、J（攻击）、鼠标左键在这里**一律无效** —— 这是刻意收紧的：
## 旧版按 1/2/3 是"直接选中"，眼睛还没扫完就按下去了，肉鸽里选错一张
## 要赔一整局。改成"Q/E 移高亮 → 空格确认"之后，误触路径只剩下面这条装填窗口。
## Esc 仍然可以放弃这次恩赐（跳过在肉鸽里是正当选择）。
##
## 注意这里**不**读 move_left/move_right：那会让 A/D 也能移动高亮，
## 而用户要的是"别的键无效"。
func _draft_input(dt: float) -> void:
	_draft_t += dt
	var n := _draft_items.size()
	if n <= 0:
		_close_draft()
		return
	if GameInput.just("draft_prev"):
		_draft_index = (_draft_index - 1 + n) % n
		Sound.play("ui")
		hud.show_draft(_draft_items, _draft_index, _draft_armed())
		return
	if GameInput.just("draft_next"):
		_draft_index = (_draft_index + 1) % n
		Sound.play("ui")
		hud.show_draft(_draft_items, _draft_index, _draft_armed())
		return
	if GameInput.just("pause"):
		# 放弃这次：肉鸽里"跳过"也是一个正当选择
		hud.toast("你放弃了这次的恩赐。")
		_close_draft()
		return
	if GameInput.just("confirm") and _draft_armed():
		_take_draft(_draft_index)


func _open_draft() -> void:
	if world == null:
		return
	_draft_items = world.roll_draft()
	_draft_index = 0
	_draft_t = 0.0
	draft_opens += 1
	state = "draft"
	_menu_kind = ""
	hud.show_draft(_draft_items, _draft_index, false)
	Sound.play("levelup")


## 事件可能在别的状态里到达（比如正在播对白），先记下来
func _request_draft() -> void:
	if state == "play":
		_open_draft()
	else:
		_pending_draft = true


func _take_draft(i: int) -> void:
	if i >= 0 and i < _draft_items.size() and world != null:
		world.apply_draft(_draft_items[i])
		Sound.play("ui_big")
	_close_draft()


func _close_draft() -> void:
	hud.hide_draft()
	_draft_items = []
	_draft_index = 0
	state = "play"
	if not _pending_dlg.is_empty():
		play_dialogue(_pending_dlg.pop_front())
		return
	if _clear_pending:
		_clear_pending = false
		_show_clear()


func restart_level() -> void:
	prog["coins"] = int(float(prog["coins"]) * 0.75)
	# 肉鸽：重开这一趟 = 重新开始一局，恩赐清空
	prog["boons"] = {}
	start_level()


func respawn() -> void:
	if world != null:
		world.prog["deaths"] = int(world.prog["deaths"])
	prog["coins"] = int(float(prog["coins"]) * 0.75)
	prog["boons"] = {}
	start_level()


# ---------------------------------------------------------------- 事件路由

func _drain_events() -> void:
	var evs := world.events
	world.events = []
	for e in evs:
		match str(e["type"]):
			"toast":
				hud.toast(str(e["text"]))
			"boss_start":
				hud.toast("【%s】从黑暗里站了起来" % str(e["name"]))
			"dialogue":
				_queue_dialogue(str(e["key"]))
			"level_cleared":
				_clear_pending = true
				Sound.play("levelup")
			"draft":
				_request_draft()
			"player_died":
				_on_player_died()
			_:
				pass


func _queue_dialogue(key: String) -> void:
	if state == "play":
		play_dialogue(key)
	else:
		_pending_dlg.append(key)


func play_dialogue(key: String) -> void:
	var lines: Array = Content.DIALOGUES.get(key, [])
	if lines.is_empty():
		return
	_dlg_lines = lines
	_dlg_i = 0
	state = "dialogue"
	hud.show_dialogue(true)
	var l: Array = _dlg_lines[0]
	hud.set_dialogue(str(l[0]), str(l[1]))


func _dlg_next() -> void:
	Sound.play("ui")
	_dlg_i += 1
	if _dlg_i < _dlg_lines.size():
		var l: Array = _dlg_lines[_dlg_i]
		hud.set_dialogue(str(l[0]), str(l[1]))
		return
	hud.show_dialogue(false)
	_dlg_lines = []
	if not _pending_dlg.is_empty():
		play_dialogue(_pending_dlg.pop_front())
		return
	if _pending_draft:
		_pending_draft = false
		_open_draft()
		return
	if _clear_pending:
		_clear_pending = false
		_show_clear()
		return
	state = "play"


func _on_player_died() -> void:
	_menu_kind = "death"
	state = "menu"
	hud.show_dialogue(false)
	hud.show_overlay("你 的 灯 灭 了",
		"黑暗把你拖回上一座灯塔。灯火散落了一些。\n\n" + _stats_text(),
		"按 R 重生　·　Esc 回标题", "death")


func _show_clear() -> void:
	_menu_kind = "clear"
	state = "menu"
	var lv := int(prog["level"])
	var last := lv >= Content.level_count() - 1
	var body := ""
	if lv == 0:
		body = "钟声第三下，外庭所有的灯同时熄了……\n\n"
	else:
		body = "盲女点亮了灯塔。从此她也成了你身上的光。\n\n"
	body += _stats_text()
	if last:
		body += "\n\n两关都通了——灯骑士走出了无芯之暗。"
	else:
		body += "\n\n灯塔已亮起——前面还有更暗的地方。"
	hud.show_overlay(str(world.level["name"]) + "　已 恢 复 光 明", body,
		("按 空格 前往下一关" if not last else "按 R 重新开始") + "　·　Esc 回标题", "clear")


func _stats_text() -> String:
	var bl := []
	for b in Content.BOONS:
		var c := int(prog["boons"].get(str(b["id"]), 0))
		if c > 0:
			bl.append("%s×%d" % [str(b["name"]), c])
	var boon_txt := "　恩赐 %d 项" % bl.size() if not bl.is_empty() else "　（没有恩赐）"
	return "灯火 %d　灯芯 %d　击杀 %d　死亡 %d　最高连击 %d%s" % [
		int(prog["coins"]), int(prog["wicks"]),
		int(prog["kills"]), int(prog["deaths"]), int(prog["max_combo"]), boon_txt]


# ---------------------------------------------------------------- 供自检/调试读取

func debug_state() -> Dictionary:
	var d := {
		"state": state,
		"menu": _menu_kind,
		"has_world": world != null,
		"dialogue_open": hud.dlg_panel.visible if hud != null else false,
		"overlay_visible": hud.overlay.visible if hud != null else false,
		"draft_open": hud.draft_layer.visible if hud != null else false,
		"level": int(prog["level"]),
		"boon_count": prog["boons"].size() if typeof(prog["boons"]) == TYPE_DICTIONARY else 0,
		"weapon": str(prog["weapon"]),
	}
	if world != null:
		d["hp"] = world.player.hp
		d["combo"] = world.player.combo_int()
		d["light_radius"] = world.player_light_radius()
		d["brightness"] = world.brightness01()
		d["enemies"] = world.alive_enemy_count()
		d["waves_cleared"] = world.waves_cleared_count()
		d["boss_spawned"] = world.boss_spawned
		d["boss_dead"] = world.boss_dead
		d["cleared"] = world.cleared
		d["coins"] = int(world.prog["coins"])
		d["kills"] = int(world.prog["kills"])
		d["deaths"] = int(world.prog["deaths"])
		d["max_combo"] = int(world.prog["max_combo"])
		d["player_dead"] = world.player.dead
		d["objective"] = world.objective
		d["prompt"] = world.prompt
		d["occluders"] = world.light_rig.occluder_count()
		d["lights"] = world.light_rig.light_count()
		d["braziers_lit"] = world.braziers_lit
		d["braziers_required"] = world.braziers_required
		d["boss_warded"] = world.boss_warded()
		d["skill_count"] = world.player.skills().size()
		d["respawn_count"] = world.respawn_count
		d["has_girl"] = world.girl != null
		d["girl_near"] = world.girl_near
	return d

