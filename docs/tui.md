# Nulya TUI — 设计与计划

> **状态：T0–T115 全部落地**（T10 `/goal` 仍是占位）。前端在仓库顶层 `tui/`（见 [`../tui/README.md`](../tui/README.md)）；本文是它的设计契约（§1–§10）+ 实施日志（§11，T0–T114 已归档到 [`history/tui-implementation-log.md`](history/tui-implementation-log.md)）。`tui/` 不在内核范围里（另一条工具链、另一个进程），所以它的现状写在本文，不进 DESIGN.md。
> **内核为它长的东西**（都在 [DESIGN.md](DESIGN.md) 里）：`session step` 的行协议（纯观测，`--stream` 现在是无操作别名）· `session step --gate`（每个 tool call 执行前的一票否决，§4/§14）· `session new --parent` 的 fork 语义（§11/§14）· `NULYA_EXE`（子进程 env 里的本二进制路径，§7.6）。其余每一样（`--prompt` / `--with` / `--carry` / `--bare` / `--env` / `--workspace` / `task *` / `remote *`）都是内核为**每个** driver 长的动词，前端只是第一个 consumer。
> 上位原则见 [PLAN.md](PLAN.md) §3.11：前端是 core 之上的薄客户端——**tail ledger 文件 + append user 事件；前端是长期进程，re-spawn 的只是 worker**。

## 0. 定位（三句话）

1. **TUI 是一个 driver 客户端，不是第二个 harness。** 它只做三件事：渲染 ledger、收用户输入、spawn `nulya session *`。任何"该不该继续 / 何时结束 / 要不要审阅"都是 driver 脚本或 agent 的事（PLAN §3.6），TUI 里一行都不写。
2. **TUI 只显示 ledger 里有的东西 + 本次 step 的瞬态流。** 想被看到的状态必须 append 进 ledger（这正是 PLAN §3.6 第 3 条）；TUI 不发明第二份真相。
3. **接触面 = `nulya session *` CLI + `.nulya/` 目录布局（DESIGN §3.4 / §5.5 / §7.2）。** TUI 里只有 `src/nulya/` 一个目录知道这些形状。

目标场景：**用 nulya 改 nulya**。所以第一版的成败标准不是功能全，而是：能连续几个小时在里面工作、看得清 agent 在干什么、能取消、能 resume、演化动作（造工具 / 换版本 / 获得能力）在对话里一眼可辨。

## 1. 决策

### 1.1 已定（前面讨论过）

| 决策 | 选择 | 理由 |
|---|---|---|
| 技术栈 | Bun + TypeScript + OpenTUI（`@opentui/core` + `@opentui/solid`） | markdown / diff / code / scrollbox / textarea / keymap / test renderer 现成；native core 本身是 Zig；opencode 同款路径最经实战 |
| 位置 | 仓库顶层 `tui/`，独立 `package.json`，不进 Zig build graph、不进 zon `.paths` | 另一个工具链、另一个进程；kernel 留在 `src/`（`nulya src` 的范围） |
| 内核↔TUI 边界 | 进程边界（CLI + JSONL），不是库边界 | PLAN §3.11 有意为之；driver 面被第一个真实 consumer 使用 |
| 内核改动 | **仅** `session step --stream`（§2.2）；其余全部读文件 | deltas 根本不出内核，TUI 绕不过；其它信息 `.nulya/` 里都有 |

### 1.2 本文拍板（可推翻，附理由）

| # | 决策 | 选择 | 理由 / 备选 |
|---|---|---|---|
| D1 | 屏幕模式 | **alt-screen + `scrollbox` transcript**（`stickyScroll: bottom`） | 折叠开关、resume 回放、"diff 默认展开可配置"都要求历史可变；`split-footer` 提交进 scrollback 的内容不可再改。备选：设定 `screen = "footer"` 后期加 |
| D2 | 流式传输 | `step --stream` 写 **stdout**（TUI 拥有 step 子进程） | 最简、可调试。我们自己 spawn 的 driver 把这套行协议原样透传到 stderr，所以 sidecar 不需要；剩下的只有"不是我 spawn 的那个 driver"，那条路仍是 turn 级（§5.6、§10.3） |
| D3 | 绑定 | Solid | opencode 同款；fine-grained 更新适合流式。React 也行，API 同形 |
| D4 | 设定文件 | 独立 `tui.toml`，路径**镜像**内核 config 的目录（user 层 + `.nulya/tui.toml` 项目层），不放进内核 config | 内核不该认识 TUI 的键；同目录让"设定在哪"只有一个答案 |
| D5 | 默认折叠 | diff presentation **展开**；shell / 扩展工具输出 **折叠**；**thinking 默认 `hidden`**（T43，可设回 `collapsed`）；capability banner 展开；**一串跑完且成功的无身体调用折成一行 run 摘要**（T43，`run_summary`） | 你的要求 + 演化动作要显眼；reasoning 既不是模型说的也不是它做的，而「正在想」由输入框上面那一行说（T38） |
| D6 | 取消 | `Esc` = `session cancel`（step 边界消化，当前工具跑完）；`Ctrl+C` 两下 = kill step 进程树（下一次 open 由 kernel `completeInterruptedToolBatch` 修复） | 两种语义都真实存在，都给；不发明第三种 |
| D7 | sub-agent 谱系来源 | v1 从 transcript 推导（`nulya session new` 的输出 id、`session step <id>` 命令）；**不**改 header | `parent` 语义是 fork/compaction 的续接点，不是 spawned-by；等 subagent skill 真写出来再决定要不要 `spawned_by` header 字段（§10） |
| D8 | 权限 / 审批 | **两档 mode + 三张规则表**（T24 推翻"v1 没有"）：内核给一个 gate 原语（`session step --gate`，DESIGN §4），前端答；deny 就是那个 call 的 tool_result，模型读得到 | 原来的理由是"kernel 没有可消费的东西，TUI 不发明审批"——对的一半：发明一个内核不知道的审批，模型永远不会知道自己被拒了。所以补的是**内核那一半**（一个语义：allow / deny+note），判断留在前端（§5.7） |
| D9 | 内容宽度 | transcript 内容宽度上限 `max_width = 100` 列，左对齐 | 250 列的 markdown 不可读；设定可改 |
| D11 | **session 懒创建：第一条消息才 `session new`** | 开屏是一个 **draft tab**（无 id、磁盘上什么都没有），它只捏着 `session new` 要的东西（pick / `--with`）；成员表在 materialize 那一刻现读 `tui-state.json`。`--session <id>` 仍是真 tab；`/compact` 仍产真 tab | composition 在 `session new` 冻结（physics #2）——开屏就建，等于替人把 tools / 成员 / model 决定了，随后在 `/ext` `/model` 里做的一切要么落到**下一场**、要么靠"偷偷替换空 session"糊过去。懒创建让"改完再开"变成默认，`discardIfUntouched` 从常规路径退回成边角（T22） |
| D12 | **`/ext` 的 Enter 是一个开关：activate + 选上它的 tool 一起动** | ON = `ext activate` +（声明了 `manual` tool 的话）把它们全进本 TUI 的成员表；OFF = 先撤选择（含 user config 的 `always`）再 `ext deactivate`。单个 tool 仍在 tools pane 用 `Space`，单个版本仍在版本线用 `a`/`r` | **推翻 T12 §5 的"永不合成一个总开关"**。那条原则对内核是对的、对屏幕是错的：两个键（`Space` 批量选择 / `d` deactivate）都藏在 `?` 后面，而它们移动的状态**一格都没画**——截图里 `evolution` `guide` 是 `built` 但 `current (none)`，人按 Enter 没反应、也看不出差别。一个画出来的开关 + 底下写清两根轴，胜过两个没人找得到的键（T22） |
| D10 | **给人用的：一切在屏幕上完成** | 启动 `nulya` 之后，选模型 / 换 effort / 看哪个 profile 缺 key / **贴 key** 都是屏幕上的交互（`/model` 选择器、`/effort`、选择器里的 `s`），**不能要求人去找 config 文件改**。TUI 记住上次的选择（`tui-state.json`，见 §7）；隐式的选择跑不了（缺 key）时开屏就是选择器 + 原因 + 怎么修。config 文件是**定义**（一个 model id 是什么、profile 怎么连）不是**日常操作面** | 这是 TUI 的关键设计理念，与 D4 分工：`tui-state.json` 只有程序写；`tui.toml` 与内核 `config.toml` 是**人写的文件**，TUI 只对它们做**最小编辑**——在末尾追加/就地替换一个带标记的 `[[provider.profiles]] name/api_key` 小块（`nulya/credentials.ts`），以及 `/settings` 里就地换掉一个键所在的那一行（`state/settingsfile.ts`，T100）；两处都不重写、不重排、不碰人的注释与顺序，所以文件仍是同一份文档、作者仍只有人一个。「不能要求人去找 config 文件改」正是这条规则要禁的事，一个只读的设定面板违反的就是它。内核不学"上次选了谁"（那不是 substrate）；kernel 只提供 `nulya config show --json` 一个投影（含 `paths`），TUI 不复刻配置合并链、不猜 home 在哪 |

### 1.3 边界尺子：什么住 TUI 本体，什么住 extension 的 tui plugin

「composer 能贴图、能 `@` 文件，这些是不是该做成扩展」这个问题反复出现，答案定成一把尺子而不是逐案讨论：

**问：删掉这个功能，TUI 还能不能把任何一场 session 用起来？**

- **不能 → 本体。** 输入侧（composer、剪贴板粘贴与折叠、`@` 路径补全、键盘、IME）、ledger 渲染、tab / observer、审批对话框、`/model` `/env` 这些选择器，都发生在**任何 session 存在之前或之外**，产物只是「一条 user turn 的文本 + 图片」或「一个 `session new` 参数」。它们没有可以宿主到包里的语义：plugin 契约（`plugin-api.d.ts`）**有意**没有 composer 钩子——把输入交给包，等于让装了某个包的人打字行为都变化，那是 physics #6 在前端的对应物。贴图尤其如此：图片是 model-visible 的 turn 内容，格式由内核定（DESIGN §3.1），composer 只是在替人**拼一条 turn**。
- **能，而它只对装了某个包的人有意义 → 包的 plugin。** 与某个包的语义绑定的命令 / 卡片 / 面板（plan 的评审面板、ask 的选项、agent 的委派卡）已经全是包声明的（T39–T41）；没装 plan，连 `/plan` 这个词都不存在——这条已经兑现，继续兑现。
- **管理面已经存在，不新发明**：包的前端面走 manifest 的 `contributes.ui{"tui"}` / `commands` / `tools[].ui`，随版本冻结、`plugins=false` 一键退回声明层。「TUI 拓展如何提供」的答案就是这条路，不再开第二条。

推论：往本体加东西前先过这把尺子；过不了的，去问「哪个包该声明它」。尺子过了也还有 §1.2 的各条决策要对齐（一切在屏幕上完成、不发明第二份真相）。

## 2. 与内核的接触面

### 2.1 现有（只读用法）

| 面 | TUI 用法 |
|---|---|
| `nulya session new [--profile p] [--model id] [--with <id>[@<v>][:<tool>,…]] [--prompt f] [--bare] [--env spec] [--workspace dir]` | **一场 session 唯一的出生点，只在 draft tab 收到第一条消息时跑**（`tabs.materialize`，D11）；`/new` 的 Enter 只改 draft，不 spawn。这一行 argv 是 draft 上每个选择的落点：成员与它们的工具选择（§5.3）· `session_prompts` 渲染出来的开场文本（§5.11、T66）· exec target 与远端工作区（§5.11）。stdout = id |
| `nulya session new --parent <id>:<seq> --carry …` | 已经开始的 session 上的 `/model`：把这场对话带进一个新 session（`tabs.carryFork`），composition 现解、tab 换过去（`replace`，与 `/sessions <id>` 同一条路）。父文件一个字节不变。内核的门（凭据 · 带过去的 turn 里有图时新模型要主张 vision · 切点超过 tail）前端原样显示 |
| `nulya session step <id> --effort e` | 每个 step 按本 tab 的 effort 传（`/model` 选的、`/effort` 改的）；不传 = kernel 默认 |
| `nulya config show --json` | `/model` 的行、启动时判断隐式选择能不能跑（`launch.planLaunch`）、draft 的 model id（profile 只给了名字时取它的默认 model）与 `registry`（`max_tools`）、`extensions.with`（合并后的成员表，draft 的工具面 = 它选中的 tool ∪ `tui-state.json` 的 `session_with` 选中的）；只报 env var 名与 credential 布尔 |
| `nulya session append <id> --file f` | 发送：写 `.nulya/scratch/tui-<nonce>.txt` 再 `--file`（多行 / Windows 引号安全）；投进 inbox，**下一 step 边界才进 ledger**（PLAN §4 边角）→ TUI 乐观回显、标 `queued`，见到对应 `user_text` 事件后转正——那条事件行现在在 `model started` **之前**就到（DESIGN §14，T27），所以 `queued` 只在真正还排着队的时候挂着，而不是整整一个 step。stdout 现在多印一行投递名回执（DESIGN §14）；`session.ts` 的转正还是按文本拼接匹配 `queued` 项，没有改接这个回执 |
| `nulya session step <id> --stream --gate` | 每次发送后 spawn 一个；stdout 见 §2.2。**`--gate` 常开**：每个 tool call 执行前内核打一行请求、等 stdin 一行 `allow` / `deny [note]`，答案由 §5.7 的 mode + 规则给（T24） |
| `nulya session events <id> [--since N]` | 打开 / resume 时一次性回放；**不**用 `--follow`（driver 模式下 step 的 stdout 已是全量实时源） |
| `nulya session cancel <id>` | `Esc` |
| `nulya session list [--json]` | `/sessions` 的全部内容（created 倒序、composition / parent / 事件数 / usage / 最新 verdict）；**TUI 不再自己扫 header**（T8） |
| `nulya session outcome <id> <v> [--note]` | `/outcome`；写 outcome journal、不碰 session 文件也不取锁，所以正在跑的场次、别人在 drive 的场次都能当场评 |
| `nulya session new --with <id>[@<v>]` | `/with <id>[@<v>]`，以及每一条 `{with: true}` 的包命令（`/evolve` `/ask` `/plan`，T53）：把一个包带进这一场（membership，不是 store 指针——`current` 指哪个版本一点不变） |
| `nulya ext build <path>` | 开屏 sync、`/ext` 的 `b`、以及自带包成员解析（`sessionMemberOnce`）的第一步；version 内容寻址，所以每次都 build，未改动就是同一个 version |
| `nulya ext run <id>@<v> <tool> <json>` | 包命令的 `{run: "<tool>"}` 动作、`session_prompts` 的 `render`、以及插件的 `extRun` / `extRunPackage`。`/compact` 就是这一条：过程住在 `extensions/compact` 里（DESIGN §11），宿主只提供跨包调用与 `openTab`，父 tab 保留（§5.8） |
| `nulya ext push <id>@<v> --env <spec>` | `/ext` 的 `r`，只在这一场是 remote 时出现（§5.3）；成功与失败都是内核那句话原样显示 |
| `nulya remote check\|ls --env <spec>` | `/env` 选中一个 `remote:` 档之后：`check` 开一次真通道取 `home`，`ls` 是远端目录浏览器的每一层（§5.11）。check 失败就原样显示，浏览器不开 |
| `nulya ext list` | `/ext` 的目录清单：每个 id 生效的版本、以及**哪一层指针**说了算（`workspace` / `user`）——两层指针与"workspace 压 user"是 kernel policy，TUI 不复刻（T8） |
| `nulya task list --session <id> --json` | `/tasks` 与状态栏 `⠋ N background` 的**全部**内容（`state` / `exit_code` / `elapsed_s` / `duration_ms` / `command` / `log`）。`starting`（还没写 status）与 `lost`（说 running 但租约空闲）是内核算好的投影，TUI 一律不复刻——与 `/sessions` 改读 `session list --json` 同一条纪律（§5.9） |
| `nulya task kill <task>` | `/tasks` 的 `k`（`K` = 每一个还在跑的）；写 kill 标记，supervisor 杀整棵进程树 |
| `.nulya/sessions/<id>.inbox/` | 有没有 `.json` = 有没有等着下一个 step 边界排干的事件 → **driver 唤醒的唯一判据**（§5.9）；与 `.lock` 探针同一个 idle 定时器、同样无副作用 |
| `.nulya/scratch/<sid>/tasks/t<N>/output.log` | `/tasks` 的 `Enter`：读最后 64 KB（路径来自 `task list --json`，TUI 不自己拼 scratch 路径）；不是真·live tail，跟着面板的轮询重读 |
| 后台回执 / 报告文本 | `[background task <sid>/t<N> started] … log: …`（`shell {background:true}` 的结果）与任务报告 note 正文的两条分隔行 → 两张卡片按文本形状识别（`nulya/ledger.ts`，与 `[exit N]` 同一先例） |
| `.nulya/sessions/<id>.lock` | 能否非阻塞独占 → 有无别的写者（§5.6）；`session list` 给不了"此刻谁在写"，所以这条探针留在 TUI |
| `<root>/<id>/versions/v-*/extension.json` | `/ext` 与 CompositionCard 的明细：`runtime`/`contributes`（tools / skills / **system_prompts** / commands / policy / 本前端那一条 `ui.tui`）；root 由 `ext list` 指出 |
| `.nulya/tool-usage.jsonl` | `/ext` 里的 usage 表：一行取 `tool_id` + `ok` → uses_total / recent / success_rate，**跨全部 session 聚合**（**只投影，不重算排序**——排序是 kernel policy，TUI 不复刻）。行上还有 `at` / `session?` / `duration_ms?`（DESIGN §5.5），TUI 只挑它要的两列、其余原样忽略。单场自己调了几次工具、几次失败，`session list --json` 的 `tools{calls,failures}` 已经从 ledger 派生（DESIGN §14），这条 journal 只在需要跨 session 的成功率或耗时时才查 |
| header `composition.native_tools` / `active[]` | 本场冻结契约（§5.1）；与 store `current` 比对 → "下一场会变"的漂移提示 |
| shell 结果形状 | `stdout` + `--- stderr ---` + `[exit N]`（`tools/shell.zig`）→ 状态 chip 解析 `[exit N]` |
| `tool_results[].presentation` | UI-only JSON；`{kind:"diff", patch, path?, filetype?, added?, removed?}` 交给宿主 diff primitive。`std.edit` 的 diff 由 extension 从实际 `ReplacementPlan` + 旧/新文件字节写入 sidecar；TUI 不解析 edit 参数；语法高亮与 `+N -N` chip 由宿主从 surface 计算（或读 surface 显式字段） |
| 取消标记文本 | `loop.zig` 四种 marker（interrupted / canceled executing / recording canceled / not executed）→ 识别成 canceled 卡片 |
| `emit` 溢出 | `tool_results[].spill_path` → 卡片尾部 "full output → path"，`o` 打开（`$EDITOR` / 展开读文件） |

### 2.2 内核改动之一：`nulya session step` 的行协议 `[已落地 · T0 → DESIGN §14]`

**协议与机制的真相在 [DESIGN.md](DESIGN.md) §14**（`loop.StepContext.observer` 纯观测钩子 + 行协议）。这里只留 TUI 侧的消费约定：

