#!/usr/bin/env python3
# 生成 dist/regress.html —— 交互流程回归测试。
#
# 覆盖的是 tools/sim.ts 测不到的东西：Game 类的场景状态机
# （mode / menuKind / 返回栈 / 黑幕 / 死亡结算）。
# 这些缺陷都只在"多个界面来回切"时才暴露，逻辑仿真跑不到。
#
# 每个用例带明确断言，结果由 --dump-dom 取回，失败则退出码非 0。
import pathlib, sys

root = pathlib.Path(__file__).resolve().parent.parent
dist = root / 'dist'
src = (dist / 'index.html').read_text(encoding='utf-8')

HARNESS = r'''
    <pre id="report" style="position:fixed;left:0;top:0;z-index:99999;background:#000;color:#0f0;font:11px monospace;padding:6px;margin:0">PENDING</pre>
    <script>
    window.__errs = [];
    window.addEventListener('error', e => window.__errs.push('err:' + e.message));
    (function () { const oe = console.error; console.error = function () { window.__errs.push('console:' + Array.prototype.join.call(arguments, ' ')); oe.apply(console, arguments); }; })();
    </script>
    <script type="module">
    const g = window.__lightknight;
    const DT = 1 / 60;
    const out = { cases: [], errors: [] };
    const pump = n => { for (let i = 0; i < n; i++) { try { g.update(DT); } catch (e) { out.errors.push('update: ' + e.message); } } };
    const key = c => window.dispatchEvent(new KeyboardEvent('keydown', { code: c }));
    const fadeOn = () => document.getElementById('fade').classList.contains('on');
    const w = () => g.world;
    const st = () => ({
      mode: g.mode, menu: g.menuKind,
      hp: w() ? Math.round(w().player.hp) : null,
      dead: w() ? !!w().player.dead : null,
      deaths: g.prog.deaths, fade: fadeOn(),
    });
    function check(name, cond, detail) {
      out.cases.push({ name, pass: !!cond, detail: detail || '' });
    }

    /* ============ 1. 战斗中与掌灯人交互 → 返回应回到战斗 ============ */
    g.devSpawnAll = false;
    g.startLevel(0, false); pump(90);
    const m = w().merchantProp;
    if (m) { w().player.x = m.x + 20; w().player.y = m.y + 10; }
    pump(4); key('KeyE'); pump(4);
    const openShop = st();
    check('掌灯人对话能打开商店', openShop.mode === 'menu' && openShop.menu === 'shop', JSON.stringify(openShop));
    g.handleAction('back'); pump(20);
    const afterBack = st();
    check('商店「返回」回到战斗（而不是标题菜单）',
      afterBack.mode === 'play' && afterBack.hp !== null, JSON.stringify(afterBack));
    check('返回战斗后立刻有一段无敌保护', w().player.invuln > 0.4, 'invuln=' + w().player.invuln.toFixed(2));

    /* ============ 2. 返回标题：不能残留黑幕 ============ */
    g.startLevel(0, false); pump(90);
    g.handleAction('totitle'); pump(200);
    const atTitle = st();
    check('返回标题：fade 黑幕已撤掉', atTitle.fade === false, JSON.stringify(atTitle));
    check('返回标题：world 已释放且处于标题菜单',
      atTitle.mode === 'menu' && atTitle.menu === 'title' && atTitle.hp === null, JSON.stringify(atTitle));

    /* ============ 3. 死亡期间被菜单打断 → 死亡界面不能丢 ============ */
    g.startLevel(0, false); pump(90);
    const m3 = w().merchantProp;
    if (m3) { w().player.x = m3.x + 20; w().player.y = m3.y + 10; }
    pump(4); key('KeyE'); pump(4);            // 打开商店（世界暂停）
    const deaths0 = g.prog.deaths;
    w().hurtPlayer(9999, 0);                   // 在商店里被判定死亡
    pump(200);                                 // 倒计时本应走完
    const deadInShop = st();
    check('商店中死亡：暂时留在商店（不吞掉结算）',
      deadInShop.deaths === deaths0 + 1 && deadInShop.dead === true
        && deadInShop.mode === 'menu' && deadInShop.menu === 'shop',
      JSON.stringify(deadInShop) + ' 基线deaths=' + deaths0);
    g.handleAction('back'); pump(200);          // 关掉商店回到战斗
    const afterDeath = st();
    check('关掉商店后死亡界面正常出现（不再永久卡死）',
      afterDeath.menu === 'death', JSON.stringify(afterDeath));
    g.handleAction('respawn'); pump(120);
    const afterRespawn = st();
    check('死亡后可复活回灯塔并恢复行动',
      afterRespawn.mode === 'play' && afterRespawn.dead === false && afterRespawn.hp > 0, JSON.stringify(afterRespawn));

    /* ============ 4. 倒地后不允许开暂停菜单 ============ */
    g.startLevel(0, false); pump(90);
    w().hurtPlayer(9999, 0); pump(4);
    key('Escape'); pump(200);
    const deadEsc = st();
    check('死亡结算不被暂停菜单顶掉', deadEsc.menu === 'death', JSON.stringify(deadEsc));

    /* ============ 5. 关卡三渡口可以抵达终章 ============ */
    g.startLevel(2, false); pump(90);
    w().cleared = true;
    const gp = w().goalProp;
    check('关卡三终点是渡口', gp && gp.kind === 'dock', gp ? gp.kind : 'null');
    if (gp) { w().player.x = gp.x; w().player.y = gp.y + 20; }
    pump(6); key('KeyE'); pump(200);
    const atDock = st();
    check('渡口按 E 能推进到终章',
      atDock.mode !== 'play' || atDock.menu === 'victory', JSON.stringify(atDock));

    /* ============ 6. 暂停菜单里来回切换不会让返回栈错乱 ============ */
    g.startLevel(0, false); pump(90);
    key('Escape'); pump(6);
    check('战斗中可以开暂停菜单', g.menuKind === 'pause', g.menuKind);
    g.handleAction('help'); pump(6);
    check('暂停 → 操作说明', g.menuKind === 'help', g.menuKind);
    g.handleAction('back'); pump(6);
    check('操作说明返回 → 回到暂停', g.menuKind === 'pause', g.menuKind);
    g.handleAction('resume'); pump(20);
    check('暂停「继续战斗」回到战斗', g.mode === 'play' && w().player.hp !== null, JSON.stringify(st()));

    out.errors = out.errors.concat(window.__errs || []);
    out.pass = out.cases.every(c => c.pass) && out.errors.length === 0;
    document.getElementById('report').textContent = 'LKREPORT' + JSON.stringify(out) + 'ENDLKREPORT';
    </script>
'''
o = src.replace('</body>', HARNESS + '\n  </body>')
if o == src:
    print('ERROR: no </body>', file=sys.stderr); sys.exit(1)
(dist / 'regress.html').write_text(o, encoding='utf-8')
print('written', dist / 'regress.html', len(o), 'bytes')
