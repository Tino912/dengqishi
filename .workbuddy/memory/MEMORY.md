# 灯骑士（dengqishi）· 项目长期记忆（索引）

⚠️ **细节在同目录 `DETAIL-godot.md` —— 改代码前先读它。**
另有 skill：`godot-headless-verify`（离屏像素自检）、`git-remote-in-sandbox`（沙箱内推远端）。

## 是什么 / 权威归属
地图全黑、只有灯骑士周围些许亮光的游戏，**两份实现，故意的**：
- **Web 版** `src/`（Vite + TS + Canvas）：3 武器、三关数值、商店/升级/存档。
- **Godot 版** `godot-lightknight/`（4.7.2）：**跑在前面** —— 8 武器 / 19 技能 / 三选一 /
  精英词缀 / 种子随机布局 / 三关三图 / 5 元素与状态效果 / 攻击发光 / 夜色 / 迷雾，
  这些 Web 都没有。
⚠️ 旧约定「跨版本改玩法以 Web 为准」**已作废**；动之前先决定以哪边为准，**别默认 Web 是权威**。

## 硬约定
1. 根 `README.md` 是**用户给的原稿，不要覆盖**；实现说明另开文件（`IMPLEMENTATION.md`、
   `godot-lightknight/README.md`）。
2. 交付物必须**真跑起来**验证（真引擎 / 真浏览器），不接受「应该可以」，固化成一键脚本。
3. 多界面切换类缺陷（返回栈错乱 / 遮罩残留 / 结算被菜单吃掉）类型检查、构建、纯逻辑仿真
   都覆盖不了 → 必须真浏览器走完整交互流程。
4. 断言针对真实状态；累计计数用**基线增量**，别硬编码。
5. **全绿 ≠ 有意义**：写完断言必须跑一轮**变异测试**（改坏实现，确认只有对应断言变红）。
6. **绝对断言要与相对断言配对**：整片「比基准多多少」的断言，在基准被改坏时全都不响。
7. **变异"没红"要先分清两种情况**：补丁没打在生效的那一层，还是**断言问错了问题**。
   后者（断言对该失败方式天然不敏感）要**让旋钮转一下** —— 同一帧只改一个变量做前后对照，
   **不是把阈值调松**。

## 当前基线
- `tools/godot-lightknight.sh` — 自检 **358/358**，约 30 秒，连跑两遍 `report.json`
  **逐字节相同**（md5 `b65e9c4d0d6440892d51ec6f208bae0f`）。超过两分钟没好通常是脚本
  没起来，先 grep `SCRIPT ERROR|Parse Error`。
  ⚠️ **rc=1 不等于断言红** —— 必须单独看 `report.json.errors`。
  ⚠️ **别在测试跑的时候改脚本/源码**（它会反复调用自检，中途改会污染整轮结果）。
- `tools/godot-mutate.py` — **25 个变异**，备份 `~/.cache/dq-mutate/src.bak`。
  ⚠️ 刻意不用 `rmtree`（沙箱批量删除保护会拦 → 还原失败、坏源码留盘），改用
  `copytree(dirs_exist_ok=True)` 覆盖还原；⚠️ src 改过后它拒绝覆盖旧备份，先把 `src.bak`
  **改名存档**（别删）再重跑。
- 另有 `godot-probe*.sh`（迁移前遮挡探针）、`browser-verify.sh` + `make-*.py`（Web 版）。

## 三个最容易踩的坑（其余见 DETAIL-godot.md）
1. **沙箱「批量删除保护」**：一次删 >50 个文件会被拦（连 Python `shutil.rmtree` 也拦）
   → 还原 / 同步一律**覆盖式复制，只写不删**。
2. **`/tmp` 只有 10MB**（写满就崩，症状是「同样命令时好时坏」）+ 预置 `HTTP_PROXY/HTTPS_PROXY`
   会让本地回环 502 → `TMPDIR` / `--user-data-dir` / 截图输出一律放 `~/.cache/` 下，
   跑命令前先 unset 代理。
3. **自检里「少点一种冻结界面的自动点击」→ 后面成片变红**（敌人不动 / 镜头不跟 / 灯不亮），
   极难反查。会冻结世界的有四种：`dialogue`、`draft`（**开宝箱也是这个状态**）、`shop`、
   `World.waves_disabled`。

## 仓库
`origin` = `git@github.com:Tino912/dengqishi.git`（SSH）。沙箱内 push 见 skill
`git-remote-in-sandbox`。`.godot/`、`node_modules/`、`.Trash-0/` 已移出跟踪；`shots/`、
`dist/` **保持跟踪**（给人看的产物）。
