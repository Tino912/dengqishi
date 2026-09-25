#!/usr/bin/env python3
"""灯骑士 · Godot 自检的变异测试（证明断言真的有牙齿）。

**为什么要这个**：断言写完第一遍就全绿，说明不了任何事 —— 可能是断言根本
没在盯着实现。唯一可靠的办法是**故意把实现改坏**，然后确认：
  · 该红的断言真的红了；
  · 没有连带误伤（别的断言不该无故变红 —— 那说明它们互相耦合，将来会误导人）。

**怎么用**
    tools/godot-mutate.py              # 跑全部变异（8 个，约 10 分钟）
    tools/godot-mutate.py 闪光          # 只跑名字里含「闪光」的
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
]


def run_verify() -> dict:
    """跑一次自检，返回 report.json（断言变红是预期内的，rc 不用管）。"""
    subprocess.run([str(VERIFY)], cwd=ROOT, capture_output=True, text=True, timeout=900)
    if not REPORT.exists():
        raise RuntimeError("自检没有产出 report.json —— 看 ~/.cache/godot-tmp/godot-lightknight.log")
    return json.loads(REPORT.read_text())


def failed_checks(rep: dict) -> list[str]:
    return sorted(k for k, v in rep["checks"].items() if not v)


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
    base_fails = failed_checks(run_verify())
    if base_fails:
        print("  ⚠️ 基线本身就有红的，先修好再变异：", base_fails, file=sys.stderr)
        return 1
    print("  基线全绿 ✓\n")

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
