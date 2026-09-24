class_name Art
extends RefCounted
## Art —— 全部程序化矢量美术。零外部素材，与 Web 版 render.ts 的画法对应。
##
## 坐标：默认在**屏幕坐标**下作画（用 Proj.sx / Proj.sy 显式投影），
## 与 render.ts 一致，方便两个版本逐帧比对。
## 地面上的圆（影子、光池、地面标记）要"投到地板上才是正圆"，
## 所以先 draw_set_transform 把纵轴压扁再画圆 —— 见 ground_circle()。

static var font: Font = null
## 标题/卡牌/大数字用的**显示字体**。正文用它偏软，小字号也不够扎实，
## 但一旦放大，"写出来的"笔触感是黑体给不了的 —— 这是这一版视觉升级里
## 最便宜也最见效的一笔。
## 霞鹜文楷 LXGW WenKai，OFL-1.1，随工程放在 assets/fonts/ 下（来源见 README）。
static var font_disp: Font = null

const DISPLAY_FONT := "res://assets/fonts/LXGWWenKai-Regular.ttf"

const FONT_CANDIDATES := [
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Medium.ttc",
	"/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
	"/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
]


## Godot 内置字体不含 CJK，中文会渲染成空白/豆腐块。
## 所以运行时加载一份思源黑体（Arch 的 noto-cjk 包）。
static func ensure_font() -> void:
	if font != null:
		return
	for p in FONT_CANDIDATES:
		if not FileAccess.file_exists(p):
			continue
		var f := FontFile.new()
		if f.load_dynamic_font(p) == OK:
			font = f
			break
	if font == null:
		font = ThemeDB.fallback_font
	# 显示字体：优先用随工程的霞鹜文楷，取不到就退回正文那份（不能没有）
	var df := FontFile.new()
	if df.load_dynamic_font(ProjectSettings.globalize_path(DISPLAY_FONT)) == OK:
		font_disp = df
	else:
		font_disp = font


static func gpos(x: float, y: float, z: float, cam: Vector2) -> Vector2:
	return Vector2(Proj.sx(x, cam.x), Proj.sy(y, z, cam.y))


# ---------------------------------------------------------------- 变换

## 进入"地板空间"：纵轴按 YSQUASH 压扁，于是这里的圆投到地板上是正圆。
static func begin_floor(ci: CanvasItem, cam: Vector2) -> void:
	ci.draw_set_transform(
		Vector2(Proj.VIEW_W * 0.5 - cam.x, Proj.VIEW_H * 0.5 - cam.y * Proj.YSQUASH),
		0.0, Vector2(1.0, Proj.YSQUASH))


static func end_xf(ci: CanvasItem) -> void:
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 地面正圆（阴影、光池、地面标记）
static func ground_circle(ci: CanvasItem, px: float, py: float, r: float, col: Color) -> void:
	ci.draw_set_transform(Vector2(px, py), 0.0, Vector2(1.0, Proj.YSQUASH))
	ci.draw_circle(Vector2.ZERO, r, col)
	end_xf(ci)


static func ground_ring(ci: CanvasItem, px: float, py: float, r: float, col: Color, w: float) -> void:
	ci.draw_set_transform(Vector2(px, py), 0.0, Vector2(1.0, Proj.YSQUASH))
	ci.draw_arc(Vector2.ZERO, r, 0.0, TAU, 48, col, w, true)
	end_xf(ci)


static func ground_arc(ci: CanvasItem, px: float, py: float, r: float,
		a0: float, a1: float, col: Color, w: float) -> void:
	ci.draw_set_transform(Vector2(px, py), 0.0, Vector2(1.0, Proj.YSQUASH))
	ci.draw_arc(Vector2.ZERO, r, a0, a1, 24, col, w, true)
	end_xf(ci)


static func shadow(ci: CanvasItem, x: float, y: float, r: float, cam: Vector2, alpha: float) -> void:
	ground_circle(ci, Proj.sx(x, cam.x), Proj.sy(y, 0.0, cam.y), r, Color(0.0, 0.0, 0.0, alpha))


## 叠加发光：贴一张径向渐变贴图。
##
## 旧版是"同心圆近似"（7 层 draw_circle 叠出渐变），优点是不依赖任何贴图，
## 缺点是层与层之间能看出台阶、且光晕边缘是硬圆。换成贴图后
## **一次 draw_texture_rect** 就得到连续衰减，还更便宜。
## 最后一个参数是历史遗留（原来是同心圆层数），现在不用了 —— 留着是为了
## 二十多个调用点不必逐个改。
static func glow(ci: CanvasItem, p: Vector2, r: float, col: Color, alpha: float, _rings := 7) -> void:
	if r <= 0.0 or alpha <= 0.0:
		return
	var d := r * 2.0
	ci.draw_texture_rect(soft_dot, Rect2(p.x - r, p.y - r, d, d), false,
		Color(col.r, col.g, col.b, alpha))


# ---------------------------------------------------------------- 运行时素材

## 素材放在 assets/ 下，**运行时按路径读文件**，不走 Godot 的资源导入管线。
##
## 为什么：这个工程是用命令行直接跑的（tools/godot-lightknight.sh），没人开编辑器。
## 一个没有 .import 的 PNG 用 load("res://…") 会失败（资源系统只认导入产物），
## 但 Image.load_from_file() 直接解码文件，命令行、编辑器、导出后行为一致。
##
## 贴图**加载时就降采样到 256**：素材原图 512×512，而实际画出来常常只有几十像素，
## 运行时贴图又没有 mipmap，直接缩会被采样成噪点。先做一次 Lanczos 降采样，
## 之后无论画多大都是平滑的。
const ASSET_DIR := "res://assets/vendor/kenney_particles/"
const TEX_SIZE := 256

static var _tex_cache: Dictionary = {}
## 程序化生成的径向渐变（画所有光晕用）
static var soft_dot: ImageTexture = null
## 素材加载的失败记录，自检会把它报出来（免得"贴图没加载"表现为"画面没变化"）
static var tex_errors: Array = []


