# Goal · ext-review：extension 面的六处收口（2026-08-23 评审落地）

> 这是一份**执行契约**，不是设计文档。来源是 2026-08-23 对 extension 参数面的整体评审（结论：内核没破，四不像在 manifest 的听众混杂、"能力怎么到模型面前"的七个概念、与脚本 extension 名存实亡三处）。地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7 / §4 / §14。
> 本文件的决策已定，不要重开；认为错了就写进 §6 自己那一节的 `BLOCKED:` 并停下，不要自行改方向。
> **四条 lane 并行在各自的 worktree 里跑，互不可见。** §5 的文件归属表是为了合并时少冲突——不是你的文件就别动（需要时在 §6 写一句"需要 X 改 Y"）。

## 0. 目标（一句话）

让 AI 写一个 extension 时只面对一套简单的东西：一张按听众分层的 manifest、两根轴（成员 / 工具面）的 2×2、一条五行 shell 就能写出的脚本 wire；并把 driver 侧重复推导冻结事实的代码删掉（gate 请求自带声明、pin 蕴含成员）。**八条 physics 零改动，kernel prompt 零改动（`kernel_hash` 不变）。**

## 1. 范围：四条 lane

### Lane A · 脚本 wire（`runtime.wire: "plain"`）+ 按平台的 entry / interpreter + `ext init` 缺省脚本

**问题**：随仓库带的 6 个有 runtime 的 extension 全是编译 Zig，零个脚本；原因全是 JSON-RPC 要在 stdin 上解析 JSON（`sh` 没有、Windows 没 `jq`）、要回同一个 `id`、一个 manifest 只有一个 `interpreter` 所以 `sh` + `ps1` 没法共用一个版本。`ext init` 缺省还是编译版。PLAN §0.1 #3 说的"脚本默认、Zig 是实测需要时的优化"没有兑现。

**做：**

1. **`runtime.wire?: "jsonrpc" | "plain"`**，缺省 `jsonrpc`（老 manifest 逐字节同义）。与 `entry` / `interpreter` 同层——关于"怎么跟这个 runtime 说话"的事实，内核强制。认不出的词 `InvalidWire`（封闭词表，`audience` 同纪律）。**两种 kind 都可以用 `plain`**（一个编译的 Zig 也可以读 env 打文本；不加"只许脚本"的规则）。
2. **plain 的契约**（写进 `src/extension/protocol.zig` 的模块注释顶部，这样 `nulya ext api protocol` 打印出来的就是它，零漂移）：
   - **stdin** = 这次调用的 arguments，一个 compact JSON object（模型写的原文，与 JSON-RPC 的 `params.arguments` 同一份字节）。
   - **env** 在净化后的 env 之上再加：`NULYA_TOOL=<tool name>`；对 arguments 每个**顶层**且值是 string / number / bool 的键 `k`，加 `NULYA_ARG_<k>=<值>`（string 原样、number 按 JSON 文本、bool 是 `true` / `false`）；键名只接受 `[A-Za-z0-9_]+`，不合的键不进 env（仍在 stdin 里）；数组 / 对象 / null 不进 env。
   - **stdout** = 结果文本，**原样**作为 string result 进 `emit`（§7.3 已有的"字符串结果原文进 emit"规则，不加第二条）。
   - **退出码** 0 = `ok`；非 0 = 失败的调用（与 JSON-RPC error 折成 `ok=false` 同一条路）：文本是 `exit <code>` + stderr（经 `emit.headTail` 的既有预算），stdout 若非空也附上。
   - 超时、kill 整棵树、env 净化、`NULYA_EXE` / `NULYA_SESSION`：与 jsonrpc **完全相同**，同一条 `runExtension` 路。
   - `nulya ext run <id> <tool> --arg k=v` 与模型调用走**同一条**路（env 由 host 从 JSON 派生，脚本看不出是谁在调）。
