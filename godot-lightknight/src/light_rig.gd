class_name LightRig
extends Node2D
## LightRig —— 遮挡光照系统。这是整个迁移的核心理由：
## Web 版用 Canvas 合成手搓光照（全屏压暗 → destination-out 挖洞 → 叠暖光），
## 那套做法**没有遮挡关系，光会穿墙**。这里用 Godot 的 Light2D + LightOccluder2D，
## 墙会真的把光挡住——对"黑暗里只有灯骑士周围亮"这个核心机制是质变。
##
## 三件事：
##   1. CanvasModulate   全局压暗（对应 Web 版的 rgba(fog, ambient) 全屏填充）
##   2. PointLight2D     玩家灯火 + 敌人自光 + 火盆 + 灯塔
##   3. LightOccluder2D  每面墙一个遮挡体
##
## 坐标：本节点自身被摆到"相机偏移"处，因此所有子节点都用
##   「屏幕相对坐标」= (x, y * YSQUASH)，也就是 z = 0 时的屏幕位置。
## 这样遮挡体的多边形可以直接照搬第二探针里验证过的那套屏幕几何。

## 遮挡体底边削掉的屏幕像素数。第二探针的结论：贴"画出来的整体轮廓"、
## 只削底边 16px。削多少 = 墙脚亮多高（受光高度 ≈ 削底量 − 1~3px）；
## 削 8px 在侧光下完全亮不起来，削 0（= 贴轮廓）则墙脚全黑。
const OCC_TRIM := 16.0

## 灯的贴图边长（半径 = 半边长 = 128）
const TEX_N := 256
const TEX_HALF := TEX_N / 2.0

## 攻击类短命灯的上限（挥击 1 盏 + 弹丸/留场物共用剩下的）。
## 软渲染（llvmpipe）下每盏投影灯都要重算一遍遮挡，弹丸雨能一次开几十盏 —— 
## 所以宁可不点，也不能让帧率掉下去。
const FX_LIGHT_MAX := 6

var cm: CanvasModulate
var player_light: PointLight2D
var goal_light: PointLight2D

var _occluders: Array[LightOccluder2D] = []
var _brazier_lights := {}     # prop index -> PointLight2D
var _enemy_lights := {}       # enemy id -> PointLight2D
## 「攻击类」的短命灯：挥击、飞行中的弹丸、留场的光球/光柱。
## key 是**稳定字符串**（`"swing"` / `"proj:<pid>"` / `"fx:<id>"`）——
## 这样每一帧只是改已有灯的属性，而不是 new 一个（软渲染下每帧 new 灯会立刻拖垮帧率）。
var _fx_lights := {}
var _tex_floor: ImageTexture
var _tex_circle: ImageTexture
var _ready_done := false


func _ready() -> void:
	_tex_floor = _make_radial_tex(Proj.YSQUASH)
	_tex_circle = _make_radial_tex(1.0)
	cm = CanvasModulate.new()
	cm.name = "Darkness"
	cm.color = Color(0.05, 0.06, 0.10)
	add_child(cm)
	player_light = _make_light(560.0, 1.0, Color(1.0, 0.86, 0.58), true)
	player_light.name = "PlayerLight"
	goal_light = _make_light(300.0, 0.0, Color(1.0, 0.90, 0.66), true)
	goal_light.name = "GoalLight"
	_ready_done = true


# ---------------------------------------------------------------- 贴图

## 线性衰减的径向贴图。squash < 1 时纵向半径被压扁 ——
## 屏幕上是个椭圆，投到地板上正好是正圆。第二探针实测：
## 屏幕正圆灯会让"地面等距的南北两点"比东西两点亮 70%（各向异性），
## 竖压椭圆则比值 1.007（各向一致）。所以 2.5D 的灯必须压。
func _make_radial_tex(squash: float) -> ImageTexture:
	var img := Image.create(TEX_N, TEX_N, false, Image.FORMAT_RGBA8)
	var half := TEX_HALF
	for y in TEX_N:
		for x in TEX_N:
			var dx := (float(x) + 0.5 - half) / half
			var dy := (float(y) + 0.5 - half) / half / maxf(0.001, squash)
			var r := sqrt(dx * dx + dy * dy)
			var a := 0.0
			if r < 1.0:
				a = 1.0 - r
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _make_light(radius: float, energy: float, color: Color, shadows: bool) -> PointLight2D:
	var l := PointLight2D.new()
	l.texture = _tex_floor
	l.texture_scale = radius / TEX_HALF
	l.energy = energy
	l.color = color
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.shadow_enabled = shadows
	if "shadow_filter_smooth" in l:
		l.shadow_filter_smooth = 1.0
	add_child(l)
	return l


## 圆形的自光（敌人/火盆这类小球光，用正圆即可，它们太小看不出各向异性）
func _make_glow(radius: float, energy: float, color: Color) -> PointLight2D:
	var l := PointLight2D.new()
	l.texture = _tex_circle
	l.texture_scale = radius / TEX_HALF
	l.energy = energy
	l.color = color
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.shadow_enabled = false
	add_child(l)
	return l


