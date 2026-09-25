#!/usr/bin/env bash
# 灯骑士 · Godot 迁移切片 —— 一键复现自检
#
# 在真实 Godot 引擎里跑 godot-lightknight 工程的自检场景：固定 1280x720 离屏渲染，
# 走完整流程（标题 → 移动/碰撞 → 战斗/连击/技能/掉落 → 遮挡光照对照 →
# 8 把武器 / 19 个技能 / 特效种类 → 敌人 AI → 三波 + Boss → 死亡重生/火盆 →
# 机器人试玩 90 秒 → 第二关「无芯之暗」：三选一 / 火盆再生 / 盲女 / Boss →
# 宝箱/背包/守灯人 → 布局随机化 → 武器元素与状态效果 / 攻击发光 /
# 第三关「灯河渡口」与三图风格 / 敌人样貌），
# 全程由场景自己推进固定步长、自己采样 viewport 像素、自己给出判定，
# 最后写 shots/report.json 并在这里汇总。
#
# 用法：  tools/godot-lightknight.sh
# 依赖：  godot 4.4+（标准版即可，无需 mono/C#）；需要可用的显示环境（X11 或 XWayland）
#         —— 自检要读 SubViewport 的像素，--headless 的 dummy 渲染器读不出画面。
#
# 预期结果：324/324 断言通过，退出码 0。五个核心结论：
#   ① 光会被墙挡住：同一采样点，开阴影 0.005 ≈ 射程外的黑暗底噪（0.008），
#      关阴影 0.083（亮 17 倍）。注意这两个数字的前提是**屏幕上没有残留的全屏闪光** ——
#      flash_rect 不归 set_post_enabled 管，闪光一旦卡住会给每个采样点加一个常数，
#      把"墙后 vs 底噪"的比值压到 1 附近，看起来像"遮挡不成立"。
#   ② 八把武器在**特效种类**上真的分开了（slash/ring/burst/pillar/pull/zone/muzzle +
#      Boss 独占的 beam），不是只改伤害数字。
#   ③ 宝箱与敌人（波次 + Boss）的落点是**每局重摇**的：换局种子整套换、同局种子逐点相同、
#      撒出来的点都不在墙里、并且从出生点起链式走得通（走不通会静默卡关）。
#   ④ 武器带**随机元素**，而且状态真的生效：火在掉血、冰一步不动、雷只连一跳且不穿墙、
#      毒同时掉血与减速、光对暗影系是 100×1.85×1.30 而不是"大概 1.3 倍"。
#   ⑤ 攻击真的在发光：挥击与飞行中的弹丸各自点一盏**带遮挡**的灯，
#      同一像素「发着光 vs 收手/弹丸消失」实测 0.078 -> 0.207、0.092 -> 0.935。
# 连跑两遍 shots/report.json 逐字节相同（随机数全部走种子播种）。
#
# 断言是否有牙齿，用 tools/godot-mutate.py 验证（故意改坏实现，看该红的红没红）。

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-/usr/bin/godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/godot-lightknight"
SHOTS="$PROJ/shots"

# 本机沙箱会预设代理，本地回环会因此失败；Godot 本身不需要网络
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
# 关键：TMPDIR 必须落在真实磁盘上（本机 /tmp 只有 10MB，写满会让进程崩）
export HOME="${HOME:-/home/$(id -un)}"
export TMPDIR="$HOME/.cache/godot-tmp"
mkdir -p "$TMPDIR"

if [ ! -x "$GODOT_BIN" ] && ! command -v "$GODOT_BIN" >/dev/null 2>&1; then
  echo "找不到 Godot：$GODOT_BIN（可用 GODOT_BIN=... 覆盖）" >&2
  exit 1
fi

echo "▸ Godot: $("$GODOT_BIN" --version 2>/dev/null | head -1)"
echo "▸ 工程:  $PROJ"

if [ ! -d "$PROJ/.godot" ]; then
  echo "▸ 首次导入…"
  "$GODOT_BIN" --headless --path "$PROJ" --import >/dev/null 2>&1
fi

echo "▸ 运行自检（真实渲染，全程约 1 分钟）…"
rm -rf "$SHOTS"
LOG="$TMPDIR/godot-lightknight.log"
timeout 400 "$GODOT_BIN" --path "$PROJ" res://scenes/selfcheck.tscn \
  --rendering-driver opengl3 >"$LOG" 2>&1
RC=$?

if grep -qiE "SCRIPT ERROR|Parse Error|Invalid call|Nonexistent function" "$LOG"; then
  echo "▸ 脚本报错：" >&2
  grep -iE "SCRIPT ERROR|Parse Error|Invalid call|Nonexistent function" "$LOG" | head -10 >&2
  exit 1
fi

if [ ! -f "$SHOTS/report.json" ]; then
  echo "自检未产出 report.json（rc=$RC）。日志尾部：" >&2
  tail -20 "$LOG" >&2
  exit 1
fi

echo "▸ 结论"
python3 - "$SHOTS/report.json" <<'PY'
import json, sys, pathlib

d = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(f"  渲染器      {d['renderer']}")
print(f"  Godot       {d['godot']}")
print(f"  投影        屏幕 y = 世界 y × {d['ysquash']}（与 Web 版 render.ts 的 YSQUASH 一致）")
print(f"  断言        {d['checks_passed']}/{d['checks_total']} 通过")
print()