static func tex(name: String) -> Texture2D:
	if _tex_cache.has(name):
		return _tex_cache[name]
	var img := Image.new()
	var err := img.load(ProjectSettings.globalize_path(ASSET_DIR + name + ".png"))
	var t: Texture2D = null
	if err == OK:
		img.convert(Image.FORMAT_RGBA8)
		if img.get_width() != TEX_SIZE:
			img.resize(TEX_SIZE, TEX_SIZE, Image.INTERPOLATE_LANCZOS)
		t = ImageTexture.create_from_image(img)
	else:
		if not tex_errors.has(name):
			tex_errors.append(name)
	_tex_cache[name] = t
	return t


## 中心 1、边缘 0 的径向渐变，衰减用 smootherstep（一阶导连续），
## 所以没有可见的圈或硬边。128 就够 —— 它永远是被拉开放大的。
static func _make_soft_dot() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := float(n) * 0.5 - 0.5
	for y in n:
		for x in n:
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var t := clampf(1.0 - d, 0.0, 1.0)
			# smootherstep(1-d)：中心平、边缘平、中间过渡，四角正好归零
			var a := t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


static func ensure_assets() -> void:
	ensure_font()
	if soft_dot == null:
		soft_dot = _make_soft_dot()


## 带旋转/缩放的贴图（挥击月牙、光束、速度线这类有朝向的）
static func tex_rot(ci: CanvasItem, name: String, p: Vector2, w: float, h: float,
		rot: float, col: Color, flip_v := false) -> void:
	var t := tex(name)
	if t == null:
		return
	var tw := float(t.get_width())
	var th := float(t.get_height())
	var sc := Vector2(w / tw, h / th)
	if flip_v:
		sc.y = -sc.y
	ci.draw_set_transform(p, rot, sc)
	ci.draw_texture_rect(t, Rect2(-tw * 0.5, -th * 0.5, tw, th), false, col)
	end_xf(ci)


## 屏幕空间的正贴图（不投影，用于 HUD 之外的叠加）
static func tex_at(ci: CanvasItem, name: String, p: Vector2, w: float, h: float, col: Color) -> void:
	var t := tex(name)
	if t == null:
		return
	ci.draw_texture_rect(t, Rect2(p.x - w * 0.5, p.y - h * 0.5, w, h), false, col)


# ---------------------------------------------------------------- 地板

static func floor(ci: CanvasItem, level: Dictionary, pal: Dictionary, cam: Vector2, t: float) -> void:
	var lw := float(level["w"])
	var lh := float(level["h"])
	begin_floor(ci, cam)
	var c1 := Color.html(str(pal["floor"]))
	var c2 := Color.html(str(pal["floor2"]))
	# 只铺可见范围，省掉大片屏幕外的绘制
	var y0 := maxf(0.0, cam.y - Proj.VIEW_H * 0.5 / Proj.YSQUASH - 96.0)
	var y1 := minf(lh, cam.y + Proj.VIEW_H * 0.5 / Proj.YSQUASH + 96.0)
	var x0 := maxf(0.0, cam.x - Proj.VIEW_W * 0.5 - 96.0)
	var x1 := minf(lw, cam.x + Proj.VIEW_W * 0.5 + 96.0)

	# 底色（同时也让 CanvasModulate 有东西可压暗 —— 空背景不会被照亮）
	ci.draw_rect(Rect2(x0, y0, x1 - x0, y1 - y0), c1)

	var tile := 96.0
	var iy := floori(y0 / tile)
	while float(iy) * tile < y1:
		var ix := floori(x0 / tile)
		while float(ix) * tile < x1:
			var tx := float(ix) * tile
			var ty := float(iy) * tile
			var odd := (ix + iy) % 2 == 0
			var c := c2 if odd else c1
			ci.draw_rect(Rect2(tx + 1.5, ty + 1.5, tile - 3.0, tile - 3.0), c)
			ix += 1
		iy += 1

	# 地面暗纹：裂缝/血痕（按固定种子，同一关每次一样）
	var rng := Proj.make_rng(int(level["seed"]) + 99)
	for i in 26:
		var x := rng.randf() * lw
		var y := rng.randf() * lh
		var a := Color(0.0, 0.0, 0.0, 0.45)
		ci.draw_line(Vector2(x, y), Vector2(x + (rng.randf() - 0.5) * 90.0, y + (rng.randf() - 0.5) * 90.0),
			a, 1.0 + rng.randf() * 2.0, true)
	end_xf(ci)


# ---------------------------------------------------------------- 墙

static func wall(ci: CanvasItem, w: Array, pal: Dictionary, cam: Vector2) -> void:
	var x0 := Proj.sx(w[0], cam.x)
	var x1 := Proj.sx(w[0] + w[2], cam.x)
	var yN := Proj.sy(w[1], 0.0, cam.y)
	var yS := Proj.sy(w[1] + w[3], 0.0, cam.y)
	var h := float(w[4])
	var tN := yN - h
	var tS := yS - h
	if x1 < -90.0 or x0 > Proj.VIEW_W + 90.0 or yS < -180.0 or tN > Proj.VIEW_H + 180.0:
		return

	var c_wall := Color.html(str(pal["wall"]))
	var c_top := Color.html(str(pal["wall_top"]))
	var c_rim := Color.html(str(pal["rim"]))

	# 东侧面：给立方体一点厚度感
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(x1, tN), Vector2(x1 + 8.0, tN + 8.0), Vector2(x1 + 8.0, yS + 8.0), Vector2(x1, yS),
	]), Color(0.0, 0.0, 0.0, 0.55))

	# 南立面（朝向镜头）：上亮下暗，用横向色带模拟渐变
	var bands := 8
	for i in bands:
		var t0 := float(i) / float(bands)
		var t1 := float(i + 1) / float(bands)
		var c := c_top.lerp(c_wall, minf(1.0, t0 * 2.6)).lerp(Color(0.03, 0.04, 0.07), maxf(0.0, t0 - 0.35) / 0.65)
		ci.draw_rect(Rect2(x0, tS + (yS - tS) * t0, x1 - x0, (yS - tS) * (t1 - t0) + 0.8), c)
	# 砖缝
	var yy := tS + 11.0
	while yy < yS:
		ci.draw_line(Vector2(x0, yy), Vector2(x1, yy), Color(0.0, 0.0, 0.0, 0.35), 1.0, true)
		yy += 13.0

	# 顶面
	ci.draw_rect(Rect2(x0, tN, x1 - x0, yS - yN), c_wall)
	ci.draw_line(Vector2(x0, tN), Vector2(x1, tN), Color(c_rim.r, c_rim.g, c_rim.b, 0.28), 1.4, true)
	ci.draw_line(Vector2(x0, yS), Vector2(x1, yS), Color(0.0, 0.0, 0.0, 0.5), 1.0, true)


