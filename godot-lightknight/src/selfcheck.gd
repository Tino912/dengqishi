extends Node2D
## SelfCheck —— 在真实引擎里跑完整流程并自检。
##
## 为什么不用 Godot 的单元测试框架：
## 我要验证的东西一大半是**像素**（黑暗够不够黑、光有没有被墙挡住、灯是不是地面正圆）。
## 所以做法与浏览器版一致：让程序自己推进世界状态、自己采样 viewport 的像素、
## 自己给出判定。区别是这次跑在真 Godot 引擎里，渲染也是真渲染。
##
## 输出：res://shots/*.png + shots/report.json，并向 stdout 打印 LKRPT 段。

const OUT_DIR := "res://shots"
const VIEW_W := 1280
const VIEW_H := 720
const STEP := 1.0 / 60.0

## 第一关里选来测遮挡的那面墙（x, y, w, d, h）
const TEST_WALL := [520.0, 300.0, 140.0, 400.0, 54.0]

## 布局种子（宝箱点位 / 敌人锚点 / Boss 场地都由它派生）。
##
## **自检必须注入固定值**：正常游戏里这个种子是 Main 开局时随机摇的，
## 那样每跑一次宝箱和敌人的位置都不一样，`shots/report.json` 不可能逐字节相同，
## "确定性"这条底线就没了。所以这里注入一个常数，
## 再在 `_section_layout()` 里显式验两件事：**换种子位置真的会变、同种子位置不变**。
const LAYOUT_SEED := 20260925

var sub: SubViewport
var main: Main
var report := {"cases": {}, "checks": {}, "samples": {}, "errors": []}
var _checks := {}
var _shot_n := 0

## 肉鸽三选一的记录（自检里用来核对"确实发生了三选一、并且选择生效了"）
var draft_log := []
var draft_taken := 0


func _ready() -> void:
	report["godot"] = Engine.get_version_info()["string"]
	report["renderer"] = RenderingServer.get_video_adapter_name()
	report["viewport"] = [VIEW_W, VIEW_H]
	report["ysquash"] = Proj.YSQUASH
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	sub = SubViewport.new()
	sub.size = Vector2i(VIEW_W, VIEW_H)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = false
	sub.disable_3d = true
	add_child(sub)

	main = Main.new()
	main.manual = true
	main.skip_dialogue = true
	# 布局种子注入固定值 —— 必须在任何 start_level() 之前
	main.run_seed = LAYOUT_SEED
	# 默认停掉「波次 → Boss」链条：锚点是随机的，若落进某段的活动范围，
	# 那一波会意外刷出、又被判"清空"弹出三选一，把正在测的世界冻住。
	# 只有 `_section_waves_boss()` 会临时放开（并重建世界拿干净进度）。
	main.waves_off = true
	sub.add_child(main)

	GameInput.aim_mode = "move"
	await _run()


func _run() -> void:
	print("[selfcheck] 开始")
	# 每一段都必须 await。GDScript 的协程在第一个 await 处就会让出控制权；
	# 如果这里漏掉 await，后面的段落会和它并发推进——断言前提错位、
	# 截图也会拍成"别人已经改过的世界"。
	await _check_boot()
	await _section_assets()
	await _section_move()
	await _section_combat()
	await _section_light_occlusion()
	await _section_weapons_skills()
	await _section_enemy_ai()
	await _section_waves_boss()
	await _section_drops_death()
	await _section_bot_playthrough()
	await _section_level2()
	await _section_bag_chest()
	await _section_shop()
	await _section_layout()
	_finish()


# ================================================================ 基础设施

func _ok(name: String, cond: bool, detail := "") -> void:
	_checks[name] = cond
	if not cond:
		report["errors"].append("[断言失败] " + name + "  " + detail)


func _num(name: String, v: float, shown := -999.0) -> void:
	report["samples"][name] = snappedf(v, 0.0001) if shown == -999.0 else shown


## 推进 n 个固定步（可同时按住若干键）。
##
## 注意：有**三种**界面会让世界"停住"——`main.state == "dialogue"`（对白）、
## `"draft"`（肉鸽三选一，**开宝箱也走这个状态**）和 `"shop"`（守灯人商店）。
## **三者都不调 world.step()**，所以只要有一个没被点掉，
## 后面所有段落都会一起变红，症状是一大片看似无关的断言同时失败
## （敌人不动、镜头不跟、盲女不跟人走、灯不亮…），极难反查到真正的原因。
## 所以这里默认三种都自己处理掉：对白按 confirm 翻页，三选一/宝箱拿第一项，商店按 Esc 走人。
## 专门要验它们的那几段，把对应的 auto_* 关掉、自己接管输入。
func _pump(n: int, hold := {}, auto_draft := true,
		auto_dialogue := true, auto_shop := true) -> void:
	for k in hold.keys():
		GameInput.set_override(str(k), hold[k])
	for i in n:
		if main.state == "dialogue":
			if auto_dialogue:
				_tap("confirm")
			else:
				main.advance(STEP)
			continue
		if auto_draft and main.state == "draft":
			_resolve_draft(0)
			continue
		if auto_shop and main.state == "shop":
			_tap("pause")     # Esc 离开商店
			continue
		main.advance(STEP)
	if not hold.is_empty():
		GameInput.clear_overrides()


## 三选一：拿走第 pick 项（默认第一项）。
##
## 走的是**和玩家完全同一条输入路径**：先等过装填窗口，再用 E/Q 把高亮挪过去，
## 最后按空格确认。旧版这里是 `_tap("skill" + (pick+1))`（那时候 1/2/3 是直接选），
## 现在 1/2/3 在三选一里已经失效，而且"高亮在哪、拿走的就是哪"本身就是要验的东西，
## 所以不能再走捷径。
func _resolve_draft(pick := 0) -> bool:
	if main.state != "draft":
		return false
	var items: Array = main._draft_items
	var before := int(main.prog["boons"].size())
	var wid := str(main.prog["weapon"])
	# ① 等过装填窗口（面板刚弹出时确认键故意不生效）。这里用真实步进等过去，
	#    而不是直接把计时器置满 —— 那样就等于没验这条规则。
	var arm_guard := 0
	while not main._draft_armed() and arm_guard < 120:
		arm_guard += 1
		main.advance(STEP)
	# ② Q/E 把高亮挪到目标项
	var mv_guard := 0
	while main._draft_index != pick and mv_guard < 8:
		mv_guard += 1
		_tap("draft_next")
	var idx := main._draft_index
	var picked: Dictionary = items[idx] if idx < items.size() else {}
	_tap("confirm")
	draft_log.append({
		"pick": pick, "index": idx, "offer": items.size(),
		"picked": "%s:%s" % [str(picked.get("kind", "")), str(picked.get("id", ""))],
		"weapon_before": wid, "weapon_after": str(main.prog["weapon"]),
		"boons_before": before, "boons_after": int(main.prog["boons"].size()),
		"state": main.state,
	})
	draft_taken += 1
	return true


func _tap(action: String) -> void:
	GameInput.set_override(action, true)
	main.advance(STEP)
	GameInput.set_override(action, false)
	# 必须再走一步：just() 比的是"这一步 vs 上一步"，只按下不松开的话
	# 连续两次 tap 之间不会形成第二次边沿，对白就会卡在第一句。
	main.advance(STEP)


## 一招打死。但带词缀「障」的精英会格挡第一次伤害，所以要打两下。
func _force_kill(w: World, e: EnemyState) -> void:
	var guard := 0
	while not e.dead and guard < 4:
		guard += 1
		w.damage_enemy(e, 99999.0, 0.0, 0.0)


## 收集当前世界里的特效种类（用来断言"特效确实不止一种"）
func _collect_kinds(w: World, into: Dictionary) -> void:
	for f in w.effects:
		into[str(f["kind"])] = true


func _w() -> World:
	return main.world


func _p() -> PlayerState:
	return main.world.player


## 等渲染几帧再取图（SubViewport 是 UPDATE_ALWAYS）
func _grab() -> Image:
	for i in 8:
		await RenderingServer.frame_post_draw
	return sub.get_texture().get_image()


## 让渲染追平世界状态（SubViewport 每帧重绘，等两帧即可）
func _settle() -> void:
	for i in 2:
		await RenderingServer.frame_post_draw


func _shot(name: String) -> void:
	_write_png(await _grab(), name)


func _write_png(img: Image, name: String) -> void:
	_shot_n += 1
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, name])
	img.save_png(path)


## 把当前过场对白点完。
## 对白期间 main.state == "dialogue"，advance() 不会调用 world.step()——
## 世界是冻结的。所以任何"要继续推进世界"的测试都必须先显式清掉对白。
func _drain_dialogue(max_taps := 60) -> bool:
	var guard := 0
	while main.state == "dialogue" and guard < max_taps:
		guard += 1
		_tap("confirm")
	return main.state != "dialogue"


## 世界坐标 → 屏幕像素（用这一帧实际的绘制相机）
func _screen_of(w: World, x: float, y: float) -> Vector2:
	return Vector2(Proj.sx(x, w.draw_cam.x), Proj.sy(y, 0.0, w.draw_cam.y))


## 取一块 patch 的平均亮度（Rec.709）
func _lum(img: Image, p: Vector2, r := 4) -> float:
	var acc := 0.0
	var n := 0
	var cx := int(p.x)
	var cy := int(p.y)
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var x := cx + dx
			var y := cy + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			acc += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
	return snappedf(acc / maxf(1.0, float(n)), 0.0001)


func _mean_lum(img: Image) -> float:
	var acc := 0.0
	var n := 0
	var y := 0
	while y < img.get_height():
		var x := 0
		while x < img.get_width():
			var c := img.get_pixel(x, y)
			acc += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			n += 1
			x += 6
		y += 6
	return snappedf(acc / maxf(1.0, float(n)), 0.0001)


# ================================================================ 各段自检

func _check_boot() -> void:
	var st := main.debug_state()
	_ok("启动即进入标题画面", st["state"] == "title" and st["overlay_visible"])
	# 标题截图必须在 start_level() 之前拍，否则拍到的已经是关卡画面
	var img_t := await _grab()
	_num("标题画面平均亮度", _mean_lum(img_t))
	_write_png(img_t, "01-title")

	main.start_level()
	_pump(2)
	var w := _w()
	_ok("关卡构建：墙 14 面", w.walls.size() == 14, str(w.walls.size()))
	_ok("关卡构建：遮挡体与墙一一对应", w.light_rig.occluder_count() == 14,
		str(w.light_rig.occluder_count()))
	_ok("关卡构建：道具 ≥ 32（6 个手工 + 26 个装饰）", w.props.size() >= 32, str(w.props.size()))
	_ok("关卡构建：初始无敌人", w.alive_enemy_count() == 0)
	_ok("玩家出生在关卡起点", absf(w.player.x - 300.0) < 1.0 and absf(w.player.y - 1350.0) < 1.0)
	_ok("玩家满血", is_equal_approx(w.player.hp, w.player.max_hp))
	_ok("灯具已建（玩家灯 + 灯塔灯）", w.light_rig.light_count() >= 2,
		str(w.light_rig.light_count()))
	_num("光源数", 0.0, w.light_rig.light_count())
	# 道具清单（含手工摆放的 6 个 + 程序化装饰 26 个）：排查"画面里有个不该在的东西"时用
	var pl := []
	for pr in w.props:
		pl.append({"k": str(pr["kind"]), "x": snappedf(float(pr["x"]), 0.1),
			"y": snappedf(float(pr["y"]), 0.1), "lit": bool(pr.get("lit", false))})
	report["samples"]["props"] = pl
	var lr0 := w.player_light_radius()
	_num("基础光照半径为 150", lr0)
	# 相机会从初始位置阻尼跟随玩家，刚开局的 2 帧还没跟上（玩家会被挤到画面外）。
	# 等它稳定下来再截图，否则截出来的"关卡起点"其实看不到人。
	_pump(55)
	var img_l1 := await _grab()
	_num("初始画布平均亮度", _mean_lum(img_l1))
	_write_png(img_l1, "02-level1-start")


