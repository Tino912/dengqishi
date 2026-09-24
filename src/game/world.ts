/* ============================================================
   world.ts — 玩法核心
   这里是 README 里那些机制的落地处：
   · 地图黑暗，只有灯骑士周围些许亮
   · 连击提高亮度，随时间变暗
   · 每把武器自带技能，技能需要连击数解锁（使用即消耗连击）
   · 灯芯升级血量与亮度
   · 一关打完灯塔才亮；死了回到上一灯塔
   ============================================================ */
import {
  TAU, YSQUASH, clamp, damp, rand, randInt, pick, chance, dist, dist2, angleTo,
  angleDiff, mulberry32, circleRect, pushOutRect, screenToWorldY,
} from '../core/utils';
import { Input } from '../core/input';
import { Sound } from '../core/audio';
import {
  WEAPON_MAP, ENEMY_TYPES, eliteify, EnemyDef, WeaponDef, SkillDef,
} from './content';
import { LEVELS, LevelDef, Wall, PropKind, PropDef } from './levels';

/* ------------------------------ 存档进度 ------------------------------ */

export interface Progress {
  coins: number;
  wicks: number;
  up: { hp: number; light: number; edge: number };
  shop: { ember: number; brightoil: number };
  weapon: string;
  weapons: string[];
  level: number;
  lit: number[];
  cleared: number[];
  blindGirl: boolean;
  oil: number;           // 灯油存量（商店购买消耗品）
  kills: number;
  deaths: number;
  maxCombo: number;
}

export function newProgress(): Progress {
  return {
    coins: 0, wicks: 0,
    up: { hp: 0, light: 0, edge: 0 },
    shop: { ember: 0, brightoil: 0 },
    weapon: 'blade', weapons: ['blade'],
    level: 0, lit: [], cleared: [], blindGirl: false,
    oil: 0, kills: 0, deaths: 0, maxCombo: 0,
  };
}

/* ------------------------------ 实体 ------------------------------ */

export interface Prop {
  kind: PropKind;
  x: number; y: number; r: number; h: number;
  seed: number;
  solid: boolean;
  lit?: boolean;
  litT?: number;
  pulse?: number;
}

export class Enemy {
  def: EnemyDef;
  elite = false;
  id: number;
  x: number; y: number; z = 0;
  vx = 0; vy = 0;
  hp: number; maxHp: number;
  r: number; h: number;
  facing = 1;
  state: 'spawn' | 'idle' | 'chase' | 'windup' | 'attack' | 'hurt' | 'dead' = 'spawn';
  t = 0;
  atkCd = 0;
  hitFlash = 0;
  stun = 0;
  wob = rand(0, TAU);
  dead = false;
  deathT = 0;
  spawnT = 0.45;
  /** boss 专用 */
  boss: {
    action: string; timer: number; cool: number; phase: number;
    tx: number; ty: number; dashT: number; sweepA: number; drainT: number;
  } | null = null;

  constructor(def: EnemyDef, x: number, y: number, id: number) {
    this.def = def; this.x = x; this.y = y; this.id = id;
    this.maxHp = def.hp; this.hp = def.hp;
    this.r = def.r; this.h = def.h;
    if (def.behavior === 'boss') {
      this.boss = { action: '', timer: 0, cool: 1.2, phase: 1, tx: 0, ty: 0, dashT: 0, sweepA: 0, drainT: 0 };
    }
  }
}

export interface Drop {
  x: number; y: number; z: number;
  vx: number; vy: number; vz: number;
  kind: 'coin' | 'wick' | 'oil';
  value: number;
  life: number; t: number;
  taken: boolean;
}

export interface Effect {
  id: number;
  kind: 'ring' | 'beam' | 'pillar' | 'slash' | 'sweep' | 'burst';
  x: number; y: number; z: number;
  angle: number;
  r0: number; r1: number;
  len: number; w: number;
  life: number; maxLife: number;
  dmg: number; knock: number; stun: number;
  color: string;
  hit: Set<number>;
  own: 'player' | 'enemy';
  delay: number;
}

export interface Particle {
  x: number; y: number; z: number;
  vx: number; vy: number; vz: number;
  life: number; maxLife: number; size: number;
  color: string; glow: boolean; drag: number; grav: number;
  kind: 'spark' | 'smoke' | 'ember' | 'ring';
}

export interface FloatText {
  x: number; y: number; z: number;
  vy: number;
  text: string; color: string; size: number;
  life: number; maxLife: number;
}

export interface Proj {
  x: number; y: number; z: number;
  vx: number; vy: number;
  r: number; dmg: number;
  life: number;
  color: string;
  spin: number;
}

export type WorldEvent =
  | { type: 'dialogue'; key: string }
  | { type: 'toast'; text: string }
  | { type: 'bossStart'; name: string }
  | { type: 'bossEnd' }
  | { type: 'levelCleared' }
  | { type: 'playerDead' }
  | { type: 'openShop' }
  | { type: 'openGoal' }
  | { type: 'openLighthouse' }
  | { type: 'victory' }
  | { type: 'flash'; color: string; power: number };

const HITSTOP_HIT = 0.045;
const HITSTOP_CRIT = 0.075;

export class World {
  level: LevelDef;
  prog: Progress;
  view = { w: 1280, h: 720 };

  walls: Wall[] = [];
  props: Prop[] = [];
  enemies: Enemy[] = [];
  drops: Drop[] = [];
  effects: Effect[] = [];
  particles: Particle[] = [];
  texts: FloatText[] = [];
  projs: Proj[] = [];

  player = {
    x: 0, y: 0, z: 0, vx: 0, vy: 0,
    r: 17, h: 44,
    hp: 100, maxHp: 100,
    facing: 0,
    attackT: 0, attackCd: 0, attackAlt: false,
    dashT: 0, dashCd: 0, dashDx: 0, dashDy: 0,
    invuln: 0, hurtFlash: 0,
    combo: 0, comboTimer: 0, comboPeak: 0,
    glow: 0, walkT: 0,
    weapon: WEAPON_MAP['blade'],
    skillCd: {} as Record<string, number>,
    flurry: 0, flurryT: 0,
    revives: 0,
    dead: false, deathT: 0,
  };

  cam = { x: 0, y: 0 };
  shake = 0;
  shakeT = 0;
  hitstop = 0;
  time = 0;
  flash = { color: '#fff', power: 0 };
  ambient = 0.9;
  cleared = false;
  bossEnemy: Enemy | null = null;
  bossSpawned = false;
  bossDead = false;
  bossAnnounced = false;

  waves = [] as { def: (typeof LEVELS)[number]['waves'][number]; spawned: boolean; cleared: boolean; members: number[] }[];
  braziers: Prop[] = [];
  braziersLit = 0;
  goalProp: Prop;
  merchantProp: Prop | null = null;
  girl: { x: number; y: number; active: boolean; t: number; gone: boolean } | null = null;

  respawnTimer = 0;
  /** 调试用：进入关卡时立刻刷出所有波次与 Boss */
  devSpawnAll = false;
  private devSpawned = false;
  prompt: string | null = null;
  objective = '';
  events: WorldEvent[] = [];
  private nextId = 1;
  private rng: () => number;
  private flashT = 0;
  highlightBrazier: Prop | null = null;
  girlSavedThisLevel = false;

  constructor(levelIndex: number, prog: Progress, opts: { spawnAll?: boolean } = {}) {
    this.level = LEVELS[clamp(levelIndex, 0, LEVELS.length - 1)];
    this.prog = prog;
    this.devSpawnAll = !!opts.spawnAll;
    this.rng = mulberry32(this.level.seed);
    this.walls = this.level.walls.map((w) => ({ ...w }));

    // 玩家
    this.player.x = this.level.start.x;
    this.player.y = this.level.start.y;
    this.player.maxHp = 100 + prog.up.hp * 25 + prog.shop.ember * 12;
    this.player.hp = this.player.maxHp;
    this.player.weapon = WEAPON_MAP[prog.weapon] ?? WEAPON_MAP['blade'];
    this.player.revives = prog.blindGirl ? 1 : 0;

    // 道具
    this.props = [];
    for (const p of this.level.props) this.props.push(this.makeProp(p));

    // 装饰（按固定种子生成，保证同一关每次一样）
    this.decorate();

    this.braziers = this.props.filter((p) => p.kind === 'brazier');
    this.merchantProp = this.props.find((p) => p.kind === 'merchant') ?? null;
    this.goalProp = this.props.find(
      (p) => p.kind === (this.level.goal.kind === 'dock' ? 'dock' : 'lighthouse'),
    )!;
    if (this.goalProp) {
      this.goalProp.x = this.level.goal.x;
      this.goalProp.y = this.level.goal.y;
      this.goalProp.lit = this.prog.lit.includes(this.level.index);
      this.goalProp.litT = this.goalProp.lit ? 1 : 0;
    }

    if (this.level.blindGirl) {
      this.girl = { x: this.level.blindGirl.x, y: this.level.blindGirl.y, active: true, t: 0, gone: false };
    }

    this.waves = this.level.waves.map((w) => ({ def: w, spawned: false, cleared: false, members: [] }));

    this.ambient = this.level.ambient;
    this.cam.x = this.player.x;
    this.cam.y = this.player.y;

    this.updateObjective();
  }

