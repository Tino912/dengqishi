extends Node
## Content —— 游戏内容数据。
##
## 第一关的数值与布局仍然逐条照抄 Web 版 src/game/content.ts 与 levels.ts，
## 这样"迁移切片"的手感可比性还成立。
##
## 但**从这一版起，Godot 版是主开发线**：新增的 5 把武器、恩赐池（肉鸽三选一）、
## 精英词缀、第二关，Web 版都没有。差异写在 godot-lightknight/README.md 的
## 「与 Web 版的差异」一节里，不要以为两边还能逐帧比对。

# ================================================================ 武器
# 设计依据 README：每把武器自带一套技能，技能消耗连击数解锁；
# 不同武器的技能数与门槛连击数均不同。
#
# 这里的 8 把武器**不是靠调伤害数字区分的**，每把在
# 【攻速 / 范围 / 弧宽 / 挥击特效 / 技能机制】上各有自己的位置：
#
#   灯刃   blade     中庸基准，连击攒得最快
#   双灯刃 twin      最快的攻速，最窄的弧，单下最轻
#   长明枪 spear     最长的突刺，最窄的弧（0.62），贯穿型技能
#   锁灯   chain     最长的近战（132），拖拽型技能
#   烬锤   hammer    最慢最重，弧最宽之一（2.10），只有一招
#   灯镰   scythe    最宽的弧（2.70），收割型，带回血技能
#   灯弩   crossbow  唯一远程（射程 380），挥击即射矢
#   灯杖   staff     唯一法术型，留下持续区域与护盾

