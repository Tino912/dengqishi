/* ============================================================
   tools/sim.ts — 无浏览器逻辑仿真（npm run sim）
   两部分：
   A. 实战通关：用合成按键让机器人真的把第一关打完（正常推进 + 一次刷全压测），
      第二、三关各跑 150 秒做稳定性检查。
   B. 确定性链路测试：直接驱动"火盆 → 波次 → Boss → 清关 → 灯塔 → 渡河"整条链路，
      不依赖机器人操作水平，保证每次都覆盖到每个机制分支。
   另有：死亡与盲女之灯、灯塔/掌灯人交互、存档往返、内容数据自检。
   ============================================================ */
import { World, newProgress, Progress } from '../src/game/world';
import { Input } from '../src/core/input';
import { LEVELS } from '../src/game/levels';
import { WEAPONS, WEAPON_MAP } from '../src/game/content';
import { Save } from '../src/game/save';
import { dist } from '../src/core/utils';

/* ---- 最小环境垫片（node 下没有 DOM / localStorage） ---- */
const store: Record<string, string> = {};
(globalThis as any).window = { addEventListener() {}, devicePixelRatio: 1 };
(globalThis as any).localStorage = {
  getItem: (k: string) => (k in store ? store[k] : null),
  setItem: (k: string, v: string) => { store[k] = v; },
  removeItem: (k: string) => { delete store[k]; },
};

const DT = 1 / 60;

/* 固定随机源：让仿真结果可复现 */
const seedRand = (() => {
  let a = 0x9e3779b9 >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
})();
Math.random = seedRand as any;

let failures = 0;
function check(label: string, cond: boolean, extra = '') {
  if (!cond) failures++;
  console.log(`${cond ? '  ✓' : '  ✗'} ${label}${extra ? '　→ ' + extra : ''}`);
}
function note(text: string) { console.log(`  · ${text}`); }

/* ------------------------------------------------------------------
   机器人：会走位、会躲蓄力、血少会撤、攒够连击就放技能、会去点火盆
   （真人比它聪明得多，所以它的通关耗时只作为难度参考，不作硬指标）
   ------------------------------------------------------------------ */
const botState = { t: 0, x: 0, y: 0, detour: 0, sign: 1, lastHit: 0, killsMark: 0 };

