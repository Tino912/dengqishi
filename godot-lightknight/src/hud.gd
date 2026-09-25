class_name Hud
extends CanvasLayer
## Hud —— 界面层。放在 CanvasLayer 里，因此**不受世界那层的 CanvasModulate 压暗**，
## 这一点很重要：Web 版里 HUD 是 DOM，天然不受画布光照影响，这里靠 CanvasLayer 达成同样效果。
##
## 字体：Godot 内置字体没有 CJK，中文会变空白/豆腐块，
## 所以运行时加载：正文用思源黑体（系统里的 noto-cjk），标题/卡牌/大数字用
## 随工程的霞鹜文楷（见 Art.ensure_font）。
##
## 这一版的画法分两层：
##   · 装饰（面板、条、环、徽记、插画）全部自己 _draw —— 因为 StyleBoxFlat 只有
##     纯色底，画不出渐变、辉光、扇形冷却这些；
##   · 文字仍然用 Label —— 中文换行/对齐交给引擎，比手写 draw_string 可靠得多。
##
## 另外有一层 post（暗角）：世界的像素采样类断言要能把它单独关掉，
## 否则"墙后到底暗不暗"会被 HUD 的暗角干扰 —— 见 set_post_enabled()。

# ---------------------------------------------------------------- 调色

const C_GOLD := Color("#f2c46a")
const C_GOLD_HI := Color("#ffe7b0")
const C_EMBER := Color("#ff9a4d")
const C_HP_A := Color("#ff5d57")
const C_HP_B := Color("#ffc46b")
const C_LIGHT_A := Color("#ffb64d")
const C_LIGHT_B := Color("#fff0c4")
const C_INK := Color("#eae5d8")
const C_MUTE := Color("#9b9587")
const C_DIM := Color("#6d6a63")
const C_PANEL_A := Color("#1a1f2c")
const C_PANEL_B := Color("#0a0d15")
const C_LINE := Color("#6a5a34")
const C_OK := Color("#8fe0b0")

var root: Control
## 后处理层（暗角）。**可以单独关掉**，见 set_post_enabled()
var post: Control
var hud_box: Control

var hp_bar: RBar
var hp_text: Label
var light_bar: RBar
var stats_label: Label
var combo_num: Label
var combo_tag: Label
var objective_label: Label
var prompt_label: Label
var weapon_label: Label
var boon_flow: HFlowContainer
var boss_box: Control
var boss_bar: RBar
var boss_name: Label
var toast_box: VBoxContainer
var dlg_panel: PanelContainer
var dlg_speaker: Label
var dlg_text: Label
var dlg_hint: Label
var flash_rect: ColorRect
var overlay: Control
var ov_art: OvArt
var ov_card: PanelContainer
var ov_title: Label
var ov_body: Label
var ov_hint: Label
var vignette: TextureRect
var skill_chips: Array = []
var draft_layer: Control
var draft_title: Label
var draft_sub: Label
var draft_cards: Array = []
var draft_hint: Label
var draft_arm: ArmBar

var _toasts := []
## 面板装填进度（三选一）：HUD 自己计时，好让"还不能确认"这件事看得见
var _arm_t := 0.0
var _arm_done := false
var _t := 0.0
## 连击数字的跳动
var _combo_pop := 0.0
var _combo_last := 0
## 恩赐徽章的签名（变了才重建）
var _boon_sig := ""
## 画面板底纹用的噪点贴图（一次生成，反复平铺）
var _noise: ImageTexture = null


func _ready() -> void:
	layer = 10
	Art.ensure_assets()
	_noise = _make_noise(96)
	_build()
	hide_overlay()
	show_dialogue(false)


# ---------------------------------------------------------------- 构建

func _mk_label(parent: Node, size: int, color := C_INK, disp := false, outline := 5) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", Art.font_disp if disp else Art.font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	# 真正的描边比 1px 阴影干净得多，暗背景上的小字尤其明显
	if outline > 0:
		l.add_theme_constant_override("outline_size", outline)
		l.add_theme_color_override("font_outline_color", Color(0.02, 0.025, 0.04, 0.9))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## 面板底：自上而下的暗色渐变 + 一圈描边 + 柔投影。
## 内边距挂在 StyleBox 上（PanelContainer 自己没有 content_margin_*，
## 那是 MarginContainer 的属性 —— 写在 PanelContainer 上会直接报错）。
func _panel_sb(alpha := 0.94, border := C_LINE, bw := 1, r := 7,
		pad := Vector4(16, 12, 16, 12)) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(C_PANEL_A.r, C_PANEL_A.g, C_PANEL_A.b, alpha)
	sb.border_color = Color(border.r, border.g, border.b, 0.85)
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(r)
	sb.shadow_color = Color(0, 0, 0, 0.45)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 3)
	sb.content_margin_left = pad.x
	sb.content_margin_right = pad.y
	sb.content_margin_top = pad.z
	sb.content_margin_bottom = pad.w
	return sb


func _mk_panel(parent: Node, minsize := Vector2.ZERO, pad := Vector4(16, 12, 16, 12)) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _panel_sb(0.94, C_LINE, 1, 7, pad))
	if minsize != Vector2.ZERO:
		p.custom_minimum_size = minsize
	parent.add_child(p)
	return p


func _build() -> void:
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_post()
	_build_status()
	_build_skills()
	_build_combo()
	_build_objective()
	_build_boss()
	_build_prompt()
	_build_toasts()
	_build_dialogue()
	_build_flash()
	_build_overlay()
	_build_draft()


## 后处理：暗角。用一张径向贴图，中心通透、四周压暗 ——
## 旧版是一整块纯色 ColorRect 均匀压暗，连画面正中都糊了 20%，很闷。
func _build_post() -> void:
	post = Control.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(post)
	vignette = TextureRect.new()
	vignette.texture = _make_vignette(256, 144)
	vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vignette.stretch_mode = TextureRect.STRETCH_SCALE
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post.add_child(vignette)


