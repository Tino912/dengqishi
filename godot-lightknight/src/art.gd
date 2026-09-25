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

	# 地面纹样按关卡的 `art_style` 分家。
	# **三张地图风格各异**这件事主要落在这一处 + 墙体造型 + 道具种类上，
	# 光靠 palette 换色是不够的：换色只是"同一张图换了个滤镜"，
	# 纹样不同才是"这是另一个地方"。
	match str(level.get("art_style", "court")):
		"quarry":
			_floor_quarry(ci, x0, y0, x1, y1, c1, c2)
		"river":
			_floor_river(ci, x0, y0, x1, y1, c1, c2, t)
		_:
			_floor_court(ci, x0, y0, x1, y1, c1, c2)

	# 地面暗纹：裂缝/血痕（按固定种子，同一关每次一样）
	var rng := Proj.make_rng(int(level["seed"]) + 99)
	for i in 26:
		var x := rng.randf() * lw
		var y := rng.randf() * lh
		var a := Color(0.0, 0.0, 0.0, 0.45)
		ci.draw_line(Vector2(x, y), Vector2(x + (rng.randf() - 0.5) * 90.0, y + (rng.randf() - 0.5) * 90.0),
			a, 1.0 + rng.randf() * 2.0, true)
	end_xf(ci)


## 第一关「灯堡外庭」的地面：**方庭石板** —— 96 的方格棋盘，工整、亮、有人住过。
static func _floor_court(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float,
		c1: Color, c2: Color) -> void:
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


## 第二关「无芯之暗」的地面：**蚀暗矿层** —— 78 的交错砌块（每行错开半格），
## 明暗对比比第一关大得多，看起来像被凿开又塌回去的岩层。
static func _floor_quarry(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float,
		c1: Color, c2: Color) -> void:
	var tw := 78.0
	var th := 52.0
	var iy := floori(y0 / th)
	while float(iy) * th < y1:
		var odd_row := iy % 2 != 0
		var off := tw * 0.5 if odd_row else 0.0
		var ix := floori((x0 - off) / tw)
		while float(ix) * tw + off < x1:
			var tx := float(ix) * tw + off
			var ty := float(iy) * th
			# 用行列做一个确定性的深浅抖动（不用 RNG：floor 是每帧都跑的）
			var j := float((ix * 7 + iy * 13) % 5) * 0.06
			var c := c2.lerp(c1, 0.35 + j)
			ci.draw_rect(Rect2(tx + 1.0, ty + 1.0, tw - 2.0, th - 2.0), c)
			# 每块的石纹：一道斜凿痕
			ci.draw_line(Vector2(tx + 6.0, ty + th - 7.0), Vector2(tx + tw - 10.0, ty + 7.0),
				Color(0.0, 0.0, 0.0, 0.22), 1.0, true)
			ix += 1
		iy += 1


## 第三关「灯河渡口」的地面：**水泽** —— 横向的波纹带，明暗随 `sin` 起伏，
## 而且整片随 `t` 缓慢**向下游推移**（这就是"河在流"的全部来源）。
## 再叠几条横向的碎光，水面的感觉就出来了。
static func _floor_river(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float,
		c1: Color, c2: Color, t: float) -> void:
	var band := 46.0
	# 流动：把整个带的相位按时间平移，看起来就是水在往下游走
	var flow := fmod(t * 26.0, band)
	var iy := floori((y0 - flow) / band)
	while float(iy) * band + flow < y1:
		var wy := float(iy) * band + flow
		var k := sin(wy * 0.021 + t * 0.8)
		var c := c2.lerp(c1, clampf(0.5 + 0.5 * k, 0.0, 1.0))
		ci.draw_rect(Rect2(x0, wy, x1 - x0, band + 1.0), c)
		# 波峰的碎光：一条断续的浅色横线
		if k > 0.55:
			var seg := 140.0
			var sx := floorf(x0 / seg) * seg
			while sx < x1:
				ci.draw_line(Vector2(sx + 18.0, wy + band * 0.42),
					Vector2(sx + 96.0, wy + band * 0.42),
					Color(0.62, 0.86, 0.86, (k - 0.55) * 0.42), 1.6, true)
				sx += seg
		iy += 1


