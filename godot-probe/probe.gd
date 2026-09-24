extends Node2D
## LightKnight 光照最小验证探针
##
## 回答两件事：
##   1) Godot 4 的 2D 点光会不会被墙体遮挡（阴影）？—— 同一场景只改 shadow_enabled 做对照
##   2) 光照是否可被运行时调节（对应「连击提高亮度」），以及哪种混合模式更像「灯火」
##
## 渲染走固定尺寸的 SubViewport（1280x720），因此窗口被窗口管理器改成什么尺寸都不影响结果。
## 输出：res://shots/*.png + report.json，并向 stdout 打印 LKRPT 段。

const OUT_DIR := "res://shots"
const VIEW_W := 1280
const VIEW_H := 720

## 不放 Camera2D，世界坐标 == 画布像素，采样点可直接照抄
const LIGHT_POS := Vector2(380, 360)
const WALL := Rect2(560, 60, 40, 600)   ## 竖直墙，立在灯的右前方

const SAMPLES := {
	"A_at_light": Vector2(380, 360),      ## 灯中心 —— 应最亮
	"B_lit_side": Vector2(480, 360),      ## 墙前、与灯同侧 —— 应受光
	"C_behind": Vector2(760, 360),        ## 墙后正对灯 —— ★ 判定点
	"D_corner": Vector2(1190, 660),       ## 远角 —— 应保持全暗
	"E_same_side_far": Vector2(380, 650), ## 同侧但更远 —— 距离衰减
	"F_on_wall": Vector2(578, 360),       ## 墙体中部 —— 看墙自身是否受光
	"G_wall_top": Vector2(578, 120),      ## 墙体上段
	"H_beyond_shadow": Vector2(1000, 360),## 阴影更远处
	## 横扫墙面（墙占 x 560..600，灯在左）—— 用来判断墙是不是被自己挡住
	"W1_face_562": Vector2(562, 360),
	"W2_in_566": Vector2(566, 360),
	"W3_mid_580": Vector2(580, 360),
	"W4_far_597": Vector2(597, 360),
}

## 用例：名字 -> {energy, shadow, blend, inset}
## inset：遮挡体相对墙体内缩的像素数（0 = 遮挡体与墙体完全重合）
const CASES := [
	{"name": "shadow_on_add", "energy": 1.2, "shadow": true, "blend": Light2D.BLEND_MODE_ADD, "inset": 0.0},
	{"name": "shadow_off_add", "energy": 1.2, "shadow": false, "blend": Light2D.BLEND_MODE_ADD, "inset": 0.0},
	{"name": "shadow_on_mix", "energy": 1.2, "shadow": true, "blend": Light2D.BLEND_MODE_MIX, "inset": 0.0},
	{"name": "energy_high", "energy": 2.6, "shadow": true, "blend": Light2D.BLEND_MODE_ADD, "inset": 0.0},
	{"name": "inset_10", "energy": 1.2, "shadow": true, "blend": Light2D.BLEND_MODE_ADD, "inset": 10.0},
	{"name": "inset_24", "energy": 1.2, "shadow": true, "blend": Light2D.BLEND_MODE_ADD, "inset": 24.0},
]

const BLEND_NAMES := {
	Light2D.BLEND_MODE_ADD: "ADD",
	Light2D.BLEND_MODE_SUB: "SUB",
	Light2D.BLEND_MODE_MIX: "MIX",
}

var _sub: SubViewport
var _world: Node2D
var _report := {
	"godot": "",
	"renderer": "",
	"viewport": [VIEW_W, VIEW_H],
	"cases": {},
	"errors": [],
}


func _ready() -> void:
	_report["godot"] = Engine.get_version_info()["string"]
	_report["renderer"] = RenderingServer.get_video_adapter_name()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# 固定尺寸离屏画布：与窗口实际大小解耦
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


func _run_case(c: Dictionary) -> void:
	_build(c["energy"], c["shadow"], c["blend"], c.get("inset", 0.0))

	for i in 8:
		await RenderingServer.frame_post_draw

	var img: Image = _sub.get_texture().get_image()
	var png_path := ProjectSettings.globalize_path(OUT_DIR + "/" + c["name"] + ".png")
	img.save_png(png_path)

	var samples := {}
	for k in SAMPLES:
		samples[k] = _patch_lum(img, SAMPLES[k])

	_report["cases"][c["name"]] = {
		"energy": c["energy"],
		"shadow_enabled": c["shadow"],
		"blend": BLEND_NAMES[c["blend"]],
		"occluder_inset": c.get("inset", 0.0),
		"samples": samples,
		"mean_lum": _mean_lum(img),
		"bright_pct": _bright_pct(img, 0.25),
		"png": png_path,
		"readback_size": [img.get_width(), img.get_height()],
	}


