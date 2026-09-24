/* ============================================================
   render.ts — 2.5D 渲染
   · 地面用压扁的斜轴测投影铺贴
   · 角色/建筑以"立绘"方式绘制（脚在投影点，身高向上），矢量绘制、零素材
   · 黑暗层：先用黑色盖住全屏，再用 destination-out 在光源处"挖洞"，
     最后叠加一层暖色加光，得到"黑暗中的一盏灯"
   · 深度排序：墙按前缘 y，实体按 y，自然产生遮挡
   ============================================================ */
import { YSQUASH, TAU, clamp, rand, rgba, dist, mulberry32, lerp, damp } from '../core/utils';
import { World, Enemy, Prop, Drop, Effect, Particle, Proj } from './world';

interface Light { x: number; y: number; r: number; power: number; color: string; }

export class Renderer {
  canvas: HTMLCanvasElement;
  ctx: CanvasRenderingContext2D;
  W = 0; H = 0; dpr = 1;
  private dark: HTMLCanvasElement;
  private dctx: CanvasRenderingContext2D;
  private lights: Light[] = [];
  private groundKey = -1;
  private groundTile: HTMLCanvasElement | null = null;
  private cam = { x: 0, y: 0 };
  private shx = 0;
  private shy = 0;
  private t = 0;

