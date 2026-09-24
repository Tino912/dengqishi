#!/usr/bin/env python3
# 生成 dist/verify.html —— 在真实浏览器里执行真实构建产物，并自采样 Canvas 像素。
#
# 为什么这样做：本环境 chrome 的 --screenshot / --virtual-time-budget 会被沙箱
# 阻断（SIGTRAP/SIGSEGV），但 --dump-dom 可用。于是把验证写成**完全同步**的：
# 在页面加载期间直接手动推进游戏循环（不依赖 rAF / setTimeout），
# 采样 canvas 像素与 DOM/HUD 状态，把结果写进 <pre id="report">，
# 再由 chrome --dump-dom 输出。
import pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
dist = root / 'dist'
src = (dist / 'index.html').read_text(encoding='utf-8')

HARNESS = r'''
    <pre id="report" style="position:fixed;left:0;top:0;z-index:99999;background:#000;color:#0f0;font:11px monospace;padding:6px;margin:0">PENDING</pre>
    <script>
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push('err:' + e.message));
    window.addEventListener('unhandledrejection', e => window.__errs.push('rej:' + String(e.reason)));
    (function () {
      const oe = console.error;
      console.error = function () { window.__errs.push('console:' + Array.prototype.join.call(arguments, ' ')); oe.apply(console, arguments); };
    })();
    </script>
    <script type="module">
    const errs = [];
    const rep = document.getElementById('report');

    /* ---------- 像素采样 ---------- */
    function sample() {
      const c = document.getElementById('game');
      if (!c || !c.width) return { err: 'canvas 无尺寸' };
      const ctx = c.getContext('2d');
      const w = c.width, h = c.height;
      let d;
      try { d = ctx.getImageData(0, 0, w, h).data; }
      catch (e) { return { err: 'getImageData 失败: ' + e.message }; }

      let opaque = 0, lum = 0, warm = 0, bright = 0, minL = 999, maxL = -1;
      const buckets = new Set();
      for (let i = 0; i < d.length; i += 4) {
        if (d[i + 3] > 8) {
          opaque++;
          const r = d[i], g = d[i + 1], b = d[i + 2];
          const l = r * 0.299 + g * 0.587 + b * 0.114;
          lum += l; if (l < minL) minL = l; if (l > maxL) maxL = l;
          if (l > 90) bright++;
          if (r > g + 12 && r > b + 24) warm++;
          buckets.add(((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
        }
      }
      // 分区亮度：中心（玩家灯下）vs 四角（应更暗）
      const lumOf = (x0, y0, x1, y1) => {
        let s = 0, n = 0;
        for (let y = y0; y < y1; y += 2) for (let x = x0; x < x1; x += 2) {
          const i = (y * w + x) * 4;
          s += d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114; n++;
        }
        return +(s / Math.max(1, n)).toFixed(1);
      };
      const cx = w >> 1, cy = h >> 1, bw = w >> 3, bh = h >> 3;
      return {
        size: w + 'x' + h,
        opaquePct: +(100 * opaque / (w * h)).toFixed(2),
        meanLum: +(lum / Math.max(1, opaque)).toFixed(1),
        minLum: minL === 999 ? -1 : +minL.toFixed(1),
        maxLum: +maxL.toFixed(1),
        brightPct: +(100 * bright / Math.max(1, opaque)).toFixed(2),
        warmPct: +(100 * warm / Math.max(1, opaque)).toFixed(2),
        colors: buckets.size,
        lumCenter: lumOf(cx - bw, cy - bh, cx + bw, cy + bh),
        lumTL: lumOf(0, 0, bw * 2, bh * 2),
        lumBR: lumOf(w - bw * 2, h - bh * 2, w, h),
      };
    }

    /* ---------- 光照诊断 ---------- */
    function diag() {
      const r = g.renderer, w = g.world;
      if (!w) return { err: 'no world' };
      const c = document.getElementById('game');
      const ctx = c.getContext('2d');
      const ww = c.width, hh = c.height;
      const d = ctx.getImageData(0, 0, ww, hh).data;
      const block = (cx, cy, n) => {
        let s = 0, k = 0;
        for (let y = Math.max(0, cy - n); y < Math.min(hh, cy + n); y++)
          for (let x = Math.max(0, cx - n); x < Math.min(ww, cx + n); x++) {
            const i = (y * ww + x) * 4;
            s += d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114; k++;
          }
        return +(s / Math.max(1, k)).toFixed(1);
      };
      const SXf = r.SX.bind(r), SYf = r.SY.bind(r);
      const lights = (r.lights || []).map(l => ({
        r: Math.round(l.r), p: +l.power.toFixed(2),
        sx: Math.round(SXf(l.x)), sy: Math.round(SYf(l.y, 0)),
      }));
      const psx = Math.round(SXf(w.player.x)), psy = Math.round(SYf(w.player.y, 0));
      return {
        ambient: +w.ambient.toFixed(3), lightCount: lights.length,
        lights: lights.slice(0, 4),
        playerScreen: [psx, psy], canvasMid: [ww >> 1, hh >> 1],
        atPlayer: block(psx, psy, 14),
        atCenter: block(ww >> 1, hh >> 1, 14),
        centerWide: block(ww >> 1, hh >> 1, 40),
        farTL: block(40, 40, 14), farTR: block(ww - 40, 40, 14),
        farBL: block(40, hh - 40, 14), farBR: block(ww - 40, hh - 40, 14),
      };
    }

    /* ---------- DOM / 世界状态 ---------- */
    function hud() {
      const g = window.__lightknight, w = g && g.world;
      const T = id => { const e = document.getElementById(id); return e ? (e.textContent || '').trim().slice(0, 30) : null; };
      return {
        mode: g && g.mode, menu: g && g.menuKind,
        level: w ? (w.level.name + ' #' + w.level.index) : null,
        enemies: w ? w.enemies.filter(e => !e.dead).length : -1,
        drops: w ? (w.drops || []).length : -1,
        effects: w ? (w.effects || []).length : -1,
        hp: w ? Math.round(w.player.hp) + '/' + Math.round(w.player.maxHp) : null,
        combo: w ? (w.player.combo | 0) : null,
        lightR: w ? Math.round(w.lightRadius) : null,
        brightness01: w ? +(w.brightness01 || 0).toFixed(2) : null,
        weapon: w && w.player.weapon ? w.player.weapon.name : null,
        hudHpText: T('hpText'), hudCoins: T('coins'), hudObj: T('objective'), hudWicks: T('wicks'),
        hudVisible: !document.getElementById('hud').classList.contains('hidden'),
        skillSlots: document.querySelectorAll('#skills > *').length,
        overlayLen: (document.getElementById('overlay').innerHTML || '').length,
        promptShown: !document.getElementById('prompt').classList.contains('hidden'),
      };
    }

    /* ---------- 同步推进游戏循环 ---------- */
    const g = window.__lightknight;
    const DT = 1 / 60;
    function pump(frames) {
      for (let i = 0; i < frames; i++) {
        try { g.update(DT); } catch (e) { errs.push('update: ' + e.message); if (errs.length > 6) break; }
      }
    }
    function key(code) { window.dispatchEvent(new KeyboardEvent('keydown', { code })); }
    function keyUp(code) { window.dispatchEvent(new KeyboardEvent('keyup', { code })); }

    const out = { steps: [], menus: [], errors: [], checks: {} };

    try {
      out.booted = !!g;
      if (!g) { errs.push('window.__lightknight 不存在（bundle 未执行）'); throw new Error('no game'); }

      /* 1. 标题画面 */
      pump(30);
      out.steps.push({ name: 'title', hud: hud(), px: sample() });

      /* 2. 逐关：普通 + 全刷（压测渲染） */
      for (let lv = 0; lv < 3; lv++) {
        g.devSpawnAll = false;
        g.startLevel(lv, false);
        pump(90);                                  // 淡入 0.62s + 世界装载
        // 让玩家动起来并攻击，制造连击/特效
        key('KeyW'); pump(20); keyUp('KeyW');
        key('Space'); pump(6);
        pump(150);
        out.steps.push({ name: 'L' + lv + '-normal', hud: hud(), px: sample() });
        out['diag' + lv] = diag();

        // 全刷压测：所有波次 + Boss 同屏
        g.devSpawnAll = true;
        g.startLevel(lv, false);
        pump(120);
        key('Space'); pump(4);
        pump(240);
        out.steps.push({ name: 'L' + lv + '-spawnAll', hud: hud(), px: sample() });
      }

      /* 3. 菜单渲染 */
      for (const act of ['help', 'about', 'shop', 'upgrade', 'pause', 'lighthouse']) {
        try {
          if (typeof g.showMenu === 'function') g.showMenu(act);
          else g.handleAction(act);
          pump(12);
          out.menus.push({ act, menu: g.menuKind, overlayLen: (document.getElementById('overlay').innerHTML || '').length, px: sample() });
        } catch (e) { errs.push('menu ' + act + ': ' + e.message); }
      }

      /* 4. 死亡 → 复活链路 */
      try {
        g.closeMenu ? g.closeMenu() : g.handleAction('resume');
        g.startLevel(0, false); pump(90);
        if (g.world) { g.world.player.hp = 0.01; g.world.hurtPlayer(999, 0); }
        pump(150);
        out.deathMode = g.mode; out.deathMenu = g.menuKind;
        g.handleAction('respawn'); pump(80);
        out.respawn = { mode: g.mode, hp: g.world ? Math.round(g.world.player.hp) : null };
      } catch (e) { errs.push('death/respawn: ' + e.message); }

      /* 5. 汇总判定 */
      const ok = s => s.px && !s.px.err;
      const worlds = out.steps.filter(s => s.hud.level);
      out.checks = {
        渲染有输出: out.steps.every(s => ok(s) && s.px.opaquePct > 50),
        有丰富色彩: out.steps.every(s => s.px.colors >= 24),
        三关均成像: worlds.length >= 6,
        三关有敌人: ['L0', 'L1', 'L2'].every(p => {
          const s = out.steps.find(x => x.name === p + '-spawnAll');
          return s && s.hud.enemies > 0;
        }),
        黑暗光照系统: [0, 1, 2].every(i => {
          const dg = out['diag' + i];
          if (!dg || dg.err) return false;
          const corners = [dg.farTL, dg.farTR, dg.farBL, dg.farBR];
          const darkest = Math.min(...corners);
          // 玩家身边必须显著亮于任何角落（相机受关卡边界钳制，玩家不一定在画布正中）
          return dg.atPlayer > Math.max(...corners) * 1.8 && dg.atPlayer > darkest * 4;
        }),
        有暖色灯光: out.steps.filter(s => s.hud.level).some(s => s.px.warmPct > 0.5),
        HUD已挂载: out.steps.some(s => s.hud.hudHpText && s.hud.hudCoins !== null),
        技能槽渲染: out.steps.some(s => s.hud.skillSlots >= 1),
        菜单可渲染: out.menus.every(m => m.overlayLen > 200),
      };
      out.checksAllPass = Object.values(out.checks).every(Boolean);
    } catch (e) {
      errs.push('fatal: ' + e.message);
    }

    out.errors = errs.concat(window.__errs || []);
    rep.textContent = 'LKREPORT' + JSON.stringify(out) + 'ENDLKREPORT';
    </script>
'''