- 一行一个 JSON，写完即 flush；带 `stream` 字段 = 瞬态观测行，不带 = 与 `session events` 同形的 ledger 事件行（同一套 seq，可直接按 seq 入 items）。
- 行序（每个 step）：`started → text_delta* / thinking_delta* → tool_use_start / tool_use_input_delta* → done → tool begin/end* → 该 step 的 ledger 行 → step end`；整次调用最后一行是 `run done{steps,stopped}`（`stopped ∈ end_turn | budget | canceled | max_tokens`；被 `max_tokens` 截断的 step 的 `step end` 多一列 `"stop":"max_tokens"`，DESIGN §4）。见到 `step end` 就知道这一步的事件已全。**瞬态失败**（DESIGN §13）：一次尝试中途可能冒出 `{"stream":"model","event":"retry","attempt","max_retries","delay_ms","error"}`——这次尝试的 delta / usage 全部作废，内核退避后原样重发、再从 `started` 开始；`session.ts` 收到它就 `dropInFlight` + 回退 provisional usage，并把 "retry n/m in Xs" 放进 `error` 供 **transcript 末尾**的 `ErrorNotice` 显示（§4.2），下一个 `started` 清掉。
- `reasoning_item` 不出现在流里（不透明、只为回放）；thinking 的可显示文本只有 `thinking_delta`，turn 结束后从 ledger 的 `reasoning` 尽力抽（§4.2）。
- 诊断也是 JSON（`{"stream":"run","event":"error","message":"…"}` + 非零退出），所以 `nulya/cli.ts` 的解析器**永远**不必处理裸文本行。

**明确不做的内核改动**（放进 §10 待议）：`session new` 自动记 spawned-by；`<id>.live` sidecar。（`nulya config show`、`session step --gate` 与 `session append` 的投递回执当时也在这张单子上，后来都做了——前两条因为前端不该复刻配置合并链、"前端自己发明审批"会让模型永远不知道自己被拒了（§5.7）；`session append` 的回执因为 core-review 小刀那一轮把 `--stream` 收成唯一协议时顺带做了，见 [core-review.md](goals/core-review.md) §4。TUI 侧还没接它——`session.ts` 的 `queued` 转正仍按拼接文本匹配，§2.1。）

## 3. 目录与模块（`tui/`）

```
tui/
├── package.json  tsconfig.json  bun.lock  README.md
├── src/
│   ├── main.tsx              # 参数解析（--session <id> | --new [--profile p] [--model id] [--effort e] | --workspace dir）→ launch.planLaunch → createCliRenderer → <App/>
│   ├── launch.ts             # 启动选择：命令行 > tui-state 上次选择 > 内核 active_profile，每层过 config show 的 credential；都不行 → 离线场 + 开屏选择器（D10）
│   ├── nulya/                # ★ 唯一知道内核形状的目录
│   │   ├── bin.ts            #   binary 发现：NULYA_BIN → <repo>/zig-out/bin/nulya[.exe] → PATH；版本探测（`nulya --version` 若有）
│   │   ├── cli.ts            #   spawn：new(--profile/--model) / append(--file) / step --stream [--effort] / events / cancel / config show --json；--stream 行 → 类型化 StreamLine
│   │   ├── ledger.ts         #   Header / Event 类型（DESIGN §3.4 形状）；events 行解析；四种 cancel marker 识别；tool_results[].presentation 只是 UI-only JSON
│   │   └── files.ts          #   .nulya/ 布局：sessions 列表 / lock 探测 / extensions store / tool-usage 投影
│   ├── state/                # 视图状态，都不碰终端
│   │   ├── session.ts        #   一场 session 的视图状态：items（seq 键）、in-flight turn、pending appends、usage 累计、role（driver|observer）、runningModel
│   │   ├── driver.ts         #   状态机 idle→appending→stepping→idle；run done 后若仍有 pending 未转正 → 再 step；wake()（§5.9）
│   │   ├── attach.ts         #   角色探针（`<id>.lock` + SessionBusy）与 idle 定时器
│   │   ├── tabs.ts           #   tab = (workspace, session)：attachment + tab 级 effort + 它自己那棵 pane 树
│   │   ├── panes.ts sidebar.ts subpanes.ts  # 两棵 pane 树的适配、侧边栏、sub-agent pane
│   │   ├── settings.ts settingsfile.ts      # tui.toml 读（user → project）与最小编辑（§7）
│   │   ├── tui_state.ts recents.ts          # 程序写给自己的两个文件（§7）
│   │   └── tasks.ts context.ts targets.ts enter.ts envprofile.ts …  # 后台任务 / 窗口占用 / exec target 探测 / 进入一个目录 / 按 target 的工具面 profile
│   ├── pane/                 # pane 树本体（tree.ts）、surface 注册表（registry.ts）、焦点单一仲裁（focus.ts）
│   ├── plugins/              # 包带进来的前端代码：host.ts（加载与五个注册面）、surface.tsx、context.ts
│   ├── render/               #   registry.ts 是唯一按 tool 名 / 命令前缀 match 的地方
│   │   ├── cards/            #   一个 ledger 形状一张卡（UserTurn / AssistantTurn / Thinking / ShellCard / ExtToolCard / PluginToolCard / RunCard / SubSessionCard / TaskFinishedCard / RebindCard / CompositionCard / CanceledCard / …）
│   │   ├── runs.ts syntax.ts #   run 摘要的分组规则；fenced code 的调色板（§6.2）
│   │   └── theme.ts          #   tokens 与 glyph 表（§6）
│   ├── ui/                   #   App / Transcript / Composer / StatusBar / TabBar / WorkingStatus / 各 picker 与面板 / PaneHost / columns.ts rows.ts / overlays(…)
│   ├── approvals.ts readonlyshell.ts  # 审批链与只读命令分类器（§5.7）
│   ├── agents.ts packageCommands.ts commands.ts skills.ts  # 委派、包命令、内建命令、skill
│   └── keymap.ts
├── plugin-api.d.ts           # 包的前端契约，唯一一份（§1.3、T40）
└── test/                     #   bun test：cli.ts 用 NULYA_SCRIPTED_MODE 跑真实二进制；render 用 @opentui/core/testing 快照
```

纪律：
- `nulya/` 之外不出现 `Bun.spawn`、不出现 `.nulya/` 路径、不出现事件字段名字符串。
- `render/registry.ts` 是**唯一**按 tool 名 / 命令前缀 match 的地方（tcode `RenderRegistry` 同一教训）；live 与 replay 走同一组卡片。
- TUI 不持有隐藏的会话真相：关掉重开、`--session <id>` 回放出来的必须和刚才看到的一致（测试钉住）。

## 4. 交互设计

### 4.1 主屏

```
─────────────────────────────────────────────────────────────────────────────────────────────────────
  ▎ session · 2026-08-16 14:02 · frozen composition
  ▎ tools  shell ⚡read ⚡edit ⚡grep      skills  evolution zig-style
                                                                                        (CompositionCard)
  › 把 emit.zig 的 head/tail 预算改成可配置                                              (UserTurn)

  ● 我先看一下 emit.zig 里预算的定义…                                                    (AssistantTurn, markdown)
    ▸ thinking · 1.2k chars                                                              (Thinking, 折叠)
    $ nulya src emit.zig                                                 ▸ 212 lines     (EvolveCard: 读内核源码)
    ⌘ edit · src/emit.zig                                                     (+2 -1)       (std plugin card, diff 默认展开)
      @@ -12,3 +12,4 @@
      -pub const head_bytes = 4096;
      +pub const head_bytes = 4096; // default, see OutputBudget
      +pub const tail_bytes = 2048;
    $ zig build test                                                ▸ 38 lines · exit 1  (ShellCard, 折叠)

  ⚙ ext build .nulya/extensions/lint → v-3f2a91                                          (EvolveCard)
  ⚡ capability · lint@v-3f2a91 · tools: lint_zig                                        (CapabilityBanner)

  ● 改好了，测试通过。要不要把默认值也写进 default.toml？                                (streaming)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 ⠋ shell · 3s · esc to cancel · ↑12.4k ↓3.1k cache 89%                            (WorkingStatus §4.4b)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 › 好，写进去_                                                                            (Composer)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 ◧ unsafe · claude-sonnet-5 (high) · tools 1+3                          ◕ 61% · step 4  ⚙
```

**内容区是一棵 pane 树**（T68/T69，goals/tui-shell.md §5.1）：上面画的是它的退化形——一个 pane，一个 surface。`/sidebar`（`F8`，或状态行行首那个 `◧`）在它左边劈出第二个 pane，装 sessions 列表的窄宽变体（§5.4）；`Ctrl+←/→` 在 pane 之间移动键盘，`Esc` 从侧边栏回主 pane。**开侧边栏不移动焦点**，所以打字照常进输入框；只有人把键盘送进去，它才拿键盘（那一刻输入框的边框退回 `hairline`，§6.1 第 5 条那个唯一信号照常成立）。整屏 overlay（`F2`/`F3`/…）永远开在**主 pane**里，与键盘当时在哪无关。

四块：transcript（`scrollbox`，sticky bottom，鼠标滚轮 / PgUp / PgDn；离开底部时状态栏出现 `↓ new` 提示）、**输入框上面那一行**（0 或 1 行，只在有事发生时存在，§4.4b）、composer（`textarea`）、**输入框下面那一行**（1 行，§4.5）。没有边框，用两条 hairline 分隔；空状态首屏是一个小 wordmark（`ascii-font`）+ 一对 `cwd` / `shell` 行（文件在哪、命令去哪，两行都可点）+ 几条 `/` 命令 + **一条 tip**（`Welcome.tips`）。

**每个 tab 有自己的 workspace**（T71，goals/tui-shell.md §5.3b）：tab = (workspace, session)，这个 tab 的每一次 spawn（`session new|step|append|events`、`ext run`、`task list` 轮询、compact、agent render）都跑在它自己的目录里。**空状态那一行 `cwd` 从此是个控件**——点它开 `/cwd` 的目录浏览器（整屏 overlay，§5.11），因为那正是这个 tab 的目录还是个**决定**的那一屏。第一条消息之后接手的是状态行上的 workspace chip，而**它只在说得出新东西时才占列**（§6.1 第 4 条）：屏幕上开着第二个 workspace，或者这个 tab 就是 `no project` 那一个。只有一个目录时——也就是今天每一个人的屏幕——那一格不存在，这一行逐位不变。

**只有一条线，是输入框自己的边框**（T26）：TabBar（>1 个 tab 时）· transcript · 输入框 · 状态行，四块之间原来有三条通栏 hairline，现在一条都没有——见 §6。**没有标题行**（T22）。原来那行是 `nulya · <session id> · <profile> · <model> · effort · tools · skills`：给程序看的，不是给人看的——session id 人读不出也用不上（要它就去 `/sessions`），`nulya` 是废话，provider 名字紧挨着 model id 也是。它说的唯一有用的东西是**模型**，而模型该在人打字时看得见的地方——输入框底下，tcode 就是这么放的。TabBar 仍在（>1 个 tab 时），但 tab 名是**模型 + 需要时 `#n`**、draft 标 `(new)`，不是 session id。
**tab 条是鼠标也走得通的**（T70）：当前那个戴 `▎`（其余两格空白——**形状**，所以 NO_COLOR 下也分得开；从前每个 tab 都戴 `⤷` 而 `⤷` 是 sub-session 的字形，等于每一行都在说一件与它无关的事），每个 tab 尾巴上一个 `✕`（faint，悬停变 err，点它 = `Ctrl+W` 的 `tabs.close`），整条末尾一个 `+`（= 裸 `/new` 的 `startDraft`）。名字按剩余宽度均分并 `fit` 截断，**绝不换行**——这一条的内容数量是人决定的，而一条会长成两行的 chrome 每开一个 tab 就把整屏往下推一行。`◧` 与将来的包 chip 都不在这条上（前者在状态行行首，后者在 composer 下面那条带，goals/tui-shell.md §4）。

### 4.2 Transcript 项与卡片

| ledger / 流 | 卡片 | 头行 | 体 | 默认 |
|---|---|---|---|---|
| header | CompositionCard | `session · 时间 · frozen composition` | tools（builtin 平色、ext 带 ⚡）、skills、model identity、parent 链接 | 展开，一场一张 |
| `user_text` | UserTurn | `›` + 文本（markdown 关，保留换行） | — | queued 时头行加 `· queued` dim |
| `assistant.text` | AssistantTurn | `●` + markdown（tree-sitter 高亮） | — | 展开 |
| `assistant.reasoning` / `thinking_delta` | Thinking | `⋯ thinking  (N chars) ▸`（T26 起与所有卡片同一个 `CardFrame`，dim 一档） | 流式时显示滚动的最后一行 dim；结束后从 `reasoning` 尽力抽 `thinking` 字段（Anthropic 形状），抽不到显示 `reasoning (opaque)` | **默认 `hidden`**（T43）；设定 `thinking = hidden\|collapsed\|expanded`。hidden 时它**离开 item 列表**（`Transcript.visibleItems`）而不是画一张零高的卡——否则它前面那一行空行还留在屏幕上 |
| call `shell` | ShellCard | `$ 命令  (N lines[· exit N]) ▸`（exit 0 不写） | 完整命令（按宽度硬换行）+ stdout / stderr 分段；尚无输出的运行中调用也能展开 | **折叠**；设定 `tool_output` |
| call `shell` `{background:true}` | ShellCard（后台变体） | `$ 命令  (background <sid>/t3 · running 12s) ▸`；报告到了换成 `(background <sid>/t3[ · exit N] · 41.8s)` | 回执原文（任务全名 + log 路径 + 三条命令） | **折叠**；**不加新 glyph**（还是那条命令，变的只有那一格 note） |
| `note` · `source:"task"` | TaskFinishedCard | `$ 命令  (background <sid>/t3[ · exit N][ · killed] · 41.8s) ▸`（`exit 0` 照 T26 省略） | 输出 tail + 尾行 `full log → <path>` | **折叠**；一条事件一张卡，不是回执那张卡的更新 |
| 一串调用 | RunCard | `⋯ read ×3 · grep ×2 · shell ▸`（glyph 是 thinking 的三点、全程 dim、**没有 note**——一个 run 按构造就是"都成功了、没什么可给你看"，再写一格 `(6 calls)` 是同一句话说两遍，T26） | 展开就是原来那些卡，各自照旧折叠 | **折叠**；设定 `run_summary`。**进得去的**只有「跑完 + 成功 + 没有身体」的 `shell` / 扩展 tool，且至少两个；**进不去的**：还在跑的、失败的（含 `exit != 0`）、被取消的、回执型的（后台任务 / 子场）、`edit`、演化动作、`checklist`/`markdown`、包自己用代码画的卡，以及**任何声明了 `render` 的 tool**——那就是包说「我对这次调用长什么样有意见」，一个有画面要给的调用不该被概括（`render/runs.ts`） |
| diff surface（`std.edit`、`git_apply`、migration 等任意插件卡片） | PluginToolCard + host diff surface | `⌘ tool · path  (+2 -1[· failed])` | `tool_results[].presentation` 里的 diff surface（OpenTUI `diff`，语法高亮，长行按字符换行）；无插件或无 presentation 时退回普通 ext 输出 | **展开**；设定 `diff = expanded\|collapsed` |
| call `ext:*` | ExtToolCard | `⌘ tool_name · 参数摘要  (N lines) ▸`（**第一个参数不写键名**——工具的第一个参数就是它的主语：路径、模式、命令，T26） | 输出 | 折叠 |
| shell 命令前缀 `nulya src` / `nulya ext init\|build\|activate\|deactivate\|run` / `nulya skill load` / `nulya session new\|append\|step\|events` | EvolveCard / SubSessionCard | 见 §5.2 / §5.5 | 原始输出可展开 | 折叠但头行信息量大 |
| `note` · `source:"ext"` + `meta.id` | CapabilityBanner | `⚡ capability · id@version · tools: …` | note 全文 | 展开 |
| `note` · 其它 source | UserTurn + badge | 正文 + `· <source>`（插件的那条 badge 是 `meta.pkg · meta.kind`） | 原文 | 与 user turn 同形，badge 说它从哪来 |
| sentinel user turn | 包的 user-turn renderer / SkillEcho | 由**声明它的那个包**折回原话并带 badge（`<approval-note>` / `<task-stopped>` / `<user-skill>`；`<ext-note>` 是老 session 里的形态，现在是一条 `note`） | 原文 | 折叠；没装那个包时它就是一条普通 user turn，原文照样读得到 |
| canceled marker | CanceledCard | `⊘ tool · canceled (side effects unknown)` 三种文案对应三种 marker | — | 展开 |
| `spill_path` | 卡片尾行 | `full output → .nulya/scratch/…` | — | — |
| （不是事件）`snapshot.error` | ErrorNotice | `✗ ` + 驱动侧最近一次**显式操作**失败的原文（provider 的 retry、`run error`、`step exited N`、`session new` 被拒）；step 非零退出时保留结构化 `run error`，并把 provider 留在 stderr 的响应详情接在下一行 | — | 永远展开，在 items **之后**；下一次 user send、显式 `/step`、take over 或真正的 `model started` 清掉；timer wake / replay / 切 tab 不清 |

**`ErrorNotice` 不是 item**：它没有 ledger 事件、replay 也不会重现它，所以像 CompositionCard 一样待在 item 列表**外面**（一个在顶、一个在底），不必参与 `seq` 排序或 `dropInFlight`。它从状态栏搬下来，因为那一行只有一行、还要和 model / cost / chips 分：`error: model request failed (Transp` 就是所有人真正读到的错误的形状。换行由我们自己做（`wrapWords`，同 `ui/Fact` 的理由），状态栏只留 `error · see transcript`。

折叠交互**两种，不是四种**（T38）：鼠标在头行**按下与松开落在同一格**才切换（拖过去的是选取文本，不是点击，T18）；`Esc` 空 composer 时进 browse 模式（`j/k` 移动高亮卡、`Enter`/`Space` 切换、`Esc` 回 composer）。**`Ctrl+O` 与 `Ctrl+Shift+O` 已删除**：前者是第三种折叠方式、且作用于"碰巧是最后一张"的那张卡（说不出自己作用在谁身上的手势）；后者一次展开屏幕上每一张卡的正文，那不是任何一种视图。反方向留着：**`/fold` 全部折起**——读开了几张之后想要的正是这个。这一栏因此空了两个 `[keys]` 动作，见 §7。

### 4.3 流式与状态机（provisional → authoritative）

- 每次 `step --stream` 期间维护一个 **in-flight turn**：`text_delta` 追加到一个流式 AssistantTurn（只有这一块重排；已完成的 turn 是独立 renderable，不重解析）；`tool_use_start` 立刻建 tool 卡（`pending`）、`input_delta` 拼参数、`done` 后 parse；`tool begin/end` 切 `running → done`；`tool_results` 事件填输出。
- ledger 事件行到达 → 以 `seq` 为键写入 items，**替换**对应 provisional 项（文本应相同；不同以 ledger 为准并 debug 日志）。
- `user_text` 事件到达 → 与 pending appends 按顺序匹配转正；内核会把同一次 drain 的多条 queued 消息以空行合成一个 turn，前端因此把对应的多张乐观卡折成这一张 committed 卡。事件行在 `model started` 之前到，所以模型一开始回答，卡片就已经不再标 `queued`。
- `run done` → 状态回 idle；若 pending appends 仍有未转正的 → 自动再 spawn 一次 step（用户在跑的中途发了话、但 run 已 end_turn）。
- 观测粒度就是 kernel 的粒度：TUI 不猜 "模型在想什么"，只显示流。

### 4.4 Composer / 按键 / slash