func _build_status() -> void:
	hud_box = Control.new()
	hud_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(hud_box)

	var panel := _mk_panel(hud_box, Vector2(322, 0))
	panel.position = Vector2(18, 16)
	# 面板左上角挂一盏小灯，和 HUD 的"灯笼"气质对上。
	# 注意必须挂在 hud_box 上而不是 panel 里 —— PanelContainer 会把每个子节点
	# 都拉满它的内容区，挂进去就不是"角上一盏灯"而是一整块了。
	var lamp := PanelLamp.new()
	lamp.position = Vector2(11, 9)
	lamp.size = Vector2(18, 18)
	lamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_box.add_child(lamp)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	panel.add_child(v)

	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 9)
	v.add_child(hp_row)
	var hp_cap := _mk_label(hp_row, 15, C_GOLD, true)
	hp_cap.text = "灯焰"
	hp_cap.custom_minimum_size = Vector2(38, 0)
	hp_bar = _bar(hp_row, C_HP_A, C_HP_B, 208.0, 13.0)
	hp_text = _mk_label(hp_row, 13, C_INK)
	hp_text.custom_minimum_size = Vector2(64, 0)

	var lt_row := HBoxContainer.new()
	lt_row.add_theme_constant_override("separation", 9)
	v.add_child(lt_row)
	var lt_cap := _mk_label(lt_row, 15, C_GOLD, true)
	lt_cap.text = "灯火"
	lt_cap.custom_minimum_size = Vector2(38, 0)
	light_bar = _bar(lt_row, C_LIGHT_A, C_LIGHT_B, 208.0, 9.0)
	var lt_pad := Control.new()
	lt_pad.custom_minimum_size = Vector2(64, 0)
	lt_row.add_child(lt_pad)

	stats_label = _mk_label(v, 14, Color(0.86, 0.82, 0.72))
	weapon_label = _mk_label(v, 15, C_GOLD_HI, true)
	boon_flow = HFlowContainer.new()
	boon_flow.add_theme_constant_override("h_separation", 5)
	boon_flow.add_theme_constant_override("v_separation", 5)
	boon_flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boon_flow.custom_minimum_size = Vector2(294, 0)
	v.add_child(boon_flow)


func _build_skills() -> void:
	for i in 3:
		var chip := SkillChip.new()
		chip.custom_minimum_size = Vector2(274, 44)
		chip.position = Vector2(18, Proj.VIEW_H - 160.0 + float(i) * 48.0)
		hud_box.add_child(chip)
		chip.setup(i)
		skill_chips.append(chip)


func _build_combo() -> void:
	combo_num = _mk_label(hud_box, 54, C_GOLD_HI, true, 8)
	combo_num.position = Vector2(Proj.VIEW_W * 0.5 - 160.0, 8.0)
	combo_num.custom_minimum_size = Vector2(320, 0)
	combo_num.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	combo_tag = _mk_label(hud_box, 15, C_GOLD, true, 4)
	combo_tag.position = Vector2(Proj.VIEW_W * 0.5 - 160.0, 68.0)
	combo_tag.custom_minimum_size = Vector2(320, 0)
	combo_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_objective() -> void:
	objective_label = _mk_label(hud_box, 15, Color(0.80, 0.86, 1.0), false, 4)
	objective_label.position = Vector2(Proj.VIEW_W - 430.0, 22.0)
	objective_label.custom_minimum_size = Vector2(410, 0)
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _build_boss() -> void:
	boss_box = Control.new()
	boss_box.position = Vector2(Proj.VIEW_W * 0.5 - 270.0, 96.0)
	boss_box.custom_minimum_size = Vector2(540, 46)
	boss_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_box.add_child(boss_box)
	boss_name = _mk_label(boss_box, 18, Color(1.0, 0.76, 0.60), true)
	boss_name.text = ""
	boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_name.custom_minimum_size = Vector2(540, 0)
	boss_bar = RBar.new()
	boss_bar.position = Vector2(0, 26)
	boss_bar.custom_minimum_size = Vector2(540, 13)
	boss_bar.col_a = Color("#b3241c")
	boss_bar.col_b = Color("#ff8a4d")
	boss_bar.radius = 6.0
	boss_bar.ticks = 4
	boss_box.add_child(boss_bar)
	# 默认藏起来：Control 默认是 visible，不写这一行的话"还没打 Boss 就先有条红条"
	# （refresh 里虽然会再设一次，但第一帧截图（start_level 后立刻拍）会拍到这个默认态）
	boss_box.visible = false


func _build_prompt() -> void:
	prompt_label = _mk_label(hud_box, 17, C_GOLD_HI, true, 6)
	prompt_label.position = Vector2(Proj.VIEW_W * 0.5 - 320.0, Proj.VIEW_H - 84.0)
	prompt_label.custom_minimum_size = Vector2(640, 0)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _build_toasts() -> void:
	toast_box = VBoxContainer.new()
	toast_box.position = Vector2(Proj.VIEW_W * 0.5 - 300.0, Proj.VIEW_H - 240.0)
	toast_box.custom_minimum_size = Vector2(600, 0)
	toast_box.alignment = BoxContainer.ALIGNMENT_END
	toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_box.add_child(toast_box)


func _build_dialogue() -> void:
	dlg_panel = _mk_panel(root, Vector2(820, 148))
	dlg_panel.position = Vector2(Proj.VIEW_W * 0.5 - 410.0, Proj.VIEW_H - 186.0)
	# 上沿一道金线：像灯笼的提梁
	var sb := dlg_panel.get_theme_stylebox("panel") as StyleBoxFlat
	if sb != null:
		sb.border_width_top = 2
		sb.border_color = Color(0.72, 0.60, 0.34, 0.9)
	var dv := VBoxContainer.new()
	dv.add_theme_constant_override("separation", 8)
	dlg_panel.add_child(dv)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	dv.add_child(head)
	dlg_speaker = _mk_label(head, 19, C_GOLD_HI, true)
	dlg_hint = _mk_label(head, 14, Color(0.72, 0.68, 0.60))
	dlg_hint.text = "空格 继续"
	dlg_text = _mk_label(dv, 20, Color(0.95, 0.93, 0.87))
	dlg_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	dlg_text.custom_minimum_size = Vector2(786, 0)


