# Nulya TUI — 设计与计划

> **状态：未实现，属计划。** 本文是 `tui/` 的设计契约 + 里程碑；落地后把"已实现"的部分搬进 [DESIGN.md](DESIGN.md) §14 / 新 §18，本文收缩成纯计划。
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

## 2. 与内核的接触面

### 2.1 现有（只读用法）

| 面 | TUI 用法 |
|---|---|
| `nulya session new [--model p]` | `/new`；stdout = id |
| `nulya session append <id> --file f` | 发送：写 `.nulya/scratch/tui-<nonce>.txt` 再 `--file`（多行 / Windows 引号安全）；投进 inbox，**下一 step 边界才进 ledger**（PLAN §4 边角）→ TUI 乐观回显、标 `queued`，见到对应 `user_text` 事件后转正 |
| `nulya session step <id> --stream` | 每次发送后 spawn 一个；stdout 见 §2.2 |
| `nulya session events <id> [--since N]` | 打开 / resume 时一次性回放；**不**用 `--follow`（driver 模式下 step 的 stdout 已是全量实时源） |
| `nulya session cancel <id>` | `Esc` |
| `.nulya/sessions/*.jsonl` | `/sessions` 列表（mtime 排序；header 给 model / composition / parent；第一条 `user_text` 当标题）；`<id>.lock` 能否非阻塞独占 → 有无别的写者（§5.6） |
| `.nulya/extensions/<id>/{current,versions/v-*/extension.json}` | `/ext` 视图：id、current、版本数、`runtime`/`contributes`/`permissions` |
| `.nulya/tool-usage.jsonl` | `/ext` 里的 usage 表：`{v:1,tool_id,ok}` → uses_total / recent / success_rate（**只投影，不重算排序**——排序是 kernel policy，TUI 不复刻） |
| header `composition.native_tools` / `active[]` | 本场冻结契约（§5.1）；与 store `current` 比对 → "下一场会变"的漂移提示 |
| shell 结果形状 | `stdout` + `--- stderr ---` + `[exit N]`（`tools/shell.zig`）→ 状态 chip 解析 `[exit N]` |
| `edit` 参数 | `{path, old_string, new_string, replace_all?}` → TUI 端 old→new 生成 unified diff 喂 OpenTUI `diff` 组件 |
| 取消标记文本 | `loop.zig` 四种 marker（interrupted / canceled executing / recording canceled / not executed）→ 识别成 canceled 卡片 |
| `emit` 溢出 | `tool_results[].spill_path` → 卡片尾部 "full output → path"，`o` 打开（`$EDITOR` / 展开读文件） |

### 2.2 新增（唯一内核改动）：`nulya session step <id> --stream`

**语义**：与不带 `--stream` 的 `step` 完全相同（同一 `AgentSession.run`、同一预算夹取、同一 cancel 消化）；区别只是 stdout **在跑的过程中**逐行输出下面的 JSON，而不是跑完一次性输出。不进 ledger、不改 model-visible 状态、不影响 replay——纯观测（physics 之外的"可观测"职责）。

**机制**（实现自由，约束如下）：`loop.StepContext` 增一个可选 `observer`（`{ptr, vtable}`），回调点：
- 模型流：`runStepWithPrompt` 把 `provider.StreamEvent` **tee** 一份（collector 照旧收；`reasoning_item` 可不转发）
- 工具执行：`execOne` 前后各一次（`tool_begin` / `tool_end{ok}`）
- step 边界：`AgentSession.run` 每个 step 结束后一次（含 canceled）；`cli.zig` 的 observer 在这里把 `sess.l.view()[printed..]` 以 `events` 同形的行刷出

**行协议**（一行一个 JSON；`stream` 字段区分瞬态行，无 `stream` 字段的就是 ledger 事件行）：