- `Enter` 发送；`Shift+Enter` / `Ctrl+J` 换行；`↑` 空 composer 时翻历史；粘贴多行原样。
- 发送时若 `stepping`：只 append（queued）；不打断。**正文只在 transcript 那张用户卡上出现一次**，输入框上面的 queue lane 只画一行计数 `⏸ N queued · ctrl+g interrupts & delivers`（静息时不画）；要提前结束当前 step 并投递就是 `Ctrl+G`（append → kill 这一步 → 等它真的退出 → 立即再 step；idle 且输入框是空的时走 `wake()`，**inbox 为空绝不裸 step**）。`Ctrl+J` 始终留给非 Kitty 终端的换行——裸 `ctrl+j` 与换行在那些终端上字节相同，抢它会毁掉 `Shift+Enter` 的退路。同一 TUI 的 append 子进程串行启动，保证快速连发取得 inbox 名时仍是 FIFO。
- `/` 开头弹一个小补全，三档依次：**内建命令**（表在 `commands.ts`，也是 `/help` 与补全读的同一张表：`/model` `/mode [ask|unsafe]` `/provider` `/effort <level|auto>` `/env [<target>]` `/new` `/clear` `/sessions [<id>]` `/cwd [<path>]` `/sidebar [<percent>]` `/ext` `/tasks` `/usage` `/context` `/settings` `/outcome <verdict> [note]` `/with [<id>[@<v>]]` `/agent [<name> <task…>]` `/step` `/cancel` `/fold` `/help` `/quit`）· **activate 了的包自己声明的命令**（`contributes.commands`；`/plan` `/ask` `/evolve` `/compact` 都是这一档，包不在就连这个词都不存在）· **activate 了的 skill**（`nulya skill list`，描述截 100 字符）。分发同序：内建 → 包命令 → skill → 原样发给模型。
  - 一个概念一个词：`/with` 就是内核的 `session new --with`；`/new` 另开一个 tab、`/clear` 把**当前** tab 原地换成一张新草稿（同一个数组下标），两者都不删任何东西（ledger 只能 append，旧 session 的文件照样在盘上、`/sessions` 照样找得到），区别只在"新的那一场落在哪个 tab"。
  - **`/as`（`/with` 的旧名）· `/resume`（`/sessions`）· `/exit`（`/quit`）不上表但补全**：不列出是这个前端只为一个概念主张一个词，补全是回答一个已经打了四个字母的人；别名与本名走**同一段代码**，且都在 `builtin_names` 里，所以包夺不走。
  - `/<skill> [args]` = `nulya skill load <ref>` 拿到 body、包一层 sentinel 后作为**普通 user turn** append（谁触发不等于谁判断，goals/tui-panel.md D8）；与包命令重名的 skill 不在菜单里出现第二次。
- `@` 开头（前一字符非字母数字下划线）弹文件补全：`↑↓` 选、`Tab` 上屏成 `@path`；已知引用在输入框里 accent。**上屏的是路径，不是文件内容**（T13）。
- 粘贴：> 1000 字符或 > 15 行折叠成 `[Pasted text #N]`，提交时展开回原文；`Backspace` 落在占位尾部整条删掉（T14）。
- 有 tool call 在等批准时（§5.7），**审批对话框拿着键盘**：`↑↓` / 数字键选答案、`Enter` 作答、`Tab` 在答案列表与 note 之间切、直接打字即写 note、`Esc` 在列表上 = deny（在 note 里先清空）。带 modifier 的键（`Ctrl+C`）照旧穿过去。
- 全局：`Esc` cancel（stepping 时）/ browse 模式；**`Ctrl+C` 由近及远，永远不在第一下退出**（T27）：输入框里有字 → 先清空（`ComposerApi.clear`）· 正在 stepping → 先 kill 这一步 · 都没有 → 先说一句 `Ctrl+C again to quit`，**再按一下才退**（提示 3 秒后失效，所以几分钟后的一下永远不是意外退出）。半条写了一半的消息、和整个屏幕，都不是第二次按键能撤销的东西；`main.tsx` 的 `exitOnCtrlC: false` 是这条链成立的前提。`Ctrl+L` 重绘；`F2` `/ext`；`F3` `/sessions`；`F4` 下一个 tab；`F5` `/model`；`F6` `/provider`；`F7` `/tasks`；`F8` `/sidebar`；`Ctrl+W` 关掉当前 tab（最后一个不关）；`Ctrl+←/→/↑/↓` 在 pane 之间移动键盘（**只在不止一个 pane 时才认领这四个键**，平时它们仍是 textarea 的 word-motion）。
- 鼠标（T18）：列表行点一下落光标、点已选中的行执行它的 Enter；`/ext` 的 pane 条、`[x]` 与 id 行的开关记号、TabBar、状态栏的 `↓ N more below`、输入框都可点（点输入框也会退出 browse 模式）；拖过文本是选取，松手复制（OSC 52）。**模型这一行处处可点**（T20 → T22）：**输入框下面那一行开头的 `<model-id> [(effort)]`**、CompositionCard 的 `model` 值都开 `/model`；Welcome 的那几条 `/` 命令行、那一行末尾的 `/help` 也是按钮。所有可点的东西悬停都是同一种反馈：**把这一行自己的颜色朝 `lift` 抬起来**（T95，`ui/rows.ts`），背后不刷底色——底色只留给光标（`selection`），两个事实两种手法。
- **第一条消息才建 session**（T22，D11）：开屏是 draft，`Enter` 发送时先解 skill（`/name`）、再 `session new`、再 append+step。内核在这一步的拒绝（缺 key / store 未信任 / 成员或工具认不出）**留在屏幕上**：notice 是内核原话，tab 仍是 draft，**打的字回到输入框**（`ComposerApi.restore`，只在框还空着时放回去——人在等的时候又打了别的，那是人的）。draft 上 `/outcome` `/compact` `/step` `/cancel` `Esc` 各回一句"这个 tab 还没有 session"，一个都不炸。
- `/model`（F5）与 `/provider`（F6）是**两个命令、两个问题**（T5 → T6 → T20 → T21，与 tcode 的 `/model` ÷ `/provider` 同一刀）：
  - `/model` **只有模型**：每个能跑的 provider 的每个 model 一行（`provider · label · id · ctx · ‹ effort › · ✓ current`），`h/l` 拨 effort、Enter 开新场；跑不了的 provider 不出模型行（这才是让表变短的东西），`provider` 那一列保证"这是谁家的模型"一眼可读。一个 model 的 ctx / effort 档位**先读该 profile 自己的 catalog**、没有才回落全局 `[[models]]`——同一个 id 在订阅口与公共 API 口是两个东西。一个 provider 都跑不了时只有一行 `no provider can run yet · /provider …`，Enter / `p` 就是过去。
  - `/provider` 是 **key 与 endpoint 的家**：一行一个 profile（`name · wire/endpoint · N models · 状态`），detail 行列出它的 model id（浏览不拦，拦的只是开一场），`s` 贴 key、`a` 加 compatible endpoint，codex 说 `codex login`；**Enter 在能跑的 provider 上 = 回 `/model` 并落在它的第一个模型上**——"先选 provider 再选它的模型"就是这两步。
  - 开屏没得跑时：还有别的 provider 能跑 → 开 `/model`；一个都跑不了 → 开 `/provider`（`launch.LaunchPlan.guideOn`）。
- observer 时空 composer 上的 `Enter` = take over（§5.6）；browse 模式里选中的卡若指名了一个 session，`Enter` 在**当前 tab 内部**开一块观察 pane（§5.5）、`t` 才给它一个自己的 tab，`Space` 永远是折叠。

### 4.4b 输入框上面那一行（正在发生什么）

**在发生事情时才存在**（T38，`ui/WorkingStatus.tsx`；参考 tcode 的 `status_line`）。静息态它不占一行——不是写一句 `idle`，是**根本不画**。

分工是一句判断：**"这一场是什么"与"此刻在发生什么"是两个问题，被读的频率差一个数量级**。前者（model / mode / face / cost）读一次就信了，住在输入框**下面**；后者每过一秒都要再读一遍，之前挂在那一行的尾巴上——屏幕上**最少的列、最低的对比度**给了唯一一个活的事实，还逼着那一行常年留一格给 `idle`（一个"没什么可说"的词）。现在它自己一行，就在你要打字的那个框上面。

一行两段：**主段**（一个 spinner + 它是什么，`accent.assistant` 绿——正在跑的就是 assistant 那一轮，不是警告）· **尾段**（`dim`：`· 12s · esc to cancel · ↑12.4k ↓3.1k cache 89%`——**花掉多少也在这里**（T42：一个会变的总数，正是只在它变的时候值得读；静息态它下面那一行不再写它）；尾段窄屏时从末尾截，所以这三样的顺序就是它们该被丢掉的顺序。钟给一切在动的东西，`esc to cancel` **只给 Esc 真能停的那一步**（本 tab 正在 drive 的 step，`Activity.cancelable`）：`waiting for your answer` 底下写它是在提议取消一个已经停住的 step，`2 background` 或 observer 排队的 append 底下写它则点名了一个其实会进 browse 模式的键，而后台命令本来就活得过 step）。`12s` 的钟来自 `Driver.startedAt`（离开 idle 时打点、回 idle 清掉；observer 用它自己排队的时刻），**跟着动画那一拍重采样**——渲染里读墙上时钟就不是它输入的函数了。

**高光扫过**（`theme.shimmerColor`，逐条移植自 tcode `theme::shimmer_color`）：一条高斯软带从左扫到右，越过尾巴后停一拍再来。它**抬起每格自己的颜色**（朝 `theme.lift`）而不是覆盖它，所以绿的还是绿的、静止时每一格精确等于 base。`theme.lift` 是主题自己声明的（深色朝亮、浅色朝墨、`NO_COLOR` 就是 `fg` 因而整个扫描是 no-op）——"更亮"不是颜色自带的方向。实现上**一格一个 `<text>`**：`<span fg>` 是显然的写法，而 @opentui/solid 到 0.5.9 仍把这个 prop 丢掉、整段一个颜色（实测）；`Index` 而非 `For`，位置固定、字符在变。`motion = false` 关掉的正是这两样（spinner 与扫带），文字一字不变。

**什么会出现在这一行**（判据是纯函数 `activityOf`，一处定义）：等你回答的 tool call（warn，静）· `error · see transcript`（err，静）· observer 的 `press ↵ to take over` / `queued for the other writer` · `canceling` · **正在跑的 tool 名，没有 tool 就是 `thinking`** · `sending` · `step budget spent · /step to continue`（warn，静）· `reply cut off (max_tokens) · …`（warn，静）· 开屏那趟 store sync 的 `building <id> (5/8)`（它压过 background，但排在上面每一样之下——一趟 store pass 从不挡住对话）· 最后是 `N background`（可点 → 输入框上面的任务面板，§5.9）。**后台计数与其余每一段并存**（`Activity.background` 自己一段、自己的点击区，裁剪时它最先被挤掉）：一个前台 step 与一条后台命令是两件事，写掉哪一件都是假话；只有"background 就是唯一内容"那一支不重复挂它——那时数字本身就是这句话。**其余一律 null**：idle、跑完了、被取消了——那些是静息态，transcript 里有它们的卡片。observer 的 `following` 也删了：那不是活动，是这个 tab 的身份，下面那一行右边写着。

### 4.5 输入框下面那一行

一句**纯粹的静态描述**——"这一场是什么"，不是"此刻在发生什么"（后者在 §4.4b 那一行）。两端是 host chrome（行首 `◧` 侧边栏把手、行尾 `⚙` 设定入口），中间是这一场自己的事实：

（**驱动侧的失败不在这一行**：`error · see transcript` 写在上面那一行（§4.4b），原文整段在 transcript 末尾，§4.2 `ErrorNotice`。）

**权限 mode**（`ask` / `unsafe`，**行首**，可点 → mode picker（再点一下收起），§5.7；`unsafe` 是 warn 色——它是屏幕上每个 tool call 被裁决的立场，该在 model 之前读到） · `<model-id> [(effort)]`（**主语**，`muted`，可点 → `/model`；已开场的读 `state/session.ts` 的 `runningModel`（header 那一列，整场不变），draft 读它的 pick；effort 只在本 tab 明确选过时才写括号——`auto` 就是内核默认，为它花七列不值） · `tools 1+N`（`dim`，可点 → `/ext`；1 = 那一个 builtin `shell`，DESIGN §5.1；draft 上 N = 合并 config `[extensions] with` 选中的 tool ∪ `tui-state.json` 的 `session_with` 选中的 ∪ **每一场都被组合进来的那些包（config `[extensions] with` / `tui.toml` `session_with`）active 版本的 `surface: "auto"` tool**，再 ∪ 那几个包声明的 `surface: "manual"` tool（由 `sessionExtras` 在 `session new` 那一刻写进同一条 `--with`））。**token 累计不在这一行**——它在 §4.4b，只在跑着的时候写（`state/session.ts` 的 `usageLabel`，来源是 ledger 的 `assistant.usage`；`/usage` 里是全部账）。右：**context ring**（`◕ 72%`，可点 → `/context` 面板） · `↓ N more below` · **`◈ <id>`**（这一场戴着的、contribute 了 system prompt 的包，`accent.evolve`，可点 → `/ext`；draft 读 `--with` 的 ref，已开场的读冻结 `contributions` 与 header 的 inline prompt——顶上那张卡默认折着，不写这一格就一个字都没有） · **`⇥ <spec>`**（shell 跑在哪，warn 色，可点 → `/env`；local 就整格不写，§5.11） · **workspace chip**（只在屏幕上开着第二个 workspace、或这个 tab 是 `no project` 时才占列，§5.11） · `step n`（**跑过步才写**）· `observer · driven elsewhere`（§5.6；**只有例外说自己**——当写者是常态，`driver` 那个词在每个人的每一场里都一模一样，一格恒定的东西不是信息）。离开底部时插入 `↓ 3 new`。

**没有的东西不占列**：没跑过步就不写 `step 0`，是写者就不写 `driver`。**键位提示也不在这里**：一个永远在那儿的提醒过了第一个小时就没人再读，而它占的是屏幕上最挤的一行；它在开屏那一屏，一次一条 tip（§4.1、`Welcome.tips`）。

**notice 盖住整行，然后自己下去**。有 notice 就整行是它（`fg`），停留时间按长度算（`App.noticeHold`：`1500 + 45/字`，夹在 3 s–9 s），到点自己让位给静息态。下限 3 s 就是 `Ctrl+C again to quit` 落的地方，也正是那个 offer 有效的窗口——两者**由构造相等**而不是碰巧：arm 到期时同一处把这句话取下来。两个例外用 `holdNotice` 声明：browse 模式的键位提示与等着回答的 handoff 提议——它们不是新闻，是屏幕**正处在**的状态，各自的代码路径负责清掉。

**窄屏让位的顺序是一句判断，不是平均分**：mode 与 model **永不让**；再窄就丢 `tools`（上面的 CompositionCard 已经把工具面写全了）。notice 不参与这场分配（它拿整行），活动也不参与（它自己一行，§4.4b）。

上下文占用是**一个环 + 一个百分比**（`◕ 72%`，T82；从第一步有计数起就在，颜色分三档：<60% dim · ≥60% warn · ≥85% err，并在 err 档补一句 `· /compact`）。分母是 `[[models]]` 目录的 `context_window`（目录没写就整个不显示，不编分母）；分子是**最后一步**的 `input + cache_read + cache_write`——`provider.Usage.input_tokens` 是扣掉缓存之后的量，只读它会把一个快满的窗口报成几乎空的。它只是显示，不触发任何动作；点它（或 `/context`）展开 §4.5b 那个面板。

### 4.5b context 面板（`/context`，T82）

输入框上面的一块（与 `ModePicker` / `ApprovalPanel` / `PluginPanel` 同一区、同一套 `Dialog` 骨架），**被动**：不进 `resolveFocus`、不拿键盘、里面没有可选的东西。`Esc` 收（`handleGlobalCancel` 第一支——刚开的东西先答），再点一次环也收。**trusted zone 在时整个不画**（`dialogUp()`），zone 一走原样回来——与包的面板同一条规矩：没有任何东西能挤在人和一个审批问题之间。

内容是 `state/context.ts` 的一个**分节数组**（纯函数）：① `context`（last prompt / window / free + 一条横条，横条用两个形状而不是两种颜色，`NO_COLOR` 下照样读得出满到哪儿） ② `this session`（input / cache read / cache write / output / priced steps，**为零的不写行、一行都没有就不写这一节**）。**留给第三节的是形状不是空位**：provider 自己报的订阅用量（codex 的 rate-limit 窗口）到时候就是多一节 —— 没有行的节永不产生，所以今天它一列都不占。全部数字来自 ledger 的 `assistant.usage`（`/usage` 仍是全部账；这里只是与一个决定有关的那几个）。

## 5. nulya 独有视图

### 5.1 CompositionCard（每场 session 的冻结契约）

来自 header：model identity（provider/model/base_url 主机）、`active[]`（ext id@version 短 hash）、`native_tools`、skills（从各 active 版本的 `extension.json` `contributes.skills` 读）、`parent`。这是"这一场模型看到什么"的一眼版本；打开两场对比就是演化的差分。

**它会折，且默认折着**（T25，设定 `transcript.composition`）：静息只有两行——标题（`session · <时间> · frozen composition`，右端一个折叠记号，与每张 tool 卡同一列）与 model 行（`model  <provider/model> · tools 1+N · skills n · prompts n · ext n`，模型本身仍是 `/model` 的点击目标，点击不冒泡到折叠）。展开后每根轴一行：`model`（这一行的右半换成 endpoint 主机）· `tools` · `skills` · `prompts`（贡献 system prompt 的包名）· `ext`（`id@v-` + 8 位）· `parent`。**版本哈希是 provenance，不是每场都值一屏的东西**——五个自带扩展的全串曾经在第一句话之前占掉八行。

**每一行都是"标签列 + 会换行的值"（`ui/Fact`），不是 flex 行。** OpenTUI 对超宽的 flex 行不换行而是**压缩**：名字从中间被切、标签与值之间的空格被吞，`model` 于是显示成 `mode`。所以窄屏的处理写死在两处纯函数里——值按 ` · ` 关节折到下一行（`wrapWords`），标题按整段短语退让（完整 → 去掉 `frozen composition` → 只剩 `session`），model 行的计数从最不紧要的一端整格丢弃而不是把 `ext 5` 切成 `e…`。

**draft 变体**（T22）：还没有 session 的 tab 上，同一张卡换个时态——标题是 `next session · set when you send the first message`，三行同序（tools = `shell` + 计划中选上的那些、model = draft 的 pick 解出来的 model id、`--with` 写在 model 那行右边）。数据只来自 `config show --json`、`tui-state.json` 与 `ext list` 已经说过的东西，**没有第二个 composition 解析器**——真正的解析永远是内核在 `session new` 里做的那一次。

### 5.2 EvolveCard（演化动作在对话里的形状）

registry 按 shell 命令前缀识别，头行抽关键事实（抽不到就退回 ShellCard，永不报错）：

| 命令 | 图标 · 头行 | 抽取 |
|---|---|---|
| `nulya src [path]` | `⌕ read kernel · path` | 行数 |
| `nulya ext init [--script] id` | `⚙ ext init · id` | 路径 |
| `nulya ext build path` | `⚙ ext build · id → v-hash` | stdout 里的 version |
| `nulya ext activate id ver` | `⚡ activate · id@ver`（配对之后的 CapabilityBanner） | |
| `nulya ext deactivate id` | `↺ deactivate · id`（回滚没有自己的动词——它就是 `activate` 一个旧版本） | |
| `nulya ext run id tool …` | `⌘ ext run · id/tool`（等同 ExtToolCard 语义，但走 shell） | ok / exit |
| `nulya skill load ref` | `☰ skill · ref` | |
| `nulya session new …` | `⤷ sub-session · <id>`（stdout 的 id） | id → 可打开 |
| `nulya session step <id>` | `⤷ sub-session step · <id>` | 同上 |

