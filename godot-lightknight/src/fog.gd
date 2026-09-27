class_name Fog
extends Node2D
## Fog —— 迷雾层。需求：「给地图添加迷雾，灯照的地方迷雾会散去」。
##
## ── 为什么不用 Light2D 来"擦"雾 ──
## Godot 的 2D 光照只能把**被照到**的地方画出来（`LIGHT_MODE_LIGHT_ONLY`），
## 而雾要的正好相反：**没被照到**的地方才该有雾。
## 而 `Light2D.blend_mode = BLEND_MODE_SUB` 减的是 RGB，**不减 alpha**
## ——"用一盏负光在雾上挖洞"在 2D 里做不到（叠加层 Bloom 那套 ADD 同理，只有加法）。
## 所以这张雾是**自己算**的。
##
## ── 怎么算 ──
##   ① 屏幕切成 80×45 的小格（16px 一格），每格问一句"这里被照亮了多少"；
##   ② 照亮值 = max over 灯（径向衰减 × 视线有没有被墙挡住）；
##      ⚠️ 这两个因子在**两个不同的空间**里算，而且都必须那样算：
##        衰减按**地面**距离（灯贴图是竖压椭圆，地面等距才等亮）；
##        遮挡按**屏幕相对空间** `(x, y·YSQUASH − z)`（灯层的遮挡体就在那个空间里，
##        见 `LightRig.occluder_rect`）。竖直方向乘一个 `YSQUASH` 就是两套坐标的
##        全部分歧 —— 2026-09-27 之前这里两样都按地面算，于是"雾与墙不协调"。
##   ③ 写进一张 80×45 的贴图，交给一个全屏着色器：照亮值低的地方画成雾、
##      高的地方留空，再叠一层缓慢飘动的噪声当雾絮。
##
## 视线用**射线扇**，不逐格沿线采样：
##   每盏灯按 192 条射线做一次"射线 vs 墙矩形"求交，得到**每个角度上光最远到哪儿**；
##   于是格子只要比一下距离就够了。代价是 射线数×近处墙数（几百次求交/盏），
##   比"每格 × 步数"便宜两个数量级 —— 而且墙只有十几面。
##
## ── 三个刻意的设计决定 ──
##   ① **逐字走固定步长**（由 `World.step()` 调），不用 `_process`：
##      着色器里的雾絮时间也取自世界的 `time`，所以连"雾在飘"这件事都是可复现的。
##   ② **有开关**（`enabled`）：像素类断言要能把它关掉，否则"墙后到底暗不暗"
##      量到的是雾。与 HUD 那层暗角（`set_post_enabled`）是同一个道理。
##   ③ **只认"能开雾的灯"**：玩家灯 / 灯塔 / 火盆 / 攻击类灯 / 敌人自光。
##      太小的灯不开雾（否则雾面上全是针孔），盏数也有上限。
##
## ── 雾长在地图上（2026-09-27 用户需求）──
## 原话：「请让迷雾是地图本身的元素，不要跟着主角动」。
## 旧版噪声采样的是 `SCREEN_UV` —— **贴在屏幕上**，主角一走整片雾跟着镜头平移，
## 看着像"镜头前糊了一层灰纱"，而不是"这块地上有雾"。
## 现在雾纹只在**世界坐标**里存在（`cam_xy` / `view_w` / `ysquash` 把 SCREEN_UV
## 反解成地面点，见着色器里的推导）；同一张二维场喂给三个消费者：
## 照亮场（`_rebuild`）、高度场（`_bake_heights`）、雾纹（着色器）。
## 自检 ②f 就是量这件事：相机平移 Δ 后，**把 Δ 抵消掉**画面应逐字节相同
## （而"按屏幕对齐"那一版必须明显不同）—— 后者是它的反向对照。

## 照亮场分辨率。16px 一格：够糊，也够抠。每格 1 个 texel，
## 着色器用线性过滤把它插值开，所以看不见格子。
const GRID_W := 80
const GRID_H := 45
const GRID_N := GRID_W * GRID_H

## 射线条数。192 → 1.875°/条，半径 620 的那盏灯在弧上约 20px 一条，
## 落在雾的柔边里看不出来。
const RAYS := 192

## ⚠️ **这一层不再自己定遮挡几何**。旧版这里是 `WALL_PAD := 10.0`：
## 把墙的地面足迹往外胖一圈当遮挡矩形。那与灯层（`LightOccluder2D`，贴的是
## **画出来的轮廓**、底边削 16px 让墙脚受光）是两套完全不同的几何 —— 于是同一个
## 墙脚，灯说"亮"、雾说"全雾"（实测：墙南立面下 16px 那一带，灯层=亮 / 雾层 reveal=0.000，
## 而雾的揭开区要再往南 20px 才开始）。用户 2026-09-27 报的「雾与墙壁碰撞时的不协调」就是它。
## 现在两层同源（`LightRig.occluder_rect`）、同空间（屏幕相对空间）。
## 粗筛时才在包围盒上放宽一点，见 `_near_occluders()`。
const OCC_MARGIN := 8.0

## 重建间隔（秒）。雾不需要 60Hz，20Hz 又省 2/3 的算力。
const REBUILD_PERIOD := 0.05

## 没被照到时，雾**回填**的速度（每秒）。照亮是立刻的，回填是慢慢来的
## —— 这样"灯扫过去"会留下一道正在合拢的痕迹，像真的雾。
const REFILL := 1.6

## 开雾的灯数上限（按半径从大到小取）
const OPENER_MAX := 10
## 半径小于这个数的灯不开雾（敌人身上的小自光只是"透出一点亮"，不该整个散开）
const MIN_OPENER_R := 24.0