3. **按平台的 entry / interpreter**：`runtime.entry` 与 `runtime.interpreter` 各自**既可以是 string，也可以是 object** `{ "<os>": string, …, "default"?: string }`，`<os>` 用 Zig `builtin.os.tag` 的名字（`windows` / `linux` / `macos` / …）。解析：宿主 os → `default` → 没有就这个版本**在本机没有入口**（composition 里 pin 它 → 新错误 `EntryUnsupportedOnHost`，hard fail 指名；`ext run` → stderr 一句 + exit 1）。**object 形式只许 script kind**（所有变体都在 `src/` 下；混 `bin/` 与 `src/`、或 object 里出现 `bin/` → `InvalidEntry`）——编译 kind 的跨平台是交叉编译，不在本契约。`isScript` / `implementationKind` 看全部变体（一致才合法）。build 时每个声明的 entry 变体文件都必须在 snapshot 里（`validateSystemPrompts` 的同一先例）。version id：snapshot 本来就收整个 `src/**`，所以 `v` 对所有平台相同——这正是要的。
4. **`ext init` 缺省脚本、`--zig` 才编译**（`--script` 作为无操作别名保留一个版本期，usage 不再列它）。脚手架：`src/run.sh` + `src/run.ps1` 两个文件、manifest 用 object 形式的 entry + interpreter + `"wire": "plain"`、**不写 `permissions`**（见 Lane D D7，你顺手在两个 template 里都删掉）；两个脚本各三四行：打印 `hello from <id>` 加 `NULYA_ARG_name`（tool input 声明一个可选 `name` string）。`--zig` 的 Zig 模板不动（仍 jsonrpc）。
5. **文档与 model-facing 文本**：DESIGN §7.1（两种 wire、按平台 entry）、§7.3（plain 契约一段）、§7.4（object entry 进 snapshot 的说法）、§14（`ext init [--zig] [--user] <id> [tool]`）；PLAN §0.1 #3 与 §3.3 加一句"已兑现"；`cli/common.zig` 的 `ext_usage` 那一行；`ext api examples` 的脚本那段改成 plain 的样子（把 `sed` 抠 id 那套删掉）。**不碰** `ext api permissions`（Lane D 重写它，并且会按本契约的最终状态写上 `wire` 与按平台 entry）。
6. **e2e**：新文件 `tests/e2e/script_wire.zig`（e2e.zig 加一行 import）：① `ext init` 缺省出的脚本 extension → `build`（不需 zig）→ `ext run … --arg name=world` 打回文本 → activate → `session new --pin` 后经 scripted provider 在 session 里被调用，result 文本**逐字节**是脚本的 stdout；② 非零退出的脚本 → `ok=false`、文本含 `exit <code>` 与 stderr；③ object entry 在本机选中本平台那个；一个只声明**另一个**平台的 manifest → pin 它的 `session new` hard fail 指名、`ext run` 一句拒绝；④ 既有的 `--script` jsonrpc e2e 照绿（老 wire 不变）。本机 Windows，所以 ③ 的"另一个平台"写 `linux`。

**不做**：persistent runtime；`plain` 的 streaming；改 JSON-RPC 任何字节；TUI（除非 grep 发现它调 `ext init`——今天没有）；bundled 8 个 extension 改成脚本（那是以后按需的事）。

### Lane B · gate 请求自带冻结声明 + pin ⇒ with

**问题 1**：gate 请求行只有 `{call_id, tool, args}`，于是每个答题人都在重推"这个 tool 只读吗、属于哪个包"——TUI 读 manifest，`extensions/agent/src/runner.zig` 对子场 header 每个成员 spawn 一次 `nulya ext inspect <id>@<v>` 解析 JSON 收 `readonly: true` 的名字（BUGS #16 ① 正是这条推导静默失败：名单恒空，explore 什么都读不了）。内核在 gate 那一刻手里就拿着 Binding。
**问题 2**：`--pin ext:std/read` 在非成员上是 `PinNamesUnknownExtension` 硬拒，所以 `extensions/agent` 的 `render` 为每个 pin 派生一个 `--with`、还做预验证（`main.zig:218-300, 537-539`），TUI 也各自做一遍。一个 tool 不可能在包不在场时上工具面——蕴含是被迫的，让每个 driver 各拼一遍是仪式。

**做：**

