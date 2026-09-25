class_name World
extends Node2D
## World —— 世界核心。逻辑逐条对齐 Web 版 src/game/world.ts。
##
## 设计取向：实体是普通 RefCounted 数据对象，世界自己以**固定步长**推进（step(dt)），
## 绘制全部走 _draw() 的即时模式。这是刻意选择——它让逻辑移植是"翻译"而不是"重写"，
## 也让自检可以在真实引擎里逐帧驱动、和游戏内完全同一条代码路径。
## 代价是没用到编辑器的节点树可视化，这一点写在 README 的取舍一节里。
##
## 光照、HUD 各自独立：LightRig 负责灯与遮挡体，Hud 负责界面。

const HITSTOP_HIT := 0.045
const HITSTOP_CRIT := 0.075
const DT_MAX := 1.0 / 30.0

# ---------------------------------------------------------------- 世界数据

var level := {}
var cam := Vector2.ZERO
var shake := 0.0
var hitstop := 0.0
var time := 0.0
var flash_color := Color.WHITE
var flash_power := 0.0
var ambient := 0.9
var cleared := false

var walls := []            # [x, y, w, d, h]
var props := []            # {kind,x,y,r,h,solid,seed,lit,lit_t,pulse}
var enemies: Array[EnemyState] = []
var drops := []
var effects := []
var particles := []
var texts := []
var projs := []

var player: PlayerState
var waves := []            # {def, spawned, cleared, members}
var braziers := []
var chests := []           # 宝箱（也是 props 里的一项，这里单独存一份方便遍历）
var goal_prop := {}
var merchant_prop := {}
var girl = null

var boss_enemy: EnemyState = null
var boss_spawned := false
var boss_dead := false
var boss_hinted := false
var braziers_lit := 0
var respawn_timer := 0.0
var prompt := ""
var objective := ""
var events := []

# ---------------------------------------------------------------- 肉鸽 / 第二关
## 当前关卡序号（0 = 外庭，1 = 无芯之暗）
var level_index := 0
## 局内恩赐：id → 层数。存在 prog 里，所以过关会带走、死亡会清空。
var boons := {}
## 已发过三选一的波次下标（每波只弹一次）
var draft_done := {}
## 三选一是"波次清空 → 事件 → Main 接管"，World 只负责触发，不持有选择的态
## 盲女是否在光照加成范围内
var girl_near := false
## 无芯之暗：火盆没点满时，死掉的敌人会再生
var respawn_queue := []
## 再生计数（自检用）
var respawn_count := 0
## 本关是否需要点满火盆
var braziers_required := 0

## 调试：进入关卡立刻刷出全部波次与 Boss
var dev_spawn_all := false
var dev_spawned := false

var light_rig: LightRig
var bloom: Bloom
## 这一帧实际用于绘制的相机（含震屏偏移）。光照层也用它，否则影子会与画面脱开。
var draw_cam := Vector2.ZERO

var prog := {
	"coins": 0, "wicks": 0,
	"up": {"hp": 0, "light": 0, "edge": 0},
	"shop": {"ember": 0, "brightoil": 0},
	"weapon": "blade",
	## 背包里的备用武器（"" = 空）。按 X 与手持互换。
	"bag_weapon": "",
	## 武器词条：{武器id: [{"id": 词条id, "lv": 等级}, ...]}。
	## 挂在**武器 id** 上而不是"当前手持"上 —— 换手不丢，换回来还在。
	"waffix": {},
	"kills": 0, "deaths": 0, "max_combo": 0,
	"used_revive": false,
}

var _next_id := 1
var _rng: RandomNumberGenerator
var _decor_rng: RandomNumberGenerator
## 重铸 / 锤炼 / 宝箱各自独立的随机源。**绝不能用 `_rng`** ——
## `_rng` 是主仿真流，动它会把之后所有的世界演化都挪掉（见 README 的"步数就是货币"）。
var _shop_rng: RandomNumberGenerator
var _chest_rng: RandomNumberGenerator


func setup(dev := false, lv_index := -1) -> void:
	dev_spawn_all = dev
	if lv_index >= 0:
		level_index = lv_index
	level = Content.level_at(level_index)
	_rng = Proj.make_rng(int(level["seed"]))
	_decor_rng = Proj.make_rng(int(level["seed"]) + 991)
	# 商店/宝箱的随机源：和 _rng、_decor_rng 都分开，互不干扰（各自确定）
	_shop_rng = Proj.make_rng(int(level["seed"]) + 6060)
	_chest_rng = Proj.make_rng(int(level["seed"]) + 5150)
	ambient = float(level["ambient"])

	if not prog.has("boons"):
		prog["boons"] = {}
	boons = prog["boons"]
	# 背包与词条表：跨关保留（prog 是 Main 传进来的那一份）
	if not prog.has("bag_weapon"):
		prog["bag_weapon"] = ""
	if not prog.has("waffix"):
		prog["waffix"] = {}
	# 三选一的随机源按关卡重置 → 同一关的抽取序列可复现
	draft_rng = Proj.make_rng(int(level["seed"]) + 4242)

	for w in level["walls"]:
		walls.append([float(w[0]), float(w[1]), float(w[2]), float(w[3]), float(w[4])])

	player = PlayerState.new()
	player.x = level["start"].x
	player.y = level["start"].y
	player.max_hp = 100.0 + float(prog["up"]["hp"]) * 25.0 + float(prog["shop"]["ember"]) * 12.0 \
		+ float(boon("hp")) * 22.0
	player.hp = player.max_hp
	player.weapon_id = str(prog["weapon"])

	for pd in level["props"]:
		props.append(_make_prop(pd))
	_decorate()

	# 宝箱：**必须等 _decorate() 之后再入 props**。
	# 两个原因，都是"不要打扰已经量好的世界"：
	#   ① props 里每一项都要 `_decor_rng.randi_range` 抽 seed —— 提前加会挪动装饰的随机流；
	#   ② `_decorate()` 会躲开已有道具 120px —— 提前加会改变"哪里能放装饰"的判定。
	# 两条都会让整关装饰换位置，把依赖装饰的像素断言全撞掉。
	for cp in level.get("chests", []):
		var chest := {
			"kind": "chest", "x": float(cp.x), "y": float(cp.y),
			"r": float(Content.PROP_TABLE["chest"]["r"]),
			"h": float(Content.PROP_TABLE["chest"]["h"]),
			"solid": false, "seed": 0, "lit": false, "lit_t": 0.0, "pulse": 0.0,
			"opened": false, "items": [],
		}
		props.append(chest)
		chests.append(chest)

	for pr in props:
		match str(pr["kind"]):
			"brazier":
				braziers.append(pr)
			"merchant":
				merchant_prop = pr
			"lighthouse":
				goal_prop = pr
	if not goal_prop.is_empty():
		goal_prop["x"] = level["goal"]["pos"].x
		goal_prop["y"] = level["goal"]["pos"].y

	braziers_required = int(level.get("braziers_required", 0))

	# 肉鸽：波次组成每次跑都不一样（用关卡种子派生，仍然确定）
	var rolled := _roll_waves()

	for wd in rolled:
		waves.append({"def": wd, "spawned": false, "cleared": false, "members": []})

	# 盲女同行（第二关）
	if level.has("blind_girl"):
		var gp: Vector2 = level["blind_girl"]
		girl = {
			"x": gp.x, "y": gp.y, "r": 13.0, "h": 38.0,
			"vx": 0.0, "vy": 0.0, "wob": 0.0, "talk_cd": 0.0, "talked": false,
		}

	cam = Vector2(player.x, player.y)

	light_rig = LightRig.new()
	light_rig.name = "LightRig"
	add_child(light_rig)
	light_rig.build_occluders(walls)

	bloom = Bloom.new()
	bloom.name = "Bloom"
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	bloom.material = mat
	bloom.world = self
	add_child(bloom)

	Art.ensure_font()
	_update_objective()
	emit_hud()


# ---------------------------------------------------------------- 肉鸽：派生属性
#
# 恩赐（BOONS）全部走这几个访问器，不要在别处硬编码倍率，
# 否则自检的数值断言和实际手感会脱节。

func boon(id: String) -> int:
	return int(boons.get(id, 0))


# ---------------------------------------------------------------- 武器词条
#
# 词条存在 `prog["waffix"]`：`{武器id: [{"id":…, "lv":…}, …]}`。
# 读的时候一律走下面这几个访问器，**写的时候**只有守灯人的重铸/锤炼两个入口。
#
# 注意 `affix_lv()` 默认看的是**手持**那把武器 —— 所以"换手之后手感变了"
# 是自动生效的，不需要在 swap 里再同步一遍任何东西。

## 取某把武器的词条数组。create=true 时顺便建好条目（写入路径用）。
func _affix_arr(wid: String, create := false) -> Array:
	if not prog["waffix"].has(wid):
		if not create:
			return []
		prog["waffix"][wid] = []
	return prog["waffix"][wid]


## 某把武器的词条列表（默认手持那把）
func weapon_affixes(wid := "") -> Array:
	return _affix_arr(wid if wid != "" else str(prog["weapon"]))


## 某条词条在某把武器上的等级（0 = 没有）
func affix_lv(id: String, wid := "") -> int:
	for a in weapon_affixes(wid):
		if str(a["id"]) == id:
			return int(a["lv"])
	return 0


## 某把武器所有词条的**等级之和** —— 锤炼的价钱按它涨
func affix_levels_sum(wid := "") -> int:
	var s := 0
	for a in weapon_affixes(wid):
		s += int(a["lv"])
	return s


## HUD 用：{id,name,lv,color,desc}
func affix_list(wid := "") -> Array:
	var out := []
	for a in weapon_affixes(wid):
		var id := str(a["id"])
		var meta: Dictionary = Content.WEAPON_AFFIXES.get(id, {})
		out.append({
			"id": id, "name": str(meta.get("name", id)), "lv": int(a["lv"]),
			"color": str(meta.get("color", "#ffe0a8")),
			"desc": str(meta.get("desc", "")),
		})
	return out


## 背包里的灯油数量（背包里的回血道具）
func potion_count() -> int:
	return int(prog["shop"].get("oil_bank", 0))


# ---------------------------------------------------------------- 派生属性
#
# 这一节是**唯一**把「恩赐 + 词条 + 存档升级」折成倍率的地方。
# 别在别处再乘一遍：自检的数值断言全靠这里。

## 挥击冷却倍率（灯芯·疾 + 词条「疾」）
func attack_cd_mul() -> float:
	return pow(0.88, float(boon("haste"))) * pow(0.90, float(affix_lv("swift")))


## 技能冷却倍率（灯芯·通）
func skill_cd_mul() -> float:
	return pow(0.82, float(boon("skill_cd")))


## 技能连击消耗（省火 + 词条「省」，最低 1）
func skill_cost(cost: int) -> int:
	return maxi(1, cost - boon("cost_cut") - affix_lv("frugal"))


## 攻击范围倍率（灯芯·远 + 词条「远」）
func reach_mul() -> float:
	return 1.0 + float(boon("reach")) * 0.12 + float(affix_lv("reach")) * 0.12


## 暴击概率（灯芯·锐 + 词条「锐」）
func crit_chance() -> float:
	return minf(0.75, float(boon("crit")) * 0.12 + float(affix_lv("crit")) * 0.08)


## 连击衰减速度（火种不熄）
func combo_decay() -> float:
	return 14.0 * pow(0.7, float(boon("combo_up")))


## 命中额外连击（越战越亮 + 词条「火」）
func combo_bonus() -> float:
	return float(boon("combo_add")) * 0.2 + float(affix_lv("ember")) * 0.15


# ---------------------------------------------------------------- 肉鸽：波次随机
#
# 关卡数据里写的是"这一波大概长什么样"，每次进关再按种子做一次扰动：
#   · 类型可能被替换成同档次的其他怪
#   · 数量 ±1
#   · 有一定概率把一只普通怪升级成带词缀的精英
# 同一局内确定（种子派生），不同局不同 —— 这就是"每一趟都不一样"。

const WAVE_SWAP := {
	"shade": ["shade", "moth", "moth"],
	"moth": ["moth", "shade"],
	"guard": ["guard", "guard", "leech"],
	"leech": ["leech", "moth"],
}

func _roll_waves() -> Array:
	var rng := Proj.make_rng(int(level["seed"]) + 7331)
	var out := []
	for wd in level["waves"]:
		var groups := []
		for grp in wd["enemies"]:
			var tid := str(grp["type"])
			var pool: Array = WAVE_SWAP.get(tid, [tid])
			var picked := str(pool[rng.randi_range(0, pool.size() - 1)])
			var count := maxi(1, int(grp["count"]) + rng.randi_range(-1, 1))
			var is_elite := bool(grp.get("elite", false))
			# 普通怪有 18% 概率被随机挑成精英（每波最多一只）
			groups.append({"type": picked, "count": count, "elite": is_elite})
		# 每波最多一只精英：从非精英组里挑一只，按种子决定
		var has_elite := false
		for g in groups:
			if bool(g["elite"]):
				has_elite = true
		if not has_elite and rng.randf() < 0.18:
			var idx := rng.randi_range(0, groups.size() - 1)
			groups[idx]["elite"] = true
		# 每一波可能有额外的一小撮散怪（越后面越多）
		if rng.randf() < 0.35:
			groups.append({"type": "moth", "count": rng.randi_range(2, 3), "elite": false})
		out.append({
			"label": str(wd["label"]), "x": float(wd["x"]), "y": float(wd["y"]),
			"radius": float(wd["radius"]), "enemies": groups,
		})
	return out


## 抽三个恩赐/武器给玩家选。武器只在"还没拿到的"里抽。
## 全部随机都走 draft_rng（**不用 Array.shuffle()**，它吃全局 RNG，
## 会让自检的三选一不可复现）。draft_rng 在第一次抽时按关卡种子初始化。
func roll_draft() -> Array:
	if draft_rng == null:
		draft_rng = Proj.make_rng(int(level["seed"]) + 4242)
	var pool := []
	for b in Content.BOONS:
		pool.append({"kind": "boon", "id": str(b["id"]), "name": str(b["name"]),
			"desc": str(b["desc"])})
	# 武器也算一种"恩赐"：换一把武器
	var owned := str(prog["weapon"])
	var others := []
	for wid in Content.WEAPONS.keys():
		if str(wid) != owned:
			others.append(str(wid))
	if not others.is_empty():
		var wpicks := []
		var g1 := 0
		while wpicks.size() < 2 and g1 < 40:
			g1 += 1
			var cand := str(others[draft_rng.randi_range(0, others.size() - 1)])
			if not wpicks.has(cand):
				wpicks.append(cand)
		for wid in wpicks:
			var wd: Dictionary = Content.WEAPONS[wid]
			pool.append({"kind": "weapon", "id": wid, "name": str(wd["name"]),
				"desc": "换上「%s」。%s" % [str(wd["name"]), str(wd["desc"])]})
	# 从池里不重复抽三个
	var picked := []
	var guard := 0
	while picked.size() < 3 and guard < 200:
		guard += 1
		var it: Dictionary = pool[draft_rng.randi_range(0, pool.size() - 1)]
		var dup := false
		for q in picked:
			if str(q["id"]) == str(it["id"]):
				dup = true
				break
		if not dup:
			picked.append(it)
	return picked


## 三选一里用的随机源。单独抽出来，方便自检注入固定种子。
var draft_rng: RandomNumberGenerator = null


func apply_draft(item: Dictionary) -> void:
	var kind := str(item.get("kind", "boon"))
	var id := str(item["id"])
	if kind == "weapon":
		prog["weapon"] = id
		player.weapon_id = id
		player.skill_cd.clear()
		events.append({"type": "toast", "text": "换上了「%s」" % str(item["name"])})
	else:
		boons[id] = int(boons.get(id, 0)) + 1
		if id == "hp":
			player.max_hp += 22.0
			player.hp = minf(player.max_hp, player.hp + 22.0)
		events.append({"type": "toast", "text": "获得恩赐「%s」" % str(item["name"])})
	sfx("levelup")
	flash_color = Color.html("#ffd9a0")
	flash_power = 0.3