  constructor(canvas: HTMLCanvasElement) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false })!;
    this.dark = document.createElement('canvas');
    this.dctx = this.dark.getContext('2d')!;
    this.resize();
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const w = window.innerWidth, h = window.innerHeight;
    this.dpr = dpr;
    this.W = w; this.H = h;
    this.canvas.width = Math.floor(w * dpr);
    this.canvas.height = Math.floor(h * dpr);
    this.canvas.style.width = w + 'px';
    this.canvas.style.height = h + 'px';
    this.dark.width = Math.floor(w * dpr);
    this.dark.height = Math.floor(h * dpr);
  }

  private SX(x: number) { return x - this.cam.x + this.W * 0.5 + this.shx; }
  private SY(y: number, z: number) { return (y - this.cam.y) * YSQUASH - z + this.H * 0.5 + this.shy; }

  private addLight(x: number, y: number, r: number, power: number, color = '#ffcf86') {
    this.lights.push({ x, y, r, power, color });
  }

  /* ============================ 地面 ============================ */

  private buildGround(world: World) {
    const key = world.level.index;
    if (this.groundKey === key && this.groundTile) return;
    this.groundKey = key;
    const size = 128;
    const c = document.createElement('canvas');
    c.width = size; c.height = size;
    const g = c.getContext('2d')!;
    const pal = world.level.palette;
    const rnd = mulberry32(world.level.seed + 7);
    g.fillStyle = pal.floor;
    g.fillRect(0, 0, size, size);
    // 石板
    const cell = 32;
    for (let iy = 0; iy < size / cell; iy++) {
      for (let ix = 0; ix < size / cell; ix++) {
        const v = rnd();
        g.fillStyle = v > 0.6 ? pal.floor2 : pal.floor;
        g.fillRect(ix * cell + 1, iy * cell + 1, cell - 2, cell - 2);
      }
    }
    // 石缝
    g.strokeStyle = 'rgba(0,0,0,0.42)';
    g.lineWidth = 1;
    for (let i = 0; i <= size; i += cell) {
      g.beginPath(); g.moveTo(i, 0); g.lineTo(i, size); g.stroke();
      g.beginPath(); g.moveTo(0, i); g.lineTo(size, i); g.stroke();
    }
    // 噪点与裂纹
    for (let i = 0; i < 90; i++) {
      const x = rnd() * size, y = rnd() * size;
      g.fillStyle = rnd() > 0.5 ? 'rgba(255,255,255,0.035)' : 'rgba(0,0,0,0.30)';
      g.fillRect(x, y, 1 + rnd() * 2.4, 1 + rnd() * 2.4);
    }
    g.strokeStyle = 'rgba(0,0,0,0.35)';
    for (let i = 0; i < 5; i++) {
      g.beginPath();
      let x = rnd() * size, y = rnd() * size;
      g.moveTo(x, y);
      for (let k = 0; k < 4; k++) { x += (rnd() - 0.5) * 40; y += (rnd() - 0.5) * 40; g.lineTo(x, y); }
      g.stroke();
    }
    this.groundTile = c;
  }

  private drawFloor(world: World) {
    const ctx = this.ctx;
    this.buildGround(world);
    // 以世界坐标铺贴：把画布变换到"世界平面"，一次填充即可
    ctx.save();
    ctx.translate(this.W * 0.5 + this.shx - this.cam.x, this.H * 0.5 + this.shy - this.cam.y * YSQUASH);
    ctx.scale(1, YSQUASH);
    const pat = ctx.createPattern(this.groundTile!, 'repeat')!;
    ctx.fillStyle = pat;
    ctx.fillRect(this.cam.x - this.W * 0.5 - 40, this.cam.y - this.H * 0.5 / YSQUASH - 40,
      this.W + 80, this.H / YSQUASH + 80);
    ctx.restore();

    // 灯河（第三关地图北侧的水面）
    if (world.level.index === 2) {
      const yTop = this.SY(0, 0), yBot = this.SY(165, 0);
      const grad = ctx.createLinearGradient(0, yTop, 0, yBot);
      grad.addColorStop(0, '#050a16');
      grad.addColorStop(1, 'rgba(10,20,40,0.0)');
      ctx.fillStyle = grad;
      ctx.fillRect(0, yTop, this.W, yBot - yTop);
      ctx.strokeStyle = 'rgba(150,190,255,0.10)';
      ctx.lineWidth = 1;
      for (let i = 0; i < 16; i++) {
        const yy = this.SY(10 + i * 10, 0) + Math.sin(this.t * 1.4 + i) * 2;
        ctx.beginPath();
        ctx.moveTo(this.SX((i * 173 + this.t * 12) % world.level.w), yy);
        ctx.lineTo(this.SX((i * 173 + this.t * 12) % world.level.w) + 60, yy);
        ctx.stroke();
      }
      // 河上漂着的残灯
      for (let i = 0; i < 8; i++) {
        const lx = (i * 331 + 40) % world.level.w;
        const ly = 40 + ((i * 71) % 90);
        const px = this.SX(lx), py = this.SY(ly, 0);
        if (px < -50 || px > this.W + 50) continue;
        const fl = 0.5 + 0.5 * Math.sin(this.t * 2 + i);
        ctx.fillStyle = rgba('#ffb765', 0.35 + fl * 0.3);
        ctx.beginPath(); ctx.ellipse(px, py, 7, 3.4, 0, 0, TAU); ctx.fill();
        ctx.fillStyle = rgba('#fff2cc', 0.5 + fl * 0.4);
        ctx.beginPath(); ctx.arc(px, py - 2, 2.2, 0, TAU); ctx.fill();
        this.addLight(lx, ly, 70, 0.35, '#ffb765');
      }
    }

    // 地面暗纹：血痕/裂缝增强氛围
    const ctx2 = ctx;
    ctx2.save();
    ctx2.globalAlpha = 0.35;
    ctx2.translate(this.W * 0.5 + this.shx - this.cam.x, this.H * 0.5 + this.shy - this.cam.y * YSQUASH);
    ctx2.scale(1, YSQUASH);
    ctx2.strokeStyle = 'rgba(0,0,0,0.55)';
    const rnd = mulberry32(world.level.seed + 99);
    for (let i = 0; i < 26; i++) {
      const x = rnd() * world.level.w, y = rnd() * world.level.h;
      ctx2.lineWidth = 1 + rnd() * 2;
      ctx2.beginPath();
      ctx2.moveTo(x, y);
      ctx2.lineTo(x + (rnd() - 0.5) * 90, y + (rnd() - 0.5) * 90);
      ctx2.stroke();
    }
    ctx2.restore();
  }

  /* ============================ 标题背景 ============================ */

  /** 没有世界时（标题/菜单）画一盏悬在黑暗里的灯 */
  private drawBackdrop() {
    const ctx = this.ctx;
    const cx = this.W * 0.5, cy = this.H * 0.5 - 40;
    const grad = ctx.createRadialGradient(cx, cy, 10, cx, cy, Math.max(this.W, this.H) * 0.75);
    grad.addColorStop(0, '#1a1408');
    grad.addColorStop(0.4, '#0b0c14');
    grad.addColorStop(1, '#03040a');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, this.W, this.H);

    const flick = 0.9 + Math.sin(this.t * 2.3) * 0.06 + Math.sin(this.t * 7.1) * 0.03;
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(cx, cy, 4, cx, cy, 330 * flick);
    rg.addColorStop(0, 'rgba(255,238,200,0.85)');
    rg.addColorStop(0.18, 'rgba(255,196,110,0.35)');
    rg.addColorStop(1, 'rgba(255,150,60,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(cx, cy, 330 * flick, 0, TAU); ctx.fill();

    // 灯芯与灯火飘散
    for (let i = 0; i < 46; i++) {
      const seed = i * 97.13;
      const a = this.t * (0.12 + (i % 5) * 0.03) + seed;
      const r = 60 + ((seed * 7) % 260);
      const px = cx + Math.cos(a) * r;
      const py = cy + Math.sin(a) * r * 0.55 + Math.sin(this.t * 0.7 + i) * 14;
      const sz = 1 + (i % 4) * 0.7;
      ctx.fillStyle = `rgba(255,${170 + (i % 5) * 12},90,${0.10 + (i % 6) * 0.035})`;
      ctx.beginPath(); ctx.arc(px, py, sz, 0, TAU); ctx.fill();
    }
    ctx.globalCompositeOperation = 'source-over';
  }

  /* ============================ 主绘制 ============================ */

  draw(world: World | null, dt: number) {
    const ctx = this.ctx;
    this.t += dt;
    this.lights.length = 0;

    const dpr = this.dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;

    if (!world) { this.drawBackdrop(); return; }

    ctx.fillStyle = world.level.palette.fog;
    ctx.fillRect(0, 0, this.W, this.H);

    // 震屏
    const s = world.shake;
    this.shx = s > 0 ? rand(-s, s) : 0;
    this.shy = s > 0 ? rand(-s, s) : 0;
    this.cam.x = world.cam.x; this.cam.y = world.cam.y;

    this.drawFloor(world);

    // 地面层特效（光环、冲击波、挥击弧线、预警圈）
    for (const f of world.effects) {
      if (f.kind === 'beam') continue;
      this.drawEffectGround(world, f);
    }

    // 深度排序列表
    type Item = { y: number; fn: () => void };
    const items: Item[] = [];

    for (const w of world.walls) {
      items.push({ y: w.y + w.d, fn: () => this.drawWall(world, w) });
    }
    for (const p of world.props) {
      items.push({ y: p.y, fn: () => this.drawProp(world, p) });
    }
    for (const d of world.drops) {
      items.push({ y: d.y, fn: () => this.drawDrop(world, d) });
    }
    for (const e of world.enemies) {
      if (e.dead && e.deathT > 0.9) continue;
      items.push({ y: e.y, fn: () => this.drawEnemy(world, e) });
    }
    if (world.girl && world.girl.active && !world.girl.gone) {
      items.push({ y: world.girl.y, fn: () => this.drawGirl(world) });
    }
    items.push({ y: world.player.y, fn: () => this.drawPlayer(world) });
    items.sort((a, b) => a.y - b.y);
    for (const it of items) it.fn();

    // 光柱 / 光束（加光绘制）
    ctx.globalCompositeOperation = 'lighter';
    for (const f of world.effects) {
      if (f.kind === 'beam' || f.kind === 'pillar') this.drawEffectBeam(world, f);
    }
    ctx.globalCompositeOperation = 'source-over';

    // 投射物
    for (const q of world.projs) this.drawProj(world, q);

    // 粒子
    ctx.globalCompositeOperation = 'lighter';
    for (const p of world.particles) this.drawParticle(world, p);
    ctx.globalCompositeOperation = 'source-over';

    // 伤害数字
    for (const t of world.texts) this.drawFloatText(world, t);

    // 黑暗与灯光
    this.applyLighting(world);

    // 玩家濒死红边 / 全屏闪光
    this.drawFlash(world);

    // 屏幕外目标指示
    this.drawMarkers(world);
  }

  /* ============================ 墙 / 道具 ============================ */

  private drawWall(world: World, w: { x: number; y: number; w: number; d: number; h: number }) {
    const ctx = this.ctx;
    const pal = world.level.palette;
    const x0 = this.SX(w.x), x1 = this.SX(w.x + w.w);
    const yN = this.SY(w.y, 0), yS = this.SY(w.y + w.d, 0);
    const tN = yN - w.h, tS = yS - w.h;   // 顶面的北缘 / 南缘
    if (x1 < -90 || x0 > this.W + 90 || yS < -180 || tN > this.H + 180) return;

    // 侧面（东侧）——给立方体一点厚度感
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.beginPath();
    ctx.moveTo(x1, tN);
    ctx.lineTo(x1 + 8, tN + 8);
    ctx.lineTo(x1 + 8, yS + 8);
    ctx.lineTo(x1, yS);
    ctx.closePath();
    ctx.fill();

    // 正面（南侧，朝向镜头）
    const g = ctx.createLinearGradient(0, tS, 0, yS);
    g.addColorStop(0, pal.wallTop);
    g.addColorStop(0.4, pal.wall);
    g.addColorStop(1, '#080a12');
    ctx.fillStyle = g;
    ctx.fillRect(x0, tS, x1 - x0, yS - tS);

    // 砖缝
    ctx.strokeStyle = 'rgba(0,0,0,0.35)';
    ctx.lineWidth = 1;
    for (let yy = tS + 11; yy < yS; yy += 13) {
      ctx.beginPath(); ctx.moveTo(x0, yy); ctx.lineTo(x1, yy); ctx.stroke();
    }

    // 顶面
    ctx.fillStyle = pal.wall;
    ctx.fillRect(x0, tN, x1 - x0, yS - yN);
    // 顶面高光边 + 南缘阴影
    ctx.strokeStyle = rgba(pal.rim, 0.28);
    ctx.lineWidth = 1.4;
    ctx.beginPath(); ctx.moveTo(x0, tN); ctx.lineTo(x1, tN); ctx.stroke();
    ctx.strokeStyle = 'rgba(0,0,0,0.5)';
    ctx.beginPath(); ctx.moveTo(x0, yS); ctx.lineTo(x1, yS); ctx.stroke();

    // 墙体本身也参与"挡光"，因此给一个极弱的自发光，让轮廓在黑暗中可辨
    this.addLight(w.x + w.w / 2, w.y + w.d / 2, Math.max(w.w, w.d) * 0.62, 0.1, '#ffd9a0');
  }

  private drawProp(world: World, p: Prop) {
    switch (p.kind) {
      case 'lighthouse': return this.drawLighthouse(world, p);
      case 'brazier': return this.drawBrazier(world, p);
      case 'merchant': return this.drawMerchant(world, p);
      case 'dock': return this.drawDock(world, p);
      case 'statue': return this.drawStatue(world, p);
      case 'pillar': return this.drawPillar(world, p);
      case 'lantern': return this.drawLantern(world, p);
      case 'tree': return this.drawTree(world, p);
      default: return this.drawRubble(world, p);
    }
  }

  private shadow(x: number, y: number, r: number, alpha = 0.42) {
    const ctx = this.ctx;
    ctx.fillStyle = `rgba(0,0,0,${alpha})`;
    ctx.beginPath();
    ctx.ellipse(this.SX(x), this.SY(y, 0), r, r * YSQUASH * 0.85, 0, 0, TAU);
    ctx.fill();
  }

  private drawLighthouse(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    const h = 200;
    this.shadow(p.x, p.y, 46, 0.5);
    // 塔身
    const g = ctx.createLinearGradient(px - 34, 0, px + 34, 0);
    g.addColorStop(0, '#151824');
    g.addColorStop(0.45, '#39415a');
    g.addColorStop(1, '#141824');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(px - 34, py);
    ctx.lineTo(px - 18, py - h + 40);
    ctx.lineTo(px + 18, py - h + 40);
    ctx.lineTo(px + 34, py);
    ctx.closePath();
    ctx.fill();
    // 环带
    ctx.fillStyle = 'rgba(0,0,0,0.35)';
    for (let i = 1; i <= 4; i++) {
      const t = i / 5;
      const w = lerp(34, 18, t);
      ctx.fillRect(px - w, py - h * t - 2, w * 2, 4);
    }
    // 灯室
    const lit = !!p.lit;
    const lampY = py - h;
    ctx.fillStyle = '#20263a';
    ctx.fillRect(px - 20, lampY - 26, 40, 30);
    ctx.fillStyle = lit ? '#ffd070' : '#2b2f3d';
    ctx.fillRect(px - 14, lampY - 22, 28, 22);
    // 屋顶
    ctx.fillStyle = '#171b28';
    ctx.beginPath();
    ctx.moveTo(px - 24, lampY - 26);
    ctx.lineTo(px, lampY - 52);
    ctx.lineTo(px + 24, lampY - 26);
    ctx.closePath(); ctx.fill();
    if (lit) {
      const flick = 0.86 + Math.sin(this.t * 4.1 + p.seed) * 0.08;
      const rg = ctx.createRadialGradient(px, lampY - 10, 4, px, lampY - 10, 240 * flick);
      rg.addColorStop(0, 'rgba(255,236,190,0.95)');
      rg.addColorStop(0.25, 'rgba(255,196,110,0.42)');
      rg.addColorStop(1, 'rgba(255,160,60,0)');
      ctx.globalCompositeOperation = 'lighter';
      ctx.fillStyle = rg;
      ctx.beginPath(); ctx.arc(px, lampY - 10, 240 * flick, 0, TAU); ctx.fill();
      // 旋转光束
      const a = this.t * 0.42;
      for (const off of [0, Math.PI]) {
        const ang = a + off;
        ctx.save();
        ctx.translate(px, lampY - 10);
        ctx.rotate(ang);
        const bg = ctx.createLinearGradient(0, 0, 620, 0);
        bg.addColorStop(0, 'rgba(255,225,160,0.30)');
        bg.addColorStop(1, 'rgba(255,190,110,0)');
        ctx.fillStyle = bg;
        ctx.beginPath();
        ctx.moveTo(0, -6);
        ctx.lineTo(620, -70);
        ctx.lineTo(620, 70);
        ctx.lineTo(0, 6);
        ctx.closePath();
        ctx.fill();
        ctx.restore();
      }
      ctx.globalCompositeOperation = 'source-over';
      this.addLight(p.x, p.y, 520, 1, '#ffd79a');
    } else {
      ctx.fillStyle = 'rgba(255,150,60,0.35)';
      ctx.beginPath(); ctx.arc(px, lampY - 11, 4 + Math.sin(this.t * 3) * 0.8, 0, TAU); ctx.fill();
      this.addLight(p.x, p.y, 150, 0.35, '#ff9b5c');
    }
  }

  private drawBrazier(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    this.shadow(p.x, p.y, 20, 0.45);
    // 三脚架
    ctx.strokeStyle = '#2a2c34';
    ctx.lineWidth = 4;
    for (const dx of [-13, 0, 13]) {
      ctx.beginPath();
      ctx.moveTo(px + dx * 0.3, py - 26);
      ctx.lineTo(px + dx, py);
      ctx.stroke();
    }
    // 盆
    ctx.fillStyle = '#31323c';
    ctx.beginPath();
    ctx.ellipse(px, py - 28, 20, 8, 0, 0, TAU);
    ctx.fill();
    ctx.fillStyle = '#1e1f27';
    ctx.beginPath();
    ctx.ellipse(px, py - 26, 17, 6, 0, 0, TAU);
    ctx.fill();

    if (p.lit) {
      const f = 1 + Math.sin(this.t * 7 + p.seed) * 0.12;
      ctx.globalCompositeOperation = 'lighter';
      for (let i = 0; i < 3; i++) {
        const hgt = (26 + i * 12) * f;
        const wid = (13 - i * 3);
        const gg = ctx.createLinearGradient(px, py - 28 - hgt, px, py - 24);
        gg.addColorStop(0, i === 0 ? 'rgba(255,244,208,0.95)' : i === 1 ? 'rgba(255,190,90,0.7)' : 'rgba(255,120,40,0.45)');
        gg.addColorStop(1, 'rgba(255,120,40,0)');
        ctx.fillStyle = gg;
        ctx.beginPath();
        ctx.moveTo(px - wid, py - 26);
        ctx.quadraticCurveTo(px - wid * 0.6, py - 26 - hgt * 0.7, px + Math.sin(this.t * 3 + i) * 3, py - 28 - hgt);
        ctx.quadraticCurveTo(px + wid * 0.6, py - 26 - hgt * 0.7, px + wid, py - 26);
        ctx.closePath();
        ctx.fill();
      }
      const rg = ctx.createRadialGradient(px, py - 34, 4, px, py - 34, 230);
      rg.addColorStop(0, 'rgba(255,220,150,0.55)');
      rg.addColorStop(1, 'rgba(255,150,60,0)');
      ctx.fillStyle = rg;
      ctx.beginPath(); ctx.arc(px, py - 34, 230, 0, TAU); ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
      this.addLight(p.x, p.y, 250, 0.95, '#ffca70');
      if (world.highlightBrazier === p) this.drawRing(px, py, 40 + Math.sin(this.t * 5) * 3, 'rgba(255,214,130,0.5)');
    } else {
      // 余烬
      const e = 0.4 + Math.sin(this.t * 2.4 + p.seed) * 0.2;
      ctx.fillStyle = rgba('#ff7a3c', 0.30 * e + 0.12);
      ctx.beginPath(); ctx.ellipse(px, py - 27, 10, 4, 0, 0, TAU); ctx.fill();
      this.addLight(p.x, p.y, 90, 0.22, '#ff8a4a');
      const near = world.highlightBrazier === p;
      this.drawRing(px, py, near ? 46 + Math.sin(this.t * 6) * 3 : 40,
        near ? 'rgba(255,214,130,0.75)' : 'rgba(150,140,120,0.35)');
      if (near) {
        ctx.fillStyle = 'rgba(255,214,130,0.9)';
        ctx.font = 'bold 13px sans-serif';
        ctx.textAlign = 'center';
        ctx.fillText(world.player.combo >= 4 ? '可以点燃' : '连击不足', px, py - 58);
      }
    }
  }

  private drawRing(x: number, y: number, r: number, color: string) {
    const ctx = this.ctx;
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(1, YSQUASH);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([7, 6]);
    ctx.beginPath();
    ctx.arc(0, 0, r, 0, TAU);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.restore();
  }

  private drawMerchant(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    const bob = Math.sin(this.t * 1.6) * 2;
    this.shadow(p.x, p.y, 16, 0.4);
    // 长袍
    ctx.fillStyle = '#2c2338';
    ctx.beginPath();
    ctx.moveTo(px - 17, py);
    ctx.quadraticCurveTo(px - 11, py - 34, px - 8, py - 40 + bob);
    ctx.lineTo(px + 8, py - 40 + bob);
    ctx.quadraticCurveTo(px + 11, py - 34, px + 17, py);
    ctx.closePath(); ctx.fill();
    // 兜帽
    ctx.fillStyle = '#3a2f4a';
    ctx.beginPath();
    ctx.arc(px, py - 46 + bob, 11, Math.PI, TAU);
    ctx.fill();
    ctx.fillStyle = 'rgba(255,214,130,0.85)';
    ctx.beginPath();
    ctx.arc(px - 4, py - 44 + bob, 1.8, 0, TAU);
    ctx.arc(px + 4, py - 44 + bob, 1.8, 0, TAU);
    ctx.fill();
    // 灯杖
    ctx.strokeStyle = '#4a3c2a';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.moveTo(px + 18, py);
    ctx.lineTo(px + 22, py - 72 + bob);
    ctx.stroke();
    const lx = px + 22, ly = py - 78 + bob;
    const fl = 0.8 + Math.sin(this.t * 3.4) * 0.2;
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(lx, ly, 2, lx, ly, 120 * fl);
    rg.addColorStop(0, 'rgba(255,236,190,0.9)');
    rg.addColorStop(0.3, 'rgba(255,190,110,0.3)');
    rg.addColorStop(1, 'rgba(255,160,60,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(lx, ly, 120 * fl, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = '#ffeec2';
    ctx.beginPath(); ctx.arc(lx, ly, 4, 0, TAU); ctx.fill();
    this.addLight(p.x + 22, p.y - 6, 150, 0.7, '#ffd79a');
    // 招牌
    if (dist(world.player.x, world.player.y, p.x, p.y) < 130) {
      ctx.fillStyle = 'rgba(255,214,130,0.92)';
      ctx.font = 'bold 14px "Noto Serif CJK SC", serif';
      ctx.textAlign = 'center';
      ctx.fillText('掌灯人', px, py - 100 + bob);
    }
  }

  private drawDock(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    this.shadow(p.x, p.y, 40, 0.35);
    // 木栈道
    ctx.fillStyle = '#2a2418';
    ctx.beginPath();
    ctx.ellipse(px, py, 52, 18, 0, 0, TAU);
    ctx.fill();
    ctx.strokeStyle = '#3c3220';
    ctx.lineWidth = 2;
    for (let i = -2; i <= 2; i++) {
      ctx.beginPath();
      ctx.moveTo(px - 46, py + i * 6);
      ctx.lineTo(px + 46, py + i * 6);
      ctx.stroke();
    }
    // 挂灯
    const lx = px, ly = py - 92 + Math.sin(this.t * 1.4) * 2;
    ctx.strokeStyle = '#3a3226';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(px - 40, py - 60); ctx.lineTo(px - 40, ly); ctx.lineTo(px + 40, py - 60); ctx.stroke();
    ctx.fillStyle = '#2b2f3d';
    ctx.fillRect(lx - 8, ly, 16, 20);
    const lit = !!p.lit;
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(lx, ly + 10, 3, lx, ly + 10, lit ? 400 : 130);
    rg.addColorStop(0, lit ? 'rgba(255,240,200,0.9)' : 'rgba(255,200,140,0.5)');
    rg.addColorStop(1, 'rgba(255,170,80,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(lx, ly + 10, lit ? 400 : 130, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    this.addLight(p.x, p.y, lit ? 380 : 130, lit ? 0.9 : 0.45, '#ffd79a');
    ctx.fillStyle = 'rgba(255,214,130,0.92)';
    ctx.font = 'bold 14px "Noto Serif CJK SC", serif';
    ctx.textAlign = 'center';
    ctx.fillText('灯河渡口', px, py - 118);
  }

  private drawStatue(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    this.shadow(p.x, p.y, 20, 0.45);
    ctx.fillStyle = '#2c2f3c';
    ctx.beginPath();
    ctx.moveTo(px - 15, py);
    ctx.lineTo(px - 9, py - 54);
    ctx.lineTo(px + 9, py - 54);
    ctx.lineTo(px + 15, py);
    ctx.closePath(); ctx.fill();
    ctx.beginPath();
    ctx.arc(px, py - 60, 9, 0, TAU);
    ctx.fill();
    ctx.fillStyle = 'rgba(255,214,130,0.5)';
    ctx.beginPath();
    ctx.ellipse(px, py - 66, 12, 4, 0, 0, TAU); ctx.fill();
    this.addLight(p.x, p.y, 100, 0.3, '#ffcf86');
  }

  private drawPillar(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    this.shadow(p.x, p.y, 18, 0.4);
    const g = ctx.createLinearGradient(px - 16, 0, px + 16, 0);
    g.addColorStop(0, '#20242f');
    g.addColorStop(0.5, '#3c4256');
    g.addColorStop(1, '#1c202a');
    ctx.fillStyle = g;
    ctx.fillRect(px - 14, py - 66, 28, 66);
    ctx.fillStyle = '#333a4c';
    ctx.fillRect(px - 18, py - 8, 36, 8);
    ctx.strokeStyle = 'rgba(255,220,150,0.22)';
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    ctx.moveTo(px, py - 62); ctx.lineTo(px, py - 10);
    ctx.stroke();
  }

  private drawLantern(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    const bob = Math.sin(this.t * 1.2 + p.seed) * 3;
    this.shadow(p.x, p.y, 8, 0.3);
    ctx.strokeStyle = '#2a2c34';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(px, py);
    ctx.lineTo(px, py - 40);
    ctx.stroke();
    ctx.fillStyle = '#242833';
    ctx.beginPath();
    ctx.ellipse(px, py - 44 + bob, 9, 11, 0, 0, TAU);
    ctx.fill();
    const fl = 0.6 + Math.sin(this.t * 3.2 + p.seed) * 0.4;
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(px, py - 44 + bob, 2, px, py - 44 + bob, 100 * fl);
    rg.addColorStop(0, 'rgba(255,230,180,0.85)');
    rg.addColorStop(1, 'rgba(255,170,80,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(px, py - 44 + bob, 100 * fl, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    this.addLight(p.x, p.y - 8, 110, 0.55, '#ffd79a');
  }

  private drawTree(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    this.shadow(p.x, p.y, 14, 0.35);
    ctx.strokeStyle = '#1b1a20';
    ctx.lineCap = 'round';
    ctx.lineWidth = 5;
    ctx.beginPath();
    ctx.moveTo(px, py);
    ctx.lineTo(px + 2, py - 40);
    ctx.stroke();
    ctx.lineWidth = 2.6;
    for (let i = 0; i < 5; i++) {
      const a = -Math.PI / 2 + (i - 2) * 0.44;
      ctx.beginPath();
      ctx.moveTo(px + 1, py - 32 - i * 2);
      ctx.lineTo(px + Math.cos(a) * 24, py - 32 - i * 2 - Math.sin(-a) * 16 - 12);
      ctx.stroke();
    }
  }

  private drawRubble(world: World, p: Prop) {
    const ctx = this.ctx;
    const px = this.SX(p.x), py = this.SY(p.y, 0);
    const rnd = mulberry32(p.seed);
    for (let i = 0; i < 6; i++) {
      const dx = (rnd() - 0.5) * 32, dy = (rnd() - 0.5) * 12;
      const s = 3 + rnd() * 6;
      ctx.fillStyle = i % 2 ? '#242a38' : '#1b202c';
      ctx.beginPath();
      ctx.ellipse(px + dx, py + dy, s, s * 0.72, rnd() * 3, 0, TAU);
      ctx.fill();
    }
  }

  /* ============================ 角色 ============================ */

  private drawPlayer(world: World) {
    const ctx = this.ctx;
    const p = world.player;
    const px = this.SX(p.x);
    const bob = Math.abs(Math.sin(p.walkT)) * 2.2;
    const z = p.z + bob;
    const py = this.SY(p.y, z);
    const gy = this.SY(p.y, 0);
    const faceX = Math.cos(p.facing);

    // 死亡：熄灭
    if (p.dead) {
      const t = clamp(p.deathT / 1.2, 0, 1);
      ctx.globalAlpha = 1 - t;
      this.shadow(p.x, p.y, 16 * (1 - t * 0.4), 0.4);
      ctx.fillStyle = '#2a2e3c';
      ctx.beginPath();
      ctx.ellipse(px, gy - 16 * (1 - t), 18 * (1 - t * 0.5), 22 * (1 - t * 0.6), 0, 0, TAU);
      ctx.fill();
      ctx.globalAlpha = 1;
      return;
    }

    // 地面光池
    const lr = world.lightRadius;
    ctx.globalCompositeOperation = 'lighter';
    const pool = ctx.createRadialGradient(px, gy, 6, px, gy, lr * 0.55);
    pool.addColorStop(0, 'rgba(255,214,150,0.20)');
    pool.addColorStop(1, 'rgba(255,180,90,0)');
    ctx.fillStyle = pool;
    ctx.beginPath();
    ctx.ellipse(px, gy, lr * 0.55, lr * 0.55 * YSQUASH, 0, 0, TAU);
    ctx.fill();
    ctx.globalCompositeOperation = 'source-over';

    this.shadow(p.x, p.y, 15, 0.45);

    // 挥击轨迹
    if (p.attackT > 0) {
      const t = 1 - p.attackT / 0.2;
      const w = p.weapon;
      ctx.save();
      ctx.translate(px, gy);
      ctx.scale(1, YSQUASH);
      const a0 = p.facing - w.arc * 0.6;
      const a1 = p.facing + w.arc * 0.6;
      const sweep = a0 + (a1 - a0) * t;
      ctx.globalCompositeOperation = 'lighter';
      const gg = ctx.createRadialGradient(0, 0, w.range * 0.2, 0, 0, w.range);
      gg.addColorStop(0, 'rgba(255,240,200,0)');
      gg.addColorStop(0.75, rgba('#ffe3a8', 0.5 * (1 - t)));
      gg.addColorStop(1, 'rgba(255,190,90,0)');
      ctx.fillStyle = gg;
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.arc(0, 0, w.range, sweep - 0.9, sweep);
      ctx.closePath();
      ctx.fill();
      ctx.strokeStyle = rgba('#fff3d0', 0.75 * (1 - t));
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.arc(0, 0, w.range * 0.86, sweep - 0.7, sweep);
      ctx.stroke();
      ctx.restore();
      ctx.globalCompositeOperation = 'source-over';
    }

    // 冲刺残影
    if (p.dashT > 0) {
      ctx.globalCompositeOperation = 'lighter';
      ctx.fillStyle = 'rgba(255,220,160,0.16)';
      for (let i = 1; i <= 4; i++) {
        const bx = px - p.dashDx * i * 12;
        const by = py - p.dashDy * i * 12 * YSQUASH;
        ctx.beginPath();
        ctx.ellipse(bx, by - 20, 11 - i, 16 - i, 0, 0, TAU);
        ctx.fill();
      }
      ctx.globalCompositeOperation = 'source-over';
    }

    ctx.save();
    ctx.translate(px, py);
    const flip = faceX >= 0 ? 1 : -1;
    ctx.scale(flip, 1);

    // 斗篷
    const cloak = ctx.createLinearGradient(0, -46, 0, 0);
    cloak.addColorStop(0, '#4a5670');
    cloak.addColorStop(0.55, '#2f3749');
    cloak.addColorStop(1, '#1d2230');
    ctx.fillStyle = cloak;
    ctx.beginPath();
    ctx.moveTo(-13, 0);
    ctx.quadraticCurveTo(-14, -22, -8, -32);
    ctx.lineTo(8, -32);
    ctx.quadraticCurveTo(14, -22, 13, 0);
    ctx.quadraticCurveTo(0, 4, -13, 0);
    ctx.closePath();
    ctx.fill();
    // 胸口灯火
    const core = 0.6 + world.brightness01 * 0.4 + Math.sin(this.t * 5) * 0.06;
    ctx.globalCompositeOperation = 'lighter';
    const cg = ctx.createRadialGradient(0, -20, 1, 0, -20, 22 * core);
    cg.addColorStop(0, 'rgba(255,244,214,0.95)');
    cg.addColorStop(0.4, 'rgba(255,190,100,0.5)');
    cg.addColorStop(1, 'rgba(255,150,60,0)');
    ctx.fillStyle = cg;
    ctx.beginPath(); ctx.arc(0, -20, 22 * core, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';

    // 头盔
    ctx.fillStyle = '#3d4761';
    ctx.beginPath();
    ctx.arc(0, -36, 8.6, 0, TAU);
    ctx.fill();
    ctx.fillStyle = '#59657f';
    ctx.beginPath();
    ctx.arc(-2.4, -38.5, 4.4, 0, TAU);
    ctx.fill();
    // 面甲光缝
    ctx.globalCompositeOperation = 'lighter';
    ctx.fillStyle = '#ffe9b0';
    ctx.fillRect(-5.5, -37.5, 11, 2.6);
    ctx.globalCompositeOperation = 'source-over';

    // 提灯
    const lx = -13 * 1, ly = -22 + Math.sin(this.t * 2.6) * 1.4;
    ctx.strokeStyle = '#4d566d';
    ctx.lineWidth = 1.6;
    ctx.beginPath(); ctx.moveTo(-9, -30); ctx.lineTo(lx, ly - 5); ctx.stroke();
    ctx.fillStyle = '#20263a';
    ctx.beginPath(); ctx.arc(lx, ly, 4.4, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'lighter';
    ctx.fillStyle = '#ffdf9a';
    ctx.beginPath(); ctx.arc(lx, ly, 2.6, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';

    // 武器
    const w = p.weapon;
    const swing = p.attackT > 0 ? (1 - p.attackT / 0.2) : 0;
    const wAng = p.facing * flip + (swing > 0 ? (swing - 0.5) * 1.1 : 0.35);
    const wlen = w.style === 'thrust' ? 46 : w.style === 'smash' ? 34 : 30;
    const dirX = Math.cos(wAng), dirY = Math.sin(wAng) * YSQUASH;
    ctx.strokeStyle = '#cfd8ea';
    ctx.lineWidth = w.style === 'smash' ? 5 : w.style === 'thrust' ? 2.4 : 3.2;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(dirX * 6, -22 + dirY * 6);
    ctx.lineTo(dirX * wlen, -22 + dirY * wlen);
    ctx.stroke();
    if (w.style === 'smash') {
      ctx.fillStyle = '#8e97ab';
      ctx.beginPath();
      ctx.arc(dirX * wlen, -22 + dirY * wlen, 7, 0, TAU);
      ctx.fill();
    }
    ctx.restore();

    // 连击光环
    if (p.combo > 1) {
      const k = clamp(p.combo / 40, 0, 1);
      ctx.globalCompositeOperation = 'lighter';
      const rg = ctx.createRadialGradient(px, gy - 20, 4, px, gy - 20, 60 + k * 90);
      rg.addColorStop(0, rgba('#ffe9b0', 0.18 + k * 0.22));
      rg.addColorStop(1, 'rgba(255,170,60,0)');
      ctx.fillStyle = rg;
      ctx.beginPath();
      ctx.arc(px, gy - 20, 60 + k * 90, 0, TAU);
      ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
    }

    this.addLight(p.x, p.y, lr, 1.15, world.prog.blindGirl ? '#fff0c8' : '#ffd79a');
  }

  private drawEnemy(world: World, e: Enemy) {
    const ctx = this.ctx;
    const spawn = e.state === 'spawn' ? clamp(1 - e.spawnT / 0.45, 0, 1) : 1;
    const death = e.dead ? clamp(e.deathT / 0.6, 0, 1) : 0;
    const alpha = spawn * (1 - death);
    if (alpha <= 0.02) return;
    const px = this.SX(e.x);
    const float = e.def.behavior === 'chase' ? Math.sin(this.t * 3 + e.wob) * 3 : 0;
    const py = this.SY(e.y, e.z + float);
    const gy = this.SY(e.y, 0);
    const def = e.def;

    ctx.globalAlpha = alpha;
    this.shadow(e.x, e.y, e.r * (1 - death * 0.5), 0.35 * alpha);

    // 蓄力预警
    if (e.state === 'windup' && def.behavior !== 'chase') {
      const t = e.t / def.wind;
      ctx.save();
      ctx.translate(px, gy);
      ctx.scale(1, YSQUASH);
      ctx.strokeStyle = rgba('#ff8a5a', 0.35 + t * 0.5);
      ctx.lineWidth = 3;
      if (def.behavior === 'spitter') {
        ctx.beginPath(); ctx.arc(0, 0, 26 + t * 10, 0, TAU); ctx.stroke();
      } else {
        const a = Math.atan2(world.player.y - e.y, world.player.x - e.x);
        ctx.beginPath();
        ctx.arc(0, 0, def.atkRange + 16, a - 0.75, a + 0.75);
        ctx.stroke();
      }
      ctx.restore();
    }

    const hit = e.hitFlash > 0;
    ctx.save();
    ctx.translate(px, py);
    if (hit) {
      ctx.globalCompositeOperation = 'lighter';
    }

    if (def.behavior === 'boss') this.drawBossBody(world, e);
    else if (def.id === 'guard') this.drawGuardBody(world, e);
    else if (def.id === 'leech') this.drawLeechBody(world, e);
    else this.drawShadeBody(world, e);

    ctx.restore();
    ctx.globalCompositeOperation = 'source-over';

    // 血条
    if (!e.dead && e.hp < e.maxHp && def.behavior !== 'boss') {
      const bw = e.r * 2.1;
      ctx.fillStyle = 'rgba(0,0,0,0.6)';
      ctx.fillRect(px - bw / 2, gy - e.h - 18, bw, 4);
      ctx.fillStyle = e.elite ? '#ffd070' : '#d8543f';
      ctx.fillRect(px - bw / 2, gy - e.h - 18, bw * clamp(e.hp / e.maxHp, 0, 1), 4);
    }
    if (e.elite) {
      ctx.fillStyle = 'rgba(255,224,138,0.95)';
      ctx.font = 'bold 11px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('◆ 精英', px, gy - e.h - 24);
    }

    // 死亡灰烬
    if (e.dead && e.deathT < 0.6) {
      ctx.globalCompositeOperation = 'lighter';
      ctx.fillStyle = rgba(def.glow, 0.3 * (1 - death));
      ctx.beginPath();
      ctx.arc(px, py - e.h * 0.4, e.r * (1 + death * 2), 0, TAU);
      ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
    }
    ctx.globalAlpha = 1;

    if (def.light) this.addLight(e.x, e.y, def.light * 3.4, e.dead ? 0.1 : 0.42, def.glow);
  }

  private drawShadeBody(world: World, e: Enemy) {
    const ctx = this.ctx;
    const def = e.def;
    const r = e.r, h = e.h;
    ctx.fillStyle = rgba(def.body, 0.92);
    ctx.beginPath();
    ctx.moveTo(-r, 0);
    for (let i = 0; i <= 12; i++) {
      const a = Math.PI * (i / 12);
      const wob = 1 + Math.sin(this.t * 4 + i * 1.3 + e.wob) * 0.12;
      ctx.lineTo(-Math.cos(a) * r * wob, -Math.sin(a) * h * wob);
    }
    ctx.closePath();
    ctx.fill();
    // 触须
    ctx.strokeStyle = rgba(def.body, 0.8);
    ctx.lineWidth = 2;
    for (let i = -2; i <= 2; i++) {
      ctx.beginPath();
      ctx.moveTo(i * 5, -2);
      ctx.quadraticCurveTo(i * 8 + Math.sin(this.t * 5 + i) * 4, 6, i * 10 + Math.sin(this.t * 5 + i) * 6, 12);
      ctx.stroke();
    }
    // 眼
    const glow = e.state === 'windup' ? 1 : 0.7;
    ctx.globalCompositeOperation = 'lighter';
    ctx.fillStyle = rgba(def.glow, glow);
    ctx.beginPath();
    ctx.arc(-4.5, -h * 0.68, 2.6, 0, TAU);
    ctx.arc(4.5, -h * 0.68, 2.6, 0, TAU);
    ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
  }

  private drawGuardBody(world: World, e: Enemy) {
    const ctx = this.ctx;
    const def = e.def;
    const r = e.r, h = e.h;
    // 躯干
    const g = ctx.createLinearGradient(0, -h, 0, 0);
    g.addColorStop(0, '#4a3a28');
    g.addColorStop(1, def.body);
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(-r * 0.8, 0);
    ctx.lineTo(-r * 0.72, -h * 0.78);
    ctx.lineTo(r * 0.72, -h * 0.78);
    ctx.lineTo(r * 0.8, 0);
    ctx.closePath(); ctx.fill();
    // 头
    ctx.fillStyle = '#3a2e20';
    ctx.beginPath(); ctx.arc(0, -h * 0.86, r * 0.4, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'lighter';
    ctx.fillStyle = rgba(def.glow, 0.95);
    ctx.fillRect(-r * 0.28, -h * 0.88, r * 0.56, 3);
    ctx.globalCompositeOperation = 'source-over';
    // 裂缝
    ctx.strokeStyle = rgba(def.glow, 0.5 + Math.sin(this.t * 4 + e.wob) * 0.2);
    ctx.lineWidth = 1.6;
    ctx.beginPath();
    ctx.moveTo(-r * 0.4, -h * 0.6); ctx.lineTo(-r * 0.1, -h * 0.4); ctx.lineTo(-r * 0.3, -h * 0.2);
    ctx.moveTo(r * 0.35, -h * 0.66); ctx.lineTo(r * 0.12, -h * 0.42);
    ctx.stroke();
    // 武器（大砍刀）
    const frac = e.state === 'windup' ? -0.9 + e.t / def.wind * 0.9 : e.state === 'attack' ? 0.6 : 0.15;
    ctx.save();
    ctx.rotate(frac * 0.9 * e.facing);
    ctx.strokeStyle = '#5d6579';
    ctx.lineWidth = 5;
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(e.facing * r * 0.6, -h * 0.55);
    ctx.lineTo(e.facing * (r * 0.6 + 26), -h * 0.55 - 8);
    ctx.stroke();
    ctx.restore();
    if (e.elite) {
      ctx.fillStyle = 'rgba(255,224,138,0.85)';
      ctx.beginPath();
      ctx.moveTo(-5, -h * 1.02); ctx.lineTo(-2, -h * 1.14); ctx.lineTo(1, -h * 1.03);
      ctx.lineTo(4, -h * 1.15); ctx.lineTo(6, -h * 1.0);
      ctx.closePath(); ctx.fill();
    }
  }

  private drawLeechBody(world: World, e: Enemy) {
    const ctx = this.ctx;
    const def = e.def;
    const pulse = 1 + Math.sin(this.t * 6 + e.wob) * 0.12;
    const wind = e.state === 'windup' ? 1.5 : 1;
    ctx.fillStyle = def.body;
    ctx.beginPath();
    ctx.ellipse(0, -e.h * 0.5, e.r * pulse, e.h * 0.5 * pulse, 0, 0, TAU);
    ctx.fill();
    // 腿
    ctx.strokeStyle = '#2a2033';
    ctx.lineWidth = 2.2;
    for (let i = 0; i < 4; i++) {
      const a = 0.6 + i * 0.55;
      ctx.beginPath();
      ctx.moveTo(0, -e.h * 0.3);
      ctx.lineTo(Math.cos(a) * e.r * 1.5, -e.h * 0.3 + Math.sin(a) * 6 + 6);
      ctx.stroke();
    }
    // 光囊
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(0, -e.h * 0.62, 1, 0, -e.h * 0.62, 16 * wind);
    rg.addColorStop(0, 'rgba(255,255,255,0.95)');
    rg.addColorStop(0.4, rgba(def.glow, 0.7));
    rg.addColorStop(1, 'rgba(255,80,120,0)');
    ctx.fillStyle = rg;
    ctx.beginPath();
    ctx.arc(0, -e.h * 0.62, 16 * wind, 0, TAU);
    ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
  }

  private drawBossBody(world: World, e: Enemy) {
    const ctx = this.ctx;
    const def = e.def;
    const sc = def.bossScale ?? 1;
    const r = e.r * sc, h = e.h * sc;
    const phase = e.boss?.phase ?? 1;
    const accent = def.bossStyle === 'shadow' ? '#c9a6ff' : phase >= 3 ? '#ff4f7a' : phase === 2 ? '#ff7a3c' : '#ff9b5c';
    const breathe = 1 + Math.sin(this.t * 2.2) * 0.03;

    // 腿
    ctx.strokeStyle = '#140d16';
    ctx.lineWidth = r * 0.28;
    ctx.lineCap = 'round';
    for (const s of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(s * r * 0.5, -h * 0.42);
      ctx.lineTo(s * r * 1.15, -h * 0.2);
      ctx.lineTo(s * r * 1.2, 0);
      ctx.stroke();
    }
    // 躯干
    const g = ctx.createLinearGradient(0, -h, 0, 0);
    g.addColorStop(0, '#3a2230');
    g.addColorStop(0.6, def.body);
    g.addColorStop(1, '#0d0810');
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(-r * 0.85 * breathe, 0);
    ctx.quadraticCurveTo(-r * 1.15, -h * 0.55, -r * 0.6, -h * 0.95);
    ctx.lineTo(r * 0.6, -h * 0.95);
    ctx.quadraticCurveTo(r * 1.15, -h * 0.55, r * 0.85 * breathe, 0);
    ctx.closePath();
    ctx.fill();
    // 手臂
    ctx.strokeStyle = def.body;
    ctx.lineWidth = r * 0.22;
    for (const s of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(s * r * 0.7, -h * 0.78);
      ctx.quadraticCurveTo(s * r * 1.5, -h * 0.7, s * r * 1.35, -h * 0.2);
      ctx.stroke();
    }
    // 角
    ctx.fillStyle = '#221620';
    for (const s of [-1, 1]) {
      ctx.beginPath();
      ctx.moveTo(s * r * 0.32, -h * 0.95);
      ctx.quadraticCurveTo(s * r * 0.75, -h * 1.25, s * r * 0.42, -h * 1.12);
      ctx.lineTo(s * r * 0.2, -h * 0.98);
      ctx.closePath(); ctx.fill();
    }
    // 巨口（吞噬漩涡）
    const my = -h * 0.72;
    const mouthR = r * 0.34 + Math.sin(this.t * 3) * r * 0.03;
    ctx.fillStyle = '#07040a';
    ctx.beginPath(); ctx.arc(0, my, mouthR, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'lighter';
    for (let i = 0; i < 3; i++) {
      const t = this.t * 1.6 + i * 2.1;
      ctx.strokeStyle = rgba(accent, 0.55 - i * 0.12);
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(0, my, mouthR * (0.3 + i * 0.22), t, t + 3.4);
      ctx.stroke();
    }
    // 牙
    ctx.fillStyle = 'rgba(240,230,220,0.8)';
    for (let i = 0; i < 7; i++) {
      const a = (i / 7) * TAU + this.t * 0.3;
      const tx = Math.cos(a) * mouthR, ty = my + Math.sin(a) * mouthR;
      ctx.beginPath();
      ctx.moveTo(tx, ty);
      ctx.lineTo(tx - Math.cos(a) * mouthR * 0.32 - 2, ty - Math.sin(a) * mouthR * 0.32);
      ctx.lineTo(tx + 2, ty + 1);
      ctx.closePath(); ctx.fill();
    }
    // 眼
    ctx.fillStyle = rgba(accent, 0.95);
    ctx.beginPath();
    ctx.ellipse(-r * 0.3, -h * 0.88, r * 0.1, r * 0.05, 0, 0, TAU);
    ctx.ellipse(r * 0.3, -h * 0.88, r * 0.1, r * 0.05, 0, 0, TAU);
    ctx.fill();
    ctx.globalCompositeOperation = 'source-over';

    // 蓄力时口部发光
    if (e.boss && e.boss.action) {
      ctx.globalCompositeOperation = 'lighter';
      const rg = ctx.createRadialGradient(0, my, 2, 0, my, r * (e.boss.action === 'drain' ? 2.2 : 1.2));
      rg.addColorStop(0, rgba(accent, 0.6));
      rg.addColorStop(1, 'rgba(255,60,40,0)');
      ctx.fillStyle = rg;
      ctx.beginPath(); ctx.arc(0, my, r * (e.boss.action === 'drain' ? 2.2 : 1.2), 0, TAU); ctx.fill();
      ctx.globalCompositeOperation = 'source-over';
    }
  }

  private drawGirl(world: World) {
    const ctx = this.ctx;
    const g = world.girl!;
    const px = this.SX(g.x);
    const bob = Math.sin(this.t * 1.7) * 2.4;
    const py = this.SY(g.y, bob);
    const gy = this.SY(g.y, 0);
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(px, py - 22, 3, px, py - 22, 150);
    rg.addColorStop(0, 'rgba(255,255,250,0.35)');
    rg.addColorStop(1, 'rgba(220,230,255,0)');
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(px, py - 22, 150, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    this.shadow(g.x, g.y, 11, 0.3);
    // 裙
    ctx.fillStyle = 'rgba(238,240,248,0.92)';
    ctx.beginPath();
    ctx.moveTo(px - 11, gy);
    ctx.quadraticCurveTo(px - 8, py - 20, px - 5, py - 26);
    ctx.lineTo(px + 5, py - 26);
    ctx.quadraticCurveTo(px + 8, py - 20, px + 11, gy);
    ctx.closePath(); ctx.fill();
    // 头
    ctx.fillStyle = 'rgba(246,246,252,0.96)';
    ctx.beginPath(); ctx.arc(px, py - 32, 6.6, 0, TAU); ctx.fill();
    // 白发
    ctx.strokeStyle = 'rgba(255,255,255,0.9)';
    ctx.lineWidth = 2;
    for (let i = -1; i <= 1; i++) {
      ctx.beginPath();
      ctx.moveTo(px + i * 3.4, py - 34);
      ctx.quadraticCurveTo(px + i * 5 + Math.sin(this.t + i) * 2, py - 18, px + i * 4.6, py - 8);
      ctx.stroke();
    }
    // 闭眼
    ctx.strokeStyle = 'rgba(120,130,160,0.9)';
    ctx.lineWidth = 1.2;
    ctx.beginPath();
    ctx.arc(px - 2.4, py - 32, 2.2, 0.15, Math.PI - 0.15);
    ctx.arc(px + 2.4, py - 32, 2.2, 0.15, Math.PI - 0.15);
    ctx.stroke();
    this.addLight(g.x, g.y, 170, 0.72, '#eef2ff');
    // 呼吸般的微尘
    if (Math.random() < 0.35) {
      world.addParticle(g.x + rand(-8, 8), g.y + rand(-6, 6), rand(8, 34), {
        vx: rand(-6, 6), vy: rand(-6, 6), vz: rand(8, 22), life: rand(0.8, 1.8),
        size: rand(1, 2.2), color: '#ffffff', glow: true, drag: 1.2, grav: -6,
      });
    }
  }

  /* ============================ 投射物 / 粒子 / 文字 ============================ */

  private drawDrop(world: World, d: Drop) {
    const ctx = this.ctx;
    const px = this.SX(d.x);
    const bob = Math.sin(this.t * 3.4 + d.x * 0.05) * 3;
    const py = this.SY(d.y, d.z + bob);
    const gy = this.SY(d.y, 0);
    const color = d.kind === 'coin' ? '#ffc861' : d.kind === 'wick' ? '#fff0c0' : '#9fe6ff';
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(px, py, 1, px, py, d.kind === 'wick' ? 46 : 28);
    rg.addColorStop(0, rgba(color, 0.95));
    rg.addColorStop(1, rgba(color, 0));
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(px, py, d.kind === 'wick' ? 46 : 28, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = color;
    if (d.kind === 'coin') {
      ctx.beginPath();
      ctx.moveTo(px, py - 7);
      ctx.quadraticCurveTo(px + 5, py, px, py + 5);
      ctx.quadraticCurveTo(px - 5, py, px, py - 7);
      ctx.fill();
    } else if (d.kind === 'wick') {
      ctx.fillRect(px - 1.6, py - 10, 3.2, 16);
      ctx.fillStyle = '#fff8e0';
      ctx.beginPath(); ctx.arc(px, py - 10, 3.4, 0, TAU); ctx.fill();
    } else {
      ctx.fillRect(px - 4, py - 9, 8, 14);
      ctx.fillStyle = '#d8f6ff';
      ctx.fillRect(px - 2, py - 14, 4, 5);
    }
    ctx.globalAlpha = 0.28;
    ctx.fillStyle = '#000';
    ctx.beginPath();
    ctx.ellipse(px, gy, 6, 3, 0, 0, TAU);
    ctx.fill();
    ctx.globalAlpha = 1;
    this.addLight(d.x, d.y, d.kind === 'wick' ? 130 : 70, 0.34, color);
  }

  private drawProj(world: World, q: Proj) {
    const ctx = this.ctx;
    const px = this.SX(q.x), py = this.SY(q.y, q.z);
    ctx.globalCompositeOperation = 'lighter';
    const rg = ctx.createRadialGradient(px, py, 1, px, py, q.r * 3.4);
    rg.addColorStop(0, 'rgba(255,255,255,0.95)');
    rg.addColorStop(0.35, rgba(q.color, 0.7));
    rg.addColorStop(1, rgba(q.color, 0));
    ctx.fillStyle = rg;
    ctx.beginPath(); ctx.arc(px, py, q.r * 3.4, 0, TAU); ctx.fill();
    ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = '#fff';
    ctx.beginPath(); ctx.arc(px, py, q.r * 0.45, 0, TAU); ctx.fill();
    this.addLight(q.x, q.y, 90, 0.35, q.color);
  }

  private drawParticle(world: World, p: Particle) {
    const ctx = this.ctx;
    const t = p.life / p.maxLife;
    const px = this.SX(p.x), py = this.SY(p.y, p.z);
    if (px < -40 || px > this.W + 40 || py < -40 || py > this.H + 40) return;
    ctx.globalAlpha = clamp(t, 0, 1) * (p.glow ? 0.95 : 0.6);
    ctx.fillStyle = p.color;
    if (p.glow) {
      ctx.beginPath();
      ctx.arc(px, py, p.size * (0.6 + t * 0.7), 0, TAU);
      ctx.fill();
      // 拖尾
      ctx.globalAlpha *= 0.5;
      ctx.beginPath();
      ctx.arc(px - p.vx * 0.012, py - p.vy * 0.012 * YSQUASH, p.size * 0.7 * t, 0, TAU);
      ctx.fill();
    } else {
      ctx.beginPath();
      ctx.arc(px, py, p.size, 0, TAU);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  private drawFloatText(world: World, t: { x: number; y: number; z: number; text: string; color: string; size: number; life: number; maxLife: number }) {
    const ctx = this.ctx;
    const a = clamp(t.life / t.maxLife, 0, 1);
    const px = this.SX(t.x), py = this.SY(t.y, t.z);
    ctx.globalAlpha = a;
    ctx.font = `bold ${t.size}px "Noto Sans CJK SC", sans-serif`;
    ctx.textAlign = 'center';
    ctx.lineWidth = 3;
    ctx.strokeStyle = 'rgba(0,0,0,0.75)';
    ctx.strokeText(t.text, px, py);
    ctx.fillStyle = t.color;
    ctx.fillText(t.text, px, py);
    ctx.globalAlpha = 1;
  }

  /* ============================ 特效 ============================ */

  private drawEffectGround(world: World, f: Effect) {
    const ctx = this.ctx;
    const px = this.SX(f.x), py = this.SY(f.y, 0);
    const t = 1 - f.life / f.maxLife;
    if (f.delay > 0) {
      // 落灯预警
      ctx.save();
      ctx.translate(px, py);
      ctx.scale(1, YSQUASH);
      ctx.strokeStyle = rgba(f.color, 0.35 + t * 0.6);
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(0, 0, f.r1, 0, TAU);
      ctx.stroke();
      ctx.fillStyle = rgba(f.color, 0.1 + t * 0.18);
      ctx.beginPath(); ctx.arc(0, 0, f.r1 * t, 0, TAU); ctx.fill();
      ctx.restore();
      return;
    }
    if (f.kind === 'slash') {
      ctx.save();
      ctx.translate(px, py);
      ctx.scale(1, YSQUASH);
      ctx.globalCompositeOperation = 'lighter';
      const alpha = (1 - t) * (f.own === 'enemy' ? 0.55 : 0.7);
      const grad = ctx.createRadialGradient(0, 0, f.r0, 0, 0, f.r1);
      grad.addColorStop(0, rgba(f.color, 0));
      grad.addColorStop(0.8, rgba(f.color, alpha * 0.55));
      grad.addColorStop(1, rgba(f.color, 0));
      ctx.fillStyle = grad;
      ctx.beginPath();
      ctx.moveTo(0, 0);
      const sweep = f.angle + f.w / 2 * (1 - 2 * t);
      ctx.arc(0, 0, f.r1, f.angle - f.w / 2, sweep);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
      ctx.globalCompositeOperation = 'source-over';
      return;
    }
    const r = f.r0 + (f.r1 - f.r0) * t;
    ctx.save();
    ctx.translate(px, py);
    ctx.scale(1, YSQUASH);
    ctx.globalCompositeOperation = 'lighter';
    const alpha = (1 - t) * 0.85;
    const grad = ctx.createRadialGradient(0, 0, r * 0.35, 0, 0, r);
    grad.addColorStop(0, rgba(f.color, alpha * 0.25));
    grad.addColorStop(0.72, rgba(f.color, alpha * 0.55));
    grad.addColorStop(1, rgba(f.color, 0));
    ctx.fillStyle = grad;
    ctx.beginPath(); ctx.arc(0, 0, r, 0, TAU); ctx.fill();
    ctx.strokeStyle = rgba(f.color, alpha);
    ctx.lineWidth = 3 * (1 - t) + 1;
    ctx.beginPath(); ctx.arc(0, 0, r, 0, TAU); ctx.stroke();
    ctx.restore();
    ctx.globalCompositeOperation = 'source-over';
    if (f.own === 'player') this.addLight(f.x, f.y, r * 1.1, 0.5 * (1 - t), f.color);
  }

  private drawEffectBeam(world: World, f: Effect) {
    const ctx = this.ctx;
    const t = 1 - f.life / f.maxLife;
    const px = this.SX(f.x), py = this.SY(f.y, f.z ?? 20);
    const dx = Math.cos(f.angle), dy = Math.sin(f.angle) * YSQUASH;
    const alpha = (1 - t) * 0.9;

    if (f.kind === 'pillar') {
      const gx = this.SX(f.x), gy = this.SY(f.y, 0);
      if (f.delay > 0) return;
      const hgt = 460;
      const w = f.r1 * 0.5;
      const g = ctx.createLinearGradient(gx, gy - hgt, gx, gy);
      g.addColorStop(0, rgba(f.color, 0));
      g.addColorStop(0.25, rgba(f.color, alpha * 0.5));
      g.addColorStop(1, rgba(f.color, alpha * 0.85));
      ctx.fillStyle = g;
      const ww = w * (0.6 + t * 0.6);
      ctx.beginPath();
      ctx.moveTo(gx - ww, gy);
      ctx.lineTo(gx - ww * 0.45, gy - hgt);
      ctx.lineTo(gx + ww * 0.45, gy - hgt);
      ctx.lineTo(gx + ww, gy);
      ctx.closePath();
      ctx.fill();
      const rg = ctx.createRadialGradient(gx, gy, 4, gx, gy, f.r1 * 1.4);
      rg.addColorStop(0, rgba(f.color, alpha * 0.9));
      rg.addColorStop(1, rgba(f.color, 0));
      ctx.fillStyle = rg;
      ctx.beginPath();
      ctx.ellipse(gx, gy, f.r1 * 1.4, f.r1 * 1.4 * YSQUASH, 0, 0, TAU);
      ctx.fill();
      this.addLight(f.x, f.y, 420, 1, f.color);
      return;
    }

    // 光束
    const len = f.len;
    const w = f.w;
    const nx = -dy, ny = dx;
    ctx.save();
    ctx.globalCompositeOperation = 'lighter';
    const g = ctx.createLinearGradient(px, py, px + dx * len, py + dy * len);
    g.addColorStop(0, rgba(f.color, alpha * 0.95));
    g.addColorStop(0.5, rgba(f.color, alpha * 0.6));
    g.addColorStop(1, rgba(f.color, 0));
    ctx.fillStyle = g;
    ctx.beginPath();
    ctx.moveTo(px - nx * w * 0.5, py - ny * w * 0.5);
    ctx.lineTo(px + nx * w * 0.5, py + ny * w * 0.5);
    ctx.lineTo(px + dx * len + nx * w * 0.15, py + dy * len + ny * w * 0.15);
    ctx.lineTo(px + dx * len - nx * w * 0.15, py + dy * len - ny * w * 0.15);
    ctx.closePath();
    ctx.fill();
    ctx.strokeStyle = rgba(f.color, alpha);
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(px, py);
    ctx.lineTo(px + dx * len, py + dy * len);
    ctx.stroke();
    ctx.restore();
    ctx.globalCompositeOperation = 'source-over';
    this.addLight(f.x + Math.cos(f.angle) * len * 0.4, f.y + Math.sin(f.angle) * len * 0.4, 300, 0.7, f.color);
  }

  /* ============================ 光照合成 ============================ */

  private applyLighting(world: World) {
    const ctx = this.ctx;
    const dctx = this.dctx;
    dctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    dctx.globalCompositeOperation = 'source-over';
    dctx.clearRect(0, 0, this.W, this.H);
    dctx.fillStyle = `rgba(3,4,10,${world.ambient})`;
    dctx.fillRect(0, 0, this.W, this.H);

    dctx.globalCompositeOperation = 'destination-out';
    for (const l of this.lights) {
      const px = this.SX(l.x) - this.shx, py = this.SY(l.y, 0) - this.shy;
      const r = l.r;
      if (px + r < 0 || px - r > this.W || py + r < 0 || py - r > this.H) continue;
      const p = clamp(l.power, 0, 1.2);
      // 椭圆（贴地光照）
      dctx.save();
      dctx.translate(px, py);
      dctx.scale(1, YSQUASH);
      const g = dctx.createRadialGradient(0, 0, r * 0.05, 0, 0, r);
      g.addColorStop(0, `rgba(0,0,0,${p})`);
      g.addColorStop(0.45, `rgba(0,0,0,${p * 0.72})`);
      g.addColorStop(0.75, `rgba(0,0,0,${p * 0.28})`);
      g.addColorStop(1, 'rgba(0,0,0,0)');
      dctx.fillStyle = g;
      dctx.beginPath();
      dctx.arc(0, 0, r, 0, TAU);
      dctx.fill();
      dctx.restore();
    }
    dctx.globalCompositeOperation = 'source-over';

    ctx.drawImage(this.dark, 0, 0, this.W, this.H);

    // 暖色加光：让"光"是有温度的
    ctx.globalCompositeOperation = 'lighter';
    for (const l of this.lights) {
      const px = this.SX(l.x), py = this.SY(l.y, 0);
      const r = l.r * 0.85;
      if (px + r < 0 || px - r > this.W || py + r < 0 || py - r > this.H) continue;
      ctx.save();
      ctx.translate(px, py);
      ctx.scale(1, YSQUASH);
      const g = ctx.createRadialGradient(0, 0, r * 0.05, 0, 0, r);
      g.addColorStop(0, rgba(l.color, 0.16 * l.power));
      g.addColorStop(0.5, rgba(l.color, 0.07 * l.power));
      g.addColorStop(1, rgba(l.color, 0));
      ctx.fillStyle = g;
      ctx.beginPath(); ctx.arc(0, 0, r, 0, TAU); ctx.fill();
      ctx.restore();
    }
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
  }

  private drawFlash(world: World) {
    const ctx = this.ctx;
    if (world.flash.power > 0.01) {
      const p = clamp(world.flash.power, 0, 1);
      if (world.flash.color === '#000000') {
        ctx.fillStyle = `rgba(0,0,0,${p})`;
        ctx.fillRect(0, 0, this.W, this.H);
      } else {
        ctx.globalCompositeOperation = 'lighter';
        ctx.fillStyle = rgba(world.flash.color, p * 0.42);
        ctx.fillRect(0, 0, this.W, this.H);
        ctx.globalCompositeOperation = 'source-over';
      }
    }
    // 濒死：屏幕边缘泛红
    const hp01 = world.player.hp / world.player.maxHp;
    if (hp01 < 0.32 && !world.player.dead) {
      const pulse = 0.16 + Math.sin(this.t * 5) * 0.06;
      const g = ctx.createRadialGradient(this.W / 2, this.H / 2, Math.min(this.W, this.H) * 0.28, this.W / 2, this.H / 2, Math.max(this.W, this.H) * 0.62);
      g.addColorStop(0, 'rgba(140,20,20,0)');
      g.addColorStop(1, `rgba(150,24,20,${pulse + (0.32 - hp01) * 1.2})`);
      ctx.fillStyle = g;
      ctx.fillRect(0, 0, this.W, this.H);
    }
    if (world.player.dead) {
      const t = clamp(world.player.deathT / 2.2, 0, 1);
      ctx.fillStyle = `rgba(0,0,0,${t * 0.9})`;
      ctx.fillRect(0, 0, this.W, this.H);
    }
  }

  /** 屏幕外目标指示：灯塔 / 渡口 / 未点亮的火盆 */
  private drawMarkers(world: World) {
    const ctx = this.ctx;
    const targets: { x: number; y: number; color: string; label: string }[] = [];
    if (world.goalProp && !(world.goalProp.kind === 'lighthouse' && !world.cleared)) {
      targets.push({ x: world.goalProp.x, y: world.goalProp.y, color: '#ffd070', label: world.level.goal.name });
    }
    if (world.goalProp && world.goalProp.kind === 'lighthouse' && !world.cleared) {
      targets.push({ x: world.level.boss.x, y: world.level.boss.y, color: '#ff8a5a', label: world.level.boss.label });
    }
    for (const b of world.braziers) {
      if (!b.lit && (world.level.braziersRequired ?? 0) > 0) {
        targets.push({ x: b.x, y: b.y, color: '#ffb765', label: '火盆' });
      }
    }
    // 未清完的波次也给出方向指引
    if (!world.cleared) {
      for (const wv of world.waves) {
        if (wv.cleared) continue;
        targets.push({
          x: wv.def.x, y: wv.def.y,
          color: wv.spawned ? '#ff9b5c' : '#9fd8ff',
          label: wv.spawned ? '残敌' : '敌影',
        });
      }
    }
    const pad = 42;
    for (const t of targets) {
      const px = this.SX(t.x), py = this.SY(t.y, 30);
      const inView = px > pad && px < this.W - pad && py > pad && py < this.H - pad;
      if (inView) continue;
      const cx = clamp(px, pad, this.W - pad);
      const cy = clamp(py, pad + 40, this.H - pad);
      const a = Math.atan2(py - this.H / 2, px - this.W / 2);
      ctx.save();
      ctx.translate(cx, cy);
      ctx.rotate(a);
      ctx.fillStyle = rgba(t.color, 0.85);
      ctx.beginPath();
      ctx.moveTo(12, 0); ctx.lineTo(-6, -7); ctx.lineTo(-6, 7);
      ctx.closePath(); ctx.fill();
      ctx.restore();
      const d = Math.round(dist(world.player.x, world.player.y, t.x, t.y) / 32);
      ctx.fillStyle = rgba(t.color, 0.9);
      ctx.font = 'bold 11px sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText(`${t.label} ${d}m`, cx, cy + 22);
    }
  }
}
