/* ============================================================
   content.ts — 游戏内容数据：武器与技能、敌人、灯芯升级、剧情文本
   设计依据来自 README.md：
   · 每把武器自带一套技能，技能需要连击数解锁使用
   · 不同武器技能数与需要的连击数均不同
   · 灯芯升级灯骑士血量与亮度
   ============================================================ */

/* ------------------------- 武器 & 技能 ------------------------- */

export interface SkillDef {
  id: string;
  name: string;
  /** 需要消耗的连击数（同时也是解锁门槛） */
  cost: number;
  cd: number;
  desc: string;
}

export interface WeaponDef {
  id: string;
  name: string;
  desc: string;
  price: number;
  dmg: number;
  range: number;
  /** 挥击扇形总角度（弧度） */
  arc: number;
  cd: number;
  wind: number;
  knock: number;
  /** 挥击特效样式 */
  style: 'slash' | 'thrust' | 'smash';
  skills: SkillDef[];
}

export const WEAPONS: WeaponDef[] = [
  {
    id: 'blade',
    name: '灯刃',
    desc: '灯骑士最初的短刃。轻快、连击顺滑，连击数攒得最快。',
    price: 0,
    dmg: 13, range: 66, arc: 1.5, cd: 0.3, wind: 0.1, knock: 190,
    style: 'slash',
    skills: [
      { id: 'blade_whirl', name: '旋斩', cost: 4, cd: 2.2, desc: '原地回身一周，横扫周围所有敌人。' },
      { id: 'blade_burst', name: '灯爆', cost: 12, cd: 7, desc: '引爆身上灯火，冲击波推开敌人并点亮附近火盆。' },
    ],
  },
  {
    id: 'spear',
    name: '长明枪',
    desc: '灯塔守卫的长枪。距离长、突刺强，技能最多，但需要更高的连击。',
    price: 70,
    dmg: 17, range: 104, arc: 0.62, cd: 0.42, wind: 0.16, knock: 240,
    style: 'thrust',
    skills: [
      { id: 'spear_lunge', name: '掠光刺', cost: 3, cd: 1.8, desc: '向前突进并贯穿路径上的敌人。' },
      { id: 'spear_flurry', name: '连灯刺', cost: 9, cd: 5, desc: '向前连刺五下，越打越亮。' },
      { id: 'spear_pierce', name: '长明贯', cost: 18, cd: 10, desc: '射出一道贯穿全场的光柱，重创直线上的敌人。' },
    ],
  },
  {
    id: 'hammer',
    name: '烬锤',
    desc: '噬灯者残骸打成的重锤。慢、重、范围极大；只有一招，但一招就够。',
    price: 140,
    dmg: 34, range: 82, arc: 2.1, cd: 0.68, wind: 0.24, knock: 420,
    style: 'smash',
    skills: [
      { id: 'hammer_quake', name: '撼地', cost: 7, cd: 3.6, desc: '砸地掀起环形光波，重创并击退周围一切，同时点亮附近火盆。' },
    ],
  },
];

export const WEAPON_MAP: Record<string, WeaponDef> = Object.fromEntries(WEAPONS.map((w) => [w.id, w]));

/* ------------------------- 敌人 ------------------------- */

export interface EnemyDef {
  id: string;
  name: string;
  hp: number;
  speed: number;
  dmg: number;
  r: number;
  h: number;
  aggro: number;
  atkRange: number;
  atkCd: number;
  wind: number;
  behavior: 'chase' | 'guard' | 'spitter' | 'boss';
  body: string;
  glow: string;
  /** 自身微光半径（0 = 不发光） */
  light?: number;
  coin: number;
  /** 被击退抗性 0..1 */
  weight?: number;
  bossStyle?: 'devourer' | 'shadow';
  bossScale?: number;
}

