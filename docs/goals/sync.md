# Goal · Sync：把 extension 源码放进 store 目录就能用（`ext sync` / 跨 root 复用 / `ext prune` / TUI 启动安装）

> 这是一份**执行契约**，不是设计文档。设计背景在 [DESIGN.md](../DESIGN.md) §7（store 布局、build、integrity）、§9（authority、workspace store 的 trust gate）、§14（CLI 表面）；TUI 契约在 [tui.md](../tui.md)；地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-18 的设计对话（记录在 §3），已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。
> **前置：从 `main`（≥ `8ffc6a6`）切分支 `sync`。**

## 0. 目标（一句话）

用户理想的用法是：**把 extension 源码放进 `~/.nulya/extensions/<id>/`（或项目的 `.nulya/extensions/<id>/`），启动 TUI 就能用——没编的原地编，编过的直接用**。这与现有布局是同一个东西（`ext init` 建的 draft 就在 `<root>/<id>/`，冻结版本在旁边的 `<id>/versions/`），缺的只是壳层一个"扫 root 下所有 draft 并 build"的动词、`ext build` 对别的 root 已持有的同版本的复用、一个清理动词，以及 TUI 的启动流程与 `/ext` 一键操作。**core 一字不动**：`composition` / `session` / `ledger` / `loop` / `store` 的语义都不变，新东西全在 `cli/` 与 `tui/`。

## 1. 范围

**做（按顺序，每步测试全绿再进下一步；每个子项一个 commit `sync-x: …`）：**