# ---------------------------------------------------------------- 玩家

static func player(ci: CanvasItem, p: PlayerState, cam: Vector2, brightness: float,
		dead: bool, t: float, weapon_id: String) -> void:
	var px := Proj.sx(p.x, cam.x)
	var bob := absf(sin(p.walk_t)) * 2.2
	var py := Proj.sy(p.y, p.z + bob, cam.y)
	var gy := Proj.sy(p.y, 0.0, cam.y)

	if dead:
		var tt := clampf(p.death_t / 1.2, 0.0, 1.0)
		shadow(ci, p.x, p.y, 16.0 * (1.0 - tt * 0.4), cam, 0.4 * (1.0 - tt))
		ci.draw_set_transform(Vector2(px, gy - 16.0 * (1.0 - tt)), 0.0, Vector2(1.0, 1.0))
		ci.draw_circle(Vector2.ZERO, 18.0 * (1.0 - tt * 0.5), Color("#2a2e3c"))
		end_xf(ci)
		return

	shadow(ci, p.x, p.y, 15.0, cam, 0.45)

	# 冲刺残影
	if p.dash_t > 0.0:
		for i in range(1, 5):
			var bx := px - p.dash_dx * float(i) * 12.0
			var by := py - p.dash_dy * float(i) * 12.0 * Proj.YSQUASH
			ground_circle(ci, bx, by - 20.0, 11.0 - float(i), Color(1.0, 0.86, 0.63, 0.16))

	var flip := 1.0 if cos(p.facing) >= 0.0 else -1.0
	var hurt := p.hurt_flash > 0.0

	# 斗篷
	var cloak := PackedVector2Array([
		Vector2(-13.0, 0.0), Vector2(-14.0, -22.0), Vector2(-8.0, -32.0),
		Vector2(8.0, -32.0), Vector2(14.0, -22.0), Vector2(13.0, 0.0),
		Vector2(0.0, 4.0),
	])
	var pts := PackedVector2Array()
	for q in cloak:
		pts.append(Vector2(px + q.x * flip, py + q.y))
	var body_col := Color("#2f3749") if not hurt else Color("#8d5a52")
	ci.draw_colored_polygon(pts, body_col)
	# 斗篷上缘提亮
	ci.draw_line(Vector2(px - 8.0 * flip, py - 32.0), Vector2(px + 8.0 * flip, py - 32.0),
		Color("#4a5670"), 3.0, true)

	# 头盔
	ci.draw_circle(Vector2(px, py - 36.0), 8.6, Color("#3d4761"))
	ci.draw_circle(Vector2(px - 2.4 * flip, py - 38.5), 4.4, Color("#59657f"))
	# 面罩缝
	ci.draw_line(Vector2(px - 5.0 * flip, py - 34.0), Vector2(px + 4.0 * flip, py - 34.0),
		Color(0.05, 0.06, 0.10, 0.8), 2.0, true)

	# 武器：8 把各自的轮廓差异要一眼看得出来。
	# wind/swing 是挥击的动画进度（0 → 1 → 0 的一个隆起）。
	var wind := 1.0 - clampf(p.attack_t / 0.2, 0.0, 1.0)
	var swing := sin(wind * PI)
	var hx0 := px + 8.0 * flip
	var hy0 := py - 24.0
	match weapon_id:
		"twin":
			# 双灯刃：左右手各一把短刃
			for side_v in [-1.0, 1.0]:
				var side := float(side_v)
				var bx := px + (14.0 + swing * 7.0) * flip * side
				ci.draw_line(Vector2(px + 7.0 * flip * side, py - 23.0),
					Vector2(bx, py - 25.0 - swing * 7.0), Color("#c9d3ea"), 2.6, true)
				ci.draw_colored_polygon(PackedVector2Array([
					Vector2(bx, py - 30.0 - swing * 7.0),
					Vector2(bx + 13.0 * flip * side, py - 25.0 - swing * 7.0),
					Vector2(bx, py - 20.0 - swing * 7.0),
				]), Color("#e8eeff"))
		"spear":
			var sx0 := px + 10.0 * flip
			var tx := px + (72.0 + swing * 14.0) * flip
			ci.draw_line(Vector2(sx0, py - 22.0), Vector2(tx, py - 26.0), Color("#6d7488"), 3.0, true)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(tx, py - 30.0), Vector2(tx + 12.0 * flip, py - 26.0), Vector2(tx, py - 22.0),
			]), Color("#cfd8ee"))
		"chain":
			# 锁灯：一串渐远的链环，末端挂一盏小灯
			var links := 5
			for i in links:
				var lt := float(i) / float(links - 1)
				var lx := px + (16.0 + 84.0 * lt + swing * 16.0 * lt) * flip
				var ly := py - 24.0 - sin(lt * PI) * 10.0 - swing * 6.0
				ci.draw_arc(Vector2(lx, ly), 4.2, 0.0, TAU, 10, Color("#8e8577"), 1.8, true)
			var ax := px + (108.0 + swing * 18.0) * flip
			var ay := py - 24.0 - swing * 6.0
			ci.draw_circle(Vector2(ax, ay), 6.0, Color("#4a4436"))
			ci.draw_circle(Vector2(ax, ay), 3.2, Color("#ffd98a"))
		"hammer":
			var hx := px + (14.0 + swing * 10.0) * flip
			ci.draw_line(Vector2(px + 6.0 * flip, py - 24.0), Vector2(hx, py - 10.0 - swing * 8.0),
				Color("#6b5a44"), 4.0, true)
			ci.draw_rect(Rect2(hx - 7.0, py - 16.0 - swing * 8.0, 14.0, 12.0), Color("#8a7a5e"))
		"scythe":
			# 灯镰：长柄 + 一道冷色弯刃（刃朝外的一小段圆弧）
			var scx := px + (14.0 + swing * 12.0) * flip
			ci.draw_line(Vector2(px + 4.0 * flip, py - 26.0), Vector2(scx, py - 14.0 - swing * 10.0),
				Color("#5c5568"), 3.4, true)
			var arc_c := Vector2(scx + 13.0 * flip, py - 30.0 - swing * 10.0)
			var a_from := -1.35 if flip > 0.0 else (PI - 1.35)
			ci.draw_arc(arc_c, 19.0, a_from, a_from + 2.7, 16, Color("#c9f0dc"), 3.0, true)
		"crossbow":
			# 灯弩：弩身 + 张开的弓臂 + 一支待发的光矢
			var cx0 := px + (10.0 + swing * 5.0) * flip
			ci.draw_line(Vector2(px + 2.0 * flip, py - 22.0), Vector2(cx0 + 16.0 * flip, py - 24.0),
				Color("#6b6350"), 3.2, true)
			var bx1 := cx0 + 12.0 * flip
			ci.draw_line(Vector2(bx1, py - 32.0), Vector2(bx1, py - 16.0), Color("#8e8577"), 2.4, true)
			ci.draw_line(Vector2(cx0 + 2.0 * flip, py - 24.0), Vector2(bx1 + 8.0 * flip, py - 24.0),
				Color("#bfe4ff"), 2.0, true)
		"staff":
			# 灯杖：竖着的长杖，顶端一颗光球
			var topy := py - 38.0 - swing * 4.0
			ci.draw_line(Vector2(px + 9.0 * flip, py - 6.0), Vector2(px + 13.0 * flip, topy),
				Color("#5b5170"), 3.2, true)
			ci.draw_circle(Vector2(px + 13.0 * flip, topy - 4.0), 6.4, Color("#6d5f8a"))
			ci.draw_circle(Vector2(px + 13.0 * flip, topy - 4.0), 3.6, Color("#e2d6ff"))
		_:
			# blade：最初的短刃
			var bx0 := px + (16.0 + swing * 6.0) * flip
			ci.draw_line(Vector2(hx0, hy0), Vector2(bx0, py - 26.0 - swing * 6.0),
				Color("#c9d3ea"), 3.0, true)
			ci.draw_line(Vector2(px + 4.0 * flip, py - 22.0), Vector2(px + 12.0 * flip, py - 20.0),
				Color("#5a6076"), 5.0, true)