配色统一走 `accent.evolve`，与普通工具卡区分开：**演化动作是 nulya 的主角，一眼可辨**。

### 5.3 `/ext` 演化视图（overlay，`F2`）

左列：extensions（**开关记号** · id · **`standing`**（某张常驻成员表点着这个 id：config 的 `[extensions] with`，或 `tui.toml` 的 `session_with`——右栏说是哪一张，因为两处撤销的地方不同。T52 起有这一格，T52 之前叫 `mode`，判据是「贡献了 system prompt」） · 半开时那半格 · draft 状态）——清单是 `nulya ext list` **∪ `ext sync --dry-run`（workspace 与 store 两个 draft 目录）**：`ext list` 只列"持有版本"的 id，所以**只有源码、一次都没 build 过的 id 在它里面根本不存在**（T22 的起因：`std` 躺在 user store 里 build 不出来，`/ext` 一个字都不提，唯一的痕迹是状态栏一句 `3 failed` 滚过去）。这样的行显示 `0v <kind>` + draft 状态（`not built` / `needs zig` / `fails`，warn 色），右栏把**内核那句话原样转述**（它现在自带绝对路径的修法），再加至多一行我们自己的（anyzig 那种 version shim 从 cwd 读 `build.zig.zon`，而那个目录里没有）。没有 `current` 的包（只用 `--with` 穿的 mode / evolution）读最新一次 build 的 manifest，否则它会被显示成空的。右栏（选中项）：第一行是**开关的文字版**（`id · kind · active|inactive · tools N/M on the face · current v-…`）、`pointer workspace|user|none`（哪一层的 `current` 在生效）、manifest 摘要、版本时间线（`versions/v-*` mtime，`current` 标记，本场 header 冻结的版本标记；两者不同 → `frozen v-a · store v-b → next session`）、该 ext 每个 tool 的 usage。

**`Enter`（或点开关记号）= 这个 extension 对下一场的总开关**（T22，D12）：
- **ACTIVE** = `ext activate <id> <version>`（版本取 sync plan 说 built 的那个，否则 store 里最新的 build；一个都没有就拒绝并指向 `b`）**+** 把它声明的 **`surface: "manual"`** tool 选进本 TUI 的成员表（`extensions.selectableToolsOf`，判据是冻结 manifest 的 `surface`，DESIGN §7.2.1）。`surface: "auto"` 的 tool 不必选：包一进 composition 它就在模型面前。**「active」说的是 store 指针与可用性——这个 id 现在指哪个版本、`/with`/声明的命令穿不穿得上——不是「下一场一定带着它」**（T55）：那句保证只有 `standing` 那一格能给，而它的真源是某张成员表点了名（T56）。
- **INACTIVE** = 先把它的 tool 从本 TUI 的成员表**和 user config 的 `always`** 里撤掉（别的 config 层写的撤不了，点名说出来），再 `ext deactivate`。顺序是有意的：一个成员指着没有 `current` 的 extension，`session new` 是**整场拒绝**（`WithVersionNotFound`），所以先撤引用、后撤指针，中间任何一刻的世界都是合法的。`ExtView.dropOrphanTools` 与 `App.healOrphanSelections` 修的是已经写坏的文件。某张常驻成员表仍点着这个 id 时，notice 说的是「每一场都还在点它，而它现在开不出来」。
- **一个 contribute 了 system prompt 的包是"模式"，Enter 对它的意思和对别的包完全一样——让它可用**（T31 点名它、T48 一度把它并进 standing with、**T50 把那半撤回**，ext-review-2 §3b）。它换来的是一条声明的命令（`extensions.wearCommand` 读该包 manifest 里第一条 `{with: true}`，T54）：Enter 的 notice 是 `` <id> active · /<name> opens a new tab wearing it for one session · Enter again takes that away ``（没声明命令的包指 `/with <id>`），INACTIVE 对称地说 `` <id> inactive · /<name> is gone · versions all stay ``——两句都不提"EVERY session"，因为这一行不造成那件事。**「会不会波及每一场」由 `standing` 那一格独立回答**：判据是某张常驻成员表点了名，不是这个包贡献了什么——「贡献了 system prompt」从来只是在没有别的答案时对这个问题最接近的猜法。detail 里那句"a mode"的说明（`` `/<name>` wears its prompt for one session ``）只画给没被任何常驻表点名的包（这句讲的是按 Enter 会怎样），被点名的那些由 `composedEverySession` 那句接手，并点名是**哪一张**放的（两处撤销的地方不同），两句永不同时出现。**一个模式常驻每一场仍然可以**：config 写一行 `[extensions] with`，或 `tui.toml` 的 `session_with`。
- **看得见**：`●`/`○`（ascii `*`/`-`）+ 三档色——`ok` 全 active、`warn` 半 active（另配一格 `3/5 tools` 或 `tools only`）、`faint` inactive。tools pane 的 `[x]` 用同一套色（一处颜色一个含义，§6）。**两个方向都不要 `y` 确认**：都是指针 + 成员表的移动，同一个键就能放回去，且够不着已经开跑的那一场（physics #2）。
- 两根轴仍然在：单个 tool 用 tools pane 的 `Space`（`A` 升 `always`），单个版本用版本线的 `a` / `r`（仍带确认——它们点名一个 build，是时间线上的动作）；`d` **删掉了**（它就是 INACTIVE 的一半，两个键做一件事正是被修的那个毛病）。

**tools pane 只列这个面板动得了的行**（T59）：**`manual` 的能动**（`Space` 写进成员的选择），**任何已经被选中的行也能动**（不管什么 surface——把一条不该存在的选择取下来正是这个面板的用处）；其余（`auto` 的、没被选中的 `internal` 的）折在列表下面一行里，按包自己的词分两组各带一句为什么没有 checkbox：`▸ 2 auto · with their package · 4 internal · ext run only · d shows`，`d` 或点它展开。理由是这一列画的是 checkbox，而 `auto` 行的 checkbox 按不动（它已经在面上，选它是空操作）——一张表里混着长得一样的能按的与不能按的，是最该拆掉的形状。展开状态不记进 `tui-state.json`（是好奇，不是设定）。

其它动作键：`b` build 选中 id 在它 store 目录里的源码（`ext build <root>/<id>`，落哪个 root 由内核按路径决定）；`s` 把随二进制走的那份自带源码写回去再 build（`ext seed --force` → `build` → 原来 active 的才 activate，`differs` 那一列说的就是它）；`p` = `ext prune <id>`（带确认，成功后显示内核自己那句代价说明）；**`r` 只在这一场是 remote 时存在** = `ext push <id>@<v> --env <spec>`（§5.11；帮助行标着「last time: …」——那是一句关于过去的诚实陈述，这个前端答不了「现在那台机器上有没有」）；`t` / `u` 在 tools / usage 两块 pane 之间切。底部常驻句按 tab 有没有 session 分两种：有 → `changes apply to the NEXT session — this one froze its tools at start`；draft → `changes apply to the session this tab is about to start`。第四块 pane：全部 tool 的 usage 表（只投影 `.nulya/tool-usage.jsonl`；**不**复刻排序算法，"下一场谁晋升"留给未来的 `nulya composition preview` CLI，见 §10）。

### 5.4 `/sessions`（overlay，`F3`）

`nulya session list --json` 按 `created` 倒序，**一行就是那一场的第一句话**（T47）：第一条 user_text（拿走这一行剩下的全部宽度；一句都没说过的场自己写 `nothing said yet`） · `parent` 缩进成树 · 是不是眼前这个 tab（`▎ this tab`） · 最新 verdict（`+ success` / `~ partial` / `! failure`；**没有行就什么都不画**——unjudged 不是 failure）· 有别的写者持锁 → `● live` · **最右一列是多久以前**（`just now` / `12m ago` / `3h ago` / `2d ago`，一周以上退回 `MM-DD`）。`n` 新建（列表顶上还有一行可点的 `+ new tab`，与列表里每一行同一套视觉语言）；`r` 刷新；**`d` 无**——这个屏幕不删 session。清理是人在终端做的事（`nulya session prune <id> [--force]`，DESIGN §14）；前端只对**自己创建又什么都没说过**的那一场调它（`state/tabs.ts` 的 `release`）。**`/sessions <id>`（`/resume <id>` 是它的另一个名字）是同一个动作的点名形态**（T45）：走的是 `Enter` 那一个动作，屏幕里第一次有办法按 id 找回一场（在此之前只能带 `--session` 重开进程）；裸的那个不长第二张表，就是这一张。

**一次点击就地切过去，两次才多开一个 tab**（T70）。`Enter` / 单击 = **当前这个 tab 变成那一场**（已经有 tab 的前置它，否则 `tabs.replace` 就地换掉——**tab 条不因此变长**）；`t` / 双击 = 额外给它一个 tab。终端没有原生双击，只有两次松开和一口钟（`double_click_ms = 350`），所以**单击的动作要等窗口关掉才发**：先切再补的写法在这儿不成立——切换**吃掉的正是**第二次按键想保住的那个 tab（切完之后这一场已经在眼前，`onOpenTab` 只会把它选中一次），要让这一对有意义就得把刚替换掉的东西放回去，而 draft tab 根本放不回去、session tab 要付一次 `session events` 重放。不等的那一半是**光标**：它落在按下那一刻，所以点击在同一帧就有回应。窗口内的第三次按下开一个新窗口而不是再触发一次（连点的人是还没看见任何事发生的人，一次一个 tab 是对这件事最没用的读法）。

**默认不显示 sub-agent 的场**（T70）。判据是**冻结 header 的 inline prompt `source` 带 `agent-` 前缀**（`personaOf`，`agents.ts`——`wearing()` 读的同一条约定，前端只有这一份实现）：委派出的子场是真 session、`session list` 投影它是对的，但它不是谁开的对话、也不该从这儿给它发消息，而一个会委派的 workspace 里它们数量是真对话的几倍。整屏那个的键行末尾加一句 `N agent sessions hidden · a shows`，`a` 开关；显示时这些行戴 `◈ <persona>`（rail 上只戴字形——18 列里名字要从句子上割）。**过滤发生在建树之前**（`partitionSessions` → `sessionRows`）：被藏起来的父亲不会把孩子留成一层没有上级的缩进。这是投影层的 policy，**内核零改动**，`/sessions <id>` 与 `session list` 一个都没少。
**一行上只剩「说了什么」与「多久以前」**：这张表回答的只有一个问题——「刚才那场是哪一个」，而 id、事件数、model、`with` 没有一样答得了它；一个 workspace 里几乎每一行的 model 与 `with` 还都一样，**分不开任何东西的列不是信息**（§4.5 那条「没有的东西不占列」的同一把尺子）。删的都是**这一处的显示**、不是任何事实：composition 冻在 header 里、花费在 `/usage` 与 ledger 里一分不少。**一条事件都没有的 session 整行不列**（`sessionKind` 一处判据：`own` / `delegated` / `empty`）——那是进程被杀在清理之前留下的空壳，打开它是一屏空白；它没有键可以翻出来（那个键会掀开一批什么都没有的行），只被**数出来**（键行末尾一句 `N empty sessions not listed`）。**有 parent 的 0 事件 continuation 例外**：那是刚 fork 出来、summary 还在 inbox 里的一场，它必须找得到。
**id 不在行里，印在标题行上**（T47）：它是这张表里唯一一样人读不出、却偶尔必须粘贴的东西（`nulya session events <id>` / `/outcome` / 发给别人），所以只印**光标那一行**的那一个，跟着 `j`/`k` 走。它挨着 `sessions · N` 而不是靠右边距：id 的 hash 不定长，右对齐等于光标每动一下整行跟着动（T12 那个尾空格 bug 的同一个形状，往上挪了一行）。
**时间改成「多久以前」，并画在整行最右**（T47）：`08-16 09:12` 是个时间戳——正确，而读的人还得拿它减一次今天，才能得到他唯一想要的那个答案；一周以内说距离，超过一周距离不再好记，退回 `MM-DD`。画在 chip **后面**是为了让它真的是一列：chip 时有时无，一个会被 chip 挤得左右移动的钟不是列。列宽取当屏所有行里最宽的那个（`just now` 与 `3d ago` 不一样长，写死一个数字迟早对不上）。
**按 workspace 分组**（§5.11）：屏幕上开着的每个目录各跑一次 `session list --json`，front tab 那组在前；**只有第二个 workspace 出现时才有组头**，单 workspace 的屏幕逐位不变。组头画得出但停不上去（`Enter` 在它身上没有事可做）。

列表本身一次进程 + 读全部 session 文件，所以 8s 刷一次；`● live` 只是锁探针（不开进程），1.5s 刷一次。
**同一张表还有第二种呈现：docked 变体**（T69）——`/sidebar` / `F8` / 状态行的 `◧` 把它停在屏幕左边缘的一个 pane 里（缺省宽度 1/4，`/sidebar <percent>` 改）。同一个组件、同一批 rows、同一个光标、同一条点击的法条（T70 起：单击就地切、双击多开一个）；变的只有宽度，以及**宽度决定一行上还剩什么**（`sidebarRowPlan`：钟 → verdict → `● live` → `◈ 这是委派出去的` → `▎ 就是这一个`，按这个顺序让位，第一句话永远留得下 8 格）。它底下那一行也是按宽度选出来的（`railFooter`：候选串由长到短、第一个装得下的胜出；键只在它拿着键盘时才是真的，**被藏起来的行数两种情况都要说**——少一个键在 `/sessions` 与 `/help` 里都还找得到，一张悄悄比 store 短的列表没有第二个地方能说自己短）。它**不**替代整屏那一个：整屏是键盘的读法，rail 是鼠标与余光的读法。刷新更慢（列表 20s、锁探针 3s——overlay 只在有人看的时候在，rail 整天都在），但前面那个 tab 一换就立刻重读。

### 5.5 Sub-agent

**委派从属于开它的那场对话，所以它的观察面是父 tab 里的一块 pane，不是 tab 条上的兄弟**（T72，`goals/tui-shell.md` §5.3c）。

- SubSessionCard（§5.2）上那一行 **`↗ watch here`** 是**默认路线**：在**当前 tab 内部**开一块 sub-agent pane（≥100 列左右分、窄屏上下分，子面 0.4），browse 模式 `Enter` 同语义。**显式开成 tab 仍在**：browse 模式的 `t`——与 `/sessions` 里「`Enter` 就地切换 / `t` 给它一个 tab」同一套词（T70）。卡上不放第二条链接：一张卡为同一个去处挂两条几乎同文的行，每个委派都要付。
- pane = **现有 observer transcript**（§5.6）：只读跟随、`claimsKeyboard: true`（聚焦才拿键盘，开出来不拿）、`<id>.lock` 探针与 `SessionBusy` 语义一概不变，workspace 用**父 tab 的**（委派出去的子场就在那个目录里）。
- **归属写在头一行**：`⤷ <persona> · <这次委派的任务头一行> · observing`（dim；persona 从子场冻结 header 的 `agent-*` prompt 经 `personaOf` 读出来——与列表过滤同一处实现；任务摘录与委派卡头行共用 `registry.agentTaskExcerptOf`，两处不会各说各话）。**编号不写在人读的那一行上**：`d-…` / `s-…` / 任务全名 `<sid>/tN` 仍在 `ToolPresentation` 上，因为驱动侧要靠它们把一次调用连回它的对话。`observing` 是**常量**，说的是这块 pane（没有输入框、什么都送不出去），不是那一刻的租约角色。
- **分界是一条单边 hairline**：row split 画在子面左缘、column split 画在它上缘，`ascii` 有逐位降级。侧边栏那条「两个 pane 之间不画线」（T69）说的是两个**互相独立的地方**，这条说的是**从属**——它不是框（一条边不是四条边，整屏仍只有输入框一个有边框的东西）。
- **关闭**：聚焦时 `Esc`、头行右端的 `✕`（与 tab 条同一个词），或者关掉父 tab——`state/tabs.ts` 的 `release` 顺手把它的 follower 一起停掉，因为它本来就没有第二个存在的地方。
- `/sessions` 树用 `parent`；SubSessionCard 的链接是 transcript 推导（D7）；**子场不进 sessions 列表**（T70），父 tab 里的这块 pane 就是它唯一的呈现处。
- 不做：父子之间的消息转发、trace 视图嵌套折叠、pane→tab 提升手势——等真实使用证据。

### 5.6 Driver / observer 两种角色

- **driver**（默认）：TUI 自己 spawn `step --stream`；`.lock` 由 step 子进程持有。
- **observer**：`<id>.lock` 被别的进程独占（PLAN §3.6 的 driver 脚本、或另一个 TUI、或父 session 的 shell）→ 不 spawn step，只 `events --follow`（`--since` 续接）+ `append`（queued，等对方的下一 step 边界）。状态栏 `observer · driven elsewhere`。锁看上去持续空闲后弹一行 `press ↵ to take over`（手动，不自动抢）。
- **角色靠两个信号判定，都不是猜**：①`<id>.lock` 探针（idle 时轮询，且必须**无副作用**——去"试着拿一下锁"的探法在持锁瞬间会把真 writer 的非阻塞 `flock` 挤成假 `SessionBusy`，不算探针。Windows 上内核的租约是字节区间锁，读第 0 字节即可探到；Linux 上同一租约是 `flock(2)`，读不到但内核在 `/proc/locks` 里公示，按锁文件的 dev:inode 查表即可；两者都没有的 POSIX（macOS）→ 探针诚实地答 `unknown`）；②内核自己的 `SessionBusy`——我们真去 step 时被拒，这一条在所有平台都权威。所以角色是**持续**跟着世界变的，不只是"打开时判一次"。
- observer 看不到 deltas（deltas 只在 driver 的 stdout）：v1 接受 step 粒度；真正需要时的路径是 kernel 把流也写进 `<id>.live` sidecar，TUI 换 tail 源（`nulya/cli.ts` 内部一处改）。

### 5.7 权限 mode：谁在批准每个 tool call `[T24]`

**内核只有一个语义**（DESIGN §4 / §14）：`nulya session step --gate --stream` 在每个 tool call 执行前打一行 `{"stream":"gate","event":"request",…}`、阻塞读 stdin 一行 `allow` / `deny` / `deny <note>`；deny 就是那个 call 的 `tool_results`（没跑、什么都没变），note 模型看得见。**该不该问是 driver 的 policy**，所以整套判断住在 `tui/src/approvals.ts` 这一个纯函数里。

