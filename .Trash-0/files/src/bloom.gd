class_name Bloom
extends Node2D
## Bloom —— 叠加混合层。
##
## _draw() 里的 draw_* 没有逐次混合模式，所以需要"叠加发光"的部分单独放一层：
## 这层挂一个 CanvasItemMaterial(BLEND_MODE_ADD)，对应 Web 版里的 globalCompositeOperation = 'lighter'。
## 树的顺序保证它在世界层之后绘制，所以在角色之上（与 Web 版的细微差别见 README）。

var world: World


func _draw() -> void:
	if world != null:
		world.draw_bloom(self)