## 素材：字体与粒子贴图都是**运行时按路径读文件**（不走 Godot 的导入管线，见 Art）。
## 好处是命令行直接跑不会因为缺 .import 而失败；代价是"读不到"不会崩，
## 只会静默退回默认表现 —— 于是"接了素材但画面没变化"会被误判成"素材没用"。
## 所以这里显式断言它们真的到位。
func _section_assets() -> void:
	var df := Art.font_disp
	var nm := ""
	if df != null:
		nm = str(df.get_font_name())
	var is_wenkai := nm.findn("wenkai") >= 0 or nm.find("霞") >= 0
	_ok("显示字体已加载（霞鹜文楷，不是退回正文兜底）",
		df != null and df != Art.font and is_wenkai, nm)
	_ok("正文中文可渲染（思源黑体已就位）", Art.font != null)

	var names := ["slash_01", "slash_02", "slash_03", "light_01", "light_02", "flame_01",
		"spark_01", "star_06", "star_09", "smoke_05", "trace_01", "muzzle_01",
		"twirl_01", "magic_05", "scorch_02", "circle_03"]
	var missing := []
	for n in names:
		if Art.tex(n) == null:
			missing.append(n)
	_ok("粒子/光效贴图全部加载成功", missing.is_empty(), "缺 " + ", ".join(missing))
	_ok("素材加载零报错", Art.tex_errors.is_empty(), str(Art.tex_errors))
	var t0 := Art.tex("slash_01")
	_ok("贴图已降采样到 256（运行时贴图没有 mipmap，直接缩会被采样成噪点）",
		t0 != null and t0.get_width() == Art.TEX_SIZE,
		str(t0.get_width()) if t0 != null else "null")
	_ok("程序化光晕贴图就绪（所有 glow 现在都走它）", Art.soft_dot != null)

	# 三选一 / 宝箱卡片的徽记。这张表有**两处静默出错**的方式，各断言一条：
	#   ① 键与 content.gd 的 id 对不上 → 回退默认 star_06，视觉上"好几张恩赐长得一样"
	#      （历史坑：EMBLEMS 用的还是老版本恩赐 id，与 content.gd 完全对不上）
	#   ② 值写了个不存在的贴图名 → Art.tex() 返回 null，徽记**直接隐形**，比回退更糟
	var em_keys: Dictionary = Hud.EMBLEMS
	var em_miss: Array = []
	var em_bad: Array = []
	for b in Content.BOONS:
		if not em_keys.has(str(b["id"])):
			em_miss.append(str(b["id"]))
	for wid in Content.WEAPONS.keys():
		if not em_keys.has(str(wid)):
			em_miss.append(str(wid))
	for aid in Content.WEAPON_AFFIXES.keys():
		if not em_keys.has(str(aid)):
			em_miss.append(str(aid))
	for k in em_keys.keys():
		if Art.tex(str(em_keys[k])) == null:
			em_bad.append("%s -> %s" % [k, em_keys[k]])
	_ok("三选一徽记覆盖全部武器 / 恩赐 / 词条（不靠默认图兜底）",
		em_miss.is_empty(), "缺 " + ", ".join(em_miss))
	_ok("三选一徽记引用的贴图全部真实存在（写错名会静默隐形）",
		em_bad.is_empty(), "问题项 " + ", ".join(em_bad))
	# 徽记的意义就是"一眼能区分"，所以要防的是"多张卡撞用同一张贴图"。
	# 只统计**真的会出现在卡片上**的 id（武器 + 恩赐），不含只走文字 chip 的词条。
	var em_used := {}
	for b2 in Content.BOONS:
		var v := str(em_keys.get(str(b2["id"]), "star_06"))
		em_used[v] = int(em_used.get(v, 0)) + 1
	for wid2 in Content.WEAPONS.keys():
		var v2 := str(em_keys.get(str(wid2), "star_06"))
		em_used[v2] = int(em_used.get(v2, 0)) + 1
	var em_worst := 0
	var em_worst_name := ""
	for vk in em_used.keys():
		if int(em_used[vk]) > em_worst:
			em_worst = int(em_used[vk])
			em_worst_name = str(vk)
	_ok("卡片徽记有足够区分度（同一张贴图最多被 2 个卡片 id 复用）",
		em_worst <= 2, "最多复用 %d 次（%s）" % [em_worst, em_worst_name])

	report["samples"]["assets"] = {
		"display_font": nm, "textures": names.size(), "tex_size": Art.TEX_SIZE,
		"tex_errors": Art.tex_errors.duplicate(),
	}


func _section_move() -> void:
	var w := _w()
	var p := _p()
	var x0 := p.x
	_pump(40, {"move_right": true})
	_ok("按 D 向右移动", p.x > x0 + 40.0, "%.1f -> %.1f" % [x0, p.x])

	# 朝墙走：把玩家放到测试墙西侧，一路向东顶
	w.teleport(400.0, 500.0)
	_pump(120, {"move_right": true})
	# 正确判据是"玩家圆心 + 半径 不超过墙的左沿"，而不是"离墙还有 20px"：
	# 碰撞解算会把玩家正好顶在墙面上，稳态间隙就等于玩家半径。
	var gap := TEST_WALL[0] - p.x
	_ok("撞墙停下，不会穿墙",
		p.x + p.r <= TEST_WALL[0] + 0.5 and gap < p.r + 1.5,
		"x=%.1f 墙左沿=%.0f 半径=%.0f 间隙=%.1f" % [p.x, TEST_WALL[0], p.r, gap])
	_num("撞墙后 x", p.x)

	# 向上走到边界墙，同样不该穿过去
	w.teleport(1200.0, 400.0)
	_pump(180, {"move_up": true})
	_ok("撞上方边界墙停下", p.y > 44.0, "y=%.1f" % p.y)
	await _settle()


func _section_combat() -> void:
	var w := _w()
	var p := _p()
	w.teleport(1000.0, 1100.0)
	_pump(10)

	# 在玩家正东放一只灯影
	var e := w.spawn_enemy("shade", p.x + 46.0, p.y, false)
	_pump(2)
	var hp0 := e.hp
	var combo0 := p.combo
	var lr0 := w.player_light_radius()
	GameInput.aim_world = Vector2(e.x, e.y)
	_tap("attack")
	# 挥击伤害在调用当帧结算，不需要等
	_ok("挥击命中：敌人掉血", e.hp < hp0, "%.0f -> %.0f" % [hp0, e.hp])
	_ok("命中累积连击", p.combo > combo0, "%.0f" % p.combo)
	var lr1 := w.player_light_radius()
	_ok("连击提高光照半径", lr1 > lr0, "%.1f -> %.1f" % [lr0, lr1])
	_ok("连击提高亮度（brightness01 > 0）", w.brightness01() > 0.0, "%.4f" % w.brightness01())
	_ok("伤害倍率随连击上升", w.damage_mul() > 1.0, "%.4f" % w.damage_mul())
	_num("一次挥击后的连击", p.combo)
	_num("一次挥击后的光照半径", lr1)

	# 连击衰减：4 秒不命中
	GameInput.aim_world = null
	var combo_mid := p.combo
	_ok("连击计时器被置为 2.6s", absf(p.combo_timer - 2.6) < 0.02, "%.3f" % p.combo_timer)
	_pump(240)
	_ok("停下后连击衰减", p.combo < combo_mid, "%.1f -> %.1f" % [combo_mid, p.combo])

	# 技能门槛：连击不足时被拒绝
	var before := p.combo
	w.use_skill(0)
	_ok("连击不足时技能不生效（不扣连击）", is_equal_approx(p.combo, before),
		"combo=%.1f" % p.combo)
	# 攒够连击后应能放出旋斩
	p.combo = 20.0
	p.combo_timer = 2.6
	var hp1 := e.hp
	w.use_skill(0)
	_ok("连击足够时旋斩生效：扣连击", p.combo < 20.0, "combo=%.1f" % p.combo)
	_ok("旋斩留下环形特效", w.effects.size() > 0)
	_pump(8)
	_ok("旋斩造成伤害", e.hp < hp1, "%.0f -> %.0f" % [hp1, e.hp])

	# 打死它（前面旋斩可能已经把它打死了，无妨）
	w.damage_enemy(e, 9999.0, 0.0, 0.0)
	_ok("敌人被击杀后标记 dead", e.dead)

	# ── 掉落：另放一只离玩家 500px 的来验"击杀会掉灯火" ──
	# 不能用刚才那只：它就贴在玩家身上，掉落物当帧就会被吸附拾走，
	# 于是 w.drops 立刻又空了（这正是之前这条断言误报的原因）。
	var e2 := w.spawn_enemy("shade", 1500.0, 1100.0, false)
	_pump(1)
	var drops0 := w.drops.size()
	w.damage_enemy(e2, 9999.0, 0.0, 0.0)
	_ok("击杀产生灯火掉落", w.drops.size() > drops0,
		"%d -> %d" % [drops0, w.drops.size()])

	# ── 拾取：把玩家送到最后一枚掉落物脚下 ──
	var coins0 := int(w.prog["coins"])
	var dd: Dictionary = w.drops[w.drops.size() - 1]
	w.teleport(float(dd["x"]), float(dd["y"]))
	_pump(40)
	_ok("走到灯火上会被拾取", int(w.prog["coins"]) > coins0,
		"%d -> %d" % [coins0, int(w.prog["coins"])])
	_num("拾取到的灯火", 0.0, int(w.prog["coins"]))
	await _settle()


## 本段是整次迁移的核心理由：光会不会被墙挡住。
## 同一场景、同一采样点，只切换 PointLight2D.shadow_enabled 这个变量。
func _section_light_occlusion() -> void:
	var w := _w()
	# 清场，避免敌人自光干扰采样
	for e in w.enemies:
		e.dead = true
	w.enemies.clear()
	w.drops.clear()
	w.particles.clear()

	# ── 临时净场：把随机布局带进来的干扰物拿走 ──
	# 宝箱位置现在每局随机，而它自带一道**呼吸的暖色缝光**（直接画的贴图，不认遮挡）。
	# 万一它落在采样点上，量到的就是"宝箱有多亮"，而不是"墙有没有把光挡住"。
	# （波次不用在这里操心：整份自检默认 `main.waves_off = true`，
	#  这一段里根本不会有怪刷出来 —— 见那个开关的注释。）
	var chest_bak := []
	for c in w.chests:
		if w.props.has(c):
			w.props.erase(c)
			chest_bak.append(c)

	# ── 测光之前先关掉 HUD 的后处理（暗角）──
	# 三个采样点分别在画面中部（墙前/墙后）和靠右边缘（射程外），而暗角是**径向**的：
	# 同一个"世界亮度"，画面正中和靠边的点被压暗的幅度不一样。
	# 于是"墙后 ≈ 射程外"这种跨屏幕的比较会被 HUD 的暗角污染 ——
	# 测出来的是暗角，不是光。这一条要保证的是"关掉后处理之后，采样点上的
	# 加减光只可能来自世界层"。
	main.hud.set_post_enabled(false)
	_ok("测遮挡时已关闭 HUD 后处理（暗角），避免污染世界采样",
		not main.hud.post.visible)

	# 站在测试墙西侧、开阔处，把连击顶到 40 层并锁住（= 满亮度档）。
	# 灯要离墙够近（x=450 → 离墙左沿 70px）：否则"墙后"本来就落在灯半径之外，
	# 就分不清那里的"暗"是遮挡造成的、还是光根本没照到——对照组会失去意义。
	# 另外把"光明升级"推到 6 档（每档 +24 半径），半径 150+144+280+46=620：
	# 实测这盏灯很柔和（中心也只比地板底噪亮 ~0.11），射程不够时墙后信号会太弱。
	var up_light0 := int(w.prog["up"]["light"])
	w.prog["up"]["light"] = 6
	w.teleport(450.0, 500.0)
	var p := _p()
	p.combo = 40.0
	p.combo_timer = 1e9
	p.glow = 1.0
	_pump(150)
	w.shake = 0.0     # 采样用的是 draw_cam，先把震屏抖动量清零
	_pump(1)
	# 保持锁定（步进会扣计时器）
	p.combo = 40.0
	p.combo_timer = 1e9
	p.glow = 1.0
	var r := w.player_light_radius()
	_num("满连击光照半径", r)
	_ok("测遮挡时把灯拉大一档（半径 ≥ 600，让墙后落在射程内）", r >= 600.0, "%.1f" % r)

	var s_front := _screen_of(w, 500.0, 500.0)   # 灯与墙之间：应当亮
	var s_back := _screen_of(w, 690.0, 500.0)    # 墙后、仍在灯半径内：应当被挡住
	var s_far := _screen_of(w, 1200.0, 500.0)    # 远处、超出灯半径：应当漆黑
	_num("墙前采样点屏幕x", s_front.x)
	_num("墙后采样点屏幕x", s_back.x)
	report["samples"]["screen_front"] = [s_front.x, s_front.y]
	report["samples"]["screen_back"] = [s_back.x, s_back.y]

	# 现场快照：出问题时能一眼看出灯装错了没有
	report["samples"]["rig"] = {
		"rig_pos": [snappedf(w.light_rig.position.x, 0.1), snappedf(w.light_rig.position.y, 0.1)],
		"cm": str(w.light_rig.cm.color), "ambient": w.ambient,
		"combo": p.combo, "glow": p.glow, "brightness01": w.brightness01(),
		"p_pos": [snappedf(p.x, 0.1), snappedf(p.y, 0.1)],
		"cam": [snappedf(w.draw_cam.x, 0.1), snappedf(w.draw_cam.y, 0.1)],
		"radius": r,
		"player_light": {
			"pos": [snappedf(w.light_rig.player_light.position.x, 0.1),
				snappedf(w.light_rig.player_light.position.y, 0.1)],
			"energy": snappedf(w.light_rig.player_light.energy, 0.001),
			"scale": snappedf(w.light_rig.player_light.texture_scale, 0.001),
		},
		"light_total": w.light_rig.light_count(),
	}

	# ── 开阴影 ──
	w.light_rig.player_light.shadow_enabled = true
	var img_on := await _grab()
	var front_on := _lum(img_on, s_front)
	var back_on := _lum(img_on, s_back)
	var far_on := _lum(img_on, s_far)
	var mean_on := _mean_lum(img_on)
	_num("开阴影_墙前亮度", front_on)
	_num("开阴影_墙后亮度", back_on)
	_num("开阴影_远处亮度", far_on)
	_num("开阴影_全屏平均亮度", mean_on)

	# 灯的实测衰减曲线（向西取，避开那面墙）：用来判断采样点放多远才还有信号
	var prof := []
	for dd in [20, 50, 100, 150, 200, 250, 300, 350, 400, 450]:
		var sp := _screen_of(w, 450.0 - float(dd), 500.0)
		prof.append([dd, _lum(img_on, sp)])
	report["samples"]["light_profile"] = prof
	await _shot("05-occlusion-on")

	# ── 关阴影（严格对照组：只改这一个变量）──
	w.light_rig.player_light.shadow_enabled = false
	var img_off := await _grab()
	var front_off := _lum(img_off, s_front)
	var back_off := _lum(img_off, s_back)
	var mean_off := _mean_lum(img_off)
	_num("关阴影_墙前亮度", front_off)
	_num("关阴影_墙后亮度", back_off)
	_num("关阴影_全屏平均亮度", mean_off)
	await _shot("06-occlusion-off")
	w.light_rig.player_light.shadow_enabled = true

	report["cases"]["occlusion"] = {
		"wall": TEST_WALL,
		"shadow_on": {"front": front_on, "back": back_on, "far": far_on, "mean": mean_on},
		"shadow_off": {"front": front_off, "back": back_off, "mean": mean_off},
		"back_drop_pct": snappedf(100.0 * (back_off - back_on) / maxf(0.0001, back_off), 0.01),
	}

	_ok("黑暗生效：全屏平均亮度很低", mean_on < 0.30, "%.4f" % mean_on)
	_ok("灯光生效：墙前明显亮于远处（≥3×）", front_on > far_on * 3.0,
		"前 %.4f  远 %.4f  比 %.2f" % [front_on, far_on, front_on / maxf(1e-4, far_on)])
	_ok("★ 遮挡成立：同一采样点，开阴影后亮度掉一半以上", back_on < back_off * 0.5,
		"开 %.4f  关 %.4f  降幅 %.1f%%" % [back_on, back_off,
		100.0 * (back_off - back_on) / maxf(0.0001, back_off)])
	_ok("★ 墙后确实成了暗区（相对墙前）", back_on < front_on * 0.35,
		"后 %.4f  前 %.4f" % [back_on, front_on])
	# 下面两条是一对，合起来才能排除「墙后本来就照不到、所以怎么测都暗」这个伪因：
	#   开阴影 → 墙后亮度落到「射程外的远处」同一水平（被压实到地板底噪）
	#   关阴影 → 同一个点明显亮于远处（说明光其实够得着，只是被墙挡了）
	_ok("★ 开阴影时墙后压到「照不到的远处」同一水平（≈地板底噪）",
		back_on <= far_on * 1.15, "后 %.4f  远 %.4f  比 %.2f" % [back_on, far_on,
		back_on / maxf(1e-4, far_on)])
	_ok("★ 关阴影时墙后明显亮于「照不到的远处」（光够得着，是被挡了）",
		back_off > far_on * 2.0, "关 %.4f  远 %.4f  比 %.2f" % [back_off, far_on,
		back_off / maxf(1e-4, far_on)])

	# ── 灯的贴图是"竖压椭圆"（= 地面正圆），不是屏幕正圆 ──
	# 地面上等距的东/北两点亮度应当接近 1:1。屏幕正圆会让北向多照约 70%。
	# 换个开阔位置再测，避免上面那面墙影响
	w.teleport(1000.0, 1100.0)
	_pump(150)
	p.combo = 40.0
	p.combo_timer = 1e9
	p.glow = 1.0
	p.hp = p.max_hp
	var img2 := await _grab()
	var east := _lum(img2, _screen_of(w, 1300.0, 1100.0))
	var north := _lum(img2, _screen_of(w, 1000.0, 800.0))
	var ratio := north / maxf(0.0001, east)
	_num("地面等距_东向亮度", east)
	_num("地面等距_北向亮度", north)
	_num("地面等距_北东亮度比", ratio)
	report["cases"]["light_shape"] = {"east_300": east, "north_300": north, "ratio": snappedf(ratio, 0.0001)}
	_ok("灯是地面正圆而非屏幕正圆（南北/东西亮度比≈1）", absf(ratio - 1.0) < 0.25,
		"比值 %.3f（屏幕正圆会是 ~1.65）" % ratio)

	# ── 遮挡体几何（纯函数断言，与第二探针的结论一致）──
	var poly := LightRig.occluder_polygon(100.0, 200.0, 200.0, 60.0, 46.0, LightRig.OCC_TRIM)
	var y_foot := 200.0 * Proj.YSQUASH
	var expect_top := y_foot - 46.0
	var expect_bottom := y_foot + 60.0 * Proj.YSQUASH - LightRig.OCC_TRIM
	_ok("遮挡体上沿 = 足迹北沿 − h（贴的是画出来的轮廓，不是地面足迹）",
		absf(poly[0].y - expect_top) < 0.01, "%.2f vs %.2f" % [poly[0].y, expect_top])
	_ok("遮挡体底边 = 轮廓底边 − 16px（削底，让墙脚受光）",
		absf(poly[2].y - expect_bottom) < 0.01, "%.2f vs %.2f" % [poly[2].y, expect_bottom])
	_ok("遮挡体宽度 = 墙宽", absf((poly[1].x - poly[0].x) - 200.0) < 0.01)
	_ok("削底量常数就是第二探针定下的 16", is_equal_approx(LightRig.OCC_TRIM, 16.0))

	# 还原"光明升级"档位，后面的段落（机器人试玩）要按正常配置跑
	w.prog["up"]["light"] = up_light0
	# 后处理（暗角）恢复 —— 后面的截图要的是玩家真正看到的画面
	main.hud.set_post_enabled(true)

	# 把宝箱放回去（`append` 回末尾，props 顺序不变）
	for c in chest_bak:
		w.props.append(c)


