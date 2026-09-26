#!/usr/bin/env python3
"""灯骑士 · Godot 自检的变异测试（证明断言真的有牙齿）。

**为什么要这个**：断言写完第一遍就全绿，说明不了任何事 —— 可能是断言根本
没在盯着实现。唯一可靠的办法是**故意把实现改坏**，然后确认：
  · 该红的断言真的红了；
  · 没有连带误伤（别的断言不该无故变红 —— 那说明它们互相耦合，将来会误导人）。

**怎么用**
    tools/godot-mutate.py              # 跑全部变异（50 个，一个约 1 分钟）
    tools/godot-mutate.py 迷雾          # 只跑名字里含「迷雾」的
    tools/godot-mutate.py --list       # 只列出变异清单
    tools/godot-mutate.py --restore-only   # 从备份还原 src（中途崩了用这个）

每次变异的流程：备份 src → 打补丁 → 跑 tools/godot-lightknight.sh →
读 shots/report.json 取"变红的断言名" → **无条件还原 src**。
全部跑完后再跑一次基线，确认还原干净（必须全绿）。

退出码：0 = 每个变异的实际变红集合都符合预期；1 = 有变异不符合。

⚠️ **沙箱注意：这里刻意不用 `shutil.rmtree`。** 本环境的沙箱有"批量删除保护"
（一次删超过 50 个文件会被拦下并抛异常），而 `src/` 有 20+ 个文件、`restore()`
原本是「删掉再复制」——于是在第一次还原时就崩了，**把改坏的源码留在盘上**。
现在一律用 `copytree(..., dirs_exist_ok=True)` **覆盖式还原**（只写不删），
这样还原不可能因删除被拦而失败。
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJ = ROOT / "godot-lightknight"
SRC = PROJ / "src"
BAK = pathlib.Path.home() / ".cache" / "dq-mutate" / "src.bak"
REPORT = PROJ / "shots" / "report.json"
VERIFY = ROOT / "tools" / "godot-lightknight.sh"

# 每个变异 = 一组对 src/ 下源文件的纯文本替换。
#   edits: [(相对 src 的路径, 原文, 替换)]
#   expect: 预期**必须变红**的断言名（子串匹配）
#   forbid: 预期**不该变红**的断言名（子串匹配）—— 可选
MUTATIONS: list[dict] = [
    {
        "name": "闪光衰减退回 step()（复现「世界冻结时红闪卡住」）",
        "edits": [
            ("main.gd", "\t\tworld.tick_fx(dt)\n", ""),
            (
                "world.gd",
                "\tshake = maxf(0.0, shake - dt * 40.0)\n\t# 闪光的衰减**不在这里**"
                " —— 见 tick_fx()：它必须在世界被冻结时也照常推进。\n",
                "\tshake = maxf(0.0, shake - dt * 40.0)\n"
                "\tflash_power = maxf(0.0, flash_power - dt * 2.4)\n",
            ),
        ],
        "expect": ["死亡期间全屏闪光照常淡出"],
        "forbid": ["结算期间世界时间没有前进"],
    },
    {
        "name": "refresh() 去掉 else 分支（复现「换关卡后红闪残留」）",
        "edits": [
            ("hud.gd", "\telse:\n\t\tflash_rect.color = Color(0, 0, 0, 0)\n", ""),
        ],
        "expect": ["死亡期间全屏闪光照常淡出", "重生后全屏滤镜已清除"],
    },
    {
        "name": "EMBLEMS 退回老版本恩赐 id（复现「恩赐卡徽记全一样」）",
        "edits": [
            (
                "hud.gd",
                '\t"hp": "star_06", "dmg": "spark_01", "haste": "trace_01", "light": "light_02",\n'
                '\t"reach": "light_03", "vamp": "smoke_05", "combo_up": "flame_03", "combo_add": "light_01",\n'
                '\t"dash": "smoke_02", "skill_cd": "magic_03", "cost_cut": "magic_01", "crit": "star_09",\n'
                '\t"bounty": "star_03", "killboom": "fire_01",\n',
                '\t"edge": "star_06", "bright": "light_02", "swift": "trace_01", "fuel": "magic_01",\n'
                '\t"kindle": "star_03", "vamp": "smoke_05", "thorn": "spark_01", "ward": "twirl_01",\n'
                '\t"greed": "star_09", "heavy": "scorch_02", "reach": "trace_04", "crit": "star_09",\n'
                '\t"combo": "light_03", "killboom": "fire_01", "drain": "smoke_08", "dr": "circle_03",\n'
                '\t"swift2": "trace_01", "shield": "twirl_01", "grow": "magic_03", "thorns": "spark_01",\n',
            ),
            (
                "hud.gd",
                "\t# 武器词条（reach / crit / vamp 与恩赐同名，复用上面那三条）\n"
                '\t"edge": "spark_07", "swift": "smoke_08", "shine": "flame_05",\n'
                '\t"ember": "flame_01", "frugal": "scorch_02",\n',
                "",
            ),
        ],
        "expect": ["徽记覆盖全部武器 / 恩赐 / 词条", "徽记有足够区分度"],
    },
    {
        "name": "EMBLEMS 写一个不存在的贴图名（复现「徽记静默隐形」）",
        "edits": [("hud.gd", '"hp": "star_06"', '"hp": "star_6"')],
        "expect": ["徽记引用的贴图全部真实存在"],
        "forbid": ["徽记覆盖全部武器 / 恩赐 / 词条"],
    },
    # ── 布局随机化（宝箱 / 波次锚点 / Boss 场地每局重摇）────────────────────────
    # 这一组专盯"随机化"本身。它有个天然难处：随机化的**失败方式是不报错的** ——
    # 退回固定坐标、换种子不变、撒到墙里，画面照常能跑，只有断言会红。
    # 所以这几条必须有牙齿，否则等于没做随机化。
    {
        "name": "宝箱退回关卡表里写死的坐标（复现「随机化被静默绕过」）",
        "edits": [
            (
                "world.gd",
                '	var chest_spots := _roll_chest_spots(level.get("chests", []))',
                '	var chest_spots: Array = level.get("chests", []).duplicate()',
            ),
        ],
        "expect": ["宝箱点位不是关卡表里写死的那个"],
    },
    {
        "name": "敌人锚点（波次 + Boss）退回关卡表里写死的坐标",
        "edits": [
            (
                "world.gd",
                'func _roll_anchors() -> Dictionary:\n\tvar lw := float(level["w"])',
                'func _roll_anchors() -> Dictionary:\n'
                '\tvar _fixed := []\n'
                '\tfor _wd in level["waves"]:\n'
                '\t\t_fixed.append(Vector2(float(_wd["x"]), float(_wd["y"])))\n'
                '\tvar _bd: Dictionary = level["boss"]\n'
                '\treturn {"boss": Vector2(float(_bd["x"]), float(_bd["y"])),\n'
                '\t\t"waves": _fixed, "fallbacks": 0}\n'
                '\tvar lw := float(level["w"])',
            ),
        ],
        "expect": ["波次锚点不是关卡表里写死的那个", "Boss 场地也不是写死那个坐标"],
    },
    {
        "name": "布局随机源不再吃 run_seed（复现「换种子地图不变」）",
        "edits": [
            (
                "world.gd",
                '_layout_rng = Proj.make_rng(hash([run_seed, level_index, "layout"]))',
                "_layout_rng = Proj.make_rng(0)",
            ),
        ],
        "expect": ["★ 换一个局种子 → 宝箱与敌人的位置整套换了"],
        # 同种子可复现是**必须保住**的：改坏的只是"换种子会变"，不是"确定性"。
        # 这条 forbid 就是在确认随机化的修法没有连坐把确定性自检的地基砸掉。
        "forbid": ["★ 同一个局种子重建世界 → 点位逐点相同"],
    },
    {
        "name": "波次锚点不再校验「从上一波直着走得到」（复现「清不掉的一波」）",
        "edits": [
            (
                "world.gd",
                "\t\t\tif not has_los(ref.x, ref.y, x, y, 24.0):\n\t\t\t\tcontinue\n",
                "",
            ),
        ],
        "expect": ["★ 波次锚点从出生点起链式可达"],
    },
    # ── 武器元素 / 攻击发光 / 第三张地图 ────────────────────────────────────
    # 这一组盯的是"看得见的手感"：元素随机、状态效果、攻击真的发光、三图各异。
    # 它们的失败方式同样**不报错** —— 八把武器全摇成火、冻结不再冻结、
    # 攻击灯点了但不亮、第三关越界，画面都照常能跑。
    {
        "name": "元素不再随机（八把武器全摇成同一种）",
        "edits": [
            (
                "world.gd",
                "var i := _elem_rng.randi_range(0, Content.ELEMENT_ORDER.size() - 1)",
                "var i := 0",
            ),
        ],
        "expect": ["★ 换一个局种子 → 元素表整套换掉", "★ 五种元素都摇得到"],
        # 同种子可复现是必须保住的：改坏的只是"随机"，不是"确定性"。
        "forbid": ["★ 同一个局种子重建世界 → 元素表逐项相同"],
    },
    {
        "name": "元素随机源带上关卡号 + 每次建世界都重摇（复现「过关换地图元素重摇」）",
        # 两层保护要一起拆：① 元素表存在 `prog["welem"]` 上，过关沿用；
        # ② `_elem_rng` 的种子不含关卡号。只拆②的话元素表根本不会再摇一次，
        # 断言不会红 —— 第一次跑这个变异就是这么"假通过"的。
        "edits": [
            (
                "world.gd",
                '_elem_rng = Proj.make_rng(hash([run_seed, "elem"]))',
                '_elem_rng = Proj.make_rng(hash([run_seed, level_index, "elem"]))',
            ),
            (
                "world.gd",
                '\tif not prog.has("welem") or typeof(prog["welem"]) != TYPE_DICTIONARY \\\n'
                '\t\t\tor (prog["welem"] as Dictionary).is_empty():\n'
                '\t\tprog["welem"] = _roll_elements()\n',
                '\tprog["welem"] = _roll_elements()\n',
            ),
        ],
        "expect": ["★ 过关换地图不会重摇元素"],
        # 同种子可复现必须保住：两次建世界都在同一关，元素表应当仍然一致。
        "forbid": ["★ 同一个局种子重建世界 → 元素表逐项相同"],
    },
    {
        "name": "火元素不再结算灼烧（复现「挂了状态但不掉血」）",
        "edits": [
            (
                "world.gd",
                "\t\tif e.ignite_tick <= 0.0:\n"
                "\t\t\te.ignite_tick = IGNITE_TICK\n"
                '\t\t\t_dot_damage(e, e.ignite_dps * IGNITE_TICK, "#ff8a3c")\n',
                "\t\tif e.ignite_tick <= 0.0:\n\t\t\te.ignite_tick = IGNITE_TICK\n",
            ),
        ],
        "expect": ["★ 火：灼烧一直在掉血", "★ 持续伤害不给连击"],
    },
    {
        "name": "冰元素不再冻结（复现「冰了还能跑」）",
        "edits": [
            (
                "world.gd",
                "\t\tif e.frozen_t > 0.0:\n\t\t\te.frozen_t -= dt\n"
                "\t\t\te.vx = 0.0\n\t\t\te.vy = 0.0\n\t\t\tcontinue\n",
                "\t\tif e.frozen_t > 0.0:\n\t\t\te.frozen_t -= dt\n",
            ),
        ],
        "expect": ["★ 冰：冻结期间一步都不动"],
        "forbid": ["★ 冰：冻结一解除立刻恢复移动"],
    },
    {
        "name": "雷元素连锁不再检查视线（复现「电弧穿墙」）",
        "edits": [
            (
                "world.gd",
                "\t\tif not has_los(src.x, src.y, o.x, o.y, 12.0):\n\t\t\tcontinue\n",
                "",
            ),
        ],
        "expect": ["★ 雷：电弧**不能穿墙**"],
    },
    {
        "name": "挥击灯不带遮挡（退化成叠加层上的一块亮斑）",
        "edits": [
            (
                "light_rig.gd",
                "_fx_lights[key] = _make_light(80.0, 0.0, Color.WHITE, true)",
                "_fx_lights[key] = _make_light(80.0, 0.0, Color.WHITE, false)",
            ),
        ],
        "expect": ["★ 这盏灯**带遮挡**"],
    },
    {
        "name": "挥击灯的半径不再跟攻击距离挂钩（复现「长兵器的光伸不出去」）",
        "edits": [
            (
                "light_rig.gd",
                "l.texture_scale = (reach * 0.95 + 46.0) / TEX_HALF",
                "l.texture_scale = 4.0 / TEX_HALF",
            ),
        ],
        "expect": [
            "灯的半径跟着攻击距离走",
            "★ 挥击真的把画面照亮了",
        ],
    },
    {
        "name": "弹丸灯能量为 0（复现「点了灯但没照亮」）",
        "edits": [("light_rig.gd", "l2.energy = 1.15", "l2.energy = 0.0")],
        "expect": ["★ 弹丸的灯真的照亮了那一块"],
    },
    {
        "name": "攻击类灯不封顶（复现「弹丸雨把帧率拖垮」）",
        "edits": [
            ("light_rig.gd", "var budget := FX_LIGHT_MAX", "var budget := 99999"),
        ],
        "expect": ["★ 攻击类灯有上限"],
    },
    {
        "name": "第三关之后还能继续往前（复现「越界出第 4 关」）",
        "edits": [
            (
                "main.gd",
                'prog["level"] = mini(int(prog["level"]) + 1, Content.level_count() - 1)',
                'prog["level"] = int(prog["level"]) + 1',
            ),
        ],
        "expect": ["★ 第三关之后不再往前"],
        "forbid": ["★ 第一关过关 → 进入第二关", "★ 第二关过关 → 进入第三关"],
    },
    {
        "name": "新敌人漏登记造型（复现「新怪静默变成又一只灯影」）",
        "edits": [("art.gd", '\tif nm.begins_with("灯河浮尸"):\n\t\treturn "tidehusk"\n', "")],
        "expect": [
            "★ 除了「灯影」本身，没有敌人落回兜底造型",
            "★ 敌人造型两两不同",
            "★ 造型数 = 敌人数 - 1",
            "第三关的两个新敌人都有自己的身子",
        ],
    },
    {
        "name": "第三关的地板退回第二关那种（复现「三图只有换色、没有换样」）",
        "edits": [("autoload/content.gd", '"art_style": "river",', '"art_style": "quarry",')],
        "expect": ["★ 三张地图的美术风格互不相同"],
    },
    # ── 起步攻击范围 / 夜色 / 迷雾 ─────────────────────────────────────────
    # 这一组盯的是"手感与观感"：够不够得着、夜里看不看得见、雾散不散。
    # 它们的失败方式同样**不报错**：退回 1.0 只是变难打、夜色拧到最暗只是变黑、
    # 雾不散只是整屏一层灰 —— 画面都在跑。
    {
        "name": "起步攻击范围退回 1.0（复现「够不着」的手感退回）",
        "edits": [("world.gd", "const BASE_REACH := 1.20", "const BASE_REACH := 1.00")],
        # 重点是那两条**绝对**断言。词条那几条是相对的（"比 rc0 多 0.12"），
        # 整体退回 1.0 也照样绿 —— 所以必须有绝对钉子，这个变异就是在证明钉子钉住了。
        "expect": [
            "★ 起步攻击范围 = 基础射程 ×1.20",
            "★ 起步的刀锋真的够到 79.2",
        ],
    },
    {
        "name": "夜色永远压到最暗一档（复现「地图黑得看不见」）",
        "edits": [
            (
                "light_rig.gd",
                "cm.color = NIGHT_MIN.lerp(Color(1.0, 1.0, 1.0), t)",
                "cm.color = NIGHT_MIN.lerp(Color(1.0, 1.0, 1.0), 0.0)",
            ),
        ],
        # ⚠️ 一开始这里写的是 `expect = ["夜色生效：地图不再是纯黑"]`，跑出来**没红** ——
        # 不是补丁打歪了，是**那条断言真的没牙**：调色板提亮之后，最暗一档也只是暗掉一半，
        # 全屏均值照样 > 0.05。于是补了一条"只拧 ambient 这一个变量"的前后对照
        # （见 selfcheck `_section_fog_night` 的 ②b），它才是这个失败方式的对应断言。
        "expect": ["★ 夜色旋钮真的接在画面上"],
    },
    {
        "name": "迷雾不再认遮挡（复现「光穿墙散雾」）",
        "edits": [
            (
                "fog.gd",
                "\t\tvar best := radius\n"
                "\t\tfor r in rects:\n"
                "\t\t\tvar t: float = Proj.ray_rect_dist(cx, cy, dx, dy, r[0], r[1], r[2], r[3])\n"
                "\t\t\tif t >= 0.0 and t < best:\n"
                "\t\t\t\tbest = t\n"
                "\t\tfan[i] = best\n",
                "\t\tvar best := radius\n\t\tfan[i] = best\n",
            ),
        ],
        "expect": ["★ 同距离的墙后雾没散（被那面墙挡住了）"],
        # 墙前/空地那几条**必须保住**：改坏的只是"墙后"，不是"有没有光照"。
        "forbid": [
            "近处（灯与墙之间）雾是散的",
            "★ 同距离的空地方雾散了（光够得着）",
        ],
    },
    {
        "name": "迷雾永不回填（复现「灯扫过去不留痕」）",
        "edits": [
            (
                "fog.gd",
                "\t\tvar c := _cur[i]\n\t\t_cur[i] = t if t >= c else maxf(t, c - k2)\n",
                "\t\tvar c := _cur[i]\n\t\t_cur[i] = t if t >= c else c\n",
            ),
        ],
        "expect": ["★ 0.5 秒后雾明显合拢回来"],
        # "立刻生效"那半条必须保住：改坏的只是"回填"，不是"照亮"。
        "forbid": [
            "回填对照：灯还照着时那个点确实是亮的",
            "★ 灯刚不照了，画面还是亮的",
        ],
    },
    {
        "name": "迷雾不再被灯驱散（复现「全屏一层灰」）",
        # 把所有灯的开雾半径系数清零 → 没有任何一盏灯够得上 MIN_OPENER_R，
        # 于是整屏永远是满雾 —— 这正是"忘了让灯驱散雾"的样子。
        "edits": [
            ("fog.gd", "var scale := float(KIND_SCALE.get(kind, 1.0))", "var scale := 0.0"),
        ],
        "expect": [
            "★ 灯照在脚下：那一格没有雾",
            "★ 整屏不是一层均匀的雾",
            "★ 同距离的空地方雾散了（光够得着）",
            "★ 挥击的灯把刀锋那一片的雾也驱散了",
        ],
        # "整屏是满雾"这件事本身没有被改坏，所以"雾让远处亮起来"该保住。
        "forbid": ["★ 没被照亮的地方：雾让画面亮起来"],
    },

    # ══════════════════════════════════════════════════════════════════
    # 姿态 / 动画（说话 / 施法）。这一组按「哪一层坏」排：
    #   纯数学层 → 绘制层 → 手感 → 触发链路 → 自终止。
    # ══════════════════════════════════════════════════════════════════
    {
        "name": "走路两条腿不再反相（复现「双腿同摆」「对侧步态是对的」）",
        # 只把 `hip_b` 从 `-hip` 改成 `hip`：腿仍然**在摆**（幅度不变）、
        # 屈膝仍然交替、起伏压扁也照旧 —— 坏的**只有**相位关系这一条。
        # 这正是「严格反相」这条断言该独有的牙齿。
        "edits": [("pose.gd", "\tvar hip_b := -hip\n", "\tvar hip_b := hip\n")],
        "expect": ["★ 走路时两条腿**严格反相**"],
        "forbid": [
            "★ 腿真的在摆",
            "★ 空手臂与同侧腿反相",
            "★ 两条腿不会同时屈膝",
            "★ 走路有起伏与落地压扁",
            "★ 站定时两条腿回到中立位",
        ],
    },
    {
        "name": "腿不再跟着姿态画（复现「走路时腿是两根木棍」）",
        # 姿态求解器**一个字不动**（所以纯数学那 6 条必须全绿），
        # 只在绘制层把喂给 `_draw_leg` 的髋角 / 屈膝换成 0 —— 两条腿画成静止的。
        # 这一条专门证明「走路的两个反相相位在屏幕上确实不一样」**真的在盯腿**，
        # 而不是"画面里有什么变了"（它旁边就有别人能动）。
        # 顺带：这条断言原先是**绝对**像素差，基线只在阈值上方 16%，
        # 于是"夜色拧到最暗"这种无关变异也能打红它 → 已改成按亮度归一化，
        # 本条变异就是用来确认归一化之后它**依然有牙齿**的。
        "edits": [
            (
                "art.gd",
                'float(st["hip_b"]), float(st["knee_b"]),\n',
                "0.0, 0.0,\n",
            ),
            (
                "art.gd",
                'float(st["hip"]), float(st["knee_a"]),\n',
                "0.0, 0.0,\n",
            ),
        ],
        "expect": ["★ 走路的两个反相相位在屏幕上确实不一样"],
        "forbid": [
            # 求解器没被动过，纯数学那几条必须保住
            "★ 走路时两条腿**严格反相**",
            "★ 腿真的在摆",
            "★ 两个对照都是 0",
            "★ 同一攻击进度下左挥与右挥画出来不一样",
        ],
    },
    {
        "name": "绘制层无视挥击姿态（复现「只有一个攻击范围、看不到挥舞」)",
        # 打在**绘制层**：`Pose.swing` 照常算，但画之前把 ang/ext/lean 三个
        # 消费点一起按回基准值 —— 于是"武器绕手转"在屏幕上彻底不存在。
        #
        # ⚠️ 这条变异把一条**假断言**挖了出来，过程值得记：
        #   第一版只按 ang/ext（没按 lean），结果**没红**。
        #   补上 lean 之后**还是没红**。两个原因不一样：
        #     a) `sw["lean"]` 会带着躯干 / 头 / 斗篷一起动，采样窗（156×96）
        #        把上半身整个框进去了 —— "整帧不一样"靠身体倾斜就满足了；
        #     b) 就算把艺术层彻底冻住，**世界层**还在 `world.gd` 里画一道
        #        跟着 `attack_t` 扫的刀光弧 + 月牙斩（sweep = a0 + (a1-a0)*t01），
        #        它落在同一个窗里，"前摇 vs 挥出"照样不一样。
        #   → 也就是说那条断言**两个独立的层各能单独满足它**，它压根没在问
        #     "武器转没转"。修法是按本站的老规矩"让旋钮转一下"：
        #     ① 原断言的措辞改成它真正量到的东西（粗糙的整帧烟测）；
        #     ② 补一条**只拧一个变量**的对照（`alt` 只进 `dir`）——
        #        它对"武器转没转"才真的有牙齿，见下一条变异。
        #   → 所以本条把 `前摇与挥出` 列进 **forbid**：它**应该**保持绿，
        #     这不是漏测，是那条断言的真实能力边界，写下来免得下次又误以为它在护着这一点。
        "edits": [
            (
                "art.gd",
                "\t\t\tp.attack_alt, base)\n",
                "\t\t\tp.attack_alt, base)\n"
                "\t\tsw[\"ang\"] = base\n"
                "\t\tsw[\"ext\"] = 0.0\n"
                "\t\tsw[\"lean\"] = 0.0\n",
            ),
        ],
        "expect": ["★ 同一攻击进度下左挥与右挥画出来不一样"],
        "forbid": [
            # 保持绿是**预期内**的：世界层的刀光弧仍然在扫（见上面的长注释）
            "★ 挥击的前摇与挥出画出来不一样",
            "★ 走路的两个反相相位在屏幕上确实不一样",
            "★ 八把武器的待机姿态两两不同",
            "★ 五类技能的施法姿态画出来各不相同",
        ],
    },
    {
        "name": "左右开弓不进绘制层（复现「每一刀都挥向同一边」）",
        # `alt` 只进 `dir` 一处。把它按住，等于"连续攻击不再左右交替" ——
        # 身体姿势、攻击时长、伤害判定全都不动（这就是那个单变量对照的意义）。
        "edits": [
            (
                "pose.gd",
                "\tvar dir := -1.0 if alt else 1.0\n",
                "\tvar dir := 1.0\n",
            ),
        ],
        "expect": [
            "★ 连续攻击左右交替",
            "★ 同一攻击进度下左挥与右挥画出来不一样",
        ],
        "forbid": [
            "★ 挥击的前摇与挥出画出来不一样",
            "★ 挥出末尾急停",
            "★ 挥舞是「先拉后扫」",
        ],
    },
    {
        "name": "挥出末尾不再急停（复现「像在打太极」）",
        # 把挥出的缓动从 `ease_out_quint` 换成 `v*v`（**越挥越快**）。
        # 峰值角速度反而更高（所以"峰值远大于前摇"那条必须保住），
        # 末尾却是全速撞上去 —— 打击感丢的正是这一条。
        "edits": [("pose.gd", "\t\tvar e := ease_out_quint(v)\n", "\t\tvar e := v * v\n")],
        "expect": ["★ 挥出末尾急停"],
        "forbid": [
            "★ 挥出的峰值角速度远大于前摇",
            "★ 挥舞是「先拉后扫」",
            "★ 连续攻击左右交替",
            "★ 八把武器的挥舞姿态两两不同",
        ],
    },
    {
        "name": "放技能不触发施法姿态（复现「技能只有特效、人没动作」）",
        # 端到端那条断言盯的就是这个赋值。去掉它，技能照样放（特效、冷却、
        # 扣连击全在），只是**人不动** —— 所以别的姿态断言必须全都保住。
        "edits": [
            (
                "world.gd",
                "\tp.cast_t = Pose.CAST_DUR\n\tp.cast_kind = Pose.cast_kind_of(sid)\n",
                "",
            ),
        ],
        "expect": ["★ 真的放技能会触发施法姿态"],
        "forbid": [
            "★ 施法姿态会自己结束",
            "★ 五类技能的施法姿态画出来各不相同",
            "技能[spin]：有起手与放出（幅度够大）并且收势回到静姿",
        ],
    },
    {
        "name": "施法姿态卡住不结束（复现「卡在施法姿势上」）",
        # 阈值从 0.0 挪到 999.0 = 实际上不再递减。这是"技能动作"最常见的翻车方式：
        # 起手有、放出有，就是收不回来，人永远举着手。
        "edits": [
            (
                "world.gd",
                "\tif p.cast_t > 0.0:\n\t\tp.cast_t -= dt\n",
                "\tif p.cast_t > 999.0:\n\t\tp.cast_t -= dt\n",
            ),
        ],
        "expect": ["★ 施法姿态会自己结束"],
        "forbid": ["★ 真的放技能会触发施法姿态"],
    },
    # ══════════════════════════════════════════════════════════════════
    # 挥击范围线 vs 判定（2026-09-26）
    # 用户报："**一些**武器实际攻击范围与标出来的线不符"。
    # 根因是判定与绘制各算各的（判定读 w.arc，绘制写死 0.9 半径 + 0.9 弧度）。
    # 下面 8 条把每一层各自会怎么坏都试一遍，顺便确认哪一层的断言抓哪一层。
    # ══════════════════════════════════════════════════════════════════
    {
        "name": "挥击半径漏掉 range_mul（判定与绘制又各算各的）",
        # 打在**几何来源**上：`swing_cone` 把 range_mul 按回 1.0。
        # 普通攻击看不出来（它本来就是 1.0），**连灯刺那一下才会偏** ——
        # 这正是用户那个缺陷里最难发现的一半。
        # 像素层应该保持绿：判定与绘制都读同一个 cone，仍然自洽。
        "edits": [
            (
                "world.gd",
                "\t\t\"r\": cone_radius(float(w[\"range\"]), range_mul, reach_mul()),\n",
                "\t\t\"r\": cone_radius(float(w[\"range\"]), 1.0, reach_mul()),\n",
            ),
        ],
        "expect": [
            "★ 挥击半径 = range × range_mul × reach_mul",
            "★ 连灯刺（range_mul=0.9）写进来的半径正好是普攻的 0.9 倍",
        ],
        "forbid": [
            "★ 画出来的范围线与判定逐点一致",
            "★ 范围线真的画在**外沿 r** 上",
            "★ 背后的贴身豁免圈也画了",
            "★ 扇面半角 = arc / 2",
        ],
    },
    {
        "name": "绘制层自己算范围线（半径 ×0.9、角宽写死 0.9）—— 复现用户报的那个缺陷",
        # 打在**绘制层**：判定照旧用正确的 cone，画出来的线按回旧算法。
        # 期望：像素层的「外沿带」变红（线画小了，那条带里什么都没有）；
        # 而**纯逻辑那一层必须保持绿** —— 它量的是判定与形状生成器，
        # 补丁根本没打到那里。这对绿/红说明"缺陷在哪一层，哪一层的断言负责"。
        "edits": [("world.gd", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon(cone, player.facing),\n\t\t\t\t(1.0 - t01))\n", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon({\n\t\t\t\t\"r\": cone_r * 0.9, \"inner\": 40.0, \"half\": 0.45, \"arc\": 0.9},\n\t\t\t\tplayer.facing),\n\t\t\t\t(1.0 - t01))\n")],
        "expect": ["★ 范围线真的画在**外沿 r** 上"],
        "forbid": [
            "★ 画出来的范围线与判定逐点一致",
            "★ 背后的贴身豁免圈也画了",
            "★ 而 r 之外那条对照带几乎是黑的",
            "★ 扇面半角 = arc / 2",
        ],
    },
    {
        "name": "绘制层把范围线画远 1.3 倍（反向的失败方式：线画大了）",
        # 与上一条**互为反向**：画小了由「外沿带」抓，画大了由「更外面那条对照带」抓。
        # 两条各有一条专属断言 —— 只写一条的话，必有一半失败方式没人管。
        "edits": [("world.gd", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon(cone, player.facing),\n\t\t\t\t(1.0 - t01))\n", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon({\n\t\t\t\t\"r\": cone_r * 1.3, \"inner\": 40.0, \"half\": float(cone[\"half\"]), \"arc\": 0.9},\n\t\t\t\tplayer.facing),\n\t\t\t\t(1.0 - t01))\n")],
        "expect": [
            "★ 而 r 之外那条对照带几乎是黑的",
            "★ 范围线真的画在**外沿 r** 上",
        ],
        "forbid": [
            "★ 背后的贴身豁免圈也画了",
            "★ 画出来的范围线与判定逐点一致",
        ],
    },
    {
        "name": "绘制层漏掉贴身豁免那圈（判定里有、画面上没有）",
        # 只把**画出来的**内圈缩到 0.5。判定一个字没动，所以纯逻辑那层全绿 ——
        # 这一条专门证明「背后的贴身豁免圈也画了」这条像素断言有牙齿，
        # 而它是唯一能抓住这个失败方式的断言。
        "edits": [("world.gd", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon(cone, player.facing),\n\t\t\t\t(1.0 - t01))\n", "\t\t\tArt.ground_cone(ci, px2, gy2, World.cone_polygon({\n\t\t\t\t\"r\": cone_r, \"inner\": 0.5, \"half\": float(cone[\"half\"]), \"arc\": 0.9},\n\t\t\t\tplayer.facing),\n\t\t\t\t(1.0 - t01))\n")],
        "expect": ["★ 背后的贴身豁免圈也画了"],
        "forbid": [
            "★ 范围线真的画在**外沿 r** 上",
            "★ 而 r 之外那条对照带几乎是黑的",
            "★ 画出来的范围线与判定逐点一致",
        ],
    },
    {
        "name": "判定不看角度（贴身豁免扩大到整个半径）",
        "edits": [
            (
                "world.gd",
                "\treturn absf(Proj.angle_diff(facing, atan2(dy, dx))) <= float(cone[\"half\"])\n",
                "\treturn true\n",
            ),
        ],
        # ⚠️ 后面两条机器人断言**是该红的，不是误伤**：判定变成无方向之后，
        # 机器人那一路的战况真的变了（背后的敌人也会被砍到）。
        # 端到端断言对玩法改动敏感是应该的 —— 只是要**写明白**，
        # 否则下一次跑的人会把它们当成"连带误伤"去追。
        "expect": [
            "★ 画出来的范围线与判定逐点一致",
            "★ 正后方贴身：inner×0.8 打得到、inner×1.3 打不到",
            "机器人打到了 Boss 区（进关链条能走通）",
            "机器人清完了三波（波次链条能走通）",
        ],
        "forbid": [
            "★ 正前方：r×0.99 打得到、r×1.02 打不到",
            "★ 范围线真的画在**外沿 r** 上",
            "★ 背后的贴身豁免圈也画了",
        ],
    },
    {
        "name": "扇面角宽写死 0.9（复现「有的武器对、有的武器不对」）",
        # 灯杖的 arc 正好是 0.9 —— 写死它，灯杖看着分毫不差、其余六把全错。
        # 这就是用户那句"**一些**武器不符"的字面复现。
        # 注意它连像素层也带红（画出来的扇形也变成 0.9 了），这是应该的：
        # 缺陷在几何来源那一层，往下每一层都会跟着错。
        "edits": [
            (
                "world.gd",
                "\tvar arc := float(w[\"arc\"]) * arc_mul\n",
                "\tvar arc := 0.9 * arc_mul\n",
            ),
        ],
        # 角宽写死之后 `arc_mul` 也失效了，所以"连刺的扇面更窄"那条**也该红**
        # （它验的正是 arc_mul 有没有进来）；机器人那两条同理（见上一条的说明）。
        "expect": [
            "★ 扇面半角 = arc / 2",
            "★ 角宽随武器走",
            "★ 范围线真的画在**外沿 r** 上",
            "★ 连刺的扇面也更窄",
            "机器人打到了 Boss 区（进关链条能走通）",
            "机器人清完了三波（波次链条能走通）",
        ],
        "forbid": ["★ 画出来的范围线与判定逐点一致"],
    },
    {
        "name": "灯弩被当成近战（既不再射光矢，又多画一条近战范围线）",
        # `shot` 类武器射光矢出去，判定走投射物。给它画一条近战范围线，
        # 等于"标出来的线"指向一个不存在的命中区域 —— 最明目张胆的一种"不符"。
        #
        # ⚠️ 这一条打的是 `has_swing_sector()`，而**同一个判据也决定
        # "要不要走射光矢那条分支"**（两件事本来就是同一件事：没有近战判定）。
        # 所以它一坏，灯弩就真的变成了近战 —— 后面那四条**是该红的**：
        # 三条灯弩自己的（不射箭了）加一条"八把武器特效种类"（少了一种）。
        "edits": [
            (
                "world.gd",
                "\treturn str(w.get(\"style\", \"slash\")) != \"shot\"\n",
                "\treturn true\n",
            ),
        ],
        "expect": [
            "★ 八把武器里只有灯弩没有扇面",
            "灯弩挥击会射出光矢（而不是刀弧）",
            "灯弩挥击射出了光矢",
            "玩家侧关键特效齐了（挥击/环/爆发/光柱/拽拉/持续区/枪口）",
            "八把武器共产出 ≥ 7 种特效（不是靠改数字凑数）",
            # 灯弩变成近战之后，远程那套"没有挥击视觉"当然也不成立了。
            "★ 【用户报的这条】灯弩开火时绘制层的总闸是关的",
            "★ 【用户报的这条】灯弩「开枪」时翻掉亮弧与月牙刃的开关",
        ],
        "forbid": [
            "★ 画出来的范围线与判定逐点一致",
            "★ 角宽随武器走",
        ],
    },
    {
        "name": "飘字字号表建了但绘制不读（float_text 里写死字号）",
        # 本轮"放大伤害数字"最可能悄悄失败的方式：表建好了、调用点也全改成读表了，
        # 但绘制函数忘了用 `ft["size"]`。翻代码查不出来（调用点看着全对），
        # 只有让屏幕上的像素说话。
        "edits": [
            (
                "art.gd",
                "\tvar size := base * pop\n",
                "\tvar size := 20.0 * pop\n",
            ),
        ],
        "expect": ["★ 字号真的影响渲染"],
        "forbid": [
            "★ 命中字号 ≥ 28",
            "★ 小字号那帧必须画出了字",
        ],
    },
    {
        "name": "字号表回退到上一版（22 / 28 —— 用户第二次说小的那一版）",
        # 用户第二次要求"再大一些"。这条变异把表整体调回去，
        # 如果自检的判据只是"表建好了、调用点都读表了"，那它一条都不会红 ——
        # 所以门槛必须**钉在具体数值上**（≥ 28），而不是"有没有这张表"。
        #
        # ⚠️ dot / status 一起调回 16：它们是"最低那两档"，
        # 每一次字号调整都得跟着抬，否则密刷的时候最先看不清的就是它们。
        "edits": [
            ("art.gd", "\t\"hit\": 30.0,", "\t\"hit\": 22.0,"),
            ("art.gd", "\t\"crit\": 40.0,", "\t\"crit\": 28.0,"),
            ("art.gd", "\t\"dot\": 22.0,", "\t\"dot\": 16.0,"),
            ("art.gd", "\t\"status\": 22.0,", "\t\"status\": 16.0,"),
        ],
        "expect": [
            "★ 命中字号 ≥ 28",
            "★ 每一个飘字键的字号都 ≥ 20",
        ],
        "forbid": [
            "★ 暴击字号 > 普通命中字号",
            "★ 字号真的影响渲染",
        ],
    },
    {
        "name": "月牙刃漏在总闸外面（灯弩开火时甩出一道很宽的刀弧）",
        # 这就是用户报的那个 bug 的**原样复现**：上一轮只把 ①范围线 拦住了，
        # ③月牙刃 漏在"有没有扇面"这道门外 —— 灯弩的 attack_t 照样是 0.2，
        # 于是"开枪"顺带甩出一道刀弧（半径 = cone_r × 1.34 = 611，
        # 灯弩的 cone_r 还是八把里最远的 456）。
        #
        # 注意它**不该**弄红上面那条逻辑断言：总闸函数本身没被碰，
        # 红的是像素那条（翻开关时画面会变）—— 两条断言问的是不同的问题。
        "edits": [
            (
                "world.gd",
                "\t\tif not swing_guide_only and swing_visual_on():\n",
                "\t\tif not swing_guide_only:\n",
            ),
        ],
        "expect": [
            "★ 【用户报的这条】灯弩「开枪」时翻掉亮弧与月牙刃的开关",
        ],
        "forbid": [
            "★ 【用户报的这条】灯弩开火时绘制层的总闸是关的",
            "★ 这个开关对近战武器是有效的",
            "★ 上面那条的判据是干净的",
            "★ 采样判据本身是干净的",
        ],
    },
    {
        "name": "总闸不再问「这把武器有没有扇面」（灯弩也被算进挥击视觉）",
        # 打在 `swing_visual_on()` 自己身上：去掉 `has_swing_sector`。
        # 和上面那条是**两个不同的变异点** —— 一个打总闸函数、一个打某一件视觉的
        # 局部条件。将来谁把总闸拆开写回三处各判一次，这个变异就会失去目标，
        # 那时候应该改的是代码结构，不是把变异删掉。
        "edits": [
            (
                "world.gd",
                "\treturn player.attack_t > 0.0 and not player.dead and has_swing_sector(player.weapon())\n",
                "\treturn player.attack_t > 0.0 and not player.dead\n",
            ),
        ],
        "expect": [
            "★ 【用户报的这条】灯弩开火时绘制层的总闸是关的",
            "★ 【用户报的这条】灯弩「开枪」时翻掉亮弧与月牙刃的开关",
        ],
        "forbid": [
            "★ 换成近战武器（灯镰）总闸就是开的",
        ],
    },
    {
        "name": "退出全屏时立刻设尺寸（不等窗口模式落定）",
        # 这是"最自然的写法"，也正是本机（XWayland）会栽的那个坑：
        # 实测 window_set_mode(WINDOWED) 之后，窗口尺寸**当帧**还报着全屏的
        # 2560×1600，下一帧才被 WM 改成它自己的 1270×1528。同一步里 set_size
        # 会被那次覆盖整个吃掉 —— 决策层看不出来，只有真窗口端到端会红。
        # ⚠️ 与下面「算出来的尺寸不下发」同理：这两条尺寸断言的牙齿依赖
        # **本机 WM 不会自己把窗口尺寸还回来**。哪天它开始自动还原，
        # 该改的是判据（断言"我们确实调用过 set_size"），而不是删掉这条变异。
        "edits": [
            (
                "window_mode.gd",
                "\t\tleft = RESTORE_DELAY if want.x > 0 else 0\n",
                "\t\tleft = 0\n",
            ),
        ],
        "expect": [
            "★ 【本机时序陷阱的判据】退出全屏后**恰好**先等 RESTORE_DELAY 步",
            "★ 退出全屏后窗口尺寸真的被**我们**设回按下之前那个",
            "★ 标题界面这一轮也把尺寸还原干净了",
        ],
    },
    {
        "name": "is_fullscreen 只认 FULLSCREEN（漏掉独占全屏）",
        # 「只认一种全屏」的后果不是"退不出来"这么轻：独占全屏下 F11 会以为
        # 自己当前不在全屏，于是**再进一次全屏**，玩家就再也出不来了。
        "edits": [
            (
                "window_mode.gd",
                "\treturn mode == DisplayServer.WINDOW_MODE_FULLSCREEN \\\n"
                "\t\tor mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN\n",
                "\treturn mode == DisplayServer.WINDOW_MODE_FULLSCREEN\n",
            ),
        ],
        "expect": [
            "★ 【只认 FULLSCREEN 是个坑】两种全屏模式都算全屏",
            "★ 独占全屏下按 F11 是「退出来」",
        ],
    },
    {
        "name": "进全屏时把「当前报的尺寸」当成窗口尺寸（不看待还原的）",
        # "刚退出全屏就又按回来"时，那一帧报的还是**全屏尺寸** —— 照抄就会把
        # 2560×1600 记成"窗口尺寸"，下次退出全屏得到一个占满屏幕的窗口。
        # 这条只有"把两个动作挤到同一帧"才暴露，所以自检里专门有这么一段。
        "edits": [
            (
                "window_mode.gd",
                "\tsaved_size = pending if pending.x > 0 else cur_size\n",
                "\tsaved_size = cur_size\n",
            ),
        ],
        "expect": [
            "★ 刚退出全屏就又按 F11：不能把这一帧的**全屏尺寸**当成窗口尺寸记下来",
            "★ 快按两下之后，最终还原的尺寸还是最初那个 1280×720",
        ],
    },
    {
        "name": "tick 不再核对尺寸是否已经对上（会一直重复设）",
        # 去掉"已经对了就收工"那一半。掉的是**幂等性**：
        # 收工之后每步还在设尺寸，等于一直跟 WM 抢。
        "edits": [
            (
                "window_mode.gd",
                "\tif cur_size == pending:\n"
                "\t\t# 已经是对的了（WM 自己还原成功，或者上一次设生效了）→ 收工\n"
                "\t\tpending = Vector2i.ZERO\n"
                "\t\treturn Vector2i.ZERO\n",
                "",
            ),
        ],
        "expect": [
            "★ 设过一次就收工",
            "★ 收工之后彻底没有待办",
            "★ 一旦尺寸真的对上就立刻停手",
        ],
    },
    {
        "name": "F11 只在游戏中生效（等价于把它挪进 play 那个分支）",
        # 把处理挂进某个状态分支是很自然的写法，代价是**标题界面按不动** ——
        # 而玩家最先想按 F11 的地方恰恰是标题界面。
        "edits": [
            (
                "main.gd",
                '\tif GameInput.just("fullscreen"):\n',
                '\tif GameInput.just("fullscreen") and state == "play":\n',
            ),
        ],
        "expect": [
            "★ 【界面无关】在**标题界面**（state=title）按 F11 一样生效",
        ],
    },
    {
        "name": "F11 漏在采样表外面（ACTIONS 里没登记）",
        # 本轮**真的踩过这个**：新动作只 `_register()` 进 InputMap、忘了加进
        # ACTIONS，`just()` 就永远是 false —— 键按下去毫无反应，而且**不报任何错**。
        # 决策层那十几条断言全绿，只有端到端那两条会红。
        # 留这条变异的意义：这个坑一旦再犯，机器会立刻指出来。
        "edits": [
            (
                "autoload/game_input.gd",
                '\t"fullscreen",\n]',
                ']',
            ),
        ],
        "expect": [
            "★ 【用户要的这条】F11 真的把窗口切成全屏",
            "★ 【界面无关】在**标题界面**",
        ],
    },
    {
        "name": "tick 算出来的尺寸不下发（记了不用）",
        # 决策层算得完全正确，只是**忘了真的去设** —— 这正是"接线"那一层的缺陷。
        # 条件写成一个永远不成立的式子（而不是删掉整行），是为了让改动尽量局部。
        # ⚠️ 这条变异的 `expect` 依赖一件事：**本机 WM 不会自己把窗口尺寸还回来**。
        # 如果哪天它开始自动还原，这两条尺寸断言就同时失去牙齿 ——
        # 那时应该改的是判据（比如断言"我们确实调用过 set_size"），别把变异删掉了事。
        "edits": [
            (
                "main.gd",
                "\tif want.x > 0 and want.y > 0:\n\t\tDisplayServer.window_set_size(want)\n",
                "\tif want.x < 0 and want.y < 0:\n\t\tDisplayServer.window_set_size(want)\n",
            ),
        ],
        "expect": [
            "★ 退出全屏后窗口尺寸真的被**我们**设回按下之前那个",
            "★ 标题界面这一轮也把尺寸还原干净了",
        ],
    },
]


def run_verify() -> dict:
    """跑一次自检，返回 report.json（断言变红是预期内的，rc 不用管）。"""
    subprocess.run([str(VERIFY)], cwd=ROOT, capture_output=True, text=True, timeout=900)
    if not REPORT.exists():
        raise RuntimeError("自检没有产出 report.json —— 看 ~/.cache/godot-tmp/godot-lightknight.log")
    return json.loads(REPORT.read_text())


def failed_checks(rep: dict) -> list[str]:
    return sorted(k for k, v in rep["checks"].items() if not v)


def unknown_targets(rep: dict, picked: list[dict]) -> list[str]:
    """`expect`/`forbid` 里有没有**对不上任何真实断言名**的字符串。

    为什么需要这道校验：比对用的是子串匹配，所以抄错一个字（少个「★ 」前缀、
    大小写不同、措辞记岔了）**不会**报错 —— 它会一路跑完，最后显示成
    "✘ 预期变红却没有"，看起来像"这条断言没有牙齿"，把人引到完全错误的方向。

    本条就是踩出来的：四条 `expect` 多写了「★ 」前缀，全套跑满 27 分钟才发现
    是字符串抄错了，而断言其实**全都正常变红**。基线跑完时手上正好有全量断言名，
    花 0.01 秒就能验掉，宁可在第 40 秒停下。
    """
    names = list(rep["checks"].keys())
    bad: list[str] = []
    for m in picked:
        for kind in ("expect", "forbid"):
            for pat in m.get(kind, []):
                if not any(pat in n for n in names):
                    bad.append(f'{m["name"]} —— {kind} 里的 {pat!r} 对不上任何断言名')
    return bad


def apply_edits(edits: list[tuple[str, str, str]]) -> None:
    for rel, old, new in edits:
        p = SRC / rel
        txt = p.read_text()
        n = txt.count(old)
        if n != 1:
            raise RuntimeError(f"{rel}: 待替换文本出现 {n} 次（应为 1 次），补丁写错了")
        p.write_text(txt.replace(old, new))


def tree_hash(d: pathlib.Path) -> str:
    """目录内容指纹（相对路径 + 内容），用来判断 src 与备份是否一致。"""
    h = hashlib.sha256()
    for p in sorted(d.rglob("*")):
        if p.is_file():
            h.update(str(p.relative_to(d)).encode())
            h.update(p.read_bytes())
    return h.hexdigest()


def restore() -> None:
    """**覆盖式**还原：只写不删。

    刻意不用 `shutil.rmtree` —— 沙箱的批量删除保护会在目录文件数超过阈值时
    抛异常，那样 `finally: restore()` 本身就会失败，把改坏的源码留在盘上。
    """
    shutil.copytree(BAK, SRC, dirs_exist_ok=True)


def main() -> int:
    argv = sys.argv[1:]
    if "--list" in argv:
        for m in MUTATIONS:
            print(f"  · {m['name']}")
        return 0

    if "--restore-only" in argv:
        if not BAK.exists():
            print("没有备份可还原：", BAK, file=sys.stderr)
            return 1
        print("▸ 从备份覆盖还原 src（只写不删）…")
        restore()
        print("  完成。src 指纹 =", tree_hash(SRC)[:12])
        return 0

    picked = [m for m in MUTATIONS if not argv or any(a in m["name"] for a in argv)]
    if not picked:
        print("没有匹配的变异（用 --list 看清单）", file=sys.stderr)
        return 1

    print("▸ 备份 src →", BAK)
    BAK.parent.mkdir(parents=True, exist_ok=True)
    if BAK.exists():
        if tree_hash(BAK) != tree_hash(SRC):
            # 备份是"原始基线"，只有它在就一定是干净的。src 与它不一致有两种可能：
            #   a) 你有意改了 src —— 那就把备份删掉重跑（rm -rf 之外：直接改名即可）
            #   b) 上一次变异中途崩了 —— 用 --restore-only 把 src 拉回基线
            print("  ⚠️ src 与上次的备份不一致，拒绝覆盖备份（否则会把脏状态存成基线）。", file=sys.stderr)
            print(f"     备份 = {tree_hash(BAK)[:12]}   src = {tree_hash(SRC)[:12]}", file=sys.stderr)
            print("     怀疑上次崩在中途：tools/godot-mutate.py --restore-only", file=sys.stderr)
            print(f"     确实是有意改动：删掉这个目录后重跑 —— {BAK}", file=sys.stderr)
            return 1
        print("  （备份与 src 一致，直接复用）")
    else:
        shutil.copytree(SRC, BAK)  # 覆盖式工具，目标不存在时行为与普通复制一致

    print("▸ 跑基线（应为全绿）…")
    base_report = run_verify()
    base_fails = failed_checks(base_report)
    if base_fails:
        print("  ⚠️ 基线本身就有红的，先修好再变异：", base_fails, file=sys.stderr)
        return 1

    # 基线绿了，手上正好有**全量**断言名 —— 先拿它把 expect/forbid 的字符串验一遍。
    # 抄错一个字不会在比对时报错，只会跑完全程后伪装成"预期变红却没有"。
    bad_pat = unknown_targets(base_report, picked)
    if bad_pat:
        print("  ✗ expect/forbid 里有对不上断言名的字符串：", file=sys.stderr)
        for b in bad_pat:
            print("     " + b, file=sys.stderr)
        print("     对着 shots/report.json 的 checks 键名原样抄（「★ 」前缀也算在内）",
              file=sys.stderr)
        return 1
    print("  基线全绿 ✓ · expect/forbid 的断言名全部对得上 ✓\n")

    bad: list[str] = []
    try:
        for m in picked:
            print(f"▸ 变异：{m['name']}")
            try:
                apply_edits(m["edits"])
                got = failed_checks(run_verify())
            except Exception as exc:  # noqa: BLE001
                print(f"  ✗ 打补丁失败：{exc}", file=sys.stderr)
                bad.append(m["name"])
                continue
            finally:
                restore()  # 无条件还原，绝不让改坏的代码留在盘上

            exp_ok = all(any(e in g for g in got) for e in m.get("expect", []))
            bad_hits = [g for g in got if any(f in g for f in m.get("forbid", []))]
            ok = exp_ok and not bad_hits
            mark = "✓" if ok else "✗"
            print(f"  {mark} 变红的断言（{len(got)} 条）：")
            for g in got:
                exp = any(e in g for e in m.get("expect", []))
                print(f"      {'✔ 预期' if exp else '？额外'} {g}")
            for e in m.get("expect", []):
                if not any(e in g for g in got):
                    print(f"      ✘ 预期变红却没有：{e}")
            for f in bad_hits:
                print(f"      ✘ 不该红却红了：{f}")
            if not ok:
                bad.append(m["name"])
            print()
    finally:
        restore()

    print("▸ 还原后复跑基线，确认没留脏 …")
    final_fails = failed_checks(run_verify())
    if final_fails:
        print("  ✗ 还原后仍有红的：", final_fails, file=sys.stderr)
        return 1
    print("  还原干净，全绿 ✓\n")

    if bad:
        print("✗ 有变异不符合预期：")
        for b in bad:
            print("   ", b)
        return 1
    print(f"✅ {len(picked)} 个变异全部符合预期：该红的红了，没有连带误伤。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