## 盲女：看不见的同行者。斗篷偏暖白，胸口一点光比玩家更稳。
static func girl(ci: CanvasItem, g: Dictionary, cam: Vector2, t: float) -> void:
	var px := Proj.sx(float(g["x"]), cam.x)
	var py := Proj.sy(float(g["y"]), 0.0, cam.y)
	var bob := sin(float(g["wob"])) * 1.6
	shadow(ci, float(g["x"]), float(g["y"]), 11.0, cam, 0.36)
	# 斗篷
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 10.0, py - bob), Vector2(px - 11.0, py - 18.0), Vector2(px - 6.0, py - 26.0),
		Vector2(px + 6.0, py - 26.0), Vector2(px + 11.0, py - 18.0), Vector2(px + 10.0, py - bob),
		Vector2(px, py + 3.0),
	]), Color("#ded4bb"))
	# 头 + 遮住眼睛的布条
	ci.draw_circle(Vector2(px, py - 30.0 - bob), 7.2, Color("#efe6cf"))
	ci.draw_line(Vector2(px - 7.0, py - 31.0 - bob), Vector2(px + 7.0, py - 31.0 - bob),
		Color("#8d7f66"), 2.6, true)
	# 手里的引路灯
	ci.draw_line(Vector2(px + 8.0, py - 14.0 - bob), Vector2(px + 13.0, py - 26.0 - bob),
		Color("#8d7f66"), 1.8, true)
	ci.draw_circle(Vector2(px + 13.0, py - 28.0 - bob), 3.4, Color(1.0, 0.93, 0.70, 0.95))


## 玩家胸口灯火（叠加层）
static func player_core(ci: CanvasItem, p: PlayerState, cam: Vector2, brightness: float, t: float) -> void:
	if p.dead:
		return
	var px := Proj.sx(p.x, cam.x)
	var py := Proj.sy(p.y, p.z + absf(sin(p.walk_t)) * 2.2, cam.y)
	var core := 0.6 + brightness * 0.4 + sin(t * 5.0) * 0.06
	glow(ci, Vector2(px, py - 20.0), 22.0 * core, Color("#ffbe64"), 0.85, 6)
	ci.draw_circle(Vector2(px, py - 20.0), 3.4 * core, Color("#fff4d6"))


# ---------------------------------------------------------------- 敌人