func _build(energy: float, shadow: bool, blend: int, inset: float = 0.0) -> void:
	for c in _world.get_children():
		_world.remove_child(c)
		c.free()

	# 地板：2D 光只照 CanvasItem，空背景不会被照亮
	var floor_poly := Polygon2D.new()
	floor_poly.name = "Floor"
	floor_poly.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(VIEW_W, 0),
		Vector2(VIEW_W, VIEW_H), Vector2(0, VIEW_H),
	])
	floor_poly.color = Color(0.86, 0.83, 0.76)
	_world.add_child(floor_poly)

	_add_wall(WALL, inset)
	_add_wall(Rect2(0, 0, VIEW_W, 24))
	_add_wall(Rect2(0, VIEW_H - 24, VIEW_W, 24))
	_add_wall(Rect2(0, 0, 24, VIEW_H))
	_add_wall(Rect2(VIEW_W - 24, 0, 24, VIEW_H))

	# 全局压暗 —— 「黑暗中的一盏灯」的标准做法
	var cm := CanvasModulate.new()
	cm.name = "Darkness"
	cm.color = Color(0.05, 0.06, 0.10)
	_world.add_child(cm)

	var light := PointLight2D.new()
	light.name = "Lamp"
	light.texture = _radial_texture()
	light.texture_scale = 2.2
	light.color = Color(1.0, 0.86, 0.58)
	light.energy = energy
	light.blend_mode = blend
	light.shadow_enabled = shadow            ## ← 唯一的对照变量
	light.position = LIGHT_POS
	_world.add_child(light)


func _add_wall(r: Rect2, inset: float = 0.0) -> void:
	var body := Node2D.new()
	body.position = r.position
	_world.add_child(body)

	var vis := Polygon2D.new()
	vis.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(r.size.x, 0),
		Vector2(r.size.x, r.size.y), Vector2(0, r.size.y),
	])
	vis.color = Color(0.42, 0.39, 0.46)
	body.add_child(vis)

	# 遮挡体默认与墙体完全重合 —— 此时墙会因为「射线到灯要穿过自己」而自遮挡。
	# inset 把遮挡体内缩，墙体表面便能正常受光，而影子照旧投出去。
	var o := Rect2(inset, inset, maxf(1.0, r.size.x - inset * 2.0), maxf(1.0, r.size.y - inset * 2.0))
	var occ := LightOccluder2D.new()
	var poly := OccluderPolygon2D.new()
	poly.closed = true
	poly.polygon = PackedVector2Array([
		Vector2(o.position.x, o.position.y),
		Vector2(o.position.x + o.size.x, o.position.y),
		Vector2(o.position.x + o.size.x, o.position.y + o.size.y),
		Vector2(o.position.x, o.position.y + o.size.y),
	])
	occ.occluder = poly
	body.add_child(occ)


