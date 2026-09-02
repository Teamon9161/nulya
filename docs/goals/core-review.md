# 内核评审与收缩计划（2026-09-02）

一轮通读 `src/`、`extensions/`、`tui/` 接触面与全部 docs 之后的评审，以及由它推出的**收缩**计划。
这份文档是执行契约：每一刀写清「删什么、留什么、验收是什么、哪些文档要同 commit 更新」，
分给独立的 lane 去做。落地后各节按惯例搬进 DESIGN.md，这里只留判断与决定。

## 0. 总体判断（一段）

赌注押对了，八条 physics 也真的守住了；问题不在骨架，在骨架周围长出来的东西。
ledger 只 append、header 冻 composition、一文件一 generation、唯一 builtin 是 shell、扩展走
stdin/stdout/退出码、gate 只答 allow/deny、PromptIR 类型里没有不投影的字段——这些不动。

复杂度的来源不是 physics 本身，而是三条 physics（#2 冻结、#3 只经 append、#5 内容寻址）在遇到
真实需求时，每次都用「加一个边缘机制」兑现，而不是回头问「这条 physics 是不是表述得太窄」。

| 指标 | 值 |
|---|---|
| `src/` 总行数 | 38,978 |
| 其中纯注释行 | 8,249（21%） |
| DESIGN.md（自称只写现状） | 260 KB |
| 回答「工具 X 下一场在不在模型面上」要理解的概念 | 约 11 个 |
| 锁与标记文件种类 | 9 种，分散在 4 个文件 |
| `session step` 每进程开销（ReleaseFast，std+agent 成员 / 裸场） | 0.16 s / 0.08 s——**可接受，不为此改设计** |

## 1. 评审：概念上不合理或过重的地方

1. **`model_rebind` 是为一个需求造的第六种事件，代价远超需求。** `scanSession` 双趟并发扫描与
   `pending_drained` 裁决、`reasoningFloor`、`effectiveIdentity`/`lastRebind`/`identityEqual`、
   `RebindResolver`、`applyRebind` 两处调用、`append --image` 与 `rebind` 在投递锁上串行。
   根因：physics #2 把「换 composition = 换 session」和「换 session = 丢历史」绑在一起，后者不是
   physics，只是 fork 的实现选择。下一个同类需求「中途加个工具」今天无解。
2. **事件字母表太窄，机器事实穿 `user_text` 的衣服。** `capability_note` 与 `task_finished` 同一
   genre；TUI 已有四种 sentinel 塞在 `user_text`，其中 `<ext-note pkg=…>` 是插件产出；watcher 协议
   还要再加。kernel prompt 那句「只有 user turn 是人写的」已经不真。
3. **store roots 与 trust gate 整套机制源于一个可疑前提：编译产物放进 checkout。** 因此才有首个
   active root 胜、`(shadowed)`、donor 跨 root 复制、trust journal、birth trust、`ext trust`、每步过门。
   人会提交的是 draft 源码，不是 `versions/`。
4. **composition 词汇表巴洛克化。** 两根轴 × 三个来源 + surface 三词 + `recommended` + pin 蕴含成员
   + `apply` + `--bare`。`apply:"auto"` 为了避免读一次未验证 manifest，在 `current` 多写一列、
   `ActiveEntry` 多一字段、composition 多一整条 `resolveApplyAutoExtensions` 路径。
5. **`wsl` exec target 是半个 remote**，与已退役的 `ssh:` 同一种裂脑；`--env` 一个 flag 两族语义。
6. **锁的动物园**没有集中声明；`session prune` 的 lifetime 冻结横跨 ledger / cli/task / remote。
7. **内核往 stderr 打字**（`reportBrokenActive` 等三处 + `if (builtin.is_test) return`）。
8. **credentials.toml 与 user config 的 `api_key` 是同一件事的两个文件**：子进程读得到 config.toml。
9. **tool-usage journal 记的大多是 ledger 里已有的事实**，内核零读者，是「两份真相」。
10. **注释与文档违反自己定的纪律**：大量「为什么没写成另一种样子」的论证；DESIGN.md 是辩论记录。
    读者是模型经 `nulya src`，这是直接 token 成本。
