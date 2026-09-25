class_name EnemyState
extends RefCounted
## 敌人状态。字段与 Web 版 world.ts 的 Enemy 类逐条对应。

var def := {}
var elite := false
var id := 0

var x := 0.0
var y := 0.0
var z := 0.0
var vx := 0.0
var vy := 0.0

var hp := 100.0
var max_hp := 100.0
var r := 18.0
var h := 40.0
var facing := 1.0

## spawn → idle/chase → windup → attack → hurt → dead
var state := "spawn"
var t := 0.0
var atk_cd := 0.0
var hit_flash := 0.0
var stun := 0.0
var wob := 0.0
## 本次挥击是否已经结算过伤害（避免同一次挥击打多下）
var atk_done := false

var dead := false
var death_t := 0.0
var spawn_t := 0.45

## Boss 专用
var boss := {}

## 精英词缀（燃 / 韧 / 疾 / 噬 / 障）。空串 = 普通精英或非精英。
var affix := ""
var affix_name := ""
var dr := 0.0          ## 韧：减伤 0..1
var ward_cd := 0.0     ## 障：格挡的冷却
var ward_t := 0.0      ## 障：当前剩余的格挡次数恢复计时
var burn := 0.0        ## 燃：死亡时爆出火环
var drain := 0.0       ## 噬：命中额外扣的连击数

## 元素状态（由武器元素在命中时施加，见 Content.ELEMENTS 与 World.damage_enemy）。
##
## 命名上刻意与上面那条**词缀** `burn` 分开：`burn` 是精英词缀「燃」（死亡爆火环），
## 这里用 `ignite_*` 表示**火元素**的灼烧。两者完全不同，别混。
var last_elem := ""         ## 最后被施加的元素 id（头顶刻字用）
var elem_t := 0.0           ## 头顶元素刻字的剩余时间
var ignite_t := 0.0         ## 火：灼烧剩余时间
var ignite_dps := 0.0       ## 火：灼烧每秒伤害
var ignite_tick := 0.0      ## 火：下一次结算的倒计时
var frozen_t := 0.0         ## 冰：冻结剩余时间（完全不能行动）
var venom_t := 0.0          ## 毒：中毒剩余时间
var venom_dps := 0.0        ## 毒：中毒每秒伤害
var venom_tick := 0.0       ## 毒：下一次结算的倒计时

## 无芯之暗：这只怪是从再生里站起来的（用来避免无限套娃）
var respawned := false

## 掉落的灯火是否已被取走（自检统计用）
var coin := 0


static func create(d: Dictionary, px: float, py: float, eid: int, is_elite := false) -> EnemyState:
	var e := EnemyState.new()
	e.def = d
	e.elite = is_elite
	e.id = eid
	e.x = px
	e.y = py
	e.hp = float(d["hp"])
	e.max_hp = e.hp
	e.r = float(d["r"])
	e.h = float(d["h"])
	e.coin = int(d["coin"])
	# wob 是敌人绕行（strafe）的相位：world.gd 里 `sin(e.t * 1.6 + e.wob)` 那两条
	# 直接把它加进 vx/vy —— 也就是说它**进仿真**，不只是画面。
	# 所以这里绝对不能用全局 randf()：那是未播种的全局 RNG，
	# 用它的话每一趟跑出来的世界都不一样，自检"连跑两遍 report.json 逐字节相同"
	# 这条立刻失效（症状很隐蔽：断言照样全绿，只有机器人试玩那段数值每次不同）。
	# 改成按 id 铺开：相邻的怪相位相差一个黄金角（≈137.5°），
	# 彼此不同、分布均匀，而且完全可复现。
	e.wob = fmod(float(eid) * 2.39996323, TAU)
	# 词缀字段由 Content.apply_affix 写进 def，这里取出来落成实例状态
	e.affix = str(d.get("affix", ""))
	e.affix_name = str(d.get("affix_name", ""))
	e.dr = float(d.get("dr", 0.0))
	e.ward_cd = float(d.get("ward_cd", 0.0))
	e.burn = float(d.get("burn", 0.0))
	e.drain = float(d.get("drain", 0.0))
	if e.ward_cd > 0.0:
		e.ward_t = e.ward_cd
	if str(d["behavior"]) == "boss":
		e.boss = {
			"action": "", "timer": 0.0, "cool": 0.8, "phase": 1,
			"tx": px, "ty": py, "dash_t": 0.0, "sweep_a": 0.0, "drain_t": 0.0,
			"slam_armed": false,
		}
	return e


func is_boss() -> bool:
	return str(def["behavior"]) == "boss"


func hp01() -> float:
	return clampf(hp / maxf(1.0, max_hp), 0.0, 1.0)


## 自身微光（黑暗里能看清它）
func light_radius() -> float:
	return float(def.get("light", 0.0))
