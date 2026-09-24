/* ============================================================
   levels.ts — 三张地图的布局数据
   依据 README V1 目标：3 张地图，分别叙述灯骑士的美好过往、遇难、踏上复仇。
   坐标系：x 向右，y 向下（世界平面），单位为像素。地图外圈由墙围住。
   ============================================================ */

export interface Wall { x: number; y: number; w: number; d: number; h: number; }

export type PropKind =
  | 'lighthouse' | 'brazier' | 'dock' | 'merchant'
  | 'pillar' | 'lantern' | 'tree' | 'rubble' | 'statue';

export interface PropDef { kind: PropKind; x: number; y: number; r?: number; seed?: number; }

export interface WaveDef {
  label: string;
  x: number; y: number; radius: number;
  enemies: { type: string; count: number; elite?: boolean }[];
}

export interface LevelDef {
  index: number;
  name: string;
  subtitle: string;
  lore: string;
  w: number; h: number;
  /** 黑暗层不透明度（越大越黑） */
  ambient: number;
  clearedAmbient: number;
  seed: number;
  enemyScale: number;
  walls: Wall[];
  props: PropDef[];
  waves: WaveDef[];
  boss: { type: string; x: number; y: number; radius: number; label: string };
  /** 关卡终点：灯塔（点亮存档）或灯河渡口 */
  goal: { kind: 'lighthouse' | 'dock'; x: number; y: number; name: string };
  start: { x: number; y: number };
  decorCount: number;
  palette: {
    floor: string; floor2: string; wall: string; wallTop: string; rim: string; fog: string; accent: string;
  };
  /** 需要点燃的火盆数量（无芯之暗） */
  braziersRequired?: number;
  /** 火盆未点燃时怪物不断再生 */
  respawnWhileDark?: boolean;
  blindGirl?: { x: number; y: number };
}

const B = 44; // 边界墙厚度

/** 生成外圈边界墙 */
function border(w: number, h: number, ht: number): Wall[] {
  return [
    { x: 0, y: 0, w, d: B, h: ht },
    { x: 0, y: h - B, w, d: B, h: ht },
    { x: 0, y: 0, w: B, d: h, h: ht },
    { x: w - B, y: 0, w: B, d: h, h: ht },
  ];
}

/* ============================================================
   第一关 · 灯堡外庭 —— 美好过往
   ============================================================ */
const L1: LevelDef = {
  index: 0,
  name: '灯堡外庭',
  subtitle: '第一张地图 · 美好过往',
  lore: '外庭的灯还亮着，这是你最好的日子。',
  w: 2400, h: 1700,
  ambient: 0.9, clearedAmbient: 0.58,
  seed: 10711,
  enemyScale: 1,
  walls: [
    ...border(2400, 1700, 64),
    { x: 520, y: 300, w: 140, d: 400, h: 54 },
    { x: 860, y: 620, w: 360, d: 60, h: 46 },
    { x: 1460, y: 240, w: 60, d: 340, h: 46 },
    { x: 1140, y: 880, w: 420, d: 60, h: 46 },
    { x: 420, y: 980, w: 60, d: 300, h: 46 },
    { x: 1740, y: 760, w: 300, d: 60, h: 52 },
    { x: 1600, y: 1180, w: 60, d: 300, h: 46 },
    { x: 880, y: 1300, w: 340, d: 60, h: 46 },
    { x: 2040, y: 980, w: 60, d: 400, h: 50 },
    { x: 1900, y: 150, w: 60, d: 280, h: 46 },
  ],
  props: [
    { kind: 'lighthouse', x: 2200, y: 250 },
    { kind: 'brazier', x: 700, y: 1180 },
    { kind: 'brazier', x: 1330, y: 520 },
    { kind: 'brazier', x: 1900, y: 1360 },
    { kind: 'merchant', x: 290, y: 1400 },
    { kind: 'statue', x: 1180, y: 1500 },
  ],
  waves: [
    { label: '第一波 · 石灯下的影', x: 830, y: 830, radius: 300, enemies: [{ type: 'shade', count: 4 }] },
    { label: '第二波 · 烬卫巡逻', x: 1500, y: 1130, radius: 320, enemies: [{ type: 'shade', count: 5 }, { type: 'guard', count: 2 }] },
    { label: '第三波 · 幼体前的守卫', x: 1980, y: 700, radius: 320, enemies: [{ type: 'shade', count: 4 }, { type: 'guard', count: 1, elite: true }, { type: 'leech', count: 2 }] },
  ],
  boss: { type: 'devourer_jr', x: 2080, y: 420, radius: 320, label: '噬灯者·幼体' },
  goal: { kind: 'lighthouse', x: 2200, y: 250, name: '外庭灯塔' },
  start: { x: 300, y: 1350 },
  decorCount: 26,
  palette: {
    floor: '#1b2030', floor2: '#171b28', wall: '#2b3345', wallTop: '#3b465c',
    rim: '#93a7cc', fog: '#0a0e18', accent: '#ffca70',
  },
};

/* ============================================================
   第二关 · 灯堡深处（无芯之暗）—— 遇难
   没有灯芯，怪物不断再生；盲女同行；需点燃三座火盆削弱 Boss。
   ============================================================ */