11. 小项：九档 scripted provider 混在 launch.zig；`session step` 两种输出协议；`session append`
    无回执；`events --follow` 永不退出的轮询骨架；`cli/task.zig` 约 600 行远端轮询从 Environment
    那道缝漏进 task 面。

## 2. 决定：刀口与顺序

四把大刀 + 中刀 + 小刀。**顺序：C → D 可并行；A、B 在 C 合入之后并行；中小刀最后。**
每一刀是一个 lane，一个 commit 系列，DESIGN.md / CLAUDE.md / `extensions/guide` 的 SKILL.md /
`ext api` 文本在**同一 commit** 同步；PLAN.md 里对应「不做」的段落删掉或改写。

### Lane C · 只留成员一根轴（做第一个）

**目标**：一场 session 的 composition = 一组成员，每个成员可带一个工具选择。删掉 pin 家族。

- 语法：`session new --with <id>[@<version>][:<tool>,<tool>…]`；config `[extensions] with = ["std:read,grep", "ask"]`。
  `:` 后是要上模型面的 `surface:"manual"` 工具名；不写 `:` = 只带该包的 `auto` 工具；
  `:none`（或空选择的约定形式，实现挑一种）= 成员但不上任何工具。
- **删除**：`registry.pinned_native_tools`、`session new --pin`、`composition.Options.pinned_native_tools`、
  `pinImpliedRefs`、`resolvePinnedBinding` 的 fresh 分支、`PinNamesUnknownExtension` /
  `PinToolNotDeclared` / `PinToolNotPinnable` / `InvalidStableToolId`（选择解析失败归成一个
  `WithToolNotDeclared` 之类的错误）、manifest 的 `recommended`、manifest 顶层 `apply`、
  `Store.Active.standing`、`current` 文件的 `apply=` 列、`Roots.ActiveEntry.standing`、
  `resolveApplyAutoExtensions` / `reportBrokenApplyAuto` / `StandingRecordMismatch`、`Options.apply_auto`。
- **保留**：manifest `surface`（`auto` / `manual` / `internal`）作为包的缺省；`--bare`（= 不读 config
  `with`）；`max_tools`；header 的 `native_tools`（frozen 路径不变，仍只重放这张表）；稳定 id
  `ext:<id>/<tool>` 作为 journal / gate 的身份。
- 自带包：`guide` / `coding` 去掉 `apply`；`ext activate` 的那句「进每一场」提示改为提示
  `[extensions] with`；`ext seed` / `sync --activate` 输出相应调整。`std` 六个 tool 仍是 `manual`。
- TUI：`tui/src/pins.ts`、`with.ts`、`extensions.ts` 与 `tui-state.json` 的 `session_pins` 改成成员+选择
  的形状（`/ext` 的 Enter 开关语义保持：ON = activate + 写进 with 列表并选上全部 manual 工具）。
- 验收：`zig build test`、`zig build e2e` 全绿；`tui/` 下 `bun test` 全绿；e2e 里 pin 相关用例改写成
  `--with std:read` 形式并保留「光有 usage 的下一场仍只有 shell」那条；`nulya help` 仍一屏。

### Lane D · 通用 `note` 事件（与 C 并行）

**目标**：一种事件承载全部「进程外到达的机器事实」，ledger 不再说谎。

- 新事件 `note { source: []const u8, text: []const u8, meta: []const u8 }`：`source` 是开放词表的短标签
  （`task` / `ext` / `driver` / `watcher` …，内核不解释），`meta` 是一个 JSON 值的原文
  （`task_finished` 的 `{task, exit_code}`、`capability_note` 的 `{id, version}` 搬进去），`text` 是模型读到的全部。
- **投影**：与今天 `task_finished` / `capability_note` 相同——一条 user-role turn，只投 `text`。三个
  provider 的序列化路径合并成一条。
- **去重**：`capability_note` 按 (id, version) 的内容去重改为**只靠投递名**（note 的投递者取确定名
  `note-<id>-<version>`，`origin` 去重已经覆盖）；`containsNote` 删除。
