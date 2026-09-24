# LightKnight 灯骑士 · V1 MVP 实现说明

本文说明这个 MVP **怎么跑、做了什么、怎么验证的**。
游戏设定与剧情请见 [`README.md`](./README.md)（原始设计稿，未作改动）。

---

## 1. 快速开始

```bash
npm install        # 已安装过可跳过
npm run dev        # 开发服务器 → http://127.0.0.1:5183
```

生产构建与预览：

```bash
npm run build      # 产物在 dist/
npm run preview
```

### 操作

| 按键 | 作用 |
| --- | --- |
| `W A S D` / 方向键 | 移动 |
| `J` / 鼠标左键 | 攻击（累积连击） |
| `K` / `空格` | 闪避（有短暂无敌帧） |
| `Q` `E` / `1` `2` `3` | 释放武器技能（**消耗连击**） |
| `R` | 使用灯油（临时增强光照） |
| `E` | 与 NPC / 火盆 / 灯塔交互 |
| `Esc` | 暂停 |

### 调试入口（URL 参数）

```
?level=0|1|2     直接进入指定关卡
&skipdlg=1       跳过开场对白
&spawn=1         立刻刷出全部波次与 Boss（压测 / 截图用）
```

---

## 2. 技术栈与结构

**Vite + TypeScript + Canvas 2D**，手写游戏引擎，**不依赖任何游戏框架**。

```
src/
  main.ts            入口与场景状态机（标题/对白/过场/战斗/菜单）
  style.css          UI 主题（墨色 + 鎏金，衬线中日文字体）
  core/
    utils.ts         数学、斜轴测投影(sx/sy)、碰撞、种子随机
    input.ts         键盘/鼠标，含边缘触发 justPressed
    audio.ts         WebAudio 程序化音效与自适应配乐
  game/
    content.ts       武器/敌人/升级/商品/对白/设定文本
    levels.ts        三张地图：墙体、道具、波次、Boss、调色板
    world.ts         核心玩法：移动/攻击/闪避/连击/光照/敌人AI/Boss多阶段
    render.ts        2.5D 渲染：地面、立绘、深度排序、黑暗光照、屏幕外指示
    save.ts          localStorage 存档（向前兼容字段合并）
    ui.ts            HUD 与全部菜单界面
tools/
  sim.ts             无头逻辑仿真（Node 中跑真实游戏逻辑）
  make-verify.py     生成 dist/verify.html 与 dist/shot.html
  browser-verify.sh  真实浏览器渲染验证 + 截图（见第 4 节）
  cdp-report.mjs     备用：走 Chrome DevTools Protocol 取报告（交互排障用）
```

### 两个「零外部素材」的选择

- **美术**：全部角色/建筑/地形都是**程序化矢量绘制**（`render.ts`），没有任何图片文件。
- **音频**：全部音效与配乐都是 **WebAudio 实时合成**（`audio.ts`），没有任何音频文件。

构建产物合计约 124 KB（JS 114 KB / CSS 9.5 KB，gzip 后约 38 KB）。

### 2.5D 与黑暗光照怎么做的

- **斜轴测投影**：`YSQUASH = 0.62` 纵向压扁，实体按 y 深度排序，天然产生前后遮挡。
- **黑暗**：先把整屏用 `rgba(3,4,10, ambient)` 盖住，再用 `destination-out` 在光源处
  「挖洞」（`destination-out` + 径向渐变 + 纵向压扁成椭圆），最后用 `lighter`
  叠一层暖色加光——于是"光"是有温度的。连击越高，玩家灯的光圈越大。

---

## 3. README 需求对照