const WEAPONS := {
	"blade": {
		"name": "灯刃",
		"desc": "灯骑士最初的短刃。轻快、连击顺滑，连击数攒得最快。",
		"price": 0,
		"dmg": 13.0, "range": 66.0, "arc": 1.5, "cd": 0.30, "wind": 0.10, "knock": 190.0,
		"style": "slash", "color": "#ffd070",
		"skills": [
			{"id": "blade_whirl", "name": "旋斩", "cost": 4, "cd": 2.2,
			 "desc": "原地回身一周，横扫周围所有敌人。"},
			{"id": "blade_burst", "name": "灯爆", "cost": 12, "cd": 7.0,
			 "desc": "引爆身上灯火，冲击波推开敌人并点亮附近火盆。"},
		],
	},
	"twin": {
		"name": "双灯刃",
		"desc": "一对孪生短刃。快得看不清，但单下很轻，全靠连击层数把伤害顶起来。",
		"price": 60,
		"dmg": 9.0, "range": 56.0, "arc": 1.2, "cd": 0.18, "wind": 0.06, "knock": 120.0,
		"style": "slash", "color": "#ffe6b0",
		"skills": [
			{"id": "twin_flurry", "name": "乱影刃", "cost": 4, "cd": 2.4,
			 "desc": "向前疾冲，沿路留下一串斩击。"},
			{"id": "twin_ring", "name": "双旋", "cost": 11, "cd": 6.0,
			 "desc": "两道反向扩散的环刃，一近一远，各自结算。"},
		],
	},
	"spear": {
		"name": "长明枪",
		"desc": "灯塔守卫的长枪。距离长、突刺强，技能最多，但需要更高的连击。",
		"price": 70,
		"dmg": 17.0, "range": 104.0, "arc": 0.62, "cd": 0.42, "wind": 0.16, "knock": 240.0,
		"style": "thrust", "color": "#ffe8b8",
		"skills": [
			{"id": "spear_lunge", "name": "掠光刺", "cost": 3, "cd": 1.8,
			 "desc": "向前突进并贯穿路径上的敌人。"},
			{"id": "spear_flurry", "name": "连灯刺", "cost": 9, "cd": 5.0,
			 "desc": "向前连刺五下，越打越亮。"},
			{"id": "spear_pierce", "name": "长明贯", "cost": 18, "cd": 10.0,
			 "desc": "射出一道贯穿全场的光柱，重创直线上的敌人。"},
		],
	},
	"chain": {
		"name": "锁灯",
		"desc": "末端挂灯的锁链。近战里够得最远，能把影子从黑暗里拽回来。",
		"price": 90,
		"dmg": 19.0, "range": 132.0, "arc": 0.95, "cd": 0.50, "wind": 0.18, "knock": 210.0,
		"style": "whip", "color": "#ffcf8a",
		"skills": [
			{"id": "chain_hook", "name": "链锁", "cost": 5, "cd": 3.0,
			 "desc": "抛链缠住周围所有敌人，把它们拽到面前并震晕。"},
			{"id": "chain_spin", "name": "环链", "cost": 13, "cd": 6.5,
			 "desc": "链刃绕身连转三段，一段比一段宽。"},
		],
	},
	"hammer": {
		"name": "烬锤",
		"desc": "噬灯者残骸打成的重锤。慢、重、范围极大；只有一招，但一招就够。",
		"price": 140,
		"dmg": 34.0, "range": 82.0, "arc": 2.1, "cd": 0.68, "wind": 0.24, "knock": 420.0,
		"style": "smash", "color": "#ffd9a0",
		"skills": [
			{"id": "hammer_quake", "name": "撼地", "cost": 7, "cd": 3.6,
			 "desc": "砸地掀起环形光波，重创并击退周围一切，同时点亮附近火盆。"},
		],
	},
	"scythe": {
		"name": "灯镰",
		"desc": "收割灯影的长镰。弧最宽，一扫就是小半圈；要害是「别停」，停下就暗了。",
		"price": 160,
		"dmg": 24.0, "range": 96.0, "arc": 2.7, "cd": 0.62, "wind": 0.22, "knock": 260.0,
		"style": "slash", "color": "#c9f0dc",
		"skills": [
			{"id": "scythe_reap", "name": "回旋", "cost": 5, "cd": 2.6,
			 "desc": "一整圈收割。命中的敌人越多，这一刀越重。"},
			{"id": "scythe_devour", "name": "噬影", "cost": 14, "cd": 8.0,
			 "desc": "8 秒内把你造成的伤害吸回一部分化为生命。"},
			{"id": "scythe_crescent", "name": "月环", "cost": 22, "cd": 11.0,
			 "desc": "向前推出三道月牙光刃，逐道变宽变重。"},
		],
	},
	"crossbow": {
		"name": "灯弩",
		"desc": "唯一能隔着半个外庭说话的武器。挥击不再是刀弧，而是射出一支光矢。",
		"price": 130,
		"dmg": 15.0, "range": 380.0, "arc": 0.2, "cd": 0.55, "wind": 0.14, "knock": 150.0,
		"style": "shot", "color": "#bfe4ff",
		"skills": [
			{"id": "bow_volley", "name": "三连矢", "cost": 3, "cd": 2.0,
			 "desc": "一次射出三支呈扇形展开的光矢。"},
			{"id": "bow_pierce", "name": "穿影矢", "cost": 10, "cd": 5.5,
			 "desc": "一支重型箭矢，贯穿直线上的所有敌人。"},
			{"id": "bow_rain", "name": "灯雨", "cost": 20, "cd": 10.0,
			 "desc": "在周围落下一片光矢雨，每支都带范围伤害。"},
		],
	},
	"staff": {
		"name": "灯杖",
		"desc": "盲女留下的旧杖。伤害不算高，但它能在黑暗里「留下」东西。",
		"price": 180,
		"dmg": 22.0, "range": 120.0, "arc": 0.9, "cd": 0.58, "wind": 0.20, "knock": 200.0,
		"style": "cast", "color": "#d9c2ff",
		"skills": [
			{"id": "staff_orb", "name": "灯球", "cost": 6, "cd": 5.0,
			 "desc": "在身前留下一颗滞空光球，持续灼烧靠近的敌人。"},
			{"id": "staff_ward", "name": "护光", "cost": 14, "cd": 9.0,
			 "desc": "4 秒护光：免疫伤害，并把碰到你的敌人推开。"},
			{"id": "staff_meteor", "name": "陨光", "cost": 24, "cd": 12.0,
			 "desc": "在远处砸下一道光柱。落点会先亮一下——给敌人跑的机会。"},
		],
	},
}

# ================================================================ 肉鸽恩赐
# 清空一波后三选一。都是"局内成长"：死亡 / 重开即清空（run 内累积）。
# 同一个恩赐可以重复拿到，效果按层数叠加。

