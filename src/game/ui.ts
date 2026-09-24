/* ============================================================
   ui.ts — HUD / 对白 / 菜单 / 过场（全部 DOM 浮层）
   ============================================================ */
import { clamp } from '../core/utils';
import { Line, WeaponDef, WEAPONS, UPGRADES, upgradeCost, SHOP_ITEMS } from './content';
import { World, Progress } from './world';
import { LEVELS } from './levels';

const $ = (id: string) => document.getElementById(id)!;

export class UI {
  hudEl = $('hud');
  hpFill = $('hpFill');
  hpText = $('hpText');
  lightFill = $('lightFill');
  coins = $('coins');
  wicks = $('wicks');
  upgSummary = $('upgSummary');
  comboEl = $('combo');
  comboNum = $('comboNum');
  comboHint = $('comboHint');
  skillsEl = $('skills');
  promptEl = $('prompt');
  toastWrap = $('toastwrap');
  objectiveEl = $('objective');
  bossbar = $('bossbar');
  bossname = $('bossname');
  bossFill = $('bossFill');
  bossphase = $('bossphase');
  dlgEl = $('dialogue');
  dSpeaker = $('dSpeaker');
  dText = $('dText');
  dHint = $('dHint');
  overlay = $('overlay');
  fadeEl = $('fade');
  cutEl = $('cutscene');
  cutText = $('cutText');

  private slotEls: { root: HTMLElement; nm: HTMLElement; cst: HTMLElement; cd: HTMLElement; cdnum: HTMLElement }[] = [];
  private weaponId = '';
  private dlines: Line[] = [];
  private di = 0;
  private dshown = 0;
  private dtyping = 0;
  private dDone: (() => void) | null = null;
  dActive = false;
  private toastCount = 0;

  constructor() {
    this.skillsEl.innerHTML = '';
  }

  /* ------------------------- HUD ------------------------- */

  hudVisible(v: boolean) {
    this.hudEl.classList.toggle('hidden', !v);
  }

  syncHud(world: World, prog: Progress) {
    const p = world.player;
    const hp01 = clamp(p.hp / p.maxHp, 0, 1);
    this.hpFill.style.transform = `scaleX(${hp01})`;
    this.hpText.textContent = `${Math.max(0, Math.ceil(p.hp))} / ${Math.round(p.maxHp)}`;
    this.lightFill.style.transform = `scaleX(${clamp(world.brightness01, 0, 1)})`;
    this.coins.textContent = String(prog.coins);
    this.wicks.textContent = String(prog.wicks);
    this.upgSummary.textContent = `燃${prog.up.hp} 明${prog.up.light} 锋${prog.up.edge}${prog.blindGirl ? ' · 盲女之灯' : ''}`;
    this.objectiveEl.innerHTML = world.objective;

    // 连击
    const c = Math.floor(p.combo);
    if (c >= 2) {
      this.comboEl.classList.remove('hidden');
      this.comboNum.textContent = String(c);
      const next = world.player.weapon.skills.find((s) => s.cost > c);
      this.comboHint.textContent = next ? `${next.name} 还需 ${next.cost - c} 连击` : '全部技能就绪';
      const sc = 1 + Math.min(c, 40) / 60;
      this.comboEl.style.transform = `translate(-50%, -50%) scale(${sc.toFixed(3)})`;
      this.comboEl.style.opacity = String(clamp(0.35 + c / 30, 0, 1));
    } else {
      this.comboEl.classList.add('hidden');
    }

    // 技能
    this.renderSkills(world);

    // 提示
    if (world.prompt) {
      this.promptEl.classList.remove('hidden');
      this.promptEl.innerHTML = world.prompt.replace(/按 ([A-Z])/, '按 <kbd>$1</kbd>');
    } else {
      this.promptEl.classList.add('hidden');
    }

    // Boss 血条
    if (world.bossEnemy && !world.bossEnemy.dead && world.bossSpawned) {
      this.bossbar.classList.remove('hidden');
      this.bossname.textContent = world.level.boss.label;
      this.bossFill.style.transform = `scaleX(${world.bossHp01})`;
      this.bossphase.textContent = world.bossPhaseText;
    } else {
      this.bossbar.classList.add('hidden');
    }
  }

