class_name Fog
extends Node2D
## Fog —— 迷雾层。需求：「给地图添加迷雾，灯照的地方迷雾会散去」。
##
## ── 为什么不用 Light2D 来"擦"雾 ──
## Godot 的 2D 光照只能把**被照到**的地方画出来（`LIGHT_MODE_LIGHT_ONLY`），
## 而雾要的正好相反：**没被照到**的地方才该有雾。
## 而 `Light2D.blend_mode = BLEND_MODE_SUB` 减的是 RGB，**不减 alpha**
## ——"用一盏负光在雾上挖洞"在 2D 里做不到（叠加层 Bloom 那套 ADD 同理，只有加法）。
## 所以这张雾是**自己算**的。
##
## ── 怎么算 ──
##   ① 屏幕切成 80×45 的小格（16px 一格），每格问一句"这里被照亮了多少"；
##   ② 照亮值 = max over 灯（径向衰减 × 视线有没有被墙挡住）；
##   ③ 写进一张 80×45 的贴图，交给一个全屏着色器：照亮值低的地方画成雾、
##      高的地方留空，再叠一层缓慢飘动的噪声当雾絮。
##
## 视线用**射线扇**，不逐格沿线采样：
##   每盏灯按 192 条射线做一次"射线 vs 墙矩形"求交，得到**每个角度上光最远到哪儿**；
##   于是格子只要比一下距离就够了。代价是 射线数×近处墙数（几百次求交/盏），
##   比"每格 × 步数"便宜两个数量级 —— 而且墙只有十几面。
##
## ── 三个刻意的设计决定 ──
##   ① **逐字走固定步长**（由 `World.step()` 调），不用 `_process`：
##      着色器里的雾絮时间也取自世界的 `time`，所以连"雾在飘"这件事都是可复现的。
##   ② **有开关**（`enabled`）：像素类断言要能把它关掉，否则"墙后到底暗不暗"
##      量到的是雾。与 HUD 那层暗角（`set_post_enabled`）是同一个道理。
##   ③ **只认"能开雾的灯"**：玩家灯 / 灯塔 / 火盆 / 攻击类灯 / 敌人自光。
##      太小的灯不开雾（否则雾面上全是针孔），盏数也有上限。

## 照亮场分辨率。16px 一格：够糊，也够抠。每格 1 个 texel，
## 着色器用线性过滤把它插值开，所以看不见格子。
const GRID_W := 80
const GRID_H := 45
const GRID_N := GRID_W * GRID_H

## 射线条数。192 → 1.875°/条，半径 620 的那盏灯在弧上约 20px 一条，
## 落在雾的柔边里看不出来。
const RAYS := 192

## 墙往外"胖"一圈再当遮挡物：不胖的话雾会贴着墙面留下一条缝，
## 而墙在屏幕上是有高度的（画出来比它的地面足迹高 46px 左右）。
const WALL_PAD := 10.0

## 重建间隔（秒）。雾不需要 60Hz，20Hz 又省 2/3 的算力。
const REBUILD_PERIOD := 0.05

## 没被照到时，雾**回填**的速度（每秒）。照亮是立刻的，回填是慢慢来的
## —— 这样"灯扫过去"会留下一道正在合拢的痕迹，像真的雾。
const REFILL := 1.6

## 开雾的灯数上限（按半径从大到小取）
const OPENER_MAX := 10
## 半径小于这个数的灯不开雾（敌人身上的小自光只是"透出一点亮"，不该整个散开）
const MIN_OPENER_R := 24.0