# ---------------------------------------------------------------- 墙

## 墙体。`style` 跟着关卡的 `art_style` 走 —— 三张图的墙**不是换色**：
## court 是砌得整整齐齐的砖墙，quarry 是崩了口的凿岩，river 是打进水里的木桩。
static func wall(ci: CanvasItem, w: Array, pal: Dictionary, cam: Vector2, style := "court") -> void:
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
	if style == "quarry":
		bands = 5      # 岩层：层少而厚，明暗落差大
	elif style == "river":
		bands = 7
	for i in bands:
		var t0 := float(i) / float(bands)
		var t1 := float(i + 1) / float(bands)
		var c := c_top.lerp(c_wall, minf(1.0, t0 * 2.6)).lerp(Color(0.03, 0.04, 0.07), maxf(0.0, t0 - 0.35) / 0.65)
		ci.draw_rect(Rect2(x0, tS + (yS - tS) * t0, x1 - x0, (yS - tS) * (t1 - t0) + 0.8), c)

	# 立面细节：三种风格各自一套
	match style:
		"quarry":
			_wall_face_quarry(ci, x0, x1, tS, yS, c_rim)
		"river":
			_wall_face_river(ci, x0, x1, tS, yS)
		_:
			# 砖缝
			var yy := tS + 11.0
			while yy < yS:
				ci.draw_line(Vector2(x0, yy), Vector2(x1, yy), Color(0.0, 0.0, 0.0, 0.35), 1.0, true)
				yy += 13.0

	# 顶面
	var ct := c_wall
	if style == "river":
		# 木栈的顶面偏暖，和青绿的水面拉开
		ct = c_wall.lerp(Color("#6b4a30"), 0.55)
	ci.draw_rect(Rect2(x0, tN, x1 - x0, yS - yN), ct)
	if style == "quarry":
		# 崩掉的岩口：顶边一道断续的亮线，而不是一条通线
		var bx := x0
		while bx < x1:
			ci.draw_line(Vector2(bx, tN + 1.0), Vector2(minf(bx + 26.0, x1), tN + 1.0),
				Color(c_rim.r, c_rim.g, c_rim.b, 0.34), 1.3, true)
			bx += 44.0
	elif style == "river":
		# 顶面木纹：横向的板缝
		var top_h := yS - yN
		var py := tN + 6.0
		while py < tN + top_h:
			ci.draw_line(Vector2(x0, py), Vector2(x1, py), Color(0.0, 0.0, 0.0, 0.30), 1.0, true)
			py += 9.0
		ci.draw_line(Vector2(x0, tN), Vector2(x1, tN), Color(c_rim.r, c_rim.g, c_rim.b, 0.30), 1.4, true)
	else:
		ci.draw_line(Vector2(x0, tN), Vector2(x1, tN), Color(c_rim.r, c_rim.g, c_rim.b, 0.28), 1.4, true)
	ci.draw_line(Vector2(x0, yS), Vector2(x1, yS), Color(0.0, 0.0, 0.0, 0.5), 1.0, true)

	if style == "river":
		# 水线：木桩入水处的湿痕（这一条最能把"这是河"讲清楚）
		ci.draw_rect(Rect2(x0, yS - 8.0, x1 - x0, 8.0), Color(0.04, 0.13, 0.15, 0.55))