function botStep(w: World, t: number) {
  Input.mouse.inside = false;
  Input._pressed.clear();
  Input.down.clear();
  const p = w.player;
  if (p.dead) return;

  const alive: { e: any; d: number }[] = [];
  for (const e of w.enemies) {
    if (e.dead) continue;
    alive.push({ e, d: dist(e.x, e.y, p.x, p.y) });
  }
  alive.sort((a, b) => a.d - b.d);
  const near = alive[0];

  if (w.prog.kills > botState.killsMark) { botState.killsMark = w.prog.kills; botState.lastHit = t; }
  const stalling = t - botState.lastHit > 25;   // 长时间打不到东西 → 全图追杀最近的敌人

  const need = w.level.braziersRequired ?? 0;
  const unlit = w.braziers.filter((b) => !b.lit);
  const wantBrazier = need > 0 && unlit.length > 0;
  const bossAlive = !!(w.bossEnemy && !w.bossEnemy.dead);

  let tx = w.level.boss.x, ty = w.level.boss.y;
  if (bossAlive && !(near && near.d < 120)) {
    tx = w.bossEnemy!.x; ty = w.bossEnemy!.y;
  } else if (wantBrazier && p.combo >= 4) {
    tx = unlit[0].x; ty = unlit[0].y;
  } else if (wantBrazier && near) {
    tx = near.e.x; ty = near.e.y;      // 连击不够点不燃火盆：先去打点东西攒连击
  } else if (near && near.d < 320) {
    tx = near.e.x; ty = near.e.y;
  } else {
    const un = w.waves.find((x) => !x.spawned) ?? w.waves.find((x) => !x.cleared);
    if (un) { tx = un.def.x; ty = un.def.y; }
  }
  if (stalling && near) { tx = near.e.x; ty = near.e.y; }

  let dx = tx - p.x, dy = ty - p.y;
  let len = Math.hypot(dx, dy) || 1;

  // 防卡墙：0.7 秒几乎没挪动就横着走一段
  if (t - botState.t >= 0.7) {
    const moved = Math.hypot(p.x - botState.x, p.y - botState.y);
    if (moved < 14) { botState.detour = 1.2; botState.sign = botState.sign > 0 ? -1 : 1; }
    botState.t = t; botState.x = p.x; botState.y = p.y;
  }
  if (botState.detour > 0) {
    botState.detour -= DT;
    const c = Math.cos((Math.PI / 2) * botState.sign), sn = Math.sin((Math.PI / 2) * botState.sign);
    const rx = dx * c - dy * sn, ry = dx * sn + dy * c;
    dx = rx; dy = ry; len = Math.hypot(dx, dy) || 1;
  }

  const danger = alive.find((a) => a.d < 96 && a.e.state === 'windup');
  const lowHp = p.hp < p.maxHp * 0.25;
  if (danger && p.dashCd <= 0) Input._pressed.add('ShiftLeft');

  if (lowHp && near && near.d < 300) {
    const ax = (p.x - near.e.x) / (near.d || 1), ay = (p.y - near.e.y) / (near.d || 1);
    if (ax > 0.3) Input._pressed.add('KeyD');
    if (ax < -0.3) Input._pressed.add('KeyA');
    if (ay > 0.3) Input._pressed.add('KeyS');
    if (ay < -0.3) Input._pressed.add('KeyW');
    if (near.d < 70) Input._pressed.add('KeyJ');
    if (p.hp < p.maxHp * 0.78) Input._pressed.add('KeyR');
  } else if (wantBrazier && p.combo >= 4 && dist(unlit[0].x, unlit[0].y, p.x, p.y) < unlit[0].r + 60) {
    Input._pressed.add('KeyE');           // 以连击之光点燃火盆
  } else if (near && near.d < 48) {
    Input._pressed.add('KeyJ');
  } else {
    if (dx / len > 0.28) Input._pressed.add('KeyD');
    if (dx / len < -0.28) Input._pressed.add('KeyA');
    if (dy / len > 0.28) Input._pressed.add('KeyS');
    if (dy / len < -0.28) Input._pressed.add('KeyW');
  }

  // 每 1.2 秒尝试放一个买得起的技能
  if ((t * 1000) % 1200 < DT * 1000) {
    const sk = [...p.weapon.skills].reverse().find((s) => s.cost <= p.combo && (p.skillCd[s.id] ?? 0) <= 0);
    if (sk) Input._pressed.add('Digit' + (p.weapon.skills.indexOf(sk) + 1));
  }
  Input.down = new Set(Input._pressed);
}

/* ============================================================
   A. 实战通关
   ============================================================ */
function playthrough(index: number, prog: Progress, opts: { spawnAll?: boolean; maxSec?: number }) {
  const spawnAll = !!opts.spawnAll;
  const maxSec = opts.maxSec ?? 260;
  console.log(`\n-- 实战：第 ${index + 1} 关 · ${LEVELS[index].name}（${spawnAll ? '一次刷全压测' : '正常推进'}） --`);
  const w = new World(index, prog, { spawnAll });
  botState.t = 0; botState.x = w.player.x; botState.y = w.player.y;
  botState.detour = 0; botState.lastHit = 0; botState.killsMark = prog.kills;

  const seen = new Set<string>();
  let revives = 0, clearAt = -1;
  let maxCombo = 0, maxAlive = 0, dmgTaken = 0, hpMark = w.player.hp;
  const hpMap = new Map<number, number>();
  let dmgDealt = 0;
  let crash: Error | null = null;

  for (let f = 0; f < maxSec * 60; f++) {
    const t = f * DT;
    botStep(w, t);
    try {
      w.update(DT);
    } catch (err) { crash = err as Error; break; }

    for (const ev of w.drainEvents()) seen.add(ev.type + (ev.type === 'dialogue' ? ':' + (ev as any).key : ''));
    for (const e of w.enemies) {
      const prev = hpMap.get(e.id);
      if (prev !== undefined && e.hp < prev) dmgDealt += prev - e.hp;
      hpMap.set(e.id, e.hp);
    }
    maxCombo = Math.max(maxCombo, Math.floor(w.player.combo));
    let aliveCount = 0;
    for (const e of w.enemies) if (!e.dead) aliveCount++;
    maxAlive = Math.max(maxAlive, aliveCount);
    if (w.player.hp < hpMark) dmgTaken += hpMark - w.player.hp;
    hpMark = Math.max(w.player.hp, 0);
    if (w.player.dead) {     // 游戏里会回灯塔；仿真里就地续命，好把数据跑完
      revives++;
      w.player.dead = false; w.player.deathT = 0;
      w.player.hp = w.player.maxHp; w.player.invuln = 1.5;
    }
    if (w.cleared) {
      clearAt = t;
      for (let k = 0; k < 240; k++) { botStep(w, t + k * DT); w.update(DT); w.drainEvents(); }
      break;
    }
  }

  if (crash) {
    check('长时间运行不抛异常', false, crash.message);
    console.log(crash.stack);
    return { world: w, clearAt, seen, dmgDealt, maxCombo, maxAlive, revives };
  }
  check('长时间运行不抛异常', true);
  note(`${clearAt > 0 ? `清关 ${clearAt.toFixed(0)}s` : `${maxSec}s 内没打完`}　最大同屏 ${maxAlive}　最高连击 ${maxCombo}` +
    `　输出 ${Math.round(dmgDealt)}　受击 ${Math.round(dmgTaken)}　仿真续命 ${revives}`);
  note(`事件：${[...seen].join(', ') || '（无）'}`);
  return { world: w, clearAt, seen, dmgDealt, maxCombo, maxAlive, revives };
}