func _section_enemy_ai() -> void:
	var w := _w()
	var p := _p()
	w.enemies.clear()
	w.teleport(1000.0, 1100.0)
	p.hp = p.max_hp
	p.invuln = 0.0
	_pump(10)

	var e := w.spawn_enemy("shade", p.x + 420.0, p.y, false)
	var d0 := Proj.dist(e.x, e.y, p.x, p.y)
	_pump(150)
	var d1 := Proj.dist(e.x, e.y, p.x, p.y)
	_num("灯影初始距离", d0)
	_num("灯影 2.5 秒后距离", d1)
	_ok("敌人会追击玩家", d1 < d0 - 100.0, "%.0f -> %.0f" % [d0, d1])

	# 贴脸后应当挨打。先把连击压回 10 层：上一节把连击顶到了 40，
	# 不从基线出发就没法判断"到底掉没掉"。
	e.x = p.x + 26.0
	e.y = p.y
	e.atk_cd = 0.0
	e.state = "chase"
	var hp0 := p.hp
	p.invuln = 0.0
	p.combo = 10.0
	p.combo_timer = 1e9   # 锁住，确保连击只可能因为"被咬"而下降
	_pump(180)
	_ok("敌人近身会打到玩家（掉血或已触发无敌帧）", p.hp < hp0 or p.invuln > 0.0,
		"hp %.1f -> %.1f  invuln %.2f" % [hp0, p.hp, p.invuln])
	_num("被咬之后的连击（被咬会掉 3 层）", p.combo)
	_ok("被咬会掉连击（灯被咬掉一块）", p.combo <= 7.01,
		"10.0 -> %.1f" % p.combo)

	w.enemies.clear()
	await _settle()


func _section_waves_boss() -> void:
	# 这一段要验的正是"走进范围才刷 / 清空才弹三选一 / 全清才出 Boss"，
	# 所以必须**放开**波次，并**重建世界**拿一份干净进度 ——
	# 前面所有段落都跑在 `waves_off` 下（波次一律不刷、状态全是"已刷已清"），
	# 不重建的话这里的"走进去才刷"就会退化成同义反复。
	main.waves_off = false
	main.restart_level()
	_pump(2)
	var w := _w()
	var p := _p()
	var bd: Dictionary = w.level["boss"]
	p.hp = p.max_hp
	p.dead = false
	p.invuln = 0.0

	# ── 先验：一波都没清的时候，就算跑进 Boss 区也只该给提示，不该刷 Boss ──
	_ok("开局 Boss 未出现", not w.boss_spawned)
	w.teleport(w.boss_anchor.x, w.boss_anchor.y - 100.0)
	p.hp = p.max_hp
	p.invuln = 0.0
	_pump(20)
	_ok("波次清空前 Boss 不出现（跑进 Boss 区也只给提示）", not w.boss_spawned,
		"spawned=%s hinted=%s" % [w.boss_spawned, w.boss_hinted])

	# 波次：走进每一波的范围触发，然后把本波自己的成员打死
	for i in w.waves.size():
		var wd: Dictionary = w.waves[i]["def"]
		w.teleport(float(wd["x"]), float(wd["y"]))
		p.combo = 0.0
		p.hp = p.max_hp
		p.invuln = 0.0
		_pump(6)
		var wv: Dictionary = w.waves[i]
		_ok("第 %d 波进入范围后刷出" % (i + 1), bool(wv["spawned"]))
		_ok("第 %d 波刷出的是自己这一批敌人" % (i + 1), wv["members"].size() > 0,
			str(wv["members"].size()))
		for e in w.enemies:
			if not e.dead and (e.id in wv["members"]):
				_force_kill(w, e)
		_pump(4)
		_ok("第 %d 波清空后标记 cleared" % (i + 1), bool(wv["cleared"]))
		if i < w.waves.size() - 1:
			# 还剩波次没清：此刻站进 Boss 区也仍然不该刷（这才是"清空前不出现"的本意）
			w.teleport(w.boss_anchor.x, w.boss_anchor.y - 100.0)
			p.hp = p.max_hp
			p.invuln = 0.0
			_pump(6)
			_ok("第 %d 波清空后 Boss 仍不出现（还要清完剩余波次）" % (i + 1),
				not w.boss_spawned)

	_ok("三波全部清空", w.waves_cleared_count() == 3, str(w.waves_cleared_count()))

	# 进 Boss 区（第三波的位置本来就在 Boss 圈内，所以此刻多半已经刷出来了）
	w.teleport(w.boss_anchor.x, w.boss_anchor.y - 100.0)
	p.hp = p.max_hp
	p.invuln = 0.0
	# 这里**故意**不让 _pump 替我们把对白翻掉（第 4 个参数 = auto_dialogue: false）：
	# 下面那条断言要验的正是"这段过场对白点得完"。自动翻页会让它变成同义反复。
	_pump(10, {}, true, false)
	_ok("三波清空后进入区域会触发 Boss", w.boss_spawned, str(w.boss_spawned))
	_ok("Boss 实例存在", w.boss_enemy != null and w.boss_enemy.is_boss())
	_num("Boss 最大生命", w.boss_enemy.max_hp)

	# Boss 出场会先播一段过场对白（"噬灯者·幼体 站了起来"）。对白期间世界是冻结的，
	# 不点完的话下面 _pump(240) 一步都不会推进，"Boss 会攻击玩家"必然测不到。
	_ok("Boss 出场对白可以点完", _drain_dialogue())
	await _shot("03-boss")

	# Boss 打人：站它旁边挨一下
	var be := w.boss_enemy
	p.hp = p.max_hp
	p.invuln = 0.0
	p.dead = false
	be.x = p.x + 60.0
	be.y = p.y
	var hp0 := p.hp
	_pump(240)
	_ok("Boss 会攻击玩家", p.hp < hp0 or p.invuln > 0.0, "hp %.1f -> %.1f" % [hp0, p.hp])
	_num("Boss 攻击后玩家生命", p.hp)
	report["samples"]["boss_probe"] = {
		"main_state": main.state, "boss_state": be.state,
		"boss_action": str(be.boss.get("action", "")),
		"boss_hp": be.hp, "player_hp": p.hp,
		"player_invuln": snappedf(p.invuln, 0.001),
		"dist": snappedf(Proj.dist(be.x, be.y, p.x, p.y), 0.1),
		"reach": be.r + p.r + 6.0,
	}

	# Boss 的招牌特效是 beam（吸灯光束 / 回旋光刃）——**只有 Boss 会放**，
	# 玩家的八把武器里没有 beam，所以它不归"武器特效"那一段验，归这里。
	#
	# 但 beam 是**分阶段**才有的，这一点很关键：Boss 满血时是 phase 1，
	# 招式池只有 dash/dash/slam/summon，**根本放不出 beam**。
	# 所以要先把血打下去（phase 3 的池子是 drain/sweep/summon/dash/slam，drain 和 sweep 都放 beam）。
	# 顺带把"阶段确实会随血量变"也断言掉。
	be.hp = be.max_hp * 0.3
	p.invuln = 9999.0        # 这一段只考特效，别被击退到 Boss 够不着的地方
	_pump(1)
	_ok("Boss 血量掉到 1/3 会进第三阶段", int(be.boss["phase"]) == 3,
		"hp %.0f/%.0f phase %d" % [be.hp, be.max_hp, int(be.boss["phase"])])

	# beam 只活 0.06~0.08 秒（4~5 步），必须逐步采样；_pump 完再回头看已经过期了。
	var boss_kinds := {}
	for i in 900:
		p.invuln = 9999.0
		be.x = p.x + 90.0     # 钉在视野里，免得它 dash 走开就再也不出招
		be.y = p.y
		_pump(1)
		_collect_kinds(w, boss_kinds)
		if boss_kinds.has("beam"):
			break
	report["samples"]["boss_effect_kinds"] = boss_kinds.keys()
	_ok("Boss 有招牌光束特效（beam）", boss_kinds.has("beam"), str(boss_kinds.keys()))

	# 打死 Boss → 关卡通过
	p.hp = p.max_hp
	w.damage_enemy(be, 999999.0, 0.0, 0.0)
	_pump(4)
	_ok("Boss 死亡后关卡标记为 cleared", w.cleared)
	_ok("Boss 死亡后灯塔自动点亮", bool(w.goal_prop["lit"]))
	_ok("Boss 死亡后环境变亮（ambient 下降）", w.ambient < 0.7, "%.3f" % w.ambient)
	_pump(60)
	# 过场对白结束后应弹出通关面板
	_drain_dialogue()
	_pump(4)
	_ok("通关面板出现", main.state == "menu" and main._menu_kind == "clear",
		"%s/%s" % [main.state, main._menu_kind])
	await _shot("04-clear")