## 凿岩立面：层理宽度不规则（由位置确定性决定），再补一道竖直裂缝
static func _wall_face_quarry(ci: CanvasItem, x0: float, x1: float, tS: float, yS: float,
		c_rim: Color) -> void:
	var yy := tS + 14.0
	var i := 0
	while yy < yS:
		# 18~34 交替：不用 RNG（每帧都跑，且必须完全确定）
		var step := 18.0 + float((i * 37) % 17)
		ci.draw_line(Vector2(x0, yy), Vector2(x1, yy), Color(0.0, 0.0, 0.0, 0.38), 1.4, true)
		# 层理上的短竖纹，像被凿开的面
		var vx := x0 + 24.0 + float((i * 53) % 90)
		while vx < x1:
			ci.draw_line(Vector2(vx, yy), Vector2(vx, minf(yy + step * 0.8, yS)),
				Color(c_rim.r, c_rim.g, c_rim.b, 0.10), 1.0, true)
			vx += 120.0
		yy += step
		i += 1


## 木桩立面：密集的竖直木纹 + 两道横向铁箍
static func _wall_face_river(ci: CanvasItem, x0: float, x1: float, tS: float, yS: float) -> void:
	var vx := x0 + 3.0
	var i := 0
	while vx < x1:
		var dark := 0.26 + float((i * 29) % 13) * 0.030
		ci.draw_line(Vector2(vx, tS), Vector2(vx, yS), Color(0.0, 0.0, 0.0, dark), 1.3, true)
		vx += 7.0
		i += 1
	# 铁箍
	for frac in [0.26, 0.72]:
		var hy := tS + (yS - tS) * float(frac)
		ci.draw_line(Vector2(x0, hy), Vector2(x1, hy), Color(0.30, 0.24, 0.18, 0.75), 3.0, true)


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

	match body_kind(def):
		"moth":
			_moth_body(ci, e, px, py, body, glowc, t, fade)
		"guard":
			_guard_body(ci, e, px, py, body, glowc, t, fade)
		"leech":
			_leech_body(ci, e, px, py, body, glowc, t, fade)
		"ashling":
			_ashling_body(ci, e, px, py, body, glowc, t, fade)
		"tidehusk":
			_tidehusk_body(ci, e, px, py, body, glowc, t, fade)
		"lanternjaw":
			_lanternjaw_body(ci, e, px, py, body, glowc, t, fade)
		"boss_shadow":
			_boss_shadow_body(ci, e, px, py, gy, body, glowc, t, fade)
		"boss_devourer":
			_boss_body(ci, e, px, py, gy, body, glowc, t, fade)
		_:
			_shade_body(ci, e, px, py, body, glowc, t, fade)

	_enemy_status_marks(ci, e, px, py, glowc, t, fade)

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


## 这个 def 会走哪一套身体几何。
##
## 抽成**独立函数**是为了让自检能断言"每个敌人都长得不一样" ——
## 否则断言就得去解析绘制代码。⚠️ 加新敌人必须在这里登记：
## 没登记的会静默落到 `_shade_body`（变成"又一只灯影"），而画面照常能跑。
##
## 注意「噬灯者·幼体」与「噬灯者」**故意共用** `boss_devourer`：
## 它们是同一个东西的幼体与成体，只靠体型与配色区分。
static func body_kind(def: Dictionary) -> String:
	if str(def.get("behavior", "")) == "boss":
		return "boss_" + str(def.get("boss_style", "devourer"))
	var nm := str(def.get("name", ""))
	if nm.begins_with("灯烬卫"):
		return "guard"
	if nm.begins_with("灯蛭"):
		return "leech"
	if nm.begins_with("扑灯蛾"):
		return "moth"
	if nm.begins_with("灰烬鬼"):
		return "ashling"
	if nm.begins_with("灯河浮尸"):
		return "tidehusk"
	if nm.begins_with("衔灯兽"):
		return "lanternjaw"
	return "shade"