- **兼容**：读老 ledger 时把 `task_finished` / `capability_note` 行读成 `note`（`toEvent` 里翻译，
  写端不再产生旧 kind）；header `v` 不变。`session events` / `--stream` 打印新形状。
- **删除**：`Event.task_finished`、`Event.capability_note`、对应的 encode/clone/expectEqual 分支、
  `prompt.Turn.task_finished` / `.capability_note`（合成 `Turn.note`）。
- **写者改造**：`cli/task.zig` 的 `depositReport`、`cli/ext.zig` 的 capability note 投递。
- kernel system prompt 那句改成「只有 user turn 是人写的；note 与 tool result 来自命令、文件与本 harness」。
- TUI：`tui/src/nulya/ledger.ts` 识别 `note` 并按 `source` 画卡（task 卡、capability banner 照旧）；
  `extnote.ts` 的 `<ext-note pkg>` sentinel 改为投递 `note{source:"ext"}`（经 `session append` 需要
  一个入口：加 `session note <id> --source <s> [--meta <json>] <text|--file>`，或在 `append` 上加
  `--as-note --source`；实现挑一种并写进 `nulya help`）。其余三种 sentinel 是人的输入，保持 `user_text`。
- 验收：`zig build test` / `e2e` 全绿；老 session 文件（含 `task_finished` 与 `capability_note` 行）
  resume 后投影逐块相等；scripted `background` 模式仍能看见报告；`bun test` 全绿。

### Lane A · `--carry` fork 取代 `model_rebind`（C 合入后）

**目标**：换模型、换工具、换 system prompt 都是同一个原语：带历史的 fork。

- `session new --parent <id>:<seq> --carry`：把父 ledger 事件 1..seq **复制**进新文件（新 seq 从 1 起，
  `origin` 列不复制），每条 assistant 的 `reasoning` 置空，header 记新的 `model_identity` /
  composition / prompts；`parent` 列照记。父文件一个字节不变。
- 不带 `--carry` 的 `--parent` 行为不变（compact 用）。`--carry` 时不带 `--profile/--model` 则继承父身份，
  `--with` 等 composition 照常现解（这正是「中途加工具」的路）。
- vision 门在 fork 时查一次：父 ledger 有图片而新模型没主张 `vision = true` → 拒绝、什么都不建。
- **删除**：`Event.model_rebind`、`ledger.SessionScan` / `scanSession` / `scanInbox` / `scanLedger`、
  `effectiveIdentity` / `lastRebind` / `reasoningFloor` / `identityEqual` / `Identity`、
  `AgentSession.rebind` / `ModelResolver` / `applyRebind` / `built`、`cli/session.zig` 的
  `sessionRebind` 与 `RebindResolver`、`session rebind` 动词、`append --image` 与 rebind 在投递锁上
  串行的那段理由（投递锁本身保留：`task run` 与 prune 仍靠它）。prompt.zig 的 reasoning floor 删除。
- **兼容**：读老 ledger 遇到 `model_rebind` 行 → `CorruptLedger` 之外要有出路：翻译成「从这里起
  reasoning 不回放」太复杂，直接拒绝并指路 `session new --parent <id>:<seq> --carry --profile …`。
- `session new` 的父身份继承改读父 header（不再需要 pending inbox 的判断）。
- TUI：`/model` 在已开场的 tab 上改为「carry fork 到新 tab」（compact 的同一条 UI 路径）。
- 验收：test / e2e / bun test 全绿；e2e：父 20 步后 `--carry` 到另一个 scripted profile，子场 PromptIR
  turns 与父 1..seq 逐块相等且 reasoning 为空；`/model` 中途换模型的 e2e 改写。
- docs：`docs/goals/model-rebind.md` 顶部加一段「已被 carry fork 取代」，不删。

### Lane B · 字节全局、指针分层的 store（C 合入后，与 A 并行）

**目标**：所有版本目录只在一处 `<NULYA_HOME | ~/.nulya>/store/<id>/versions/<v>/`；workspace 只留
draft 与 `current` 指针。删掉 roots 搜索与 trust gate。

- 布局：`~/.nulya/store/<id>/{versions/, current, .lock}`（user 层指针）；workspace
  `.nulya/extensions/<id>/{extension.json, src/…, current}`（draft + workspace 层指针，无 versions）。
  `extensions.paths` 删除（一个 store 没有第三档）。