func _build_flash() -> void:
	flash_rect = ColorRect.new()
	flash_rect.color = Color(0, 0, 0, 0)
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)


func _build_overlay() -> void:
	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(overlay)

	# 顺序要紧：暗色蒙版在**下**，插画在**上** —— 反过来的话提灯会被蒙版压暗
	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.02, 0.035, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(dim)

	ov_art = OvArt.new()
	ov_art.set_anchors_preset(Control.PRESET_FULL_RECT)
	ov_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(ov_art)

	ov_card = _mk_panel(overlay)
	ov_card.position = Vector2(Proj.VIEW_W * 0.5 - 460.0, 108.0)
	ov_card.custom_minimum_size = Vector2(920, 0)
	ov_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ov := VBoxContainer.new()
	ov.add_theme_constant_override("separation", 20)
	ov_card.add_child(ov)
	ov_title = _mk_label(ov, 58, C_GOLD_HI, true, 9)
	ov_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ov_title.custom_minimum_size = Vector2(880, 0)
	ov_body = _mk_label(ov, 20, Color(0.90, 0.89, 0.85), false, 5)
	ov_body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ov_body.custom_minimum_size = Vector2(880, 0)
	ov_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ov_hint = _mk_label(ov, 19, C_GOLD, true, 5)
	ov_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ov_hint.custom_minimum_size = Vector2(880, 0)


func _build_draft() -> void:
	# 单独一层，放在 overlay 之后 → 层级更高，暂停/通关的遮罩不会盖住它。
	draft_layer = Control.new()
	draft_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	draft_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(draft_layer)
	var ddim := ColorRect.new()
	ddim.color = Color(0.01, 0.015, 0.03, 0.84)
	ddim.set_anchors_preset(Control.PRESET_FULL_RECT)
	ddim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	draft_layer.add_child(ddim)

	draft_title = _mk_label(draft_layer, 40, C_GOLD_HI, true, 8)
	draft_title.position = Vector2(Proj.VIEW_W * 0.5 - 430.0, 110.0)
	draft_title.custom_minimum_size = Vector2(860, 0)
	draft_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draft_sub = _mk_label(draft_layer, 17, Color(0.80, 0.76, 0.68), false, 4)
	draft_sub.position = Vector2(Proj.VIEW_W * 0.5 - 430.0, 158.0)
	draft_sub.custom_minimum_size = Vector2(860, 0)
	draft_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draft_sub.text = "Q / E 左右看，空格拿走。看清楚了再按。"

	for i in 3:
		var card := DraftCard.new()
		card.slot = i
		card.base_pos = Vector2(Proj.VIEW_W * 0.5 - 462.0 + float(i) * 314.0, 206.0)
		card.position = card.base_pos
		card.custom_minimum_size = Vector2(292, 250)
		draft_layer.add_child(card)
		draft_cards.append(card)

	draft_arm = ArmBar.new()
	draft_arm.position = Vector2(Proj.VIEW_W * 0.5 - 462.0, 462.0)
	draft_arm.custom_minimum_size = Vector2(924, 4)
	draft_layer.add_child(draft_arm)

	draft_hint = _mk_label(draft_layer, 18, C_GOLD, true, 5)
	draft_hint.position = Vector2(Proj.VIEW_W * 0.5 - 430.0, 476.0)
	draft_hint.custom_minimum_size = Vector2(860, 0)
	draft_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	draft_hint.text = "Q ◀　　▶ E　移动高亮　·　空格 / 回车 拿走　·　Esc 放弃这次"

	draft_layer.visible = false


func _bar(parent: Node, ca: Color, cb: Color, w: float, h: float) -> RBar:
	var b := RBar.new()
	b.col_a = ca
	b.col_b = cb
	b.custom_minimum_size = Vector2(w, h)
	b.radius = maxf(3.0, h * 0.42)
	parent.add_child(b)
	return b


# ---------------------------------------------------------------- 生成贴图

