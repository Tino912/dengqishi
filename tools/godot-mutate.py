#!/usr/bin/env python3
"""灯骑士 · Godot 自检的变异测试（证明断言真的有牙齿）。

**为什么要这个**：断言写完第一遍就全绿，说明不了任何事 —— 可能是断言根本
没在盯着实现。唯一可靠的办法是**故意把实现改坏**，然后确认：
  · 该红的断言真的红了；
  · 没有连带误伤（别的断言不该无故变红 —— 那说明它们互相耦合，将来会误导人）。

**怎么用**
    tools/godot-mutate.py                  # 串行跑全部变异
    tools/godot-mutate.py --jobs 4         # 4 个 worker 并行（见下面「倍速」）
    tools/godot-mutate.py 迷雾              # 只跑名字里含「迷雾」的
    tools/godot-mutate.py --list           # 只列出变异清单
    tools/godot-mutate.py --restore-only   # 从备份还原 src（中途崩了用这个）

每次变异的流程：备份 src → 打补丁 → 跑自检 → 读 shots/report.json 取"变红的断言名"
→ **无条件还原 src**。全部跑完后再跑一次基线，确认还原干净（必须全绿）。

退出码：0 = 每个变异的实际变红集合都符合预期；1 = 有变异不符合。

**倍速（2026-09-27 用户要求「在进行变异测试时尝试倍速」，逐个量过再改）**

改之前一轮 = `tools/godot-lightknight.sh`，实测 **48.6 秒**。拆开看有两个可省的开销：
  · **每轮白跑一次导入刷新（~8 秒）**。那个脚本拿"源码比类缓存新"当判据，
    而**每个变异都会重写一个 src 文件** → 判据必然成立 → 每轮都 `--import` 一遍。
    变异从不新增 `class_name` 脚本，这一步对变异测试毫无用处。
    → 这里改成**直接调 godot**（不走那个脚本），把它省掉。
  · **`--disable-vsync`（~2.5 秒 / 6%）**：实测 42.9 → 40.2 秒，`report.json` 逐字节相同。
    ⚠️ 这个数**早先被记错过**：写的是"86 秒 → 40 秒（2.15×）"，那是拿**脚本总耗时**
    去比**引擎耗时**，两件事。真话是"脚本 48.6 / 引擎 40.2"，两处都省才落到 40.2 秒。
  · 剩下的 **40.2 秒**基本是引擎本身（llvmpipe 软件渲染）的下限，没法再挤。

所以**单轮 48.6 → 40.2 秒（1.21×）** —— 这是能落到实处的那一截。

再往上只剩**并行**：`--jobs N` 给每个 worker 一份**工程副本**（连 `.godot/` 一起复制，
所以副本也不必重新导入），各自就地改自己的 `src/`。自检只吃满 20 核里的一两核，
所以 4 路在纸面上能拿到 ~3×。

⚠️ **但本机实测用不了 —— 而且是被它自己的前提自证拦下的**（见 `run_batch()`）：
`--jobs > 1` 时会**先用未打补丁的副本并发跑一轮**。4 个 worker 一起跟 XWayland 要窗口
尺寸时，基线里这条会偶发变红：

    ★ 前提：真窗口能被设成测试尺寸 —— 设不上，下面两条尺寸断言就无从谈起

而那条前提一红，后面两条尺寸断言全成了"无从谈起" → **含全屏断言的变异会被误判**。
（它是**偶发**的：同一批 4 条变异早先并发跑过一次是全绿的。偶发最不该被"重试到绿"糊过去。）

处理：**退回串行**（慢，但结论一定可信），并把发现打在日志里。
想真正用上并发，得让真窗口那一段在进程之间互斥（或给它一个"跳过真窗口段"的模式、
再把那几条变异单独串行跑）—— 本机没做，理由见 README 二.20.5：**这一类"看起来更快"
的改动，收益必须量出来，不能推出来**。

⚠️ **沙箱注意：这里刻意不用 `shutil.rmtree`。** 本环境的沙箱有"批量删除保护"
（一次删超过 50 个文件会被拦下并抛异常），而 `src/` 有 20+ 个文件、`restore()`
原本是「删掉再复制」——于是在第一次还原时就崩了，**把改坏的源码留在盘上**。
现在一律用 `copytree(..., dirs_exist_ok=True)` **覆盖式还原**（只写不删），
这样还原不可能因删除被拦而失败。
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJ = ROOT / "godot-lightknight"
SRC = PROJ / "src"
CACHE = pathlib.Path.home() / ".cache" / "dq-mutate"
BAK = CACHE / "src.bak"
REPORT_REL = pathlib.Path("shots") / "report.json"
REPORT = PROJ / REPORT_REL
# 直接调引擎，不走 tools/godot-lightknight.sh —— 那个脚本每轮会白跑一次
# "导入刷新"（~8 秒，因为变异必然让某个 src 文件比类缓存新）。见模块开头的「倍速」。
GODOT_BIN = os.environ.get("GODOT_BIN", "/usr/bin/godot")
VERIFY_TIMEOUT = 240   # 单轮自检的超时。正常 ~40 秒；超了多半是解析错误把引擎挂住了

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
        # 锚点 2026-09-27 更新：`next_level()` 重构成 `sail_to(level + 1)` 之后，
        # 越界的**唯一**防线成了 `sail_to()` 里那个 `clampi`（`Content.level_at()`
        # 自己也夹，但它夹的是"取哪张图"，`prog["level"]` 照样会变成 3 ——
        # 于是 `main.prog["level"] == 2` 那条断言红）。
        "edits": [
            (
                "main.gd",
                'prog["level"] = clampi(target, 0, Content.level_count() - 1)',
                'prog["level"] = target',
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
        # ⚠️ 锚点**跟着 `_cast_fan()` 的重构更新过**：上一轮"雾与灯同源"把遮挡矩形
        #    从"数组 `r[0..3]`"换成了 `LightRig.occluder_rect()` 交出来的 `Rect2`，
        #    循环变量也从 `r` 变成了 `rc`。旧锚点写着 `r[0], r[1], …`，在当前源码里
        #    **命中 0 次** —— 起跑前的 `stale_patches()` 前置校验当场拦下（40 秒），
        #    否则这一条会一路跑完再报"预期变红却没有"，看着像"断言没牙"。
        #    改了源码里"长得像补丁目标"的那一行，就要回来核对这里。
        "edits": [
            (
                "fog.gd",
                "\t\tvar best := radius\n"
                "\t\tfor rc in rects:\n"
                "\t\t\tvar t := Proj.ray_rect_dist(sx, sy, dx, dy,\n"
                "\t\t\t\trc.position.x, rc.position.y, rc.size.x, rc.size.y)\n"
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
        "serial": True,   # 碰真窗口 → 永远串行跑（并发下 WM 会抖）
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
        # ⚠️ **只列"确定的那一半"**（2026-09-27 实测 5 次后的结论，见 README 二.20.5）。
        #
        # 这条变异的效果分两半：
        #   · **确定的那一半**：调用时机 —— `left = 0` 让"设尺寸"不再等 RESTORE_DELAY 步。
        #     下面那条时序断言 **5/5 全红**，钉得住。
        #   · **偶发的那一半**：最终尺寸对不对。`left = 0` 是让"我们设"和"WM 覆盖"
        #     去**抢**那一步，谁赢看运气 —— 实测五次：时序断言 5/5 红，
        #     「标题界面那一轮还原干净了」红 **3/5**，「尺寸真的被我们设回」红 **1/5**。
        #     （顺带说明 `RESTORE_DELAY` **不是**多余的余量：它挡掉的正是一个真竞态；
        #      基线里这条一直稳绿，是"等够 6 步"在起作用。）
        #
        # → **偶发的那一半两边都不能写**：写进 expect 会 5 次里错 2~4 次，
        #   写进 forbid 会 5 次里错 1~3 次，**两种写法都让这条变异随机报错**。
        #   留白反而是对的：它们照旧以"？额外"出现在日志里（看得见，但不参与判定）。
        #   它们**有牙**，只是归属另一条变异 ——「tick 算出来的尺寸不下发（记了不用）」
        #   稳定地让这两条一起红。**一条断言一个归属**。
        "expect": [
            "★ 【本机时序陷阱的判据】退出全屏后**恰好**先等 RESTORE_DELAY 步",
        ],
    },
    {
        "name": "is_fullscreen 只认 FULLSCREEN（漏掉独占全屏）",
        "serial": True,   # 碰真窗口 → 永远串行跑（并发下 WM 会抖）
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
        "serial": True,   # 碰真窗口 → 永远串行跑（并发下 WM 会抖）
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
        "serial": True,   # 碰真窗口 → 永远串行跑（并发下 WM 会抖）
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
    # ── 迷雾的高度 / 体积 / 飘移（README 二.19）──────────────────────────
    {
        "name": "高度没写进 G 通道（只在 GDScript 里算了算）",
        # _rebuild 里那张照亮场贴图是"世界 → 屏幕"的唯一通道：
        # G 通道不写的话，着色器里 alt 恒为 0 —— 高度整条链在 GPU 那侧断掉，
        # 而 GDScript 侧的 height_at / 高度场断言全部照常绿（它们不经过贴图）。
        "edits": [
            (
                "fog.gd",
                "\t\t\t_img.set_pixel(i, j, Color(v2, _alt[row2 + i], 0.0, 1.0))",
                "\t\t\t_img.set_pixel(i, j, Color(v2, 0.0, 0.0, 1.0))",
            ),
        ],
        "expect": [
            "★ 高度真的从世界进了贴图的 G 通道（不是只在 GDScript 里算了算）",
            "★ 旋钮 height_fall 真的接在画面上",
            "★ 雾沉在地面：墙顶剩的雾明显少于墙脚",
        ],
    },
    {
        "name": "照亮场算了但不上传（贴图不 update）",
        # 与上一条是**两层**：上一条坏在"写进 `_img`"，这条坏在"把 `_img` 送上 GPU"。
        # 断言必须两边都覆盖 —— 它读的是 `ImageTexture.get_image()`（真回读），
        # 所以这条也能红。⚠️ 这条的爆炸半径**故意很大**（雾永远不揭晓），
        # 报告里会连带红一片；它验的是"接线"，不是"雾好不好看"。
        "edits": [
            (
                "fog.gd",
                "\t_tex.update(_img)\n",
                "\tif false:\n\t\t_tex.update(_img)\n",
            ),
        ],
        "expect": [
            "★ 高度真的从世界进了贴图的 G 通道（不是只在 GDScript 里算了算）",
        ],
    },
    {
        "name": "着色器无视高度衰减（退回一层平的灰）",        "edits": [
            (
                "fog.gd",
                "\tfloat dens = mist_max * (1.0 - height_fall * alt);",
                "\tfloat dens = mist_max;",
            ),
        ],
        "expect": [
            "★ 旋钮 height_fall 真的接在画面上",
            "★ 雾沉在地面：墙顶剩的雾明显少于墙脚",
        ],
        "forbid": [
            "★ 旋钮 height_parallax 真的接在画面上",
            "★ 旋钮 height_mix 真的接在画面上",
        ],
    },
    {
        "name": "去掉高度视差（图案不再锚在地面）",
        # ⚠️ 这行的**变量名换过**：雾改成世界空间采样后，旧写法
        # `float sink = height_parallax * alt * height_top / view_h;` 变成了
        # `float hz = ...`（去掉 / view_h —— 除数挪进了下面的世界坐标换算里）。
        # 2026-09-27 全量跑就栽在这儿：`待替换文本出现 0 次`。
        # → 改 fog.gd 里任何一行"长得像补丁目标"的代码后，**顺手 grep 一遍变异表**。
        "edits": [
            (
                "fog.gd",
                "\tfloat hz = height_parallax * alt * height_top;",
                "\tfloat hz = 0.0;",
            ),
        ],
        "expect": [
            "★ 旋钮 height_parallax 真的接在画面上",
        ],
        "forbid": [
            "★ 旋钮 height_fall 真的接在画面上",
            "★ 旋钮 height_mix 真的接在画面上",
        ],
    },
    {
        "name": "退回单层雾（浮雾层没了）",
        "edits": [
            (
                "fog.gd",
                "\tfloat n = mix(n1, n2, clamp(alt * height_mix, 0.0, 1.0));",
                "\tfloat n = n1;",
            ),
        ],
        "expect": [
            "★ 旋钮 height_mix 真的接在画面上",
        ],
        "forbid": [
            "★ 旋钮 height_fall 真的接在画面上",
            "★ 旋钮 height_parallax 真的接在画面上",
        ],
    },
    {
        "name": "屋顶与南立面的判高反了（高度场贴错段）",
        # _prism_z 的两段（南立面 0→h 渐变 / 屋顶恒 h）对调：
        # 屋顶带会读到 (y1-wy)*s（比 h 大、被夹到 1），南立面反而恒定 ——
        # "墙顶那一格就是墙高"与屋顶窗前提这两条直接红。
        "edits": [
            (
                "fog.gd",
                "\tif wy >= y1 - h / s:\n\t\treturn (y1 - wy) * s\n\tif wy >= y0 - h / s:\n\t\treturn h\n",
                "\tif wy >= y1 - h / s:\n\t\treturn h\n\tif wy >= y0 - h / s:\n\t\treturn (y1 - wy) * s\n",
            ),
        ],
        "expect": [
            "★ 墙顶那一格在高度场里就是墙高（不是 0，也不是整屏一个值）",
            "高度测试窗整块都坐在屋顶上",
        ],
    },
    {
        "name": "雾不会动（漂速归零）",
        "edits": [
            (
                "fog.gd",
                "const MIST_SPEED := 0.16",
                "const MIST_SPEED := 0.0",
            ),
        ],
        "expect": [
            "★ 雾会飘：翻涌关掉后推进 6 秒",
            "★ 剂量-反应：漂速减半",
            "★ 漂速够快：2 秒窗的平均差",
        ],
        "forbid": [
            "★ 雾会翻涌",
        ],
    },
    {
        "name": "_rebuild 不写 mist_time（雾的时间与世界脱钩）",
        # 摘掉这一行后，自检里手动 set 的 mist_time 会一直留着 ——
        # ②d/②e 全都照样绿（它们本来就直接拧 uniform），只有"泵世界之后
        # uniform 必须跟上来"这条管道断言抓得住它。
        "edits": [
            (
                "fog.gd",
                "\tmat.set_shader_parameter(\"mist_time\", w.time)\n",
                "",
            ),
        ],
        "expect": [
            "★ 雾的时间跟着世界走",
        ],
        "forbid": [
            "★ 雾会飘：翻涌关掉后推进 6 秒",
        ],
    },
    # ── 雾长在地图上 / 伤害光圈变小（2026-09-27）────────────────────────────
    # 用户这一轮的两句话：「让迷雾是地图本身的元素，不要跟着主角动」与
    # 「减小伤害产生的光圈」。两条需求都属于**看起来正常、其实没做到**那一类：
    # 雾跟着镜头走一样"有雾"，光圈大一点一样"有打击感" —— 只有断言会说话。
    {
        "name": "雾纹退回屏幕空间采样（复现用户报的「雾跟着主角动」）",
        # 只去掉 `gw` 里的 `cam_xy` 两项：噪声的**尺度、形状、漂移全不变**，
        # 变的只有"它长在哪" —— 从"长在地图上"退回"贴在屏幕上"。
        # 这就是用户看到的现象：主角一走，整片雾跟着镜头一起平移。
        #
        # 期望是**正反两条一起红**：自检把这件事写成了一对判据 ——
        # 「把平移抵消掉应当对得上」（正）与「不抵消就该明显不同」（反）——
        # 退成屏幕空间之后两条恰好互换，所以这一条变异同时钉住它们。
        "edits": [
            (
                "fog.gd",
                "\tvec2 gw = vec2(SCREEN_UV.x * view_w - view_w * 0.5 + cam_xy.x,\n"
                "\t\t(SCREEN_UV.y * view_h - view_h * 0.5) / ysquash + cam_xy.y + hz / ysquash);",
                "\tvec2 gw = vec2(SCREEN_UV.x * view_w - view_w * 0.5,\n"
                "\t\t(SCREEN_UV.y * view_h - view_h * 0.5) / ysquash + hz / ysquash);",
            ),
        ],
        "expect": ["★ 雾长在地图上", "★ 反向对照"],
        # 改坏的只是"锚在哪"，雾本身还在、还会飘 —— 那几条必须保住。
        "forbid": ["★ 雾会飘：翻涌关掉后推进 6 秒", "★ 雾会翻涌"],
    },
    {
        "name": "相机没发给雾着色器（uniform 接线断，雾纹不再跟着镜头挪）",
        # 与上一条**可观察结果相同、坏的那一层不同**：着色器照样读 `cam_xy`，
        # 只是再也没人发它（`_rebuild` 里发的是 ZERO）→ 等价于"镜头永远停在地图原点"。
        # 留这一条是因为它最像"重构时顺手删了一行"，而着色器那边看着毫无问题。
        "edits": [
            ("fog.gd", '\tmat.set_shader_parameter("cam_xy", w.draw_cam)\n', ""),
        ],
        "expect": ["★ 雾长在地图上", "★ 反向对照"],
        # ── forbid 为什么是空的（2026-09-27 实测，不是留白偷懒）────────────────
        # 这根线**是共享输入**：`cam_xy` 同时喂两处 ——
        #   ① `gw`（雾纹长在世界坐标上）　② `ruv`（照亮场快照按相机位移挪回来）。
        # 本轮把 ② 从 `texture(reveal_tex, SCREEN_UV)` 改成 `ruv` 之后，
        # 断掉这一根线的后果**不再是**"雾纹不跟着镜头挪"这么局部：
        # 相机离锚 712.90px → `ruv` 全屏偏掉 0.557 个屏幕 → 被 `repeat_disable`
        # **夹到贴图边缘那一个 texel** → reveal / alt 全屏塌成同一个常数。
        # 于是这一条变异会连带打红（手动打补丁跑了一轮，全部**确定**复现，不是偶发）：
        #   · ★ 雾会翻涌                        moved 0.3236 → 0.0000（diff 0.0258 → 0.0061）
        #   · ★ 翻涌幅度这个旋钮真的在缩放效果      0 → 0.0000 → 0.0000
        #   · ★ 对照：三个旋钮 × 三个相位下墙脚逐字节不变　0 → 0.0495（alt 不再是 0 → hz 全屏非零）
        #   · 墙影锚定那一段的 4 条 + 2 条前提（它们本来就归本变异，见 expect）
        # 这些都不是"另一层被误伤"，而是**同一根线断了的同一个后果**。所以：
        #   · 旧的 `forbid: ["★ 雾会翻涌"]` 已**过期** —— 它写的时候 ② 还是 SCREEN_UV，
        #     那时断线只动雾纹、翻涌确实不受影响；② 改掉之后它静默变成了假失败。
        #     ⚠️ 教训：**一个 uniform 被第二处消费之后，旧变异的"不该红"清单会过期**，
        #     而且过期得毫无征兆（跑完全程才报"不该红却红了"）。
        #   · 剩下的断言要么是连带的（会红，写进 forbid 必然假失败），要么是**恒真**的
        #     （例如"翻涌关掉后两帧逐字节相同"—— 基线绿时它必然绿，列进来也是空的）。
        #   · `★ 雾会飘：翻涌关掉后推进 6 秒` 是**险绿**的（moved 0.9535 → 0.8997：
        #     密度被改坏、判据跟着松了）—— 故意不列，免得把一次侥幸写成契约。
        # 故 forbid 留空，多余的连带红如实以"？额外"出现在日志里（看得见，不参与判定）。
        "forbid": [],
    },
    {
        "name": "两处伤害光圈都退回旧尺寸（复现用户报的「光圈太大」）",
        # 四个常量一起回退 —— 这才是用户当初看到的那一版。
        # 期望：三条**绝对上限**全红（面积 / 能量 / 真实命中那一发），
        # 而「真的在发光」与两条**剂量-反应**必须保住：改坏的是"多大"，不是"有没有"。
        "edits": [
            ("art.gd", "const TEXT_GLOW_R := 0.85", "const TEXT_GLOW_R := 1.20"),
            ("art.gd", "const TEXT_GLOW_A := 0.22", "const TEXT_GLOW_A := 0.30"),
            ("art.gd", "const PARTICLE_GLOW_R := 2.1", "const PARTICLE_GLOW_R := 3.4"),
            ("art.gd", "const PARTICLE_GLOW_A := 0.30", "const PARTICLE_GLOW_A := 0.50"),
        ],
        "expect": [
            "★ 光圈变小了：亮起来的像素数",
            "★ 光圈变小了（能量口径）",
            "★ 真实命中的光圈也变小了",
        ],
        "forbid": [
            "★ 这一版的光圈真的在发光",
            "★ 剂量-反应：旋钮拧回旧尺寸那一档",
            "★ 剂量-反应：漂速减半",
        ],
    },
    {
        "name": "光圈旋钮失效（半径与不透明度不再跟着 glow_mul 缩放）",
        # 四个调用点全摘掉 `glow_mul`：画出来的光圈**尺寸一点没变**，只是那个旋钮
        # 从画线上脱开了。期望正好与上一条**互补**：两条剂量-反应红，
        # 三条绝对上限与「真的在发光」保住 —— 这两条变异合起来说明这一对判据各有分工：
        # **绝对上限拦"整体变大"，剂量-反应拦"旋钮没接上"。**
        #
        # ⚠️ 必须四个调用点一起摘：只摘飘字那一处的话，火花那一半还在响应旋钮，
        #    px_old 仍然远大于 px_now，剂量-反应照样绿 —— 那样这条变异会假通过。
        "edits": [
            (
                "art.gd",
                "\t\tglow(ci, Vector2(px, py - size * 0.36), size * TEXT_GLOW_R * glow_mul, c,\n"
                "\t\t\tTEXT_GLOW_A * glow_mul * life01)",
                "\t\tglow(ci, Vector2(px, py - size * 0.36), size * TEXT_GLOW_R, c,\n"
                "\t\t\tTEXT_GLOW_A * life01)",
            ),
            (
                "world.gd",
                '\t\tArt.glow(ci, gp, float(q["size"]) * Art.PARTICLE_GLOW_R * Art.glow_mul, gc,\n'
                "\t\t\tArt.PARTICLE_GLOW_A * Art.glow_mul, 4)",
                '\t\tArt.glow(ci, gp, float(q["size"]) * Art.PARTICLE_GLOW_R, gc,\n'
                "\t\t\tArt.PARTICLE_GLOW_A, 4)",
            ),
        ],
        "expect": [
            "★ 剂量-反应：旋钮拧回旧尺寸那一档",
            "★ 真实命中的光圈也变小了",
            # 下面这两条**也该红**（第一版把这两条列进了 forbid，实测打脸）：
            # 旋钮一旦不从画线上走，"把旋钮拧到 0"就**关不掉**那两处光晕了 ——
            # 于是"关掉之后画面会变"与"真实命中会打出光晕"这两条也一起红。
            # 它们量的是"这团光能不能被关掉"，而这个变异坏的正是"关掉"。
            "★ 这一版的光圈真的在发光",
            "真实命中确实会打出这套光晕",
        ],
        # 顺带记一件事：两条**绝对上限**在这里是"0 ≤ 上限"式的**平凡绿**
        # （测不出东西时数值塌成 0）。这不是漏测 —— 塌成 0 这件事由上面
        # 「真的在发光」那条拦住了。两条缺一条都拦不住对应的失败方式。
        "forbid": [
            "★ 光圈变小了：亮起来的像素数",
            "★ 光圈变小了（能量口径）",
        ],
    },
    # ────────────────────────────────────────────────────────────────
    # 灯河：过关 / 回溯 / 留在地图（用户原话见 `World._draw_lamp_river` 的类头注释）
    # ────────────────────────────────────────────────────────────────
    {
        "name": "灯河·「已刷已清」只摆错一半（`spawned` 留在 false）",
        # 这是"不刷怪"那条断言**唯一**能失败的方式，而且刻意摆得很窄：
        # `cleared` 依然是对的（所以"状态里就是已清空"与 `_is_peaceful` 全都不动），
        # 只把 `spawned` 留在 false —— 于是 `_update_waves` 的"刷新"分支照样会走，
        # 站在锚点上就刷出来了。
        #
        # 为什么不用"整段 for 循环删掉"那种更狠的改法：那会把 `cleared` 也一起弄丢，
        # 连带一堆状态断言变红，"不刷怪这条到底有没有牙"就淹没在一片红里了。
        # **量哪一层，就把别层冻住。**
        #
        # 反过来，阳性对照（⑦b：手动抹掉标记 → 立刻刷出来）必须**保持绿** ——
        # 它量的是"量法本身有没有牙"，跟"状态对不对"是两件事。
        "edits": [
            ("world.gd", '\t\twv["spawned"] = true\n', '\t\twv["spawned"] = false\n'),
        ],
        "expect": ["★ 已打通的关卡不刷怪"],
        "forbid": [
            "★ 那一关的波次在**状态里**就是已清空",
            "★ 阳性对照：只把那一波记成",
            "★ 全通之后停在这一关也是照亮且没有敌人的",
        ],
    },
    {
        "name": "灯河·亮色阶整条摘掉（回访的关卡不再「全图照亮」）",
        # `Art.lit_palette` 是"全图照亮"里唯一**抬得动画面的**那一层
        # （只改 `ambient` 值 1.18 倍，见 `Art.lit_palette` 的注释）。
        # 摘掉它，三条照亮判据应该一起红，而"灯河画出来了"/"停下这一关和平"
        # 这些**状态层**的断言必须保住 —— 坏的是"多亮"，不是"有没有"。
        #
        # ⚠️ 补丁要连 `if cleared:` 那一行一起摘 —— 只摘里面那句会留下一个**空块**，
        #    GDScript 直接解析错误，引擎抱着日志不退出（症状是"这一轮没跑成：
        #    自检超过 240 秒没退出"）。本批第一版就是这么翻的。
        "edits": [
            (
                "world.gd",
                "\tif cleared:\n\t\tpal = Art.lit_palette(pal, LIT_PALETTE_K)\n",
                "",
            ),
        ],
        "expect": [
            "★ 全图照亮真的画在屏幕上",
            "★ 全图照亮是「看得见的亮」",
            "★ 已打通的关卡比未打通那一版亮",
        ],
        "forbid": [
            "★ 全通之后停在这一关也是照亮且没有敌人的",
            "★ 回到的是「已恢复光明」的那一版",
            # 底子变暗 → 加色的浮灯**更**看得见 → 这一条反而更绿。
            # 写上它是为了钉住"这条变异只动色阶那一层"。
            "★ 打通之后地图上真的有「灯河」",
        ],
    },
    {
        "name": "灯河·色阶调过头（2.4 → 12，画面糊成一片）",
        # 与上一条**互补**：上一条是"根本没开"，这一条是"开过头"。
        # 期望：撞上绝对带的**上限**（0.88），而两条"更亮"的判据仍然绿
        # —— 它确实更亮了，只是亮到量不出区别。这正是上限存在的理由：
        # 加色光斑在亮底上会顶到 1.0，"更亮"在过曝区是**假的**。
        #
        # ？额外（实测）：`★ 打通之后地图上真的有「灯河」` 也一起红 ——
        # 过曝之后加色的浮灯在已经顶到 1.0 的地板上**加不出东西**，
        # 于是那条像素判据也量塌成 0。这是已知的耦合（浮灯是加色层），
        # 不是误伤；真要改到那个亮度，两边都会来叫。
        "edits": [
            ("world.gd", "const LIT_PALETTE_K := 2.4", "const LIT_PALETTE_K := 12.0"),
        ],
        "expect": ["★ 全图照亮是「看得见的亮」"],
        "forbid": ["★ 全图照亮真的画在屏幕上"],
    },
    {
        "name": "灯河·「逆流」指向自己（换关按钮点下去还在原地）",
        # 面板上那一项照样在、照样能按 —— 坏的是"按下去去哪"。
        # 这正说明"面板显示了什么"与"按下去做了什么"必须走**同一个出处**
        # （`World.ferry_options()` 的 target 就是 `Main.sail_to` 拿的那个数）。
        "edits": [
            ("world.gd", '{"id": "up", "target": lv - 1,', '{"id": "up", "target": lv,'),
        ],
        "expect": ["★ 逆流而上 → 真的回到了第一关"],
        "forbid": [
            "③ 第二关的渡口**同时给出两个方向**",
            "★ 全图照亮真的画在屏幕上",
        ],
    },
    {
        "name": "灯河·「回到地图」不记账（`_mark_cleared` 一次都不调）",
        # ⚠️ 这条变异**是实测逼出来的**：第一版摘的是 `sail_to()` 里那两行，
        #    结果 0 条变红 —— 因为 `stay_here()` 里也记了一遍，
        #    两个独立的层各能单独满足同一条断言，那条断言就是没牙的。
        #    收成"只有 `stay_here()` 一处记账"之后，这条才真的有牙。
        #
        # 期望：①b（记账）与「三关都记成了」红；
        # 而 ①c（落定）**必须保住** —— 记账与落定是两层，这条只坏记账那一层。
        "edits": [
            (
                "main.gd",
                '\tif world != null and world.cleared:\n\t\t_mark_cleared(int(prog["level"]))\n',
                "",
            ),
        ],
        "expect": [
            "★ ①b 按下空格那一刻就记上了账",
            "★ 三关都记成了「已打通」",
        ],
        "forbid": ["★ ①c 而且这一关**就地**落定成「已恢复光明」"],
    },
    {
        "name": "灯河·「留在地图中」不落定（退回「只擦掉面板继续走」）",
        # 用户原话的后半段要的是"**此时所有地图**都应该被照亮并且没有敌人"，
        # 包括脚下这一张。把 `settle_cleared_state()` 那一行拿掉，
        # 留下来的就是"刚打完 Boss、雾还在慢慢散、波次标记还是刚才那一份"的世界。
        "edits": [
            ("main.gd", "\tif world != null:\n\t\tworld.settle_cleared_state()\n", ""),
        ],
        "expect": [
            "★ 全通之后停在这一关也是照亮且没有敌人的",
            "★ ①c 而且这一关**就地**落定成「已恢复光明」",
        ],
        "forbid": [
            "★ 三关都记成了「已打通」",
            "★ 选择留在地图中 → 停在第三关，没有被踢回标题、也没有重开",
        ],
    },
    {
        "name": "灯河·浮灯一盏都不画（`_draw_lamp_river` 直接返回）",
        # 期望只有"河身那扇窗真的被点亮"这一条红。
        # ⚠️ 与它配对的"只在河身那一带"（`px_ctl <= px_river/8`）在这个失败方式下是
        #    **平凡绿**（两边都是 0，0 <= 0）—— 这跟伤害光圈那两条绝对上限是同一回事：
        #    测不出东西时数值塌成 0。塌成 0 这件事由这一条拦住了，两条缺一不可。
        #
        # ⚠️ 补丁里**参数名必须留着 `ci`**：把函数头改成早退时顺手把参数改名为 `_ci`，
        #    下面那些（已经不可达的）`ci` 引用就变成"未声明标识符"——
        #    那是**编译错误**，引擎又会抱着日志不退出，判定变成一堆看不懂的东西。
        #    本批第一版就是这么翻的。
        "edits": [
            (
                "world.gd",
                "func _draw_lamp_river(ci: CanvasItem) -> void:\n"
                "\tif not lamp_river_on or not cleared or goal_prop.is_empty():\n"
                "\t\treturn\n",
                "func _draw_lamp_river(ci: CanvasItem) -> void:\n\tif true:\n\t\treturn\n",
            ),
        ],
        "expect": ["★ 打通之后地图上真的有「灯河」"],
        "forbid": ["★ 全通之后停在这一关也是照亮且没有敌人的"],
    },
    # ── 墙影的时间锚定 / 开始界面·自定义快捷键（2026-09-27）────────────────
    # 用户这一轮的三句话：「修一下雾与墙壁碰撞时的不协调」「添加一个开始界面」
    # 「可以自定义快捷键，放在开始界面的设置里」。前两条属于**看起来很正常**那一类：
    # 少了时间锚定画面照样有雾、照样有影子，只是"墙周围的阴影一直乱晃"；
    # 改键只改内存不装 InputMap，界面上那一行也会立刻显示新键名 —— 只有玩家按下去
    # 才知道没反应。所以这一组的期望表里几乎每一条都钉在"玩家真的按得动吗"上。
    {
        "name": "墙影·旧快照不再按相机挪回去（退回屏幕锚定，复现用户报的「阴影乱晃」）",
        # 只把采样点从 `SCREEN_UV + Δ` 退回 `SCREEN_UV`：照亮场贴图的内容一个字节不变，
        # 变的只是"它画在哪儿" —— 从"长在地图上"退回"钉在屏幕上"。
        # 期望**一对正反同时红**（自检把这件事写成了一对）：
        #   正：「挪回去 == 在新相机处重建」——退成屏幕锚定之后两边差了整整 64px；
        #   反：「不挪的话同一片里明显有一批像素变了」——这时"挪了"与"不挪"是同一张图，
        #       比值判据 `d_nomove >= 20 × d_stale` 当场塌掉。
        # 还有那条"只改 Δ 造成的差"的前提：Δ 已经没人读了，它必然变 0。
        "edits": [
            (
                "fog.gd",
                "\tvec2 ruv = SCREEN_UV + vec2(cam_xy.x - rebuild_cam.x,\n"
                "\t\t(cam_xy.y - rebuild_cam.y) * ysquash) / vec2(view_w, view_h);",
                "\tvec2 ruv = SCREEN_UV;",
            ),
        ],
        "expect": [
            "★ 【用户要的】旧快照按相机位移挪回去之后",
            "★ 阴性对照：**不挪**的话同一片里",
            "前提：那个锚真的接在画面上",
        ],
        # 这两个 uniform 照样发得出去、"雾长在地图上"那条也没坏（雾纹用的是 cam_xy，
        # 与这一下锚定无关）—— 它们必须保住，否则这条变异就分不清坏在哪一层了。
        "forbid": [
            "★ 那一下位移用的是**着色器里的**锚",
            "前提：着色器这一刻算出来的位移正好是 64px",
            "★ 雾长在地图上",
            "★ 反向对照",
        ],
    },
    {
        "name": "墙影·`_rebuild` 不把锚写进着色器（只在 GDScript 里记一笔）",
        # 与上一条**症状像、坏的那一层不同**：着色器照样读 `rebuild_cam`，
        # 只是再也没人发它 —— 于是引擎侧那个默认值 (0,0) 一直生效，
        # 而 `rebuild_cam_xy()` 照样返回正确答案。这条最像"重构时顺手删了一行"。
        #
        # ⚠️ 这个变异是**广谱**的：锚恒为 (0,0) 意味着照亮场被整体挪掉 camera 那么多，
        #    连前面「迷雾的高度/体积/飘移」那一段的几条断言都会跟着红（它们是
        #    **连带**，不是这一条要钉的东西）—— 连带的那些一半写在 `expect` 里、
        #    写不进去的留白由日志的"？额外"如实报出来。别为了让日志好看去硬掰。
        #
        # ⚠️ 这一条**逼出过自检自己的一处缺陷**：原来 `u_anc` / `uni_anchor` 两处
        #    都是 `var x: Vector2 = mat.get_shader_parameter(...)` —— 而"从没被 set 过"
        #    时它返回 **null**，那一行直接抛类型错误 → **段内截断** → 预期该红的两条
        #    连登记都没有，日志上只剩一句"断言凭空变少"。哨兵必须站在"它坏了"的
        #    那一边也跑得下去 → 改成 `_shader_vec2()`。
        "edits": [
            (
                "fog.gd",
                "\t_rebuild_cam = Vector2(camx, camy)\n"
                "\tmat.set_shader_parameter(\"rebuild_cam\", _rebuild_cam)\n",
                "\t_rebuild_cam = Vector2(camx, camy)\n",
            ),
        ],
        "expect": [
            "★ 那一下位移用的是**着色器里的**锚",
            "★ 【用户要的】旧快照按相机位移挪回去之后",
            "前提：着色器这一刻算出来的位移正好是 64px",
            "★ 阴性对照：**不挪**的话同一片里",
        ],
        # ⚠️ **"那个锚真的接在画面上"这条前提在这一轮里是绿的** —— 别把它写进 expect。
        #    它量的是"同一张贴图、同一个世界，只改 Δ 画面会不会变"，而自检自己那几处
        #    `set_shader_parameter("rebuild_cam", ...)` **照样生效**（只有 `_rebuild` 里那一行
        #    被摘掉了），所以 Δ 依然影响画面。它归属的是**另一条**变异「旧快照不再按相机
        #    挪回去」——那时着色器整个不读锚，它才红。**一条断言一个归属。**
        "forbid": [
            "前提：那个锚真的接在画面上",
            "前提：取景窗压在雾层梯度最陡的地方",
        ],
    },
    # ── 开始界面 · 自定义快捷键 ───────────────────────────────────────────
    {
        "name": "改键只改内存表、不重装 InputMap（复现玩家说的「改了没用」）",
        # 最典型的一处：`binds` 改了、设置界面立刻显示新键名、看起来一切正常，
        # 但 InputMap 里还是旧键 —— 玩家按新键毫无反应、按旧键照样能用。
        # 期望三条全红：两条**成对量两层**的（`binds` + InputMap 同时比），
        # 加上"存盘读回来之后 InputMap 也得跟着恢复"那一条。
        "edits": [
            (
                "autoload/game_input.gd",
                "\t_install()\n\tsave_bindings()\n\treturn \"\"\n",
                "\tsave_bindings()\n\treturn \"\"\n",
            ),
        ],
        "expect": [
            "★ 【用户要的】改键真的落到 **InputMap** 上",
            "★ 重绑之后**旧键不再属于这个动作**",
        ],
        # 存盘那一层没坏，必须保住。
        # ⚠️ 这里**刻意不写**"★ 【用户要的】存盘能被读回来"：它读的是 `load_bindings()`
        #    之后的 InputMap，而读盘那条路**自己会 `_install()`** —— 于是"界面上改键
        #    没装 InputMap"这个失败方式它天然不敏感（实测：这一轮它确实是绿的）。
        #    它归属的是另一条变异「改键不存盘」，一条断言一个归属。
        "forbid": [
            "★ 改键会**立刻存盘**",
            "★ 【用户要的】存盘能被读回来",
        ],
    },
    {
        "name": "改键不存盘（改完看着对，重启就没了）",
        # 与上一条*对称*的一条：这次坏的是盘、不是 InputMap。
        # ⚠️ 第一条期望**逼出过一处真缺陷**：原来它写的是"起手盘上是干净的、
        #    改完之后那份一定在"，而 ⑥ 的「全部恢复默认」走 `reset_bindings()`
        #    （默认 `persist = true`）**自己就会写一次盘** —— 于是"盘上有文件"这条
        #    被两条独立的路径同时满足，这条断言在这个变异下**照样全绿**。
        #    修法：量之前先把盘上那份 `remove` 掉，并且比**内容**里有没有这个动作。
        "edits": [
            (
                "autoload/game_input.gd",
                "\t_install()\n\tsave_bindings()\n\treturn \"\"\n",
                "\t_install()\n\treturn \"\"\n",
            ),
        ],
        "expect": [
            "★ 改键会**立刻存盘**",
            "★ 【用户要的】存盘能被读回来",
        ],
        "forbid": ["★ 【用户要的】改键真的落到 **InputMap** 上"],
    },
    {
        "name": "改键不检查冲突（把别人正在用的键静默抢走）",
        # 玩家没碰过的那个动作会被顶成"没有按键的死动作" —— 比拒绝更糟。
        # 核心层（`set_bind`）与界面层（抓键之后）各有一条断言，两条都要红。
        #
        # ⚠️ 这个变异有**连带**：`inject_key(KEY_W)` 被接受了，抓键状态就结束了、
        #    页面回到设置页，于是紧接着那条"抓键状态下按 Esc 能退出来"会跟着红
        #    （它那时根本不在抓键状态了）。**连带的那一半不写进 forbid** ——
        #    该红的地方红、不该红的地方由"？额外"如实报出来，别硬掰成期望。
        "edits": [
            (
                "autoload/game_input.gd",
                "\tvar other := action_using(key, action)\n"
                "\tif other != \"\":\n"
                "\t\treturn \"「%s」已经用在「%s」上。\" % [OS.get_keycode_string(key), label_of(other)]\n",
                "",
            ),
        ],
        "expect": [
            "★ 核心层拒绝冲突",
            "★ 【界面那一层】改到一个被占用的键",
        ],
        "forbid": [
            "★ 【用户要的】改键真的落到 **InputMap** 上",
            "★ 改键会**立刻存盘**",
        ],
    },
    {
        "name": "菜单越界不回绕（撞墙停住，复现「按方向键没反应」）",
        # 只把取模回绕换成夹取。第一行再往上 → 停在第一行（玩家会以为按键失灵）。
        "edits": [
            (
                "main.gd",
                "\t\t\t\t_title_index = (_title_index + nav + n) % n\n",
                "\t\t\t\t_title_index = clampi(_title_index + nav, 0, n - 1)\n",
            ),
        ],
        "expect": ["★ 菜单能用方向键选（按下即动），并且越界会**回绕**"],
        "forbid": ["★ 【用户要的】进的是**开始界面菜单**"],
    },
    {
        "name": "重绑表漏掉一个动作（它在设置界面里根本不出现，玩家想改也改不到）",
        # ⚠️ 这一条**只**打在"表与动作表一一对应"那一条上：行数判据 `n_rows == n_reb + 2`
        #    两边同源、照样成立；行序判据只比前 `n_reb` 行、也照样成立 ——
        #    这正是"一条断言被别的断言平凡满足"的例子，所以这一条变异值得单独留着。
        "edits": [
            ("autoload/game_input.gd", "\t[\"fullscreen\", \"全屏\"],\n", ""),
        ],
        "expect": ["★ 重绑表与动作表**一一对应**"],
        "forbid": [
            "★ 【用户要的】「设置」里就是按键重绑表",
            "★ 每个动作都有出厂按键",
            "★ 设置表的行序与文案和 `GameInput.REBINDABLE` **逐行一致**",
        ],
    },
]


def worker_project(i: int) -> pathlib.Path:
    """第 i 个 worker 用的**工程副本**（`i >= 1`；真工程本身从不发出去）。

    为什么必须复制整份工程：变异是**就地改 `src/`**，两个 worker 不能共用一份 src。
    一次复制约 63MB（~1 秒），比"串行跑几十轮"便宜得多。
    连 `.godot/` 一起复制，是为了让副本**不必重新导入** —— 变异从不新增
    `class_name` 脚本，那份类缓存一直有效（这正是每轮省下 ~8 秒的地方）。

    ⚠️ **真工程不发出去**（第一版把 worker 0 指到真工程上了）：并发跑的时候只该碰副本，
    于是"整批被强杀"也不会在盘上留下改坏的 `src/` —— `restore()` 只管得住正常退出那一路。
    """
    dst = CACHE / f"w{i}" / PROJ.name
    if not dst.exists():
        shutil.copytree(PROJ, dst)
    else:
        # 只写不删地刷回基线（上一轮留下的改动与截图都作废）
        shutil.copytree(SRC, dst / "src", dirs_exist_ok=True)
    return dst


def run_verify(proj: pathlib.Path) -> dict:
    """跑一次自检，返回 report.json（断言变红是预期内的，退出码不用管）。

    ⚠️ **必须确认这份报告是这一轮写出来的**，否则"引擎挂住 / 解析错误 / 补丁把文件改坏"
    这些情况下读到的会是**上一轮那份报告** —— 结果看起来是一组完全正常的断言名，
    而这一轮其实根本没跑完。照着假结果去改代码是最贵的一种浪费。

    ⚠️ **但不要用"先删掉旧的 report.json"来实现它**（第一版就是那么写的，翻车了）：
    沙箱有「批量删除保护」，按 turn 累计，达到阈值后**连删一个文件都会被拦**
    （`SAFE_DELETE_BULK_CONFIRM_REQUIRED`，而且会**卡住等确认**）。实测并发那一轮
    四个 worker 各撞一次，整批跑挂、日志也没了。→ 改成**只记 mtime、跑完必须变**，
    一条删除都不发生，效果完全等价（自检是"跑完一次性写出来"的，所以文件被重写
    必然改 mtime）。想要更强就把 run tag 经环境变量传进去让报告自己带上（未做）。
    """
    rep = proj / REPORT_REL
    before = rep.stat().st_mtime_ns if rep.exists() else -1
    env = dict(os.environ)
    for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
              "ALL_PROXY", "all_proxy"):
        env.pop(k, None)          # 本机预设了代理，本地回环会 502
    tmp = CACHE / "tmp"           # 本机 /tmp 只有 10MB，必须落在真实磁盘上
    tmp.mkdir(parents=True, exist_ok=True)
    env["TMPDIR"] = str(tmp)
    try:
        # `--disable-vsync` 只值 6%（42.9 → 40.2 秒），但它**改的是帧节奏** ——
        # 而自检里有一段"退出全屏后**第几步**才设尺寸"的时序测试（`_section_fullscreen`）。
        # 帧节奏一变，那条判据的牙齿就可能跟着变，所以留一个开关，
        # 让"引擎参数"这一层能被单独冻住做 A/B（量哪一层，就把别层冻住）。
        args = [GODOT_BIN, "--path", str(proj), "res://scenes/selfcheck.tscn",
                "--rendering-driver", "opengl3"]
        if os.environ.get("DQ_VSYNC") != "1":
            args.append("--disable-vsync")
        proc = subprocess.run(args, capture_output=True, text=True,
                              timeout=VERIFY_TIMEOUT, env=env, cwd=str(proj))
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"自检超过 {VERIFY_TIMEOUT} 秒没退出 —— 多半是 GDScript 解析错误把引擎挂住了"
            "（解析错误会让引擎打一行日志后一直不退出）") from exc
    if not rep.exists() or rep.stat().st_mtime_ns == before:
        tail = "\n".join((proc.stdout or "").splitlines()[-15:])
        raise RuntimeError(
            f"这一轮没有写出新的 report.json（rc={proc.returncode}，"
            f"mtime 没变）—— 多半是解析错误/中途崩了。stdout 尾部：\n{tail}")
    return json.loads(rep.read_text())


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


def stale_patches(picked: list[dict]) -> list[str]:
    """每条变异的 `edits` 里，`old_string` 在**当前源码**里恰好出现 1 次吗。

    为什么需要这道校验：`apply_edits` 是"找不到就抛"的（这很对），但那条错误**只在
    跑到该变异时**才发生 —— 一条陈旧补丁会让整批跑到一半才报 `待替换文本出现 0 次`，
    白等十分钟。而"补丁锚点"其实就是**源码里的一行**：改了源码里一行长得像它的代码，
    这条变异就悄悄失效了。

    2026-09-27 实例：雾改成世界空间采样后，`float sink = ... / view_h` 变成
    `float hz = ...`（除数挪进了下面的世界坐标换算），变异表没跟上 → 全量那轮才炸。

    ⚠️ 这就是"改了源码就要顺手核对变异表"的自动化版本。判据是**恰好 1 次**：
    0 次 = 锚点没了；≥2 次 = 锚点不唯一（改错了地方也不报错）。
    """
    bad: list[str] = []
    for m in picked:
        for rel, old, _new in m.get("edits", []):
            f = SRC / rel
            if not f.exists():
                bad.append(f'{m["name"]} —— {rel} 不存在')
                continue
            n = f.read_text().count(old)
            if n != 1:
                head = old.strip().splitlines()[0][:64]
                bad.append(f'{m["name"]} —— {rel}: 锚点出现 {n} 次（应为 1 次）：{head!r}')
    return bad


def apply_edits(edits: list[tuple[str, str, str]], src: pathlib.Path) -> None:
    for rel, old, new in edits:
        p = src / rel
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


def restore_into(src: pathlib.Path) -> None:
    """**覆盖式**还原：只写不删。

    刻意不用 `shutil.rmtree` —— 沙箱的批量删除保护会在目录文件数超过阈值时
    抛异常，那样 `finally: restore()` 本身就会失败，把改坏的源码留在盘上。
    """
    shutil.copytree(BAK, src, dirs_exist_ok=True)


def restore() -> None:
    restore_into(SRC)


def run_mutation(m: dict, proj: pathlib.Path) -> tuple[bool, list[str]]:
    """在一个工程副本上：打补丁 → 跑自检 → 还原。返回 (是否符合预期, 要打印的行)。

    **三条出口各自还原一次**（不靠 `finally`）：因为要先读 `got` 再还原，
    而 `finally` 里抛异常会把结果吞掉。宁可多写两次，也不能让改坏的代码留在盘上。
    """
    try:
        apply_edits(m["edits"], proj / "src")
    except Exception as exc:  # noqa: BLE001
        restore_into(proj / "src")
        return False, [f"  ✗ 打补丁失败：{exc}"]
    try:
        got = failed_checks(run_verify(proj))
    except Exception as exc:  # noqa: BLE001
        restore_into(proj / "src")
        return False, [f"  ✗ 这一轮没跑成：{exc}"]
    restore_into(proj / "src")            # 无条件还原

    exp_ok = all(any(e in g for g in got) for e in m.get("expect", []))
    bad_hits = [g for g in got if any(f in g for f in m.get("forbid", []))]
    lines = [f"  {'✓' if exp_ok and not bad_hits else '✗'} 变红的断言（{len(got)} 条）："]
    for g in got:
        exp = any(e in g for e in m.get("expect", []))
        lines.append(f"      {'✔ 预期' if exp else '？额外'} {g}")
    for e in m.get("expect", []):
        if not any(e in g for g in got):
            lines.append(f"      ✘ 预期变红却没有：{e}")
    for f in bad_hits:
        lines.append(f"      ✘ 不该红却红了：{f}")
    return exp_ok and not bad_hits, lines


def run_batch(picked: list[dict], jobs: int) -> list[str]:
    """跑一批变异，返回"不符合预期"的变异名。jobs > 1 时并发（每个 worker 一份副本）。

    ⚠️ **碰真窗口的那几条永远串行**（变异里标了 `"serial": True`）。
    它们会真去改本机窗口（全屏切换、尺寸还原），而几个进程同时跟 WM 抢的时候，
    `_section_fullscreen` 的前提断言（"真窗口能被设成测试尺寸"）会**偶发**变红 ——
    那条一红，它后面两条尺寸断言就全成了"无从谈起"，这 4 条的判定随之不可信。
    **慢一点可以接受，不可信不行** —— 所以这 4 条（62 条里就 4 条）不进并发。
    ⚠️ 2026-09-27 记账更正：曾把「退出全屏时立刻设尺寸」的"预期变红却没有"归因于并发，
    实测**串行跑它也一样不红**（所以那不是并发造成的，见 README 二.20.5）。
    """
    if jobs <= 1:
        bad: list[str] = []
        for i, m in enumerate(picked):
            print(f"▸ [{i + 1}/{len(picked)}] 变异：{m['name']}")
            ok, lines = run_mutation(m, PROJ)
            for ln in lines:
                print(ln)
            print()
            if not ok:
                bad.append(m["name"])
        return bad

    total = len(picked)
    serial_idx = [i for i, m in enumerate(picked) if m.get("serial")]
    par_idx = [i for i, m in enumerate(picked) if not m.get("serial")]
    got: dict[int, tuple[bool, list[str]]] = {}

    def live(i: int, ok: bool) -> None:
        """边跑边报一行。整批十分钟，只在最后一次性打印会**看着像卡住** ——
        这个坑本轮真踩过（`pool.map` 要等全部跑完才返回，日志一片空白）。"""
        print(f"  {'OK' if ok else 'NG'} [{i + 1}/{total}] {picked[i]['name']}",
              flush=True)

    if serial_idx:
        print(f"▸ 先串行跑 {len(serial_idx)} 条**碰真窗口**的变异"
              f"（并发下 WM 会抖，判定不可信）…")
        for i in serial_idx:
            ok, lines = run_mutation(picked[i], PROJ)
            got[i] = (ok, lines)
            live(i, ok)
        print()

    if par_idx:
        jobs = min(jobs, len(par_idx))
        # ── 并发之前先自证"并发本身不会污染判定" ────────────────────────
        # `_section_fullscreen` 会真去改本机窗口（XWayland 下的全屏切换与尺寸还原）。
        # 几个进程同时跟窗口管理器打交道时，那几条"尺寸真的被我们设回去了"的断言
        # 有理由怀疑 —— 所以先用**未打补丁**的副本并发跑一轮，要求全绿才继续。
        projects = [worker_project(i + 1) for i in range(jobs)]
        print(f"▸ 并发前提自证：{jobs} 份副本各跑一遍**未打补丁**的自检（必须全绿）…")
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            pres = list(pool.map(lambda p: failed_checks(run_verify(p)), projects))
        flaked = {i: f for i, f in enumerate(pres) if f}
        if flaked:
            # ⚠️ **本机实测就是这里拦下的**（2026-09-27）：4 个 worker 并发时，
            # `_section_fullscreen` 里这条基线断言会抖 ——
            # `★ 前提：真窗口能被设成测试尺寸 —— 设不上，下面两条尺寸断言就无从谈起`。
            # 四个进程同时跟 XWayland 要窗口尺寸，WM 顶不住；而那条前提一红，
            # 后面两条尺寸断言就全成了"无从谈起"。
            #
            # 处理：**不硬失败，退回串行**。理由：这个抖动是**偶发**的，
            # 偶发的东西不该让整批跑挂，更不该被"重试到绿"糊过去。
            # 退回串行是唯一"结论一定可信"的走法，代价只是慢。
            for i, fails in sorted(flaked.items()):
                print(f"  ⚠️ worker {i} 的基线在并发下有红的：{fails}")
            print("  → 结论：**本机并发跑不安全**（真窗口那一段会抖），退回串行。",
                  file=sys.stderr)
            for i in par_idx:
                ok, lines = run_mutation(picked[i], PROJ)
                got[i] = (ok, lines)
                live(i, ok)
        else:
            print("  并发下基线依然全绿 ✅ —— 并发没有污染判定，开跑。\n")
            chunks: list[list[tuple[int, dict]]] = [[] for _ in range(jobs)]
            for k, i in enumerate(par_idx):
                chunks[k % jobs].append((i, picked[i]))

            def loop(args: tuple[int, list]) -> list[tuple[int, bool, list[str]]]:
                wi, mine = args
                out = []
                for idx, m in mine:
                    ok, lines = run_mutation(m, projects[wi])
                    live(idx, ok)
                    out.append((idx, ok, lines))
                return out

            print(f"▸ 开跑：{len(par_idx)} 个变异 / {jobs} 个 worker 并行…")
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                parts = list(pool.map(loop, list(enumerate(chunks))))
            for idx, ok, lines in (r for part in parts for r in part):
                got[idx] = (ok, lines)

    # 按原始顺序汇总打印 —— 几路输出直接往外打会搅在一起，没法看
    bad = []
    for idx in sorted(got):
        ok, lines = got[idx]
        m = picked[idx]
        print(f"▸ [{idx + 1}/{total}] 变异：{m['name']}")
        for ln in lines:
            print(ln)
        print()
        if not ok:
            bad.append(m["name"])
    return bad


def main() -> int:
    # 输出改成**行缓冲**。python 的 stdout 一旦被重定向到文件就是块缓冲：
    # 后台跑整批时日志一片空白，看着像"卡住了"，只能靠任务状态猜 —— 这个坑
    # 在本项目里已经记过一次（DETAIL「后台跑时日志是块缓冲」），这次直接修掉。
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(line_buffering=True)
        except Exception:  # noqa: BLE001
            pass

    argv = sys.argv[1:]
    if "--list" in argv:
        for m in MUTATIONS:
            print(f"  · {m['name']}")
        return 0

    # `--jobs N` / `--jobs=N`：并发 worker 数。先摘出来，剩下的参数才是名字过滤
    jobs = 1
    for i, a in enumerate(argv):
        if a == "--jobs" and i + 1 < len(argv):
            jobs = int(argv[i + 1])
            del argv[i:i + 2]
            break
        if a.startswith("--jobs="):
            jobs = int(a.split("=", 1)[1])
            argv.pop(i)
            break
    jobs = max(1, jobs)

    if "--restore-only" in argv:
        if not BAK.exists():
            print("没有备份可还原：", BAK, file=sys.stderr)
            return 1
        print("▸ 从备份覆盖还原 src（只写不删）…")
        restore()
        # 顺带把并发留下的 worker 副本也拉回基线（不然下次 --jobs 会从脏副本起步）
        for i in range(1, 9):
            w = CACHE / f"w{i}" / PROJ.name / "src"
            if w.exists():
                restore_into(w)
                print(f"  顺带还原 worker 副本：{w.parent}")
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
    base_report = run_verify(PROJ)
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
    print("  基线全绿 ✓ · expect/forbid 的断言名全部对得上 ✓")

    # 再把**补丁锚点**也验一遍：陈旧锚点会让整批跑到一半才炸（`待替换文本出现 0 次`），
    # 而那时已经白等十分钟。锚点就是源码里的一行，改完源码最容易忘的就是它。
    stale = stale_patches(picked)
    if stale:
        print("  ✗ 有变异的补丁锚点在当前源码里对不上：", file=sys.stderr)
        for b in stale:
            print("     " + b, file=sys.stderr)
        print("     多半是源码改过、变异表没跟上 —— 对着当前源码把它改成新的那一行。",
              file=sys.stderr)
        return 1
    print("  每条变异的补丁锚点都恰好命中 1 次 ✓\n")

    try:
        bad = run_batch(picked, jobs)
    finally:
        # `run_mutation` 自己已经逐条还原过了；这一层是兜底：万一 `run_batch`
        # 在循环之外抛了（拿不到副本、并发前提自证失败……），真工程那份也得干净。
        restore()

    print("▸ 还原后复跑基线，确认没留脏 …")
    final_fails = failed_checks(run_verify(PROJ))
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