  private renderSkills(world: World) {
    const w: WeaponDef = world.player.weapon;
    if (this.weaponId !== w.id) {
      this.weaponId = w.id;
      this.skillsEl.innerHTML = '';
      this.slotEls = [];
      w.skills.forEach((s, i) => {
        const d = document.createElement('div');
        d.className = 'slot';
        d.innerHTML = `<span class="key">${i + 1}</span><span class="nm"></span><span class="cst"></span><div class="cd hidden"></div><div class="cdnum hidden"></div>`;
        this.skillsEl.appendChild(d);
        this.slotEls.push({
          root: d,
          nm: d.querySelector('.nm')!,
          cst: d.querySelector('.cst')!,
          cd: d.querySelector('.cd')!,
          cdnum: d.querySelector('.cdnum')!,
        });
      });
      // 无技能时给个说明格
      if (w.skills.length === 0) {
        const d = document.createElement('div');
        d.className = 'slot locked';
        d.innerHTML = `<span class="nm">无技能</span>`;
        this.skillsEl.appendChild(d);
      }
    }
    const combo = world.player.combo;
    w.skills.forEach((s, i) => {
      const el = this.slotEls[i];
      if (!el) return;
      el.nm.textContent = s.name;
      el.cst.textContent = `连击 ${s.cost}`;
      const cd = world.player.skillCd[s.id] ?? 0;
      const unlocked = combo >= s.cost;
      el.root.classList.toggle('locked', !unlocked);
      el.root.classList.toggle('ready', unlocked && cd <= 0);
      if (cd > 0) {
        const f = clamp(cd / s.cd, 0, 1);
        el.cd.classList.remove('hidden');
        el.cdnum.classList.remove('hidden');
        el.cd.style.height = (f * 100) + '%';
        el.cdnum.textContent = cd.toFixed(1);
      } else {
        el.cd.classList.add('hidden');
        el.cdnum.classList.add('hidden');
      }
    });
  }

  toast(text: string) {
    const d = document.createElement('div');
    d.className = 'toast';
    d.innerHTML = text;
    this.toastWrap.appendChild(d);
    this.toastCount++;
    if (this.toastCount > 4) {
      const first = this.toastWrap.firstElementChild as HTMLElement | null;
      if (first) first.remove();
    }
    setTimeout(() => {
      d.style.transition = 'opacity .4s';
      d.style.opacity = '0';
      setTimeout(() => d.remove(), 420);
    }, 2400);
  }

  /* ------------------------- 对白 ------------------------- */

  showDialogue(lines: Line[], onDone: () => void) {
    this.dlines = lines;
    this.di = 0;
    this.dshown = 0;
    this.dtyping = 0;
    this.dDone = onDone;
    this.dActive = true;
    this.dlgEl.classList.remove('hidden');
    this.renderLine();
  }

  private renderLine() {
    const l = this.dlines[this.di];
    if (!l) return;
    this.dSpeaker.textContent = l.speaker;
    this.dSpeaker.style.color = speakerColor(l.speaker);
    this.dText.textContent = l.text.slice(0, Math.floor(this.dshown));
    this.dHint.style.opacity = this.dshown >= l.text.length ? '1' : '0.35';
  }

  updateDialogue(dt: number) {
    if (!this.dActive) return;
    const l = this.dlines[this.di];
    if (!l) return;
    this.dshown += dt * 46;
    this.renderLine();
  }

  get dialogueFullyShown() {
    const l = this.dlines[this.di];
    return !l || this.dshown >= l.text.length;
  }

  advanceDialogue() {
    if (!this.dActive) return;
    const l = this.dlines[this.di];
    if (!l) return;
    if (!this.dialogueFullyShown) {
      this.dshown = l.text.length;
      this.renderLine();
      return;
    }
    this.di++;
    this.dshown = 0;
    if (this.di >= this.dlines.length) {
      this.dActive = false;
      this.dlgEl.classList.add('hidden');
      const cb = this.dDone;
      this.dDone = null;
      if (cb) cb();
    } else {
      this.renderLine();
    }
  }

  /* ------------------------- 全屏菜单 ------------------------- */