out = src.replace('</body>', HARNESS + '\n  </body>')
if out == src:
    print('ERROR: 未找到 </body>', file=sys.stderr); sys.exit(1)
(dist / 'verify.html').write_text(out, encoding='utf-8')
print('written', dist / 'verify.html', len(out), 'bytes')

# ---------------------------------------------------------------
# shot.html —— 同步推进到指定关卡的战况，然后停在那一帧，供 --screenshot 抓图。
# 用法: shot.html?lv=0&spawn=1&frames=200&mode=play
# ---------------------------------------------------------------
SHOT = r'''
    <script type="module">
    const g = window.__lightknight;
    const q = new URLSearchParams(location.search);
    const lv = parseInt(q.get('lv') || '0', 10);
    const spawn = q.get('spawn') === '1';
    const frames = parseInt(q.get('frames') || '200', 10);
    const kind = q.get('kind') || 'play';
    const nodlg = q.get('nodlg') === '1';
    const DT = 1 / 60;
    const key = c => window.dispatchEvent(new KeyboardEvent('keydown', { code: c }));
    // 边推进边按空格，把 Boss 出场对白翻完，留下干净的战斗画面
    const pump = n => {
      for (let i = 0; i < n; i++) {
        if (nodlg && i % 12 === 0) key('Space');
        try { g.update(DT); } catch (e) {}
      }
    };

    if (kind === 'menu') {
      g.startLevel(lv, false); pump(90);
      try { g.showMenu(q.get('menu') || 'lighthouse'); } catch (e) {}
      pump(20);
    } else if (kind === 'dialogue') {
      g.startLevel(lv, true); pump(120);
    } else if (kind === 'shop') {
      // 走到掌灯人身边并打开商店
      g.startLevel(lv, false); pump(90);
      const m = g.world.merchantProp;
      if (m) { g.world.player.x = m.x + 20; g.world.player.y = m.y + 10; }
      pump(6); key('KeyE'); pump(30);
    } else if (kind === 'shopback') {      // 打开商店后点「返回」，看会落到哪里
      g.startLevel(lv, false); pump(90);
      const m2 = g.world.merchantProp;
      if (m2) { g.world.player.x = m2.x + 20; g.world.player.y = m2.y + 10; }
      pump(6); key('KeyE'); pump(24);
      g.handleAction('back'); pump(60);
    } else if (kind === 'totitle') {
      // 战斗中「回到标题」，用于确认黑幕已撤掉
      g.startLevel(lv, false); pump(90);
      g.handleAction('totitle'); pump(200);
    } else if (kind === 'death') {
      // 真实死亡流程，作为对照
      g.startLevel(lv, false); pump(90);
      g.world.hurtPlayer(9999, 0); pump(150);
    } else {
      g.devSpawnAll = spawn;
      g.startLevel(lv, false);
      pump(90);
      // 打一套：移动 + 攻击，制造连击、刀光与特效
      key('KeyD'); pump(26); window.dispatchEvent(new KeyboardEvent('keyup', { code: 'KeyD' }));
      key('Space'); pump(8);
      key('KeyW'); pump(18); window.dispatchEvent(new KeyboardEvent('keyup', { code: 'KeyW' }));
      key('Space'); pump(6);
      pump(Math.max(0, frames - 148));
    }
    // 隐藏自检标记，避免出现在截图里
    const r = document.getElementById('report'); if (r) r.style.display = 'none';
    </script>
'''
sout = src.replace('</body>', SHOT + '\n  </body>')
(dist / 'shot.html').write_text(sout, encoding='utf-8')
print('written', dist / 'shot.html', len(sout), 'bytes')