const BOONS := [
	{"id": "hp", "name": "灯芯·坚", "desc": "最大生命 +22"},
	{"id": "dmg", "name": "灯芯·锋", "desc": "全部伤害 +14%"},
	{"id": "haste", "name": "灯芯·疾", "desc": "挥击冷却 -12%"},
	{"id": "light", "name": "灯芯·明", "desc": "基础光照半径 +26"},
	{"id": "reach", "name": "灯芯·远", "desc": "攻击范围 +12%"},
	{"id": "vamp", "name": "噬影", "desc": "击杀回复 4 点生命"},
	{"id": "combo_up", "name": "火种不熄", "desc": "连击衰减速度 -30%"},
	{"id": "combo_add", "name": "越战越亮", "desc": "每次命中额外获得 0.2 连击"},
	{"id": "dash", "name": "影步", "desc": "冲刺冷却 -30%"},
	{"id": "skill_cd", "name": "灯芯·通", "desc": "技能冷却 -18%"},
	{"id": "cost_cut", "name": "省火", "desc": "技能连击消耗 -1（最低 1）"},
	{"id": "crit", "name": "灯芯·锐", "desc": "12% 概率造成双倍伤害"},
	{"id": "bounty", "name": "灯油丰沛", "desc": "击杀获得的灯火 +60%"},
	{"id": "killboom", "name": "灯灭之环", "desc": "敌人死亡时炸出 22 点光环伤害"},
]

# ================================================================ 武器词条
# 守灯人的两样活儿：
#   · 重铸 —— 把当前武器的词条**全部重 roll**（1~3 条，等级归 1）
#   · 锤炼 —— 加一条新词条；已经满了就**升一级**现有的
# 词条挂在【武器 id】上（`prog["waffix"]`），不是挂在"当前手持"上：
# 所以换手不丢、换回来还在。背包里那把也各自带自己的词条。
#
# 所有效果都**并入 world 的派生属性访问器**（damage_mul / attack_cd_mul / …），
# 不要在别处再乘一遍 —— 否则自检的数值断言和实际手感会脱节。

const AFFIX_MAX := 3        ## 一把武器最多几条词条
const AFFIX_LV_MAX := 5     ## 单条词条最高几级

const WEAPON_AFFIXES := {
	"edge": {"name": "锋", "color": "#ff9f6b", "desc": "伤害 +12%"},
	"swift": {"name": "疾", "color": "#8fd8ff", "desc": "挥击冷却 -10%"},
	"reach": {"name": "远", "color": "#b6e88f", "desc": "攻击范围 +12%"},
	"crit": {"name": "锐", "color": "#ffe066", "desc": "暴击率 +8%"},
	"vamp": {"name": "噬", "color": "#ff7d9c", "desc": "击杀回复 3 点生命"},
	"shine": {"name": "明", "color": "#ffeeb0", "desc": "光照半径 +22"},
	"ember": {"name": "火", "color": "#ffb066", "desc": "每次命中额外 +0.15 连击"},
	"frugal": {"name": "省", "color": "#c9b6ff", "desc": "技能连击消耗 -1（最低 1）"},
}

## 词条固定顺序（重铸/锤炼抽词条时的候选顺序，不用 Dictionary.keys() —— 
## 顺序随版本变会让同一颗种子 roll 出不同结果）
const AFFIX_ORDER := [
	"edge", "swift", "reach", "crit", "vamp", "shine", "ember", "frugal",
]


# ================================================================ 守灯人 / 宝箱

const SHOP := {
	"oil": {"name": "灯油", "price": 22, "heal": 0.45,
		"desc": "回血道具：喝下回复 45% 生命。买下后放进背包，按 C 喝。"},
	"reforge": {"name": "重铸", "price": 45,
		"desc": "把当前武器的词条全部重 roll（1~3 条，等级归 1）。"},
	"temper_base": 30, "temper_step": 15,
}


## 锤炼的价钱：按这把武器**已有词条等级之和**涨价 —— 
## 越练越贵，避免"一直点同一条"变成免费刷数值。
func temper_cost(levels_sum: int) -> int:
	return SHOP["temper_base"] + SHOP["temper_step"] * levels_sum