## 元素状态留在身上的痕迹（形状层）。
##
## 叠光层那一半（火苗、电弧）在 world.draw_bloom 里 —— 与工程一贯的分工一致：
## 这里画"不发光也看得见的东西"（冰壳、毒雾、头顶刻字），
## 那里画"要靠加法混合才亮得起来的东西"。
static func _enemy_status_marks(ci: CanvasItem, e: EnemyState, px: float, py: float,
		glowc: Color, t: float, fade: float) -> void:
	if e.dead:
		return
	var h := e.h
	# 冰：一层半透明的壳，把整只包住（还带几道冰晶裂纹）
	if e.frozen_t > 0.0:
		var wob := 1.0 + sin(t * 9.0 + e.wob) * 0.04
		ci.draw_set_transform(Vector2(px, py - h * 0.42), 0.0, Vector2(1.0, 1.55 * wob))
		ci.draw_circle(Vector2.ZERO, e.r * 1.06, Color(0.60, 0.86, 1.0, 0.34 * fade))
		ci.draw_arc(Vector2.ZERO, e.r * 1.06, 0.0, TAU, 28, Color(0.80, 0.94, 1.0, 0.60 * fade), 1.6, true)
		end_xf(ci)
		# 冰晶
		for i in 3:
			var fx := px + float(i - 1) * e.r * 0.55
			ci.draw_line(Vector2(fx, py - h * 0.86), Vector2(fx + 3.0, py - h * 1.02),
				Color(0.86, 0.96, 1.0, 0.55 * fade), 1.6, true)
	# 毒：体表泛绿雾 + 两个上浮的气泡感圆点（气泡的"上浮"交给 bloom 层）
	if e.venom_t > 0.0:
		ci.draw_set_transform(Vector2(px, py - h * 0.42), 0.0, Vector2(1.0, 1.5))
		ci.draw_circle(Vector2.ZERO, e.r * 1.02, Color(0.42, 0.78, 0.30, 0.20 * fade))
		end_xf(ci)
	# 头顶元素刻字：最后被打了什么元素，一眼看得见
	if e.elem_t > 0.0:
		var ec := Color.html(str(Content.element(e.last_elem).get("color", "#ffffff")))
		var a := clampf(e.elem_t / 0.4, 0.0, 1.0)
		var gy2 := py - h - 34.0
		ci.draw_circle(Vector2(px, gy2), 8.5, Color(0.05, 0.05, 0.08, 0.72 * a))
		ci.draw_arc(Vector2(px, gy2), 8.5, 0.0, TAU, 18, Color(ec.r, ec.g, ec.b, a), 1.4, true)
		if font != null:
			ci.draw_string(font, Vector2(px - 6.0, gy2 + 5.5), str(Content.element(e.last_elem).get("glyph", "?")),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(ec.r, ec.g, ec.b, a))


## 灰烬鬼：一团烧剩的灰堆里伸出来的东西 —— 矮、宽、拖着两条灰带
static func _ashling_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	var a := Color(body.r, body.g, body.b, fade)
	# 灰堆（下宽上尖）
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 1.05, py), Vector2(px - r * 0.62, py - h * 0.55),
		Vector2(px, py - h * 1.02), Vector2(px + r * 0.62, py - h * 0.55),
		Vector2(px + r * 1.05, py),
	]), a)
	# 两条拖在身后的灰带（跑起来像被风吹散的灰）
	for s in [-1.0, 1.0]:
		var sw := sin(t * 7.0 + e.wob + s) * 5.0
		ci.draw_polyline(PackedVector2Array([
			Vector2(px + s * r * 0.5, py - h * 0.5),
			Vector2(px + s * r * 0.9 + sw, py - h * 0.24),
			Vector2(px + s * r * 1.1 - sw, py + 2.0),
		]), Color(body.r * 1.6, body.g * 1.4, body.b * 1.3, 0.5 * fade), 2.2, true)
	# 裂隙里的余烬（这是它唯一亮的地方）
	var fa := 0.55 + sin(t * 6.0 + e.wob) * 0.3
	for i in 3:
		var fx := px + float(i - 1) * r * 0.42
		ci.draw_line(Vector2(fx, py - h * 0.18), Vector2(fx + 2.0, py - h * 0.72),
			Color(glowc.r, glowc.g, glowc.b, fa * fade), 2.0, true)