## 暗角：中心通透、四周压暗。o 形是椭圆（按屏幕比例生成），拉伸后正好贴满。
func _make_vignette(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	for y in h:
		for x in w:
			var dx := (float(x) - cx) / cx
			var dy := (float(y) - cy) / cy
			var r := sqrt(dx * dx + dy * dy) * 0.5
			var t := clampf((r - 0.26) / 0.62, 0.0, 1.0)
			img.set_pixel(x, y, Color(0.0, 0.008, 0.024, t * t * (3.0 - 2.0 * t)))
	return ImageTexture.create_from_image(img)


## 面板底纹用的噪点（可平铺）
func _make_noise(n: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260924
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var v := rng.randf()
			img.set_pixel(x, y, Color(1.0, 0.96, 0.88, v * 0.035))
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- 每帧刷新

func refresh(world: World) -> void:
	if world == null or world.player == null:
		return
	var p := world.player
	var hp01 := clampf(p.hp / maxf(1.0, p.max_hp), 0.0, 1.0)
	hp_bar.set01(hp01)
	hp_bar.alert = hp01 < 0.3
	hp_text.text = "%d / %d" % [int(ceil(maxf(0.0, p.hp))), int(p.max_hp)]

	light_bar.set01(clampf(world.brightness01() * 1.15, 0.0, 1.0))

	stats_label.text = "灯火 %d　灯芯 %d　击杀 %d　死亡 %d" % [
		int(world.prog["coins"]), int(world.prog["wicks"]),
		int(world.prog["kills"]), int(world.prog["deaths"])]

	var c := p.combo_int()
	if c > 0:
		combo_num.text = str(c)
		combo_tag.text = "连 击"
		if c != _combo_last:
			_combo_pop = 1.0
			_combo_last = c
			combo_num.add_theme_font_size_override("font_size",
				54 + int(clampf(float(c) / 40.0, 0.0, 1.0) * 12.0))
		var k := clampf(p.combo / 40.0, 0.0, 1.0)
		combo_num.add_theme_color_override("font_color", C_GOLD_HI.lerp(C_EMBER, k))
	else:
		combo_num.text = ""
		combo_tag.text = ""
		_combo_last = 0

	objective_label.text = "目标　" + world.objective
	prompt_label.text = world.prompt

	var wdef: Dictionary = p.weapon()
	weapon_label.text = "武器　%s" % str(wdef["name"])
	var sl: Array = p.skills()
	for i in skill_chips.size():
		var chip: SkillChip = skill_chips[i]
		if i >= sl.size():
			chip.visible = false
			continue
		chip.visible = true
		var s: Dictionary = sl[i]
		chip.set_data(i, str(s["name"]), world.skill_cost(int(s["cost"])), p.combo,
			float(p.skill_cd.get(str(s["id"]), 0.0)),
			float(s.get("cd", 1.0)))

	_refresh_boons(world)

	if world.boss_enemy != null and not world.boss_enemy.dead and world.boss_spawned:
		boss_box.visible = true
		boss_name.text = str(world.level["boss"]["label"])
		boss_bar.set01(world.boss_enemy.hp01())
	else:
		boss_box.visible = false

	# flash_power 衰减到 0 后必须把颜色写回透明：HUD 是常驻节点，
	# 而 flash_power 属于 World 实例，换关卡 / 重生后新世界从 0 开始，
	# 若这里只在 >0 时写，上一关死亡时的红闪会一直留在新关卡画面上。
	if world.flash_power > 0.0:
		var fc := world.flash_color
		flash_rect.color = Color(fc.r, fc.g, fc.b, minf(0.42, world.flash_power))
	else:
		flash_rect.color = Color(0, 0, 0, 0)

	# 暗角随亮度收放：越亮越"开"，越黑越"收"
	var vig := clampf(0.72 - world.brightness01() * 0.42, 0.16, 0.9)
	vignette.modulate = Color(1, 1, 1, vig)
	# 低血脉动：不用额外的全屏色块，直接让暗角随心跳呼吸
	if p.hp < p.max_hp * 0.3 and not p.dead:
		vignette.modulate = Color(1.0, 0.72, 0.72,
			vig * (0.86 + 0.14 * sin(_t * 6.2)))

	Sound.set_intensity(world.brightness01())


## 恩赐徽章：refresh 每个固定步都会跑，不能每步都 free + new 一遍，
## 所以先比签名，真变了才重建。
func _refresh_boons(world: World) -> void:
	var bl := world.boon_list()
	var sig := ""
	for b in bl:
		sig += "%s×%d|" % [str(b["id"]), int(b["count"])]
	if sig == _boon_sig:
		return
	_boon_sig = sig
	for ch in boon_flow.get_children():
		boon_flow.remove_child(ch)
		ch.queue_free()
	if bl.is_empty():
		var none := _mk_label(boon_flow, 13, C_DIM, false, 3)
		none.text = "恩赐　——"
		return
	var tag := _mk_label(boon_flow, 13, Color(0.72, 0.68, 0.60), false, 3)
	tag.text = "恩赐"
	for b in bl:
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _chip_sb())
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var l := _mk_label(chip, 13, C_OK, false, 3)
		l.text = "%s×%d" % [str(b["name"]), int(b["count"])]
		boon_flow.add_child(chip)


func _chip_sb() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.20, 0.16, 0.9)
	sb.border_color = Color(0.42, 0.72, 0.56, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 1.0
	sb.content_margin_bottom = 1.0
	return sb


func set_flash(color: Color, power: float) -> void:
	flash_rect.color = Color(color.r, color.g, color.b, minf(0.42, power))


## 像素采样类断言要测的是**世界的光**，不能让 HUD 的暗角掺进去。
## 关掉之后，采样点上的加减光只来自世界层 —— 断言的含义才干净。
func set_post_enabled(on: bool) -> void:
	if post != null:
		post.visible = on


# ---------------------------------------------------------------- 对白 / 提示 / 覆盖层

func show_dialogue(on: bool) -> void:
	dlg_panel.visible = on
	if not on:
		dlg_speaker.text = ""
		dlg_text.text = ""


func set_dialogue(speaker: String, text: String, hint := "▸ 空格 / 点击继续") -> void:
	dlg_speaker.text = speaker
	dlg_text.text = text
	dlg_hint.text = hint.trim_prefix("▸ ").strip_edges()


func toast(text: String) -> void:
	var l := _mk_label(toast_box, 17, Color(1.0, 0.95, 0.84), false, 5)
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toasts.append({"node": l, "life": 3.2, "max": 3.2})
	if _toasts.size() > 4:
		var old = _toasts.pop_front()
		old["node"].queue_free()


func show_overlay(title: String, body: String, hint: String, mode := "title") -> void:
	ov_title.text = title
	ov_body.text = body
	ov_hint.text = hint
	ov_art.mode = mode
	ov_art.visible = mode != "pause"
	overlay.visible = true
	hud_box.visible = false
	toast_box.visible = false


func update_overlay_body(body: String) -> void:
	ov_body.text = body


func hide_overlay() -> void:
	overlay.visible = false
	hud_box.visible = true
	toast_box.visible = true


func set_hud_visible(on: bool) -> void:
	hud_box.visible = on


# ---------------------------------------------------------------- tick

func tick(dt: float) -> void:
	_t += dt
	# 提示消息：淡出 + 上浮
	var keep := []
	for t in _toasts:
		t["life"] = float(t["life"]) - dt
		var node: Label = t["node"]
		if float(t["life"]) <= 0.0:
			node.queue_free()
			continue
		var life := float(t["life"])
		var a := clampf(life / 0.8, 0.0, 1.0)
		# 只做淡出：位置由 VBoxContainer 管，手动改 position 会被下一次布局覆盖
		node.modulate = Color(1, 1, 1, a)
		keep.append(t)
	_toasts = keep

	_combo_pop = maxf(0.0, _combo_pop - dt * 3.6)
	combo_num.scale = Vector2.ONE * (1.0 + _combo_pop * 0.14)
	combo_num.pivot_offset = Vector2(160.0, 40.0)

	hp_bar.tick(dt)
	light_bar.tick(dt)
	boss_bar.tick(dt)
	# 三选一：装填进度看得见
	if draft_layer.visible:
		_arm_t = minf(Main.DRAFT_ARM, _arm_t + dt)
		_arm_done = _arm_t >= Main.DRAFT_ARM
		draft_arm.set01(_arm_t / maxf(0.001, Main.DRAFT_ARM))
		draft_arm.ready_now = _arm_done
		draft_hint.add_theme_color_override("font_color", Hud.C_GOLD_HI if _arm_done else C_DIM)
		for card in draft_cards:
			card.armed = _arm_done
			card.tick(dt)
	for chip in skill_chips:
		chip.tick(dt)
	if overlay.visible:
		ov_art.tick(dt)


# ---------------------------------------------------------------- 三选一（肉鸽）

## 卡片配色：换武器给冷金（"换一把家伙"），恩赐给暖金（"添一点火"）
const CARD_WEAPON := Color("#8fd0ff")
const CARD_BOON := Color("#ffd27a")

## 每把武器/每种恩赐配一枚徽记（用下载来的粒子素材当"图形"，
## 比画一排方块好看，而且一眼能区分）
const EMBLEMS := {
	"blade": "slash_03", "twin": "slash_01", "spear": "trace_04", "chain": "spark_04",
	"hammer": "circle_03", "scythe": "slash_02", "crossbow": "muzzle_01", "staff": "magic_05",
	## 键必须与 content.gd 里 BOONS 的 id 逐一对齐，
	## 否则 roll_draft 产出的卡片会回退到默认 star_06，徽记就失去区分作用。
	"hp": "star_06", "dmg": "spark_01", "haste": "trace_01", "light": "light_02",
	"reach": "trace_04", "vamp": "smoke_05", "combo_up": "light_03",
	"combo_add": "fire_01", "dash": "trace_04", "skill_cd": "magic_03",
	"cost_cut": "magic_01", "crit": "star_09", "bounty": "star_03", "killboom": "fire_01",
}


func show_draft(items: Array, index: int, armed := true) -> void:
	var was_visible := draft_layer.visible
	draft_layer.visible = true
	if not was_visible:
		_arm_t = 0.0
		_arm_done = false
	draft_title.text = "清空了一片影子"
	draft_arm.set01(_arm_t / maxf(0.001, Main.DRAFT_ARM))
	draft_arm.ready_now = _arm_done
	for i in draft_cards.size():
		var card: DraftCard = draft_cards[i]
		if i >= items.size():
			card.visible = false
			continue
		card.visible = true
		card.set_item(items[i], i, i == index)


func hide_draft() -> void:
	draft_layer.visible = false
	_arm_t = 0.0
	_arm_done = false


# ================================================================ 自绘控件

## 圆角条。三段：底槽 / 残影（掉血时留在后面慢慢追上）/ 渐变实体。
class RBar extends Control:
	var value := 1.0
	var shown := 1.0
	var lag := 1.0
	var col_a := Color("#ff5d57")
	var col_b := Color("#ffc46b")
	var radius := 5.0
	var ticks := 0
	var gloss := true
	var alert := false
	var _t := 0.0
	var _sb := StyleBoxFlat.new()
	var _bd := StyleBoxFlat.new()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bd.bg_color = Color(0, 0, 0, 0)
		_bd.border_color = Color(0, 0, 0, 0.55)
		_bd.set_border_width_all(1)
		_bd.set_corner_radius_all(int(radius))
		queue_redraw()

	func set01(v: float) -> void:
		value = clampf(v, 0.0, 1.0)

	func tick(dt: float) -> void:
		_t += dt
		shown = value if value > shown else maxf(value, shown - dt * 1.6)
		lag = value if value >= lag else maxf(value, lag - dt * 0.32)
		if absf(lag - value) < 0.001:
			lag = value
		if radius != float(int(_bd.corner_radius_top_left)):
			_bd.set_corner_radius_all(int(radius))
		queue_redraw()

	func _draw() -> void:
		if size.x <= 3.0 or size.y <= 3.0:
			return
		var rect := Rect2(Vector2.ZERO, size)
		var r := maxf(2.0, radius)
		# 底槽
		_sb.bg_color = Color(0.055, 0.065, 0.09, 0.95)
		_sb.set_corner_radius_all(int(r))
		draw_style_box(_sb, rect)
		var inner := Rect2(1.0, 1.0, maxf(0.0, size.x - 2.0), maxf(0.0, size.y - 2.0))
		var midy := inner.position.y + inner.size.y * 0.5
		var capr := maxf(1.0, inner.size.y * 0.5)
		# 残影（刚掉掉的那一段，暖白，慢慢缩回去）
		if lag > shown + 0.004:
			var lw := inner.size.x * lag
			draw_rect(Rect2(inner.position.x, inner.position.y, lw, inner.size.y),
				Color(1.0, 0.86, 0.72, 0.30))
		# 实体：中间用竖切片堆出渐变，两端用圆补成圆角
		var fw := inner.size.x * shown
		if fw > 0.5:
			draw_circle(Vector2(inner.position.x + capr, midy), capr, col_a)
			draw_circle(Vector2(inner.position.x + maxf(capr, fw - capr), midy), capr,
				col_a.lerp(col_b, clampf((fw - capr) / maxf(1.0, inner.size.x), 0.0, 1.0)))
			var x0 := inner.position.x + capr
			var x1 := inner.position.x + fw - capr
			var n := int(maxf(0.0, x1 - x0))
			for i in n:
				var t := float(i) / maxf(1.0, inner.size.x)
				draw_rect(Rect2(x0 + float(i), inner.position.y, 1.0, inner.size.y),
					col_a.lerp(col_b, clampf(t, 0.0, 1.0)))
			# 高光：上半部一道白，条才有体积
			if gloss and inner.size.y >= 7.0:
				draw_rect(Rect2(inner.position.x + 2.0, inner.position.y + 1.0,
					maxf(0.0, fw - 4.0), inner.size.y * 0.34),
					Color(1.0, 1.0, 1.0, 0.14))
		# 刻度
		if ticks > 1:
			for i in range(1, ticks):
				var tx := inner.position.x + inner.size.x * float(i) / float(ticks)
				draw_rect(Rect2(tx, inner.position.y, 1.0, inner.size.y), Color(0, 0, 0, 0.5))
		# 低血：整条呼吸
		if alert:
			draw_style_box(_bd, rect)
			draw_rect(inner, Color(1.0, 0.25, 0.2, 0.10 + 0.10 * sin(_t * 7.0)))
		else:
			draw_style_box(_bd, rect)


## 技能卡：热键牌 + 名字 + 连击点 + 冷却条，一眼看出"能不能按"
class SkillChip extends Control:
	var idx := 0
	var sname := ""
	var cost := 0
	var combo := 0.0
	var cd := 0.0
	var cd_max := 1.0
	var _t := 0.0
	## 注意不能叫 _ready —— 会和节点的 `_ready()` 回调重名（GDScript 直接报解析错）
	var _is_ready := false
	var _sb := StyleBoxFlat.new()
	var _bd := StyleBoxFlat.new()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bd.bg_color = Color(0, 0, 0, 0)
		_bd.set_border_width_all(1)
		_bd.set_corner_radius_all(7)
		queue_redraw()

	func setup(i: int) -> void:
		idx = i

	func set_data(i: int, name_: String, cost_: int, combo_: float, cd_: float, cd_max_: float) -> void:
		sname = name_
		cost = cost_
		combo = combo_
		cd = cd_
		cd_max = maxf(0.01, cd_max_)

	func tick(dt: float) -> void:
		_t += dt
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		var ready := cd <= 0.0 and combo >= float(cost)
		var lack := cd <= 0.0 and combo < float(cost)
		_sb.bg_color = Color(0.075, 0.09, 0.125, 0.92 if ready else 0.72)
		_sb.set_corner_radius_all(7)
		draw_style_box(_sb, rect)

		# 热键牌
		var badge := Rect2(5.0, 6.0, 30.0, size.y - 12.0)
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0.16, 0.13, 0.07, 0.95) if ready else Color(0.10, 0.11, 0.14, 0.9)
		bs.set_corner_radius_all(5)
		bs.border_color = Color(Hud.C_GOLD.r, Hud.C_GOLD.g, Hud.C_GOLD.b, 0.75 if ready else 0.22)
		bs.set_border_width_all(1)
		draw_style_box(bs, badge)
		var f := Art.font
		var num := str(idx + 1)
		var nw := f.get_string_size(num, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18.0).x
		draw_string(f, Vector2(badge.position.x + (badge.size.x - nw) * 0.5, badge.position.y + 26.0),
			num, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18.0,
			Hud.C_GOLD_HI if ready else Color(0.55, 0.55, 0.58))

		# 名字
		var name_col := Color(0.62, 0.62, 0.66) if lack else (Hud.C_GOLD_HI if ready else Color(0.80, 0.80, 0.82))
		draw_string(f, Vector2(44.0, 29.0), sname, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18.0, name_col)

		# 连击点：cost 个小菱形，够了就填亮
		var px := 44.0 + f.get_string_size(sname, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18.0).x + 12.0
		for i in cost:
			var on := combo >= float(i + 1)
			var cx := px + float(i) * 9.0
			var cy := 23.0
			var p4 := PackedVector2Array([
				Vector2(cx, cy - 4.0), Vector2(cx + 3.4, cy), Vector2(cx, cy + 4.0), Vector2(cx - 3.4, cy)])
			draw_colored_polygon(p4, Hud.C_GOLD_HI if on else Color(0.24, 0.25, 0.30))

		# 右边状态
		var txt := ""
		var tcol := Hud.C_OK
		if cd > 0.0:
			txt = "%.1fs" % cd
			tcol = Color(0.55, 0.55, 0.60)
		elif lack:
			txt = "连击不足"
			tcol = Color(0.55, 0.50, 0.46)
		else:
			txt = "就绪"
			tcol = Hud.C_OK
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15.0).x
		draw_string(f, Vector2(size.x - 12.0 - tw, 28.0), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15.0, tcol)

		# 冷却：底部一条从右往左退的亮线
		if cd > 0.0:
			var w := size.x * (1.0 - cd / cd_max)
			draw_rect(Rect2(1.0, size.y - 3.0, w, 2.0), Color(0.55, 0.62, 0.72, 0.85))
		elif ready:
			var gl := 0.35 + 0.25 * sin(_t * 4.0)
			draw_rect(Rect2(1.0, size.y - 3.0, size.x - 2.0, 2.0),
				Color(Hud.C_GOLD.r, Hud.C_GOLD.g, Hud.C_GOLD.b, gl))

		# 边框
		_bd.border_color = Color(Hud.C_GOLD.r, Hud.C_GOLD.g, Hud.C_GOLD.b, 1.0 if ready else 0.20)
		draw_style_box(_bd, rect)


