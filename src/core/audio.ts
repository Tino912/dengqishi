/* ============================================================
   audio.ts — 纯程序化音频（WebAudio 合成，不依赖任何音频素材文件）
   音效：挥砍 / 命中 / 暴击 / 拾取灯火 / 冲刺 / 技能 / 受伤 / 点灯 / 存档 / UI / Boss 咆哮 / 死亡
   音乐：每关一个调式的低频嗡鸣 + 五声音阶拨弦，强度随连击上升
   ============================================================ */

type SfxName =
  | 'slash' | 'hit' | 'crit' | 'coin' | 'dash' | 'skill' | 'hurt'
  | 'light' | 'brazier' | 'ui' | 'uiBig' | 'roar' | 'die' | 'save' | 'levelup';

class SoundSystem {
  ctx: AudioContext | null = null;
  master: GainNode | null = null;
  sfxGain: GainNode | null = null;
  musicGain: GainNode | null = null;
  volMaster = 0.75;
  volSfx = 0.9;
  volMusic = 0.5;
  muted = false;

  private noiseBuf: AudioBuffer | null = null;
  private droneNodes: { osc: OscillatorNode[]; gain: GainNode; filter: BiquadFilterNode } | null = null;
  private musicOn = false;
  private beatTimer = 0;
  private beatIndex = 0;
  private level = 0;

  /** 必须在用户手势后调用 */
  ensure() {
    if (this.ctx) {
      if (this.ctx.state === 'suspended') this.ctx.resume().catch(() => {});
      return;
    }
    try {
      const AC = window.AudioContext || (window as any).webkitAudioContext;
      if (!AC) return;
      this.ctx = new AC();
      this.master = this.ctx.createGain();
      this.master.gain.value = this.muted ? 0 : this.volMaster;
      this.master.connect(this.ctx.destination);

      this.sfxGain = this.ctx.createGain();
      this.sfxGain.gain.value = this.volSfx;
      this.sfxGain.connect(this.master);

      this.musicGain = this.ctx.createGain();
      this.musicGain.gain.value = this.volMusic;
      this.musicGain.connect(this.master);

      // 噪声缓冲（打击乐 / 气声）
      const len = Math.floor(this.ctx.sampleRate * 1.2);
      const buf = this.ctx.createBuffer(1, len, this.ctx.sampleRate);
      const d = buf.getChannelData(0);
      for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
      this.noiseBuf = buf;
    } catch { /* 忽略音频失败，不影响游戏 */ }
  }

  setMasterVolume(v: number) {
    this.volMaster = v;
    this.muted = v <= 0.001;
    if (this.master && this.ctx) {
      this.master.gain.setTargetAtTime(this.muted ? 0 : v, this.ctx.currentTime, 0.05);
    }
  }

  toggleMute() {
    this.setMasterVolume(this.muted ? 0.75 : 0);
    return !this.muted;
  }

