#!/usr/bin/env bash
# LightKnight 光照验证 · 第二探针 —— 一键复现（2.5D 俯视下的遮挡体摆法）
#
# 在真实 Godot 引擎里跑 godot-probe 工程里的 probe25d 场景：固定 1280x720 离屏渲染，
# 22 个用例（4 种墙型 × 4 个光照方向 × 4 种遮挡体摆法 + 灯形状对照），
# 由场景自己采样像素、存 PNG、写 report.json，最后在这里汇总判定。
#
# 用法：  tools/godot-probe25d.sh
# 依赖：  godot 4.4+（标准版即可，无需 mono/C#）；需要可用的显示环境（X11 或 XWayland）
#
# 与第一探针（tools/godot-probe.sh）的区别：第一探针测「2D 光会不会被墙挡住」，
# 本探针测「2.5D 俯视下遮挡体该贴在哪一块」。两者互不影响，可各自单独跑。

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-/usr/bin/godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/godot-probe"
SHOTS="$PROJ/shots25d"

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

if [ ! -d "$PROJ/.godot" ]; then
  echo "▸ 首次导入…"
  "$GODOT_BIN" --headless --path "$PROJ" --import >/dev/null 2>&1
fi

echo "▸ 运行 2.5D 遮挡体探针（真实渲染，22 个用例）…"
rm -rf "$SHOTS"
LOG="$TMPDIR/godot-probe25d.log"
# 注意：必须把场景作为位置参数传给 Godot，否则会跑 main.tscn（第一探针）
timeout 300 "$GODOT_BIN" --path "$PROJ" res://probe25d.tscn --rendering-driver opengl3 >"$LOG" 2>&1
RC=$?

if grep -qiE "SCRIPT ERROR|Parse Error|Invalid call|Nonexistent function" "$LOG"; then
  echo "▸ 脚本报错：" >&2
  grep -iE "SCRIPT ERROR|Parse Error|Invalid call|Nonexistent function" "$LOG" | head -10 >&2
  exit 1
fi

if [ ! -f "$SHOTS/report.json" ]; then
  echo "探针未产出 report.json（rc=$RC）。日志尾部：" >&2
  tail -20 "$LOG" >&2
  exit 1
fi

echo "▸ 结论"
python3 - "$SHOTS/report.json" <<'PY'
import json, sys, pathlib

d = json.loads(pathlib.Path(sys.argv[1]).read_text())
v = d["verdict"]
g = d["geometry"]

print(f"  渲染器      {d['renderer']}")
print(f"  Godot       {d['godot']}")
print(f"  投影        屏幕 y = 世界 y × {d['ysquash']}（与 render.ts 的 YSQUASH 一致）")
print()
print("  墙型（世界坐标 → 屏幕足迹/轮廓）：")
for name, info in g.items():
    w = info["world"]
    f, s = info["foot_screen"], info["sil_screen"]
    print(f"    {name:<7} w={w['w']:<5.0f} d={w['d']:<5.0f} h={w['h']:<5.0f}"
          f"  足迹 {f[0]:.0f},{f[1]:.1f} {f[2]:.0f}×{f[3]:.1f}"
          f"  轮廓 {s[0]:.0f},{s[1]:.1f} {s[2]:.0f}×{s[3]:.1f}")
print()

def group(prefix, title):
    print(f"  {title}")
    for k in sorted(v):
        if k.startswith(prefix):
            print(f"    {'✅' if v[k] else '❌'} {k[1:]}")

group("P", "推荐摆法：贴屏幕上画出来的整体轮廓，只把底边削掉 16px")
print()
group("D", "对照摆法：缺陷已确认存在（所以不能照抄）")
print()

print("  关键数字（亮度为采样区平均，未受光地板底噪 ≈ 0.048）")
pairs = [
    ("正面光：墙前地面",            "num_正面_墙前地面"),
    ("正面光：墙后地面（推荐摆法）",  "num_正面_墙后地面_b16"),
    ("侧光：墙前地面",              "num_侧光_墙前地面"),
    ("侧光：墙后地面（贴脚印）",      "num_侧光_墙后地面_foot"),
    ("侧光：墙后地面（贴轮廓）",      "num_侧光_墙后地面_sil"),
    ("侧光：墙后地面（轮廓+削底16）", "num_侧光_墙后地面_b16"),
    ("侧光：墙后地面（轮廓均匀内缩16）","num_侧光_墙后地面_in16"),
    ("侧光：墙面顶面（贴脚印）",      "num_侧光_墙面顶面_foot"),
    ("侧光：墙面顶面（贴轮廓）",      "num_侧光_墙面顶面_b16"),
    ("背光：墙面（贴脚印）",          "num_背光_墙面_foot"),
    ("背光：墙面（贴轮廓）",          "num_背光_墙面_b16"),
    ("墙脚受光高度：不削底",          "num_侧光_墙脚受光高度_sil"),
    ("墙脚受光高度：削 8px（正面光）", "num_正面_墙脚受光高度_b8"),
    ("墙脚受光高度：削 16px（正面光）","num_正面_墙脚受光高度_b16"),
    ("墙脚受光高度：削 8px（侧光）",   "num_侧光_墙脚受光高度_b8"),
    ("墙脚受光高度：削 16px（侧光）",  "num_侧光_墙脚受光高度_b16"),
    ("底座溢光：不削底",              "num_额外_无削底时_墙侧"),
    ("底座溢光：削 8px",              "num_额外_削底带来的底座溢光_b8"),
    ("底座溢光：削 16px",             "num_额外_削底带来的底座溢光_b16"),
    ("灯形状：屏幕正圆（北/东亮度比）","num_正圆灯_地面等距北东亮度比"),
    ("灯形状：地面正圆（北/东亮度比）","num_地圆灯_地面等距北东亮度比"),
]
for label, key in pairs:
    if key in v:
        print(f"    {label:<34} {v[key]}")
print()

fails = [k for k in v if (k.startswith("P") or k.startswith("D")) and not v[k]]
if d.get("errors"):
    print("  errors:", d["errors"])
print(f"  → {'全部通过 ✅' if not fails else '未通过：' + ', '.join(fails)}")
sys.exit(0 if not fails else 1)
PY
RC=$?

echo
echo "▸ 截图：$SHOTS"
ls -1 "$SHOTS"/*.png 2>/dev/null | sed 's|^|    |'
exit $RC
