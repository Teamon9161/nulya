# Goal · ext-review-3：一种 wire + 两轮评审的收尾（2026-08-23 拍板）

> 这是一份**执行契约**（2026-08-23 拍板）：§1–§3 的决策已定，不要重开；认为错了就写进 §6 自己那一节的 `BLOCKED:` 并停下。按 [ext-review-2.md](ext-review-2.md) 同一套方式跑（契约 → lane → 审 diff → 合并）。**S 在 worktree 里与 W 并行，两者文件不重叠；R 在两者合并之后跑。**地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7。
> 来源：2026-08-23 两轮 extension 评审（[ext-review.md](ext-review.md)、[ext-review-2.md](ext-review-2.md)）落地后剩下的三件事。

## 0. 为什么还有一批

ext-review-2 把概念收成了：`activate` 一个意思、成员 × 工具面的 2×2、manifest 三层各说一次、`ext init` 缺省 plain。**还剩的不是概念，是两套并存的东西**：

1. **两种 wire 并存**。`plain` 今天已经能服务每一个 consumer（模型面、`ext run`、TUI 解析 JSON 的 driver tool、错误文本），但六个自带编译包仍说 `jsonrpc`，于是仓库里同时活着两份契约、三份互相复制的 `rpc.zig`（`std` 217 行 / `agent` 156 / `plan` 140）与三处内联信封（`handoff` / `compact` / `ask`）、内核里 `protocol.zig`（313 行）+ `invoke.invokeJsonRpc` 一整条路。一个要写扩展的 AI 打开 `nulya ext api protocol` 看到的是两节，而它只需要一节。
2. **三轮 lane 各自改过 model-facing 文本**（`nulya help` / `ext api` 三个 topic / guide `SKILL.md` / kernel prompt），没有人从头到尾读过一遍——漂移最容易藏在这里。
3. 几件小的：测试 scratch 目录不清理、一个撞名的 state 键、两处残句。

## 1. Lane W · 一种 wire（opus）

### 1.1 什么叫"迁到 plain"

一个 tool 被调用时，进程边界上只有三样东西：stdin、stdout、退出码。两种 wire 的区别只是这三样东西里装什么：

```
                jsonrpc（今天自带包用的）                       plain（今天 ext init 缺省的）
stdin   {"jsonrpc":"2.0","id":"call","method":"tool/call",     {"path":"a.txt"}            ← 参数对象本身
         "params":{"name":"read","arguments":{"path":"a.txt"}}}  env: NULYA_TOOL=read        ← tool 名在 env
stdout  {"jsonrpc":"2.0","id":"call","result":"<文件内容>"}       <文件内容>                   ← 原文就是结果
失败    {"jsonrpc":"2.0","id":"call","error":{"code":-32602,     stderr: missing `path`      ← 消息写 stderr
         "message":"missing `path`"}}                            exit 1                      ← 退出码就是成败
```

模型最终看到的字节**一样**：成功是结果原文，失败是一句话（今天是 `extension error [-32602]: missing \`path\``，plain 是 `exit 1` + 那句话）。`ext run` 打印的也一样（driver tool 打 JSON 到 stdout，TUI 照样 `JSON.parse`）。所以"迁"= 每个包删掉**读信封、回 id、拼信封**那一半代码，manifest 加一行 `"wire": "plain"`；tool 逻辑本身一个字不动。

### 1.2 为什么弃用 jsonrpc——不是复杂，是多余

- jsonrpc 比 plain **多**的三样东西今天都没有读者：`id`（oneshot 进程，每次只有一个请求，回显它只是仪式）、`error.code`（到模型那里只是一个数字）、`error.data.retryable`（内核从不读）。
- 它**少**的东西没有：plain 的 stdout 可以是 JSON（driver tool）、也可以是文本（模型面）。
- 留它的唯一理由是将来 persistent runtime / streaming 需要**分帧**——那是"先测量再做"的事（PLAN §3.3），到时候按实测需要设计一种帧，不必今天养着一种没人用其特性的。
- 代价是实打实的：AI 要读两份契约、`ext init --zig` 模板与自带包形状不一致（"示范代码"与"真实代码"两套）、内核多 ~300 行只为一种 wire、三份 `rpc.zig` 互相复制漂移。