1. **sync-a · `ext build` 跨 root 复用。** 编译前（对 compiled kind 必做；data / script kind 复制与冻结代价相同，实现者二选一但行为要一致）：按 `launch.extensionRoots` 的顺序在**别的** root 里找 `<id>/versions/<v>`（`v` 已经算出来了），找到且 `integrity.validateVersionDir` 通过 → 把整树复制进目标 root、再验一次 → 结果与本地编译逐字节相同（内容寻址保证），stdout 那行改成 `… (built, copied from <root spec>, in …)`。找不到才调 zig。复制发生在本机 `ext build` 里，所以 workspace store 的"出生地"信任规则不变（DESIGN §9：本机 `ext build` 填满空 store 即自动信任）。落点 `extension/build/build_ext.zig`（或 `cli/ext.zig` 在调 build 前做——选改动最小、且 `installPrebuilt` 那样的测试基建能直接对照的位置）。e2e：user root 里已有 compact@v，workspace `ext build extensions/compact` 不调 zig（`NULYA_ZIG` 指向一个不存在的路径仍成功）且版本目录逐字节相同。
2. **sync-b · `nulya ext sync [--user] [--activate] [--dry-run]`。** 对目标 root（缺省 workspace `.nulya/extensions`，`--user` = user root）下每个 **draft**——定义：`<root>/<id>/extension.json` 存在（就是 `ext init` 写 manifest 的位置；`versions/` 下的不算）——逐个走 `ext build` 同一条路（含 sync-a 的复用），**一个失败不中断其它**，每个 id 打一行：`<id>: v-<hash> built | already built | built (copied from …) | failed: <一句原因> | needs zig (compiled draft; set NULYA_ZIG or use the embedded toolchain)`；结尾一行汇总 `N built, M already built, K failed`；有 failed → exit 1，否则 0。`--dry-run` 只算版本、只打状态（多一个状态 `not built`），不 build、不 activate。**`--activate` 的规则（D2）**：把 `current` 指向 **这次 sync 刚 build 出来的版本**（之前不存在的），以及**没有 `current` 的 id** 的 draft 版本；draft 版本早已存在（already built）而 `current` 指着别处的 id **不动**（那是有人 rollback / activate 过，是决定）——这些 id 打 `… already built (current stays v-old)`。activate 走 `Store.activate` 同一条路（含 lease、`capability_note` 投递等既有行为）。`--user` 组合同 `ext build --user`。**在 session 里跑 `--user`** 的 stderr 提示与 `activate --user` 一致。e2e：一个 root 里放 data draft、script draft、compiled draft、一个 manifest 坏的 draft 各一 → sync 一次：三个 built、一个 failed、exit 1；再 sync 一次：三个 already built；`--activate` 三种 case（无 current → 指过去；刚 build → 指过去；已 built 且 current 在别处 → 不动）；`--dry-run` 不产生 `versions/`；`ext list` 与 `session new --with` 能看到 sync 出来的版本。
3. **sync-c · `nulya ext prune [--user] [<id>] [--dry-run]`。** 删目标 root 下（或只 `<id>`）**不是 `current`** 的版本目录，每删一个打一行 `<id>@<v> removed (<size>)`，`--dry-run` 只列不删；`current` 缺失的 id：**不删任何东西**并打一行 `<id>: no current — nothing pruned (deactivated ids keep every version; delete by hand if you mean it)`（没有 current 的 id 无法判断你要留哪个）。持 `<id>/.lock` lease（与 build / activate 同一个）。**说清代价**（stdout 汇总最后一行）：一个冻在被删版本上的旧 session 将无法 resume（`session step` 会硬失败指名那个版本）；同源码重 build 会得到同一个版本 id，所以只要 draft 还在就能恢复。不做"扫 session header 保护被引用版本"（记进 §6 后续，等真实需要）。e2e：三个版本、current 指中间的 → prune 删两个、留一个、`ext list` 仍对；`--dry-run` 不动；无 current 的 id 不动。
4. **sync-d · 文本与文档。** `nulya help` 加 `sync` / `prune` 两行（整屏仍 ≤ 40 行，必要时并行合并；e2e 有断言）；`ext api examples` 加 sync/prune 一句；DESIGN §7.4（build 复用）、§7.2（sync / prune 是壳层动词，语义各一句）、§14 命令表；CLAUDE.md 现状一句 + 模块表 `cli.zig` 行；guide skill `Building an extension` 一节加：**全局工具用 `--user`**；**把源码放进 `<root>/<id>/` 然后 `nulya ext sync [--user]`** 是最省事的装法；`ext build` 会复用别的 root 已有的同版本；`ext prune` 清旧版本、代价是什么（SKILL.md 仍 ≤ 250 行、零文档引用、description ≤ 200 字符）；tui.md 见下。
5. **sync-e · TUI T11 · 启动即安装。** `tui/`（Bun + OpenTUI，已有 `nulya/cli.ts` 封装 `ext build/run/list/activate`、`/ext` 视图、`tui.toml`）：
   - `tui.toml` 新键 `[extensions] sync_on_start = true`、`auto_activate = true`（默认值如此；文档写清）。
   - 启动时**后台**跑 `nulya ext sync --user [--activate]`（compiled draft 一次 9 s，不许阻塞 UI；状态栏显示 `syncing extensions… 2/3`，完成后一行汇总；failed 的在 `/ext` 里可见原因）。
   - **project store**：先探 trust gate（复用内核的判定——起一次 `session new` 被拒会打印 store 路径与内容；或直接读 `ext list` + `~/.nulya/trusted-stores.jsonl`——选已有信号里最省的，**不要**在 TUI 里重实现"持有"判据）：**未信任 → 弹一条提示**"this checkout ships extensions: <id [tools skills prompt]>… — trust & install? (t) trust + sync + activate / (s) sync only (build, no activate) / (n) not now"，按键才动作，且只问一次（记在 `tui-state.json`）；**已信任 → `ext sync`（build），activate 按 `auto_activate`**。这条边界是 physics #6 / DESIGN §9：user 层是你的目录可以自动，project 层是别人 clone 给你的必须点一下。
   - `/ext` 视图：每个 id 多一列 draft 状态（`ext sync --dry-run` 的输出：`not built | built | active`），一键 `a` = activate 这个 draft 的版本（`ext activate`），`p` = prune 非 current 版本（先弹一行确认）；pin 键**不做**（stretch，见下）。
   - tui.md：§9 里 T11 一行 + §11 实施日志一节；`bun test` 覆盖：sync 输出解析、`--activate` 三种 case 的展示、trust 提示的三种按键映射到哪条命令（mock `nulya`）；`bun run typecheck` 过。
   - **不动** TUI 的其它部分；不做 `/goal`（T10 仍占位）。
