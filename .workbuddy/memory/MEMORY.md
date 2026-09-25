# 灯骑士（dengqishi）· 项目长期记忆

## 项目是什么
「灯骑士 / LightKnight」——地图全黑、只有灯骑士周围些许亮光的小游戏。
**同一游戏有两份实现，故意的**：
- **Web 版**：Vite + TypeScript + Canvas，`src/`，入口 `index.html`。
  只有 **3 把武器**，有一到三关的数值、商店/升级/存档。
- **Godot 版**（`godot-lightknight/`）：Godot 4.7.2。起步于「光能不能被墙挡住」的
  迁移实验（结论：**能**，Web 版 Canvas 合成光照没有遮挡关系），
  **现在已经跑在前面**：8 把武器 / 19 技能 / 14 恩赐 / 肉鸽三选一 / 精英词缀 /
  第二关「无芯之暗」，这些 **Web 版都没有**。

### ⚠️ 权威归属（2026-09-24 起改了）
旧约定「跨版本改玩法以 Web `src/game/*.ts` 为准，Godot 照抄」**已作废**。
- Web 独占：商店/升级/存档、一到三关的数值基准。
- **Godot 独占（唯一实现）**：8 武器/19 技能、恩赐三选一、精英词缀、
  种子随机波次、第二关及其火盆再生/盲女/分阶段 Boss、敌人「扑灯蛾」。
- 动这些内容前先决定以哪边为准，**别默认 Web 是权威**。

## 硬约定
1. **`README.md` 是用户给的原稿，不要覆盖**。实现说明另开文件
   （`IMPLEMENTATION.md`、`godot-lightknight/README.md`），原稿最多加一行指引。
2. **交付物必须能被验证**：写完代码要真跑起来，用真实引擎/真实浏览器证明，
   不接受「应该可以」。每个验证都固化成 `tools/*.sh` 一键脚本。
3. **多界面切换的缺陷测不到**：类型检查、构建、纯逻辑仿真覆盖不了
   「返回栈错乱 / 遮罩残留 / 结算被菜单吃掉」。这类必须真浏览器跑完整交互流程。
4. 断言针对真实状态，别假设理想位置；累计计数用基线增量，别硬编码。
5. **全绿 ≠ 有意义**：断言写完必须做一轮**变异测试** —— 故意改坏实现，
   确认**只有**对应断言变红、没有连带误伤。工具是 `tools/godot-mutate.py`（见下）。
   本轮（布局随机化）4 个变异全部符合预期，且**"同种子逐点相同"那条始终没红**
   —— 证明随机化没有砸掉确定性自检的地基。

## 一键验证脚本（tools/）
- `tools/godot-lightknight.sh` — Godot 版完整自检（**232/232 断言**，rc=0，
  连跑两遍 `shots/report.json` **逐字节相同**，基线 md5 `dfcee4db0aa0fc92d8703bde07502d6b`）
- `tools/godot-mutate.py` — **变异测试**（故意改坏实现，确认只有对应断言变红）。
  备份在 `~/.cache/dq-mutate/src.bak`；`--list` / 名字过滤 / `--restore-only`。
  ⚠️ 它**刻意不用 `shutil.rmtree`**（沙箱批量删除保护会拦，导致"还原失败、改坏的源码留在盘上"），
  改用 `copytree(..., dirs_exist_ok=True)` 覆盖式还原。
- `tools/godot-probe25d.sh` / `godot-probe.sh` — 迁移前的遮挡体探针
- `tools/browser-verify.sh` + `make-verify.py` / `make-regress.py` / `make-hunt.py` — Web 版浏览器验证

## 本机环境坑（会反复遇到）
- **沙箱有「批量删除保护」**：一次删 >50 个文件会被拦
  （`[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED]`），**连 Python 的 `shutil.rmtree` 也拦**。
  脚本里"备份→改→rmtree 还原"会在还原那步崩掉，**把改坏的文件留在盘上**。
  → 还原/同步一律**覆盖式复制**（`shutil.copytree(dirs_exist_ok=True)` / `cp -a bak/. live/`），只写不删。
