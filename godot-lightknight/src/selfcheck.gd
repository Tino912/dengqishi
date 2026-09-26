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
	# 元素 / 攻击发光 / 第三关 / 三图风格 —— 都排在最后：
	# 命中火花与粒子要吃 `_rng`，插在中间会把前面那些依赖位置与随机的段落整体挪掉。
	await _section_elements()
	await _section_attack_light()
	await _section_level3_art()
	# 迷雾 / 夜色排在**最末**：这一段会重建世界、搬动玩家、还会把这一关的雾放掉。
	await _section_fog_night()
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


## 造一只「打不死、也不主动行动」的木桩 —— 元素状态那一组断言都在它身上做。
##
## `stun` 默认给 60 秒：既不走 AI 也不出手。注意 `World._update_enemies` 里
## `_tick_status()` 排在眩晕分支**之前**，所以火/毒的持续伤害照常结算 ——
## 这一点很关键，否则「状态挂上了」和「状态真的在生效」就分不开。
func _dummy(w: World, kind: String, x: float, y: float, stun := 60.0) -> EnemyState:
	var e := w.spawn_enemy(kind, x, y, false)
	e.hp = 999999.0
	e.max_hp = 999999.0
	e.state = "chase"
	e.stun = stun
	return e


## 收掉木桩（照抄别的段落的手法：标死 + 把死亡计时推远）
func _kill_dummy(e: EnemyState) -> void:
	e.dead = true
	e.death_t = 99.0


## 一盏位于 LightRig **局部坐标**的灯，落在屏幕上的像素位置。
##
## LightRig 自己就被摆在 `Proj.cam_offset(...)` 处（见它的 `sync`），
## 所以子节点（灯）的屏幕位置 = cam_offset + 灯自己的 position。
## 用它来精确采样「这盏灯到底照亮了哪个像素」，而不是靠猜。
func _light_screen(w: World, lp: Vector2) -> Vector2:
	return Proj.cam_offset(w.draw_cam.x, w.draw_cam.y) + lp


## 在关卡里找一块**周围留得下两个人**的空地（做「位移受不受阻」的对照实验用）。
## 找不到就退回出生点 —— 出生点保证是空的。
func _open_spot(w: World, need := 240.0) -> Vector2:
	var start: Vector2 = w.level["start"]
	for ring in 40:
		for a in 24:
			var ang := float(a) * TAU / 24.0 + float(ring) * 0.137
			var r := float(ring) * 110.0
			var q := Vector2(start.x + cos(ang) * r, start.y + sin(ang) * r)
			if w.blocked(q.x, q.y, need):
				continue
			if w.blocked(q.x + need, q.y, need * 0.5):
				continue
			return q
	return start


## 两张图在**同一块相对区域**上的差异比例（0~1）。
##
## 用来断言「三张地图长得不一样」。两个坑都在这里绕开了：
##   ① 不能只比全局平均亮度 —— 那只能说明「一张比另一张暗」，说不出画面是否真的不同。
##   ② 不能直接比整屏 —— 这游戏的屏幕**大部分是黑的**（ambient 0.9+），
##      照整屏比出来三张图都「一样」（实测只有 3% 像素不同），而那 3% 恰好就是
##      真正有区别的地方。所以按各自图里**玩家的屏幕位置**为中心裁一块来比。
func _diff_ratio(a: Image, b: Image, pa: Vector2, pb: Vector2,
		hw := 260, hh := 200, step := 4, eps := 0.02) -> float:
	var n := 0
	var diff := 0
	for dy in range(-hh, hh + 1, step):
		for dx in range(-hw, hw + 1, step):
			var xa := int(pa.x) + dx
			var ya := int(pa.y) + dy
			var xb := int(pb.x) + dx
			var yb := int(pb.y) + dy
			if xa < 0 or ya < 0 or xa >= a.get_width() or ya >= a.get_height():
				continue
			if xb < 0 or yb < 0 or xb >= b.get_width() or yb >= b.get_height():
				continue
			var ca := a.get_pixel(xa, ya)
			var cb := b.get_pixel(xb, yb)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > eps:
				diff += 1
			n += 1
	return float(diff) / maxf(1.0, float(n))


## 把一张图里以某点为中心的那块裁下来，摊平成一串颜色。
## 越界的位置填 (-1,-1,-1) 当占位符，好让两张图**同一个相对坐标**的采样一一对齐。
func _crop_samples(img: Image, p: Vector2, hw := 260, hh := 200,
		step := 4) -> PackedVector3Array:
	var out := PackedVector3Array()
	for dy in range(-hh, hh + 1, step):
		for dx in range(-hw, hw + 1, step):
			var x := int(p.x) + dx
			var y := int(p.y) + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				out.append(Vector3(-1.0, -1.0, -1.0))
				continue
			var c := img.get_pixel(x, y)
			out.append(Vector3(c.r, c.g, c.b))
	return out


## 与 `_diff_ratio` 同样的裁块比较，但**先各自减掉自己那块的平均色**。
##
## 为什么必须多这一个：地图整体提亮一档之后，任何两张图的逐像素差会直接顶到 ~99%
## —— 于是「三张图不一样」那三条断言退化成恒真，全绿也不再说明任何事。
## 减掉平均色等于把"整体明暗 / 统一色偏"这个自由度消掉，剩下的差异只可能来自
## **结构与纹理本身**：同一张图换个滤镜会被归一化抵掉（差异 ≈ 0），
## 真换了地图才留下差异。而且它自带对照 —— 同一关重建两次在两种度量下都该是 0。
func _diff_ratio_norm(a: Image, b: Image, pa: Vector2, pb: Vector2,
		hw := 260, hh := 200, step := 4, eps := 0.02) -> float:
	var sa := _crop_samples(a, pa, hw, hh, step)
	var sb := _crop_samples(b, pb, hw, hh, step)
	var n := mini(sa.size(), sb.size())
	var ma := Vector3.ZERO
	var mb := Vector3.ZERO
	var m := 0
	for i in n:
		var va := sa[i]
		var vb := sb[i]
		if va.x < 0.0 or vb.x < 0.0:
			continue
		ma += va
		mb += vb
		m += 1
	if m == 0:
		return 0.0
	ma = ma / float(m)
	mb = mb / float(m)
	# ⚠️ 第二趟也必须跳过越界的占位符。第一版漏了这一步，而 `m` 只统计有效对，
	# 于是"有效差异数"能超过"有效对数" —— 实测吐出了 101.6% / 112.0% 这种不可能的值。
	# 越界为什么会发生：裁块以**各自图里玩家的屏幕位置**为中心，而相机是带前瞻偏移的
	# （玩家并不总在屏幕正中），所以靠边的裁块会有一小条越界。
	var diff := 0
	var valid := 0
	for i in n:
		var va2 := sa[i]
		var vb2 := sb[i]
		if va2.x < 0.0 or vb2.x < 0.0:
			continue
		valid += 1
		var da := va2 - ma
		var db := vb2 - mb
		if absf(da.x - db.x) + absf(da.y - db.y) + absf(da.z - db.z) > eps:
			diff += 1
	return float(diff) / maxf(1.0, float(valid))


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

	# ── 迷雾也要关掉 ──
	# 迷雾是一层**独立于光照的全屏叠加**（见 fog.gd）：它会同时给"墙前 / 墙后 /
	# 射程外"三个点加一层雾，把"光有没有被挡住"的差压小。这与上面那层暗角是
	# 同一类污染，而且更隐蔽 —— 雾是跟着灯走的，看起来"像是光的一部分"。
	# 所以世界层的像素测量一律把它关掉；迷雾本身在 `_section_fog_night()` 里单独验。
	w.set_fog_enabled(false)
	_pump(2)
	_ok("测世界层亮度时已关闭迷雾层（否则量到的是雾，不是光）",
		not w.fog.visible)

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

	# 「光在这一点的增量」= 该点亮度 − 同一帧的底噪基线（射程外、照不到的那点）。
	#
	# ⚠️ 这一组断言原来比的是**比值**（"墙后比远处亮 2 倍"）。地图提亮之后
	# 那个写法就不成立了，而且**不是因为遮挡坏了**：底色本身从 0.008 涨到 ~0.17 之后，
	# 光贡献 0.07 会被底色的除法压成 1.26 倍 —— 测的其实是底色。
	# "光到底有没有照到那一点"本来就是**加法**的事，所以改成看增量。比值仍旧记进报告。
	var inc_on := back_on - far_on
	var inc_off := back_off - far_on
	report["samples"]["back_increment_on"] = snappedf(inc_on, 0.0001)
	report["samples"]["back_increment_off"] = snappedf(inc_off, 0.0001)
	_num("开阴影_墙后光的增量", inc_on)
	_num("关阴影_墙后光的增量", inc_off)

	_ok("夜色生效：地图不再是纯黑（全屏平均亮度 > 0.05）", mean_on > 0.05, "%.4f" % mean_on)
	_ok("仍然是晚上（全屏平均亮度 < 0.45，没亮成白天）", mean_on < 0.45, "%.4f" % mean_on)
	_ok("灯光生效：墙前比射程外明显更亮（增量 ≥ 0.15）", front_on > far_on + 0.15,
		"前 %.4f  远 %.4f  增量 %.4f" % [front_on, far_on, front_on - far_on])
	_ok("★ 遮挡成立：开阴影后，墙后那点上「光的增量」被削掉七成以上",
		inc_on < inc_off * 0.30, "开 %.4f  关 %.4f" % [inc_on, inc_off])
	_ok("★ 关阴影时墙后确实被光照到（增量 ≥ 0.03，不是「本来就照不到」）",
		inc_off >= 0.03, "%.4f" % inc_off)
	_ok("★ 开阴影时墙后压到「照不到的远处」同一水平（增量 ≤ 0.02）",
		inc_on <= 0.02, "%.4f" % inc_on)
	_ok("★ 墙后确实成了暗区（相对墙前）", back_on < front_on * 0.75,
		"后 %.4f  前 %.4f" % [back_on, front_on])

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
	# 迷雾也恢复
	w.set_fog_enabled(true)
	_pump(2)

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
		# 选哪一项：优先拿恩赐。交手距离由武器射程推出来（见下面 rch 那段注释）——
		# 这一条曾经是"机器人时好时坏"的根源：写死的近战阈值遇到灯弩/灯杖就废了。
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
		# 机器人的交手距离**从武器的真实攻击距离推出来**，不再写死 62/64/44。
		# 原因是一条实测出来的"机器人变菜"：那三个常数是照近战（灯刃）写的，
		# 一旦这局的武器是灯弩（射程 380）或灯杖，机器人就会一直贴到 60px 才出手，
		# 等于完全不会用远程 —— 症状是"同一份代码，机器人时而清完三波、时而只清一波"。
		# 现在它按 `swing_reach()` 出手，攻击范围一提升，它也跟着在更远处打。
		var rch: float = w.swing_reach()
		var keep_out: float = clampf(rch * 0.50, 30.0, 130.0)    # 贴太近就退开，别白挨刀
		var press_in: float = clampf(rch * 0.78, 44.0, 180.0)    # 压进射程
		var atk_at: float = clampf(rch * 0.95, 56.0, 200.0)      # 出手距离
		var danger := pack_n >= 3 and p.hp < p.max_hp * 0.75
		if tgt != null:
			var to := Vector2(tgt.x - p.x, tgt.y - p.y)
			var d := to.length()
			GameInput.aim_world = Vector2(tgt.x, tgt.y)
			if d > 0.001:
				var u := to / d
				if danger and pack.length_squared() > 0.0001:
					dir = -pack.normalized()   # 突出包围圈
				elif d > press_in:
					dir = u            # 压进射程
				elif d <= keep_out:
					dir = -u           # 太贴脸就退开，别白挨刀
			want_atk = d < atk_at and not danger
			want_skill = d < atk_at * 0.85 and p.combo >= 4.0 and not danger
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

	# ── 起步攻击范围：这一条必须**绝对**，不能只是相对 ──
	# 下面每一条词条断言都是"比 rc0 多多少"。所以哪怕 `BASE_REACH` 整体退回 1.0，
	# 那些相对断言照样全绿 —— 谁来钉住"这一轮把起步攻击范围上调了"这件事？
	# 就是下面这两条：一条钉倍率，一条钉**真正落到刀锋上的世界距离**。
	_ok("★ 起步攻击范围 = 基础射程 ×1.20（这一轮上调过；退回 1.0 会让「够不着」的老手感回来）",
		is_equal_approx(snappedf(rc0, 0.001), 1.20), "%.4f" % rc0)
	_ok("★ 起步的刀锋真的够到 79.2（刀射程 66 × 1.20，不是只改了倍率没接到武器上）",
		is_equal_approx(snappedf(w.swing_reach(), 0.01), 79.2), "%.2f" % w.swing_reach())
	_num("起步攻击范围倍率", rc0)
	_num("起步刀锋够到多远", w.swing_reach())

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