## 雾最浓时的 alpha。**这个数是量出来的**，不是猜的 —— 做法是"冻结世界、
## 同一帧只拧这一个 uniform"，逐像素上除雾浓之外没有第二个变量（取样见 README 二.14.3）。
## 取样块：一块没有 HUD、没有玩家光晕的地面（均值 42.5 / 局部对比度 3.90 / 基线即关雾）：
##
##   α      地面均值   局部对比度（vs 关雾）   与关雾图的高频相关性
##   0.30   57.1       3.05（78%）            0.96
##   0.40   62.1       2.78（71%）            0.93
##   0.45   64.6       2.67（68%）            0.91   ← 当前
##   0.50   67.1       2.54（65%）            0.87
##   0.60   72.0       2.38（61%）            0.79
##   0.70   76.9       2.28（58%）            0.68
##   1.00   91.2       2.21（57%）            0.23
##
## ⚠️ **后一列才是"地形还剩多少"的判据，前一列不是。** 局部对比度会被雾**自己的**
## 絮状纹理抬高：雾拉满（α=1.0）时它还剩 57%，看着好像"地形留了一半"，
## 其实那 57% 全是雾的絮 —— 与关雾图的高频相关性只有 **0.23**，地形边缘基本没了。
## 相关性是拿"雾开 / 雾关"两张图的**同一块高频分量**做的（雾关那张是基线的地形细节），
## 所以它只问一件事：**屏幕上这些细节里，有多少还是原来的地形**。
##
## ⚠️ 曲线**在 0.70 以上就是平的**：1.00 → 0.70 只买回 1% 的对比度、相关性也才 0.68，
## 均值却从 91 掉到 77（画面明显变暗）—— 等于"淡了但地形照样看不清"。
## 真正把地形找回来的是 **0.45~0.50** 这一档（相关性 0.87~0.91）。
## 所以"淡一点"必须淡过这个拐点才有意义 —— 拐点是量出来的，不是拍的。
##
## 这个数被用户拧过三轮，每一轮都留了代价：
##   ① 0.58（当时只有两层噪声）：没被照亮的地方是一整块灰板，地砖缝与墙轮廓全糊掉
##      —— 要的是"地图可见（但像晚上）"，不是"用雾把地图藏起来" → 降到 0.40。
##   ② 用户要**最浓** → 1.00。代价：灯照不到的地方地形基本看不见（相关性 0.23），
##      只有灯照的那一圈是清的（`KIND_SCALE.player = 0.82` 留了一圈柔边，
##      所以"雾退到哪儿为止"仍看得见）。
##   ③ 用户要"淡一点，让地形可见" → **0.45**：墙的轮廓与地砖缝重新读得出来（相关性 0.91），
##      而雾仍然明显（均值 64.6，是关雾的 1.5 倍）。
##
## ⚠️ `a *= mix(0.50, 1.25, n)` 那一步不能被去掉：没有噪声调制的话，整屏就是一块**平**色板；
## 有噪声才有 0.5~1.25 的厚薄差，看着才是"雾"而不是"墙"。
const MIST_MAX := 0.45

## 清关时"雾散尽"用的时间（秒）
const FADE_T := 1.2

# ================================================================ 高度与体积
#
# 需求：「迷雾还只是一层会飘的灰，没有高度和体积」。
#
# 原实现是一张**平的**全屏噪声：浓度只由「被照亮多少」决定，跟场景里任何东西的
# 高低都没关系 —— 所以一面 64px 的墙和它脚前的地面，被糊上**一样厚**的雾，
# 看上去就是一层挡在镜头前的灰纱，不是"空气里悬着的东西"。
#
# 这一版给雾装上三个互相独立的性质，每个都留了一个**只乘 alt** 的旋钮：
#
#   ① 高度：`alt` 是"这一像素看到的表面有多高"。雾沉在地面，
#      于是墙顶/石柱顶/灯塔顶上剩的雾明显更薄 —— 高的东西从雾里探出来。
#   ② 体积：雾是**两层**（贴地雾 + 浮雾），各自有自己的尺度与飘速；
#      表面越高，看到的越多是浮雾。再叠一层"图案锚在地面"的视差
#      （`sink`），所以同一片雾在墙面上会顺着高度滑动。
#   ③ 翻涌：噪声在**垂直**方向也动（两个不同频率的慢 sin），
#      不再只是"整块往东北平移"。
#
# ⚠️ 三个高度旋钮（height_fall / height_mix / height_parallax）都是 `× alt` 的形式，
# 于是**纯地面（alt = 0）上无论怎么拧，画面逐字节不变**。这不是巧合，是刻意设计的：
# 自检要证明"高度真的接在画面上"就得让旋钮转一下，而"转了但别处也该不动"这件事
# 必须有一个**精确**对照 —— alt = 0 就是这个对照。（同一个理由见类头 ②：量哪一层就把别层冻住。）

## 雾的"顶"（世界像素）。`alt = min(1, 表面高度 / FOG_TOP)`。
## 取 110 的理由：关内的墙大多 46~64 高（alt 0.42~0.58 → 雾只剩 5~6 成），
## 边界墙 64、石柱 66（0.6），而灯塔 200 会被夹到 1（塔身整根从雾里露出来）。
## 这是量出来的观感，不是拍的 —— 见 README 二.19。
const FOG_TOP := 110.0

## 高度场的格子边长（世界像素）。16 与照亮场同分辨率：雾本来就糊，再细是浪费。
const HCELL := 16.0
## 高度场往北多留的行数。一面墙的**屋顶**在屏幕上盖住的是它**北边**那条地面带
## （屋顶上边比地面足迹高 h/YSQUASH 个世界像素），不留这一段的话，地图最北边那圈
## 边界墙的屋顶会缺一块高度。FOG_TOP/YSQUASH/HCELL ≈ 11.1，取 12 行。
const H_PAD_ROWS := 12