## 恩赐列表（HUD 与自检用）
func boon_list() -> Array:
	var out := []
	for b in Content.BOONS:
		var c := boon(str(b["id"]))
		if c > 0:
			out.append({"id": str(b["id"]), "name": str(b["name"]), "count": c})
	return out


# ================================================================ 背包 / 换手 / 灯油
#
# · 背包栏 —— 额外带一把武器（`prog["bag_weapon"]`）+ 存的回血道具（`prog["shop"]["oil_bank"]`）
# · X 换手 —— 手持 ↔ 背包 互换
# · C 喝灯油 —— 消耗一件回血
#
# 灯油沿用**已有的**第 3 种掉落（`_take_drop` 里的 "oil" 早就往 `oil_bank` 里加了），
# 只是在此之前没有任何地方消费它 —— 现在它是背包里的回血道具。

func weapon_name(wid: String) -> String:
	var w: Dictionary = Content.WEAPONS.get(wid, Content.WEAPONS["blade"])
	return str(w["name"])


## 换手：手持 ↔ 背包。**背包空时什么都不做**，只提示 ——
## 不做"把手上的塞进背包、手上变空"，那等于让玩家一键把自己缴械。
func swap_weapon() -> bool:
	var cur := str(prog["weapon"])
	var bag := str(prog.get("bag_weapon", ""))
	if bag == "":
		events.append({"type": "toast", "text": "背包里没有备用武器。"})
		sfx("ui")
		return false
	prog["weapon"] = bag
	prog["bag_weapon"] = cur
	player.weapon_id = bag
	player.skill_cd.clear()      # 换武器 → 技能冷却重算（与三选一换武器一致）
	sfx("swap")
	var w := player.weapon()
	events.append({"type": "toast", "text": "换手：「%s」→「%s」"
		% [weapon_name(cur), str(w["name"])]})
	return true


## 喝一件灯油回血。**没药 / 满血都不消耗** —— 别让玩家白扔一瓶。
func use_potion() -> bool:
	var p := player
	if p.dead:
		return false
	var n := potion_count()
	if n <= 0:
		events.append({"type": "toast", "text": "背包里没有灯油。"})
		sfx("ui")
		return false
	if p.hp >= p.max_hp - 0.01:
		events.append({"type": "toast", "text": "生命是满的，灯油先留着。"})
		sfx("ui")
		return false
	var healed := minf(p.max_hp, p.hp + p.max_hp * float(Content.SHOP["oil"]["heal"])) - p.hp
	p.hp += healed
	prog["shop"]["oil_bank"] = n - 1
	sfx("coin")
	_add_text(p.x, p.y, 70.0, "+%d" % int(round(healed)), "#ffe0a8", 16.0)
	events.append({"type": "toast", "text": "喝下灯油 ×1（背包还剩 %d）" % (n - 1)})
	return true


# ================================================================ 宝箱

## 从词条表里**不重复**抽 n 条，等级都是 1。走 _shop_rng（不碰主仿真流）。
func _roll_affixes(n: int) -> Array:
	var out := []
	var guard := 0
	while out.size() < n and guard < 80:
		guard += 1
		var id := str(Content.AFFIX_ORDER[
			_shop_rng.randi_range(0, Content.AFFIX_ORDER.size() - 1)])
		var dup := false
		for a in out:
			if str(a["id"]) == id:
				dup = true
				break
		if not dup:
			out.append({"id": id, "lv": 1})
	return out


## "锋×2　噬×1" 这样的短描述（HUD 与 toast 共用）
func _affix_desc(arr: Array) -> String:
	var parts := []
	for a in arr:
		var meta: Dictionary = Content.WEAPON_AFFIXES.get(str(a["id"]), {})
		parts.append("%s×%d" % [str(meta.get("name", str(a["id"]))), int(a["lv"])])
	return "　".join(parts)


## 抽宝箱的三把武器。**排除手持与背包这两把** ——
## 否则开箱开出手上那把，玩家会觉得箱子坏了。
func roll_chest() -> Array:
	var exclude := [str(prog["weapon"]), str(prog.get("bag_weapon", ""))]
	var cands := []
	for wid in Content.WEAPONS.keys():
		if not exclude.has(str(wid)):
			cands.append(str(wid))
	if cands.is_empty():     # 兜底：8 把武器不可能全被排除，但别让箱子空着
		for wid in Content.WEAPONS.keys():
			cands.append(str(wid))
	var picked := []
	var guard := 0
	while picked.size() < 3 and guard < 60:
		guard += 1
		var wid := str(cands[_chest_rng.randi_range(0, cands.size() - 1)])
		if not picked.has(wid):
			picked.append(wid)
	var out := []
	for wid in picked:
		var affix := _roll_affixes(1)
		var wd: Dictionary = Content.WEAPONS[wid]
		var desc := "%s　词条：%s" % [str(wd["desc"]), _affix_desc(affix)]
		# 卡片左上角那行小字：开箱是"入背包"，不是"换武器"（换手要按 X）
		out.append({"kind": "weapon", "id": wid, "name": str(wd["name"]),
			"desc": desc, "affix": affix, "kind_label": "入背包"})
	return out


func open_chest(pr: Dictionary) -> void:
	if bool(pr.get("opened", false)):
		events.append({"type": "toast", "text": "这个箱子已经空了。"})
		sfx("ui")
		return
	pr["opened"] = true
	pr["items"] = roll_chest()
	sfx("open")
	_spawn_fx(float(pr["x"]), float(pr["y"]), "#ffd9a0")
	events.append({"type": "toast", "text": "箱盖掀开了。"})
	# 面板交给 main 开（世界只负责"箱子里有什么"）
	events.append({"type": "chest", "items": pr["items"]})


## 开箱选中一把 → 进背包。背包满了就把旧的**换下来丢掉**（toast 明说）。
## 这里刻意不做"掉到地上再捡" —— 那要引入可拾取的武器掉落，
## 而掉落一多，`_update_drops` 的随机流和自检的时机断言都会变脆。
func apply_chest(item: Dictionary) -> void:
	var wid := str(item["id"])
	var bag := str(prog.get("bag_weapon", ""))
	# 这把武器还没有词条时才带上宝箱给的 —— 别覆盖已经练过的
	var affix: Array = item.get("affix", [])
	if not affix.is_empty() and weapon_affixes(wid).is_empty():
		prog["waffix"][wid] = affix
	if bag != "":
		events.append({"type": "toast", "text": "背包里的「%s」被搁下了。" % weapon_name(bag)})
	prog["bag_weapon"] = wid
	sfx("levelup")
	flash_color = Color.html("#ffd9a0")
	flash_power = 0.3
	events.append({"type": "toast",
		"text": "「%s」放进了背包（按 X 换手）" % weapon_name(wid)})


# ================================================================ 守灯人：重铸 / 锤炼

func shop_oil_price() -> int:
	return int(Content.SHOP["oil"]["price"])


func reforge_price() -> int:
	return int(Content.SHOP["reforge"]["price"])


## 锤炼价钱随"这把武器词条等级之和"上涨 —— 越练越贵，防免费刷数值
func temper_price() -> int:
	return Content.temper_cost(affix_levels_sum())


## 还能不能锤炼：词条没满，或者还有词条没到等级上限
func _can_temper(wid: String) -> bool:
	var arr := weapon_affixes(wid)
	if arr.size() < Content.AFFIX_MAX:
		return true
	for a in arr:
		if int(a["lv"]) < Content.AFFIX_LV_MAX:
			return true
	return false


## 商店的三个选项。**HUD 与自检都读这一份**，别各写一套文案与价钱。
func shop_items() -> Array:
	var cur := str(prog["weapon"])
	var coins := int(prog["coins"])
	var cur_affix := _affix_desc(weapon_affixes(cur))
	if cur_affix == "":
		cur_affix = "现在没有词条"
	var oil_p := shop_oil_price()
	var ref_p := reforge_price()
	var tem_p := temper_price()
	var can_tem := _can_temper(cur)
	var out := []
	out.append({
		"id": "oil", "name": "买灯油", "price": oil_p,
		"desc": "灯油 ×1（背包现有 %d）。按 C 喝，回 45%% 生命。" % potion_count(),
		"ok": coins >= oil_p,
	})
	out.append({
		"id": "reforge", "name": "重铸", "price": ref_p,
		"desc": "把「%s」的词条全部重 roll。当前：%s" % [weapon_name(cur), cur_affix],
		"ok": coins >= ref_p,
	})
	out.append({
		"id": "temper", "name": "锤炼", "price": tem_p,
		"desc": "给「%s」加一条词条，满了就升一级。当前：%s" % [weapon_name(cur), cur_affix],
		"ok": coins >= tem_p and can_tem,
	})
	return out


func buy_shop(id: String) -> bool:
	match id:
		"oil":
			return buy_oil()
		"reforge":
			return reforge_weapon()
		"temper":
			return temper_weapon()
	return false


## 买灯油：**进背包**，不是当场回血（用户要的就是"存背包里"）
func buy_oil() -> bool:
	var price := shop_oil_price()
	if int(prog["coins"]) < price:
		events.append({"type": "toast", "text": "灯火不够（灯油要 %d，你有 %d）。"
			% [price, int(prog["coins"])]})
		sfx("ui")
		return false
	prog["coins"] = int(prog["coins"]) - price
	prog["shop"]["oil_bank"] = potion_count() + 1
	sfx("coin")
	events.append({"type": "toast", "text": "买下灯油 ×1（背包里现在 %d 件）。" % potion_count()})
	return true


## 重铸：词条**全部推倒重来**（1~3 条，等级归 1）
func reforge_weapon() -> bool:
	var price := reforge_price()
	if int(prog["coins"]) < price:
		events.append({"type": "toast", "text": "灯火不够（重铸要 %d）。" % price})
		sfx("ui")
		return false
	var wid := str(prog["weapon"])
	var arr := _roll_affixes(_shop_rng.randi_range(1, Content.AFFIX_MAX))
	prog["coins"] = int(prog["coins"]) - price
	prog["waffix"][wid] = arr
	sfx("levelup")
	events.append({"type": "toast", "text": "重铸「%s」：%s"
		% [weapon_name(wid), _affix_desc(arr)]})
	return true


## 锤炼：没满就**加一条**，满了就**升一级**
func temper_weapon() -> bool:
	var wid := str(prog["weapon"])
	if not _can_temper(wid):
		events.append({"type": "toast", "text": "「%s」的词条已经练满了。" % weapon_name(wid)})
		sfx("ui")
		return false
	var price := temper_price()
	if int(prog["coins"]) < price:
		events.append({"type": "toast", "text": "灯火不够（锤炼要 %d）。" % price})
		sfx("ui")
		return false
	var arr := _affix_arr(wid, true)
	var msg := ""
	if arr.size() < Content.AFFIX_MAX:
		var cands := []
		for id in Content.AFFIX_ORDER:
			if affix_lv(str(id), wid) == 0:
				cands.append(str(id))
		var nid := str(cands[_shop_rng.randi_range(0, cands.size() - 1)])
		arr.append({"id": nid, "lv": 1})
		msg = "添了词条「%s」" % str(Content.WEAPON_AFFIXES[nid]["name"])
	else:
		var ups := []
		for a in arr:
			if int(a["lv"]) < Content.AFFIX_LV_MAX:
				ups.append(a)
		var up: Dictionary = ups[_shop_rng.randi_range(0, ups.size() - 1)]
		up["lv"] = int(up["lv"]) + 1
		msg = "词条「%s」升到 %d 级" % [
			str(Content.WEAPON_AFFIXES[str(up["id"])]["name"]), int(up["lv"])]
	prog["coins"] = int(prog["coins"]) - price
	sfx("levelup")
	events.append({"type": "toast", "text": "锤炼「%s」：%s" % [weapon_name(wid), msg]})
	return true



func _make_prop(pd: Dictionary) -> Dictionary:
	var kind := str(pd["kind"])
	var tbl: Dictionary = Content.PROP_TABLE[kind]
	return {
		"kind": kind, "x": float(pd["x"]), "y": float(pd["y"]),
		"r": float(tbl["r"]), "h": float(tbl["h"]), "solid": bool(tbl["solid"]),
		"seed": int(_decor_rng.randi_range(0, 99999)),
		"lit": false, "lit_t": 0.0, "pulse": _decor_rng.randf() * TAU,
	}


## 装饰：按固定种子撒在空地上，保证同一关每次一样（照抄 Web 版的约束）
func _decorate() -> void:
	var kinds := ["pillar", "lantern", "tree", "rubble", "rubble"]
	var placed := 0
	var guard := 0
	while placed < int(level["decor_count"]) and guard < 1200:
		guard += 1
		var x := _decor_rng.randf_range(90.0, float(level["w"]) - 90.0)
		var y := _decor_rng.randf_range(90.0, float(level["h"]) - 90.0)
		if blocked(x, y, 40.0):
			continue
		if Proj.dist(x, y, level["start"].x, level["start"].y) < 150.0:
			continue
		if Proj.dist(x, y, level["goal"]["pos"].x, level["goal"]["pos"].y) < 190.0:
			continue
		var near := false
		for pr in props:
			if Proj.dist(x, y, float(pr["x"]), float(pr["y"])) < 120.0:
				near = true
				break
		if near:
			continue
		props.append(_make_prop({"kind": kinds[_decor_rng.randi_range(0, kinds.size() - 1)], "x": x, "y": y}))
		placed += 1


# ---------------------------------------------------------------- 碰撞

func blocked(x: float, y: float, r: float) -> bool:
	for w in walls:
		if Proj.circle_rect(x, y, r, w[0], w[1], w[2], w[3]):
			return true
	return false


func collide_wall(pos: Vector2, r: float) -> Vector2:
	var o := pos
	for w in walls:
		o = Proj.push_out_rect(o.x, o.y, r, w[0], w[1], w[2], w[3])
	for pr in props:
		if not bool(pr["solid"]):
			continue
		o = Proj.push_out_rect(o.x, o.y, r + float(pr["r"]) * 0.6, float(pr["x"]), float(pr["y"]), 1.0, 1.0)
	o.x = clampf(o.x, r + 6.0, float(level["w"]) - r - 6.0)
	o.y = clampf(o.y, r + 6.0, float(level["h"]) - r - 6.0)
	return o


# ---------------------------------------------------------------- 派生属性

## 光照半径：基础 150，灯芯/明油/恩赐加成，连击每层 +7（上限 40 层），挥击辉光再加。
## 第二关盲女在身边时另加 GIRL_LIGHT_BONUS —— 这是「可你在我身边时，我就感到格外亮堂」。
const GIRL_LIGHT_BONUS := 52.0

func player_light_radius() -> float:
	var p := player
	var r := 150.0 + float(prog["up"]["light"]) * 24.0 + float(prog["shop"]["brightoil"]) * 10.0
	r += float(boon("light")) * 26.0
	r += float(affix_lv("shine")) * 22.0
	r += minf(p.combo, 40.0) * 7.0
	r += p.glow * 46.0
	if girl_near:
		r += GIRL_LIGHT_BONUS
	return r


func brightness01() -> float:
	return clampf((minf(player.combo, 40.0) * 7.0 + player.glow * 40.0) / 280.0, 0.0, 1.0)


func damage_mul() -> float:
	return (1.0 + minf(player.combo, 60.0) * 0.012) \
		* (1.0 + float(prog["up"]["edge"]) * 0.12) \
		* (1.0 + float(boon("dmg")) * 0.14) \
		* (1.0 + float(affix_lv("edge")) * 0.12)



