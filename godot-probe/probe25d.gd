extends Node2D
## LightKnight 光照验证 · 第二探针：2.5D 俯视下的遮挡体摆法
##
## 第一探针证明了「Godot 的 2D 光会被墙挡住」，但那是纯正面视角：墙 = 屏幕上一个矩形，
## 遮挡体与它重合即可。
##
## 本项目的表现方式是 2.5D 俯视（地板竖压 YSQUASH=0.62，墙从地面足迹向屏幕上方立起 h）。
## 此时墙在屏幕上由两块语义不同的区域拼成，与 render.ts 的 drawWall 完全一致：
##     顶面   ：足迹整体上移 h 的那块矩形
##     南立面 ：从足迹南沿向上立起 h 的矩形
## 屏幕上的可见整体 = 顶面 ∪ 南立面（= 轮廓），而「地面足迹」只是轮廓里偏下的一条横带。
## 于是「遮挡体贴哪一块」成了新问题 —— 这就是本探针要解决的最后一个未知数。
##
## 要回答：
##   Q1 遮挡体该贴地面足迹，还是贴画出来的整体轮廓？
##   Q2 两种模型各自会出现什么可见缺陷？（侧光时越过墙顶漏光 / 墙面被一条暗带切开）
##   Q3 想让墙脚受光，该削哪条边、削多少？
##   Q4 灯的贴图该用屏幕正圆，还是竖压成椭圆（= 地面正圆）？
##
## 墙型全部照抄 levels.ts 里真实存在的尺寸，结论可直接迁移。
## 输出：res://shots25d/*.png + report.json，并向 stdout 打印 LKRPT 段。

const OUT_DIR := "res://shots25d"
const VIEW_W := 1280
const VIEW_H := 720

## 2.5D 投影：屏幕 y = 世界 y * YSQUASH（与 Web 版 render.ts 的 YSQUASH 一致）
const YSQUASH := 0.62

## 灯：屏幕半径约 440px、energy 1.15
## 对照游戏内玩家灯圈：radius = 150 + 连击×7（连击 40 时 430），energy 1.15。
## 取 440 ≈ 满连击档，是为了让「越过墙顶」的漏光在采样点上仍然可辨 —— 偏亮的一档，不是最弱档。
const LIGHT_SCALE := 3.44
const ENERGY := 1.15
const GAP_SIDE := 90.0
const GAP_FRONT := 120.0
## 「墙体未受光」基准：墙色 (0.34,0.32,0.38) × 压暗 (0.05,0.06,0.10) ≈ 0.0245
const BASE_THR := 0.05

## 墙型（世界坐标；数字来自 levels.ts 的真实关卡数据）
##   w 宽 / d 进深（→ 屏幕上的足迹高度 = d*0.62）/ h 立起来的高度（屏幕像素）
const WALLS := {
	"fence":  {"x": 560.0, "y": 520.0, "w": 200.0, "d": 60.0,  "h": 46.0},   ## 细墙（最常见）
	"pillar": {"x": 560.0, "y": 520.0, "w": 60.0,  "d": 60.0,  "h": 46.0},   ## 窄柱
	"block":  {"x": 560.0, "y": 520.0, "w": 140.0, "d": 400.0, "h": 54.0},   ## 厚块（如灯塔基座）
	"tall":   {"x": 560.0, "y": 520.0, "w": 200.0, "d": 60.0,  "h": 150.0},  ## 高墙（假定，用来看缺陷随 h 放大）
}

## 遮挡体摆法
	##   foot     —— 只贴地面足迹（物理上"正确"的那个）
	##   sil      —— 贴屏幕上画出来的整体轮廓（顶面 ∪ 南立面）
	##   sil_b16  —— 轮廓，只把底边削掉 16px（← 本探针推荐的摆法）
	##   sil_b8   —— 同上但只削 8px（调节刻度：削多少 = 墙脚亮多高）
	##   sil_in16 —— 轮廓四边均匀内缩 16px（把第一探针的规则直接搬过来的写法）