## 越高越薄：alt = 1 时只剩 (1 - HEIGHT_FALL) 的雾。0.85 → 灯塔顶只剩 15%。
## 这一条是**物理**的（雾沉在下面），所以取值不需要商量 —— 实测屋顶的雾只剩地面的
## 0.637（= 1 − 0.85×0.418，与公式逐位吻合，见 README 二.19）。
const HEIGHT_FALL := 0.85
## 越高的表面，越多看到"浮雾"。`clamp(alt * HEIGHT_MIX, 0, 1)` 就是"多少比例是浮雾"。
##
## 1.2 → 46 高的墙一半浮雾、66 高的石柱 79%、到 **92px** 高才完全泡在浮雾里
## （比地图上除灯塔外的任何东西都高，所以全程不会顶到 clamp 的上限）。
## 这是**取过值**的：0.8 时那面墙上只有 1/3 是浮雾 —— 自检里"分层"那条旋钮
## 量出来只有 0.0038（三个旋钮里最弱，比"浓淡"那条弱 4 倍），肉眼也读不出"换了一层雾"。
## 1.2 之后到 0.0057 左右，与"视差"那条同量级（见 README 二.19 的剂量表）。
const HEIGHT_MIX := 1.20
## 图案锚在地面的视差强度（1.0 = 物理正确：表面高 z，图案就按 z 像素在屏幕上错开）
const HEIGHT_PARALLAX := 1.0
## 垂直翻涌强度
const MIST_BILLOW := 1.0

## 雾絮的尺度与漂速。**必须在这里也写一份并显式下发**（`_ready()` 里），
## 不能只靠着色器源码里的默认值 —— `ShaderMaterial.get_shader_parameter()` 对
## "从没被 set 过"的参数返回的是 **null**，不是着色器里那个默认值。
## 后果很隐蔽：读回来是 null（`float(null)` 直接报 "Nonexistent 'float' constructor"），
## 而且任何"先读出来、拧一下、再还原"的自检写法都会悄悄失效。
## 雾胞在**屏幕上**的边长（像素）= `Proj.VIEW_H / MIST_SCALE` = 720/13 ≈ **55px**
## （横竖都是 55：宽度 1280 与高度 720 的比值已经隐含在这个换算里了）。
## 着色器把它换算成"世界像素 → 雾图坐标"的速率，纵向额外除掉竖压 ——
## 世界 y 被压扁过，除掉之后雾胞在屏幕上才是圆的。
const MIST_SCALE := 13.0
## 漂速（噪声单位/秒）。换算到屏幕像素：贴地雾 ≈ 9px/s 向东北、浮雾 ≈ 23px/s 向东南
## （两层方向相反 → 看得出"不是一整块板在平移"）。
## **这个数是量过两版的**：0.022（≈1.2px/s）时基本读不出"在动"——盯着看十几秒
## 才挪一个雾胞（55px），于是有了需求「顺便让迷雾可以动」；0.16 之后 2 秒就能看出
## 雾纹明显换了位置（自检 ②e：2 秒窗的平均差 0.0026 → 0.0133，动了的像素 0.819 → 0.951）。
## ⚠️ 它与着色器里的默认值必须**两处同步**（见上面那条注释：`_ready()` 会用它
## 显式覆盖 uniform，所以真正生效的永远是**这里**）。
const MIST_SPEED := 0.16

## 每类灯"开雾半径"相对它自己光照半径的系数。
## 玩家灯 <1：让雾在光亮区的**边缘**留一圈，看得见"雾退到哪儿为止"。
## 敌人 <1：它那圈自光本身就得比"照亮地面"小一档，是"雾里透出一点亮"。
const KIND_SCALE := {
	"player": 0.82, "goal": 0.95, "brazier": 0.95, "fx": 0.85, "enemy": 0.65,
}