# ================================================================ 精英词缀
# 精英怪除了数值强化（eliteify），还随机带一个词缀，让"同一个精英"每局不一样。

const ELITE_AFFIXES := {
	"burn": {"name": "燃", "glow": "#ff7a4a", "desc": "死亡时爆出一圈火"},
	"tough": {"name": "韧", "glow": "#9adf8a", "desc": "减伤 35%，生命更高"},
	"swift": {"name": "疾", "glow": "#8ad8ff", "desc": "更快，也打得更勤"},
	"drain": {"name": "噬", "glow": "#ff6b8a", "desc": "命中会额外咬掉连击"},
	"ward": {"name": "障", "glow": "#ffe08a", "desc": "每 4 秒挡住一次伤害"},
}

# ================================================================ 敌人

const ENEMIES := {
	"shade": {
		"name": "灯影", "hp": 24.0, "speed": 92.0, "dmg": 9.0, "r": 16.0, "h": 36.0,
		"aggro": 460.0, "atk_range": 40.0, "atk_cd": 1.05, "wind": 0.34,
		"behavior": "chase", "body": "#171a2e", "glow": "#b7a8ff", "light": 30.0,
		"coin": 2, "weight": 0.2,
	},
	"moth": {
		"name": "扑灯蛾", "hp": 18.0, "speed": 128.0, "dmg": 7.0, "r": 13.0, "h": 24.0,
		"aggro": 560.0, "atk_range": 34.0, "atk_cd": 0.90, "wind": 0.26,
		"behavior": "chase", "body": "#2a2233", "glow": "#ffd98a", "light": 18.0,
		"coin": 2, "weight": 0.05,
	},
	"guard": {
		"name": "灯烬卫", "hp": 78.0, "speed": 60.0, "dmg": 17.0, "r": 23.0, "h": 50.0,
		"aggro": 500.0, "atk_range": 62.0, "atk_cd": 1.75, "wind": 0.62,
		"behavior": "guard", "body": "#2b2118", "glow": "#ff9b45", "light": 24.0,
		"coin": 6, "weight": 0.7,
	},
	"leech": {
		"name": "灯蛭", "hp": 36.0, "speed": 74.0, "dmg": 11.0, "r": 18.0, "h": 30.0,
		"aggro": 700.0, "atk_range": 350.0, "atk_cd": 2.3, "wind": 0.68,
		"behavior": "spitter", "body": "#211826", "glow": "#ff6b8a", "light": 22.0,
		"coin": 4, "weight": 0.3,
	},
	"devourer_jr": {
		"name": "噬灯者·幼体", "hp": 430.0, "speed": 78.0, "dmg": 17.0, "r": 40.0, "h": 76.0,
		"aggro": 900.0, "atk_range": 120.0, "atk_cd": 2.0, "wind": 0.62,
		"behavior": "boss", "body": "#20141c", "glow": "#ff5f3c", "light": 40.0,
		"coin": 60, "weight": 1.0, "boss_style": "devourer", "boss_scale": 1.0,
	},
	"devourer": {
		"name": "噬灯者", "hp": 900.0, "speed": 84.0, "dmg": 22.0, "r": 48.0, "h": 92.0,
		"aggro": 1100.0, "atk_range": 135.0, "atk_cd": 1.8, "wind": 0.58,
		"behavior": "boss", "body": "#241019", "glow": "#ff4f2e", "light": 46.0,
		"coin": 110, "weight": 1.0, "boss_style": "devourer", "boss_scale": 1.25,
	},
	"lampdemon_shadow": {
		"name": "灯魔之影", "hp": 1250.0, "speed": 92.0, "dmg": 26.0, "r": 52.0, "h": 104.0,
		"aggro": 1200.0, "atk_range": 150.0, "atk_cd": 1.6, "wind": 0.5,
		"behavior": "boss", "body": "#1a1226", "glow": "#8f6bff", "light": 50.0,
		"coin": 180.0, "weight": 1.0, "boss_style": "shadow", "boss_scale": 1.35,
	},
}


