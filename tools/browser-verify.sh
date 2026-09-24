#!/usr/bin/env bash
# ============================================================
# browser-verify.sh —— 在真实（无头）浏览器中验证渲染层
#
# 为什么需要它：tools/sim.ts 只验证游戏逻辑（数值/状态机），
# 完全不经过 Canvas 绘制代码。渲染层的崩溃（语法错误、API 用错、
# 变 undefined）只有真正跑一遍绘制才会暴露。
#
# 环境注意（Arch / 容器中常见）：
#   · /tmp 可能是 10MB 的 tmpfs —— Chrome 的 profile 写不下就会
#     SIGTRAP/SIGSEGV 崩溃。故 profile 与截图一律放到 $HOME/.cache。
#   · --virtual-time-budget 在本机会让 Chrome 崩溃，不要使用。
#   · 因此验证页内部采用**同步推进**游戏循环（不依赖 rAF/定时器），
#     这样 --dump-dom 在页面加载完成时就能拿到结果。
#
# 用法：
#   bash tools/browser-verify.sh            # 验证 + 截图
#   bash tools/browser-verify.sh --no-shot  # 只验证
# ============================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT="${LK_PORT:-5199}"
CACHE="$HOME/.cache/lk-verify"
PROF="$HOME/.cache/lk-chrome"
mkdir -p "$CACHE" "$PROF" screenshots

# 本地回环不要走代理（否则 curl/chrome 会 502）
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
export TMPDIR="$CACHE/tmp"; mkdir -p "$TMPDIR"

CHROME=""
for c in google-chrome-stable google-chrome chromium chromium-browser; do
  command -v "$c" >/dev/null 2>&1 && { CHROME="$c"; break; }
done
if [ -z "$CHROME" ]; then
  echo "✗ 未找到 Chrome/Chromium，跳过浏览器验证。" >&2
  echo "  Arch 可安装：sudo pacman -S chromium" >&2
  exit 127
fi

echo "▸ 构建…"
npm run build >/dev/null || { echo "✗ 构建失败" >&2; exit 1; }

echo "▸ 生成验证页…"
python3 tools/make-verify.py
python3 tools/make-regress.py

echo "▸ 启动静态服务器 :$PORT …"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory dist >"$CACHE/http.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 2

CHROME_FLAGS=(
  --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage
  --disable-crash-reporter --disable-breakpad --hide-scrollbars
  --user-data-dir="$PROF"
)

echo "▸ 浏览器渲染自检…"
rm -rf "$PROF"
timeout 180 "$CHROME" "${CHROME_FLAGS[@]}" --window-size=1280,800 \
  --dump-dom "http://127.0.0.1:$PORT/verify.html" > "$CACHE/dom.html" 2>"$CACHE/dom.log" || true

if ! grep -q LKREPORT "$CACHE/dom.html" 2>/dev/null; then
  echo "✗ 未取得自检报告。请查看 $CACHE/dom.log" >&2
  exit 1
fi

python3 - "$CACHE/dom.html" <<'PY'
import json, pathlib, re, sys
h = pathlib.Path(sys.argv[1]).read_text(errors='replace')
for a, b in (('&quot;','"'), ('&amp;','&'), ('&lt;','<'), ('&gt;','>'), ('&#39;',"'")):
    h = h.replace(a, b)
d = json.loads(re.search(r'LKREPORT(.*?)ENDLKREPORT', h, re.S).group(1))
print('\n  浏览器渲染自检')
print('  ' + '=' * 52)
for k, v in d.get('checks', {}).items():
    print(('  ✅ ' if v else '  ❌ ') + k)
print('  ' + '=' * 52)
print('  全部通过 :', d.get('checksAllPass'))
print('  JS 报错数:', len(d.get('errors') or []))
for i in range(3):
    dg = d.get('diag%d' % i) or {}
    if dg and not dg.get('err'):
        print(f"  关卡{i} 光照: 玩家处 {dg['atPlayer']:<7} 四角 "
              f"{dg['farTL']}/{dg['farTR']}/{dg['farBL']}/{dg['farBR']}  光源数 {dg['lightCount']}")
errs = d.get('errors') or []
for e in errs[:10]:
    print('   ! ' + str(e)[:180])
sys.exit(0 if d.get('checksAllPass') else 1)
PY
RC=$?

echo
echo "▸ 交互流程回归测试…"
rm -rf "$PROF"
timeout 300 "$CHROME" "${CHROME_FLAGS[@]}" --window-size=1280,800 \
  --dump-dom "http://127.0.0.1:$PORT/regress.html" > "$CACHE/regress.html" 2>"$CACHE/regress.log" || true

if ! grep -q LKREPORT "$CACHE/regress.html" 2>/dev/null; then
  echo "✗ 未取得回归报告。请查看 $CACHE/regress.log" >&2
  RC=1
else
python3 - "$CACHE/regress.html" <<'PY' || RC=1
import json, pathlib, re, sys
h = pathlib.Path(sys.argv[1]).read_text(errors='replace')
for a, b in (('&quot;','"'), ('&amp;','&'), ('&lt;','<'), ('&gt;','>'), ('&#39;',"'")):
    h = h.replace(a, b)
d = json.loads(re.search(r'LKREPORT(.*?)ENDLKREPORT', h, re.S).group(1))
bad = 0
for c in d.get('cases', []):
    ok = c.get('pass')
    if not ok:
        bad += 1
    print(('  ✅ ' if ok else '  ❌ ') + c['name'] + ('' if ok else '   ← ' + str(c.get('detail', ''))[:110]))
errs = d.get('errors') or []
print('  ---- 通过 %d / %d　JS 报错 %d' % (len(d.get('cases', [])) - bad, len(d.get('cases', [])), len(errs)))
for e in errs[:8]:
    print('   ! ' + str(e)[:180])
sys.exit(0 if (d.get('pass') and bad == 0) else 1)
PY
fi

if [ "${1:-}" != "--no-shot" ]; then
  echo
  echo "▸ 抓取截图…"
  shot() {
    rm -rf "$PROF"
    timeout 120 "$CHROME" "${CHROME_FLAGS[@]}" --window-size=1280,800 \
      --screenshot="$ROOT/screenshots/$1.png" "http://127.0.0.1:$PORT/shot.html?$2" \
      >/dev/null 2>&1
    if [ -f "$ROOT/screenshots/$1.png" ]; then
      echo "  ✓ screenshots/$1.png"
    else
      echo "  ✗ screenshots/$1.png"
    fi
  }
  shot 01-level1-courtyard "lv=0&spawn=1&frames=260&nodlg=1"
  shot 02-level2-darkheart  "lv=1&spawn=1&frames=210"
  shot 03-level3-lightriver "lv=2&spawn=1&frames=260&nodlg=1"
  shot 04-lighthouse-save   "lv=1&kind=menu&menu=lighthouse"
  shot 05-lanternkeeper-shop "lv=0&kind=menu&menu=shop"
fi

echo
[ $RC -eq 0 ] && echo "✓ 浏览器渲染验证通过" || echo "✗ 浏览器渲染验证未通过"
exit $RC