**不弃用也行**——今天"两种 wire、plain 缺省"已经能用。但按"核心足够简单、方便 AI 了解和扩展"这把尺子，一种 wire 是终态。

### 1.3 已定决策

- **W1 · 六个自带编译包迁 plain**：`std` / `agent` / `plan` / `handoff` / `compact` / `ask`。每个包：`main` 读 stdin 为参数对象、按 `NULYA_TOOL` 分发（多 tool 的包）、结果写 stdout（文本或 JSON，与今天 `result` 的内容逐字节相同）、失败 = 消息写 stderr + `exit 1`；删 `rpc.zig` 的信封那一半（`readRequest` / `writeResponse` / id），`Outcome` 可以留作内部类型；manifest 加 `"wire": "plain"`。**退出码不做词表**（不区分 -32602 / -32000——消息本身已经说清，一个数字没有读者）。
- **W2 · e2e 断言**：`tests/e2e/std.zig:102`、`std_fs.zig:66`、`std_search.zig:218-225` 五处从 `extension error [-32000]: …` 改为 plain 的失败文本（`exit 1` + 消息）；其余自带包的 e2e 若有同类断言一并改。TUI 若有按前缀识别失败文本的地方（grep `extension error`）同步——今天 grep 为零。
- **W3 · jsonrpc 降级**：`protocol.zig` 顶部把 plain 写成**唯一推荐**、jsonrpc 标 `deprecated`（认一个版本期，给仓库外写的扩展）；`ext api protocol` 随之（它打的就是这个文件）；`ext api examples` 不再提 jsonrpc。**下一个版本**删 `protocol.zig` 的 `ToolCallRequest` / `decodeResponse`、`invoke.invokeJsonRpc`、`manifest.Wire.jsonrpc`——那一步单独一条 lane，等一个版本期过去。
- **W4 · 文档**：DESIGN §7.1 / §7.3（两种 wire → 一种 + 一段"jsonrpc 为什么退场"）、§7.8 表格的 kind 列、CLAUDE.md 现状段与模块表 `protocol.zig` / `invoke.zig` 行、guide `SKILL.md`、各包 `main.zig` 顶部"Why compiled Zig"那段（理由从"要解析 JSON-RPC"改成真正的理由：regex / walker / 解析 `session step` 的 JSONL）。
- **不做**：persistent runtime；streaming；改 `plain` 契约的任何字节。

## 1b. Lane D · 删 jsonrpc 代码路径（opus，W 之后立刻；2026-08-23 拍板：不等版本期）

W3 原定"等一个版本期再删"。拍板改为现在删：仓库内已无人说 jsonrpc，仓库外还没有人写过扩展，一个版本期保护不了任何人，而留着的是内核里一整条没有读者的路。

### 1b.1 已定决策