static func enemy(ci: CanvasItem, e: EnemyState, cam: Vector2, t: float) -> void:
	if e.dead and e.death_t > 0.9:
		return
	var def := e.def
	var px := Proj.sx(e.x, cam.x)
	var gy := Proj.sy(e.y, 0.0, cam.y)
	var py := Proj.sy(e.y, 0.0, cam.y)
	var fade := 1.0
	if e.dead:
		fade = clampf(1.0 - e.death_t / 0.9, 0.0, 1.0)
	if e.state == "spawn":
		var s := clampf(1.0 - e.spawn_t / 0.45, 0.0, 1.0)
		ci.draw_set_transform(Vector2(px, py), 0.0, Vector2(1.0, Proj.YSQUASH))
		ci.draw_arc(Vector2.ZERO, 34.0 * (1.0 - s) + 8.0, 0.0, TAU, 32,
			Color(Color.html(str(def["glow"])).r, Color.html(str(def["glow"])).g, Color.html(str(def["glow"])).b, 0.5 * s), 2.0, true)
		end_xf(ci)

	shadow(ci, e.x, e.y, e.r * 0.9 * fade, cam, 0.42 * fade)
	var flash := e.hit_flash > 0.0
	var body := Color.html(str(def["body"]))
	var glowc := Color.html(str(def["glow"]))
	if flash:
		body = body.lerp(Color.WHITE, 0.7)

	var behavior := str(def["behavior"])
	if behavior == "boss":
		_boss_body(ci, e, px, py, gy, body, glowc, t, fade)
	elif str(def["name"]).begins_with("灯烬卫"):
		_guard_body(ci, e, px, py, body, glowc, t, fade)
	elif str(def["name"]).begins_with("灯蛭"):
		_leech_body(ci, e, px, py, body, glowc, t, fade)
	elif str(def["name"]).begins_with("扑灯蛾"):
		_moth_body(ci, e, px, py, body, glowc, t, fade)
	else:
		_shade_body(ci, e, px, py, body, glowc, t, fade)

	# 精英词缀标记：头顶一个符字，一眼看出这只有什么花样
	if not e.dead and e.affix != "":
		var by2 := py - e.h - 22.0
		var col2 := Color.html(str(def.get("glow", "#ffe08a")))
		ci.draw_circle(Vector2(px, by2), 9.0, Color(0.05, 0.05, 0.08, 0.8))
		ci.draw_arc(Vector2(px, by2), 9.0, 0.0, TAU, 20, col2, 1.6, true)
		if font != null:
			ci.draw_string(font, Vector2(px - 7.0, by2 + 6.0), e.affix_name,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, col2)

	# 小血条（只在掉过血之后显示）
	if not e.dead and not e.is_boss() and e.hp < e.max_hp - 0.01:
		var bw := maxf(20.0, e.r * 2.0)
		var bx := px - bw * 0.5
		var by := py - e.h - 12.0
		ci.draw_rect(Rect2(bx, by, bw, 3.5), Color(0.0, 0.0, 0.0, 0.55))
		ci.draw_rect(Rect2(bx, by, bw * e.hp01(), 3.5), Color("#ff6f52"))


## 扑灯蛾：小而快，翅膀一开一合
static func _moth_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var flap := 0.55 + absf(sin(t * 11.0 + e.wob)) * 0.45
	var a := Color(body.r, body.g, body.b, fade)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px, py - 22.0), Vector2(px - 15.0 * flap, py - 30.0), Vector2(px - 6.0, py - 14.0),
	]), a)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px, py - 22.0), Vector2(px + 15.0 * flap, py - 30.0), Vector2(px + 6.0, py - 14.0),
	]), a)
	ci.draw_circle(Vector2(px, py - 18.0), 4.4, Color(body.r * 1.3, body.g * 1.3, body.b * 1.3, fade))
	ci.draw_circle(Vector2(px - 1.6, py - 19.0), 1.3, glowc)
	ci.draw_circle(Vector2(px + 1.6, py - 19.0), 1.3, glowc)


static func _shade_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	var pts := PackedVector2Array()
	pts.append(Vector2(px - r, py))
	for i in 13:
		var a := PI * (float(i) / 12.0)
		var wob := 1.0 + sin(t * 4.0 + float(i) * 1.3 + e.wob) * 0.12
		pts.append(Vector2(px - cos(a) * r * wob, py - sin(a) * h * wob))
	ci.draw_colored_polygon(pts, Color(body.r, body.g, body.b, 0.92 * fade))
	# 触须
	for i in range(-2, 3):
		var x0 := px + float(i) * 5.0
		ci.draw_line(Vector2(x0, py - 2.0),
			Vector2(x0 + float(i) * 5.0 + sin(t * 5.0 + float(i)) * 6.0, py + 12.0),
			Color(body.r, body.g, body.b, 0.8 * fade), 2.0, true)
	# 眼
	var g := 1.0 if e.state == "windup" else 0.7
	ci.draw_circle(Vector2(px - 4.5, py - h * 0.68), 2.6, Color(glowc.r, glowc.g, glowc.b, g * fade))
	ci.draw_circle(Vector2(px + 4.5, py - h * 0.68), 2.6, Color(glowc.r, glowc.g, glowc.b, g * fade))


static func _guard_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	# 躯干
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 0.8, py), Vector2(px - r * 0.72, py - h * 0.78),
		Vector2(px + r * 0.72, py - h * 0.78), Vector2(px + r * 0.8, py),
	]), Color(body.r, body.g, body.b, fade))
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 0.72, py - h * 0.78), Vector2(px + r * 0.72, py - h * 0.78),
		Vector2(px + r * 0.5, py - h * 0.52), Vector2(px - r * 0.5, py - h * 0.52),
	]), Color(0.29, 0.23, 0.16, fade))
	# 头
	ci.draw_circle(Vector2(px, py - h * 0.86), r * 0.4, Color("#3a2e20"))
	# 眼缝
	ci.draw_rect(Rect2(px - r * 0.28, py - h * 0.88, r * 0.56, 3.0),
		Color(glowc.r, glowc.g, glowc.b, 0.95 * fade))
	# 裂缝
	var fa := 0.5 + sin(t * 4.0 + e.wob) * 0.2
	ci.draw_polyline(PackedVector2Array([
		Vector2(px - r * 0.4, py - h * 0.6), Vector2(px - r * 0.1, py - h * 0.4), Vector2(px - r * 0.3, py - h * 0.2),
	]), Color(glowc.r, glowc.g, glowc.b, fa * fade), 1.6, true)
	ci.draw_line(Vector2(px + r * 0.35, py - h * 0.66), Vector2(px + r * 0.12, py - h * 0.42),
		Color(glowc.r, glowc.g, glowc.b, fa * fade), 1.6, true)
	# 大砍刀
	var frac := 0.15
	if e.state == "windup":
		frac = -0.9 + e.t / maxf(0.01, float(e.def["wind"])) * 0.9
	elif e.state == "attack":
		frac = 0.6
	var ang := frac * 0.9 * e.facing - PI * 0.5
	var ox := px + cos(ang) * r * 0.9
	var oy := py - h * 0.6 + sin(ang) * r * 0.9
	ci.draw_line(Vector2(px, py - h * 0.6), Vector2(ox, oy), Color("#5d6579"), 5.0, true)
	ci.draw_line(Vector2(ox, oy), Vector2(ox + cos(ang + 0.9) * 22.0 * e.facing, oy + sin(ang + 0.9) * 22.0), Color("#aab6d0"), 4.0, true)