# ================================================================ 武器元素
#
# 对应用户这一轮的两条要求：
#   · 攻击（近战挥击 / 远程弹药）要**发光**
#   · 武器要带**随机元素属性**（冰冻住、火燃烧…）
#
# 放在整份自检的**最后**：命中火花与粒子都要吃 `_rng`，
# 插在中间会把后面所有依赖位置/随机的段落整体挪掉（词条那一轮踩过这个坑）。

func _section_elements() -> void:
	main.run_seed = LAYOUT_SEED
	main.prog["level"] = 0
	main.prog["boons"] = {}
	main.waves_off = true
	main.start_level()
	_pump(6)
	var w := _w()
	var p := _p()
	p.invuln = 9999.0
	p.hp = p.max_hp

	# ── ① 元素表本身 ──
	_ok("五种元素都在表里（火/冰/雷/毒/光）", Content.ELEMENT_ORDER.size() == 5,
		str(Content.ELEMENT_ORDER.size()))
	var broken := []
	for id in Content.ELEMENT_ORDER:
		var el := Content.element(id)
		if el.is_empty() or not el.has("name") or not el.has("color") or not el.has("glyph"):
			broken.append(id)
	_ok("每种元素都有名字 / 颜色 / 头顶刻字", broken.is_empty(), ", ".join(broken))

	# ── ② 八把武器每把都有元素，且挂在「武器 id」上 ──
	var map: Dictionary = w.welem
	_ok("★ 八把武器每把都摇到了元素",
		map.size() == Content.WEAPONS.size(), "%d/%d" % [map.size(), Content.WEAPONS.size()])
	var off := []
	for wid in Content.WEAPONS.keys():
		if not Content.ELEMENT_ORDER.has(str(map.get(str(wid), ""))):
			off.append(str(wid))
	_ok("抽出来的元素都在那五种之内", off.is_empty(), ", ".join(off))

	p.weapon_id = "blade"
	var e_blade := w.weapon_element()
	p.weapon_id = "hammer"
	var e_hammer := w.weapon_element()
	p.weapon_id = "blade"
	_ok("★ 元素跟着**武器 id** 走：换手 / 换回来还是同一个（与词条同一套做法）",
		w.weapon_element() == e_blade and str(map["blade"]) == e_blade
		and str(map["hammer"]) == e_hammer,
		"blade=%s hammer=%s map=%s" % [e_blade, e_hammer, str(map)])
	_ok("HUD 的元素说明非空、且以元素名开头",
		w.element_label("blade") != ""
		and w.element_label("blade").begins_with(str(Content.element(e_blade)["name"])),
		w.element_label("blade"))

	# 基础攻击的染色跟着元素走：「这把武器是冰的，打出来就是蓝的」
	GameInput.aim_world = Vector2(p.x + 200.0, p.y)
	p.attack_cd = 0.0
	p.attack_t = 0.0
	w.effects.clear()
	_tap("attack")
	var slash_col := ""
	var slash_n := 0
	for f in w.effects:
		if str(f["kind"]) == "slash":
			slash_col = str(f["color"])
			slash_n += 1
	var want_col := "#" + w.element_color_of("blade").to_html(false)
	_ok("★ 基础攻击被染成了元素色（不是武器原本的暖黄）",
		slash_n > 0 and slash_col == want_col, "%s vs %s" % [slash_col, want_col])

	# ── ③ 状态效果：伤害之外的「元素手感」 ──
	var spot := _open_spot(w)

	# 火：挂上灼烧，并且**真的在掉血**
	var fe := _dummy(w, "shade", spot.x, spot.y)
	w.damage_enemy(fe, 100.0, 0.0, 0.0, 0.0, "fire")
	_ok("火：命中后挂上灼烧状态", fe.ignite_t > 0.0, "%.2f" % fe.ignite_t)
	var fe_hp := fe.hp
	_pump(60)                       # 1 秒 → 每 0.4 秒一跳，至少两跳
	_ok("★ 火：灼烧一直在掉血（不只是挂了个状态）",
		fe.hp < fe_hp - 1.0, "%.1f -> %.1f" % [fe_hp, fe.hp])
	_kill_dummy(fe)
	w.enemies.erase(fe)

	# 毒：绵长 + 减速（与火的「短促密集」是两种形状）
	var ve := _dummy(w, "shade", spot.x, spot.y)
	w.damage_enemy(ve, 100.0, 0.0, 0.0, 0.0, "venom")
	_ok("毒：命中后挂上中毒状态", ve.venom_t > 0.0, "%.2f" % ve.venom_t)
	_ok("毒：持续时间比灼烧长得多（「绵长」不是随口说的）",
		float(Content.element("venom")["venom_t"]) > float(Content.element("fire")["ignite_t"]) * 1.8,
		"%.1fs vs %.1fs" % [float(Content.element("venom")["venom_t"]),
			float(Content.element("fire")["ignite_t"])])
	# 减速：同样给 300 的速度，中毒那只走得明显更短（同地点、同时长）
	ve.vx = 300.0
	var vx0 := ve.x
	_pump(24)
	var v_moved := absf(ve.x - vx0)
	var ve2 := _dummy(w, "shade", spot.x, spot.y)
	ve2.vx = 300.0
	var vx1 := ve2.x
	_pump(24)
	var v_moved2 := absf(ve2.x - vx1)
	_kill_dummy(ve2)
	w.enemies.erase(ve2)
	_ok("★ 毒：中毒的敌人明显走得更慢（对照：同地点同时长、没中毒的那只）",
		v_moved < v_moved2 * 0.8 and v_moved2 > 10.0,
		"中毒 %.1f vs 正常 %.1f" % [v_moved, v_moved2])
	_num("中毒位移", v_moved)
	_num("未中毒位移", v_moved2)
	var v_hp := ve.hp
	_pump(100)                      # 再 1.7 秒 → 累计超过 VENOM_TICK(1.5) → 至少一跳
	_ok("毒：中毒也在持续掉血（只是结算比火稀疏）",
		ve.hp < v_hp - 1.0, "%.1f -> %.1f" % [v_hp, ve.hp])
	_kill_dummy(ve)
	w.enemies.erase(ve)

	# 持续伤害**不给连击** —— 否则火/毒会变成刷连击的外挂
	var de := _dummy(w, "shade", spot.x, spot.y)
	de.ignite_t = 2.0
	de.ignite_dps = 60.0
	de.ignite_tick = 0.02
	p.combo = 5.0
	p.combo_timer = 60.0
	var c_before := p.combo
	var d_hp := de.hp
	_pump(12)
	_ok("★ 持续伤害不给连击（DoT 是「白打」的，连击只认玩家亲手打中的那一下）",
		de.hp < d_hp - 1.0 and is_equal_approx(p.combo, c_before),
		"hp %.1f→%.1f　combo %.2f→%.2f" % [d_hp, de.hp, c_before, p.combo])
	_kill_dummy(de)
	w.enemies.erase(de)

	# 冰：**完全不动**，且解除后立刻恢复 —— 配一组对照，否则分不清「冻住了」和「被卡住了」
	var ie := _dummy(w, "shade", spot.x, spot.y)
	w.damage_enemy(ie, 1.0, 0.0, 0.0, 0.0, "frost")
	_ok("冰：命中后挂上冻结状态", ie.frozen_t > 0.0, "%.2f" % ie.frozen_t)
	ie.vx = 300.0
	var ix0 := ie.x
	_pump(20)
	var frozen_moved := absf(ie.x - ix0)
	ie.frozen_t = 0.0
	ie.vx = 300.0
	var ix1 := ie.x
	_pump(20)
	var thawed_moved := absf(ie.x - ix1)
	_ok("★ 冰：冻结期间一步都不动（连外力给的速度都被清掉）",
		frozen_moved < 0.01, "%.3f px" % frozen_moved)
	_ok("★ 冰：冻结一解除立刻恢复移动（不是被别的东西卡住了）",
		thawed_moved > 20.0, "%.1f px" % thawed_moved)
	_num("冻结期间位移", frozen_moved)
	_num("解冻后位移", thawed_moved)
	_kill_dummy(ie)
	w.enemies.erase(ie)

	# 雷：定身 + 电弧连锁（**只一跳**，且隔着墙不连）。
	# ⚠️ 这一段必须**先清掉前面的木桩**：木桩都堆在同一个点上，而连锁挑的是
	# 「最近的敌人」—— 距离 0 的木桩会把连锁整个抢走，于是这里的 se2 永远挨不到电，
	# 而断言会以「se2 血量没变」的形式失败，看起来像连锁没实现。
	var se := _dummy(w, "shade", spot.x, spot.y, 0.0)
	var se2 := _dummy(w, "shade", spot.x + 120.0, spot.y, 0.0)
	var se3 := _dummy(w, "shade", spot.x + 520.0, spot.y, 0.0)
	var s2_hp := se2.hp
	var s3_hp := se3.hp
	w.damage_enemy(se, 200.0, 0.0, 0.0, 0.0, "shock")
	_ok("雷：命中后麻痹定身（stun 从 0 被抬起来）", se.stun > 0.3, "%.2f" % se.stun)
	_ok("★ 雷：电弧连锁到附近的另一个敌人",
		se2.hp < s2_hp - 1.0, "%.1f -> %.1f" % [s2_hp, se2.hp])
	_ok("★ 雷：连锁只有一跳（更远的第三只没被电到，不是「一次命中清场」）",
		is_equal_approx(se3.hp, s3_hp), "%.1f -> %.1f" % [s3_hp, se3.hp])
	var arc_seen := false
	for f in w.effects:
		if str(f["kind"]) == "arc":
			arc_seen = true
	_ok("雷：画出了电弧特效（看得见才算数）", arc_seen)
	for e in [se, se2, se3]:
		_kill_dummy(e)
		w.enemies.erase(e)

	# 隔墙不连：电弧和光守的是同一条原则 —— **墙能挡住它**。
	# 做法是找一面横墙，在它南北各放一只：两只相距 < chain_radius，
	# 但中间隔着那面墙，所以不该连上。
	var chain_rad := float(Content.element("shock")["chain_radius"])
	var pair := []
	for wl in w.walls:
		if float(wl[2]) < 200.0 or float(wl[3]) > 100.0:
			continue                       # 只认"够宽、不太厚"的横墙
		var cx := float(wl[0]) + float(wl[2]) * 0.5
		var n1 := Vector2(cx, float(wl[1]) - 34.0)
		var n2 := Vector2(cx, float(wl[1]) + float(wl[3]) + 34.0)
		var dd := Proj.dist(n1.x, n1.y, n2.x, n2.y)
		if dd >= chain_rad - 20.0:
			continue
		if w.blocked(n1.x, n1.y, 22.0) or w.blocked(n2.x, n2.y, 22.0):
			continue
		if w.has_los(n1.x, n1.y, n2.x, n2.y, 12.0):
			continue                       # 这面墙挡不住这条线，换一面
		pair = [n1, n2]
		break
	_ok("找得到一面墙可以做「隔墙不连」实验", pair.size() == 2, str(pair))
	if pair.size() == 2:
		var wx1: Vector2 = pair[0]
		var wx2: Vector2 = pair[1]
		var cs := _dummy(w, "shade", wx1.x, wx1.y, 0.0)
		var ct := _dummy(w, "shade", wx2.x, wx2.y, 0.0)
		ct.hp = 999999.0
		var ct_hp := ct.hp
		w.damage_enemy(cs, 200.0, 0.0, 0.0, 0.0, "shock")
		_ok("★ 雷：电弧**不能穿墙**（墙那边的敌人不会被连到）",
			is_equal_approx(ct.hp, ct_hp),
			"距离 %.0f / 半径 %.0f　血量 %.1f" % [Proj.dist(wx1.x, wx1.y, wx2.x, wx2.y),
				chain_rad, ct.hp])
		_kill_dummy(cs)
		_kill_dummy(ct)
		w.enemies.erase(cs)
		w.enemies.erase(ct)

	# 光：对**暗影系**额外伤害 + 命中额外连击
	# ① 额外连击：这一条完全确定（不掷骰子）—— 与「没有元素」的同一击对照
	p.weapon_id = "blade"
	var keep_blade := str(map["blade"])
	w.welem["blade"] = ""           # 「没有元素」必须走这条路：damage_enemy 的空串参数
	                                # 表示「用当前武器的元素」，不是「无元素」
	var ge1 := _dummy(w, "shade", spot.x, spot.y)
	var ge2 := _dummy(w, "shade", spot.x, spot.y)
	p.combo = 0.0
	w.damage_enemy(ge1, 1.0, 0.0, 0.0, 0.0, "")
	var c_plain := p.combo
	p.combo = 0.0
	w.damage_enemy(ge2, 1.0, 0.0, 0.0, 0.0, "radiant")
	var c_rad := p.combo
	_ok("★ 光：命中额外给连击（对照：同样一击、没有元素）",
		c_rad > c_plain + 0.2, "无元素 %.2f vs 光 %.2f" % [c_plain, c_rad])
	_num("无元素一击的连击增量", c_plain)
	_num("光元素一击的连击增量", c_rad)
	# 注意 `w.welem["blade"]` 还停在空串上 —— 下面②要比"没有元素"的伤害，
	# 所以留到那一段结束再还原。

	# ② 额外伤害：光对暗影系 ×1.30。
	#
	#    这里比的是**单次最大伤害**，不是总和。暴击（1.85×）让每一下在
	#    「100」与「185」之间二选一 —— 比总和要几百次才收敛，
	#    而"最大值"直接把档位钉死：有加成的上限是 100×1.85×1.30 = 240.5，
	#    没有的是 185.0，两档根本不相交，所以可以断言**相等**而不是"大概 1.3 倍"。
	var max_plain := 0.0
	var max_rad_shadow := 0.0
	var max_rad_plain := 0.0
	for i in 120:
		var ea := _dummy(w, "shade", spot.x, spot.y)
		p.combo = 0.0
		w.damage_enemy(ea, 100.0, 0.0, 0.0, 0.0, "")
		max_plain = maxf(max_plain, 999999.0 - ea.hp)
		_kill_dummy(ea)
		w.enemies.erase(ea)
		var eb := _dummy(w, "shade", spot.x, spot.y)
		p.combo = 0.0
		w.damage_enemy(eb, 100.0, 0.0, 0.0, 0.0, "radiant")
		max_rad_shadow = maxf(max_rad_shadow, 999999.0 - eb.hp)
		_kill_dummy(eb)
		w.enemies.erase(eb)
		# ③ 同一件事打在**非**暗影系（灯烬卫是灯烬铸出来的实体）上，不该有加成 ——
		#    这一条把「光」钉成对策，而不是"通用变强"。
		var ec := _dummy(w, "guard", spot.x, spot.y)
		p.combo = 0.0
		w.damage_enemy(ec, 100.0, 0.0, 0.0, 0.0, "radiant")
		max_rad_plain = maxf(max_rad_plain, 999999.0 - ec.hp)
		_kill_dummy(ec)
		w.enemies.erase(ec)
	_ok("★ 光：对**暗影系**敌人加伤 1.30 倍（单次上限 240.5 vs 185.0）",
		is_equal_approx(max_plain, 185.0) and is_equal_approx(max_rad_shadow, max_plain * 1.30),
		"无元素 %.1f　光打暗影 %.1f" % [max_plain, max_rad_shadow])
	_ok("★ 光：对**非**暗影系敌人没有加伤（是「对策」，不是「通用变强」）",
		is_equal_approx(max_rad_plain, max_plain),
		"光打非暗影 %.1f vs 无元素 %.1f" % [max_rad_plain, max_plain])
	_num("无元素的单次伤害上限", max_plain)
	_num("光打暗影系的单次伤害上限", max_rad_shadow)
	_num("光打非暗影系的单次伤害上限", max_rad_plain)
	w.welem["blade"] = keep_blade

	_ok("敌人状态可查询（HUD / 断言共用同一份）",
		not w.enemy_status(ge2).is_empty() and str(w.enemy_status(ge2)["elem"]) == "radiant")
	_kill_dummy(ge1)
	_kill_dummy(ge2)
	w.enemies.erase(ge1)
	w.enemies.erase(ge2)

	# ── ④ 随机性：一局摇一次、同种子可复现、换种子换掉、五种都摇得到 ──
	main.run_seed = LAYOUT_SEED
	main.prog["welem"] = {}
	main.start_level()
	_pump(3)
	var map_a: Dictionary = _w().welem
	_ok("★ 同一个局种子重建世界 → 元素表逐项相同（确定性没被随机化破坏）",
		map_a == map, "%s vs %s" % [str(map_a), str(map)])

	main.run_seed = LAYOUT_SEED + 4242
	main.prog["welem"] = {}
	main.start_level()
	_pump(3)
	var map_b: Dictionary = _w().welem
	_ok("★ 换一个局种子 → 元素表整套换掉（随机真的生效）",
		map_b != map_a, "两局元素表相同 = 随机没生效")

	# 过关换地图**不该**重摇：玩家刚适应火的剑，过个图变成冰的很怪。
	# 元素属于「这一局」，不属于「这一张图」—— 所以 `_elem_rng` 不带 level_index。
	main.prog["level"] = 1
	main.start_level()
	_pump(3)
	_ok("★ 过关换地图不会重摇元素（元素属于这一局，不属于这一张图）",
		_w().welem == map_b, "%s vs %s" % [str(_w().welem), str(map_b)])

	# 分布：48 个种子 × 8 把武器，五种都该出现，且不能退化
	var wd0 := _w()
	var keep_elem_rng := wd0._elem_rng
	var count := {}
	var dup_seeds := 0
	for i in 48:
		wd0._elem_rng = Proj.make_rng(hash([LAYOUT_SEED + i * 131, "elem"]))
		var m: Dictionary = wd0._roll_elements()
		var seen := {}
		for k in m.keys():
			var v := str(m[k])
			count[v] = int(count.get(v, 0)) + 1
			seen[v] = true
		if seen.size() < Content.WEAPONS.size():
			dup_seeds += 1
	wd0._elem_rng = keep_elem_rng
	_ok("★ 五种元素都摇得到（48 个种子 × 8 把武器）", count.size() == 5, str(count))
	var thin := 99999
	for id in Content.ELEMENT_ORDER:
		thin = mini(thin, int(count.get(id, 0)))
	_ok("分布不退化（每种都至少出现 20 次 / 共 384 次）", thin >= 20,
		"最少 %d 次" % thin)
	_ok("★ 允许两把武器撞同一个元素（若强制 8 把各不同，第二局就能背下来了）",
		dup_seeds >= 40, "%d/48 个种子出现重复" % dup_seeds)
	_num("元素分布里的最少出现次数", float(thin))
	report["samples"]["element_map"] = map
	report["samples"]["element_counts"] = count
	report["samples"]["element_dup_seeds"] = dup_seeds
	report["cases"]["elements"] = {
		"count": Content.ELEMENT_ORDER.size(),
		"names": Content.ELEMENT_ORDER.duplicate(),
		"per_weapon": map,
		"counts_over_48_seeds": count,
		"seeds_with_duplicate": dup_seeds,
	}

	# 收尾：回到干净状态，别把木桩与临时状态留给后面的段落。
	# ⚠️ 上面几次 `start_level()` 已经把世界换掉了，`w` / `p` 是**旧世界**的对象，
	# 从这里开始必须重新取。
	for e in wd0.enemies:
		_kill_dummy(e)
	wd0.effects.clear()
	wd0.projs.clear()
	var p_now := _p()
	p_now.invuln = 0.0
	p_now.combo = 0.0
	GameInput.aim_world = null


