# Nulya TUI — 设计与计划

> **状态：T0（内核 `--stream`）已落地 → [DESIGN.md](DESIGN.md) §14；T1（`tui/` 骨架）已落地 → `tui/`（见 §11）；T2–T4 属计划。** 本文是 `tui/` 的设计契约 + 里程碑；落地一块就把"已实现"的部分搬进 DESIGN.md §14 / 新 §18，本文收缩成纯计划。`tui/` 不在内核范围里（另一条工具链、另一个进程），所以它的现状写在本文 §11，不进 DESIGN.md。
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

### 2.2 唯一内核改动：`nulya session step <id> --stream` `[已落地 · T0 → DESIGN §14]`

**协议与机制的真相在 [DESIGN.md](DESIGN.md) §14**（`loop.StepContext.observer` 纯观测钩子 + 行协议）。这里只留 TUI 侧的消费约定：

- 一行一个 JSON，写完即 flush；带 `stream` 字段 = 瞬态观测行，不带 = 与 `session events` 同形的 ledger 事件行（同一套 seq，可直接按 seq 入 items）。
- 行序（每个 step）：`started → text_delta* / thinking_delta* → tool_use_start / tool_use_input_delta* → done → tool begin/end* → 该 step 的 ledger 行 → step end`；整次调用最后一行是 `run done{steps,stopped}`（`stopped ∈ end_turn | budget | canceled`）。见到 `step end` 就知道这一步的事件已全。
- `reasoning_item` 不出现在流里（不透明、只为回放）；thinking 的可显示文本只有 `thinking_delta`，turn 结束后从 ledger 的 `reasoning` 尽力抽（§4.2）。
- 诊断也是 JSON（`{"stream":"run","event":"error","message":"…"}` + 非零退出），所以 `nulya/cli.ts` 的解析器**永远**不必处理裸文本行。

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
| ~~**T0 · kernel `--stream`**~~ ✅ | §2.2：`StepContext.observer`、tee、tool begin/end、per-step 刷 ledger 行、`run done/error` 行、诊断 JSON 化；单测 + e2e 冒烟；DESIGN §14 同步 | `zig build test` / `e2e` 绿；`nulya session step <id> --stream` 在 scripted 下按 §2.2 行序输出；不带 `--stream` 行为不变 |
| ~~**T1 · 骨架**~~ ✅ | `tui/` 包；`nulya/{bin,cli,ledger,files,diff}.ts`；`state/{session,driver,settings}`；App = transcript（User/Assistant 通用卡 + 通用 tool 卡）+ composer + 状态栏；driver 状态机；流式；Esc cancel；`--session` 回放；`bun test` 两条 | 在 nulya 仓库里用它对着真实 provider 完整跑一轮"读源码 → edit → zig build test"；关掉重开 `--session` 一致 |
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

### T0 · kernel `--stream`

**状态**：完成。`nulya session step <id> --stream` 已落地，行协议搬进 DESIGN §14，§2.2 收缩成 TUI 侧消费约定。`zig build test`、`zig build e2e` 全绿；不带 `--stream` 的 `session step` 一字未变（输出路径与文案原样保留，e2e 有对照断言）。

**关键决定与理由**

- **observer 全部返回 `void`**。§2.2 只说"纯观测"，没说签名。让四个回调都不可失败，是把"纯观测"变成类型上的事实：observer 既不能 append，也不能让一个 step 因为 stdout 断了而失败。写失败停在 `StepStream.err`，run 结束后走 stderr + 非零退出（stdout 仍只有 JSON）。
- **step 边界回调放在 `AgentSession.step()` 而不是 `run()`**。§2.2 写的是"`run` 每个 step 结束后一次"；放在 `step()` 里对 `run` 完全等价（`run` 只调 `step`），还顺带覆盖了直接调 `step()` 的调用方，且 `prepareStep` 在边界被取消的那一步也能报 `step end{status:"canceled"}`。
- **tee 在 `loop.zig` 而不是 `provider.zig`**。observer 类型属于 loop（`StepContext` 的一部分），provider 反过来引用会成环。`collectTurn` 在无 observer 时**就是** `Model.step`，有 observer 时才建 collector + `TeeSink`；两条路径的失败语义一致（partial collector 一律丢弃）。
- **`{"stream":"tool","event":"end"}` 只带 `call_id` + `ok`**，与 §2.2 样例逐字一致（不加 `tool` 字段）；配对信息读者从 `begin` 和 `tool_use_start` 已经拿到了。
- **未被派发的调用不发 begin/end**。一批被取消后，后面的调用内核保证从未交给 executor，"没有事件"正是这个事实的忠实表达；它们仍会以 `not executed` marker 出现在 ledger 行里。
- **`stopped` 不改 `run` 的签名**：`canceled` 来自 observer 记下的最后一个 step status，`end_turn` 来自 `sess.lastAssistantDone()`，其余是 `budget`。内核没有多长出一个字段。
- **一个 step 的 ledger 行在该 step 的 `step end` 之前刷出**，包括边界上从 inbox 排干进来的 `user_text`——所以它出现在模型 delta **之后**。这是 step 粒度的必然结果，不是 bug：TUI 拿 `seq` 入 items，顺序由 seq 决定，不由到达时刻决定。

**偏离设计之处**

- §2.2 原文整节搬进 DESIGN §14（tui.md 的铁律：已落地的写 DESIGN），§2.2 改为"真相在 DESIGN §14 + TUI 侧消费约定"。§9 里程碑表 T0 一行标 ✅。
- §2.2 样例里 `{"seq":8,"kind":"tool_results",…}` 与 `{"seq":7,"kind":"assistant",…}` 相邻；实际实现两行都在同一个 `step end` 之前刷出，顺序一致，无偏离。
- 除此之外无偏离。§10 列的四项内核改动一项没做。

**怎么运行与测试**

```bash
zig build                                        # 出二进制
zig build test                                   # 单测（含 cli.zig 的三条 --stream 测试）
zig build e2e                                    # e2e（含 --stream 冒烟）

# 手动看一眼（scripted，无需任何 API key）：
ID=$(nulya session new --model scripted)
nulya session append "$ID" "hello"
NULYA_SCRIPTED_MODE=finish nulya session step "$ID" --stream
```

新增测试：
- `src/cli.zig` — `"session step --stream emits the tui.md §2.2 line protocol in order"`：scripted provider + 假 `shell` 工具，对**整段 stdout 逐字**断言（两个 step 的全部 16 行）。另两条覆盖 `stoppedReason` 与"诊断在 `--stream` 下是 `run error` 行"。
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