# ---------------------------------------------------------------
# repro.html —— 缺陷复现探针：跑固定场景并输出逐步状态轨迹。
# 用 --dump-dom 取回（页面内同步推进，不依赖定时器）。
# ---------------------------------------------------------------
REPRO = r'''
    <pre id="report" style="position:fixed;left:0;top:0;z-index:99999;background:#000;color:#0f0;font:11px monospace;padding:6px;margin:0">PENDING</pre>
    <script>
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push('err:' + e.message));
    (function () { const oe = console.error; console.error = function () { window.__errs.push('console:' + Array.prototype.join.call(arguments, ' ')); oe.apply(console, arguments); }; })();
    </script>
    <script type="module">
    const g = window.__lightknight;
    const out = { trace: [], errors: [] };
    const DT = 1 / 60;
    const pump = n => { for (let i = 0; i < n; i++) { try { g.update(DT); } catch (e) { out.errors.push('update: ' + e.message); } } };
    const key = c => window.dispatchEvent(new KeyboardEvent('keydown', { code: c }));
    const fadeEl = () => document.getElementById('fade');

    function snap(tag) {
      const w = g.world;
      const fe = fadeEl();
      out.trace.push({
        tag,
        mode: g.mode, menu: g.menuKind, stack: (g.menuStack || []).slice(),
        hasWorld: !!w,
        worldLevel: w ? w.level.index : null,
        hp: w ? Math.round(w.player.hp) + '/' + Math.round(w.player.maxHp) : null,
        playerDead: w ? !!w.player.dead : null,
        deaths: g.prog ? g.prog.deaths : null,
        fadeClass: fe ? fe.className : null,
        fadeOpacity: fe ? getComputedStyle(fe).opacity : null,
        overlayLen: (document.getElementById('overlay').innerHTML || '').length,
        hudVisible: !document.getElementById('hud').classList.contains('hidden'),
        prompt: w ? w.prompt : null,
      });
    }

    /* ---- 场景 A：与掌灯人交互 ---- */
    g.devSpawnAll = false;
    g.startLevel(0, false);
    pump(90);
    const m = g.world.merchantProp;
    out.merchantPos = m ? [m.x, m.y] : null;
    // 站到掌灯人身边
    if (m) { g.world.player.x = m.x + 20; g.world.player.y = m.y + 10; }
    pump(4);
    snap('A1-站到掌灯人旁');
    key('KeyE'); pump(2);
    snap('A2-按E交互');
    pump(30);
    snap('A3-商店停留');
    // 点「返回」
    g.handleAction('back'); pump(30);
    snap('A4-商店返回');

    /* ---- 场景 B：返回标题 ---- */
    g.startLevel(0, false); pump(90);
    snap('B1-进入关卡');
    g.handleAction('totitle'); pump(160);
    snap('B2-返回标题后');
    pump(120);
    snap('B3-标题再等2秒');
    // 标题画面下画布是否有内容（黑屏检测）
    const c = document.getElementById('game');
    const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    let lum = 0, n = 0;
    for (let i = 0; i < d.length; i += 4) { lum += d[i] * 0.299 + d[i + 1] * 0.587 + d[i + 2] * 0.114; n++; }
    out.titleCanvasMeanLum = +(lum / n).toFixed(2);

    /* ---- 场景 C：暂停菜单里的「回到标题」（另一条入口）---- */
    g.startLevel(0, false); pump(90);
    g.handleAction('totitle'); pump(200);
    snap('C1-再回标题');
    const fe = fadeEl();
    out.fadeRect = fe ? JSON.stringify(fe.getBoundingClientRect()) : null;

    out.errors = out.errors.concat(window.__errs || []);
    document.getElementById('report').textContent = 'LKREPORT' + JSON.stringify(out) + 'ENDLKREPORT';
    </script>
'''
rout = src.replace('</body>', REPRO + '\n  </body>')
(dist / 'repro.html').write_text(rout, encoding='utf-8')
print('written', dist / 'repro.html', len(rout), 'bytes')