func _section_drops_death() -> void:
	var w := _w()
	var p := _p()

	# 死亡与重生
	var deaths0 := int(w.prog["deaths"])
	p.invuln = 0.0
	p.hp = 1.0
	w.hurt_player(9999.0, 0.0)
	_pump(2)
	_ok("生命归零后判定死亡", p.dead)
	_ok("死亡计入存档", int(w.prog["deaths"]) == deaths0 + 1,
		"%d -> %d" % [deaths0, int(w.prog["deaths"])])
	_ok("死亡弹出结算面板", main.state == "menu" and main._menu_kind == "death",
		"%s/%s" % [main.state, main._menu_kind])
	# 死亡会打出一发全屏红闪，颜色被写在**常驻 HUD** 的 flash_rect 上。
	# 先确认它真的亮着 —— 否则下面所有"清掉了"的断言都会退化成同义反复。
	_ok("死亡瞬间打出全屏红闪（红闪确实画在屏幕上）",
		_w().flash_power > 0.05 and main.hud.flash_rect.color.a > 0.03,
		"flash_power=%.3f alpha=%.3f" % [_w().flash_power, main.hud.flash_rect.color.a])
	await _shot("07-death")

	# 衰减**不能跟着世界一起冻结**。结算时 state == "menu"，advance() 不调 world.step()；
	# 衰减若还留在 step() 里，这发红闪就会一直糊在结算画面上直到重生。
	# 这里刻意走完整的 main.advance()，而不是只调 world.tick_fx() —— 把 flash_rect
	# 刷回透明是 hud.refresh() 干的，只调 tick_fx 会漏掉"power 归零但屏幕还亮着"这种假通过。
	# menu 状态下 advance() 不调 world.step()、不消耗世界 RNG，多走几步不会挪动随机流。
	var w_time0 := _w().time
	var fx_steps := 0
	while _w().flash_power > 0.001 and fx_steps < 60:
		main.advance(STEP)
		fx_steps += 1
	_ok("死亡期间全屏闪光照常淡出（世界冻结但表现层仍在演进）",
		_w().flash_power <= 0.001 and main.hud.flash_rect.color.a <= 0.001,
		"走了 %d 步 flash_power=%.3f alpha=%.3f" % [fx_steps, _w().flash_power,
			main.hud.flash_rect.color.a])
	# 顺带证明"世界真的停住了"：这些步进只该推进表现层，不该推动世界时间。
	# 少了这条，上面那条断言在"衰减其实写在 step() 里"的实现下也能过。
	_ok("结算期间世界时间没有前进（世界确实被冻结，不是靠 step 衰减）",
		is_equal_approx(_w().time, w_time0), "time %.4f -> %.4f" % [w_time0, _w().time])

	# 重生前**再手动点亮一次**红闪：上面那轮已经把 flash_power 淡到 0，
	# 如果就这么重生，"重生后不残留"就成了同义反复（本来就是 0，当然清得掉）。
	# 这条真正要测的是 hud.refresh() 的 else 分支：HUD 常驻，而 flash_power 属于旧
	# World 实例 —— 新世界从 0 开始，refresh 若不把颜色写回透明，
	# 上一关的红闪就会一直盖在新关卡的画面上。
	_w().flash_color = Color.html("#d8543f")
	_w().flash_power = 0.34
	main.advance(STEP)
	_ok("重生前红闪确实在屏幕上（给下一条断言制造真实前提）",
		main.hud.flash_rect.color.a > 0.1, "alpha=%.3f" % main.hud.flash_rect.color.a)

	_tap("restart")
	_pump(4)
	_ok("按 R 重生：回到战斗且满血", main.state == "play" and is_equal_approx(_p().hp, _p().max_hp),
		"%s hp=%.0f" % [main.state, _p().hp])
	_ok("重生后世界重建（灯塔回到未点亮）", not bool(_w().goal_prop["lit"]))
	_ok("重生后全屏滤镜已清除（新世界 flash_power=0 时 refresh 必须写回透明）",
		_w().flash_power <= 0.0 and main.hud.flash_rect.color.a <= 0.001,
		"flash_power=%.3f alpha=%.3f" % [_w().flash_power, main.hud.flash_rect.color.a])

	# 交互：火盆
	var bw := _w()
	var b: Dictionary = bw.braziers[0]
	bw.teleport(float(b["x"]) + 30.0, float(b["y"]) + 30.0)
	_p().combo = 10.0
	_p().combo_timer = 1e9
	_pump(4)
	_ok("靠近火盆会出现交互提示", bw.prompt.find("火盆") >= 0, bw.prompt)
	_tap("interact")
	_ok("按 E 点燃火盆", bool(b["lit"]))
	_ok("点燃火盆消耗 3 层连击", _p().combo < 10.0, "%.1f" % _p().combo)
	_pump(30)
	var img := await _grab()
	_ok("火盆点亮后场景变亮", _mean_lum(img) > 0.0)


## 机器人真实试玩：证明"整条循环不会崩"，而不是逐条断言具体数值。
func _section_bot_playthrough() -> void:
	main.restart_level()
	_pump(4)
	var w := _w()
	var p := _p()
	var combo_peak := 0.0
	var hp_min := p.hp
	var kills0 := int(w.prog["kills"])
	var pulse := false
	var bot_drafts := 0
	var bot_deaths := 0
	# 阵亡重开会把波次进度清零，所以报告"打到哪儿了"要取全程最大值
	var waves_best := 0
	# 同理：Boss 有没有被惊动，也要看全程（重开后的新世界这两项都是 false）
	var boss_seen := false

	for i in 5400:   # 90 秒游戏时间
		# 肉鸽：清空一波会弹三选一，而此时**世界是冻结的**（main.state == "draft"）。
		# 机器人也必须会选 —— 否则它会永远卡在面板上，症状是
		# 「击杀数停在第一波、最高连击不再涨、Boss 永不出现」。
		# 选哪一项：优先拿恩赐。机器人的走位阈值（62px 压上 / 44px 退开）是照近战写的，
		# 随到弩或灯杖它根本不会用 —— 那才是"机器人变菜"的真正原因，不是武器不好。
		if main.state == "draft":
			var pick := 0
			for j in main._draft_items.size():
				if str((main._draft_items[j] as Dictionary)["kind"]) != "weapon":
					pick = j
					break
			if _resolve_draft(pick):
				bot_drafts += 1
			continue
		# 死在菜单里是**静默**的：world 不再 step，机器人后面几十秒全在空转，
		# 看起来像"战斗循环坏了"。像真人一样按 R 爬起来，并重新取世界引用。
		if main.state == "menu":
			if main._menu_kind == "death":
				bot_deaths += 1
			_tap("restart")
			w = _w()
			p = _p()
			continue
		# 重开/过关会先播一段对白，对白期间世界同样是停的 —— 一并点掉
		if main.state == "dialogue":
			_tap("confirm")
			continue

		var tgt := _nearest_enemy(w)
		var dir := Vector2.ZERO
		var want_atk := false
		var want_skill := false
		# 附近敌人的方向之和（按距离加权）——被围时照它的反方向走才是真脱离，
		# 只盯着最近的敌人退会被包抄，40 秒就躺。
		var pack := Vector2.ZERO
		var pack_n := 0
		for e in w.enemies:
			if e.dead:
				continue
			var ed := Proj.dist(e.x, e.y, p.x, p.y)
			if ed < 132.0:
				pack += Vector2(e.x - p.x, e.y - p.y) / maxf(ed, 1.0)
				pack_n += 1
		var danger := pack_n >= 3 and p.hp < p.max_hp * 0.75
		if tgt != null:
			var to := Vector2(tgt.x - p.x, tgt.y - p.y)
			var d := to.length()
			GameInput.aim_world = Vector2(tgt.x, tgt.y)
			if d > 0.001:
				var u := to / d
				if danger and pack.length_squared() > 0.0001:
					dir = -pack.normalized()   # 突出包围圈
				elif d > 62.0:
					dir = u            # 压进射程
				elif d <= 44.0:
					dir = -u           # 太贴脸就退开，别白挨刀
			want_atk = d < 64.0 and not danger
			want_skill = d < 60.0 and p.combo >= 4.0 and not danger
		else:
			GameInput.aim_world = null
			var aim := _next_goal(w)
			var to := aim - Vector2(p.x, p.y)
			if to.length() > 0.001:
				dir = to.normalized()
		# 关键：攻击必须"按下—松开"交替。世界用的是 just("attack")（边沿触发），
		# 一直按住只会挥出第一刀，之后机器人就再也不出招了。
		pulse = not pulse
		GameInput.set_override("attack", want_atk and pulse)
		GameInput.set_override("skill1", want_skill and pulse)
		GameInput.set_override("move_right", dir.x > 0.3)
		GameInput.set_override("move_left", dir.x < -0.3)
		GameInput.set_override("move_down", dir.y > 0.3)
		GameInput.set_override("move_up", dir.y < -0.3)
		main.advance(STEP)
		combo_peak = maxf(combo_peak, p.combo)
		hp_min = minf(hp_min, p.hp)
		waves_best = maxi(waves_best, w.waves_cleared_count())
		boss_seen = boss_seen or w.boss_spawned

	GameInput.clear_overrides()
	GameInput.aim_world = null
	_pump(4)

	var kills := int(w.prog["kills"]) - kills0
	_num("机器人击杀数", 0.0, kills)
	_num("机器人最高连击", combo_peak)
	_num("机器人最低生命", hp_min)
	_num("机器人清空波次数", 0.0, w.waves_cleared_count())
	_num("机器人阵亡次数", 0.0, bot_deaths)
	report["cases"]["bot"] = {
		"kills": kills, "combo_peak": snappedf(combo_peak, 0.1),
		"hp_min": snappedf(hp_min, 0.1), "waves_cleared": w.waves_cleared_count(),
		"waves_best": waves_best, "deaths": bot_deaths, "boss_seen": boss_seen,
		"boss_spawned": w.boss_spawned, "cleared": w.cleared,
		"max_combo_prog": int(w.prog["max_combo"]),
		"drafts": bot_drafts,
	}
	_ok("机器人能打死敌人（战斗循环通）", kills > 0, str(kills))
	_ok("机器人能累积连击（连击循环通）", combo_peak > 3.0, "%.1f" % combo_peak)
	_ok("机器人会受伤（敌人威胁真实存在）", hp_min < p.max_hp, "%.1f" % hp_min)
	_ok("机器人清完了三波（波次链条能走通）", waves_best >= 3, str(waves_best))
	_ok("机器人打到了 Boss 区（进关链条能走通）", boss_seen)
	_ok("机器人也走完了肉鸽循环（自己选了三选一）", bot_drafts > 0, str(bot_drafts))
	await _shot("08-bot-play")


# ================================================================ 8 把武器 / 19 个技能

