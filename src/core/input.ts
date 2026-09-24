/* ============================================================
   input.ts — 键盘 / 鼠标输入（含边缘触发 justPressed）
   ============================================================ */
export const Input = {
  down: new Set<string>(),
  _pressed: new Set<string>(),
  _released: new Set<string>(),
  mouse: {
    x: 0, y: 0,
    down: false,
    justDown: false,
    justUp: false,
    wheel: 0,
    inside: true,
  },

  init(canvas: HTMLCanvasElement) {
    const rect = () => canvas.getBoundingClientRect();

    window.addEventListener('keydown', (e) => {
      // 空格/方向键不要滚动页面
      if (['Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Tab'].includes(e.code)) e.preventDefault();
      if (!e.repeat) this._pressed.add(e.code);
      this.down.add(e.code);
    });
    window.addEventListener('keyup', (e) => {
      this.down.delete(e.code);
      this._released.add(e.code);
    });
    window.addEventListener('blur', () => { this.down.clear(); });

    canvas.addEventListener('mousemove', (e) => {
      const r = rect();
      this.mouse.x = e.clientX - r.left;
      this.mouse.y = e.clientY - r.top;
      this.mouse.inside = true;
    });
    canvas.addEventListener('mousedown', (e) => {
      if (e.button === 0) { this.mouse.down = true; this.mouse.justDown = true; }
      if (e.button === 2) { /* 预留：右键 */ }
    });
    window.addEventListener('mouseup', (e) => {
      if (e.button === 0) { this.mouse.down = false; this.mouse.justUp = true; }
    });
    canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    canvas.addEventListener('mouseleave', () => { this.mouse.inside = false; this.mouse.down = false; });
    window.addEventListener('wheel', (e) => { this.mouse.wheel += Math.sign(e.deltaY); }, { passive: true });
  },

  isDown(code: string) { return this.down.has(code); },
  justPressed(code: string) { return this._pressed.has(code); },
  justReleased(code: string) { return this._released.has(code); },

  /** 归一化移动向量（WASD / 方向键） */
  axis(): [number, number] {
    let x = 0, y = 0;
    if (this.isDown('KeyA') || this.isDown('ArrowLeft')) x -= 1;
    if (this.isDown('KeyD') || this.isDown('ArrowRight')) x += 1;
    if (this.isDown('KeyW') || this.isDown('ArrowUp')) y -= 1;
    if (this.isDown('KeyS') || this.isDown('ArrowDown')) y += 1;
    const len = Math.hypot(x, y);
    if (len > 0) { x /= len; y /= len; }
    return [x, y];
  },

  /** 每帧末清理边缘状态 */
  endFrame() {
    this._pressed.clear();
    this._released.clear();
    this.mouse.justDown = false;
    this.mouse.justUp = false;
    this.mouse.wheel = 0;
  },
};
