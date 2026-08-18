# Nulya TUI — 设计与计划

> **状态：T0–T9 与 T11 全部落地。** 内核侧只有三处：`session step --stream`（纯观测）、`session new --parent` 的 fork 语义 → [DESIGN.md](DESIGN.md) §14/§11，与 `NULYA_EXE`（子进程 env 里的本二进制路径，§7.6——`/compact` 的过程搬进 `extensions/compact` 之后它才调得到 harness）；前端 T1（骨架）、T2（卡片与折叠）、T3（nulya 视图：`/sessions`、`/ext`、sub-session tab、observer）、T4（`/help` `/settings` `/usage`、keymap 覆盖、`bun build --compile`、README、5k 事件性能）、T5（`/model` `/effort`）、T6（布局与 slash 补全）、T7（`/compact`）、T8（慢速回路：`/outcome` `/evolve` `/mode`、`/sessions` 改读 `session list --json`、成本来自 ledger、`/ext` 认多 root）、T9（`/compact` 改成 spawn `extensions/compact`）、T11（启动即安装：`ext sync` 的时机、project store 的 trust 问句、`/ext` 的 draft 列与 `p`）都在 `tui/`（见 §11 与 [`../tui/README.md`](../tui/README.md)）。本文是 `tui/` 的设计契约 + 里程碑 + 实施日志；`tui/` 不在内核范围里（另一条工具链、另一个进程），所以它的现状写在本文 §11，不进 DESIGN.md。
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
| D5 | 默认折叠 | `edit` diff **展开**；shell / 扩展工具输出 **折叠**；thinking **折叠**；capability banner 展开 | 你的要求 + 演化动作要显眼 |
| D6 | 取消 | `Esc` = `session cancel`（step 边界消化，当前工具跑完）；`Ctrl+C` 两下 = kill step 进程树（下一次 open 由 kernel `completeInterruptedToolBatch` 修复） | 两种语义都真实存在，都给；不发明第三种 |
| D7 | sub-agent 谱系来源 | v1 从 transcript 推导（`nulya session new` 的输出 id、`session step <id>` 命令）；**不**改 header | `parent` 语义是 fork/compaction 的续接点，不是 spawned-by；等 subagent skill 真写出来再决定要不要 `spawned_by` header 字段（§10） |
| D8 | 权限 / 审批 | v1 没有 | kernel 没有 policy hook 消费者；TUI 不发明审批 |
| D9 | 内容宽度 | transcript 内容宽度上限 `max_width = 100` 列，左对齐 | 250 列的 markdown 不可读；设定可改 |
| D10 | **给人用的：一切在屏幕上完成** | 启动 `nulya` 之后，选模型 / 换 effort / 看哪个 profile 缺 key / **贴 key** 都是屏幕上的交互（`/model` 选择器、`/effort`、选择器里的 `s`），**不能要求人去找 config 文件改**。TUI 记住上次的选择（`tui-state.json`，见 §7）；隐式的选择跑不了（缺 key）时开屏就是选择器 + 原因 + 怎么修。config 文件是**定义**（一个 model id 是什么、profile 怎么连）不是**日常操作面** | 这是 TUI 的关键设计理念，与 D4 分工：`tui.toml` 只有人写、`tui-state.json` 只有程序写；内核 `config.toml` 人写，TUI **只做一种写**——在末尾追加/就地替换一个带标记的 `[[provider.profiles]] name/api_key` 小块（`nulya/credentials.ts`；不重写、不碰人的内容）。内核不学"上次选了谁"（那不是 substrate）；kernel 只提供 `nulya config show --json` 一个投影（含 `paths`），TUI 不复刻配置合并链、不猜 home 在哪 |

## 2. 与内核的接触面

### 2.1 现有（只读用法）