- **D1 · 只有一种 wire，所以没有 `wire` 字段。** 删 `manifest.Wire`、`Runtime.wire`、`wireOf`、`InvalidWire` 与相关单测。manifest 里的 `wire` 键从此是未知键：`parse` 记下写的值（`Manifest.legacy_wire: ?[]const u8`），`build_ext.noteLegacyShapes` 打一行——写 `"jsonrpc"` 的说"那种 wire 已经没有了，这个 runtime 会按 plain 被调用：stdin 是参数对象、stdout 原文是结果、退出码是成败——见 `nulya ext api protocol`"；写 `"plain"` 的说"这个键不再需要，plain 是唯一的 wire"。六个自带包的 manifest 与 `templates.zig` 的两个模板都删掉这一行。
- **D2 · `protocol.zig` = 契约 + 契约里两条纯规则。** 删 `jsonrpc_version` / `method_tool_call` / `ToolCallRequest` / `ErrorBody` / `DecodedResponse` / `DecodeError` / `decodeResponse` / `stringField` / `compactValue` 与它们的单测；模块注释只剩 plain（jsonrpc 那一节整个删，不留"deprecated"——退场的理由留在 DESIGN §7.3 一段里，model-facing 文本不讲历史）。把 `invoke.zig` 里**两边都要遵守的纯规则**搬进来并带着单测：`normalizedArguments`（"没有参数就是 `{}`"）与 `NULYA_TOOL` / `NULYA_ARG_<k>` 的导出规则（`PlainEnv` + `isEnvSafeKey`，哪些键导出、NUL 跳过）——于是 `nulya ext api protocol` 打印的就是契约与它的实现，`invoke.zig` 只剩 spawn、捕获与失败文本。
- **D3 · `invoke.zig`**：删 `invokeJsonRpc`、`request_id`、`Options.wire`、所有 jsonrpc 单测与只为它存在的 `invokeToolAllocSweep`；`invokeTool` 直接走 plain。`ToolInvocation` 与失败文本（`exit <code>` / `stderr:` / `stdout:`）一个字节不变（e2e 与 TUI `toolSaid` 都读它）。
- **D4 · 调用链**：`tools.Binding.wire` 与 `initOwned` 的 `wire` 参数删；`composition.zig` / `cli/ext.zig` 的 `rt.wireOf()` 传参删；`environment.zig` 里凡是把 stdin 叫作"JSON-RPC request"的注释改成"这次调用的参数对象"（`request_json` 这个字段名若改成 `stdin_json` 就一起改到 `FakeEnv`，不改也行，但注释必须是真的）。`extensions/std/src/rpc.zig` 顶部残留的 jsonrpc 一句删。
- **D5 · 测试**：`tests/e2e/support.zig` 的 `jsonrpc_main_zig` / `jsonRpcManifestJson` 改成 plain 夹具（`greetSource` 改写一个打印 greeting 的 plain `main`；`extension.zig` 的 `failing_main` 改成 stderr + `exit 1`）；`script_wire.zig` 里"老 jsonrpc wire 照绿"那条测试删；`extension.zig` / `ext_cli.zig` 里经 `protocol.decodeResponse` 断言的地方改成直接断言 stdout；`gate_pin.zig` 的 manifest 字符串删 `"wire":"plain"`；`tests/e2e.zig` 头注释。
- **D6 · 文本**：`ext api manifest`（`cli/ext.zig`）删 `runtime.wire` 那句；DESIGN §7.1 / §7.3（"一种 wire"；jsonrpc 只留一段过去时的"曾经有、为什么退场"）、§7.8、§14；CLAUDE.md 模块表 `protocol.zig` / `invoke.zig` / `manifest.zig` 行与现状段（W 那条加"代码路径已删"）；guide `SKILL.md` 的 `runtime.wire` 那条删。
- **不做**：`plain` 契约任何字节；persistent / streaming；`kernel_hash` 不动（kernel prompt 不碰）。

### 1b.2 验收

`zig build test`、`zig build e2e`、`zig build && cd tui && bun test`（TUI 经 `ext run` 跑真二进制，失败文本形状不能变）。

## 2. Lane R · model-facing 文本一致性复读（sonnet，在 W 之后）

- **R1**：一个读者按模型会走的顺序从头读一遍——kernel prompt（`composition.zig` 常量）→ `nulya help` → `nulya ext api protocol` / `manifest` / `examples` → `extensions/guide/skills/guide/SKILL.md`——对照 DESIGN §5.1 / §7.1 / §7.2.1 / §14 **今天**的语义，列出每一处矛盾或过时（重点：`activation` / `permissions` / `policy.deny` 残留、`commands[].action` 对象形式、`ui` 按宿主、`--bare`、`[extensions] with`、`ext run` 形状、一种 wire），逐处修正。
- **R2**：`nulya help` 仍一屏（e2e 有行数预算）；model-facing 文本**零文档引用**的 e2e 仍绿。
- **R3**：同一遍也读 TUI 的 `/help` 文案与 `Welcome.tips`，对照 tui.md T48–T50。
- **R4**：DESIGN / CLAUDE.md / PLAN 里 grep `on_request` / `activation` / `permissions` / `PolicyAllowNotPermitted` / `jsonrpc`，历史叙述加一句"（已删，ext-review-2/3）"或删；`docs/goals/ext-review.md` 与 `ext-review-2.md` 是历史契约，不改。

## 3. Lane S · 小件（sonnet，最先做）