- 指针分层：workspace `current` 优先于 user `current`；两层都没有 = 没激活。`ext activate [--user]`
  只决定写哪一层的指针；`ext build` 总是写全局 store 并打印版本；`ext deactivate` 删本层指针。
- **删除**：`extension/roots.zig` 的多 root 搜索（退化成「一个 store + 两层指针」的小模块或并入
  store.zig）、`(shadowed)`、donor 复制（`buildExtensionReusing` 的 donors）、`firstWithVersion`、
  `resolveForTarget` 跨 root 循环、`journals/trust.zig`、`launch.ensureWorkspaceStoreTrusted` /
  `occupiedWorkspaceStore` / `storeHoldsExtensions`、`cli/ext.zig` 的 `recordBirthTrust` /
  `ext trust` / `printUntrustedStoreRefusal`、`remote serve` 里的 trust 判据、`ext prune --user`
  的 `--user` 区分（prune 只有一个 store）。
- `ext push` 推到那台机器的唯一 store；`exec_version` 反查只查一个 store。
- 兼容：一次性迁移动词 `ext migrate`（把老 `.nulya/extensions/<id>/versions/*` 与
  `~/.nulya/extensions/*` 搬进新布局并改写指针），或在 `ext sync` 里顺手做；老 header 的
  `active[]` 是 (id, version)，不记 root，所以 resume 不受影响。
- TUI：`/ext` 的 root 列改为「指针在哪一层」；`ext trust` 的入口删除。
- 验收：test / e2e-ext / e2e-core / e2e-remote 全绿（trust 相关用例删除，遮蔽用例改写成两层指针
  的优先级用例）；bun test 全绿。

### 中刀（A/B 之后，可分给 sonnet）

- **E** 退役 `wsl` exec target：删 `ExecTarget` / `wslPath` / `wslScript` / `shellArgv` 的 wsl 分支 /
  supervisor `--env` / `exec_target_syntax`；`--env` 只认 `remote:*`；老 header 里的 `wsl` 像 `ssh:`
  一样响亮拒绝并指路 `remote:wsl`。
- **F** `src/lease.zig`：所有租约与标记（writer / deposit / deposit pair / session leases / task /
  store / journal）的取锁函数与**一张顺序表**集中在这一个模块；`environment/remote` 与
  `extensions/agent` 的锁在表里登记（不搬代码）。内核的三处 stderr 改成 `Diag` sink 参数
  （`composition.zig` / `roots` / `extension/exec.zig`），`if (builtin.is_test) return` 全部删除。
- **G** 删 `credentials.toml`（`launch.fileValue` 一族）；tool-usage journal 收窄到 ledger 说不了的
  两列（`duration_ms`、`ext run` 场外调用），`session list --json` 从 ledger 派生每场的工具计数。
- **I** 把 `cli/task.zig` 的远端轮询（`Far`、`pollAndDeliver`、`sweepRemoteReports`、`heldTaskFor`
  的远端分支）隔离到 `cli/task_remote.zig`。

### 小刀（最后，sonnet）

- scripted provider 搬到 `providers/scripted.zig`；`session step` 只留 `--stream` 协议（无 flag 时
  也按行协议输出，`--stream` 作为无操作别名保留一个版本期）；`session append` 打印投递名；
  `events --follow` 要么做成真 tail 要么删 flag。
- 注释瘦身：按 `docs/goals/comments.md` 的契约扫一遍 `src/`——删「为什么没写成另一种样子」、删
  文档指针、模块头 ≤ 15 行；目标是纯注释行降到 12% 以下。
- DESIGN.md 同步各 lane 之后再做一次「留事实与不变量，删论证」。

## 3. 不动的（中道那一侧）

ledger append-only 与 header 冻结；一文件一 generation 与 `--parent`；shell 唯一 builtin 与那一种
wire；PromptIR 的类型纪律；gate / observer 的形状；batch 不变量；inbox 用目录而非文件
（`moveDeposit` 一个 rename 就是证据）；一次 step 一个进程、不做 daemon；remote 藏在 Environment
vtable 后面这道缝。