- 沙箱预置了 `HTTP_PROXY/HTTPS_PROXY` → **本地回环会 502**，命令前必须 unset。
- **`/tmp` 是 10MB tmpfs**。`TMPDIR` / `--user-data-dir` / 截图输出一律放 `~/.cache/` 下，
  否则进程写满就崩（症状是「同样命令时好时坏」，极难排查）。
- 无头浏览器只有 `/usr/bin/google-chrome-stable`（无 firefox/playwright/puppeteer）。
  用 `--headless=new`；**`--virtual-time-budget` 在本机必崩，不要用**；
  `--dump-dom` 比 `--screenshot` 稳。
- Godot：`/usr/bin/godot` 4.7.2 标准版（非 mono），`gl_compatibility` + llvmpipe 软渲染，
  `DISPLAY=:1`（XWayland）。
- **Godot 自检不能 `--headless`**：dummy 渲染器读不出 SubViewport 像素，
  而判定「黑不黑、光有没有被挡」全靠读像素。
- 本机无声卡（ALSA 打不开）→ Godot 回落 dummy 驱动，音频代码正确但**听不到声音**。

## Godot 版关键设计（改之前先读）
- 固定步长 `Main.advance(1/60)`，**游戏 `_process` 累加器和自检直接调用走同一条代码路径**。
- 输入自己实现边沿检测（`GameInput.just()`，靠每步 `sample()` 比较），
  **不用 `Input.is_action_just_pressed()`**（固定步长 + 脚本驱动下语义不可靠）；
  `set_override()` 供自检注入。
- **有两种界面会让世界停住**：`main.state == "dialogue"`（对白）和 `"draft"`（三选一），
  两者都不调 `world.step()`。自检的 `_pump(n, hold, auto_draft, auto_dialogue)`
  默认两种都自己点掉；专门要验它们的那几段把 `auto_*` 关掉。
  **少点一种 → 后面所有段落成片变红**（敌人不动/镜头不跟/盲女不跟人走），极难反查。
- **参与仿真的随机数必须来自种子**。`EnemyState.wob` 曾经用全局 `randf()`，
  而它直接进 `vx/vy`（`sin(e.t*1.6+e.wob)`）→ 每趟世界都不同。
  现在按 id 铺黄金角 `fmod(float(eid)*2.39996323, TAU)`。
- **多推一步都会挪动 RNG 流**。为了加截图多走 6 步，撞掉了几十条断言之后的一条；
  要补回来（`_pump(6)`+截图+`_pump(74)`，总数仍是 80）。
  **但 `_shot()` 本身不推世界**（只 await 两帧 `frame_post_draw`，不调 `main.advance`），
  所以插截图是安全的 —— 危险的是"为了取景多 `_pump`"。另注：`_write_png` **自己补 `.png`**，
  传 `"12-draft.png"` 会落盘成 `12-draft.png.png`。
- **三选一输入是"两段式"**：只有 `Q`/`E` 移高亮（`draft_prev`/`draft_next`），
  只有 `空格`/`回车` 拿走，`Esc` 放弃。`1`/`2`/`3`、`A`/`D`、`J`/左键**全部无效**
  （用户明确要求"别的键无效，不然容易误选"）。另有 **0.35 秒装填窗口** `Main.DRAFT_ARM`：
  面板刚弹出的 0.35 秒内按确认无效，防"清波瞬间正在连打空格"的误触。
  这几条在自检里是**逐条可失败**的断言，别删。
- **"对比前 vs 对比后"必须把其它变量冻住**：光照半径里有 `combo`、`glow`，
  而 `glow` 一旦被写成 1.0 就**不再衰减**（只有 Boss 倒下时才写成 1.0）。
  盲女 +52 那条最初测出 `248 -> 248`，是基准值本身已含 +52，不是逻辑错。
- 玩家脚下的烘焙光池 `_draw` 画的、**不认遮挡**，故意保持很小（`0.26×`/`0.15×`），
  真正的照明交给会被墙挡住的 `PointLight2D`。