# ---------------------------------------------------------------- 主步进

## 只推进**纯表现层**（目前只有全屏闪光）。
##
## 对白 / 菜单（结算）/ 三选一 / 商店期间世界被冻结（main 在那些 state 下不调 step()），
## 但闪光是给玩家的视觉反馈，不该跟着一起冻住 —— 否则死亡瞬间那一下红闪
## 会一直糊在结算画面上，直到重生才消失。
##
## 这条衰减**不消耗任何 RNG**，在冻结期间调用不会挪动随机流，所以自检的确定性不受影响。
func tick_fx(dt: float) -> void:
	flash_power = maxf(0.0, flash_power - dt * 2.4)


## 固定步长推进。游戏内与自检都走这一条路径。
func step(dt_raw: float) -> void:
	if hitstop > 0.0:
		hitstop -= dt_raw
		dt_raw *= 0.1
	var dt := minf(dt_raw, DT_MAX)
	time += dt

	_update_aim()
	_update_player(dt)
	_update_enemies(dt)
	_update_effects(dt)
	_update_projs(dt)
	_update_drops(dt)
	_update_girl(dt)
	_update_particles(dt)
	_update_waves(dt)
	_update_interaction(dt)
	_update_objective()
	_update_camera(dt)

	# 震屏：偏移量同时给绘制层与光照层，保证影子跟得住画面
	draw_cam = cam
	if shake > 0.0:
		draw_cam += Vector2(_rng.randf_range(-shake, shake), _rng.randf_range(-shake, shake))
	shake = maxf(0.0, shake - dt * 40.0)
	# 闪光的衰减**不在这里** —— 见 tick_fx()：它必须在世界被冻结时也照常推进。

	if light_rig != null:
		light_rig.sync(self)
	queue_redraw()
	# 叠加层是独立的 CanvasItem，它的内容完全由世界状态决定，
	# 不显式标脏它就会一直停在最后一次重绘的画面（表现为"玩家脚下那圈光池
	# 不跟着人走、半径也不变"）。
	if bloom != null:
		bloom.queue_redraw()


func sfx(id: String) -> void:
	Sound.play(id)


func _update_aim() -> void:
	var p := player
	if GameInput.aim_world != null:
		var aw: Vector2 = GameInput.aim_world
		p.facing = atan2(aw.y - p.y, aw.x - p.x)
		return
	if GameInput.aim_mode == "mouse" and GameInput.mouse_seen:
		var wx := GameInput.mouse_pos.x - Proj.VIEW_W * 0.5 + cam.x
		var wy := Proj.screen_to_world_y(GameInput.mouse_pos.y, cam.y)
		p.facing = atan2(wy - p.y, wx - p.x)
	else:
		var a := GameInput.axis()
		if a.length_squared() > 0.0001:
			p.facing = atan2(a.y, a.x)


func _update_camera(dt: float) -> void:
	cam.x = Proj.damp(cam.x, player.x, 7.0, dt)
	cam.y = Proj.damp(cam.y, player.y, 7.0, dt)
	var half_w := Proj.VIEW_W * 0.5
	var half_h := Proj.VIEW_H * 0.5 / Proj.YSQUASH
	var lw := float(level["w"])
	var lh := float(level["h"])
	cam.x = clampf(cam.x, half_w, lw - half_w) if lw > Proj.VIEW_W else lw * 0.5
	cam.y = clampf(cam.y, half_h, lh - half_h) if lh > half_h * 2.0 else lh * 0.5


# ---------------------------------------------------------------- 玩家

func _update_player(dt: float) -> void:
	var p := player
	if p.dead:
		p.death_t += dt
		return

	# 连击衰减：2.6 秒不命中就慢慢暗下来（火种不熄恩赐会拖慢它）
	if p.combo > 0.0:
		p.combo_timer -= dt
		if p.combo_timer <= 0.0:
			p.combo = maxf(0.0, p.combo - dt * combo_decay())
			if p.combo == 0.0:
				p.combo_peak = 0.0

	# 移动
	var a := GameInput.axis()
	var speed := 218.0
	if p.dash_t > 0.0:
		p.dash_t -= dt
		p.vx = p.dash_dx * 640.0
		p.vy = p.dash_dy * 640.0
		if _rng.randf() < dt * 40.0:
			_add_particle(p.x, p.y, _rng.randf_range(6.0, 30.0), {
				"vx": _rng.randf_range(-30.0, 30.0), "vy": _rng.randf_range(-30.0, 30.0),
				"vz": _rng.randf_range(0.0, 30.0), "life": 0.4,
				"size": _rng.randf_range(2.0, 4.5), "color": "#ffd79a", "glow": true,
				"drag": 3.0, "grav": -10.0,
			})
		p.invuln = maxf(p.invuln, 0.05)
	else:
		p.vx = Proj.damp(p.vx, a.x * speed, 22.0, dt)
		p.vy = Proj.damp(p.vy, a.y * speed, 22.0, dt)

	if p.dash_cd > 0.0:
		p.dash_cd -= dt
	if GameInput.just("dash") and p.dash_cd <= 0.0 and p.dash_t <= 0.0:
		var d := a if a.length_squared() > 0.0001 else Vector2(cos(p.facing), sin(p.facing))
		p.dash_dx = d.x
		p.dash_dy = d.y
		p.dash_t = 0.17
		p.dash_cd = 1.0 * pow(0.7, float(boon("dash")))
		sfx("dash")
		for i in 12:
			_add_particle(p.x, p.y, _rng.randf_range(4.0, 34.0), {
				"vx": -d.x * _rng.randf_range(40.0, 140.0) + _rng.randf_range(-40.0, 40.0),
				"vy": -d.y * _rng.randf_range(40.0, 140.0) + _rng.randf_range(-40.0, 40.0),
				"vz": _rng.randf_range(0.0, 40.0), "life": _rng.randf_range(0.3, 0.6),
				"size": _rng.randf_range(1.6, 3.6), "color": "#ffe0a8", "glow": true,
				"drag": 2.5, "grav": -14.0,
			})

	var np := collide_wall(Vector2(p.x + p.vx * dt, p.y + p.vy * dt), p.r)
	p.x = np.x
	p.y = np.y
	if absf(p.vx) + absf(p.vy) > 30.0:
		p.walk_t += dt * 11.0

	# 计时器
	if p.attack_cd > 0.0:
		p.attack_cd -= dt
	if p.attack_t > 0.0:
		p.attack_t -= dt
	if p.invuln > 0.0:
		p.invuln -= dt
	if p.hurt_flash > 0.0:
		p.hurt_flash -= dt
	if p.shield_t > 0.0:
		p.shield_t -= dt
	if p.lifesteal_t > 0.0:
		p.lifesteal_t -= dt
		if p.lifesteal_t <= 0.0:
			p.lifesteal_pct = 0.0
	for k in p.skill_cd.keys():
		if p.skill_cd[k] > 0.0:
			p.skill_cd[k] -= dt

	# 连灯刺：连刺序列
	if p.flurry > 0:
		p.flurry_t -= dt
		if p.flurry_t <= 0.0:
			p.flurry -= 1
			p.flurry_t = 0.11
			player_swing(0.72, 1.5, 0.9)
			sfx("slash")

	# 普通攻击
	if GameInput.just("attack") and p.attack_cd <= 0.0 and p.flurry <= 0:
		p.attack_cd = float(player.weapon()["cd"]) * attack_cd_mul()
		p.attack_t = 0.2
		p.attack_alt = not p.attack_alt
		player_swing(float(player.weapon()["arc"]), 1.0, 1.0)
		sfx("slash")

	# 技能 1/2/3
	for i in 3:
		if GameInput.just("skill" + str(i + 1)):
			use_skill(i)

	# 背包：X 换手 / C 喝灯油（都不吃 RNG，放哪都确定）
	if GameInput.just("swap_weapon"):
		swap_weapon()
	if GameInput.just("use_potion"):
		use_potion()

	# 交互
	if GameInput.just("interact"):
		interact()


## 一次挥击判定：扇形（距离 + 角度），40 距离内不看角度（贴脸必中）。
## 灯弩（style == "shot"）不是刀弧，改为射出一支光矢。
func player_swing(arc_mul: float, dmg_mul_v: float, range_mul: float) -> void:
	var p := player
	var w := player.weapon()
	var rng_r := float(w["range"]) * range_mul * reach_mul()
	var arc := float(w["arc"]) * arc_mul
	var col := str(w.get("color", "#ffd070"))
	var hits := 0

	if str(w.get("style", "slash")) == "shot":
		# 远程：射一支光矢，飞完 w.range 就消失
		var sp := 900.0
		_add_proj({
			"x": p.x, "y": p.y, "z": 26.0,
			"vx": cos(p.facing) * sp, "vy": sin(p.facing) * sp,
			"r": 13.0, "dmg": float(w["dmg"]) * dmg_mul_v, "life": rng_r / sp,
			"color": col, "own": "player", "knock": float(w["knock"]),
		})
		effects.append({
			"id": _next_id, "kind": "muzzle", "x": p.x + cos(p.facing) * 22.0,
			"y": p.y + sin(p.facing) * 22.0, "z": 26.0, "angle": p.facing,
			"r0": 6.0, "r1": 26.0, "len": 0.0, "w": 0.0,
			"life": 0.12, "max_life": 0.12, "dmg": 0.0, "knock": 0.0, "stun": 0.0,
			"color": col, "hit": {}, "own": "player", "delay": 0.0,
		})
		_next_id += 1
		player.glow = minf(1.0, player.glow + 0.10)
		return

	for e in enemies:
		if e.dead:
			continue
		var d := Proj.dist(p.x, p.y, e.x, e.y)
		if d > rng_r + e.r:
			continue
		var ang := Proj.angle_to(p.x, p.y, e.x, e.y)
		if absf(Proj.angle_diff(p.facing, ang)) > arc * 0.5 and d > 40.0:
			continue
		damage_enemy(e, float(w["dmg"]) * dmg_mul_v, ang, float(w["knock"]))
		hits += 1

	effects.append({
		"id": _next_id, "kind": "slash", "x": p.x, "y": p.y, "z": 24.0,
		"angle": p.facing, "r0": rng_r * 0.35, "r1": rng_r, "len": 0.0, "w": arc,
		"life": 0.17, "max_life": 0.17, "dmg": 0.0, "knock": 0.0, "stun": 0.0,
		"color": col, "hit": {}, "own": "player", "delay": 0.0,
	})
	_next_id += 1

	if hits > 0:
		shake = minf(shake + float(hits) * 1.1, 9.0)
		player.glow = minf(1.0, player.glow + 0.22)
	try_light_brazier(player.x, player.y, rng_r + 26.0)



func use_skill(index: int) -> void:
	var p := player
	var skills: Array = p.skills()
	if index >= skills.size():
		events.append({"type": "toast", "text": "这把武器没有第 %d 个技能。" % (index + 1)})
		return
	var sk: Dictionary = skills[index]
	var sid := str(sk["id"])
	if float(p.skill_cd.get(sid, 0.0)) > 0.0:
		return
	var cost := float(skill_cost(int(sk["cost"])))
	if p.combo < cost:
		events.append({"type": "toast", "text": "【%s】需要 %d 连击（当前 %d）" % [sk["name"], int(cost), p.combo_int()]})
		sfx("ui")
		return
	# 技能消耗连击——灯是有代价的
	p.combo -= cost
	p.skill_cd[sid] = float(sk["cd"]) * skill_cd_mul()
	cast_skill(sid)
	sfx("skill")
	shake = minf(shake + 5.0, 14.0)
	flash_color = Color.html("#ffd9a0")
	flash_power = 0.34
	p.glow = 1.0