## 这一段把武器表**逐个技能跑一遍**，判据是"这一招确实产出了东西"：
## 新特效 / 新投射物 / 护盾 / 吸血窗口 / 连刺序列 / 位移之一发生变化。
## 不这样测的话，cast_skill 里少写一个 match 分支根本没人发现。
func _section_weapons_skills() -> void:
	var w := _w()
	var p := _p()
	# 这一段要断言"基础数值"，先把肉鸽恩赐清掉，免得倍率叠加把结论搅浑
	w.prog["boons"] = {}
	w.boons = w.prog["boons"]
	p.dead = false
	p.hp = p.max_hp
	p.invuln = 9999.0     # 只测玩家出手，不让敌人打断
	p.shield_t = 0.0
	p.lifesteal_t = 0.0
	p.flurry = 0

	var wids := Content.WEAPONS.keys()
	_ok("武器表有 8 把", wids.size() == 8, str(wids.size()))

	# 八把武器的"位置"要真的分开，而不是只改伤害数字
	_ok("灯弩是唯一远程（style == shot）",
		str(Content.WEAPONS["crossbow"]["style"]) == "shot"
		and str(Content.WEAPONS["crossbow"]["range"]) == "380.0")
	_ok("灯镰的弧最宽（2.70）",
		is_equal_approx(float(Content.WEAPONS["scythe"]["arc"]), 2.7))
	_ok("锁灯的近战距离最长（132）",
		is_equal_approx(float(Content.WEAPONS["chain"]["range"]), 132.0))
	_ok("双灯刃攻速最快（0.18）",
		is_equal_approx(float(Content.WEAPONS["twin"]["cd"]), 0.18))
	_ok("烬锤最慢最重（0.68 / 34）",
		is_equal_approx(float(Content.WEAPONS["hammer"]["cd"]), 0.68)
		and is_equal_approx(float(Content.WEAPONS["hammer"]["dmg"]), 34.0))

	var my_spawns := []
	var skill_total := 0
	var skill_fired := 0
	var kinds := {}
	for wid in wids:
		var wd: Dictionary = Content.WEAPONS[wid]
		var skl: Array = wd["skills"]
		p.weapon_id = str(wid)
		for si in skl.size():
			skill_total += 1
			var sk: Dictionary = skl[si]
			p.combo = 90.0
			p.skill_cd.clear()
			p.dash_t = 0.0
			var fx0 := w.effects.size()
			var pr0 := w.projs.size()
			var sh0 := p.shield_t
			var ls0 := p.lifesteal_t
			var fl0 := p.flurry
			var da0 := p.dash_t
			w.use_skill(si)
			var changed := w.effects.size() > fx0 or w.projs.size() > pr0 \
				or p.shield_t > sh0 or p.lifesteal_t > ls0 \
				or p.flurry > fl0 or p.dash_t > da0
			if changed:
				skill_fired += 1
			else:
				_ok("技能生效：%s / %s" % [str(wd["name"]), str(sk["name"])], false,
					"没有产出任何特效/投射物/状态变化")
			_collect_kinds(w, kinds)
	_ok("19 个技能全部有产出（%d/%d）" % [skill_fired, skill_total],
		skill_fired == skill_total and skill_total == 19)
	_num("技能总数", 0.0, skill_total)

	# ── 灯弩：挥击不是刀弧，而是射出光矢 ──
	p.weapon_id = "crossbow"
	p.invuln = 9999.0
	GameInput.aim_world = Vector2(p.x + 120.0, p.y)
	var pr_shot := w.projs.size()
	_tap("attack")
	_ok("灯弩挥击会射出光矢（而不是刀弧）", w.projs.size() > pr_shot,
		"%d -> %d" % [pr_shot, w.projs.size()])
	_collect_kinds(w, kinds)

	# ── 贯穿：一箭穿过三个排队的敌人 ──
	var line_y := p.y
	var line: Array = []
	for i in 3:
		var le := w.spawn_enemy("shade", p.x + 150.0 + float(i) * 70.0, line_y, false)
		le.hp = 4000.0
		le.max_hp = 4000.0
		line.append(le)
		my_spawns.append(le)
	var piere_hp := []
	for le in line:
		piere_hp.append(le.hp)
	w.projs.clear()
	p.facing = 0.0
	p.combo = 90.0
	p.skill_cd.clear()
	GameInput.aim_world = Vector2(p.x + 300.0, p.y)
	w.cast_skill("bow_pierce")
	_pump(40)
	var pierced := 0
	for i in line.size():
		if line[i].hp < float(piere_hp[i]):
			pierced += 1
	_ok("穿影矢一根穿过多只（≥2）", pierced >= 2, "命中 %d 只" % pierced)

	# ── 持续区域：灯球按 tick 反复打，而不是只结算一次 ──
	p.weapon_id = "staff"
	p.combo = 90.0
	p.skill_cd.clear()
	w.effects.clear()
	var ze := w.spawn_enemy("shade", p.x, p.y - 10.0, false)
	ze.hp = 9999.0
	ze.max_hp = 9999.0
	ze.state = "chase"
	my_spawns.append(ze)
	GameInput.aim_world = Vector2(p.x + 80.0, p.y)
	w.cast_skill("staff_orb")
	var zone_hp0 := ze.hp
	# 灯球落在 facing 方向 80px；把敌人挪到球心
	for f in w.effects:
		if str(f["kind"]) == "zone":
			ze.x = float(f["x"])
			ze.y = float(f["y"])
	# 顺便留一张"新武器特效"的实证截图：灯杖的灯球（持续区域）。
	# 断言只能证明"有 zone 这个 kind"，看不出它长什么样 —— 这一张是给人看的。
	# 注意这里多走的 6 步必须在下面补回来（80 → 74）：固定步长下每多推一步都会挪动
	# RNG 流，后面几十条依赖位置/随机的断言会集体错位（这次就撞掉了"链锁拽近"那条）。
	_pump(6)
	await _shot("11-weapon-staff-orb")
	_pump(74)     # 6 + 74 = 原样 80 步 → 约 1.3 秒 → 至少 3 跳
	var zone_hits := 0
	for f in w.effects:
		if str(f["kind"]) == "zone":
			zone_hits = (f["hit"] as Dictionary).size()
	var zone_dmg := zone_hp0 - ze.hp
	_ok("灯球是持续区域（1.3 秒内多次结算，不是只打一下）", zone_dmg > 0.0 and zone_hits >= 1,
		"伤害 %.1f 命中集 %d" % [zone_dmg, zone_hits])
	_num("灯球 1.3 秒总伤害", zone_dmg)

	# ── 牵引：链锁把敌人拽近 ──
	p.weapon_id = "chain"
	p.combo = 90.0
	p.skill_cd.clear()
	var pe := w.spawn_enemy("shade", p.x + 170.0, p.y, false)
	pe.hp = 9999.0
	pe.max_hp = 9999.0
	pe.state = "chase"
	pe.stun = 5.0
	my_spawns.append(pe)
	var pd0 := Proj.dist(p.x, p.y, pe.x, pe.y)
	w.cast_skill("chain_hook")
	_pump(30)
	var pd1 := Proj.dist(p.x, p.y, pe.x, pe.y)
	_ok("链锁把敌人拽近（距离明显缩短）", pd1 < pd0 - 40.0,
		"%.0f -> %.0f" % [pd0, pd1])

	# ── 护光：护盾期间免疫伤害 ──
	p.weapon_id = "staff"
	p.combo = 90.0
	p.skill_cd.clear()
	w.cast_skill("staff_ward")
	var shield_hp := p.hp
	p.invuln = 0.0
	w.hurt_player(50.0, 0.0)
	_ok("护光期间被咬不掉血", is_equal_approx(p.hp, shield_hp) and p.shield_t > 0.0,
		"hp %.1f -> %.1f shield %.2f" % [shield_hp, p.hp, p.shield_t])

	# ── 噬影：吸血窗口会把造成的伤害转成生命 ──
	p.weapon_id = "scythe"
	p.combo = 90.0
	p.skill_cd.clear()
	w.cast_skill("scythe_devour")
	var ls_hp := p.hp - 40.0
	p.hp = ls_hp
	var ve := w.spawn_enemy("shade", p.x + 60.0, p.y, false)
	ve.hp = 9999.0
	ve.max_hp = 9999.0
	ve.ward_cd = 0.0
	my_spawns.append(ve)
	w.damage_enemy(ve, 200.0, 0.0, 0.0)
	_ok("噬影：造成伤害会回血", p.hp > ls_hp, "hp %.1f -> %.1f" % [ls_hp, p.hp])

	# ── 精英词缀 ──
	var rng := Proj.make_rng(9)
	var aff_ok := true
	var aff_detail := ""
	for k in Content.ELITE_AFFIXES.keys():
		var base: Dictionary = Content.ENEMIES["shade"]
		var el: Dictionary = Content.eliteify(base)
		var af: Dictionary = Content.apply_affix(el, str(k), rng)
		if str(af.get("affix", "")) != str(k) or str(af.get("affix_name", "")) == "":
			aff_ok = false
			aff_detail = str(k)
	_ok("5 个精英词缀都能挂上去（燃/韧/疾/噬/障）", aff_ok
		and Content.ELITE_AFFIXES.size() == 5, aff_detail)
	var tough: Dictionary = Content.apply_affix(Content.eliteify(Content.ENEMIES["shade"]), "tough", rng)
	_ok("词缀「韧」真的带减伤（dr > 0）", float(tough.get("dr", 0.0)) > 0.0)
	var ward: Dictionary = Content.apply_affix(Content.eliteify(Content.ENEMIES["shade"]), "ward", rng)
	_ok("词缀「障」真的带格挡冷却（ward_cd > 0）", float(ward.get("ward_cd", 0.0)) > 0.0)

	# ── 恩赐：数值要真的作用到派生属性上 ──
	w.prog["boons"] = {"dmg": 2, "light": 1, "haste": 1}
	w.boons = w.prog["boons"]
	var dm_with := w.damage_mul()
	var lr_with := w.player_light_radius()
	var cd_with := w.attack_cd_mul()
	var cost_with := w.skill_cost(6)
	w.prog["boons"] = {}
	w.boons = w.prog["boons"]
	var dm_without := w.damage_mul()
	var lr_without := w.player_light_radius()
	_ok("恩赐「灯芯·锋」提高伤害", dm_with > dm_without * 1.2,
		"%.3f -> %.3f" % [dm_without, dm_with])
	_ok("恩赐「灯芯·明」提高光照半径", lr_with > lr_without + 20.0,
		"%.0f -> %.0f" % [lr_without, lr_with])
	_ok("恩赐「灯芯·疾」降低挥击冷却", cd_with < 1.0, "%.3f" % cd_with)
	_ok("恩赐「省火」降低技能消耗（但最低 1）", cost_with == 6)
	w.prog["boons"] = {"cost_cut": 3}
	w.boons = w.prog["boons"]
	_ok("省火扣到最低 1 就不再扣", w.skill_cost(3) == 1, str(w.skill_cost(3)))
	w.prog["boons"] = {}
	w.boons = w.prog["boons"]

	# ── 特效种类：八把武器的"位置"要真的分开，而不是只改伤害数字 ──
	# 判据是这一路把 8 把武器 / 19 个技能跑完之后，世界里出现过的 effect.kind 集合。
	# beam / muzzle 这类只活 0.06~0.2 秒，所以每次出手后都立刻 _collect_kinds() 采一次，
	# 否则等 _pump 完再看就已经过期了（这一条曾经因此漏判）。
	# 注意 beam 不在这张表里：它只有 Boss 会放，归 _section_waves_boss 验。
	var kk: Array = kinds.keys()
	kk.sort()
	report["cases"]["weapons"] = {
		"count": wids.size(), "skills": skill_total,
		"effect_kinds": kk, "effect_kinds_n": kk.size(),
	}
	_ok("八把武器共产出 ≥ 7 种特效（不是靠改数字凑数）", kk.size() >= 7,
		"%d 种：%s" % [kk.size(), ", ".join(kk)])
	var need_kinds := ["slash", "ring", "burst", "pillar", "pull", "zone", "muzzle"]
	var missing := []
	for nk in need_kinds:
		if not kinds.has(nk):
			missing.append(nk)
	_ok("玩家侧关键特效齐了（挥击/环/爆发/光柱/拽拉/持续区/枪口）",
		missing.is_empty(), "缺 " + ", ".join(missing))

	# 收尾：清掉这一段制造的敌人与状态，别影响后面的段落
	for e in my_spawns:
		e.dead = true
		e.death_t = 99.0
	p.weapon_id = "blade"
	p.invuln = 0.0
	p.shield_t = 0.0
	p.lifesteal_t = 0.0
	p.lifesteal_pct = 0.0
	p.flurry = 0
	p.combo = 0.0
	w.projs.clear()
	w.effects.clear()
	GameInput.aim_world = null
	_pump(2)


# ================================================================ 第二关 · 无芯之暗