## 4. 落地记录

（各 lane 合入时在此追加一行：日期、commit、偏离契约之处与理由。）

- **2026-09-02 · Lane D**（`4572c3f` 内核与文档 · `d37757e` 两条翻译挪到一处 · `8a5d892` TUI · `5b6e6fa` e2e 断言）：`capability_note` / `task_finished` 合成 `note{source, text, meta?}`，投影一条 user-role turn，三个 provider 一条路径（`openai` 上能力宣告随之从 `system` 改到 `user`）；`containsNote` 与内容去重删除，只靠投递名；老 kind 在 `toEvent` 里翻译，header `v` 不变。driver 入口选了**新动词** `session note`（而不是 `append --as-note`）：`append` 说的是"人说了什么"，一个把它变成非 user turn 的 flag 恰好抹掉这一刀要立的区别。三处偏离：① `nulya help` 从 66 行长到 68 行（e2e 预算同步）——一个说不出来的能力占两行，按 e2e 那条注释自己的规矩；② 插件的 `<ext-note>` 按契约投成 `source:"ext"`，与能力宣告同一个 source，所以前端靠 `meta`（`pkg` vs `id`）分诊；③ `docs/goals/{background,tui-plugin}.md` 里逐字引用旧 kind 的段落没动（它们是当时的契约与实施记录，与 `model-rebind.md` 同一类归档）。验收：`zig build test` 600/600 · `zig build e2e` 173 pass 3 skip · `tui/` 下 `bun test` 774 pass，剩下的一条红是 `/ext` 的 `r` 提示行在**本机 worktree 的长路径**下换行（stash 到 `d37757e` 上同样红，与本刀无关）。

- **2026-09-02 · 中刀 I + 小刀第一条**（`dff5792` `cli/task.zig` 远端轮询隔离 · 本 commit scripted provider 搬迁）：两把纯代码搬移，都不改行为、不改 CLI、不改文档语义。I 把 `Far`/`FarAnswer`/`pollAndDeliver`/`sweepRemoteReports`（实现）与 `readRow` 的远端分支整体搬进新文件 `cli/task_remote.zig`；`cli/task.zig` 只留全部动词、`collectRows`、`heldTaskFor`、`readRow` 的本机路径。两个文件互相 `@import`（`task_remote` 反查 `task.Row`/`RowRef`/`collectRows`/`markerPresent`/`depositReport`/`json_opts`，相应改 `pub`），`sweepRemoteReports` 由 `task.zig` 重导出，`cli/session.zig`、`cli/remote.zig` 原有的 import 一处未改。小刀那条把 `launch.zig` 里的九档 `ScriptedProvider`（连同 `hasToolResult` 等五个辅助函数与两个测试）整体搬到 `providers/scripted.zig`；`launch.ScriptedProvider` 保留为一行重导出别名，`NULYA_SCRIPTED_MODE`、`support.launch.ScriptedProvider` 等全部调用点未改一字。验收：`zig build test` 599/599 · `zig build e2e` 172 pass 3 skip（含单独重跑的 `e2e-core` 60 pass 3 skip、`e2e-remote` 30 pass）。

- **2026-09-02 · Lane C**（`5d8ce04` 内核 + docs、`f242590` TUI + tui.md）：契约逐条落地。
  `:none` 采用契约给的那个拼法（空选择 `<id>:` 也读作 none）；选择**加在**包的 `auto` 缺省
  之上而不是替换它，并允许点名一个 `auto` tool（去重后是空操作）——这样 `WithToolNotDeclared`
  只有「没声明」与「是 internal」两种含义，模型少一条要记的规则。
  三处契约没点名、但删掉 `--pin` 逼出来的连带改动：① `extensions/agent` 的 persona front matter
  `pins:` 改名 `with:`（条目从 `ext:<id>/<tool>` 变成成员 spec），否则委派出的子场会静默丢工具面；
  内联列表的逗号切分因此改成引号感知，好让 `with: ["std:read,grep"]` 写得下一个选择。
  ② `tui.toml` 的 `env.<kind>.pins` 删除——成员 spec 自己带得动选择。
  ③ TUI 的 `ext list` `standing` 判据改成「某张常驻成员表点了名」。
  遗留：`tui/` 的 `bun test` 有一条红的（`/ext` 的 `r` 帮助行断言），是 worktree 路径过长把那行
  折成两行所致，`git stash` 后同样红。