## 精英化：数值强化（照抄 Web 版）
func eliteify(def: Dictionary) -> Dictionary:
	var d := def.duplicate(true)
	d["name"] = str(def["name"]) + "（精英）"
	d["hp"] = roundf(float(def["hp"]) * 2.6)
	d["dmg"] = roundf(float(def["dmg"]) * 1.35)
	d["r"] = float(def["r"]) * 1.28
	d["h"] = float(def["h"]) * 1.2
	d["coin"] = int(round(float(def["coin"]) * 4.0))
	d["glow"] = "#ffe08a"
	d["light"] = float(def.get("light", 0.0)) + 34.0
	d["weight"] = 1.0
	return d


## 精英词缀：在数值强化之上再叠一层行为变化。
## rng 由关卡种子派生，所以同一局内是确定的。
func apply_affix(def: Dictionary, affix: String, rng: RandomNumberGenerator) -> Dictionary:
	var d := def.duplicate(true)
	if not ELITE_AFFIXES.has(affix):
		return d
	var a: Dictionary = ELITE_AFFIXES[affix]
	d["affix"] = affix
	d["affix_name"] = str(a["name"])
	d["glow"] = str(a["glow"])
	match affix:
		"tough":
			d["hp"] = roundf(float(d["hp"]) * 1.3)
			d["dr"] = 0.35
			d["h"] = float(d["h"]) * 1.05
		"swift":
			d["speed"] = float(d["speed"]) * 1.4
			d["atk_cd"] = float(d["atk_cd"]) * 0.75
		"drain":
			d["hp"] = roundf(float(d["hp"]) * 0.85)
			d["drain"] = 2.0
		"ward":
			d["ward_cd"] = 4.0
		"burn":
			d["burn"] = 1.0
	# 词缀会额外加一点随机性与区分度
	d["coin"] = int(round(float(d["coin"]) * rng.randf_range(1.0, 1.35)))
	return d


# ================================================================ 关卡
# 第一关布局逐条照抄 levels.ts 的 L1（保持迁移可比性）。
# 第二关照抄 levels.ts 的 L2，并把它的三个特殊机制做出来：
#   · braziersRequired / respawnWhileDark —— 火盆不点全，死掉的东西会再生
#   · blindGirl —— 盲女同行，靠近她光照更强
#   · 更黑的 ambient（0.955）

const B_EDGE := 44.0   # 边界墙厚度