  screen(html: string) {
    this.overlay.innerHTML = html;
    this.overlay.classList.remove('hidden');
  }
  hideScreen() {
    this.overlay.classList.add('hidden');
    this.overlay.innerHTML = '';
  }
  get screenOpen() { return !this.overlay.classList.contains('hidden'); }

  fade(on: boolean) {
    this.fadeEl.classList.toggle('on', on);
  }

  /* ------------------------- 过场 ------------------------- */

  cut(text: string, sub?: string) {
    this.cutEl.classList.remove('hidden');
    this.cutText.innerHTML = text + (sub ? `<span class="small">${sub}</span>` : '');
  }
  hideCut() { this.cutEl.classList.add('hidden'); }

  /* ------------------------- 菜单键盘导航 ------------------------- */

  private focusIndex = 0;
  private lastNav = 0;

  navMenu(dt: number) {
    if (!this.screenOpen) return;
    const btns = Array.from(this.overlay.querySelectorAll<HTMLElement>('.btn:not(.disabled)'));
    if (!btns.length) return;
    this.lastNav += dt;
    if (this.focusIndex >= btns.length) this.focusIndex = 0;
    if (this.lastNav > 0.14) {
      // 键位在 main 里已经 edge-trigger，这里只做高亮跟随
      this.lastNav = 0;
    }
    btns.forEach((b, i) => b.style.outline = i === this.focusIndex ? '1px solid rgba(255,203,107,0.5)' : 'none');
  }
  moveFocus(dir: number) {
    const btns = Array.from(this.overlay.querySelectorAll<HTMLElement>('.btn:not(.disabled)'));
    if (!btns.length) return;
    this.focusIndex = (this.focusIndex + dir + btns.length) % btns.length;
  }
  clickFocused() {
    const btns = Array.from(this.overlay.querySelectorAll<HTMLElement>('.btn:not(.disabled)'));
    if (!btns.length) return false;
    const b = btns[this.focusIndex] ?? btns[0];
    b.click();
    return true;
  }
  resetFocus() { this.focusIndex = 0; }
}

function speakerColor(name: string) {
  switch (name) {
    case '灯骑士': return '#ffd070';
    case '盲女': return '#e8eefc';
    case '掌灯人': return '#c9a6ff';
    case '噬灯者':
    case '噬灯者·幼体': return '#ff6a4a';
    case '灯魔之影': return '#b48cff';
    case '灯河': return '#9fd8ff';
    default: return '#a9a291';
  }
}

/* ============================================================
   各类菜单的 HTML 构造
   ============================================================ */

export function titleScreen(prog: Progress, hasSave: boolean) {
  const lv = LEVELS[clamp(prog.level, 0, LEVELS.length - 1)];
  return `
  <div class="screen">
    <h1>灯骑士<small>LIGHTKNIGHT · V1 MVP</small></h1>
    <p class="quote">暂时的是现实，永恒的是理想。</p>
    <p>黑暗吞掉了整座灯堡，只有你身边一点亮。连击就是你的灯——打中敌人光就变强，停下来就会暗下去；
       每把武器的技能都要靠连击数才能解锁。一关打完，灯塔才会亮起，那是你唯一的存档与庇护。</p>
    <div class="menu">
      <button class="btn primary" data-act="${hasSave ? 'continue' : 'new'}">
        ${hasSave ? '继续旅程' : '开始旅程'}
        <span class="sub">${hasSave ? `第 ${prog.level + 1} 关 · ${lv.name}　灯火 ${prog.coins}　灯芯 ${prog.wicks}` : '从序章开始'}</span>
      </button>
      ${hasSave ? `<button class="btn" data-act="new">新的旅程<span class="sub">清空进度，从序章重新开始</span></button>` : ''}
      <button class="btn" data-act="help">操作说明<span class="sub">键位与核心机制</span></button>
      <button class="btn" data-act="about">关于本作<span class="sub">V1 设定与设计来源</span></button>
    </div>
    <div class="hintline">点击画面任意处即可启用音效（WebAudio 程序化生成，无音频素材）</div>
  </div>`;
}

