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

## title | play | dialogue | menu | draft | shop
var state := "title"

var prog := {
	"coins": 0, "wicks": 0,
	"up": {"hp": 0, "light": 0, "edge": 0},
	"shop": {"ember": 0, "brightoil": 0},
	"weapon": "blade",
	## 背包栏：备用武器（"" = 空）与武器词条表（{武器id: [{id,lv}]}）
	"bag_weapon": "",
	"waffix": {},
	## 武器元素：{武器id: 元素id}。**一局摇一次**（看 new_run），过关带走。
	"welem": {},
	"kills": 0, "deaths": 0, "max_combo": 0,
	## 当前关卡（0 = 灯堡外庭，1 = 灯堡深处·无芯之暗，2 = 灯河渡口）
	"level": 0,
	## 局内恩赐（肉鸽）。死亡 / 重开清空，过关带走。
	"boons": {},
}

var dev_spawn := false

## 这一局的布局种子：宝箱点位、敌人波次锚点、Boss 场地都由它派生。
## **每开一局换一次**（点开始游戏时重新生成），同一局内死亡重生 / 重开这一趟沿用 ——
## 所以"重开一趟"时地图还是刚才那张，玩家记住的宝箱位置不会当场失效。
## 自检会把它覆写成固定值，用来保证 report.json 逐字节可复现。
var run_seed := 0

## 自检沙盒：停掉「波次 → Boss」链条（详见 World.waves_disabled）。
## 波次锚点现在是每局随机的，它可能落进测试段落的活动范围，
## 于是那一波会在不该出现的时候刷出来、又被判"清空"弹出三选一，把世界冻住。
## 正常游戏恒为 false；自检默认 true，只在专门验波次的那一段放开。
var waves_off := false

var _acc := 0.0
var _dlg_lines := []
var _dlg_i := 0
var _pending_dlg := []
var _clear_pending := false
var _menu_kind := ""

## 三选一 / 宝箱（共用同一套冻结态与输入规则，只有"拿走之后干什么"不同）
var _pending_draft := false
var _draft_items := []
var _draft_index := 0
## "draft" = 清波三选一，"chest" = 开宝箱。决定 _take_draft 该调哪个 apply。
var _panel_kind := "draft"
## 面板被别的东西挡住时（正在播对白）先记下来
var _pending_chest := []
## 当前面板的文案。**必须存着**：Q/E 移动高亮时会重新调 show_draft(),
## 不带上这三行的话，宝箱面板一按方向键就会退回三选一的默认标题。
var _panel_title := ""
var _panel_sub := ""
var _panel_hint := ""
## 自检用：面板打开过几次（"确实走到了肉鸽循环"的可核对证据）
var draft_opens := 0
var chest_opens := 0

## 守灯人商店
var _shop_items := []
var _shop_index := 0
var _pending_shop := false
var shop_opens := 0


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
	hud.hide_shop()
	_pending_chest = []
	_pending_shop = false
	_panel_kind = "draft"
	hud.show_overlay(
		"灯 骑 士",
		"第一关 · 灯堡外庭　→　第二关 · 灯堡深处 · 无芯之暗　→　第三关 · 灯河渡口\n"
		+ "「外庭的灯还亮着，这是你最好的日子。」\n\n"
		+ "WASD 移动　鼠标瞄准　J 挥击　Shift 冲刺　1/2/3 技能　E 交互\n"
		+ "X 换手（手持 ↔ 背包武器）　C 喝灯油（背包里的回血道具）\n"
		+ "每开一局，八把武器各随机带一种元素（火/冰/雷/毒/光），攻击会上状态。\n"
		+ "地图上有宝箱，能开出带词条的武器；守灯人能重铸 / 锤炼武器、卖灯油。\n"
		+ "清空一波会跳出三选一：Q / E 左右看，空格拿走。死了就重来一趟。\n"
		+ "连击就是你的光：打得越顺，灯越亮；停下来，黑暗会咬住你。",
		"按 空格 / 点击 开始"
	)


## 开新的一局：**换一张地图**（宝箱与敌人的位置重新生成）。
## 死亡重生 / `restart_level()` **不换** —— 重开这一趟时地图还是刚才那张；
## 想换地图就回标题（Esc）再按一次开始。
func new_run() -> void:
	run_seed = _make_run_seed()
	# 新的一局 = 8 把武器的元素**全部重摇**（清空后由 World.setup 重新 roll）。
	# 同一局内过关、死亡重开都不会重摇 —— 玩家记住的"我那把火刀"不会当场变卦。
	prog["welem"] = {}
	start_level()


## 这一局的布局种子：时间 + 单调计数混合，保证每次开局都不一样。
## 注意它**不参与"逐字节可复现"** —— 那是由自检注入固定 run_seed 实现的，
## 不是靠这里的随机。所以这里可以放心用真随机。
func _make_run_seed() -> int:
	var ms := int(Time.get_unix_time_from_system() * 1000.0)
	var us := Time.get_ticks_usec()
	return absi(hash([ms, us, randi()]))