console.log('LightKnight 逻辑仿真开始');
console.log('\n=== A. 实战通关（机器人操作） ===');

const prog = newProgress();
{
  const r = playthrough(0, prog, { maxSec: 220 });
  check('[第一关] 波次触发并刷出敌人', r.world.waves.some((x) => x.spawned));
  check('[第一关] 敌人可被击杀', prog.kills > 0, `kills=${prog.kills}`);
  check('[第一关] 连击机制生效', r.maxCombo >= 5, `maxCombo=${r.maxCombo}`);
  check('[第一关] 技能被释放并消耗连击', Object.keys(r.world.player.skillCd).length > 0,
    Object.keys(r.world.player.skillCd).join(',') || '（没放过技能）');
  check('[第一关] 波次全部清空后才会推进', r.world.waves.every((x) => x.cleared),
    r.world.waves.map((x) => (x.spawned ? (x.cleared ? '清' : '战') : '未')).join('/'));
  check('[第一关] 实战通关（Boss 是被真打死的）', r.clearAt > 0, `耗时 ${r.clearAt.toFixed(0)}s`);
  check('[第一关] 清关后灯塔点亮', r.world.cleared && prog.lit.includes(0), `lit=[${prog.lit}]`);
  check('[第一关] 清关后地图变亮', r.world.ambient < LEVELS[0].ambient - 0.05, r.world.ambient.toFixed(3));
  check('[第一关] 清关触发主线对白', [...r.seen].some((s) => s.startsWith('dialogue:l1_')),
    [...r.seen].filter((s) => s.startsWith('dialogue')).join(', '));
  check('[第一关] 灯火可掉落可拾取', prog.coins > 0, `coins=${prog.coins}`);
  prog.level = 1;
}
{
  const p = newProgress();
  p.weapon = 'hammer';
  p.weapons = ['blade', 'spear', 'hammer'];
  p.up = { hp: 6, light: 5, edge: 5 };
  p.shop = { ember: 3, brightoil: 3 };
  const r = playthrough(0, p, { spawnAll: true, maxSec: 160 });
  check('[压测] 一次刷全全部波次仍能通关', r.clearAt > 0, `耗时 ${r.clearAt.toFixed(0)}s，最大同屏 ${r.maxAlive}`);
  check('[压测] 敌人数量受控（Boss 召唤有上限）', r.world.enemies.length < 120, `敌人数 ${r.world.enemies.length}`);
}
for (const i of [1, 2]) {
  const p = newProgress();
  p.weapon = WEAPONS[i].id;
  p.weapons = WEAPONS.map((x) => x.id);
  p.up = { hp: 3, light: 3, edge: 3 };
  const r = playthrough(i, p, { maxSec: 150 });
  check(`[第 ${i + 1} 关] 150 秒混战不崩、数值不失控`,
    Number.isFinite(r.world.player.hp) && r.world.player.hp >= 0 &&
    r.world.enemies.every((e) => Number.isFinite(e.hp)) && r.world.enemies.length < 120,
    `玩家血量 ${Math.round(r.world.player.hp)}，敌人数 ${r.world.enemies.length}`);
}

/* ============================================================
   B. 确定性链路测试（不依赖机器人水平）
   ============================================================ */
console.log('\n=== B. 关卡链路（确定性驱动） ===');