1. **`tool.ToolDefinition` 加 `readonly: ?bool = null`**（`ext_tools.Binding.init` 从冻结 manifest 的 `ToolSpec.readonly` 填；builtin `shell` 是 null）。`loop.ToolGate.review` 的入参从 `call` 变成一个 `GateRequest{ call, definition: *const tool.ToolDefinition }`（或等价：多传 definition），**observer 不动**。不设 gate 的 step 逐字节不变（既有测试）。
2. **gate 请求行多两列**：`"tool_id"`（`definition.id`——稳定 id，`ext:std/read` / `shell`，pin 与 usage journal 用的就是它）与 `"readonly"`（`true` / `false` / `null`，null 就写 JSON `null`）。列的顺序放在 `tool` 之后、`args` 之前。DESIGN §4 / §14 的 gate 那段与示例行同步；`step_stream.zig` 的既有 `--stream` 解析断言不能断（不带 `--gate` 一字不变）。
3. **`extensions/agent/src/runner.zig`**：删 `readonlyToolNames` / `collectReadonly` 与对 `ext inspect` 的 spawn；`gateVerdict` 改读请求行：`tool == "shell"` → `deny <note>`；`readonly == true` → `allow`；其余 → `deny <note>`（note 文案照旧、点名 tool_id）。`Args.readonly` 语义不变。`header.zig` 仍给 `wornPersona` / `parentIdentity` 用，不删。
4. **TUI**：`approvals.decide` 的 `manifest_readonly` 那一档改吃 gate 请求行上的 `readonly`（`App.tsx` 解析 gate 行的地方把新列传进去），`[approvals] manifest_readonly` 这个**键保留**（它说的是"信不信"）；deny 的 note 若点名包，用 `tool_id` 的 `ext:<id>/` 前缀，不再查 manifest。TUI 侧为审批而读 manifest 的代码删掉；其它用途（`/ext` 列表）不动。`bun test` 要过（先 `zig build` 刷新 `zig-out/bin/nulya.exe`）。
5. **pin ⇒ with**：`composition.resolve` 的 fresh 路在 `unionWith(… opts.with)` 之后：对 `pinned_native_tools`（config 与 `--pin` 的并集）里每个 `ext:<id>/…` 的 `<id>`，若不在已解析成员里，按 `WithRef{id, version=null}`（取 `current`）再 union 一次。没有 `current` → 仍是 `WithVersionNotFound`，**错误消息点名是哪个 pin 蕴含的**（`session new` 的 stderr 句子要让人看出"这是 pin 带进来的、包没有 current、用 `--with <id>@<v>` 或 activate"）。frozen 路（header `active`）零改动。`PinNamesUnknownExtension` 只剩"任何 root 都没有这个 id"这一种情况。**顺手修掉** `main.zig:270` 注释里记的那个内核 panic（`session new --with <可解析> --with <不可解析>`）：找到 `unionWith` 错误路径的释放问题，写单测钉住。
6. **`extensions/agent`**：`render` 不再派生 `--with`、不再预验证（`main.zig:218-300` 那段与 `:537-539`）——`render` 返回的参数组里 `with` 列表删除；TUI 的 `agents.ts` / `cli.ts` 跟随（`SessionExtras.with` 若只为此存在就删）。`pins.ts` 若有同样的派生也删。顶层 session 带 `agent` 包那条（`--with agent@<自身版本> --pin ext:agent/agent`）**保留**——那是按版本点名，不是 current。
7. **文档**：DESIGN §4（gate 请求形状）、§5.1（"pin 蕴含成员"一句）、§7.8（`agent` 的 "pins 要连带 `--with`" 一段改写、"readonly 由 gate 机械应答"一段改写）、§14（`--pin` 条目、gate 行示例）；tui.md §5.7 审批一段一句。
8. **e2e**：新文件 `tests/e2e/gate_pin.zig`：① `--gate --stream` 的请求行带 `tool_id` 与 `readonly`（pin 一个 `readonly: true` 的脚本 tool 与 `shell` 各一条）；② 一个 `activation: on_request` 的包，`session new --pin ext:<它>/<tool>` 不带 `--with` 照样开场、header `active` 含它；③ pin 一个没有 `current` 的包 → exit 1，stderr 点名 pin；④ bundled agent 的 explore 委派（既有用例）在 `ext inspect` 被移除依赖后照绿。

**不做**：`audience` 进 gate 行；TUI 审批 UI 改样子；`--with` 语义任何改动；`registry.pinned_native_tools` 的 config 语义改动。