static func _leech_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	# 鼓胀的囊体
	ci.draw_set_transform(Vector2(px, py - h * 0.4), 0.0, Vector2(1.0, 1.35))
	ci.draw_circle(Vector2.ZERO, r * 0.9, Color(body.r, body.g, body.b, 0.95 * fade))
	end_xf(ci)
	# 口器
	var open := 1.0 if e.state == "windup" else 0.4
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 0.45, py - h * 0.6), Vector2(px + r * 0.45, py - h * 0.6),
		Vector2(px + r * 0.2 * open, py - h * 0.2), Vector2(px - r * 0.2 * open, py - h * 0.2),
	]), Color(glowc.r, glowc.g, glowc.b, 0.55 * fade))
	# 腿
	for i in range(-2, 3):
		var a := float(i) * 0.4
		ci.draw_line(Vector2(px + float(i) * 5.0, py - h * 0.2),
			Vector2(px + float(i) * 9.0, py + 6.0 + sin(t * 6.0 + float(i)) * 2.0),
			Color(body.r, body.g, body.b, 0.85 * fade), 2.0, true)


static func _boss_body(ci: CanvasItem, e: EnemyState, px: float, py: float, gy: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	var puff := 1.0 + sin(t * 2.2 + e.wob) * 0.04
	# 主体：上窄下宽的暗块
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * puff, py),
		Vector2(px - r * 0.66, py - h * 0.55),
		Vector2(px - r * 0.34, py - h * 0.92),
		Vector2(px, py - h * 1.04),
		Vector2(px + r * 0.34, py - h * 0.92),
		Vector2(px + r * 0.66, py - h * 0.55),
		Vector2(px + r * puff, py),
	]), Color(body.r, body.g, body.b, 0.96 * fade))
	# 角
	for s in [-1.0, 1.0]:
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px + s * r * 0.38, py - h * 0.9),
			Vector2(px + s * r * 0.72, py - h * 1.32),
			Vector2(px + s * r * 0.5, py - h * 0.86),
		]), Color(0.13, 0.09, 0.12, fade))
	# 裂开的灯口（吞噬处）
	var maw := 0.5 + 0.5 * sin(t * 2.4)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 0.42, py - h * 0.52),
		Vector2(px + r * 0.42, py - h * 0.52),
		Vector2(px + r * 0.26, py - h * 0.52 + 16.0 * maw),
		Vector2(px - r * 0.26, py - h * 0.52 + 16.0 * maw),
	]), Color(glowc.r, glowc.g, glowc.b, 0.75 * fade))
	# 双目
	ci.draw_circle(Vector2(px - r * 0.3, py - h * 0.82), r * 0.11, Color(1.0, 0.92, 0.7, fade))
	ci.draw_circle(Vector2(px + r * 0.3, py - h * 0.82), r * 0.11, Color(1.0, 0.92, 0.7, fade))


# ---------------------------------------------------------------- 道具

static func prop(ci: CanvasItem, pr: Dictionary, pal: Dictionary, cam: Vector2, t: float) -> void:
	var kind := str(pr["kind"])
	var px := Proj.sx(float(pr["x"]), cam.x)
	var gy := Proj.sy(float(pr["y"]), 0.0, cam.y)
	var py := gy
	var h := float(pr["h"])
	match kind:
		"lighthouse":
			_lighthouse(ci, px, gy, h, pr, pal, t)
		"brazier":
			_brazier(ci, px, gy, pr, t)
		"merchant":
			_merchant(ci, px, gy, t)
		"statue":
			_statue(ci, px, gy, h)
		"dock":
			ci.draw_rect(Rect2(px - 34.0, gy - 10.0, 68.0, 14.0), Color("#4a3f2e"))
		"pillar":
			ci.draw_rect(Rect2(px - 12.0, gy - h, 24.0, h), Color("#39415a"))
			ci.draw_rect(Rect2(px - 16.0, gy - h - 6.0, 32.0, 7.0), Color("#4a5470"))
		"lantern":
			ci.draw_line(Vector2(px, gy), Vector2(px, gy - h), Color("#39415a"), 3.0)
			tex_rot(ci, "light_01", Vector2(px, gy - h), 92.0, 92.0, 0.0,
				Color(1.0, 0.88, 0.58, 0.42))
			ci.draw_circle(Vector2(px, gy - h), 6.0, Color(1.0, 0.82, 0.5, 0.9))
		"tree":
			ci.draw_line(Vector2(px, gy), Vector2(px, gy - h * 0.5), Color("#2e2a24"), 5.0)
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(px - 20.0, gy - h * 0.5), Vector2(px, gy - h),
				Vector2(px + 20.0, gy - h * 0.5),
			]), Color("#252d33"))
		"rubble":
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(px - 16.0, gy), Vector2(px - 8.0, gy - 12.0),
				Vector2(px + 6.0, gy - 14.0), Vector2(px + 16.0, gy),
			]), Color("#2d3346"))
		_:
			ci.draw_circle(Vector2(px, gy), float(pr["r"]), Color("#39415a"))