```jsonl
{"stream":"model","event":"started"}
{"stream":"model","event":"text_delta","text":"…"}
{"stream":"model","event":"thinking_delta","text":"…"}
{"stream":"model","event":"tool_use_start","index":0,"id":"call_1","name":"shell"}
{"stream":"model","event":"tool_use_input_delta","index":0,"fragment":"{\"command\":"}
{"stream":"model","event":"usage","input_tokens":1200,"output_tokens":80,"cache_read_tokens":1100,"cache_write_tokens":0}
{"stream":"model","event":"done","stop":"tool_use"}
{"stream":"tool","event":"begin","call_id":"call_1","tool":"shell"}
{"stream":"tool","event":"end","call_id":"call_1","ok":true}
{"seq":7,"kind":"assistant","text":"…","calls":[…]}
{"seq":8,"kind":"tool_results","results":[…]}
{"stream":"step","event":"end","status":"completed"}
{"stream":"run","event":"done","steps":2,"stopped":"end_turn"}
```

- `stopped ∈ end_turn | budget | canceled`。
- 任何诊断（原来 `printOut` 的 "session step failed: …" 等）在 `--stream` 下改为 `{"stream":"run","event":"error","message":"…"}` 然后非零退出；**stdout 上没有非 JSON 行**。
- 每条写完 flush（TUI 逐行读）。
- 单元测试用 scripted provider 钉住行序：`started → text_delta* → tool_use_* → done → tool begin/end* → ledger 行 → step end → run done`。
- 同一 commit 更新 DESIGN §14 的 `step` 一行 + 本节搬过去。

**明确不做的内核改动**（放进 §10 待议）：`session new` 自动记 spawned-by；`nulya config show`；`session append` 打印投递回执；`<id>.live` sidecar。

## 3. 目录与模块（`tui/`）