- **S1** · `tui/test/isolate.ts` 的 scratch `NULYA_HOME`（`mkdtempSync`）退出时 `rmSync(..., {recursive, force})`——今天 `%TEMP%` 里已堆 786 个 `nulya-*`。
- **S2** · `tui-state.json` 的 `session_with`（K8 新加，`/ext` 写的常驻清单）与 `tui.toml [extensions] session_with`（TUI 恒带的 `handoff` / `agent`，按精确版本）**撞名**。改 state 键为 `standing_with`，读旧名一个版本期；`tui_state.ts` 那段"Not to be confused with…"注释随之消失。
- **S3** · 残句：tui.md §7 提到已删的 `autoActivatable`（只动 tui.md——DESIGN / CLAUDE.md 的残留归 R4，免得与 W4 撞文件）。

## 4. 验收

```bash
zig build test
zig build e2e
zig build && cd tui && bun test && bun run typecheck
```

## 5. 顺序

**S ∥ W，然后 R**。S 只碰 `tui/` 与 tui.md，W 只碰 `extensions/`、`src/extension/{protocol,invoke}.zig`、`tests/e2e/`、DESIGN §7、CLAUDE.md、guide——不重叠，所以并行；R 放最后，对**最终**状态做一遍一致性复读，而不是对中间状态。

## 6. 进度（拍板后各 lane 在自己那节追加）

### Lane S

**完成**（sonnet，worktree，与 Lane W 并行）。三件小事，只碰 `tui/**` 与 `docs/tui.md`，内核零改动。

- **S1**：`tui/test/isolate.ts:22-33` — scratch `NULYA_HOME` 现在在 `process.on("exit", …)` 里 `rmSync(scratchHome, {recursive:true, force:true})`（`try/catch` 吞掉失败，best effort）。文件顶部解释隔离理由的注释未动。
- **S2**：`tui/src/state/tui_state.ts` 的 STATE 键 `session_with` 改名 `standing_with`（interface 字段 `:84`、`loadTuiState` 读两个键名一个版本期只写新名 `:131-143`、导出函数改名 `sessionWith`→`standingWithIds` / `rememberSessionWith`→`rememberStandingWith` `:194-201`，避开 `tui/src/extensions.ts` 的谓词 `standingWith`）；"Not to be confused with…" 澄清注释删除。调用点全部跟上：`tui/src/ui/overlays/ExtView.tsx`（import + 4 处调用 + 2 处注释）、`tui/src/ui/App.tsx`（import + 1 处调用）、`tui/test/overlays.test.tsx`（import + 2 处调用 + 1 处历史叙述性注释同步改名）、`tui/src/extensions.ts`（1 处注释）。`tui.toml` 的 `[extensions] session_with`（`state/settings.ts`）与它在 `pins.ts`/`handoff.ts`/`App.tsx`/`ExtView.tsx` 里的其余引用**一字未动**——grep 过每一处，确认是那个人写的设定而不是这个 state 键。`docs/tui.md` §11 里 K8/T1/T48/T50 历史日志对 state 那半的旧称呼也**没有**回填改名（与 `auto`→`unsafe` 那条同一先例：历史条目描述的是当时的名字）。
- **S3**：`docs/tui.md` §7 两处 `autoActivatable` 残留都改了——TOML 样例里 `auto_activate` 那行内联注释（原 `**带 system prompt 的包除外**，T31`，现在说 `activate 只是移指针，T50`）与它下面那段散文（重写：activate 今天只移 `current` 指针、不改变 composition；进不进 session 是 `/ext` Enter 的 standing pins / standing with 两半决定，对模式包 Enter 永不写 standing with，T48/T50）。§11 里其余 8 处 `autoActivatable` 提及全在历史日志段落（T34/T37/T41/T46/T48 等），描述的是它存在时的行为，按惯例不改。
- **旁及发现，未动**：同一段 TOML 样例里 `handoff = true` 那一行（`docs/tui.md:412`）与代码不符——T34 起 `[extensions] handoff` 已经是列表键 `session_with = ["handoff", "agent"]`，旧布尔键只在读的时候认（`withPackage`）。与 S3 认领的 `autoActivatable` 残留是两回事，超出这条任务的范围，留着给下一次经过这段文档的人（不是 Lane R 的 model-facing 文本复读范围，也不是 DESIGN/CLAUDE 残留）。

