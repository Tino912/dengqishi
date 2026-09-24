/* ============================================================
   main.ts — 入口与场景状态机
   标题 → 序章对白 → 关卡（战斗/对白）→ 死亡或清关 → 灯塔 → 灯河 → 下一关 → V1 终章
   ============================================================ */
import { Input } from './core/input';
import { Sound } from './core/audio';
import { clamp, dist } from './core/utils';
import { Renderer } from './game/render';
import { World, newProgress, Progress } from './game/world';
import { Save } from './game/save';
import {
  UI, titleScreen, helpScreen, aboutScreen, pauseScreen, deathScreen,
  lighthouseScreen, upgradeScreen, shopScreen, victoryScreen,
} from './game/ui';
import {
  DIALOGUES, UPGRADES, upgradeCost, SHOP_ITEMS, WEAPONS, WEAPON_MAP,
} from './game/content';
import { LEVELS } from './game/levels';

type MenuKind = 'title' | 'help' | 'about' | 'pause' | 'death' | 'lighthouse' | 'upgrade' | 'shop' | 'victory';
/** 菜单返回栈里的一帧：要么是某个菜单，要么是「回到战斗」 */
type MenuFrame = MenuKind | 'play';

const CUT_RIVER: { text: string; sub?: string }[] = [
  { text: '灯火顺流而下，<br>一盏接着一盏，在你脚边熄灭。', sub: 'LIGHTRIVER' },
  { text: '灯骑士啊，你是不幸的，<br>可你亦是人们的希望——<br>去吧，渡过灯河，<br>去往更暗处带去光明吧。', sub: '渡过灯河' },
];

class Game {
  renderer: Renderer;
  ui = new UI();
  prog: Progress;
  world: World | null = null;
  mode: 'title' | 'play' | 'dialogue' | 'cutscene' | 'menu' = 'title';
  menuKind: MenuKind = 'title';
  private menuStack: MenuFrame[] = [];
  private pending: { t: number; act: () => void } | null = null;
  private deathDelay = -1;
  private cut: { list: { text: string; sub?: string }[]; i: number; t: number; onEnd: () => void } | null = null;
  private elapsed = 0;
  private lastTime = 0;
  private bgWorld: World | null = null;
  /** 调试入口：进入关卡即刷出全部波次（?spawn=1） */
  private devSpawnAll = false;

  constructor() {
    const canvas = document.getElementById('game') as HTMLCanvasElement;
    this.renderer = new Renderer(canvas);
    Input.init(canvas);
    this.prog = Save.load() ?? newProgress();

    window.addEventListener('resize', () => {
      this.renderer.resize();
      if (this.world) { this.world.view.w = this.renderer.W; this.world.view.h = this.renderer.H; }
    });

    // 任意手势后启用音频
    const kick = () => { Sound.ensure(); };
    window.addEventListener('pointerdown', kick, { once: false });
    window.addEventListener('keydown', kick, { once: false });

    // 菜单点击（事件委托）
    this.ui.overlay.addEventListener('click', (e) => {
      const el = (e.target as HTMLElement).closest('[data-act]') as HTMLElement | null;
      if (!el) return;
      this.handleAction(el.dataset.act!);
    });

    this.toTitle();

    // 调试 / 测试入口（便于快速跳到某一关验证）：
    //   ?level=0..2   直接进入该关卡
    //   &skipdlg=1    跳过开场对白
    //   &spawn=1      立刻刷出全部波次与 Boss（压测与截图用）
    const q = new URLSearchParams(location.search);
    const devLevel = q.get('level');
    if (devLevel !== null && devLevel !== '') {
      this.devSpawnAll = q.get('spawn') === '1';
      this.startLevel(clamp(parseInt(devLevel, 10) || 0, 0, LEVELS.length - 1), q.get('skipdlg') !== '1');
    }

    requestAnimationFrame((t) => this.frame(t));
  }

  /* ---------------------------- 场景切换 ---------------------------- */