- **TUI 永远以 `--gate --stream` spawn step**（`nulya/cli.ts` 的 `sessionStep({gate})`：给了 gate 才加 `--gate` 与 `stdin: "pipe"`，gate 请求行**不进** `lines()`——它是这一层与内核之间的机械，屏幕经 callback 知道这件事）。mode 不下传内核、也没法下传：内核那一头没有"模式"这个概念。于是**切换即时生效**——每个请求都是一次新的 `approve(request)` 调用，mid-batch 切 mode 自然作用于下一个请求，而屏幕上正等着的那张卡片会**立刻按新 mode 重裁**（切到 `unsafe` 却让卡片继续等，看起来就是键坏了）。
- **两档**：`ask`（默认）= 规则没管的每个 call 都停下来问；`unsafe` = 直接跑。**为什么叫 `unsafe` 而不是 `auto`**（T31）：tcode 的 `Auto` 是 classifier 审核，这一档没有任何审核，它就是 tcode 的 `Unsafe`；叫 `auto` 是在承诺一个这里根本不做的判断。存储优先级 **`tui-state.json` 的 `mode`（程序写，记住上次选择）> `tui.toml` `[driver] mode` > `"ask"`**（与 `/model` 的选择同一条纪律：人在屏幕上做的选择由程序记，`tui.toml` 只有人写）；外面来的词里的 `auto` 由 `approvals.normalizeMode` **一处**读成 `unsafe`，写回时写新名。
- **入口是一个 picker，不是 toggle**（T31，`ui/ModePicker.tsx`，参考 tcode `mode_picker.rs`）。状态栏**行首**可点的 chip（T35 之前在最右；`unsafe` 是 warn 色——"没人看着就跑"不该是安静的那一格）与**裸 `/mode`** 都开它；`/mode ask|unsafe` 仍然直接切。它是**输入框上面的一个对话框**，与审批对话框同一套样子（标题、`rowGutter` 的光标/悬停、一行一个答案、悬停即移光标、点一下即作答）与同一套键盘归属（在的时候拿键盘，`Ctrl+C` 除外）；一行一个 mode + 一句说明 + `✓` 当前 + 底下一行 hint，`↑↓`/数字键移动（**夹住不回绕**：两行的回绕会让 ↑ 与 ↓ 变成同一个键）、`Enter`/单击选、`Esc` 收。它排在审批对话框**前面**拿键盘——点 chip 正是"别再问我了"这个手势，最容易在有 call 等着的时候发生，选完当场重裁那个 call。**切换本身不再说话**：chip 就在那儿写着是哪一档，picker 刚刚才把两档都说过一遍，再往状态栏甩两句解释只会把 model / cost / activity 挤成一团（T35 起 notice 干脆盖住整行，所以"挤"这件事换了形状，但"切换不必说话"没变）。
- **决策序**（`approvals.decide`，四层，第一个说话的算数）：① `[approvals] deny` → 直接拒（**连 ask mode 都不弹卡片**；一个被规则拒的 call 从来没被问过，所以它也不可能进过 always 集合，这就是它排在 always 之前而不矛盾的理由）；② 本场 `always` 集合（卡片上按 `a` 记入，内存态、per-run——试一个工具不该在别人读的文件里留下东西；持久版本是 `[approvals] allow`）；③ `[approvals] ask` → 弹卡片（**连 unsafe mode 也弹**，这正是它自成一张表而不是"没写进 allow"的理由）；④ `[approvals] allow` → 放行；⑤ manifest 的 `readonly: true`（DESIGN §7.2.1，`[approvals] manifest_readonly = false` 可关）；⑥ **只读命令分类器**（T65，`readonlyshell.ts`：**只对 `shell`、只在 `ask` 档**——引号感知地把命令行按 `&&` `||` `|` `;` 换行拆成简单命令，每一段都命中封闭白名单才放行，命令替换 / 写向重定向 / wrapper / 解析不动的一切一票否决；`[approvals] readonly_commands` 可加程序名，但买不动任何一条否决。它排在人写的四张表之后正是因为那四张表必须压得过它，**而 readonly 天花板不用它**——那道天花板对 `shell` 一律拒，理由是没有 sandbox 就分不出 `cat foo` 与 `rm foo`）；⑦ mode 兜底。
- **条目两种形状**：tool（`ext:std/read` 稳定 id、或 `shell` / `read` 这样的名字）与 **shell 命令前缀**（`shell:git status`——前缀不是 glob，写的人不必学一套模式语言）。稳定 id 与 `readonly` 都**在 gate 请求行上**（`tool_id` / `readonly`，DESIGN §4）：这两样是内核在开场冻进 tool definition 的事实，从前这一侧要去翻本场冻结的 manifest 反推，现在 `approvals.ts` 一个 manifest 都不开（`[approvals] manifest_readonly` 这个键留着——它管的是**信不信**，不是从哪儿读）。`a` 记的 key 同理：普通 tool 记整个稳定 id，**`shell` 只记第一个词**（`shell:git`）——"always allow shell" 等于 "always allow everything"，而 `git` 与 `rm` 不因为同一个程序跑它们就是同一个权限。
- **它是一个对话框，不是一句 `[y/n]`**（T28 又一次推翻 T27 的形状）。`ApprovalPanel` 在输入框上面，**一行一个答案、可选、可点**：`↑↓` 或数字键移动光标、`Enter` 答出光标那一行、**鼠标悬停即移动光标、点一下即作答**（`ui/rows.ts` 的同一套 `rowBackground` / `rowGutter`，与所有列表同一种视觉语言）。答案本身按"影响范围从窄到宽"排：allow this call · allow the rest of this batch（只在批量 > 1 时）· always allow `<kind>` this session · allow everything from here on（= 切 `unsafe`，tcode 的 `set_mode` 选项）· deny。那张 tool 卡上留一行 `waiting for you — answer below`，说的是**哪一个** call。
- **`Tab` 在任意选项上写 note**（T28，tcode `approval.rs` 的 tab-annotation，这个前端的必备功能）：面板底下常驻一个 note 字段，**note 跟着被选中的那个答案走**——"可以，但下次用 ls" 与 "不行，因为…" 是同一个手势换一行光标，这正是 note 属于**对话框**而不属于某个"deny with a reason"专用键的理由。`Tab` 在列表与 note 之间切；**直接打字也进 note**（tcode 的规则：伸手去写字，就已经在写了），所以它从来不需要被发现；note 里的 `Esc` 先清空、再退回列表，列表上的 `Esc` = deny。
  - **note 的去向分两条，因为内核只有一条**：`deny <note>` 是 gate 自带的语义（进那个 call 的 marker 结果，DESIGN §4）；**allow 没有 note 通道，也不该有**——call 跑了，模型接下来读的是这个工具自己的输出，再长一个 payload 等于让内核决定一个人的话该落在转录的哪里（physics #8）。所以 allow 上的 note 走**所有话都走的那条路**：`session append`（`approvalnote.ts` 的 sentinel + 一次性 contract，与 `midtask.ts` 同一形状同一理由），下一个 step 边界排干 → 正好落在它所评论的那一批 `tool_results` 后面。卡片按 sentinel 折回人自己的话，badge 写 `note on <tool>`。
- **对话框在的时候它拿着键盘**（T28）：内核就停在这一个 call 上，屏幕上没有别的地方可打字——这正是"打字 = 写 note"能够成立的前提。代价是这几秒里 `/mode unsafe` 打不出来，所以它成了列表上的一个答案（上一条）。`Ctrl+C` 仍然穿过去（带 modifier 的键一律不拦）：杀掉这一步是不想回答时的另一条出路。
- **一批 call 的批量答复**（T27）：内核的 gate 天生是串行的（call N 只在 N-1 跑完之后才问，DESIGN §4），所以这里没有 tcode 那种"一个对话框审一整批"的位置；等价物是那一行 answer——**人看得见的那些 call**（整批都已经是屏幕上的卡片）一次答完。实现是把那批**尚未执行**的 `call_id` 记进一个集合，后续请求逐个消费；不是一个布尔，否则一次 run 里的**下一批**（还没人看过）会被它悄悄盖住。它排在 `[approvals] deny` 之后：一条"永不"不该被一次关于六个 call 的按键推翻。面板抬头写 `1 of 3 in this batch`，只有一个 call 时这两样都不出现。
- **等待中的请求是一个队列，不是一个槽**（T27）：这个进程可以同时 drive 多个 tab，两场 session 各停在一个 call 上是可能的；第二个请求覆盖第一个，会让那个 step 永远等一个没人能兑现的 promise、并一直攥着写者租约。状态栏活动区在等的时候只写 `waiting for your answer`（warn 色，压过其它所有活动——内核这会儿就停在这里）；键不在这一行重复，那正是它在窄屏上被挤成 `y allow · nasknstep` 的原因。
- **这不是安全边界**（DESIGN §9）：extension 与 shell 同权，`readonly` 是包的主张不是强制。它管的是"这一次要不要发生"，真隔离等 sandbox（PLAN §3.8）。

### 5.8 模型自己提的 handoff `[T24 · compact plugin 迁移]`

`extensions/handoff` 的 tool 只校验 `done` / `next_task` / `keep`（`drop` 可选）并返回；调用参数本身就是冻在 ledger 里的 durable 阶段结束信号。它不 fork、不写第二份 handoff 文件，也不持有任何 UI 状态。

TUI 的便利流程现在全部属于 `extensions/compact/tui/compact.ts`，宿主不再认识 compact / handoff 的包名、tool 名或 marker：

- compact package current 时，它的 plugin 注册 `/compact [focus]`、handoff preview panel、compact request/context summary user-turn renderer，以及 `/sessions` 的 summary title formatter；plugins 关闭或包加载失败时，ledger 原文照常可读，只是不再有这些便利 UI。
- host 给每条 event 明确的 `live | replay` 来源。plugin 只关联 **live assistant handoff call + 同 call id 的成功 tool result**；replay 永远不弹 panel、不 fork。call correlation 仍以 session + call id 隔离，但 actionable proposal 是 **每 session 一个槽**：同场更新的成功 handoff supersede 旧 handoff，跨场互不覆盖；进程内保存 `pending → running → done`，成功或明确 dismiss 才 done，临时失败回 pending 可重试，异步完成只在自己仍是该场最新 proposal 时更新。失败、deny、残缺参数都不形成 proposal。前台 session 改变时 host 通知 plugin；切回有 pending proposal 的 session 会重新打开 panel，切走则收起但不 dismiss，所以 pending handoff 始终有重新 follow / dismiss 的入口。
- handoff follow 服从当前 driver 的明确 permission mode：`ask` 显示 `Enter` follow / `Esc` dismiss 面板，`unsafe` 在 step 真正回到 idle 后自动 follow，让 TUI 与 goal driver 都能跨阶段持续运行。observer 可以看到 proposal，但执行前仍因 `SessionView.role` 被明确拒绝，不能抢 writer lease；同一 session 在 observer / driver 之间转换也属于 `onSession` 通知，host 不能只按 id + mode 去重，否则 unsafe auto-follow 会停在旧角色上。API 2.4 以可选 `SessionView.permissionMode` 投影这项只读政策；plugin 不能回答 gate或修改 mode。API 2.2 的 `activity` 继续保证 append/step 在途时绝不 fork。Enter 已提交 follow 后，Esc 只收起运行中面板，不取消已开始的 continuation；失败会恢复 pending 并重新呈现，旧 Promise 完成也不能改写 supersede 它的新 proposal。
- 手工 `/compact` 与 follow 共用一个 `run`：driver + idle 预检 → 调本包冻结版本的 internal `compact` tool（手工传 `focus`，handoff 传那次 assistant event 的 `brief_seq`）→ 解析 child → `openTab(child, {wakePending:true})`。父 tab 保留；child attachment 只在 inbox 确有 summary 时自动排干并继续，空 inbox 绝不裸 step。child composition 卡常驻一行可点击 parent lineage，`/sessions` 也保留尚为 0 event 的 continuation；父 ledger 不复制。
- `extensions/plan` 的 approve 不再调用宿主专用 compact 动词，而是经通用 `extRunPackage("compact", "compact", {session, brief_file})` 后 `openTab(child, {wakePending:true})`。compact 缺失、未 current、未 build 或 workspace store 未信任时，review panel 和已写 brief 都保留。

宿主因此只保留通用原语：插件注册/回滚与异常隔离、事件 provenance、只读 session role/status/permissionMode、同包 `extRun`、跨包 internal-tool `extRunPackage`、`openTab(..., {wakePending})`、以及 user-turn renderer/title registry。marker 渲染、follow policy 与 fork 结果协议都由 package 自己版本化。

### 5.9 后台任务：内核给 supervisor 与事件，屏幕决定何时再 step `[T29]`

内核那一半已经全在（DESIGN §6.1 / §3.1）：`shell {background:true}` 起一个脱离 step 进程的命令并立刻回执，supervisor 看着它跑，结束时把 `note{source:"task", meta:{task, exit_code}}` **投进这场 session 的 inbox**，下一个 step 边界排干、进 ledger、模型读到。少的只有一件事——**谁来开那一步**。何时继续从来是 driver 的 policy（physics #8，goals/background.md D8），所以这块屏幕补的就是这一条：

- **唤醒判据是四个词：driver 角色 + 这场是本进程驱动过的 + `status() === "idle"` + `<id>.inbox/` 非空**（`state/driver.ts` 的 `wake()`，唯一的新 policy；"驱动过"= 本进程 `session new` 出来的，或从这个 tab 发过消息 / step 过 / `↵` 接管过——`attach.ts` 的 `driven`）。四点都承重：
  - **"驱动过"挡的是一个窄而后果重的窗口**：一个刚打开的 tab（SubSessionCard 的 `Enter`、`/sessions`）角色缺省是 driver，第一次探针之前它分不清"没人驱动"与"别人正好在两个 step 之间"——而 inbox 非空恰恰发生在那个别人的 `task wait --any` 刚返回、还没来得及 `session step` 的一瞬，我们抢先一步，它的下一步就是 `SessionBusy`，一个 driver 脚本会就此退出。所以没人要求的那一步只在**我们已经是它的驱动者**的 session 上发生；打开一场旧 session 只看不说，第一条消息才把它变成我们的（`tasks.test.ts` 两条钉住）。
  - 判据是**inbox**，不是"某个任务 done 了"。任务结束只是让 inbox 非空的来源之一，别的终端 `session append`、`ext activate` 的 capability note 都算；反过来，**inbox 为空时绝不裸 step**——那会把上一条 assistant turn 当 prefill 重发（DESIGN §4），不是"继续"，是关于谁最后说话的谎。
  - 轮询搭 `probeWriterLease` 那个 idle 定时器的车（`state/attach.ts`，默认 700 ms），**不另起第二个**：它本来就是"我们坐着不动的时候世界干了什么"的那一拍，而多一个定时器只是多一个要停的东西。
  - **observer 不踢**（角色判断留在 `attach.ts`，`driver.ts` 只回答"inbox 里有没有东西"）：那个 inbox 由持锁的写者在它自己的下一个 step 边界排干，两个写者正是 durable session 唯一拒绝的事（DESIGN §3.4）。
  - **`ask` 模式照踢**：模型只是去读一个结果，它接下来每一个 tool call 仍然逐个过 gate（§5.7）。
- **`nulya task list --session <id> --json` 是任务面的唯一数据源**（`state/tasks.ts` 一个 per-tab 的 watch：tab 打开读一次、每个 step 结束读一次、有没 done 的任务时每 1.5 s 读一次；一个从没起过任务的 session 只付开场那一次）。`starting` / `lost` / `unreachable` / `elapsed_s` 全是内核算好的投影，TUI **不复刻**——它们要同时读任务目录与那把锁，第二份实现迟早跟唯一算数的那份说两样话。**远端任务**（`machine` 那一列非空）：`unreachable` 算"不再等"（问不到那台机器，轮询也学不到新东西，而每一次问都是一条短通道），但它**不是** `done`——任务多半还在那边好好跑着，所以两处文案各说各的；它的 log 在那台机器上，面板改说一句 `the log lives on <spec>` 而不是拿本机 io 去读一条别的机器上的路径。
- **两张卡**（§4.2）：ShellCard 的后台变体（同一个 `$`，note 换成 `background <sid>/t3 · running 12s`）与任务报告 note 的 TaskFinishedCard（`$ 命令 (background <sid>/t3 · exit 1 · 41.8s)`，体是输出 tail + 尾行 `full log → …`）。两者靠**全名** `<sid>/t<N>` 连起来：回执首行写了它，事件里又写了一遍，所以 `session.ts` 排干那条事件时按名字找回发起它的那张卡并记下 exit 与耗时——**重开一场也照样显示**，不靠任何进程。"还在跑几秒了"这种没法 append 的事实才走 live 投影（`TasksContext`）。
- **状态栏**：有没 done 的任务就在活动区写 `⠋ 2 background`，**driver idle 时也写**——任务活得过 step，一条正在跑的命令是那一刻唯一还在发生的事，说"idle"才是假话。它与其余每一段**并存**（自己一段、自己的点击区，裁剪时最先被挤掉，§4.4b）；**点它开的是输入框上面的任务面板**（`TasksPanel`：每个还在跑的任务一行 + 一个可点的 stop，只用鼠标、不进 `resolveFocus`、不抢键盘，`Esc` 收起排在 `handleGlobalCancel` 最前），全屏那张表仍是 `/tasks`（F7）。停一个任务与 `/tasks` 的 `k`/`K` 走**同一个** `state/tasks.stopTask`：`nulya task kill` 之后追加一条 `<task-stopped>` sentinel，好让模型知道是人停的（内核的 `· killed` 分不出是谁）。
- **`/tasks`（F7）**：一行一个 `<sid>/t<N> · state · 用时 · 命令 · 怎么结束的`；`Enter` 看 log 的最后 64 KB（跟着面板的 1.5 s 轮询重读，**不求真·live tail**——那要一个常驻进程，而人想知道的"它现在在干什么"重读就够）；`k` kill（不二次确认：杀错了重跑一次就行，杀不掉的任务才是没有 undo 的那个），`K` 杀掉所有还在跑的；`r` 重读。**这是全前端唯一 `j/k` 不是移动的列表**——`k` 在这里是 kill(1) 那个动词，光标只认方向键，footer 写明白；一个键在五个面板里移动光标、在第六个面板里毁东西，是两种不一致里更糟的那种。
- **`/quit` 不杀**：有还在跑的任务就先说一句 `N background tasks keep running; their results land in the session inbox`，再 `/quit` 一次才走。离开这个前端不该停掉一个 detached 的进程（内核里也根本没有"session 结束"这个概念）；结果会在 inbox 里等下一个 step。要停就去 `/tasks` 按 `K`。
- **不做**：跨 tab 的任务汇总视图（`/tasks` 只看当前 tab 的 session，整个 workspace 的答案是终端里的 `nulya task list`）；后台输出实时进 transcript（log 文件 + `/tasks` 就是观察面）；任何"自动清理"或退出时杀任务。

### 5.10 Sub-agent：一个定义文件，就是一组 `session new` 参数 `[T32]`

PLAN §3.2 早就把答案写死了——**一个 agent 就是 `session new` 的一组参数**，`AgentDef` 不进 kernel。所以这一块从头到尾没有一样新东西是内核给的：定义是一个 markdown 文件，正文渲染成一个 prompt 文件、`--prompt` 冻进 header（**T44**；从前是材料化成 data extension 再 `--with`），`--with` 给 composition 与工具面，`--max-steps` 给预算，readonly 由 gate 兜住。