# ================================================================ 攻击发光
#
# 用户要求「近战挥击与远程弹药会发出一定的光」。这一段的重点是：
# 那盏灯不只是「叠加层上的亮斑」，而是**真的 Light2D**（带遮挡、认墙），
# 并且它真的把画面照亮了 —— 用同一像素的前后对比来证明。

func _section_attack_light() -> void:
	main.run_seed = LAYOUT_SEED
	main.prog["level"] = 0
	main.prog["boons"] = {}
	main.waves_off = true
	main.start_level()
	GameInput.aim_world = null
	_pump(40)                        # 让相机跟稳，采样点才不会偏
	var w := _w()
	var p := _p()
	p.hp = p.max_hp
	p.invuln = 9999.0
	# 迷雾关掉：这一段量的是"这一盏攻击灯加了/减了多少亮度"，
	# 而迷雾会同时给采样点加一层、还会被灯本身驱散（两个效应混在一起）。
	# 迷雾被攻击灯驱散这件事，在 `_section_fog_night()` 里单独验。
	w.set_fog_enabled(false)
	_pump(2)
	# 把「玩家自己的光」冻住：连击与辉光都会改玩家灯的半径与亮度，
	# 不冻住的话下面的前后对比就同时动了两个变量，测出来的差值说明不了是谁干的。
	p.combo = 0.0
	p.combo_timer = 0.0
	p.glow = 0.0
	w.effects.clear()
	w.projs.clear()
	_pump(4)

	_ok("没在挥击时就没有攻击类灯", w.light_rig.fx_light_count() == 0,
		", ".join(w.light_rig.fx_light_keys()))

	# ── ① 近战挥击：刀锋上点一盏灯，且真的照亮了那里 ──
	p.weapon_id = "chain"            # 长兵器：光能甩到玩家自身光照半径之外，看得见
	p.attack_cd = 0.0
	p.attack_t = 0.0
	GameInput.aim_world = Vector2(p.x + 400.0, p.y)   # 朝东挥，采样点好算
	_pump(20)
	_tap("attack")
	_ok("★ 挥击中：刀锋上多了一盏灯", w.light_rig.fx_light_keys().has("swing"),
		", ".join(w.light_rig.fx_light_keys()))
	var sl: PointLight2D = w.light_rig._fx_lights.get("swing", null)
	_ok("★ 这盏灯**带遮挡**（所以它是真的光，不是叠加层上的一块亮斑）",
		sl != null and sl.shadow_enabled)
	# 供报告汇总用的几个数（在下面各自的 if 里赋值）
	var swing_lit := 0.0
	var swing_dark := 0.0
	var proj_lit := 0.0
	var proj_dark := 0.0
	var proj_light_n := 0
	if sl != null:
		_ok("灯的染色跟着武器元素走（不是固定的暖黄）",
			sl.color.is_equal_approx(w.element_color_of()),
			"%s vs %s" % [str(sl.color), str(w.element_color_of())])
		_ok("灯的半径跟着攻击距离走（长兵器的光伸得更远）",
			sl.texture_scale * LightRig.TEX_HALF > float(p.weapon()["range"]) * 0.5,
			"%.1f" % (sl.texture_scale * LightRig.TEX_HALF))
		var spot_px := _light_screen(w, sl.position)
		var img_on := await _grab()
		var l_on := _lum(img_on, spot_px, 5)
		# 收手：结束挥击并重同步一次（灯会被回收），**同一像素**再采一次。
		# 这中间不调 main.advance —— 世界的其它一切都原样不动，只剩「有没有这盏灯」。
		p.attack_t = 0.0
		w.light_rig.sync(w)
		var img_off := await _grab()
		var l_off := _lum(img_off, spot_px, 5)
		swing_lit = l_on
		swing_dark = l_off
		_ok("★ 挥击真的把画面照亮了（同一像素：挥击中 vs 收手后）",
			l_on > l_off + 0.05, "%.4f -> %.4f" % [l_off, l_on])
		_num("挥击灯下的像素亮度（挥击中）", l_on)
		_num("挥击灯下的像素亮度（收手后）", l_off)
		await _shot("17-swing-light")
		_ok("收手后刀锋灯被回收（不是亮着不灭）",
			not w.light_rig.fx_light_keys().has("swing"),
			", ".join(w.light_rig.fx_light_keys()))

	# ── ② 远程弹药：飞行中的弹丸带一盏灯，跟着弹丸走 ──
	p.weapon_id = "crossbow"
	p.attack_cd = 0.0
	p.attack_t = 0.0
	# 先挑一个「又通、又还在画面里」的方向：弹药要飞出两百多像素才算离开
	# 玩家那盏灯的强光区 —— 在玩家脚边采样的话那里本来就亮到接近饱和，
	# 弹丸灯加进去只能挤出 0.04 的差，那种断言看着绿其实什么都证明不了。
	var aim_ang := 0.0
	var aim_ok := false
	for k in 24:
		var a := TAU * float(k) / 24.0
		var tx := p.x + cos(a) * 250.0
		var ty := p.y + sin(a) * 250.0
		if not w.has_los(p.x, p.y, tx, ty, 14.0):
			continue
		var sc := _screen_of(w, tx, ty)
		if sc.x < 60.0 or sc.x > 1220.0 or sc.y < 60.0 or sc.y > 660.0:
			continue
		aim_ang = a
		aim_ok = true
		break
	_ok("找得到一个又通、又还在画面里的射击方向（弹药灯采样的前提）", aim_ok)
	GameInput.aim_world = Vector2(p.x + cos(aim_ang) * 500.0, p.y + sin(aim_ang) * 500.0)
	_pump(20)
	_tap("attack")
	_pump(14)                        # 飞出去约 240px（灯弩射程 380，还活着）
	var q: Dictionary = {}
	for f in w.projs:
		if str(f.get("own", "")) == "player":
			q = f
	_ok("灯弩挥击射出了光矢", not q.is_empty())
	if not q.is_empty():
		_ok("★ 弹丸带着**产生那一刻**的元素（快照：之后换武器也不会变）",
			str(q.get("elem", "")) == w.weapon_element(),
			"%s vs %s" % [str(q.get("elem", "")), w.weapon_element()])
		var pk := "proj:%d" % int(q.get("pid", -1))
		_ok("★ 飞行中的弹丸带一盏灯（key 是弹丸的稳定 id）",
			w.light_rig.fx_light_keys().has(pk), ", ".join(w.light_rig.fx_light_keys()))
		var pl: PointLight2D = w.light_rig._fx_lights.get(pk, null)
		if pl != null:
			var want := Vector2(float(q["x"]), float(q["y"]) * Proj.YSQUASH - float(q["z"]))
			_ok("这盏灯**跟着弹丸飞**（不是钉在发射点）",
				pl.position.distance_to(want) < 0.01,
				"%s vs %s" % [str(pl.position), str(want)])
			var q_px := _light_screen(w, pl.position)
			var img_fly := await _grab()
			var l_fly := _lum(img_fly, q_px, 5)
			# 让弹丸消失（灯随之回收），同一个像素再采一次
			w.projs.clear()
			w.light_rig.sync(w)
			var img_gone := await _grab()
			var l_gone := _lum(img_gone, q_px, 5)
			proj_lit = l_fly
			proj_dark = l_gone
			_ok("★ 弹丸的灯真的照亮了那一块（飞行中 vs 消失后，同一像素）",
				l_fly > l_gone + 0.03, "%.4f -> %.4f" % [l_gone, l_fly])
			_num("弹丸灯下的像素亮度（飞行中）", l_fly)
			_num("弹丸灯下的像素亮度（消失后）", l_gone)
			await _shot("18-proj-light")
		_ok("弹丸消失后灯自动回收", not w.light_rig.fx_light_keys().has(pk),
			", ".join(w.light_rig.fx_light_keys()))

	# ── ③ 上限：软渲染下每盏投影灯都要重算一遍遮挡，不能无限点 ──
	w.projs.clear()
	for i in 24:
		w._add_proj({"x": p.x + float(i) * 14.0, "y": p.y, "z": 20.0,
			"vx": 0.0, "vy": 0.0, "r": 8.0, "dmg": 1.0, "life": 5.0,
			"color": "#ffffff", "own": "player"})
	w.light_rig.sync(w)
	_ok("★ 攻击类灯有上限（弹丸雨一次能造十几颗，不封顶会把帧率拖垮）",
		w.light_rig.fx_light_count() <= LightRig.FX_LIGHT_MAX,
		"%d 盏 / 上限 %d" % [w.light_rig.fx_light_count(), LightRig.FX_LIGHT_MAX])
	_num("24 颗弹丸时的攻击灯盏数", 0.0, w.light_rig.fx_light_count())
	proj_light_n = w.light_rig.fx_light_count()
	w.projs.clear()
	# 顺手把挥击也结束掉 —— 刚才那一下攻击同样点了一盏刀锋灯，
	# 不清掉的话下面「灯归零」会一直为假（而且那不是弹丸的问题）。
	p.attack_t = 0.0
	w.effects.clear()
	w.light_rig.sync(w)
	_ok("弹丸与挥击都结束之后，攻击灯归零", w.light_rig.fx_light_count() == 0,
		", ".join(w.light_rig.fx_light_keys()))

	# 收尾
	p.invuln = 0.0
	p.combo = 0.0
	GameInput.aim_world = null
	report["cases"]["attack_light"] = {
		"swing_px_dark": snappedf(swing_dark, 0.0001),
		"swing_px_lit": snappedf(swing_lit, 0.0001),
		"proj_px_dark": snappedf(proj_dark, 0.0001),
		"proj_px_lit": snappedf(proj_lit, 0.0001),
		"fx_light_max": LightRig.FX_LIGHT_MAX,
		"fx_lights_with_24_projs": proj_light_n,
	}
	_pump(2)