```
tui/
├── package.json  tsconfig.json  bun.lock  README.md
├── src/
│   ├── main.tsx              # 参数解析（--session <id> | --new [--model p] | --workspace dir）→ createCliRenderer → <App/>
│   ├── nulya/                # ★ 唯一知道内核形状的目录
│   │   ├── bin.ts            #   binary 发现：NULYA_BIN → <repo>/zig-out/bin/nulya[.exe] → PATH；版本探测（`nulya --version` 若有）
│   │   ├── cli.ts            #   spawn：new / append(--file) / step --stream / events / cancel；--stream 行 → 类型化 StreamLine
│   │   ├── ledger.ts         #   Header / Event 类型（DESIGN §3.4 形状）；events 行解析；四种 cancel marker 识别
│   │   ├── files.ts          #   .nulya/ 布局：sessions 列表 / lock 探测 / extensions store / tool-usage 投影
│   │   └── diff.ts           #   edit args → unified diff 文本
│   ├── state/
│   │   ├── session.ts        #   一场 session 的视图状态：items（seq 键）、in-flight turn、pending appends、usage 累计、role（driver|observer）
│   │   ├── driver.ts         #   状态机 idle→appending→stepping→idle；run done 后若仍有 pending 未转正 → 再 step
│   │   └── settings.ts       #   tui.toml 加载合并（user → project）
│   ├── render/               #   渲染注册表：按 (tool, 命令前缀) 选卡片；这是唯一按名字 match 的地方
│   │   ├── registry.ts
│   │   ├── cards/            #   UserTurn / AssistantTurn / Thinking / ShellCard / EditCard / ExtToolCard / EvolveCard / CapabilityBanner / SubSessionCard / CompositionCard / CanceledCard
│   │   └── theme.ts          #   tokens（§6）
│   ├── ui/                   #   App / Transcript / Composer / StatusBar / overlays(SessionsPicker, ExtView, Help)
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

折叠交互：鼠标点头行切换；键盘 `Ctrl+O` 切换最近一张卡；`Esc` 空 composer 时进 browse 模式（`j/k` 移动高亮卡、`Enter`/`Space` 切换、`Esc` 回 composer）；`Ctrl+Shift+O` 全部展开/折叠。

### 4.3 流式与状态机（provisional → authoritative）

- 每次 `step --stream` 期间维护一个 **in-flight turn**：`text_delta` 追加到一个流式 AssistantTurn（只有这一块重排；已完成的 turn 是独立 renderable，不重解析）；`tool_use_start` 立刻建 tool 卡（`pending`）、`input_delta` 拼参数、`done` 后 parse；`tool begin/end` 切 `running → done`；`tool_results` 事件填输出。
- ledger 事件行到达 → 以 `seq` 为键写入 items，**替换**对应 provisional 项（文本应相同；不同以 ledger 为准并 debug 日志）。
- `user_text` 事件到达 → 与 pending appends 按顺序匹配转正。
- `run done` → 状态回 idle；若 pending appends 仍有未转正的 → 自动再 spawn 一次 step（用户在跑的中途发了话、但 run 已 end_turn）。
- 观测粒度就是 kernel 的粒度：TUI 不猜 "模型在想什么"，只显示流。

### 4.4 Composer / 按键 / slash

- `Enter` 发送；`Shift+Enter` / `Ctrl+J` 换行；`↑` 空 composer 时翻历史；粘贴多行原样。
- 发送时若 `stepping`：只 append（queued）；不打断。
- `/` 开头弹一个小补全：`/new [--model p]` `/sessions` `/ext` `/skills` `/usage` `/cancel` `/fold` `/settings` `/help` `/quit`。未知 `/xxx` 原样发给模型（nulya 没有 skill slash；skill 由模型 `nulya skill load`）。
- 全局：`Esc` cancel（stepping 时）/ browse 模式；`Ctrl+C` 两下退出（stepping 时第一下先 kill）；`Ctrl+L` 重绘；`F2` `/ext`；`F3` `/sessions`。

### 4.5 状态栏

左：token 累计（本进程内从 `usage` 流事件累加：`↑input ↓output cache%`；resume 前的历史未知，显示 `since attach`）· 当前活动（`⠋ shell 3s` / `⠋ model` / `idle`）· 提示三条。右：`step n` · role（`driver` / `observer` §5.6）。离开底部时插入 `↓ 3 new`。

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

左列：extensions（id · current 短 hash · N versions · kind compiled/script/data · 贡献的 tools/skills 数）。右栏（选中项）：manifest 摘要、版本时间线（`versions/v-*` mtime，`current` 标记，本场 header 冻结的版本标记；两者不同 → `pinned v-a · store v-b → next session`）、该 ext 每个 tool 的 usage（uses / recent / success%）、本场 ledger 里与它相关的 EvolveCard / CapabilityBanner 时间线（按 seq 跳转）。
动作键：`a` activate / `r` rollback（弹确认后 shell out `nulya ext …`，输出进一个临时行；不进 ledger——它本来就是 CLI 动作）。第二块 tab：全部 tool 的 usage 表（只投影 `.nulya/tool-usage.jsonl`；**不**复刻排序算法，"下一场谁晋升"留给未来的 `nulya composition preview` CLI，见 §10）。

### 5.4 `/sessions`（overlay，`F3`）

`.nulya/sessions/` 按 mtime 倒序：id · 时间 · model · 事件数 · 第一条 user_text（截断）· `parent` 缩进成树 · 有别的写者持锁 → `● live`。`Enter` 打开（events 回放 → 判 role）；`n` 新建；`d` 无（不删，ledger 只 append——想清理用文件系统）。

### 5.5 Sub-agent

现状：subagent = 自调用（PLAN §3.2），尚无 consumer；TUI 只做"看得见"：
- SubSessionCard（§5.2）里的 id 可 `Enter` 打开为**第二个 tab**（顶部 `tab-select` 仅在 >1 个 session 打开时出现），子 session 正在被父 step 里的 shell 写 → 子 tab 自动进 observer 模式（§5.6），只 tail。
- `/sessions` 树用 `parent`；SubSessionCard 的链接是 transcript 推导（D7）。
- 不做：父子之间的消息转发、trace 视图嵌套折叠——等第一个 subagent skill。

### 5.6 Driver / observer 两种角色

- **driver**（默认）：TUI 自己 spawn `step --stream`；`.lock` 由 step 子进程持有。
- **observer**：打开时发现 `<id>.lock` 被别的进程独占（PLAN §3.6 的 driver 脚本、或另一个 TUI、或父 session 的 shell）→ 不 spawn step，只 `events --follow`（`--since` 续接）+ `append`（queued，等对方的下一 step 边界）。状态栏 `observer · driven elsewhere`。锁释放后弹一行 `press ↵ to take over`。
- observer 看不到 deltas（deltas 只在 driver 的 stdout）：v1 接受 step 粒度；真正需要时的路径是 kernel 把流也写进 `<id>.live` sidecar，TUI 换 tail 源（`nulya/cli.ts` 内部一处改）。

## 6. 视觉规范

克制是终端里的美观。规则：
- **一处颜色一个含义**：角色色只用于左侧 glyph 和卡片头行；正文默认 fg；元数据 dim；成功/失败是短 chip（`ok` / `exit 1`）不是整行变色。
- **无边框 transcript**：垂直节奏靠空行——turn 之间一空行、卡片之间不空、卡片体缩进 +2；两条 hairline 分隔三块。
- **diff 静**：仅前景色的 add/del，无背景块；上下文行 dim。
- **动效一处**：状态栏一个 braille spinner + 流式末尾 `▍` 光标；不做 shimmer（设定 `motion = false` 全关）。
- **符号集**（Windows Terminal / 常见等宽字体都有）：`›` user · `●` assistant · `$` shell · `✎` edit · `⌘` ext tool · `⚙` build/init · `⚡` capability/activate · `↺` rollback · `⌕` read kernel · `☰` skill · `⤷` sub-session · `⊘` canceled · `▸ ▾` fold · `⠋` spinner；`ascii = true` 时降级为 `> * $ ~ # + ! < ? = > x`。
- **主题 tokens**（`render/theme.ts`；`nulya-dark` 默认、`nulya-light`；尊重 `NO_COLOR`）：`fg dim accent.user accent.assistant accent.tool accent.evolve ok err warn diff.add diff.del hairline selection`。语法高亮用 OpenTUI `SyntaxStyle`，同一套 tokens 派生。
- **宽度**：内容 ≤ `max_width`（默认 100），左对齐；窄于 60 列时隐藏状态栏右半与卡片右侧 chip。