const LEVEL1 := {
	"index": 0,
	"name": "灯堡外庭",
	"subtitle": "第一张地图 · 美好过往",
	"lore": "外庭的灯还亮着，这是你最好的日子。",
	"w": 2400.0, "h": 1700.0,
	"ambient": 0.9,
	"cleared_ambient": 0.58,
	"seed": 10711,
	"enemy_scale": 1.0,
	"decor_count": 26,
	"boss_dialogue": "l1_boss_pre",
	"clear_dialogue": "l1_clear",
	"start": Vector2(300.0, 1350.0),
	"goal": {"kind": "lighthouse", "pos": Vector2(2200.0, 250.0), "name": "外庭灯塔"},
	"palette": {
		"floor": "#1b2030", "floor2": "#171b28",
		"wall": "#2b3345", "wall_top": "#3b465c",
		"rim": "#93a7cc", "fog": "#0a0e18", "accent": "#ffca70",
	},
	# x, y, w(宽), d(进深), h(立起高度)
	"walls": [
		# 外圈边界
		[0.0, 0.0, 2400.0, B_EDGE, 64.0],
		[0.0, 1700.0 - B_EDGE, 2400.0, B_EDGE, 64.0],
		[0.0, 0.0, B_EDGE, 1700.0, 64.0],
		[2400.0 - B_EDGE, 0.0, B_EDGE, 1700.0, 64.0],
		# 关内
		[520.0, 300.0, 140.0, 400.0, 54.0],
		[860.0, 620.0, 360.0, 60.0, 46.0],
		[1460.0, 240.0, 60.0, 340.0, 46.0],
		[1140.0, 880.0, 420.0, 60.0, 46.0],
		[420.0, 980.0, 60.0, 300.0, 46.0],
		[1740.0, 760.0, 300.0, 60.0, 52.0],
		[1600.0, 1180.0, 60.0, 300.0, 46.0],
		[880.0, 1300.0, 340.0, 60.0, 46.0],
		[2040.0, 980.0, 60.0, 400.0, 50.0],
		[1900.0, 150.0, 60.0, 280.0, 46.0],
	],
	"props": [
		{"kind": "lighthouse", "x": 2200.0, "y": 250.0},
		{"kind": "brazier", "x": 700.0, "y": 1180.0},
		{"kind": "brazier", "x": 1330.0, "y": 520.0},
		{"kind": "brazier", "x": 1900.0, "y": 1360.0},
		{"kind": "merchant", "x": 290.0, "y": 1400.0},
		{"kind": "statue", "x": 1180.0, "y": 1500.0},
	],
	# 宝箱：**故意不写进 props**。props 里每一项都会消耗 _decor_rng 抽一个 seed，
	# 往里加东西会整体挪动装饰的随机流 → 所有装饰的位置都会变 → 依赖装饰的像素断言全崩。
	# 单独一个 key，用独立的 rng、并且等 _decorate() 跑完再入 props。
	#
	# ⚠️ 这里只管**数量**与**兜底坐标**：真实点位每局由 `World._roll_chest_spots()`
	# 按 `Main.run_seed` 随机生成；只有撒点失败时才回落到下面这两个点
	# （数量必须永远对得上 —— 少一个宝箱会连带撞掉一片断言）。
	"chests": [Vector2(700.0, 1450.0), Vector2(2150.0, 1150.0)],
	# 波次：`x/y` 是**兜底锚点**（真实锚点每局由 `World._roll_anchors()` 随机生成）；
	# 触发半径 `radius` 与 `enemies` 的构成仍然由这里说了算。
	"waves": [
		{"label": "第一波 · 石灯下的影", "x": 830.0, "y": 830.0, "radius": 300.0,
		 "enemies": [{"type": "shade", "count": 4}]},
		{"label": "第二波 · 烬卫巡逻", "x": 1500.0, "y": 1130.0, "radius": 320.0,
		 "enemies": [{"type": "shade", "count": 5}, {"type": "guard", "count": 2}]},
		{"label": "第三波 · 幼体前的守卫", "x": 1980.0, "y": 700.0, "radius": 320.0,
		 "enemies": [{"type": "shade", "count": 4}, {"type": "guard", "count": 1, "elite": true},
						 {"type": "leech", "count": 2}]},
	],
	# Boss：`x/y` 也是**兜底锚点**，真实场地每局随机生成（存于 `World.boss_anchor`）。
	# 场上"势力范围"大小仍用这里的 `radius`；`label` / `type` 不受影响。
	"boss": {"type": "devourer_jr", "x": 2080.0, "y": 420.0, "radius": 320.0, "label": "噬灯者·幼体"},
}