- 叠加层（`Bloom`）必须显式 `queue_redraw()`，Godot 不会因为子节点父级标脏就自动重绘。
- 遮挡体 = **屏幕上画出的整体轮廓（顶面 ∪ 南立面），只削底边 16px**（`LightRig.OCC_TRIM`）。
- 灯贴图必须**竖向压 0.62**（= 投影 `YSQUASH`），否则地面上南北比东西多照 70%。
- **Boss 招式池分阶段**：满血 phase 1 只有 `dash/dash/slam/summon`，
  **放不出 `beam`**；掉到 1/3 进 phase 3 才有 `drain`/`sweep`（都放 beam）。
- 自检确定性靠 `level["seed"]`（第一关 10711、第二关 20422）。

## 美术 / 素材层（2026-09-24 新增）
- 素材**运行时加载**，故意绕开 Godot 导入管线：
  `Image.load_from_file(ProjectSettings.globalize_path(...))` → `ImageTexture.create_from_image`。
  好处：裸仓库跑一键自检**不需要** `.import` 文件、也不依赖 `.godot/imported`。
  代价：无 mipmap/压缩 → 贴图**预先手动降采样到 256×256**（不降采样会有采样噪点）。
  入口在 `art.gd`：`ensure_assets()` / `tex()` / `tex_rot()` / `soft_dot`。
- **程序化为主、贴图只做点缀**。几何（地形/角色/灯）仍全用 `draw_*`；
  贴图只用在渐变与粒子这类手画不好看的地方（挥击弧/火花/拖尾/火焰/余烬）。
- **光晕是生成的渐变贴图**（`soft_dot`，smootherstep 衰减），不再是几十个同心圆
  （同心圆近看是一圈圈环）。
- **HUD 用自绘控件**，不用 `StyleBoxFlat`（做不到渐变条 / 辉光 / 扇形冷却）：
  `RBar`（血条/灯条/Boss 条 + 滞后残影 + 冷却刻度）、`SkillChip`、`DraftCard`、
  `ArmBar`、`PanelLamp`。卡片按 `_boon_sig` 签名缓存，内容没变就不重建。
- HUD 上叠了**暗角后处理层**。做像素采样断言前必须 `hud.set_post_enabled(false)`，
  否则暗角会污染「黑不黑 / 光有没有被挡」的判定。
- 素材许可（都已进仓，可整包复制）：Kenney Particle Pack **CC0 1.0**、
  霞鹜文楷 LXGW WenKai **OFL-1.1**（`assets/`下）。展示字体取不到时回退系统 noto-cjk。
- Godot 4 三个易错点：`content_margin_*` 属于 `StyleBoxFlat` 而**不是** `PanelContainer`；
  内部类引用外层常量必须写 `Hud.C_XXX`；`var _ready := false` 会撞 `func _ready()`。
- **rc=1 不等于断言红**：`skill_cd_max` 那次是 152/152 全绿但每帧打
  "Invalid access to property or key"（还级联出空技能名）。**必须单独看 `report.json.errors`。**

## 宝箱 / 背包 / 守灯人（2026-09-25 新增）
- **宝箱**：每关 2 个（第二关也各 2 个）。按 `E` 开 → **复用三选一面板**出 3 把武器 → 选中进**背包**。
  `state == "draft"` 但 `main._panel_kind == "chest"` 区分；开过的箱子不复活。
- **背包**：只多带**一把**武器（`prog["bag_weapon"]`）+ 存的回血道具（`prog["shop"]["oil_bank"]`，
  这个字段原本就有、只有掉落往里加、**从来没有地方消费**，现在成了背包里的灯油）。
- `X` 换手（手持 ↔ 背包；**背包空时什么都不做**）；`C` 喝灯油（回 45%；**没药 / 满血都不消耗**）。
- **守灯人**（原「掌灯人」，已统一改名）= 商店：买灯油 22 / **重铸** 45 / **锤炼** 30+15×等级和。
  · **重铸** = 词条全部推倒重来（随机 1~3 条、等级归 1、互不重复）
  · **锤炼** = 没满 3 条就加一条；满了就升一级；全到 5 级后**不受理也不收钱**
- **8 条词条**（锋/疾/远/锐/噬/明/火/省）全部落在**已有派生属性访问器**上
  （`damage_mul` / `attack_cd_mul` / `reach_mul` / `crit_chance` / `combo_bonus` /
  `skill_cost` / `player_light_radius` / `_kill_enemy`），**不要在别处再乘一遍**。