## 三选一卡片。装饰自己画（渐变底、选中辉光、徽记），文字交给子 Label。
class DraftCard extends Control:
	var slot := 0
	var item: Dictionary = {}
	var selected := false
	var armed := true
	var base_pos := Vector2.ZERO
	var _t := 0.0
	var _lift := 0.0
	var emblem: TextureRect
	var kind_label: Label
	var name_label: Label
	var desc_label: Label
	var _built := false
	var _sb := StyleBoxFlat.new()
	var _bd := StyleBoxFlat.new()

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		pivot_offset = Vector2(146.0, 125.0)
		_bd.bg_color = Color(0, 0, 0, 0)
		queue_redraw()

	func ensure_children() -> void:
		if _built:
			return
		_built = true
		emblem = TextureRect.new()
		emblem.position = Vector2(0, 14)
		emblem.size = Vector2(292, 96)
		emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(emblem)
		kind_label = Label.new()
		kind_label.add_theme_font_override("font", Art.font)
		kind_label.add_theme_font_size_override("font_size", 13)
		kind_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		kind_label.add_theme_constant_override("outline_size", 4)
		kind_label.position = Vector2(0, 108)
		kind_label.size = Vector2(292, 20)
		kind_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(kind_label)
		name_label = Label.new()
		name_label.add_theme_font_override("font", Art.font_disp)
		name_label.add_theme_font_size_override("font_size", 26)
		name_label.add_theme_color_override("font_color", Hud.C_GOLD_HI)
		name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		name_label.add_theme_constant_override("outline_size", 6)
		name_label.position = Vector2(14, 128)
		name_label.size = Vector2(264, 36)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(name_label)
		desc_label = Label.new()
		desc_label.add_theme_font_override("font", Art.font)
		desc_label.add_theme_font_size_override("font_size", 15)
		desc_label.add_theme_color_override("font_color", Color(0.84, 0.83, 0.79))
		desc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		desc_label.add_theme_constant_override("outline_size", 4)
		desc_label.position = Vector2(16, 168)
		desc_label.size = Vector2(260, 66)
		desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(desc_label)

	func set_item(it: Dictionary, i: int, sel: bool) -> void:
		ensure_children()
		item = it
		slot = i
		selected = sel
		var kind := str(it.get("kind", "boon"))
		var tint: Color = Hud.CARD_WEAPON if kind == "weapon" else Hud.CARD_BOON
		kind_label.text = "换武器" if kind == "weapon" else "恩赐"
		kind_label.add_theme_color_override("font_color", tint)
		name_label.text = str(it["name"])
		desc_label.text = str(it["desc"])
		var tid := str(it.get("id", ""))
		var tex_name: String = str(Hud.EMBLEMS.get(tid, "star_06"))
		var t := Art.tex(tex_name)
		emblem.texture = t
		emblem.modulate = Color(tint.r, tint.g, tint.b, 0.95 if t != null else 0.0)
		queue_redraw()

	func tick(dt: float) -> void:
		_t += dt
		var want := 1.0 if selected else 0.0
		_lift = lerpf(_lift, want, minf(1.0, dt * 12.0))
		position = base_pos + Vector2(0.0, -14.0 * _lift)
		scale = Vector2.ONE * (1.0 + 0.035 * _lift)
		queue_redraw()

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		var kind := str(item.get("kind", "boon"))
		var tint: Color = Hud.CARD_WEAPON if kind == "weapon" else Hud.CARD_BOON
		var r := 10.0
		# 选中：先铺一圈辉光（比描边更像"亮着"）
		if selected:
			var g := 0.5 + 0.16 * sin(_t * 4.0)
			for i in range(6, 0, -1):
				var t := float(i) / 6.0
				var pad := 3.0 + t * 16.0
				_sb.bg_color = Color(tint.r, tint.g, tint.b, g * (1.0 - t) * 0.20)
				_sb.set_corner_radius_all(int(r + pad * 0.6))
				draw_style_box(_sb, rect.grow(pad))
		# 卡面：上浅下深的渐变（用 24 条横带近似）
		var bands := 24
		for i in bands:
			var t0 := float(i) / float(bands)
			var c := Color(0.115, 0.135, 0.185).lerp(Color(0.035, 0.045, 0.070), t0)
			if selected:
				c = c.lerp(Color(tint.r * 0.30, tint.g * 0.30, tint.b * 0.30), 0.35)
			_sb.bg_color = c
			_sb.set_corner_radius_all(int(r))
			var y0 := rect.position.y + rect.size.y * t0
			var y1 := rect.position.y + rect.size.y * float(i + 1) / float(bands)
			draw_rect(Rect2(rect.position.x + 1.0, y0, rect.size.x - 2.0, y1 - y0 + 0.8), c)
		# 顶部一道彩色引导线
		_sb.bg_color = Color(tint.r, tint.g, tint.b, 0.9 if selected else 0.45)
		_sb.set_corner_radius_all(3)
		draw_style_box(_sb, Rect2(rect.position.x + 12.0, rect.position.y + 5.0,
			rect.size.x - 24.0, 3.0))
		# 描边
		_bd.border_color = Color(tint.r, tint.g, tint.b, 1.0 if selected else 0.30)
		_bd.set_border_width_all(2 if selected else 1)
		_bd.set_corner_radius_all(int(r))
		draw_style_box(_bd, rect)
		# 未装填：整张卡压暗一点，提示"还不能按"
		if not armed:
			draw_rect(rect, Color(0.0, 0.0, 0.0, 0.28))


