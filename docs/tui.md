# Nulya TUI — 设计与计划

> **状态：T0–T24 全部落地。** 内核侧只有四处：`session step --stream`（纯观测）、`session step --gate`（每个 tool call 执行前问一次，T24 → DESIGN §4/§14）、`session new --parent` 的 fork 语义 → [DESIGN.md](DESIGN.md) §14/§11，与 `NULYA_EXE`（子进程 env 里的本二进制路径，§7.6——`/compact` 的过程搬进 `extensions/compact` 之后它才调得到 harness）；前端 T1（骨架）、T2（卡片与折叠）、T3（nulya 视图：`/sessions`、`/ext`、sub-session tab、observer）、T4（`/help` `/settings` `/usage`、keymap 覆盖、`bun build --compile`、README、5k 事件性能）、T5（`/model` `/effort`）、T6（布局与 slash 补全）、T7（`/compact`）、T8（慢速回路：`/outcome` `/evolve` `/mode`、`/sessions` 改读 `session list --json`、成本来自 ledger、`/ext` 认多 root）、T9（`/compact` 改成 spawn `extensions/compact`）、T11（启动即安装：`ext sync` 的时机、project store 的 trust 问句、`/ext` 的 draft 列与 `p`）、T24（权限 mode `/mode`、审批卡片、handoff 接线；穿身份的命令改叫 `/as`）都在 `tui/`（见 §11 与 [`../tui/README.md`](../tui/README.md)）。本文是 `tui/` 的设计契约 + 里程碑 + 实施日志；`tui/` 不在内核范围里（另一条工具链、另一个进程），所以它的现状写在本文 §11，不进 DESIGN.md。
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
| D2 | 流式传输 | v1：`step --stream` 写 **stdout**（TUI 拥有 step 子进程） | 最简、可调试。observer 模式（别人在 drive）要看 deltas 需 `<id>.live` sidecar——等第一个 driver 脚本出现再做（§5.6） |
| D3 | 绑定 | Solid | opencode 同款；fine-grained 更新适合流式。React 也行，API 同形 |
| D4 | 设定文件 | 独立 `tui.toml`，路径**镜像**内核 config 的目录（user 层 + `.nulya/tui.toml` 项目层），不放进内核 config | 内核不该认识 TUI 的键；同目录让"设定在哪"只有一个答案 |
| D5 | 默认折叠 | diff presentation **展开**；shell / 扩展工具输出 **折叠**；**thinking 默认 `hidden`**（T43，可设回 `collapsed`）；capability banner 展开；**一串跑完且成功的无身体调用折成一行 run 摘要**（T43，`run_summary`） | 你的要求 + 演化动作要显眼；reasoning 既不是模型说的也不是它做的，而「正在想」由输入框上面那一行说（T38） |
| D6 | 取消 | `Esc` = `session cancel`（step 边界消化，当前工具跑完）；`Ctrl+C` 两下 = kill step 进程树（下一次 open 由 kernel `completeInterruptedToolBatch` 修复） | 两种语义都真实存在，都给；不发明第三种 |
| D7 | sub-agent 谱系来源 | v1 从 transcript 推导（`nulya session new` 的输出 id、`session step <id>` 命令）；**不**改 header | `parent` 语义是 fork/compaction 的续接点，不是 spawned-by；等 subagent skill 真写出来再决定要不要 `spawned_by` header 字段（§10） |
| D8 | 权限 / 审批 | **两档 mode + 三张规则表**（T24 推翻"v1 没有"）：内核给一个 gate 原语（`session step --gate`，DESIGN §4），前端答；deny 就是那个 call 的 tool_result，模型读得到 | 原来的理由是"kernel 没有可消费的东西，TUI 不发明审批"——对的一半：发明一个内核不知道的审批，模型永远不会知道自己被拒了。所以补的是**内核那一半**（一个语义：allow / deny+note），判断留在前端（§5.7） |
| D9 | 内容宽度 | transcript 内容宽度上限 `max_width = 100` 列，左对齐 | 250 列的 markdown 不可读；设定可改 |
| D11 | **session 懒创建：第一条消息才 `session new`** | 开屏是一个 **draft tab**（无 id、磁盘上什么都没有），它只捏着 `session new` 要的东西（pick / `--with`）；pin 在 materialize 那一刻现读 `tui-state.json`。`--session <id>` 仍是真 tab；`/compact` 仍产真 tab | composition 在 `session new` 冻结（physics #2）——开屏就建，等于替人把 tools / pin / model 决定了，随后在 `/ext` `/model` 里做的一切要么落到**下一场**、要么靠"偷偷替换空 session"糊过去。懒创建让"改完再开"变成默认，`discardIfUntouched` 从常规路径退回成边角（T22） |
| D12 | **`/ext` 的 Enter 是一个开关：activate + pin 一起动** | ON = `ext activate` +（声明了 tool 的话）把它的 tool 全进本 TUI 的 pin 列；OFF = 先撤 pin（含 user config 的 `always`）再 `ext deactivate`。两根轴在内核里仍是两根：单个 tool 仍在 tools pane 用 `Space`，单个版本仍在版本线用 `a`/`r` | **推翻 T12 §5 的"永不合成一个总开关"**。那条原则对内核是对的、对屏幕是错的：两个键（`Space` 批量 pin / `d` deactivate）都藏在 `?` 后面，而它们移动的状态**一格都没画**——截图里 `evolution` `guide` 是 `built` 但 `current (none)`，人按 Enter 没反应、也看不出差别。一个画出来的开关 + 底下写清两根轴，胜过两个没人找得到的键（T22） |
| D10 | **给人用的：一切在屏幕上完成** | 启动 `nulya` 之后，选模型 / 换 effort / 看哪个 profile 缺 key / **贴 key** 都是屏幕上的交互（`/model` 选择器、`/effort`、选择器里的 `s`），**不能要求人去找 config 文件改**。TUI 记住上次的选择（`tui-state.json`，见 §7）；隐式的选择跑不了（缺 key）时开屏就是选择器 + 原因 + 怎么修。config 文件是**定义**（一个 model id 是什么、profile 怎么连）不是**日常操作面** | 这是 TUI 的关键设计理念，与 D4 分工：`tui.toml` 只有人写、`tui-state.json` 只有程序写；内核 `config.toml` 人写，TUI **只做一种写**——在末尾追加/就地替换一个带标记的 `[[provider.profiles]] name/api_key` 小块（`nulya/credentials.ts`；不重写、不碰人的内容）。内核不学"上次选了谁"（那不是 substrate）；kernel 只提供 `nulya config show --json` 一个投影（含 `paths`），TUI 不复刻配置合并链、不猜 home 在哪 |

## 2. 与内核的接触面

### 2.1 现有（只读用法）

| 面 | TUI 用法 |
|---|---|
| `nulya session new [--profile p] [--model id] [--pin] [--with]` | **一场 session 唯一的出生点，只在 draft tab 收到第一条消息时跑**（`tabs.materialize`，D11）；`/new` `/model` 的 Enter 只改 draft，不 spawn。stdout = id |
| `nulya session step <id> --effort e` | 每个 step 按本 tab 的 effort 传（`/model` 选的、`/effort` 改的）；不传 = kernel 默认 |
| `nulya config show --json` | `/model` 的行、启动时判断隐式选择能不能跑（`launch.planLaunch`）、draft 的 model id（profile 只给了名字时取它的默认 model）与 `registry`（`max_tools` / 合并后的 pin，draft 的工具面 = 它 ∪ `tui-state.json` 的 `session_pins`）；只报 env var 名与 credential 布尔 |
| `nulya session append <id> --file f` | 发送：写 `.nulya/scratch/tui-<nonce>.txt` 再 `--file`（多行 / Windows 引号安全）；投进 inbox，**下一 step 边界才进 ledger**（PLAN §4 边角）→ TUI 乐观回显、标 `queued`，见到对应 `user_text` 事件后转正——那条事件行现在在 `model started` **之前**就到（DESIGN §14，T27），所以 `queued` 只在真正还排着队的时候挂着，而不是整整一个 step |
| `nulya session step <id> --stream --gate` | 每次发送后 spawn 一个；stdout 见 §2.2。**`--gate` 常开**：每个 tool call 执行前内核打一行请求、等 stdin 一行 `allow` / `deny [note]`，答案由 §5.7 的 mode + 规则给（T24） |
| `nulya session events <id> [--since N]` | 打开 / resume 时一次性回放；**不**用 `--follow`（driver 模式下 step 的 stdout 已是全量实时源） |
| `nulya session cancel <id>` | `Esc` |
| `nulya session list [--json]` | `/sessions` 的全部内容（created 倒序、composition / parent / 事件数 / usage / 最新 verdict）；**TUI 不再自己扫 header**（T8） |
| `nulya session outcome <id> <v> [--note]` | `/outcome`；写 outcome journal、不碰 session 文件也不取锁，所以正在跑的场次、别人在 drive 的场次都能当场评 |
| `nulya session new --with <id>[@<v>]` | `/with <id>[@<v>]`，以及每一条 `{with: true}` 的包命令（`/evolve` `/ask` `/plan`，T53）：把一个包带进这一场（membership，不是 store 指针——`current` 指哪个版本一点不变） |
| `nulya ext build <path>` | `/compact` 与开屏 sync 的第一步；version 内容寻址，所以每次都 build，未改动就是同一个 version |
| `nulya ext run <id>@<v> <tool> <json>` | `/compact`：过程住在 `extensions/compact` 里（DESIGN §11），前端只 build 它、run 它、把 tab 换到它返回的 session；它持锁的这段时间本 tab 自己翻成 observer 跟随（§5.6） |
| `nulya ext list` | `/ext` 的目录清单：每个 id 来自哪个 root、谁被 `(shadowed)`——root 顺序与"首个持有者胜"是 kernel policy，TUI 不复刻（T8） |
| `nulya task list --session <id> --json` | `/tasks` 与状态栏 `⠋ N background` 的**全部**内容（`state` / `exit_code` / `elapsed_s` / `duration_ms` / `command` / `log`）。`starting`（还没写 status）与 `lost`（说 running 但租约空闲）是内核算好的投影，TUI 一律不复刻——与 `/sessions` 改读 `session list --json` 同一条纪律（§5.9） |
| `nulya task kill <task>` | `/tasks` 的 `k`（`K` = 每一个还在跑的）；写 kill 标记，supervisor 杀整棵进程树 |
| `.nulya/sessions/<id>.inbox/` | 有没有 `.json` = 有没有等着下一个 step 边界排干的事件 → **driver 唤醒的唯一判据**（§5.9）；与 `.lock` 探针同一个 idle 定时器、同样无副作用 |
| `.nulya/scratch/<sid>/tasks/t<N>/output.log` | `/tasks` 的 `Enter`：读最后 64 KB（路径来自 `task list --json`，TUI 不自己拼 scratch 路径）；不是真·live tail，跟着面板的轮询重读 |
| 后台回执 / 报告文本 | `[background task <sid>/t<N> started] … log: …`（`shell {background:true}` 的结果）与 `task_finished.text` 的两条分隔行 → 两张卡片按文本形状识别（`nulya/ledger.ts`，与 `[exit N]` 同一先例） |
| `.nulya/sessions/<id>.lock` | 能否非阻塞独占 → 有无别的写者（§5.6）；`session list` 给不了"此刻谁在写"，所以这条探针留在 TUI |
| `<root>/<id>/versions/v-*/extension.json` | `/ext` 与 CompositionCard 的明细：`runtime`/`contributes`（tools / skills / **system_prompts** / commands / policy / 本前端那一条 `ui.tui`）；root 由 `ext list` 指出 |
| `.nulya/tool-usage.jsonl` | `/ext` 里的 usage 表：一行取 `tool_id` + `ok` → uses_total / recent / success_rate（**只投影，不重算排序**——排序是 kernel policy，TUI 不复刻）。行上还有 `at` / `session?` / `duration_ms?`（DESIGN §5.5），TUI 只挑它要的两列、其余原样忽略 |
| header `composition.native_tools` / `active[]` | 本场冻结契约（§5.1）；与 store `current` 比对 → "下一场会变"的漂移提示 |
| shell 结果形状 | `stdout` + `--- stderr ---` + `[exit N]`（`tools/shell.zig`）→ 状态 chip 解析 `[exit N]` |
| `tool_results[].presentation` | UI-only JSON；`{kind:"diff", patch, path?, filetype?, added?, removed?}` 交给宿主 diff primitive。`std.edit` 的 diff 由 extension 从实际 `ReplacementPlan` + 旧/新文件字节写入 sidecar；TUI 不解析 edit 参数；语法高亮与 `+N -N` chip 由宿主从 surface 计算（或读 surface 显式字段） |
| 取消标记文本 | `loop.zig` 四种 marker（interrupted / canceled executing / recording canceled / not executed）→ 识别成 canceled 卡片 |
| `emit` 溢出 | `tool_results[].spill_path` → 卡片尾部 "full output → path"，`o` 打开（`$EDITOR` / 展开读文件） |

### 2.2 内核改动之一：`nulya session step <id> --stream` `[已落地 · T0 → DESIGN §14]`

**协议与机制的真相在 [DESIGN.md](DESIGN.md) §14**（`loop.StepContext.observer` 纯观测钩子 + 行协议）。这里只留 TUI 侧的消费约定：

- 一行一个 JSON，写完即 flush；带 `stream` 字段 = 瞬态观测行，不带 = 与 `session events` 同形的 ledger 事件行（同一套 seq，可直接按 seq 入 items）。
- 行序（每个 step）：`started → text_delta* / thinking_delta* → tool_use_start / tool_use_input_delta* → done → tool begin/end* → 该 step 的 ledger 行 → step end`；整次调用最后一行是 `run done{steps,stopped}`（`stopped ∈ end_turn | budget | canceled | max_tokens`；被 `max_tokens` 截断的 step 的 `step end` 多一列 `"stop":"max_tokens"`，DESIGN §4）。见到 `step end` 就知道这一步的事件已全。**瞬态失败**（DESIGN §13）：一次尝试中途可能冒出 `{"stream":"model","event":"retry","attempt","max_retries","delay_ms","error"}`——这次尝试的 delta / usage 全部作废，内核退避后原样重发、再从 `started` 开始；`session.ts` 收到它就 `dropInFlight` + 回退 provisional usage，并把 "retry n/m in Xs" 放进 `error` 供 **transcript 末尾**的 `ErrorNotice` 显示（§4.2），下一个 `started` 清掉。
- `reasoning_item` 不出现在流里（不透明、只为回放）；thinking 的可显示文本只有 `thinking_delta`，turn 结束后从 ledger 的 `reasoning` 尽力抽（§4.2）。
- 诊断也是 JSON（`{"stream":"run","event":"error","message":"…"}` + 非零退出），所以 `nulya/cli.ts` 的解析器**永远**不必处理裸文本行。

**明确不做的内核改动**（放进 §10 待议）：`session new` 自动记 spawned-by；`session append` 打印投递回执；`<id>.live` sidecar。（`nulya config show` 与 `session step --gate` 当时也在这张单子上，后来都做了——前者因为前端不该复刻配置合并链，后者因为"前端自己发明审批"会让模型永远不知道自己被拒了，见 §5.7。）

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
│   ├── state/
│   │   ├── session.ts        #   一场 session 的视图状态：items（seq 键）、in-flight turn、pending appends、usage 累计、role（driver|observer）
│   │   ├── driver.ts         #   状态机 idle→appending→stepping→idle；run done 后若仍有 pending 未转正 → 再 step
│   │   ├── settings.ts       #   tui.toml 加载合并（user → project）
│   │   ├── tui_state.ts      #   tui-state.json：程序唯一写的文件（上次 /model 的 profile/model/effort）
│   │   └── tabs.ts           #   一 tab 一场：attachment + tab 级 effort；replace() 让空场就地换模型
│   ├── render/               #   渲染注册表：按 (tool, 命令前缀) 选卡片；这是唯一按名字 match 的地方
│   │   ├── registry.ts
│   │   ├── cards/            #   UserTurn / AssistantTurn / Thinking / ShellCard / ExtToolCard / PluginToolCard / EvolveCard / CapabilityBanner / SubSessionCard / CompositionCard / CanceledCard
│   │   └── theme.ts          #   tokens（§6）
│   ├── ui/                   #   App / Transcript / Composer / StatusBar / TabBar / columns.ts / list.ts / rows.ts（点击与 hover 的共享判断，T18）/ overlays(SessionsView, ExtView, ModelView, Help, Settings, Usage, Footer)
│   └── keymap.ts
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
    $ nulya src emit.zig                                            ▸ 212 lines · ok     (EvolveCard: 读内核源码)
    ⌘ edit · src/emit.zig                                                     (+2 -1)       (std plugin card, diff 默认展开)
      @@ -12,3 +12,4 @@
      -pub const head_bytes = 4096;
      +pub const head_bytes = 4096; // default, see OutputBudget
      +pub const tail_bytes = 2048;
    $ zig build test                                                ▸ 38 lines · exit 1  (ShellCard, 折叠)

  ⚙ ext build .nulya/extensions/lint → v-3f2a91                                          (EvolveCard)
  ⚡ capability · lint@v-3f2a91 · tools: lint_zig                                        (CapabilityBanner)

  ● 改好了，测试通过。要不要把默认值也写进 default.toml？▍                               (streaming)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 ⠋ shell · 3s · esc to cancel · ↑12.4k ↓3.1k cache 89%                            (WorkingStatus §4.4b)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 › 好，写进去_                                                                            (Composer)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 unsafe · claude-sonnet-5 (high) · tools 1+3                                       ctx 61% · step 4
```

**内容区是一棵 pane 树**（T68/T69，goals/tui-shell.md §5.1）：上面画的是它的退化形——一个 pane，一个 surface。`/sidebar`（`F8`，或状态行行首那个 `◧`）在它左边劈出第二个 pane，装 sessions 列表的窄宽变体（§5.4）；`Ctrl+←/→` 在 pane 之间移动键盘，`Esc` 从侧边栏回主 pane。**开侧边栏不移动焦点**，所以打字照常进输入框；只有人把键盘送进去，它才拿键盘（那一刻输入框的边框退回 `hairline`，§6.1 第 5 条那个唯一信号照常成立）。整屏 overlay（`F2`/`F3`/…）永远开在**主 pane**里，与键盘当时在哪无关。

四块：transcript（`scrollbox`，sticky bottom，鼠标滚轮 / PgUp / PgDn；离开底部时状态栏出现 `↓ new` 提示）、**输入框上面那一行**（0 或 1 行，只在有事发生时存在，§4.4b）、composer（`textarea`）、**输入框下面那一行**（1 行，§4.5）。没有边框，用两条 hairline 分隔；空状态首屏是一个小 wordmark（`ascii-font`）+ cwd + 几条 `/` 命令 + **一条 tip**（T38）。

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
| call `shell` | ShellCard | `$ 命令  (N lines[· exit N]) ▸`（exit 0 不写） | stdout / stderr 分段 | **折叠**；设定 `tool_output` |
| call `shell` `{background:true}` | ShellCard（后台变体） | `$ 命令  (background <sid>/t3 · running 12s) ▸`；报告到了换成 `(background <sid>/t3[ · exit N] · 41.8s)` | 回执原文（任务全名 + log 路径 + 三条命令） | **折叠**；**不加新 glyph**（还是那条命令，变的只有那一格 note） |
| `task_finished` | TaskFinishedCard | `$ 命令  (background <sid>/t3[ · exit N][ · killed] · 41.8s) ▸`（`exit 0` 照 T26 省略） | 输出 tail + 尾行 `full log → <path>` | **折叠**；一条事件一张卡，不是回执那张卡的更新 |
| 一串调用 | RunCard | `⋯ read ×3 · grep ×2 · shell ▸`（glyph 是 thinking 的三点、全程 dim、**没有 note**——一个 run 按构造就是"都成功了、没什么可给你看"，再写一格 `(6 calls)` 是同一句话说两遍，T26） | 展开就是原来那些卡，各自照旧折叠 | **折叠**；设定 `run_summary`。**进得去的**只有「跑完 + 成功 + 没有身体」的 `shell` / 扩展 tool，且至少两个；**进不去的**：还在跑的、失败的（含 `exit != 0`）、被取消的、回执型的（后台任务 / 子场）、`edit`、演化动作、`checklist`/`markdown`、包自己用代码画的卡，以及**任何声明了 `render` 的 tool**——那就是包说「我对这次调用长什么样有意见」，一个有画面要给的调用不该被概括（`render/runs.ts`） |
| diff surface（`std.edit`、`git_apply`、migration 等任意插件卡片） | PluginToolCard + host diff surface | `⌘ tool · path  (+2 -1[· failed])` | `tool_results[].presentation` 里的 diff surface（OpenTUI `diff`，语法高亮）；无插件或无 presentation 时退回普通 ext 输出 | **展开**；设定 `diff = expanded\|collapsed` |
| call `ext:*` | ExtToolCard | `⌘ tool_name · 参数摘要  (N lines) ▸`（**第一个参数不写键名**——工具的第一个参数就是它的主语：路径、模式、命令，T26） | 输出 | 折叠 |
| shell 命令前缀 `nulya src` / `nulya ext init\|build\|activate\|rollback\|run` / `nulya skill load` / `nulya session new\|append\|step\|events` | EvolveCard / SubSessionCard | 见 §5.2 / §5.5 | 原始输出可展开 | 折叠但头行信息量大 |
| `capability_note` | CapabilityBanner | `⚡ capability · id@version · tools: …` | note 全文 | 展开 |
| canceled marker | CanceledCard | `⊘ tool · canceled (side effects unknown)` 三种文案对应三种 marker | — | 展开 |
| `spill_path` | 卡片尾行 | `full output → .nulya/scratch/…` | — | — |
| （不是事件）`snapshot.error` | ErrorNotice | `✗ ` + 驱动侧最后一次失败的**原文**（provider 的 retry、`run error`、`step exited N`、`session new` 被拒） | — | 永远展开，在 items **之后**；下一个 `model started` 清掉 |

**`ErrorNotice` 不是 item**：它没有 ledger 事件、replay 也不会重现它，所以像 CompositionCard 一样待在 item 列表**外面**（一个在顶、一个在底），不必参与 `seq` 排序或 `dropInFlight`。它从状态栏搬下来，因为那一行只有一行、还要和 model / cost / chips 分：`error: model request failed (Transp` 就是所有人真正读到的错误的形状。换行由我们自己做（`wrapWords`，同 `ui/Fact` 的理由），状态栏只留 `error · see transcript`。

折叠交互**两种，不是四种**（T38）：鼠标在头行**按下与松开落在同一格**才切换（拖过去的是选取文本，不是点击，T18）；`Esc` 空 composer 时进 browse 模式（`j/k` 移动高亮卡、`Enter`/`Space` 切换、`Esc` 回 composer）。**`Ctrl+O` 与 `Ctrl+Shift+O` 已删除**：前者是第三种折叠方式、且作用于"碰巧是最后一张"的那张卡（说不出自己作用在谁身上的手势）；后者一次展开屏幕上每一张卡的正文，那不是任何一种视图。反方向留着：**`/fold` 全部折起**——读开了几张之后想要的正是这个。这一栏因此空了两个 `[keys]` 动作，见 §7。

### 4.3 流式与状态机（provisional → authoritative）

- 每次 `step --stream` 期间维护一个 **in-flight turn**：`text_delta` 追加到一个流式 AssistantTurn（只有这一块重排；已完成的 turn 是独立 renderable，不重解析）；`tool_use_start` 立刻建 tool 卡（`pending`）、`input_delta` 拼参数、`done` 后 parse；`tool begin/end` 切 `running → done`；`tool_results` 事件填输出。
- ledger 事件行到达 → 以 `seq` 为键写入 items，**替换**对应 provisional 项（文本应相同；不同以 ledger 为准并 debug 日志）。
- `user_text` 事件到达 → 与 pending appends 按顺序匹配转正。
- `run done` → 状态回 idle；若 pending appends 仍有未转正的 → 自动再 spawn 一次 step（用户在跑的中途发了话、但 run 已 end_turn）。
- 观测粒度就是 kernel 的粒度：TUI 不猜 "模型在想什么"，只显示流。

### 4.4 Composer / 按键 / slash

- `Enter` 发送；`Shift+Enter` / `Ctrl+J` 换行；`↑` 空 composer 时翻历史；粘贴多行原样。
- 发送时若 `stepping`：只 append（queued）；不打断。
- `/` 开头弹一个小补全：内建命令（`/model` `/mode [ask|unsafe]` `/effort <level|auto>` `/new [--profile p] [--model id]` `/sessions [<id>]` `/ext` `/tasks` `/usage` `/compact [focus]` `/outcome` `/with [<id>[@<v>]]` `/agent [<name> <task…>]`（§5.10）`/cancel` `/fold` `/settings` `/help` `/quit`；**`/mode` 从 T24 起是权限 mode**（T31 起裸 `/mode` 开一个 picker），带一个 extension 进这一场的那个 T36 起叫 **`/with`**——就是内核的 `session new --with`，一个概念一个词；中间叫过一阵 `/as`，那个名字仍然认（alias），理由与代价见 §11 T36；**`/clear` 与 `/resume` 分别是 `/new` 与 `/sessions` 的 alias**，都不上表——一个概念一个词，别处的词接到这里已有的那件事上就行；何况这里没有任何东西被 clear 掉（ledger 只能 append，新开一场就是新开一场），而 resume 也不是一个内核动词（append-only 让「打开它再说下一句」本身就是继续）。`/sessions` 从此收一个可选 id，两个名字**同一段代码**——alias 若走另一条路，它就不是 alias 而是第二个命令）在前，**activate 了的包自己声明的命令居中**（T39 的 `contributes.commands`；`/evolve` `/ask` `/plan` 都是这一档，T53），**activate 了的 skill 在后**（`nulya skill list`，描述截 100 字符）。分发同序：内建 → 包命令 → skill → 原样发给模型。`/<skill> [args]` = `nulya skill load <ref>` 拿到 body、包一层 sentinel 后作为**普通 user turn** append（T15；旧文本写的"nulya 没有 skill slash"已翻案——它把"谁触发"误当成了"谁判断"，理由见 goals/tui-panel.md D8）。
- `@` 开头（前一字符非字母数字下划线）弹文件补全：`↑↓` 选、`Tab` 上屏成 `@path`；已知引用在输入框里 accent。**上屏的是路径，不是文件内容**（T13）。
- 粘贴：> 1000 字符或 > 15 行折叠成 `[Pasted text #N]`，提交时展开回原文；`Backspace` 落在占位尾部整条删掉（T14）。
- 有 tool call 在等批准时（§5.7），**审批对话框拿着键盘**：`↑↓` / 数字键选答案、`Enter` 作答、`Tab` 在答案列表与 note 之间切、直接打字即写 note、`Esc` 在列表上 = deny（在 note 里先清空）。带 modifier 的键（`Ctrl+C`）照旧穿过去。
- 全局：`Esc` cancel（stepping 时）/ browse 模式；**`Ctrl+C` 由近及远，永远不在第一下退出**（T27）：输入框里有字 → 先清空（`ComposerApi.clear`）· 正在 stepping → 先 kill 这一步 · 都没有 → 先说一句 `Ctrl+C again to quit`，**再按一下才退**（提示 3 秒后失效，所以几分钟后的一下永远不是意外退出）。半条写了一半的消息、和整个屏幕，都不是第二次按键能撤销的东西；`main.tsx` 的 `exitOnCtrlC: false` 是这条链成立的前提。`Ctrl+L` 重绘；`F2` `/ext`；`F3` `/sessions`；`F4` 下一个 tab；`F7` `/tasks`；`Ctrl+W` 关掉当前 tab（最后一个不关）。
- 鼠标（T18）：列表行点一下落光标、点已选中的行执行它的 Enter；`/ext` 的 pane 条、`[x]` 与 id 行的开关记号、TabBar、状态栏的 `↓ N more below`、输入框都可点（点输入框也会退出 browse 模式）；拖过文本是选取，松手复制（OSC 52）。**模型这一行处处可点**（T20 → T22）：**输入框下面那一行开头的 `<model-id> [(effort)]`**、CompositionCard 的 `model` 值都开 `/model`；Welcome 的那几条 `/` 命令行、那一行末尾的 `/help` 也是按钮。所有可点的东西悬停都是同一个 `hover` 底色。
- **第一条消息才建 session**（T22，D11）：开屏是 draft，`Enter` 发送时先解 skill（`/name`）、再 `session new`、再 append+step。内核在这一步的拒绝（缺 key / store 未信任 / pin 认不出）**留在屏幕上**：notice 是内核原话，tab 仍是 draft，**打的字回到输入框**（`ComposerApi.restore`，只在框还空着时放回去——人在等的时候又打了别的，那是人的）。draft 上 `/outcome` `/compact` `/step` `/cancel` `Esc` 各回一句"这个 tab 还没有 session"，一个都不炸。
- `/model`（F5）与 `/provider`（F6）是**两个命令、两个问题**（T5 → T6 → T20 → T21，与 tcode 的 `/model` ÷ `/provider` 同一刀）：
  - `/model` **只有模型**：每个能跑的 provider 的每个 model 一行（`provider · label · id · ctx · ‹ effort › · ✓ current`），`h/l` 拨 effort、Enter 开新场；跑不了的 provider 不出模型行（这才是让表变短的东西），`provider` 那一列保证"这是谁家的模型"一眼可读。一个 model 的 ctx / effort 档位**先读该 profile 自己的 catalog**、没有才回落全局 `[[models]]`——同一个 id 在订阅口与公共 API 口是两个东西。一个 provider 都跑不了时只有一行 `no provider can run yet · /provider …`，Enter / `p` 就是过去。
  - `/provider` 是 **key 与 endpoint 的家**：一行一个 profile（`name · wire/endpoint · N models · 状态`），detail 行列出它的 model id（浏览不拦，拦的只是开一场），`s` 贴 key、`a` 加 compatible endpoint，codex 说 `codex login`；**Enter 在能跑的 provider 上 = 回 `/model` 并落在它的第一个模型上**——"先选 provider 再选它的模型"就是这两步。
  - 开屏没得跑时：还有别的 provider 能跑 → 开 `/model`；一个都跑不了 → 开 `/provider`（`launch.LaunchPlan.guideOn`）。
- observer 时空 composer 上的 `Enter` = take over（§5.6）；browse 模式里选中的卡若指名了一个 session，`Enter` 打开它成第二个 tab，`Space` 永远是折叠。

### 4.4b 输入框上面那一行（正在发生什么）

**在发生事情时才存在**（T38，`ui/WorkingStatus.tsx`；参考 tcode 的 `status_line`）。静息态它不占一行——不是写一句 `idle`，是**根本不画**。

分工是一句判断：**"这一场是什么"与"此刻在发生什么"是两个问题，被读的频率差一个数量级**。前者（model / mode / face / cost）读一次就信了，住在输入框**下面**；后者每过一秒都要再读一遍，之前挂在那一行的尾巴上——屏幕上**最少的列、最低的对比度**给了唯一一个活的事实，还逼着那一行常年留一格给 `idle`（一个"没什么可说"的词）。现在它自己一行，就在你要打字的那个框上面。

一行两段：**主段**（一个 spinner + 它是什么，`accent.assistant` 绿——正在跑的就是 assistant 那一轮，不是警告）· **尾段**（`dim`：`· 12s · esc to cancel · ↑12.4k ↓3.1k cache 89%`——**花掉多少也在这里**（T42：一个会变的总数，正是只在它变的时候值得读；静息态它下面那一行不再写它）；尾段窄屏时从末尾截，所以这三样的顺序就是它们该被丢掉的顺序。钟给一切在动的东西，`esc to cancel` **只给 Esc 真能停的那一步**（本 tab 正在 drive 的 step，`Activity.cancelable`）：`waiting for your answer` 底下写它是在提议取消一个已经停住的 step，`2 background` 或 observer 排队的 append 底下写它则点名了一个其实会进 browse 模式的键，而后台命令本来就活得过 step）。`12s` 的钟来自 `Driver.startedAt`（离开 idle 时打点、回 idle 清掉；observer 用它自己排队的时刻），**跟着动画那一拍重采样**——渲染里读墙上时钟就不是它输入的函数了。

**高光扫过**（`theme.shimmerColor`，逐条移植自 tcode `theme::shimmer_color`）：一条高斯软带从左扫到右，越过尾巴后停一拍再来。它**抬起每格自己的颜色**（朝 `theme.lift`）而不是覆盖它，所以绿的还是绿的、静止时每一格精确等于 base。`theme.lift` 是主题自己声明的（深色朝亮、浅色朝墨、`NO_COLOR` 就是 `fg` 因而整个扫描是 no-op）——"更亮"不是颜色自带的方向。实现上**一格一个 `<text>`**：`<span fg>` 是显然的写法，而 @opentui/solid 0.5.3 把这个 prop 丢掉、整段一个颜色（实测）；`Index` 而非 `For`，位置固定、字符在变。`motion = false` 关掉的正是这两样（spinner 与扫带），文字一字不变。

**什么会出现在这一行**（判据是纯函数 `activityOf`，一处定义）：等你回答的 tool call（warn，静）· `error · see transcript`（err，静）· observer 的 `press ↵ to take over` / `queued for the other writer` · `canceling` · **正在跑的 tool 名，没有 tool 就是 `thinking`** · `sending` · `step budget spent · /step to continue`（warn，静）· `reply cut off (max_tokens) · …`（warn，静）· 最后是 `N background`（可点 → `/tasks`，§5.9）。**其余一律 null**：idle、跑完了、被取消了——那些是静息态，transcript 里有它们的卡片。observer 的 `following` 也删了：那不是活动，是这个 tab 的身份，下面那一行右边写着。

### 4.5 输入框下面那一行

一行，四段（T22 起，标题行取消后它是"我在跟谁说话"；T35 把 mode 挪到行首、把 notice 从这场分配里拿走；**T38 把"现在在发生什么"整个搬去了 §4.4b**，于是这一行成了一句纯粹的静态描述）：

（**驱动侧的失败不在这一行**：`error · see transcript` 写在上面那一行（§4.4b），原文整段在 transcript 末尾，§4.2 `ErrorNotice`。）

**权限 mode**（`ask` / `unsafe`，**行首**，可点 → mode picker（**再点一下收起**，T42），§5.7；`unsafe` 是 warn 色；T35 之前它在最右边——那是一行愿意先丢掉的东西所在的位置，而它是屏幕上每个 tool call 被裁决的立场，该在 model 之前读到） · `<model-id> [(effort)]`（**主语**，`fg`，可点 → `/model`；effort 只在本 tab 明确选过时才写括号——`auto` 就是内核默认，为它花七列不值） · `tools 1+N`（`dim`；1 = 那一个 builtin `shell`，DESIGN §5.1；draft 上 N = 合并 config pin ∪ `tui-state.json` 的 `session_pins` ∪ **每一场都被组合进来的那些包（`apply: "auto"` / config `[extensions] with` / `tui.toml` `session_with`）active 版本的 `surface: "auto"` tool**，再 ∪ 那几个包声明的 `surface: "manual"` tool（由 `sessionExtras` 在 `session new` 那一刻 `--pin` 进去，T52——**今天这一半是空的**：`handoff` 与 `agent` 的入口 tool 都是 `auto`，两个都由前一半数进来了，T53；不算进来的话开屏就在说 `agent` 没启用，T42））。**token 累计从 T42 起不在这一行**——它搬去了 §4.4b 那一行，只在跑着的时候写（`state/session.ts` 的 `usageLabel`，来源仍是 ledger 的 `assistant.usage`；`/usage` 里是全部账）。右：`ctx N%` · `↓ N more below` · **`◈ <id>`**（这一场戴着的、contribute 了 system prompt 的包，`accent.evolve`，可点 → `/ext`；draft 读 `--with` 的 ref，已开场的读冻结 `contributions`——顶上那张卡默认折着，不写这一格就一个字都没有，T31） · `step n`（**跑过步才写**）· `observer · driven elsewhere`（§5.6；**只有例外说自己**——当写者是常态，`driver` 那个词在每个人的每一场里都一模一样，一格恒定的东西不是信息，T35）。离开底部时插入 `↓ 3 new`。

**没有的东西不占列**：没跑过步就不写 `step 0`（T35 之前连"一场还没花过钱"都要用十二列写成 `no usage yet`；那一格后来整个搬走了，见上）。**键位提示也不在这里了**（T38）：`Esc cancel · Ctrl+O fold · /help` 常年挂在这一行，是两头都输——一个永远在那儿的提醒过了第一个小时就没人再读，而它占的是屏幕上最挤的一行。它搬去了开屏那一屏，一次一条 tip（§4.1、`Welcome.tips`），tcode 的做法；`/help` 那个可点的 box 也随之删掉——开屏的 `/help` 那一行本来就是同一个按钮。

**notice 盖住整行，然后自己下去**（T35）。它曾经是这一行里再多一段、去抢剩下的列，于是"刚发生了什么"被挤进最后几列，而且**留在那儿**——`Ctrl+C again to quit` 在那个 offer 早已过期之后还挂着，`opened s-…` 挂一整场。现在：有 notice 就整行是它（`fg`），停留时间按长度算（`App.noticeHold`：`1500 + 45/字`，夹在 3 s–9 s），到点自己让位给静息态。下限 3 s 就是 `Ctrl+C again to quit` 落的地方，也正是那个 offer 有效的窗口——两者**由构造相等**而不是碰巧：arm 到期时同一处把这句话取下来。两个例外用 `holdNotice` 声明：browse 模式的键位提示与等着回答的 handoff 提议——它们不是新闻，是屏幕**正处在**的状态，各自的代码路径负责清掉。

**窄屏让位的顺序是一句判断，不是平均分**：mode 与 model **永不让**；再窄就丢 `tools`（上面的 CompositionCard 已经把工具面写全了）。notice 不参与这场分配（T35 起它拿整行），活动也不参与了（T38 起它自己一行）。

上下文占用（`ctx 72% · /compact`）只在 ≥60% 时出现、≥80% 转 warn 色。分母是 `[[models]]` 目录的 `context_window`（目录没写就整个不显示，不编分母）；分子是**最后一步**的 `input + cache_read + cache_write`——`provider.Usage.input_tokens` 是扣掉缓存之后的量，只读它会把一个快满的窗口报成几乎空的。它只是显示，不触发任何动作。

## 5. nulya 独有视图

### 5.1 CompositionCard（每场 session 的冻结契约）

来自 header：model identity（provider/model/base_url 主机）、`active[]`（ext id@version 短 hash）、`native_tools`、skills（从各 active 版本的 `extension.json` `contributes.skills` 读）、`parent`。这是"这一场模型看到什么"的一眼版本；打开两场对比就是演化的差分。

**它会折，且默认折着**（T25，设定 `transcript.composition`）：静息只有两行——标题（`session · <时间> · frozen composition`，右端一个折叠记号，与每张 tool 卡同一列）与 model 行（`model  <provider/model> · tools 1+N · skills n · prompts n · ext n`，模型本身仍是 `/model` 的点击目标，点击不冒泡到折叠）。展开后每根轴一行：`model`（这一行的右半换成 endpoint 主机）· `tools` · `skills` · `prompts`（贡献 system prompt 的包名）· `ext`（`id@v-` + 8 位）· `parent`。**版本哈希是 provenance，不是每场都值一屏的东西**——五个自带扩展的全串曾经在第一句话之前占掉八行。

**每一行都是"标签列 + 会换行的值"（`ui/Fact`），不是 flex 行。** OpenTUI 对超宽的 flex 行不换行而是**压缩**：名字从中间被切、标签与值之间的空格被吞，`model` 于是显示成 `mode`。所以窄屏的处理写死在两处纯函数里——值按 ` · ` 关节折到下一行（`wrapWords`），标题按整段短语退让（完整 → 去掉 `frozen composition` → 只剩 `session`），model 行的计数从最不紧要的一端整格丢弃而不是把 `ext 5` 切成 `e…`。

**draft 变体**（T22）：还没有 session 的 tab 上，同一张卡换个时态——标题是 `next session · set when you send the first message`，三行同序（tools = `shell` + 计划中的 pin、model = draft 的 pick 解出来的 model id、`--with` 写在 model 那行右边）。数据只来自 `config show --json`、`tui-state.json` 与 `ext list` 已经说过的东西，**没有第二个 composition 解析器**——真正的解析永远是内核在 `session new` 里做的那一次。

### 5.2 EvolveCard（演化动作在对话里的形状）

registry 按 shell 命令前缀识别，头行抽关键事实（抽不到就退回 ShellCard，永不报错）：

| 命令 | 图标 · 头行 | 抽取 |
|---|---|---|
| `nulya src [path]` | `⌕ read kernel · path` | 行数 |
| `nulya ext init [--script] id` | `⚙ ext init · id` | 路径 |
| `nulya ext build path` | `⚙ ext build · id → v-hash` | stdout 里的 version |
| `nulya ext activate id ver` | `⚡ activate · id@ver`（配对之后的 CapabilityBanner） | |
| `nulya ext rollback id ver` | `↺ rollback · id@ver` | |
| `nulya ext run id tool …` | `⌘ ext run · id/tool`（等同 ExtToolCard 语义，但走 shell） | ok / exit |
| `nulya skill load ref` | `☰ skill · ref` | |
| `nulya session new …` | `⤷ sub-session · <id>`（stdout 的 id） | id → 可打开 |
| `nulya session step <id>` | `⤷ sub-session step · <id>` | 同上 |

配色统一走 `accent.evolve`，与普通工具卡区分开：**演化动作是 nulya 的主角，一眼可辨**。

### 5.3 `/ext` 演化视图（overlay，`F2`）

左列：extensions（**开关记号** · id · **`standing`**（内核此刻正把这个包组进这台机器上每一场 session——判据是 `ext list` 那个 `standing` marker，即 activate 写进 `current` 的记录，**不是**前端去读某个版本 manifest 的 `apply`（T56）：`apply` 是**一个版本的声明**、只该拿来问「候选版本会不会 standing」，`standing` 是**内核记下的有效状态**、才答得了「现在是不是」；一个声明了 `apply: "auto"` 却没有 `current` 的包，standing 那一格是空的，右栏改说「激活它会把它组进每一场」。T52 起有这一格，T52 之前叫 `mode`，判据是「贡献了 system prompt」） · 半开时那半格 · draft 状态 · 被遮蔽的标 `shadowed`）——清单是 `nulya ext list` **∪ `ext sync --dry-run`（两个 root）**：`ext list` 只列"持有版本"的 id，所以**只有源码、一次都没 build 过的 id 在它里面根本不存在**（T22 的起因：`std` 躺在 user store 里 build 不出来，`/ext` 一个字都不提，唯一的痕迹是状态栏一句 `3 failed` 滚过去）。这样的行显示 `0v <kind>` + draft 状态（`not built` / `needs zig` / `fails`，warn 色），右栏把**内核那句话原样转述**（它现在自带绝对路径的修法），再加至多一行我们自己的（anyzig 那种 version shim 从 cwd 读 `build.zig.zon`，而 store root 里没有）。没有 `current` 的包（只用 `--with` 穿的 mode / evolution）读最新一次 build 的 manifest，否则它会被显示成空的。右栏（选中项）：第一行是**开关的文字版**（`id · kind · active|inactive · tools N/M pinned · current v-…`）、manifest 摘要、版本时间线（`versions/v-*` mtime，`current` 标记，本场 header 冻结的版本标记；两者不同 → `frozen v-a · store v-b → next session`）、该 ext 每个 tool 的 usage。

**`Enter`（或点开关记号）= 这个 extension 对下一场的总开关**（T22，D12）：
- **ACTIVE** = `ext activate <id> <version>`（版本取 sync plan 说 built 的那个，否则 store 里最新的 build；一个都没有就拒绝并指向 `b`）**+** 把它声明的 **`surface: "manual"`** tool 进本 TUI 的 pin 列（`extensions.pinsOf`，判据是冻结 manifest 的 `surface`，DESIGN §7.2.1）。**就这两样**（T52）：T48 曾经加过第三样——「standing with」，把 id 写进 `tui-state.json` 让每一场 `session new` 都 `--with` 它——那半**整个删掉了**，因为「这个包该不该在每一场里」现在由**包自己**说（顶层 `apply: "auto"`，DESIGN §5.1），而内核对每一个 driver 都照做；一个前端在旁边另记一张私单，就是同一个问题的第二个答案。`surface: "auto"` 的 tool 不写 pin：包一进 composition 它就在模型面前，而一根指着它的 pin 会被整场拒绝（`PinToolNotPinnable`）。**「active」说的是 store 指针与可用性——这个 id 现在指哪个版本、`/with`/声明的命令穿不穿得上——不是「下一场一定带着它」**（T55）：那句保证只有 `standing` 那一格能给，而它的真源是内核的记录（T56）。
- **INACTIVE** = 先把它的 tool 从本 TUI 列**和 user config 的 `always`** 里撤掉（别的 config 层写的撤不了，点名说出来），再 `ext deactivate`。顺序是有意的：pin 指着一个没有 `current` 的 extension，`session new` 是**整场拒绝**（pin 蕴含成员、而没有 `current` 可带，`WithVersionNotFound`），所以先撤引用、后撤指针，中间任何一刻的世界都是合法的。`ExtView.dropOrphanPins` 与 `App.healStandingPins` 修的是已经写坏的文件。对一个 `apply: "auto"` 的包，`ext deactivate` 正是**唯一**的收回方式（没有 `current` 就不在任何一场里），notice 因此说的是 `<id> inactive · it leaves every session composed here`。
- **一个 contribute 了 system prompt 的包是"模式"，Enter 对它的意思和对别的包完全一样——让它可用**（T31 点名它、T48 一度把它并进 standing with、**T1 把那半撤回**，ext-review-2 §3b）。它换来的是一条声明的命令（`extensions.wearCommand` 读该包 manifest 里第一条 `{with: true}`，T54）：Enter 的 notice 是 `` <id> active · /<name> opens a new tab wearing it for one session · Enter again takes that away ``（没声明命令的包指 `/with <id>`），INACTIVE 对称地说 `` <id> inactive · /<name> is gone · versions all stay ``——两句都不提"EVERY session"，因为这一行不造成那件事。**T52 起「会不会波及每一场」由 `standing` 那一格独立回答**（`apply: "auto"`）：一个 `manual` 的 prompt 包离每一场很远，而一个 `apply:"auto"` 的纯 tool 包就在每一场里——「贡献了 system prompt」从来只是在没有包能自述 reach 的年代对这个问题最接近的猜法。detail 里那句"a mode"的说明（`` `/<name>` wears its prompt for one session ``）只画给 `manual` 的包（判据是**声明** `apply`——这句讲的是按 Enter 会怎样），`apply:"auto"` 的包由下面两句之一接手：已经 standing 的是"composed into every session"，还没有 `current` 的是"activating it composes it into every session started here"（T56），三句永不同时出现。**一个模式常驻每一场仍然可以**：包自己写 `apply: "auto"`、config 写一行 `[extensions] with`、或 `tui.toml` 的 `session_with`——detail 里那句 `composedEverySession` 照旧点名是**哪一张**放的（三处撤销的地方不同）。
- **看得见**：`●`/`○`（ascii `*`/`-`）+ 三档色——`ok` 全 active、`warn` 半 active（另配一格 `3/5 tools` 或 `pins only`）、`faint` inactive。tools pane 的 `[x]` 用同一套色（一处颜色一个含义，§6）。**两个方向都不要 `y` 确认**：都是指针 + pin 的移动，同一个键就能放回去，且够不着已经开跑的那一场（physics #2）。
- 两根轴仍然在：单个 tool 用 tools pane 的 `Space`（`A` 升 `always`），单个版本用版本线的 `a` / `r`（仍带确认——它们点名一个 build，是时间线上的动作）；`d` **删掉了**（它就是 INACTIVE 的一半，两个键做一件事正是被修的那个毛病）。

**tools pane 只列有 checkbox 的行**（T33）：internal tool（**包自己在 manifest 里声明 `surface: "internal"` 的那些**，DESIGN §7.2.1；T34 之前是这里一张按 id 写死的名单，T52 之前那个词叫 `driver`）折在列表下面一行里——`▸ N internal tools · called with ext run, never on the model face · d shows`，`d` 或点它展开。判据是 `internal && 没有 pin`：一个真被 pin 上的 internal tool 照常显示，因为那是这张表能撤回的状态。展开状态不记进 `tui-state.json`（是好奇，不是设定）。**`surface: "auto"` 的 tool 留在列表里但没有 checkbox**（`auto · with the package`）：它已经在模型面前，只是不由这张表决定。

其它动作键：`b` build 选中 id 在它 store 目录里的源码（`ext build <root>/<id>`，落哪个 root 由内核按路径决定）；`p` = `ext prune <id>`（带确认，成功后显示内核自己那句代价说明）。底部常驻句按 tab 有没有 session 分两种：有 → `changes apply to the NEXT session — this one froze its tools at start`；draft → `changes apply to the session this tab is about to start`。第四块 pane：全部 tool 的 usage 表（只投影 `.nulya/tool-usage.jsonl`；**不**复刻排序算法，"下一场谁晋升"留给未来的 `nulya composition preview` CLI，见 §10）。

### 5.4 `/sessions`（overlay，`F3`）

`nulya session list --json` 按 `created` 倒序，**一行就是那一场的第一句话**（T47）：第一条 user_text（拿走这一行剩下的全部宽度；一句都没说过的场自己写 `nothing said yet`） · `parent` 缩进成树 · 是不是眼前这个 tab（`▎ this tab`） · 最新 verdict（`+ success` / `~ partial` / `! failure`；**没有行就什么都不画**——unjudged 不是 failure）· 有别的写者持锁 → `● live` · **最右一列是多久以前**（`just now` / `12m ago` / `3h ago` / `2d ago`，一周以上退回 `MM-DD`）。`n` 新建；`r` 刷新；`d` 无（不删，ledger 只 append——想清理用文件系统）。**`/sessions <id>`（`/resume <id>` 是它的另一个名字）是同一个动作的点名形态**（T45）：走的是 `Enter` 那一个动作，屏幕里第一次有办法按 id 找回一场（在此之前只能带 `--session` 重开进程）；裸的那个不长第二张表，就是这一张。

**一次点击就地切过去，两次才多开一个 tab**（T70）。`Enter` / 单击 = **当前这个 tab 变成那一场**（已经有 tab 的前置它，否则 `tabs.replace` 就地换掉——**tab 条不因此变长**）；`t` / 双击 = 额外给它一个 tab。终端没有原生双击，只有两次松开和一口钟（`double_click_ms = 350`），所以**单击的动作要等窗口关掉才发**：先切再补的写法在这儿不成立——切换**吃掉的正是**第二次按键想保住的那个 tab（切完之后这一场已经在眼前，`onOpenTab` 只会把它选中一次），要让这一对有意义就得把刚替换掉的东西放回去，而 draft tab 根本放不回去、session tab 要付一次 `session events` 重放。不等的那一半是**光标**：它落在按下那一刻，所以点击在同一帧就有回应。窗口内的第三次按下开一个新窗口而不是再触发一次（连点的人是还没看见任何事发生的人，一次一个 tab 是对这件事最没用的读法）。

**默认不显示 sub-agent 的场**（T70）。判据是**冻结 header 的 inline prompt `source` 带 `agent-` 前缀**（`personaOf`，`agents.ts`——`wearing()` 读的同一条约定，前端只有这一份实现）：委派出的子场是真 session、`session list` 投影它是对的，但它不是谁开的对话、也不该从这儿给它发消息，而一个会委派的 workspace 里它们数量是真对话的几倍。整屏那个的键行末尾加一句 `N agent sessions hidden · a shows`，`a` 开关；显示时这些行戴 `◈ <persona>`（rail 上只戴字形——18 列里名字要从句子上割）。**过滤发生在建树之前**（`partitionSessions` → `sessionRows`）：被藏起来的父亲不会把孩子留成一层没有上级的缩进。这是投影层的 policy，**内核零改动**，`/sessions <id>` 与 `session list` 一个都没少。
**一行上只剩「说了什么」与「多久以前」**（T45 删掉 model 与 token 两列，T47 删掉 id、事件数与 `with` 列）：这张表回答的只有一个问题——「刚才那场是哪一个」，而没有人靠「6 events」或「with agent ask compact guide handoff std」认出一场对话；一个 workspace 里几乎每一行的 model 和 `with` 还都一样，**分不开任何东西的列不是信息**（§4.5 那条「没有的东西不占列」的同一把尺子）。删的都是**这一处的显示**、不是任何事实：composition 冻在 header 里、`/ext` 与开场那一行都说得出，花费在 `/usage` 与 ledger 里一分不少，事件数则是 `Enter` 进去就看得见的东西。省下的宽度全部给第一条 user_text（它在 T45 之前还有个 40 字符截断，正是被那些列挤出来的）。**`0 events` 唯一还在承载的意思由一句话接手**：一场什么都没说过的 session 自己写 `nothing said yet`。
**id 不在行里，印在标题行上**（T47）：它是这张表里唯一一样人读不出、却偶尔必须粘贴的东西（`nulya session events <id>` / `/outcome` / 发给别人），所以只印**光标那一行**的那一个，跟着 `j`/`k` 走。它挨着 `sessions · N` 而不是靠右边距：id 的 hash 不定长，右对齐等于光标每动一下整行跟着动（T12 那个尾空格 bug 的同一个形状，往上挪了一行）。
**时间改成「多久以前」，并画在整行最右**（T47）：`08-16 09:12` 是个时间戳——正确，而读的人还得拿它减一次今天，才能得到他唯一想要的那个答案；一周以内说距离，超过一周距离不再好记，退回 `MM-DD`。画在 chip **后面**是为了让它真的是一列：chip 时有时无，一个会被 chip 挤得左右移动的钟不是列。列宽取当屏所有行里最宽的那个（`just now` 与 `3d ago` 不一样长，写死一个数字迟早对不上）。
列表本身一次进程 + 读全部 session 文件，所以 8s 刷一次；`● live` 只是锁探针（不开进程），1.5s 刷一次。
**同一张表还有第二种呈现：docked 变体**（T69）——`/sidebar` / `F8` / 状态行的 `◧` 把它停在屏幕左边缘的一个 pane 里（缺省宽度 1/4，`/sidebar <percent>` 改）。同一个组件、同一批 rows、同一个光标、同一条点击的法条（T70 起：单击就地切、双击多开一个）；变的只有宽度，以及**宽度决定一行上还剩什么**（`sidebarRowPlan`：钟 → verdict → `● live` → `◈ 这是委派出去的` → `▎ 就是这一个`，按这个顺序让位，第一句话永远留得下 8 格）。它底下那一行也是按宽度选出来的（`railFooter`：候选串由长到短、第一个装得下的胜出；键只在它拿着键盘时才是真的，**被藏起来的行数两种情况都要说**——少一个键在 `/sessions` 与 `/help` 里都还找得到，一张悄悄比 store 短的列表没有第二个地方能说自己短）。它**不**替代整屏那一个：整屏是键盘的读法，rail 是鼠标与余光的读法。刷新更慢（列表 20s、锁探针 3s——overlay 只在有人看的时候在，rail 整天都在），但前面那个 tab 一换就立刻重读。

### 5.5 Sub-agent

**委派从属于开它的那场对话，所以它的观察面是父 tab 里的一块 pane，不是 tab 条上的兄弟**（T72，`goals/tui-shell.md` §5.3c）。

- SubSessionCard（§5.2）上那一行 `↗ watch <d-id 或 s-id> here` 是**默认路线**：在**当前 tab 内部**开一块 sub-agent pane（≥100 列左右分、窄屏上下分，子面 0.4），browse 模式 `Enter` 同语义。**显式开成 tab 仍在**：browse 模式的 `t`——与 `/sessions` 里「`Enter` 就地切换 / `t` 给它一个 tab」同一套词（T70）。卡上不放第二条链接：一张卡为同一个去处挂两条几乎同文的行，每个委派都要付。
- pane = **现有 observer transcript**（§5.6）：只读跟随、`claimsKeyboard: true`（聚焦才拿键盘，开出来不拿）、`<id>.lock` 探针与 `SessionBusy` 语义一概不变，workspace 用**父 tab 的**（委派出去的子场就在那个目录里）。
- **归属写在头一行**：`⤷ <persona> · <d-id 或 s-id> · observing`（dim；persona 从子场冻结 header 的 `agent-*` prompt 经 `personaOf` 读出来——与 T70 的列表过滤同一处实现）。`observing` 是**常量**，说的是这块 pane（没有输入框、什么都送不出去），不是那一刻的租约角色。
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

### 5.8 模型自己提的 handoff `[T24]`

`extensions/handoff` 的 tool 只做一件事：把 brief 渲染成 `.nulya/handoffs/<session>-<n>.md` 并叫模型收尾（DESIGN §11）。**那个文件就是提议**——没有 JSON 要解析，也还什么都没发生；fork 是**驱动者**的动作，`drivers/goal.*` 不问就 fork，这个前端在 `ask` 下先问（旁边就有个人）。

- **进 composition**：draft materialize 那一刻按 `[extensions] session_with`（默认 `["handoff", "agent"]`，T34；T52 起那两个老布尔键不再读）加 `--with handoff@<v>` + 它每个 `surface: "manual"` tool 的 `--pin`（两根轴，DESIGN §7.5：`--with` 是成员，`--pin` 才给它一个 native 槽）。**这张单子上的两个包今天都不需要 pin**（T52 / T53）：`handoff` 与 `agent` 的入口 tool 都声明 `surface: "auto"`，成员关系本身就是它们上台的路，而指着它们的 pin 会被整场拒绝（`PinToolNotPinnable`）。`SessionMember.pins` 那一半留着——它从**正在被组合的那个版本**的冻结 manifest 读，所以哪天某个包把一个 tool 挪回 `manual`，这里不用改一个字就跟上了。版本由 `extensions.sessionMember` 拿（`bundledDraftPath` → `ext build`，所以**不在 nulya checkout 里也能用**：二进制自带源码，seed 进 user store 再 build）；build 在开屏后台起、失败就这一场不带它并照常开场——**装不上不是开不了场的理由**。局限：第一次在一台机器上要付一次编译（compiled 包）。
- **看盘的时机**：每个 step 结束（driver 回 idle）看一次 `.nulya/handoffs/<id>-*.md`，与 `drivers/goal.*` 同一个信号；已处理过的路径记在内存里，同一个提议不会问第二遍。
- **`ask`** = brief 显示在 transcript 与输入框之间（**不是 transcript 卡片**：brief 是磁盘上的制品不是 ledger 事件，这个前端只画 ledger 有的东西），`Enter` 跟过去 / `Esc` 收起（文件留着）。**`unsafe`** = 直接跟，一行 notice。
- **跟过去 = `/compact` 的 `brief_file` 分支**（DESIGN §11）：同一条 fork，只是摘要已经写好了，旧 session 逐字节不变，tab 换到子 session——与 `/compact` 完全同一段代码（`compact.ts` 多一个可选参数）。

### 5.9 后台任务：内核给 supervisor 与事件，屏幕决定何时再 step `[T29]`

内核那一半已经全在（DESIGN §6.1 / §3.1）：`shell {background:true}` 起一个脱离 step 进程的命令并立刻回执，supervisor 看着它跑，结束时把 `task_finished{task, exit_code, text}` **投进这场 session 的 inbox**，下一个 step 边界排干、进 ledger、模型读到。少的只有一件事——**谁来开那一步**。何时继续从来是 driver 的 policy（physics #8，goals/background.md D8），所以这块屏幕补的就是这一条：

- **唤醒判据是四个词：driver 角色 + 这场是本进程驱动过的 + `status() === "idle"` + `<id>.inbox/` 非空**（`state/driver.ts` 的 `wake()`，唯一的新 policy；"驱动过"= 本进程 `session new` 出来的，或从这个 tab 发过消息 / step 过 / `↵` 接管过——`attach.ts` 的 `driven`）。四点都承重：
  - **"驱动过"挡的是一个窄而后果重的窗口**：一个刚打开的 tab（SubSessionCard 的 `Enter`、`/sessions`）角色缺省是 driver，第一次探针之前它分不清"没人驱动"与"别人正好在两个 step 之间"——而 inbox 非空恰恰发生在那个别人的 `task wait --any` 刚返回、还没来得及 `session step` 的一瞬，我们抢先一步，它的下一步就是 `SessionBusy`，一个 driver 脚本会就此退出。所以没人要求的那一步只在**我们已经是它的驱动者**的 session 上发生；打开一场旧 session 只看不说，第一条消息才把它变成我们的（`tasks.test.ts` 两条钉住）。
  - 判据是**inbox**，不是"某个任务 done 了"。任务结束只是让 inbox 非空的来源之一，别的终端 `session append`、`ext activate` 的 capability note 都算；反过来，**inbox 为空时绝不裸 step**——那会把上一条 assistant turn 当 prefill 重发（DESIGN §4），不是"继续"，是关于谁最后说话的谎。
  - 轮询搭 `probeWriterLease` 那个 idle 定时器的车（`state/attach.ts`，默认 700 ms），**不另起第二个**：它本来就是"我们坐着不动的时候世界干了什么"的那一拍，而多一个定时器只是多一个要停的东西。
  - **observer 不踢**（角色判断留在 `attach.ts`，`driver.ts` 只回答"inbox 里有没有东西"）：那个 inbox 由持锁的写者在它自己的下一个 step 边界排干，两个写者正是 durable session 唯一拒绝的事（DESIGN §3.4）。
  - **`ask` 模式照踢**：模型只是去读一个结果，它接下来每一个 tool call 仍然逐个过 gate（§5.7）。
- **`nulya task list --session <id> --json` 是任务面的唯一数据源**（`state/tasks.ts` 一个 per-tab 的 watch：tab 打开读一次、每个 step 结束读一次、有没 done 的任务时每 1.5 s 读一次；一个从没起过任务的 session 只付开场那一次）。`starting` / `lost` / `elapsed_s` 全是内核算好的投影，TUI **不复刻**——它们要同时读任务目录与那把锁，第二份实现迟早跟唯一算数的那份说两样话。
- **两张卡**（§4.2）：ShellCard 的后台变体（同一个 `$`，note 换成 `background <sid>/t3 · running 12s`）与 `task_finished` 的 TaskFinishedCard（`$ 命令 (background <sid>/t3 · exit 1 · 41.8s)`，体是输出 tail + 尾行 `full log → …`）。两者靠**全名** `<sid>/t<N>` 连起来：回执首行写了它，事件里又写了一遍，所以 `session.ts` 排干那条事件时按名字找回发起它的那张卡并记下 exit 与耗时——**重开一场也照样显示**，不靠任何进程。"还在跑几秒了"这种没法 append 的事实才走 live 投影（`TasksContext`）。
- **状态栏**：有没 done 的任务就在活动区写 `⠋ 2 background`，**driver idle 时也写**——任务活得过 step，一条正在跑的命令是那一刻唯一还在发生的事，说"idle"才是假话。它排在两个 stop reason（都要人按一下键）之下、其余静息状态之上；点它 = `/tasks`。
- **`/tasks`（F7）**：一行一个 `<sid>/t<N> · state · 用时 · 命令 · 怎么结束的`；`Enter` 看 log 的最后 64 KB（跟着面板的 1.5 s 轮询重读，**不求真·live tail**——那要一个常驻进程，而人想知道的"它现在在干什么"重读就够）；`k` kill（不二次确认：杀错了重跑一次就行，杀不掉的任务才是没有 undo 的那个），`K` 杀掉所有还在跑的；`r` 重读。**这是全前端唯一 `j/k` 不是移动的列表**——`k` 在这里是 kill(1) 那个动词，光标只认方向键，footer 写明白；一个键在五个面板里移动光标、在第六个面板里毁东西，是两种不一致里更糟的那种。
- **`/quit` 不杀**：有还在跑的任务就先说一句 `N background tasks keep running; their results land in the session inbox`，再 `/quit` 一次才走。离开这个前端不该停掉一个 detached 的进程（内核里也根本没有"session 结束"这个概念）；结果会在 inbox 里等下一个 step。要停就去 `/tasks` 按 `K`。
- **不做**：跨 tab 的任务汇总视图（`/tasks` 只看当前 tab 的 session，整个 workspace 的答案是终端里的 `nulya task list`）；后台输出实时进 transcript（log 文件 + `/tasks` 就是观察面）；任何"自动清理"或退出时杀任务。

### 5.10 Sub-agent：一个定义文件，就是一组 `session new` 参数 `[T32]`

PLAN §3.2 早就把答案写死了——**一个 agent 就是 `session new` 的一组参数**，`AgentDef` 不进 kernel。所以这一块从头到尾没有一样新东西是内核给的：定义是一个 markdown 文件，正文渲染成一个 prompt 文件、`--prompt` 冻进 header（**T44**；从前是材料化成 data extension 再 `--with`），`--pin` 给工具面，`--max-steps` 给预算，readonly 由 gate 兜住。

- **定义在哪**：`.nulya/agents/*.md`（workspace）与 `~/.nulya/agents/*.md`（`NULYA_HOME` 整体搬走，与内核 config 同规则）。**只认一层平铺、只认 `.md`**——`agents/` 是一列 persona，不是要组织的树；同名 workspace 胜出，输的那个**点名报出来**而不是静悄悄丢掉（"我在改的是哪一个"必须答得出来）。坏定义 **warn-and-skip 不致命**（tcode 同款纪律）：只有"没有 front matter"与"没有正文"两种情况会被跳过（那正是"不是一个定义"的两种含义），其余每一条读不动的字段都是一条警告 + 一个缺省——为一行坏字段丢掉整个 persona 是贵的那个答案。
- **front matter 的每个字段都是 `session new` 的一个参数**：`name`（缺省 = 文件名 stem）· `description`（picker 里那一行）· `readonly`（见下）· `model`（`profile` 或 `profile/model-id` → `--profile` / `--model`；不写就继承发起它的那个 tab 的模型——一个不在乎跑在哪的 persona 不该把活悄悄挪到内核缺省上）· `pins`（`ext:<id>/<tool>` 数组，逐个 `--pin`；**形状不对的一律丢掉并警告**，因为一个解不出来的 pin 不是少一个工具，是整场 `session new` 被拒）· `max_steps`（该 tab 的 `session step --max-steps`）。**正文就是 system prompt，逐字**。
- **渲染 `[T44]`**：定义正文写成 `.nulya/scratch/agents/agent-<name>.md`，`session new --prompt <它>` 把**字节**冻进那一场的 header（DESIGN §3.4 / §5.6）。**什么都不安装**：没有包、没有版本、`/ext` 里不多一行，`ext prune` 也拿不走某一场赖以 resume 的身份文本。**每次都写**（`/evolve` 同款理由）：内容由定义决定，没改就是同样的字节，改了下一次 `/agent` 自动拿到新的，没人需要记得重 build；两次委派同时写也无害。落 `.nulya/scratch/agents/`，**刻意不在任何 store root 里**——它是隔壁那个真正被维护的文件的一次渲染，不是有人在维护的包。**从前它是 data extension**（id `agent-<name>`、`--with` 戴上、永不 activate）：那把一段 per-session 文本做成了安装物，`/ext` 里长出一排派生包，而 `ext prune` 能删掉某一场的身份文本。`agent-` 这个前缀留下来了，但它现在**只是那个包自己的写/读约定**（`render` 写这个文件名、`wornPersona` 从 header 的 `composition.prompts[].source` 剥它），内核对这个标签一无所知。
- **trust 问句**（`main.tsx` `askAboutCheckout`，与同一次开屏的 store 问句共享同一时刻、同一"只问一次"纪律——两边都要问时 `extensions.planCheckout` 把它们合成**一句**而不是两句先后问，T2，ext-review-2 §3b）：随 checkout 到达的 `.nulya/agents/*.md` 要答一次才能用。**两个理由，第二个有牙**：① 一个定义就是一段 system prompt，用它 = 让别人写的 persona 拿着本 workspace 的工具说话；② 一次委派会把自带的 `agent` 包 build 进本 workspace 的 extension store，而**本机 build 填满空 store 就是信任**（DESIGN §9）——问句晚于第一次 build，就等于替 checkout 签完名再问。单独问时两个键（`t` 信任 / `n` 现在不），问在屏幕出现之前；与 store 问句合成一句时借用它的三键形状（`t` 信任两者 / `s` 只 build 扩展、两者都不信任 / `n` 都不动）。答案记在 `tui-state.json` 的 `asked_agents` / `trusted_agents`，与从前一样——合并的只是屏幕上问的那一下，不是记录的地方。`~/.nulya/agents` 永不问（与 user store 同理由：没有人放，它不会自己到那儿）。
- **`/agent <name> <task…>`**：渲染 →（`session new --prompt <渲染出的文件> [--with]* [--pin]* [--profile/--model]`）→ **开一张看得见的新 tab** → append task → TUI 照常以 driver 驱动（`--gate --stream`，`max_steps` 生效）。看得见是有意的：一个跑歪了的委派，得有人能看、能 `Esc`、事后能读。**裸 `/agent` 是 picker**（`ui/AgentPicker.tsx`，与 `/mode` `/model` 同一套对话框：`◈` 标题、`ui/rows.ts` 的光标与悬停、数字键、`Enter`、`Esc`，在的时候拿键盘）——**选中一行不启动任何东西**，只把 `/agent <name> ` 写进输入框：委派需要一个任务，而任务没人猜得出来，一个替人编了任务就开场的 picker 是前端往别人嘴里塞话。
- **`readonly` 是一道天花板，不是一条规则**（agents-and-review §1 不变式 1）：它在**三张表之前**问，且任何东西都掀不动它——一条 `[approvals] allow` 悄悄把 `shell` 放回一个 read-only persona，就是这个功能唯一会变成谎话的形状。两条：`shell` 一律拒（没有 OS sandbox 就分不出 `cat foo` 与 `rm foo`，同 §1 不变式 5）；extension tool 只放行**自己的冻结 manifest 声明了 `"readonly": true`** 的（DESIGN §7.2.1 那个声明是包的自述、内核不强制，**信不信是这条 policy 的选择**，`[approvals] manifest_readonly = false` 是不想信的人说话的地方）。拒绝走内核 gate 的 `deny <note>`，所以**模型读得到自己为什么什么都没跑**，而且那是那个 call 的 `tool_results`，在 ledger 里（DESIGN §4）。**这不是安全边界**，和 §5.7 最后一句是同一句话：真隔离等 sandbox（PLAN §3.8）。
- **模型自己委派：`agent{name|session, task}`，回报走后台任务**（`session` 形态 = 往一场已经报告过的子场再送一轮，append-only 命中它自己的前缀缓存；能不能委派由被委派者定义里的 `agents` 白名单决定，空 = leaf。两者的门与理由见 DESIGN §7.8）（`extensions/agent`，DESIGN §7.8/§11）。这一半**前端零新机制**：`agent{name, task}` 起一个**属于父场**的后台任务去驱动子场，任务结束时 supervisor 把 `task_finished` 投进父场 inbox——而"driver 角色 + idle + inbox 非空 → 再 step"（§5.9 T29 唯一那条 policy）本来就在跑，所以报告自己会到，**没有第二个看盘的钩子、没有新的面板、`drivers/goal.*` 一个字没改**。第一版规格是"写请求文件 + 每步之后看盘"，否掉的理由是它等于给每个 driver 发明一份要重学的盘面约定（且跨平台两份实现），而内核已经有且只有一个"欠答案"的回路。
  - **带入条件两条，都刻意**：`--with agent@<v>`（T53 起没有 pin——那个 tool 是 `surface: "auto"`，成员即上台）**只在这个 workspace 真的有 agent 定义时**才加（一个只会答"没有人可以委派"的 tool 照样占一个 `max_tools` 槽与每场的前缀 token，PLAN §3.4.1），且**只加在顶层 session**——委派出去的子场不带它，所以子 agent 不能再委派（leaf，agents-and-review §1 的 `SpawnPolicy` 最小形态）。
  - **渲染只有一处实现**：`ext run agent@<v> render --arg name=<n>`，它写文件并回一整组 `session new` 参数。TUI 的 `/agent` 也调它——两份实现就是同一个 persona 的两种读法；TS 侧只留**读**（发现、列表、picker）。
  - **卡片**：`agent` 这个 tool call 在 registry 里是一张 **subsession 卡**（`⤷ agent · <name> → <子 id>`），子 id 取自**回执**而不是参数——调用返回前那场 session 还不存在，与 `nulya session new` 经 shell 的那一行同一个手法。**T43 起它自己一张卡**（`SubSessionCard`）：note 说那个后台任务在怎么样（`s-1/t1 · running 42s` → 报告到了变成 `· exit 0 · 41.8s`，与后台 `shell` 同一套读法），头行下面一行 **`↗ open <id> in a tab`** 点得动——与 browse 模式 `Enter` 走同一个入口（`state/navigate.ts`）。
  - **600 s 天花板**：`run` 经 `ext run` 调用，而 `ext run` 强制 manifest 的 `timeout_ms`、上限 `tool.Timeouts.extension_max_ms`（`src/cli/ext.zig`），manifest 顶格要满。将来解除不用改设计——换一种任务命令形态即可。
- **定义分三层，什么都不写也有三个能用的**（DESIGN §7.8）：`.nulya/agents/*.md`（workspace）> `~/.nulya/agents/*.md`（user）> **包自带的 `explore` / `plan` / `general` / `orchestrator`**（`extensions/agent/src/builtin/*.md`，`@embedFile` 进那个包的二进制，随它一起分发）。**首个持有者胜，输的那个照样列出来并标 `shadowed`**——与 store roots 同一条规则、同一个理由。四个 persona 移植自 tcode，`ask_user` 与 tcode 那些我们没有的 frontmatter 是**删掉**而不是翻译；`orchestrator` 是唯一带 `agents` 白名单（可以委派）的那个，其余三个都是 leaf。
- **读也只有一处实现**：`ext run agent@<v> list` 返回全部定义（name / description / readonly / layer / shadowed / pins / max_steps / warnings）。TUI 的 picker、readonly 天花板、委派参数**全部读它**——TS 侧一行 frontmatter 解析都没有。理由与写路径同款：两个 parser 就是"这个 agent 是不是 readonly"的两个答案，而那正是天花板要变成一次拒绝的那个问题。**唯一的例外是 trust 问句**：它问在屏幕出现之前、任何 build 之前，所以它读的是**文件名**（`workspaceAgentFiles`，一次 `readdir`），不是定义——"这个 clone 带来了定义吗"本来就是关于名字的问题。
- **pin 蕴含成员（2026-08-23，ext-review lane B）**：一个 pin 把它自己的包带进 composition（取 `current`，DESIGN §5.1），所以委派**不再**为 pins 派生 `--with`、`render` 也不再预验证它们——从前那段派生与 `ext list` 预检（T32 第三期）整个删掉了。包没有 `current` 时是内核的 `session new` 在 stderr 点名"这些是 pin 带进来的、其中一个没有 `current`"并给出 `--with <id>@<v>` / `ext activate` 两条出路；TS 侧只是把那句原样转述。两条委派路径（模型的 `agent` tool 与 `/agent`）因此都不再有自己的一份"包装好了没有"判断。
- **`◈ agent-<name>` 白拿**：戴着的东西在 tab 标题与状态栏那个 chip 上本来就看得见（T31 的机制），不需要为 sub-agent 加第二套显示。T44 之后 `wearing()` 多读一处——header 冻的 `composition.prompts[].source`——因为按同一把尺子，那也是这一场戴着的一段 system prompt，只是它不属于任何包。

### 5.11 每个 tab 一个 workspace `[T71]`

跨目录的对话（goals/tui-shell.md §5.3b）。**内核零改动**——session 本来就属于它被创建的那个目录，`Workspace` 一直是 `nulya/cli.ts` 每个调用的显式参数，S1c 只是把它从 store 级下放到 tab 级。

- **tab = (workspace, session)**：`TabCommon.ws`。session tab 的目录永不改变（它的文件在那儿）；draft 可以被重新指向，`TabStore.retarget` 就是浏览器按的那个动词——它换掉整个 tab 对象而不是改一个字段，因为 `ws` 是通过 `tabs.active()` 到处被读的。
- **`/cwd`**：裸的开目录浏览器（整屏 overlay `host:cwd`，§6.5 的第一类骨架 —— 它是个**地方**所以标题不带 glyph，列表可能超屏所以是 scrollbox）；带参数直接选定，是「拿一行」的点名形态（与 `/resume <id>` 之于 `Enter` 同一条先例）。三个入口：`/cwd` · 空状态那一行 `cwd`（可点）· 状态行上的 workspace chip（只在它说得出新东西时存在）。
- **浏览器只有一个动词**：`Enter` 永远拿光标那一行——目录行是**进去**，`no project` / recent / `use this directory` 是**选定**。打字不需要第二个确认手势，因为**打字把光标放到 `use this directory` 上**：「在输入框按 Enter」和「在一行上按 Enter」于是是同一次击键做同一件事。路径框全程持有键盘（能粘贴路径是终端用户第一个要的东西），所以光标只认 `↑↓`——`j`/`k` 是路径里的字母。列表：`no project` 恒第一行 · recents 段 · `use this directory` · `..` 段首 + 子目录（只列目录、隐藏点目录、按名排序、含 `.nulya/` 的带 `▪`）。**不做**文件预览、多选、新建目录。
- **无项目 session**：家 workspace = `<NULYA_HOME | ~/.nulya>/home/`。**不是 `~` 本身**——`~/.nulya` 是 user 层，塌在一起会让 user extension store 被内核 trust gate 误认成未信任的 workspace store 而拒开 session（DESIGN §9）。这一场跳过 `[extensions] session_prompts`：那些 renderer 画的是**项目**（布局、instruction 文件、这个分支、这棵工作树），而 `no project` 的答案正是「没有项目」，每一段都会是空话，而且它进的是缓存前缀、每一步都在付。侧边栏与 chip 上它叫 `no project`。
- **列表按 workspace 分组**：打开的 tab 的 workspace 全列，每组各跑一次 `session list --json`，当前 front tab 的组在前，组头 = 目录名 + 宽度够时的 dim 全路径（`min_path`，rail 上放不下就整个不画）。**只有第二个 workspace 出现时才有组头**（`groupedRows`）——单 workspace 的屏幕逐位等于 T70 结束时那一帧，快照钉住了这一点。光标只停在 session 行上（`nextSelectable`）：组头按 `Enter` 没有事可做。T70 的 persona 过滤每组照用。
- **信任与开屏流程按 workspace 首次进入时走**：launch workspace 仍由 `main.tsx` 在裸终端上问（那一刻还没有屏幕）；此后**第一个进入某个目录的 tab** 触发 `enterWorkspace` —— 同样的 `planProjectStore` / `planProjectAgents` / `planCheckout`，答案改在屏幕上给（`ui/CheckoutPrompt.tsx`，输入框上面的对话框，**trusted zone**，`resolveFocus` 里排在最外层：它是唯一一个**授权**而不是选择的对话框）。内核 trust gate 的硬拒照旧原样显示在那个 tab 里（`refusal`，T46）。
- **recents 在 user 层**：`<NULYA_HOME | ~/.nulya>/tui-recents.json`（§7）。**建场成功时才记**——浏览过不等于在那儿工作过，一个记下光标走过的地方的清单是点击史不是地点表。`no project` 不进 recents（它有恒定的第一行）。
- **持久与恢复**：`tui-state.json` 的 `tabs`（§7）。恢复**只做第一个之后的那些**：第一个 tab 仍由这一趟启动决定（`--session`，否则 draft，T22），所以单 tab 的屏幕逐帧不变；draft 不记（盘上什么都没有），文件已经不在的 session 跳过。

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
| `hairline` `selection` `hover` `lift` | 家具底色：框线 · 光标行 · 指针行（永远比光标那档更淡）· 扫光抬起的方向（主题自报，`NO_COLOR` 即 `fg`，扫光变成 no-op） |

语法高亮由同一套 tokens 派生（OpenTUI `SyntaxStyle`），所以代码块不可能和主题脱节。
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
| `⚙` | `+` | build / init |
| `⚡` | `!` | **一次能力的获得**：`ext activate` 与它配对的 capability note；Welcome 与 CompositionCard 里 pin 上去的 tool 名前缀 |
| `↺` | `<` | rollback |
| `⌕` | `?` | 读内核源码（`nulya src`） |
| `☰` | `=` | skill |
| `⤷` | `>` | sub-session。transcript 面：一次开了自己那场对话的调用（委派卡）。**pane 面**：sub-agent 观察 pane 的归属行行首（T72）——同一个意思的两处，一处说「有这么一场」，一处说「就是它」 |
| `⊘` | `x` | 被取消的调用 |
| `✗` | `!` | driver 侧的失败（`ErrorNotice`）——不是 tool 的失败，那个说 `exit N` |
| `▸` `▾` | `>` `v` | 折叠：关 / 开；`▾` 同时是**列表里光标所在的那一行**（两处都是「这一个展开着 / 就在这儿」） |
| `·` | `.` | 指针所在的那一行（形状与光标不同，所以没有颜色时也分得开） |
| `↓` | `v` | **下面还有**：`↓ N more below`（方向，不是状态——所以不是 `▾`） |
| `↗` | `->` | 去别处：卡片上唯一那条可点的链接（`open <id> in a tab`，T43） |
| `⠋` | `-\|/` | spinner（只在 `WorkingStatus`） |
| `✻` | `*` | tip：屏幕在跟人说话，不是发生了什么（T38） |
| `◧` | `[` | **sessions 侧边栏的把手**（T69）：左半填实的方块 = 屏幕左边缘停着一块 pane。只画在状态行行首那两格，点它开/关。**它不说侧边栏是开是关**——侧边栏在不在屏幕上是它自己以整块宽度回答的问题，把手再答一遍就是同一个问题的第二个答案（§6.1 第 4 条）。**≥100 列时它后面跟着自己的名字** `◧ sessions`（T70）：一个没人见过的字形、画在这一行最不被扫到的那一端、开的又是一块从没在屏幕上出现过的 pane——第一个用它的人报告说完全没找到侧边栏。窄屏退回纯字形（`sidebarRowPlan` 的同一条让位规则）|
| `▪` | `*` | **这个目录已经是一个 workspace**（T71，只在 `/cwd` 的目录浏览器里）：里面已经有 `.nulya/`，选它是走进已经存在的工作而不是开一个目录的第一场。**不是 `⚡`**——那个说的是「刚刚获得了一样能力」（`ext activate` 与 pin 上去的 tool 名），一个以前被工作过的目录此刻什么都没获得 |
| `✕` | `x` | **关掉眼前这一块**（T70 在 tab 条上，T72 在 sub-agent pane 的归属行末尾——同一个按钮，作用在它所在的那块东西上）：`⊘`/`✗` 说的是一次调用**发生了什么**（被取消、失败）、住在 transcript 里；这一个是个**按钮**，按钮以它做的事命名 |
| `+` | `+` | **新开一个 tab**（T70，只在 tab 条上） |
| `◈` | `#` | **这一场以什么身份/档位在跑**：选它的那些对话框标题（`/model` `/mode` `/agent` `/with`）、状态栏「戴着谁」的 chip、包自己的 panel 标题。列 store 或 journal 的面板是「地方」，标题**不带记号**（T31）；审批对话框也不带——它不是选身份，是**一个 call 被裁决**，颜色（warn）说完了 |
| `‹ ›` | `<` `>` | `/model` 的 effort 转盘 |
| `✓` | `*` | **现在生效的那一个**：`/model` 的 current model、`/ext` 版本线的 `✓ current`、`/mode` 当前档（一律 `ok` 色） |

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
ascii          = false

[ui]
theme  = "nulya-dark"       # nulya-dark | nulya-light
motion = true

[driver]                    # T24
mode = "ask"                # ask | unsafe —— 一趟从哪一档开始；chip 与 `/mode` 的选择记在 tui-state.json 里、优先级更高
                            # （写着 auto 的老文件照旧读成 unsafe，T31）

[approvals]                 # T24；条目 = tool id / tool 名 / `shell:<命令前缀>`
allow = []
ask   = []                  # 连 unsafe 也弹
deny  = []                  # 连 ask 也不弹，直接拒
manifest_readonly = true    # 信一个 tool 自己声明的 `"readonly": true`（DESIGN §7.2.1；是提示不是边界）

[extensions]                # T11
sync_on_start = true        # 开屏时后台 build 各 store root 下的 draft（`nulya ext sync`）
auto_activate = true        # 让那一趟把 `current` 指到它刚建出来的版本上（activate 只是移指针，T50）
session_with  = ["handoff", "agent"]  # 这个前端给它开的每个顶层 tab 额外带上的包（`--with` + `--pin`，§5.8 / §5.10）；旧的 `handoff = false` 仍认
session_prompts = ["ground"] # 每场开场前问一次「这一场的开场文本」的包（T66）：跑它的 internal `render`、
                            # 读回 `{"prompt": "<路径>"}`、把路径喂给 `session new --prompt`。不是成员——
                            # 进 session 的是它写出来的那个文件（`goals/session-prompt.md` 的那条线）。
                            # `no project` 那个 workspace 整段跳过（T71，§5.11）
plugins       = true        # 代码层总开关（T40）：加载 trusted + 已激活/本场戴着的包的 `contributes.ui.tui.entry`
                            # false = 只剩声明层（commands / policy / 每个 tool 的 ui 照常，逐字节等于 T39 结束时）

[keys]                      # 覆盖默认键；名字表见 keymap.ts
cancel = "escape"
```

`[extensions]` 两个键都只作用于**这一趟 sync**：`auto_activate` 永远不会盖掉指着别处的 `current`（那是 DESIGN §7.2 的规则，前端无从违反），所以一次 rollback 活得过下一次启动。**对一个 `apply: "manual"` 的包，`activate` 只是移动一个指针**（`current`，ext-review-2 Lane K）——无论它贡献了什么，activate 本身都不改变任何 session 的 composition，所以这一趟对它没有什么需要挡的。**唯一的例外是 `apply: "auto"` 的包**（T52）：对它 activate 就是 compose，内核从那一刻起把它组进这台机器上每一场非 `--bare` 的 fresh session，所以这一趟**永不**激活一个还没有 `current` 的这种包（`extensions.autoActivatable`，与内核给自己的 `ext sync --activate` 同一条规矩），只把它点名到状态栏那一行上，让 `/ext` 的 Enter 去按。project store 的那道 trust 问句**不受这两个键管**——它是 DESIGN §9 的边界，只有按键能推动。

`/settings` 只显示当前生效值与来源文件；不在 TUI 里写配置（编辑器改文件即可，第二个诉求出现再做）。

**`tui-recents.json`（T71）**：user 层下**第二个**由程序写的文件，JSON `{"recent": ["<绝对路径>", …]}`（新的在前，上限 12）。为什么不是 `tui-state.json` 的一个键：那个文件在其它每一处都是 **workspace 层**的事实（这个项目的 pin、它的侧边栏、它的档），而这一条是**关于好几个目录**的事实——一份别的目录的清单不能住在其中一个目录里面（`trusted-stores.jsonl` 因为同一个理由在 user 层，DESIGN §9）。**只在真的建起一场 session 时写**：浏览到一个地方不等于在那儿工作过。读不出来 = 没记住，永不阻止启动。

**`tui-state.json`（D10；T5 起）**：同目录（user 层）下由程序写的文件，JSON：`{"model":{"profile":"deepseek","model":"deepseek-v4-flash","effort":"high"},"mode":"ask"}`（`mode` 是 T24 的权限档，同一条理由：人在屏幕上做的选择由程序记；`tabs: [{"ws": "<目录>", "session": "<id>?"}]` 是 T71 的「上一趟开着哪些 tab、各自在哪个目录」——tab 是一对，所以记也得记一对：一个 id 说不出它是从哪个 `.nulya/sessions/` 里来的。恢复只做**第一个之后的那些**，第一个仍由这一趟启动决定）——`/model` 的 Enter 与 `/effort` 会更新它；启动无 `--profile` 时的默认选择就是它（`launch.planLaunch`：命令行 > 上次选择 > 内核 `active_profile`；每一层都要 `config show` 说它有 credential 才算数，否则落到离线 scripted 并开屏弹选择器讲原因）。缺失或损坏 = 没记住，永不阻止启动。为什么不放进 `tui.toml`：那是人写的；程序回写人的文件会碰注释与排版（tcode 用 toml_edit 才做到），这里不值得。为什么不进内核 config：内核不需要知道"上次选了谁"（不是 substrate）。

## 8. 测试

- `tui/test/cli.test.ts`：`NULYA_SCRIPTED_MODE=finish|loop` 跑真实 `nulya` 二进制：new → append → step --stream，断言行序与类型化解析；cancel 路径；events 回放与 live 状态一致（同一 fixture 两条路径渲染出同一帧）。
- `tui/test/render.test.ts`：`@opentui/core/testing` 的 test renderer 对每种卡片出快照帧（含折叠/展开、diff、canceled、窄屏）。
- 不调真实 API；CI 只需 `zig build` 出二进制 + `bun test`。
- Zig 侧：`--stream` 行协议单测（scripted provider）；e2e 里加一条 `--stream` 冒烟。

## 9. 里程碑

| 里程碑 | 内容 | 完成标准 |
|---|---|---|
| ~~**T0 · kernel `--stream`**~~ ✅ | §2.2：`StepContext.observer`、tee、tool begin/end、per-step 刷 ledger 行、`run done/error` 行、诊断 JSON 化；单测 + e2e 冒烟；DESIGN §14 同步 | `zig build test` / `e2e` 绿；`nulya session step <id> --stream` 在 scripted 下按 §2.2 行序输出；不带 `--stream` 行为不变 |
| ~~**T1 · 骨架**~~ ✅ | `tui/` 包；`nulya/{bin,cli,ledger,files,diff}.ts`；`state/{session,driver,settings}`；App = transcript（User/Assistant 通用卡 + 通用 tool 卡）+ composer + 状态栏；driver 状态机；流式；Esc cancel；`--session` 回放；`bun test` 两条 | 在 nulya 仓库里用它对着真实 provider 完整跑一轮"读源码 → edit → zig build test"；关掉重开 `--session` 一致 |
| ~~**T2 · 卡片与折叠**~~ ✅ | registry；Shell/Edit(diff)/ExtTool/Thinking/Canceled/spill；EvolveCard 全表；CapabilityBanner；CompositionCard；折叠交互；`tui.toml`；主题 tokens；ascii 降级 | §4.2 表每行一个快照测试；`diff` 设定生效 |
| ~~**T3 · nulya 视图**~~ ✅ | `/sessions`（树 + live 标记 + 打开）；`/ext`（store / 版本线 / 漂移 / usage / 动作键）；SubSessionCard → 第二 tab；observer 模式（锁探测、`events --follow` 续接、take over） | 用 shell 在另一终端跑一个 driver 脚本 loop step，TUI 以 observer 附上并能 append |
| ~~**T4 · 收尾**~~ ✅ | `/help` `/settings` `/usage`；keymap 覆盖；`bun build --compile` 出单文件；README（安装、`NULYA_BIN`、按键）；性能核对（长 session 回放 5k 事件不卡；scrollbox 视口裁剪 + `history_window`） | 5k 事件 session 打开 < 1s（实测 ~0.35s + 首帧 ~0.15s）；README 照做能跑 |
| ~~**T5 · 模型选择**~~ ✅ | 内核外壳：`[[models]]` 目录 + profile `models[]`、`session new --profile/--model`、`step --effort`、`nulya config show --json`、DeepSeek `off`/`reasoning_content`；前端：`/model` 选择器（↑↓ ←→ Enter）、`/effort`、`tui-state.json`、无 key 时开屏即选择器（D10） | `zig build test`/`e2e` 绿；`bun test` 新增 `model.test.tsx` 8 条；开 `nulya`（无 key）第一屏就是选择器 + 原因 |

| ~~**T6 · 用出来的痛点**~~ ✅ | composer/状态栏永不收缩（真 bug）；`/model` 两级（providers → models）+ `a` 加 compatible provider；空 session 首屏；slash 补全；`PgUp`/`PgDn`/`Shift+End` 回读 | `bun test` 99 pass；30/24/16/10 行终端下 composer 都在 |
| ~~**T7 · compaction**~~ ✅ | 内核：`session new --parent` 校验父 + 继承冻结身份（DESIGN §11/§14）；前端：`/compact [focus]`、压缩两条 turn 的卡片、状态栏上下文占用 | `zig build e2e` 里 fork 继承一条；`bun test` 100 pass；聊两句 → `/compact` → 新 session 顶上是 summary |

| ~~**T8 · 慢速回路的前端**~~ ✅ | `/outcome <verdict> [note]`（→ `nulya session outcome`，`/quit` 问一次）；`/sessions` 改读 `nulya session list --json`（verdict / usage / parent / composition，不再自己扫 header）；`/evolve`（`ext build extensions/evolution` → `session new --with evolution@<v>`）；`/mode <id>[@<v>]`；token 计数改以 ledger `assistant.usage` 为准；`/ext` 认多 root 与 `shadowed`。**内核零改动** | `bun test` 111 pass；评一次 verdict 后 `/sessions` 里看得到；`/evolve` 起来的场次 composition 里带 `evolution@<v>`、CompositionCard 显示 `prompts 1` |

| ~~**T11 · 启动即安装**~~ ✅ | 内核给了 `nulya ext sync`（build 一个 root 下的每个 draft）与 `ext prune`（DESIGN §7.2）；前端只决定**什么时候跑**：`tui.toml` `[extensions] sync_on_start/auto_activate`；user store 后台跑（状态栏 `syncing extensions… 2/3` + 一行汇总）；**project store 先问**（未信任且有 draft → 开屏前一句问话 + `t`/`s`/`n`，只问一次，记在 `tui-state.json`）；`/ext` 每个 id 多一列 draft 状态（`ext sync --dry-run`），`a` 在 id 列表上指向 draft 的版本，`p` 删非 current 版本（先确认）。**内核零改动** | `bun test` 新增 `extensions.test.ts` 6 条（真二进制的 plan/sync/`--activate` 三种答案 + 纯策略）；在本仓库 checkout 里开一次看得到 trust 问句 |

| ~~**T12 · `/ext` 的 pin 面板**~~ ✅ | `/ext` 第四个 pane **tools**：每个 tool 一行、三态 `always`（user config `registry.pinned_native_tools`，managed 只替换那一行、保注释、写后重读校验）/ `this TUI`（`tui-state.json` 的 `session_pins` → 每场 `session new` 自动 `--pin`）/ off，project/system 层写的 pin 只读显示；配额行 `tools 2+N/8`；`Space` toggle（id 行 = 整包）、`A` 升格、`d` = `ext deactivate`；`ext activate` 带 `NULYA_SESSION` 让内核投 capability_note。**内核零改动**（契约 [goals/tui-panel.md](goals/tui-panel.md)） | `bun test` 126 pass（新增 `pins.test.ts` 8 条 + `/ext` tools pane 一条交互）；面板里 `Space` 打开一个 tool → `session new` 的 header `native_tools` 里就有它，关掉就没有 |
| ~~**T13 · composer 的 `@` 文件补全**~~ ✅ | 触发边界 / token 字符表 / 评分（basename 前缀 0 < path 前缀 1 < 子序列 10+gaps，根文件优先）/ 菜单标签规则全部逐条移植自 tcode `composer.rs`；索引 = `git ls-files --cached --others --exclude-standard`（非 git 退化成带 prune 表的小 walk），上限 20000，后台建、30s 陈旧后台刷；`↑↓` 选、`Tab` 上屏成 `@path`，已知引用在输入框里 accent。**提交时 `@path` 原文进 ledger，不注入文件内容**（契约 D5）。**内核零改动** | `bun test` 135 pass（新增 `references.test.ts` 8 条，其中四条与 tcode 的测试逐条同形 + `composer.test.tsx` 一条交互）；本仓库上 `@comp` 补出 `@src/composition.zig`，`node_modules` 一条不漏进来 |
| ~~**T14 · 长文本粘贴折叠**~~ ✅ | OpenTUI 的 bracketed paste 事件（`onPaste` + `PasteEvent.preventDefault()`）是现成的；阈值照 tcode（> 1000 字符或 > 15 行）→ 折叠成 `[Pasted text #N]` 占位（accent 高亮、下面一行说明它装了多少、`Backspace` 整体删除），提交时展开回原文。短粘贴一字未变。**图片不做**（内核 vision track，契约 D7）。**内核零改动** | `bun test` 140 pass（新增 `paste.test.ts` 4 条 + `composer.test.tsx` 一条走真 bracketed paste 的往返）|
| ~~**T15 · skill 作为 slash command**~~ ✅ | `/` 补全内建命令在前、`nulya skill list` 的 skill 在后（描述截 100 字符）；分发同序，`/xyz` 命中 skill → `skill load <ref>` 拿 body、包 tcode 的 `<user-skill …>` sentinel 后作为**普通 user turn** append，未命中原样发给模型；transcript 靠同一个 `parseSkillEcho` 把它折成 `/name args · N lines`（live 与回放共用）；`/ext` 的 activate/rollback/deactivate 让 skill 表失效重取。翻案了 `commands.ts` 头注释与 §4.4 的"nulya 没有 skill slash"（契约 D8）。**内核零改动** | `bun test` 146 pass（新增 `skills.test.ts` 5 条——含 tcode 两条 sentinel 测试同形与一条真二进制闭环——加 `render.test.tsx` 一条折叠快照）；把仓库的 `extensions/guide` 装进一个 store 后 `/g` 补出 `/guide`、`/guide <args>` 变成一条 226 行的 user turn、transcript 折成一行 |
| ~~**T24 · 权限 mode + handoff 接线**~~ ✅ | 内核：`loop.StepContext.gate` + `session step --gate`（每个 tool call 执行前问一次，deny = 那个 call 的 tool_result；DESIGN §4/§14）+ manifest 的 `readonly?` 声明；前端：`--gate` 常开、`approvals.ts` 一个纯函数（deny/always/ask/allow/readonly/mode 六层）、审批卡片（`y`/`n`/`N`/`a`，只在输入框空着时接管这四个字母）、状态栏可点的 mode chip、`/mode ask\|auto`（穿身份的改叫 `/as`）、handoff 文件每步后看一眼（`ask` 弹面板 / `auto` 直接跟，跟 = `/compact` 的 `brief_file`）、每场默认 `--with handoff@<v> --pin ext:handoff/handoff` | `bun test` 212 pass（`approvals.test.ts` + `gate.test.tsx`）、`zig build e2e` 55 pass（`--gate` 一条：请求行 / deny 带 note / allow 真跑 / EOF fail closed） |
| ~~**T25 · CompositionCard 折叠**~~ ✅ | 顶上那张卡默认折成两行（标题 + model 行的模型与计数），展开才有 tools / skills / prompts / ext / parent；每一行改成"标签列 + 会换行的值"（`ui/Fact`，与 Welcome 共用）而不是会被 OpenTUI 压缩的 flex 行；版本哈希缩到 8 位；设定 `transcript.composition`。**内核零改动** | `bun test` 214 pass（静息 / 展开两张新快照、40 列逐行宽度断言、头行点击开关） |
| ~~**T26 · 一屏的节奏**~~ ✅ | 拿 tcode 的截图当标尺：头行从右对齐 chip 改成行内 `(note)` + 行尾 fold 记号；成功不再写 `ok`（只报大小，出事才说词）；`Transcript.gapBefore` 一个纯函数定三档空行（run 内 0 / beat 间 1 / 人开口前 2）；Thinking 并进 `CardFrame`；参数摘要第一个参数不写键名；三条通栏 hairline 换成**输入框自己的圆角边框**（有焦点变色），输入框随内容 1–8 行长高。**内核零改动** | `bun test` 216 pass（`gapBefore` / `wrappedRows` 两个纯函数 + 全部卡片快照重出 + 窄屏切头行不切状态词） |
| ~~**T27 · 审批面板 + Ctrl+C 的三层含义**~~ ✅ | 审批从"tool 卡多一行"改成**输入框上面的面板**（一行一个答案、可点、`fit` 到宽度，卡片只留 `waiting for you` 标记）；新增 `A` = 连同本批剩下的 call 一起允许（记 call_id 集合，不是布尔）；等待中的请求改成**队列**（多 tab 同时 drive 不再丢答案）；状态栏 activity 也过 `fit`（`nasknstep 1` 那种叠字）；`Ctrl+C` 由近及远、永不第一下退出。内核一处：`--stream` 在 `model started` 之前先刷已经存在的 ledger 行，于是排干的 `user_text` 当场转正（`queued` 不再挂满整个 step） | `bun test` 219 pass（`gate.test.tsx` 批量两条 + `lifecycle` 的 Ctrl+C 一条 + 面板文案）、`zig build e2e` 55 pass（`--stream` 首行改断言成排干的 user_text） |
| ~~**T28 · 审批对话框（tcode 形状）+ 任意选项的 note**~~ ✅ | 审批从"一列要按的字母"改成**一个可选可点的答案列表**（`↑↓`/数字/悬停移动光标、`Enter`/点击作答、五个答案按影响范围排、末位是 tcode 的 `set_mode`），底下常驻 **note 字段**：`Tab` 或直接打字进入，**note 跟着被选中的答案走**。note 的两条去向：deny 用内核自带的 `deny <note>`，allow 走 `session append`（`approvalnote.ts` sentinel + contract，下一个 step 边界落在同批 tool_results 后面，卡片 badge `note on <tool>`）。对话框在时拿键盘（`Ctrl+C` 除外）。**内核零改动** | `bun test` 221 pass（`approvalnote.test.ts` 6 条 + gate 的 allow-note / deny-note / 纯鼠标作答 / mode 答案 / 批量各一条） |
| **T10 · `/goal`（占位，未开工）** | spawn 随仓库带的 driver 脚本（`win32` → `powershell -NoProfile -ExecutionPolicy Bypass -File drivers/goal.ps1`，否则 `sh drivers/goal.sh`），把它的 **stderr 喂给已有的 `--stream` 解析器**（token delta / tool begin-end / usage 全在里面），把它的 **stdout 当控制通道**：`session <id>` 开 tab、`handoff <old> -> <new>` 换 tab（原 tab 留着可回看）、`done <id>` 收尾并提示 `/outcome`。跟随中的 tab 是 **observer**（driver 持着写者 lease）。**内核零改动**，也不需要 §10.4 的 `<id>.live` sidecar | 起一个两阶段目标：token 实时可见；handoff 时自动切到子 session；`Esc` 停得下来（`session cancel` 或杀脚本）|
| ~~**T29 · 后台任务**~~ ✅ | 内核先长 `shell {background:true}` → supervisor → inbox → 第五种事件 `task_finished`（B1–B4，DESIGN 同步）；前端只做**屏幕该做的**：`driver.ts` 的唯一新 policy "driver 角色 + 本进程驱动过 + idle + `<id>.inbox/` 非空 → step"（inbox 为空绝不裸 step；`ask` 也踢；observer 不踢；只打开没说话的 tab 不踢）· `nulya task list --session <id> --json` 喂状态栏 `⠋ N background` chip 与 `/tasks`（看 log、`k` kill）· ShellCard 后台变体 + `TaskFinishedCard`（按全名 `<sid>/t<N>` 连回发起的那张卡）· `/quit` 提示不杀。**TUI 不复刻** `lost` 判定与 retarget 扫描——kernel 的投影是权威 | `bun test`：任务 done 后 idle 的 driver 自动 step 且 ledger 出现 `task_finished`；inbox 为空不 step；observer 不 step；两张卡快照；`bun build --compile` 仍单文件 |

顺序 T0 → T1 → T2 → T3 → T4；**T1 结束就开始用它 dogfood**，T2 起的优先级由用出来的痛点重排（T5–T8 就是这么来的）。

**M5 给前端的新面**（内核已落地，T8 已全部消费）：`nulya session list [--json]`（一次拿到每场的 composition / parent / 事件数 / usage / 最新 verdict——`/sessions` 不必再自己解析 header）· `nulya session outcome <id> <verdict> [--note]`（写 outcome journal，不碰 session 文件，所以正在跑的场次也能评）· `session new --with <id>[@<version>]`（把一个 built 但**不 activate** 的包带进这一场——mode / evolution 就是这么投放的）· ledger 里 `assistant.usage`（每步真实成本，状态栏和 `/usage` 可以按步显示而不只是累计）· extension 的 user root `~/.nulya/extensions`（`/ext` 视图要标出每个 id 来自哪个 root、谁被遮蔽）。

## 10. 开放问题（待议，默认都先不做）

1. **spawned-by 谱系**：subagent 的 `session new` 在 `NULYA_SESSION` 存在时是否自动记一个 header 字段（`spawned_by{session,seq}`，与 `parent` 分开）？是 provenance fact，成本几行；但等 subagent skill 成为第一个 consumer 再定字段名与语义。
2. ~~**`nulya config show [--json]`**：外壳级投影，供 `/new --model` 选择器与 agent 自查；v1 手打 profile 名。~~ **已落地（T5）**：DESIGN §14；`/model` 读它。
3. **`session append` 打印投递回执**（inbox 文件名）→ TUI 按 `origin` 精确转正而非按序匹配；现在按序够用。
4. ~~**`<id>.live` sidecar**：observer 模式的 deltas；等第一个 driver 脚本。~~ **不需要了（M2c）**：第一个 driver（`drivers/goal.*`）把 `session step --stream` 的行协议**原样透传到自己的 stderr**，stdout 只留控制行——spawn 它的前端直接拿到 deltas，既不用 sidecar 文件也不用内核改动（DESIGN §11）。仍未解的只有"别人跑的 driver"（不是我 spawn 的那种）：那条路还是只有 `events --follow` 的 turn 级粒度。
5. **`nulya composition preview`**：下一场的工具面长什么样（config 的 pin + `--pin` + 冻结版本合出来的结果）——纯投影 CLI，省得 TUI 自己拼。
6. **`split-footer` 模式**作为可选屏幕模式（scrollback 原生复制），与折叠可变历史的取舍。
7. session `--system-file/--skill/--pin`（PLAN §3.2 未落地）落地后 `/new` 的表单。
8. ~~**header 的 `created` 现在是空串**~~ **已落地（M5f）**：`session new` 写 RFC3339 UTC，`session list --json` 按它倒序；CompositionCard 可以显示时间了（老 session 仍是空串，退回按 id 排）。
9. ~~**"这个 tool 是给 driver 的"今天是前端的一张硬编码名单**（`bundled_driver_only` → `pinsOnActivate`，T24/T33）。~~ **已落地（T34）**：manifest per-tool 的 `audience`（`"model" | "driver"`，DESIGN §7.2.1，与 `readonly?` 同级：解析、冻结、不强制），前端四张名单（`bundled_driver_only` / `pinsOnActivate` / `bundled_active` / 字面量 `std_pins`）随之消失，第三方的 driver 型 extension 现在说得出这件事。

10. **宿主宪章 + 扩展 UI 自由度模型 + app 化（鼠标优先 / pane 平铺）**：整份设计讨论记录在
   [goals/tui-shell.md](goals/tui-shell.md)（宪章四类、三层自由度、五条不打架规则、chip 模型、
   核心 vs 扩展切法、里程碑草案 S1–S3）。**未排期**；动宿主骨架或 plugin API 前先读它。

## 11. 实施日志

> 每个里程碑追加一小节，只追加不改写。格式：状态 / 关键决定与理由 / 偏离设计之处 / 怎么运行与测试 / 已知问题 / 给下一里程碑的提醒。
> 主对话（编排者）在每节末尾追加一行 `核验：…` 记录 `zig build test` / `zig build e2e` / `bun test` 的结果。

### T0 · kernel `--stream`

**状态**：完成。`nulya session step <id> --stream` 已落地，行协议搬进 DESIGN §14，§2.2 收缩成 TUI 侧消费约定。`zig build test`、`zig build e2e` 全绿；不带 `--stream` 的 `session step` 一字未变（输出路径与文案原样保留，e2e 有对照断言）。

**关键决定与理由**

- **observer 全部返回 `void`**。§2.2 只说"纯观测"，没说签名。让四个回调都不可失败，是把"纯观测"变成类型上的事实：observer 既不能 append，也不能让一个 step 因为 stdout 断了而失败。写失败停在 `StepStream.err`，run 结束后走 stderr + 非零退出（stdout 仍只有 JSON）。
- **step 边界回调放在 `AgentSession.step()` 而不是 `run()`**。§2.2 写的是"`run` 每个 step 结束后一次"；放在 `step()` 里对 `run` 完全等价（`run` 只调 `step`），还顺带覆盖了直接调 `step()` 的调用方，且 `prepareStep` 在边界被取消的那一步也能报 `step end{status:"canceled"}`。
- **tee 在 `loop.zig` 而不是 `provider.zig`**。observer 类型属于 loop（`StepContext` 的一部分），provider 反过来引用会成环。`collectTurn` 在无 observer 时**就是** `Model.step`，有 observer 时才建 collector + `TeeSink`；两条路径的失败语义一致（partial collector 一律丢弃）。
- **`{"stream":"tool","event":"end"}` 只带 `call_id` + `ok`**，与 §2.2 样例逐字一致（不加 `tool` 字段）；配对信息读者从 `begin` 和 `tool_use_start` 已经拿到了。
- **未被派发的调用不发 begin/end**。一批被取消后，后面的调用内核保证从未交给 executor，"没有事件"正是这个事实的忠实表达；它们仍会以 `not executed` marker 出现在 ledger 行里。
- **`stopped` 不改 `run` 的签名**：`canceled` 来自 observer 记下的最后一个 step status，`max_tokens` 来自 `sess.lastStopReason()`（M5.1 加的、最后一步的模型停止原因），`end_turn` 来自 `sess.lastAssistantDone()`，其余是 `budget`。TUI 见 `max_tokens` 提示"发一条消息继续"（裸 `/step` 在 text-only 截断后是 assistant 结尾的 prefill，thinking 开着时 provider 拒绝）。
- **一个 step 的 ledger 行在该 step 的 `step end` 之前刷出**，包括边界上从 inbox 排干进来的 `user_text`——所以它出现在模型 delta **之后**。这是 step 粒度的必然结果，不是 bug：TUI 拿 `seq` 入 items，顺序由 seq 决定，不由到达时刻决定。

**偏离设计之处**

- §2.2 原文整节搬进 DESIGN §14（tui.md 的铁律：已落地的写 DESIGN），§2.2 改为"真相在 DESIGN §14 + TUI 侧消费约定"。§9 里程碑表 T0 一行标 ✅。
- §2.2 样例里 `{"seq":8,"kind":"tool_results",…}` 与 `{"seq":7,"kind":"assistant",…}` 相邻；实际实现两行都在同一个 `step end` 之前刷出，顺序一致，无偏离。
- 除此之外无偏离。§10 列的四项内核改动一项没做。

**怎么运行与测试**

```bash
zig build                                        # 出二进制
zig build test                                   # 单测（含 cli/step_stream.zig 的两条行协议测试）
zig build e2e                                    # e2e（含 --stream 冒烟）

# 手动看一眼（scripted，无需任何 API key）：
ID=$(nulya session new --model scripted)
nulya session append "$ID" "hello"
NULYA_SCRIPTED_MODE=finish nulya session step "$ID" --stream
```

新增测试：
- `src/cli/step_stream.zig` — `"session step --stream emits the tui.md §2.2 line protocol in order"`：scripted provider + 假 `shell` 工具，对**整段 stdout 逐字**断言（两个 step 的全部 16 行）。`src/cli/session.zig` 另有两条覆盖 `stoppedReason` 与"诊断在 `--stream` 下是 `run error` 行"。
- `tests/e2e.zig` — `"session cli: --stream emits the transient line protocol and leaves the ledger identical"`：跑真实二进制，逐行 `parseFromSlice` 确认 stdout 全是 JSON、首行 `model started`、末行 `run done{steps:2,stopped:"end_turn"}`、两个 `step end`；再跑一遍**不带** `--stream` 的同样 session，断言两份 session 文件从 `seq:2` 起逐字相同（seq 1 带 inbox 投递名 `origin`，天然不同），且 plain stdout 里没有 `"stream":`。

**已知问题**

- observer 的写口是 `std.Io.Writer`（stdout 走 `writerStreaming` + 每行 flush）。如果 step 被 **Future cancel**（进程内取消，CLI 目前不走这条路），`step end` 那次写会以 `error.Canceled` 落进 `StepStream.err`，让退出码变 1。CLI 的取消只走 `<id>.cancel` 标记（无 io 取消），所以现实里碰不到；真要碰到时正确的修法是在 `note()` 里忽略 `error.Canceled`。
- `src/loop.zig` / `src/session.zig` 在本次改动**之前**就没通过 `zig fmt --check`（已用 `git stash` 核对）。没有顺手 reformat：那会把无关 diff 混进 T0 的 commit。
- 未测：真实 provider 下的 `thinking_delta` / `usage` 行（scripted provider 不发这两种）。字段名直接来自 `provider.StreamEvent`，风险低；T1 用 deepseek 短冒烟时顺带看一眼。

**给下一里程碑（T1 · 骨架）的提醒**

1. `nulya/cli.ts` 解析 `--stream` 时**只**分两类：有 `stream` 字段 → 瞬态；无 → ledger 事件（直接按 `seq` 入 items）。不要按 `kind` 白名单过滤——新 event kind 出现时应该原样落进 items，由 registry 决定怎么画。
2. `usage` 行给的是**本次 step 的**四个计数（不是累计）。状态栏要自己累加，且 resume 前的历史未知（§4.5 的 `since attach`）。
3. `run done` 的 `stopped` 是驱动状态机的关键：`budget` 意味着 `--max-steps` 用完但 turn 没结束——D-状态机要么再 spawn 一次 step，要么在 UI 上明确显示"预算用完"，别静默停住。
4. 取消路径：`Esc` → `session cancel` → 那一步以 `{"stream":"step","event":"end","status":"canceled"}` + `run done{stopped:"canceled"}` 收尾；被取消的工具在 ledger 行里是三种 marker 之一（§2.1），CanceledCard 认 marker 文本而不是认 `stream` 行。
5. 内核这边 T0 之后**不再需要**任何改动就能做完 T1；再想改内核先回 §10 讨论。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun test` 尚不适用（`tui/` 未创建）。

### T1 · 骨架

**状态**：完成。`tui/` 包已建（Bun 1.3.5 + `@opentui/core`/`@opentui/solid` 0.5.3 + solid-js 1.9.12）：`nulya/{bin,cli,ledger,files,diff}.ts`、`state/{session,driver,settings,folds}.ts`、`render/{registry,theme,cards/*}`、`ui/{App,Transcript,Composer,StatusBar}`、`keymap.ts`、`main.tsx`。transcript（User / Assistant / 通用 tool / Thinking / CapabilityBanner / Unknown）+ composer + 状态栏跑通；driver 状态机、流式渲染、`Esc` 取消、`--session` 回放都在。**内核一行未改**（硬约束 1）。`bun test` 20 条全绿（`tui/test/{cli.test.ts,render.test.tsx}` + 7 张快照）；`zig build test` / `zig build e2e` 绿。

**关键决定与理由**

- **provisional → committed 的替换点只有两处。** 流式行只造 *provisional* 卡（key `p<turn>:…`），ledger 行造 *committed* 卡（key `e<seq>…`）。committed 项按 seq 插在 provisional 段之前，所以"到达顺序"永远不决定"显示顺序"——step 边界从 inbox 排干进来的 `user_text` 带着小 seq，仍然排回它该在的位置（T0 提醒 1 的直接落地）。丢弃 provisional 只发生在：收到该 step 的 `assistant` 事件时，以及 `step end` 时兜底（provider 阶段被取消的那一步根本没有 assistant 事件，剩下的 provisional 必须清掉，否则屏幕上会留一张 ledger 不背书的卡）。
- **thinking 卡放在 assistant 文本之前**（§4.1 的示意图里画在之后）。理由：流里 `thinking_delta` 本来就先到，若 committed 时翻成"文本在前"，live 与 replay 就会给出两种画面——而"两条路径同一帧"是本里程碑用测试钉死的不变量，排版好看排在它后面。
- **`stopped:"budget"` 不自动续跑。** "该不该继续"是 driver 脚本 / agent 的事（PLAN §3.6、硬约束 2），TUI 一行都不写。状态栏明确显示 `step budget spent · /step to continue`，并新增一个 `/step` slash 命令让用户显式续。§4.3 那条"pending 未转正就再 spawn 一次 step"照做了，但加了收敛条件：只有 queued 数**严格下降**才继续循环，否则停下并让用户看见——否则一条永远转不正的 pending 会变成无限 spawn。
- **diff 打开行号 gutter**（§6 写的是"仅前景色的 add/del"）。OpenTUI 的 `DiffRenderable` 只在 gutter 里画 `-` / `+`；关掉行号后 add/del 之间**只剩颜色**差别，NO_COLOR 下、以及任何纯文本抓帧（包括本里程碑的快照测试）里就完全分不出来。背景块仍按 §6 全部 transparent，只是把符号找回来。
- **`edit` 的 diff 行号相对片段、不相对文件。** `edit` 参数只有 `{path, old_string, new_string}`，ledger 里没有文件偏移；replay 时文件也早就变了。与其编一个假的行号，不如让 hunk 头老老实实写 `@@ -1,n +1,m @@`——这是那次事务的忠实图像，而不是第二份真相（理由写在 `nulya/diff.ts` 顶部）。
- **`nulya/files.ts` 现在只有 session 路径 / 存在性 / header。** §3 的模块表还给它派了 lock 探测、extensions store、tool-usage 投影——但那三样的消费者（observer 模式、`/ext` 视图）都在 T3。按 CLAUDE.md「第二个 consumer 出现之前不抽 abstraction」「只写不读的字段是该删的信号」，先不写没人读的代码。
- **`render/registry.ts` 已经是唯一的 match 点，但表还没填满。** T1 只认 `shell` / `edit` / 其它 extension tool，外加"命令以 `nulya` 开头 → evolve 配色 + 按 `src|skill|session|其它` 选图标"。§5.2 的全表（抽 version、抽 id、SubSessionCard）是 T2 的活，加在 `describeTool` 一个函数里即可，卡片只读 `ToolPresentation`。
- **测试里的 `settle()`。** `@opentui/core/testing` 的 `renderOnce()` / `waitForFrame()` 单独用时，`markdown` 与 `diff` 画出来是**空的**——它们的解析要跨真实计时器 tick 才落地，只推 render pass 推不动。`test/support.ts` 的 `settle(setup, passes, delayMs)` = 睡一下再 render，重复若干次。踩了半小时，记在这里省得 T2 再踩。

**偏离设计之处**

1. **§4.1 的卡片顺序**：thinking 在 assistant 文本**之前**（理由见上）。
2. **§4.4 的 slash 列表**：新增 `/step`（budget 用尽后显式续跑）。`/new` `/sessions` `/ext` `/skills` `/usage` `/settings` 未做（T3/T4）。
3. **§6 的 "diff 静"**：保留"无背景块"，但打开行号 gutter 以拿回 `-`/`+` 符号（理由见上）。
4. **§4.2 的卡片表**：T1 只有通用 tool 卡（registry 决定图标/头行/chip），ShellCard / EditCard / ExtToolCard / EvolveCard / SubSessionCard / CanceledCard 尚未拆成独立组件——canceled 是通用卡按 marker 文本变形，不是独立卡。CompositionCard 也没做，header 信息压成顶栏一行（`nulya · <id> · provider/model · tools 2+N`）；skills 数要读每个 active 版本的 `extension.json`（§5.1），留给 T2 的 CompositionCard。
5. **§4.2 的折叠交互**：只有键盘（`Ctrl+O` 切最近一张卡、`Ctrl+Shift+O` 全展开、`/fold` 全折叠）。鼠标点头行、`Esc` 进 browse 模式（`j/k`）是 T2。
6. **§4.1 的空状态首屏 wordmark** 与 **§4.5 的 `↓ N new`** 未做。
7. **§3 模块表**：`files.ts` 只实现了 sessions header 那一档（理由见上）；另加了一个模块表上没有的 `state/folds.ts`（折叠覆盖的 store，纯视图状态）。
8. **本文的状态行与 §9 的 T1 一行**改成已落地（与 T0 同一种记法）。`tui/` 的现状留在本文 §11、**不进 DESIGN.md**——DESIGN.md 是内核的现状，`tui/` 是内核之上的客户端。`CLAUDE.md` 里 `docs/tui.md` 那一行仍写着"未实现，归属 PLAN"：工作区里 `CLAUDE.md` 有别人未提交的改动，本次 commit 按硬约束 7 没碰它，等那些改动落地时一并更新。

**怎么运行与测试**

```bash
zig build                                    # TUI 需要一个 nulya 二进制
cd tui && bun install

bun run typecheck                            # tsc --noEmit
bun test                                     # 20 条：CLI 协议 + 渲染快照 + 按键注入

bun run src/main.tsx                         # 当前目录开一场新 session
bun run src/main.tsx --session s-…           # 重开
NULYA_SCRIPTED_MODE=finish bun run src/main.tsx --model scripted   # 离线
```

二进制发现顺序：`NULYA_BIN` → workspace（或本包）向上找 `zig-out/bin/nulya[.exe]` → `PATH`。

- `tui/test/cli.test.ts`：临时 workspace + **真实二进制**（scripted，无密钥无网络）。`new → append → step --stream` 对**整段行序**逐条断言（17 行的 tag 序列），并做类型化解析（`tool_use_start.name == "shell"`、`run done{steps:2,stopped:"end_turn"}`、seq 1..4）；`--since` 尾巴；cancel 路径用 `NULYA_SCRIPTED_MODE=loop --max-steps 20`，见到第一个 `step end` 就 `session cancel`，断言出现 `status:"canceled"` 且 `run done{stopped:"canceled"}` 且总步数远小于预算；最后一条断言 **events 回放的 items 投影 == live 流的 items 投影**。
- `tui/test/render.test.tsx`：7 张卡片快照（user/queued、thinking 折叠、shell 折叠+exit chip、evolve、diff 展开、canceled marker、capability），外加 `diff=collapsed` / `tool_output=expanded` 设定生效、窄屏隐藏右侧 chip、ascii 降级；然后是三条端到端（真实二进制 + test renderer + `mockInput`）：**同一 session live 与 replay 渲染出同一帧**、**打字 + Enter 真的驱动一次 step**（user turn 从 queued 转正、tool 卡出现、`stopped == "end_turn"`）、**关掉重开 `--session` 的 transcript 逐字相同**（对比两条 hairline 之间的行，避开状态栏计数）、**`Ctrl+O` 展开最近一张 tool 卡**。

**已知问题**

- **真实 provider 冒烟未跑：环境里没有任何密钥**（查过 `DEEPSEEK_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`，只有一个 `ANTHROPIC_BASE_URL`）。按硬约束 6 跳过，全链路验证一律走 scripted。因此 T0 遗留的两条也还没实测：真实 provider 下的 `thinking_delta` 与 `usage` 流行（状态栏的 token 累计、Thinking 卡的流式尾行都还没见过真数据）。**"读源码 → edit → zig build test" 那一轮**必须等有密钥的人手工跑一次。
- **只能自动验证到"按键 → 状态 → 帧"这一层。** alt-screen 的实际观感、鼠标滚轮、`Shift+Enter`（要 kitty keyboard 协议，Windows Terminal 支持；不支持时退 `Ctrl+J`）、`Ctrl+C` 两下、真实终端里的换行/宽字符，都得早上手工确认一遍。启动路径本身验证过：`bun run src/main.tsx` 在仓库里真的进了 alt-screen 并画出首帧（stderr 干净），只是无法在无人值守下继续操作。
- `Ctrl+C` 第一下 kill 的是 step 进程本身；Windows 上它派生的 shell 子进程可能残留（`Bun.spawn().kill()` 不杀进程树）。ledger 侧是安全的——下次 open 由内核 `completeInterruptedToolBatch` 补齐。
- `@opentui/solid` 0.5.3 的 `SpanProps` 类型丢了 `fg`/`bg`（`TextNodeOptions` 运行时是支持的）。没有用类型 hack 绕，改成 row box + 兄弟 `<text>`——顺带得到了悬挂缩进。
- 退出走 `process.exit(0)`（`renderer.destroy()` 之后）。OpenTUI 不在 `process.exit` 上自动清理，所以顺序不能反。
- `settle()` 那条（见上）：新加需要 markdown/diff 的快照测试时别用 `renderOnce()` 一把。

**给下一里程碑（T2 · 卡片与折叠）的提醒**

1. **卡片全表加在 `render/registry.ts` 的 `describeTool` 里**，不要在组件里再 match 一次名字。`ToolPresentation` 现在有 `{glyph, head, accent, body, isEdit}`——要抽 `ext build` 的 version、`session new` 的 id，就往这个返回值上加字段，`ToolCard` 只负责摆。
2. **每加一种卡就加一帧快照**；`render.test.tsx` 里"live 与 replay 同一帧""关掉重开逐字相同"这两条是不变量，任何新卡片都必须继续满足——尤其别让新卡片依赖只有流里才有的信息（`tool begin/end` 在 replay 里根本不存在，canceled 只能认 marker 文本，T0 提醒 4）。
3. **`tui.toml` 已经能读全**（`state/settings.ts`，user → project 合并，坏文件不致命）。T2 新增的折叠键只要加进 `Settings.transcript` 并从 `Style.settings` 读即可；`createStyle` 是唯一把设定变成 tokens 的地方。
4. **provisional → committed 的替换只有两处**（`assistant` 事件、`step end`），新卡片别绕开它们自己维护状态，否则 replay 就对不上了。
5. **`usage` 是每步的增量**（T0 提醒 2 已按此累加），resume 之前的历史未知，状态栏写的是 `since attach`——真出了 CompositionCard / `/usage` 视图时别把它当全量。
6. **内核不需要再改**（T0 提醒 5 依然成立）：T1 全程只用了 `session new|append|step --stream|events|cancel` 与 session 文件首行。§10 那四项一项没动。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun test` 20 pass 0 fail（7 快照）。真实 provider 冒烟未跑——环境无任何 API 密钥。

### T2 · 卡片与折叠

**状态**：完成。`render/registry.ts` 填满 §4.2 / §5.2 全表；卡片拆成 `CardFrame` + `ShellCard` / `EditCard` / `ExtToolCard` / `EvolveCard` / `CanceledCard` / `CompositionCard`（`Thinking` / `CapabilityBanner` / `UserTurn` / `AssistantTurn` 沿用并加强）；折叠交互补齐鼠标点头行与 browse 模式（`state/browse.ts`）；`tui.toml` 的 `diff` / `tool_output` / `thinking` / `ascii` 全部真的生效；主题 tokens 多一个 `bar` 字形并有 ascii 降级。**内核一行未改**（硬约束 1）。`bun test` 40 条全绿（`cli.test.ts` / **新增** `registry.test.ts` / `render.test.tsx`，14 张快照）；`zig build test` / `zig build e2e` 绿。

**关键决定与理由**

- **`describeTool` 现在也拿 `output`。** §5.2 有两行的事实只在 stdout 里：`ext build` 的 `v-<hash>`（内核打 `<dir>: <version> (built)`）、`session new` 的 id。ledger 把参数和结果都存着，所以 live 与 replay 读到的是同一份事实——签名从 `(tool, args, glyphs)` 变成 `({tool, args, output}, glyphs)`，抽取仍然只发生在 registry 一处。
- **抽不到就退回 ShellCard，不报错。** `nulya toolchain …`、以及任何比本 build 新的子命令，走的是普通 shell 卡。这条是 §5.2 写死的纪律，也是 registry 唯一的失败模式：一张朴素的卡永远是对的。
- **卡片按 `presentation.kind` 分派，不按工具名。** `ToolCard` 只有一个 `Switch`，读的是 registry 已经做完的决定；六个卡片组件里没有一处 `=== "shell"` 之类的名字比较。`CardFrame` 收走了头行布局、折叠开关、spill 尾行，所以"新加一种卡"不会长出第二套视觉语言。
- **取消压过工具身份。** 一次被内核收尾的调用，重要的是"它没跑完"，不是"它是个 shell"，所以 `CanceledCard` 在 `Switch` 的最前面，且四种 marker 各有各的措辞（"side effects unknown" 与 "never started" 不是同一个警告）。认的仍然是 marker **文本**（T0 提醒 4）。
- **CompositionCard 不是 transcript item。** header 不是事件（DESIGN §3.1），把它塞进 items 就是发明第二份真相。它由 `Transcript` 从 `snapshot.header` 直接画在 items 之前，因此 T1 钉死的两条不变量（live == replay、关掉重开逐字相同）完全不受影响。它读的 skills 来自**冻结版本**的 `extension.json`（`files.ts` 新增 `readContributions`），不是 store 的 `current`——本场跑的是什么，就显示什么（DESIGN §7.5）。
- **CapabilityBanner 的头行自己解析 note 文本。** `extension/notes.zig` 生成的文本是确定性的（`Tools:` / `Skills:` 两段，每条 `- <name> — <desc>`），把名字提到头行正是这张卡存在的理由——"agent 现在会 X 了"不该需要展开。解析放在 `nulya/ledger.ts`（那是唯一认识内核形状的目录），认不出的形状就只是没有名字，全文照旧在下面。
- **browse 模式让 composer 先 blur。** 不 blur 的话 `j`/`k` 会同时进文本框；blur 之后 App 的 `useKeyboard` 独占这几个键，`Esc` 再把焦点还回去。`Esc` 的三义在一个地方分完：stepping → cancel；idle 且 composer 空 → 进 browse；browse 中 → 退出。
- **`Ctrl+Shift+O` 改成 toggle。** T1 只会全展开，按第二下没反应；§4.2 写的是"全部展开/折叠"，所以记一个 `allOpen` 信号来回翻。
- ~~**SubSessionCard 不做独立组件。**~~ **T43 推翻**：当时它与 EvolveCard 的差别只是 glyph 和「有一个 session id」，抽出来是无谓的（registry 先保留 `kind:"subsession"` + `sessionId` 两个**事实**，绘制交给 `EvolveCard`）。现在差别是两条**实时**事实（那个后台任务在怎么样）加一个**手势**（`↗ open … in a tab`），第二个 consumer 到了，于是 `render/cards/SubSessionCard.tsx` 成立。第一版曾加过一行 dim 的 `⤷ session <id>`，与头行完全重复，删掉了——现在那一行说的是它**不重复**的东西。

**偏离设计之处**

1. **§4.2 的 SubSessionCard**：没有独立组件（理由见上）；`sessionId` 这个事实在 registry 里，快照测试仍覆盖了这一行。
2. **§4.2 的 CompositionCard 头行"时间"**：内核实际写的 header 里 `created` 是**空串**（`nulya session new` 不填它），所以有值才显示。没有伪造时间（用 mtime 或从 session id 反推都是第二份真相），也没有为此改内核（硬约束 1）。这是 §10 值得记一笔的一行内核修补。
3. **§4.2 的 CapabilityBanner 头行**：除 `tools: …` 外也带 `skills: …`——note 本来就宣告两种能力，只显示一半没有理由。
4. **§4.2 的 CanceledCard**：不可折叠。它的"体"是 `—`，marker 文本已经全在 chip 上，留一个空的折叠开关是假的可交互。
5. **§4.2 的 `▎` 左侧竖线**：§6 的符号集原本没有列它（§4.1 的示意图里画着），CompositionCard 需要一个"这是一块"的记号，新增 glyph `bar`（ascii 降级为 `|`）。**已同步补进 §6 的符号表**（先改文档再改代码，硬约束 7）。
6. **§6 的 "diff 静"**：沿用 T1 的偏离（行号 gutter 开着，靠它拿回 `-`/`+` 符号）。
7. **§4.4 的 `/settings`**：仍未做（§9 归 T4）。`/help` 的提示行更新为包含 browse。
8. **§7 的 `[keys]`**：`cancel` / `quit` / `redraw` 等可覆盖（T1 已有；`fold` / `foldAll` 两个动作在 T38 整个删掉了，见 §4.2）；browse 内部的 `j`/`k`/`Enter` 是固定键，没有做成可配置——第二个诉求出现再说。

**怎么运行与测试**

```bash
zig build                                    # TUI 需要一个 nulya 二进制
cd tui && bun install

bun run typecheck                            # tsc --noEmit
bun test                                     # 40 条：CLI 协议 + 演化表 + 渲染快照 + 按键/鼠标注入

bun run src/main.tsx --session s-…           # 手工看一眼
```

新增/改动的测试：

- `tui/test/registry.test.ts`（**新**，11 条，无渲染器）：§5.2 每一行一条——`src` / `ext init`（含 `--script` 不当 id）/ `ext build`（`(built)` 与 `(already built)` 两种 stdout）/ `activate` / `rollback`（两个 glyph 不同）/ `ext run`（`--arg` 与位置 JSON 两种形态）/ `skill load` / `session new`（id 来自 stdout，没打印就是 `null`）/ `session step`；外加"读不懂的 `nulya` 命令退回 shell 卡"和"参数还在流式时显示原始 JSON 而不是瞎猜"。
- `tui/test/render.test.tsx`：**§4.2 的每一行都有一张快照**——CompositionCard / UserTurn（含 queued）/ AssistantTurn / Thinking / ShellCard / EditCard / ExtToolCard / EvolveCard（§5.2 七种命令一帧）/ SubSession（两种）/ CapabilityBanner / CanceledCard（四种 marker 一帧）/ spill 尾行；另加 ascii 降级两帧（普通卡 + CompositionCard）、窄屏隐藏右侧 chip、`diff=collapsed` / `tool_output=expanded`。
- **`diff` 设定生效有真文件为证**：`"a project tui.toml flips the diff default"` 在临时 workspace 里先断言默认展开，再写一个 `.nulya/tui.toml`（`diff="collapsed"` + `thinking="expanded"`），重新 `loadSettings` 后同一张 diff 卡消失、同一张 thinking 卡展开——两个方向都动，证明是设定而不是"全都折了"。
- **鼠标**：`"clicking a card's head line folds it"` 用 test renderer 的 `mockMouse.click(4, 0)` 点头行，展开→再点收起。
- **browse 模式**：`"Esc on an empty composer opens browse mode, where Enter folds a card"` 跑真实二进制一轮 scripted step，然后 `Esc` 进 browse（状态栏出现提示）、`Enter` 展开最近一张卡（stdout 出现第二次）、`Esc` 退出。
- T1 的四条不变量测试（live == replay、Enter 真的驱动一次 step、关掉重开逐字相同、`Ctrl+O`）全部保留且仍绿——CompositionCard 加在 transcript 顶部后也没破。

**已知问题**

- **真实 provider 仍未跑：环境里没有任何 API 密钥**（T1 已记，本里程碑按硬约束 6 本就不跑）。因此 `thinking_delta` / `usage` 流行、以及 Anthropic 形状的 `reasoning` 抽取（`readableThinking`）仍只在构造数据上验证过。
- **鼠标与 browse 只在 test renderer 里验证过。** 真实终端里鼠标上报由 OpenTUI 打开，但 Windows Terminal 的滚轮/点击、以及 `scrollbox` 里坐标随滚动偏移之后的点击命中，都还没人工确认。
- **`nulya src` 的行数 chip 数的是 shell 结果的行数**（含 `--- stderr ---` / `[exit N]` 那几行），不是文件行数。真行数只有内核知道；宁可数得诚实也不发明一个数字。
- **CompositionCard 的 skills 在 store 被删/改名后静默为空。** header 冻结的版本目录不在了，`readContributions` 返回空而不是报错——header 本身已经把版本号写在 `ext lint@v-…` 那一行，所以信息不会全丢。真正的"漂移提示"（冻结版本 vs store `current`）是 §5.3 的 `/ext` 视图，归 T3。
- `EditCard` 的 diff 高度是补丁行数（上限 40 行）。一次超长 edit 会被截断显示，没有内部滚动——`scrollbox` 已经在外面，嵌套滚动区在终端里更难用。
- T1 的 `settle()` 那条依然成立：新加需要 markdown/diff 的快照别用单次 `renderOnce()`。

**给下一里程碑（T3 · nulya 视图）的提醒**

1. **`nulya/files.ts` 已经有 `readContributions` / `readActiveContributions`**（读**冻结版本**的 `extension.json`）。`/ext` 视图要的 store 扫描、`current` 指针、`versions/` 时间线、`.nulya/tool-usage.jsonl` 投影都接着加在这个文件里——`nulya/` 之外仍然不许出现 `.nulya/` 路径。
2. **`presentation.sessionId` 已经是事实**，`ToolCard` 里 `evolve || subsession` 那个 Match 就是 SubSessionCard 的落点（注释指着）。要做"Enter 打开成第二个 tab"时，先想清楚第二个 tab 的 session 是 observer（§5.6），别让两个进程都去抢 `<id>.lock`。
3. **browse 模式的键在 `App.tsx` 的 `useKeyboard` 里，靠 `browse.active()` 门控。** overlay（`/sessions`、`/ext`）打开时同样要门控，否则 `j/k` 会被两处同时消费；顺手把 overlay 的开关也做成一个 store，别再往 App 里堆信号。
4. **每加一种卡就加一帧快照，每加一行 §5.2 就先加 `registry.test.ts`**（无渲染器、跑一秒）。live == replay 与关掉重开逐字相同这两条不变量对新卡片同样有效——新卡片不许依赖只有流里才有的信息。
5. **`usage` 是每步的增量**（T0 提醒 2），状态栏写的是 `since attach`；`/usage` 视图（T4）别把它当全量。
6. **内核不需要再改**（T0 提醒 5、T1 提醒 6 依然成立）：T2 全程只用了 `session new|append|step --stream|events|cancel`、session 文件首行、以及 `.nulya/extensions/<id>/versions/<v>/extension.json` 的只读读取。§10 那四项一项没动；唯一想加的一行内核修补是 header 的 `created` 实际为空（见"偏离"第 2 条），值得记进 §10 而不是偷偷补在前端。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun test` 40 pass 0 fail（14 快照，3 文件）。

### T3 · nulya 视图

**状态**：完成。四块都落地：`/sessions`（F3；`.nulya/sessions/` 全表、按 `parent` 缩进成树、`● live` 标记、`Enter` 打开成 tab、`n` 新建）；`/ext`（F2；store 列表 + 版本线 + `current` / 本场冻结双标记 + 漂移行 + per-tool usage + 全量 usage 表 + `a`/`r` 动作键带确认）；**SubSessionCard → 第二 tab**（browse 里 `Enter` 打开卡片指名的 session，顶部出现 tab 行）；**observer 模式**（租约探针 + 内核 `SessionBusy` 双信号、`session events --follow` 续接、`press ↵ to take over`）。**内核一行未改**（硬约束 1；§10 那四项一项没动）。`bun test` 52 条全绿（新增 `files.test.ts` / `observer.test.ts` / `overlays.test.tsx`，16 张快照）；`zig build test` / `zig build e2e` 绿。

**关键决定与理由**

- **角色不是一个模式，是关于世界的事实——所以用两个信号，都不猜。** ①`<id>.lock` 探针：内核的租约在 Windows 上是**字节区间锁**，别的进程读第 0 字节就会 `EBUSY`（实测过：空文件、只读句柄同样成立），这是一次**只读、无副作用**的探测，不碰锁、不写文件；POSIX 上同一个租约是 `flock`，读根本看不见 → 探针诚实地答 `unknown`，绝不谎报 `free`。②内核自己的 `SessionBusy`：真去 step 被拒时，`--stream` 上就是一行 `run error{message:"session open failed: SessionBusy"}`，这条在所有平台都权威。于是 `state/attach.ts` 的角色是**持续**跟着世界走的（idle 时每 700ms 探一次，两个方向都切），不是"打开时判一次"。§5.6 已按此改写（先改文档再改代码）。
- **`SessionBusy` 不画成红字。** 它不是错误，是"写者是别人"这个事实。`driver.ts` 在流里截住这一行、不喂给 `state`（否则状态栏会变成 `error:`），转而回调 `onBusy` → 切 observer。被拒的那次 step 什么都没写，用户排队的那句话仍在 inbox 里等对方的 step 边界。
- **take-over 要连续 N 次看见锁空闲（默认 3 × 700ms），且必须手动按 `Enter`。** driver 脚本是 `step → 放锁 → sleep → step` 的循环，单次"锁是空的"只说明我们恰好在两步之间看了一眼。自动抢锁会把别人的循环打断成随机的 `SessionBusy`——谁驱动这场 session 是人的决定，不是探针的。
- **`applyEvent` 按 seq 幂等。** 同一条 ledger 行现在可能从两张嘴进来（自己 step 的 stdout、follower 的 tail），而 seq 单调且事件不可变，所以"见过"就等于"seq ≤ applied"，一次比较解决。`--since` 仍照传，只是不再是正确性的唯一依赖。
- **observer 也能 `append`、也能 `cancel`。** append 投 inbox，由对方在 step 边界排干（DESIGN §3.4）——这正是 §5.6 要的"能说话"。cancel 写的是 `<id>.cancel` 标记，由**持锁者**在它的 step 边界消费（physics #7），所以观察者请求取消是有意义的，只是停下来的不是我们的 step。
- **第二个 tab 不特判 observer。** §5.5 说子 session"自动进 observer 模式"；实现是让它走**同一个** `createAttachment`——父 session 的 shell 正持着子 session 的锁，探针自然给出 observer。少一个特例，多一条一致的路径。
- **tab 行自绘，不用 `TabSelectRenderable`。** OpenTUI 的 tab-select 是可聚焦控件，会和 composer / overlay 的焦点模型打架（我们的焦点只有三态：composer、browse、overlay）。一行 `<text>` 就能表达"哪些 session 开着、哪个在前"，>1 才出现，行为与 §5.5 一致。
- **overlay 自己 `useKeyboard`，App 用 `overlay.active()` 门控**（T2 提醒 3 的直接落地）。overlay 打开时 App 只保留 F2/F3 与退出键，`j/k` 不会被两处同时消费。
- **`/ext` 的 usage 只投影、不排序成"谁会晋升"。** 计数表按 uses 排是显示顺序；内核根本没有别的顺序——上模型工具面的唯一途径是**有人写一条 pin**（`registry.pinned_native_tools` / `session new --pin`，DESIGN §5.1/§5.5），usage 是写 pin 的人读的证据，不是队列。前端造一个"下一个是谁"的排名等于凭空发明一条内核没有的语义（§2.1 写死的纪律）。`a`/`r` 的输出留在 overlay 的一行里，**不进 ledger**——它本来就是 CLI 动作，改的是下一场 session 的组成。
- **`/sessions` 没有删除键。** ledger 只能 append；一个提供"删掉这场"的视图是在假装系统不是这样工作的。要清理用文件系统。
- **overlay 的帧快照把 id 与时间归一化后再存。** session id 与 mtime 每次跑都不同，原始帧永远对不上；归一化后快照仍然钉住**排版**（列宽、换行、标记位置），而不假装易变的部分是稳定的。

**偏离设计之处**

1. **§5.6 的"打开时发现锁被独占"**：实现是**持续**探测 + `SessionBusy` 兜底，角色双向切换；探针在非 Windows 上只会回答 `unknown`。§5.6 已同步改写（多出"两个信号"一条）。
2. **§5.5 的"顶部 `tab-select`"**：用自绘的一行 tab bar 替代 OpenTUI 的 `TabSelectRenderable`（理由见上）。
3. **§5.3 的"本场 ledger 里相关 EvolveCard / CapabilityBanner 时间线（按 seq 跳转）"**：**未做**。它需要 transcript 的 seq→行定位与 scrollbox 的程序化滚动，价值低于其余四块；`/ext` 的漂移行与 usage 已经回答了"这个 ext 现在是什么状态"。留给 T4。
4. **§4.2 的 browse `Enter`**：含义分叉——选中的卡若指名了一个 session（`presentation.sessionId`）则 `Enter` 打开成 tab，否则折叠；`Space` 永远是折叠。§4.4 已补这一条。
5. **§4.4 的按键**：新增 `F4`（下一个 tab）、`Ctrl+W`（关 tab）；已补进 §4.4。`/new` `/sessions` `/ext` 三个 slash 命令落地，`/skills` `/usage` `/settings` 仍未做（T4）。
6. **§3 的模块表**：新增 `state/attach.ts`（角色 + follower）、`state/tabs.ts`、`state/overlay.ts`、`ui/TabBar.tsx`、`ui/overlays/{SessionsView,ExtView}.tsx`、`test/fixtures/driver-loop.ts`；`nulya/files.ts` 补齐了模块表原本就写着的三样（lock 探测 / extensions store / tool-usage 投影）。
7. **§4.5 的状态栏右半**：observer 时是 `step N · observer · driven elsewhere`（warn 色），左半在可以接管时变成 `press ↵ to take over`。
8. `header.created` 仍是空串（§10.8 的那一行内核修补仍未做，CompositionCard 照旧省略时间）。

**怎么运行与测试**

```bash
zig build                                    # TUI 需要一个 nulya 二进制
cd tui && bun install

bun run typecheck                            # tsc --noEmit
bun test                                     # 52 条（6 个文件，16 张快照）

bun run src/main.tsx --session s-…           # 手工看一眼；F2 /ext、F3 /sessions
```

手工重现 observer（两个终端，无需任何 API key）：

```bash
ID=$(nulya session new --model scripted)
# 终端 A（driver 脚本）：
bun tui/test/fixtures/driver-loop.ts "$(which nulya)" . "$ID" ./stop-driver
# 终端 B：
cd tui && bun run src/main.tsx --session "$ID"     # 状态栏 observer · driven elsewhere
# 在 B 里打字发送 → queued，A 的下一步把它排干 → 转正
touch stop-driver                                   # A 退出后，B 出现 press ↵ to take over
```

新增测试：

- `tui/test/files.test.ts`（4 条，无渲染器）：`listSessions`（顺序 / header / 事件数 / 标题）、`probeWriterLease`（真的在别人 step 期间看见 `held`，非 Windows 上接受 `unknown`）、`listExtensions`（真的 `ext init --script` → `build` → `activate`，断言 `current`、版本线、`kind == "script"`）、`readToolUsage`（跑一次 scripted step 后 `builtin.shell` 真的在日志里）。
- `tui/test/observer.test.ts`（2 条，**T3 的完成标准**）：`test/fixtures/driver-loop.ts` 作为"另一个终端的 driver 脚本"被 spawn 起来循环 `nulya session step`，TUI 侧的 `createAttachment` 附上去，逐条断言 ①角色变成 observer ②`lastSeq` 在我们不持任何写句柄时增长 ③observer `send` 的那句话先 `queued`、再被**对方的** step 排干转正 ④脚本退出后 `takeoverReady` 变真而角色仍是 observer（不自动抢）⑤`takeOver()` 后我们自己的 step 真的把事件写进同一个 ledger。第二条把探针关掉（poll 间隔设成比测试还长），只留 `SessionBusy` 一条信号，证明 POSIX 路径也能定角色、且不报 error。
- `tui/test/overlays.test.tsx`（7 条）：`/sessions` 的帧快照 + `j`/`Enter` 真的回调 `onOpen`；别人持锁时 `● live` 真的出现；`/ext` 的帧快照（版本线、`⚡ current`、`▎ this session`、动作键提示）+ `u` 切到 usage 表看到 `builtin.shell`；漂移行（纯函数 + 真帧）；`F3` 开、`Esc` 关；sub-session 卡 `Esc` → `Enter` 真的开出第二个 tab（tab 行出现两个 id、头行换成子 session）；`a`/`r` 动作键真的移动了 store 的 `current`（build 出第二个版本 → 视图里 `r` + `y` → `listExtensions` 断言指针回到第一个版本）。
- T1/T2 的四条不变量测试（live == replay、Enter 驱动一次 step、关掉重开逐字相同、`Ctrl+O`/browse）全部保留且仍绿——App 从"一个 session"变成"一组 tab"之后没破。

**已知问题**

- **非 Windows 上没有 `● live`，角色也只能靠 `SessionBusy` 事后知道。** `flock` 对读不可见，探针只会答 `unknown`（`/sessions` 因此不画标记）。真要在 Linux/macOS 上得到同样的即时性，最小改动是内核在 `<id>.lock` 里写一行 owner pid（§10 的 sidecar 讨论的近亲）——但那是内核改动，T3 不做。**本里程碑全部在 Windows 上验证，非 Windows 路径未跑过。**
- **`/sessions` 每 1.5s 重读一次全部 session 文件**（为了数事件行与刷新 live 标记）。几十场、每场几百事件时无感；5k 事件 × 多场会变贵。T4 的性能项该把它改成"按 size 增量数行"。
- **observer 看不到 deltas**，只有 step 粒度（§5.6 v1 明确接受）。对方 step 进行中屏幕是静的，直到那一步的 ledger 行落盘。真要 deltas 就是 §10.4 的 `<id>.live` sidecar，届时只改 `attach.ts` 的 `startFollow` 一处。
- **两个 TUI 抢同一场 session 没有排队**：谁先按 `Enter` take over 谁拿到，另一个下一次 step 时被 `SessionBusy` 弹回 observer。这正是内核语义，只是 UI 上没有"排队等待"的表达。
- **overlay 里只有键盘**，没接鼠标（transcript 的鼠标折叠是 T2 做的，overlay 没跟）。
- **`/ext` 的 `a`/`r` 没有 dry-run**，确认行是唯一的护栏；执行后本场 session 不变（正确），视图靠漂移行说明"下一场才换"。
- **真实 provider 仍未跑：环境里没有任何 API 密钥**（T1/T2 已记，T3 按硬约束 6 本就不跑）。
- Windows 上 `Ctrl+C` 第一下 kill 的仍只是 step 进程本身（T1 遗留）。

**给下一里程碑（T4 · 收尾）的提醒**

1. **`/help` 要重写**：F2/F3/F4、`Ctrl+W`、browse 里 `Enter` 的两义、observer 的 take-over —— 现在这些只在 README 和状态栏提示里。`/settings` 直接读 `Settings.sources`（已经在收集），`/usage` 直接用 `files.readToolUsage`（已经写好，`/ext` 的第二块就是它）。
2. **性能三处**：`listSessions` 读全文件数行（见"已知问题"）；transcript 5k 事件的回放；`scrollbox` 视口裁剪。前两处都在 `nulya/files.ts` 与 `state/session.ts`，不涉及内核。
3. **`bun build --compile` 要排除 `test/`**：`test/fixtures/driver-loop.ts` 是测试件，不是产品的一部分。
4. **别把"自动继续"塞进 `attach.ts`。** 它现在只有一条自动动作（pending 未转正且队列在缩短时再 step，T1 定的），take-over 是手动的、budget 用尽是手动的 `/step`。"什么时候该继续"仍然是 driver 脚本 / agent 的事（PLAN §3.6、硬约束 2）。
5. **内核不需要再改**（T0 提醒 5、T1 提醒 6、T2 提醒 6 依然成立）：T3 全程只用了 `session new|append|step --stream|events --follow|cancel`、`ext activate|rollback`、以及 `.nulya/` 下的**只读**读取（session 文件、`<id>.lock` 的一次只读探测、`extensions/**/extension.json`、`current`、`tool-usage.jsonl`）。

核验（编排者）：`zig build e2e` 绿 / `bun test` 53 pass 0 fail（16 快照，6 文件）。`zig build test` **首轮出现一次 `232 pass, 1 skip, 1 fail`**，随后无法复现：单测二进制连跑 15 次、`zig build test`（含独立 cache-dir 强制重跑）5 次，全绿；失败当时 T3 的 driver-loop 夹具进程可能尚未退干净、与 durable session 的 `<id>.lock` / 临时目录抢占。**留给 T4 加固**：让涉及锁 / 临时目录的测试对环境里的游离进程免疫（各自独立临时目录、不复用固定 session id），并在 §11 记录结论。

### T4 · 收尾

**状态**：完成。`/help`（F1）、`/settings`、`/usage` 三个 overlay 落地；`[keys]` 覆盖从"能解析"变成"有端到端证据"；`bun run compile` 出单文件 `tui/dist/nulya-tui.exe`（实测 126 MB，能启动、能跑）；`tui/README.md` 重写成 Windows Terminal 上照做能跑的安装 + 一整轮往返；性能三处都动了（回放 O(n²) → O(n)、transcript `history_window`、`listSessions` 增量数行）。**内核语义一行未改**（硬约束 1）——Zig 侧只改了两个测试的等待预算（见下）。`bun test` **60 pass 0 fail**（8 文件，17 快照）；`zig build test` / `zig build e2e` 绿。

**关键决定与理由**

- **`/help` 读活的 keymap，不读一张手写表。** 一份会漂移的按键文档比没有更糟。`HelpView` 拿 `createKeymap(settings)` 的结果画左列，并把与 `default_keys` 不同的那几行标成 `(tui.toml)`——于是"我改了什么键"这个问题在屏幕上有答案，而不是在两个文件之间对账。README 的按键表因此只承诺"这些是默认值，`/help` 才是现况"。
- **`/settings` 只显示，不写。** §7 就是这么定的，理由值得写下来：设定是用户编辑的文件，TUI 也去写就成了同一份真相的第二个作者，"这个值从哪来"从此没有唯一答案。视图同时列出**两个候选路径**（user 层 / 项目层）及其状态（applied / unreadable / absent），所以"该往哪写"也在屏幕上——不需要先去读文档。
- **`/usage` 把两种数分开摆。** token 是瞬态的（流里是**每步增量**，attach 之前的历史根本不属于我们，所以标 `since attach`）；tool 计数是耐久的（`.nulya/tool-usage.jsonl`，跨 session）。把它们并排放又不说清区别，就是在鼓励把前者当总量读。`UsageTable` 从 `ExtView` 里提出来成了独立模块——这正是"第二个 consumer 出现之后才抽 abstraction"（CLAUDE.md）。
- **回放的 O(n²) 是真 bug，不是"5k 太多"。** `firstProvisionalIndex` 从头扫、`dropInFlight` 全表扫，都发生在**每一条**事件上。但 committed 永远是前缀、provisional 永远是后缀（`insertCommitted` 亲手维持的不变量），所以两处都改成从尾部往回走、只碰在飞的那几张卡。再把整条 tail 的回放合并成**一次** store 事务（`applyInto` 与 `applyEvent` 分家）。5k 事件的打开时间 **2119ms → 331ms**，语义一字未变。
- **`transcript.history_window`（新设定，默认 400）。** `viewportCulling` 省的是**渲染**，不是**布局**：5000 张卡挂在树上，每帧都要为它们算 layout。所以只挂尾部一段，其余在 transcript 顶部留一行 `▸ N earlier items · in the ledger, not on screen`。这不是"丢历史"——ledger 文件永远是全的，`history_window = 0` 就全挂。首帧 **823ms → 148ms**，流式每帧 **17.8ms → 1.8ms**（30fps 的预算是 33ms，前者已经吃掉一半）。
- **`listSessions` 增量数行。** T3 留下的问题：`/sessions` 每 1.5s 重读**全部** session 文件。ledger 只能 append（physics #1），所以已经读过的字节永远不会变——缓存 `{consumed, header, events, title}`，每次只读新追加的那一段并数完整行。这是 append-only 直接换来的性能，不是缓存技巧。
- **`--new` 补成真 flag。** §3 写着 `--session | --new [--model p] | --workspace`，T1 只做了前后两个（不给 `--session` 本来就是开新的）。与 `--session` 同时给现在直接报错退出，而不是猜哪个赢。

**偏离设计之处**

1. **§7 的 `[transcript]`**：新增 `history_window`（理由见上）。**已同步补进 §7 的示例**（先改文档再改代码，硬约束 7）。
2. **§9 的 T4 一行 与 本文顶部状态行**：改成已落地。
3. **§4.4 的 `/skills`**：仍未做。skill 的进出是模型的事（`nulya skill list|load` 经 shell），一个只读的 skill 列表现在没有第二个消费者；`/ext` 已经把每个 ext 贡献的 skills 显示出来了。**这是 T4 唯一没做的 §4.4 条目。**
4. **§5.3 的"本场 ledger 里相关 EvolveCard / CapabilityBanner 时间线（按 seq 跳转）"**：T3 记为未做，T4 仍未做（需要 seq→行定位 + scrollbox 程序化滚动；`scrollChildIntoView` 是现成的落点）。
5. **`/help` 是 overlay 而不是状态栏一行**（T2 时是 `setNotice` 一行）。一行放不下 F1–F4、browse 的两义、observer 的 take-over。
6. `header.created` 仍是空串（§10.8 那一行内核修补始终未做）。

**怎么运行与测试**

```bash
zig build                                    # TUI 需要一个 nulya 二进制
cd tui && bun install

bun run typecheck                            # tsc --noEmit
bun test                                     # 60 条（8 文件，17 快照）
bun run compile                              # dist/nulya-tui.exe（单文件，~126 MB）

bun run src/main.tsx --model codex           # 真实 provider
bun run src/main.tsx --session s-…           # 重开
```

安装、`NULYA_BIN` 的三条解析规则、provider/model 怎么选、怎么取消、怎么 resume——全在 [`../tui/README.md`](../tui/README.md)，按 Windows Terminal 的实际命令写。

新增测试：

- `tui/test/views.test.tsx`（**新**，5 条）：`/help` 的帧快照（默认键；再用 `keys.fold = "ctrl+b"` 的设定渲染一次，断言出现 `ctrl+b` 与 `(tui.toml)` 标记）；**`[keys]` 覆盖端到端**——临时 workspace 里真写一个 `.nulya/tui.toml`，跑一轮真实 scripted step，然后 `Ctrl+O` **不再**展开、`Ctrl+B` 展开（两个方向都测，证明是重绑不是"全都展开了"）；`/settings` 的纯函数行 + 真帧（项目文件标 `applied`、`keys.fold` 在表里）；`/usage`（构造的 usage 流 → 1200 与 `90% of input`，加上真实 journal 里的 `builtin.shell`）；`F1` 开 help、`Esc` 关、`/usage` 走 slash 同一扇门。
- `tui/test/perf.test.tsx`（**新**，2 条，**T4 的完成标准**）：夹具往真实 session 文件里追加 5000 条 wire-format 事件行（不付 5000 次真实 step 的代价；文件本身就是 wire format），然后 ①`nulya session events` + `applyEvents` 的**打开**时间 < 1s ②首帧 < 1s、最新一轮在屏幕上、`windowItems` 确实只挂了 400 张且最后一张是最新的、20 帧流式的**每帧**均值 < 33ms。

**5k 事件基准（本机实测，Windows 11 + Bun 1.3.5）**

| 指标 | T3 的实现 | T4 之后 |
|---|---|---|
| 打开（spawn `session events` + 解析 5000 行 + 折进 items） | 2119 ms | **331–348 ms** |
| 首帧（`testRender` + 一次 `renderOnce`，100×30） | 823 ms | **139–148 ms** |
| 流式每帧（`text_delta` + `renderOnce`，均值） | 17.8 ms | **1.8 ms** |

打开 + 首帧合计约 **0.5s**，完成标准（< 1s）达成。三项都是 `bun test test/perf.test.tsx` 每次跑出来的（`console.log` 打印真值，断言留有余量），不是一次性手测。

**flaky 测试的处理结论**

审完 Zig 侧所有涉及锁与临时目录的测试，结论是 **T3 猜的方向（`<id>.lock` 抢占 / 固定路径）不成立**，但那次失败仍然很可能是"环境里有别的进程"造成的，只是机制不同：

- **锁与临时目录本来就是隔离的。** 每个碰 durable session 的测试都在自己的 `std.testing.tmpDir(.{})`（`.zig-cache/tmp/<随机>`）里，session 文件名与 `<id>.lock` 都是**相对那个目录**的；全部 `Dir.cwd()` 的用法只出现在 CLI 的非测试路径。没有任何测试写仓库的 `.nulya/`、复用固定 session id、或依赖 OS 全局临时路径。所以另一个 nulya 进程**拿不到**同一把锁。
- **真正对环境敏感的是三处等待预算。** `environment.zig` 的 `"canceling a running shell…"` 先等子进程写出 `started` 标记，上限只有 `200 × 20ms = 4s`，等不到就**硬断言失败**——机器一忙（另一个 nulya 在跑、并行的 bun test、杀毒软件扫 `powershell.exe`）就可能超。同一个文件的 `"runExtension captures stderr…"` 给 `.cmd` 脚本的 `timeout_ms` 只有 **1s**，而它断言的是 `!timed_out`——这条测的是 stderr 捕获，不是超时。`tools/shell.zig` 的同型循环是同样的 4s。
- **改了什么**：等待上限提到 `1500 × 20ms = 30s`（见到标记立刻 break，空闲时一分钱不多花），`timeout_ms` 改成生产默认 `30_000`。**只改测试，内核语义一字未动。** 改完 `zig build test` / `zig build e2e` 绿。
- **还有一条无法证伪的可能**：`std.testing.tmpDir` 落在 `.zig-cache/tmp/` 下，与并发的 `zig build` 共享同一棵 cache 目录树。若那次失败时另有 `zig build` 在跑，缓存目录层面的干扰无法排除——但这不是本仓库的测试能加固的，真要根治得让测试用 OS 临时目录（约 100 处 `tmpDir` 的改动，代价远大于收益）。**记在这里，等它再出现一次再动。**

**真实 provider 冒烟（跑了）**

T1/T2/T3 三轮都因"环境无任何 API 密钥"跳过。本轮重新检查：`DEEPSEEK_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` 依然全无（只有一个 `ANTHROPIC_BASE_URL`），但 **`~/.codex/auth.json` 存在**——codex profile 的凭据本来就不是 env。于是用 codex 跑了**一轮**（一次 API 调用，未重试）：

```bash
nulya session new --model codex
nulya session append <id> "Reply with exactly: hello from nulya. Do not use any tools."
nulya session step <id> --stream --max-steps 1
```

stdout 全是 JSON、退出码 0、stderr 空；行序与 DESIGN §14 完全一致：`model started` → `text_delta` ×4 → `usage{input_tokens:194,output_tokens:8,cache_read_tokens:0,cache_write_tokens:0}` → `done{stop:"end_turn"}` → `seq1 user_text` → `seq2 assistant` → `step end{completed}` → `run done{steps:1,stopped:"end_turn"}`。再把这段真实 stdout 喂回 TUI 的 `parseStepLine` + `createSessionState`：**0 行解析不了**，usage 累加成 `{input:194,output:8,cacheRead:0,cacheWrite:0}`，items 恰好是 user + assistant 两条。

于是 T0 遗留的两条里，**`usage` 流行在真实 provider 上首次被证实**（状态栏与 `/usage` 的 token 累加走的就是这条路）。**`thinking_delta` 仍未见过真数据**：这一轮模型没有产出可显示的 thinking，codex 的 reasoning 是加密 item、按设计根本不进流（DESIGN §14）。要验证 Thinking 卡的流式尾行，得一个开着 thinking 且回传明文 thinking block 的 Anthropic key。

**已知问题**

- **早上那一轮的这些环节仍未被自动验证**（诚实清单）：alt-screen 的实际观感与重绘、鼠标滚轮与 `scrollbox` 滚动后点击的命中、`Shift+Enter`（需要 kitty keyboard 协议，Windows Terminal 支持；不支持时退 `Ctrl+J`）、`Ctrl+C` 两下、真实 provider 下**带工具调用**的完整一轮（本轮冒烟刻意让模型不用工具，只跑了纯文本路径）、以及**真实 provider 下的 `Esc` 取消**（scripted 下测过，真 provider 下没测）。真实 provider 的 resume 也只在纯文本那一场上成立过。
- **`bun run compile` 出的 exe 不能在 `tui/` 目录里启动**：Bun 会读 cwd 的 `bunfig.toml`，而本包的那份是开发用的 `preload`，编译产物既没有也不需要它 → `preload not found "@opentui/solid/preload"`。在 workspace 里跑就没事（README 已写明）。这是 Bun 的行为，不是我们的状态。
- **`history_window` 之外的卡片不在树上**，所以 browse 模式（`j`/`k`）走不到它们，`Ctrl+Shift+O` 也只影响挂着的那些。5k 事件时窗口是最近 400 张（约 100 轮），要全挂就把 `history_window` 设成 0——代价见上表。
- **`/usage` 的 token 只是本进程 attach 之后的**（T0 提醒 2 的必然结果），视图里明说了；真正的全量需要内核在 ledger 里记 usage，那是内核改动，没做。
- **`/settings` 不显示内核自己的 config**（`default.toml` → system → user → project）。§10.2 的 `nulya config show` 一直没做，前端复刻一份合并逻辑必然漂移。
- **非 Windows 路径依然没跑过**（T3 遗留）：`● live` 与租约探针在 POSIX 上只会答 `unknown`。
- Windows 上 `Ctrl+C` 第一下 kill 的仍只是 step 进程本身，它派生的 shell 子进程可能残留（T1 遗留）。
- T1 的 `settle()` 那条依然成立，而且**在纯文本视图上也会咬人**：`/help` 的帧快照在一次整套跑里抓到过半张画面（单独跑与随后连跑三整套都绿），已把它的 settle 提到 8 遍。新加快照时宁可多睡两轮。

**后续方向（不再有下一个里程碑，写给下一个来动这块的人）**

1. **先 dogfood，再加功能。** T1 起就该在这里面工作了，但真实 provider 的完整一轮（工具调用 + 取消 + resume）到现在只有人能验。用出来的痛点应该压过 §10 里任何一条待议。
2. **`/ext` 的 seq 跳转**（§5.3 未做的那块）落点是 `scrollbox.scrollChildIntoView(id)` + 给卡片一个稳定 id；这是 OpenTUI 现成的能力，不需要内核。
3. **observer 的 deltas** 仍是 §10.4 的 `<id>.live` sidecar，改动只落在 `attach.ts` 的 `startFollow` 一处——但它是内核改动，等第一个真正需要它的 driver 脚本。
4. **内核不需要再改**（T0 提醒 5 起，四个里程碑都成立）：T4 全程只用了 `session new|append|step --stream|events --follow|cancel`、`ext activate|rollback`、以及 `.nulya/` 下的只读读取。§10 那八项一项没动。
5. **性能的下一个瓶颈不在这三处**：真要更快，测的应该是 `EditCard` 的 diff 高度上限与 markdown 解析（两者都跨真实计时器 tick 落地，见 T1 的 `settle()`），不是 items 数。

核验（编排者）：`zig build test` 绿（连跑两轮，T3 那次 flake 未再出现）/ `zig build e2e` 绿 / `bun test` 60 pass 0 fail（17 快照，8 文件）。T0–T4 全部完成。

### T4 之后 · review 修补（2026-08-16）

**状态**：对 `tui/src` 逐文件 review 后修的一轮，全部是前端；**内核一行未改**。`bun test` 71 pass 0 fail（11 文件，17 快照），`bun run typecheck` 绿。每一条都有回归测试钉住（新增 `test/driver.test.ts` / `test/ledger.test.ts` / `test/composer.test.tsx`）。

**修了什么（按严重程度）**

1. **两次快速发送会开两个 step 进程 → 第二个被内核 `SessionBusy` 拒 → 角色误切成 observer。** `driver.send` 只把 `stepping` 当"在跑"，第一条还在 `sending`（append 中）时第二条又走了一遍 `drive()`。现在 `drive()` 有 `driving` 门闩、`send/step` 把任何非 `idle` 都当在跑；同时 `nulya/cli.ts` 的 `sessionAppend` **按 session 串行**——两个并发的 `session append` 进程在 inbox 里没有定义的先后，实测过 "first, second" 落成 "second, first"。
2. **`snapshot.error` 从不清除**：一次 spawn 失败 / `run error` 之后状态栏红到进程结束。现在 `model started` 清掉它（一步真的开始，就是上一次失败已经过去的事实）。
3. **`Ctrl+C` 的"再按一下退出"永远待命**：`ctrlCArmed` 置真后不复位，之后任何时刻的第一下 Ctrl+C 都直接退出而不是先 kill 当前 step。现在新 step 开始时复位，且 3 秒后自动失效。
4. **被消费的全局键也会打进 composer**：OpenTUI 先跑全局 `useKeyboard` 再跑焦点控件，App 从不 `preventDefault()`，于是 `Ctrl+W` 同时"关 tab"和"删一个词"（textarea 自带 readline 绑定），任何与 textarea 撞的 `[keys]` 覆盖都会双发。现在 App 消费的键一律 `preventDefault()`；`Ctrl+W` 只在 >1 个 tab 时归 App，单 tab 时保留 composer 的删词。
5. **step 进程非零退出但没打 `run error` 行时静默**（意外的 Zig 错误、崩溃：只在 stderr 上）。现在 exit≠0 且未见 `run error`、且不是我们 kill 的 → 状态栏显示 `step exited N: <stderr 首行>`。被 kill 的 step 有 `killed` 标记，**不**当崩溃报，也不再触发"pending 收缩就再 step"的循环。
6. **spill 过的 shell 结果丢掉 exit chip**：`emit.zig` 截断时在 `[exit N]` **之后**追加 `[full output: …]`，`shellExitCode` 却锚定行尾。现在取最后一个 `[exit N]`，footer 不进卡片正文（spill 路径已是 `spill_path` 字段，卡片尾行画一次）。
7. **hydrate 与首个 step 的竞态**：`tabs.ts` 先建 attachment 再异步回放 tail；打开后立刻发送，step 的事件先到、回放到达时全部 `seq ≤ applied` 被当重复丢掉。现在 attachment 带一个 `ready` promise，`drive()` 先等回放完。
8. **composer 历史只能取回最后一条**：Up 一次后 buffer 非空，再按 Up 变成光标移动。现在记住"当前显示的是哪条历史"，buffer 仍是那条就继续走历史，用户一改就交还光标。
9. **每张卡一个 resize 监听器**：`CardFrame`/`StatusBar`/`Hairline` 各自 `useTerminalDimensions()`，400 张卡 = 400 个监听器（`MaxListenersExceededWarning` 在 perf 测试里刷屏）。新增 `render/theme.ts` 的 `ScreenContext`/`useScreen()`，App 顶上读一次；单卡测试无 provider 时回退到直接问 renderer。
10. **`Ctrl+C` 只杀 step 进程本身，Windows 上 shell 子进程残留**（T1 起的已知问题）。`cli.ts` 的 kill 在 win32 上先 `taskkill /pid <pid> /t /f` 再兜底 `proc.kill()`（顺序不能反：先杀父进程会把子树孤儿化，taskkill 就枚举不到了）。
11. **take-over 后自己排队的那句话没人排干**：observer 时 `append` 进了 inbox，对方退出、我们接管，之后要再发一句或 `/step` 才动。现在 `takeOver()` 若 `pendingCount() > 0` 就 `step()` 一次——这仍是 T1 定的那条唯一的机械 re-step（我们自己的 pending），不是"自动继续"。
12. browse / `Ctrl+O` 只在**挂着的**卡（`history_window` 内）里走，选到没挂的卡不会再出现"看不见的高亮"。
13. **空场不留**（同一天补的）。TUI 启动即 `session new`（为了首屏就能画冻结组成与 id），看一眼就退会留下一个"只有 header、0 事件"的文件，dogfood 一周 `/sessions` 就是一列空行。现在 **TUI 自己造的**（无参启动 / `--new` / `/new` / `/sessions` 的 `n`）session 在 tab 关闭或退出时若**从未记录任何东西**就被撤销：`nulya/files.ts` 的 `discardIfUntouched` 是这个程序对 `.nulya/sessions/` 的唯一一处写，四道门任一为"否"就不删——有事件行（那已经是 ledger，physics #1）；inbox 非空（有人 append 了、还没被 step 排干，里头是用户打的字）；租约被持有（此刻正有 step 在跑）；非 Windows 上只要 `.lock` 存在（探针看不见 `flock`，答"不知道"就不动）。`--session <id>` 打开的、别人的，**永远不是候选**——另一个 TUI 空闲地坐在它自己刚建的空场上，从外面看和这个一模一样，删掉会让它的下一次 `append` 报 `no such session`。§5.4 的"`/sessions` 无删除键"仍成立：那是关于有内容的 ledger 的。测试：`files.test.ts` 四道门各一条、`lifecycle.test.tsx` App 级三条（造了没用→没了；造了用了→在；按 id 打开→在）。

**没改、但值得你知道的**

- **模型 / preset 选择器**（tcode 那种）：**没有**。`--model <profile>` / `/new --model <profile>` 手打 profile 名。模型选择器本身不复杂（一个 overlay 列 profile → Enter → `session new --model` 开新 tab；模型冻结在 session 头，"换模型"永远等于"开新场"），卡在 §10.2 的 `nulya config show [--json]`——没有它，前端得自己复刻 `default → system → user → project` 的合并（含 project 层只能收窄）才知道有哪些 profile，必然漂移。那是 `cli.zig` 外壳层几十行，不是内核改动。**preset 选择器**：内核没有 preset 概念，`session new --system-file/--skill/--pin` 都还没落地（§10.7），没有东西可选，现在做是空中楼阁。
- 不干净的退出（关终端窗口、`kill -9`）留下的空场不会被扫：TUI 无法区分"我上次留下的"和"另一个进程刚建的"，宁可留一行也不删别人的。
- §4.5 的 `↓ N new`（离开底部时的新内容提示）仍未做。
- 非 Windows 上租约探针仍答 `unknown`（T3 起）。

核验：`bun run typecheck` 绿 / `bun test` 75 pass 0 fail（12 文件，17 快照）。内核未动，`zig build test` / `e2e` 不受影响。

### T5 · `/model` 选择器、effort、`config show`（2026-08-16）

**状态**：完成。这是 T0 之后**第二次**碰内核，全部在外壳层（`config.zig` / `launch.zig` / `cli.zig` / `providers/openai.zig` / `default.toml`），frozen core（§15.1）一字未动：header 形状不变（`model` 仍是 profile 名、`model_identity` 仍是解析后的身份），`resolveDescriptor` 只多了一个可选 model id 参数。`zig build test` / `e2e` 绿；`bun run typecheck` 绿；`bun test` 82 pass（13 文件，18 快照；`files.test.ts` 的租约探针一条在整套并跑时偶发 60s 超时、单跑绿——T3 起的老 flake）。

**关键决定与理由**

1. **模型的两张表（DESIGN §9.5）。** 原来 profile 把"怎么连"和"用哪个 model + effort"捆在一起，一个 endpoint 换个模型就得再抄五行 profile。现在 `[[provider.profiles]]` 只说怎么连 + 服务哪些 `models[]`，`[[models]]` 目录说一个 id 是什么（label / efforts / default_effort / context_window）；同一个 `deepseek-v4-flash` 经 openai 口和 anthropic 口只写一次。目录是**纯描述**（kernel 不读；`Config.defaultEffort` 与 `config show` 读），落在 config 层而不是 TUI，因为它有两个 consumer：选择器和 agent 自己（`nulya session new --profile … --model …` 时该知道有哪些）。**"删掉它八条 physics 哪条失效"→ 一条都不 → 不是 kernel**，所以只到 config/cli 为止。id 与档位按各家文档核过（2026-08）：DeepSeek `reasoning_effort` 只认 low|high|max（medium 折成 high），所以目录列 `off|low|high|max`。
2. **`session new --profile P [--model ID]`，`--model` 回归字面意思。** 原来 `--model` 吃 profile 名是命名疤痕；小项目直接改、不留兼容（e2e / tui 测试全部同步）。不存在的 profile 现在**拒绝**（exit 1、提示 `config show`），存在但缺 key 的仍冻结 scripted（离线替身语义不变）但 stderr 明说——给人用的入口不该把 typo 变成一场静默的 scripted session。
3. **effort 是每步的 generation option，不是身份。** 内核本来就在 step 时从 config 读 effort（DESIGN §3），所以 `session step --effort E` 只是把这个决定交给 driver；TUI 里 effort 是 **tab 级**状态（`SessionTab.effort`），`/model` 选的、`/effort` 改的，下一次 spawn step 时带上。header 上显示 `· effort high`。
4. **`nulya config show --json`（§10.2 落地）。** `{active_profile, profiles[]{…, credential: bool, models[]}, models[]}`；credential 用与 `resolveDescriptor` **同一个**判定（`launch.credentialAvailable`），所以选择器标 ready 的行 `session new` 一定不落 scripted。永不报值、inline `api_key` 不出现（单测钉住）。TUI 因此不复刻配置合并链（D10）。
5. **`/model` 是一张平表**：每个 (profile, model) 一行，`↑↓` 移动、`←→` 转该行的 effort 档位（`auto` + 目录档位，tcode 同款）、Enter 开新场、Esc 回；缺 key 的行**留在列表里但变暗、行尾写 `set DEEPSEEK_API_KEY`**，Enter 在上面只报原因不动作——"为什么选不了"的答案在行上，不在文件里。当前 tab 的 (profile, model) 标 `✓ current`；列表比屏幕高时按光标开窗（`windowRange`，上下各一行 "N more"）。
6. **换模型 = 开新场，但空场就地替换。** 一个 TUI 自己造的、0 事件、空闲的 tab 上按 Enter，新 session **取代**这个 tab（旧文件经 `discardIfUntouched` 撤销）而不是并排开第二个——启动 → 选模型 → 开始工作，看不到 tab 增生；用过的 tab 才开第二个（`tabs.replace`）。
7. **`tui-state.json`（D10）。** 程序唯一写的文件：上次的 (profile, model, effort)。启动顺序 `launch.planLaunch`：命令行 `--profile/--model/--effort` > 上次选择 > 内核 `active_profile`，每层都要 `config show` 说它有 key 才算数；命令行点名的跑不了→直接 stderr 拒绝（不静默换）；隐式的都跑不了 → 起离线 scripted 场并**开屏即选择器**，标题下一行写原因（`openai needs OPENAI_API_KEY · this session is the offline stand-in · pick one marked ready, or set the key and restart`），composer 让出键盘。`/new` 无参 = 上次选择；`/new --profile p` 是一次性的、不记住。
8. **DeepSeek 两个坑（tcode 踩过、官方文档核实）。** `off` 在 DeepSeek 发 `thinking:{type:"disabled"}`（它默认开 thinking，`reasoning_effort:"off"` 不是一个档位）、别处什么都不发；**带 tool_calls 的 assistant 轮的 `reasoning_content` 必须原样传回**否则 400——现在 openai 口在 DeepSeek 端点上把本轮 `reasoning_content` 拼成一个 `reasoning_item`（`{"reasoning_content":"…"}`）走已有的 reasoning 回放机制（与 anthropic thinking / codex encrypted item 同一条路），只挂在带 `tool_calls` 的 message 上。**未在真实 key 上跑**（本机没有 `DEEPSEEK_API_KEY`），单测钉住 wire 形状；`NULYA_INTEGRATION_PROFILE=deepseek zig build integration` 是下一步该跑的活证据。

**偏离设计之处**

- §3 里 `main.tsx` 的参数由 `--model <profile>` 变成 `--profile <p> [--model <id>] [--effort <e>]`；`/new --model p` 同步改。README 与 §2.1 表已改。
- default.toml 的 `openai` 默认模型从 `gpt-4o-mini` 换成 `gpt-5.6-sol`（目录里的 id，随 tcode 2026-07 核过的清单）；`launch.default_openai_model` 仍是 profile 未写 model 时的兜底。

**没做 / 给下一里程碑**

- **preset（整套 lineup）没做**：单角色世界里 preset ≡ profile；等 sub-agent 有第一个 consumer、有了角色，preset 落 `tui.toml`/driver 侧、以文字告诉 agent，不进内核。
- `codex` profile 的 `models` 只有 `gpt-5.5`（tcode 是从本地 runtime 目录填的），要多个再加目录条目。→ **已改**（2026-08-18）：内核 `config show` 现在为没写 `models` 的 codex profile 读 Codex CLI 的 `~/.codex/models_cache.json`，并在 `profiles[].catalog` 里给出该端点自己报的参数（DESIGN §9.5）；TUI 的消费见 T21。
- 选择器不做鼠标；`/effort` 不校验档位（打错了 provider 会 4xx，状态栏可见）。
- `--session <id>` resume 的 tab effort 起于 undefined（kernel 默认），不从 state 找；等真的需要再做。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun run typecheck` 绿 / `bun test` 82 pass 1 flake（`probeWriterLease` 整套并跑超时、单跑绿）。

### T5 补记 · `~/.nulya`、文件里的 key、选择器里贴 key（同日）

**状态**：完成。`zig build test` / `e2e` 绿；`bun test` model.test.tsx 11 条（新增 credentials 写入/替换、真二进制 `NULYA_HOME` 回路、`s` 贴 key 流程）。

**关键决定与理由**

1. **user 层配置搬到 `~/.nulya/config.toml`**（Windows `%USERPROFILE%\.nulya\config.toml`），`tui.toml` / `tui-state.json` 同目录；`NULYA_HOME` 整体搬走（测试用它隔离）。原来的 `%AppData%\nulya` / `~/.config/nulya` 在 Windows 上难找，且与 workspace 的 `.nulya/` 不同形。`nulya config show` 现在先打印三条路径。
2. **profile 自己的 `api_key` 真正生效**（原来能解析、不被读——正是 CLAUDE.md 说的"只写不读"信号）。`launch.credentialSource`：`config > env > login`。边界不变：key 不进 session 文件、不进工具子进程 env、不从 project 层来（DESIGN §9.5 改写了这一段）。**它不只是方便**：`environment.isSecretKey` 会把 `*API_KEY*` 从模型 shell 的 env 剥掉，所以 sub-agent 自调用（模型自己 `nulya session new`）唯一能拿到 credential 的路径就是 kernel 自己读文件。
3. **`/model` 里按 `s` 贴 key**：一行 `<input>`，Enter 写进 `config show` 报的 `paths.user`——`nulya/credentials.ts` 追加/就地替换一个带标记的四行块（`# nulya: api_key for profile "x" …` + `[[provider.profiles]]` + `name` + `api_key`），靠内核"同层同名 profile 按序合并"的语义只覆盖 `api_key`；人的内容一字不动。存完自动 `r`，行变 `ready · key in config`。开屏引导句改成"pick a row marked ready, or press s on one to paste its API key"。
4. `default.toml` 加 `openrouter`（anthropic 口，`https://openrouter.ai/api`，`OPENROUTER_API_KEY`，`tencent/hy3:free`），与 tcode 同款；`config show` 多 `credential_source`。

**给下一里程碑**：key 输入不做遮罩（本地终端、写完即消失）；`s` 只服务 openai/anthropic 两种 kind（codex 走 `codex login`）；新增一个**不在**内置列表里的 endpoint 仍要手写 5 行 profile——真要"屏幕上加 provider"再做向导。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun run typecheck` 绿 / `bun test` 86 条：单文件全绿；整套并跑时 1–3 条**进程重**的测试（`probeWriterLease`、driver "killed step"、`discardIfUntouched`）偶发超时，每次不同、单跑都绿、无残留 `nulya` 进程——去掉 model.test.tsx 整套跑同样有 1 条，是本机负载下 T3 起的老现象，不是逻辑回归。

### T6 · 用出来的痛点：composer 塌陷、provider/model 两级、空屏与 slash 补全（2026-08-16）

**状态**：完成。`bun run typecheck` 绿；`bun test` 99 pass（新增 `test/layout.test.tsx` 6 条 + composer 2 条 + model 4 条）；`bun run compile` 出单文件。

来源是一次真实试用给出的三条：①`/model` 配的是"模型"不是"provider"，一个 provider 铺开成好几行、挤满屏幕，而且没有地方填 compatible endpoint；②对话一轮之后 **composer 不见了**；③整体太简陋。

**关键决定与理由**

1. **composer / 状态栏 `flexShrink={0}`（真 bug，②的根因）**。三块布局里 composer 只是普通 flex child：transcript 一长，flex 协商就把它压成 1 行、再压成 0 行——不报错，只是**屏幕上没有能打字的地方了**。`test/layout.test.tsx` 把它钉死：30/24/16/10 行终端 + 80 行的回答，prompt 行与其下两行必须都在。同一类问题在 overlay 上也存在（`/help` 变长后行画在行上），所以 `HelpView` 的正文进 `scrollbox`，`SessionsView` 跟 `ModelView` 一样窗口化（`ui/list.ts` 的 `windowRange` / `visibleRows` 抽出来共用）。**规则**：底部两块永不收缩，中间那块要么滚动要么窗口化。

2. **`/model` 变两级：providers → 它的 models（①）**。原来一行一个 `(profile, model)`：七个内置 profile 变成十四行，其中十三行重复同一句 credential 状态，而且大半是没有 key 的 provider 的模型。现在第一层一行一个 profile（wire + endpoint host + 几个模型 + 能不能跑），Enter 钻进它的模型（effort dial 在这一层）。credential 归 provider，所以 `s` 在两层都是"给当前这个 provider 贴 key"。没有 key 的 provider **仍然可以进去看**——Enter 才说明为什么不能跑，浏览不该被拦。

3. **`a` = 加一个 OpenAI/Anthropic-compatible provider（①的后半句）**。tcode 的 `setup::Setup` 是一个状态机走 name → protocol → base_url → models；这里同形：name → wire（两行菜单，各带一句"谁属于这一类"）→ base URL → 逗号分隔的 model ids → key（可空）。写进 `paths.user` 的**一个**带标记块（`nulya/credentials.ts` 的 `writeProfile`）。`placeBlock` 从"按行数替换"改成"替换到下一个空行"——profile 块的长度随 model 列表变，按行数替换会留下孤儿行。内核一行没改：它本来就说两种 wire，缺的只是"不离开 TUI 就能说出来"的地方。
   - 每一步的输入框**必须**清空：`<Show keyed>` 在同一帧内 unmount/remount 会复用底下那个 renderable，于是 base URL 前面粘着刚打的 profile 名（`openrouterhttps://…`）。`createEffect` 在每个 text step 开始时清一次。
   - 全局按键里开输入框的那几处要 `preventDefault()`（`a` / `s` / wire 的 Enter / add 行的 Enter），否则同一次 dispatch 里新挂上来的输入框会把这个键当成自己的第一个字符/一次空提交。
   - 被拒绝的字段**保留原文**（改比重打便宜）；测试用 `pressBackspace` 擦。

4. **③的三件**：
   - **空 session 首屏**（§4.1 一直写着、从没做）：`ascii_font` wordmark + 一句话 + 四条 `/` 入口 + 一行"怎么开始"。不是卡片——没有事件支撑它。第一条 turn 落地即消失。model/tools 不重复写，上面那张 CompositionCard 已经说了。
   - **slash 补全**（§4.4 一直写着、从没做）：`src/commands.ts` 是唯一的命令表，`App.runCommand` 派发它、composer 补全它、`/help` 列它。composer 上方列出还可能是哪几条，`Tab` 补第一条。**没有**可上下选的菜单：Enter 永远发送写着的东西，这是输入框不能破的承诺。只补第一个词——有空格之后是参数，在参数上弹菜单是噪音。
   - **回读**：`PgUp` / `PgDn` / `Shift+End` 进 keymap（`/help` 原来就在吹这个键、却没人绑）。离开底部时状态栏出 `▾ N more below · Shift+End`，要**连续两次**探测到才显示——长回答排版时 box 会短暂离开自己的 sticky bottom，每条长回答闪一下比不显示更糟。

**偏离设计之处**：§4.1 说空屏是"wordmark + session 信息 + 三条提示"，session 信息那半删了（与 CompositionCard 重复）。§4.4 的补全设计成"小补全弹窗"，实现成不可选的提示列表 + Tab，理由见上。

**怎么看一眼**

```bash
cd tui && bun test test/layout.test.tsx test/model.test.tsx test/composer.test.tsx
bun run src/main.tsx --profile scripted   # 空屏 → 打 `/` 看补全 → F5 看两级选择器
```

**已知问题 / 给下一里程碑**
- `ExtView` / `UsageView` / `SettingsView` 还没窗口化，条目一多同样会画出界（`ui/list.ts` 已经备好）。
- `a` 加的 provider 不写 `[[models]]` 目录条目，所以它的模型没有 effort dial、没有 context window——目录是"一个 id 是什么"，等真需要再给表单加一步。
- `more below` 是 200ms 轮询 + 两次确认，不是事件；鼠标滚轮之后最多晚 400ms 才出现。真嫌慢的话要 OpenTUI 给 scrollbox 一个 scroll 事件。
- mock 键盘没有 PgUp/PgDn，`test/layout.test.tsx` 直接往 `renderer.stdin` 灌转义序列。

核验（编排者）：`bun run typecheck` 绿 / `bun test` 99 pass 0 fail（`files.test.ts` 的 `probeWriterLease` 在整套并跑时偶发超时、单跑绿——T3 起的老现象）/ `bun run compile` 出 `dist/nulya-tui.exe`。内核 `src/` 一字未改。

### T7 · compaction：同一场对话，换个文件（2026-08-16）

**状态**：完成。内核侧补了 fork 原语的缺口（`session new --parent` 校验父存在 + 继承父的冻结身份，DESIGN §11/§14）；前端新增 `/compact [focus]`、压缩两条 turn 的卡片、状态栏的上下文占用。

来源：内核盘点发现 `compaction.max_input_tokens` 能解析但无人消费、`context_window` 只被 `config show` 打印——也就是说**长 session 撑爆上下文时是硬失败，没有任何降级路径**，而 TUI 已经能让人坐着聊很久了。

**关键决定与理由**

1. **压缩是外挂，不是内核。** 拆成三件事之后归属自明：何时压 = policy（driver）；压成什么 = intelligence（模型）；新文件 + parent 指针 + 身份延续 = substrate（内核）。前两件一行都没进 `src/`；第三件只动了 `cli.zig` 这层外壳，`session.zig` 一字未改。整个 `/compact` 是 `session append` + `session step` + `session new --parent` 的组合，内核既不知道也不关心发生过一次压缩。

2. **摘要在旧 session 内部生成，不开子 session**（参考了 tcode 的 `agent/compact.rs`，但结论不同）。tcode 就地替换历史、共享 cache scope；nulya 不能替换历史（physics §1/§3），所以本来打算开一个子 session 去总结。**那是错的**：压缩恰好发生在缓存前缀最大的时候，子 session 是另一个文件、另一个 cache 域，等于把整份转录当全新 input 再付一次全价——正是要压缩的那个东西。改成在旧 session 里 append 一条压缩请求再 step，走的是已缓存的前缀。代价是请求与摘要成为旧 ledger 里两条真实事件，这反而诚实：那个文件记下了自己为什么结束。

3. **身份继承、composition 不继承。** 两者都是 session 边界上的决定，方向相反：模型身份是"在跟谁说话"，压缩换人是意外，所以 `--parent` 不点名模型时原样继承父 header 的 `model_identity`；而 composition 的冻结点、promotion 的晋升点本来就是 session 边界（DESIGN §5.5/§7.5），fork 是个边界，让它自然吸收新晋升与新版本才一致。

4. **失败必须什么都不动。** `/compact` 的每一条早退（observer、正在 step、空 session、模型没给出文本）都让对话停在原地。摘要先写出来，再动任何东西；拿不到摘要就明说 `nothing moved, this session is still the live one`。半途而废的压缩 = 丢掉一整段对话，这是这个功能唯一真正危险的失败模式。

5. **两个 marker 是前端与自己的约定**，不是内核概念——内核看到的就是两条普通 `user_text`。它们存在只为让 transcript 把"机器写的那两条"折起来（请求默认折叠、摘要默认展开），以及让一条不是人打的摘要看起来不像人打的。

6. **不自动压。** 阈值键仍然无人消费；状态栏只在 ctx ≥60% 时把 `/compact` 显示出来。自动压缩失手的代价是一整段对话，先让人按，等有真实使用证据再说。

**偏离设计之处**：PLAN §3.4 原写"由 agent 或 kernel 生成 summary"，实现只做了前者（kernel 不生成任何东西）；原写"summary 为首条事件"，实际是投进新 session 的 inbox、第一次 step 时才进 ledger——`session append` 本来就是这个语义，没有为它开第二条路。

**怎么看一眼**

```bash
zig build e2e
```

```bash
cd tui && bun test test/compact.test.ts
```

聊两句之后打 `/compact`，看新 tab 顶上的 summary 卡（`bun run src/main.tsx --profile scripted`）。

**已知问题 / 给下一里程碑**
- `/sessions` 不显示 parent 链：压缩后父与子是两行，看不出是同一场对话。
- 压缩请求跑的是这个 tab 的 `--max-steps`，模型若违反"不要调工具"会多跑几步；`summaryFrom` 取请求之后的全部 assistant 文本，够用但不精确。
- 摘要质量没有测试，也测不了；`test/compact.test.ts` 钉的是"拿不到摘要时什么都不动"这类不会丢东西的性质。
- 上下文占用取自最后一步的 usage，只有 `--stream` 这条路有 usage，所以 observer 模式下不显示。
- `/help` 已经满了：加 `/compact` 之后 `/cancel` 以下要滚动才看得到。再加命令之前得先想清楚这一页怎么分组。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun run typecheck` 绿 / `bun test` 100 pass 0 fail（`driver.test.ts` 的 "killed step" 在整套并跑时偶发超时——干净树上同样复现，T3 起的老现象，非本轮回归）。

### T8 · 慢速回路的前端：判决、穿衣服、成本（2026-08-16）

M5 在内核里放了四个面（outcome journal / per-step usage / 多 store root / `--with`），前端一个都没接。这一轮全部接上，**内核一行没改**。

1. **`/sessions` 改读 `nulya session list --json`。** 原来的实现自己 open 每个 session 文件、增量扫 header 与事件数，是 T3 时内核还没有这个投影的产物。现在 composition / parent / 事件数 / usage / 最新 verdict 一次拿到，`files.ts` 里的 `listSessions` + 扫描缓存整段删掉（-100 行）。**没有全搬**：`● live` 还是本地锁探针——"此刻谁在写"不是文件里的事实，`session list` 也不该假装知道；列表 8s 一刷（一个进程 + 读全部文件），探针 1.5s 一刷（不开进程）。
2. **`/outcome <verdict> [note]`。** 一行 CLI，判决进 outcome journal 而不是 ledger——它是关于这一场的判断，不是这一场里的一个 turn，所以内核不取 `<id>.lock`，正在 step 的场、别人在 drive 的场都能当场评（测试里断言评完 `events` 没变）。`/quit` 在"这一场干过活且本进程没评过"时问一次、再打一次就走；`Ctrl+C` 是逃生口，永远不问。**没做**：verdict 选择器 UI——三个词打出来比按方向键快。
3. **`/evolve` 与 `/mode <id>[@<v>]`（`src/evolve.ts`）。** 两个动作同一条路：`ext build` 一个 draft → `session new --with <id>@<version>`。都**不 activate**：`--with` 是这一场的 composition membership，activate 会让此后每一场都冻结它。每次都 build 是故意的——version 是 draft 的 hash，没改就是同一个 version，于是改了 prompt 不用记得重建。composition 在 `session new` 冻结（physics #2），所以两者都开新场，没有"给当前对话换个 system prompt"这种东西，前端也不假装有。
4. **成本以 ledger 为准。** `assistant.usage` 现在被读进 `UsageTotals`：流里的 `usage` 事件仍然即时显示（否则一步结束前状态栏是空的），但它是 provisional，同一步的 ledger 行落地时把它换掉——一步只算一次。收获是重开一场就能看见它至今花了多少、observer 模式也有成本与 ctx%（以前两者都要"since attach"），代价是 `session.ts` 里多一个一格深的队列（`step end` 时清空孤儿：那一步的 ledger 行早在 marker 之前就刷过了）。`/usage` 的 "steps watched" 变成 "steps priced · N watched here"——provider 没报 usage 的步是**缺席**不是 0。
5. **`/ext` 认多 root。** 清单改用 `nulya ext list`（root 顺序、`(shadowed)` 都是 kernel policy，TUI 不复刻），右栏写明来自哪个 root、被遮蔽的标红说明"永远不会跑"。顺带修一个 M5 之后才显形的洞：只用 `--with` 穿的包一辈子没有 `current`，原来的 manifest 回退是"current → draft"，store 里没有 draft，于是 evolution 在 `/ext` 里显示成没有任何贡献——改成"current → 最新 build → draft"。`contributes.system_prompts` 也开始显示（`/ext` 的 `prompts N`、CompositionCard 的 `prompts 1`）：一个 mode 包往往**只有**一个 prompt，不显示它等于说这一场什么都没穿。

**新的 CLI 面**（都在 `src/nulya/cli.ts`，别处不认得 flag 名）：`sessionList` / `sessionOutcome` / `extBuild` / `extList` / `sessionNew({with})`。`ledger.Usage` 是内核那一个 struct 的镜像，`StreamUsage` 直接是它的别名——内核 M5 review 刚把两个 Usage 合成一个，这里没有理由再分叉。

**怎么看一眼**

```bash
cd tui && bun test
```

真跑：`/evolve` 之后看顶上的 CompositionCard 有没有 `evolution@v-…` 与 `prompts 1`；`/outcome success 试了一轮` 之后 `F3` 看那一行的 `+ success`。

**已知问题 / 给下一里程碑**
- `/mode` 没有补全也没有列表：打错 id 只会得到内核的一行错误。`/ext` 里加一个"穿上它"的键（比如 `w`）比补全更值。
- `/evolve` 只认仓库里的 `extensions/evolution`；在别人的 workspace 里就是一句 build 失败。真要在别处用，得先想清楚这个包该住在哪个 root。
- `/quit` 的"问一次"只记本进程评过谁，不去查 journal：昨天评过的场今天再开还会被问一次。查一次 `session list` 就能不问，但那是启动路径上的一个进程。
- verdict 只能给**当前 tab**，`/sessions` 里选中一行直接评（`s`/`p`/`f`）会更顺手。
- 整套并跑时 `driver.test.ts` 的 "killed step" 与 `overlays.test.tsx` 的 live 标记偶发超时——T3 起的老现象（负载敏感），单独跑都是秒过。

核验（编排者）：`bun run typecheck` 绿 / `bun test` 111 pass 0 fail（快照 3 处更新：`/help` 多了三条命令、`/ext` 多了 root 行、CompositionCard 多了 `prompts`）。`src/` 本轮一行未动，所以内核的绿由它自己的 `zig build test` / `e2e` 负责，不在这一条里重复声明。

### T9 · `/compact` 交给 `extensions/compact`（2026-08-17）

**状态**：完成。T7 把压缩过程写在了 TUI 的 TypeScript 里（`compact.ts` 的 `compactPrompt`/`summaryFrom`/`openCompacted` + `App.compactNow`）。PLAN §0 的承诺是"内核之上的一切住在 AI 可读、可版本化的媒介里"，而 §3.6 又要 `/goal` 复用同一条 fork 路径——两条都指向同一个动作：**把过程搬进随仓库带的 extension，前端只 spawn 它并跟着看**。

1. **过程搬家。** `extensions/compact`（compiled，`bin/compact`）contribute 一个 `compact{session, focus?, max_steps?}` tool，七步与 T7 逐字相同（DESIGN §11 列了）。prompt 原文 `@embedFile` 成 `src/compact_prompt.md`，随 version 一起冻结——改 prompt 就是改 version，不再是改前端。
2. **为什么是 compiled 而不是脚本。** driver 必须**解析 `nulya session step` 打印的 JSONL**：`sh` 没有 JSON 读取器（jq 不保证有）、Windows 连 jq 和 python 都不保证，写两份脚本实现同一个过程更糟。这正是 PLAN §0.1 #3 给 Zig 留的位置（脚本是默认，Zig 是实测需要时的选择）。代价诚实地记在这里：第一次在一台机器上 `/compact` 需要一个 zig（`NULYA_ZIG` / 内嵌 / PATH 三档，DESIGN §10），build 失败时前端把内核那句指路原样显示。
3. **内核只加了一个变量。** `NULYA_EXE`（`LocalEnvironment.init` 放的本进程绝对路径，DESIGN §7.6/§9）——子进程要调 `nulya` 时该调的是**正在跑的这个**二进制。没有它，driver 型 extension 只能猜 PATH。
4. **前端剩下什么。** `compact.ts` 只留两个 marker（折叠用；`main.zig` 是它们的源头）、`compactionMarker`/`withoutMarker`，加一个 `runCompact`（`extBuild` → `extRun` → 读结果 JSON）；`compactPrompt`/`summaryTurn`/`summaryFrom`/`openCompacted` 删掉。`App.compactNow` 保留三条早退（observer / 正在 step / 空场）、换 tab、失败时把 notice 换成工具那句话。`cli.ts` 多一个 `extRun`（`nulya/` 之外仍然不认得 flag 名）。
5. **跟随靠已有的 observer 模式。** 工具跑的时候持着旧 session 的 `<id>.lock`，所以那个 tab 的 attach 探针自己翻成 observer，`session events --follow` 把请求与摘要**作为整条事件**送进 transcript——**没有 delta 了**（deltas 只在自己的 `session step --stream` stdout 上）。取舍是：过程搬出去换来"这段等待期间屏幕上是整条一整条地出现"，而不是逐字。失败路径多做一件事：如果这时还停在 observer，直接 `takeOver()`，不让用户为了拿回自己的 session 去按 Enter。
6. **新 tab 不再乐观回显摘要。** 前端不知道摘要文本了（它在旧 session 的 ledger 与新 session 的 inbox 里）。第一次 step 之后它就是 turn 1，卡片照旧。

**怎么看一眼**

```bash
zig build e2e            # "bundled compact: …" 这条钉住整个 fork
```

```bash
cd tui && bun test test/compact.test.ts
```

真跑：聊两句 → `/compact` → 旧 tab 变 observer、两条折叠卡出现 → 新 tab 顶上是新 id。

**已知问题 / 给下一里程碑**
- **30s 上限。** `ext run` 走 `tool.Timeouts.extension_ms`（DESIGN §7.3），而步骤 2–3 在等一个真实模型。慢 provider 会撞上它：撞上时只有旧 ledger 里那两条事件，什么都没搬，可以再按一次——但这是这一轮最该先解决的事（要么 driver 型调用有自己的预算，要么 `ext run` 能带一个）。
- `/compact` 现在需要一个 zig（第一次 build）。在别人的 workspace 里没有 `extensions/compact`，和 `/evolve` 同一个洞。
- 摘要质量仍然测不了；TS 侧只钉两个 marker 的往返，其余交给 `zig build e2e`。
- T7 的那两条仍在：`/sessions` 不显示 parent 链；上下文占用只有 `--stream` 那条路有 usage。

核验（编排者）：`zig build test` 绿 / `zig build e2e` 绿 / `bun run typecheck` 绿 / `bun test` 110 pass（`files.test.ts` 的 `probeWriterLease` 与 `overlays.test.tsx` 的 live 标记在整套并跑时偶发超时——T3 起的老现象，单文件跑都是秒过）。

### T9 之后 · Linux 的租约探针（2026-08-17）

**状态**：完成。T3 的第一条已知问题（"非 Windows 上没有 `● live`，角色只能靠 `SessionBusy` 事后知道"）在 Linux 上解除；内核零改动。

1. **根因。** 内核的租约（`ledger.acquireWriterLease`）在 Linux 上是 `flock(2)`——Zig std 在 `posix.O` 没有 `EXLOCK` 的平台走 `flock` 路径（0.16 的 `Io/Threaded.zig`）。锁随句柄关闭释放，但锁**文件**永不删除（POSIX 惯例，unlink 有竞态），而 `files.ts` 的非 win32 分支把"锁文件存在"直接当 held/unknown → `discardIfUntouched` 在 Linux 上恒 false（每个看一眼就关的 session 都留下空文件）、探针恒 `unknown`（observer 只能等 `SessionBusy`）。
2. **探法：查 `/proc/locks`，不去碰锁。** 内核把每个 flock 公示在 `/proc/locks`（`FLOCK ADVISORY WRITE <pid> <maj>:<min>:<ino> …`）；`stat` 锁文件拿 dev:inode、按 glibc 的 `gnu_dev_major/minor` 拆 `st_dev`、在表里找同 inode 的行——**纯读**，与 Windows 的字节区间探针同一性质。曾考虑 `flock -n <file> -c true` 子进程：语义匹配（同为 flock(2)），但它是 try-acquire——探针持锁的那一瞬，真 writer 的 `LOCK_NB` 会被挤成假 `SessionBusy`（attach 每 700ms 探一次、driver 脚本循环抢锁，撞得上），故弃。匹配放宽到"该 inode 上任何锁都算 held"：内核只拿 flock，但万一将来 std 换锁种，错向 held 是保住活 session 文件的方向。
3. **`discardIfUntouched` 收敛成一条。** 平台分支删掉，守卫统一为 `probeWriterLease(...) !== "free"`：win32 走字节探针（行为不变）、Linux 走 `/proc/locks`、没有 `/proc` 的 POSIX（macOS）照旧 `unknown` → 保守留下。
4. **测试收紧。** `files.test.ts` 的探针断言在 Linux 与 Windows 同级（idle 必须 `free`、别人 step 期间必须见到 `held`）；`overlays.test.tsx` 的 `● live` 标记断言扩到 Linux。`bun test` 110 条在 Linux 全绿——T3 那句"非 Windows 路径未跑过"也一并作废。

**已知问题**：macOS 仍是 `unknown`（没有 `/proc/locks`；`fcntl F_GETLK` 看不见 flock）。真要即时性，路径仍是 T3 记过的那条：内核往 `<id>.lock` 里写 owner pid——内核改动，等需要它的人出现。

### T10 · `/goal`（占位，未开工）

**状态**：设计已定、内核侧全部就绪，TUI 代码一行未写。写在这里是为了不把它忘掉，也为了说清"为什么这一条不需要内核再长东西"。

内核侧 M2c 已经落地（DESIGN §11）：随仓库带的 `extensions/handoff`（模型在阶段边界提议）、`compact` 的 `brief_file` 分支（只 fork、旧文件逐字节不变）、以及 `drivers/goal.sh` / `drivers/goal.ps1`——**第一个 driver**。前端要做的只是 spawn 它并读两个流：

- **stdout = 控制通道**，只有四种行：`session <id>`（开 tab 并跟随）、`handoff <old> -> <new>`（换到子 session 的 tab；父 tab 留着，`/sessions` 里它们同 `root`）、`done <id>`、`evaluate: …`（提示 `/outcome`）。一行 JSON 都不会混进来，e2e 钉住了这一点。
- **stderr = `session step --stream` 的行协议原样透传**，正是 `tui/src/nulya/cli.ts` 已经在解析的东西（T0 定的 §2.2）。所以 `/goal` 里的 token delta、tool begin/end、usage 与手打一条消息时走的是同一个渲染路径。

跟随中的 tab 天然是 **observer**（driver 进程持着写者 lease，§5.6 的两个信号照旧适用）；`Esc` 的语义是 `nulya session cancel <当前 id>`，driver 会在下一个 step 边界看到。选脚本按平台：`process.platform === "win32"` → `powershell -NoProfile -ExecutionPolicy Bypass -File drivers/goal.ps1`，否则 `sh drivers/goal.sh`；两份脚本逐行对齐，行为相同。

**不做**：把 goal loop 内建进 TUI（PLAN §3.6 的整条论证——driver 是可替换的脚本，前端是客户端不是过程的所有者）；也不做 handoff 的守卫阈值（那是 driver policy，等真实使用证据，PLAN §3.4.1）。

### T11 · 启动即安装（2026-08-18）

**动机**：理想用法是"把 extension 源码放进 `~/.nulya/extensions/<id>/`，开 TUI 就能用"。内核这一轮给了动词（`nulya ext sync` / `ext prune`，DESIGN §7.2/§7.4），**前端只决定什么时候跑**——而"什么时候"恰好落在内核已经画好的那条线上（physics #6 / DESIGN §9）：user store 是你自己的目录，project store 是别人 clone 给你的。

1. **两条路，两种待遇。** user root（`ext sync --user`）在 **App 的 `onMount` 后台**跑：compiled draft 一次要好几秒，绝不能挡开屏；状态栏借用已有的 `hint` 位显示 `syncing extensions… 2/3`（分母来自先跑的一次 `--dry-run`，那次 plan 同时也是 `/ext` 的 draft 列数据），完成后一行 `user store: 2 built · 1 already`。project root **在 `main.tsx` 里、`session new` 之前**问：它必须早于 session 创建，因为未信任的 store 正是让 `session new` 硬拒的那件事（DESIGN §9），而那时 OpenTUI 的备用屏还没进，普通终端问句就够。
2. **问句只有一句，三个键。** `t` = `ext trust` + `ext sync --activate`；`s` = 只 `ext sync`（不 trust、不 activate）；`n`/`Esc`/`Enter` = 什么都不做（并说一句 `nulya ext trust` 随时可用）。**只问一次**：答案无关，问过就记进 `tui-state.json` 的 `asked_stores`。判据不在前端重实现——"有哪些 draft" 是 `ext sync --dry-run` 的输出，"信不信任" 是读内核自己的 `<user dir>/trusted-stores.jsonl`（只读，从不写；写 trust 的永远是 `nulya ext trust`，它会先把要信任的东西打印出来）。
3. **`s` 为什么不是半吊子。** 一个只带 draft 的 checkout，按 `s` 之后 store 从空变成有内容，而**本机 build 填满空 store 就是信任**（DESIGN §9 的出生地规则），所以 session 照常能开。真正需要 `t` 的是"checkout 里已经躺着 built 版本"那种——那时按 `s` 之后 `session new` 仍会被拒，而那正是诚实的结果：没人看过它。
4. **`/ext` 多一列。** 每个 id 的 draft 状态 `not built | built | active | needs zig | fails`，来自 `ext sync --dry-run`（workspace + user 两个 root 各一次），所以"源码改了但没 build"第一次在界面上看得见。`a` 在 id 列表上指向 **draft 的那个版本**（在版本线上仍是选中项，两种选择各自成立），`p` = `ext prune <id>`，先弹一行确认（`delete N version(s), keep <current>?`），成功后显示的是内核自己那句代价说明而不是省了多少字节。
5. **测试**：`test/extensions.test.ts` 6 条——真二进制上的 plan/sync/幂等、`--activate` 的三种答案（moved / already there / left alone，含真的 rollback 一次）、行解析的全部形状、纯策略（问不问、三个键映射到哪条命令）。`/ext` 快照更新了两行（draft 列 + 按键行）。

**已知**：`bun test` 全量跑在这台机器上偶发超时（涉及真二进制持写者租约的那几条，跑单文件全绿，且与本条改动无关——同样的偶发在改动前后各出现一次，失败集合还不同）。

**没做**：`/ext` 的 pin 键（写 project 层 `registry.pinned_native_tools`）——pin 是第三个决定，且它属于人或 evolution session，等真实需要；`/goal`（T10 仍占位）。

### T12 · `/ext` 的 pin 面板（2026-08-18）

**动机**：`/ext` 一直只能"看"——版本线、漂移、usage 都在，但把一个 tool 放上模型工具面这件事，得去手写 `~/.nulya/config.toml`。而 pin 恰好是内核已经画好的两根轴之一（DESIGN §5.1），前端要做的只是把两个写口（config 的 `registry.pinned_native_tools` 与 argv 的 `session new --pin`）变成两个键。

1. **三态，因为写口有两个半。** `always` = user config 文件里有它（每场都付一个槽位 + 前缀 token）；`this TUI` = `tui-state.json` 的 `session_pins`，本 TUI 起的每场 `session new` 自动带 `--pin`；`off`。第四个不是状态而是一句事实：合并投影里有、user 文件里没有 = project/system 层写的，**只读显示 `from another config layer`**，因为本面板只写一个 key、一个文件（契约 D3）。`Space` 打开永远先进 `this TUI`（试用零成本、不碰任何配置文件），`A`（Shift+A，与旁边的 `a` activate 隔开）才升格为 `always` 并同时删掉 session 那份——内核 union 会去重，但屏幕上一个 pin 两行状态是谎话。
2. **不对称照说不绕。** `session new` 的 pin 是 union（config ∪ argv），所以**没有**"不动 config 的前提下给某一场做减法"这件事。面板不假装有：`always` 的唯一关法就是从 user config 里删掉它，而那句 notice 就这么写。`session new --no-pin` 是这条约束的最小内核动词，本轮**没做**，等真实证据（契约 D2）。
3. **写 config 是文本手术，不是重序列化。** `pins.ts` 的 `setPinnedTools` 只替换（或追加）`pinned_native_tools` 那一段：按 table header 定位 `[registry]`，按引号外的方括号配平吃掉可能跨行的数组，其余字节一个不动。理由很直白——配置文件是人写的文本，一个只管一个 key 的程序没资格重排它的注释和顺序。写完**重读 + `Bun.TOML.parse` 校验**，不一致就把原字节写回去并报错：文本手术如果悄悄产出内核读法不同的东西，界面会显示一个从没进过任何 session 的 pin。
4. **配额行说的是内核的算法，不是我们的预判。** `tools 2+N/8`：`max_tools` 含 builtin（DESIGN §5.1），把 2 显出来是因为"我明明只 pin 了 6 个为什么被拒"只有这一个答案。超了**不拦**——拒绝是 `session new` 的事，面板超了只多一句 `session new will refuse`，真被拒时贴内核原话。
5. **两根轴分开（契约 D4）。** `d` = `ext deactivate`，动的是 membership（skills / system prompts 进不进 composition），与 pins 并排而不是合成一个假总开关。tools-only 的包（std）"整体开关" ≈ 在 id 行上 `Space` 批量 pin；data 包（evolution / guide）的开关就是 activate / deactivate。—— **本条已被 T22 推翻**（原则对内核是对的、对屏幕是错的：两个键都藏着，它们移动的状态一格没画）。今天 `Enter` 就是那个总开关，两根轴仍分别可及（tools pane 的 `Space` / 版本线的 `a`·`r`），`d` 删掉了。理由见 §11 T22 第 4 条与 §1.2 D12。
6. **唯一会通知在跑的 session 的动作是 activate。** 面板 spawn `ext activate` 时给子进程带 `NULYA_SESSION=<当前 session 文件>`，借内核现成的 `depositSessionNote`（DESIGN §5.3）——模型下个 step 边界就知道有新版本可以 `ext run`。deactivate 与 pin 改动**一条通知都不补**：本场工具面在 `session new` 冻死了（physics #2），对它们没有可行动信息，往 ledger 里塞 UI 旁白是噪音。底部常驻一句 `changes apply to the NEXT session — this one froze its tools at start`，是 drift line 的姊妹句。
7. **测试**：`test/pins.test.ts` 8 条——三态与 another-layer 只读、off→`this TUI`→`A`→`always` 的全链、整包 toggle、配额行、行来源（只列有 `current` 且没被 shadow 的包，因为别的 pin 会被 `session new` 拒）、config 写回（保注释 / 跨行数组 / 缺 key 缺 table 三种落点 / round-trip）、以及**真二进制的闭环**：`session_pins` → `--pin` → header `native_tools` 里就是它，没 pin 的那个 tool 是对照组，pin 一个不存在的 tool 拿到内核自己的拒绝。`test/overlays.test.tsx` 再加一条走真键盘：`t` 进 pane、`Space` 打开、状态文件与新 session 的 header 都跟着变、再 `Space` 关掉又都退回去。

**已知 / 没做**：`A` 升格是逐个 tool 的（整包写 user config 不是谁按住一个键会做的决定）；`/ext` 的 `/sessions` 快照在本机偶发一个尾空格差异（session id 的 hash 长度不定，先于本轮存在）；`session new --no-pin`（见 2）。

### T13 · composer 的 `@` 文件补全（2026-08-18）

**动机**：把路径读给模型是每天做几十遍的动作，而它一直是手打全路径。tcode 那套 `@` 交互被用了很久，边界情况（邮箱不是引用、根文件优先、basename 前缀胜过 path 前缀）都是**用出来的**而不是设计出来的——所以本轮的判断只有一个：**照抄**（契约 D6）。

1. **纯函数逐条移植。** `references.ts` 的 `referenceBoundary` / `referenceTokenChar` / `referenceScore` / `referenceMatchOrder` / `referenceMarker` / `formatBytes` 一一对应 tcode `composer.rs` 的同名函数，常量（三档评分 0 / 1 / 10+gaps、菜单 8 行、`MAX_INDEX_ENTRIES = 20_000`）原样。测试也照抄了四条（`reference_token_avoids_email_addresses` / `..._prefers_basenames_then_fuzzy_paths` / `..._prioritizes_root_files` / `reference_labels_use_basenames_unless_they_conflict`）——行为是移植的，失败也该是移植的。
2. **索引就是 git 的清单。** `git ls-files --cached --others --exclude-standard -z`：gitignore 语义**白得**，这里不再有第二份 `.gitignore` 实现。目录不在 git 的输出里，是从文件路径**推**出来的——顺带得到一条好性质：只有装着东西的目录才会出现在菜单里。非 git 目录退化成一个带 prune 表（借 `extensions/std/src/walk.zig` 那张，它本身也是 tcode 的）的小 walk，那不是正确性所在的地方。索引在 App 挂载时后台建，`@` 激活时 `touch()`，超过 30s 才后台重建——**永远不 await 一次按键**：第一个 `@` 在建完之前是空菜单，下一个就全有了，这比"git 走 monorepo 时输入框不收字符"划算得多。
3. **`@` 与 `/` 两个菜单，都不抢 Enter。** `@` 菜单在时 `↑↓` 是选择、`Tab` 上屏；Enter 永远发送**写着的东西**。这是输入框唯一不能破的承诺——一个偷走 Enter 的菜单会让每条消息变成"赌高亮在哪儿"。触发点用 textarea 的 `cursorOffset` 从光标往回找边界 `@`，往前吃到 token 尾，光标必须落在已打出的那段里：所以 `@src/app.ts and more` 后面接着打字不会再弹菜单。
4. **高亮只给解析得出来的引用。** `knownReferenceRanges` + `addHighlightByCharRange`（一次性的 `SyntaxStyle.fromStyles`）；`@` 后面跟着不认识的词就是普通散文。这样 accent 才有意义——它说的是"这个能解析"，不是"你打了个 at 号"。
5. **上屏的是路径，不是内容（契约 D5，与 tcode 的有意识分歧）。** tcode 的 `expand_references` 把文件内容展开成独立 block，省一轮往返——那是真收益，先承认。nulya 不这么做，理由是 nulya 自己的：append-only ledger + fork/compaction 的长寿谱系意味着注入的快照**永久**待在前缀里、每步付费且会陈旧；今天 `user_text` 是纯文本，注入需要内容块结构，本身就是内核改动。模型有 `read`，freshness 去重让重复读很便宜，路径本身就是它需要的那一部分。代价是每个引用多一轮往返，若真疼再议。

**偏离**：菜单里文件的大小只在**显示的那 8 条**上 `statSync`（`git ls-files` 不给 metadata，为 20000 条各 stat 一次不值），tcode 是 walk 时顺手拿到的；显示形状（`file · 1.2 KiB`）一致。

**已知 / 没做**：`@目录` 不展开（契约 §5）；索引不监听文件系统（30s 陈旧 + `@` 时触发，够用）。

### T14 · 长文本粘贴折叠（2026-08-18）

**先探明的那件事**：契约说"OpenTUI 若不透出 paste 事件就是 BLOCKED，不做按键洪流启发式"——**透得出**。`Renderable` 有 `onPaste`（`PasteEvent{bytes}`），它在 renderable 自己的 `handlePaste` 之前跑，`preventDefault()` 就能把默认插入拿掉；测试侧 `mockInput.pasteBracketedText` 走的是同一条路。所以整条回路（真 bracketed paste → 折叠 → 提交展开）是自动化测出来的，不是手测出来的。

1. **阈值与占位形状照抄**（契约 D6）：`> 1000 字符 || > 15 行`（tcode `PASTE_FOLD_CHARS` / `PASTE_FOLD_LINES`），占位 `[Pasted text #N]`，`Backspace` 落在占位尾部就整条删掉（否则啃掉一个 `]`，剩下一个看着像文字、其实还挂着 attachment 的形状）。边界测试也照抄：**恰好等于阈值不折叠**。
2. **折叠是草稿的显示，不是对草稿的修改。** 提交时 `expandPastes` 把占位换回原文，落进 ledger 的就是粘贴的那些字节、在粘贴的那个位置。占位对应的 attachment 被删掉之后仍留在文字里的 `[Pasted text #1]` **原样发出去**——那时它就是人打的字，替它编内容比露出方括号更糟。
3. **attachment 不在提交时清空**（与 tcode 的 `drain` 不同）：只有它的占位被删才走。理由是 history——composer 的历史存的是**屏幕上那份**（带占位），`↑` 召回时看到的是当初打的那行而不是它代表的四十行；召回后再发，占位仍然解析得出来。生命周期与 `history` 一致（进程内），所以不是新增一类泄漏。
4. **accent 与 `@` 共用一套**：`paintTokens` 把已知 `@引用`（T13）与占位一起画；占位按**形状**匹配（tcode `input_token_ranges` 也是），因为眼睛读的是那个 token。`[Pasted text #]`（没数字）与 `[Image #3]` 都不亮——后者是 vision track 的事。
5. **图片整体不做**（契约 D7 / §5）：ledger 没有图片内容块，三个 provider 的序列化也没有；先造"看不见图"的占位再返工不值。剪贴板探测与 `[Image #N]` 的形状等 vision 内核面落地后照抄 tcode `input.rs`。

**已知**：Linux 上的真终端手测未做（自动化已覆盖同一条 bracketed paste 路径，`pasteBracketedText` 与终端送出的字节序列是同一份解析）。

### T15 · skill 作为 slash command（2026-08-18）

**翻案的那句话**：`commands.ts` 的头注释与 §4.4 原本写着"nulya 没有 skill slash；skill 由模型 `nulya skill load`——否则就是把智能放进前端"。这句判断把**谁触发**误当成了**谁判断**。skill 本来就是渐进披露的 prompt，内核给了 `skill list` / `skill load` 两个只读面，模型经 `shell` 走的就是这条路；`/name` 只是把触发者换成人，省掉那一轮往返。前端**不选择、不改写、不自动触发**任何 skill——这条没变，变的只是承认"人也可以触发"（契约 D8）。两处旧文本本轮都改了。

1. **顺序就是优先级。** 补全：内建命令在前、skill 在后；分发同序（内建 → skill → 原样发给模型）。所以装一个包**永远拿不走** `/model`；一个叫 `model` 的 skill 会出现在菜单第二行，但 Enter 走的是内建那条。
2. **sentinel 照抄 tcode 的 `wrap_skill_echo`**（`<user-skill name="…" args="…">\n<body>\n</user-skill>`，属性 `&`/`"` 转义）。它挣了两次位置：① transcript 只凭**ledger 文本**就能把这一条折回 `/name args · N lines`——live 与回放调的是同一个 `parseSkillEcho`，格式只有一处知道；② 它说明 body 是"穿着 user message 衣服的仓库文件"。今天 nulya 没有任何东西读这个区分，但这条 turn 是永久的（physics #1），事后再加标记够不着已经写下去的那些。行数按 Rust `str::lines()` 的算法（末尾换行结束最后一行，而不是开一个空行）——`paste.ts` 的行计数同步对齐了。
3. **它就是一条普通 user turn。** 走 `session append`，内核对"skill turn"一无所知也不会有；卡片是**对内容的读法**，与 compaction 那两条一个路子（`skillEchoOf` 之于 `compactionMarker`）。默认折叠：人做的事是打了 `/name args`，那两百行是真的、永久的、一个键就能展开的，但不是发生的那件事。
4. **缓存什么时候失效有唯一答案。** `nulya skill list` 列的是**activate 了的** extension 的 catalog，所以只有 activate / rollback / deactivate 能改变它——`/ext` 确认执行后回调 `invalidate()`，而不是这边轮询。pin 不触发（那是另一根轴）；开新场、跑一步都不触发。
5. **测试**：`skills.test.ts` 5 条——tcode 的两条 sentinel 测试逐条同形（特殊字符 round-trip、普通文本不误判）、内建优先、`/name args` 的切分、以及**真二进制闭环**（真的 draft → `ext sync --activate` → `skill list` 的 TSV 与 ref 形状 → `skill load` 的字节 → 包好的 turn 里有 body、折叠成一行、未命中返回 null）。`render.test.tsx` 加一条折叠快照。

**已知 / 没做**：skill echo 卡片不进 browse 模式的可选列表（`foldable()` 只收 tool / thinking，CompactionCard 同样如此——鼠标点头行仍能折叠）；per-project 的 slash alias、前端自动触发 skill 都在契约 §5 的"不做"里。

### T16 · `/model` 的排版修补（2026-08-18）

**乱码的根因**（截图先拿到、再在测试渲染器里复现的那半）：一条 `<text>` 只画自己的字形落到的格子，**空格覆盖的格子原样留着**；所以一行的折行位置在两帧之间变了，上一帧的字就从新文本的每一个空格里透出来。截图里 notice 渲染成 `openai·hasino APIvkeyr·athisssessionsisnthe offline stand-in`——把它与上一行标题 `model · which provider a session runs on` 逐格对齐，**插进去的每个字符都正是标题在该列的那个字符**（第 6 列 `·`、第 10 列 `i`、第 13 列空格、第 17 列 `v`、第 21 列 `r`…）。所以不是宽度测量错、也不是 `·` 的双字节，是**重排**：只要一行会折，它迟早会花。宽度测量只是导火索——单元格超宽 → 折行 → 重排。

因此对策不在 OpenTUI 而在**布局纪律**：**列表里的任何一行都不许折**。新增 `tui/src/ui/columns.ts`（纯函数，5 条测试）：`displayWidth`/`charWidth`（按显示宽度，不是字符数也不是字节数）、`fit`（超宽截断加 `…`，落在宽字符里就少占一列而不是多占一列）、`wrapWords`（**我们自己**按 ` · ` 关节折，断点丢掉分隔符，所以不会有以 `·` 开头的孤行；一个短语比整行还宽就退到空格，一个词比整行还宽就动刀）、`columnWidth`（内容 + gutter，封顶；全空的列**一列都不占**）、`squeeze`（窄屏时最宽的列先让格子，不低于各自下限）。

`ModelView` 的四处对应修补：
1. **列宽来自内容**：name 列原本写死 18，而 `deepseek-anthropic` 正好 18 → 与右邻居粘成 `deepseek-anthropicanthropic wire · api.`。现在 name/endpoint/models/status（二级是 label/id/ctx/dial/status）都由 `columnWidth` + `squeeze` 算出来，每格文本过 `fit`，行 `height={1}`，gutter 恒 2。
2. **notice 与 hint 手动折**：一行一个 `<text>`，断在 ` · ` 上；`launch.ts` 的 guide 与两级 hint 顺手收短（八十列一行装得下的 hint 就不会折出孤行）。
3. **窗口预留按真实渲染行数**：`list.ts` 拆出 `listBudget(height, own)`（App 自己的 chrome = 9 行是唯一的常数，`visibleRows` 现在就是 `listBudget(h, 7 + extra)`，`/sessions` 逐格不变），`ModelView` 数的是它**真的画出来的**标题 + notice 折后行数 + 空行 + 详情 + hint；溢出时再留两行给 "N more" 标记。原先按"notice 恒 1 行"预留，是屏幕下方一片空白却说"上面还有 2 行"的原因之一。
4. providers 列表补了缺的 "N more below"。

**同病未修**（不在本轮范围，记在这里）：`ExtView`（`width={34}` 的左栏 + 版本行）、`UsageView`（`width={20}`）、`HelpView`（`width={32}`）、`SettingsView`（`width={12}` / `{28}`）、`Composer` 的补全菜单（`width={40}` / `{26}`）都仍是写死列宽 + 未截断的文本，窄屏或长 id 下会犯同一个错；改法就是上面这套 helper。

#### T16b · 其余五个面迁到同一套纪律（2026-08-18）

上一条点名的五个面全部迁完，**行为与键位一字未改，只改呈现**：单元格一律过 `fit`、行 `height={1}`、列宽由 `columnWidth` + `squeeze` 按内容算出并带 2 空格 gutter、成句的说明 / hint 用 `wrapWords` 自己折成一行一个 `<text>`。

- **`ExtView`**（四个 pane）：左栏 `width={34}` → 由 id / `Nv kind` / draft / `shadowed` 四列的内容算出，且封顶在半屏（右边详情是解释光标在什么上的那一半）。版本行**按优先级分配而不是平均让步**：version id 是 `v-` + 24 hex、是人抄去喂 `ext activate` 的东西，**永不截断**；两个 marker（`⚡ current` / `▎ this session`）其次；时间戳只是给一个本来就有序的列表排序，所以它先缩、缩不动就整列消失（`columnWidth` 全空的列一列都不占）。详情四句与 pin 面板的空态改 `wrapWords`，pin 行拆成 `[x] ` + id + state + uses + ok% 五格，footer 三句也折。
- **`UsageTable`**（被 `/usage` 与 `/ext` 的 usage pane 共用）：多一个 `width` 必填 prop——同一张表画在两个不同宽度的盒子里，按错的盒子算列宽就是必然折行。行改成 toolId / `N uses` / `X% ok` 三列。
- **`UsageView`**：左标签列由六个标签的内容算出（原写死 20），标题与那句 105 字的 caveat（八十列必折）改 `wrapWords`。
- **`HelpView`**：说明列改成"**一行一个 `<text>`，续行缩进到说明列**"——它在 scrollbox 里，折行点会随滚动偏移变，是最坏的犯病位置。key 列由**实际绑定**算出（`/new [--profile p] [--model id]` 是 31 列，原写死 32 只剩一个空格 gutter，与 `deepseek-anthropic` 同款）并封顶 34。**还修了一个真的被吃字符**：scrollbox 的滚动条画在内容区**最后一列**上，按 `width-2` 排版的行每一行都被啃掉最后一个字（截图证据 `…stops at its nex█`），所以这一面的 `inner()` 是 `width-3`。
- **`SettingsView`**：状态列 / key 列 / value 列都内容驱动，路径过 `fit`（`settingsPaths` 从 workspace 路径派生，长度没有上界），结尾那句 130 字改 `wrapWords`。
- **`Composer` 的补全菜单**：两个菜单都是表，所以都守表的纪律——`/` 菜单的 name 列由候选（含 skill 的 `/name`）算出、说明**截断成一行**（菜单里一个候选占两行，`↑↓` 就不再是"一个候选"了）；`@` 菜单的 label 列同理（同名文件会让 label 变成整条路径）。两条 hint 折。

**`columns.ts` 的一处修正**：`charWidth` 把默认 emoji 呈现的符号（`231A`…`2B55` 那批，含本项目在用的 `⚡`）从 1 列改成 2 列。证据就是 `/ext` 快照——`⚡ current` 后面本该有两格 gutter 只剩一格，说明渲染器认它 2 列而我们认 1 列；"我们算得下、终端画不下"正是溢出的定义。其余 16 个主题 glyph 实测都是 1 列，有断言钉住。

**测试**：五条窄宽度（76 列）frame 测试，每条都断言"没有任何一行超过 76 列"+ gutter 完好（两行把同一列的内容放在同一个 offset）+ 超长内容出现 `…`；`/ext` 那条现造一个 36 字符的 extension id（它同时也是自己 tool 的名字），四个 pane 逐个走一遍并断言 version id **整条**都在。`columns.test.ts` 加一条 emoji 宽度。`bun test` 152 → **157 pass**；两个既有快照（`/help`、`/ext`）按预期版面更新，逐行看过 diff——变化只有 gutter 补齐、列宽由内容决定、长句断在 ` · ` 关节上。

**仍未迁**：`SessionsView`（不在 T16 点名的清单里；它的行是 `flexGrow` 的一段拼接文本，长 `first_user_text` 已经切到 40，但窄屏下仍可能折）。

### T17 · mid-task 消息带上自己的说明（2026-08-18）

**通路早就在，缺的只是措辞。** 内核侧：`session append` 不拿写者锁、投 inbox、内核在**每个** step 之前排干（DESIGN §3.4）；TUI 侧：driver 运行中 `send()` 直接 append，落在最后一步流式期间的消息由 `drive()` 结束时的 `pendingCount()` 检查再起一轮送达（§4.3 允许的那一次机械 re-step）。但模型看到的只是 tool_results 之后凭空出现的一条 user turn——和"停下来听新指令"在字面上无法区分，模型往往就真的停了。tcode 的答案是投一条机器署名的 `Entry::Note`（interrupt contract：用户**没有**打断你，回应后继续原任务，别把中途消息当隐式停工信号）。

1. **note 是 prompt，不进内核。** nulya 不为此新增 ledger 事件类型：措辞是 policy（physics #8），而"何时输入的"这个事实 TUI 自己最清楚。落法是 T15 skill echo 的同款 sentinel（`midtask.ts`：`<user-mid-task-message>\n<原文>\n</user-mid-task-message>\n<note>`），wrap 与 parse 同一模块，live 与回放共用一个读法,卡片折回用户原话 + `sent mid-task` 小标。note 逐字照抄 tcode（`agent/mod.rs`），只把复数改单数;它有个经得起赛跑的性质——说的是**输入时刻**（"typed while you were working"），所以 append 与 run 结束赛跑、实际下一轮开头才排干时,这句话仍然为真。
2. **parse 只认 sentinel、不认 note 措辞**：旧 TUI 写的 turn 在新 TUI 里照样折（note 将来可以重写而不搁浅已落盘的 turn）；close 标签取**最后**一次出现,正文引用 sentinel 也能 round-trip。
3. **包不包，按"模型是否真的在干活"**：driver 侧只在 `stepping` / `canceling` 包（`sending` 不包——那一场还没开跑,消息只是加入开场批次）；observer 侧只在 lease 探针**确证** `held` 时包（`free` / `unknown` 不主张没核实过的事）。
4. **note 一轮一份，"合并"不需要**：tcode 的 TUI 把排在一个 turn 后面的多条 prompt 合成一条再开下一轮（`turn.rs` `merge`——否则模型只回答第一条）；nulya 靠结构免疫这个病——运行中的多条各自进 inbox、内核在下个边界**一次排干**，赛跑漏掉的由 `drive()` 的 `pendingCount()` 检查**再起一轮**（不是一条一轮）送达,消息在 ledger 里保持独立事件（三条消息就是三个事实）。真正对应 tcode"一批一条 note"的是：同一轮 run 里只有**第一条**中途消息带完整 contract,后续只带 sentinel（tag 说明身份,contract 一遍就够）,run 结束复位。
5. **测试**：`midtask.test.ts` 7 条纯函数（round-trip、note 措辞无关性、无 note 的裸 sentinel、正文引 sentinel、误判、多行）+ `driver.test.ts` 一条真二进制（scripted loop 跑着时连发两条 → 第一条带 note、第二条只有 sentinel、都折回原话、rest 那条原样）。`bun test` 157 → **165 pass**。
5. **顺手更新一个滞后快照**：`/sessions` 的行从 `scripted` 变 `scripted/scripted-demo`——不是本轮改的,是 vision V3 把 scripted 选中的 model id 冻进 header（goals/vision.md §6）的诚实呈现,TUI 测试用的新内核二进制把它带了出来。

### T18 · 鼠标与层次：让"能点"看得见，让"主次"分得开（2026-08-18）

**内核零改动**（只动 `tui/`）。两件事其实是同一件：一个界面如果所有文本都是同一档灰、所有可点的东西都没有反馈，那它既读不出主次，也猜不出哪儿能按。

#### 鼠标

覆盖面：**overlay 列表行**（`/sessions` 的每一行、`/ext` 四个 pane 的 id 行 / 版本行 / tool 行、`/model` 的 provider / model / wire 行与 "+ add a provider" 行）· **`/ext` 的 pane 条**（新增的 `extensions  versions  tools  usage` 一行，点哪个去哪个）· **`/ext` tools pane 的 `[x]`**（等价 `Space`）· **TabBar**（点 tab 切换）· **状态栏的 `↓ N more below`**（等价 `Shift+End`）· **composer**（点输入区回到输入，即使正在 browse 模式）· **卡片头行**（本来就有，改了触发时机）· **拖拽选中 + 复制**。`SettingsView` / `UsageView` **没有**行点击——它们没有光标、没有行动作，给一个亮起来但按下去什么都不发生的高亮是骗人。

1. **一次点击的定义：按下与松开落在同一个格子**（`ui/rows.ts` 的 `onClick`）。这不是洁癖：OpenTUI 在任何 selectable 文本上按下就开始一个选区，所以"按下即触发"意味着**在卡片头行上拉选文本会把卡片折起来**——复制转录的动作会重排转录。改成按下记坐标、松开比坐标，`mockMouse.drag(4,0,12,0)` 的测试就是这条的证据。
2. **不造全局 dispatcher**：每个组件自己的 JSX props，`ui/rows.ts` 只提供三个共享判断（什么是点击、指针在哪一行、一行长什么样）。**点击调的是键盘调的同一个函数**——`/sessions` 的第二次点击走 `open()`（Enter 的那个）、`/model` 走 `enterModels()` / `pick()`、`[x]` 走 `toggle(...)`（`Space` 的那个）。行为只有一份。
3. **两次点击而不是一次**：一次点击落光标，落在已选中的行上再点才执行。开一个 session、起一场对话都不该是划过鼠标时的意外。
4. **hover 是两套记号，不是一套**：光标行 = `▾` + `selection` 底色，指针行 = 新 glyph `·`（ascii `.`）+ 更淡的 `hover` 底色。故意不同形——NO_COLOR 或者一块惨白的终端下，颜色没了还要分得出"键盘在这儿"和"鼠标路过"。`onMouseOut` 只在自己仍然占着那个槽位时才清（同一行跨列移动会先 out 后 over）。
5. **overlay 打开时点不穿**：`App` 的 `<Switch>` 让 overlay 起来时 transcript **根本没挂载**，所以不是"盖住"而是"不存在"。一条测试钉住它（开 `/help` → 点原来卡片头行的位置 → 什么都没折）。
6. **滚动之后的命中**：tui.md 一直记着这块没人确认过。现在有测试：十张卡片塞进 6 行的 scrollbox，读出屏幕第 N 行画的是哪张卡，点它，展开的正是那张。前端**没有任何**屏幕行 → item 的换算，命中是 OpenTUI 对真正画在那里的 renderable 做的 hit-test——这条测试说的就是这件事。
7. **两个真 bug，都是这轮才看得见的**：① `<text>` 上挂鼠标 props **不生效**，得挂在 `<box>` 上（`[x]` 因此是一个 `width={4}` 的盒子）；② `<For each={tools()}>` 在每次 `refreshPins()` 之后重建**每一行**（`toolRows` 每次造新对象），而一个在按下与松开之间被销毁的 renderable 会把这次点击一起带走——连点两下 `[x]` 第二下丢失。两处列表（`/ext` tools、`/sessions`，后者每 8 秒重读一次）改成 `<Index>`：一个位置一个 renderable，只换它说的话。顺带 `applyPin` 写完就地更新 `tuiPins`（`config show` 是个子进程，等它回话期间屏幕不该落后于已经写下去的文件）。
8. **文本选取做了**（契约里问过成本）：OpenTUI 0.5.3 的选区是现成的——按下 selectable 文本即 `startSelection`、拖拽 `updateSelection`、松开 `finishSelection` 并 emit `CliRenderEvents.SELECTION`，`Selection.getSelectedText()` 把选中的 renderable 拼回文本。`App` 只加了一个监听：非空就 `renderer.copyToClipboardOSC52(text)` 并在状态栏说复制了多少字符。选 **OSC 52** 而不是 host clipboard（`createHostClipboard` 也在库里）的理由是它只是一条发给已经连着本进程的终端的转义序列——过 ssh 也照样管用、不用装东西；终端不认就是没复制，所以那句提示只在真复制了才出现。空选区（每次普通点击都会产生一个）直接返回。

#### 层次与减法

9. **四档明度取代两档**（`render/theme.ts`）：`fg`（这个东西本身：卡片头行、选中行、值）· **`muted`**（它由什么构成：id 旁边的 label、计数、状态）· `dim`（关于它写的话：说明、提示、footer、列名）· **`faint`**（家具：hover 记号、空 gutter、失效格）。再加一个 `hover` 底色（永远比 `selection` 安静）。token 加在主题里，三套主题（dark / light / NO_COLOR）各一份，散落的硬编码颜色一个没加。**快照没有因为颜色变化而变**——`captureCharFrame()` 只有字符，这也是为什么颜色这一档可以放心改。
10. **overlay 底部收成一行**（`ui/overlays/Footer.tsx`）：`OverlayFooter` + `createKeyHelp()`，常驻只有"这个面板的重点两三个键 · ? keys"，`?` 展开其余，再按 `?` 或 `Esc` 收起。`/ext` 因此从"两行键 + 一行警告"变成"一行警告 + 一行键"。**只有真有更多键的面板才写 `? keys`**（`/usage` 就两个键，宣传一个按了没反应的入口是撒谎）。`?` 由各 overlay 在自己的 `useKeyboard` 里 `help.consume(key)`，因为 `/model` 的表单步骤里 `?` 必须还是一个普通字符——那里 consume 放在 text-step 提前 return 之后。
11. **`/ext` 多一行 pane 条**：四个 pane 原本只能靠"知道 Tab 会轮、`t`/`u` 会跳"找到，usage 表和 pin 面板等于是隐藏功能。一行四个词，既是目录也是按钮。
12. **`/sessions` 迁进 T16 的排版纪律**（T16b 记的"仍未迁"）：行不再交给终端折——`fit` 到算出来的中段宽度，id 与两个 chip 是固定两端。顺带分三档：id 是主语、`when · model · events · cost · with` 是 `muted`、第一句 user text 是 `dim`。
13. **空状态给指路**：`/ext` 的 "no extensions built yet" 后面补两句（extension 是什么、`ext init` → `ext build`）；tools pane 空态说明"要先有 active 版本"；`/sessions` 空态说 `n` 开一场 + 出生即冻结 + 从不删除；usage 表空态说"每跑一次工具内核就 append 一行，shell 和 edit 也算"。
14. **状态栏与标题行分层**：状态栏一条 `<text>` 拆成三段（花费 `muted` / 当前活动 `fg`，且只在真的在动时才 `fg` / 键提示 `dim`）；标题行拆成"哪一场、什么模型"（`muted`）与"冻了什么"（`dim`）。
15. **`/help` 多一块 mouse**，并把 `inner()` 从 `width-3` 改成 `width-4`——内容变长之后滚动条真的出现了，而按 `width-3` 排版的行会紧贴着轨道一格不留（T16b 修的是"被吃掉一个字"，这次修的是"一格留白也没有"）。

**测试**：新增 `test/mouse.test.tsx` 8 条（拖拽不折叠 + 选区文本、滚动后的命中、`/sessions` 一点选中二点打开、hover 记号来去、`/ext` 点 pane 与点 `[x]` 的开关往返、TabBar 点击、overlay 不透传、点输入框退出 browse），`layout.test.tsx` 加一条（点状态栏的 `more below` 回到底部），`views.test.tsx` / `overlays.test.tsx` 各改成"先断言一行、按 `?` 再断言其余"。`overlays.test.tsx` 的 `stable()` 顺手把行尾空格抹平——T12 记的那个"偶发尾空格差异"就是 session id 的 hash 长度不定，尾部留白不是版面。四个快照按预期更新，逐帧看过。`bun test` 165 → **176 pass**。

**没做**：`/model` 的 effort 拨盘 `‹ ›` 不接点击（它是一个横向的三态转盘，点左右箭头需要把两个字符各做成一个目标，收益不抵复杂度，`h/l` 与 `←→` 都在）；overlay 里的滚轮（`/help` 的 scrollbox 本来就吃滚轮，其余几个是窗口化的定长列表，滚轮要先有"列表自己的滚动位置"这个概念）；右键菜单、双击（终端里两者都不可靠，且没有第二个语义要挂）。

### T19 · 自带扩展随二进制走：`ext seed` 的消费者（2026-08-18）

**内核改动只有 `nulya ext seed` 本身**（DESIGN §7.2/§7.8：build.zig 把仓库的 `extensions/**` 按 `src_embed` 同一先例嵌进二进制，seed 把这些 draft 写进 store root，已有 draft 一律不动）。TUI 侧是它的第一个消费者，接了三处：

1. **开屏问一次**（`main.tsx` `askAboutBundled`，与 project-store 的问句同地、同纪律）：user store 缺自带扩展、这台机器还没问过、且有人在键盘前，才问。`(t)` seed 全部 → `ext sync --user` build → **只激活 `std` 与 `guide`**（`extensions.ts` 的 `bundled_active`——compact / evolution / handoff 是 `/compact` `/evolve` / driver 按需带入的，装 ≠ 激活）→ 把 `ext:std/*` 五个 pin 并进 `tui-state.json` 的 `session_pins`（先按 `config show` 的 `max_tools` 验配额，2+5≤8 放不下就不写并明说）；`(s)` 只 seed + build；`(n)` 不动。答案记在 `asked_bundled`（机器级布尔——user store 是机器级的，不是 per-store 列表）。
2. **`/compact` `/evolve` 出了 nulya 仓库也能用**（`extensions.ts` 的 `bundledDraftPath`）：repo 相对路径下没有 draft 时，`ext seed --user <id>`（已有即 no-op）再从 user store 的 draft build。`compact.ts` / `evolve.ts` 各改一行调用。
3. **启动 sync 的激活收窄**（`App.tsx` `syncStores`）：不再用内核的 `--activate`（它还会把"没有 `current` 的 id"一并激活——seed 之后 user store 里合法地住着故意不激活的包,evolution 的 system prompt 会因此进每一场 session），改为 sync 不带 flag、然后**只激活本趟 `built` 出来的版本**（逐个 `ext activate`）。手放的新 draft 第一趟就是 `built`，行为不变；故意留着不激活的包从此真的留得住。状态栏汇总多一节 `· N activated`。

**测试**：`extensions.test.ts` +2（真二进制的 seed 往返：dry-run 计数、点名子集、二次 seed 不覆盖；问句文案）；内核侧 e2e +1（seed → sync 闭环、`--dry-run` 零落盘、已有 draft 字节不动）。`bun test` 176 pass、`tsc` 干净、`zig build test` / `zig build e2e` 绿。

**没做**：`/ext` 里没有单独的"bundled"分区——seed 过之后它们就是普通 draft + 版本，现有列表如实显示；`auto_activate` 打开时"以前 build 过但从未激活"的 id 不再被启动补激活（`/ext` 的 `a` 一键即达，这正是"激活是决定"）。

### T20 · `/model` 以模型为主语；模型这一行处处可点（2026-08-18）

**内核零改动**（只动 `tui/`）。来源是拿 tcode 并排一看给出的三条：①`/model` 打开是一张 provider 表，"选模型"藏在第二层——它长成了 provider 配置器；②tcode 的 model 行**能点**开选择器、可点的东西鼠标过去都有同一种高亮，nulya 只有 overlay 里的行有；③整体仍简陋——截图里就有两处：标题行尾巴上一个孤零零的 ` ·`、状态栏 `Ctrl+O fold · /` 把 `help` 吃掉了。

#### `/model`：第一层是模型

1. **T5 → T6 → T20 是同一个问题的三次回答。** T5 一张平表：每个 (profile, model) 一行，七个 profile 摊成十四行、十三行都在重复"没 key"；T6 改成 providers → models 两级，行数下来了，但把要选的东西藏进了第二层。真正让表变短的不是嵌套，是 tcode `build_menu` 的那个过滤：**跑不了的 provider 不出模型行**（`pickableRows`：`credential` 为真的 profile 的每个 model，加上正在生效的那个 pick 的 profile——不管它此刻能不能跑，`✓ current` 得有一行可落，Enter 在上面只说原因）。所以现在第一层一行一个能跑的 (provider, model)：`provider · label · id · ctx · ‹ effort › · ✓ current / offline`，`h/l` 拨 effort、Enter 开新场，光标开在生效中的那行。
2. **providers 退到后面，但没有消失。** 最后一行 `providers · 2 ready · 4 need a key · manage keys · add an endpoint`（`p` 或 Enter/点它）进第二层——原来的 provider 表原封不动（wire、endpoint、几个模型、状态），credential 仍归 provider（`s` 贴 key 在两层都指"当前这行的 provider"），`a` 加 compatible endpoint 两层都能按。**Enter 在 provider 上按它的状态办事**：能跑 → 回模型层并落在它的第一个模型上；缺 key 的 openai/anthropic 口 → 直接进贴 key；codex → 说 `codex login`。跑不了的 provider 的模型 id 现在写在它的 detail 行里（`… · models gpt-5.6-sol, gpt-5.6-luna`）——T6 说的"浏览不该被拦"仍然成立，拦的只是"开一场"。
3. **effort 拨盘按行 key 记，不按下标**（`dials: Map<"profile/model", slot>`）：贴完 key 一 reload，上面多出几行，原来的那行不能把自己的 effort 交给别人；两个光标也按名字保住（provider 按 name、model 按 key），`r` / 存 key / 加 provider 之后没有人被静默挪走。
4. **列宽的优先级**：模型层六列由内容算、窄屏 `squeeze`；label 有 20 列的下限而 id 没有——80 列下两者同宽时"widest first"会切出 `DeepSeek V4 Fla…` 而它旁边的 id 完好，label 才是命名模型的那一列，id 先让。
5. 措辞跟着走：`commands.ts` / `/help` / Welcome 的 `/model` 一句、`launch.ts` 的开屏 guide（"pick a model, or Enter on providers to paste a key"）与 `--profile` 被拒时的指路。

#### 可点与层次

6. **模型这一行处处可点，同一处开**：标题行的 `profile · model` 段、CompositionCard 的 `model` 值、Welcome 的四条 `/` 命令行、状态栏默认 hint 里的 `/help`——四处都走 `ui/rows.ts` 的 `onClick`（按下松开同格）、指针悬停时同一个 `theme.hover` 底色，点击调的是键盘调的同一个函数（`openOverlay("model")` / `submit("/sessions")`——不是 `overlay.open`，那样 composer 不会让出键盘，`j` 会同时打进输入框和移动选择器）。CompositionCard / Welcome 没拿到回调时（测试里单独渲染）行是**惰性的、不亮**——T18 的规矩：给一个按下去什么都不发生的高亮是骗人。
7. **两处溢出**：标题行三段（`nulya · <id> · ` / model / detail）都由我们裁——model `fit` 到 subject 剩下的宽度，detail 取 `wrapWords` 的**第一行**（按 ` · ` 关节整段丢），所以 80 列下结尾是 `tools 2+0` 而不是 `skill…` 或孤 `·`；状态栏先把右侧三个 chip（ctx / more below / role）算成字符串，hint 拿剩下的宽度 `fit`——默认 hint 里 `/help` 单独一个 box 才点得到，notice 整条替换 hint。
8. Welcome 多一行 `cwd`（CompositionCard 说了 model 与 tools，没说是哪个 workspace——两个终端唯一分得开的事实）；四条命令的说明与结尾那句都过 `fit` / `wrapWords`（一个 `height={1}` 的行会把折出来的第二行剪掉）。

9. **开屏问句（T11 / T19）的两处小修**：三个选项从一行改成一行一个（与上面的包列表同形），问句以 `› ` 收尾、答案**回显在同一行**并换行——raw mode 吞掉了终端回显，原来按下 `t` 之后屏幕与按之前一模一样，接着 zig 编译 std 那一分钟看起来就是挂了；`readAnswer` 只认 t/s/n/Esc/Enter，其它字节（终端对查询的应答、focus 事件、IME 半截序列、空 chunk）**不再算 "not now"**——原来一个杂散字节就把问题静默答成拒绝并记成"问过了"。

**测试**：`model.test.tsx` 重写四条（模型层开屏 + `p` 进 providers 两张快照；76 列两张表都不折；拨盘 / Enter / providers 上的三种 Enter；`s` 从 providers 贴 key 后回模型层多出 openai 的行；`a` 从模型层直接进表单）+1（`pickableRows` / `providersSummary`）；`mouse.test.tsx` +1（标题行 model → 选择器、CompositionCard model → 选择器且 `j` 不进 composer、Welcome 行 → `/sessions`、状态栏 `/help` → `/help`）；`/help` 快照按预期更新。顺手修两条**与本轮无关、换上新二进制才现形**的测试：`views.test.tsx` 的 `/settings` 76 列那条按 `…` 找行而不按长名（Windows 的 temp 前缀就把列用完了）；`observer.test.ts` 第 3 步用 `parseMidTask` 比原文（T17 之后 observer 在探针确证 `held` 时会包 mid-task sentinel，原断言比裸文本只是在赛跑里侥幸过）。`bun test` 176 → **178 pass**、`tsc` 干净。

**没做**：selector 仍是全屏 overlay，不是 tcode 那种浮在 transcript 上的带框弹窗（overlay 起来时 transcript 根本没挂载，T18 第 5 条——浮框要先有"盖住而不是替换"这个概念）；状态栏不常驻 context 占用（§4.5 的 ≥60% 才出现照旧）；preset / sub-agent 段（T5 就说过：单角色世界里 preset ≡ profile）。

### T21 · `/model` 与 `/provider` 分家：两个问题，两个命令（2026-08-18）

**内核零改动**（只动 `tui/`）。来源是 T20 上手后的一句反馈——"现在 provider 可以选，但是怎么选 provider 的模型呢，这俩个功能得分开吧，不行的话就参考 tcode 吧"。T20 把模型提到第一层是对的，错的是**没把 provider 送走**：provider 表、贴 key、加 endpoint 全塞在同一块屏幕的第二层，于是"选 provider"与"选模型"缠成一件事，`s` / `a` / `p` 三个键长在一列模型中间。tcode 从来就是两条命令（`model_picker.rs` 一张平的模型表 ÷ `setup.rs` 的 provider 配置器，命令表在 `app/mod.rs`），这一轮照着那条缝切。

1. **`/model`（F5）只剩模型。** T20 的模型层原样留下（`pickableRows` = 每个能跑的 provider 的每个 model + 生效中那个 pick 的 provider；六列内容定宽 + `squeeze`；`h/l` 按行 key 记拨盘；Enter 开新场；两次点击才开场），**删掉**尾行 `providers · …`、`p`、`s`、`a` 与 providers / key / add-form 五个 mode——`ModelView.tsx` 从 1108 行掉到 ~400。`provider` 那一列留着：不分层之后，它就是"这是谁家的模型"唯一的读法。Enter 落在一个失去 key 的 `✓ current` 行上仍只说原因，措辞改成指路 `/provider`。
2. **`/provider`（F6，新 overlay `ProviderView.tsx`）拿走剩下的一切**：一行一个 profile（`name · wire/endpoint · N models · 状态`）、detail 行照旧列出它的 model id（浏览不拦，拦的只是开一场）、`s` 贴 key（`writeProfileKey`）、`a` / 尾行进 compatible endpoint 表单（`writeProfile`）、codex 说 `codex login`、`r` reload。**跑不了的 provider 的状态里才写 `· s to paste one`**——`blockedReason` 现在只给事实（`no key`），补救办法由"此刻哪块屏幕在显示它"来加，因为一个不在这块屏幕上的键比不给建议更糟。
3. **Enter 在能跑的 provider 上 = 关掉 `/provider`、开 `/model` 并落在它的第一个模型上**（`onShowModels` → `App` 的 `focusProfile` 信号 → `ModelView` 首次 load 时优先落在这个 profile）。用户问的"怎么选 provider 的模型"就是这两步，而它们是两块屏幕不是两层。`focusProfile` 只在 `openOverlay` 之外的这一条路上被设，别的方式开 `/model` 一律清掉——否则上一次交接会静默替下一次选行。
4. **只搬两边都用的东西**（"第二个 consumer 出现之前不抽 abstraction"，出现了才抽）：`ui/overlays/providers.ts` 只有三个函数——`modelIdsOf` / `keyable` / `blockedReason`，即两块屏幕都要问的那三个问题。`endpointOf` / `readyLabel` / `WIRES` / 表单只有 `/provider` 用，就留在 `/provider`；`providersSummary` 随尾行一起删（计数现在读行就有）。
5. **开屏没得跑时去哪**（`launch.LaunchPlan.guideOn` + `App.guideOn`）：还有别的 provider 能跑 → 开 `/model`（"pick a model that can run"）；一个真 provider 都跑不了 → 开 `/provider`（"paste a key, or add a compatible endpoint"）——那时一张模型表没有任何东西可给，缺的那把 key 就是问题本身，tcode 的首次运行同样是 provider 向导。`scripted` 不算 provider（没人配置它）。`/model` 自己空表时也只有一行 `no provider can run yet · /provider …`，Enter / `p` 过去。
6. **顺带消费内核这一轮的 `profiles[].catalog`**（另一条线在改壳层，TUI 侧只是读）：`ProfileView.catalog: ModelView[] | null` 防御式解析（缺列 / 非数组 = null，老二进制照跑），`modelRows` **先查该 profile 自己的 catalog、再回落全局 `[[models]]`**——`gpt-5.6-sol` 在 ChatGPT 订阅口是 258k ctx + 多一档 `xhigh`，在公共 API 口是 1.05M ctx 且到 `high` 为止，两个都对，只是对的不是同一个端点。codex 列的是订阅真给的那几个（读 Codex CLI 的 models cache，`nulya config show --refresh` 重取）。
7. 措辞与入口跟着走：`commands.ts` 多一条 `/provider`、`keymap.ts` 多一个 `provider: "f6"`（F1–F5 已占满，F6 是空的且与 F5 相邻）、`state/overlay.ts` 的 `OverlayKind` 多一个 `"provider"`、`/help` 的动作表与命令表各多一行、Welcome 多一行、`launch.ts` 里"press s on it under /model → providers"改成 `/provider`、README 的选择模型一节与键表重写。

**测试**：`model.test.tsx` 重写成"只有模型"（模型层快照里不再有 `providers ·` / `s paste a key` / `no key`；76 列一张表不折；拨盘与 Enter；`focusProfile` 落在交接过来的 provider 第一行；空表那一行 + Enter/`p` 都调 `onOpenProviders`；失去 key 的 current 行 Enter 的文案；`planLaunch` 的 `guideOn` 两支；`App` 的 `guideOn="provider"` 真开 `/provider`）+ 新的 **`provider.test.tsx`**（provider 表快照 + 76 列不折；三种 Enter——ready 交接到 `/model` 第一行、缺 key 进贴 key、codex 说 login；`s` 贴完 key 后 reload，Enter 过去 `/model` 就多出 openai 的行；`a` 走完表单写一条 profile；两条 credentials 单测与两条真二进制 `NULYA_HOME` 测试从 model 搬过来）+ 一条 fixture 测 profile 自带 catalog 压过全局同 id。两块屏幕共用的 `fake_config` 搬进 `test/support.ts`（**测试文件不能 import 另一个测试文件**，那会把它的 test 注册两遍）。`/help` 快照按预期更新，并把它的渲染高度 60 → 66：页面长了 4 行，原来的视口把 `/quit` 挤出屏幕，而这条测试的全部意义就是"每条命令都在这一页上"。`bun test` 178 → **187 个测试、183 pass**、`tsc` 干净；4 条 fail 全是**改动前就红的**（三条 `/ext` + 一条 5k 事件性能计时；另有一条 `probeWriterLease` 60s 超时在基线红、这次绿，是机器负载）。

**没做**：`/provider` 不写 `[[models]]` 目录条目（`a` 加进来的 endpoint 的模型仍没有 effort dial 与 context window——目录是"一个 id 是什么"，等真需要再给表单加一步，T6 起就挂在这里）；两块屏幕仍是全屏 overlay 不是浮框（T20 同一条）；没有 `/provider` 的删除/禁用动作（配置文件是人的，TUI 只做"加"与"改 key"这两种写）；`catalog` 里的 `vision` 列没读（前端没有消费者）。

**测试隔离（同日补）**：上面"改动前就红"的三条 `/ext` 的原因找到了——测试从没设 `NULYA_HOME`，内核把开发者真实的 `~/.nulya/extensions`（T19 seed 进去的 `evolution` / `guide`）也列进了 `/ext`，断言的版本 hash 落到了别的包上；同一个口子还让每次 `bun test` 往真实的 `trusted-stores.jsonl` 里追加临时 workspace 的信任行。修法与内核 e2e 同一招（`NULYA_HOME=<ws>/.nulya-test-home`）：`test/isolate.ts` 作为 bunfig `[test] preload`，整趟测试把 `NULYA_HOME` 指到一个 mkdtemp 目录，任何测试都看不到（也写不到）真实的 home。**Bun 的一个坑**：`Bun.spawn` / `spawnSync` 不传 `env` 时用的是进程**启动时**的 environ，不是运行期改过的 `process.env`——所以测试里裸的 `Bun.spawnSync({ cmd, cwd })` 与 `src/nulya/cli.ts` 的 `sessionFollow` 都补了 `env: process.env`（否则 `ext build` 记的信任写进真实 home、`session new` 却在临时 home 里找，同一趟里两把 home）。`bun test` **187/187 pass**（性能计时那条在无干扰时也过）。

### T22 · 第一条消息才开场；标题行下沉；`/ext` 列全并给一个开关（2026-08-18）

来源是拿着运行中的截图给的四句话：①"session 应该等用户发第一个消息再创建吧，在此之前 tool 什么的都应该可以改"；②"上面的 session id 对用户没意义，nulya 也是，模型名不需要显示提供商——参考 tcode 放 composer 下面，配色配好"；③"std extension 为什么不显示"；④"按 Enter pin 没 pin 也看不出来，UI 要有区别，最好有颜色或者 toggle，而且叫 activate 更好懂"。四件事一起做，**TUI 侧全部落地；内核只动了一处、且不是 TUI 要的**（见第 3 条末尾）。

1. **session 第一条消息才建（§1.2 D11）。** 以前 `main.tsx` 在 `render()` 之前就 `session new`，靠退出时 `discardIfUntouched` 把没用过的空场删掉，靠 `untouched()` 在 `/model` 选完时**偷偷替换**空场——两个补丁都是同一个病的症状：composition 在 `session new` 冻结（physics #2），开屏就建等于替人把 tools / pin / model 决定了，人随后在 `/ext` `/model` 做的一切要么落到"下一场"、要么靠替换糊过去，`/ext` 底下那句 `changes apply to the NEXT session` 对一场根本没开始的 session 就是这么荒唐地成立的。现在 `state/tabs.ts` 的 tab 是 `DraftTab | SessionTab` 的 union：draft **没有 id、磁盘上什么都没有**，只捏着 `session new` 要的东西（`pick`、`--with` 的 `bring`、effort），pin **不**存在 draft 里而是 `materialize` 那一刻现读 `tui-state.json`——`/ext` 里一秒前拨的开关就由这一场带走。`materialize` 是 draft 变 session 的**唯一**一处，发生在第一条消息：`sendTurn` 先解 skill（`/name` 装不上就不开场）、再 `session new`、再 append + step；内核的拒绝（缺 key / store 未信任 / pin 认不出）**留在屏幕上**——notice 是内核原话、tab 仍是 draft、打的字回到输入框（`ComposerApi.restore`，只在框还空着时放回去）。`/model` 在 draft 上只改 pick（不起进程、不写文件），在已开场的 tab 上开一个**新 draft**（换模型本来就是换场，现在换场不再花任何东西）；`/evolve` `/mode` 也是 draft + `bring`；`--session <id>` 与 `/compact` 的产物仍是真 tab。draft 上 `/outcome` `/compact` `/step` `/cancel` `Esc` 各回一句"这个 tab 还没有 session"。`discardIfUntouched` 与 `created` 留着——compaction 失败等边角仍会产生"建了没用"的 session——但常规路径不再产生，`files.ts` 头上那段"TUI 开屏即建"的注释改掉了。tab 的 store 键从 `id` 改成 `key`（draft 是 `draft-<n>`），`replace` / `close` 认 key。
2. **标题行取消，模型下沉到输入框下面（§4.1 / §4.5）。** 原来那行 `nulya · <session id> · <profile> · <model> · effort · tools · skills` 给程序看的成分居多：session id 人读不出也用不上（要它去 `/sessions`），`nulya` 是废话，provider 紧挨 model id 也是重复（`/model` 那张表里 provider 列还在，那是它该在的地方）。它唯一有用的是**模型**，而模型该在人打字时看得见的位置——tcode 就是把 `mode · model (effort) · cache · /help` 放在 input 底下（`app/draw.rs` `idle_hint`）。现在 `StatusBar` 是那一行：`<model-id> [(effort)]`（主语，`fg`，可点 → `/model`，与 T20 的其它模型可点处同一套 `onClick` + `hover`）· `tools 2+N`（`dim`）· token 累计（`muted`）· 当前活动（只在真的在动时 `fg`）· hint / notice（`dim`），右侧 `step n · driver/observer` 照旧。effort 只在本 tab 明确选过时才写括号（`auto` 是内核默认，七列不值）。**窄屏让位是一句判断不是平均分**（`layout()`）：model / 活动 / 通向 `/help` 的三格永不让，notice 其次（它是新闻），再丢 `tools`（上面的 CompositionCard 说全了）、再丢 token；80 列实测三样都在。draft 上同一行：model 来自 pick、`tools 2+N` 来自合并 config pin ∪ `session_pins`。TabBar 仍只在 >1 个 tab 时出现，但 tab 名从 session id 改成 **model id（同名加 `#n`）**、draft 标 `(new)`（`tabLabels`）。CompositionCard 多一个 **draft 变体**（§5.1）：`next session · set when you send the first message`，三行同序，数据只来自 `config show --json` / `tui-state.json` / `ext list`——**没有第二个 composition 解析器**，真的解析永远是内核在 `session new` 里那一次。
3. **`/ext` 列出只有源码的 id（§5.3）。** 真因两层。屏幕这层：`/ext` 的清单来自 `ext list`，而 `ext list` 只列**持有版本**的 id——`~/.nulya/extensions/std|compact|handoff` 三个 compiled draft 一次都没 build 成，于是**整个不存在**，唯一痕迹是开屏 sync 在状态栏滚过一句 `user store: 0 built · 2 already · 3 failed`。现在清单 = `ext list` ∪ `ext sync --dry-run`（两个 root，本来就为 draft 列取过的那两份 plan），只有源码的 id 显示 `0v <kind>` + draft 状态（`not built` / `needs zig` / `fails`，warn 色），右栏说清怎么办：`needs zig` 把**内核那句话原样转述**（`wrapWords` 折）+ 至多一行我们自己知道而内核不知道的（PATH 上的 zig 若是 anyzig 那类 version shim，它从 cwd 往上找 `build.zig.zon` 定版本，而 store root 里没有——所以 `nulya toolchain zig version` 在仓库里能答、在 store 里不能）；`b` 就地 `ext build <root>/<id>`（落哪个 root 由内核按路径定）；开屏 sync 有失败时 notice **点名失败的 id 并指路 `/ext`**，不再只报个数。机器这层：这台机器上 build 不出来的原因正是那个 shim。**内核唯一改动**在这里、并且是用户自己给的方向（"到时候不是要随包带 zig 0.16 吗，就在同样的位置装一个"）：`resolveZig` 第二档从"内嵌工具链"改成 **managed 目录** `<data>/toolchains/zig/0.16.0/`（DESIGN §10）——内嵌了就往里解压，没内嵌也认里面已有的（扁平 / `zig-<target>-<ver>/` 两种布局），目录是 nulya 自己的、版本钉死的，谁放的字节不改变它是什么；`ext build` / `ext sync` 撞墙那句 `needs zig (…)` 现在**自带这个目录的绝对路径**（`cli_toolchain.noZigHint`），并区分"根本没有 zig"与"有 zig 但它在 store root 里答不出版本"（后者点名那个路径）。TUI 转述的就是这句，所以 `/ext` 里的修法与内核永远是同一句话。
4. **`Enter` = 一个开关，两根轴一起动（§1.2 D12，推翻 T12 §5）。** 以前 extensions pane 上 Enter 无绑定；`Space` 是 pin（data 包答 "declares no tools · nothing to pin"）；`a` 要先 Tab 到版本线选版本；`d` deactivate——两根轴（membership / pin）在内核里是真的，但屏幕上**一格状态都没画**：截图里 `evolution` `guide` 是 `built` 却 `current (none)`，人按 Enter 没反应、也看不出与别的行有何不同。T12 §5 那句"永不合成一个假总开关"对内核是对的、对屏幕是错的——一个画出来的开关 + 底下写清两根轴，胜过两个藏在 `?` 后面没人找得到的键。现在每个 id 行开头一格 `●`/`○`（ascii `*`/`-`，`theme.glyphs.switchOn/Off`）：`ok` 全开、`warn` 半开（旁边一格 `3/5 tools` 或 `pins only`）、`faint` 关；`Enter`（或点那一格）切换。**ON** = `ext activate <id> <version>`（版本取 sync plan 说 built 的，否则 store 里最新的 build；一个都没有就拒绝并指向 `b`）+ 把它声明的 tool 全进本 TUI 的 pin 列，**先验配额**（`2 + face > max_tools` 一个字节都不写，贴内核那句 `session new will refuse`）；**OFF** = 先撤 pin（本 TUI 列 + user config 的 `always`；别的 config 层写的撤不了，点名说出来）再 `ext deactivate`——顺序有意：pin 指着一个没 `current` 的 extension 是 `session new` **整场拒绝**（`PinNamesUnknownExtension`），所以每一步之间的世界都得合法；同理每次 refresh 把指着已不 active 的东西的本 TUI pin 丢掉并说一句（`orphanPins`），修掉了 `d` 之后 pin 留在 `tui-state.json` 里让下一场开不了的旧坑。**两个方向都不要 `y`**：都是指针 + pin 的移动，同一个键放得回去，且够不着已开跑的那一场（physics #2）；`p` prune 仍确认。tools pane 的 `[x]` 换成同一套色（一处颜色一个含义）。两根轴仍分别可及：单个 tool 用 tools pane 的 `Space` / `A`，单个版本用版本线的 `a` / `r`（仍带确认——它们点名一个 build，是时间线上的动作）；`d` **删掉**（它就是 OFF 的一半，两个键做一件事正是被修的那个毛病）。底部常驻句按 tab 有没有 session 分两种：有 → `changes apply to the NEXT session — this one froze its tools at start`；draft → `changes apply to the session this tab is about to start`。用词跟着用户走：这个开关叫 activate（footer `Enter on/off · …`，`?` 展开 `Enter activates the extension and pins its tools, again turns both off`），"pin" 只在 tools pane 里说单个 tool。
5. **措辞与入口**：`commands.ts` / Welcome 里 `/model` 早就是"pick what the next session runs on"（T20），现在它字面成真；README 开头那段"first frame 有 session id in the header"改成 draft 的真相，`/model` 那行说清 draft 上只改 pick、开过场的 tab 旁边开新 draft，`/ext` 的键表按上面重写，多一行"点输入框下面的模型 = `/model`"。

**测试**：`bun test` 187 → **193 pass**、`tsc` 干净。新增 / 改写：`lifecycle.test.tsx` 的两条 eager-create 测试改成"draft 在磁盘上什么都不建、屏幕与 store 一致"与"第一条消息**恰好**建一场，且带着那一刻的 pin"（真二进制、scripted provider）；`overlays.test.tsx` +2（`/ext` 列出只有源码的 id、说清缺什么、拒绝打开；Enter 开 → `current` 指过去 + pin 写下，再 Enter 关 → pin 没了 + deactivate）；`pins.test.ts` 的整包 toggle 改成 `pinAll` / `unpinAll` + 开关三态（`partial` 就叫 partial）；`extensions.test.ts` +1（`needs zig` 的 draft 转述内核原话）并让 sync 汇总点名失败 id；`model.test.tsx` 那条"fresh session 被替换"改成"写 draft，不建 session；已开场的 tab 上开第二个 draft"；`mouse.test.tsx` 的模型可点从标题行改到输入框下面那一行；`/ext` 快照按预期更新（开关一列、`0v` 行）。内核侧：`zig build test` 399 pass / 2 skip（`toolchain.zig` +1：managed 目录里已有的 zig 没内嵌也认，扁平与嵌套两种布局）、`zig build e2e` 54 pass（sync 那条只断 `needs zig` 前缀，句子变长不影响）。

**没做**：draft 的 CompositionCard 不解析 `--with` 包的 skills / prompts（只写 `with <id>@<v>`——那要读版本目录的 manifest，等真需要）；`needs zig` 不自动 `b`（修法要人做一次，做完 `b` 一键）；开屏 sync 的失败仍只是一句 notice（不弹面板）；两块选择器仍是全屏 overlay（T20 同一条）；`d` 若有人肌肉记忆抗议再作为 OFF 的别名放回。

### T23 · 卡顿是结构问题：`/ext` 乐观更新、开屏不再前台编译、清单只答"要不要动它"（2026-08-19）

**内核零改动**（只动 `tui/`）。来源是用户的四句：①"整体卡顿，`/ext` 里开关一个扩展每按一下等半天"；②"第一次启动在进屏幕前编译了很久"；③"我在 compact 上按了很多次 Enter，它就是不 active"；④"版本哈希、`3v comp` 这些占着最显眼的位置，我看的是要不要开它"。四件事同一个病因的四个面：**每个动作都全量往返、每一格都在显示存储的内部标识**。

1. **`/ext` 的每个动作从"全量往返"改成"乐观更新 + 后台校对"。** 原来一次 Enter 是 `ext activate` → `applyPin` → `refreshPins`(`config show`) → `refresh`(两次 `ext sync --dry-run` + `ext list` + `draftEntries` 里又一次 `ext list` + 又一次 `config show`)——**七个子进程串行，全部 await 完才给第一个反馈**，Debug 内核下每个 0.75–1.2s，合计 3–4 秒屏幕一动不动。现在：**两根数据轴按代价分开**（`listed` = `ext list`，一个子进程；`sourceOnly` = 两次 dry-run，是这块屏幕最贵的调用），`extensions` 是两者的 memo。打开面板 = 先 `ext list` 画第一帧，usage / pins / plans 再落进来；**动作后只 `reconcile()`**（`ext list` + `config show`，后台跑，通知早就在屏幕上了）——activate/deactivate 是指针移动，**改不了"一份源码会 build 成什么"**，所以两次 dry-run 只在开面板、`b` build、`p` prune 后重算。`applyPin` 多一个 `reconcile` 开关，一次动作里 `config show` 不再被 spawn 两次。乐观本身：按键当场 `setLocalCurrent` + 把 pin 状态推进信号 + notice 写 `std on…`，**但一个字节都不落盘**——`ext activate` 答应了才写 pin 文件（pin 指着一个没有 `current` 的 extension 是 `session new` **整场拒绝**，它绝不能活过一次失败的 activate；OFF 方向反过来，先撤 pin 再动指针，同一条理由）。失败则把指针与**两张 pin 列原样**放回（`pinSnapshot`——`unpinAll` 会连按之前就有的 pin 一起撤掉，所以回滚存快照而不是取反）。连按去重：`working` 是一张 id 集合，同一个 id 的第二次 Enter 只回一句"还在忙上一次"，不排队、不拿半写状态算第二个决定。id 列表从 `For` 换成 `Index`（tools pane 早有的先例）：乐观改一次、校对再改一次，`For` 会把每一行拆了重建两遍，按下与松开之间被拆掉的行会把这次点击一起带走。
2. **配额满了不再整体拒绝——两根轴只有一根有配额（用户③的真因）。** 他的 `session_pins` 已有 6 个（handoff + std 五件），`2+6 = 8 = max_tools`，compact 声明 1 个 tool，预检 `2+6+1 > 8` 就把**整个开关**拒了，只留一句 `2+9/8 · nothing changed`——叠上 3–4 秒延迟，体感就是"按了没反应"。但 membership 与 pin 是两根轴：**`ext run` 调一个扩展的 tool 根本不需要 pin**（`/compact` 一直就是这么调 compact 的）。现在配额不够只挡 pin：照常 activate，通知说清"面已满 `2+6/8`、N 个工具没进面、tools pane 的 Space 能腾一格、`ext run` 照样够得着"（`pins.faceFullLine`），行内 `0/1 tools` 那一格本来就是为这个状态准备的。`quotaLine` 越界那句也从 `over registry.max_tools · session new will refuse` 改成人话（差几个、去哪腾、不腾会怎样）。
3. **on-demand 包的工具不上模型面**（同一轮追加；名单已于 T34 被 manifest 的 `audience` 取代）：`compact` 的 tool 是**driver 接口**——它 append/step 它所关于的那场 session，模型在**那场 session 里**调它必然撞单写者锁（`SessionBusy`）；`handoff` 的 tool 确实是给模型的，但那是 driver 用 `--with … --pin` 按场带进去的，不是每场常驻。所以 `extensions.ts` 多一个 `bundled_driver_only = [compact, evolution, handoff]` + `pinsOnActivate(id)`，`/ext` 的 Enter 对这三个**只做 membership**，通知说明"已激活；此包的工具由 `/compact` 或 driver 用 `ext run` 按需调，不占工具面"；开关三态也跟着用"**可 pin 的**工具数"算，否则 compact 会永远停在半开的 `0/1 tools`。名单是**临时判据**，代码注释写明长期方案是 manifest 的 per-tool `audience`（包自己说它的 tool 是给谁的——只有它知道），内核侧后补。
4. **自带扩展改成"开屏后台自动装 + 激活"，问句取消**（用户②）。原来 `main.tsx` 在 `render()` **之前**问一句再前台 `ext seed` + `ext sync --user`，其中三个是真的 `zig build-exe`，几十秒到分钟级，屏幕上只有一句 `installing…`——问句本身也没什么可问的：user store 是这个人自己的目录，装进去的东西就是他刚跑的那个二进制带来的。现在 seed 挪进 `App.syncStores`（进屏之后、后台），进度走已有的状态栏 sync 通道，结尾一行汇总 `user store: 5 built · std & guide active · std tools pinned`。**同意模型收敛成一条规则**：只有 `ext seed` 报告"**这一趟才到**"的 id 才被 adopt（`adoptBundled`）——已经在 store 里的是别人早就做过的决定，**包括昨天在 `/ext` 里关掉它这个决定**，任何一次开屏都不许翻案。顺带堵一个新口子：`syncStores` 原来的"激活本趟 built 出来的版本"循环遇上新 seed 会把五个全激活（`evolution` 的 system prompt 就进了每一场 session），所以那个循环显式跳过 `arrived` 的 id——它们的激活是 `adoptBundled` 的事，而它只认 `std` 与 `guide`。`tui.toml` 的两个键照旧：`sync_on_start=false` 一步不动，`auto_activate` 管两边的指针移动。**workspace/project store 的 trust 门原样保留**（DESIGN §9 的内核安全门，且它是唯一能挡住"开不出 session"的东西，仍在屏幕之前问）。`tui-state.json` 的 `asked_bundled` 退役：`loadTuiState` 逐键白名单读，老文件里多一个键从来不是错，模型选择与 pin 照常读回。
5. **信息密度：主视图只回答"要不要动它"**（用户④）。id 行去掉 `3v comp` 那一格（版本数与 kind 是"已经走近这个包的人"才关心的，它们在详情面板与版本线上），行上只剩：开关标记 · id · 半开提示(`3/5 tools` / `pins only`) · draft 状态 · shadowed。版本线**宽度自适应**（用户当场纠正过一版：先落了"一律短哈希 + 光标下一行画全串"，但宽度绰绰有余时藏着 16 位数字不买任何东西）：两个标记列（current / this session）优先，剩余宽度放得下就整行画**完整版本串**并省掉光标下的辅助行，放不下才退到**短哈希**（`shortVersion`，`v-` + 8 位）+ 光标所在行下方画一次全串——24 位十六进制是内容地址，它存在的理由是"同一份源码 build 两次同名"，人对它做的唯一一件事就是贴到 `ext activate` 后面。**散文行永远用短哈希**：drift 行与详情的 `current v-…` 同样用短哈希（同一个纯函数，两行说同一个 build 不可能差一位）；permissions 行只在**真有非零项**时出现（`permissionLine`：`fs 0 · net — · proc 0` 在每个包上都是三格废话，正是它让唯一真要权限的那个包不再显眼），root 路径留着但降到最暗色。

**测试**：`cd tui && bun test` 193 → **196 pass**、`tsc` 干净。新增：`overlays.test.tsx` +2（`shortVersion` / `permissionLine` 两个纯函数；**满配额的面上 Enter 仍然激活**——独立 temp workspace 写 `[registry] max_tools = 2`，断言 `current` 真的动了、`session_pins` 是空的、屏幕上是 `tool face is full` 而不是 `nothing changed`）、`pins.test.ts` +1（`faceFullLine`）；改写：`extensions.test.ts` 把"问句文案"那条换成"只 adopt 这一趟到达的 id"（没到达的一律不动 = 关掉的东西活得过重启；`needs zig` 的没有版本可指），`overlays.test.tsx` 的 76 列那条改断言"行上没有版本哈希"、drift 那条断言短哈希 + 完整串仍在下一行、source-only 那条把 `0v scri` 换成详情面板的 `· script · inactive`、tools pane 那条不再假设 `max_tools` 是 8（**内核这一轮把默认值改成了 20**），快照的 `stable()` 多一条 `tools 2+N/<max>` 归一化——配额分母是内核的默认值，不是这块屏幕的排版。

**没做**：`/ext` 打开时仍会跑两次 `ext sync --dry-run`（只是不再挡住第一帧；真要更快得让内核给一个便宜的 plan）；乐观更新只覆盖 activate / deactivate / a / r，`b` build 与 `p` prune 仍是"等它、然后全量刷"（它们本来就要改磁盘上的版本目录）；`bundled_driver_only` 是硬编码名单，等 manifest 的 `audience`（**T34 已做**）；状态栏的 sync 进度仍只有一行 notice，没有专门的安装面板。

### T24 · 权限：内核给一个 gate，屏幕决定问不问（2026-08-19）

**内核这一轮真的动了**（前 23 轮里只有 T0 的 `--stream` 和 fork 原语动过）：`loop.StepContext` 多一个 `gate`，`session step` 多一个 `--gate`（DESIGN §4 / §14）。理由是这块屏幕先前唯一诚实的说法是 D8 的"v1 没有权限"——而 kernel 侧没有任何可消费的东西，前端**发明**一个审批就是在 ledger 之外造第二份真相（模型不会知道自己被拒了）。gate 修好的正是这一点：**deny 是那个 call 的 `tool_results`**，模型读得到、ledger 里记得住，没有新事件种类，不设 gate 的路径逐字节不变。

1. **`--gate` 常开**（`nulya/cli.ts`）：TUI spawn 的每个 step 都是 `--gate --stream` + `stdin: "pipe"`；gate 请求行**不进** `lines()`，由 `answer()` 就地问屏幕、把 `allow` / `deny [note]` 写回去。gate 抛异常 = deny（内核那头对 EOF 也 fail closed，这一头不能成为它干等的理由）。
2. **判断全在 `approvals.ts` 一个纯函数里**（§5.7 的决策序：deny 表 → 本场 always → ask 表 → allow 表 → manifest `readonly` → mode）。条目两种形状（tool id / tool 名，或 `shell:<命令前缀>`），`a` 记的 key 对 shell **只记第一个词**。它不 import 任何 UI、不 spawn 任何东西，所以它是这一轮唯一有密集单测的地方（`approvals.test.ts` 7 条）。
3. **卡片是那张 tool 卡多一行**（`ToolItem.awaiting` + `ApprovalPrompt`），键 `y` / `n` / `N`(带理由) / `a`；理由经输入框收（这时它不是 turn 而是 note——call 还开着，发给模型的东西会排在它后面）。状态栏活动区在等的时候压过其它一切并转 warn 色。
4. **`/mode` 让名给权限档，穿身份的改叫 `/as`**（`/mode auto` 与 `/mode evolution` 从来不是同一类东西）。存储链 `tui-state.json` > `tui.toml [driver] mode` > `ask`；状态栏最右的 chip 可点；**有卡片在等时切 mode 会立刻重裁它**。
5. **handoff 接线**（§5.8）：每个 step 结束看一次 `.nulya/handoffs/<id>-*.md`（与 `drivers/goal.*` 同一个信号），`ask` 弹面板（brief + `Enter` 跟 / `Esc` 收）、`auto` 直接跟；跟过去就是 `/compact` 的 `brief_file` 分支。draft materialize 时按 `[extensions] handoff`（默认 true）加 `--with handoff@<v> --pin ext:handoff/handoff`——`--pin` 在这个前端里的第一个真实 consumer。（T34 起那个键是 `[extensions] session_with` 列表里的一项，pin 由 manifest 的 `audience` 派生。）
6. **顺带的两处 CLI 清理**（内核那边同一轮）：`ext rollback` 动词删了（回滚 = `activate` 旧版本），所以 `/ext` 版本线只剩 `a`、`registry.ts` 不再认 `rollback` 这个动词、README 的键表跟着改；`config show --refresh` 变成 `nulya config refresh`（TUI 没有消费者，只有 README 一句话改）。

**测试**：`cd tui && bun test` 196 → **211 pass**（+`approvals.test.ts` 7 条纯函数、`gate.test.tsx` 7 条：ask 下等待 + `y` 真跑、`N` + 理由进 ledger 的 marker、卡片在等时 `/mode auto` 当场放行、auto 下直接跑、verdict 行的形状、handoff 文件的发现与去重、以及"这个 TUI 开的 session 真带着 handoff 的成员 + pin"（没有 zig 就 skip——compiled 包））；`tsc` 干净。改写：**跑真步骤的测试一律用 `auto_settings`**（`support.ts` 新增：`driver.mode = "auto"` + 关掉 handoff——没人在键盘前的测试就是 auto 那一档，而 handoff 会给每个被读回的 store 多一个包）；`/ext` 的 `r` 那条改成 `a`（同一个确认框）、`registry.test.ts` 的两动词那条改成"activate 一个动词 + 老拼写退回 shell 卡"、`render.test.tsx` 的 §5.2 那行改成 activate 旧版本、`/help` 快照重出（多了 `/mode` 行、`y/n/N/a` 键行、两条鼠标行，viewport 66 → 72）。内核侧：`zig build test` 全绿（`loop.zig` +2：allow-all == 无 gate、deny 只停这一个 call 且不记 journal）、`zig build e2e` 55 pass（新增一条：`--gate` 的请求行 / deny 带 note / allow 真跑 / EOF fail closed，`support.runCliStdin` 是为它加的第一个喂 stdin 的 runner）。

**没做**：`ask` 下没有"批准这一批"的快捷键（一次一个 call 是内核的形状，批量要另想）；`[approvals]` 不支持 glob（前缀够用，且不必学一套模式语言）；classifier（tcode 的 auto 档背后那个安全分类器）没有——它是 extension 的活，见 PLAN；handoff 的 brief 面板不可滚动（超过 8 行截断，全文在文件里）；`readonly` 目前没有任何自带包声明（`extensions/std` 的 `read` / `grep` / `glob` 是最该标的三个，等一次单独的改动）。

### T25 · 顶上那张卡：默认折起来，行不再被压缩（2026-08-19）

**内核零改动**，`tui/` 三个文件。来源是一张运行中的截图 + 一句话："这个对话面板这样显示是不是有点太丑了……默认也没必要全部展示出来吧"。截图上是五个自带扩展的完整版本串，把 CompositionCard 撑成八行，并且 `model` 那个标签显示成 `mode`。

1. **两个病其实是一个：行被压缩，不是被换行。** 卡里每一行原来是一串 `<text>` 组成的 flex 行，OpenTUI 对装不下的 flex 行**收缩子节点**——名字中间被切、标签与值之间的那个空格被吞（`modecodex/gpt-5.5`）。老代码知道这件事，办法是 `toolsFit()`：算一遍总宽，装不下就整行换成计数。但那只保护了 tools 行，model 行后面挂着 `· ext <五个全串>`，于是它就是被压缩的那一行。现在**没有一行是 flex 行**：`ui/Fact` 是"标签列 + 由我们自己折行的值"（`wrapWords`，先在 ` · ` 关节上折），Welcome 屏幕本来就是这么写的（T24 §5.1 那条注释写得很清楚），这次把它抽出来成第二个 consumer 共用——`toolsFit()` 连同它那套"装不下就变数字"一起删掉，因为值现在向下长。
2. **默认折起来（`transcript.composition`，默认 `collapsed`）。** 静息两行：标题 + model 行（模型 + `tools 2+N · skills n · prompts n · ext n` 那串计数）。判据是**改变这场 session 能做什么的东西留在外面，provenance 收进去**：模型与计数是前者，"哪个包冻在哪个 hash 上"是后者——它值得随手可得，不值得每一场都占五分之一屏。折叠走已有的 `state/folds.ts`（key = `composition:<session id>`），所以 `Ctrl+Shift+O` 一起管它；头行点击 = 折叠（与每张 tool 卡同一个手势、同一个右端记号列），model 那一格的点击 `stopPropagation` 后仍是 `/model`（T20 起就有的目标，测试点的还是那一行）。
3. **哈希缩到 8 位**（`shortVersion` 是 `/ext` 版本线 T23 就有的同一条规矩：散文里一律短哈希，全串留给要贴进 `ext activate` 的地方）；`prompts` 从计数改成**贡献者的名字**（`prompts  evolution` 比 `prompts 1` 多告诉你一件事，而这行只在展开时出现）；窄屏时标题整段退让（完整 → 去掉 `frozen composition` → `session`），计数从末尾整格丢弃——切成 `e…` 的一格什么也没说。

**测试**：`cd tui && bun test` 211 → **214 pass**、`tsc` 干净。`render.test.tsx` 的那张卡拆成四条：静息两行（新快照，断言 provenance 确实不在屏幕上）、展开全貌（新快照）、40 列不压缩（逐行断言宽度 ≤ 41、`mode ` 不出现、长哈希不出现）、头行点击开关一次。老的"tools 行装不下就退回计数"那条随 `toolsFit()` 一起删除；ascii 那条改成在展开的设定下跑并多断一句折叠记号也降级了。`zig build test` / `zig build e2e` 未受影响（内核一字未动）。

**没做**：`Ctrl+O`（"最近一张卡"）不认这张卡——它按 transcript item 找，而 header 不是 event；要它得给 browse 模式一个非 item 的成员，不值。`/settings` 里没有为这个键单开一行（它和另外三个 fold 键同表）。draft 屏（Welcome）没动。

### T26 · 一屏的节奏：把 tcode 的密度学过来（2026-08-19）

**内核零改动**，`tui/` 十个文件。来源是用户贴的一张 tcode 截图 + 一句"我们的还有一种廉价感"。对着两张图看，差的不是颜色也不是字形，是**三件排版上的事**——而它们各自都指向同一个毛病：这块屏幕在**报告**，不在**叙述**。

1. **右对齐的 chip 是廉价感的第一来源。** 一行 `⌘ lint_zig · path=src/emit.zig` 后面隔着三十个空列，第 98 列上挂一个 `ok`——第二列小字，每张卡都有，而且它说的那件事（成功了）本来就是默认。改成 tcode 的写法：note 用括号紧跟头行、fold 记号在文字末尾，整行从左往右读完。行内没有一个节点会被 flex 压缩（头行由 `fit` 切到 note 剩下的宽度），窄屏于是切的是命令而不是 `exit 1`——原来 60 列以下是把整个 chip 丢掉的，正好丢掉那一行上唯一要紧的东西。
2. **成功是沉默的。** `ok` 从每一张卡上删掉：一次调用只说它带回来多少（`(121 lines)` / `(+2 -1)`），失败才说词并且只有那时候才有颜色（`exit 1`、`failed`）。`ChipTone` 的 `ok` 一档随之删除（没有写者了）。`exit 0` 同理不写。`sizeNote` 一个函数管三张卡的计数，顺手修掉 `1 lines`。
3. **空行是有语法的。** 原来 `marginTop={1}` 挂在 UserTurn / AssistantTurn 两张卡上，tool 卡一个都没有——于是一句话和它下面六次调用焊在一起，整屏没有纹理。现在垂直节奏是 `Transcript.gapBefore` 一个纯函数：**run 内 0**（六次调用是一块，就是 tcode 的 `Read 5 ranges` 在做的事，只是我们每行自带 glyph、不需要那行汇总）· **beat 间 1**（thinking 属于它后面那句话，所以那里也是 0）· **人开口前 2**（换一轮对话不只是换一个 beat）。卡片自己不再决定自己上面有多少空——一处定节奏，`render.test.tsx` 的 `Harness` 也改成走真的 `Transcript`，因为空行现在是快照要钉的东西。
4. **顺手把三件"看着像 bug"的东西修了**：Thinking 并进 `CardFrame`（原来 fold 记号在**左**边、别的卡都在右边，而且它的 toggle 挂在裸 `onMouseDown` 上——拖过去选文字会把它折起来，正是 `ui/rows.ts` 存在的理由）· 参数摘要的第一个参数不写键名（`read · src/emit.zig · offset=1`，工具的第一个参数就是它的主语）· edit 卡的 diff 高度多算了 patch 的三行头和一个尾行，每张 edit 卡底下都拖着两行空白。
5. **三条通栏 hairline 换成输入框自己的边框。** 四个区、三条线，其中两条隔开的正是输入框的上下边（输入框自己就能说这件事），第三条在只有一个 tab 时上面什么都没有。现在整屏只有一个有边框的东西，就是**你打字的那个框**（圆角，ascii 降级成 `+-|`）——它同时是"在这里打字"的邀请与**键盘在不在这里**的唯一信号（有焦点 `accent.user`，browse 模式 / overlay 拿走键盘时退回 `hairline`）。框还**随内容长高**（`wrappedRows`，1–8 行）：原来恒定三行，于是任何时候都有两行是空的，而粘一段十二行的东西时它在三行的窗口里滚。两个真 bug 一起掉出来：`›` 那个 glyph 没写 `flexShrink={0}`，一段够宽的文字会把它挤没（文字于是比自己的续行还靠左一列）；`onPaste` 在**不折叠**的短粘贴上直接 return，镜像信号 `line()` 不更新——补全菜单与新的高度都会照着粘贴之前的内容算，而 IME 上屏一整句走的也是这条路。

**测试**：`bun test` 214 → **216 pass**、`tsc` 干净。新增两个纯函数的单测（`gapBefore` 三档 + 真帧断言"两次调用是邻居、上面那句话不是"；`wrappedRows` 含 CJK 双宽与结尾换行，外加真渲染的"框会长高"）；窄屏那条从"chip 被丢掉"改成"切头行、`exit 1` 留下、每行不超宽"；`registry.test.ts` 多一条"第一个参数不写键名、后面的照写"；`layout.test.tsx` 的"三行"改成"框的上下边都在"；`transcriptOf`（live == replay 那条）改成切到输入框的框上沿，因为它原来是靠两条 hairline 定位的。全部卡片快照重出。

**没做**：不做 tcode 的 `● Read 5 ranges` 汇总头行——我们每次调用自带 glyph，汇总只会多一行并重复它下面已经写着的东西；不给 assistant 正文上色（`fg` 是内容该在的那一档，代价会落在 markdown 的代码块上）；`Ctrl+O` 仍然只认 transcript item（header 不是 event）；输入框的宽度没跟着 `max_width` 收（框是屏幕的家具，不是内容）。

### T27 · 审批面板、批量答复、Ctrl+C 的三层含义（2026-08-19）

来源是用户的一张截图和三句话："只要 prompt 发出去就不是 queue 了吧"、"我现在都不知道如何审批，run this 好像都挤在一起了"、"prompt 框有输入的时候 Ctrl+C 也直接退出了"。三件事，其中只有第一件需要动内核。

1. **`queued` 挂满整个 step，是协议的顺序问题不是标签问题。** `session append` 投进 inbox，前端乐观回显并标 `queued`，等对应的 `user_text` **ledger 行**到达才转正——而 `--stream` 原本把一个 step 的**所有** ledger 行攒到 `step end` 才刷。于是那条消息明明在 step 边界就已经排干、进了 ledger、模型已经在回答它，屏幕上还写着 `queued`。修的是**报告的时机**而不是前端的猜测：`StepStream` 拿一个只读的 ledger 句柄，`model started` 一到就先把尚未报告的行刷出去（那一刻唯一可能存在的就是刚排干的 `user_text`）。前端一个字没改——它本来就在等那条行。不猜的理由：前端"看到 started 就把 queued 清掉"会在"append 刚好落在排干之后"的窗口里说谎，而那条消息接下来还要靠 `pendingCount` 决定要不要再跑一个 step。
2. **审批那一行是八个 text 节点排的 row。** 窄于 78 列，终端就从任意位置把它折成两行（`run this?` 和键名互相插进对方中间——截图里正是这样）。而且位置也错：一个 turn 的整批 call 在第一个执行之前就全画出来了，内核停在的那张卡通常**不是**最后一张，问句夹在两张卡中间。改成**输入框上面的面板**（与 §5.8 的 handoff 面板同一个位置：答案给在哪里，问题就问在哪里），一行一个答案、每行一个字符串由我们 `fit`、鼠标点行 = 按那个键；卡片上只留一行 `waiting for you — answer below` 说明是**哪一个**。状态栏不再重复键名（那正是 `y allow · nasknstep 1 · driver` 的来源），顺手给 activity 段也套上 `fit`——它原来只被**测量**不被**切**，超宽就撞进右边的 chip。
3. **批量：tcode 的形状搬不过来，能搬的是它的意图。** tcode 按 tool 自己的 `BatchPolicy` 把一整批放进一个对话框；nulya 的 gate 是串行的（内核只在 call N-1 跑完之后才问 N，DESIGN §4），一个 driver 手上根本没有"整批一起答"的位置。等价物是 `A`：那一批的卡片**全在屏幕上**，人看着它们一次答完剩下的。实现是记下那些尚未执行的 `call_id`，逐个消费——**不是布尔**，否则一次 run 里的下一批（还没人看过）会被悄悄盖住；排在 `[approvals] deny` **之后**，一条"永不"不该被一次关于六个 call 的按键推翻。
4. **顺手掉出来两个真 bug。** `pending` 是**一个槽**：这个进程能同时 drive 多个 tab，第二个 gate 请求会覆盖第一个，那个 step 于是永远等一个没人能兑现的 promise、并一直攥着 `<id>.lock`——改成队列。以及 `gate.test.tsx` 里 `/mode auto` 那条测试**没有 statePath**，`rememberMode` 于是写进这一趟共享的 `tui-state.json`，把它后面每个测试的起始 mode 都变成 `auto`（被 `isolate.ts` 的 `NULYA_HOME` 挡在开发者的 `~/.nulya` 之外，但同一趟内是真串味）。
5. **Ctrl+C 由近及远，永远不在第一下退出。** 输入框里有字 → 先清空 · 正在 stepping → 先 kill 这一步 · 都没有 → 先说 `Ctrl+C again to quit`，再按一下才退（提示 3 秒失效）。原来第三档是直接退。写了一半的消息和整个屏幕，都不是第二次按键能撤销的东西。

**测试**：`bun test` 216 → **219 pass**、`zig build test` / `e2e` 全绿。`launch.ScriptedProvider` 多一档 `batch`（一个 turn 三个 shell call）——与 `handoff` 档同一个先例：串行 gate 的形状需要一个离线替身才能被测。e2e 的 `--stream` 首行断言从 `model started` 改成排干的 `user_text` 行，`cli.test.ts` 的整串行序同步。

**没做**：不给面板做 `↑↓` + Enter 的选择器（tcode 有，但那里对话框独占键盘；这里输入框还得能收下拒绝理由，方向键归它）；`A` 不落任何持久规则（持久版本是 `[approvals] allow`）；`/mode` 仍是两档——`accept-edits` 那种第三档要等 manifest 的 `readonly` 之外还有别的可信声明。
\n
### T28 · 审批不是一句 `[y/n]`，是一个对话框（2026-08-19）

**内核零改动**，`tui/` 九个文件。来源是用户看过 T27 之后的一句："这种方式感觉特别终端，我更喜欢 tcode 那种完全支持鼠标交互的模式……特别重要的是 Tab 后可以在任意选项输入 note，这个功能我经常用，这块是必须有的。"

T27 已经把问句从卡片挪到了输入框上面、把每个答案拆成自己的一行。**剩下的问题是形状**：那还是一列"要按的字母"（`y` 允许 · `a` 不再问 · `n` 拒绝），也就是 `[y/n]` 加了几个词。它有两个真毛病：鼠标只能点，不能**移动光标**（没有"我正看着哪一行"这回事）；而 note 只挂在 `N` 这**一个**键上——想在同意的同时说一句"下次用 ls"，屏幕上没有这个东西。

1. **一个可选、可点的答案列表。** 光标（`▾` + selection 底色）、悬停（`·` + hover 底色）、数字键、`↑↓`、`Enter`——与 `/ext` `/sessions` `/model` 每一个列表**同一套** `ui/rows.ts`，因为它本来就是同一种东西。**悬停即移动光标**（tcode `approval_mouse_moved`），所以点击答的永远是眼睛正看着的那一行；单击直接作答（tcode `approval_mouse_down`），不需要"先选中再确认"两步。五个答案按**影响范围从窄到宽**排：这一个 call · 这一批剩下的 · 这一类（本场） · 从此以后（= 切 `auto`，tcode 的 `set_mode` 选项） · 拒绝。
2. **note 属于对话框，不属于某个键。** 底下常驻一个 note 字段（`<input>`，`ProviderView` 已有先例），`Tab` 进出，**直接打字也进**（tcode：伸手去写字就已经在写了，所以它从不需要被发现），而 `Enter` 把它和**光标所在的那个答案**一起交出去。于是"可以，但下次用 ls"和"不行，因为…"是同一个手势换一行光标——这正是 note 该住在对话框而不是住在 `N` 上的理由，也是 `N`（"deny with a reason"）这个答案就此消失的理由。鼠标作答同样带上 note：写完再点，字不会白写。
3. **note 的去向分两条，因为内核只有一条。** `deny <note>` 是 gate 自带的（进那个 call 的 marker 结果，DESIGN §4）。**allow 没有 note 通道，也不该加一个**：call 跑了，模型接下来读的是这个工具自己的输出；再长一个 payload 等于让内核决定一个人的话该落在转录的哪里，而那是 prompt 的判断（physics #8）。所以它走**所有话都走的那条路**——`session append`，下一个 step 边界排干，正好落在它评论的那一批 `tool_results` 后面。框架是 `approvalnote.ts`：与 `midtask.ts` 逐条同形的 sentinel + 一次性 contract（`<user-approval-note tool="shell">`），卡片按 sentinel 折回人自己的话、badge 写 `note on shell`。`Driver.send` 因此多一个 `framed` 参数：已经自带框的文本不该再被 mid-task 的框套一次。
4. **对话框拿着键盘。** 内核就停在这一个 call 上，屏幕上没有别的地方可打字——这正是"打字 = 写 note"能成立的前提，也是 T27 那版为什么必须把 `y`/`n`/`a` 从一个还活着的输入框里抢出来。代价是这几秒 `/mode auto` 打不出来，于是它成了列表上的第四个答案（也就是 tcode 早就有的 `set_mode`）。`Ctrl+C` 与一切带 modifier 的键照旧穿过去：杀掉这一步是不想回答时的另一条出路。

**测试**：`bun test` 219 → **221 pass**。新增 `approvalnote.test.ts`（6 条，含"两个 sentinel 互不相认"——卡片路由先问它，一条 mid-task 落进那个分支会被安上一个它从来不属于的 call 名）；`gate.test.tsx` 改成走新形状，并补三条：**allow + note**（call 真跑了，note 作为一条带 sentinel 的 `user_text` 进 ledger、屏幕上 badge 是 `note on shell`）· **纯鼠标作答**（`moveTo` 移光标 → `click` 作答，note 一起带走）· **数字键选到 `mode auto` 那一行**（原来那条"打 `/mode auto`"的测试的去处）。

**没做**：不给面板加边框（§6 仍然只有输入框有边框，整屏一个）；note 仍是单行（多行要么变成第二个 composer，要么让面板顶掉转录，两者都不值）；不做 tcode 的 `ask_user` 表单——那要内核先有一个"模型向人提问"的原语，今天没有，它属于 PLAN。

### T29 · 后台任务：内核已经把结果放进 inbox，屏幕只欠一步（2026-08-20）

**内核零改动**（B1–B4 已经把 substrate 全长完了：`shell {background:true}` → supervisor → inbox → 第五种事件 `task_finished`，DESIGN §6.1 / §3.1）。`tui/src/` 十九个文件（三个是新的：`state/tasks.ts` · `render/cards/TaskFinishedCard.tsx` · `ui/overlays/TasksView.tsx`）。这一轮真正新增的判断只有一条，其余全是"把内核已经答出来的东西画出来"。

1. **唯一的新 policy 是三个词：driver + idle + inbox 非空。** 内核不会替谁决定何时再 step（physics #8），所以一个任务结束后，报告就躺在 `<id>.inbox/` 里等一个 step 边界。判据写成 `driver.wake()`：**inbox 非空**才 drive，而不是"某个任务 done 了"——任务结束只是让 inbox 非空的来源之一（别的终端 `session append`、`ext activate` 的 note 都算），而 inbox 为空时裸 step 会把上一条 assistant turn 当 prefill 重发（DESIGN §4）。轮询搭 `probeWriterLease` 那个 idle 定时器的车，一个新定时器都没起；角色判断留在 `attach.ts`（`if (role() === "driver") void driver.wake()`），`driver.ts` 只回答"里面有没有东西"——observer 去踢就是抢别人的写者租约。
2. **`lost` / `starting` / `elapsed_s` 一律读内核的投影。** `nulya task list --session <id> --json` 是任务面的唯一数据源（`state/tasks.ts`，per-tab 的 watch）。这两个状态要同时读任务目录和那把锁才答得出来，前端复刻一份迟早跟唯一算数的那份说两样话——与 T8 让 `/sessions` 改读 `session list --json` 同一条纪律。轮询自己关自己：没有未 done 的任务就不发进程，所以一个从没起过任务的 session 只付 tab 打开那一次。
3. **两张卡靠全名连起来，连接点在 ledger 而不在轮询。** 回执首行 `[background task <sid>/t<N> started]` 与事件里的 `task` 是同一个字符串，所以 `session.ts` 排干那条事件时按名字找回发起它的那张 shell 卡、记下 exit 与耗时（`ToolItem.taskResult`）——**重开一场照样显示**，不靠任何进程。只有"还在跑，已经几秒了"这种没法 append 的事实才走 live 投影（`TasksContext`，与 fold / browse 同一种 context 形状，所以快照测试不需要 provider）。`task_finished` 是**自己一张卡**而不是那张卡的更新：那次调用早就返回过了（返回的是回执），这是几分钟后的第二个事件，模型也是当成新的一轮读的。不加新 glyph（还是 `$`），`exit 0` 照 T26 沉默。
4. **`registry.ts` 多一句判断：后台启动不是它命名的那个动作。** `shell {command:"nulya ext build …", background:true}` 原来会被演化表认成 EvolveCard，头行去 stdout 里找一个还不存在的 version、note 报"回执有几行"——都是关于回执的话，不是关于那条命令的。判据取 **args 里的 `background`** 而不是结果文本（前者在整个调用生命周期里稳定），落在那个唯一按名字 / 前缀 match 的文件里。
5. **状态栏在 idle 时也说话。** `⠋ 2 background` 排在两个 stop reason（都要人按键）之下、其余静息状态之上：任务活得过 step，一条正在跑的命令是那一刻唯一还在发生的事，写"idle"才是假话。spinner 的定时器因此也要认它，否则那个 `⠋` 是一个不动的字符。
6. **`/tasks`（F7）里 `k` 是 kill 不是光标**——全前端唯一 `j/k` 不移动的列表，光标只认方向键，footer 写明白。理由：这个面板的行是可以被停掉的进程，`k` 从 kill(1) 起就是这个意思；一个键在五个面板里移动光标、在第六个面板里毁东西，是两种不一致里更糟的那种。`k` 不二次确认（杀错了重跑一次，杀不掉的任务才是没有 undo 的那个），`K` 杀掉所有还在跑的，`Enter` 看 log 最后 64 KB（跟着 1.5 s 轮询重读，不求真·live tail）。
7. **`/quit` 说一句，不杀。** 离开这个前端不该停掉一个 detached 的进程——内核里根本没有"session 结束"这个概念，而结果会在 inbox 里等下一个 step（下一次开这场 session 的人就会读到）。所以只提示一次 `N background tasks keep running; their results land in the session inbox`，再 `/quit` 一次就走；要停在 `/tasks` 按 `K`。

8. **review 时补上第四个条件（同日）**：唤醒只对**本进程驱动过**的 session 生效（`attach.ts` 的 `driven`：`session new` 出来的、或从这个 tab 发过消息 / step 过 / `↵` 接管过）。实现时留下的那条观察——刚打开的 sub-session tab 在第一次探针前有 ≤700 ms 可能替别人跑一步——不只是多跑一步：对方的下一次 `session step` 会被 `SessionBusy` 拒掉，`drivers/goal.*` 就此 exit 1。规则仍然只在一个地方（`attach.ts` 那一行 `role() === "driver" && driven`），`tabs.ts` 在 materialize 时把 `created` 递成初值。`tasks.test.ts` 多两条：只打开不说话的 tab 面对非空 inbox 不动、发过一条消息之后 append 就能唤醒；`driven: true` 的 attachment 从第一次探针起就排干。

**测试**：`cd tui && bun test` 227 → **244 pass**、`tsc` 干净、`bun build --compile` 仍出单文件。新增 `tasks.test.ts` 9 条：真二进制的 `background` 档全环（起任务 → 本步以 waiting 收尾 → 谁都不碰它 → 报告进 ledger → 模型说 `background done` → 卡片记下 exit → **inbox 空了就不再自己 step**）· 空 inbox 上 `wake()` 两次一个事件都不多 · 持锁的另一个写者在时 observer 一步都不走（step 的二进制换成 `bun`，真走了会在状态栏留一句，沉默就是断言）· `task list --json` 的每一列 · 回执与报告的解析四条（命令里带 ` · `、killed、timed out、无输出、读不懂就返回 null）· 一条报告只认自己那张卡。`render.test.tsx` 加三条（后台变体的 running / 报告到了 / TaskFinishedCard 折叠与展开，三张快照），`overlays.test.tsx` 加两条 `/tasks` 的帧，`registry.test.ts` 加一条“后台的 `nulya …` 不是演化卡”。

**没做**：跨 tab 的任务汇总（`/tasks` 只看当前 tab 的 session，整个 workspace 用终端里的 `nulya task list`）；后台输出实时进 transcript；退出时自动杀；`/tasks` 里没有"再跑一次"（重跑是一句话，让模型说）。

### T30 · `edit` 不再是 builtin：TUI 侧只有计数与 pin 列表要改（2026-08-20）

**内核那一侧的改动是删东西**（DESIGN §6：内核只剩 `shell` 一个 builtin，`edit` 成了 `extensions/std` 的第六个 tool，§7.8）。前端因此只有三处，全是把已经变了的事实说对：

1. **`builtin_tools` 从 2 变成 1**（`pins.ts`），于是 `tools 1+N`、配额行 `1+N/<max>`、`faceFullLine` 都跟着对——这个数字本来就只有一个来源，改一处就够了；`StatusBar` / `CompositionCard` 原来各自写死 `2+`，一并改成读它。
2. **`std_pins` 六个**（`extensions.ts` 多 `ext:std/edit`），所以开屏那次后台安装把 `edit` 也 pin 上；`CompositionCard` / `Welcome` 的 tools 行不再手写 `shell edit`，只写 `shell` + 那些 ⚡。
3. **一次性迁移**（`adoptStdEditPin`，`main.tsx` 在读 config 之前调一次）：`tui-state.json` 里已经有旧的五个 std pin 而没有 `ext:std/edit` → 补上。**只做一次**，marker 记在同一个文件（`adopted_std_edit_pin`），所以之后在 `/ext` 里故意关掉 `edit` 不会被下次启动又打开——"帮你补一个你显然想要的" 与 "每次启动都替你决定" 只差这一个布尔。没有状态文件就什么都不做。**但要等这台机器上生效中的 `std` 真的声明了 `edit` 才补**（`stdEditPinDecision` 三态 `done` / `adopt` / `wait`：`ext list` 找 `std` 的 `current`、读那个冻结 manifest 的 `contributes.tools`）——user store 里的 std draft 是老源码时（`ext seed` 不刷新已有 draft，DESIGN §7.8），一个内核解析不到的 pin 会让下一场 `session new` 直接 `PinToolNotDeclared`，所以那时什么都不写、下次启动再看；fresh 的状态文件（没有 std pin）直接标 done，不为它多跑一次 `ext list`。

EditCard 一个字没改：它按 `view.tool === "edit"` 选卡，而 extension tool 的 model-visible 名字就是 manifest 里的 `name`，仍然是 `edit`；diff 仍从 `old_string` / `new_string` 画（成功时不显示 tool 输出，所以新增的回显片段不会重复出现），失败时显示的就是 std 的教学文案。

**测试**：`cd tui && bun test` **244 pass**（三条快照与四条断言里的 `2+` / `shell edit` 改数）、`tsc` 干净。

### T31 · 模式这个词有两种意思，两种都没说清（2026-08-20）

`docs/BUGS.md` 的头两条，根子上是同一件事：**屏幕上有两种"模式"，哪一种都没把自己的影响范围说出来**。一种是包戴在会话头上的 system prompt（`evolution`），一种是权限档（`ask` / 那时叫 `auto`）。内核零改动，`extensions/` 零改动。

#### 一、`evolution` 被后台悄悄 activate（BUGS 1）

现象是"我没启动 evolution，模型却说自己是 slow loop"。查下来 `~/.nulya/extensions/evolution/current` 确实指着一个版本——而 `evolution` contribute 的是 `[skills prompt]`，**activate = 它的 identity system prompt 进每一场 session 的 system blocks**（DESIGN §5.3 / §7.8）。谁指的：`App.syncStores` 的 auto-activate 循环，它当时唯一的守卫是 `arrived.includes(line.id)`——只挡得住 `ext seed` 刚落下源码的**那一次**启动。之后 draft 一重建（或者手动 seed 过一次），`state === "built"` 就把它 activate 了。

修的是四处，第一处是判据、其余三处是把这件事说出来：

1. **`extensions.autoActivatable(id, prompts)`**（纯函数，`bun test` 钉住）：`bundled_driver_only` 的三个按名字拒（**T34 删掉了这一半**，只剩下面那条通则），**任何声明了 `contributes.system_prompts` 的包**按通则拒——那是"模式"，选模式是人的决定，不是启动的副作用。`prompts` 为 `null`（读不到冻结 manifest）也是拒：分不清的时候，留着不开的代价是 `/ext` 里一次按键，反过来的代价是这台机器上的每一场 session。配套两个小件：`syncRoot(ws, user)`（`ext sync [--user]` 作用的那个 root，所以刚 build 完的版本在哪儿是已知的，不必再 `ext list`）与 `promptsOf`。后台 pass 主动跳过的 id 会在那一行 sync 汇总里点名（`… built, left off (a mode) · /ext`）——建好了却什么都不做的包，不说就是个谜。
2. **`/ext` 把后果说出来**：id 列表多一列 `mode`（`modeCell`，on 时 warn 色），详情面多一行 `a mode · turning it on puts its system prompt in every new session on this machine · /evolve（或 /as <id>）wears it for one session instead`，Enter 的 notice 换成 `promptConsequence`——`evolution active · its system prompt now enters EVERY new session on this machine · /evolve wears it for one session instead · Enter again to turn it off`。**开关仍然是一个键、仍然不问 `y`**：它只是不再沉默。
3. **开屏点名**：`syncStores` 收尾时 `activePromptPackages(await listExtensions(ws))`，有就在状态栏说一句并指 `/ext`（`promptPackageWarning`）。**不替人 deactivate**——关掉和打开一样是决定。这一半是守卫补不了的：指针已经在盘上了。
4. **进化模式怎么进要看得见**：`/help` 与 `commands.ts` 的 `/evolve` 改成人话（慢速回路：复盘已完成的 session、判断该不该留下或造工具；开一个新 tab 戴上它，**什么都不 activate**）；`/evolve` 执行后自己补一句 notice（开了新 tab、戴的是哪个版本、下一条消息才开场）；draft tab 的标题带上 `--with` 的 id（`tabLabels`：`scripted-demo · evolution (new)`——`/evolve` 开的第二个 tab 与第一个同模型，不写就完全一样）；状态栏多一个 `◈ evolution` chip（`StatusBar.wearing`，draft 读 `bring()`，已开场的 session 读冻结 `contributions` 里有 system prompt 的成员——顶上那张卡默认折着，折起来之后原本一个字都没有）。

#### 二、权限档：`auto` → `unsafe`，切换不解释，改成一个 picker（BUGS 2）

- **名字**。tcode 有四档，它的 `Auto` 是 **classifier 审核**；nulya 这一档没有任何审核，就是不问就跑——那是 tcode 的 `Unsafe`。叫 `auto` 是在承诺一个这里根本不做的判断。全量改名（`approvals.ts` / `/mode` / 审批对话框那一行答案 / 状态栏 chip / `commands.ts` / `/help` / 测试）。迁移只有一处：`approvals.normalizeMode(word)` 把外面来的词（`tui-state.json`、`tui.toml [driver] mode`、`/mode` 的参数）里的 `auto` 读成 `unsafe`，写回时写新名——**`isMode` 不再认 `auto`**，认它的只有这一个函数。
- **切换不再解释**。原来每次切都甩两句话到状态栏，而状态栏是全屏最挤的一行（model / cost / activity 都在上面），一句解释把它们挤成一团。chip 本身就在说是哪一档，picker 刚刚才把两档都说过一遍——说完了就没有什么要宣布的。
- **`/mode` 是一个 picker，不是 toggle**（`ui/ModePicker.tsx`，参考 tcode `mode_picker.rs`）。toggle 这个手势天生说不出另一边是什么，那正是它非要配一句解释的原因。picker 是**输入框上面的一个对话框**，与 T28 的审批对话框同一套样子（标题、`rowGutter` 的光标/悬停、一行一个答案、悬停即移光标、点一下即作答）与同一套键盘归属（在的时候拿键盘，`Ctrl+C` 除外）。一行一个 mode + 一句说明（`ask` = ask before every tool call no rule settles；`unsafe` = run every tool call without asking · only `[approvals]` deny / ask rules still stop it——最后半句是它不是全有全无的唯一理由）+ `✓` 当前 + 底下一行 hint。`↑↓`/数字键移动、`Enter`/单击选、`Esc` 收，**夹住不回绕**（两行的回绕会让 ↑ 和 ↓ 变成同一个键）。`/mode ask|unsafe` 仍然直接切。picker 排在审批对话框**前面**拿键盘：点 chip 是"别再问我了"这个手势，正好会在有 call 等着的时候发生，而选完 `chooseMode` 当场重裁那个 call（原来就有的逻辑）。
- **`/model` 也向 tcode 靠**（`model_picker.rs`）：标题带 `◈`（新 glyph `picker`，只给两个 picker 用——列 store 或 journal 的面板是"地方"不是"选择"，标题照旧）、**按 provider 分组**（`pickerLines` 把 rows 投影成 heading + model 两种行；provider 从每一行的一列变成组标题说一次，`no key` / `offline stand-in` 这类关于 provider 自己的话也跟着搬上去）、`✓` 标当前、effort 档位照旧是 `‹ x ›` 的转盘、底下 hint 改成 `↑↓ model · ←→ effort · Enter starts a session · Esc close`。窗口按**画出来的行**算并且永不停在没有标题的组上。

**没照抄 tcode 的两处**（有意）：① 选中标记仍是共享的 `rowGutter`（`▾` 光标 / `·` 悬停）而不是 `▸`——这一套是全应用六个列表共用的视觉语言（tui.md §6），为两个 picker 破例，换来的是别处全部不一致；② 没有边框——`§4.1`/`§6` 定的就是无边框，审批对话框也没有。

**测试**：`cd tui && bun test`、`tsc` 干净。新增：mode 迁移与 picker 选择逻辑（`approvals.test.ts`）、`autoActivatable` / `promptConsequence` / `activePromptPackages` / `promptsOf`（`extensions.test.ts`）、`/mode` 开 picker 与选完不解释（`gate.test.tsx`）、点 chip 开 picker 并点行作答（`mouse.test.tsx`）、`/ext` 的 mode 列与后果文案（`overlays.test.tsx`）、`tabLabels` 带 `--with`（`evolve.test.ts`）、状态栏 `◈` chip（`views.test.tsx`）。

### T32 · sub-agent 第一期：一个定义文件，就是一组 `session new` 参数（2026-08-20）

**内核零改动**，`extensions/` 零改动。新文件三个（`src/agents.ts` · `src/ui/AgentPicker.tsx` · `test/agents.test.ts` + `test/delegate.test.tsx`），其余是小接线。设计契约在 §5.10；这里只记为什么是这个形状。

1. **没有新机制，一个都没有。** PLAN §3.2 那句"一个 agent 就是 `session new` 的一组参数"是这一轮唯一的设计，剩下全是把已有的东西按那句话摆好：`ext build` 一个 draft（`/evolve` 的路）· `session new --with <精确版本>`（`/evolve` 的路）· `--pin` 一个工具面（T12 的路）· `--max-steps` 一次 run（driver 本来就有的 option）· `--gate` 拦一个 call（T24 的路）。**`src/` 一个字节都没动**，`docs/DESIGN.md` 也因此一个字都不用改——没有新的内核事实。
2. **system prompt 只有一条路进 session，所以材料化不是绕路，它就是那条路。** physics #3/#4：model-visible 状态只经 append 改变，换 composition = 换 session。一个 persona 要被模型看见，只能是某个**冻结的 extension 版本**贡献的 system block。把 markdown 渲染成 data extension 因此不是"为了复用 extension 机制"，而是"这本来就是唯一的机制"——顺带白拿内容寻址：改了 markdown 就是新版本，没改就是老版本，`/agent` 每次都 build 也不用谁记得重建。
3. **trust 问句的时序是被 DESIGN §9 逼出来的，不是抄 T11 抄的。** 本机 `ext build` 填满一个空的 workspace store **就是**信任（出生地规则）。所以"第一次材料化一个 project 定义"这个动作会替 checkout 把名签了；问句必须早于它，而"早于它"最干净的位置就是 T11 那个问句旁边——屏幕还没进备用屏、`session new` 还没发生。两个键而不是三个：这里没有"装一半"这回事，只有"别人写的 persona 能不能拿着本 workspace 的工具说话"。
4. **`readonly` 排在三张表之前，是因为它排在别的地方就会变成谎话。** 决策序原本是 deny → always → ask → allow → manifest readonly → mode（§5.7）；readonly agent 的天花板插在**最前面**且不可上诉。理由不是"更安全"（它本来就不是安全边界，§5.7 末句），而是**语义**：`readonly: true` 的全部意思就是没有东西能掀开它，一条 `allow` 能把 `shell` 放回来的话，这个词就只是装饰。拒绝用内核自带的 `deny <note>`，于是模型读得到自己为什么什么都没跑，而且那句话在 ledger 里而不是只在屏幕上。
5. **picker 选中一行不启动任何东西。** 它把 `/agent <name> ` 写进输入框就停手。一个委派需要一个任务、任务没人猜得出来，而"替人编一个任务然后开场"是这个前端唯一不能犯的那类错——和 T22 那条"第一条消息才开场"是同一条纪律。
6. **`◈` chip / tab 标题 / CompositionCard 全部白拿**：sub-agent 的 session 戴着 `agent-<name>` 这个 `--with` 成员，T31 已经把"这一场戴着谁"画在两处了，所以这一轮**没有**为 sub-agent 加任何显示代码。

**测试**：`cd tui && bun test` 257 → **272 pass**（新增 `agents.test.ts` 11 条纯函数——front matter 的四种写法 / 字段全解 / 缺省 / 坏文件 warn-skip 的两种跳过与四条警告 / 双层发现与同名点名 / manifest 形状 / **真二进制的材料化幂等与改一个字得新版本** / readonly 天花板 / 问句只问一次 / 答案落盘；`delegate.test.tsx` 4 条真二进制全环——`/agent` 开出戴着 persona 的子 session 且 **read-only 的 `shell` call 在子 ledger 里是 `ok=false` 带 gate note**、未知名字列全并什么都不建、没给任务时说清为什么要给、裸 `/agent` 的 picker 与"Enter 只写命令"）。`/help` 快照重出（多了 `/agent` 三行，viewport 74 → 77）。`tsc` 干净。

**第二期（同日）：模型自己委派，靠内核已有的后台任务回路。** `extensions/agent`（compiled，四个源文件）三个 tool：`agent{name,task}`（模型的委派：材料化 → `session new` → `session append` → `task run`，回执点名子场并叫模型收尾）· `materialize{name}`（定义 → 冻结的 data extension 版本；**这套渲染的唯一实现**）· `run{session,agent?,readonly?,max_steps?}`（后台任务跑的那条命令：解析 `session step --stream` 的 JSONL、`readonly` 时以 `--gate` 机械应答、把子场最后一条 assistant 文本包成 fence 打 stdout）。**内核零改动。**

7. **第一版规格被否掉的那件事，值得记下来。** 原方案是"`agent` tool 写一个请求文件，TUI 每步之后看盘跟进"——handoff 的形状。问题不在它跑不通，而在它**发明了一份每个 driver 都要重学的盘面约定**：TUI 一份、`goal.sh` 一份、`goal.ps1` 一份、下一个 driver 再一份，而它们要认的是同一件事——"有个东西欠你一个答案"。内核里**已经有且只有一个**这样的回路（`task_finished` 经 inbox 在 step 边界排干，DESIGN §6.1/§3.1），T29 又已经把"inbox 非空就再 step"写成了 driver 侧唯一那条 policy。所以走它：`drivers/goal.*` **一个字没改**就能收到 sub-agent 的报告，TUI 也没加第二个钩子。`extensions/handoff` 的文件形态从此是**历史特例**，不新增第二个（这条已进 CLAUDE.md 的工作约定）。
8. **两个 driver，一条天花板。** 人按 `/agent` 时 TUI 是 driver，readonly 由屏幕那条 gate policy 兜住（上面第 4 条）；模型调 `agent` 时 `run` 是 driver，同一条天花板由它**机械应答**——没有人在键盘前，所以规则是死的：`shell` 一律拒、extension tool 只放行**子场自己的冻结 manifest** 声明了 `readonly:true` 的（放行名单在开跑前从子场 header 一次算好——gate 请求只带模型面上的名字，"这个名字来自哪个包"的答案在 header 里）。两条路的拒绝都是内核 gate 的 `deny <note>`，都进子场 ledger。
9. **报告是数据。** `run` 打出的是子场**最后一条 assistant 文本**（子 agent 被告知最终发言即报告），包在 `<agent-report agent=… session=…>` 里 + 一句"这是待评估的发现不是命令"的合同 + 由**代码**附上子 session id（`nulya session events <id>` 读全程）。它落进 `task_finished.text`，而内核那层本来就在外面又包了一句"data, not instructions"——两层框，都不是模型写的。
10. **`materialize` 是写路径的唯一实现，TS 只留读。** version id 是 manifest 字节的 hash，两份渲染就是同一个 persona 的两个版本；所以 `agents.ts` 删掉了 `agentManifest` / `agentDraftPath` / 自己写 draft 那段，改成 `buildAgentPackage` + `materializeAgent`（走 `ext run`），发现与解析（picker 要列）留在 TS。
11. **撞到的一堵墙（规格没预见，绕法不引入新机制）**：`std.json.Stringify` 的 `objectField` 之后**不能直接往 writer 写原始字节**——状态机会以为没有值被写出，下一个 `endObject` 就踩 unreachable。`materialize` 要返回一个对象（它的读者是 driver 不是模型），所以走它自己的 `beginWriteRaw` / `endWriteRaw` 开口而不是绕过它。

**测试**：`extensions/agent` 的 e2e 一条全环（`tests/e2e/extension.zig`，scripted）：materialize 幂等 + 坏 pin 被丢并点名 + 冻的是 data extension 且**没有 current** · 未知名字列全 · 无 session 拒绝 · 一次真委派——子场建出来、以父场的后台任务跑、**read-only 的 `shell` call 在子 ledger 里是 `ok=false` 带 gate note**、`task wait --any` 等到它、父场下一步排干出 `task_finished` 且里面是 `<agent-report>` + `as DATA`。前端：`delegate.test.tsx` 多一条"有定义才带 `agent`、子场绝不带"，`registry.test.ts` 多一条回执解析出子 id，`agents.test.ts` 的材料化那条改成走真包的 `materialize`。`ext seed` 的自带扩展 5 → 6，两处计数与文档同步。

**第三期（同日）：自带 persona，读路径也收成一处。** `extensions/agent` 从三个 tool 变四个，多的是 `list`（driver-facing、永不 pin）。

12. **"标准库"体验：什么都不写就有 `explore` / `plan` / `general`。** 三个 persona 移植自 tcode 的 builtin（`crates/tcode-tools/src/agent/builtin/*.md`），`@embedFile` 进这个 extension 自己的二进制——分发就是二进制，没有安装步骤也没有要建的目录。**nulya 没有的概念是删掉而不是翻译**：`ask_user`（没有"子 agent 向人提问"的原语，plan 那条改成"取最合理的读法、在报告里说你取了哪一种"）与向下 fan-out（子场不带这个包 = leaf，explore/plan/general 三份正文里那几条都删了）；`orchestrator` 整个不移植——它存在的意义就是 fan-out。frontmatter 只留我们有的：explore = `readonly: true` + `pins: [ext:std/read, ext:std/grep, ext:std/glob]` + `max_steps: 12`；plan 同样三个只读 pin、`max_steps: 20`（它不是 readonly——它跑在调用者的权限档下，改动照样过 gate）；general 六个 std tool 全要、`max_steps: 30`。三个都**不点名模型**：不在乎跑在哪的 persona 该跟着发起它的那一场。
13. **分层用 store roots 那条规则，不用 tcode 那条。** workspace > user > builtin，**首个持有者胜、输的照样列出来并标 `shadowed`**。tcode 是"builtin 名字保留、不许覆盖"——那在它那里成立，在这里不成立：这个仓库里每一样分层的东西（store root、config 层）都是遮蔽而不是拒绝，为一处破例换来的是别处全部不一致。
14. **读路径收成一处。** `list` 是定义格式的唯一 reader，`agents.ts` 里的 frontmatter 解析全删——picker、readonly 天花板、委派参数都读它。两个 parser 就是"这个 agent 是不是 readonly"的两个答案，而那正是天花板要变成一次拒绝的那个问题。**唯一的例外是 trust 问句**：它问在屏幕之前、任何 build 之前，所以读的是**文件名**（一次 `readdir`），不是定义。
15. **pins 连带 `--with`，且先验证。** 一个 pin 不让它的包成为成员，而 pin 非成员是整场拒绝，所以每个不同的 ext id 派生一个 `--with <id>`（取 `current`）。**并且 `materialize` 先验证**——不然消息是内核那句真话但没有出路的 `--with names an extension with no such built version`，而人需要的是"`explore` 要 std，`nulya ext build extensions/std --user`"。
16. **顺手改掉一个自己造的错**：`refreshAgents()` 一度挂在 `onMount` 上，于是**开屏就编译一次 agent 包**——正是 T11/T23 反复在赶出关键路径的那件事（它还顺带把别的测试的 `/ext` 断言打挂了，因为那个包出现在了共享的 user store 里）。改成懒的：`/agent` 用到时、或第一场 session 组装时（与 handoff 包同一形状）。带入条件也随之变简单——包自带 persona，所以"有定义才带"恒真，改成一个 `tui.toml` 键 `[extensions] agent`（与 `handoff` 并排），说不要的人有地方说。
17. **撞到一个内核 bug，没改内核**（`src/` 仍冻结）：`session new --with <解析得出来的> --with <解析不出来的>` 在 `composition.unionWith` 的 `errdefer freeResolved` 里 **panic（Invalid free）**；把解析不出来的放在**前面**则正常报 `WithVersionNotFound`。委派永远先放 persona 自己那个 `--with`，所以它永远走崩的那个顺序。绕法不引入新机制：`materialize` 先验证成员——这本来就是好消息该有的样子。已在报告里点名。

**测试**：`zig build test` 448 pass（新增 `extensions/agent/src/defs.zig` 六条：frontmatter 四种写法 / 缺省与 CRLF / 三种致命与四条警告 / pin 与 name 的形状 / **三层发现与遮蔽** / 自带三个 persona 都解析得出来且只有 explore 是 readonly；build.zig 第三个 `addTest`）。`zig build e2e` 69 pass（新增一条：什么都不写时 `list` 的形状与三个 builtin、workspace 同名定义遮蔽 builtin 且 `materialize` 取赢的那个、std 没装时点名指路且什么都不建、装上后 builtin explore 真委派——子场冻结里有 `agent-explore` + `std`、native face 正好是那三个只读 tool、`shell` 被 gate 拒）。`cd tui && bun test` 269 pass、`tsc` 干净。

**第四期（同日）：追问，以及谁可以委派。** `agent` tool 长出第二个形态、frontmatter 长出两个字段、builtin 补齐第四个。内核零改动。

18. **`agent{name|session, task}`：追问是同一个 tool 的第二个形态。** `session` 往一场**已经报告过的**子场再送一轮——append-only，子场带着它找到的一切 resume，**命中它自己的前缀缓存**（DESIGN §1），一次纠正只付一轮，而重开一场要把侦察再买一遍。这是设计红利而不是新机制：ledger 只 append，resume 就是再 step。四道门都在建任何东西之前：s-… 形状 · 冻结 header 必须戴着 `agent-*`（否则那是别人的对话）· **还在跑就拒绝**（判据用内核自己的 `task list --json`——驱动它的后台任务 `starting`/`running` 就是"还在工作"；往正在产出报告的 run 里塞一轮，报告说不清自己包含了什么）· `max_exchanges`（数子场的 `user_text`，未声明 = 不限）。每一轮一个新后台任务、一条 `task_finished`——**报告的路一条都没变**。
19. **`readonly` 自动仍然对**：runner 每次都从**那一场自己的冻结 header** 重算放行名单，追问既不换 composition 也不换 header，所以没有第二处要同步的东西。**并发点写进文档**：人若在 TUI 子 tab 接管说话、模型同时追问，撞的是 durable session 的单写者语义（`SessionBusy` / 上面那道"还在跑"的门）——行为安全，两个写者本来就是内核唯一拒绝的事。
20. **能不能委派，是被委派者定义里的一个字段**：`agents: [name, …]`，**空 = leaf**（除协调者外每个 persona 的默认）。非空时那一场才额外带 `--with agent@<自身版本> --pin ext:agent/agent`——**一个字段、一处读取**，于是"不能委派的子场"干脆没有这个 tool，没有"事后再拒绝"这回事。tool 侧的校验从**本场冻结 header 里的 `agent-<name>` 成员**反查定义（header 是冻的，说的是这一场实际 composed 成什么，不是定义文件今天说什么），名字不在单里就报错并列出允许的。
21. **深度兜底防的是间接环，不是攻击**：白名单看不见 `a→b→a`，所以 runner 给它驱动的那一步设 `NULYA_AGENT_DEPTH=<n+1>`（非 secret 形状，过得了净化），tool 读到 ≥3 拒绝。**人从前端驱动子场时这个变量根本不在**——写明了：它和白名单都是 policy，与审批表同类，真隔离等 sandbox。
22. **`orchestrator` 补上了**（前一期跳过它，理由是"它的意义就是 fan-out 而我们是 leaf"——白名单一到位那个理由就没了）。移植纪律同前三个：`agents: [explore, plan, general]`、`max_exchanges: 4`、**不给 pins**（委派是它的全部工作，正文也这么说）；tcode 的 `tools: []` / `gatesOutput` / `disallowedAgents` 我们没有，删掉；"用 `resume` 把纠正送回子 agent 完整的上下文"那句**留着并改写成我们的形态**——第 18 条刚好把它变成真的。

**测试**：`zig build test` 450 pass（`defs.zig` 多两条：白名单 / exchange 预算的三种写法与坏条目，session id 形状；builtin 那条改成"恰好一个协调者，且它只点名本包有的 persona"）。`zig build e2e` 71 pass（多两条：**追问全环**——委派 → 读报告 → `agent{session,task}` → 第二份 `task_finished`，断言子场两条 `user_text`、`session list` 行数不变（没有新场）、超 `max_exchanges` 拒绝、还在跑时拒绝（`loop` 档）、neither/both/非委派场三种参数错；**白名单与深度**——协调者的场 `native_tools` 有 `ext:agent/agent` 而叶子的场没有、名字不在单里报错并列名、叶子场一律拒绝、`NULYA_AGENT_DEPTH=3` 拒绝）。`cd tui && bun test` 269 pass、`tsc` 干净。

### T33 · tools pane 的每一行都该是一个能按的开关（2026-08-20）

`/ext` 的 tools pane 上，六个 driver tool（`agent` 一家四个 + `compact` + `handoff`）与五个可 pin 的 `std` tool 并列，**并且按 id 字母序排在前面**。于是这张表的第一屏答的不是它自己的问题（哪些在模型脸上、还能加几个），而是"这里有一堆你按不动的东西"。

**判据不是"driver tool 该不该显示"，是"这张表的行意味着什么"。** T24 当初把它们列出来的理由（"一个存在却哪儿都画不出来的 tool，正是 `compact` 变成谜的方式"）今天只对了一半：extensions pane 的详情行早就在说 `its N tool(s) stay off the model face · /compact and drivers call them with ext run`（T22/T24），所以它们并不是"哪儿都画不出来"。而**可 pin 的那一半有 `registry.max_tools` 封顶，driver 那一半没有封顶**——每加一个自带包（T32 一次加四个）就往这张表顶上多堆一行，噪音是往错误方向增长的。

所以：**折叠，不是隐藏**。列表里只留有 checkbox 的行，底下一行常驻 `▸ N driver tools · called with ext run, never on the model face · d shows`，`d` 或点它展开/收起。

- **三个纯函数**（`bun test` 钉住，不碰渲染）：`foldedRows` / `shownRows(rows, expanded)` / `foldLine(count, expanded)`。折叠的判据是 `driver && state === "off"`——**一个 driver tool 若真被 pin 上了，它照常显示**：那是这张表能改的一个状态（`Space` 撤回），而列表里唯一那个错的 checkbox 是最不该藏的东西。
- **展开状态不进 `tui-state.json`**：它是一次"还装了些什么"的好奇，不是一条关于这个前端该长什么样的设定。
- **光标跟着行走，不是跟着序号走**：展开/收起时按 id 重新定位，否则六行从光标底下抽走，选中项会漂到别处。
- **折叠行在列表下面而不是在列表里**：它没有 checkbox 也不吃光标——"光标能走上去却按不动"正是这次要拆掉的那个形状。
- **空列表的两种理由分开说**：一个 tool 都没有 → 照旧教怎么 build；只有 driver tool → `nothing on the model face · every active extension here declares driver tools only`（那些包是 active 的，让人去 build 是假话）。
- `d` 只在 tools pane 且真有东西可折时才响应——在别处按下去没反应的键，比没绑定的键更糟。

**测试**：`bun test` 271 pass、`tsc` 干净。新增 `pins.test.ts` 一条（折叠/展开/计数/被 pin 的 driver 行仍在）与 `overlays.test.tsx` 一条真渲染（store 里放一个真的 `compact` 脚本包：折起来时它不在帧里、`d` 之后在、再 `d` 又不在）。

### T34 · 一个 tool 是给谁的，只有它的包知道（2026-08-20）

前端里有四张名单在替包回答"这个 tool 是给模型的还是给 driver 的"——而这个问题**只有包自己知道**。这一轮把它换成内核 manifest 的一个字段，然后把四张名单全删掉。**内核动了一处**（`contributes.tools[].audience`，DESIGN §7.2.1），是 PLAN §4 早就定好形状的那一条。

**内核侧（第二个"包自己说"的字段，不长新机制）**：`manifest.ToolSpec.audience: ?[]const u8` + `Audience{model, driver}` + `audienceOf()`，与 `readonly?` 逐条同纪律——**解析、冻结、不强制**。kernel 不据此过滤工具面、不影响 pin 解析：**pin 一个 driver tool 依然合法**，只是没有 driver 会默认这么写。错误的分法跟着 `timeout_ms`：类型不对（`true`）是 parse 的 `WrongType`，认不出的词（`"drivers"`）是 validate 的 **`InvalidAudience`**——退回缺省的后果正是这个字段要防的那件事。**缺省是 null 不是 `"model"`**：把沉默读成 model 是**读的人**的选择，做在用它的地方（`files.modelTools`），不做在内核里。自带包只标了该标的：`compact` 的唯一 tool、`agent` 的 `materialize`/`run`/`list`——**`agent` 那个 tool 不标**，它正是给模型的委派入口。

**四张名单变成了什么**：

| 原来 | 现在 |
|---|---|
| `bundled_driver_only = ["agent","compact","evolution","handoff"]` | **删除**。判据是每个 tool 自己的 `audience` |
| `pinsOnActivate(id)`（per 包的布尔） | `pinsOf(contributions)`（per tool 派生：model-audience 的才给 pin）。`agent` 因此一个包两个答案 |
| `bundled_active = ["std","guide"]` | **删除**。开屏 sync 的 auto-activate 只剩通则 `autoActivatable(prompts)` |
| 字面量 `std_pins` 六个 | 从 std **当前冻结版本**的 manifest 派生；字面量降级为冷启动 fallback + `edit` 那次一次性迁移的历史依据（那条迁移一个字没动） |

**`autoActivatable` 少了一半，这是收益不是退让。** 它原来两条：按名字拒四个 bundled id，以及按通则拒任何 contribute 了 system prompt 的包。第一条删掉后 `compact` / `handoff` / `agent` 会被开屏后台 sync 激活——**这是预期行为**：activate 只是 membership，pin 那一半由 audience 挡住，而它们都不 contribute system prompt，所以没有 T31 那种"每场 session 都被戴上一个模式"的风险。`evolution` 仍被挡，靠的是那条**本来就是真正理由**的通则。

**`[extensions] handoff` / `agent` 两个布尔 → 一个列表键 `session_with`**（默认 `["handoff", "agent"]`）。"要带哪些包"是列表形状的问题，不该每加一个就多一个键 + `App.tsx` 里多一个分支。老键照读（`withPackage`：读到 `handoff = false` 就把它从列表里去掉，读在列表之后所以是更近的那句话），**只读不重写文件**——与 `normalizeMode` 认老 `auto` 同一先例。`App.tsx` 的 `handoffExtras` / `sessionExtras` 两段手写分支塌缩成对这个列表的一个循环（`extensions.sessionMember`：自带 draft 就 build（内容寻址故幂等），否则取 store `current`；一个包解析不出来只 notice 一句、session 照开）；`handoffBuild` / `agentBuild` 两个 `let` 合成一张 `memberBuilds` map，于是 `/agent` 与 composition 走同一次 build 而不是各建一次。`handoff_pin` / `buildHandoff` / `handoff_id` 随之删除（`agent_pin` 留着——委派路径在用）。

**`render/registry.ts` 的 `view.tool === "agent"` 保持现状并写明了原因**：到这里的是 `ledger.ToolCall.tool`，内核记的是**模型面的名字**，包名在 session header 里而不在这次调用里（`App.tsx` 的 `toolId` 是唯一把两者接起来的地方，它要那个 tab 的冻结 composition）。为一个 glyph 把冻结 composition 穿过整条 transcript 管道不值得；不做的代价是"另一个也叫 `agent` 的第三方 tool 会画成子场卡"——**画错一张图，不是做错一件事**。

**测试**：`zig build test` 通过（`manifest.zig` 新增一条：三种声明 + 沉默 ≠ model + `InvalidAudience` + 类型错是 `WrongType`；`cli/ext.zig` 那条"每个 manifest 错都是 draft fault"补上新错误名）。`zig build e2e` 通过（新增一条：script 包声明三种 audience → build → **冻结 manifest 逐个读得回、沉默仍是沉默** → 证明内核不据此改变行为（pin 一个 driver tool 的 session 照样组装得出来）→ 认不出的词被 `ext build` 点名拒绝且**一个版本目录都没建**）。`cd tui && bun test` 277 pass、`tsc` 干净（新增：`pinsOf` 的四种包形状含一个仓库外的 id、std pin 从 manifest 派生且 fallback 仍在、`session_with` 新旧键三种写法、`withPackage`；改写：`overlays.test.tsx` 的折叠真渲染换成一个**这个前端从没听说过的** `patrol` 包——它成为 driver tool 靠的是自己 manifest 里那句话；`pins.test.ts` 的折叠计数从 5 变 4，因为 `ext:agent/agent` 现在正确地留在可 pin 那一半；`delegate.test.tsx` 多断言顶层场的 `native_tools` 里**只有** `ext:agent/agent`）。

### T35 · 输入框下面那一行：把恒定的东西去掉，把新闻抬起来（2026-08-20）

用出来的四条抱怨都指着同一行：mode 在最右（一行愿意先丢掉的东西所在的位置），`no usage yet` 占着十二列说"什么都没有"，`driver` 在每个人的每一场里都一模一样，而 `Ctrl+C again to quit` 被挤进最后几列**并且留在那儿**——那个 offer 三秒就过期了，字还挂着。**内核零改动**，全部在 `tui/src/ui/{StatusBar,App}.tsx`。

**① mode 移到行首。** 它是屏幕上每个 tool call 被裁决的立场，该在 model 之前读到，而不是排在 cost 与一堆 chip 后面。分隔的 ` · ` 留在可点的 box 外面，所以那个 chip 仍然精确地是那一个词（`/mode` picker 的鼠标半边不变，§5.7）。

**② 没有的东西不占列。** 一场还没花过钱 → 整格不写（`usage()` 返回 `null`）；没跑过步 → 不写 `step 0`；是写者 → 不写 `driver`（**只有例外说自己**：`observer · driven elsewhere` 照旧，warn 色）。顺带发现一件事：空的 `<text>` 仍然占一列，两个挨着就是 `tools 1+0  · idle` 那个多出来的空格——所以每个可能为空的段都用 `<Show>` 包住，**不渲染**而不是渲染空串。

**③ notice 盖住整行，然后自己下去。** 它不再是这一行里再多一段去抢剩下的列：有 notice 就整行是它（`fg`，`fit` 到宽度），静息态原样让位。停留时间按长度算——`App.noticeHold(text) = clamp(1500 + 45×字数, 3000, 9000)`：`opened s-a1b2` 与三句话的 sync 汇总本来就不该停一样久，而一个固定数在两头都错。**下限 3000 就是 `Ctrl+C again to quit` 落的地方，也正是那个 offer 有效的窗口**——不是巧合：arm 到期的那个 `setTimeout` 里，同一处把这句话取下来（`untrack(notice)` 拿到当时说的那条，只有它还在才清，否则期间换过的新闻会被误删）。两个例外用 **`holdNotice`** 声明——browse 模式的键位提示、等着回答的 handoff 提议——它们不是新闻而是屏幕**正处在**的状态，各自的代码路径负责清；其余五十来个 `setNotice` 调用点一个字没改。

**测试**：`bun test` 277 pass、`tsc` 干净（内核未动，`zig build` 侧无改动）。改动四处断言，全是因为"notice 盖住整行"这件事本身：`layout.test.tsx` 不再找 `driver` 一词（改成"那一行不是空的"）；`model.test.tsx` 的 `/effort`、`views.test.tsx` 的 `/as`、`delegate.test.tsx` 的 `/agent` 从"做完立刻读那一行"改成 `until(statusLine(...))` **等 notice 自己下去**——这正是新行为的钉子。`support.ts` 多一个 `statusLine(setup)`（帧的倒数第二行）：对状态栏的断言必须是对状态栏的，顶上那张 composition 卡也写着 model。（`observer` / `tasks` 两个 lease 测试在机器同时跑别的东西时会 120 s 超时，单跑 5 s 通过——老毛病，与本轮无关。）

### T36 · `/as` 改叫 `/with`：一个概念一个词（2026-08-20）

它跑的一直是 `session new --with <id>[@<version>]`，一个 flag、一个 id、不 activate 任何东西。名字却换过两次，两次都比那个 flag 说得少：`/mode` 与权限档撞名（T24 拿走了那个词），`/as` 则把一个**通用**动词读成了特例——`--with` 的语义是**成员关系**，而一个成员可能只贡献 tools 或只贡献 skills（`extensions/agent` 的 `--with agent-<name>@<v>` 正是这么用的），那种时候没有哪一场在"以谁的身份"说话。这个前端的其它命令（`/outcome` `/compact` `/cancel`）都直接借内核的词，这一个没有理由例外。

**改动**：`commands.ts` 的表项 → `/with`；`App.runCommand` 认 `/with` **并保留 `/as` 作 alias**（一行的代价，换掉的是"手指记着 `/as` 的人打出去会先落进 skill catalog、再原样发给模型"）；`extensions.promptConsequence` 与 `/ext` 详情面那句里的 `/as <id>` → `/with <id>`（`evolution` 那一支仍指 `/evolve`，它多做一步 build）。`/help` 的表项多一句 `(/as is the old name)`，仍是两行。

**没有改的**：`--with` 可重复而 `/with` 仍只吃一个 id——多成员是下一件事，与改名分开做。`/evolve` 也还在，它与 `/with evolution` 的差别不是名字而是**多一步 `ext build`**，所以现在还不是 alias（见下一条待办：`/with <id>` 在没有 `current` 时自建，那之后 `/evolve` 才塌得进来）。

**测试**：`bun test` 277 pass；`/help` 快照与四处断言随文本更新，行为断言（`views.test.tsx` 那条 wearing 的 e2e）只改了打进去的那个词。

### T37 · activate 是登记还是全局，由包自己说（2026-08-20）

用出来的抱怨只有一句："`evolution` 我没启用，为什么有 `/evolve` 这个命令？"——站在用户那边，**没 activate 的东西就该完全不存在**，而 activate 应该是"这个入口现在有了"。今天的内核不是这样：activate 一个包，它的 system prompt 就进这台机器上此后的每一场 session（DESIGN §7.5），于是一个 mode 包**只能**永远不 activate，靠一个写死 id 的 `/evolve` 绕过去——命令与开关说的是两件不相干的事。

先提的方案是给 system prompt 补一根与 tools 的 pin 对称的轴（成员关系 ≠ 投影，按机器配一份"要戴谁"）。**被否决了**，理由是用户提的那条更硬：一个包的 tool 常常是**按它自己的 prompt 在场**写的，按机器把两半拆开会造出作者从没跑过的组合，组合数随包数爆炸；而 pin 那根轴是被 `max_tools` 这个硬约束逼出来的，prompt 这边没有对应的悬崖。落地的是**整包**的一个 bit。

**内核（`activation`，DESIGN §7.2.1）**：manifest 顶层可选枚举 `"always"`（缺省）/ `"on_request"`，与 `permissions` 同级但**是内核唯一强制的 manifest 字段**——`composition.resolveActiveExtensions` 里一处过滤：`on_request` 的成员不进 discovery，随后 `unionWith` 从**同一个 `current`** 把它带进点名它的那一场（`--with <id>` 一个字没改）。`ext list` 因此多一列 `on-request`（对它来说 `active` 的意思是"登记了"），`ext activate --user` 在 session 里那句警告只对 `always` 说。缺省的读法定在 `manifest.zig` 一处（这是关于**文件格式**的事实而不是判断：这个字段之前写的每一份 manifest 都是全局生效），认不出的词是 `InvalidActivation` 而不是退回缺省。`extensions/evolution` 的 manifest 加了这一行。

**TUI**：`Contributions` / `ExtensionEntry` 各多一个 `activation`（读自冻结 manifest）。① `autoActivatable` 的判据从"贡献 prompt 就不自动激活"变成"**reach 到每一场**才不自动激活"——于是**自带的 `evolution` 现在会被开屏那趟 sync 装上并 activate**，而那一下什么 session 都没改变，它只是让 `/with evolution` 这条路出现。② `/ext` 的 mode 列分 `mode` / `opt-in` 两个词、两种颜色，Enter 的 notice 分两句（`registered · no session changed` vs `EVERY new session on this machine`），开屏那句 active-mode 警告**不再点名 `on_request` 的包**（对它警告只会教人忽略那一行）。③ 裸 `/with` 开一个 picker（`WithPicker.tsx`，与 `/mode` `/agent` 同一套对话框、同一套键盘归属），**列的是登记了的 `on_request` 包**——没 activate 就不在里面，正是那句抱怨要的；`always` 的包也不列（它已经在每一场里，戴它是个 no-op）。④ **`/evolve` 从命令表里撤了**（与 `/as` 一样仍然认，只是不再被列出）：一个列在表里的命令是这个前端在说"它存在"，而 `/evolve` 点名了一个这台机器上可能根本没有的包——那就是这一条要修的困惑本身。

**测试**：`zig build test` 453 pass（`manifest.zig` 与 `composition.zig` 各加一条：一个包声明何时加入 / 一个 `on_request` 包 activate 之后不进普通场、被点名才进、deactivate 之后裸名字解析不出而点名版本照样戴）；`bun test` 274 pass（`/help` 快照、`autoActivatable`、`promptConsequence`、`activePromptPackages` 随之更新）。

### T38 · 正在发生什么，是一行自己的事（2026-08-20）

四条抱怨仍指着输入框下面那一行：`Esc cancel · Ctrl+O fold` 那种键位提示该像 tcode 那样做成 tip · `Ctrl+O` 是很"终端"的快捷键、而且一下全展开特别混乱、感觉没必要 · `/help` 摆在那儿没意义 · `idle` 也没用，模型在跑的时候该像 tcode 那样在 composer 上方给一个**有颜色、有动画、有高光扫过**的状态。**内核零改动**。

**① `WorkingStatus`：输入框上面的那一行（§4.4b）。** 分工是"这一场是什么"vs"此刻在发生什么"——两个问题被读的频率差一个数量级，之前挤在同一行里，活的那个拿到了屏幕上最少的列和最低的对比度，还逼着那一行常年留一格给 `idle`。现在：**静息态根本不画这一行**，在跑时它自己一行，`⠋ shell` + `dim` 的 ` · 12s · esc to cancel`（这句 offer 只落在 `cancelable` 的那一格——本 tab 正在 drive 的 step；`2 background` 与 observer 排队的 append 只有钟，Esc 在它们上面进的是 browse 模式）。判据是纯函数 **`activityOf`**（一处定义、可单测）；`following` 与 `canceled` 一并删掉——前者是这个 tab 的身份（下面那一行右边写着），后者 transcript 里有卡片。

**② 高光扫过**（`theme.shimmerColor`，逐条移植自 tcode `theme::shimmer_color`：`speed 1.5 / sigma 4 / dwell 12` 的高斯带）。它**抬起每格自己的颜色**朝 `theme.lift` 而不是覆盖，所以静止时每格精确等于 base、运行中绿的还是绿的。新增 token **`theme.lift`**：深色主题朝亮、浅色主题朝墨、`NO_COLOR` 就是 `fg`——"更亮"不是颜色自带的方向，只有主题说得出自己那一端在哪。两个实现细节值得记：**`<span fg>` 在 @opentui/solid 0.5.3 里不生效**（prop 被丢掉，`captureSpans` 实测整段一个颜色），所以一格一个 `<text>`；用 `Index` 不用 `For`（位置固定、字符在变）。`motion = false` 关掉 spinner 与扫带，文字一字不变。

**③ 时钟**：`Driver.startedAt`（离开 idle 打点、回 idle 清掉，`setStatus` 一处维护所以钟不会和它标的状态脱节；observer 用自己排队的时刻），经 `Attachment` 上来。渲染里**不读墙上时钟**——那样它就不是自己输入的函数了；`clockNow()` 跟着动画那一拍重采样。

**④ 折叠只剩两种手势**：鼠标点头行、browse 模式。`ctrl+o` / `ctrl+shift+o` 两个 `Action` 从 `keymap.ts` 删除（`fold` / `foldAll` 连同 `allOpen` 那个信号）。理由不是"键盘不该能折叠"——browse 模式就是键盘那一半，且它**说得出自己作用在谁身上**；`ctrl+o` 作用于"碰巧是最后一张"的卡，`ctrl+shift+o` 一次展开屏幕上每一张卡的正文。反方向的 `/fold`（全部折起）留着：读开几张之后想要的正是它。

**⑤ tip 上开屏，`/help` 下状态栏。** `Welcome` 多一条 `✻ tip: …`（`Welcome.tips` 十一条，每条都必须描述**今天真实的**行为；`pickTip()` 在 `App` 里调一次，渲染中重挑会让这一行在眼皮底下跳）。新 glyph **`✻`**（ascii `*`）而不是复用 `⚡`：一个记号一个意思，`⚡` 是"某个 extension 得到了能力"。状态栏那个可点的 `/help` box 一并删除——开屏 `/help` 那一行本来就是同一个按钮。

**测试**：`bun test` 276 pass、`tsc` 干净、内核未动。改动六处断言：`render.test.tsx` 的 `Ctrl+O expands…` 重写成**点头行展开、再点折起**（那才是现在的手势）· `views.test.tsx` 的 `/help` 快照（少两行、多两行）与两条布局断言改用 `redraw` 那一行当基准 · `[keys]` 覆盖端到端改成重绑 `help`（`f1` 不再开、`ctrl+b` 开）· `mouse.test.tsx` 断言那一行**不含** `Ctrl+O` / `/help`，`/help` 的点击目标改成开屏那一行。（跑全量时 `driver` / `observer` / `agents` 三个文件会 120 s 超时——查出来是**上一轮跑漏下来的两个 bun 进程**在占机器，杀掉后 276/276、151 s。）

### T39 · goals/tui-plugin.md U2：声明层三样东西真的接进了前端（2026-08-21）

U1（内核）在 4bfdba5 已落地——manifest 的 `contributes.commands/policy/ui`（当时叫 `tui`，ext-review 一轮改名）与 `ToolSpec.ui.render/panel`（当时是顶层的 `ToolSpec.render/panel`）都已冻结可读。U2 把这三样接进 TUI，**内核零改动**：commands 插进 slash 链、policy 插进天花板与审批表、render/panel 插进卡片与一条新的 widget。

**① commands：`packageCommands.ts`（新）+ `extensions.packageCommands`（新）。** 数据源是 `nulya ext list` 自己的扫描顺序（不是 `listExtensions()` 那份为显示重排过字母序的投影），过滤 `current !== null && !shadowed`，workspace root 的条目额外过 `storeTrusted` 这道门——"activated 且 trusted"照字面实现，与 session 是否真的 `--with` 了它无关：`with`（这一层日志写下时还叫 `wear`，ext-review 一轮改名）命令的整个意义就是把一个还没进这场 composition 的包带进来，它必须在会话存在之前就能被发现。分发插一层——`ui/App.tsx` 的 `submit` 现在是**内建（`runCommand`，同步）→ 包命令（`runPackageCommand`，异步，插进 `sendTurn` 开头）→ skill（`skillTurn`）→ 原样发模型**，三个动词各接现成路径：`with` = `startDraft(undefined, false, {id})`（与 `/with <id>` 完全同一条代码）、`run <tool>` = `activeVersionOf` 现读 `current` 再 `extRun(ws, `${id}@${version}`, tool, runArgs(args))`（`runArgs`：`ext run` 自己的 CLI 要求末尾 JSON 必须是对象——空文本给 `{}`，打出来的字面 JSON 对象原样转发，自由文本包成 `{text: ...}`，这是**唯一**对形状做的解释，写在 `packageCommands.ts` 的注释里）、`skill <ref>` = 把 `<ref>` 当作 T15 `skillTurn`会认的那个 skill 名字直接复用（`skillTurn(ws, skills.entries(), \`/${ref} ${args}\`)`）——折叠回显示的是**skill 自己的名字**，不是命令名（`/plugin-note` 落进 ledger 是 `<user-skill name="note" ...>`，屏幕上折成 `/note`），这是"原路复用"字面意义上的推论，不是疏漏。同名规则（D8）：`commands.ts` 的内建表先过一遍（`builtin_names`，新导出），永远赢；包与包之间用 `ext list` 的扫描顺序"先到者赢"（`packageCommands.ts` `dedupe`），输的一方记进 `shadowed` 但目前**没有 UI 出口**去念出来（见下面"偏离"）。

**② policy：`approvals.ts` 新 `poolPolicy`/`withPolicy`/`CompositionPolicy`。** `poolPolicy(contributions)` 把 composition 里每个成员的 `policy.deny`/`policy.ask` 去重合并、并列出哪些成员主张了 `readonly: true`（`readonlyBy`，给 note 点名用）；`withPolicy` 把这坨并进 `tui.toml` 自己的 `deny`/`ask` 表再传给 `decide`——`decide` 函数签名一个字没动。**天花板复用 agents.ts 的 `readonlyCeiling`**（事实 #7 明确要求"两个天花板一处判断"）：给它加一个可选的 `subject` 参数（缺省仍是 `"read-only agent"`，agent 那条路一字不变），`ui/App.tsx` 的 `approve()` 在 agent 天花板之后紧接着再过一遍同一个函数，`subject` 传 `` `read-only policy of ${policy.readonlyBy.join(", ")}` ``——模型读到的 deny note 因此点名是哪个包的 policy，不是被误认成一个 agent。`compositionPolicy(asked)` 只读 `SessionTab.contributions()`：那是这场会话冻结的成员列表，`state/tabs.ts` 的 `ready` promise 保证它在第一个 step 能跑之前已经就绪，所以没有"draft 预览"要单独处理的竞态。

**③ render/panel：`render/registry.ts` 加 `RenderHint` 参数 + 两个新 `CardKind`（`checklist`/`markdown`）。** `describeTool(view, glyphs, hint?)` 的 hint 由调用方从 composition 解出（`nulya/files.ts` 新 `renderHintOf`，与 `toolReadonly` 同一个查法：遍历 `contributions`，找到声明了这个 tool 名字的成员，取它的 `toolRender[tool]`）——registry 自己不知道 `Contributions` 是什么，保持"一个 call 一个 hint"的纯函数。`checklist`：从 args 或 result 里认 `items:[{text,state}]`（先 args 后 result，因为一个 `todo{items}` 式的 tool 通常在参数里就把计划说全了），任一形状不对就静默退回普通 `ext` 卡；新组件 `ChecklistCard.tsx`，marker 是纯文本 `[ ]`/`[~]`/`[x]`（没有新 glyph，theme 的 glyph 表是 unicode/ascii 双态，为一张卡加一个只有它用的符号不值）。`markdown`：body 换成 `<markdown>` 组件渲染，新组件 `MarkdownToolCard.tsx`；两个新卡的 chip/fold/spill 逻辑与 `ExtToolCard` 完全一致，唯一的区别是 body。`ui.panel: true`（当时是顶层的 `panel: true`）：新文件 `state/panels.ts`（纯函数 `panelItemsOf`，按声明它的成员在 composition 里的顺序取每个 tool 最新一次调用）+ `ui/PanelStrip.tsx`（复用 `CardFrame`，fold key 是 `panel:<item key>`——与同一条调用在 transcript 里的卡片分开折叠，两者是同一件事的两个视图不是一张卡出现两次），位置在 `WorkingStatus` 与 `Composer` 之间；v1 按包声明顺序竖排、超两行折成一行 `+N more panel(s) · /ext`（U2 §5 开放问题 3 的"v1"就是这个答案，本轮定下）。`checklistMarker`/`checklistChip` 抽成 `registry.ts` 的两个小导出，`ChecklistCard` 与 `PanelStrip` 共用同一份"[x] 3/5"的写法。

**偏离，都不改方向，只是范围裁剪**：
- **同名 shadow 没有 UI 告警**：`packageCommands.dedupe` 已经把输家记下来（`shadowed: {row, heldBy}[]`），但 `ui/App.tsx` 目前只用它的 `winners` 一半，没有地方把 `shadowed` 念出来（没有一屏适合放这句话——`/ext` 是关于包不是关于命令）。留给下一次真的撞见两个包争一个名字时再决定长在哪儿；`resolve()` 已经把两半都算好，接一条通知只是一行代码。
- **"draft 用计划中的 --with ∪ activated 集合预览"没有单独实现**：gate 只在真实 `SessionTab` 上触发（draft 没有 session 可 step），而一场刚 materialize 的会话的 `contributions()` 在它第一个 step 能跑之前已经保证就绪（②里说的那条 `ready` promise）——所以没有一个 gate 可观察的时刻会让"预览"和"真实"说两样话。`poolPolicy` 仍是纯函数、可以接任何手工拼出的 `Contributions[]`，将来要给草稿加一条政策预览行，直接调它即可。
- **unknown render 词没有走 `console.debug`**：翻了一遍 `tui/src` 没有任何 `console.*` 运行时日志（OpenTUI 占着终端，写 stdout/stderr 有画面被打乱的风险，这大概是这里从来没长出日志机制的原因）。"debug 一句"落地成了 `registry.ts` fallback 分支的一句解释性注释——与文件里既有的 `// Fall through.` 同一个先例，没有为这一件事单开一条新的日志通道。

**测试**：`bun test` 327 pass（35 个文件，180 s；`test/files.test.ts` 单独重跑时撞见过一次 lease 探针在整套跑完后的高负载下超时，隔离重跑即过，是 `project-nulya-tui-test-gotchas.md` 记过的已知类别，与本次改动无关），`bunx tsc --noEmit` 干净。新增 `test/packageCommands.test.ts`（纯：`parseAction`/`runArgs`/`withoutBuiltins`/`dedupe`/`resolve`/`packageCompletions`）、`test/panels.test.ts`（纯：`panelItemsOf` 的顺序/去重/"还没调用过不占行"）、`test/plugin.test.tsx`（真二进制：一个 PowerShell 脚本扩展 `plugin` 声明三个动词各一条命令 + 一个 tool + 一个 skill，跑通 wear/run/skill 三条路；一个零 tool 的纯 `policy` 扩展 `guard`，`--with` 进一场 `unsafe` 会话证明它的 `readonly: true` 在 gate 上先于一切表拒掉 `shell` 且 note 点名 `guard`；第三条钉住一个包声明 `/model` 也抢不走内建）、`test/registry.test.ts` 追加 checklist/markdown/unknown-render 六条单测、`test/approvals.test.ts` 追加 `poolPolicy`/`withPolicy` 六条（含"pool 出的 deny 真的让 `decide` 拒掉"）、`test/render.test.tsx` 追加 checklist/markdown 卡片快照与 panel strip 两条快照（`Harness`/`frameOf` 新增 `contributions` 透传）。

### T40 · goals/tui-plugin.md U3：一个包可以带一段前端代码进来（2026-08-21）

U2（T39）让一个包用 JSON 说出它的前端面。U3 是另一半：`contributes.ui = {entry, api}`（当时叫 `tui`）指着包里的一个 TS 模块，TUI 过 trust 门后把它 `import` 进本进程，交给它一个**窄的、版本化的、行渲染的**宿主 API。**内核零改动**——U1（4bfdba5）已经把 entry 的字节随版本冻结了，kernel 从不加载它。

**① 先验的那件事（契约 fact #13）：`bun build --compile` 产物里 `await import(<盘上绝对路径的 .ts>)` 行不行。** 答案是**行**，所以**没有 `Bun.Transpiler` 回退路径，dev 与 compiled 走同一个 `import()`**——一份加载器两种产物说两样话本来就是要修的 bug，最好的防法是只有一条路。实测覆盖：Windows 反斜杠绝对路径 / `file://` URL / 从别处 cwd 运行 / 插件模块 `import` 它自己的兄弟文件 / `.tsx` 入口 / 语法错与 top-level throw 都是可 catch 的 reject。两条边界也量到了：插件里的 bare specifier 按**插件自己的目录**解析（宿主的 `@opentui/*`、`solid-js` 一个都够不着——正是 D9 想要的），而 `import type { PluginApi } from "nulya-tui/plugin-api"` **照样能跑**，因为 Bun 永远擦掉纯类型导入，那个 specifier 在装插件的机器上根本不需要解析得出来。

**② 一个 bug，是这次实测捞出来的**：Bun 1.3.5 上，一个**首次 import 因为解析失败**的模块，**第二次 `import()` 永不 settle**（不是再抛一次，是挂住）。所以「失败过的 entry 绝不再碰」不是省事，是正确性：`host.ts` 里 `import_failures: Map<entry, message>` 是**模块级**的（module registry 本来就是进程的，一个进程里第二个 host 也不许再伸手），每个 host 另有一份 `attempted: Set<id@version>` 保证同一趟不重复告警。第二个 host 照样报得出那句失败——记的是消息不是"跳过"。

**③ 契约在 `tui/plugin-api.d.ts`，是唯一一份。** `tsconfig` 加了 `paths: {"nulya-tui/plugin-api": ["./plugin-api.d.ts"]}` 并把它收进 `include`，所以**插件作者与宿主实现读同一个文件**——`src/` 里再写一份类型就是同一个问题的两个答案（T32 的教训）。顶部写死版本策略：`contributes.ui.api`（当时是 `contributes.tui.api`）是**主版本**，等于本 build 实现的那个数才加载，否则一行 warn + 跳过（D10）；同主版本内这份文件只增不减；破坏性改动换主版本号，而包的声明是冻结的，所以那时两个数都还认得。**渲染契约是行不是组件**（D9）：`render(width) -> Line[]`，`Line = Span[]`，`Span = {text, token?}`，token 是**按文本"是什么"命名**的（`fg/muted/dim/faint/accent.*/ok/err/warn`），宿主映射到当前主题——`NO_COLOR` 因此白拿（每个 token 塌成 `fg`，插件的字一个不变），浅色主题也白拿。宿主保留每一个插件不该做的决定：CardFrame、折叠、焦点、宽度、位置、token→颜色。**不暴露 OpenTUI/Solid**：没有单实例问题、没有版本 skew，插件的 renderer 是纯函数，测试不需要终端。

**④ 加载条件**：`tui.toml` `[extensions] plugins`（缺省 `true`）是总开关，`false` = 只剩声明层、行为与 T39 结束时逐字节相同；单个包关掉就是 `/ext` 的 Enter（加载集合本来就是「trusted 且已激活」∪「本进程某个 tab 正戴着的冻结成员」，不另设第二张名单）。**默认 `true` 的理由是 D4**：extension 的代码在 `ext run` 那一刻就已经在这台机器上跑了，trust 门（DESIGN §9）就是那个决定的边界，这里不设第二道。worn 那一半不需要额外 trust——workspace store 没被信任时内核根本不让 `session new`，所以「有一场 session」本身就蕴含它被信过。**加载是单向的**：一个模块跑过就是跑过，JS 没有 unload；deactivate 一个包，它的界面留到下次启动（`/ext` 对 mode 包说的也是同一句话）。

**⑤ 新风险只有一个，是 UI 欺骗（D4），所以宿主独占每一处「说了算」的表面**：审批对话框 / mode picker / `/provider` 的 key 输入在场时（`App.dialogUp`），插件 panel **既不画也不接键**——`open()` 不失败也不报错，它**排队**，zone 一消失就出现（`panel()` 每次现问 zone，所以不需要计时器，插件侧也没有可以探测或绕开的失败）。panel 上面永远有一行宿主画的 `◈ <pkg> · this panel is an extension's`，下面永远有一行宿主画的 `Esc close`——而 `Esc` 是宿主兜的：插件 `onKey` 返回 false 时宿主自己收起，所以「进得去出不来的面板」不存在。`Ctrl+C` 根本到不了插件（`handleKey` 头一行就拒）。`registerCard(tool)` **只许本包 tool，违者当场抛**（D11），抛了就整个 activate 回滚——半激活的插件不是插件。`registerCommand` 撞内建名是 warn + 忽略（D8，一个内建永远不会被夺走）。

**⑥ 写路径就是人已有的动词（D5），一个不多**：`appendNote(kind, text)` = `session append`，包一层新 sentinel `<ext-note pkg="…" kind="…">`（`extnote.ts`，形状与 `approvalnote.ts` 逐条对齐：属性而非正文行、最后一个 close 作数、parse 只认 sentinel 不认 contract 措辞），transcript 按它折回原话并把 `pkg · kind` 做成 badge——`pkg` 由**宿主**填，插件冒名不了；`extRun(tool, args)` 只放行本包 tool；`openTab` / `wearNext` 是 `/sessions` 与 `/with` 的同一条路。**没有答 gate、没有写 session 文件、没有第二份真相**。`observe` 全是只读：`onStream`/`onEvent` 从 `DriverOptions.onLine`（新，driver.ts 在 `state.applyStream/applyEvent` **之后**调，throw 被吞——插件不许因为读错一行就停掉一个 step；attach.ts 的 follower 也接了，所以 observer tab 不是黑屏）、`tasks()`/`session()` 是现成投影。`state.get/set` 落 `tui-state.json` 的 `plugins: {"<pkg>": {…}}` 槽，读改写，一个坏槽带不走 model pick。

**⑦ 三种表面各归各位**：card 走 `render/cards/PluginToolCard.tsx`，在 `ToolCard` 的 `Switch` 里**排在 registry 各 kind 之前、cancel marker 之后**（同一个包发了代码就压过它自己的 `ui.render` 词——天花板盖地板；取消是「这个 call 根本没发生」，那更早）；panel 走 `ui/PluginPanel.tsx`，位置与 `ApprovalPanel`/`ModePicker` 同一区、**画在它们下面**（等答案的问题永远排在报告前面），键盘顺序是 trusted zone → overlay → 插件 panel → browse → 全局；widget 走 `ui/PluginWidgets.tsx`，`WorkingStatus` 与 `PanelStrip` 之间，**第一行是头行常驻、其余折在下面**（不需要契约再加一个"标题"字段），并且注册了 widget 的那个包自己的 `ui.panel: true` 行会从 `PanelStrip` 里消失（`state/panels.ts` 新纯函数 `withoutSuperseded`，**按包**而不是按 tool——widget 是包注册的，一个包对自己的进度显示只说一次话）。**`ApprovalPanel` / `ModePicker` 一个字没改**（契约 fact #8：抽象自它们、不重写它们），插件 panel 没有行、没有光标、没有 note 字段可以跟它们共享，硬凑一个基类只会让两边都难读。

**⑧ 高度是宿主的，宽度是插件的。** `render(width)` 不告诉 renderer 高度（契约如此），所以宿主封顶：panel 半屏、展开的 widget body 四分之一屏，超出的行**数出来**（`+N more rows · <pkg> drew more than fits here`）而不是悄悄丢。理由就是 D6 本身——composer 区面板存在的全部意义是 transcript 还看得见，一个会长到把对话挤出屏幕的面板就是我们没造的那个全屏 overlay。`.d.ts` 把这条写给了插件作者：要展示很多就自己分页/折叠，用自己的键。

**⑨ 契约里有两个 `onKey` 在 1.0 里不被调用**，`.d.ts` 逐条写明了原因而不是让人接一个永不触发的回调：card 没有自己的焦点（browse 模式拥有卡片上的键，给卡再加一个键盘持有者就是第三个焦点主），widget 是常驻行、跟输入框抢每一个键而输入框必须赢。**需要键的表面就开 panel**——那是这里唯一真的拿键盘的东西。声明留着是因为该有答案时它在这儿。

**⑩ 一个 renderer 抛异常只赔它自己那几行**：`PluginSurface`（与 `PluginWidgets` 的头行）都在 try 里调 `render`，失败画一行 `<pkg> could not draw this · <message>`。这是 D10 在渲染期的形式——插件是别人写的代码跑在一次 render pass 里，让异常漏出去就是整个屏幕没了。

**偏离与添加**（都小，理由随行）：① 契约列的 API 之外加了一个 `api.notice(text)`：一个命令做完事总得说一句，而这句话没有别的表达方式。② 契约没说 renderer 什么时候重画——插件的记忆对 Solid 不可见，所以 host 有一个 `revision` 信号，在「插件处理了一个键 / 收到一行 observe / notice / state.set / panel 开关 / 命令跑完」之后 bump，`.d.ts` 顶部把这个规则写给了插件作者。③ 声明层与代码层的同名命令：契约定「同包代码胜」，实现上是 `runPluginCommand` 整体排在 `runPackageCommand` 前面，所以跨包时也是代码胜——与 widget 压过 `ui.panel: true` 同一条「天花板盖地板」，没有再造第二套规则。④ D9 的行渲染在 U3 范围内**没有撑不住的地方**（panel / widget / card 三种都只需要「若干行带色的字 + 一个键回调」）；U4 的评审面板要做「选区跨行高亮」时，最小扩展仍是 `Span` 上加一个背景 token，**不是**暴露组件树——留给那时的第一个真实需求。

**测试**：`bun test` **344/344**（36 个文件，178 s），`bunx tsc --noEmit` 干净，`bun run compile` 仍出单文件。新增 `test/plugins.test.tsx`（16 条）+ **夹具插件 `test/fixtures/probe-plugin.ts`**——它是一个真的 `.ts`，被 `tsc` 按契约检查（这是它住在 `test/` 而不是测试文件里的字符串常量的全部理由：没人写过的契约就是没人读过的契约），测试把它**复制进一个包 draft、`ext build`、由 host 从冻结版本按绝对路径加载**，所以跑的就是一个真包会 ship 的东西。四个夹具包：`probe`（全套：widget / 本包 tool 的 card / 带键的 panel / 三条命令 / 两个 observer）、`future`（`api: 2` → 一行 warn 跳过）、`broken`（模块解析不了）、`nosy`（给别人的 tool 注册 card → activate 抛 → 回滚，它先注册的 widget 也没了）。断言分两层：加载 / 版本 skip / 坏插件不拖死前端 / 越包抛错 / 内建名抢不走 / 总开关 / 重复 load / trusted zone 排队 / `Ctrl+C` 到不了插件 / `Esc` 收起 / observe 计数 —— 问 host（有真 store、无屏幕，答案精确）；widget 上条、panel 拿键盘（`j` 进插件不进输入框）、`Esc` 交还、`appendNote` 落 ledger 且 transcript 折回并带 badge、总开关 false 时那一行不存在 —— 问一个真渲染的 `App`。`test/panels.test.ts` 追加一条 `withoutSuperseded`（本包的行让位、别人的不动、没有插件时逐字节等于 U2 的答案）。NO_COLOR 是 `tokenColor` 的纯单测（帧只有字符，颜色断言不了，而"每个 token 塌成 fg"正是那句话的准确形式）。**compiled 产物上手动验过一次真实包**：`bun build --compile` 一个只 import 生产 `host.ts` 的小 harness，指向一个用真 `nulya ext build|activate` 建出来的 `probe` 包 —— 加载、activate、三条命令、widget 的行、panel 开→`j`→`Esc`，全部正确（结果记在 goals/tui-plugin.md §6）。

### T41 · goals/tui-plugin.md U4：两个真包，把声明层和代码层一次用完（2026-08-21）

U1 给了 manifest 五个声明位，U2 把它们接进前端，U3 让一个包带一段前端代码进来。U4 是**验收物**：两个随仓库走的真包，`extensions/plan` 与 `extensions/ask`（DESIGN §7.8 的第七、第八个）。**内核零改动**；`tui/` 这边只多两处，都是这两个包逼出来的（见 ③）。

**① `extensions/plan`：一个包说完「计划模式」是什么。** compiled（照 `extensions/handoff` 的骨架：JSON-RPC 进、echo `id`、参数校验），`activation: "on_request"`，五个声明位一次用全——system prompt（这一场是干什么的）· `policy: {readonly: true}`（戴上它意味着什么权限立场）· `commands: [{name: "plan", action: "with"}]`（人怎么戴上；当时这个词还是 `wear`，ext-review 一轮改名）· `todo` 的 `ui: {render: "checklist", panel: true}`（它的 tool 怎么画；当时是顶层的 `render`/`panel`）· `ui: {entry: "tui/plan.ts", api: 1}`（它带了一段前端代码；当时叫 `tui`）。三个 tool：`propose{plan_md}` 与 `todo{items}` **什么都不写**（计划与清单在参数里，而参数已经在 ledger 里；磁盘上再写一份就是第二份真相），`approve{session, plan_md}`（`audience: "driver"`）是唯一碰盘的那个。**`propose` / `todo` 各自声明 `readonly: true`，否则这个包的 policy 会拒掉它自己的工具**——这是 D3 那条天花板的第一个真实后果，也是它对的地方：一个自称只读的 session 里，能跑的必须是自称只读的 tool，包括它自己带来的。

**② 前端模块 `tui/plan.ts`：三个表面，每一个都是声明层说不出来的。** `registerCard("propose")` 从**参数**画计划（`CardView.args` 在 `state: "pending"` 时还在长，所以是边到边画的，不需要第二条通道）；`observe.onEvent` 从 assistant 事件里读那次调用的参数——**ledger 是唯一来源**，面板只是一面透镜；`observe.onStream` 看见那个 call 的 `tool end` 就 `panel.open()`，**没人按任何键**。面板里：`j/k` 移动 · `u/d` 翻页 · `v` 起选区 · `c` 写评论（打字进面板）· `r` 把全部评论拼成**一条** `appendNote("plan-comments", …)`（引文带行号，模型下一步读到、改计划、再 `propose`——循环）· `a` 批准 · `Esc` 收起、`/plan-review` 重开。**故意不注册 widget**：包已经声明了 `todo{ui: {panel: true}}`，而代码 widget 会把那一行顶掉（T40 ⑦），两层说同一句话就是重复。

**③ 契约长了两个可选位（1.1），两个都是这两个包逼出来的，不是顺手加的。**
- **`PluginKey.text?`**：`name` 是键的**身份**（小写、`a` 与 `A` 共用、非字符键是一个词），而评论框要的是**字节**；从 `name` + `shift` 反推是在猜键盘布局（`shift+3` 在一种布局上是 `#`，在另一种上是 `£`）。OpenTUI 早就把真实字节解析进 `sequence` 了，所以规则只有一条：**一个可打印码点，且没有把按键变成命令的修饰键**（`pluginKeyOf` 的 `printableOf`）。没有它，"在面板里写字"这件事在 1.0 里是做不对的，只能装作做对。
- **`PluginActions.compact(options?)`**：approve 之后要 fork。契约原文给了两条路，**(a) 被实测否掉**——`approve` 写出 handoff 形状的文件、交给 §5.8 既有的看盘，看上去零 API 改动，但那个看盘住在 `createEffect(() => { if (status() !== "idle") return; … checkHandoff() })` 里：approve 发生时**没有 step 在跑**，`status()` 早就是 `idle`，那个 effect 追踪的东西一个都没变，于是它不会重跑。人按了 `a`，什么都不会发生，直到下一次有人把这场 session 步一步——这不是延迟，是错的。所以走 **(b)**：`compact` 就是**人已有的那个动词**（`/compact`，D5 合规），host 里接的是现成的 `runCompact`。`.d.ts` 顶部补了一段 1.0/1.1 的清单与"插件问不到 minor、也不需要问"的读法。
- 顺带把 fork 收成一处：`ui/App.tsx` 新 `forkHere(options)`（守卫 → `runCompact` → `tabs.replace` → notice → 失败时把租约拿回来），`followHandoffFile` 与插件 seam 两个调用者共用它。原来 handoff 那条路没有"正在 step 就别 fork"的守卫，现在有了。

**④ `extensions/ask`：第二个 consumer，故意几乎不值钱。** 一个 tool `ask{question, options?, free_text?}`，handoff 形状（立刻返回、不阻塞、不写盘）；面板列选项，`1`-`9` 落到某一行、`j/k` 移动、`Enter` 作答、`t` 改成自己打字，答案走 `appendNote("answer", …)` 并把原问题带上（几轮之后一句孤零零的"the ledger"不是任何东西的答案）。**没插件时问题就在那张普通 ext 卡里，人打字回答完全等价**——这正是选它当第二个 consumer 的理由：它证明代码层是**便利**，不是通道。它也验证了 panel 注册面对第二种用法（一次性问答，不是长驻评审）不需要任何新东西。

**⑤ D9 的行渲染够不够用（goals/tui-plugin.md §5 开放问题 1 的最终答案）：够——但高度那条缺口是真的。** 「选区跨行高亮」不需要 `Span.bg`——一个两列的 gutter（`>` 光标 / `|` 选中 / `*` 有评论）配上 token 的明暗，比背景色更清楚，而且与 `ui/rows.ts` 在别处的做法是同一种视觉语言。真正卡住的是 `render(width)` **不告诉 renderer 高度**（T40 ⑧ 已经记过宿主那一半）：插件只能猜一个分页大小，`plan.ts` 写死 `page_rows = 8`（8 行正文 + 自己的 3 行 chrome，塞得进 24 行终端上那个半屏封顶）。这不是设计错误，是一个**还没值得付的**扩展：最小形态仍是给 `render` 第二个参数或给 `PanelSpec` 一个高度提示，等第三个 consumer 真的因此画错了再做。
**还有一处 D12 的边界**：`ui.render: "markdown"` 画的是 tool 的**结果**（`MarkdownToolCard` 读 `item.output`），而 `propose` 的散文在**参数**里——所以它对 `propose` 没有用，声明层在这里给不出地板，代码卡是唯一的答案。词表以后要长出"画参数"的那一半时，这就是它的第一个理由。

**⑥ 装它们是一个决定，但是一个便宜的决定。**〔**T46 更正**：`ask` 的 `activation` 已改回默认的 `always`——它是能力不是模式，见下面 T46；`autoActivatable` 照样放行它，因为它不 contribute system prompt，所以这一段说的开屏行为一个字没变。〕两个包当时都 `activation: "on_request"`，所以开屏那趟后台 sync 会把它们 activate（`autoActivatable` 对 `on_request` 放行，T37）——而那一下**什么 session 都没改变**，只是让 `/plan` `/ask` `/with plan` 这几条路存在，以及让两个前端模块被加载。代价是第一次开屏多两个 `zig build-exe`（后台，T23 已经把它赶出关键路径）。

**测试**：`bun test` **348/348**（37 个文件），新增 `test/consumers.test.tsx` 四条（真二进制、真 store、真冻结版本、真 `session append` / `ext run` / fork；唯一模拟的是**模型**——没有任何离线 provider 会调 `propose` 或 `ask`，所以那两行 `tool` 流与那条 assistant 事件是直接交给 host 的，与 `session step --stream` 打出来的字节同形）：① plan 全环（propose → 面板自己开 → 评论 → `r` 落**一条**带 `pkg="plan" kind="plan-comments"` 的 sentinel user turn 且引文带行号 → 再 propose → `a` → brief 落盘 → fork 出的子场 composition 里**没有** `plan@`，而 brief 是它的第一条 turn）· ② plan 场上 gate 拒 `shell` 且 note 写 `read-only policy of plan`（真渲染的 `App`，`unsafe` 模式——所以拒绝只可能来自天花板）· ③ ask 选项作答落 ledger · ④ ask 自己打字作答（`key.text` 的钉子）。`zig build e2e` **73/73**，新增一条包级：propose / todo / ask 的成功与 `-32602` 两路 + **什么都没写进 `.nulya/handoffs`** · 戴上 plan 的场里 prompt 进了 system blocks、policy 冻在版本的 manifest 里、`tools` 是 `shell` + 唯一那个 pin（两根轴）· `approve` 写出的 brief 被 `compact --arg brief_file=` 直接吃下、子场 header 里没有 `plan`。`ext seed` 的自带扩展 6 → 8，三处计数（e2e 两处 + `test/extensions.test.ts` 一处）与 `src/bundled.zig` 的钉子同步。`bunx tsc --noEmit` 干净——`tsconfig` 的 `include` 多了 `../extensions/*/tui`，所以**这两个包的插件模块被按契约 typecheck**（与 `test/fixtures/probe-plugin.ts` 是真文件同一个理由）。

### T42 · 三处「说得不对的地方」，与自带扩展的更新通道（2026-08-21）

四件事，三件在前端，一件在壳层（内核语义仍然零改动）。它们凑成一条是因为触发它们的是同一次使用：一场跑了 20 步的 session，屏幕上有一行在说没人读的数字、一格在说一件不真的事，而那件不真的事的根源在磁盘上。

**① 流量搬到「正在发生什么」那一行（§4.4b / §4.5）。** `↑281.6k ↓12.0k cache 86%` 原来常驻输入框下面那一行。一个**会变的总数**只在它变的时候值得读——静息时它是六列没人看的算术，还把 model id（"我在跟谁说话"）挤成第一个被截断的东西。现在它是 `WorkingStatus` 尾段的第三样（`· 12s · esc to cancel · ↑… ↓… cache …%`），跑完就随整行一起消失；`/usage` 仍然是全部账，`ctx N%` 留在原处（它不是总数，是警告）。共用的短语落在 `state/session.ts` 的 `usageLabel` / `compactCount`，与 `cacheShare` 同一处。

**② mode chip 再点一下收起（§4.5）。** 点 `unsafe` 开 picker，再点一下什么都不发生——而这个屏幕上其它每一个"点开"都是可以点回去的（`openOverlay` 本来就是 `overlay.toggle`，折叠卡的头行也是）。`toggleModePicker` 一行，把 `/mode` 那条命令留在 `openModePicker`（打两次 `/mode` 不是收起的意思）。

**③ `◈ evolution` 为什么会自己出现——它不是新 bug，是磁盘上的旧账。** `~/.nulya/extensions/evolution/current` 指着一个**旧版本**：那份 manifest 早于 `activation: "on_request"`（DESIGN §7.2.1），所以在 discovery 里它仍是 `always` = 它的 identity system prompt 进这台机器上的每一场 session（`docs/BUGS.md` 第 1 条的余烬——那次修的是"以后不会再被自动打开"，没有、也不该由 harness 替人关掉已经开着的）。点它开 `/ext` 是设计（T31：这一格就是 `/ext` 的鼠标那一半）。**真正的问题是它为什么还是旧的**，那就是 ④。

**④ `nulya ext seed` 成为自带扩展的更新通道（DESIGN §7.2 / §7.8，新 `src/cli/ext_seed.zig`）。** 原来的规则是"该 root 已有 draft 的 id 一律不动"，理由正当（那可能带着别人的编辑），后果却是：**升级二进制永远不会更新已经装上的自带扩展**。于是这台机器上 `agent` 的三个 `audience: "driver"` 没生效（四个 tool 全在模型面上）、`std` 还没有 `edit`、`evolution` 还是 `always`——全都是本机 build 过一次就冻在那儿了。

判据不能是内容 hash（自演化每轮都改），也不能是问一句（这一步跑在开屏之前的后台），所以是**一条记录**：seed 每写一个 draft 就在 `<root>/<id>/.seed` 记下自己写的那棵树的 digest。四种答案——没有 → seed；与本二进制逐字节相同 → up to date（**顺手补记录**，这是老 store 唯一的补课机会）；记录仍描述盘上这棵树 → 这是 harness 自己的副本、没人动过 → **自动刷新**；记录对不上或没有记录 → 有人动过（或是记录出现之前的老 seed）→ **原样留着并点名**，`--force` 是唯一的覆盖入口。刷新过的 draft 对随后那趟 `ext sync` 就是一个普通的"变了的 draft"：build 出新版本、`--activate` 把 `current` 指过去，于是 ③ 的 `evolution` 会自己变成 `on_request` 的那一版（activate 从此只是登记，不再进任何 session）。记录**不进 package snapshot**（snapshot 由 manifest 决定），所以 version id 一位都不变。

前端只多两句 notice：`X & Y updated to this build`，以及点名它不敢碰的那些 + 那条 `--force` 命令（`App.syncStores`）。老 store 的那一次仍然需要人点头——这是对的：只有人知道那份 draft 是自己改的还是上一个二进制留下的。

**⑤ 顺带修掉一个被它暴露出来的谎：draft 屏幕上 `[extensions] session_with` 的包一个都不算数。** 状态行与 Welcome 卡的 `tools 1+N` 只数**持久 pin**（config 的 `pinned_native_tools` ∪ `tui-state.json` 的 `session_pins`），而 `handoff` / `agent` 是在 `session new` 那一刻由 `sessionExtras` 加进去的——于是开屏永远写着 `tools 1+5`、Welcome 的 tools 行里没有 `agent`，而下一条消息开出来的 session header 里**明明有四个 agent tool**。一个人看着那块屏幕，唯一合理的结论就是"agent 没启用"。修法是 `plannedPins` 认第三个来源（`composedPins`）：从 `ext list` 里读那几个 id **active 版本**的 model-facing tool（`pinsOf`），**不是**去 `sessionMember` 解析——后者会 build bundled draft，那是一趟 zig，而一个还没被要求做任何事的开屏不该起编译（T23）。pin 指的是 tool 不是版本（`ext:agent/agent`），所以两种读法只在"这台机器上根本没 active 过这个包"时才不同，而那一秒正是后台 sync 在把它变 active——少报一秒是这里该有的错法。`/ext` 那半边也一样在说谎：tools pane 给这些 tool 画的是**空 checkbox**、`agent` 那行写 `0/4 tools`——一个整块屏幕都在回答"模型能调什么"的面板，对四个模型正在调的 tool 说了"没有"。所以 `PinState` 多第五档 **`composed`**（`pins.ts`：`always` / `session` / `other` / **`composed`** / `off`，标签 `with the package`）：它不是"pin 被写在哪儿"的第四个地方，是"没有任何列表写它、它照样上脸"的那一类；`toggle` / `promote` 对它与 `other` 同一态度——**不写，点名是谁决定的**（`[extensions] session_with` 在 `tui.toml` 里），因为一个按下去会被下一场纠正的开关就是一句谎。`nextFace` 与 `plannedPins` 因此加同一个来源，一张脸只有一个数。详情面另加一行说这个包每一场都在。

**⑥ 「以后还会不会这样、而人根本看不出来」——这一条的答案在 `/ext` 里，不在 notice 里。** 自动那半边从此是自动的：seed 写下的 `.seed` 记录让下一个二进制认得出自己的副本、直接刷新。**停下来的只剩两种**——你编辑过的 draft（这是对的，不能替人覆盖）与**记录出现之前的老 store**（一次性）。这两种以前只在开屏 notice 里说一句、六秒后消失，还让人去终端敲 `nulya ext seed --user --force`——一个状态是**持久的**（它是一个目录的事实，直到有人处理它为止都为真），就不该只活在一条新闻里。所以 `/ext` 的 id 列表多一列 `differs`（第三个 dry-run，`ext seed --user --dry-run`，无编译只算 digest；它压过 sync 那一列的 `active`——"这份代码比跑它的二进制旧"才是能动手的那个事实），详情面把两种可能与代价写全（**旧源码留在它自己那个冻结版本的 `package/` 里**，所以这一步丢不掉任何 build 过的东西），**`s` 一键做完那三条命令**（`seed --force` → `build` → 原来是 active 的才 `activate`）。notice 改成指路 `/ext`。

**测试**：`zig build test` 465/465（新增两条纯函数级：seed → `current` → 编辑 → `theirs`，以及"记录描述盘上这棵树"→ `stale` → 刷新后连多出来的文件一起清掉）；`zig build e2e` 74（那条 seed 的 e2e 改写成四种答案 + `--force`）；`bun test` 全绿（`extensions.test.ts` 补了编辑→点名→`--force` 三步）。

### T43 · 一屏该说的话，和一次委派该由谁挑模型（2026-08-21）

五件事，四件在前端（内核零改动），一件在 `extensions/agent`。凑成一条是因为它们来自同一次使用：一场跑着的对话，屏幕在抖、回答被挤住、探索把回答顶出屏幕，而委派永远跑在跟主场一样贵的模型上。

**① 流式时的闪烁：那个光标是 markdown。** `AssistantTurn` 原来画的是 `content={text + (streaming && motion ? " ▍" : "")}`——光标拼进的是 **content**，所以它参与解析。于是每个 delta 都在重新解析一份多一个字形的文档，而那个字形在**块边界**上会改变答案：文本以换行结尾时它独占一行（+1），下一个 delta 又收回（−1），一个开头的 ``` 干脆把它吞进未闭合的 code block。逐 chunk 抓帧实测：三个 delta 内 7 → **6** → 7 行。而 transcript 是 sticky-bottom 的 scrollbox，每一次高度回缩都是整屏重排——那就是"疯狂闪烁"。删掉之后同一段流式输出的行数**只增不减**（同一份探针，回缩计数 0）。它本来也该走了：T38 之后"正在发生什么"是输入框上面一整行自己的事（spinner + 扫光），transcript 里不该再有会动的东西。

**② thinking 默认 `hidden`，且 hidden 意味着离开列表。** 一个折叠的 reasoning 卡仍然要花掉一个头行、一个 glyph、一个 fold 记号——**每一次回答都花，而且就花在回答正上方**。它既不是模型说的（那是 assistant 文本）也不是它做的（那是 tool 卡），是 provider 的草稿纸，留在 ledger 里为的是回放（DESIGN §3.1）；而"它正在想"这件事，输入框上面那一行本来就在说（`activityOf` 没有 tool 时就写 `thinking`）。`transcript.thinking = "collapsed"` 把卡要回来，一个字节都没丢。**实现上有个坑**：`hidden` 不能只是让卡返回 `null`——一个画不出东西的 item 仍然占着 `gapBefore` 给它的那一行空白。所以它**离开 item 列表**（`Transcript.visibleItems`），下游的空行、browse 光标、`N earlier items` 计数全都算在真正画出来的东西上。

**③ 回答与它上面那张卡之间补一行空。** `gapBefore` 原来有一条 `thinking → assistant = 0`（"thinking 与它后面那句话是同一个 beat"）。那个道理在，但屏幕上那是**两张卡贴在一起**：一个带 glyph 与 fold 记号的头行，紧接着一段 markdown，挤成一坨。"属于后面那句话"由顺序和 dim 已经说完了；空行在这一屏的语法里就是 beat 边界，而 thinking 是一个 beat。②之后这条多半用不上——但当有人把卡要回来时，它得是对的。

**④ 一串跑完的调用折成一行（`render/runs.ts` + `render/cards/RunCard.tsx`）。** 模型读十一个文件再回答，屏幕上就是十一行，把它**说的话**顶出去。现在那一串是 `⋯ read ×3 · grep ×2 · shell ▸`，展开就是原来那些卡各自照旧。三个纯函数、一份测试：`foldsIntoRun`（一次调用进不进得去）· `groupRuns`（**两个起步**——把一次调用概括成"1 call"是用一行换一行还藏掉了一条命令）· `runSummary`（按 tool 名计数，**不猜语义**：tcode 的 `Read 5 ranges` 与 Claude Code 的 `Read and edited config.py` 都要求知道每个 tool 是什么意思，而这块屏幕不知道——包给自己 tool 起的名字就是现成的最短的词）。

**进不去的比进得去的重要**，每一条都是规则不是口味：**还在跑的**（那正是唯一值得看的一行——于是效果自然就是 Claude Code 那样：跑的时候看得见，跑完了收起来）· **失败的**（成功才沉默，T26；一条静静包含着失败的摘要行是这个功能唯一比没有更糟的形态）· 被取消的（marker 就是那张卡的全部内容）· **回执型的**（后台任务、子场：它们不是做完的动作）· `edit` 的 diff · 演化动作（`nulya ext build` 这些正是 nulya 存在要让人看见的时刻，§5.2）· `checklist` / `markdown` · 包用代码画的卡。

**包怎么说"别收我"：声明 `render`。** 不加 manifest 字段（DESIGN §7.2.1 的 `contributes.tools[].render` 已经是开放词表、kernel 只解析不强制），驱动者能从中读出的正是"这个包对它这次调用长什么样有意见"——一个有画面要给的调用不该被概括。于是 `std` 想让 `write` 跳出摘要，就是给它一个 `render` 声明，不必等前端认识这个名字。`tui.toml` 的 `run_summary = false` 是人这一侧的总开关，回到一次调用一行。

**⑤ 委派卡：说出它在怎么样，并且能点进去（`SubSessionCard`）。** `agent` 的调用返回的是**回执**——别处有一个后台任务正在驱动一场 session，报告稍后才到——而它原来画的是 `EvolveCard`，一张"做完了的动作"的卡。现在：note 用**和后台 `shell` 完全同一套读法**（`state/tasks.ts` 的 `backgroundNote`，两个 consumer 了才抽）——ledger 的报告到了就用它（重开一场照样显示），没到就用 `task list` 的实时投影（`s-1/t1 · running 42s`）；头行下面多一行 **`↗ open <id> in a tab`**，点它或 browse 模式 `Enter` 走**同一个入口**（`state/navigate.ts` 的 `NavigateContext`，App 给的是它自己的 `tabs.open`）。这一步同时修好一个静默失效：`task_finished` 找"是哪张卡起的这个任务"用的是 `backgroundStartOf`，只认内核那句 `[background task X started]`，而 `agent` 的回执是自己的句子——所以委派卡从来不会变成 `done`。现在两种回执由 `startedTaskOf` 一处读。

**这推翻了 T2 的一条决策**（§9 里"SubSessionCard 不做独立组件"）：当时它与 `EvolveCard` 的差别只是 glyph 和一个 id，抽出来是无谓的。现在差别是两条实时事实 + 一个手势，第二个 consumer 到了。

**"这能不能纯在 `extensions/agent` 的 tui plugin 里做"——不能，而且不该。** 契约版本 1 的 `CardRenderer` 只返回 `Line[]`，`onKey` **明确写着不会被调用**（卡片没有自己的焦点，browse 模式持有卡片上的键），也没有点击回调；`actions.openTab` 有，但只够从一条 `/命令` 或一个 panel 触发。进度更根本：子场是**后台任务**在驱动，它的 `--stream` 根本不经过这个前端，而 `observe.onStream` / `onEvent` 给的是前端自己驱动的 step 与 front tab 的事件。要让插件做，得给 API 加"卡片激活回调"和"跨 session 观测"两样，而第一个 consumer 就是宿主自己——那正是"第二个 consumer 出现之前不抽 abstraction"要拦的事。**跳转本来就是宿主的手势**（T3 起 `Enter` 就能开），缺的只是屏幕上没有一个东西说得出这件事。

**⑥ 委派可以点名跑在什么模型上：`agent{name, task, model?}`（DESIGN §7.8）。** 原来只有定义文件的 `model:` frontmatter，不写就继承发起它的那一场——于是一次宽搜和一次严审花一样的钱，而这两件事的价值差一个数量级。形态与 frontmatter 逐字相同、**一处解析**（`defs.parseModelRef`，两个 parser 就是两套语法）；优先级由近及远：**这次调用 > 定义 > 继承**，且取的是**一对**（profile 与 id 从不同来源拼起来会点名一个那个 profile 不服务的模型）。`session` 形态给 `model` 是 `-32602` 而不是静默忽略——那一场的身份创建时就冻死了（physics #2），而 append-only 正是追问便宜的原因。解析不出当场报错并指 `nulya config show`；profile 名对不上则由内核那句拒绝原样上来，只多一句"这是你给的 `model` 参数、可以不带它重试"。

**测试**：`bun test` 新增 `test/runs.test.ts`（5 条：什么折得进去、什么折不进去的**八种**、`render` 声明与代码卡两种 opt-out、两个起步与被打断的 run、摘要文案）+ `render.test.tsx` 三条（thinking 默认不在屏幕上而 `collapsed` 把卡要回来、委派卡的实时 note 与**真的点得动**的 `↗ open`、一串调用折成一行而中间那个 `exit 1` 留在外面）；节奏那条改用 `run_summary = false` 的 style（节奏说的是空行在哪，摘要说的是有几行，两件事）。`zig build test` 466/466（`parseModelRef` 一条：只有 profile、profile/id、以及三种半截）；`zig build e2e` 73/73（那条 bundled agent 的 e2e 多两段：坏 `model` 报错并指 `config show`、追问形态给 `model` 被拒，两条都在建任何东西之前）。**一个性能回归当场被 `perf.test.tsx` 抓住**：行列表原来是普通函数，而每一行都要读它一次去找自己前面那一行 → 平方级，且每一趟都在解析每个调用的参数以判断它是哪种卡；5k 事件的第一帧因此 2.2 s。`createMemo` 之后 208 ms、流式每帧 7 ms。App 那一侧的 `cards()` **刻意不 memo**（memo 会在创建时立即求值，而 `plugins` 那时还没建好——它读在按键上，不在帧上）。

### T44 · persona 不再材料化：一段只属于一场的文本，家在那一场的 header 里（2026-08-21）

契约：`docs/goals/session-prompt.md`。内核长了一个 `session new --prompt <file>`（可重复，创建时读字节冻进 header 的 `composition.prompts`，DESIGN §3.4 / §5.6），前端与 `extensions/agent` 是它的第一个 consumer。

**推翻的是 T32 的第 2 条日志**（"system prompt 只有一条路进 session，所以材料化不是绕路，它就是那条路"）。那句话当时是真的：一段 system prompt 要被模型看见，只能由某个冻结的 extension 版本贡献。代价当时没算清——一个 sub-agent 的 persona 只对**一场** session 有意义，把它做成 extension 就是把 per-session 文本变成**安装物**：`/ext` 里长出一排 `agent-*` 派生包（污染是被藏起来而不是不存在），而 `ext prune agent-explore` 能删掉某一场赖以 resume 的身份文本——resume 与 prune 就此耦合。尺子因此立在这里：**这段文本有没有独立于某一场 session 的生命周期**。有（`evolution` / `plan` / `handoff`——装得上、activate 得了、回滚有意义）→ extension；没有（persona 正文、将来任何只发给这一场的 brief）→ `--prompt`。PLAN §3.2 那句"`--system-file` 被 `--with` 吸收了"对前者成立，对后者不成立。

**前端这一侧改了四处，都很小**：① `sessionNew` / `SessionExtras` 各多一个 `prompt` 列表；② `materializeAgent` → `renderAgent`（包那边 `materialize` → `render`：只写 `.nulya/scratch/agents/agent-<name>.md` 并回一整组 `session new` 参数，多了 `prompt` / `label`，少了 `id` / `version` / `ref`）；③ `startAgent` 不再 `bring` 一个派生包，改传 `prompt: [m.prompt]`——pins 连带的 `--with` 与 `agent` 包本身那一条**一字未动**；④ `wearing()`（tab 标题与状态栏那个 `◈`）多读一处 header 的 `composition.prompts[].source`——按同一把尺子，那也是这一场戴着的一段 system prompt，只是它不属于任何包。**`/ext` 零改动**：污染从源头消失，不需要一条把它藏起来的规则。

**`agent-` 这个前缀留下来了，但它换了身份**：从一个 extension id 变成**那个包自己的写/读约定**——`render` 写这个文件名，`wornPersona`（"这一场是不是一次委派"、"它可以委派给谁"两道门的判据）从 header 的 `composition.prompts[].source` 剥它。内核对这个标签一无所知：`source` 由 CLI 记成文件 basename 去扩展名，原样进 block、原样进 header，不去重、不加前缀、不按它排序（DESIGN 那条 D4）。

**测试**：`bun test` 356 pass（`agents.test.ts` 那条材料化改成 `render`——多断言"prompt 文件里是正文"与"`.nulya/extensions/agent-probe` 不存在"；`delegate.test.tsx` 的 `agentSession()` 改读 `session list --json` 的 `composition.prompts`，driver tool 名单里 `materialize` → `render`；四处 `FrozenComposition` 字面量补 `prompts: []`）。**唯一的红仍是那条要 `pwsh` 的 plugin 测试**（本机没装 powershell，干净 HEAD 上同样红）。快照零变更。

### T45 · 两个别处的词，与 `/sessions` 那一行上真正值得读的东西（2026-08-21）

内核零改动。三件事：`/clear` 与 `/resume` 各接到这里已有的一件事上、`/sessions` 收一个可选 id、那张表删掉 model 与 token 两列。

**起因是落空的 slash 不是没反应。** `/` 开头的东西内建认不出就交给 skill 目录、再认不出就**原样发给模型**（§4.4）。所以一个手滑的 `/clear` 会变成一条写着 `/clear` 的 user turn，进 ledger、进前缀缓存、永远删不掉。这是该接的理由；接成什么样则由已有的东西决定。

**两个都是 alias，都不上表**（`/as` 的先例）：`/clear` → `/new`，`/resume` → `/sessions`。表上一行就是这个前端在说「存在这样一个命令」，而两个词一个概念正是 T36 花了一次改名去消除的东西。两个新词都没有带来新概念——`/clear` 这里**没有任何东西被清掉**（ledger 只能 append，physics #1；换 composition 就是换 session，physics #4，刚才那一场连着它的 tab、它的文件、它的每一条事件都原封不动待在那儿），`/resume` 也不是内核动词（append-only 让「打开它再说下一句」本身就是继续，DESIGN §3.1）。两行说明里各点一次它们的名，想得起来的人查得到。

**真正新的能力是 `[<id>]`，而它长在 `/sessions` 上。** 屏幕里按 id 打开一场，在此之前只有两条路：`/sessions` 里用眼睛找，或者带 `--session <id>` 重开进程；现在委派卡、`session list`、别人贴过来的 id 都可以直接粘。**alias 与本名走同一段代码**——`/resume <id>` 与 `/sessions <id>` 是同一个 `if`，因为一个通向别处的名字就不是 alias 而是第二个命令。id 不存在时点名它并说明裸形态会列出来，**绝不落到「发给模型」那一档**。实现全部是「文件在不在 + `openSession(id)`」，与 `Enter` 同一个入口（两个手势一个行为，不会漂）；能不能写仍由 `<id>.lock` 答（§5.6），开出来的 tab `created: false`，所以离开时不会被 `discardIfUntouched` 收走（`state/tabs.ts`）。

**model 与 token 两列删掉，第一条 user_text 拿走它们的宽度。** 这张表回答的只有一个问题——「刚才那场是哪一个」——而那两列都答不了它：一个 workspace 里几乎每一行的 model 都一样，**分不开任何东西的列不是信息**（§4.5 那条「没有的东西不占列」的同一把尺子），而真要看它，它冻在 header 里、开场就写在输入框底下；花费则是没人拿来认一场 session 的数字，账在 `/usage` 与 ledger 里一分不少，删的是**这一处的显示**不是任何事实。`said()` 原来那个 40 字符截断正是被这两列挤出来的，现在跟着一起删——行给它中间剩下的全部宽度，`fit` 在真实边界上切。`costOf` / `modelOf` / `tokens` 三个 helper 一并删除（没有第二个读者）。

**开屏 sync 那句汇总把「编译不过」与「没有工具链」分开说。** 内核的 `ext sync` 在 `ZigVersionUnreadable` 上也 `failed += 1`（`cli/ext.zig`），于是一行 `2 failed` 同时是两件事——一件要读诊断改源码，一件要装一个 zig，**而人对其中一件做的任何事都帮不了另一件**。合成一个数字之后，第二件读起来就是第一件：实测有人因此去查自己的 zig 环境变量，而那台机器的 `NULYA_ZIG` 指着一个能跑的 0.16.0、连 PATH 上没有 zig 都照样 build（managed 目录接住了）。现在汇总是 `1 failed · 2 need zig`（两段各自只在非零时出现，§4.5 那条「没有的东西不占列」），点名那一段也跟着分成两句不同的动词——`ask plan not built · /ext` 与 `std need a toolchain · /ext`。计数**从 line 上数 `needs zig`、再从内核的总数里减掉**（`Math.max(0, …)`）：解析不出的行会让它偏向「failed」，那是安全的方向——反过来会把一个坏掉的 draft 藏在「装个 zig 就好」后面。这是 T22 那一课的下一层：那次学会的是**点名**（`3 failed` 滚过去，`std` 因此在界面上消失了一周，§11 T22），这次是**点名也要配对的动词**，否则名字把人送去读一份编译得好好的源码。`/ext` 的 draft 列本来就分得清（`fails` / `needs zig`），只有那行汇总说不出来。

**内核也补了一刀，在同一条路的更深一层（DESIGN §7.4 / §10 / §14）。** 上面那件事做完，屏幕能说「2 need zig」了，可它**还是说不出为什么** —— `build_ext.compilerIdentity` 把 `std.process.run` 的错误、zig 的退出码和它自己的 stderr **全部扔掉**，三种失败（进程没起来 / 起来了但退出码非 0 / 跑通了但没打印版本）塌缩成同一个 `ZigVersionUnreadable`。实测代价：一台 `NULYA_ZIG` 指着能跑的 0.16.0、连 PATH 上没有 zig 都照样 build 的机器，在 TUI 里按 `b` 得到的是「could not report its version」，而**任何人都没办法知道是哪一种** —— 我从 Git Bash、PowerShell、Bun spawn 三条路各跑一遍全是绿的，复现不出来，因为要复现得先知道复现什么。现在原因跟着失败走（`Zig.failure` / `whyUnreadable()`，`catch` 处就地记下来）：`could not run it: FileNotFound` · `it exited 255: no build.zig to pull a zig version from, you can:` · `it printed no version…`，两个打这句话的地方（`ext build` 与 `ext sync`）各引一次。`firstLine` 把子进程的抱怨裁成一行（先 trim、取第一行、**再 trim 一次**——CRLF 主机交出来的那行尾巴上带着 CR，塞进句子里就是一个花掉的终端）并截到 200 字符：它进的是一句话，不是一段输出。**第一堵墙上还要再分一次**：`FileNotFound` 在 Windows 上同时是「exe 不在」与「工作目录不在」（`CreateProcessW` 两种情况回同一个码），而这两件事的修法相反，所以 `spawnNote` 在**失败路径上**去问一次文件系统，答出「there is no file at that path」/「that file is there, but the directory this build runs in is not」/ 两样都在就照打原错误名（= OS 自己拒绝了这次 spawn）。这一条是被真机逼出来的：屏幕上报 `FileNotFound` 的那个路径**确实存在**，我从三个 shell 加一个 Bun spawn 都跑得动它——错误名当时说的不是真话，而是说不出话。**内核语义零变化**——同样的错误、同样的控制流、同样的三条出路，只是那句话现在说得出发生了什么。

**测试**：`lifecycle.test.tsx` 一条（打错的 id 只得到一句话且什么都没开 → 裸 `/resume` 开出的就是 `/sessions` 那一张 → `/resume <id>` 开出那一场 → `/clear` 回到 draft 且 store 里一场没多 → 进程结束后那一场还在；**刻意用 alias 而不是本名跑**，走岔了当场就红）；`extensions.test.ts` 一条新的（两种混在一起 / 只有 needs zig / 只有 failed / 内核总数与 line 对不上时不为负）+ 原来那条 `failedIds` 改成两个函数各断言一半；`/help` 与 `/sessions` 两张快照按新表更新。内核侧 `zig build test` 466 → **467 pass**（`firstLine` 一条：空 / 全空白 / 多行 / 前导空行 / CRLF / 超长各一个断言）、`zig build e2e` 绿（sync 那条只断 `needs zig` 前缀，句子变长不影响——这正是当初那条断言写成前缀的用处）。

### T46 · 一根 pin 关掉了整个前端：一个包只在被点名的场里，它的 pin 也只能在那一行 argv 里（2026-08-21）

内核零改动——**内核是对的那一方**。三件事：`/ext` 的开关不再为 `on_request` 的包写常驻 pin、戴上一个包时它的 pin 跟着那一行 argv 走、开场自己修一次已经写坏的 `tui-state.json`；外加一件本该早就做的——`session new` 被拒时那段话画在**对话区**而不是状态栏。

**故障的样子**：把 `/ext` 里所有包都按了一遍之后，**每一场 session 都开不出来**，屏幕上唯一的解释是输入框下面那一行，还被切掉了半句：`session new failed: a pin names an extension with no active version here (see …`（后面还有半句和整张 pin 列，屏幕上没有）。`tui-state.json` 里有 `ext:ask/ask` / `ext:plan/propose` / `ext:plan/todo` 三行，而 `ask` 与 `plan` 的 manifest 都写着 `activation: "on_request"`。

**为什么这三行是不可能被满足的承诺**：`on_request` 的意思是 activate 只是**登记**——`composition.resolveActiveExtensions` 明确跳过它，它只进 `session new --with` 点名它的那一场（DESIGN §7.2.1）。而 pin 是**对着 composition 解析**的，所以一根指着非成员的 pin 不是「少一个工具」，是 `PinNamesUnknownExtension`、**整场拒绝**（physics：一场缺了被要求的能力的 session 不是被要求的那一场，DESIGN §7.5）。`/ext` 的 Enter 却对每个包一视同仁地写 `pinsOf`（T34 起判据是 manifest 的 `audience`，那一步是对的，缺的是第二个判据），于是「把所有扩展都打开」这个最自然的动作，产出的是一个开不了机的前端。

**修法是把规则写进名字**：`extensions.standingPinsOf` = 「一张**常驻**列表（`tui-state.json` 的 `session_pins`、user config 的 `registry.pinned_native_tools`）可以为这个包持有的 pin」，对 `on_request` 恒为空；`pinsOf` 保持原义（这个版本放在 model 面前的 tool）。`/ext` 的 `pinnable` 与 `toolRows` 都改读前者——于是一个 `opt-in` 的包在 tools pane 里**不再长出一个按不动的 checkbox**，它的开关是 membership 一件事，和 `compact` 一模一样（全开，不是半开）。Enter 的那句话也不再落到「its tools stay off the model face · drivers call them with ext run」那一档（对 `ask` 来说那是假话），而是走 `promptConsequence` 的 `on_request` 分支并把工具数说出来。

**另一半：戴上就得带着 pin。** 两根轴在别处是独立的（DESIGN §7.5），在这里不能是——`on_request` 的包成员身份只有一场那么长，所以指着它的 pin **要么写在同一行 argv 里，要么永远没有地方可写**。`App.wornPins` 因此在 draft materialize 时读一次那个版本的 model tools，与 `--with` 一起交给 `session new`。这不只是配合上面那个删除：在此之前 `/plan` 戴上的规划人格**根本调不到 `propose`**（`consumers.test.tsx` 里那两条是把 tool 流直接喂给 host 的，所以测出不来），`/ext` 那三根写坏的 pin 反而是唯一让它能用的东西——一个 bug 遮着另一个 bug。

**已经写坏的文件自己修**：`ExtView.dropOrphanPins` 从 T12 起就在做这件事，但只在面板打开的时候。而这个故障的形状正是「**开不出 session，所以也没人会去开面板**」，所以 `App.healStandingPins` 把同一次修复挪到开屏那趟 `listExtensions` 上（`resolveComposedPins` 已经在读它，不多一个子进程）。判据是共用的纯函数 `pins.resolvableStandingPins`——active、未被遮蔽、且 `activation` 说它进每一场；两个 consumer 于是不可能对「哪根 pin 是合法的」给出两个答案。

**最后是那句被切掉的话**（这才是「排查」花掉的时间的真正原因）：`session new` 的拒绝常常是**一段**——不信任的 store 会把它持有的每个 `id@version` 都列出来，坏 pin 会把整张 pin 列念一遍——而它以前只走 `setNotice`，那是**一行**、还与 model 和花费共用（§4.5）。现在 `nulya/cli.ts` 的 `fail` 抛 `CliError{message, detail}`：`message` 仍是一行给状态栏，`detail` 是命令说过的全部；draft 的 `ensureSession` 把 `detail` 放进 `App.refusal`，经 `Transcript` 的 `error` 走已有的 `ErrorNotice`——**一个失败的显示只有一处实现**，与一场跑着的 session 的 driver 失败同一张卡、同样按宽度折行。它的寿命就是 draft 的：下一次尝试开场时清掉，绝不盖在一场真的开起来了的 session 上。

**顺带改对一个声明：`ask` 不是模式，是能力（`extensions/ask`，`activation` 改回默认的 `always`）。** 上面那条规则一落地就把这件事照出来了：按新规则 `on_request` 的 `ask` 只能靠 `/ask` 戴上一场，而**没有人能预先决定"待会儿会有一个问题"**——模型是在任务中间才发现它需要问的，所以一个只在被预先指定的 session 里存在的提问包，等于一个永远不会触发的包。`activation` 问的是「我是能力还是模式」（DESIGN §7.2.1），两个包的答案本来就不同：`plan` 戴上是在说**这一场**是什么（人格 + 只读立场），那是人在开工前的决定，`on_request` 是对的；`ask` 只有一个 tool、没有 system prompt、没有 policy，它是一个能力，默认那一档才对。

**它当初写 `on_request` 的理由（T41 ⑥：这样开屏后台 sync 才肯 activate 它）不需要这个声明**——`autoActivatable` 放行的条件是 `systemPrompts.length === 0 || activation === "on_request"`，而 `ask` 本来就没有 system prompt，所以开屏行为一个字节都没变。改了之后 `/ext` 上那一行的 `Enter` 同时 activate + pin `ext:ask/ask`，**这一个键就是「模型可以问我了」**；只想给某一场用、不想常驻占一个 `max_tools` 槽的，`/ask`（包自己声明的命令）仍然在，走的正是上面那条 `--with` 带 pin 的路。`plan` 一个字未动。

**测试**：`bun test` **362 pass**（+`extensions.test.ts` 一条：`standingPinsOf` 对 always/on_request 两答，且 `pinsOf` 对同一个包照旧给出两个工具——「戴上时它们仍然到得了 model 面前」；+`pins.test.ts` 一条：`resolvableStandingPins` 排除 `on_request` / 无 `current` / `shadowed` 三种、driver tool **在内**（`audience` 是关于该给谁看，不是关于能不能 pin），并用 `orphanPins` 把真实故障里那三根 pin 挑出来）；`bunx tsc --noEmit` 干净。

### T47 · `/sessions` 的一行：把机器认得的东西拿掉，留下人认得的那一句（2026-08-22）

内核零改动。一件事：那张表的每一行只剩**第一句话**与**多久以前**——id、事件数、`with` 了哪些包，三样一起离开这一行。

**起因是一张截图**：`s-1787395224263-1fadef 08-22 18:40 · 6 events · with agent ask compact guide handoff std · 请探索当前 Nulya harness 的扩展…`。一行里排在最前、拿走最多宽度的三样东西，没有一样能回答读它的人唯一在问的那个问题——**「刚才那场是哪一个」**：22 个字符的 id 人读不出也记不住；`6 events` 说不出是哪 6 条（真想知道就 `Enter` 进去，那是一个键的距离）；`with …` 那一串在一个 workspace 里几乎行行相同，而**分不开任何东西的列不是信息**（§4.5「没有的东西不占列」的同一把尺子，T45 用它删掉了 model 与 token 两列——这次是同一条路的下一步）。真正认得出那场对话的那句话，被挤在最后、还随时会被切掉。

**于是一行 = 一句话 + 一个钟**。第一条 user_text 拿走整行剩下的全部宽度（内核已经替我们截到 120 字节并把换行换成空格，`session_list.zig` 的 `summarize`），chip 与钟排在它后面。`0 events` 唯一还在说的那件事——「这场什么都没发生」——由一句话接手：`nothing said yet`，faint 色，与「一句真话」在视觉上就分得开。

**id 只印一次，在标题行上，跟着光标走。** 它不是没用，是**只在被复制的那一刻有用**（`nulya session events <id>`、`/outcome`、贴给别人）——所以它不该占满每一行，也不能就此从屏幕上消失（§4.4 T22 删掉标题行时说过「要 id 就去 `/sessions`」，那句承诺得有地方兑现）。放在 `sessions · N` **旁边**而不是右边距：id 的 hash 不定长，右对齐意味着光标每动一下整行的空白跟着重排——正是 T12 那个尾空格 bug 的形状，只是往上挪了一行（快照当场把它抓了出来：同一帧跑两次差一个空格）。

**时间从时间戳改成距离，并且移到整行最右。** `08-16 09:12` 是正确的，也是需要读的人拿今天减一次才能用的——而他想知道的只有「是不是十分钟前那个」。一周以内说 `just now` / `12m ago` / `3h ago` / `2d ago`，超过一周距离不再好记，退回 `MM-DD`。**排在 chip 后面**是这条里唯一一处「看起来次要、其实是全部意义」的决定：chip 时有时无，一个会被 `▎ this tab` 或 `● live` 挤得左右移动的钟不是列，而这一列的全部价值就是能一眼从上往下扫。列宽取**当屏所有行里最宽的那个**（`just now` 是 8 格、`3d ago` 是 6 格；写死一个数字，迟早对不上自己画出来的东西）。

**顺带补上「哪一场是眼前这个 tab」的一句话**：以前只有 id 那一列换个颜色在说它，而颜色在 NO_COLOR 或单色终端里说不出话——现在是一枚 `▎ this tab` chip，与 `/ext` 的 `▎ this session` 同一个字形同一个意思。

**测试**：`ago` 是纯函数，边界钉在 `overlays.test.tsx`（59s / 60s / 90min / 26h / 6d / 8d 各一个答案，空串与坏字符串是 `—`，**另一台机器给出的未来时间戳仍然是 `just now`** 而不是负数）；`/sessions` 那条改成断言**看得见的东西**——第一句话在、`nothing said yet` 在、`events` 这个词不在、光标那一行的 id 在而另一行的 id **不在**（按 `j` 之后它才出现，这一条同时钉住了「标题行跟着光标走」）；`mouse.test.tsx` 两条按 id 找行的改成按那句话找行（行上已经没有 id 可找了——测试跟着人的眼睛走）。快照按新表更新。`bun test` **363 pass**、`bunx tsc --noEmit` 干净。

### T48 · reach 是人的决定：`activation` 删除，`/ext` 的开关从此写两半（2026-08-23）

T37 给了包一个字段自己说"activate 我算不算常驻"（`activation`）。内核把它删了（ext-review-2 Lane K，DESIGN §5.1/§7.2.1）：reach 是人的决定不是作者的（physics #6），而 pin 蕴含成员之后那个 bit 本来也已经拦不住任何东西——config 里一条 `pinned_native_tools = ["ext:plan/propose"]` 就把一个 `on_request` 的包带进每一场，内核照办，前端只能绕着走（那就是 `standingPinsOf` 存在的全部理由）。连带删掉的是 fresh 路的 discovery：**`activate` 从此只说 `<id>` 指哪个版本，一场 session 都不改变**，成员是 config `[extensions] with` 或 `session new --with` 点名的。

前端因此少了三样东西、多了一样：

- **删** `extensions.autoActivatable`（activate 永远安全了，`App.syncStores` 的 `--activate` 不再读 manifest）· `standingPinsOf`（它就是 `pinsOf`）· `activePromptPackages` / `promptPackageWarning` 与开屏那句"发现 active 的 mode 包就点名"——**那种状态不再存在**，一个包活着而没人点名它时，它一个 token 都不花。`Contributions` / `ExtensionEntry` 的 `activation` 字段与 `files.ts` 里那份 `activationOf` 镜像一起删。
- **加** `tui-state.json` 的 `session_with`：`/ext` 的 Enter 从此写**两半**——`current`（activate）+ standing pins（不变）+ **standing with**，条件是这个包贡献了 skills / system_prompts / commands / ui 任一（`extensions.standingWith`）。纯 tool 包不写：它的 pin 自己就把包带进来了（DESIGN §5.1），第二种说法只是第二样要撤回的东西。再按一次 Enter 两半一起撤——一条指着没有 `current` 的 id 的 `with` 会让 `session new` 整场拒绝，比一条悬空的 pin 更狠。

其余是把新语义画出来：`/ext` 的 `mode` 列只剩一个词（"贡献 system prompt"，从前要在 `mode` / `opt-in` 里选一个说包声明了哪种 reach）；detail 里"composed into every session"那行现在说得出是**哪张单子**把它放进去的（config 的 `[extensions] with` / `tui.toml` 的 `session_with` / 这个面板自己）；裸 `/with` 的 picker 列出**所有**有 `current` 且贡献 system prompt 的包（从前只列声明了 opt-in 的）；`ext list` 第二列的 `(inactive)` 改叫 `(no current)`，TS 侧两个词都认（新前端 + 老二进制）。`session new --bare` 由 `sessionNew`/`SessionExtras` 透传，值来自 `extensions/agent` 的 `render`——委派该带什么是那个包的事，不是这里的。

**测试**：`bun test` 全绿（新增：`standingWith` 的四种贡献各一条 + 纯 tool 包一条；`/ext` 那条端到端多断言 `session_with` 两个方向都动了；`pins.test` 的"standing 名单"少了一个条件，多了 mode 的 tool 也能被 pin 这一条）。`zig build test` / `zig build e2e` 见 goals/ext-review-2.md §6 Lane K。

### T49 · manifest 瘦身的前端一半：对象 action、按宿主的 ui、一个 mode 不必再声明自己的名字（2026-08-23）

内核那一半是 ext-review-2 的 Lane M（DESIGN §7.2.1）。前端这边跟着改了四处，**没有一处是新概念**：

- **`packageCommands.parseAction` 读对象**（`{with:true}` / `{run:"<tool>"}` / `{skill:"<ref>"}`），旧的字符串形与 `"wear"` 两种老写法都仍然折进同一个 `PackageAction`。`isDeprecatedWearAction` 因此变成 **`deprecatedActionNote`**：它回的不再是一个 bool 而是**要说的那句话**（"写成对象" / "把 `wear` 改成 `with`"），因为现在有两种老写法而调用点只有一个。
- **`files.uiOf` 读 `contributes.ui.tui`**（`plugins/host.ts` 一个字没改——它读的一直是 `contributions.ui`）。没有 `tui` 这一条 = 这个包对本前端没有插件，**跳过不警告**：manifest 按宿主键之后，"没有我的那一条" 是普通答案不是缺陷。平铺的老形式仍读成本前端的（顶层有 `entry` 键就是它）——冻结版本留在盘上的字节不会因为 draft 改了写法就变。
- **`approvals.poolPolicy` 只剩 `readonlyBy`，`withPolicy` 删掉**。`decide` 从此拿到的就是 `tui.toml` 那三张表本身，一个包不能再往里加行；它能要的那一件事（整场只读）判在三张表**之前**，与 agent 天花板同一处 —— 那条路径本来就在，只是现在是唯一的一条。
- **`/<id>` 不必声明**（`extensions.derivedCommand`）：一个贡献 system prompt 的包，它的名字唯一可能的意思就是"戴上它"，而每个这样的包都得在 manifest 里抄同一条 `commands` 才能说出来。现在 driver 自己推：有 `current` + 贡献 prompt + id 是 `[a-z0-9-]+` → `/<id>` = with。包自己声明的同名条目**优先**（声明比推导更具体，它可能另有所指），内建名永不被夺走（`resolve` 那条既有规则，derived row 与别的 row 走同一条路）。`extensions/plan` 的 `commands` 条目因此删掉，`extensions/ask` 的留着——`ask` 不贡献 prompt，`/ask` 是它真正的主张。
- 顺带：`/ext` 详情里那行 `permissions fs 1 · net …` 删了（`permissionLine` 与 `ExtensionEntry.permissions` 一起），字段已经不在 schema 里。

**测试**：`bun test` 全绿（`parseAction` 三条按新旧形状重写、`poolPolicy` 收成两条 + 一条"包的 policy 永远进不了审批表"、`derivedCommand` 一条新的；`plugins.test.tsx` 的夹具与 `plugin.test.tsx` 的 manifest 改成新写法）。

### T50 · `/ext` 的 Enter 只剩一个意思；一个 checkout 只问一句（2026-08-23）

K/C/M 三条 lane 落地之后对 TUI **用户**的一次复盘（`goals/ext-review-2.md` §3b）：用户要懂的只该是"启动即就绪、`/ext` 开关、模式是一条斜杠命令"，复盘只挑出两处还在说别的，内核零改动。

**① `/ext` Enter = 让这个包可用，就这一个意思。** T48 的 `standingWith` 把贡献 system prompt 的包也写进 standing `session_with`，于是对 `plan` / `evolution` 按 Enter 几乎等于说"从此每一场都戴它"——一个几乎永远不是本意的后果，逼得那一行 Enter 必须带一句吓人的"EVERY new session"才敢按。改法是把这半条规则整个撤回：`extensions.standingWith` 变成 `systemPrompts.length > 0 → false`，否则 `skills || commands || ui`——贡献 system prompt 的包**永不**再写标准 `session_with`，无论它还贡献了什么（`plan` 同时也有一个 `ui` 面板，这条件照样是 `false`：面板在 `/plan` 自己那一场里靠那一场自己的 `--with` 加载，从来不需要标准列表）。Enter 对这样的包仍然只移 `current`（+ 它声明的 model-audience pin，如有）——composition 一点不改（DESIGN §5.1），但 M4 的 `derivedCommand` 早就在等它：一有 `current`，`/<id>` 这条命令就出现，Enter 的 notice 从此说的是这个：`` `<id>` on · /<id> opens a new tab wearing it for one session · Enter again takes the command away ``；`switchOff` 对称地说 `` `<id>` off · /<id> is gone · versions all stay ``（原来那句"no longer enters new sessions"从来就不该被说出——它从未真的进过）。`ExtView.tsx` 的 detail 里那句"a mode"的说明同步改写（`turning it on puts its prompt in every new session` → `Enter gives it a /<id> command that wears its prompt for one session`），配色从 warn 降成 muted——不再是一句警告，只是一句信息。`mode` 列保留（这仍然是一件值得让人一眼看出的事），它旁边的英文说明改成"Enter 给它一条 `/<id>` 命令"。**`promptConsequence` 整个删除**，`switchOn`/`switchOff` 直接写各自的通知文案；`switchOff` 仍然把 id 从 `session_with` 里移除，处理这一改之前写进去的旧条目。`WithPicker`（裸 `/with`）不动——它列的本来就是"有 `current` 且贡献 prompt 的包"，从未依赖 `standingWith`。**一个模式常驻每一场依然可以，只是不再是这一行 Enter 的事**：config `[extensions] with`，或 `tui.toml` 的 `session_with`——都是人写的、显式的、罕见的决定，`/ext` detail 里"composed into every session"那句照旧点名是哪张单子放的。

**② 开屏只问一句。** 随 checkout 到达的东西曾经问两次：先是 `.nulya/extensions` 的 store 问句（`t`/`s`/`n`），再是 `.nulya/agents` 的 agent 问句（`t`/`n`）——同一次开屏、同一个人、同一把"只问一次"的尺子，却是两段先后打出来的文字。新写的纯函数 `extensions.planCheckout(storePlan, agentsPlan)`（与 `planProjectStore` 并排，按类型导入 `agents.ts` 的 `AgentTrustPlan`，不产生值层面的循环依赖）判断三种情形：两边都不用问 → `{kind:"none"}`；只有一边要问 → 原样返回**那一边今天的问题**（文字、按键、`apply` 的行为逐字节不变，`agentsPromptText`/`bothPromptText` 两个新的纯文本组装函数只在"只问一边"与"两边都问"时才被用到）；两边都要问 → 一段文本先列 store 持有什么、再列 agents 定义了什么，接一句新问题、三个答案：`t` 信任并安装两者（store：trust+build+activate；agents：trusted）、`s` 只 build 扩展、两者都不信任、`n` 都不动。返回类型 `{kind:"ask", text, choices, apply(key)}` 里的 `apply` **保持纯**——它只把一次按键翻译成一个 `CheckoutAction{store, agentsTrust}`，不碰文件系统；真正跑命令、记 `asked_stores`/`asked_agents`/`trusted_agents`、打印"installing…"与两句"left alone"的，是 `main.tsx` 新写的**唯一**glue 函数 `askAboutCheckout`（取代原来的 `askAboutProjectStore` / `askAboutProjectAgents` / `readAnswer`，`readKey` 保留），它读 `plan.text`、循环 `readKey()` 直到 `plan.apply(key)` 接受一个答案为止，再按 `action.store.sync` 决定要不要打印"installing…"+`summarize(...)`，按 `checkoutFollowUp(action, storeAsked, agentsAsked)`（新的纯函数，只对**这次真的被问到**的那一侧打印"left alone"）补上两句从前分开打的话。`sync_on_start` 关掉时 store 半句仍然整个不问（这条开关本来就是"要不要碰扩展"的总闸），agent 半句不受它影响，与从前一致。`applyAnswer` 拆成 `applyStoreAction`（按 `StoreAction` 直接跑）+ 一层 `actionFor` 转换，供两条路复用同一份命令。

**测试**：`extensions.test.ts` 新增 `planCheckout` 一条（六种组合：都不问、都 ready、只 store、只 agents、两者都问的三个答案）与 `checkoutFollowUp` 一条；`standingWith` 那条改名重写（prompt 包现在断言 `false`，skill/command/ui 三种各自 `true`，prompt+skill 同时贡献仍是 `false`）；`consumers.test.tsx` 里 `plan is a mode and ask is a capability` 那条的 `standingWith(plan)` 断言从 `true` 改成 `false`（`plan` 真实清单里同时有 `ui` 面板，正是"prompt 优先于其它贡献"这条规则的活例子）；`overlays.test.tsx` 的 `/ext marks a package that contributes a system prompt as a mode…` 整条重写，断言 Enter 之后 `session_with` **不含**该 id、notice 含 `/<id>`、detail 文案含"nothing here composes it standing"。`bun test` 365 跑绿（一次全量偶发在高负载下丢一条 lease 等待测试的超时，隔离重跑照绿——`project-nulya-tui-test-gotchas.md` 记过的既有类别，与本改动无关）。`bun run typecheck` 干净。`CLAUDE.md` 里 ext-review-2 Lane K 那条现状 bullet 的 TUI 指路从"tui.md T47"改成"tui.md T48/T50"（T47 说的是 `/sessions` 那张表，从不是这条规则住的地方；T48 引入了这条规则，T50 是它现在的样子）。

### T51 · 测试 scratch 目录清理 + `tui-state.json` 那半 `session_with` 改名（`goals/ext-review-3.md` Lane S，2026-08-23）

两轮评审落地后剩下的两件小事，都只碰 TUI 自己的文件，内核零改动。

**① `tui/test/isolate.ts` 不再往 `%TEMP%` 里堆。** preload 给每次 `bun test` 起一个 scratch `NULYA_HOME`（`mkdtempSync`，几乎每条测试都要 spawn 真二进制，见该文件顶部注释），但从没人删过它——跑得够久的一台机器 `%TEMP%` 里已经堆了近八百个 `nulya-tui-home-*` 目录。补一个 `process.on("exit", …)` 里的 `rmSync(scratchHome, {recursive:true, force:true})`，包一层 `try/catch` 吞掉失败：一次清理失败绝不该拖垮一次测试跑（Windows 上一个还攥着 handle 的子进程会让这次删除失败，下一次进程退出时再试）。文件顶部那段解释"为什么要隔离"的注释不用动——它说的是隔离本身，不是清理。

**② `tui-state.json` 的 `session_with`（K8 新加，`/ext` Enter 写的常驻成员半张单子）与 `tui.toml` `[extensions] session_with`（T34：TUI 恒带的 `handoff` / `agent`，按精确版本解析）撞了同一个词——两个文件里两样几乎不相关的东西共用一个名字，读一遍代码先要分清"这一处是程序状态还是人写的设定"。改法是把 state 那半改名 `standing_with`：`tui_state.ts` 的 `sessionWith`/`rememberSessionWith` 随之改名 **`standingWithIds`/`rememberStandingWith`**——不叫 `standingWith`，因为 `extensions.ts` 早就用这个名字导出一个谓词（Lane T：这个包贡献的东西够不够格进 standing with 名单），两个不同的东西不能共享一个名字。`loadTuiState` 读**两个**键名一个版本期（`record["standing_with"] ?? record["session_with"]`，与 `mode` 那半认老 `auto` 同一先例），只写新名（`saveTuiState`）；调用点全部跟着改名——`ExtView.tsx` 的 `switchOn`/`switchOff`/`composedEverySession`、`App.tsx` 的 `sessionExtras`、`overlays.test.tsx` 的 `/ext marks a package that contributes a system prompt as a mode…`。`tui_state.ts` 里那段"Not to be confused with `tui.toml`'s `session_with`"的澄清注释随之删除——名字不再相同，没什么好澄清的了。`tui.toml` 自己的 `[extensions] session_with` 一个字没动（那是人写的设定，不在这次改名范围里），历史日志（K8/T1/T48/T50）里对 state 那半的旧称呼也没动——那些条目描述的是当时的名字，跟"老文件里的 `auto` 仍读成 `unsafe`"同一个先例：历史不因后来的改名而重写。

**测试**：两处都是纯改名 + 一个 best-effort 清理，行为不变，没有新增断言。`bun test` 365 跑绿（隔离重跑 `overlays.test.tsx`/`extensions.test.ts`/`consumers.test.tsx`/`pins.test.ts` 时丢过一条无关的 lease 等待测试超时——`/sessions marks a session somebody else is driving as live`，单独重跑即绿，`project-nulya-tui-test-gotchas.md` 记过的既有类别）。`bun run typecheck` 干净。

### T52 · 三个词换了、缺省翻了个面、一张单子不必再由前端写（`goals/ext-syntax.md` §4，2026-08-25）

内核那一轮把 `surface` 的三个词按**问题**重命名（`with`/`pin`/`driver` → **`auto`/`manual`/`internal`**：这个包已经是成员了，这个 tool 怎么到模型面前）、把缺省从 `pin` 翻成 **`auto`**，并给 manifest 加了一个顶层 **`apply: "auto" | "manual"`**（缺省 `manual`）。TUI 是这些词的第二个读者，本条是它的跟进——内核零改动。

**① 三个词与那个翻面的缺省。** `nulya/files.ts` 的 `toolSurfaceOf` 从前认 `pin`/`with`/`driver`、并把**任何别的词折进 `pin`**（那是给退役的 `audience` 留的路）。新词汇下这条折叠是灾难性的：三类会**全部**塌进 `pinTools`，于是 `/ext` 的 tools pane 会给每个 `auto` 与 `internal` tool 画一个能按的 checkbox，而按下去写出的 pin 会被 `session new` 整场拒绝（`PinToolNotPinnable`）。改成只认三个词，**认不出就是 `auto`**——与内核逐字对齐，因为缺省不是"没说"而是一个答案（一个人特意组合进来的包，它的 tool 就是他想用的那些）。三个投影随之改名，跟着词走：`pinTools`/`withTools`/`driverTools` → **`manualTools`/`autoTools`/`internalTools`**（`Contributions` 与 `ExtensionEntry` 各一份，`pins.ts` 的 `resolvableStandingPins`、`extensions.ts` 的 `pinsOf`、`ExtView` 的 `ToolRow.auto`/`.internal` 全部跟着）。**T33 的折叠判据**从 `driver && 没有 pin` 变成 `internal && 没有 pin`，那一行的措辞改成包自己的词加上它的意思：`▸ N internal tools · called with ext run, never on the model face · d shows`；`labelOf` 的两句同理（`auto · with the package` / `internal · ext run`）。

**② `apply`，与它替掉的那张单子。** `Contributions`/`ExtensionEntry` 多一个 `apply`（从冻结 manifest 顶层读，缺省 `manual`），带来两处行为改变：

- **开屏后台 sync 的自动激活判据**（T31 的那条）从"不贡献 system prompt"改成 **`apply !== "auto"`**（`extensions.autoActivatable`）。旧判据在 `activation` 被删之后已经在守一扇不通向任何地方的门：一个 `manual` 的 prompt 包，activate 只是移一个指针、composition 一点不改（DESIGN §5.1），它的 prompt 要有人点名（`/<id>`、`/with`、`[extensions] with`）才进得去。真正值得挡的是 `apply: "auto"`——**对它 activate 就是 compose**，内核从那一刻起把它组进这台机器上每一场非 `--bare` 的 fresh session。所以判据换了个主语，而 T31 的那句话一个字没变：一趟没人看着的后台 pass 不该替人决定每一场 session 戴什么。`adoptBundled` 与 `App.syncStores` 各在自己那条激活路径上问一次（一次冻结 manifest 的文件读），被跳过的**点名**而不是计数（`<id> built, not activated (every session) · /ext`）——"1 not activated"没有人能拿它做任何事。
- **`/ext` 的 Enter 从写三样变回写两样**：`current` + 它的 `manual` pins。T48 加的那半"standing with"（`extensions.standingWith` → `tui-state.json` 的 `standing_with` → `sessionExtras` 逐个 `--with`）**整个删除**，连同 `standingWithIds`/`rememberStandingWith` 与 `TuiState.standing_with` 这个字段。理由是那半解决的问题现在有了一个更好的持有者：一个包该不该在每一场里，是**包自己**说（`apply: "auto"`），而内核对每一个 driver 都照做——一个前端在旁边另记一张私单，就是同一个问题的第二个答案。`/ext` 的 `mode` 列随之改成 **`standing`**（`modeCell` → `standingCell`，判据 `apply === "auto"`）：那一列问的一直是"这一行的 Enter 会不会波及每一场"，而"贡献了 system prompt"只是在没有包能自述 reach 的年代对这个问题最接近的猜法——今天它认错了包（一个 `manual` 的 prompt 包离得很远，一个 `apply:"auto"` 的纯 tool 包就在每一场里）。Enter/OFF 的 notice 因此有三种形状（`apply:auto` → `composed into every session on this machine` / mode → 那条 `/<id>` / 其余 → 版本与 pin 数），detail 里"composed into every session"那句多认一张单子并点名是**哪一张**（包自己的 `apply`、config 的 `[extensions] with`、`tui.toml` 的 `session_with`），因为这三样撤销的地方不同。

**③ 一处顺带修好的真 bug。** `sessionExtras` 只传 `--with`、不传 `--pin`，而 `agent` 的入口 tool 是 `surface: "manual"`——membership 不是工具面，所以 `ext:agent/agent` 根本没上过模型的桌子（`delegate.test.tsx` 那条断言在本轮之前就是红的）。`SessionMember` 补上 `pins`（从**正在被组合的那个版本**的冻结 manifest 读，`pinsOf`），`sessionExtras` 把它们放进同一行 argv。`handoff` 不受影响：它的 tool 是 `auto`，一个 `--with` 就够。

**④ legacy 全清（项目 pre-release，不留兼容补丁）。** 删掉的：`toolSurfaceOf` 里 `audience` 的折叠 · `extensions.stdEditPinDecision`/`adoptStdEditPin` 与 `TuiState.adopted_std_edit_pin`（T30 给老 `session_pins` 补 `ext:std/edit` 的一次性迁移）· `approvals.normalizeMode` 把老 `auto` 读成 `unsafe` 的那一行（只认 `ask`/`unsafe`）· `loadTuiState` 认老键 `session_with` 的那一读（T51 的过渡，随 `standing_with` 一起消失）· `files.uiOf` 认平铺 `contributes.ui{entry,api}` 的那一支（内核 ext-review-2 已经拒绝这个形状）· `PackageActionValue` 的字符串小语言与 `packageCommands.splitAction` 里按空格切的那一半（同上）· `settings.ts` 读 `[extensions] handoff`/`agent` 两个老布尔的循环与 `withPackage`（T34 换成 `session_with` 列表时留下的）。**命令别名留着**：`/as` 仍认作 `/with`，`{"wear": true}` 仍折成 `with`——那是 UI 便利与一张开放词表上的同义词，不是在读一个退役的**形状**。

**测试**：`bun test` **373 全绿**（`bun run typecheck` 干净）。改动最大的是夹具：`ext init` 的模板现在不写 `surface`，所以每一处**关于 pin** 的夹具都要自己说 `manual`（`overlays`/`mouse`/`lifecycle` 三个文件的 `lint`、`overlays` 的 full-face `lint`、`pins.test.ts` 的 `notes`），而 `overlays` 的折叠夹具从 `audience: "driver"` 改成 `surface: "internal"`。新的钉子三根：`files.test.ts` 用一次**真 build** 钉住两个内核缺省（没写 `surface` 的 tool 进 `autoTools`、`manualTools` 为空、没写 `apply` 的包是 `manual`）；`extensions.test.ts` 用另一次真 build 钉住 `apply: "auto"` 读得出来且 `autoActivatable` 为 `false`，并把 `std` 那条夹具扩成三个 surface 各一个 tool 外加一个什么都不写的；`autoActivatable` 自己一条纯函数测试取代原来那条 `standingWith`。`consumers.test.tsx` 的 `plan`/`ask` 那条改成断言**两个包都不说 `apply`**（所以 `/ext` 的 Enter 对它们都只是移指针），`pinsOf` 两处从 `["ext:plan/propose", …]`/`["ext:ask/ask"]` 改成 `[]`——它们的 tool 现在是 `auto`，membership 就是它们上台的路。顺带修好一条**与本轮无关的既有红**：`registry.test.ts` 断言 `read · src/emit.zig · offset=40`，而 `7b1612f` 起 `{path, offset?, limit?}` 已经被当作一个**文件目标**读成 `src/emit.zig:40`（`pathArgsSummary`，代码注释里写着），测试没跟上。

### T53 · 一个包的模型面就是它自己，一条命令的家是声明它的那个包（2026-08-25）

T52 之后剩下两处「同一件事说两遍」，都是 `surface`/`apply` 那套词换完之后才看得清的。内核零改动。

**① `extensions/agent` 的 `agent` tool：`manual` → `auto`。** 它是这个包对模型面的**全部**贡献（另外三个是 `internal`），而「带不带这个包」本来就是每个 driver 每一场自己的决定——`--with` 已经把那句话说完了，membership 之外再要一根 `--pin ext:agent/agent`，是同一个决定说第二遍。新语义下这件事还更硬：`auto` tool **不可 pin**（`fresh_pin` 只认 `manual`，否则整场 `PinToolNotPinnable`），所以翻转 surface 与删掉全部 pin 调用点是一件事而不是两件。删掉的三处：`extensions/agent/src/main.zig` 委派白名单那条 argv（子场是 `--bare` + 显式 `--with`，membership 就够）· `tui/src/agents.ts` 的 `agent_pin` 常量 · `App.startAgent` 里把它拼进 `pin` 数组的那一段。**`sessionExtras` 一个字没改**：它的 pins 来自 `SessionMember.pins`（`pinsOf` 读正在被组合的那个版本的冻结 manifest），surface 一翻那张单子自己就空了——这正是 T52 把它写成「从 manifest 读」而不是「一张写死的列表」换来的。`tui-state.json` 里可能存着的老 `ext:agent/agent`（`/ext` 在它还是 `manual` 时按 Enter 写的）由 `healStandingPins` 在开屏时当 orphan 掉出来并说一句——已有的自愈路径，不需要迁移代码。`render/registry.ts` 认卡片按 **tool id**，id 没变，一个字没动。

**e2e 怎么改的**：`tests/e2e/extension.zig` 那条「只有带白名单的 persona 才carry 这个 tool」**断言字面量不变**——`"native_tools":["ext:agent/agent"]` 在协调者的冻结 header 里照旧成立，因为 auto tool 的 native 槽和 pin 来的 native 槽写进 header 的是同一张表（`session.zig` 把 `extension_tool_bindings` 整个投影成 `native_tools`）。变的是它现在**证明的是什么**，所以补了三根钉子把新语义钉住：协调者的 header 里 `"id":"agent"`（成员关系存在）· 叶子的 header 里既没有 `ext:agent/agent` 也没有 `"id":"agent"`（**根本不是成员**，不是「是成员但没上台」）· 叶子的 `"native_tools":[]`（`--bare` 之下没有第二条路能把 `internal` 那三个放上去）。「叶子根本没有这个 tool」这条语义因此比从前更钉得死。

**② `/evolve` 去硬编码：evolution 自己声明这条命令。** `extensions/evolution/extension.json` 加一条 `contributes.commands`（`evolve` → `{with: true}`，**不加 `apply`**——它就该按场穿），于是它走 T39 那条包命令链，与 `/ask` 完全同一条路。删掉的：`App.runCommand` 里的 `/evolve` 分支与 `evolveNow`（那个「先 `ext build` 再穿」的特例）· `commands.ts` 的 `aliases.evolve`（**必须删**：alias 排在包命令前面被 `withoutBuiltins` 用作保留名，留着的话 evolution 声明的那条永远不会被派发）。`src/evolve.ts` 因此只剩 `/with` 的通用件（`WithRef` / `parseWithRef` / `formatWithRef` / `withOptions`），**改名 `src/with.ts`**——文件名说的是它服务的那个概念，而 `/evolve` 已经不住在这里了；`test/evolve.test.ts` 同步改名。

**行为变化，要说清楚**：`/evolve` 现在**要求 evolution 已经 build + activate**。开屏 sync 会做到这一步（bundled draft → `ext seed --user` → `ext sync` build → `autoActivatable` 为真所以 activate，因为它不写 `apply`），所以常规使用感觉不到差别；但两件事变了——**改了 draft 要重新 sync/build 才生效**（从前每次 `/evolve` 都重 build，改完立刻生效），**没激活时 `/evolve` 根本不存在**（补全里没有、打出去会落进 skill catalog 再原样发给模型），修法是 `/ext` 里给它 Enter。这正是 T37 那句抱怨（「我没启用 evolution，为什么有 `/evolve`」）的最终形态：一个命令的存在与那个包的存在，从此是同一件事。

**③ `/help` 补一行。** `/evolve` 离开内建表之后，`/help` 就再也不会提到它——而 `/ask` `/plan` 早就已经是这样了（那一页从来只列 `commands.ts`）。所以 `slashes` 多一条按**形状**而不是按名字的行：`/<package command> · declared by an active extension · /ext lists them`。不去真的枚举当前激活的包命令，是因为 `/help` 这一页描述的是**这个前端**提供什么，而哪些包命令存在是 `/ext` 的问题。

**测试**：`zig build test` 489 pass、`zig build e2e` 92 pass、`cd tui && bun test` 374 pass（`bun run typecheck` 干净）。`with.test.ts` 第三条重写成新路径：build 之后**没有** `current` → `packageCommands` 里没有 `evolve` → `activate` → 有了，且 `parseAction` 是 `{kind:"with"}`，并断言 `/evolution` **不**出现（先是 `derivedCommand` 收窄了一条，随后 T54 把派生整个删了）。`/help` 快照更新一行——`/with` 的说明短了两行、新那行占一行，所以整页没有内容被挤到折叠线以下。**唯一的红是既有的环境红**：`model.test.tsx` 的 `/model` 那条在本机会看到真实的 codex profile 排在 `scripted` 前面，`git stash` 之后同样红。

### T54 · 命令只因声明而存在：`derivedCommand` 删除（2026-08-25）

**T49 的翻案，由用户点名**："`/<id>` 不必声明"让前端替 manifest 发明它从未主张过的名字——manifest 是关于一个包的唯一真相（DESIGN §7.2.1），而这条派生是站在它旁边的第二个答案。T53 已经暴露了它的别扭：evolution 声明了 `/evolve`，派生还要再给一个等价的 `/evolution`，于是先补了一条"声明了 `{with: true}` 就不派生"的收窄——一条规则需要豁免清单，通常说明规则本身站错了地方。现在整个删掉：**一条 slash 命令存在，当且仅当某个 activated 包的 manifest 声明了它**。

**改动**：`extensions.derivedCommand` 删除，替之以 `wearCommand`（读声明：一个包的第一条 `{with: true}` 命令，`/ext` 的 Enter notice 与 detail 文案用它点名"怎么穿上"——没声明就指 `/with <id>`）；`packageCommands` 只收集声明；`extensions/plan` 把 T49 删掉的三行 `commands` 声明加回 manifest（`/plan`）。什么都不丢：没声明命令的 prompt 包照样 `/with <id>` 穿上，裸 `/with` 的 picker 照样列它。kong / dogfood 这类 `apply: "auto"` 常驻包从不需要一条"穿上"命令——派生规则对它们本来就是自作主张。

**测试**：`extensions.test.ts` 的派生测试重写为 `wearCommand` 三条；`overlays.test.tsx` 的 house.style 场景改断言 `/with` 指路与 `it can no longer be worn`；`with.test.ts` 断言声明的命令是唯一一条。

### T55 · `/ext` 的措辞与后台 sync 的加固：两件事都在说"activate 不是 reach"（外部 review，2026-08-26）

外部 review 点出两处地方仍在用「on/off」的重量讲一个只移动指针的动作，而内核这一轮同时把 `ext sync --activate` 从"拒绝没人看过的 `apply:auto` 包"改成了"真的全部激活"（另一个 agent 的改动，只在内核侧）——两件事分开看都不大，合在一起看是同一个漏洞的两半：TUI 这边如果继续用 on/off 暗示"下一场一定生效"，而后台 sync 又能在没人看着的时候悄悄改变一个 standing 包的 reach，模型或人都会在某天发现自己以为常驻的模式不见了，却找不到是谁、什么时候关掉的。两处改动都不碰内核，只碰 `tui/`。

**① 措辞：`/ext` 的主状态词从 on/off 换成 active/inactive。** 详情页早就在说 `active|inactive`（T22 起），只有开关那一列、Enter 的 notice、hint 与 footer 还在说 on/off——而对一个 `manual` 包，"on"暗示的"下一场就带着它"从来不成立（`activate` 只移 `current` 指针，DESIGN §5.1；真正回答"会不会波及每一场"的是 `standing` 那一格，T52）。`ExtView.tsx`：`SwitchState` 的取值 `"on"/"off"` → `"active"/"inactive"`（`switchState`、`switchColor`、`toggleExtension`、id 列的开关标记与配色，及沿途的注释）；`switchOn`/`switchOff` 两个函数改名 `activateExtension`/`deactivateExtension`，飞行中的 notice 从 `<id> on…`/`<id> off…` 改成 `activating <id>…`/`deactivating <id>…`；落地的 notice、footer 的 `brief`/`more`、`pinKey` 的兜底提示同步换词。`apply:"auto"` 分支里"composed into every session on this machine"这类**讲后果**的句子原样保留——它们说的正是 active 与 standing 的差别，不是本轮要改的东西。`docs/tui.md` §5.3 与本条同步（ON/OFF → ACTIVE/INACTIVE，并顺手把一段还在讲 T54 之前 `derivedCommand` 派生规则的过时描述改成现在的 `wearCommand` 声明式命令）。测试：`pins.test.ts` 的 `switchState` 断言随枚举改名；`overlays.test.tsx` 两处字面量（footer 的 `Enter on/off …` 与 house.style 场景的 `off · it can no longer be worn`）与对应快照跟着改。

**② 加固：后台自动激活除了看候选版本，还要看当前活跃版本的 `apply`。** `extensions.autoActivatable(what)` 一直只读**候选**（即将成为 `current` 的那个版本）的 `apply`——这是 T52 关的门：候选是 `apply:"auto"` 就不自动激活。但它答不出镜像的问题：一个**已经**是 `apply:"auto"` 的包（比如 kong，此刻正被组进这台机器上每一场 session），draft 出一个 `apply:"manual"` 的新版本，候选自己看起来完全安全——`autoActivatable(candidate)` 是 `true`——而背景 sync 一旦替它挪动 `current`，kong 就在没有一次按键的情况下从每一场 session 里悄悄退出了。这正是 T31 那条 bug 的镜像：T31 挡的是"没人看着就把一个包组进每一场"，这里要挡的是"没人看着就把一个包从每一场里挪出去"——两个方向都不该是背景任务的权力。

新增 `extensions.safeToActivateUnattended(ws, id, candidate)`：候选不是 `auto` **且**（没有已激活版本，或已激活版本读出来也不是 `auto`）才答 `true`；已激活版本从 `ext list` 找同 id 里未被遮蔽、有 `current` 的那一行，读它自己的冻结 manifest。`App.tsx` 的开屏后台 sync 循环（`syncStores`，未带 `--activate` 的 `ext sync` 之后手动决定每个 id 要不要移指针那一段）从 `autoActivatable(built)` 换成 `await safeToActivateUnattended(props.ws, line.id, built)`——被挡下的 id 走的还是原来"点名而不计数"的那条路（`standing.push(line.id)`，状态栏说 `<id> built, not activated (every session) · /ext`）。**候选与已激活版本的 manifest 可能来自不同 build**，两次读各自独立（`builtContributions` 读候选那一份，`safeToActivateUnattended` 内部另读已激活那一份），不共享缓存也不假设两者一致。`adoptBundled`（`ext seed` 这一轮**新落地**的 id 的激活路径）没有改：它处理的 id 定义上是这次 seed 才第一次出现在这个 store 里的，不可能有"已激活版本"，`autoActivatable` 单独判就是完整答案。

**测试**：`extensions.test.ts` 补两条真实 store 场景——kong 场景（对一个真实 store 里已激活 `apply:"auto"` 的包重建出一个 `apply:"manual"` 的新版本，断言 `safeToActivateUnattended` 为 `false` 且 `current` 真的没有移动，即便候选单独看 `autoActivatable` 会是 `true`）与普通场景（`manual` 激活、`manual` 候选，断言 `safeToActivateUnattended` 为 `true`，加固对无关重建没有副作用）。`cd tui && bun test`：377 pass（新增 2 条），`bun run typecheck` 干净。

### T56 · standing 的真源换成内核的记录，无人值守的激活 fail-closed（外部 review，2026-08-26）

同一轮外部 review 的后两点，都在同一件事上：**前端不该自己算「这个包现在是不是在每一场里」，也不该把「我不知道」读成「可以动」。** 内核这一轮已经把 `apply` 的记录写进了 `current`（`ext list` 每行的贡献括号里因此多一个词 `standing`，如 `[skills prompt standing]`），于是第一点是接上真源，第二点是把三个 fail-open 的洞补上。两处都不碰内核。

**① `standing` 读内核的记录，不再从 manifest 重推。** `ext list` 的 parser 一直把那个 marker 丢掉，`/ext` 于是从 `current` 版本 manifest 的 `apply` 反推「现在是不是 standing」——两个字段答的是两个问题：**`apply` 是某一个版本的声明**（该拿来问「候选版本会不会 standing」），**`standing` 是内核记下的有效状态**（activate 时验过 manifest 才写进 `current`）。它们可以不一致（记录出现之前写下的指针、被手改过的版本目录），而不一致时描述真实 session 的是后者——内核自己的 `contributionMarker` 就是这么选的，前端跟着选同一个。

改动：`ExtStoreEntry.standing` / `ExtensionEntry.standing`（parser 认任何一个方括号字段里的 `standing` 词——marker 是尾随字段不是固定列，`[with]` / `(shadowed)` 都可能跟在后面），`Contributions.apply` **原样保留**（两者语义不同、都要留，两处注释写清区别）。读它的地方：`standingCell`、`composedEverySession`、`refreshPins`/`refreshComposedMembership` 的 auto-tool 投影、deactivate 的 notice（「it leaves every session composed here」说的是**它本来有的东西**）。仍读 `apply` 的地方只有「按下去会怎样」：activate 的 notice（那一刻记录还不存在，`reconcile()` 随后把 store 的答案取回来）与 detail 里"a mode"那句的判据。detail 因此多一句——**声明了 `apply:"auto"` 但还不 standing** 的包（inactive，或指针老于记录）说 `` `apply: "auto"` in its own manifest · activating it composes it into every session started here ``；从前这种包会拿到「composed into every session started here」这句现在时的话，而它其实一场都没进。

**② unattended 激活 fail-closed，并且只有一个 policy 出口。** 三个洞，都是「不知道 = 放行」的不同写法：`safeToActivateUnattended` 里 `extList` 失败 `catch { return true }`（我不知道旧状态 → 当作安全）；`App.tsx` 写的是 `if (built && !safe(built)) continue`，于是 `builtContributions` 回 `null`——**连候选是什么都读不出来**——反而绕过守卫去激活；`adoptBundled` 干脆有自己一份更窄的政策（只看候选 `apply`），理由是「seed 说 arrived 的 id 不可能有已激活版本」——但 `ext seed` 判 arrived 看的是 **draft 不存在**，而 `<id>/current` 完全可以在 draft 被删之后独立活着，于是"user store 里 kong 有旧的 standing current、无 draft → seed arrived → 候选 manual → 悄悄关掉 standing"是一条真实路径。

改法是 review 给的形状：`safeToActivateUnattended` = 候选 `auto` → false · `extList` 失败 → **false** · 没有 active 行 → true · 否则 `!entry.standing`（读 ① 的字段，不再读 manifest）；新的 `activateUnattended(ws, {id, version, root, user})` 是**唯一那道门**（`built` 读不出来 → `held`；政策说不 → `held`；`extSetCurrent` 抛 → `failed`），startup sync 与 `adoptBundled` 都只经它。**候选从哪来不是政策输入**：`arrived` 说的是这一轮谁落地了，与「移动这个指针会不会改变每一场 session 带什么」无关，两个调用者两份政策就是多了一份。被拦下的照常在状态栏点名，措辞从 `built, not activated (every session)` 收成 `built, not activated · /ext`——现在被拦有两种原因（reach 问题是活的 / store 答不出来），而分得清它们的是 `/ext` 那一行本身。

**测试**：`files.test.ts` 一条真二进制 fixture（`apply:"auto"` 的 data 包：build 后 `standing` 是 `false`（没有 `current`）→ activate 后 `true` → deactivate 后又 `false`，而 `apply` 三次都是 `"auto"`——manifest 读法分不出这三态），并给既有那条加一句 `manual` 包恒 `false`；`extensions.test.ts` 三条——`ext list` 打不通时 helper 回 `false`（候选单独看是安全的）、候选 manifest 读不出时 `activateUnattended` 是 `held` 且 `current` 没动、以及 adoptBundled 场景（user store 里预置一个 `apply:"auto"` 已激活的 `kong` 与一个什么都没有的 `house.rule`，把 kong 的 draft 改成 `manual` 重 build，然后把两个 id 一起当成 `arrived`：kong 的指针没动且仍 standing、被点名，house.rule 照常激活）。T55 那两条一字未改地仍然成立——它们本来就只断言 helper 的答案与指针的位置。`cd tui && bun test`：382 pass，`bun run typecheck` 干净。

### T57 · 一趟 sync 说得出自己在等谁（2026-08-26）

开屏那趟后台 sync 在屏幕上几乎不存在：进度写在 `setNotice` 上，而 T35 之后 notice 是**新闻**——盖住那一行，然后按 `noticeHold`（下限 3 秒）自己下去。内核**在一个 draft 建完时**才报它，所以六个编译包里第一个跑 zig 的那几十秒里一次回调都不发：计数停在 `2/8`，三秒后整行消失，剩下的时间屏幕一个字都不说。这正是"卡住了"的样子，而人找到的修法是退出去手动再 build 一次。第二个半边：`/ext` 只在 `onMount` 读一次，开着它等 sync 的人看的是**开始之前**那份 plan，于是一个已经建好的 draft 继续写着 `not built`——同一件事的两种表现。内核零改动，第三点在 `cli/ext.zig` 的呈现层。

**① 进度搬去 `WorkingStatus`。** 判据是 T38 自己划的那条线：notice 是新闻，输入框上面那一行是**正在发生什么**。`activityOf` 多一个事实 `syncing: SyncProgress | null`（`{what, done, total, since}`），画成 `⠋ building std (5/8) · 41s`；`total = 0` 不打计数（seed 那一段没有可数的东西，`(0/0)` 是一个永远填不满的进度条）。**排在最后一格之前**：一趟 store pass 从不挡住对话，所以等审批、跑着的 step、花完的预算全都比它更该被读到；它只压过 `background`，因为第一条消息之前那两者里它才是人在等的那个。`Activity` 因此多一个可选的 `since`——不是 step 的工作有自己的起点，否则它会去借一场还没开始的 session 的钟。

**② 报的是 id 不是数字。** `syncStores` 本来就先跑一次 `planStore` 取总数，现在把**那份有序的 id 列表**留着：内核报的是"谁完成了"，正在做的就是同一张单子上的下一个。`building std` 与停住的 `5/8` 的区别，就是"在等谁"与"不知道还有没有在动"的区别。走完最后一个之后不再点名（还有指针要移、listing 要重读），收成 `syncing extensions (8/8)`。

**③ 写完了就让屏幕重读。** `planTick` 这个"有人写了那些文件"的信号早就在，只是 sync 结束时只在 `adopted.length > 0` 那一支 bump。改成**无条件** bump 一次，并把它作为 `tick` 传给 `ExtView`，那边 `createEffect(on(…, {defer: true}))` 重跑 `refresh()`。于是"sync 跑完 `/ext` 还说 not built"消失——它从来不是 sync 的问题，是一张没人告诉它该重读的屏。

**④ 不用编译器的 draft 排在前面**（`cli/ext.zig` 的 `draftIds`，DESIGN §14）：`data` / `script` 的 identity 只是 snapshot，建它们是拷贝加 digest，毫秒级；八个自带包里正好两个是这种。两组内各按 id 排序，所以"两次 sync 读起来一样"仍然成立，而计数**立刻**开始动，剩下的等待明确是在等编译。判 kind 要读一次 draft manifest（几百字节，读不出来的排进第一组——它的真实错误该当场报出来，而不是排在每一个编译之后）。下游不依赖顺序：每个 draft 独立 build，汇总是总数。

**测试**：`workingstatus.test.ts` 两条——一条钉住它画出 id 与计数、`total = 0` 时不画计数、且带着自己的钟，一条钉住优先级（审批 / stepping / 花完的预算都压过它，而它压过 `background`）。顺序那一格没有断言：它是呈现，而 DESIGN §14 明说下游不依赖它。`cd tui && bun test`：384 pass，`bun run typecheck` 干净；`zig build test` / `zig build e2e -Dtest-filter="sync"` 干净。

### T58 · 一个包说得出它推荐开哪几个工具（2026-08-26）

`manual` 的含义一直只写了一半。它说的是"有 pin 才上模型面"——那是**内核**的规则，从来正确——但没有任何地方说过"装上这个包之后，这几个该不该开"。于是两个安装者各自在猜，而且猜得不一样：`/ext` 的 Enter 把**全部** `manual` tool 都 pin 上（`pinsOf`），手工 `nulya ext activate` 一条都不写。后者正是 `extensions/std` 的文档安装路径，六个工具因此全在模型面外，而屏幕上没有任何迹象说少了什么。

补的是一个**给安装者的声明**：`contributes.tools[].recommended`（`manifest.ToolSpec`，缺省 `true`，DESIGN §5.1/§7.2.1）。内核解析、冻结、**零 enforce**——工具面的解析一个字没改，`manual` 仍然是"有 pin 才上"——读它的只有决定要写哪些 pin 的那一方。缺省是 `true` 因为那正是 `manual` 在实践中的意思：**装上就开、但可以逐个关**，而 `auto` 是"因为包在所以在、没有单独的开关"，两者的差别只在那个开关，不在默认。所以八个自带包一个字都不用改，行为逐位不变（`std` 的六个仍然全开——它是编译包，为一个恒等的默认值 bump 一次 version id 等于让每台机器重跑一次 zig）。

**它买到的是混用型的包**：为之存在的能力写 `auto`，只有部分 session 想要的额外能力写 `manual` + `recommended: false`。在此之前，前端把全部 manual 都 pin 上，正好开的是作者标出来要留着关的那一半。写在非 `manual` 的 tool 上是 `InvalidRecommended`（`auto` 的本来就开着、`internal` 的永远上不了面，那个键在那儿只会骗人）。

**"缺省开"不需要负号**，这是它能便宜落地的原因：默认被**物化**成一条条具体的 pin，不是内核在解析工具面时算出来的——关掉某一个就是删掉那一行，减法本来就存在。真需要负号的是"把一个 `auto` 关掉"，那件事没做。

前端侧：`Contributions.recommendedTools` / `ExtensionEntry.recommendedTools`（`contributionsOf` 从 manifest 读，`recommended === false` 才排除），`pinsOf` 从"全部 manual"改成读它。CLI 侧：`ext activate` 生效的那一份多一行 stderr 点名推荐的 pin，并明说**这里不写任何配置**、出路是 `[registry] pinned_native_tools` 或 `session new --pin`（推荐集合为空则整行不打——`compact` 那样只有 internal tool 的包没有 pin 可建议）。

**测试**：`manifest.zig` 一条（缺省 true、`false` 读得回、两种非 manual surface 与"没写 surface 等于 auto"都是 `InvalidRecommended`、类型错是 `WrongType`）；`extensions.test.ts` 两条——纯函数那条钉住"推荐的进 pin、没推荐的留在 `manualTools` 里等一次按键"，真二进制那条给 std fixture 加了一个 `recommended: false` 的 `demolish`，走一遍真 `ext sync` + `builtContributions`。`cd tui && bun test`：385 pass，`bun run typecheck` 干净；`zig build test` / `zig build e2e` 干净。

### T59 · `/ext` 的工具面收起每一个按不动的开关（2026-08-26）

T33 把 `internal` 行折起来时给的理由是**数量**（六个 driver tool 对五个可 pin 的，而后者有 `max_tools` 封顶、前者没有）。`auto` 行留在外面，理由是它们确实在模型面上。但那一列画的是 checkbox，而 `auto` 行的 checkbox **按不动**——`Space` 写的是 pin，pin 的入口只有 `manual` 一种（内核对指名 `auto` 的 pin 直接 `PinToolNotPinnable`）。于是这张表里混着两种长得一样的行：能按的和不能按的。

判据因此从"是不是 internal"换成**"这一行这个面板能不能动它"**：`manual` 的能动；任何**已经有 pin 压着**的行也能动（不管什么 surface——把一条不该存在的 pin 取下来正是这个面板的用处，T33 那条例外原样保留并推广）；其余（`auto` 的 `composed` / `off`，`internal` 的 `off`）一律折起。**折起不是删掉**：它们仍在 `d` 后面，展开后每行的 `stateLabel` 已经说了 `with the package`。

折起那一行按**包自己的词**分两组，各带一句为什么没有 checkbox：`2 auto · with their package · 4 internal · ext run only · d shows`。一行一个键（fold 是一个控件，而读者在问的是同一个问题：要不要打开）；措辞刻意短，因为这行要 `fit` 到面板宽度、计数必须活过窄终端。信号量名 `driversOpen` 随之改成 `foldOpen`——它折的已经不只是 driver tool。

**测试**：`pins.test.ts` 那条改写成"collapsed 就是全部开关"（一个 `auto` 包 + 一个 `internal` 包 + 一个 `manual` 包：折 6 露 3；折起行同时点名两组；只有一种时不提另一种；压着 pin 的 `internal` 行仍然可见）。`overlays.test.tsx` 两处跟随：折起行的文案，以及 80 列那条把它的长 id 扩展改成 `manual`——它量的是"窄终端下 checkbox 守住格位、id 被切"，而脚手架出来的 tool 是 `auto`，会连着那个被切的格子一起折走。`cd tui && bun test`：385 pass，`bun run typecheck` 干净。

### T60 · 无人值守激活的守卫删除（2026-08-26）

`autoActivatable` / `safeToActivateUnattended`（T31 → T55 → T56）整个删掉，`activateUnattended` 只剩一条 **fail-closed**：读不出这个版本的 manifest 就不动指针——那不是 policy，是「别对读不出来的数据动手」。

**为什么它该走**。守卫的出身是 [BUGS.md](BUGS.md) 第一条：`evolution` 被开屏 sync 悄悄激活，于是每个模型都以为自己是 slow loop。但**让那件事成为可能的是 discovery**——activate 蕴含成员关系——而 discovery 在 2026-08-25 随 `activation` 一起删了（ext-syntax Lane K）。今天 `evolution` 是 `apply: "manual"`，与 `plan` 同形：把 `current` 指向它，它进不了任何一场 session，prompt 只在 `/evolve` 开的那一场里生效。**结构性修复早就落地了，守卫却又活了很久。**

于是它的实际战果反了过来：`autoActivatable = apply !== "auto"` 对 plan / evolution / std 全部放行，自带包里**唯一被它拦住的是 `guide`**——整个贡献只有一行 skill catalog 的那个。而它写来要防的形状（`apply: "auto"` **加** system prompt，也就是一个「模式」）恰恰是 `apply` 这个字段存在的意义（nulya-kit 的 kong / dogfood），且只会因为**有人装了它**才出现。一道为了防止改写模型身份而建的门，最后只挡住了全套里最便宜的包，代价是「装了 nulya，guide 却不生效」。

**为什么删掉是安全的**。进得到自动激活的只有三条路，每一条都已经过了一个人：装这个二进制（`ext seed`）、自己往 user store 写源码、亲口回答 checkout 的信任问句——而那个问句本来就提供 `s` = 只 build 不激活（DESIGN §9）。守卫是在这些之后**再**替人否决一次。

**换掉它的是可见**（`warnUserScope` 那条先例：允许、不拦、但绝不能不可见）：`adoptInstalled` 把「这些包从此进每一场 session · /ext」写进开屏那行汇总，`/ext` 的 `standing` 列与 Enter 是收回的地方。

### T61 · 首次安装才替人写 pin（2026-08-26）

配套的另一半，也是 T58 `recommended` 缺的那个时机。从前只有两处会写 pin：`/ext` 的 Enter，和 `adoptBundled` 里**写死 `id === "std"`** 的一支。于是"开屏 sync 激活了一个包"与"这个包的工具上不上模型面"是两件互不相干的事——实测状态就是 `std · active · 0/6 tools`，`session_pins: []`。

新规则一句话：**一个包这一趟拿到它的第一个 `current` 时**（`adoptInstalled` → `pinRecommended`），按它自己声明的 `recommended` 写 pin；`std` 那个 id 判断随之删除（T34 那批硬编码名单的最后一条）。

**窄在"从来没有过 current"而不是"指针动了"**：版本前进时 pin 列表已经是人的了，按后者会把他 `Space` 掉的工具在下次 rebuild 时悄悄加回来——一个会自己撤销的开关不是开关。判据来自开屏**在 seed 之前**读的一次 `ext list`（`hadCurrent`），读不到就当作"全都已经装过"（写不出 pin 好过写在别人的选择上）；`adoptBundled` 收同一个集合作参数，两个调用点一个定义。`max_tools` 不够就一个都不写，让 `/ext` 去挑——开不起来的 session 比没上面的工具糟。

**测试**：`extensions.test.ts` 三条——`apply:auto` 的包首次安装会被激活 + 只 pin `recommended` 的那个 + 汇总里点名它进每一场；仅重建的包一条 pin 都不写（人 `Space` 掉的留在原地）；`adoptBundled` 的那条改写成"arrived 里新装的那个才是 install"。`cd tui && bun test`：383 pass。**文档**：CLAUDE.md 三处（T31 那句"activate = 它的 prompt 进每一场"是 2026-08-25 之后的假话，正是它把这次排查带偏的）、`docs/BUGS.md` 第一条补了"真正修它的是什么"。

### T62 · `/ext` 的 draft 列跟着 `current` 走，并改口叫 `inactive`（2026-08-26）

**Bug**：在 `/ext` 里 activate 一个包，那一列不变，要关掉面板重开才显示 `active`。

**根因是两个真相来源，而只有一个被刷新。** 这一列的 `active` 读的是 `drafts()` 里 `ext sync --dry-run` 报的 `activation`，而 activate 之后跑的 `reconcile` **故意不重跑 plans**——注释写着"a pointer move cannot change what a draft would build to"。那句话对**版本**成立（内容寻址，指针动了源码还是那份），但同一行上还有一个 `activation` 列，它说的正是 `current` 指向谁，而那恰恰是 activate 改的东西。于是乐观更新（`setLocalCurrent`）与 `reconcile` 都在更新 listing，屏幕上却有一列在读另一份没人刷新的数据。

**修法不是多刷一次**（两趟 `ext sync --dry-run` 是这个面板最贵的调用，注释里避开它的理由完全成立），而是**让这一列别再回答那个问题**：`draftColumn(line, current)` 收 listing 里那个 id 的 `current`，`line.activation` 从此不被读。一个问题一个来源，于是"忘了刷新"这种 bug 在结构上不可能再出现。

**`built` 拆成两个词。** 它从前盖住了两个**修法不同**的状态：`current` 根本没有（包是关的，Enter 打开）与 `current` 指着**别的版本**（包在跑，只是这份源码的 build 不是它——`a` 在版本行上把 `current` 指过去）。合成一个词说，后者挨着同一行的 `standing` 就是自相矛盾：这个包进每一场 session，而这一列说它 inactive。所以现在是 `inactive` 与 `not current` 两个词，而 `built` 这个说法本身也退场——它挨着 `active` 会被读成进度阶梯上的一格「还没到」，而它的意思只是「这个 build 在」。detail 里对 `not current` 多一句点名那个键（`draftHelp` 收一个 `current` 参数；它是唯一一个既不是 `b` 也不是 Enter 能修的行状态）。其余四个词不变：`not built` / `fails` / `needs zig` / `differs`。

**测试**：`draftColumn(one, null)` 在 `line.activation === "activated"` 时仍然回 `inactive`——plan 自己的那个词被忽略，这条断言就是不变量本身；另加"current 指着别的版本 → inactive"。`cd tui && bun test`：383 pass。

### T63 · 四处「说了半句」：开屏的静止动画、没有源码的包没有状态词、按不动的 tools chip、认得却不提示的别名（2026-08-26）

四件互不相干的小事，共同点是**屏幕上已经有那个东西，只是它没把话说完**。

**① 开屏那趟 sync 的动画是静止的。** `WorkingStatus` 对 `syncing` 活动照样给 `moving: true`（spinner + 高光扫带），但驱动这一切的 `spinnerTick` 定时器在 `App` 里的开启条件是 `status() !== "idle" || runningTasks() > 0`——而 store pass 跑在**还没有 session 可 step、也没有后台任务**的时刻，于是钟根本不走：glyph 冻在第一帧，扫带停在原地。这是这个前端上**第一个**被看见的动画，也是唯一一个不动的。条件补上 `|| syncing()`，写成 `activityOf` 里 `moving` 的那个并集。（`motion=false` 照旧全关。）

**② `kong` / `dogfood` 在 `/ext` 里没有状态词。** 不是它们没 active——开关的 glyph 是绿的、detail 那行写着 `active`——是**列表那一行里没有任何一个词这么说**。`draftColumn(line, current)` 在 `line` 为 null 时回空串，而 `line` 来自 `ext sync --dry-run`，只有 store 目录里**有源码**的包才有。这两个是 `ext build <仓库外的路径> --user` 装进来的：`versions/` 与 `current` 都在，旁边没有 draft。于是整个列表里只有它们两行是空的，而旁边每一行都写着 `active`——空白被读成「关着」。T62 已经把这一列变成了**指针**的列（`active` / `inactive` / `not current` 三个词说的都是 `current`），所以没有源码时它照样答得出来：`current ? "active" : "inactive"`。有源码的四个词（`not built` / `fails` / `needs zig` / `differs`）一个不变。

（顺带记一笔诊断结论：这两个包**不该**有 `standing` 列——nulya-kit 的 manifest 没写 `apply: "auto"`，所以内核的 `current` 记录里也没有那一列，`/ext` 报的是对的。）

**③ 输入框下面的 `tools 1+N` 按不动。** 同一行上 mode chip、model、`◈ wearing` 三个都有 hover 高亮与点击（分别开 `/mode` / `/model` / `/ext`），而 `tools 1+N` ——一个数**每一个都能在 `/ext` 的 tools pane 里开关**的东西的计数——是纯文本。补上 hover + 点击进 `/ext`，`onOpenExt` 复用 wearing chip 已有的那个 prop。`· ` 分隔符留在可点区**外面**（chip 是那个事实，不是连接它的标点），所以 `tools_chip` 常量不再自带前缀，宽度预算里补回三列。

**④ `/resume` 没有 Tab 提示。** 补全不是硬编码的，它读 `commands.ts` 的表；四个别名（`/as` `/clear` `/resume`，这次多一个 `/exit`）**故意不在表上**——一个概念一个词，`/help` 与命令表都只说那一个。但「不列出」和「不补全」是两件事被当成了一件：`/res` 打出来得到一个空菜单，而空菜单在这个前端里的意思是「没这个命令」，而它明明有，只是叫 `/sessions`。所以 `completions` 现在在列出的名字**后面**追加别名候选，那一行写的是 `another name for /sessions`——列出与否是这个前端**主张**什么，补全是回答一个已经打了四个字母的人。排在后面：`/e` 先给 `/effort` 与 `/ext`，再给 `/exit`。

**`/exit` 新增为 `/quit` 的别名**（其它 harness 的词）。只做带斜杠的那个：裸 `exit` 是一句普通文本，前端不该替模型截下它。别名进 `builtin_names`，所以包也夺不走这个名字。

**测试**：`draftColumn(null, v)` / `draftColumn(null, null)` 两条（没有源码时的指针列）；别名补全一条（`/res` → `/resume`、那一行指向 `/sessions`、`/e` 的排序把列出的名字放前面）。`cd tui && bun test`：384 pass，`bunx tsc --noEmit` 干净。

### T64 · queue lane 与 ctrl+j：排队的消息看得见，插队是一个手势（2026-08-26）

**内核零改动**（goals/agent-runner.md ar-t1）。substrate 早就齐了：`session append` 投 inbox、内核每个 step 边界排干（T27 把报告时机也修准了）、Esc kill 这一步、T29 的 wake 在 idle tick 时把非空 inbox 排掉——所以"中断并投递"事实上一直可达，只是要两个手势加一个定时器 tick，且没人知道这条路存在。这一轮全是把它包装成**一个**看得见的动作。

1. **queue lane（`ui/QueueLane.tsx`）**：`pendingCount() > 0` 时在输入框上方（WorkingStatus 同区——都是"此刻正在发生什么"，不是 session 的描述）画一行 `⏸ N queued — enter queues · ctrl+j interrupts & delivers`，底下逐条截一行列出排队消息；静息时**不画**（T35/T38 那条规矩：没有 `0 queued` 这一行）。点击任一行 = 下面的手势——inbox 是内核整体 FIFO 排干的，不假装能单条插队。lane 显示的是用户原话：mid-run 排队的消息在 wire 上套着 mid-task sentinel（midtask.ts），lane 用与 transcript 卡**同一个** `parseMidTask` 折回来。
2. **手势（`Driver.interruptAndDeliver`）= 三个现有动词按顺序接线**：append（原样走 `send` 的排队路径，所以 `queued` 标记行为不变）→ kill（T27 既有的杀这一步）→ 等 `drive()` 的 `finally` 真正跑完（新内部 `idleOnce()`——不是"kill 信号发出"那一刻，否则第二个 `session step` 会撞上还没放的写者租约）→ 立即 `step()`。零新状态机。idle + composer 有字退化成普通 `send`；**idle + 空文本（lane 的点击落在 step 刚结束之后）走 `wake()`**——inbox 非空立即 step、为空仍是 no-op，绝不裸 step 空 inbox（那会把上一条 assistant 当 prefill 重发，DESIGN §4）。observer 没有自己的写者租约可杀，`Attachment.interruptAndDeliver` 对它退化成既有的排队 append。
3. **ctrl+j 是有条件抢的键（keymap `interrupt`，`[keys]` 可覆盖）**。裸 ctrl+j 在非 Kitty 终端与换行**字节相同**（`@opentui/core` mock-keys 实测），而它正是 composer 的 Shift+Enter 退路——无条件抢会吃掉那批终端的换行。所以 App 的 layer 只在 `interruptRelevant()`（有步在跑，或已有排队）时 enable，静息时按键原样落进 composer——`closeTab`/ctrl+w 在单 tab 时放行 delete-word 的同一条先例。composer 侧 `triggerInterrupt()` 复用 `submit()` 的清空/历史/粘贴展开路径，`onSubmit` 只多一个 flag。
4. **契约的一处偏离，记在案**：ar-t1 写"idle 时该手势等价普通发送"，字面执行意味着任何时候都抢 ctrl+j（见上），改为仅在有意义时抢；静息 + composer 有字时 Enter 本来就够。

**测试**：`bun test` 393 pass（新增 `queuelane.test.tsx` 纯渲染 + 点击、`interrupt.test.tsx` 真二进制端到端 kill+redeliver 与静息态不画，`driver`/`observer` 各加 interruptAndDeliver 的分支条目），`tsc` 干净。

**没做**：不给 lane 做单条删除或重排（inbox 在内核里没有这些动词，前端不该假装有）；`/agent` 子场的 d-* 跟随是 ar-t2。

### T65 · `ask` 档下的只读命令：一个保守的分类器，答掉那些从来没有悬念的问题（`goals/agent-runner.md` ar-i，2026-08-26）

**内核零改动**，全部在 `tui/`。起因是 `ask` 这一档的实际体感：规则没管的每个 call 都停下来问，而其中绝大多数是 `git status` / `ls` / `cat` —— 答案从头到尾没有悬念，问多了只教会人"这个框是用来按 Enter 穿过去的"。把无聊的那些就地答掉，才是让真正值得看的那一个还读得出来的办法。

1. **它不是安全边界，一个字都不能这么读**（§5.7 末句、DESIGN §9 没有变）：`shell` 与 extension 同权，真隔离等 sandbox（PLAN §3.8）。所以 **readonly 天花板（agent 定义 / `contributes.policy`）不用它**——那道天花板对 `shell` 一律拒，理由正是"没有 OS sandbox 就分不出 `cat foo` 与 `rm foo`"（agents-and-review §1 不变式 5），一个字符串分类器改不了这个事实。这里裁的只是"要不要为这一次打断一个人"，而那个人就在一键之外，每个 call 也都在屏幕上。
2. **判断全在 `tui/src/readonlyshell.ts` 一个纯函数里**（`classifyShellCommand(command, extra)` → 一句拒绝的理由或 `null`）。写法只有一个方向：**否决很便宜，放错很贵**。① 引号感知 tokenizer（单引号 / 双引号 / 反斜杠转义）把命令行在**顶层**按 `&&` `||` `|` `;` 换行拆成简单命令，**每一段都得过**——`git status && rm -rf .` 里第一段干净说明不了第二段任何事情；② 一票否决：命令替换 `` ` `` / `$(…)` / `<(…)` `>(…)`、写向重定向 `>` `>>` `2>` `&>`（唯一例外是**精确**的 `2>&1`——它把一条已经存在的流指向另一条，什么都不创建；`< file` 允许，那个文件名不算参数）、env 前缀赋值、`eval`/`exec`/`sh -c`/`xargs`/`sudo` 这类 wrapper、以及**任何解析不动的东西**（不闭合的引号、认不出的形状）都是"去问人"；③ 名单是**封闭**的：没认出来的程序一律问。
3. **反引号无条件禁**，连引号里的也禁——它在 POSIX 里是替换、在 PowerShell 里是转义符，禁掉它（以及 `$(`、裸 `&`）之后**一个 POSIX 形状的 parser 可以替两种 dialect 说话**：能过这个分类器的命令，在两种 shell 下解析一样、行为一样。
4. **名单到子命令与 flag 级**：`git` 顶层只认 `--no-pager` / `-C <dir>`（**`-c` 拒**——`git -c core.fsmonitor=… status` 就是一个注入点，`--exec-path=` 同理），子命令按 status/diff/log/show/blame/rev-parse/ls-files/… 放行并拒 `git diff --output=`，`branch` 只在**每个参数都是列举 flag**时放行（裸 operand 会**建**分支），`remote` 只 `-v`/`show`/`get-url`，`stash` 只 `list`/`show`，`tag` 只空或 `-l`；`find` 拒 `-delete`/`-exec`/`-execdir`/`-ok`/`-okdir` 与 `-fprint*`（写文件那几个）；`sort` 拒 `-o`；`rg` 拒 `--pre`/`-z`，`fd` 拒 `-x`/`-X`；`nulya` 只放只读动词（`help` / `config show` / `ext list|inspect|api` / `session list|events` / `task list|status` / `skill list|load` / `src`，**`demo` 不算**——它跑模型）；`--version` 类查询只对点名的那几个工具生效。
5. **`sed` 与 `awk` 整个不进名单，理由同一条**：它们的操作数是**另一种语言写的程序**，而那种语言自己能写文件（sed 的 `w`、awk 的 `print > f`）也能跑命令（GNU `s///e`、awk 的 `system()`）——`sed -i` 只是其中最显眼的一条路，flag 级检查在这里不可能是完备的，而"给另一种语言写的程序分类"不是一个命令分类器该做的事。`find` 留下来正因为它危险的动词是 **flag**，那恰好是这个文件看得见的东西。想放 `sed -n` 的人在 `[approvals] readonly_commands` 里说一句，那是他自己的决定（与 `manifest_readonly` 同一条纪律）。
6. **裁决链的位置**（§5.7 决策序补一层）：`deny` → 本场 `always` → `ask` → `allow` → manifest `readonly` → **只读命令分类器（仅 `shell`、仅 `ask` 档）** → mode 兜底。排在人写的四张表**之后**：人写的 `deny`/`ask` 必须能压过它。**只在 `ask` 档说话**：`unsafe` 下一行本来就放行，这时候再挂一个"因为它只读"的标记，等于给一个不是理由的理由。`approvals.judge` 返回 `{decision, via}`、`decide` 是它的薄封装——顺序**只写一遍**，UI 侧不为了画那行标记再实现一次"这条命令只读吗"。
7. **卡上一行标记**（T28 "卡上只留一行标记"的先例）：`AutoAllowedMark`，dim，画在审批对话框本该出现的位置——期待被问的人看得见自己没被问、以及为什么。它是 view fact（`ToolItem.autoAllowed`），但**存在 `SessionState` 的一个 id 集合里**而不是只写在某个 item 上：provisional 卡会被 committed 卡整个替换（`dropInFlight`），而 gate 的回答落在那一刻的哪一侧要看两条线谁先到——写在 item 上就成了一个看运气的标记。
8. **人这一侧的开关是 `[approvals] readonly_commands`**（如 `["cargo tree", "kubectl get"]`）：按**整词前缀**匹配一个简单命令，与三张表同样"替换而非合并"（近的一层要能把条目撤下来）。它加的只是**程序名单**——parser 的每一条否决讲的是这一行的**形状**，任何条目都买不动：`cargo tree > deps.txt`、`cargo tree && rm -rf .`、`sh -c` 照问不误。

**测试**：`test/readonlyshell.test.ts` 表驱动（每个否决向量一行、复合命令、引号藏操作符、`2>&1` 的边界），`approvals.test.ts` 补裁决链位置与 `readonly_commands` 三条，`gate.test.tsx` 加一条真二进制端到端（`ask` 档、没人按键，scripted 的 `echo hello-from-nulya` 直接跑完并带标记）。**同一个文件里其余的审批测试从此带一条 `[approvals] ask = ["shell:echo"]`**——`echo` 现在会被分类器放行，而那些测试问的是对话框本身，这条 checkpoint 正好也把"人写的表压得过分类器"钉在了那儿。`bun test` 全绿、`tsc` 干净。

**没做**：不给分类器做 off 开关（`ask` 表已经是"就这一类还是要问我"的说法，`unsafe` 是另一头）；不改 `run_summary` 的收编规则（被折进 `⋯ read ×3` 的那些本来就是"跑完 + 成功 + 无身体"，摘要行自己就说了没人被问）；不拿它去松动任何 readonly 天花板（第 1 条）。

### T66 · 开场就知道自己在哪：`ground` 渲染，`--prompt` 送进去（`goals/ground.md`，2026-08-27）

**内核零改动**，前端只多一个模块与一次调用。起因是 kernel prompt 只有五句 harness 事实、`coding` 补了工作纪律，而**这一场具体跑在哪**（哪个目录、什么平台、今天几号、git 什么状态、项目长什么样、这个 checkout 自己写了什么规矩）一个字都没有——于是每场开头的头几个 tool call 都在问「我在哪」。

1. **`ground` 不是 `session_with` 的一员**，所以它没有进那张列表。membership 带进 session 的是**冻在版本里的同一批字节**；这些是今天的日期、这个分支、这个目录，生命周期恰好一场 session——`--prompt` 那一侧（`goals/session-prompt.md` 的尺子）。它是另一根轴：**`[extensions] session_prompts`**，一张**列表**（缺省 `["ground"]`），与 `session_with` 逐位对称、同样是「近的一层可以整张换掉」。
2. **前端不认识 `ground` 这个名字。** 契约就一句：列表里的每个 id，跑它的 internal tool `render`，读回 `{"prompt": "<路径>"}`（`src/sessionprompt.ts`，模块里没有一个包名）。第一版是 `ground_id` 常量 + `extensions.ground` 布尔 + `renderGround()` 函数——三份 ground 专属知识长在一个「一切能力都是扩展」的前端里，等于把刚买来的抽象又绕回去；而第二个 renderer（workspace memory、repo policy）该是配置里多一行，不是这里多一个 `renderFoo()`。
3. **调用点只有一个：`sessionExtras()`**，`ensureSession` 里 draft 变成 session 的那一刻，**排在 `session_with` 之后**——事实在 `session new` 冻结它们之前的最后一刻才读。版本解析借的是 `sessionMemberOnce`（自带 draft 就地 build、否则取 `current`，与别的自带包同一条路），拿到的只是版本。
4. **失败不挡开场，但两种失败分开说**：包解析不出来 → `not composed in · /ext for what it said`（`/ext` 确实答得了）；`render` 自己失败 → **把它的话原样显示**（`renderSessionPrompt` 认真整理了 stderr/stdout，第一版却在调用点 `.catch(() => null)` 全吞掉，然后把人指向一个对这件事无话可说的屏幕）。两种都照开 session。
4. **没做**：没有 `/ground` 命令（它不是一个模式，没有可穿脱的东西）；没有把渲染结果画在 transcript 上（它是 system block，`/sessions` 的 composition 里看得见）；没有让它跟着每一步刷新（`--prompt` 冻在 header 里正是它该待的地方——重渲染一次就是把缓存前缀换掉）。

### T67 · §6 从一段规则写成一份设计语言，屏幕逐个对齐到它（2026-08-27）

**内核零改动**，`tui/` 十二个文件，**行为一个字没动**（按键、slash、状态机、审批链、driver policy 全不变）。起因是把整套屏幕当成一件东西看：单张看都对，摆在一起就有一层廉价感——而它不来自配色，来自**同一个决定在不同屏幕上做了两遍**。所以先把 §6 写成能逐条检查的九条法条 + 四张表（明度与颜色角色 · glyph 词表 · transcript 节奏 · 两类面的骨架），再拿它当审计单把每块屏幕过一遍。既有的审美决定（T18 四档明度 · T26 头行与三档空行 · T35「没有的东西不占列」· T38 动效只在一行 · T43 run 摘要与 thinking 离场）**是被收编进法条，不是被推翻**。

改的六处，每一处都是一条法条在某个屏幕上没被守住：

1. **一个左边缘**（第 2 条）。四个 composer 区对话框（`/mode` `/agent` `/with`、审批）是同一个东西的四份手抄，于是**一个对话框里有三个左边缘**：标题在第 1 列、光标 gutter 在第 3 列、hint 又在第 3 列却比它该领的标题右两格。新 `ui/Dialog.tsx`（`DialogTitle` / `DialogBody` / `DialogHint` + `dialog_gutter`）把骨架收成一处，规矩与 overlay 逐位相同：**盒子 padding 1、gutter 占第 1–2 列、一切内容从第 3 列起**（标题 glyph 恰好两格宽，`◈ ` 就是标题自己的 gutter）。
2. **`●` 在 transcript 面有两个意思**（第 6 条）。`● Reading emit.zig first.`（模型说的话）与它正下方的 `● Run 2 commands`（run 摘要）——两种永远相邻的行、同一个字形，NO_COLOR 下只差两格缩进。run 摘要改回 §4.2 一直写着的 `⋯`（thinking 与它说的是同一句话：**一段折起来的过程，你只被给到这一行**），并按 §4.2 全程 dim（原来 glyph 是 `accent.tool`，那是把「成功了、没什么可看」画成了一次调用的亮度）。
3. **`▾ N more below` 是方向不是状态**（第 6 条）。状态栏借了折叠记号，而 `▾` 在这个前端里的意思是「这张卡开着 / 光标在这一行」。新 glyph `below` = `↓`（ascii `v`），也正是 §4.5 一直写着的那个。
4. **`⚡ current` 说错了话**（第 1、6 条）。`/ext` 版本线上「store 指针指着哪个版本」用的是 `⚡`——而 `⚡` 是**一次能力的获得**。改成 `✓ current`、`ok` 色，与 `/model` 的 `✓ current` **同字形同颜色同含义**：这是现在生效的那一个。
5. **数字右对齐 + 一种时长**（第 2、7 条）。`UsageTable` 的 `9 uses` / `1041 uses` 与 `94% ok` / `100% ok` 左对齐是四条参差的边，而扫一列计数靠的是末位数字——数字按当屏最宽的那个补左空格，词跟着一起对齐；`/usage` 的 token 块同办法（后面那句 `· 88% of prompt` 降成 dim 的旁注，它本来就是关于那个数的话）。时长原本有**三种**写法：`WorkingStatus` 的 `1m40s`、`/tasks` 与后台卡的 `1m 05s`、还有内核报的 `41.8s`——`elapsedLabel` 现在就是 `state/tasks.seconds`，我们自己数的一律一种写法，内核那个是**引用**，不重排。
6. **两处会换行的行**（第 7 条）与**一处会盖住自己的面**（第 3、5 条）。卡片的 spill 指针（`full output → <长路径>`）与 `↗` 动作行都不过 `fit`；`/usage` 的主体不在 scrollbox 里，于是 token 块 + 工具日志一超屏，`OverlayFooter` 就**画在最后一行上面**（实测 `rxrefresh/·gEsc closees   100% ok`——正是 `ui/columns.ts` 顶上那段说的「空格底下留着上一帧的字符」）。主体收进 `scrollbox`（`flexBasis: 0`），`HelpView` 与 `TasksView` 早就是这么写的，`/usage` 是漏掉的那个。顺带 `/help` 的 footer 也改走 `OverlayFooter`（第 8 条：一个面只有一行这样的话，写在同一个地方；它原本是裸 `<text>`，窄屏会糊），并补上它第一组键的 `keys` 小标题——四组里只有它没有，读起来像标题的一部分。

**没做**：不动 pane / 布局（那是 `goals/tui-shell.md` 的 S1）；不加任何动效（第 9 条）；不改 `▎` 与 `›` 的现有分工（`▎` 是左规线与「就是这一个」，`›` 是输入点——两条都写进 §6.3 的表里，不是靠记）；不给 `/ext` 详情里那句 `lint · 0 uses · —` 改成表（它是一行事实不是一列数，等真有第二个读者再说）。**审批对话框的标题去掉了 `▎`**：`◈` 是「选身份/档位」的记号而它不是，颜色（warn）已经说完了这件事——`▎` 因此在 composer 区一个用法都不剩。

**测试**：`bun test` 500 pass（`tsc` 干净，内核未动）。四处断言随新样子更新，其中三处顺手改成守机制而不是守字形——run 摘要那条从 `toContain("● Run 2 commands")` 改成「那一行**不含**assistant 的 glyph」（它要守的本来就是这个）、`elapsedLabel` 的 `1m00s` 改成「与 `seconds()` 逐位相等」（一种写法才是被钉的东西）、`/usage` 的「两个值同一个起始列」改成「同一个**结束**列」（右对齐之后那才是对齐的定义）。三份快照重出（`/ext` 的 `✓ current`、run 摘要那一帧、`/help` 多一行小标题与新 footer）。

### T68 · S1a：pane 骨架——今天这块屏幕是新模型的退化形（2026-08-27）

**内核零改动**（`src/` 一个字节没动），`tui/` 五个新文件 + `App.tsx` 一处，**行为与外观零改变**：`bun test` 527 pass、**32 份快照零 diff**、`tsc` 干净。做的是 `goals/tui-shell.md` §5.4 的 **S1 前一半**：把 pane 树 + 焦点单一仲裁 + 鼠标路由引进宿主，现有屏幕改挂成 surface。不做 S2（plugin API T2 / chip），不做侧边栏（S1b）。

**尺子**：宪章 §5.1 说「宿主自己当第一个 consumer，API 才诚实」——所以验收标准不是"能分屏了"，是**分屏能力加进来之后屏幕上一个像素都没动**。今天这块屏幕必须是新模型的**退化形**（一个 pane），而不是新模型的一个特例。

**四块，四个文件**：

1. **`src/pane/tree.ts`——pane 树本体**（纯函数，不 import solid）。节点 = 叶（一个 surface）或 split（方向 + 比例 + 两个孩子）；`singlePane` / `setSurface` / `splitPane` / `closePane` / `resizeSplit` / `focusPane` / `layout` / `paneAt` / `moveFocus`。两条不变量由测试钉住：**`focus` 永远指着一个真实存在的叶**（关掉聚焦的 pane 时焦点交给兄弟）、**split 永远有两个孩子**（删掉一个就把 split 塌成另一个，"空 split"这个状态不存在，于是没有 consumer 需要处理它）。三个决定：① **方向词用 flexbox 的词**（`row` = 并排 / `column` = 上下），模型与画面不会用同一个词说两件事；② **`ratio` 是新 pane 的份额**，不是 first child 的——问侧边栏宽度的人问的是侧边栏的宽度，"`place` 有没有把这个数翻过来"正是那种会在两个调用点算出两种结果的算术，转换在 `splitPane` 里做一次；③ **关掉最后一个 pane 被拒绝**（原样返回），"没有 pane 时该显示什么"是宿主 policy 不是模型的性质，一个能表示"空"的模型让每个 consumer 都得处理一个谁都不想要的状态。
2. **`src/pane/registry.ts`——surface 注册表**。一个 surface = 一整屏内容 + 一个**属主**。三个字段现在就在，因为它们是宿主必须推理的东西而不是便利：`owner`（host / package——§1 推论一「包不许画 chrome」要可执行，"这是宿主的"就必须是表里的一个事实而不是命名约定）· `claimsKeyboard`（聚焦这个 pane 会不会把键盘从 composer 拿走——**这正是 `overlay.active()` 一直以来的含义**）· `onKey`（可选；宿主自带的面自己听 OpenTUI，这个字段是给 S2 的包的——它们装不了全局监听器）。撞名走 store roots 那条老规则（§3.3）：**首个持有者胜、输的被记下来而不是悄悄丢掉**；宿主先注册，所以没有包能把 `host:*` 从一块人必须信任的屏幕底下抽走。
3. **`src/pane/focus.ts`——焦点单一仲裁**。`resolveFocus(state) -> FocusOwner`：`dialog(with|agent|mode|approval)` → `surface` → `plugin-panel` → `browse` → `composer`。**顺序一个字没改**——T68 之前它是 `App.tsx` 里一串各自正确、却没有任何一处写出"顺序是什么"的 `if`；现在它是一个纯函数、一份能读能测的值，也是 S2 问"我的 surface 能拿键盘吗"时唯一要满足的东西（答案：只有人把焦点给了它、且没有 trusted zone 在场）。**修饰键不参与仲裁**（`modified` 是入参而不是调用方先过滤掉的东西——例外该写在它例外的那条规则旁边）：审批对话框在场时 Ctrl+C 仍要能杀掉那一步。**Esc / Ctrl+C 根本不出现在这个文件里**——它们是宿主注册的 keymap layer，在仲裁被咨询之前就答完了，「Esc/Ctrl+C 永远归宿主」因此是**结构上**成立而不是靠一条分支。
4. **`src/ui/PaneHost.tsx`——挂载与鼠标路由**。两条规则：**一个 pane 画成它自己**（单叶树渲染 surface 时**外面没有任何 wrapper box**，与它取代的 `<Switch>` 逐节点相同——这不是优化，这就是 S1a 的验收标准；一个 wrapper 就是旧布局没有的一个 flex 容器，而它把孩子的尺寸继承错了正是"外观没变"悄悄不成立的方式）；**命中测试就是 renderable 树**——split 里的 pane 各有一个自己的盒子、`onMouseDown` 挂在上面，盒子里任何一次点击都冒泡到它，于是**"点击落在哪个 pane"由画出它的那次布局决定，两者不可能各说各话**。`pane/tree.ts` 仍然建模几何（`layout` / `paneAt`），因为**方向性焦点移动是只有摆放才答得出的问题**，也因为 S2 的 surface 会要 pane 局部坐标——但一次真实点击的路由**不经过第二份可能与画面漂移的布局**。wrapper 永不认领事件：`ui/rows.ts` 已经定义了什么**是**一次点击（同一格按下并松开），聚焦一个 pane 是发生在按下那一路上的、严格更弱的一件事，不许挡住下面那一行也对同一次点击做出反应。

**迁移（`App.tsx` 一处，+177 −106）**：`state/overlay.ts` 的 `OverlayStore` **一个字节没改，也没有第二个真相**——它变成 pane 树的一个投影（`state/panes.ts` 的 `overlayAdapter`）。理由：那个 store 的真实内容从来不是"哪个 overlay"，而是**这一个 pane 显示哪个 surface**，而 `active()` 从来就是**那个 surface 拿不拿键盘**。于是 `kind()` 读树、`open()` 写树，每个调用点（`openOverlay` / `closeOverlay` / `shortcutLayerBlocked` / 三个 `createEffect` 的 composer 焦点条件）**拼写一个字都没动**。屏幕上那段 `<Switch>` 换成 `<PaneHost>`，八个 overlay 的 JSX **原样搬进** `ui/surfaces.tsx` 声明的九个 host surface 的 thunk 里（JSX 留在 `App`：这些屏幕每个要十来个 props、把它们穿过注册表只会买来第二套类型；一个 definition 是**一个身份加一个画它的 thunk**）。`useKeyboard` 那串 `if` 换成先算一次 `owner` 再分派——**唯一一处读信号而不读裁决的是 browse**：plugin panel **拒绝**了这个键时仍要落到 browse，仲裁器只报一个属主，而旧的链条里唯一不在第一个认领者处停下的就是这里，注释写明了。

**为什么 `claimsKeyboard` 不写成"surface 不是 transcript"**：S1b 的 sessions 侧边栏正是那种**画得出、聚得了焦、却没有理由拦住人打字**的面。写成"不是 transcript"会在它到来的那天变成一个 bug，而写成一个属主自己声明的布尔，那天什么都不用改。

**测试（+27，两份新文件）**：`test/panes.test.ts` 钉纯模型三样——树（操作不会留下画不出来的树；两个 pane 摆放的几何就是那条缝所在的几何；小到分不开的盒子给一个 pane 零格而不是撒谎）· 注册表（首个持有者胜；没注册的 surface 一个键都不认领——包加载失败不该能吞掉每一次击键）· 仲裁器（**顺序**本身；chord 越过所有认领者）。`test/panehost.test.tsx` 钉两条模型自己说不出的话：**单叶树与直接渲染那个 surface 逐帧相同**（对着一次**参考渲染**断言而不是对着一份存下来的帧——这样即使全套快照都围着一个 wrapper 重录过，它依然会红），以及**点击落进画在那里的那个 pane、且下面那一行照样收到同一次点击**。

**没做**（都是 S1b / S2）：侧边栏与任何新 UI（理想情况下 S1a 不产生新像素，所以 §6 九条这轮没有新的适用对象）· plugin API 的 T2 与 chip（`tui/plugin-api.d.ts` 一个字节没动）· detach / tab-in-pane / 浮动（§5.1b 写死的边界）· 分屏的按键与 `tui.toml` 语法（没有第一个 consumer 之前，一个开分屏的键盘手势是在给一个还不存在的布局起名字）。**给 S1b 的提醒**：`ui/rows.ts` 的 `onClick(action, stop = true)`（`/ext` 的 checkbox 是唯一一处）会 `stopPropagation`，所以点在它上面**不会**顺带聚焦那个 pane——真开出第二个 pane 时这是要补的一处，判据是"聚焦发生在按下那一路上"。

### T69 · S1b：sessions 侧边栏——pane 骨架的第一个消费者（2026-08-27）

**内核零改动**（`src/` 一个字节没动），`tui/plugin-api.d.ts` 一个字节没动；`bun test` 527 → 543 pass（新 16 条）、`tsc` 干净。做的是 `goals/tui-shell.md` §5.4 的 **S1 后一半**：第一个真实的 split，也是 T68 那套 pane 树 / registry / 焦点仲裁 / `PaneHost` 的第一次被使用。不做 S2（chip / 包的 T2 面）。

**尺子**：S1a 的验收标准是"分屏能力加进来之后屏幕上一个像素都没动"；S1b 的是**"侧边栏不是宿主里的一个新概念"**——它必须整个是"有一个 row split，第一个孩子显示 `host:sidebar`"，没有 `PaneHost` 的特判、没有第二套布局、没有一个 `if (sidebar)`。`state/sidebar.ts` 因此全是 `PaneTree → PaneTree` 的纯函数，宿主只拿着一个"人要不要它"的布尔去 reconcile。

**六块**：

1. **`state/sidebar.ts`——侧边栏是一次 pane 操作**（纯函数，`openSidebar` / `closeSidebar` / `sidebarRatio` / `resizeSidebar` / `sidebarWidth` / `sidebar_min_width`）。两个决定：① **`openSidebar` 带 `focusNew: false`**——这就是 T68 那句"侧边栏没有理由拦住人打字"落地的地方（见下面那条偏离）；② **`sidebarWidth` 用 `layout()` 量，不自己算** `round(width × ratio)`：第二份同样的算术就是第二个迟早会和画面吵架的答案，而窄宽变体的列宽全靠这个数。`PaneStore` 为此多一个 `apply(op)`——纯操作住在别处，store 只提供那一道通往 signal 的门，否则每来一个手势就要给 store 加一个动词。
2. **`host:sidebar` 是第二个 surface，不是 `host:sessions` 的第二次挂载**。两者宽度不同、画的东西不同，而**决定性的那一样是"显示它要不要拿走键盘"**——那是注册表里的一个字段，一个 id 只能有一个答案。
3. **窄宽变体在 `SessionsView` 里，不是第二个组件**（`variant="sidebar"`）：rows、光标、刷新、两次点击的法条全是同一份；两个组件就是这些全都有两个答案。变的只有宽度，以及纯函数 **`sidebarRowPlan`**——一行从外往里让位（钟 → verdict → `live` → `▎`），第一句话保底 8 格。理由写在函数头上：一行**就是**那一场的第一句话（T47），所以让位的只能是它周围的格子。**一处翻车**：`if (docked()) return dockedBody()` 一开始写在 `useKeyboard` **上面**，于是 rail 一个键都不认——`j`/`Esc` 全落空而光标照画（光标只看 focus）。现在那一行在 `useKeyboard` 下面，并且注释写明了为什么。
4. **三个入口**：`/sidebar`（裸的开关，`<percent>` 顺带改宽度并打开）· **`F8`** · **状态行行首的 `◧`**。为什么是 F8 而不是人人都会的 `ctrl+b`：composer 的 textarea 默认把 `ctrl+b` 绑成 move-left，而这个开关**永远有意义**，没法像 `closeTab` / `interrupt` 那样"没意义时把键让回去"——一次永久的抢键不该是缺省（想要的人在 `tui.toml` 写一行）。同理 `Ctrl+←/→`（pane 间移动键盘）挂的那一层 **只在不止一个 pane 时开**，平时它们仍是 textarea 的 word-motion。
5. **把手为什么在状态行行首**：`◧` 开的是屏幕**左边缘**那块 pane，而位置是终端仅有的四样语法之一，所以它只能在最左边；顺带让状态行也有了每个 list 行都有的那两格 gutter（§6.5"内容从第 3 列起"），mode chip 因此右移两格。还有一条不是审美的理由：`goals/tui-shell.md` §4 把 `below-left`/`below-right` 那条 chip 带留给**包**，而宿主 chrome 不排在扩展后面等位置（§1 推论一）——它在包永远够不到的地方。**它不表示开还是关**：侧边栏在不在，屏幕已经用四分之一的宽度回答了。<60 列时把手不画，因为那时侧边栏根本开不出来。
6. **状态：人要什么 vs 屏幕上是什么**。`tui-state.json` 记的是 `{open, ratio}` = **要什么**；窄终端（<60 列）自己把 rail 收起来，宽回去再放出来。把"收起来了"当成人的答案记下去，就把一次拖窗口变成了一个从没做过的决定。

**T68 点名的那个洞**（`ui/rows.ts`）：`onClick(action, stop)` 从此**只认领松开、不认领按下**。判据是 T68 自己给的那条——聚焦发生在按下那一路上，而 `stop` 要防的是**外层行动作**，行是在松开时才动作的。从前多停一次按下不花钱，因为行上面只有行；现在行上面是 pane，于是"在没聚焦的 pane 里点一个 checkbox"会把框打上而键盘没跟过来，而点一下正是"我在这儿工作"最明确的手势。外层照旧收到按下、记下起点、收不到松开，所以照旧不动作。回归测试验证过在旧代码上会红。

**偏离 prompt 的一处，写清楚**：prompt（与 T68 的预告）说侧边栏 `claimsKeyboard: false`；落地成 **`true`**。理由是这个字段自己的定义——"聚焦这个 pane 会不会把键盘从 composer 拿走"——而一个用 `j` 驱动的列表，诚实答案是会。写成 `false` 又要 `j/k/Enter/Esc` 能用，等于**输入框还在闪、而 `j` 被别人吃掉**：那不是折中，是陷阱。T68 真正要保的那句"没有理由拦住人打字"落在**焦点的放置**上而不是这个布尔上：`openSidebar` 用 `focusNew: false`，所以键盘只会因为有人送它过去才过去，`Esc` 送回来。连带三处：`overlayAdapter` 的 `kind()/open()/close()` 改读**主 pane**（哪个整屏视图在前面是主 pane 的事实，F2 不该开在键盘碰巧待着的那条 rail 里），`active()` 仍读**焦点 pane**（它答的是"输入框还有没有键盘"）；`handleGlobalQuit` 的 `overlay.active()` 改成 `overlay.kind() !== null`——整屏视图在前面时没有东西可停，Ctrl+C 是"离开"，而一条被聚焦的 rail 旁边 transcript 和它的 step 还在，那时 Ctrl+C 仍该走"清草稿 → 杀 step → 才是退出"那条收窄。

**顺手修的一个真 bug**：键盘**离开** pane 时输入框拿不回来。Solid 的 effect 在信号还在结算时就 flush，那一刻 composer 自己的 `disabled` effect 还没把 textarea 变回 focusable，于是从 effect 里发的 `focus()` 被拒——盒子变成"能用、空的、不听键"。别的每一条离开 pane 的路本来就手动通知 composer（`closeOverlay`），补的是 T69 新加的那两条（`goToPane` / `moveKeyboard`）。**另一件事没修，因为不是这一轮的**：点 transcript 空白处会让输入框失焦——单 pane、没有侧边栏、S1b 之前就如此。

**设计语言（§6 九条）**：新东西只有三样——rail、把手、rail 的 footer。① 颜色：把手开着 `accent.evolve`（可点的去处）/ 关着 `faint`（家具），一屏 accent 仍 ≤3；NO_COLOR 下把手形状不变而**状态由 rail 本身说**，没有只靠颜色区分的两件事。② 对齐：钟按当屏最宽的那个补齐（不然它不是列），marker 靠右成列，rail 的 gutter 两格、内容第 3 列起。③ 留白：**两个 pane 之间不画线**——这个前端只有一样有边框的东西（§6.1 第 5 条），所以边界只能是空气，而**一格空气不是边界**，rail 因此右侧留 2 格。④ 没有的不占列：footer 只在 rail 拿着键盘时画（那时那三个键才是真的），把手 <60 列不画，钟/verdict/live 放不下就整格消失。⑤⑥ 无新边框；新 glyph `◧` 已进 §6.3 表。⑦ 全部 `fit`，不换行。⑧ rail 有自己那一行 dim 的 `j/k · Enter · Esc`。⑨ 没有新动效。§6.5 上 rail 用的是 **overlay 那套骨架**（标题 · 一个空行 · 主体 · 底部一行），不发明第三种密度。

**测试**（`test/sidebar.test.tsx` 15 条 + `test/panehost.test.tsx` 1 条）。模型那半不开终端：开/关/再开的幂等、关掉时焦点交给谁、seam 两边都认同一个 `share`、`sidebarWidth` 与 `layout` 同源、`sidebarRowPlan` 的让位顺序与保底、**`overlayAdapter` 的两个 pane 分工**、`tui-state` 的半个 slot 也读得回。屏幕那半对着真 workspace 的真帧：rail 与 transcript 同屏且盒子照样收字、120 列多出钟而 80 列没有、窄终端不画且没忘记、记住的状态开屏就在、点两下换 session、**键盘只在被送进去时才在 rail**（`Ctrl+←` → `j` 动光标 → `Esc` 回来 → 草稿一个字没丢）。快照两帧（80 / 120），**先把帧里的钟停掉**（composition 卡的日期与 `just now`）——快照是拿来钉版式的，钉上一只走着的表就是每分钟红一次。

**给 S2 的提醒**：① 侧边栏是**第一个不是整屏、却会拿键盘的面**，包的 T2 面是第二个——`claimsKeyboard` 就是"聚焦时拿不拿"，别把它读成"是不是整屏"；"是不是整屏"今天由 `overlay_surfaces` 这张表回答，真需要时再给 surface 加字段，别把两件事挤进一个布尔。② 一个包的面要拿键盘，就必须像 `SessionsView` 这样**自己按 `mount.focused` 关掉自己的监听**：`useKeyboard` 是全局的，同屏两个面各听各的键会同时开火（`SurfaceDefinition.onKey` 存在正是为了让包不必装全局监听器）。③ 任何搬进 pane 的面都要**从 pane 拿宽度**（`sidebarWidth` 这条路），`useScreen()` 从现在起答的是终端不是它的盒子。④ 打开一个面 ≠ 把键盘送过去，这两件事分开写；送过去的那一半记得把输入框还回来（`goToPane`）。

### T70 · 用出来的五件事：丢焦点的空白、找不到的把手、反了的点击、不该在列表里的子场、只有键盘的 tab 条（2026-08-27）

**内核零改动**（`src/` 一个字节没动），`tui/plugin-api.d.ts` 一个字节没动；`bun test` 543 → 550 pass、`tsc` 干净。
S1b 之后第一次拿去真用，五条反馈全在宿主这一侧，全是"已经做出来的东西没被人找到 / 做的不是人以为的那件事"。

**① 点空白 transcript 会把键盘从输入框拿走**（S1b 之前就有，单 pane 也复现，T69 只是终于把它写进注释）。
根因不在我们这儿也不是玄学：**`ScrollBoxRenderable` 自己 `focusable = true`**，而 OpenTUI 的 `autoFocus` 在 mouse-down 上
**从命中的那个 renderable 一路往上找第一个 focusable 并聚焦它**（`dispatchMouseEvent`），于是 transcript 这只盒子是它每一格的那个祖先——
点最后一张卡下面的空白、点卡片头行折叠它，都会让 textarea 被 blur：框还亮着、光标还闪、打字没有反应。
**修法是 `focusable = false`，而这不是绕开而是这只盒子的实情**：这个前端从来没有靠过 scrollbox 自己的按键绑定——
PgUp/PgDn、Shift+End、browse 全走宿主 keymap 并作用在那个 ref 上，所以焦点在这里买到的唯一东西，就是把它从屏幕上**唯一需要焦点的控件**手上拿走的能力。
别的 scrollbox 不同案：它们各自住在一个本来就会拿键盘的 surface 里（overlay、docked rail），那里聚焦**正是**人要的。
回归测试没法看帧（什么都没变）——它点一下空白然后**打字**，断言字落在框里；验证过在旧代码上会红。
顺带 `test/sidebar.test.tsx` 那条"点 transcript 离开 rail"补了后半句：现在键盘**一路回到框里**，不是回到那只吞掉它的 scrollbox。

**② 侧边栏太隐蔽**（用户原话：完全没找到）。三处，都不新增一行屏幕：
① **≥100 列时把手说自己的名字** `◧ sessions`（窄屏退回纯字形，与 `sidebarRowPlan` 同一条让位规则；后面两格空气而不是 ` · `——
它是 host chrome、排在将来任何包 chip 之前，空气说"另一样东西"，关节说"下一样东西"）。
一个没人见过的字形 + 这一行最不被扫到的那一端 + 一块从没出现过的 pane = 三重不可发现，而**能被找到的控件是有名字的控件**。
② **Welcome 的 `/sessions` 那一行捎带说** `every session here · /sidebar docks the same list on the left`——
不给 rail 单开一行：那是同一份内容在一屏之内说两遍，而这本来就是"我在找我别的对话"时会读的那一行。
③ **tips 两条**（`/sidebar` 或 `F8` 或行首那个 `◧`；以及单击/双击）。tips 因此从常量变成 `tipsOf(glyphs)`：
其中一条**点名了一个字形**，而这个前端每个字形都有逐位对应的 ascii 降级——在画 `[` 的终端上印 `◧` 就是指着一个不在屏幕上的控件。
**没做**"侧边栏关着时 tab 条左端也放一个手柄"：tab 条只在 >1 个 tab 时存在（T22 那条"单 session 屏幕要和没有 tab 之前一模一样"），
而需要被发现的恰恰是**只有一个 tab 的第一次启动**——手柄放在那儿，正好在唯一要紧的场景里不存在。

**③ 单击 = 就地切换，双击 = 多开一个 tab**（用户预期与原实现正好反）。见 §5.4 那段：
`Enter`/单击走 `tabs.replace(当前 key, id)`（已有 tab 的前置它，所以**tab 条不因单击变长**），`t`/双击走 `tabs.open`。
`/resume <id>` 跟着 `Enter` 走（T45 就写死了它是"同一个动作的点名形态"）。
**实测结论：单击必须等窗口关掉，"先立即执行、双击到来时再补开 tab"在这里不成立**——不是手感问题是可组合性问题：
切换**消费掉的正是**双击要保住的那个 tab（切完这一场已在眼前，`onOpenTab` 只会把它选中），要救回来就得把刚替换掉的东西放回去，
而 draft tab 放不回去、session tab 要付一次 `session events` 重放。所以：一个手势一个动作，谁都不用撤销谁；
**不等的是光标**（落在按下那一刻，点击在同一帧有回应），等的只是那一次整屏内容的更换——350 ms 之后换整块屏，比 350 ms 之后打个勾要不刺眼得多。
第三次按下开新窗口而不是再触发一次。测试钉的是**两个手势是两个不同的动词**（双击那条断言 `onSwitch` 一次都没被叫到）——
这条断言恰好也是"立即执行"那个方案过不了的那条。

**④ sub-agent 的场默认不进列表**。判据、文案与过滤时机见 §5.4；这里只记两件事：
**判断只有一份**（`agents.ts` 的 `personaOf` + `persona_prompt_prefix`，`renderAgent` 拼 label 用的是同一个常量）——
两份 `startsWith("agent-")` 就是过滤和标签迟早各说各话；**过滤在建树之前**，否则被藏起来的父亲会把孩子留成缩进在虚空下面的一行。
rail 上那个 `◈` 是**倒数第二个让位的格子**（只比 `▎ 这一个` 早），因为它是这一行唯一说"这不是一段对话"的东西，而它只在人自己按了 `a` 之后才存在。

**⑤ tab 条：鼠标补齐 + 按 §6 整容**。`✕`（faint / 悬停 err / `stop` 只认松开，所以不会顺手把这个 tab 选中）与 `+`，
两个都是**已有的动词**（`tabs.close` / `startDraft`），不是第二条路。整容三处：
当前 tab 从"背景色 + `accent.user`"变成**`▎` 这个形状**（其余两格空白，名字仍同列起）——从前每个 tab 都戴 `⤷`，
而 `⤷` 是 sub-session 的字形，等于这一行上每一格都在说一件与它无关的事，且"哪个在前面"在 NO_COLOR 下无从分辨；
`▎` 那两格**非活动 tab 也占**（空白）：不是为了对齐（一条 strip 只有一行，没有列可对），
是为了**切 tab 时 tab 不要动**——只有活动 tab 付这两格的话，每换一次前台，它左边所有名字就整体移两格，
正是 T12/T47 那个"会跟着光标跑的右对齐格子"的同一个形状。
名字按剩余宽度均分并 `fit`（`stripPlan`），**既不换行也不溢出**：装不下时**按钮先于名字让位**
（`✕` 只是便利，`Ctrl+W` 才是那个动词；而名字剩一个字母的 strip 已经不在干它的活了）——
实测 60 列 5 个 tab、40 列 4 个 tab 都因此从"`+` 被切掉、最后一个 tab 断在半个字形上"变成整条装得下。
**写下来的那一个极限**：每个 tab 少于 `marker + 1 + gap` 列时不存在任何分配方案，那时照旧在边距上截断；
真要解就是 goals/tui-shell.md §4 给 chip 条写好的那条 `+k` 折叠，**这一轮没做**（它要有自己的点击行为，
而触发它需要终端窄到每个已开 tab 不足五列）。改前 `⤷ scripted-demo #1  ⤷ scripted-demo #2`，
改后 `   scripted-demo #1 ✕  ▎ scripted-demo #2 ✕  +`，60 列 5 个 tab 是 `   claude…  ▎ claude…    claude…    claude…    claude…  +`。

**设计语言（§6 九条）**：新增的可见物只有三样——把手的标签、tab 条的两个按钮、rail footer 的第二种内容。
① 颜色：`✕` faint→err 只在悬停时（它是这一行唯一会丢掉东西的控件，该在要被按的那一刻才说话，而不是一直亮着），一屏 accent 仍 ≤3。
② 对齐：tab 名均分 + `fit`；`▎`/两格空白让所有 tab 名同列起；把手标签后两格空气与状态行其余部分的 ` · ` 关节**刻意不同**。
③ 留白：没有新的空行规则。④ 没有的不占列：把手标签 <100 列不画、`✕`/`+` 无回调不画、rail footer 无话可说时整行不画、隐藏数为 0 时那句不写。
⑤ 无新边框。⑥ **新 glyph `✕` `+` 已进 §6.3 表**，并写明它们只活在 tab 条这一面上（`⊘`/`✗` 是 transcript 里"发生过什么"，这两个是按钮）。
⑦ 全部 `fit`，不换行。⑧ 每面仍只有一行 dim 的"我能做什么"——rail 那行现在由 `railFooter` 按宽度选，隐藏计数塞进整屏那一行的键行末尾而不是另起一行。⑨ 没有新动效。

**测试**（543 → 550 pass）：`test/mouse.test.tsx` 10 → 12（新：点空白之后**打字**、落在框里——这条**验证过在旧代码上会红**；
tab 条的 `✕`/`+`/`▎`；`stripPlan` 的**不变量**"画出来的一切都在两条边距之内"，而不是钉某个具体宽度。
重写：单击/双击那条，双击那半断言 `onSwitch` **一次都没被叫到**——这条恰好就是"立即执行单击"那个方案过不了的那条），
`test/sidebar.test.tsx` 15 → 19（`partitionSessions`/`personaOf` · `railFooter` 的宽度选择与"计数比键活得久" ·
单击就地切且 strip 不变长 · 双击多一个 tab · 隐藏计数与 `a` 的开关 · rail 的让位顺序多一格 persona），
`test/workingstatus.test.ts` 的 `pickTip` 多一条"每条 tip 说的是这套字形"（ascii 下那条不许印 `◧`）。
跟着改的：`/resume` 的回执文案、`/sessions` 的键行、tab 条不再有 `⤷`、Welcome 的 `/sessions` 说明。两张快照更新。

### T71 · S1c：每个 tab 一个 workspace——目录浏览器、无项目 session、按目录分组的列表（`goals/tui-shell.md` §5.3b，2026-08-28）

**内核零改动**（`src/` 一个字节没动），`tui/plugin-api.d.ts` 一个字节没动；`bun test` 550 → 571 pass（新 22 条）、`tsc` 干净、**既有 33 份快照里只有 `/help` 那一份变了**（多了一条命令，一条命令不出现在那一页上就等于不存在——`commands.ts` 的契约）。做的是 §5.3b 的六点。

**尺子**：S1b 的验收标准是「侧边栏不是宿主里的一个新概念」；S1c 的是**「跨目录不是宿主里的一个新概念，是 `Workspace` 这个已经存在的参数换了个出处」**。`nulya/cli.ts` 从第一天起每个调用就带着 `Workspace`；被 `createTabStore(ws, …)` 收成全局的是它，而不是内核里的什么东西。所以这一轮的形状是**下放**，不是新增：`TabCommon.ws`，然后把 `props.ws` 在每一个「对某一场 session 动手」的调用点换成 `ws()`。

**八块：**

1. **tab = (workspace, session)**（`state/tabs.ts`）。`ws` 是 tab 的字段，`open`/`replace` 的「是不是已经开着」比**两半**（两个目录是两份 session 存放处，只问一半正是让错的 tab 被前置的方式），`release` 用 tab 自己的 `ws` 去 `discardIfUntouched`（对着进程的启动目录去 discard 要么落空、要么点名别人的文件），`materialize` 用 `draft.ws` 去 `session new`——**那一行就是一个 tab 的目录成为真的地方**。session tab 的目录永不改变；draft 可以被重新指向，新动词 `retarget` 换掉整个 tab 对象而不是改一个字段（`ws` 是通过 `tabs.active()` 到处被读的，改字段等于让每一处读到新值而没有一处被通知）。
2. **三张按目录的表**（`App.perWorkspace`）：`@` 路径索引、skill 目录、包命令表——它们都是**关于一个目录**的。按 `ws.dir` 建一次留着，不是每次读重建：路径索引要走一遍仓库，另外两个各要 spawn 一次二进制。`sessionMemberOnce` 的缓存键同理多了一维（同一个 id 在两个目录里诚实地可以是两个版本，store 搜索顺序是 workspace 的）。
3. **目录浏览器**（`browsedir.ts` 纯函数 + `ui/overlays/DirBrowser.tsx`）。**overlay 而不是 composer 对话框**：§6.5 把这条线画在一个地方——输入框上面的对话框永不许超屏，而一个目录的列表显然会，所以它拿 overlay 的骨架（标题 · 一个空行 · 主体 · 最后一行 dim 的键）并且主体是 scrollbox；标题**不带 glyph**，它是一个**地方**。**只有一个动词**：`Enter` 永远拿光标那一行（目录进去，`no project`/recent/`use this directory` 选定）——两个显然的动词会打架，而**打字把光标放到 `use this directory` 上**这一条让「在输入框按 Enter」和「在一行上按 Enter」变成同一次击键做同一件事，不是两条要分开记的规则。路径框全程持键盘（能粘贴路径是终端用户第一个要的东西），所以光标只认 `↑↓`——`j`/`k` 是路径里的字母。纯函数那半（`expandPath` / `resolveTyped` / `visibleChildren` / `browserRows`）不碰磁盘也不碰终端，于是「在这个前缀上会画出哪些行」是一个测得出的问题。**打字是收窄而不是清空**：`~/src/nul` 列 `~/src` 里以 `nul` 开头的，这正是「打几个字、然后点」能成立的原因。
4. **无项目 session**：家 workspace = `<NULYA_HOME | ~/.nulya>/home/`，经 `userConfigDir` 解析（`NULYA_HOME` 只有一处读，测试的 preload 因此带得动它）。**不是 `~` 本身**，理由是结构性的而不是整洁：`~/.nulya` 是 user 层，塌在一起会让 user extension store 被内核 trust gate 误认成未信任的 workspace store 而**拒开 session**（DESIGN §9）。往下一层，两层还是两层。这一场**整段跳过 `[extensions] session_prompts`**：那些 renderer 画的是项目（布局、instruction 文件、这个分支、这棵工作树），而 `no project` 的答案正是「没有项目」——每一段都会是空话，而且它进的是缓存前缀、每一步都在付。**不是「问了然后忽略」**：这里没有让它答对的东西。测试用一个**不存在的** renderer 把这条钉住：普通 workspace 会说 `not composed in`，家 workspace 的**沉默**因此是「那个循环没跑」的证据而不是「碰巧成功了」。
5. **列表按 workspace 分组**（`SessionsView.groupedRows`）。打开的 tab 的 workspace 全列，每组各跑一次 `session list --json`（一个目录答不上来变成一个空组加一句 notice，而不是整屏没有——别的组还是真的）。**只有第二个 workspace 出现时才有组头**：单 workspace 的屏幕逐位等于 T70 结束时那一帧，快照钉住了这一点。空组也保留自己的组头——一个刚走进去还没说过话的目录，恰恰是最需要看见它在那儿的那个。组头是**画得出但停不上去**的行（`nextSelectable`）：`Enter` 在组头上没有事可做，而一个会停在按不动的行上的光标是要按两次的光标。组头的 dim 全路径在放不下时**整个不画**（`min_path`，rail 上就是这样）——`C:\U…` 不是消歧，是那个真正干活的词前面的四格噪音。
6. **信任与开屏流程按 workspace 首次进入时走**。launch workspace 仍由 `main.tsx` 在裸终端上问——那一刻还没有屏幕，那仍是对的地方；此后**第一个进入某个目录的 tab** 触发 `enterWorkspace`，用的是同一批纯函数（`planProjectStore` / `planProjectAgents` / `planCheckout`），差别只在答案在哪儿给。`ui/CheckoutPrompt.tsx` 是输入框上面的对话框、**trusted zone**、在 `resolveFocus` 里排在最外层——它是唯一一个**授予权限**而不是选一样东西的对话框。它一个字都不自己写：文案、键、每个键的含义全是 `planCheckout` 的，所以两处问法不可能漂移成两笔不同的交易。`syncStores` 因此收了两个参数（`where` + `SyncPlan`）而不是复制二十行。内核 trust gate 的硬拒照旧原样显示在那个 tab 里（`refusal`，T46 那条通道一个字没改）。
7. **recents 在 user 层**（`state/recents.ts`，`tui-recents.json`）。为什么是第二个文件而不是 `tui-state.json` 的一个键：那个文件在其它每一处都是 **workspace 层**的事实，而这一条是**关于好几个目录**的——一份别的目录的清单不能住在其中一个目录里面（`trusted-stores.jsonl` 因为同一个理由在 user 层）。**建场成功时才记**，浏览到不算。家 workspace 不记（它有恒定的第一行，再来一条就是同一个地方被给了两次）。
8. **持久与恢复**（`tui-state.json` 的 `tabs`）。tab 是一对所以记也记一对：一个 id 说不出它是从哪个 `.nulya/sessions/` 里来的。恢复**只做第一个之后的那些**——第一个仍由这一趟启动决定（`--session`，否则 draft，T22），所以单 tab 的屏幕逐帧不变，而把四场对话开在两个仓库里的人回来时东西还在原处。恢复不创建任何东西（draft 不记，文件已经不在的 session 跳过），写是一个普通 effect 而不是退出时保存：`Ctrl+C`、被杀的终端、崩溃都不走退出路径，而一份只在干净退出时写的记录，恰好在最需要它的时候是错的。

**设计语言（§6 九条）**：新的可见物只有四样——浏览器整面、组头、workspace chip、checkout 对话框。① 颜色：`no project` / `use this directory` 用 `accent.evolve`（可点的去处），`..` 用 `faint`（家具），组头名字 `accent.evolve` + 路径 `dim`，checkout 整行 `warn`（这个前端里「等你回答」的那一档）；一屏 accent 仍 ≤3。② 对齐：浏览器每行 gutter 两格、内容第 3 列起，`▪` 成列在右边距；组头与 session 行同一个左边缘。③ 留白：不发明第三种密度——浏览器是 overlay 那套（标题 · 空行 · 主体 · 底部一行），checkout 是对话框那套（标题 · 主体 · 一行键，不空行）。④ **没有的东西不占列**：workspace chip 只在说得出新东西时存在（第二个 workspace 在场，或这个 tab 是 `no project`），组头只在有第二组时存在，组头的路径放不下就整个不画，`..` 在文件系统根上不存在。⑤ 无新边框。⑥ **新 glyph `▪` 已进 §6.3 表**，并写明它为什么**不是** `⚡`（那个说的是「刚刚获得了一样能力」）。⑦ 全部 `fit`，不换行；快照断言了每一行都在两条边距之内。⑧ 每面仍只有一行 dim 的「我能做什么」。⑨ 没有新动效。

**测试**（`test/workspace.test.tsx`，22 条）。模型那半不开终端：家 workspace 的解析经 `NULYA_HOME`（且**不是** `~/.nulya` 本身）· `expandPath` 的 `~` / 盘符 / 相对 · `resolveTyped` 的收窄与结尾分隔符 · `browserRows` 的四条（`no project` 恒第一、`..` 段首、点目录不列、同一个地方不出现两次）· recents 的读写与「家 workspace 不记」· `groupedRows` 的「一个 workspace 没有组头 / 第二个才有 / 空组保留组头」与 `nextSelectable` 跨过组头 · `promptLines` / `choiceHint` 只是把 plan 重讲一遍。屏幕那半花真二进制：**`/cwd` 之后 session 落在那个目录里、这边一场都没有**（S1c 的全部主张）· `no project` 落在 `NULYA_HOME/home` 且不问 renderer · `+` 继承 front tab 的目录 · 记住的 tab 带着自己的目录回来 · 文件已经不在的那条被跳过 · 浏览器 80/120 两帧快照（临时路径**按等宽掩码**再存——快照是拿来钉版式的，一个会缩短行的掩码就是钉了一个没人见过的版式）。

**给 S1d（`goals/tui-shell.md` §5.3c，sub-agent pane）的接口提醒**：① 那棵「tab 内容区自己的 pane 树」要挂在 tab 上，而 tab 现在已经是一对了——`TabCommon` 是它的家，和 `ws` 并排；② 子 pane 的 observer transcript 必须用**父 tab 的 `ws`**（委派出去的子场就在那个目录里，`navigate.openSession` 这一轮已经按这条改了）；③ `openWorkspaces()` 是「屏幕上有哪些目录」的唯一答案，pane 树多一层不该给它第二个；④ 焦点仲裁器已经有 `checkout` 这一档在最外层，S1d 的 pane 走的仍是 `surface` 那一档，不需要新的枚举值。

**没做**：pane 树里的 workspace（一个 tab 的所有 pane 共用它的目录——S1d 的子 pane 观察的是这一场委派出去的子场，同目录）· 插件宿主仍按**启动目录**加载与 `extRun`（`createPluginHost` 是每进程一个，契约上就是这么写的；把它变成每 tab 一个是 S2 的事，那时 `tui/plugin-api.d.ts` 才会动）· 跨 workspace 的 `session list` 合并（每组各答各的，内核一次只投影一个 `.nulya/sessions/`）· 目录浏览器的新建目录 / 文件预览 / 多选（§5.3b 明说不做）。

### T72 · S1d：sub-agent 视图从属于父 tab——两层 pane 树，一个 portal（`goals/tui-shell.md` §5.3c，2026-08-28）

**内核零改动**（`src/` 一个字节没动），`tui/plugin-api.d.ts` 一个字节没动；`bun test` 572 → 582 pass（新 10 条）、`tsc` 干净、**既有 35 份快照里只有 `/help` 那一份变了**（多了 `ctrl+up` / `ctrl+down` / browse 的 `t` 三行，页面因此长了三行、那个测试的视口从 86 抬到 90——它的注释早就写着"tall enough for the whole page"）。做的是 §5.3c 的五点。

**尺子**：S1b 的验收标准是「侧边栏不是宿主里的一个新概念」；S1d 的是**「两层树不是两套机制」**——`PaneHost`、命中测试、焦点仲裁各自仍然只有一份实现，被用了两次。

**架构：两棵树，一个 portal。**
① **app 树**（`App` 自己那个 store）holds 跨 tab 的东西：sessions 侧边栏，以及**一个 portal 叶** `host:tab`。
② **tab 树**（`TabCommon.panes`，挨着 `ws`）holds 属于这场对话的东西：transcript、当前在前面的整屏视图、任意个 sub-agent pane。
③ 它们只经**一个 surface id** 相接：portal 这个 surface 的 render 就是 `<PaneHost tree={前台 tab 的树}>`——**同一个组件递归用一次**，于是挂载、鼠标路由（split 里的每个 pane 各有一个盒子，`onMouseDown` 挂在上面、不 stop，所以内层先聚焦 tab 内的 pane、外层再聚焦 portal，两次赋值同一件事）、以及「单叶树画成它自己、外面没有 wrapper」这条 S1a 的验收标准，全部原样继承。今天没有 sub-agent 的屏幕因此是 app 单叶 → portal → tab 单叶 → transcript，**一个 wrapper 都没有**，快照零 diff 正是这条的证据。
④ **焦点只多一跳**：`state/panes.ts` 的 `focusThrough(app, tab)`——app 树指着的叶，除非那是 portal，那就再往里一跳。**它是唯一知道两棵树是嵌套的函数**；`overlay.active()`、composer 的 blur、`resolveFocus` 的 `keyboardPane` 全读它，`pane/focus.ts` **一个字没改**（S1d 走的仍是 `surface` 那一档，T71 的提醒说对了）。
⑤ **方向移动由内往外**：`moveKeyboard` 先在 portal 的盒子里问 tab 树，动不了才问 app 树。所以 `Ctrl+→` 从 transcript 到旁边的 sub-agent，`Ctrl+←` 从 sub-agent 会**先经过** transcript 再到侧边栏，而不是从它头上跳过去。portal 的盒子由 app 树自己的 `layout` 量出来（`sidebarWidth` 的同一条纪律：第二份同样的算术就是第二个会跟画面吵架的答案）。
⑥ **为什么不做一棵大树**：那样每个叶子都要带一个「我跟不跟前台 tab 走」的标记，而每个操作都得尊重这个标记；两棵小树谁都不需要它，因为这个问题根本不会被问到。**overlay 也因此下放到 tab 树**——F2 在这个 tab 开 `/ext`，不该动另一个 tab 正在看的东西。

**pane 里装的是什么**：`state/tabs.ts` 的 `SubView` = 一个 tab 得到的全套（`SessionState` + `Attachment` + `TaskWatch` + 同一个 `hydrate` 的 header/contributions），**减掉 tab 条**。observer 不是这里选的——`driven: false` 正是「在这儿打开的、不是在这儿创建的」那一档已经传的值，角色由租约说了算（§5.6）。`watch(pane, id, label)` / `unwatch(pane)` 挂在 `SessionTab` 上，`release` 顺手 dispose 它们：委派没有第二个存在的地方，关掉对话就是关掉看它的窗。**一次注册服务所有 pane**：surface id 是 `host:subagent`，view 按 **pane** 反查（mount 本来就带着 pane id）——按 session id 注册的话，两个 tab 看同一场就是「首个持有者胜」，第二块 pane 什么都画不出来。

**设计语言（§6 九条）**：新的可见物只有三样——分界线、归属行、pane 的那行键。① 颜色：`⤷` 用 `accent.evolve`（去处），归属的话 `dim`（**关于**这块 pane 写的话），`✕` faint→err 只在悬停时；一屏 accent 仍 ≤3。② 对齐：row split 时子面在竖线右边留一格空气、column split 时**一格都不留**——上下叠的两个 transcript 必须共用同一条左边缘，差一列就是 §6.2 那条最该量的粗糙。③ 留白：不发明新密度，pane 里就是 transcript 自己那套（§6.4）。④ **没有的东西不占列**：那行键只在这块 pane 拿着键盘时画；`Welcome` **离开了**没有输入框的 transcript（判据就是 `onCommand` 在不在——欢迎屏是输入框的邀请，一个说不出话的面没有东西可邀请），所以刚开出来还没 replay 完的 pane 是空的而不是一屏 slash 命令。⑤ **边框**：这是这个前端第二样带 box-drawing 的东西，理由写在 §6.1 第 5 条自己的措辞里——「归属需要被说出来」的时候才用，而侧边栏那条空气分界说的是两个**独立的地方**（T69），这条说的是**从属**；**一条边不是一个框**，整屏仍然只有输入框一个「看起来像控件」的东西。⑥ 无新 glyph：`⤷` 与 `✕` 各在 §6.3 表里多写了一句它的第二处。⑦ 全部 `fit`，不换行。⑧ 每面一行 dim 的「我能做什么」。⑨ 没有新动效。

**两条键**：`focusUp` / `focusDown`（`ctrl+up` / `ctrl+down`）。不是补齐对称，是**窄屏上子面在上下**——只给左右，恰好在最需要键盘的那些终端上到不了那块 pane。与 `focusLeft/Right` 同一层，仍然只在**不止一个 pane**时才认领这四个键（`paneCount()` 现在数两棵树，portal 只算一次）。

**测试**（572 → 582）。模型那半不开终端：split 落在 transcript 之后且不抢键盘 · 100 列是那条分界线（≥ row，< column） · 方向从树上读回来而不是从开的时候记住（终端后来被拖窄，不能留一条身后没有邻居的线） · 关掉聚焦着的子面之后焦点仍指着一个真实存在的叶 · **`focusThrough` 的两种答案**（portal → 往里一跳；侧边栏 → 自己答） · 两个 tab 的树互不相干 · 归属那句话。屏幕那半对着真 workspace 的真帧：120 列左右分（断言**同一行**上既有父面的链接行又有那条竖线——那是 row split 唯一的签名）+ 输入框照样收字 · 80 列上下叠（归属行**上面一行**是横线，且没有任何一行同时有父面内容与竖线） · `Ctrl+→` 进去、那行键出现、`Esc` 关掉且**键盘一路回到框里** · 一个 tab 记得自己的布局（`/new` 开第二个 → 子面不在，`F4` 回来 → 还在），`Ctrl+W` 关掉父 tab 连它一起走。两张快照（120 / 80），**先把会走的东西掩掉**（session id 与日期，按等宽掩码）。既有的那条「`Enter` 开成第二个 tab」改成 `t`，断言一字未减——两条路都还在，只是主次换了。

**偏离 prompt 的两处，写清楚**：① prompt 说「保留显式开成 tab：卡上第二个动作或修饰键」——落地成 **browse 的 `t`**，卡上不加第二行。理由是这一行的成本是**每一个委派卡都要付**的两行几乎同文的链接，而 `t` 在这块屏幕上已经是「给它一个 tab」的那个词（T70 的 `/sessions`），`/help` 里也就多一行而不是多一个概念；修饰键点击则被否掉，因为终端对 modifier+click 的支持参差，而这条出路必须在每个终端上都在。② prompt 说 pane 头一行写 `⤷ <agent> · <d-id> · observing`，我把 `observing` 定成**常量**而不是跟着 `attach.role()` 变：这块 pane 结构上就是只读的（底下没有输入框，什么都送不出去），而租约角色是世界的状态、会在背景任务跑完的那一刻翻成 `driving`——那个词在这里读起来像许可。租约要说话的地方是状态栏的 `observer · driven elsewhere`（§5.6），不是这一行。

**没做**：pane→tab 提升手势（§5.3c 点 2 说「或后续做」，第一个真实需求还没出现）· 子 pane 落进 `tui-state.json`（观察面是临时的：它跟着一次「我想看看那个」而来，重开一场时那个委派多半已经结束，恢复它等于替人做一个他没做过的决定；tab 的 `tabs` 状态照旧只记 tab）· 拖拽调整 seam（没有第一个 consumer 的手势）· 子 pane 自己的 workspace（一个 tab 的所有 pane 共用它的目录——`openWorkspaces()` 因此仍然是「屏幕上有哪些目录」的唯一答案，T71 的提醒说对了，它一个字没改）。

**给 S2 的提醒**：① 包的 T2 面走的是**同一条路**——注册一个 surface，让 tab 树的一个叶指着它；`host:subagent` 就是宿主自己当第一个 consumer 的那个例子（按 **pane** 反查内容、`claimsKeyboard: true`、自己按 `mount.focused` 关掉监听）。② 但它是**宿主自己的面**，所以还留着一个 S2 必须补的洞：包的面装不了全局 `useKeyboard`，键要从 `SurfaceDefinition.onKey` 走——那个字段从 T68 起就在，今天仍然零 consumer。③ 一块 pane 的宽度**从 pane 拿**（`panes.boxes(portalRect())`），`useScreen()` 答的是终端；S1d 又多了一层，所以「portal 的盒子」是包的面该问的那个矩形。④ 打开一个面 ≠ 把键盘送过去（`focusNew: false`），送过去的那一半记得把输入框还回来。

### T73 · 表格不再闪：markdown 的宽度是一个数，不是一个百分比；顺带把鼠标指针交回给屏幕（2026-08-28）

**内核零改动**（`src/` 那半是另一件事，见下），`tui/plugin-api.d.ts` 一个字节没动；`bun test` 582 → 587 pass（新 5 条）、`tsc` 干净、既有快照零 diff。

**症状**：resume 一场带 markdown 表格的 session，表格里的一格**一会儿在同一行、一会儿换行，一直闪**。

**是 OpenTUI 的 bug，判据不是「闪」而是「同一个宽度下布局不唯一」**。78 列上直接开，与从 100 列缩回 78 列，画出来的是两张不同的表；渲染树把责任指得很死——`MarkdownRenderable w=75` 里装着 `TextTableRenderable w=76`，**子比父宽一列**。`TextTableRenderable`（markdown 的表格块）经 yoga 的 measure func 把列宽 fit 一次就缓存住（`_cachedMeasureLayout` / `_layoutDirty`），而它自己的 `width` 不变、`onResize` 不触发，所以**空间后来变窄它不会重新 fit**——第一趟布局时 scrollbox 的竖直滚动条还没占掉那一列，表格按宽一列定了列宽，此后只有一次真正的 resize 才会重算。**闪**是这条与滚动条的回路：错的列宽给出错的行数，行数决定内容高不高过视口，高度决定滚动条在不在，滚动条决定那一列在不在——两套列宽于是交替。

排除项都实测了：不在 scrollbox 里不复现 · 同样内容的**散文**在同一个 scrollbox 里 stable（只有表格有 measure-func 这条路）· `clearCache()` / `refreshStyles()` / 重设 content 都修不好 · **升级没用**（0.5.9 的 `rebuildLayoutForCurrentWidth` 与 0.5.3 逐字节相同）。

**修法：`<markdown>` 的 `width` 必须是一个数**。布局派生的写法一律失败（`100%` / auto / `flexGrow` / `alignSelf: stretch` 全都一样），只有布局开始之前就定下的数字稳定，而数字变了表格**会**跟着变。数从哪来是这条改动真正的问题——`useScreen()` 答的是终端，而一张卡活在 pane 里、侧边栏拿走它四分之一（T72 给 S2 的提醒 ③ 就是这句话）。所以新的 `ui/measure.ts` 的 `boxWidth()` 问**盒子自己**：每个 renderable 在自己排出来的尺寸变化时都 emit `resize`，一个 body 一个监听，**没有第二份布局算术会跟画面吵架**（与 `App` 那句「rows below 只有盒子自己是诚实的来源」同一条纪律）。代价是一帧：resize 之后 body 先按上一个宽度画一次。那本来就是它每时每刻的状态，区别是现在它会自己纠正。

两个 consumer：`AssistantTurn`（顺带把散文那条 `screen - 4` 也换成量出来的宽度——那个数在侧边栏开着时宽了四分之一，只是软 wrap 把它兜住了没人看见）与 `MarkdownToolCard`。

**留下的一处、说清楚**：内容高度正好卡在滚动条阈值上（差一行）时，**滚不滚**仍取决于怎么走到这个宽度的——两个自洽的定点，各自稳定，不再交替。要抹掉它得让滚动条那一列**恒占**，那是一个设计决定（一条永远画着的轨道），不是一个 bug 修复，所以没做。

**测试**（`test/markdown.test.tsx`，3 条）：表格的右边框在框里（每个宽度、开着和不开滚动条两种高度）· 同一个宽度画同一张表，无论是直接到的还是经 resize 到的（**在旧代码上会红**，验证过）· 没人碰的屏幕不变（这条旧代码也绿——交替要终端自己的帧循环，测试渲染器只在被要求时画；它守的是人真正看见的那条性质）。列的具体位置一个都没断言：那是 OpenTUI 的事。

**鼠标指针（同一条改动里的第二件事）**：终端默认在整个窗口里画文字光标，于是 transcript、tab 条、每一行可点的东西上，指针都在说「这里有字可以选」。**唯一说对了的地方是输入框**。杠杆是 OSC 22（kitty 起的头，ghostty / wezterm 跟着），空名字 = 交回终端自己的默认。OpenTUI 有这个 API（`renderer.setMousePointer`），但 **0.5.3 与 0.5.9 上调它一个字节都不发**（实测：teardown 时发一次空的，请求一次也不发），所以字节由 `ui/pointer.ts` 自己写：开屏 `default`、进输入框 `text`、离开 `default`、退出交回。**去重是承重的**——`onMouseOver` 每跨一格就 fire 一次，不去重就是按鼠标移动的速率往线上灌转义序列。只写给真终端（`bun test` 下 stdout 是管道，什么都不写）。真 pty 里录到的就是 `default → text → default`。最后一句话仍在人的终端配置里（kitty 的 `pointer_shape_when_grabbed`）。

**内核那半（`src/`，与 TUI 无关，同一轮）**：`ext build` 撞上「manifest 解析得了、但它点名的文件冻不进去」（system prompt 不是 UTF-8 / 太大 / 不存在，skill frontmatter 坏了，声明的 entry 或前端模块没写）时，答的是一整屏 Zig 栈回溯——`isDraftFault` 早就列全了这些错，但只有 `ext sync` 用它。现在这个动词也用它，答一句话。**理由是落点**：这些错真正的代价是一场 session 每一步都被 provider 400，而作者站着的地方是 build。顺带修掉它暴露的一处泄漏：`integrity.collectPackageSnapshot` 的 `errdefer` 只释放了条目内容、没释放列表自己的缓冲，而 `ext sync` 会在一个进程里走过每一个坏 draft。两条测试都验证过在旧代码上会红。

### T74 · 一场什么都没说过的 session 不是一行（2026-08-28）

**内核零改动**；`bun test` 587 → 588 pass、`tsc` 干净、一份快照变了三行。

`/sessions` 与侧栏列的是 `session list --json` 的全部投影，于是 `events == 0` 的 session 也占一行——**header 有、ledger 一条事件都没有**，进程被杀在 `discardIfUntouched` 之前留下的空壳，打开它是一屏空白。T22 之后新消息本来就冻一场新 session，所以少列它不丢任何东西。

**判据只有 `events === 0`**，一处实现：`sessionKind(entry)` 答 `own` / `delegated` / `empty`，`partitionSessions` 由它分桶，`groupedRows` 由它过滤。**空的排在第一位**——一场空的委派场先是空的，不然「有一场对话你没看见」那个计数里会混进没有对话的行。

**与 `a` 那条规则的区别写在类型里**：委派场藏起来是**有键可以翻出来的**（那是真的对话，只是不该默认占满列表）；空场没有键——那个键会掀开一批什么都没有的行。所以它只被**数出来**：rail 底下那行多一段 `N empty`（宽度不够时它第一个被让掉，因为没有键要教），整屏视图的键行多一句 `N empty sessions not listed`（`a` 开着关着都说，它不属于那个键切换的两类）。标题那个 `sessions · N` 仍是**库里有多少**——与今天藏着委派场时的行为一致：标题说库，底下那行说没画什么。

**没有做的**：删掉它们（内核只 append，前端更不该删文件）· 给它一个键（见上）· 把「inbox 里已经有一条消息、但还没有哪一步把它排干」也算进来（那种 session 也确实 `events == 0`，窗口只有一步之长，而 `/sessions <id>` 与 `nulya session list` 照样到得了它——与委派场那条「什么都没有对内核、对 `session list`、对 `/sessions <id>` 隐藏」同一句话）。

**顺带修掉一条靠巧合通过的测试**：`/resume` 那条用的是 `pressKey("escape")`，而它打出去的是 **escape 这六个字母**——`a` 切了委派场的显示、`n` 开了一个新 tab，看起来像是关掉了列表。此后 `/resume <id>` 的字符继续落在列表上，最后那个 `Enter` 打开的是**光标所在的行**，而那一行恰好就是它想要的那场，于是它一路绿着断言了一件没发生过的事。改成 `pressEscape()`。列表变短之后它才露出来（没有行可选，Enter 什么都不做）——这类测试的真实成本就是这样：它不响的时候，你不知道它在测什么。