- **词条挂在「武器 id」上**（`prog["waffix"] = {武器id: [{id,lv}]}`），不是挂在"当前手持"上 →
  换手不丢、换回来还在。有专门断言。

### 两个"别搅动已量好的世界"的硬约束
1. **加道具绝不能直接往 `level["props"]` 里塞**！`props` 每项都要 `_decor_rng.randi_range`
   抽 seed，且 `_decorate()` 会躲开已有道具 120px —— 提前加会让**整关装饰换位置**，
   依赖装饰的像素断言成片变红。→ 宝箱走**单独的 `chests` key**，在 `_decorate()` **之后**
   才入 `props`，用独立的 `_chest_rng`。
2. **宝箱故意不 solid**，否则会插进 `collide_wall` 的推挤，把动线/撞墙断言搞崩。
3. **随机源分家**：`_rng`(主仿真) / `_decor_rng`(装饰) / `_shop_rng`(商店) / `_chest_rng`(宝箱)
   / `_layout_rng`(布局随机化)。**除 `_rng` 外全部不得走主仿真流** —— 主仿真流里每步
   消耗多少由"玩家第几步走到哪儿"决定，往里插随机数会把之后所有演化整体挪掉。

## 布局随机化（2026-09-25 新增）：宝箱 / 波次锚点 / Boss 场地每局重摇
- `World.run_seed`（由 `Main.run_seed` 传入）+ `_layout_rng = Proj.make_rng(hash([run_seed, level_index, "layout"]))`。
  另存 `boss_anchor`（Boss 触发用的运行时坐标）与 `layout_info`（进 report 的布局快照）。
- `Main`：标题开局走 `new_run()`（换种子）；**死亡重开 `restart_level` 不换种子**（同一局同一张图）。
  自检里 `main.run_seed = selfcheck.LAYOUT_SEED (=20260925)` 钉死。
- 生成入口：`World._roll_chest_spots(fallback)` / `_roll_anchors()`（Boss + 每波）/
  `has_los(x0,y0,x1,y1,thick)`（直线采样判通路）/ `_reachable_spot()`（不耗 RNG 的环形兜底）。
  `level["chests"|"waves"|"boss"]` 里的坐标**只是数量与兜底值**。
- 约束：宝箱（离墙 26 / 离出生点 240 / 离灯塔 200 / 避 props `96+r` / 箱间距 320）。
  锚点（Boss 净空 120、离出生点 480、离灯塔 260；每波净空 74、离出生点 360、离 Boss 380；
  **相邻锚点距离卡 460~900 上下限** —— 太近会让清一波顺手清掉下一波，太远链条被拉断、
  实测机器人只清得掉两波）。
- **可达性是最值钱那条**：`blocked()` 只能查"点在墙里"，查不出"与玩家之间隔着一道墙" ——
  后者不报错、不抛异常、只是那波永远清不掉 → **关卡静默卡死**。
  所以用 `has_los` 做**链式**可达（第一波↔出生点，之后↔上一波；别都对着出生点判，会过严到退化兜底）。
  ⚠️ 诚实边界：`has_los` 是**约束与断言共用**的同一函数，写坏了会一起被骗；
  真正的独立证人是端到端的「机器人清完了三波」。
- 实测反直觉点：**手写那份布局本身不满足链式可达**（第 1 波 `(830,830)`、第 3 波 `(1980,700)`
  相对上一锚点都没直线通路，连 出生点→Boss 也没有）—— 它是按"绕过去"设计的。
  随机撒点才用更严的"必须直着走得到"。

### ⚠️ 新增一个"能冻结世界"的机制：`waves_disabled` 沙盒开关
锚点随机后，某波可能落进自检早期某段的活动范围 → **意外刷出 → 被顺手清掉 → 判"清空" →
弹三选一 → `state="draft"` → 世界冻结** → 几百行后看似无关的断言失败（实测 `_tap("attack")`
之后 `state` 竟是 `draft`、弩矢没射出）。
→ `Main.waves_off` → `World.waves_disabled`，在 `_update_waves()` **开头早退**（运行时每步读，
可中途开关）。自检**默认 `waves_off=true`**，只有波次段/第二关段放开、且**先 `restart_level()`**。
⚠️ 别在 setup 里标记（那样会漏掉"清一波弹三选一"的验证，实测 29 条断言被跳过）。