static func _lighthouse(ci: CanvasItem, px: float, gy: float, h: float,
		pr: Dictionary, pal: Dictionary, t: float) -> void:
	var lit: bool = bool(pr.get("lit", false))
	var t01: float = clampf(float(pr.get("lit_t", 1.0 if lit else 0.0)), 0.0, 1.0)
	if lit:
		pr["lit_t"] = minf(1.0, t01 + 0.02)
	# 塔身：上窄下宽
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 26.0, gy), Vector2(px - 15.0, gy - h * 0.82),
		Vector2(px + 15.0, gy - h * 0.82), Vector2(px + 26.0, gy),
	]), Color("#2a3145"))
	# 横向石带
	for i in 4:
		var yy := gy - h * 0.82 * (float(i) / 4.0) - 8.0
		ci.draw_line(Vector2(px - 24.0 + float(i) * 1.8, yy), Vector2(px + 24.0 - float(i) * 1.8, yy),
			Color(0.0, 0.0, 0.0, 0.35), 2.0, true)
	# 灯室
	ci.draw_rect(Rect2(px - 14.0, gy - h - 16.0, 28.0, 20.0), Color("#38415a"))
	# 灯火
	var core := Color.html("#fff2cc") if lit else Color("#2b3346")
	ci.draw_circle(Vector2(px, gy - h - 6.0), 7.0, core)
	# 塔顶
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 17.0, gy - h - 16.0), Vector2(px, gy - h - 32.0), Vector2(px + 17.0, gy - h - 16.0),
	]), Color("#454f6b"))
	if lit:
		# 塔顶那盏灯：叠一层柔和的径向光晕（素材光晕比纯色圆点有层次）
		tex_rot(ci, "light_01", Vector2(px, gy - h - 6.0), 128.0, 128.0, 0.0,
			Color(1.0, 0.92, 0.70, 0.55))
		# 旋转光束：灯塔亮起的标志
		for i in 2:
			var a := t * 0.5 + float(i) * PI
			var lx := px + cos(a) * 190.0
			var ly := gy - h - 6.0 + sin(a) * 60.0
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(px, gy - h - 6.0),
				Vector2(lx - sin(a) * 20.0, ly + cos(a) * 20.0),
				Vector2(lx + sin(a) * 20.0, ly - cos(a) * 20.0),
			]), Color(1.0, 0.9, 0.62, 0.10 + 0.05 * sin(t * 2.0)))


static func _brazier(ci: CanvasItem, px: float, gy: float, pr: Dictionary, t: float) -> void:
	var lit: bool = bool(pr.get("lit", false))
	# 三足与盆
	ci.draw_line(Vector2(px - 10.0, gy - 8.0), Vector2(px - 13.0, gy), Color("#4a4256"), 3.0)
	ci.draw_line(Vector2(px + 10.0, gy - 8.0), Vector2(px + 13.0, gy), Color("#4a4256"), 3.0)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 18.0, gy - 30.0), Vector2(px + 18.0, gy - 30.0),
		Vector2(px + 12.0, gy - 10.0), Vector2(px - 12.0, gy - 10.0),
	]), Color("#3c3648"))
	ci.draw_line(Vector2(px - 18.0, gy - 30.0), Vector2(px + 18.0, gy - 30.0), Color("#5d5570"), 2.0, true)
	if lit:
		var f := 1.0 + sin(t * 9.0 + float(pr["seed"])) * 0.12
		# 画出来的火苗：素材比"一圈同心圆"真的像火。
		# （这一层是普通混合，真正把它点亮的是叠加层里那团辉光）
		tex_rot(ci, "flame_01", Vector2(px, gy - 34.0 - 24.0 * f), 46.0 * f, 78.0 * f,
			0.0, Color(1.0, 0.86, 0.54, 0.88))
		for i in 3:
			var rr := (6.0 + float(i) * 3.0) * f
			ci.draw_circle(Vector2(px, gy - 34.0 - float(i) * 3.0), rr,
				Color(1.0, 0.82 - float(i) * 0.10, 0.42, 0.45 - float(i) * 0.10))


static func _merchant(ci: CanvasItem, px: float, gy: float, t: float) -> void:
	var bob := sin(t * 2.0) * 1.5
	# 长袍
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 16.0, gy + bob), Vector2(px - 10.0, gy - 40.0 + bob),
		Vector2(px + 10.0, gy - 40.0 + bob), Vector2(px + 16.0, gy + bob),
	]), Color("#3a2f46"))
	# 兜帽
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 12.0, gy - 38.0 + bob), Vector2(px, gy - 54.0 + bob),
		Vector2(px + 12.0, gy - 38.0 + bob),
	]), Color("#4a3d59"))
	# 面部的两点灯
	ci.draw_circle(Vector2(px - 3.5, gy - 40.0 + bob), 1.8, Color("#ffca70"))
	ci.draw_circle(Vector2(px + 3.5, gy - 40.0 + bob), 1.8, Color("#ffca70"))
	# 灯杖
	ci.draw_line(Vector2(px + 16.0, gy + bob), Vector2(px + 20.0, gy - 62.0 + bob), Color("#6b5a44"), 3.0)
	ci.draw_circle(Vector2(px + 20.0, gy - 64.0 + bob), 6.0, Color(1.0, 0.8, 0.45, 0.9))


static func _statue(ci: CanvasItem, px: float, gy: float, h: float) -> void:
	ci.draw_rect(Rect2(px - 22.0, gy - 12.0, 44.0, 12.0), Color("#333b52"))
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - 13.0, gy - 12.0), Vector2(px - 9.0, gy - h),
		Vector2(px + 9.0, gy - h), Vector2(px + 13.0, gy - 12.0),
	]), Color("#3d4660"))
	ci.draw_circle(Vector2(px, gy - h - 6.0), 8.0, Color("#485373"))
	# 胸口的灯（已熄）
	ci.draw_circle(Vector2(px, gy - h * 0.62), 4.0, Color("#2b3346"))


# ---------------------------------------------------------------- 掉落物 / 粒子 / 飘字

static func drop(ci: CanvasItem, d: Dictionary, cam: Vector2, t: float) -> void:
	var px := Proj.sx(float(d["x"]), cam.x)
	var py := Proj.sy(float(d["y"]), float(d["z"]) + 6.0, cam.y)
	var gy := Proj.sy(float(d["y"]), 0.0, cam.y)
	ground_circle(ci, px, gy, 6.0, Color(1.0, 0.8, 0.4, 0.18))
	var kind := str(d["kind"])
	var col := Color("#ffca70")
	if kind == "wick":
		col = Color("#c9a6ff")
	elif kind == "oil":
		col = Color("#8fe0b0")
	var pulse := 1.0 + sin(t * 6.0 + float(d["x"]) * 0.05) * 0.12
	ci.draw_circle(Vector2(px, py), 4.2 * pulse, col)
	ci.draw_circle(Vector2(px, py), 8.0 * pulse, Color(col.r, col.g, col.b, 0.22))