### Lane C · `activation` 缺省按形状 + `ext run` 不套 timeout + `ext inspect` 只答 store

**做：**

1. **`manifest.activationOf`**：字段缺省时，`system_prompts.len > 0` → `.on_request`，否则 `.always`。显式写了就按写的。理由写在字段注释里（system prompt 是唯一"activate 即每场付费"的贡献；BUGS #1 的重演路径由此关掉；"向后兼容"兼容的是 8 个仓库内文件，不值一个危险缺省）。单测：prompt-only 无字段 → on_request；tool-only 无字段 → always；显式 `always` + prompt → always。`extensions/evolution` / `plan` 的显式 `on_request` **保留**（自文档）。`ext api permissions` 里 activation 那段**不要动**（Lane D 重写整段，会写成按形状）；DESIGN §7.2.1 的 activation 段同样归 Lane D；你改 **§7.5** 的 "discovery 只捡 `always` 的包" 一句（加上缺省规则）。TUI `extensions.ts` 若在任何地方把缺省读成 `always`（grep `activation`），改成同一条形状规则；`autoActivatable` 本来就按 system_prompts 判，不动。
2. **`ext run` 缺省不套 timeout**（`cli/ext.zig:890` 那处）；加可选 `--timeout-ms N`（正整数，上限仍 `tool.Timeouts.extension_max_ms`；给了才夹）。manifest `timeout_ms` 从此只是**模型工具面上一次 call** 的上限（loop 那条路零改动）。`ext_usage` 那一行加 `[--timeout-ms N]`；DESIGN §7.3（"native pin 的路径与 CLI 的路径读同一个字段"那句改写）、§7.8 的 "600 s 天花板" 一段删掉换成一句"`ext run` 不套 timeout，上限只在模型面"、§14 `ext run` 条目；CLAUDE.md 那行留给编排者改，你在 §6 记一句。`extensions/agent` manifest 的 `run.timeout_ms: 600000` 保留（它是模型面的数，而 `run` 永不 pin）。
3. **`ext inspect`**：`<id>` = **生效中**版本的冻结 manifest（`Roots.firstActive`），`<id>@<v>` = 那个版本，**没有 draft 回退**；想看 draft 用 `ext inspect <path>`（参数含路径分隔符、或是一个带 `extension.json` 的目录 → 打印那份 draft）。没有生效版本 → stderr `no active version of '<id>'; see nulya ext list` + exit 1。`ext_usage` / DESIGN §14 那两行改写；这次 diff 刚加的 inspect e2e 改成新语义。TUI grep `inspect` 看有没有调用方（`render/registry.ts:318` 只是画卡，不是调用）。
4. **e2e**：新文件 `tests/e2e/ext_cli.zig`：① 一个无字段的 prompt-only 包 activate 后 `session new` 不带它、`--with` 带它；② `ext run` 一个睡 2 s 的脚本 tool 在 manifest `timeout_ms: 1000` 下**不**超时、`--timeout-ms 500` 才超时；③ `inspect` 三种形态。

**不做**：`ext list` 的列；`activation` 词表；任何 TUI 展示改动。

### Lane D · manifest 按听众分层：`tui` → `ui`、`render`/`panel` → `tools[].ui`、`permissions` 出模板与自带包、`wear` → `with`、`ext api` 三层表

**问题**：manifest 14 个字段、三种听众（内核 / driver / 前端），JSON 形状没说哪个字段归谁读，`manifest.zig` 用 150 行注释解释纪律差别；`contributes.tui` 点名了一个具体前端；`render` / `panel` 是 TUI 布局词散在 tool 级；`permissions` 在 `src/` 里零读者却被八个 manifest 和两个模板照抄；`wear` 是 TUI 造的词冻进了内核解析的数据（`--with` / `wear` / `/with` / `session_with` 四个拼法一件事）。

**做（全是改名与搬家，语义零改动）：**

