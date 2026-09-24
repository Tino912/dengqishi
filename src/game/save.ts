/* ============================================================
   save.ts — 用 localStorage 做"灯塔存档"
   ============================================================ */
import { Progress, newProgress } from './world';

const KEY = 'lightknight.save.v1';

export const Save = {
  has(): boolean {
    try { return !!localStorage.getItem(KEY); } catch { return false; }
  },
  load(): Progress | null {
    try {
      const raw = localStorage.getItem(KEY);
      if (!raw) return null;
      const d = JSON.parse(raw);
      const base = newProgress();
      // 逐字段合并，兼容旧存档
      const up = d.up ?? {};
      const merged: Progress = {
        ...base, ...d,
        up: { hp: +(up.hp ?? 0), light: +(up.light ?? 0), edge: +(up.edge ?? 0) },
        shop: { ember: +(d.shop?.ember ?? 0), brightoil: +(d.shop?.brightoil ?? 0) },
        weapons: Array.isArray(d.weapons) && d.weapons.length ? d.weapons : ['blade'],
        lit: Array.isArray(d.lit) ? d.lit : [],
        cleared: Array.isArray(d.cleared) ? d.cleared : [],
      };
      if (!merged.weapons.includes(merged.weapon)) merged.weapon = 'blade';
      return merged;
    } catch {
      return null;
    }
  },
  write(p: Progress) {
    try { localStorage.setItem(KEY, JSON.stringify(p)); } catch { /* 隐私模式等 */ }
  },
  clear() {
    try { localStorage.removeItem(KEY); } catch { /* noop */ }
  },
};

export function describeProgress(p: Progress, levelName: string) {
  const upTxt = `燃${p.up.hp} 明${p.up.light} 锋${p.up.edge}`;
  return `第 ${p.level + 1} 关 · ${levelName}　灯火 ${p.coins}　灯芯 ${p.wicks}　(${upTxt})`;
}