oc = d["cases"]["occlusion"]
on, off = oc["shadow_on"], oc["shadow_off"]
base = on["far"]      # 同一帧里"超出灯半径、完全照不到"的采样点 = 地板底噪
print("  遮挡照明对照（只切换 PointLight2D.shadow_enabled 这一个变量）")
print(f"    测试墙            世界 {oc['wall']}")
print(f"    墙前（灯与墙之间） {on['front']:.4f}")
print(f"    墙后 开阴影        {on['back']:.4f}   ← 落到射程外底噪同一水平")
print(f"    墙后 关阴影        {off['back']:.4f}   ← 光其实够得着，是被墙挡了")
print(f"    射程外（同帧基线） {base:.4f}")
print(f"    墙后降幅           {oc['back_drop_pct']:.1f}%")
print(f"    墙后/底噪          开 {on['back']/max(base,1e-4):.2f}×   关 {off['back']/max(base,1e-4):.2f}×")
print(f"    墙前/底噪          {on['front']/max(base,1e-4):.2f}×")
print()

ls = d["cases"]["light_shape"]
print(f"  灯的形状    东 {ls['east_300']:.4f} / 北 {ls['north_300']:.4f} = {ls['ratio']:.4f}")
print("              （屏幕正圆会是 ~1.65；竖压椭圆 = 地面正圆，故 ≈1）")
print()

prof = d["samples"].get("light_profile", [])
if prof:
    print("  灯的实测衰减（距灯地面距离 → 采样亮度）")
    for dd, v in prof:
        print(f"    d={dd:<5} {v:.4f}  {'#' * int(v * 60)}")
    print()

bot = d["cases"]["bot"]
print("  机器人真实试玩（90 秒游戏时间，不预设数值，只看循环通不通）")
print(f"    击杀 {bot['kills']}　最高连击 {bot['combo_peak']}　最低生命 {bot['hp_min']}"
      f"　清空波次 {bot['waves_best']}/{3}　三选一 {bot['drafts']} 次"
      f"　阵亡 {bot['deaths']}　打到 Boss {bot['boss_seen']}")
print()

wp = d["cases"].get("weapons")
if wp:
    print("  武器 / 技能 / 特效（八把武器的位置要真的分开，不是改数字凑数）")
    print(f"    {wp['count']} 把武器　{wp['skills']} 个技能　特效 {wp['effect_kinds_n']} 种")
    print(f"    {', '.join(wp['effect_kinds'])}")
    print()

l2 = d["cases"].get("level2")
if l2:
    print("  第二关「无芯之暗」")
    print(f"    {l2['name']}　{l2['w']:.0f}×{l2['h']:.0f}　墙 {l2['walls']} 面　"
          f"ambient {l2['ambient']}（第一关 0.9）　敌人倍率 {l2['enemy_scale']}")
    print(f"    火盆 {l2['braziers_lit']}/{l2['braziers_required']}"
          f"　死亡再生 {l2['respawns']} 次　盲女同行 {l2['has_girl']}　Boss {l2['boss']}")
    print()

el = d["cases"].get("elements")
if el:
    print(f"  武器元素（每局摇一次，共 {el['count']} 种：{'/'.join(el['names'])}）")
    print("    这一局的八把：" + "　".join(f"{k}={v}" for k, v in el["per_weapon"].items()))
    print(f"    48 个种子的分布：" + "　".join(f"{k}={v}" for k, v in el["counts_over_48_seeds"].items())
          + f"　（{el['seeds_with_duplicate']}/48 个种子有重复 —— 允许重复是故意的）")
    print()

al = d["cases"].get("attack_light")
if al:
    print("  攻击发光（同一像素：发着光 vs 收手 / 弹丸消失）")
    print(f"    挥击的刀锋灯   {al['swing_px_dark']:.4f} -> {al['swing_px_lit']:.4f}"
          f"　（{al['swing_px_lit'] / max(al['swing_px_dark'], 1e-4):.1f}×）")
    print(f"    飞行中的弹丸灯 {al['proj_px_dark']:.4f} -> {al['proj_px_lit']:.4f}"
          f"　（{al['proj_px_lit'] / max(al['proj_px_dark'], 1e-4):.1f}×）")
    print(f"    攻击类灯上限 {al['fx_light_max']} 盏："
          f"塞 24 颗弹丸时实际点了 {al['fx_lights_with_24_projs']} 盏")
    print()

l3 = d["cases"].get("level3")
if l3:
    print("  第三关「灯河渡口」（三图风格各异：court / quarry / river）")
    print(f"    {l3['name']}　{l3['w']:.0f}×{l3['h']:.0f}　墙 {l3['walls']} 面　"
          f"ambient {l3['ambient']}（第二关 0.955）　敌人倍率 {l3['enemy_scale']}　Boss {l3['boss']}")
    ad = [(k, v) for k, v in d["samples"].items() if k.startswith("art_diff_")]
    if ad:
        print("    三张地图在出生点周围的画面差异：" +
              "　".join(f"{k.replace('art_diff_', '').replace('_', ' vs ')}={v * 100:.1f}%" for k, v in ad)
              + f"　（对照：同一关重建两次 = {d['samples'].get('同一关重建两次的画面差异', 0) * 100:.2f}%）")
    print()

print(f"  肉鸽循环：整趟共发生三选一 {d['samples'].get('draft_taken')} 次")
print()

fails = [k for k, v in d["checks"].items() if not v]
if d.get("errors"):
    print("  失败明细：")
    for e in d["errors"]:
        print("   ", e)
print(f"  → {'全部通过 ✅' if not fails else '未通过：' + ', '.join(fails)}")
sys.exit(0 if not fails else 1)
PY
RC=$?

echo
echo "▸ 截图：$SHOTS"
ls -1 "$SHOTS"/*.png 2>/dev/null | sed 's|^|    |'
exit $RC