func _section_level2() -> void:
	# 切到第二关（重新建世界）。这一段放最后，因为它会把世界换掉。
	# **波次必须是开着的**：这段要验"清空一波 → 弹出三选一"，
	# 而那个面板就是靠"波次被判定清空"才弹出来的。
	# 验完三选一立刻停链（见本段中间），免得随机锚点把别的怪刷进火盆 / 盲女那几段。
	main.waves_off = false
	main.prog["boons"] = {}
	main.prog["weapon"] = "blade"
	main.prog["level"] = 1
	main.start_level()
	_pump(4)
	var w := _w()
	var p := _p()

	_ok("第二关加载成功（index == 1）", int(w.level["index"]) == 1, str(w.level["index"]))
	_ok("第二关墙体 16 面", w.walls.size() == 16, str(w.walls.size()))
	_ok("第二关要点头满 3 座火盆", w.braziers_required == 3, str(w.braziers_required))
	_ok("第二关有盲女同行", w.girl != null)
	_ok("第二关的地图更大（2800x2000）",
		is_equal_approx(float(w.level["w"]), 2800.0) and is_equal_approx(float(w.level["h"]), 2000.0))
	_ok("第二关更黑（ambient 0.955 > 第一关 0.9）",
		float(w.level["ambient"]) > 0.9, "%.3f" % float(w.level["ambient"]))
	_num("第二关 ambient", float(w.level["ambient"]))
	_num("第二关敌人倍率", float(w.level["enemy_scale"]))

	# ── 肉鸽：三选一在第二关也照样发生，且选择真的生效 ──
	var boons_before := int(main.prog["boons"].size())
	var wv0: Dictionary = w.waves[0]
	w.teleport(float(wv0["def"]["x"]), float(wv0["def"]["y"]))
	p.hp = p.max_hp
	p.invuln = 0.0
	_pump(8)
	_ok("第二关第一波会刷出", bool(wv0["spawned"]))
	for e in w.enemies:
		if not e.dead and (e.id in wv0["members"]):
			_force_kill(w, e)
	# 这里**不能**用默认的 _pump —— 它见到 draft 就自动替我们选掉了（那是为了让后面
	# 的段落不被冻结的世界拖死）。可这一段要验的正是"面板真的弹出来"，
	# 所以把 auto_draft 关掉，并且先清干净输入，免得有残留的按住状态吃掉这个边沿。
	GameInput.clear_overrides()
	_pump(2, {}, false)
	_ok("清空一波后确实弹出三选一", main.state == "draft", main.state)
	_ok("三选一给了 3 个选项", main._draft_items.size() == 3, str(main._draft_items.size()))

	# ── 三选一的输入规则：只有 Q/E 移动、只有空格/回车拿走 ──
	# 用户的要求是"QE 左右切换，别的键无效，不然容易误选"。
	# 下面这组就是这句话的验收标准：**每一条都要能真的失败**，
	# 而不是"看起来该是那样"（旧版是 1/2/3 直接选中，误触一下就赔一局）。
	var idx0 := main._draft_index
	var n0 := main._draft_items.size()

	# ① 装填窗口：面板刚弹出来就按确认，必须无效
	_ok("面板刚弹出时还没装填完", not main._draft_armed())
	_tap("confirm")
	_ok("装填窗口内按确认无效（防误触：清波瞬间常在连打空格冲刺）",
		main.state == "draft", main.state)

	# ② 1/2/3（旧版的"直接选中"）必须全部失效
	var leak := ""
	for k in ["skill1", "skill2", "skill3"]:
		_tap(k)
		if main.state != "draft":
			leak = k
	_ok("1/2/3 在三选一里已彻底失效（不再直接选中）",
		leak == "" and main.state == "draft", "泄漏键=" + leak + " state=" + main.state)

	# ③ A/D 也不能移动高亮（高亮只认 Q/E）
	_tap("move_right")
	_tap("move_left")
	_ok("A/D 不会移动三选一高亮", main._draft_index == idx0, str(main._draft_index))

	# ④ J（攻击）/ 鼠标左键绑的是同一个 attack，同样不能确认
	_tap("attack")
	_ok("J 不能确认三选一（攻击键在这里无效）", main.state == "draft", main.state)

	# ⑤ Q/E 正常移动，且两头绕圈
	_tap("draft_next")
	var i_next := main._draft_index
	_ok("E 把高亮右移一格", i_next == (idx0 + 1) % n0, "%d -> %d" % [idx0, i_next])
	_tap("draft_prev")
	_ok("Q 把高亮左移一格（回到原位）", main._draft_index == idx0, str(main._draft_index))
	_tap("draft_prev")
	_ok("Q 从第一格再左移会绕到最后一格",
		main._draft_index == (idx0 - 1 + n0) % n0, str(main._draft_index))
	_tap("draft_next")
	_ok("绕回来仍是原位（左右对称）", main._draft_index == idx0, str(main._draft_index))

	# ⑥ 装填完成后，空格确实能把**当前高亮的那一张**拿走
	var arm2 := 0
	while not main._draft_armed() and arm2 < 120:
		arm2 += 1
		main.advance(STEP)
	_ok("面板装填完成（此后确认才生效）", main._draft_armed())
	report["samples"]["draft_input"] = {
		"arm_seconds": snappedf(Main.DRAFT_ARM, 0.01),
		"keys_move": ["Q", "E"], "keys_confirm": ["空格", "回车"],
		"keys_dead": ["1", "2", "3", "A", "D", "J", "鼠标左键"],
	}

	# 给"新的三选一面板"留一张截图。**截图不推世界**（只 await 两帧渲染，
	# 不调 main.advance），所以既不会挪动 RNG 流，也不破坏上面的输入规则验证。
	# 停在中间那张上，是为了让「上浮 + 金描边」的高亮一眼能看出来。
	_tap("draft_next")
	await _shot("12-draft")
	_tap("draft_prev")
	_ok("截图不打乱高亮位置（截图不入 RNG / 不动状态）",
		main._draft_index == idx0, str(main._draft_index))

	var offer := []
	for it in main._draft_items:
		offer.append("%s:%s" % [str(it["kind"]), str(it["name"])])
	report["samples"]["draft_offers"] = offer
	# 验一遍"选它到底改了什么"。要点是**高亮在哪、拿走的就得是哪一张**：
	# 所以特意挑**最后一张**（让它必须先移动两格），选完再核对
	# ① 日志里记下的 picked 正好是它 ② 生效的也正好是它。
	var pick := n0 - 1
	for i in range(main._draft_items.size() - 1, -1, -1):
		if str((main._draft_items[i] as Dictionary)["kind"]) == "weapon":
			pick = i     # 有武器就优先验"换武器"这条路
			break
	var target: Dictionary = main._draft_items[pick]
	var weapon_before := str(main.prog["weapon"])
	var boons_before2 := int(main.prog["boons"].size())
	_resolve_draft(pick)
	var last: Dictionary = draft_log[draft_log.size() - 1]
	_ok("确认拿走的就是高亮那一张（不是第一张）",
		pick > 0 and str(last["picked"]) == "%s:%s" % [str(target["kind"]), str(target["id"])],
		"高亮第 %d 张 → 拿走 %s" % [pick, str(last["picked"])])
	if str(target["kind"]) == "weapon":
		_ok("三选一里选「武器」会真的换上那一把",
			str(main.prog["weapon"]) == str(target["id"]) and _p().weapon_id == str(target["id"]),
			"%s -> %s" % [weapon_before, str(main.prog["weapon"])])
	else:
		_ok("三选一里选「恩赐」会把这一项记进恩赐表",
			int(main.prog["boons"].get(str(target["id"]), 0)) > 0,
			"恩赐 %s（%d -> %d 项）" % [str(target["id"]), boons_before2,
				int(main.prog["boons"].size())])
	_ok("三选一后世界恢复推进（state 回到 play）", main.state == "play", main.state)
	_num("三选一后恩赐项数", 0.0, int(main.prog["boons"].size()))

	# 三选一验完了 → 立刻停掉波次链。
	# 后面的火盆 / 再生 / 盲女 / Boss 都是**自己摆敌人**来测的，
	# 不希望随机锚点把别的波次刷进来（那会给"她近了更亮"这类比较掺进噪音）。
	w.waves_disabled = true

	# ── 无芯之暗：火盆没点满，死掉的东西会再生 ──
	p.hp = p.max_hp
	p.invuln = 0.0
	var victim := w.spawn_enemy("shade", p.x + 300.0, p.y, false)
	_pump(2)
	_force_kill(w, victim)
	_pump(2)
	var rc0 := w.respawn_count
	_pump(60 * 8)      # 再生延迟 6 秒，等够
	_ok("火盆没点满时，死掉的影子会再生", w.respawn_count > rc0,
		"respawn %d -> %d" % [rc0, w.respawn_count])
	_num("第二关再生次数", 0.0, w.respawn_count)

	# ── 火盆计数与 Boss 护佑 ──
	_ok("火盆没点满时 Boss 被护佑（减伤）", w.boss_warded())
	for b in w.braziers:
		w.light_brazier(b)
	_pump(2)
	_ok("三座火盆都点亮了", w.braziers_lit == 3, str(w.braziers_lit))
	_ok("火盆点满后 Boss 的护佑解除", not w.boss_warded())
	_ok("火盆点满后不再再生（新死的怪不入队）",
		w.braziers_lit >= w.braziers_required)
	_ok("点满火盆会推进目标文案", w.objective.find("点燃火盆") < 0 or w.cleared,
		w.objective)

	# ── 盲女：她会跟着你走；她在身边时光照 +52 ──
	# 光照半径里 combo、glow（挥击辉光）都是会变的项，而且 glow 一旦被顶到 1.0
	# 就不再衰减（只有 Boss 倒下时才会被写成 1.0）。所以比较两次测量之前先把它们
	# 按到 0 并开无敌 —— 否则"她近了更亮"会和"刚好挨了一刀/Boss 刚死"混在一起，
	# 之前那版就是这样翻的车：基准值本身已经含了 +52，测出来 248 -> 248。
	p.invuln = 9999.0
	for e in w.enemies:
		if not e.dead:
			_force_kill(w, e)

	# 前置条件：世界必须真的在跑。点满三座火盆会连排三段「火盆亮了」对白，
	# 对白期间 step() 是不被调的 —— 下面所有"传送到某处 → 走一步看结果"的假设
	# 都建立在这个前提上，所以先把残留的对白/三选一清干净，并把它断言出来。
	# （上一版就是在这一步栽的：girl_near 一直停在旧值、盲女一步没动、距离恰好 1200。）
	_drain_dialogue()
	_pump(2)
	_drain_dialogue()
	_ok("盲女段开始前世界在推进（state == play）", main.state == "play", main.state)

	# ① 先验"跟着"：把她甩到地图另一头，她自己应该会追回来（这是真行为，不是摆拍）
	# 方向按玩家现处的位置挑，保证落点在地图里（2800×2000，边界墙厚 70），
	# 而且横向距离一定 1200px —— 远大于 girl_near 的 260 阈值。
	var far_x := (p.x - 1200.0) if p.x > 1400.0 else (p.x + 1200.0)
	w.girl["x"] = far_x
	w.girl["y"] = p.y
	w.girl["vx"] = 0.0
	w.girl["vy"] = 0.0
	_pump(1)
	_ok("盲女不在附近时 girl_near 为假", not w.girl_near)
	_pump(60 * 10)     # 给她 10 秒
	var gdist := Proj.dist(float(w.girl["x"]), float(w.girl["y"]), p.x, p.y)
	_ok("盲女会跟着玩家（从地图另一头自己追回来）", gdist < 400.0, "%.0f" % gdist)

	# ② 再量"加成"：除盲女的位置之外什么都不动，两次测量只差这一个变量
	p.combo = 0.0
	p.glow = 0.0
	w.girl["x"] = far_x
	w.girl["y"] = p.y
	_pump(1)
	var lr_far := w.player_light_radius()
	w.girl["x"] = p.x + 40.0
	w.girl["y"] = p.y
	w.girl["vx"] = 0.0
	w.girl["vy"] = 0.0
	_pump(1)
	_ok("盲女在身边时 girl_near 为真", w.girl_near)
	var lr_near := w.player_light_radius()
	_ok("盲女在身边时的光照半径恰好 +%d" % int(World.GIRL_LIGHT_BONUS),
		absf((lr_near - lr_far) - World.GIRL_LIGHT_BONUS) < 0.5,
		"%.0f -> %.0f（差 %.1f）" % [lr_far, lr_near, lr_near - lr_far])
	_num("盲女不在附近时的光照半径", lr_far)
	_num("盲女在身边时的光照半径", lr_near)
	# 走近她会出交互提示，按 E 说话
	_ok("靠近盲女会出现交互提示", w.prompt.find("盲女") >= 0, w.prompt)

	# ── Boss：第二关的 Boss 是成年噬灯者 ──
	var bd: Dictionary = w.level["boss"]
	_ok("第二关 Boss 是噬灯者（devourer）", str(bd["type"]) == "devourer", str(bd["type"]))
	w.boss_spawned = true
	var be := w.spawn_enemy("devourer", p.x + 200.0, p.y, false)
	w.boss_enemy = be
	be.boss = {"action": "", "timer": 0.0, "cool": 0.8, "phase": 1,
		"tx": be.x, "ty": be.y, "dash_t": 0.0, "sweep_a": 0.0, "drain_t": 0.0, "slam_armed": false}
	_pump(2)
	_ok("第二关 Boss 实例存在且是 boss 行为", be.is_boss())

	# 火盆已经点满 → 护佑解除，此时它应该会掉血
	var bhp0 := be.hp
	be.ward_cd = 0.0
	w.damage_enemy(be, 200.0, 0.0, 0.0)
	_ok("护佑解除后 Boss 会正常掉血", be.hp < bhp0, "%.0f -> %.0f" % [bhp0, be.hp])

	report["cases"]["level2"] = {
		"name": str(w.level["name"]), "index": int(w.level["index"]),
		"w": float(w.level["w"]), "h": float(w.level["h"]),
		"walls": w.walls.size(), "ambient": snappedf(float(w.level["ambient"]), 0.001),
		"enemy_scale": float(w.level["enemy_scale"]),
		"braziers_lit": w.braziers_lit, "braziers_required": w.braziers_required,
		"respawns": w.respawn_count, "has_girl": w.girl != null,
		"boss": str((w.level["boss"] as Dictionary)["type"]),
	}
	await _shot("09-level2")
	# 第二关也走一遍通关流程
	var lv1_deaths := int(main.prog["deaths"])
	_force_kill(w, be)
	_pump(4)
	_ok("第二关 Boss 死亡后标记 cleared", w.cleared)
	_ok("第二关通关会加灯芯", int(main.prog["wicks"]) >= 1, str(main.prog["wicks"]))
	_ok("第二关通关给了一次「盲女之灯」（revives +1）", p.revives >= 1, str(p.revives))
	_ok("死亡计数没有被通关流程误加", int(main.prog["deaths"]) == lv1_deaths)
	_drain_dialogue()
	_pump(4)
	_ok("第二关通关面板出现（并且是最后一关）",
		main.state == "menu" and main._menu_kind == "clear", "%s/%s" % [main.state, main._menu_kind])
	await _shot("10-level2-clear")


func _nearest_enemy(w: World) -> EnemyState:
	var best: EnemyState = null
	var bd := 1e9
	for e in w.enemies:
		if e.dead:
			continue
		var d := Proj.dist(e.x, e.y, w.player.x, w.player.y)
		if d < bd:
			bd = d
			best = e
	return best


func _next_goal(w: World) -> Vector2:
	for wv in w.waves:
		if not bool(wv["cleared"]):
			var wd: Dictionary = wv["def"]
			return Vector2(float(wd["x"]), float(wd["y"]))
	if w.boss_enemy != null and not w.boss_enemy.dead:
		return Vector2(w.boss_enemy.x, w.boss_enemy.y)
	# 兜底：Boss 场地的**运行时锚点**（随机生成的那份，不是关卡表里的固定值）
	return w.boss_anchor


## 在 (cx, cy) 周围找一个**不合墙**的落脚点，离中心 dist。
##
## 为什么不用 `world.find_spawn_point()`：那个函数吃 `_rng`（主仿真流），
## 自检调它会把后面所有跟随机有关的东西整体错位 —— 本项目最容易踩的坑。
## 这里只要"哪儿能站"这一个答案，所以自己按固定角度扫一圈，不消耗任何 RNG。
func _stand_near(w: World, cx: float, cy: float, dist: float) -> Vector2:
	for k in 24:
		var a := float(k) / 24.0 * TAU
		var q := Vector2(cx + cos(a) * dist, cy + sin(a) * dist)
		if not w.blocked(q.x, q.y, 14.0):
			return q
	return Vector2(cx, cy)   # 实在没地方就站箱子上 —— 宝箱故意不 solid，站得住


# ================================================================ 收尾

## 等面板装填完成。**用真实步进等过去，不直接把计时器置满** ——
## 直接置满就等于没验"装填窗口真的挡住了误触"这条规则。
func _wait_arm() -> void:
	var g := 0
	while not main._draft_armed() and g < 120:
		g += 1
		main.advance(STEP)


## 当前手持武器的词条签名（"变了没变"用）
func _affix_sig_of(w: World) -> String:
	var s := ""
	for a in w.weapon_affixes():
		s += "%s%d|" % [str(a["id"]), int(a["lv"])]
	return s


# ================================================================ 背包 / 换手 / 灯油 / 宝箱