const SHADER_SRC := """
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D reveal_tex : filter_linear, repeat_disable, hint_default_black;
uniform vec4 mist_lo : source_color = vec4(0.16, 0.19, 0.27, 1.0);
uniform vec4 mist_hi : source_color = vec4(0.33, 0.38, 0.48, 1.0);
uniform float mist_max : hint_range(0.0, 1.0) = 0.45;
uniform float mist_time = 0.0;
uniform float mist_scale = 13.0;
uniform float mist_speed = 0.16;

// ── 高度 / 体积的旋钮 ──
// 前三个**只乘 alt**，所以纯地面（alt = 0）上无论怎么拧，画面逐字节不变 ——
// 自检里那三条"精确对照"就是这么来的（见 fog.gd 常量区的说明）。
uniform float height_fall : hint_range(0.0, 1.0) = 0.85;
uniform float height_mix : hint_range(0.0, 1.0) = 0.80;
uniform float height_parallax : hint_range(0.0, 2.0) = 1.0;
uniform float mist_billow : hint_range(0.0, 2.0) = 1.0;
uniform float height_top = 110.0;   // 世界像素：alt = min(1, 表面高度 / height_top)
uniform float view_h = 720.0;

// ── 世界锚定（"雾是地图的一部分"）──
// 噪声**不在屏幕空间采样**：`cam_xy` / `view_w` / `ysquash` 三个 uniform 把
// SCREEN_UV 反解成"这一像素朝下看、落在 z = 0 的那一点（世界像素）"。
// 验收见自检 ②f，说明见类头「雾长在地图上」那一段。
uniform vec2 cam_xy = vec2(0.0, 0.0);
uniform float view_w = 1280.0;
uniform float ysquash = 0.62;

// ── 照亮场的"时间锚定" ──
// 照亮场（reveal_tex）只在每 REBUILD_PERIOD 秒重算一次，中间那两三帧**是旧数据**。
// 但它的**语义**是世界锚定的（每一格问的是"它脚下的世界点被照亮多少"），
// 于是"旧数据"正确用法不是钉在屏幕上不动，而是**按相机位移挪回去再采**：
// 相机往东走 10px 之后，屏幕上第 590 列画的世界点，就是重建时第 600 列那一格。
// 少了这一下，影子的边界会"冻 3 帧、再窜一大步"—— 玩家看到的就是
// 「墙周围的阴影一直乱晃」（2026-09-27 用户反馈，探针实测：灯层边界相邻帧
// 偏差 0.50px、来回 0 次；雾层 1.65px、来回 30 次，而且抖动**全落在重建帧上**）。
uniform vec2 rebuild_cam = vec2(0.0, 0.0);

float h21(vec2 p) {
	p = fract(p * vec2(0.1031, 0.1030));
	p += dot(p, p.yx + 33.33);
	return fract((p.x + p.y) * p.x);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = mix(h21(i), h21(i + vec2(1.0, 0.0)), u.x);
	float b = mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), u.x);
	return mix(a, b, u.y);
}

void fragment() {
	// reveal_tex 两个通道都有用：R = 被照亮多少（0 = 全雾），
	// G = **这一像素看到的表面有多高**（0 = 地面，1 = 到雾顶）。
	//
	// ⚠️ 采样点**不是** `SCREEN_UV`：这张贴图是"重建那一刻"的屏幕快照，
	// 语义却是世界锚定的。相机在两次重建之间挪了多远，就把它挪回去多少
	// —— 推导见 `rebuild_cam` 上面的注释。少了这一下，影子的边界会
	// "冻几帧、再窜一步"，看着就是乱晃。
	vec2 ruv = SCREEN_UV + vec2(cam_xy.x - rebuild_cam.x,
		(cam_xy.y - rebuild_cam.y) * ysquash) / vec2(view_w, view_h);
	vec2 rp = texture(reveal_tex, ruv).rg;
	float reveal = rp.r;
	float alt = clamp(rp.g, 0.0, 1.0);

	// ── 雾长在**地图**上，不跟着主角走 ──
	// 投影是仿射的：sx = x − cam_x + VIEW_W/2、sy = (y − cam_y) × S − z + VIEW_H/2。
	// 于是"这一像素朝下看、落在 z = 0 的那一点"可以直接反解，而且 **cam 会自己消掉**：
	// 相机一动，同一个**世界点**算出来的 gw 不变 —— 雾纹于是钉在地图上。
	//
	// ⚠️ 之前这里是 `SCREEN_UV × mist_scale`：那一版雾纹是**贴在屏幕上**的，
	// 主角一走、镜头一动，整片雾就跟着镜头平移（用户报的"雾跟着主角动"）。
	// 现在它只是一张**世界空间的二维场**（与照亮场、高度场同一套坐标），
	// 时间那一项留给"风"：雾自己也飘，但那是地图上的雾在飘，不是镜头在拖动它。
	//
	// 表面高 z 的像素看到的是**它脚下那片地面**的雾：把采样点沿地面深度往南挪
	// z/S 世界像素（在屏幕上正好是往下 z 像素）。alt = 0 时这一项恰好是 0 ——
	// 平地不受它影响，自检拿它当**精确**对照（见常量区的说明）。
	float hz = height_parallax * alt * height_top;
	vec2 gw = vec2(SCREEN_UV.x * view_w - view_w * 0.5 + cam_xy.x,
		(SCREEN_UV.y * view_h - view_h * 0.5) / ysquash + cam_xy.y + hz / ysquash);

	// 世界像素 → 雾图坐标。屏幕上雾胞的边长固定是 `view_h / mist_scale` 像素
	// （13 → 55px，两个方向都是 55：横向不乘 1.78，是因为宽度 1280 与高度 720
	// 在 `mist_scale` 里已经隐含了这个比值），所以纵向要**除掉竖压** S ——
	// 世界 y 被压扁过，除掉之后雾胞在**屏幕上**才是圆的（老实现是屏幕空间，
	// 天然就圆；换成世界空间而不补这一下，雾胞会变成竖着的长条）。
	float cell1 = view_h / mist_scale;
	vec2 w1 = vec2(1.0 / cell1, ysquash / cell1);
	float cell2 = view_h / (mist_scale * 0.62);
	vec2 w2 = vec2(1.0 / cell2, ysquash / cell2);

	// 贴地雾：细、慢，主要往东北飘；另加一点缓慢的**垂直翻涌**
	//
	// ⚠️ 翻涌那两个系数（0.70 / 1.00）是**量出来的**，不是拍的：它们乘上雾胞尺度
	// 就是"雾纹在屏幕上上下挪多少像素"—— `0.70 × 55 ≈ 39px`（一个周期 37 秒）。
	// 第一版取 0.35（≈19px），自检里"推进时间后动了的像素"只有 9.6%，
	// 而且**肉眼基本看不出来**在翻涌；翻倍到 39px / 58px 之后才读得出来"雾是一团在呼吸的东西"。
	// 剂量-反应表见 README 二.19（`mist_billow` 拧 0 / 0.5 / 1.0 的量法）。
	vec2 q1 = gw * w1;
	q1 += vec2(mist_time * mist_speed, mist_time * mist_speed * 0.55);
	q1.y += sin(mist_time * 0.17) * 0.70 * mist_billow;
	float n1 = vnoise(q1) * 0.54 + vnoise(q1 * 2.3 + 11.0) * 0.31
		+ vnoise(q1 * 5.1 + 31.0) * 0.15;

	// 浮雾：更大一团、飘得更快、垂直分量明显 —— 与贴地雾不是同一张图
	vec2 q2 = gw * w2;
	q2 += vec2(mist_time * mist_speed * 1.6, -mist_time * mist_speed * 0.9);
	q2.y += sin(mist_time * 0.11 + 1.7) * 1.00 * mist_billow;
	float n2 = vnoise(q2) * 0.62 + vnoise(q2 * 2.7 + 7.0) * 0.38;

	// 看到的表面越高，越少"贴地雾"、越多"浮雾"（这就是"分层"）
	float n = mix(n1, n2, clamp(alt * height_mix, 0.0, 1.0));

	// 总量：雾沉在地面，越高越薄；到雾顶只剩 (1 - height_fall)
	float dens = mist_max * (1.0 - height_fall * alt);
	float a = dens * clamp(1.0 - reveal, 0.0, 1.0);
	// 噪声不只改浓度，也改"絮"的厚薄：低到 0.5、高到 1.25，才有飘动感
	a *= mix(0.50, 1.25, n);
	vec3 col = mix(mist_lo.rgb, mist_hi.rgb, n * n);
	COLOR = vec4(col, clamp(a, 0.0, 1.0));
}
"""