const CASES := [
	## 侧光（最刁钻的方向：灯与足迹同高，最容易"从墙顶翻过去"）
	{"name": "W_fence_foot",  "wall": "fence",  "occ": "foot",     "light": "W"},
	{"name": "W_fence_sil",   "wall": "fence",  "occ": "sil",      "light": "W"},
	{"name": "W_fence_b8",    "wall": "fence",  "occ": "sil_b8",   "light": "W"},
	{"name": "W_fence_b16",   "wall": "fence",  "occ": "sil_b16",  "light": "W"},
	{"name": "W_fence_in16",  "wall": "fence",  "occ": "sil_in16", "light": "W"},
	{"name": "W_pillar_foot", "wall": "pillar", "occ": "foot",     "light": "W"},
	{"name": "W_pillar_b16",  "wall": "pillar", "occ": "sil_b16",  "light": "W"},
	{"name": "W_block_foot",  "wall": "block",  "occ": "foot",     "light": "W"},
	{"name": "W_block_b16",   "wall": "block",  "occ": "sil_b16",  "light": "W"},
	{"name": "W_tall_foot",   "wall": "tall",   "occ": "foot",     "light": "W"},
	{"name": "W_tall_b16",    "wall": "tall",   "occ": "sil_b16",  "light": "W"},
	## 正面光（玩家站在墙前面 —— 最常见的场景）
	{"name": "S_fence_foot",  "wall": "fence",  "occ": "foot",     "light": "S"},
	{"name": "S_fence_sil",   "wall": "fence",  "occ": "sil",      "light": "S"},
	{"name": "S_fence_b8",    "wall": "fence",  "occ": "sil_b8",   "light": "S"},
	{"name": "S_fence_b16",   "wall": "fence",  "occ": "sil_b16",  "light": "S"},
	{"name": "S_block_b16",   "wall": "block",  "occ": "sil_b16",  "light": "S"},
	## 背光（灯在墙后）
	{"name": "N_fence_foot",  "wall": "fence",  "occ": "foot",     "light": "N"},
	{"name": "N_fence_b16",   "wall": "fence",  "occ": "sil_b16",  "light": "N"},
	## 东侧光（与西侧对称，做交叉验证）
	{"name": "E_fence_foot",  "wall": "fence",  "occ": "foot",     "light": "E"},
	{"name": "E_fence_b16",   "wall": "fence",  "occ": "sil_b16",  "light": "E"},
	## 灯的形状：屏幕正圆 vs 竖压成椭圆（= 地面正圆）。空场景，只量光斑能照多远。
	{"name": "shape_circle", "wall": "none", "occ": "none", "light": "C", "bare": true, "shape": "circle"},
	{"name": "shape_floor",  "wall": "none", "occ": "none", "light": "C", "bare": true, "shape": "floor"},
]

var _sub: SubViewport
var _world: Node2D
var _tex_cache := {}
var _report := {
	"godot": "",
	"renderer": "",
	"viewport": [VIEW_W, VIEW_H],
	"ysquash": YSQUASH,
	"cases": {},
	"verdict": {},
	"errors": [],
}


func _ready() -> void:
	_report["godot"] = Engine.get_version_info()["string"]
	_report["renderer"] = RenderingServer.get_video_adapter_name()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	_sub = SubViewport.new()
	_sub.size = Vector2i(VIEW_W, VIEW_H)
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.transparent_bg = false
	_sub.disable_3d = true
	add_child(_sub)

	_world = Node2D.new()
	_sub.add_child(_world)

	_run()


func _run() -> void:
	for c in CASES:
		await _run_case(c)
	_judge()
	_write_report()
	get_tree().quit()


# ------------------------------------------------------------------ 几何

func _geo(wname: String) -> Dictionary:
	var w: Dictionary = WALLS[wname]
	## 世界足迹 → 屏幕足迹（x 不变，y 竖压，深度也跟着竖压）
	var f := Rect2(w["x"], w["y"] * YSQUASH, w["w"], w["d"] * YSQUASH)
	## 屏幕上的可见整体 = 足迹 ∪ 南立面 = 足迹上沿再往上 h 的一块
	var sil := Rect2(f.position.x, f.position.y - w["h"], f.size.x, f.size.y + w["h"])
	return {"foot": f, "sil": sil, "h": w["h"], "name": wname}


func _light_pos(geo: Dictionary, dir: String) -> Vector2:
	var f: Rect2 = geo["foot"]
	var s: Rect2 = geo["sil"]
	var mid := f.position.y + f.size.y * 0.5
	match dir:
		"W": return Vector2(f.position.x - GAP_SIDE, mid)
		"E": return Vector2(f.position.x + f.size.x + GAP_SIDE, mid)
		"S": return Vector2(f.position.x + f.size.x * 0.5, f.position.y + f.size.y + GAP_FRONT)
		"N": return Vector2(f.position.x + f.size.x * 0.5, s.position.y - GAP_FRONT)
	return Vector2(640.0, 360.0)