func cast_skill(id: String) -> void:
	var p := player
	var w := player.weapon()
	var dm := damage_mul()
	var col := str(w.get("color", "#ffd070"))

	match id:
		# ============================================================ 灯刃
		"blade_whirl":
			_push_effect({
				"kind": "ring", "r0": 26.0, "r1": 132.0, "life": 0.32,
				"dmg": float(w["dmg"]) * 1.5 * dm, "knock": 300.0, "color": col,
			})
			_ring_particles(p.x, p.y, 26, col)

		"blade_burst":
			_push_effect({
				"kind": "burst", "r0": 40.0, "r1": 320.0, "life": 0.5,
				"dmg": float(w["dmg"]) * 2.1 * dm, "knock": 900.0, "color": "#fff2cc",
			})
			_push_effect({"kind": "ring", "r0": 40.0, "r1": 340.0, "life": 0.6, "dmg": 0.0, "color": col})
			shake = minf(shake + 10.0, 18.0)
			_light_near_braziers(300.0)

		# ============================================================ 双灯刃
		"twin_flurry":
			# 疾冲，沿途留下四段斩击；斩击点跟着冲刺方向铺开
			p.dash_dx = cos(p.facing)
			p.dash_dy = sin(p.facing)
			p.dash_t = 0.22
			p.dash_cd = maxf(p.dash_cd, 0.25)
			p.invuln = 0.26
			for i in 4:
				var ft := float(i) / 3.0
				_push_effect({
					"kind": "slash",
					"x": p.x + cos(p.facing) * 78.0 * ft,
					"y": p.y + sin(p.facing) * 78.0 * ft,
					"angle": p.facing,
					"r0": 22.0, "r1": float(w["range"]) * 1.1, "w": float(w["arc"]) * 1.35,
					"life": 0.20 + ft * 0.10,
					"dmg": float(w["dmg"]) * 1.05 * dm, "knock": 130.0, "color": col,
				})

		"twin_ring":
			# 两道反向环：一近一远，各自结算
			_push_effect({
				"kind": "ring", "r0": 20.0, "r1": 130.0, "life": 0.42,
				"dmg": float(w["dmg"]) * 1.35 * dm, "knock": 280.0, "color": col,
			})
			_push_effect({
				"kind": "ring", "r0": 236.0, "r1": 36.0, "life": 0.54,
				"dmg": float(w["dmg"]) * 1.35 * dm, "knock": 280.0, "color": "#fff0c8",
			})
			_ring_particles(p.x, p.y, 20, col)

		# ============================================================ 长明枪
		"spear_lunge":
			p.dash_dx = cos(p.facing)
			p.dash_dy = sin(p.facing)
			p.dash_t = 0.26
			p.dash_cd = maxf(p.dash_cd, 0.3)
			p.invuln = 0.3
			for i in 5:
				var t := float(i) / 4.0
				_push_effect({
					"kind": "pillar", "x": p.x + cos(p.facing) * 70.0 * t,
					"y": p.y + sin(p.facing) * 70.0 * t, "r0": 8.0, "r1": 46.0, "life": 0.26,
					"dmg": float(w["dmg"]) * 1.15 * dm, "knock": 240.0, "color": col,
				})

		"spear_flurry":
			p.flurry = 5
			p.flurry_t = 0.02

		"spear_pierce":
			# 贯穿：pierce 表示最多能穿过几个敌人
			_add_proj({
				"x": p.x, "y": p.y, "z": 26.0,
				"vx": cos(p.facing) * 900.0, "vy": sin(p.facing) * 900.0,
				"r": 26.0, "dmg": float(w["dmg"]) * 2.6 * dm, "life": 0.9,
				"color": "#fff0c8", "own": "player", "pierce": 6, "hit": {},
			})

		# ============================================================ 锁灯
		"chain_hook":
			# 抛链：命中后把敌人拽到面前并震晕
			_push_effect({
				"kind": "pull", "r0": 26.0, "r1": 208.0, "life": 0.34,
				"dmg": float(w["dmg"]) * 1.20 * dm, "knock": 0.0, "stun": 0.0,
				"pull": 760.0, "pull_stun": 0.6, "color": col,
			})
			_push_effect({"kind": "ring", "r0": 208.0, "r1": 26.0, "life": 0.34,
				"dmg": 0.0, "color": "#ffe3a8"})
			shake = minf(shake + 4.0, 14.0)

		"chain_spin":
			# 三段，一段比一段宽
			for i in 3:
				_push_effect({
					"kind": "ring", "r0": 22.0, "r1": 108.0 + float(i) * 52.0,
					"life": 0.30 + float(i) * 0.13, "delay": float(i) * 0.13,
					"dmg": float(w["dmg"]) * 0.95 * dm, "knock": 300.0, "color": col,
				})
			_ring_particles(p.x, p.y, 30, "#ffe3a8")

		# ============================================================ 烬锤
		"hammer_quake":
			_push_effect({
				"kind": "burst", "r0": 30.0, "r1": 250.0, "life": 0.55,
				"dmg": float(w["dmg"]) * 1.8 * dm, "knock": 700.0, "stun": 0.35, "color": col,
			})
			_push_effect({"kind": "ring", "r0": 30.0, "r1": 300.0, "life": 0.7, "dmg": 0.0, "color": "#ffbb70"})
			shake = minf(shake + 9.0, 18.0)
			_light_near_braziers(260.0)

		# ============================================================ 灯镰
		"scythe_reap":
			# 范围内敌人越多，这一刀越重（收割）
			var caught := 0
			for e2 in enemies:
				if not e2.dead and Proj.dist(p.x, p.y, e2.x, e2.y) < 200.0:
					caught += 1
			var mul := 1.0 + 0.25 * float(caught)
			_push_effect({
				"kind": "ring", "r0": 30.0, "r1": 194.0, "life": 0.38,
				"dmg": float(w["dmg"]) * 1.35 * dm * mul, "knock": 300.0, "color": col,
			})
			if caught > 0:
				events.append({"type": "toast", "text": "回旋 · 收割 %d 个目标" % caught})
			_ring_particles(p.x, p.y, 22, col)

		"scythe_devour":
			p.lifesteal_t = 8.0
			p.lifesteal_pct = 0.35
			for i in 24:
				var a := _rng.randf() * TAU
				_add_particle(p.x, p.y, _rng.randf_range(8.0, 42.0), {
					"vx": -cos(a) * _rng.randf_range(60.0, 200.0), "vy": -sin(a) * _rng.randf_range(60.0, 200.0),
					"vz": _rng.randf_range(0.0, 50.0), "life": _rng.randf_range(0.3, 0.7),
					"size": _rng.randf_range(2.0, 4.2), "color": "#a8e6b0", "glow": true,
					"drag": 2.4, "grav": -30.0,
				})
			events.append({"type": "toast", "text": "噬影：8 秒内伤害的 35% 化为生命"})

		"scythe_crescent":
			for i in 3:
				var fi := float(i)
				_push_effect({
					"kind": "slash",
					"x": p.x + cos(p.facing) * (40.0 + 74.0 * fi),
					"y": p.y + sin(p.facing) * (40.0 + 74.0 * fi),
					"angle": p.facing,
					"r0": 30.0, "r1": float(w["range"]) * (0.85 + 0.25 * fi),
					"w": float(w["arc"]) * 0.9,
					"life": 0.30 + 0.10 * fi,
					"dmg": float(w["dmg"]) * (0.90 + 0.35 * fi) * dm, "knock": 230.0, "color": col,
				})

		# ============================================================ 灯弩
		"bow_volley":
			for off in [-0.17, 0.0, 0.17]:
				var aa: float = p.facing + float(off)
				_add_proj({
					"x": p.x, "y": p.y, "z": 26.0,
					"vx": cos(aa) * 900.0, "vy": sin(aa) * 900.0,
					"r": 12.0, "dmg": float(w["dmg"]) * 0.95 * dm, "life": 0.46,
					"color": col, "own": "player", "knock": float(w["knock"]),
				})

		"bow_pierce":
			_add_proj({
				"x": p.x, "y": p.y, "z": 26.0,
				"vx": cos(p.facing) * 1150.0, "vy": sin(p.facing) * 1150.0,
				"r": 17.0, "dmg": float(w["dmg"]) * 2.2 * dm, "life": 1.0,
				"color": "#ffffff", "own": "player", "pierce": 8, "hit": {},
				"knock": 340.0,
			})

		"bow_rain":
			# 在周围撒一片延迟落下的光矢雨（每个点是一个带 delay 的 burst）
			for i in 10:
				var a2 := _rng.randf() * TAU
				var dd := _rng.randf_range(60.0, 250.0)
				var qx := clampf(p.x + cos(a2) * dd, 40.0, float(level["w"]) - 40.0)
				var qy := clampf(p.y + sin(a2) * dd, 40.0, float(level["h"]) - 40.0)
				_push_effect({
					"kind": "burst", "x": qx, "y": qy, "z": 18.0,
					"r0": 14.0, "r1": 62.0, "life": 0.30,
					"delay": _rng.randf_range(0.25, 0.75),
					"dmg": float(w["dmg"]) * 0.70 * dm, "knock": 120.0, "color": col,
				})

		# ============================================================ 灯杖
		"staff_orb":
			# 滞空光球：留在原地，按 tick 反复灼烧（持续区域）
			var ox := clampf(p.x + cos(p.facing) * 80.0, 40.0, float(level["w"]) - 40.0)
			var oy := clampf(p.y + sin(p.facing) * 80.0, 40.0, float(level["h"]) - 40.0)
			_push_effect({
				"kind": "zone", "x": ox, "y": oy, "z": 46.0, "angle": 0.0,
				"r0": 62.0, "r1": 62.0, "life": 6.0,
				"dmg": float(w["dmg"]) * 0.30 * dm, "knock": 40.0,
				"tick": 0.35, "color": col,
			})
			events.append({"type": "toast", "text": "灯球留在原地，持续灼烧 6 秒"})

		"staff_ward":
			p.shield_t = 4.0
			_push_effect({"kind": "ring", "r0": 26.0, "r1": 96.0, "life": 0.4, "dmg": 0.0, "color": col})
			_push_effect({"kind": "ring", "r0": 96.0, "r1": 30.0, "life": 0.5, "dmg": 0.0, "color": "#ffffff"})
			shake = minf(shake + 3.0, 12.0)
			events.append({"type": "toast", "text": "护光：4 秒内免疫伤害"})

		"staff_meteor":
			# 陨光：落点先亮一下，再砸下来（delay 给敌人跑的机会）
			var mx := p.x + cos(p.facing) * 300.0
			var my := p.y + sin(p.facing) * 300.0
			mx = clampf(mx, 60.0, float(level["w"]) - 60.0)
			my = clampf(my, 60.0, float(level["h"]) - 60.0)
			_push_effect({
				"kind": "burst", "x": mx, "y": my, "z": 20.0,
				"r0": 26.0, "r1": 200.0, "life": 0.45,
				"delay": 0.55,
				"dmg": float(w["dmg"]) * 2.4 * dm, "knock": 560.0, "stun": 0.5, "color": col,
			})
			_push_effect({"kind": "ring", "x": mx, "y": my, "z": 20.0,
				"r0": 200.0, "r1": 40.0, "life": 0.45, "delay": 0.55, "dmg": 0.0, "color": "#ffffff"})
			shake = minf(shake + 11.0, 18.0)


## 环形特效配的粒子（各技能共用的"手感"）
func _ring_particles(x: float, y: float, n: int, color: String) -> void:
	for i in n:
		var a := _rng.randf() * TAU
		_add_particle(x, y, _rng.randf_range(10.0, 40.0), {
			"vx": cos(a) * _rng.randf_range(160.0, 420.0),
			"vy": sin(a) * _rng.randf_range(160.0, 420.0),
			"vz": _rng.randf_range(0.0, 60.0), "life": _rng.randf_range(0.25, 0.5),
			"size": _rng.randf_range(2.0, 4.0), "color": color, "glow": true,
			"drag": 3.0, "grav": -20.0,
		})


## 点亮玩家附近还没亮的火盆（灯爆 / 撼地）
func _light_near_braziers(radius: float) -> void:
	for b in braziers:
		if not bool(b["lit"]) and Proj.dist(player.x, player.y, float(b["x"]), float(b["y"])) < radius:
			light_brazier(b)


func _push_effect(over: Dictionary) -> void:
	var p := player
	var base := {
		"id": _next_id, "kind": "ring", "x": p.x, "y": p.y, "z": 22.0, "angle": p.facing,
		"r0": 0.0, "r1": 100.0, "len": 0.0, "w": 0.0, "life": 0.4, "max_life": 0.4,
		"dmg": 0.0, "knock": 0.0, "stun": 0.0, "color": "#ffd070",
		"hit": {}, "own": "player", "delay": 0.0,
	}
	for k in over.keys():
		base[k] = over[k]
	base["max_life"] = base["life"]
	_next_id += 1
	effects.append(base)


# ---------------------------------------------------------------- 敌人

func spawn_enemy(type_id: String, x: float, y: float, is_elite := false, affix := "") -> EnemyState:
	if not Content.ENEMIES.has(type_id):
		return null
	var def: Dictionary = Content.ENEMIES[type_id]
	var scale := float(level["enemy_scale"])
	if is_elite:
		def = Content.eliteify(def)
		# 精英词缀：不指定就按种子从词缀表里抽一个（同一局确定，不同局不同）
		var af := affix
		if af == "":
			var keys := Content.ELITE_AFFIXES.keys()
			af = str(keys[_rng.randi_range(0, keys.size() - 1)])
		def = Content.apply_affix(def, af, _rng)
	def = def.duplicate(true)
	if not is_elite:
		def["hp"] = float(def["hp"]) * scale
		def["dmg"] = float(def["dmg"]) * scale
	var e := EnemyState.create(def, x, y, _next_id, is_elite)
	_next_id += 1
	enemies.append(e)
	return e


## 在圆内找一个不被墙挡住的位置
func find_spawn_point(cx: float, cy: float, radius: float, r: float) -> Vector2:
	for i in 40:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * radius
		var x := cx + cos(a) * d
		var y := cy + sin(a) * d
		if not blocked(x, y, r + 4.0):
			return Vector2(x, y)
	return Vector2(cx, cy)


func _update_enemies(dt: float) -> void:
	var p := player
	for e in enemies:
		if e.dead:
			e.death_t += dt
			continue
		# 受击闪白
		if e.hit_flash > 0.0:
			e.hit_flash -= dt
		# 词缀「障」：格挡冷却
		if e.ward_cd > 0.0 and e.ward_t > 0.0:
			e.ward_t -= dt
		# 火盆未点满时 Boss 被「护佑」：除了减伤还缓慢自愈（照抄 Web 版）
		if e.is_boss() and boss_warded():
			e.hp = minf(e.max_hp, e.hp + e.max_hp * 0.006 * dt)

		# 出场硬直：这段时间只挨打，不动也不出手
		if e.state == "spawn":
			e.spawn_t -= dt
			e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
			e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
			if e.spawn_t <= 0.0:
				e.state = "chase"
			continue
		# 眩晕：跳过思考，只做位移
		if e.stun > 0.0:
			e.stun -= dt
			_move_entity(e, dt)
			continue
		if e.atk_cd > 0.0:
			e.atk_cd -= dt

		# 灯杖·护光：护盾把贴到身上的敌人推开
		if p.shield_t > 0.0 and not p.dead:
			var sd := Proj.dist(e.x, e.y, p.x, p.y)
			if sd < e.r + p.r + 40.0 and sd > 0.01:
				var sa := Proj.angle_to(p.x, p.y, e.x, e.y)
				var push_f := (1.0 - sd / (e.r + p.r + 40.0)) * 720.0
				e.vx += cos(sa) * push_f * dt
				e.vy += sin(sa) * push_f * dt

		if e.is_boss():
			_boss_ai(e, dt)
		else:
			_basic_ai(e, dt)

		# 分离，避免叠成一团（与 Web 版 updateEnemies 的互推一致）
		for o in enemies:
			if o == e or o.dead:
				continue
			var dd := Proj.dist(e.x, e.y, o.x, o.y)
			var mn := e.r + o.r
			if dd < mn and dd > 0.01:
				var push := (mn - dd) * 0.5
				var ax2 := (e.x - o.x) / dd
				var ay2 := (e.y - o.y) / dd
				e.vx += ax2 * push * 14.0
				e.vy += ay2 * push * 14.0
				o.vx -= ax2 * push * 10.0
				o.vy -= ay2 * push * 10.0

		_move_entity(e, dt)

		# 接触伤害（贴身擦到）—— Boss 靠这一条才有"挨近就掉血"的压迫感
		if e.is_boss() and Proj.dist(e.x, e.y, p.x, p.y) < e.r + p.r + 6.0:
			hurt_player(float(e.def["dmg"]) * 0.35 * dt * 10.0,
				Proj.angle_to(e.x, e.y, p.x, p.y))


## 位移 + 撞墙反弹（Boss 冲撞撞墙会眩晕）。与 Web 版 moveEntity 一一对应。
func _move_entity(e: EnemyState, dt: float) -> void:
	var want := Vector2(e.x + e.vx * dt, e.y + e.vy * dt)
	var np := collide_wall(want, e.r)
	if absf(np.x - want.x) > 0.5 and absf(np.x - want.x) < e.r * 2.0:
		e.vx *= -0.2
		if e.is_boss() and str(e.boss.get("action", "")) == "dash":
			e.stun = 1.1
			e.boss["action"] = ""
			e.boss["cool"] = 1.4
			shake = 10.0
	if absf(np.y - want.y) > 0.5 and absf(np.y - want.y) < e.r * 2.0:
		e.vy *= -0.2
	e.x = np.x
	e.y = np.y
	# 恒定摩擦：这是 Web 版敌人速度的真实来源（阻尼后约为标称速度的 0.69 倍）
	e.vx = Proj.damp(e.vx, 0.0, 2.6, dt)
	e.vy = Proj.damp(e.vy, 0.0, 2.6, dt)
	if absf(e.vx) + absf(e.vy) < 4.0:
		e.vx = 0.0
		e.vy = 0.0