| 面 | TUI 用法 |
|---|---|
| `nulya session new [--profile p] [--model id]` | `/new`、`/model` 的 Enter；stdout = id |
| `nulya session step <id> --effort e` | 每个 step 按本 tab 的 effort 传（`/model` 选的、`/effort` 改的）；不传 = kernel 默认 |
| `nulya config show --json` | `/model` 的行、启动时判断隐式选择能不能跑（`launch.planLaunch`）；只报 env var 名与 credential 布尔 |
| `nulya session append <id> --file f` | 发送：写 `.nulya/scratch/tui-<nonce>.txt` 再 `--file`（多行 / Windows 引号安全）；投进 inbox，**下一 step 边界才进 ledger**（PLAN §4 边角）→ TUI 乐观回显、标 `queued`，见到对应 `user_text` 事件后转正 |
| `nulya session step <id> --stream` | 每次发送后 spawn 一个；stdout 见 §2.2 |
| `nulya session events <id> [--since N]` | 打开 / resume 时一次性回放；**不**用 `--follow`（driver 模式下 step 的 stdout 已是全量实时源） |
| `nulya session cancel <id>` | `Esc` |
| `nulya session list [--json]` | `/sessions` 的全部内容（created 倒序、composition / parent / 事件数 / usage / 最新 verdict）；**TUI 不再自己扫 header**（T8） |
| `nulya session outcome <id> <v> [--note]` | `/outcome`；写 outcome journal、不碰 session 文件也不取锁，所以正在跑的场次、别人在 drive 的场次都能当场评 |
| `nulya session new --with <id>[@<v>]` | `/evolve`（先 `ext build extensions/evolution`）与 `/mode <id>[@<v>]`：把一个 **built 但不 activate** 的包带进这一场（membership，不是 store 指针） |
| `nulya ext build <path>` | `/evolve` 与 `/compact` 的第一步；version 内容寻址，所以每次都 build，未改动就是同一个 version |
| `nulya ext run <id>@<v> <tool> <json>` | `/compact`：过程住在 `extensions/compact` 里（DESIGN §11），前端只 build 它、run 它、把 tab 换到它返回的 session；它持锁的这段时间本 tab 自己翻成 observer 跟随（§5.6） |
| `nulya ext list` | `/ext` 的目录清单：每个 id 来自哪个 root、谁被 `(shadowed)`——root 顺序与"首个持有者胜"是 kernel policy，TUI 不复刻（T8） |
| `.nulya/sessions/<id>.lock` | 能否非阻塞独占 → 有无别的写者（§5.6）；`session list` 给不了"此刻谁在写"，所以这条探针留在 TUI |
| `<root>/<id>/versions/v-*/extension.json` | `/ext` 与 CompositionCard 的明细：`runtime`/`contributes`（tools / skills / **system_prompts**）/`permissions`；root 由 `ext list` 指出 |
| `.nulya/tool-usage.jsonl` | `/ext` 里的 usage 表：一行取 `tool_id` + `ok` → uses_total / recent / success_rate（**只投影，不重算排序**——排序是 kernel policy，TUI 不复刻）。行上还有 `at` / `session?` / `duration_ms?`（DESIGN §5.5），TUI 只挑它要的两列、其余原样忽略 |
| header `composition.native_tools` / `active[]` | 本场冻结契约（§5.1）；与 store `current` 比对 → "下一场会变"的漂移提示 |
| shell 结果形状 | `stdout` + `--- stderr ---` + `[exit N]`（`tools/shell.zig`）→ 状态 chip 解析 `[exit N]` |
| `edit` 参数 | `{path, old_string, new_string, replace_all?}` → TUI 端 old→new 生成 unified diff 喂 OpenTUI `diff` 组件 |
| 取消标记文本 | `loop.zig` 四种 marker（interrupted / canceled executing / recording canceled / not executed）→ 识别成 canceled 卡片 |
| `emit` 溢出 | `tool_results[].spill_path` → 卡片尾部 "full output → path"，`o` 打开（`$EDITOR` / 展开读文件） |

### 2.2 唯一内核改动：`nulya session step <id> --stream` `[已落地 · T0 → DESIGN §14]`

**协议与机制的真相在 [DESIGN.md](DESIGN.md) §14**（`loop.StepContext.observer` 纯观测钩子 + 行协议）。这里只留 TUI 侧的消费约定：

- 一行一个 JSON，写完即 flush；带 `stream` 字段 = 瞬态观测行，不带 = 与 `session events` 同形的 ledger 事件行（同一套 seq，可直接按 seq 入 items）。
- 行序（每个 step）：`started → text_delta* / thinking_delta* → tool_use_start / tool_use_input_delta* → done → tool begin/end* → 该 step 的 ledger 行 → step end`；整次调用最后一行是 `run done{steps,stopped}`（`stopped ∈ end_turn | budget | canceled | max_tokens`；被 `max_tokens` 截断的 step 的 `step end` 多一列 `"stop":"max_tokens"`，DESIGN §4）。见到 `step end` 就知道这一步的事件已全。**瞬态失败**（DESIGN §13）：一次尝试中途可能冒出 `{"stream":"model","event":"retry","attempt","max_retries","delay_ms","error"}`——这次尝试的 delta / usage 全部作废，内核退避后原样重发、再从 `started` 开始；`session.ts` 收到它就 `dropInFlight` + 回退 provisional usage，并把 "retry n/m in Xs" 放进 `error` 供状态栏显示，下一个 `started` 清掉。
- `reasoning_item` 不出现在流里（不透明、只为回放）；thinking 的可显示文本只有 `thinking_delta`，turn 结束后从 ledger 的 `reasoning` 尽力抽（§4.2）。
- 诊断也是 JSON（`{"stream":"run","event":"error","message":"…"}` + 非零退出），所以 `nulya/cli.ts` 的解析器**永远**不必处理裸文本行。

