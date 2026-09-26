class_name Pose
extends RefCounted
## Pose —— 角色**姿态求解器**。放下全部绘制，只回答"这一刻身体各部位在什么角度"。
##
## 为什么抽成一个文件、而且全是 static 纯函数：
## 动画"对不对"有三条其实是**数学命题**，不是审美问题 ——
##   ① 关节真的在转（局部角在变），而不是整个身体平移（那只是"贴图在滑"）；
##   ② 相位关系对：两条腿必须**反相**（对侧步态），空手臂与**同侧**腿反相；
##   ③ 速度剖面对：挥出的**峰值**角速度要远大于前摇，且挥出**末尾趋零** ——
##      打击感来自那个急停，不是来自"挥得快"。
## 把姿态从 `_draw` 里抽出来，这三条就能直接写成断言；
## 混在绘制代码里就只能靠像素采样去猜，错了也说不清是哪一层错的。
##
## 硬约束：**纯函数**（同输入同输出）、**不碰 RNG**、不读时间墙、不改任何状态。
## `_draw` 每帧都会调这里，一旦它消耗了随机流，整个工程的可复现性就毁了。

## 普通攻击的总时长。
## ⚠️ 必须与 world.gd 里 `p.attack_t = 0.2` 一致 —— 自检里有一条断言专门核对这个
## （只改一边的话，"攻击进度"就会算成另一条曲线，而画面照样能跑）。
const ATTACK_DUR := 0.2

## 站定与全速之间：速度低于这个值算站定，高于 LO 算全速。
## ⚠️ 门槛必须与 world.gd 里推进 `walk_t` 的条件一致
## （`if absf(p.vx) + absf(p.vy) > 30.0: p.walk_t += dt * 11.0`），
## 而且用的是**同一种度量**（曼哈顿，不是欧氏）——否则"在动"和"腿在摆"会各说各话。
const MOVE_LO := 30.0
const MOVE_HI := 120.0

## 腿的髋摆幅（弧度）。在 2.5D 侧视下这是**屏幕空间**的角度。
const HIP_AMP := 0.62
## 上下起伏的高度（像素）
const BOB_H := 2.6
## 落地压扁的比例（0.045 = 最扁时矮 4.5%）
const SQUASH := 0.045


# ---------------------------------------------------------------- 缓动
# 只留这三条：它们不是"随便挑个好看的曲线"，各自对应一个具体的手感 ——
# 前摇要 ease_in_out（拉弓：慢起慢停），挥出要 ease_out_quint（起步即最高速、
# 末尾拖长减速 = 急停），收势要 ease_out_cubic。