export function helpScreen() {
  return `
  <div class="screen">
    <h2>操作说明</h2>
    <h3>移动与战斗</h3>
    <table class="keys">
      <tr><td><kbd class="k">W</kbd><kbd class="k">A</kbd><kbd class="k">S</kbd><kbd class="k">D</kbd></td><td>移动（也可用方向键）</td></tr>
      <tr><td>鼠标移动</td><td>决定朝向与攻击方向（按鼠标位置瞄准）</td></tr>
      <tr><td><kbd class="k">J</kbd> / 鼠标左键</td><td>普通攻击（命中即积累连击）</td></tr>
      <tr><td><kbd class="k">Shift</kbd></td><td>冲刺翻滚（短暂无敌，用来穿出包围）</td></tr>
      <tr><td><kbd class="k">1</kbd><kbd class="k">2</kbd><kbd class="k">3</kbd></td><td>武器技能（需要足够的连击数，使用会消耗连击）</td></tr>
      <tr><td><kbd class="k">E</kbd> / <kbd class="k">F</kbd></td><td>交互：与掌灯人交易、点燃火盆、在灯塔处休整、渡过灯河</td></tr>
      <tr><td><kbd class="k">R</kbd></td><td>使用灯油回复生命</td></tr>
      <tr><td><kbd class="k">Esc</kbd></td><td>暂停 / 操作说明</td></tr>
      <tr><td>空格 / <kbd class="k">E</kbd></td><td>对白推进（再按一次可跳过打字）</td></tr>
    </table>
    <h3>三条核心机制</h3>
    <p><b>① 连击即光。</b>连击越高，光照半径越大；2.6 秒不命中就会开始变暗。变暗意味着视野变窄、伤害下降，也更容易被影子咬住。被击中会掉 3 点连击——这是最贵的代价。</p>
    <p><b>② 技能吃连击。</b>每把武器自带的技能都有连击门槛，达到门槛才能释放，释放会扣掉对应的连击数。所以"攒连击放技能"与"保持明亮"之间永远在互相拉扯。</p>
    <p><b>③ 灯塔只在清关后亮。</b>没打完就死了，会被诅咒拖回上一座灯塔，本关敌人全部重置；清关后灯塔亮起，那里可以存档、用灯芯升级、找掌灯人补给，并渡过灯河前往下一关。</p>
    <h3>第二关的特殊规则</h3>
    <p>「无芯之暗」里没有灯芯——三座火盆没点齐之前，影子会不断再生，而噬灯者处于"护佑"状态（伤害减免 84% 并缓慢自愈）。点燃火盆需要 <b>4 连击</b>：靠近火盆按 <kbd class="k">E</kbd>，或直接用攻击/技能打到它。</p>
    <div class="menu"><button class="btn primary" data-act="close">返回</button></div>
  </div>`;
}

export function aboutScreen() {
  return `
  <div class="screen">
    <h2>关于本作</h2>
    <p class="quote">LightKnight 灯骑士 · V1 MVP（Web 技术栈实现）</p>
    <div class="lore">游戏：灯河（LightRiver）
主角：灯骑士（LightKnight）——少年受到诅咒
关卡：灯堡　物品：灯火（货币）、灯芯（点亮灯塔，让主角更强）
灯塔：庇护所、存档、传送点　Boss：噬灯者　NPC：掌灯人（商人）</div>
    <p>本 MVP 按 README 的 V1 目标实现：3 张地图分别讲述<b>美好过往 / 遇难 / 踏上复仇</b>，具备可玩的战斗系统与连贯的主线叙事，2.5D 俯视角。</p>
    <h3>已实现</h3>
    <p>· 2.5D 斜轴测地图与程序化绘制的人物、怪物、建筑（零外部素材）<br>
       · 黑暗中的光照系统：连击提高亮度、随时间变暗、火盆与灯塔作为场景光源<br>
       · 3 把武器、7 个技能，全部以连击数解锁并消耗连击<br>
       · 4 种敌人 + 精英化 + 3 个 Boss（多阶段 AI：扑食 / 呼影 / 吞噬光 / 横扫）<br>
       · 灯塔存档、灯芯升级、掌灯人商店、灯火掉落、精英与 Boss 奖励<br>
       · 主线对白、灯河过场、盲女同行与"盲女之灯"的濒死救赎<br>
       · WebAudio 程序化音效与随连击强度变化的背景音乐</p>
    <h3>技术</h3>
    <p>TypeScript + Vite + Canvas 2D 手写引擎：固定步长循环、斜轴测投影、深度排序、destination-out 光照挖洞 + 加光合成、命中定格与震屏。</p>
    <div class="menu"><button class="btn primary" data-act="close">返回</button></div>
  </div>`;
}