func _patches(geo: Dictionary) -> Dictionary:
	var f: Rect2 = geo["foot"]
	var h: float = geo["h"]
	var x0 := f.position.x
	var y0 := f.position.y
	var fw := f.size.x
	var fh := f.size.y
	var ybot := y0 + fh
	var ytop := y0 - h
	var mid := y0 + fh * 0.5
	var tfh := minf(fh - 8.0, 24.0)
	return {
		"base":    Rect2(x0 + fw * 0.25, ybot - 9.0, fw * 0.5, 8.0),
		"band":    Rect2(x0 + fw * 0.25, y0 + 3.0, fw * 0.5, maxf(4.0, fh - 6.0)),
		"topface": Rect2(x0 + fw * 0.25, ytop + (fh - tfh) * 0.5, fw * 0.5, tfh),
		"front":   Rect2(x0 + fw * 0.25, ybot + 14.0, fw * 0.5, 20.0),
		"behind":  Rect2(x0 + fw * 0.25, ytop - 34.0, fw * 0.5, 20.0),
		"far":     Rect2(x0 + fw * 0.25, ytop - 94.0, fw * 0.5, 20.0),
		"left":    Rect2(x0 - 85.0, mid - 25.0, 60.0, 50.0),
		"right":   Rect2(x0 + fw + 25.0, mid - 25.0, 60.0, 50.0),
	}


func _rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position,
		r.position + Vector2(r.size.x, 0.0),
		r.position + Vector2(r.size.x, r.size.y),
		r.position + Vector2(0.0, r.size.y),
	])


func _occ_rect(kind: String, f: Rect2, h: float) -> Rect2:
	var sil := Rect2(f.position.x, f.position.y - h, f.size.x, f.size.y + h)
	match kind:
		"foot": return f
		"sil": return sil
		"sil_in16": return sil.grow(-16.0)
	if kind.begins_with("sil_b"):
		## sil_bN = 轮廓只削底边 N 像素（上沿与两侧都保持原样）
		var trim := maxf(1.0, float(kind.substr(5).to_int()))
		return Rect2(sil.position.x, sil.position.y, sil.size.x, maxf(4.0, sil.size.y - trim))
	return f


# ------------------------------------------------------------------ 构建

func _build(c: Dictionary) -> void:
	for ch in _world.get_children():
		_world.remove_child(ch)
		ch.free()

	## 地板：2D 光只照 CanvasItem，空背景不会被照亮
	var floor_poly := Polygon2D.new()
	floor_poly.polygon = _rect_poly(Rect2(0, 0, VIEW_W, VIEW_H))
	floor_poly.color = Color(0.86, 0.83, 0.76)
	_world.add_child(floor_poly)

	var lpos := Vector2(640.0, 360.0)
	if not c.get("bare", false):
		var geo := _geo(c["wall"])
		_add_25d_wall(geo, c["occ"])
		lpos = _light_pos(geo, c["light"])

	## 全局压暗 —— 「黑暗中的一盏灯」的标准做法
	var cm := CanvasModulate.new()
	cm.color = Color(0.05, 0.06, 0.10)
	_world.add_child(cm)

	var light := PointLight2D.new()
	light.texture = _shape_tex(c.get("shape", "circle"))
	light.texture_scale = LIGHT_SCALE
	light.color = Color(1.0, 0.86, 0.58)
	light.energy = ENERGY
	light.blend_mode = Light2D.BLEND_MODE_ADD
	light.shadow_enabled = true
	## 边缘不柔化，采样点才好判定（不同 Godot 版本属性名有差异，故做存在性判断）
	if "shadow_filter_smooth" in light:
		light.shadow_filter_smooth = 0.0
	light.position = lpos
	_world.add_child(light)


func _add_25d_wall(geo: Dictionary, occ_kind: String) -> void:
	var f: Rect2 = geo["foot"]
	var h: float = geo["h"]

	var body := Node2D.new()
	_world.add_child(body)

	## 顶面：屏幕上就是「足迹整体上移 h」
	var top := Polygon2D.new()
	top.polygon = _rect_poly(Rect2(f.position.x, f.position.y - h, f.size.x, f.size.y))
	top.color = Color(0.46, 0.43, 0.50)
	body.add_child(top)

	## 南立面：从足迹南沿向上立起 h
	var face := Polygon2D.new()
	face.polygon = _rect_poly(Rect2(f.position.x, f.position.y + f.size.y - h, f.size.x, h))
	face.color = Color(0.34, 0.32, 0.38)
	body.add_child(face)

	if occ_kind == "none":
		return

	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.closed = true
	poly.polygon = _rect_poly(_occ_rect(occ_kind, f, h))
	occ.occluder = poly
	body.add_child(occ)