# ---------------------------------------------------------------- 遮挡体

## 由墙列表构建遮挡体。walls 元素为 [x, y, w, d, h]（世界地面坐标）。
func build_occluders(walls: Array) -> void:
	for o in _occluders:
		o.queue_free()
	_occluders.clear()
	for w in walls:
		var occ := LightOccluder2D.new()
		var poly := OccluderPolygon2D.new()
		poly.closed = true
		poly.polygon = occluder_polygon(
			float(w[0]), float(w[1]), float(w[2]), float(w[3]), float(w[4]), OCC_TRIM
		)
		occ.occluder = poly
		add_child(occ)
		_occluders.append(occ)


## 一面墙的遮挡体多边形（屏幕相对坐标）。
##
## 墙上屏幕后由两块拼成（与 Web 版 drawFloor / drawWall 的画法一致）：
##   顶面   = 足迹整体上移 h
##   南立面 = 从足迹南沿向上立起 h
## 画出来的整体轮廓 = 顶面 ∪ 南立面 = 足迹上沿再往上 h 的矩形。
##
## 贴「地面足迹」会让光从墙顶翻过去照到墙后（实测墙后比轮廓模型亮 10 倍）；
## 贴「轮廓四边均匀内缩」会从墙顶漏光。所以是：贴轮廓，只削底边。
static func occluder_polygon(x: float, y: float, w: float, d: float, h: float,
		trim := OCC_TRIM) -> PackedVector2Array:
	var y_foot := y * Proj.YSQUASH          # 足迹北沿（屏幕）
	var fh := d * Proj.YSQUASH              # 足迹屏幕高度
	var y_top := y_foot - h                 # 轮廓上沿 = 墙顶
	var height := fh + h - trim             # 轮廓总高减掉底边削掉的量
	if height < 4.0:
		height = 4.0
	return PackedVector2Array([
		Vector2(x, y_top),
		Vector2(x + w, y_top),
		Vector2(x + w, y_top + height),
		Vector2(x, y_top + height),
	])


# ---------------------------------------------------------------- 同步

## 每帧调用：把灯与遮挡体对齐到当前相机；按存档/关卡/连击更新亮度。
func sync(world) -> void:
	if not _ready_done:
		return
	position = Proj.cam_offset(world.draw_cam.x, world.draw_cam.y)

	# 全局压暗：ambient 越大越黑。清关后 world.ambient 降低 → 抬向白色。
	var d := clampf(1.0 - world.ambient, 0.03, 0.65)
	var t := clampf((d - 0.10) / 0.50, 0.0, 1.0)
	cm.color = Color(0.05, 0.06, 0.10).lerp(Color(1.0, 1.0, 1.0), t)

	# 玩家灯火：半径由连击决定，亮度由连击/辉光决定 —— 「连击就是你的光」
	var p = world.player
	var r: float = world.player_light_radius()
	player_light.position = Vector2(p.x, p.y * Proj.YSQUASH - p.z * 0.0)
	player_light.texture_scale = r / TEX_HALF
	player_light.energy = 0.80 + world.brightness01() * 0.60
	player_light.visible = not p.dead

	# 灯塔
	var gp = world.goal_prop
	if gp is Dictionary and not (gp as Dictionary).is_empty():
		goal_light.position = Vector2(float(gp["x"]), float(gp["y"]) * Proj.YSQUASH)
		var lit: bool = bool(gp.get("lit", false))
		goal_light.energy = 1.05 if lit else 0.06

	# 火盆
	_sync_prop_lights(world)
	# 敌人自光
	_sync_enemy_lights(world)
	# 攻击/弹丸的短命灯
	_sync_fx_lights(world)