  private tone(
    freq: number, dur: number, type: OscillatorType, vol: number,
    opt: { slide?: number; attack?: number; detune?: number; dest?: AudioNode } = {},
  ) {
    if (!this.ctx || !this.sfxGain) return;
    const t = this.ctx.currentTime;
    const osc = this.ctx.createOscillator();
    const g = this.ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(Math.max(20, freq), t);
    if (opt.slide) osc.frequency.exponentialRampToValueAtTime(Math.max(20, freq * opt.slide), t + dur);
    if (opt.detune) osc.detune.value = opt.detune;
    const atk = opt.attack ?? 0.005;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), t + atk);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    osc.connect(g);
    g.connect(opt.dest ?? this.sfxGain);
    osc.start(t);
    osc.stop(t + dur + 0.05);
  }

  private noise(
    dur: number, vol: number,
    opt: { freq?: number; q?: number; sweepTo?: number; type?: BiquadFilterType; attack?: number } = {},
  ) {
    if (!this.ctx || !this.sfxGain || !this.noiseBuf) return;
    const t = this.ctx.currentTime;
    const src = this.ctx.createBufferSource();
    src.buffer = this.noiseBuf;
    const f = this.ctx.createBiquadFilter();
    f.type = opt.type ?? 'bandpass';
    f.frequency.setValueAtTime(opt.freq ?? 1200, t);
    if (opt.sweepTo) f.frequency.exponentialRampToValueAtTime(Math.max(60, opt.sweepTo), t + dur);
    f.Q.value = opt.q ?? 1.2;
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(Math.max(0.0002, vol), t + (opt.attack ?? 0.006));
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    src.connect(f); f.connect(g); g.connect(this.sfxGain);
    src.start(t);
    src.stop(t + dur + 0.05);
  }

  sfx(name: SfxName) {
    if (!this.ctx || this.muted) return;
    switch (name) {
      case 'slash':
        this.noise(0.16, 0.28, { freq: 2600, sweepTo: 500, q: 0.9 });
        this.tone(680, 0.1, 'triangle', 0.07, { slide: 0.5 });
        break;
      case 'hit':
        this.noise(0.1, 0.3, { freq: 420, sweepTo: 120, q: 1.4, type: 'lowpass' });
        this.tone(180, 0.1, 'square', 0.1, { slide: 0.6 });
        break;
      case 'crit':
        this.noise(0.2, 0.34, { freq: 900, sweepTo: 110, q: 1.1, type: 'lowpass' });
        this.tone(880, 0.22, 'sawtooth', 0.1, { slide: 0.28 });
        this.tone(1320, 0.16, 'triangle', 0.07, { slide: 0.4 });
        break;
      case 'coin':
        this.tone(1180, 0.09, 'triangle', 0.11);
        this.tone(1760, 0.14, 'triangle', 0.08, { attack: 0.01 });
        break;
      case 'dash':
        this.noise(0.22, 0.2, { freq: 300, sweepTo: 2200, q: 0.8, type: 'bandpass' });
        break;
      case 'skill':
        this.tone(220, 0.5, 'sawtooth', 0.12, { slide: 3.2, attack: 0.02 });
        this.tone(330, 0.45, 'triangle', 0.08, { slide: 2.6 });
        this.noise(0.5, 0.16, { freq: 400, sweepTo: 4200, q: 0.7 });
        break;
      case 'hurt':
        this.tone(160, 0.24, 'square', 0.13, { slide: 0.45 });
        this.noise(0.24, 0.22, { freq: 700, sweepTo: 160, q: 0.8, type: 'lowpass' });
        break;
      case 'light':
        [523, 659, 784, 1046].forEach((f, i) => setTimeout(() => this.tone(f, 0.7, 'triangle', 0.09, { attack: 0.02 }), i * 90));
        break;
      case 'brazier':
        this.noise(0.5, 0.2, { freq: 800, sweepTo: 2600, q: 0.6 });
        this.tone(392, 0.8, 'sine', 0.09, { attack: 0.04 });
        break;
      case 'ui':
        this.tone(520, 0.06, 'square', 0.05);
        break;
      case 'uiBig':
        this.tone(300, 0.3, 'triangle', 0.1, { slide: 1.8 });
        break;
      case 'roar':
        this.tone(70, 1.0, 'sawtooth', 0.2, { slide: 0.6, attack: 0.06 });
        this.noise(1.1, 0.22, { freq: 260, sweepTo: 90, q: 0.6, type: 'lowpass' });
        break;
      case 'die':
        this.tone(200, 1.2, 'sawtooth', 0.16, { slide: 0.2, attack: 0.02 });
        this.tone(300, 1.1, 'triangle', 0.1, { slide: 0.22 });
        break;
      case 'save':
        [392, 523, 784].forEach((f, i) => setTimeout(() => this.tone(f, 0.9, 'sine', 0.1, { attack: 0.05 }), i * 140));
        break;
      case 'levelup':
        [523, 622, 784, 1046, 1318].forEach((f, i) => setTimeout(() => this.tone(f, 0.6, 'triangle', 0.09), i * 80));
        break;
    }
  }

  /* ---------------- 音乐 ---------------- */
  startMusic(levelIndex: number) {
    if (!this.ctx || !this.musicGain) return;
    this.stopMusic();
    this.level = levelIndex;
    this.musicOn = true;
    this.beatTimer = 0;
    this.beatIndex = 0;

    const t = this.ctx.currentTime;
    const filter = this.ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = 420;
    filter.Q.value = 2;
    const g = this.ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.25, t + 3.5);
    g.connect(filter);
    filter.connect(this.musicGain);

    // 每关不同的根音：L1 温暖，L2 低沉压抑，L3 庄严
    const roots = [110, 87.31, 98];
    const root = roots[clampIdx(levelIndex, 0, roots.length - 1)];
    const oscs: OscillatorNode[] = [];
    [
      { f: root, type: 'sawtooth' as OscillatorType, det: -6, vol: 0.5 },
      { f: root, type: 'sawtooth' as OscillatorType, det: 7, vol: 0.4 },
      { f: root * 1.5, type: 'sine' as OscillatorType, det: 0, vol: 0.35 },
      { f: root * 0.5, type: 'sine' as OscillatorType, det: 0, vol: 0.5 },
    ].forEach((o) => {
      const osc = this.ctx!.createOscillator();
      osc.type = o.type;
      osc.frequency.value = o.f;
      osc.detune.value = o.det;
      const og = this.ctx!.createGain();
      og.gain.value = o.vol;
      osc.connect(og); og.connect(g);
      osc.start(t);
      oscs.push(osc);
    });

    this.droneNodes = { osc: oscs, gain: g, filter };
  }

  stopMusic() {
    if (!this.ctx || !this.droneNodes) return;
    const t = this.ctx.currentTime;
    const { osc, gain } = this.droneNodes;
    gain.gain.cancelScheduledValues(t);
    gain.gain.setTargetAtTime(0.0001, t, 0.4);
    osc.forEach((o) => { try { o.stop(t + 2); } catch { /* noop */ } });
    this.droneNodes = null;
    this.musicOn = false;
  }

  /** 每帧调用；intensity 0..1 由连击/亮度驱动 */
  updateMusic(dt: number, intensity: number) {
    if (!this.ctx || !this.musicOn || this.muted) return;
    if (this.droneNodes) {
      this.droneNodes.filter.frequency.setTargetAtTime(340 + intensity * 1100, this.ctx.currentTime, 0.4);
    }
    const interval = lerpNum(1.25, 0.36, clamp01(intensity));
    this.beatTimer += dt;
    if (this.beatTimer < interval) return;
    this.beatTimer -= interval;
    this.beatIndex++;

    const scales = [
      [0, 3, 5, 7, 10],   // 小调五声 — 灯堡外庭
      [0, 1, 5, 6, 8],    // 阴郁音阶 — 无芯之暗
      [0, 2, 3, 7, 9],    // 含增四度的悲壮 — 灯河渡口
    ];
    const root = [220, 174.61, 196][clampIdx(this.level, 0, 2)];
    const scale = scales[clampIdx(this.level, 0, 2)];
    const semi = scale[Math.floor(Math.random() * scale.length)] + (Math.random() < 0.25 ? 12 : 0);
    const f = root * Math.pow(2, semi / 12);
    this.tone(f, 1.6, 'triangle', 0.05 + intensity * 0.05, { attack: 0.02 });
    if (this.beatIndex % 4 === 0) {
      // 心跳般的低鼓
      this.tone(root * 0.5, 0.5, 'sine', 0.1 + intensity * 0.08, { slide: 0.6 });
    }
    if (intensity > 0.55 && this.beatIndex % 2 === 1) {
      this.noise(0.1, 0.06, { freq: 5200, q: 0.9 });
    }
  }
}

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const lerpNum = (a: number, b: number, t: number) => a + (b - a) * t;
const clampIdx = (v: number, a: number, b: number) => (v < a ? a : v > b ? b : v);

export const Sound = new SoundSystem();