func _basic_ai(e: EnemyState, dt: float) -> void:
	var p := player
	var behavior := str(e.def["behavior"])
	var d := Proj.dist(e.x, e.y, p.x, p.y)
	var aggro := float(e.def["aggro"])
	var atk_range := float(e.def["atk_range"])
	var wind := float(e.def["wind"])
	var to_player := Proj.angle_to(e.x, e.y, p.x, p.y)
	e.facing = 1.0 if cos(to_player) >= 0.0 else -1.0

	if e.state == "chase":
		if p.dead:
			e.vx = Proj.damp(e.vx, 0.0, 6.0, dt)
			e.vy = Proj.damp(e.vy, 0.0, 6.0, dt)
			return
		e.t += dt
		if behavior == "spitter":
			if d < aggro and e.atk_cd <= 0.0 and d < atk_range and e.t > 0.4:
				e.state = "windup"
				e.t = 0.0
			elif d < aggro:
				# 保持距离：太近后退，太远靠近，同时侧移游走
				var spd := float(e.def["speed"])
				var want := -1.0 if d < 210.0 else 1.0
				e.vx = cos(to_player) * spd * want
				e.vy = sin(to_player) * spd * want
				e.vx += cos(to_player + PI * 0.5) * spd * 0.5 * sin(e.t * 1.6 + e.wob)
				e.vy += sin(to_player + PI * 0.5) * spd * 0.5 * sin(e.t * 1.6 + e.wob)
			else:
				e.vx = Proj.damp(e.vx, 0.0, 5.0, dt)
				e.vy = Proj.damp(e.vy, 0.0, 5.0, dt)
			return
		if d < aggro:
			var spd := float(e.def["speed"]) * (1.0 if behavior == "guard" else 1.15)
			var v := Vector2(p.x - e.x, p.y - e.y)
			if v.length_squared() > 0.0001:
				v = v.normalized()
			e.vx = Proj.damp(e.vx, v.x * spd, 6.0, dt)
			e.vy = Proj.damp(e.vy, v.y * spd, 6.0, dt)
		else:
			e.vx = Proj.damp(e.vx, 0.0, 4.0, dt)
			e.vy = Proj.damp(e.vy, 0.0, 4.0, dt)
			if _rng.randf() < dt * 0.6:
				var a2 := _rng.randf() * TAU
				e.vx += cos(a2) * 34.0
				e.vy += sin(a2) * 34.0
		if d < atk_range + p.r - 6.0 and e.atk_cd <= 0.0 and e.t > 0.5 and not p.dead:
			e.state = "windup"
			e.t = 0.0
	elif e.state == "windup":
		e.vx = Proj.damp(e.vx, 0.0, 10.0, dt)
		e.vy = Proj.damp(e.vy, 0.0, 10.0, dt)
		e.t += dt
		if e.t >= wind:
			e.state = "attack"
			e.t = 0.0
			if behavior == "spitter":
				# 远程：吐一枚灯蛭弹后就回到追猎
				e.state = "chase"
				e.atk_cd = float(e.def["atk_cd"])
				_add_proj({
					"x": e.x, "y": e.y, "z": e.h * 0.5,
					"vx": cos(to_player) * 330.0, "vy": sin(to_player) * 330.0,
					"r": 11.0, "dmg": float(e.def["dmg"]), "life": 2.6,
					"color": str(e.def["glow"]), "own": "enemy",
				})
				sfx("skill")
			else:
				# 近战：一记前冲，伤害在前冲当帧结算（照抄 Web 版 windup 分支）
				var lunge := 240.0 if behavior == "guard" else 150.0
				e.vx = cos(to_player) * lunge
				e.vy = sin(to_player) * lunge
				if Proj.dist(e.x, e.y, p.x, p.y) < atk_range + p.r + 14.0:
					hurt_player(float(e.def["dmg"]), to_player, e.drain)
				e.atk_cd = float(e.def["atk_cd"])
				effects.append({
					"id": _next_id, "kind": "slash", "x": e.x, "y": e.y, "z": 24.0,
					"angle": to_player, "r0": 12.0, "r1": atk_range + 18.0, "len": 0.0, "w": 1.5,
					"life": 0.18, "max_life": 0.18, "dmg": 0.0, "knock": 0.0, "stun": 0.0,
					"color": "#ff8f6a", "hit": {}, "own": "enemy", "delay": 0.0,
				})
				_next_id += 1
				sfx("slash")
	elif e.state == "attack":
		e.t += dt
		if e.t > 0.25:
			e.atk_done = false
			e.state = "chase"


## Boss 三阶段 AI：dash / slam / summon / drain / sweep（照 Web 版移植）
func _boss_ai(e: EnemyState, dt: float) -> void:
	var p := player
	var bs: Dictionary = e.boss
	var hp01 := e.hp01()
	if hp01 < 0.33:
		bs["phase"] = 3
	elif hp01 < 0.66:
		bs["phase"] = 2
	else:
		bs["phase"] = 1
	var phase := int(bs["phase"])

	if str(bs["action"]) == "":
		bs["cool"] = float(bs["cool"]) - dt
		if float(bs["cool"]) <= 0.0:
			var pool := []
			if phase == 1:
				pool = ["dash", "dash", "slam", "summon"]
			elif phase == 2:
				pool = ["slam", "drain", "summon", "dash"]
			else:
				pool = ["drain", "sweep", "summon", "dash", "slam"]
			var act: String = pool[_rng.randi_range(0, pool.size() - 1)]
			bs["action"] = act
			bs["timer"] = 0.0
			bs["slam_armed"] = false
			if act == "dash":
				bs["tx"] = p.x
				bs["ty"] = p.y
			if act == "drain":
				events.append({"type": "toast", "text": "噬灯者开始吞噬你的光！"})
			if act == "sweep":
				events.append({"type": "toast", "text": "灯影横扫——躲开！"})
		return

	bs["timer"] = float(bs["timer"]) + dt
	var tm := float(bs["timer"])
	var action := str(bs["action"])
	var d := Proj.dist(e.x, e.y, p.x, p.y)
	var wind := 0.5

	match action:
		"dash":
			if tm < wind:
				e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
				e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
				e.facing = 1.0 if cos(Proj.angle_to(e.x, e.y, p.x, p.y)) >= 0.0 else -1.0
			else:
				var a := Proj.angle_to(e.x, e.y, float(bs["tx"]), float(bs["ty"]))
				e.vx = cos(a) * 640.0
				e.vy = sin(a) * 640.0
				if tm > wind + 0.5:
					bs["action"] = ""
					bs["cool"] = _rng.randf_range(0.7, 1.4)
		"slam":
			if tm < 0.7:
				e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
				e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
			elif not bool(bs["slam_armed"]):
				bs["slam_armed"] = true
				shake = 20.0
				flash_color = Color.html("#ff7a4a")
				flash_power = 0.4
				for i in 2:
					effects.append({
						"id": _next_id, "kind": "ring", "x": e.x, "y": e.y, "z": 10.0,
						"angle": 0.0, "r0": 30.0, "r1": 240.0 + float(i) * 70.0, "len": 0.0, "w": 0.0,
						"life": 0.42 + float(i) * 0.12, "max_life": 0.42 + float(i) * 0.12,
						"dmg": float(e.def["dmg"]) * 1.5, "knock": 700.0, "stun": 0.3,
						"color": "#ff8a5a", "hit": {}, "own": "enemy", "delay": 0.0,
					})
					_next_id += 1
				for i in 30:
					var a2 := _rng.randf() * TAU
					_add_particle(e.x, e.y, _rng.randf_range(6.0, 30.0), {
						"vx": cos(a2) * _rng.randf_range(120.0, 520.0),
						"vy": sin(a2) * _rng.randf_range(120.0, 520.0),
						"vz": _rng.randf_range(40.0, 220.0), "life": _rng.randf_range(0.4, 0.9),
						"size": _rng.randf_range(2.5, 6.0), "color": "#ff9b5c", "glow": true,
						"drag": 2.0, "grav": 120.0,
					})
				sfx("roar")
				bs["action"] = ""
				bs["cool"] = _rng.randf_range(0.9, 1.6)
		"summon":
			if tm < 0.6:
				if _rng.randf() < dt * 6.0:
					_spawn_fx(e.x + _rng.randf_range(-60.0, 60.0), e.y + _rng.randf_range(-40.0, 60.0), str(e.def["glow"]))
			else:
				var minions := 0
				for m in enemies:
					if not m.dead and not m.is_boss():
						minions += 1
				var want := 4 if phase >= 3 else 3
				var room := int(maxf(0.0, float(8 - minions)))
				var n := mini(want, room)
				for i in n:
					var pt := find_spawn_point(e.x, e.y, 160.0, 18.0)
					spawn_enemy("shade", pt.x, pt.y)
					_spawn_fx(pt.x, pt.y, "#b7a8ff")
				events.append({"type": "toast", "text": "它吐出了新的影子。" if n > 0 else "黑暗已经挤不出新的影子了。"})
				bs["action"] = ""
				bs["cool"] = _rng.randf_range(1.6, 2.4)
		"drain":
			var a3 := Proj.angle_to(e.x, e.y, p.x, p.y)
			e.facing = 1.0 if cos(a3) >= 0.0 else -1.0
			if tm < 0.6:
				e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
				e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
			elif tm < 2.0:
				e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
				e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
				var in_beam := absf(Proj.angle_diff(a3, Proj.angle_to(e.x, e.y, p.x, p.y))) < 0.42
				if in_beam and d < 620.0:
					var steal := minf(p.combo, 26.0 * dt)
					p.combo -= steal
					e.hp = minf(e.max_hp, e.hp + steal * 6.0)
					if _rng.randf() < dt * 20.0:
						var tt := _rng.randf_range(0.2, 1.0)
						_add_particle(e.x + cos(a3) * 620.0 * (1.0 - tt), e.y + sin(a3) * 620.0 * (1.0 - tt),
							_rng.randf_range(10.0, 50.0), {
								"vx": -cos(a3) * 120.0, "vy": -sin(a3) * 120.0, "vz": 0.0,
								"life": 0.4, "size": _rng.randf_range(1.5, 3.0),
								"color": "#ffd79a", "glow": true, "drag": 0.0, "grav": 0.0,
							})
					if _rng.randf() < dt * 2.0:
						hurt_player(6.0, a3)
				effects.append({
					"id": _next_id, "kind": "beam", "x": e.x, "y": e.y, "z": 38.0, "angle": a3,
					"len": 640.0, "w": 34.0, "r0": 0.0, "r1": 640.0, "life": 0.08, "max_life": 0.08,
					"dmg": 0.0, "knock": 0.0, "stun": 0.0, "color": "#ff6a4a",
					"hit": {}, "own": "enemy", "delay": 0.0,
				})
				_next_id += 1
			else:
				bs["action"] = ""
				bs["cool"] = _rng.randf_range(0.8, 1.5)
		"sweep":
			e.vx = Proj.damp(e.vx, 0.0, 8.0, dt)
			e.vy = Proj.damp(e.vy, 0.0, 8.0, dt)
			if tm >= 0.6 and tm < 2.1:
				bs["sweep_a"] = float(bs["sweep_a"]) + dt * (3.1 if phase >= 3 else 2.3)
				for off in [0.0, PI]:
					var aa: float = float(bs["sweep_a"]) + float(off)
					var rel := Proj.angle_to(e.x, e.y, p.x, p.y)
					if absf(Proj.angle_diff(aa, rel)) < 0.3 and d < 700.0:
						hurt_player(14.0 * dt * 10.0, rel)
					effects.append({
						"id": _next_id, "kind": "beam", "x": e.x, "y": e.y, "z": 30.0, "angle": aa,
						"len": 700.0, "w": 26.0, "r0": 0.0, "r1": 700.0, "life": 0.06, "max_life": 0.06,
						"dmg": 0.0, "knock": 0.0, "stun": 0.0, "color": "#c9a6ff",
						"hit": {}, "own": "enemy", "delay": 0.0,
					})
					_next_id += 1
			elif tm >= 2.1:
				bs["action"] = ""
				bs["cool"] = _rng.randf_range(0.9, 1.5)


# ---------------------------------------------------------------- 伤害

func damage_enemy(e: EnemyState, dmg: float, dir: float, knock: float, stun := 0.0) -> void:
	if e.dead:
		return
	# 词缀「障」：每 ward_cd 秒挡住一次伤害
	if e.ward_cd > 0.0 and e.ward_t <= 0.0:
		e.ward_t = e.ward_cd
		e.hit_flash = 0.12
		_add_text(e.x, e.y, e.h * 0.9, "格挡", "#ffe08a", 14.0)
		sfx("ui")
		return
	var crit := _rng.randf() < minf(0.85, 0.16 + crit_chance())
	var final := dmg * (1.85 if crit else 1.0)
	# 词缀「韧」：减伤
	final *= (1.0 - clampf(e.dr, 0.0, 0.9))
	if e.is_boss() and boss_warded():
		final *= float(level.get("boss_ward", 0.16))
	e.hp -= final
	e.hit_flash = 0.12

	var p := player
	if p.combo < 99.0:
		p.combo = minf(99.0, p.combo + 1.0 + combo_bonus())
	p.combo_timer = 2.6
	p.combo_peak = maxf(p.combo_peak, p.combo)
	prog["max_combo"] = int(maxf(float(prog["max_combo"]), floor(p.combo)))
	p.glow = minf(1.0, p.glow + (0.4 if crit else 0.2))
	p.hits_dealt += 1

	# 灯镰·噬影：把这段时间造成的伤害吸一部分回来
	if p.lifesteal_t > 0.0 and p.lifesteal_pct > 0.0 and not p.dead:
		var healed := final * p.lifesteal_pct
		if healed >= 1.0:
			p.hp = minf(p.max_hp, p.hp + healed)
			_add_text(p.x, p.y, 56.0, "+" + str(int(round(healed))), "#a8e6b0", 13.0)

	# 击退：重量越大越抗
	var wt := 1.0 - float(e.def.get("weight", 0.3))
	var kb := knock * clampf(wt, 0.05, 1.0) / (5.0 if e.is_boss() else 1.0)
	e.vx += cos(dir) * kb
	e.vy += sin(dir) * kb
	if stun > 0.0:
		e.stun = maxf(e.stun, stun)

	hitstop = maxf(hitstop, HITSTOP_CRIT if crit else HITSTOP_HIT)
	shake = minf(shake + (5.0 if crit else 2.6), 16.0)
	sfx("crit" if crit else "hit")

	var n := 16 if crit else 9
	for i in n:
		var a := dir + _rng.randf_range(-1.0, 1.0)
		_add_particle(e.x + _rng.randf_range(-6.0, 6.0), e.y + _rng.randf_range(-6.0, 6.0),
			_rng.randf_range(10.0, e.h * 0.7), {
				"vx": cos(a) * _rng.randf_range(60.0, 300.0),
				"vy": sin(a) * _rng.randf_range(60.0, 300.0),
				"vz": _rng.randf_range(30.0, 180.0), "life": _rng.randf_range(0.22, 0.5),
				"size": _rng.randf_range(1.4, 3.2),
				"color": "#fff4d0" if crit else "#ffce80", "glow": true,
				"drag": 2.6, "grav": 260.0,
				# 命中火花给个有形状的芯：暴击用四芒星，普通用闪电状的火星
				"tex": "star_06" if crit else "spark_07", "rot": a,
			})
	_add_text(e.x, e.y, e.h * 0.9,
		("●" if crit else "") + str(int(round(final))),
		"#fff2c8" if crit else "#ffcf86", 19.0 if crit else 14.0)

	if e.hp <= 0.0:
		_kill_enemy(e, dir)