  toTitle() {
    this.world = null;
    this.mode = 'title';
    this.menuKind = 'title';
    this.menuStack = [];
    this.pending = null;
    this.deathDelay = -1;
    this.cut = null;
    this.ui.hudVisible(false);
    this.ui.hideCut();
    // 回到标题必须撤掉过场黑幕，否则整个标题界面被 #fade 盖成纯黑
    this.ui.fade(false);
    Sound.stopMusic();
    this.showMenu('title');
  }

  /** 从菜单/对白回到战斗：给一小段无敌，避免"刚关掉面板就被贴脸打死" */
  private resumePlay(grace = 1.1) {
    this.mode = 'play';
    this.ui.hudVisible(true);
    const p = this.world?.player;
    if (p && !p.dead) p.invuln = Math.max(p.invuln, grace);
  }

  private showMenu(kind: MenuKind, push = false) {
    // 记录返回目标：战斗中被打开的菜单要能回到战斗，而不是落到陈旧的 menuKind
    if (push) this.menuStack.push(this.mode === 'play' ? 'play' : this.menuKind);
    this.menuKind = kind;
    this.mode = 'menu';
    this.ui.resetFocus();
    const w = this.world;
    switch (kind) {
      case 'title': this.ui.screen(titleScreen(this.prog, Save.has())); break;
      case 'help': this.ui.screen(helpScreen()); break;
      case 'about': this.ui.screen(aboutScreen()); break;
      case 'pause': if (w) this.ui.screen(pauseScreen(w)); break;
      case 'death': if (w) this.ui.screen(deathScreen(w)); break;
      case 'lighthouse': if (w) this.ui.screen(lighthouseScreen(w, w.level.index >= LEVELS.length - 1)); break;
      case 'upgrade': if (w) this.ui.screen(upgradeScreen(w)); break;
      case 'shop': if (w) this.ui.screen(shopScreen(w)); break;
      case 'victory': if (w) this.ui.screen(victoryScreen(w, this.elapsed)); break;
    }
  }

  private closeMenu() {
    this.menuStack = [];
    this.ui.hideScreen();
    if (this.world) this.resumePlay();
    else this.showMenu('title');
  }

  private backMenu() {
    const prev = this.menuStack.pop();
    if (prev === 'play') { this.closeMenu(); return; }
    if (prev) { this.showMenu(prev); return; }
    if (this.menuKind === 'title' || this.menuKind === 'death' || this.menuKind === 'victory') return;
    this.closeMenu();
  }

  /* ---------------------------- 关卡 ---------------------------- */

  startLevel(index: number, withIntro = true) {
    const i = clamp(index, 0, LEVELS.length - 1);
    this.prog.level = i;
    Save.write(this.prog);
    this.menuStack = [];
    this.ui.hideScreen();
    this.ui.fade(true);
    this.pending = {
      t: 0.62,
      act: () => {
        this.world = new World(i, this.prog, { spawnAll: this.devSpawnAll });
        this.world.view.w = this.renderer.W;
        this.world.view.h = this.renderer.H;
        this.mode = 'play';
        this.deathDelay = -1;
        this.ui.hudVisible(true);
        this.ui.fade(false);
        Sound.startMusic(i);
        if (withIntro) {
          const key = i === 0 ? 'l1_start' : i === 1 ? 'l2_start' : 'l3_start';
          this.playDialogue(key);
        }
      },
    };
  }

  private respawn() {
    if (!this.world) return;
    const i = this.world.level.index;
    this.prog.coins = Math.floor(this.prog.coins * 0.75);
    Save.write(this.prog);
    this.menuStack = [];
    this.ui.hideScreen();
    this.ui.fade(true);
    this.pending = {
      t: 0.6,
      act: () => {
        this.world = new World(i, this.prog);
        this.world.view.w = this.renderer.W;
        this.world.view.h = this.renderer.H;
        this.mode = 'play';
        this.deathDelay = -1;
        this.ui.hudVisible(true);
        this.ui.fade(false);
        Sound.startMusic(i);
        this.ui.toast('你被拖回了上一座灯塔——' + LEVELS[i].name);
      },
    };
  }