static func particle(ci: CanvasItem, q: Dictionary, cam: Vector2) -> void:
	var life01 := clampf(float(q["life"]) / maxf(0.001, float(q["max_life"])), 0.0, 1.0)
	var px := Proj.sx(float(q["x"]), cam.x)
	var py := Proj.sy(float(q["y"]), float(q["z"]), cam.y)
	var c := Color.html(str(q["color"]))
	# 带贴图的粒子：火星/烟/光点各有各的素材，比一律画小圆点好看得多，
	# 而且"这一下是什么效果"一眼能认出来。
	var tn := str(q.get("tex", ""))
	if tn != "":
		var sz := float(q["size"]) * (0.45 + life01 * 0.75)
		tex_rot(ci, tn, Vector2(px, py), sz, sz, float(q.get("rot", 0.0)),
			Color(c.r, c.g, c.b, c.a * life01), bool(q.get("flip_v", false)))
		return
	ci.draw_circle(Vector2(px, py), float(q["size"]) * (0.4 + life01 * 0.6), Color(c.r, c.g, c.b, life01))


static func float_text(ci: CanvasItem, ft: Dictionary, cam: Vector2) -> void:
	ensure_font()
	var life01 := clampf(float(ft["life"]) / maxf(0.001, float(ft["max_life"])), 0.0, 1.0)
	var px := Proj.sx(float(ft["x"]), cam.x)
	var py := Proj.sy(float(ft["y"]), float(ft["z"]), cam.y)
	var c := Color.html(str(ft["color"]))
	var txt := str(ft["text"])
	var base := float(ft["size"])
	# 刚冒出来的 0.25 秒里放大再回落 —— 数字"弹"出来才有打击感
	var age := 1.0 - life01
	var pop := 1.0 + 0.45 * maxf(0.0, 1.0 - age / 0.25)
	var size := base * pop
	var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x
	var pos := Vector2(px - w * 0.5, py)
	# 暴击那种大数字：背后垫一层同色暖光，在暗底上会自己亮起来
	if base >= 17.0:
		glow(ci, Vector2(px, py - size * 0.36), size * 1.2, c, 0.30 * life01)
	# 描边：八个方向各描一遍。比单层 1px 阴影清楚得多，暗背景上尤其明显
	var oc := Color(0.04, 0.03, 0.03, life01 * 0.85)
	for d in [Vector2(-1.4, 0.0), Vector2(1.4, 0.0), Vector2(0.0, -1.4), Vector2(0.0, 1.4),
			Vector2(-1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0), Vector2(1.0, -1.0)]:
		ci.draw_string(font, pos + d, txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, oc)
	ci.draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size,
		Color(c.r, c.g, c.b, life01))


# ---------------------------------------------------------------- 地面特效

static func effect_ground(ci: CanvasItem, f: Dictionary, cam: Vector2) -> void:
	var kind := str(f["kind"])
	var t01 := clampf(1.0 - float(f["life"]) / maxf(0.001, float(f["max_life"])), 0.0, 1.0)
	var rr := lerpf(float(f["r0"]), float(f["r1"]), t01)
	var col := Color.html(str(f["color"]))
	var px := Proj.sx(float(f["x"]), cam.x)
	var py := Proj.sy(float(f["y"]), 0.0, cam.y)
	var fade := 1.0 - t01
	match kind:
		"ring", "burst", "pull":
			ground_ring(ci, px, py, rr * 0.94, Color(col.r, col.g, col.b, 0.7 * fade), 3.0)
			if kind == "burst":
				ground_ring(ci, px, py, rr * 0.7, Color(col.r, col.g, col.b, 0.35 * fade), 6.0)
			if kind == "pull":
				ground_ring(ci, px, py, rr * 0.62, Color(col.r, col.g, col.b, 0.4 * fade), 2.0)
		"pillar":
			ground_circle(ci, px, py, rr, Color(col.r, col.g, col.b, 0.35 * fade))
		"zone":
			# 持续区域：地面上一圈不散的光斑
			ground_circle(ci, px, py, rr, Color(col.r, col.g, col.b, 0.16))
			ground_ring(ci, px, py, rr, Color(col.r, col.g, col.b, 0.5), 2.0)
		"muzzle":
			ground_circle(ci, px, py, rr, Color(col.r, col.g, col.b, 0.45 * fade))
		"slash":
			var a0 := float(f["angle"]) - float(f["w"]) * 0.5
			var a1 := float(f["angle"]) + float(f["w"]) * 0.5
			ground_arc(ci, px, py, rr * 0.86, a0, a1, Color(col.r, col.g, col.b, 0.8 * fade), 3.0)
		"beam":
			var ang := float(f["angle"])
			var ln := float(f["len"])
			var wd := float(f["w"])
			ci.draw_colored_polygon(PackedVector2Array([
				Vector2(px, py), Vector2(px + cos(ang) * ln, py + sin(ang) * ln * Proj.YSQUASH),
			]) if false else PackedVector2Array([
				Vector2(px - sin(ang) * wd * 0.5, py + cos(ang) * wd * 0.5 * Proj.YSQUASH),
				Vector2(px + sin(ang) * wd * 0.5, py - cos(ang) * wd * 0.5 * Proj.YSQUASH),
				Vector2(px + cos(ang) * ln + sin(ang) * wd * 0.5, py + sin(ang) * ln * Proj.YSQUASH - cos(ang) * wd * 0.5 * Proj.YSQUASH),
				Vector2(px + cos(ang) * ln - sin(ang) * wd * 0.5, py + sin(ang) * ln * Proj.YSQUASH + cos(ang) * wd * 0.5 * Proj.YSQUASH),
			]), Color(col.r, col.g, col.b, 0.55))