## 装填进度条：三选一面板刚弹出时，确认键故意不生效 ——
## 这根条把"还不能按"这件事变成看得见的东西，而不是让玩家以为按键坏了。
class ArmBar extends Control:
	var v := 0.0
	var ready_now := false
	var _t := 0.0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set01(x: float) -> void:
		v = clampf(x, 0.0, 1.0)

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color(1.0, 1.0, 1.0, 0.08))
		var c := Color(Hud.C_GOLD.r, Hud.C_GOLD.g, Hud.C_GOLD.b, 0.9) if ready_now \
			else Color(Hud.C_EMBER.r, Hud.C_EMBER.g, Hud.C_EMBER.b, 0.85)
		draw_rect(Rect2(0.0, 0.0, size.x * v, size.y), c)


## 面板角上那盏小灯（纯装饰，让人一眼认出这是"灯骑士"的界面）
class PanelLamp extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		Art.glow(self, c, 16.0, Color(1.0, 0.78, 0.42), 0.55)
		draw_circle(c, 3.6, Color(1.0, 0.96, 0.86))


## 覆盖层插画：一盏提灯 + 光扇 + 飘浮的火星。
## 标题/通关是暖的，死亡把那盏灯熄掉一半（几乎全黑、只剩一点冷光）。
class OvArt extends Control:
	var mode := "title"
	var _t := 0.0
	var _embers := []
	var _seeded := false
	var _lantern := Vector2(640.0, 196.0)

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _seed() -> void:
		_seeded = true
		var rng := RandomNumberGenerator.new()
		rng.seed = 7717
		for i in 54:
			_embers.append({
				"x": rng.randf() * Proj.VIEW_W,
				"y": rng.randf() * Proj.VIEW_H + Proj.VIEW_H,
				"sp": 8.0 + rng.randf() * 26.0,
				"r": 0.8 + rng.randf() * 2.2,
				"ph": rng.randf() * TAU,
			})

	func tick(dt: float) -> void:
		if not _seeded:
			_seed()
		_t += dt
		for e in _embers:
			e["y"] = float(e["y"]) - float(e["sp"]) * dt
			if float(e["y"]) < -20.0:
				e["y"] = Proj.VIEW_H + 20.0
		queue_redraw()

	func _draw() -> void:
		if not _seeded:
			_seed()
		var warm := 1.0
		var hue := Color(1.0, 0.80, 0.46)
		if mode == "death":
			warm = 0.32
			hue = Color(0.60, 0.72, 0.90)
		elif mode == "clear":
			warm = 0.85
			hue = Color(1.0, 0.88, 0.62)
		var cx := _lantern.x
		var cy := _lantern.y

		# 背后的光
		Art.glow(self, Vector2(cx, cy), 300.0 * warm, hue, 0.20 * warm)
		Art.glow(self, Vector2(cx, cy), 130.0 * warm, Color(1.0, 0.86, 0.62), 0.22 * warm)

		# 旋转的光扇：8 道，很淡，慢
		for i in 8:
			var a := _t * 0.12 + float(i) * TAU / 8.0
			var ln := 520.0
			var wdt := 0.16
			draw_colored_polygon(PackedVector2Array([
				Vector2(cx, cy),
				Vector2(cx + cos(a - wdt) * ln, cy + sin(a - wdt) * ln * 0.55),
				Vector2(cx + cos(a + wdt) * ln, cy + sin(a + wdt) * ln * 0.55),
			]), Color(hue.r, hue.g, hue.b, 0.055 * warm))

		# 提梁 + 灯身
		var cc := Color(0.30, 0.26, 0.20, 0.95)
		draw_line(Vector2(cx, cy - 150.0), Vector2(cx, cy - 92.0), cc, 2.0, true)
		draw_arc(Vector2(cx, cy - 92.0), 22.0, PI, TAU, 24, cc, 2.4, true)
		var body := PackedVector2Array([
			Vector2(cx - 30.0, cy - 68.0), Vector2(cx + 30.0, cy - 68.0),
			Vector2(cx + 38.0, cy - 30.0), Vector2(cx + 24.0, cy + 22.0),
			Vector2(cx - 24.0, cy + 22.0), Vector2(cx - 38.0, cy - 30.0),
		])
		draw_colored_polygon(body, Color(0.10, 0.11, 0.15, 0.96))
		var col_gold := Color(hue.r, hue.g, hue.b, 0.55 + 0.25 * warm)
		draw_polyline(PackedVector2Array([
			Vector2(cx - 30.0, cy - 68.0), Vector2(cx + 30.0, cy - 68.0),
			Vector2(cx + 38.0, cy - 30.0), Vector2(cx + 24.0, cy + 22.0),
			Vector2(cx - 24.0, cy + 22.0), Vector2(cx - 38.0, cy - 30.0),
			Vector2(cx - 30.0, cy - 68.0),
		]), col_gold, 2.0, true)
		# 灯芯
		var fl := 1.0 + sin(_t * 5.2) * 0.10
		Art.glow(self, Vector2(cx, cy - 24.0), 62.0 * fl * (0.4 + 0.6 * warm),
			hue, 0.55 * warm)
		draw_circle(Vector2(cx, cy - 24.0), 7.5 * fl, Color(1.0, 0.97, 0.90, 0.35 + 0.6 * warm))
		# 提灯下沿透出的光
		draw_colored_polygon(PackedVector2Array([
			Vector2(cx - 20.0, cy + 22.0), Vector2(cx + 20.0, cy + 22.0),
			Vector2(cx + 78.0, cy + 150.0), Vector2(cx - 78.0, cy + 150.0),
		]), Color(hue.r, hue.g, hue.b, 0.07 * warm))

		# 火星
		for e in _embers:
			var a := 0.25 + 0.30 * sin(_t * 1.6 + float(e["ph"]))
			Art.glow(self, Vector2(float(e["x"]), float(e["y"])), float(e["r"]) * 6.0,
				hue, a * 0.5 * warm)
			draw_circle(Vector2(float(e["x"]), float(e["y"])), float(e["r"]),
				Color(1.0, 0.93, 0.78, a * warm))