**验收**：`zig build`（首次 worktree，成功）；`cd tui && bun run typecheck`（干净）；`bun test` 全量 365 pass / 0 fail（一次跑干净，无超时）；针对改动最集中的四个文件（`overlays.test.tsx` `extensions.test.ts` `consumers.test.tsx` `pins.test.ts`）单独重跑时丢过一条无关的 lease 等待测试超时（`/sessions marks a session somebody else is driving as live`，与 `standing_with` 改名无关），单独重跑该测试即绿——`project-nulya-tui-test-gotchas.md` 记过的既有类别。

### Lane W

**W1 · 六个包迁 `plain`**（`zig build test` / `zig build e2e` 全绿）。每个包的 `main` 现在是同一形状：读 stdin 的参数对象 → 按 `NULYA_TOOL` 分发（单 tool 的包忽略它，因为它说不出新东西）→ 一个 `answer()` 把结果打 stdout + exit 0，或把消息打 stderr + exit 1。manifest 各加 `"wire": "plain"`。tool 逻辑一个字未动。

| 包 | 删掉的 | 行数 |
|---|---|---|
| `std` | `rpc.zig` 的 `readRequest` / `writeResponse` / `Request` / `fallback_id` / 三个码 / `Fail` / `invalidParams`；`main.zig` 的信封分发 | rpc 217 → 167，main 127 → 140（`std_options` 见下） |
| `agent` | 同上；`Outcome.json` 并进 `.text`；`failed()` 去掉 `code` 参数 | rpc 156 → 110，main 750 → 738 |
| `plan` | 同上 | rpc 140 → 94，main 277 → 268 |
| `handoff` | 内联信封（`writeResponse` / `call_id` / `Fail`）+ `readBrief` 里那两层 `params.arguments` | main 258 → 230 |
| `compact` | 同上 + `readArgs` 的两层 + `fail()` 的 `code` 参数 | main 566 → 537 |
| `ask` | 同上 + 整个 `arguments()` 辅助函数 | main 222 → 172 |

**退出码不做词表，落到了类型上。** 三个码删掉之后 `Fail{code, message}` 只剩一个 message，于是 `Outcome.failed` 直接是 `[]const u8`；`refuse` 与 `invalidParams` 变成同一个函数（都是"消息 + exit 1"），并成 `refuse`（`std` 的六个 tool 模块因此各有几处纯改名，是这条 lane 里唯一碰到 tool 逻辑文件的改动）；`agent` / `plan` 的 `Outcome.json` 与 `.text` 在 plain 上都只是"把这些字节打到 stdout"，并成 `.text`。**driver 面的字节没变**：`render` / `list` / `approve` / `compact` / `handoff` 照旧打同一个 compact JSON，`tui/src/nulya/cli.ts` 的 `JSON.parse` 与 `drivers/goal.*` 的 `grep -o '"session":"s-…'` 都不用动。

**一处新纪律，是迁移本身逼出来的：plain 上 stderr 就是失败消息，所以包必须独占 stderr。** `extensions/std` 里 vendored 的 mvzr 用 `std.log` 打了一行 `error(mvzr): missing closing parenthesis`，从前谁也看不见（jsonrpc 的 application error 分支不附 stderr），迁过来之后它挤在教学文案**上面**——一个库的调试行，出现在模型要照着改的那句话里。修法是 `extensions/std/src/main.zig` 声明一个空的 `std_options.logFn`：这个二进制没有第二种输出，refusal 该说什么已经逐句写好了。（`compact` 的 `warn()` 不受影响：它只在成功路径上说话，那时 stderr 照旧被丢弃。）

**W2 · e2e**：`std.zig:102` / `std_fs.zig:66` / `std_search.zig:218,222,225` 五处从 `extension error [-32000|-32602]: …` 改成 `exit 1\nstderr:\n` + 同一句文案（`invoke.invokePlain` 拼的形状），**每一句教学文案原样保留**；`extension.zig:3014,3037`（`plan propose {}` / `ask {}`）两处 `indexOf("-32602")` 改成 `startsWith("exit 1\nstderr:\n")`。`handoff` / `compact` 的 e2e 一个字没改——它们本来就 `JSON.parse` stdout。`tests/e2e.zig` 顶部那句"a string JSON-RPC `result`"随之改写。仓库里 `extension error [` 的最后一个写者只剩 `invoke.invokeJsonRpc`。