var world: World
## 迷雾开关。**像素类断言要能关掉它** —— 见类头注释 ②。
var enabled := true
var mat: ShaderMaterial

var _img: Image
var _tex: ImageTexture
## 照亮场：`_target` 是"这一刻应该多亮"，`_cur` 是"画面上现在多亮"（带回填滞后）
var _target := PackedFloat32Array()
var _cur := PackedFloat32Array()
var _step_x := 1.0
var _step_y := 1.0
var _acc := 0.0
var _rebuilds := 0
var _openers := []
## 每个屏幕格子"看到的表面有多高"（0..1），写进照亮场的 G 通道
var _alt := PackedFloat32Array()
## 世界空间高度场（一格 HCELL 世界像素）。**只烘一次**：墙和道具是静态的。
var _hgt := PackedFloat32Array()
var _hgw := 0
var _hgh := 0
## 高度场第 0 行对应的世界 y（是负的 —— 往北多留了 H_PAD_ROWS 行）
var _hg_oy := 0.0
## 射线扇缓存：同一盏灯（同一个位置、同一个半径）不必每帧重投
var _fan_cache := {}
## 上一次重建用的相机位置。着色器用它把"旧快照"挪回世界锚定（见 SHADER_SRC 里
## `rebuild_cam` 的推导）。**自检会核对它跟着重建走**。
var _rebuild_cam := Vector2.ZERO
var _mist := Color(0.16, 0.19, 0.27)
## 整体浓淡系数：清关时从 1 掉到 0（"这一关的雾散了"）
var _fade := 1.0
var _fade_target := 1.0


func _ready() -> void:
	_step_x = float(Proj.VIEW_W) / float(GRID_W)
	_step_y = float(Proj.VIEW_H) / float(GRID_H)
	_target.resize(GRID_N)
	_cur.resize(GRID_N)
	_alt.resize(GRID_N)
	# 起始状态：整屏都是雾（`_cur` = 0 = 揭示度 0 = 雾最浓）
	_img = Image.create(GRID_W, GRID_H, false, Image.FORMAT_RGBA8)
	_img.fill(Color(0.0, 0.0, 0.0, 1.0))
	_tex = ImageTexture.create_from_image(_img)
	var sh := Shader.new()
	sh.code = SHADER_SRC
	mat = ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("reveal_tex", _tex)
	mat.set_shader_parameter("mist_max", MIST_MAX)
	mat.set_shader_parameter("height_fall", HEIGHT_FALL)
	mat.set_shader_parameter("height_mix", HEIGHT_MIX)
	mat.set_shader_parameter("height_parallax", HEIGHT_PARALLAX)
	mat.set_shader_parameter("mist_billow", MIST_BILLOW)
	mat.set_shader_parameter("height_top", FOG_TOP)
	mat.set_shader_parameter("view_h", float(Proj.VIEW_H))
	# 世界锚定用的三个（`cam_xy` 每步都会重发，见 `sync()`）
	mat.set_shader_parameter("view_w", float(Proj.VIEW_W))
	mat.set_shader_parameter("ysquash", Proj.YSQUASH)
	mat.set_shader_parameter("cam_xy", Vector2.ZERO)
	# 这三个原本"只靠着色器默认值"（见 MIST_SCALE 的注释：不显式下发的话读回来是 null）
	mat.set_shader_parameter("mist_scale", MIST_SCALE)
	mat.set_shader_parameter("mist_speed", MIST_SPEED)
	mat.set_shader_parameter("mist_time", 0.0)      # 真正的值每 0.05s 由 `_rebuild()` 写
	material = mat


## 每关的雾色取自关卡表（`palette.mist`）—— 三张图的雾不是同一种颜色。
func setup(level: Dictionary) -> void:
	var pal: Dictionary = level.get("palette", {})
	_mist = Color.html(str(pal.get("mist", "#2b3448")))
	mat.set_shader_parameter("mist_lo", _mist)
	mat.set_shader_parameter("mist_hi", _mist.lerp(Color(1.0, 1.0, 1.0), 0.38))
	# 高度场在这里烘一次。**每关一次**，不是每帧 —— 墙与道具都是静态的。
	_bake_heights(level)


func set_enabled(on: bool) -> void:
	enabled = on
	visible = on


## 清关：把这一关的雾慢慢放掉（由 `World._on_boss_dead()` 调）。
func disperse() -> void:
	_fade_target = 0.0


## 反过来：让"已经散尽的雾"重新聚起来（重开同一关时用）。
## 没有它，`disperse()` 就是单向的 —— 自检验完"雾会散掉"之后没法把世界还原。
func reset_fade() -> void:
	_fade_target = 1.0


func fade() -> float:
	return _fade


## 这一关的雾色（取自 `palette.mist`）—— 自检拿它核对"雾色来自关卡表"。
func fog_color() -> Color:
	return _mist


## 浓淡系数的推进。**由 `World.tick_fx()` 调**，所以世界被面板冻住时它照样在散 ——
## 与"红闪衰减不跟着冻住"是同一个理由：这是给玩家看的反馈，不是世界状态。
func tick_fade(dt: float) -> void:
	if is_equal_approx(_fade, _fade_target):
		return
	var rate := 1.0 / FADE_T
	if _fade > _fade_target:
		_fade = maxf(_fade_target, _fade - rate * dt)
	else:
		_fade = minf(_fade_target, _fade + rate * dt)
	mat.set_shader_parameter("mist_max", MIST_MAX * _fade)


func rebuilds() -> int:
	return _rebuilds


func opener_count() -> int:
	return _openers.size()


func openers() -> Array:
	return _openers


# ---------------------------------------------------------------- 每步