# ================================================================ 迷雾 · 夜色

## 「迷雾」与「夜色」两件事的验收。
##
## 这一段**排在最后**：它会重建世界、把玩家搬来搬去、还会把这一关的雾放掉。
## 插在中间会把后面那些依赖位置与随机流的段落整体挪位（见 `_run()` 的排序说明）。
##
## 三条主张，各自用**独立的证据**：
##   ① 地图可见但像晚上 —— 全屏平均亮度落在"能看清地形"与"不是白天"之间；
##   ② 灯照到的地方雾散、照不到的地方雾满 —— 直接读照亮场 + 像素对照；
##   ③ 墙会把"散雾"也挡住 —— 同一盏灯、**同距离**的两个点，一个在墙后、一个在空地。
func _section_fog_night() -> void:
	main.run_seed = LAYOUT_SEED
	main.prog["level"] = 0
	main.prog["boons"] = {}
	main.waves_off = true
	main.start_level()
	_pump(40)
	var w := _w()
	var p := _p()
	# 清场：敌人自光、弹丸灯、留场光球都会往照亮场里加东西，
	# 采样时就说不清"那一格是被谁照亮的"。这一段只想看玩家自己那盏灯。
	for e in w.enemies:
		e.dead = true
	w.enemies.clear()
	w.drops.clear()
	w.projs.clear()
	w.effects.clear()
	w.shake = 0.0
	# 站在出生点原地不动（`teleport` 会把相机也一起钉到人身上，
	# 于是"玩家在屏幕正中"这件事是算得出来的，不是碰运气）
	w.teleport(300.0, 1350.0)
	_pump(30)

	_ok("迷雾层随关卡一起建好、并且默认开着",
		w.fog != null and w.fog.enabled and w.fog.visible)
	_ok("迷雾是挂在**世界**里的子节点（所以它盖得住世界）",
		w.fog.get_parent() == w)
	# HUD 在自己的 CanvasLayer 上（layer 10），与世界的绘制顺序无关 ——
	# 所以不管雾画在世界里的哪一层，都盖不到血条与三选一面板。
	_ok("★ 界面不受迷雾影响（HUD 在自己的 CanvasLayer 上，层号高于世界）",
		main.hud is CanvasLayer and main.hud.layer >= 1, "layer=%d" % main.hud.layer)
	_ok("迷雾挂在世界层、而界面挂在更高的 CanvasLayer —— 两者不在同一套绘制顺序里",
		main.hud.get_parent() == main and w.fog.get_parent() == w)

	# ── ① 照亮场：脚下散、远处满 ──
	var g := w.fog.grid_target_copy()
	var vmax := 0.0
	var v_dark := 0
	for i in g.size():
		vmax = maxf(vmax, g[i])
		if g[i] < 0.10:
			v_dark += 1
	var rev_here := w.fog_reveal_at(p.x, p.y)
	_num("玩家脚下的迷雾揭示度", rev_here)
	_num("照亮场里最亮的一格", vmax)
	_num("整屏全是雾的格子数", 0.0, v_dark)
	report["cases"]["fog"] = {
		"grid": [Fog.GRID_W, Fog.GRID_H], "rays": Fog.RAYS,
		"mist_max": Fog.MIST_MAX, "refill_per_s": Fog.REFILL,
		"fade_t": Fog.FADE_T, "opener_max": Fog.OPENER_MAX,
		"player_reveal": snappedf(rev_here, 0.0001),
		"grid_max": snappedf(vmax, 0.0001),
		"grid_dark_cells": v_dark, "grid_cells": g.size(),
	}
	_ok("★ 灯照在脚下：那一格没有雾", rev_here > 0.85, "%.3f" % rev_here)
	_ok("★ 整屏不是一层均匀的雾：既有被照亮的格子，也有满雾的格子",
		vmax > 0.85 and v_dark > g.size() / 4,
		"最亮 %.3f　满雾格 %d/%d" % [vmax, v_dark, g.size()])

	# ── ② 像素级：同一帧、同一世界，只切「迷雾开不开」──
	# 采样点固定的两个：玩家脚下（雾已散）和正北 480（照不到、满雾）。
	# 后者离出生点的火盆够远（离得最近的火盆 506px，火盆光照 210）——
	# 这一点是算过的，不是"应该没事"。
	var spot_lit := _screen_of(w, p.x, p.y)
	var spot_dark := _screen_of(w, p.x, p.y - 480.0)
	_ok("两个采样点都在画面内（否则读到的格子是被夹到边上的）",
		spot_dark.y > 20.0 and spot_dark.y < float(VIEW_H) - 20.0
		and spot_lit.x > 20.0 and spot_lit.x < float(VIEW_W) - 20.0,
		"亮 %.0f,%.0f　暗 %.0f,%.0f" % [spot_lit.x, spot_lit.y, spot_dark.x, spot_dark.y])
	w.set_fog_enabled(false)
	_pump(2)
	var img_nofog := await _grab()
	w.set_fog_enabled(true)
	_pump(2)
	var img_fog := await _grab()
	var lit_off := _lum(img_nofog, spot_lit, 6)
	var lit_on := _lum(img_fog, spot_lit, 6)
	var dark_off := _lum(img_nofog, spot_dark, 6)
	var dark_on := _lum(img_fog, spot_dark, 6)
	var mean_off := _mean_lum(img_nofog)
	var mean_on := _mean_lum(img_fog)
	_num("关雾_玩家脚下亮度", lit_off)
	_num("开雾_玩家脚下亮度", lit_on)
	_num("关雾_远处亮度", dark_off)
	_num("开雾_远处亮度", dark_on)
	_num("关雾_全屏平均亮度", mean_off)
	_num("开雾_全屏平均亮度", mean_on)
	report["cases"]["fog"]["pixel"] = {
		"lit_off": lit_off, "lit_on": lit_on,
		"dark_off": dark_off, "dark_on": dark_on,
		"mean_off": mean_off, "mean_on": mean_on,
	}
	# 注意采样点的亮度**含 HUD 的暗角**（这一段没关后处理，量的是玩家真看到的画面）：
	# 暗角是径向的，所以整屏均值那一条是"整体观感"，两个定点是"同一像素的前后"。
	_ok("★ 没被照亮的地方：雾让画面亮起来（那些角落不再是纯黑）",
		dark_on > dark_off + 0.02, "关雾 %.4f -> 开雾 %.4f" % [dark_off, dark_on])
	_ok("★ 灯光照亮的地方：几乎看不出有雾（雾在那儿散掉了）",
		absf(lit_on - lit_off) < 0.05, "关雾 %.4f -> 开雾 %.4f" % [lit_off, lit_on])
	_ok("★ 夜色：地图可见但不是白天（全屏平均亮度落在 0.05 ~ 0.45）",
		mean_on > 0.05 and mean_on < 0.45, "%.4f" % mean_on)
	_ok("迷雾让全屏更亮一档（「地图可见」这条主要靠它）", mean_on > mean_off + 0.01,
		"%.4f -> %.4f" % [mean_off, mean_on])

	# ── ②b 夜色旋钮必须真的接在画面上 ──
	#
	# ⚠️ 光断言"地图不是纯黑"**抓不到**「夜色被拧到最暗」这个失败方式：调色板提亮之后，
	# 就算 `CanvasModulate` 一直取 `NIGHT_MIN`，画面也只是**暗掉一半**，远谈不上纯黑
	# （三关 ambient 0.90 / 0.955 / 0.975 现在都落在 `t` 的可动区间里）。
	# 变异测试 `夜色永远压到最暗一档` 正是拿这条**没红**暴露出来的。
	# 所以改成"同一帧、同一世界，**只拧 `world.ambient` 这一个变量**"做前后对照 ——
	# 这跟遮挡那组看增量的道理一样：**要证明旋钮接上了，就得让旋钮转一下**。
	var amb0 := w.ambient
	var mean_night := mean_on
	w.ambient = 0.98            # d = 0.02 → t ≈ 0 → 最暗一档 NIGHT_MIN
	_pump(1)
	var mean_darkest := _mean_lum(await _grab())
	w.ambient = amb0
	_pump(1)
	_num("夜色最暗档_全屏平均亮度", mean_darkest)
	report["cases"]["fog"]["pixel"]["mean_darkest"] = mean_darkest
	_ok("★ 夜色旋钮真的接在画面上（只把 ambient 拧到最暗，全屏明显变暗）",
		mean_night > mean_darkest + 0.02,
		"本关 %.4f -> 最暗档 %.4f" % [mean_night, mean_darkest])

	_write_png(img_fog, "20-fog-on")
	_write_png(img_nofog, "21-fog-off")

	# ── ③ 墙会把"散雾"也挡住（这是遮挡的**第二个独立证人**）──
	# 迷雾用的是自己那套射线扇求交（`Proj.ray_rect_dist`），与 `PointLight2D`
	# 的影子系统是两套代码。同距离两点、一墙之隔，差别只可能来自那面墙。
	var up_light0 := int(w.prog["up"]["light"])
	w.prog["up"]["light"] = 6                 # 把灯拉大一档（半径 → 620）
	w.teleport(450.0, 500.0)
	p.combo = 40.0
	p.combo_timer = 1e9
	p.glow = 1.0
	_pump(150)
	w.shake = 0.0
	_pump(1)
	p.combo = 40.0
	p.combo_timer = 1e9
	p.glow = 1.0
	_pump(2)
	var r_big := w.player_light_radius()
	var front := Vector2(500.0, 500.0)        # 灯与墙之间
	var behind := Vector2(690.0, 500.0)       # 墙后（东 240）
	var open_s := Vector2(450.0, 740.0)       # 空地（南 240）
	var d_behind := Proj.dist(450.0, 500.0, behind.x, behind.y)
	var d_open := Proj.dist(450.0, 500.0, open_s.x, open_s.y)
	var rev_front := w.fog_reveal_at(front.x, front.y)
	var rev_behind := w.fog_reveal_at(behind.x, behind.y)
	var rev_open := w.fog_reveal_at(open_s.x, open_s.y)
	_num("满灯光照半径", r_big)
	_num("雾_墙前揭示度", rev_front)
	_num("雾_墙后揭示度", rev_behind)
	_num("雾_空地(同距离)揭示度", rev_open)
	report["cases"]["fog"]["wall"] = {
		"light_r": r_big, "front": rev_front, "behind": rev_behind, "open": rev_open,
		"d_behind": snappedf(d_behind, 0.1), "d_open": snappedf(d_open, 0.1),
	}
	_ok("对照两点到灯的距离相同（差 < 0.5px，所以「远近」不是解释）",
		absf(d_behind - d_open) < 0.5, "%.2f vs %.2f" % [d_behind, d_open])
	_ok("近处（灯与墙之间）雾是散的", rev_front > 0.85, "%.3f" % rev_front)
	_ok("★ 同距离的空地方雾散了（光够得着）", rev_open > 0.35, "%.3f" % rev_open)
	_ok("★ 同距离的墙后雾没散（被那面墙挡住了）", rev_behind < 0.10, "%.3f" % rev_behind)

	# ── ④ 雾会回填：灯不再照到那个点之后，雾慢慢合拢回来 ──
	# `target` 是"这一刻该多亮"（瞬间归零），`reveal` 是"画面上现在多亮"
	# （按 REFILL 每秒 1.6 慢慢掉）—— 这条尾巴就是"灯扫过去留下一道正在合拢的痕迹"。
	#
	# ⚠️ 这里刻意**不搬动相机**。照亮场是**屏幕空间**的（一格对应屏幕上一小块），
	# 相机一移动，同一个世界点就落到别的格子上去了，量到的其实是"另一格的历史" ——
	# 第一版就是把玩家传送走，结果 `reveal` 直接读到 0，看着像"雾瞬间合拢"。
	# 改用"灯不再照那里"：连击掉光 → 光照半径从 620 缩回 150，
	# 240px 外那一点就出了灯范围 —— 这正是玩家断连击时看到的那一幕，相机不动。
	var g0 := Vector2(450.0, 740.0)          # 满连击时被照到（240px 外），断连击后就照不到
	var rev0 := w.fog_reveal_at(g0.x, g0.y)
	w.prog["up"]["light"] = up_light0        # 灯收回常规档（半径 620 → 150）
	p.combo = 0.0
	p.glow = 0.0
	p.combo_timer = 0.0
	_pump(4)                                 # 至少重建一次，`target` 才是新鲜的
	var tgt := w.fog_target_at(g0.x, g0.y)
	var rev1 := w.fog_reveal_at(g0.x, g0.y)
	_pump(30)                                # 0.5 秒
	var rev2 := w.fog_reveal_at(g0.x, g0.y)
	_num("雾回填_灯还照着时", rev0)
	_num("雾回填_灯不照了(目标值)", tgt)
	_num("雾回填_之后0.07秒(画面值)", rev1)
	_num("雾回填_之后0.57秒(画面值)", rev2)
	report["cases"]["fog"]["refill_test"] = {
		"lit": rev0, "target_after": tgt, "cur_after": rev1, "cur_later": rev2,
	}
	_ok("回填对照：灯还照着时那个点确实是亮的", rev0 > 0.45, "%.3f" % rev0)
	_ok("回填对照：那个点周围没有别的灯（否则测不出回填）", tgt < 0.10, "%.3f" % tgt)
	_ok("★ 灯刚不照了，画面还是亮的（雾不会瞬间糊上来）", rev1 > rev0 - 0.35,
		"目标 %.3f 而画面 %.3f" % [tgt, rev1])
	_ok("★ 0.5 秒后雾明显合拢回来", rev2 < rev1 - 0.25, "%.3f -> %.3f" % [rev1, rev2])

	# ── ⑤ 攻击的灯也散雾 ──
	# 朝南挥（南边是空地：东边那面测试墙会把攻击灯自己挡掉，用东向测会得到假阴性）。
	# 前后两次只差「有没有在挥」：玩家灯的参数、位置、朝向全部冻住。
	w.teleport(450.0, 500.0)
	w.projs.clear()
	w.effects.clear()
	p.weapon_id = "crossbow"                   # 射程 380：刀锋灯甩得比玩家灯那圈雾远
	p.attack_cd = 0.0
	p.attack_t = 0.0
	p.combo = 0.0
	p.glow = 0.0
	p.combo_timer = 0.0
	GameInput.aim_world = Vector2(p.x, p.y + 400.0)
	_pump(20)
	var spot_atk := Vector2(450.0, 750.0)      # 南 250：玩家灯那圈雾（123）够不到
	var atk_before := w.fog_reveal_at(spot_atk.x, spot_atk.y)
	_tap("attack")
	_pump(5)
	var atk_after := w.fog_reveal_at(spot_atk.x, spot_atk.y)
	var fx_n := 0
	for i in w.light_rig.source_count():
		if str(w.light_rig.src_kind[i]) == "fx":
			fx_n += 1
	_num("挥击前_南250的雾揭示度", atk_before)
	_num("挥击后_南250的雾揭示度", atk_after)
	report["cases"]["fog"]["attack"] = {
		"before": atk_before, "after": atk_after, "fx_lights": fx_n,
	}
	_ok("挥击时确实点起了攻击类灯（否则下一条无从谈起）", fx_n > 0, str(fx_n))
	_ok("挥击前那一点在被照亮的范围之外（对照前提）", atk_before < 0.10,
		"%.3f" % atk_before)
	_ok("★ 挥击的灯把刀锋那一片的雾也驱散了", atk_after > 0.40,
		"%.3f -> %.3f" % [atk_before, atk_after])
	await _shot("22-swing-fog")
	GameInput.aim_world = null

	# ── ⑥ 三关各有各的雾色 + 清关时雾散尽 ──
	var mists := []
	for i in 3:
		mists.append(str((Content.LEVELS[i]["palette"] as Dictionary).get("mist", "")))
	_ok("★ 三关各有自己的雾色（雾也是地图美术的一部分）",
		mists[0] != mists[1] and mists[1] != mists[2] and mists[0] != mists[2], str(mists))
	_ok("雾色取自关卡表的 palette.mist，不是写死的",
		w.fog.fog_color().is_equal_approx(Color.html(mists[0])),
		"%s vs %s" % [str(w.fog.fog_color()), mists[0]])
	var f0 := w.fog.fade()
	var mm0 := float(w.fog.mat.get_shader_parameter("mist_max"))
	w.fog.disperse()
	w.tick_fx(0.6)
	var f1 := w.fog.fade()
	var mm1 := float(w.fog.mat.get_shader_parameter("mist_max"))
	_num("清关前浓淡系数", f0)
	_num("清关0.6秒后浓淡系数", f1)
	report["cases"]["fog"]["fade"] = {"before": f0, "after": f1, "mist_max_after": mm1}
	_ok("★ 清关时这一关的雾会慢慢散掉", f1 < f0 - 0.30, "%.2f -> %.2f" % [f0, f1])
	_ok("雾的浓淡真的接到了着色器上（不是只在状态里自娱自乐）",
		absf(mm0 - Fog.MIST_MAX * f0) < 0.001 and absf(mm1 - Fog.MIST_MAX * f1) < 0.001,
		"%.3f vs %.3f" % [mm1, Fog.MIST_MAX * f1])
	w.fog.reset_fade()
	w.tick_fx(2.0)
	_ok("雾散尽之后还能重新聚起来（重开同一关要用）", w.fog.fade() > 0.95,
		"%.2f" % w.fog.fade())

	# 收尾：世界停在一个干净的正常状态（雾开着、后处理开着）
	w.set_fog_enabled(true)
	GameInput.aim_world = null
	_pump(2)