  private makeProp(p: PropDef): Prop {
    const seed = (p.seed ?? 0) || Math.floor(this.rng() * 100000);
    const table: Record<PropKind, { r: number; h: number; solid: boolean }> = {
      lighthouse: { r: 30, h: 200, solid: true },
      brazier: { r: 20, h: 42, solid: true },
      dock: { r: 34, h: 26, solid: false },
      merchant: { r: 17, h: 48, solid: false },
      pillar: { r: 17, h: 66, solid: true },
      lantern: { r: 13, h: 40, solid: false },
      tree: { r: 15, h: 54, solid: false },
      rubble: { r: 16, h: 14, solid: false },
      statue: { r: 19, h: 62, solid: true },
    };
    const t = table[p.kind];
    return { kind: p.kind, x: p.x, y: p.y, r: t.r, h: t.h, seed, solid: t.solid, lit: false, litT: 0, pulse: rand(0, TAU) };
  }

  private decorate() {
    const kinds: PropKind[] = ['pillar', 'lantern', 'tree', 'rubble', 'rubble'];
    let placed = 0, guard = 0;
    while (placed < this.level.decorCount && guard++ < 1200) {
      const x = rand(90, this.level.w - 90);
      const y = rand(90, this.level.h - 90);
      if (this.blocked(x, y, 40)) continue;
      if (dist(x, y, this.level.start.x, this.level.start.y) < 150) continue;
      if (dist(x, y, this.level.goal.x, this.level.goal.y) < 190) continue;
      let near = false;
      for (const p of this.props) if (dist(x, y, p.x, p.y) < 120) { near = true; break; }
      if (near) continue;
      const kind = pick(kinds);
      this.props.push(this.makeProp({ kind, x, y }));
      placed++;
    }
  }

  /* ------------------------------ 碰撞 ------------------------------ */

  blocked(x: number, y: number, r: number) {
    for (const w of this.walls) if (circleRect(x, y, r, w.x, w.y, w.w, w.d)) return true;
    return false;
  }

  private collideWall(o: { x: number; y: number }, r: number) {
    for (const w of this.walls) {
      const [nx, ny] = pushOutRect(o.x, o.y, r, w.x, w.y, w.w, w.d);
      o.x = nx; o.y = ny;
    }
    for (const p of this.props) {
      if (!p.solid) continue;
      const [nx, ny] = pushOutRect(o.x, o.y, r + p.r * 0.6, p.x, p.y, 1, 1);
      // pushOutRect 以 1x1 矩形代表圆柱底座
      o.x = nx; o.y = ny;
    }
    o.x = clamp(o.x, r + 6, this.level.w - r - 6);
    o.y = clamp(o.y, r + 6, this.level.h - r - 6);
  }

  /* ------------------------------ 主更新 ------------------------------ */

  update(dtRaw: number) {
    // 命中定格（打击感）
    if (this.hitstop > 0) {
      this.hitstop -= dtRaw;
      dtRaw *= 0.1;
    }
    const dt = Math.min(dtRaw, 1 / 30);
    this.time += dt;

    this.updateAim();
    this.updatePlayer(dt);
    this.updateEnemies(dt);
    this.updateEffects(dt);
    this.updateProjs(dt);
    this.updateDrops(dt);
    this.updateParticles(dt);
    this.updateWaves(dt);
    this.updateInteraction(dt);
    this.updateObjective();

    // 相机
    const tx = this.player.x, ty = this.player.y;
    this.cam.x = damp(this.cam.x, tx, 7, dt);
    this.cam.y = damp(this.cam.y, ty, 7, dt);
    const halfW = this.view.w / 2, halfH = this.view.h / 2 / YSQUASH;
    if (this.level.w > this.view.w) this.cam.x = clamp(this.cam.x, halfW, this.level.w - halfW);
    else this.cam.x = this.level.w / 2;
    if (this.level.h > halfH * 2) this.cam.y = clamp(this.cam.y, halfH, this.level.h - halfH);
    else this.cam.y = this.level.h / 2;

    // 震屏与闪光衰减
    this.shake = damp(this.shake, 0, 6, dt);
    if (this.shake < 0.2) this.shake = 0;
    this.flash.power = damp(this.flash.power, 0, 5, dt);

    // 通关后地图变亮
    if (this.cleared) {
      const lit = this.prog.lit.includes(this.level.index) || this.goalProp?.lit;
      this.ambient = damp(this.ambient, lit ? this.level.clearedAmbient : this.level.ambient * 0.86, 1.1, dt);
    } else {
      this.ambient = damp(this.ambient, this.level.ambient, 1.5, dt);
    }

    // 盲女跟随
    if (this.girl && this.girl.active && !this.girl.gone) {
      this.girl.t += dt;
      const tx2 = this.player.x - Math.cos(this.player.facing) * 52;
      const ty2 = this.player.y - Math.sin(this.player.facing) * 52 - 6;
      this.girl.x = damp(this.girl.x, tx2, 4.2, dt);
      this.girl.y = damp(this.girl.y, ty2, 4.2, dt);
      if (chance(dt * 8)) {
        this.addParticle(this.girl.x + rand(-8, 8), this.girl.y + rand(-6, 6), rand(16, 40), {
          vx: rand(-6, 6), vy: rand(-6, 6), vz: rand(12, 26), life: rand(0.7, 1.5),
          size: rand(1.2, 2.4), color: '#fff6dd', glow: true, drag: 1.4, grav: -6,
        });
      }
    }

    if (this.player.glow > 0) this.player.glow = Math.max(0, this.player.glow - dt * 1.6);
  }

  private updateAim() {
    const { mouse } = Input;
    const wx = mouse.x - this.view.w / 2 + this.cam.x;
    const wy = screenToWorldY(mouse.y, this.cam, this.view.h);
    const p = this.player;
    // 鼠标在画布内才用鼠标瞄准，否则保持朝向
    if (mouse.inside) {
      const a = Math.atan2(wy - p.y, wx - p.x);
      p.facing = a;
    } else {
      const [ax, ay] = Input.axis();
      if (ax || ay) p.facing = Math.atan2(ay, ax);
    }
  }

  /* ------------------------------ 玩家 ------------------------------ */

  private playerLightRadius() {
    const p = this.player;
    let r = 150 + this.prog.up.light * 24 + this.prog.shop.brightoil * 10;
    r += Math.min(p.combo, 40) * 7;
    r += p.glow * 46;
    if (this.girl && !this.girl.gone && dist(p.x, p.y, this.girl.x, this.girl.y) < 210) r += 70;
    return r;
  }
  get lightRadius() { return this.playerLightRadius(); }
  get brightness01() {
    const p = this.player;
    return clamp((Math.min(p.combo, 40) * 7 + p.glow * 40) / 280, 0, 1);
  }
  get damageMul() {
    const p = this.player;
    return (1 + Math.min(p.combo, 60) * 0.012) * (1 + this.prog.up.edge * 0.12);
  }