- **定义在哪**：`.nulya/agents/*.md`（workspace）与 `~/.nulya/agents/*.md`（`NULYA_HOME` 整体搬走，与内核 config 同规则）。**只认一层平铺、只认 `.md`**——`agents/` 是一列 persona，不是要组织的树；同名 workspace 胜出，输的那个**点名报出来**而不是静悄悄丢掉（"我在改的是哪一个"必须答得出来）。坏定义 **warn-and-skip 不致命**（tcode 同款纪律）：只有"没有 front matter"与"没有正文"两种情况会被跳过（那正是"不是一个定义"的两种含义），其余每一条读不动的字段都是一条警告 + 一个缺省——为一行坏字段丢掉整个 persona 是贵的那个答案。
- **front matter 的每个字段都是 `session new` 的一个参数**：`name`（缺省 = 文件名 stem）· `description`（picker 里那一行）· **`permissions: readonly | default | unsafe`**（三档权限阶梯，见下；旧的 `readonly:` 是被拒的词，整个定义会被 skip——一个跑在没点名的档上的 persona 比不存在更糟）· `runner`（这条委派由哪个 harness 驱动，缺省 `nulya`；非 nulya 的 runner 在这个前端里只列得出来、`/agent` 起不动——一个 tab 就是人肉驱动的 nulya runner，别的 harness 没有可 step 的本地 session）· `agents: [name, …]`（它可以委派给谁，空 = leaf）· `max_exchanges` · `model`（`profile` 或 `profile/model-id` → `--profile` / `--model`；不写就继承发起它的那个 tab 的模型——一个不在乎跑在哪的 persona 不该把活悄悄挪到内核缺省上）· `with`（`<id>[@<version>][:<tool>,…]` 数组，逐个 `--with`；**形状不对的一律丢掉并警告**，因为一个解不出来的成员不是少一个工具，是整场 `session new` 被拒）· `max_steps`（该 tab 的 `session step --max-steps`）。**正文就是 system prompt，逐字**。
- **渲染 `[T44]`**：定义正文写成 `.nulya/scratch/agents/agent-<name>.md`，`session new --prompt <它>` 把**字节**冻进那一场的 header（DESIGN §3.4 / §5.6）。**什么都不安装**：没有包、没有版本、`/ext` 里不多一行，`ext prune` 也拿不走某一场赖以 resume 的身份文本。**每次都写**（`/evolve` 同款理由）：内容由定义决定，没改就是同样的字节，改了下一次 `/agent` 自动拿到新的，没人需要记得重 build；两次委派同时写也无害。落 `.nulya/scratch/agents/`，**刻意不在 store 也不在 workspace 的 draft 目录里**——它是隔壁那个真正被维护的文件的一次渲染，不是有人在维护的包。**从前它是 data extension**（id `agent-<name>`、`--with` 戴上、永不 activate）：那把一段 per-session 文本做成了安装物，`/ext` 里长出一排派生包，而 `ext prune` 能删掉某一场的身份文本。`agent-` 这个前缀留下来了，但它现在**只是那个包自己的写/读约定**（`render` 写这个文件名、`wornPersona` 从 header 的 `composition.prompts[].source` 剥它），内核对这个标签一无所知。
- **trust 问句**（`main.tsx` `askAboutCheckout`，与同一次开屏的 store 问句共享同一时刻、同一"只问一次"纪律——两边都要问时 `extensions.planCheckout` 把它们合成**一句**而不是两句先后问，T50，ext-review-2 §3b）：随 checkout 到达的 `.nulya/agents/*.md` 要答一次才能用。**理由**：一个定义就是一段 system prompt，用它 = 让别人写的 persona 拿着本 workspace 的工具说话。单独问时两个键（`t` 信任 / `n` 现在不），问在屏幕出现之前；与 draft 问句合成一句时借用它的三键形状（`i` 装扩展并信任定义 / `s` 只 build 扩展、什么都不信任 / `n` 都不动）。答案记在 `tui-state.json` 的 `asked_agents` / `trusted_agents`，与从前一样——合并的只是屏幕上问的那一下，不是记录的地方。`~/.nulya/agents` 永不问（与 user store 同理由：没有人放，它不会自己到那儿）。
- **`/agent <name> <task…>`**：**先开一张看得见的新 tab**（继承当前 workspace 与模型，状态行写 `loading its definition…`），再渲染 →（`session new --prompt <渲染出的文件> [--with]* [--profile/--model]`）→ append task → TUI 照常以 driver 驱动（`--gate --stream`，`max_steps` 生效）。先开 tab 是因为三次 spawn 之后才有反应看起来就像 Enter 没生效；未知名字 / 非 nulya runner / 不受信的 workspace 只收回这张什么都没碰过的草稿并回到原 tab，不留下假任务。**目录在建出 draft 的下一行就定住**（`agentPackage(where)` / `agentsIn(where)` 的 workspace 是必填参数）：这中间是一整趟 toolchain run，足够一个人切到另一个 checkout，而"哪个目录"绝不能是一个可读的当前状态。看得见是有意的：一个跑歪了的委派，得有人能看、能 `Esc`、事后能读。**裸 `/agent` 是 picker**（`ui/AgentPicker.tsx`，与 `/mode` `/model` 同一套对话框：`◈` 标题、`ui/rows.ts` 的光标与悬停、数字键、`Enter`、`Esc`，在的时候拿键盘）——**选中一行不启动任何东西**，只把 `/agent <name> ` 写进输入框：委派需要一个任务，而任务没人猜得出来，一个替人编了任务就开场的 picker 是前端往别人嘴里塞话。
- **`permissions: readonly` 是一道天花板，不是一条规则**（agents-and-review §1 不变式 1）：它在**三张表之前**问，且任何东西都掀不动它——一条 `[approvals] allow` 悄悄把 `shell` 放回一个 read-only persona，就是这个功能唯一会变成谎话的形状。两条：`shell` 一律拒（没有 OS sandbox 就分不出 `cat foo` 与 `rm foo`，同 §1 不变式 5）；extension tool 只放行**自己的冻结 manifest 声明了 `"readonly": true`** 的（DESIGN §7.2.1 那个声明是包的自述、内核不强制，**信不信是这条 policy 的选择**，`[approvals] manifest_readonly = false` 是不想信的人说话的地方）。拒绝走内核 gate 的 `deny <note>`，所以**模型读得到自己为什么什么都没跑**，而且那是那个 call 的 `tool_results`，在 ledger 里（DESIGN §4）。**这不是安全边界**，和 §5.7 最后一句是同一句话：真隔离等 sandbox（PLAN §3.8）。
- **模型自己委派：`agent{name|session, task, model?, interrupt?, permissions?}`，回报走后台任务**（`session` 形态收的是一个 **delegation id `d-…`**：往一条已经报告过的委派再送一轮，append-only 命中它自己的前缀缓存；能不能委派由被委派者定义里的 `agents` 白名单决定，空 = leaf。每一道门与理由都在 DESIGN §7.8 与 `extensions/agent`，前端一条都不复刻）。这一半**前端零新机制**：`agent{name, task}` 起一个**属于父场**的后台任务去驱动子场，任务结束时 supervisor 把报告 note 投进父场 inbox——而"driver 角色 + idle + inbox 非空 → 再 step"（§5.9 T29 唯一那条 policy）本来就在跑，所以报告自己会到，**没有第二个看盘的钩子、没有新的面板、`drivers/goal.*` 一个字没改**。第一版规格是"写请求文件 + 每步之后看盘"，否掉的理由是它等于给每个 driver 发明一份要重学的盘面约定（且跨平台两份实现），而内核已经有且只有一个"欠答案"的回路。
  - **怎么被带进来**：`--with agent@<v>`，**不带工具选择**——那个 tool 是 `surface: "auto"`，成员即上台。带哪些包由 `tui.toml` 的 `[extensions] session_with`（缺省 `["handoff", "agent"]`）说，不由这个前端按 workspace 里有没有定义现猜——包自带四个 persona，所以「有定义才带」恒真。**能不能再往下委派不在这条 argv 上**：它是被委派者定义里的 `agents` 白名单，由 `extensions/agent` 自己读（一个字段一处读取，不能委派的子场根本没有这个 tool）。
  - **渲染只有一处实现**：`ext run agent@<v> render --arg name=<n>`，它写文件并回一整组 `session new` 参数。TUI 的 `/agent` 也调它——两份实现就是同一个 persona 的两种读法；TS 侧只留**读**（发现、列表、picker）。
  - **卡片**：`agent` 这个 tool call 在 registry 里是一张 **`SubSessionCard`**，头行说的是**派了谁、在干什么**（`agent · explore · find the writers`）而不是它的编号；note 与后台 `shell` 同一套读法（`running 42s` → 报告到了变成 `· exit 0 · 41.8s`），头行下面一行 **`↗ watch here`** 点得动——与 browse 模式 `Enter` 走同一个入口（`state/navigate.ts`，§5.5）。id（`d-…` / 子 session id）取自**回执**而不是参数：调用返回前那场 session 还不存在。
  - **没有 600 s 天花板**：`ext run` 缺省不套 timeout，而委派那条后台命令永远不上模型面，所以 manifest 的 `timeout_ms` 也管不到它——一次委派想跑多久跑多久。
- **定义分三层，什么都不写也有三个能用的**（DESIGN §7.8）：`.nulya/agents/*.md`（workspace）> `~/.nulya/agents/*.md`（user）> **包自带的 `explore` / `plan` / `general` / `orchestrator`**（`extensions/agent/src/builtin/*.md`，`@embedFile` 进那个包的二进制，随它一起分发）。**首个持有者胜，输的那个照样列出来并标 `shadowed`**——与 extension 的两层指针同一条规则、同一个理由。四个 persona 移植自 tcode，`ask_user` 与 tcode 那些我们没有的 frontmatter 是**删掉**而不是翻译；`orchestrator` 是唯一带 `agents` 白名单（可以委派）的那个，其余三个都是 leaf。
- **读也只有一处实现**：`ext run agent@<v> list` 返回全部定义（name / description / readonly（由 `permissions` 派生的那一列）/ runner / layer / shadowed / with / max_steps / warnings）。TUI 的 picker、readonly 天花板、委派参数**全部读它**——TS 侧一行 frontmatter 解析都没有。理由与写路径同款：两个 parser 就是"这个 agent 是不是 readonly"的两个答案，而那正是天花板要变成一次拒绝的那个问题。**唯一的例外是 trust 问句**：它问在屏幕出现之前、任何 build 之前，所以它读的是**文件名**（`workspaceAgentFiles`，一次 `readdir`），不是定义——"这个 clone 带来了定义吗"本来就是关于名字的问题。
- **成员直接传**：定义的 `with` 原样成为 `session new --with`，`render` 不预验证它们。包没有 `current` 时是内核的 `session new` 在 stderr 点名并给出 `--with <id>@<v>` / `ext activate` 两条出路；TS 侧只是把那句原样转述。两条委派路径（模型的 `agent` tool 与 `/agent`）因此都没有自己的一份"包装好了没有"判断。
- **`◈ agent-<name>` 白拿**：戴着的东西在 tab 标题与状态栏那个 chip 上本来就看得见（T31 的机制），不需要为 sub-agent 加第二套显示。T44 之后 `wearing()` 多读一处——header 冻的 `composition.prompts[].source`——因为按同一把尺子，那也是这一场戴着的一段 system prompt，只是它不属于任何包。

### 5.11 每个 tab 一个 workspace，与它跑在哪台机器上

跨目录的对话（goals/tui-shell.md §5.3b）。**内核零改动**——session 本来就属于它被创建的那个目录，`Workspace` 一直是 `nulya/cli.ts` 每个调用的显式参数，S1c 只是把它从 store 级下放到 tab 级。

- **tab = (workspace, session)**：`TabCommon.ws`。session tab 的目录永不改变（它的文件在那儿）；draft 可以被重新指向，`TabStore.retarget` 就是浏览器按的那个动词——它换掉整个 tab 对象而不是改一个字段，因为 `ws` 是通过 `tabs.active()` 到处被读的。
- **`/cwd`**：裸的开目录浏览器（整屏 overlay `host:cwd`，§6.5 的第一类骨架 —— 它是个**地方**所以标题不带 glyph，列表可能超屏所以是 scrollbox）；带参数直接选定，是「拿一行」的点名形态（与 `/resume <id>` 之于 `Enter` 同一条先例）。三个入口：`/cwd` · 空状态那一行 `cwd`（可点）· 状态行上的 workspace chip（只在它说得出新东西时存在）。
- **浏览器只有一个动词**：`Enter` 永远拿光标那一行——目录行是**进去**，`no project` / recent / `use this directory` 是**选定**。打字不需要第二个确认手势，因为**打字把光标放到 `use this directory` 上**：「在输入框按 Enter」和「在一行上按 Enter」于是是同一次击键做同一件事。路径框全程持有键盘（能粘贴路径是终端用户第一个要的东西），所以光标只认 `↑↓`——`j`/`k` 是路径里的字母。列表：`no project` 恒第一行 · recents 段 · `use this directory` · `..` 段首 + 子目录（只列目录、隐藏点目录、按名排序、含 `.nulya/` 的带 `▪`）。**不做**文件预览、多选、新建目录。
- **无项目 session**：家 workspace = `<NULYA_HOME | ~/.nulya>/home/`。**不是 `~` 本身**——`~/.nulya` 是 user 层，塌在一起会让 store 与工作区搅在一处。这一场跳过 `[extensions] session_prompts`：那些 renderer 画的是**项目**（布局、instruction 文件、这个分支、这棵工作树），而 `no project` 的答案正是「没有项目」，每一段都会是空话，而且它进的是缓存前缀、每一步都在付。侧边栏与 chip 上它叫 `no project`。
- **列表按 workspace 分组**：打开的 tab 的 workspace 全列，每组各跑一次 `session list --json`，当前 front tab 的组在前，组头 = 目录名 + 宽度够时的 dim 全路径（`min_path`，rail 上放不下就整个不画）。**只有第二个 workspace 出现时才有组头**（`groupedRows`）——单 workspace 的屏幕逐位等于 T70 结束时那一帧，快照钉住了这一点。光标只停在 session 行上（`nextSelectable`）：组头按 `Enter` 没有事可做。T70 的 persona 过滤每组照用。
- **信任与开屏流程按 workspace 首次进入时走**：launch workspace 仍由 `main.tsx` 在裸终端上问（那一刻还没有屏幕）；此后**第一个进入某个目录的 tab** 触发 `enterWorkspace` —— 同样的 `planProjectStore` / `planProjectAgents` / `planCheckout`，答案改在屏幕上给（`ui/CheckoutPrompt.tsx`，输入框上面的对话框，**trusted zone**，`resolveFocus` 里排在最外层：它是唯一一个**授权**而不是选择的对话框）。内核对一场 session 的硬拒照旧原样显示在那个 tab 里（`refusal`，T46）。
- **recents 在 user 层**：`<NULYA_HOME | ~/.nulya>/tui-recents.json`（§7）。**建场成功时才记**——浏览过不等于在那儿工作过，一个记下光标走过的地方的清单是点击史不是地点表。`no project` 不进 recents（它有恒定的第一行）。
- **持久与恢复**：`tui-state.json` 的 `tabs`（§7）。恢复**只做第一个之后的那些**：第一个 tab 仍由这一趟启动决定（`--session`，否则 draft，T22），所以单 tab 的屏幕逐帧不变；draft 不记（盘上什么都没有），文件已经不在的 session 跳过。

**`/env`：下一场的 shell 跑在哪**（`local` / `remote:wsl:<distro>` / `remote:ssh:<host>`，DESIGN §8.1/§8.2）。这条轴不是权限也不是 backend：`Dialect` 说命令用哪种语言写，`environment.backend` 说它被关得多紧，exec target 说**哪台机器的 shell 读它**——今天只有两点：`local`，或 `remote:` 一族（连工作区一起搬）。

- **前端只做三件事**：把选择放进 `session new --env`（落点是 `sessionExtras()`，与 `session_with` / `session_prompts` 同一处同一时刻）· 记住它（`tui-state.json` 的 `exec_env`——**内核没有对应的 config 键、也不该有**：给 `[environment]` 加一个默认值就要回答「这个目标比 `local` 更严还是更松」，而 config 链的收窄规则对这个问题没有诚实答案；记住一个选择是前端的事，给目标排序不是）· 用状态行上的 `⇥ <spec>` 说出来（非 local 才占列；已开场的读冻结 header，draft 读待定选择——`/env` 动不了已经开始的那一场）。**不校验拼写**：`session new` 已经会拒绝并带上整套词表，这边再写一个 parser 就是一个问题两个答案。
- **picker 列的是探测出来的东西**（`state/targets.ts`）：`local` 恒在 · Windows 上 `wsl.exe -l -q` 的每个发行版，产 `remote:wsl:<name>` 行 · `~/.ssh/config` 里非模式的 `Host`，产 `remote:ssh:<host>` 行（`Host *` 是一段缺省不是一台机器，`Include` 不跟——那正是最后一行存在的理由）。最后一行 `somewhere else…` **不是一个 target**，它把 `/env ` 写进输入框——一个 picker 最不该做的事就是暗示它列出来的就是全部。
- **remote 档要两次回答**：选机器只是一半，另一半是**那台机器上的哪个目录**（内核的 `--workspace` 是独立的一个 flag）。选中 `remote:` 行之后 `nulya remote check --env <spec> --json` 开一次真通道取 `home` 当起点，接上**同一个** `DirBrowser`（换的只是一个 `DirSource`：`list` / `exists` / `join` / `dirname` 四件事——远端永远用 posix 拼路径，Windows 宿主上 `node:path.join` 对一条要发给 Linux 的路径是错的字节）。check 失败就原样显示内核的话、**浏览器不开**——对一台连不上的机器展示「选个目录」只是同一个失败的第二次重复。spec 与 workspace **同一次调用成对写入、成对清空**（§7）。
- **remote 场里的工具面另配一份**（`tui.toml` 的 `[env.<kind>]`，§7）：缺省 `bare = true` + 空的 `with` / `session_prompts`——`std` 的 read/grep/glob 读的是**本地**盘、`ground` 渲染的是**本地**事实，把它们放到一场工作区在别处的 session 上只会制造 not-found 与假话。
- **包也要过去**：`/ext` 的 `r` = `ext push <id>@<v> --env <spec>`，只在这一场是 remote 时存在（§5.3）。

## 6. 视觉规范（设计语言）

**简约但精致——美来自对齐、克制与节奏，不来自装饰。**
终端里没有阴影、没有圆角、没有字号：能用来造出秩序的只有**位置、明度、空行、字形**四样，
所以每一样都必须被当成语法而不是品味来用。下面九条是法条，**新写的每一块屏幕都要逐条过一遍**；
后面四张表（明度与颜色角色 · glyph 词表 · 间距节奏 · 两类面的骨架）是这九条的可执行形式。
标了 T 号的是既有决定被收编进来的位置，不是新规矩。

### 6.1 九条

1. **颜色克制。** dim 是主力；**accent 只用于语义**——`accent.user`（人）· `accent.assistant`（模型的这一轮）·
   `accent.evolve`（演化动作、标题、可点的去处）· `ok/warn/err`（判决）· `◈` 的归属。
   **一屏同时出现的 accent ≤ 3 种**，没有纯装饰色。**成功是沉默的**（T26）：一次调用只说它带回来多少
   （`(121 lines)` / `(+2 -1)`），出事才说词（`exit 1` / `failed`，err 色）——每行写个 `ok` 只是噪音，
   而且把颜色用光了。**`NO_COLOR` 下必须依然可读**：凡是只靠颜色区分的两件事，都要另有一个**形状**上的区别
   （光标 `▾` / 指针 `·`、开关 `●` / `○`），这条否决权大于任何配色上的方便。
2. **对齐是第一美学。** 同屏的列必须**真的**对齐：宽度一律用 `displayWidth`（CJK 双宽、`⚡` 这类默认 emoji 宽度、
   组合字符都在 `ui/columns.ts` 里算过），**列宽从内容算**（`columnWidth` / `squeeze`），不写死数字。
   **数字右对齐**——`9 uses` / `1041 uses` 左对齐是四条参差的边，而人扫一列计数靠的是**末位数字**
   （`UsageTable`、`/usage` 的 token 块）。同类行的字段起始列一致：一个面里只允许**一个**左边缘（§6.5）。
   粗糙感十有八九出在这一条上，审计时逐屏先量它。