static func ease_in_out(x: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


static func ease_out_cubic(x: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return 1.0 - pow(1.0 - u, 3.0)


static func ease_out_quint(x: float) -> float:
	var u := clampf(x, 0.0, 1.0)
	return 1.0 - pow(1.0 - u, 5.0)


# ---------------------------------------------------------------- 朝向

## 地面角度 → 屏幕角度。
## 地面被 YSQUASH 压扁过，同一组"地面方向"投到屏幕上角度会变（正面视角下
## 甚至完全相同），不换算的话武器会指着屏幕外、和地面上那道挥击弧对不上。
static func face_angle(facing: float, ysquash: float) -> float:
	return atan2(sin(facing) * ysquash, cos(facing))


# ---------------------------------------------------------------- 走路

## "在动程度"：0 = 站定，1 = 全速。
## 站定时两条腿会**收回中立位**（而不是僵在某个相位上）—— 这也是它乘进
## 每一个摆幅的原因。
static func move01(p: PlayerState) -> float:
	var sp := absf(p.vx) + absf(p.vy)     # 曼哈顿，与 world 的门槛同一种度量
	return clampf((sp - MOVE_LO) / (MOVE_HI - MOVE_LO), 0.0, 1.0)


## 走路循环的姿态。相位用 `p.walk_t`（由 world 推进，站定时冻结）。
##
## 返回的键（全部是**屏幕空间**的量）：
##   hip / hip_b   两条腿的髋角（弧度，正 = 向前摆）
##   knee_a / knee_b  屈膝量（0..1，后摆那半程才屈 —— 抬脚）
##   arm_free      空手臂的摆角
##   bob           上下起伏（像素）
##   squash        竖直缩放（<1 = 被压扁，落地那一下）
##   lean / sway   躯干前倾 / 侧倾（弧度）
##   cloak         斗篷下摆的横向摆动量（像素）
##   move          在动程度（0..1），画手可以用它做"静止时收拢"的过渡
static func walk(p: PlayerState) -> Dictionary:
	var m := move01(p)
	var ph := p.walk_t
	var s := sin(ph)
	var c := cos(ph)

	var hip := s * HIP_AMP * m
	# ⚠️ 两条腿**严格反相**：不是"看起来差不多反"，而是 hip_b == -hip。
	# 自检直接断言 `hip + hip_b == 0`；一旦有人给某条腿单独加个偏移，
	# 那条断言立刻红 —— 这正是"对侧步态"这个约束该有的护栏。
	var hip_b := -hip

	# 屈膝只在**后摆**那半程（抬脚），前摆时腿是伸直的
	var knee_a := maxf(0.0, -s) * 0.9 * m
	var knee_b := maxf(0.0, s) * 0.9 * m

	# 空手臂与**同侧**腿反相（标准步态：右手前摆时右腿后蹬）
	var arm_free := -hip * 0.68

	# 上下起伏：一个相位两个波峰，与落脚同拍
	var bob := absf(s) * BOB_H * m
	# 落地压扁：最低点（|sin| = 0）最扁。**这是"重量"的来源** ——
	# 少了它，角色看起来像气球在飘。
	var squash := 1.0 - (1.0 - absf(s)) * SQUASH * m

	# 躯干：基础前倾 + 每步一次的颠簸（双频）
	var lean := 0.055 * m + sin(ph * 2.0) * 0.022 * m
	# 侧倾：重心左右移动，与腿同相
	var sway := c * 0.05 * m
	# 斗篷下摆：**半频**（布料惯性，比脚步慢），原地站着也在轻微呼吸
	var cloak := sin(ph * 0.5 + 0.4) * (1.8 + 5.2 * m)

	# 冲刺：整体前倾、腿收起来 —— 覆盖走路的观感（冲刺本身是另一套动作）
	if p.dash_t > 0.0:
		lean += 0.17
		bob += 3.0
		hip = hip * 0.35
		hip_b = -hip
	# 受击：向后仰 + 抖动（抖动频率是定值，不碰 RNG）
	if p.hurt_flash > 0.0:
		lean -= 0.13
		sway += sin(p.hurt_flash * 62.0) * 0.055

	return {
		"hip": hip, "hip_b": hip_b,
		"knee_a": knee_a, "knee_b": knee_b,
		"arm_free": arm_free,
		"bob": bob, "squash": squash, "lean": lean, "sway": sway,
		"cloak": cloak, "move": m,
	}


# ---------------------------------------------------------------- 普通攻击（武器挥舞）

## 武器挥舞的姿态。返回 ang / ext / lean / dir / phase / v。
##
## `t01`   攻击进度 0 → 1（= 1 - attack_t / ATTACK_DUR）
## `style` 武器手感（slash / thrust / whip / smash），来自 Content.WEAPONS
## `arc`   这把武器的挥击弧度（rad），决定扫过多少
## `wind`  这把武器的前摇（秒），决定前摇占整段的**比例**
## `alt`   左右交替（`p.attack_alt`，每次出手翻转）—— 连续攻击会左右开弓
## `base`  屏幕上这一下的基准朝向角（调用方用 face_angle 换算）
##
## ⚠️ 这里**只改表现**：`wind` 只用来切分这 0.2 秒，不改变攻击时长，
## 所以伤害判定、连击计时、机器人通关节奏**一点都没动**。
static func swing(style: String, arc: float, wind: float, t01: float,
		alt: bool, base: float) -> Dictionary:
	var t := clampf(t01, 0.0, 1.0)
	# 前摇占比：重武器（wind 0.24）占 55%，轻的（0.06）占 15%。
	# 上下都夹住了 —— 万一表里填了个离谱的数，曲线也不会退化成"没有前摇"或"不挥"。
	var wf := clampf(wind / ATTACK_DUR, 0.15, 0.55)
	var dir := -1.0 if alt else 1.0
	var span := maxf(arc, 0.30)
	var pull := span * 0.45        # 后拉量：把武器拉**出弧外**蓄势，扫回来才有行程

	# 每种武器的"手感"：挥砍靠扫（角主导），突刺靠推（伸展主导），
	# 锁链甩出去（伸展大 + 带波动），重锤抡（角度放大），
	# 弩几乎不扫（端着射，只有一点后坐），杖是"举起来指"。
	var ang_gain := 1.0
	var ext_gain := 1.0
	match style:
		"thrust":
			ang_gain = 0.25
			ext_gain = 1.50
		"whip":
			ang_gain = 0.55
			ext_gain = 1.40
		"smash":
			ang_gain = 1.25
			ext_gain = 0.85
		"shot":
			ang_gain = 0.12      # 弩是端平的，不该横扫
			ext_gain = 0.30      # 那点动作是后坐
		"cast":
			ang_gain = 0.75
			ext_gain = 1.15
		_:
			pass    # slash：标准横扫

	var a_start := (span * 0.5 + pull) * dir * ang_gain    # 起手（在弧外）
	var a_end := (-span * 0.5) * dir * ang_gain            # 收手（在弧的另一端）

	var ang_rel := 0.0
	var ext := 0.0
	var lean := 0.0
	var phase := 0          # 0 = 前摇，1 = 挥出（给画手和自检一个明确的段标记）
	var v := 0.0

	if t <= wf:
		# ── 前摇：从静止位拉到起手位。ease_in_out = 慢起慢停（像拉弓）
		var u := t / maxf(wf, 1e-6)
		var e := ease_in_out(u)
		ang_rel = lerp(0.0, a_start, e)
		ext = lerp(0.0, -0.20, e)        # 手往回收一点
		lean = lerp(0.0, -0.07, e)       # 上身后仰蓄力
	else:
		# ── 挥出：从起手位扫到收手位。
		# ⚠️ ease_out_quint 是这一整套动画里最关键的选择：
		#   起步瞬间速度最大、末尾速度趋零 —— 平均速度并不比前摇高多少，
		#   但**峰值**高得多、而且**末尾是急停**。打击感全在这个急停上。
		#   换成 ease_in_out（对称的）会立刻"软"下来，像在打太极。
		v = (t - wf) / maxf(1.0 - wf, 1e-6)
		var e := ease_out_quint(v)
		ang_rel = lerp(a_start, a_end, e)
		ext = lerp(-0.20, ext_gain, ease_out_cubic(v))
		lean = lerp(-0.07, 0.11, ease_out_cubic(v))
		phase = 1

	return {
		"ang": base + ang_rel,
		"ang_rel": ang_rel,
		"ext": ext,
		"lean": lean,
		"dir": dir,
		"phase": phase,
		"v": v,
	}


# ---------------------------------------------------------------- 技能施放

## 技能姿态的类别。**由技能 id 推出来**（`cast_kind_of`），
## 所以加新技能时不用来改这里 —— 起手字对得上就自动归类。
const CAST_KINDS := ["spin", "slam", "thrust", "toss", "raise"]


## 技能 id → 姿态类别。前缀匹配，认不出来就 `raise`（最普通的"举手放光"）。
static func cast_kind_of(skill_id: String) -> String:
	if skill_id.contains("whirl") or skill_id.contains("spin") or skill_id.contains("reap"):
		return "spin"        # 回身一周
	if skill_id.contains("burst") or skill_id.contains("quake") or skill_id.contains("meteor"):
		return "slam"        # 下砸 / 引爆
	if skill_id.contains("lunge") or skill_id.contains("flurry") \
			or skill_id.contains("pierce") or skill_id.contains("crescent") \
			or skill_id.contains("volley") or skill_id.contains("rain"):
		return "thrust"      # 突进 / 连刺 / 齐射
	if skill_id.contains("hook") or skill_id.contains("orb"):
		return "toss"        # 抛出去
	return "raise"


## 技能姿态。`t01` = 施法进度 0 → 1（= 1 - cast_t / CAST_DUR）。
##
## 返回（全部是"相对站姿"的偏量）：
##   arm   持械手的抬举角（+ 举高 / − 压低）
##   off   持械手的水平偏置（像素，+ 向前）
##   lean  躯干前倾（弧度）
##   spin  整体转身（弧度，只有回身类非零）
##   ext   武器沿自身方向的伸展（突刺/抛掷用）
##   rush  整体向前的位移（像素，突进类用）
static func cast(kind: String, t01: float) -> Dictionary:
	var t := clampf(t01, 0.0, 1.0)
	# 三段：起手（0 → 0.30，沉一下）→ 放出（0.30 → 0.62，最快的部分）
	# → 收势（0.62 → 1.0，动作回落）。收势必须是**独立的一段**，
	# 否则技能一放完人就"啪"地弹回站姿，看着像掉帧。
	var up := ease_in_out(t / 0.30)
	var burst := ease_out_quint(clampf((t - 0.30) / 0.32, 0.0, 1.0))
	var settle := 1.0 - ease_out_cubic(clampf((t - 0.62) / 0.38, 0.0, 1.0))

	# 包络：起手到 1、收势回到 0，中间保持
	var amp := minf(up, settle)

	var arm := 0.0
	var off := 0.0
	var lean := 0.0
	var spin := 0.0
	var ext := 0.0
	var rush := 0.0

	match kind:
		"spin":
			# 回身：原地转一整圈。⚠️ 用 2π 是为了"转回原朝向"，
			# 用 ease_out_cubic 让转速递减（起手快、收尾慢），停在正面。
			spin = TAU * ease_out_cubic(t) * amp
			arm = -0.85 * amp
			lean = 0.05 * amp
		"slam":
			# 下砸：先高举过头（back 越大举得越高），再砸下去
			arm = lerp(1.30 * up, -0.90, burst) * settle
			lean = lerp(-0.13 * up, 0.22, burst) * settle
			off = 6.0 * burst * settle
		"thrust":
			# 突进：身体前压、手推出去、整个人往前蹿一小步
			arm = 0.18 * amp
			ext = 1.55 * burst * settle
			lean = 0.16 * burst * settle
			rush = 13.0 * burst * settle
		"toss":
			# 抛掷：手先收到身侧再甩出去（过顶弧）
			arm = lerp(-0.35 * up, 1.45, burst) * settle
			off = 4.0 * amp
			lean = lerp(0.05 * up, -0.10, burst) * settle
		_:
			# raise：双手上举放光（护持 / 增益 / 认不出来的技能）
			arm = 1.15 * amp
			lean = -0.07 * amp
			off = 2.0 * amp

	return {"arm": arm, "off": off, "lean": lean, "spin": spin,
		"ext": ext, "rush": rush, "amp": amp, "kind": kind}


## 施法总时长（秒）。比一次普通攻击长 —— 技能要有"起手—放出—收势"的余地。
const CAST_DUR := 0.62