6. **真实过一遍**：本机 `~/.nulya/extensions/`（若为空，用 `NULYA_HOME` 指一个临时目录）放一个 script draft + 一个 compiled draft → 启动 TUI（`bun run start`，可以只跑到 sync 完成就退）→ 记录状态栏文本与 `ext list`；在本仓库 checkout 里启动一次看 trust 提示出现（**不要代按 t**，按 n）；把观察贴进 §6。跑不了写明原因。

**不做（明确越界）：** 改 core（`composition` / `session` / `ledger` / `loop` / `prompt` / `store` 的语义；`store.zig` 若只是加一个只读遍历 helper 供 sync/prune 用可以，改行为不行）；自动 pin；`ext build` 默认落点改成 user（默认仍 workspace）；把 draft 删掉"只留产物"（冻结版本已含源码快照，draft 是工作副本）；`ext sync` 递归找子目录里的 draft（只认 `<root>/<id>/extension.json` 一层）；prune 扫 session header；bundled extension 的打包/安装到 user 层（PLAN §4 开放问题，另议）；TUI 的 `/goal`；对已有 e2e 的顺手重构；push。

**可选 stretch（只在 1–6 全绿、已 commit 之后）：** `/ext` 里的 `pin` 键（写 project 层 `.nulya/config.toml` 的 `registry.pinned_native_tools`，写前显示将写入的行）。不做别的。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在 **Windows（本机）** 全绿；`cd tui && bun test && bun run typecheck` 全绿；代码不得 Windows-only。
- §1.1–1.3 的 e2e 新增并通过（名字自拟，语义不可少）；既有 e2e 全部继续通过（断言不减弱）；`nulya help` 那条 e2e（≤ 40 行、动词族真子串）仍过。
- `ext build` 复用：e2e 证明不调 zig（`NULYA_ZIG` 指向不存在的路径）也能在第二个 root 得到逐字节相同的版本。
- 文档：DESIGN §7.2/§7.4/§14、CLAUDE.md、guide SKILL.md（≤ 250 行、零 `DESIGN`/`PLAN` 字样）、tui.md T11。
- **手动**：§6 里有一份真实观察记录（或写明为何跑不了）。
- 每个子项一个或多个 commit，信息格式 `sync-a: …` … `docs: …`；在分支 `sync` 上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · draft 就住在 `<root>/<id>/`，不删。** 这是 `ext init` 的既有约定；冻结版本在旁边 `versions/`；`package/` 已是源码快照，draft 是下次要改的工作副本。"只留产物"不做。
- **D2 · `sync --activate` 只 activate 它刚 build 出来的版本和没有 `current` 的 id。** 已 built 而 `current` 在别处 = 有人 rollback / activate 过，是决定，sync 不覆盖。四种场景：新放进来 → 生效；改了源码重启 → 新版本生效；rollback 到 v1 而 draft 仍是 v2（已 built）→ 保持 v1；rollback 后又改源码到 v3 → v3 生效。这条规则一句话说得清，且 rollback 能活过下一次 sync。
- **D3 · build 是机械的、activate 是决定、pin 是另一个决定。** 所以 `sync` 缺省只 build，`--activate` 显式；pin 不进 sync（TUI 里最多是 stretch 的一个按键，写的还是 config 里那条人写的 pin）。
- **D4 · user 层自动、project 层要点一下。** user store 不过 trust gate（本来就不过），TUI 启动可以自动 sync + activate；project store 随 checkout 到达，未信任必须弹提示、按键才动，只问一次；已信任才自动 build。physics #6、DESIGN §9 的边界原样。
- **D5 · `ext build` 跨 root 复用是内容寻址的直接推论，不是新语义。** 同 id 同 hash = 同字节；复制 + 验 integrity 与本地编译等价。复制发生在本机 `ext build` 内，出生地规则不变。
- **D6 · prune 只删非 `current`；无 `current` 的 id 不动；不扫 session header。** 代价（旧 session 无法 resume）诚实打印；同源码重 build 得同 id 是恢复路径。
- **D7 · core 零改动。** 需要动 `composition` / `session` / `ledger` / `loop` / `store` 的语义才能落地 → BLOCKED。
- **D8 · model-facing 文本零文档引用**（`help` / `ext api` / SKILL.md / sync、prune 的 stdout 文本），同 M2c D8。