func _shape_tex(kind: String) -> ImageTexture:
	if _tex_cache.has(kind):
		return _tex_cache[kind]
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half := float(n) * 0.5
	## 「floor」把纵向半径按 YSQUASH 压扁 → 屏幕上是个椭圆，投到地板上才是正圆
	var sq := YSQUASH if kind == "floor" else 1.0
	for y in n:
		for x in n:
			var dx := (float(x) + 0.5 - half) / half
			var dy := (float(y) + 0.5 - half) / half / sq
			var r := sqrt(dx * dx + dy * dy)
			var a := 0.0
			if r < 1.0:
				a = 1.0 - r          ## 线性衰减（与第一探针的 GradientTexture2D 等价）
			img.set_pixel(x, y, Color(1, 1, 1, a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[kind] = tex
	return tex


# ------------------------------------------------------------------ 采样

func _patch_lum(img: Image, p: Vector2, r: int = 4) -> float:
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


func _rect_lum(img: Image, r: Rect2) -> float:
	var acc := 0.0
	var n := 0
	var y := int(r.position.y)
	while y < int(r.position.y + r.size.y):
		var x := int(r.position.x)
		while x < int(r.position.x + r.size.x):
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				var c := img.get_pixel(x, y)
				acc += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
				n += 1
			x += 2
		y += 2
	return snappedf(acc / maxf(1.0, float(n)), 0.0001)


## 从墙体最下沿往上走，量「连着受光的高度」—— 用来验证「削多少 = 墙脚亮多高」
func _base_depth(img: Image, geo: Dictionary) -> float:
	var f: Rect2 = geo["foot"]
	var s: Rect2 = geo["sil"]
	var ybot := int(s.position.y + s.size.y) - 1
	var xs := [
		f.position.x + f.size.x * 0.3,
		f.position.x + f.size.x * 0.5,
		f.position.x + f.size.x * 0.7,
	]
	var total := 0.0
	for xf in xs:
		var x := int(xf)
		var y := ybot
		var d := 0.0
		while y > int(s.position.y) + 1:
			var c := img.get_pixel(x, y)
			if 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b <= BASE_THR:
				break
			d += 1.0
			y -= 1
		total += d
	return snappedf(total / float(xs.size()), 0.01)


## 从灯心往一个方向扫，返回最远的「仍然算亮」的距离（屏幕像素）
func _reach(img: Image, origin: Vector2, dir: Vector2, thr: float, max_d: float) -> float:
	var step := 2.0
	var d := 0.0
	var last := 0.0
	while d <= max_d:
		var p := origin + dir * d
		if p.x < 1.0 or p.y < 1.0 or p.x > float(img.get_width() - 2) or p.y > float(img.get_height() - 2):
			break
		var c := img.get_pixel(int(p.x), int(p.y))
		if 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b > thr:
			last = d
		d += step
	return snappedf(last, 0.1)


func _rect_arr(r: Rect2) -> Array:
	return [
		snappedf(r.position.x, 0.1), snappedf(r.position.y, 0.1),
		snappedf(r.size.x, 0.1), snappedf(r.size.y, 0.1),
	]


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
			x += 4
		y += 4
	return snappedf(acc / maxf(1.0, float(n)), 0.0001)


# ------------------------------------------------------------------ 用例

func _run_case(c: Dictionary) -> void:
	_build(c)
	for i in 8:
		await RenderingServer.frame_post_draw

	var img: Image = _sub.get_texture().get_image()
	var png_path := ProjectSettings.globalize_path(OUT_DIR + "/" + c["name"] + ".png")
	img.save_png(png_path)

	var entry := {
		"wall": c["wall"],
		"occ": c["occ"],
		"light": c["light"],
		"mean_lum": _mean_lum(img),
		"png": png_path,
	}

	if c.get("bare", false):
		var cen := Vector2(640.0, 360.0)
		## 同一个「地面距离」在两个方向上各取一点：
		##   横向 → 屏幕偏移 (D, 0)
		##   纵向 → 屏幕偏移 (0, -D*YSQUASH)  ← 屏幕 y 是竖压过的，所以纵向偏移只有 0.62×
		var d_floor := 300.0
		var lum_e := _patch_lum(img, cen + Vector2(d_floor, 0.0))
		var lum_n := _patch_lum(img, cen + Vector2(0.0, -d_floor * YSQUASH))
		entry["shape"] = c.get("shape", "circle")
		entry["floor_dist_probed"] = d_floor
		entry["lum_east_300"] = lum_e
		entry["lum_north_300"] = lum_n
		## 地面上等距的两点亮度之比：地面正圆 → ≈1；屏幕正圆 → 明显 >1（纵向照得更远）
		entry["ratio_north_over_east"] = snappedf(lum_n / maxf(0.0001, lum_e), 0.0001)
		entry["radius_ew_screen"] = _reach(img, cen, Vector2(1, 0), 0.10, 620.0)
	else:
		var geo := _geo(c["wall"])
		var patches := _patches(geo)
		var s := {}
		for k in patches:
			s[k] = _rect_lum(img, patches[k])
		entry["foot_screen"] = _rect_arr(geo["foot"])
		entry["sil_screen"] = _rect_arr(geo["sil"])
		entry["light_pos"] = [snappedf(_light_pos(geo, c["light"]).x, 0.1), snappedf(_light_pos(geo, c["light"]).y, 0.1)]
		entry["patches"] = s
		entry["base_depth"] = _base_depth(img, geo)

	_report["cases"][c["name"]] = entry


# ------------------------------------------------------------------ 判定

func _rat(a: float, b: float) -> float:
	return snappedf(a / maxf(0.0001, b), 0.0001)


func _judge() -> void:
	var cs: Dictionary = _report["cases"]
	var need := []
	for c in CASES:
		need.append(c["name"])
	for n in need:
		if not cs.has(n):
			_report["errors"].append("缺少用例 " + n)
			return

	var v := {}

	# ── 一、推荐摆法（贴轮廓 + 只削底边 16px）应当成立的性质 ──
	var s_b16: Dictionary = cs["S_fence_b16"]["patches"]
	var s_foot: Dictionary = cs["S_fence_foot"]["patches"]
	var w_b16: Dictionary = cs["W_fence_b16"]["patches"]
	var w_foot: Dictionary = cs["W_fence_foot"]["patches"]
	var w_sil: Dictionary = cs["W_fence_sil"]["patches"]
	var w_in16: Dictionary = cs["W_fence_in16"]["patches"]
	var n_b16: Dictionary = cs["N_fence_b16"]["patches"]
	var n_foot: Dictionary = cs["N_fence_foot"]["patches"]
	var e_b16: Dictionary = cs["E_fence_b16"]["patches"]
	var e_foot: Dictionary = cs["E_fence_foot"]["patches"]

	v["P1_正面光_墙后地面全黑"] = s_b16["behind"] < s_b16["front"] * 0.15
	v["P2_削底16_墙脚受光_不削则不受光"] = (
		cs["S_fence_b16"]["base_depth"] >= 12.0 and cs["S_fence_sil"]["base_depth"] <= 2.0
	)
	v["P3_侧光_墙后不漏光"] = w_b16["behind"] < w_foot["behind"] * 0.2
	v["P4_侧光_墙脚同样受光"] = cs["W_fence_b16"]["base_depth"] >= 10.0
	v["P5_背光_墙后不漏光"] = n_b16["front"] < n_b16["behind"] * 0.15
	v["P6_背光_墙面保持剪影"] = n_b16["topface"] < n_foot["topface"] * 0.2
	v["P7_四种墙型_侧光下墙面都保持剪影"] = (
		cs["W_fence_b16"]["patches"]["topface"] < 0.06
		and cs["W_pillar_b16"]["patches"]["topface"] < 0.06
		and cs["W_block_b16"]["patches"]["topface"] < 0.06
		and cs["W_tall_b16"]["patches"]["topface"] < 0.06
	)
	v["P8_正面光下细墙与厚块墙脚都受光"] = (
		cs["S_fence_b16"]["base_depth"] >= 12.0 and cs["S_block_b16"]["base_depth"] >= 12.0
	)
	v["P9_侧光下浅墙墙脚受光"] = (
		cs["W_fence_b16"]["base_depth"] >= 10.0
		and cs["W_pillar_b16"]["base_depth"] >= 10.0
		and cs["W_tall_b16"]["base_depth"] >= 10.0
	)
	v["P10_地面正圆灯_各向光距一致"] = absf(cs["shape_floor"]["ratio_north_over_east"] - 1.0) < 0.2
	v["P11_东西侧光对称"] = absf(e_b16["behind"] - w_b16["behind"]) < 0.01

	# ── 二、对照摆法的缺陷（✅ = 缺陷已确认存在，所以不能照抄） ──
	v["D1_脚印模型_侧光翻过墙顶照到墙后"] = w_foot["behind"] > w_b16["behind"] * 5.0
	v["D2_脚印模型_照亮墙身并用影子横切它"] = w_foot["topface"] > w_foot["band"] * 5.0
	v["D3_脚印模型_背光时墙面反被照亮"] = n_foot["topface"] > n_b16["topface"] * 5.0
	v["D4_均匀内缩_改为从墙顶漏光"] = w_in16["behind"] > w_b16["behind"] * 3.0
	v["D5_脚印模型_厚墙与厚块都会漏"] = (
		w_foot["behind"] > w_b16["behind"] * 5.0
		and cs["W_block_foot"]["patches"]["behind"] > cs["W_block_b16"]["patches"]["behind"] * 2.5
	)
	v["D6_屏幕正圆灯_纵向多照七成"] = cs["shape_circle"]["ratio_north_over_east"] > 1.4

	# ── 三、原始数字（留给文档引用） ──
	v["num_正面_墙前地面"] = s_b16["front"]
	v["num_正面_墙后地面_b16"] = s_b16["behind"]
	v["num_正面_墙后地面_foot"] = s_foot["behind"]
	v["num_侧光_墙前地面"] = w_b16["left"]
	v["num_侧光_墙后地面_foot"] = w_foot["behind"]
	v["num_侧光_墙后地面_sil"] = w_sil["behind"]
	v["num_侧光_墙后地面_b8"] = cs["W_fence_b8"]["patches"]["behind"]
	v["num_侧光_墙后地面_b16"] = w_b16["behind"]
	v["num_侧光_墙后地面_in16"] = w_in16["behind"]
	v["num_侧光_墙面顶面_foot"] = w_foot["topface"]
	v["num_侧光_墙面顶面_b16"] = w_b16["topface"]
	v["num_侧光_墙面暗带_foot"] = w_foot["band"]
	v["num_侧光_墙面暗带_b16"] = w_b16["band"]
	v["num_侧光_墙脚受光高度_sil"] = cs["W_fence_sil"]["base_depth"]
	v["num_侧光_墙脚受光高度_b8"] = cs["W_fence_b8"]["base_depth"]
	v["num_侧光_墙脚受光高度_b16"] = cs["W_fence_b16"]["base_depth"]
	v["num_正面_墙脚受光高度_b8"] = cs["S_fence_b8"]["base_depth"]
	v["num_正面_墙脚受光高度_b16"] = cs["S_fence_b16"]["base_depth"]
	v["num_正面_厚块墙脚受光高度_b16"] = cs["S_block_b16"]["base_depth"]
	v["num_侧光_厚块墙脚受光高度_b16"] = cs["W_block_b16"]["base_depth"]
	v["num_侧光_窄柱墙脚受光高度_b16"] = cs["W_pillar_b16"]["base_depth"]
	v["num_侧光_高墙墙脚受光高度_b16"] = cs["W_tall_b16"]["base_depth"]
	v["num_背光_墙面_foot"] = n_foot["topface"]
	v["num_背光_墙面_b16"] = n_b16["topface"]
	v["num_额外_削底带来的底座溢光_b16"] = w_b16["right"]
	v["num_额外_削底带来的底座溢光_b8"] = cs["W_fence_b8"]["patches"]["right"]
	v["num_额外_无削底时_墙侧"] = w_sil["right"]
	v["num_正圆灯_地面等距北东亮度比"] = cs["shape_circle"]["ratio_north_over_east"]
	v["num_地圆灯_地面等距北东亮度比"] = cs["shape_floor"]["ratio_north_over_east"]

	## 墙型几何（便于文档引用）
	var g := {}
	for wn in WALLS:
		var geo := _geo(wn)
		g[wn] = {
			"foot_screen": _rect_arr(geo["foot"]),
			"sil_screen": _rect_arr(geo["sil"]),
			"world": WALLS[wn],
		}
	_report["geometry"] = g
	_report["verdict"] = v


func _write_report() -> void:
	var path := ProjectSettings.globalize_path(OUT_DIR + "/report.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_report, "  "))
		f.close()
	print("LKRPT" + JSON.stringify(_report) + "ENDLKRPT")
	print("[probe25d] shots -> ", ProjectSettings.globalize_path(OUT_DIR))