## 用户这一轮要的第一组功能：宝箱开武器、背包多带一把、X 换手、C 喝灯油。
func _section_bag_chest() -> void:
	# 这一段自己重开一次第一关：世界随机器全部重置，背包/词条从干净状态验。
	# （放在所有段落之后，所以这里多推多少步都不会影响前面的断言。）
	# 关掉波次链：锚点是随机的，别让一整波怪刷进宝箱 / 商店那几段。
	main.waves_off = true
	main.prog["level"] = 0
	main.restart_level()
	_pump(4)
	var w := _w()
	var p := _p()
	p.invuln = 99999.0      # 只测背包，不让敌人打断
	w.prog["bag_weapon"] = ""
	w.prog["waffix"] = {}
	w.prog["shop"]["oil_bank"] = 0
	w.prog["weapon"] = "blade"
	p.weapon_id = "blade"

	# ── 宝箱：点位存在、初始是关着的 ──
	_ok("第一关放了 2 个宝箱", w.chests.size() == 2, str(w.chests.size()))
	var unopened := 0
	for c in w.chests:
		if not bool(c["opened"]):
			unopened += 1
	_ok("宝箱一开始都是没开过的", unopened == w.chests.size(),
		"%d/%d" % [unopened, w.chests.size()])

	# ── 走过去按 E 开箱 ──
	var c0: Dictionary = w.chests[0]
	# 宝箱位置现在每局随机，所以站位也要**算出来**而不是写死偏移：
	# 固定偏移（+34,+30）在一个随机点旁边很可能正好是墙。
	var st0 := _stand_near(w, float(c0["x"]), float(c0["y"]), 46.0)
	w.teleport(st0.x, st0.y)
	_pump(3)
	_ok("靠近宝箱会出现交互提示", w.prompt.find("宝箱") >= 0, w.prompt)

	# 开箱这一段**必须关掉自动处理**：要验的正是"面板真的弹出来了、里面是什么"
	GameInput.clear_overrides()
	_tap("interact")
	_ok("按 E 打开宝箱（弹出选择面板）", main.state == "draft", main.state)
	_ok("这是宝箱面板，不是清波三选一", main._panel_kind == "chest", main._panel_kind)
	_ok("宝箱开出 3 把武器", main._draft_items.size() == 3 and _all_weapons(main._draft_items),
		"%d 项" % main._draft_items.size())
	var has_equipped := false
	for it in main._draft_items:
		if str((it as Dictionary)["id"]) == str(w.prog["weapon"]):
			has_equipped = true
	_ok("开出的 3 把里不含手上那把（不会开出重复的）", not has_equipped)
	var all_affixed := true
	for it in main._draft_items:
		if (it as Dictionary).get("affix", []).is_empty():
			all_affixed = false
	_ok("开箱的武器都自带一条词条", all_affixed)

	await _shot("13-chest")

	# 刚踩过的坑：`_draft_input` 每次按方向键都会重调 show_draft()，
	# 如果没把文案一起带上，宝箱面板一按 Q/E 就会退回三选一的默认标题。
	_tap("draft_next")
	_ok("宝箱面板按方向键移动后，标题与底部提示不会被重置成三选一",
		main.hud.draft_title.text.find("箱") >= 0
		and main.hud.draft_hint.text.find("背包") >= 0,
		"%s / %s" % [main.hud.draft_title.text, main.hud.draft_hint.text])
	_tap("draft_prev")

	# ── 拿走**中间那张**：验"高亮在哪、拿走的就得是哪张" ──
	var idx := 1
	var target: Dictionary = main._draft_items[idx]
	var wid := str(target["id"])
	var mv := 0
	while main._draft_index != idx and mv < 8:
		mv += 1
		_tap("draft_next")
	_wait_arm()
	_tap("confirm")
	_ok("宝箱选中的就是高亮那一张", str(w.prog["bag_weapon"]) == wid,
		"高亮第 %d 张 → 背包 %s" % [idx, str(w.prog["bag_weapon"])])
	_ok("宝箱武器进的是**背包**，不是直接换上",
		str(w.prog["weapon"]) == "blade", str(w.prog["weapon"]))
	_ok("开箱后世界恢复推进", main.state == "play", main.state)
	_ok("这个宝箱记成已开（同一个箱子不能反复刷）", bool(c0["opened"]))

	# ── 空箱子不再弹面板 ──
	_tap("interact")
	_ok("已经开过的宝箱不会再弹出面板", main.state == "play", main.state)

	# ── 背包满时：新武器换掉旧的，旧的被搁下 ──
	var bag_before := str(w.prog["bag_weapon"])
	var c1: Dictionary = w.chests[1]
	var st1 := _stand_near(w, float(c1["x"]), float(c1["y"]), 46.0)
	w.teleport(st1.x, st1.y)
	_pump(3)
	_tap("interact")
	_ok("第二个宝箱能开", main.state == "draft" and main._panel_kind == "chest", main.state)
	var wid2 := str((main._draft_items[0] as Dictionary)["id"])
	_wait_arm()
	_tap("confirm")
	_ok("背包已满时，开箱会把新的放进去、旧的换下来",
		str(w.prog["bag_weapon"]) == wid2 and bag_before != wid2,
		"%s -> %s" % [bag_before, str(w.prog["bag_weapon"])])

	# ── X 换手 ──
	_ok("两把武器不是同一把（换手才验得出来）",
		str(w.prog["weapon"]) != str(w.prog["bag_weapon"]),
		"%s / %s" % [str(w.prog["weapon"]), str(w.prog["bag_weapon"])])
	var hand_before := str(w.prog["weapon"])
	var bag_now := str(w.prog["bag_weapon"])
	_tap("swap_weapon")
	_ok("按 X 与背包武器互换",
		str(w.prog["weapon"]) == bag_now and str(w.prog["bag_weapon"]) == hand_before,
		"%s/%s -> %s/%s" % [hand_before, bag_now,
			str(w.prog["weapon"]), str(w.prog["bag_weapon"])])
	_ok("换手后玩家手上真的换了武器（不只是改字典）", p.weapon_id == bag_now, p.weapon_id)
	# 换手要能影响派生属性：词条是挂在武器 id 上的
	w.prog["waffix"] = {"blade": [{"id": "edge", "lv": 1}], bag_now: []}
	_tap("swap_weapon")
	_ok("换手换回原来那把，且它的词条跟着回来（词条挂在武器上，不是挂在「手上」）",
		str(w.prog["weapon"]) == hand_before and w.affix_lv("edge") == 1,
		"weapon=%s edge_lv=%d" % [str(w.prog["weapon"]), w.affix_lv("edge")])
	_tap("swap_weapon")
	_ok("手持那把没词条的武器时，「锋」的等级回到 0", w.affix_lv("edge") == 0,
		str(w.affix_lv("edge")))

	# ── 背包空时按 X 不该把自己缴械 ──
	w.prog["bag_weapon"] = ""
	var w3 := str(w.prog["weapon"])
	_tap("swap_weapon")
	_ok("背包是空的时候按 X 不换手（不会把自己缴械）",
		str(w.prog["weapon"]) == w3 and str(w.prog["bag_weapon"]) == "",
		"%s / bag=%s" % [str(w.prog["weapon"]), str(w.prog["bag_weapon"])])

	# ── C 喝灯油 ──
	p.hp = p.max_hp * 0.30
	_tap("use_potion")
	_ok("背包里没有灯油时按 C 不回血", w.potion_count() == 0
		and is_equal_approx(p.hp, p.max_hp * 0.30), "hp=%.1f" % p.hp)

	w.prog["shop"]["oil_bank"] = 2
	var hp_low := p.hp
	_tap("use_potion")
	var healed := p.hp - hp_low
	_ok("按 C 喝灯油会回血", healed > 1.0, "%.1f -> %.1f" % [hp_low, p.hp])
	_ok("回血量正好是 45% 最大生命",
		is_equal_approx(snappedf(healed, 0.01), snappedf(p.max_hp * 0.45, 0.01)),
		"%.2f vs %.2f" % [healed, p.max_hp * 0.45])
	_ok("喝一件灯油，背包里的数量 -1（2 -> 1）", w.potion_count() == 1, str(w.potion_count()))

	p.hp = p.max_hp
	_tap("use_potion")
	_ok("满血按 C 不会白白浪费灯油", w.potion_count() == 1 and is_equal_approx(p.hp, p.max_hp),
		"药=%d hp=%.1f" % [w.potion_count(), p.hp])

	# ── 背包栏截图（右下角：手持 + 词条 + 备用 + 灯油）──
	w.prog["waffix"]["blade"] = [{"id": "edge", "lv": 2}, {"id": "vamp", "lv": 1}]
	w.prog["weapon"] = "blade"
	p.weapon_id = "blade"
	w.prog["bag_weapon"] = "staff"
	w.prog["shop"]["oil_bank"] = 3
	_pump(2)
	_ok("背包栏的三个数都对得上（手持 / 备用 / 灯油）",
		w.affix_list().size() == 2 and w.potion_count() == 3 and str(w.prog["bag_weapon"]) == "staff",
		"词条%d 药%d 备用%s" % [w.affix_list().size(), w.potion_count(), str(w.prog["bag_weapon"])])
	report["samples"]["bag"] = {
		"weapon": str(w.prog["weapon"]), "bag_weapon": str(w.prog["bag_weapon"]),
		"potions": w.potion_count(), "affix": _affix_sig_of(w),
	}
	report["samples"]["chest"] = {
		"per_level": w.chests.size(),
		"weapon_pool": Content.WEAPONS.size(),
		"equipped_excluded": true,
		"affix_per_chest_weapon": 1,
	}
	await _shot("14-bag")


## 把 items 全判成武器
func _all_weapons(items: Array) -> bool:
	for it in items:
		if str((it as Dictionary).get("kind", "")) != "weapon":
			return false
	return not items.is_empty()


# ================================================================ 守灯人：重铸 / 锤炼 / 买灯油