- **2026-09-02 · Lane A**（`a719a6d` 内核 + docs · `925af3f` TUI + tui.md）：`model_rebind`
  整族退场，换模型 / 换工具 / 换 system prompt 收成一个原语
  `session new --parent <id>:<seq> --carry`（复制经 `parseEventLine`→`toEvent`→`append`
  同一套 codec，`origin` 不带、`reasoning` 置空，父文件一字节不动）。
  契约点名要删的每一样都删了；`session step` 的 effort 缺省与 `--image` 的 vision 门
  改读 header，`session list` 不再有 rebind 分支。投递锁按契约保留。
  四处偏离或契约没点名的连带决定：
  ① 兼容用的错误叫 `LegacyModelRebind`，它由 **`toEvent`** 抛出而不是 `openDurable`——
  于是 `openDurable`、`readCarry`、`drainInbox`（inbox 里躺着一条老 rebind 投递的情形）
  三个读点白拿地共用同一句判断，`session step` 在 open 与 run 两处各翻一次同一句指路。
  ② vision 门抽成一个判据 `visionClaimed(cfg, model_id, what)` 两个入口，
  但**保留了两种拒绝措辞**（"有条目却没主张" vs "没有条目"）——e2e 靠这个区别钉的是
  "没有条目 = 不主张" 这条规则本身，合并成一句会让它测不出来。
  ③ TUI 的 `/model` 用 `tabs.carryFork` + `replace`（`/sessions <id>` 的那条 tab-switch 路），
  **不是**新开一个 tab：一场对话仍然在一个 tab 里，而 `replace` 顺带把"这个进程刚建、
  还一句话都没说过"的空父场 prune 掉（既有语义，carry 0 条历史的 fork 正好落在这一档）。
  ④ e2e 的"reasoning 置空"那条要一个带 reasoning 的父场，而 scripted provider 不产出
  reasoning，所以测试往父文件**追加一行**合法的 assistant 事件当 fixture
  （文件格式就是契约），再断言子场逐块相等且不含 `reasoning` / `origin`。
  验收：`zig build test` 593/593 · `zig build e2e` 172 pass 3 skip ·
  `tui/` 下 `bun test` 769 pass 1 fail，那一条仍是 `/ext` 的 `r` 帮助行在本机 worktree
  长路径下折行（与 Lane C/D 记的是同一条）。`nulya help` 净减一行。

- **2026-09-02 · 中刀 G**（`1c8aec3` 删 credentials.toml · `b3ca604` tool-usage journal 收窄）：两把独立的删法，各一个 commit。① 删 `launch.fileValue`/`fileValueAt`/`credentialFilePath`/`credentials_file`/`warned_credentials_mode` 与 `CredentialSource.file`，`credentialSource` 收成 config → env → (codex) login 两处；`session new` 的缺凭证提示、`config show` 的 `credential_source`（靠 `@tagName` 自动收窄，没有硬编码词表要改）、TUI 的联合类型、DESIGN §9.5 同步；e2e 的凭证测试从"写 credentials.toml"改成"设 env"，launch.zig 删文件路径单测、留一条更小的 config-beats-env 优先级单测。② tool-usage journal 该收到多窄，契约给了两个方案，选了较小的那个：`session.recordCompletedToolStats` 与它写的 `ok` 列原样保留——TUI `/ext` 的 usage 表要跨全部 session 聚合成功率，那是单个 ledger 文件答不出的问题，把它搬到 ledger 需要重写那张表的数据源；改成给 `session list --json` 加一列 `tools{calls, failures}`，直接数当前 session 文件里的 `tool_results[].ok`，不碰 journal。journal 现在的立足点缩到两件 ledger 说不出的事（`duration_ms`、`ext run` 场外调用的身份），单场调了几次、几次失败已经有 ledger 原生的答案；不升 `v`。DESIGN §3.3/§5.5/§14、CLAUDE.md「三条 journal」一句、docs/tui.md §2.1 同步；PLAN §3.5 未提及这两列的删减，未改。
  验收：`zig build test` 593/593 · `zig build e2e` 172 pass 3 skip · `tui/` 下 `bun test` 769 pass 1 fail，同一条 `/ext` 的 `r` 帮助行长路径折行（与前几条 lane 记的是同一条，本刀之前就红）。