func start_level() -> void:
	_free_world()
	world = World.new()
	world.name = "World"
	world.prog = prog
	add_child(world)
	move_child(world, 0)
	# 兜底：没走过"开始游戏"那一步（比如 --dev-spawn 直接开）时也得有个非 0 的局种子
	if run_seed == 0:
		run_seed = _make_run_seed()
	world.setup(dev_spawn, int(prog["level"]), run_seed, waves_off)
	state = "play"
	_menu_kind = ""
	_clear_pending = false
	_pending_draft = false
	_pending_chest = []
	_pending_shop = false
	_panel_kind = "draft"
	hud.hide_draft()
	hud.hide_shop()
	hud.hide_overlay()
	hud.show_dialogue(false)
	if not skip_dialogue:
		# 三关各自的入场对白：l1_start / l2_start / l3_start
		play_dialogue("l%d_start" % (int(prog["level"]) + 1))


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
				# 从标题开局 = 新的一局 → 重新摇一张地图（宝箱与敌人换位置）
				new_run()
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
		"shop":
			_shop_input(dt)

	if world != null:
		# 表现层不跟着"世界是否冻结"走：对白 / 结算 / 三选一 / 商店期间上面的
		# match 分支不会调 world.step()，但全屏闪光必须照常淡出 ——
		# 否则死亡瞬间的红闪会一直糊在结算画面上，直到重生才消失。
		# tick_fx 不消耗 RNG，在这里调用不影响自检的确定性。
		world.tick_fx(dt)
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
		_redraw_panel()
		return
	if GameInput.just("draft_next"):
		_draft_index = (_draft_index + 1) % n
		Sound.play("ui")
		_redraw_panel()
		return
	if GameInput.just("pause"):
		# 放弃这次：肉鸽里"跳过"也是一个正当选择
		hud.toast("你放弃了这次的恩赐。")
		_close_draft()
		return
	if GameInput.just("confirm") and _draft_armed():
		_take_draft(_draft_index)


## 重画当前面板（带上面存着的文案）。三选一 / 宝箱共用。
func _redraw_panel() -> void:
	hud.show_draft(_draft_items, _draft_index, _draft_armed(),
		_panel_title, _panel_sub, _panel_hint)


func _open_draft() -> void:
	if world == null:
		return
	_draft_items = world.roll_draft()
	_draft_index = 0
	_draft_t = 0.0
	_panel_kind = "draft"
	_panel_title = ""
	_panel_sub = ""
	_panel_hint = ""
	draft_opens += 1
	state = "draft"
	_menu_kind = ""
	_redraw_panel()
	Sound.play("levelup")


## 开宝箱：**和三选一共用同一个面板与同一套输入规则**（Q/E 移动、空格/回车拿走、Esc 放弃），
## 只是"拿走之后"走的是 apply_chest（进背包）而不是 apply_draft（换手/加恩赐）。
func _open_chest(items: Array) -> void:
	if world == null:
		return
	_draft_items = items
	_draft_index = 0
	_draft_t = 0.0
	_panel_kind = "chest"
	_panel_title = "箱 底 的 兵 器"
	_panel_sub = "Q / E 挑一把，空格放进背包。Esc 就不要了。"
	_panel_hint = "Q ◀　　▶ E　移动高亮　·　空格 / 回车 放进背包　·　Esc 不要了"
	chest_opens += 1
	state = "draft"
	_menu_kind = ""
	_redraw_panel()
	Sound.play("levelup")


## 事件可能在别的状态里到达（比如正在播对白），先记下来
func _request_draft() -> void:
	if state == "play":
		_open_draft()
	else:
		_pending_draft = true


## 宝箱的 items 由 world 在开箱那一刻 roll 好（世界只负责"箱子里有什么"）
func _request_chest(items: Array) -> void:
	if state == "play":
		_open_chest(items)
	else:
		_pending_chest = items


func _take_draft(i: int) -> void:
	if i < 0 or i >= _draft_items.size() or world == null:
		return
	if _panel_kind == "chest":
		world.apply_chest(_draft_items[i])
	else:
		world.apply_draft(_draft_items[i])
	Sound.play("ui_big")
	_close_draft()


func _close_draft() -> void:
	hud.hide_draft()
	_draft_items = []
	_draft_index = 0
	_panel_kind = "draft"
	_panel_title = ""
	_panel_sub = ""
	_panel_hint = ""
	_resume_play()


## 面板（三选一 / 宝箱 / 商店）关掉之后：世界恢复推进，
## 并接着做"刚才被面板挡住的那些事"（对白 → 三选一 → 结算）。
## 三个面板共用这一段 —— 分成三份写必然会有某一份漏掉某个 pending。
func _resume_play() -> void:
	state = "play"
	if not _pending_dlg.is_empty():
		play_dialogue(_pending_dlg.pop_front())
		return
	if _pending_draft:
		_pending_draft = false
		_open_draft()
		return
	if not _pending_chest.is_empty():
		var items: Array = _pending_chest
		_pending_chest = []
		_open_chest(items)
		return
	if _pending_shop:
		_pending_shop = false
		_open_shop()
		return
	if _clear_pending:
		_clear_pending = false
		_show_clear()