function step(w: World, frames = 1) { for (let i = 0; i < frames; i++) w.update(DT); }
/** 再生出来的"游魂"：不属于任何波次的敌人 */
function strays(w: World) {
  const memberIds = new Set<number>();
  for (const wv of w.waves) for (const id of wv.members) memberIds.add(id);
  return w.enemies.filter((e) => !e.dead && !memberIds.has(e.id)).length;
}
function teleport(w: World, x: number, y: number) { w.player.x = x; w.player.y = y; }
/** 走到波次区域触发刷怪，再把这一波自己的成员打死 */
function clearWave(w: World, waveIdx: number) {
  const def = w.waves[waveIdx].def;
  teleport(w, def.x, def.y);
  step(w, 3);
  for (const id of w.waves[waveIdx].members) {
    const e = w.enemies.find((x) => x.id === id);
    if (e && !e.dead) w.damageEnemy(e, e.maxHp * 2, 0, 0);
  }
  step(w, 3);
}
function drain(w: World) {
  const evs: string[] = [];
  for (const e of w.drainEvents()) evs.push(e.type + (e.type === 'dialogue' ? ':' + (e as any).key : ''));
  return evs;
}

/* —— 第二关：火盆护佑 → 再生停止 —— */
{
  console.log('\n-- 第二关 · 无芯之暗：无芯之暗的规则 --');
  const p = newProgress();
  const w = new World(1, p);
  const need = LEVELS[1].braziersRequired ?? 0;
  check('火盆没点齐时 Boss 处于护佑状态', w.bossWarded && w.braziersLit === 0);
  const e0 = w.enemies.length;
  step(w, 60 * 12);
  check('无芯之暗会不断再生影子', w.enemies.length > e0, `${e0} → ${w.enemies.length}`);

  w.player.combo = 30;
  const litEvs: string[] = [];
  for (const b of w.braziers) {
    teleport(w, b.x, b.y + 30);
    Input._pressed.clear(); w.update(DT);
    Input._pressed.add('KeyE'); w.update(DT);
    litEvs.push(...drain(w));
  }
  check('三座火盆全部点燃', w.braziersLit === need, `${w.braziersLit}/${need}`);
  check('点燃后护佑解除', !w.bossWarded);
  check('点燃火盆触发了盲女对白', litEvs.includes('dialogue:l2_brazier'),
    litEvs.filter((x) => x.startsWith('dialogue')).join(','));
  const before = strays(w);
  step(w, 60 * 14);
  check('护佑解除后影子不再再生', strays(w) <= before + 3, `游魂 ${before} → ${strays(w)}`);
}

/* —— 第二关：护佑减伤 → Boss → 盲女化为灯芯 —— */
{
  console.log('\n-- 第二关 · 无芯之暗：Boss 与盲女 --');
  const p = newProgress();
  const w = new World(1, p);
  teleport(w, LEVELS[1].boss.x, LEVELS[1].boss.y + 60);
  clearWave(w, 0); clearWave(w, 1); clearWave(w, 2);
  check('三波清空后波次状态为"清"', w.waves.every((x) => x.cleared),
    w.waves.map((x) => (x.spawned ? (x.cleared ? '清' : '战') : '未')).join('/'));
  // 波次清空后走回 Boss 区域，Boss 才会现身（符合"进入区域遭遇"的设计）
  teleport(w, LEVELS[1].boss.x, LEVELS[1].boss.y + 60);
  step(w, 10);
  check('走回 Boss 区域后 Boss 出现', w.bossSpawned && !!w.bossEnemy, LEVELS[1].boss.label);
  if (w.bossEnemy) {
    const before = w.bossEnemy.hp;
    w.damageEnemy(w.bossEnemy, 200, 0, 0);
    check('护佑下 Boss 伤害被大幅削减', (before - w.bossEnemy.hp) < 200 * 0.3,
      `打 200 实际掉 ${Math.round(before - w.bossEnemy.hp)}`);
    check('护佑下 Boss 会缓慢自愈', (() => {
      const h0 = w.bossEnemy!.hp;
      step(w, 60 * 4);
      return w.bossEnemy!.hp > h0;
    })(), `自愈到 ${Math.round(w.bossEnemy.hp)}`);
    // 点齐火盆解除护佑
    w.player.combo = 30;
    for (const b of w.braziers) {
      teleport(w, b.x, b.y + 30);
      Input._pressed.clear(); w.update(DT);
      Input._pressed.add('KeyE'); w.update(DT);
    }
    drain(w);
    check('解除护佑后 Boss 正常吃伤害', (() => {
      const h0 = w.bossEnemy!.hp;
      w.damageEnemy(w.bossEnemy!, 200, 0, 0);
      return h0 - w.bossEnemy!.hp > 200 * 0.9;
    })());
    w.damageEnemy(w.bossEnemy, w.bossEnemy.maxHp * 2, 0, 0);
  }
  const evs = drain(w);
  check('Boss 死亡 → 清关事件', evs.includes('bossEnd') && evs.includes('levelCleared'), evs.join(','));
  check('清关后灯塔点亮并发放灯芯', w.cleared && p.lit.includes(1) && p.wicks >= 1, `灯芯${p.wicks}`);
  check('盲女化为灯芯（永久获得盲女之灯）', p.blindGirl === true);
  check('第二关清关有主线对白', evs.includes('dialogue:l2_clear'), evs.filter((x) => x.startsWith('dialogue')).join(','));
}