  private updatePlayer(dt: number) {
    const p = this.player;
    if (p.dead) { p.deathT += dt; return; }

    // 连击衰减：2.6 秒不命中就慢慢暗下来
    if (p.combo > 0) {
      p.comboTimer -= dt;
      if (p.comboTimer <= 0) {
        p.combo = Math.max(0, p.combo - dt * 14);
        if (p.combo === 0) p.comboPeak = 0;
      }
    }

    // 移动
    let [ax, ay] = Input.axis();
    const speed = 218;
    if (p.dashT > 0) {
      p.dashT -= dt;
      ax = p.dashDx; ay = p.dashDy;
      p.vx = ax * 640; p.vy = ay * 640;
      if (chance(dt * 40)) {
        this.addParticle(p.x, p.y, rand(6, 30), {
          vx: rand(-30, 30), vy: rand(-30, 30), vz: rand(0, 30), life: 0.4,
          size: rand(2, 4.5), color: '#ffd79a', glow: true, drag: 3, grav: -10,
        });
      }
      p.invuln = Math.max(p.invuln, 0.05);
    } else {
      p.vx = damp(p.vx, ax * speed, 22, dt);
      p.vy = damp(p.vy, ay * speed, 22, dt);
    }
    if (p.dashCd > 0) p.dashCd -= dt;
    if (Input.justPressed('ShiftLeft') || Input.justPressed('ShiftRight') || Input.justPressed('Space') === false && Input.justPressed('KeyL')) { /* noop */ }
    if ((Input.justPressed('ShiftLeft') || Input.justPressed('ShiftRight')) && p.dashCd <= 0 && p.dashT <= 0) {
      const [dx, dy] = ax || ay ? [ax, ay] : [Math.cos(p.facing), Math.sin(p.facing)];
      p.dashDx = dx; p.dashDy = dy; p.dashT = 0.17; p.dashCd = 1.0;
      Sound.sfx('dash');
      for (let i = 0; i < 12; i++) {
        this.addParticle(p.x, p.y, rand(4, 34), {
          vx: -dx * rand(40, 140) + rand(-40, 40), vy: -dy * rand(40, 140) + rand(-40, 40),
          vz: rand(0, 40), life: rand(0.3, 0.6), size: rand(1.6, 3.6),
          color: '#ffe0a8', glow: true, drag: 2.5, grav: -14,
        });
      }
    }

    const next = { x: p.x + p.vx * dt, y: p.y + p.vy * dt };
    this.collideWall(next, p.r);
    p.x = next.x; p.y = next.y;
    if (Math.abs(p.vx) + Math.abs(p.vy) > 30) p.walkT += dt * 11;

    // 计时器
    if (p.attackCd > 0) p.attackCd -= dt;
    if (p.attackT > 0) p.attackT -= dt;
    if (p.invuln > 0) p.invuln -= dt;
    if (p.hurtFlash > 0) p.hurtFlash -= dt;
    for (const k in p.skillCd) if (p.skillCd[k] > 0) p.skillCd[k] -= dt;

    // 连灯刺：连刺序列
    if (p.flurry > 0) {
      p.flurryT -= dt;
      if (p.flurryT <= 0) {
        p.flurry--;
        p.flurryT = 0.11;
        this.playerSwing(0.72, 1.5, 0.9);
        Sound.sfx('slash');
      }
    }

    // 攻击
    if ((Input.justPressed('KeyJ') || Input.mouse.justDown || Input.justPressed('KeyK')) && p.attackCd <= 0 && p.flurry <= 0) {
      p.attackCd = p.weapon.cd;
      p.attackT = 0.2;
      p.attackAlt = !p.attackAlt;
      this.playerSwing(p.weapon.arc, 1, 1);
      Sound.sfx('slash');
    }

    // 技能 1/2/3
    for (let i = 0; i < 3; i++) {
      if (Input.justPressed('Digit' + (i + 1))) this.useSkill(i);
    }

    // 交互
    if (Input.justPressed('KeyE') || Input.justPressed('KeyF')) this.interact();
  }

  /** 玩家一次挥击判定 */
  private playerSwing(arcMul: number, dmgMul: number, rangeMul: number) {
    const p = this.player;
    const w = p.weapon;
    const range = w.range * rangeMul;
    const arc = w.arc * arcMul;
    let hits = 0;
    for (const e of this.enemies) {
      if (e.dead) continue;
      const d = dist(p.x, p.y, e.x, e.y);
      if (d > range + e.r) continue;
      const a = angleTo(p.x, p.y, e.x, e.y);
      if (Math.abs(angleDiff(p.facing, a)) > arc / 2 && d > 40) continue;
      this.damageEnemy(e, w.dmg * dmgMul, a, w.knock);
      hits++;
    }
    // 挥击特效
    this.effects.push({
      id: this.nextId++, kind: 'slash', x: p.x, y: p.y, z: 24,
      angle: p.facing, r0: range * 0.35, r1: range, len: 0, w: arc,
      life: 0.17, maxLife: 0.17, dmg: 0, knock: 0, stun: 0,
      color: this.prog.blindGirl ? '#ffe9b0' : '#ffd070', hit: new Set(), own: 'player', delay: 0,
    });
    if (hits > 0) {
      this.shake = Math.min(this.shake + hits * 1.1, 9);
      this.player.glow = Math.min(1, this.player.glow + 0.22);
    }
    // 顺手点亮火盆
    this.tryLightBrazier(p.x, p.y, range + 26);
  }

  useSkill(index: number) {
    const p = this.player;
    const skills = p.weapon.skills;
    if (index >= skills.length) {
      this.events.push({ type: 'toast', text: '这把武器没有第 ' + (index + 1) + ' 个技能。' });
      return;
    }
    const sk: SkillDef = skills[index];
    if ((p.skillCd[sk.id] ?? 0) > 0) return;
    if (p.combo < sk.cost) {
      this.events.push({ type: 'toast', text: `【${sk.name}】需要 ${sk.cost} 连击（当前 ${Math.floor(p.combo)}）` });
      Sound.sfx('ui');
      return;
    }
    // 技能消耗连击——灯是有代价的
    p.combo -= sk.cost;
    p.skillCd[sk.id] = sk.cd;
    this.castSkill(sk.id);
    Sound.sfx('skill');
    this.shake = Math.min(this.shake + 5, 14);
    this.flash = { color: '#ffd9a0', power: 0.34 };
    this.player.glow = 1;
  }

  private castSkill(id: string) {
    const p = this.player;
    const w = p.weapon;
    const dm = this.damageMul;
    const push = (e: Partial<Effect>) => {
      this.effects.push({
        id: this.nextId++, kind: 'ring', x: p.x, y: p.y, z: 22, angle: p.facing,
        r0: 0, r1: 100, len: 0, w: 0, life: 0.4, maxLife: 0.4,
        dmg: 0, knock: 0, stun: 0, color: '#ffd070', hit: new Set(), own: 'player', delay: 0,
        ...e,
      } as Effect);
    };

    switch (id) {
      case 'blade_whirl':
        push({ kind: 'ring', r0: 26, r1: 132, life: 0.32, dmg: w.dmg * 1.5 * dm, knock: 300, color: '#ffdc96' });
        for (let i = 0; i < 26; i++) {
          const a = rand(0, TAU);
          this.addParticle(p.x, p.y, rand(10, 40), {
            vx: Math.cos(a) * rand(160, 420), vy: Math.sin(a) * rand(160, 420), vz: rand(0, 60),
            life: rand(0.25, 0.5), size: rand(2, 4), color: '#ffe3a8', glow: true, drag: 3, grav: -20,
          });
        }
        break;

      case 'blade_burst':
        push({ kind: 'burst', r0: 40, r1: 320, life: 0.5, dmg: w.dmg * 2.1 * dm, knock: 900, color: '#fff2cc' });
        push({ kind: 'ring', r0: 40, r1: 340, life: 0.6, dmg: 0, knock: 0, color: '#ffd070' });
        this.shake = Math.min(this.shake + 10, 18);
        // 点亮附近火盆
        for (const b of this.braziers) {
          if (!b.lit && dist(p.x, p.y, b.x, b.y) < 300) this.lightBrazier(b);
        }
        break;

      case 'spear_lunge': {
        p.dashDx = Math.cos(p.facing); p.dashDy = Math.sin(p.facing);
        p.dashT = 0.26; p.dashCd = Math.max(p.dashCd, 0.3);
        p.invuln = 0.3;
        // 沿路径连续判定：用多个圆形效果铺一条线
        for (let i = 0; i < 5; i++) {
          const t = i / 4;
          push({
            kind: 'ring', x: p.x + Math.cos(p.facing) * (40 + t * 200), y: p.y + Math.sin(p.facing) * (40 + t * 200),
            r0: 10, r1: 52, life: 0.22, dmg: w.dmg * 0.55 * dm, knock: 260, color: '#ffe9b0',
          });
        }
        break;
      }

      case 'spear_flurry':
        p.flurry = 5; p.flurryT = 0.02;
        break;

      case 'spear_pierce':
        push({
          kind: 'beam', angle: p.facing, len: 940, w: 30, r0: 0, r1: 940,
          life: 0.42, dmg: w.dmg * 3.1 * dm, knock: 700, stun: 0.4, color: '#fff6dd',
        });
        this.shake = Math.min(this.shake + 9, 18);
        this.flash = { color: '#fff8e6', power: 0.5 };
        break;

      case 'hammer_quake':
        push({ kind: 'ring', r0: 30, r1: 262, life: 0.42, dmg: w.dmg * 2.2 * dm, knock: 760, stun: 1.1, color: '#ffc078' });
        push({ kind: 'ring', r0: 20, r1: 240, life: 0.55, dmg: 0, knock: 0, color: '#ffab5c' });
        this.shake = Math.min(this.shake + 14, 22);
        for (const b of this.braziers) if (!b.lit && dist(p.x, p.y, b.x, b.y) < 280) this.lightBrazier(b);
        break;

      case 'hammer_meteor': {
        // 目标点：瞄准方向 340 距离处
        const tx = p.x + Math.cos(p.facing) * 340;
        const ty = p.y + Math.sin(p.facing) * 340;
        push({
          kind: 'pillar', x: tx, y: ty, angle: 0, r0: 0, r1: 170, len: 0, w: 0,
          life: 0.85, dmg: w.dmg * 2.7 * dm, knock: 800, stun: 0.8,
          color: '#ffb765', delay: 0.34,
        });
        this.shake = Math.min(this.shake + 12, 20);
        break;
      }
    }
  }

