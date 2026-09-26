class_name WindowMode
extends RefCounted
## F11 全屏的**决策**。纯逻辑 —— 自己不碰窗口，只回答"该切到哪个模式、该不该设尺寸"。
##
## 为什么把决策拆出来：本机（XWayland）实测有一条**时序陷阱** ——
## 调 `window_set_mode(WINDOWED)` 之后，窗口尺寸在**当帧**还报着全屏的尺寸
## （实测 2560×1600），要到**下一帧**才被 WM 改成它自己的主意（实测 1270×1528）。
## 于是"切模式 + 立刻 set_size"这种最自然的写法，那次 set_size 会被整个吃掉，
## 退出全屏得到的是一个 1270×1528 的陌生窗口。实测三种写法：
##
## | 写法                        | 退出全屏后的尺寸      |
## |-----------------------------|-----------------------|
## | 同一步里连着设（朴素）        | ❌ 1270×1528          |
## | `set_size.call_deferred`     | ❌ 1270×1528（同帧，照样被吃）|
## | 等落定之后再设                | ✅ 1280×720           |
##
## 窗口操作没法在断言里反复做，所以"什么时候该设、设多少、设几次"全做成纯状态机，
## 断言逐条钉它；真窗口只在自检最后端到端验一次（见 selfcheck 的全屏段）。

## 退出全屏后先等几步再动尺寸 —— 等 WM 把窗口模式真正落定。
## 实测 1 帧就够（本机 WM 在第一帧就把尺寸换成了它自己的），这里留成 6 步（0.1 秒）余量。
const RESTORE_DELAY := 6
## 尺寸设上去之后**每步核对一次**，对不上就再设 —— 上限这么多步。
## 单设一次有可能被 WM 吃掉；连设是安全的（实测补设三次与设一次结果相同），
## 而"直到真的对上为止"比"设一次就赌"稳。
const MAX_TRIES := 10

## 进全屏之前的窗口模式（退出时按它还原）
var saved_mode := DisplayServer.WINDOW_MODE_WINDOWED
## 进全屏之前的窗口尺寸
var saved_size := Vector2i.ZERO
## 待还原的尺寸（ZERO = 没有待办）
var pending := Vector2i.ZERO
## 还要先等几步（等窗口模式落定）
var left := 0
## 已经重试了几次
var tries := 0
## 一共按过几次 F11（自检用来核对"键真的被采样到了"）
var toggles := 0


## 全屏的两种模式都算全屏。**只认 `WINDOW_MODE_FULLSCREEN` 是错的** ——
## 那样窗口如果是独占全屏（EXCLUSIVE_FULLSCREEN），F11 会以为"现在不是全屏"
## 而再进一次全屏，玩家就再也退不出来了。
static func is_fullscreen(mode: int) -> bool:
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## 按下 F11：返回**该切到哪个窗口模式**。调用方负责真正下发 —— 本函数只算不做。
func press(cur_mode: int, cur_size: Vector2i) -> int:
	toggles += 1
	if is_fullscreen(cur_mode):
		# 退出全屏：还原成"进之前那个模式和尺寸"。
		var want := pending if pending.x > 0 else saved_size
		# 但要还原成**最大化**时就不要设尺寸了：最大化窗口的尺寸由 WM 说了算，
		# 硬设一个会把窗口从最大化里"拽"出来（还可能拽成退出全屏那一帧那个陌生尺寸）。
		if saved_mode == DisplayServer.WINDOW_MODE_MAXIMIZED:
			want = Vector2i.ZERO
		pending = want
		left = RESTORE_DELAY if want.x > 0 else 0
		tries = 0
		return saved_mode
	# 进入全屏：先记住现在的样子。
	saved_mode = cur_mode
	# ⚠️ `cur_size` 在这里**可能是假的**：如果是"刚退出全屏、下一帧就按回来"，
	# 这一帧的 cur_size 报的还是全屏尺寸（2560×1600）—— 照抄的话就把一个
	# 全屏大小的尺寸记成了"窗口尺寸"，下次退出全屏会得到一个占满屏幕的窗口。
	# 有待还原的尺寸时以它为准（那才是真正的窗口尺寸）。
	saved_size = pending if pending.x > 0 else cur_size
	pending = Vector2i.ZERO
	left = 0
	tries = 0
	return DisplayServer.WINDOW_MODE_FULLSCREEN


## 每个固定步调一次：返回**这一步要设的尺寸**（ZERO = 什么都不做）。
## 只有"已经等够、又不在全屏、尺寸还没对上"才返回待还原的尺寸。
func tick(cur_mode: int, cur_size: Vector2i) -> Vector2i:
	if pending.x <= 0:
		return Vector2i.ZERO
	if left > 0:
		left -= 1
		return Vector2i.ZERO
	if cur_size == pending:
		# 已经是对的了（WM 自己还原成功，或者上一次设生效了）→ 收工
		pending = Vector2i.ZERO
		return Vector2i.ZERO
	if tries >= MAX_TRIES:
		pending = Vector2i.ZERO
		return Vector2i.ZERO
	tries += 1
	return pending