func _kill_enemy(e: EnemyState, dir: float) -> void:
	e.dead = true
	e.death_t = 0.0
	prog["kills"] = int(prog["kills"]) + 1
	player.kills += 1
	sfx("die" if e.is_boss() else "hit")

	# 词条「噬」：击杀回复生命（不吃 RNG）
	var vamp := affix_lv("vamp")
	if vamp > 0 and not player.dead:
		var hp_before := player.hp
		player.hp = minf(player.max_hp, player.hp + float(vamp) * 3.0)
		if player.hp > hp_before + 0.01:
			_add_text(e.x, e.y, e.h + 12.0,
				"+%d" % int(round(player.hp - hp_before)), "#ff9db4", 13.0)

	var is_boss := e.is_boss()
	var coins := int(e.def["coin"])
	# 恩赐「灯油丰沛」：掉落更多灯火
	coins = int(round(float(coins) * (1.0 + float(boon("bounty")) * 0.6)))
	var pieces := 10 if is_boss else clampi(int(round(float(coins) / 2.0)), 1, 4)
	for i in pieces:
		drops.append({
			"x": e.x, "y": e.y, "z": _rng.randf_range(10.0, e.h * 0.6),
			"vx": _rng.randf_range(-140.0, 140.0), "vy": _rng.randf_range(-140.0, 140.0),
			"vz": _rng.randf_range(60.0, 190.0), "kind": "coin",
			"value": int(maxf(1.0, round(float(coins) / float(pieces)))),
			"life": 26.0, "t": 0.0, "taken": false,
		})
	if is_boss:
		for i in 2:
			drops.append({
				"x": e.x, "y": e.y, "z": 40.0,
				"vx": _rng.randf_range(-90.0, 90.0), "vy": _rng.randf_range(-90.0, 90.0),
				"vz": _rng.randf_range(90.0, 170.0), "kind": "wick", "value": 1,
				"life": 40.0, "t": 0.0, "taken": false,
			})
		drops.append({"x": e.x, "y": e.y, "z": 30.0, "vx": 0.0, "vy": 0.0, "vz": 120.0,
			"kind": "oil", "value": 1, "life": 40.0, "t": 0.0, "taken": false})
	elif _rng.randf() < 0.08:
		drops.append({"x": e.x, "y": e.y, "z": 26.0,
			"vx": _rng.randf_range(-40.0, 40.0), "vy": _rng.randf_range(-40.0, 40.0), "vz": 120.0,
			"kind": "oil", "value": 1, "life": 26.0, "t": 0.0, "taken": false})

	var n := 90 if is_boss else 20
	for i in n:
		var a := _rng.randf() * TAU
		var sp := _rng.randf_range(120.0, 720.0) if is_boss else _rng.randf_range(60.0, 320.0)
		var st := "star_09" if is_boss else ("star_06" if i % 3 == 0 else "spark_01")
		_add_particle(e.x, e.y, _rng.randf_range(6.0, e.h), {
			"vx": cos(a) * sp, "vy": sin(a) * sp, "vz": _rng.randf_range(40.0, 320.0),
			"life": _rng.randf_range(0.4, 1.1), "size": _rng.randf_range(2.0, 7.0 if is_boss else 4.0),
			"color": str(e.def["glow"]), "glow": true, "drag": 2.0, "grav": 220.0,
			"tex": st, "rot": a,
		})
	# 散尽的一缕烟：**不吃 _rng** —— 参数由下标推出来，同样可复现。
	# 放在非叠加层（glow=false），所以是"烟"不是"火星"。
	var snum := 10 if is_boss else 5
	for i in snum:
		var sa := float(i) * 2.399 + dir
		_add_particle(e.x + cos(sa) * 7.0, e.y + sin(sa) * 7.0, float(e.h) * 0.30,
			{"vx": cos(sa) * 24.0, "vy": sin(sa) * 24.0 - 10.0, "vz": 44.0 + float(i) * 9.0,
			 "life": 0.75 + float(i) * 0.10, "size": (20.0 if is_boss else 14.0) + float(i) * 5.0,
			 "color": "#6a6a78", "glow": false, "drag": 1.3, "grav": -22.0,
			 "tex": "smoke_0" + str(2 + i % 3), "rot": sa})
	if is_boss:
		player.glow = 1.0
		flash_color = Color.html("#ffd9a0")
		flash_power = 0.7
		shake = 24.0
		_on_boss_dead()
		return

	# ── 非 Boss：恩赐与词缀触发的连锁 ──
	# 恩赐「灯灭之环」：敌人死亡时炸出一圈光
	if boon("killboom") > 0:
		_push_effect({
			"kind": "burst", "x": e.x, "y": e.y, "z": 18.0,
			"r0": 14.0, "r1": 92.0, "life": 0.3, "increase": 0.0,
			"dmg": 22.0 * float(boon("killboom")) * (1.0 + float(boon("dmg")) * 0.14),
			"knock": 140.0, "color": "#ffd98a",
		})
	# 恩赐「噬影」：击杀回血
	if boon("vamp") > 0 and not player.dead:
		var hv := 4.0 * float(boon("vamp"))
		player.hp = minf(player.max_hp, player.hp + hv)
		_add_text(player.x, player.y, 58.0, "+" + str(int(hv)), "#a8e6b0", 13.0)
	# 词缀「燃」：死亡时爆出一圈火，会烧到玩家
	if e.burn > 0.0:
		_push_effect({
			"kind": "burst", "x": e.x, "y": e.y, "z": 18.0,
			"r0": 16.0, "r1": 118.0, "life": 0.36,
			"dmg": 13.0, "knock": 260.0, "color": "#ff7a4a",
			"own": "enemy", "delay": 0.10,
		})
		_spawn_fx(e.x, e.y, "#ff7a4a")
	# 无芯之暗：火盆没点满时，死掉的东西会再生
	if bool(level.get("respawn_while_dark", false)) and not e.respawned \
			and braziers_lit < braziers_required:
		respawn_queue.append({
			"type": _type_of(e), "affix": e.affix, "elite": e.elite,
			"x": e.x, "y": e.y, "t": 6.0,
		})


## 从 def 反查敌人类型 id（再生时需要重新 spawn）
func _type_of(e: EnemyState) -> String:
	for k in Content.ENEMIES.keys():
		if Content.ENEMIES[k] == e.def:
			return str(k)
	# 精英/带词缀的 def 是复制出来的，退化用名字去掉后缀来认
	var nm := str(e.def.get("name", ""))
	for k in Content.ENEMIES.keys():
		if nm.begins_with(str(Content.ENEMIES[k]["name"])):
			return str(k)
	return "shade"


func _on_boss_dead() -> void:
	boss_dead = true
	cleared = true
	ambient = float(level.get("cleared_ambient", 0.58))
	events.append({"type": "boss_end"})
	events.append({"type": "level_cleared"})
	# 第二关：通关时盲女燃尽自己点亮灯塔 → 「盲女之灯」给你一次濒死复燃
	if girl != null:
		player.revives += 1
	if not goal_prop.is_empty():
		goal_prop["lit"] = true
	prog["coins"] = int(prog["coins"]) + 80
	prog["wicks"] = int(prog["wicks"]) + 1
	events.append({"type": "dialogue", "key": str(level.get("clear_dialogue", "l1_clear"))})



func hurt_player(dmg: float, dir: float, extra_combo_loss := 0.0) -> void:
	var p := player
	if p.dead or p.invuln > 0.0:
		return
	# 灯杖·护光：护盾期间完全免疫，只在身上擦一下火花
	if p.shield_t > 0.0:
		_spawn_fx(p.x, p.y, "#d9c2ff")
		_add_text(p.x, p.y, 60.0, "护光", "#d9c2ff", 14.0)
		sfx("ui")
		return
	p.hp -= dmg
	p.invuln = 0.7
	p.hurt_flash = 0.35
	# 被咬掉光（词缀「噬」会额外咬掉一截连击）
	p.combo = maxf(0.0, p.combo - 3.0 - extra_combo_loss)
	shake = minf(shake + 7.0, 18.0)
	flash_color = Color.html("#d8543f")
	flash_power = 0.34
	p.vx += cos(dir) * 210.0
	p.vy += sin(dir) * 210.0
	sfx("hurt")
	_add_text(p.x, p.y, 60.0, "-" + str(int(round(dmg))), "#ff8a72", 16.0)
	for i in 12:
		var a := dir + _rng.randf_range(-1.2, 1.2)
		_add_particle(p.x, p.y, _rng.randf_range(10.0, 44.0), {
			"vx": cos(a) * _rng.randf_range(60.0, 220.0), "vy": sin(a) * _rng.randf_range(60.0, 220.0),
			"vz": _rng.randf_range(20.0, 120.0), "life": _rng.randf_range(0.3, 0.6),
			"size": _rng.randf_range(2.0, 4.0), "color": "#ff9a80", "glow": true,
			"drag": 3.0, "grav": 260.0,
		})
	if p.hp <= 0.0:
		_player_die()


func _player_die() -> void:
	var p := player
	# 盲女之灯：濒死替燃一次（第一关没有盲女，但流程留着）
	if p.revives > 0:
		p.revives -= 1
		p.hp = p.max_hp * 0.5
		p.invuln = 2.0
		p.combo = 0.0
		flash_color = Color.html("#fff2cc")
		flash_power = 0.8
		events.append({"type": "toast", "text": "盲女之灯替你燃了一次。"})
		return
	p.dead = true
	p.death_t = 0.0
	p.combo = 0.0
	prog["deaths"] = int(prog["deaths"]) + 1
	sfx("die")
	events.append({"type": "player_died"})


# ---------------------------------------------------------------- 特效 / 投射物 / 掉落 / 粒子

func _update_effects(dt: float) -> void:
	var keep := []
	for f in effects:
		f["life"] = float(f["life"]) - dt
		var t := clampf(1.0 - float(f["life"]) / maxf(0.001, float(f["max_life"])), 0.0, 1.0)
		var rr := lerpf(float(f["r0"]), float(f["r1"]), t)
		# "zone" 是持续区域（灯杖·灯球）：按 tick 反复结算，每跳重置命中集，
		# 所以同一个敌人可以被打很多次 —— 这是它和 burst 的本质区别。
		var tick := float(f.get("tick", 0.0))
		if tick > 0.0:
			f["tick_t"] = float(f.get("tick_t", 0.0)) - dt
			if float(f["tick_t"]) <= 0.0:
				f["tick_t"] = tick
				f["hit"] = {}
				_apply_effect_damage(f, rr)
		elif float(f["dmg"]) > 0.0 and t >= float(f["delay"]):
			_apply_effect_damage(f, rr)
		if float(f["life"]) > 0.0:
			keep.append(f)
	effects = keep


func _apply_effect_damage(f: Dictionary, rr: float) -> void:
	var kind := str(f["kind"])
	var hit: Dictionary = f["hit"]
	var own := str(f["own"])
	if own == "player":
		for e in enemies:
			if e.dead or hit.has(e.id):
				continue
			var d := Proj.dist(float(f["x"]), float(f["y"]), e.x, e.y)
			match kind:
				"slash":
					if d <= rr + e.r and (absf(Proj.angle_diff(float(f["angle"]), Proj.angle_to(float(f["x"]), float(f["y"]), e.x, e.y))) <= float(f["w"]) * 0.5 or d < 40.0):
						pass
					else:
						continue
				"beam":
					if not _in_beam(f, e.x, e.y, e.r):
						continue
				_:
					if d > rr + e.r:
						continue
			hit[e.id] = true
			damage_enemy(e, float(f["dmg"]), Proj.angle_to(float(f["x"]), float(f["y"]), e.x, e.y),
				float(f["knock"]), float(f["stun"]))
			# 锁灯·链锁：命中后把它拽向施法点
			if kind == "pull" and not e.dead:
				var pw := float(f.get("pull", 620.0)) * clampf(1.0 - float(e.def.get("weight", 0.3)), 0.08, 1.0)
				var pa := Proj.angle_to(e.x, e.y, float(f["x"]), float(f["y"]))
				e.vx += cos(pa) * pw
				e.vy += sin(pa) * pw
				e.stun = maxf(e.stun, float(f.get("pull_stun", 0.0)))
	else:
		var p := player
		if p.dead or p.invuln > 0.0:
			return
		var d := Proj.dist(float(f["x"]), float(f["y"]), p.x, p.y)
		match kind:
			"sweep", "beam":
				if not _in_beam_width(f, p.x, p.y, p.r):
					return
			_:
				if d > rr + p.r:
					return
		hurt_player(float(f["dmg"]), Proj.angle_to(float(f["x"]), float(f["y"]), p.x, p.y))


func _in_beam(f: Dictionary, tx: float, ty: float, tr: float) -> bool:
	return _in_beam_width(f, tx, ty, tr)


func _in_beam_width(f: Dictionary, tx: float, ty: float, tr: float) -> bool:
	var ox := float(f["x"])
	var oy := float(f["y"])
	var ang := float(f["angle"])
	var ln := float(f["len"])
	var half_w := float(f["w"]) * 0.5
	var dx := tx - ox
	var dy := ty - oy
	var along := dx * cos(ang) + dy * sin(ang)
	if along < -tr or along > ln + tr:
		return false
	var perp := absf(-dx * sin(ang) + dy * cos(ang))
	return perp <= half_w + tr


func _add_proj(d: Dictionary) -> void:
	var base := {
		"x": 0.0, "y": 0.0, "z": 20.0, "vx": 0.0, "vy": 0.0,
		"r": 12.0, "dmg": 5.0, "life": 1.0, "color": "#ffffff", "own": "enemy",
	}
	for k in d.keys():
		base[k] = d[k]
	projs.append(base)


func _update_projs(dt: float) -> void:
	var p := player
	var keep := []
	for q in projs:
		q["life"] = float(q["life"]) - dt
		q["x"] = float(q["x"]) + float(q["vx"]) * dt
		q["y"] = float(q["y"]) + float(float(q["vy"]) * dt)
		if float(q["life"]) <= 0.0 or blocked(float(q["x"]), float(q["y"]), float(q["r"])):
			_proj_burst(q)
			continue
		if str(q["own"]) == "enemy":
			if not p.dead and Proj.dist(float(q["x"]), float(q["y"]), p.x, p.y) < float(q["r"]) + p.r:
				hurt_player(float(q["dmg"]), Proj.angle_to(float(q["x"]), float(q["y"]), p.x, p.y))
				_proj_burst(q)
				continue
		else:
			# pierce：带这个键的投射物可以贯穿（命中不消失），同一个敌人只吃一次。
			# 不带这个键的（普通光矢）命中第一个就炸。
			var hitset: Dictionary = q.get("hit", {})
			var piercing: bool = q.has("pierce")
			var left := int(q.get("pierce", 0))
			var hit_any := false
			for e in enemies:
				if e.dead or hitset.has(e.id):
					continue
				if Proj.dist(float(q["x"]), float(q["y"]), e.x, e.y) < float(q["r"]) + e.r:
					hitset[e.id] = true
					damage_enemy(e, float(q["dmg"]),
						Proj.angle_to(float(q["x"]), float(q["y"]), e.x, e.y),
						float(q.get("knock", 260.0)))
					hit_any = true
					if not piercing:
						break
					left -= 1
					if left < 0:
						break
			if hit_any:
				q["hit"] = hitset
			if piercing:
				q["pierce"] = left
			if hit_any and (not piercing or left < 0):
				_proj_burst(q)
				continue
		keep.append(q)
	projs = keep


func _proj_burst(q: Dictionary) -> void:
	var c := str(q["color"])
	for i in 10:
		var a := _rng.randf() * TAU
		_add_particle(float(q["x"]), float(q["y"]), float(q["z"]), {
			"vx": cos(a) * _rng.randf_range(50.0, 220.0), "vy": sin(a) * _rng.randf_range(50.0, 220.0),
			"vz": _rng.randf_range(10.0, 90.0), "life": _rng.randf_range(0.2, 0.45),
			"size": _rng.randf_range(1.6, 3.4), "color": c, "glow": true, "drag": 3.0, "grav": 180.0,
		})


func _update_drops(dt: float) -> void:
	var p := player
	var keep := []
	for d in drops:
		if bool(d["taken"]):
			continue
		d["life"] = float(d["life"]) - dt
		if float(d["life"]) <= 0.0:
			continue
		d["t"] = float(d["t"]) + dt
		d["x"] = float(d["x"]) + float(d["vx"]) * dt
		d["y"] = float(d["y"]) + float(d["vy"]) * dt
		d["z"] = float(d["z"]) + float(d["vz"]) * dt
		if float(d["z"]) < 0.0:
			d["z"] = 0.0
			d["vz"] = -float(d["vz"]) * 0.35
		d["vz"] = float(d["vz"]) - 520.0 * dt
		d["vx"] = Proj.damp(float(d["vx"]), 0.0, 4.0, dt)
		d["vy"] = Proj.damp(float(d["vy"]), 0.0, 4.0, dt)
		# 拾取（吸附）
		var dd := Proj.dist(float(d["x"]), float(d["y"]), p.x, p.y)
		if dd < 90.0:
			var a := Proj.angle_to(float(d["x"]), float(d["y"]), p.x, p.y)
			var pull := (1.0 - dd / 90.0) * 420.0
			d["vx"] = float(d["vx"]) + cos(a) * pull * dt
			d["vy"] = float(d["vy"]) + sin(a) * pull * dt
		if dd < 30.0 and not p.dead:
			_take_drop(d)
			continue
		keep.append(d)
	drops = keep