func _radial_texture() -> GradientTexture2D:
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	grad.colors = PackedColorArray([
		Color(1, 1, 1, 1.0), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.0),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 512
	tex.height = 512
	return tex


# ---------------------------------------------------------------- 采样

func _patch_lum(img: Image, p: Vector2, r: int = 6) -> float:
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
			x += 4
		y += 4
	return snappedf(acc / maxf(1.0, float(n)), 0.0001)


func _bright_pct(img: Image, thr: float) -> float:
	var hit := 0
	var n := 0
	var y := 0
	while y < img.get_height():
		var x := 0
		while x < img.get_width():
			var c := img.get_pixel(x, y)
			if (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > thr:
				hit += 1
			n += 1
			x += 4
		y += 4
	return snappedf(100.0 * float(hit) / maxf(1.0, float(n)), 0.01)


# ---------------------------------------------------------------- 判定 / 输出

func _judge() -> void:
	var cs: Dictionary = _report["cases"]
	for need in ["shadow_on_add", "shadow_off_add", "shadow_on_mix", "energy_high", "inset_10", "inset_24"]:
		if not cs.has(need):
			_report["errors"].append("缺少用例 " + need)
			return

	var on: Dictionary = cs["shadow_on_add"]
	var off: Dictionary = cs["shadow_off_add"]
	var mix: Dictionary = cs["shadow_on_mix"]
	var hi: Dictionary = cs["energy_high"]
	var i10: Dictionary = cs["inset_10"]
	var i24: Dictionary = cs["inset_24"]

	var s_on: Dictionary = on["samples"]
	var s_off: Dictionary = off["samples"]
	var behind_on: float = s_on["C_behind"]
	var behind_off: float = s_off["C_behind"]

	# 墙体剖面：墙占 x 560..600，灯在左侧。深度 d = x - 560。
	# 模型：遮挡体近边在 560+inset 时，墙面上深度 d > inset 的点「到灯的射线会穿过自己的遮挡体」→ 处于阴影。
	# 所以受光深度应当正好等于 inset。
	var w_inset_10 := {
		"d2": i10["samples"]["W1_face_562"],
		"d6": i10["samples"]["W2_in_566"],
		"d20": i10["samples"]["W3_mid_580"],
		"d37": i10["samples"]["W4_far_597"],
	}
	var w_inset_24 := {
		"d2": i24["samples"]["W1_face_562"],
		"d6": i24["samples"]["W2_in_566"],
		"d20": i24["samples"]["W3_mid_580"],
		"d37": i24["samples"]["W4_far_597"],
	}
	var unlit_wall: float = s_on["W4_far_597"]   # 深处必然全暗，作为「未受光」基准
	var lit_min: float = unlit_wall + 0.08       # 明显高于基准才算受光

	_report["verdict"] = {
		# ── 核心结论：光被墙挡住 ──
		"occlusion_works": behind_on < behind_off * 0.5,
		"behind_on": behind_on,
		"behind_off": behind_off,
		"behind_drop_pct": snappedf(100.0 * (behind_off - behind_on) / maxf(0.0001, behind_off), 0.01),
		# 阴影外侧仍暗 → 说明是墙挡的，不是光斑变小
		"far_corner_dark": s_on["D_corner"] < behind_off * 0.5,
		# 提高亮度后墙后依然是黑的 → 阴影在高亮度下依旧成立
		"shadow_holds_at_high_energy": hi["samples"]["C_behind"] < behind_off * 0.5,
		# 距离衰减
		"falloff_works": s_on["A_at_light"] > s_on["D_corner"] * 3.0,
		# 亮度运行时可调（对应「连击提高亮度」）
		"energy_modulates": hi["mean_lum"] > on["mean_lum"] * 1.15,

		# ── 墙的自遮挡：机制与修法 ──
		# 遮挡体与墙体重合时，墙表面（除最外一层）全在阴影里
		"wall_self_shadowed": s_on["F_on_wall"] < s_off["F_on_wall"] * 0.3,
		"wall_on": s_on["F_on_wall"],
		"wall_off": s_off["F_on_wall"],
		# 遮挡体内缩 i 后，受光深度应当 ≈ i：i=10 时只有 d2/d6 受光，d20 仍暗
		"inset10_lights_d2_d6_only":
			w_inset_10["d2"] > lit_min and w_inset_10["d6"] > lit_min
			and w_inset_10["d20"] < lit_min,
		# i=24 时 d20 应转为受光，而 d37 仍暗
		"inset24_lights_d20_not_d37":
			w_inset_24["d20"] > lit_min and w_inset_24["d37"] < lit_min,
		# 内缩遮挡体不会漏光：墙后依旧全黑
		"inset_keeps_behind_dark":
			i10["samples"]["C_behind"] < behind_off * 0.5
			and i24["samples"]["C_behind"] < behind_off * 0.5,
		"wall_profile_inset_10": w_inset_10,
		"wall_profile_inset_24": w_inset_24,
		"unlit_wall_baseline": unlit_wall,

		# ── 混合模式对比 ──
		"mix_mean_lum": mix["mean_lum"],
		"add_mean_lum": on["mean_lum"],
	}


func _write_report() -> void:
	var path := ProjectSettings.globalize_path(OUT_DIR + "/report.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_report, "  "))
		f.close()
	print("LKRPT" + JSON.stringify(_report) + "ENDLKRPT")
	print("[probe] shots -> ", ProjectSettings.globalize_path(OUT_DIR))