## 雾最浓时的 alpha。**这个数是量出来的**，不是猜的 —— 做法是"冻结世界、
## 同一帧只拧这一个 uniform"，逐像素上除雾浓之外没有第二个变量（取样见 README 二.14.3）。
## 取样块：一块没有 HUD、没有玩家光晕的地面（均值 42.5 / 局部对比度 3.90 / 基线即关雾）：
##
##   α      地面均值   局部对比度（vs 关雾）   与关雾图的高频相关性
##   0.30   57.1       3.05（78%）            0.96
##   0.40   62.1       2.78（71%）            0.93
##   0.45   64.6       2.67（68%）            0.91   ← 当前
##   0.50   67.1       2.54（65%）            0.87
##   0.60   72.0       2.38（61%）            0.79
##   0.70   76.9       2.28（58%）            0.68
##   1.00   91.2       2.21（57%）            0.23
##
## ⚠️ **后一列才是"地形还剩多少"的判据，前一列不是。** 局部对比度会被雾**自己的**
## 絮状纹理抬高：雾拉满（α=1.0）时它还剩 57%，看着好像"地形留了一半"，
## 其实那 57% 全是雾的絮 —— 与关雾图的高频相关性只有 **0.23**，地形边缘基本没了。
## 相关性是拿"雾开 / 雾关"两张图的**同一块高频分量**做的（雾关那张是基线的地形细节），
## 所以它只问一件事：**屏幕上这些细节里，有多少还是原来的地形**。
##
## ⚠️ 曲线**在 0.70 以上就是平的**：1.00 → 0.70 只买回 1% 的对比度、相关性也才 0.68，
## 均值却从 91 掉到 77（画面明显变暗）—— 等于"淡了但地形照样看不清"。
## 真正把地形找回来的是 **0.45~0.50** 这一档（相关性 0.87~0.91）。
## 所以"淡一点"必须淡过这个拐点才有意义 —— 拐点是量出来的，不是拍的。
##
## 这个数被用户拧过三轮，每一轮都留了代价：
##   ① 0.58（当时只有两层噪声）：没被照亮的地方是一整块灰板，地砖缝与墙轮廓全糊掉
##      —— 要的是"地图可见（但像晚上）"，不是"用雾把地图藏起来" → 降到 0.40。
##   ② 用户要**最浓** → 1.00。代价：灯照不到的地方地形基本看不见（相关性 0.23），
##      只有灯照的那一圈是清的（`KIND_SCALE.player = 0.82` 留了一圈柔边，
##      所以"雾退到哪儿为止"仍看得见）。
##   ③ 用户要"淡一点，让地形可见" → **0.45**：墙的轮廓与地砖缝重新读得出来（相关性 0.91），
##      而雾仍然明显（均值 64.6，是关雾的 1.5 倍）。
##
## ⚠️ `a *= mix(0.50, 1.25, n)` 那一步不能被去掉：没有噪声调制的话，整屏就是一块**平**色板；
## 有噪声才有 0.5~1.25 的厚薄差，看着才是"雾"而不是"墙"。
const MIST_MAX := 0.45

## 清关时"雾散尽"用的时间（秒）
const FADE_T := 1.2

## 每类灯"开雾半径"相对它自己光照半径的系数。
## 玩家灯 <1：让雾在光亮区的**边缘**留一圈，看得见"雾退到哪儿为止"。
## 敌人 <1：它那圈自光本身就得比"照亮地面"小一档，是"雾里透出一点亮"。
const KIND_SCALE := {
	"player": 0.82, "goal": 0.95, "brazier": 0.95, "fx": 0.85, "enemy": 0.65,
}

const SHADER_SRC := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D reveal_tex : filter_linear, repeat_disable, hint_default_black;
uniform vec4 mist_lo : source_color = vec4(0.16, 0.19, 0.27, 1.0);
uniform vec4 mist_hi : source_color = vec4(0.33, 0.38, 0.48, 1.0);
uniform float mist_max : hint_range(0.0, 1.0) = 0.45;
uniform float mist_time = 0.0;
uniform float mist_scale = 13.0;
uniform float mist_speed = 0.022;

float h21(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = mix(h21(i), h21(i + vec2(1.0, 0.0)), u.x);
	float b = mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), u.x);
	return mix(a, b, u.y);
}