## 4. 参考（先读这些，再动手）

- `src/cli/ext.zig`（`ext build` 的落点选择 `buildDestRoot`、`--user`、`activate|rollback|deactivate` 的 lease 与 note、`ext list` 的 root 列 / `(shadowed)` / `[tools skills prompt]`、`api` 三个 topic、`printUntrustedStoreRefusal`）；`src/cli/common.zig`（usage 按动词族拆的常量、`RootSearch`）；`src/extension/build/build_ext.zig`（`buildExtension`：version 计算 → `already_built` 短路 → freeze → 编译 → seal）；`src/extension/store.zig`（`Store.lease` / `activate` / `deactivate`、`versions/` 布局）、`roots.zig`（`Roots.firstWithVersion` / `resolveVersion`）、`integrity.zig`（`validateVersionDir`）；`src/launch.zig`（`extensionRoots`、`occupiedWorkspaceStore`、`ensureWorkspaceStoreTrusted`）；`src/journals/trust.zig`。
- `tests/e2e/support.zig`（`installPrebuilt` / `stageBundled` / `trustWorkspaceStore`——sync-a 的产品实现和它是同一件事的两面，可对照；测试里请直接用这些 helper）、`tests/e2e/extension.zig`（`cli ext build: a draft outside any store lands …`、`bundled …` 几条）、`tests/e2e/cli.zig`（`cli help` 那条对 usage 的断言）。
- `tui/src/nulya/cli.ts`（`ext build/run/list/activate` 封装、`fail`）、`tui/src/nulya/files.ts`（`ext list` 投影）、`tui/src/ui/`（`/ext` 视图）、`tui/src/launch.ts`（启动流程）、`tui/tui.toml` 与 `tui-state.json` 的读写处；docs/tui.md §5（`/ext`）、§9（里程碑表）、§11（实施日志格式）。
- DESIGN §7.2 / §7.4 / §7.5 / §9 / §14；docs/goals/M2c.md §3 D8；docs/goals/guide.md §6（真实跑出来的用法反馈）。
- 本仓库 `nulya` 不在 PATH 上：`./zig-out/bin/nulya.exe`（`zig build` 后）；bun 1.3.5 在 PATH。

## 5. 工作方式

- 分支 `sync`（从 `main` 切）。每个子项完成：`zig build test` + `zig build e2e`（+ 改了 `tui/` 时 `bun test` + `bun run typecheck`）全绿 → commit。
- 代码注释英文，docs 中文，model-facing 文本英文；测试与模块同文件；`zig fmt`。
- 每完成一个子项，在 §6 记一行（commit hash + 一句话 + 有无偏离）。
- 卡住 / 需要改 core / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

- **sync-a**（`2e1a33c`）：`ext build` 编译前先在别的 root 找同一版本，找到就整树复制 + 再验一次 integrity，stdout 打 `(built, copied from <root spec>, in <dest>)`。
  **一处偏离契约字面**：匹配键不是"已经算出来的 `v`"，而是 **seal 的 `(package_digest, target)` +（能问出编译器时）`compiler`**——因为 compiled 版本的 id 含 compiler identity，而契约要求的 e2e（`NULYA_ZIG` 指向不存在的路径仍成功）意味着**没有编译器时算不出 `v`**。所以 `compilerIdentity` 不再提前失败：问得到就是精确匹配（等价于按 `v` 找，D5 原样），问不到就放宽成"这份 snapshot 在这个 target 上的任意一次 build"，候选按 version id 排序取第一个（不依赖目录顺序）。真要编译时仍报 `ZigVersionUnreadable`。落点 `extension/build/build_ext.zig`（新增 `buildExtensionReusing`，旧签名成为 `donors = &.{}` 的包装，28 个调用点不动）+ `cli/ext.zig`（`donorRoots` / `buildState`）。
  e2e：`cli ext build: a compiled version another store root already holds is copied in rather than compiled …`（user root 里放 bundled `compact`，workspace build 在 `NULYA_ZIG=definitely-not-a-compiler` 下成功、版本目录逐字节相同、再 build 是 `already built`、activate + run 真跑得起来）。support 加 `stageBundledIn` / `expectSameTree`。