## 由 `World.step()` 调用（固定步长）。dt 用于雾的回填速度。
##
## ⚠️ **不要**像 `LightRig` / `Bloom` 那样把 `position` 设成 `Proj.cam_offset(...)`。
## 那两层的局部坐标是"世界坐标投影过来的"（它们的子节点直接写世界坐标，只是 y 预乘了
## `YSQUASH`），而这一层**根本不使用世界坐标**：`_draw()` 画的是整屏矩形、着色器读的是
## `SCREEN_UV`、照亮场也是按屏幕格子铺的。它已经在屏幕空间里了，再叠一次 `cam_offset`
## 会把这块矩形搬到屏幕外 —— 症状很隐蔽：**只有约 53% 的屏幕被雾盖住**，
## 而且盖住的那部分还是照亮场的错位切片（"灯下雾散"看起来对不上灯）。
func sync(w: World, dt: float) -> void:
	if not enabled:
		return
	# ⚠️ **每一步**都要重发相机，不是等重建那一拍再发。雾纹现在是钉在世界上算的：
	# 相机在两次重建之间挪了一点，图案就得跟着挪那一点 —— 发晚了（比如塞进
	# `_rebuild` 里）镜头就会"拖着"雾走一帧，恰是这次要修掉的那种观感。
	mat.set_shader_parameter("cam_xy", w.draw_cam)
	_acc += dt
	if _acc < REBUILD_PERIOD:
		return
	var d := _acc
	_acc = 0.0
	_rebuild(w, d)


func _rebuild(w: World, dt: float) -> void:
	_rebuilds += 1
	if _fan_cache.size() > 64:
		_fan_cache.clear()
	var lx := PackedFloat32Array()
	var ly := PackedFloat32Array()
	var lr := PackedFloat32Array()
	var fans := []
	_collect_openers(w, lx, ly, lr, fans)
	_openers = []
	for k in lx.size():
		_openers.append({"x": lx[k], "y": ly[k], "r": lr[k]})

	var camx := w.draw_cam.x
	var camy := w.draw_cam.y
	var half_w := Proj.VIEW_W * 0.5
	var half_h := Proj.VIEW_H * 0.5
	var inv_squash := 1.0 / Proj.YSQUASH
	var n := lx.size()

	for j in GRID_H:
		# 屏幕 y → 地面世界 y（雾是按地面算的，不是按屏幕 —— 屏幕空间会把
		# 竖压后的椭圆算成斜的：同一盏灯在南北与东西方向上的边界就对不上了）
		var wy := (float(j) + 0.5) * _step_y
		wy = (wy - half_h) * inv_squash + camy
		var row := j * GRID_W
		for i in GRID_W:
			var wx := (float(i) + 0.5) * _step_x - half_w + camx
			# 这一格"看到的表面有多高"，先算出来 —— 它不依赖别的格。
			var alt := height_at(wx, wy)
			_alt[row + i] = alt
			# ⚠️ 这一格问灯的时候，**两个因子在两个空间里算**（两个都必须那样算）：
			#   ① 衰减要的是**地面距离**（灯贴图是竖压椭圆 → 地面等距才等亮）；
			#   ② 遮挡要的是**屏幕相对空间**的距离：竖直方向乘一个 YSQUASH。
			#      这不是近似 —— 屏幕相对坐标是 `(x, y·S − z)`，而"屏幕 y 落在这一格"
			#      的表面满足 `地面y = wy + z/S`，于是 `sr_y = (wy + z/S)·S − z = wy·S`：
			#      **z 自己消掉了**，任何高度的像素、它的屏幕相对 y 就是 `wy·S`。
			#      所以射线直接打到"这一像素"，不需要按高度挪。
			# 旧实现两样都按地面算（竖直方向少乘一个 S），于是墙脚那 16px
			# 灯层说亮、雾层说全雾 —— 正是用户报的「雾与墙不协调」。
			var best := 0.0
			for k in n:
				var ddx := wx - lx[k]
				var ddy := wy - ly[k]
				# ① 衰减：地面距离。**先用平方比**，免得给每格都白算一次 sqrt
				#    （这一层每步要跑 GRID_N × 灯数 次，实测 sqrt 是这里最贵的一步）。
				var rr := lr[k]
				var d2 := ddx * ddx + ddy * ddy
				if d2 >= rr * rr:
					continue
				var dd := sqrt(d2)
				# ② 遮挡：屏幕相对空间的距离（与灯层的遮挡体同空间）
				var sdy := ddy * Proj.YSQUASH
				var sd := sqrt(ddx * ddx + sdy * sdy)
				if sd > _fan_lookup(fans[k], ddx, sdy, sd):
					continue
				var v := 1.0 - dd / rr
				v = v * v * (3.0 - 2.0 * v)     # smoothstep：中心平、边缘柔
				if v > best:
					best = v
					if best >= 0.999:
						break
			_target[row + i] = best

	# 照亮立刻生效；没被照到的地方按 REFILL 慢慢合拢
	var k2 := REFILL * dt
	for i in GRID_N:
		var t := _target[i]
		var c := _cur[i]
		_cur[i] = t if t >= c else maxf(t, c - k2)

	for j in GRID_H:
		var row2 := j * GRID_W
		for i in GRID_W:
			var v2 := _cur[row2 + i]
			# R = 照亮（揭雾），G = 表面高度（雾的高度/体积就靠它）
			_img.set_pixel(i, j, Color(v2, _alt[row2 + i], 0.0, 1.0))
	_tex.update(_img)
	mat.set_shader_parameter("mist_time", w.time)
	# 这一次重建用的是哪台相机 —— 着色器靠它把"旧快照"挪回世界锚定（见 rebuild_cam）
	_rebuild_cam = Vector2(camx, camy)
	mat.set_shader_parameter("rebuild_cam", _rebuild_cam)