export function pauseScreen(world: World) {
  const w = world.player.weapon;
  return `
  <div class="screen">
    <h2>暂停</h2>
    <p class="quote">${world.level.subtitle}　·　${world.level.name}</p>
    <p>当前武器：<b>${w.name}</b>　连击：<b>${Math.floor(world.player.combo)}</b>　灯火：<b>${world.prog.coins}</b>　灯芯：<b>${world.prog.wicks}</b></p>
    <div class="menu">
      <button class="btn primary" data-act="resume">继续战斗</button>
      <button class="btn" data-act="help">操作说明</button>
      <button class="btn" data-act="save">存档（就地存档，写入浏览器）</button>
      <button class="btn" data-act="totitle">回到标题<span class="sub">当前进度会先保存</span></button>
    </div>
  </div>`;
}

export function deathScreen(world: World) {
  return `
  <div class="screen">
    <h2>你的灯灭了</h2>
    <p class="lore">你是受诅咒者。死了也散不掉，\n只会被拖回上一座亮着的灯塔。</p>
    <p>本关进度已重置，散落的灯火只找回了一部分。已获得的<b>灯芯</b>与<b>升级</b>不会丢失。</p>
    <p>当前：灯火 <b>${world.prog.coins}</b>　灯芯 <b>${world.prog.wicks}</b>　累计击杀 <b>${world.prog.kills}</b></p>
    <div class="menu">
      <button class="btn primary" data-act="respawn">回到灯塔，再来一次</button>
      <button class="btn" data-act="help">操作说明</button>
      <button class="btn" data-act="totitle">回到标题</button>
    </div>
  </div>`;
}

export function lighthouseScreen(world: World, isLast: boolean) {
  const need = world.level.braziersRequired ?? 0;
  void need;
  return `
  <div class="screen">
    <h2>${world.level.goal.name}　·　已点亮</h2>
    <p class="quote">灯塔是庇护所、存档点、传送点。</p>
    <p>灯火 <b>${world.prog.coins}</b>　灯芯 <b>${world.prog.wicks}</b>　灯芯升级 <b>燃${world.prog.up.hp} / 明${world.prog.up.light} / 锋${world.prog.up.edge}</b></p>
    <div class="menu">
      <button class="btn primary" data-act="save">点亮并存档<span class="sub">写入浏览器本地存档</span></button>
      <button class="btn" data-act="upgrade">灯芯升级<span class="sub">消耗灯芯，永久提升血量与亮度</span></button>
      <button class="btn" data-act="shop">与掌灯人交谈<span class="sub">购买武器、火种、明油、灯油</span></button>
      ${isLast
        ? `<button class="btn" data-act="victory">渡过灯河<span class="sub">V1 终章</span></button>`
        : `<button class="btn" data-act="next">渡过灯河　前往下一关<span class="sub">灯河过场</span></button>`}
      <button class="btn" data-act="resume">返回战场（继续探索本关）</button>
    </div>
  </div>`;
}

export function upgradeScreen(world: World) {
  const prog = world.prog;
  const cards = UPGRADES.map((u) => {
    const lv = prog.up[u.id];
    const maxed = lv >= u.max;
    const cost = upgradeCost(u, lv);
    const canPay = prog.wicks >= cost;
    return `
      <div class="card">
        <div class="t">${u.name}　<span style="font-size:12px;color:#9a9384">Lv.${lv}/${u.max}</span></div>
        <div class="d">${u.desc}</div>
        <div class="p">花费 <b>${maxed ? '—' : cost}</b> 灯芯</div>
        <button class="btn ${maxed || !canPay ? 'disabled' : ''}" data-act="up:${u.id}" style="width:100%;margin-top:8px">
          ${maxed ? '已满级' : canPay ? '升级' : '灯芯不足'}
        </button>
      </div>`;
  }).join('');
  return `
  <div class="screen">
    <h2>灯芯升级</h2>
    <p class="quote">灯芯点亮灯塔，也让灯骑士更强。当前灯芯：<b>${prog.wicks}</b></p>
    <div class="grid3">${cards}</div>
    <div class="menu menubar"><button class="btn primary" data-act="back">返回</button></div>
  </div>`;
}