func _take_drop(d: Dictionary) -> void:
	d["taken"] = true
	match str(d["kind"]):
		"coin":
			prog["coins"] = int(prog["coins"]) + int(d["value"])
			sfx("coin")
		"wick":
			prog["wicks"] = int(prog["wicks"]) + int(d["value"])
			sfx("levelup")
			events.append({"type": "toast", "text": "拾得灯芯 ×1"})
		"oil":
			prog["shop"]["oil_bank"] = int(prog["shop"].get("oil_bank", 0)) + 1
			sfx("coin")
			events.append({"type": "toast", "text": "拾得灯油 ×1"})


func _update_particles(dt: float) -> void:
	var keep := []
	for q in particles:
		q["life"] = float(q["life"]) - dt
		if float(q["life"]) <= 0.0:
			continue
		q["x"] = float(q["x"]) + float(q["vx"]) * dt
		q["y"] = float(q["y"]) + float(q["vy"]) * dt
		q["z"] = float(q["z"]) + float(q["vz"]) * dt
		q["vz"] = float(q["vz"]) - float(q["grav"]) * dt
		var dr := float(q["drag"])
		if dr > 0.0:
			q["vx"] = Proj.damp(float(q["vx"]), 0.0, dr, dt)
			q["vy"] = Proj.damp(float(q["vy"]), 0.0, dr, dt)
		if float(q["z"]) < 0.0:
			q["z"] = 0.0
			q["vz"] = 0.0
		keep.append(q)
	particles = keep

	var kt := []
	for t in texts:
		t["life"] = float(t["life"]) - dt
		if float(t["life"]) <= 0.0:
			continue
		t["z"] = float(t["z"]) + float(t["vy"]) * dt
		kt.append(t)
	texts = kt


func _add_particle(x: float, y: float, z: float, d: Dictionary) -> void:
	particles.append({
		"x": x, "y": y, "z": z,
		"vx": float(d.get("vx", 0.0)), "vy": float(d.get("vy", 0.0)), "vz": float(d.get("vz", 0.0)),
		"life": float(d.get("life", 0.5)), "max_life": float(d.get("life", 0.5)),
		"size": float(d.get("size", 2.0)), "color": str(d.get("color", "#ffffff")),
		"glow": bool(d.get("glow", false)), "drag": float(d.get("drag", 0.0)),
		"grav": float(d.get("grav", 0.0)),
	})


func _add_text(x: float, y: float, z: float, txt: String, color: String, size: float) -> void:
	texts.append({"x": x, "y": y, "z": z, "vy": 46.0, "text": txt,
		"color": color, "size": size, "life": 0.85, "max_life": 0.85})


func _spawn_fx(x: float, y: float, color: String) -> void:
	for i in 8:
		var a := _rng.randf() * TAU
		_add_particle(x, y, _rng.randf_range(4.0, 20.0), {
			"vx": cos(a) * _rng.randf_range(40.0, 180.0), "vy": sin(a) * _rng.randf_range(40.0, 180.0),
			"vz": _rng.randf_range(20.0, 90.0), "life": _rng.randf_range(0.3, 0.6),
			"size": _rng.randf_range(1.8, 3.6), "color": color, "glow": true, "drag": 2.6, "grav": 60.0,
		})


# ---------------------------------------------------------------- 波次 / Boss

## 第二关的火盆护佑：火盆没点满，Boss 减伤（level["boss_ward"]）。
## 第一关没有这个机制（braziers_required == 0）。
func boss_warded() -> bool:
	if braziers_required <= 0:
		return false
	return braziers_lit < braziers_required



func _update_waves(dt: float) -> void:
	respawn_timer -= dt
	_update_respawns(dt)

	if dev_spawn_all and not dev_spawned:
		dev_spawned = true
		for w in waves:
			if bool(w["spawned"]):
				continue
			w["spawned"] = true
			_spawn_wave_members(w, true)

	for wi in waves.size():
		var w: Dictionary = waves[wi]
		var wd: Dictionary = w["def"]
		if not bool(w["spawned"]):
			var d := Proj.dist(player.x, player.y, float(wd["x"]), float(wd["y"]))
			if d < float(wd["radius"]) + 90.0:
				w["spawned"] = true
				_spawn_wave_members(w, false)
				events.append({"type": "toast", "text": str(wd["label"])})
				sfx("ui_big")
		if bool(w["spawned"]) and not bool(w["cleared"]):
			var alive := false
			for e in enemies:
				if not e.dead and (e.id in w["members"]):
					alive = true
					break
			if not alive:
				w["cleared"] = true
				if not cleared:
					events.append({"type": "toast", "text": "%s　已清空" % wd["label"]})
					# 肉鸽：清空一波 → 三选一。每波只弹一次。
					if not draft_done.has(wi):
						draft_done[wi] = true
						events.append({"type": "draft"})

	# Boss：其它波次全清后再进入区域才触发
	if not boss_spawned and not boss_dead:
		var all_clear := true
		for w in waves:
			if not bool(w["cleared"]):
				all_clear = false
				break
		var bd: Dictionary = level["boss"]
		var in_boss := Proj.dist(player.x, player.y, float(bd["x"]), float(bd["y"])) < float(bd["radius"])
		var near_boss := Proj.dist(player.x, player.y, float(bd["x"]), float(bd["y"])) < float(bd["radius"]) + 320.0
		if (dev_spawn_all or in_boss or (all_clear and near_boss)) and (all_clear or dev_spawn_all):
			boss_spawned = true
			var pt := find_spawn_point(float(bd["x"]), float(bd["y"]), 80.0, 40.0)
			boss_enemy = spawn_enemy(str(bd["type"]), pt.x, pt.y, false)
			events.append({"type": "boss_start", "name": str(bd["label"])})
			events.append({"type": "dialogue", "key": str(level.get("boss_dialogue", "l1_boss_pre"))})
			sfx("roar")
			shake = 16.0
			flash_color = Color.html("#ff8a5a")
			flash_power = 0.42
		elif in_boss and not boss_hinted:
			boss_hinted = true
			events.append({"type": "toast", "text": "还有影子没清掉——先清空这片区域。"})


## 无芯之暗：火盆没点满时，死掉的东西会不断再生。
## 关键约束：再生出来的怪**不挂回任何一波的成员表**，否则那一波永远清不掉、
## 关卡就无法推进了。所以这里的再生是"压力"，不是"路障"。
func _update_respawns(dt: float) -> void:
	if respawn_queue.is_empty():
		return
	var p := player
	var keep := []
	for r in respawn_queue:
		r["t"] = float(r["t"]) - dt
		if float(r["t"]) > 0.0:
			keep.append(r)
			continue
		# 玩家就在脸上时先押后，别在鼻子底下刷怪
		if Proj.dist(p.x, p.y, float(r["x"]), float(r["y"])) < 160.0:
			r["t"] = 1.0
			keep.append(r)
			continue
		var alive := 0
		for e2 in enemies:
			if not e2.dead and not e2.is_boss():
				alive += 1
		if alive >= 14:
			r["t"] = 1.5
			keep.append(r)
			continue
		var tid := str(r["type"])
		if not Content.ENEMIES.has(tid):
			continue
		var def: Dictionary = Content.ENEMIES[tid]
		def = def.duplicate(true)
		var sc := float(level["enemy_scale"])
		def["hp"] = float(def["hp"]) * sc
		def["dmg"] = float(def["dmg"]) * sc
		var e := EnemyState.create(def, float(r["x"]), float(r["y"]), _next_id, false)
		e.respawned = true
		_next_id += 1
		enemies.append(e)
		respawn_count += 1
		_spawn_fx(float(r["x"]), float(r["y"]), str(def.get("glow", "#ffffff")))
		if respawn_count == 1:
			events.append({"type": "toast", "text": "黑暗里又爬出新的影子……（去点燃火盆）"})
	respawn_queue = keep


func _spawn_wave_members(w: Dictionary, fx: bool) -> void:
	var wd: Dictionary = w["def"]
	for grp in wd["enemies"]:
		for i in int(grp["count"]):
			var tid := str(grp["type"])
			var def: Dictionary = Content.ENEMIES.get(tid, {})
			var rr := float(def.get("r", 18.0))
			var pt := find_spawn_point(float(wd["x"]), float(wd["y"]), float(wd["radius"]), rr)
			var e := spawn_enemy(tid, pt.x, pt.y, bool(grp.get("elite", false)))
			if e != null:
				w["members"].append(e.id)
				if fx:
					_spawn_fx(pt.x, pt.y, str(def.get("glow", "#ffffff")))


func waves_cleared_count() -> int:
	var n := 0
	for w in waves:
		if bool(w["cleared"]):
			n += 1
	return n


# ---------------------------------------------------------------- 盲女同行（第二关）

## 盲女跟着玩家走，靠近时给光照加成（GIRL_LIGHT_BONUS）。
## 她不会被攻击、不挡路 —— 是"灯"不是"队友"。
func _update_girl(dt: float) -> void:
	if girl == null:
		return
	var p := player
	girl["wob"] = float(girl["wob"]) + dt * 2.2
	if p.dead:
		girl_near = false
		return
	var d := Proj.dist(p.x, p.y, float(girl["x"]), float(girl["y"]))
	# 保持一个"跟着但不同步"的距离：太远追上来，太近就慢一点
	var want := 86.0
	if d > want + 8.0:
		var a := Proj.angle_to(float(girl["x"]), float(girl["y"]), p.x, p.y)
		var sp := clampf((d - want) * 2.4, 40.0, 210.0)
		girl["vx"] = Proj.damp(float(girl["vx"]), cos(a) * sp, 6.0, dt)
		girl["vy"] = Proj.damp(float(girl["vy"]), sin(a) * sp, 6.0, dt)
	elif d < want - 24.0 and d > 0.01:
		var a2 := Proj.angle_to(float(girl["x"]), float(girl["y"]), p.x, p.y)
		girl["vx"] = Proj.damp(float(girl["vx"]), -cos(a2) * 70.0, 6.0, dt)
		girl["vy"] = Proj.damp(float(girl["vy"]), -sin(a2) * 70.0, 6.0, dt)
	else:
		girl["vx"] = Proj.damp(float(girl["vx"]), 0.0, 6.0, dt)
		girl["vy"] = Proj.damp(float(girl["vy"]), 0.0, 6.0, dt)
	var np := collide_wall(Vector2(float(girl["x"]) + float(girl["vx"]) * dt,
		float(girl["y"]) + float(girl["vy"]) * dt), float(girl["r"]))
	# 别被墙卡住：卡住就直接瞬移到玩家身侧
	if Proj.dist(np.x, np.y, float(girl["x"]), float(girl["y"])) < 0.3 and d > want + 40.0:
		var a3 := Proj.angle_to(p.x, p.y, float(girl["x"]), float(girl["y"]))
		np = Vector2(p.x + cos(a3) * 60.0, p.y + sin(a3) * 60.0)
	girl["x"] = np.x
	girl["y"] = np.y

	girl_near = d < 260.0
	if float(girl["talk_cd"]) > 0.0:
		girl["talk_cd"] = float(girl["talk_cd"]) - dt


# ---------------------------------------------------------------- 交互

func _update_interaction(dt: float) -> void:
	prompt = ""
	var p := player
	if p.dead:
		return
	var best := ""
	var best_d := 1e9
	for b in braziers:
		var d := Proj.dist(p.x, p.y, float(b["x"]), float(b["y"]))
		if d < 74.0 and not bool(b["lit"]) and d < best_d:
			best_d = d
			best = "点燃火盆（按 E）· 消耗 3 连击"
	if girl != null:
		var d := Proj.dist(p.x, p.y, float(girl["x"]), float(girl["y"]))
		if d < 90.0 and d < best_d:
			best_d = d
			best = "盲女：她感觉得到你身上的光（按 E 说话）"
	if not merchant_prop.is_empty():
		var d := Proj.dist(p.x, p.y, float(merchant_prop["x"]), float(merchant_prop["y"]))
		if d < 76.0 and d < best_d:
			best_d = d
			best = "守灯人：重铸 / 锤炼 / 买灯油（按 E 交谈）"
	for c in chests:
		var d := Proj.dist(p.x, p.y, float(c["x"]), float(c["y"]))
		if d < 78.0 and d < best_d:
			best_d = d
			if bool(c["opened"]):
				best = "空宝箱（按 E 再看看）"
			else:
				best = "宝箱：掀开看看（按 E）"
	if not goal_prop.is_empty():
		var d := Proj.dist(p.x, p.y, float(goal_prop["x"]), float(goal_prop["y"]))
		if d < 110.0 and d < best_d:
			best_d = d
			if bool(goal_prop["lit"]):
				best = "灯塔已亮 · 这里是庇护所"
			elif braziers_required > 0 and braziers_lit < braziers_required:
				best = "灯塔没反应 · 还差 %d 座火盆" % (braziers_required - braziers_lit)
			else:
				best = "点亮灯塔需要先清除这片区域"
	prompt = best


func light_brazier(b: Dictionary) -> void:
	if bool(b["lit"]):
		return
	b["lit"] = true
	b["lit_t"] = 0.0
	braziers_lit += 1
	sfx("brazier")
	_spawn_fx(float(b["x"]), float(b["y"]), "#ffb765")
	events.append({"type": "toast", "text": "火盆亮了。黑暗后退了三步。"})
	if braziers_required > 0:
		events.append({"type": "dialogue", "key": "l2_brazier"})
		if braziers_lit >= braziers_required:
			events.append({"type": "toast", "text": "火盆点满了——黑暗里的再生停了，Boss 的护佑也没了。"})
			flash_color = Color.html("#ffd9a0")
			flash_power = 0.45
			shake = 10.0


func try_light_brazier(x: float, y: float, rng: float) -> bool:
	for b in braziers:
		if not bool(b["lit"]) and Proj.dist(x, y, float(b["x"]), float(b["y"])) < rng:
			light_brazier(b)
			return true
	return false


func interact() -> void:
	var p := player
	if p.dead:
		return
	for b in braziers:
		if not bool(b["lit"]) and Proj.dist(p.x, p.y, float(b["x"]), float(b["y"])) < 74.0:
			if p.combo < 3.0:
				events.append({"type": "toast", "text": "连击不足 3 层，点不着火盆。"})
				sfx("ui")
				return
			p.combo -= 3.0
			light_brazier(b)
			return
	if girl != null and Proj.dist(p.x, p.y, float(girl["x"]), float(girl["y"])) < 90.0:
		if float(girl["talk_cd"]) <= 0.0 or not bool(girl["talked"]):
			girl["talked"] = true
			girl["talk_cd"] = 12.0
			events.append({"type": "dialogue", "key": "girl_talk"})
		return
	for c in chests:
		if Proj.dist(p.x, p.y, float(c["x"]), float(c["y"])) < 78.0:
			open_chest(c)
			return
	if not merchant_prop.is_empty() and Proj.dist(p.x, p.y, float(merchant_prop["x"]), float(merchant_prop["y"])) < 76.0:
		# 第一次交谈：先让守灯人自己说两句（走对白），谈完 main 再开商店
		if not bool(prog.get("keeper_talked", false)):
			prog["keeper_talked"] = true
			events.append({"type": "dialogue", "key": "keeper"})
		events.append({"type": "shop"})
		return
	if not goal_prop.is_empty() and Proj.dist(p.x, p.y, float(goal_prop["x"]), float(goal_prop["y"])) < 110.0:
		if bool(goal_prop["lit"]):
			events.append({"type": "dialogue", "key": "lighthouse_lit"})
		elif braziers_required > 0 and braziers_lit < braziers_required:
			events.append({"type": "toast", "text": "灯塔没反应——还差 %d 座火盆。" % (braziers_required - braziers_lit)})
		else:
			events.append({"type": "toast", "text": "灯塔还没反应——这片区域的影子还在。"})
		return


# ---------------------------------------------------------------- 目标