## 把「能开雾的灯」收集成扁平数组（避免每格去查字典）。
## 顺序按半径从大到小 —— 大灯先算，小的补细节；超过上限的直接不要。
func _collect_openers(w: World, lx: PackedFloat32Array, ly: PackedFloat32Array,
		lr: PackedFloat32Array, fans: Array) -> void:
	var rig: LightRig = w.light_rig
	if rig == null:
		return
	var picks := []
	for i in rig.source_count():
		var kind := rig.src_kind[i]
		var scale := float(KIND_SCALE.get(kind, 1.0))
		var rr := rig.src_r[i] * scale
		if rr < MIN_OPENER_R:
			continue
		picks.append([rr, kind, rig.src_x[i], rig.src_y[i], i, rig.src_z[i]])
	picks.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for k in mini(picks.size(), OPENER_MAX):
		var pk: Array = picks[k]
		var rr2 := float(pk[0])
		var cx := float(pk[2])
		var cy := float(pk[3])
		lx.append(cx)
		ly.append(cy)
		lr.append(rr2)
		# 射线扇在屏幕相对空间里投 —— 那里才是遮挡几何的空间
		# （灯层也是那个空间，见 `LightRig.occluder_rect` 的注释）。
		# `src_z` 必须一起带上：灯层的灯就是摆在 `y·S − z` 上的。
		fans.append(_fan_for("%s:%d" % [str(pk[1]), int(pk[4])],
			cx, cy * Proj.YSQUASH - float(pk[5]), rr2))


# ---------------------------------------------------------------- 高度场

## 世界空间高度场的缓存。同一关会被反复重建（自检里 `start_level()` 调很多次），
## 而墙和道具是静态的 —— 烘一次就够。键 = 关卡数据本身，值 = [格子, 宽, 高, 原点 y]。
static var _hcells := {}


## 把这一关的"高东西"烘成一张世界空间高度场：每格存
## **这一格地面深度上可见表面有多高 / FOG_TOP**（0 = 地面，1 = 到雾顶）。
##
## 为什么按"地面深度"而不是按屏幕：投影是
##     屏幕 y = (世界 y - 相机 y) * YSQUASH - z
## 一个屏幕像素对应的是**一条沿高度斜下去的线**，而"地面深度"是它落在 z=0 上的那个点。
## 于是"这一像素看到的表面有多高"变成了一个只跟世界有关的量 ——
## 可以**烘一次、与相机无关、与帧无关**。这也是它不放进 `_rebuild()` 的原因。
func _bake_heights(level: Dictionary) -> void:
	var lw := float(level.get("w", 2400.0))
	var lh := float(level.get("h", 1700.0))
	var key := "%s|%s|%s|%s" % [str(lw), str(lh), str(level.get("walls", [])),
		str(level.get("props", []))]
	var hit: Array = _hcells.get(key, [])
	if hit.is_empty():
		var gw := int(ceil(lw / HCELL)) + 2
		var gh := int(ceil(lh / HCELL)) + H_PAD_ROWS + 2
		var oy := -float(H_PAD_ROWS) * HCELL
		var prisms := _prisms(level)
		var grid := PackedFloat32Array()
		grid.resize(gw * gh)
		grid.fill(0.0)
		for j in gh:
			var wy := oy + (float(j) + 0.5) * HCELL
			var row := j * gw
			for i2 in gw:
				var wx := (float(i2) + 0.5) * HCELL
				var z := 0.0
				for pr in prisms:
					var zz := _prism_z(pr, wx, wy)
					if zz > z:
						z = zz
				grid[row + i2] = minf(1.0, z / FOG_TOP)
		hit = [grid, gw, gh, oy]
		_hcells[key] = hit
	_hgt = hit[0]
	_hgw = int(hit[1])
	_hgh = int(hit[2])
	_hg_oy = float(hit[3])


## 静态的"高东西" → 一根根长方体，用 [x0, y0, x1, y1, 高] 表示。
## 墙本来就是长方体（`Art.wall()` 画的正是南立面 + 屋顶）；道具（灯塔 / 石柱 /
## 雕像 / 树…）按半径当方足印 —— 雾本来就糊，圆与方在 16px 的格子上看不出差别。
func _prisms(level: Dictionary) -> Array:
	var out := []
	for wl in level.get("walls", []):
		out.append([float(wl[0]), float(wl[1]), float(wl[0]) + float(wl[2]),
			float(wl[1]) + float(wl[3]), float(wl[4])])
	var table: Dictionary = Content.PROP_TABLE
	for pr in level.get("props", []):
		var info: Dictionary = table.get(str(pr.get("kind", "")), {})
		if info.is_empty():
			continue
		var r := float(info.get("r", 12.0))
		var cx := float(pr.get("x", 0.0))
		var cy := float(pr.get("y", 0.0))
		out.append([cx - r, cy - r, cx + r, cy + r, float(info.get("h", 30.0))])
	return out


## 一根长方体在"地面深度 wy"处的可见表面高度。分两段，与 `Art.wall()` 画出来的
## 形状一一对应：
##   南立面：地面深度 [y1 - h/S, y1]，高度从 0 线性升到 h
##   屋顶：  再往北 h/S，即 [y0 - h/S, y1 - h/S]，高度恒为 h
## ⚠️ 屋顶落在**比墙的足迹更北**的地方 —— 这是投影的必然（墙往上长，在画面上
## 盖住的是它北边那条地面带），也正因为它会跑到 y<0，`H_PAD_ROWS` 那一段留白才必要。
func _prism_z(pr: Array, wx: float, wy: float) -> float:
	if wx < pr[0] or wx > pr[2]:
		return 0.0
	var h := float(pr[4])
	var y0 := float(pr[1])
	var y1 := float(pr[3])
	var s := Proj.YSQUASH
	if wy > y1:
		return 0.0
	if wy >= y1 - h / s:
		return (y1 - wy) * s
	if wy >= y0 - h / s:
		return h
	return 0.0


## 世界坐标上"可见表面多高 / FOG_TOP"（0 = 地面，1 = 到雾顶）。查烘好的那张表。
func height_at(x: float, y: float) -> float:
	if _hgt.is_empty():
		return 0.0
	var i := int(floor(x / HCELL))
	var j := int(floor((y - _hg_oy) / HCELL))
	if i < 0 or j < 0 or i >= _hgw or j >= _hgh:
		return 0.0
	return _hgt[j * _hgw + i]


func fog_top() -> float:
	return FOG_TOP


func height_cells() -> Vector2i:
	return Vector2i(_hgw, _hgh)