## 7. 设定 `tui.toml`

路径：user 层 `%APPDATA%\nulya\tui.toml` / `~/.config/nulya/tui.toml`，项目层 `.nulya/tui.toml`；后者覆盖前者；`Bun.TOML.parse`。

```toml
[transcript]
edit_diff   = "expanded"    # expanded | collapsed
tool_output = "collapsed"   # collapsed | expanded
thinking    = "collapsed"   # collapsed | hidden | expanded
max_width   = 100
ascii       = false

[ui]
theme  = "nulya-dark"       # nulya-dark | nulya-light
motion = true

[keys]                      # 覆盖默认键；名字表见 keymap.ts
cancel = "escape"
fold   = "ctrl+o"
```

`/settings` 只显示当前生效值与来源文件；不在 TUI 里写配置（编辑器改文件即可，第二个诉求出现再做）。

## 8. 测试

- `tui/test/cli.test.ts`：`NULYA_SCRIPTED_MODE=finish|loop` 跑真实 `nulya` 二进制：new → append → step --stream，断言行序与类型化解析；cancel 路径；events 回放与 live 状态一致（同一 fixture 两条路径渲染出同一帧）。
- `tui/test/render.test.ts`：`@opentui/core/testing` 的 test renderer 对每种卡片出快照帧（含折叠/展开、diff、canceled、窄屏）。
- 不调真实 API；CI 只需 `zig build` 出二进制 + `bun test`。
- Zig 侧：`--stream` 行协议单测（scripted provider）；e2e 里加一条 `--stream` 冒烟。