## 灯河浮尸：泡胀的人形残骸，一肩高一肩低，拖着水草
static func _tidehusk_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	var bob := sin(t * 2.4 + e.wob) * 2.0
	var a := Color(body.r, body.g, body.b, fade)
	# 躯干：故意不对称（一肩高一肩低）——这是"泡歪了"，和灯烬卫的方正对比很大
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 0.9, py), Vector2(px - r * 0.86, py - h * 0.62),
		Vector2(px - r * 0.30, py - h * 0.90), Vector2(px + r * 0.52, py - h * 0.74),
		Vector2(px + r * 0.88, py - h * 0.34), Vector2(px + r * 0.82, py),
	]), a)
	# 头：低垂、偏一侧
	ci.draw_circle(Vector2(px + r * 0.12, py - h * 0.92 + bob), r * 0.42,
		Color(body.r * 1.15, body.g * 1.15, body.b * 1.2, fade))
	# 长臂（重击的来源）：一只手拖到地上
	var arm := 0.5 + 0.5 * sin(t * 3.0 + e.wob)
	var ax := px - r * 1.1
	var ay := py - h * 0.30 + arm * h * 0.34
	ci.draw_line(Vector2(px - r * 0.7, py - h * 0.7), Vector2(ax, ay),
		Color(body.r * 1.2, body.g * 1.2, body.b * 1.25, fade), 6.0, true)
	# 水草
	for i in range(-1, 2):
		var wx := px + float(i) * r * 0.6
		ci.draw_polyline(PackedVector2Array([
			Vector2(wx, py - h * 0.1), Vector2(wx + 4.0 + float(i) * 3.0, py + h * 0.14),
			Vector2(wx - 2.0, py + h * 0.3),
		]), Color(0.34, 0.62, 0.44, 0.55 * fade), 2.0, true)
	# 眼：两团在水下发绿的光
	ci.draw_circle(Vector2(px + r * 0.02, py - h * 0.92 + bob), 2.4,
		Color(glowc.r, glowc.g, glowc.b, 0.95 * fade))
	ci.draw_circle(Vector2(px + r * 0.34, py - h * 0.90 + bob), 2.0,
		Color(glowc.r, glowc.g, glowc.b, 0.8 * fade))


## 衔灯兽：四足低伏，嘴里叼着一盏灯 —— 它亮的地方就是嘴
static func _lanternjaw_body(ci: CanvasItem, e: EnemyState, px: float, py: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	var breathe := 1.0 + sin(t * 3.4 + e.wob) * 0.05
	var a := Color(body.r, body.g, body.b, fade)
	# 低伏的躯体
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - r * 1.1, py - h * 0.06), Vector2(px - r * 1.15, py - h * 0.52),
		Vector2(px - r * 0.10, py - h * 0.78 * breathe), Vector2(px + r * 0.92, py - h * 0.62),
		Vector2(px + r * 1.12, py - h * 0.24), Vector2(px + r * 0.86, py - h * 0.04),
	]), a)
	# 四条腿
	for i in 4:
		var lx := px - r * 0.85 + float(i) * r * 0.6
		var lift := sin(t * 8.0 + float(i) * 1.7 + e.wob) * 3.0
		ci.draw_line(Vector2(lx, py - h * 0.14), Vector2(lx + 2.0, py + 6.0 + lift),
			Color(body.r * 1.2, body.g * 1.2, body.b * 1.2, 0.9 * fade), 2.6, true)
	# 长吻（前伸）
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px + r * 0.86, py - h * 0.60), Vector2(px + r * 1.62, py - h * 0.50),
		Vector2(px + r * 1.60, py - h * 0.30), Vector2(px + r * 0.88, py - h * 0.28),
	]), Color(body.r * 1.1, body.g * 1.1, body.b * 1.15, fade))
	# 嘴里的灯：开合（蓄力时张大）
	var open := 1.0 if e.state == "windup" else 0.45
	var lx2 := px + r * 1.5
	var ly2 := py - h * 0.42
	ci.draw_circle(Vector2(lx2, ly2), 4.0 + 3.0 * open,
		Color(glowc.r, glowc.g, glowc.b, 0.95 * fade))
	# 背脊上的三根倒刺
	for i in 3:
		var sx := px - r * 0.5 + float(i) * r * 0.5
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(sx - 4.0, py - h * 0.66), Vector2(sx, py - h * 0.95),
			Vector2(sx + 4.0, py - h * 0.64),
		]), Color(0.16, 0.12, 0.09, fade))