### 三个"冻结世界的界面"（最容易把自己搞死）
`dialogue` / `draft`（**开宝箱也走这个状态**）/ `shop`。
`_pump(n, hold, auto_draft, auto_dialogue, auto_shop)` 默认**三个都自己处理掉**；
少点一个，后面所有段落会成片变红（敌人不动、镜头不跟、灯不亮），极难反查。
三个面板的收尾统一走 `_resume_play()`。

## 仓库 / 版本控制（2026-09-25 起）
- 远程 `origin` = **`git@github.com:Tino912/dengqishi.git`**（SSH，密钥 `/home/tino12/.ssh/id_rsa`）。
  **沙箱里 push/pull 要绕三层墙**（系统 ssh 配置属主、uid 与 `$HOME` 不一致、私钥读取需授权）——
  可复制的写法与诊断手法见 skill **`git-remote-in-sandbox`**。
- 仓库原来**没有 `.gitignore`**，`.godot/` 缓存、`node_modules/`、`.Trash-0/`（桌面回收站）
  全被跟踪，是噪音与冲突的主要来源。已加 `.gitignore` 并把这三类**移出跟踪**
  （`git rm -r --cached`，磁盘文件未删）。`shots/` 与 `dist/` **保持跟踪**（是给人看的产物）。
- 提交历史：`7b95646`（基线）→ `c5e8ed2`（宝箱/背包/守灯人那轮）→ `64886d7`（清理 + .gitignore）
  → `e9c6ba6`（修回全屏闪光残留 ×2 + 三选一徽记错位，+8 断言）→ **`9d6d361`（宝箱与敌人落点每局随机生成，+9 断言）**。
- ✅ **那三个 bug 我们已自己重新实现**（2026-09-25，不是 cherry-pick；PR 的 diff 套不上，
  因为宝箱那轮改过同样的 4 个文件）。原 PR = fork `maxlen727/LightKnight-rev@fix/godot-fx-residual`，
  提交 `55cb837`，原合并提交 `1a9f2a8`（已被强推掉，但 GitHub 永久保留 `refs/pull/1/head`，
  `git fetch origin refs/pull/1/head` 可取回对照）。三条修复落点：
  ① `hud.refresh()` 的 `else` 分支把 `flash_rect.color` 写回透明；
  ② 闪光衰减抽成 `World.tick_fx(dt)` 由 `main.advance()` **无条件**调用
     （**同时必须从 `step()` 里删掉**，否则双重衰减）；
  ③ `Hud.EMBLEMS` 按 `content.gd` 的 `WEAPONS`/`BOONS`/`WEAPON_AFFIXES` 重写。
  → 另注：这三条修复**顺手清掉了一个像素采样的污染源**，遮挡断言的余量大幅变好，
  详见 daily log 与 skill `godot-headless-verify` 8.9。

## 已知待办（未做）
- Godot 版只有**两关**；设计稿的第三关（盲女被吃→化为力量）未做。
- ~~Godot 版无商店~~ → **已有守灯人商店**（买灯油/重铸/锤炼）；但仍**无升级/存档/传送**，
  局内成长 = 三选一 + 宝箱 + 词条。无手柄触屏。
- ~~上面「已知回归」那三条（红闪残留、红闪卡结算、恩赐徽记）尚未自行修回~~
  → **2026-09-25 已自行修回**（见「仓库 / 版本控制」节），并各补了回归断言。
- **像素采样要注意没被"关后处理"开关覆盖的叠加层**：`set_post_enabled(false)` 只关暗角，
  **管不到全屏 `flash_rect`**。残留闪光会给每个采样点加常数、压平比值型断言。
- 敌人弹道只做了 leech；`spitter` 手感未与 Web 逐帧比对。
- **Web 版 `render.ts` 的 `applyLighting` 用 `createRadialGradient` 画屏幕正圆**，
  在 2.5D 地面上是椭圆 → 南北多照 60%。**与换引擎无关，可独立先修**（竖向压 YSQUASH）。