/* —— 第三关：Boss 三阶段 → 渡河终章 —— */
{
  console.log('\n-- 第三关 · 灯河渡口 --');
  const p = newProgress();
  p.blindGirl = true;
  const w = new World(2, p);
  teleport(w, LEVELS[2].boss.x, LEVELS[2].boss.y + 60);
  clearWave(w, 0); clearWave(w, 1); clearWave(w, 2);
  teleport(w, LEVELS[2].boss.x, LEVELS[2].boss.y + 60);
  step(w, 10);
  check('三波清空、走回渡口后 Boss 如期出现', w.bossSpawned && !!w.bossEnemy, LEVELS[2].boss.label);
  const b = w.bossEnemy;
  if (b) {
    const phases = new Set<number>();
    for (let i = 0; i < 60 && !b.dead; i++) {
      w.damageEnemy(b, b.maxHp * 0.05, 0, 0);
      step(w, 40);
      phases.add(b.boss?.phase ?? 1);
    }
    check('Boss 会依次推进三个阶段', phases.size >= 3, `经历阶段 ${[...phases].sort().join(',')}`);
    check('Boss 被打死', b.dead);
  }
  const evs = drain(w);
  check('清关 + 终章对白', w.cleared && evs.includes('dialogue:l3_clear'), evs.filter((x) => x.startsWith('dialogue')).join(','));
  check('第三关没有火盆机制（护佑不适用）', (LEVELS[2].braziersRequired ?? 0) === 0);

  teleport(w, LEVELS[2].goal.x, LEVELS[2].goal.y + 40);
  Input._pressed.clear(); w.update(DT);
  check('站上渡口出现"渡过灯河"提示', !!w.prompt && w.prompt.includes('渡过灯河'), w.prompt ?? '（无）');
  Input._pressed.add('KeyE'); w.update(DT);
  const evs2 = drain(w);
  check('按 E 触发 V1 终章', evs2.includes('victory'), evs2.join(','));
}

/* —— 第一关：灯塔菜单 + 掌灯人 + 火盆 + 灯油 —— */
{
  console.log('\n-- 灯塔 / 掌灯人 / 火盆 交互 --');
  const p = newProgress();
  const w = new World(0, p, { spawnAll: true });
  check('未清关时灯塔是暗的', !w.cleared && !w.goalProp.lit);
  w.player.x = w.goalProp.x; w.player.y = w.goalProp.y + 40;
  Input._pressed.clear(); Input._pressed.add('KeyE'); w.update(DT);
  let evs = drain(w);
  check('未清关时灯塔拒绝开启菜单', !evs.includes('openLighthouse'), evs.join(',') || '（无事件）');

  w.damageEnemy(w.bossEnemy!, w.bossEnemy!.maxHp * 2, 0, 0);
  evs = drain(w);
  check('Boss 死亡触发 bossEnd / levelCleared', evs.includes('bossEnd') && evs.includes('levelCleared'), evs.join(','));
  check('清关后灯塔点亮', w.cleared && w.goalProp.lit);
  check('清关发放灯芯与灯火', p.wicks >= 1 && p.coins >= 80, `灯芯${p.wicks} 灯火${p.coins}`);
  check('Boss 掉落灯火与灯芯到地面', w.drops.some((d) => d.kind === 'wick') && w.drops.some((d) => d.kind === 'coin'));

  w.player.x = w.goalProp.x; w.player.y = w.goalProp.y + 40;
  Input._pressed.clear(); Input._pressed.add('KeyE'); w.update(DT);
  evs = drain(w);
  check('清关后可在灯塔处休整（打开菜单）', evs.includes('openLighthouse'), evs.join(','));

  const m = w.props.find((x) => x.kind === 'merchant')!;
  w.player.x = m.x; w.player.y = m.y + 40;
  Input._pressed.clear(); w.update(DT);
  check('靠近掌灯人出现交互提示', !!w.prompt && w.prompt.includes('掌灯人'), w.prompt ?? '（无提示）');
  Input._pressed.add('KeyE'); w.update(DT);
  evs = drain(w);
  check('按 E 打开掌灯人商店', evs.includes('openShop'), evs.join(','));

  const b = w.braziers[0];
  w.player.x = b.x; w.player.y = b.y + 30;
  w.player.combo = 0;
  Input._pressed.clear(); Input._pressed.add('KeyE'); w.update(DT);
  check('连击不足时点不燃火盆', !b.lit, `combo=${w.player.combo}`);
  w.player.combo = 6;
  Input._pressed.clear(); Input._pressed.add('KeyE'); w.update(DT);
  check('4 连击以上可点燃火盆并消耗连击', b.lit && w.player.combo < 6, `剩余连击 ${w.player.combo}`);

  w.prog.oil = 1; w.player.hp = 10;
  Input._pressed.clear(); Input._pressed.add('KeyR'); w.update(DT);
  check('灯油可回复生命', w.player.hp > 10 && w.prog.oil === 0, `hp=${Math.round(w.player.hp)}`);
}