export const ENEMY_TYPES: Record<string, EnemyDef> = {
  shade: {
    id: 'shade', name: '灯影', hp: 24, speed: 92, dmg: 9, r: 16, h: 36,
    aggro: 460, atkRange: 40, atkCd: 1.05, wind: 0.34, behavior: 'chase',
    body: '#171a2e', glow: '#b7a8ff', light: 30, coin: 2, weight: 0.2,
  },
  guard: {
    id: 'guard', name: '灯烬卫', hp: 78, speed: 60, dmg: 17, r: 23, h: 50,
    aggro: 500, atkRange: 62, atkCd: 1.75, wind: 0.62, behavior: 'guard',
    body: '#2b2118', glow: '#ff9b45', light: 24, coin: 6, weight: 0.7,
  },
  leech: {
    id: 'leech', name: '灯蛭', hp: 36, speed: 74, dmg: 11, r: 18, h: 30,
    aggro: 700, atkRange: 350, atkCd: 2.3, wind: 0.68, behavior: 'spitter',
    body: '#211826', glow: '#ff6b8a', light: 22, coin: 4, weight: 0.3,
  },
  devourer_jr: {
    id: 'devourer_jr', name: '噬灯者·幼体', hp: 430, speed: 78, dmg: 17, r: 40, h: 76,
    aggro: 900, atkRange: 120, atkCd: 2.0, wind: 0.62, behavior: 'boss',
    body: '#20141c', glow: '#ff5f3c', light: 40, coin: 60, weight: 1,
    bossStyle: 'devourer', bossScale: 1,
  },
  devourer: {
    id: 'devourer', name: '噬灯者', hp: 900, speed: 84, dmg: 22, r: 48, h: 92,
    aggro: 1100, atkRange: 135, atkCd: 1.8, wind: 0.58, behavior: 'boss',
    body: '#241019', glow: '#ff4f2e', light: 46, coin: 110, weight: 1,
    bossStyle: 'devourer', bossScale: 1.25,
  },
  lampdemon_shadow: {
    id: 'lampdemon_shadow', name: '灯魔之影', hp: 1250, speed: 92, dmg: 26, r: 52, h: 104,
    aggro: 1200, atkRange: 150, atkCd: 1.6, wind: 0.5, behavior: 'boss',
    body: '#1a1226', glow: '#8f6bff', light: 50, coin: 180, weight: 1,
    bossStyle: 'shadow', bossScale: 1.35,
  },
};

/** 精英化：相当于该关卡的"精英怪" */
export function eliteify(def: EnemyDef): EnemyDef {
  return {
    ...def,
    name: def.name + '（精英）',
    hp: Math.round(def.hp * 2.6),
    dmg: Math.round(def.dmg * 1.35),
    r: def.r * 1.28,
    h: def.h * 1.2,
    coin: Math.round(def.coin * 4),
    glow: '#ffe08a',
    light: (def.light ?? 0) + 34,
    weight: 1,
  };
}

/* ------------------------- 灯芯升级（灯塔处） ------------------------- */

export interface UpgradeDef {
  id: 'hp' | 'light' | 'edge';
  name: string;
  desc: string;
  max: number;
  costBase: number;
}

export const UPGRADES: UpgradeDef[] = [
  { id: 'hp', name: '灯芯·燃', desc: '最大生命 +25', max: 6, costBase: 2 },
  { id: 'light', name: '灯芯·明', desc: '基础光照半径 +24，照亮更远', max: 5, costBase: 2 },
  { id: 'edge', name: '灯芯·锋', desc: '全部武器伤害 +12%', max: 5, costBase: 3 },
];

export const upgradeCost = (def: UpgradeDef, level: number) => def.costBase + level;

/* ------------------------- 掌灯人商店 ------------------------- */

export interface ShopItem {
  id: string;
  name: string;
  desc: string;
  price: number;
  /** 可重复购买 */
  repeat?: boolean;
}

export const SHOP_ITEMS: ShopItem[] = [
  { id: 'oil', name: '灯油', desc: '立刻回复 45% 最大生命。', price: 22, repeat: true },
  { id: 'ember', name: '火种', desc: '永久提升最大生命 +12。', price: 85, repeat: true },
  { id: 'brightoil', name: '明油', desc: '永久提升基础光照半径 +10。', price: 95, repeat: true },
];

/* ------------------------- 剧情 ------------------------- */

export interface Line { speaker: string; text: string; }

