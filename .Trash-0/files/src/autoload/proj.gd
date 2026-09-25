extends Node
## Proj —— 数学、2.5D 斜投影、碰撞。
## 与 Web 版 src/core/utils.ts 一一对应，常量保持一致。
##
## 坐标约定（与 Web 版相同）：
##   x 向右，y 向"下/远"（俯视平面地面坐标），z 向上（高度）。
##   屏幕 y = (世界 y - 相机 y) * YSQUASH - z + H/2
## 这条"斜轴测"投影就是 2.5D 观感的来源：地面被压扁，物体按高度立起来。

const YSQUASH := 0.62
const VIEW_W := 1280
const VIEW_H := 720
const TAU_F := TAU

# ---------------------------------------------------------------- 投影

func sx(x: float, cam_x: float) -> float:
	return x - cam_x + VIEW_W * 0.5


func sy(y: float, z: float, cam_y: float) -> float:
	return (y - cam_y) * YSQUASH - z + VIEW_H * 0.5


## 屏幕坐标 → 地面世界坐标（z 视为 0）
func screen_to_world_y(my: float, cam_y: float) -> float:
	return (my - VIEW_H * 0.5) / YSQUASH + cam_y


## 相机偏移：把世界原点映射到屏幕上的位置。供"屏幕相对坐标"的容器使用。
func cam_offset(cam_x: float, cam_y: float) -> Vector2:
	return Vector2(VIEW_W * 0.5 - cam_x, VIEW_H * 0.5 - cam_y * YSQUASH)


# ---------------------------------------------------------------- 数学

## 帧率无关的指数趋近
func damp(a: float, b: float, rate: float, dt: float) -> float:
	return lerp(a, b, 1.0 - exp(-rate * dt))


func dist(ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	return sqrt(dx * dx + dy * dy)


func dist2(ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	return dx * dx + dy * dy


func angle_to(ax: float, ay: float, bx: float, by: float) -> float:
	return atan2(by - ay, bx - ax)


## 归一化到 [-PI, PI] 的角度差
func angle_diff(a: float, b: float) -> float:
	var d := fmod(b - a, TAU)
	if d > PI:
		d -= TAU
	if d < -PI:
		d += TAU
	return d


## 确定性随机（关卡布局与战斗抖动都用它，保证可复现）
func make_rng(seed_v: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	return r


# ---------------------------------------------------------------- 碰撞
# 世界平面上的圆 vs 轴对齐矩形。与 Web 版 pushOutRect 同算法。

func circle_rect(cx: float, cy: float, r: float, rx: float, ry: float, rw: float, rh: float) -> bool:
	var nx := clampf(cx, rx, rx + rw)
	var ny := clampf(cy, ry, ry + rh)
	var dx := cx - nx
	var dy := cy - ny
	return dx * dx + dy * dy < r * r


## 把圆推出矩形；圆心在矩形内部时朝最近的边推出。
func push_out_rect(cx: float, cy: float, r: float, rx: float, ry: float, rw: float, rh: float) -> Vector2:
	var nx := clampf(cx, rx, rx + rw)
	var ny := clampf(cy, ry, ry + rh)
	var dx := cx - nx
	var dy := cy - ny
	var d := sqrt(dx * dx + dy * dy)
	if d > r:
		return Vector2(cx, cy)
	if d < 0.0001:
		var dl := cx - rx
		var dr := rx + rw - cx
		var dt_ := cy - ry
		var db := ry + rh - cy
		var m: float = min(min(dl, dr), min(dt_, db))
		if m == dl:
			return Vector2(rx - r, cy)
		if m == dr:
			return Vector2(rx + rw + r, cy)
		if m == dt_:
			return Vector2(cx, ry - r)
		return Vector2(cx, ry + rh + r)
	dx /= d
	dy /= d
	return Vector2(nx + dx * r, ny + dy * r)


# ---------------------------------------------------------------- 颜色

func col(hex: String, a := 1.0) -> Color:
	var c := Color.html(hex)
	c.a = a
	return c


## 在色相上做轻微抖动，避免程序化美术过于平板
func shade(c: Color, f: float) -> Color:
	return Color(clampf(c.r * f, 0.0, 1.0), clampf(c.g * f, 0.0, 1.0), clampf(c.b * f, 0.0, 1.0), c.a)


func lerp_col(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, clampf(t, 0.0, 1.0))