## 9. 里程碑

| 里程碑 | 内容 | 完成标准 |
|---|---|---|
| **T0 · kernel `--stream`** | §2.2：`StepContext.observer`、tee、tool begin/end、per-step 刷 ledger 行、`run done/error` 行、诊断 JSON 化；单测 + e2e 冒烟；DESIGN §14 同步 | `zig build test` / `e2e` 绿；`nulya session step <id> --stream` 在 scripted 下按 §2.2 行序输出；不带 `--stream` 行为不变 |
| **T1 · 骨架** | `tui/` 包；`nulya/{bin,cli,ledger,files,diff}.ts`；`state/{session,driver,settings}`；App = transcript（User/Assistant 通用卡 + 通用 tool 卡）+ composer + 状态栏；driver 状态机；流式；Esc cancel；`--session` 回放；`bun test` 两条 | 在 nulya 仓库里用它对着真实 provider 完整跑一轮"读源码 → edit → zig build test"；关掉重开 `--session` 一致 |
| **T2 · 卡片与折叠** | registry；Shell/Edit(diff)/ExtTool/Thinking/Canceled/spill；EvolveCard 全表；CapabilityBanner；CompositionCard；折叠交互；`tui.toml`；主题 tokens；ascii 降级 | §4.2 表每行一个快照测试；`edit_diff` 设定生效 |
| **T3 · nulya 视图** | `/sessions`（树 + live 标记 + 打开）；`/ext`（store / 版本线 / 漂移 / usage / 动作键）；SubSessionCard → 第二 tab；observer 模式（锁探测、`events --follow` 续接、take over） | 用 shell 在另一终端跑一个 driver 脚本 loop step，TUI 以 observer 附上并能 append |
| **T4 · 收尾** | `/help` `/settings` `/usage`；keymap 覆盖；`bun build --compile` 出单文件；README（安装、`NULYA_BIN`、按键）；性能核对（长 session 回放 5k 事件不卡；scrollbox 视口裁剪） | 5k 事件 session 打开 < 1s；README 照做能跑 |

顺序 T0 → T1 → T2 → T3 → T4；**T1 结束就开始用它 dogfood**，T2 起的优先级由用出来的痛点重排。

## 10. 开放问题（待议，默认都先不做）

1. **spawned-by 谱系**：subagent 的 `session new` 在 `NULYA_SESSION` 存在时是否自动记一个 header 字段（`spawned_by{session,seq}`，与 `parent` 分开）？是 provenance fact，成本几行；但等 subagent skill 成为第一个 consumer 再定字段名与语义。
2. **`nulya config show [--json]`**：外壳级投影，供 `/new --model` 选择器与 agent 自查；v1 手打 profile 名。
3. **`session append` 打印投递回执**（inbox 文件名）→ TUI 按 `origin` 精确转正而非按序匹配；现在按序够用。
4. **`<id>.live` sidecar**：observer 模式的 deltas；等第一个 driver 脚本。
5. **`nulya composition preview`**：下一场会晋升谁——纯投影 CLI，避免 TUI 复刻 `tool_selection.rank`。
6. **`split-footer` 模式**作为可选屏幕模式（scrollback 原生复制），与折叠可变历史的取舍。
7. session `--system-file/--skill/--pin`（PLAN §3.2 未落地）落地后 `/new` 的表单。

## 11. 实施日志

> 每个里程碑追加一小节，只追加不改写。格式：状态 / 关键决定与理由 / 偏离设计之处 / 怎么运行与测试 / 已知问题 / 给下一里程碑的提醒。
> 主对话（编排者）在每节末尾追加一行 `核验：…` 记录 `zig build test` / `zig build e2e` / `bun test` 的结果。