  private playDialogue(key: string, onEnd?: () => void) {
    const lines = DIALOGUES[key];
    if (!lines) { if (onEnd) onEnd(); return; }
    this.mode = 'dialogue';
    this.ui.hudVisible(true);
    this.ui.showDialogue(lines, () => {
      if (onEnd) onEnd();
      else if (this.world) this.resumePlay(1.4);
      else this.showMenu('title');
    });
  }

  private startCutscene(list: { text: string; sub?: string }[], onEnd: () => void) {
    this.mode = 'cutscene';
    this.cut = { list, i: 0, t: 0, onEnd };
    this.ui.hudVisible(false);
    this.ui.cut(list[0].text, list[0].sub);
    Sound.sfx('uiBig');
  }

  /* ---------------------------- 动作分发 ---------------------------- */

  handleAction(act: string) {
    Sound.ensure();
    const w = this.world;
    const sfx = (n: Parameters<typeof Sound.sfx>[0] | 'ui' = 'ui') => Sound.sfx(n as any);

    if (act === 'new') {
      this.prog = newProgress();
      Save.clear();
      sfx('uiBig');
      this.ui.hideScreen();
      this.mode = 'dialogue';
      this.ui.hudVisible(false);
      this.ui.showDialogue(DIALOGUES['intro'], () => this.startLevel(0, true));
      return;
    }
    if (act === 'continue') { sfx('uiBig'); this.startLevel(this.prog.level, false); return; }
    if (act === 'help') { sfx(); this.showMenu('help', true); return; }
    if (act === 'about') { sfx(); this.showMenu('about', true); return; }
    if (act === 'close' || act === 'back') { sfx(); this.backMenu(); return; }
    if (act === 'resume') {
      sfx();
      this.closeMenu();
      return;
    }
    if (act === 'totitle') {
      Save.write(this.prog);
      sfx('save');
      this.ui.toast('进度已保存。');
      this.pending = { t: 0.45, act: () => this.toTitle() };
      this.ui.fade(true);
      return;
    }
    if (act === 'save') {
      Save.write(this.prog);
      sfx('save');
      this.ui.toast('已在灯塔存档。');
      return;
    }
    if (act === 'upgrade') { sfx(); this.showMenu('upgrade', true); return; }
    if (act === 'shop') { sfx(); this.showMenu('shop', true); return; }

    if (act.startsWith('up:')) {
      const id = act.slice(3) as 'hp' | 'light' | 'edge';
      const def = UPGRADES.find((u) => u.id === id);
      if (!def || !w) return;
      const lv = this.prog.up[id];
      const cost = upgradeCost(def, lv);
      if (lv >= def.max || this.prog.wicks < cost) { sfx('ui'); return; }
      this.prog.wicks -= cost;
      this.prog.up[id] = lv + 1;
      if (id === 'hp') {
        w.player.maxHp = 100 + this.prog.up.hp * 25 + this.prog.shop.ember * 12;
        w.player.hp += 25;
      }
      Save.write(this.prog);
      sfx('levelup');
      this.ui.toast(`${def.name} 提升至 Lv.${lv + 1}`);
      this.showMenu('upgrade');
      // 升级界面是从灯塔进来的，返回时回灯塔（重复购买不要把栈撑大）
      if (this.menuStack[this.menuStack.length - 1] !== 'lighthouse') this.menuStack.push('lighthouse');
      return;
    }

    if (act.startsWith('buyw:')) {
      const id = act.slice(5);
      const def = WEAPON_MAP[id];
      if (!def || !w) return;
      if (!this.prog.weapons.includes(id)) {
        if (this.prog.coins < def.price) { sfx('ui'); this.ui.toast('灯火不足。'); return; }
        this.prog.coins -= def.price;
        this.prog.weapons.push(id);
        this.ui.toast(`购得武器：${def.name}`);
      }
      this.prog.weapon = id;
      w.player.weapon = def;
      Save.write(this.prog);
      sfx('levelup');
      this.ui.resetFocus();
      this.ui.screen(shopScreen(w));
      return;
    }

    if (act.startsWith('equip:')) {
      const id = act.slice(6);
      const def = WEAPON_MAP[id];
      if (!def || !w) return;
      this.prog.weapon = id;
      w.player.weapon = def;
      Save.write(this.prog);
      sfx();
      this.ui.resetFocus();
      this.ui.screen(shopScreen(w));
      return;
    }

    if (act.startsWith('buyi:')) {
      const id = act.slice(5);
      const it = SHOP_ITEMS.find((s) => s.id === id);
      if (!it || !w) return;
      if (this.prog.coins < it.price) { sfx('ui'); this.ui.toast('灯火不足。'); return; }
      this.prog.coins -= it.price;
      if (id === 'oil') { this.prog.oil++; this.ui.toast('购得灯油 ×1（按 R 使用）'); }
      if (id === 'ember') {
        this.prog.shop.ember++;
        w.player.maxHp = 100 + this.prog.up.hp * 25 + this.prog.shop.ember * 12;
        w.player.hp += 12;
        this.ui.toast('火种入怀，最大生命 +12');
      }
      if (id === 'brightoil') { this.prog.shop.brightoil++; this.ui.toast('明油入灯，基础光照 +10'); }
      Save.write(this.prog);
      sfx('coin');
      this.ui.resetFocus();
      this.ui.screen(shopScreen(w));
      return;
    }

    if (act === 'next') {
      sfx('uiBig');
      this.ui.hideScreen();
      this.ui.fade(true);
      const next = (this.world?.level.index ?? 0) + 1;
      this.pending = {
        t: 0.5,
        act: () => {
          this.ui.fade(false);
          this.startCutscene(CUT_RIVER, () => {
            this.ui.hideCut();
            this.ui.fade(true);
            this.pending = {
              t: 0.5,
              act: () => {
                this.ui.fade(false);
                this.startLevel(next, true);
              },
            };
          });
        },
      };
      return;
    }

    if (act === 'victory') {
      sfx('uiBig');
      this.ui.hideScreen();
      this.startCutscene(
        [{ text: '你踏上渡口的破船。<br>身后，灯堡的灯全亮了。', sub: 'V1 · 终章' }],
        () => {
          this.ui.hideCut();
          const w2 = this.world;
          if (w2) {
            this.prog.level = LEVELS.length - 1;
            Save.write(this.prog);
          }
          this.showMenu('victory');
          this.ui.hudVisible(false);
        },
      );
      return;
    }

    if (act === 'respawn') { sfx('uiBig'); this.respawn(); return; }
  }

