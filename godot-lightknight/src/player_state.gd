class_name PlayerState
extends RefCounted
## 玩家状态。字段与 Web 版 world.ts 里的 world.player 逐条对应。

var x := 0.0
var y := 0.0
var z := 0.0
var vx := 0.0
var vy := 0.0
var r := 17.0
var h := 44.0

var hp := 100.0
var max_hp := 100.0

var facing := 0.0
var attack_t := 0.0
var attack_cd := 0.0
var attack_alt := false
var wind_hold := 0.0     ## 蓄力（重武器前摇，仅用于表现）

var dash_t := 0.0
var dash_cd := 0.0
var dash_dx := 0.0
var dash_dy := 0.0

## 技能施法姿态：剩余时间（秒）与类别（spin/slam/thrust/toss/raise，见 Pose）。
## ⚠️ **纯表现**：只被绘制层读，不参与伤害、判定、连击或任何数值计算。
## 存在这里而不是 world，是为了让"世界推进"和"画出来"共用同一份状态 ——
## 分开存两份时间的话，暂停/冻结界面里两者会走散（本项目踩过这个坑）。
var cast_t := 0.0
var cast_kind := ""

var invuln := 0.0
var hurt_flash := 0.0

var combo := 0.0
var combo_timer := 0.0
var combo_peak := 0.0
var glow := 0.0
var walk_t := 0.0

var weapon_id := "blade"
var skill_cd := {}

var flurry := 0
var flurry_t := 0.0

## 灯杖·护光：护盾剩余时间（护盾期间免疫伤害，并把碰到你的敌人推开）
var shield_t := 0.0
## 灯镰·噬影：吸血窗口剩余时间与比例
var lifesteal_t := 0.0
var lifesteal_pct := 0.0

var revives := 0
var dead := false
var death_t := 0.0

## 统计（自检与结算用）
var hits_dealt := 0
var kills := 0


func weapon() -> Dictionary:
	return Content.WEAPONS.get(weapon_id, Content.WEAPONS["blade"])


func skills() -> Array:
	return weapon()["skills"]


func combo_int() -> int:
	return int(floor(combo))