**明确不做的内核改动**（放进 §10 待议）：`session new` 自动记 spawned-by；`nulya config show`；`session append` 打印投递回执；`<id>.live` sidecar。

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
│   │   ├── ledger.ts         #   Header / Event 类型（DESIGN §3.4 形状）；events 行解析；四种 cancel marker 识别
│   │   ├── files.ts          #   .nulya/ 布局：sessions 列表 / lock 探测 / extensions store / tool-usage 投影
│   │   └── diff.ts           #   edit args → unified diff 文本
│   ├── state/
│   │   ├── session.ts        #   一场 session 的视图状态：items（seq 键）、in-flight turn、pending appends、usage 累计、role（driver|observer）
│   │   ├── driver.ts         #   状态机 idle→appending→stepping→idle；run done 后若仍有 pending 未转正 → 再 step
│   │   ├── settings.ts       #   tui.toml 加载合并（user → project）
│   │   ├── tui_state.ts      #   tui-state.json：程序唯一写的文件（上次 /model 的 profile/model/effort）
│   │   └── tabs.ts           #   一 tab 一场：attachment + tab 级 effort；replace() 让空场就地换模型
│   ├── render/               #   渲染注册表：按 (tool, 命令前缀) 选卡片；这是唯一按名字 match 的地方
│   │   ├── registry.ts
│   │   ├── cards/            #   UserTurn / AssistantTurn / Thinking / ShellCard / EditCard / ExtToolCard / EvolveCard / CapabilityBanner / SubSessionCard / CompositionCard / CanceledCard
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
 nulya · s-8f2a…c1 · anthropic/claude-sonnet-5 · tools 2+3 · skills 2                    step 4 · driver
─────────────────────────────────────────────────────────────────────────────────────────────────────
  ▎ session · 2026-08-16 14:02 · frozen composition
  ▎ tools  shell edit ⚡web_search ⚡fetch ⚡summarize      skills  evolution zig-style
                                                                                        (CompositionCard)
  › 把 emit.zig 的 head/tail 预算改成可配置                                              (UserTurn)

  ● 我先看一下 emit.zig 里预算的定义…                                                    (AssistantTurn, markdown)
    ▸ thinking · 1.2k chars                                                              (Thinking, 折叠)
    $ nulya src emit.zig                                            ▸ 212 lines · ok     (EvolveCard: 读内核源码)
    ✎ src/emit.zig                                                              ok       (EditCard, diff 默认展开)
      @@ -12,3 +12,4 @@
      -pub const head_bytes = 4096;
      +pub const head_bytes = 4096; // default, see OutputBudget
      +pub const tail_bytes = 2048;
    $ zig build test                                                ▸ 38 lines · exit 1  (ShellCard, 折叠)

  ⚙ ext build .nulya/extensions/lint → v-3f2a91                                          (EvolveCard)
  ⚡ capability · lint@v-3f2a91 · tools: lint_zig                                        (CapabilityBanner)

  ● 改好了，测试通过。要不要把默认值也写进 default.toml？▍                               (streaming)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 › 好，写进去_                                                                            (Composer)
─────────────────────────────────────────────────────────────────────────────────────────────────────
 ↑12.4k ↓3.1k cache 89% · ⠋ shell 3s · Esc cancel · Ctrl+O fold · /help                  (StatusBar)