/* ============================================================
   C. 死亡 / 存档 / 数据自检
   ============================================================ */
console.log('\n=== C. 死亡与诅咒复活 ===');
{
  const p = newProgress();
  p.blindGirl = true;
  const w = new World(0, p);
  w.hurtPlayer(9999, 0);
  check('盲女之灯替玩家燃了一次', !w.player.dead && w.player.hp > 0, `hp=${Math.round(w.player.hp)}`);
  w.player.invuln = 0;
  w.hurtPlayer(9999, 0);
  const ev = drain(w);
  check('致命伤后判定死亡', w.player.dead);
  check('抛出 playerDead 事件（被诅咒拖回灯塔）', ev.includes('playerDead'));
  check('死亡计数 +1', p.deaths === 1);
  const before = { x: w.player.x, y: w.player.y };
  botStep(w, 1); w.update(DT);
  check('死亡后玩家不再移动（保护）', w.player.x === before.x && w.player.y === before.y);
}

console.log('\n=== C. 存档往返 ===');
{
  const p = newProgress();
  p.coins = 321; p.wicks = 5; p.up = { hp: 2, light: 1, edge: 3 };
  p.weapons = ['blade', 'spear']; p.weapon = 'spear';
  p.lit = [0, 1]; p.cleared = [0, 1]; p.blindGirl = true; p.level = 2;
  Save.write(p);
  const back = Save.load();
  check('存档可读回', !!back);
  check('字段完整', !!back && back.coins === 321 && back.wicks === 5 && back.up.edge === 3 &&
    back.weapon === 'spear' && back.weapons.length === 2 && back.blindGirl === true && back.level === 2);
}

console.log('\n=== C. 内容数据自检 ===');
for (const w of WEAPONS) {
  check(`【${w.name}】技能连击门槛递增且为正（README：技能需要连击数解锁）`,
    w.skills.every((s) => s.cost > 0) && w.skills.every((s, i, a) => i === 0 || s.cost > a[i - 1].cost),
    w.skills.map((s) => `${s.name}:${s.cost}`).join(' '));
}
check('三把武器的技能数量各不相同（README 要求）',
  new Set(WEAPONS.map((w) => w.skills.length)).size === WEAPONS.length,
  WEAPONS.map((w) => `${w.name}(${w.skills.length})`).join(' '));
check('武器表可查询', !!WEAPON_MAP['blade'] && !!WEAPON_MAP['spear'] && !!WEAPON_MAP['hammer']);
check('三关都有 Boss、终点与光照参数', LEVELS.every((l) => !!l.boss.type && !!l.goal.kind && l.ambient > 0.5));
check('灯芯升级会同时作用于血量与亮度', (() => {
  const a = new World(0, newProgress());
  const p2: Progress = newProgress();
  p2.up = { hp: 6, light: 5, edge: 0 };
  p2.shop = { ember: 2, brightoil: 2 };
  const b2 = new World(0, p2);
  return b2.lightRadius > a.lightRadius && b2.player.maxHp > a.player.maxHp;
})());

console.log(`\n${failures === 0 ? '全部通过 ✅' : `有 ${failures} 项未通过 ❌`}`);
process.exit(failures === 0 ? 0 : 1);