const L2: LevelDef = {
  index: 1,
  name: '灯堡深处 · 无芯之暗',
  subtitle: '第二张地图 · 遇难',
  lore: '没有灯芯的地方，死了的东西会不断再生。',
  w: 2800, h: 2000,
  ambient: 0.955, clearedAmbient: 0.62,
  seed: 20422,
  enemyScale: 1.18,
  walls: [
    ...border(2800, 2000, 70),
    { x: 400, y: 360, w: 520, d: 60, h: 56 },
    { x: 400, y: 360, w: 60, d: 340, h: 56 },
    { x: 1120, y: 300, w: 60, d: 420, h: 54 },
    { x: 1400, y: 640, w: 420, d: 60, h: 54 },
    { x: 700, y: 880, w: 60, d: 380, h: 50 },
    { x: 900, y: 1240, w: 460, d: 60, h: 50 },
    { x: 1600, y: 980, w: 60, d: 440, h: 54 },
    { x: 1820, y: 1420, w: 440, d: 60, h: 50 },
    { x: 2020, y: 380, w: 60, d: 400, h: 54 },
    { x: 2240, y: 820, w: 60, d: 320, h: 50 },
    { x: 1320, y: 1540, w: 400, d: 60, h: 50 },
    { x: 2260, y: 1160, w: 340, d: 60, h: 50 },
  ],
  props: [
    { kind: 'lighthouse', x: 2640, y: 1830 },
    { kind: 'brazier', x: 620, y: 560 },
    { kind: 'brazier', x: 1560, y: 790 },
    { kind: 'brazier', x: 2380, y: 1680 },
    { kind: 'merchant', x: 300, y: 1860 },
    { kind: 'statue', x: 1420, y: 1180 },
    { kind: 'statue', x: 2100, y: 1620 },
  ],
  waves: [
    { label: '第一波 · 再生之影', x: 900, y: 760, radius: 340, enemies: [{ type: 'shade', count: 5 }, { type: 'guard', count: 1 }] },
    { label: '第二波 · 蛭群', x: 1720, y: 1220, radius: 340, enemies: [{ type: 'shade', count: 5 }, { type: 'guard', count: 2 }, { type: 'leech', count: 2 }] },
    { label: '第三波 · 烬卫队长', x: 2380, y: 560, radius: 320, enemies: [{ type: 'shade', count: 4 }, { type: 'guard', count: 1, elite: true }, { type: 'leech', count: 2 }] },
  ],
  boss: { type: 'devourer', x: 1240, y: 420, radius: 340, label: '噬灯者' },
  goal: { kind: 'lighthouse', x: 2640, y: 1830, name: '深处灯塔' },
  start: { x: 300, y: 1750 },
  decorCount: 30,
  braziersRequired: 3,
  respawnWhileDark: true,
  blindGirl: { x: 430, y: 1700 },
  palette: {
    floor: '#171523', floor2: '#131120', wall: '#262034', wallTop: '#332b45',
    rim: '#8b78b4', fog: '#08060f', accent: '#c9a6ff',
  },
};

/* ============================================================
   第三关 · 灯河渡口 —— 踏上复仇
   掌灯人传话；灯魔之影镇守渡口；渡过灯河即 V1 终章。
   ============================================================ */
const L3: LevelDef = {
  index: 2,
  name: '灯河渡口',
  subtitle: '第三张地图 · 踏上复仇',
  lore: '去吧，渡过灯河，去往更暗处带去光明吧。',
  w: 2600, h: 1800,
  ambient: 0.92, clearedAmbient: 0.5,
  seed: 30931,
  enemyScale: 1.3,
  walls: [
    ...border(2600, 1800, 68),
    { x: 600, y: 420, w: 480, d: 60, h: 54 },
    { x: 600, y: 420, w: 60, d: 320, h: 54 },
    { x: 1500, y: 380, w: 60, d: 420, h: 52 },
    { x: 1800, y: 760, w: 440, d: 60, h: 52 },
    { x: 900, y: 900, w: 60, d: 360, h: 50 },
    { x: 1200, y: 1280, w: 420, d: 60, h: 50 },
    { x: 2000, y: 1100, w: 60, d: 380, h: 52 },
    { x: 300, y: 1300, w: 380, d: 60, h: 50 },
    { x: 2200, y: 500, w: 60, d: 340, h: 50 },
    { x: 1600, y: 1500, w: 60, d: 240, h: 48 },
  ],
  props: [
    { kind: 'dock', x: 1300, y: 200 },
    { kind: 'brazier', x: 700, y: 1050 },
    { kind: 'brazier', x: 2060, y: 1560 },
    { kind: 'merchant', x: 300, y: 1500 },
    { kind: 'statue', x: 1750, y: 620 },
    { kind: 'statue', x: 700, y: 1650 },
  ],
  waves: [
    { label: '第一波 · 渡口的游魂', x: 900, y: 1150, radius: 340, enemies: [{ type: 'shade', count: 5 }, { type: 'guard', count: 2 }] },
    { label: '第二波 · 灯蛭伏击', x: 1700, y: 1250, radius: 340, enemies: [{ type: 'shade', count: 6 }, { type: 'guard', count: 2 }, { type: 'leech', count: 3 }] },
    { label: '第三波 · 影之侍从', x: 2380, y: 900, radius: 320, enemies: [{ type: 'shade', count: 4, elite: true }, { type: 'guard', count: 1, elite: true }, { type: 'leech', count: 3 }] },
  ],
  boss: { type: 'lampdemon_shadow', x: 1300, y: 620, radius: 360, label: '灯魔之影' },
  goal: { kind: 'dock', x: 1300, y: 200, name: '灯河渡口' },
  start: { x: 420, y: 1560 },
  decorCount: 28,
  palette: {
    floor: '#1c1b26', floor2: '#171620', wall: '#2c2536', wallTop: '#3b3248',
    rim: '#a389c8', fog: '#0a0812', accent: '#c4a0ff',
  },
};

export const LEVELS: LevelDef[] = [L1, L2, L3];