- **2026-09-02 · 中刀 E**（`0fa2835` 内核 + docs · `56fb0e4` TUI + tui.md）：契约逐条落地。
  `ExecTarget` / `parseExecTarget` / `execTargetSupportedOnHost` / `exec_target_syntax` /
  `wslPath` / `wslScript` / `appendSingleQuoted` 与 `LocalEnvironment` 的 `exec_spec` /
  `target`（连同 `shellArgv` 的 wsl 分支与不再需要的 `cwd` 参数、argv buf 从 `[8]` 收到
  `[5]`）一并删除；`LocalOptions.exec`、`task supervise --env`、`SupervisorSpawn.exec_spec`
  同理。`launch.execTargetRefusal` 收窄成三档：`remote:*` 的解析/可达判定、两个退役拼法
  （`legacySshHint` 与新 `legacyWslHint`，合成 `legacyExecHint`）、其余一律 unrecognized；
  `sessionEnvironment` 把"非空且非 `remote:`"直接判 `error.InvalidExecTarget`，老 header
  里的 `wsl` / `wsl:<distro>` resume 时在 `session step` 与 `task run` 两处都响亮拒绝并
  指路 `remote:wsl`。`remote:wsl` 一族（`environment/remote/mod.zig` 里 WSL 自己那份实现）
  一字未动。TUI：`state/envprofile.ts` 的 `ExecTargetKind` 从三档收成 `local | remote`，
  `[env.wsl]` 变成未识别键（同 `[env.ssh]` 的待遇）；`state/targets.ts` 的 picker 不再产
  裸 `wsl:<name>` 行；`state/tui_state.ts` 读老状态文件里的 `wsl`/`wsl:<distro>` 同 `ssh:`
  一样丢回本机，不重写升级。
  两处偏离：① `src/cli/ext_push.zig` 里"`--env wsl`"的过时措辞留着没改——那个文件属于
  Lane B 并行占用的 `src/cli/ext*.zig`，契约点名不碰；② `docs/PLAN.md` §3.8 的
  "exec target 的三件已知欠账"整段改写而非删除，换成一句"只搬 shell、其余留在 host 今天
  没有答案"——三件旧欠账里两件（config 缺省的比较对象、kill 保证）随 wsl 退役本身消失，
  第三件（`NULYA_EXE` 到不了对面）本来就是 wsl 独有的失效点，不值得留一具体面目的空壳。
  验收：`zig build test` 592/592 · `zig build e2e` 174 pass 1 skip · `tui/` 下 `bun test`
  769 pass 1 fail，那一条仍是 `/ext` 的 `r` 帮助行在本机 worktree 长路径下折行（与
  Lane A/C/D 记的是同一条，与本刀无关）。

- **2026-09-02 · Lane B**（`b4efc52` 内核 + docs · 本 commit TUI）：built 版本的字节只住 `<NULYA_HOME | ~/.nulya>/store/<id>/versions/<v>/`，workspace 只剩 draft 与可选的 `current` 指针；`extension/site.zig` 的 `Site` 取代 roots 搜索（一个 store + 两层指针，workspace 压 user）。删掉：`roots.zig` 的多 root 搜索与 `(shadowed)`、donor 跨 root 复制、`journals/trust.zig` 与 `ext trust` / birth trust / 每步过门、`[extensions] paths`、`ext prune --user`、`ext build --user`（只有一个落点）。新增一次性搬家动词 `ext migrate [--dry-run]`。`extension_roots` plumbing 收成一个 `extension_store` 路径。TUI：`/ext` 的 root 列改成 `workspace` / `user` 指针层，`ext trust` 入口删除。验收：`zig build test` 591/591 · 五组 e2e 全绿 · `tui/` 下 `bun test` 769 pass，剩一条是各 lane 都记过的长路径换行断言。