func _update_objective() -> void:
	var total := waves.size()
	var done := waves_cleared_count()
	if player.dead:
		objective = "你的灯灭了……"
	elif not cleared:
		if braziers_required > 0 and braziers_lit < braziers_required:
			objective = "点燃火盆 %d / %d　·　清影 %d / %d 波" % [braziers_lit, braziers_required, done, total]
		elif done < total:
			objective = "清除 %s 的影子　%d / %d 波" % [str(level["name"]), done, total]
		elif boss_enemy != null and not boss_enemy.dead:
			var bd: Dictionary = level["boss"]
			objective = "击败 %s" % str(bd["label"])
			if boss_warded():
				objective += "（火盆未点满 · 它被护佑着）"
		else:
			objective = "清除 %s 的影子　%d / %d 波" % [str(level["name"]), done, total]
	else:
		objective = "%s 已恢复光明 · 去点亮灯塔" % str(level["name"])


func emit_hud() -> void:
	events.append({"type": "hud"})


# ---------------------------------------------------------------- 存档

func save_dict() -> Dictionary:
	return {
		"level": level_index,
		"coins": int(prog["coins"]),
		"wicks": int(prog["wicks"]),
		"kills": int(prog["kills"]),
		"deaths": int(prog["deaths"]),
		"max_combo": int(prog["max_combo"]),
		"cleared": cleared,
		"braziers_lit": braziers_lit,
		"hp": player.hp,
		"max_hp": player.max_hp,
		"boons": boons.duplicate(),
	}


func teleport(x: float, y: float) -> void:
	player.x = x
	player.y = y
	cam = Vector2(x, y)


func alive_enemy_count() -> int:
	var n := 0
	for e in enemies:
		if not e.dead:
			n += 1
	return n


# ================================================================ 绘制
# 普通混合层：地板 → 地面特效 → 按 y 深度排序的立体物 → 飘字
# 叠加层（Bloom）见 draw_bloom()。

func _draw() -> void:
	if level.is_empty():
		return
	var pal: Dictionary = level["palette"]
	var c := draw_cam

	Art.floor(self, level, pal, c, time)

	# 地面层特效（光环、冲击波、挥击弧、预警圈）——在立体物之下，与 Web 版一致
	for f in effects:
		Art.effect_ground(self, f, c)

	# 深度排序：斜轴测下"越靠下（y 越大）越靠前"
	var items := []
	for w in walls:
		items.append({"y": float(w[1]) + float(w[3]), "k": 0, "r": w})
	for pr in props:
		items.append({"y": float(pr["y"]), "k": 1, "r": pr})
	for d in drops:
		items.append({"y": float(d["y"]), "k": 2, "r": d})
	for e in enemies:
		items.append({"y": e.y, "k": 3, "r": e})
	if girl != null:
		items.append({"y": float(girl["y"]), "k": 5, "r": girl})
	items.append({"y": player.y, "k": 4, "r": player})
	items.sort_custom(func(a, b): return float(a["y"]) < float(b["y"]))

	for it in items:
		match int(it["k"]):
			0:
				Art.wall(self, it["r"], pal, c)
			1:
				Art.prop(self, it["r"], pal, c, time)
			2:
				Art.drop(self, it["r"], c, time)
			3:
				Art.enemy(self, it["r"], c, time)
			4:
				Art.player(self, player, c, brightness01(), player.dead, time, player.weapon_id)
			5:
				Art.girl(self, it["r"], c, time)

	for ft in texts:
		Art.float_text(self, ft, c)


## 叠加混合层：灯火、辉光、火花（对应 Web 版的 globalCompositeOperation = 'lighter'）
func draw_bloom(ci: CanvasItem) -> void:
	if level.is_empty():
		return
	var c := draw_cam

	# 玩家脚下的暖芯。Web 版把这圈当成"唯一的光"，半径开到 0.55×光照半径；
	# 但它是 _draw 画的、**不认遮挡**，一大团暖光会直接糊在墙后的阴影上，
	# 正好抵消 LightOccluder2D 的意义。所以这里只留贴着脚的一小圈暖芯，
	# 真正的照明交给 LightRig 那盏会被墙挡住的 PointLight2D。
	var lr := player_light_radius()
	if not player.dead:
		var px := Proj.sx(player.x, c.x)
		var gy := Proj.sy(player.y, 0.0, c.y)
		Art.ground_circle(ci, px, gy, lr * 0.26, Color(1.0, 0.84, 0.59, 0.16))
		Art.ground_circle(ci, px, gy, lr * 0.15, Color(1.0, 0.80, 0.50, 0.12))
		Art.player_core(ci, player, c, brightness01(), time)
		# 冲刺：顺着冲刺方向拖几道曳光。参数全部由下标推出来，**不碰 _rng** ——
		# 多抽随机数会把仿真的随机流推歪，画面好看不值得拿可复现性去换。
		if player.dash_t > 0.0:
			var da := atan2(player.dash_dy, player.dash_dx)
			for i in 4:
				var tt := float(i) / 4.0
				var back := 34.0 + tt * 96.0
				var dp := Vector2(px - player.dash_dx * back,
					Proj.sy(player.y, 20.0, c.y) - player.dash_dy * back * Proj.YSQUASH)
				Art.tex_rot(ci, "trace_01", dp, 132.0 - tt * 46.0, 30.0 - tt * 10.0,
					da + PI * 0.5, Color(1.0, 0.90, 0.70, (1.0 - tt) * 0.30))

	# 挥击轨迹的亮芯
	if player.attack_t > 0.0:
		var t01 := 1.0 - player.attack_t / 0.2
		var w: Dictionary = player.weapon()
		var a0 := player.facing - float(w["arc"]) * 0.6
		var a1 := player.facing + float(w["arc"]) * 0.6
		var sweep := a0 + (a1 - a0) * t01
		var px2 := Proj.sx(player.x, c.x)
		var gy2 := Proj.sy(player.y, 0.0, c.y)
		Art.ground_arc(ci, px2, gy2, float(w["range"]) * 0.9, sweep - 0.9, sweep,
			Color(1.0, 0.95, 0.82, 0.55 * (1.0 - t01)), 4.0)
		# 月牙斩：一道有弧度的亮刃跟着扫过去 —— 打击感主要来自这一下。
		# 位置与朝向都在**屏幕空间**（贴图是用 draw_set_transform 转的），
		# 所以 y 要按 YSQUASH 压一下、角度也要换算，才能和地面上那道弧严丝合缝。
		var rad := float(w["range"]) * 1.34
		var sxp := px2 + cos(sweep) * rad * 0.70
		var syp := gy2 - 24.0 + sin(sweep) * rad * 0.70 * Proj.YSQUASH
		var scr := atan2(sin(sweep) * Proj.YSQUASH, cos(sweep))
		# 月牙形状按武器挑一个：重武器宽、突刺类窄，八把武器一眼能看出差别。
		# 朝左时竖直镜像 —— 镜像一次加旋转正好等于水平镜像，朝向就对上了。
		var sn := "01"
		if player.weapon_id == "spear" or player.weapon_id == "crossbow":
			sn = "03"
		elif player.weapon_id == "hammer" or player.weapon_id == "scythe":
			sn = "02"
		Art.tex_rot(ci, "slash_" + sn, Vector2(sxp, syp), rad * 1.45, rad * 1.45,
			scr + PI * 0.5, Color(1.0, 0.95, 0.84, 0.78 * (1.0 - t01)),
			cos(player.facing) < 0.0)

	# 灯杖·护光：身上罩一层会呼吸的光壳
	if player.shield_t > 0.0 and not player.dead:
		var pcx := Proj.sx(player.x, c.x)
		var pgy := Proj.sy(player.y, 0.0, c.y)
		var pulse := 1.0 + sin(time * 7.0) * 0.06
		var a := clampf(player.shield_t / 4.0, 0.25, 1.0)
		Art.ground_ring(ci, pcx, pgy, 44.0 * pulse, Color(0.85, 0.76, 1.0, 0.42 * a), 4.0)
		Art.glow(ci, Vector2(pcx, Proj.sy(player.y, 24.0, c.y)), 40.0, Color(0.85, 0.76, 1.0), 0.30 * a, 5)

	# 盲女：她自己就是一盏小灯
	if girl != null:
		var gx := Proj.sx(float(girl["x"]), c.x)
		var gy := Proj.sy(float(girl["y"]), 0.0, c.y)
		var gf := 1.0 + sin(float(girl["wob"])) * 0.12
		Art.ground_circle(ci, gx, gy, 70.0 * gf, Color(1.0, 0.94, 0.74, 0.13))
		Art.glow(ci, Vector2(gx, Proj.sy(float(girl["y"]), 34.0, c.y)), 26.0 * gf,
			Color("#ffe9b0"), 0.7, 5)

	# 技能/爆发的亮芯
	for f in effects:
		var t01 := clampf(1.0 - float(f["life"]) / maxf(0.001, float(f["max_life"])), 0.0, 1.0)
		var rr := lerpf(float(f["r0"]), float(f["r1"]), t01)
		var col := Color.html(str(f["color"]))
		var px := Proj.sx(float(f["x"]), c.x)
		var py := Proj.sy(float(f["y"]), float(f["z"]), c.y)
		# 带 delay 的效果（灯雨 / 陨光 / 旋链）：落点先亮一下再砸下来
		var dl := float(f["delay"])
		if dl > 0.0 and t01 < dl:
			var warn := t01 / maxf(0.001, dl)
			Art.ground_ring(ci, px, Proj.sy(float(f["y"]), 0.0, c.y), rr * 0.85,
				Color(col.r, col.g, col.b, 0.30 + 0.35 * warn), 3.0)
			continue
		match str(f["kind"]):
			"burst":
				# 星爆：素材的十字光比纯光晕更有"炸开"的形状感
				Art.tex_rot(ci, "magic_03", Vector2(px, py), rr * 2.6, rr * 2.6, 0.0,
					Color(1.0, 0.96, 0.88, 0.85 * (1.0 - t01)))
				Art.glow(ci, Vector2(px, py), maxf(20.0, rr * 0.45), col, 0.5 * (1.0 - t01), 6)
			"ring", "pull":
				var gry := Proj.sy(float(f["y"]), 0.0, c.y)
				Art.tex_rot(ci, "circle_03", Vector2(px, gry), rr * 2.3, rr * 2.3 * Proj.YSQUASH,
					0.0, Color(1.0, 0.94, 0.80, 0.5 * (1.0 - t01)))
				Art.ground_ring(ci, px, gry, rr * 0.9,
					Color(col.r, col.g, col.b, 0.35 * (1.0 - t01)), 7.0)
			"zone":
				# 滞空光球：一直在，缓慢呼吸
				var zf := 1.0 + sin(time * 6.0) * 0.08
				Art.tex_rot(ci, "magic_05", Vector2(px, py), 112.0 * zf, 112.0 * zf,
					time * 0.7, Color(1.0, 0.97, 0.90, 0.70))
				Art.glow(ci, Vector2(px, py), rr * 0.7 * zf, col, 0.65, 6)
				Art.ground_circle(ci, px, Proj.sy(float(f["y"]), 0.0, c.y), rr,
					Color(col.r, col.g, col.b, 0.13))
				ci.draw_circle(Vector2(px, py), 13.0 * zf, Color(1.0, 0.98, 0.92, 0.95))
			"muzzle":
				Art.tex_rot(ci, "muzzle_01", Vector2(px, py), 74.0, 74.0,
					float(f["angle"]) + PI, Color(1.0, 0.94, 0.78, 0.9 * (1.0 - t01)))
				Art.glow(ci, Vector2(px, py), rr * 0.8, col, 0.6 * (1.0 - t01), 5)
			"beam":
				pass
			"pillar":
				Art.glow(ci, Vector2(px, py), rr * 1.2, col, 0.35 * (1.0 - t01), 5)

	# 火盆的火焰辉光
	for pr in props:
		var kind := str(pr["kind"])
		if kind != "brazier" or not bool(pr["lit"]):
			continue
		var px := Proj.sx(float(pr["x"]), c.x)
		var py := Proj.sy(float(pr["y"]), 40.0, c.y)
		var f := 1.0 + sin(time * 9.0 + float(pr["seed"])) * 0.12
		# 火焰（叠加层）：底下那层负责形状，这一层负责"亮得刺眼"
		Art.tex_rot(ci, "fire_01", Vector2(px, py), 64.0 * f, 86.0 * f, 0.0,
			Color(1.0, 0.84, 0.52, 0.62))
		Art.glow(ci, Vector2(px, py), 46.0 * f, Color("#ffb765"), 0.5, 6)

	# 灯塔灯火
	if not goal_prop.is_empty() and bool(goal_prop["lit"]):
		var px := Proj.sx(float(goal_prop["x"]), c.x)
		var py := Proj.sy(float(goal_prop["y"]), float(goal_prop["h"]) + 8.0, c.y)
		Art.glow(ci, Vector2(px, py), 42.0, Color("#fff2cc"), 0.8, 6)

	# 敌人眼睛的辉光
	for e in enemies:
		if e.dead:
			continue
		var px := Proj.sx(e.x, c.x)
		var py := Proj.sy(e.y, 0.0, c.y)
		var glowc := Color.html(str(e.def["glow"]))
		var rr := (e.r * 0.9) if not e.is_boss() else (e.r * 0.8)
		Art.glow(ci, Vector2(px, py - e.h * 0.7), rr, glowc, 0.22, 4)

	# 掉落物的光晕（加一颗会呼吸的星，捡东西这件事更容易被看见）
	for d in drops:
		var px := Proj.sx(float(d["x"]), c.x)
		var py := Proj.sy(float(d["y"]), float(d["z"]) + 6.0, c.y)
		var dk := str(d["kind"])
		var dc := Color("#ffca70")
		if dk == "wick":
			dc = Color("#c9a6ff")
		elif dk == "oil":
			dc = Color("#8fe0b0")
		var tw := 0.85 + 0.15 * sin(time * 4.0 + float(d["x"]) * 0.05)
		Art.tex_rot(ci, "star_06", Vector2(px, py), 26.0 * tw, 26.0 * tw, 0.0,
			Color(dc.r, dc.g, dc.b, 0.9))
		Art.glow(ci, Vector2(px, py), 14.0, dc, 0.3, 4)

	# 火花：光晕负责"在发光"，带贴图的那种再叠一层有形状的芯
	for q in particles:
		if not bool(q["glow"]):
			continue
		var gp := Art.gpos(float(q["x"]), float(q["y"]), float(q["z"]), c)
		var gc := Color.html(str(q["color"]))
		var lf := clampf(float(q["life"]) / maxf(0.001, float(q["max_life"])), 0.0, 1.0)
		Art.glow(ci, gp, float(q["size"]) * 3.4, gc, 0.5, 4)
		var tn2 := str(q.get("tex", ""))
		if tn2 != "":
			var sz := float(q["size"]) * 5.6 * (0.55 + lf * 0.6)
			Art.tex_rot(ci, tn2, gp, sz, sz, float(q.get("rot", 0.0)),
				Color(gc.r, gc.g, gc.b, lf * 0.9))
	for q in particles:
		if bool(q["glow"]):
			continue
		Art.particle(ci, q, c)
	# 飞行物：顺着速度方向拖一道曳光，比一个亮点清楚得多
	for q in projs:
		var p2 := Art.gpos(float(q["x"]), float(q["y"]), float(q["z"]), c)
		var pc := Color.html(str(q["color"]))
		var pvx := float(q.get("vx", 0.0))
		var pvy := float(q.get("vy", 0.0))
		var pang := atan2(pvy, pvx) if absf(pvx) + absf(pvy) > 0.001 else 0.0
		var pr := float(q["r"])
		Art.tex_rot(ci, "trace_01", p2, pr * 9.0, pr * 1.7, pang + PI * 0.5,
			Color(pc.r, pc.g, pc.b, 0.85))
		Art.glow(ci, p2, pr * 2.2, pc, 0.7, 5)
		ci.draw_circle(p2, pr * 0.45, Color(1.0, 0.98, 0.9, 0.95))