| README 要求 | 落地情况 |
| --- | --- |
| 2.5D 俯视角 | 斜轴测投影 + 深度排序 |
| 3 张地图（美好过往 / 遇难 / 踏上复仇） | 灯堡外庭 · 灯堡深处·无芯之暗 · 灯河渡口 |
| 1. 地图/背景制作 | 程序化地面纹理、墙体、灯塔、火盆、渡口、雕像、灯树… |
| 2. 武器特效 | 3 把武器，各自的挥击弧、刀光、特效与技能 |
| 3. 人物动画 | 程序化骨骼式绘制（待机呼吸、行走摆臂、攻击前倾、受击闪烁） |
| 4. 怪物生成与攻击动画 | 影仆/守卫/吸取者 + 3 个 Boss，含蓄力预警圈与攻击动作 |
| 5. NPC 及交互 | 掌灯人（商人，买卖武器/火种/明油/灯油）；盲女（同行情谊与复活机制） |
| 6. 物件交互 | 火盆（需 4 连击点燃）、灯塔（存档/升级/传送）、渡口（过河） |
| 7. 主线连贯 | 序章对白 → 三关演出 → 灯河过场 → V1 终章 |
| 8. 音效播放 | 程序化音效 + 随连击强度变化的配乐 |
| 每把武器自带技能，需连击解锁，**不同武器技能数与连击数不同** | 灯刃 2 技能（旋斩:4 / 灯爆:12）、长明枪 3 技能（掠光刺:3 / 连灯刺:9 / 长明贯:18）、烬锤 **1** 技能（撼地:7） |
| 灯芯升级血量与亮度 | 灯芯 ×3 项升级（生命 / 光照 / 锋锐），消耗灯芯 |
| 地图黑暗，只有灯骑士周围亮 | 见上一节 |
| 连击提高亮度，随时间变暗 | 连击驱动 `lightRadius`，停止命中后按 14/s 衰减 |
| 灯塔一关打完才亮；没打完死了回上一灯塔 | 清关才点亮并解锁；死亡从最近灯塔重生，灯火扣 25% |
| 一张图若干精英怪及一个 Boss | 每关 3 波杂兵（含精英）+ 1 个 Boss |
| 一图打完通过"灯河"去下一关 | 渡口目标 + 灯河过场动画 |
| 没灯芯、黑暗中怪与 Boss 不断再生 | 第二关：影子在黑暗中持续重生，需点燃 3 座火盆破除 |
| 盲女：灭了的古老灯芯，与灯骑士互相感应 | 同行 NPC；`盲女之灯` 让玩家多一次复活 |
| 过场词与台词 | 全部按 README 原文录入（`content.ts` 的 `DIALOGUES` / `LORE`） |

**V1 未做**（README 里属于更后续的设定）：灯神与灯魔、集齐灯芯、诅咒解除、盲女的最终命运。

---

## 4. 验证方式

分两层，互补。

### 4.1 逻辑层 —— `npm run sim`

`tools/sim.ts` 在 Node 里直接跑**真实的游戏逻辑**（打桩 `window`/`localStorage`，
用种子随机保证可复现），驱动机器人打通关卡，并做确定性链路测试。

```bash
npm run sim
```

> 这一层曾经抓到一个致命 bug：波次清理的判断写在 `spawned` 早退之后，
> 导致已清波次永远不会被标记为 cleared，**Boss 永远不出现**。
> 这种问题 `tsc` 和 `vite build` 都发现不了。

### 4.2 渲染层 —— `npm run verify`

`tsc`/`build`/逻辑仿真都**完全不经过 Canvas 绘制代码**，所以还需要真跑一遍渲染。

```bash
npm run verify         # 验证 + 抓截图
npm run verify:fast    # 只验证
```

做法：`tools/make-verify.py` 基于 `dist/index.html` 生成 `dist/verify.html`，
页面内部**同步推进**游戏循环（不依赖 `requestAnimationFrame` / 定时器），
逐关采样 `getImageData()` 与 DOM 状态，把结论写进 DOM 再由 `--dump-dom` 取出；
同时用 `dist/shot.html` 停在指定帧上供 `--screenshot` 抓图。

当前结果：

```
✅ 渲染有输出      ✅ 有丰富色彩      ✅ 三关均成像
✅ 三关有敌人      ✅ 黑暗光照系统    ✅ 有暖色灯光
✅ HUD已挂载       ✅ 技能槽渲染      ✅ 菜单可渲染
全部通过: True     JS 报错数: 0

关卡0 光照: 玩家处 204   四角 14/9/10/17
关卡1 光照: 玩家处 235   四角 11/7/7/12
关卡2 光照: 玩家处  91   四角 13/8/8/27
```

截图见 [`screenshots/`](./screenshots)。

### 4.3 环境坑（Arch / 容器里常见）

1. **`/tmp` 是 10 MB 的 tmpfs**。Chrome 的 profile 写不下就会 `SIGTRAP`/`SIGSEGV`
   崩溃。脚本因此把 profile 与临时文件都放到 `$HOME/.cache`。
   —— 这一条卡了很久：同样的命令时好时坏，根因就是 `/tmp` 空间。