export function shopScreen(world: World) {
  const prog = world.prog;
  const weapons = WEAPONS.map((w) => {
    const owned = prog.weapons.includes(w.id);
    const equipped = prog.weapon === w.id;
    return `
      <div class="card ${owned ? 'owned' : ''}">
        <div class="t">${w.name}${equipped ? '　〔已装备〕' : ''}</div>
        <div class="d">${w.desc}<br>伤害 ${w.dmg}　范围 ${Math.round(w.range)}　技能 ${w.skills.length} 个：${w.skills.map((s) => `${s.name}(${s.cost})`).join('、')}</div>
        <div class="p">${owned ? '已拥有' : `价格 <b>${w.price}</b> 灯火`}</div>
        <button class="btn ${equipped ? 'disabled' : ''}" data-act="${owned ? `equip:${w.id}` : `buyw:${w.id}`}" style="width:100%;margin-top:8px">
          ${equipped ? '当前武器' : owned ? '装备' : (prog.coins >= w.price ? '购买' : '灯火不足')}
        </button>
      </div>`;
  }).join('');

  const items = SHOP_ITEMS.map((it) => {
    const can = prog.coins >= it.price;
    const extra = it.id === 'oil' ? `（持有 ${prog.oil}）` : it.id === 'ember' ? `（已购 ${prog.shop.ember} 次）` : `（已购 ${prog.shop.brightoil} 次）`;
    return `
      <div class="card">
        <div class="t">${it.name}</div>
        <div class="d">${it.desc}${extra}</div>
        <div class="p">价格 <b>${it.price}</b> 灯火</div>
        <button class="btn ${can ? '' : 'disabled'}" data-act="buyi:${it.id}" style="width:100%;margin-top:8px">${can ? '购买' : '灯火不足'}</button>
      </div>`;
  }).join('');

  return `
  <div class="screen">
    <h2>掌灯人</h2>
    <p class="quote">"尽情燃烧吧，你得为这个世界带去更多光亮！"</p>
    <p>持有灯火：<b>${prog.coins}</b></p>
    <h3>武器（每把武器的技能数与连击门槛都不同）</h3>
    <div class="grid3">${weapons}</div>
    <h3>补给</h3>
    <div class="grid3">${items}</div>
    <div class="menu menubar">
      <button class="btn" data-act="save">存档</button>
      <button class="btn primary" data-act="back">返回</button>
    </div>
  </div>`;
}

export function victoryScreen(world: World, elapsed: number) {
  const p = world.prog;
  return `
  <div class="screen">
    <h1>灯河<small>LIGHTKNIGHT · V1 完</small></h1>
    <p class="lore">灯骑士啊，你是不幸的，可你亦是人们的希望，\n去吧，渡过灯河，去往更暗处带去光明吧。</p>
    <p>影子碎了。对岸的灯一盏接一盏亮起，而更深处，灯神与灯魔仍旧沉睡在黑暗里。
       盲女燃成的灯芯贴在你胸口，很轻，也很烫。V1 的旅程到此为止——V2 会有更长的河。</p>
    <h3>旅途统计</h3>
    <p>累计击杀 <b>${p.kills}</b>　累计死亡 <b>${p.deaths}</b>　最高连击 <b>${p.maxCombo}</b><br>
       灯火 <b>${p.coins}</b>　灯芯 <b>${p.wicks}</b>　灯芯升级 <b>燃${p.up.hp} / 明${p.up.light} / 锋${p.up.edge}</b><br>
       总耗时 <b>${Math.floor(elapsed / 60)} 分 ${Math.floor(elapsed % 60)} 秒</b></p>
    <div class="menu">
      <button class="btn primary" data-act="totitle">回到标题</button>
      <button class="btn" data-act="resume">留在灯河渡口继续探索<span class="sub">可以刷灯火与灯芯</span></button>
    </div>
  </div>`;
}