  /* ------------------------------ 敌人 ------------------------------ */

  private spawnEnemy(typeId: string, x: number, y: number, elite = false): Enemy | null {
    let def = ENEMY_TYPES[typeId];
    if (!def) return null;
    const scale = this.level.enemyScale;
    def = {
      ...def,
      hp: Math.round(def.hp * scale),
      dmg: Math.round(def.dmg * (0.85 + scale * 0.2)),
    };
    if (elite) def = eliteify(def);
    const e = new Enemy(def, x, y, this.nextId++);
    e.elite = elite;
    if (def.behavior === 'boss') {
      e.maxHp = Math.round(def.hp);
      e.hp = e.maxHp;
    }
    this.enemies.push(e);
    return e;
  }

  private findSpawnPoint(cx: number, cy: number, radius: number, r: number): [number, number] {
    for (let i = 0; i < 40; i++) {
      const a = rand(0, TAU), d = rand(radius * 0.35, radius);
      const x = clamp(cx + Math.cos(a) * d, 70, this.level.w - 70);
      const y = clamp(cy + Math.sin(a) * d, 70, this.level.h - 70);
      if (this.blocked(x, y, r + 6)) continue;
      if (dist(x, y, this.player.x, this.player.y) < 250) continue;
      return [x, y];
    }
    return [cx, cy];
  }

  private updateWaves(dt: number) {
    this.respawnTimer -= dt;

    // 调试/压测模式：进入关卡即刷出全部波次
    if (this.devSpawnAll && !this.devSpawned) {
      this.devSpawned = true;
      for (const w of this.waves) {
        if (w.spawned) continue;
        w.spawned = true;
        for (const grp of w.def.enemies) {
          for (let i = 0; i < grp.count; i++) {
            const def = ENEMY_TYPES[grp.type];
            const [x, y] = this.findSpawnPoint(w.def.x, w.def.y, w.def.radius, def?.r ?? 18);
            const e = this.spawnEnemy(grp.type, x, y, !!grp.elite);
            if (e) { w.members.push(e.id); this.spawnFx(x, y, def?.glow ?? '#fff'); }
          }
        }
      }
    }

    // 波次：进入区域触发；本波自己刷出的敌人全部阵亡才算清空。
    // （不能用"区域内还有没有敌人"来判断：敌人追着玩家跑远后，会让别的波次永远清不掉）
    for (const w of this.waves) {
      if (!w.spawned) {
        const d = dist(this.player.x, this.player.y, w.def.x, w.def.y);
        if (d < w.def.radius + 90) {
          w.spawned = true;
          for (const grp of w.def.enemies) {
            for (let i = 0; i < grp.count; i++) {
              const def = ENEMY_TYPES[grp.type];
              const [x, y] = this.findSpawnPoint(w.def.x, w.def.y, w.def.radius, def?.r ?? 18);
              const e = this.spawnEnemy(grp.type, x, y, !!grp.elite);
              if (e) { w.members.push(e.id); this.spawnFx(x, y, def?.glow ?? '#fff'); }
            }
          }
          this.events.push({ type: 'toast', text: w.def.label });
          Sound.sfx('uiBig');
        }
      }
      if (w.spawned && !w.cleared) {
        const alive = this.enemies.some((e) => !e.dead && w.members.includes(e.id));
        if (!alive) {
          w.cleared = true;
          if (!this.cleared) this.events.push({ type: 'toast', text: `${w.def.label}　已清空` });
        }
      }
    }

    // Boss 触发：其它波次全清后进入区域
    if (!this.bossSpawned && !this.bossDead) {
      const allClear = this.waves.every((w) => w.cleared);
      const inBoss = dist(this.player.x, this.player.y, this.level.boss.x, this.level.boss.y) < this.level.boss.radius;
      if (this.devSpawnAll || inBoss || (allClear && dist(this.player.x, this.player.y, this.level.boss.x, this.level.boss.y) < this.level.boss.radius + 320)) {
        if (allClear || this.devSpawnAll) {
          this.bossSpawned = true;
          const [bx, by] = this.findSpawnPoint(this.level.boss.x, this.level.boss.y, 80, 40);
          const b = this.spawnEnemy(this.level.boss.type, bx, by, false)
            ?? this.spawnEnemy(this.level.boss.type, this.level.boss.x, this.level.boss.y, false)!;
          this.bossEnemy = b;
          this.bossAnnounced = true;
          this.events.push({ type: 'bossStart', name: this.level.boss.label });
          this.events.push({ type: 'dialogue', key: this.level.index === 1 ? 'l2_boss_pre' : this.level.index === 2 ? 'l3_boss_pre' : 'l1_boss_pre' });
          Sound.sfx('roar');
          this.shake = 16;
          this.flash = { color: '#ff8a5a', power: 0.42 };
        } else if (inBoss && !this.bossHinted) {
          this.bossHinted = true;
          this.events.push({ type: 'toast', text: '还有影子没清掉——先清空这片区域。' });
        }
      }
    }

    // 无芯之暗：火盆未点齐时，怪物不断再生
    if (this.level.respawnWhileDark && !this.cleared) {
      const need = this.level.braziersRequired ?? 0;
      if (this.braziersLit < need && this.respawnTimer <= 0) {
        this.respawnTimer = 5.5;
        const alive = this.enemies.filter((e) => !e.dead && e.def.behavior !== 'boss').length;
        if (alive < 10) {
          const centers = this.waves.map((w) => w.def);
          const pickW = pick(centers);
          for (let i = 0; i < 2; i++) {
            const [x, y] = this.findSpawnPoint(pickW.x, pickW.y, pickW.radius, 18);
            if (this.spawnEnemy('shade', x, y)) this.spawnFx(x, y, '#b7a8ff');
          }
          this.events.push({ type: 'toast', text: '黑暗里又爬出新的影子……（去点燃火盆）' });
        }
      }
    }
  }
  private bossHinted = false;

  /** Boss 是否被火盆护佑（减伤 + 回血） */
  get bossWarded() {
    const need = this.level.braziersRequired ?? 0;
    return need > 0 && this.braziersLit < need;
  }