void fragment() {
	// reveal: 1 = 被照亮（没有雾），0 = 没被照到（雾最浓）
	float reveal = texture(reveal_tex, SCREEN_UV).r;
	// 三个倍频叠出"雾絮"：只有两个倍频时，整屏只有十来个噪声格，
	// 看着像一块灰板（第一版就是这样）；第三个倍频给出细一点的絮状结构。
	// 整片缓慢往东北飘。
	vec2 q = SCREEN_UV * vec2(mist_scale * 1.78, mist_scale);
	q += vec2(mist_time * mist_speed, mist_time * mist_speed * 0.55);
	float n = vnoise(q) * 0.54 + vnoise(q * 2.3 + 11.0) * 0.31 + vnoise(q * 5.1 + 31.0) * 0.15;

	float a = mist_max * clamp(1.0 - reveal, 0.0, 1.0);
	// 噪声不只改浓度，也改"絮"的厚薄：低到 0.5、高到 1.25，才有飘动感
	a *= mix(0.50, 1.25, n);
	vec3 col = mix(mist_lo.rgb, mist_hi.rgb, n * n);
	COLOR = vec4(col, clamp(a, 0.0, 1.0));
}
"""

var world: World
## 迷雾开关。**像素类断言要能关掉它** —— 见类头注释 ②。
var enabled := true
var mat: ShaderMaterial

var _img: Image
var _tex: ImageTexture
## 照亮场：`_target` 是"这一刻应该多亮"，`_cur` 是"画面上现在多亮"（带回填滞后）
var _target := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _step_x := 1.0
var _step_y := 1.0
var _acc := 0.0
var _rebuilds := 0
var _openers := []
## 射线扇缓存：同一盏灯（同一个位置、同一个半径）不必每帧重投
var _fan_cache := {}
var _mist := Color(0.16, 0.19, 0.27)
## 整体浓淡系数：清关时从 1 掉到 0（"这一关的雾散了"）
var _fade := 1.0
var _fade_target := 1.0


func _ready() -> void:
	_step_x = float(Proj.VIEW_W) / float(GRID_W)
	_step_y = float(Proj.VIEW_H) / float(GRID_H)
	_target.resize(GRID_N)
	_cur.resize(GRID_N)
	# 起始状态：整屏都是雾（`_cur` = 0 = 揭示度 0 = 雾最浓）
	_img = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	_tex = ImageTexture.create_from_image(_img)
	var sh := Shader.new()
	sh.code = SHADER_SRC
	mat = ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("reveal_tex", _tex)
	mat.set_shader_parameter("mist_max", MIST_MAX)
	material = mat


## 每关的雾色取自关卡表（`palette.mist`）—— 三张图的雾不是同一种颜色。
func setup(level: Dictionary) -> void:
	var pal: Dictionary = level.get("palette", {})
	_mist = Color.html(str(pal.get("mist", "#2b3448")))
	mat.set_shader_parameter("mist_lo", _mist)
	mat.set_shader_parameter("mist_hi", _mist.lerp(Color(1.0, 1.0, 1.0), 0.38))


func set_enabled(on: bool) -> void:
	enabled = on
	visible = on


## 清关：把这一关的雾慢慢放掉（由 `World._on_boss_dead()` 调）。
func disperse() -> void:
	_fade_target = 0.0


## 反过来：让"已经散尽的雾"重新聚起来（重开同一关时用）。
## 没有它，`disperse()` 就是单向的 —— 自检验完"雾会散掉"之后没法把世界还原。
func reset_fade() -> void:
	_fade_target = 1.0


func fade() -> float:
	return _fade


## 这一关的雾色（取自 `palette.mist`）—— 自检拿它核对"雾色来自关卡表"。
func fog_color() -> Color:
	return _mist


## 浓淡系数的推进。**由 `World.tick_fx()` 调**，所以世界被面板冻住时它照样在散 ——
## 与"红闪衰减不跟着冻住"是同一个理由：这是给玩家看的反馈，不是世界状态。
func tick_fade(dt: float) -> void:
	if is_equal_approx(_fade, _fade_target):
		return
	var rate := 1.0 / FADE_T
	if _fade > _fade_target:
		_fade = maxf(_fade_target, _fade - rate * dt)
	else:
		_fade = minf(_fade_target, _fade + rate * dt)
	mat.set_shader_parameter("mist_max", MIST_MAX * _fade)


func rebuilds() -> int:
	return _rebuilds


func opener_count() -> int:
	return _openers.size()


func openers() -> Array:
	return _openers


# ---------------------------------------------------------------- 每步

## 由 `World.step()` 调用（固定步长）。dt 用于雾的回填速度。
##
## ⚠️ **不要**像 `LightRig` / `Bloom` 那样把 `position` 设成 `Proj.cam_offset(...)`。
## 那两层的局部坐标是"世界坐标投影过来的"（它们的子节点直接写世界坐标，只是 y 预乘了
## `YSQUASH`），而这一层**根本不使用世界坐标**：`_draw()` 画的是整屏矩形、着色器读的是
## `SCREEN_UV`、照亮场也是按屏幕格子铺的。它已经在屏幕空间里了，再叠一次 `cam_offset`
## 会把这块矩形搬到屏幕外 —— 症状很隐蔽：**只有约 53% 的屏幕被雾盖住**，
## 而且盖住的那部分还是照亮场的错位切片（"灯下雾散"看起来对不上灯）。
func sync(w: World, dt: float) -> void:
	if not enabled:
		return
	_acc += dt
	if _acc < REBUILD_PERIOD:
		return
	var d := _acc
	_acc = 0.0
	_rebuild(w, d)


func _rebuild(w: World, dt: float) -> void:
	_rebuilds += 1
	if _fan_cache.size() > 64:
		_fan_cache.clear()
	var lx := PackedFloat32Array()
	var ly := PackedFloat32Array()
	var lr := PackedFloat32Array()
	var fans := []
	_collect_openers(w, lx, ly, lr, fans)
	_openers = []
	for k in lx.size():
		_openers.append({"x": lx[k], "y": ly[k], "r": lr[k]})

	var camx := w.draw_cam.x
	var camy := w.draw_cam.y
	var half_w := Proj.VIEW_W * 0.5
	var half_h := Proj.VIEW_H * 0.5
	var inv_squash := 1.0 / Proj.YSQUASH
	var n := lx.size()

	for j in GRID_H:
		# 屏幕 y → 地面世界 y（雾是按地面算的，不是按屏幕 —— 屏幕空间会把
		# 竖压后的椭圆算成斜的：同一盏灯在南北与东西方向上的边界就对不上了）
		var wy := (float(j) + 0.5) * _step_y
		wy = (wy - half_h) * inv_squash + camy
		var row := j * GRID_W
		for i in GRID_W:
			var wx := (float(i) + 0.5) * _step_x - half_w + camx
			var best := 0.0
			for k in n:
				var ddx := wx - lx[k]
				var ddy := wy - ly[k]
				var dd := sqrt(ddx * ddx + ddy * ddy)
				var rr := lr[k]
				if dd >= rr:
					continue
				if dd > _fan_lookup(fans[k], ddx, ddy, dd):
					continue
				var v := 1.0 - dd / rr
				v = v * v * (3.0 - 2.0 * v)     # smoothstep：中心平、边缘柔
				if v > best:
					best = v
					if best >= 0.999:
						break
			_target[row + i] = best

	# 照亮立刻生效；没被照到的地方按 REFILL 慢慢合拢
	var k2 := REFILL * dt
	for i in GRID_N:
		var t := _target[i]
		var c := _cur[i]
		_cur[i] = t if t >= c else maxf(t, c - k2)

	for j in GRID_H:
		var row2 := j * GRID_W
		for i in GRID_W:
			var v2 := _cur[row2 + i]
			_img.set_pixel(i, j, Color(v2, v2, v2, 1.0))
	_tex.update(_img)
	mat.set_shader_parameter("mist_time", w.time)


## 把「能开雾的灯」收集成扁平数组（避免每格去查字典）。
## 顺序按半径从大到小 —— 大灯先算，小的补细节；超过上限的直接不要。
func _collect_openers(w: World, lx: PackedFloat32Array, ly: PackedFloat32Array,
		lr: PackedFloat32Array, fans: Array) -> void:
	var rig: LightRig = w.light_rig
	if rig == null:
		return
	var picks := []
	for i in rig.source_count():
		var kind := rig.src_kind[i]
		var scale := float(KIND_SCALE.get(kind, 1.0))
		var rr := rig.src_r[i] * scale
		if rr < MIN_OPENER_R:
			continue
		picks.append([rr, kind, rig.src_x[i], rig.src_y[i], i])
	picks.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for k in mini(picks.size(), OPENER_MAX):
		var pk: Array = picks[k]
		var rr2 := float(pk[0])
		var cx := float(pk[2])
		var cy := float(pk[3])
		lx.append(cx)
		ly.append(cy)
		lr.append(rr2)
		fans.append(_fan_for("%s:%d" % [str(pk[1]), int(pk[4])], cx, cy, rr2))


# ---------------------------------------------------------------- 射线扇

func _fan_for(key: String, cx: float, cy: float, radius: float) -> PackedFloat32Array:
	var c: Dictionary = _fan_cache.get(key, {})
	if not c.is_empty() \
			and is_equal_approx(float(c["x"]), cx) \
			and is_equal_approx(float(c["y"]), cy) \
			and is_equal_approx(float(c["r"]), radius):
		return c["fan"]
	var fan := _cast_fan(cx, cy, radius)
	_fan_cache[key] = {"x": cx, "y": cy, "r": radius, "fan": fan}
	return fan


## 一盏灯朝 RAYS 个方向各投一条射线，得到"这个角度上光最远到哪儿"。
func _cast_fan(cx: float, cy: float, radius: float) -> PackedFloat32Array:
	var fan := PackedFloat32Array()
	fan.resize(RAYS)
	var rects := _near_walls(cx, cy, radius)
	for i in RAYS:
		var a := TAU * float(i) / float(RAYS)
		var dx := cos(a)
		var dy := sin(a)
		var best := radius
		for r in rects:
			var t: float = Proj.ray_rect_dist(cx, cy, dx, dy, r[0], r[1], r[2], r[3])
			if t >= 0.0 and t < best:
				best = t
		fan[i] = best
	return fan


## 粗筛：只把（胖过一圈的）包围盒和这盏灯的圆有交集的墙留下。墙只有十几面，
## 但一帧要投十几盏灯的射线，这一步能省掉大半。
func _near_walls(cx: float, cy: float, radius: float) -> Array:
	var out := []
	var r := radius + WALL_PAD
	for wl in world.walls:
		var x := float(wl[0]) - WALL_PAD
		var y := float(wl[1]) - WALL_PAD
		var ww := float(wl[2]) + WALL_PAD * 2.0
		var dd := float(wl[3]) + WALL_PAD * 2.0
		if x > cx + r or x + ww < cx - r:
			continue
		if y > cy + r or y + dd < cy - r:
			continue
		out.append([x, y, ww, dd])
	return out


## 在扇形上按角度插值取"这个方向的最远距离"。
static func _fan_lookup(fan: PackedFloat32Array, dx: float, dy: float, d: float) -> float:
	if d <= 0.0001 or fan.is_empty():
		return 1.0e30
	var a := atan2(dy, dx)
	if a < 0.0:
		a += TAU
	var f := a / TAU * float(RAYS)
	var i := int(f) % RAYS
	var j := (i + 1) % RAYS
	return lerpf(fan[i], fan[j], f - float(i))


# ---------------------------------------------------------------- 查询（自检用）

## 世界坐标 → 网格索引
func grid_of(x: float, y: float) -> Vector2i:
	var sx := x - world.draw_cam.x + Proj.VIEW_W * 0.5
	var sy := (y - world.draw_cam.y) * Proj.YSQUASH + Proj.VIEW_H * 0.5
	return Vector2i(
		clampi(int(sx / _step_x), 0, GRID_W - 1),
		clampi(int(sy / _step_y), 0, GRID_H - 1))


## 这一刻"应该"被照亮多少（0 = 全雾，1 = 无雾）。不含回填滞后。
func target_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	return _target[g.y * GRID_W + g.x]


## 画面上"现在"被照亮多少（含回填滞后）。
func reveal_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	return _cur[g.y * GRID_W + g.x]


func grid_target_copy() -> PackedFloat32Array:
	return _target


func grid_cur_copy() -> PackedFloat32Array:
	return _cur


func _draw() -> void:
	# 一整块屏幕大小的矩形；颜色由着色器完全接管（见 SHADER_SRC 的 COLOR = ...）。
	draw_rect(Rect2(0.0, 0.0, Proj.VIEW_W, Proj.VIEW_H), Color.WHITE)