## 高度场缓存里有几关 —— 自检用它证明"烘一次、复用"这件事真的发生了。
func height_cache_size() -> int:
	return _hcells.size()


# ---------------------------------------------------------------- 射线扇

func _fan_for(key: String, sx: float, sy: float, radius: float) -> PackedFloat32Array:
	var c: Dictionary = _fan_cache.get(key, {})
	if not c.is_empty() \
			and is_equal_approx(float(c["x"]), sx) \
			and is_equal_approx(float(c["y"]), sy) \
			and is_equal_approx(float(c["r"]), radius):
		return c["fan"]
	var fan := _cast_fan(sx, sy, radius)
	_fan_cache[key] = {"x": sx, "y": sy, "r": radius, "fan": fan}
	return fan


## 一盏灯朝 RAYS 个方向各投一条射线，得到"这个角度上光最远到哪儿"。
##
## ⚠️ 入参是**屏幕相对空间**的灯位（`x` = 世界 x，`y` = 世界 y·YSQUASH）——
## 因为矩形来自 `LightRig.occluder_rect()`，灯层的 `LightOccluder2D` 用的就是它。
## 这个函数（连同它的缓存）**与相机无关**：几何在屏幕相对空间里是静态的，
## 相机只挪整块画布。所以同一盏灯的扇形可以一直复用。
func _cast_fan(sx: float, sy: float, radius: float) -> PackedFloat32Array:
	var fan := PackedFloat32Array()
	fan.resize(RAYS)
	var rects := _near_occluders(sx, sy, radius)
	for i in RAYS:
		var a := TAU * float(i) / float(RAYS)
		var dx := cos(a)
		var dy := sin(a)
		var best := radius
		for rc in rects:
			var t := Proj.ray_rect_dist(sx, sy, dx, dy,
				rc.position.x, rc.position.y, rc.size.x, rc.size.y)
			if t >= 0.0 and t < best:
				best = t
		fan[i] = best
	return fan


## 粗筛：只把（包围盒放宽一圈后）和这盏灯有交集的遮挡矩形留下。墙只有十几面，
## 但一帧要投十几盏灯的射线，这一步能省掉大半。
func _near_occluders(sx: float, sy: float, radius: float) -> Array:
	var out := []
	var r := radius + OCC_MARGIN
	for wl in world.walls:
		var rc := LightRig.occluder_rect(float(wl[0]), float(wl[1]),
			float(wl[2]), float(wl[3]), float(wl[4]))
		if rc.position.x > sx + r or rc.position.x + rc.size.x < sx - r:
			continue
		if rc.position.y > sy + r or rc.position.y + rc.size.y < sy - r:
			continue
		out.append(rc)
	return out


## 在扇形上按角度插值取"这个方向的最远距离"。
static func _fan_lookup(fan: PackedFloat32Array, dx: float, dy: float, d: float) -> float:
	if d <= 0.0001 or fan.is_empty():
		return 1.0e30
	var a := atan2(dy, dx)
	if a < 0.0:
		a += TAU
	var f := a / TAU * float(RAYS)
	var i := int(f) % RAYS
	var j := (i + 1) % RAYS
	return lerpf(fan[i], fan[j], f - float(i))


# ---------------------------------------------------------------- 查询（自检用）

## 世界坐标 → 网格索引
func grid_of(x: float, y: float) -> Vector2i:
	var sx := x - world.draw_cam.x + Proj.VIEW_W * 0.5
	var sy := (y - world.draw_cam.y) * Proj.YSQUASH + Proj.VIEW_H * 0.5
	return Vector2i(
		clampi(int(sx / _step_x), 0, GRID_W - 1),
		clampi(int(sy / _step_y), 0, GRID_H - 1))


## 这一刻"应该"被照亮多少（0 = 全雾，1 = 无雾）。不含回填滞后。
func target_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	return _target[g.y * GRID_W + g.x]


## 画面上"现在"被照亮多少（含回填滞后）。
func reveal_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	return _cur[g.y * GRID_W + g.x]


## 这一格"看到的表面有多高"（0..1）—— 也就是写进照亮场 G 通道的那个值。
## 自检用它核对"高度真的从世界进了贴图"（与 `height_at` 是两层：
## 前者是世界空间的真值，后者是屏幕上那一格实际拿到的数）。
func alt_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	return _alt[g.y * GRID_W + g.x]


## **贴图里**那一格的 G 通道（0..1）。与 `alt_at()` 是两回事：那个读的是 GDScript
## 里的 `_alt` 数组，**已经算过但还没写进 GPU 也会照常返回真值**。
##
## ⚠️ 这条是**变异测试逼出来的**：原来那条"高度真的进了 G 通道"的断言用的就是
## `alt_at()` —— 于是把 `_img.set_pixel(...)` 的 G 通道改成恒 0（高度整条链在 GPU
## 那侧断掉）之后，它照样绿。断言**问错了地方**：它问的是"GDScript 算没算"，
## 而不是"贴图里有没有"。现在这里真的去读 `_img` 的像素。
func alt_tex_at(x: float, y: float) -> float:
	var g := grid_of(x, y)
	# 向**渲染服务器**要回贴图内容（`ImageTexture.get_image()` 是真的回读），
	# 读不到才退回 CPU 侧的 `_img` —— 于是"算了但没 `update()` 上去"也会被抓住。
	var back := _tex.get_image()
	var im: Image = back if back != null else _img
	return im.get_pixel(g.x, g.y).g


func grid_target_copy() -> PackedFloat32Array:
	return _target


## 上一次重建用的相机位置（着色器把旧快照挪回世界锚定时用的就是它）
func rebuild_cam_xy() -> Vector2:
	return _rebuild_cam


func grid_cur_copy() -> PackedFloat32Array:
	return _cur


func _draw() -> void:
	# 一整块屏幕大小的矩形；颜色由着色器完全接管（见 SHADER_SRC 的 COLOR = ...）。
	draw_rect(Rect2(0.0, 0.0, Proj.VIEW_W, Proj.VIEW_H), Color.WHITE)