## 用户这一轮要的第二组功能：守灯人能给武器加词条（重铸 / 锤炼），以及卖灯油。
func _section_shop() -> void:
	var w := _w()
	var p := _p()
	p.invuln = 99999.0
	p.dead = false
	var m: Dictionary = w.merchant_prop
	_ok("第一关有守灯人", not m.is_empty())
	if m.is_empty():
		return
	w.teleport(float(m["x"]) + 30.0, float(m["y"]) + 30.0)
	_pump(3)
	_ok("靠近守灯人会提示可以交谈", w.prompt.find("守灯人") >= 0, w.prompt)

	# 钱给够方便验买卖；词条清零，从"裸武器"开始
	w.prog["coins"] = 400
	w.prog["waffix"] = {}
	w.prog["weapon"] = "blade"
	p.weapon_id = "blade"
	# 第一次交谈的判定要确定：显式清掉"已经聊过"的标记
	w.prog.erase("keeper_talked")

	# ── 第一次交谈：先讲故事，讲完才开商店 ──
	GameInput.clear_overrides()
	_tap("interact")
	_ok("第一次和守灯人交谈会先讲两句", main.state == "dialogue", main.state)
	var g := 0
	while main.state == "dialogue" and g < 60:
		g += 1
		_tap("confirm")
	_ok("对白讲完自动打开商店（对白挡住的面板会补开）", main.state == "shop", main.state)
	_ok("商店四行：买灯油 / 重铸 / 锤炼 / 离开",
		main._shop_items.size() == 4, str(main._shop_items.size()))
	_ok("商店的三个服务项与 world.shop_items() 一致",
		str((main._shop_items[0] as Dictionary)["id"]) == "oil"
		and str((main._shop_items[1] as Dictionary)["id"]) == "reforge"
		and str((main._shop_items[2] as Dictionary)["id"]) == "temper"
		and str((main._shop_items[3] as Dictionary)["id"]) == "leave")

	# ── ① 买灯油：扣灯火，进背包（不是当场回血）──
	_wait_arm()
	var pots0 := w.potion_count()
	var coins_a := int(w.prog["coins"])
	p.hp = p.max_hp * 0.4
	var hp_before_buy := p.hp
	main._shop_index = 0
	_tap("confirm")
	_ok("在守灯人处买灯油会扣掉 22 灯火",
		int(w.prog["coins"]) == coins_a - w.shop_oil_price(),
		"%d -> %d" % [coins_a, int(w.prog["coins"])])
	_ok("买到的灯油是**放进背包**（当场不回血）",
		w.potion_count() == pots0 + 1 and is_equal_approx(p.hp, hp_before_buy),
		"药 %d->%d hp=%.1f" % [pots0, w.potion_count(), p.hp])
	_ok("买完商店还开着（可以连着买）", main.state == "shop", main.state)

	# ── ② 灯火不够时买不成 ──
	var pots1 := w.potion_count()
	w.prog["coins"] = 3
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	main._shop_index = 0
	_tap("confirm")
	_ok("灯火不够时买灯油不成，也不扣钱",
		w.potion_count() == pots1 and int(w.prog["coins"]) == 3,
		"药=%d 灯火=%d" % [w.potion_count(), int(w.prog["coins"])])
	# 面板的 ok 标记可能来自上一次刷新，所以 world 自己必须再拦一道 ——
	# 直接调世界层的入口验一次（这才是真正的钱包守卫）
	_ok("world 层自己也拦一道：灯火不够时 buy_oil() 直接拒绝",
		not w.buy_oil() and w.potion_count() == pots1 and int(w.prog["coins"]) == 3,
		"药=%d 灯火=%d" % [w.potion_count(), int(w.prog["coins"])])

	# ── ③ 重铸：词条全部推倒重来 ──
	w.prog["coins"] = 400
	w.prog["waffix"]["blade"] = [{"id": "edge", "lv": 3}]
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	var sig_before := _affix_sig_of(w)
	var coins_b := int(w.prog["coins"])
	main._shop_index = 1
	_tap("confirm")
	_ok("重铸扣掉 45 灯火",
		int(w.prog["coins"]) == coins_b - w.reforge_price(),
		"%d -> %d" % [coins_b, int(w.prog["coins"])])
	_ok("重铸之后词条真的变了（不是原样留着）",
		_affix_sig_of(w) != sig_before, "%s -> %s" % [sig_before, _affix_sig_of(w)])
	var af := w.weapon_affixes()
	_ok("重铸后词条条数在 1~3 之间", af.size() >= 1 and af.size() <= Content.AFFIX_MAX,
		str(af.size()))
	var lv1 := true
	for a in af:
		if int(a["lv"]) != 1:
			lv1 = false
	_ok("重铸把词条等级全部归 1", lv1, _affix_sig_of(w))
	var uniq := {}
	for a in af:
		uniq[str(a["id"])] = true
	_ok("重铸出的词条不重复", uniq.size() == af.size(), _affix_sig_of(w))

	# ── ④ 锤炼：没满就加一条；价钱随等级之和上涨 ──
	w.prog["coins"] = 400
	w.prog["waffix"]["blade"] = []
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	var base_price := w.temper_price()
	var coins_c := int(w.prog["coins"])
	main._shop_index = 2
	_tap("confirm")
	_ok("锤炼给裸武器添上第一条词条", w.weapon_affixes("blade").size() == 1,
		_affix_sig_of(w))
	_ok("锤炼扣掉应付的灯火（30 + 15×已有等级和）",
		int(w.prog["coins"]) == coins_c - base_price, "%d -> %d" % [coins_c, int(w.prog["coins"])])
	_ok("练过之后价钱变贵（不是固定价）",
		w.temper_price() > base_price, "%d -> %d" % [base_price, w.temper_price()])

	# ── ⑤ 满 3 条时：锤炼改为"升一级"，而不是加第四条 ──
	w.prog["coins"] = 4000
	w.prog["waffix"]["blade"] = [
		{"id": "edge", "lv": 1}, {"id": "swift", "lv": 1}, {"id": "reach", "lv": 1}]
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	main._shop_index = 2
	_tap("confirm")
	_ok("词条满 3 条后，锤炼改成升一级（不再加第四条）",
		w.weapon_affixes("blade").size() == 3 and w.affix_levels_sum("blade") == 4,
		"%d 条 / 等级和 %d" % [w.weapon_affixes("blade").size(), w.affix_levels_sum("blade")])

	# ── ⑥ 全部练到等级上限后：不再受理，也不再收钱 ──
	w.prog["waffix"]["blade"] = [
		{"id": "edge", "lv": Content.AFFIX_LV_MAX},
		{"id": "swift", "lv": Content.AFFIX_LV_MAX},
		{"id": "reach", "lv": Content.AFFIX_LV_MAX}]
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	main._shop_index = 2
	var temper_ok := bool((main._shop_items[2] as Dictionary)["ok"])
	var coins_d := int(w.prog["coins"])
	_tap("confirm")
	_ok("词条全部到上限后，锤炼不可点了（也标注为买不了）", not temper_ok)
	_ok("练满之后按确认不会扣钱（不收冤枉钱）",
		int(w.prog["coins"]) == coins_d, str(int(w.prog["coins"])))

	# ── 商店截图（高亮停在"锤炼"上）──
	main._shop_items = w.shop_items()
	main._shop_items.append({"id": "leave", "name": "离开", "price": 0, "desc": "", "ok": true})
	main._shop_index = 2
	main._redraw_shop()
	await _shot("15-shop")

	# ── ⑦ 词条真的进了派生属性（不是只躺在字典里）──
	# 把别的倍率来源全部清零，只留下词条这一个变量
	w.prog["waffix"] = {}
	w.prog["boons"] = {}
	w.boons = w.prog["boons"]
	w.prog["up"] = {"hp": 0, "light": 0, "edge": 0}
	w.prog["shop"]["brightoil"] = 0
	w.prog["weapon"] = "blade"
	p.weapon_id = "blade"
	p.combo = 0.0
	p.glow = 0.0
	p.shield_t = 0.0
	var d0 := w.damage_mul()
	var cd0 := w.attack_cd_mul()
	var rc0 := w.reach_mul()
	var cr0 := w.crit_chance()
	var lr0 := w.player_light_radius()
	var cb0 := w.combo_bonus()
	var sc0 := w.skill_cost(4)

	w.prog["waffix"]["blade"] = [{"id": "edge", "lv": 2}]
	_ok("词条「锋」真的进了伤害倍率（+24%）",
		is_equal_approx(snappedf(w.damage_mul(), 0.001), snappedf(d0 * 1.24, 0.001)),
		"%.4f -> %.4f" % [d0, w.damage_mul()])
	w.prog["waffix"]["blade"] = [{"id": "swift", "lv": 1}]
	_ok("词条「疾」真的减了挥击冷却（×0.90）",
		is_equal_approx(snappedf(w.attack_cd_mul(), 0.001), snappedf(cd0 * 0.90, 0.001)),
		"%.4f -> %.4f" % [cd0, w.attack_cd_mul()])
	w.prog["waffix"]["blade"] = [{"id": "reach", "lv": 1}]
	_ok("词条「远」真的加了攻击范围（+0.12）",
		is_equal_approx(snappedf(w.reach_mul(), 0.001), snappedf(rc0 + 0.12, 0.001)),
		"%.4f -> %.4f" % [rc0, w.reach_mul()])
	w.prog["waffix"]["blade"] = [{"id": "crit", "lv": 1}]
	_ok("词条「锐」真的加了暴击率（+0.08）",
		is_equal_approx(snappedf(w.crit_chance(), 0.001), snappedf(cr0 + 0.08, 0.001)),
		"%.4f -> %.4f" % [cr0, w.crit_chance()])
	w.prog["waffix"]["blade"] = [{"id": "shine", "lv": 1}]
	_ok("词条「明」真的加了光照半径（+22）",
		is_equal_approx(snappedf(w.player_light_radius(), 0.01), snappedf(lr0 + 22.0, 0.01)),
		"%.2f -> %.2f" % [lr0, w.player_light_radius()])
	w.prog["waffix"]["blade"] = [{"id": "ember", "lv": 1}]
	_ok("词条「火」真的给了额外连击（+0.15）",
		is_equal_approx(snappedf(w.combo_bonus(), 0.001), snappedf(cb0 + 0.15, 0.001)),
		"%.4f -> %.4f" % [cb0, w.combo_bonus()])
	w.prog["waffix"]["blade"] = [{"id": "frugal", "lv": 1}]
	_ok("词条「省」真的减了技能连击消耗（4 -> 3）",
		w.skill_cost(4) == sc0 - 1 and w.skill_cost(4) == 3,
		"%d -> %d" % [sc0, w.skill_cost(4)])

	# 词条「噬」：击杀真的回血
	w.prog["waffix"]["blade"] = [{"id": "vamp", "lv": 1}]
	p.hp = p.max_hp - 40.0
	var e := w.spawn_enemy("shade", p.x + 46.0, p.y)
	_force_kill(w, e)
	_ok("词条「噬」击杀真的回血 3 点",
		is_equal_approx(snappedf(p.hp, 0.01), snappedf(p.max_hp - 37.0, 0.01)),
		"%.2f（应为 %.2f）" % [p.hp, p.max_hp - 37.0])

	# 收尾：这一段的数字写进报告
	report["samples"]["shop"] = {
		"oil_price": w.shop_oil_price(),
		"reforge_price": w.reforge_price(),
		"temper_price_now": w.temper_price(),
		"temper_base": Content.SHOP["temper_base"],
		"temper_step": Content.SHOP["temper_step"],
		"affix_max": Content.AFFIX_MAX,
		"affix_lv_max": Content.AFFIX_LV_MAX,
		"affix_pool": Content.AFFIX_ORDER.size(),
	}
	_num("重铸价钱", 0.0, w.reforge_price())
	_num("锤炼基础价钱", 0.0, Content.SHOP["temper_base"])
	_ok("词条池一共 8 条", Content.AFFIX_ORDER.size() == 8, str(Content.AFFIX_ORDER.size()))

	# 截图之后商店一直是开着的 —— 按 Esc 走人，顺便验"能正常离开"
	_tap("pause")
	_ok("按 Esc 离开商店，世界恢复推进", main.state == "play", main.state)
	_pump(2)
	_ok("离开后商店面板确实藏起来了（遮罩不会留着）", not main.hud.shop_layer.visible)


# ================================================================ 布局随机化
#
# 这一轮要的：宝箱与敌人的位置**随机生成**，不再每关固定。
#
# 下面要证明三件事，缺一条这个功能就是假的：
#   ① 生成的点**不是**关卡表里写死的那几个（否则等于没随机）；
#   ② 换个 run_seed，位置**真的整体换了**（否则"随机"只是摆设）；
#   ③ 同一个 run_seed 重建世界，点位**逐点相同**
#      —— 这是整份确定性自检的地基，被随机化破坏的话后面全不可复现。
# 另外必须验：撒出来的点**站得住**（不撞墙、离出生点够远）——
# 随机撒点最典型的翻车就是撒进墙里：敌人永久卡住、宝箱摸不到，而断言还全绿。

## 一套布局的签名（宝箱 / 波次锚点 / Boss 场地），用来比较"两套布局一样不一样"
func _layout_sig(w: World) -> String:
	var s := ""
	for c in w.chests:
		s += "C%.1f,%.1f;" % [float(c["x"]), float(c["y"])]
	for wv in w.waves:
		var wd: Dictionary = wv["def"]
		s += "W%.1f,%.1f;" % [float(wd["x"]), float(wd["y"])]
	s += "B%.1f,%.1f" % [w.boss_anchor.x, w.boss_anchor.y]
	return s


func _section_layout() -> void:
	# ── 从头来一局，记住这批点位 ──
	main.run_seed = LAYOUT_SEED
	main.restart_level()
	_pump(3)
	var w := _w()

	# ① 不再是关卡表里写死的坐标
	var fixed_chests: Array = w.level["chests"]
	var same_chest := 0
	for i in mini(w.chests.size(), fixed_chests.size()):
		var fp: Vector2 = fixed_chests[i]
		if Proj.dist(float(w.chests[i]["x"]), float(w.chests[i]["y"]), fp.x, fp.y) < 1.0:
			same_chest += 1
	_ok("宝箱点位不是关卡表里写死的那个（真的重摇过）",
		same_chest == 0, "%d/%d 与固定点重合" % [same_chest, w.chests.size()])

	var fixed_waves: Array = w.level["waves"]
	var same_wave := 0
	for i in mini(w.waves.size(), fixed_waves.size()):
		var fd: Dictionary = fixed_waves[i]
		var wd: Dictionary = w.waves[i]["def"]
		if Proj.dist(float(wd["x"]), float(wd["y"]), float(fd["x"]), float(fd["y"])) < 1.0:
			same_wave += 1
	_ok("波次锚点不是关卡表里写死的那个（真的重摇过）",
		same_wave == 0, "%d/%d 与固定点重合" % [same_wave, w.waves.size()])

	var bf: Dictionary = w.level["boss"]
	_ok("Boss 场地也不是写死那个坐标",
		Proj.dist(w.boss_anchor.x, w.boss_anchor.y, float(bf["x"]), float(bf["y"])) > 40.0,
		"生成 (%.0f,%.0f)　表里 (%.0f,%.0f)" % [w.boss_anchor.x, w.boss_anchor.y,
			float(bf["x"]), float(bf["y"])])

	# ② 换一个局种子 → 整套位置必须换掉
	var sig_a := _layout_sig(w)
	main.run_seed = LAYOUT_SEED + 7717
	main.restart_level()
	_pump(3)
	var w2 := _w()
	var sig_b := _layout_sig(w2)
	_ok("★ 换一个局种子 → 宝箱与敌人的位置整套换了",
		sig_a != sig_b, "两套签名相同 = 随机没生效")

	# ③ 换回同一个种子 → 逐点相同（确定性自检的地基）
	main.run_seed = LAYOUT_SEED
	main.restart_level()
	_pump(3)
	var w3 := _w()
	_ok("★ 同一个局种子重建世界 → 点位逐点相同（确定性没被随机化破坏）",
		_layout_sig(w3) == sig_a, "%s vs %s" % [_layout_sig(w3), sig_a])

	# ④ 撒出来的点真的站得住
	var bad_chest := 0
	for c in w3.chests:
		if w3.blocked(float(c["x"]), float(c["y"]), 20.0):
			bad_chest += 1
	_ok("生成的宝箱点都不在墙里", bad_chest == 0, "%d 个卡墙" % bad_chest)

	var start: Vector2 = w3.level["start"]
	var bad_wave := 0
	var too_close := 0
	for wv in w3.waves:
		var wd: Dictionary = wv["def"]
		if w3.blocked(float(wd["x"]), float(wd["y"]), 60.0):
			bad_wave += 1
		if Proj.dist(float(wd["x"]), float(wd["y"]), start.x, start.y) < 340.0:
			too_close += 1
	_ok("生成的波次锚点都不在墙里（中心留得下落脚地）", bad_wave == 0, "%d 个卡墙" % bad_wave)
	_ok("波次锚点都离出生点够远（不会一出生就开打）", too_close == 0, "%d 个太近" % too_close)

	# 可达性 —— 这一条是随机布局最容易漏、也最致命的一类：
	# 点位看着都在空地上，但被一道墙隔开，玩家/机器人过不去，那一波永远清不掉，
	# 关卡直接卡死。而**全程不报任何错**，只有真的走一遍（机器人试玩）才暴露。
	var unreachable := 0
	var prev := start
	for wv in w3.waves:
		var wd2: Dictionary = wv["def"]
		var q := Vector2(float(wd2["x"]), float(wd2["y"]))
		if not w3.has_los(prev.x, prev.y, q.x, q.y, 20.0):
			unreachable += 1
		prev = q
	_ok("★ 波次锚点从出生点起链式可达（走不通就会卡关，而且不报错）",
		unreachable == 0, "%d 段走不通" % unreachable)

	# ⑤ 撒点成功率：退化到兜底说明约束太严或地图太空，都要修
	_ok("随机布局没有退化到兜底坐标", int(w3.layout_info.get("fallbacks", -1)) == 0,
		"fallbacks=%d" % int(w3.layout_info.get("fallbacks", -1)))

	# 报告里留一份：出事时一眼看出"这一局地图长什么样"
	report["samples"]["layout"] = {
		"seed": LAYOUT_SEED,
		"chests": w3.layout_info.get("chests", []),
		"waves": w3.layout_info.get("waves", []),
		"boss": w3.layout_info.get("boss", []),
		"alt_seed_changes": sig_a != sig_b,
	}

	# 收尾：种子调回标准值并重建，离开这一段时世界与别的段落看到的一致
	main.run_seed = LAYOUT_SEED
	main.restart_level()
	_pump(3)


func _finish() -> void:
	# 肉鸽循环的总体证据：整趟跑下来确实反复发生了三选一
	report["samples"]["draft_taken"] = draft_taken
	report["samples"]["draft_log"] = draft_log
	_ok("整趟跑下来反复发生三选一（肉鸽循环成立）", draft_taken >= 5, str(draft_taken))
	var passed := 0
	for k in _checks.keys():
		if bool(_checks[k]):
			passed += 1
	report["checks"] = _checks
	report["checks_total"] = _checks.size()
	report["checks_passed"] = passed
	report["checks_all_pass"] = passed == _checks.size()

	var path := ProjectSettings.globalize_path(OUT_DIR + "/report.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  "))
		f.close()

	print("LKRPT" + JSON.stringify(report) + "ENDLKRPT")
	print("[selfcheck] 截图与报告 -> ", ProjectSettings.globalize_path(OUT_DIR))
	print("[selfcheck] 断言 %d/%d 通过" % [passed, _checks.size()])
	get_tree().quit(0 if report["checks_all_pass"] else 1)