1. **`contributes.tui{entry, api}` → `contributes.ui{entry, api}`**：`manifest.Tui` → `Ui`，`dupTui` → `dupUi`，`InvalidTuiEntry` / `InvalidTuiApi` → `InvalidUiEntry` / `InvalidUiApi`，`build_ext.validateTui` / `TuiEntryFileMissing` → `validateUi` / `UiEntryFileMissing`；`cli/ext.zig` 的 `isManifestFault` 清单与测试；`extensions/plan` / `ask` 的 manifest；TUI 读它的地方（`plugins/host.ts` 等，grep `contributes.tui` / `.tui`）；tui.md / goals/tui-plugin.md 里指这个字段的地方改名（prose 里"TUI"照旧）。**不做兼容别名**——没有第三方冻结版本。
2. **`tools[].render` / `tools[].panel` → `tools[].ui: { render?, panel? }`**：`ToolSpec` 两个字段收成 `ui: ?ToolUi`（`ToolUi{render: ?[]const u8, panel: ?bool}`），缺省 null；`extensions/plan` 的 `todo`；TUI 读 `render` / `panel` 的地方（`extensions.ts` 的 Contributions 类型、`render/registry.ts`、`state/panels.ts` 等）。
3. **`permissions` 出自带包与模板**：八个 `extensions/*/extension.json` 删掉 `"permissions"`；parser 继续接受、`Manifest.permissions` 字段保留（M7 sandbox 给它读者时再回来）；`manifest.zig` 字段注释改成一句"声明、零读者、等 M7"。**模板（`templates.zig`）归 Lane A**，你不动它。
4. **`commands[].action: "wear"` → `"with"`**：`extensions/ask` / `plan` 的 manifest；`manifest.zig` 注释与测试里的词；TUI `commands.ts` / `packageCommands.ts` 认 `with`（`wear` 作为同义词再认一个版本期，warn 一句）；tui.md / goals/tui-plugin.md 里 action 词表的引用改成 `with`（屏幕文案"戴上"**不改**）。
5. **`policy` 的 "`null` 与 `{}` 不同"**收掉：`policy` 算作贡献 iff 它有内容（`readonly != null` 或 `deny` / `ask` 非空）；`{}` = 没说。`NoContributions` 判据相应改；测试改。
6. **`ext api permissions` 重写成三层**（这是 model-facing 文本，零文档引用）：**① 内核强制**（`id` / `runtime{entry, interpreter, wire}` / `tools[]{name, input, timeout_ms}` / `skills` / `system_prompts` / `activation`——含 Lane A 的 `wire` 与按平台 entry、Lane C 的 activation 缺省按形状，**按本契约最终状态写**）；**② driver 声明**（`readonly` / `audience` / `policy` / `permissions`：内核解析类型、冻结、不强制；`audience` 封闭词表认不出就拒，其余缺省 null = 没说）；**③ 前端声明**（`commands` / `tools[].ui` / `ui`：开放词表，认不出是读者的事）。每层一段，纪律各说一次，不再逐字段各说一遍。后面 authority / gate / timeout / trust 的段落保留（timeout 那段按 Lane C 改：`ext run` 不套、模型面才套）。
7. **DESIGN §7.2.1** 同样重组成三层（示例 JSON 改成新形状，含 `wire` 与 object entry 的例子；activation 段按 Lane C 的缺省规则写），**你拥有整个 §7.2.1**；§7.8 表里 `plan` / `ask` 两行的字段名跟着改。
8. **测试**：`zig build test` / `e2e`（`tests/e2e/extension.zig` 里断言 `tui` / `render` / `panel` / `permissions` 的地方改）；`cd tui && bun test`——**先 `zig build`**（二进制内嵌 `extensions/**`，manifest 改了必须刷新 exe），快照有意变更在 §6 列出。

**不做**：任何字段的语义；`audience` / `activation` 的词表与纪律；`readonly` 三处的统一（只在 §7.2.1 加一段并排说清三者）；新字段。

## 2. 完成标准（每条 lane 各自满足）

- `zig build test` 与 `zig build e2e` 在本机（Windows，Zig 0.16）全绿；动了 TUI 的 lane 还要 `cd tui && bun test` 全绿（已知恒红的 `pwsh` plugin fixture 条不算；perf / lease 两条在并行负载下会 flake，单独重跑一次再定）。
- 既有测试断言不减弱；新行为有 e2e 钉死（各 lane 的新文件）。
- model-facing 文本（usage / `ext api` / kernel prompt / SKILL.md / tool description）零文档引用（e2e 有断言）。
- **不 commit、不 push**；改完 `git add -A` 把新文件纳入索引（合并时从 `git diff --cached` 取）；在 §6 自己那一节逐条记下做了什么、偏离了什么、快照变了哪些。
- 代码注释英文、docs 中文；`zig fmt` 只 fmt 自己改的文件（整目录 fmt 会把没动的 CRLF 文件全改成 LF）。