  private updateEnemies(dt: number) {
    const p = this.player;
    for (const e of this.enemies) {
      if (e.dead) { e.deathT += dt; continue; }
      if (e.hitFlash > 0) e.hitFlash -= dt;
      // 火盆未点齐时，Boss 被"护佑"：除了高额减伤还会缓慢自愈
      if (this.bossWarded && e.def.behavior === 'boss') {
        e.hp = Math.min(e.maxHp, e.hp + e.maxHp * 0.006 * dt);
      }
      e.wob += dt * 3;
      e.t += dt;

      if (e.state === 'spawn') {
        e.spawnT -= dt;
        if (e.spawnT <= 0) e.state = 'idle';
        continue;
      }
      if (e.stun > 0) { e.stun -= dt; this.moveEntity(e, dt); continue; }
      if (e.atkCd > 0) e.atkCd -= dt;

      const d = dist(p.x, p.y, e.x, e.y);
      const def = e.def;
      const behavior = def.behavior;

      if (behavior === 'boss') this.bossAi(e, dt, d);
      else if (behavior === 'spitter') {
        // 远程：保持距离并吐灯蛭弹
        const a = angleTo(e.x, e.y, p.x, p.y);
        e.facing = Math.cos(a) > 0 ? 1 : -1;
        if (e.state === 'windup') {
          if (e.t > def.wind) {
            e.state = 'chase';
            e.atkCd = def.atkCd;
            this.projs.push({
              x: e.x, y: e.y, z: 22,
              vx: Math.cos(a) * 330, vy: Math.sin(a) * 330,
              r: 11, dmg: def.dmg, life: 2.6, color: def.glow, spin: rand(0, TAU),
            });
            Sound.sfx('hit');
          }
        } else if (d < def.aggro && e.atkCd <= 0 && d < def.atkRange && e.t > 0.4) {
          e.state = 'windup'; e.t = 0;
        } else if (d < def.aggro) {
          const want = d < 210 ? -1 : 1;
          e.vx = Math.cos(a) * def.speed * want;
          e.vy = Math.sin(a) * def.speed * want;
          // 侧移
          e.vx += Math.cos(a + Math.PI / 2) * def.speed * 0.5 * Math.sin(e.t * 1.6 + e.wob);
          e.vy += Math.sin(a + Math.PI / 2) * def.speed * 0.5 * Math.sin(e.t * 1.6 + e.wob);
        } else { e.vx = damp(e.vx, 0, 5, dt); e.vy = damp(e.vy, 0, 5, dt); }
      } else {
        // 近战：chase / guard
        const a = angleTo(e.x, e.y, p.x, p.y);
        e.facing = Math.cos(a) > 0 ? 1 : -1;
        if (e.state === 'windup') {
          if (e.t > def.wind) {
            e.state = 'attack'; e.t = 0;
            const lunge = behavior === 'guard' ? 240 : 150;
            e.vx = Math.cos(a) * lunge; e.vy = Math.sin(a) * lunge;
            // 命中判定
            if (dist(p.x, p.y, e.x, e.y) < def.atkRange + p.r + 14) {
              const a2 = angleTo(e.x, e.y, p.x, p.y);
              if (Math.abs(angleDiff(Math.atan2(e.vy, e.vx), a2)) < 1.5) this.hurtPlayer(def.dmg, a2);
            }
            e.atkCd = def.atkCd;
            // 敌方挥击特效
            this.effects.push({
              id: this.nextId++, kind: 'slash', x: e.x, y: e.y, z: 24, angle: a,
              r0: 12, r1: def.atkRange + 18, len: 0, w: 1.5, life: 0.18, maxLife: 0.18,
              dmg: 0, knock: 0, stun: 0, color: '#ff8f6a', hit: new Set(), own: 'enemy', delay: 0,
            });
          }
        } else if (e.state === 'attack') {
          if (e.t > 0.25) e.state = 'chase';
        } else if (d < def.aggro) {
          if (d < def.atkRange + p.r - 6 && e.atkCd <= 0 && e.t > 0.5) {
            e.state = 'windup'; e.t = 0;
          } else {
            const sp = def.speed * (behavior === 'guard' ? 1 : 1.15);
            e.vx = damp(e.vx, Math.cos(a) * sp, 6, dt);
            e.vy = damp(e.vy, Math.sin(a) * sp, 6, dt);
          }
        } else {
          e.vx = damp(e.vx, 0, 4, dt);
          e.vy = damp(e.vy, 0, 4, dt);
          if (chance(dt * 0.6)) {
            const a2 = rand(0, TAU);
            e.vx += Math.cos(a2) * 34; e.vy += Math.sin(a2) * 34;
          }
        }
      }

      // 分离，避免叠成一团
      for (const o of this.enemies) {
        if (o === e || o.dead) continue;
        const dd = dist(e.x, e.y, o.x, o.y);
        const min = e.r + o.r;
        if (dd < min && dd > 0.01) {
          const push = (min - dd) * 0.5;
          const ax2 = (e.x - o.x) / dd, ay2 = (e.y - o.y) / dd;
          e.vx += ax2 * push * 14; e.vy += ay2 * push * 14;
          o.vx -= ax2 * push * 10; o.vy -= ay2 * push * 10;
        }
      }

      this.moveEntity(e, dt);

      // 接触伤害（贴身擦到）
      if (e.def.behavior === 'boss' && d < e.r + p.r + 6) this.hurtPlayer(e.def.dmg * 0.35 * dt * 10, angleTo(e.x, e.y, p.x, p.y));
    }

    // 清理尸体
    if (this.enemies.length > 90) this.enemies = this.enemies.filter((e) => !e.dead || e.deathT < 3);
  }

  private moveEntity(e: Enemy, dt: number) {
    const nx = { x: e.x + e.vx * dt, y: e.y + e.vy * dt };
    const before = { x: nx.x, y: nx.y };
    this.collideWall(nx, e.r);
    // 撞墙则停下（Boss 冲撞撞墙会眩晕）
    if (Math.abs(nx.x - before.x) > 0.5 && Math.abs(nx.x - before.x) < e.r * 2) {
      e.vx *= -0.2;
      if (e.def.behavior === 'boss' && e.boss?.action === 'dash') {
        e.stun = 1.1; e.boss.action = ''; e.boss.cool = 1.4;
        this.shake = 10;
      }
    }
    if (Math.abs(nx.y - before.y) > 0.5 && Math.abs(nx.y - before.y) < e.r * 2) e.vy *= -0.2;
    e.x = nx.x; e.y = nx.y;
    e.vx = damp(e.vx, 0, 2.6, dt);
    e.vy = damp(e.vy, 0, 2.6, dt);
    if (Math.abs(e.vx) + Math.abs(e.vy) < 4) { e.vx = 0; e.vy = 0; }
  }

  /* ------------------------------ Boss AI ------------------------------ */

  private bossAi(e: Enemy, dt: number, d: number) {
    const bs = e.boss!;
    const p = this.player;
    const hp01 = e.hp / e.maxHp;
    if (hp01 < 0.33) bs.phase = 3; else if (hp01 < 0.66) bs.phase = 2; else bs.phase = 1;

    if (bs.action === '') {
      bs.cool -= dt;
      if (bs.cool <= 0) {
        const pool: string[] = [];
        if (bs.phase === 1) pool.push('dash', 'dash', 'slam', 'summon');
        if (bs.phase === 2) pool.push('slam', 'drain', 'summon', 'dash');
        if (bs.phase === 3) pool.push('drain', 'sweep', 'summon', 'dash', 'slam');
        bs.action = pick(pool);
        bs.timer = 0;
        if (bs.action === 'dash') { bs.tx = p.x; bs.ty = p.y; }
        if (bs.action === 'drain' || bs.action === 'sweep') {
          this.events.push({ type: 'toast', text: bs.action === 'drain' ? '噬灯者开始吞噬你的光！' : '灯影横扫——躲开！' });
        }
      }
    } else {
      bs.timer += dt;
      const wind = 0.5;
      switch (bs.action) {
        case 'dash': {
          if (bs.timer < wind) {
            e.vx = damp(e.vx, 0, 8, dt); e.vy = damp(e.vy, 0, 8, dt);
            e.facing = Math.cos(angleTo(e.x, e.y, p.x, p.y)) > 0 ? 1 : -1;
          } else {
            const a = angleTo(e.x, e.y, bs.tx, bs.ty);
            e.vx = Math.cos(a) * 640; e.vy = Math.sin(a) * 640;
            if (bs.timer > wind + 0.5) { bs.action = ''; bs.cool = rand(0.7, 1.4); }
          }
          break;
        }
        case 'slam': {
          if (bs.timer < 0.7) { e.vx = damp(e.vx, 0, 8, dt); e.vy = damp(e.vy, 0, 8, dt); }
          else if (bs.timer < 0.72) {
            this.shake = 20;
            this.flash = { color: '#ff7a4a', power: 0.4 };
            for (let i = 0; i < 2; i++) {
              this.effects.push({
                id: this.nextId++, kind: 'ring', x: e.x, y: e.y, z: 10,
                angle: 0, r0: 30, r1: 240 + i * 70, len: 0, w: 0,
                life: 0.42 + i * 0.12, maxLife: 0.42 + i * 0.12,
                dmg: e.def.dmg * 1.5, knock: 700, stun: 0.3,
                color: '#ff8a5a', hit: new Set(), own: 'enemy', delay: 0,
              });
            }
            for (let i = 0; i < 30; i++) {
              const a = rand(0, TAU);
              this.addParticle(e.x, e.y, rand(6, 30), {
                vx: Math.cos(a) * rand(120, 520), vy: Math.sin(a) * rand(120, 520), vz: rand(40, 220),
                life: rand(0.4, 0.9), size: rand(2.5, 6), color: '#ff9b5c', glow: true, drag: 2, grav: 120,
              });
            }
            Sound.sfx('roar');
            bs.action = ''; bs.cool = rand(0.9, 1.6);
          }
          break;
        }
        case 'summon': {
          if (bs.timer < 0.6) {
            if (chance(dt * 6)) this.spawnFx(e.x + rand(-60, 60), e.y + rand(-40, 60), e.def.glow);
          } else {
            const minions = this.enemies.filter((m) => !m.dead && m.def.behavior !== 'boss').length;
            const want = bs.phase >= 3 ? 4 : 3;
            const room = Math.max(0, 8 - minions);   // 场上小怪上限，避免无限召唤
            const n = Math.min(want, room);
            for (let i = 0; i < n; i++) {
              const [x, y] = this.findSpawnPoint(e.x, e.y, 160, 18);
              this.spawnEnemy('shade', x, y);
              this.spawnFx(x, y, '#b7a8ff');
            }
            if (n > 0) this.events.push({ type: 'toast', text: '它吐出了新的影子。' });
            else this.events.push({ type: 'toast', text: '黑暗已经挤不出新的影子了。' });
            bs.action = ''; bs.cool = rand(1.6, 2.4);
          }
          break;
        }
        case 'drain': {
          const a = angleTo(e.x, e.y, p.x, p.y);
          e.facing = Math.cos(a) > 0 ? 1 : -1;
          if (bs.timer < 0.6) { e.vx = damp(e.vx, 0, 8, dt); e.vy = damp(e.vy, 0, 8, dt); }
          else if (bs.timer < 2.0) {
            e.vx = damp(e.vx, 0, 8, dt); e.vy = damp(e.vy, 0, 8, dt);
            // 光束吸附：越近吸得越快
            const inBeam = Math.abs(angleDiff(a, angleTo(e.x, e.y, p.x, p.y))) < 0.42;
            if (inBeam && d < 620) {
              const drain = 26 * dt;
              const stolen = Math.min(p.combo, drain);
              p.combo -= stolen;
              e.hp = Math.min(e.maxHp, e.hp + stolen * 6);
              if (chance(dt * 20)) {
                const t = rand(0.2, 1);
                this.addParticle(
                  e.x + Math.cos(a) * 620 * (1 - t), e.y + Math.sin(a) * 620 * (1 - t), rand(10, 50),
                  { vx: -Math.cos(a) * 120, vy: -Math.sin(a) * 120, vz: 0, life: 0.4, size: rand(1.5, 3), color: '#ffd79a', glow: true, drag: 0, grav: 0 },
                );
              }
              if (chance(dt * 2)) this.hurtPlayer(6, a);
            }
            this.effects.push({
              id: this.nextId++, kind: 'beam', x: e.x, y: e.y, z: 38, angle: a, len: 640, w: 34,
              r0: 0, r1: 640, life: 0.08, maxLife: 0.08, dmg: 0, knock: 0, stun: 0,
              color: '#ff6a4a', hit: new Set(), own: 'enemy', delay: 0,
            });
          } else { bs.action = ''; bs.cool = rand(0.8, 1.5); }
          break;
        }
        case 'sweep': {
          e.vx = damp(e.vx, 0, 8, dt); e.vy = damp(e.vy, 0, 8, dt);
          if (bs.timer < 0.6) break;
          if (bs.timer < 2.1) {
            bs.sweepA += dt * (bs.phase >= 3 ? 3.1 : 2.3);
            for (const off of [0, Math.PI]) {
              const a = bs.sweepA + off;
              // 判定
              const rel = angleTo(e.x, e.y, p.x, p.y);
              if (Math.abs(angleDiff(a, rel)) < 0.3 && d < 700) this.hurtPlayer(14 * dt * 10, rel);
              this.effects.push({
                id: this.nextId++, kind: 'beam', x: e.x, y: e.y, z: 30, angle: a, len: 700, w: 26,
                r0: 0, r1: 700, life: 0.06, maxLife: 0.06, dmg: 0, knock: 0, stun: 0,
                color: '#c9a6ff', hit: new Set(), own: 'enemy', delay: 0,
              });
            }
          } else { bs.action = ''; bs.cool = rand(0.9, 1.5); }
          break;
        }
      }
    }
  }