**W3 · jsonrpc 降级**：`protocol.zig` 模块注释重写——`plain` 在前、写成唯一要写的 wire（多一句"stderr 就是模型读到的消息"），jsonrpc 一节标 **DEPRECATED** 并写清它为什么退场（多的三样 `id` / `error.code` / `error.data.retryable` 一个读者都没有，少的东西没有，分帧留给真需要它的那天按用途设计）。`ext api manifest` 的 `runtime.wire` 一句、`ext api examples` 里那句"--zig scaffolds the JSON-RPC one"随之改；顺带把 `manifest.zig` 的 `Wire` 枚举文档（plain 在前、jsonrpc 标 deprecated）、`templates.zig` 顶部、`tools.zig` 那句"`definition.name` 是 JSON-RPC name"一起改准。**`ToolCallRequest` / `decodeResponse` / `invokeJsonRpc` / `Wire.jsonrpc` 一个都没删**，缺省仍读作 jsonrpc，e2e 里那些合成 fixture（`support.jsonrpc_main_zig` 等）照旧证明它能跑。

**W4 · 文档**：DESIGN §7.1（wire 段拆成"要写的只有 plain"+"jsonrpc 已 deprecated"两段）、§7.3（开头一句、plain 的 stdout 那行补一句 driver 面打 JSON、jsonrpc 小节标 DEPRECATED、末尾新增一段"为什么 jsonrpc 退场"）、§7.6（"只拿 JSON-RPC request" → "只拿这次调用的 arguments"）、§7.8（表前一句加"六个有 runtime 的都说 plain"；`agent` 的"`params.name` 分发" → "`NULYA_TOOL` 分发"）、§11（`compact` 的 `-32001`、`handoff` 的 `-32602` 与"要读 JSON-RPC 请求、回同一个 id"的理由）、§15.1 那张表一行、架构图一处；CLAUDE.md 加一条 ext-review-3 W 的现状 bullet + 改 `protocol.zig`/`invoke.zig` 那一行 + 两处旧叙述；`extensions/guide` 的 SKILL.md 那一条；`docs/goals/std.md` 的 D6（它是 `std` 的活契约，写着"错误 = JSON-RPC error … `-32602`/`-32000`"）。各包 `main.zig` 顶部的"Why compiled Zig"改成真正的理由——`std` 是 regex + gitignore walker + `edit` 的归一化回退，`agent` 是 `run` 要逐行读 `session step` 的 JSONL 并在管道上答 gate，`plan` / `handoff` / `ask` 是"把几个分节/选项当一组校验"，`compact` 本来写的就是"要解析 JSONL"、未动。

**没做 / 留给别人**：`tui/src/compact.ts:86` 与 `tui/src/nulya/cli.ts:790` 两处注释仍写着"the JSON-RPC error the CLI prints"——**行为没变**（非零退出、消息在 stdout），只是措辞过时了；本 lane 不碰 `tui/**`（Lane S 的地盘），留给 R 或 S 顺手改。`docs/goals/ext-review.md` / `ext-review-2.md` 是历史契约，未改。

### Lane R

**完成**（sonnet，主工作树，在 S/W 合并之后）。R1 是从 kernel prompt 读到 `nulya help` 读到 `ext api` 三个 topic 再到 guide `SKILL.md` 的一次顺读，对照今天的 DESIGN §5.1/§7.1/§7.2.1/§14；R4 是对 DESIGN/CLAUDE/PLAN/tui.md/base-tools.md/agents-and-review.md 的一次 grep 复读。**大部分文本已经是准的**——kernel prompt、`nulya help`（跑的是真二进制）、`ext api protocol/manifest/examples`、guide SKILL.md、`notes.zig` 的 `noteText`、TUI 的 `/help` 与 `Welcome.tips` 逐一读过，均与今天的语义（一种 wire、`policy{readonly}`、`commands[].action` 对象、按宿主 `ui`、`--bare`、`[extensions] with`）一致，没有改动（详见下面"读过、没动"）。改动全在 DESIGN.md / CLAUDE.md / PLAN.md，六处：