2. **`--virtual-time-budget` 会在本机让 Chrome 崩溃**，不要用；所以验证页改成同步推进。
3. 本地回环要走 `no_proxy`：脚本里已 `unset HTTP_PROXY HTTPS_PROXY`，
   否则 curl/chrome 访问 `127.0.0.1` 会 502。

---

## 5. 已修缺陷（试玩反馈）

试玩反馈了两个问题：**与掌灯人对话后像是"被判定死亡"**、**返回标题黑屏**。
两个都排查并修好了，根因如下（均由 `npm run verify` 的回归用例锁定）。

### 5.1 返回标题黑屏

`#fade` 是全屏纯黑遮罩，`z-index: 30`，高于菜单层 `#overlay`。
`handleAction('totitle')` 会先 `fade(true)` 拉黑做转场，但 `toTitle()` 里
**没有配对的 `fade(false)`**（`startLevel` / `respawn` 都有）。
于是黑幕永远留在最上层——画布其实在正常绘制标题背景（实测平均亮度 23.6），
只是整块被黑幕盖住。

修法：`toTitle()` 补上 `fade(false)`，并顺手把 `pending` / `deathDelay` /
`cut` / `menuStack` 一并复位，保证回标题是干净状态。

### 5.2 与掌灯人交互后卡死

这里是**两个 bug 叠在一起**，表现都像"人死了动不了"。

**(a) 菜单返回栈压进了陈旧值。** `showMenu(kind, push)` 原本写的是
`if (push && this.menuKind) this.menuStack.push(this.menuKind)`。
但战斗中是 `mode === 'play'`，`menuKind` 还停留在上一次的陈旧值（通常是 `'title'`）。
于是在地图上按 E 开商店，栈里压的是 `'title'`；点「返回」就**弹出了标题菜单**，
且 `mode` 卡在 `'menu'`，世界停止推进——玩家按键没反应，看起来就像被判了死亡。

修法：返回栈改为 `MenuFrame = MenuKind | 'play'`，压栈时
`this.mode === 'play' ? 'play' : this.menuKind`；`backMenu()` 遇到 `'play'`
就 `closeMenu()` 回到战斗。

**(b) 死亡结算会被菜单吃掉。** 死亡后要等 1.9 秒倒地动画才出结算界面，但原来的写法是：

```ts
if (this.deathDelay > 0) {
  this.deathDelay -= dt;                                  // ← 不管什么模式都在减
  if (this.deathDelay <= 0 && this.mode === 'play') { … } // ← 模式不对就不弹
}
```

只要这 1.9 秒内处于菜单/对白状态（例如倒地瞬间按了 Esc 开暂停），
倒计时会在看不见的地方走完，**死亡界面永远不再出现**——`player.dead` 保持 `true`，
人被卡死在菜单里，只能刷新页面。实测：在商店中死亡后等 200 帧，
`menu` 仍是 `shop`，死亡界面始终不出现。

修法：倒计时限定在 `mode === 'play'` 内推进，倒完立刻弹结算；
同时倒地后禁止开暂停菜单（`!world.player.dead`）。

### 5.3 顺带修掉的

- **关卡三无法通关**：渡口按 E 会发出 `{type:'victory'}` 事件，但 `main.ts` 里
  写的是 `case 'victory': break;`（空实现），终章根本触发不了。
  已改为路由到 `handleAction('victory')`。
- **从菜单/对白回到战斗时给 1.1~1.4 秒无敌**，避免"刚关掉面板就被贴脸打死"的不公平手感。
- **商店/升级面板的底部操作条改为常驻**（`position: sticky`）。
  原来矮窗口下「返回」会被滚出可视区，玩家找不到出口。

### 5.4 回归测试

上面每一条都在 `tools/make-regress.py` 里有对应用例（15 条断言），
随 `npm run verify` 一起跑。这些缺陷**只在多个界面来回切时才暴露**，
逻辑仿真（`npm run sim`）和类型检查都覆盖不到。

---

## 6. 已知限制

- 渲染验证是**像素与状态层面**的（亮度分区、配色多样性、DOM 文本），
  它证明"画出来了、光照在起作用、没有 JS 异常"，但**不能替代人眼对美术风格的判断**。
- `tools/cdp-report.mjs` 是另一条基于 DevTools Protocol 的取报告路线，
  本环境后台启动 Chrome 会被沙箱打断，故当前入口未使用它，留作交互排障。