  /* ---------------------------- 帧更新 ---------------------------- */

  private frame(now: number) {
    const dt = Math.min((now - this.lastTime) / 1000 || 0.016, 0.05);
    this.lastTime = now;
    try {
      this.update(dt);
    } catch (err) {
      console.error('[LightKnight] 更新出错：', err);
    }
    requestAnimationFrame((t) => this.frame(t));
  }

  private update(dt: number) {
    const world = this.world;

    // 延时动作（过场 / 淡入淡出后的关卡装载）
    if (this.pending) {
      this.pending.t -= dt;
      if (this.pending.t <= 0) {
        const act = this.pending.act;
        this.pending = null;
        act();
      }
    }

    // ---------- 输入分发 ----------
    if (this.mode === 'dialogue') {
      if (Input.justPressed('Space') || Input.justPressed('KeyE') || Input.justPressed('KeyF') || Input.justPressed('Enter')) {
        this.ui.advanceDialogue();
      }
      this.ui.updateDialogue(dt);
    } else if (this.mode === 'cutscene' && this.cut) {
      this.cut.t += dt;
      if (Input.justPressed('Space') || Input.justPressed('Enter') || this.cut.t > 3.8) {
        this.cut.i++;
        this.cut.t = 0;
        if (this.cut.i >= this.cut.list.length) {
          const cb = this.cut.onEnd;
          this.cut = null;
          this.ui.hideCut();
          cb();
        } else {
          this.ui.cut(this.cut.list[this.cut.i].text, this.cut.list[this.cut.i].sub);
          Sound.sfx('ui');
        }
      }
    } else if (this.mode === 'menu') {
      if (Input.justPressed('ArrowDown') || Input.justPressed('KeyS')) this.ui.moveFocus(1);
      if (Input.justPressed('ArrowUp') || Input.justPressed('KeyW')) this.ui.moveFocus(-1);
      if (Input.justPressed('Enter') || Input.justPressed('Space')) this.ui.clickFocused();
      if (Input.justPressed('Escape')) {
        if (this.menuKind === 'help' || this.menuKind === 'about' || this.menuKind === 'upgrade' || this.menuKind === 'shop') this.backMenu();
        else if (this.menuKind === 'pause' || this.menuKind === 'lighthouse') this.closeMenu();
      }
      this.ui.navMenu(dt);
    } else if (this.mode === 'play') {
      // 倒地后不再允许开暂停菜单，否则会盖掉死亡结算
      if (Input.justPressed('Escape') && world && !world.player.dead) {
        this.showMenu('pause');
        Sound.sfx('ui');
      }
    }

    // ---------- 世界推进 ----------
    if (this.mode === 'play' && world && !this.pending) {
      this.elapsed += dt;
      world.update(dt);

      for (const ev of world.drainEvents()) {
        switch (ev.type) {
          case 'toast': this.ui.toast(ev.text); break;
          case 'flash': world.flash = { color: ev.color, power: ev.power }; break;
          case 'bossStart': this.ui.toast('【' + ev.name + '】出现了'); break;
          case 'bossEnd': this.ui.bossbar.classList.add('hidden'); break;
          case 'dialogue': this.playDialogue(ev.key); break;
          case 'openShop': this.showMenu('shop', true); break;
          case 'openLighthouse': this.showMenu('lighthouse'); break;
          case 'victory': this.handleAction('victory'); break;
          case 'playerDead': this.deathDelay = 1.9; break;
          case 'levelCleared':
            Save.write(this.prog);
            this.ui.toast(`【${world.level.name}】已清关——灯塔亮起`);
            break;
        }
      }

      this.ui.syncHud(world, this.prog);
    }

    // 死亡结算（等倒地动画放完）
    // 注意：只在战斗状态下倒计时。否则死亡瞬间若停在对白/菜单里，
    // 倒计时会在看不到的地方走完，死亡界面永远不再出现 → 玩家卡死。
    if (this.deathDelay > 0 && this.mode === 'play') {
      this.deathDelay -= dt;
      if (this.deathDelay <= 0) {
        this.deathDelay = -1;
        this.showMenu('death');
      }
    }

    // ---------- 绘制 ----------
    const dw = this.mode === 'title' ? null : this.world;
    this.renderer.draw(dw ?? this.bgWorld, dt);

    // 背景音乐强度：连击 + 附近敌人数
    if (world && this.mode !== 'title') {
      let near = 0;
      for (const e of world.enemies) if (!e.dead && dist(e.x, e.y, world.player.x, world.player.y) < 420) near++;
      const heat = clamp(world.brightness01 * 0.7 + Math.min(near, 8) / 12, 0, 1);
      Sound.updateMusic(dt, heat);
    }

    Input.endFrame();
  }
}

// 兜底：iframe/无 DOM 环境下也不至于白屏报错
window.addEventListener('error', (e) => console.error('[LightKnight] 运行时错误：', e.message));

const game = new Game();
(window as any).__lightknight = game;
export default game;