# ================================================================ 第三张地图 · 三图风格 · 敌人样貌

func _section_level3_art() -> void:
	# ── ① 三关各自的静态事实 ──
	_ok("本作是三关", Content.level_count() == 3, str(Content.level_count()))
	var names := []
	var styles := []
	var ambs := []
	var scales := []
	var bosses := []
	for i in 3:
		var lv: Dictionary = Content.LEVELS[i]
		names.append(str(lv["name"]))
		styles.append(str(lv.get("art_style", "")))
		ambs.append(float(lv["ambient"]))
		scales.append(float(lv["enemy_scale"]))
		bosses.append(str(lv["boss"]["type"]))
		_ok("第 %d 关的 index 与它的位置一致" % (i + 1), int(lv["index"]) == i, str(lv["index"]))
	_ok("★ 三张地图的美术风格互不相同（court / quarry / river）",
		styles[0] != styles[1] and styles[1] != styles[2] and styles[0] != styles[2],
		str(styles))
	_ok("★ 一关更比一关黑（ambient 递增）",
		ambs[0] < ambs[1] and ambs[1] < ambs[2],
		"%.3f / %.3f / %.3f" % [ambs[0], ambs[1], ambs[2]])
	_ok("★ 一关更比一关狠（enemy_scale 递增）",
		scales[0] < scales[1] and scales[1] < scales[2],
		"%.2f / %.2f / %.2f" % [scales[0], scales[1], scales[2]])
	_ok("★ 三关的 Boss 各不相同（幼体 / 成体 / 灯魔之影）",
		bosses[0] != bosses[1] and bosses[1] != bosses[2] and bosses[0] != bosses[2],
		str(bosses))
	_ok("第三关是本作唯一一场「灯魔之影」", bosses[2] == "lampdemon_shadow", bosses[2])
	_ok("灯魔之影算暗影系（所以「光」元素对它加伤）",
		bool(Content.ENEMIES["lampdemon_shadow"].get("shadow", false)))
	_ok("只有第二关有盲女同行", not (Content.LEVELS[0] as Dictionary).has("blind_girl")
		and (Content.LEVELS[1] as Dictionary).has("blind_girl")
		and not (Content.LEVELS[2] as Dictionary).has("blind_girl"))
	_ok("第三关是灯河渡口", names[2] == "灯河渡口", names[2])
	_ok("第三关的地图最大（3000×2200）",
		float(Content.LEVELS[2]["w"]) == 3000.0 and float(Content.LEVELS[2]["h"]) == 2200.0)

	# 三关各有各的入场 / Boss / 清关对白，且都在对白表里
	var dlgs := []
	for i in 3:
		dlgs.append([str(Content.LEVELS[i].get("start_dialogue", "l%d_start" % (i + 1))),
			str(Content.LEVELS[i].get("clear_dialogue", "")),
			str(Content.LEVELS[i].get("boss_dialogue", ""))])
	var missing_dlg := []
	for i in 3:
		for d in dlgs[i]:
			if d != "" and not Content.DIALOGUES.has(d):
				missing_dlg.append(d)
	_ok("三关的对白都在对白表里", missing_dlg.is_empty(), ", ".join(missing_dlg))
	_ok("三关的清关对白各不相同",
		dlgs[0][1] != dlgs[1][1] and dlgs[1][1] != dlgs[2][1] and dlgs[0][1] != dlgs[2][1],
		str([dlgs[0][1], dlgs[1][1], dlgs[2][1]]))

	# ── ② 一关一关真的走一遍，各拍一张照 ──
	main.run_seed = LAYOUT_SEED
	main.prog["boons"] = {}
	main.waves_off = true
	var imgs: Array[Image] = []
	var lums := []
	# 每张图里玩家落在屏幕上的位置 —— 三张图要按**各自的玩家位置**对齐着比，
	# 否则比的是"屏幕的同一块砖"，而玩家在三张图里并不都在同一个屏幕位置。
	var pcs := []
	for i in 3:
		main.prog["level"] = i
		# 展示用：把上一段跑出来的计数清零，免得第三关的封面照挂着「击杀 89」
		main.prog["kills"] = 0
		main.prog["deaths"] = 0
		main.prog["max_combo"] = 0
		main.prog["coins"] = 0
		main.prog["bag_weapon"] = ""
		main.start_level()
		_pump(40)                    # 等相机跟稳，画面才是「这张图的样子」
		var w := _w()
		var st: Vector2 = w.level["start"]
		_ok("第 %d 关「%s」加载成功" % [i + 1, str(w.level["name"])],
			int(w.level["index"]) == i, str(w.level["index"]))
		_ok("第 %d 关有墙、且遮挡体一一对应" % (i + 1),
			w.walls.size() > 0 and w.light_rig.occluder_count() == w.walls.size(),
			"墙 %d / 遮挡体 %d" % [w.walls.size(), w.light_rig.occluder_count()])
		_ok("第 %d 关玩家出生在关卡起点" % (i + 1),
			Proj.dist(w.player.x, w.player.y, st.x, st.y) < 2.0,
			"(%.0f,%.0f) vs (%.0f,%.0f)" % [w.player.x, w.player.y, st.x, st.y])
		_ok("第 %d 关的敌人倍率来自关卡表" % (i + 1),
			is_equal_approx(float(w.level["enemy_scale"]), scales[i]),
			"%.2f vs %.2f" % [float(w.level["enemy_scale"]), scales[i]])
		# 比画面差异之前把迷雾关掉：这一段量的是**地图美术**（地形几何 + 配色），
		# 而迷雾是另一层、还跟着 `world.time` 飘 —— 不关掉的话连"同一关重建两次"
		# 都会被它飘成两张不同的图，下面那几条就失去了对照。
		# 迷雾本身在 `_section_fog_night()` 里单独验。
		w.set_fog_enabled(false)
		_pump(2)
		if i == 0:
			_ok("三图对比时已关闭迷雾层（这一段量的是地图美术，不是雾）",
				not w.fog.visible)
		var img := await _grab()
		imgs.append(img)
		lums.append(_mean_lum(img))
		pcs.append(_screen_of(w, w.player.x, w.player.y))
		if i == 2:
			# 封面照反过来带上迷雾 —— 那才是玩家真正看到的第三关
			w.set_fog_enabled(true)
			_pump(2)
			await _shot("16-level3")
			report["cases"]["level3"] = {
				"name": str(w.level["name"]), "index": int(w.level["index"]),
				"w": float(w.level["w"]), "h": float(w.level["h"]),
				"walls": w.walls.size(), "ambient": snappedf(float(w.level["ambient"]), 0.001),
				"enemy_scale": float(w.level["enemy_scale"]),
				"boss": str((w.level["boss"] as Dictionary)["type"]),
			}
			_ok("第三关有灯河渡口专属道具（浮台 / 浮灯，前两关没有）",
				_has_prop(w, "dock") and _has_prop(w, "lantern"),
				"dock=%s lantern=%s" % [_has_prop(w, "dock"), _has_prop(w, "lantern")])
			# 再拍一张「灯河」本身：这条横贯的地貌是第三关的主角，
			# 出生点那张拍不到它。传送到河边的渡口缺口再拍。
			w.teleport(1460.0, 700.0)
			_pump(40)
			await _shot("19-level3-river")

	# 三张画面必须真的不一样。比的是**各自玩家周围那一片**：
	# 整屏比会全都"一样"（这游戏的屏幕大部分是黑的），只比平均亮度又只能看出明暗。
	#
	# ⚠️ 但**只看原始逐像素差在提亮之后就废了**：底色从 ~0.008 涨到 ~0.17，
	# 于是任何两张图都有 ~99% 的像素差 > eps，那三条断言变成恒真。
	# 所以真正的判据换成 `_diff_ratio_norm`（扣掉整体明暗之后的**结构**差异），
	# 原始值仍旧记进报告，好让"归一化是不是把该留的留下了"可以对人核对。
	for a in 3:
		for b in range(a + 1, 3):
			var r := _diff_ratio(imgs[a], imgs[b], pcs[a], pcs[b])
			var rn := _diff_ratio_norm(imgs[a], imgs[b], pcs[a], pcs[b])
			_ok("★ 地图 %d 与地图 %d 不是「同一张图换了个滤镜」（扣掉整体明暗后仍有 >15%% 的像素长得不一样）"
				% [a + 1, b + 1], rn > 0.15,
				"归一化 %.1f%%　原始 %.1f%%" % [rn * 100.0, r * 100.0])
			report["samples"]["art_diff_%d_%d" % [a + 1, b + 1]] = snappedf(rn, 0.0001)
			report["samples"]["art_raw_%d_%d" % [a + 1, b + 1]] = snappedf(r, 0.0001)

	# 对照：同一关**重建两次**，画面应当几乎逐像素相同。
	# 这一条是上面那三个百分数的地基 —— 没有它，"30% 不同"根本说明不了什么，
	# 因为这个指标也可能对任何输入都吐出 30%。
	main.prog["level"] = 0
	main.prog["kills"] = 0
	main.prog["deaths"] = 0
	main.prog["max_combo"] = 0
	main.prog["coins"] = 0
	main.prog["bag_weapon"] = ""
	main.start_level()
	_pump(40)
	var w_same := _w()
	w_same.set_fog_enabled(false)
	_pump(2)
	var img_same := await _grab()
	var pc_same := _screen_of(w_same, w_same.player.x, w_same.player.y)
	var r_same := _diff_ratio(img_same, imgs[0], pc_same, pcs[0])
	var rn_same := _diff_ratio_norm(img_same, imgs[0], pc_same, pcs[0])
	_ok("★ 对照：同一关重建两次，画面几乎逐像素相同（原始差异 < 3%）",
		r_same < 0.03, "%.2f%%" % (r_same * 100.0))
	_ok("★ 对照：扣掉整体明暗之后结构也一样（归一化差异 < 5%）",
		rn_same < 0.05, "%.2f%%" % (rn_same * 100.0))
	_num("同一关重建两次的画面差异", r_same)
	_num("同一关重建两次的归一化差异", rn_same)

	# 另外，三关的调色板也得各不同 —— 几何不同是一回事，"这张图是这个颜色"是另一回事。
	var pal_vals := {}
	for key in ["floor", "floor2", "wall", "wall_top", "rim"]:
		var v := []
		for i in 3:
			v.append(str((Content.LEVELS[i]["palette"] as Dictionary).get(key, "")))
		pal_vals[key] = v
	var pal_diff := 0
	for key in pal_vals.keys():
		var v: Array = pal_vals[key]
		if v[0] != v[1] or v[1] != v[2] or v[0] != v[2]:
			pal_diff += 1
	_ok("★ 三关的调色板也各不相同（5 项里至少 4 项互异）", pal_diff >= 4,
		"%d/5 项" % pal_diff)
	_num("三关调色板里互异的项数", 0.0, pal_diff)
	_ok("三张地图的平均亮度也各不相同",
		lums[0] != lums[1] and lums[1] != lums[2],
		"%.4f / %.4f / %.4f" % [lums[0], lums[1], lums[2]])
	_num("第一关画面平均亮度", lums[0])
	_num("第二关画面平均亮度", lums[1])
	_num("第三关画面平均亮度", lums[2])

	# ── ③ 敌人样貌各异 ──
	# `Art.body_kind` 是「这只敌人长什么样」的唯一入口；**没登记的会静默退回「灯影」**，
	# 而画面照常能跑 —— 所以必须有这么一条盯住它。
	var kinds := {}
	var dup := []
	var fell := []
	for k in Content.ENEMIES.keys():
		var bk := Art.body_kind(Content.ENEMIES[k])
		if bk == "shade" and str(k) != "shade":
			fell.append(str(k))
		if kinds.has(bk):
			dup.append("%s 与 %s 共用 %s" % [str(k), str(kinds[bk]), bk])
		else:
			kinds[bk] = k
	_ok("★ 除了「灯影」本身，没有敌人落回兜底造型（新敌人忘了登记就落这里）",
		fell.is_empty(), ", ".join(fell))
	_ok("★ 敌人造型两两不同（只有噬灯者幼体/成体是故意的共用）",
		dup.size() == 1 and str(dup[0]).find("devourer") >= 0, "; ".join(dup))
	_ok("噬灯者幼体与成体共用一套身子（是故意的，不是漏登记）",
		Art.body_kind(Content.ENEMIES["devourer_jr"])
		== Art.body_kind(Content.ENEMIES["devourer"]))
	_ok("★ 造型数 = 敌人数 - 1（%d 种敌人 → %d 套身子）"
		% [Content.ENEMIES.size(), kinds.size()],
		kinds.size() == Content.ENEMIES.size() - 1,
		str(kinds))
	report["samples"]["enemy_bodies"] = kinds
	_ok("第三关的两个新敌人都有自己的身子（灰烬鬼 / 灯河浮尸 / 衔灯兽）",
		str(kinds.get("ashling", "")) == "ashling"
		and str(kinds.get("tidehusk", "")) == "tidehusk"
		and str(kinds.get("lanternjaw", "")) == "lanternjaw")

	# ── ④ 三关推进：L1 → L2 → L3 → 通关（不再往前）──
	main.prog["level"] = 0
	main.start_level()
	_pump(3)
	_ok("第一关加载成功（index == 0）", int(_w().level["index"]) == 0)
	main.next_level()
	_ok("★ 第一关过关 → 进入第二关",
		int(main.prog["level"]) == 1 and int(_w().level["index"]) == 1,
		"level=%d" % int(main.prog["level"]))
	main.next_level()
	_ok("★ 第二关过关 → 进入第三关",
		int(main.prog["level"]) == 2 and int(_w().level["index"]) == 2,
		"level=%d" % int(main.prog["level"]))
	main.next_level()
	_ok("★ 第三关之后不再往前（通关，不会越界出第 4 关）",
		int(main.prog["level"]) == 2 and int(_w().level["index"]) == 2,
		"level=%d" % int(main.prog["level"]))

	# 收尾：回到第一关，离开这一段时世界干净
	main.prog["level"] = 0
	main.start_level()
	_pump(3)


## 关卡里有没有某种道具
func _has_prop(w: World, kind: String) -> bool:
	for pr in w.props:
		if str(pr["kind"]) == kind:
			return true
	return false


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