  /* ------------------------------ 伤害与死亡 ------------------------------ */

  damageEnemy(e: Enemy, dmg: number, dir: number, knock: number, stun = 0) {
    if (e.dead) return;
    const crit = chance(0.16);
    let final = dmg * (crit ? 1.85 : 1);
    if (e.def.behavior === 'boss' && this.bossWarded) {
      final *= 0.16;
      // 被护佑：缓慢回复
    }
    e.hp -= final;
    e.hitFlash = 0.12;

    // 连击
    const p = this.player;
    if (p.combo < 99) p.combo = Math.min(99, p.combo + 1);
    p.comboTimer = 2.6;
    p.comboPeak = Math.max(p.comboPeak, p.combo);
    this.prog.maxCombo = Math.max(this.prog.maxCombo, Math.floor(p.combo));
    p.glow = Math.min(1, p.glow + (crit ? 0.4 : 0.2));

    // 击退
    const w = 1 - (e.def.weight ?? 0.3);
    const kb = knock * clamp(w, 0.05, 1) / (e.def.behavior === 'boss' ? 5 : 1);
    e.vx += Math.cos(dir) * kb;
    e.vy += Math.sin(dir) * kb;
    if (stun > 0) e.stun = Math.max(e.stun, stun);

    this.hitstop = Math.max(this.hitstop, crit ? HITSTOP_CRIT : HITSTOP_HIT);
    this.shake = Math.min(this.shake + (crit ? 5 : 2.6), 16);
    Sound.sfx(crit ? 'crit' : 'hit');

    // 受击火花
    const n = crit ? 16 : 9;
    for (let i = 0; i < n; i++) {
      const a = dir + rand(-1, 1);
      this.addParticle(e.x + rand(-6, 6), e.y + rand(-6, 6), rand(10, e.h * 0.7), {
        vx: Math.cos(a) * rand(60, 300), vy: Math.sin(a) * rand(60, 300), vz: rand(30, 180),
        life: rand(0.22, 0.5), size: rand(1.4, 3.2),
        color: crit ? '#fff4d0' : '#ffce80', glow: true, drag: 2.6, grav: 260,
      });
    }
    this.addText(e.x, e.y, e.h * 0.9, (crit ? '●' : '') + Math.round(final), crit ? '#fff2c8' : '#ffcf86', crit ? 19 : 14);

    if (e.hp <= 0) this.killEnemy(e, dir);
  }

  private killEnemy(e: Enemy, dir: number) {
    e.dead = true;
    e.deathT = 0;
    this.prog.kills++;
    Sound.sfx(e.def.behavior === 'boss' ? 'die' : 'hit');

    const isBoss = e.def.behavior === 'boss';
    // 掉落灯火
    const coins = e.def.coin;
    const pieces = isBoss ? 10 : clamp(Math.round(coins / 2), 1, 4);
    for (let i = 0; i < pieces; i++) {
      this.drops.push({
        x: e.x, y: e.y, z: rand(10, e.h * 0.6),
        vx: rand(-140, 140), vy: rand(-140, 140), vz: rand(60, 190),
        kind: 'coin', value: Math.max(1, Math.round(coins / pieces)),
        life: 26, t: 0, taken: false,
      });
    }
    if (isBoss) {
      const wicks = [2, 3, 4][clamp(this.level.index, 0, 2)];
      for (let i = 0; i < wicks; i++) {
        this.drops.push({
          x: e.x, y: e.y, z: 40, vx: rand(-90, 90), vy: rand(-90, 90), vz: rand(90, 170),
          kind: 'wick', value: 1, life: 40, t: 0, taken: false,
        });
      }
      this.drops.push({ x: e.x, y: e.y, z: 30, vx: 0, vy: 0, vz: 120, kind: 'oil', value: 1, life: 40, t: 0, taken: false });
    } else if (chance(0.08)) {
      this.drops.push({ x: e.x, y: e.y, z: 26, vx: rand(-40, 40), vy: rand(-40, 40), vz: 120, kind: 'oil', value: 1, life: 26, t: 0, taken: false });
    }

    // 死亡特效
    const n = isBoss ? 90 : 20;
    for (let i = 0; i < n; i++) {
      const a = rand(0, TAU);
      const sp = isBoss ? rand(120, 720) : rand(60, 320);
      this.addParticle(e.x, e.y, rand(6, e.h), {
        vx: Math.cos(a) * sp, vy: Math.sin(a) * sp, vz: rand(40, 320),
        life: rand(0.4, 1.1), size: rand(2, isBoss ? 7 : 4),
        color: isBoss ? pick(['#ff9b5c', '#ffd79a', '#ff6a4a']) : e.def.glow,
        glow: true, drag: 2, grav: 220,
      });
    }
    if (isBoss) {
      this.player.glow = 1;
      this.flash = { color: '#ffd9a0', power: 0.7 };
      this.shake = 24;
      this.onBossDead();
    }
  }

  private onBossDead() {
    this.bossDead = true;
    this.cleared = true;
    this.events.push({ type: 'bossEnd' });
    this.events.push({ type: 'levelCleared' });

    // 灯塔亮起
    if (this.goalProp) { this.goalProp.lit = true; this.goalProp.litT = 0; }
    if (!this.prog.cleared.includes(this.level.index)) this.prog.cleared.push(this.level.index);
    if (!this.prog.lit.includes(this.level.index)) {
      this.prog.lit.push(this.level.index);
      this.prog.wicks += 1;
    }
    this.prog.coins += [80, 120, 200][clamp(this.level.index, 0, 2)];

    if (this.level.index === 1) {
      // 盲女化为灯芯
      this.prog.blindGirl = true;
      this.girlSavedThisLevel = true;
      setTimeout(() => { /* 用事件序列代替计时器 */ }, 0);
      this.events.push({ type: 'dialogue', key: 'l2_clear' });
      if (this.girl) { this.girl.gone = true; this.girl.active = false; }
    } else if (this.level.index === 0) {
      this.events.push({ type: 'dialogue', key: 'l1_clear' });
    } else {
      this.events.push({ type: 'dialogue', key: 'l3_clear' });
    }
  }

