/* ============================================================
   utils.ts — 数学、随机数、2.5D 斜投影
   世界坐标：x 向右，y 向"下/远"（俯视平面），z 向上（高度）。
   投影方式为斜轴测（oblique）：屏幕 y = 世界 y * 压扁系数 - 高度。
   这带来 2.5D 的立体观感：地面被压扁，物体按高度"立"起来。
   ============================================================ */

export const TAU = Math.PI * 2;
/** 俯视地面的纵向压扁系数，越小越"斜视角" */
export const YSQUASH = 0.62;

export interface Cam { x: number; y: number; }

export const clamp = (v: number, a: number, b: number) => (v < a ? a : v > b ? b : v);
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
/** 帧率无关的指数趋近 */
export const damp = (a: number, b: number, rate: number, dt: number) => lerp(a, b, 1 - Math.exp(-rate * dt));
export const rand = (a: number, b: number) => a + Math.random() * (b - a);
export const randInt = (a: number, b: number) => Math.floor(a + Math.random() * (b - a + 1));
export const pick = <T,>(arr: T[]): T => arr[Math.floor(Math.random() * arr.length)];
export const chance = (p: number) => Math.random() < p;
export const sign = (v: number) => (v < 0 ? -1 : 1);

export const dist = (ax: number, ay: number, bx: number, by: number) => Math.hypot(bx - ax, by - ay);
export const dist2 = (ax: number, ay: number, bx: number, by: number) => {
  const dx = bx - ax, dy = by - ay;
  return dx * dx + dy * dy;
};
export const angleTo = (ax: number, ay: number, bx: number, by: number) => Math.atan2(by - ay, bx - ax);

/** 归一化到 [-PI, PI] 的角度差 */
export function angleDiff(a: number, b: number) {
  let d = (b - a) % TAU;
  if (d > Math.PI) d -= TAU;
  if (d < -Math.PI) d += TAU;
  return d;
}

/** 确定性随机（关卡布局用，保证每次一样） */
export function mulberry32(seed: number) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/* ---------------- 投影 ---------------- */
export const sx = (x: number, cam: Cam, W: number) => x - cam.x + W * 0.5;
export const sy = (y: number, z: number, cam: Cam, H: number) => (y - cam.y) * YSQUASH - z + H * 0.5;
/** 屏幕坐标 → 地面世界坐标（z 视为 0） */
export const screenToWorldY = (my: number, cam: Cam, H: number) => (my - H * 0.5) / YSQUASH + cam.y;

/** 圆-矩形 相交（世界平面） */
export function circleRect(cx: number, cy: number, r: number, rx: number, ry: number, rw: number, rh: number) {
  const nx = clamp(cx, rx, rx + rw);
  const ny = clamp(cy, ry, ry + rh);
  return dist2(cx, cy, nx, ny) < r * r;
}

/** 把圆推出矩形（简单分离） */
export function pushOutRect(
  cx: number, cy: number, r: number, rx: number, ry: number, rw: number, rh: number,
): [number, number] {
  const nx = clamp(cx, rx, rx + rw);
  const ny = clamp(cy, ry, ry + rh);
  let dx = cx - nx, dy = cy - ny;
  let d = Math.hypot(dx, dy);
  if (d > r) return [cx, cy];
  if (d < 0.0001) {
    // 圆心在矩形内部：朝最近边推出
    const left = cx - rx, right = rx + rw - cx, top = cy - ry, bottom = ry + rh - cy;
    const m = Math.min(left, right, top, bottom);
    if (m === left) return [rx - r, cy];
    if (m === right) return [rx + rw + r, cy];
    if (m === top) return [cx, ry - r];
    return [cx, ry + rh + r];
  }
  dx /= d; dy /= d;
  return [nx + dx * r, ny + dy * r];
}

export function fmt(n: number) {
  return Math.round(n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

/** 十六进制颜色转 rgba 字符串 */
export function rgba(hex: string, a: number) {
  const h = hex.replace('#', '');
  const n = parseInt(h.length === 3 ? h.split('').map((c) => c + c).join('') : h, 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}
