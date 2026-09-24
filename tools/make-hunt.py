#!/usr/bin/env python3
# 生成 dist/hunt.html —— 针对「与掌灯人交互后判定为死亡」的定向排查探针。
import pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
dist = root / 'dist'
src = (dist / 'index.html').read_text(encoding='utf-8')

HUNT = r'''
    <pre id="report" style="position:fixed;left:0;top:0;z-index:99999;background:#000;color:#0f0;font:11px monospace;padding:6px;margin:0">PENDING</pre>
    <script>
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push('err:' + e.message));
    (function () { const oe = console.error; console.error = function () { window.__errs.push('console:' + Array.prototype.join.call(arguments, ' ')); oe.apply(console, arguments); }; })();
    </script>
    <script type="module">
    const g = window.__lightknight;
    const out = { cases: [], errors: [] };
    const DT = 1 / 60;
    const pump = n => { for (let i = 0; i < n; i++) { try { g.update(DT); } catch (e) { out.errors.push('update: ' + e.message); } } };
    const key = c => window.dispatchEvent(new KeyboardEvent('keydown', { code: c }));
    const snap = () => { const w = g.world; return {
      mode: g.mode, menu: g.menuKind,
      hp: w ? +w.player.hp.toFixed(1) : null, dead: w ? !!w.player.dead : null,
      enemies: w ? w.enemies.filter(e => !e.dead).length : -1,
      deaths: g.prog.deaths, lifeR: w ? Math.round(w.lightRadius) : null,
    }; };

    /* 给 playerDie / hurtPlayer 装钩子，记录调用栈与来源 */
    let deathStacks = [], hurtLog = [];
    function instrument() {
      if (!g.world) return;
      const proto = Object.getPrototypeOf(g.world);
      if (!proto.__patched) {
        const opd = proto.playerDie;
        proto.playerDie = function () {
          deathStacks.push(new Error('playerDie').stack);
          if (deathStacks.length <= 3) out['deathStack' + deathStacks.length] = deathStacks[deathStacks.length - 1];
          return opd.call(this);
        };
        const ohp = proto.hurtPlayer;
        proto.hurtPlayer = function (dmg, dir) {
          const before = this.player.hp;
          const r = ohp.call(this, dmg, dir);
          if (this.player.hp < before && hurtLog.length < 12) {
            hurtLog.push({ dmg: +Number(dmg).toFixed(2), before: +before.toFixed(1), after: +this.player.hp.toFixed(1), mode: g.mode });
          }
          return r;
        };
        proto.__patched = true;
      }
    }

    const origStart = g.startLevel.bind(g);
    g.startLevel = function (i, w2) { origStart(i, w2); instrument(); };

    /* ---- 用例 1：商店开启时，世界是否真的冻结？（敌人贴脸、长时间停留）---- */
    g.devSpawnAll = true;
    g.startLevel(0, false); pump(200);            // 让敌人聚过来
    const m = g.world.merchantProp;
    const before1 = snap();
    if (m) { g.world.player.x = m.x + 10; g.world.player.y = m.y; }
    pump(4); key('KeyE'); pump(2);
    const atOpen = snap();
    // 把敌人硬拉到玩家身边，确认暂停期间不会掉血
    for (const e of g.world.enemies) { if (!e.dead) { e.x = g.world.player.x + 30; e.y = g.world.player.y; } }
    pump(900);                                    // 商店里待 15 秒
    const after1 = snap();
    out.cases.push({ name: '1-商店开启时世界是否冻结', before: before1, atOpen, after900帧: after1,
      冻结: after1.hp === atOpen.hp && after1.deaths === atOpen.deaths });

    /* ---- 用例 2：关闭商店后继续打，记录死亡来源 ---- */
    g.handleAction('back'); pump(30);
    const afterBack = snap();
    pump(600);
    const after2 = snap();
    out.cases.push({ name: '2-关闭商店后30帧/600帧', afterBack, after600帧: after2 });

    /* ---- 用例 3：先受伤濒死，再打开商店，看死亡界面会不会丢 ---- */
    g.devSpawnAll = false;
    g.startLevel(0, false); pump(90);
    g.world.player.hp = 5;
    const m3 = g.world.merchantProp;
    if (m3) { g.world.player.x = m3.x + 10; g.world.player.y = m3.y; }
    pump(4); key('KeyE'); pump(2);
    g.world.hurtPlayer(999, 0);                   // 在商店里被判定死亡
    pump(4);
    const inShopDeath = snap();
    pump(200);                                    // 等 deathDelay(1.9s) 走完
    const afterDelay = snap();
    out.cases.push({ name: '3-商店中死亡→等1.9秒', 刚死: inShopDeath, 等200帧后: afterDelay,
      死亡界面是否出现: afterDelay.menu === 'death' });

    /* ---- 用例 4：正常死亡（对照组）---- */
    g.startLevel(0, false); pump(90);
    g.world.hurtPlayer(9999, 0); pump(150);
    out.cases.push({ name: '4-正常死亡对照', 结果: snap() });

    /* ---- 用例 5：关卡三终点（灯河渡口）能否通关 ---- */
    g.devSpawnAll = false;
    g.startLevel(2, false); pump(90);
    g.world.cleared = true;                       // 假设已清关
    const gp = g.world.goalProp;
    out.goalKind = gp ? gp.kind : null;
    if (gp) { g.world.player.x = gp.x; g.world.player.y = gp.y + 20; }
    pump(6); key('KeyE'); pump(6);
    const events5 = g.world.drainEvents().map(e => e.type);
    out.cases.push({ name: '5-关卡三终点按E', goalKind: out.goalKind, 产生事件: events5, 之后状态: snap(),
      能否抵达终章: events5.includes('victory') });
    // 也试灯塔菜单路径
    g.startLevel(2, false); pump(90); g.world.cleared = true;
    g.handleAction('victory'); pump(120);
    out.cases.push({ name: '5b-victory动作', 状态: snap(), overlay: (document.getElementById('overlay').innerHTML || '').length });

    out.deathStacks = deathStacks.length;
    out.hurtLog = hurtLog;
    out.errors = out.errors.concat(window.__errs || []);
    document.getElementById('report').textContent = 'LKREPORT' + JSON.stringify(out) + 'ENDLKREPORT';
    </script>
'''
o = src.replace('</body>', HUNT + '\n  </body>')
if o == src:
    print('ERROR: no </body>', file=sys.stderr); sys.exit(1)
(dist / 'hunt.html').write_text(o, encoding='utf-8')
print('written', dist / 'hunt.html', len(o), 'bytes')