- `docs/DESIGN.md:621`（§7.8 `plan`/`ask` 一节）：**当前状态错误**——原文说"`session new --parent` 不带 `--with`、`plan` 又声明 `on_request`"，但 `activation` 字段已在 ext-review-2 Lane K 整个删除（验证：`extensions/plan/extension.json` 里根本没有 `activation` 键）。改成"`session new --parent` 不带 `--with`（composition 一律现解，不继承，§5.1）"——保留原意（fork 不带 persona），去掉对已删字段的引用。
- `docs/DESIGN.md:845`（`nulya help` 一节）：**当前状态错误**——原文说"当前 45 行"，但 `zig build && nulya help | wc -l` 与 `tests/e2e/cli.zig:72` 的预算都是 52（`git blame` 找到两笔未记的增量：background task 动词族 `47b80a8` +6，`--bare` 的 `4e19d27` +1）。改成"当前 52 行"，先例列表补上 `task` 整个动词族 +6、`--bare` +1。
- `docs/DESIGN.md:440`（§7.2.1 driver 声明，`readonly?`）：`readonly?` 与已删的 `permissions` 字段"完全同级（§9）"这句在 §7.2.1 自己 12 行之后才说明 `permissions` 已删——顺序读容易先当它还在。改成引用 §9 那句"没有一个 manifest 字段是安全边界"本身，不再点名一个已经不存在的字段。
- `docs/DESIGN.md:379` 与 `CLAUDE.md:47`（同一句，`ext seed` 的记录理由）：`evolution` 的 `activation: on_request` 作为历史例证与仍然存在的 `agent.audience` 并列，没有任何标记说前者已经不在 schema 里。各加一句"该字段现已删，§7.2.1" / "该字段后来被删，见下面 ext-review-2 Lane K 那条"。
- `docs/PLAN.md:300`（§3.8.1，readonly 与 permissions 对比）：同一种问题更明显——本节自己在两段之前（§3.8）刚说"2026-08-23 删掉了"，这里却接着说 readonly "它与 `permissions` 同级——两者都要等 §3.8 的 OS 强制才谈得上边界"，读起来像 permissions 还在等沙箱而不是已经没了。改成"要等 §3.8 的 OS 强制才谈得上边界（已删的 `permissions` 字段曾经也是这一类声明，见上）"。
- `CLAUDE.md:50`（gate 那条现状 bullet）：同一处比较，加"当时"两字并指向后面 manifest 瘦身那条的删除记录。

**读过、没动，附理由**：