  hurtPlayer(dmg: number, dir: number) {
    const p = this.player;
    if (p.dead || p.invuln > 0) return;
    p.hp -= dmg;
    p.invuln = 0.7;
    p.hurtFlash = 0.35;
    // 被咬掉光
    p.combo = Math.max(0, p.combo - 3);
    this.shake = Math.min(this.shake + 7, 18);
    this.flash = { color: '#d8543f', power: 0.34 };
    p.vx += Math.cos(dir) * 210;
    p.vy += Math.sin(dir) * 210;
    Sound.sfx('hurt');
    this.addText(p.x, p.y, 60, '-' + Math.round(dmg), '#ff8a72', 16);
    for (let i = 0; i < 12; i++) {
      const a = dir + rand(-1.2, 1.2);
      this.addParticle(p.x, p.y, rand(10, 44), {
        vx: Math.cos(a) * rand(60, 220), vy: Math.sin(a) * rand(60, 220), vz: rand(20, 120),
        life: rand(0.3, 0.6), size: rand(2, 4), color: '#ff9a80', glow: true, drag: 3, grav: 260,
      });
    }
    if (p.hp <= 0) this.playerDie();
  }

  private playerDie() {
    const p = this.player;
    // 盲女之灯：一次救赎
    if (p.revives > 0) {
      p.revives--;
      p.hp = p.maxHp * 0.45;
      p.invuln = 2.4;
      p.combo = 20;
      p.comboTimer = 2.6;
      this.flash = { color: '#fff6dd', power: 1 };
      this.shake = 20;
      Sound.sfx('light');
      this.events.push({ type: 'toast', text: '盲女之灯替你燃了一次——她还在。' });
      for (let i = 0; i < 60; i++) {
        const a = rand(0, TAU);
        this.addParticle(p.x, p.y, rand(6, 60), {
          vx: Math.cos(a) * rand(80, 360), vy: Math.sin(a) * rand(80, 360), vz: rand(40, 240),
          life: rand(0.5, 1.2), size: rand(2, 5), color: '#fff2cc', glow: true, drag: 2, grav: 120,
        });
      }
      return;
    }
    p.dead = true;
    p.deathT = 0;
    p.hp = 0;
    this.prog.deaths++;
    this.shake = 18;
    this.flash = { color: '#000000', power: 0.8 };
    Sound.sfx('die');
    for (let i = 0; i < 50; i++) {
      const a = rand(0, TAU);
      this.addParticle(p.x, p.y, rand(6, 50), {
        vx: Math.cos(a) * rand(40, 240), vy: Math.sin(a) * rand(40, 240), vz: rand(30, 180),
        life: rand(0.6, 1.6), size: rand(2, 5), color: '#c9bda2', glow: true, drag: 2, grav: 90,
      });
    }
    this.events.push({ type: 'playerDead' });
  }

  /* ------------------------------ 效果 / 投掷物 ------------------------------ */

  private updateEffects(dt: number) {
    const p = this.player;
    for (let i = this.effects.length - 1; i >= 0; i--) {
      const f = this.effects[i];
      f.life -= dt;
      if (f.life <= 0) { this.effects.splice(i, 1); continue; }
      const t = 1 - f.life / f.maxLife;
      if (f.delay > 0) { f.delay -= dt; continue; }
      const r = f.r0 + (f.r1 - f.r0) * t;

      if (f.own === 'player') {
        for (const e of this.enemies) {
          if (e.dead || f.hit.has(e.id)) continue;
          let inside = false;
          if (f.kind === 'beam') {
            // 线段判定
            const dx = Math.cos(f.angle), dy = Math.sin(f.angle);
            const rx = e.x - f.x, ry = e.y - f.y;
            const proj = rx * dx + ry * dy;
            if (proj > -10 && proj < f.len) {
              const perp = Math.abs(rx * -dy + ry * dx);
              inside = perp < f.w * 0.5 + e.r;
            }
          } else {
            inside = dist(f.x, f.y, e.x, e.y) < r + e.r;
          }
          if (inside) {
            f.hit.add(e.id);
            this.damageEnemy(e, f.dmg, angleTo(f.x, f.y, e.x, e.y), f.knock, f.stun);
          }
        }
        // 技能也能点亮火盆
        if (f.kind === 'ring' || f.kind === 'burst' || f.kind === 'pillar') {
          for (const b of this.braziers) {
            if (!b.lit && dist(f.x, f.y, b.x, b.y) < r + b.r + 10) this.lightBrazier(b);
          }
        }
      } else {
        // 敌方范围伤害作用于玩家
        if (!f.hit.has(-1)) {
          const hitPlayer = f.kind === 'beam'
            ? (() => {
                const dx = Math.cos(f.angle), dy = Math.sin(f.angle);
                const rx = p.x - f.x, ry = p.y - f.y;
                const proj = rx * dx + ry * dy;
                if (proj < 0 || proj > f.len) return false;
                return Math.abs(rx * -dy + ry * dx) < f.w * 0.5 + p.r;
              })()
            : dist(f.x, f.y, p.x, p.y) < r + p.r;
          if (hitPlayer) {
            f.hit.add(-1);
            this.hurtPlayer(f.dmg, angleTo(f.x, f.y, p.x, p.y));
          }
        }
      }
    }
  }

  private updateProjs(dt: number) {
    const p = this.player;
    for (let i = this.projs.length - 1; i >= 0; i--) {
      const q = this.projs[i];
      q.life -= dt;
      q.x += q.vx * dt;
      q.y += q.vy * dt;
      q.spin += dt * 6;
      if (this.blocked(q.x, q.y, q.r)) { this.projBurst(q); this.projs.splice(i, 1); continue; }
      if (dist(q.x, q.y, p.x, p.y) < q.r + p.r) {
        this.hurtPlayer(q.dmg, angleTo(q.x, q.y, p.x, p.y));
        this.projBurst(q);
        this.projs.splice(i, 1);
        continue;
      }
      if (q.life <= 0) { this.projBurst(q); this.projs.splice(i, 1); }
    }
  }

  private projBurst(q: Proj) {
    for (let i = 0; i < 10; i++) {
      const a = rand(0, TAU);
      this.addParticle(q.x, q.y, q.z, {
        vx: Math.cos(a) * rand(40, 200), vy: Math.sin(a) * rand(40, 200), vz: rand(20, 120),
        life: rand(0.2, 0.5), size: rand(1.5, 3.5), color: q.color, glow: true, drag: 3, grav: 200,
      });
    }
  }

  private updateDrops(dt: number) {
    const p = this.player;
    for (let i = this.drops.length - 1; i >= 0; i--) {
      const d = this.drops[i];
      d.life -= dt; d.t += dt;
      if (d.taken) {
        // 飞向玩家
        const a = angleTo(d.x, d.y, p.x, p.y);
        const s = 520;
        d.x += Math.cos(a) * s * dt;
        d.y += Math.sin(a) * s * dt;
        d.z = damp(d.z, 26, 8, dt);
        if (dist(d.x, d.y, p.x, p.y) < 26) {
          if (d.kind === 'coin') { this.prog.coins += d.value; Sound.sfx('coin'); }
          else if (d.kind === 'wick') { this.prog.wicks += d.value; Sound.sfx('levelup'); this.events.push({ type: 'toast', text: '获得 灯芯 ×1' }); }
          else { this.prog.oil += d.value; Sound.sfx('coin'); this.events.push({ type: 'toast', text: '获得 灯油 ×1（按 R 使用）' }); }
          this.drops.splice(i, 1);
        }
        continue;
      }
      d.x += d.vx * dt; d.y += d.vy * dt; d.z += d.vz * dt;
      d.vz -= 520 * dt;
      d.vx = damp(d.vx, 0, 3, dt); d.vy = damp(d.vy, 0, 3, dt);
      if (d.z < 6) { d.z = 6; d.vz = Math.abs(d.vz) * 0.35; if (d.vz < 30) d.vz = 0; }
      if (dist(d.x, d.y, p.x, p.y) < 104) d.taken = true;
      if (d.life <= 0) this.drops.splice(i, 1);
      if (chance(dt * 3)) {
        this.addParticle(d.x, d.y, d.z, {
          vx: rand(-8, 8), vy: rand(-8, 8), vz: rand(10, 30), life: rand(0.5, 1.1),
          size: rand(1, 2.2), color: d.kind === 'coin' ? '#ffd070' : d.kind === 'wick' ? '#ffeec2' : '#9fe6ff',
          glow: true, drag: 1, grav: -20,
        });
      }
    }
  }

  private updateParticles(dt: number) {
    for (let i = this.particles.length - 1; i >= 0; i--) {
      const q = this.particles[i];
      q.life -= dt;
      if (q.life <= 0) { this.particles.splice(i, 1); continue; }
      q.x += q.vx * dt; q.y += q.vy * dt; q.z += q.vz * dt;
      q.vz -= q.grav * dt;
      q.vx = damp(q.vx, 0, q.drag, dt);
      q.vy = damp(q.vy, 0, q.drag, dt);
      if (q.z < 2) { q.z = 2; q.vz = Math.abs(q.vz) * 0.3; }
    }
    for (let i = this.texts.length - 1; i >= 0; i--) {
      const t = this.texts[i];
      t.life -= dt;
      t.z += t.vy * dt;
      t.vy = damp(t.vy, 26, 3, dt);
      if (t.life <= 0) this.texts.splice(i, 1);
    }
    if (this.particles.length > 900) this.particles.splice(0, this.particles.length - 900);
  }