const LEVEL2 := {
	"index": 1,
	"name": "灯堡深处 · 无芯之暗",
	"subtitle": "第二张地图 · 遇难",
	"lore": "没有灯芯的地方，死了的东西会不断再生。",
	"w": 2800.0, "h": 2000.0,
	"ambient": 0.955,
	"cleared_ambient": 0.62,
	"seed": 20422,
	"enemy_scale": 1.18,
	"decor_count": 30,
	"boss_dialogue": "l2_boss_pre",
	"clear_dialogue": "l2_clear",
	"start": Vector2(300.0, 1750.0),
	"goal": {"kind": "lighthouse", "pos": Vector2(2640.0, 1830.0), "name": "深处灯塔"},
	"palette": {
		"floor": "#171523", "floor2": "#131120",
		"wall": "#262034", "wall_top": "#332b45",
		"rim": "#8b78b4", "fog": "#08060f", "accent": "#c9a6ff",
	},
	"walls": [
		[0.0, 0.0, 2800.0, 70.0, 70.0],
		[0.0, 2000.0 - 70.0, 2800.0, 70.0, 70.0],
		[0.0, 0.0, 70.0, 2000.0, 70.0],
		[2800.0 - 70.0, 0.0, 70.0, 2000.0, 70.0],
		[400.0, 360.0, 520.0, 60.0, 56.0],
		[400.0, 360.0, 60.0, 340.0, 56.0],
		[1120.0, 300.0, 60.0, 420.0, 54.0],
		[1400.0, 640.0, 420.0, 60.0, 54.0],
		[700.0, 880.0, 60.0, 380.0, 50.0],
		[900.0, 1240.0, 460.0, 60.0, 50.0],
		[1600.0, 980.0, 60.0, 440.0, 54.0],
		[1820.0, 1420.0, 440.0, 60.0, 50.0],
		[2020.0, 380.0, 60.0, 400.0, 54.0],
		[2240.0, 820.0, 60.0, 320.0, 50.0],
		[1320.0, 1540.0, 400.0, 60.0, 50.0],
		[2260.0, 1160.0, 340.0, 60.0, 50.0],
	],
	"props": [
		{"kind": "lighthouse", "x": 2640.0, "y": 1830.0},
		{"kind": "brazier", "x": 620.0, "y": 560.0},
		{"kind": "brazier", "x": 1560.0, "y": 790.0},
		{"kind": "brazier", "x": 2380.0, "y": 1680.0},
		{"kind": "merchant", "x": 300.0, "y": 1860.0},
		{"kind": "statue", "x": 1420.0, "y": 1180.0},
		{"kind": "statue", "x": 2100.0, "y": 1620.0},
	],
	# 宝箱（同上：不入 props，避免挪动 _decor_rng 流；点位每局随机，这里是兜底）
	"chests": [Vector2(500.0, 1750.0), Vector2(2500.0, 800.0)],
	# 波次：`x/y` 兜底锚点，真实锚点每局随机生成
	"waves": [
		{"label": "第一波 · 再生之影", "x": 900.0, "y": 760.0, "radius": 340.0,
		 "enemies": [{"type": "shade", "count": 5}, {"type": "guard", "count": 1}]},
		{"label": "第二波 · 蛭群", "x": 1720.0, "y": 1220.0, "radius": 340.0,
		 "enemies": [{"type": "shade", "count": 5}, {"type": "guard", "count": 2}, {"type": "leech", "count": 2}]},
		{"label": "第三波 · 烬卫队长", "x": 2380.0, "y": 560.0, "radius": 320.0,
		 "enemies": [{"type": "shade", "count": 4}, {"type": "guard", "count": 1, "elite": true}, {"type": "leech", "count": 2}]},
	],
	# Boss：`x/y` 兜底锚点（真实场地每局随机，见 World.boss_anchor）
	"boss": {"type": "devourer", "x": 1240.0, "y": 420.0, "radius": 340.0, "label": "噬灯者"},
	# ── 第二关专属机制 ──
	"braziers_required": 3,        # 点满 3 座火盆才能压制再生
	"respawn_while_dark": true,    # 火盆未点满时，死掉的敌人会再生
	"blind_girl": Vector2(430.0, 1700.0),
	"boss_ward": 0.55,             # 火盆未点满时 Boss 减伤
}

const LEVELS := [LEVEL1, LEVEL2]


func level_count() -> int:
	return LEVELS.size()


func level_at(i: int) -> Dictionary:
	return LEVELS[clampi(i, 0, LEVELS.size() - 1)]


## 道具的物理尺寸（半径 / 高度 / 是否阻挡移动）——照抄 Web 版的 makeProp 表
const PROP_TABLE := {
	"lighthouse": {"r": 30.0, "h": 200.0, "solid": true},
	"brazier": {"r": 20.0, "h": 42.0, "solid": true},
	"dock": {"r": 34.0, "h": 26.0, "solid": false},
	"merchant": {"r": 17.0, "h": 48.0, "solid": false},
	"pillar": {"r": 17.0, "h": 66.0, "solid": true},
	"lantern": {"r": 13.0, "h": 40.0, "solid": false},
	"tree": {"r": 15.0, "h": 54.0, "solid": false},
	"rubble": {"r": 16.0, "h": 14.0, "solid": false},
	"statue": {"r": 19.0, "h": 62.0, "solid": true},
	# 宝箱：**故意不 solid**。它是个"交互点"，不是障碍 ——
	# 设成 solid 会插进 collide_wall 的推挤里，而动线/撞墙那几条断言
	# 是拿现有道具布局量出来的，多一个实心体就可能把玩家顶到别处。
	"chest": {"r": 20.0, "h": 30.0, "solid": false},
}