# ---------------------------------------------------------------- 守灯人的商店
#
# 与三选一同样的输入规则（Q/E 移动、空格/回车 确认、Esc 离开），
# **同样有装填窗口** —— 玩家是拿 E 把商店点开的，而确认键是空格，
# 但"开商店那一刻手正按着空格在冲刺"是同一个误触路径，所以一视同仁。

func _shop_input(dt: float) -> void:
	_draft_t += dt
	var n := _shop_items.size()
	if n <= 0:
		_close_shop()
		return
	if GameInput.just("draft_prev"):
		_shop_index = (_shop_index - 1 + n) % n
		Sound.play("ui")
		_redraw_shop()
		return
	if GameInput.just("draft_next"):
		_shop_index = (_shop_index + 1) % n
		Sound.play("ui")
		_redraw_shop()
		return
	if GameInput.just("pause"):
		_close_shop()
		return
	if GameInput.just("confirm") and _draft_armed():
		_buy(_shop_index)


## 走进守灯人身边按 E 会收到 "shop" 事件；正在播对白的话先挂着
func _request_shop() -> void:
	if state == "play":
		_open_shop()
	else:
		_pending_shop = true


func _open_shop() -> void:
	if world == null:
		return
	_shop_items = world.shop_items()
	# "离开"由 main 补上（world 只管买卖，不管界面该有几行）
	_shop_items.append({"id": "leave", "name": "离开", "price": 0,
		"desc": "下次再带灯火来。", "ok": true})
	_shop_index = 0
	_draft_t = 0.0
	shop_opens += 1
	state = "shop"
	_menu_kind = ""
	_redraw_shop()
	Sound.play("ui_big")


func _redraw_shop() -> void:
	if world == null:
		return
	hud.show_shop(_shop_items, _shop_index, int(prog["coins"]), _draft_armed())


## 买 / 离开。买完**不关面板**，方便连着买；买不起只提示、不成交。
func _buy(i: int) -> void:
	if i < 0 or i >= _shop_items.size() or world == null:
		return
	var it: Dictionary = _shop_items[i]
	if str(it["id"]) == "leave":
		_close_shop()
		return
	if not bool(it["ok"]):
		world.events.append({"type": "toast", "text": "灯火不够，先攒着。"})
		Sound.play("ui")
		return
	world.buy_shop(str(it["id"]))
	Sound.play("ui_big")
	# 买完重算（灯油数量 / 词条 / 锤炼价钱都会变），高亮停在同一行
	_shop_items = world.shop_items()
	_shop_items.append({"id": "leave", "name": "离开", "price": 0,
		"desc": "下次再带灯火来。", "ok": true})
	_shop_index = clampi(_shop_index, 0, _shop_items.size() - 1)
	_redraw_shop()


func _close_shop() -> void:
	hud.hide_shop()
	_shop_items = []
	_shop_index = 0
	_resume_play()


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
			"chest":
				_request_chest(e["items"])
			"shop":
				_request_shop()
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
	_resume_play()


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
	# 三关各自的收尾词（0 灯堡外庭 / 1 无芯之暗 / 2 灯河渡口）
	var bodies := [
		"钟声第三下，外庭所有的灯同时熄了……\n\n",
		"盲女点亮了灯塔。从此她也成了你身上的光。\n\n",
		"灯河上的浮灯全亮了，一盏一盏朝下游漂去。\n\n",
	]
	var body := str(bodies[clampi(lv, 0, bodies.size() - 1)])
	body += _stats_text()
	if last:
		body += "\n\n三张地图都走完了——灯骑士站在河心，把灯举过头顶。"
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
		"panel_kind": _panel_kind,
		"shop_open": hud.shop_layer.visible if hud != null else false,
		"shop_index": _shop_index,
		"shop_opens": shop_opens,
		"chest_opens": chest_opens,
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
		# 布局随机化：这一局实际生成的点位（排查"这箱子怎么在这儿"时看它）
		d["run_seed"] = run_seed
		d["chest_spots"] = world.layout_info.get("chests", [])
		d["wave_spots"] = world.layout_info.get("waves", [])
		d["boss_spot"] = world.layout_info.get("boss", [])
		d["layout_fallbacks"] = int(world.layout_info.get("fallbacks", 0))
		d["has_girl"] = world.girl != null
		d["girl_near"] = world.girl_near
		# 背包 / 词条 / 宝箱
		d["bag_weapon"] = str(world.prog.get("bag_weapon", ""))
		d["potions"] = world.potion_count()
		d["affix_count"] = world.weapon_affixes().size()
		d["affix_lv_sum"] = world.affix_levels_sum()
		var unopened := 0
		for c in world.chests:
			if not bool(c["opened"]):
				unopened += 1
		d["chests_left"] = unopened
		d["chests_total"] = world.chests.size()
	return d