  /* ------------------------------ 交互 ------------------------------ */

  private tryLightBrazier(x: number, y: number, range: number): boolean {
    for (const b of this.braziers) {
      if (b.lit) continue;
      if (dist(x, y, b.x, b.y) < range + b.r) {
        if (this.player.combo >= 4) { this.lightBrazier(b); return true; }
        this.events.push({ type: 'toast', text: '需要 4 连击的光才能点亮火盆。' });
        return false;
      }
    }
    return false;
  }

  lightBrazier(b: Prop) {
    if (b.lit) return;
    b.lit = true; b.litT = 0;
    this.braziersLit++;
    this.player.combo = Math.max(0, this.player.combo - 4);
    Sound.sfx('brazier');
    this.flash = { color: '#ffca70', power: 0.4 };
    this.shake = 8;
    for (let i = 0; i < 40; i++) {
      const a = rand(0, TAU);
      this.addParticle(b.x, b.y, rand(10, 46), {
        vx: Math.cos(a) * rand(40, 200), vy: Math.sin(a) * rand(40, 200), vz: rand(60, 260),
        life: rand(0.5, 1.3), size: rand(2, 5), color: pick(['#ffd79a', '#fff2cc', '#ffb765']),
        glow: true, drag: 1.6, grav: 60,
      });
    }
    const need = this.level.braziersRequired ?? 0;
    if (need > 0) {
      this.events.push({ type: 'toast', text: `火盆已点亮 ${this.braziersLit} / ${need}` });
      if (this.braziersLit === 1) this.events.push({ type: 'dialogue', key: 'l2_brazier' });
      if (this.braziersLit >= need) {
        this.events.push({ type: 'toast', text: '三座火盆齐明——噬灯者的护佑破了！' });
        this.events.push({ type: 'flash', color: '#fff2cc', power: 0.8 });
        if (this.bossEnemy) {
          this.damageEnemy(this.bossEnemy, this.bossEnemy.maxHp * 0.12, 0, 0);
        }
      }
    }
  }

  private updateInteraction(dt: number) {
    const p = this.player;
    void dt;
    let prompt: string | null = null;
    this.highlightBrazier = null;

    // 火盆
    for (const b of this.braziers) {
      if (b.lit) continue;
      if (dist(p.x, p.y, b.x, b.y) < b.r + 72) {
        this.highlightBrazier = b;
        prompt = p.combo >= 4
          ? '按 E 以连击之光点燃火盆（消耗 4 连击）／直接攻击火盆亦可'
          : `需要 4 连击才能点燃火盆（当前 ${Math.floor(p.combo)}）`;
        break;
      }
    }

    // 掌灯人
    if (!prompt && this.merchantProp && dist(p.x, p.y, this.merchantProp.x, this.merchantProp.y) < 96) {
      prompt = '按 E 与掌灯人交谈（购买武器与补给）';
    }

    // 终点
    if (!prompt && this.goalProp && dist(p.x, p.y, this.goalProp.x, this.goalProp.y) < this.goalProp.r + 96) {
      if (this.goalProp.kind === 'dock') {
        prompt = this.cleared ? '按 E 渡过灯河' : '先击败灯魔之影';
      } else {
        prompt = this.cleared
          ? '按 E 在灯塔处休整（存档 / 灯芯升级 / 渡过灯河）'
          : '灯塔尚未点亮——先击败本关 Boss';
      }
    }

    // 使用灯油
    if (Input.justPressed('KeyR')) this.useOil();

    this.prompt = prompt;
  }

  useOil() {
    const p = this.player;
    if (this.prog.oil <= 0) { this.events.push({ type: 'toast', text: '没有灯油了。' }); Sound.sfx('ui'); return; }
    if (p.hp >= p.maxHp - 0.5) { this.events.push({ type: 'toast', text: '生命已满。' }); return; }
    this.prog.oil--;
    p.hp = Math.min(p.maxHp, p.hp + p.maxHp * 0.45);
    Sound.sfx('light');
    this.flash = { color: '#ffd9a0', power: 0.25 };
    this.addText(p.x, p.y, 70, '+' + Math.round(p.maxHp * 0.45), '#ffe9b0', 16);
    for (let i = 0; i < 24; i++) {
      const a = rand(0, TAU);
      this.addParticle(p.x, p.y, rand(6, 40), {
        vx: Math.cos(a) * rand(30, 160), vy: Math.sin(a) * rand(30, 160), vz: rand(40, 200),
        life: rand(0.4, 0.9), size: rand(1.6, 3.6), color: '#ffeec2', glow: true, drag: 2, grav: 40,
      });
    }
  }

  interact() {
    const p = this.player;
    if (p.dead) return;
    // 火盆
    for (const b of this.braziers) {
      if (!b.lit && dist(p.x, p.y, b.x, b.y) < b.r + 72) {
        this.tryLightBrazier(p.x, p.y, b.r + 60);
        return;
      }
    }
    // 掌灯人
    if (this.merchantProp && dist(p.x, p.y, this.merchantProp.x, this.merchantProp.y) < 96) {
      this.events.push({ type: 'openShop' });
      return;
    }
    // 终点
    if (this.goalProp && dist(p.x, p.y, this.goalProp.x, this.goalProp.y) < this.goalProp.r + 96) {
      if (this.goalProp.kind === 'dock') {
        if (this.cleared) this.events.push({ type: 'victory' });
        else this.events.push({ type: 'toast', text: '灯魔之影还挡在渡口。' });
      } else if (this.cleared) {
        this.events.push({ type: 'openLighthouse' });
      } else {
        this.events.push({ type: 'toast', text: '灯塔还暗着——先击败本关 Boss。' });
      }
    }
  }

  /* ------------------------------ 小工具 ------------------------------ */

  addParticle(
    x: number, y: number, z: number,
    o: Partial<Particle> & { life: number; size: number; color: string },
  ) {
    this.particles.push({
      x, y, z, vx: 0, vy: 0, vz: 0,
      maxLife: o.life, glow: true, drag: 2, grav: 0,
      kind: 'spark', ...o,
    } as Particle);
  }

  addText(x: number, y: number, z: number, text: string, color: string, size: number) {
    this.texts.push({ x, y, z, vy: 40, text, color, size, life: 0.75, maxLife: 0.75 });
  }

  spawnFx(x: number, y: number, color: string) {
    for (let i = 0; i < 14; i++) {
      const a = rand(0, TAU);
      this.addParticle(x, y, rand(0, 20), {
        vx: Math.cos(a) * rand(30, 180), vy: Math.sin(a) * rand(30, 180), vz: rand(40, 180),
        life: rand(0.3, 0.7), size: rand(1.6, 3.4), color, glow: true, drag: 2, grav: 20,
      });
    }
  }

  private updateObjective() {
    const lv = this.level;
    if (this.cleared) {
      if (lv.goal.kind === 'dock') this.objective = '目标：<b>渡过灯河</b>（前往地图北侧的渡口）';
      else this.objective = '目标：<b>点亮灯塔</b>（存档 · 灯芯升级 · 渡过灯河）';
      return;
    }
    const unspawned = this.waves.filter((w) => !w.spawned).length;
    const remaining = this.waves.filter((w) => w.spawned && !w.cleared).length;
    const need = lv.braziersRequired ?? 0;
    if (need > 0 && this.braziersLit < need) {
      this.objective = `目标：点燃火盆 <b>${this.braziersLit} / ${need}</b>　（否则影子不断再生，Boss 减伤）`;
      return;
    }
    if (!this.bossSpawned) {
      this.objective = remaining > 0
        ? `目标：清掉这片区域的影子（剩 ${remaining} 组）`
        : unspawned > 0
          ? '目标：向更深处前进，寻找敌影'
          : `目标：前往 <b>${lv.boss.label}</b> 所在处`;
      return;
    }
    this.objective = `目标：击败 <b>${lv.boss.label}</b>`;
  }

  drainEvents(): WorldEvent[] {
    const ev = this.events;
    this.events = [];
    return ev;
  }

  /** 当前 Boss 血量比例（HUD 用） */
  get bossHp01() {
    if (!this.bossEnemy || this.bossEnemy.dead) return 0;
    return clamp(this.bossEnemy.hp / this.bossEnemy.maxHp, 0, 1);
  }
  get bossPhaseText() {
    if (!this.bossEnemy) return '';
    const ph = this.bossEnemy.boss?.phase ?? 1;
    const ward = this.bossWarded ? '　〔护佑中：伤害-84%〕' : '';
    return ['', '一阶段 · 扑食', '二阶段 · 呼影', '三阶段 · 熄灯'][ph] + ward;
  }
}