## 灯魔之影（终章 Boss）：**没有实体**的一块黑暗，只有轮廓与里面那些灯
##
## 与噬灯者（`_boss_body`）刻意做成两种东西：噬灯者是"有嘴有角的野兽"，
## 灯魔之影是"一团会呼吸的黑"。判据是 `def["boss_style"]`。
static func _boss_shadow_body(ci: CanvasItem, e: EnemyState, px: float, py: float, gy: float,
		body: Color, glowc: Color, t: float, fade: float) -> void:
	var r := e.r
	var h := e.h
	# 主体：一团由 sine 驱动的软边黑块（不是多边形硬边）
	var pts := PackedVector2Array()
	var n := 20
	for i in n:
		var a := TAU * float(i) / float(n)
		var wob := 1.0 + sin(a * 3.0 + t * 1.6 + e.wob) * 0.14 \
			+ sin(a * 5.0 - t * 2.1) * 0.07
		pts.append(Vector2(px + cos(a) * r * 1.05 * wob,
			py - h * 0.52 + sin(a) * h * 0.56 * wob))
	ci.draw_colored_polygon(pts, Color(0.03, 0.02, 0.05, 0.94 * fade))
	# 轮廓：一圈冷紫的边，把"这是一团东西"勾出来
	var ring := PackedVector2Array()
	for i in n + 1:
		var a2 := TAU * float(i) / float(n)
		var wob2 := 1.0 + sin(a2 * 3.0 + t * 1.6 + e.wob) * 0.14 + sin(a2 * 5.0 - t * 2.1) * 0.07
		ring.append(Vector2(px + cos(a2) * r * 1.05 * wob2,
			py - h * 0.52 + sin(a2) * h * 0.56 * wob2))
	ci.draw_polyline(ring, Color(glowc.r, glowc.g, glowc.b, 0.42 * fade), 2.0, true)
	# 里面浮着几盏被它吃掉的灯（缓慢自转、忽明忽暗）
	for i in 4:
		var ang := t * 0.5 + float(i) * TAU / 4.0 + e.wob
		var rr := r * (0.32 + 0.12 * float(i % 2))
		var lx := px + cos(ang) * rr
		var ly := py - h * 0.52 + sin(ang) * rr * 0.72
		var ta := 0.45 + 0.45 * sin(t * 2.6 + float(i) * 1.9)
		ci.draw_circle(Vector2(lx, ly), 3.0 + 1.6 * ta, Color(1.0, 0.86, 0.56, ta * fade))
	# 一对狭长的眼
	for s in [-1.0, 1.0]:
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px + s * r * 0.10, py - h * 0.72),
			Vector2(px + s * r * 0.46, py - h * 0.66),
			Vector2(px + s * r * 0.46, py - h * 0.60),
			Vector2(px + s * r * 0.10, py - h * 0.66),
		]), Color(glowc.r, glowc.g, glowc.b, 0.9 * fade))


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
		"chest":
			_chest(ci, px, gy, pr, t)
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