## 3. 已定决策（全 lane 通用）

- **D1 · 内核只长 substrate。** 本契约唯一进 `src/extension/` 与 `src/loop.zig` 的语义改动是 plain wire（extension 执行的 substrate）与 gate 请求多两列（冻结事实的投影）；其余全是壳层、extension、docs。
- **D2 · 两根轴不变**：成员（activate 每场 / `--with` 这场）× 工具面（`pinned_native_tools` 每场 / `--pin` 这场）。pin ⇒ with 是推论不是第三根轴：`--with` 仍独立存在（成员而不上面）。
- **D3 · 纪律只有两种**：内核强制的（类型错 parse 拒、值错 validate 拒）与声明（类型错 parse 拒；封闭词表值错 validate 拒、开放词表永不拒；缺省 null = 没说）。不新增第三种。
- **D4 · 改名不留兼容别名**（`tui` → `ui`、`render/panel` → `ui{}`），唯一例外是 `wear` 作为 `with` 的同义词在 TUI 里多认一个版本期——它写在人的 `tui.toml` 与 manifest 里都有。
- **D5 · string result 规则不加第二条**：plain wire 的 stdout 就是 §7.3 的字符串结果。
- **D6 · timeout 的归属**：manifest `timeout_ms` 是模型工具面上一次 call 的上限；driver 在自己的进程里 `ext run`，挂不挂是它的事。
- **D7 · `permissions` 留字段、出文件**：parser 接受；模板与自带包不写；读者等 M7。
- **D8 · `activation` 缺省按形状**，显式写了按写的；词表不变。
- **D9 · `inspect` 只答 store**；draft 用路径问。
- **D10 · kernel prompt / builtin 定义零改动**，`kernel_hash` 不变；CLAUDE.md 由编排者在合并后统一改，lane 不动它。

## 4. 参考（先读这些）

- 评审本身：本文件 §1 各 lane 的"问题"段。DESIGN §7.1–§7.5、§4、§9、§14；CLAUDE.md 模块表。
- `src/extension/manifest.zig`（整个文件；Lane A 看 `Runtime` / `isScript` / `validate` 的 runtime 段与 `:759-800` 的脚本测试；Lane C 看 `activationOf` / `:954` 测试；Lane D 看 `ToolSpec` / `Tui` / `Policy` / `validate` 与 `:1043+` 的 tui-plugin 测试）。
- `src/extension/invoke.zig`（`invokeTool` / `Options`）、`src/environment.zig`（`runExtensionImpl`：env 净化 + `NULYA_EXE`，plain 的 env 加在这里；`shellArgv` / interpreter 的 argv 决定）、`src/extension/protocol.zig`（模块注释 = `ext api protocol` 打印的东西）、`src/extension/build/templates.zig`、`src/extension/build/build_ext.zig`（`validateSystemPrompts` / `validateTui` 先例）。
- `src/loop.zig:150-170`（`ToolGate`）、`:370-380`（gate 在 `execOne` 前的那一处）；`src/cli/step_stream.zig:295-350`（`StepGate` 写请求行）；`src/tool.zig`（`ToolDefinition`）；`src/extension/tools.zig`（`Binding.init`）。
- `src/composition.zig:296-300`（`resolve` fresh 路）、`:420-440`（pin 解析与 `PinNamesUnknownExtension`）、`:555+`（`unionWith`）、`:1561`（pin 错误测试）。
- `src/cli/ext.zig:163-180`（`ext_usage`）、`:880-900`（`ext run` 的 timeout）、`:1354-1412`（`extInspect`）、`:1420-1552`（`extApi` 三个 topic）、`:1554+`（`isManifestFault`）。
- `extensions/agent/src/runner.zig:231-310`（`gateVerdict` / `readonlyToolNames` / `collectReadonly`）、`main.zig:218-300` 与 `:520-560`（with 派生与 spawn argv）。
- TUI：`tui/src/approvals.ts`、`extensions.ts`（`Contributions` / `pinsOnActivate` / `autoActivatable`）、`commands.ts` / `packageCommands.ts`（`wear`）、`plugins/host.ts`（`contributes.tui`）、`render/registry.ts` / `state/panels.ts`（`render` / `panel`）、`pins.ts`、`agents.ts`、`ui/App.tsx`（gate 行解析）。`bun test` 必须在 `tui/` 下、且先 `zig build`。
- `tests/e2e/extension.zig`（既有用例的写法；`support.zig` 的 testkit），`tests/e2e.zig:79-90`（aggregator，新文件加一行）。
- 本机：Windows 11，`zig` 是 anyzig shim（`zig build …` 正常；裸 `zig test f.zig` 要写 `zig 0.16.0 test f.zig`）；没有 `rg`；二进制 `zig-out/bin/nulya.exe`。