3. **留白是结构。** 空行是这一屏的语法，不是喘气：transcript 三档由 `Transcript.gapBefore` 一个纯函数说了算
   （T26/T43，§6.4），overlay 与 composer 对话框各有自己那一套骨架（§6.5）。
   **同一类面只允许一种密度**——两个 overlay 用两种节奏，是屏幕在说它们是两个产品。
4. **没有的东西不占列**（T35）。空值不画占位词（没花过钱不写 `no usage yet`、没跑过步不写 `step 0`、
   是写者不写 `driver`——**只有例外说自己**）；画不出内容的元素不占行（`thinking = hidden` 时它离开 item 列表，
   T43，否则前面那一行 `gapBefore` 的空白还留着）。空的 `<text>` **也占一列**，所以可能为空的段一律 `<Show>` 包住。
5. **边框词表最小化。** box-drawing 只在「归属需要被说出来」的时候用。**整屏只有一个有边框的东西：输入框**
   （T26，圆角，ascii 降级 `+-|`）——它同时是「在这里打字」的邀请与**键盘在不在这里**的唯一信号
   （有焦点 `accent.user`，browse / overlay 拿走键盘时退回 `hairline`），并**随内容长高**（1–8 行）。
   列表与页面**用缩进和留白分组，不画框线**；transcript 无边框，卡片体缩进 +2。全仓库只有这一种框风格。
6. **glyph 词表封闭**（表在 §6.3）。每个 glyph 在表里写明它唯一的语义；
   **一个 glyph 在同一块面（transcript / overlay / composer 区）里只允许一个意思**，跨面复用必须在表里把两处各写一句。
   新 glyph 必须**先进表**（这条硬约束从 T4 起就有）；同一语义不许两个 glyph
   （`▾ N more below` 与折叠记号曾经是同一个字形，现在是 `↓`）。`ascii = true` 有一份逐位对应的降级表。
7. **截断用 `…`，绝不换行挤压布局。** 一格放不下就 `fit` 到列宽（**从末尾切**，窄屏切的是头行、命令、路径，
   **不切状态词**——`exit 1` 正是窄屏上最该留下的那一格，T26），一句话由**我们**在 ` · ` 关节处折
   （`wrapWords`，一行一个 `<text>`）。理由不是整洁而是正确：`<text>` 只画自己字形落到的格子，
   空格底下留的是**上一帧**的字符，所以一个换行会变的行会**糊**（`ui/columns.ts` 顶上那段）。
   **数字格式统一**：一眼看的计数走 `compactCount`（`12.3k` / `1.2M`）；账面（`/usage`）写全数、右对齐；
   **时长只有一种写法**（`state/tasks.seconds`：`41s` / `2m 05s`），`WorkingStatus` 与 `/tasks` 与后台卡共用它，
   唯一的例外是内核自己报出来的 `41.8s`——那是**引用**，不重排。
8. **每屏一行 dim 的「我能做什么」。** overlay 用 `overlays/Footer.tsx`（常驻两三个重点 + `? keys`，
   `?` 展开其余；没有更多键的面板不写 `? keys`，T18）；composer 区的对话框用 `ui/Dialog.tsx` 的 `DialogHint`。
   两处都是**最后一行、dim、在 ` · ` 关节处折**——一个面只有一行这样的话，它就永远在同一个地方。
9. **动效只在一行上**（T38/T43）：输入框**上面**那一行的 braille spinner + 高斯扫光（`WorkingStatus`），
   `motion = false` 全关。transcript 里没有任何会动的东西——流式末尾那个 `▍` 光标 T43 删掉了：
   它拼进的是 markdown 的 **content**，每个 delta 都要重解析一份多一个字形的文档，
   块边界上它被吞掉或独占一行（实测三个 delta 内 7→6→7 行地抖），而 sticky-bottom 的 scrollbox 每抖一次就是整屏重排。
   **不加新动效。**

### 6.2 明度与颜色角色

**四档明度是一个层级，不是一块调色板**（T18）：一段文字用哪一档由它**是什么**决定，不由它该多显眼决定。

| token | 它是什么 | 画在哪 |
|---|---|---|
| `fg` | 这个东西本身 | 人说的话、模型说的话、一行的值、选中行 |
| `muted` | 它由什么构成 | 卡片头行（说出来的话才是最亮的那一档）、id 旁的 label、计数、状态词 |
| `dim` | **关于**它写的话 | 说明、hint、footer、列名、note 里的括号、run 摘要整行 |
| `faint` | 家具 | 折叠记号、指针记号、空 gutter、失效格、note 字段的占位 |

| accent | 唯一语义 |
|---|---|
| `accent.user` | 人：`▎` 左规线、输入框有焦点时的边框与光标、`/ext` 版本线上的 `▎ this session` |
| `accent.assistant` | 模型正在进行的这一轮：`●` 头、`WorkingStatus` 跑动时的主段 |
| `accent.tool` | 一次普通的 tool 调用的 glyph（`$` / `⌘` / `✎`） |
| `accent.evolve` | 演化与去处：`⚙ ⚡ ↺ ⌕ ☰ ⤷` 的 glyph、面的标题、`↗` 可点行、状态栏 `◈`、`↓ N more below` |
| `ok` / `warn` / `err` | 判决：`✓ current` / `unsafe`·等你回答·漂移 / `exit 1`·`✗`·deny |
| `diff.add` / `diff.del` | **只有前景色**，无背景块；上下文行 dim |
| `hairline` `selection` `lift` | 框线 · **光标行的底色**（唯一的行底色）· 抬色的方向：指针经过的行与扫光都朝它抬（主题自报，`NO_COLOR` 即 `fg`，两者都变成 no-op；T95 把 `hover` 那格底色删了） |

**代码有自己的配色**（T91，`render/syntax.ts`）：`markup.*`（正文的标题 / 列表 / 链接）与 `default` 仍来自上面这套 tokens——那是本前端自己的文档；而 fenced code 里的 14 个角色（comment / string / number / boolean / constant / keyword / function / type / variable / property / operator / punctuation / tag / attribute）来自一张**独立的调色板**，`[ui] code_theme` 选：`auto`（缺省，按界面主题的明暗给出 one-dark / github-light）· `theme`（旧行为：代码也用界面 tokens）· `one-dark` · `github-dark` · `github-light`。scoped capture 名（`keyword.control` 之类）不列——OpenTUI 的 `getStyleId` 会回落到第一个点之前的基名。`NO_COLOR` 压过一切调色板。
主题：`nulya-dark`（默认）/ `nulya-light` / `NO_COLOR` 全塌成终端自己的前景色。

### 6.3 glyph 词表（封闭）

| glyph | ascii | 唯一语义 |
|---|---|---|
| `›` | `>` | **输入点**：还没说出口的话——composer 提示符、Welcome 的邀请、`/provider` 的输入字段、SkillEcho 回显的那条 `/name args` |
| `▎` | `\|` | **左规线**：把一整块标成「这是谁的」（UserTurn 每一行、CompositionCard 每一行），或在一行里标出「就是眼前这一个」（`▎ this tab` / `▎ this session`、**tab 条上当前那个 tab**（T70）——其余 tab 留两格空白，所以名字仍在同一列起） |
| `●` | `*` | transcript 面：模型说的话。overlay 面：`● ○` 开关里亮着的那半（`/ext`）、`● live`（别人正持着写者租约） |
| `○` | `-` | overlay 面：`● ○` 开关灭着的那半 |
| `⋯` | `...` | **折起来的一段过程，你只被给到这一行**：thinking 卡、run 摘要（T43；曾经是 `●`，与它上面那句话同字形） |
| `$` | `$` | shell 调用 |
| `✎` | `~` | 一次 edit（diff 卡） |
| `⌘` | `#` | extension tool 调用 |
| `⚙` | `%` | build / init（transcript 卡的头）· **`/settings` 的入口**（状态行行尾那两格，T92）——**词表里唯一一个共用形状的条目**，故意的：齿轮是不用教就读作"设置"的那一个图标，而这正是 `◧` 对侧边栏**不成立**的地方；两者永不相遇（一个是卡的头字形，一个钉在状态行末端），位置就是它们的区别 |
| `⚡` | `!` | **一次能力的获得**：`ext activate` 与它配对的 capability note；Welcome 与 CompositionCard 里选上去的 tool 名前缀 |
| `↺` | `<` | rollback |
| `⌕` | `?` | 读内核源码（`nulya src`） |
| `☰` | `=` | skill |
| `⤷` | `>` | sub-session。transcript 面：一次开了自己那场对话的调用（委派卡）。**pane 面**：sub-agent 观察 pane 的归属行行首（T72）——同一个意思的两处，一处说「有这么一场」，一处说「就是它」 |
| `⊘` | `x` | 被取消的调用 |
| `✗` | `!` | driver 侧的失败（`ErrorNotice`）——不是 tool 的失败，那个说 `exit N` |
| `▸` `▾` | `>` `v` | 折叠：关 / 开；`▾` 同时是**列表里光标所在的那一行**（两处都是「这一个展开着 / 就在这儿」） |
| `·` | `.` | 指针所在的那一行（形状与光标不同，所以没有颜色时也分得开） |
| `↓` | `v` | **下面还有**：`↓ N more below`（方向，不是状态——所以不是 `▾`） |
| `↗` | `->` | 去别处：卡片上唯一那条可点的链接（`↗ watch here`，§5.5） |
| `⠋` | `-\|/` | spinner（只在 `WorkingStatus`） |
| `✻` | `*` | tip：屏幕在跟人说话，不是发生了什么（T38） |
| `◧` | `[` | **sessions 侧边栏的把手**（T69）：左半填实的方块 = 屏幕左边缘停着一块 pane。只画在状态行行首那两格，点它开/关。**它不说侧边栏是开是关**——侧边栏在不在屏幕上是它自己以整块宽度回答的问题，把手再答一遍就是同一个问题的第二个答案（§6.1 第 4 条）。**≥100 列时它后面跟着自己的名字** `◧ sessions`（T70）：一个没人见过的字形、画在这一行最不被扫到的那一端、开的又是一块从没在屏幕上出现过的 pane——第一个用它的人报告说完全没找到侧边栏。窄屏退回纯字形（`sidebarRowPlan` 的同一条让位规则）|
| `▪` | `*` | **这个目录已经是一个 workspace**（T71，只在 `/cwd` 的目录浏览器里）：里面已经有 `.nulya/`，选它是走进已经存在的工作而不是开一个目录的第一场。**不是 `⚡`**——那个说的是「刚刚获得了一样能力」（`ext activate` 与选上去的 tool 名），一个以前被工作过的目录此刻什么都没获得 |
| `✕` | `x` | **关掉眼前这一块**（T70 在 tab 条上，T72 在 sub-agent pane 的归属行末尾——同一个按钮，作用在它所在的那块东西上）：`⊘`/`✗` 说的是一次调用**发生了什么**（被取消、失败）、住在 transcript 里；这一个是个**按钮**，按钮以它做的事命名 |
| `+` | `+` | **新开一个 tab**（T70，只在 tab 条上） |
| `◈` | `#` | **这一场以什么身份/档位在跑**：选它的那些对话框标题（`/model` `/mode` `/agent` `/with`）、状态栏「戴着谁」的 chip、包自己的 panel 标题。列 store 或 journal 的面板是「地方」，标题**不带记号**（T31）；审批对话框也不带——它不是选身份，是**一个 call 被裁决**，颜色（warn）说完了 |
| `‹ ›` | `<` `>` | `/model` 的 effort 转盘 |
| `✓` | `*` | **现在生效的那一个**：`/model` 的 current model、`/ext` 版本线的 `✓ current`、`/mode` 当前档（一律 `ok` 色） |
| `⇥` | `⇥` | **shell 跑在哪**（`⇥ remote:wsl:Ubuntu`，只在状态行、只在非 local 时；warn 色——它是让 `rm -rf build` 变成两件事的那个事实） |
| `⏸` | `⏸` | **排着队的消息**（`⏸ N queued`，只在输入框上面那条 queue lane，§4.4） |
| `○◔◑◕●` | `.:oO#` | **一把梯子，不是五个字形**：context 环与面板里那条横条的刻度（`theme.glyphs.ring`）。各自没有意思，只有在同一刻度上的位置；两头永不被取进去（用掉了就不画空环，还有余量就不画满环），精确的百分比写在旁边。面板里的横条用同一条规则、**两个形状**（`theme.glyphs.meter`）而不是两种颜色——`NO_COLOR` 下也得看得出满到哪儿 |

### 6.4 transcript 的节奏

- **头行从左往右读**（T26）：`glyph 头行  (note) ▸`——note 在括号里紧跟头行、fold 记号在文字末尾。
  原来 note 是**右对齐 chip**，于是第 98 列挂着一个 `ok`、和它说的那次调用之间隔着三十个空列。
  行内没有任何节点会被 flex 压缩：头行由我们 `fit` 到 note 与记号剩下的宽度。
- **卡片体缩进 +2**；spill 指针（`full output → …`）与 `↗` 动作行在**折叠之外**，与体同缩进，都 `fit` 到行宽。
- **空行三档**（`Transcript.gapBefore`，一个纯函数）：**一次 run 里的调用之间 0**（六次调用是一块）·
  **beat 之间 1** · **人开口之前 2**（换一轮对话不只是换一个 beat）。
  T43 把 `thinking → assistant` 那条 0 收回了：屏幕上那是两张卡贴在一起，而「属于后面那句话」由顺序和 dim 已经说完。
- **宽度**：内容 ≤ `max_width`（默认 100），左对齐；窄于 60 列时隐藏状态栏右半。

### 6.5 两类面，两套骨架，一个左边缘

**这两类是词表的全部**：一个新面必须是其中之一，不许发明第三种密度。两类共用同一条铁律——
**盒子左padding 1 格，gutter 占第 1–2 列，一切内容从第 3 列起**。所以标题的 glyph 恰好两格宽
（`◈ ` 就是标题自己的 gutter），行的名字、标题的字、body 的字，全落在同一列上。

| | overlay（整屏，`/ext` `/sessions` `/model` `/provider` `/tasks` `/usage` `/settings` `/help`） | composer 区对话框（`ui/Dialog.tsx`：`/mode` `/agent` `/with`、审批） |
|---|---|---|
| 标题 | 一行，`accent.evolve`；**列 store / journal 的面不带 glyph**（它是「地方」），只有本身是一次「选身份/档位」的才带 `◈`（`/model`） | 一行，`◈ <名> · <一句它是干什么的>`；审批那个不带 glyph、整行 warn |
| 标题之后 | **一个空行** | **不空行**（它长在输入框上面，一行就是一行） |
| 主体 | 行的 gutter 走 `ui/rows.ts` 的 `rowGutter`（永远两格宽） | 同一个 `rowGutter` |
| 底部 | `OverlayFooter`：notice → warning → 一行键（+ `? keys`） | `DialogHint`：一行键 |
| 内容超屏 | 装进 `scrollbox`（`flexBasis: 0`，否则盒子按内容高度起步、把 footer 挤成 0 行然后**画在最后一行上面**） | 不会超屏（对话框自己有上限：审批的命令摘要封顶 6 行 + 一行 `… +N more lines`） |

`/ext` 是 overlay 里唯一分栏的（左列 id / 右栏详情 / 下面 tools 与 usage 两个 pane），
分栏也只是把同一套骨架放进两个盒子——**每个盒子里仍然只有一个左边缘**。

## 7. 设定 `tui.toml`

路径：user 层 `~/.nulya/tui.toml`（Windows `%USERPROFILE%\.nulya\tui.toml`；`NULYA_HOME` 整体搬走，与内核 `config.toml` 同目录同规则），项目层 `.nulya/tui.toml`；后者覆盖前者；`Bun.TOML.parse`。

```toml
[transcript]
diff           = "expanded"    # expanded | collapsed
tool_output    = "collapsed"   # collapsed | expanded
thinking       = "hidden"      # hidden | collapsed | expanded —— 默认不画 reasoning 卡（T43）
run_summary    = true          # 一串跑完且成功的无身体调用折成一行（T43）；false = 一次调用一行
composition    = "collapsed"   # collapsed | expanded —— 顶上那张 session 卡（T25）
max_width      = 100
history_window = 400           # 同时挂载的卡片数（从最新往回数）；0 = 全挂（T4）
stream_interval_ms = 100       # 流式 markdown 最多多久重画一次；0 = 每个 delta 都画（BUGS #21）
ascii          = false

[ui]
theme      = "nulya-dark"   # nulya-dark | nulya-light
code_theme = "auto"         # auto | theme | one-dark | github-dark | github-light —— 只作用于 fenced code（T91）
motion     = true

[driver]                    # T24
mode = "ask"                # ask | unsafe —— 一趟从哪一档开始；chip 与 `/mode` 的选择记在 tui-state.json 里、优先级更高

[approvals]                 # T24；条目 = tool id / tool 名 / `shell:<命令前缀>`
allow = []
ask   = []                  # 连 unsafe 也弹
deny  = []                  # 连 ask 也不弹，直接拒
manifest_readonly = true    # 信一个 tool 自己声明的 `"readonly": true`（DESIGN §7.2.1；是提示不是边界）
readonly_commands = []      # ask 档下额外算作只读、因而不打断人的程序名（T65 的分类器可扩，但否决压不掉）

[extensions]                # T11
sync_on_start = true        # 开屏时后台 build 两个 draft 目录里的 draft（`nulya ext sync`）
auto_activate = true        # 让那一趟把 `current` 指到它刚建出来的版本上（activate 只是移指针，T50）
session_with  = ["handoff", "agent"]  # 这个前端给它开的每个顶层 tab 额外带上的成员，`<id>[:<tool>,…]`；不写选择就取该版本全部 manual tool（§5.8 / §5.10）
session_prompts = ["ground"] # 每场开场前问一次「这一场的开场文本」的包（T66）：跑它的 internal `render`、
                            # 读回 `{"prompt": "<路径>"}`、把路径喂给 `session new --prompt`。不是成员——
                            # 进 session 的是它写出来的那个文件（`goals/session-prompt.md` 的那条线）。
                            # `no project` 那个 workspace 整段跳过（T71，§5.11）
plugins       = true        # 代码层总开关（T40）：加载已激活/本场戴着的包的 `contributes.ui.tui.entry`
                            # false = 只剩声明层（commands / policy / 每个 tool 的 ui 照常，逐字节等于 T39 结束时）

# 按 `/env` 目标的种类（local | remote）覆盖上面这两个列表。
# 不写这一节、或写出来但留空，就是下面注释里那份缺省；`bare` 缺省时 local = false、remote = true。
# 写了的字段整体替换缺省，没写的沿用——与 session_with 那条「替换不合并」同一条纪律。
[env.local]                 # 不写 = local 的缺省：bare=false，用 [extensions] 那两个列表
[env.remote]                # 不写 = { bare = true, with = [], session_prompts = [] }
# bare = true                 # 缺省已是 true；config 的 `[extensions] with` 不读
# with  = []                  # 缺省已是 []；想在远端场里也带某个包，写它的 id
# session_prompts = []        # 缺省已是 []；ground 的本地事实对远端没有意义

[keys]                      # 覆盖默认键；名字表见 keymap.ts
cancel = "escape"
```