- kernel prompt（`src/composition.zig:47`）：57 词，逐句核对——`shell` 是唯一 builtin、pin 冻在场首、ledger 角色那句——都与今天的行为一致，没有一个字提到已删的机制。改它会动 `kernel_hash`，不值得为纯文风改一次。
- `nulya help`（`src/cli/common.zig` 的六个 `*_usage` 常量 + `usage()`）：跑的是 `zig build` 之后的真二进制，52 行，`ext run`/`session new --bare`/`--prompt`/`ext seed`/`ext trust` 等全部与 DESIGN §14 逐行对齐；e2e 预算 52 与实测相符（本 lane 未改预算本身，只改了 DESIGN.md 里那句描述性数字）。
- `nulya ext api protocol`：打印的是真实 `src/extension/protocol.zig` 源码（`nulya src` 的特例），plain 在前、jsonrpc 一节明确标 DEPRECATED 并解释"为什么退场"——这份文本允许出现 `DESIGN §`（e2e 的零引用断言只检查 `manifest`/`examples`/`help`，见 `tests/e2e/cli.zig:163`），不受 R2 约束。
- `nulya ext api manifest` / `examples`：三层声明（内核强制/driver 声明/前端声明）逐段核对，`policy` 只剩 `{readonly}`、`commands[].action` 是对象、`ui` 按宿主键、`--bare` 与 2×2 表都在，零 `DESIGN`/`PLAN` 字样（grep 确认）。
- `extensions/guide/skills/guide/SKILL.md`：257 行全文读过，`activation`/`permissions`/`on_request` 一个字都不出现，两根轴（membership × tool face）的表述与 DESIGN §5.1 一致，`--bare`/`--seed`/plain wire recipe 都在。CLAUDE.md 那条"guide"现状 bullet 里的"187 行"是它 2026-08 落地时的行数，历史 bullet 不追更行号，未动。
- `src/extension/notes.zig` 的 `noteText`：`invoke: nulya ext run {id} <tool> '<json-args>'` 与今天 `ext run` 的形状一致，不提任何已删机制。
- TUI `/help`（`tui/src/ui/overlays/HelpView.tsx`）与 `tui/src/commands.ts`：命令表逐条核对，`/mode [ask|unsafe]`、`/with`（`/as` 旧名仍认）、`/agent` 均是 T31/T36/T48-T50 之后的说法；`Welcome.tips`（`tui/src/ui/Welcome.tsx:64`）十一条逐条核对，没有过时描述。两处都不需要改。
- `tui/src/compact.ts:86` 与 `tui/src/nulya/cli.ts:790`：Lane W 的进度记录说这两处"JSON-RPC error"措辞留给下一棒，但重新 `grep -rn 'JSON-RPC\|jsonrpc' tui/src` 是**零命中**——两处已经在 W 的同一个提交（`74aa3ea`）里改成了"a non-zero exit"/"REFUSES"的说法，Lane W 的自述与实际 diff 不一致，但代码本身已经是对的，R 这里不需要再动。
- `docs/agents-and-review.md:93`（"declared permissions ⊆ session_authority"）：整份文档在 CLAUDE.md 的路由表里标"全部未实现，归属 PLAN"，这句是未来 policy-hook 设计里的不变量措辞，呼应的是 DESIGN §9 至今仍然成立的 `extension_permissions ⊆ session_authority`，不是在断言 manifest 还有一个叫 `permissions` 的字段。未动。
- `docs/tui.md` §11 的全部命中（T23/T24/T31/T32/T34/T37/T41/T42/T46/T48）：都在"实施日志"里，逐条描述的是**那一个 T 当时**的行为（`activation`/`autoActivatable`/`standingPinsOf`/`on_request` 在被引入、被使用、最终在 T48 被删除的过程），T48/T50 已经在同一份日志里正确记录了删除。与 Lane S 处理 `autoActivatable` 残留时的先例一致：历史日志条目不因为后来改名/删除而重写，只有"当前该怎么做"的说明性段落（S3 已处理的 TOML 样例那两处）才需要跟着改。未再动 tui.md。
- `docs/base-tools.md`：grep 零命中，无需处理。
- `docs/PLAN.md` 其余命中（31/52/139/190/285/289/361）：31/139/190/285/289/361 均已正确标注"已删"/"✅ 已落地"或是与已删字段无关的通用词（如 190 的"activation / rollback"是英文动词，不是 manifest 字段）；52（M2c 一节讲 `handoff` 当初为什么是 compiled、要读 JSON-RPC）是纯历史记录，描述的是落地那一刻的决定与理由，不是当前 `handoff` 的实现方式（`handoff` 已在 Lane W 迁到 plain wire），但这段话本身没有断言"现在还是这样"，只是没有再补一句"后来 wire 变了"——留给下一次真正碰 M2c 一节的人一起处理，不在本次 grep 目标（`on_request`/`activation`/`permissions`/`jsonrpc` 等）划出的六处硬伤之列。
- 未在 R4 的 grep 列表里、但顺带读到的一处：`docs/PLAN.md:299`（3.8.1 那条 mode 表述）仍写"两档 mode（`ask` / `auto`）"——T31（2026-08-20）已把 `auto` 改名 `unsafe`。这个词不在本 lane 的 grep 目标（`on_request`/`activation`/`permissions`/`jsonrpc`/`autoActivatable`/`standingPinsOf`）里，按任务范围界定未改，记在这里供下一遍复读参考。

**验收**：`zig build test` exit 0；`zig build e2e` exit 0（含 `nulya help` 的 52 行预算、`ext api manifest`/`examples`/`help` 的零文档引用断言）。未改动任何 `tui/**` 或 `.zig` 文件，所以未跑 `bun test`（S 的 worktree 已经跑绿过一次，W 之后没有 TUI 侧改动），也未跑 `zig fmt`（没有 `.zig` 改动）。全部改动都是 `.md` 文件的最小字面修正，没有重排未改动的段落。