## 5. 文件归属（并行合并的约定）

| 文件 / 区域 | A | B | C | D |
|---|---|---|---|---|
| `manifest.zig` `Runtime` / runtime 段 validate / 脚本测试 | ✓ | | | |
| `manifest.zig` `activationOf` + 那条测试 | | | ✓ | |
| `manifest.zig` `ToolSpec.ui` / `Ui` / `Policy` / tui-plugin 测试 / `permissions` 注释 | | | | ✓ |
| `invoke.zig` / `environment.zig` / `protocol.zig` / `templates.zig` / `build_ext.zig`（entry 变体校验） | ✓ | | | |
| `build_ext.zig`（`validateTui` 改名） | | | | ✓ |
| `tool.zig` / `loop.zig` / `step_stream.zig` / `extension/tools.zig` / `composition.zig` | | ✓ | | |
| `cli/ext.zig` `extInit` + `ext api examples` 脚本段 | ✓ | | | |
| `cli/ext.zig` `extRun` / `extInspect` | | | ✓ | |
| `cli/ext.zig` `ext api permissions` + `isManifestFault` 清单 | | | | ✓ |
| `cli/common.zig` `ext_usage`（各改自己那一行） | ✓ | | ✓ | |
| `cli/session.zig`（pin 错误消息） | | ✓ | | |
| `extensions/*/extension.json` | | | | ✓ |
| `extensions/agent/src/*` | | ✓ | | |
| TUI `approvals.ts` / `App.tsx` gate 解析 / `agents.ts` / `pins.ts` / `cli.ts` | | ✓ | | |
| TUI `extensions.ts`（activation 缺省） | | | ✓ | |
| TUI `extensions.ts`（ui 类型）/ `commands.ts` / `packageCommands.ts` / `plugins/host.ts` / `render` / `panels` / 快照 | | | | ✓ |
| DESIGN §7.1 / §7.3 / §7.4 / PLAN §0.1 #3 §3.3 | ✓ | | | |
| DESIGN §4 / §5.1 / §7.8（agent 两段）/ §14 gate 与 `--pin` 条目 | | ✓ | | |
| DESIGN §7.5 / §7.8 "600 s" 段 / §14 `ext run` `inspect` 条目 | | | ✓ | |
| DESIGN §7.2.1（整节）/ §7.8 表里 plan、ask 两行 / tui.md / goals/tui-plugin.md | | | | ✓ |
| DESIGN §14 `ext init` 行 | ✓ | | | |
| `tests/e2e.zig` 各加自己一行 import；新文件各自 `tests/e2e/<lane>.zig` | ✓ | ✓ | ✓ | |
| CLAUDE.md | 编排者 | | | |

两条 lane 都要碰同一个文件时（`manifest.zig` / `cli/ext.zig` / `common.zig` / `build_ext.zig` / `extensions.ts` / e2e `extension.zig`），**各自只动表里归自己的函数 / 段落**，新测试放自己的新文件里。

## 6. 进度区（各 lane 在自己一节下记；不要动别人的）

### A · 脚本 wire

（待填）

### B · gate 声明 + pin ⇒ with

（待填）

### C · activation 缺省 / ext run timeout / inspect

（待填）

### D · manifest 分层

（待填）