```

三块：transcript（`scrollbox`，sticky bottom，鼠标滚轮 / PgUp / PgDn；离开底部时状态栏出现 `↓ new` 提示）、composer（`textarea`）、状态栏（1 行）。没有边框，用两条 hairline 分隔；空状态首屏是一个小 wordmark（`ascii-font`）+ session 信息 + 三条提示。

### 4.2 Transcript 项与卡片

| ledger / 流 | 卡片 | 头行 | 体 | 默认 |
|---|---|---|---|---|
| header | CompositionCard | `session · 时间 · frozen composition` | tools（builtin 平色、ext 带 ⚡）、skills、model identity、parent 链接 | 展开，一场一张 |
| `user_text` | UserTurn | `›` + 文本（markdown 关，保留换行） | — | queued 时头行加 `· queued` dim |
| `assistant.text` | AssistantTurn | `●` + markdown（tree-sitter 高亮） | — | 展开 |
| `assistant.reasoning` / `thinking_delta` | Thinking | `▸ thinking · N chars` | 流式时显示滚动的最后一行 dim；结束后从 `reasoning` 尽力抽 `thinking` 字段（Anthropic 形状），抽不到显示 `reasoning (opaque)` | 折叠；设定 `thinking = collapsed\|hidden\|expanded` |
| call `shell` | ShellCard | `$ 命令（单行截断）` + 右侧 `▸ N lines · ok\|exit N` | stdout / stderr 分段 | **折叠**；设定 `tool_output` |
| call `edit` | EditCard | `✎ path` + `ok\|failed` | unified diff（`diff` 组件，语法高亮） | **展开**；设定 `edit_diff = expanded\|collapsed` |
| call `ext:*` | ExtToolCard | `⌘ tool_name · 参数摘要（一级键截断）` | 输出 | 折叠 |
| shell 命令前缀 `nulya src` / `nulya ext init\|build\|activate\|rollback\|run` / `nulya skill load` / `nulya session new\|append\|step\|events` | EvolveCard / SubSessionCard | 见 §5.2 / §5.5 | 原始输出可展开 | 折叠但头行信息量大 |
| `capability_note` | CapabilityBanner | `⚡ capability · id@version · tools: …` | note 全文 | 展开 |
| canceled marker | CanceledCard | `⊘ tool · canceled (side effects unknown)` 三种文案对应三种 marker | — | 展开 |
| `spill_path` | 卡片尾行 | `full output → .nulya/scratch/…` | — | — |

折叠交互：鼠标在头行**按下与松开落在同一格**才切换（拖过去的是选取文本，不是点击，T18）；键盘 `Ctrl+O` 切换最近一张卡；`Esc` 空 composer 时进 browse 模式（`j/k` 移动高亮卡、`Enter`/`Space` 切换、`Esc` 回 composer）；`Ctrl+Shift+O` 全部展开/折叠。

### 4.3 流式与状态机（provisional → authoritative）

- 每次 `step --stream` 期间维护一个 **in-flight turn**：`text_delta` 追加到一个流式 AssistantTurn（只有这一块重排；已完成的 turn 是独立 renderable，不重解析）；`tool_use_start` 立刻建 tool 卡（`pending`）、`input_delta` 拼参数、`done` 后 parse；`tool begin/end` 切 `running → done`；`tool_results` 事件填输出。
- ledger 事件行到达 → 以 `seq` 为键写入 items，**替换**对应 provisional 项（文本应相同；不同以 ledger 为准并 debug 日志）。
- `user_text` 事件到达 → 与 pending appends 按顺序匹配转正。
- `run done` → 状态回 idle；若 pending appends 仍有未转正的 → 自动再 spawn 一次 step（用户在跑的中途发了话、但 run 已 end_turn）。
- 观测粒度就是 kernel 的粒度：TUI 不猜 "模型在想什么"，只显示流。

### 4.4 Composer / 按键 / slash

- `Enter` 发送；`Shift+Enter` / `Ctrl+J` 换行；`↑` 空 composer 时翻历史；粘贴多行原样。
- 发送时若 `stepping`：只 append（queued）；不打断。
- `/` 开头弹一个小补全：内建命令（`/model` `/effort <level|auto>` `/new [--profile p] [--model id]` `/sessions` `/ext` `/usage` `/compact [focus]` `/outcome` `/evolve` `/mode` `/cancel` `/fold` `/settings` `/help` `/quit`）在前，**activate 了的 skill 在后**（`nulya skill list`，描述截 100 字符）。分发同序：内建 → skill → 原样发给模型。`/<skill> [args]` = `nulya skill load <ref>` 拿到 body、包一层 sentinel 后作为**普通 user turn** append（T15；旧文本写的"nulya 没有 skill slash"已翻案——它把"谁触发"误当成了"谁判断"，理由见 goals/tui-panel.md D8）。
- `@` 开头（前一字符非字母数字下划线）弹文件补全：`↑↓` 选、`Tab` 上屏成 `@path`；已知引用在输入框里 accent。**上屏的是路径，不是文件内容**（T13）。
- 粘贴：> 1000 字符或 > 15 行折叠成 `[Pasted text #N]`，提交时展开回原文；`Backspace` 落在占位尾部整条删掉（T14）。
- 全局：`Esc` cancel（stepping 时）/ browse 模式；`Ctrl+C` 两下退出（stepping 时第一下先 kill）；`Ctrl+L` 重绘；`F2` `/ext`；`F3` `/sessions`；`F4` 下一个 tab；`Ctrl+W` 关掉当前 tab（最后一个不关）。
- 鼠标（T18）：列表行点一下落光标、点已选中的行执行它的 Enter；`/ext` 的 pane 条与 `[x]`、TabBar、状态栏的 `↓ N more below`、输入框都可点（点输入框也会退出 browse 模式）；拖过文本是选取，松手复制（OSC 52）。**模型这一行处处可点**（T20）：标题行的 `profile · model` 段、CompositionCard 的 `model` 值都开 `/model`；Welcome 的那几条 `/` 命令行、状态栏的 `/help` 也是按钮。所有可点的东西悬停都是同一个 `hover` 底色。
- `/model`（F5）与 `/provider`（F6）是**两个命令、两个问题**（T5 → T6 → T20 → T21，与 tcode 的 `/model` ÷ `/provider` 同一刀）：
  - `/model` **只有模型**：每个能跑的 provider 的每个 model 一行（`provider · label · id · ctx · ‹ effort › · ✓ current`），`h/l` 拨 effort、Enter 开新场；跑不了的 provider 不出模型行（这才是让表变短的东西），`provider` 那一列保证"这是谁家的模型"一眼可读。一个 model 的 ctx / effort 档位**先读该 profile 自己的 catalog**、没有才回落全局 `[[models]]`——同一个 id 在订阅口与公共 API 口是两个东西。一个 provider 都跑不了时只有一行 `no provider can run yet · /provider …`，Enter / `p` 就是过去。
  - `/provider` 是 **key 与 endpoint 的家**：一行一个 profile（`name · wire/endpoint · N models · 状态`），detail 行列出它的 model id（浏览不拦，拦的只是开一场），`s` 贴 key、`a` 加 compatible endpoint，codex 说 `codex login`；**Enter 在能跑的 provider 上 = 回 `/model` 并落在它的第一个模型上**——"先选 provider 再选它的模型"就是这两步。
  - 开屏没得跑时：还有别的 provider 能跑 → 开 `/model`；一个都跑不了 → 开 `/provider`（`launch.LaunchPlan.guideOn`）。
- observer 时空 composer 上的 `Enter` = take over（§5.6）；browse 模式里选中的卡若指名了一个 session，`Enter` 打开它成第二个 tab，`Space` 永远是折叠。

### 4.5 状态栏

左：token 累计（`↑input ↓output cache%`；**来源是 ledger 的 `assistant.usage`**，流事件只是它落盘前的临时值，同一步不会数两遍——所以重开一场也看得见它到今天为止花了多少，T8）· 当前活动（`⠋ shell 3s` / `⠋ model` / `idle`）· 提示三条。右：`step n` · role（`driver` / `observer` §5.6）。离开底部时插入 `↓ 3 new`。

上下文占用（`ctx 72% · /compact`）只在 ≥60% 时出现、≥80% 转 warn 色。分母是 `[[models]]` 目录的 `context_window`（目录没写就整个不显示，不编分母）；分子是**最后一步**的 `input + cache_read + cache_write`——`provider.Usage.input_tokens` 是扣掉缓存之后的量，只读它会把一个快满的窗口报成几乎空的。它只是显示，不触发任何动作。

## 5. nulya 独有视图

### 5.1 CompositionCard（每场 session 的冻结契约）

来自 header：model identity（provider/model/base_url 主机）、`active[]`（ext id@version 短 hash）、`native_tools`、skills（从各 active 版本的 `extension.json` `contributes.skills` 读）、`parent`。这是"这一场模型看到什么"的一眼版本；打开两场对比就是演化的差分。

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

左列：extensions（id · current 短 hash · N versions · kind compiled/script/data · 贡献的 tools/skills 数 · 被遮蔽的标 `shadowed`）——清单来自 `nulya ext list`，**多个 root** 都在里面（workspace → user `~/.nulya/extensions` → `extensions.paths`），右栏第一行写明它来自哪个 root。没有 `current` 的包（只用 `--with` 穿的 mode / evolution）读最新一次 build 的 manifest，否则它会被显示成空的。右栏（选中项）：manifest 摘要、版本时间线（`versions/v-*` mtime，`current` 标记，本场 header 冻结的版本标记；两者不同 → `pinned v-a · store v-b → next session`）、该 ext 每个 tool 的 usage（uses / recent / success%）、本场 ledger 里与它相关的 EvolveCard / CapabilityBanner 时间线（按 seq 跳转）。
动作键：`a` activate / `r` rollback（弹确认后 shell out `nulya ext …`，输出进一个临时行；不进 ledger——它本来就是 CLI 动作）。第二块 tab：全部 tool 的 usage 表（只投影 `.nulya/tool-usage.jsonl`；**不**复刻排序算法，"下一场谁晋升"留给未来的 `nulya composition preview` CLI，见 §10）。

### 5.4 `/sessions`（overlay，`F3`）

`nulya session list --json` 按 `created` 倒序：id · 时间 · model · 事件数 · 花费（`↑prompt ↓output`，没有被计价过的步就不显示）· 带了哪些 `--with` 包 · 第一条 user_text（截断）· `parent` 缩进成树 · 最新 verdict（`+ success` / `~ partial` / `! failure`；**没有行就什么都不画**——unjudged 不是 failure）· 有别的写者持锁 → `● live`。`Enter` 打开（events 回放 → 判 role）；`n` 新建；`r` 刷新；`d` 无（不删，ledger 只 append——想清理用文件系统）。
列表本身一次进程 + 读全部 session 文件，所以 8s 刷一次；`● live` 只是锁探针（不开进程），1.5s 刷一次。

### 5.5 Sub-agent

现状：subagent = 自调用（PLAN §3.2），尚无 consumer；TUI 只做"看得见"：
- SubSessionCard（§5.2）里的 id 可 `Enter` 打开为**第二个 tab**（顶部 `tab-select` 仅在 >1 个 session 打开时出现），子 session 正在被父 step 里的 shell 写 → 子 tab 自动进 observer 模式（§5.6），只 tail。
- `/sessions` 树用 `parent`；SubSessionCard 的链接是 transcript 推导（D7）。
- 不做：父子之间的消息转发、trace 视图嵌套折叠——等第一个 subagent skill。

### 5.6 Driver / observer 两种角色

- **driver**（默认）：TUI 自己 spawn `step --stream`；`.lock` 由 step 子进程持有。
- **observer**：`<id>.lock` 被别的进程独占（PLAN §3.6 的 driver 脚本、或另一个 TUI、或父 session 的 shell）→ 不 spawn step，只 `events --follow`（`--since` 续接）+ `append`（queued，等对方的下一 step 边界）。状态栏 `observer · driven elsewhere`。锁看上去持续空闲后弹一行 `press ↵ to take over`（手动，不自动抢）。
- **角色靠两个信号判定，都不是猜**：①`<id>.lock` 探针（idle 时轮询，且必须**无副作用**——去"试着拿一下锁"的探法在持锁瞬间会把真 writer 的非阻塞 `flock` 挤成假 `SessionBusy`，不算探针。Windows 上内核的租约是字节区间锁，读第 0 字节即可探到；Linux 上同一租约是 `flock(2)`，读不到但内核在 `/proc/locks` 里公示，按锁文件的 dev:inode 查表即可；两者都没有的 POSIX（macOS）→ 探针诚实地答 `unknown`）；②内核自己的 `SessionBusy`——我们真去 step 时被拒，这一条在所有平台都权威。所以角色是**持续**跟着世界变的，不只是"打开时判一次"。
- observer 看不到 deltas（deltas 只在 driver 的 stdout）：v1 接受 step 粒度；真正需要时的路径是 kernel 把流也写进 `<id>.live` sidecar，TUI 换 tail 源（`nulya/cli.ts` 内部一处改）。

## 6. 视觉规范

克制是终端里的美观。规则：
- **一处颜色一个含义**：角色色只用于左侧 glyph 和卡片头行；成功/失败是短 chip（`ok` / `exit 1`）不是整行变色。
- **四档明度是一个层级，不是一块调色板**（T18）：一段文字用哪一档由它**是什么**决定，不由它该多显眼决定——`fg` 这个东西本身（卡片头行、选中行、值）· `muted` 它由什么构成（id 旁的 label、计数、状态）· `dim` 关于它写的话（说明、hint、footer、列名）· `faint` 家具（hover 记号、空 gutter、失效格）。
- **无边框 transcript**：垂直节奏靠空行——turn 之间一空行、卡片之间不空、卡片体缩进 +2；两条 hairline 分隔三块。
- **diff 静**：仅前景色的 add/del，无背景块；上下文行 dim。
- **动效一处**：状态栏一个 braille spinner + 流式末尾 `▍` 光标；不做 shimmer（设定 `motion = false` 全关）。
- **符号集**（Windows Terminal / 常见等宽字体都有）：`›` user · `●` assistant · `$` shell · `✎` edit · `⌘` ext tool · `⚙` build/init · `⚡` capability/activate · `↺` rollback · `⌕` read kernel · `☰` skill · `⤷` sub-session · `⊘` canceled · `▎` composition · `▸ ▾` fold · `·` pointer（鼠标所在的行）· `⠋` spinner；`ascii = true` 时降级为 `> * $ ~ # + ! < ? = > x . |`。
- **主题 tokens**（`render/theme.ts`；`nulya-dark` 默认、`nulya-light`；尊重 `NO_COLOR`）：`fg muted dim faint accent.user accent.assistant accent.tool accent.evolve ok err warn diff.add diff.del hairline selection hover`。语法高亮用 OpenTUI `SyntaxStyle`，同一套 tokens 派生。
- **光标与指针是两套记号**：光标行 `▾` + `selection` 底色，指针行 `·` + 更淡的 `hover` 底色。形状不同，所以没有颜色时也分得开。
- **overlay 的底部只有一行键**（T18）：常驻两三个重点 + `? keys`，`?` 展开其余；没有更多键的面板不写 `? keys`。
- **宽度**：内容 ≤ `max_width`（默认 100），左对齐；窄于 60 列时隐藏状态栏右半与卡片右侧 chip。

## 7. 设定 `tui.toml`

路径：user 层 `~/.nulya/tui.toml`（Windows `%USERPROFILE%\.nulya\tui.toml`；`NULYA_HOME` 整体搬走，与内核 `config.toml` 同目录同规则），项目层 `.nulya/tui.toml`；后者覆盖前者；`Bun.TOML.parse`。

```toml
[transcript]
edit_diff      = "expanded"    # expanded | collapsed
tool_output    = "collapsed"   # collapsed | expanded
thinking       = "collapsed"   # collapsed | hidden | expanded
max_width      = 100
history_window = 400           # 同时挂载的卡片数（从最新往回数）；0 = 全挂（T4）
ascii          = false

[ui]
theme  = "nulya-dark"       # nulya-dark | nulya-light
motion = true

[extensions]                # T11
sync_on_start = true        # 开屏时后台 build 各 store root 下的 draft（`nulya ext sync`）
auto_activate = true        # 让那一趟把 `current` 指到它刚建出来的版本上

[keys]                      # 覆盖默认键；名字表见 keymap.ts
cancel = "escape"
fold   = "ctrl+o"
```

`[extensions]` 两个键都只作用于**这一趟 sync**：`auto_activate` 永远不会盖掉指着别处的 `current`（那是 DESIGN §7.2 的规则，前端无从违反），所以一次 rollback 活得过下一次启动。project store 的那道 trust 问句**不受这两个键管**——它是 DESIGN §9 的边界，只有按键能推动。

`/settings` 只显示当前生效值与来源文件；不在 TUI 里写配置（编辑器改文件即可，第二个诉求出现再做）。

**`tui-state.json`（D10；T5 起）**：同目录（user 层）下**唯一由程序写**的文件，JSON：`{"model":{"profile":"deepseek","model":"deepseek-v4-flash","effort":"high"}}`——`/model` 的 Enter 与 `/effort` 会更新它；启动无 `--profile` 时的默认选择就是它（`launch.planLaunch`：命令行 > 上次选择 > 内核 `active_profile`；每一层都要 `config show` 说它有 credential 才算数，否则落到离线 scripted 并开屏弹选择器讲原因）。缺失或损坏 = 没记住，永不阻止启动。为什么不放进 `tui.toml`：那是人写的；程序回写人的文件会碰注释与排版（tcode 用 toml_edit 才做到），这里不值得。为什么不进内核 config：内核不需要知道"上次选了谁"（不是 substrate）。

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
| ~~**T2 · 卡片与折叠**~~ ✅ | registry；Shell/Edit(diff)/ExtTool/Thinking/Canceled/spill；EvolveCard 全表；CapabilityBanner；CompositionCard；折叠交互；`tui.toml`；主题 tokens；ascii 降级 | §4.2 表每行一个快照测试；`edit_diff` 设定生效 |
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
| **T10 · `/goal`（占位，未开工）** | spawn 随仓库带的 driver 脚本（`win32` → `powershell -NoProfile -ExecutionPolicy Bypass -File drivers/goal.ps1`，否则 `sh drivers/goal.sh`），把它的 **stderr 喂给已有的 `--stream` 解析器**（token delta / tool begin-end / usage 全在里面），把它的 **stdout 当控制通道**：`session <id>` 开 tab、`handoff <old> -> <new>` 换 tab（原 tab 留着可回看）、`done <id>` 收尾并提示 `/outcome`。跟随中的 tab 是 **observer**（driver 持着写者 lease）。**内核零改动**，也不需要 §10.4 的 `<id>.live` sidecar | 起一个两阶段目标：token 实时可见；handoff 时自动切到子 session；`Esc` 停得下来（`session cancel` 或杀脚本）|

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
- `tui/test/render.test.tsx`：7 张卡片快照（user/queued、thinking 折叠、shell 折叠+exit chip、evolve、edit diff 展开、canceled marker、capability），外加 `edit_diff=collapsed` / `tool_output=expanded` 设定生效、窄屏隐藏右侧 chip、ascii 降级；然后是三条端到端（真实二进制 + test renderer + `mockInput`）：**同一 session live 与 replay 渲染出同一帧**、**打字 + Enter 真的驱动一次 step**（user turn 从 queued 转正、tool 卡出现、`stopped == "end_turn"`）、**关掉重开 `--session` 的 transcript 逐字相同**（对比两条 hairline 之间的行，避开状态栏计数）、**`Ctrl+O` 展开最近一张 tool 卡**。

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

**状态**：完成。`render/registry.ts` 填满 §4.2 / §5.2 全表；卡片拆成 `CardFrame` + `ShellCard` / `EditCard` / `ExtToolCard` / `EvolveCard` / `CanceledCard` / `CompositionCard`（`Thinking` / `CapabilityBanner` / `UserTurn` / `AssistantTurn` 沿用并加强）；折叠交互补齐鼠标点头行与 browse 模式（`state/browse.ts`）；`tui.toml` 的 `edit_diff` / `tool_output` / `thinking` / `ascii` 全部真的生效；主题 tokens 多一个 `bar` 字形并有 ascii 降级。**内核一行未改**（硬约束 1）。`bun test` 40 条全绿（`cli.test.ts` / **新增** `registry.test.ts` / `render.test.tsx`，14 张快照）；`zig build test` / `zig build e2e` 绿。

**关键决定与理由**

- **`describeTool` 现在也拿 `output`。** §5.2 有两行的事实只在 stdout 里：`ext build` 的 `v-<hash>`（内核打 `<dir>: <version> (built)`）、`session new` 的 id。ledger 把参数和结果都存着，所以 live 与 replay 读到的是同一份事实——签名从 `(tool, args, glyphs)` 变成 `({tool, args, output}, glyphs)`，抽取仍然只发生在 registry 一处。
- **抽不到就退回 ShellCard，不报错。** `nulya toolchain …`、以及任何比本 build 新的子命令，走的是普通 shell 卡。这条是 §5.2 写死的纪律，也是 registry 唯一的失败模式：一张朴素的卡永远是对的。
- **卡片按 `presentation.kind` 分派，不按工具名。** `ToolCard` 只有一个 `Switch`，读的是 registry 已经做完的决定；六个卡片组件里没有一处 `=== "shell"` 之类的名字比较。`CardFrame` 收走了头行布局、折叠开关、spill 尾行，所以"新加一种卡"不会长出第二套视觉语言。
- **取消压过工具身份。** 一次被内核收尾的调用，重要的是"它没跑完"，不是"它是个 shell"，所以 `CanceledCard` 在 `Switch` 的最前面，且四种 marker 各有各的措辞（"side effects unknown" 与 "never started" 不是同一个警告）。认的仍然是 marker **文本**（T0 提醒 4）。
- **CompositionCard 不是 transcript item。** header 不是事件（DESIGN §3.1），把它塞进 items 就是发明第二份真相。它由 `Transcript` 从 `snapshot.header` 直接画在 items 之前，因此 T1 钉死的两条不变量（live == replay、关掉重开逐字相同）完全不受影响。它读的 skills 来自**冻结版本**的 `extension.json`（`files.ts` 新增 `readContributions`），不是 store 的 `current`——本场跑的是什么，就显示什么（DESIGN §7.5）。
- **CapabilityBanner 的头行自己解析 note 文本。** `extension/notes.zig` 生成的文本是确定性的（`Tools:` / `Skills:` 两段，每条 `- <name> — <desc>`），把名字提到头行正是这张卡存在的理由——"agent 现在会 X 了"不该需要展开。解析放在 `nulya/ledger.ts`（那是唯一认识内核形状的目录），认不出的形状就只是没有名字，全文照旧在下面。
- **browse 模式让 composer 先 blur。** 不 blur 的话 `j`/`k` 会同时进文本框；blur 之后 App 的 `useKeyboard` 独占这几个键，`Esc` 再把焦点还回去。`Esc` 的三义在一个地方分完：stepping → cancel；idle 且 composer 空 → 进 browse；browse 中 → 退出。
- **`Ctrl+Shift+O` 改成 toggle。** T1 只会全展开，按第二下没反应；§4.2 写的是"全部展开/折叠"，所以记一个 `allOpen` 信号来回翻。
- **SubSessionCard 不做独立组件。** 它与 EvolveCard 唯一的差别是 glyph 和"有一个 session id"，而"打开成第二个 tab"是 T3。按 CLAUDE.md「第二个 consumer 出现之前不抽 abstraction」，registry 保留 `kind:"subsession"` + `sessionId` 这两个**事实**，绘制暂时交给 `EvolveCard`；T3 要接的话，落点就是 `ToolCard` 里那个 Match 分支（代码里有注释指着）。第一版曾加过一行 dim 的 `⤷ session <id>`，与头行完全重复，删掉了。

**偏离设计之处**

1. **§4.2 的 SubSessionCard**：没有独立组件（理由见上）；`sessionId` 这个事实在 registry 里，快照测试仍覆盖了这一行。
2. **§4.2 的 CompositionCard 头行"时间"**：内核实际写的 header 里 `created` 是**空串**（`nulya session new` 不填它），所以有值才显示。没有伪造时间（用 mtime 或从 session id 反推都是第二份真相），也没有为此改内核（硬约束 1）。这是 §10 值得记一笔的一行内核修补。
3. **§4.2 的 CapabilityBanner 头行**：除 `tools: …` 外也带 `skills: …`——note 本来就宣告两种能力，只显示一半没有理由。
4. **§4.2 的 CanceledCard**：不可折叠。它的"体"是 `—`，marker 文本已经全在 chip 上，留一个空的折叠开关是假的可交互。
5. **§4.2 的 `▎` 左侧竖线**：§6 的符号集原本没有列它（§4.1 的示意图里画着），CompositionCard 需要一个"这是一块"的记号，新增 glyph `bar`（ascii 降级为 `|`）。**已同步补进 §6 的符号表**（先改文档再改代码，硬约束 7）。
6. **§6 的 "diff 静"**：沿用 T1 的偏离（行号 gutter 开着，靠它拿回 `-`/`+` 符号）。
7. **§4.4 的 `/settings`**：仍未做（§9 归 T4）。`/help` 的提示行更新为包含 browse。
8. **§7 的 `[keys]`**：`cancel` / `fold` / `foldAll` / `quit` / `redraw` 可覆盖（T1 已有）；browse 内部的 `j`/`k`/`Enter` 是固定键，没有做成可配置——第二个诉求出现再说。

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
- `tui/test/render.test.tsx`：**§4.2 的每一行都有一张快照**——CompositionCard / UserTurn（含 queued）/ AssistantTurn / Thinking / ShellCard / EditCard / ExtToolCard / EvolveCard（§5.2 七种命令一帧）/ SubSession（两种）/ CapabilityBanner / CanceledCard（四种 marker 一帧）/ spill 尾行；另加 ascii 降级两帧（普通卡 + CompositionCard）、窄屏隐藏右侧 chip、`edit_diff=collapsed` / `tool_output=expanded`。
- **`edit_diff` 设定生效有真文件为证**：`"a project tui.toml flips the edit diff default"` 在临时 workspace 里先断言默认展开，再写一个 `.nulya/tui.toml`（`edit_diff="collapsed"` + `thinking="expanded"`），重新 `loadSettings` 后同一张 edit 卡的 diff 消失、同一张 thinking 卡展开——两个方向都动，证明是设定而不是"全都折了"。
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
5. **两根轴分开（契约 D4）。** `d` = `ext deactivate`，动的是 membership（skills / system prompts 进不进 composition），与 pins 并排而不是合成一个假总开关。tools-only 的包（std）"整体开关" ≈ 在 id 行上 `Space` 批量 pin；data 包（evolution / guide）的开关就是 activate / deactivate。
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