# ================================================================ 文本

const LORE := {
	"motto": "暂时的是现实，永恒的是理想。",
	"l1": "外庭的灯还亮着，这是你最好的日子。",
	"l2": "没有灯芯的地方，死了的东西会不断再生。",
}

const DIALOGUES := {
	"l1_start": [
		["旁白", "【灯堡外庭】\n石灯还亮着，风里有灯油的味道。这是灯骑士最好的日子。"],
		["灯骑士", "（连击会让身上的灯火更亮……越大意，越容易被黑暗咬住。）"],
		["守灯人", "记住：连击就是你的光。别停手，也别贪。"],
	],
	"l1_boss_pre": [
		["旁白", "角落里蜷着一团小小的影子，它正抱着一盏灯啃。"],
		["噬灯者·幼体", "灯……是吃的……"],
		["灯骑士", "（它还是幼体。可它已经在吃灯了。）"],
	],
	"l1_clear": [
		["旁白", "幼体倒下时，灯堡的钟响了。你以为这只是个晚上的巡逻。"],
		["灯骑士", "这影子……在吃灯火？"],
		["旁白", "钟声第三下，外庭所有的灯同时熄了。"],
		["守灯人", "（远处的黑暗里）听到了吗……它们饿了。"],
	],
	"lighthouse_lit": [
		["旁白", "灯塔亮了。庇护所、存档点、传送点——都在这里。"],
	],
	# ── 第二关 ──
	"l2_start": [
		["旁白", "【灯堡深处 · 无芯之暗】\n这里的灯芯被人拔走了。没有光，死了的东西会不断再生。"],
		["灯骑士", "好黑……"],
		["灯骑士", "天还能亮吗？"],
		["盲女", "会的。"],
		["灯骑士", "……可你不是看不见吗？"],
		["盲女", "可你在我身边时，我就感到格外亮堂。"],
		["旁白", "（她看不见，却能感应灯火。靠近她时，你身上的光会更强。）"],
	],
	"l2_brazier": [
		["盲女", "把连击的火按在火盆上——它们会替你记住这段光亮。"],
		["旁白", "火盆亮起。黑暗后退了三步。"],
	],
	"l2_boss_pre": [
		["噬灯者", "你是受诅咒者，跟我们一样，是吃灯的家伙。"],
		["灯骑士", "我不是。"],
		["噬灯者", "那你胸口的暗纹是什么？是灯在吃你，还是你在吃灯？"],
		["盲女", "别听它的。它吃的是别人的灯，你烧的是自己的心。"],
	],
	"l2_clear": [
		["旁白", "噬灯者扑向盲女——它闻到了古老灯芯的味道。"],
		["灯骑士", "不！"],
		["旁白", "你救出了她，可是她已经燃尽了。"],
		["盲女", "……点我。"],
		["灯骑士", "什么？"],
		["盲女", "点亮我。让我去当灯芯，你就能走到更暗的地方去。"],
		["旁白", "她点亮了灯塔。从此她也成了你身上的光。"],
		["旁白", "【获得 盲女之灯】光照更强，且她会在你濒死时替你燃一次。"],
	],
	"girl_talk": [
		["盲女", "你身上的灯在抖。别怕，我在。"],
		["灯骑士", "……你怎么知道我在抖。"],
		["盲女", "因为你一亮，我这里也跟着亮。"],
	],
	"keeper": [
		["守灯人", "过来点，别站在黑里。灯的活儿我这儿有三样：重铸、锤炼、还有灯油。"],
		["灯骑士", "……你什么都要钱。"],
		["守灯人", "我不收钱，我收灯火。你身上那点光，是别人烧剩的。"],
		["守灯人", "重铸是把词条推倒重来，锤炼是往刃上加一道。想清楚再给钱。"],
	],
	"chest_open": [
		["旁白", "箱盖一掀，里面躺着一把还带着余温的兵器。"],
	],
	"no_wick": [
		["旁白", "这里没有灯芯，死亡会重生。先去点燃三座火盆，用连击之光。"],
	],
}