export const DIALOGUES: Record<string, Line[]> = {
  intro: [
    { speaker: '旁白', text: '灯河之上，无数灯火浮沉。\n人们说，光是借来的，总有一天要还。' },
    { speaker: '旁白', text: '灯堡的少年骑士，守着一座座灯塔长大。\n他曾在光里许愿：要让这世上再无一寸黑暗。' },
    { speaker: '旁白', text: '可是那一夜，他在灯下醒来，胸口多了一枚不会熄灭的暗纹——\n他成了"受诅咒者"。' },
    { speaker: '灯骑士', text: '……我还能点亮灯塔吗？' },
    { speaker: '掌灯人', text: '能。只是你得先学会，在没人替你点灯的地方，自己烧起来。' },
    { speaker: '掌灯人', text: '去吧。外庭的灯还亮着，先去那儿看看——那是你最好的日子。' },
  ],

  l1_start: [
    { speaker: '旁白', text: '【灯堡外庭】\n石灯还亮着，风里有灯油的味道。这是灯骑士最好的日子。' },
    { speaker: '灯骑士', text: '（连击会让身上的灯火更亮……越大意，越容易被黑暗咬住。）' },
    { speaker: '掌灯人', text: '记住：连击就是你的光。别停手，也别贪。' },
  ],

  l1_boss_pre: [
    { speaker: '旁白', text: '角落里蜷着一团小小的影子，它正抱着一盏灯啃。' },
    { speaker: '噬灯者·幼体', text: '灯……是吃的……' },
    { speaker: '灯骑士', text: '（它还是幼体。可它已经在吃灯了。）' },
  ],

  l1_clear: [
    { speaker: '旁白', text: '幼体倒下时，灯堡的钟响了。你以为这只是个晚上的巡逻。' },
    { speaker: '灯骑士', text: '这影子……在吃灯火？' },
    { speaker: '旁白', text: '钟声第三下，外庭所有的灯同时熄了。' },
    { speaker: '掌灯人', text: '（远处的黑暗里）听到了吗……它们饿了。' },
  ],

  l2_start: [
    { speaker: '旁白', text: '【灯堡深处 · 无芯之暗】\n这里的灯芯被人拔走了。没有光，死了的东西会不断再生。' },
    { speaker: '灯骑士', text: '好黑……' },
    { speaker: '灯骑士', text: '天还能亮吗？' },
    { speaker: '盲女', text: '会的。' },
    { speaker: '灯骑士', text: '……可你不是看不见吗？' },
    { speaker: '盲女', text: '可你在我身边时，我就感到格外亮堂。' },
    { speaker: '旁白', text: '（她看不见，却能感应灯火。靠近她时，你身上的光会更强。）' },
  ],

  l2_brazier: [
    { speaker: '盲女', text: '把连击的火按在火盆上——它们会替你记住这段光亮。' },
    { speaker: '旁白', text: '火盆亮起。黑暗后退了三步。' },
  ],

  l2_boss_pre: [
    { speaker: '噬灯者', text: '你是受诅咒者，跟我们一样，是吃灯的家伙。' },
    { speaker: '灯骑士', text: '我不是。' },
    { speaker: '噬灯者', text: '那你胸口的暗纹是什么？是灯在吃你，还是你在吃灯？' },
    { speaker: '盲女', text: '别听它的。它吃的是别人的灯，你烧的是自己的心。' },
  ],

  l2_clear: [
    { speaker: '旁白', text: '噬灯者扑向盲女——它闻到了古老灯芯的味道。' },
    { speaker: '灯骑士', text: '不！' },
    { speaker: '旁白', text: '你救出了她，可是她已经燃尽了。' },
    { speaker: '盲女', text: '……点我。' },
    { speaker: '灯骑士', text: '什么？' },
    { speaker: '盲女', text: '点亮我。让我去当灯芯，你就能走到更暗的地方去。' },
    { speaker: '旁白', text: '她点亮了灯塔。从此她也成了你身上的光。' },
    { speaker: '旁白', text: '【获得 盲女之灯】光照更强，且她会在你濒死时替你燃一次。' },
  ],

  l3_start: [
    { speaker: '掌灯人', text: '尽情燃烧吧，你得为这个世界带去更多光亮！' },
    { speaker: '旁白', text: '【灯河渡口】\n河上漂着无数熄灭的灯。对岸，是灯魔的影子。' },
    { speaker: '盲女', text: '（在你胸口轻轻一动）我在这儿。' },
  ],

  l3_boss_pre: [
    { speaker: '灯魔之影', text: '把灯留下，我就让你做回一个普通人。' },
    { speaker: '灯骑士', text: '我要的不是普通人。我要的是天亮。' },
  ],

  l3_clear: [
    { speaker: '灯河', text: '灯骑士啊，你是不幸的，可你亦是人们的希望，\n去吧，渡过灯河，去往更暗处带去光明吧。' },
    { speaker: '旁白', text: '影子碎了。对岸的灯，一盏接一盏亮起。' },
    { speaker: '灯骑士', text: '等着我。' },
  ],

  no_wick: [
    { speaker: '旁白', text: '这里没有灯芯，死亡会重生。先去点燃三座火盆，用连击之光。' },
  ],

  respawn: [
    { speaker: '旁白', text: '你倒下了。灯骑士的诅咒把你拖回上一座灯塔。' },
    { speaker: '旁白', text: '灯火散落了一些，但暗纹还记得你的连击。' },
  ],

  lighthouse_lit: [
    { speaker: '旁白', text: '灯塔亮了。庇护所、存档点、传送点——都在这里。' },
  ],
};

/* 标题与过场用到的引文 */
export const LORE = {
  motto: '暂时的是现实，永恒的是理想。',
  l1: '外庭的灯还亮着，这是你最好的日子。',
  l2: '没有灯芯的地方，死了的东西会不断再生。',
  l3: '去吧，渡过灯河，去往更暗处带去光明吧。',
};