## 挥击、飞行中的弹丸、留场的光球/光柱各自点一盏灯。
##
## 两点设计决定：
##  ① **带遮挡**（`shadow_enabled = true`）。这盏灯就是"攻击在发光"这件事本身 ——
##     如果它不认墙，就退化成画面上的一块亮斑，和叠加层的辉光没有区别，
##     而这套工程的全部意义就是"光会被墙挡住"。
##  ② **有上限**。软渲染下每盏投影灯都要重算一遍遮挡，一盏弹丸雨能开几十盏。
##     超出上限的直接不点（画面损失很小，帧率损失很大）。
func _sync_fx_lights(world) -> void:
	var live := {}
	var budget := FX_LIGHT_MAX

	# ── ① 挥击 ──
	# 灯落在**刀锋扫到的那一点**上，不是玩家脚下：脚下已经被玩家自己那盏灯照亮了，
	# 放在那里看不出任何区别。半径取攻击距离的 0.9，所以长兵器（锁灯 132）
	# 的光能伸出玩家自身光照半径之外 —— 这就是"挥击在发光"看得见的原因。
	var p: PlayerState = world.player
	if p.attack_t > 0.0 and not p.dead:
		var w: Dictionary = p.weapon()
		var t01 := clampf(p.attack_t / 0.2, 0.0, 1.0)
		# 光跟着刀锋扫过去：收手时缩回身边，出手时甩到最远
		var reach := float(w["range"]) * 0.9 * (0.30 + 0.70 * (1.0 - t01))
		var sweep: float = p.facing + float(w["arc"]) * 0.25 * (1.0 - 2.0 * (1.0 - t01))
		var key := "swing"
		live[key] = true
		budget -= 1
		if not _fx_lights.has(key):
			_fx_lights[key] = _make_light(80.0, 0.0, Color.WHITE, true)
		var l: PointLight2D = _fx_lights[key]
		var wx: float = p.x + cos(sweep) * reach
		var wy: float = p.y + sin(sweep) * reach * 0.55
		l.position = Vector2(wx, wy * Proj.YSQUASH - 16.0)
		l.texture_scale = (reach * 0.95 + 46.0) / TEX_HALF
		l.color = world.element_color_of()
		l.energy = 1.05 * t01

	# ── ② 玩家弹丸 ──
	for q in world.projs:
		if str(q.get("own", "")) != "player":
			continue
		if budget <= 0:
			break
		var key2 := "proj:%d" % int(q.get("pid", 0))
		live[key2] = true
		budget -= 1
		if not _fx_lights.has(key2):
			_fx_lights[key2] = _make_light(60.0, 0.0, Color.WHITE, true)
		var l2: PointLight2D = _fx_lights[key2]
		l2.position = Vector2(float(q["x"]), float(q["y"]) * Proj.YSQUASH - float(q["z"]))
		l2.texture_scale = (float(q["r"]) * 7.5 + 26.0) / TEX_HALF
		l2.color = Color.html(str(q["color"]))
		l2.energy = 1.15

	# ── ③ 留场物（灯球 / 光柱）──
	# 这两个是"留在原地继续照亮"的东西，用不投影的柔光就够：
	# 它们本来就是暖一团光，投不投影差别不大，但不投影省一半开销。
	for f in world.effects:
		var kind := str(f["kind"])
		if kind != "zone" and kind != "pillar":
			continue
		if budget <= 0:
			break
		var key3 := "fx:%d" % int(f["id"])
		live[key3] = true
		budget -= 1
		if not _fx_lights.has(key3):
			_fx_lights[key3] = _make_glow(90.0, 0.0, Color.WHITE)
		var l3: PointLight2D = _fx_lights[key3]
		l3.position = Vector2(float(f["x"]), float(f["y"]) * Proj.YSQUASH - float(f["z"]))
		var t03 := clampf(1.0 - float(f["life"]) / maxf(0.001, float(f["max_life"])), 0.0, 1.0)
		var rr3 := lerpf(float(f["r0"]), float(f["r1"]), t03)
		l3.texture_scale = (rr3 * 1.5 + 60.0) / TEX_HALF
		l3.color = Color.html(str(f["color"]))
		l3.energy = (0.9 if kind == "zone" else 0.7) * (1.0 - t03 * 0.35)

	# 回收：这一帧没被点到的都熄掉
	for k in _fx_lights.keys():
		if not live.has(k):
			_fx_lights[k].queue_free()
			_fx_lights.erase(k)


## 攻击类光源的盏数（自检用：验"挥击亮了、收手就灭"）
func fx_light_count() -> int:
	return _fx_lights.size()


func fx_light_keys() -> Array:
	return _fx_lights.keys()



func _sync_prop_lights(world) -> void:
	for i in world.props.size():
		var pr: Dictionary = world.props[i]
		if str(pr["kind"]) != "brazier":
			continue
		var lit: bool = bool(pr.get("lit", false))
		if not _brazier_lights.has(i):
			if not lit:
				continue
			_brazier_lights[i] = _make_glow(210.0, 1.0, Color(1.0, 0.72, 0.38))
		var l: PointLight2D = _brazier_lights[i]
		l.position = Vector2(float(pr["x"]), float(pr["y"]) * Proj.YSQUASH - 22.0)
		var flick := 0.92 + 0.08 * sin(world.time * 7.0 + float(i) * 2.1)
		l.energy = (1.0 if lit else 0.0) * flick


func _sync_enemy_lights(world) -> void:
	var live := {}
	for e in world.enemies:
		if e.dead:
			continue
		var lr: float = e.light_radius()
		if lr <= 0.0:
			continue
		live[e.id] = true
		if not _enemy_lights.has(e.id):
			var c := Color.html(str(e.def["glow"]))
			_enemy_lights[e.id] = _make_glow(lr * 2.6, 0.62, c)
		var l: PointLight2D = _enemy_lights[e.id]
		l.position = Vector2(e.x, e.y * Proj.YSQUASH - e.h * 0.45)
		l.texture_scale = (lr * 2.6) / TEX_HALF
		l.energy = 0.62 + (0.35 if e.state == "windup" else 0.0)
	# 回收死掉的
	for id in _enemy_lights.keys():
		if not live.has(id):
			_enemy_lights[id].queue_free()
			_enemy_lights.erase(id)


func light_count() -> int:
	var n := 0
	for c in get_children():
		if c is Light2D:
			n += 1
	return n


func occluder_count() -> int:
	return _occluders.size()