`sync_on_start` / `auto_activate` 都只作用于**这一趟 sync**：`auto_activate` 永远不会盖掉指着别处的 `current`（那是 DESIGN §7.2 的规则，前端无从违反），所以一次 rollback 活得过下一次启动。**没有第二道 policy 挡在它前面**（T60 把那个守卫整个删了）：进得到自动激活的只有三条路——装这个二进制、自己往 store 写源码、亲口回答 checkout 的那句问（它本来就提供 `s` = 只 build 不激活）——每一条都已经过了一个人，守卫是在这些之后**再**替人否决一次。`activateUnattended` 只剩一条 **fail-closed**：读不出这个版本的冻结 manifest 就不动指针——那不是 policy，是「别对读不出来的数据动手」。换掉守卫的是**可见**：开屏那行汇总点名这一趟装了什么并指 `/ext`，`standing` 那一格与 Enter 是收回的地方。**一个包这一趟拿到它的第一个 `current` 时**（而不是每次指针前进时），按它自己声明的 `surface` 选上它的 `manual` tool——版本前进时那张成员表已经是人的了，一个会自己撤销的开关不是开关；`max_tools` 不够就一个都不写，让 `/ext` 去挑。checkout 那句「要不要 build 它的 draft」**不受这两个键管**：别人写的源码在本机编译并被指上，只有按键能推动。

`/settings` 显示当前生效值与来源文件，**说得出这个文件收哪些字段**（T94）——上面这一整张表的每个键都在屏幕上，每行带着它接受的词表或形状，以及——当它不是缺省时——缺省是什么；能在界面里选、记在 `tui-state.json` 里的那些（模型 / 权限档 / 目录 / shell 跑在哪 / 成员与它们的工具）排在最前面，每行就是一个入口（T92）——**并且改得动**（T100）：`j/k` 落光标、`Enter` 在两值的键上直接换成另一个、三值以上开一个列表、数字与列表在行内输入（列表用逗号分隔，与值那一列的写法同一种）。写的是 **user 层**那一个文件，手法是**最小编辑**：找到那个键所在的行就地替换（连行尾注释一起留着）、没有就在它那张表的末尾加一行、连表都没有才在文件末尾开一节并写一句 `# nulya:` 说明是谁加的；**绝不重排、绝不删注释、绝不 serialize 整个文件**（`state/settingsfile.ts`，`nulya/credentials.ts` 的同一条纪律）。**这不构成第二个作者**：作者只有人一个，屏幕是那支笔，文件仍是同一份文档。`keys.*` 与 `env.<kind>.*` 两类行不写（前者名字是开集，后者一行代表三张表），`Enter` 只说去哪儿改；**项目层已经设过的键在行首标出来并拒绝写**——近的那层胜，写在 user 层什么都不会发生。写完当场重读文件链、界面即刻生效（`render/theme.ts` 的 `liveStyle`），只在启动时读一次的那几个键（`extensions.*`、`driver.mode`）由行自己说出这一点。

**`tui-recents.json`（T71）**：user 层下**第二个**由程序写的文件，JSON `{"recent": ["<绝对路径>", …]}`（新的在前，上限 12）。为什么不是 `tui-state.json` 的一个键：那个文件在其它每一处都是 **workspace 层**的事实（这个项目的成员表、它的侧边栏、它的档），而这一条是**关于好几个目录**的事实——一份别的目录的清单不能住在其中一个目录里面。**只在真的建起一场 session 时写**：浏览到一个地方不等于在那儿工作过。读不出来 = 没记住，永不阻止启动。

**`tui-state.json`（D10）**：同目录（user 层）下由程序写的文件，记的全是**人在屏幕上做过的选择**——`model{profile,model,effort}` · `mode`（权限档）· `session_with` · `exec_env` 与 `exec_workspace`（**同一次调用成对写入、成对清空**：一个 spec 配着上一次别的 spec 选的目录是错配）· `remote_cwd`（每台机器自己的浏览起点）· `remote_pushed`（上次这个前端 push 了什么、内核说了什么——一句关于过去的陈述，不是一句关于现在的主张）· `sidebar{open,ratio}`（**人要什么**，不是屏幕上是什么：窄终端自己把 rail 收起来，宽回去再放出来）· `tabs: [{ws, session?}]`（tab 是一对，所以记也记一对；恢复只做**第一个之后的那些**，第一个仍由这一趟启动决定）· `asked_stores` / `asked_agents` / `trusted_agents`（checkout 的那两句只问一次）· `plugins`（每个包自己的一格）。`/model` 的 Enter 与 `/effort` 会更新它；启动无 `--profile` 时的默认选择就是它（`launch.planLaunch`：命令行 > 上次选择 > 内核 `active_profile`；每一层都要 `config show` 说它有 credential 才算数，否则落到离线 scripted 并开屏弹选择器讲原因）。缺失或损坏 = 没记住，永不阻止启动。为什么不放进 `tui.toml`：那是人写的；程序回写人的文件会碰注释与排版（tcode 用 toml_edit 才做到），这里不值得。为什么不进内核 config：内核不需要知道"上次选了谁"（不是 substrate）。

## 8. 测试

`cd tui && bun test`（`bun run typecheck` / `bun run compile` 是另外两条）。三种测试，各守各的：

- **纯函数**：判据、投影、解析、布局算术（`approvals` / `runs` / `panes` / `browsedir` / `settingsfile` / `readonlyshell` …）。不开终端，也不需要二进制。
- **真渲染**：`@opentui/core/testing` 的 test renderer——每种卡片与每块面的快照帧（含折叠/展开、窄屏），以及**真的按键与真的鼠标**。快照里会走的东西（session id、日期、临时路径、时钟）**先按等宽掩码掩掉**：快照是拿来钉版式的，钉上一只走着的表就是每分钟红一次。
- **真二进制**：`NULYA_SCRIPTED_MODE` 跑 `nulya` 自己（new → append → `step --stream` 的行序与类型化解析、cancel、gate、后台任务、委派、`ext` 全套、remote 走 `remote:exec:` loopback 起一条真通道）。**不调真实 API**；CI 只需 `zig build` 出二进制 + `bun test`。preload 给每次 `bun test` 起一个 scratch `NULYA_HOME` 并在退出时删掉。
- **断言守机制，不守细枝末节**（CLAUDE.md 那条）：一条断言失败时该是代码逻辑错了，不是某个文案、列宽或常量变了。改一个 bug 时先把测试写红——本文档归档的日志里，"验证过它在旧代码上会红"是反复出现的那句。
- Zig 侧：`--stream` 行协议单测（scripted provider）+ e2e 里的 `--stream` / `--gate` 冒烟。

## 9. 里程碑

T0–T115 全部落地，逐条经过与验收标准在归档的实施日志里（[`history/tui-implementation-log.md`](history/tui-implementation-log.md)）；今天前端是什么样在 §11 开头。

**仍未开工的只有一个**：

| 里程碑 | 内容 | 完成标准 |
|---|---|---|
| **T10 · `/goal`（占位）** | spawn 随仓库带的 driver 脚本（`win32` → `powershell -NoProfile -ExecutionPolicy Bypass -File drivers/goal.ps1`，否则 `sh drivers/goal.sh`），把它的 **stderr 喂给已有的 `--stream` 解析器**（token delta / tool begin-end / usage 全在里面），把它的 **stdout 当控制通道**：`session <id>` 开 tab、`handoff <old> -> <new>` 换 tab（原 tab 留着可回看）、`done <id>` 收尾并提示 `/outcome`。跟随中的 tab 是 **observer**（driver 持着写者 lease）。**内核零改动**，也不需要 §10.3 的 `<id>.live` sidecar | 起一个两阶段目标：token 实时可见；handoff 时自动切到子 session；`Esc` 停得下来（`session cancel` 或杀脚本）|

排期方式没变，也值得记下来：**T1 结束就开始用它 dogfood**，此后每一轮的优先级由用出来的痛点重排，而不是由这张表。

## 10. 开放问题（待议，默认都先不做）

1. **spawned-by 谱系**：subagent 的 `session new` 在 `NULYA_SESSION` 存在时是否自动记一个 header 字段（`spawned_by{session,seq}`，与 `parent` 分开）？是 provenance fact，成本几行；但等第一个真实 consumer 出现再定字段名与语义。
2. **`session append` 打印投递回执**（inbox 文件名）→ TUI 按 `origin` 精确转正而非按序匹配；现在按序够用。
3. **别人跑的 driver 的 deltas**：我们自己 spawn 的 driver 把 `--stream` 的行协议原样透传到 stderr，所以 `<id>.live` sidecar 不需要了（DESIGN §11）；剩下的只有"不是我 spawn 的那个 driver"——那条路仍然只有 `events --follow` 的 turn 级粒度。
4. **`nulya composition preview`**：下一场的工具面长什么样（config 的 `[extensions] with` + argv 的 `--with` + 冻结版本合出来的结果）——纯投影 CLI，省得 TUI 自己拼。
5. **`split-footer` 模式**作为可选屏幕模式（scrollback 原生复制），与折叠可变历史的取舍。
6. **`/new` 的表单**：等 PLAN §3.2 那几个 `session new` 参数长齐。
7. **宿主宪章 + 扩展 UI 自由度模型 + app 化（鼠标优先 / pane 平铺）**：整份设计讨论记录在 [goals/tui-shell.md](goals/tui-shell.md)（宪章四类、三层自由度、五条不打架规则、chip 模型、核心 vs 扩展切法、里程碑草案 S1–S3）。S1（pane 骨架 / 侧边栏 / 每 tab 一个 workspace / sub-agent pane）已落地，**S2 未排期**；动宿主骨架或 plugin API 前先读它。

曾经在这张单子上、后来做掉的：`nulya config show --json`（`/model` 读它）· `session step --gate`（前端自己发明的审批模型永远不会知道自己被拒了）· header 的 `created` · 「这个 tool 是给谁的」——今天由 manifest 每个 tool 的 **`surface`**（`auto` / `manual` / `internal`，DESIGN §7.2.1）回答，前端那四张硬编码名单一并消失。

## 11. 实施日志

**T0–T114（2026-08-15 → 2026-09-01）已归档到 [`docs/history/tui-implementation-log.md`](history/tui-implementation-log.md)**——那是怎么走到今天的流水，不必读；今天是什么写在下面这一小节与 §1–§10 里。**新条目从 T115 起写在这里。**

> 每个里程碑追加一小节，只追加不改写。格式：状态 / 关键决定与理由 / 偏离设计之处 / 怎么运行与测试 / 已知问题 / 给下一里程碑的提醒。
> 主对话（编排者）在每节末尾追加一行 `核验：…` 记录 `zig build test` / `zig build e2e` / `bun test` 的结果。

### 今天前端是什么样

按面各说一两句；每一面的契约在 §1–§10，这里只说它现在长什么样。

- **屏幕**：内容区是一棵 pane 树（`src/pane/`），最常见的形态是它的退化形——一个 pane、一张 transcript。左边可以劈出 sessions 侧边栏（`/sidebar`、`F8`、状态行行首的 `◧`），tab 内部可以劈出 sub-agent 观察 pane；整屏 overlay 永远开在主 pane 里。整屏只有一样东西有边框：输入框，它同时是「键盘在不在这儿」的唯一信号。
- **transcript**：一个 ledger 事件一张卡（`render/cards/`），live 与 replay 走同一组卡片。默认折叠：工具输出折、diff 展开、thinking 不画、一串跑完且成功的无身体调用折成一行 run 摘要。换行宽度取**这一栏的**（`useBodyWidth`）而不是终端的。折叠只有两种手势：点头行、browse 模式（`Esc` 进，`j/k` 移动、`Enter`/`Space` 切换）。
- **输入框上面那一行**：只在有事发生时存在（`WorkingStatus`）——spinner + 正在跑的 tool 名 + 钟 + `esc to cancel` + 这一轮的花费，外加一段可点的 `N background`。静息态整行不画，它也是全前端唯一有动效的一行。
- **输入框上面那一区**：审批对话框、`/mode` `/with` `/agent` `/env` 四个 picker、context 面板、后台任务面板、插件 panel、queue lane、checkout 授权框与 ssh 密码框都排在这里；谁拿键盘由 `pane/focus.ts` 一处仲裁（trusted zone → 整屏视图 → 插件 panel → browse → 输入框）。
- **输入框下面那一行**：一句静态描述——行首 `◧`、mode chip、模型 id（可点 → `/model`）、`tools 1+N`（可点 → `/ext`），右边是 context 环、`◈ 戴着谁`、`⇥ shell 跑在哪`、`step n`、observer 标记，行尾 `⚙`。**没有的东西不占列**；notice 来时盖住整行、按长度停留几秒自己下去。
- **命令**：内建表在 `commands.ts`（一个概念一个词；`/as` `/resume` `/exit` 是不列出但补全的别名），其后是 activate 了的包自己声明的命令（`/plan` `/ask` `/evolve` `/compact` 都是这一档），再其后是 skill，都不认就原样发给模型。
- **权限**：永远以 `--gate --stream` spawn step，`ask`（缺省）/ `unsafe` 两档，判断全在 `approvals.ts` 一条链里（§5.7）。问就是输入框上面一个可选可点的对话框，每个答案都能带 note。readonly 天花板（agent 定义的 `permissions`、包的 `contributes.policy`）排在整条链之前，谁都掀不动。
- **后台任务**：唯一的新 policy 是「driver + 本进程驱动过 + idle + inbox 非空 → 再 step」，其余全是把 `task list --json` 画出来——状态栏的 `N background`（点开是输入框上面的任务面板，能停）、`/tasks`（F7 全屏，看 log、`k`/`K` kill）、两张按任务全名连起来的卡。远端任务多一个 `unreachable` 状态与一列 `machine`，log 在那台机器上。
- **委派**：`.nulya/agents/*.md`（workspace > user > 包自带三层）一个定义就是一组 `session new` 参数；`/agent <name> <task…>` 开一张看得见的新 tab，裸 `/agent` 是只把命令写进输入框、不启动任何东西的 picker。模型自己调 `agent{…}` 时前端只画：委派卡说的是「派了谁、在干什么」而不是它的编号，`↗ watch here` 在**当前 tab 内部**开一块只读的 sub-agent pane。
- **plugin 层**：声明位（`commands` / `policy` / `tools[].ui` / `contributes.ui.tui`）与代码层（`plugin-api.d.ts`：行渲染、五个注册面、只有人已有的动词）都已接通，`tui.toml` 的 `[extensions] plugins = false` 一键退回纯声明层。compact / handoff / plan / ask 的界面全住在各自的包里——宿主不认识它们的包名、tool 名与 marker。
- **一场 session 的边界**：开屏是 draft tab，第一条消息才 `session new`，那一刻现读 pin、成员（`session_with`）、开场文本（`session_prompts`）、目录、exec target 与模型。已经开始的 session 什么都不能就地换（身份与 composition 冻在它那个文件里）——`/model` 于是走 `session new --parent <id>:<seq> --carry`：同一条对话带着历史进新 session，模型与今天的成员表一起现解，tab 换过去。
- **目录与远端**：tab = (workspace, session)；`/cwd` 换 draft 的目录，`no project` 落在 `<NULYA_HOME | ~/.nulya>/home/`；`/env` 选下一场的 shell 跑在哪，remote 档还要在那台机器上选一个目录，`/ext` 上的 `r` 把选中的包 push 过去。
- **人写的与程序写的分开**：`tui.toml` 是人写的设定（`/settings` 只做最小编辑——换掉一行、绝不重排、绝不删注释），`tui-state.json` 与 `tui-recents.json` 是程序写给自己的便条（上次的模型 / 档 / 目录 / exec target / pin / tab / 最近的 workspace）。


### T115 · BUGS #10 的续扫：一张卡的宽度是它那一栏的，不是整个终端的（2026-09-01）

**内核零改动，只动 `tui/`。** #10 的现象（"复制的大段 md 粘贴后很多没展示，但发给模型的正常"）在 `UserTurn` 上的根因是 T73/BUGS #17 那条老规则的一处漏网：换行宽度取自 `useScreen()`（整个终端）而不是 `useBodyWidth()`（这张卡实际所在的那一栏）。换行后的每一行由自己的 `height={1}` 盒子绘制，OpenTUI **不会**把过宽的行折到下一行——多出来的部分根本不画。所以开着侧边栏或分屏时，屏幕丢内容而 ledger 与模型都是完整的，这个不对称就是 #10 的全部症状。

这次把这一类**扫干净**（`src/render/` 下 `useScreen()` 归零）。改成 `useBodyWidth()` 的八处，各自的损失形状：

- **`UserTurn`**（#10 本身）· **`ShellCard`** 的 `ShellCommand` · **`CapabilityBanner`** —— 三处都是 `hardWrapLines` 进 `height={1}` 行，过宽即丢尾。
- **`ErrorNotice`** —— 同一形状的 `wrapWords`，而它的注释本来就写着"失败是屏幕上唯一必须读全的东西"。
- **`CompositionCard`** —— `valueWidth()` 喂 `ui/Fact` 的 `wrapWords`（同样丢尾），`title()` 那句"整段整段地让、而不是被切"在按终端算的宽度下失效：sub-agent 分栏里它挑了最长那一形，再被 flex 切成 `session · … · frozen`，正好丢掉说明这张卡是什么的那个词。
- **`CardFrame`**（含 `ActionRow`）—— 头行是 `fit()` 切的不是折的，按终端切完再被栏边缘 clip，先没的是行尾的 note 与折叠标记，也就是"发生了什么"那一半。
- **`PluginToolCard`** / **`PluginUserTurnCard`** / **`plugins/surface.tsx`**（`PluginSurface`、`PluginCardSurface`）—— 这几处传下去的是一个**数字**，别人的 renderer 拿它决定自己在哪里断行；给成终端宽度，回来的每一行都对这一栏太长。`PluginUserTurnCard` 尤其要紧：compact / handoff 带过来的整段上下文正是从这张卡进屏幕的。`surfaceWidth` 的参数因此从 `screenWidth` 改名 `available`。

**留着 `useScreen()` 的（判据：它画出来的行有没有被放进一个受限宽度的容器）**：`ui/PluginPanel.tsx`、`ui/PluginWidgets.tsx`、`ui/PanelStrip.tsx`（借 `CardFrame`）以及状态栏、tab 条、各 picker 与 overlay —— 它们全是 `PaneHost` 的**兄弟**、在那个 `flexDirection: column` 的整宽列里，侧边栏与分屏都不缩它们。`BodyWidthContext` 只包着 `Transcript`（`App` 的 portal 与 `SubAgentPane` 的分栏两处提供），所以 `CardFrame` / `PluginSurface` 这些**两边都用**的组件改成 `useBodyWidth()` 之后，在 transcript 外它自动落回终端宽度——与从前逐位相同。

测试 `test/panewidth.test.tsx` 三条，钉的是机制不是行数或断点：① 一个 `pane=44` / `terminal=110` 的 `Transcript`（user turn + shell + capability + error 四张卡）**没有一行超过 44 列**；② 窄栏折行**一个字符都不丢**；③ plugin renderer 被告知的宽度 ≤ 栏宽。把 `useBodyWidth` 临时改成无条件读 `useScreen()`（即旧行为）后，①③ 变红（`Received: 100`），②不变——它守的是反方向。

快照只churn了一处且正是修复本身：`subpane.test.tsx` 的分栏帧里，右栏 composition 头行从被切的 `session · ---------------- · frozen` 变成整段让掉的 `session · ----------------`，即 `title()` 注释承诺的行为。`bun run typecheck` 通过。

**合并时补的一处**：T114 的 `RebindCard` 是这次扫除分叉之后才出现的卡，同样画在 transcript 里、同样按终端宽度算 `room()` —— 一并改成 `useBodyWidth()`。这条规则的检验方式因此写成"`src/render/` 下 `useScreen()` 归零"而不是一张文件名单：名单会被下一张新卡绕过。