## 宝箱：没开是闭合的盖子 + 从缝里漏出来的一线光（会呼吸）；
## 开了就把盖子往后掀、露出里面的暗。缝光是有意留的"路标"——
## 全黑的地图上得让人看见"那边有个好东西"。
static func _chest(ci: CanvasItem, px: float, gy: float, pr: Dictionary, t: float) -> void:
	var opened: bool = bool(pr.get("opened", false))
	var hw := 21.0       # 半宽
	var dep := 13.0      # 进深（2.5D 压扁）
	var body_h := 20.0   # 箱体高
	var wood := Color("#4a3524")
	var wood_hi := Color("#63482f")
	var iron := Color("#87775b")

	# 地面投影
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - hw - 5.0, gy), Vector2(px - hw + 5.0, gy - dep * 0.7),
		Vector2(px + hw + 5.0, gy - dep * 0.7), Vector2(px + hw - 5.0, gy),
	]), Color(0.0, 0.0, 0.0, 0.32))

	# 箱体南立面 + 顶面（顶面亮一点，给出体积感）
	ci.draw_rect(Rect2(px - hw, gy - body_h, hw * 2.0, body_h), wood)
	ci.draw_colored_polygon(PackedVector2Array([
		Vector2(px - hw, gy - body_h), Vector2(px - hw, gy - body_h - dep),
		Vector2(px + hw, gy - body_h - dep), Vector2(px + hw, gy - body_h),
	]), wood_hi)
	# 两道铁箍
	for fx in [-0.55, 0.55]:
		ci.draw_rect(Rect2(px + hw * fx - 2.0, gy - body_h, 4.0, body_h), iron)

	if opened:
		# 掀开的盖子：向后倒，露出箱内的暗
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px - hw, gy - body_h - dep),
			Vector2(px - hw - 4.0, gy - body_h - dep - 15.0),
			Vector2(px + hw + 4.0, gy - body_h - dep - 15.0),
			Vector2(px + hw, gy - body_h - dep),
		]), Color("#38281a"))
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px - hw + 3.0, gy - body_h - dep + 4.0),
			Vector2(px + hw - 3.0, gy - body_h - dep + 4.0),
			Vector2(px + hw - 3.0, gy - body_h - 1.0),
			Vector2(px - hw + 3.0, gy - body_h - 1.0),
		]), Color("#120c07"))
	else:
		# 闭合的盖子：中间起脊
		var top := gy - body_h - dep
		ci.draw_colored_polygon(PackedVector2Array([
			Vector2(px - hw, top), Vector2(px, top - 9.0),
			Vector2(px + hw, top), Vector2(px, top + 5.0),
		]), Color("#6f5136"))
		# 缝光：呼吸着的暖光（比画个"！"更含蓄）
		var pulse := 0.45 + 0.25 * sin(t * 2.4 + float(pr.get("pulse", 0.0)))
		tex_rot(ci, "light_01", Vector2(px, gy - body_h - dep * 0.4), 78.0, 56.0, 0.0,
			Color(1.0, 0.86, 0.55, pulse * 0.55))
		# 锁扣
		ci.draw_circle(Vector2(px, gy - body_h - 1.0), 3.6, Color("#ffce7a"))


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
		"arc":
			# 雷元素的连锁电弧：地面上那条是**投影**（暗一点），亮的芯在 bloom 层
			var ap := arc_pts(float(f["x"]), float(f["y"]), float(f["z"]),
				float(f["x2"]), float(f["y2"]), float(f["z2"]), cam)
			ci.draw_polyline(ap, Color(col.r, col.g, col.b, 0.45 * fade), 2.0, true)


## 电弧的形状：两点之间来回折的折线（屏幕坐标）。
##
## 折点用**确定性的伪随机**（由下标与端点推出来，黄金角铺开），不用 RNG ——
## 它在 `_draw` 里每帧都算，而 `_draw` **绝不能消耗随机流**。
static func arc_pts(ax: float, ay: float, az: float, bx: float, by: float, bz: float,
		cam: Vector2, n := 7, amp := 8.5) -> PackedVector2Array:
	var a := gpos(ax, ay, az, cam)
	var b := gpos(bx, by, bz, cam)
	var dx := b.x - a.x
	var dy := b.y - a.y
	var ln := maxf(1.0, sqrt(dx * dx + dy * dy))
	var pts := PackedVector2Array()
	for i in n + 1:
		var k := float(i) / float(n)
		var p := a.lerp(b, k)
		var off := 0.0
		if i > 0 and i < n:
			off = sin(float(i) * 2.39996323 + ax * 0.021 + by * 0.013) * amp
		pts.append(Vector2(p.x - dy / ln * off, p.y + dx / ln * off))
	return pts
