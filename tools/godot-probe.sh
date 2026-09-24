#!/usr/bin/env bash
# LightKnight 光照最小验证 —— 一键复现
#
# 在真实 Godot 引擎里跑 godot-probe 工程：固定 1280x720 离屏渲染，
# 由游戏自己采样像素、存 PNG、写 report.json，最后在这里汇总结论。
#
# 用法：  tools/godot-probe.sh
# 依赖：  godot 4.4+（标准版即可，无需 mono/C#）；需要可用的显示环境（X11 或 XWayland）

set -uo pipefail

GODOT_BIN="${GODOT_BIN:-/usr/bin/godot}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT/godot-probe"
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

# 首次运行需要导入，否则 .godot/ 不存在会报错
if [ ! -d "$PROJ/.godot" ]; then
  echo "▸ 首次导入…"
  "$GODOT_BIN" --headless --path "$PROJ" --import >/dev/null 2>&1
fi

echo "▸ 运行探针（真实渲染）…"
rm -f "$SHOTS"/*.png
LOG="$TMPDIR/godot-probe.log"
timeout 180 "$GODOT_BIN" --path "$PROJ" --rendering-driver opengl3 >"$LOG" 2>&1
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

print(f"  渲染器      {d['renderer']}")
print(f"  Godot       {d['godot']}")
print()
print(f"  墙后亮度    开阴影 {v['behind_on']}  /  关阴影 {v['behind_off']}"
      f"   → 降 {v['behind_drop_pct']}%")
print()

checks = [
    ("光被墙遮挡（核心）",            v["occlusion_works"]),
    ("阴影外仍是暗的（不是光斑变小）",  v["far_corner_dark"]),
    ("高亮度下阴影依旧成立",          v["shadow_holds_at_high_energy"]),
    ("距离衰减成立",                  v["falloff_works"]),
    ("亮度可被运行时调节",            v["energy_modulates"]),
    ("墙体自遮挡（遮挡体与墙重合）",    v["wall_self_shadowed"]),
    ("内缩 10px：受光深度 = 10px",    v["inset10_lights_d2_d6_only"]),
    ("内缩 24px：受光深度 = 24px",    v["inset24_lights_d20_not_d37"]),
    ("内缩遮挡体不漏光",              v["inset_keeps_behind_dark"]),
]
for name, ok in checks:
    print(f"  {'✅' if ok else '❌'} {name}")

print()
print(f"  混合模式均亮：ADD {v['add_mean_lum']}  /  MIX {v['mix_mean_lum']}")
if d.get("errors"):
    print("  errors:", d["errors"])

# 数值型断言的判定已经写在 probe.gd 里；这里只要有一条不成立就以非零退出
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
RC=$?

echo
echo "▸ 截图：$SHOTS"
ls -1 "$SHOTS"/*.png 2>/dev/null | sed 's|^|    |'
exit $RC
